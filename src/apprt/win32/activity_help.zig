//! What the Activity Monitor's control bar SAYS when the pointer rests on it
//! (T1634) — the win32 half of the `.help()` modifiers on Mac's
//! `RemoteActivityMonitorView.swift` control bar (:990-1066), word for word.
//!
//! Those are the rows a reader is most likely to mistrust: the "List truncated"
//! badge, the "Show all" filter, the process count, plus the Kill and New
//! Process buttons beside them. Without the words a truncated table and a
//! filtered count read as plain facts. This module is the part of the fix that
//! needs no window: which surface is hovered (`Target`) and the sentence it
//! answers with. The comctl32 plumbing is `help_tooltip.zig` (shared with the
//! machine chooser) and the hit tests are `activity_hover.zig`, so everything
//! here runs in the `none` lane.
//!
//! Mac surfaces with NO string here, on purpose:
//!
//! - the "% CPU unverified" label (:1004-1009) — the win32 panel does not mark
//!   an unverifiable CPU column at all yet. That is T1549, and when it lands its
//!   label takes `cpu_unverified_detail` below through this same plumbing;
//! - the "Refresh failed" badge — Mac gives it no `.help()` either;
//! - the PID and Memory cells — none on Mac;
//! - the %CPU cell — Mac's says `cpuUnverifiedDetail` only while the agent's
//!   CPU units are untrusted and nothing otherwise, and the win32 panel does
//!   not know "untrusted" yet (T1549 above), so today it is the trusted case.
//!
//! The process table's Name, Window / Pane and Path cells (:1082-1142) carry
//! their tips since T1548; they are painted surfaces like the badge and count,
//! keyed on the row's PID as well as the column (`activity_hover.zig`).

const std = @import("std");
const rows_mod = @import("activity_rows.zig");

/// The longest string any of these can produce, for the caller's buffer. The
/// control bar's variable parts are a process name and a machine label, both
/// short; the table's are a full executable path and a pane's multi-line
/// detail (`activity_panes.max_detail`, 768), which set this size. A longer
/// path is clipped on a code point.
pub const max_len: usize = 1024;

/// The control-bar surface under the pointer. One value names ONE tooltip.
pub const Target = enum {
    /// The status badge, while it says "List truncated". Painted.
    badge,
    /// The "N of M" / "N processes" count. Painted.
    count,
    /// The "Show all" checkbox. A real control.
    show_all,
    /// "Kill" / "Kill N", present while rows are selected. A real control.
    kill,
    /// "New Process". A real control.
    new_process,
    /// A process row's Name cell (T1548). Painted; one per row, so the
    /// panel keys it on the row's PID too.
    name_cell,
    /// A process row's Window / Pane cell (T1548). Painted, per row.
    pane_cell,
    /// A process row's Path cell (T1548). Painted, per row.
    path_cell,

    /// Whether a real child CONTROL carries this surface. A control's tip is
    /// shown by comctl32 itself; every other surface is painted, and the panel
    /// shows its tip by hand.
    pub fn isControl(self: Target) bool {
        return switch (self) {
            .show_all, .kill, .new_process => true,
            .badge, .count, .name_cell, .pane_cell, .path_cell => false,
        };
    }

    /// Whether this surface is a process-table cell, one per row.
    pub fn isCell(self: Target) bool {
        return switch (self) {
            .name_cell, .pane_cell, .path_cell => true,
            else => false,
        };
    }

    /// The stable name the debug oracle prints (`target=<kind>`).
    pub fn kind(self: Target) []const u8 {
        return switch (self) {
            .badge => "badge",
            .count => "count",
            .show_all => "show-all",
            .kill => "kill",
            .new_process => "new-process",
            .name_cell => "name",
            .pane_cell => "pane",
            .path_cell => "path",
        };
    }
};

/// The Window / Pane cell of a row no Ghoztty pane started. Mac `:1129`.
pub const not_a_pane = "Not started by a Ghoztty pane.";

/// The Name cell: the full command line when the agent sent one, else the name
/// itself — Mac `:1088`, `row.cmd.isEmpty ? row.name : row.cmd`. Null when
/// both are empty (the cell shows a dash, and Mac's empty `.help` shows
/// nothing). A command past the buffer is clipped on a code point.
pub fn nameCell(buf: []u8, name: []const u8, cmd: []const u8) ?[]const u8 {
    const s = if (cmd.len > 0) cmd else name;
    if (s.len == 0) return null;
    return clipCopy(buf, s);
}

/// The Path cell: the whole path, or nothing when there is none — Mac `:1142`.
pub fn pathCell(buf: []u8, cmd: []const u8) ?[]const u8 {
    if (cmd.len == 0) return null;
    return clipCopy(buf, cmd);
}

/// The Window / Pane cell: the pane's detail (`activity_panes.paneDetail`),
/// or Mac's sentence for a row no pane owns — Mac `:1129`,
/// `pane?.detail ?? "Not started by a Ghoztty pane."`. A row with a label and
/// somehow no detail falls back to the label rather than to the sentence,
/// which would contradict the cell.
pub fn paneCell(label: []const u8, detail: []const u8) []const u8 {
    if (label.len == 0) return not_a_pane;
    if (detail.len > 0) return detail;
    return label;
}

/// `s` with each newline written as the two characters `\n`, for the debug
/// oracle: a log line must stay one line for the acceptance script to read the
/// pane detail back whole. Cut on a code point when it does not fit.
pub fn oneLine(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n') {
            if (n + 2 > buf.len) break;
            buf[n] = '\\';
            buf[n + 1] = 'n';
            n += 2;
            i += 1;
            continue;
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const take = @min(cp_len, s.len - i);
        if (n + take > buf.len) break;
        @memcpy(buf[n .. n + take], s[i .. i + take]);
        n += take;
        i += take;
    }
    return buf[0..n];
}

/// `s` copied into `buf`, cut on a code point when it does not fit.
fn clipCopy(buf: []u8, s: []const u8) []const u8 {
    var n = @min(s.len, buf.len);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// The truncated-list badge. Mac `:1002`.
pub const truncated = "The agent capped the process table; some rows are not shown.";

/// The explanation T1549's "% CPU unverified" label will carry. Mac's
/// `cpuUnverifiedDetail` (:1211-1216), kept here so both halves of that task
/// read the one string, as Mac's header tooltip and control-bar label do.
pub const cpu_unverified_detail =
    "This machine's agent is older than the CPU-units fix, so it may report " ++
    "per-process CPU up to ~24\u{00D7} low (on Apple Silicon; correct on Intel \u{2014} " ++
    "there is no way to tell from here). Relative ordering is still valid. " ++
    "Update the agent on that machine for real numbers.";

/// The badge's tip, or null when the badge says nothing that has one. Mirrors
/// `activity_actions.badgeText`'s precedence exactly: when a failed refresh is
/// what the badge SHOWS, the truncation sentence would describe words that are
/// not on screen, so there is no tip.
pub fn badge(refresh_failed: bool, is_truncated: bool, total_rows: usize) ?[]const u8 {
    if (refresh_failed and total_rows > 0) return null;
    if (is_truncated) return truncated;
    return null;
}

/// Whether the spawned-only filter can mean anything for this source — Mac's
/// `canFilterSpawned` (:751-753): a known root, or at least one row attributed
/// to a pane.
pub fn canFilterSpawned(f: rows_mod.Filter) bool {
    return f.root_pid != 0 or f.any_attributed;
}

/// "Show all". Mac `:1022-1024`.
pub fn showAll(f: rows_mod.Filter) []const u8 {
    return if (canFilterSpawned(f))
        "When off, show only processes Ghoztty started (the agent and its descendants)."
    else
        "This agent pre-dates spawned-process filtering, so all processes are shown.";
}

/// The count label. Mac `countLabel`'s help (:1068-1070): the full sentence
/// while the spawned-only restriction is in force, else the label's own words.
/// Keyed on the restriction alone, as Mac's is — the label itself also looks at
/// the search box, the tip does not.
pub fn count(buf: []u8, f: rows_mod.Filter, shown: usize, total: usize) []const u8 {
    if (rows_mod.spawnedOnlyActive(f)) {
        return std.fmt.bufPrint(
            buf,
            "Showing {d} Ghoztty-spawned of {d} total processes.",
            .{ shown, total },
        ) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d} processes", .{shown}) catch buf[0..0];
}

/// The Kill button. Mac `:1040-1042`: one row names its process ("PID <n>"
/// when the row has no name), several are counted. Null with nothing selected —
/// the button is hidden then.
pub fn kill(buf: []u8, selected: usize, first_pid: i64, first_name: []const u8) ?[]const u8 {
    if (selected == 0) return null;
    if (selected == 1) {
        if (first_name.len == 0) {
            return std.fmt.bufPrint(buf, "Terminate PID {d}", .{first_pid}) catch buf[0..0];
        }
        return clipped(buf, "Terminate {s}", first_name);
    }
    return std.fmt.bufPrint(buf, "Terminate {d} selected processes", .{selected}) catch buf[0..0];
}

/// "New Process". Mac `:1050`, `"Start a new process on \(model.source.label)"`.
pub fn newProcess(buf: []u8, machine: []const u8) []const u8 {
    return clipped(buf, "Start a new process on {s}", machine);
}

/// Whether `x` falls on the text actually drawn in `slot`, given the text's
/// measured width and which edge it is drawn against. The badge and count
/// slots are wider than their words; a tip that answers over empty slack reads
/// as a tip about nothing. The text is clamped to the slot, since DrawText
/// ellipsizes an overlong badge rather than overflowing it.
pub fn textHit(left: i32, right: i32, text_w: i32, right_aligned: bool, x: i32, y_in: bool) bool {
    if (!y_in or text_w <= 0 or right <= left) return false;
    const w = @min(text_w, right - left);
    const lo = if (right_aligned) right - w else left;
    return x >= lo and x < lo + w;
}

/// `fmt` with one string argument, the argument clipped (at a UTF-8 boundary)
/// so the sentence always fits `buf` and never ends in half a code point.
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

test "badge: the truncation sentence is Mac's words" {
    try testing.expectEqualStrings(
        "The agent capped the process table; some rows are not shown.",
        badge(false, true, 512).?,
    );
}

test "badge: no tip when the badge is not saying 'List truncated'" {
    // Nothing to say.
    try testing.expect(badge(false, false, 10) == null);
    // A failed refresh with rows on screen is what the badge shows instead.
    try testing.expect(badge(true, true, 10) == null);
    try testing.expect(badge(true, false, 10) == null);
    // A failed refresh with NO rows shows no "Refresh failed" badge, so a
    // truncated flag is what is on screen again.
    try testing.expectEqualStrings(truncated, badge(true, true, 0).?);
}

test "showAll: both of Mac's sentences, keyed on canFilterSpawned" {
    try testing.expectEqualStrings(
        "When off, show only processes Ghoztty started (the agent and its descendants).",
        showAll(.{ .root_pid = 42 }),
    );
    try testing.expectEqualStrings(
        "When off, show only processes Ghoztty started (the agent and its descendants).",
        showAll(.{ .any_attributed = true }),
    );
    try testing.expectEqualStrings(
        "This agent pre-dates spawned-process filtering, so all processes are shown.",
        showAll(.{}),
    );
}

test "count: the spawned-only sentence, and the plain count otherwise" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings(
        "Showing 3 Ghoztty-spawned of 212 total processes.",
        count(&buf, .{ .root_pid = 7 }, 3, 212),
    );
    // Show all on: the restriction is off.
    try testing.expectEqualStrings("212 processes", count(&buf, .{ .root_pid = 7, .show_all = true }, 212, 212));
    // No root and nothing attributed: the restriction cannot apply.
    try testing.expectEqualStrings("40 processes", count(&buf, .{}, 40, 212));
    // A search narrows the label to "N processes" but, as on Mac, not the tip.
    try testing.expectEqualStrings(
        "Showing 1 Ghoztty-spawned of 212 total processes.",
        count(&buf, .{ .root_pid = 7, .needle = "zsh" }, 1, 212),
    );
}

test "kill: names one process, falls back to its pid, counts several" {
    var buf: [max_len]u8 = undefined;
    try testing.expect(kill(&buf, 0, 0, "") == null);
    try testing.expectEqualStrings("Terminate pwsh.exe", kill(&buf, 1, 4242, "pwsh.exe").?);
    try testing.expectEqualStrings("Terminate PID 4242", kill(&buf, 1, 4242, "").?);
    try testing.expectEqualStrings("Terminate 3 selected processes", kill(&buf, 3, 1, "x").?);
}

test "newProcess names the machine" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("Start a new process on Local", newProcess(&buf, "Local"));
    try testing.expectEqualStrings("Start a new process on Warmbox", newProcess(&buf, "Warmbox"));
}

test "a long name is clipped to fit, never split mid code point" {
    var small: [30]u8 = undefined;
    // "Terminate " is 10 bytes; 20 are left for the name.
    const t = kill(&small, 1, 1, "abcdefghijklmnopqrs\u{00e9}zzz").?;
    try testing.expect(t.len <= small.len);
    try testing.expect(std.unicode.utf8ValidateSlice(t));
    try testing.expect(std.mem.startsWith(u8, t, "Terminate abcdefghijklmnopqrs"));
}

test "cpu_unverified_detail is Mac's sentence" {
    try testing.expect(std.mem.startsWith(u8, cpu_unverified_detail, "This machine's agent is older than the CPU-units fix"));
    try testing.expect(std.mem.endsWith(u8, cpu_unverified_detail, "Update the agent on that machine for real numbers."));
    try testing.expect(std.unicode.utf8ValidateSlice(cpu_unverified_detail));
    try testing.expect(cpu_unverified_detail.len <= max_len);
}

test "textHit: only the drawn words answer, on the edge they are drawn against" {
    // A 100-wide slot at 10..110 holding 40 px of text.
    try testing.expect(textHit(10, 110, 40, false, 10, true));
    try testing.expect(textHit(10, 110, 40, false, 49, true));
    try testing.expect(!textHit(10, 110, 40, false, 50, true));
    try testing.expect(!textHit(10, 110, 40, false, 9, true));
    // Right-aligned: the words sit at 70..110.
    try testing.expect(!textHit(10, 110, 40, true, 69, true));
    try testing.expect(textHit(10, 110, 40, true, 70, true));
    try testing.expect(textHit(10, 110, 40, true, 109, true));
    try testing.expect(!textHit(10, 110, 40, true, 110, true));
    // An ellipsized badge is clamped to the slot.
    try testing.expect(textHit(10, 110, 400, false, 109, true));
    try testing.expect(!textHit(10, 110, 400, false, 110, true));
    // Off the row, no text, or no slot: nothing.
    try testing.expect(!textHit(10, 110, 40, false, 20, false));
    try testing.expect(!textHit(10, 110, 0, false, 10, true));
    try testing.expect(!textHit(10, 10, 40, false, 10, true));
}

test "Target: only the real child controls are shown by comctl32" {
    try testing.expect((Target.show_all).isControl());
    try testing.expect((Target.kill).isControl());
    try testing.expect((Target.new_process).isControl());
    try testing.expect(!(Target.badge).isControl());
    try testing.expect(!(Target.count).isControl());
    try testing.expectEqualStrings("new-process", Target.new_process.kind());
    try testing.expectEqualStrings("show-all", Target.show_all.kind());
}

test "nameCell: the command when there is one, else the name (Mac :1088)" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings(
        "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        nameCell(&buf, "pwsh.exe", "C:\\Program Files\\PowerShell\\7\\pwsh.exe").?,
    );
    try testing.expectEqualStrings("System", nameCell(&buf, "System", "").?);
    // Both empty: the cell shows a dash and says nothing.
    try testing.expect(nameCell(&buf, "", "") == null);
}

test "pathCell: the whole path, or nothing (Mac :1142)" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("D:\\git\\ghoztty\\zig-out\\bin\\ghoztty.exe", pathCell(&buf, "D:\\git\\ghoztty\\zig-out\\bin\\ghoztty.exe").?);
    try testing.expect(pathCell(&buf, "") == null);
}

test "a path past the buffer is clipped on a code point" {
    var small: [10]u8 = undefined;
    const t = pathCell(&small, "C:\\abcdef\u{00e9}gh").?;
    try testing.expectEqualStrings("C:\\abcdef", t);
    try testing.expect(std.unicode.utf8ValidateSlice(t));
}

test "paneCell: the detail, Mac's sentence for no pane, the label as a last resort" {
    try testing.expectEqualStrings("Window: a\nShell PID: 1", paneCell("a", "Window: a\nShell PID: 1"));
    try testing.expectEqualStrings("Not started by a Ghoztty pane.", paneCell("", ""));
    // Never the "not started" sentence over a cell that names a pane.
    try testing.expectEqualStrings("a", paneCell("a", ""));
}

test "oneLine: newlines become a literal \\n, everything else is kept" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Window: a\\nPane: \u{203A}x", oneLine(&buf, "Window: a\nPane: \u{203A}x"));
    // Never half an escape or half a code point at the cut.
    var small: [3]u8 = undefined;
    try testing.expectEqualStrings("abc", oneLine(&small, "abc\nd"));
    try testing.expectEqualStrings("a", oneLine(&small, "a\u{203A}"));
}

test "Target: the table cells are painted, per-row surfaces" {
    try testing.expect(!(Target.name_cell).isControl());
    try testing.expect((Target.name_cell).isCell());
    try testing.expect((Target.pane_cell).isCell());
    try testing.expect((Target.path_cell).isCell());
    try testing.expect(!(Target.count).isCell());
    try testing.expectEqualStrings("pane", Target.pane_cell.kind());
}
