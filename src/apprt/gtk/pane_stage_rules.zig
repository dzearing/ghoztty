//! Stacked panes on GTK, the pure half (T3567, Linux L11e;
//! docs/reference/stacked-panes.md).
//!
//! A split tab on GTK is ONE container, the stage, whose children the shared
//! stacked-panes engine places: win32's `pane_stack_layout` /
//! `pane_stack_grid` / `pane_stack_state` / `stack_drag`, which are Mac's
//! `PaneLayout` / `PaneStackState` / `RowDrag` port, pure and with no OS
//! imports. So GTK and win32 compute the same layout from the same tree: a
//! pane is never narrower or shorter than the configured minimum, a row that
//! cannot fit becomes a run on show plus minimized strips, and focusing a pane
//! brings it forward.
//!
//! What is decided here, with no GTK imports so the tests run in the `none`
//! lane:
//!
//!   * where the grid sits in the stage, and where a card is allocated given
//!     the CSS margin the elevated style puts round it;
//!   * the face a strip shows (its tab, less the part tucked under the strip
//!     in front of it), and how its label is turned to run down a vertical
//!     strip;
//!   * the cursor a gutter shows.
const std = @import("std");
const testing = std.testing;
const grid = @import("../win32/pane_stack_grid.zig");
const layout = @import("../win32/pane_stack_layout.zig");

pub const PxRect = grid.PxRect;
pub const Direction = layout.Direction;

/// The elevated style's card margin (`style.css` `.pane-elevated .pane-card`,
/// half of `pane_style.gutter`): GTK takes it out of whatever the card is
/// allocated, so a card is allocated that much larger than the engine's frame
/// for its visible edge to land on the frame.
pub const elevated_card_margin: i32 = 5;

/// The grid's rect in the stage. The elevated style insets it by the card
/// margin, so with the tree's own padding the edge is one whole gutter away,
/// as for a lone pane; the flat style runs edge to edge.
pub fn gridRect(stage_w: i32, stage_h: i32, elevated: bool) PxRect {
    const inset: i32 = if (elevated) elevated_card_margin else 0;
    return .{
        .left = inset,
        .top = inset,
        .right = @max(inset, stage_w - inset),
        .bottom = @max(inset, stage_h - inset),
    };
}

/// Where a card on show is allocated: its frame, grown by the CSS margin GTK
/// will take back out of it.
pub fn cardAllocation(frame: PxRect, elevated: bool) PxRect {
    const m: i32 = if (elevated) elevated_card_margin else 0;
    return .{
        .left = frame.left - m,
        .top = frame.top - m,
        .right = frame.right + m,
        .bottom = frame.bottom + m,
    };
}

/// The part of a strip that shows: its tab, less the `tuck` that reaches under
/// the strip in front of it (toward the run). Faces of neighbouring strips
/// then meet edge to edge instead of overlapping, so no paint order is needed
/// between them. `leads`: the strip lies before its run (its run side is its
/// trailing edge). `axis`: the row's direction.
pub fn stripFace(tab: PxRect, leads: bool, tuck: i32, axis: Direction) PxRect {
    var r = tab;
    const t = @max(tuck, 0);
    switch (axis) {
        .horizontal => if (leads) {
            r.right = @max(r.left, r.right - t);
        } else {
            r.left = @min(r.right, r.left + t);
        },
        .vertical => if (leads) {
            r.bottom = @max(r.top, r.bottom - t);
        } else {
            r.top = @min(r.bottom, r.top + t);
        },
    }
    return r;
}

/// How a strip's label is allocated over its face. In a row (a horizontal
/// split chain) the strip is a vertical bar and its name runs DOWN it (Mac
/// `PaneCardView.titleRect`): the label is laid out `w` x `h` = the face's
/// height x width, then rotated 90 degrees clockwise and moved to (`tx`,
/// `ty`), the face's top-right corner. In a column the strip is a horizontal
/// bar and the label sits on it as is.
pub const LabelPlacement = struct {
    w: i32,
    h: i32,
    tx: f32,
    ty: f32,
    rotate: bool,
};

pub fn labelPlacement(face: PxRect, axis: Direction) LabelPlacement {
    return switch (axis) {
        .horizontal => .{
            .w = face.height(),
            .h = face.width(),
            .tx = @floatFromInt(face.right),
            .ty = @floatFromInt(face.top),
            .rotate = true,
        },
        .vertical => .{
            .w = face.width(),
            .h = face.height(),
            .tx = @floatFromInt(face.left),
            .ty = @floatFromInt(face.top),
            .rotate = false,
        },
    };
}

/// The cursor over a gutter of a row running along `d`: a row's gutters are
/// upright, so they resize sideways.
pub fn gutterCursor(d: Direction) [:0]const u8 {
    return switch (d) {
        .horizontal => "col-resize",
        .vertical => "row-resize",
    };
}

/// A press that moved less than this is a click (Mac's 5pt drag threshold
/// for a strip): a strip clicked is brought forward, one dragged is not.
pub const click_slop: f64 = 5;

pub fn isClick(dx: f64, dy: f64) bool {
    return @abs(dx) < click_slop and @abs(dy) < click_slop;
}

// ---- Glides (T3625; docs/reference/stacked-panes.md "Glides") --------------
//
// The motion itself is win32's pure follower, `pane_stack_slide` (Mac
// `PaneStageView.glide`): the stage hands it the layout before and after, and
// asks it every frame where each card and its pane are drawn. What GTK adds is
// how a card shows a pane held at another size: the card is allocated where
// the glide draws it, and its content is allocated at the held size, offset
// inside it, so the card (overflow hidden, its rounded rim and all) cuts it.

/// Where a card's content is allocated inside the card while a glide holds it:
/// `card` is the card as drawn and `pane` the held pane, both in stage
/// coordinates; the offset is from the card's content box (its frame - the
/// CSS margin is already out of it).
pub const HeldContent = struct {
    dx: i32,
    dy: i32,
    w: i32,
    h: i32,
};

pub fn heldContent(card: PxRect, pane: PxRect) HeldContent {
    return .{
        .dx = pane.left - card.left,
        .dy = pane.top - card.top,
        .w = @max(pane.width(), 1),
        .h = @max(pane.height(), 1),
    };
}

/// How long "the drag is over" waits after the hand lets go (Mac
/// `PaneStackState.isGesturing`, 50 ms): a fast hand outruns the grid, so the
/// glide keeps following for that long before it may end.
pub const gesture_tail_us: i64 = 50 * std.time.us_per_ms;

/// Whether a gutter drag still counts as under way at `now_us`: the drag is
/// held, or was let go less than `gesture_tail_us` ago (`released_us`).
pub fn gesturing(dragging: bool, released_us: ?i64, now_us: i64) bool {
    if (dragging) return true;
    const r = released_us orelse return false;
    return now_us - r < gesture_tail_us;
}

/// The time a glide frame advances, in ms: the frame clock's step, with a
/// first frame (or one after a stall, a window hidden mid-glide) counted as
/// one 60 Hz period, so no single frame carries most of the motion.
pub const frame_ms: f64 = 1000.0 / 60.0;

pub fn frameStep(last_us: ?i64, now_us: i64) f64 {
    const l = last_us orelse return frame_ms;
    const dt = @as(f64, @floatFromInt(now_us - l)) / std.time.us_per_ms;
    if (dt <= 0) return 0;
    return if (dt > 4 * frame_ms) frame_ms else dt;
}

/// The two halves of a card on its way into or out of its strip at
/// `collapse` (`pane_stack_slide.collapse`: 0 a card, 1 its strip): its
/// content fades out as its title fades in (Mac `PaneCardView.collapse`).
pub const Fade = struct { content: f64, face: f64 };

pub fn fadeAt(collapse: f64) Fade {
    const c = std.math.clamp(collapse, 0, 1);
    return .{ .content = 1 - c, .face = c };
}

test "the elevated grid sits a card margin in; flat runs edge to edge" {
    try testing.expectEqual(PxRect{ .left = 5, .top = 5, .right = 795, .bottom = 595 }, gridRect(800, 600, true));
    try testing.expectEqual(PxRect{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, gridRect(800, 600, false));
    // A stage too small for its inset is empty, never inverted.
    const tiny = gridRect(6, 6, true);
    try testing.expect(tiny.width() >= 0 and tiny.height() >= 0);
}

test "a card is allocated its frame plus the margin GTK takes back" {
    const f: PxRect = .{ .left = 10, .top = 10, .right = 400, .bottom = 300 };
    try testing.expectEqual(PxRect{ .left = 5, .top = 5, .right = 405, .bottom = 305 }, cardAllocation(f, true));
    try testing.expectEqual(f, cardAllocation(f, false));
}

test "a strip's face gives up its tuck on the run side only" {
    const tab: PxRect = .{ .left = 100, .top = 0, .right = 148, .bottom = 500 };
    // Before the run: the run is to its right.
    try testing.expectEqual(PxRect{ .left = 100, .top = 0, .right = 136, .bottom = 500 }, stripFace(tab, true, 12, .horizontal));
    // After the run: the run is to its left.
    try testing.expectEqual(PxRect{ .left = 112, .top = 0, .right = 148, .bottom = 500 }, stripFace(tab, false, 12, .horizontal));
    // A column: the run is above or below.
    const vt: PxRect = .{ .left = 0, .top = 200, .right = 500, .bottom = 248 };
    try testing.expectEqual(PxRect{ .left = 0, .top = 200, .right = 500, .bottom = 236 }, stripFace(vt, true, 12, .vertical));
    try testing.expectEqual(PxRect{ .left = 0, .top = 212, .right = 500, .bottom = 248 }, stripFace(vt, false, 12, .vertical));
    // No tuck (the strip next to the run) keeps its whole tab; a tuck past
    // the tab never inverts it.
    try testing.expectEqual(tab, stripFace(tab, true, 0, .horizontal));
    const over = stripFace(tab, false, 500, .horizontal);
    try testing.expect(over.width() == 0);
}

test "a vertical strip's label runs down it from the face's top-right corner" {
    const face: PxRect = .{ .left = 100, .top = 20, .right = 136, .bottom = 520 };
    const p = labelPlacement(face, .horizontal);
    try testing.expect(p.rotate);
    try testing.expectEqual(@as(i32, 500), p.w);
    try testing.expectEqual(@as(i32, 36), p.h);
    try testing.expectEqual(@as(f32, 136), p.tx);
    try testing.expectEqual(@as(f32, 20), p.ty);
    // Rotating (x, y) by 90 degrees clockwise is (-y, x): the label's far
    // corner (w, h) lands on the face's bottom-left, so the label covers the
    // face exactly.
    const far_x = p.tx - @as(f32, @floatFromInt(p.h));
    const far_y = p.ty + @as(f32, @floatFromInt(p.w));
    try testing.expectEqual(@as(f32, @floatFromInt(face.left)), far_x);
    try testing.expectEqual(@as(f32, @floatFromInt(face.bottom)), far_y);
}

test "a horizontal strip's label sits on it unturned" {
    const face: PxRect = .{ .left = 0, .top = 200, .right = 500, .bottom = 236 };
    const p = labelPlacement(face, .vertical);
    try testing.expect(!p.rotate);
    try testing.expectEqual(@as(i32, 500), p.w);
    try testing.expectEqual(@as(i32, 36), p.h);
    try testing.expectEqual(@as(f32, 0), p.tx);
    try testing.expectEqual(@as(f32, 200), p.ty);
}

test "a held pane sits inside its card at its own size, pinned where the glide puts it" {
    // A card narrowing into a strip on its left: the pane (400 wide) is
    // pinned to the card's far (right) edge, so it starts left of the card.
    const card: PxRect = .{ .left = 100, .top = 10, .right = 250, .bottom = 510 };
    const pane: PxRect = .{ .left = -150, .top = 10, .right = 250, .bottom = 510 };
    const h = heldContent(card, pane);
    try testing.expectEqual(@as(i32, -250), h.dx);
    try testing.expectEqual(@as(i32, 0), h.dy);
    try testing.expectEqual(@as(i32, 400), h.w);
    try testing.expectEqual(@as(i32, 500), h.h);
    // A pane held at its card's own place and size is the card.
    const same = heldContent(card, card);
    try testing.expectEqual(HeldContent{ .dx = 0, .dy = 0, .w = 150, .h = 500 }, same);
    // Never a zero or negative allocation.
    const empty = heldContent(card, .{ .left = 5, .top = 5, .right = 5, .bottom = 5 });
    try testing.expect(empty.w >= 1 and empty.h >= 1);
}

test "the drag is over 50ms after the hand lets go" {
    try testing.expect(gesturing(true, null, 0));
    try testing.expect(!gesturing(false, null, 1_000_000));
    try testing.expect(gesturing(false, 1_000_000, 1_000_000 + 49_000));
    try testing.expect(!gesturing(false, 1_000_000, 1_000_000 + 50_000));
}

test "a glide frame is the clock's step, a first or stalled frame one 60Hz period" {
    try testing.expectEqual(frame_ms, frameStep(null, 5_000_000));
    try testing.expectApproxEqAbs(@as(f64, 8.333), frameStep(1_000_000, 1_008_333), 1e-3);
    // A window hidden mid-glide: its next frame does not jump the motion.
    try testing.expectEqual(frame_ms, frameStep(1_000_000, 2_000_000));
    // The clock never runs backwards into a negative step.
    try testing.expectEqual(@as(f64, 0), frameStep(2_000_000, 1_000_000));
}

test "a card's content fades out as its strip's title fades in" {
    try testing.expectEqual(Fade{ .content = 1, .face = 0 }, fadeAt(0));
    try testing.expectEqual(Fade{ .content = 0, .face = 1 }, fadeAt(1));
    const mid = fadeAt(0.25);
    try testing.expectApproxEqAbs(@as(f64, 0.75), mid.content, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), mid.content + mid.face, 1e-9);
    // Out of range is clamped, never a negative opacity.
    try testing.expectEqual(Fade{ .content = 0, .face = 1 }, fadeAt(3));
}

test "gutters resize across their row; a small move is a click" {
    try testing.expectEqualStrings("col-resize", gutterCursor(.horizontal));
    try testing.expectEqualStrings("row-resize", gutterCursor(.vertical));
    try testing.expect(isClick(2, -3));
    try testing.expect(!isClick(6, 0));
    try testing.expect(!isClick(0, -5));
}

// ---- Blades (T3729; docs/reference/stacked-panes.md "Strips are blades") ----
//
// A strip that has another between it and the run reaches `strip_tuck` under
// that one: its face is drawn at its whole tab, the strip in front painted
// over the tucked part (`Leaf.elevation` paint order, T3625), so the blades
// overlap instead of meeting edge to edge. Its title is centred on what
// shows. Each strip casts win32's blade shadow (`blade_shadow.paint`, Mac
// `PaneCardView`): tight, light, leaning away from the run onto the blade
// behind it, cast from a shape pulled in by the corner radius at each end,
// and coming on with `collapse` as a card narrows into its strip.

const blade_shadow = @import("../win32/blade_shadow.zig");
const pane_elevation = @import("../win32/pane_elevation.zig");
const pane_stack_strip = @import("../win32/pane_stack_strip.zig");

/// The CSS padding the `.pane-strip-tuck-*` classes add on the tucked side,
/// in px (style.css). The engine's tuck is Mac's `Metrics.bladeTuck`.
pub const strip_tuck_css_px: i32 = 12;

/// Which side of a strip's label is tucked under the strip in front, in the
/// LABEL's own coordinates (a row's label is turned 90 degrees clockwise, so
/// its top is the strip's right edge). `.none`: nothing is tucked (the strip
/// beside the run).
pub const LabelTuck = enum { none, top, bottom };

pub fn labelTuck(leads: bool, tuck: i32, axis: Direction) LabelTuck {
    if (tuck <= 0) return .none;
    return switch (axis) {
        // Turned: label y=0 is the strip's right edge, and a leading strip's
        // run (so its tuck) is on its right.
        .horizontal => if (leads) .top else .bottom,
        // As is: a leading strip's tuck is its bottom edge.
        .vertical => if (leads) .bottom else .top,
    };
}

/// The picture a strip's shadow is drawn in: `rect` (stage coordinates,
/// logical px) is the tab grown by the shadow's reach on every side, and
/// `w` x `h` the texture in device pixels at `scale`.
pub const ShadowImage = struct {
    rect: PxRect,
    w: usize,
    h: usize,
    scale: i32,
};

pub fn shadowImage(tab: PxRect, scale: i32) ShadowImage {
    const s = @max(scale, 1);
    const reach_dev = blade_shadow.reachPx(@floatFromInt(s));
    const reach = @divFloor(reach_dev + s - 1, s);
    const r: PxRect = .{
        .left = tab.left - reach,
        .top = tab.top - reach,
        .right = tab.right + reach,
        .bottom = tab.bottom + reach,
    };
    return .{
        .rect = r,
        .w = @intCast(@max(r.width(), 0) * s),
        .h = @intCast(@max(r.height(), 0) * s),
        .scale = s,
    };
}

/// Lay the shadow of the strip at `tab` into `buf` (`img.w` x `img.h`,
/// `GDK_MEMORY_B8G8R8A8_PREMULTIPLIED`): black at the shadow's alpha, clear
/// everywhere else - inside the strip's own shape too, since the face is
/// laid over it. `blade_shadow.paint` darkens a desk; over a clear buffer
/// that IS the premultiplied shadow.
pub fn renderShadow(buf: []u32, img: ShadowImage, tab: PxRect, axis: Direction, leads: bool, collapse: f64, is_light: bool) void {
    std.debug.assert(buf.len >= img.w * img.h);
    @memset(buf, 0);
    const s = img.scale;
    const rect: pane_stack_strip.Rect = .{
        .left = (tab.left - img.rect.left) * s,
        .top = (tab.top - img.rect.top) * s,
        .right = (tab.right - img.rect.left) * s,
        .bottom = (tab.bottom - img.rect.top) * s,
    };
    const sf: f32 = @floatFromInt(s);
    const c: f32 = @floatCast(std.math.clamp(collapse, 0, 1));
    blade_shadow.paint(buf, img.w, img.h, rect, axis, leads, c, is_light, sf, pane_elevation.radiusPx(sf));
}

/// What a shadow picture was last drawn for: it is redrawn only when this
/// changes, so a strip that only moves keeps its texture. `collapse` is kept
/// in 1/256ths, finer than an 8-bit alpha can tell apart.
pub const ShadowKey = struct {
    w: i32,
    h: i32,
    scale: i32,
    axis: Direction,
    leads: bool,
    collapse: u16,
    is_light: bool,

    pub fn of(tab: PxRect, scale: i32, axis: Direction, leads: bool, collapse: f64, is_light: bool) ShadowKey {
        return .{
            .w = tab.width(),
            .h = tab.height(),
            .scale = @max(scale, 1),
            .axis = axis,
            .leads = leads,
            .collapse = @intFromFloat(@round(std.math.clamp(collapse, 0, 1) * 256)),
            .is_light = is_light,
        };
    }
};

test "the tuck CSS matches the engine's blade tuck" {
    try testing.expectEqual(@as(f64, @floatFromInt(strip_tuck_css_px)), layout.Metrics.blade_tuck);
}

test "a strip's title gives way on its tucked side only" {
    try testing.expectEqual(LabelTuck.none, labelTuck(true, 0, .horizontal));
    try testing.expectEqual(LabelTuck.top, labelTuck(true, 12, .horizontal));
    try testing.expectEqual(LabelTuck.bottom, labelTuck(false, 12, .horizontal));
    try testing.expectEqual(LabelTuck.bottom, labelTuck(true, 12, .vertical));
    try testing.expectEqual(LabelTuck.top, labelTuck(false, 12, .vertical));
}

/// The shadow's alpha at stage px (`x`, `y`), from the device pixel at its
/// centre.
fn alphaAt(buf: []const u32, img: ShadowImage, x: i32, y: i32) u8 {
    const s = img.scale;
    const dx: usize = @intCast((x - img.rect.left) * s + @divFloor(s, 2));
    const dy: usize = @intCast((y - img.rect.top) * s + @divFloor(s, 2));
    return @truncate(buf[dy * img.w + dx] >> 24);
}

test "a blade's shadow leans away from the run, is clear inside the strip, and fades in its ends" {
    const a = testing.allocator;
    // A 48 x 400 strip trailing its run (the run is to its left).
    const tab: PxRect = .{ .left = 200, .top = 20, .right = 248, .bottom = 420 };
    const img = shadowImage(tab, 1);
    try testing.expect(img.rect.left < tab.left and img.rect.right > tab.right);
    const buf = try a.alloc(u32, img.w * img.h);
    defer a.free(buf);
    renderShadow(buf, img, tab, .horizontal, false, 1, false);
    const mid = @divTrunc(tab.top + tab.bottom, 2);
    // Clear inside: the face is laid over it.
    try testing.expectEqual(@as(u8, 0), alphaAt(buf, img, 224, mid));
    // Premultiplied black: only the alpha byte is ever set.
    for (buf) |p| try testing.expectEqual(@as(u32, 0), p & 0x00FF_FFFF);
    // Away from the run (right) it is darker than toward it (left).
    const away = alphaAt(buf, img, tab.right + 1, mid);
    const toward = alphaAt(buf, img, tab.left - 2, mid);
    try testing.expect(away > toward);
    // Light: 30% on dark at most.
    try testing.expect(away > 0 and away <= 77);
    // Past the ends along the strip it has faded well below its side.
    try testing.expect(@as(u32, alphaAt(buf, img, 224, tab.bottom + 2)) * 3 < away);
    // Leading the run, it leans the other way.
    renderShadow(buf, img, tab, .horizontal, true, 1, false);
    try testing.expect(alphaAt(buf, img, tab.left - 2, mid) > alphaAt(buf, img, tab.right + 1, mid));
    // Lighter on a light desk (14%).
    renderShadow(buf, img, tab, .horizontal, false, 1, true);
    const light = alphaAt(buf, img, tab.right + 1, mid);
    try testing.expect(light > 0 and light < away);
}

test "a blade's shadow follows collapse: none on a card, full on its strip" {
    const a = testing.allocator;
    const tab: PxRect = .{ .left = 10, .top = 10, .right = 50, .bottom = 300 };
    const img = shadowImage(tab, 2);
    try testing.expectEqual(@as(usize, @intCast(img.rect.width() * 2)), img.w);
    const buf = try a.alloc(u32, img.w * img.h);
    defer a.free(buf);
    renderShadow(buf, img, tab, .horizontal, false, 0, false);
    for (buf) |p| try testing.expectEqual(@as(u32, 0), p);
    renderShadow(buf, img, tab, .horizontal, false, 0.4, false);
    const part = alphaAt(buf, img, tab.right + 1, 150);
    renderShadow(buf, img, tab, .horizontal, false, 1, false);
    const full = alphaAt(buf, img, tab.right + 1, 150);
    try testing.expect(part > 0 and part < full);
}

test "a shadow is redrawn only when what it looks like changes" {
    const t: PxRect = .{ .left = 0, .top = 0, .right = 40, .bottom = 300 };
    const moved: PxRect = .{ .left = 90, .top = 0, .right = 130, .bottom = 300 };
    try testing.expectEqual(ShadowKey.of(t, 1, .horizontal, true, 1, false), ShadowKey.of(moved, 1, .horizontal, true, 1, false));
    try testing.expect(!std.meta.eql(ShadowKey.of(t, 1, .horizontal, true, 1, false), ShadowKey.of(t, 1, .horizontal, true, 0.5, false)));
}
