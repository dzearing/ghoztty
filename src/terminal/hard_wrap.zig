//! Detection of rows that a TUI hard-wrapped itself.
//!
//! Terminal autowrap (soft wrap) is recorded in the grid: `Row.wrap` and
//! `Row.wrap_continuation` say exactly which rows continue each other, and
//! the formatter already joins them. A TUI that does its own word wrapping
//! (Claude Code, and anything built on Ink / wrap-ansi) records nothing: it
//! writes each visual row itself, re-indented to the left margin of its
//! text block, so the grid holds real newlines and real leading spaces.
//!
//! This file decides, from geometry alone, whether a row continues the row
//! above it. It is the ONE definition of that fact: the copy formatter uses
//! it to rejoin wrapped paragraphs, and both link matchers (hover highlight
//! and click) use it so a URL broken across a TUI wrap is one URL. Two
//! heuristics that could disagree about the same text is the failure this
//! module exists to prevent.
//!
//! The decision is necessarily a heuristic — "the author wrapped this" and
//! "the author wrote two short lines" can be byte-identical — so every rule
//! below biases toward leaving text alone. A missed join costs a newline
//! that was already on screen; a wrong join corrupts code or a table.
//!
//! The decision has two layers:
//!
//!   1. `boundary` classifies one pair of rows: whether they belong to one
//!      block of text at all, and if so whether the upper row ended where a
//!      word wrapper at the pane edge would have ended it.
//!
//!   2. `seamAt` / `seams` accept a wrap only if no nearby boundary in the
//!      same block is a near miss. A word wrapper NEVER leaves a word on
//!      the next row that would have fit on this one, so one near miss
//!      proves the block's line ends are the author's — a 72-column commit
//!      body in an 80-column pane, say, whose rows otherwise pass the
//!      per-row test about half the time and would come out half-joined.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const page = @import("page.zig");
const Cell = page.Cell;
const Row = page.Row;
const Pin = @import("PageList.zig").Pin;

/// The most columns a wrapped row may stop short of the right edge. A word
/// wrapper leaves at most (next word length) blank columns, which for prose
/// is small; a much larger gap means the line ended because its author
/// ended it ("Files:" above a long path), even if the next token is long.
pub const max_slack = 20;

/// How many boundaries above and below a candidate seam are searched for
/// a near miss. Bounded so the cost per row is constant.
pub const window = 8;

/// How two rows join when the second continues the first.
pub const Seam = struct {
    /// Leading cells of the continuation row to drop: its re-indentation.
    skip: usize,

    /// The text that replaces the newline. A wrap at a word boundary is a
    /// space; a wrap that broke a token too long for the line (a URL, a
    /// path) is nothing, so the token comes back whole.
    glue: Glue,

    pub const Glue = enum {
        space,
        none,

        pub fn bytes(self: Glue) []const u8 {
            return switch (self) {
                .space => " ",
                .none => "",
            };
        }
    };
};

/// The relationship between two vertically adjacent rows.
pub const Boundary = union(enum) {
    /// Not one block of text: a blank row, a new list item, a change of
    /// indentation, a table, code, or a terminal soft wrap.
    separate,

    /// One block, but the upper row stops well short of the edge: its
    /// author ended it.
    end,

    /// One block, and the upper row stops near the edge although the next
    /// word would have fit after it. Evidence against wrapping nearby.
    near_miss,

    /// One block, and the next token did not fit: a wrap, unless the
    /// block shows a near miss.
    wrap: Seam,
};

/// Classifies the boundary between `prev` and the row directly below it,
/// `next`. Both rows must be the same width.
pub fn boundary(
    prev_row: Row,
    prev: []const Cell,
    next_row: Row,
    next: []const Cell,
) Boundary {
    if (prev.len != next.len) return .separate;
    return classify(prev_row, Line.init(prev), next_row, Line.init(next), prev.len);
}

/// `boundary`, from rows already measured: `seams` measures each row once
/// and classifies both boundaries it takes part in from that.
fn classify(
    prev_row: Row,
    prev_line: ?Line,
    next_row: Row,
    next_line: ?Line,
    cols: usize,
) Boundary {
    // Terminal soft wraps are someone else's job, and a row involved in one
    // has no meaningful indentation of its own.
    if (prev_row.wrap or prev_row.wrap_continuation) return .separate;
    if (next_row.wrap_continuation) return .separate;

    const p = prev_line orelse return .separate;
    const n = next_line orelse return .separate;

    // Tables, box drawing, and columnar output (`ls -l`, aligned tool
    // output) are laid out on purpose. Merging their rows is worse than
    // the bug this fixes.
    if (p.structured or n.structured) return .separate;

    // A row that opens with a list marker, a quote bar, or a TUI gutter
    // glyph starts something new; it never continues the row above.
    if (n.marker != .none) return .separate;
    switch (n.first_cp) {
        '>', '|', '#', '`' => return .separate,
        else => {},
    }

    // A run of fields ("Author: ...", "Signed-off-by: ...") is one per
    // line by design. Both rows must open with a label: prose wraps before
    // a word like "following:" all the time.
    if (p.label and n.label) return .separate;

    // The continuation must sit exactly at the text column of the row it
    // continues: the block margin, or the hanging indent after a bullet.
    // Deeper indentation is structure (code, nesting) and must survive.
    if (n.first != p.content) return .separate;

    // Statement and block ends mark code, which is never prose-wrapped,
    // and a trailing ellipsis marks a row the TUI truncated: nothing of it
    // continues below.
    switch (p.last_cp) {
        '{', '}', ';', '…' => return .separate,
        else => {},
    }

    // The word-wrap test: a wrapper only breaks before a token that would
    // not have fit in the space left on the row. (An input box that wraps
    // one column short of the edge can turn a one-letter word into a near
    // miss; that costs a join, never corrupts one.)
    const slack = cols - p.end;
    const token = n.first_token;
    if (slack > max_slack) return .end;
    if (slack > token) return .near_miss;

    // A wrapper only breaks INSIDE a token when the token is longer than a
    // whole line, so a seam whose two halves together outrun the line was
    // a broken token (URL, path) and joins with nothing. Prose words are
    // never that long. The row must also reach the right edge (allowing
    // that column of padding): a long token the wrapper moved whole to a
    // fresh row leaves a gap behind it.
    const width = cols - p.content;
    const glue: Seam.Glue = if (slack <= 1 and
        p.last_token + token + 1 > width) .none else .space;

    return .{ .wrap = .{ .skip = n.first, .glue = glue } };
}

/// The seam joining the row at `pin` to the row above it, or null if the
/// newline between them is real. Rows may live in different pages.
pub fn seamAt(pin: Pin) ?Seam {
    return decide(PinRows{ .pin = pin });
}

/// Fills `out[i]` with the seam joining row `top + i` to the row above
/// it — `seamAt` for a run of consecutive rows, sharing the work between
/// them. Rows past the end of the screen get null. The renderer's path:
/// it decides a whole viewport at once.
pub fn seams(alloc: Allocator, top: Pin, out: []?Seam) Allocator.Error!void {
    // bounds[i] joins row (i - window) to the row above it, for every
    // boundary any decision in `out` can look at.
    const bounds = try alloc.alloc(Boundary, out.len + 2 * window);
    defer alloc.free(bounds);

    var above = measure(offset(top, -window - 1));
    for (bounds, 0..) |*b, i| {
        const below = measure(offset(top, @as(isize, @intCast(i)) - window));
        b.* = classifyMeasured(above, below);
        above = below;
    }

    for (out, 0..) |*o, i| o.* = decide(ArrayRows{
        .bounds = bounds,
        .center = i + window,
    });
}

/// Decides seams row by row, top to bottom, by the same rule as `seamAt`
/// but measuring each row once. The formatter's path: a copy can span an
/// entire scrollback, and per-row windows would read every row 2×window
/// times over.
pub const Walker = struct {
    /// The current row.
    pin: Pin,

    /// bounds[j] joins the row at offset (j - window) from the current row
    /// to the row above it: everything `seam` and `seamBelow` look at.
    bounds: [2 * window + 2]Boundary,

    /// The row at the bottom of `bounds`, and the pin of the row below it.
    newest: ?Measured,
    next: ?Pin,

    /// A walker whose current row is `pin`.
    pub fn init(pin: Pin) Walker {
        var self: Walker = undefined;
        self.pin = pin;
        var above = measure(offset(pin, -window - 1));
        for (&self.bounds, 0..) |*b, j| {
            const below = measure(offset(pin, @as(isize, @intCast(j)) - window));
            b.* = classifyMeasured(above, below);
            above = below;
        }
        self.newest = above;
        self.next = offset(pin, window + 2);
        return self;
    }

    /// The seam joining the current row to the row above it.
    pub fn seam(self: *const Walker) ?Seam {
        return decide(ArrayRows{ .bounds = &self.bounds, .center = window });
    }

    /// The seam joining the row below to the current row.
    pub fn seamBelow(self: *const Walker) ?Seam {
        return decide(ArrayRows{ .bounds = &self.bounds, .center = window + 1 });
    }

    /// Moves the current row to `pin`: one step when it is the next row
    /// down, which is how a top-to-bottom pass uses it, else a fresh start.
    pub fn moveTo(self: *Walker, pin: Pin) void {
        if (self.pin.node == pin.node and self.pin.y == pin.y) return;
        if (self.pin.down(1)) |below| {
            if (below.node == pin.node and below.y == pin.y) return self.advance();
        }
        self.* = .init(pin);
    }

    /// Moves the current row down one.
    pub fn advance(self: *Walker) void {
        self.pin = self.pin.down(1) orelse self.pin;
        std.mem.copyForwards(Boundary, self.bounds[0 .. self.bounds.len - 1], self.bounds[1..]);
        const below = measure(self.next);
        self.bounds[self.bounds.len - 1] = classifyMeasured(self.newest, below);
        self.newest = below;
        self.next = if (self.next) |n| n.down(1) else null;
    }
};

/// The most rows `extend` follows in each direction.
pub const max_extend = 32;

/// Extends a line spanning rows `top` through `bottom` (already joined by
/// any soft wraps) across TUI hard wraps, by at most `max_extend` rows each
/// way, and returns its new first and last rows. Link matching's path: it
/// runs on every mouse move, so every boundary is measured at most once.
pub fn extend(top: Pin, bottom: Pin) struct { top: Pin, bottom: Pin } {
    var up: Memo = .{ .origin = top };
    var k: isize = 0;
    while (-k < max_extend) : (k -= 1) {
        if (decide(Shifted{ .memo = &up, .shift = k }) == null) break;
    }
    const new_top = offset(top, k).?;

    // Downward, a joined row may itself soft-wrap onward; its whole soft
    // run belongs to the line and the next candidate is the row after it.
    var down: Memo = .{ .origin = bottom };
    var last: isize = 0;
    while (last < max_extend) {
        if (decide(Shifted{ .memo = &down, .shift = last + 1 }) == null) break;
        last += 1;
        while (last < max_extend) {
            const p = offset(bottom, last) orelse break;
            if (!p.rowAndCell().row.wrap or p.down(1) == null) break;
            last += 1;
        }
    }
    const new_bottom = offset(bottom, last).?;

    return .{ .top = new_top, .bottom = new_bottom };
}

/// One row, measured once.
const Measured = struct {
    row: Row,
    line: ?Line,
    cols: usize,
};

fn measure(pin: ?Pin) ?Measured {
    const p = pin orelse return null;
    const cells = p.cells(.all);
    return .{
        .row = p.rowAndCell().row.*,
        .line = Line.init(cells),
        .cols = cells.len,
    };
}

fn classifyMeasured(above: ?Measured, below: ?Measured) Boundary {
    const a = above orelse return .separate;
    const b = below orelse return .separate;
    if (a.cols != b.cols) return .separate;
    return classify(a.row, a.line, b.row, b.line, a.cols);
}

/// The row `k` rows below `pin` (above, for negative `k`).
fn offset(pin: Pin, k: isize) ?Pin {
    return if (k < 0) pin.up(@abs(k)) else if (k > 0) pin.down(@intCast(k)) else pin;
}

/// Lazily computed boundaries around an origin row, each at most once.
const Memo = struct {
    origin: Pin,
    cache: [2 * reach + 1]?Boundary = @splat(null),

    /// The farthest offset `extend` can ask about: `max_extend` steps plus
    /// a decision window, plus one.
    const reach = max_extend + window + 1;

    fn at(self: *Memo, k: isize) Boundary {
        if (@abs(k) > reach) return (PinRows{ .pin = self.origin }).at(k);
        const i: usize = @intCast(k + reach);
        if (self.cache[i]) |b| return b;
        const b = (PinRows{ .pin = self.origin }).at(k);
        self.cache[i] = b;
        return b;
    }
};

const Shifted = struct {
    memo: *Memo,
    shift: isize,

    fn at(self: Shifted, k: isize) Boundary {
        return self.memo.at(self.shift + k);
    }
};

/// Accepts the boundary at offset 0 as a seam if it is a wrap and no
/// boundary within `window` of it in the same block is a near miss.
/// `rows.at(k)` is the boundary between rows k-1 and k, relative to the
/// candidate row; offsets with no rows are `.separate`.
fn decide(rows: anytype) ?Seam {
    const s = switch (rows.at(0)) {
        .wrap => |s| s,
        .separate, .end, .near_miss => return null,
    };

    // Scan outward in both directions until the block ends.
    inline for (.{ -1, 1 }) |dir| {
        var k: isize = dir;
        while (@abs(k) <= window) : (k += dir) switch (rows.at(k)) {
            .wrap => {},
            .near_miss => return null,
            .separate, .end => break,
        };
    }

    return s;
}

const PinRows = struct {
    pin: Pin,

    fn at(self: PinRows, k: isize) Boundary {
        const below = offset(self.pin, k) orelse return .separate;
        return classifyMeasured(measure(below.up(1)), measure(below));
    }
};

const ArrayRows = struct {
    bounds: []const Boundary,
    center: usize,

    fn at(self: ArrayRows, k: isize) Boundary {
        const i = @as(isize, @intCast(self.center)) + k;
        if (i < 0 or i >= self.bounds.len) return .separate;
        return self.bounds[@intCast(i)];
    }
};

/// The column a row's text is measured from when computing the common
/// indentation of a block, or null for a blank row. A row led by a TUI
/// gutter glyph ("⏺ ", "❯ ") is measured at the text after the glyph, so
/// the glyph hangs in the margin instead of pinning the block's indent
/// at zero.
pub fn indent(cells: []const Cell) ?usize {
    const line = Line.init(cells) orelse return null;
    return switch (line.marker) {
        .gutter => line.content,
        .none, .list => line.first,
    };
}

/// The column of the first non-blank cell, or null for a blank row.
pub fn firstText(cells: []const Cell) ?usize {
    for (cells, 0..) |cell, x| if (!blank(cell)) return x;
    return null;
}

/// A cell that reads as whitespace. A spacer tail belongs to the wide
/// character before it and is never blank; a spacer head only pads the
/// end of a soft-wrapped row.
fn blank(cell: Cell) bool {
    return switch (cell.wide) {
        .spacer_tail => false,
        .spacer_head => true,
        .narrow, .wide => switch (cell.codepoint()) {
            0, ' ', '\t' => true,
            else => false,
        },
    };
}

const Marker = enum {
    none,

    /// Markdown-style list item: "- ", "* ", "+ ", "• ", "1. ", "2) ".
    list,

    /// A TUI's own decoration glyph ahead of its text: Claude Code's
    /// "⏺ " response bullet, "❯ " prompt, "⎿ " tool-output elbow, "▎ "
    /// quote bar, "⚠ " notices.
    gutter,
};

/// The measurements of one row that `seam` and `indent` work from.
const Line = struct {
    /// Column of the first non-blank cell.
    first: usize,

    /// Column of the text proper: after a leading marker, else `first`.
    content: usize,

    /// One past the last non-blank column.
    end: usize,

    first_cp: u21,
    last_cp: u21,

    /// Width in columns of the first token at `first` and the last token
    /// ending at `end`. A token is a run of non-blank cells.
    first_token: usize,
    last_token: usize,

    marker: Marker,

    /// Box drawing or a run of 3+ interior blanks: deliberate layout.
    structured: bool,

    /// The first token of the text proper (after any marker) is a label:
    /// two or more cells ending in ':'.
    label: bool,

    fn init(cells: []const Cell) ?Line {
        const first = firstText(cells) orelse return null;
        var last = first;
        for (cells[first..], first..) |cell, x| if (!blank(cell)) {
            last = x;
        };
        const end = last + @as(usize, if (cells[last].wide == .wide) 2 else 1);

        var structured = false;
        var run: usize = 0;
        for (cells[first..end]) |cell| {
            if (blank(cell)) {
                run += 1;
                if (run >= 3) structured = true;
                continue;
            }
            run = 0;
            if (boxDrawing(cell.codepoint())) structured = true;
        }

        const marker, const content = markerAt(cells, first);
        const first_token = tokenRight(cells, first);
        const content_token = tokenRight(cells, content);
        return .{
            .first = first,
            .content = content,
            .end = end,
            .first_cp = cells[first].codepoint(),
            .last_cp = cells[last].codepoint(),
            .first_token = first_token,
            .last_token = tokenLeft(cells, end),
            .marker = marker,
            .structured = structured,
            .label = content_token >= 2 and
                cells[content + content_token - 1].codepoint() == ':',
        };
    }
};

fn tokenRight(cells: []const Cell, start: usize) usize {
    var x = start;
    while (x < cells.len and !blank(cells[x])) x += 1;
    return x - start;
}

fn tokenLeft(cells: []const Cell, end: usize) usize {
    var x = end;
    while (x > 0 and !blank(cells[x - 1])) x -= 1;
    return end - x;
}

/// Recognizes a marker at `first` and returns it with the column the text
/// after it starts at. Up to two gutter glyphs may stack ("▎ ※ ").
fn markerAt(cells: []const Cell, first: usize) struct { Marker, usize } {
    var marker: Marker = .none;
    var x = first;
    for (0..2) |_| {
        const kind, const width = markerToken(cells, x) orelse break;
        if (marker == .none) marker = kind;
        x += width;
        while (x < cells.len and blank(cells[x])) x += 1;

        // A list marker is the item's own syntax; nothing stacks after it.
        if (kind == .list) break;
    }

    // A marker with no text after it is just a lone symbol.
    if (x >= cells.len) return .{ .none, first };
    return .{ marker, x };
}

/// A marker token at `x`: the token plus at least one blank after it.
fn markerToken(cells: []const Cell, x: usize) ?struct { Marker, usize } {
    const width = tokenRight(cells, x);
    if (width == 0 or x + width >= cells.len) return null;

    const cp = cells[x].codepoint();
    if (width == 1 or (width == 2 and cells[x].wide == .wide)) {
        return switch (cp) {
            '-', '*', '+', '•', '◦', '▪', '‣' => .{ .list, width },
            else => if (gutterGlyph(cp)) .{ .gutter, width } else null,
        };
    }

    // A short run of gutter glyphs ("⏵⏵ ") is one marker.
    if (width <= 3) gutter: {
        for (cells[x .. x + width]) |c| {
            if (c.wide == .spacer_tail) continue;
            if (!gutterGlyph(c.codepoint())) break :gutter;
        }
        return .{ .gutter, width };
    }

    // Ordered list: up to three digits then "." or ")".
    if (width >= 2 and width <= 4) {
        const term = cells[x + width - 1].codepoint();
        if (term != '.' and term != ')') return null;
        for (cells[x .. x + width - 1]) |c| switch (c.codepoint()) {
            '0'...'9' => {},
            else => return null,
        };
        return .{ .list, width };
    }

    return null;
}

/// Symbols a TUI draws as decoration in its own gutter: the punctuation,
/// arrows, technical, geometric, dingbat and emoji blocks. Box drawing is
/// excluded — it is table structure, not a bullet.
fn gutterGlyph(cp: u21) bool {
    return switch (cp) {
        0x2190...0x24FF, // arrows, math, misc technical (⏺ ⎿), enclosed
        0x2580...0x2BFF, // blocks (▎), geometric (●), misc symbols, dingbats
        0x203B, // ※
        0x1F300...0x1FAFF, // emoji
        => true,
        else => false,
    };
}

fn boxDrawing(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x257F;
}

// Test helpers: build one row of cells from a string, padded to `cols`.
fn testRow(comptime cols: usize, str: []const u8) [cols]Cell {
    var cells: [cols]Cell = @splat(Cell.init(0));
    var x: usize = 0;
    var it = (std.unicode.Utf8View.init(str) catch unreachable).iterator();
    while (it.nextCodepoint()) |cp| : (x += 1) cells[x] = Cell.init(cp);
    return cells;
}

fn testRowFlags(flags: struct { wrap: bool = false, wrap_continuation: bool = false }) Row {
    var row: Row = @bitCast(@as(u64, 0));
    row.wrap = flags.wrap;
    row.wrap_continuation = flags.wrap_continuation;
    return row;
}

fn testBoundary(comptime cols: usize, a: []const u8, b: []const u8) Boundary {
    const prev = testRow(cols, a);
    const next = testRow(cols, b);
    return boundary(testRowFlags(.{}), &prev, testRowFlags(.{}), &next);
}

/// The seam if the boundary is a wrap, else null.
fn testSeam(comptime cols: usize, a: []const u8, b: []const u8) ?Seam {
    return switch (testBoundary(cols, a, b)) {
        .wrap => |s| s,
        else => null,
    };
}

test "seam: Claude Code prose wraps at a word boundary" {
    // Rows from a real 100-column Claude Code render.
    const s = testSeam(
        100,
        "⏺ This is a deliberately long paragraph of ordinary prose that should be hard-wrapped by Claude",
        "  Code's own renderer at the pane's right edge, so that the copy transform has a real example to",
    ).?;
    try testing.expectEqual(2, s.skip);
    try testing.expectEqual(.space, s.glue);

    try testing.expectEqual(Seam.Glue.space, testSeam(
        100,
        "  Code's own renderer at the pane's right edge, so that the copy transform has a real example to",
        "  rejoin, with words that land near the boundary and a few longer words like internationalization",
    ).?.glue);
}

test "seam: URL broken mid-token joins with nothing" {
    const a = "  A very long URL that must wrap: https://github.com/dzearing/ghoztty/blob/main/src/terminal/formatt";
    const b = "  er.zig?plain=1&query=this-is-a-deliberately-long-query-string-that-keeps-going-and-going-past-the-";
    const c = "  right-edge-of-the-pane-for-testing#L1234-L1300 and some trailing text after it.";
    const ab = testSeam(100, a, b).?;
    try testing.expectEqual(.none, ab.glue);
    try testing.expectEqual(2, ab.skip);
    try testing.expectEqual(.none, testSeam(100, b, c).?.glue);
}

test "seam: input box keeps one column of right padding" {
    // Claude Code's prompt box breaks a path one column short of the edge.
    const s = testSeam(
        100,
        "❯ Print the contents of /private/tmp/claude-501/-Users-dzearing-git-ghoztty-copy-cleanup/faf212a3-b ",
        "  879-4ed3-a237-c28a7a89e0d6/scratchpad/sample.md as your reply, rendered as markdown exactly as    ",
    ).?;
    try testing.expectEqual(.none, s.glue);
}

test "seam: list hanging indents" {
    try testing.expect(testSeam(
        100,
        "  - A list item that is long enough to wrap onto a second row so that we can observe the hanging",
        "    indent Claude Code uses for list continuation lines in the rendered output, padding padding",
    ) != null);
    try testing.expect(testSeam(
        100,
        "  1. Numbered item that is long enough to wrap onto a second row so that we can observe the numbered",
        "     hanging indent Claude Code uses here.",
    ) != null);
    // The next item is never a continuation, however full the row above.
    try testing.expect(testSeam(
        100,
        "  - A list item that is long enough to wrap onto a second row so that we can observe the hanging",
        "  - Second item, short.",
    ) == null);
}

test "seam: rows that must stay separate" {
    // Short lines: the next word would have fit.
    try testing.expect(testSeam(40, "  Short line one.", "  Short line two.") == null);
    // Deeper indentation is code structure.
    try testing.expect(testSeam(30, "  const x = foo(bar, baz, q);", "      return x;") == null);
    // A code line ending a statement.
    try testing.expect(testSeam(30, "  const value = compute(a, b);", "  return value;") == null);
    // Tables and box drawing.
    try testing.expect(testSeam(
        40,
        "  │ a cell with some fairly long text  │",
        "  │ the pane is narrow enough to force │",
    ) == null);
    // Columnar output.
    try testing.expect(testSeam(
        51,
        "-rw-r--r--@  1 dzearing  staff   17088 Oct  7 a.zig",
        "-rw-r--r--@  1 dzearing  staff   14123 Oct  7 b.zig",
    ) == null);
    // A label above a long path: the gap behind the label is too wide to
    // be a wrap even though the path would not have fit.
    try testing.expect(testSeam(
        60,
        "  Files:",
        "  /Users/dzearing/git/ghoztty/src/terminal/formatter.zig",
    ) == null);
    // The quote bar repeats on its continuation: the bar is a marker.
    try testing.expect(testSeam(
        60,
        "  ▎ A blockquote that is long enough to wrap onto a second",
        "  ▎ quote continuation lines in the grid, more words.",
    ) == null);
    // Prose wraps before a word ending in a colon.
    try testing.expect(testSeam(
        60,
        "❯ Run these two shell commands with the Bash tool,",
        "  separately: 'ls -la src/renderer' and 'git log -2'. Then",
    ) != null);
    // Claude Code's footer: a truncated row, and a status row above a row
    // led by a double glyph.
    try testing.expect(testSeam(
        60,
        "  ctx: 69k/200k (34%) | files: 10 changed | v2.1.292 (Hai…",
        "  users/dzearing/copy-cleanup | ~/git/ghoztty-copy-cleanup",
    ) == null);
    try testing.expect(testSeam(
        60,
        "  users/dzearing/copy-cleanup | ~/git/ghoztty-copy-cleanup",
        "  ⏵⏵ bypass permissions on (shift+tab to cycle)",
    ) == null);
    // A run of fields stays one per line (git trailers).
    try testing.expect(testSeam(
        80,
        "    Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>",
        "    Claude-Session: https://claude.ai/code/session_01MvqsRJ6jaeJAeFdtjkj5e2",
    ) == null);
    // Blank rows.
    try testing.expect(testSeam(10, "abcdefghij", "") == null);
}

test "seam: soft-wrapped rows are not ours" {
    const prev = testRow(10, "abcdefghij");
    const next = testRow(10, "klmno");
    try testing.expectEqual(.separate, boundary(
        testRowFlags(.{ .wrap = true }),
        &prev,
        testRowFlags(.{ .wrap_continuation = true }),
        &next,
    ));
    try testing.expectEqual(.separate, boundary(
        testRowFlags(.{ .wrap_continuation = true }),
        &prev,
        testRowFlags(.{}),
        &next,
    ));
}

test "seam: near miss and author line ends" {
    // 72-column commit prose in an 80-column pane. "the" would have fit
    // after "local": no wrapper leaves that, so it is a near miss.
    try testing.expectEqual(.near_miss, testBoundary(
        80,
        "    Finder with the file selected. Present only while the pane shows a local",
        "    the markdown, code, HTML, image) -- a website or diff has nothing to",
    ));
    // A row ending far from the edge is simply where its author stopped.
    try testing.expectEqual(.end, testBoundary(80, "    Short.", "    Another line that is long."));
}

test "indent: gutter glyph hangs in the margin" {
    try testing.expectEqual(2, indent(&testRow(20, "⏺ Launched.")).?);
    try testing.expectEqual(2, indent(&testRow(20, "  Worktree: x")).?);
    // A list marker is content, not margin.
    try testing.expectEqual(0, indent(&testRow(20, "- item")).?);
    try testing.expectEqual(4, indent(&testRow(20, "    code")).?);
    try testing.expect(indent(&testRow(20, "")) == null);
    try testing.expect(indent(&testRow(20, "     ")) == null);
}
