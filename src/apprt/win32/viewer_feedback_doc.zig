//! The feedback composer's DOCUMENT: where a quoted passage goes when it is
//! inserted, which quotes are in the report, and how their places move when
//! native edits the text (T641, the win32 half of Mac's `feedbackQuoteID`
//! runs).
//!
//! Pure — text in, text out, no OS surface — so it is unit tested in the
//! `-Dapp-runtime=none` lane like the rest of `apprt/win32`'s pure modules.
//! `ViewerFeedbackBar` splices from what this decides, and `ViewerPane` owns
//! the `Registry` and the live spans.
//!
//! ## Identity is a NODE (T935)
//!
//! Mac hangs a `feedbackQuoteID` attribute on the quote's text run, so deleting
//! the run drops its metadata from the report. The composer's page does the
//! same with a `<div class="q" data-qid="N">`: deleting the block drops the
//! metadata with it, and editing the passage KEEPS it. The page reports its
//! live blocks in every snapshot, and `ViewerPane` keeps those spans as the
//! truth the report is written from.
//!
//! What native owes that arrangement is to keep the spans true across its OWN
//! edits — a quote or a picture spliced into the buffer — until the page's next
//! snapshot restates them. That is `shiftSpans`. Before T1704 this module
//! instead RE-DERIVED every quote by matching its registered passage against
//! the text (a design written for the RichEdit, which had no per-run field to
//! hang an id on); that silently dropped the metadata of any quote the user had
//! edited as soon as native touched the buffer, and it went with the RichEdit.
const std = @import("std");
const Allocator = std.mem.Allocator;

const bridge = @import("viewer_bridge.zig");

/// One quoted passage and the referential context the report writer (T637)
/// needs. Owns every string; freed by `Registry.deinit`.
pub const Entry = struct {
    /// Stable within one composer session, and never reused — the number a
    /// future `[Quote #N]` affordance would show, allocated the way the image
    /// carousel allocates chip numbers.
    id: u32,
    text: []const u8,
    heading_id: ?[]const u8 = null,
    heading_text: ?[]const u8 = null,
    block_selector: ?[]const u8 = null,
    block_text: ?[]const u8 = null,
    offset_in_block: ?u32 = null,
    document_offset: ?u32 = null,
};

/// Where a live quote sits in the composer text, as a byte range. `index` is into the registry's `entries`.
pub const Span = struct {
    start: usize,
    end: usize,
    index: usize,
};

/// Every quote inserted into this composer, in insertion order. Entries are
/// never removed when the user deletes a block — the page simply stops
/// reporting a span for it, which is what keeps "what is in the report" a
/// function of the document rather than of a side-channel someone has to
/// remember to update.
pub const Registry = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    next_id: u32 = 1,

    pub fn deinit(self: *Registry, alloc: Allocator) void {
        for (self.entries.items) |e| {
            alloc.free(e.text);
            if (e.heading_id) |v| alloc.free(v);
            if (e.heading_text) |v| alloc.free(v);
            if (e.block_selector) |v| alloc.free(v);
            if (e.block_text) |v| alloc.free(v);
        }
        self.entries.deinit(alloc);
        self.* = .{};
    }

    /// Copy one bridge message into the registry and return its id.
    ///
    /// The passage is normalised on the way in (see `normalize`) so the text
    /// stored here is byte-identical to the text that lands in the composer,
    /// and so the span `insertion` computes for it covers exactly the stored
    /// passage.
    pub fn add(self: *Registry, alloc: Allocator, q: bridge.Quote) !u32 {
        const text = try normalize(alloc, q.text);
        errdefer alloc.free(text);
        if (text.len == 0) return error.EmptyQuote;

        var e: Entry = .{
            .id = self.next_id,
            .text = text,
            .offset_in_block = q.offset_in_block,
            .document_offset = q.document_offset,
        };
        errdefer freeOptionals(alloc, &e);
        if (q.heading_id) |v| e.heading_id = try alloc.dupe(u8, v);
        if (q.heading_text) |v| e.heading_text = try alloc.dupe(u8, v);
        if (q.block_selector) |v| e.block_selector = try alloc.dupe(u8, v);
        if (q.block_text) |v| e.block_text = try alloc.dupe(u8, v);

        try self.entries.append(alloc, e);
        self.next_id += 1;
        return e.id;
    }

    fn freeOptionals(alloc: Allocator, e: *Entry) void {
        if (e.heading_id) |v| alloc.free(v);
        if (e.heading_text) |v| alloc.free(v);
        if (e.block_selector) |v| alloc.free(v);
        if (e.block_text) |v| alloc.free(v);
    }

    /// Where the entry with `id` sits in `entries`, or null when nothing does.
    ///
    /// The lookup the page's snapshots need (T935): a quote block names itself
    /// by id, and everything downstream — the report's metadata, the span the
    /// body is quoted from — is addressed by index. An id nobody knows is
    /// dropped rather than guessed at; that is a block from a composer session
    /// whose registry is gone, and inventing a match for it would attach one
    /// passage's heading to another's text.
    pub fn indexOfId(self: *const Registry, id: u32) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.id == id) return i;
        }
        return null;
    }
};

/// Canonical form of a passage: CRLF and bare CR become LF (the composer's
/// buffer speaks LF), and surrounding whitespace goes. A passage that trimmed away
/// to nothing is not a quote.
pub fn normalize(alloc: Allocator, raw: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\r') {
            if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
            buf.appendAssumeCapacity('\n');
        } else buf.appendAssumeCapacity(raw[i]);
    }
    const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
    const owned = try alloc.dupe(u8, trimmed);
    buf.deinit(alloc);
    return owned;
}

/// The edit that puts `passage` into `text` at `caret` as its own block.
///
/// `at` is where the delta goes (always the caret), `insert` is what to write
/// there, and `caret_after` is where the caret ends up: on a fresh line BELOW
/// the block, because the point of quoting is to say something about it.
pub const Insertion = struct {
    at: usize,
    insert: []u8,
    caret_after: usize,
    /// Where the passage itself sits in the document AFTER the insertion — the
    /// quote's span, without the blank lines around it.
    block_start: usize,
    block_end: usize,

    pub fn deinit(self: Insertion, alloc: Allocator) void {
        alloc.free(self.insert);
    }
};

/// Blank lines the block needs around it so it occupies complete lines with
/// air either side — computed from what is ALREADY there, so quoting twice in
/// a row does not stack up empty lines.
pub fn insertion(
    alloc: Allocator,
    text: []const u8,
    caret_in: usize,
    passage: []const u8,
) !Insertion {
    const caret = @min(caret_in, text.len);
    const lead = leadNewlines(text[0..caret]);
    const trail = trailNewlines(text[caret..]);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, lead + passage.len + trail);
    buf.appendNTimesAssumeCapacity('\n', lead);
    buf.appendSliceAssumeCapacity(passage);
    buf.appendNTimesAssumeCapacity('\n', trail);

    return .{
        .at = caret,
        .insert = try buf.toOwnedSlice(alloc),
        // Past the blank line under the block, whether those newlines came
        // from `trail` or were already in the text. Clamped, because a caret
        // beyond the document is not a place anything can put one.
        .caret_after = @min(
            caret + lead + passage.len + 2,
            text.len + lead + passage.len + trail,
        ),
        .block_start = caret + lead,
        .block_end = caret + lead + passage.len,
    };
}

/// How many newlines have to precede the block: enough that it starts on its
/// own line with one blank line above it, and none at all at the very top of
/// an empty composer.
fn leadNewlines(before: []const u8) usize {
    if (before.len == 0) return 0;
    var n: usize = 0;
    var i = before.len;
    while (i > 0 and before[i - 1] == '\n' and n < 2) : (i -= 1) n += 1;
    return 2 - n;
}

/// The same, after the block. Two newlines even at the end of the document:
/// that is the line the user is about to type on.
fn trailNewlines(after: []const u8) usize {
    var n: usize = 0;
    while (n < after.len and after[n] == '\n' and n < 2) n += 1;
    return 2 - n;
}

/// The spans `old` (ascending, over the text BEFORE the edit) moved across
/// inserting `len` bytes at `at`, plus `quote` — the block the insertion is,
/// when it is one, already in post-insert coordinates. Caller frees.
///
/// A span wholly before `at` stays; one at or after it moves by `len`. A span
/// the insertion lands strictly INSIDE is the one real decision:
///
/// - a picture chip (`quote` null) widens it, because a picture dropped into a
///   quoted passage is still inside that quote;
/// - a quote block drops it, because the new block splits the old passage in
///   two and a single span can no longer say where it is. Its entry stays in
///   the registry — the same thing that happens when the user deletes a block.
///
/// The result is ascending and non-overlapping, which is what
/// `ViewerPane.feedbackSetQuoteSpans` requires of it.
pub fn shiftSpans(
    alloc: Allocator,
    old: []const Span,
    at: usize,
    len: usize,
    quote: ?Span,
) ![]Span {
    var out: std.ArrayListUnmanaged(Span) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, old.len + 1);
    var placed = quote == null;
    for (old) |s| {
        if (s.end <= at) {
            out.appendAssumeCapacity(s);
            continue;
        }
        // Everything from here on is at or after the insertion, so the new
        // block belongs in front of it.
        if (!placed) {
            out.appendAssumeCapacity(quote.?);
            placed = true;
        }
        if (s.start >= at) {
            out.appendAssumeCapacity(.{ .start = s.start + len, .end = s.end + len, .index = s.index });
        } else if (quote == null) {
            out.appendAssumeCapacity(.{ .start = s.start, .end = s.end + len, .index = s.index });
        }
    }
    if (!placed) out.appendAssumeCapacity(quote.?);
    return out.toOwnedSlice(alloc);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// Apply an insertion to a buffer, the way the control does — the little bit
/// of glue that lets a test assert on the RESULTING document rather than on a
/// delta and an offset.
fn applied(alloc: Allocator, text: []const u8, caret: usize, passage: []const u8) ![]u8 {
    const ins = try insertion(alloc, text, caret, passage);
    defer ins.deinit(alloc);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, text[0..ins.at]);
    try out.appendSlice(alloc, ins.insert);
    try out.appendSlice(alloc, text[ins.at..]);
    return out.toOwnedSlice(alloc);
}

test "normalize: line endings and surrounding space" {
    const alloc = testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "  hello  ", .want = "hello" },
        .{ .in = "a\r\nb", .want = "a\nb" },
        .{ .in = "a\rb", .want = "a\nb" },
        .{ .in = "\n\nkeep me\n\n", .want = "keep me" },
        .{ .in = "   \t\n ", .want = "" },
    };
    for (cases) |c| {
        const got = try normalize(alloc, c.in);
        defer alloc.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "insertion: an empty composer gets the block and nothing else" {
    const alloc = testing.allocator;
    const got = try applied(alloc, "", 0, "the passage");
    defer alloc.free(got);
    // No leading blank line at the very top — a report that opens with an
    // empty line is a report that looks broken.
    try testing.expectEqualStrings("the passage\n\n", got);

    const ins = try insertion(alloc, "", 0, "the passage");
    defer ins.deinit(alloc);
    // The caret lands under the block, on the line the user types on.
    try testing.expectEqual(@as(usize, "the passage\n\n".len), ins.caret_after);
}

test "insertion: a block always occupies complete lines" {
    const alloc = testing.allocator;
    // Caret mid-word: the block still starts on its own line, with air above.
    const got = try applied(alloc, "already typed", 7, "quoted");
    defer alloc.free(got);
    try testing.expectEqualStrings("already\n\nquoted\n\n typed", got);
}

test "insertion: existing blank lines are reused, not stacked" {
    const alloc = testing.allocator;
    // One newline before -> one more is added; two -> none.
    const one = try applied(alloc, "note\n", 5, "q");
    defer alloc.free(one);
    try testing.expectEqualStrings("note\n\nq\n\n", one);

    const two = try applied(alloc, "note\n\n", 6, "q");
    defer alloc.free(two);
    try testing.expectEqualStrings("note\n\nq\n\n", two);

    // Quoting twice in a row is the case that stacks blank lines if the
    // trailing side is not counted too.
    const ins = try insertion(alloc, "note\n\nq\n\n", 9, "r");
    defer ins.deinit(alloc);
    const twice = try applied(alloc, "note\n\nq\n\n", 9, "r");
    defer alloc.free(twice);
    try testing.expectEqualStrings("note\n\nq\n\nr\n\n", twice);
    try testing.expectEqual(twice.len, ins.caret_after);
}

test "insertion: a caret past the end is clamped rather than refused" {
    const alloc = testing.allocator;
    const got = try applied(alloc, "abc", 99, "q");
    defer alloc.free(got);
    try testing.expectEqualStrings("abc\n\nq\n\n", got);
}

test "insertion: a multi-line passage stays one block" {
    const alloc = testing.allocator;
    const got = try applied(alloc, "", 0, "line one\nline two");
    defer alloc.free(got);
    try testing.expectEqualStrings("line one\nline two\n\n", got);
}

/// A bridge quote with just the fields a test cares about.
fn quoteOf(text: []const u8) bridge.Quote {
    return .{ .text = text };
}

test "add: an empty passage is refused rather than stored" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    try testing.expectError(error.EmptyQuote, reg.add(alloc, quoteOf("   \n ")));
    try testing.expectEqual(@as(usize, 0), reg.entries.items.len);
}

test "add: ids are never reused" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), try reg.add(alloc, quoteOf("a")));
    try testing.expectEqual(@as(u32, 2), try reg.add(alloc, quoteOf("b")));
    // A refused add does not burn an id either.
    try testing.expectError(error.EmptyQuote, reg.add(alloc, quoteOf("")));
    try testing.expectEqual(@as(u32, 3), try reg.add(alloc, quoteOf("c")));
}

test "add: a quote arriving with CRLF is stored the way it will be inserted" {
    // The composer's buffer speaks LF, so a stored CR would make the block's
    // span (computed from the stored passage) a byte longer than the text the
    // page actually shows.
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    _ = try reg.add(alloc, quoteOf("first\r\nsecond"));
    try testing.expectEqualStrings("first\nsecond", reg.entries.items[0].text);

    const ins = try insertion(alloc, "", 0, reg.entries.items[0].text);
    defer ins.deinit(alloc);
    try testing.expectEqualStrings("first\nsecond", ins.insert[ins.block_start..ins.block_end]);
}

test "insertion: the block span covers the passage and nothing around it" {
    const alloc = testing.allocator;
    const text = "already typed";
    const ins = try insertion(alloc, text, 7, "quoted");
    defer ins.deinit(alloc);
    const got = try applied(alloc, text, 7, "quoted");
    defer alloc.free(got);
    try testing.expectEqualStrings("quoted", got[ins.block_start..ins.block_end]);
    // Empty composer: no leading blank lines, so the span starts at 0.
    const first = try insertion(alloc, "", 0, "p");
    defer first.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), first.block_start);
    try testing.expectEqual(@as(usize, 1), first.block_end);
}

test "shiftSpans: spans before stay, spans after move, the new block lands between" {
    const alloc = testing.allocator;
    // Quotes A=[0,1) and B=[3,4); 5 bytes inserted at 3, the new quote at
    // [5,6).
    const old = [_]Span{
        .{ .start = 0, .end = 1, .index = 0 },
        .{ .start = 3, .end = 4, .index = 1 },
    };
    const got = try shiftSpans(alloc, &old, 3, 5, .{ .start = 5, .end = 6, .index = 2 });
    defer alloc.free(got);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(Span{ .start = 0, .end = 1, .index = 0 }, got[0]);
    try testing.expectEqual(Span{ .start = 5, .end = 6, .index = 2 }, got[1]);
    try testing.expectEqual(Span{ .start = 8, .end = 9, .index = 1 }, got[2]);
}

test "shiftSpans: an EDITED quote keeps its place and its identity" {
    // The regression the text matching had (T1704): the user changed a word in
    // quote 0, so its text no longer equals the registered passage, and then a
    // second quote arrived after it. The span is carried, not re-found.
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    _ = try reg.add(alloc, quoteOf("the passage"));
    _ = try reg.add(alloc, quoteOf("another"));

    const edited = "the pasage\n\n"; // one character gone
    const ins = try insertion(alloc, edited, edited.len, reg.entries.items[1].text);
    defer ins.deinit(alloc);
    const old = [_]Span{.{ .start = 0, .end = 10, .index = 0 }};
    const got = try shiftSpans(alloc, &old, ins.at, ins.insert.len, .{
        .start = ins.block_start,
        .end = ins.block_end,
        .index = 1,
    });
    defer alloc.free(got);
    const doc = try applied(alloc, edited, edited.len, reg.entries.items[1].text);
    defer alloc.free(doc);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("the pasage", doc[got[0].start..got[0].end]);
    try testing.expectEqual(@as(usize, 0), got[0].index);
    try testing.expectEqualStrings("another", doc[got[1].start..got[1].end]);
    try testing.expectEqual(@as(usize, 1), got[1].index);
}

test "shiftSpans: a picture inside a quote widens it, a quote inside one drops it" {
    const alloc = testing.allocator;
    const old = [_]Span{.{ .start = 2, .end = 10, .index = 0 }};

    const chip = try shiftSpans(alloc, &old, 5, 12, null);
    defer alloc.free(chip);
    try testing.expectEqual(@as(usize, 1), chip.len);
    try testing.expectEqual(Span{ .start = 2, .end = 22, .index = 0 }, chip[0]);

    const quote = try shiftSpans(alloc, &old, 5, 9, .{ .start = 7, .end = 10, .index = 1 });
    defer alloc.free(quote);
    try testing.expectEqual(@as(usize, 1), quote.len);
    try testing.expectEqual(@as(usize, 1), quote[0].index);
}

test "shiftSpans: an insertion right at a span's edges leaves the span whole" {
    const alloc = testing.allocator;
    const old = [_]Span{.{ .start = 4, .end = 8, .index = 0 }};
    // At its end: the span is before the insertion and does not move.
    const at_end = try shiftSpans(alloc, &old, 8, 3, null);
    defer alloc.free(at_end);
    try testing.expectEqual(Span{ .start = 4, .end = 8, .index = 0 }, at_end[0]);
    // At its start: the span moves whole.
    const at_start = try shiftSpans(alloc, &old, 4, 3, null);
    defer alloc.free(at_start);
    try testing.expectEqual(Span{ .start = 7, .end = 11, .index = 0 }, at_start[0]);
    // Nothing old, a quote only.
    const only = try shiftSpans(alloc, &.{}, 0, 3, .{ .start = 0, .end = 1, .index = 0 });
    defer alloc.free(only);
    try testing.expectEqual(@as(usize, 1), only.len);
}
