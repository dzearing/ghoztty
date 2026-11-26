//! How often a pane may present, by how much anybody is looking at it (T3761).
//!
//! A terminal pane woken by output builds and presents a frame per wakeup,
//! and a busy program's output arrives in many small chunks: T3740 measured a
//! pane printing ~12 lines a second presenting ~50 frames a second, each one
//! costing its renderer thread and the GPU driver's. That is right for the
//! window somebody is using and wasted on the other forty-nine windows of a
//! cascade, where each shows a strip: 50 such windows kept ~11 cores busy.
//!
//! So the apprt tells each pane its window's `Pace`:
//!
//! - `full`: the window in use (activated and seen). No cap, as before.
//! - `background`: another window, mostly on view. Capped at `background_ms`
//!   (20 fps) - output still reads as live to someone glancing across.
//! - `glimpse`: another window of which only a sliver shows (under
//!   `glimpse_permille` of its client area). Capped at `glimpse_ms` (4 fps),
//!   the rate low-power mode already gives an unfocused pane.
//!
//! Hidden panes are not drawn at all, in every mode (`visible`); a pace says
//! how often a pane somebody CAN see draws. A frame that something forces
//! (resize, focus, config, a repaint, the pace change itself) is never held
//! back, and held output is never lost: the pane renders once at the cap with
//! everything that arrived in between. Low-power mode (T1951) still applies on
//! top; the stricter of the two caps wins.
//!
//! Pure, with no OS imports, so its tests run in every app-runtime lane.

const std = @import("std");
const low_power = @import("low_power.zig");

pub const Pace = enum(u8) { full, background, glimpse };

/// A background window's panes present at most this often (20 fps).
pub const background_ms: u64 = 50;
/// A barely visible background window's panes present at most this often
/// (4 fps).
pub const glimpse_ms: u64 = 250;
/// Below this share of its client area on view, in thousandths, a background
/// window is a glimpse.
pub const glimpse_permille: u16 = 250;

/// The pace of a window: in use, or how much of it is on view.
pub fn ofWindow(in_use: bool, seen_permille: u16) Pace {
    if (in_use) return .full;
    return if (seen_permille < glimpse_permille) .glimpse else .background;
}

/// The minimum spacing between this pane's output-driven frames, or null for
/// none.
pub fn capMs(low_power_on: bool, focused: bool, pace: Pace) ?u64 {
    const lp: u64 = if (!low_power_on) 0 else if (focused) low_power.focused_ms else low_power.unfocused_ms;
    const pc: u64 = switch (pace) {
        .full => 0,
        .background => background_ms,
        .glimpse => glimpse_ms,
    };
    const cap = @max(lp, pc);
    return if (cap == 0) null else cap;
}

/// How long a renderer woken by new output should wait before building and
/// presenting a frame, or null to do it now. `since_last_ns` is the time since
/// this pane last built a frame (null: never, or no clock).
pub fn deferMs(cap_ms: ?u64, forced: bool, since_last_ns: ?u64) ?u64 {
    const cap = cap_ms orelse return null;
    if (forced) return null;
    const since = since_last_ns orelse return null;
    const cap_ns = cap * std.time.ns_per_ms;
    if (since >= cap_ns) return null;
    return @max((cap_ns - since) / std.time.ns_per_ms, 1);
}

const testing = std.testing;

test "pace: the window in use is never capped, whatever is on view" {
    try testing.expectEqual(Pace.full, ofWindow(true, 0));
    try testing.expectEqual(Pace.full, ofWindow(true, 1000));
    try testing.expectEqual(@as(?u64, null), capMs(false, true, .full));
    try testing.expectEqual(@as(?u64, null), capMs(false, false, .full));
}

test "pace: another window is a glimpse below a quarter on view" {
    try testing.expectEqual(Pace.glimpse, ofWindow(false, 0));
    try testing.expectEqual(Pace.glimpse, ofWindow(false, 249));
    try testing.expectEqual(Pace.background, ofWindow(false, 250));
    try testing.expectEqual(Pace.background, ofWindow(false, 1000));
}

test "pace: background panes cap at 20 fps, glimpsed ones at 4" {
    try testing.expectEqual(@as(?u64, 50), capMs(false, true, .background));
    try testing.expectEqual(@as(?u64, 250), capMs(false, true, .glimpse));
}

test "pace: the stricter of low power and pace wins" {
    // Low power alone, as T1951 had it.
    try testing.expectEqual(@as(?u64, 33), capMs(true, true, .full));
    try testing.expectEqual(@as(?u64, 250), capMs(true, false, .full));
    // A focused low-power pane in a background window takes the pace's 50.
    try testing.expectEqual(@as(?u64, 50), capMs(true, true, .background));
    // An unfocused one keeps low power's 250 over the pace's 50.
    try testing.expectEqual(@as(?u64, 250), capMs(true, false, .background));
    try testing.expectEqual(@as(?u64, 250), capMs(true, true, .glimpse));
}

test "pace: deferMs holds output inside the cap and never for a forced or first frame" {
    const ms = std.time.ns_per_ms;
    try testing.expectEqual(@as(?u64, null), deferMs(null, false, 0));
    try testing.expectEqual(@as(?u64, null), deferMs(50, true, 0));
    try testing.expectEqual(@as(?u64, null), deferMs(50, false, null));
    try testing.expectEqual(@as(?u64, 40), deferMs(50, false, 10 * ms));
    try testing.expectEqual(@as(?u64, null), deferMs(50, false, 50 * ms));
    try testing.expectEqual(@as(?u64, 240), deferMs(250, false, 10 * ms));
    // Never a zero-length timer.
    try testing.expectEqual(@as(?u64, 1), deferMs(50, false, 50 * ms - 1));
}

test "pace: it agrees with low power's own cap when pace adds nothing" {
    const ms = std.time.ns_per_ms;
    inline for (.{ true, false }) |focused| {
        inline for (.{ 0, 10, 33, 100, 250 }) |since| {
            try testing.expectEqual(
                low_power.deferMs(true, focused, false, since * ms),
                deferMs(capMs(true, focused, .full), false, since * ms),
            );
        }
    }
}
