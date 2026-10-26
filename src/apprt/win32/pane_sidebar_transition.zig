//! The pane sidebar's list transitions (T1880), pure so they are testable:
//! switching between this window and all windows slides like a navigation
//! push, and folding a group reveals or covers its rows from the top down
//! while the rows below slide to their place. Both are Mac's
//! (`PaneSidebarOutline.scopeAnimation` / `foldAnimation` / `FoldReveal` in
//! PaneSidebarView.swift).
//!
//! SwiftUI animates two live view trees; GDI has one frame. So the column
//! keeps a picture of the frame it showed before the change (`old`), paints
//! the frame after it live (`new`), paints its bare material once more
//! (`bg`: the column with no header and no rows), and composes each frame
//! from the three here. A list moves as its difference from the material
//! (`src - bg`), laid back over the material where it lands, so the glass
//! and the card's edges hold still while the rows travel - the material is
//! what Mac's list slides OVER, not part of the list.
//!
//! Pixels are `0x00RRGGBB` words, top-down rows of `w`.

const std = @import("std");

/// This window <-> all windows (Mac 0.3 s: the whole list changes).
pub const scope_ms: u64 = 300;
/// A group folding open or closed (Mac 0.22 s).
pub const fold_ms: u64 = 220;
/// How far a list slides as it leaves or arrives, in DIP (Mac 48 pt:
/// enough to read as a direction, not a full page turn).
pub const scope_slide_dip: f32 = 48;
/// The frame cadence while a transition runs: a 48-DIP slide over 300 ms
/// wants every display frame, unlike the shimmer's slow band.
pub const frame_ms: u32 = 16;

/// Mac's curve for both: `.timingCurve(0.2, 0.8, 0.2, 1)`, a strong ease-out.
const curve = [4]f64{ 0.2, 0.8, 0.2, 1 };

/// The eased progress `elapsed_ms` into a transition of `duration_ms`:
/// 0 at the start, 1 from the end on.
pub fn progress(elapsed_ms: u64, duration_ms: u64) f64 {
    if (duration_ms == 0 or elapsed_ms >= duration_ms) return 1;
    const t = @as(f64, @floatFromInt(elapsed_ms)) / @as(f64, @floatFromInt(duration_ms));
    return ease(t);
}

/// The cubic bezier (0,0) (x1,y1) (x2,y2) (1,1) read as y at x = `t`, the
/// way CSS and Core Animation read a timing curve.
pub fn ease(t: f64) f64 {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    // x(s) is monotone on [0, 1] for x1, x2 in [0, 1]: bisect for s.
    var lo: f64 = 0;
    var hi: f64 = 1;
    var s: f64 = t;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        s = (lo + hi) / 2;
        if (bez(s, curve[0], curve[2]) < t) lo = s else hi = s;
    }
    return bez(s, curve[1], curve[3]);
}

fn bez(s: f64, p1: f64, p2: f64) f64 {
    const u = 1 - s;
    return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s;
}

/// The band of the column a transition repaints; everything outside it is
/// the new frame as painted.
pub const Region = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    fn clampTo(self: Region, w: i32, h: i32) Region {
        return .{
            .left = std.math.clamp(self.left, 0, w),
            .top = std.math.clamp(self.top, 0, h),
            .right = std.math.clamp(self.right, 0, w),
            .bottom = std.math.clamp(self.bottom, 0, h),
        };
    }
};

/// Where the outgoing and the incoming list sit at eased progress `p` of a
/// scope switch, as horizontal offsets in pixels and opacities. This
/// window's list lives on the LEFT and all windows on the RIGHT (Mac: each
/// list's transition is tied to which list it IS), so going to all windows
/// the old list leaves to the left and the new one arrives from the right,
/// and coming back is the mirror.
pub const Slide = struct {
    old_dx: i32,
    old_alpha: f64,
    new_dx: i32,
    new_alpha: f64,
};

pub fn slideAt(p: f64, to_all: bool, slide_px: i32) Slide {
    const s: f64 = @floatFromInt(slide_px);
    // The list that is all windows sits at +slide when away; this window's
    // at -slide.
    const old_side: f64 = if (to_all) -1 else 1;
    return .{
        .old_dx = @intFromFloat(@round(old_side * s * p)),
        .old_alpha = 1 - p,
        .new_dx = @intFromFloat(@round(-old_side * s * (1 - p))),
        .new_alpha = p,
    };
}

/// One frame of the scope switch into `out`: outside `region` the new frame;
/// inside it the material with both lists laid over it at their offsets and
/// opacities. A list's pixels that slide past the region's edge are cut
/// there, as Mac's clipped list is.
pub fn composeSlide(out: []u32, bg: []const u32, old: []const u32, new: []const u32, w: i32, h: i32, region: Region, p: f64, to_all: bool, slide_px: i32) void {
    @memcpy(out, new);
    const r = region.clampTo(w, h);
    const sl = slideAt(p, to_all, slide_px);
    const uw: usize = @intCast(w);
    var y = r.top;
    while (y < r.bottom) : (y += 1) {
        const row: usize = @as(usize, @intCast(y)) * uw;
        var x = r.left;
        while (x < r.right) : (x += 1) {
            const base = bg[row + @as(usize, @intCast(x))];
            var acc = channels(base);
            const ox = x - sl.old_dx;
            if (ox >= r.left and ox < r.right) {
                const i = row + @as(usize, @intCast(ox));
                addDelta(&acc, old[i], bg[i], sl.old_alpha);
            }
            const nx = x - sl.new_dx;
            if (nx >= r.left and nx < r.right) {
                const i = row + @as(usize, @intCast(nx));
                addDelta(&acc, new[i], bg[i], sl.new_alpha);
            }
            out[row + @as(usize, @intCast(x))] = pack(acc);
        }
    }
}

/// One frame of a fold into `out`. The group's rows begin at `y0` (its
/// header's bottom) and are `group_h` tall when open. `tall` is the frame
/// that shows them, `short` the one that does not: opening, those are the
/// new and the old frame; closing, the old and the new. At eased progress
/// `p` the open band is `group_h * p` tall opening, `group_h * (1 - p)`
/// closing: the group's rows stay where they are, masked to that band from
/// the top down, and everything below it is the short frame slid down by the
/// band (Mac `FoldReveal`: a top-anchored mask, never a `.move`, which slid
/// the rows up through the header). Only `region` (the scrolled viewport)
/// moves; above `y0` and outside the region is the new frame.
pub fn composeFold(out: []u32, bg: []const u32, tall: []const u32, short: []const u32, new: []const u32, w: i32, h: i32, region: Region, y0: i32, group_h: i32, opening: bool, p: f64) void {
    @memcpy(out, new);
    const r = region.clampTo(w, h);
    const frac = if (opening) p else 1 - p;
    const band: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(group_h)) * frac));
    const uw: usize = @intCast(w);
    var y = @max(r.top, y0);
    while (y < r.bottom) : (y += 1) {
        const row: usize = @as(usize, @intCast(y)) * uw;
        // Inside the band: the group's own rows, in place.
        if (y < y0 + band) {
            copySpan(out, tall, row, r);
            continue;
        }
        // Below it: the short frame's row that now lands here.
        const sy = y - band;
        if (sy < r.top or sy >= r.bottom) {
            fillSpan(out, bg, row, r);
            continue;
        }
        const srow: usize = @as(usize, @intCast(sy)) * uw;
        var x = r.left;
        while (x < r.right) : (x += 1) {
            const xi: usize = @intCast(x);
            var acc = channels(bg[row + xi]);
            addDelta(&acc, short[srow + xi], bg[srow + xi], 1);
            out[row + xi] = pack(acc);
        }
    }
}

fn copySpan(out: []u32, src: []const u32, row: usize, r: Region) void {
    const a = row + @as(usize, @intCast(r.left));
    const b = row + @as(usize, @intCast(r.right));
    @memcpy(out[a..b], src[a..b]);
}

const fillSpan = copySpan;

const Acc = [3]f64;

fn channels(c: u32) Acc {
    return .{ @floatFromInt((c >> 16) & 0xFF), @floatFromInt((c >> 8) & 0xFF), @floatFromInt(c & 0xFF) };
}

fn addDelta(acc: *Acc, src: u32, under: u32, alpha: f64) void {
    if (alpha <= 0 or src == under) return;
    const s = channels(src);
    const u = channels(under);
    inline for (0..3) |k| acc[k] += alpha * (s[k] - u[k]);
}

fn pack(acc: Acc) u32 {
    var c: u32 = 0;
    inline for (0..3) |k| {
        const v: u32 = @intFromFloat(@round(std.math.clamp(acc[k], 0, 255)));
        c = (c << 8) | v;
    }
    return c;
}

test "the curve is Mac's ease-out: pinned ends, fast start, monotone" {
    try std.testing.expectEqual(@as(f64, 0), ease(0));
    try std.testing.expectEqual(@as(f64, 1), ease(1));
    // (0.2, 0.8, 0.2, 1) is past 80% of the way by a third of the time.
    try std.testing.expect(ease(1.0 / 3.0) > 0.8);
    // Symmetric control x's: at x = 0.5 the curve is past 0.9.
    try std.testing.expect(ease(0.5) > 0.9 and ease(0.5) < 1);
    var prev: f64 = -1;
    var i: usize = 0;
    while (i <= 100) : (i += 1) {
        const v = ease(@as(f64, @floatFromInt(i)) / 100);
        try std.testing.expect(v >= prev);
        prev = v;
    }
    try std.testing.expectEqual(@as(f64, 1), progress(300, scope_ms));
    try std.testing.expectEqual(@as(f64, 1), progress(9999, fold_ms));
    try std.testing.expectEqual(@as(f64, 0), progress(0, fold_ms));
}

test "to all windows the old list leaves left and the new arrives from the right; back is the mirror" {
    const go = slideAt(0, true, 48);
    try std.testing.expectEqual(@as(i32, 0), go.old_dx);
    try std.testing.expectEqual(@as(i32, 48), go.new_dx);
    try std.testing.expectEqual(@as(f64, 1), go.old_alpha);
    try std.testing.expectEqual(@as(f64, 0), go.new_alpha);
    const mid = slideAt(0.5, true, 48);
    try std.testing.expectEqual(@as(i32, -24), mid.old_dx);
    try std.testing.expectEqual(@as(i32, 24), mid.new_dx);
    const done = slideAt(1, true, 48);
    try std.testing.expectEqual(@as(i32, -48), done.old_dx);
    try std.testing.expectEqual(@as(i32, 0), done.new_dx);
    try std.testing.expectEqual(@as(f64, 1), done.new_alpha);
    const back = slideAt(0.5, false, 48);
    try std.testing.expectEqual(@as(i32, 24), back.old_dx);
    try std.testing.expectEqual(@as(i32, -24), back.new_dx);
}

const bgc: u32 = 0x00202020;
const ink: u32 = 0x00E0E0E0;

fn frame(comptime w: usize, comptime h: usize, fill: u32) [w * h]u32 {
    return [_]u32{fill} ** (w * h);
}

test "a slide moves the list over a material that holds still" {
    const w = 10;
    const h = 2;
    const bg = frame(w, h, bgc);
    // Old list: a mark at x = 4; new list: a mark at x = 6. Row 0 is the
    // header (outside the region), row 1 the list.
    var old = bg;
    old[w + 4] = ink;
    var new = bg;
    new[0] = 0x00FF0000; // header pixel, new frame only
    new[w + 6] = ink;
    var out = frame(w, h, 0);
    const region: Region = .{ .left = 0, .top = 1, .right = w, .bottom = h };

    // Start: only the old list, in place - and the header is already new.
    composeSlide(&out, &bg, &old, &new, w, h, region, 0, true, 2);
    try std.testing.expectEqual(@as(u32, 0x00FF0000), out[0]);
    try std.testing.expectEqual(ink, out[w + 4]);
    try std.testing.expectEqual(bgc, out[w + 6]);
    try std.testing.expectEqual(bgc, out[w + 8]);

    // End: only the new list, in place; the old one gone.
    composeSlide(&out, &bg, &old, &new, w, h, region, 1, true, 2);
    try std.testing.expectEqual(ink, out[w + 6]);
    try std.testing.expectEqual(bgc, out[w + 4]);
    try std.testing.expectEqual(bgc, out[w + 2]);

    // Halfway to all windows: the old mark one pixel left, half faded; the
    // new one a pixel right of home, half in - and the material between and
    // around them untouched.
    composeSlide(&out, &bg, &old, &new, w, h, region, 0.5, true, 2);
    const half: u32 = 0x00808080; // 0x20 + 0.5 * (0xE0 - 0x20)
    try std.testing.expectEqual(half, out[w + 3]);
    try std.testing.expectEqual(half, out[w + 7]);
    try std.testing.expectEqual(bgc, out[w + 4]);
    try std.testing.expectEqual(bgc, out[w + 6]);
}

test "a slide never draws a list outside the region" {
    const w = 6;
    const h = 1;
    const bg = frame(w, h, bgc);
    var old = bg;
    old[1] = ink; // inside the region's left edge
    const new = bg;
    var out = frame(w, h, 0);
    // The region starts at x = 1: sliding left by 1 would put the mark at 0.
    composeSlide(&out, &bg, &old, &new, w, h, .{ .left = 1, .top = 0, .right = w, .bottom = h }, 0.5, true, 2);
    try std.testing.expectEqual(bgc, out[0]);
}

test "a fold opening reveals the group from the top down while the rows below slide" {
    const w = 1;
    const h = 8;
    const bg = frame(w, h, bgc);
    // Header at row 1; the group's rows are rows 2..4 (3 tall) open. Closed,
    // the next row (marked 0x55) sits at row 2; open, at row 5.
    var closed = bg;
    closed[1] = 0x00AAAAAA;
    closed[2] = 0x00555555;
    var open = closed;
    open[2] = 0x00010101;
    open[3] = 0x00020202;
    open[4] = 0x00030303;
    open[5] = 0x00555555;
    var out = frame(w, h, 0);
    const region: Region = .{ .left = 0, .top = 1, .right = w, .bottom = h };

    // Start: looks exactly closed.
    composeFold(&out, &bg, &open, &closed, &open, w, h, region, 2, 3, true, 0);
    try std.testing.expectEqualSlices(u32, &closed, &out);
    // End: exactly open.
    composeFold(&out, &bg, &open, &closed, &open, w, h, region, 2, 3, true, 1);
    try std.testing.expectEqualSlices(u32, &open, &out);
    // A third of the way: the group's FIRST row is revealed (top down), the
    // next row has moved down by one.
    composeFold(&out, &bg, &open, &closed, &open, w, h, region, 2, 3, true, 1.0 / 3.0);
    try std.testing.expectEqual(@as(u32, 0x00AAAAAA), out[1]);
    try std.testing.expectEqual(@as(u32, 0x00010101), out[2]);
    try std.testing.expectEqual(@as(u32, 0x00555555), out[3]);
    try std.testing.expectEqual(bgc, out[4]);
}

test "a fold closing covers the group from the bottom up and pulls the rows below after it" {
    const w = 1;
    const h = 8;
    const bg = frame(w, h, bgc);
    var closed = bg;
    closed[2] = 0x00555555;
    var open = bg;
    open[2] = 0x00010101;
    open[3] = 0x00020202;
    open[4] = 0x00030303;
    open[5] = 0x00555555;
    var out = frame(w, h, 0);
    const region: Region = .{ .left = 0, .top = 0, .right = w, .bottom = h };
    composeFold(&out, &bg, &open, &closed, &closed, w, h, region, 2, 3, false, 0);
    try std.testing.expectEqualSlices(u32, &open, &out);
    composeFold(&out, &bg, &open, &closed, &closed, w, h, region, 2, 3, false, 1);
    try std.testing.expectEqualSlices(u32, &closed, &out);
    // Two thirds through: one row of the group left, the next row right
    // under it.
    composeFold(&out, &bg, &open, &closed, &closed, w, h, region, 2, 3, false, 2.0 / 3.0);
    try std.testing.expectEqual(@as(u32, 0x00010101), out[2]);
    try std.testing.expectEqual(@as(u32, 0x00555555), out[3]);
}

test "rows that would come from outside the viewport are bare material" {
    const w = 1;
    const h = 4;
    const bg = frame(w, h, bgc);
    var closed = bg;
    closed[3] = ink;
    const open = bg;
    var out = frame(w, h, 0);
    // Viewport rows 1..3 (row 3 is below it). Halfway open the band is one
    // row (row 1, from the tall frame) and row 2 shows the short frame's row
    // 1; the short frame's row 3 - the ink, outside the viewport - never
    // slides into view, and row 3 itself is the new frame.
    composeFold(&out, &bg, &open, &closed, &open, w, h, .{ .left = 0, .top = 1, .right = w, .bottom = 3 }, 1, 2, true, 0.5);
    try std.testing.expectEqual(bgc, out[2]);
    try std.testing.expectEqual(bgc, out[3]);
}
