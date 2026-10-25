//! Undo for `+rearrange` (T2234): the parts that need no window.
//!
//! Mac's `+rearrange` goes through `replaceSurfaceTree(undoAction: "Rearrange
//! Layout")`, so Cmd+Z puts the previous tree back and Cmd+Shift+Z puts the
//! rearranged one back again. The Windows half parks the previous layout on
//! the close-undo stack (`LayoutUndo.zig`), recorded here as a `Shape`: the
//! tree's nodes with every pane replaced by its IDENTITY.
//!
//! By identity rather than by reference, because the undo entry must not keep
//! a pane alive that the user closed after the rearrange - a pane whose last
//! reference outlives its close stays on screen until that reference goes.
//! The only panes the entry holds are the ones the rearrange left out, and
//! those it must hold: they are what the undo brings back.
//!
//! The user may have split, closed or lost a pane between the rearrange and
//! the undo, so `rebuild` puts back what is still there: a pane that no longer
//! answers to its identity is pruned and its sibling takes the whole split,
//! and `appendMissing` adds every pane the tab gained since at the top level,
//! on the right - the way a carried stashed pane joins a rearranged layout. A
//! redo is the same `Shape`, captured from the rearranged tree as the undo
//! replaces it.
//!
//! Pure over any `SplitTree(V)` whose `V` has a `stash_seq: u64` field (see
//! `pane_stash.zig`), so it is unit-tested in every lane.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

fn inTree(comptime V: type, tree: *const SplitTree(V), v: *const V) bool {
    var it = tree.iterator();
    while (it.next()) |entry| if (entry.view == v) return true;
    return false;
}

/// Add every pane of `current` that `tree` lacks to `tree`, at the top level
/// on the right, in screen order. `tree` may be empty.
pub fn appendMissing(
    comptime V: type,
    gpa: Allocator,
    tree: *SplitTree(V),
    current: *const SplitTree(V),
) Allocator.Error!void {
    const Tree = SplitTree(V);
    var it = current.leafIterator();
    while (it.next()) |entry| {
        if (inTree(V, tree, entry.view)) continue;
        var leaf = try Tree.init(gpa, entry.view);
        defer leaf.deinit();
        const bigger = try tree.insertAtTopLevel(gpa, .right, 0.5, &leaf);
        tree.deinit();
        tree.* = bigger;
    }
}

/// A layout by pane identity: the tree's nodes with every leaf's view
/// replaced by its `Id` and its stash mark.
pub fn Shape(comptime V: type, comptime Id: type) type {
    return struct {
        const Self = @This();
        const Tree = SplitTree(V);
        const Handle = Tree.Node.Handle;

        pub const Leaf = struct { id: Id, stash_seq: u64 };
        pub const Node = union(enum) {
            leaf: Leaf,
            split: Tree.Split,
        };

        nodes: []Node,
        /// The zoomed pane, when a single pane filled the tab.
        zoomed: ?Id,

        pub fn capture(
            alloc: Allocator,
            tree: *const Tree,
            comptime idOf: fn (*const V) Id,
        ) Allocator.Error!Self {
            const nodes = try alloc.alloc(Node, tree.nodes.len);
            for (tree.nodes, nodes) |src, *dst| dst.* = switch (src) {
                .leaf => |v| .{ .leaf = .{ .id = idOf(v), .stash_seq = v.stash_seq } },
                .split => |s| .{ .split = s },
            };
            const zoomed: ?Id = if (tree.zoomed) |z| switch (tree.nodes[z.idx()]) {
                .leaf => |v| idOf(v),
                .split => null,
            } else null;
            return .{ .nodes = nodes, .zoomed = zoomed };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.nodes);
            self.* = undefined;
        }

        /// The tree this shape describes, with `lookup` naming each leaf's
        /// view. A leaf whose identity names no view - or a view an earlier
        /// leaf already took - is pruned, and its sibling fills the split.
        /// Directions and ratios of every surviving split are kept, and so is
        /// a zoom on a pane that survived. Null when no leaf survives. The
        /// result holds its own reference on every view.
        pub fn rebuild(
            self: *const Self,
            gpa: Allocator,
            ctx: anytype,
            comptime lookup: fn (@TypeOf(ctx), Id) ?*V,
        ) Allocator.Error!?Tree {
            if (self.nodes.len == 0) return null;
            var used: std.ArrayListUnmanaged(*V) = .empty;
            defer used.deinit(gpa);
            var tree = (try self.build(gpa, .root, &used, ctx, lookup)) orelse return null;
            if (self.zoomed) |id| if (lookup(ctx, id)) |v| {
                var it = tree.iterator();
                while (it.next()) |entry| {
                    if (entry.view == v) tree.zoomed = entry.handle;
                }
            };
            return tree;
        }

        fn build(
            self: *const Self,
            gpa: Allocator,
            at: Handle,
            used: *std.ArrayListUnmanaged(*V),
            ctx: anytype,
            comptime lookup: fn (@TypeOf(ctx), Id) ?*V,
        ) Allocator.Error!?Tree {
            switch (self.nodes[at.idx()]) {
                .leaf => |leaf| {
                    const v = lookup(ctx, leaf.id) orelse return null;
                    for (used.items) |u| if (u == v) return null;
                    try used.append(gpa, v);
                    return try Tree.init(gpa, v);
                },
                .split => |s| {
                    var left = try self.build(gpa, s.left, used, ctx, lookup);
                    errdefer if (left) |*l| l.deinit();
                    var right = try self.build(gpa, s.right, used, ctx, lookup);
                    errdefer if (right) |*r| r.deinit();
                    if (left == null) return right;
                    if (right == null) return left;
                    defer left.?.deinit();
                    defer right.?.deinit();
                    const direction: Tree.Split.Direction = switch (s.layout) {
                        .horizontal => .right,
                        .vertical => .down,
                    };
                    return try left.?.split(gpa, .root, direction, s.ratio, &right.?);
                },
            }
        }

        /// Put back every captured stash mark on the views `lookup` still
        /// finds, so what was stashed is stashed again and what was on screen
        /// is on screen. Views it no longer finds keep their own.
        pub fn restoreStash(
            self: *const Self,
            ctx: anytype,
            comptime lookup: fn (@TypeOf(ctx), Id) ?*V,
        ) void {
            for (self.nodes) |node| switch (node) {
                .leaf => |leaf| if (lookup(ctx, leaf.id)) |v| {
                    v.stash_seq = leaf.stash_seq;
                },
                .split => {},
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const TestView = struct {
    label: []const u8,
    refs: usize = 0,
    stash_seq: u64 = 0,

    pub fn ref(self: *TestView, alloc: Allocator) Allocator.Error!*TestView {
        _ = alloc;
        self.refs += 1;
        return self;
    }
    pub fn unref(self: *TestView, alloc: Allocator) void {
        _ = alloc;
        self.refs -= 1;
    }
    pub fn splitTreeLabel(self: *const TestView) []const u8 {
        return self.label;
    }
};
const TTree = SplitTree(TestView);
const TShape = Shape(TestView, u8);

fn labelOf(v: *const TestView) u8 {
    return v.label[0];
}

fn findIn(set: []const *TestView, id: u8) ?*TestView {
    for (set) |v| if (v.label[0] == id) return v;
    return null;
}

/// The node listing of a tree (the formatter draws a picture before it).
fn listing(alloc: Allocator, tree: *const TTree) ![]u8 {
    const all = try std.fmt.allocPrint(alloc, "{f}", .{tree.*});
    defer alloc.free(all);
    const at = std.mem.indexOf(u8, all, "split (") orelse std.mem.indexOf(u8, all, "leaf: ").?;
    return alloc.dupe(u8, all[at..]);
}

/// A | (B / C) with a 0.3 root ratio.
fn threePane(alloc: Allocator, a: *TestView, b: *TestView, c: *TestView) !TTree {
    var ta = try TTree.init(alloc, a);
    defer ta.deinit();
    var tb = try TTree.init(alloc, b);
    defer tb.deinit();
    var tc = try TTree.init(alloc, c);
    defer tc.deinit();
    var bc = try tb.split(alloc, .root, .down, 0.25, &tc);
    defer bc.deinit();
    return try ta.split(alloc, .root, .right, 0.3, &bc);
}

test "layout_undo: a shape rebuilds the same tree, ratios and directions included" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    const all = [_]*TestView{ &a, &b, &c };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();
    var shape = try TShape.capture(alloc, &tree, labelOf);
    defer shape.deinit(alloc);

    var again = (try shape.rebuild(alloc, @as([]const *TestView, &all), findIn)).?;
    defer again.deinit();
    const want = try listing(alloc, &tree);
    defer alloc.free(want);
    const got = try listing(alloc, &again);
    defer alloc.free(got);
    try testing.expectEqualStrings(want, got);
    try testing.expectEqual(@as(usize, 2), a.refs);
}

test "layout_undo: a pane gone since is pruned and its sibling fills the split" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    var shape = try TShape.capture(alloc, &tree, labelOf);
    defer shape.deinit(alloc);
    tree.deinit();

    const left = [_]*TestView{ &a, &c };
    var again = (try shape.rebuild(alloc, @as([]const *TestView, &left), findIn)).?;
    const got = try listing(alloc, &again);
    defer alloc.free(got);
    try testing.expectEqualStrings(
        \\split (layout: horizontal, ratio: 0.30)
        \\  leaf: A
        \\  leaf: C
        \\
    , got);
    try testing.expectEqual(@as(usize, 0), b.refs);
    again.deinit();
    try testing.expectEqual(@as(usize, 0), a.refs);
    try testing.expectEqual(@as(usize, 0), c.refs);

    const none = [_]*TestView{};
    try testing.expectEqual(@as(?TTree, null), try shape.rebuild(alloc, @as([]const *TestView, &none), findIn));
}

test "layout_undo: one view named twice is placed once" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var ta = try TTree.init(alloc, &a);
    var tb = try TTree.init(alloc, &b);
    var tree = try ta.split(alloc, .root, .right, 0.5, &tb);
    ta.deinit();
    tb.deinit();
    var shape = try TShape.capture(alloc, &tree, labelOf);
    defer shape.deinit(alloc);
    tree.deinit();

    const always_a = struct {
        fn f(v: *TestView, _: u8) ?*TestView {
            return v;
        }
    }.f;
    var again = (try shape.rebuild(alloc, &a, always_a)).?;
    defer again.deinit();
    try testing.expectEqual(@as(usize, 1), again.nodes.len);
}

test "layout_undo: panes added since join on the right, in screen order" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var d: TestView = .{ .label = "D" };
    var tree = try TTree.init(alloc, &a);
    defer tree.deinit();
    // Now: C over (B | D); the restored tree already has A and B.
    var current = blk: {
        var tb = try TTree.init(alloc, &b);
        defer tb.deinit();
        var td = try TTree.init(alloc, &d);
        defer td.deinit();
        var bd = try tb.split(alloc, .root, .right, 0.5, &td);
        defer bd.deinit();
        var tc = try TTree.init(alloc, &c);
        defer tc.deinit();
        break :blk try tc.split(alloc, .root, .down, 0.5, &bd);
    };
    defer current.deinit();
    var tb = try TTree.init(alloc, &b);
    defer tb.deinit();
    var restored = try tree.insertAtTopLevel(alloc, .right, 0.5, &tb);
    defer restored.deinit();

    try appendMissing(TestView, alloc, &restored, &current);
    const got = try listing(alloc, &restored);
    defer alloc.free(got);
    try testing.expectEqualStrings(
        \\split (layout: horizontal, ratio: 0.50)
        \\  split (layout: horizontal, ratio: 0.50)
        \\    split (layout: horizontal, ratio: 0.50)
        \\      leaf: A
        \\      leaf: B
        \\    leaf: C
        \\  leaf: D
        \\
    , got);

    // Into an empty tree: the current panes alone.
    var empty: TTree = .empty;
    defer empty.deinit();
    try appendMissing(TestView, alloc, &empty, &tree);
    try testing.expectEqual(&a, empty.nodes[0].leaf);
}

test "layout_undo: a zoom comes back on the pane that had it" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (entry.view == &c) tree.zoomed = entry.handle;
    }
    var shape = try TShape.capture(alloc, &tree, labelOf);
    defer shape.deinit(alloc);

    const all = [_]*TestView{ &a, &b, &c };
    var again = (try shape.rebuild(alloc, @as([]const *TestView, &all), findIn)).?;
    defer again.deinit();
    try testing.expectEqual(&c, again.nodes[again.zoomed.?.idx()].leaf);

    // The zoomed pane is gone: the rest comes back unzoomed.
    const ab = [_]*TestView{ &a, &b };
    var rest = (try shape.rebuild(alloc, @as([]const *TestView, &ab), findIn)).?;
    defer rest.deinit();
    try testing.expectEqual(@as(?TTree.Node.Handle, null), rest.zoomed);
}

test "layout_undo: stash marks come back with the shape" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B", .stash_seq = 7 };
    var c: TestView = .{ .label = "C" };
    const all = [_]*TestView{ &a, &b, &c };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();
    var shape = try TShape.capture(alloc, &tree, labelOf);
    defer shape.deinit(alloc);

    // The rearrange brought B out and stashed C.
    b.stash_seq = 0;
    c.stash_seq = 9;
    shape.restoreStash(@as([]const *TestView, &all), findIn);
    try testing.expectEqual(@as(u64, 0), a.stash_seq);
    try testing.expectEqual(@as(u64, 7), b.stash_seq);
    try testing.expectEqual(@as(u64, 0), c.stash_seq);
}
