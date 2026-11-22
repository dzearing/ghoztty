//! Watch one file so a viewer pane re-renders when the document it shows is
//! saved (T3413, Linux L9d - Mac's `startWatchingFile`/`scheduleReload`,
//! win32's `viewer_watcher.zig`).
//!
//! A `GFileMonitor` on the file itself. GIO's inotify backend watches the
//! file's DIRECTORY and reports by name, so an atomic save (write a temp
//! file, rename it over the target) arrives as an ordinary event for the same
//! path and nothing has to re-arm onto a new inode - the same reason win32
//! watches by name. Which events count, and the debounce, are the pure
//! `viewer_reload.zig`; this end only turns a burst of them into one call on
//! the GTK main loop, which is where the monitor delivers anyway.
//!
//! Non-fatal in every failure mode, as on win32: a viewer whose monitor could
//! not start still shows its file and still reloads on `+reload` and Ctrl+R.
//! A file on a Windows drive (`/mnt/c/...`, WSL's 9p mount) gets no inotify
//! events for edits made from the Windows side; that is the mount's limit.
const Watch = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const wk = @import("webkit.zig");
const policy = @import("viewer_reload.zig");

const log = std.log.scoped(.gtk_viewer);

alloc: ?Allocator = null,
/// The watched path, owned; null when not watching.
path: ?[]u8 = null,
monitor: ?*wk.GFileMonitor = null,
handler: c_ulong = 0,
/// The pending debounce, a GLib source id; 0 when none is armed.
timer: c_uint = 0,

/// Called once per collapsed burst, on the main loop.
on_save: ?*const fn (ctx: *anyopaque) void = null,
ctx: ?*anyopaque = null,

/// The file being watched, or null.
pub fn watching(self: *const Watch) ?[]const u8 {
    return self.path;
}

/// Watch `path` and call `on_save(ctx)` after each burst of saves. Re-arming
/// is calling this again; it stops the previous watch first - including a
/// debounce already armed, which belongs to the old file (win32's T400:
/// left running it fires at wherever the pane went).
///
/// The watch must not move while it runs: the monitor's signal and the
/// debounce carry its address. It lives inside a heap-allocated `Viewer`.
pub fn start(
    self: *Watch,
    alloc: Allocator,
    path: []const u8,
    on_save: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
) void {
    self.stop();
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return;
    const file = wk.g_file_new_for_path(z.ptr);
    defer wk.g_object_unref(file);
    var err: ?*wk.GError = null;
    const monitor = wk.g_file_monitor_file(file, 0, null, &err) orelse {
        if (err) |e| {
            defer wk.g_error_free(e);
            log.warn("viewer: cannot watch {s}: {s} (live reload is off; +reload still works)", .{ path, std.mem.span(e.message orelse "?") });
        }
        return;
    };
    const owned = alloc.dupe(u8, path) catch {
        wk.g_object_unref(monitor);
        return;
    };
    self.* = .{
        .alloc = alloc,
        .path = owned,
        .monitor = monitor,
        .on_save = on_save,
        .ctx = ctx,
    };
    self.handler = wk.g_signal_connect_data(monitor, "changed", @ptrCast(&onChanged), self, null, 0);
    log.debug("viewer: watching {s}", .{path});
}

/// Stop watching, and drop a debounce still armed. Idempotent.
pub fn stop(self: *Watch) void {
    self.cancelPending();
    if (self.monitor) |m| {
        if (self.handler != 0) wk.g_signal_handler_disconnect(m, self.handler);
        _ = wk.g_file_monitor_cancel(m);
        wk.g_object_unref(m);
    }
    if (self.path) |p| if (self.alloc) |a| a.free(p);
    self.* = .{};
}

/// Drop a debounce already armed, leaving the watch running: an explicit
/// reload has just read the file, so a save it covered owes nothing more.
pub fn cancelPending(self: *Watch) void {
    if (self.timer != 0) {
        _ = wk.g_source_remove(self.timer);
        self.timer = 0;
    }
}

fn onChanged(
    _: *wk.GFileMonitor,
    _: *wk.GFile,
    _: ?*wk.GFile,
    event: policy.MonitorEvent,
    ud: ?*anyopaque,
) callconv(.c) void {
    const self: *Watch = @ptrCast(@alignCast(ud orelse return));
    if (!policy.isSave(event)) return;
    log.debug("viewer: {s} changed ({s})", .{ self.path orelse "?", @tagName(event) });
    // Restart the debounce: a burst collapses into one render after it.
    self.cancelPending();
    self.timer = wk.g_timeout_add(policy.debounce_ms, &onDebounced, self);
}

fn onDebounced(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Watch = @ptrCast(@alignCast(ud orelse return 0));
    self.timer = 0;
    if (self.on_save) |cb| if (self.ctx) |c| cb(c);
    // G_SOURCE_REMOVE: one shot.
    return 0;
}
