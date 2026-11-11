//! A strip's name as a cached coverage picture (T2871).
//!
//! The names on a stack's strips are the same text, face and ink tick after
//! tick of a glide; only where they sit changes. Putting them out with GDI
//! text every tick cost 0.05 ms on average and 2-6 ms about once in 170
//! paints, which is a late frame. So each name is drawn ONCE, white on
//! black, into a picture whose pixels are its coverage (ClearType's per
//! channel, as GDI drew it), and every paint after that lays the picture
//! into the desk's own pixels with `blend` - no GDI text on the glide path.
//!
//! Pure: the GDI half (drawing a missing picture) is `Window.stripLabelPic`.

const std = @import("std");
const color_math = @import("color_math.zig");

pub const Rgb = color_math.Rgb;

/// A rectangle in a buffer's own pixels, right and bottom exclusive.
pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

/// How many names are kept. A window rarely shows more than a handful of
/// strips; a cut that changes as a strip narrows is a new name, so this
/// holds a few cuts of each too.
pub const capacity = 16;

/// The longest name kept, in UTF-16 units (a strip's cut name is far less).
pub const max_text = 256;

/// The picture a name is drawn into, and where `TextOutW` puts its origin
/// in it. GDI's cell for a font turned 270 degrees lies to the LEFT of its
/// origin (`pane_stack_strip.labelOrigin`), so a rotated name's origin sits
/// a text height in from the left. `margin` on every side catches what a
/// glyph or ClearType's fringe draws past the cell.
pub const Box = struct { w: i32, h: i32, origin_x: i32, origin_y: i32 };

pub fn box(rotated: bool, text_len: i32, text_h: i32) Box {
    const m = margin(text_h);
    return if (rotated) .{
        .w = text_h + 2 * m,
        .h = text_len + 2 * m,
        .origin_x = m + text_h,
        .origin_y = m,
    } else .{
        .w = text_len + 2 * m,
        .h = text_h + 2 * m,
        .origin_x = m,
        .origin_y = m,
    };
}

fn margin(text_h: i32) i32 {
    return @max(2, @divTrunc(text_h, 4));
}

test "box: a level name's cell starts at its origin; a turned one lies left of it" {
    const level = box(false, 100, 16);
    try std.testing.expectEqual(@as(i32, 108), level.w);
    try std.testing.expectEqual(@as(i32, 24), level.h);
    try std.testing.expectEqual(@as(i32, 4), level.origin_x);
    try std.testing.expectEqual(@as(i32, 4), level.origin_y);
    const turned = box(true, 100, 16);
    try std.testing.expectEqual(@as(i32, 24), turned.w);
    try std.testing.expectEqual(@as(i32, 108), turned.h);
    // The cell spans [origin_x - 16, origin_x): inside, with the margin left.
    try std.testing.expectEqual(@as(i32, 20), turned.origin_x);
    try std.testing.expectEqual(@as(i32, 4), turned.origin_y);
    // A tiny face still gets a margin.
    try std.testing.expectEqual(@as(i32, 2), box(false, 5, 4).origin_x);
}

/// One drawn name: its coverage, `box.w` x `box.h`, top-down, alpha zero.
pub const Pic = struct {
    text: [max_text]u16 = undefined,
    len: usize = 0,
    height: i32 = 0,
    rotated: bool = false,
    box: Box = .{ .w = 0, .h = 0, .origin_x = 0, .origin_y = 0 },
    px: []u32 = &.{},
    used: u64 = 0,

    fn matches(self: *const Pic, text: []const u16, height: i32, rotated: bool) bool {
        return self.px.len > 0 and self.height == height and self.rotated == rotated and
            std.mem.eql(u16, self.text[0..self.len], text);
    }
};

pub const Cache = struct {
    pics: [capacity]Pic = [_]Pic{.{}} ** capacity,
    clock: u64 = 0,

    pub fn deinit(self: *Cache, alloc: std.mem.Allocator) void {
        for (&self.pics) |*p| {
            if (p.px.len > 0) alloc.free(p.px);
            p.* = .{};
        }
    }

    /// The picture already drawn for this name, marked as just used.
    pub fn find(self: *Cache, text: []const u16, height: i32, rotated: bool) ?*Pic {
        for (&self.pics) |*p| {
            if (p.matches(text, height, rotated)) {
                self.clock += 1;
                p.used = self.clock;
                return p;
            }
        }
        return null;
    }

    /// A slot for a new picture of `b`'s size: an empty one, else the one
    /// used longest ago. Its pixels are zeroed for drawing into; null when
    /// the name is too long to key or the pixels cannot be had.
    pub fn claim(
        self: *Cache,
        alloc: std.mem.Allocator,
        text: []const u16,
        height: i32,
        rotated: bool,
        b: Box,
    ) ?*Pic {
        if (text.len > max_text or b.w <= 0 or b.h <= 0) return null;
        var pick: *Pic = &self.pics[0];
        for (&self.pics) |*p| {
            if (p.px.len == 0) {
                pick = p;
                break;
            }
            if (p.used < pick.used) pick = p;
        }
        const n = @as(usize, @intCast(b.w)) * @as(usize, @intCast(b.h));
        if (pick.px.len != n) {
            if (pick.px.len > 0) alloc.free(pick.px);
            pick.px = &.{};
            pick.px = alloc.alloc(u32, n) catch return null;
        }
        @memset(pick.px, 0);
        @memcpy(pick.text[0..text.len], text);
        pick.len = text.len;
        pick.height = height;
        pick.rotated = rotated;
        pick.box = b;
        self.clock += 1;
        pick.used = self.clock;
        return pick;
    }

    /// Forget a picture whose drawing failed, so it is not laid blank.
    pub fn drop(_: *Cache, alloc: std.mem.Allocator, p: *Pic) void {
        if (p.px.len > 0) alloc.free(p.px);
        p.* = .{};
    }
};

test "Cache: a name is found again; a different cut, size or turn is not" {
    const alloc = std.testing.allocator;
    var c: Cache = .{};
    defer c.deinit(alloc);
    const name = std.unicode.utf8ToUtf16LeStringLiteral("build");
    const b = box(false, 30, 12);
    const p = c.claim(alloc, name, 12, false, b).?;
    p.px[0] = 0xFFFFFF;
    try std.testing.expectEqual(p, c.find(name, 12, false).?);
    try std.testing.expect(c.find(name, 13, false) == null);
    try std.testing.expect(c.find(name, 12, true) == null);
    try std.testing.expect(c.find(std.unicode.utf8ToUtf16LeStringLiteral("buil\u{2026}"), 12, false) == null);
}

test "Cache: when full, the name used longest ago gives up its slot" {
    const alloc = std.testing.allocator;
    var c: Cache = .{};
    defer c.deinit(alloc);
    var bufs: [capacity + 1][1]u16 = undefined;
    for (&bufs, 0..) |*t, i| t[0] = @intCast('a' + i);
    for (bufs[0..capacity]) |*t| _ = c.claim(alloc, t, 12, false, box(false, 10, 12)).?;
    // Touch the first, so the second is now the oldest.
    _ = c.find(&bufs[0], 12, false).?;
    _ = c.claim(alloc, &bufs[capacity], 12, false, box(false, 20, 12)).?;
    try std.testing.expect(c.find(&bufs[0], 12, false) != null);
    try std.testing.expect(c.find(&bufs[1], 12, false) == null);
    try std.testing.expect(c.find(&bufs[capacity], 12, false) != null);
}

test "Cache: a name too long to key is not cached" {
    const alloc = std.testing.allocator;
    var c: Cache = .{};
    defer c.deinit(alloc);
    const long = [_]u16{'x'} ** (max_text + 1);
    try std.testing.expect(c.claim(alloc, &long, 12, false, box(false, 10, 12)) == null);
}

/// Lay `pic` (coverage, `pic_w` wide) into `dst` (`dst_w` x `dst_h`,
/// premultiplied BGRA) with its top-left at (`at_x`, `at_y`), in `ink`, only
/// inside `clip`. Each channel is mixed at its own coverage, as ClearType
/// text is. A pixel keeps its alpha and its channels never exceed it, so a
/// translucent desk's pixels stay valid premultiplied; a pixel whose alpha
/// is zero is an opaque picture's (GDI leaves its alpha byte alone), and is
/// mixed as opaque.
pub fn blend(
    dst: []u32,
    dst_w: i32,
    dst_h: i32,
    pic: []const u32,
    pic_w: i32,
    pic_h: i32,
    at_x: i32,
    at_y: i32,
    clip: []const Rect,
    ink: Rgb,
) void {
    if (pic_w <= 0 or pic_h <= 0 or dst_w <= 0 or dst_h <= 0) return;
    const stride: usize = @intCast(dst_w);
    const pstride: usize = @intCast(pic_w);
    for (clip) |c0| {
        const l = @max(@max(c0.left, at_x), 0);
        const t = @max(@max(c0.top, at_y), 0);
        const r = @min(@min(c0.right, at_x + pic_w), dst_w);
        const b = @min(@min(c0.bottom, at_y + pic_h), dst_h);
        if (r <= l or b <= t) continue;
        var y = t;
        while (y < b) : (y += 1) {
            const drow = dst[@as(usize, @intCast(y)) * stride ..];
            const prow = pic[@as(usize, @intCast(y - at_y)) * pstride ..];
            var x = l;
            while (x < r) : (x += 1) {
                const cov = prow[@intCast(x - at_x)];
                if (cov & 0xFFFFFF == 0) continue;
                const d = &drow[@intCast(x)];
                d.* = mix(d.*, cov, ink);
            }
        }
    }
}

fn mix(d: u32, cov: u32, ink: Rgb) u32 {
    const a: u32 = d >> 24;
    const full: u32 = if (a == 0) 255 else a;
    const inks = [3]u32{ ink.r, ink.g, ink.b };
    var out: u32 = a << 24;
    inline for (.{ 16, 8, 0 }, 0..) |sh, i| {
        const c = (cov >> sh) & 0xFF;
        const under = (d >> sh) & 0xFF;
        const over = (inks[i] * full + 127) / 255;
        const v = (under * (255 - c) + over * c + 127) / 255;
        out |= @min(v, full) << sh;
    }
    return out;
}

test "blend: full coverage is the ink, none leaves the desk, a part mixes per channel" {
    var dst = [_]u32{ 0xFF102030, 0xFF102030, 0xFF102030 };
    const pic = [_]u32{ 0xFFFFFF, 0x000000, 0x800000 };
    blend(&dst, 3, 1, &pic, 3, 1, 0, 0, &.{.{ .left = 0, .top = 0, .right = 3, .bottom = 1 }}, .{ .r = 0xF0, .g = 0xE0, .b = 0xD0 });
    try std.testing.expectEqual(@as(u32, 0xFFF0E0D0), dst[0]);
    try std.testing.expectEqual(@as(u32, 0xFF102030), dst[1]);
    // Only red is covered, at half: red halfway to the ink, green and blue
    // untouched (ClearType's per-channel coverage).
    try std.testing.expectEqual(@as(u32, 0xFF802030), dst[2]);
}

test "blend: nothing lands outside the clip or the buffer" {
    var dst = [_]u32{0xFF000000} ** 9; // 3 x 3
    const pic = [_]u32{0xFFFFFF} ** 9;
    // Placed one up and one left, clipped to the right column.
    blend(&dst, 3, 3, &pic, 3, 3, -1, -1, &.{.{ .left = 1, .top = 0, .right = 3, .bottom = 3 }}, .{ .r = 255, .g = 255, .b = 255 });
    // The picture covers columns 0-1 of rows 0-1; the clip takes column 0
    // away, and its right column falls off the picture.
    const expect = [_]u32{
        0xFF000000, 0xFFFFFFFF, 0xFF000000,
        0xFF000000, 0xFFFFFFFF, 0xFF000000,
        0xFF000000, 0xFF000000, 0xFF000000,
    };
    try std.testing.expectEqualSlices(u32, &expect, &dst);
}

test "blend: a translucent pixel keeps its alpha and stays premultiplied" {
    var dst = [_]u32{ 0x80101010, 0x00000000 };
    const pic = [_]u32{ 0xFFFFFF, 0xFFFFFF };
    blend(&dst, 2, 1, &pic, 2, 1, 0, 0, &.{.{ .left = 0, .top = 0, .right = 2, .bottom = 1 }}, .{ .r = 255, .g = 255, .b = 255 });
    // White at alpha 0x80 is 0x80 per channel, premultiplied.
    try std.testing.expectEqual(@as(u32, 0x80808080), dst[0]);
    // Alpha zero is an opaque picture's pixel: mixed as opaque, alpha kept.
    try std.testing.expectEqual(@as(u32, 0x00FFFFFF), dst[1]);
}
