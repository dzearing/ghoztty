//! Which Ghoztty pane a process belongs to, for the activity monitor's
//! "Window / Pane" column (T709; Mac's `PaneAttribution.swift`, ab79f37c4 +
//! 2964c8859).
//!
//! Pure — no OS imports and no GDI, like `activity_rows.zig` beside it — so the
//! interesting cases (an orphaned grandchild, a ppid cycle, a parent the row cap
//! clipped, two panes with the same title) are unit-tested in every app-runtime
//! lane. `activity_view.collectPanes` is the impure half that walks the live
//! window list and feeds this.
//!
//! ## Why the column exists
//!
//! Without it, twenty agent sessions render as twenty identical rows: Claude
//! Code reports its version string ("2.1.220") as its accounting name, so the
//! Name column says the same thing on every one of them and nothing on screen
//! says which pane to go and close. That is the whole point of the panel.
//!
//! ## The Windows seed is the shell pid, not a tty
//!
//! Mac seeds attribution from the controlling terminal because it does not know
//! a pane's shell pid — `+list` reports the FOREGROUND pid, which for an agent
//! session is `claude` and not the shell that owns the subtree. Under ConPTY
//! there is no tty to key on at all, and the app does know the shell pid:
//! `Surface.shellPid` for an app-spawned pane, `termio.Remote.child_pid` for a
//! pane whose shell lives under an agent (local or cross-machine). So the seed
//! here is the pane's shell pid, which is a STRONGER seed than the Mac's: it
//! cannot be lost by a child detaching from its terminal.
//!
//! The second pass is Mac's unchanged. A process with no seed of its own walks
//! up the ppid chain to the nearest already-attributed ancestor, which is what
//! catches the tool subprocesses hanging two and three levels under an agent:
//!
//!     31160 pwsh.exe          <- the pane's shell           seeded
//!       8452 node.exe         <- claude                     propagated
//!         9912 rg.exe         <- a tool call                propagated
//!
//! ## Labels are assigned per GROUP, never one pane at a time
//!
//! A label is only useful if it DISTINGUISHES, and whether a pane's own title
//! distinguishes it depends on what its siblings are called — which cannot be
//! known one pane at a time. Two panes in one tab both titled `~/git` (the
//! common case: the shell reports its cwd as its title) reproduce the exact
//! "twenty identical rows" problem the column exists to solve, so a title earns
//! a place in the label only when it is unique among its siblings, and the rest
//! fall back to a positional `pane N`. That is the 2964c8859 fix, ported.
//!
//! ## The group is a TAB, not a window
//!
//! Mac's grouping unit is the `TerminalController`, which on that platform IS
//! one tab. A win32 `Window` holds up to `MAX_TABS` independent split trees, so
//! grouping by window would restart the positional numbering in every tab and
//! render two different panes as `window-1 › pane 1`. The group is therefore a
//! (window, tab) pair, and a window with more than one tab names the tab in the
//! label — the Windows-native translation, not a Mac mechanism emulated.

const std = @import("std");

const rows_mod = @import("activity_rows.zig");

const Row = rows_mod.Row;

/// The most panes one panel attributes against. Well past what a box with a
/// process table worth opening this panel for has open; a pane beyond it simply
/// does not attribute, which reads as "not one of ours" rather than as a wrong
/// answer.
pub const max_panes: usize = 64;

/// Longest label a pane gets. The column is 180 DIP at its ideal, so anything
/// past this ellipsizes on screen anyway.
pub const max_label: usize = 160;

/// Total label storage the panel reserves. Fixed, like every other buffer in
/// this panel — the attribution runs on the GUI thread inside `rebuild`, which
/// is not a place to be allocating every 1.5 s.
pub const label_arena_bytes: usize = max_panes * max_label;

/// One live pane, as the panel sees it.
pub const Pane = struct {
    /// The pane's shell pid ON THE MACHINE THIS PANEL IS SAMPLING. 0 ⇒ the pane
    /// has no shell yet (or runs no shell at all, like a viewer), and it then
    /// attributes nothing rather than matching pid 0.
    shell_pid: i64 = 0,
    /// Human-readable "which window/pane is this", pointing into the panel's
    /// own label arena — never at a window's transient title buffer.
    label: []const u8 = "",
    /// The multi-line hover detail for the column's tooltip (T1548; Mac's
    /// `AttributedPane.detail`) — see `paneDetail`. Same arena rule as `label`.
    detail: []const u8 = "",
};

/// Longest hover detail a pane gets: four variable lines of at most
/// `max_label` bytes each plus their fixed captions, with room to spare.
pub const max_detail: usize = 4 * max_label + 128;

/// Detail storage the panel reserves, alongside `label_arena_bytes`.
pub const detail_arena_bytes: usize = max_panes * max_detail;

/// The separator between a group and the pane inside it. U+203A, the same
/// single-angle quote Mac uses.
pub const sep = " \u{203A} ";

// ---------------------------------------------------------------------
// Attribution
// ---------------------------------------------------------------------

/// Fill in every row's `pane_label`, returning how many rows got one.
///
/// Two passes, exactly as `PaneAttribution.attribute` runs them: seed from the
/// pane shell pids, then propagate to everything with no seed of its own by
/// walking up the ppid chain. The propagation runs to a fixed point rather than
/// with a per-row memoized walk — the same idiom `rows_mod.markSpawned` uses one
/// file over, for the same reason: this module allocates nothing and the row
/// count is bounded by the sampler's limit.
///
/// Cycle-safe: a row is assigned at most once and never re-reads its own label,
/// so the torn-snapshot case where 500's parent is 600 and 600's is 500 settles
/// instead of spinning the GUI thread.
pub fn attribute(rows: []Row, panes: []const Pane) usize {
    for (rows) |*r| {
        r.pane_label = "";
        r.pane_detail = "";
    }
    if (rows.len == 0 or panes.len == 0) return 0;

    var n: usize = 0;

    // Pass 1 — seed. A pane whose shell is not in this snapshot (it exited, or
    // the row cap clipped it) seeds nothing, and its descendants then attribute
    // through whatever ancestor IS present, or not at all.
    for (rows) |*r| {
        for (panes) |p| {
            if (p.shell_pid == 0 or p.shell_pid != r.pid) continue;
            r.pane_label = p.label;
            r.pane_detail = p.detail;
            n += 1;
            break;
        }
    }
    if (n == 0) return 0;

    // Pass 2 — propagate. Depth-capped as well as fixed-point: a snapshot deep
    // enough to need more than this is one where the answer stopped being
    // interesting long before the GUI thread stopped working for it.
    var depth: usize = 0;
    while (depth < 128) : (depth += 1) {
        var changed = false;
        for (rows) |*r| {
            if (r.pane_label.len > 0) continue;
            if (r.ppid == 0) continue;
            for (rows) |parent| {
                if (parent.pid != r.ppid or parent.pane_label.len == 0) continue;
                r.pane_label = parent.pane_label;
                r.pane_detail = parent.pane_detail;
                n += 1;
                changed = true;
                break;
            }
        }
        if (!changed) break;
    }

    return n;
}

// ---------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------

/// True for the `window-N` handle `App` mints when nobody named the window
/// (Mac's `isAutoMintedName`). It is a unique handle, not a name a human would
/// recognise, so anything real beats it.
pub fn isAutoMintedName(name: []const u8) bool {
    const prefix = "window-";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const suffix = name[prefix.len..];
    if (suffix.len == 0) return false;
    for (suffix) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Trim the whitespace a title may carry before it is judged empty.
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// The trailing component of a Windows path, for the cwd fallback. Handles both
/// separators, and a trailing one, so `D:\git\ghoztty\` reads `ghoztty`.
pub fn baseName(path: []const u8) []const u8 {
    var p = path;
    while (p.len > 0 and (p[p.len - 1] == '\\' or p[p.len - 1] == '/')) p = p[0 .. p.len - 1];
    if (p.len == 0) return "";
    if (std.mem.lastIndexOfAny(u8, p, "\\/")) |i| return p[i + 1 ..];
    return p;
}

/// The most human-identifiable name for a window, mirroring the fallback chain
/// Mac's `windowLabel(for:)` walks: the most intentional name first, degrading
/// to whatever is still distinguishing.
///
/// A user pin (`+rename`, `+new-window --title`) beats the IPC target name,
/// which beats what the tab strip shows, which beats the focused pane's title,
/// which beats its working directory. `window-N` is the last resort precisely
/// because it always exists.
pub fn windowLabel(
    pinned: []const u8,
    ipc_name: []const u8,
    tab_title: []const u8,
    focus_title: []const u8,
    focus_pwd: []const u8,
) []const u8 {
    if (trim(pinned).len > 0) return trim(pinned);
    if (ipc_name.len > 0 and !isAutoMintedName(ipc_name)) return ipc_name;
    if (trim(tab_title).len > 0) return trim(tab_title);
    if (trim(focus_title).len > 0) return trim(focus_title);
    if (baseName(trim(focus_pwd)).len > 0) return baseName(trim(focus_pwd));
    return ipc_name;
}

/// The label for one (window, tab) group. A single-tab window is named by the
/// window alone — the extra segment would say nothing. A multi-tab window names
/// the tab, because the positional `pane N` inside it restarts per tab and two
/// tabs would otherwise render the identical string.
///
/// A tab whose title already IS the window label adds nothing either (the
/// window took its name from that same tab, one line up in `windowLabel`), so it
/// falls back to the position.
pub fn groupLabel(
    buf: []u8,
    window_label: []const u8,
    tab_title: []const u8,
    tab_index: usize,
    tab_count: usize,
) []const u8 {
    if (tab_count <= 1) return fit(buf, window_label);
    const title = trim(tab_title);
    if (title.len > 0 and !std.mem.eql(u8, title, window_label)) {
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ window_label, sep, title }) catch
            fit(buf, window_label);
    }
    return std.fmt.bufPrint(buf, "{s}{s}tab {d}", .{ window_label, sep, tab_index + 1 }) catch
        fit(buf, window_label);
}

/// Whether `titles[index]` actually separates that pane from its siblings — the
/// 2964c8859 rule. A title that is empty, that repeats another pane's, or that
/// merely restates the group label tells the reader nothing.
pub fn titleDistinguishes(
    titles: []const []const u8,
    index: usize,
    group_label: []const u8,
) bool {
    if (index >= titles.len) return false;
    const mine = trim(titles[index]);
    if (mine.len == 0) return false;
    if (std.mem.eql(u8, mine, group_label)) return false;
    for (titles, 0..) |other, i| {
        if (i == index) continue;
        if (std.mem.eql(u8, trim(other), mine)) return false;
    }
    return true;
}

/// One pane's label within its group. A lone pane is named by the group (the
/// group label already identifies it); otherwise its own title when that
/// distinguishes, else its position in split order.
pub fn paneLabel(
    buf: []u8,
    group_label: []const u8,
    pane_title: []const u8,
    index: usize,
    count: usize,
    distinguishing: bool,
) []const u8 {
    if (count <= 1) return fit(buf, group_label);
    if (distinguishing) {
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ group_label, sep, trim(pane_title) }) catch
            fit(buf, group_label);
    }
    return std.fmt.bufPrint(buf, "{s}{s}pane {d}", .{ group_label, sep, index + 1 }) catch
        fit(buf, group_label);
}

/// Copy as much of `text` into `buf` as fits, on a UTF-8 boundary. The labels
/// carry U+203A and may carry any title the user typed, so a byte truncation
/// could leave a partial sequence the painter would draw as a replacement glyph.
pub fn fit(buf: []u8, text: []const u8) []const u8 {
    if (text.len <= buf.len) {
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }
    var n = buf.len;
    // Back off to the start of the last whole code point.
    while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

/// `s` cut to at most `n` bytes on a code-point boundary, without copying.
fn clip(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var k = n;
    while (k > 0 and (s[k] & 0xC0) == 0x80) k -= 1;
    return s[0..k];
}

/// What one pane's identity is, for its hover detail.
pub const DetailInput = struct {
    window_label: []const u8,
    /// The pane's tab, and where it sits. A one-tab window names no tab.
    tab_title: []const u8 = "",
    tab_index: usize = 0,
    tab_count: usize = 1,
    pane_title: []const u8 = "",
    /// The pane's position among its tab's attributing panes, split order.
    index: usize = 0,
    count: usize = 1,
    /// The pane's working directory, full path; the detail shows its last
    /// component, as Mac's does.
    cwd: []const u8 = "",
    shell_pid: i64 = 0,
};

/// The "Window / Pane" cell's hover detail (T1548): Mac's
/// `PaneAttribution` detail lines (`Window:`, `Pane:`, `Pane position:`,
/// `Directory:`, `TTY:`), one per line, translated where the concept differs:
///
/// - **`Shell PID:` stands where `TTY:` does.** ConPTY has no tty name, and the
///   shell pid is what this platform seeds attribution from (the module doc) —
///   the `+list --tty` → `+list --pid` pair again.
/// - **`Tab:` is added for a window holding more than one tab.** Mac's window
///   IS one tab, so its `Window:` line already pins the pane down; a win32
///   window can hold several, and `Pane position: 1 of 2` would then not say
///   which tab's first pane it means.
///
/// Every variable part is clipped to `max_label`, so with `buf` of
/// `max_detail` bytes no line is ever dropped; a smaller buffer keeps the
/// lines that fit, whole.
pub fn paneDetail(buf: []u8, in: DetailInput) []const u8 {
    var len: usize = 0;
    const Line = struct {
        fn add(b: []u8, l: *usize, comptime fmt: []const u8, args: anytype) void {
            const sepn: usize = if (l.* == 0) 0 else 1;
            if (b.len < l.* + sepn) return;
            const room = b[l.* + sepn ..];
            const s = std.fmt.bufPrint(room, fmt, args) catch return;
            if (sepn == 1) b[l.*] = '\n';
            l.* += sepn + s.len;
        }
    };

    Line.add(buf, &len, "Window: {s}", .{clip(trim(in.window_label), max_label)});
    if (in.tab_count > 1) {
        const t = clip(trim(in.tab_title), max_label);
        if (t.len > 0 and !std.mem.eql(u8, t, trim(in.window_label))) {
            Line.add(buf, &len, "Tab: {s} ({d} of {d})", .{ t, in.tab_index + 1, in.tab_count });
        } else {
            Line.add(buf, &len, "Tab: {d} of {d}", .{ in.tab_index + 1, in.tab_count });
        }
    }
    const pane_title = clip(trim(in.pane_title), max_label);
    if (pane_title.len > 0) Line.add(buf, &len, "Pane: {s}", .{pane_title});
    if (in.count > 1) Line.add(buf, &len, "Pane position: {d} of {d}", .{ in.index + 1, in.count });
    const dir = clip(baseName(trim(in.cwd)), max_label);
    if (dir.len > 0) Line.add(buf, &len, "Directory: {s}", .{dir});
    if (in.shell_pid != 0) Line.add(buf, &len, "Shell PID: {d}", .{in.shell_pid});
    return buf[0..len];
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn mkRow(pid: i64, ppid: i64, name: []const u8) Row {
    return .{ .pid = pid, .ppid = ppid, .name = name };
}

test "attribute: seeds on the shell pid and propagates down the whole subtree" {
    // The shape this column exists for: a pane's shell, an agent under it, and
    // a tool call two levels down that a tty match would have missed.
    var rows = [_]Row{
        mkRow(4, 0, "System"),
        mkRow(31160, 4, "pwsh.exe"),
        mkRow(8452, 31160, "node.exe"),
        mkRow(9912, 8452, "rg.exe"),
        mkRow(700, 4, "explorer.exe"),
    };
    const panes = [_]Pane{.{ .shell_pid = 31160, .label = "build" }};

    try testing.expectEqual(@as(usize, 3), attribute(&rows, &panes));
    try testing.expectEqualStrings("", rows[0].pane_label);
    try testing.expectEqualStrings("build", rows[1].pane_label);
    try testing.expectEqualStrings("build", rows[2].pane_label);
    try testing.expectEqualStrings("build", rows[3].pane_label);
    try testing.expectEqualStrings("", rows[4].pane_label);
}

test "attribute: two panes keep their own subtrees" {
    var rows = [_]Row{
        mkRow(100, 4, "pwsh.exe"),
        mkRow(101, 100, "zig.exe"),
        mkRow(200, 4, "pwsh.exe"),
        mkRow(201, 200, "zig.exe"),
    };
    const panes = [_]Pane{
        .{ .shell_pid = 100, .label = "a" },
        .{ .shell_pid = 200, .label = "b" },
    };
    try testing.expectEqual(@as(usize, 4), attribute(&rows, &panes));
    try testing.expectEqualStrings("a", rows[1].pane_label);
    try testing.expectEqualStrings("b", rows[3].pane_label);
}

test "attribute: the walk does not depend on row order" {
    // A child listed BEFORE its parent must still attribute — the fixed point
    // is what makes the pass order-independent, and a real snapshot is in pid
    // order, not tree order.
    var rows = [_]Row{
        mkRow(9912, 8452, "rg.exe"),
        mkRow(8452, 31160, "node.exe"),
        mkRow(31160, 4, "pwsh.exe"),
    };
    const panes = [_]Pane{.{ .shell_pid = 31160, .label = "build" }};
    try testing.expectEqual(@as(usize, 3), attribute(&rows, &panes));
    try testing.expectEqualStrings("build", rows[0].pane_label);
}

test "attribute: a ppid cycle settles instead of spinning" {
    var rows = [_]Row{
        mkRow(100, 4, "pwsh.exe"),
        mkRow(500, 600, "a.exe"),
        mkRow(600, 500, "b.exe"),
    };
    const panes = [_]Pane{.{ .shell_pid = 100, .label = "a" }};
    try testing.expectEqual(@as(usize, 1), attribute(&rows, &panes));
    try testing.expectEqualStrings("", rows[1].pane_label);
    try testing.expectEqualStrings("", rows[2].pane_label);
}

test "attribute: a missing parent stops the walk rather than guessing" {
    // 8452's parent is not in the snapshot (the row cap clipped it), so nothing
    // under it can be attributed — an answer of "not ours" beats a wrong pane.
    var rows = [_]Row{
        mkRow(31160, 4, "pwsh.exe"),
        mkRow(8452, 77777, "node.exe"),
    };
    const panes = [_]Pane{.{ .shell_pid = 31160, .label = "build" }};
    try testing.expectEqual(@as(usize, 1), attribute(&rows, &panes));
    try testing.expectEqualStrings("", rows[1].pane_label);
}

test "attribute: a pane with no shell pid matches nothing" {
    // A viewer pane runs no shell, and pid 0 is a real ppid value — a zero seed
    // that matched would attribute every root process to a viewer.
    var rows = [_]Row{ mkRow(4, 0, "System"), mkRow(100, 4, "pwsh.exe") };
    const panes = [_]Pane{.{ .shell_pid = 0, .label = "viewer" }};
    try testing.expectEqual(@as(usize, 0), attribute(&rows, &panes));
    try testing.expectEqualStrings("", rows[0].pane_label);

    // And a previous pass's labels are cleared, not left standing.
    rows[0].pane_label = "stale";
    _ = attribute(&rows, &panes);
    try testing.expectEqualStrings("", rows[0].pane_label);
}

test "isAutoMintedName: the window-N handle only" {
    try testing.expect(isAutoMintedName("window-1"));
    try testing.expect(isAutoMintedName("window-42"));
    try testing.expect(!isAutoMintedName("window-"));
    try testing.expect(!isAutoMintedName("window-build"));
    try testing.expect(!isAutoMintedName("build"));
    try testing.expect(!isAutoMintedName(""));
}

test "baseName: both separators, and a trailing one" {
    try testing.expectEqualStrings("ghoztty", baseName("D:\\git\\ghoztty"));
    try testing.expectEqualStrings("ghoztty", baseName("D:\\git\\ghoztty\\"));
    try testing.expectEqualStrings("ghoztty", baseName("/d/git/ghoztty"));
    try testing.expectEqualStrings("git", baseName("git"));
    try testing.expectEqualStrings("", baseName(""));
    try testing.expectEqualStrings("", baseName("\\\\"));
}

test "windowLabel: the pin wins, then the target name, then the tab" {
    try testing.expectEqualStrings(
        "release",
        windowLabel("release", "window-3", "~/git", "pwsh", "D:\\git"),
    );
    try testing.expectEqualStrings(
        "build",
        windowLabel("", "build", "~/git", "pwsh", "D:\\git"),
    );
    // The auto-minted handle never beats anything real.
    try testing.expectEqualStrings(
        "~/git",
        windowLabel("", "window-3", "~/git", "pwsh", "D:\\git"),
    );
    try testing.expectEqualStrings(
        "pwsh",
        windowLabel("", "window-3", "", "pwsh", "D:\\git"),
    );
    try testing.expectEqualStrings(
        "git",
        windowLabel("", "window-3", "", "", "D:\\git"),
    );
    // With nothing real at all the handle is still better than an empty cell.
    try testing.expectEqualStrings(
        "window-3",
        windowLabel("", "window-3", "", "", ""),
    );
    // Whitespace is not a name.
    try testing.expectEqualStrings(
        "pwsh",
        windowLabel("  ", "window-3", "  \t", "pwsh", ""),
    );
}

test "groupLabel: a single-tab window is named by the window alone" {
    var buf: [max_label]u8 = undefined;
    try testing.expectEqualStrings("build", groupLabel(&buf, "build", "~/git", 0, 1));
}

test "groupLabel: a multi-tab window names the tab" {
    var buf: [max_label]u8 = undefined;
    try testing.expectEqualStrings(
        "build \u{203A} tests",
        groupLabel(&buf, "build", "tests", 1, 3),
    );
    // A tab title that merely restates the window label adds nothing.
    try testing.expectEqualStrings(
        "build \u{203A} tab 2",
        groupLabel(&buf, "build", "build", 1, 3),
    );
    try testing.expectEqualStrings(
        "build \u{203A} tab 1",
        groupLabel(&buf, "build", "", 0, 2),
    );
}

test "titleDistinguishes: only a title unique among its siblings" {
    const titles = [_][]const u8{ "~/git", "~/git", "logs", "", "build" };
    try testing.expect(!titleDistinguishes(&titles, 0, "build-win")); // repeated
    try testing.expect(!titleDistinguishes(&titles, 1, "build-win"));
    try testing.expect(titleDistinguishes(&titles, 2, "build-win"));
    try testing.expect(!titleDistinguishes(&titles, 3, "build-win")); // empty
    // A title that just restates the group says nothing either.
    try testing.expect(!titleDistinguishes(&titles, 4, "build"));
    try testing.expect(!titleDistinguishes(&titles, 9, "build")); // out of range
}

test "paneLabel: lone pane, distinguishing title, positional fallback" {
    var buf: [max_label]u8 = undefined;
    try testing.expectEqualStrings("build", paneLabel(&buf, "build", "~/git", 0, 1, true));
    try testing.expectEqualStrings(
        "build \u{203A} logs",
        paneLabel(&buf, "build", "logs", 1, 3, true),
    );
    // This is the 2964c8859 defect: two panes titled "~/git" must NOT both
    // render "build › ~/git".
    try testing.expectEqualStrings(
        "build \u{203A} pane 1",
        paneLabel(&buf, "build", "~/git", 0, 2, false),
    );
    try testing.expectEqualStrings(
        "build \u{203A} pane 2",
        paneLabel(&buf, "build", "~/git", 1, 2, false),
    );
}

test "fit: truncates on a code-point boundary, never mid-sequence" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("abc", fit(&buf, "abc"));
    // "ab" + U+203A (3 bytes) = 5 bytes; a 4-byte buffer must drop the whole
    // character rather than leave two bytes of it.
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("ab", fit(&small, "ab\u{203A}"));
    try testing.expect(std.unicode.utf8ValidateSlice(fit(&small, "ab\u{203A}cd")));
}

test "a label that overflows its buffer degrades to the group, not to garbage" {
    var buf: [8]u8 = undefined;
    // "grouplabel" alone is longer than the buffer, so the fallback truncates.
    const out = paneLabel(&buf, "grouplabel", "title", 1, 3, true);
    try testing.expect(out.len <= buf.len);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "paneDetail: Mac's lines, Shell PID in place of TTY" {
    var buf: [max_detail]u8 = undefined;
    try testing.expectEqualStrings(
        "Window: build\nPane: ~/git\nPane position: 2 of 3\nDirectory: ghoztty\nShell PID: 31160",
        paneDetail(&buf, .{
            .window_label = "build",
            .pane_title = "~/git",
            .index = 1,
            .count = 3,
            .cwd = "D:\\git\\ghoztty\\",
            .shell_pid = 31160,
        }),
    );
}

test "paneDetail: a lone pane has no position, and empty parts have no line" {
    var buf: [max_detail]u8 = undefined;
    // Mac: `if !single` gates the position, `if !isEmpty` the title and cwd.
    try testing.expectEqualStrings(
        "Window: logs\nShell PID: 7",
        paneDetail(&buf, .{ .window_label = "logs", .pane_title = "  ", .shell_pid = 7 }),
    );
}

test "paneDetail: a multi-tab window names the tab, by title or by position" {
    var buf: [max_detail]u8 = undefined;
    try testing.expectEqualStrings(
        "Window: work\nTab: server (2 of 3)\nShell PID: 9",
        paneDetail(&buf, .{ .window_label = "work", .tab_title = "server", .tab_index = 1, .tab_count = 3, .shell_pid = 9 }),
    );
    // A tab title that only restates the window says nothing: position instead.
    try testing.expectEqualStrings(
        "Window: work\nTab: 1 of 2\nShell PID: 9",
        paneDetail(&buf, .{ .window_label = "work", .tab_title = "work", .tab_index = 0, .tab_count = 2, .shell_pid = 9 }),
    );
    // A one-tab window names no tab at all.
    try testing.expectEqualStrings(
        "Window: work\nShell PID: 9",
        paneDetail(&buf, .{ .window_label = "work", .tab_title = "server", .tab_count = 1, .shell_pid = 9 }),
    );
}

test "paneDetail: overlong parts are clipped on a code point, and every line survives" {
    var buf: [max_detail]u8 = undefined;
    const long = "\u{203A}" ** 200; // 600 bytes
    const out = paneDetail(&buf, .{
        .window_label = long,
        .tab_title = long ++ "x",
        .tab_count = 2,
        .pane_title = long,
        .count = 2,
        .cwd = long,
        .shell_pid = 42,
    });
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expect(std.mem.endsWith(u8, out, "\nShell PID: 42"));
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, out, "\n") + 1);
}

test "paneDetail: a small buffer keeps whole lines, never a partial one" {
    var small: [24]u8 = undefined;
    const out = paneDetail(&small, .{ .window_label = "build", .pane_title = "server", .shell_pid = 123456 });
    try testing.expectEqualStrings("Window: build", out);
}

test "attribute: carries each pane's detail with its label, down the subtree" {
    var rows = [_]Row{
        mkRow(100, 4, "pwsh.exe"),
        mkRow(101, 100, "zig.exe"),
        mkRow(5, 4, "svchost.exe"),
    };
    const panes = [_]Pane{.{ .shell_pid = 100, .label = "a", .detail = "Window: a\nShell PID: 100" }};
    try testing.expectEqual(@as(usize, 2), attribute(&rows, &panes));
    try testing.expectEqualStrings("Window: a\nShell PID: 100", rows[0].pane_detail);
    try testing.expectEqualStrings("Window: a\nShell PID: 100", rows[1].pane_detail);
    try testing.expectEqualStrings("", rows[2].pane_detail);
}
