//! The carousel slide (T2102, a slice of T2101): Mac `PaneStageView`
//! (86b7e3410), as the numbers the window's placement reads.
//!
//! When a stack's run changes - a strip clicked, focus moved onto a tucked
//! pane - the cards on show do not jump to their new slots: they glide there,
//! the way Mac's do. A card that keeps its size is only ever
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
//! A card that goes BEHIND the run slides too (T2186): from where it was on
//! show to its tucked place at the stack's edge, at the size it is held at,
//! and is hidden only when the slide ends - so a fold reads as the card
//! tucking itself away, not as a pane vanishing. And a slide a drag started (a
//! fold or an unfold under the hand) is a `resize` slide: the cards on show
//! pass through every width between the old layout and the new one, the way
//! the drag itself resizes them on every move, instead of holding their old
//! size and snapping when the slide ends. While a drag is under way the
//! slide's targets follow the hand (`Slide.retarget`).
//!
//! The motion itself is Mac's a81db68f9 follower (T2268), not a curve with a
//! duration: every frame each card's edges close `1 - exp(-dt / 45 ms)` of the
//! way on where the layout puts the card NOW - about 90% in 0.1 s - and snap
//! onto it within half a pixel. A drag that moves the target mid-glide is
//! followed from wherever the card is drawn, without a restart; a glide that
//! catches up under a drag rests until the hand moves again, and ends only
//! once the drag is over.
//!
//! Pure, so the tests need no window: the follower, which cards slide, and where
//! each one is at a given moment.

const std = @import("std");
const testing = std.testing;
const grid = @import("pane_stack_grid.zig");
const PxRect = grid.PxRect;
const Id = grid.Id;

/// How quickly a glide closes on its target (T2268; Mac `PaneStageView.glideTime`,
/// a81db68f9): every frame each edge goes `1 - exp(-dt / glide_ms)` of the way
/// from where it is drawn to where the layout puts it NOW - about 90% in 0.1 s.
/// There is no duration: a glide is over when every card has caught up, and a
/// target that moves (a drag reshaping the row) is simply followed.
pub const glide_ms: f64 = 45;

/// An edge within this many pixels of its target is snapped onto it (Mac's
/// 0.5 pt), so a glide ends instead of creeping forever.
pub const snap_px: f64 = 0.5;

/// The time constant for a glide stretched to last about `slide_ms`, for an
/// acceptance script that has to catch a card mid-motion
/// (`GHOZTTY_STACK_SLIDE_MS`): scaled from Mac's old 380 ms slide, which the
/// follower replaced at about the same feel, so 2000 ms is a glide about five
/// times slower and 0 is none.
pub fn stretchedGlideMs(slide_ms: f64) f64 {
    return @max(slide_ms, 0) * glide_ms / 380;
}

/// The fraction of the way to its target an edge goes in `dt_ms`, for a glide
/// of time constant `tau_ms`. No time constant is no glide: all the way.
pub fn followK(dt_ms: f64, tau_ms: f64) f64 {
    if (tau_ms <= 0) return 1;
    if (dt_ms <= 0) return 0;
    return 1 - @exp(-dt_ms / tau_ms);
}

/// One edge one frame on: `k` of the way from `a` to `b`, or onto `b` once it
/// is within `snap_px`.
pub fn follow(a: f64, b: f64, k: f64) f64 {
    if (@abs(b - a) < snap_px) return b;
    return a + (b - a) * k;
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

/// One card's glide: the pane rect it started from, where the layout puts it
/// now, and where it is drawn (each edge on its own, unrounded).
pub const Card = struct {
    id: Id,
    from: PxRect,
    to: PxRect,
    drawn: Edges,
};

/// A rect's four edges as the glide carries them, in fractional pixels.
pub const Edges = struct {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,

    pub fn of(px: PxRect) Edges {
        return .{
            .left = @floatFromInt(px.left),
            .top = @floatFromInt(px.top),
            .right = @floatFromInt(px.right),
            .bottom = @floatFromInt(px.bottom),
        };
    }

    pub fn round(e: Edges) PxRect {
        return .{
            .left = @intFromFloat(@round(e.left)),
            .top = @intFromFloat(@round(e.top)),
            .right = @intFromFloat(@round(e.right)),
            .bottom = @intFromFloat(@round(e.bottom)),
        };
    }

    fn eql(e: Edges, px: PxRect) bool {
        return std.meta.eql(e, of(px));
    }
};

/// The most cards one slide tracks; a window holds far fewer panes.
pub const max_cards = 64;

pub const Slide = struct {
    cards: [max_cards]Card = undefined,
    len: usize = 0,
    /// The glide's time constant (`glide_ms`, or a test's stretched one).
    tau_ms: f64 = glide_ms,
    /// A drag's slide: sizes move with positions (see `rectOf`).
    resize: bool = false,

    pub fn items(self: *const Slide) []const Card {
        return self.cards[0..self.len];
    }

    fn find(self: *const Slide, id: Id) ?Card {
        for (self.items()) |c| if (c.id == id) return c;
        return null;
    }

    /// Where card `id`'s pane is drawn now, or null when it is not sliding -
    /// not in this glide, or caught up with its slot, where it sits like any
    /// other card. A card going behind the run that has caught up is its strip
    /// (Mac `stepGlide`: "a card that reached its strip is the strip"), so it
    /// is hidden though the glide may still be resting under a drag. See
    /// `rectOf` for the shape.
    pub fn rect(self: *const Slide, id: Id) ?PxRect {
        const c = self.find(id) orelse return null;
        if (c.drawn.eql(c.to)) return null;
        return rectOf(c, self.resize);
    }

    /// The card that card `id` shows now, or null when it is not sliding (see
    /// `rect`). See `cardOf`.
    pub fn cardRect(self: *const Slide, id: Id) ?PxRect {
        const c = self.find(id) orelse return null;
        if (c.drawn.eql(c.to)) return null;
        return cardOf(c, self.resize);
    }

    /// Where card `id`'s pane is drawn, caught up or not; null when this glide
    /// does not carry it.
    pub fn placed(self: *const Slide, id: Id) ?PxRect {
        const c = self.find(id) orelse return null;
        return rectOf(c, self.resize);
    }

    /// One frame, `dt_ms` after the last: every edge of every card eases
    /// toward its target (Mac `PaneStageView.stepGlide`). True once every card
    /// has caught up.
    pub fn step(self: *Slide, dt_ms: f64) bool {
        const k = followK(dt_ms, self.tau_ms);
        for (self.cards[0..self.len]) |*c| {
            const to = Edges.of(c.to);
            c.drawn = .{
                .left = follow(c.drawn.left, to.left, k),
                .top = follow(c.drawn.top, to.top, k),
                .right = follow(c.drawn.right, to.right, k),
                .bottom = follow(c.drawn.bottom, to.bottom, k),
            };
        }
        return self.settled();
    }

    /// Every card is where the layout puts it. Under a drag a settled glide
    /// RESTS - the next layout the hand makes starts it again - and only once
    /// the drag is over does catching up end it (Mac `isGesturing`).
    pub fn settled(self: *const Slide) bool {
        for (self.items()) |c| if (!c.drawn.eql(c.to)) return false;
        return true;
    }

    /// Point every sliding card at where the layout puts it NOW (T2186): a
    /// drag goes on reshaping the row while the fold's glide runs, and each
    /// card eases toward the hand's layout from where it is drawn, rather than
    /// the one at the fold. `now` holds each card's current placement (a
    /// tucked card's held rect). True when a target moved.
    pub fn retarget(self: *Slide, now: []const Placed) bool {
        var moved = false;
        for (self.cards[0..self.len]) |*c| {
            for (now) |p| if (p.id == c.id) {
                if (!std.meta.eql(c.to, p.rect)) moved = true;
                c.to = p.rect;
                break;
            };
        }
        return moved;
    }

    /// Where a gutter laid out at `gutter` is drawn while the cards glide
    /// (T2270; Mac `PaneStageView.shownGutter`, a81db68f9): moved along with
    /// the card whose edge it is, as far as that card has got. `across_x`: the
    /// cards sit side by side and the gutter runs down between them. An edge
    /// within `tol_px` of the gutter's side is that card's (Mac's 1.5 pt).
    /// Null when no card in this glide has that gutter for an edge.
    pub fn shownGutter(self: *const Slide, gutter: PxRect, across_x: bool, tol_px: i32) ?PxRect {
        for (self.items()) |c| {
            const target = c.to;
            const shown = cardOf(c, self.resize);
            const offset: i32 = if (across_x) blk: {
                if (target.bottom <= gutter.top or target.top >= gutter.bottom) continue;
                if (@abs(target.right - gutter.left) <= tol_px) break :blk shown.right - target.right;
                if (@abs(target.left - gutter.right) <= tol_px) break :blk shown.left - target.left;
                continue;
            } else blk: {
                if (target.right <= gutter.left or target.left >= gutter.right) continue;
                if (@abs(target.bottom - gutter.top) <= tol_px) break :blk shown.bottom - target.bottom;
                if (@abs(target.top - gutter.bottom) <= tol_px) break :blk shown.top - target.top;
                continue;
            };
            return if (across_x)
                .{ .left = gutter.left + offset, .top = gutter.top, .right = gutter.right + offset, .bottom = gutter.bottom }
            else
                .{ .left = gutter.left, .top = gutter.top + offset, .right = gutter.right, .bottom = gutter.bottom + offset };
        }
        return null;
    }
};

/// Where `c`'s pane is drawn. A click's glide moves its origin and holds the
/// size it slid FROM until the glide is over, so a card that changes size
/// resizes once, at the end. With `resize` (a drag's glide, T2186) every edge
/// moves, so the size passes through each width on the way.
pub fn rectOf(c: Card, resize: bool) PxRect {
    if (c.drawn.eql(c.to)) return c.to;
    const d = c.drawn.round();
    if (resize) return d;
    return .{
        .left = d.left,
        .top = d.top,
        .right = d.left + c.from.width(),
        .bottom = d.top + c.from.height(),
    };
}

/// The card `c` shows (T2187; Mac `PaneCardView.apply`'s resizing slide): at
/// the same place as its pane (`rectOf`), but already at its slot's size. Its
/// pane is held at the old size until the glide ends, so the card is what is
/// SEEN of it: a pane that shrinks is cut to its new card at once rather than
/// covering its neighbours for the whole glide - which hid a pane unfolding
/// beside it until the very end, so the unfold looked instant - and one that
/// grows shows its card's backdrop beyond it. A `resize` glide (a drag's,
/// T2186) resizes the pane on the way, so card and pane agree.
pub fn cardOf(c: Card, resize: bool) PxRect {
    const p = rectOf(c, resize);
    if (resize) return p;
    return .{ .left = p.left, .top = p.top, .right = p.left + c.to.width(), .bottom = p.top + c.to.height() };
}

/// What of a held pane window shows inside its card: `window` cut to `card`,
/// or null when the window already fits (nothing to cut).
pub fn clip(window: Size, card: Size) ?Size {
    if (window.w <= card.w and window.h <= card.h) return null;
    return .{ .w = @max(@min(window.w, card.w), 1), .h = @max(@min(window.h, card.h), 1) };
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
/// where it is ON SCREEN - its place in `current` (a glide under way) when it
/// has one, else its last placement - so a slide that interrupts another
/// carries on from there. A card that comes forward
/// from behind the run starts at its tucked card's rect, which lies under the
/// run at its stack's edge. A card that goes behind the run (on show before,
/// tucked after) slides to its tucked rect and is hidden when the slide ends
/// (T2186); a card that stays tucked does not slide. `resize`: a drag's slide
/// (see `rectOf`). `tau_ms`: the glide's time constant (`glide_ms`).
pub fn plan(
    before: []const Placed,
    after: []const Placed,
    current: ?*const Slide,
    tau_ms: f64,
    resize: bool,
) Slide {
    var out: Slide = .{ .tau_ms = tau_ms, .resize = resize };
    for (after) |a| {
        const last: ?Placed = for (before) |b| {
            if (b.id == a.id) break b;
        } else null;
        // Tucked now: it slides only if it was on show (it is going away).
        if (a.tucked) if (last) |b| if (b.tucked) continue;
        const from = blk: {
            if (current) |cur| if (cur.placed(a.id)) |rect| break :blk rect;
            if (last) |b| break :blk b.rect;
            break :blk null;
        } orelse continue;
        if (std.meta.eql(from, a.rect)) continue;
        if (out.len == max_cards) break;
        out.cards[out.len] = .{ .id = a.id, .from = from, .to = a.rect, .drawn = Edges.of(from) };
        out.len += 1;
    }
    return out;
}

// -- tests -------------------------------------------------------------------

fn r(left: i32, top: i32, w: i32, h: i32) PxRect {
    return .{ .left = left, .top = top, .right = left + w, .bottom = top + h };
}

/// Run `s` at 16 ms frames until it settles; the frames it took.
fn runOut(s: *Slide) usize {
    var frames: usize = 1;
    while (!s.step(16)) : (frames += 1) if (frames > 1000) break;
    return frames;
}

test "followK: Mac's follower - about 90% of the way in 0.1 s, whatever the frame rate" {
    // One 100 ms step closes 1 - e^(-100/45) = 89% of the gap.
    const k = followK(100, glide_ms);
    try testing.expect(k > 0.88 and k < 0.9);
    // Six 16.7 ms frames close the same gap as one 100 ms step: the follower
    // is frame-rate independent.
    var gap: f64 = 1;
    for (0..6) |_| gap *= 1 - followK(100.0 / 6.0, glide_ms);
    try testing.expectApproxEqAbs(1 - k, gap, 1e-9);
    // No time, no motion; no time constant, all the way.
    try testing.expectEqual(@as(f64, 0), followK(0, glide_ms));
    try testing.expectEqual(@as(f64, 1), followK(16, 0));
}

test "follow: an edge within half a pixel snaps onto its target" {
    try testing.expectEqual(@as(f64, 100), follow(99.6, 100, 0.01));
    try testing.expectEqual(@as(f64, 100), follow(100.4, 100, 0.01));
    try testing.expectEqual(@as(f64, 50), follow(0, 100, 0.5));
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
    var s = plan(&before, &after, null, glide_ms, false);
    // The cards on show afterwards slide, and so does card 2, going behind
    // the run (T2186); card 1 is already at its tucked place.
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(@as(Id, 2), s.cards[0].id);
    try testing.expectEqual(@as(Id, 3), s.cards[1].id);
    try testing.expectEqual(r(780, 0, 400, 600), s.cards[1].from);
    try testing.expectEqual(@as(Id, 4), s.cards[2].id);
    // It starts where the cards were.
    try testing.expectEqual(r(790, 0, 400, 600), s.placed(4).?);
    // Mid-glide each card is between its two places, at its own size: a
    // move, never a resize.
    try testing.expect(!s.step(30));
    const mid = s.placed(4).?;
    try testing.expect(mid.left < 790 and mid.left > 430);
    try testing.expectEqual(@as(i32, 400), mid.width());
    try testing.expectEqual(@as(i32, 600), mid.height());
    // It catches up, and is exactly there.
    _ = runOut(&s);
    try testing.expect(s.settled());
    try testing.expectEqual(r(430, 0, 400, 600), s.placed(4).?);
    try testing.expectEqual(r(20, 0, 400, 600), s.placed(2).?);
    // A card that is not sliding has no slide rect, and one that has caught
    // up is no longer sliding: it sits at its slot.
    try testing.expectEqual(@as(?PxRect, null), s.rect(1));
    try testing.expectEqual(@as(?PxRect, null), s.rect(4));
}

test "step: 90% of the way in 0.1 s, settled within about a third of a second" {
    const before = [_]Placed{.{ .id = 1, .rect = r(1000, 0, 400, 600), .tucked = true }};
    const after = [_]Placed{.{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false }};
    var s = plan(&before, &after, null, glide_ms, false);
    _ = s.step(100);
    // 1000 px to go: about 110 left after 0.1 s.
    const left = s.placed(1).?.left;
    try testing.expect(left > 100 and left < 120);
    // 16 ms frames from the start: it settles, by snapping, well inside 0.4 s.
    var t = plan(&before, &after, null, glide_ms, false);
    const frames = runOut(&t);
    try testing.expect(frames * 16 <= 400);
    try testing.expectEqual(r(0, 0, 400, 600), t.placed(1).?);
}

test "plan: a card that changes size holds its old size until it has caught up" {
    const before = [_]Placed{.{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false }};
    const after = [_]Placed{.{ .id = 1, .rect = r(100, 0, 500, 600), .tucked = true }};
    var s = plan(&before, &after, null, glide_ms, false);
    _ = s.step(40);
    const mid = s.placed(1).?;
    try testing.expectEqual(@as(i32, 400), mid.width());
    try testing.expect(mid.left > 0 and mid.left < 100);
    // One size change in the whole glide, at its end.
    _ = runOut(&s);
    try testing.expectEqual(r(100, 0, 500, 600), s.placed(1).?);
}

test "cardOf: an unfold cuts the widening neighbour to its new card at once (T2187)" {
    // A | B with B folded: A fills the row. B unfolds; A keeps its place and
    // goes from 900 to 450 wide, B slides in from the row's edge.
    const before = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 900, 600), .tucked = false },
        .{ .id = 2, .rect = heldRect(r(880, 0, 450, 600), .{ .w = 375, .h = 600 }), .tucked = true },
    };
    const after = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 450, 600), .tucked = false },
        .{ .id = 2, .rect = r(450, 0, 450, 600), .tucked = false },
    };
    var s = plan(&before, &after, null, glide_ms, false);
    try testing.expectEqual(@as(usize, 2), s.len);
    _ = s.step(16);
    // A's pane is held at 900 (no resize mid-glide) - and before T2187 that
    // was all there was of it, covering B everywhere B could be.
    try testing.expectEqual(@as(i32, 900), s.placed(1).?.width());
    // Its card is 450 from the first frame, so B's way in is not under it.
    const card_a = s.cardRect(1).?;
    try testing.expectEqual(r(0, 0, 450, 600), card_a);
    const card_b = s.cardRect(2).?;
    try testing.expect(card_b.left > 450 and card_b.left < 880);
    try testing.expect(card_a.right <= card_b.left);
    try testing.expectEqual(@as(i32, 450), card_b.width());
    // The cut: A's 900-wide window shows 450 of itself; B's 375-wide window
    // fits its 450 card and is not cut.
    try testing.expectEqual(Size{ .w = 450, .h = 600 }, clip(.{ .w = 900, .h = 600 }, .{ .w = card_a.width(), .h = 600 }).?);
    try testing.expectEqual(@as(?Size, null), clip(.{ .w = 375, .h = 600 }, .{ .w = card_b.width(), .h = 600 }));
    // At the end card and pane agree, and neither is sliding any more.
    _ = runOut(&s);
    try testing.expectEqual(r(0, 0, 450, 600), s.placed(1).?);
    try testing.expectEqual(r(450, 0, 450, 600), s.placed(2).?);
    try testing.expectEqual(@as(?PxRect, null), s.cardRect(2));
    // A drag's glide resizes the pane on the way: its card is the pane.
    var g = plan(&before, &after, null, glide_ms, true);
    _ = g.step(16);
    try testing.expectEqual(g.rect(1).?, g.cardRect(1).?);
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
    var first = plan(&before, &after, null, glide_ms, false);
    _ = first.step(20);
    const where = first.placed(2).?;
    // Back again, 20 ms in: both cards carry on from where the first glide
    // has them, not from their slots.
    const again = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false },
        .{ .id = 2, .rect = r(400, 0, 400, 600), .tucked = false },
    };
    const second = plan(&after, &again, &first, glide_ms, false);
    try testing.expectEqual(@as(usize, 2), second.len);
    try testing.expectEqual(where, second.placed(2).?);
    // Card 1 was sliding behind the run (T2186): it comes back from where
    // that glide had it, not from its tucked place.
    try testing.expectEqual(first.placed(1).?, second.placed(1).?);
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
    var s = plan(&before, &after, null, glide_ms, false);
    // Card 2 comes forward; card 1 goes behind the run but is already at its
    // tucked place.
    try testing.expectEqual(@as(usize, 1), s.len);
    _ = s.step(30);
    try testing.expectEqual(@as(i32, 375), s.placed(2).?.width());
    _ = runOut(&s);
    try testing.expectEqual(r(10, 0, 450, 600), s.placed(2).?);
}

test "plan: a fold under a drag - the folding card tucks away, the others pass through every width" {
    // P | s1 | s2, the root divider dragged right until s2 folds (T2186):
    // P grows, s1 is pushed right and narrows, s2 tucks at the right edge.
    const before = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 490, 600), .tucked = false },
        .{ .id = 2, .rect = r(500, 0, 490, 600), .tucked = false },
        .{ .id = 3, .rect = r(1000, 0, 490, 600), .tucked = false },
    };
    const after = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 1000, 600), .tucked = false },
        .{ .id = 2, .rect = r(1010, 0, 470, 600), .tucked = false },
        .{ .id = 3, .rect = r(1480, 0, 490, 600), .tucked = true },
    };
    try testing.expect(runsChanged(&before, &after));
    var s = plan(&before, &after, null, glide_ms, true);
    try testing.expectEqual(@as(usize, 3), s.len);
    // P widens through the glide - no 490 -> 1000 jump at its end.
    var last_w: i32 = 490;
    var steps: usize = 0;
    var mid: ?PxRect = null;
    while (!s.step(8)) {
        const w = s.placed(1).?.width();
        try testing.expect(w >= last_w and w <= 1000);
        if (w != last_w) steps += 1;
        last_w = w;
        if (mid == null and w > 745) mid = s.placed(3).?;
    }
    try testing.expect(steps >= 5);
    // s2 slides to its tucked place at its own size, and is there at the end.
    try testing.expect(mid.?.left > 1000 and mid.?.left < 1480);
    try testing.expectEqual(@as(i32, 490), mid.?.width());
    try testing.expectEqual(r(1480, 0, 490, 600), s.placed(3).?);
    // A click's glide (no resize) still holds sizes, as T2102 has it.
    var click = plan(&before, &after, null, glide_ms, false);
    _ = click.step(30);
    try testing.expectEqual(@as(i32, 490), click.placed(1).?.width());
}

test "retarget: the glide eases toward the hand's latest layout, from where it is drawn" {
    const before = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 490, 600), .tucked = false },
        .{ .id = 2, .rect = r(500, 0, 490, 600), .tucked = false },
    };
    const after = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 980, 600), .tucked = false },
        .{ .id = 2, .rect = r(980, 0, 490, 600), .tucked = true },
    };
    var s = plan(&before, &after, null, glide_ms, true);
    _ = s.step(30);
    const drawn = s.placed(1).?;
    // The drag moves on: P's slot is a little wider now. Nothing jumps: the
    // card is still where it was drawn, and heads for the new target.
    const moved = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 990, 600), .tucked = false },
        .{ .id = 2, .rect = r(990, 0, 490, 600), .tucked = true },
    };
    try testing.expect(s.retarget(&moved));
    try testing.expectEqual(drawn, s.placed(1).?);
    _ = runOut(&s);
    try testing.expectEqual(r(0, 0, 990, 600), s.placed(1).?);
    try testing.expectEqual(r(990, 0, 490, 600), s.placed(2).?);
    // A retarget never adds a card the slide does not carry, and one that
    // moves nothing says so.
    try testing.expectEqual(@as(usize, 2), s.len);
    try testing.expect(!s.retarget(&moved));
}

test "settled: a glide that has caught up rests, and a moved target wakes it" {
    const before = [_]Placed{.{ .id = 1, .rect = r(0, 0, 490, 600), .tucked = false }};
    const after = [_]Placed{.{ .id = 1, .rect = r(0, 0, 900, 600), .tucked = true }};
    var s = plan(&before, &after, null, glide_ms, true);
    _ = runOut(&s);
    try testing.expect(s.settled());
    // Resting: further frames move nothing, and the card that went behind
    // the run is its strip - not sliding, so the window hides it.
    try testing.expect(s.step(16));
    try testing.expectEqual(r(0, 0, 900, 600), s.placed(1).?);
    try testing.expectEqual(@as(?PxRect, null), s.rect(1));
    // The hand moves the layout: no longer settled, and it follows.
    const moved = [_]Placed{.{ .id = 1, .rect = r(0, 0, 950, 600), .tucked = true }};
    _ = s.retarget(&moved);
    try testing.expect(!s.settled());
    try testing.expect(!s.step(16));
    const w = s.placed(1).?.width();
    try testing.expect(w > 900 and w < 950);
}

test "stretchedGlideMs: a stretched slide is a slower glide, and 0 is none" {
    try testing.expectApproxEqAbs(glide_ms, stretchedGlideMs(380), 1e-9);
    try testing.expect(stretchedGlideMs(2000) > 5 * glide_ms);
    try testing.expectEqual(@as(f64, 0), stretchedGlideMs(0));
    // Stretched to 2 s, a 400 px glide is still in motion half a second in.
    const before = [_]Placed{.{ .id = 1, .rect = r(400, 0, 400, 600), .tucked = true }};
    const after = [_]Placed{.{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false }};
    var s = plan(&before, &after, null, stretchedGlideMs(2000), false);
    var t: f64 = 0;
    while (t < 500) : (t += 16) _ = s.step(16);
    try testing.expect(!s.settled());
    try testing.expect(s.placed(1).?.left > 0);
}

test "a zero time constant is no glide: the first frame lands" {
    const before = [_]Placed{.{ .id = 1, .rect = r(1000, 0, 400, 600), .tucked = true }};
    const after = [_]Placed{.{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false }};
    var s = plan(&before, &after, null, 0, false);
    try testing.expect(s.step(16));
    try testing.expectEqual(r(0, 0, 400, 600), s.placed(1).?);
}

test "shownGutter: mid-glide the gutter is drawn beside the card whose edge it is" {
    // Card 1 widens from 400 to 600 under a drag; its right edge is the
    // gutter at 600..606, and card 2 starts beyond it.
    const before = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false },
        .{ .id = 2, .rect = r(406, 0, 400, 600), .tucked = false },
    };
    const after = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 600, 600), .tucked = false },
        .{ .id = 2, .rect = r(606, 0, 200, 600), .tucked = false },
    };
    var s = plan(&before, &after, null, glide_ms, true);
    _ = s.step(16);
    const gutter = r(600, 0, 6, 600);
    const at = s.shownGutter(gutter, true, 2).?;
    const edge = s.placed(1).?.right;
    try testing.expect(edge > 400 and edge < 600);
    // Moved by exactly as far as the card still has to go, only along x.
    try testing.expectEqual(edge, at.left);
    try testing.expectEqual(@as(i32, 6), at.right - at.left);
    try testing.expectEqual(gutter.top, at.top);
    try testing.expectEqual(gutter.bottom, at.bottom);
    // Caught up: the gutter is where the layout puts it.
    while (!s.step(16)) {}
    try testing.expectEqual(gutter, s.shownGutter(gutter, true, 2).?);
}

test "shownGutter: a card on the far side of the gutter carries it by its leading edge" {
    const before = [_]Placed{.{ .id = 2, .rect = r(406, 0, 400, 600), .tucked = false }};
    const after = [_]Placed{.{ .id = 2, .rect = r(206, 0, 600, 600), .tucked = false }};
    var s = plan(&before, &after, null, glide_ms, true);
    _ = s.step(16);
    const at = s.shownGutter(r(200, 0, 6, 600), true, 2).?;
    try testing.expectEqual(s.placed(2).?.left, at.right);
}

test "shownGutter: rows stacked top to bottom move a gutter that runs across" {
    const before = [_]Placed{.{ .id = 1, .rect = r(0, 0, 800, 300), .tucked = false }};
    const after = [_]Placed{.{ .id = 1, .rect = r(0, 0, 800, 500), .tucked = false }};
    var s = plan(&before, &after, null, glide_ms, true);
    _ = s.step(16);
    const gutter = r(0, 500, 800, 6);
    const at = s.shownGutter(gutter, false, 2).?;
    try testing.expectEqual(s.placed(1).?.bottom, at.top);
    try testing.expectEqual(gutter.left, at.left);
    // The across-x reading of the same gutter finds no card edge.
    try testing.expectEqual(@as(?PxRect, null), s.shownGutter(gutter, true, 2));
}

test "shownGutter: a gutter no gliding card borders is not moved" {
    const before = [_]Placed{.{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false }};
    const after = [_]Placed{.{ .id = 1, .rect = r(0, 0, 600, 600), .tucked = false }};
    var s = plan(&before, &after, null, glide_ms, true);
    _ = s.step(16);
    // Not at the card's edge, and beside it but in another row.
    try testing.expectEqual(@as(?PxRect, null), s.shownGutter(r(900, 0, 6, 600), true, 2));
    try testing.expectEqual(@as(?PxRect, null), s.shownGutter(r(600, 700, 6, 300), true, 2));
}
