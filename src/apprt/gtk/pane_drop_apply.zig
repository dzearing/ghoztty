//! What a pane drop does to ONE window tab's split tree (T3564, Linux L11b;
//! docs/reference/pane-rearrange.md). Pure - no GTK imports - so these unit
//! tests run in every app-runtime lane, the `win32/pane_drop.zig` pattern.
//!
//! The resolver (`win32/pane_drop.zig`) says what a point means; this makes
//! it so. Only the drops that stay inside the tree the pane came from are
//! here: a split of another pane, a swap with it, an insert at the top level
//! of the window, and an insert in a divider's gap. The tab bar, a new window
//! and the other cross-tree drops are the drag's other half (the follow-up
//! cards T3564 filed).
//!
//! Every result holds the very same views (`SplitTree.move` and friends), so
//! a terminal that moves keeps its shell, its scrollback and its pane id -
//! the identity rule `+rearrange` follows (T3368).
//!
//! **A drop that would change nothing is no drop** (Mac
//! `PaneMoveCoordinator.wouldLeaveInPlace`, win32 T2705): `apply` answers
//! `.in_place` for it, made on a copy and compared by layout
//! (`win32/pane_layout.zig`), so the answer cannot disagree with the move.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const pane_drop = @import("../win32/pane_drop.zig");
const pane_gap = @import("../win32/pane_gap.zig");
const pane_layout = @import("../win32/pane_layout.zig");
const pane_id = @import("../ipc/pane_id.zig");

/// The ratio a split or top-level drop gives the two sides: halves, as
/// win32's `drop_highlight.insert_ratio` and the Mac's drop do.
pub const split_ratio: f16 = 0.5;

/// Most leaves a tree may have for the scratch buffers below; a bigger tree
/// is refused rather than walked past its end.
pub const max_leaves: usize = 128;

pub fn Outcome(comptime Tree: type) type {
    return union(enum) {
        /// The new tree; the caller installs it and deinits it.
        moved: Tree,
        /// The drop would leave the pane where it is: nothing happens.
        in_place,
        /// Not a drop inside this tree (a tab, a window, the sidebar, or a
        /// target in another window), or its pane or divider is gone.
        not_here,
    };
}

/// Make `target` happen to `tree`, for the pane `dragged`. `idOf` names a
/// view's pane id. Nothing is mutated: the answer is a new tree or a reason
/// there is none.
pub fn apply(
    comptime Tree: type,
    alloc: Allocator,
    tree: *const Tree,
    comptime idOf: fn (*Tree.View) []const u8,
    dragged: []const u8,
    target: pane_drop.Target,
) Allocator.Error!Outcome(Tree) {
    const at = handleOf(Tree, tree, idOf, dragged) orelse return .not_here;

    if (pane_layout.Move.of(target)) |move| {
        var shape: pane_layout.Shape = .{};
        const root = shape.fromTree(Tree, tree, idOf, never(Tree.View));
        if (shape.wouldLeaveInPlace(root, dragged, move)) return .in_place;
    }

    switch (target) {
        .split => |s| {
            const other = handleOf(Tree, tree, idOf, s.pane) orelse return .not_here;
            if (other == at) return .in_place;
            return .{ .moved = try tree.move(alloc, at, other, direction(Tree, s.side), split_ratio) };
        },
        .swap => |s| {
            const other = handleOf(Tree, tree, idOf, s.pane) orelse return .not_here;
            if (other == at) return .in_place;
            return .{ .moved = try tree.swap(alloc, at, other) };
        },
        .top_level => |s| {
            const view = tree.nodes[at.idx()].leaf;
            var leaf = try Tree.init(alloc, view);
            defer leaf.deinit();
            // Remove first: `insertAtTopLevel` wraps the root, so every
            // handle survives it, but the removal has to see the tree the
            // pane is still in.
            var rest = try @constCast(tree).remove(alloc, at);
            defer rest.deinit();
            return .{ .moved = try rest.insertAtTopLevel(alloc, direction(Tree, s.side), split_ratio, &leaf) };
        },
        .insert => |s| {
            var ids: [max_leaves][]const u8 = undefined;
            if (tree.nodes.len > ids.len) return .not_here;
            const view = tree.nodes[at.idx()].leaf;
            var rest = try @constCast(tree).remove(alloc, at);
            defer rest.deinit();
            // The divider is looked up in the tree WITHOUT the pane, where
            // the gap it is inserted into actually is.
            const gap = pane_gap.findGap(
                Tree,
                &rest,
                idOf,
                never(Tree.View),
                s.layout,
                s.before,
                s.after,
                dragged,
                &ids,
            ) orelse return .not_here;
            var leaf = try Tree.init(alloc, view);
            defer leaf.deinit();
            return .{ .moved = try rest.insertInGap(alloc, gap, @floatCast(pane_drop.insert_share), &leaf) };
        },
        .new_tab, .new_window, .stash, .sidebar_order, .join_window, .reorder, .tile => return .not_here,
    }
}

/// The handle of the leaf whose pane id is `id`, or null.
pub fn handleOf(
    comptime Tree: type,
    tree: *const Tree,
    comptime idOf: fn (*Tree.View) []const u8,
    id: []const u8,
) ?Tree.Node.Handle {
    for (tree.nodes, 0..) |node, i| switch (node) {
        .leaf => |v| if (pane_id.eql(idOf(v), id)) return @enumFromInt(i),
        .split => {},
    };
    return null;
}

/// The divider candidates of `tree` for the resolver, from the leaves'
/// rects. `ids` and `out` are the caller's scratch and must outlive the
/// returned slice (the dividers borrow `ids`).
pub fn dividers(
    comptime Tree: type,
    tree: *const Tree,
    comptime idOf: fn (*Tree.View) []const u8,
    rects: []const pane_drop.PaneRect,
    metrics: pane_drop.Metrics,
    ids: [][]const u8,
    out: []pane_drop.Divider,
) []const pane_drop.Divider {
    if (tree.nodes.len > ids.len) return out[0..0];
    const n = pane_gap.dividers(Tree, tree, idOf, rects, metrics, ids, out);
    return out[0..n];
}

/// GTK has no stashed panes yet (T3596), so no leaf is hidden.
fn never(comptime View: type) fn (*View) bool {
    return struct {
        fn f(_: *View) bool {
            return false;
        }
    }.f;
}

fn direction(comptime Tree: type, side: pane_drop.Side) Tree.Split.Direction {
    return switch (side) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    };
}

// -- tests ------------------------------------------------------------------

const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

const TestView = struct {
    id: []const u8,

    pub fn ref(self: *TestView, _: Allocator) Allocator.Error!*TestView {
        return self;
    }
    pub fn unref(_: *TestView, _: Allocator) void {}
    pub fn splitTreeLabel(self: *const TestView) []const u8 {
        return self.id;
    }
};
const TestTree = SplitTree(TestView);

fn testId(v: *TestView) []const u8 {
    return v.id;
}

/// `H(a,b)` style text of a tree's shape, for comparing results.
fn shapeText(tree: *const TestTree, at: TestTree.Node.Handle, buf: *std.ArrayList(u8)) !void {
    switch (tree.nodes[at.idx()]) {
        .leaf => |v| try buf.appendSlice(testing.allocator, v.id),
        .split => |s| {
            try buf.appendSlice(testing.allocator, if (s.layout == .horizontal) "H(" else "V(");
            try shapeText(tree, s.left, buf);
            try buf.append(testing.allocator, ',');
            try shapeText(tree, s.right, buf);
            try buf.append(testing.allocator, ')');
        },
    }
}

fn expectShape(tree: *const TestTree, want: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try shapeText(tree, .root, &buf);
    try testing.expectEqualStrings(want, buf.items);
}

/// a | b | c as H(a, H(b, c)).
fn threeAcross(views: *[3]TestView) !TestTree {
    const alloc = testing.allocator;
    var a = try TestTree.init(alloc, &views[0]);
    defer a.deinit();
    var b = try TestTree.init(alloc, &views[1]);
    defer b.deinit();
    var c = try TestTree.init(alloc, &views[2]);
    defer c.deinit();
    var bc = try b.split(alloc, .root, .right, 0.5, &c);
    defer bc.deinit();
    return try a.split(alloc, .root, .right, 0.33, &bc);
}

test "a split drop moves the pane beside the other one, keeping the same view" {
    var views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var tree = try threeAcross(&views);
    defer tree.deinit();
    var out = try apply(TestTree, testing.allocator, &tree, testId, "a", .{ .split = .{ .window = 1, .pane = "c", .side = .down } });
    switch (out) {
        .moved => |*t| {
            defer t.deinit();
            try expectShape(t, "H(b,V(c,a))");
            const h = handleOf(TestTree, t, testId, "a").?;
            try testing.expect(t.nodes[h.idx()].leaf == &views[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a swap exchanges two panes in place" {
    var views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var tree = try threeAcross(&views);
    defer tree.deinit();
    var out = try apply(TestTree, testing.allocator, &tree, testId, "a", .{ .swap = .{ .window = 1, .pane = "c" } });
    switch (out) {
        .moved => |*t| {
            defer t.deinit();
            try expectShape(t, "H(c,H(b,a))");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a top-level drop spans the whole side of the window" {
    var views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var tree = try threeAcross(&views);
    defer tree.deinit();
    var out = try apply(TestTree, testing.allocator, &tree, testId, "b", .{ .top_level = .{ .window = 1, .side = .up } });
    switch (out) {
        .moved => |*t| {
            defer t.deinit();
            try expectShape(t, "V(b,H(a,c))");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a divider drop inserts the pane in that gap" {
    var views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var tree = try threeAcross(&views);
    defer tree.deinit();
    const before = [_][]const u8{"a"};
    const after = [_][]const u8{"b"};
    var out = try apply(TestTree, testing.allocator, &tree, testId, "c", .{ .insert = .{
        .window = 1,
        .before = &before,
        .after = &after,
        .layout = .horizontal,
        .landing = .{ .left = 0, .top = 0, .right = 1, .bottom = 1 },
    } });
    switch (out) {
        .moved => |*t| {
            defer t.deinit();
            try expectShape(t, "H(a,H(c,b))");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a drop that would leave the pane where it is does nothing" {
    // In a | b, dragging a: b's left side and the window's left edge both
    // rebuild the layout a | b.
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" } };
    var a = try TestTree.init(alloc, &views[0]);
    defer a.deinit();
    var b = try TestTree.init(alloc, &views[1]);
    defer b.deinit();
    var tree = try a.split(alloc, .root, .right, 0.5, &b);
    defer tree.deinit();

    const left_of_b = try apply(TestTree, alloc, &tree, testId, "a", .{ .split = .{ .window = 1, .pane = "b", .side = .left } });
    try testing.expect(left_of_b == .in_place);
    const left_edge = try apply(TestTree, alloc, &tree, testId, "a", .{ .top_level = .{ .window = 1, .side = .left } });
    try testing.expect(left_edge == .in_place);

    // ...while the right edge is a real move.
    var right_edge = try apply(TestTree, alloc, &tree, testId, "a", .{ .top_level = .{ .window = 1, .side = .right } });
    switch (right_edge) {
        .moved => |*t| {
            defer t.deinit();
            try expectShape(t, "H(b,a)");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a drop that is not inside this tree, or names a gone pane, is not here" {
    var views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var tree = try threeAcross(&views);
    defer tree.deinit();
    const alloc = testing.allocator;
    try testing.expect(try apply(TestTree, alloc, &tree, testId, "a", .{ .new_tab = .{ .window = 1, .index = 0 } }) == .not_here);
    try testing.expect(try apply(TestTree, alloc, &tree, testId, "a", .{ .new_window = .{ .x = 0, .y = 0 } }) == .not_here);
    try testing.expect(try apply(TestTree, alloc, &tree, testId, "a", .{ .swap = .{ .window = 1, .pane = "zz" } }) == .not_here);
    try testing.expect(try apply(TestTree, alloc, &tree, testId, "zz", .{ .swap = .{ .window = 1, .pane = "a" } }) == .not_here);
}

test "the resolver and apply agree end to end on a laid-out window" {
    // a | b side by side, 0..200 x 0..100, dragging a onto b's lower
    // triangle (below the 44px swap box, nearest the bottom): split b
    // downward. The window is under four edge bands tall, so it has none.
    var views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" } };
    const alloc = testing.allocator;
    var a = try TestTree.init(alloc, &views[0]);
    defer a.deinit();
    var b = try TestTree.init(alloc, &views[1]);
    defer b.deinit();
    var tree = try a.split(alloc, .root, .right, 0.5, &b);
    defer tree.deinit();

    const rects = [_]pane_drop.PaneRect{
        .{ .id = "a", .rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 } },
        .{ .id = "b", .rect = .{ .left = 100, .top = 0, .right = 200, .bottom = 100 } },
    };
    const metrics = pane_drop.Metrics.forScale(1.0);
    var ids: [max_leaves][]const u8 = undefined;
    var divs: [max_leaves]pane_drop.Divider = undefined;
    const candidate: pane_drop.Candidate = .{
        .window = 1,
        .z_order = 0,
        .content_rect = .{ .left = 0, .top = 0, .right = 200, .bottom = 100 },
        .pane_rects = &rects,
        .dividers = dividers(TestTree, &tree, testId, &rects, metrics, &ids, &divs),
    };
    const target = pane_drop.resolve(.{ .x = 150, .y = 90 }, &.{candidate}, "a", metrics) orelse
        return error.TestUnexpectedResult;
    try testing.expect(target == .split);
    try testing.expectEqual(pane_drop.Side.down, target.split.side);
    var out = try apply(TestTree, alloc, &tree, testId, "a", target);
    switch (out) {
        .moved => |*t| {
            defer t.deinit();
            try expectShape(t, "V(b,a)");
        },
        else => return error.TestUnexpectedResult,
    }
}
