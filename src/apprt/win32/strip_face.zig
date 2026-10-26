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
        .hovered = false,
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
