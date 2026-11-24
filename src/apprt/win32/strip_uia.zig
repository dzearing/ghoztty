//! What a screen reader is told about a tucked pane's strip (T2122): Mac
//! `PaneStackTabView`'s accessibility, as the numbers and words the window's
//! UI Automation provider (`strip_uia_provider.zig`) answers with.
//!
//! On Mac each strip is an accessibility button labelled
//! `Tucked pane: <name>`, with the help text `Brings the pane forward`, whose
//! press brings the pane on show - the same thing a click on it does. A win32
//! strip is pixels the window paints (`pane_stack_strip`, T2109), with no
//! window of its own for a screen reader to find, so the window describes them
//! itself: one Invoke-able button per strip, children of the window.
//!
//! Pure, so the tests need no window and no COM: the name, the order a reader
//! walks the strips in, how a step from one strip reaches the next, which
//! strip is under a point, and the strip's runtime id.

const std = @import("std");
const testing = std.testing;

/// Mac's `accessibilityLabel` prefix.
pub const name_prefix = "Tucked pane: ";
/// Mac's `accessibilityHelp`.
pub const help_text = "Brings the pane forward";

/// The strip's accessible name: `Tucked pane: <label>`, where `label` is the
/// name the strip shows (`Window.paneStripLabel`, the banner title first).
/// Cut to `buf` when the label is longer than it, never past it.
pub fn name(label: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for ([_][]const u8{ name_prefix, label }) |part| {
        const take = @min(part.len, buf.len - n);
        @memcpy(buf[n..][0..take], part[0..take]);
        n += take;
    }
    // Never end on half a UTF-8 sequence: a reader would speak garbage. Only
    // the last character can have been cut.
    var end = n;
    if (end > 0) {
        const start = lastCharStart(buf[0..end]);
        const want = std.unicode.utf8ByteSequenceLength(buf[start]) catch 1;
        if (start + want > end) end = start;
    }
    return buf[0..end];
}

fn lastCharStart(s: []const u8) usize {
    var i = s.len - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// A strip's rectangle in screen pixels.
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }
};

/// The order a reader walks strips in: top to bottom, then left to right -
/// the order they read on screen, whatever order the engine paints them in
/// (`pane_stack_layout.paintOrder` is bottom-first, which is no reading order).
pub fn readsBefore(a: Rect, b: Rect) bool {
    if (a.top != b.top) return a.top < b.top;
    return a.left < b.left;
}

/// UIA's `NavigateDirection`.
pub const NavigateDirection = enum(i32) {
    parent = 0,
    next_sibling = 1,
    previous_sibling = 2,
    first_child = 3,
    last_child = 4,
    _,
};

/// Where a step from strip `from` (null: the window, whose children the
/// strips are) in direction `dir` lands among `count` strips: the index of a
/// strip, or null for none. `parent` is the caller's - a strip's parent is
/// the window, and the window's is not ours to answer.
pub fn navigate(count: usize, from: ?usize, dir: NavigateDirection) ?usize {
    if (count == 0) return null;
    const i = from orelse return switch (dir) {
        .first_child => 0,
        .last_child => count - 1,
        else => null,
    };
    if (i >= count) return null;
    return switch (dir) {
        .next_sibling => if (i + 1 < count) i + 1 else null,
        .previous_sibling => if (i > 0) i - 1 else null,
        else => null,
    };
}

/// The strip under screen point (x, y), given the strips in reading order and
/// each one's place in the paint order (`paint[i]` for strip `i`, higher is
/// on top): where strips overlap - a strip reaches under the one in front of
/// it (T2283) - the one painted last is the one the pointer is over, as the
/// window's own click hit test has it.
pub fn hitTest(rects: []const Rect, paint: []const usize, x: i32, y: i32) ?usize {
    var best: ?usize = null;
    for (rects, 0..) |r, i| {
        if (!r.contains(x, y)) continue;
        if (best) |b| {
            if (paint[i] < paint[b]) continue;
        }
        best = i;
    }
    return best;
}

/// The strip's part of its UIA runtime id (after `UiaAppendRuntimeId`): the
/// pane's address folded into 31 bits. Unique among the strips on show as
/// long as no two panes share their address's low bits past the allocator's
/// alignment, which a heap does not hand out; never 0, which UIA reserves.
pub fn runtimeIdPart(view_addr: usize) i32 {
    const folded: u64 = @as(u64, view_addr) >> 3;
    const mixed = folded ^ (folded >> 31);
    const v: i32 = @intCast(mixed & 0x7FFF_FFFF);
    return if (v == 0) 1 else v;
}

test "strip_uia: a strip is named like Mac's, prefix then the label" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Tucked pane: build logs", name("build logs", &buf));
    try testing.expectEqualStrings("Tucked pane: ", name("", &buf));
    try testing.expectEqualStrings("Brings the pane forward", help_text);
}

test "strip_uia: a name too long for its buffer is cut on a character boundary" {
    // "Tucked pane: " is 13 bytes and "a" one more; an "é" is 2, so in 15
    // bytes the first one would straddle the end and is dropped whole.
    var buf: [15]u8 = undefined;
    const got = name("a\u{e9}\u{e9}", &buf);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
    try testing.expectEqualStrings("Tucked pane: a", got);
    var room: [16]u8 = undefined;
    try testing.expectEqualStrings("Tucked pane: a\u{e9}", name("a\u{e9}\u{e9}", &room));
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("Tuck", name("x", &tiny));
}

test "strip_uia: strips read top to bottom, then left to right" {
    const a: Rect = .{ .left = 0, .top = 0, .right = 10, .bottom = 100 };
    const b: Rect = .{ .left = 20, .top = 0, .right = 30, .bottom = 100 };
    const c: Rect = .{ .left = 0, .top = 200, .right = 100, .bottom = 210 };
    try testing.expect(readsBefore(a, b));
    try testing.expect(!readsBefore(b, a));
    try testing.expect(readsBefore(b, c));
    try testing.expect(!readsBefore(a, a));
}

test "strip_uia: the window's children are the strips, first to last, and siblings step between them" {
    try testing.expectEqual(@as(?usize, 0), navigate(3, null, .first_child));
    try testing.expectEqual(@as(?usize, 2), navigate(3, null, .last_child));
    try testing.expectEqual(@as(?usize, null), navigate(3, null, .next_sibling));
    try testing.expectEqual(@as(?usize, null), navigate(3, null, .parent));
    try testing.expectEqual(@as(?usize, 1), navigate(3, 0, .next_sibling));
    try testing.expectEqual(@as(?usize, null), navigate(3, 2, .next_sibling));
    try testing.expectEqual(@as(?usize, null), navigate(3, 0, .previous_sibling));
    try testing.expectEqual(@as(?usize, 1), navigate(3, 2, .previous_sibling));
    // A strip has no children, and a strip that is gone has no siblings.
    try testing.expectEqual(@as(?usize, null), navigate(3, 1, .first_child));
    try testing.expectEqual(@as(?usize, null), navigate(3, 5, .next_sibling));
    // No strips at all: nothing anywhere.
    try testing.expectEqual(@as(?usize, null), navigate(0, null, .first_child));
}

test "strip_uia: the strip under a point is the one painted on top where two overlap" {
    const rects = [_]Rect{
        .{ .left = 0, .top = 0, .right = 40, .bottom = 100 },
        .{ .left = 30, .top = 0, .right = 70, .bottom = 100 },
    };
    // Reading order puts the left strip first; the paint order has it on top.
    try testing.expectEqual(@as(?usize, 0), hitTest(&rects, &.{ 1, 0 }, 35, 50));
    try testing.expectEqual(@as(?usize, 1), hitTest(&rects, &.{ 0, 1 }, 35, 50));
    try testing.expectEqual(@as(?usize, 1), hitTest(&rects, &.{ 1, 0 }, 60, 50));
    try testing.expectEqual(@as(?usize, null), hitTest(&rects, &.{ 0, 1 }, 80, 50));
    // The right and bottom edges are outside, as a RECT's are.
    try testing.expectEqual(@as(?usize, null), hitTest(&rects, &.{ 0, 1 }, 70, 50));
}

test "strip_uia: runtime ids are never zero and tell neighbouring panes apart" {
    try testing.expect(runtimeIdPart(0) != 0);
    const a = runtimeIdPart(0x1_0000_1000);
    const b = runtimeIdPart(0x1_0000_1400);
    try testing.expect(a > 0 and b > 0);
    try testing.expect(a != b);
    try testing.expectEqual(a, runtimeIdPart(0x1_0000_1000));
}
