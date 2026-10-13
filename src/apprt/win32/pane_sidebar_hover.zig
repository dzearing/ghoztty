//! The pane sidebar's hover-open card and its tooltips, as rules (T1842; Mac
//! `PaneSidebarHostView` hover-open, `PaneSidebarState.hoverOpenDelay`,
//! `PaneSidebarRow.rowHelp`).
//!
//! Unpinned, the sidebar is the mini rail. With the pointer on the rail's card
//! for a short intent delay, the card opens to the full panel width OVER the
//! grid - the column itself stays the rail's 68 DIP, so no terminal in the
//! window resizes as the pointer passes by. Leaving starts a grace period;
//! the card contracts when it runs out, unless the pointer came back, a press
//! is still held on the card, or (later) a drag or a menu is in flight. Only
//! the pin changes the column.
//!
//! No OS imports, so this unit-tests in every app-runtime lane; the window
//! half is `PaneSidebar.zig`.

const std = @import("std");
const pane_sidebar = @import("pane_sidebar.zig");

/// The intent delay on the way in, so passing over the rail on the way
/// somewhere else does not pop it open (Mac `hoverOpenDelay`, 0.1 s on main
/// as of 2026-10-11; the T1828 intake read 140 ms off an earlier revision).
pub const open_delay_ms: u32 = 100;
/// The grace period on the way out (Mac `hoverCloseDelay`).
pub const close_delay_ms: u32 = 280;

/// Whether the intent timer, on firing, should open the card: only while the
/// sidebar is still the rail, not already open, and the pointer is still on
/// the rail's card (Mac re-checks `pointerIsOverCard` at fire time, so a
/// pointer that crossed the rail and left in under the delay opens nothing).
/// The same test decides whether a pointer arms the timer at all; the rail's
/// margin is NOT the card - Mac's tracking area is `cardRect`.
pub fn opensOnTimer(mode: pane_sidebar.Mode, open: bool, pointer_on_rail_card: bool) bool {
    return mode == .mini and !open and pointer_on_rail_card;
}

pub const CloseVerdict = enum {
    /// The pointer is on the card: nothing to do; the next leave re-arms.
    stay,
    /// The pointer is gone but something holds the card open (a press on
    /// it, a drag, a menu): look again after another grace period.
    retry,
    /// Contract to the rail.
    close,
};

/// What the grace timer decides when it fires (Mac `scheduleClose`): never
/// contract out from under the pointer or a held press, and keep trying
/// while only the hold is what keeps it.
pub fn closeVerdict(pointer_on_card: bool, held: bool) CloseVerdict {
    if (pointer_on_card) return .stay;
    if (held) return .retry;
    return .close;
}

/// What `toggle pin` does to the open card. Pinning closes it (the panel
/// replaces it). Unpinning OPENS it: the pin was just clicked, so the pointer
/// is on it, and Mac leaves the card open until the pointer leaves
/// (`setPaneSidebarPinned`: `isHoverOpen = !pinned`).
pub fn openAfterPinToggle(now_pinned: bool) bool {
    return !now_pinned;
}

// ---------------------------------------------------------------------------
// Z-order: where the open card goes among the window's own popups

/// One window in the run directly above the sidebar's top-level window,
/// nearest first (`GetWindow(.., GW_HWNDPREV)` from the root).
pub const ZStep = struct {
    /// The card itself.
    is_self: bool = false,
    /// Owned by the same top-level window: a pane's banner strip, dim
    /// overlay, scrollbar, badge. The card must go ABOVE these - it opens
    /// over the grid, and a dimmed or bannered pane under it must not paint
    /// through it.
    is_sibling: bool = false,
    is_visible: bool = true,
};

/// The index in `above` the card is inserted AFTER (i.e. placed directly
/// below), or null for the top of the band. That is the first visible window
/// above the root that is not one of the root's own popups: the card lands
/// above all of its siblings and below everything that is not this window's,
/// so a card opened on a background window never floats over another app
/// (the T142 shape `overlay_zorder.zig` describes).
pub fn seatAfter(above: []const ZStep) ?usize {
    for (above, 0..) |s, i| {
        if (s.is_self or s.is_sibling or !s.is_visible) continue;
        return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tooltips (Mac `.help`)

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

/// The pin (Mac's wording; an em dash, as Mac writes it).
pub fn pinTip(pinned: bool) []const u8 {
    return if (pinned) "Unpin \u{2014} collapse to icons" else "Pin \u{2014} keep the sidebar open";
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

test "pane_sidebar_hover: Mac's timing" {
    try testing.expectEqual(@as(u32, 100), open_delay_ms);
    try testing.expectEqual(@as(u32, 280), close_delay_ms);
}

test "pane_sidebar_hover: only the rail's card opens, and only once" {
    try testing.expect(opensOnTimer(.mini, false, true));
    // The pointer left before the delay ran out.
    try testing.expect(!opensOnTimer(.mini, false, false));
    // Already open.
    try testing.expect(!opensOnTimer(.mini, true, true));
    // Pinned (or pinned while the timer ran) and hidden never open a card.
    try testing.expect(!opensOnTimer(.expanded, false, true));
    try testing.expect(!opensOnTimer(.hidden, false, true));
}

test "pane_sidebar_hover: the grace timer never contracts under the pointer or a held press" {
    try testing.expectEqual(CloseVerdict.stay, closeVerdict(true, false));
    try testing.expectEqual(CloseVerdict.stay, closeVerdict(true, true));
    try testing.expectEqual(CloseVerdict.retry, closeVerdict(false, true));
    try testing.expectEqual(CloseVerdict.close, closeVerdict(false, false));
}

test "pane_sidebar_hover: unpinning leaves the card open, pinning closes it" {
    try testing.expect(openAfterPinToggle(false));
    try testing.expect(!openAfterPinToggle(true));
}

test "pane_sidebar_hover: the card seats above its siblings and below the first foreign window" {
    // Nothing above the root: top of the band.
    try testing.expectEqual(@as(?usize, null), seatAfter(&.{}));
    // Banner + dim overlay of this window, then another app's window.
    try testing.expectEqual(@as(?usize, 2), seatAfter(&.{
        .{ .is_sibling = true },
        .{ .is_sibling = true },
        .{},
    }));
    // The card itself and a hidden foreign window are passed over.
    try testing.expectEqual(@as(?usize, 3), seatAfter(&.{
        .{ .is_self = true },
        .{ .is_visible = false },
        .{ .is_sibling = true },
        .{},
    }));
    // Only siblings: the top.
    try testing.expectEqual(@as(?usize, null), seatAfter(&.{ .{ .is_sibling = true }, .{ .is_self = true } }));
}

test "pane_sidebar_hover: tooltip wording" {
    try testing.expectEqualStrings("Click to focus", rowHint(.grid));
    try testing.expectEqualStrings("Click to restore", rowHint(.stashed));
    try testing.expect(std.mem.startsWith(u8, stashed_row_tip, rowHint(.stashed)));
    try testing.expect(std.mem.indexOf(u8, stashed_row_tip, "Alt-click to swap") != null);
    try testing.expectEqualStrings("Stash", buttonTip(.grid));
    try testing.expectEqualStrings("Restore", buttonTip(.stashed));
    try testing.expect(std.mem.startsWith(u8, pinTip(true), "Unpin"));
    try testing.expect(std.mem.startsWith(u8, pinTip(false), "Pin"));
}

test "pane_sidebar_hover: a tile's tip is its title, then the hint" {
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

test "pane_sidebar_hover: a long title is cut with an ellipsis, keeping the hint and the terminator" {
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
