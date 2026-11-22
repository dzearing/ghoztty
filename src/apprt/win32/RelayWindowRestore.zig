//! T3352: reopen, at launch, the relay windows the last run left open - the
//! worker half of Mac's `AppDelegate.restoreRemoteWindows` (WP-D2).
//!
//! The record is `App.relay_manifest` (`relay_manifest.zig`). This file does
//! the part that blocks: resolving the account's relay token (which may renew
//! it over the network), dialing each machine through the relay, and asking
//! its agent whether the session is still there. None of that may run on the
//! GUI thread, so the split is the one `RestoreAllRelay` (T339) drew:
//!
//!   worker thread   token -> dial -> probe the session, per entry
//!   GUI thread      decide each entry's fate and reopen the live ones
//!                   (`App.adoptRelayWindowRestore`)
//!
//! Per entry, the worker settles one of three fates, Mac's:
//!
//!   - no session id was ever captured, or the far agent says the session is
//!     gone -> `drop` (nothing to attach to, ever);
//!   - no credential, the relay or agent unreachable, or a probe that could not
//!     tell -> `keep` (the machine may simply be offline; the next launch tries
//!     again, and the restore path never puts up an alert);
//!   - alive -> `restore`, carrying the transport it dialed.
//!
//! The worker never touches the manifest - it is GUI-thread state. It reports,
//! and the GUI thread writes. One `Job` allocation travels both ways and is
//! freed on the GUI thread; any transport the GUI thread did not hand to a
//! window is freed with it, so a reply that lands while the app quits leaks
//! nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const Window = @import("Window.zig");
const relay_manifest = @import("relay_manifest.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Posted to the app's message window when the worker is done.
/// wparam = `*Job`, owned by the handler.
pub const WM_APP_RELAY_WINDOW_RESTORE: u32 = w32.WM_APP + 52;

/// How long the liveness probe waits for the far agent (Mac: 5 s).
const probe_timeout_ns: u64 = 5 * std.time.ns_per_s;

pub const Fate = enum { keep, drop, restore };

pub const Item = struct {
    /// Owned deep copy of the manifest entry (`relay_manifest.freeEntry`).
    entry: relay_manifest.Entry,
    fate: Fate = .keep,
    /// The transport dialed for a `restore`; owned by the job until the GUI
    /// thread hands it to a window and nulls it.
    dialed: ?Window.RemoteDialed = null,
};

pub const Job = struct {
    alloc: Allocator,
    hwnd: w32.HWND,
    items: []Item,
    /// The bearer token the dials used, owned. The restored windows record it
    /// for their own redials (`Window.setRemoteMachine` dupes it).
    token: ?[]u8 = null,

    pub fn destroy(self: *Job) void {
        for (self.items) |*item| {
            if (item.dialed) |d| d.deinitDestroy(self.alloc);
            relay_manifest.freeEntry(self.alloc, item.entry);
        }
        self.alloc.free(self.items);
        if (self.token) |t| self.alloc.free(t);
        self.alloc.destroy(self);
    }
};

/// GUI thread: snapshot every recorded relay window and start the worker.
/// Returns false when there is nothing to restore or the worker could not
/// start (in which case every entry is released, still recorded, for the next
/// launch).
pub fn start(app: *App) bool {
    const alloc = app.core_app.alloc;
    const hwnd = app.msg_hwnd orelse return false;
    if (app.relay_manifest.count() == 0) return false;

    const entries = app.relay_manifest.snapshotForRestore(alloc) catch |err| {
        log.warn("relay window restore: snapshot failed err={}", .{err});
        return false;
    };
    defer alloc.free(entries);
    if (entries.len == 0) return false;

    const job = alloc.create(Job) catch {
        releaseAll(app, entries);
        relay_manifest.freeSnapshot(alloc, entries);
        return false;
    };
    const items = alloc.alloc(Item, entries.len) catch {
        alloc.destroy(job);
        releaseAll(app, entries);
        relay_manifest.freeSnapshot(alloc, entries);
        return false;
    };
    // The entries' strings move into the items; `entries` itself is freed by
    // the defer above.
    for (items, entries) |*item, e| item.* = .{ .entry = e };
    job.* = .{ .alloc = alloc, .hwnd = hwnd, .items = items };

    const thread = std.Thread.spawn(.{}, run, .{job}) catch |err| {
        log.warn("relay window restore: worker did not start err={}", .{err});
        for (items) |item| app.relay_manifest.releaseRestore(item.entry.id);
        job.destroy();
        return false;
    };
    thread.detach();
    log.info("relay window restore: restoring {d} recorded relay window(s)", .{items.len});
    return true;
}

fn releaseAll(app: *App, entries: []const relay_manifest.Entry) void {
    for (entries) |e| app.relay_manifest.releaseRestore(e.id);
}

/// Worker thread: settle every item's fate, then post the job back.
fn run(job: *Job) void {
    settle(job);
    if (w32.PostMessageW(job.hwnd, WM_APP_RELAY_WINDOW_RESTORE, @intFromPtr(job), 0) == 0) {
        // The message window is gone, so the app is too: nothing can reopen
        // these windows now, and the entries stay on disk for the next launch.
        log.warn("relay window restore: reply could not be posted; dropping it", .{});
        job.destroy();
    }
}

fn settle(job: *Job) void {
    const alloc = job.alloc;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    // Signed out with no dev token: no dial at all. Every entry is kept for the
    // next launch, and the restore path never alerts (Mac).
    const token = IpcHandlers.resolveToken(arena_state.allocator()) orelse {
        log.info("relay window restore: no relay credential; {d} window(s) kept for later", .{job.items.len});
        return;
    };
    job.token = alloc.dupe(u8, token) catch return;

    for (job.items) |*item| {
        const sid = item.entry.session_id orelse {
            log.info("relay window restore: device={s} never reported a session; dropping", .{item.entry.device});
            item.fate = .drop;
            continue;
        };
        const d = alloc.create(relay_dial.Dialed) catch continue;
        d.* = relay_dial.dial(alloc, item.entry.relay_base, item.entry.device, token, .raw) catch |err| {
            alloc.destroy(d);
            log.warn(
                "relay window restore: dial failed device={s} err={}; keeping it for the next launch",
                .{ item.entry.device, err },
            );
            continue;
        };
        const dialed: Window.RemoteDialed = .{ .relay = d };
        switch (dialed.conn().probeSessionTimeout(sid, probe_timeout_ns)) {
            .alive => {
                item.dialed = dialed;
                item.fate = .restore;
            },
            .dead => {
                log.info("relay window restore: session={s} on device={s} is gone; dropping", .{ sid, item.entry.device });
                dialed.deinitDestroy(alloc);
                item.fate = .drop;
            },
            .unknown => {
                log.warn("relay window restore: session={s} on device={s} did not answer; keeping it", .{ sid, item.entry.device });
                dialed.deinitDestroy(alloc);
            },
        }
    }
}
