//! Relay windows come back at relaunch (T3671, Linux L8d-5): the GTK half of
//! win32's T3352 (`win32/relay_manifest.zig` + `RelayWindowRestore.zig`) and
//! the Mac's `RemoteSessionManifest` / `AppDelegate.restoreRemoteWindows`.
//!
//! `SessionLayout` skips every remote window, because its sessions live on
//! the FAR agent and are re-attached by dialing it, not by asking this
//! machine's agent. This keeps the separate record the Mac and win32 keep:
//! one entry per open relay window - where to dial (relay base + device),
//! what to ATTACH (its first pane's agent session), what it was called -
//! and never a token; the restore resolves the credential from the account
//! store (or `GHOSTTY_RELAY_TOKEN`) at launch. The record itself is win32's
//! `relay_manifest.Manifest`, which is std-only; only the path is Linux's
//! (`<config root>/ghoztty/remote-windows[-debug][-<lineage>].json`, beside
//! the session layout).
//!
//! Lifecycle, the Mac's and win32's:
//!
//!   - REGISTERED when a relay window opens (`+new-remote-window --relay`,
//!     `--from-focused` off a relay window, or this restore). Its session id
//!     is captured once the first pane has opened its far session, a network
//!     round trip later (a 500 ms poll for up to 30 s, win32's).
//!   - REMOVED on a deliberate close (the user's, `+close`, the remote shell
//!     exiting): `windowDisposed` while the app is not quitting.
//!   - KEPT through a quit (`syncForQuit` refreshes it first) or a crash.
//!
//! Restore at launch (`start`): a worker thread resolves the token, dials
//! each entry and probes its session; the GTK thread then reopens the live
//! ones on the transport the worker dialed (`ipc_remote_window.openWith`,
//! ATTACHing the session), drops the ones the far agent no longer knows, and
//! leaves everything it could not reach on disk for the next launch.
//! A direct `--host` window is not recorded, as on both other platforms: a
//! TCP endpoint is not an account resource with a stable identity.
//!
//! Who: only the instance serving this user's IPC socket owns the file (the
//! `SessionLayout` rule without its `session-persistence` gate: a relay
//! window's sessions are the far agent's, whatever this machine persists).
//!
//! GTK main thread only, except `settle`, which runs on the worker over its
//! own copies and touches no GTK or manifest state.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");

const build_config = @import("../../build_config.zig");
const agent_lineage = @import("../../remote/agent_lineage.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const relay_manifest = @import("../win32/relay_manifest.zig");
const rules = @import("session_layout_rules.zig");

const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const IpcHandlers = @import("IpcHandlers.zig");
const RemoteLink = @import("RemoteLink.zig");
const ipc_remote_window = @import("ipc_remote_window.zig");

const gobject = @import("gobject");

const log = std.log.scoped(.gtk_relay_windows);

const alloc = std.heap.c_allocator;

/// How long the liveness probe waits for the far agent (Mac and win32: 5 s).
const probe_timeout_ns: u64 = 5 * std.time.ns_per_s;

/// The session-id capture poll (win32 `armRelaySidCapture`).
const sid_poll_ms: c_uint = 500;
const sid_poll_ticks: u32 = 60;

/// The record; null until `init` (or when this instance does not own it).
var manifest: ?relay_manifest.Manifest = null;

/// The open windows holding an entry. A window leaves the list in
/// `windowDisposed`, so no pointer here outlives its window.
const Open = struct { window: *Window, id: relay_manifest.Id };
var open_windows: std.ArrayList(Open) = .empty;

var sid_timer: ?c_uint = null;
var sid_ticks: u32 = 0;

fn manifestPath(a: Allocator) ?[]u8 {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (@import("../../os/homedir.zig").home(&home_buf) catch null) orelse return null;
    var sfx_buf: [agent_lineage.max_len]u8 = undefined;
    const instance = agent_lineage.fromEnv(&sfx_buf);
    return rules.relayWindowsPathFrom(a, build_config.is_debug, instance, std.posix.getenv("XDG_CONFIG_HOME"), home) catch null;
}

/// Load the record. Call once at launch, on the instance serving the IPC
/// socket, before `start`.
pub fn init(app: *Application) void {
    if (manifest != null) return;
    if (app.rt().ipc_server == null) return;
    const path = manifestPath(alloc);
    defer if (path) |p| alloc.free(p);
    manifest = relay_manifest.Manifest.load(alloc, path);
    if (manifest.?.count() > 0) log.info("relay window record: {d} window(s) recorded", .{manifest.?.count()});
}

/// What the opener knows beyond the link: the IPC name and pinned title it
/// gave the window, the session the first pane is ATTACHing (a restore), and
/// the entry that restore supersedes (dropped in the same write).
pub const Record = struct {
    ipc_name: ?[]const u8 = null,
    title: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    replacing: ?[]const u8 = null,
};

/// Record a just-opened remote window if it rides a RELAY link.
pub fn record(window: *Window, link: *RemoteLink.Link, r: Record) void {
    const m = &(manifest orelse return);
    const relay = switch (link.machine) {
        .relay => |v| v,
        .tcp => return,
    };
    open_windows.ensureUnusedCapacity(alloc, 1) catch return;
    const id = m.register(.{
        .relay_base = relay.base,
        .device = relay.device,
        .session_id = r.session_id,
        .name = relay.name,
        // GTK's machine name is only ever the caller's `--name` (T1736).
        .name_pinned = relay.name != null,
        .ipc_name = r.ipc_name,
        .window_title = r.title,
    }, r.replacing) catch |err| {
        log.warn("relay window record: register failed err={}", .{err});
        return;
    };
    open_windows.appendAssumeCapacity(.{ .window = window, .id = id });
    log.info("relay window record: registered device={s} session={s} name={s}", .{
        relay.device,
        r.session_id orelse "(pending)",
        relay.name orelse "",
    });
    if (r.session_id == null) armSidCapture();
}

/// A window is going away. Outside a quit that is a deliberate close, so its
/// entry goes too; a quit keeps it for the next launch.
pub fn windowDisposed(window: *Window, quitting: bool) void {
    for (open_windows.items, 0..) |o, i| {
        if (o.window != window) continue;
        const gone = open_windows.swapRemove(i);
        if (!quitting) if (manifest) |*m| {
            m.remove(&gone.id);
            log.info("relay window record: window closed; entry removed", .{});
        };
        return;
    }
}

/// The quit's last look: every open relay window's session, IPC name and
/// pinned title as they stand now, so a rename after the open survives.
pub fn syncForQuit() void {
    if (sid_timer) |t| {
        _ = glib.Source.remove(t);
        sid_timer = null;
    }
    refresh();
}

fn refresh() void {
    const m = &(manifest orelse return);
    for (open_windows.items) |*o| {
        if (firstPaneSessionId(o.window)) |sid| m.setSessionId(&o.id, sid);
        m.setTitle(&o.id, o.window.titleOverride(), false);
        m.setIpcName(&o.id, o.window.ipcName());
    }
}

fn armSidCapture() void {
    sid_ticks = sid_poll_ticks;
    if (sid_timer != null) return;
    sid_timer = glib.timeoutAdd(sid_poll_ms, sidTick, null);
}

fn sidTick(_: ?*anyopaque) callconv(.c) c_int {
    const m = &(manifest orelse {
        sid_timer = null;
        return 0;
    });
    var pending: usize = 0;
    for (open_windows.items) |*o| {
        const e = m.find(&o.id) orelse continue;
        if (e.session_id != null) continue;
        if (firstPaneSessionId(o.window)) |sid| {
            m.setSessionId(&o.id, sid);
            log.info("relay window record: session captured session={s}", .{sid});
        } else pending += 1;
    }
    if (sid_ticks > 0) sid_ticks -= 1;
    if (pending == 0 or sid_ticks == 0) {
        if (pending > 0) log.warn("relay window record: {d} window(s) never reported a session id", .{pending});
        sid_timer = null;
        return 0;
    }
    return 1;
}

/// The agent session of `window`'s first terminal pane (Mac:
/// `surfaceTree.first`), or null while it has none.
fn firstPaneSessionId(window: *Window) ?[]const u8 {
    const tab_view = window.getTabView();
    if (tab_view.getNPages() <= 0) return null;
    const page = tab_view.getNthPage(0);
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return null;
    const tree = tab.getSplitTree().getTree() orelse return null;
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.remoteLink() == null) continue;
        const sid = entry.view.agentSessionId() orelse continue;
        if (sid.len == 0) continue;
        return sid;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Restore at launch.

const Fate = enum { keep, drop, restore };

const Item = struct {
    /// Owned deep copy of the manifest entry.
    entry: relay_manifest.Entry,
    fate: Fate = .keep,
    /// The transport dialed for a `restore`; owned until a window adopts it.
    dialed: ?*relay_dial.Dialed = null,
};

const Job = struct {
    items: []Item,
    /// The bearer the dials used, owned: the restored windows' links keep it
    /// for their own redials (a split's, `--from-focused`).
    token: ?[]u8 = null,

    fn destroy(self: *Job) void {
        for (self.items) |*item| {
            if (item.dialed) |d| {
                d.deinit();
                alloc.destroy(d);
            }
            relay_manifest.freeEntry(alloc, item.entry);
        }
        alloc.free(self.items);
        if (self.token) |t| alloc.free(t);
        alloc.destroy(self);
    }
};

/// Snapshot every recorded relay window and start the worker. Returns false
/// when there is nothing to restore or the worker could not start (every
/// entry is then released, still recorded, for the next launch).
pub fn start(app: *Application) bool {
    _ = app;
    const m = &(manifest orelse return false);
    if (m.count() == 0) return false;
    const entries = m.snapshotForRestore(alloc, &.{}) catch |err| {
        log.warn("relay window restore: snapshot failed err={}", .{err});
        return false;
    };
    defer alloc.free(entries);
    if (entries.len == 0) return false;

    const job = alloc.create(Job) catch {
        for (entries) |e| m.releaseRestore(e.id);
        relay_manifest.freeSnapshot(alloc, entries);
        return false;
    };
    const items = alloc.alloc(Item, entries.len) catch {
        alloc.destroy(job);
        for (entries) |e| m.releaseRestore(e.id);
        relay_manifest.freeSnapshot(alloc, entries);
        return false;
    };
    for (items, entries) |*item, e| item.* = .{ .entry = e };
    job.* = .{ .items = items };

    const thread = std.Thread.spawn(.{}, run, .{job}) catch |err| {
        log.warn("relay window restore: worker did not start err={}", .{err});
        for (items) |item| m.releaseRestore(item.entry.id);
        job.destroy();
        return false;
    };
    thread.detach();
    log.info("relay window restore: restoring {d} recorded relay window(s)", .{items.len});
    return true;
}

fn run(job: *Job) void {
    settle(job);
    _ = glib.idleAdd(adoptIdle, job);
}

/// Worker thread: settle every item's fate (win32's `settle`, the Mac's).
fn settle(job: *Job) void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    // Signed out with no dev token: no dial at all, every entry kept, and the
    // restore path never alerts.
    const token = ipc_remote_window.resolveToken(arena_state.allocator()) orelse {
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
            log.warn("relay window restore: dial failed device={s} err={}; keeping it for the next launch", .{ item.entry.device, err });
            continue;
        };
        switch (d.conn.probeSessionTimeout(sid, probe_timeout_ns)) {
            .alive => {
                item.dialed = d;
                item.fate = .restore;
            },
            .dead => {
                log.info("relay window restore: session={s} on device={s} is gone; dropping", .{ sid, item.entry.device });
                d.deinit();
                alloc.destroy(d);
                item.fate = .drop;
            },
            .unknown => {
                log.warn("relay window restore: session={s} on device={s} did not answer; keeping it", .{ sid, item.entry.device });
                d.deinit();
                alloc.destroy(d);
            },
        }
    }
}

fn adoptIdle(ud: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(ud orelse return 0));
    defer job.destroy();
    _ = adopt(Application.default(), job);
    return 0;
}

/// GTK thread: reopen the windows the worker found alive and settle every
/// other entry. Returns how many reopened.
fn adopt(app: *Application, job: *Job) usize {
    const m = &(manifest orelse return 0);
    var restored: usize = 0;
    for (job.items) |*item| {
        const id = item.entry.id;
        switch (item.fate) {
            .drop => {
                m.remove(id);
                continue;
            },
            .keep => {
                m.releaseRestore(id);
                continue;
            },
            .restore => {},
        }
        const sid = item.entry.session_id orelse {
            m.remove(id);
            continue;
        };
        // The app is leaving: leave the entry for a later launch.
        if (app.isQuitting()) {
            m.releaseRestore(id);
            continue;
        }
        const d = item.dialed orelse {
            m.releaseRestore(id);
            continue;
        };
        item.dialed = null;
        const link = RemoteLink.adopt(.{ .relay = d }, .{ .relay = .{
            .base = item.entry.relay_base,
            .device = item.entry.device,
            .token = job.token orelse "",
            .name = if (item.entry.name_pinned) item.entry.name else null,
        } }) catch {
            m.releaseRestore(id);
            continue;
        };
        // A name somebody took while the window was gone stays theirs.
        const ipc_name: ?[]const u8 = if (item.entry.ipc_name) |n|
            (if (IpcHandlers.nameTaken(app, n)) null else n)
        else
            null;
        _ = ipc_remote_window.openWith(app, .{ .link = link, .session_id = sid }, false, .{
            .ipc_name = ipc_name,
            .title = item.entry.window_title,
            .session_id = sid,
            .replacing = id,
        });
        // A window whose first pane did not take the link retired it and
        // registered nothing; the entry stays for a later launch.
        if (m.isInFlight(id)) {
            m.releaseRestore(id);
            continue;
        }
        log.info("relay window restore: reattached device={s} session={s} name={s}", .{ item.entry.device, sid, ipc_name orelse "" });
        restored += 1;
    }
    log.info("relay window restore: {d} of {d} window(s) reopened", .{ restored, job.items.len });
    return restored;
}
