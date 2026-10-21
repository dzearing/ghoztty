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
const Direction = @import("pane_stack_layout.zig").Direction;

/// The label's size and weight: Mac's 11 pt semibold.
pub const label_dip: f32 = 11;
pub const label_weight: i32 = 600;
/// The space the label keeps from each end of its strip: Mac's 12 pt padding
/// (a horizontal strip's text is `size - 24` long).
pub const label_inset_dip: f32 = 12;

const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };

/// The strip's fill over a pane of background `bg`: the background darkened
/// (6% toward black on a light theme, 35% on a dark one), laid at 85% / 82%
/// over the pane's own colour. GDI has no alpha for a flat fill, so the blend
/// is resolved here into the opaque colour it reads as.
pub fn stripRgb(bg: Rgb) Rgb {
    const light = color_math.isLight(bg);
    const base = color_math.mix(bg, black, if (light) 0.06 else 0.35);
    return color_math.mix(bg, base, if (light) 0.85 else 0.82);
}

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
    const ds = stripRgb(dark_bg);
    const ls = stripRgb(light_bg);
    try testing.expect(color_math.luminance(ds) < color_math.luminance(dark_bg));
    try testing.expect(color_math.luminance(ls) < color_math.luminance(light_bg));
    // A light theme's strip is only a shade darker (Mac's 6% x 85%).
    try testing.expectEqual(@as(u8, 237), ls.r);
    // Dark ink on light, light ink on dark; the hovered ink is the stronger.
    const dl = inkRgb(ds, false, false);
    const dh = inkRgb(ds, false, true);
    try testing.expect(dl.r > ds.r and dh.r > dl.r);
    const ll = inkRgb(ls, true, false);
    const lh = inkRgb(ls, true, true);
    try testing.expect(ll.r < ls.r and lh.r < ll.r);
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
