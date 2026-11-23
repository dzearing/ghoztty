//! The GTK pane banner's pure half (T3339, Linux L10): banner markdown, as
//! parsed by the shared `banner_markdown` (the Mac's `BannerMarkdown`, ported
//! once for win32), turned into the Pango markup a `GtkLabel` draws.
//!
//! GTK has a markup language and a label that renders links in it, so the
//! Linux banner is stock widgets: a label per text line or heading, a grid per
//! list and per table, a separator per rule (`PaneBanner.zig`). This module is
//! the one translation those widgets need - an inline run to markup - plus
//! the small decisions around it (heading sizes, a table cell's alignment),
//! kept here so the none lane tests them on every seat.
//!
//! No GTK imports.
const std = @import("std");
const Allocator = std.mem.Allocator;
const md = @import("../win32/banner_markdown.zig");

/// Append `text` to `out`, escaped for Pango markup.
pub fn appendEscaped(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        '"' => try out.appendSlice(alloc, "&quot;"),
        '\'' => try out.appendSlice(alloc, "&apos;"),
        else => try out.append(alloc, c),
    };
}

/// The glyph a checkbox inside running text falls back to (the parser hands
/// a native box only to list markers and table cells; Mac's `☑`/`☐`).
pub fn checkboxGlyph(checked: bool) []const u8 {
    return if (checked) "\u{2611}" else "\u{2610}";
}

/// Append one inline run (styled text, links, glyph checkboxes) as markup.
/// A link is the outermost tag, so its whole label - bold parts and all - is
/// one clickable `<a>`; `GtkLabel` emits `activate-link` with the href.
pub fn appendInline(alloc: Allocator, out: *std.ArrayList(u8), items: []const md.Inline) Allocator.Error!void {
    // The href of the `<a>` currently open: consecutive runs of one link (a
    // label with a bold word in it) share a single tag.
    var open: ?[]const u8 = null;
    for (items) |item| {
        const link: ?[]const u8 = switch (item) {
            .seg => |s| if (s.text.len == 0) open else s.link,
            .checkbox => null,
        };
        const same = if (open != null and link != null) std.mem.eql(u8, open.?, link.?) else open == null and link == null;
        if (!same) {
            if (open != null) try out.appendSlice(alloc, "</a>");
            open = null;
            if (link) |href| {
                try out.appendSlice(alloc, "<a href=\"");
                try appendEscaped(alloc, out, href);
                try out.appendSlice(alloc, "\">");
                open = href;
            }
        }
        try appendRun(alloc, out, item);
    }
    if (open != null) try out.appendSlice(alloc, "</a>");
}

/// One run's styled text (its link tag is `appendInline`'s).
fn appendRun(alloc: Allocator, out: *std.ArrayList(u8), item: md.Inline) Allocator.Error!void {
    switch (item) {
        .checkbox => |checked| try out.appendSlice(alloc, checkboxGlyph(checked)),
        .seg => |s| {
            if (s.text.len == 0) return;
            if (s.style.bold) try out.appendSlice(alloc, "<b>");
            if (s.style.italic) try out.appendSlice(alloc, "<i>");
            if (s.style.underline) try out.appendSlice(alloc, "<u>");
            if (s.style.code) try out.appendSlice(alloc, "<tt>");
            try appendEscaped(alloc, out, s.text);
            if (s.style.code) try out.appendSlice(alloc, "</tt>");
            if (s.style.underline) try out.appendSlice(alloc, "</u>");
            if (s.style.italic) try out.appendSlice(alloc, "</i>");
            if (s.style.bold) try out.appendSlice(alloc, "</b>");
        },
    }
}

/// One inline run as a NUL-terminated markup string, optionally wrapped in a
/// span (a heading's size, a table header's weight).
pub fn markup(
    alloc: Allocator,
    items: []const md.Inline,
    wrap: ?[]const u8,
) Allocator.Error![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (wrap) |attrs| {
        try out.appendSlice(alloc, "<span ");
        try out.appendSlice(alloc, attrs);
        try out.appendSlice(alloc, ">");
    }
    try appendInline(alloc, &out, items);
    if (wrap != null) try out.appendSlice(alloc, "</span>");
    return out.toOwnedSliceSentinel(alloc, 0);
}

/// The span a heading of `level` is drawn in: bold, larger as the level
/// shrinks (the Mac's heading scale, in Pango's named sizes).
pub fn headingSpan(level: u8) []const u8 {
    return switch (level) {
        1 => "weight=\"bold\" size=\"x-large\"",
        2 => "weight=\"bold\" size=\"large\"",
        else => "weight=\"bold\"",
    };
}

/// A table cell's `xalign`, from the separator row's `:` markers.
pub fn cellXalign(alignment: ?md.ColumnAlignment) f32 {
    return switch (alignment orelse .leading) {
        .leading => 0.0,
        .center => 0.5,
        .trailing => 1.0,
    };
}

/// A list item's marker text: `•` for a bullet, `N.` for an ordered item.
/// Null for a checkbox, which is a native box, not text.
pub fn listMarker(buf: []u8, marker: md.ListMarker) ?[]const u8 {
    return switch (marker) {
        .bullet => "\u{2022}",
        .ordered => |n| std.fmt.bufPrint(buf, "{d}.", .{n}) catch "?.",
        .checkbox => null,
    };
}

/// A `file://` URI's path, percent-decoded, or the target unchanged when it
/// is already a plain path (an autolinked `/…`, `~/…` resolved by the
/// parser). Written into `buf`; null when it does not fit or is not a local
/// file URI.
pub fn localPath(buf: []u8, target: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(target, "file:")) {
        if (target.len > buf.len) return null;
        @memcpy(buf[0..target.len], target);
        return buf[0..target.len];
    }
    var rest = target["file:".len..];
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        // Only an empty (or `localhost`) authority is a local file.
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const host = rest[0..slash];
        if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return null;
        rest = rest[slash..];
    }
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) {
        if (n >= buf.len) return null;
        if (rest[i] == '%' and i + 2 < rest.len) {
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                buf[n] = hi.? * 16 + lo.?;
                n += 1;
                i += 3;
                continue;
            }
        }
        buf[n] = rest[i];
        n += 1;
        i += 1;
    }
    if (n == 0) return null;
    return buf[0..n];
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn firstText(arena: Allocator, src: []const u8) ![:0]const u8 {
    const blocks = try md.parseBlocks(arena, .{ .cwd = "/home/u/repo", .home = "/home/u", .posix = true }, src);
    return switch (blocks[0]) {
        .text => |t| try markup(arena, t, null),
        else => error.NotText,
    };
}

test "markup: styles nest and text is escaped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("<b>bold</b> and <i>it</i> <u>un</u> <tt>a&lt;b</tt>", try firstText(a, "**bold** and *it* __un__ `a<b`"));
    try testing.expectEqualStrings("Tom &amp; Jerry &lt;3 &quot;q&quot;", try firstText(a, "Tom & Jerry <3 \"q\""));
}

test "markup: a link owns its whole label and its href is escaped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Link text carries the parser's underline (the Mac draws links so).
    try testing.expectEqualStrings(
        "see <a href=\"https://x.io/?a=1&amp;b=2\"><u>the </u><b><u>PR</u></b></a>",
        try firstText(a, "see [the **PR**](https://x.io/?a=1&b=2)"),
    );
    // Two links side by side stay two tags.
    try testing.expectEqualStrings(
        "<a href=\"https://a.io\"><u>a</u></a> <a href=\"https://b.io\"><u>b</u></a>",
        try firstText(a, "[a](https://a.io) [b](https://b.io)"),
    );
    // Autolinks resolve against the POSIX context the GTK pane supplies.
    try testing.expectEqualStrings(
        "open <a href=\"/home/u/repo/docs/a.md\"><u>./docs/a.md</u></a>",
        try firstText(a, "open ./docs/a.md"),
    );
}

test "markup: an inline checkbox is a glyph; wraps add a span" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = try md.parseBlocks(a, .{}, "## Title");
    const h = blocks[0].heading;
    try testing.expectEqual(@as(u8, 2), h.level);
    try testing.expectEqualStrings("<span weight=\"bold\" size=\"large\">Title</span>", try markup(a, h.content, headingSpan(h.level)));
    try testing.expectEqualStrings("done \u{2611}", try firstText(a, "done [x]"));
}

test "cellXalign and listMarker" {
    try testing.expectEqual(@as(f32, 0), cellXalign(null));
    try testing.expectEqual(@as(f32, 0.5), cellXalign(.center));
    try testing.expectEqual(@as(f32, 1), cellXalign(.trailing));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("\u{2022}", listMarker(&buf, .bullet).?);
    try testing.expectEqualStrings("12.", listMarker(&buf, .{ .ordered = 12 }).?);
    try testing.expect(listMarker(&buf, .{ .checkbox = true }) == null);
}

test "localPath: plain paths pass, file URIs decode, remote hosts refuse" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/a b.md", localPath(&buf, "/home/u/a b.md").?);
    try testing.expectEqualStrings("/home/u/a b.md", localPath(&buf, "file:///home/u/a%20b.md").?);
    try testing.expectEqualStrings("/tmp/x", localPath(&buf, "file://localhost/tmp/x").?);
    try testing.expect(localPath(&buf, "file://server/share/x") == null);
    var tiny: [3]u8 = undefined;
    try testing.expect(localPath(&tiny, "/home/u/a.md") == null);
}
