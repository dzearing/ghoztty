//! The arithmetic behind the nav bar's idle address field (T2538).
//!
//! While nobody is editing it, the field is not a window on screen: the bar
//! paints it from a cached print of the hidden EDIT, made once at a width wide
//! enough for all of its text. A single-line EDIT showing its text from the
//! first character looks the same at any width up to its right margin, so the
//! field at a narrower width is the cache's left part, then the cache's own
//! right margin and border. Two blits per paint, and no EDIT moved or printed
//! while a drag changes the width on every step.
//!
//! Pure so the rules are testable without a window; `ViewerNavBar` does the
//! GDI.

const std = @import("std");

/// One horizontal slice copied from the cache into the field: `w` columns from
/// cache column `src_x` to field column `dst_x`, full height.
pub const Blit = struct {
    dst_x: i32,
    src_x: i32,
    w: i32,
};

/// The two slices that make a `field_w`-wide field from a `cache_w`-wide
/// print whose trailing `k` columns are right margin plus border. A field
/// narrower than `k` is all trailing edge; a zero-width slice is a no-op the
/// caller skips.
pub fn blits(field_w: i32, cache_w: i32, k: i32) [2]Blit {
    const fw = @max(field_w, 0);
    const kk = std.math.clamp(k, 0, @min(fw, @max(cache_w, 0)));
    const lead = @min(fw - kk, @max(cache_w - kk, 0));
    return .{
        .{ .dst_x = 0, .src_x = 0, .w = lead },
        .{ .dst_x = fw - kk, .src_x = cache_w - kk, .w = kk },
    };
}

/// How wide to print the cache: never narrower than the field, and wide enough
/// that the text - `inset` columns of left border and margin, `text_w` of
/// glyphs - ends before the trailing `k` columns, plus `slack` for the
/// partial-character rounding an EDIT does at its edge. Capped at `cap` (an
/// absurdly long address simply runs into the cached edge) unless the field
/// itself is wider.
pub fn cacheWidth(field_w: i32, inset: i32, text_w: i32, k: i32, cap: i32) i32 {
    const slack = 16;
    const want = @max(field_w, inset + text_w + k + slack);
    return @max(field_w, @min(want, cap));
}

/// Whether the cache has to be printed again before a paint at this size.
pub fn needsReprint(dirty: bool, cache_w: i32, cache_h: i32, field_w: i32, field_h: i32) bool {
    return dirty or cache_h != field_h or cache_w < field_w;
}

test "T2538: a narrower field is the cache's left part plus its trailing edge" {
    const b = blits(200, 900, 4);
    try std.testing.expectEqual(Blit{ .dst_x = 0, .src_x = 0, .w = 196 }, b[0]);
    try std.testing.expectEqual(Blit{ .dst_x = 196, .src_x = 896, .w = 4 }, b[1]);
}

test "T2538: a field exactly the cache's width is the cache" {
    const b = blits(300, 300, 3);
    try std.testing.expectEqual(@as(i32, 297), b[0].w);
    try std.testing.expectEqual(@as(i32, 297), b[1].dst_x);
    try std.testing.expectEqual(@as(i32, 297), b[1].src_x);
    try std.testing.expectEqual(@as(i32, 300), b[0].w + b[1].w);
}

test "T2538: a field narrower than its trailing edge is all edge" {
    const b = blits(2, 500, 4);
    try std.testing.expectEqual(@as(i32, 0), b[0].w);
    try std.testing.expectEqual(Blit{ .dst_x = 0, .src_x = 498, .w = 2 }, b[1]);
    const z = blits(0, 500, 4);
    try std.testing.expectEqual(@as(i32, 0), z[0].w + z[1].w);
}

test "T2538: the cache is wide enough for the text and never narrower than the field" {
    try std.testing.expectEqual(@as(i32, 400), cacheWidth(400, 3, 100, 4, 8192));
    try std.testing.expectEqual(@as(i32, 3 + 900 + 4 + 16), cacheWidth(400, 3, 900, 4, 8192));
    try std.testing.expectEqual(@as(i32, 8192), cacheWidth(400, 3, 20000, 4, 8192));
    try std.testing.expectEqual(@as(i32, 9000), cacheWidth(9000, 3, 20000, 4, 8192));
}

test "T2538: reprint only on a change the blits cannot absorb" {
    try std.testing.expect(!needsReprint(false, 900, 35, 200, 35));
    try std.testing.expect(!needsReprint(false, 900, 35, 900, 35));
    try std.testing.expect(needsReprint(true, 900, 35, 200, 35));
    try std.testing.expect(needsReprint(false, 900, 35, 901, 35));
    try std.testing.expect(needsReprint(false, 900, 35, 200, 36));
}
