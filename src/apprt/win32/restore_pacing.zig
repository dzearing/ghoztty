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

/// Whether the launch should pace the windows it has left to build after the
/// first. `remaining` is how many still need building; `deferred_armed` is
/// whether the T976 deferred pass is waiting on the agent.
pub fn shouldPace(remaining: usize, deferred_armed: bool) bool {
    if (deferred_armed) return false;
    return remaining > 0;
}

/// Fill `out` (len == stamps.len) with the indices 0..len in restore order:
/// the most recently focused first, unstamped windows after every stamped one
/// in their original order. Stable, so equal stamps keep their listed order.
pub fn order(stamps: []const ?i64, out: []usize) void {
    std.debug.assert(out.len == stamps.len);
    for (out, 0..) |*o, i| o.* = i;
    std.sort.insertion(usize, out, stamps, lessThan);
}

fn lessThan(stamps: []const ?i64, a: usize, b: usize) bool {
    const sa = stamps[a];
    const sb = stamps[b];
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
    order(&stamps, &out);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, &out);
}

test "T1163: unstamped windows keep their listed order, after every stamped one" {
    const stamps = [_]?i64{ null, 50, null, 70, null };
    var out: [5]usize = undefined;
    order(&stamps, &out);
    try testing.expectEqualSlices(usize, &.{ 3, 1, 0, 2, 4 }, &out);
}

test "T1163: a manifest written before the stamp existed restores in listed order" {
    const stamps = [_]?i64{ null, null, null };
    var out: [3]usize = undefined;
    order(&stamps, &out);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, &out);
}

test "T1163: equal stamps keep their listed order" {
    const stamps = [_]?i64{ 5, 9, 5, 9 };
    var out: [4]usize = undefined;
    order(&stamps, &out);
    try testing.expectEqualSlices(usize, &.{ 1, 3, 0, 2 }, &out);
}

test "T1163: an empty restore orders nothing" {
    var out: [0]usize = .{};
    order(&.{}, &out);
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
