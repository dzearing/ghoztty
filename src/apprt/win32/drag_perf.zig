//! T1343: what one splitter-drag motion tick COSTS, and whether the drag the
//! user is watching is smooth or steppy.
//!
//! A divider drag is one `WM_MOUSEMOVE` → `updateDividerDrag` →
//! `layoutSplitsLive` per motion tick, and the whole chain runs on the UI
//! thread, so the tick's wall clock IS the drag's frame time: a tick that
//! costs 60 ms is a drag that moves four times a second no matter how fast the
//! mouse is reporting. The user's 2026-09-04 report ("resizing panes is janky
//! and slow ... it feels so unpolished") was about exactly that number, and
//! nothing had ever measured it.
//!
//! The cost that dominates it is a WAIT, not work: each resized pane blocks
//! the UI thread on its renderer presenting a frame at the new size, so the
//! anti-flicker guarantee is bought once per pane. `serialWaitCeilingUs` and
//! `batchedWaitCeilingUs` below are the two shapes of that bill — the first is
//! what the code did until T1343, the second is what it does now — and the
//! whole point of the fix is that only one of them grows with the pane count.
//!
//! Same split as `layout_cost.zig` beside it: pure arithmetic here, the
//! Windows-facing half (the clock, the event handles, the log line) in
//! `Window.zig`.

const std = @import("std");
const testing = std.testing;

/// One display frame at 60 Hz, in microseconds. A motion tick that fits inside
/// this cannot drop a frame; one that does not is a step the user sees.
pub const frame_budget_us: u64 = 16_667;

/// The per-pane frame wait, in microseconds — `WaitForSingleObject(event, 16)`
/// as `Surface.handleResize` spells it.
pub const frame_wait_ms: u64 = 16;

/// The most `GHOZTTY_PRESENT_LAG_MS` may hold a present back (T1035): half the
/// frame wait, so a lagged frame still lands inside the budget and a wait that
/// times out under the knob is a real miss rather than the knob's own doing.
pub const present_lag_max_ms: u8 = frame_wait_ms / 2;

/// What the frame wait can cost a motion tick when it is paid PER PANE: the
/// pre-T1343 shape, where every resized surface waits its own 16 ms in turn.
/// Linear in the pane count, which is why the drag got worse the more panes
/// were open — the complaint the task was filed from.
pub fn serialWaitCeilingUs(panes: usize) u64 {
    return @as(u64, panes) * frame_wait_ms * std.time.us_per_ms;
}

/// What the same wait costs when the whole layout pass waits ONCE for every
/// pane's frame together (`WaitForMultipleObjects(bWaitAll)`): flat in the
/// pane count, because the panes render in parallel on their own threads and
/// only the serialization of the waiting was ever ours.
pub fn batchedWaitCeilingUs(panes: usize) u64 {
    return if (panes == 0) 0 else frame_wait_ms * std.time.us_per_ms;
}

/// How one frame wait ended (T1035). Three endings, not two: a wait can run
/// out its budget, be WOKEN by a renderer's present, or find the frame already
/// on screen before it ever blocked. Only the second proves the renderer's
/// frame signal reaches the wait — `timed_out == false` alone does not, since
/// "the frame was already there" is also not a timeout, and that is what a
/// wait with its signal unwired looks like whenever the renderer is quick.
pub const WaitOutcome = struct {
    timed_out: bool = false,
    woken: bool = false,
};

/// One motion tick of a divider drag.
pub const Sample = struct {
    /// The whole `updateDividerDrag` call: ratio solve + layout pass + frame
    /// wait. This is the number the drag's smoothness is made of.
    tick_us: u64 = 0,
    /// The part of `tick_us` spent blocked on renderer frames.
    wait_us: u64 = 0,
    /// Panes resized by this tick — the multiplier on the serial shape.
    panes: usize = 0,
    /// How many separate frame WAITS this tick performed. One per resized pane
    /// on the serial shape, exactly one for the whole pass on the batched one.
    ///
    /// This is the observable that does not depend on the machine: whether a
    /// wait actually costs 16 ms is up to whether the compositor is throttling
    /// presents (on a hidden test desktop it usually is not), but how many
    /// times the UI thread agreed to stop and wait is a property of the code.
    waits: usize = 0,
    /// Panes that took a `WM_SIZE` in this tick. Zero waits with zero resizes
    /// means the tick did no layout work; zero waits with several resizes would
    /// mean the synchronous-present path has quietly stopped running.
    resizes: usize = 0,
    /// The dim-overlay refresh at the end of the layout pass, and the panes'
    /// own `sizeCallback` (grid reflow + renderer viewport + PTY SIGWINCH),
    /// summed over the tick. Together with `wait_us` these are the three parts
    /// a motion tick is made of — measured, because the task this module was
    /// written for assumed the wait was the whole bill and it is not.
    overlay_us: u64 = 0,
    resize_us: u64 = 0,
    /// The layout pass itself, which contains the wait, the overlays and the
    /// panes' resizes. `tick_us - layout_us` is the ratio solve on top of it.
    layout_us: u64 = 0,
    /// The two halves of that pass which are neither the wait nor the
    /// overlays: placing the panes (which dispatches their `WM_SIZE`) and
    /// repainting the divider bands.
    place_us: u64 = 0,
    paint_us: u64 = 0,
    /// Cutting the elevated style's rounded card regions after placement
    /// (`applyCardRegions`, T1906): a `SetWindowRgn` per resized pane.
    cards_us: u64 = 0,
    /// How many of those waits ran out the full timeout rather than being woken
    /// by a presented frame — the shape that costs the drag a whole frame each.
    timeouts: usize = 0,
    /// How many of those waits a presented frame actually WOKE (T1035): the
    /// renderer's signal ended the block, rather than the clock or a frame
    /// that had already landed. Zero over a drag that waited means the wait
    /// is a sleep with a size check on the end — the shape T1031 found, where
    /// `signalFrameDrawn` had no caller — and nothing else counts it.
    woken: usize = 0,
    /// Panes whose wait came back on a frame the renderer had drawn at the
    /// PREVIOUS size (T1476). Distinct from `timeouts`: the wait was answered,
    /// promptly, by the wrong frame — which is a blink the timeout count calls
    /// a clean tick.
    stale: usize = 0,
    /// The layered-chrome fan-out this tick paid for (T1345): how many
    /// `SetWindowPos` calls landed on a chrome popup, how many
    /// `UpdateLayeredWindow` blits were handed to the compositor, and how many
    /// z-order walks ran. These are the operations, not the clock — the same
    /// distinction `waits` draws against `wait_us`, and for the same reason:
    /// what a window move costs depends on the machine, how many the tick
    /// issued is a property of the code.
    chrome_moves: u32 = 0,
    /// Of those moves, the ones the scrollbar and the dim wash issued — the
    /// two that exist on every pane, and therefore the two that scale.
    chrome_sb_moves: u32 = 0,
    chrome_dim_moves: u32 = 0,
    chrome_blits: u32 = 0,
    chrome_heals: u32 = 0,
    /// Blits and heals the skip policies declined. Counted so a change that
    /// quietly stops skipping shows up as a number rather than as a feeling.
    chrome_skipped: u32 = 0,
    /// Wall clock spent inside those moves (T1350) - the ceiling on what
    /// putting the chrome into fewer windows could save this tick.
    chrome_move_us: u64 = 0,
    /// Viewer panes this tick resized (T2448), and what their bound syncs
    /// cost: the nav bar's placement, the WebView2 controller's bounds and the
    /// TOC card's relayout.
    viewer_syncs: u32 = 0,
    viewer_us: u64 = 0,
    viewer_nav_us: u64 = 0,
    viewer_bounds_us: u64 = 0,
    viewer_toc_us: u64 = 0,

    /// Work the UI thread actually did, as opposed to waited for.
    pub fn workUs(self: Sample) u64 {
        return self.tick_us -| self.wait_us;
    }

    pub fn overBudget(self: Sample) bool {
        return self.tick_us > frame_budget_us;
    }
};

/// A whole drag, accumulated tick by tick. Fixed size, no allocator: this runs
/// inside the motion path it is measuring.
pub const Stats = struct {
    ticks: u64 = 0,
    total_us: u64 = 0,
    max_us: u64 = 0,
    wait_us: u64 = 0,
    over_budget: u64 = 0,
    panes_max: usize = 0,
    /// The most frame waits any single tick performed. The number the fix is
    /// about: 1 whatever the pane count, instead of one per pane.
    waits_max: usize = 0,
    resizes_max: usize = 0,
    waits_total: u64 = 0,
    timeouts_total: u64 = 0,
    woken_total: u64 = 0,
    stale_total: u64 = 0,
    overlay_us: u64 = 0,
    resize_us: u64 = 0,
    layout_us: u64 = 0,
    place_us: u64 = 0,
    paint_us: u64 = 0,
    cards_us: u64 = 0,
    /// The most chrome operations any single tick performed. Max rather than
    /// mean for the same reason `waits_max` is: the fan-out is a per-tick
    /// property and averaging it over a drag that started before the panes
    /// existed would hide it.
    chrome_moves_max: u32 = 0,
    chrome_sb_moves_max: u32 = 0,
    chrome_dim_moves_max: u32 = 0,
    chrome_blits_max: u32 = 0,
    chrome_heals_max: u32 = 0,
    chrome_skipped_max: u32 = 0,
    chrome_move_us: u64 = 0,
    viewer_syncs_max: u32 = 0,
    viewer_us: u64 = 0,
    viewer_nav_us: u64 = 0,
    viewer_bounds_us: u64 = 0,
    viewer_toc_us: u64 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }

    pub fn record(self: *Stats, s: Sample) void {
        self.ticks += 1;
        self.total_us += s.tick_us;
        self.wait_us += s.wait_us;
        if (s.tick_us > self.max_us) self.max_us = s.tick_us;
        if (s.panes > self.panes_max) self.panes_max = s.panes;
        if (s.waits > self.waits_max) self.waits_max = s.waits;
        if (s.resizes > self.resizes_max) self.resizes_max = s.resizes;
        self.overlay_us += s.overlay_us;
        self.layout_us += s.layout_us;
        self.place_us += s.place_us;
        self.paint_us += s.paint_us;
        self.cards_us += s.cards_us;
        self.resize_us += s.resize_us;
        self.waits_total += s.waits;
        self.timeouts_total += s.timeouts;
        self.woken_total += s.woken;
        self.stale_total += s.stale;
        if (s.chrome_moves > self.chrome_moves_max) self.chrome_moves_max = s.chrome_moves;
        if (s.chrome_sb_moves > self.chrome_sb_moves_max) self.chrome_sb_moves_max = s.chrome_sb_moves;
        if (s.chrome_dim_moves > self.chrome_dim_moves_max) self.chrome_dim_moves_max = s.chrome_dim_moves;
        if (s.chrome_blits > self.chrome_blits_max) self.chrome_blits_max = s.chrome_blits;
        if (s.chrome_heals > self.chrome_heals_max) self.chrome_heals_max = s.chrome_heals;
        if (s.chrome_skipped > self.chrome_skipped_max) self.chrome_skipped_max = s.chrome_skipped;
        self.chrome_move_us += s.chrome_move_us;
        if (s.viewer_syncs > self.viewer_syncs_max) self.viewer_syncs_max = s.viewer_syncs;
        self.viewer_us += s.viewer_us;
        self.viewer_nav_us += s.viewer_nav_us;
        self.viewer_bounds_us += s.viewer_bounds_us;
        self.viewer_toc_us += s.viewer_toc_us;
        if (s.overBudget()) self.over_budget += 1;
    }

    pub fn meanUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.total_us / self.ticks;
    }

    pub fn meanWaitUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.wait_us / self.ticks;
    }

    pub fn meanLayoutUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.layout_us / self.ticks;
    }

    pub fn meanPlaceUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.place_us / self.ticks;
    }

    pub fn meanPaintUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.paint_us / self.ticks;
    }

    pub fn meanCardsUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.cards_us / self.ticks;
    }

    pub fn meanChromeMoveUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.chrome_move_us / self.ticks;
    }

    pub fn meanOverlayUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.overlay_us / self.ticks;
    }

    pub fn meanViewerUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.viewer_us / self.ticks;
    }

    pub fn meanViewerNavUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.viewer_nav_us / self.ticks;
    }

    pub fn meanViewerBoundsUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.viewer_bounds_us / self.ticks;
    }

    pub fn meanViewerTocUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.viewer_toc_us / self.ticks;
    }

    pub fn meanResizeUs(self: Stats) u64 {
        if (self.ticks == 0) return 0;
        return self.resize_us / self.ticks;
    }

    /// Drag frames per second implied by the mean tick — the number a watching
    /// human is actually judging. 0 ticks reads as 0 rather than infinity.
    pub fn fps(self: Stats) u64 {
        const mean = self.meanUs();
        if (mean == 0) return 0;
        return std.time.us_per_s / mean;
    }

    /// The verdict a harness can assert on. `smooth` means the average tick
    /// fits in a frame; `steppy` means the drag is visibly behind the mouse.
    pub fn verdict(self: Stats) Verdict {
        if (self.ticks == 0) return .no_data;
        return if (self.meanUs() <= frame_budget_us) .smooth else .steppy;
    }
};

pub const Verdict = enum { no_data, smooth, steppy };

test "serial wait grows with pane count, batched does not" {
    // The whole claim the fix rests on, in one assertion pair.
    try testing.expectEqual(@as(u64, 16_000), serialWaitCeilingUs(1));
    try testing.expectEqual(@as(u64, 64_000), serialWaitCeilingUs(4));
    try testing.expectEqual(@as(u64, 128_000), serialWaitCeilingUs(8));

    try testing.expectEqual(@as(u64, 16_000), batchedWaitCeilingUs(1));
    try testing.expectEqual(@as(u64, 16_000), batchedWaitCeilingUs(4));
    try testing.expectEqual(@as(u64, 16_000), batchedWaitCeilingUs(8));

    // Nothing resized, nothing waited for.
    try testing.expectEqual(@as(u64, 0), serialWaitCeilingUs(0));
    try testing.expectEqual(@as(u64, 0), batchedWaitCeilingUs(0));
}

test "four panes on the serial shape cannot hold a frame; batched can" {
    try testing.expect(serialWaitCeilingUs(4) > frame_budget_us);
    try testing.expect(batchedWaitCeilingUs(4) <= frame_budget_us + 1);
}

test "sample splits work from waiting and never underflows" {
    const s: Sample = .{ .tick_us = 20_000, .wait_us = 16_000, .panes = 4 };
    try testing.expectEqual(@as(u64, 4_000), s.workUs());
    try testing.expect(s.overBudget());

    // A wait that outlasts the tick is a clock artifact, not a negative.
    const odd: Sample = .{ .tick_us = 100, .wait_us = 900 };
    try testing.expectEqual(@as(u64, 0), odd.workUs());
}

test "stats accumulate mean, max, fps and the over-budget count" {
    var st: Stats = .{};
    try testing.expectEqual(Verdict.no_data, st.verdict());
    try testing.expectEqual(@as(u64, 0), st.fps());

    st.record(.{
        .tick_us = 10_000,
        .wait_us = 8_000,
        .panes = 2,
        .waits = 2,
        .timeouts = 1,
        .woken = 1,
        .resizes = 2,
        .overlay_us = 1_000,
        .resize_us = 3_000,
        .layout_us = 9_000,
        .place_us = 5_000,
        .paint_us = 100,
        .cards_us = 40,
    });
    st.record(.{
        .tick_us = 30_000,
        .wait_us = 28_000,
        .panes = 4,
        .waits = 4,
        .timeouts = 4,
        .resizes = 4,
        .overlay_us = 2_000,
        .resize_us = 1_000,
        .layout_us = 29_000,
        .place_us = 25_000,
        .paint_us = 300,
        .cards_us = 60,
    });

    // The wait COUNT is the machine-independent half of the measurement: how
    // long a wait takes depends on whether the compositor is throttling
    // presents, how many the tick agreed to perform does not.
    try testing.expectEqual(@as(usize, 4), st.waits_max);
    try testing.expectEqual(@as(u64, 6), st.waits_total);
    try testing.expectEqual(@as(u64, 5), st.timeouts_total);
    // T1035: woken is its own count, not "waits minus timeouts" — a wait that
    // found its frame already presented is neither.
    try testing.expectEqual(@as(u64, 1), st.woken_total);
    try testing.expectEqual(@as(usize, 4), st.resizes_max);
    try testing.expectEqual(@as(u64, 1_500), st.meanOverlayUs());
    try testing.expectEqual(@as(u64, 2_000), st.meanResizeUs());
    try testing.expectEqual(@as(u64, 19_000), st.meanLayoutUs());
    try testing.expectEqual(@as(u64, 15_000), st.meanPlaceUs());
    try testing.expectEqual(@as(u64, 200), st.meanPaintUs());
    try testing.expectEqual(@as(u64, 50), st.meanCardsUs());

    try testing.expectEqual(@as(u64, 2), st.ticks);
    try testing.expectEqual(@as(u64, 20_000), st.meanUs());
    try testing.expectEqual(@as(u64, 30_000), st.max_us);
    try testing.expectEqual(@as(u64, 18_000), st.meanWaitUs());
    try testing.expectEqual(@as(u64, 1), st.over_budget);
    try testing.expectEqual(@as(usize, 4), st.panes_max);
    try testing.expectEqual(@as(u64, 50), st.fps());
    try testing.expectEqual(Verdict.steppy, st.verdict());

    // A drag that stays inside the frame budget reads smooth, and the batched
    // shape waits once no matter how many panes moved.
    var fast: Stats = .{};
    fast.record(.{ .tick_us = 4_000, .panes = 8, .waits = 1, .resizes = 8 });
    // The batched shape's whole claim, in the units the log line reports.
    try testing.expectEqual(@as(u64, 0), fast.meanWaitUs());
    try testing.expectEqual(@as(usize, 1), fast.waits_max);
    try testing.expectEqual(Verdict.smooth, fast.verdict());
    try testing.expectEqual(@as(u64, 250), fast.fps());
    try testing.expectEqual(@as(u64, 0), fast.over_budget);

    fast.reset();
    try testing.expectEqual(@as(u64, 0), fast.ticks);
    try testing.expectEqual(Verdict.no_data, fast.verdict());
}

test "chrome move time is a per-tick mean, unlike the counts (T1350)" {
    // The counts are a per-tick maximum because they are a property of the
    // code; the clock is a cost, and a cost is reported as a mean the same way
    // every other `_us` term on the drag line is.
    var st: Stats = .{};
    try testing.expectEqual(@as(u64, 0), st.meanChromeMoveUs());
    st.record(.{ .tick_us = 1000, .chrome_moves = 4, .chrome_move_us = 300 });
    st.record(.{ .tick_us = 1000, .chrome_moves = 2, .chrome_move_us = 100 });
    try testing.expectEqual(@as(u64, 200), st.meanChromeMoveUs());
    try testing.expectEqual(@as(u32, 4), st.chrome_moves_max);
    st.reset();
    try testing.expectEqual(@as(u64, 0), st.chrome_move_us);
}

test "the chrome fan-out is carried as a per-tick maximum, not an average" {
    // T1345: the number that matters is how many chrome operations ONE mouse
    // move issues — a mean over a drag that began at two panes and ended at
    // eight would report neither.
    var st: Stats = .{};
    st.record(.{
        .tick_us = 1_000,
        .chrome_moves = 4,
        .chrome_sb_moves = 2,
        .chrome_dim_moves = 2,
        .chrome_blits = 2,
        .chrome_heals = 4,
    });
    st.record(.{
        .tick_us = 1_000,
        .chrome_moves = 16,
        .chrome_sb_moves = 8,
        .chrome_dim_moves = 8,
        .chrome_blits = 0,
        .chrome_heals = 0,
        .chrome_skipped = 32,
    });

    try testing.expectEqual(@as(u32, 16), st.chrome_moves_max);
    try testing.expectEqual(@as(u32, 8), st.chrome_sb_moves_max);
    try testing.expectEqual(@as(u32, 8), st.chrome_dim_moves_max);
    try testing.expectEqual(@as(u32, 2), st.chrome_blits_max);
    try testing.expectEqual(@as(u32, 4), st.chrome_heals_max);
    try testing.expectEqual(@as(u32, 32), st.chrome_skipped_max);

    st.reset();
    try testing.expectEqual(@as(u32, 0), st.chrome_moves_max);
    try testing.expectEqual(@as(u32, 0), st.chrome_skipped_max);
}

/// The fold glide's own frames under a drag (T2448). A divider drag runs two
/// clocks on the UI thread at once: the mouse's motion ticks (`Stats` above)
/// and the glide's frame-clock ticks (`Window.stackSlideTick`), and the user
/// sees the second. A motion tick that costs 60 ms delays the glide tick
/// queued behind it, so the glide steps at the pass rate however cheap its own
/// tick is - which is why this carries the GAP between ticks beside their cost.
pub const GlideStats = struct {
    ticks: u64 = 0,
    total_us: u64 = 0,
    max_us: u64 = 0,
    /// Start-to-start gaps between consecutive ticks; `gaps` is one fewer than
    /// `ticks`, since the first tick has no predecessor.
    gaps: u64 = 0,
    gap_total_us: u64 = 0,
    max_gap_us: u64 = 0,
    /// Gaps longer than two display periods: a frame the glide did not draw.
    late: u64 = 0,
    /// Ticks whose own pass resized a viewer pane, and what those resizes
    /// cost summed over the glide.
    viewer_ticks: u64 = 0,
    viewer_us: u64 = 0,

    pub fn reset(self: *GlideStats) void {
        self.* = .{};
    }

    /// One glide tick that cost `cost_us`, `gap_us` after the tick before it
    /// (null for the first tick of a glide), against a display period of
    /// `period_us`.
    pub fn record(self: *GlideStats, cost_us: u64, gap_us: ?u64, period_us: u64, viewer_us: ?u64) void {
        self.ticks += 1;
        self.total_us += cost_us;
        if (cost_us > self.max_us) self.max_us = cost_us;
        if (viewer_us) |v| {
            self.viewer_ticks += 1;
            self.viewer_us += v;
        }
        const g = gap_us orelse return;
        self.gaps += 1;
        self.gap_total_us += g;
        if (g > self.max_gap_us) self.max_gap_us = g;
        if (g > 2 * period_us) self.late += 1;
    }

    pub fn meanUs(self: GlideStats) u64 {
        if (self.ticks == 0) return 0;
        return self.total_us / self.ticks;
    }

    pub fn meanGapUs(self: GlideStats) u64 {
        if (self.gaps == 0) return 0;
        return self.gap_total_us / self.gaps;
    }

    /// Glide frames per second implied by the mean gap.
    pub fn fps(self: GlideStats) u64 {
        const g = self.meanGapUs();
        if (g == 0) return 0;
        return std.time.us_per_s / g;
    }

    /// `smooth` is the task's bar: no tick more than two periods after the
    /// last one.
    pub fn verdict(self: GlideStats) Verdict {
        if (self.gaps == 0) return .no_data;
        return if (self.late == 0) .smooth else .steppy;
    }
};

test "a glide's gaps are measured between ticks, not from the first" {
    var g: GlideStats = .{};
    g.record(2_000, null, 16_667, null);
    g.record(4_000, 16_000, 16_667, 1_500);
    g.record(3_000, 18_000, 16_667, null);
    try testing.expectEqual(@as(u64, 3), g.ticks);
    try testing.expectEqual(@as(u64, 2), g.gaps);
    try testing.expectEqual(@as(u64, 17_000), g.meanGapUs());
    try testing.expectEqual(@as(u64, 3_000), g.meanUs());
    try testing.expectEqual(@as(u64, 4_000), g.max_us);
    try testing.expectEqual(@as(u64, 1), g.viewer_ticks);
    try testing.expectEqual(@as(u64, 1_500), g.viewer_us);
    try testing.expectEqual(@as(u64, 58), g.fps());
    try testing.expectEqual(Verdict.smooth, g.verdict());
}

test "a gap past two periods is a late frame, and one makes the glide steppy" {
    // The user's window (T2448): glide ticks 60-100 ms apart at 60 Hz.
    var g: GlideStats = .{};
    g.record(1_000, null, 16_667, null);
    g.record(1_000, 33_000, 16_667, null);
    try testing.expectEqual(Verdict.smooth, g.verdict());
    g.record(1_000, 80_000, 16_667, null);
    try testing.expectEqual(@as(u64, 1), g.late);
    try testing.expectEqual(@as(u64, 80_000), g.max_gap_us);
    try testing.expectEqual(Verdict.steppy, g.verdict());
    g.reset();
    try testing.expectEqual(Verdict.no_data, g.verdict());
}
