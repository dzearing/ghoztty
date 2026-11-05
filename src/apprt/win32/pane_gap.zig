//! The dividers of a split tree, for a pane dropped on one (T2704). Pure — no
//! OS imports — so these unit tests run in every app-runtime lane, the
//! `pane_drop.zig` pattern.
//!
//! Mac parity: `PaneDropCandidate.Divider.all` (the dividers a drag can land
//! on) and the lookup half of `SplitTree.inserting(view:between:and:)` (which
//! split a released divider names), from 30d13ea14.
//!
//! Both walk the tree in screen order, which is what lets a split's two sides
//! be two contiguous runs of ONE id buffer: a subtree's leaves are always
//! adjacent in that order, so naming a side costs a slice rather than a list
//! of its own per split, and the walk needs no allocator on a mouse move.

const std = @import("std");
const testing = std.testing;
const pane_drop = @import("pane_drop.zig");
const pane_id = @import("pane_id.zig");

/// Every divider of `tree` whose two sides are on screen and apart, as
/// `rects` has them, written to `out`; returns how many.
///
/// `ids` is the scratch the dividers' `before`/`after` slices point into, so
/// it must outlive them: it needs a slot per leaf. A side's panes are the
/// leaves `rects` has a rect for, so a stashed pane or one off screen is not
/// part of either side. Outer dividers come first, Mac's order, so where two
/// are equally near the outer one wins.
pub fn dividers(
    comptime Tree: type,
    tree: *const Tree,
    comptime idOf: fn (*Tree.View) []const u8,
    rects: []const pane_drop.PaneRect,
    metrics: pane_drop.Metrics,
    ids: [][]const u8,
    out: []pane_drop.Divider,
) usize {
    if (tree.nodes.len == 0) return 0;
    var w: Walk(Tree, idOf) = .{ .tree = tree, .ids = ids, .rects = rects, .metrics = metrics, .out = out };
    _ = w.visit(.root);
    std.mem.reverse(pane_drop.Divider, out[0..w.n]);
    return w.n;
}

fn Walk(comptime Tree: type, comptime idOf: fn (*Tree.View) []const u8) type {
    return struct {
        const Self = @This();
        const Range = struct { start: usize, end: usize };

        tree: *const Tree,
        ids: [][]const u8,
        rects: []const pane_drop.PaneRect,
        metrics: pane_drop.Metrics,
        out: []pane_drop.Divider,
        len: usize = 0,
        n: usize = 0,

        fn visit(self: *Self, at: Tree.Node.Handle) Range {
            const start = self.len;
            switch (self.tree.nodes[at.idx()]) {
                .leaf => |view| {
                    const id = idOf(view);
                    if (self.len < self.ids.len and onScreen(self.rects, id)) {
                        self.ids[self.len] = id;
                        self.len += 1;
                    }
                },
                .split => |s| {
                    const l = self.visit(s.left);
                    const r = self.visit(s.right);
                    // Post-order, reversed by the caller: children are found
                    // first and end up after their ancestors.
                    if (self.n < self.out.len) {
                        if (pane_drop.dividerFor(
                            layoutOf(s.layout),
                            self.ids[l.start..l.end],
                            self.ids[r.start..r.end],
                            self.rects,
                            self.metrics,
                        )) |dv| {
                            self.out[self.n] = dv;
                            self.n += 1;
                        }
                    }
                },
            }
            return .{ .start = start, .end = self.len };
        }
    };
}

/// The split of `tree` whose divider has exactly the panes `before` on one
/// side and `after` on the other, on `layout`'s axis — the split a released
/// divider names — or null when there is none any more.
///
/// `hidden` leaves (stashed panes) are not part of a side, and neither is
/// `exclude`, the pane being moved, which may still be in the tree beside
/// that divider or already gone from it. With it taken out, a side holding
/// nothing else has no divider left to drop in (Mac's nil). `ids` is scratch,
/// a slot per leaf.
pub fn findGap(
    comptime Tree: type,
    tree: *const Tree,
    comptime idOf: fn (*Tree.View) []const u8,
    comptime hidden: fn (*Tree.View) bool,
    layout: pane_drop.RowDirection,
    before: []const []const u8,
    after: []const []const u8,
    exclude: []const u8,
    ids: [][]const u8,
) ?Tree.Node.Handle {
    if (tree.nodes.len == 0) return null;
    var f: Find(Tree, idOf, hidden) = .{
        .tree = tree,
        .ids = ids,
        .layout = layout,
        .before = before,
        .after = after,
        .exclude = exclude,
    };
    _ = f.visit(.root);
    return f.found;
}

fn Find(
    comptime Tree: type,
    comptime idOf: fn (*Tree.View) []const u8,
    comptime hidden: fn (*Tree.View) bool,
) type {
    return struct {
        const Self = @This();
        const Range = struct { start: usize, end: usize };

        tree: *const Tree,
        ids: [][]const u8,
        layout: pane_drop.RowDirection,
        before: []const []const u8,
        after: []const []const u8,
        exclude: []const u8,
        len: usize = 0,
        found: ?Tree.Node.Handle = null,

        fn visit(self: *Self, at: Tree.Node.Handle) Range {
            const start = self.len;
            switch (self.tree.nodes[at.idx()]) {
                .leaf => |view| {
                    const id = idOf(view);
                    if (self.len < self.ids.len and !hidden(view) and !pane_id.eql(id, self.exclude)) {
                        self.ids[self.len] = id;
                        self.len += 1;
                    }
                },
                .split => |s| {
                    const l = self.visit(s.left);
                    const r = self.visit(s.right);
                    if (self.found == null and layoutOf(s.layout) == self.layout and
                        sameSet(self.ids[l.start..l.end], self.before, self.exclude) and
                        sameSet(self.ids[r.start..r.end], self.after, self.exclude))
                    {
                        self.found = at;
                    }
                },
            }
            return .{ .start = start, .end = self.len };
        }
    };
}

/// Whether `have` (no `exclude` in it) is exactly `want` minus `exclude`,
/// and not empty. Ids are unique within a tree, so counting suffices once
/// every member of `have` is in `want`.
fn sameSet(have: []const []const u8, want: []const []const u8, exclude: []const u8) bool {
    if (have.len == 0) return false;
    var wanted: usize = 0;
    for (want) |id| {
        if (!pane_id.eql(id, exclude)) wanted += 1;
    }
    if (wanted != have.len) return false;
    for (have) |id| {
        for (want) |w| {
            if (pane_id.eql(id, w)) break;
        } else return false;
    }
    return true;
}

fn onScreen(rects: []const pane_drop.PaneRect, id: []const u8) bool {
    for (rects) |r| {
        if (pane_id.eql(r.id, id)) return true;
    }
    return false;
}

/// `SplitTree`'s layout as the resolver spells it: a horizontal split is
/// left|right, whose divider runs top to bottom.
fn layoutOf(layout: anytype) pane_drop.RowDirection {
    return switch (layout) {
        .horizontal => .horizontal,
        .vertical => .vertical,
    };
}

// -- tests ----------------------------------------------------------------

const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

/// A view that is its own id, and hands back the same pointer on `ref` the
/// way `PaneView` does.
const TestView = struct {
    id: []const u8,
    stashed: bool = false,

    pub fn ref(self: *TestView, alloc: std.mem.Allocator) std.mem.Allocator.Error!*TestView {
        _ = alloc;
        return self;
    }

    pub fn unref(self: *TestView, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn splitTreeLabel(self: *const TestView) []const u8 {
        return self.id;
    }
};
const TestTree = SplitTree(TestView);

fn testId(v: *TestView) []const u8 {
    return v.id;
}

fn testHidden(v: *TestView) bool {
    return v.stashed;
}

const id_a = "AAAAAAAA-0000-4000-8000-00000000000A";
const id_b = "BBBBBBBB-0000-4000-8000-00000000000B";
const id_c = "CCCCCCCC-0000-4000-8000-00000000000C";
const id_d = "DDDDDDDD-0000-4000-8000-00000000000D";

const m1 = pane_drop.Metrics{ .edge_band = 28, .swap_minimum = 44 };

/// `A | (B over C)`, at 0.5 each.
fn testTree(alloc: std.mem.Allocator, a: *TestView, b: *TestView, c: *TestView) !TestTree {
    var ta: TestTree = try .init(alloc, a);
    defer ta.deinit();
    var tb: TestTree = try .init(alloc, b);
    defer tb.deinit();
    var tc: TestTree = try .init(alloc, c);
    defer tc.deinit();
    var bc = try tb.split(alloc, .root, .down, 0.5, &tc);
    defer bc.deinit();
    return try ta.split(alloc, .root, .right, 0.5, &bc);
}

const tree_rects = [_]pane_drop.PaneRect{
    .{ .id = id_a, .rect = .{ .left = 0, .top = 0, .right = 498, .bottom = 800 } },
    .{ .id = id_b, .rect = .{ .left = 502, .top = 0, .right = 1000, .bottom = 398 } },
    .{ .id = id_c, .rect = .{ .left = 502, .top = 402, .right = 1000, .bottom = 800 } },
};

test "every split with both sides on screen is a divider, outer first" {
    var a: TestView = .{ .id = id_a };
    var b: TestView = .{ .id = id_b };
    var c: TestView = .{ .id = id_c };
    var tree = try testTree(testing.allocator, &a, &b, &c);
    defer tree.deinit();

    var ids: [8][]const u8 = undefined;
    var out: [8]pane_drop.Divider = undefined;
    const n = dividers(TestTree, &tree, testId, &tree_rects, m1, &ids, &out);
    try testing.expectEqual(@as(usize, 2), n);

    try testing.expectEqual(pane_drop.RowDirection.horizontal, out[0].layout);
    try testing.expectEqual(@as(usize, 1), out[0].before.len);
    try testing.expectEqualStrings(id_a, out[0].before[0]);
    try testing.expectEqual(@as(usize, 2), out[0].after.len);
    try testing.expectEqualStrings(id_b, out[0].after[0]);
    try testing.expectEqualStrings(id_c, out[0].after[1]);

    try testing.expectEqual(pane_drop.RowDirection.vertical, out[1].layout);
    try testing.expectEqualStrings(id_b, out[1].before[0]);
    try testing.expectEqualStrings(id_c, out[1].after[0]);
    // The inner divider runs only across its own split.
    try testing.expectEqual(@as(i32, 502), out[1].rect.left);
}

test "a pane with no rect is on neither side, and a side of nothing has no divider" {
    var a: TestView = .{ .id = id_a };
    var b: TestView = .{ .id = id_b };
    var c: TestView = .{ .id = id_c };
    var tree = try testTree(testing.allocator, &a, &b, &c);
    defer tree.deinit();

    // C stashed: off the grid, so B fills the right side alone.
    const rects = [_]pane_drop.PaneRect{ tree_rects[0], tree_rects[1] };
    var ids: [8][]const u8 = undefined;
    var out: [8]pane_drop.Divider = undefined;
    const n = dividers(TestTree, &tree, testId, &rects, m1, &ids, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 1), out[0].after.len);
    try testing.expectEqualStrings(id_b, out[0].after[0]);
}

test "a lone pane has no dividers" {
    var a: TestView = .{ .id = id_a };
    var tree: TestTree = try .init(testing.allocator, &a);
    defer tree.deinit();
    var ids: [2][]const u8 = undefined;
    var out: [2]pane_drop.Divider = undefined;
    try testing.expectEqual(@as(usize, 0), dividers(TestTree, &tree, testId, &tree_rects, m1, &ids, &out));
}

test "findGap names the split a divider's sides describe" {
    var a: TestView = .{ .id = id_a };
    var b: TestView = .{ .id = id_b };
    var c: TestView = .{ .id = id_c };
    var tree = try testTree(testing.allocator, &a, &b, &c);
    defer tree.deinit();
    var ids: [8][]const u8 = undefined;

    const outer = findGap(TestTree, &tree, testId, testHidden, .horizontal, &.{id_a}, &.{ id_c, id_b }, id_d, &ids).?;
    try testing.expect(outer == .root);
    const inner = findGap(TestTree, &tree, testId, testHidden, .vertical, &.{id_b}, &.{id_c}, id_d, &ids).?;
    try testing.expect(tree.nodes[inner.idx()] == .split);
    try testing.expect(inner != .root);
    // The wrong axis, or a side that does not match, is no divider.
    try testing.expect(findGap(TestTree, &tree, testId, testHidden, .vertical, &.{id_a}, &.{ id_b, id_c }, id_d, &ids) == null);
    try testing.expect(findGap(TestTree, &tree, testId, testHidden, .horizontal, &.{id_a}, &.{id_b}, id_d, &ids) == null);
}

test "findGap leaves out the moving pane, and a side it was all of has no gap" {
    var a: TestView = .{ .id = id_a };
    var b: TestView = .{ .id = id_b };
    var c: TestView = .{ .id = id_c };
    var tree = try testTree(testing.allocator, &a, &b, &c);
    defer tree.deinit();
    var ids: [8][]const u8 = undefined;

    // Dragging C onto the A | (B over C) divider, C still in the tree: the
    // divider's right side is B once C has left it.
    const g = findGap(TestTree, &tree, testId, testHidden, .horizontal, &.{id_a}, &.{ id_b, id_c }, id_c, &ids).?;
    try testing.expect(g == .root);
    // Dragging B onto B over C: nothing would be left above the divider.
    try testing.expect(findGap(TestTree, &tree, testId, testHidden, .vertical, &.{id_b}, &.{id_c}, id_b, &ids) == null);
}

test "findGap does not count a stashed pane as part of a side" {
    var a: TestView = .{ .id = id_a };
    var b: TestView = .{ .id = id_b };
    var c: TestView = .{ .id = id_c, .stashed = true };
    var tree = try testTree(testing.allocator, &a, &b, &c);
    defer tree.deinit();
    var ids: [8][]const u8 = undefined;
    try testing.expect(findGap(TestTree, &tree, testId, testHidden, .horizontal, &.{id_a}, &.{id_b}, id_d, &ids).? == .root);
}

test "a dropped pane lands between the divider's sides" {
    // The whole round trip: the divider the resolver saw, found again in the
    // tree and filled, gives A | D | (B over C).
    var a: TestView = .{ .id = id_a };
    var b: TestView = .{ .id = id_b };
    var c: TestView = .{ .id = id_c };
    var d: TestView = .{ .id = id_d };
    const alloc = testing.allocator;
    var tree = try testTree(alloc, &a, &b, &c);
    defer tree.deinit();

    var ids: [8][]const u8 = undefined;
    var out: [8]pane_drop.Divider = undefined;
    _ = dividers(TestTree, &tree, testId, &tree_rects, m1, &ids, &out);
    var find_ids: [8][]const u8 = undefined;
    const at = findGap(TestTree, &tree, testId, testHidden, out[0].layout, out[0].before, out[0].after, id_d, &find_ids).?;

    var leaf: TestTree = try .init(alloc, &d);
    defer leaf.deinit();
    var result = try tree.insertInGap(alloc, at, @floatCast(pane_drop.insert_share), &leaf);
    defer result.deinit();

    var it = result.leafIterator();
    const want = [_][]const u8{ id_a, id_d, id_b, id_c };
    for (want) |w| try testing.expectEqualStrings(w, it.next().?.view.id);
    try testing.expect(it.next() == null);
}
