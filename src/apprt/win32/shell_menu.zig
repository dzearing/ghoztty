//! The "new tab on a chosen shell" menu (T3753, child of T3735): the pure half.
//!
//! Two menus offer it, in the Windows Terminal shape Windows users already
//! know - a list of shells under the new-tab control:
//!
//!   * the tab strip's "+": a right-click on it drops the list down from the
//!     button (a left-click still opens a tab on the default shell at once);
//!   * the window menu's File > New Tab, which becomes a submenu holding the
//!     same list.
//!
//! Both read one catalog - `SettingsWindow.installedShells`, the list Settings
//! > Shell offers (T3750) - and both put the same rows in the same order: the
//! default shell first, labelled with the New Tab chord, a separator, then one
//! row per installed shell. This file holds what can be decided without the
//! OS - the command ids and the label text - so the none lane asserts it; the
//! menus are built in `Window.zig` and the tab is opened by
//! `new_tab_shell.zig`.

const std = @import("std");

/// First command id of a shell row. Clear of every id that can share a popup
/// with these rows: `menu_bar.menuCommandId` (one per `commands.Id`, a few
/// hundred at most) below it, and the tab context menu's 9000s above.
pub const base: usize = 0x1000;

/// Upper bound on the shell rows a menu shows, so the id range is fixed.
pub const max_entries: usize = 32;

/// The first row: a tab on the default shell, the same thing a left-click on
/// "+" or the New Tab chord opens. Naming it after what it opens, rather than
/// repeating the submenu's own "New Tab", is what makes the list read as a
/// choice of shells.
pub const default_label = "&Default Shell";

/// The command id of shell row `index`.
pub fn commandId(index: usize) usize {
    return base + index;
}

/// The shell row a `TrackPopupMenuEx` result names, or null when it is not
/// one of the `count` rows (dismissed, or another item of the same popup).
pub fn indexOf(cmd: usize, count: usize) ?usize {
    if (cmd < base) return null;
    const i = cmd - base;
    return if (i < @min(count, max_entries)) i else null;
}

/// `label` with every `&` doubled, so a distro or shell name holding one shows
/// it instead of underlining the next letter as a mnemonic. Returns the slice
/// of `buf` written; a label longer than `buf` is cut at the buffer, never at
/// half a doubled pair.
pub fn escapeMnemonics(buf: []u8, label: []const u8) []const u8 {
    var n: usize = 0;
    for (label) |c| {
        const need: usize = if (c == '&') 2 else 1;
        if (n + need > buf.len) break;
        buf[n] = c;
        n += 1;
        if (c == '&') {
            buf[n] = '&';
            n += 1;
        }
    }
    return buf[0..n];
}

const testing = std.testing;

test "shell rows: ids round-trip, and nothing outside the range is a row" {
    try testing.expectEqual(@as(?usize, 0), indexOf(commandId(0), 3));
    try testing.expectEqual(@as(?usize, 2), indexOf(commandId(2), 3));
    try testing.expect(indexOf(commandId(3), 3) == null);
    try testing.expect(indexOf(0, 3) == null); // dismissed
    try testing.expect(indexOf(base - 1, 3) == null); // a menu_bar command
    try testing.expect(indexOf(9100, 3) == null); // the tab context menu's colors
    // More rows than the menu offers can never be addressed.
    try testing.expect(indexOf(commandId(max_entries), max_entries + 5) == null);
}

test "shell rows sit clear of the tab context menu's ids" {
    try testing.expect(commandId(max_entries) < 9000);
}

test "escapeMnemonics: an ampersand shows as itself" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("WSL: R&&D", escapeMnemonics(&buf, "WSL: R&D"));
    try testing.expectEqualStrings("cmd.exe", escapeMnemonics(&buf, "cmd.exe"));
    var tiny: [4]u8 = undefined;
    // "a&" + "&" would split the pair at the edge; the pair is dropped whole.
    try testing.expectEqualStrings("abc", escapeMnemonics(&tiny, "abc&d"));
}
