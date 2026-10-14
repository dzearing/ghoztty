//! The pane sidebar's all-windows scope on Windows - its pure rules (T1829;
//! Mac 55352e377, b4a3216cc, 7855941f7: `PaneSidebarWindowGrouping`,
//! `PaneSidebarFilter`, the outline in `PaneSidebarView`).
//!
//! A header toggle, off by default, widens the sidebar's roster from this
//! window to every Ghoztty window, as an OUTLINE: each window is a parent row
//! (a chevron, its name, its pane count or a question badge) with its panes
//! indented under it. Windows are sorted by name - Finder's order, so the list
//! holds still as focus moves - and a window named `<project>: <worktree>`,
//! the worktree convention, is grouped under a collapsible project header and
//! labeled by its worktree alone.
//!
//! On Windows a Mac window is a TAB here: Mac's tabs are windows of their
//! own, each with its own sidebar roster, and this sidebar already lists one
//! tab's panes. So a "window" in this file is one tab of one top-level window,
//! and the top-level's other tabs are groups beside it.
//!
//! Everything here is string rules and list shaping - the title split, the
//! name order, the grouping, the search terms, and the line stream the panel
//! lays out (`pane_sidebar.layoutWith`) - so it is unit-tested in every lane.
//! Gathering the windows and painting them is `PaneSidebar.zig`.

const std = @import("std");
const pane_sidebar = @import("pane_sidebar.zig");

pub const Line = pane_sidebar.Line;

// ---------------------------------------------------------------------------
// Names

pub const Split = struct {
    project: []const u8,
    worktree: []const u8,
};

/// A window title split as `<project>: <worktree>`, or null when it isn't
/// one (Mac `PaneSidebarWindowGrouping.split`): both halves non-empty, and the
/// project short and a single line - a sentence that happens to contain a
/// colon is not a project, and neither is a URL (`http://x` has no space after
/// its colon).
pub fn splitWindowTitle(title: []const u8) ?Split {
    const at = std.mem.indexOf(u8, title, ": ") orelse return null;
    const project = std.mem.trim(u8, title[0..at], " \t");
    const worktree = std.mem.trim(u8, title[at + 2 ..], " \t");
    if (project.len == 0 or worktree.len == 0) return null;
    const chars = std.unicode.utf8CountCodepoints(project) catch project.len;
    if (chars > max_project_chars) return null;
    if (std.mem.indexOfAny(u8, project, "\r\n") != null) return null;
    return .{ .project = project, .worktree = worktree };
}

pub const max_project_chars: usize = 40;

/// Finder's order (Mac `localizedStandardCompare`): case-insensitive, and a
/// run of digits compares by its value, so `wt-2` sorts before `wt-10`. ASCII
/// letters fold; anything else compares by its bytes.
pub fn naturalOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const ra = digitRun(a, i);
            const rb = digitRun(b, j);
            const da = stripZeros(a[i..ra]);
            const db = stripZeros(b[j..rb]);
            // More significant digits is the bigger number.
            if (da.len != db.len) return std.math.order(da.len, db.len);
            const o = std.mem.order(u8, da, db);
            if (o != .eq) return o;
            i = ra;
            j = rb;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return std.math.order(ca, cb);
        i += 1;
        j += 1;
    }
    return std.math.order(a.len - i, b.len - j);
}

pub fn naturalLess(a: []const u8, b: []const u8) bool {
    return naturalOrder(a, b) == .lt;
}

fn digitRun(s: []const u8, from: usize) usize {
    var e = from;
    while (e < s.len and std.ascii.isDigit(s[e])) e += 1;
    return e;
}

fn stripZeros(d: []const u8) []const u8 {
    var k: usize = 0;
    while (k + 1 < d.len and d[k] == '0') k += 1;
    return d[k..];
}

// ---------------------------------------------------------------------------
// Order and grouping

/// One window in outline order.
pub const Placed = struct {
    /// Index into the titles the order was computed from.
    index: usize,
    /// The project it is grouped under, or null for a window on its own.
    /// A slice of its title.
    project: ?[]const u8,
    /// What its own header shows: the worktree inside a group, else the
    /// whole title.
    label: []const u8,
};

/// The windows in outline order (Mac `PaneSidebarWindowGrouping.sections`):
/// sections sorted by name - a project by its name, a lone window by its
/// title - and a project's windows by worktree. A project's windows are
/// always contiguous. `out` must hold `titles.len`; returns how many.
pub fn outlineOrder(titles: []const []const u8, out: []Placed) usize {
    const n = @min(titles.len, out.len);
    for (titles[0..n], 0..) |t, i| {
        out[i] = if (splitWindowTitle(t)) |s|
            .{ .index = i, .project = s.project, .label = s.worktree }
        else
            .{ .index = i, .project = null, .label = t };
    }
    std.sort.insertion(Placed, out[0..n], {}, placedLess);
    return n;
}

fn placedLess(_: void, a: Placed, b: Placed) bool {
    const ka = a.project orelse a.label;
    const kb = b.project orelse b.label;
    switch (naturalOrder(ka, kb)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    // Names that only differ in case are still two sections: never let
    // their windows interleave.
    switch (std.mem.order(u8, ka, kb)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    // A lone window ahead of the project it shares a name with.
    if ((a.project == null) != (b.project == null)) return a.project == null;
    switch (naturalOrder(a.label, b.label)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return a.index < b.index;
}

/// Whether `placed[i]` opens a new project group.
pub fn opensProject(placed: []const Placed, i: usize) bool {
    const p = placed[i].project orelse return false;
    if (i == 0) return true;
    const prev = placed[i - 1].project orelse return true;
    return !std.mem.eql(u8, p, prev);
}

/// How many windows the project group starting at `i` holds.
pub fn projectSize(placed: []const Placed, i: usize) usize {
    const p = placed[i].project orelse return 1;
    var n: usize = 1;
    while (i + n < placed.len) : (n += 1) {
        const q = placed[i + n].project orelse break;
        if (!std.mem.eql(u8, p, q)) break;
    }
    return n;
}

// ---------------------------------------------------------------------------
// The line stream

/// One window group, in outline order, as the line builder needs it.
pub const GroupSpec = struct {
    /// Non-null inside a project group.
    project: ?[]const u8 = null,
    grid: usize,
    stashed: usize = 0,
    /// The window's own panes are folded away under its header.
    folded: bool = false,
    /// Its project group is folded: the window header is gone too.
    project_folded: bool = false,
};

/// The panel's lines for the outline (Mac's `allWindows` view). Items are
/// numbered in group order - every group's grid panes, then its stashed ones,
/// including the panes of folded groups (the rail still shows those) - and a
/// pane line's `index` is that number. A head's `index` is its group's (a
/// project head names its first window's). Folded groups emit no pane lines.
/// Returns how many lines were written; stops early when `out` is full.
pub fn buildLines(groups: []const GroupSpec, out: []Line) usize {
    var n: usize = 0;
    var item: usize = 0;
    for (groups, 0..) |g, gi| {
        const opens = if (g.project) |p| (gi == 0 or groups[gi - 1].project == null or
            !std.mem.eql(u8, p, groups[gi - 1].project.?)) else false;
        if (opens) {
            if (!push(out, &n, .{ .kind = .project, .index = gi })) return n;
        } else if (g.project == null and gi > 0) {
            // A hairline between top-level sections that are windows; a
            // project header carries its own space above it.
            if (!push(out, &n, .{ .kind = .rule })) return n;
        }
        const depth: u8 = if (g.project != null) 1 else 0;
        const panes = g.grid + g.stashed;
        defer item += panes;
        if (g.project_folded) continue;
        if (!push(out, &n, .{ .kind = .window, .index = gi, .depth = depth })) return n;
        if (g.folded) continue;
        for (0..g.grid) |k| {
            if (!push(out, &n, .{ .kind = .pane, .index = item + k, .depth = depth + 1 })) return n;
        }
        if (g.stashed == 0) continue;
        if (!push(out, &n, .{ .kind = .rule, .depth = depth + 1 })) return n;
        if (!push(out, &n, .{ .kind = .stashed_caption, .index = gi, .depth = depth + 1 })) return n;
        for (0..g.stashed) |k| {
            if (!push(out, &n, .{ .kind = .pane, .index = item + g.grid + k, .depth = depth + 1 })) return n;
        }
    }
    return n;
}

/// Whether a window's panes are folded away (Mac 321e61d7c,
/// `PaneSidebarState.isWindowFolded`). Every window starts folded - one row
/// each, the overview the scope is for - except THIS window, which starts
/// open: it holds the pane you are in. `toggled` is a flip away from that
/// default, so a window that opens while the list shows arrives folded with
/// nothing to record. A search unfolds everything: a hit inside a fold reads
/// as no hit.
pub fn windowFolded(is_this_window: bool, toggled: bool, searching: bool) bool {
    if (searching) return false;
    return is_this_window == toggled;
}

fn push(out: []Line, n: *usize, line: Line) bool {
    if (n.* == out.len) return false;
    out[n.*] = line;
    n.* += 1;
    return true;
}

// ---------------------------------------------------------------------------
// Search (Mac `PaneSidebarFilter`; the field is T1877, `pane_sidebar_search`):
// whitespace-separated terms, ALL of which must appear somewhere in what a
// pane's row says about it, ignoring case and diacritics.

pub const TermIter = std.mem.TokenIterator(u8, .any);

pub fn terms(query: []const u8) TermIter {
    return std.mem.tokenizeAny(u8, query, " \t\r\n");
}

/// The most fields one pane is searched by (Mac `searchFields` plus its
/// window's title).
pub const max_fields: usize = 8;
/// Bytes of each field (and term) the fold looks at.
pub const fold_cap: usize = 1024;

pub fn matches(query: []const u8, fields: []const ?[]const u8) bool {
    var bufs: [max_fields][fold_cap]u8 = undefined;
    var folded: [max_fields]?[]const u8 = undefined;
    const nf = @min(fields.len, max_fields);
    for (fields[0..nf], 0..) |f, i| folded[i] = if (f) |s| fold(s, &bufs[i]) else null;
    var tb: [fold_cap]u8 = undefined;
    var it = terms(query);
    while (it.next()) |raw| {
        const t = fold(raw, &tb);
        if (t.len == 0) continue; // a term that was only combining marks
        var hit = false;
        for (folded[0..nf]) |f| {
            const s = f orelse continue;
            if (std.mem.indexOf(u8, s, t) != null) {
                hit = true;
                break;
            }
        }
        if (!hit) return false;
    }
    return true;
}

/// `s` folded for search into `buf` (Mac `.caseInsensitive,
/// .diacriticInsensitive`): ASCII lower-cased, the accented Latin letters of
/// Latin-1 and Latin Extended-A to their lower-case base letter, combining
/// marks (U+0300-U+036F - a decomposed `é` is `e` and one) dropped. Anything
/// else - other scripts, an invalid byte - passes through unchanged, which is
/// still an exact match for the same text. Never longer than `s`; cut at
/// `buf`'s end.
pub fn fold(s: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (len == 1 or i + len > s.len) {
            buf[n] = std.ascii.toLower(s[i]);
            n += 1;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch {
            buf[n] = s[i];
            n += 1;
            i += 1;
            continue;
        };
        if (cp >= 0x300 and cp <= 0x36F) {
            i += len;
            continue;
        }
        if (baseLetter(cp)) |b| {
            buf[n] = std.ascii.toLower(b);
            n += 1;
        } else {
            if (n + len > buf.len) break;
            @memcpy(buf[n .. n + len], s[i .. i + len]);
            n += len;
        }
        i += len;
    }
    return buf[0..n];
}

/// U+00C0-U+00FF and U+0100-U+017F by offset; '.' is a letter with no base
/// to fold to (a ligature, a letter of its own, a sign).
const latin1_bases = "AAAAAA.CEEEEIIII.NOOOOO.OUUUUY..aaaaaa.ceeeeiiii.nooooo.ouuuuy.y";
const ext_a_bases = "AaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIi..JjKk.LlLlLlLlLlNnNnNnn..OoOoOo..RrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZzs";

fn baseLetter(cp: u21) ?u8 {
    const b: u8 = if (cp >= 0xC0 and cp <= 0xFF)
        latin1_bases[cp - 0xC0]
    else if (cp >= 0x100 and cp <= 0x17F)
        ext_a_bases[cp - 0x100]
    else
        return null;
    return if (b == '.') null else b;
}

comptime {
    std.debug.assert(latin1_bases.len == 0x40);
    std.debug.assert(ext_a_bases.len == 0x80);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "a project-colon-worktree title splits" {
    const s = splitWindowTitle("ghoztty: pane-sidebar").?;
    try testing.expectEqualStrings("ghoztty", s.project);
    try testing.expectEqualStrings("pane-sidebar", s.worktree);
}

test "other titles do not split" {
    try testing.expect(splitWindowTitle("zsh") == null);
    try testing.expect(splitWindowTitle("ghoztty:") == null); // no worktree
    try testing.expect(splitWindowTitle("ghoztty: ") == null);
    try testing.expect(splitWindowTitle(": main") == null); // no project
    try testing.expect(splitWindowTitle("http://localhost:3000") == null); // no space after the colon
    try testing.expect(splitWindowTitle("x" ** 50 ++ ": y") == null); // a sentence, not a project
    try testing.expect(splitWindowTitle("two\nlines: y") == null);
    // Windows path shapes are not projects either.
    try testing.expect(splitWindowTitle("C:\\Users\\me") == null);
}

test "natural order folds case and compares numbers by value" {
    try testing.expect(naturalLess("wt-2", "wt-10"));
    try testing.expect(!naturalLess("wt-10", "wt-2"));
    try testing.expect(naturalLess("app", "App2"));
    try testing.expect(naturalLess("Build logs", "ghoztty"));
    try testing.expectEqual(std.math.Order.eq, naturalOrder("ABC", "abc"));
    try testing.expect(naturalLess("x007", "x8"));
    try testing.expect(naturalLess("a", "ab"));
}

fn orderOf(titles: []const []const u8, buf: []Placed) []const Placed {
    return buf[0..outlineOrder(titles, buf)];
}

test "windows are sorted by name and grouped by project" {
    var buf: [8]Placed = undefined;
    const p = orderOf(&.{ "zsh", "ghoztty: windows-amd64", "relay: main", "ghoztty: pane-sidebar", "Build logs", "ghoztty: main" }, &buf);
    const want_labels = [_][]const u8{ "Build logs", "main", "pane-sidebar", "windows-amd64", "main", "zsh" };
    const want_index = [_]usize{ 4, 5, 3, 1, 2, 0 };
    for (p, 0..) |e, i| {
        try testing.expectEqualStrings(want_labels[i], e.label);
        try testing.expectEqual(want_index[i], e.index);
    }
    try testing.expect(p[0].project == null); // an ungrouped window keeps its whole name
    try testing.expect(opensProject(p, 1));
    try testing.expect(!opensProject(p, 2));
    try testing.expectEqual(@as(usize, 3), projectSize(p, 1));
    try testing.expect(opensProject(p, 4));
    try testing.expectEqualStrings("relay", p[4].project.?);
    try testing.expect(!opensProject(p, 5));
}

test "numbers sort by value and case is ignored" {
    var buf: [4]Placed = undefined;
    const p = orderOf(&.{ "app: wt-10", "app: wt-2", "App2: x" }, &buf);
    try testing.expectEqualStrings("wt-2", p[0].label);
    try testing.expectEqualStrings("wt-10", p[1].label);
    try testing.expectEqualStrings("App2", p[2].project.?);
}

test "projects differing only in case never interleave" {
    var buf: [4]Placed = undefined;
    const p = orderOf(&.{ "Proj: b", "proj: a", "Proj: c" }, &buf);
    // Two groups, each contiguous.
    var opened: usize = 0;
    for (0..p.len) |i| if (opensProject(p, i)) {
        opened += 1;
    };
    try testing.expectEqual(@as(usize, 2), opened);
}

test "the order is stable for identical titles" {
    var buf: [4]Placed = undefined;
    const p = orderOf(&.{ "pwsh", "pwsh", "pwsh" }, &buf);
    try testing.expectEqual(@as(usize, 0), p[0].index);
    try testing.expectEqual(@as(usize, 1), p[1].index);
    try testing.expectEqual(@as(usize, 2), p[2].index);
}

fn kinds(lines: []const Line, buf: []u8) []const u8 {
    for (lines, 0..) |l, i| buf[i] = switch (l.kind) {
        .project => 'P',
        .window => 'W',
        .pane => 'p',
        .rule => '-',
        .stashed_caption => 'S',
    };
    return buf[0..lines.len];
}

test "lines: lone windows separated by hairlines, panes under their window" {
    var lines: [32]Line = undefined;
    const n = buildLines(&.{
        .{ .grid = 2 },
        .{ .grid = 1, .stashed = 1 },
    }, &lines);
    var kb: [32]u8 = undefined;
    try testing.expectEqualStrings("Wpp-Wp-Sp", kinds(lines[0..n], &kb));
    // Panes are one level in; their items count across groups.
    try testing.expectEqual(@as(u8, 1), lines[1].depth);
    try testing.expectEqual(@as(usize, 0), lines[1].index);
    try testing.expectEqual(@as(usize, 1), lines[2].index);
    try testing.expectEqual(@as(usize, 2), lines[5].index);
    try testing.expectEqual(@as(usize, 3), lines[8].index);
    try testing.expectEqual(@as(usize, 1), lines[7].index); // the caption names its group
}

test "lines: a project header, its windows one level in" {
    var lines: [32]Line = undefined;
    const n = buildLines(&.{
        .{ .grid = 1 },
        .{ .project = "ghoztty", .grid = 1 },
        .{ .project = "ghoztty", .grid = 2 },
        .{ .project = "relay", .grid = 1 },
        .{ .grid = 1 },
    }, &lines);
    var kb: [32]u8 = undefined;
    try testing.expectEqualStrings("WpPWpWppPWp-Wp", kinds(lines[0..n], &kb));
    try testing.expectEqual(@as(u8, 1), lines[3].depth); // window in a project
    try testing.expectEqual(@as(u8, 2), lines[4].depth); // its pane
    try testing.expectEqual(@as(usize, 1), lines[2].index); // the project names its first window
}

test "lines: folding drops the panes, and a folded project drops its windows" {
    var lines: [32]Line = undefined;
    const n = buildLines(&.{
        .{ .grid = 2, .folded = true },
        .{ .project = "p", .grid = 1, .project_folded = true },
        .{ .project = "p", .grid = 1, .project_folded = true },
        .{ .grid = 1 },
    }, &lines);
    var kb: [32]u8 = undefined;
    try testing.expectEqualStrings("WP-Wp", kinds(lines[0..n], &kb));
    // Items still count the folded panes: the last window's pane is item 4.
    try testing.expectEqual(@as(usize, 4), lines[4].index);
}

test "every window starts folded but this one; a flip inverts it; a search opens all (T1924)" {
    // The defaults.
    try testing.expect(windowFolded(false, false, false));
    try testing.expect(!windowFolded(true, false, false));
    // A flip away from them.
    try testing.expect(!windowFolded(false, true, false));
    try testing.expect(windowFolded(true, true, false));
    // Searching opens everything, flipped or not.
    for ([_]bool{ false, true }) |this| for ([_]bool{ false, true }) |flip| {
        try testing.expect(!windowFolded(this, flip, true));
    };
}

test "lines: a full buffer stops cleanly" {
    var lines: [3]Line = undefined;
    try testing.expectEqual(@as(usize, 3), buildLines(&.{.{ .grid = 5 }}, &lines));
}

test "search: every term must match somewhere" {
    try testing.expect(matches("ghoztty", &.{ "ghoztty: pane-sidebar", "zsh", null }));
    try testing.expect(!matches("ghoztty", &.{ "relay: main", "zsh", "~/git/relay" }));
    const fields = [_]?[]const u8{ "ghoztty: pane-sidebar", "claude - pane-sidebar", "Pane sidebar - building" };
    try testing.expect(matches("ghoztty claude", &fields));
    try testing.expect(!matches("ghoztty relay", &fields));
    try testing.expect(matches("GHOZTTY", &fields));
    try testing.expect(matches("   ", &.{"anything"}));
    var it = terms("  a  b ");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("b", it.next().?);
    try testing.expect(it.next() == null);
}

test "search: diacritics and case fold, both ways (T1877)" {
    // Mac's `.diacriticInsensitive`: an accent in either the query or the
    // text does not stop the match.
    try testing.expect(matches("resume", &.{"R\u{00E9}sum\u{00E9} notes"}));
    try testing.expect(matches("R\u{00C9}SUM\u{00C9}", &.{"resume notes"}));
    try testing.expect(matches("zurich", &.{"Z\u{00FC}rich office"}));
    try testing.expect(matches("lodz", &.{"\u{0141}\u{00F3}d\u{017A}"}));
    // Decomposed (a macOS path is NFD): the combining mark is dropped.
    try testing.expect(matches("cafe", &.{"cafe\u{0301}"}));
    try testing.expect(matches("caf\u{00E9}", &.{"cafe\u{0301}"}));
    // Not a fold: a different letter is still a different letter.
    try testing.expect(!matches("strasse", &.{"Stra\u{00DF}e"}));
    // Other scripts match themselves exactly.
    try testing.expect(matches("\u{03C0}\u{03B1}\u{03BD}", &.{"\u{03C0}\u{03B1}\u{03BD}\u{03B5}\u{03BB}"}));
    // A term that is nothing but a mark constrains nothing.
    try testing.expect(matches("\u{0301}", &.{"x"}));
}

test "search: the fold never grows its input and stops at the buffer" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("abcd", fold("ABCDEF", &buf));
    var b2: [16]u8 = undefined;
    try testing.expectEqualStrings("eo\u{4E2D}", fold("\u{00C9}\u{014C}\u{4E2D}", &b2));
    // A stray continuation byte passes through.
    try testing.expectEqualStrings("a\x80b", fold("A\x80B", &b2));
    // A multi-byte character that would not fit whole is left out.
    var b3: [2]u8 = undefined;
    try testing.expectEqualStrings("a", fold("a\u{4E2D}", &b3));
}
