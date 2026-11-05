//! The card that follows the pointer during a pane drag (T2703, Mac
//! 30d13ea14 `PaneDragGhost.swift`): pure geometry and pixels. The window that
//! shows it is `PaneDragGhost.zig`.
//!
//! A card rather than a bare snapshot, for Mac's reason: a terminal frame
//! alone reads as glyphs on nothing at drag size, and a pane whose content has
//! not been captured yet still has to say what is being carried. So the card
//! is the pane's background, a title strip, whatever content the pane has
//! given us, a rim and a shadow.
//!
//! Every number is Mac's, in DIP, scaled by the window's DPI here. The title
//! strip's 18 is Mac's band height (10 pt text with 4 DIP above and below),
//! kept rather than snapped to the spacing scale because the scale governs
//! gaps between painted things and the band is a size; the card radius is the
//! design system's card radius (8) as well as Mac's.
//!
//! Pixels are `0xAARRGGBB` words in a TOP-DOWN buffer, premultiplied once
//! `finalize` has run - the form `UpdateLayeredWindow(ULW_ALPHA,
//! AC_SRC_ALPHA)` takes.

const std = @import("std");
const color_math = @import("color_math.zig");

pub const Rgb = color_math.Rgb;

/// The card never outgrows this: it marks the drag, and must not hide the
/// targets under it.
pub const max_w_dip: f32 = 220;
pub const max_h_dip: f32 = 150;
/// A sliver of a pane still gets a card big enough to read.
pub const min_w_dip: f32 = 120;
pub const min_h_dip: f32 = 72;
pub const title_dip: f32 = 18;
pub const radius_dip: f32 = 8;
/// Room around the card in the image, for its shadow.
pub const margin_dip: f32 = 10;
/// The title's inset from the card's left and right edges.
pub const title_inset_dip: f32 = 8;
/// The title's em height (Mac: 10 pt semibold system font).
pub const title_font_dip: f32 = 10;

/// Mac's shadow: black at 40%, blur 6, dropped 2 (down, on screen).
pub const shadow_alpha: f32 = 0.4;
pub const shadow_blur_dip: f32 = 6;
pub const shadow_drop_dip: f32 = 2;

/// The rim: the card's ink colour at 18%, one device pixel wide.
pub const rim_alpha: f32 = 0.18;
/// The title strip: the ink colour laid over the background at 10%.
pub const strip_alpha: f32 = 0.10;
/// The title text: the ink colour at 85%.
pub const text_alpha: f32 = 0.85;

pub const Size = struct { w: i32, h: i32 };
pub const Point = struct { x: i32, y: i32 };
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
};

pub fn px(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * @max(scale, 0.1)));
}

/// The pane's shape (device px), scaled to fit the maximum and held to the
/// minimum - all at `scale`. Never scaled UP: a pane smaller than the maximum
/// keeps its own size (subject to the minimum), as Mac's `min(..., 1)` says.
pub fn cardSize(pane_w: i32, pane_h: i32, scale: f32) Size {
    const max_w: f32 = max_w_dip * scale;
    const max_h: f32 = max_h_dip * scale;
    const min_w = px(min_w_dip, scale);
    const min_h = px(min_h_dip, scale);
    if (pane_w <= 0 or pane_h <= 0) return .{ .w = min_w, .h = min_h };
    const pw: f32 = @floatFromInt(pane_w);
    const ph: f32 = @floatFromInt(pane_h);
    const s = @min(@min(max_w / pw, max_h / ph), 1.0);
    return .{
        .w = @max(min_w, @as(i32, @intFromFloat(@round(pw * s)))),
        .h = @max(min_h, @as(i32, @intFromFloat(@round(ph * s)))),
    };
}

/// The image holding a card: the card plus the shadow margin all round.
pub fn imageSize(card: Size, scale: f32) Size {
    const m = px(margin_dip, scale);
    return .{ .w = card.w + 2 * m, .h = card.h + 2 * m };
}

/// Where the image's top-left goes (screen px) for the pointer at `pointer`:
/// the pointer holds the card by the middle of its title strip, as a window
/// is held by its titlebar, so the card hangs BELOW the pointer and the
/// target under it stays in view. (Mac's `frame(imageSize:pointer:)`, in a
/// y-down space.)
pub fn imageOrigin(pointer: Point, image: Size, scale: f32) Point {
    const m = px(margin_dip, scale);
    const t = px(title_dip, scale);
    return .{
        .x = pointer.x - @divTrunc(image.w, 2),
        .y = pointer.y - m - @divTrunc(t, 2),
    };
}

/// The card's parts in image coordinates.
pub const Layout = struct {
    card: Rect,
    title: Rect,
    body: Rect,
    radius: f32,
};

pub fn layout(card: Size, scale: f32) Layout {
    const m = px(margin_dip, scale);
    const t = @min(px(title_dip, scale), card.h);
    const c: Rect = .{ .left = m, .top = m, .right = m + card.w, .bottom = m + card.h };
    return .{
        .card = c,
        .title = .{ .left = c.left, .top = c.top, .right = c.right, .bottom = c.top + t },
        .body = .{ .left = c.left, .top = c.top + t, .right = c.right, .bottom = c.bottom },
        .radius = radius_dip * scale,
    };
}

/// The size to ask a pane's content for so it COVERS the body at 1:1 - the
/// pane's own aspect, scaled until both of the body's sides are filled. The
/// drawn content is anchored top-left (where a fresh terminal's prompt is),
/// so whatever overhangs is the bottom and the right.
pub fn contentRequest(pane_w: i32, pane_h: i32, body: Size) Size {
    if (pane_w <= 0 or pane_h <= 0 or body.w <= 0 or body.h <= 0) return body;
    const pw: f32 = @floatFromInt(pane_w);
    const ph: f32 = @floatFromInt(pane_h);
    const bw: f32 = @floatFromInt(body.w);
    const bh: f32 = @floatFromInt(body.h);
    const s = @max(bw / pw, bh / ph);
    return .{
        .w = @max(body.w, @as(i32, @intFromFloat(@ceil(pw * s - 0.01)))),
        .h = @max(body.h, @as(i32, @intFromFloat(@ceil(ph * s - 0.01)))),
    };
}

/// Light or dark, for the ink drawn on it (Mac's `isLightColor`: perceived
/// luminance past the midpoint).
pub fn isLight(c: Rgb) bool {
    const l = 0.299 * @as(f32, @floatFromInt(c.r)) + 0.587 * @as(f32, @floatFromInt(c.g)) + 0.114 * @as(f32, @floatFromInt(c.b));
    return l > 127.5;
}

/// The ink on `bg`: black on a light card, white on a dark one.
pub fn inkFor(bg: Rgb) Rgb {
    return if (isLight(bg)) .{ .r = 0, .g = 0, .b = 0 } else .{ .r = 255, .g = 255, .b = 255 };
}

pub fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
    const k = std.math.clamp(t, 0, 1);
    return .{
        .r = mixByte(a.r, b.r, k),
        .g = mixByte(a.g, b.g, k),
        .b = mixByte(a.b, b.b, k),
    };
}

fn mixByte(a: u8, b: u8, t: f32) u8 {
    const v = @as(f32, @floatFromInt(a)) * (1 - t) + @as(f32, @floatFromInt(b)) * t;
    return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
}

pub fn pack(c: Rgb) u32 {
    return 0xFF00_0000 | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

/// The colour the title text is drawn in, over the strip.
pub fn textColor(bg: Rgb) Rgb {
    return mix(stripColor(bg), inkFor(bg), text_alpha);
}

pub fn stripColor(bg: Rgb) Rgb {
    return mix(bg, inkFor(bg), strip_alpha);
}

/// Pass 1: the card's opaque face - the body in the background colour, the
/// title strip tinted toward the ink. The whole image is written (the margin
/// too, which `finalize` turns into shadow), so no stale pixel survives.
pub fn fillCard(buf: []u32, w: usize, h: usize, lay: Layout, bg: Rgb) void {
    if (buf.len < w * h) return;
    const body = pack(bg);
    const strip = pack(stripColor(bg));
    for (0..h) |y| {
        const iy: i32 = @intCast(y);
        const c = if (iy >= lay.title.top and iy < lay.title.bottom) strip else body;
        @memset(buf[y * w ..][0..w], c);
    }
}

/// Pass 2: the pane's content in the body, covering it from the top-left.
/// `content` is BOTTOM-UP (both capture paths are), `cw` x `ch`; drawn
/// opaque, the way the fold carries the same frames (`strip_face`), and
/// sampled by area so text shrinks into grey rather than shattering.
pub fn drawContent(buf: []u32, w: usize, h: usize, body: Rect, content: []const u32, cw: i32, ch: i32, pane: Size) void {
    if (cw <= 0 or ch <= 0) return;
    if (content.len < @as(usize, @intCast(cw)) * @as(usize, @intCast(ch))) return;
    if (buf.len < w * h) return;
    const bw = body.width();
    const bh = body.height();
    if (bw <= 0 or bh <= 0) return;
    // How big the content is drawn: the cover size for the pane's own shape
    // (so a frame captured at another size still lands at the pane's aspect),
    // falling back to the frame's own when the pane's is unknown.
    const shape: Size = if (pane.w > 0 and pane.h > 0) pane else .{ .w = cw, .h = ch };
    const drawn = contentRequest(shape.w, shape.h, .{ .w = bw, .h = bh });
    // Source pixels per drawn pixel, each axis.
    const sx: f32 = @as(f32, @floatFromInt(cw)) / @as(f32, @floatFromInt(drawn.w));
    const sy: f32 = @as(f32, @floatFromInt(ch)) / @as(f32, @floatFromInt(drawn.h));
    const ucw: usize = @intCast(cw);
    var y: i32 = 0;
    while (y < bh) : (y += 1) {
        const dy: i32 = body.top + y;
        if (dy < 0 or dy >= @as(i32, @intCast(h))) continue;
        const y0f = @as(f32, @floatFromInt(y)) * sy;
        const y0: i32 = @intFromFloat(@floor(y0f));
        const y1: i32 = @max(y0 + 1, @as(i32, @intFromFloat(@ceil(y0f + sy))));
        var x: i32 = 0;
        while (x < bw) : (x += 1) {
            const dx: i32 = body.left + x;
            if (dx < 0 or dx >= @as(i32, @intCast(w))) continue;
            const x0f = @as(f32, @floatFromInt(x)) * sx;
            const x0: i32 = @intFromFloat(@floor(x0f));
            const x1: i32 = @max(x0 + 1, @as(i32, @intFromFloat(@ceil(x0f + sx))));
            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var n: u32 = 0;
            var yy = y0;
            while (yy < y1 and yy < ch) : (yy += 1) {
                // Bottom-up: the top row is the frame's last.
                const row = content[@as(usize, @intCast(ch - 1 - yy)) * ucw ..][0..ucw];
                var xx = x0;
                while (xx < x1 and xx < cw) : (xx += 1) {
                    const p = row[@intCast(xx)];
                    r += (p >> 16) & 0xFF;
                    g += (p >> 8) & 0xFF;
                    b += p & 0xFF;
                    n += 1;
                }
            }
            if (n == 0) continue;
            buf[@as(usize, @intCast(dy)) * w + @as(usize, @intCast(dx))] =
                0xFF00_0000 | ((r / n) << 16) | ((g / n) << 8) | (b / n);
        }
    }
}

/// Signed distance from a pixel centre to the rounded rect's edge: negative
/// inside, positive outside.
pub fn roundedDistance(x: f32, y: f32, r: Rect, radius: f32) f32 {
    const l: f32 = @floatFromInt(r.left);
    const t: f32 = @floatFromInt(r.top);
    const rt: f32 = @floatFromInt(r.right);
    const b: f32 = @floatFromInt(r.bottom);
    const hw = (rt - l) / 2;
    const hh = (b - t) / 2;
    const rad = @min(radius, @min(hw, hh));
    const dx = @max(@abs(x - (l + hw)) - (hw - rad), 0);
    const dy = @max(@abs(y - (t + hh)) - (hh - rad), 0);
    const outside = @sqrt(dx * dx + dy * dy) - rad;
    // Inside the straight part, the distance is to the nearer side.
    const ix = @abs(x - (l + hw)) - hw;
    const iy = @abs(y - (t + hh)) - hh;
    if (dx == 0 and dy == 0) return @max(ix, iy);
    return outside;
}

/// Pass 3 (after any GDI text, which writes alpha 0): cut the face to the
/// rounded card with anti-aliased corners, lay the rim on its edge, put the
/// shadow outside it, and premultiply - the image is then ready for
/// `UpdateLayeredWindow` with per-pixel alpha.
pub fn finalize(buf: []u32, w: usize, h: usize, lay: Layout, bg: Rgb, scale: f32) void {
    if (buf.len < w * h) return;
    const ink = inkFor(bg);
    const rim_px: f32 = 1;
    const blur = shadow_blur_dip * scale;
    const drop = shadow_drop_dip * scale;
    var shadow_rect = lay.card;
    const drop_i: i32 = @intFromFloat(@round(drop));
    shadow_rect.top += drop_i;
    shadow_rect.bottom += drop_i;
    for (0..h) |y| {
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        for (0..w) |x| {
            const cx = @as(f32, @floatFromInt(x)) + 0.5;
            const i = y * w + x;
            const d = roundedDistance(cx, cy, lay.card, lay.radius);
            const cover = std.math.clamp(0.5 - d, 0, 1);

            // The shadow under the card, falling off over the blur.
            const sd = roundedDistance(cx, cy, shadow_rect, lay.radius);
            const sk = if (sd <= 0) 1.0 else std.math.clamp(1 - sd / @max(blur, 1), 0, 1);
            const sa = shadow_alpha * sk * sk;

            var face = buf[i];
            if (cover > 0) {
                // The rim: the outermost device pixel of the card.
                if (d > -rim_px) {
                    const fc: Rgb = .{
                        .r = @intCast((face >> 16) & 0xFF),
                        .g = @intCast((face >> 8) & 0xFF),
                        .b = @intCast(face & 0xFF),
                    };
                    face = pack(mix(fc, ink, rim_alpha));
                }
            }
            // Card over shadow, premultiplied: a = c + s(1-c).
            const a = cover + sa * (1 - cover);
            if (a <= 0) {
                buf[i] = 0;
                continue;
            }
            const fr: f32 = @floatFromInt((face >> 16) & 0xFF);
            const fg: f32 = @floatFromInt((face >> 8) & 0xFF);
            const fb: f32 = @floatFromInt(face & 0xFF);
            // The shadow is black, so it adds alpha and no colour.
            const pr = fr * cover;
            const pg = fg * cover;
            const pb = fb * cover;
            buf[i] = (@as(u32, toByte(a * 255)) << 24) |
                (@as(u32, toByte(pr)) << 16) |
                (@as(u32, toByte(pg)) << 8) |
                toByte(pb);
        }
    }
}

fn toByte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
}

/// What a drag shows under the pointer, by where it started (Mac
/// `PaneDragSource`): a pane's grab handle or rearrange header carries a
/// ghost; a strip (the tucked pane itself moves) and a sidebar row (the row
/// itself follows the pointer) do not.
pub fn wantsGhost(blade: bool, list: bool) bool {
    return !blade and !list;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "cardSize: a big pane fits the maximum at its own aspect" {
    for (scales) |s| {
        const c = cardSize(@intFromFloat(1600 * s), @intFromFloat(900 * s), s);
        try testing.expect(c.w <= px(max_w_dip, s));
        try testing.expect(c.h <= px(max_h_dip, s));
        // 16:9 is wider than 220:150, so width is the binding side.
        try testing.expectEqual(px(max_w_dip, s), c.w);
        const aspect = @as(f32, @floatFromInt(c.w)) / @as(f32, @floatFromInt(c.h));
        try testing.expectApproxEqAbs(@as(f32, 16.0 / 9.0), aspect, 0.03);
    }
}

test "cardSize: a tall pane is bound by height" {
    for (scales) |s| {
        const c = cardSize(@intFromFloat(500 * s), @intFromFloat(1000 * s), s);
        try testing.expectEqual(px(max_h_dip, s), c.h);
        try testing.expect(c.w >= px(min_w_dip, s));
    }
}

test "cardSize: a sliver is held to the minimum" {
    for (scales) |s| {
        const c = cardSize(@intFromFloat(40 * s), @intFromFloat(20 * s), s);
        try testing.expectEqual(px(min_w_dip, s), c.w);
        try testing.expectEqual(px(min_h_dip, s), c.h);
    }
}

test "cardSize: a small pane is never scaled up past its own size" {
    const c = cardSize(160, 100, 1.0);
    try testing.expectEqual(@as(i32, 160), c.w);
    try testing.expectEqual(@as(i32, 100), c.h);
}

test "cardSize: an unmeasured pane gets the minimum card" {
    const c = cardSize(0, 0, 1.5);
    try testing.expectEqual(px(min_w_dip, 1.5), c.w);
    try testing.expectEqual(px(min_h_dip, 1.5), c.h);
}

test "imageOrigin: the card hangs below the pointer, held by its title strip" {
    for (scales) |s| {
        const card = cardSize(2000, 1200, s);
        const img = imageSize(card, s);
        const lay = layout(card, s);
        const p: Point = .{ .x = 900, .y = 500 };
        const o = imageOrigin(p, img, s);
        // Horizontally centred on the pointer.
        try testing.expect(@abs((o.x + @divTrunc(img.w, 2)) - p.x) <= 1);
        // The pointer is inside the title strip, so the body is below it.
        const strip_top = o.y + lay.title.top;
        const strip_bottom = o.y + lay.title.bottom;
        try testing.expect(p.y >= strip_top and p.y < strip_bottom);
        try testing.expect(o.y + lay.body.top > p.y);
    }
}

test "layout: title strip on top, body below, inside the margin" {
    for (scales) |s| {
        const card = cardSize(1000, 700, s);
        const lay = layout(card, s);
        try testing.expectEqual(px(margin_dip, s), lay.card.left);
        try testing.expectEqual(px(title_dip, s), lay.title.height());
        try testing.expectEqual(lay.title.bottom, lay.body.top);
        try testing.expectEqual(lay.card.bottom, lay.body.bottom);
        try testing.expectEqual(card.w, lay.card.width());
    }
}

test "contentRequest covers the body at the pane's aspect" {
    const r = contentRequest(1600, 900, .{ .w = 220, .h = 106 });
    try testing.expect(r.w >= 220 and r.h >= 106);
    const aspect = @as(f32, @floatFromInt(r.w)) / @as(f32, @floatFromInt(r.h));
    try testing.expectApproxEqAbs(@as(f32, 16.0 / 9.0), aspect, 0.03);
    // A tall pane covers by width.
    const t = contentRequest(400, 1200, .{ .w = 120, .h = 54 });
    try testing.expectEqual(@as(i32, 120), t.w);
}

test "inkFor: black on light, white on dark" {
    try testing.expect(inkFor(.{ .r = 250, .g = 250, .b = 250 }).r == 0);
    try testing.expect(inkFor(.{ .r = 20, .g = 20, .b = 30 }).r == 255);
}

test "text reads on the strip: contrast at least 4.5:1 for typical backgrounds" {
    const bgs = [_]Rgb{
        .{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
        .{ .r = 0x28, .g = 0x2c, .b = 0x34 },
        .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .{ .r = 0xfd, .g = 0xf6, .b = 0xe3 },
        .{ .r = 0x00, .g = 0x00, .b = 0x00 },
    };
    for (bgs) |bg| {
        const ratio = contrast(textColor(bg), stripColor(bg));
        try testing.expect(ratio >= 4.5);
    }
}

fn relLum(c: Rgb) f64 {
    const ch = struct {
        fn f(v: u8) f64 {
            const s = @as(f64, @floatFromInt(v)) / 255.0;
            return if (s <= 0.03928) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
        }
    };
    return 0.2126 * ch.f(c.r) + 0.7152 * ch.f(c.g) + 0.0722 * ch.f(c.b);
}

fn contrast(a: Rgb, b: Rgb) f64 {
    const la = relLum(a);
    const lb = relLum(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

test "fillCard + finalize: an opaque rounded card with a shadow below it" {
    const s: f32 = 1.0;
    const card = cardSize(1600, 900, s);
    const img = imageSize(card, s);
    const lay = layout(card, s);
    const w: usize = @intCast(img.w);
    const h: usize = @intCast(img.h);
    const buf = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(buf);
    const bg: Rgb = .{ .r = 0x20, .g = 0x30, .b = 0x40 };
    fillCard(buf, w, h, lay, bg);
    finalize(buf, w, h, lay, bg, s);

    // The middle of the body: opaque background.
    const mid = buf[@as(usize, @intCast(lay.body.top + 20)) * w + w / 2];
    try testing.expectEqual(@as(u32, 0xFF), mid >> 24);
    try testing.expectEqual(pack(bg), mid);

    // The title strip is tinted toward white on a dark card.
    const strip = buf[@as(usize, @intCast(lay.title.top + 5)) * w + w / 2];
    try testing.expectEqual(pack(stripColor(bg)), strip);
    try testing.expect(((strip >> 16) & 0xFF) > bg.r);

    // The outer corner pixel is cut away (no card, at most faint shadow).
    const corner = buf[@as(usize, @intCast(lay.card.top)) * w + @as(usize, @intCast(lay.card.left))];
    try testing.expect((corner >> 24) < 0x80);

    // Below the card, the shadow: translucent black.
    const below = buf[@as(usize, @intCast(lay.card.bottom + 1)) * w + w / 2];
    try testing.expect((below >> 24) > 0 and (below >> 24) < 0xFF);
    try testing.expectEqual(@as(u32, 0), below & 0xFF_FFFF);

    // Far outside (image corner): nothing at all.
    try testing.expectEqual(@as(u32, 0), buf[0]);

    // Premultiplied everywhere: no colour channel exceeds alpha.
    for (buf) |p| {
        const a = p >> 24;
        try testing.expect(((p >> 16) & 0xFF) <= a);
        try testing.expect(((p >> 8) & 0xFF) <= a);
        try testing.expect((p & 0xFF) <= a);
    }
}

test "finalize draws the rim on the card's edge" {
    const s: f32 = 1.0;
    const card = cardSize(1600, 900, s);
    const img = imageSize(card, s);
    const lay = layout(card, s);
    const w: usize = @intCast(img.w);
    const h: usize = @intCast(img.h);
    const buf = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(buf);
    const bg: Rgb = .{ .r = 0x10, .g = 0x10, .b = 0x10 };
    fillCard(buf, w, h, lay, bg);
    finalize(buf, w, h, lay, bg, s);
    // The left edge, mid-body: lighter than the background (white rim on dark).
    const y: usize = @intCast(lay.body.top + 30);
    const edge = buf[y * w + @as(usize, @intCast(lay.card.left))];
    const inner = buf[y * w + @as(usize, @intCast(lay.card.left + 4))];
    try testing.expect(((edge >> 16) & 0xFF) > ((inner >> 16) & 0xFF));
}

test "drawContent covers the body from the top-left of a bottom-up frame" {
    const w: usize = 40;
    const h: usize = 40;
    var buf: [w * h]u32 = undefined;
    @memset(&buf, 0xFF000000);
    // A 4x4 bottom-up frame: its TOP row (stored last) is red, the rest blue.
    var frame: [16]u32 = undefined;
    @memset(&frame, 0xFF0000FF);
    for (12..16) |i| frame[i] = 0xFFFF0000;
    const body: Rect = .{ .left = 0, .top = 10, .right = 40, .bottom = 40 };
    drawContent(&buf, w, h, body, &frame, 4, 4, .{ .w = 4, .h = 4 });
    // Top of the body is red (the frame's top row), lower down is blue.
    try testing.expectEqual(@as(u32, 0xFFFF0000), buf[10 * w + 5]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), buf[38 * w + 5]);
    // Above the body untouched.
    try testing.expectEqual(@as(u32, 0xFF000000), buf[5 * w + 5]);
}

test "drawContent ignores a frame too small for its stated size" {
    var buf: [16]u32 = undefined;
    @memset(&buf, 7);
    const frame = [_]u32{ 1, 2 };
    drawContent(&buf, 4, 4, .{ .left = 0, .top = 0, .right = 4, .bottom = 4 }, &frame, 4, 4, .{ .w = 4, .h = 4 });
    for (buf) |p| try testing.expectEqual(@as(u32, 7), p);
}

test "wantsGhost: grab handle and header drags only" {
    try testing.expect(wantsGhost(false, false));
    try testing.expect(!wantsGhost(true, false));
    try testing.expect(!wantsGhost(false, true));
}
