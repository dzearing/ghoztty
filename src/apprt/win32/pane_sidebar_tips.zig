//! The pane sidebar's tooltips, as rules (T1842; Mac `.help`,
//! `PaneSidebarRow.rowHelp`, `PaneSidebarView`'s collapse/expand button).
//!
//! Until T2289 this module also held the hover-open card's timing and its
//! z-order seat. Mac e77422577 retired hover-open - the rail never opens
//! under the pointer, and one header button switches collapsed and expanded -
//! so what is left is the wording every tile, row, row button and the toggle
//! carries.
//!
//! No OS imports, so this unit-tests in every app-runtime lane; the window
//! half is `PaneSidebar.zig`.

const std = @import("std");
const pane_sidebar = @import("pane_sidebar.zig");

/// A row's or tile's click hint (Mac `rowHelp`; the Alt-click swap joins the
/// stashed hint with T1845).
pub fn rowHint(section: pane_sidebar.Section) []const u8 {
    return switch (section) {
        .grid => "Click to focus",
        .stashed => "Click to restore",
    };
}

/// A stashed row's tooltip in the panel (T1845, Mac `rowHelp`): the click
/// hint, and the Alt-click swap beside it - the panel row has the room a
/// rail tile's two-line tip does not.
pub const stashed_row_tip = "Click to restore \u{00B7} Alt-click to swap with the focused pane";

/// A row's hover button.
pub fn buttonTip(section: pane_sidebar.Section) []const u8 {
    return switch (section) {
        .grid => "Stash",
        .stashed => "Restore",
    };
}

/// The collapse/expand toggle (Mac's wording, em dash and all): the panel's
/// collapses, the rail's expands - or, in a window too narrow for the panel,
/// says why it will not.
pub fn toggleTip(expanded: bool, can_expand: bool) []const u8 {
    if (expanded) return "Collapse the sidebar to icons";
    return if (can_expand) "Expand the sidebar" else "Too narrow to expand \u{2014} widen the window";
}

/// UTF-16 units one tile tooltip may hold, terminator included.
pub const tip_cap: usize = 192;

/// A rail tile's tooltip, into `out`, NUL-terminated: the pane's title (the
/// tile shows only its monogram, so the tip is where the name is read), then
/// the click hint on its own line. A title too long for the buffer is cut
/// with an ellipsis rather than dropping the hint. Returns the length without
/// the terminator.
pub fn tileTip(out: *[tip_cap]u16, title: []const u16, section: pane_sidebar.Section) usize {
    const hint = rowHint(section);
    // hint + "\n" + terminator always fit; the title takes what is left.
    const reserve = hint.len + 2;
    const room = tip_cap - reserve;
    var n: usize = 0;
    if (title.len <= room) {
        @memcpy(out[0..title.len], title);
        n = title.len;
    } else {
        @memcpy(out[0 .. room - 1], title[0 .. room - 1]);
        n = room - 1;
        // Never split a surrogate pair at the cut.
        if (n > 0 and std.unicode.utf16IsHighSurrogate(out[n - 1])) n -= 1;
        out[n] = 0x2026;
        n += 1;
    }
    if (n > 0) {
        out[n] = '\n';
        n += 1;
    }
    for (hint) |c| {
        out[n] = c;
        n += 1;
    }
    out[n] = 0;
    return n;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "pane_sidebar_tips: tooltip wording" {
    try testing.expectEqualStrings("Click to focus", rowHint(.grid));
    try testing.expectEqualStrings("Click to restore", rowHint(.stashed));
    try testing.expect(std.mem.startsWith(u8, stashed_row_tip, rowHint(.stashed)));
    try testing.expect(std.mem.indexOf(u8, stashed_row_tip, "Alt-click to swap") != null);
    try testing.expectEqualStrings("Stash", buttonTip(.grid));
    try testing.expectEqualStrings("Restore", buttonTip(.stashed));
}

test "pane_sidebar_tips: the toggle says what a click does, and why it cannot" {
    try testing.expectEqualStrings("Collapse the sidebar to icons", toggleTip(true, true));
    // Expanded is never shown in a narrow window (the rail stands in), but
    // the panel's own wording does not depend on the width.
    try testing.expectEqualStrings("Collapse the sidebar to icons", toggleTip(true, false));
    try testing.expectEqualStrings("Expand the sidebar", toggleTip(false, true));
    try testing.expectEqualStrings("Too narrow to expand \u{2014} widen the window", toggleTip(false, false));
}

test "pane_sidebar_tips: a tile's tip is its title, then the hint" {
    var out: [tip_cap]u16 = undefined;
    const title = std.unicode.utf8ToUtf16LeStringLiteral("claude - relay");
    const n = tileTip(&out, title, .grid);
    var want_buf: [64]u8 = undefined;
    var got_buf: [tip_cap * 3]u8 = undefined;
    const got = got_buf[0 .. std.unicode.utf16LeToUtf8(&got_buf, out[0..n]) catch unreachable];
    const want = std.fmt.bufPrint(&want_buf, "claude - relay\nClick to focus", .{}) catch unreachable;
    try testing.expectEqualStrings(want, got);
    try testing.expectEqual(@as(u16, 0), out[n]);

    // No title: just the hint.
    const n2 = tileTip(&out, &.{}, .stashed);
    const got2 = got_buf[0 .. std.unicode.utf16LeToUtf8(&got_buf, out[0..n2]) catch unreachable];
    try testing.expectEqualStrings("Click to restore", got2);
}

test "pane_sidebar_tips: a long title is cut with an ellipsis, keeping the hint and the terminator" {
    var out: [tip_cap]u16 = undefined;
    var long: [400]u16 = undefined;
    @memset(&long, 'a');
    const n = tileTip(&out, &long, .stashed);
    try testing.expect(n < tip_cap);
    try testing.expectEqual(@as(u16, 0), out[n]);
    const hint = "\nClick to restore";
    for (hint, 0..) |c, i| try testing.expectEqual(@as(u16, c), out[n - hint.len + i]);
    try testing.expectEqual(@as(u16, 0x2026), out[n - hint.len - 1]);

    // A surrogate pair straddling the cut is dropped whole, never halved.
    const room = tip_cap - ("Click to restore".len + 2);
    var pairs: [400]u16 = undefined;
    @memset(&pairs, 'b');
    pairs[room - 2] = 0xD83D;
    pairs[room - 1] = 0xDC7B;
    const m = tileTip(&out, &pairs, .stashed);
    const cut = m - hint.len - 1; // the ellipsis
    try testing.expectEqual(@as(u16, 0x2026), out[cut]);
    try testing.expect(!std.unicode.utf16IsHighSurrogate(out[cut - 1]));
}
