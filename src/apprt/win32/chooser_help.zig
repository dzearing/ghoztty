//! What every surface of the machine chooser SAYS when the pointer rests on it
//! (T1633) — the win32 half of the `.help()` modifiers on Mac's
//! `MachineChooserView.swift`, word for word.
//!
//! T812 gave the CPU meter a native hover tooltip; every other control in the
//! chooser stayed silent. This module is the part of the fix that needs no
//! window: which surface is hovered (`Target`) and the sentence it answers
//! with. The comctl32 plumbing lives in `chooser_tooltip.zig` and the hit tests
//! in `MachineChooser.zig`, so everything here runs in the `none` lane.
//!
//! Mac surfaces with NO Windows counterpart get no string here, on purpose — a
//! sentence for a control that does not exist is dead text nobody can test by
//! use (T1633 records each as n/a with its reason):
//!
//! - the machine row's session-count capsule (`countBadge`) — the win32 rows
//!   carry no count badge;
//! - a session row's "Show" / "Resume" buttons — a win32 session card IS the
//!   resume affordance (double-click / Return), it has no per-row button.

const std = @import("std");
const chooser_session_sort = @import("chooser_session_sort.zig");
const chooser_rows = @import("chooser_rows.zig");

/// The longest string any of these can produce, for the caller's buffer. The
/// variable part is a machine name or an email; both are clipped by the
/// callers' own caps well under this.
pub const max_len: usize = 320;

/// The surface under the pointer. One value names ONE tooltip, so "did the
/// pointer move to something else" is `eql`, and a per-row surface carries its
/// row so moving to the same control on the next card is a change.
pub const Target = union(enum) {
    /// A roster row's CPU meter (T812). Index into the DISPLAYED rows.
    cpu: usize,
    /// A roster row's End ("x") button. Index into the displayed rows.
    end_session: usize,
    /// A session-list column header (T602).
    sort_header: chooser_session_sort.Key,
    /// The detail pane's primary action.
    new_window,
    /// "Restore All" (T335).
    restore_all,
    /// "Activity" (T177).
    activity,
    /// The management "..." button (T176).
    manage,
    /// The signed-in account's email and monogram.
    account,
    /// A machine row's status dot. Index into the machine LIST.
    machine_status: usize,

    pub fn eql(a: Target, b: Target) bool {
        return std.meta.eql(a, b);
    }

    /// Whether a real child CONTROL carries this surface. A control's tip is
    /// shown by comctl32 itself (it can see the pointer leave the control);
    /// every other surface is painted, and the dialog shows its tip by hand.
    pub fn isControl(self: Target) bool {
        return switch (self) {
            .new_window, .restore_all, .activity, .manage => true,
            .cpu, .end_session, .sort_header, .account, .machine_status => false,
        };
    }

    /// The stable name the debug oracle prints (`target=<kind>`).
    pub fn kind(self: Target) []const u8 {
        return switch (self) {
            .cpu => "cpu",
            .end_session => "end-session",
            .sort_header => "sort-header",
            .new_window => "new-window",
            .restore_all => "restore-all",
            .activity => "activity",
            .manage => "manage",
            .account => "account",
            .machine_status => "machine-status",
        };
    }

    /// `kind` plus the detail that tells two of one kind apart - the row, or
    /// the column - as one log token run: `end-session row=2`,
    /// `sort-header key=cpu`, `new-window`.
    pub fn describe(self: Target, buf: []u8) []const u8 {
        return switch (self) {
            .cpu, .end_session, .machine_status => |i| std.fmt.bufPrint(
                buf,
                "{s} row={d}",
                .{ self.kind(), i },
            ) catch self.kind(),
            .sort_header => |k| std.fmt.bufPrint(
                buf,
                "{s} key={s}",
                .{ self.kind(), @tagName(k) },
            ) catch self.kind(),
            else => self.kind(),
        };
    }
};

/// A session row's End button. Mac `MachineChooserView.swift:905`.
pub const end_session = "End this session (terminates its process)";

/// "Restore All". Mac `MachineChooserView.swift:560`.
pub const restore_all = "Rebuild this machine's full window layout here";

/// The primary action. Mac `:552`, `"Open a new window on \(detailTitle)"` —
/// `machine` is the detail pane's title for the selected row ("This PC" for
/// the local machine, the device's name otherwise).
pub fn newWindow(buf: []u8, machine: []const u8) []const u8 {
    return clipped(buf, "Open a new window on {s}", machine);
}

/// "Activity". Mac `:801`, `"Open Activity Monitor for \(name)"`.
pub fn activity(buf: []u8, machine: []const u8) []const u8 {
    return clipped(buf, "Open Activity Monitor for {s}", machine);
}

/// The management "..." button. Mac `:588`, `"Manage \(machine.name)"`.
pub fn manage(buf: []u8, machine: []const u8) []const u8 {
    return clipped(buf, "Manage {s}", machine);
}

/// The signed-in account. Mac `:1284`, `"Signed in as \(email)"`.
pub fn signedIn(buf: []u8, email: []const u8) []const u8 {
    return clipped(buf, "Signed in as {s}", email);
}

/// A column header. Mac's `sessionSortHelp` (`:769`): what clicking it will do,
/// or - on the column the list is already sorted by - what it is doing now.
/// The column is named in lower case, exactly as Mac lowercases `columnTitle`.
pub fn sortHeader(
    buf: []u8,
    order: chooser_session_sort.Order,
    key: chooser_session_sort.Key,
) []const u8 {
    var lower: [32]u8 = undefined;
    const title = key.columnTitle();
    const n = @min(title.len, lower.len);
    const column = std.ascii.lowerString(lower[0..n], title[0..n]);
    if (order.key != key) {
        return std.fmt.bufPrint(buf, "Sort by {s}", .{column}) catch buf[0..0];
    }
    return std.fmt.bufPrint(
        buf,
        "Sorted by {s}, {s} \u{2014} click to reverse",
        .{ column, if (order.ascending) "ascending" else "descending" },
    ) catch buf[0..0];
}

/// A machine row's status dot. Mac's `statusText(for:)` (`:1475`), which is the
/// same three words the win32 detail pane already uses for presence.
pub fn machineStatus(presence: chooser_rows.Presence) []const u8 {
    return presence.label();
}

/// Whether a point `x` pixels from a machine row's left edge is on the row's
/// STATUS column. The hit box is the reserved column plus the pill's leading
/// padding before it: the dot is 8 DIP, and a tip that only answers on those
/// eight pixels reads as flicker (the T812 meter rule). It never reaches the
/// machine glyph's column, which is the row's own and would make the whole
/// leading edge of every row a status tooltip.
pub fn statusColumnHit(m: chooser_rows.RowMetrics, x: i32) bool {
    const right = m.status_cx + @divTrunc(m.status_col_w, 2);
    return x >= m.fill_inset_x and x < right;
}

/// `text` with every newline written as a literal backslash-n, into `out`, so a
/// debug oracle line about a two-line tip (the throttled CPU tip) stays ONE line
/// a grep cannot split. `out.len >= 2 * text.len` is the caller's contract;
/// anything past it is dropped rather than overrun.
pub fn escapeNewlines(out: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    for (text) |c| {
        if (c == '\n') {
            if (n + 2 > out.len) break;
            out[n] = '\\';
            out[n + 1] = 'n';
            n += 2;
        } else {
            if (n + 1 > out.len) break;
            out[n] = c;
            n += 1;
        }
    }
    return out[0..n];
}

/// `fmt` with one string argument, the argument clipped (at a UTF-8 boundary)
/// so the sentence always fits `buf` and never ends in half a code point. A
/// clipped name still says what the control does; an empty string would show
/// no tooltip at all.
fn clipped(buf: []u8, comptime fmt: []const u8, arg: []const u8) []const u8 {
    const fixed = comptime fmt.len - 3; // "{s}"
    if (buf.len <= fixed) return buf[0..0];
    var take = @min(arg.len, buf.len - fixed);
    while (take > 0 and take < arg.len and (arg[take] & 0xC0) == 0x80) take -= 1;
    return std.fmt.bufPrint(buf, fmt, .{arg[0..take]}) catch buf[0..0];
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "newWindow names the selected machine the way the detail pane does" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("Open a new window on This PC", newWindow(&buf, "This PC"));
    try testing.expectEqualStrings("Open a new window on Warmbox", newWindow(&buf, "Warmbox"));
}

test "restore_all and end_session are Mac's words" {
    try testing.expectEqualStrings("Rebuild this machine's full window layout here", restore_all);
    try testing.expectEqualStrings("End this session (terminates its process)", end_session);
}

test "activity and manage name the machine" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("Open Activity Monitor for Warmbox", activity(&buf, "Warmbox"));
    try testing.expectEqualStrings("Manage Warmbox", manage(&buf, "Warmbox"));
}

test "signedIn names the account" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("Signed in as e2e@example.com", signedIn(&buf, "e2e@example.com"));
}

test "sortHeader: an inactive column says what a click will do, in lower case" {
    var buf: [max_len]u8 = undefined;
    const by_name: chooser_session_sort.Order = .{ .key = .name, .ascending = true };
    try testing.expectEqualStrings("Sort by cpu", sortHeader(&buf, by_name, .cpu));
    const by_cpu: chooser_session_sort.Order = .{ .key = .cpu, .ascending = false };
    try testing.expectEqualStrings("Sort by name", sortHeader(&buf, by_cpu, .name));
}

test "sortHeader: the active column says its direction, both ways, for both keys" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings(
        "Sorted by name, ascending \u{2014} click to reverse",
        sortHeader(&buf, .{ .key = .name, .ascending = true }, .name),
    );
    try testing.expectEqualStrings(
        "Sorted by name, descending \u{2014} click to reverse",
        sortHeader(&buf, .{ .key = .name, .ascending = false }, .name),
    );
    try testing.expectEqualStrings(
        "Sorted by cpu, descending \u{2014} click to reverse",
        sortHeader(&buf, .{ .key = .cpu, .ascending = false }, .cpu),
    );
    try testing.expectEqualStrings(
        "Sorted by cpu, ascending \u{2014} click to reverse",
        sortHeader(&buf, .{ .key = .cpu, .ascending = true }, .cpu),
    );
}

test "machineStatus is Mac's statusText for all three presences" {
    try testing.expectEqualStrings("Online", machineStatus(.online));
    try testing.expectEqualStrings("Offline", machineStatus(.offline));
    try testing.expectEqualStrings("Checking status", machineStatus(.checking));
}

test "a long name is clipped to fit, never split mid code point" {
    var small: [30]u8 = undefined;
    // "Manage " is 7 bytes; 23 are left for the name.
    const t = manage(&small, "abcdefghijklmnopqrstuv\u{00e9}zzz");
    try testing.expect(t.len <= small.len);
    try testing.expect(std.unicode.utf8ValidateSlice(t));
    try testing.expect(std.mem.startsWith(u8, t, "Manage abcdefghijklmnopqrstuv"));
    // A buffer too small for even the fixed words answers empty, not garbage.
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("", manage(&tiny, "x"));
}

test "Target: a per-row surface on another row is a different tooltip" {
    const a: Target = .{ .end_session = 0 };
    try testing.expect(a.eql(.{ .end_session = 0 }));
    try testing.expect(!a.eql(.{ .end_session = 1 }));
    try testing.expect(!a.eql(.{ .cpu = 0 }));
    try testing.expect((Target{ .sort_header = .cpu }).eql(.{ .sort_header = .cpu }));
    try testing.expect(!(Target{ .sort_header = .cpu }).eql(.{ .sort_header = .name }));
}

test "Target: only the real child controls are shown by comctl32" {
    try testing.expect((Target{ .new_window = {} }).isControl());
    try testing.expect((Target{ .restore_all = {} }).isControl());
    try testing.expect((Target{ .activity = {} }).isControl());
    try testing.expect((Target{ .manage = {} }).isControl());
    try testing.expect(!(Target{ .cpu = 0 }).isControl());
    try testing.expect(!(Target{ .end_session = 0 }).isControl());
    try testing.expect(!(Target{ .sort_header = .name }).isControl());
    try testing.expect(!(Target{ .account = {} }).isControl());
    try testing.expect(!(Target{ .machine_status = 1 }).isControl());
}

test "Target.describe is the oracle's one-token-run spelling" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("end-session row=2", (Target{ .end_session = 2 }).describe(&buf));
    try testing.expectEqualStrings("sort-header key=cpu", (Target{ .sort_header = .cpu }).describe(&buf));
    try testing.expectEqualStrings("machine-status row=1", (Target{ .machine_status = 1 }).describe(&buf));
    try testing.expectEqualStrings("new-window", (Target{ .new_window = {} }).describe(&buf));
    try testing.expectEqualStrings("account", (Target{ .account = {} }).describe(&buf));
}

test "escapeNewlines keeps a two-line tip on one oracle line, and never overruns" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("a\\nb", escapeNewlines(&out, "a\nb"));
    try testing.expectEqualStrings("plain", escapeNewlines(&out, "plain"));
    var tiny: [3]u8 = undefined;
    // "a" and one escape pair fit; the second pair would overrun, so it stops.
    try testing.expectEqualStrings("a\\n", escapeNewlines(&tiny, "a\n\n"));
}

test "statusColumnHit covers the dot's column and stops before the glyph" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = chooser_rows.rowMetrics(scale);
        // The dot itself.
        try testing.expect(statusColumnHit(m, m.status_cx));
        try testing.expect(statusColumnHit(m, m.status_cx - @divTrunc(m.dot_d, 2)));
        try testing.expect(statusColumnHit(m, m.status_cx + @divTrunc(m.dot_d, 2) - 1));
        // Outside the pill, and on the machine glyph's column: not the status.
        try testing.expect(!statusColumnHit(m, m.fill_inset_x - 1));
        try testing.expect(!statusColumnHit(m, m.glyph_col_x));
        try testing.expect(!statusColumnHit(m, m.glyph_x + @divTrunc(m.glyph_w, 2)));
    }
}
