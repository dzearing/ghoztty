//! The pure half of the GTK stage's gutter bar and a gutter's double-click
//! (T3626; docs/reference/stacked-panes.md "The gutter bar", "Double-clicking
//! a grip"; Mac `GutterBar`, win32 T2253/T2270/T2409/T2285).
//!
//! Every divider and grip on the stage shows a 4px accent bar with a soft
//! glow down the middle of its gutter: half strength while the pointer is
//! over it, full while it is dragged, and one bar at a time. The bar stays in
//! the gutter (it is drawn where the layout leaves the gutter, never out at
//! the pointer), and when the dragged gutter is replaced - a pane tucks away,
//! a strip comes out - it moves to the gutter that took its place, nearest
//! where the bar was (`place`).
//!
//! The bar's size and strengths are win32's (`win32/gutter_bar.zig`, which
//! carries Mac's numbers across), imported in place like the rest of the
//! stacked-panes engine, so the two frontends cannot disagree. The GTK half
//! (`class/split_tree.zig`) draws it as one non-targetable widget on the
//! stage, above every card.
//!
//! Std-only so it asserts in the `-Dapp-runtime=none` lane.
const std = @import("std");
const testing = std.testing;
const gutter_bar = @import("../win32/gutter_bar.zig");
const grid = @import("../win32/pane_stack_grid.zig");
const layout = @import("../win32/pane_stack_layout.zig");

pub const PxRect = grid.PxRect;
pub const Direction = layout.Direction;
pub const Strength = gutter_bar.Strength;

/// What a gutter on the stage is: a split divider, a grip between two cards
/// of a stacked run, or the grip where a run meets its strips.
pub const Kind = enum { divider, grip, edge };

/// A gutter as the stage lays it out: what a bar can sit in.
pub const Gutter = struct {
    kind: Kind,
    direction: Direction,
    rect: PxRect,
    /// A divider's split node: its identity from one layout to the next.
    node: ?u32 = null,
};

/// The gutter a drag took hold of, as the press found it.
pub const Held = struct {
    kind: Kind,
    direction: Direction,
    node: ?u32 = null,
};

fn mid(r: PxRect, d: Direction) i32 {
    return switch (d) {
        .horizontal => @divFloor(r.left + r.right, 2),
        .vertical => @divFloor(r.top + r.bottom, 2),
    };
}

/// Whether `a` and `b` share any of their span ACROSS the drag: a gutter in
/// another row of the window is never the one that replaced this one.
fn sharesSpan(a: PxRect, b: PxRect, d: Direction) bool {
    return switch (d) {
        .horizontal => a.top < b.bottom and b.top < a.bottom,
        .vertical => a.left < b.right and b.left < a.right,
    };
}

/// Which of `gutters` a held drag's bar is on now (Mac
/// `GutterBar.replacement`). A divider still in the layout keeps its bar.
/// Otherwise - a grip, whose index is not stable, or a divider the drag
/// folded into a stack - the gutter running the same way, across the same
/// span, nearest where the bar was `last`; its own kind wins a tie. Null when
/// no gutter qualifies (the bar goes out).
pub fn place(gutters: []const Gutter, held: Held, last: PxRect) ?usize {
    if (held.node) |node| for (gutters, 0..) |g, i| {
        if (g.kind == .divider and g.node == node) return i;
    };
    const at = mid(last, held.direction);
    var best: ?usize = null;
    var best_d: i64 = std.math.maxInt(i64);
    var best_same = false;
    for (gutters, 0..) |g, i| {
        if (g.direction != held.direction) continue;
        if (!sharesSpan(g.rect, last, held.direction)) continue;
        const d: i64 = @abs(@as(i64, mid(g.rect, held.direction)) - at);
        const same = g.kind == held.kind;
        if (d < best_d or (d == best_d and same and !best_same)) {
            best = i;
            best_d = d;
            best_same = same;
        }
    }
    return best;
}

/// The one bar on show and how strong: the drag's at full strength while a
/// drag is under way - whatever the pointer is over - else the hovered
/// gutter's at half (win32 `gutter_bar.lit`, Mac `GutterBar.show`).
pub const Lit = struct { index: usize, strength: Strength };

pub fn lit(hovered: ?usize, dragged: ?usize, dragging: bool) ?Lit {
    if (dragging) return if (dragged) |d| .{ .index = d, .strength = .drag } else null;
    if (hovered) |h| return .{ .index = h, .strength = .hover };
    return null;
}

/// The bar's core in `gutter` (logical px): 4px across, centred, the
/// gutter's whole length, never wider than the gutter (win32 `barIn`).
pub fn barIn(gutter: PxRect, d: Direction) PxRect {
    const r = gutter_bar.barIn(.{
        .left = gutter.left,
        .top = gutter.top,
        .right = gutter.right,
        .bottom = gutter.bottom,
    }, switch (d) {
        .horizontal => .across_x,
        .vertical => .across_y,
    }, 1);
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

/// One press on a gutter: when, where, and which gutter.
pub const Press = struct {
    us: i64,
    x: f64,
    y: f64,
    kind: Kind,
    direction: Direction,
};

/// Whether `now` completes a double-click begun by `prev`: inside the
/// desktop's double-click time and distance (`gtk-double-click-time`,
/// `gtk-double-click-distance`), on a gutter of the same kind and way.
pub fn isDoublePress(prev: ?Press, now: Press, time_ms: i64, distance: f64) bool {
    const p = prev orelse return false;
    if (p.kind != now.kind or p.direction != now.direction) return false;
    const dt = now.us - p.us;
    if (dt < 0 or dt > time_ms * std.time.us_per_ms) return false;
    return @abs(now.x - p.x) <= distance and @abs(now.y - p.y) <= distance;
}

/// What a double-click on a gutter does (Mac `TerminalSplitOperation`):
/// a divider evens out the panes across it in its direction only
/// (`equalize`), a grip between two cards evens the run on show
/// (`evenRun`), and the grip where a run meets its strips has none.
pub const Even = enum { splits, run, none };

pub fn evenFor(kind: Kind) Even {
    return switch (kind) {
        .divider => .splits,
        .grip => .run,
        .edge => .none,
    };
}

// ---------------------------------------------------------------------------

fn r(l: i32, t: i32, rt: i32, b: i32) PxRect {
    return .{ .left = l, .top = t, .right = rt, .bottom = b };
}

test "a divider still laid out keeps its bar, wherever it went" {
    const gs = [_]Gutter{
        .{ .kind = .grip, .direction = .horizontal, .rect = r(300, 0, 310, 400) },
        .{ .kind = .divider, .direction = .horizontal, .rect = r(700, 0, 710, 400), .node = 4 },
    };
    const i = place(&gs, .{ .kind = .divider, .direction = .horizontal, .node = 4 }, r(300, 0, 310, 400)).?;
    try testing.expectEqual(@as(usize, 1), i);
}

test "a divider folded into a stack hands its bar to the grip nearest where it was" {
    const gs = [_]Gutter{
        .{ .kind = .edge, .direction = .horizontal, .rect = r(36, 0, 46, 400) },
        .{ .kind = .grip, .direction = .horizontal, .rect = r(500, 0, 510, 400) },
        .{ .kind = .edge, .direction = .horizontal, .rect = r(900, 0, 910, 400) },
    };
    const i = place(&gs, .{ .kind = .divider, .direction = .horizontal, .node = 9 }, r(480, 0, 490, 400)).?;
    try testing.expectEqual(@as(usize, 1), i);
}

test "a grip's bar follows the gutter nearest where it was, not one in another row" {
    const gs = [_]Gutter{
        // Same x, but in the row below: not this drag's.
        .{ .kind = .grip, .direction = .horizontal, .rect = r(410, 500, 420, 900) },
        .{ .kind = .grip, .direction = .horizontal, .rect = r(440, 0, 450, 400) },
        // Running the other way: never.
        .{ .kind = .divider, .direction = .vertical, .rect = r(0, 400, 900, 410), .node = 1 },
    };
    const i = place(&gs, .{ .kind = .grip, .direction = .horizontal }, r(405, 0, 415, 400)).?;
    try testing.expectEqual(@as(usize, 1), i);
    try testing.expect(place(gs[2..], .{ .kind = .grip, .direction = .horizontal }, r(405, 0, 415, 400)) == null);
}

test "a tie goes to the gutter of the held kind" {
    const gs = [_]Gutter{
        .{ .kind = .divider, .direction = .horizontal, .rect = r(390, 0, 400, 400), .node = 2 },
        .{ .kind = .edge, .direction = .horizontal, .rect = r(410, 0, 420, 400) },
    };
    const i = place(&gs, .{ .kind = .edge, .direction = .horizontal }, r(400, 0, 410, 400)).?;
    try testing.expectEqual(@as(usize, 1), i);
}

test "one bar at a time: a drag's outranks the hover, and a lost gutter lights nothing" {
    try testing.expect(lit(null, null, false) == null);
    const h = lit(2, null, false).?;
    try testing.expectEqual(Strength.hover, h.strength);
    try testing.expectEqual(@as(usize, 2), h.index);
    const d = lit(2, 0, true).?;
    try testing.expectEqual(Strength.drag, d.strength);
    try testing.expectEqual(@as(usize, 0), d.index);
    // Mid-drag the hover never lights, even when the drag's gutter is gone.
    try testing.expect(lit(2, null, true) == null);
    try testing.expectEqual(@as(f32, 0.5), Strength.hover.opacity());
    try testing.expectEqual(@as(f32, 1.0), Strength.drag.opacity());
}

test "the bar is 4px down the middle of its gutter, its whole length" {
    try testing.expectEqual(r(103, 0, 107, 400), barIn(r(100, 0, 110, 400), .horizontal));
    try testing.expectEqual(r(0, 51, 800, 55), barIn(r(0, 50, 800, 56), .vertical));
    // A gutter thinner than the bar keeps it inside.
    const thin = barIn(r(10, 0, 12, 30), .horizontal);
    try testing.expect(thin.left >= 10 and thin.right <= 12);
}

test "a second press on the same gutter, soon and close, is a double-click" {
    const a: Press = .{ .us = 1_000_000, .x = 405, .y = 200, .kind = .grip, .direction = .horizontal };
    var b = a;
    b.us += 250 * std.time.us_per_ms;
    b.x += 2;
    try testing.expect(isDoublePress(a, b, 400, 5));
    try testing.expect(!isDoublePress(null, b, 400, 5));
    var late = b;
    late.us = a.us + 401 * std.time.us_per_ms;
    try testing.expect(!isDoublePress(a, late, 400, 5));
    var far = b;
    far.y += 6;
    try testing.expect(!isDoublePress(a, far, 400, 5));
    var other = b;
    other.kind = .divider;
    try testing.expect(!isDoublePress(a, other, 400, 5));
    var back = b;
    back.us = a.us - 1;
    try testing.expect(!isDoublePress(a, back, 400, 5));
}

test "a divider evens its splits, a grip between cards its run, a run's edge nothing" {
    try testing.expectEqual(Even.splits, evenFor(.divider));
    try testing.expectEqual(Even.run, evenFor(.grip));
    try testing.expectEqual(Even.none, evenFor(.edge));
}
