//! Pointer-first drags on the composition tree (T2769, from the T2556
//! decision). With the panes in the window's DirectComposition tree, a
//! divider drag's mouse move used to cost ~15.7 ms, ~14.7 of it the pane
//! batch (child-window moves and swap-chain resizes) - and the card edge the
//! user is dragging only moved once all of that was done.
//!
//! Now a move does the cheap part first: every pane visual is written at
//! where the layout puts it and the device commits, about a millisecond after
//! the pointer moved. The layout pass (the windows and their resizes) follows
//! behind, at most once per display frame and never while a newer move is
//! already queued. Until a pane's resize lands its grid is the size it was,
//! so a pane that grew shows desk past its old edge, never a stretched grid.
//!
//! This file is the arithmetic of that: whether a move runs the layout pass
//! now or leaves it to the next frame, how a visual's card shape follows a
//! size the window does not have yet, and what a drag's moves added up to.
//! No OS imports.

const std = @import("std");
const comp_tree = @import("../../renderer/comp_tree.zig");

/// What a drag move does about the layout pass behind its compositor write.
pub const Pass = enum {
    /// Lay out now.
    run,
    /// A newer move is already queued: its own move will lay out.
    skip_queued,
    /// A pass ran less than a frame ago: leave it to the frame timer.
    skip_frame,
};

/// Whether the move at `now_ns` runs its layout pass. `last_ns` is when the
/// last pass of this drag started (null before the first), `pending_ns` when
/// the oldest move still waiting for a pass was skipped (null when none is),
/// `period_ns` the display frame. A queued move wins over the clock - laying
/// out a position the pointer has already left is the cost this exists to
/// drop - but never for longer than a frame: a mouse that always has the
/// next move queued must not starve the windows of their place.
pub fn decide(now_ns: u64, last_ns: ?u64, pending_ns: ?u64, period_ns: u64, newer_queued: bool) Pass {
    const overdue = if (pending_ns) |p| now_ns -| p >= period_ns else false;
    if (newer_queued and !overdue) return .skip_queued;
    const last = last_ns orelse return .run;
    if (overdue or now_ns -| last >= period_ns) return .run;
    return .skip_frame;
}

/// How long until the frame timer should lay out a skipped move: what is
/// left of the frame since the last pass, never less than 1 ms (a zero
/// timer would spin the queue).
pub fn timerDelayMs(now_ns: u64, last_ns: u64, period_ns: u64) u32 {
    const spent = now_ns -| last_ns;
    const left = period_ns -| spent;
    const ms = (left + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    return @intCast(@max(ms, 1));
}

/// The card shape a pane window of `old_w` x `old_h` had, carried to the
/// `new_w` x `new_h` its visual is drawn at ahead of the window. An edge that
/// sat on the window's far edge follows it; an inner cut (a slide's, a
/// header's) keeps its place. Null (the whole window) stays null.
pub fn reshape(shape: comp_tree.Shape, old_w: i32, old_h: i32, new_w: i32, new_h: i32) comp_tree.Shape {
    var out = shape;
    const r = shape.rect orelse return out;
    var nr = r;
    if (r.right >= old_w) nr.right = r.right + (new_w - old_w);
    if (r.bottom >= old_h) nr.bottom = r.bottom + (new_h - old_h);
    nr.right = @max(nr.right, nr.left);
    nr.bottom = @max(nr.bottom, nr.top);
    out.rect = nr;
    return out;
}

/// One drag's compositor moves, for the drag line (`divider drag comp ...`).
pub const Stats = struct {
    /// Moves that wrote the pane visuals ahead of the layout.
    commits: u32 = 0,
    /// Pointer-to-commit, summed and the worst, in us.
    commit_total_us: u64 = 0,
    commit_max_us: u64 = 0,
    /// Layout passes the drag ran, and the moves that left theirs behind.
    passes: u32 = 0,
    skipped_queued: u32 = 0,
    skipped_frame: u32 = 0,
    /// Passes that started less than a frame after the one before - zero
    /// unless something other than the coalescer laid out.
    passes_inside_frame: u32 = 0,
    last_pass_ns: ?u64 = null,
    /// When the oldest move still waiting for a pass was skipped.
    pending_ns: ?u64 = null,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }

    pub fn recordCommit(self: *Stats, us: u64) void {
        self.commits +|= 1;
        self.commit_total_us +|= us;
        self.commit_max_us = @max(self.commit_max_us, us);
    }

    pub fn recordPass(self: *Stats, now_ns: u64, period_ns: u64) void {
        if (self.last_pass_ns) |l| {
            if (now_ns -| l < period_ns -| period_ns / 8) self.passes_inside_frame +|= 1;
        }
        self.passes +|= 1;
        self.last_pass_ns = now_ns;
        self.pending_ns = null;
    }

    pub fn recordSkip(self: *Stats, p: Pass, now_ns: u64) void {
        if (p != .run and self.pending_ns == null) self.pending_ns = now_ns;
        switch (p) {
            .run => {},
            .skip_queued => self.skipped_queued +|= 1,
            .skip_frame => self.skipped_frame +|= 1,
        }
    }

    pub fn meanCommitUs(self: Stats) u64 {
        if (self.commits == 0) return 0;
        return self.commit_total_us / self.commits;
    }
};

test "decide: a queued move always skips; the first move runs; then one pass a frame (T2769)" {
    const p: u64 = 16_666_667;
    try std.testing.expectEqual(Pass.skip_queued, decide(0, null, null, p, true));
    try std.testing.expectEqual(Pass.run, decide(5, null, null, p, false));
    try std.testing.expectEqual(Pass.skip_frame, decide(10 * std.time.ns_per_ms, 0, 10, p, false));
    try std.testing.expectEqual(Pass.run, decide(p, 0, null, p, false));
    try std.testing.expectEqual(Pass.skip_queued, decide(2 * p, 0, 2 * p - 5, p, true));
    // A clock that went backwards never reads as a frame elapsed.
    try std.testing.expectEqual(Pass.skip_frame, decide(0, 5, null, p, false));
}

test "decide: a move waiting a whole frame is laid out even with the next one queued" {
    const p: u64 = 16_666_667;
    // First pass never ran, moves have queued for a frame: run now.
    try std.testing.expectEqual(Pass.run, decide(p + 1, null, 0, p, true));
    // Just short of a frame: still yields to the queued move.
    try std.testing.expectEqual(Pass.skip_queued, decide(p - 1, null, 0, p, true));
    // After a pass, a pending move a frame old runs whatever the queue says.
    try std.testing.expectEqual(Pass.run, decide(3 * p, 2 * p, 2 * p, p, true));
}

test "timerDelayMs: the rest of the frame, rounded up, at least 1 ms" {
    const p: u64 = 16_666_667;
    try std.testing.expectEqual(@as(u32, 17), timerDelayMs(0, 0, p));
    try std.testing.expectEqual(@as(u32, 7), timerDelayMs(10 * std.time.ns_per_ms, 0, p));
    try std.testing.expectEqual(@as(u32, 1), timerDelayMs(p, 0, p));
    try std.testing.expectEqual(@as(u32, 1), timerDelayMs(3 * p, 0, p));
}

test "reshape: edges on the window's far side follow the new size; inner cuts stay" {
    const whole: comp_tree.Shape = .{};
    try std.testing.expectEqual(whole, reshape(whole, 400, 300, 500, 300));
    const card: comp_tree.Shape = .{ .rect = .{ .left = 0, .top = 0, .right = 400, .bottom = 300 }, .radius = 6 };
    const grown = reshape(card, 400, 300, 520, 280);
    try std.testing.expectEqual(@as(i32, 520), grown.rect.?.right);
    try std.testing.expectEqual(@as(i32, 280), grown.rect.?.bottom);
    try std.testing.expectEqual(@as(f32, 6), grown.radius);
    // A slide's cut inside the window keeps its far edge.
    const cut: comp_tree.Shape = .{ .rect = .{ .left = 0, .top = 0, .right = 250, .bottom = 300 } };
    try std.testing.expectEqual(@as(i32, 250), reshape(cut, 400, 300, 600, 300).rect.?.right);
    // A shrink past the cut's start never inverts it.
    const left_cut: comp_tree.Shape = .{ .rect = .{ .left = 100, .top = 0, .right = 400, .bottom = 300 } };
    const shrunk = reshape(left_cut, 400, 300, 50, 300).rect.?;
    try std.testing.expect(shrunk.right >= shrunk.left);
}

test "Stats: commits, skips and the passes that came inside a frame" {
    const p: u64 = 16_666_667;
    var s: Stats = .{};
    s.recordCommit(800);
    s.recordCommit(1200);
    try std.testing.expectEqual(@as(u64, 1000), s.meanCommitUs());
    try std.testing.expectEqual(@as(u64, 1200), s.commit_max_us);
    s.recordPass(0, p);
    s.recordPass(p, p);
    try std.testing.expectEqual(@as(u32, 0), s.passes_inside_frame);
    s.recordPass(p + 3 * std.time.ns_per_ms, p);
    try std.testing.expectEqual(@as(u32, 1), s.passes_inside_frame);
    s.recordSkip(.skip_queued, 100);
    s.recordSkip(.skip_frame, 200);
    s.recordSkip(.run, 300);
    try std.testing.expectEqual(@as(u32, 1), s.skipped_queued);
    try std.testing.expectEqual(@as(u32, 1), s.skipped_frame);
    // The oldest skip is the one the starvation guard measures from.
    try std.testing.expectEqual(@as(?u64, 100), s.pending_ns);
    s.recordPass(2 * p, p);
    try std.testing.expectEqual(@as(?u64, null), s.pending_ns);
    s.reset();
    try std.testing.expectEqual(@as(u32, 0), s.passes);
}

// ---------------------------------------------------------------------------
// The composition thread's model (T2770).
//
// After T2769 the pane visuals follow the pointer first - but on the window
// thread, so a stall there freezes the edge under the hand. While a divider
// drag is live a composition thread wakes on the compositor clock, reads the
// cursor, and writes the dragged visuals itself. It cannot run the layout:
// the row drag folds, tucks the sidebar and moves focus, none of it pure. So
// at every move it lays out, the window thread publishes a MODEL of the drag
// around where the pointer is: each visible pane's pose there, and which of
// its edges sit on the dragged gutter. The thread extrapolates the gutter
// alone - those edges follow the pointer one for one, nothing else moves -
// clamped so no pane goes under its minimum. That is what the layout does
// itself until a pane reaches its minimum; past it (the next pane giving way,
// a fold) the window thread's own pass reconciles when it catches up.
// ---------------------------------------------------------------------------

/// The drag's axis: a vertical divider moves along x.
pub const Axis = enum { x, y };

/// One pane visual, as the window thread last laid it out.
pub const PaneModel = struct {
    /// The visual's offset and clip there.
    pose: comp_tree.Pose,
    /// Its extent along the axis (the placement's w or h).
    size: f32,
    /// Its leading (left/top) edge is the gutter's far side: the pane moves
    /// with the pointer and narrows.
    lo_moves: bool = false,
    /// Its trailing (right/bottom) edge is the gutter's near side: the pane
    /// widens with the pointer.
    hi_moves: bool = false,

    pub fn moves(self: PaneModel) bool {
        return self.lo_moves or self.hi_moves;
    }
};

/// Which of a pane's edges sit on the dragged gutter.
pub const Edges = struct { lo: bool, hi: bool };

/// Classify a pane's edges against the dragged gutter, all in client px
/// along the axis: `lo`/`hi` are the pane's leading/trailing edges, `g_lo`/
/// `g_hi` the gutter's, and `overlap` whether the pane shares the divider's
/// span across the axis (a pane in another row whose edge happens to line up
/// does not move). `tol` absorbs the layout's rounding.
pub fn classify(lo: i32, hi: i32, g_lo: i32, g_hi: i32, overlap: bool, tol: i32) Edges {
    if (!overlap) return .{ .lo = false, .hi = false };
    return .{ .lo = @abs(lo - g_hi) <= tol, .hi = @abs(hi - g_lo) <= tol };
}

/// How far the pointer may travel from the model's base before a moving pane
/// would go under `min` along the axis.
pub const Limits = struct { lo: f32, hi: f32 };

/// [lo, hi], lo <= 0 <= hi. A pane already under its minimum pins that side
/// at 0 rather than pushing back.
pub fn travelLimits(panes: []const PaneModel, min: f32) Limits {
    var lo: f32 = -std.math.floatMax(f32);
    var hi: f32 = std.math.floatMax(f32);
    for (panes) |p| {
        // Widening as the pointer goes forward; going back narrows it.
        if (p.hi_moves) lo = @max(lo, @min(min - p.size, 0));
        // Narrowing as the pointer goes forward.
        if (p.lo_moves) hi = @min(hi, @max(p.size - min, 0));
    }
    return .{ .lo = lo, .hi = hi };
}

/// The pointer's travel `d` from the base, clamped to the limits.
pub fn clampTravel(d: f32, lim: Limits) f32 {
    return std.math.clamp(d, lim.lo, lim.hi);
}

/// Where `p`'s visual goes with the gutter `d` px along `axis` from the base:
/// a moving leading edge carries the offset and pulls the far clip edge back
/// by as much (the far edge stays put); a moving trailing edge pushes the far
/// clip edge out. Corner radii are kept. A pane that does not move is
/// returned as it was.
pub fn poseAt(p: PaneModel, axis: Axis, d: f32) comp_tree.Pose {
    var out = p.pose;
    if (!p.moves() or d == 0) return out;
    switch (axis) {
        .x => {
            if (p.lo_moves) {
                out.x += d;
                out.clip.right -= d;
            }
            if (p.hi_moves) out.clip.right += d;
            out.clip.right = @max(out.clip.right, out.clip.left);
        },
        .y => {
            if (p.lo_moves) {
                out.y += d;
                out.clip.bottom -= d;
            }
            if (p.hi_moves) out.clip.bottom += d;
            out.clip.bottom = @max(out.clip.bottom, out.clip.top);
        },
    }
    return out;
}

/// Nearest-rank percentile of `samples` (sorted in place), 0 when empty.
pub fn percentile(samples: []u32, pct: u32) u32 {
    if (samples.len == 0) return 0;
    std.mem.sort(u32, samples, {}, std.sort.asc(u32));
    const rank = (samples.len * @min(pct, 100) + 99) / 100;
    return samples[@max(rank, 1) - 1];
}

/// One drag's composition-thread work, for its line
/// (`divider drag thread ...`).
pub const ThreadStats = struct {
    /// Compositor clock ticks the thread woke for.
    ticks: u32 = 0,
    /// Ticks that wrote a new pose and committed.
    writes: u32 = 0,
    /// Writes made while the window thread was inside a stall (the debug
    /// seam marks it): the edge advancing with nobody else able to move it.
    writes_in_stall: u32 = 0,
    /// Ticks that fell inside a stall at all.
    ticks_in_stall: u32 = 0,
    /// Writes the travel clamp cut short.
    clamped: u32 = 0,
    /// Stall ticks that wrote nothing, by why: the travel had not moved
    /// since the last write, no model was published yet, the thread was
    /// dead (a failed write/commit), or the cursor could not be read.
    stall_same: u32 = 0,
    stall_empty: u32 = 0,
    stall_dead: u32 = 0,
    stall_nocursor: u32 = 0,
    /// Commits refused because a surface was mid-draw on the window thread
    /// (retried on the next tick).
    commit_retries: u32 = 0,
    /// Cursor sample to commit returned, per write, in us (ring).
    lag_us: [256]u32 = undefined,
    lag_n: usize = 0,
    lag_max_us: u32 = 0,

    pub fn recordWrite(self: *ThreadStats, lag_us: u32, in_stall: bool, was_clamped: bool) void {
        self.writes +|= 1;
        if (in_stall) self.writes_in_stall +|= 1;
        if (was_clamped) self.clamped +|= 1;
        self.lag_us[self.lag_n % self.lag_us.len] = lag_us;
        self.lag_n += 1;
        self.lag_max_us = @max(self.lag_max_us, lag_us);
    }

    pub fn lagP95(self: *ThreadStats) u32 {
        const n = @min(self.lag_n, self.lag_us.len);
        return percentile(self.lag_us[0..n], 95);
    }
};

fn testPane(x: f32, w: f32, lo: bool, hi: bool) PaneModel {
    return .{
        .pose = .{ .x = x, .y = 10, .clip = .{ .left = 0, .top = -4, .right = w, .bottom = 300 } },
        .size = w,
        .lo_moves = lo,
        .hi_moves = hi,
    };
}

test "classify: edges on the gutter move; a lined-up edge in another row does not (T2770)" {
    // Gutter 396..404: the left pane ends at 396, the right one starts at 404.
    const left = classify(0, 396, 396, 404, true, 2);
    try std.testing.expect(left.hi and !left.lo);
    const right = classify(404, 800, 396, 404, true, 2);
    try std.testing.expect(right.lo and !right.hi);
    // Rounding inside the tolerance still counts.
    try std.testing.expect(classify(0, 397, 396, 404, true, 2).hi);
    // Same x, other row: nothing moves.
    const other = classify(0, 396, 396, 404, false, 2);
    try std.testing.expect(!other.lo and !other.hi);
    // A pane far from the gutter.
    const far = classify(810, 1200, 396, 404, true, 2);
    try std.testing.expect(!far.lo and !far.hi);
}

test "poseAt: the leading edge carries the visual, the trailing edge stretches the clip" {
    const left = testPane(0, 396, false, true);
    const right = testPane(404, 396, true, false);
    const still = testPane(900, 200, false, false);
    const l = poseAt(left, .x, 30);
    try std.testing.expectEqual(@as(f32, 0), l.x);
    try std.testing.expectEqual(@as(f32, 426), l.clip.right);
    const r = poseAt(right, .x, 30);
    try std.testing.expectEqual(@as(f32, 434), r.x);
    // Its far edge stays where it was: 404 + 396 = 434 + 366.
    try std.testing.expectEqual(@as(f32, 366), r.clip.right);
    try std.testing.expectEqual(still.pose, poseAt(still, .x, 30));
    // Along y the same, on the other fields.
    const below = poseAt(testPane(0, 396, true, false), .y, 12);
    try std.testing.expectEqual(@as(f32, 22), below.y);
    try std.testing.expectEqual(@as(f32, 288), below.clip.bottom);
    // Never inverted.
    try std.testing.expect(poseAt(right, .x, 1000).clip.right >= 0);
}

test "travelLimits: the pointer stops where a moving pane reaches its minimum" {
    const panes = [_]PaneModel{ testPane(0, 300, false, true), testPane(304, 500, true, false), testPane(900, 50, false, false) };
    const lim = travelLimits(&panes, 100);
    // Back: the left pane may give 200; forward: the right one 400.
    try std.testing.expectEqual(@as(f32, -200), lim.lo);
    try std.testing.expectEqual(@as(f32, 400), lim.hi);
    try std.testing.expectEqual(@as(f32, 400), clampTravel(650, lim));
    try std.testing.expectEqual(@as(f32, -200), clampTravel(-999, lim));
    try std.testing.expectEqual(@as(f32, 17), clampTravel(17, lim));
    // Already under the minimum: that side is pinned at 0, never pushed back.
    const tight = [_]PaneModel{ testPane(0, 80, false, true), testPane(84, 60, true, false) };
    const t = travelLimits(&tight, 100);
    try std.testing.expectEqual(@as(f32, 0), t.lo);
    try std.testing.expectEqual(@as(f32, 0), t.hi);
}

test "ThreadStats: writes, stall writes and the lag percentile" {
    var s: ThreadStats = .{};
    var i: u32 = 1;
    while (i <= 100) : (i += 1) s.recordWrite(i * 10, i > 90, i == 5);
    try std.testing.expectEqual(@as(u32, 100), s.writes);
    try std.testing.expectEqual(@as(u32, 10), s.writes_in_stall);
    try std.testing.expectEqual(@as(u32, 1), s.clamped);
    try std.testing.expectEqual(@as(u32, 950), s.lagP95());
    try std.testing.expectEqual(@as(u32, 1000), s.lag_max_us);
    var empty: ThreadStats = .{};
    try std.testing.expectEqual(@as(u32, 0), empty.lagP95());
}
