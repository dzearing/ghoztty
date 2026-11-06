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

/// A face being painted: `w` x `h` pixels, rows `stride` apart (T2461). The
/// face keeps one DIB for a whole glide, sized for the card at its widest, so
/// a narrower frame is a window onto it rather than a fresh bitmap.
pub const Frame = struct {
    pixels: []u32,
    stride: usize,
    w: usize,
    h: usize,

    pub fn row(self: Frame, y: usize) []u32 {
        return self.pixels[y * self.stride ..][0..self.w];
    }
};

/// The columns of a face row the content covers, `[x0, x1)`.
const Span = struct { x0: usize, x1: usize };

/// Where `content` lands on face row `y` of a `w`-wide face: the frame's row
/// (bottom-up: the face's top row is the frame's last) and the face columns
/// it covers. Null on a row it does not reach.
fn contentRow(content: Content, w: usize, y: usize) ?struct { src: []const u32, span: Span } {
    if (content.w <= 0 or content.h <= 0) return null;
    const cw: usize = @intCast(content.w);
    if (content.pixels.len < cw * @as(usize, @intCast(content.h))) return null;
    const cy = @as(i32, @intCast(y)) - content.y;
    if (cy < 0 or cy >= content.h) return null;
    const x0: i32 = @max(0, content.x);
    const x1: i32 = @min(@as(i32, @intCast(w)), content.x + content.w);
    if (x1 <= x0) return null;
    const src = content.pixels[@as(usize, @intCast(content.h - 1 - cy)) * cw ..][0..cw];
    return .{
        .src = src[@intCast(x0 - content.x)..][0..@intCast(x1 - x0)],
        .span = .{ .x0 = @intCast(x0), .x1 = @intCast(x1) },
    };
}

/// What of a face the content will cover completely, so the band under it
/// need not be painted (T2461): the content at full strength - a fold's first
/// frames, the widest and costliest - leaves nothing of the band to see.
pub const Hole = struct {
    content: Content,

    /// The face columns on row `y` the band may skip.
    fn at(self: ?Hole, w: usize, y: usize) ?Span {
        const hole = self orelse return null;
        const r = contentRow(hole.content, w, y) orelse return null;
        return r.span;
    }
};

/// The hole `content` at `alpha` leaves in the band: all of what it covers at
/// full strength, none of it otherwise.
pub fn holeOf(content: ?Content, alpha: u8) ?Hole {
    const c = content orelse return null;
    return if (alpha == 255) .{ .content = c } else null;
}

/// Lay `content` over the face at `alpha` and make every pixel opaque, in one
/// pass (T2457, T2461): each covered pixel becomes `alpha` of the content and
/// the rest of what the face already holds (the band and the strip's name),
/// and every other pixel keeps the band. So one picture carries the card -
/// the content fading out as the title fades in - and nothing is composited
/// over a live window that moves on its own clock. GDI text leaves the alpha
/// byte it draws over at whatever it likes, and a layered window reads it, so
/// the opaque pass is not optional; the fade is the content's, never the
/// window's.
pub fn finish(f: Frame, content: ?Content, alpha: u8) void {
    for (0..f.h) |y| {
        const dst = f.row(y);
        const r = if (content) |c| contentRow(c, f.w, y) else null;
        const covered: Span = if (alpha > 0 and r != null) r.?.span else .{ .x0 = f.w, .x1 = f.w };
        for (dst[0..covered.x0]) |*p| p.* |= 0xFF00_0000;
        for (dst[covered.x1..]) |*p| p.* |= 0xFF00_0000;
        if (covered.x0 == covered.x1) continue;
        blendRow(dst[covered.x0..covered.x1], r.?.src, alpha);
    }
}

/// `dst` = `alpha` of `src` over `dst`, opaque. Red and blue ride one u32 in
/// 16-bit lanes and green another; `(t + (t >> 8)) >> 8` with `t = x + 128`
/// is `x / 255` rounded, exactly, for every `x` a lane can hold here.
fn blendRow(dst: []u32, src: []const u32, alpha: u8) void {
    if (alpha == 255) {
        for (dst, src) |*p, c| p.* = 0xFF00_0000 | c;
        return;
    }
    // Eight pixels a step - a 4K fold blends some four million a frame - and
    // the tail one at a time, through the same arithmetic.
    const lanes = 8;
    const V = @Vector(lanes, u32);
    var i: usize = 0;
    while (i + lanes <= dst.len) : (i += lanes) {
        const c: V = src[i..][0..lanes].*;
        const b: V = dst[i..][0..lanes].*;
        dst[i..][0..lanes].* = blendPx(V, c, b, alpha);
    }
    for (dst[i..], src[i..]) |*p, c| p.* = blendPx(u32, c, p.*, alpha);
}

fn blendPx(comptime T: type, c: T, b: T, alpha: u8) T {
    const s = struct {
        fn k(v: u32) T {
            return if (T == u32) v else @splat(v);
        }
    }.k;
    const a = s(alpha);
    const ia = s(255 - @as(u32, alpha));
    const m_rb = s(0xFF00FF);
    const m_g = s(0xFF00);
    const sh8 = if (T == u32) @as(u5, 8) else @as(@Vector(@typeInfo(T).vector.len, u5), @splat(8));
    var rb = (c & m_rb) * a + (b & m_rb) * ia + s(0x0080_0080);
    rb = ((rb + ((rb >> sh8) & m_rb)) >> sh8) & m_rb;
    var g = (c & m_g) * a + (b & m_g) * ia + s(0x8000);
    g = ((g + ((g >> sh8) & m_g)) >> sh8) & m_g;
    return s(0xFF00_0000) | rb | g;
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

/// How many distinct colours (alpha ignored, up to 16) a 16 x 16 grid over a
/// `w` x `h` frame holds - a carried frame's log oracle (T2460): a page or a
/// terminal holds its text over its ground, a capture that failed into black
/// holds one.
pub fn sampleColors(pixels: []const u32, w: i32, h: i32) u32 {
    if (w <= 0 or h <= 0) return 0;
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    if (pixels.len < uw * uh) return 0;
    var seen: [16]u32 = undefined;
    var n: u32 = 0;
    for (0..16) |gy| {
        const y = (gy * 2 + 1) * uh / 32;
        for (0..16) |gx| {
            const x = (gx * 2 + 1) * uw / 32;
            const c = pixels[y * uw + x] & 0xFF_FFFF;
            if (std.mem.indexOfScalar(u32, seen[0..n], c) != null) continue;
            seen[n] = c;
            n += 1;
            if (n == seen.len) return n;
        }
    }
    return n;
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
/// elevated one), around `hole`.
pub fn fillSolid(f: Frame, rgb: Rgb, hole: ?Hole) void {
    const px = pack(rgb);
    for (0..f.h) |y| {
        const dst = f.row(y);
        if (Hole.at(hole, f.w, y)) |s| {
            @memset(dst[0..s.x0], px);
            @memset(dst[s.x1..], px);
        } else @memset(dst, px);
    }
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

/// Fill the face with the glass strip band (T2160) around `hole`: the strip
/// laid over the sheet over each desk pixel under it, as the desk paints the
/// band once the card is in. A face pixel off the desk takes the nearest
/// edge's.
pub fn fillGlass(f: Frame, desk: Desk, lut: *const pane_stack_strip.GlassLut, hole: ?Hole) void {
    if (desk.w <= 0 or desk.h <= 0) return;
    for (0..f.h) |y| {
        const dy = std.math.clamp(desk.y + @as(i32, @intCast(y)), 0, desk.h - 1);
        const src = desk.pixels[@as(usize, @intCast(dy * desk.w))..][0..@intCast(desk.w)];
        const dst = f.row(y);
        if (Hole.at(hole, f.w, y)) |s| {
            glassSpan(dst[0..s.x0], 0, src, desk.x, lut);
            glassSpan(dst[s.x1..], s.x1, src, desk.x, lut);
        } else glassSpan(dst, 0, src, desk.x, lut);
    }
}

/// Face columns `[x, x + dst.len)` of one band row over desk row `src`, the
/// face's column 0 at desk column `dx0`: the columns off the desk take its
/// edge pixel, and only those are clamped.
fn glassSpan(dst: []u32, x: usize, src: []const u32, dx0: i32, lut: *const pane_stack_strip.GlassLut) void {
    if (dst.len == 0) return;
    const dw: i32 = @intCast(src.len);
    const first: i32 = dx0 + @as(i32, @intCast(x));
    const n: i32 = @intCast(dst.len);
    // Face columns before the desk's left edge, on it, and past its right.
    const on0: usize = @intCast(std.math.clamp(-first, 0, n));
    const on1: usize = @intCast(std.math.clamp(dw - first, @as(i32, @intCast(on0)), n));
    if (on0 > 0) @memset(dst[0..on0], pack(lut.at(src[0])));
    if (on1 > on0) {
        const from = src[@intCast(first + @as(i32, @intCast(on0)))..][0 .. on1 - on0];
        // The desk is a smooth gradient upscaled from a small one, so a run
        // of equal pixels is the common case: the last lookup is reused
        // while the desk under it holds.
        var last_d: u32 = from[0];
        var last_p: u32 = pack(lut.at(last_d));
        for (dst[on0..on1], from) |*p, d| {
            if (d != last_d) {
                last_d = d;
                last_p = pack(lut.at(d));
            }
            p.* = last_p;
        }
    }
    if (on1 < dst.len) @memset(dst[on1..], pack(lut.at(src[src.len - 1])));
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

fn frameOf(buf: []u32, w: usize, h: usize) Frame {
    return .{ .pixels = buf, .stride = w, .w = w, .h = h };
}

test "finish: the content over the band at alpha, pinned, bottom-up, opaque (T2457)" {
    const band: u32 = 0xFF00_0000;
    var buf = [_]u32{band} ** 6; // a 3x2 face
    // A 2x2 frame, bottom-up: its first row is the face's bottom row.
    const frame = [_]u32{ 0x00_0000FF, 0x00_00FF00, 0x00_FF0000, 0x00_FFFFFF };
    // Pinned one pixel right of the face's origin: the face's left column
    // keeps the band.
    finish(frameOf(&buf, 3, 2), .{ .pixels = &frame, .w = 2, .h = 2, .x = 1, .y = 0 }, 255);
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
    finish(frameOf(&half, 1, 1), .{ .pixels = &white, .w = 1, .h = 1, .x = 0, .y = 0 }, 128);
    // (255 * 128 + 0x20 * 127 + 127) / 255 = 144.
    try testing.expectEqual(@as(u32, 0xFF909090), half[0]);

    // Nothing at alpha 0, and a frame pinned off the face draws nothing.
    var none = [_]u32{band} ** 2;
    finish(frameOf(&none, 2, 1), .{ .pixels = &white, .w = 1, .h = 1, .x = 0, .y = 0 }, 0);
    finish(frameOf(&none, 2, 1), .{ .pixels = &white, .w = 1, .h = 1, .x = -1, .y = 0 }, 255);
    finish(frameOf(&none, 2, 1), .{ .pixels = &white, .w = 1, .h = 1, .x = 0, .y = 1 }, 255);
    try testing.expectEqual(band, none[0]);
    try testing.expectEqual(band, none[1]);
}

test "finish: every pixel opaque, covered or not, and nothing past the frame's width touched (T2461)" {
    // GDI text leaves alpha 0 behind: a 2-wide frame on a 3-wide stride, half
    // covered by a frame at partial strength, no content in the second call.
    var buf = [_]u32{ 0x00AA_BBCC, 0x0011_2233, 0x0055_5555, 0x0001_0203, 0x0004_0506, 0x0055_5555 };
    const f: Frame = .{ .pixels = &buf, .stride = 3, .w = 2, .h = 2 };
    const one = [_]u32{0x00FF_FFFF};
    finish(f, .{ .pixels = &one, .w = 1, .h = 1, .x = 1, .y = 0 }, 100);
    try testing.expectEqual(@as(u32, 0xFFAA_BBCC), buf[0]);
    try testing.expect(buf[1] >> 24 == 0xFF and buf[1] != 0xFF11_2233);
    try testing.expectEqual(@as(u32, 0xFF01_0203), buf[3]);
    try testing.expectEqual(@as(u32, 0xFF04_0506), buf[4]);
    // The stride's spare column is not the frame's.
    try testing.expectEqual(@as(u32, 0x0055_5555), buf[2]);
    try testing.expectEqual(@as(u32, 0x0055_5555), buf[5]);
    var plain = [_]u32{ 0x0012_3456, 0x0065_4321 };
    finish(frameOf(&plain, 2, 1), null, 255);
    try testing.expectEqual(@as(u32, 0xFF12_3456), plain[0]);
    try testing.expectEqual(@as(u32, 0xFF65_4321), plain[1]);
}

test "blendRow: the packed lanes round exactly as (x + 127) / 255 per channel (T2461)" {
    var a: u32 = 0;
    while (a < 256) : (a += 1) {
        var c: u32 = 0;
        while (c < 256) : (c += 15) {
            var b: u32 = 0;
            while (b < 256) : (b += 17) {
                // Three channels apart, so a lane leak would show.
                const src = [_]u32{(c << 16) | (b << 8) | (255 - c)};
                var dst = [_]u32{(b << 16) | (c << 8) | (255 - b)};
                blendRow(&dst, &src, @intCast(a));
                const ch = struct {
                    fn of(x: u32, y: u32, al: u32) u32 {
                        return (x * al + y * (255 - al) + 127) / 255;
                    }
                }.of;
                const want = 0xFF00_0000 | (ch(c, b, a) << 16) | (ch(b, c, a) << 8) | ch(255 - c, 255 - b, a);
                try testing.expectEqual(want, dst[0]);
            }
        }
    }
}

test "holeOf: only content at full strength leaves the band a hole (T2461)" {
    const one = [_]u32{0};
    const c: Content = .{ .pixels = &one, .w = 1, .h = 1, .x = 0, .y = 0 };
    try testing.expect(holeOf(c, 255) != null);
    try testing.expect(holeOf(c, 254) == null);
    try testing.expect(holeOf(null, 255) == null);
}

test "sampleColors: a black frame holds one colour, a page holds more, alpha ignored (T2460)" {
    var black = [_]u32{0} ** (32 * 32);
    try testing.expectEqual(@as(u32, 1), sampleColors(&black, 32, 32));
    // Alpha is meaningless in a carried frame: an opaque black is still black.
    black[0] = 0xFF00_0000;
    try testing.expectEqual(@as(u32, 1), sampleColors(&black, 32, 32));
    // Text over a ground: alternate rows of two colours, and a third column.
    var page = [_]u32{0x00F0_F0F0} ** (32 * 32);
    for (0..32) |y| {
        if (y % 4 == 1) @memset(page[y * 32 ..][0..32], 0x0020_2020);
        page[y * 32 + 3] = 0x0000_66CC;
    }
    try testing.expectEqual(@as(u32, 3), sampleColors(&page, 32, 32));
    // Nothing to read: no frame, or a slice short of its size.
    try testing.expectEqual(@as(u32, 0), sampleColors(&page, 0, 32));
    try testing.expectEqual(@as(u32, 0), sampleColors(page[0..10], 32, 32));
}

test "finish: a frame wider than the window it stands in for still covers it, clipped (T2485)" {
    // The run8 shape scaled down: read back at 4 wide, the drag then squeezed
    // the window to 3. Every face pixel is the frame's, never the band.
    const band: u32 = 0xFF00_0000;
    var buf = [_]u32{band} ** 3;
    const frame = [_]u32{ 0x00_000001, 0x00_000002, 0x00_000003, 0x00_000004 };
    finish(frameOf(&buf, 3, 1), .{ .pixels = &frame, .w = 4, .h = 1, .x = 0, .y = 0 }, 255);
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

test "fillSolid: every pixel the band, opaque, around a hole and inside the stride" {
    var buf = [_]u32{0x12345678} ** 6;
    fillSolid(frameOf(&buf, 3, 2), .{ .r = 1, .g = 2, .b = 3 }, null);
    for (buf) |p| try testing.expectEqual(@as(u32, 0xFF010203), p);

    // A 3x2 frame on a 4-wide stride, with content at full strength over its
    // middle column of the top row: that pixel and the spare column are
    // left as they were.
    var holed = [_]u32{0x1234_5678} ** 8;
    const one = [_]u32{0};
    const hole = holeOf(.{ .pixels = &one, .w = 1, .h = 1, .x = 1, .y = 0 }, 255);
    fillSolid(.{ .pixels = &holed, .stride = 4, .w = 3, .h = 2 }, .{ .r = 1, .g = 2, .b = 3 }, hole);
    try testing.expectEqualSlices(u32, &.{ 0xFF010203, 0x1234_5678, 0xFF010203, 0x1234_5678 }, holed[0..4]);
    try testing.expectEqualSlices(u32, &.{ 0xFF010203, 0xFF010203, 0xFF010203, 0x1234_5678 }, holed[4..8]);
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
    fillGlass(frameOf(&buf, 2, 2), .{ .pixels = &desk, .w = 3, .h = 2, .x = 2, .y = 0 }, &lut, null);
    try testing.expectEqual(pack(lut.at(0x808080)), buf[0]);
    try testing.expectEqual(pack(lut.at(0x808080)), buf[1]);
    try testing.expectEqual(pack(lut.at(0xFFFFFF)), buf[2]);
    try testing.expectEqual(pack(lut.at(0xFFFFFF)), buf[3]);
    // Different desk pixels make different strip pixels: the desk shows through.
    try testing.expect(buf[0] != buf[2]);

    // Hanging off both edges: a 5-wide face from desk column -1 takes the
    // left edge, the row, then the right edge (T2461: only those clamp).
    var wide: [5]u32 = undefined;
    fillGlass(frameOf(&wide, 5, 1), .{ .pixels = &desk, .w = 3, .h = 2, .x = -1, .y = 1 }, &lut, null);
    const row1 = [_]u32{ 0x202020, 0x202020, 0x606060, 0xFFFFFF, 0xFFFFFF };
    for (wide, row1) |p, d| try testing.expectEqual(pack(lut.at(d)), p);
    // Wholly off either side: every column takes that edge.
    fillGlass(frameOf(&wide, 5, 1), .{ .pixels = &desk, .w = 3, .h = 2, .x = -9, .y = 0 }, &lut, null);
    for (wide) |p| try testing.expectEqual(pack(lut.at(0x000000)), p);
    fillGlass(frameOf(&wide, 5, 1), .{ .pixels = &desk, .w = 3, .h = 2, .x = 7, .y = 0 }, &lut, null);
    for (wide) |p| try testing.expectEqual(pack(lut.at(0x808080)), p);

    // Around a hole the band is painted on either side and not under it.
    var holed = [_]u32{7} ** 5;
    const one = [_]u32{0} ** 2;
    fillGlass(frameOf(&holed, 5, 1), .{ .pixels = &desk, .w = 3, .h = 2, .x = -1, .y = 1 }, &lut, holeOf(.{ .pixels = &one, .w = 2, .h = 1, .x = 1, .y = 0 }, 255));
    try testing.expectEqual(pack(lut.at(0x202020)), holed[0]);
    try testing.expectEqual(@as(u32, 7), holed[1]);
    try testing.expectEqual(@as(u32, 7), holed[2]);
    try testing.expectEqual(pack(lut.at(0xFFFFFF)), holed[3]);
    try testing.expectEqual(pack(lut.at(0xFFFFFF)), holed[4]);
}
