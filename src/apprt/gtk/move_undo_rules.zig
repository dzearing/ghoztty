//! What undoing (or redoing) a pane MOVE does to the trees it touched
//! (T3706, Linux L11b6). Pure - no GTK imports - so these unit tests run in
//! every app-runtime lane, the `pane_drop_apply.zig` pattern.
//!
//! Mac registers every pane move under one undo action, "Move Pane"
//! (`PaneMoveCoordinator.commit` / `crossWindowCommit`): Cmd+Z puts every
//! tree the move touched back as it was, as ONE step - the tab the pane left
//! and the tab it joined, in one window or two. The Linux app records each
//! such tree as a `layout_undo.Shape` (the tree by pane identity, so the
//! entry keeps no pane alive), and this rebuilds them TOGETHER: a pane that
//! moved is found in whichever tree it is in now and goes back to the one
//! its shape names, so the pane leaves the tree it moved to.
//!
//! Nothing is ever lost on the way back: a pane the user opened in one of
//! those trees since the move is in no shape, so it stays in the tree it is
//! in now, joining it at the top level on the right (`appendMissing`'s
//! rule); a pane closed since is pruned and its sibling takes its split.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const layout_undo = @import("../win32/layout_undo.zig");

/// The trees `shapes` describe, built from the panes of `current` (the same
/// trees as they are now, in the same order; null for a tree with no pane).
/// A pane is looked for in EVERY current tree, so a pane the move carried
/// across goes back. A pane of `current[i]` that no rebuilt tree places
/// joins tree `i` at the top level, on the right, in screen order. The
/// result has one tree per shape - empty when nothing is left for it - and
/// holds its own reference on every view. Caller frees with `freeAll`.
pub fn rebuildAcross(
    comptime V: type,
    comptime Id: type,
    alloc: Allocator,
    shapes: []const layout_undo.Shape(V, Id),
    current: []const ?*const SplitTree(V),
    comptime idOf: fn (*const V) Id,
) Allocator.Error![]SplitTree(V) {
    std.debug.assert(shapes.len == current.len);
    const VTree = SplitTree(V);
    const Ctx = struct {
        current: []const ?*const VTree,

        fn find(self: @This(), id: Id) ?*V {
            for (self.current) |maybe| {
                const t = maybe orelse continue;
                var it = t.iterator();
                while (it.next()) |entry| {
                    if (std.meta.eql(idOf(entry.view), id)) return entry.view;
                }
            }
            return null;
        }
    };
    const ctx: Ctx = .{ .current = current };

    const out = try alloc.alloc(VTree, shapes.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*t| t.deinit();
        alloc.free(out);
    }
    for (shapes, out) |*shape, *dst| {
        dst.* = (try shape.rebuild(alloc, ctx, Ctx.find)) orelse .empty;
        built += 1;
    }

    // Strays: a pane in a tree now that no shape put anywhere.
    for (current, 0..) |maybe, i| {
        const t = maybe orelse continue;
        var it = t.leafIterator();
        while (it.next()) |entry| {
            if (placed(V, out, entry.view)) continue;
            var leaf = try VTree.init(alloc, entry.view);
            defer leaf.deinit();
            const bigger = try out[i].insertAtTopLevel(alloc, .right, 0.5, &leaf);
            out[i].deinit();
            out[i] = bigger;
        }
    }
    return out;
}

/// Free what `rebuildAcross` returned.
pub fn freeAll(comptime V: type, alloc: Allocator, trees: []SplitTree(V)) void {
    for (trees) |*t| t.deinit();
    alloc.free(trees);
}

fn placed(comptime V: type, trees: []const SplitTree(V), v: *const V) bool {
    for (trees) |*t| {
        var it = t.iterator();
        while (it.next()) |entry| if (entry.view == v) return true;
    }
    return false;
}

/// The owner a move's undo entry gets: the one window every tree it touched
/// is in, else `shared` - a move between two windows is undone from either
/// (Mac groups it on the source's undo manager; the Linux undo stack keys an
/// entry by window, and a shared key is what any window's undo reaches).
pub fn ownerFor(windows: []const usize, shared: usize) usize {
    if (windows.len == 0) return shared;
    for (windows[1..]) |w| if (w != windows[0]) return shared;
    return windows[0];
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const View = struct {
    label: []const u8,
    refs: usize = 0,

    pub fn ref(self: *View, alloc: Allocator) Allocator.Error!*View {
        _ = alloc;
        self.refs += 1;
        return self;
    }
    pub fn unref(self: *View, alloc: Allocator) void {
        _ = alloc;
        self.refs -= 1;
    }
};
const Tree = SplitTree(View);
const Shape = layout_undo.Shape(View, u8);

fn labelId(v: *const View) u8 {
    return v.label[0];
}

/// The labels of `tree`'s panes in screen order, as one string.
fn order(buf: []u8, tree: *const Tree) []const u8 {
    var n: usize = 0;
    var it = tree.leafIterator();
    while (it.next()) |entry| {
        buf[n] = entry.view.label[0];
        n += 1;
    }
    return buf[0..n];
}

fn pair(alloc: Allocator, a: *View, b: *View, dir: Tree.Split.Direction) !Tree {
    var l = try Tree.init(alloc, a);
    defer l.deinit();
    var r = try Tree.init(alloc, b);
    defer r.deinit();
    return try l.split(alloc, .root, dir, 0.5, &r);
}

test "move_undo: a pane carried to another tree goes back, and leaves the tree it joined" {
    const alloc = testing.allocator;
    var a: View = .{ .label = "a" };
    var b: View = .{ .label = "b" };
    var c: View = .{ .label = "c" };

    // Before: source = a|b, dest = c.
    var src_before = try pair(alloc, &a, &b, .right);
    defer src_before.deinit();
    var dst_before = try Tree.init(alloc, &c);
    defer dst_before.deinit();
    var shapes = [_]Shape{
        try Shape.capture(alloc, &src_before, labelId),
        try Shape.capture(alloc, &dst_before, labelId),
    };
    defer for (&shapes) |*s| s.deinit(alloc);

    // After the move: source = a, dest = c|b.
    var src_now = try Tree.init(alloc, &a);
    defer src_now.deinit();
    var dst_now = try pair(alloc, &c, &b, .right);
    defer dst_now.deinit();

    const out = try rebuildAcross(View, u8, alloc, &shapes, &.{ &src_now, &dst_now }, labelId);
    defer freeAll(View, alloc, out);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("ab", order(&buf, &out[0]));
    try testing.expectEqualStrings("c", order(&buf, &out[1]));
}

test "move_undo: a tree the move emptied is built again, and one it created empties" {
    const alloc = testing.allocator;
    var a: View = .{ .label = "a" };

    // Before: source = a, the new tab did not exist (an empty shape).
    var src_before = try Tree.init(alloc, &a);
    defer src_before.deinit();
    const empty: Tree = .empty;
    var shapes = [_]Shape{
        try Shape.capture(alloc, &src_before, labelId),
        try Shape.capture(alloc, &empty, labelId),
    };
    defer for (&shapes) |*s| s.deinit(alloc);

    // After: the source is empty (null), the new tab holds a.
    var dst_now = try Tree.init(alloc, &a);
    defer dst_now.deinit();
    const out = try rebuildAcross(View, u8, alloc, &shapes, &.{ null, &dst_now }, labelId);
    defer freeAll(View, alloc, out);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("a", order(&buf, &out[0]));
    try testing.expect(out[1].isEmpty());
}

test "move_undo: a pane opened since the move stays where it is, on the right" {
    const alloc = testing.allocator;
    var a: View = .{ .label = "a" };
    var b: View = .{ .label = "b" };
    var c: View = .{ .label = "c" };
    var n: View = .{ .label = "n" };

    var src_before = try pair(alloc, &a, &b, .down);
    defer src_before.deinit();
    var dst_before = try Tree.init(alloc, &c);
    defer dst_before.deinit();
    var shapes = [_]Shape{
        try Shape.capture(alloc, &src_before, labelId),
        try Shape.capture(alloc, &dst_before, labelId),
    };
    defer for (&shapes) |*s| s.deinit(alloc);

    // After the move b went to dest, and the user split n off c there.
    var src_now = try Tree.init(alloc, &a);
    defer src_now.deinit();
    var cb = try pair(alloc, &c, &b, .right);
    defer cb.deinit();
    var nl = try Tree.init(alloc, &n);
    defer nl.deinit();
    var dst_now = try cb.insertAtTopLevel(alloc, .right, 0.5, &nl);
    defer dst_now.deinit();

    const out = try rebuildAcross(View, u8, alloc, &shapes, &.{ &src_now, &dst_now }, labelId);
    defer freeAll(View, alloc, out);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("ab", order(&buf, &out[0]));
    try testing.expectEqualStrings("cn", order(&buf, &out[1]));
}

test "move_undo: a pane closed since is pruned, and nothing is placed twice" {
    const alloc = testing.allocator;
    var a: View = .{ .label = "a" };
    var b: View = .{ .label = "b" };
    var c: View = .{ .label = "c" };

    // A swap: before src = a|b, dest = c; after src = a|c, dest = b.
    var src_before = try pair(alloc, &a, &b, .right);
    defer src_before.deinit();
    var dst_before = try Tree.init(alloc, &c);
    defer dst_before.deinit();
    var shapes = [_]Shape{
        try Shape.capture(alloc, &src_before, labelId),
        try Shape.capture(alloc, &dst_before, labelId),
    };
    defer for (&shapes) |*s| s.deinit(alloc);

    // Then a was closed.
    var src_now = try Tree.init(alloc, &c);
    defer src_now.deinit();
    var dst_now = try Tree.init(alloc, &b);
    defer dst_now.deinit();

    const out = try rebuildAcross(View, u8, alloc, &shapes, &.{ &src_now, &dst_now }, labelId);
    defer freeAll(View, alloc, out);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("b", order(&buf, &out[0]));
    try testing.expectEqualStrings("c", order(&buf, &out[1]));
    // One reference per tree it is in: `dst_now`, `src_before` and the result.
    try testing.expectEqual(@as(usize, 3), b.refs);
}

test "move_undo: references are balanced" {
    const alloc = testing.allocator;
    var a: View = .{ .label = "a" };
    var b: View = .{ .label = "b" };
    {
        var before = try pair(alloc, &a, &b, .right);
        defer before.deinit();
        var shapes = [_]Shape{try Shape.capture(alloc, &before, labelId)};
        defer for (&shapes) |*s| s.deinit(alloc);
        const out = try rebuildAcross(View, u8, alloc, &shapes, &.{&before}, labelId);
        try testing.expectEqual(@as(usize, 2), a.refs);
        freeAll(View, alloc, out);
        try testing.expectEqual(@as(usize, 1), a.refs);
    }
    try testing.expectEqual(@as(usize, 0), a.refs);
    try testing.expectEqual(@as(usize, 0), b.refs);
}

test "move_undo: one window owns its move, two share it" {
    try testing.expectEqual(@as(usize, 7), ownerFor(&.{ 7, 7 }, 0));
    try testing.expectEqual(@as(usize, 0), ownerFor(&.{ 7, 9 }, 0));
    try testing.expectEqual(@as(usize, 7), ownerFor(&.{7}, 0));
    try testing.expectEqual(@as(usize, 0), ownerFor(&.{}, 0));
}
