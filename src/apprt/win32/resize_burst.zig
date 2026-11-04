//! Submit a window-edge drag step's content in one burst, clear of DWM's
//! latch (T2666).
//!
//! T2659 measured why the terminal and the viewer's bar reach the screen on a
//! different compose from the window frame: DWM takes whatever was submitted
//! by a latch about 3.4 ms before each compose, and anything later waits a
//! whole compose. With T2578's pre-layout the terminal presents ~4.8 ms
//! BEFORE the frame change, so a latch falls between them about half the time
//! (content one compose early); without it the present comes ~9 ms after
//! (content one compose late).
//!
//! The fix keeps the drawing early - in `WM_WINDOWPOSCHANGING`, where the new
//! rect is known - but holds every pane's swap until the end of that message,
//! right before the frame changes, and releases them together. When a latch
//! would fall inside that burst it is waited out first, so the burst and the
//! frame change land in the same latch period. `GHOZTTY_RESIZE_BURST` turns it
//! on; a film decides whether it becomes the default.
//!
//! The arithmetic is here, free of win32, for the `none` lane. The compose
//! clock it reads is `DCompositionGetStatistics`' target vblank and period, in
//! QPC ticks (`DwmGetCompositionTimingInfo` cannot serve: its counters move
//! per call on this box, `comp_spike_main.zig`).

const std = @import("std");

/// How long before a compose DWM stops taking submissions for it, in
/// microseconds. Measured on 2026-11-03 at 120 Hz (T2659): a frame change
/// 3.55 ms ahead made its compose, 3.15 ms did not; a present 6.8 ms ahead
/// made it, 3.46 ms did not.
pub const latch_lead_us: u64 = 3400;

/// How long the burst takes from its first submission to the frame change,
/// in microseconds: the bar paint, the released swaps and the rest of
/// `SetWindowPos`. A latch closer than this is waited out.
pub const burst_span_us: u64 = 1500;

/// Past the latch by this much before submitting, so a burst that was
/// waiting for it does not land on its edge.
pub const latch_margin_us: u64 = 250;

/// The longest a renderer holds a drawn frame waiting for the release, in
/// milliseconds. Past it the frame is swapped anyway: a release that never
/// comes (the step was abandoned, the window went away) costs one frame's
/// timing, never a stuck pane.
/// Covers a frame that reached its hold first and then sat through the whole
/// gather, the latch step and the bar paint.
pub const hold_timeout_ms: u32 = 16;

/// The longest the UI thread waits, in microseconds, for every armed pane's
/// renderer to reach its hold before the release. Since T2623 an edge drag
/// holds the grid, so nothing else in the pass waited for these frames; this
/// is that wait, kept under one 120 Hz compose so a slow pane costs a step's
/// sync, never the drag's rate.
pub const gather_us: u64 = 6000;

/// Whether a pane has nothing left to gather for the burst: no hold armed
/// (`hold` 0), or its renderer is already waiting in the hold with exactly
/// the held size drawn (`waiting`, 0 while it is not waiting).
pub fn gathered(hold: u64, waiting: u64) bool {
    return hold == 0 or waiting == hold;
}

/// The longest the UI thread waits after the release for the held swaps to
/// have gone through, in microseconds.
pub const settle_us: u64 = 3000;

/// QPC ticks in `us` microseconds at `freq` ticks per second.
pub fn ticks(us: u64, freq: u64) u64 {
    return us * freq / std.time.us_per_s;
}

/// The compose clock as last read: a compose's target time and the period
/// between composes, in QPC ticks.
pub const Clock = struct {
    target: i64,
    period: i64,
};

/// How long to wait, in QPC ticks, before starting a burst at `now` that
/// spans `span` ticks, so that no latch (`lead` ticks before a compose) falls
/// inside it. Zero when the next latch is clear of the burst - or when the
/// clock is unknown, since a guess would only add a wait.
pub fn latchWait(now: i64, clock: ?Clock, lead: i64, span: i64, margin: i64) i64 {
    const c = clock orelse return 0;
    if (c.period <= 0 or lead < 0 or span <= 0) return 0;
    // The first latch at or after `now`: composes are `target + k*period` for
    // every integer k, and each one's latch is `lead` before it. `target` may
    // be in the past (the usual case) or ahead of `now`.
    const first = c.target - lead;
    const k = std.math.divCeil(i64, now - first, c.period) catch return 0;
    const latch = first + k * c.period;
    const until = latch - now;
    if (until >= span) return 0;
    return until + margin;
}

const testing = std.testing;

// 120 Hz at a 10 MHz QPC: 83_333 ticks a t_period, t_lead 34_000, t_span 15_000.
const t_period: i64 = 83_333;
const t_lead: i64 = 34_000;
const t_span: i64 = 15_000;
const t_margin: i64 = 2_500;

test "ticks converts microseconds at the counter's frequency" {
    try testing.expectEqual(@as(u64, 34_000), ticks(latch_lead_us, 10_000_000));
    try testing.expectEqual(@as(u64, 15_000), ticks(burst_span_us, 10_000_000));
}

test "a latch well ahead of the burst is not waited for" {
    // The compose targets t=1_000_000, its latch at 966_000; now 900_000 is
    // 66_000 ticks before it, far more than the burst needs.
    const c: Clock = .{ .target = 1_000_000, .period = t_period };
    try testing.expectEqual(@as(i64, 0), latchWait(900_000, c, t_lead, t_span, t_margin));
}

test "a latch inside the burst is waited out, plus the t_margin" {
    const c: Clock = .{ .target = 1_000_000, .period = t_period };
    // 10_000 ticks before the latch at 966_000: the burst would straddle it.
    try testing.expectEqual(@as(i64, 10_000 + t_margin), latchWait(956_000, c, t_lead, t_span, t_margin));
    // Exactly on the latch: wait only the t_margin.
    try testing.expectEqual(@as(i64, t_margin), latchWait(966_000, c, t_lead, t_span, t_margin));
}

test "a target in the past projects forward by whole periods" {
    // The last compose read was ten periods ago; the latch it implies now is
    // at 1_000_000 + 10 * period - lead.
    const c: Clock = .{ .target = 1_000_000, .period = t_period };
    const latch: i64 = 1_000_000 + 10 * t_period - t_lead;
    try testing.expectEqual(@as(i64, 5_000 + t_margin), latchWait(latch - 5_000, c, t_lead, t_span, t_margin));
    try testing.expectEqual(@as(i64, 0), latchWait(latch - t_span, c, t_lead, t_span, t_margin));
    // Just past a latch: the next one is a whole period away.
    try testing.expectEqual(@as(i64, 0), latchWait(latch + 1, c, t_lead, t_span, t_margin));
}

test "a target ahead of now is handled the same way" {
    const c: Clock = .{ .target = 2_000_000, .period = t_period };
    // The latch one t_period before that compose is 2_000_000 - t_period - t_lead.
    const latch: i64 = 2_000_000 - t_period - t_lead;
    try testing.expectEqual(@as(i64, 1 + t_margin), latchWait(latch - 1, c, t_lead, t_span, t_margin));
}

test "a pane is gathered once its renderer waits at the held size" {
    const size: u64 = (@as(u64, 800) << 32) | 600;
    const old: u64 = (@as(u64, 780) << 32) | 600;
    // Nothing armed: nothing to wait for.
    try testing.expect(gathered(0, 0));
    try testing.expect(gathered(0, old));
    // Armed and the renderer still drawing: not yet.
    try testing.expect(!gathered(size, 0));
    // Waiting, but at a stale size: not the frame the burst wants.
    try testing.expect(!gathered(size, old));
    try testing.expect(gathered(size, size));
}

test "a held frame outlasts the gather plus the latch step" {
    try testing.expect(@as(u64, hold_timeout_ms) * 1000 > gather_us + burst_span_us + latch_margin_us);
}

test "no clock, or a nonsense one, never adds a wait" {
    try testing.expectEqual(@as(i64, 0), latchWait(5, null, t_lead, t_span, t_margin));
    try testing.expectEqual(@as(i64, 0), latchWait(5, .{ .target = 10, .period = 0 }, t_lead, t_span, t_margin));
    try testing.expectEqual(@as(i64, 0), latchWait(5, .{ .target = 10, .period = -4 }, t_lead, t_span, t_margin));
}

test "the wait never exceeds the burst span plus the margin" {
    const c: Clock = .{ .target = 123_456, .period = t_period };
    var now: i64 = 0;
    while (now < 3 * t_period) : (now += 997) {
        const w = latchWait(now, c, t_lead, t_span, t_margin);
        try testing.expect(w >= 0);
        try testing.expect(w <= t_span + t_margin);
    }
}
