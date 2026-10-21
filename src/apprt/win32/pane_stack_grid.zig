//! The win32 window's side of the stacked-panes layout (T2107, the first slice
//! of T2101): turns a tab's `SplitTree(PaneView)` into the flat node array
//! `pane_stack_layout.compute` reads, and its DIP answer back into the pixel
//! rects the window places, paints and hit-tests.
//!
//! Two jobs, both pure so the tests need no window:
//!
//! - **Nodes, index for index.** `nodes[i]` describes `tree.nodes[i]`, so a
//!   `Divider.node` or `Result.displayed_ratio[i]` names a split of the real
//!   tree - the one a divider drag writes its ratio into. The stash is applied
//!   the way `Window.splitRects` applies it (T1827): a split with a side that
//!   holds no visible pane COLLAPSES into its visible side, by pointing its
//!   parent straight at that side's node. The collapsed split keeps its
//!   direction and ratio in the real tree for the pane that comes back, and the
//!   engine never sees a slot for a pane that is not on screen.
//! - **DIPs to pixels.** The engine lays the grid out from (0, 0) in DIPs; a
//!   rect comes back as the grid's pixel origin plus each EDGE scaled and
//!   rounded, never a rounded size added to a rounded origin, so two panes that
//!   share an edge in DIPs share it in pixels and the grid still ends exactly
//!   on its own right and bottom edge.
//!
//! The pane's id is `@intFromPtr(view)` unless the caller says otherwise:
//! stable for the view's lifetime, which is the lifetime of everything
//! `PaneStackState` remembers about it.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const layout = @import("pane_stack_layout.zig");
const pane_stash = @import("pane_stash.zig");

pub const Id = layout.Id;
pub const Node = layout.Node;

/// A pixel rectangle, edges inclusive-exclusive like a win32 `RECT` (same
/// field names, so the window converts with a struct literal).
pub const PxRect = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(r: PxRect) i32 {
        return r.right - r.left;
    }
    pub fn height(r: PxRect) i32 {
        return r.bottom - r.top;
    }
    pub fn contains(r: PxRect, x: i32, y: i32) bool {
        return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
    }
};

/// The engine's input for one tree.
pub const Built = struct {
    /// One entry per `tree.nodes` entry. Entries the visible tree does not
    /// reach (a wholly stashed subtree, a collapsed split) are placeholders.
    nodes: []Node,
    /// The node the visible tree starts at, or null when every pane is stashed.
    root: ?u32,

    pub fn deinit(self: *Built, gpa: Allocator) void {
        gpa.free(self.nodes);
        self.* = undefined;
    }
};

/// The default pane id: the view's address.
pub fn viewId(view: anytype) Id {
    return @intFromPtr(view);
}

/// Build the engine's nodes from `tree` (a `SplitTree(View)` or anything with
/// its `nodes` shape). `idOf(view) Id` names each leaf.
pub fn build(gpa: Allocator, tree: anytype, comptime idOf: anytype) Allocator.Error!Built {
    return buildWith(gpa, tree, idOf, .visible);
}

/// Which panes get a slot: the ones on screen, or every leaf as if nothing
/// were stashed - the slot a stashed pane is kept sized to (T1827), which
/// `Window.splitRectsFull` computes today.
pub const Panes = enum { visible, all };

pub fn buildWith(gpa: Allocator, tree: anytype, comptime idOf: anytype, comptime panes: Panes) Allocator.Error!Built {
    const nodes = try gpa.alloc(Node, tree.nodes.len);
    errdefer gpa.free(nodes);
    @memset(nodes, .{ .leaf = 0 });
    const root: ?u32 = if (tree.nodes.len == 0) null else resolve(tree, 0, nodes, idOf, panes);
    return .{ .nodes = nodes, .root = root };
}

/// Fill `nodes` for the subtree at `i` and return the node that stands for it
/// in the laid-out tree (itself, its visible side, or null).
fn resolve(tree: anytype, i: usize, nodes: []Node, comptime idOf: anytype, comptime panes: Panes) ?u32 {
    if (i >= tree.nodes.len) return null;
    switch (tree.nodes[i]) {
        .leaf => |view| {
            if (panes == .visible and pane_stash.isStashed(view)) return null;
            nodes[i] = .{ .leaf = idOf(view) };
            return @intCast(i);
        },
        .split => |s| {
            const lo = resolve(tree, s.left.idx(), nodes, idOf, panes);
            const hi = resolve(tree, s.right.idx(), nodes, idOf, panes);
            if (lo == null) return hi;
            if (hi == null) return lo;
            nodes[i] = .{ .split = .{
                .direction = if (s.layout == .horizontal) .horizontal else .vertical,
                .ratio = @floatCast(s.ratio),
                .left = lo.?,
                .right = hi.?,
            } };
            return @intCast(i);
        },
    }
}

/// The engine's metrics for a style: the elevated style's gap in DIPs, or null
/// for the flat style's gutter (`Metrics.flat_gap`).
pub fn metrics(gap_dip: ?f64) layout.Metrics {
    return layout.Metrics.forStyle(gap_dip);
}

/// One pane's place, in pixels.
pub const Placement = struct {
    /// The full card. A tucked card keeps its full size; most of it lies under
    /// the cards in front of it.
    rect: PxRect,
    is_tucked: bool,
    /// Drawn as its strip alone.
    is_sliver: bool,
    /// The strip that shows of a tucked card: where a click brings it forward.
    tab: ?PxRect,
    tab_axis: ?layout.Direction,
    /// Where the card may draw when it hangs off its stack's far end.
    clip: ?PxRect,
};

/// A tree laid out in a pixel rect: the engine's result plus what turns its
/// DIPs into pixels. `deinit` frees it.
pub const Grid = struct {
    result: layout.Result,
    origin_x: i32,
    origin_y: i32,
    scale: f64,

    pub fn deinit(self: *Grid) void {
        self.result.deinit();
        self.* = undefined;
    }

    /// A DIP rect (grid-local) in window pixels.
    pub fn px(self: *const Grid, r: layout.Rect) PxRect {
        return .{
            .left = self.edge(self.origin_x, r.x),
            .top = self.edge(self.origin_y, r.y),
            .right = self.edge(self.origin_x, r.x + r.w),
            .bottom = self.edge(self.origin_y, r.y + r.h),
        };
    }

    fn edge(self: *const Grid, origin: i32, dip: f64) i32 {
        // `unbounded` clip edges stay far away rather than overflowing.
        const v = std.math.clamp(@round(dip * self.scale), -1e9, 1e9);
        return origin + @as(i32, @intFromFloat(v));
    }

    pub fn placement(self: *const Grid, id: Id) ?Placement {
        const l = self.result.leaf(id) orelse return null;
        return .{
            .rect = self.px(l.frame),
            .is_tucked = l.is_tucked,
            .is_sliver = l.is_sliver,
            .tab = if (l.tab) |t| self.px(t) else null,
            .tab_axis = l.tab_axis,
            .clip = if (l.clip) |c| self.px(c) else null,
        };
    }

    /// The gutter of divider `i`, where it takes the mouse.
    pub fn dividerGutter(self: *const Grid, i: usize) PxRect {
        return self.px(self.result.dividers.items[i].gutter);
    }

    /// The divider whose gutter holds the point, if any.
    pub fn dividerAt(self: *const Grid, x: i32, y: i32) ?usize {
        for (0..self.result.dividers.items.len) |i| {
            if (self.dividerGutter(i).contains(x, y)) return i;
        }
        return null;
    }

    /// The tucked pane whose strip holds the point, if any: the highest in
    /// paint order wins where strips overlap, which is the one drawn on top.
    pub fn stripAt(self: *const Grid, x: i32, y: i32) ?Id {
        var best: ?Id = null;
        var best_elev: []const i64 = &.{};
        var it = self.result.leaves.iterator();
        while (it.next()) |e| {
            const t = e.value_ptr.tab orelse continue;
            if (!self.px(t).contains(x, y)) continue;
            const elev = e.value_ptr.elevation;
            if (best == null or std.mem.order(i64, elev, best_elev) == .gt) {
                best = e.key_ptr.*;
                best_elev = elev;
            }
        }
        return best;
    }
};

/// Lay `tree` out in the pixel rect `rect` at `scale` (pixels per DIP).
pub fn compute(
    gpa: Allocator,
    tree: anytype,
    comptime idOf: anytype,
    rect: PxRect,
    scale: f32,
    m: layout.Metrics,
    provider: layout.Provider,
) Allocator.Error!Grid {
    var built = try build(gpa, tree, idOf);
    defer built.deinit(gpa);
    return computeBuilt(gpa, built, rect, scale, m, provider);
}

/// `compute` over nodes the caller already built.
pub fn computeBuilt(
    gpa: Allocator,
    built: Built,
    rect: PxRect,
    scale: f32,
    m: layout.Metrics,
    provider: layout.Provider,
) Allocator.Error!Grid {
    const s: f64 = if (scale > 0) scale else 1;
    const dip: layout.Rect = .{
        .w = @as(f64, @floatFromInt(@max(rect.width(), 0))) / s,
        .h = @as(f64, @floatFromInt(@max(rect.height(), 0))) / s,
    };
    // A wholly stashed tree lays nothing out; `compute` treats an
    // out-of-range root as empty.
    const root: u32 = built.root orelse @intCast(built.nodes.len);
    return .{
        .result = try layout.compute(gpa, built.nodes, root, dip, m, provider),
        .origin_x = rect.left,
        .origin_y = rect.top,
        .scale = s,
    };
}

// ---------------------------------------------------------------------------
// Tests: a fake tree with SplitTree's shape (nodes, `.leaf` views carrying
// `stash_seq`, `.split` with `layout`, an f16 `ratio` and handles with `idx()`).

const FakeView = struct { id: Id, stash_seq: u64 = 0 };

const FakeHandle = enum(u16) {
    _,
    fn idx(self: FakeHandle) usize {
        return @intFromEnum(self);
    }
};

const FakeNode = union(enum) {
    leaf: *FakeView,
    split: struct {
        layout: enum { horizontal, vertical },
        ratio: f16,
        left: FakeHandle,
        right: FakeHandle,
    },
};

const FakeTree = struct { nodes: []const FakeNode };

fn h(i: u16) FakeHandle {
    return @enumFromInt(i);
}

fn fakeId(view: *FakeView) Id {
    return view.id;
}

/// `a | (b | (c | d))`, the shape a row of four built by successive splits has.
fn rowOfFour(v: *[4]FakeView) [7]FakeNode {
    return .{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.25, .left = h(1), .right = h(2) } },
        .{ .leaf = &v[0] },
        .{ .split = .{ .layout = .horizontal, .ratio = 1.0 / 3.0, .left = h(3), .right = h(4) } },
        .{ .leaf = &v[1] },
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = h(5), .right = h(6) } },
        .{ .leaf = &v[2] },
        .{ .leaf = &v[3] },
    };
}

test "pane_stack_grid: nodes map index for index" {
    var v = [_]FakeView{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 }, .{ .id = 4 } };
    const n = rowOfFour(&v);
    var b = try build(testing.allocator, FakeTree{ .nodes = &n }, fakeId);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 0), b.root);
    try testing.expectEqual(@as(usize, 7), b.nodes.len);
    try testing.expectEqual(@as(Id, 3), b.nodes[5].leaf);
    const s = b.nodes[2].split;
    try testing.expectEqual(layout.Direction.horizontal, s.direction);
    try testing.expectEqual(@as(u32, 3), s.left);
    try testing.expectEqual(@as(u32, 4), s.right);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), s.ratio, 1e-3);
}

test "pane_stack_grid: a split with a stashed side collapses into its visible side" {
    var v = [_]FakeView{ .{ .id = 1 }, .{ .id = 2, .stash_seq = 7 }, .{ .id = 3 }, .{ .id = 4 } };
    const n = rowOfFour(&v);
    var b = try build(testing.allocator, FakeTree{ .nodes = &n }, fakeId);
    defer b.deinit(testing.allocator);
    // Split 2 held the stashed pane 2 and split 4: its parent points at 4.
    try testing.expectEqual(@as(u32, 4), b.nodes[0].split.right);
    try testing.expectEqual(@as(u32, 1), b.nodes[0].split.left);
}

test "pane_stack_grid: the full build keeps a stashed pane's slot" {
    var v = [_]FakeView{ .{ .id = 1 }, .{ .id = 2, .stash_seq = 7 }, .{ .id = 3 }, .{ .id = 4 } };
    const n = rowOfFour(&v);
    var b = try buildWith(testing.allocator, FakeTree{ .nodes = &n }, fakeId, .all);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), b.nodes[0].split.right);
    try testing.expectEqual(@as(Id, 2), b.nodes[3].leaf);
}

test "pane_stack_grid: a wholly stashed side leaves the visible root" {
    var v = [_]FakeView{ .{ .id = 1, .stash_seq = 1 }, .{ .id = 2 }, .{ .id = 3 }, .{ .id = 4 } };
    const n = rowOfFour(&v);
    var b = try build(testing.allocator, FakeTree{ .nodes = &n }, fakeId);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 2), b.root);
}

test "pane_stack_grid: everything stashed lays out nothing" {
    var v = [_]FakeView{ .{ .id = 1, .stash_seq = 1 }, .{ .id = 2, .stash_seq = 2 }, .{ .id = 3, .stash_seq = 3 }, .{ .id = 4, .stash_seq = 4 } };
    const n = rowOfFour(&v);
    var g = try compute(testing.allocator, FakeTree{ .nodes = &n }, fakeId, .{ .right = 800, .bottom = 600 }, 1, metrics(null), .{});
    defer g.deinit();
    try testing.expectEqual(@as(usize, 0), g.result.leaves.count());
}

test "pane_stack_grid: an empty tree lays out nothing" {
    var g = try compute(testing.allocator, FakeTree{ .nodes = &.{} }, fakeId, .{ .right = 800, .bottom = 600 }, 1, metrics(null), .{});
    defer g.deinit();
    try testing.expectEqual(@as(usize, 0), g.result.leaves.count());
}

test "pane_stack_grid: a roomy row tiles the pixel rect with the engine's gutters" {
    var v = [_]FakeView{ .{ .id = 1 }, .{ .id = 2 } };
    const n = [_]FakeNode{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = h(1), .right = h(2) } },
        .{ .leaf = &v[0] },
        .{ .leaf = &v[1] },
    };
    // 1.5x: 1500 px is 1000 DIP, room for two 300 DIP panes.
    const rect: PxRect = .{ .left = 10, .top = 40, .right = 1510, .bottom = 940 };
    var g = try compute(testing.allocator, FakeTree{ .nodes = &n }, fakeId, rect, 1.5, metrics(null), .{});
    defer g.deinit();
    const a = g.placement(1).?;
    const b = g.placement(2).?;
    try testing.expect(!a.is_tucked and !b.is_tucked);
    try testing.expectEqual(rect.left, a.rect.left);
    try testing.expectEqual(rect.top, a.rect.top);
    try testing.expectEqual(rect.right, b.rect.right);
    try testing.expectEqual(rect.bottom, b.rect.bottom);
    // The flat gutter is 6 DIP = 9 px between them, and it is the divider's.
    try testing.expectEqual(@as(i32, 9), b.rect.left - a.rect.right);
    try testing.expectEqual(@as(usize, 1), g.result.dividers.items.len);
    try testing.expectEqual(@as(u32, 0), g.result.dividers.items[0].node);
    const gut = g.dividerGutter(0);
    try testing.expectEqual(a.rect.right, gut.left);
    try testing.expectEqual(b.rect.left, gut.right);
    try testing.expectEqual(@as(?usize, 0), g.dividerAt(gut.left, 500));
    try testing.expectEqual(@as(?usize, null), g.dividerAt(gut.left - 1, 500));
    try testing.expectEqual(@as(?usize, null), g.dividerAt(gut.right, 500));
}

test "pane_stack_grid: shared DIP edges stay shared in pixels at a fractional scale" {
    var v = [_]FakeView{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 }, .{ .id = 4 } };
    const n = rowOfFour(&v);
    // 1.25x, 1601 px: 1280.8 DIP - roomy for four 300 DIP panes plus gutters.
    var g = try compute(testing.allocator, FakeTree{ .nodes = &n }, fakeId, .{ .right = 1601, .bottom = 700 }, 1.25, metrics(16), .{});
    defer g.deinit();
    try testing.expectEqual(@as(usize, 0), g.result.stacks.items.len);
    var prev_right: i32 = 0;
    for (1..5) |id| {
        const p = g.placement(id).?;
        if (id > 1) {
            // Gutter 16 DIP = 20 px, whatever the rounding did to the sizes.
            try testing.expectEqual(@as(i32, 20), p.rect.left - prev_right);
        } else try testing.expectEqual(@as(i32, 0), p.rect.left);
        prev_right = p.rect.right;
    }
    try testing.expectEqual(@as(i32, 1601), prev_right);
}

test "pane_stack_grid: four panes narrower than 4 x 300 DIP stack, and a strip is hit" {
    var v = [_]FakeView{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 }, .{ .id = 4 } };
    const n = rowOfFour(&v);
    // 2x DPI, 1520 px = 760 DIP: two on show, two tucked (the engine's own
    // 760 DIP case, through the adapter).
    var g = try compute(testing.allocator, FakeTree{ .nodes = &n }, fakeId, .{ .right = 1520, .bottom = 1200 }, 2, metrics(10), .{});
    defer g.deinit();
    try testing.expectEqual(@as(usize, 1), g.result.stacks.items.len);
    try testing.expectEqual(layout.Range{ .lo = 0, .hi = 1 }, g.result.stacks.items[0].run);
    try testing.expect(!g.placement(1).?.is_tucked);
    try testing.expect(!g.placement(2).?.is_tucked);
    const p3 = g.placement(3).?;
    const p4 = g.placement(4).?;
    try testing.expect(p3.is_tucked and p4.is_tucked);
    // A stacked row draws no divider; its strips are where clicks land.
    try testing.expectEqual(@as(usize, 0), g.result.dividers.items.len);
    const t3 = p3.tab.?;
    const t4 = p4.tab.?;
    try testing.expectEqual(@as(?Id, 3), g.stripAt(t3.left + 1, @divTrunc(t3.top + t3.bottom, 2)));
    try testing.expectEqual(@as(?Id, 4), g.stripAt(t4.right - 1, @divTrunc(t4.top + t4.bottom, 2)));
    // A pane on show has no strip to hit.
    const r1 = g.placement(1).?.rect;
    try testing.expectEqual(@as(?Id, null), g.stripAt(r1.left + 5, r1.top + 5));
    // Every card is the same width, so moving the run never resizes one.
    try testing.expectEqual(g.placement(1).?.rect.width(), p4.rect.width());
}

test "pane_stack_grid: the focused pane is on show through the provider" {
    var v = [_]FakeView{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 }, .{ .id = 4 } };
    const n = rowOfFour(&v);
    const P = struct {
        fn rank(_: ?*const anyopaque, id: Id) ?u32 {
            return if (id == 4) 0 else null;
        }
    };
    var g = try compute(testing.allocator, FakeTree{ .nodes = &n }, fakeId, .{ .right = 760, .bottom = 600 }, 1, metrics(10), .{ .rank = P.rank });
    defer g.deinit();
    try testing.expect(!g.placement(4).?.is_tucked);
    try testing.expect(g.placement(1).?.is_tucked);
}

test "pane_stack_grid: a vertical split is a column" {
    var v = [_]FakeView{ .{ .id = 1 }, .{ .id = 2 } };
    const n = [_]FakeNode{
        .{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = h(1), .right = h(2) } },
        .{ .leaf = &v[0] },
        .{ .leaf = &v[1] },
    };
    var g = try compute(testing.allocator, FakeTree{ .nodes = &n }, fakeId, .{ .right = 800, .bottom = 806 }, 1, metrics(null), .{});
    defer g.deinit();
    const a = g.placement(1).?.rect;
    const b = g.placement(2).?.rect;
    try testing.expectEqual(a.left, b.left);
    try testing.expectEqual(@as(i32, 400), a.bottom);
    try testing.expectEqual(@as(i32, 406), b.top);
    try testing.expectEqual(layout.Direction.vertical, g.result.dividers.items[0].direction);
}
