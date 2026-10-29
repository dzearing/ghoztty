//! The pane sidebar's rename in place, as rules (T2339; Mac 379a352ef,
//! a13bf6f43 `PaneSidebarRename` / `PaneSidebarRenameField`).
//!
//! Hovered, a window header, a project header and a terminal pane's row each
//! show a pencil first among their buttons. It turns the name into a field
//! that takes the caret with its text selected. Return or clicking away keeps
//! what was typed, Escape cancels, and an unchanged name pins nothing - a
//! title that was following the shell keeps following it.
//!
//! - **Window**: the field holds the whole title, `<project>: ` included, so
//!   typing `a: foo` moves the window to group `a` as `foo`. Empty goes back
//!   to following the window's own title. A Mac window is a Windows tab, so
//!   the name pinned is the tab's (Change Tab Title) - unless the window
//!   carries a window-wide pin (Change Window Title, `+rename`), which is what
//!   the row shows and so what the field edits.
//! - **Project group**: the field holds the project. Each of its windows is
//!   retitled `<new>: <name>`; empty takes them out of the group, each to its
//!   own `<name>`.
//! - **A rename never moves anything** (T2405; Mac 7e2d0a9da): committing a
//!   window's or a group's - or Change Window Title - pins the all-windows
//!   list as it was shown, so only what the new name asks for moves
//!   (`pane_sidebar_window_order.renamingWindow` / `renamingProject`).
//! - **Terminal pane**: the field sets its title as Change Pane Title does
//!   (`Surface.setUserTitle`), and that name outranks a banner title
//!   (`pane_sidebar.paneLabel`). A viewer is named by its page: no pencil.
//!
//! No OS imports, so this unit-tests in every app-runtime lane; the window
//! half is `PaneSidebar.zig`.

const std = @import("std");

/// What is being renamed.
pub const Kind = enum { window, project, pane };

/// Whether an item of `kind` offers the pencil. `viewer` only matters for a
/// pane: a viewer is named by its page.
pub fn offersPencil(kind: Kind, viewer: bool) bool {
    return switch (kind) {
        .window, .project => true,
        .pane => !viewer,
    };
}

/// The pencil's tooltip (Mac's `.help`).
pub fn tip(kind: Kind) []const u8 {
    return switch (kind) {
        .window => "Rename window",
        .project => "Rename group",
        .pane => "Rename pane",
    };
}

/// What a commit does to the name.
pub const Outcome = union(enum) {
    /// Unchanged: pin nothing.
    keep,
    /// Empty: drop the pin, back to the name the item finds for itself.
    clear,
    /// Pin this name (trimmed; a slice of the typed text).
    set: []const u8,
};

/// The field was committed with `typed`, having opened on `current` (what
/// the item showed). Surrounding spaces are not part of a name.
pub fn decide(typed: []const u8, current: []const u8) Outcome {
    const name = std.mem.trim(u8, typed, " \t");
    if (std.mem.eql(u8, name, std.mem.trim(u8, current, " \t"))) return .keep;
    if (name.len == 0) return .clear;
    return .{ .set = name };
}

/// A project group renamed to `project`: the title one of its windows,
/// called `label` within the group, takes - `<project>: <label>`, or just
/// `<label>` when the group's name was emptied. Written into `buf`; cut short
/// (never mid-character) when it does not fit.
pub fn groupTitle(buf: []u8, project: []const u8, label: []const u8) []const u8 {
    var n: usize = 0;
    const parts = [_][]const u8{ project, ": ", label };
    const from: usize = if (project.len == 0) 2 else 0;
    for (parts[from..]) |part| {
        const take = fitUtf8(part, buf.len - n);
        @memcpy(buf[n .. n + take], part[0..take]);
        n += take;
        if (take < part.len) break;
    }
    return buf[0..n];
}

/// How many leading bytes of `s` fit in `room` without cutting a character.
fn fitUtf8(s: []const u8, room: usize) usize {
    if (s.len <= room) return s.len;
    var n = room;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "T2339: the pencil is offered by windows, groups and terminals - never a viewer" {
    try testing.expect(offersPencil(.window, false));
    try testing.expect(offersPencil(.project, false));
    try testing.expect(offersPencil(.pane, false));
    try testing.expect(!offersPencil(.pane, true));
    // `viewer` means nothing to a header.
    try testing.expect(offersPencil(.window, true));
    try testing.expectEqualStrings("Rename window", tip(.window));
    try testing.expectEqualStrings("Rename group", tip(.project));
    try testing.expectEqualStrings("Rename pane", tip(.pane));
}

test "T2339: an unchanged name pins nothing, empty clears, anything else is pinned trimmed" {
    try testing.expectEqual(Outcome.keep, decide("zsh", "zsh"));
    // Spaces round it are not part of the name, either side.
    try testing.expectEqual(Outcome.keep, decide("  zsh ", "zsh"));
    try testing.expectEqual(Outcome.keep, decide("zsh", " zsh"));
    try testing.expectEqual(Outcome.clear, decide("", "zsh"));
    try testing.expectEqual(Outcome.clear, decide("   ", "zsh"));
    try testing.expectEqualStrings("build", decide(" build ", "zsh").set);
    // A window's whole title: typing a project moves it into that group.
    try testing.expectEqualStrings("a: foo", decide("a: foo", "foo").set);
    // Emptying an item that already shows nothing is unchanged, not a clear.
    try testing.expectEqual(Outcome.keep, decide("", ""));
}

test "T2339: a group rename retitles each window <new>: <name>, and empty ungroups" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("web: main", groupTitle(&buf, "web", "main"));
    try testing.expectEqualStrings("main", groupTitle(&buf, "", "main"));
    // Unicode survives, and a title too long is cut at a character.
    try testing.expectEqualStrings("gh\u{00F6}st: feature-2", groupTitle(&buf, "gh\u{00F6}st", "feature-2"));
    var small: [7]u8 = undefined;
    try testing.expectEqualStrings("ab: \u{00E9}", groupTitle(&small, "ab", "\u{00E9}\u{00E9}\u{00E9}"));
    try testing.expectEqualStrings("abcdefg", groupTitle(&small, "abcdefghij", "x"));
}
