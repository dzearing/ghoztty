//! The exact ratios behind a tree's f16 ones (T2485 D19).
//!
//! `SplitTree` keeps a split's ratio as an f16: about 2.4e-4 of a step at a
//! ratio near a third, which over a 1500-DIP row is half a pixel. A row drag
//! recomputes every split of the row each tick so that the panes it is not
//! resizing keep their size, and storing those ratios as f16 moved the panes
//! beyond the dragged gutter by that error: whichever edge sat near a half
//! pixel rounded one way on one tick and the other way on the next, so a pane
//! nobody was touching shook by a pixel (run57 f99-f104, pane 5 at 1352 then
//! 1351 then 1352).
//!
//! The window writes each ratio here as well as into the tree, and the grid
//! reads it back in place of the tree's. A shadow counts only while it still
//! describes the tree: the same node array (a replaced tree has a new one) and
//! a ratio that rounds to what the tree holds (anything else wrote the tree
//! since). The shared tree's type is untouched.

const std = @import("std");

/// Splits shadowed per tree; a tree with more than this falls back to f16
/// for the rest, which is the old behaviour rather than a failure.
pub const capacity = 32;

pub const Shadow = struct {
    /// The tree's node array the entries were written against.
    nodes: ?*const anyopaque = null,
    len: usize = 0,
    node: [capacity]u32 = undefined,
    ratio: [capacity]f64 = undefined,

    /// Record `ratio` for split `node` of the tree whose node array starts at
    /// `nodes`. A different array drops every entry first.
    pub fn note(self: *Shadow, nodes: *const anyopaque, node: u32, ratio: f64) void {
        if (self.nodes != nodes) {
            self.nodes = nodes;
            self.len = 0;
        }
        for (self.node[0..self.len], 0..) |n, i| {
            if (n == node) {
                self.ratio[i] = ratio;
                return;
            }
        }
        if (self.len == capacity) return;
        self.node[self.len] = node;
        self.ratio[self.len] = ratio;
        self.len += 1;
    }

    /// The exact ratio for split `node`, when the shadow still describes it:
    /// the same node array, and `stored` (the tree's f16) is what it rounds to.
    pub fn exact(self: *const Shadow, nodes: *const anyopaque, node: u32, stored: f16) ?f64 {
        if (self.nodes != nodes) return null;
        for (self.node[0..self.len], 0..) |n, i| {
            if (n != node) continue;
            const r = self.ratio[i];
            return if (@as(f16, @floatCast(r)) == stored) r else null;
        }
        return null;
    }
};

const testing = std.testing;

test "split_ratio_shadow: an exact ratio reads back while the tree holds its f16" {
    var s: Shadow = .{};
    var arr: [4]u8 = undefined;
    const r: f64 = 0.3337;
    s.note(&arr, 2, r);
    try testing.expectEqual(@as(?f64, r), s.exact(&arr, 2, @floatCast(r)));
    // The f16 really does lose it: the point of the shadow.
    try testing.expect(@as(f64, @as(f16, @floatCast(r))) != r);
    try testing.expectEqual(@as(?f64, null), s.exact(&arr, 3, @floatCast(r)));
}

test "split_ratio_shadow: anything else writing the tree retires the shadow" {
    var s: Shadow = .{};
    var arr: [4]u8 = undefined;
    s.note(&arr, 2, 0.3337);
    try testing.expectEqual(@as(?f64, null), s.exact(&arr, 2, 0.5));
}

test "split_ratio_shadow: a replaced tree drops every entry" {
    var s: Shadow = .{};
    var a: [4]u8 = undefined;
    var b: [4]u8 = undefined;
    s.note(&a, 2, 0.3337);
    try testing.expectEqual(@as(?f64, null), s.exact(&b, 2, @floatCast(@as(f64, 0.3337))));
    s.note(&b, 4, 0.25);
    try testing.expectEqual(@as(?f64, null), s.exact(&a, 2, @floatCast(@as(f64, 0.3337))));
    try testing.expectEqual(@as(usize, 1), s.len);
}

test "split_ratio_shadow: a rewrite updates in place and a full table keeps its entries" {
    var s: Shadow = .{};
    var arr: [4]u8 = undefined;
    for (0..capacity) |i| s.note(&arr, @intCast(i), 0.5);
    s.note(&arr, 3, 0.4001);
    try testing.expectEqual(@as(usize, capacity), s.len);
    try testing.expectEqual(@as(?f64, 0.4001), s.exact(&arr, 3, @floatCast(@as(f64, 0.4001))));
    s.note(&arr, capacity + 5, 0.3);
    try testing.expectEqual(@as(?f64, null), s.exact(&arr, capacity + 5, @floatCast(@as(f64, 0.3))));
}
