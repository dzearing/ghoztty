//! Where every pane of a window's split tree goes, in DIPs: the stacked-panes
//! layout (T2082). A port of Mac's `PaneLayout.swift` (86b7e3410, with the
//! sticky run of d26e51183), pure and with no OS imports, so its unit tests
//! run in every app-runtime lane (the hero_math.zig pattern).
//!
//! It is the ONE layout function: the grid renders from it, the stashed-pane
//! slots render from it (so a stashed pane always has the size it will come
//! back at), and the tests check it. A tree, a rectangle and a focus history
//! go in; frames come out.
//!
//! It owns two rules a per-binary-split walk cannot express, because both need
//! to see a whole ROW of panes at once:
//!
//! - **A pane has a real minimum size** (`Metrics.minimum_pane_*`, 225 x 125
//!   DIP). A row whose ratios would squeeze a pane below it is laid out as if
//!   the ratios had been honored as far as they can be (`waterFill`), without
//!   touching the stored ratios — so shrinking a window and growing it back
//!   returns the layout the user made.
//! - **A row that cannot fit even at the minimum becomes a stack.** As many
//!   panes as fit stay side by side (the visible RUN); the rest are cards
//!   tucked at the side they live on, each showing a `peek`-wide strip of its
//!   leading edge. A tucked card is the size of the slot it would come forward
//!   into, so with equal slots changing the run moves cards but never resizes
//!   one — which is what lets the carousel slide without a ConPTY resize per
//!   frame.
//! - **The user can collapse a row by hand** (`Pin`): dragging a divider past a
//!   pane's minimum tucks that side's outermost pane.
//!
//! "Row" means a same-direction chain of the binary tree: `a | (b | c)` is one
//! row of three, and `a | (b / c)` is a row of two whose second item is a
//! column.
//!
//! The input tree is this module's own `Node` slice rather than
//! `SplitTree(PaneView)`, so the tests need no views; the window maps its
//! split tree onto it node for node (same indices), which is also how a
//! `Divider.node` and `Result.displayed_ratio` name a split of the real tree.
//!
//! Units are DIPs as f64. Mac's `rounded()` is half-away-from-zero, which is
//! Zig's `@round`; `rounded(.down)` is `@floor`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Id = u64;

pub const Direction = enum { horizontal, vertical };

pub const Side = enum { leading, trailing };

/// How far away a `Leaf.clip` puts the edges that bound nothing.
pub const unbounded: f64 = 100_000;

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    pub fn maxX(r: Rect) f64 {
        return r.x + r.w;
    }
    pub fn maxY(r: Rect) f64 {
        return r.y + r.h;
    }

    /// The slice of this rect from `offset` to `offset + length` along `d`
    /// (offsets from the rect's own leading edge), spanning it across.
    pub fn span(r: Rect, d: Direction, offset: f64, length: f64) Rect {
        return switch (d) {
            .horizontal => .{ .x = r.x + offset, .y = r.y, .w = length, .h = r.h },
            .vertical => .{ .x = r.x, .y = r.y + offset, .w = r.w, .h = length },
        };
    }

    /// Whole DIPs, without growing past where the next pane starts the way a
    /// plain outward rounding would.
    pub fn integral(r: Rect) Rect {
        const x0 = @round(r.x);
        const y0 = @round(r.y);
        return .{ .x = x0, .y = y0, .w = @round(r.maxX()) - x0, .h = @round(r.maxY()) - y0 };
    }

    /// The overlap of two rects, or null when they do not overlap with a
    /// positive area (CGRect's `isNull || isEmpty`).
    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.maxX(), b.maxX());
        const y1 = @min(a.maxY(), b.maxY());
        if (x1 - x0 <= 0 or y1 - y0 <= 0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn unite(a: Rect, b: Rect) Rect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .w = @max(a.maxX(), b.maxX()) - x0, .h = @max(a.maxY(), b.maxY()) - y0 };
    }

    pub fn start(r: Rect, d: Direction) f64 {
        return if (d == .horizontal) r.x else r.y;
    }
    pub fn extentAlong(r: Rect, d: Direction) f64 {
        return if (d == .horizontal) r.w else r.h;
    }
};

/// An inclusive index range (Swift's `ClosedRange<Int>`). Never empty.
pub const Range = struct {
    lo: usize,
    hi: usize,

    pub fn count(r: Range) usize {
        return r.hi - r.lo + 1;
    }
    pub fn contains(r: Range, i: usize) bool {
        return i >= r.lo and i <= r.hi;
    }
};

pub const Metrics = struct {
    /// The space between two side-by-side panes.
    gap: f64,
    /// How much of a tucked card's leading edge shows.
    peek: f64 = default_peek,
    /// The smallest a pane may be before its row starts stacking.
    minimum_width: f64 = default_minimum_width,
    minimum_height: f64 = default_minimum_height,
    /// `minimum_peek` in this layout's units (`scaled` multiplies it).
    floor_peek: f64 = minimum_peek,

    /// The size floor: 225 is about 26 columns of a typical font and 125
    /// about seven rows - narrow, but still a terminal you can read a prompt
    /// and its output in (Mac afc64dc53 lowered it from 300 x 200, which
    /// stacked a row sooner than people wanted; T2284). Mac's points are DIPs
    /// here, scaled by the window's DPI by whoever turns frames into pixels.
    pub const default_minimum_width: f64 = 225;
    pub const default_minimum_height: f64 = 125;

    /// A tucked card shows this much of itself: room for the vertical title
    /// strip and a few columns of what is in it.
    pub const default_peek: f64 = 36;

    /// Below this a tucked card can no longer be hit; past it a window too
    /// small for even one pane plus strips lets the front panes shrink.
    pub const minimum_peek: f64 = 8;

    /// The flat style's gutter: its line runs down the middle. A real gutter,
    /// because the gutters are where every resize grip lives.
    pub const flat_gap: f64 = 6;

    pub fn forStyle(pane_gap: ?f64) Metrics {
        return .{ .gap = pane_gap orelse flat_gap };
    }

    /// These metrics in units `s` times smaller than a DIP - physical pixels,
    /// for a window at scale `s` (T2108). Frames are snapped to whole units
    /// (`Rect.integral`), and on Mac a whole point is a whole backing pixel
    /// pair; a whole DIP at 125% is not a whole pixel, so a 3 px gap laid out
    /// in DIPs came out 2, 3 or 4 px depending on where it fell. Laid out in
    /// pixels, the gap is rounded to whole pixels once and lands whole.
    pub fn scaled(m: Metrics, s: f64) Metrics {
        return .{
            .gap = @round(m.gap * s),
            .peek = m.peek * s,
            .minimum_width = m.minimum_width * s,
            .minimum_height = m.minimum_height * s,
            .floor_peek = m.floor_peek * s,
        };
    }

    fn minimum(m: Metrics, d: Direction) f64 {
        return if (d == .horizontal) m.minimum_width else m.minimum_height;
    }
};

/// The input tree: a flat node array whose `split` children are indices into
/// it. The window builds it from `SplitTree(PaneView).nodes`, index for index.
pub const Node = union(enum) {
    leaf: Id,
    split: Split,

    pub const Split = struct {
        direction: Direction,
        /// The left/top child's share, 0..1.
        ratio: f64,
        left: u32,
        right: u32,
    };
};

/// One pane's place.
pub const Leaf = struct {
    /// The pane's full frame. A tucked pane keeps its full size; most of it is
    /// behind the cards in front of it.
    frame: Rect,
    /// Whether the pane is a card tucked behind the visible run of a stack (at
    /// any level), rather than on show.
    is_tucked: bool,
    /// The part of a tucked pane that shows — its leading strip, where a click
    /// brings it forward. Null for a pane on show.
    tab: ?Rect = null,
    /// The axis the tab's stack runs along (`.horizontal`: a tall strip at the
    /// pane's left edge; `.vertical`: a short one at its top).
    tab_axis: ?Direction = null,
    /// The card is tucked into its stack, so it is drawn as its tab alone: the
    /// rest of it would lie under its neighbours.
    is_sliver: bool = false,
    /// Paint order: leaves are painted in ascending lexicographic order of
    /// this, one entry per stack the pane is in, outermost first. Ties keep
    /// the tree's order (`paintOrder`).
    elevation: []const i64 = &.{},
    /// Where the pane may draw, when a card hangs off its stack's far end.
    /// Only the far edges bound anything; the rest lie `unbounded` away.
    clip: ?Rect = null,
};

/// A row of panes and which of its items are on show, for the gestures that
/// change that.
pub const Row = struct {
    /// The items' leaf ids, in order.
    items: []const []const Id,
    /// The items on show: all of them for a row side by side.
    run: Range,
    /// The extent of each item on show, in order (`run.count()` of them).
    sizes: []const f64 = &.{},
    /// Where the row starts along its direction, and how long it is: what a
    /// drag's pointer is measured against.
    start: f64 = 0,
    extent: f64 = 0,
    /// The smallest each item may be along the row, in order.
    minimums: []const f64 = &.{},
    gap: f64 = 0,
    peek: f64 = Metrics.default_peek,

    /// What names the row in the stack state: its panes, sorted, so swapping
    /// two of them keeps the row what it was. Caller frees.
    pub fn key(r: Row, gpa: Allocator) Allocator.Error![]Id {
        var n: usize = 0;
        for (r.items) |it| n += it.len;
        const out = try gpa.alloc(Id, n);
        var i: usize = 0;
        for (r.items) |it| for (it) |id| {
            out[i] = id;
            i += 1;
        };
        std.mem.sort(Id, out, {}, std.sort.asc(Id));
        return out;
    }
};

/// How a gesture changes which items of a row are on show.
pub const Restack = union(enum) {
    /// One fewer: the outermost item on show on that side tucks away.
    collapse: Side,
    /// One more: the nearest item tucked on that side comes back out.
    expand: Side,
};

/// A row the user collapsed: `count` of its items on show from `start`,
/// whether or not the row would fit side by side.
pub const Pin = struct {
    start: usize,
    count: usize,

    /// Bring item `index` on show: the run grows to take it in, and when more
    /// than `fits` would then be on show, the items at the far end from it
    /// give way. Null when that shows all `n` items.
    pub fn restoring(p: Pin, index: usize, fits: usize, n: usize) ?Pin {
        var lower = @min(p.start, index);
        var upper = @max(p.start + p.count - 1, index);
        const most = @max(1, fits);
        if (upper - lower + 1 > most) {
            if (index < p.start) upper = lower + most - 1 else lower = upper + 1 - most;
        }
        const pin: Pin = .{ .start = lower, .count = upper - lower + 1 };
        return if (pin.count >= n) null else pin;
    }

    /// What is left of the pin when the items at `removed` leave a row of `n`
    /// (a pane closed, stashed, or moved away): the items on show close up
    /// over the slots the others left, and tucked ones stay tucked on their
    /// sides. When nothing on show is left, the item before the run comes on
    /// show — or, with nothing before it, the one after. Null when what is
    /// left all shows, or is no row at all.
    pub fn removing(p: Pin, gpa: Allocator, removed: []const usize, n: usize) Allocator.Error!?Pin {
        var origin: std.ArrayListUnmanaged(?usize) = .empty;
        defer origin.deinit(gpa);
        for (0..n) |i| {
            if (std.mem.indexOfScalar(usize, removed, i) == null) try origin.append(gpa, i);
        }
        return p.carrying(origin.items);
    }

    /// The pin when items join a row, at `added` of the `n` it has now (a
    /// split, a pane dropped or restored into it): one beside the run or
    /// inside it is on show with it, and one among the tucked items is tucked
    /// with them. Adding never brings a tucked item out.
    pub fn adding(p: Pin, gpa: Allocator, added: []const usize, n: usize) Allocator.Error!?Pin {
        const origin = try gpa.alloc(?usize, n);
        defer gpa.free(origin);
        var next: usize = 0;
        for (origin, 0..) |*o, i| {
            if (std.mem.indexOfScalar(usize, added, i) != null) {
                o.* = null;
            } else {
                o.* = next;
                next += 1;
            }
        }
        return p.carrying(origin);
    }

    /// The pin when the row's items become `origin`: each one's index in the
    /// row before, or null for one that joined it. Items keep the side of the
    /// run they were on, and a reorder keeps the same items on show.
    pub fn carrying(p: Pin, origin: []const ?usize) ?Pin {
        if (origin.len <= 1) return null;
        const run_end = p.start + p.count; // exclusive
        var first: ?usize = null;
        var last: ?usize = null;
        for (origin, 0..) |o, i| {
            const o_v = o orelse continue;
            if (o_v >= p.start and o_v < run_end) {
                if (first == null) first = i;
                last = i;
            }
        }
        var pin: Pin = undefined;
        if (first) |f| {
            var lower = f;
            var upper = last.?;
            while (lower > 0 and origin[lower - 1] == null) lower -= 1;
            while (upper < origin.len - 1 and origin[upper + 1] == null) upper += 1;
            pin = .{ .start = lower, .count = upper - lower + 1 };
        } else {
            var before: usize = 0;
            var i = origin.len;
            while (i > 0) {
                i -= 1;
                if (origin[i]) |o| if (o < p.start) {
                    before = i;
                    break;
                };
            }
            pin = .{ .start = before, .count = 1 };
        }
        return if (pin.count >= origin.len) null else pin;
    }

    /// What `change` makes of a row of `n` items showing `run`; null when it
    /// shows the whole row again.
    pub fn restacking(run: Range, n: usize, change: Restack) ?Pin {
        var pin: Pin = undefined;
        switch (change) {
            .collapse => |side| {
                if (run.count() <= 1) return .{ .start = run.lo, .count = run.count() };
                pin = .{ .start = if (side == .leading) run.lo + 1 else run.lo, .count = run.count() - 1 };
            },
            .expand => |side| {
                const s = if (side == .leading) (if (run.lo > 0) run.lo - 1 else 0) else run.lo;
                pin = .{ .start = s, .count = @min(n - s, run.count() + 1) };
            },
        }
        return if (pin.count >= n) null else pin;
    }

    pub fn eql(a: ?Pin, b: ?Pin) bool {
        if (a == null or b == null) return a == null and b == null;
        return a.?.start == b.?.start and a.?.count == b.?.count;
    }
};

/// What a gutter of `row` dragged to `position` (the gutter's centre, from
/// the row's start) makes of the row: any gutter - a divider, a grip between
/// cards on show, a grip where the run meets its strips. Mac
/// `PaneLayout.dragged` (a81db68f9).
///
/// The items before the gutter get the space from the row's start to it, the
/// items after it the rest. Each side shows as many of its items as fit at
/// their minimums - nearest the gutter first, and never more than it had on
/// show when the drag began (`start_sizes`: each item's size then, null for a
/// strip), or one if it had none - and the others are strips at the row's
/// edge on that side; a side with no room for even one is all strips, the
/// gutter at their edge, the other side taking the rest. The item beside the
/// gutter takes up the slack; the others keep their sizes until the space
/// runs out, and then give way nearest first.
///
/// So a drag only collapses panes and brings out at most one: dragging a
/// gutter one way tucks the panes on that side away one after another while
/// the panes on the other side grow - its strips stay strips - and a strip
/// pulled out by its gutter comes out alone, the other side giving way.
/// Dragging back undoes exactly that: the row is a function of where the
/// gutter is, never of how it got there. Caller frees the sizes.
pub fn dragged(gpa: Allocator, row: Row, boundary: usize, position: f64, start_sizes: []const ?f64) Allocator.Error!Dragged {
    const n = row.items.len;
    if (boundary == 0 or boundary >= n) return .{ .run = row.run, .sizes = try gpa.dupe(f64, row.sizes) };
    const G = struct {
        row: Row,
        start_sizes: []const ?f64,
        boundary: usize,

        fn step(g: @This()) f64 {
            return g.row.peek + g.row.gap;
        }
        /// An item's floor for this drag: its minimum, or the size the drag
        /// found it at when that is less. The grid snaps sizes to whole
        /// pixels, so a pane at its minimum can be laid out a fraction under
        /// it (337 px against 337.5 at 150%, T2284); measured against the bare
        /// minimum it would not fit where it already is, and a grip pressed
        /// and let go without moving would fold it away.
        fn minimum(g: @This(), i: usize) f64 {
            const m = if (i < g.row.minimums.len) g.row.minimums[i] else 0;
            return if (g.start(i)) |s| @min(m, s) else m;
        }
        fn start(g: @This(), i: usize) ?f64 {
            return if (i < g.start_sizes.len) g.start_sizes[i] else null;
        }
        /// How many items lie on `side` of the gutter.
        fn len(g: @This(), side: Side) usize {
            return if (side == .leading) g.boundary else g.row.items.len - g.boundary;
        }
        /// The row index of the `j`th item on `side`, nearest the gutter first.
        fn at(g: @This(), side: Side, j: usize) usize {
            return if (side == .leading) g.boundary - 1 - j else g.boundary + j;
        }
        /// The extent the first `k` of `side` need on show, the rest of it as
        /// strips.
        fn need(g: @This(), side: Side, k: usize) f64 {
            const count: f64 = @floatFromInt(g.len(side));
            if (k == 0) return g.step() * count - g.row.gap;
            var total: f64 = 0;
            for (0..k) |j| total += g.minimum(g.at(side, j));
            const kf: f64 = @floatFromInt(k);
            return total + g.row.gap * (kf - 1) + g.step() * (count - kf);
        }
        /// A drag only collapses panes, and brings out at most one: a side
        /// shows no more than it had on show when the drag began - or, all
        /// strips then, the one pane beside the gutter, pulled out.
        fn most(g: @This(), side: Side) usize {
            var shown: usize = 0;
            for (0..g.len(side)) |j| {
                if (g.start(g.at(side, j)) != null) shown += 1;
            }
            return @max(1, shown);
        }
        /// How many of `side` fit on show in `space`.
        fn fits(g: @This(), side: Side, space: f64) usize {
            var count: usize = 0;
            while (count < g.most(side) and g.need(side, count + 1) <= space) count += 1;
            return count;
        }
        /// One side, in `space`: what is on show, at what size, into `out`.
        fn fill(g: @This(), side: Side, space: f64, out: []?f64) void {
            const count = g.fits(side, space);
            if (count == 0) return;
            const strips: f64 = @floatFromInt(g.len(side) - count);
            const gaps: f64 = @floatFromInt(count - 1);
            const cards = space - g.step() * strips - g.row.gap * gaps;
            var rest: f64 = 0;
            for (1..count) |j| {
                const i = g.at(side, j);
                const size = @max(g.start(i) orelse g.minimum(i), g.minimum(i));
                out[i] = size;
                rest += size;
            }
            const first = g.at(side, 0);
            var deficit = g.minimum(first) - (cards - rest);
            for (1..count) |j| {
                if (!(deficit > 0)) break;
                const i = g.at(side, j);
                const give = @min(deficit, out[i].? - g.minimum(i));
                out[i].? -= give;
                rest -= give;
                deficit -= give;
            }
            out[first] = cards - rest;
        }
    };
    const g: G = .{ .row = row, .start_sizes = start_sizes, .boundary = boundary };

    // Each side's extent: up to the gutter - or, a side that is all strips,
    // just its strips, the other side taking the rest.
    var left = position - row.gap / 2;
    var right = row.extent - position - row.gap / 2;
    if (g.fits(.leading, left) == 0) {
        left = g.need(.leading, 0);
        right = row.extent - left - row.gap;
    } else if (g.fits(.trailing, right) == 0) {
        right = g.need(.trailing, 0);
        left = row.extent - right - row.gap;
    }

    const sized = try gpa.alloc(?f64, n);
    defer gpa.free(sized);
    @memset(sized, null);
    g.fill(.leading, left, sized);
    g.fill(.trailing, right, sized);
    var lo: ?usize = null;
    var hi: usize = 0;
    for (sized, 0..) |s, i| if (s != null) {
        if (lo == null) lo = i;
        hi = i;
    };
    const first = lo orelse return .{ .run = row.run, .sizes = try gpa.dupe(f64, row.sizes) };
    const sizes = try gpa.alloc(f64, hi + 1 - first);
    for (sizes, first..) |*s, i| s.* = sized[i] orelse g.minimum(i);
    return .{ .run = .{ .lo = first, .hi = hi }, .sizes = sizes };
}

/// What `dragged` makes of a row.
pub const Dragged = struct {
    /// The items on show; the rest are strips.
    run: Range,
    /// The extent of each item of `run`, in order. The caller's to free.
    sizes: []f64,
};

/// One split of a row, with the ratio that sizes it (`settingRow`).
pub const RowRatio = struct {
    /// An index into the input nodes.
    node: u32,
    ratio: f64,
};

/// The splits of the row of `items` (each item's leaf ids, in order) along
/// `d` within the tree at `root`, each with the ratio that gives every item
/// its share of `shares` (one per item) - or, `shares` null, the ratio it has
/// now. Null when the tree holds no such row. Caller frees. Mac
/// `SplitTree.settingRow` (a81db68f9): how a gutter drag that leaves the whole
/// row on show sizes it, through the tree's ratios rather than a collapse.
pub fn settingRow(gpa: Allocator, nodes: []const Node, root: u32, d: Direction, items: []const []const Id, shares: ?[]const f64) Allocator.Error!?[]RowRatio {
    if (shares) |s| if (s.len != items.len) return null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const T = struct {
        nodes: []const Node,
        d: Direction,

        fn along(t: @This(), node: u32) ?Node.Split {
            if (node >= t.nodes.len) return null;
            return switch (t.nodes[node]) {
                .split => |s| if (s.direction == t.d) s else null,
                .leaf => null,
            };
        }
        fn leaves(t: @This(), al: Allocator, node: u32, out: *std.ArrayListUnmanaged(Id)) Allocator.Error!void {
            if (node >= t.nodes.len) return;
            switch (t.nodes[node]) {
                .leaf => |id| try out.append(al, id),
                .split => |s| {
                    try t.leaves(al, s.left, out);
                    try t.leaves(al, s.right, out);
                },
            }
        }
        fn rowItems(t: @This(), al: Allocator, node: u32, out: *std.ArrayListUnmanaged([]const Id)) Allocator.Error!void {
            if (t.along(node)) |s| {
                try t.rowItems(al, s.left, out);
                try t.rowItems(al, s.right, out);
                return;
            }
            var ids: std.ArrayListUnmanaged(Id) = .empty;
            try t.leaves(al, node, &ids);
            try out.append(al, ids.items);
        }
        fn itemCount(t: @This(), node: u32) usize {
            const s = t.along(node) orelse return 1;
            return t.itemCount(s.left) + t.itemCount(s.right);
        }
        fn heads(t: @This(), al: Allocator, node: u32, want: []const []const Id) Allocator.Error!bool {
            if (t.along(node) == null) return false;
            var got: std.ArrayListUnmanaged([]const Id) = .empty;
            try t.rowItems(al, node, &got);
            if (got.items.len != want.len) return false;
            for (got.items, want) |x, y| if (!std.mem.eql(Id, x, y)) return false;
            return true;
        }
        fn find(t: @This(), al: Allocator, node: u32, want: []const []const Id) Allocator.Error!?u32 {
            if (node >= t.nodes.len) return null;
            if (try t.heads(al, node, want)) return node;
            const s = switch (t.nodes[node]) {
                .split => |s| s,
                .leaf => return null,
            };
            return (try t.find(al, s.left, want)) orelse try t.find(al, s.right, want);
        }
        fn sized(t: @This(), al: Allocator, node: u32, part: ?[]const f64, out: *std.ArrayListUnmanaged(RowRatio)) Allocator.Error!void {
            const s = t.along(node) orelse return;
            const count = t.itemCount(s.left);
            var ratio = s.ratio;
            var split: usize = 0;
            if (part) |p| {
                split = @min(count, p.len);
                var total: f64 = 0;
                for (p) |v| total += v;
                var lead: f64 = 0;
                for (p[0..split]) |v| lead += v;
                if (total > 0) ratio = lead / total;
            }
            try out.append(al, .{ .node = node, .ratio = ratio });
            try t.sized(al, s.left, if (part) |p| p[0..split] else null, out);
            try t.sized(al, s.right, if (part) |p| p[split..] else null, out);
        }
    };
    const t: T = .{ .nodes = nodes, .d = d };
    const head = (try t.find(a, root, items)) orelse return null;
    var out: std.ArrayListUnmanaged(RowRatio) = .empty;
    try t.sized(a, head, shares, &out);
    return try gpa.dupe(RowRatio, out.items);
}

/// Distribute `available` in proportion to `wanted`, giving no item less than
/// its entry in `minimums`: an item that would fall below its minimum is
/// pinned there and the rest share what is left, again in proportion. The
/// caller guarantees `minimums` fit in `available`. Caller frees.
pub fn waterFill(gpa: Allocator, wanted: []const f64, minimums: []const f64, available: f64) Allocator.Error![]f64 {
    const out = try gpa.alloc(f64, wanted.len);
    waterFillInto(wanted, minimums, available, out);
    return out;
}

fn waterFillInto(wanted: []const f64, minimums: []const f64, available: f64, sizes: []f64) void {
    std.debug.assert(sizes.len == wanted.len);
    @memset(sizes, 0);
    // Rows are a handful of panes; a fixed mask keeps this allocation-free.
    var pinned_buf: [256]bool = undefined;
    const pinned = pinned_buf[0..@min(wanted.len, pinned_buf.len)];
    @memset(pinned, false);
    while (true) {
        var pinned_total: f64 = 0;
        var free_count: usize = 0;
        var wanted_total: f64 = 0;
        for (pinned, 0..) |p, i| {
            if (p) pinned_total += sizes[i] else {
                free_count += 1;
                wanted_total += @max(wanted[i], 0);
            }
        }
        if (free_count == 0) return;
        for (pinned, 0..) |p, i| {
            if (p) continue;
            const share = if (wanted_total > 0)
                @max(wanted[i], 0) / wanted_total
            else
                1.0 / @as(f64, @floatFromInt(free_count));
            sizes[i] = (available - pinned_total) * share;
        }
        var any_under = false;
        for (pinned, 0..) |p, i| {
            if (!p and sizes[i] < minimums[i]) any_under = true;
        }
        if (!any_under) return;
        for (pinned, 0..) |*p, i| {
            if (!p.* and sizes[i] < minimums[i]) {
                sizes[i] = minimums[i];
                p.* = true;
            }
        }
    }
}

/// Which items of a stack are on show: the most recently focused one (rank 0
/// is the focused pane; null: never focused), grown to `count` items toward
/// whichever neighbour had focus more recently — to the trailing side on a
/// tie, so a stack nobody has focused shows its first items.
pub fn visibleRun(ranks: []const ?u32, count_in: usize) Range {
    const n = ranks.len;
    if (n == 0) return .{ .lo = 0, .hi = 0 };
    const count = @min(@max(count_in, 1), n);
    const key = struct {
        fn k(r: ?u32) u64 {
            return if (r) |v| v else std.math.maxInt(u64);
        }
    }.k;
    var front: usize = 0;
    for (ranks, 0..) |r, i| {
        if (key(r) < key(ranks[front])) front = i;
    }
    var s = front;
    var e = front;
    while (e - s + 1 < count) {
        const before: ?u64 = if (s > 0) key(ranks[s - 1]) else null;
        const after: ?u64 = if (e < n - 1) key(ranks[e + 1]) else null;
        if (before != null and after != null) {
            if (after.? <= before.?) e += 1 else s -= 1;
        } else if (before != null) {
            s -= 1;
        } else {
            e += 1;
        }
    }
    return .{ .lo = s, .hi = e };
}

/// Which items of a stack are on show, given the run it showed when last laid
/// out (`before`): that run again while it is the same size and shows the most
/// recently focused item, else slid just far enough to show it — so focusing
/// a pane on show never moves a card, and focusing a strip moves the fewest.
/// With no run before, or one of another size (the window grew or shrank past
/// a card), `visibleRun`.
pub fn stickyRun(before_in: ?Range, ranks: []const ?u32, count_in: usize) Range {
    const n = ranks.len;
    const count = @min(@max(count_in, 1), n);
    const before = before_in orelse return visibleRun(ranks, count);
    if (before.count() != count or before.hi >= n) return visibleRun(ranks, count);
    var front: ?usize = null;
    var best: u64 = std.math.maxInt(u64);
    for (ranks, 0..) |r, i| {
        if (r) |v| if (v < best) {
            best = v;
            front = i;
        };
    }
    const f = front orelse return before;
    if (before.contains(f)) return before;
    return if (f < before.lo)
        .{ .lo = f, .hi = f + count - 1 }
    else
        .{ .lo = f + 1 - count, .hi = f };
}

/// A divider between two side-by-side panes (or groups of panes).
pub const Divider = struct {
    /// The binary split this divider belongs to (an index into the input
    /// nodes) — what a drag on it moves.
    node: u32,
    direction: Direction,
    /// The split node's whole frame.
    node_frame: Rect,
    /// The divider's centre, from the leading edge of `node_frame` along
    /// `direction`.
    position: f64,
    /// The row the divider is in. A drag that would squeeze a pane past its
    /// minimum collapses the row instead.
    row: Row,
    /// How many of the row's items lie before the divider.
    index: usize,
    /// The gutter between the panes either side: where the divider takes the
    /// mouse, and nowhere else.
    gutter: Rect,

    /// The divider's current position as a fraction of the node.
    pub fn fraction(d: Divider) f64 {
        const extent = d.node_frame.extentAlong(d.direction);
        return if (extent > 0) d.position / extent else 0.5;
    }
};

/// A grip on a stacked row: between two cards on show, or at the edge where
/// the run meets the tucked cards of a row the user collapsed.
pub const StackHandle = struct {
    pub const Kind = union(enum) {
        /// Between run slots `slot` and `slot + 1` (indices into `row.sizes`).
        between: usize,
        /// At the run's edge on that side.
        expand: Side,
    };

    row: Row,
    direction: Direction,
    /// The stack's frame.
    frame: Rect,
    /// The grip's centre, from the stack's leading edge.
    position: f64,
    kind: Kind,
    /// The gutter the grip sits in, where it takes the mouse.
    gutter: Rect,
};

/// A row that is stacked, for callers that want to know (tests, `+list`).
pub const Stack = struct {
    frame: Rect,
    direction: Direction,
    items: []const []const Id,
    /// The visible run: the indices of the items on show.
    run: Range,
    /// How many items could be on show at once in this space: all of them for
    /// a row the user collapsed that would fit side by side.
    fits: usize = 0,
};

/// What the caller knows about panes and rows. Every hook is optional.
pub const Provider = struct {
    ctx: ?*const anyopaque = null,
    /// How recently a pane had focus, 0 being the focused one (null: never).
    /// A stack's run is built around the most recently focused of its items.
    rank: ?*const fn (ctx: ?*const anyopaque, id: Id) ?u32 = null,
    /// The pin of a row the user collapsed, by the row's key (sorted ids).
    pin: ?*const fn (ctx: ?*const anyopaque, key: []const Id) ?Pin = null,
    /// The run slots' shares, as the user sized them, by the row's key.
    shares: ?*const fn (ctx: ?*const anyopaque, key: []const Id) ?[]const f64 = null,
    /// The run a row of these items had when last laid out, if it was a stack.
    shown: ?*const fn (ctx: ?*const anyopaque, items: []const []const Id) ?Range = null,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    leaves: std.AutoArrayHashMapUnmanaged(Id, Leaf) = .empty,
    dividers: std.ArrayListUnmanaged(Divider) = .empty,
    stacks: std.ArrayListUnmanaged(Stack) = .empty,
    stack_handles: std.ArrayListUnmanaged(StackHandle) = .empty,
    /// The tree as laid out, one entry per input node (leaves keep their
    /// input value): every side-by-side row's ratios are the ones on screen,
    /// after minimums. A divider drag starts from these, so it moves what the
    /// user sees rather than ratios the minimums are overriding.
    displayed_ratio: []f64 = &.{},

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn leaf(self: *const Result, id: Id) ?Leaf {
        return self.leaves.get(id);
    }
};

/// Lay `nodes[root]` out in `rect`.
pub fn compute(
    gpa: Allocator,
    nodes: []const Node,
    root: u32,
    rect: Rect,
    metrics: Metrics,
    provider: Provider,
) Allocator.Error!Result {
    var result: Result = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer result.arena.deinit();
    const a = result.arena.allocator();
    result.displayed_ratio = try a.alloc(f64, nodes.len);
    for (nodes, 0..) |n, i| result.displayed_ratio[i] = switch (n) {
        .leaf => 0,
        .split => |s| s.ratio,
    };
    var engine: Engine = .{ .a = a, .nodes = nodes, .metrics = metrics, .provider = provider, .result = &result };
    if (root < nodes.len) try engine.layout(root, rect, false, null);
    return result;
}

/// Every row under `root`, outermost first, as its items' leaf ids: what the
/// stack state keys a row's collapse by. Allocated in `a` (use an arena).
pub fn rows(a: Allocator, nodes: []const Node, root: u32) Allocator.Error![]const []const []const Id {
    var out: std.ArrayListUnmanaged([]const []const Id) = .empty;
    try rowsInto(a, nodes, root, &out);
    return out.items;
}

fn rowsInto(a: Allocator, nodes: []const Node, node: u32, out: *std.ArrayListUnmanaged([]const []const Id)) Allocator.Error!void {
    if (node >= nodes.len) return;
    const split = switch (nodes[node]) {
        .leaf => return,
        .split => |s| s,
    };
    var items: std.ArrayListUnmanaged(u32) = .empty;
    try chainItems(a, nodes, node, split.direction, &items);
    const row = try a.alloc([]const Id, items.items.len);
    for (items.items, 0..) |it, i| row[i] = try leavesOf(a, nodes, it);
    try out.append(a, row);
    for (items.items) |it| try rowsInto(a, nodes, it, out);
}

fn chainItems(a: Allocator, nodes: []const Node, node: u32, d: Direction, out: *std.ArrayListUnmanaged(u32)) Allocator.Error!void {
    switch (nodes[node]) {
        .split => |s| if (s.direction == d) {
            try chainItems(a, nodes, s.left, d, out);
            try chainItems(a, nodes, s.right, d, out);
            return;
        },
        .leaf => {},
    }
    try out.append(a, node);
}

/// A node's leaf ids in tree order.
fn leavesOf(a: Allocator, nodes: []const Node, node: u32) Allocator.Error![]const Id {
    var out: std.ArrayListUnmanaged(Id) = .empty;
    try appendLeaves(a, nodes, node, &out);
    return out.items;
}

fn appendLeaves(a: Allocator, nodes: []const Node, node: u32, out: *std.ArrayListUnmanaged(Id)) Allocator.Error!void {
    switch (nodes[node]) {
        .leaf => |id| try out.append(a, id),
        .split => |s| {
            try appendLeaves(a, nodes, s.left, out);
            try appendLeaves(a, nodes, s.right, out);
        },
    }
}

/// The smallest extent of `nodes[root]` along `d` with every pane at
/// `minimum`: side by side, or — with `stacking` — with rows that don't fit
/// stacked. No gaps: this is what a divider move clamps against.
pub fn minimumExtent(gpa: Allocator, nodes: []const Node, root: u32, d: Direction, minimum_width: f64, minimum_height: f64, stacking: bool) Allocator.Error!f64 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var dummy: Result = .{ .arena = undefined };
    var engine: Engine = .{
        .a = arena.allocator(),
        .nodes = nodes,
        .metrics = .{ .gap = 0, .minimum_width = minimum_width, .minimum_height = minimum_height },
        .provider = .{},
        .result = &dummy,
    };
    return if (stacking) engine.compact(root, d) else engine.comfortable(root, d);
}

/// `panes` (in tree order) in the order to paint them, bottom first: by
/// `Leaf.elevation`, ties in tree order. Sorts in place.
pub fn paintOrder(panes: []Id, result: *const Result) void {
    const Ctx = struct {
        r: *const Result,
        order: []const Id,
        fn elev(c: @This(), id: Id) []const i64 {
            return if (c.r.leaves.get(id)) |l| l.elevation else &.{};
        }
        fn lessThan(c: @This(), x: Id, y: Id) bool {
            return std.mem.order(i64, c.elev(x), c.elev(y)) == .lt;
        }
    };
    // Stable: equal elevations keep tree order.
    std.sort.insertion(Id, panes, Ctx{ .r = result, .order = panes }, Ctx.lessThan);
}

const Engine = struct {
    a: Allocator,
    nodes: []const Node,
    metrics: Metrics,
    provider: Provider,
    result: *Result,
    /// The elevation of the card being laid out, in each stack it is in.
    elevation: std.ArrayListUnmanaged(i64) = .empty,

    const Item = struct { node: u32, share: f64 };

    /// The items of the same-direction chain rooted at `node`, each with its
    /// share of the chain.
    fn items(e: *Engine, node: u32, d: Direction) Allocator.Error![]Item {
        var out: std.ArrayListUnmanaged(Item) = .empty;
        try e.itemsInto(node, d, 1, &out);
        return out.items;
    }

    fn itemsInto(e: *Engine, node: u32, d: Direction, share: f64, out: *std.ArrayListUnmanaged(Item)) Allocator.Error!void {
        switch (e.nodes[node]) {
            .split => |sp| if (sp.direction == d) {
                try e.itemsInto(sp.left, d, share * sp.ratio, out);
                try e.itemsInto(sp.right, d, share * (1 - sp.ratio), out);
                return;
            },
            .leaf => {},
        }
        try out.append(e.a, .{ .node = node, .share = share });
    }

    fn ids(e: *Engine, row: []const Item) Allocator.Error![]const []const Id {
        const out = try e.a.alloc([]const Id, row.len);
        for (row, 0..) |it, i| out[i] = try leavesOf(e.a, e.nodes, it.node);
        return out;
    }

    fn keyOf(e: *Engine, row: []const Item) Allocator.Error![]const Id {
        var out: std.ArrayListUnmanaged(Id) = .empty;
        for (row) |it| try appendLeaves(e.a, e.nodes, it.node, &out);
        std.mem.sort(Id, out.items, {}, std.sort.asc(Id));
        return out.items;
    }

    /// The pin of a row the user collapsed, if it still collapses it.
    fn pinned(e: *Engine, row: []const Item) Allocator.Error!?Pin {
        if (row.len <= 1) return null;
        const f = e.provider.pin orelse return null;
        const p = f(e.provider.ctx, try e.keyOf(row)) orelse return null;
        if (p.count >= row.len) return null;
        const count = @max(1, p.count);
        return .{ .start = @min(p.start, row.len - p.count), .count = count };
    }

    /// The smallest extent along `d` that shows every pane of `node` side by
    /// side at its minimum.
    fn comfortable(e: *Engine, node: u32, d: Direction) Allocator.Error!f64 {
        const s = switch (e.nodes[node]) {
            .leaf => return e.metrics.minimum(d),
            .split => |sp| sp,
        };
        if (s.direction != d) return @max(try e.comfortable(s.left, d), try e.comfortable(s.right, d));
        const row = try e.items(node, d);
        const m = e.metrics;
        if (try e.pinned(row)) |pin| {
            // Collapsed by the user: its run of cards, and strips.
            var card: f64 = 0;
            for (row) |it| card = @max(card, try e.compact(it.node, d));
            const pc: f64 = @floatFromInt(pin.count);
            return card * pc + m.gap * (pc - 1) +
                (m.peek + m.gap) * @as(f64, @floatFromInt(row.len - pin.count));
        }
        var total: f64 = 0;
        for (row) |it| total += try e.comfortable(it.node, d);
        return total + m.gap * @as(f64, @floatFromInt(row.len - 1));
    }

    /// The smallest extent along `d` that `node` fits in when its rows may
    /// stack.
    fn compact(e: *Engine, node: u32, d: Direction) Allocator.Error!f64 {
        const s = switch (e.nodes[node]) {
            .leaf => return e.metrics.minimum(d),
            .split => |sp| sp,
        };
        if (s.direction != d) return @max(try e.compact(s.left, d), try e.compact(s.right, d));
        const row = try e.items(node, d);
        var widest: f64 = 0;
        for (row) |it| widest = @max(widest, try e.compact(it.node, d));
        return widest + (e.metrics.peek + e.metrics.gap) * @as(f64, @floatFromInt(row.len - 1));
    }

    fn layout(e: *Engine, node: u32, rect: Rect, tucked: bool, clip: ?Rect) Allocator.Error!void {
        const s = switch (e.nodes[node]) {
            .leaf => |id| {
                try e.result.leaves.put(e.a, id, .{
                    .frame = rect.integral(),
                    .is_tucked = tucked,
                    .elevation = try e.a.dupe(i64, e.elevation.items),
                    .clip = clip,
                });
                return;
            },
            .split => |sp| sp,
        };
        const d = s.direction;
        const row = try e.items(node, d);
        const extent = rect.extentAlong(d);
        const gaps = e.metrics.gap * @as(f64, @floatFromInt(row.len - 1));
        var comfortable_total = gaps;
        var compact_total = gaps;
        for (row) |it| {
            comfortable_total += try e.comfortable(it.node, d);
            compact_total += try e.compact(it.node, d);
        }
        const fits_side_by_side = comfortable_total <= extent or compact_total <= extent;
        if ((try e.pinned(row)) == null and fits_side_by_side) {
            // Side by side. Prefer every pane at full size; only when that
            // can't fit may a nested row give way and stack.
            const minimums = try e.a.alloc(f64, row.len);
            const wanted = try e.a.alloc(f64, row.len);
            const available = extent - gaps;
            for (row, 0..) |it, i| {
                minimums[i] = if (comfortable_total <= extent)
                    try e.comfortable(it.node, d)
                else
                    try e.compact(it.node, d);
                wanted[i] = it.share * available;
            }
            const sizes = try waterFill(e.a, wanted, minimums, available);
            const spans = try e.a.alloc(Rect, row.len);
            var offset: f64 = 0;
            for (sizes, 0..) |size, i| {
                spans[i] = rect.span(d, offset, size);
                offset += size + e.metrics.gap;
            }
            const shown: Row = .{
                .items = try e.ids(row),
                .run = .{ .lo = 0, .hi = row.len - 1 },
                .sizes = sizes,
                .start = rect.start(d),
                .extent = extent,
                .minimums = minimums,
                .gap = e.metrics.gap,
                .peek = e.metrics.peek,
            };
            var index: usize = 0;
            _ = try e.layoutChain(node, d, spans, &index, shown, tucked, clip);
        } else {
            try e.layoutStack(row, rect, d, tucked, clip, fits_side_by_side);
        }
    }

    /// Walk the binary chain of a side-by-side row, laying each item out in
    /// its span and recording a divider for every split in the chain. Returns
    /// the frame the chain node covers; records the ratio it was laid out at.
    fn layoutChain(e: *Engine, node: u32, d: Direction, spans: []const Rect, index: *usize, row: Row, tucked: bool, clip: ?Rect) Allocator.Error!Rect {
        const s = switch (e.nodes[node]) {
            .split => |sp| if (sp.direction == d) sp else null,
            .leaf => null,
        } orelse {
            const span = spans[index.*];
            index.* += 1;
            try e.layout(node, span, tucked, clip);
            return span;
        };
        const first = index.*;
        const left = try e.layoutChain(s.left, d, spans, index, row, tucked, clip);
        const before = index.*;
        const right = try e.layoutChain(s.right, d, spans, index, row, tucked, clip);
        const frame = left.unite(right);
        const centre = if (d == .horizontal) (left.maxX() + right.x) / 2 else (left.maxY() + right.y) / 2;
        const start = frame.start(d);
        // The ratio on screen as this engine reads a ratio: the left side's
        // share of the panes' sizes, the gutters left out (`itemsInto`). Laid
        // out again it lands where it is, so a tree that adopts it does not
        // move (T2125; a fraction of the frame put every boundary half a
        // gutter off per adoption, which a held resize key compounded).
        var left_size: f64 = 0;
        var total_size: f64 = 0;
        for (spans[first..index.*], first..) |sp, i| {
            const size = sp.extentAlong(d);
            total_size += size;
            if (i < before) left_size += size;
        }
        if (total_size > 0) e.result.displayed_ratio[node] = left_size / total_size;
        // A tucked row's dividers are under the cards in front of it.
        if (!tucked) {
            // The gutter, in whole DIPs as the panes are (`integral`).
            const gutter: Rect = if (d == .horizontal) .{
                .x = @round(left.maxX()),
                .y = @round(frame.y),
                .w = @max(0, @round(right.x) - @round(left.maxX())),
                .h = @round(frame.maxY()) - @round(frame.y),
            } else .{
                .x = @round(frame.x),
                .y = @round(left.maxY()),
                .w = @round(frame.maxX()) - @round(frame.x),
                .h = @max(0, @round(right.y) - @round(left.maxY())),
            };
            try e.result.dividers.append(e.a, .{
                .node = node,
                .direction = d,
                .node_frame = frame,
                .position = centre - start,
                .row = row,
                .index = before,
                .gutter = gutter,
            });
        }
        return frame;
    }

    /// A row that doesn't fit: as many items side by side as fit, the rest
    /// tucked at either end. Every card on show and every strip is separated
    /// from the next by the same gutter as panes side by side: that is where
    /// the grips live. The gutters are the same wherever the run is, so moving
    /// it never resizes one.
    fn layoutStack(e: *Engine, row: []const Item, rect: Rect, d: Direction, tucked: bool, clip: ?Rect, fits_side_by_side: bool) Allocator.Error!void {
        const n = row.len;
        const nf: f64 = @floatFromInt(n);
        const gap = e.metrics.gap;
        const extent = rect.extentAlong(d);
        // No card smaller than the largest item's minimum.
        var card: f64 = 0;
        for (row) |it| card = @max(card, try e.compact(it.node, d));
        if (n == 0) card = e.metrics.minimum(d);
        const peek = @max(e.metrics.floor_peek, @min(e.metrics.peek, @floor((extent - card) / (nf - 1) - gap)));
        const Needed = struct {
            n: f64,
            peek: f64,
            gap: f64,
            card: f64,
            fn at(self: @This(), on_show: usize) f64 {
                const o: f64 = @floatFromInt(on_show);
                return (self.n - o) * (self.peek + self.gap) + o * self.card + (o - 1) * self.gap;
            }
        };
        const needed: Needed = .{ .n = nf, .peek = peek, .gap = gap, .card = card };
        const pin = try e.pinned(row);
        var fits: usize = 1;
        while (fits + 1 < n and needed.at(fits + 1) <= extent) fits += 1;
        const count = @min(fits, if (pin) |p| p.count else n - 1);
        const cf: f64 = @floatFromInt(count);
        if (fits_side_by_side) fits = n;
        // The run's slots: equal, or as the user sized them (`shares`), never
        // under a card's minimum. In whole DIPs, so a card that moves to a
        // slot of the same size is not resized by rounding.
        const run_space = @floor(extent - (nf - cf) * (peek + gap) - (cf - 1) * gap);
        const key = try e.keyOf(row);
        const user_shares: ?[]const f64 = if (e.provider.shares) |f| f(e.provider.ctx, key) else null;
        const wanted = try e.a.alloc(f64, count);
        const mins = try e.a.alloc(f64, count);
        for (0..count) |i| {
            wanted[i] = if (user_shares != null and user_shares.?.len == count)
                user_shares.?[i] * run_space
            else
                run_space / cf;
            mins[i] = @min(card, run_space / cf);
        }
        const slots = try waterFill(e.a, wanted, mins, run_space);
        for (slots) |*sl| sl.* = @max(1, @floor(sl.*));
        var head: f64 = 0;
        for (slots[0 .. count - 1]) |sl| head += sl;
        slots[count - 1] = @max(1, run_space - head);

        const ranks = try e.a.alloc(?u32, n);
        for (row, 0..) |it, i| {
            var best: ?u32 = null;
            if (e.provider.rank) |f| for (try leavesOf(e.a, e.nodes, it.node)) |id| {
                if (f(e.provider.ctx, id)) |r| best = if (best) |b| @min(b, r) else r;
            };
            ranks[i] = best;
        }
        const item_ids = try e.ids(row);
        const before: ?Range = if (e.provider.shown) |f| f(e.provider.ctx, item_ids) else null;
        var run: Range = undefined;
        if (pin) |p| {
            // The user's run, or — in a window too small for all of it — the
            // part of it around the pane last focused there.
            const window: Range = .{ .lo = p.start, .hi = p.start + p.count - 1 };
            const inner: ?Range = if (before) |b|
                (if (b.lo >= window.lo and b.hi <= window.hi) Range{ .lo = b.lo - p.start, .hi = b.hi - p.start } else null)
            else
                null;
            const part = stickyRun(inner, ranks[window.lo .. window.hi + 1], count);
            run = .{ .lo = part.lo + p.start, .hi = part.hi + p.start };
        } else {
            run = stickyRun(before, ranks, count);
        }

        const end = if (d == .horizontal) rect.maxX() else rect.maxY();
        const run_start = @as(f64, @floatFromInt(run.lo)) * (peek + gap);
        const Slot = struct {
            slots: []const f64,
            run_start: f64,
            gap: f64,
            /// Where slot `k` of the run starts.
            fn start(self: @This(), k: usize) f64 {
                var t = self.run_start;
                for (self.slots[0..k]) |sl| t += sl;
                return t + @as(f64, @floatFromInt(k)) * self.gap;
            }
        };
        const slot: Slot = .{ .slots = slots, .run_start = run_start, .gap = gap };
        const run_end = slot.start(count - 1) + slots[count - 1];
        for (row, 0..) |it, i| {
            // A tucked card is the size of the slot it would come forward
            // into: the run's first, or its last.
            const size = if (i < run.lo) slots[0] else if (i <= run.hi) slots[i - run.lo] else slots[count - 1];
            const offset = if (i < run.lo)
                @as(f64, @floatFromInt(i)) * (peek + gap)
            else if (i <= run.hi)
                slot.start(i - run.lo)
            else
                run_end + gap + @as(f64, @floatFromInt(i - run.hi - 1)) * (peek + gap);
            const frame = rect.span(d, offset, size);
            const is_tucked = !run.contains(i);
            // Past the run, cards run off the stack's far end; draw only the
            // part inside it.
            var child_clip = clip;
            if (i > run.hi) {
                const u = unbounded;
                const inside: Rect = if (d == .horizontal)
                    .{ .x = -u, .y = -u, .w = end + u, .h = 2 * u }
                else
                    .{ .x = -u, .y = -u, .w = 2 * u, .h = end + u };
                child_clip = if (child_clip) |c| (c.intersect(inside) orelse c) else inside;
            }
            // The run on top; tucked cards lower the farther out they are.
            const ni: i64 = @intCast(n);
            const ii: i64 = @intCast(i);
            const elev: i64 = if (i < run.lo) ii else if (i <= run.hi) 2 * ni + ii else 2 * ni - 1 - ii;
            try e.elevation.append(e.a, elev);
            try e.layout(it.node, frame, tucked or is_tucked, child_clip);
            _ = e.elevation.pop();
            if (!is_tucked) continue;
            // The strip that shows, across every pane in the card. It replaces
            // a tab from a stack nested inside the card: that one is under
            // this card's neighbours now.
            const tab_span = rect.span(d, offset, @min(peek, size));
            for (try leavesOf(e.a, e.nodes, it.node)) |id| {
                const placed = e.result.leaves.getPtr(id) orelse continue;
                const tab = placed.frame.intersect(tab_span);
                placed.tab = if (tab) |t| t.integral() else null;
                placed.tab_axis = if (tab != null) d else null;
                // On either side of the run a tucked card is drawn as its
                // strip alone: nothing of it lies under a card on show, so a
                // glass card never shows one through itself.
                placed.is_sliver = tab != null;
            }
        }
        try e.result.stacks.append(e.a, .{ .frame = rect, .direction = d, .items = item_ids, .run = run, .fits = fits });

        // Grips, on a stack that shows: in the gutters between the cards on
        // show, and in the gutter where the run meets its strips - whether
        // the user collapsed the row or it stacked for want of room, and with
        // room to widen it or not: without, pulling it brings the strip out
        // and the other side gives way (`dragged`). It used to be no grip at
        // all there, a gutter that could not be taken (Mac a81db68f9).
        if (tucked) return;
        const card_mins = try e.a.alloc(f64, n);
        @memset(card_mins, card);
        const shown: Row = .{
            .items = item_ids,
            .run = run,
            .sizes = slots,
            .start = rect.start(d),
            .extent = extent,
            .minimums = card_mins,
            .gap = gap,
            .peek = peek,
        };
        const G = struct {
            rect: Rect,
            d: Direction,
            gap: f64,
            /// The gutter from `from` to `from + gap`, across the stack.
            fn at(self: @This(), from: f64) Rect {
                return self.rect.span(self.d, @round(from), @round(from + self.gap) - @round(from)).integral();
            }
        };
        const gutter: G = .{ .rect = rect, .d = d, .gap = gap };
        for (0..count - 1) |k| {
            try e.result.stack_handles.append(e.a, .{
                .row = shown,
                .direction = d,
                .frame = rect,
                .position = slot.start(k + 1) - gap / 2,
                .kind = .{ .between = k },
                .gutter = gutter.at(slot.start(k + 1) - gap),
            });
        }
        {
            if (run.lo > 0) try e.result.stack_handles.append(e.a, .{
                .row = shown,
                .direction = d,
                .frame = rect,
                .position = run_start - gap / 2,
                .kind = .{ .expand = .leading },
                .gutter = gutter.at(run_start - gap),
            });
            if (run.hi < n - 1) try e.result.stack_handles.append(e.a, .{
                .row = shown,
                .direction = d,
                .frame = rect,
                .position = run_end + gap / 2,
                .kind = .{ .expand = .trailing },
                .gutter = gutter.at(run_end),
            });
        }
    }
};

// ---------------------------------------------------------------------------
// Tests: a port of Mac's PaneLayoutTests (macos/Tests/Splits/PaneLayoutTests
// .swift). Elevated-style numbers: a 10 DIP gap, 36 DIP peeks, 300x200 panes.

const test_metrics: Metrics = .{ .gap = 10, .peek = 36, .minimum_width = 300, .minimum_height = 200 };

/// A tree under construction: leaves are ids 1..n in order.
const TestTree = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,

    fn deinit(t: *TestTree) void {
        t.nodes.deinit(testing.allocator);
    }
    fn leaf(t: *TestTree, id: Id) !u32 {
        try t.nodes.append(testing.allocator, .{ .leaf = id });
        return @intCast(t.nodes.items.len - 1);
    }
    fn split(t: *TestTree, d: Direction, ratio: f64, left: u32, right: u32) !u32 {
        try t.nodes.append(testing.allocator, .{ .split = .{ .direction = d, .ratio = ratio, .left = left, .right = right } });
        return @intCast(t.nodes.items.len - 1);
    }
    /// `1 | 2 | ... | n` along `d`, equal, built the way inserting each pane
    /// after the last one builds it: `a | (b | (c | d))`.
    fn row(t: *TestTree, n: usize, d: Direction) !u32 {
        var right = try t.leaf(@intCast(n));
        var i = n - 1;
        while (i >= 1) : (i -= 1) {
            const l = try t.leaf(@intCast(i));
            const items_right: f64 = @floatFromInt(n - i);
            right = try t.split(d, 1.0 / (1.0 + items_right), l, right);
        }
        return right;
    }
};

/// A provider over a focus list (most recent first), pins and shares keyed by
/// a sorted id list, and a last-shown run.
const TestProvider = struct {
    focus: []const Id = &.{},
    pin_key: []const Id = &.{},
    pin_value: ?Pin = null,
    shares_key: []const Id = &.{},
    shares_value: ?[]const f64 = null,

    fn rank(ctx: ?*const anyopaque, id: Id) ?u32 {
        const self: *const TestProvider = @ptrCast(@alignCast(ctx.?));
        for (self.focus, 0..) |f, i| if (f == id) return @intCast(i);
        return null;
    }
    fn pin(ctx: ?*const anyopaque, key: []const Id) ?Pin {
        const self: *const TestProvider = @ptrCast(@alignCast(ctx.?));
        return if (std.mem.eql(Id, key, self.pin_key)) self.pin_value else null;
    }
    fn shares(ctx: ?*const anyopaque, key: []const Id) ?[]const f64 {
        const self: *const TestProvider = @ptrCast(@alignCast(ctx.?));
        return if (std.mem.eql(Id, key, self.shares_key)) self.shares_value else null;
    }
    fn provider(self: *const TestProvider) Provider {
        return .{ .ctx = self, .rank = rank, .pin = pin, .shares = shares };
    }
};

fn testLayout(t: *const TestTree, root: u32, width: f64, height: f64, p: *const TestProvider) !Result {
    return compute(testing.allocator, t.nodes.items, root, .{ .w = width, .h = height }, test_metrics, p.provider());
}

fn frameOf(r: *const Result, id: Id) Rect {
    return r.leaves.get(id).?.frame;
}

const ids_1_to_3 = [_]Id{ 1, 2, 3 };
const ids_1_to_4 = [_]Id{ 1, 2, 3, 4 };

test "pane_stack_layout: roomy rows follow their ratios" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(4, .horizontal);
    const p: TestProvider = .{};
    var r = try testLayout(&t, root, 1630, 600, &p);
    defer r.deinit();
    const xs = [_]f64{ 0, 410, 820, 1230 };
    for (1..5) |i| {
        try testing.expectEqual(@as(f64, 400), frameOf(&r, i).w);
        try testing.expectEqual(xs[i - 1], frameOf(&r, i).x);
        try testing.expect(!r.leaves.get(i).?.is_tucked);
        try testing.expect(r.leaves.get(i).?.tab == null);
    }
    try testing.expectEqual(@as(usize, 0), r.stacks.items.len);
    try testing.expectEqual(@as(usize, 3), r.dividers.items.len);
}

test "pane_stack_layout: a ratio that would squeeze a pane is overridden, not stored" {
    // a | b with b at 10% of 1000: b would be 99. It gets its 300.
    var t: TestTree = .{};
    defer t.deinit();
    const a = try t.leaf(1);
    const b = try t.leaf(2);
    const root = try t.split(.horizontal, 0.9, a, b);
    const p: TestProvider = .{};
    var r = try testLayout(&t, root, 1010, 600, &p);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 700), frameOf(&r, 1).w);
    try testing.expectEqual(@as(f64, 300), frameOf(&r, 2).w);
    // The displayed ratio is the one on screen, as a share of the sizes (the
    // gutter left out, T2125); the input is untouched.
    try testing.expectApproxEqAbs(700.0 / 1000.0, r.displayed_ratio[root], 0.0001);
    try testing.expectEqual(@as(f64, 0.9), t.nodes.items[root].split.ratio);
    try testing.expectEqual(@as(f64, 705), r.dividers.items[0].position);
}

test "pane_stack_layout: T2125 a tree that adopts its displayed ratios lays out unchanged" {
    // a | (b | c) with uneven ratios, roomy and squeezed: writing the ratios
    // on screen back into the tree must not move a single pane - the divider
    // solver adopts them before every drag tick and every resize key.
    for ([_]f64{ 1400, 1000 }) |w| {
        var t: TestTree = .{};
        defer t.deinit();
        const a = try t.leaf(1);
        const b = try t.leaf(2);
        const c = try t.leaf(3);
        const bc = try t.split(.horizontal, 0.3, b, c);
        const root = try t.split(.horizontal, 0.45, a, bc);
        const p: TestProvider = .{};
        var r1 = try testLayout(&t, root, w, 600, &p);
        defer r1.deinit();
        for ([_]u32{ root, bc }) |n| t.nodes.items[n].split.ratio = r1.displayed_ratio[n];
        var r2 = try testLayout(&t, root, w, 600, &p);
        defer r2.deinit();
        for (1..4) |id| try testing.expectEqual(frameOf(&r1, id), frameOf(&r2, id));
        for ([_]u32{ root, bc }) |n|
            try testing.expectApproxEqAbs(r1.displayed_ratio[n], r2.displayed_ratio[n], 1e-9);
    }
}

test "pane_stack_layout: waterFill pins only what falls short" {
    const s = try waterFill(testing.allocator, &.{ 100, 450, 450 }, &.{ 300, 300, 300 }, 1000);
    defer testing.allocator.free(s);
    try testing.expectEqualSlices(f64, &.{ 300, 350, 350 }, s);
}

test "pane_stack_layout: waterFill keeps proportions among the rest" {
    const s = try waterFill(testing.allocator, &.{ 50, 300, 650 }, &.{ 300, 0, 0 }, 1000);
    defer testing.allocator.free(s);
    try testing.expectEqual(@as(f64, 300), @round(s[0]));
    try testing.expectEqual(@as(f64, 221), @round(s[1]));
    try testing.expectEqual(@as(f64, 479), @round(s[2]));
}

test "pane_stack_layout: a row that can't fit stacks and shows what fits" {
    // 4 x 300 + gaps = 1230 > 760: a stack. Two cards fit side by side with
    // two strips, each with its gutter (2x46 + 2x300 + 10 <= 760); three don't.
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(4, .horizontal);
    const p: TestProvider = .{};
    var r = try testLayout(&t, root, 760, 600, &p);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.stacks.items.len);
    const run = r.stacks.items[0].run;
    // Nothing focused yet: the first cards show.
    try testing.expectEqual(Range{ .lo = 0, .hi = 1 }, run);
    try testing.expectEqual(@as(usize, 0), r.dividers.items.len);
    // Every card is the same width, so moving the run never resizes one.
    for (1..5) |i| try testing.expectEqual((760.0 - 2 * 46 - 10) / 2, frameOf(&r, i).w);
}

test "pane_stack_layout: the focused pane is on show" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(4, .horizontal);
    const p: TestProvider = .{ .focus = &.{4} };
    var r = try testLayout(&t, root, 760, 600, &p);
    defer r.deinit();
    try testing.expectEqual(Range{ .lo = 2, .hi = 3 }, r.stacks.items[0].run);
    try testing.expect(!r.leaves.get(4).?.is_tucked);
    try testing.expect(r.leaves.get(1).?.is_tucked);
}

test "pane_stack_layout: the run grows toward the pane focused more recently" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(4, .horizontal);
    {
        // c focused, b before it: b|c, not c|d.
        const p: TestProvider = .{ .focus = &.{ 3, 2 } };
        var r = try testLayout(&t, root, 760, 600, &p);
        defer r.deinit();
        try testing.expectEqual(Range{ .lo = 1, .hi = 2 }, r.stacks.items[0].run);
    }
    {
        const p: TestProvider = .{ .focus = &.{ 3, 4 } };
        var r = try testLayout(&t, root, 760, 600, &p);
        defer r.deinit();
        try testing.expectEqual(Range{ .lo = 2, .hi = 3 }, r.stacks.items[0].run);
    }
}

test "pane_stack_layout: clicking the leftmost card slides the others right" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(4, .horizontal);
    const pb: TestProvider = .{ .focus = &.{4} };
    var before = try testLayout(&t, root, 600, 600, &pb);
    defer before.deinit();
    const pa: TestProvider = .{ .focus = &.{ 1, 4 } };
    var after = try testLayout(&t, root, 600, 600, &pa);
    defer after.deinit();
    // 600 fits one 300 card plus three strips: a single-card run.
    try testing.expectEqual(Range{ .lo = 3, .hi = 3 }, before.stacks.items[0].run);
    try testing.expectEqual(Range{ .lo = 0, .hi = 0 }, after.stacks.items[0].run);
    const w: f64 = 600 - 3 * 46;
    const xb = [_]f64{ 0, 46, 92, 138 };
    const xa = [_]f64{ 0, w + 10, w + 56, w + 102 };
    for (1..5) |i| {
        try testing.expectEqual(xb[i - 1], frameOf(&before, i).x);
        try testing.expectEqual(xa[i - 1], frameOf(&after, i).x);
        // Nothing changed size.
        try testing.expectEqual(frameOf(&before, i).w, frameOf(&after, i).w);
        try testing.expectEqual(frameOf(&before, i).h, frameOf(&after, i).h);
    }
}

test "pane_stack_layout: cards keep their order wherever the run is" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(5, .horizontal);
    for (1..6) |focused| {
        const p: TestProvider = .{ .focus = &.{focused} };
        var r = try testLayout(&t, root, 900, 600, &p);
        defer r.deinit();
        for (1..5) |i| try testing.expect(frameOf(&r, i).x <= frameOf(&r, i + 1).x);
    }
}

fn drawnRect(l: Leaf) Rect {
    if (l.is_sliver) return l.tab.?;
    if (l.clip) |c| return l.frame.intersect(c) orelse Rect{};
    return l.frame;
}

test "pane_stack_layout: the paint order shows the run and every tab" {
    // Wherever a higher pane overlaps a lower one, the lower one must be
    // tucked — the run is never covered — and every tab must be uncovered.
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(5, .horizontal);
    for ([_]f64{ 420, 600, 900, 1200 }) |width| {
        for (1..6) |focused| {
            const p: TestProvider = .{ .focus = &.{focused} };
            var r = try testLayout(&t, root, width, 600, &p);
            defer r.deinit();
            var order = [_]Id{ 1, 2, 3, 4, 5 };
            paintOrder(&order, &r);
            for (order, 0..) |lo_id, i| for (order[i + 1 ..]) |hi_id| {
                const lower = r.leaves.get(lo_id).?;
                const upper = drawnRect(r.leaves.get(hi_id).?);
                if (drawnRect(lower).intersect(upper) == null) continue;
                try testing.expect(lower.is_tucked);
                if (lower.tab) |tab| try testing.expect(tab.intersect(upper) == null);
            };
        }
    }
}

test "pane_stack_layout: no card is drawn over another" {
    // A tucked card, on either side of the run, is drawn as its strip alone —
    // so no card, a translucent glass one above all, ever has another under it.
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(5, .horizontal);
    for ([_]f64{ 420, 600, 900, 1200, 1400 }) |width| {
        for (1..6) |focused| {
            const p: TestProvider = .{ .focus = &.{focused} };
            var r = try testLayout(&t, root, width, 600, &p);
            defer r.deinit();
            var drawn: [5]Rect = undefined;
            for (1..6) |id| {
                const l = r.leaves.get(id).?;
                if (l.is_tucked) try testing.expect(l.is_sliver);
                drawn[id - 1] = drawnRect(l);
            }
            for (0..5) |i| for (i + 1..5) |j| try testing.expect(drawn[i].intersect(drawn[j]) == null);
        }
    }
}

test "pane_stack_layout: cards sit lower the farther they are from the run" {
    // a b [c] d e: the run on top, falling away to either side.
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(5, .horizontal);
    const p: TestProvider = .{ .focus = &.{3} };
    var r = try testLayout(&t, root, 600, 600, &p);
    defer r.deinit();
    try testing.expectEqual(Range{ .lo = 2, .hi = 2 }, r.stacks.items[0].run);
    var order = [_]Id{ 1, 2, 3, 4, 5 };
    paintOrder(&order, &r);
    try testing.expectEqualSlices(Id, &.{ 1, 2, 5, 4, 3 }, &order);
    try testing.expect(r.leaves.get(4).?.is_sliver);
    try testing.expect(r.leaves.get(2).?.is_sliver);
    try testing.expect(!r.leaves.get(3).?.is_sliver);
}

test "pane_stack_layout: tabs are the visible strips" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(4, .horizontal);
    const p: TestProvider = .{ .focus = &.{2} };
    var r = try testLayout(&t, root, 600, 600, &p);
    defer r.deinit();
    const w: f64 = 600 - 3 * 46;
    try testing.expect(r.leaves.get(2).?.tab == null);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 36, .h = 600 }, r.leaves.get(1).?.tab.?);
    try testing.expectEqual(Rect{ .x = 46 + w + 10, .y = 0, .w = 36, .h = 600 }, r.leaves.get(3).?.tab.?);
    try testing.expectEqual(Rect{ .x = 46 + w + 56, .y = 0, .w = 36, .h = 600 }, r.leaves.get(4).?.tab.?);
    try testing.expectEqual(Direction.horizontal, r.leaves.get(4).?.tab_axis.?);
}

test "pane_stack_layout: cards past the run are clipped to the stack" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(4, .horizontal);
    const p: TestProvider = .{ .focus = &.{1} };
    var r = try testLayout(&t, root, 600, 600, &p);
    defer r.deinit();
    const w: f64 = 600 - 3 * 46;
    const d = r.leaves.get(4).?;
    try testing.expect(d.frame.maxX() > 600);
    const clip = d.clip.?;
    try testing.expectEqual(@as(f64, 600), clip.maxX());
    try testing.expect(clip.x < d.frame.x and clip.y < 0 and clip.maxY() > 600);
    try testing.expectEqual(Rect{ .x = w + 102, .y = 0, .w = 600 - (w + 102), .h = 600 }, d.frame.intersect(clip).?);
    try testing.expect(r.leaves.get(1).?.clip == null);
}

test "pane_stack_layout: a too-narrow stack shrinks its strips before its cards" {
    // 300 + 3 x (36 + 10) = 438 > 380: strips shrink to whole DIPs of
    // (380 - 300) / 3 less their gutter, and the card keeps the rest.
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(4, .horizontal);
    const p: TestProvider = .{ .focus = &.{1} };
    var r = try testLayout(&t, root, 380, 600, &p);
    defer r.deinit();
    try testing.expectEqual(@as(f64, 16), r.leaves.get(2).?.tab.?.w);
    try testing.expectEqual(@as(f64, 380 - 3 * (16 + 10)), frameOf(&r, 1).w);
}

test "pane_stack_layout: columns stack too" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(3, .vertical);
    const p: TestProvider = .{ .focus = &.{3} };
    var r = try testLayout(&t, root, 800, 400, &p);
    defer r.deinit();
    const stack = r.stacks.items[0];
    try testing.expectEqual(Direction.vertical, stack.direction);
    try testing.expectEqual(Range{ .lo = 2, .hi = 2 }, stack.run);
    try testing.expectEqual(Direction.vertical, r.leaves.get(1).?.tab_axis.?);
    try testing.expectEqual(@as(f64, 36), r.leaves.get(1).?.tab.?.h);
    try testing.expectEqual(@as(f64, 400 - 2 * 46), frameOf(&r, 3).h);
}

/// a | (b / (c | d)), ids 1..4.
fn nestedRowInColumn(t: *TestTree) !u32 {
    const c = try t.leaf(3);
    const d = try t.leaf(4);
    const inner = try t.split(.horizontal, 0.5, c, d);
    const b = try t.leaf(2);
    const column = try t.split(.vertical, 0.5, b, inner);
    const a = try t.leaf(1);
    return t.split(.horizontal, 0.5, a, column);
}

test "pane_stack_layout: an inner row stacks before the outer one" {
    // a | (b / (c | d)): at 800 the outer row can't hold a, c and d side by
    // side, but it can hold a beside a STACKED c|d.
    var t: TestTree = .{};
    defer t.deinit();
    const root = try nestedRowInColumn(&t);
    const p: TestProvider = .{ .focus = &.{4} };
    var r = try testLayout(&t, root, 800, 800, &p);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.stacks.items.len);
    const items = r.stacks.items[0].items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualSlices(Id, &.{3}, items[0]);
    try testing.expectEqualSlices(Id, &.{4}, items[1]);
    try testing.expect(!r.leaves.get(1).?.is_tucked);
    try testing.expect(!r.leaves.get(2).?.is_tucked);
    try testing.expect(r.leaves.get(3).?.is_tucked);
    try testing.expect(!r.leaves.get(4).?.is_tucked);
}

test "pane_stack_layout: a stacked card can hold a whole column" {
    // (a / b) | c | d in 700: a stack of three, whose first card is a column.
    var t: TestTree = .{};
    defer t.deinit();
    const a = try t.leaf(1);
    const b = try t.leaf(2);
    const column = try t.split(.vertical, 0.5, a, b);
    const c = try t.leaf(3);
    const d = try t.leaf(4);
    const cd = try t.split(.horizontal, 0.5, c, d);
    const root = try t.split(.horizontal, 1.0 / 3.0, column, cd);
    const p: TestProvider = .{ .focus = &.{4} };
    var r = try testLayout(&t, root, 700, 600, &p);
    defer r.deinit();
    const la = r.leaves.get(1).?;
    const lb = r.leaves.get(2).?;
    try testing.expect(la.is_tucked and lb.is_tucked);
    try testing.expectEqual(la.frame.h, la.tab.?.h);
    try testing.expectEqual(lb.frame.y, lb.tab.?.y);
    // The column's own divider is under the card in front of it.
    try testing.expectEqual(@as(usize, 0), r.dividers.items.len);
}

test "pane_stack_layout: visibleRun prefers the trailing side on a tie and stops at the ends" {
    try testing.expectEqual(Range{ .lo = 0, .hi = 1 }, visibleRun(&.{ null, null, null, null }, 2));
    try testing.expectEqual(Range{ .lo = 1, .hi = 2 }, visibleRun(&.{ null, 0, null, null }, 2));
    try testing.expectEqual(Range{ .lo = 1, .hi = 3 }, visibleRun(&.{ null, null, null, 0 }, 3));
    try testing.expectEqual(Range{ .lo = 0, .hi = 2 }, visibleRun(&.{ 0, null, null }, 5));
}

test "pane_stack_layout: stickyRun keeps a run that shows the focused pane, and slides the least" {
    // Focusing a pane already on show never moves anything.
    try testing.expectEqual(Range{ .lo = 1, .hi = 2 }, stickyRun(.{ .lo = 1, .hi = 2 }, &.{ null, null, 0, null }, 2));
    // A strip brought forward slides the run only as far as it takes.
    try testing.expectEqual(Range{ .lo = 2, .hi = 3 }, stickyRun(.{ .lo = 1, .hi = 2 }, &.{ null, null, null, 0 }, 2));
    try testing.expectEqual(Range{ .lo = 0, .hi = 1 }, stickyRun(.{ .lo = 1, .hi = 2 }, &.{ 0, null, null, null }, 2));
    // A run of another size (the window changed): visibleRun.
    try testing.expectEqual(Range{ .lo = 3, .hi = 3 }, stickyRun(.{ .lo = 1, .hi = 2 }, &.{ null, null, null, 0 }, 1));
    // Nobody focused: the run before stays.
    try testing.expectEqual(Range{ .lo = 2, .hi = 3 }, stickyRun(.{ .lo = 2, .hi = 3 }, &.{ null, null, null, null }, 2));
}

test "pane_stack_layout: the divider clamp falls back to stacked minimums when needed" {
    // b | c needs 600 side by side; stacked it needs 300 + 36 (no gaps here).
    var t: TestTree = .{};
    defer t.deinit();
    const b = try t.leaf(2);
    const c = try t.leaf(3);
    const bc = try t.split(.horizontal, 0.5, b, c);
    try testing.expectEqual(@as(f64, 600), try minimumExtent(testing.allocator, t.nodes.items, bc, .horizontal, 300, 200, false));
    try testing.expectEqual(@as(f64, 336), try minimumExtent(testing.allocator, t.nodes.items, bc, .horizontal, 300, 200, true));
    try testing.expectEqual(@as(f64, 200), try minimumExtent(testing.allocator, t.nodes.items, bc, .vertical, 300, 200, true));
}

test "pane_stack_layout: a collapsed row tucks a pane even with room to spare" {
    // a | b | c fits side by side at 1200; the user tucked c away.
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(3, .horizontal);
    const p: TestProvider = .{ .pin_key = &ids_1_to_3, .pin_value = .{ .start = 0, .count = 2 } };
    var r = try testLayout(&t, root, 1200, 600, &p);
    defer r.deinit();
    try testing.expectEqual(Range{ .lo = 0, .hi = 1 }, r.stacks.items[0].run);
    try testing.expect(r.leaves.get(3).?.is_tucked);
    try testing.expectEqual(@as(f64, 1200), r.leaves.get(3).?.tab.?.maxX());
    const w: f64 = @floor((1200.0 - 46 - 10) / 2);
    try testing.expectEqual(w, frameOf(&r, 1).w);
    try testing.expectEqual(w, frameOf(&r, 2).w);
}

test "pane_stack_layout: dividers know their row" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(3, .horizontal);
    const p: TestProvider = .{};
    var r = try testLayout(&t, root, 1200, 600, &p);
    defer r.deinit();
    var seen = [_]bool{ false, false, false };
    for (r.dividers.items) |d| {
        seen[d.index] = true;
        try testing.expectEqual(Range{ .lo = 0, .hi = 2 }, d.row.run);
        const key = try d.row.key(testing.allocator);
        defer testing.allocator.free(key);
        try testing.expectEqualSlices(Id, &ids_1_to_3, key);
    }
    try testing.expect(!seen[0] and seen[1] and seen[2]);
}

test "pane_stack_layout: squeezing a pane tucks the outermost on that side" {
    try testing.expect(Pin.eql(.{ .start = 0, .count = 2 }, Pin.restacking(.{ .lo = 0, .hi = 2 }, 3, .{ .collapse = .trailing })));
    try testing.expect(Pin.eql(.{ .start = 1, .count = 2 }, Pin.restacking(.{ .lo = 0, .hi = 2 }, 3, .{ .collapse = .leading })));
    // Down to one card on show, never none.
    try testing.expect(Pin.eql(.{ .start = 1, .count = 1 }, Pin.restacking(.{ .lo = 1, .hi = 1 }, 3, .{ .collapse = .leading })));
}

test "pane_stack_layout: widened all the way a row is side by side again" {
    try testing.expect(Pin.eql(null, Pin.restacking(.{ .lo = 0, .hi = 1 }, 3, .{ .expand = .trailing })));
    try testing.expect(Pin.eql(.{ .start = 0, .count = 2 }, Pin.restacking(.{ .lo = 1, .hi = 1 }, 4, .{ .expand = .leading })));
}

test "pane_stack_layout: clicking a minimized pane restores just that one" {
    const pin: Pin = .{ .start = 0, .count = 2 };
    try testing.expect(Pin.eql(.{ .start = 0, .count = 3 }, pin.restoring(2, 3, 4)));
    // A pane on show changes nothing.
    try testing.expect(Pin.eql(pin, pin.restoring(1, 3, 4)));
    // Room for everything: the row is side by side again.
    try testing.expect(Pin.eql(null, (Pin{ .start = 0, .count = 1 }).restoring(1, 2, 2)));
}

test "pane_stack_layout: without room the far edge minimizes instead" {
    try testing.expect(Pin.eql(.{ .start = 1, .count = 2 }, (Pin{ .start = 0, .count = 2 }).restoring(2, 2, 4)));
    try testing.expect(Pin.eql(.{ .start = 0, .count = 2 }, (Pin{ .start = 1, .count = 2 }).restoring(0, 2, 4)));
    try testing.expect(Pin.eql(.{ .start = 1, .count = 3 }, (Pin{ .start = 0, .count = 2 }).restoring(3, 3, 4)));
}

test "pane_stack_layout: a pane leaving the run closes up over its slot" {
    const gpa = testing.allocator;
    // a b [c d] e f: c closes. d takes the run alone, between the same strips.
    const pin: Pin = .{ .start = 2, .count = 2 };
    try testing.expect(Pin.eql(.{ .start = 2, .count = 1 }, try pin.removing(gpa, &.{2}, 6)));
    try testing.expect(Pin.eql(.{ .start = 2, .count = 1 }, try pin.removing(gpa, &.{3}, 6)));
    // A strip closes: the run keeps its panes, shifted when it was before them.
    try testing.expect(Pin.eql(.{ .start = 1, .count = 2 }, try pin.removing(gpa, &.{0}, 6)));
    try testing.expect(Pin.eql(.{ .start = 2, .count = 2 }, try pin.removing(gpa, &.{5}, 6)));
    // Everything left fits in the run: side by side again.
    try testing.expect(Pin.eql(null, try (Pin{ .start = 0, .count = 2 }).removing(gpa, &.{2}, 3)));
    // A row of one is no row.
    try testing.expect(Pin.eql(null, try (Pin{ .start = 0, .count = 1 }).removing(gpa, &.{1}, 2)));
}

test "pane_stack_layout: the only pane on show closing brings out its neighbour before" {
    const gpa = testing.allocator;
    try testing.expect(Pin.eql(.{ .start = 1, .count = 1 }, try (Pin{ .start = 2, .count = 1 }).removing(gpa, &.{2}, 5)));
    // Nothing before it: the one after.
    try testing.expect(Pin.eql(.{ .start = 0, .count = 1 }, try (Pin{ .start = 0, .count = 1 }).removing(gpa, &.{0}, 4)));
}

test "pane_stack_layout: a pane joining beside the run comes on show" {
    const gpa = testing.allocator;
    const pin: Pin = .{ .start = 2, .count = 1 };
    try testing.expect(Pin.eql(.{ .start = 2, .count = 2 }, try pin.adding(gpa, &.{3}, 6)));
    try testing.expect(Pin.eql(.{ .start = 2, .count = 2 }, try pin.adding(gpa, &.{2}, 6)));
    // Among the strips, it is one of them.
    try testing.expect(Pin.eql(.{ .start = 3, .count = 1 }, try pin.adding(gpa, &.{0}, 6)));
    try testing.expect(Pin.eql(.{ .start = 2, .count = 1 }, try pin.adding(gpa, &.{5}, 6)));
    // Inside a run of two: between them.
    try testing.expect(Pin.eql(.{ .start = 1, .count = 3 }, try (Pin{ .start = 1, .count = 2 }).adding(gpa, &.{2}, 5)));
}

test "pane_stack_layout: rows list every chain outermost first" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try nestedRowInColumn(&t);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try rows(arena.allocator(), t.nodes.items, root);
    try testing.expectEqual(@as(usize, 3), got.len);
    // [[a], [b, c, d]], [[b], [c, d]], [[c], [d]]
    try testing.expectEqualSlices(Id, &.{1}, got[0][0]);
    try testing.expectEqualSlices(Id, &.{ 2, 3, 4 }, got[0][1]);
    try testing.expectEqualSlices(Id, &.{2}, got[1][0]);
    try testing.expectEqualSlices(Id, &.{ 3, 4 }, got[1][1]);
    try testing.expectEqualSlices(Id, &.{3}, got[2][0]);
    try testing.expectEqualSlices(Id, &.{4}, got[2][1]);
    const single = [_]Node{.{ .leaf = 1 }};
    try testing.expectEqual(@as(usize, 0), (try rows(arena.allocator(), &single, 0)).len);
}

test "pane_stack_layout: a stack knows how many cards fit" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(4, .horizontal);
    {
        const p: TestProvider = .{ .pin_key = &ids_1_to_4, .pin_value = .{ .start = 0, .count = 2 } };
        var r = try testLayout(&t, root, 1400, 600, &p);
        defer r.deinit();
        try testing.expectEqual(@as(usize, 4), r.stacks.items[0].fits);
    }
    {
        const p: TestProvider = .{};
        var r = try testLayout(&t, root, 760, 600, &p);
        defer r.deinit();
        try testing.expectEqual(@as(usize, 2), r.stacks.items[0].fits);
    }
}

fn hasKind(r: *const Result, kind: StackHandle.Kind) bool {
    for (r.stack_handles.items) |h| if (std.meta.eql(h.kind, kind)) return true;
    return false;
}

test "pane_stack_layout: grips sit between cards and at every edge of the run" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(3, .horizontal);
    const p: TestProvider = .{ .pin_key = &ids_1_to_3, .pin_value = .{ .start = 0, .count = 2 } };
    {
        var r = try testLayout(&t, root, 1200, 600, &p);
        defer r.deinit();
        try testing.expect(hasKind(&r, .{ .between = 0 }));
        try testing.expect(hasKind(&r, .{ .expand = .trailing }));
        try testing.expect(!hasKind(&r, .{ .expand = .leading }));
    }
    {
        // Too narrow for a third card: the edge is a grip all the same
        // (pulling it brings the strip out, the other side giving way), and
        // so it is on a row that stacked for want of room, collapsed by
        // nobody (Mac a81db68f9).
        var r = try testLayout(&t, root, 700, 600, &p);
        defer r.deinit();
        try testing.expect(hasKind(&r, .{ .expand = .trailing }));
        const unpinned: TestProvider = .{};
        var u = try testLayout(&t, root, 700, 600, &unpinned);
        defer u.deinit();
        try testing.expect(hasKind(&u, .{ .expand = .trailing }) or hasKind(&u, .{ .expand = .leading }));
    }
}

test "pane_stack_layout: the run's slots are the user's to size" {
    // a b on show at 30/70, c tucked: c is the size of the slot it would come
    // forward into (the last), and nothing is under its minimum.
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(3, .horizontal);
    const p: TestProvider = .{
        .pin_key = &ids_1_to_3,
        .pin_value = .{ .start = 0, .count = 2 },
        .shares_key = &ids_1_to_3,
        .shares_value = &.{ 0.3, 0.7 },
    };
    var r = try testLayout(&t, root, 1200, 600, &p);
    defer r.deinit();
    const run: f64 = 1200 - 46 - 10;
    const w0 = frameOf(&r, 1).w;
    const w1 = frameOf(&r, 2).w;
    try testing.expectEqual(@floor(run * 0.3), w0);
    try testing.expectEqual(run, w0 + w1);
    try testing.expectEqual(w1, frameOf(&r, 3).w);
    for (r.stack_handles.items) |h| if (std.meta.eql(h.kind, StackHandle.Kind{ .between = 0 })) {
        try testing.expectEqualSlices(f64, &.{ w0, w1 }, h.row.sizes);
    };
}

/// a | b | c side by side in 1220 (three 400 panes, 10 gutters).
const three_items = [_][]const Id{ &.{1}, &.{2}, &.{3} };
const three_across: Row = .{
    .items = &three_items,
    .run = .{ .lo = 0, .hi = 2 },
    .sizes = &.{ 400, 400, 400 },
    .start = 0,
    .extent = 1220,
    .minimums = &.{ 300, 300, 300 },
    .gap = 10,
    .peek = 36,
};
const all_400 = [_]?f64{ 400, 400, 400 };

fn expectDragged(want_lo: usize, want_hi: usize, want: []const f64, got: Dragged) !void {
    defer testing.allocator.free(got.sizes);
    try testing.expectEqual(want_lo, got.run.lo);
    try testing.expectEqual(want_hi, got.run.hi);
    try testing.expectEqual(want.len, got.sizes.len);
    for (want, got.sizes) |w, g| try testing.expectApproxEqAbs(w, g, 1e-9);
}

test "pane_stack_layout: a gutter dragged resizes the two beside it first" {
    // The gutter between a and b (at 405) to 455: a grows by 50, b gives it
    // up, c keeps its size.
    try expectDragged(0, 2, &.{ 450, 350, 400 }, try dragged(testing.allocator, three_across, 1, 455, &all_400));
}

test "pane_stack_layout: a gutter dragged on tucks panes away one after another" {
    const gpa = testing.allocator;
    // b gives way first; past its minimum c gives way to its own, then -
    // there being no room for both at their minimums - c tucks away (a strip
    // of 36 and its gutter at the end), then b.
    try expectDragged(0, 2, &.{ 495, 305, 400 }, try dragged(gpa, three_across, 1, 500, &all_400));
    try expectDragged(0, 1, &.{ 695, 1220 - 700 - 5 - 46 }, try dragged(gpa, three_across, 1, 700, &all_400));
    // b still fits, at 415 with c's strip.
    const two = try dragged(gpa, three_across, 1, 800, &all_400);
    defer gpa.free(two.sizes);
    try testing.expectEqual(@as(usize, 1), two.run.hi);
    // At the edge b too: its side is all strips, a has the rest.
    try expectDragged(0, 0, &.{1220 - 82 - 10}, try dragged(gpa, three_across, 1, 1210, &all_400));
    // The row never empties: a cannot tuck from this gutter too.
    const zero = try dragged(gpa, three_across, 1, 0, &all_400);
    defer gpa.free(zero.sizes);
    try testing.expect(zero.run.count() >= 1);
}

const four_items = [_][]const Id{ &.{1}, &.{2}, &.{3}, &.{4} };

test "pane_stack_layout: a gutter dragged never brings strips out on its other side" {
    const gpa = testing.allocator;
    // a b on show, c d strips: the gutter between a and b dragged left tucks
    // a away and grows b; c and d stay strips however far it goes.
    const row: Row = .{
        .items = &four_items,
        .run = .{ .lo = 0, .hi = 1 },
        .sizes = &.{ 554, 554 },
        .extent = 1210,
        .minimums = &.{ 300, 300, 300, 300 },
        .gap = 10,
        .peek = 36,
    };
    const sizes = [_]?f64{ 554, 554, null, null };
    const same = try dragged(gpa, row, 1, 559, &sizes);
    defer gpa.free(same.sizes);
    try testing.expectEqual(Range{ .lo = 0, .hi = 1 }, same.run);
    const left = try dragged(gpa, row, 1, 305, &sizes);
    defer gpa.free(left.sizes);
    try testing.expectEqual(Range{ .lo = 0, .hi = 1 }, left.run);
    try testing.expect(left.sizes[1] > 554);
    const edge = try dragged(gpa, row, 1, 0, &sizes);
    defer gpa.free(edge.sizes);
    try testing.expectEqual(Range{ .lo = 1, .hi = 1 }, edge.run);
}

test "pane_stack_layout: a strip pulled out brings out its pane alone" {
    const gpa = testing.allocator;
    // s0 s1 strips, a b on show: the grip between s1 and a pulled far right
    // brings out s1 alone - s0 behind it stays a strip - and the panes on the
    // other side tuck away to make room.
    const row: Row = .{
        .items = &four_items,
        .run = .{ .lo = 2, .hi = 3 },
        .sizes = &.{ 554, 554 },
        .extent = 1210,
        .minimums = &.{ 300, 300, 300, 300 },
        .gap = 10,
        .peek = 36,
    };
    const sizes = [_]?f64{ null, null, 554, 554 };
    const pulled = try dragged(gpa, row, 2, 700, &sizes);
    defer gpa.free(pulled.sizes);
    try testing.expectEqual(Range{ .lo = 1, .hi = 2 }, pulled.run);
    try testing.expectApproxEqAbs(@as(f64, 700 - 5 - 46), pulled.sizes[0], 0.001);
    const far = try dragged(gpa, row, 2, 1200, &sizes);
    defer gpa.free(far.sizes);
    try testing.expectEqual(Range{ .lo = 1, .hi = 1 }, far.run);
}

test "pane_stack_layout: T2284 a pane snapped a fraction under its minimum stays on show at its own grip" {
    const gpa = testing.allocator;
    // s0 [b] s2 at 150%: 54 px strips, 15 px gutters, a 337.5 px minimum, and
    // b laid out at 337 - whole pixels. The grip where the run meets s2, at
    // its press, is the row as the drag found it; a step either way still
    // moves it.
    const row: Row = .{
        .items = &three_items,
        .run = .{ .lo = 1, .hi = 1 },
        .sizes = &.{337},
        .extent = 475.5,
        .minimums = &.{ 337.5, 337.5, 337.5 },
        .gap = 15,
        .peek = 54,
    };
    const sizes = [_]?f64{ null, 337, null };
    // The run holds; b takes back the half pixel the snap left.
    try expectDragged(1, 1, &.{337.5}, try dragged(gpa, row, 2, 413.5, &sizes));
    const back = try dragged(gpa, row, 2, 0, &sizes);
    defer gpa.free(back.sizes);
    try testing.expectEqual(Range{ .lo = 2, .hi = 2 }, back.run);
}

test "pane_stack_layout: a gutter dragged back puts the row back exactly" {
    const gpa = testing.allocator;
    const there = try dragged(gpa, three_across, 1, 1000, &all_400);
    defer gpa.free(there.sizes);
    try testing.expect(there.run.count() != 3);
    try expectDragged(0, 2, &.{ 400, 400, 400 }, try dragged(gpa, three_across, 1, 405, &all_400));
}

test "pane_stack_layout: settingRow sizes every split of the row, and finds it nested" {
    const gpa = testing.allocator;
    // A column over a row a | (b | c): the row's two splits are 2 and 4.
    const nodes = [_]Node{
        .{ .split = .{ .direction = .vertical, .ratio = 0.5, .left = 1, .right = 2 } },
        .{ .leaf = 9 },
        .{ .split = .{ .direction = .horizontal, .ratio = 0.5, .left = 3, .right = 4 } },
        .{ .leaf = 1 },
        .{ .split = .{ .direction = .horizontal, .ratio = 0.5, .left = 5, .right = 6 } },
        .{ .leaf = 2 },
        .{ .leaf = 3 },
    };
    const set = (try settingRow(gpa, &nodes, 0, .horizontal, &three_items, &.{ 450, 350, 400 })) orelse
        return error.TestExpectedRow;
    defer gpa.free(set);
    try testing.expectEqual(@as(usize, 2), set.len);
    try testing.expectEqual(@as(u32, 2), set[0].node);
    try testing.expectApproxEqAbs(@as(f64, 450.0 / 1200.0), set[0].ratio, 1e-9);
    try testing.expectEqual(@as(u32, 4), set[1].node);
    try testing.expectApproxEqAbs(@as(f64, 350.0 / 750.0), set[1].ratio, 1e-9);
    // Null shares: the ratios as they are.
    const now = (try settingRow(gpa, &nodes, 0, .horizontal, &three_items, null)) orelse
        return error.TestExpectedRow;
    defer gpa.free(now);
    try testing.expectApproxEqAbs(@as(f64, 0.5), now[0].ratio, 1e-9);
    // No such row: null.
    try testing.expect((try settingRow(gpa, &nodes, 0, .vertical, &three_items, null)) == null);
}

test "pane_stack_layout: a window too small for the collapsed run shows its focused part" {
    var t: TestTree = .{};
    defer t.deinit();
    const root = try t.row(4, .horizontal);
    const p: TestProvider = .{ .focus = &.{3}, .pin_key = &ids_1_to_4, .pin_value = .{ .start = 1, .count = 2 } };
    var r = try testLayout(&t, root, 500, 600, &p);
    defer r.deinit();
    try testing.expectEqual(Range{ .lo = 2, .hi = 2 }, r.stacks.items[0].run);
}
