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
