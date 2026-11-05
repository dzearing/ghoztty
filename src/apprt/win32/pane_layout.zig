//! Whether a pane drop would leave the pane where it already is (T2705). Pure
//! — no OS imports — so these unit tests run in every app-runtime lane, the
//! `pane_drop.zig` pattern.
//!
//! Mac parity: `PaneMoveCoordinator.wouldLeaveInPlace` and
//! `SplitTree.hasSameLayout` (30d13ea14). A split, divider or window-edge
//! target that would change nothing on screen has no target and no preview,
//! and a release there does nothing: in A | B, dragging A, B's left triangle,
//! the divider and the window's left edge are all quiet.
//!
//! The answer comes from MAKING the move, on a copy, and comparing layouts,
//! so it cannot disagree with the move itself. The copy is a `Shape`: the
//! visible tree reduced to which pane is where - no ratios, no views, no
//! references held - in one fixed buffer, so a mouse move allocates nothing.
//! Its nodes are never edited: a move appends the nodes it changes and gets
//! a new root, so the tree before and the tree after share one buffer.

const std = @import("std");
const testing = std.testing;
const pane_drop = @import("pane_drop.zig");
const pane_id = @import("pane_id.zig");

const RowDirection = pane_drop.RowDirection;
const Side = pane_drop.Side;

/// Room for a 128-pane tree (255 nodes) plus every node a move adds.
pub const max_nodes: usize = 384;

pub const Index = u16;

const Node = union(enum) {
    leaf: []const u8,
    split: struct { layout: RowDirection, left: Index, right: Index },
};

/// A move a drop target would make, in layout terms.
pub const Move = union(enum) {
    /// Beside the pane `pane`, on `side` of it.
    split: struct { pane: []const u8, side: Side },
    /// Down a whole side of the window.
    top_level: Side,
    /// In the gap of the divider between `before` and `after`.
    insert: struct {
        layout: RowDirection,
        before: []const []const u8,
        after: []const []const u8,
    },

    /// The move `target` makes, or null for a target that is never where the
    /// pane already is: a swap, a tab, a window, the sidebar.
    pub fn of(target: pane_drop.Target) ?Move {
        return switch (target) {
            .split => |s| .{ .split = .{ .pane = s.pane, .side = s.side } },
            .top_level => |s| .{ .top_level = s.side },
            .insert => |s| .{ .insert = .{ .layout = s.layout, .before = s.before, .after = s.after } },
            else => null,
        };
    }
};

pub const Shape = struct {
    nodes: [max_nodes]Node = undefined,
    len: usize = 0,
    /// Set when a node did not fit. A full shape answers "not in place", so
    /// an oversized tree keeps every target rather than losing real ones.
    full: bool = false,

    fn add(self: *Shape, n: Node) ?Index {
        if (self.len >= max_nodes) {
            self.full = true;
            return null;
        }
        self.nodes[self.len] = n;
        self.len += 1;
        return @intCast(self.len - 1);
    }

    /// `tree`'s visible layout: its leaves less the `hidden` ones (stashed
    /// panes, Mac's `visibleTree`), a split with one side left becoming that
    /// side. Null for a tree with nothing visible.
    pub fn fromTree(
        self: *Shape,
        comptime Tree: type,
        tree: *const Tree,
        comptime idOf: fn (*Tree.View) []const u8,
        comptime hidden: fn (*Tree.View) bool,
    ) ?Index {
        if (tree.nodes.len == 0) return null;
        return self.build(Tree, tree, idOf, hidden, .root);
    }

    fn build(
        self: *Shape,
        comptime Tree: type,
        tree: *const Tree,
        comptime idOf: fn (*Tree.View) []const u8,
        comptime hidden: fn (*Tree.View) bool,
        at: Tree.Node.Handle,
    ) ?Index {
        switch (tree.nodes[at.idx()]) {
            .leaf => |view| {
                if (hidden(view)) return null;
                return self.add(.{ .leaf = idOf(view) });
            },
            .split => |s| {
                const l = self.build(Tree, tree, idOf, hidden, s.left);
                const r = self.build(Tree, tree, idOf, hidden, s.right);
                if (l == null) return r;
                if (r == null) return l;
                return self.add(.{ .split = .{
                    .layout = switch (s.layout) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    .left = l.?,
                    .right = r.?,
                } });
            },
        }
    }

    pub fn contains(self: *const Shape, at: ?Index, id: []const u8) bool {
        const i = at orelse return false;
        return switch (self.nodes[i]) {
            .leaf => |l| pane_id.eql(l, id),
            .split => |s| self.contains(s.left, id) or self.contains(s.right, id),
        };
    }

    /// `at` with the pane `id` taken out; null when nothing is left.
    pub fn without(self: *Shape, at: Index, id: []const u8) ?Index {
        switch (self.nodes[at]) {
            .leaf => |l| return if (pane_id.eql(l, id)) null else at,
            .split => |s| {
                const l = self.without(s.left, id);
                const r = self.without(s.right, id);
                if (l == s.left and r == s.right) return at;
                if (l == null) return r;
                if (r == null) return l;
                return self.add(.{ .split = .{ .layout = s.layout, .left = l.?, .right = r.? } });
            },
        }
    }

    /// `node` beside `other`, on `side` of it.
    fn beside(self: *Shape, other: Index, side: Side, node: Index) ?Index {
        const layout: RowDirection = switch (side) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };
        const first = side == .left or side == .up;
        return self.add(.{ .split = .{
            .layout = layout,
            .left = if (first) node else other,
            .right = if (first) other else node,
        } });
    }

    /// `at` with the pane `target` split on `side` to hold `node`; null when
    /// `target` is not in it.
    fn splitting(self: *Shape, at: Index, target: []const u8, side: Side, node: Index) ?Index {
        switch (self.nodes[at]) {
            .leaf => |l| return if (pane_id.eql(l, target)) self.beside(at, side, node) else null,
            .split => |s| {
                if (self.splitting(s.left, target, side, node)) |l| {
                    return self.add(.{ .split = .{ .layout = s.layout, .left = l, .right = s.right } });
                }
                if (self.splitting(s.right, target, side, node)) |r| {
                    return self.add(.{ .split = .{ .layout = s.layout, .left = s.left, .right = r } });
                }
                return null;
            },
        }
    }

    /// `at` with `node` in the gap of the split on `layout` whose sides hold
    /// exactly `before` and `after` (less `exclude`, the pane being moved);
    /// null when there is no such split.
    fn gapping(
        self: *Shape,
        at: Index,
        layout: RowDirection,
        before: []const []const u8,
        after: []const []const u8,
        exclude: []const u8,
        node: Index,
    ) ?Index {
        switch (self.nodes[at]) {
            .leaf => return null,
            .split => |s| {
                if (s.layout == layout and
                    self.holdsExactly(s.left, before, exclude) and
                    self.holdsExactly(s.right, after, exclude))
                {
                    // `L | R` becomes `L | (node | R)`, the shape of
                    // `SplitTree.insertInGap`.
                    const inner = self.add(.{ .split = .{ .layout = layout, .left = node, .right = s.right } }) orelse return null;
                    return self.add(.{ .split = .{ .layout = layout, .left = s.left, .right = inner } });
                }
                if (self.gapping(s.left, layout, before, after, exclude, node)) |l| {
                    return self.add(.{ .split = .{ .layout = s.layout, .left = l, .right = s.right } });
                }
                if (self.gapping(s.right, layout, before, after, exclude, node)) |r| {
                    return self.add(.{ .split = .{ .layout = s.layout, .left = s.left, .right = r } });
                }
                return null;
            },
        }
    }

    fn countLeaves(self: *const Shape, at: Index) usize {
        return switch (self.nodes[at]) {
            .leaf => 1,
            .split => |s| self.countLeaves(s.left) + self.countLeaves(s.right),
        };
    }

    /// Whether the leaves under `at` are exactly `want` less `exclude`, and
    /// not none. Ids are unique within a tree, so counting suffices once
    /// every wanted id is found.
    fn holdsExactly(self: *const Shape, at: Index, want: []const []const u8, exclude: []const u8) bool {
        var wanted: usize = 0;
        for (want) |id| {
            if (pane_id.eql(id, exclude)) continue;
            if (!self.contains(at, id)) return false;
            wanted += 1;
        }
        return wanted > 0 and wanted == self.countLeaves(at);
    }

    /// Whether `a` and `b` put the same panes in the same places, whatever
    /// the sizes and however the tree nests them: A beside (B beside C) is
    /// laid out as (A beside B) beside C (Mac `hasSameLayout`).
    pub fn sameLayout(self: *const Shape, a: ?Index, b: ?Index) bool {
        var ta: Tokens = .{};
        var tb: Tokens = .{};
        if (a) |i| self.emit(i, null, &ta);
        if (b) |i| self.emit(i, null, &tb);
        if (ta.full or tb.full) return false;
        if (ta.len != tb.len) return false;
        for (ta.items[0..ta.len], tb.items[0..tb.len]) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }

    /// The layout as a token run, a split on the same axis as its parent read
    /// as part of the parent's row (Mac's `PaneArrangement`).
    fn emit(self: *const Shape, at: Index, parent: ?RowDirection, out: *Tokens) void {
        switch (self.nodes[at]) {
            .leaf => |l| out.push(.{ .pane = l }),
            .split => |s| {
                const opens = parent != s.layout;
                if (opens) out.push(.{ .open = s.layout });
                self.emit(s.left, s.layout, out);
                self.emit(s.right, s.layout, out);
                if (opens) out.push(.close);
            },
        }
    }

    /// Whether `move` would leave `dragged` where it is in the layout `root`.
    /// A pane not in it - stashed, or in another tab - is not on this grid,
    /// so every place is a new one to it. A move that cannot be made (its
    /// pane or divider is gone, or nothing would be left beside it) counts
    /// as in place, since a release there would do nothing.
    pub fn wouldLeaveInPlace(self: *Shape, root: ?Index, dragged: []const u8, move: Move) bool {
        const r = root orelse return false;
        if (self.full or !self.contains(r, dragged)) return false;
        const rest = self.without(r, dragged) orelse return true;
        const leaf = self.add(.{ .leaf = dragged }) orelse return false;
        const moved: ?Index = switch (move) {
            .split => |s| self.splitting(rest, s.pane, s.side, leaf),
            .top_level => |side| self.beside(rest, side, leaf),
            .insert => |s| self.gapping(rest, s.layout, s.before, s.after, dragged, leaf),
        };
        if (self.full) return false;
        const m = moved orelse return true;
        return self.sameLayout(m, r);
    }
};

const Token = union(enum) {
    open: RowDirection,
    close,
    pane: []const u8,

    fn eql(a: Token, b: Token) bool {
        return switch (a) {
            .open => |l| b == .open and b.open == l,
            .close => b == .close,
            .pane => |p| b == .pane and pane_id.eql(p, b.pane),
        };
    }
};

const Tokens = struct {
    items: [max_nodes * 2]Token = undefined,
    len: usize = 0,
    full: bool = false,

    fn push(self: *Tokens, t: Token) void {
        if (self.len >= self.items.len) {
            self.full = true;
            return;
        }
        self.items[self.len] = t;
        self.len += 1;
    }
};

// -- tests ----------------------------------------------------------------

const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

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

/// Whether dragging `dragged` per `move` in `tree` would leave it in place.
fn inPlace(tree: *const TestTree, dragged: []const u8, move: Move) bool {
    var shape: Shape = .{};
    const root = shape.fromTree(TestTree, tree, testId, testHidden);
    return shape.wouldLeaveInPlace(root, dragged, move);
}

/// `A | B`.
fn pair(alloc: std.mem.Allocator, a: *TestView, b: *TestView) !TestTree {
    var ta: TestTree = try .init(alloc, a);
    defer ta.deinit();
    var tb: TestTree = try .init(alloc, b);
    defer tb.deinit();
    return try ta.split(alloc, .root, .right, 0.5, &tb);
}

test "in A | B dragging A, B's left side, the divider and the left edge are in place" {
    var a: TestView = .{ .id = id_a };
    var b: TestView = .{ .id = id_b };
    var tree = try pair(testing.allocator, &a, &b);
    defer tree.deinit();

    try testing.expect(inPlace(&tree, id_a, .{ .split = .{ .pane = id_b, .side = .left } }));
    try testing.expect(inPlace(&tree, id_a, .{ .top_level = .left }));
    try testing.expect(inPlace(&tree, id_a, .{ .insert = .{ .layout = .horizontal, .before = &.{id_a}, .after = &.{id_b} } }));
}

test "in A | B dragging A, every other side is a real move" {
    var a: TestView = .{ .id = id_a };
    var b: TestView = .{ .id = id_b };
    var tree = try pair(testing.allocator, &a, &b);
    defer tree.deinit();

    try testing.expect(!inPlace(&tree, id_a, .{ .split = .{ .pane = id_b, .side = .right } }));
    try testing.expect(!inPlace(&tree, id_a, .{ .split = .{ .pane = id_b, .side = .up } }));
    try testing.expect(!inPlace(&tree, id_a, .{ .split = .{ .pane = id_b, .side = .down } }));
    try testing.expect(!inPlace(&tree, id_a, .{ .top_level = .right }));
    try testing.expect(!inPlace(&tree, id_a, .{ .top_level = .up }));
    try testing.expect(!inPlace(&tree, id_a, .{ .top_level = .down }));
}

test "a run of splits on one axis reads as one row" {
    // A | (B | C): dragging C to B's right side, or onto the right edge, is
    // where it already is; to B's left it is a real move.
    var a: TestView = .{ .id = id_a };
    var b: TestView = .{ .id = id_b };
    var c: TestView = .{ .id = id_c };
    const alloc = testing.allocator;
    var bc = try pair(alloc, &b, &c);
    defer bc.deinit();
    var ta: TestTree = try .init(alloc, &a);
    defer ta.deinit();
    var tree = try ta.split(alloc, .root, .right, 0.5, &bc);
    defer tree.deinit();

    try testing.expect(inPlace(&tree, id_c, .{ .split = .{ .pane = id_b, .side = .right } }));
    try testing.expect(inPlace(&tree, id_c, .{ .top_level = .right }));
    try testing.expect(!inPlace(&tree, id_c, .{ .split = .{ .pane = id_b, .side = .left } }));
    // (A | B) | C nests differently and is laid out the same.
    var shape: Shape = .{};
    const root = shape.fromTree(TestTree, &tree, testId, testHidden).?;
    var ab = try pair(alloc, &a, &b);
    defer ab.deinit();
    var tc: TestTree = try .init(alloc, &c);
    defer tc.deinit();
    var other = try ab.split(alloc, .root, .right, 0.5, &tc);
    defer other.deinit();
    const root2 = shape.fromTree(TestTree, &other, testId, testHidden).?;
    try testing.expect(shape.sameLayout(root, root2));
}

test "a divider drop is in place only when the pane already sits in that gap" {
    // A | (C | B), dragging C onto the outer divider: with C taken out that
    // divider is A | B, and C landing in its gap is back where it was.
    var a: TestView = .{ .id = id_a };
    var b: TestView = .{ .id = id_b };
    var c: TestView = .{ .id = id_c };
    const alloc = testing.allocator;
    var cb = try pair(alloc, &c, &b);
    defer cb.deinit();
    var ta: TestTree = try .init(alloc, &a);
    defer ta.deinit();
    var tree = try ta.split(alloc, .root, .right, 0.5, &cb);
    defer tree.deinit();
    try testing.expect(inPlace(&tree, id_c, .{ .insert = .{ .layout = .horizontal, .before = &.{id_a}, .after = &.{ id_c, id_b } } }));

    // A | B | C (the rearrange-divider-drop shape): C onto the A|B divider
    // is a real move.
    var ab = try pair(alloc, &a, &b);
    defer ab.deinit();
    var tc: TestTree = try .init(alloc, &c);
    defer tc.deinit();
    var abc = try ab.split(alloc, .root, .right, 0.5, &tc);
    defer abc.deinit();
    try testing.expect(!inPlace(&abc, id_c, .{ .insert = .{ .layout = .horizontal, .before = &.{id_a}, .after = &.{id_b} } }));
}

test "a pane that is not on the grid finds every place new" {
    var a: TestView = .{ .id = id_a, .stashed = true };
    var b: TestView = .{ .id = id_b };
    var tree = try pair(testing.allocator, &a, &b);
    defer tree.deinit();
    // A stashed: its old place is not "where it is".
    try testing.expect(!inPlace(&tree, id_a, .{ .split = .{ .pane = id_b, .side = .left } }));
    try testing.expect(!inPlace(&tree, id_a, .{ .top_level = .left }));
    // A pane from another tab is not in this tree at all.
    try testing.expect(!inPlace(&tree, id_d, .{ .split = .{ .pane = id_b, .side = .left } }));
}

test "the only pane on the grid has nowhere new to go here" {
    var a: TestView = .{ .id = id_a };
    var tree: TestTree = try .init(testing.allocator, &a);
    defer tree.deinit();
    try testing.expect(inPlace(&tree, id_a, .{ .top_level = .right }));
}

test "a stashed neighbour is not part of the layout" {
    // A | (B over C), C stashed: on screen it is A | B, so dragging A to B's
    // left is in place.
    var a: TestView = .{ .id = id_a };
    var b: TestView = .{ .id = id_b };
    var c: TestView = .{ .id = id_c, .stashed = true };
    const alloc = testing.allocator;
    var tb: TestTree = try .init(alloc, &b);
    defer tb.deinit();
    var tc: TestTree = try .init(alloc, &c);
    defer tc.deinit();
    var bc = try tb.split(alloc, .root, .down, 0.5, &tc);
    defer bc.deinit();
    var ta: TestTree = try .init(alloc, &a);
    defer ta.deinit();
    var tree = try ta.split(alloc, .root, .right, 0.5, &bc);
    defer tree.deinit();
    try testing.expect(inPlace(&tree, id_a, .{ .split = .{ .pane = id_b, .side = .left } }));
}

test "Move.of keeps only the targets that can be where the pane is" {
    try testing.expect(Move.of(.{ .swap = .{ .window = 1, .pane = id_b } }) == null);
    try testing.expect(Move.of(.{ .new_tab = .{ .window = 1, .index = 0 } }) == null);
    const m = Move.of(.{ .top_level = .{ .window = 1, .side = .left } }).?;
    try testing.expectEqual(Side.left, m.top_level);
}
