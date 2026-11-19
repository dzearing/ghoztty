//! The shape of a big launch restore (T1163, decision D102) — which window
//! comes back first, and how the rest follow.
//!
//! Before this, a launch rebuilt every saved window in one burst, in whatever
//! order the manifest and the agent's layout store happened to list them. A
//! user who keeps a dozen persistent terminals got a dozen windows at once, and
//! the one they had been working in was not necessarily the one in front.
//!
//! The user's answer to D102 (2026-10-26): **the last-focused window first, the
//! rest a moment later, one at a time.** So:
//!
//!   * Every captured window records when it was last brought to the front
//!     (`session_layout.Window.last_focused_ms`). `order` sorts the restore by
//!     that, most recent first. A window with no stamp (an older manifest, a
//!     Mac blob) keeps its listed position after every stamped one, so a file
//!     written before this change restores exactly as it did.
//!   * The launch builds the first window synchronously, so it is on screen and
//!     focused before anything else happens, and hands the rest to a timer that
//!     builds one per `interval_ms`, each shown BEHIND the first.
//!   * `shouldPace` says when to take that path at all: a single window has
//!     nothing to pace, and a restore that is still waiting on the local agent
//!     (the T976 deferred pass) stays one burst so the two mechanisms never
//!     race over the same carried windows.
//!
//! Pure std, no OS imports: the mechanism is `App.restorePass` /
//! `App.tickPacedRestore`; the decisions live here so both test lanes cover
//! them.

const std = @import("std");

/// How long after one restored window the next one is built. "A moment
/// later": long enough that each window visibly arrives on its own and the
/// first one paints and takes input between them, short enough that a dozen
/// windows are all back within a few seconds.
pub const interval_ms: u32 = 200;

/// The debug-build test seam's environment variable (T3216): stretch the gap
/// between paced windows so an acceptance run can land an agent handoff inside
/// the paced restore every time, not one run in two. Never read in a release
/// build (`App.pacedIntervalMs`).
pub const env_interval = "GHOZTTY_RESTORE_PACE_MS";

/// The interval a debug build uses given `env_interval`'s value: a whole
/// number of milliseconds in 50..10000, anything else is the default.
pub fn intervalFromEnv(value: ?[]const u8) u32 {
    const v = value orelse return interval_ms;
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t"), 10) catch return interval_ms;
    if (n < 50 or n > 10_000) return interval_ms;
    return n;
}

test "intervalFromEnv: unset, junk and out-of-range values keep the default" {
    try std.testing.expectEqual(interval_ms, intervalFromEnv(null));
    try std.testing.expectEqual(interval_ms, intervalFromEnv("soon"));
    try std.testing.expectEqual(interval_ms, intervalFromEnv("10"));
    try std.testing.expectEqual(interval_ms, intervalFromEnv("60000"));
    try std.testing.expectEqual(@as(u32, 2500), intervalFromEnv(" 2500 "));
}

/// How long a paced restore waits for the local-agent link to come back after
/// it drops mid-restore (T3216), before it leaves the windows it has not built
/// for the next launch. An update's relaunch meets exactly this: the agent
/// replaces itself (T907 handoff) while the windows are still arriving, and
/// the app's in-place recovery watches the link for 5 s before it re-dials.
/// Long enough to cover that watch and the re-dial with room to spare; short
/// enough that a genuinely gone agent does not hold the pacer for minutes.
pub const link_wait_ms: i64 = 30_000;

/// What one pacer tick does about the agent link (T3216).
pub const LinkStep = enum {
    /// The link the probe was taken on is live: build the next window.
    proceed,
    /// A link is live, but it is not the one the probe describes (the agent
    /// was replaced, or the link dropped and came back): take a fresh probe on
    /// it, then build.
    reprobe,
    /// No live link yet, or a recovery is still running: come back next tick.
    wait,
    /// No live link for `link_wait_ms`: stop, and leave the rest carried.
    give_up,
};

/// `live`: a link that carries requests exists. `same`: it is the one the
/// probe was taken on. `recovering`: an in-place recovery is mid-flight.
/// `waited_ms`: how long this pacer has been waiting, null when it was not.
/// A link that went down and came back on the SAME connection is reprobed
/// too: what the roster said before the drop is about an agent that may since
/// have handed its sessions to a successor.
pub fn linkStep(live: bool, same: bool, recovering: bool, waited_ms: ?i64) LinkStep {
    if (live and !recovering) {
        if (same and waited_ms == null) return .proceed;
        return .reprobe;
    }
    if ((waited_ms orelse 0) >= link_wait_ms) return .give_up;
    return .wait;
}

test "linkStep: a steady link builds the next window" {
    try std.testing.expectEqual(LinkStep.proceed, linkStep(true, true, false, null));
}

test "linkStep: a replaced agent's link is reprobed, never abandoned (T3216)" {
    try std.testing.expectEqual(LinkStep.reprobe, linkStep(true, false, false, null));
    try std.testing.expectEqual(LinkStep.reprobe, linkStep(true, false, false, 6_000));
}

test "linkStep: a link that dropped and came back on the same connection is reprobed" {
    try std.testing.expectEqual(LinkStep.reprobe, linkStep(true, true, false, 1_200));
}

test "linkStep: no link, or a recovery mid-flight, waits inside the budget" {
    try std.testing.expectEqual(LinkStep.wait, linkStep(false, false, false, null));
    try std.testing.expectEqual(LinkStep.wait, linkStep(false, false, false, link_wait_ms - 1));
    try std.testing.expectEqual(LinkStep.wait, linkStep(true, false, true, 2_000));
}

test "linkStep: a link gone for the whole budget gives up" {
    try std.testing.expectEqual(LinkStep.give_up, linkStep(false, false, false, link_wait_ms));
    try std.testing.expectEqual(LinkStep.give_up, linkStep(true, true, true, link_wait_ms + 1));
}

/// Whether the launch should pace the windows it has left to build after the
/// first. `remaining` is how many still need building; `deferred_armed` is
/// whether the T976 deferred pass is waiting on the agent.
pub fn shouldPace(remaining: usize, deferred_armed: bool) bool {
    if (deferred_armed) return false;
    return remaining > 0;
}

/// Fill `out` (len == stamps.len == front.len) with the indices 0..len in
/// restore order: the window marked frontmost first (T3137, Mac 3f772a2f0 -
/// the first window built here is the one in front, so this is Mac's
/// `frontmostLast` for a builder that stacks the rest behind it), then the
/// most recently focused, unstamped windows after every stamped one in their
/// original order. Stable, so equal keys keep their listed order. The
/// frontmost mark is what carries "in front" across lineages: a Mac blob has
/// no stamp, only the mark.
pub fn order(stamps: []const ?i64, front: []const bool, out: []usize) void {
    std.debug.assert(out.len == stamps.len and front.len == stamps.len);
    for (out, 0..) |*o, i| o.* = i;
    std.sort.insertion(usize, out, Keys{ .stamps = stamps, .front = front }, lessThan);
}

/// Fill `out` (len == front.len) with the indices 0..len for a builder where
/// the LAST window built ends in front (Restore All, which activates each
/// window it builds): as listed, with the frontmost-marked window moved to the
/// end. Mac's `SessionLayoutManifest.frontmostLast`, verbatim.
pub fn frontmostLast(front: []const bool, out: []usize) void {
    std.debug.assert(out.len == front.len);
    var n: usize = 0;
    for (front, 0..) |f, i| if (!f) {
        out[n] = i;
        n += 1;
    };
    for (front, 0..) |f, i| if (f) {
        out[n] = i;
        n += 1;
    };
}

const Keys = struct { stamps: []const ?i64, front: []const bool };

fn lessThan(keys: Keys, a: usize, b: usize) bool {
    if (keys.front[a] != keys.front[b]) return keys.front[a];
    const sa = keys.stamps[a];
    const sb = keys.stamps[b];
    if (sa == null) return false; // unstamped never sorts ahead of anything
    if (sb == null) return true; // stamped sorts ahead of unstamped
    return sa.? > sb.?;
}

/// The stamp a captured window records: the moment it was last activated, or
/// nothing if it never was (0 is the field's "never" value on a live window).
pub fn recordedStamp(last_activated_ms: i64) ?i64 {
    return if (last_activated_ms > 0) last_activated_ms else null;
}

/// The stamp a rebuilt window carries forward. A window that was activated
/// while being rebuilt (the first one) keeps that newer moment; one shown in
/// the background keeps the stamp it was saved with, so a launch that nobody
/// touches restores in the same order next time.
pub fn carriedStamp(current_ms: i64, saved: ?i64) i64 {
    return @max(current_ms, saved orelse 0);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "T1163: the most recently focused window restores first" {
    const stamps = [_]?i64{ 100, 300, 200 };
    var out: [3]usize = undefined;
    order(&stamps, &noFront(stamps.len), &out);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, &out);
}

test "T1163: unstamped windows keep their listed order, after every stamped one" {
    const stamps = [_]?i64{ null, 50, null, 70, null };
    var out: [5]usize = undefined;
    order(&stamps, &noFront(stamps.len), &out);
    try testing.expectEqualSlices(usize, &.{ 3, 1, 0, 2, 4 }, &out);
}

test "T1163: a manifest written before the stamp existed restores in listed order" {
    const stamps = [_]?i64{ null, null, null };
    var out: [3]usize = undefined;
    order(&stamps, &noFront(stamps.len), &out);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &out);
}

test "T1163: equal stamps keep their listed order" {
    const stamps = [_]?i64{ 5, 9, 5, 9 };
    var out: [4]usize = undefined;
    order(&stamps, &noFront(stamps.len), &out);
    try testing.expectEqualSlices(usize, &.{ 1, 3, 0, 2 }, &out);
}

test "T1163: an empty restore orders nothing" {
    var out: [0]usize = .{};
    order(&.{}, &.{}, &out);
}

test "T1163: pacing needs something left to pace, and never races the deferred pass" {
    try testing.expect(shouldPace(3, false));
    try testing.expect(!shouldPace(0, false));
    try testing.expect(!shouldPace(3, true));
}

test "T1163: a never-activated window records no stamp" {
    try testing.expectEqual(@as(?i64, null), recordedStamp(0));
    try testing.expectEqual(@as(?i64, 1234), recordedStamp(1234));
}

test "T1163: a rebuilt window keeps whichever stamp is newer" {
    try testing.expectEqual(@as(i64, 500), carriedStamp(0, 500));
    try testing.expectEqual(@as(i64, 900), carriedStamp(900, 500));
    try testing.expectEqual(@as(i64, 0), carriedStamp(0, null));
}

test "T1163: the pacing interval is a moment, not a wait" {
    try testing.expect(interval_ms >= 100 and interval_ms <= 500);
}

fn noFront(comptime n: usize) [n]bool {
    return [_]bool{false} ** n;
}

test "T3137: the window that was in front restores first, ahead of every stamp" {
    const stamps = [_]?i64{ 100, 300, null };
    const front = [_]bool{ false, false, true };
    var out: [3]usize = undefined;
    order(&stamps, &front, &out);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, &out);
}

test "T3137: a Mac blob (no stamps) restores its frontmost window first, the rest as listed" {
    const stamps = [_]?i64{ null, null, null, null };
    const front = [_]bool{ false, true, false, false };
    var out: [4]usize = undefined;
    order(&stamps, &front, &out);
    try testing.expectEqualSlices(usize, &.{ 1, 0, 2, 3 }, &out);
}

test "T3137: frontmostLast moves the front window to the end and keeps the rest as listed" {
    var out: [3]usize = undefined;
    frontmostLast(&.{ true, false, false }, &out);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, &out);
    // Mac's withNoFrontmostTheOrderIsAsWritten.
    frontmostLast(&.{ false, false, false }, &out);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &out);
}
