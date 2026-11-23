//! Pictures in the GTK feedback composer: the pure half (T3546, Linux L9j-4;
//! Mac `[Image #N]` attachments + carousel, win32 T637/T646/T647/T936).
//!
//! A picture reaches the composer two ways - the composer's `+` button or
//! Ctrl+Shift+S takes a screenshot of the pane from the app's OWN render
//! (Wayland and a headless Weston offer no global capture), and a paste or a
//! drop in the shared `composer.js` page hands up a PNG - and both go the same
//! way from there, through win32's pure `viewer_feedback_images.Store`:
//!
//! - the store keeps the PNG and allocates the chip's STABLE number;
//! - `attach` splices `[Image #N]` in at the page's caret (UTF-16 units, the
//!   T648 lesson) and carries the live quote spans across that edit;
//! - `seedImageSpans` sends the live chips down with every seed, so a
//!   reopened page rebuilds each one as an atomic node (T936);
//! - `reportImages` is what the report's `images` array and the body's
//!   `![Image #N](images/image-N.png)` links are built from.
//!
//! What is attached is DERIVED from the text (`Store.live`), exactly as on
//! win32: delete a chip and its picture leaves the report and the thumbnail
//! strip with it, and the numbers left keep their gaps.
//!
//! No GTK imports: every function asserts in the none lane.
const std = @import("std");
const Allocator = std.mem.Allocator;

const doc = @import("../win32/viewer_feedback_doc.zig");
const images = @import("../win32/viewer_feedback_images.zig");
const page = @import("../win32/viewer_feedback_page.zig");
const report = @import("../win32/viewer_feedback_report.zig");
const utf16 = @import("../win32/utf16_offset.zig");

/// The composer after a chip went in. Owns both slices.
pub const Attached = struct {
    text: []u8,
    spans: []doc.Span,
    /// Just past the chip (and its trailing space), in the page's UTF-16 units.
    caret_units: i64,

    pub fn deinit(self: Attached, alloc: Allocator) void {
        alloc.free(self.text);
        alloc.free(self.spans);
    }
};

/// Put chip `number` into `text` at the caret (`caret_units` in UTF-16 units;
/// negative = at the end), with a space either side where there is not one
/// already (`images.insertion`), and move the live quote `spans` past it.
pub fn attach(
    alloc: Allocator,
    text: []const u8,
    caret_units: i64,
    spans: []const doc.Span,
    number: u32,
) !Attached {
    const caret = if (caret_units < 0) text.len else utf16.byteForUnits(text, @intCast(caret_units));
    const ins = try images.insertion(alloc, text, caret, number);
    defer ins.deinit(alloc);
    const out = try std.mem.concat(alloc, u8, &.{ text[0..ins.at], ins.insert, text[ins.at..] });
    errdefer alloc.free(out);
    const moved = try doc.shiftSpans(alloc, spans, ins.at, ins.insert.len, null);
    return .{
        .text = out,
        .spans = moved,
        .caret_units = @intCast(utf16.unitsBeforeByte(out, ins.caret_after)),
    };
}

/// Every live chip in `text` as the seed's `{n,start,end}` in UTF-16 units.
/// Caller frees.
pub fn seedImageSpans(alloc: Allocator, text: []const u8, store: *const images.Store) ![]page.ImageSpan {
    const live = try store.live(alloc, text);
    defer alloc.free(live);
    const out = try alloc.alloc(page.ImageSpan, live.len);
    for (live, 0..) |s, i| out[i] = .{
        .n = store.entries.items[s.index].number,
        .start = @intCast(utf16.unitsBeforeByte(text, s.start)),
        .end = @intCast(utf16.unitsBeforeByte(text, s.end)),
    };
    return out;
}

/// What a send files: one `report.Image` per live chip (PNG copied into `aa`,
/// which the worker owns), and their numbers for `images.renderLinks`.
pub const ReportImages = struct {
    images: []report.Image,
    numbers: []u32,
};

pub fn reportImages(aa: Allocator, text: []const u8, store: *const images.Store) !ReportImages {
    const live = try store.live(aa, text);
    const out = try aa.alloc(report.Image, live.len);
    const numbers = try aa.alloc(u32, live.len);
    for (live, 0..) |s, i| {
        const e = store.entries.items[s.index];
        out[i] = .{
            .number = e.number,
            .png = try aa.dupe(u8, e.png),
            .pixel_width = e.pixel_width,
            .pixel_height = e.pixel_height,
        };
        numbers[i] = e.number;
    }
    return .{ .images = out, .numbers = numbers };
}

/// The report body: quotes as markdown blockquotes first (`renderBody` moves
/// every offset), then each live chip re-found by text and turned into an
/// image link - win32's order (`ViewerPane.feedbackReport`).
pub fn renderBody(aa: Allocator, text: []const u8, spans: []const doc.Span, numbers: []const u32) ![]u8 {
    const quoted = try report.renderBody(aa, text, spans);
    return images.renderLinks(aa, quoted, numbers);
}

/// The number of the live chip the caret is in or touching, if any - the tile
/// the thumbnail strip rings (win32 `syncCarouselToCaret`).
pub fn chipAtCaret(alloc: Allocator, text: []const u8, caret_units: i64, store: *const images.Store) ?u32 {
    if (caret_units < 0) return null;
    const caret = utf16.byteForUnits(text, @intCast(caret_units));
    const live = store.live(alloc, text) catch return null;
    defer alloc.free(live);
    for (live) |s| {
        if (caret >= s.start and caret <= s.end) return store.entries.items[s.index].number;
    }
    return null;
}

/// `1,3` for the describe line; `-` for none.
pub fn numbersText(buf: []u8, numbers: []const u32) []const u8 {
    if (numbers.len == 0) return "-";
    var n: usize = 0;
    for (numbers, 0..) |num, i| {
        const s = std.fmt.bufPrint(buf[n..], "{s}{d}", .{ if (i == 0) "" else ",", num }) catch return buf[0..n];
        n += s.len;
    }
    return buf[0..n];
}

/// The thumbnail box, in logical pixels: the longest side of a tile's
/// picture. A screenshot of a wide pane stays wide, a tall one tall.
pub const thumb_px: i32 = 56;

/// A tile's picture size for a `w`x`h` image, fitted inside `thumb_px` on its
/// long side and never upscaled; at least 1 on each side.
pub fn thumbSize(w: u32, h: u32) struct { w: i32, h: i32 } {
    if (w == 0 or h == 0) return .{ .w = thumb_px, .h = thumb_px };
    const long: f64 = @floatFromInt(@max(w, h));
    const scale: f64 = @min(1.0, @as(f64, @floatFromInt(thumb_px)) / long);
    const tw: i32 = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(w)) * scale)));
    const th: i32 = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(h)) * scale)));
    return .{ .w = tw, .h = th };
}

/// The device-pixel size a capture of a `w`x`h` logical widget renders at.
/// Null for a widget with no area (not laid out, or collapsed), which has
/// nothing to capture.
pub fn captureSize(w: i32, h: i32, scale: i32) ?struct { w: u32, h: u32 } {
    if (w <= 0 or h <= 0) return null;
    const s: i32 = @max(1, scale);
    return .{ .w = @intCast(w * s), .h = @intCast(h * s) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fakePng(alloc: Allocator, w: u32, h: u32) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &images.signature);
    try out.appendSlice(alloc, &[_]u8{ 0, 0, 0, 13 });
    try out.appendSlice(alloc, "IHDR");
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, w, .big);
    try out.appendSlice(alloc, &be);
    std.mem.writeInt(u32, &be, h, .big);
    try out.appendSlice(alloc, &be);
    try out.appendNTimes(alloc, 0, 8);
    return out.toOwnedSlice(alloc);
}

test "attach: the chip goes in at the caret with one space either side" {
    const a = testing.allocator;
    const r = try attach(a, "see this", 3, &.{}, 1);
    defer r.deinit(a);
    try testing.expectEqualStrings("see [Image #1] this", r.text);
    // Past the chip and its trailing space.
    try testing.expectEqual(@as(i64, 14), r.caret_units);
}

test "attach: no caret means the end; no doubled spaces" {
    const a = testing.allocator;
    const r = try attach(a, "end ", -1, &.{}, 4);
    defer r.deinit(a);
    try testing.expectEqualStrings("end [Image #4] ", r.text);
}

test "attach: the caret is in UTF-16 units, not bytes" {
    const a = testing.allocator;
    // "é" is 2 bytes, 1 unit: caret 2 is after "éa".
    const r = try attach(a, "éab", 2, &.{}, 2);
    defer r.deinit(a);
    try testing.expectEqualStrings("éa [Image #2] b", r.text);
}

test "attach: a quote after the caret moves past the chip; one before stays" {
    const a = testing.allocator;
    const spans = [_]doc.Span{
        .{ .start = 0, .end = 2, .index = 0 },
        .{ .start = 6, .end = 9, .index = 1 },
    };
    // "ab\n\nx def": caret at 5 (before "def"'s span? no - after "x").
    const r = try attach(a, "ab\n\nx def", 5, &spans, 1);
    defer r.deinit(a);
    try testing.expectEqualStrings("ab\n\nx [Image #1] def", r.text);
    try testing.expectEqual(@as(usize, 2), r.spans.len);
    try testing.expectEqual(@as(usize, 0), r.spans[0].start);
    try testing.expectEqual(@as(usize, 2), r.spans[0].end);
    try testing.expectEqualStrings("def", r.text[r.spans[1].start..r.spans[1].end]);
}

test "seedImageSpans: live chips only, in UTF-16 units, numbers kept" {
    const a = testing.allocator;
    var store: images.Store = .{};
    defer store.deinit(a);
    const p = try fakePng(a, 10, 10);
    defer a.free(p);
    _ = try store.add(a, p);
    _ = try store.add(a, p);
    _ = try store.add(a, p);
    // #2 was deleted; #9 is typed by hand and unknown.
    const text = "é [Image #1] [Image #3] [Image #9]";
    const spans = try seedImageSpans(a, text, &store);
    defer a.free(spans);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expectEqual(@as(u32, 1), spans[0].n);
    try testing.expectEqual(@as(u32, 2), spans[0].start);
    try testing.expectEqual(@as(u32, 12), spans[0].end);
    try testing.expectEqual(@as(u32, 3), spans[1].n);
}

test "reportImages + renderBody: the links and the files agree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var store: images.Store = .{};
    defer store.deinit(testing.allocator);
    const p = try fakePng(testing.allocator, 640, 480);
    defer testing.allocator.free(p);
    _ = try store.add(testing.allocator, p);
    _ = try store.add(testing.allocator, p);
    const text = "look [Image #2] here";
    const r = try reportImages(aa, text, &store);
    try testing.expectEqual(@as(usize, 1), r.images.len);
    try testing.expectEqual(@as(u32, 2), r.images[0].number);
    try testing.expectEqual(@as(?u32, 640), r.images[0].pixel_width);
    try testing.expectEqual(@as(?u32, 480), r.images[0].pixel_height);
    const body = try renderBody(aa, text, &.{}, r.numbers);
    try testing.expectEqualStrings("look ![Image #2](images/image-2.png) here", body);
}

test "chipAtCaret: inside or touching a live chip" {
    const a = testing.allocator;
    var store: images.Store = .{};
    defer store.deinit(a);
    const p = try fakePng(a, 4, 4);
    defer a.free(p);
    _ = try store.add(a, p);
    const text = "ab [Image #1] cd";
    try testing.expectEqual(@as(?u32, 1), chipAtCaret(a, text, 3, &store));
    try testing.expectEqual(@as(?u32, 1), chipAtCaret(a, text, 13, &store));
    try testing.expectEqual(@as(?u32, null), chipAtCaret(a, text, 15, &store));
    try testing.expectEqual(@as(?u32, null), chipAtCaret(a, text, -1, &store));
}

test "numbersText" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("-", numbersText(&buf, &.{}));
    try testing.expectEqualStrings("1,3", numbersText(&buf, &.{ 1, 3 }));
}

test "thumbSize fits the long side and never upscales" {
    const wide = thumbSize(800, 400);
    try testing.expectEqual(@as(i32, 56), wide.w);
    try testing.expectEqual(@as(i32, 28), wide.h);
    const tall = thumbSize(100, 400);
    try testing.expectEqual(@as(i32, 14), tall.w);
    try testing.expectEqual(@as(i32, 56), tall.h);
    const small = thumbSize(20, 10);
    try testing.expectEqual(@as(i32, 20), small.w);
    try testing.expectEqual(@as(i32, 10), small.h);
}

test "captureSize scales to device pixels and refuses an empty widget" {
    const s = captureSize(800, 600, 2).?;
    try testing.expectEqual(@as(u32, 1600), s.w);
    try testing.expectEqual(@as(u32, 1200), s.h);
    try testing.expect(captureSize(0, 600, 1) == null);
    try testing.expectEqual(@as(u32, 800), captureSize(800, 600, 0).?.w);
}
