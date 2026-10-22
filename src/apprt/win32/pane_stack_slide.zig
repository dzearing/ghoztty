//! The carousel slide (T2102, a slice of T2101): Mac `PaneStageView`
//! (86b7e3410), as the numbers the window's placement reads.
//!
//! When a stack's run changes - a strip clicked, focus moved onto a tucked
//! pane - the cards on show do not jump to their new slots: they glide there,
//! on Mac's curve and in Mac's time. A card that keeps its size is only ever
//! MOVED on the way, so its terminal is never told to resize (a child window
//! moved without a size change gets no WM_SIZE, and so no ConPTY resize). A
//! card whose size changes too (a row gaining or losing a card on show) holds
//! the size it had while it moves - Mac's `paneContentFreeze` - and takes its
//! new size in one step when the slide ends: one resize per pane, after the
//! motion, never a reflow mid-slide.
//!
//! A slide that starts while one is under way starts every card from where it
//! is on screen, so a second click mid-slide never snaps anything back.
//!
//! Pure, so the tests need no window: the curve, which cards slide, and where
//! each one is at a given moment.

const std = @import("std");
const testing = std.testing;
const grid = @import("pane_stack_grid.zig");
const PxRect = grid.PxRect;
const Id = grid.Id;

/// How long a card takes to slide: Mac's `slideDuration` (0.38 s), or, while a
/// divider drag is reshaping the row, its quicker `gestureSlideDuration`
/// (0.2 s) so the layout keeps up with the hand.
pub const duration_ms: f64 = 380;
pub const gesture_duration_ms: f64 = 200;

/// The slide's curve: Mac's `CAMediaTimingFunction(controlPoints: 0.2, 0.8,
/// 0.2, 1)` - the HTML mock's `cubic-bezier(0.2, 0.8, 0.2, 1)` - as the eased
/// progress at linear progress `t` (clamped to 0..1).
pub fn ease(t: f64) f64 {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    // x(s) is monotonic on 0..1 for these control points: bisect for the s
    // whose x is `t`, then read y there. 30 halvings is far below a pixel.
    var lo: f64 = 0;
    var hi: f64 = 1;
    var s: f64 = t;
    for (0..30) |_| {
        s = (lo + hi) / 2;
        if (bezier(0.2, 0.2, s) < t) lo = s else hi = s;
    }
    return bezier(0.8, 1, s);
}

/// One coordinate of a cubic Bezier from 0 to 1 with inner points `p1`, `p2`.
fn bezier(p1: f64, p2: f64, s: f64) f64 {
    const u = 1 - s;
    return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s;
}

/// A card as the layout placed it: its full card rect, and whether it is
/// tucked behind its stack's run (only its strip on show).
pub const Placed = struct {
    id: Id,
    rect: PxRect,
    tucked: bool,
};

/// A card's width and height, in pixels.
pub const Size = struct {
    w: i32,
    h: i32,
};

/// The size a tucked card's pane is held at (T2105; Mac `PaneCardView`'s
/// `frozenSize` for a tucked card, 89848fd59): the size it last had on show,
/// so a row reflowing around it - a window resize, a card coming or going -
/// never resizes a program nobody can see. `held` is what the card was held
/// at already, `last` its placement in the previous layout, `slot` the slot
/// the layout gives it now. A card that has never been on show takes its
/// slot's size, once.
pub fn hold(held: ?Size, last: ?Placed, slot: PxRect) Size {
    if (held) |s| return s;
    if (last) |b| if (!b.tucked) return .{ .w = b.rect.width(), .h = b.rect.height() };
    return .{ .w = slot.width(), .h = slot.height() };
}

/// Where a tucked card's (hidden) pane sits: at its tucked place, at its held
/// size. Bringing it forward slides it from here at that size, and it takes
/// its slot's size once, when the slide ends.
pub fn heldRect(slot: PxRect, s: Size) PxRect {
    return .{ .left = slot.left, .top = slot.top, .right = slot.left + s.w, .bottom = slot.top + s.h };
}

/// One card's slide: from where it was on screen to its slot.
pub const Card = struct {
    id: Id,
    from: PxRect,
    to: PxRect,
};

/// The most cards one slide tracks; a window holds far fewer panes.
pub const max_cards = 64;

pub const Slide = struct {
    cards: [max_cards]Card = undefined,
    len: usize = 0,
    duration_ms: f64 = duration_ms,

    pub fn items(self: *const Slide) []const Card {
        return self.cards[0..self.len];
    }

    fn find(self: *const Slide, id: Id) ?Card {
        for (self.items()) |c| if (c.id == id) return c;
        return null;
    }

    /// Where card `id` is `elapsed_ms` into the slide, or null when it is not
    /// sliding (it sits at its slot). See `at` for the shape.
    pub fn rectAt(self: *const Slide, id: Id, elapsed_ms: f64) ?PxRect {
        const c = self.find(id) orelse return null;
        return at(c, self.progress(elapsed_ms));
    }

    /// Linear progress, 0..1.
    pub fn progress(self: *const Slide, elapsed_ms: f64) f64 {
        if (self.duration_ms <= 0) return 1;
        return std.math.clamp(elapsed_ms / self.duration_ms, 0, 1);
    }

    pub fn done(self: *const Slide, elapsed_ms: f64) bool {
        return elapsed_ms >= self.duration_ms;
    }
};

/// Where `c` is at linear progress `t`. Its origin moves along the curve; its
/// size is the size it slid FROM until the slide is over, and its slot's
/// size only then - so a card that changes size resizes once, at the end.
pub fn at(c: Card, t: f64) PxRect {
    if (t >= 1) return c.to;
    const e = ease(t);
    const x = lerp(c.from.left, c.to.left, e);
    const y = lerp(c.from.top, c.to.top, e);
    return .{
        .left = x,
        .top = y,
        .right = x + c.from.width(),
        .bottom = y + c.from.height(),
    };
}

fn lerp(a: i32, b: i32, e: f64) i32 {
    const fa: f64 = @floatFromInt(a);
    const fb: f64 = @floatFromInt(b);
    return @intFromFloat(@round(fa + (fb - fa) * e));
}

/// Whether going from `before` to `after` changed which cards are on show -
/// the one change that slides (Mac's `runs != lastRuns`). A card only one
/// side knows (a pane split off or closed) does not count on its own.
pub fn runsChanged(before: []const Placed, after: []const Placed) bool {
    for (after) |a| {
        for (before) |b| {
            if (b.id == a.id and b.tucked != a.tucked) return true;
        }
    }
    return false;
}

/// The slide from `before` to `after`: every card on show afterwards that the
/// layout knew before and that is not already at its slot. Each starts from
/// where it is ON SCREEN - its place in `current` (a slide under way, read
/// `elapsed_ms` in) when it has one, else its last placement - so a slide
/// that interrupts another carries on from there. A card that comes forward
/// from behind the run starts at its tucked card's rect, which lies under the
/// run at its stack's edge. Cards that go behind the run do not slide: they
/// are hidden at once and their strips take their place.
pub fn plan(
    before: []const Placed,
    after: []const Placed,
    current: ?*const Slide,
    elapsed_ms: f64,
    duration: f64,
) Slide {
    var out: Slide = .{ .duration_ms = duration };
    for (after) |a| {
        if (a.tucked) continue;
        const from = blk: {
            if (current) |cur| if (cur.rectAt(a.id, elapsed_ms)) |rect| break :blk rect;
            for (before) |b| if (b.id == a.id) break :blk b.rect;
            break :blk null;
        } orelse continue;
        if (std.meta.eql(from, a.rect)) continue;
        if (out.len == max_cards) break;
        out.cards[out.len] = .{ .id = a.id, .from = from, .to = a.rect };
        out.len += 1;
    }
    return out;
}

// -- tests -------------------------------------------------------------------

fn r(left: i32, top: i32, w: i32, h: i32) PxRect {
    return .{ .left = left, .top = top, .right = left + w, .bottom = top + h };
}

test "ease: Mac's curve - fast out of the gate, settling into place" {
    try testing.expectEqual(@as(f64, 0), ease(0));
    try testing.expectEqual(@as(f64, 1), ease(1));
    try testing.expectEqual(@as(f64, 0), ease(-1));
    try testing.expectEqual(@as(f64, 1), ease(2));
    // cubic-bezier(0.2, 0.8, 0.2, 1) is past 80% of the way by the halfway
    // mark, and only creeps after that.
    try testing.expect(ease(0.5) > 0.8 and ease(0.5) < 0.95);
    try testing.expect(ease(0.1) > 0.2);
    var prev: f64 = 0;
    var i: usize = 1;
    while (i <= 100) : (i += 1) {
        const e = ease(@as(f64, @floatFromInt(i)) / 100);
        try testing.expect(e >= prev);
        prev = e;
    }
}

test "plan: a strip click slides the cards on show to their new slots" {
    // Two on show (1, 2), two tucked at the right edge (3, 4); a click on 4
    // brings it on show and tucks 1.
    const before = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false },
        .{ .id = 2, .rect = r(400, 0, 400, 600), .tucked = false },
        .{ .id = 3, .rect = r(780, 0, 400, 600), .tucked = true },
        .{ .id = 4, .rect = r(790, 0, 400, 600), .tucked = true },
    };
    const after = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = true },
        .{ .id = 2, .rect = r(20, 0, 400, 600), .tucked = true },
        .{ .id = 3, .rect = r(30, 0, 400, 600), .tucked = false },
        .{ .id = 4, .rect = r(430, 0, 400, 600), .tucked = false },
    };
    try testing.expect(runsChanged(&before, &after));
    const s = plan(&before, &after, null, 0, duration_ms);
    // Only the cards on show afterwards slide; the tucked ones are hidden.
    try testing.expectEqual(@as(usize, 2), s.len);
    try testing.expectEqual(@as(Id, 3), s.cards[0].id);
    try testing.expectEqual(r(780, 0, 400, 600), s.cards[0].from);
    try testing.expectEqual(@as(Id, 4), s.cards[1].id);
    // Mid-slide each card is between its two places, at its own size: a
    // move, never a resize.
    const mid = s.rectAt(4, duration_ms / 2).?;
    try testing.expect(mid.left < 790 and mid.left > 430);
    try testing.expectEqual(@as(i32, 400), mid.width());
    try testing.expectEqual(@as(i32, 600), mid.height());
    try testing.expectEqual(r(430, 0, 400, 600), s.rectAt(4, duration_ms).?);
    try testing.expect(s.done(duration_ms));
    try testing.expect(!s.done(duration_ms - 1));
    // A card that is not sliding has no slide rect.
    try testing.expectEqual(@as(?PxRect, null), s.rectAt(1, 10));
}

test "plan: a card that changes size holds its old size until the end" {
    const c: Card = .{ .id = 1, .from = r(0, 0, 400, 600), .to = r(100, 0, 500, 600) };
    const mid = at(c, 0.5);
    try testing.expectEqual(@as(i32, 400), mid.width());
    try testing.expect(mid.left > 0 and mid.left < 100);
    const near_end = at(c, 0.999);
    try testing.expectEqual(@as(i32, 400), near_end.width());
    // One size change in the whole slide, at its end.
    try testing.expectEqual(r(100, 0, 500, 600), at(c, 1));
}

test "plan: a slide mid-slide starts from where the cards are on screen" {
    const before = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false },
        .{ .id = 2, .rect = r(400, 0, 400, 600), .tucked = true },
    };
    const after = [_]Placed{
        .{ .id = 1, .rect = r(5, 0, 400, 600), .tucked = true },
        .{ .id = 2, .rect = r(20, 0, 400, 600), .tucked = false },
    };
    const first = plan(&before, &after, null, 0, duration_ms);
    const where = first.rectAt(2, 100).?;
    // Back again, 100 ms in: card 1 comes forward from its tucked rect, and
    // card 2 is tucked (no slide); but were card 2 to stay on show, it would
    // start from `where`, not from its slot.
    const again = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false },
        .{ .id = 2, .rect = r(400, 0, 400, 600), .tucked = false },
    };
    const second = plan(&after, &again, &first, 100, duration_ms);
    try testing.expectEqual(@as(usize, 2), second.len);
    try testing.expectEqual(where, second.rectAt(2, 0).?);
    try testing.expectEqual(r(5, 0, 400, 600), second.rectAt(1, 0).?);
}

test "runsChanged: a resize or a new pane alone is not a slide" {
    const a = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false },
        .{ .id = 2, .rect = r(400, 0, 400, 600), .tucked = false },
    };
    const b = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 500, 600), .tucked = false },
        .{ .id = 2, .rect = r(500, 0, 500, 600), .tucked = false },
        .{ .id = 3, .rect = r(900, 0, 400, 600), .tucked = true },
    };
    try testing.expect(!runsChanged(&a, &b));
}

test "hold: a tucked card keeps the size it last had on show" {
    // On show at 400 wide, then tucked into a 450-wide slot: held at 400.
    const shown: Placed = .{ .id = 1, .rect = r(400, 0, 400, 600), .tucked = false };
    const s = hold(null, shown, r(780, 0, 450, 600));
    try testing.expectEqual(Size{ .w = 400, .h = 600 }, s);
    // The row reflows around it (a window resize): still 400, whatever the
    // slot says, and it sits at its tucked place.
    const tucked: Placed = .{ .id = 1, .rect = heldRect(r(780, 0, 450, 600), s), .tucked = true };
    const again = hold(s, tucked, r(700, 0, 380, 520));
    try testing.expectEqual(s, again);
    try testing.expectEqual(r(700, 0, 400, 600), heldRect(r(700, 0, 380, 520), again));
    // Never on show: it takes its slot's size, once.
    try testing.expectEqual(Size{ .w = 380, .h = 520 }, hold(null, null, r(700, 0, 380, 520)));
}

test "plan: a held card comes forward at its held size and resizes at the end" {
    const before = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 450, 600), .tucked = false },
        .{ .id = 2, .rect = heldRect(r(440, 0, 450, 600), .{ .w = 375, .h = 600 }), .tucked = true },
    };
    const after = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 450, 600), .tucked = true },
        .{ .id = 2, .rect = r(10, 0, 450, 600), .tucked = false },
    };
    const s = plan(&before, &after, null, 0, duration_ms);
    try testing.expectEqual(@as(usize, 1), s.len);
    try testing.expectEqual(@as(i32, 375), s.rectAt(2, duration_ms / 2).?.width());
    try testing.expectEqual(r(10, 0, 450, 600), s.rectAt(2, duration_ms).?);
}
