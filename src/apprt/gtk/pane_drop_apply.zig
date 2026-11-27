//! What a pane drop does to ONE window tab's split tree (T3564, Linux L11b;
//! docs/reference/pane-rearrange.md). Pure - no GTK imports - so these unit
//! tests run in every app-runtime lane, the `win32/pane_drop.zig` pattern.
//!
//! The resolver (`win32/pane_drop.zig`) says what a point means; this makes
//! it so: `apply` for the drops that stay inside the tree the pane came from
//! (a split of another pane, a swap with it, an insert at the top level of
//! the window, an insert in a divider's gap), `applyArriving` for the same
//! drops into another tab's tree, and `tabDrop` for a release on the tab bar
//! (T3615). A new window and cross-window drops are follow-up cards (T3616,
//! T3618).
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
const pane_relocate = @import("../win32/pane_relocate.zig");
const pane_stash = @import("../win32/pane_stash.zig");

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
        const root = shape.fromTree(Tree, tree, idOf, stashed(Tree.View));
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
                stashed(Tree.View),
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
        // A strip moved along the row it is folded into (T3629, Mac
        // `PaneMoveCoordinator.reorder`, win32 `commitReorderDrop`): out of
        // where it is, and in beside the row's item made of exactly the
        // panes `beside`, on `side`, halving that item's space.
        .reorder => |s| {
            if (s.beside.len == 0) return .not_here;
            const view = tree.nodes[at.idx()].leaf;
            var leaf = try Tree.init(alloc, view);
            defer leaf.deinit();
            var rest = try @constCast(tree).remove(alloc, at);
            defer rest.deinit();
            // Found in the tree WITHOUT the pane: a column the strip was one
            // pane of is named by the panes left in it.
            const index = pane_relocate.nodeWithPanes(&rest, s.beside, idOf) orelse return .not_here;
            const item: Tree.Node.Handle = @enumFromInt(index);
            return .{ .moved = try rest.split(alloc, item, direction(Tree, s.side), split_ratio, &leaf) };
        },
        .new_tab, .new_window, .stash, .sidebar_order, .join_window, .tile => return .not_here,
    }
}

/// The two trees a drop from ANOTHER tree changes (T3615): the one the pane
/// left and the one it arrived in. `source` is `.empty` when the pane was its
/// tab's last one - that tab then closes, which is how a dwell-switched drop
/// empties a tab.
pub fn Arrival(comptime Tree: type) type {
    return union(enum) {
        moved: struct { source: Tree, dest: Tree },
        /// Not a drop into `dest`, or its pane or divider is gone.
        not_here,
    };
}

/// Make `target` happen to `dest` for the pane `dragged` of ANOTHER tree,
/// `source` (T3615): the drop a 500ms tab dwell makes possible, into a tab
/// the pane was not in. The same targets as `apply`, built from the shared
/// cross-tree moves (`SplitTree.moveTo`/`swapWith`, the Mac's) so the pane
/// that lands is the very pane that left. A move into another tree is never
/// "in place", so there is no `.in_place` answer.
pub fn applyArriving(
    comptime Tree: type,
    alloc: Allocator,
    source: *const Tree,
    dest: *const Tree,
    comptime idOf: fn (*Tree.View) []const u8,
    dragged: []const u8,
    target: pane_drop.Target,
) Allocator.Error!Arrival(Tree) {
    const at = handleOf(Tree, source, idOf, dragged) orelse return .not_here;
    // A pane already in `dest` is `apply`'s business, not an arrival.
    if (handleOf(Tree, dest, idOf, dragged) != null) return .not_here;
    switch (target) {
        .split => |s| {
            const other = handleOf(Tree, dest, idOf, s.pane) orelse return .not_here;
            const r = try source.moveTo(alloc, at, dest, other, direction(Tree, s.side), split_ratio);
            return .{ .moved = .{ .source = r.source, .dest = r.dest } };
        },
        .swap => |s| {
            const other = handleOf(Tree, dest, idOf, s.pane) orelse return .not_here;
            const r = try source.swapWith(alloc, at, dest, other);
            return .{ .moved = .{ .source = r.a, .dest = r.b } };
        },
        .top_level => |s| {
            var leaf = try Tree.init(alloc, source.nodes[at.idx()].leaf);
            defer leaf.deinit();
            // The destination first, while the source still holds the view
            // (the `moveTo` order): its count never reaches zero between.
            var new_dest = try dest.insertAtTopLevel(alloc, direction(Tree, s.side), split_ratio, &leaf);
            errdefer new_dest.deinit();
            return .{ .moved = .{ .source = try @constCast(source).remove(alloc, at), .dest = new_dest } };
        },
        .insert => |s| {
            var ids: [max_leaves][]const u8 = undefined;
            if (dest.nodes.len > ids.len) return .not_here;
            // The pane is not in `dest`, so its gap is read off `dest` as is.
            const gap = pane_gap.findGap(
                Tree,
                dest,
                idOf,
                stashed(Tree.View),
                s.layout,
                s.before,
                s.after,
                dragged,
                &ids,
            ) orelse return .not_here;
            var leaf = try Tree.init(alloc, source.nodes[at.idx()].leaf);
            defer leaf.deinit();
            var new_dest = try dest.insertInGap(alloc, gap, @floatCast(pane_drop.insert_share), &leaf);
            errdefer new_dest.deinit();
            return .{ .moved = .{ .source = try @constCast(source).remove(alloc, at), .dest = new_dest } };
        },
        .new_tab, .new_window, .stash, .sidebar_order, .join_window, .reorder, .tile => return .not_here,
    }
}

/// What a release on the tab bar does (T3615, win32 `canNewTabDrop`, Mac
/// `.newTab`): `seam` is the resolver's insertion index (0 = before the
/// first tab, `tab_count` = after the last).
pub const TabDrop = union(enum) {
    /// Take the pane out of its tab into a new tab of its own, inserted at
    /// this position.
    new_tab: usize,
    /// The pane is its tab's only one - already a tab of its own - so the
    /// gesture means "put the tab there": move the tab to this position.
    reorder: usize,
    /// The pane's own tab, dropped right where it is: nothing happens.
    in_place,
};

/// The tab-bar drop for the pane being dragged: `leaves` is how many panes
/// its tab (`source_tab`) holds. A window's only tab with its only pane is
/// always `.in_place`, so a drag never closes a window this way.
pub fn tabDrop(leaves: usize, source_tab: usize, seam: usize, tab_count: usize) TabDrop {
    if (source_tab >= tab_count) return .in_place;
    if (leaves > 1) return .{ .new_tab = @min(seam, tab_count) };
    if (pane_relocate.tabReorderIndex(source_tab, seam, tab_count)) |to| return .{ .reorder = to };
    return .in_place;
}

/// May the pane be moved into a new window of its own (T3618): a release
/// over nothing, or the header's pop-out button? `leaves` is how many panes
/// its tab holds, `tab_count` how many tabs its window has. A window's last
/// pane may not - the move would close one window to open another around
/// the very same pane, and a window closing as a drag's side effect skips
/// its close confirmation (Mac `PaneHeaderView.canPopOut`, win32
/// `pane_relocate.popOutAllowed`). Joining ANOTHER window stays allowed.
pub fn popOutAllowed(leaves: usize, tab_count: usize) bool {
    if (leaves == 0 or tab_count == 0) return false;
    return pane_relocate.popOutAllowed(leaves, tab_count);
}

/// The size a popped-out window opens at: the window it leaves, or - when
/// that one is maximized or fullscreen - its restored (default) size, so
/// the new window is not a second screen-filling one (win32 T1546). Null
/// when neither is known: the new window takes its own estimate.
pub fn popOutSize(w: c_int, h: c_int, filling: bool, restored_w: c_int, restored_h: c_int) ?[2]c_int {
    if (filling) {
        if (restored_w > 0 and restored_h > 0) return .{ restored_w, restored_h };
        return null;
    }
    if (w > 0 and h > 0) return .{ w, h };
    return null;
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

/// The leaves a drop does not see: stashed panes (T3596; T3667, win32
/// `paneViewStashed`). They are in the tree but not on screen, so "would
/// this drop change anything" and "which gap is this" are answered over
/// the arrangement on show.
/// Whether a release of `dragged` on `target` in `tree` would change
/// anything - what the live preview asks on every drag motion (T3708; Mac
/// `wouldLeaveInPlace`, win32 `dropLeavesInPlace`): a spot that would leave
/// the pane where it is has no preview, the same rule `apply` answers
/// `.in_place` by, so the preview cannot promise a move the release refuses.
/// A pane that is not in this tree is arriving from another tab or window,
/// so every place is a new one to it. Allocates nothing.
pub fn wouldMove(
    comptime Tree: type,
    tree: *const Tree,
    comptime idOf: fn (*Tree.View) []const u8,
    dragged: []const u8,
    target: pane_drop.Target,
) bool {
    if (handleOf(Tree, tree, idOf, dragged) == null) return true;
    switch (target) {
        .split => |s| if (pane_id.eql(s.pane, dragged)) return false,
        .swap => |s| return !pane_id.eql(s.pane, dragged),
        else => {},
    }
    const move = pane_layout.Move.of(target) orelse return true;
    var shape: pane_layout.Shape = .{};
    const root = shape.fromTree(Tree, tree, idOf, stashed(Tree.View));
    return !shape.wouldLeaveInPlace(root, dragged, move);
}

fn stashed(comptime View: type) fn (*View) bool {
    return struct {
        fn f(v: *View) bool {
            return pane_stash.isStashed(v);
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
    stash_seq: u64 = 0,

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

test "T3667: a drop is judged over the panes on show, a stashed one unseen" {
    // H(a, H(b, c)) with b stashed shows a | c. Dropping c to the right of a
    // changes nothing anyone can see: no drop. With b on show it is a move.
    var views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var tree = try threeAcross(&views);
    defer tree.deinit();
    const target: pane_drop.Target = .{ .split = .{ .window = 1, .pane = "a", .side = .right } };
    var shown = try apply(TestTree, testing.allocator, &tree, testId, "c", target);
    switch (shown) {
        .moved => |*t| t.deinit(),
        else => return error.TestUnexpectedResult,
    }
    pane_stash.mark(&views[1]);
    const hidden = try apply(TestTree, testing.allocator, &tree, testId, "c", target);
    try testing.expect(hidden == .in_place);
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

test "a strip reorder moves the pane beside the named item, halving it (T3629)" {
    // a | b | c, the strip c dropped before a: the item a is halved and c
    // sits on its left.
    var views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var tree = try threeAcross(&views);
    defer tree.deinit();
    const beside = [_][]const u8{"a"};
    var out = try apply(TestTree, testing.allocator, &tree, testId, "c", .{ .reorder = .{
        .window = 1,
        .beside = &beside,
        .side = .left,
        .caret = .{ .left = 0, .top = 0, .right = 1, .bottom = 1 },
    } });
    switch (out) {
        .moved => |*t| {
            defer t.deinit();
            try expectShape(t, "H(H(c,a),b)");
            // The very view moved, not a copy.
            const h = handleOf(TestTree, t, testId, "c").?;
            try testing.expect(t.nodes[h.idx()].leaf == &views[2]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a strip reorder beside a column names the column by its panes (T3629)" {
    // a | V(b, c): the strip a dropped after the column b,c.
    const alloc = testing.allocator;
    var views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var a = try TestTree.init(alloc, &views[0]);
    defer a.deinit();
    var b = try TestTree.init(alloc, &views[1]);
    defer b.deinit();
    var c = try TestTree.init(alloc, &views[2]);
    defer c.deinit();
    var bc = try b.split(alloc, .root, .down, 0.5, &c);
    defer bc.deinit();
    var tree = try a.split(alloc, .root, .right, 0.5, &bc);
    defer tree.deinit();
    const beside = [_][]const u8{ "b", "c" };
    var out = try apply(TestTree, alloc, &tree, testId, "a", .{ .reorder = .{
        .window = 1,
        .beside = &beside,
        .side = .right,
        .caret = .{ .left = 0, .top = 0, .right = 1, .bottom = 1 },
    } });
    switch (out) {
        .moved => |*t| {
            defer t.deinit();
            try expectShape(t, "H(V(b,c),a)");
        },
        else => return error.TestUnexpectedResult,
    }
    // An item that is not in the tree is no drop.
    const gone = [_][]const u8{"z"};
    const none = try apply(TestTree, alloc, &tree, testId, "a", .{ .reorder = .{
        .window = 1,
        .beside = &gone,
        .side = .right,
        .caret = .{ .left = 0, .top = 0, .right = 1, .bottom = 1 },
    } });
    try testing.expect(none == .not_here);
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

// -- T3615: arrivals from another tab, and the tab bar ------------------------

/// x | y as H(x, y): another tab's tree.
fn twoAcross(views: *[2]TestView) !TestTree {
    const alloc = testing.allocator;
    var x = try TestTree.init(alloc, &views[0]);
    defer x.deinit();
    var y = try TestTree.init(alloc, &views[1]);
    defer y.deinit();
    return try x.split(alloc, .root, .right, 0.5, &y);
}

test "a pane arriving from another tab splits a pane there and leaves its old tab" {
    var src_views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var dst_views = [_]TestView{ .{ .id = "x" }, .{ .id = "y" } };
    var src = try threeAcross(&src_views);
    defer src.deinit();
    var dst = try twoAcross(&dst_views);
    defer dst.deinit();
    var out = try applyArriving(TestTree, testing.allocator, &src, &dst, testId, "a", .{ .split = .{ .window = 1, .pane = "y", .side = .down } });
    switch (out) {
        .moved => |*m| {
            defer m.source.deinit();
            defer m.dest.deinit();
            try expectShape(&m.source, "H(b,c)");
            try expectShape(&m.dest, "H(x,V(y,a))");
            // The very same view: the shell that left is the one that lands.
            const h = handleOf(TestTree, &m.dest, testId, "a").?;
            try testing.expect(m.dest.nodes[h.idx()].leaf == &src_views[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a swap across tabs puts each pane in the other's place" {
    var src_views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var dst_views = [_]TestView{ .{ .id = "x" }, .{ .id = "y" } };
    var src = try threeAcross(&src_views);
    defer src.deinit();
    var dst = try twoAcross(&dst_views);
    defer dst.deinit();
    var out = try applyArriving(TestTree, testing.allocator, &src, &dst, testId, "b", .{ .swap = .{ .window = 1, .pane = "x" } });
    switch (out) {
        .moved => |*m| {
            defer m.source.deinit();
            defer m.dest.deinit();
            try expectShape(&m.source, "H(a,H(x,c))");
            try expectShape(&m.dest, "H(b,y)");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a tab's last pane arriving elsewhere leaves its tab empty" {
    const alloc = testing.allocator;
    var only = [_]TestView{.{ .id = "a" }};
    var dst_views = [_]TestView{ .{ .id = "x" }, .{ .id = "y" } };
    var src = try TestTree.init(alloc, &only[0]);
    defer src.deinit();
    var dst = try twoAcross(&dst_views);
    defer dst.deinit();
    var top = try applyArriving(TestTree, alloc, &src, &dst, testId, "a", .{ .top_level = .{ .window = 1, .side = .up } });
    switch (top) {
        .moved => |*m| {
            defer m.source.deinit();
            defer m.dest.deinit();
            try testing.expect(m.source.isEmpty());
            try expectShape(&m.dest, "V(a,H(x,y))");
        },
        else => return error.TestUnexpectedResult,
    }
    const before = [_][]const u8{"x"};
    const after = [_][]const u8{"y"};
    var gap = try applyArriving(TestTree, alloc, &src, &dst, testId, "a", .{ .insert = .{
        .window = 1,
        .before = &before,
        .after = &after,
        .layout = .horizontal,
        .landing = .{ .left = 0, .top = 0, .right = 1, .bottom = 1 },
    } });
    switch (gap) {
        .moved => |*m| {
            defer m.source.deinit();
            defer m.dest.deinit();
            try testing.expect(m.source.isEmpty());
            try expectShape(&m.dest, "H(x,H(a,y))");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "an arrival names a pane of the destination, never one it is already in" {
    var src_views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var dst_views = [_]TestView{ .{ .id = "x" }, .{ .id = "y" } };
    var src = try threeAcross(&src_views);
    defer src.deinit();
    var dst = try twoAcross(&dst_views);
    defer dst.deinit();
    const alloc = testing.allocator;
    // b is in the source, not the destination: no pane to split there.
    try testing.expect(try applyArriving(TestTree, alloc, &src, &dst, testId, "a", .{ .split = .{ .window = 1, .pane = "b", .side = .left } }) == .not_here);
    // The pane is not in the source at all.
    try testing.expect(try applyArriving(TestTree, alloc, &src, &dst, testId, "zz", .{ .swap = .{ .window = 1, .pane = "x" } }) == .not_here);
    // Already in the destination: that is `apply`'s, not an arrival.
    try testing.expect(try applyArriving(TestTree, alloc, &dst, &dst, testId, "x", .{ .swap = .{ .window = 1, .pane = "y" } }) == .not_here);
    try testing.expect(try applyArriving(TestTree, alloc, &src, &dst, testId, "a", .{ .new_tab = .{ .window = 1, .index = 0 } }) == .not_here);
}

test "a tab-bar drop makes a new tab, or moves a lone pane's tab, or nothing" {
    // A tab of several panes: a new tab at the seam, clamped to the end.
    try testing.expectEqual(TabDrop{ .new_tab = 0 }, tabDrop(3, 0, 0, 2));
    try testing.expectEqual(TabDrop{ .new_tab = 2 }, tabDrop(3, 0, 5, 2));
    // A lone pane is already a tab: the drop moves its tab to the seam...
    try testing.expectEqual(TabDrop{ .reorder = 2 }, tabDrop(1, 0, 3, 3));
    try testing.expectEqual(TabDrop{ .reorder = 0 }, tabDrop(1, 2, 0, 3));
    // ...and the seams either side of it are where it already is.
    try testing.expectEqual(TabDrop.in_place, tabDrop(1, 1, 1, 3));
    try testing.expectEqual(TabDrop.in_place, tabDrop(1, 1, 2, 3));
    // A window's only tab holding its only pane: never closes the window.
    try testing.expectEqual(TabDrop.in_place, tabDrop(1, 0, 0, 1));
    try testing.expectEqual(TabDrop.in_place, tabDrop(1, 0, 1, 1));
}

test "the resolver's tab bar answer drives tabDrop end to end" {
    // Two tab buttons across a 400px bar: over the second means seam 1.
    const tabs = [_]pane_drop.Rect{
        .{ .left = 0, .top = 0, .right = 200, .bottom = 34 },
        .{ .left = 200, .top = 0, .right = 400, .bottom = 34 },
    };
    const bar: pane_drop.Candidate = .{
        .window = 1,
        .z_order = 0,
        .content_rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .pane_rects = &.{},
        .tab_bar_rect = .{ .left = 0, .top = 0, .right = 400, .bottom = 34 },
        .tab_button_rects = &tabs,
    };
    const metrics = pane_drop.Metrics.forScale(1.0);
    const t = pane_drop.resolve(.{ .x = 300, .y = 17 }, &.{bar}, "a", metrics) orelse
        return error.TestUnexpectedResult;
    try testing.expect(t == .new_tab);
    try testing.expectEqual(@as(usize, 1), t.new_tab.index);
    try testing.expectEqual(TabDrop{ .new_tab = 1 }, tabDrop(2, 0, t.new_tab.index, 2));
    // And the same point is a dwell on tab 1.
    try testing.expectEqual(@as(usize, 1), pane_drop.hoveredTab(.{ .x = 300, .y = 17 }, &.{bar}).?.index);
}

test "a pane may pop out into a new window unless it is its window's last" {
    // A window's only pane in its only tab: refused.
    try testing.expect(!popOutAllowed(1, 1));
    // A pane with a sibling in its tab, or a lone pane with another tab.
    try testing.expect(popOutAllowed(2, 1));
    try testing.expect(popOutAllowed(1, 2));
    try testing.expect(popOutAllowed(3, 4));
    // A tree or window that reads empty has no pane to move.
    try testing.expect(!popOutAllowed(0, 2));
    try testing.expect(!popOutAllowed(2, 0));
}

test "a popped-out window takes its source's size, or the restored size of a filling one" {
    try testing.expectEqual([2]c_int{ 900, 600 }, popOutSize(900, 600, false, 500, 400).?);
    // Maximized or fullscreen: the restored size, never a second full screen.
    try testing.expectEqual([2]c_int{ 500, 400 }, popOutSize(1920, 1080, true, 500, 400).?);
    try testing.expect(popOutSize(1920, 1080, true, 0, 0) == null);
    // Nothing laid out yet: the new window's own estimate.
    try testing.expect(popOutSize(0, 0, false, 500, 400) == null);
}

test "T3708: the preview's rule - a spot that would leave the pane where it is moves nothing" {
    // x | y, dragging x.
    var views = [_]TestView{ .{ .id = "x" }, .{ .id = "y" } };
    var tree = try twoAcross(&views);
    defer tree.deinit();
    const w: pane_drop.WindowRef = 1;
    // y's left half, and the window's left edge, put x back where it is.
    try testing.expect(!wouldMove(TestTree, &tree, testId, "x", .{ .split = .{ .window = w, .pane = "y", .side = .left } }));
    try testing.expect(!wouldMove(TestTree, &tree, testId, "x", .{ .top_level = .{ .window = w, .side = .left } }));
    // Every other half of y, the right edge and a swap all move it.
    try testing.expect(wouldMove(TestTree, &tree, testId, "x", .{ .split = .{ .window = w, .pane = "y", .side = .right } }));
    try testing.expect(wouldMove(TestTree, &tree, testId, "x", .{ .split = .{ .window = w, .pane = "y", .side = .down } }));
    try testing.expect(wouldMove(TestTree, &tree, testId, "x", .{ .top_level = .{ .window = w, .side = .right } }));
    try testing.expect(wouldMove(TestTree, &tree, testId, "x", .{ .swap = .{ .window = w, .pane = "y" } }));
    // Onto itself: nothing, whatever the kind.
    try testing.expect(!wouldMove(TestTree, &tree, testId, "x", .{ .swap = .{ .window = w, .pane = "x" } }));
    try testing.expect(!wouldMove(TestTree, &tree, testId, "x", .{ .split = .{ .window = w, .pane = "x", .side = .up } }));
    // A pane from another tab or window: every place is new to it.
    try testing.expect(wouldMove(TestTree, &tree, testId, "a", .{ .split = .{ .window = w, .pane = "y", .side = .left } }));
    try testing.expect(wouldMove(TestTree, &tree, testId, "a", .{ .top_level = .{ .window = w, .side = .left } }));
}

test "T3708: the preview's rule agrees with what the release does" {
    // Every split side of every pane and every edge: wouldMove is false
    // exactly where `apply` answers in_place.
    var views = [_]TestView{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" } };
    var tree = try threeAcross(&views);
    defer tree.deinit();
    const sides = [_]pane_drop.Side{ .left, .right, .up, .down };
    const ids = [_][]const u8{ "a", "b", "c" };
    for (ids) |dragged| {
        for (ids) |other| for (sides) |side| {
            const t: pane_drop.Target = .{ .split = .{ .window = 1, .pane = other, .side = side } };
            var out = try apply(TestTree, testing.allocator, &tree, testId, dragged, t);
            const moved = switch (out) {
                .moved => |*m| blk: {
                    m.deinit();
                    break :blk true;
                },
                else => false,
            };
            try testing.expectEqual(moved, wouldMove(TestTree, &tree, testId, dragged, t));
        };
        for (sides) |side| {
            const t: pane_drop.Target = .{ .top_level = .{ .window = 1, .side = side } };
            var out = try apply(TestTree, testing.allocator, &tree, testId, dragged, t);
            const moved = switch (out) {
                .moved => |*m| blk: {
                    m.deinit();
                    break :blk true;
                },
                else => false,
            };
            try testing.expectEqual(moved, wouldMove(TestTree, &tree, testId, dragged, t));
        }
    }
}
