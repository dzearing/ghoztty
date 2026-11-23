//! Quoting a viewer page into the GTK feedback composer: the pure half
//! (T3545, Linux L9j-3; Mac `handleQuoteMessage` + `feedbackQuoteID`, win32
//! T641/T935).
//!
//! The toolbar itself is the SHARED `src/viewer/selection.js`, injected into
//! every page the viewer shows (the template and a website alike) exactly as
//! Mac and Windows inject it. It posts `{type:"quote", ...}` on the page
//! view's `viewerTOC` handler, which win32's pure `viewer_bridge.parse`
//! already reads into a `bridge.Quote` with its referential context.
//!
//! What this file adds is the GTK composer's arithmetic, reusing win32's pure
//! modules for every decision:
//!
//! - `splice`: a passage goes in at the caret as its own block
//!   (`viewer_feedback_doc.insertion`), and the live quote spans move across
//!   that edit (`shiftSpans`). The GTK composer keeps its caret in the page's
//!   UTF-16 units and its text in UTF-8, so the conversion at that boundary
//!   (`utf16_offset`, the T648 lesson) is here too.
//! - `seedSpans` / `adoptSpans`: the spans cross the page boundary DOWN as
//!   `{id,start,end}` in UTF-16 units (so a reopened page rebuilds the blocks
//!   with their ids) and come back UP the same way after every edit - the
//!   page's nodes are the truth (T935), so a deleted block drops its metadata
//!   and an edited one keeps it.
//! - `reportQuotes` / `resolveSourceLines`: what the report's `quotes` array
//!   carries, `sourceLine` resolved by searching the FILE at send time.
//! - `copyText`: the toolbar's Copy. GTK sets `window.__ghozttyHostCopy`, so
//!   the shared script posts `{type:"copy",text}` and the app writes the GDK
//!   clipboard; the page's async clipboard is not reliably granted to a script
//!   on a custom scheme.
//!
//! No GTK imports: every function asserts in the none lane.
const std = @import("std");
const Allocator = std.mem.Allocator;

const bridge = @import("../win32/viewer_bridge.zig");
const doc = @import("../win32/viewer_feedback_doc.zig");
const page = @import("../win32/viewer_feedback_page.zig");
const report = @import("../win32/viewer_feedback_report.zig");
const utf16 = @import("../win32/utf16_offset.zig");

/// The flag that routes the toolbar's Copy up the bridge (`selection.js`).
pub const host_copy_flag = "__ghozttyHostCopy";

/// What the page view injects: the flag, then the shared toolbar. One script
/// so the flag is set before the toolbar reads it.
pub const selection_script = "window." ++ host_copy_flag ++ " = true;\n" ++ bridge.selection_js;

/// Bytes of a source file read to resolve `sourceLine` (win32's cap): past it
/// the quotes have no line number, which the format allows.
pub const source_cap = 8 * 1024 * 1024;

/// The text of a `{type:"copy",text:"..."}` message, owned by the caller; null
/// for anything else (including an empty copy, which there is nothing to put on
/// the clipboard for).
pub fn copyText(alloc: Allocator, json_text: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const kind = switch (obj.get("type") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (!std.mem.eql(u8, kind, "copy")) return null;
    const text = switch (obj.get("text") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (text.len == 0) return null;
    return alloc.dupe(u8, text) catch null;
}

/// The composer after a quote went in. Owns both slices.
pub const Spliced = struct {
    text: []u8,
    spans: []doc.Span,
    /// Where the caret lands (below the block), in the page's UTF-16 units.
    caret_units: i64,

    pub fn deinit(self: Spliced, alloc: Allocator) void {
        alloc.free(self.text);
        alloc.free(self.spans);
    }
};

/// Put `passage` (a registry entry's normalized text, entry `index`) into
/// `text` as its own block at the caret, and carry the live `spans` across.
///
/// `caret_units` is the page's caret in UTF-16 units, negative for "at the
/// end" (a composer that never reported one). `spans` are byte spans over
/// `text`, ascending.
pub fn splice(
    alloc: Allocator,
    text: []const u8,
    caret_units: i64,
    spans: []const doc.Span,
    passage: []const u8,
    index: usize,
) !Spliced {
    const caret = if (caret_units < 0) text.len else utf16.byteForUnits(text, @intCast(caret_units));
    const ins = try doc.insertion(alloc, text, caret, passage);
    defer ins.deinit(alloc);

    const out = try std.mem.concat(alloc, u8, &.{ text[0..ins.at], ins.insert, text[ins.at..] });
    errdefer alloc.free(out);
    const moved = try doc.shiftSpans(alloc, spans, ins.at, ins.insert.len, .{
        .start = ins.block_start,
        .end = ins.block_end,
        .index = index,
    });
    return .{
        .text = out,
        .spans = moved,
        .caret_units = @intCast(utf16.unitsBeforeByte(out, ins.caret_after)),
    };
}

/// The byte spans as the page's seed wants them: registry ids and UTF-16
/// units. A span naming no entry is skipped. Caller frees.
pub fn seedSpans(
    alloc: Allocator,
    text: []const u8,
    spans: []const doc.Span,
    entries: []const doc.Entry,
) ![]page.QuoteSpan {
    var out: std.ArrayListUnmanaged(page.QuoteSpan) = .empty;
    errdefer out.deinit(alloc);
    for (spans) |s| {
        if (s.index >= entries.len) continue;
        try out.append(alloc, .{
            .id = entries[s.index].id,
            .start = @intCast(utf16.unitsBeforeByte(text, s.start)),
            .end = @intCast(utf16.unitsBeforeByte(text, s.end)),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// A snapshot's quote blocks as byte spans over `text` (the snapshot's own
/// text). A block whose id this composer never issued is dropped rather than
/// matched to a neighbour, and so is one that is empty, past the end, or out
/// of order - win32's `quoteSpanIsSane`: what reads these next is the report
/// writer, which quotes `text[start..end]`. Caller frees.
pub fn adoptSpans(
    alloc: Allocator,
    text: []const u8,
    quotes: []const page.QuoteSpan,
    registry: *const doc.Registry,
) ![]doc.Span {
    var out: std.ArrayListUnmanaged(doc.Span) = .empty;
    errdefer out.deinit(alloc);
    var at: usize = 0;
    for (quotes) |q| {
        const index = registry.indexOfId(q.id) orelse continue;
        const start = utf16.byteForUnits(text, q.start);
        const end = utf16.byteForUnits(text, q.end);
        if (start < at or end <= start or end > text.len) continue;
        try out.append(alloc, .{ .start = start, .end = end, .index = index });
        at = end;
    }
    return out.toOwnedSlice(alloc);
}

/// The report's `quotes`, one per live span, every string duped into `aa`
/// (the send job's arena, which outlives the pane's buffers on the worker).
/// `edited_text` is the block as it now reads when the user reworded it
/// (T985); `text` stays the page's wording, which is what `sourceLine` finds.
pub fn reportQuotes(
    aa: Allocator,
    text: []const u8,
    spans: []const doc.Span,
    entries: []const doc.Entry,
) ![]report.Quote {
    var out: std.ArrayListUnmanaged(report.Quote) = .empty;
    for (spans) |sp| {
        if (sp.index >= entries.len) continue;
        const e = entries[sp.index];
        const edited: ?[]const u8 = if (sp.start <= sp.end and sp.end <= text.len)
            report.editedText(e.text, text[sp.start..sp.end])
        else
            null;
        try out.append(aa, .{
            .number = e.id,
            .text = try aa.dupe(u8, e.text),
            .heading_id = try dupeOpt(aa, e.heading_id),
            .heading_text = try dupeOpt(aa, e.heading_text),
            .block_selector = try dupeOpt(aa, e.block_selector),
            .block_text = try dupeOpt(aa, e.block_text),
            .offset_in_block = e.offset_in_block,
            .document_offset = e.document_offset,
            .edited_text = try dupeOpt(aa, edited),
        });
    }
    return out.toOwnedSlice(aa);
}

fn dupeOpt(aa: Allocator, value: ?[]const u8) !?[]const u8 {
    const v = value orelse return null;
    return try aa.dupe(u8, v);
}

/// Each quote's 1-based line in the file the pane shows, by searching it
/// (`report.sourceLine`); a passage it cannot place keeps null.
pub fn resolveSourceLines(aa: Allocator, source: []const u8, quotes: []report.Quote) void {
    for (quotes) |*q| q.source_line = report.sourceLine(aa, source, q.text);
}

/// The number of live quotes a describe line reports.
pub fn liveCount(spans: []const doc.Span, entries: []const doc.Entry) usize {
    var n: usize = 0;
    for (spans) |s| {
        if (s.index < entries.len) n += 1;
    }
    return n;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn quote(text: []const u8) bridge.Quote {
    return .{ .text = text, .heading_id = "intro", .block_selector = "p:nth-of-type(2)", .offset_in_block = 4 };
}

test "the page script sets the host-copy flag BEFORE the shared toolbar" {
    const flag_at = std.mem.indexOf(u8, selection_script, "window." ++ host_copy_flag ++ " = true;").?;
    const toolbar_at = std.mem.indexOf(u8, selection_script, "window.__ghozttySelection = true").?;
    try testing.expect(flag_at < toolbar_at);
    // The toolbar still has its Quote button: nothing here hides it.
    try testing.expect(std.mem.indexOf(u8, selection_script[0..toolbar_at], "__ghozttyHideQuote") == null);
}

test "the shared toolbar routes Copy up the bridge when the flag is set" {
    // The branch this host relies on, in the script every platform ships.
    try testing.expect(std.mem.indexOf(u8, bridge.selection_js, "if (window." ++ host_copy_flag ++ ")") != null);
    try testing.expect(std.mem.indexOf(u8, bridge.selection_js, "post({ type: \"copy\", text: found.text })") != null);
}

test "copyText: a copy message's text, and nothing else" {
    const alloc = testing.allocator;
    const got = copyText(alloc, "{\"type\":\"copy\",\"text\":\"fox \\u00e9\"}").?;
    defer alloc.free(got);
    try testing.expectEqualStrings("fox \xc3\xa9", got);
    try testing.expect(copyText(alloc, "{\"type\":\"copy\",\"text\":\"\"}") == null);
    try testing.expect(copyText(alloc, "{\"type\":\"copy\"}") == null);
    try testing.expect(copyText(alloc, "{\"type\":\"copy\",\"text\":3}") == null);
    try testing.expect(copyText(alloc, "{\"type\":\"quote\",\"text\":\"x\"}") == null);
    try testing.expect(copyText(alloc, "[1]") == null);
    try testing.expect(copyText(alloc, "not json") == null);
}

test "a copy message is not a bridge message (it reaches copyText, not parse)" {
    try testing.expect(bridge.parse(testing.allocator, "{\"type\":\"copy\",\"text\":\"x\"}") == null);
}

test "splice: into an empty composer, the caret below the block" {
    const alloc = testing.allocator;
    const s = try splice(alloc, "", -1, &.{}, "the passage", 0);
    defer s.deinit(alloc);
    try testing.expectEqualStrings("the passage\n\n", s.text);
    try testing.expectEqual(@as(usize, 1), s.spans.len);
    try testing.expectEqual(doc.Span{ .start = 0, .end = 11, .index = 0 }, s.spans[0]);
    try testing.expectEqual(@as(i64, 13), s.caret_units);
}

test "splice: at the end of typed text, after a blank line" {
    const alloc = testing.allocator;
    const s = try splice(alloc, "look", -1, &.{}, "q", 0);
    defer s.deinit(alloc);
    try testing.expectEqualStrings("look\n\nq\n\n", s.text);
    try testing.expectEqualStrings("q", s.text[s.spans[0].start..s.spans[0].end]);
}

test "splice: a caret in UTF-16 units lands on the right byte past non-ASCII text" {
    const alloc = testing.allocator;
    // "é😀" is 2 + 4 bytes but 1 + 2 UTF-16 units; the caret sits after it.
    const text = "\xc3\xa9\xf0\x9f\x98\x80 tail";
    const s = try splice(alloc, text, 3, &.{}, "Q", 0);
    defer s.deinit(alloc);
    try testing.expectEqualStrings("\xc3\xa9\xf0\x9f\x98\x80\n\nQ\n\n tail", s.text);
    try testing.expectEqualStrings("Q", s.text[s.spans[0].start..s.spans[0].end]);
    // Caret after the blank line under the block: 3 + 2 + 1 + 2 units.
    try testing.expectEqual(@as(i64, 8), s.caret_units);
}

test "splice: a second quote above the first moves the first along" {
    const alloc = testing.allocator;
    const a = try splice(alloc, "", -1, &.{}, "first", 0);
    defer a.deinit(alloc);
    const b = try splice(alloc, a.text, 0, a.spans, "second", 1);
    defer b.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), b.spans.len);
    try testing.expectEqualStrings("second", b.text[b.spans[0].start..b.spans[0].end]);
    try testing.expectEqual(@as(usize, 1), b.spans[0].index);
    try testing.expectEqualStrings("first", b.text[b.spans[1].start..b.spans[1].end]);
    try testing.expectEqual(@as(usize, 0), b.spans[1].index);
}

test "seedSpans and adoptSpans round-trip through UTF-16 units and ids" {
    const alloc = testing.allocator;
    var reg: doc.Registry = .{};
    defer reg.deinit(alloc);
    _ = try reg.add(alloc, quote("caf\xc3\xa9"));
    _ = try reg.add(alloc, quote("\xf0\x9f\x98\x80 b"));
    const a = try splice(alloc, "\xc3\xa9 ", -1, &.{}, reg.entries.items[0].text, 0);
    defer a.deinit(alloc);
    const b = try splice(alloc, a.text, -1, a.spans, reg.entries.items[1].text, 1);
    defer b.deinit(alloc);

    const down = try seedSpans(alloc, b.text, b.spans, reg.entries.items);
    defer alloc.free(down);
    try testing.expectEqual(@as(usize, 2), down.len);
    try testing.expectEqual(@as(u32, 1), down[0].id);
    try testing.expectEqual(@as(u32, 2), down[1].id);
    // "é \n\n" is 4 units before the first block; "café" is 4 units long.
    try testing.expectEqual(@as(u32, 4), down[0].start);
    try testing.expectEqual(@as(u32, 8), down[0].end);

    const up = try adoptSpans(alloc, b.text, down, &reg);
    defer alloc.free(up);
    try testing.expectEqualSlices(doc.Span, b.spans, up);
}

test "adoptSpans drops unknown ids, empty and overlapping blocks, and clamps one past the end" {
    const alloc = testing.allocator;
    var reg: doc.Registry = .{};
    defer reg.deinit(alloc);
    _ = try reg.add(alloc, quote("abc"));
    const text = "abc def ghi";
    const quotes = [_]page.QuoteSpan{
        .{ .id = 9, .start = 0, .end = 3 }, // never issued
        .{ .id = 1, .start = 4, .end = 4 }, // empty
        .{ .id = 1, .start = 4, .end = 7 }, // kept
        .{ .id = 1, .start = 5, .end = 9 }, // overlaps the kept one
        .{ .id = 1, .start = 8, .end = 40 }, // past the end: clamps to the text's end
    };
    const got = try adoptSpans(alloc, text, &quotes, &reg);
    defer alloc.free(got);
    // byteForUnits clamps 40 to text.len, which is a real run (8..11).
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(doc.Span{ .start = 4, .end = 7, .index = 0 }, got[0]);
    try testing.expectEqual(doc.Span{ .start = 8, .end = 11, .index = 0 }, got[1]);
}

test "reportQuotes carries the context, and the edit when the block was reworded" {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var reg: doc.Registry = .{};
    defer reg.deinit(alloc);
    _ = try reg.add(alloc, quote("quick brown fox"));
    _ = try reg.add(alloc, quote("lazy dog"));
    const text = "quick brown fox\n\nlazy cat\n\nnote";
    const spans = [_]doc.Span{
        .{ .start = 0, .end = 15, .index = 0 },
        .{ .start = 17, .end = 25, .index = 1 },
    };
    const qs = try reportQuotes(aa, text, &spans, reg.entries.items);
    try testing.expectEqual(@as(usize, 2), qs.len);
    try testing.expectEqual(@as(u32, 1), qs[0].number);
    try testing.expectEqualStrings("quick brown fox", qs[0].text);
    try testing.expectEqualStrings("intro", qs[0].heading_id.?);
    try testing.expectEqualStrings("p:nth-of-type(2)", qs[0].block_selector.?);
    try testing.expectEqual(@as(?u32, 4), qs[0].offset_in_block);
    try testing.expect(qs[0].edited_text == null);
    try testing.expectEqualStrings("lazy dog", qs[1].text);
    try testing.expectEqualStrings("lazy cat", qs[1].edited_text.?);
    try testing.expectEqual(@as(usize, 2), liveCount(&spans, reg.entries.items));
}

test "resolveSourceLines finds the passage in the file, and admits when it cannot" {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var qs = [_]report.Quote{
        .{ .number = 1, .text = "quick brown fox" },
        .{ .number = 2, .text = "nowhere in it" },
    };
    resolveSourceLines(aa, "# T\n\nThe **quick brown fox** jumps.\n", &qs);
    // Markdown emphasis sits around it in the source, not inside it.
    try testing.expectEqual(@as(?u32, 3), qs[0].source_line);
    try testing.expect(qs[1].source_line == null);
}
