//! Deferred launch-restore policy (T976) — when the launch restore ran before
//! the local agent was dialable, this decides whether to try again, when, and
//! when to stop.
//!
//! The mechanism lives in `App.zig` (`tickRestoreRetry`); the DECISIONS live
//! here, pure, so they are unit-testable in both app-runtime lanes without a
//! live agent — the same split `agent_recovery.zig` uses for T145/T723.
//!
//! Why it exists: `LocalAgent.findOrSpawn` gives a freshly spawned agent
//! `spawn_deadline_ms` (2s) to bind its pipe, and the launch restore treats
//! that one answer as final. Every window whose panes need an ATTACH is then
//! left unrestored and carried to the NEXT launch (T590), so a box that is
//! merely BUSY at logon — a login storm, a cold disk, twenty recorded sessions
//! for the agent to re-materialize — comes back to a blank terminal and the
//! user has to relaunch to get their layout. That is the same symptom T975
//! fixed from a different cause, and fixing the causes one at a time cannot
//! close it: the restore has to stop being a one-shot decision.
//!
//! The shape is short-then-patient, and BOUNDED at both ends:
//!
//!   * Early attempts are close together, because the overwhelmingly common
//!     case is an agent that was seconds late — the windows should appear
//!     while the user is still looking at the launch, not after they have
//!     started working around it.
//!   * Later attempts back off to 5s, because the remaining case is a box
//!     under real load and polling it faster neither helps nor is free.
//!   * The schedule RUNS OUT (`retryDelayMs` returns null). An agent that has
//!     not come up in ~55s is not late, it is broken or absent, and windows
//!     materializing minutes into a session would be worse than the blank
//!     terminal: the carried entries stay carried, exactly as they do today,
//!     and the next launch restores them.

const std = @import("std");

/// Backoff schedule for completing a launch restore that ran too early. One
/// entry per retry, in order; running off the end is the give-up point.
///
/// Sums to 55s of wall clock. Each tick costs one FIND-ONLY dial of the
/// agent's recorded pipe (`LocalAgent.adoptIfUp` — never a spawn), which fails
/// immediately while no pipe exists, so an absent agent is polled for free.
pub const retry_delays_ms = [_]u32{
    500,   500,   1000,  1000, 2000, 2000, 3000, 5000,
    5_000, 5_000, 5_000, 5000, 5000, 5000, 5000, 5000,
};

/// The delay before retry number `attempt` (0-based), or null when the
/// schedule is spent.
pub fn retryDelayMs(attempt: usize) ?u32 {
    if (attempt >= retry_delays_ms.len) return null;
    return retry_delays_ms[attempt];
}

/// Total wall clock the schedule covers, for the log line that announces it.
pub fn budgetMs() u64 {
    var total: u64 = 0;
    for (retry_delays_ms) |d| total += d;
    return total;
}

/// Whether a finished launch restore should arm the deferred pass at all.
///
/// `pending` is how many manifest windows the launch carried forward;
/// `adjudicated` is its `positively_adjudicated` — the agent answered AND the
/// roster probe landed. An adjudicated launch already knows everything there
/// is to know about those windows (they are held by another running instance,
/// or their build failed), and neither is cured by waiting for an agent that
/// is already there.
///
/// `unasked` is true when the launch never reached the agent at all, so it
/// never pulled the agent's layout blobs (T1002). A window that exists ONLY
/// there — the crash-orphaned window T194 recovers — was then never offered,
/// and it is not in `pending` because nothing on this side knows its key. That
/// is unfinished work even with `pending` at zero: it is the headline T194
/// shape (a crash left the manifest empty) meeting a late agent.
pub fn shouldArm(pending: usize, adjudicated: bool, unasked: bool) bool {
    if (adjudicated) return false;
    return pending > 0 or unasked;
}

/// What one retry tick should do.
pub const Verdict = enum {
    /// The agent is reachable now — rebuild the carried windows.
    restore,
    /// Still no agent, and the schedule has room: arm the next tick.
    retry,
    /// Nothing is waiting to be restored (a later launch-time write, a config
    /// reload that turned persistence off). Disarm without a complaint.
    stand_down,
    /// The schedule ran out with the agent still unreachable.
    exhausted,
};

/// The tick decision. `attempt` is the 0-based index of the retry that is
/// about to be armed, i.e. how many have already been spent. `unasked` is
/// `shouldArm`'s: the agent's own layout store has not been read yet, so there
/// is something to wait for even when no manifest window was carried.
pub fn evaluate(pending: usize, unasked: bool, agent_up: bool, attempt: usize) Verdict {
    if (pending == 0 and !unasked) return .stand_down;
    if (agent_up) return .restore;
    if (retryDelayMs(attempt) == null) return .exhausted;
    return .retry;
}

test "retry schedule: bounded, present from the first attempt, and it runs out" {
    const testing = std.testing;

    // Every scheduled attempt has a delay…
    for (0..retry_delays_ms.len) |i| {
        try testing.expect(retryDelayMs(i) != null);
    }
    // …and the one past the end does not. That null IS the give-up point, so a
    // schedule that never ended would poll an absent agent for the life of the
    // app.
    try testing.expectEqual(@as(?u32, null), retryDelayMs(retry_delays_ms.len));
    try testing.expectEqual(@as(?u32, null), retryDelayMs(retry_delays_ms.len + 99));

    // Short-then-patient: the first attempt is sub-second and no attempt ever
    // gets shorter than one before it.
    try testing.expect(retryDelayMs(0).? <= 500);
    var prev: u32 = 0;
    for (retry_delays_ms) |d| {
        try testing.expect(d >= prev);
        prev = d;
    }

    // The budget is long enough for a loaded box and short enough that windows
    // never materialize minutes into a session.
    try testing.expect(budgetMs() >= 30_000);
    try testing.expect(budgetMs() <= 90_000);
}

test "shouldArm: only an unadjudicated launch with something left to restore" {
    const testing = std.testing;

    // The T976 case: windows carried because no agent answered.
    try testing.expect(shouldArm(3, false, true));
    try testing.expect(shouldArm(3, false, false));

    // Nothing carried, and the agent's store WAS read ⇒ the launch restored
    // everything it was offered.
    try testing.expect(!shouldArm(0, false, false));

    // T1002: nothing carried, but the launch never reached the agent, so the
    // windows only the agent remembers were never offered. That is the
    // crash-with-an-empty-manifest shape, and it is the one worth waiting for.
    try testing.expect(shouldArm(0, false, true));

    // The agent answered and the probe landed: those windows are held by
    // another instance or failed to build, and no amount of waiting changes
    // either. Arming here would re-probe a healthy agent 16 times for nothing.
    try testing.expect(!shouldArm(3, true, false));
    try testing.expect(!shouldArm(0, true, false));
}

test "evaluate: the agent arriving wins over the schedule, and an empty set stands down" {
    const testing = std.testing;

    // Agent up ⇒ restore, whatever the attempt count says.
    try testing.expectEqual(Verdict.restore, evaluate(2, false, true, 0));
    try testing.expectEqual(Verdict.restore, evaluate(2, false, true, retry_delays_ms.len - 1));

    // Still down, room left ⇒ keep waiting.
    try testing.expectEqual(Verdict.retry, evaluate(2, false, false, 0));
    try testing.expectEqual(Verdict.retry, evaluate(2, false, false, retry_delays_ms.len - 1));

    // Still down, schedule spent ⇒ give up (the carried entries survive to the
    // next launch; that is the pre-T976 behaviour, reached later instead of
    // immediately).
    try testing.expectEqual(Verdict.exhausted, evaluate(2, false, false, retry_delays_ms.len));

    // Nothing pending is never a complaint, in either link state.
    try testing.expectEqual(Verdict.stand_down, evaluate(0, false, false, 0));
    try testing.expectEqual(Verdict.stand_down, evaluate(0, false, true, 0));
    try testing.expectEqual(Verdict.stand_down, evaluate(0, false, false, retry_delays_ms.len));

    // T1002: an unread agent store is something to wait for on its own — an
    // empty carried set with the agent never asked still restores on arrival,
    // retries while it is absent, and gives up when the schedule runs out.
    try testing.expectEqual(Verdict.restore, evaluate(0, true, true, 3));
    try testing.expectEqual(Verdict.retry, evaluate(0, true, false, 0));
    try testing.expectEqual(Verdict.exhausted, evaluate(0, true, false, retry_delays_ms.len));
}
