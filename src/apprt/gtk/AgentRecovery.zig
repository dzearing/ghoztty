//! In-place local-agent recovery for the GTK app (T3400, Linux L8e): when the
//! local `ghoztty-agent` dies or its link stays down while the app is running,
//! every terminal pane that rode it is rebuilt IN PLACE on a fresh agent -
//! same window, same split, same pane id and name - instead of sitting frozen
//! until the app is relaunched. The Mac's `LocalAgentManager` link observer
//! (T12e) and win32's settle watch + `recoverLocalAgentInPlace` (T145, T399,
//! T723, T1473) are the models; every DECISION is win32's pure
//! `agent_recovery.zig`, shared rather than copied.
//!
//! The pieces:
//!
//!  - **The watch.** A `poll_ms` GLib timeout samples the shared link (one
//!    mutex take) and the agent's pid. A down link opens a settle window of
//!    `settle_ms`, because a link can heal (the Mac's 2026-07-21 incident); an
//!    agent pid that is confirmed gone waives the window, since a dead process
//!    heals nothing. `agent_recovery.evaluate` decides once it elapses.
//!  - **The rebuild.** `LocalAgent.reconnectForRecovery` finds or spawns an
//!    agent and retires the old connection (shut down off this thread). Then
//!    every terminal pane whose core rides a RETIRED connection is replaced in
//!    its slot (`SplitTree.replaceSurface`) by a pane that re-ATTACHes its
//!    session when the new agent lists it alive or relaunchable - a restarted
//!    agent turns its recorded sessions into relaunchable tombstones, so the
//!    shell comes back in its directory with the `session restarted` divider -
//!    else opens a fresh shell in the pane's directory. Viewers are never
//!    touched (`agent_recovery.rebuildsLeaf`). The replaced pane is marked
//!    `spareSession`, so its teardown DETACHes rather than ending the session
//!    its replacement just attached (`agent_recovery.sessionSpared`).
//!  - **The retry.** A re-dial that fails is retried on
//!    `agent_recovery.retry_delays_ms` (T723): a down link never produces a
//!    second edge, so without it the panes would stay frozen.
//!  - **A new pane first.** A pane opened while the agent is confirmed dead
//!    (`newSurfaceVerdict` = `recover_first`) re-dials through
//!    `LocalAgent.sharedConnection`, which then asks this module to rebuild the
//!    stranded panes on the next idle (never from inside the pane being built).
//!
//! Log lines (the acceptance reads them): `agent recovery: link down ...`,
//! `agent recovery: rebuilt <n> pane(s) ...`, `agent recovery: link recovered
//! on its own ...`, `agent recovery: retry ...`, `agent recovery: gave up ...`.
//!
//! GTK main thread only.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const policy = @import("../win32/agent_recovery.zig");
const connection = @import("../../remote/connection.zig");

const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;

const log = std.log.scoped(.gtk_agent_recovery);

/// How long a roster request on the fresh connection may take.
const roster_timeout_ns: u64 = 2 * std.time.ns_per_s;

var timer: ?c_uint = null;
/// When the current down window opened (ms), or null while the link is up.
var down_since_ms: ?i64 = null;
/// Retries already run since the last successful re-dial.
var retry_attempts: usize = 0;
/// When the next retry is due (ms), or null when none is armed.
var retry_due_ms: ?i64 = null;
var recovering = false;
var idle_pending = false;

/// Start the watch. Idempotent; a no-op tick while no agent was ever dialed.
pub fn start(app: *Application) void {
    if (timer != null) return;
    app.rt().local_agent.on_reconnected = scheduleRebuild;
    timer = glib.timeoutAdd(policy.poll_ms, tick, app);
}

fn tick(ud: ?*anyopaque) callconv(.c) c_int {
    const app: *Application = @ptrCast(@alignCast(ud orelse return 0));
    if (app.isQuitting()) {
        timer = null;
        return 0;
    }
    watch(app, std.time.milliTimestamp());
    return 1;
}

fn watch(app: *Application, now: i64) void {
    if (recovering) return;
    const la = &app.rt().local_agent;

    if (retry_due_ms) |due| {
        if (now < due) return;
        retry_due_ms = null;
        switch (policy.evaluateRetry(la.sharedState(), retry_attempts)) {
            .retry => {
                retry_attempts += 1;
                log.warn("agent recovery: retry {d} of {d}", .{ retry_attempts, policy.retry_delays_ms.len });
                recover(app, "retry");
            },
            .link_recovered => {
                log.warn("agent recovery: link recovered on its own while a retry was armed; nothing rebuilt", .{});
                retry_attempts = 0;
            },
            .no_owner => retry_attempts = 0,
            .exhausted => {
                log.err("agent recovery: gave up after {d} retries; panes on the lost agent stay frozen until a new pane or a relaunch reaches an agent", .{retry_attempts});
                retry_attempts = 0;
            },
        }
        return;
    }

    const raw_state = la.sharedState() orelse {
        down_since_ms = null;
        return;
    };
    const pid = la.sharedPid();
    const alive = la.sharedPidAlive();
    // A dead agent can still read `connected` for a moment before the reader
    // sees the socket close; a confirmed-dead pid is a drop either way.
    const state: connection.LinkState.State = if (!policy.isDown(raw_state) and pid > 0 and !alive)
        .reconnecting
    else
        raw_state;

    if (!policy.isDown(state)) {
        if (down_since_ms != null) {
            log.warn("agent recovery: link recovered on its own (state={s}); nothing rebuilt", .{@tagName(state)});
            down_since_ms = null;
        }
        return;
    }
    const since = down_since_ms orelse since: {
        log.warn("agent recovery: link down (state={s}, agent pid {d} {s}); settling", .{
            @tagName(state), pid, if (alive) "alive" else "gone",
        });
        down_since_ms = now;
        break :since now;
    };
    var remaining = policy.settle_ms - (now - since);
    if (policy.settleWaived(state, pid, alive)) remaining = 0;
    const live: ?i64 = if (remaining <= 0) (if (la.liveAgentPid()) |p| @as(i64, p) else null) else null;

    const verdict = policy.evaluate(state, true, remaining, pid, live);
    switch (verdict) {
        .keep_watching => return,
        .link_recovered, .owner_replaced => down_since_ms = null,
        .agent_restarted => |d| {
            down_since_ms = null;
            log.warn("agent recovery: agent is gone (was pid {d}, now {?d}); recovering windows in place", .{ d.previous_pid, d.current_pid });
            recover(app, "agent restarted");
        },
        .transport_down => |d| {
            down_since_ms = null;
            log.warn("agent recovery: link down but agent pid {d} is alive; recovering windows in place", .{d.pid});
            recover(app, "transport down");
        },
    }
}

/// Re-dial, then rebuild every pane stranded on a retired connection. A
/// failed re-dial arms the next retry.
fn recover(app: *Application, why: []const u8) void {
    const la = &app.rt().local_agent;
    const conn = la.reconnectForRecovery() orelse {
        if (policy.retryDelayMs(retry_attempts)) |delay| {
            retry_due_ms = std.time.milliTimestamp() + delay;
            log.warn("agent recovery: no agent reachable ({s}); retry in {d} ms", .{ why, delay });
        } else {
            log.err("agent recovery: gave up after {d} retries; panes on the lost agent stay frozen until a new pane or a relaunch reaches an agent", .{retry_attempts});
            retry_attempts = 0;
        }
        return;
    };
    retry_attempts = 0;
    retry_due_ms = null;
    rebuildStranded(app, conn);
}

/// `LocalAgent.on_reconnected`: a new pane re-dialed past a dead agent; the
/// other panes are rebuilt once that pane is built.
fn scheduleRebuild() void {
    if (idle_pending) return;
    idle_pending = true;
    _ = glib.idleAdd(rebuildIdle, null);
}

fn rebuildIdle(_: ?*anyopaque) callconv(.c) c_int {
    idle_pending = false;
    const app = Application.default();
    const d = app.rt().local_agent.shared orelse return 0;
    down_since_ms = null;
    retry_due_ms = null;
    retry_attempts = 0;
    rebuildStranded(app, d.conn);
    return 0;
}

/// Replace every terminal pane whose core rides a retired connection with a
/// pane on `conn`, in place. Returns how many were rebuilt.
fn rebuildStranded(app: *Application, conn: *connection.Connection) void {
    if (recovering) return;
    recovering = true;
    defer recovering = false;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Which sessions the agent can hand back: alive, or a tombstone it can
    // relaunch (win32's recovery rule). Unknown roster: try every session.
    var usable: ?std.StringHashMapUnmanaged(void) = null;
    if (conn.requestSessions(roster_timeout_ns)) |roster_| {
        var roster = roster_;
        defer roster.deinit();
        var ids: std.StringHashMapUnmanaged(void) = .empty;
        for (roster.sessions) |s| {
            if (!(s.alive or s.relaunchable)) continue;
            ids.put(arena, arena.dupe(u8, s.id) catch continue, {}) catch continue;
        }
        usable = ids;
    } else |err| log.warn("agent recovery: roster unavailable err={}; re-attaching every session", .{err});

    const la = &app.rt().local_agent;
    var rebuilt: usize = 0;
    var fresh: usize = 0;
    var node: ?*glib.List = app.as(gtk.Application).getWindows();
    while (node) |n| : (node = n.f_next) {
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const window = gobject.ext.cast(Window, obj) orelse continue;
        const tab_view = window.getTabView();
        const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
        for (0..pages) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const split = tab.getSplitTree();
            // Collect first: each replacement swaps the tree being walked.
            var stranded: std.ArrayList(*Surface) = .empty;
            const tree = split.getTree() orelse continue;
            var it = tree.iterator();
            while (it.next()) |entry| {
                const s = entry.view;
                if (!policy.rebuildsLeaf(if (s.getViewer() != null) .viewer else .terminal)) continue;
                const c = s.agentConnection() orelse continue;
                if (!la.isRetired(c)) continue;
                stranded.append(arena, s) catch continue;
            }
            for (stranded.items) |old| {
                const attached = replace(arena, split, old, usable) catch |err| {
                    log.warn("agent recovery: pane {s} could not be rebuilt err={}", .{ old.paneId(), err });
                    continue;
                };
                rebuilt += 1;
                if (!attached) fresh += 1;
            }
        }
    }
    log.info("agent recovery: rebuilt {d} pane(s) on the new agent connection ({d} re-attached, {d} fresh)", .{ rebuilt, rebuilt - fresh, fresh });
}

/// Build `old`'s replacement and swap it in. True when it re-attaches a
/// session, false when it opens a fresh shell.
fn replace(
    arena: std.mem.Allocator,
    split: anytype,
    old: *Surface,
    usable: ?std.StringHashMapUnmanaged(void),
) !bool {
    const sid: ?[]const u8 = if (old.agentSessionId()) |id| sid: {
        const owned = try arena.dupe(u8, id);
        if (usable) |u| if (!u.contains(owned)) break :sid null;
        break :sid owned;
    } else null;
    const pane_id = try arena.dupe(u8, old.paneId());
    const pwd: ?[]const u8 = if (old.getPwd()) |p| try arena.dupe(u8, p) else null;
    const name: ?[]const u8 = if (old.ipcName()) |nm| try arena.dupe(u8, nm) else null;
    const title: ?[:0]const u8 = if (old.titleOverride()) |t| try arena.dupeZ(u8, t) else null;
    // The pane's banner rides across too (T3560): the replacement is the same
    // pane to the user, and its backend keeps the notice out of the slot.
    const banner: ?[]const u8 = if (old.getPaneBanner()) |b| try arena.dupe(u8, b) else null;

    Surface.pending_restore = .{
        .session_id = sid,
        .pane_id = pane_id,
        .working_directory = pwd,
        .banner = banner,
        // And its tint (T3589): a recovered pane used to come back untinted.
        .tint = old.backgroundTint(),
    };
    const replacement = Surface.new(.{});
    Surface.pending_restore = null;
    defer replacement.unref();
    _ = replacement.refSink();

    if (name) |nm| replacement.setIpcName(nm);
    if (title) |t| replacement.setTitleOverride(t);

    // Spare BEFORE the swap: the swap may drop the last reference to `old`.
    old.spareSession();
    if (!try split.replaceSurface(old, replacement)) return error.NotInTree;
    return sid != null;
}
