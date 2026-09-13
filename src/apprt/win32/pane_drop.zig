//! Pure drop resolution for rearrange-mode pane drags (T1528). No OS imports,
//! so these unit tests run in every app-runtime lane (the split_geometry.zig
//! pattern).
//!
//! Mac parity: this is `macos/Sources/Features/Splits/PaneDropResolver.swift`
//! (b18ee2d77), ported behavior-for-behavior. A screen point plus a SET of
//! candidate windows goes in, and the drop that point currently means comes
//! out as a VALUE — producing one touches nothing, which is what lets the same
//! answer drive both the live drop highlight (T1531) and the commit.
//!
//! Taking a set of windows rather than one is deliberate and is what makes
//! cross-tab and cross-window dragging (T1532) one code path instead of a
//! second one bolted on later: a resolver that knew about a single window
//! would have to be rewritten to learn about two. Applying a resolved target
//! is the tree-rearrange half's job (T1529).
//!
//! **Coordinate space is the one deliberate divergence from the Swift.**
//! AppKit screen coordinates grow UPWARD, so Mac's "nearer the top" is a
//! LARGER y and its pane rects are y-up; win32 screen coordinates grow
//! DOWNWARD, so every up/down comparison inverts here. Rects follow the win32
//! `RECT` convention — `left`/`top` inclusive, `right`/`bottom` exclusive.
//!
//! Distances are in PHYSICAL PIXELS, so the constants Mac states in points
//! are scaled through `Metrics.forScale` rather than baked, the same way
//! `split_geometry.bandPx` does it.

const std = @import("std");
const testing = std.testing;
const pane_id = @import("pane_id.zig");

/// A point in screen coordinates, physical pixels, y growing downward.
pub const Point = struct {
    x: i32,
    y: i32,
};

/// A screen rectangle in win32 `RECT` terms: `right`/`bottom` are exclusive.
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.left and p.x < self.right and
            p.y >= self.top and p.y < self.bottom;
    }
};

/// Which side of a pane (or of the window) the dragged pane lands on.
///
/// Spelled the way `apprt.action.SplitDirection` and Mac's
/// `SplitTree.NewDirection` are, so the drag half can hand a resolved side
/// straight to the tree mutation without a translation table.
pub const Side = enum {
    left,
    right,
    up,
    down,
};

/// Names the window a drop lands in without holding one.
///
/// The resolver is pure, so it must not hold an `HWND` or a `Window` — the
/// caller passes `@intFromPtr(hwnd)` and maps the answer back itself, and a
/// test fabricates window identities out of small integers.
pub const WindowRef = u64;

/// What a pane drag would do if the button were released right now.
pub const Target = union(enum) {
    /// Split `pane` on `side`, putting the dragged pane there.
    split: struct { window: WindowRef, pane: []const u8, side: Side },

    /// Exchange the dragged pane and `pane` in place.
    swap: struct { window: WindowRef, pane: []const u8 },

    /// Insert at the TOP level of the window's tree, on `side`, so the
    /// dragged pane spans the full width or height of the window.
    top_level: struct { window: WindowRef, side: Side },

    /// Move the pane into a new tab of its own, at `index` in the tab strip.
    new_tab: struct { window: WindowRef, index: usize },

    /// Move the pane into a new window at this screen point. This is what
    /// "released over nothing" means.
    new_window: Point,

    /// The window this target lands in, or null for a brand new one.
    pub fn window(self: Target) ?WindowRef {
        return switch (self) {
            .split => |s| s.window,
            .swap => |s| s.window,
            .top_level => |s| s.window,
            .new_tab => |s| s.window,
            .new_window => null,
        };
    }
};

/// One leaf pane's screen rectangle, keyed by its `$GHOZTTY_PANE_ID`.
pub const PaneRect = struct {
    id: []const u8,
    rect: Rect,
};

/// Everything the resolver needs to know about ONE candidate window.
///
/// All rects are in SCREEN coordinates, because that is the only space a
/// cross-window drag has in common — two windows share no client space.
pub const Candidate = struct {
    window: WindowRef,

    /// Front-to-back ordering, 0 = frontmost. Decides which window owns a
    /// point that two overlapping windows both contain.
    z_order: u32,

    /// The split-tree area: the window's client rect minus the chrome.
    content_rect: Rect,

    /// The WHOLE window, chrome and borders included (T1538).
    ///
    /// Only used to decide which window OWNS an overlapped point — no drop is
    /// ever resolved against it. Without it a point on a window's caption
    /// belongs to no window, which reads as "over nothing" and makes a NEW
    /// window out of a release on a title bar; with two windows it would also
    /// hand the point to whatever window happens to lie behind.
    ///
    /// Optional because a caller that has only measured the split area is
    /// still answerable — it just cannot claim its own chrome.
    frame_rect: ?Rect = null,

    /// Every leaf pane's frame.
    pane_rects: []const PaneRect,

    /// The tab strip, when this window is showing one.
    tab_bar_rect: ?Rect = null,

    /// Tab buttons in visual order, left to right.
    tab_button_rects: []const Rect = &.{},
};

/// The pixel distances the resolution rules are stated in.
///
/// Mac names these in points against a fixed 1pt-per-unit space; a win32
/// window can be on a 100%, 125%, 150% or 200% monitor, so a baked pixel
/// count would make the swap target a third of a pane on one monitor and a
/// twentieth of it on another.
pub const Metrics = struct {
    /// How far inside the window's content edge the top-level insert band
    /// reaches. Mac: 28pt.
    edge_band: i32,

    /// Floor on the swap rectangle's width and height, so a narrow pane still
    /// has a hittable center. Mac: 44pt.
    swap_minimum: i32,

    /// The swap rectangle is this fraction of each of the pane's dimensions
    /// before the floor and the cap apply.
    pub const swap_fraction: f32 = 0.34;

    /// ...and never more than this fraction of them, so a small pane does not
    /// become mostly swap. The cap is applied AFTER the floor and therefore
    /// wins on a pane too small for both, which is Mac's order.
    pub const swap_maximum_fraction: f32 = 0.60;

    /// Below `edge_band * this` on either axis the edge band is suppressed
    /// entirely. A band on all four sides of a tiny window would tile the
    /// whole thing, leaving no way to reach a pane's own zones — the band is
    /// a refinement of pane targeting, so it must never eat all of it.
    pub const minimum_window_bands: i32 = 4;

    pub fn forScale(scale: f32) Metrics {
        return .{
            .edge_band = scaled(28, scale),
            .swap_minimum = scaled(44, scale),
        };
    }

    /// The smallest content rect on which the edge band still applies.
    pub fn minimumWindowForEdgeBand(self: Metrics) i32 {
        return self.edge_band * minimum_window_bands;
    }
};

fn scaled(points: i32, scale: f32) i32 {
    const v: f32 = @round(@as(f32, @floatFromInt(points)) * scale);
    return @max(@as(i32, @intFromFloat(v)), 1);
}

/// Where a point falls within a single pane.
pub const PaneZone = union(enum) {
    edge: Side,
    center,
};

/// The drop `point` currently means, or null for "nothing would happen" —
/// over a window of ours but not over any target (a divider), or over the
/// dragged pane itself.
///
/// `dragged` is the pane being moved, compared case-insensitively the way
/// every other pane-id comparison in this apprt is.
pub fn resolve(
    point: Point,
    candidates: []const Candidate,
    dragged: []const u8,
    metrics: Metrics,
) ?Target {
    // ONE window owns the point: the frontmost of ours that covers it at all,
    // strip or content. Everything below is then answered against that window
    // alone.
    //
    // The strip used to be searched across the whole candidate SET before the
    // content was looked at, which is invisible with one window and wrong with
    // two (T1538): a point over the front window's panes is also, quite often,
    // a point over the tab strip of a window sitting BEHIND it, and the drop
    // would open a tab in the window the user could not even see.
    const candidate = frontmost(candidates, point, windowHit) orelse {
        // Over no window of ours at all.
        return .{ .new_window = point };
    };

    // The tab strip sits outside the content rect and outranks it: it is
    // chrome, and a point on it is never also a point on a pane.
    if (tabBarContains(candidate, point)) {
        return .{ .new_tab = .{
            .window = candidate.window,
            .index = tabIndexAt(candidate, point),
        } };
    }

    // Over the window but on neither the strip nor the split area — a border,
    // or the run of caption a strip does not claim. Nothing: a drop there is
    // not a request for a window of its own, it is a miss.
    if (!contentHit(candidate, point)) return null;

    // The window edge beats the pane under it. Dropping at the very edge of a
    // window reads as "put it down the whole side", which a pane's own
    // half-split cannot express.
    if (edgeBandSide(point, candidate.content_rect, metrics)) |side| {
        return .{ .top_level = .{ .window = candidate.window, .side = side } };
    }

    const pane = blk: {
        for (candidate.pane_rects) |p| {
            if (p.rect.contains(point)) break :blk p;
        }
        // Inside the window but between panes — a divider. Nothing.
        break :blk null;
    } orelse return null;

    // A pane cannot be dropped onto itself: every zone of it is a no-op, and
    // a swap with itself is not a swap.
    if (pane_id.eql(pane.id, dragged)) return null;

    return switch (paneZone(point, pane.rect, metrics)) {
        .center => .{ .swap = .{ .window = candidate.window, .pane = pane.id } },
        .edge => |side| .{ .split = .{
            .window = candidate.window,
            .pane = pane.id,
            .side = side,
        } },
    };
}

/// The tab currently under the pointer, for T1532's long-hover timer that
/// switches tabs mid-drag.
///
/// Separate from `resolve` because it is a *dwell* result, not a drop: the
/// same point simultaneously means "release here to make a new tab" and "rest
/// here to open that tab".
pub fn hoveredTab(point: Point, candidates: []const Candidate) ?TabHit {
    const candidate = frontmost(candidates, point, tabBarContains) orelse return null;
    for (candidate.tab_button_rects, 0..) |r, i| {
        if (r.contains(point)) return .{ .window = candidate.window, .index = i };
    }
    // The strip's background or its "+" button names no tab.
    return null;
}

pub const TabHit = struct {
    window: WindowRef,
    index: usize,
};

/// The swap rectangle inscribed in a pane.
pub fn swapRect(rect: Rect, metrics: Metrics) Rect {
    const w = swapExtent(rect.width(), metrics);
    const h = swapExtent(rect.height(), metrics);
    const cx = rect.left + @divFloor(rect.width(), 2);
    const cy = rect.top + @divFloor(rect.height(), 2);
    return .{
        .left = cx - @divFloor(w, 2),
        .top = cy - @divFloor(h, 2),
        .right = cx - @divFloor(w, 2) + w,
        .bottom = cy - @divFloor(h, 2) + h,
    };
}

fn swapExtent(extent: i32, metrics: Metrics) i32 {
    if (extent <= 0) return 0;
    const e: f32 = @floatFromInt(extent);
    const wanted: i32 = @intFromFloat(@round(e * Metrics.swap_fraction));
    const cap: i32 = @intFromFloat(@round(e * Metrics.swap_maximum_fraction));
    return @min(@max(wanted, metrics.swap_minimum), cap);
}

/// Which pane zone a point falls in.
///
/// Outside the swap rectangle the pane is divided into four triangles by its
/// diagonals — "nearest edge wins" — which is what makes the corners behave:
/// a point up and to the left reads as whichever it is more of.
pub fn paneZone(point: Point, rect: Rect, metrics: Metrics) PaneZone {
    if (swapRect(rect, metrics).contains(point)) return .center;
    return .{ .edge = nearestSide(point, rect) };
}

/// The top-level insert side a point in the window's edge band means, or null
/// when it is not in the band.
pub fn edgeBandSide(point: Point, content_rect: Rect, metrics: Metrics) ?Side {
    if (!content_rect.contains(point)) return null;

    const minimum = metrics.minimumWindowForEdgeBand();
    if (content_rect.width() < minimum or content_rect.height() < minimum) return null;

    // In PIXELS, not normalized: the band is an absolute distance, so the
    // edge it names must be the one actually nearest in pixels. Using the
    // pane triangles' normalized distances here would miss — 30px from a
    // short window's side is "nearer" in fractions than 10px from its very
    // long bottom, and the drop would fall out of the band entirely.
    const to_left = point.x - content_rect.left;
    const to_right = content_rect.right - 1 - point.x;
    const to_top = point.y - content_rect.top;
    const to_bottom = content_rect.bottom - 1 - point.y;

    const nearest = @min(@min(to_left, to_right), @min(to_top, to_bottom));
    if (nearest > metrics.edge_band) return null;

    // Horizontal first, so an exact corner is deterministic.
    if (nearest == to_left) return .left;
    if (nearest == to_right) return .right;
    if (nearest == to_top) return .up;
    return .down;
}

/// The edge a point is nearest to as a FRACTION of the pane's own dimensions
/// — the four triangles cut by the pane's diagonals.
///
/// Normalized rather than absolute so a 2000x200 pane still divides along its
/// diagonals; in pixels its diagonals would be so shallow that nearly every
/// position read as up or down.
///
/// Ties break horizontal-first — left, right, up, down — so an exact corner
/// is deterministic.
fn nearestSide(point: Point, rect: Rect) Side {
    const w = rect.width();
    const h = rect.height();
    if (w <= 0 or h <= 0) return .right;

    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const to_left: f32 = @as(f32, @floatFromInt(point.x - rect.left)) / fw;
    const to_right: f32 = @as(f32, @floatFromInt(rect.right - 1 - point.x)) / fw;
    // y grows DOWNWARD here, so the pane's top edge is `top` and "insert
    // above" is proximity to it. This is the inversion of the Swift.
    const to_top: f32 = @as(f32, @floatFromInt(point.y - rect.top)) / fh;
    const to_bottom: f32 = @as(f32, @floatFromInt(rect.bottom - 1 - point.y)) / fh;

    const nearest = @min(@min(to_left, to_right), @min(to_top, to_bottom));
    if (nearest == to_left) return .left;
    if (nearest == to_right) return .right;
    if (nearest == to_top) return .up;
    return .down;
}

// -- private --------------------------------------------------------------

fn contentHit(c: Candidate, p: Point) bool {
    return c.content_rect.contains(p);
}

fn tabBarContains(c: Candidate, p: Point) bool {
    const r = c.tab_bar_rect orelse return false;
    return r.contains(p);
}

/// The lowest-z-order candidate `pred` accepts.
///
/// Mac sorts the array up front; picking the minimum in one pass is the same
/// arbitration without asking a pure function for an allocator or mutating
/// the caller's slice.
fn frontmost(
    candidates: []const Candidate,
    point: Point,
    comptime pred: fn (Candidate, Point) bool,
) ?Candidate {
    var best: ?Candidate = null;
    for (candidates) |c| {
        if (!pred(c, point)) continue;
        if (best == null or c.z_order < best.?.z_order) best = c;
    }
    return best;
}

/// Does this candidate cover the point at ALL?
///
/// The window's whole frame when it published one, and otherwise the two rects
/// it did publish (they are disjoint — the strip sits above the content). This
/// is what decides which window owns an overlapped point.
fn windowHit(c: Candidate, p: Point) bool {
    if (c.frame_rect) |f| {
        if (f.contains(p)) return true;
    }
    return contentHit(c, p) or tabBarContains(c, p);
}

/// Over a button: insert at that button's index. Over the strip's background
/// or its "+": append. Either way the strip means "tab".
fn tabIndexAt(c: Candidate, point: Point) usize {
    for (c.tab_button_rects, 0..) |r, i| {
        if (r.contains(point)) return i;
    }
    return c.tab_button_rects.len;
}

// -- tests ----------------------------------------------------------------

const dragged_id = "AAAAAAAA-0000-4000-8000-000000000001";
const other_id = "BBBBBBBB-0000-4000-8000-000000000002";
const third_id = "CCCCCCCC-0000-4000-8000-000000000003";

const m1 = Metrics{ .edge_band = 28, .swap_minimum = 44 };

/// One window, 1000x800 at the origin, split left/right down the middle with
/// the dragged pane on the left.
fn twoPaneCandidate(panes: []const PaneRect) Candidate {
    return .{
        .window = 1,
        .z_order = 0,
        .content_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 },
        .pane_rects = panes,
    };
}

test "Metrics.forScale scales Mac's point constants into pixels" {
    try testing.expectEqual(@as(i32, 28), Metrics.forScale(1.0).edge_band);
    try testing.expectEqual(@as(i32, 44), Metrics.forScale(1.0).swap_minimum);
    try testing.expectEqual(@as(i32, 35), Metrics.forScale(1.25).edge_band);
    try testing.expectEqual(@as(i32, 56), Metrics.forScale(2.0).edge_band);
    try testing.expectEqual(@as(i32, 88), Metrics.forScale(2.0).swap_minimum);
}

test "a point over no window at all makes a new window there" {
    const panes = [_]PaneRect{.{ .id = dragged_id, .rect = .{ .left = 0, .top = 0, .right = 500, .bottom = 800 } }};
    const cands = [_]Candidate{twoPaneCandidate(&panes)};
    const t = resolve(.{ .x = 5000, .y = 5000 }, &cands, dragged_id, m1).?;
    try testing.expect(t == .new_window);
    try testing.expectEqual(@as(i32, 5000), t.new_window.x);
    try testing.expect(t.window() == null);
}

test "an empty candidate set always makes a new window" {
    const t = resolve(.{ .x = 10, .y = 10 }, &.{}, dragged_id, m1).?;
    try testing.expect(t == .new_window);
}

test "the centre of another pane swaps with it" {
    const panes = [_]PaneRect{
        .{ .id = dragged_id, .rect = .{ .left = 0, .top = 0, .right = 500, .bottom = 800 } },
        .{ .id = other_id, .rect = .{ .left = 500, .top = 0, .right = 1000, .bottom = 800 } },
    };
    const cands = [_]Candidate{twoPaneCandidate(&panes)};
    const t = resolve(.{ .x = 750, .y = 400 }, &cands, dragged_id, m1).?;
    try testing.expect(t == .swap);
    try testing.expectEqualStrings(other_id, t.swap.pane);
    try testing.expectEqual(@as(WindowRef, 1), t.window().?);
}

test "each quadrant of another pane splits it on that side" {
    const panes = [_]PaneRect{
        .{ .id = dragged_id, .rect = .{ .left = 0, .top = 0, .right = 500, .bottom = 800 } },
        .{ .id = other_id, .rect = .{ .left = 500, .top = 0, .right = 1000, .bottom = 800 } },
    };
    const cands = [_]Candidate{twoPaneCandidate(&panes)};

    const cases = [_]struct { p: Point, side: Side }{
        .{ .p = .{ .x = 540, .y = 400 }, .side = .left },
        .{ .p = .{ .x = 960, .y = 400 }, .side = .right },
        .{ .p = .{ .x = 750, .y = 60 }, .side = .up },
        .{ .p = .{ .x = 750, .y = 740 }, .side = .down },
    };
    for (cases) |c| {
        const t = resolve(c.p, &cands, dragged_id, m1).?;
        try testing.expect(t == .split);
        try testing.expectEqualStrings(other_id, t.split.pane);
        try testing.expectEqual(c.side, t.split.side);
    }
}

test "y grows downward: the pane's upper quadrant is `up`, not `down`" {
    // The inversion of the Swift. A pane spanning y 100..500 has its TOP at
    // y=100 here, where AppKit would have it at the larger y.
    const rect = Rect{ .left = 0, .top = 100, .right = 400, .bottom = 500 };
    try testing.expectEqual(Side.up, nearestSide(.{ .x = 200, .y = 110 }, rect));
    try testing.expectEqual(Side.down, nearestSide(.{ .x = 200, .y = 490 }, rect));
}

test "an exact corner breaks horizontal-first" {
    const rect = Rect{ .left = 0, .top = 0, .right = 400, .bottom = 400 };
    // Dead on the top-left diagonal: left and up are equidistant.
    try testing.expectEqual(Side.left, nearestSide(.{ .x = 10, .y = 10 }, rect));
    // Top-right: right and up are equidistant, and right wins over up.
    try testing.expectEqual(Side.right, nearestSide(.{ .x = 389, .y = 10 }, rect));
}

test "a pane cannot be dropped onto itself" {
    const panes = [_]PaneRect{
        .{ .id = dragged_id, .rect = .{ .left = 0, .top = 0, .right = 500, .bottom = 800 } },
        .{ .id = other_id, .rect = .{ .left = 500, .top = 0, .right = 1000, .bottom = 800 } },
    };
    const cands = [_]Candidate{twoPaneCandidate(&panes)};
    // Centre of the dragged pane, well clear of the window's edge band.
    try testing.expect(resolve(.{ .x = 250, .y = 400 }, &cands, dragged_id, m1) == null);
    // ...and its quadrant, too.
    try testing.expect(resolve(.{ .x = 100, .y = 400 }, &cands, dragged_id, m1) == null);
}

test "the dragged pane is matched case-insensitively" {
    var lowered: [36]u8 = undefined;
    _ = std.ascii.lowerString(&lowered, dragged_id);
    const panes = [_]PaneRect{
        .{ .id = dragged_id, .rect = .{ .left = 0, .top = 0, .right = 500, .bottom = 800 } },
    };
    const cands = [_]Candidate{twoPaneCandidate(&panes)};
    try testing.expect(resolve(.{ .x = 250, .y = 400 }, &cands, &lowered, m1) == null);
}

test "a gap between panes is a divider and resolves to nothing" {
    const panes = [_]PaneRect{
        .{ .id = dragged_id, .rect = .{ .left = 0, .top = 0, .right = 498, .bottom = 800 } },
        .{ .id = other_id, .rect = .{ .left = 502, .top = 0, .right = 1000, .bottom = 800 } },
    };
    const cands = [_]Candidate{twoPaneCandidate(&panes)};
    try testing.expect(resolve(.{ .x = 500, .y = 400 }, &cands, dragged_id, m1) == null);
}

test "the window's edge band inserts at the top level, beating the pane under it" {
    const panes = [_]PaneRect{
        .{ .id = dragged_id, .rect = .{ .left = 0, .top = 0, .right = 500, .bottom = 800 } },
        .{ .id = other_id, .rect = .{ .left = 500, .top = 0, .right = 1000, .bottom = 800 } },
    };
    const cands = [_]Candidate{twoPaneCandidate(&panes)};

    const cases = [_]struct { p: Point, side: Side }{
        .{ .p = .{ .x = 3, .y = 400 }, .side = .left },
        .{ .p = .{ .x = 996, .y = 400 }, .side = .right },
        .{ .p = .{ .x = 500, .y = 3 }, .side = .up },
        .{ .p = .{ .x = 500, .y = 796 }, .side = .down },
    };
    for (cases) |c| {
        const t = resolve(c.p, &cands, dragged_id, m1).?;
        try testing.expect(t == .top_level);
        try testing.expectEqual(c.side, t.top_level.side);
        try testing.expectEqual(@as(WindowRef, 1), t.window().?);
    }
}

test "the edge band is an absolute distance, not a fraction of the window" {
    const wide = Rect{ .left = 0, .top = 0, .right = 4000, .bottom = 300 };
    // 30px from the left is OUTSIDE the 28px band even though it is a far
    // smaller fraction of the width than 10px is of the height.
    try testing.expect(edgeBandSide(.{ .x = 30, .y = 150 }, wide, m1) == null);
    try testing.expectEqual(Side.up, edgeBandSide(.{ .x = 2000, .y = 10 }, wide, m1).?);
}

test "a window too small for four bands has no edge band at all" {
    const tiny = Rect{ .left = 0, .top = 0, .right = 100, .bottom = 100 };
    try testing.expect(edgeBandSide(.{ .x = 2, .y = 50 }, tiny, m1) == null);
    // One pixel over the threshold on both axes and it is back.
    const ok = Rect{ .left = 0, .top = 0, .right = 112, .bottom = 112 };
    try testing.expectEqual(Side.left, edgeBandSide(.{ .x = 2, .y = 56 }, ok, m1).?);
}

test "a point outside the content rect is never in its edge band" {
    const r = Rect{ .left = 0, .top = 0, .right = 1000, .bottom = 800 };
    try testing.expect(edgeBandSide(.{ .x = -5, .y = 400 }, r, m1) == null);
}

test "the swap rectangle is floored, then capped, so a small pane is not mostly swap" {
    // 1000x800: 34% is 340x272, comfortably over the 44px floor.
    const big = swapRect(.{ .left = 0, .top = 0, .right = 1000, .bottom = 800 }, m1);
    try testing.expectEqual(@as(i32, 340), big.width());
    try testing.expectEqual(@as(i32, 272), big.height());

    // 100x100: 34% is 34, under the floor, so the floor lifts it to 44 —
    // still under the 60% cap of 60.
    const small = swapRect(.{ .left = 0, .top = 0, .right = 100, .bottom = 100 }, m1);
    try testing.expectEqual(@as(i32, 44), small.width());

    // 60x60: the floor wants 44 but the 60% cap is 36, and the cap wins.
    const tiny = swapRect(.{ .left = 0, .top = 0, .right = 60, .bottom = 60 }, m1);
    try testing.expectEqual(@as(i32, 36), tiny.width());
}

test "the swap rectangle is centred in its pane" {
    const r = swapRect(.{ .left = 100, .top = 200, .right = 600, .bottom = 600 }, m1);
    try testing.expectEqual(@as(i32, 350), r.left + @divFloor(r.width(), 2));
    try testing.expectEqual(@as(i32, 400), r.top + @divFloor(r.height(), 2));
}

test "a degenerate pane rect resolves rather than dividing by zero" {
    const empty = Rect{ .left = 10, .top = 10, .right = 10, .bottom = 10 };
    try testing.expectEqual(Side.right, nearestSide(.{ .x = 10, .y = 10 }, empty));
    try testing.expectEqual(@as(i32, 0), swapRect(empty, m1).width());
}

test "the tab strip makes a new tab at the index under the pointer" {
    const panes = [_]PaneRect{.{ .id = other_id, .rect = .{ .left = 0, .top = 40, .right = 1000, .bottom = 800 } }};
    const buttons = [_]Rect{
        .{ .left = 0, .top = 0, .right = 120, .bottom = 40 },
        .{ .left = 120, .top = 0, .right = 240, .bottom = 40 },
    };
    const cands = [_]Candidate{.{
        .window = 7,
        .z_order = 0,
        .content_rect = .{ .left = 0, .top = 40, .right = 1000, .bottom = 800 },
        .pane_rects = &panes,
        .tab_bar_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 40 },
        .tab_button_rects = &buttons,
    }};

    const first = resolve(.{ .x = 60, .y = 20 }, &cands, dragged_id, m1).?;
    try testing.expect(first == .new_tab);
    try testing.expectEqual(@as(usize, 0), first.new_tab.index);
    try testing.expectEqual(@as(WindowRef, 7), first.new_tab.window);

    const second = resolve(.{ .x = 180, .y = 20 }, &cands, dragged_id, m1).?;
    try testing.expectEqual(@as(usize, 1), second.new_tab.index);

    // Past the last button — the strip's background — appends.
    const append = resolve(.{ .x = 700, .y = 20 }, &cands, dragged_id, m1).?;
    try testing.expectEqual(@as(usize, 2), append.new_tab.index);
}

test "the tab strip outranks the content rect when they overlap" {
    // A strip drawn INSIDE the content rect must still read as chrome.
    const panes = [_]PaneRect{.{ .id = other_id, .rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 } }};
    const buttons = [_]Rect{.{ .left = 0, .top = 0, .right = 120, .bottom = 40 }};
    const cands = [_]Candidate{.{
        .window = 7,
        .z_order = 0,
        .content_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 },
        .pane_rects = &panes,
        .tab_bar_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 40 },
        .tab_button_rects = &buttons,
    }};
    const t = resolve(.{ .x = 60, .y = 20 }, &cands, dragged_id, m1).?;
    try testing.expect(t == .new_tab);
}

test "hoveredTab names a button but never the strip's background" {
    const buttons = [_]Rect{
        .{ .left = 0, .top = 0, .right = 120, .bottom = 40 },
        .{ .left = 120, .top = 0, .right = 240, .bottom = 40 },
    };
    const cands = [_]Candidate{.{
        .window = 7,
        .z_order = 0,
        .content_rect = .{ .left = 0, .top = 40, .right = 1000, .bottom = 800 },
        .pane_rects = &.{},
        .tab_bar_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 40 },
        .tab_button_rects = &buttons,
    }};
    const hit = hoveredTab(.{ .x = 180, .y = 20 }, &cands).?;
    try testing.expectEqual(@as(usize, 1), hit.index);
    try testing.expectEqual(@as(WindowRef, 7), hit.window);

    // The background names no tab, even though a DROP there would append.
    try testing.expect(hoveredTab(.{ .x = 700, .y = 20 }, &cands) == null);
    // Off the strip entirely.
    try testing.expect(hoveredTab(.{ .x = 180, .y = 400 }, &cands) == null);
}

test "overlapping windows are arbitrated by z-order, not by array order" {
    const back_panes = [_]PaneRect{.{ .id = other_id, .rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 } }};
    const front_panes = [_]PaneRect{.{ .id = third_id, .rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 } }};
    const cands = [_]Candidate{
        .{
            .window = 2,
            .z_order = 5,
            .content_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 },
            .pane_rects = &back_panes,
        },
        .{
            .window = 3,
            .z_order = 0,
            .content_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 },
            .pane_rects = &front_panes,
        },
    };
    const t = resolve(.{ .x = 500, .y = 400 }, &cands, dragged_id, m1).?;
    try testing.expect(t == .swap);
    try testing.expectEqual(@as(WindowRef, 3), t.swap.window);
    try testing.expectEqualStrings(third_id, t.swap.pane);
}

test "z-order arbitrates the tab strip too" {
    const buttons = [_]Rect{.{ .left = 0, .top = 0, .right = 120, .bottom = 40 }};
    const cands = [_]Candidate{
        .{
            .window = 2,
            .z_order = 5,
            .content_rect = .{ .left = 0, .top = 40, .right = 1000, .bottom = 800 },
            .pane_rects = &.{},
            .tab_bar_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 40 },
            .tab_button_rects = &buttons,
        },
        .{
            .window = 3,
            .z_order = 0,
            .content_rect = .{ .left = 0, .top = 40, .right = 1000, .bottom = 800 },
            .pane_rects = &.{},
            .tab_bar_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 40 },
            .tab_button_rects = &buttons,
        },
    };
    const t = resolve(.{ .x = 60, .y = 20 }, &cands, dragged_id, m1).?;
    try testing.expectEqual(@as(WindowRef, 3), t.new_tab.window);
    try testing.expectEqual(@as(WindowRef, 3), hoveredTab(.{ .x = 60, .y = 20 }, &cands).?.window);
}

test "the front window's PANES beat a strip behind them (T1538)" {
    // The shape a second window makes: a back window whose strip lies under
    // the front window's split area. Before one window owned the point, the
    // strip was searched across the whole set first and this dropped a tab
    // into the window the user could not see.
    const front_panes = [_]PaneRect{.{ .id = other_id, .rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 } }};
    const buttons = [_]Rect{.{ .left = 0, .top = 380, .right = 120, .bottom = 420 }};
    const cands = [_]Candidate{
        .{
            .window = 7,
            .z_order = 0,
            .content_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 },
            .pane_rects = &front_panes,
        },
        .{
            .window = 8,
            .z_order = 4,
            .content_rect = .{ .left = 0, .top = 420, .right = 1000, .bottom = 800 },
            .pane_rects = &.{},
            .tab_bar_rect = .{ .left = 0, .top = 380, .right = 1000, .bottom = 420 },
            .tab_button_rects = &buttons,
        },
    };
    const t = resolve(.{ .x = 500, .y = 400 }, &cands, dragged_id, m1).?;
    try testing.expect(t == .swap);
    try testing.expectEqual(@as(WindowRef, 7), t.swap.window);
}

test "a point on a window's own chrome is a miss, not a new window" {
    // Between the strip and the content — the caption run a strip does not
    // claim. A new window there would be a gesture the user never made, and
    // before the frame rect that is exactly what it was.
    const cands = [_]Candidate{
        .{
            .window = 7,
            .z_order = 0,
            .frame_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 },
            .content_rect = .{ .left = 0, .top = 100, .right = 1000, .bottom = 800 },
            .pane_rects = &.{},
            .tab_bar_rect = .{ .left = 0, .top = 0, .right = 400, .bottom = 40 },
            .tab_button_rects = &.{},
        },
    };
    try testing.expect(resolve(.{ .x = 700, .y = 20 }, &cands, dragged_id, m1) == null);
}

test "a window's chrome still beats a window BEHIND it" {
    const behind = [_]PaneRect{.{ .id = other_id, .rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 } }};
    const cands = [_]Candidate{
        .{
            .window = 7,
            .z_order = 0,
            .frame_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 },
            .content_rect = .{ .left = 0, .top = 100, .right = 1000, .bottom = 800 },
            .pane_rects = &.{},
            .tab_bar_rect = .{ .left = 0, .top = 0, .right = 400, .bottom = 40 },
            .tab_button_rects = &.{},
        },
        .{
            .window = 8,
            .z_order = 3,
            .frame_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 },
            .content_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 },
            .pane_rects = &behind,
        },
    };
    try testing.expect(resolve(.{ .x = 700, .y = 20 }, &cands, dragged_id, m1) == null);
}

test "a drop lands in ANOTHER window, named by that window's ref" {
    const mine = [_]PaneRect{.{ .id = dragged_id, .rect = .{ .left = 0, .top = 0, .right = 500, .bottom = 800 } }};
    const theirs = [_]PaneRect{.{ .id = other_id, .rect = .{ .left = 2000, .top = 0, .right = 3000, .bottom = 800 } }};
    const cands = [_]Candidate{
        .{
            .window = 1,
            .z_order = 1,
            .content_rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 },
            .pane_rects = &mine,
        },
        .{
            .window = 2,
            .z_order = 0,
            .content_rect = .{ .left = 2000, .top = 0, .right = 3000, .bottom = 800 },
            .pane_rects = &theirs,
        },
    };
    const t = resolve(.{ .x = 2500, .y = 400 }, &cands, dragged_id, m1).?;
    try testing.expect(t == .swap);
    try testing.expectEqual(@as(WindowRef, 2), t.swap.window);
    try testing.expectEqualStrings(other_id, t.swap.pane);
}

test "Target.window answers for every kind" {
    const split: Target = .{ .split = .{ .window = 1, .pane = other_id, .side = .left } };
    const swap: Target = .{ .swap = .{ .window = 2, .pane = other_id } };
    const top: Target = .{ .top_level = .{ .window = 3, .side = .down } };
    const tab: Target = .{ .new_tab = .{ .window = 4, .index = 0 } };
    const win: Target = .{ .new_window = .{ .x = 0, .y = 0 } };
    try testing.expectEqual(@as(?WindowRef, 1), split.window());
    try testing.expectEqual(@as(?WindowRef, 2), swap.window());
    try testing.expectEqual(@as(?WindowRef, 3), top.window());
    try testing.expectEqual(@as(?WindowRef, 4), tab.window());
    try testing.expectEqual(@as(?WindowRef, null), win.window());
}
