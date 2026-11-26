//! The remote reconnect ladder on GTK (T3675, Linux L11a-3) - the DRIVER.
//! win32's `RemoteReconnect.zig` (T366) and the Mac's WP-D1 ladder
//! (`BaseTerminalController`, `MARK: Remote Reconnect`): drop -> bounded
//! redial with backoff -> re-ATTACH by session id -> live again, with the
//! connection pill (`RemotePill.zig`) saying which of those is happening.
//! Every DECISION is win32's pure `remote_reconnect.zig`, shared.
//!
//! The GTK difference is where the ladder lives: on the `RemoteLink.Link`,
//! not on a window. A GTK pane holds its link and can leave its window, so
//! one dial is one ladder, and every window showing a pane on it paints the
//! same pill.
//!
//!  1. **Notice.** `watch` puts a link-state observer on the link's current
//!     transport. It runs on the connection's reader thread under its state
//!     mutex, so it only queues one `g_idle_add`; everything else happens on
//!     the GTK thread. Re-installed after every swap.
//!  2. **Drive.** `tick` samples every live link, folds the transport state
//!     into the ladder (`policy.onLinkChange`) and runs what is due. A
//!     `poll_ms` GLib timeout is armed only while a link has something to
//!     wait for (`policy.needsTick`) or a dial is out.
//!  3. **Dial.** `startAttempt` spawns a detached worker that dials the
//!     link's machine (TCP, or the relay with the account's bearer, else the
//!     one the window was dialed with), then asks the agent for its roster.
//!     It lands back through `g_idle_add` with a generation; a stale one only
//!     frees what it brought. Links are never freed (`RemoteLink`'s module
//!     doc), so the worker may name its link by pointer.
//!  4. **Swap.** `applySwap` points the link at the NEW transport, replaces
//!     every pane riding it in its slot (`SplitTree.replaceSurface`, the
//!     shape `AgentRecovery` uses for the local agent) with one that
//!     re-ATTACHes its session by id, and only then shuts the old transport
//!     down - kept, never freed (`RemoteLink.Link.replaceTransport`). The
//!     replaced pane is `spareSession`d, so its teardown DETACHes rather than
//!     ending the session its replacement just attached. A reconnect the
//!     USER asked for whose sessions are gone (a rebooted box, a restarted
//!     agent) keeps the layout and opens a fresh shell in every pane (T611);
//!     the automatic ladder goes terminal there instead.
//!
//! Log lines (the acceptance reads some): `remote reconnect: ... dropped;
//! attempt n/5 in <ms>`, `... back on a fresh transport (<n> pane(s)
//! re-attached|opened fresh)`, `... link recovered on its own`, `...
//! exhausted its fast ladder`, `... is terminal after attempt`.
//!
//! GTK main thread only, except `onLinkChange` and `worker`.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const policy = @import("../win32/remote_reconnect.zig");
const dial_failure = @import("../win32/dial_failure.zig");
const connection = @import("../../remote/connection.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const RemoteLink = @import("RemoteLink.zig");
const ipc_remote_window = @import("ipc_remote_window.zig");

const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;

const log = std.log.scoped(.gtk_remote_reconnect);
const alloc = std.heap.c_allocator;

/// The ladder's cadence while something is due (win32 `poll_ms`).
pub const poll_ms: c_uint = 250;

/// How long the roster probe on a fresh connection may take before liveness
/// counts as UNKNOWN (win32 `probe_timeout_ns`).
const probe_timeout_ns: u64 = 5 * std.time.ns_per_s;

var timer: ?c_uint = null;
var idle_queued = std.atomic.Value(bool).init(false);

// =============================================================================
// Observation
// =============================================================================

/// Watch `link`'s current transport. Idempotent; `applySwap` calls it again
/// for the fresh one. Every remote pane's adoption calls it, so each link is
/// watched from its first pane on.
pub fn watch(link: *RemoteLink.Link) void {
    if (link.retired or link.reconnect.observed) return;
    link.conn().setStateHandler(link, onLinkChange);
    link.reconnect.observed = true;
}

/// Reader thread, under the connection's state mutex: queue one pass and
/// return. Every edge matters - a link that comes BACK is how a
/// self-healable window recovers with no click.
fn onLinkChange(
    _: *anyopaque,
    _: *connection.Connection,
    old: connection.LinkState.State,
    new: connection.LinkState.State,
) void {
    if (old == new) return;
    if (idle_queued.swap(true, .acq_rel)) return;
    _ = glib.idleAdd(onIdle, null);
}

fn onIdle(_: ?*anyopaque) callconv(.c) c_int {
    idle_queued.store(false, .release);
    tick();
    return 0;
}

// =============================================================================
// Driving
// =============================================================================

/// One pass over every live link, then arm or disarm the poller.
pub fn tick() void {
    if (pass()) {
        if (timer == null) timer = glib.timeoutAdd(poll_ms, onTimer, null);
    } else if (timer) |t| {
        _ = glib.Source.remove(t);
        timer = null;
    }
}

fn onTimer(_: ?*anyopaque) callconv(.c) c_int {
    if (pass()) return 1;
    timer = null;
    return 0;
}

/// Drive every live link; true while any still needs the poller.
fn pass() bool {
    if (Application.default().isQuitting()) return false;
    const now = std.time.milliTimestamp();
    var wanted = false;
    for (RemoteLink.allLinks()) |link| {
        if (link.retired) continue;
        drive(link, now);
        const rc = &link.reconnect;
        if (rc.inflight or policy.needsTick(rc.ladder)) wanted = true;
    }
    return wanted;
}

fn drive(link: *RemoteLink.Link, now: i64) void {
    const rc = &link.reconnect;
    switch (policy.onLinkChange(rc.ladder, policy.classify(link.conn().state()))) {
        .none => {},
        .recovered => {
            _ = rc.gen.bump();
            rc.attempt = 0;
            rc.due_ms = 0;
            rc.manual = false;
            rc.breaker.reset();
            setLadder(link, .connected);
            log.info("remote reconnect: link recovered on its own for {s}", .{name(link)});
        },
        .begin_reconnect => beginLadder(link, now, false),
        .go_terminal => {
            if (rc.ladder != .disconnected)
                log.warn("remote reconnect: {s} is terminally disconnected (evicted or session gone)", .{name(link)});
            goTerminal(link, policy.terminal_state);
        },
    }
    if (rc.inflight) return;
    if (rc.due_ms == 0 or now < rc.due_ms) return;
    rc.due_ms = 0;
    startAttempt(link);
}

fn beginLadder(link: *RemoteLink.Link, now: i64, manual: bool) void {
    const rc = &link.reconnect;
    // A click is fresh evidence: it clears the breaker's memory.
    const poisoned = if (manual) blk: {
        rc.breaker.reset();
        break :blk false;
    } else rc.breaker.judge(now);

    const decision = if (manual)
        policy.beginManualReconnect(rc.ladder)
    else
        policy.beginReconnect(rc.ladder, hasSession(link), poisoned);

    switch (decision) {
        .ignore => return,
        .terminal_no_session => {
            log.warn("remote reconnect: {s} dropped with no session to re-attach; nothing to come back to", .{name(link)});
            goTerminal(link, policy.terminal_state);
        },
        .terminal_poisoned => {
            log.warn("remote reconnect: {s} condemned after {d} swaps that died inside {d}ms", .{
                name(link), policy.poison_limit, policy.poison_window_ms,
            });
            goTerminal(link, policy.terminal_state);
        },
        .start => |s| {
            _ = rc.gen.bump();
            rc.attempt = s.attempt;
            rc.manual = manual;
            setLadder(link, .{ .reconnecting = .{ .attempt = s.attempt } });
            const delay = policy.backoffMs(s.attempt, manual);
            rc.due_ms = now + @as(i64, @intCast(delay));
            log.warn("remote reconnect: {s} dropped; attempt {d}/{d} in {d}ms{s}", .{
                name(link), s.attempt, policy.max_attempts, delay, if (manual) " (manual)" else "",
            });
        },
    }
}

/// The ONE writer of the ladder state: every transition repaints the pills.
fn setLadder(link: *RemoteLink.Link, next: policy.WindowState) void {
    const rc = &link.reconnect;
    if (std.meta.eql(rc.ladder, next)) return;
    rc.ladder = next;
    refreshPills();
}

fn goTerminal(link: *RemoteLink.Link, state: policy.WindowState) void {
    const rc = &link.reconnect;
    _ = rc.gen.bump();
    rc.attempt = 0;
    rc.due_ms = 0;
    rc.manual = false;
    setLadder(link, state);
}

/// The user asked for `link` to reconnect NOW (a broken pill's click): from
/// any disconnected tier, terminal included, with no backoff.
pub fn manualReconnect(link: *RemoteLink.Link) void {
    if (link.retired) return;
    beginLadder(link, std.time.milliTimestamp(), true);
    tick();
}

/// Repaint every window's pill.
pub fn refreshPills() void {
    var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
    while (node) |n| : (node = n.f_next) {
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const window = gobject.ext.cast(Window, obj) orelse continue;
        window.refreshRemotePill();
    }
}

fn name(link: *const RemoteLink.Link) []const u8 {
    return link.machine.displayName();
}

// =============================================================================
// The panes riding a link
// =============================================================================

/// One terminal pane on a link, and the split tree that holds it.
const Pane = struct { split: *@import("class/split_tree.zig").SplitTree, surface: *Surface };

/// Every terminal pane riding `link`, in every window. Viewers never ride
/// one. On `arena`.
fn panesOn(arena: std.mem.Allocator, link: *RemoteLink.Link) []Pane {
    var out: std.ArrayList(Pane) = .empty;
    var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
    while (node) |n| : (node = n.f_next) {
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const window = gobject.ext.cast(Window, obj) orelse continue;
        const tab_view = window.getTabView();
        const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
        for (0..pages) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const split = tab.getSplitTree();
            const tree = split.getTree() orelse continue;
            var it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view.remoteLink() != link) continue;
                if (entry.view.getViewer() != null) continue;
                out.append(arena, .{ .split = split, .surface = entry.view }) catch continue;
            }
        }
    }
    return out.items;
}

/// Whether any pane on `link` holds a far session a dial could bring back.
fn hasSession(link: *RemoteLink.Link) bool {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    for (panesOn(arena_state.allocator(), link)) |p| {
        if (p.surface.agentSessionId() != null) return true;
    }
    return false;
}

// =============================================================================
// The redial worker
// =============================================================================

const Request = struct {
    link: *RemoteLink.Link,
    gen: u64,
    manual: bool,
    /// The machine, copied: the worker owns every byte it reads.
    target: Target,

    fn destroy(self: *Request) void {
        self.target.free();
        alloc.destroy(self);
    }
};

const Target = union(enum) {
    tcp: struct { host: []u8, port: u16 },
    relay: struct { base: []u8, device: []u8, recorded_token: []u8 },

    fn free(self: Target) void {
        switch (self) {
            .tcp => |t| alloc.free(t.host),
            .relay => |r| {
                alloc.free(r.base);
                alloc.free(r.device);
                alloc.free(r.recorded_token);
            },
        }
    }
};

/// A finished attempt, owned by the GTK thread from the idle on.
const Result = struct {
    link: *RemoteLink.Link,
    gen: u64,
    manual: bool,
    dial: policy.DialResult,
    dialed: ?RemoteLink.Dialed = null,
    /// The agent's roster, or null when the probe never landed (UNKNOWN).
    roster: ?connection.OwnedSessions = null,

    fn destroy(self: *Result) void {
        if (self.dialed) |d| d.deinitDestroy(alloc);
        if (self.roster) |*r| r.deinit();
        alloc.destroy(self);
    }
};

fn startAttempt(link: *RemoteLink.Link) void {
    const rc = &link.reconnect;
    const target: Target = switch (link.machine) {
        .tcp => |t| .{ .tcp = .{
            .host = alloc.dupe(u8, t.host) catch return failAttempt(link),
            .port = t.port,
        } },
        .relay => |r| blk: {
            const base = alloc.dupe(u8, r.base) catch return failAttempt(link);
            const device = alloc.dupe(u8, r.device) catch {
                alloc.free(base);
                return failAttempt(link);
            };
            const tok = alloc.dupe(u8, r.token) catch {
                alloc.free(base);
                alloc.free(device);
                return failAttempt(link);
            };
            break :blk .{ .relay = .{ .base = base, .device = device, .recorded_token = tok } };
        },
    };
    const req = alloc.create(Request) catch {
        target.free();
        return failAttempt(link);
    };
    req.* = .{ .link = link, .gen = rc.gen.value, .manual = rc.manual, .target = target };
    const thread = std.Thread.spawn(.{}, worker, .{req}) catch |err| {
        log.warn("remote reconnect: dial thread spawn failed err={}", .{err});
        req.destroy();
        return failAttempt(link);
    };
    thread.detach();
    rc.inflight = true;
    log.info("remote reconnect: dialing {s} (attempt {d}{s})", .{ name(link), rc.attempt, if (rc.manual) ", manual" else "" });
}

/// An attempt did not bring the link back (or could not be started).
fn failAttempt(link: *RemoteLink.Link) void {
    const rc = &link.reconnect;
    const has_session = hasSession(link);
    // A failed BACKGROUND re-dial is not a fast-ladder attempt: the
    // exhausted state is the truthful one and stays.
    if (rc.ladder == .disconnected) {
        rc.due_ms = if (rc.ladder.disconnected.self_healable and has_session)
            std.time.milliTimestamp() + @as(i64, @intCast(policy.redial_interval_ms))
        else
            0;
        return;
    }
    switch (policy.onAttemptFailed(rc.attempt, has_session)) {
        .retry => |r| {
            rc.attempt = r.attempt;
            setLadder(link, .{ .reconnecting = .{ .attempt = r.attempt } });
            rc.due_ms = std.time.milliTimestamp() + @as(i64, @intCast(r.delay_ms));
        },
        .exhausted => |e| {
            rc.attempt = 0;
            setLadder(link, policy.exhausted_state);
            rc.due_ms = if (e.arm_background_redial)
                std.time.milliTimestamp() + @as(i64, @intCast(policy.redial_interval_ms))
            else
                0;
            log.warn("remote reconnect: {s} exhausted its fast ladder; {s}", .{
                name(link),
                if (e.arm_background_redial) "re-dialing in the background" else "no session to re-attach, waiting for the link",
            });
        },
    }
}

/// The detached dial. Owns `req`; hands its outcome to the GTK thread.
fn worker(req: *Request) void {
    defer req.destroy();
    var dialed: ?RemoteLink.Dialed = null;
    var dial: policy.DialResult = .failed;
    switch (req.target) {
        .tcp => |t| if (alloc.create(tcp_dial.Dialed)) |d| {
            if (tcp_dial.dial(alloc, t.host, t.port, .raw)) |ok| {
                d.* = ok;
                dialed = .{ .tcp = d };
                dial = .ok;
            } else |err| {
                log.warn("remote reconnect: tcp dial {s}:{d} failed err={}", .{ t.host, t.port, err });
                if (dial_failure.classify(err) == .incompatible) dial = .incompatible;
                alloc.destroy(d);
            }
        } else |_| {},
        .relay => |r| {
            // The account store's renewable bearer wins; the one the window
            // was dialed with is the fallback (win32 T1276). None at all is
            // signed out - retrying cannot sign anyone in.
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const token = policy.chooseRelayToken(
                ipc_remote_window.resolveToken(arena_state.allocator()),
                r.recorded_token,
            );
            if (token == null) {
                dial = .unauthorized;
            } else if (alloc.create(relay_dial.Dialed)) |d| {
                if (relay_dial.dial(alloc, r.base, r.device, token.?, .raw)) |ok| {
                    d.* = ok;
                    dialed = .{ .relay = d };
                    dial = .ok;
                } else |err| {
                    log.warn("remote reconnect: relay dial device={s} failed err={}", .{ r.device, err });
                    switch (dial_failure.classify(err)) {
                        .unauthorized => dial = .unauthorized,
                        .incompatible => dial = .incompatible,
                        .unreachable_machine => {},
                    }
                    alloc.destroy(d);
                }
            } else |_| {}
        },
    }

    var roster: ?connection.OwnedSessions = null;
    if (dialed) |d| {
        roster = d.conn().requestSessions(probe_timeout_ns) catch |err| blk: {
            log.warn("remote reconnect: liveness probe failed err={} (treating as unknown)", .{err});
            break :blk null;
        };
    }

    const res = alloc.create(Result) catch {
        if (dialed) |d| d.deinitDestroy(alloc);
        if (roster) |*r| r.deinit();
        return;
    };
    res.* = .{
        .link = req.link,
        .gen = req.gen,
        .manual = req.manual,
        .dial = dial,
        .dialed = dialed,
        .roster = roster,
    };
    _ = glib.idleAdd(onDialedIdle, res);
}

fn onDialedIdle(ud: ?*anyopaque) callconv(.c) c_int {
    const res: *Result = @ptrCast(@alignCast(ud orelse return 0));
    onDialed(res);
    return 0;
}

// =============================================================================
// Landing an attempt
// =============================================================================

fn onDialed(res: *Result) void {
    defer res.destroy();
    const link = res.link;
    const rc = &link.reconnect;
    rc.inflight = false;
    defer tick();
    if (link.retired or !rc.gen.isCurrent(res.gen)) {
        log.info("remote reconnect: stale attempt for {s} discarded", .{name(link)});
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The sessions the agent can hand back: alive or relaunchable. Null
    // roster: UNKNOWN, which `outcomeFromAttempt` reads as "try the swap".
    var usable: ?std.StringHashMapUnmanaged(void) = null;
    if (res.roster) |roster| {
        var ids: std.StringHashMapUnmanaged(void) = .empty;
        for (roster.sessions) |s| {
            if (!(s.alive or s.relaunchable)) continue;
            ids.put(arena, arena.dupe(u8, s.id) catch continue, {}) catch continue;
        }
        usable = ids;
    }

    const decided = policy.decideAttempt(.{
        .dial = res.dial,
        .session_present = sessionPresent(arena, link, usable),
        .manual = res.manual,
    });
    switch (decided.action) {
        .swap => |s| {
            const fresh = res.dialed orelse return failAttempt(link);
            if (applySwap(arena, link, fresh, usable, s.fresh_session)) {
                res.dialed = null; // the link owns it now
            } else failAttempt(link);
        },
        .retry => failAttempt(link),
        .terminal => {
            log.warn("remote reconnect: {s} is terminal after attempt {d} ({s})", .{
                name(link), rc.attempt, @tagName(decided.outcome),
            });
            goTerminal(link, policy.terminalStateFor(decided.outcome));
        },
    }
}

/// Tri-state: whether the agent that answered still owns a session one of
/// `link`'s panes holds. Null when the roster never landed.
fn sessionPresent(arena: std.mem.Allocator, link: *RemoteLink.Link, usable: ?std.StringHashMapUnmanaged(void)) ?bool {
    const u = usable orelse return null;
    for (panesOn(arena, link)) |p| {
        const sid = p.surface.agentSessionId() orelse continue;
        if (u.contains(sid)) return true;
    }
    return false;
}

// =============================================================================
// The swap
// =============================================================================

/// Point `link` at `fresh`, replace every pane riding it in place, and only
/// then retire the old transport. True when the link adopted `fresh`.
fn applySwap(
    arena: std.mem.Allocator,
    link: *RemoteLink.Link,
    fresh: RemoteLink.Dialed,
    usable: ?std.StringHashMapUnmanaged(void),
    fresh_session: bool,
) bool {
    const rc = &link.reconnect;
    var guard: policy.SwapGuard = .{};

    // Collect first: each replacement swaps the tree being walked.
    const panes = panesOn(arena, link);
    if (panes.len == 0) {
        guard.onAbandoned();
        return false;
    }

    // The link's transport moves first: every replacement reads it when its
    // core is built, which for a pane in a tab nobody shows is later.
    const old = link.dialed;
    link.dialed = fresh;

    var rebuilt: usize = 0;
    var fresh_count: usize = 0;
    for (panes) |p| {
        const attached = replacePane(arena, link, p, usable, fresh_session) catch |err| {
            log.warn("remote reconnect: pane {s} could not be rebuilt err={}", .{ p.surface.paneId(), err });
            continue;
        };
        rebuilt += 1;
        if (!attached) fresh_count += 1;
    }

    if (rebuilt == 0) {
        // Nothing rides the new transport; the old one still knows these
        // sessions. Put it back and count a failed attempt.
        link.dialed = old;
        guard.onAbandoned();
        log.warn("remote reconnect: rebuild produced no panes for {s}; keeping the old transport", .{name(link)});
        return false;
    }
    guard.onAttached();

    // ONLY NOW may the old transport go (kept, never freed).
    std.debug.assert(guard.mayRetireOld());
    link.dialed = old;
    link.replaceTransport(fresh);
    guard.onRetired();
    watch(link);

    rc.attempt = 0;
    rc.due_ms = 0;
    rc.manual = false;
    setLadder(link, .connected);
    // Not a reset: a swap is not yet proof of recovery (the breaker judges
    // it if this link dies again).
    rc.breaker.onSwapCompleted(std.time.milliTimestamp());

    log.info("remote reconnect: {s} is back on a fresh transport ({d} pane(s) re-attached, {d} opened fresh)", .{
        name(link), rebuilt - fresh_count, fresh_count,
    });
    return true;
}

/// Build `p`'s replacement on `link` and swap it in. True when it re-ATTACHes
/// its session, false when it opens a fresh shell.
fn replacePane(
    arena: std.mem.Allocator,
    link: *RemoteLink.Link,
    p: Pane,
    usable: ?std.StringHashMapUnmanaged(void),
    fresh_session: bool,
) !bool {
    const old = p.surface;
    // A fresh-session swap re-ATTACHes nothing, uniformly (win32's empty
    // attach set). Otherwise a session the agent no longer has opens fresh.
    const sid: ?[]const u8 = if (fresh_session) null else if (old.agentSessionId()) |id| sid: {
        if (usable) |u| if (!u.contains(id)) break :sid null;
        break :sid try arena.dupe(u8, id);
    } else null;
    const pane_id = try arena.dupe(u8, old.paneId());
    const pane_name: ?[]const u8 = if (old.ipcName()) |nm| try arena.dupe(u8, nm) else null;
    const title: ?[:0]const u8 = if (old.titleOverride()) |t| try arena.dupeZ(u8, t) else null;
    const banner: ?[]const u8 = if (old.getPaneBanner()) |b| try arena.dupe(u8, b) else null;
    const opened = old.remoteOpenValues();
    const shell: ?[]const u8 = if (opened.shell) |v| try arena.dupe(u8, v) else null;
    const cwd: ?[]const u8 = if (opened.working_directory) |v| try arena.dupe(u8, v) else null;

    Surface.pending_restore = .{
        .pane_id = pane_id,
        .banner = banner,
        .tint = old.backgroundTint(),
    };
    RemoteLink.pending_open = .{
        .link = link,
        .session_id = sid,
        // Only a fresh shell reads these; an ATTACH resumes the session's own.
        .shell = shell,
        .working_directory = cwd,
    };
    const replacement = Surface.new(.{});
    Surface.pending_restore = null;
    RemoteLink.pending_open = null;
    defer replacement.unref();
    _ = replacement.refSink();

    if (pane_name) |nm| replacement.setIpcName(nm);
    if (title) |t| replacement.setTitleOverride(t);

    // Spare BEFORE the swap: the swap may drop the last reference to `old`.
    old.spareSession();
    if (!try p.split.replaceSurface(old, replacement)) return error.NotInTree;
    return sid != null;
}
