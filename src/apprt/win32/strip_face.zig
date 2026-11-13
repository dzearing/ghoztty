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

/// Cut the face to `rects` in its own pixels (T2942): every pixel outside
/// them becomes 0 - transparent, and premultiplied-correct, under a
/// per-pixel-alpha UpdateLayeredWindow - and every pixel inside is left as
/// `finish` made it. This replaces a `SetWindowRgn` on the face's popup on
/// every stepped tick, a window-manager transaction that ran 1-4.5 ms on a
/// 4K fold's heaviest ticks. `rects` is a region's rectangles as
/// `GetRegionData` returns them: y-x banded, so a band is a run of rects
/// sharing one top and bottom, bands top to bottom and rects left to right.
/// Rects past the face are clipped to it. Only the cut-away pixels are
/// written: a rounded card loses its corners and nothing else. `R` is any
/// rect with i32 `left`/`top`/`right`/`bottom` (a win32 RECT read straight
/// out of the region data, or a `PxRect`).
/// Returns how many pixels it cut, which costs nothing extra: it is the sum
/// of what it cleared.
pub fn maskOutside(f: Frame, comptime R: type, rects: []const R) usize {
    const clampTo = struct {
        fn c(v: i32, hi: usize) usize {
            return @intCast(std.math.clamp(v, 0, @as(i32, @intCast(hi))));
        }
    }.c;
    const clear = struct {
        fn c(px: []u32) usize {
            @memset(px, 0);
            return px.len;
        }
    }.c;
    var cut: usize = 0;
    var y: usize = 0;
    var i: usize = 0;
    while (i < rects.len) {
        const top = rects[i].top;
        const bottom = rects[i].bottom;
        var j = i;
        while (j < rects.len and rects[j].top == top and rects[j].bottom == bottom) j += 1;
        const band = rects[i..j];
        i = j;
        const b0 = clampTo(top, f.h);
        const b1 = clampTo(bottom, f.h);
        while (y < b0) : (y += 1) cut += clear(f.row(y));
        while (y < b1) : (y += 1) {
            const row = f.row(y);
            var x: usize = 0;
            for (band) |r| {
                const x0 = clampTo(r.left, f.w);
                const x1 = clampTo(r.right, f.w);
                if (x0 > x) cut += clear(row[x..x0]);
                x = @max(x, x1);
            }
            if (x < f.w) cut += clear(row[x..]);
        }
    }
    while (y < f.h) : (y += 1) cut += clear(f.row(y));
    return cut;
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

test "maskOutside: a rounded card keeps its body and loses only its corners (T2942)" {
    const o: u32 = 0xFF11_2233;
    // A 4x4 face (stride 5: the DIB is wider than the frame) cut to a
    // GetRegionData-shaped rounded rect: row 0 is [1,3), rows 1-2 whole,
    // row 3 is [1,3).
    var buf = [_]u32{o} ** 20;
    const f: Frame = .{ .pixels = &buf, .stride = 5, .w = 4, .h = 4 };
    try testing.expectEqual(@as(usize, 4), maskOutside(f, PxRect, &.{
        .{ .left = 1, .top = 0, .right = 3, .bottom = 1 },
        .{ .left = 0, .top = 1, .right = 4, .bottom = 3 },
        .{ .left = 1, .top = 3, .right = 3, .bottom = 4 },
    }));
    const want = [4][4]u32{
        .{ 0, o, o, 0 },
        .{ o, o, o, o },
        .{ o, o, o, o },
        .{ 0, o, o, 0 },
    };
    for (0..4) |y| for (0..4) |x| try testing.expectEqual(want[y][x], buf[y * 5 + x]);
    // The column past the frame (the DIB's slack) is never touched.
    for (0..4) |y| try testing.expectEqual(o, buf[y * 5 + 4]);
}

test "maskOutside: rows outside every band, gaps inside one, and rects past the face (T2942)" {
    const o: u32 = 0xFFAB_CDEF;
    var buf = [_]u32{o} ** 24; // 6x4
    const f = frameOf(&buf, 6, 4);
    // Row 0 is in no band; rows 1-2 are one band of two rects with a gap
    // at [2,4) and the second running past the right edge; row 3 is past
    // the last band. A rect above the face is clipped away entirely.
    // 6 + 2 + 2 + 6 cut.
    try testing.expectEqual(@as(usize, 16), maskOutside(f, PxRect, &.{
        .{ .left = 0, .top = -5, .right = 6, .bottom = -1 },
        .{ .left = -3, .top = 1, .right = 2, .bottom = 3 },
        .{ .left = 4, .top = 1, .right = 99, .bottom = 3 },
    }));
    for (0..6) |x| try testing.expectEqual(@as(u32, 0), buf[x]);
    for (1..3) |y| {
        const row = buf[y * 6 ..][0..6];
        try testing.expectEqualSlices(u32, &.{ o, o, 0, 0, o, o }, row);
    }
    for (0..6) |x| try testing.expectEqual(@as(u32, 0), buf[18 + x]);
}

test "maskOutside: no rects is an empty region, which cuts everything (T2942)" {
    var buf = [_]u32{0xFFFF_FFFF} ** 6;
    try testing.expectEqual(@as(usize, 6), maskOutside(frameOf(&buf, 3, 2), PxRect, &.{}));
    for (buf) |p| try testing.expectEqual(@as(u32, 0), p);
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

/// A face visual's clip box (T2777): the card region's box `box` cut to the
/// `w` x `h` face, and whether it was the whole card - nothing cut away -
/// so the card's rounded corners belong on it. A cut edge is a straight
/// line through the card, where a corner radius would round off the face.
pub fn clipBox(box: PxRect, w: i32, h: i32) struct { box: PxRect, whole: bool } {
    const cut: PxRect = .{
        .left = std.math.clamp(box.left, 0, w),
        .top = std.math.clamp(box.top, 0, h),
        .right = std.math.clamp(box.right, 0, w),
        .bottom = std.math.clamp(box.bottom, 0, h),
    };
    if (cut.right <= cut.left or cut.bottom <= cut.top) return .{ .box = .{}, .whole = false };
    return .{ .box = cut, .whole = std.meta.eql(cut, box) };
}

test "clipBox: a card inside the face keeps its corners; a cut one does not; an empty one clips to nothing (T2777)" {
    const in = clipBox(.{ .left = 2, .top = 0, .right = 90, .bottom = 50 }, 100, 50);
    try testing.expect(in.whole);
    try testing.expectEqual(PxRect{ .left = 2, .top = 0, .right = 90, .bottom = 50 }, in.box);
    // A fold's card running past the face's right edge: cut, straight.
    const cut = clipBox(.{ .left = -4, .top = 0, .right = 140, .bottom = 50 }, 100, 50);
    try testing.expect(!cut.whole);
    try testing.expectEqual(PxRect{ .left = 0, .top = 0, .right = 100, .bottom = 50 }, cut.box);
    const none = clipBox(.{ .left = 120, .top = 0, .right = 140, .bottom = 50 }, 100, 50);
    try testing.expect(!none.whole);
    try testing.expectEqual(PxRect{}, none.box);
}

/// A strength line along a declared face's glide: its value at the start
/// and at the landing, unclamped.
pub const Line = struct { from: f32, to: f32 };

/// The carried content's strength along a fold declared to the compositor
/// (T2778): `tweenCollapse` of the card's extent is linear in it, and the
/// extent is linear in the glide's follower, so the strength is a straight
/// line in the same 0..1 of the way - from the card drawn at `d0` to it
/// landed at `d1`. Both ends are UNCLAMPED: a strip narrower than `strip`
/// runs a fold's line past 0 before the card lands, and an unfold's (T2779)
/// starts below 0 and rises into 0..1 part of the way; the compositor holds
/// it outside (`FacePose.fadeSpan`). Null when the line starts above 1 (a
/// card drawn wider than its pane), which frames handle.
pub fn fadeLine(d0: f64, d1: f64, strip: f64, full: f64, min_span: f64) ?Line {
    const span = @max(full - strip, min_span);
    if (span <= 0) return null;
    const from = 1 - (full - d0) / span;
    if (from > 1 + 1e-6) return null;
    return .{ .from = @floatCast(@min(from, 1)), .to = @floatCast(1 - (full - d1) / span) };
}

test "fadeLine: the same strength tweenCollapse gives, as a line (T2778)" {
    // A 400 px pane folding from its whole width into a 46 px strip, which
    // lands at 36 px: the line ends past 0.
    const l = fadeLine(400, 36, 46, 400, 120).?;
    try testing.expectEqual(@as(f32, 1), l.from);
    try testing.expect(l.to < 0);
    for ([_]f64{ 0, 0.3, 0.7, 0.95 }) |f| {
        const d = 400 + (36 - 400) * f;
        const want: f32 = @floatCast(1 - tweenCollapse(d, 46, 400, 120));
        const got = std.math.clamp(l.from + (l.to - l.from) * @as(f32, @floatCast(f)), 0, 1);
        try testing.expectApproxEqAbs(want, got, 1e-5);
    }
    // A card drawn wider than the pane it carries: frames, not a line.
    try testing.expectEqual(@as(@TypeOf(fadeLine(0, 0, 0, 0, 0)), null), fadeLine(500, 36, 46, 400, 120));
}

test "fadeLine: an unfold's strength rises from below 0, as tweenCollapse gives it (T2779)" {
    // A 400 px pane opening out of a 36 px strip to its whole width.
    const l = fadeLine(36, 400, 46, 400, 120).?;
    try testing.expect(l.from < 0);
    try testing.expectEqual(@as(f32, 1), l.to);
    for ([_]f64{ 0, 0.01, 0.3, 0.7, 1 }) |f| {
        const d = 36 + (400 - 36) * f;
        const want: f32 = @floatCast(1 - tweenCollapse(d, 46, 400, 120));
        const got = std.math.clamp(l.from + (l.to - l.from) * @as(f32, @floatCast(f)), 0, 1);
        try testing.expectApproxEqAbs(want, got, 1e-5);
    }
}

/// A live strip card's face strength along a glide declared to the
/// compositor (T2822): the face is blended over its live pane at Mac's
/// last-120 collapse (`collapseOf`), which is linear in the card's extent
/// along the stack, so it too is a straight line in the follower's 0..1 -
/// from the card drawn at `d0` to it landed at `d1`, both ends UNCLAMPED (a
/// fold's starts below 0 while the card is still wider than the fade zone
/// and is held at 0 until it rises in; it ends past 1 once the card is
/// narrower than a strip). The extent is the card's along the stack, which
/// is `collapseOf`'s shorter side for every card the fade reaches.
pub fn liveLine(d0: f64, d1: f64, strip: f64, span: f64) ?Line {
    if (span <= 0) return null;
    return .{ .from = @floatCast(1 - (d0 - strip) / span), .to = @floatCast(1 - (d1 - strip) / span) };
}

test "liveLine: the strength collapseOf gives, as a line (T2822)" {
    // A 400 px card folding into a strip landing at 36 px, zone 46 + 120.
    const l = liveLine(400, 36, 46, 120).?;
    try testing.expect(l.from < 0);
    try testing.expect(l.to > 1);
    for ([_]f64{ 0, 0.3, 0.6, 0.7, 0.8, 0.95, 1 }) |f| {
        const d = 400 + (36 - 400) * f;
        const want: f32 = @floatCast(pane_stack_slide.collapse(d, 46, 120));
        const got = std.math.clamp(l.from + (l.to - l.from) * @as(f32, @floatCast(f)), 0, 1);
        try testing.expectApproxEqAbs(want, got, 1e-5);
    }
    try testing.expectEqual(@as(@TypeOf(liveLine(0, 0, 0, 0)), null), liveLine(400, 36, 46, 0));
}

/// Where the strip name's picture goes for a face showing `vis` (client
/// pixels, fractional), the picture painted for a face `pic_w` x `pic_h`
/// (T2778): `pane_stack_strip.labelOrigin` centres the name across a tall
/// strip and down a short one, so the picture rides that centre as the face
/// narrows, and keeps to the face's top (tall) or left (short) edge.
pub fn nameOffset(axis: Direction, left: f32, top: f32, right: f32, bottom: f32, pic_w: f32, pic_h: f32) struct { x: f32, y: f32 } {
    return switch (axis) {
        .horizontal => .{ .x = left + ((right - left) - pic_w) / 2, .y = top },
        .vertical => .{ .x = left, .y = top + ((bottom - top) - pic_h) / 2 },
    };
}

test "nameOffset: the name rides the face's centre across its narrowing side (T2778)" {
    const a = nameOffset(.horizontal, 100, 0, 500, 600, 400, 600);
    try testing.expectEqual(@as(f32, 100), a.x);
    const b = nameOffset(.horizontal, 20, 0, 56, 600, 400, 600);
    // The picture's centre on the 36 px face's centre.
    try testing.expectEqual(@as(f32, 38), b.x + 200);
    try testing.expectEqual(@as(f32, 0), b.y);
    const c = nameOffset(.vertical, 10, 0, 410, 40, 400, 300);
    try testing.expectEqual(@as(f32, 10), c.x);
    try testing.expectEqual(@as(f32, 20), c.y + 150);
}

/// A name drawn white on black (GDI, ClearType or not) made into `ink` at
/// the coverage it drew, premultiplied (T2778): the name's own picture,
/// clear wherever no text is, laid over the band by the compositor.
pub fn inkFromCoverage(px: []u32, ink: Rgb) void {
    for (px) |*p| {
        const v = p.*;
        const cov: u32 = @max(@max((v >> 16) & 0xFF, (v >> 8) & 0xFF), v & 0xFF);
        if (cov == 0) {
            p.* = 0;
            continue;
        }
        const r = (@as(u32, ink.r) * cov + 127) / 255;
        const g = (@as(u32, ink.g) * cov + 127) / 255;
        const b = (@as(u32, ink.b) * cov + 127) / 255;
        p.* = (cov << 24) | (r << 16) | (g << 8) | b;
    }
}

test "inkFromCoverage: text coverage becomes premultiplied ink; no text is clear (T2778)" {
    var px = [_]u32{ 0x000000, 0xFFFFFF, 0x408020 };
    inkFromCoverage(&px, .{ .r = 0xFF, .g = 0x80, .b = 0x00 });
    try testing.expectEqual(@as(u32, 0), px[0]);
    try testing.expectEqual(@as(u32, 0xFFFF8000), px[1]);
    // Coverage 0x80: half of the ink, alpha 0x80.
    try testing.expectEqual(@as(u32, 0x80804000), px[2]);
}

const comp_tree = @import("../../renderer/comp_tree.zig");
const comp_overlay = @import("../../renderer/comp_overlay.zig");

/// A strip face's glide handed to the compositor whole (T2778; an unfold
/// since T2779): when, from what, to what, on which follower, and which
/// carried frame it shows - so a retarget, or an opening card's frame landing,
/// starts from where the compositor has the face rather than from where the
/// window's last frame did.
pub const FaceDecl = struct {
    t0: std.time.Instant,
    from: comp_tree.FacePose,
    to: comp_tree.FacePose,
    dist: f32,
    tau_s: f64,
    /// The carried frame the face shows (null: the band and name alone, an
    /// opening card whose frame has not landed yet).
    content: ?ContentId = null,
    /// A live strip card's face (T2822): `opacity` is the whole face's
    /// strength over its live pane (`liveLine`), not a carried frame's.
    live: bool = false,

    /// Which frame a face carries: a frame that lands, or is replaced by one
    /// asked at another size, is a new declaration.
    pub const ContentId = struct {
        ptr: usize,
        w: i32,
        h: i32,

        pub fn of(c: ?Content) ?ContentId {
            const v = c orelse return null;
            return .{ .ptr = @intFromPtr(v.pixels.ptr), .w = v.w, .h = v.h };
        }

        pub fn eql(a: ?ContentId, b: ?ContentId) bool {
            if (a == null or b == null) return a == null and b == null;
            return a.?.ptr == b.?.ptr and a.?.w == b.?.w and a.?.h == b.?.h;
        }
    };

    /// Where the compositor has the face `now`: the exact path its cubics
    /// stand in for, the strength held inside 0..1.
    pub fn reached(self: FaceDecl, now: std.time.Instant) comp_tree.FacePose {
        const t_s = @as(f64, @floatFromInt(now.since(self.t0))) / std.time.ns_per_s;
        return self.at(t_s);
    }

    fn at(self: FaceDecl, t_s: f64) comp_tree.FacePose {
        const f = comp_overlay.followerAt(self.dist, self.tau_s, pane_stack_slide.snap_px, t_s);
        return comp_tree.FacePose.lerp(self.from, self.to, @floatCast(f));
    }

    /// When the strength comes inside 0..1 (`enter_s`, null from the start)
    /// and when it leaves it to be held (`leave_s`, null: it runs to the
    /// end), in seconds after `t0` (T2779: an unfold's rises in part-way).
    pub fn fadeTimes(self: FaceDecl) struct { enter_s: ?f64, leave_s: ?f64 } {
        const s = comp_tree.FacePose.fadeSpan(self.from, self.to);
        const T = struct {
            fn of(d: FaceDecl, f: f32) f64 {
                return comp_overlay.followerTimeOf(d.dist, d.tau_s, pane_stack_slide.snap_px, f);
            }
        };
        return .{
            .enter_s = if (s.enter > 0) T.of(self, s.enter) else null,
            .leave_s = if (s.leave < 1) T.of(self, s.leave) else null,
        };
    }
};

test "FaceDecl: reached follows the follower, the fade held from its knee (T2778)" {
    const t0 = std.time.Instant.now() catch return error.SkipZigTest;
    const d: FaceDecl = .{
        .t0 = t0,
        .from = .{ .clip = .{ .left = 100, .right = 500, .bottom = 600 }, .content_x = 100, .opacity = 1 },
        .to = .{ .clip = .{ .left = 20, .right = 56, .bottom = 600 }, .content_x = 20, .opacity = -0.25 },
        .dist = 444,
        .tau_s = 0.045,
    };
    try testing.expectEqual(d.from, d.at(0));
    const times = d.fadeTimes();
    try testing.expectEqual(@as(?f64, null), times.enter_s);
    const k = times.leave_s.?;
    // At the knee the strength has just run out, and stays out; the card
    // is still on its way.
    try testing.expectApproxEqAbs(@as(f32, 0), d.at(k).opacity, 1e-4);
    try testing.expectEqual(@as(f32, 0), d.at(k + 0.05).opacity);
    try testing.expect(d.at(k).clip.right > 56);
    try testing.expectApproxEqAbs(@as(f32, 56), d.at(10).clip.right, 1e-4);
}

test "FaceDecl: an unfold's strength is held at 0 until it rises in (T2779)" {
    const t0 = std.time.Instant.now() catch return error.SkipZigTest;
    const d: FaceDecl = .{
        .t0 = t0,
        .from = .{ .clip = .{ .left = 20, .right = 56, .bottom = 600 }, .content_x = 20, .opacity = -0.03 },
        .to = .{ .clip = .{ .left = 20, .right = 420, .bottom = 600 }, .content_x = 20, .opacity = 1 },
        .dist = 364,
        .tau_s = 0.045,
    };
    const times = d.fadeTimes();
    try testing.expectEqual(@as(?f64, null), times.leave_s);
    const e = times.enter_s.?;
    try testing.expect(e > 0);
    try testing.expectEqual(@as(f32, 0), d.at(e / 2).opacity);
    try testing.expectApproxEqAbs(@as(f32, 0), d.at(e).opacity, 1e-4);
    try testing.expect(d.at(e + 0.05).opacity > 0);
    try testing.expectApproxEqAbs(@as(f32, 1), d.at(10).opacity, 1e-4);
}

test "FaceDecl.ContentId: a landed or replaced frame is a new one (T2779)" {
    var a = [_]u32{ 1, 2, 3, 4 };
    var b = [_]u32{ 1, 2, 3, 4 };
    const ca: Content = .{ .pixels = &a, .w = 2, .h = 2, .x = 0, .y = 0 };
    const cb: Content = .{ .pixels = &b, .w = 2, .h = 2, .x = 0, .y = 0 };
    const Id = FaceDecl.ContentId;
    try testing.expect(Id.eql(null, null));
    try testing.expect(!Id.eql(null, Id.of(ca)));
    try testing.expect(Id.eql(Id.of(ca), Id.of(ca)));
    try testing.expect(!Id.eql(Id.of(ca), Id.of(cb)));
}
