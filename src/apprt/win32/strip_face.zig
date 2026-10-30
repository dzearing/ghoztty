//! The strip's face over a card gliding into or out of its strip (T2288;
//! Mac a81db68f9 `PaneCardView.collapse` / `PaneStackTabFace`): as the card
//! narrows its content fades out and its strip's title fades in, and the
//! reverse coming out, with nothing switched at the end.
//!
//! On Mac the content's alpha is `1 - collapse` and the title face's is
//! `collapse`. Here the content is a terminal (or a page) nobody can fade, so
//! the face is an opaque picture of the strip - its band and its name - laid
//! over what of the card is drawn at `collapse` constant alpha: the content
//! reads through it at `1 - collapse`, which is the same blend.
//!
//! Pure, so the tests need no window: how far in a card is, the face's
//! alpha, and its pixels.

const std = @import("std");
const testing = std.testing;
const grid = @import("pane_stack_grid.zig");
const color_math = @import("color_math.zig");
const pane_stack_slide = @import("pane_stack_slide.zig");
const pane_stack_strip = @import("pane_stack_strip.zig");
const Direction = @import("pane_stack_layout.zig").Direction;

const PxRect = grid.PxRect;
const Rgb = color_math.Rgb;

/// A strip's thickness, in DIP (Mac `PaneLayout.Metrics.peek`).
pub const peek_dip: f64 = 36;

/// A card drawn no wider than this is all strip: its peek and the tuck that
/// reaches under the strip in front of it, which is still just a strip (Mac
/// afc64dc53; T2283).
pub const strip_dip: f64 = peek_dip + @import("pane_stack_layout.zig").Metrics.blade_tuck;

/// Over how many DIP wider than a strip the fade runs (Mac
/// `PaneCardView.fadeSpan`): a card drawn this much wider than a strip shows
/// none of the face.
pub const fade_span_dip: f64 = 120;

/// How far into its strip a card is, from what of it is drawn (`visible`,
/// Mac `paneRect.intersection(clip)`): 0 for a card at least the fade span
/// wider than a strip, 1 for one no wider than a strip. An empty rect is not
/// drawn, so it is not anywhere.
pub fn collapseOf(visible: PxRect, scale: f32) f64 {
    const w = visible.width();
    const h = visible.height();
    if (w <= 0 or h <= 0) return 0;
    const s: f64 = @floatCast(scale);
    const extent: f64 = @floatFromInt(@min(w, h));
    return pane_stack_slide.collapse(extent, strip_dip * s, fade_span_dip * s);
}

/// Where the fade runs at `scale`, for the glide to cross it over three
/// frames at least (T2442, `pane_stack_slide.limitFade`).
pub fn fadeOf(scale: f32) pane_stack_slide.Fade {
    const s: f64 = @floatCast(scale);
    return .{ .strip = strip_dip * s, .span = fade_span_dip * s };
}

/// How far a card carrying its own content (T2457) is through its glide into
/// its strip, along the stack's axis: 0 at `full` (the pane's held length, the
/// card as it was on show), 1 at `strip`. The fade runs over the WHOLE tween,
/// not just its last `fade_span_dip` - the user's spec: no frame shows the
/// content at full strength on a narrow card. A pane hardly wider than a strip
/// still gets the span Mac's fade has, so it never crosses in a frame.
pub fn tweenCollapse(drawn: f64, strip: f64, full: f64, min_span: f64) f64 {
    const span = @max(full - strip, min_span);
    if (span <= 0) return if (drawn <= strip) 1 else 0;
    return std.math.clamp((full - drawn) / span, 0, 1);
}

/// A pane's last frame as its renderer read it back (T2457; `Surface`'s
/// snapshot: bottom-up, 0x??RRGGBB, alpha meaningless), `w` x `h`, and where
/// its top-left sits in the face - the pane is pinned to the card's far edge,
/// so it can start before the face's origin.
pub const Content = struct {
    pixels: []const u32,
    w: i32,
    h: i32,
    x: i32,
    y: i32,
};

/// Lay `content` over a `w` x `h` face at `alpha` (T2457): each pixel becomes
/// `alpha` of the content and the rest of what the face already holds (the
/// band and the strip's name), opaque. So one picture carries the card - the
/// content fading out as the title fades in - and nothing is composited over
/// a live window that moves on its own clock. A face pixel the content does
/// not cover keeps the band.
pub fn blendContent(buf: []u32, w: usize, h: usize, content: Content, alpha: u8) void {
    if (content.w <= 0 or content.h <= 0 or alpha == 0) return;
    if (content.pixels.len < @as(usize, @intCast(content.w)) * @as(usize, @intCast(content.h))) return;
    const a: u32 = alpha;
    const ia: u32 = 255 - a;
    const cw: usize = @intCast(content.w);
    for (0..h) |row| {
        const cy = @as(i32, @intCast(row)) - content.y;
        if (cy < 0 or cy >= content.h) continue;
        // Bottom-up: the face's top row is the frame's last.
        const src = content.pixels[@as(usize, @intCast(content.h - 1 - cy)) * cw ..][0..cw];
        const x0: i32 = @max(0, content.x);
        const x1: i32 = @min(@as(i32, @intCast(w)), content.x + content.w);
        if (x1 <= x0) continue;
        const dst = buf[row * w ..][@intCast(x0)..@intCast(x1)];
        const from = src[@intCast(x0 - content.x)..][0..dst.len];
        if (a == 255) {
            for (dst, from) |*p, c| p.* = 0xFF00_0000 | (c & 0xFF_FFFF);
            continue;
        }
        for (dst, from) |*p, c| {
            const b = p.*;
            const r = (((c >> 16) & 0xFF) * a + ((b >> 16) & 0xFF) * ia + 127) / 255;
            const g = (((c >> 8) & 0xFF) * a + ((b >> 8) & 0xFF) * ia + 127) / 255;
            const bl = ((c & 0xFF) * a + (b & 0xFF) * ia + 127) / 255;
            p.* = 0xFF00_0000 | (r << 16) | (g << 8) | bl;
        }
    }
}

/// How far a carried frame may be off the window it stands in for and still
/// count as fitting it, in px (T2485). The held rect is re-derived each frame
/// and can round a pixel away from the size the frame was read back at. A
/// fold carries its frame either way (`blendContent` pins and clips it); a
/// misfit past this is only logged, as the oracle for a window the drag kept
/// squeezing after the frame was read.
pub const carried_slack_px: i32 = 2;

/// Whether a carried frame `fw` x `fh` still fits a window `aw` x `ah`.
pub fn carriedFits(fw: i32, fh: i32, aw: i32, ah: i32) bool {
    return @abs(fw - aw) <= carried_slack_px and @abs(fh - ah) <= carried_slack_px;
}

/// The face's constant alpha for `collapse` (0..1).
pub fn alphaOf(collapse: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(collapse, 0, 1) * 255));
}

/// The axis a face's name reads along (Mac: the strip's own axis, else the
/// card's long side): a tall face is a horizontal stack's strip, read down.
pub fn axisOf(visible: PxRect, strip_axis: ?Direction) Direction {
    if (strip_axis) |a| return a;
    return if (visible.width() < visible.height()) .horizontal else .vertical;
}

/// One opaque pixel, as a top-down 32-bit DIB holds it (0xAARRGGBB).
pub fn pack(c: Rgb) u32 {
    return 0xFF00_0000 | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

/// Fill the face with a solid strip band (the flat style, and the solid
/// elevated one).
pub fn fillSolid(buf: []u32, rgb: Rgb) void {
    @memset(buf, pack(rgb));
}

/// The desk under a glass face: the cached gradient (`PaneDesk.Backdrop`'s
/// pixels, `w` x `h`), and where the face's top-left sits in it.
pub const Desk = struct {
    pixels: []const u32,
    w: i32,
    h: i32,
    x: i32,
    y: i32,
};

/// Fill a `w` x `h` face with the glass strip band (T2160): the strip laid
/// over the sheet over each desk pixel under it, as the desk paints the band
/// once the card is in. A face pixel off the desk takes the nearest edge's.
pub fn fillGlass(buf: []u32, w: usize, h: usize, desk: Desk, lut: *const pane_stack_strip.GlassLut) void {
    if (desk.w <= 0 or desk.h <= 0) return;
    for (0..h) |row| {
        const dy = std.math.clamp(desk.y + @as(i32, @intCast(row)), 0, desk.h - 1);
        const src = desk.pixels[@as(usize, @intCast(dy * desk.w))..][0..@intCast(desk.w)];
        const dst = buf[row * w ..][0..w];
        for (dst, 0..) |*p, col| {
            const dx = std.math.clamp(desk.x + @as(i32, @intCast(col)), 0, desk.w - 1);
            p.* = pack(lut.at(src[@intCast(dx)]));
        }
    }
}

/// GDI text leaves the alpha byte it draws over at whatever it likes; a
/// layered window reads it, so every pixel is made opaque again after the
/// name is drawn. The fade is the window's constant alpha, never per pixel.
pub fn makeOpaque(buf: []u32) void {
    for (buf) |*p| p.* |= 0xFF00_0000;
}

test "collapseOf: none wide, all at a strip and its tuck, half way between (T2288, T2283)" {
    const r = struct {
        fn of(w: i32, h: i32) PxRect {
            return .{ .left = 10, .top = 20, .right = 10 + w, .bottom = 20 + h };
        }
    }.of;
    try testing.expectEqual(@as(f64, 0), collapseOf(r(400, 600), 1));
    try testing.expectEqual(@as(f64, 0), collapseOf(r(168, 600), 1));
    try testing.expectApproxEqAbs(@as(f64, 0.5), collapseOf(r(108, 600), 1), 1e-9);
    // A strip reaching 12 DIP under the one in front is still all strip.
    try testing.expectEqual(@as(f64, 1), collapseOf(r(48, 600), 1));
    try testing.expectEqual(@as(f64, 1), collapseOf(r(36, 600), 1));
    // The smaller side, whichever it is: a short strip across the top.
    try testing.expectApproxEqAbs(@as(f64, 0.5), collapseOf(r(600, 108), 1), 1e-9);
    // In DIP: at 150% a strip and its tuck are 72 px and the span 180.
    try testing.expectApproxEqAbs(@as(f64, 0.5), collapseOf(r(162, 900), 1.5), 1e-9);
    try testing.expectEqual(@as(f64, 1), collapseOf(r(72, 900), 1.5));
    // Nothing drawn is no face.
    try testing.expectEqual(@as(f64, 0), collapseOf(r(0, 600), 1));
}

test "tweenCollapse: the fade runs over the whole tween, monotonic in the drawn length (T2457)" {
    // A 900 px pane folding into a 48 px strip: none of it at full length,
    // half at the midpoint, all at the strip, clamped past either end.
    try testing.expectEqual(@as(f64, 0), tweenCollapse(900, 48, 900, 120));
    try testing.expectApproxEqAbs(@as(f64, 0.5), tweenCollapse(474, 48, 900, 120), 1e-9);
    try testing.expectEqual(@as(f64, 1), tweenCollapse(48, 48, 900, 120));
    try testing.expectEqual(@as(f64, 1), tweenCollapse(30, 48, 900, 120));
    try testing.expectEqual(@as(f64, 0), tweenCollapse(950, 48, 900, 120));
    // Unlike Mac's last-120 fade, a card well wider than a strip is already
    // part way faded: 300 px of a 900 px pane is 70% of the way in.
    try testing.expect(tweenCollapse(300, 48, 900, 120) > 0.7);
    try testing.expectEqual(@as(f64, 0), pane_stack_slide.collapse(300, 48, 120));
    // Narrower is never less faded.
    var last: f64 = 0;
    var d: f64 = 900;
    while (d >= 48) : (d -= 7) {
        const c = tweenCollapse(d, 48, 900, 120);
        try testing.expect(c >= last);
        last = c;
    }
    // A pane hardly wider than a strip still fades over the minimum span.
    try testing.expectApproxEqAbs(@as(f64, 30.0 / 120.0), tweenCollapse(70, 48, 100, 120), 1e-9);
}

test "blendContent: the content over the band at alpha, pinned, bottom-up, opaque (T2457)" {
    const band: u32 = 0xFF00_0000;
    var buf = [_]u32{band} ** 6; // a 3x2 face
    // A 2x2 frame, bottom-up: its first row is the face's bottom row.
    const frame = [_]u32{ 0x00_0000FF, 0x00_00FF00, 0x00_FF0000, 0x00_FFFFFF };
    // Pinned one pixel right of the face's origin: the face's left column
    // keeps the band.
    blendContent(&buf, 3, 2, .{ .pixels = &frame, .w = 2, .h = 2, .x = 1, .y = 0 }, 255);
    try testing.expectEqual(band, buf[0]);
    try testing.expectEqual(@as(u32, 0xFFFF0000), buf[1]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[2]);
    try testing.expectEqual(band, buf[3]);
    try testing.expectEqual(@as(u32, 0xFF0000FF), buf[4]);
    try testing.expectEqual(@as(u32, 0xFF00FF00), buf[5]);

    // Half way: half the content, half the band - and the band can carry
    // the strip's name, which shows through at the rest.
    var half = [_]u32{0xFF20_2020};
    const white = [_]u32{0x00FF_FFFF};
    blendContent(&half, 1, 1, .{ .pixels = &white, .w = 1, .h = 1, .x = 0, .y = 0 }, 128);
    // (255 * 128 + 0x20 * 127 + 127) / 255 = 144.
    try testing.expectEqual(@as(u32, 0xFF909090), half[0]);

    // Nothing at alpha 0, and a frame pinned off the face draws nothing.
    var none = [_]u32{band} ** 2;
    blendContent(&none, 2, 1, .{ .pixels = &white, .w = 1, .h = 1, .x = 0, .y = 0 }, 0);
    blendContent(&none, 2, 1, .{ .pixels = &white, .w = 1, .h = 1, .x = -1, .y = 0 }, 255);
    blendContent(&none, 2, 1, .{ .pixels = &white, .w = 1, .h = 1, .x = 0, .y = 1 }, 255);
    try testing.expectEqual(band, none[0]);
    try testing.expectEqual(band, none[1]);
}

test "blendContent: a frame wider than the window it stands in for still covers it, clipped (T2485)" {
    // The run8 shape scaled down: read back at 4 wide, the drag then squeezed
    // the window to 3. Every face pixel is the frame's, never the band.
    const band: u32 = 0xFF00_0000;
    var buf = [_]u32{band} ** 3;
    const frame = [_]u32{ 0x00_000001, 0x00_000002, 0x00_000003, 0x00_000004 };
    blendContent(&buf, 3, 1, .{ .pixels = &frame, .w = 4, .h = 1, .x = 0, .y = 0 }, 255);
    try testing.expectEqual(@as(u32, 0xFF00_0001), buf[0]);
    try testing.expectEqual(@as(u32, 0xFF00_0002), buf[1]);
    try testing.expectEqual(@as(u32, 0xFF00_0003), buf[2]);
}

test "carriedFits: a pixel or two of rounding still fits, a real resize does not (T2485)" {
    try testing.expect(carriedFits(282, 923, 282, 923));
    // The run1 probe's shape: read back at 282, held at 281.
    try testing.expect(carriedFits(282, 923, 281, 923));
    try testing.expect(carriedFits(280, 921, 282, 923));
    try testing.expect(!carriedFits(282, 923, 279, 923));
    try testing.expect(!carriedFits(282, 923, 282, 900));
}

test "alphaOf: the collapse as a byte, clamped" {
    try testing.expectEqual(@as(u8, 0), alphaOf(0));
    try testing.expectEqual(@as(u8, 128), alphaOf(0.5));
    try testing.expectEqual(@as(u8, 255), alphaOf(1));
    try testing.expectEqual(@as(u8, 255), alphaOf(1.5));
    try testing.expectEqual(@as(u8, 0), alphaOf(-1));
}

test "axisOf: the strip's own axis, else the long side" {
    const tall: PxRect = .{ .left = 0, .top = 0, .right = 40, .bottom = 300 };
    const wide: PxRect = .{ .left = 0, .top = 0, .right = 300, .bottom = 40 };
    try testing.expectEqual(Direction.horizontal, axisOf(tall, null));
    try testing.expectEqual(Direction.vertical, axisOf(wide, null));
    try testing.expectEqual(Direction.vertical, axisOf(tall, .vertical));
}

test "fillSolid and makeOpaque: every pixel the band, opaque" {
    var buf = [_]u32{0x12345678} ** 6;
    fillSolid(&buf, .{ .r = 1, .g = 2, .b = 3 });
    for (buf) |p| try testing.expectEqual(@as(u32, 0xFF010203), p);
    buf[2] = 0x00AABBCC; // text drawn over it
    makeOpaque(&buf);
    try testing.expectEqual(@as(u32, 0xFFAABBCC), buf[2]);
}

test "fillGlass: each pixel the strip over the desk under it, clamped at the desk's edge" {
    const lut = pane_stack_strip.GlassLut.init(.{
        .bg = .{ .r = 30, .g = 30, .b = 40 },
        .sheet = .{},
    });
    // A 3x2 desk with a distinct pixel each.
    const desk = [_]u32{ 0x000000, 0x404040, 0x808080, 0x202020, 0x606060, 0xFFFFFF };
    var buf: [4]u32 = undefined;
    // A 2x2 face whose top-left sits at desk (2, 0): its right column is off
    // the desk and takes the edge's pixel.
    fillGlass(&buf, 2, 2, .{ .pixels = &desk, .w = 3, .h = 2, .x = 2, .y = 0 }, &lut);
    try testing.expectEqual(pack(lut.at(0x808080)), buf[0]);
    try testing.expectEqual(pack(lut.at(0x808080)), buf[1]);
    try testing.expectEqual(pack(lut.at(0xFFFFFF)), buf[2]);
    try testing.expectEqual(pack(lut.at(0xFFFFFF)), buf[3]);
    // Different desk pixels make different strip pixels: the desk shows through.
    try testing.expect(buf[0] != buf[2]);
}
