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
//! A card going behind the run glides into its STRIP (T2287; Mac a81db68f9's
//! `PaneStageView.target`): its card narrows from where it was on show to the
//! strip's rect, and its pane - held at the size it had on show, so nothing
//! is resized - rides the card's far edge, cut to the card, so its content
//! slides behind the strip's edge rather than vanishing at full size. Coming
//! out is the same in reverse: the card widens out of the strip.
//!
//! Pure, so the tests need no window: the follower, which cards slide, and where
//! each one is at a given moment.

const std = @import("std");
const testing = std.testing;
const grid = @import("pane_stack_grid.zig");
const PxRect = grid.PxRect;
/// A window region's rect, for a caller that keeps one (`PaneView.card_region_cut`).
pub const Rect = PxRect;
const Id = grid.Id;
const Direction = @import("pane_stack_layout.zig").Direction;

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

/// A card as the layout placed it: its full card rect (a tucked card's held
/// rect), and whether it is tucked behind its stack's run (only its strip on
/// show).
pub const Placed = struct {
    id: Id,
    rect: PxRect,
    tucked: bool,
    /// A tucked card's strip (T2287): where its card is drawn once it has
    /// gone in, and where it comes out from.
    strip: ?PxRect = null,
    /// The axis its stack runs along: a horizontal stack's strips are bands
    /// down the cards' leading edges.
    axis: Direction = .horizontal,

    /// Where the glide takes this card (Mac `PaneStageView.target`): its
    /// strip when it is tucked, else its card.
    pub fn target(p: Placed) PxRect {
        if (p.tucked) if (p.strip) |s| return s;
        return p.rect;
    }
};

/// Which corner a strip card's held pane is pinned to (T2287; Mac
/// `PaneCardView.glideAnchor`): its far edge from the strip, so the pane
/// slides behind the strip's edge as the card narrows.
pub const Anchor = enum {
    top_left,
    top_right,
    bottom_left,

    /// For a stack along `axis` whose strip lies on the leading side of the
    /// card (`leads`): pinned trailing (or to the bottom); else leading.
    pub fn of(axis: Direction, strip_leads: bool) Anchor {
        if (!strip_leads) return .top_left;
        return if (axis == .horizontal) .top_right else .bottom_left;
    }
};

/// Whether `strip` lies on the leading side of `card` along `axis` (Mac
/// `PaneStageView.leads`).
pub fn leads(strip: PxRect, card: PxRect, axis: Direction) bool {
    return if (axis == .vertical)
        strip.top + strip.bottom < card.top + card.bottom
    else
        strip.left + strip.right < card.left + card.right;
}

/// How far into its strip a card drawn at `extent` (its smaller side) is
/// (T2287, for T2288's fade; Mac `PaneCardView.collapse`): 0 for a card at
/// least `span` wider than a strip, 1 for one no wider than `strip`.
pub fn collapse(extent: f64, strip: f64, span: f64) f64 {
    if (span <= 0) return if (extent <= strip) 1 else 0;
    return std.math.clamp(1 - (extent - strip) / span, 0, 1);
}

/// The most a strip card's `collapse` moves in one frame (T2442): the fade
/// always gets three frames, however long a frame takes. A 16 ms frame never
/// reaches it - the follower closes 31% of the way, and the zone is the last
/// 120 DIP - so at the frame rate Mac draws at this changes nothing; a 70 ms
/// frame closes 79% and used to cross the whole zone in one, putting the card
/// in its strip with its content still at full strength.
pub const max_fade_step: f64 = 1.0 / 3.0;

/// Where a strip card's fade runs, in pixels (T2442): `strip` and `span` as
/// `collapse` takes them - the window's scale applied to `strip_face`'s DIP.
pub const Fade = struct {
    strip: f64,
    span: f64,
};

/// A strip card's edges one frame on (T2442): `next` - where the follower put
/// them - unless that moves the card's `collapse` more than `max_fade_step`
/// from where `prev` had it; then only as far along the same line as moves it
/// that much. `collapse` is linear in the card's smaller side inside the zone,
/// so the stop is found exactly rather than searched for.
pub fn limitFade(prev: Edges, next: Edges, fade: Fade) Edges {
    const e0 = prev.extent();
    const e1 = next.extent();
    const c0 = collapse(e0, fade.strip, fade.span);
    const c1 = collapse(e1, fade.strip, fade.span);
    if (@abs(c1 - c0) <= max_fade_step + 1e-9) return next;
    if (e1 == e0) return next;
    const c = if (c1 > c0) c0 + max_fade_step else c0 - max_fade_step;
    const e = fade.strip + fade.span * (1 - c);
    const t = std.math.clamp((e - e0) / (e1 - e0), 0, 1);
    return .{
        .left = prev.left + (next.left - prev.left) * t,
        .top = prev.top + (next.top - prev.top) * t,
        .right = prev.right + (next.right - prev.right) * t,
        .bottom = prev.bottom + (next.bottom - prev.bottom) * t,
    };
}

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
    /// Set for a card going into or coming out of its strip (T2287): the
    /// card is drawn at `drawn` (every edge moving, so it narrows or widens)
    /// and its pane is held, pinned to `anchor`. See `StripCard`.
    strip: ?StripCard = null,
};

/// How a card on its way into or out of its strip holds its pane (T2287).
pub const StripCard = struct {
    /// The size the pane is held at; null follows the target's size (a
    /// drag's glide out of a strip, whose target moves with the hand).
    held: ?Size,
    anchor: Anchor,
    /// The axis its stack runs along, which its strip's name reads by
    /// (T2288's face).
    axis: Direction = .horizontal,
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

    /// The smaller side, as `strip_face.collapseOf` measures a card.
    pub fn extent(e: Edges) f64 {
        return @min(e.right - e.left, e.bottom - e.top);
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

/// A strip held at the length it had when the glide found it (T2312).
pub const HeldStrip = struct {
    id: Id,
    length: i32,
};

/// A strip that stays a strip and moves (T2417; Mac 7e2d0a9da, "strips tween
/// rect to rect"): only its strip is drawn on the way - the pane behind it
/// stays hidden - eased edge by edge from where it was drawn to where the
/// layout puts it now, across the stack as well as along it.
pub const StripGlide = struct {
    id: Id,
    to: PxRect,
    drawn: Edges,
};

/// How long `rect` is along a stack running along `axis`.
pub fn along(rect: PxRect, axis: Direction) i32 {
    return if (axis == .vertical) rect.height() else rect.width();
}

/// `tab` cut to `length` along `axis`, kept by its outer edge - the one away
/// from the run (`strip_leads`: the strip lies before it). A tab no longer
/// than `length` is itself.
pub fn heldStrip(tab: PxRect, axis: Direction, strip_leads: bool, length: i32) PxRect {
    if (along(tab, axis) <= length) return tab;
    var t = tab;
    switch (axis) {
        .horizontal => if (strip_leads) {
            t.right = t.left + length;
        } else {
            t.left = t.right - length;
        },
        .vertical => if (strip_leads) {
            t.bottom = t.top + length;
        } else {
            t.top = t.bottom - length;
        },
    }
    return t;
}

pub const Slide = struct {
    cards: [max_cards]Card = undefined,
    len: usize = 0,
    /// The glide's time constant (`glide_ms`, or a test's stretched one).
    tau_ms: f64 = glide_ms,
    /// A drag's slide: sizes move with positions (see `rectOf`).
    resize: bool = false,
    /// Where a strip card's fade runs (T2442), so no frame crosses more than
    /// `max_fade_step` of it; null leaves the follower alone.
    fade: ?Fade = null,
    /// Strips that stay strips and gain their reach under a newcomer (T2312):
    /// each is shown no longer than it was until the glide is over.
    held: [max_cards]HeldStrip = undefined,
    held_len: usize = 0,
    /// Strips that stay strips and move (T2417): see `StripGlide`.
    strips: [max_cards]StripGlide = undefined,
    strips_len: usize = 0,

    pub fn items(self: *const Slide) []const Card {
        return self.cards[0..self.len];
    }

    pub fn stripItems(self: *const Slide) []const StripGlide {
        return self.strips[0..self.strips_len];
    }

    /// Whether this glide carries anything: a card, or a strip on the move.
    pub fn active(self: *const Slide) bool {
        return self.len > 0 or self.strips_len > 0;
    }

    fn findStrip(self: *const Slide, id: Id) ?StripGlide {
        for (self.stripItems()) |s| if (s.id == id) return s;
        return null;
    }

    /// Where strip `id` is drawn on its way to its new rect (T2417), or null
    /// when it is not moving or has caught up.
    pub fn movingStrip(self: *const Slide, id: Id) ?PxRect {
        const s = self.findStrip(id) orelse return null;
        if (s.drawn.eql(s.to)) return null;
        return s.drawn.round();
    }

    /// How long strip `id` is held at along its stack, or null when it is
    /// shown as the layout has it.
    pub fn heldLength(self: *const Slide, id: Id) ?i32 {
        for (self.held[0..self.held_len]) |h| if (h.id == id) return h.length;
        return null;
    }

    /// Where strip `id`, laid out at `tab`, shows while this glide is under
    /// way (T2312; Mac 760272563 `PaneStageView.stepGlide`): a strip gaining
    /// its reach under the strip in front - a pane collapsing between it and
    /// the run - keeps its length until the glide is over, measured from its
    /// OUTER edge, the one that shows. Reaching out sooner put its edge in
    /// the gutter ahead of the newcomer. `strip_leads`: it lies before the
    /// run. Losing the reach is immediate: `tab` is never lengthened.
    ///
    /// A strip on the move (T2417) shows where the glide has it, and a held
    /// length is applied to that eased rect by its outer edge (Mac
    /// `stepGlide`). A tab the glide is not heading for is shown as it is.
    pub fn shownStrip(self: *const Slide, id: Id, tab: PxRect, axis: Direction, strip_leads: bool) PxRect {
        const at = if (self.findStrip(id)) |s|
            (if (std.meta.eql(s.to, tab)) self.movingStrip(id) orelse tab else tab)
        else
            tab;
        const length = self.heldLength(id) orelse return at;
        return heldStrip(at, axis, strip_leads, length);
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

    /// The card `id` is drawn at on its way into or out of its strip (T2288,
    /// for the strip's face over it), and its stack's axis; null when it is
    /// not such a card, or has caught up - a card at its strip IS the strip,
    /// which the window paints, and one out of it is a card like any other.
    pub fn stripFace(self: *const Slide, id: Id) ?struct { card: PxRect, axis: Direction, leads: bool } {
        const c = self.find(id) orelse return null;
        const s = c.strip orelse return null;
        if (c.drawn.eql(c.to)) return null;
        // The pane is pinned away from a strip on its leading side
        // (`Anchor.of`), so the anchor says which side the strip is on.
        return .{ .card = cardOf(c, self.resize), .axis = s.axis, .leads = s.anchor != .top_left };
    }

    /// Whether card `id` is on its way INTO its strip (T2457): a strip card
    /// that has not caught up, drawn longer than where it is headed. Such a
    /// card can carry its pane's last frame instead of the live pane, since
    /// nothing in it changes size on the way.
    pub fn folding(self: *const Slide, id: Id) bool {
        const c = self.find(id) orelse return false;
        if (c.strip == null or c.drawn.eql(c.to)) return false;
        return Edges.of(c.to).extent() < c.drawn.extent();
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
            const next: Edges = .{
                .left = follow(c.drawn.left, to.left, k),
                .top = follow(c.drawn.top, to.top, k),
                .right = follow(c.drawn.right, to.right, k),
                .bottom = follow(c.drawn.bottom, to.bottom, k),
            };
            // A card going into or out of its strip crosses its fade over
            // three frames at least (T2442).
            c.drawn = if (c.strip != null) if (self.fade) |f| limitFade(c.drawn, next, f) else next else next;
        }
        for (self.strips[0..self.strips_len]) |*s| {
            const to = Edges.of(s.to);
            s.drawn = .{
                .left = follow(s.drawn.left, to.left, k),
                .top = follow(s.drawn.top, to.top, k),
                .right = follow(s.drawn.right, to.right, k),
                .bottom = follow(s.drawn.bottom, to.bottom, k),
            };
        }
        return self.settled();
    }

    /// Every card is where the layout puts it. Under a drag a settled glide
    /// RESTS - the next layout the hand makes starts it again - and only once
    /// the drag is over does catching up end it (Mac `isGesturing`).
    pub fn settled(self: *const Slide) bool {
        for (self.items()) |c| if (!c.drawn.eql(c.to)) return false;
        for (self.stripItems()) |s| if (!s.drawn.eql(s.to)) return false;
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
                const to = p.target();
                if (!std.meta.eql(c.to, to)) moved = true;
                c.to = to;
                break;
            };
        }
        for (self.strips[0..self.strips_len]) |*s| {
            for (now) |p| if (p.id == s.id) {
                const to = p.strip orelse break;
                if (!std.meta.eql(s.to, to)) moved = true;
                s.to = to;
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

    /// How far the grid's leading (left) edge is drawn from where the layout
    /// puts it, in pixels (T2406; Mac 7e2d0a9da `PaneStageView.leadingLag`):
    /// the drawn left of the card - or blade (T2417) - laid out leftmost,
    /// less its target's. The pane sidebar's card follows it, so the gutter
    /// between them is the same at every frame. Null with nothing in the
    /// glide.
    pub fn leadingLag(self: *const Slide) ?i32 {
        var to_left: ?i32 = null;
        var lag: i32 = 0;
        for (self.items()) |c| {
            if (to_left == null or c.to.left < to_left.?) {
                to_left = c.to.left;
                lag = cardOf(c, self.resize).left - c.to.left;
            }
        }
        for (self.stripItems()) |g| {
            if (to_left == null or g.to.left < to_left.?) {
                to_left = g.to.left;
                lag = g.drawn.round().left - g.to.left;
            }
        }
        return if (to_left != null) lag else null;
    }
};

/// Where `c`'s pane is drawn. A click's glide moves its origin and holds the
/// size it slid FROM until the glide is over, so a card that changes size
/// resizes once, at the end. With `resize` (a drag's glide, T2186) every edge
/// moves, so the size passes through each width on the way.
///
/// A strip card's pane (T2287) is held at its size and pinned to the drawn
/// card's far edge, whatever the glide: the card narrows or widens around it.
pub fn rectOf(c: Card, resize: bool) PxRect {
    if (c.drawn.eql(c.to)) return c.to;
    const d = c.drawn.round();
    if (c.strip) |s| {
        const size = s.held orelse Size{ .w = c.to.width(), .h = c.to.height() };
        return switch (s.anchor) {
            .top_left => .{ .left = d.left, .top = d.top, .right = d.left + size.w, .bottom = d.top + size.h },
            .top_right => .{ .left = d.right - size.w, .top = d.top, .right = d.right, .bottom = d.top + size.h },
            .bottom_left => .{ .left = d.left, .top = d.bottom - size.h, .right = d.left + size.w, .bottom = d.bottom },
        };
    }
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
///
/// A strip card (T2287) is drawn where the glide has it, every edge moving:
/// it narrows into its strip, or widens out of it.
pub fn cardOf(c: Card, resize: bool) PxRect {
    if (c.strip != null) return if (c.drawn.eql(c.to)) c.to else c.drawn.round();
    const p = rectOf(c, resize);
    if (resize) return p;
    return .{ .left = p.left, .top = p.top, .right = p.left + c.to.width(), .bottom = p.top + c.to.height() };
}

/// What of a held pane window shows inside its card: the part of `window`
/// inside `card`, in the window's own coordinates (a window region), or null
/// when the window already lies inside it (nothing to cut). A strip card's
/// pane (T2287) is pinned to the card's far edge, so its cut can start past
/// the window's own origin.
pub fn clip(window: PxRect, card: PxRect) ?PxRect {
    if (window.left >= card.left and window.top >= card.top and
        window.right <= card.right and window.bottom <= card.bottom) return null;
    const left = @max(window.left, card.left) - window.left;
    const top = @max(window.top, card.top) - window.top;
    return .{
        .left = left,
        .top = top,
        .right = @max(@min(window.right, card.right) - window.left, left + 1),
        .bottom = @max(@min(window.bottom, card.bottom) - window.top, top + 1),
    };
}

/// Whether re-cutting a sliding pane from `prev` to `next` (both window
/// regions, in the window's own coordinates, as `clip` makes them) needs the
/// pane redrawn (T2415). A cut that only shrinks - a card folding into its
/// strip - shows nothing of the pane that was not on show already, and the
/// window's own paint after the layout covers what the pane gave back, so
/// forcing a redraw only buys a GL repaint on every frame of the glide. A
/// cut that grows, or a pane with no cut before, has pixels nobody drew.
pub fn cutNeedsRedraw(prev: ?PxRect, next: PxRect) bool {
    const p = prev orelse return true;
    return next.left < p.left or next.top < p.top or next.right > p.right or next.bottom > p.bottom;
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
/// (T2186); a card that stays tucked does not slide, but its strip moves
/// strip-only when its rect changed (T2417, `StripGlide`). `resize`: a drag's slide
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
        // Tucked now and before: a strip that stays a strip. It gains its
        // reach held (T2312), and it moves strip-only, rect to rect (T2417) -
        // unless the glide under way still has it narrowing into its strip,
        // which carries on from where it is drawn.
        if (a.tucked) if (last) |b| if (b.tucked) {
            holdReach(&out, a, b, current);
            if (!carryStripCard(&out, a, current)) moveStrip(&out, a, b, current);
            continue;
        };
        const from = blk: {
            if (current) |cur| if (cur.find(a.id)) |c| break :blk shownAt(c, cur.resize);
            if (last) |b| break :blk b.target();
            break :blk null;
        } orelse continue;
        const to = a.target();
        if (std.meta.eql(from, to)) continue;
        if (out.len == max_cards) break;
        out.cards[out.len] = .{
            .id = a.id,
            .from = from,
            .to = to,
            .drawn = Edges.of(from),
            .strip = if (last) |b| stripCard(b, a, from, resize) else null,
        };
        out.len += 1;
    }
    return out;
}

/// Hold strip `a` (a strip before, `b`, and after) at the length it shows now
/// - its last strip's, or less if the glide under way holds it shorter - when
/// its strip grew: it takes the reach once the glide is over (T2312).
fn holdReach(out: *Slide, a: Placed, b: Placed, current: ?*const Slide) void {
    const now = a.strip orelse return;
    const was = b.strip orelse return;
    if (a.axis != b.axis) return;
    var length = along(was, a.axis);
    if (current) |cur| if (cur.heldLength(a.id)) |h| {
        length = @min(length, h);
    };
    if (length >= along(now, a.axis)) return;
    if (out.held_len == max_cards) return;
    out.held[out.held_len] = .{ .id = a.id, .length = length };
    out.held_len += 1;
}

/// Carry on a card the glide under way still has gliding into its strip, from
/// where it is drawn, toward its strip as laid out now: a layout that comes
/// mid-fold (a sidebar column shift) never snaps it onto its strip. Whether
/// it was such a card.
fn carryStripCard(out: *Slide, a: Placed, current: ?*const Slide) bool {
    const cur = current orelse return false;
    const c = cur.find(a.id) orelse return false;
    const s = c.strip orelse return false;
    const from = shownAt(c, cur.resize);
    const to = a.target();
    if (std.meta.eql(from, to)) return true;
    if (out.len == max_cards) return true;
    out.cards[out.len] = .{ .id = a.id, .from = from, .to = to, .drawn = Edges.of(from), .strip = s };
    out.len += 1;
    return true;
}

/// Move strip `a` (a strip before, `b`, and after) from where it is drawn -
/// the glide under way's place for it, else its last strip - to its strip
/// now, when the two differ (T2417).
fn moveStrip(out: *Slide, a: Placed, b: Placed, current: ?*const Slide) void {
    const to = a.strip orelse return;
    const from: Edges = blk: {
        if (current) |cur| if (cur.findStrip(a.id)) |s| break :blk s.drawn;
        break :blk Edges.of(b.strip orelse return);
    };
    if (from.eql(to)) return;
    if (out.strips_len == max_cards) return;
    out.strips[out.strips_len] = .{ .id = a.id, .to = to, .drawn = from };
    out.strips_len += 1;
}

/// Where card `c` of a glide under way is on screen, for the next glide to
/// start from: a strip card's card (its pane is pinned inside it), any other
/// card's pane.
fn shownAt(c: Card, resize: bool) PxRect {
    return if (c.strip != null) cardOf(c, resize) else rectOf(c, resize);
}

/// How card `a` holds its pane on its way into or out of its strip (T2287),
/// given its last placement `b` and where it starts `from`; null for a card
/// that does neither, or whose stack draws no strip for it.
fn stripCard(b: Placed, a: Placed, from: PxRect, resize: bool) ?StripCard {
    if (a.tucked and !b.tucked) {
        // Going in: held at the size it is tucked at - the size it had on
        // show - pinned to its far edge from the strip.
        const strip = a.strip orelse return null;
        return .{
            .held = .{ .w = a.rect.width(), .h = a.rect.height() },
            .anchor = Anchor.of(a.axis, leads(strip, from, a.axis)),
            .axis = a.axis,
        };
    }
    if (!a.tucked and b.tucked) {
        // Coming out: a click's glide holds the size it was tucked at, and
        // the pane takes its slot's size once, at the end; a drag's follows
        // the slot as the hand moves it.
        const strip = b.strip orelse return null;
        return .{
            .held = if (resize) null else .{ .w = b.rect.width(), .h = b.rect.height() },
            .anchor = Anchor.of(b.axis, leads(strip, a.rect, b.axis)),
            .axis = b.axis,
        };
    }
    return null;
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

test "plan: the sidebar expanding glides every card over from where it was, each resized once at the end (T2291)" {
    // Two cards side by side; the sidebar's column grows by 200 px, so the
    // grid starts 200 px further right and is 200 px narrower. No run
    // changed - only the grid moved under the cards.
    const before = [_]Placed{
        .{ .id = 1, .rect = r(60, 0, 500, 600), .tucked = false },
        .{ .id = 2, .rect = r(570, 0, 500, 600), .tucked = false },
    };
    const after = [_]Placed{
        .{ .id = 1, .rect = r(260, 0, 400, 600), .tucked = false },
        .{ .id = 2, .rect = r(670, 0, 400, 600), .tucked = false },
    };
    try testing.expect(!runsChanged(&before, &after));
    var s = plan(&before, &after, null, glide_ms, false);
    try testing.expectEqual(@as(usize, 2), s.len);
    // The first frame is where the cards were on screen.
    try testing.expectEqual(r(60, 0, 500, 600), s.placed(1).?);
    _ = s.step(30);
    const mid = s.placed(2).?;
    // On the way: moved, its terminal still the size it had...
    try testing.expectEqual(@as(i32, 500), mid.width());
    try testing.expect(mid.left > 570 and mid.left < 670);
    // ...and cut to the card it is going to, so it never covers its neighbour.
    try testing.expectEqual(@as(i32, 400), s.cardRect(2).?.width());
    _ = runOut(&s);
    try testing.expectEqual(r(260, 0, 400, 600), s.placed(1).?);
    try testing.expectEqual(r(670, 0, 400, 600), s.placed(2).?);
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
    try testing.expectEqual(r(0, 0, 450, 600), clip(s.rect(1).?, card_a).?);
    try testing.expectEqual(@as(?PxRect, null), clip(s.rect(2).?, card_b));
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

test "plan: a card going behind the run narrows into its strip, its pane pinned to the far edge (T2287)" {
    // A | C with C folding into a strip at the row's right edge: the strip
    // trails C's card, so the pane is pinned to its leading edge and slides
    // right, behind the strip.
    const before = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false },
        .{ .id = 3, .rect = r(400, 0, 400, 600), .tucked = false },
    };
    const strip = r(764, 0, 36, 600);
    const after = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 760, 600), .tucked = false },
        .{ .id = 3, .rect = heldRect(r(764, 0, 400, 600), .{ .w = 400, .h = 600 }), .tucked = true, .strip = strip },
    };
    var s = plan(&before, &after, null, glide_ms, false);
    try testing.expectEqual(@as(usize, 2), s.len);
    const c = s.cards[1];
    try testing.expectEqual(@as(Id, 3), c.id);
    // Its glide ends at the strip, not at the full-size card behind it.
    try testing.expectEqual(strip, c.to);
    try testing.expectEqual(Anchor.top_left, c.strip.?.anchor);
    _ = s.step(30);
    const card = s.cardRect(3).?;
    const pane = s.rect(3).?;
    // The card narrows: narrower than it was, wider than the strip.
    try testing.expect(card.width() < 400 and card.width() > 36);
    try testing.expect(card.left > 400 and card.left < 764);
    // The pane keeps its size (no resize) at the card's leading edge, and is
    // cut to the card.
    try testing.expectEqual(@as(i32, 400), pane.width());
    try testing.expectEqual(card.left, pane.left);
    try testing.expectEqual(PxRect{ .left = 0, .top = 0, .right = card.width(), .bottom = 600 }, clip(pane, card).?);
    // Caught up, it is its strip: not sliding, so the window hides the pane
    // and paints the strip.
    _ = runOut(&s);
    try testing.expectEqual(@as(?PxRect, null), s.rect(3));
    try testing.expectEqual(@as(?PxRect, null), s.cardRect(3));
}

test "plan: a strip on the card's leading side pins the pane to the trailing edge (T2287)" {
    // A card folding into a strip at the row's LEFT edge: the content slides
    // left, behind the strip's edge, so it is pinned to the card's right.
    const before = [_]Placed{.{ .id = 1, .rect = r(100, 0, 400, 600), .tucked = false }};
    const after = [_]Placed{.{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = true, .strip = r(0, 0, 36, 600) }};
    var s = plan(&before, &after, null, glide_ms, false);
    try testing.expectEqual(Anchor.top_right, s.cards[0].strip.?.anchor);
    _ = s.step(20);
    const card = s.cardRect(1).?;
    const pane = s.rect(1).?;
    try testing.expectEqual(card.right, pane.right);
    try testing.expectEqual(@as(i32, 400), pane.width());
    // The cut starts inside the window: its leading part is past the card.
    const cut = clip(pane, card).?;
    try testing.expectEqual(card.left - pane.left, cut.left);
    try testing.expectEqual(@as(i32, 400), cut.right);
    // A vertical stack's leading strip lies above: pinned to the bottom.
    try testing.expectEqual(Anchor.bottom_left, Anchor.of(.vertical, true));
    try testing.expect(leads(r(0, 0, 400, 30), r(0, 40, 400, 300), .vertical));
}

test "plan: a card coming out of its strip widens from it, its pane held and pinned (T2287)" {
    const strip = r(764, 0, 36, 600);
    const before = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 760, 600), .tucked = false },
        .{ .id = 3, .rect = r(764, 0, 375, 600), .tucked = true, .strip = strip },
    };
    const after = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false },
        .{ .id = 3, .rect = r(400, 0, 400, 600), .tucked = false },
    };
    var s = plan(&before, &after, null, glide_ms, false);
    const c = s.find(3).?;
    // It starts at its strip, not at the full card hidden behind the run.
    try testing.expectEqual(strip, c.from);
    try testing.expectEqual(Anchor.top_left, c.strip.?.anchor);
    _ = s.step(20);
    const card = s.cardRect(3).?;
    try testing.expect(card.width() > 36 and card.width() < 400);
    // Held at the size it was tucked at until the glide ends.
    try testing.expectEqual(@as(i32, 375), s.rect(3).?.width());
    _ = runOut(&s);
    try testing.expectEqual(r(400, 0, 400, 600), s.placed(3).?);
    // A drag's glide out follows the slot's size instead.
    var g = plan(&before, &after, null, glide_ms, true);
    _ = g.step(20);
    try testing.expectEqual(@as(i32, 400), g.rect(3).?.width());
}

test "stripFace: a card on its way into or out of its strip, by its stack's axis, until it catches up (T2288)" {
    const strip = r(0, 0, 400, 30);
    // A column's card folding up into a strip across the top.
    const before = [_]Placed{.{ .id = 1, .rect = r(0, 40, 400, 300), .tucked = false }};
    const after = [_]Placed{.{ .id = 1, .rect = r(0, 0, 400, 300), .tucked = true, .strip = strip, .axis = .vertical }};
    var s = plan(&before, &after, null, glide_ms, false);
    _ = s.step(20);
    const f = s.stripFace(1).?;
    try testing.expectEqual(s.cardRect(1).?, f.card);
    try testing.expectEqual(Direction.vertical, f.axis);
    // Caught up it is the strip, which the window paints: no face.
    _ = runOut(&s);
    try testing.expectEqual(@as(@TypeOf(s.stripFace(1)), null), s.stripFace(1));
    // A card that only moves along the run has no strip and so no face.
    const b2 = [_]Placed{.{ .id = 2, .rect = r(0, 0, 400, 600), .tucked = false }};
    const a2 = [_]Placed{.{ .id = 2, .rect = r(100, 0, 400, 600), .tucked = false }};
    var m = plan(&b2, &a2, null, glide_ms, false);
    _ = m.step(20);
    try testing.expect(m.cardRect(2) != null);
    try testing.expectEqual(@as(@TypeOf(m.stripFace(2)), null), m.stripFace(2));
}

/// The collapse of strip card `id` as drawn, at `fade`.
fn drawnCollapse(s: *const Slide, id: Id, fade: Fade) f64 {
    const c = s.find(id).?;
    return collapse(c.drawn.extent(), fade.strip, fade.span);
}

test "step: a fold crosses its fade over three frames however long a frame is (T2442)" {
    const fade: Fade = .{ .strip = 48, .span = 120 };
    const before = [_]Placed{.{ .id = 1, .rect = r(400, 0, 400, 600), .tucked = false }};
    const after = [_]Placed{.{ .id = 1, .rect = r(764, 0, 400, 600), .tucked = true, .strip = r(764, 0, 36, 600) }};
    // 70 ms frames, the user's window under a drag (1.49.6 log): unlimited,
    // one frame took the card from outside the zone to past 90% of it.
    var bare = plan(&before, &after, null, glide_ms, false);
    _ = bare.step(70);
    _ = bare.step(70);
    try testing.expect(drawnCollapse(&bare, 1, fade) > 0.9);
    var s = plan(&before, &after, null, glide_ms, false);
    s.fade = fade;
    var partial: usize = 0;
    var last: f64 = 0;
    var frames: usize = 0;
    while (!s.step(70)) : (frames += 1) {
        const c = drawnCollapse(&s, 1, fade);
        try testing.expect(c - last <= max_fade_step + 1e-6);
        if (c > 0 and c < 1) partial += 1;
        last = c;
        try testing.expect(frames < 100);
    }
    try testing.expect(partial >= 2);
    // And it still lands on its strip.
    try testing.expectEqual(r(764, 0, 36, 600), s.cards[0].drawn.round());
}

test "folding: a card on its way into its strip, until it is there; never one coming out (T2457)" {
    const on_show = [_]Placed{.{ .id = 1, .rect = r(400, 0, 400, 600), .tucked = false }};
    const tucked = [_]Placed{.{ .id = 1, .rect = r(764, 0, 400, 600), .tucked = true, .strip = r(764, 0, 36, 600) }};
    var fold = plan(&on_show, &tucked, null, glide_ms, false);
    try testing.expect(fold.folding(1));
    try testing.expect(!fold.folding(2));
    while (!fold.step(16)) {}
    // At its strip it IS the strip, and carries nothing.
    try testing.expect(!fold.folding(1));
    var unfold = plan(&tucked, &on_show, null, glide_ms, false);
    try testing.expect(!unfold.folding(1));
}

test "step: at 60 fps the fade limit never bites - Mac's follower, frame for frame (T2442)" {
    const fade: Fade = .{ .strip = 48, .span = 120 };
    const before = [_]Placed{.{ .id = 1, .rect = r(400, 0, 400, 600), .tucked = false }};
    const after = [_]Placed{.{ .id = 1, .rect = r(764, 0, 400, 600), .tucked = true, .strip = r(764, 0, 36, 600) }};
    var bare = plan(&before, &after, null, glide_ms, false);
    var s = plan(&before, &after, null, glide_ms, false);
    s.fade = fade;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const a = bare.step(16.7);
        const b = s.step(16.7);
        try testing.expectEqual(bare.cards[0].drawn, s.cards[0].drawn);
        try testing.expectEqual(a, b);
    }
}

test "step: an unfold fades its content back in over three frames too (T2442)" {
    const fade: Fade = .{ .strip = 48, .span = 120 };
    const tucked = [_]Placed{.{ .id = 1, .rect = r(764, 0, 400, 600), .tucked = true, .strip = r(764, 0, 36, 600) }};
    const shown = [_]Placed{.{ .id = 1, .rect = r(400, 0, 400, 600), .tucked = false }};
    var s = plan(&tucked, &shown, null, glide_ms, false);
    s.fade = fade;
    var partial: usize = 0;
    var last: f64 = 1;
    var frames: usize = 0;
    while (!s.step(100)) : (frames += 1) {
        const c = drawnCollapse(&s, 1, fade);
        try testing.expect(last - c <= max_fade_step + 1e-6);
        if (c > 0 and c < 1) partial += 1;
        last = c;
        try testing.expect(frames < 100);
    }
    try testing.expect(partial >= 2);
}

test "limitFade: a step inside the cap is the follower's own; past it, stops on the same line (T2442)" {
    const fade: Fade = .{ .strip = 48, .span = 120 };
    const e = struct {
        fn of(left: f64, right: f64) Edges {
            return .{ .left = left, .top = 0, .right = right, .bottom = 600 };
        }
    }.of;
    // 168 -> 140 wide: collapse 0 -> 0.23, under the cap.
    try testing.expectEqual(e(632, 772), limitFade(e(604, 772), e(632, 772), fade));
    // 168 -> 48: capped at collapse 1/3, a card 128 wide, its edges on the line.
    const got = limitFade(e(604, 772), e(724, 772), fade);
    try testing.expectApproxEqAbs(@as(f64, 128), got.extent(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 772), got.right, 1e-9);
    // Wholly outside the zone the follower is untouched.
    try testing.expectEqual(e(300, 772), limitFade(e(0, 772), e(300, 772), fade));
}

test "plan: a card turned back mid-glide carries on from where its card is drawn (T2287)" {
    const strip = r(764, 0, 36, 600);
    const shown = [_]Placed{.{ .id = 3, .rect = r(400, 0, 400, 600), .tucked = false }};
    const tucked = [_]Placed{.{ .id = 3, .rect = r(764, 0, 400, 600), .tucked = true, .strip = strip }};
    var going = plan(&shown, &tucked, null, glide_ms, false);
    _ = going.step(20);
    const drawn = going.cardRect(3).?;
    const back = plan(&tucked, &shown, &going, glide_ms, false);
    try testing.expectEqual(drawn, back.cards[0].from);
    try testing.expect(back.cards[0].strip != null);
}

test "retarget: a card going into its strip follows the strip, not its held card (T2287)" {
    const before = [_]Placed{.{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false }};
    const after = [_]Placed{.{ .id = 1, .rect = r(764, 0, 400, 600), .tucked = true, .strip = r(764, 0, 36, 600) }};
    var s = plan(&before, &after, null, glide_ms, true);
    const moved = [_]Placed{.{ .id = 1, .rect = r(770, 0, 400, 600), .tucked = true, .strip = r(770, 0, 36, 600) }};
    try testing.expect(s.retarget(&moved));
    try testing.expectEqual(r(770, 0, 36, 600), s.cards[0].to);
}

test "collapse: Mac's fade - none until a strip plus the span, all of it at strip width" {
    try testing.expectEqual(@as(f64, 0), collapse(400, 36, 120));
    try testing.expectEqual(@as(f64, 0), collapse(156, 36, 120));
    try testing.expectApproxEqAbs(@as(f64, 0.5), collapse(96, 36, 120), 1e-9);
    try testing.expectEqual(@as(f64, 1), collapse(36, 36, 120));
    try testing.expectEqual(@as(f64, 1), collapse(10, 36, 120));
}

test "clip: a window inside its card is not cut" {
    try testing.expectEqual(@as(?PxRect, null), clip(r(10, 10, 100, 100), r(0, 0, 200, 200)));
    // Bigger than its card: cut to it, from the window's own origin.
    try testing.expectEqual(PxRect{ .left = 0, .top = 0, .right = 450, .bottom = 600 }, clip(r(0, 0, 900, 600), r(0, 0, 450, 600)).?);
}

test "cutNeedsRedraw: a fold's shrinking cut is never redrawn, a growing one is (T2415)" {
    // First cut of the glide: nothing was cut before, so draw it.
    try testing.expect(cutNeedsRedraw(null, r(100, 0, 300, 600)));
    // Folding into a leading strip: the pane rides the card's far edge, so
    // what shows of it narrows from the left, frame on frame.
    const a = clip(r(0, 0, 400, 600), r(100, 0, 300, 600)).?;
    const b = clip(r(-60, 0, 400, 600), r(100, 0, 240, 600)).?;
    try testing.expect(!cutNeedsRedraw(a, b));
    try testing.expect(!cutNeedsRedraw(a, a));
    // Unfolding is the same frames backwards: the cut grows, and the pixels
    // it gives the pane were never drawn.
    try testing.expect(cutNeedsRedraw(b, a));
}

test "plan: a strip that stays a strip keeps its length by its outer edge until the glide is over (T2312, Mac 760272563)" {
    // Trailing stack: strip 3 at the right edge, 24 px; card 2 collapses onto
    // the stack between it and the run, so 3 now reaches 12 px under 2.
    const before = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 400, 600), .tucked = false },
        .{ .id = 2, .rect = r(400, 0, 370, 600), .tucked = false },
        .{ .id = 3, .rect = r(776, 0, 400, 600), .tucked = true, .strip = r(776, 0, 24, 600) },
    };
    const after = [_]Placed{
        .{ .id = 1, .rect = r(0, 0, 740, 600), .tucked = false },
        .{ .id = 2, .rect = r(752, 0, 370, 600), .tucked = true, .strip = r(752, 0, 36, 600) },
        .{ .id = 3, .rect = r(764, 0, 400, 600), .tucked = true, .strip = r(764, 0, 36, 600) },
    };
    var s = plan(&before, &after, null, glide_ms, false);
    try testing.expect(s.len > 0);
    try testing.expectEqual(@as(?i32, 24), s.heldLength(3));
    // Mid-glide its outer edge is where it was, and none of it shows past
    // where it showed before: the reach waits for the newcomer.
    _ = s.step(16);
    try testing.expectEqual(r(776, 0, 24, 600), s.shownStrip(3, r(764, 0, 36, 600), .horizontal, false));
    // The leading side keeps its left edge.
    try testing.expectEqual(r(0, 0, 24, 600), heldStrip(r(0, 0, 36, 600), .horizontal, true, 24));
    try testing.expectEqual(r(0, 0, 600, 24), heldStrip(r(0, 0, 600, 36), .vertical, true, 24));
    try testing.expectEqual(r(0, 12, 600, 24), heldStrip(r(0, 0, 600, 36), .vertical, false, 24));
    // Losing the reach is immediate: a shorter tab is never lengthened.
    try testing.expectEqual(r(776, 0, 12, 600), s.shownStrip(3, r(776, 0, 12, 600), .horizontal, false));
    // A strip not held, and one held by no glide, shows as laid out.
    try testing.expectEqual(r(752, 0, 36, 600), s.shownStrip(2, r(752, 0, 36, 600), .horizontal, false));
    // A glide that interrupts this one holds it no longer than it shows now.
    var shorter = after;
    shorter[2].strip = r(770, 0, 30, 600);
    const later = [_]Placed{ after[0], after[1], .{ .id = 3, .rect = r(764, 0, 400, 600), .tucked = true, .strip = r(760, 0, 40, 600) } };
    const next = plan(&shorter, &later, &s, glide_ms, false);
    try testing.expectEqual(@as(?i32, 24), next.heldLength(3));
    // A strip that does not grow is not held.
    const same = plan(&after, &after, null, glide_ms, false);
    try testing.expectEqual(@as(?i32, null), same.heldLength(3));
}

test "plan: a sidebar column shift moves a stays-tucked strip rect to rect, its pane hidden (T2417, Mac 7e2d0a9da)" {
    // A leading stack: strip 3 at the grid's left edge, card 1 on show. The
    // sidebar expands and the grid's left edge moves 200 px right.
    const before = [_]Placed{
        .{ .id = 3, .rect = r(0, 0, 400, 600), .tucked = true, .strip = r(0, 0, 36, 600) },
        .{ .id = 1, .rect = r(48, 0, 752, 600), .tucked = false },
    };
    const after = [_]Placed{
        .{ .id = 3, .rect = r(200, 0, 400, 600), .tucked = true, .strip = r(200, 0, 36, 600) },
        .{ .id = 1, .rect = r(248, 0, 552, 600), .tucked = false },
    };
    var s = plan(&before, &after, null, glide_ms, false);
    try testing.expect(s.active());
    try testing.expectEqual(@as(usize, 1), s.strips_len);
    // Strip-only: the tucked pane is never placed by the glide, so it stays
    // hidden behind its strip.
    try testing.expectEqual(@as(?PxRect, null), s.rect(3));
    try testing.expectEqual(@as(?PxRect, null), s.cardRect(3));
    const to = r(200, 0, 36, 600);
    // Before the first frame it is where it was drawn.
    try testing.expectEqual(r(0, 0, 36, 600), s.shownStrip(3, to, .horizontal, true));
    // It passes through places between, never jumping, at its own size.
    var seen: usize = 0;
    var last_left: i32 = 0;
    var frames: usize = 0;
    while (!s.step(16)) : (frames += 1) {
        if (frames > 1000) break;
        const at = s.shownStrip(3, to, .horizontal, true);
        try testing.expect(at.left >= last_left and at.left <= 200);
        try testing.expectEqual(@as(i32, 36), at.width());
        if (at.left > 0 and at.left < 200) seen += 1;
        last_left = at.left;
    }
    try testing.expect(seen >= 2);
    try testing.expect(s.settled());
    try testing.expectEqual(to, s.shownStrip(3, to, .horizontal, true));
}

test "plan: a strip eases across its stack too, not only along it (T2417, Mac 7e2d0a9da)" {
    // A column's strip across the top; the sidebar expanding narrows the column.
    const before = [_]Placed{.{ .id = 3, .rect = r(0, 0, 600, 300), .tucked = true, .strip = r(0, 0, 600, 30), .axis = .vertical }};
    const after = [_]Placed{.{ .id = 3, .rect = r(200, 0, 400, 300), .tucked = true, .strip = r(200, 0, 400, 30), .axis = .vertical }};
    var s = plan(&before, &after, null, glide_ms, false);
    _ = s.step(16);
    const at = s.shownStrip(3, r(200, 0, 400, 30), .vertical, true);
    try testing.expect(at.width() > 400 and at.width() < 600);
    try testing.expectEqual(@as(i32, 30), at.height());
}

test "plan: a pure reach gain still shows its old strip until the glide is over (T2312 under T2417)" {
    const before = [_]Placed{
        .{ .id = 2, .rect = r(400, 0, 370, 600), .tucked = false },
        .{ .id = 3, .rect = r(776, 0, 400, 600), .tucked = true, .strip = r(776, 0, 24, 600) },
    };
    const after = [_]Placed{
        .{ .id = 2, .rect = r(752, 0, 370, 600), .tucked = true, .strip = r(752, 0, 36, 600) },
        .{ .id = 3, .rect = r(764, 0, 400, 600), .tucked = true, .strip = r(764, 0, 36, 600) },
    };
    var s = plan(&before, &after, null, glide_ms, false);
    var frames: usize = 0;
    while (!s.step(16)) : (frames += 1) {
        if (frames > 1000) break;
        try testing.expectEqual(r(776, 0, 24, 600), s.shownStrip(3, r(764, 0, 36, 600), .horizontal, false));
    }
    try testing.expect(frames >= 2);
}

test "plan: a card still folding into its strip carries on through a column shift (T2417)" {
    const shown = [_]Placed{.{ .id = 3, .rect = r(400, 0, 400, 600), .tucked = false }};
    const tucked = [_]Placed{.{ .id = 3, .rect = r(764, 0, 400, 600), .tucked = true, .strip = r(764, 0, 36, 600) }};
    var going = plan(&shown, &tucked, null, glide_ms, false);
    _ = going.step(20);
    const drawn = going.cardRect(3).?;
    // The column shifts mid-fold: the strip's place moves.
    const shifted = [_]Placed{.{ .id = 3, .rect = r(784, 0, 400, 600), .tucked = true, .strip = r(784, 0, 36, 600) }};
    const next = plan(&tucked, &shifted, &going, glide_ms, false);
    try testing.expectEqual(@as(usize, 1), next.len);
    try testing.expectEqual(@as(usize, 0), next.strips_len);
    try testing.expectEqual(drawn, next.cards[0].from);
    try testing.expectEqual(r(784, 0, 36, 600), next.cards[0].to);
    try testing.expect(next.cards[0].strip != null);
}

test "retarget: a moving strip follows its strip as laid out now (T2417)" {
    const before = [_]Placed{.{ .id = 3, .rect = r(0, 0, 400, 600), .tucked = true, .strip = r(0, 0, 36, 600) }};
    const after = [_]Placed{.{ .id = 3, .rect = r(200, 0, 400, 600), .tucked = true, .strip = r(200, 0, 36, 600) }};
    var s = plan(&before, &after, null, glide_ms, true);
    const moved = [_]Placed{.{ .id = 3, .rect = r(210, 0, 400, 600), .tucked = true, .strip = r(210, 0, 36, 600) }};
    try testing.expect(s.retarget(&moved));
    try testing.expectEqual(r(210, 0, 36, 600), s.strips[0].to);
}

test "leadingLag: the grid's leading edge as drawn, against where the layout puts it (T2406, Mac 7e2d0a9da)" {
    // The sidebar expanded: every card shifts 160 px right.
    const before = [_]Placed{
        .{ .id = 1, .rect = r(80, 0, 400, 600), .tucked = false },
        .{ .id = 2, .rect = r(490, 0, 400, 600), .tucked = false },
    };
    const after = [_]Placed{
        .{ .id = 1, .rect = r(240, 0, 400, 600), .tucked = false },
        .{ .id = 2, .rect = r(650, 0, 400, 600), .tucked = false },
    };
    var s = plan(&before, &after, null, glide_ms, false);
    // At the start the grid is drawn where it was: a whole shift behind.
    try testing.expectEqual(@as(?i32, -160), s.leadingLag());
    _ = s.step(20);
    const mid = s.leadingLag().?;
    try testing.expect(mid > -160 and mid < 0);
    // It is the LEFTMOST card's, whatever order the glide holds them in.
    try testing.expectEqual(s.placed(1).?.left - 240, mid);
    while (!s.step(16)) {}
    try testing.expectEqual(@as(?i32, 0), s.leadingLag());
    const none: Slide = .{};
    try testing.expectEqual(@as(?i32, null), none.leadingLag());
}
