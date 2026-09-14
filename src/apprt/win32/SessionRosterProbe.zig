//! The machine chooser's PUSHED session roster (T710) — the win32 half of Mac's
//! `SessionBrowserProbe.subscribeLocalPush` (`bf318f55b`).
//!
//! ## Why a subscription at all
//! The roster the chooser draws was a photograph: fetched when a machine is
//! selected and never again. Start a session elsewhere, finish one, close one,
//! attach to one — the list keeps saying what was true at selection time until
//! the user clicks away and back. Mac hit the same wall from the other side (a
//! 2s poll, as stale as its last tick and silently frozen if a completion could
//! not be delivered) and the agent grew a PUSH for both of us: it sends the
//! roster whenever it CHANGES, and one immediately on subscribe so a subscriber
//! starts from truth rather than waiting for the first change.
//!
//! ## One decode path
//! The pushed payload is the same `SESSIONS` frame a `LIST_SESSIONS` reply
//! carries, so it is decoded by the same `remote_connection.decodeSessions` the
//! fetch worker uses and adopted by the same `SessionRoster.adopt*` bookkeeping.
//! A pushed roster and a fetched one are indistinguishable downstream, which is
//! the property that keeps the two from drifting apart.
//!
//! ## One subscription at a time
//! Like `SessionCpuProbe`, this follows the SELECTED machine and nothing else:
//! moving the selection tears the old subscription down before starting the new
//! one, and closing the chooser guarantees no stream — and no borrowed
//! connection — outlives the dialog.
//!
//! ## Whose connection
//! Never its own. The LOCAL agent's warm shared connection (borrowed; browsing
//! must never SPAWN an agent, so no warm connection simply means no pushes), or
//! the one warm connection `MachineConnectionPool` holds for the chooser's lease
//! (T461).
//!
//! ## Degrading against an older agent
//! `Connection.subscribeSessions` returns `error.Unsupported` when the peer never
//! advertised `capability.sessions_push` — an unknown opcode is a FATAL framing
//! error to an older agent, so the gate is what keeps a working connection alive
//! rather than politeness. Unsupported ⇒ no stream, and the chooser is exactly
//! what it was before this file existed: correct, just not live.

const SessionRosterProbe = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const remote_connection = @import("../../remote/connection.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Posted to the app's message-only window when a pushed roster landed:
/// `wparam` = the chooser id it belongs to. The roster itself is parked in
/// `pending` rather than travelling in the message, so a burst of pushes
/// coalesces into "there is something newer to take" instead of a queue of
/// heap rosters.
///
/// It lands on the MESSAGE-ONLY window and is routed by chooser id, exactly as
/// the roster's fetch reply and the CPU stream are: a chooser that closed first
/// would have a message aimed at its own HWND discarded with its queue, and —
/// worse — a posted message aimed at a destroyed HWND whose value was recycled
/// is a message delivered to somebody else's window.
pub const WM_APP_CHOOSER_ROSTER_PUSH: u32 = w32.WM_APP + 36;

alloc: Allocator,

/// The connection the subscription is installed on, or null. BORROWED, always —
/// `LocalAgent` owns the local one for the app's lifetime and the pool owns a
/// machine's for as long as the chooser's lease lives, so this is never freed
/// here. It is nulled the moment either owner says the connection is going away.
conn: ?*remote_connection.Connection = null,

/// The newest pushed roster, decoded and waiting for the GUI thread. Guarded by
/// `mutex`: written from the control-reader thread, taken on the GUI thread.
///
/// Newest wins. A roster is a WHOLE snapshot, so an older one still parked here
/// is not a backlog to work through — it is a stale answer to the same question,
/// and keeping it would make a burst of changes render backwards.
pending: ?remote_connection.OwnedSessions = null,
mutex: std.Thread.Mutex = .{},

/// Where a pushed roster is announced, and who it belongs to. Written once per
/// subscribe and never cleared, for the reason `SessionCpuProbe` documents: the
/// handler reads both from the reader thread, the target is the app's
/// message-only window which outlives every chooser, and a frame that races a
/// teardown posts a chooser id nothing matches and is dropped by the routing.
hwnd: ?w32.HWND = null,
chooser_id: u64 = 0,

/// Whether this machine's roster is SERVED BY PUSHES right now. The chooser
/// reads it to decide whether a refetch would tell it anything a push has not
/// already: an agent too old to push leaves it false and everything behaves as
/// it did before T710.
pub fn live(self: *const SessionRosterProbe) bool {
    return self.conn != null;
}

/// Point the probe at a connection — the selected machine's, or null for "no
/// machine, or one with nothing warm to ride". Idempotent: the same connection
/// twice keeps the live subscription instead of churning it.
///
/// Returns true when the subscription state CHANGED, so the caller knows whether
/// anything about the region moved.
pub fn retarget(
    self: *SessionRosterProbe,
    hwnd: ?w32.HWND,
    chooser_id: u64,
    conn: ?*remote_connection.Connection,
) bool {
    if (self.conn == conn and conn != null) return false;

    const was = self.live();
    self.stop();

    const c = conn orelse return was != self.live();
    const h = hwnd orelse return was != self.live();

    // Publish the identity BEFORE subscribing: the agent sends a roster the
    // instant the subscription is live, and the handler reads both.
    self.hwnd = h;
    self.chooser_id = chooser_id;
    c.subscribeSessions(self, onRoster) catch |err| {
        // `error.Unsupported` is an agent older than the capability, and it is
        // the ordinary case rather than a failure: the chooser keeps the roster
        // it fetched, and nothing about the region changes.
        log.info("chooser roster: no pushed roster from this agent err={}", .{err});
        return was != self.live();
    };
    self.conn = c;
    log.info("chooser roster: subscribed to the pushed roster", .{});
    return was != self.live();
}

/// Drop the subscription and anything parked. Safe when not subscribed, and
/// safe to call from teardown — which is where it MUST be called, before the
/// pool lease is released: the pool may free the connection the moment the last
/// lease goes, and a handler still registered on it would then fire into freed
/// memory.
pub fn stop(self: *SessionRosterProbe) void {
    // Unsubscribe FIRST: `Connection.unsubscribeSessions` guarantees no handler
    // fires after it returns, which is what makes clearing `pending` below safe
    // rather than a race against a reader thread still decoding into it.
    if (self.conn) |c| c.unsubscribeSessions();
    self.conn = null;
    self.clearPending();
}

/// The connection is going away (the pool's link died, or its lease is being
/// released) — forget it WITHOUT touching it. `stop` would write an unsubscribe
/// down a socket whose owner has already decided to free it; the pool notifies
/// its leases before the free precisely so this can happen first.
pub fn forget(self: *SessionRosterProbe) void {
    self.conn = null;
    self.clearPending();
}

fn clearPending(self: *SessionRosterProbe) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    // A parked roster is a statement about ONE agent: handing it to the next
    // machine's rows would list this box's sessions under somebody else's name.
    if (self.pending) |*p| p.deinit();
    self.pending = null;
}

/// GUI thread: take the newest pushed roster, or null when there is none left
/// (a coalesced burst posts more messages than it parks rosters). The caller
/// OWNS what comes back and must `deinit` it.
pub fn take(self: *SessionRosterProbe) ?remote_connection.OwnedSessions {
    self.mutex.lock();
    defer self.mutex.unlock();
    const out = self.pending;
    self.pending = null;
    return out;
}

/// Control-reader thread: one pushed roster. Decodes the BORROWED payload into
/// owned rows — it dies the moment this returns — parks them, and posts. Touches
/// no GUI state (`Connection.SessionsHandler`'s contract).
///
/// A payload we cannot read is dropped with a line, never parked: the rows on
/// screen are a real roster and a malformed frame is not a reason to blank them.
fn onRoster(ctx: *anyopaque, json: []const u8) void {
    const self: *SessionRosterProbe = @ptrCast(@alignCast(ctx));

    const owned = remote_connection.decodeSessions(self.alloc, json) catch |err| {
        log.warn("chooser roster: pushed roster unreadable err={}", .{err});
        return;
    };

    const count = owned.sessions.len;
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending) |*old| old.deinit();
        self.pending = owned;
    }

    // The acceptance oracle: an owner-drawn roster has no HWNDs to read back, so
    // what ARRIVED is said out loud — and said as a PUSH, because "the list is
    // live" and "the list was fetched again" are the two things this task exists
    // to tell apart.
    log.info("chooser roster: pushed {d} session(s)", .{count});

    if (self.hwnd) |h| {
        _ = w32.PostMessageW(h, WM_APP_CHOOSER_ROSTER_PUSH, @intCast(self.chooser_id), 0);
    }
}
