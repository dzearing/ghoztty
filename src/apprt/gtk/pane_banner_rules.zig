//! The GTK pane banner's pure decisions (T3559, Linux L10b): when the card
//! can collapse, what its collapsed title row holds, and what a key does in
//! the Set Pane Banner editor. `PaneBanner.zig` and `BannerEditor.zig` are the
//! GTK halves; this is the part the none lane tests on every seat.
//!
//! docs/reference/banners.md: clicking the card (or its chevron) collapses it
//! to its title row; the collapsed state is ephemeral and a cleared banner
//! comes back expanded. The editor takes Return as a newline, Cmd+Return
//! (Ctrl+Return here, as on Windows) to save, and Escape to cancel; empty text
//! clears the banner.
//!
//! No GTK imports.
const std = @import("std");
const md = @import("../win32/banner_markdown.zig");

/// A banner collapses only when it has something under its first line - the
/// win32 rule (`BannerOverlay.collapsible`): a one-line banner IS its title
/// row, so it has no chevron and a click on it does nothing.
pub fn collapsible(text: ?[]const u8) bool {
    const t = text orelse return false;
    return std.mem.indexOfScalar(u8, std.mem.trim(u8, t, " \t\r\n"), '\n') != null;
}

/// The blocks a collapsed card draws: its title row and nothing under it.
/// That is the first block, cut to one row - a list's first item, a table's
/// header (or, with no visible header, its first body row). A text line or
/// heading stays one block; the card draws it on one line, ellipsized.
/// Slices of `blocks`' own memory, so the caller's arena keeps them alive.
pub fn collapsedBlocks(blocks: []const md.Block, out: *[1]md.Block) []const md.Block {
    if (blocks.len == 0) return blocks;
    out[0] = switch (blocks[0]) {
        .list => |items| .{ .list = items[0..@min(items.len, 1)] },
        .table => |t| .{ .table = .{
            .header = t.header,
            .alignments = t.alignments,
            .rows = if (t.hasVisibleHeader()) t.rows[0..0] else t.rows[0..@min(t.rows.len, 1)],
        } },
        else => blocks[0],
    };
    return out[0..1];
}

/// What one key press in the editor's text box does.
pub const EditorKey = enum {
    /// Ctrl+Return (or Ctrl+keypad Enter): apply the text and close.
    save,
    /// Escape: close without applying.
    cancel,
    /// Anything else, plain Return included: the text box's own (a newline).
    pass,
};

pub const key_return: c_uint = 0xff0d; // GDK_KEY_Return
pub const key_kp_enter: c_uint = 0xff8d; // GDK_KEY_KP_Enter
pub const key_iso_enter: c_uint = 0xfe34; // GDK_KEY_ISO_Enter
pub const key_escape: c_uint = 0xff1b; // GDK_KEY_Escape
pub const mod_shift: c_uint = 1 << 0; // GDK_SHIFT_MASK
pub const mod_control: c_uint = 1 << 2; // GDK_CONTROL_MASK
pub const mod_alt: c_uint = 1 << 3; // GDK_ALT_MASK

pub fn editorKey(keyval: c_uint, state: c_uint) EditorKey {
    const enter = keyval == key_return or keyval == key_kp_enter or keyval == key_iso_enter;
    if (enter and state & mod_control != 0) return .save;
    if (keyval == key_escape and state & (mod_control | mod_alt | mod_shift) == 0) return .cancel;
    return .pass;
}

/// The banner the editor's text sets: surrounding blank space dropped (the
/// win32 `BannerDialog.normalizeText` rule, minus the CRLF a GTK text buffer
/// never holds). Empty means clear.
pub fn editorText(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n");
}

const testing = std.testing;

test "collapsible: only a banner with a line under its first" {
    try testing.expect(!collapsible(null));
    try testing.expect(!collapsible(""));
    try testing.expect(!collapsible("one line"));
    try testing.expect(!collapsible("one line\n"));
    try testing.expect(!collapsible("\n  title  \n\n"));
    try testing.expect(collapsible("title\nbody"));
    try testing.expect(collapsible("**Build**\n| a | b |\n|---|---|\n| 1 | 2 |"));
}

fn parse(arena: std.mem.Allocator, text: []const u8) ![]const md.Block {
    return md.parseBlocks(arena, .{ .posix = true }, text);
}

test "collapsedBlocks: the first block, cut to its first row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var one: [1]md.Block = undefined;

    // A title line over a body: just the title.
    const a = collapsedBlocks(try parse(arena, "## Title\nbody one\nbody two"), &one);
    try testing.expectEqual(@as(usize, 1), a.len);
    try testing.expect(a[0] == .heading);

    // A list first: its first item only.
    const b = collapsedBlocks(try parse(arena, "- one\n- two\n- three"), &one);
    try testing.expectEqual(@as(usize, 1), b.len);
    try testing.expectEqual(@as(usize, 1), b[0].list.len);

    // A table with a header: the header, no body rows.
    const c = collapsedBlocks(try parse(arena, "| Job | State |\n|---|---|\n| lint | ok |\n| test | red |"), &one);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqual(@as(usize, 0), c[0].table.rows.len);
    try testing.expectEqual(@as(usize, 2), c[0].table.header.len);

    // A key/value table with an empty header: its first body row.
    const d = collapsedBlocks(try parse(arena, "| | |\n|---|---|\n| k | v |\n| k2 | v2 |"), &one);
    try testing.expectEqual(@as(usize, 1), d[0].table.rows.len);

    // Nothing to draw stays nothing.
    try testing.expectEqual(@as(usize, 0), collapsedBlocks(&.{}, &one).len);
}

test "editorKey: Return is a newline, Ctrl+Return saves, Escape cancels" {
    try testing.expectEqual(EditorKey.pass, editorKey(key_return, 0));
    try testing.expectEqual(EditorKey.pass, editorKey(key_return, mod_shift));
    try testing.expectEqual(EditorKey.save, editorKey(key_return, mod_control));
    try testing.expectEqual(EditorKey.save, editorKey(key_kp_enter, mod_control));
    try testing.expectEqual(EditorKey.save, editorKey(key_iso_enter, mod_control | mod_shift));
    try testing.expectEqual(EditorKey.cancel, editorKey(key_escape, 0));
    try testing.expectEqual(EditorKey.pass, editorKey(key_escape, mod_control));
    try testing.expectEqual(EditorKey.pass, editorKey('a', mod_control));
}

test "editorText: surrounding blank space dropped, empty clears" {
    try testing.expectEqualStrings("a\nb", editorText("  a\nb \n\n"));
    try testing.expectEqualStrings("", editorText(" \n\t "));
    try testing.expectEqualStrings("**x**", editorText("**x**"));
}
