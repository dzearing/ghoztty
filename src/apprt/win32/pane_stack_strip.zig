//! What a tucked pane's strip looks like (T2109, the third slice of T2101):
//! Mac `PaneStackTabFace`, as the numbers the window's painter reads.
//!
//! A pane tucked into a stack (`pane_stack_layout`) shows only its strip - a
//! dark band of the pane's own colour down the card's leading edge (a row's
//! stack) or across its top (a column's), with the pane's name along it. The
//! name is the one the pane sidebar gives it: the banner's title first
//! (`pane_sidebar.paneLabel`). A click on the strip brings the pane forward.
//!
//! Pure, so the tests need no window: the colours, where the label sits, and
//! how a name too long for its strip is cut (in the middle, as Mac's
//! `.truncationMode(.middle)` does, so both ends of a path survive).

const std = @import("std");
const testing = std.testing;
const color_math = @import("color_math.zig");
const Rgb = color_math.Rgb;
const desk_palette = @import("desk_palette.zig");
const pane_elevation = @import("pane_elevation.zig");
const Direction = @import("pane_stack_layout.zig").Direction;

/// The label's size and weight: Mac's 11 pt semibold.
pub const label_dip: f32 = 11;
pub const label_weight: i32 = 600;
/// The space the label keeps from each end of its strip: Mac's 12 pt padding
/// (a horizontal strip's text is `size - 24` long).
pub const label_inset_dip: f32 = 12;

const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };

/// The scrim that dims a tucked card (Mac `PaneCardView.updateScrim`): black
/// at 45% on a dark theme and 16% on a light one, lightened to 20% / 6% while
/// the card's strip is hovered (T2121).
pub fn scrimAlpha(light: bool, hovered: bool) f64 {
    return if (light)
        (if (hovered) 0.06 else 0.16)
    else
        (if (hovered) 0.2 else 0.45);
}

/// The strip's fill over a pane of background `bg`: the background darkened
/// (6% toward black on a light theme, 35% on a dark one), laid at 85% / 82%
/// over the pane's own colour as the card's scrim dims it - so the strip
/// lightens with the scrim while it is hovered (T2121). GDI has no alpha for
/// a flat fill, so the layers are resolved here into the opaque colour they
/// read as.
pub fn stripRgb(bg: Rgb, hovered: bool) Rgb {
    return stripOver(bg, bg, hovered);
}

/// The strip's fill where the pane under it shows `pane`: `stripRgb`'s
/// layers with the scrim laid over that pixel rather than over the flat
/// background. They differ on a glass pane (T2160), whose card is a sheet
/// of `bg` over the desk, so the desk tints the strip through it as it does
/// on Mac.
pub fn stripOver(pane: Rgb, bg: Rgb, hovered: bool) Rgb {
    const light = color_math.isLight(bg);
    const base = color_math.mix(bg, black, if (light) 0.06 else 0.35);
    const under = color_math.mix(pane, black, scrimAlpha(light, hovered));
    return color_math.mix(under, base, if (light) 0.85 else 0.82);
}

/// A strip on a glass pane (T2160): the pane's background, the sheet the
/// tucked card shows (every pane's is the same since T2281), and whether it
/// is hovered.
pub const Glass = struct {
    bg: Rgb,
    sheet: pane_elevation.Sheet,
    hovered: bool,
};

/// `stripOver` a glass sheet, per desk channel value, as byte tables: every
/// layer - the sheet's linear-light mix, the scrim, the strip - works on
/// each channel alone, so one lookup per channel is the whole answer.
pub const GlassLut = struct {
    r: [256]u8,
    g: [256]u8,
    b: [256]u8,

    pub fn init(glass: Glass) GlassLut {
        var l: GlassLut = undefined;
        for (0..256) |i| {
            const c: u32 = @intCast(i);
            const s = pane_elevation.sheetMix((c << 16) | (c << 8) | c, glass.bg, glass.sheet);
            const out = stripOver(.{
                .r = @truncate(s >> 16),
                .g = @truncate(s >> 8),
                .b = @truncate(s),
            }, glass.bg, glass.hovered);
            l.r[i] = out.r;
            l.g[i] = out.g;
            l.b[i] = out.b;
        }
        return l;
    }

    /// The strip over desk pixel `desk` (0x00RRGGBB; the alpha byte is
    /// ignored).
    pub fn at(l: *const GlassLut, desk: u32) Rgb {
        return .{
            .r = l.r[(desk >> 16) & 0xFF],
            .g = l.g[(desk >> 8) & 0xFF],
            .b = l.b[desk & 0xFF],
        };
    }
};

/// The label's ink on `strip`: black at 65% on a light theme, white at 75% on
/// a dark one, stronger while the strip is hovered.
pub fn inkRgb(strip: Rgb, light: bool, hovered: bool) Rgb {
    return if (light)
        color_math.mix(strip, black, if (hovered) 0.85 else 0.65)
    else
        color_math.mix(strip, white, if (hovered) 0.95 else 0.75);
}

/// A strip rect, in pixels.
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(r: Rect) i32 {
        return r.right - r.left;
    }
    pub fn height(r: Rect) i32 {
        return r.bottom - r.top;
    }
};

/// One strip as the desk composite paints it (`PaneDesk.paint`): where, which
/// way its stack runs, and its resolved colour.
pub const Band = struct {
    tab: Rect,
    axis: Direction,
    rgb: Rgb,
    /// Set on a glass pane (T2160): the band is resolved per pixel over the
    /// sheet on the desk under it, and `rgb` is only the label's reference.
    glass: ?Glass = null,
    /// Whether the strip lies before its stack's run (`Leaf.strip_leads`):
    /// its blade shadow leans the other way, away from the run (T2307).
    leads: bool = true,
    /// How far into its strip the card is (T2307): 1 for a strip at rest,
    /// less for a card still gliding in or out, whose shadow is faded by it.
    collapse: f32 = 1,
    /// False for a card still gliding (T2287): it is a card until the glide
    /// reaches the strip, so only its shadow is laid here, in paint order.
    band: bool = true,
};

/// Paint a strip's band into a desk composite (`PaneDesk`; 0x00RRGGBB with
/// coverage in the alpha byte, `desk_palette.coverage`), in the elevated
/// style (T2121): the pane's own card at the strip's size, so all four
/// corners are the card's `radius`, antialiased against what is already there
/// (Mac `PaneCardView`'s clip, T2283). A strip that reaches under the one in
/// front of it (`pane_stack_layout.Metrics.blade_tuck`) has its run-side
/// corners out of sight under that one, so a stack of strips reads as bars
/// laid over one another. `tab` is in buffer pixels and is clipped to the
/// buffer; `radius` 0 paints a plain band.
pub fn paintBand(buf: []u32, w: usize, h: usize, tab: Rect, axis: Direction, rgb: Rgb, radius: i32) void {
    paintWith(buf, w, h, tab, axis, radius, Solid{ .rgb = rgb });
}

/// `paintBand` on a glass pane (T2160): each pixel is the strip over the
/// sheet on `desk` there (the bare desk, `w` x `h` like `buf`), rather than
/// one colour resolved over the opaque background.
pub fn paintGlassBand(buf: []u32, desk: []const u32, w: usize, h: usize, tab: Rect, axis: Direction, glass: Glass, radius: i32) void {
    std.debug.assert(desk.len >= w * h);
    const lut = GlassLut.init(glass);
    paintWith(buf, w, h, tab, axis, radius, OverDesk{ .lut = &lut, .desk = desk });
}

const Solid = struct {
    rgb: Rgb,
    fn at(self: Solid, _: usize) Rgb {
        return self.rgb;
    }
};

const OverDesk = struct {
    lut: *const GlassLut,
    desk: []const u32,
    fn at(self: OverDesk, i: usize) Rgb {
        return self.lut.at(self.desk[i]);
    }
};

fn paintWith(buf: []u32, w: usize, h: usize, tab: Rect, axis: Direction, radius: i32, source: anytype) void {
    const x0: i32 = @max(tab.left, 0);
    const y0: i32 = @max(tab.top, 0);
    const x1: i32 = @min(tab.right, @as(i32, @intCast(w)));
    const y1: i32 = @min(tab.bottom, @as(i32, @intCast(h)));
    if (x1 <= x0 or y1 <= y0) return;
    // Never more than half the side the two corners share, nor more than
    // the other side, as SwiftUI clamps an uneven rectangle's radii.
    const shared, const other = switch (axis) {
        .horizontal => .{ tab.height(), tab.width() },
        .vertical => .{ tab.width(), tab.height() },
    };
    const rad: i32 = @max(0, @min(radius, @min(@divTrunc(shared, 2), other)));
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = @as(usize, @intCast(y)) * w;
        var x = x0;
        while (x < x1) : (x += 1) {
            const i = row + @as(usize, @intCast(x));
            const a = bandCoverage(tab, axis, rad, x, y);
            if (a <= 0) continue;
            const rgb = source.at(i);
            if (a >= 1) {
                buf[i] = desk_palette.packRgb(rgb.r, rgb.g, rgb.b) | 0xFF00_0000;
                continue;
            }
            const src: desk_palette.Rgbf = .{
                .r = @floatFromInt(rgb.r),
                .g = @floatFromInt(rgb.g),
                .b = @floatFromInt(rgb.b),
            };
            const dst = buf[i];
            buf[i] = desk_palette.withCoverage(
                desk_palette.Rgbf.lerp(desk_palette.Rgbf.unpack(dst), src, a).pack(),
                desk_palette.coverOver(desk_palette.coverage(dst), a),
            );
        }
    }
}

/// How much of pixel (x, y) the band covers, 0..1: all of it off the corner
/// squares, and inside one the antialiased quarter circle of radius `rad`
/// (pixel centre, half a pixel either side of the curve).
pub fn bandCoverage(tab: Rect, axis: Direction, rad: i32, x: i32, y: i32) f32 {
    _ = axis;
    if (rad <= 0) return 1;
    const in_corner = (x < tab.left + rad or x >= tab.right - rad) and
        (y < tab.top + rad or y >= tab.bottom - rad);
    if (!in_corner) return 1;
    const r: f32 = @floatFromInt(rad);
    const px: f32 = @as(f32, @floatFromInt(x)) + 0.5;
    const py: f32 = @as(f32, @floatFromInt(y)) + 0.5;
    const l: f32 = @floatFromInt(tab.left);
    const t: f32 = @floatFromInt(tab.top);
    const rt: f32 = @floatFromInt(tab.right);
    const b: f32 = @floatFromInt(tab.bottom);
    const cx = if (px < l + r) l + r else rt - r;
    const cy = if (py < t + r) t + r else b - r;
    const d = @sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy)) - r;
    return std.math.clamp(0.5 - d, 0, 1);
}

/// The part of a strip that shows, where its name is centred (Mac afc64dc53
/// `PaneCardView.titleRect`): `tab` less the `tuck` pixels that reach under
/// the strip in front of it, toward the run - past the trailing edge of a
/// strip before the run (`leads`), past the leading edge of one after it. A
/// strip no longer than its tuck is left whole.
pub fn visiblePart(tab: Rect, axis: Direction, leads: bool, tuck: i32) Rect {
    if (tuck <= 0) return tab;
    const along = switch (axis) {
        .horizontal => tab.width(),
        .vertical => tab.height(),
    };
    if (along <= tuck) return tab;
    var r = tab;
    switch (axis) {
        .horizontal => if (leads) {
            r.right -= tuck;
        } else {
            r.left += tuck;
        },
        .vertical => if (leads) {
            r.bottom -= tuck;
        } else {
            r.top += tuck;
        },
    }
    return r;
}

/// The length the label may run along a strip, in pixels: the strip's long
/// side less the inset at each end. 0 when the strip is too short for any.
pub fn labelRoom(tab: Rect, axis: Direction, scale: f32) i32 {
    const inset: i32 = @intFromFloat(@round(label_inset_dip * scale));
    const long = switch (axis) {
        .horizontal => tab.height(),
        .vertical => tab.width(),
    };
    return @max(0, long - 2 * inset);
}

/// Where the label's text starts, for a run `text_len` pixels long and
/// `text_h` pixels tall, as `TextOutW` takes it with `TA_LEFT | TA_TOP`.
///
/// - `.horizontal` (a tall strip): the text reads top to bottom, as a book's
///   spine on a shelf does, centred both ways. It is drawn with a font turned
///   270 degrees, whose cell lies to the LEFT of its origin (the glyphs' tops
///   face right), so the origin sits half the text height right of centre.
/// - `.vertical` (a short strip across the top): left-aligned after the inset,
///   centred down the strip.
pub fn labelOrigin(tab: Rect, axis: Direction, text_len: i32, text_h: i32, scale: f32) struct { x: i32, y: i32 } {
    const inset: i32 = @intFromFloat(@round(label_inset_dip * scale));
    return switch (axis) {
        .horizontal => .{
            .x = tab.left + @divTrunc(tab.width() + text_h, 2),
            .y = tab.top + @max(inset, @divTrunc(tab.height() - text_len, 2)),
        },
        .vertical => .{
            .x = tab.left + inset,
            .y = tab.top + @divTrunc(tab.height() - text_h, 2),
        },
    };
}

/// `text` cut in the middle to `keep` UTF-16 units plus an ellipsis between
/// the halves (the head takes the odd one), written into `out`. The whole
/// text when it already fits in `keep`. A surrogate pair is never split: a
/// half that would end (or start) inside one gives that unit up.
pub fn middleCut(text: []const u16, keep: usize, out: []u16) []const u16 {
    if (text.len <= keep) {
        const n = @min(text.len, out.len);
        @memcpy(out[0..n], text[0..n]);
        return out[0..n];
    }
    if (out.len == 0) return out[0..0];
    var head = (keep + 1) / 2;
    var tail = keep - head;
    // A high surrogate at the head's end would be cut from its partner.
    if (head > 0 and isHigh(text[head - 1])) head -= 1;
    // A low surrogate at the tail's start lost its partner to the cut.
    if (tail > 0 and isLow(text[text.len - tail])) tail -= 1;
    const n = @min(head + 1 + tail, out.len);
    var i: usize = 0;
    for (text[0..head]) |c| {
        if (i >= n) break;
        out[i] = c;
        i += 1;
    }
    if (i < n) {
        out[i] = 0x2026;
        i += 1;
    }
    for (text[text.len - tail ..]) |c| {
        if (i >= n) break;
        out[i] = c;
        i += 1;
    }
    return out[0..i];
}

fn isHigh(c: u16) bool {
    return c >= 0xD800 and c <= 0xDBFF;
}

fn isLow(c: u16) bool {
    return c >= 0xDC00 and c <= 0xDFFF;
}

// ---------------------------------------------------------------------
// Tests

test "pane_stack_strip: the strip is darker than the pane on both themes, and the ink reads on it" {
    const dark_bg: Rgb = .{ .r = 0x28, .g = 0x2c, .b = 0x34 };
    const light_bg: Rgb = .{ .r = 0xfa, .g = 0xfa, .b = 0xfa };
    const ds = stripRgb(dark_bg, false);
    const ls = stripRgb(light_bg, false);
    try testing.expect(color_math.luminance(ds) < color_math.luminance(dark_bg));
    try testing.expect(color_math.luminance(ls) < color_math.luminance(light_bg));
    // Mac's layers over #282c34: the 82% strip over the pane under a 45%
    // scrim.
    try testing.expectEqual(Rgb{ .r = 25, .g = 28, .b = 33 }, ds);
    // A light theme's strip is only a shade or two darker (6% x 85% over a
    // 16% scrim).
    try testing.expectEqual(@as(u8, 231), ls.r);
    // Dark ink on light, light ink on dark; the hovered ink is the stronger.
    const dl = inkRgb(ds, false, false);
    const dh = inkRgb(ds, false, true);
    try testing.expect(dl.r > ds.r and dh.r > dl.r);
    const ll = inkRgb(ls, true, false);
    const lh = inkRgb(ls, true, true);
    try testing.expect(ll.r < ls.r and lh.r < ll.r);
}

test "pane_stack_strip: hovering a strip lightens its card's scrim, so the strip lightens with it" {
    const dark_bg: Rgb = .{ .r = 0x28, .g = 0x2c, .b = 0x34 };
    const light_bg: Rgb = .{ .r = 0xfa, .g = 0xfa, .b = 0xfa };
    // Mac's numbers: 45% -> 20% dark, 16% -> 6% light.
    try testing.expectEqual(@as(f64, 0.45), scrimAlpha(false, false));
    try testing.expectEqual(@as(f64, 0.2), scrimAlpha(false, true));
    try testing.expectEqual(@as(f64, 0.16), scrimAlpha(true, false));
    try testing.expectEqual(@as(f64, 0.06), scrimAlpha(true, true));
    const dh = stripRgb(dark_bg, true);
    try testing.expectEqual(Rgb{ .r = 27, .g = 30, .b = 35 }, dh);
    const d = stripRgb(dark_bg, false);
    try testing.expect(color_math.luminance(dh) > color_math.luminance(d));
    try testing.expect(color_math.luminance(stripRgb(light_bg, true)) > color_math.luminance(stripRgb(light_bg, false)));
    // Still darker than the pane itself.
    try testing.expect(color_math.luminance(dh) < color_math.luminance(dark_bg));
}

test "pane_stack_strip: an elevated band is a card at strip size - every corner rounded, antialiased" {
    const w = 60;
    const h = 120;
    const desk: u32 = desk_palette.packRgb(10, 200, 10);
    var buf = [_]u32{desk} ** (w * h);
    const rgb: Rgb = .{ .r = 25, .g = 28, .b = 33 };
    const solid = desk_palette.packRgb(25, 28, 33) | 0xFF00_0000;
    // A tall strip at x 10..40, y 10..110, radius 12.
    const tab: Rect = .{ .left = 10, .top = 10, .right = 40, .bottom = 110 };
    paintBand(&buf, w, h, tab, .horizontal, rgb, 12);
    // The very corner pixels, at both ends of both edges, are desk (T2283:
    // Mac's strip is the card's own clip, rounded all round).
    try testing.expectEqual(desk, buf[10 * w + 10]);
    try testing.expectEqual(desk, buf[109 * w + 10]);
    try testing.expectEqual(desk, buf[10 * w + 39]);
    try testing.expectEqual(desk, buf[109 * w + 39]);
    // Mid-edge and inside: band.
    try testing.expectEqual(solid, buf[60 * w + 10]);
    try testing.expectEqual(solid, buf[60 * w + 39]);
    try testing.expectEqual(solid, buf[10 * w + 25]);
    // Outside the tab: untouched.
    try testing.expectEqual(desk, buf[60 * w + 9]);
    try testing.expectEqual(desk, buf[60 * w + 40]);
    // Somewhere on the top-left curve a pixel is a blend, partly covered.
    var blended = false;
    for (10..22) |yy| for (10..22) |xx| {
        const c = desk_palette.coverage(buf[yy * w + xx]);
        if (c > 0 and c < 1) blended = true;
    };
    try testing.expect(blended);

    // A short strip: all four round too.
    var buf2 = [_]u32{desk} ** (w * h);
    const across: Rect = .{ .left = 5, .top = 5, .right = 55, .bottom = 35 };
    paintBand(&buf2, w, h, across, .vertical, rgb, 12);
    try testing.expectEqual(desk, buf2[5 * w + 5]);
    try testing.expectEqual(desk, buf2[5 * w + 54]);
    try testing.expectEqual(desk, buf2[34 * w + 5]);
    try testing.expectEqual(desk, buf2[34 * w + 54]);
    try testing.expectEqual(solid, buf2[20 * w + 30]);

    // Two blades, the outer one reaching under the inner (painted after it):
    // where the inner one's corner curves away, the outer one's band shows,
    // not the desk - bars laid over one another, not pills touching.
    var buf4 = [_]u32{desk} ** (w * h);
    paintBand(&buf4, w, h, .{ .left = 0, .top = 10, .right = 40, .bottom = 110 }, .horizontal, rgb, 12);
    paintBand(&buf4, w, h, .{ .left = 18, .top = 10, .right = 48, .bottom = 110 }, .horizontal, rgb, 12);
    try testing.expectEqual(solid, buf4[10 * w + 18]);
    try testing.expectEqual(solid, buf4[109 * w + 18]);
    // The outer one's own outward corner still curves away from the desk.
    try testing.expectEqual(desk, buf4[10 * w + 0]);

    // Radius 0 is a plain band; a band off the buffer is clipped, not a crash.
    var buf3 = [_]u32{desk} ** (w * h);
    paintBand(&buf3, w, h, .{ .left = -5, .top = -5, .right = 20, .bottom = 20 }, .horizontal, rgb, 0);
    try testing.expectEqual(solid, buf3[0]);
    try testing.expectEqual(desk, buf3[20 * w + 20]);
}

test "pane_stack_strip: on glass the strip is resolved over the sheet, so the desk tints it" {
    const bg: Rgb = .{ .r = 0x28, .g = 0x2c, .b = 0x34 };
    // Over a desk pixel that is the background itself, glass changes
    // nothing: the sheet over it is the background.
    const thin: pane_elevation.Sheet = .{};
    const lut = GlassLut.init(.{ .bg = bg, .sheet = thin, .hovered = false });
    const same = lut.at(desk_palette.packRgb(bg.r, bg.g, bg.b));
    try testing.expectEqual(stripRgb(bg, false), same);
    // Over a blue desk the strip leans blue, and over a red one red: the
    // opaque strip is the same colour on both.
    const blue = lut.at(desk_palette.packRgb(20, 60, 160));
    const red = lut.at(desk_palette.packRgb(160, 40, 30));
    try testing.expect(blue.b > same.b and blue.b > red.b);
    try testing.expect(red.r > same.r and red.r > blue.r);
    // Still a dark band: darker than the sheet it sits on.
    const sheet = pane_elevation.sheetMix(desk_palette.packRgb(20, 60, 160), bg, thin);
    try testing.expect(color_math.luminance(blue) < color_math.luminance(.{
        .r = @truncate(sheet >> 16),
        .g = @truncate(sheet >> 8),
        .b = @truncate(sheet),
    }));
    // Hovered lightens it, as on an opaque pane.
    const hl = GlassLut.init(.{ .bg = bg, .sheet = thin, .hovered = true });
    try testing.expect(color_math.luminance(hl.at(desk_palette.packRgb(20, 60, 160))) > color_math.luminance(blue));
    // The table is the per-pixel layers exactly.
    const d: u32 = desk_palette.packRgb(90, 120, 200);
    const s = pane_elevation.sheetMix(d, bg, thin);
    try testing.expectEqual(stripOver(.{
        .r = @truncate(s >> 16),
        .g = @truncate(s >> 8),
        .b = @truncate(s),
    }, bg, false), lut.at(d));
}

test "pane_stack_strip: a glass band follows the desk under each pixel and keeps the rounded corners" {
    const w = 40;
    const h = 60;
    const bg: Rgb = .{ .r = 0x28, .g = 0x2c, .b = 0x34 };
    // A desk that runs from blue at the top to red at the bottom.
    var desk: [w * h]u32 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const t: u32 = @intCast(y * 255 / (h - 1));
        desk[y * w + x] = desk_palette.packRgb(@intCast(t), 40, @intCast(255 - t)) | 0xFF00_0000;
    };
    var buf = desk;
    const glass: Glass = .{ .bg = bg, .sheet = .{}, .hovered = false };
    const tab: Rect = .{ .left = 5, .top = 5, .right = 25, .bottom = 55 };
    paintGlassBand(&buf, &desk, w, h, tab, .horizontal, glass, 8);
    const lut = GlassLut.init(glass);
    // Inside: the strip over that row's desk, opaque; the rows differ.
    const top = lut.at(desk[10 * w + 15]);
    const bottom = lut.at(desk[50 * w + 15]);
    try testing.expectEqual(desk_palette.packRgb(top.r, top.g, top.b) | 0xFF00_0000, buf[10 * w + 15]);
    try testing.expectEqual(desk_palette.packRgb(bottom.r, bottom.g, bottom.b) | 0xFF00_0000, buf[50 * w + 15]);
    try testing.expect(top.b > bottom.b and bottom.r > top.r);
    // Every corner is still desk (T2283), and mid-edge is band.
    try testing.expectEqual(desk[5 * w + 5], buf[5 * w + 5]);
    try testing.expectEqual(desk[5 * w + 24], buf[5 * w + 24]);
    const me = lut.at(desk[30 * w + 24]);
    try testing.expectEqual(desk_palette.packRgb(me.r, me.g, me.b) | 0xFF00_0000, buf[30 * w + 24]);
    // Outside the tab: untouched.
    try testing.expectEqual(desk[30 * w + 30], buf[30 * w + 30]);
}

test "pane_stack_strip: a tall strip's label runs down its middle; a short one's starts after the inset" {
    const tall: Rect = .{ .left = 100, .top = 50, .right = 130, .bottom = 450 };
    // 400 px long less 2 x 15 px inset at 1.25x.
    try testing.expectEqual(@as(i32, 370), labelRoom(tall, .horizontal, 1.25));
    const o = labelOrigin(tall, .horizontal, 100, 14, 1.25);
    // Centred across: the rotated cell [x - 14, x) straddles the strip's middle.
    try testing.expectEqual(@as(i32, 122), o.x);
    try testing.expectEqual(@as(i32, 115), o.x - 14 + 7);
    // Centred along.
    try testing.expectEqual(@as(i32, 200), o.y);
    // Never closer to the end than the inset, however long the text.
    try testing.expectEqual(@as(i32, 65), labelOrigin(tall, .horizontal, 1000, 14, 1.25).y);

    const short: Rect = .{ .left = 10, .top = 20, .right = 410, .bottom = 50 };
    try testing.expectEqual(@as(i32, 370), labelRoom(short, .vertical, 1.25));
    const v = labelOrigin(short, .vertical, 100, 14, 1.25);
    try testing.expectEqual(@as(i32, 25), v.x);
    try testing.expectEqual(@as(i32, 28), v.y);
    // A strip shorter than both insets has no room at all.
    try testing.expectEqual(@as(i32, 0), labelRoom(.{ .left = 0, .top = 0, .right = 20, .bottom = 30 }, .vertical, 1.25));
}

test "pane_stack_strip: a tucked strip's name centres on the part that shows" {
    const tab: Rect = .{ .left = 100, .top = 0, .right = 160, .bottom = 400 };
    // Before the run: the tuck is past its trailing edge.
    try testing.expectEqual(Rect{ .left = 100, .top = 0, .right = 145, .bottom = 400 }, visiblePart(tab, .horizontal, true, 15));
    // After it: past its leading edge.
    try testing.expectEqual(Rect{ .left = 115, .top = 0, .right = 160, .bottom = 400 }, visiblePart(tab, .horizontal, false, 15));
    // A column's strips tuck down the stack.
    const across: Rect = .{ .left = 0, .top = 50, .right = 400, .bottom = 110 };
    try testing.expectEqual(Rect{ .left = 0, .top = 50, .right = 400, .bottom = 95 }, visiblePart(across, .vertical, true, 15));
    try testing.expectEqual(Rect{ .left = 0, .top = 65, .right = 400, .bottom = 110 }, visiblePart(across, .vertical, false, 15));
    // No tuck, or a strip no longer than it: whole.
    try testing.expectEqual(tab, visiblePart(tab, .horizontal, true, 0));
    try testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 10, .bottom = 400 }, visiblePart(.{ .left = 0, .top = 0, .right = 10, .bottom = 400 }, .horizontal, true, 15));
}

test "pane_stack_strip: a long name is cut in the middle, keeping both ends" {
    const s = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Users\\me\\git\\project");
    var buf: [64]u16 = undefined;
    // Fits: unchanged.
    try testing.expectEqualSlices(u16, s, middleCut(s, s.len, &buf));
    // Cut to 8: four from the front, an ellipsis, four from the back.
    const cut = middleCut(s, 8, &buf);
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("C:\\U\u{2026}ject"), cut);
    // Odd keep: the head takes the extra one.
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("C:\\\u{2026}ct"), middleCut(s, 5, &buf));
    // Nothing kept is still an ellipsis, so the strip says a name is there.
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\u{2026}"), middleCut(s, 0, &buf));
}

test "pane_stack_strip: a cut never splits a surrogate pair" {
    // "a" + U+1F600 (a pair) + "bcdef" + U+1F600 + "g"
    const s = std.unicode.utf8ToUtf16LeStringLiteral("a\u{1F600}bcdef\u{1F600}g");
    var buf: [32]u16 = undefined;
    // keep 4: head 2 would end on the high half of the first pair; tail 2
    // would start on the low half of the second.
    const cut = middleCut(s, 4, &buf);
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("a\u{2026}g"), cut);
}
