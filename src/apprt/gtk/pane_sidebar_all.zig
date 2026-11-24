//! The GTK pane sidebar's all-windows list, its pure half (T3558, Linux L10c;
//! docs/reference/pane-sidebar.md "All windows").
//!
//! The header's scope button widens the sidebar from this window's panes to
//! every window's, as an OUTLINE: a row per window (its name and pane count)
//! with its panes under it when it is unfolded, windows titled
//! `<project>: <worktree>` grouped under a project header, and - beside a
//! group - the lone windows under an "Ungrouped" header. A search field keeps
//! only the panes every term matches, and the windows holding one; a search
//! unfolds everything, since a hit inside a fold would read as no hit. The
//! collapsed rail is one tile per window.
//!
//! As on win32, a Mac window is a TAB here: a GTK window's tabs are each a
//! "window" of the list (the per-window list already lists one tab's panes).
//!
//! Every rule is win32's pure modules, which carry the Mac's:
//! `win32/pane_sidebar_outline.zig` (the title split, Finder order, opened
//! order for namesakes, the line stream, the search match) and
//! `win32/pane_sidebar_shared.zig` (the scope, its search, the absolute
//! folds every window shares). This file only feeds them GTK's windows and
//! turns their lines into the rows `PaneSidebar.zig` draws. No GTK imports:
//! it runs in the none lane.
//!
//! Not here yet: dragging rows (windows, groups, panes) and the stash tray
//! (T3607); group editing - the window-row menu and the headers' tools
//! (T3608); a row's own tools, the hover tint and the busy sheen (T3606).

const std = @import("std");
const Allocator = std.mem.Allocator;
const outline = @import("../win32/pane_sidebar_outline.zig");
const shared_mod = @import("../win32/pane_sidebar_shared.zig");
const search_field = @import("../win32/pane_sidebar_search.zig");
const ps = @import("../win32/pane_sidebar.zig");
const rows = @import("pane_sidebar_rows.zig");

pub const Shared = shared_mod.Shared;
pub const HeadSelection = ps.HeadSelection;

/// One window of the list (a tab of a GTK window), as the caller gathered it.
pub const Window = struct {
    /// Its name: the pinned window title, else the tab's, else its focused
    /// pane's (`name`).
    name: []const u8,
    /// Stable while it lives: what its fold is kept by.
    key: u64,
    /// When it opened, relative to the others (smaller first): namesakes list
    /// in this order (Mac `openedOrder`).
    opened: u64,
    /// The window the sidebar is drawn in.
    own: bool = false,
    panes: []const rows.Pane,
};

pub const Kind = enum { project, ungrouped, window, pane };

/// One row of the outline, in drawing order.
pub const Item = struct {
    kind: Kind,
    /// The window (index into the gathered windows): a window row's, a pane
    /// row's; a header's first window.
    window: usize = 0,
    /// A pane row's pane (index into its window's panes).
    pane: usize = 0,
    /// A header's caption: the project's name, a window's label (its worktree
    /// inside a group, else its name). Borrowed from the gathered names.
    label: []const u8 = "",
    /// A project header's windows, a window row's panes (the hits, searching).
    count: usize = 0,
    folded: bool = false,
    /// Outline level (`pane_sidebar.Line.depth`): a pane row is one deeper
    /// than its window, which is all the indenting the list does.
    depth: u8 = 0,
    /// What the fold toggle flips: a window's key, a project's `projectKey`.
    key: u64 = 0,
    /// A window row's selection (`pane_sidebar.headSelection`).
    selection: HeadSelection = .none,
};

/// A project's fold key (shared `folded_projects`); the Ungrouped header's
/// is the empty project's.
pub fn projectKey(project: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x7033);
    h.update("project:");
    h.update(project);
    return h.final();
}

pub const ungrouped_key_name = "";

/// A window's name (win32 `groupName`): the user's pinned window title, else
/// the tab's pinned title, else the tab's own title (its focused pane's),
/// else the focused pane's directory, else "Window".
pub fn name(window_pinned: ?[]const u8, tab_pinned: ?[]const u8, tab_title: ?[]const u8, pwd: ?[]const u8) []const u8 {
    if (window_pinned) |w| if (w.len > 0) return w;
    if (tab_pinned) |t| if (t.len > 0) return t;
    return ps.displayTitle(tab_title, pwd, "Window");
}

/// Whether the search filters the list now: there is a query, the scope is
/// all windows, and the panel is expanded (the rail has no field).
pub fn filters(query: []const u8, all_windows: bool, expanded: bool) bool {
    var it = outline.terms(query);
    return search_field.filters(it.next() != null, all_windows, expanded);
}

/// Whether pane `p` of the window called `window_name` matches every term of
/// `query` (Mac `PaneSidebarFilter`; win32 `paneMatches`): its window's name,
/// its row's label, its own title (a banner title hides it on the row), its
/// banner's first line and its directory, whole and with home as `~`.
pub fn paneMatches(query: []const u8, window_name: []const u8, p: rows.Pane, home: ?[]const u8) bool {
    var lb: [rows.TEXT_BUF_LEN]u8 = undefined;
    var sb: [rows.TEXT_BUF_LEN]u8 = undefined;
    const t = rows.text(p, home, &lb, &sb);
    var line_buf: [rows.TEXT_BUF_LEN]u8 = undefined;
    const banner = if (p.viewer) null else ps.bannerLine(p.banner, &line_buf);
    var pwd_buf: [rows.TEXT_BUF_LEN]u8 = undefined;
    const pwd_short: ?[]const u8 = if (p.pwd) |d| ps.abbreviatePath(d, home, &pwd_buf) else null;
    return outline.matches(query, &.{ window_name, t.label, p.title, p.title_override, banner, p.pwd, pwd_short });
}

/// The windows in the list's order: lone windows by name, then each project
/// by name with its windows by worktree (`outline.outlineOrder`), namesakes
/// in the order they opened. Indices into `windows`; `out` holds
/// `windows.len`.
fn order(arena: Allocator, windows: []const Window, placed: []outline.Placed) Allocator.Error!void {
    const opened = try arena.alloc(u64, windows.len);
    for (windows, opened) |w, *o| o.* = w.opened;
    const by_opened = try arena.alloc(usize, windows.len);
    _ = outline.openedOrder(opened, by_opened);
    const titles = try arena.alloc([]const u8, windows.len);
    for (by_opened, titles) |i, *t| t.* = windows[i].name;
    _ = outline.outlineOrder(titles, placed);
    // Back from the opened order to the caller's indices.
    for (placed) |*p| p.index = by_opened[p.index];
}

/// The expanded all-windows outline. `query` is the search when it filters
/// (`filters`), else null. Items borrow the windows' names; everything is
/// allocated in `arena`.
pub fn build(arena: Allocator, windows: []const Window, query: ?[]const u8, shared: *const Shared, home: ?[]const u8) Allocator.Error![]Item {
    const placed = try arena.alloc(outline.Placed, windows.len);
    try order(arena, windows, placed);
    const searching = query != null;

    // The windows listed (a search drops the ones with no hit) and each one's
    // hits, in the order the panes were gathered (reading order).
    const Listed = struct { placed: outline.Placed, hits: []usize };
    var listed: std.ArrayListUnmanaged(Listed) = .empty;
    for (placed) |p| {
        const w = windows[p.index];
        var hits: std.ArrayListUnmanaged(usize) = .empty;
        for (w.panes, 0..) |pane, k| {
            if (query) |q| if (!paneMatches(q, w.name, pane, home)) continue;
            try hits.append(arena, k);
        }
        if (searching and hits.items.len == 0) continue;
        try listed.append(arena, .{ .placed = p, .hits = hits.items });
    }

    const specs = try arena.alloc(outline.GroupSpec, listed.items.len);
    for (listed.items, specs) |l, *s| s.* = .{
        .project = l.placed.project,
        .grid = l.hits.len,
        .folded = shared.groupFolded(true, windows[l.placed.index].key, searching),
        .project_folded = false,
    };
    // A project fold (and the Ungrouped header's) hides its windows' rows;
    // a search unfolds it as it unfolds windows.
    const ungrouped = outline.headsUngrouped(specs);
    for (specs) |*s| {
        if (searching) break;
        if (s.project) |pj| {
            s.project_folded = shared.folded_projects.contains(projectKey(pj));
        } else if (ungrouped) {
            s.project_folded = shared.folded_projects.contains(projectKey(ungrouped_key_name));
        }
    }

    // Every window's panes are numbered one after another (`buildLines`):
    // where each window's numbers start.
    const first_item = try arena.alloc(usize, listed.items.len);
    var next_item: usize = 0;
    for (listed.items, first_item) |l, *f| {
        f.* = next_item;
        next_item += l.hits.len;
    }

    const listed_placed = try arena.alloc(outline.Placed, listed.items.len);
    for (listed.items, listed_placed) |l, *p| p.* = l.placed;

    const lines = try arena.alloc(ps.Line, 2 * listed.items.len + next_item + 1);
    const n = outline.buildLines(specs, lines);
    const out = try arena.alloc(Item, n);
    var g: usize = 0; // the window group a pane line belongs to
    for (lines[0..n], out) |line, *item| switch (line.kind) {
        .project => {
            const spec = specs[line.index];
            const w = listed.items[line.index].placed.index;
            if (spec.project) |pj| {
                item.* = .{
                    .kind = .project,
                    .window = w,
                    .label = pj,
                    .count = outline.projectSize(listed_placed, line.index),
                    .folded = spec.project_folded,
                    .key = projectKey(pj),
                };
            } else {
                var lones: usize = 0;
                for (specs) |s| if (s.project == null) {
                    lones += 1;
                };
                item.* = .{
                    .kind = .ungrouped,
                    .window = w,
                    .label = "Ungrouped",
                    .count = lones,
                    .folded = spec.project_folded,
                    .key = projectKey(ungrouped_key_name),
                };
            }
        },
        .window => {
            const l = listed.items[line.index];
            const w = windows[l.placed.index];
            const spec = specs[line.index];
            item.* = .{
                .kind = .window,
                .window = l.placed.index,
                .label = l.placed.label,
                .count = l.hits.len,
                .folded = spec.folded,
                .depth = line.depth,
                .key = w.key,
                .selection = ps.headSelection(.window, w.own, spec.folded, false, true),
            };
        },
        .pane => {
            while (g + 1 < listed.items.len and line.index >= first_item[g + 1]) g += 1;
            const l = listed.items[g];
            item.* = .{
                .kind = .pane,
                .window = l.placed.index,
                .pane = l.hits[line.index - first_item[g]],
                .depth = line.depth,
            };
        },
    };
    return out;
}

/// The collapsed all-windows rail: one tile per window, in the list's order,
/// headers left out. Indices into `windows`.
pub fn railOrder(arena: Allocator, windows: []const Window) Allocator.Error![]usize {
    const placed = try arena.alloc(outline.Placed, windows.len);
    try order(arena, windows, placed);
    const out = try arena.alloc(usize, windows.len);
    for (placed, out) |p, *o| o.* = p.index;
    return out;
}

/// The first pane a search lists (what Return goes to), or null.
pub fn firstHit(items: []const Item) ?Item {
    for (items) |i| if (i.kind == .pane) return i;
    return null;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn kinds(items: []const Item, buf: []u8) []const u8 {
    for (items, 0..) |it, i| buf[i] = switch (it.kind) {
        .project => 'P',
        .ungrouped => 'U',
        .window => 'W',
        .pane => 'p',
    };
    return buf[0..items.len];
}

test "T3558: every window folds to its row when the scope turns on, and unfolds to its panes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var shared: Shared = .{};
    defer shared.deinit(testing.allocator);
    _ = shared.setAllWindows(true);

    const a_panes = [_]rows.Pane{ .{ .title = "vim" }, .{ .title = "make" } };
    const b_panes = [_]rows.Pane{.{ .title = "htop" }};
    const wins = [_]Window{
        .{ .name = "beta", .key = 2, .opened = 1, .panes = &b_panes },
        .{ .name = "alpha", .key = 1, .opened = 2, .own = true, .panes = &a_panes },
    };
    var buf: [32]u8 = undefined;
    var items = try build(arena, &wins, null, &shared, null);
    // Finder order, both folded; this window's folded row is the accent.
    try testing.expectEqualStrings("WW", kinds(items, &buf));
    try testing.expectEqualStrings("alpha", items[0].label);
    try testing.expectEqual(@as(usize, 2), items[0].count);
    try testing.expect(items[0].folded);
    try testing.expectEqual(HeadSelection.accent, items[0].selection);
    try testing.expectEqual(HeadSelection.none, items[1].selection);

    // Unfolding alpha lists its panes under it, a level in; open, its row
    // takes the unemphasized pill (the focused pane's row has the accent).
    shared.toggleGroup(testing.allocator, true, 1);
    items = try build(arena, &wins, null, &shared, null);
    try testing.expectEqualStrings("WppW", kinds(items, &buf));
    try testing.expectEqual(@as(usize, 0), items[1].pane);
    try testing.expectEqual(@as(usize, 1), items[2].pane);
    try testing.expectEqual(@as(u8, 1), items[1].depth);
    try testing.expectEqual(HeadSelection.unemphasized, items[0].selection);
    try testing.expectEqual(@as(usize, 1), items[1].window);

    // Turning the scope off forgets the folds: on again, all folded.
    _ = shared.setAllWindows(false);
    _ = shared.setAllWindows(true);
    items = try build(arena, &wins, null, &shared, null);
    try testing.expectEqualStrings("WW", kinds(items, &buf));
}

test "T3558: project windows group under their header, lone windows first under Ungrouped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var shared: Shared = .{};
    defer shared.deinit(testing.allocator);
    _ = shared.setAllWindows(true);

    const one = [_]rows.Pane{.{ .title = "sh" }};
    const wins = [_]Window{
        .{ .name = "ghoztty: wt-10", .key = 1, .opened = 1, .panes = &one },
        .{ .name = "notes", .key = 2, .opened = 2, .panes = &one },
        .{ .name = "ghoztty: wt-2", .key = 3, .opened = 3, .panes = &one },
    };
    var buf: [32]u8 = undefined;
    var items = try build(arena, &wins, null, &shared, null);
    try testing.expectEqualStrings("UWPWW", kinds(items, &buf));
    try testing.expectEqualStrings("Ungrouped", items[0].label);
    try testing.expectEqual(@as(usize, 1), items[0].count);
    try testing.expectEqualStrings("notes", items[1].label);
    try testing.expectEqualStrings("ghoztty", items[2].label);
    try testing.expectEqual(@as(usize, 2), items[2].count);
    // Labeled by the worktree, in Finder order (2 before 10).
    try testing.expectEqualStrings("wt-2", items[3].label);
    try testing.expectEqualStrings("wt-10", items[4].label);

    // Folding the project hides its windows' rows; the header stays.
    shared.toggleProject(testing.allocator, items[2].key);
    items = try build(arena, &wins, null, &shared, null);
    try testing.expectEqualStrings("UWP", kinds(items, &buf));
    try testing.expect(items[2].folded);

    // With no group there is no Ungrouped header: a flat list.
    const flat = [_]Window{
        .{ .name = "b", .key = 1, .opened = 1, .panes = &one },
        .{ .name = "a", .key = 2, .opened = 2, .panes = &one },
    };
    items = try build(arena, &flat, null, &shared, null);
    try testing.expectEqualStrings("WW", kinds(items, &buf));
}

test "T3558: namesakes list in the order they opened" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var shared: Shared = .{};
    defer shared.deinit(testing.allocator);
    _ = shared.setAllWindows(true);
    const one = [_]rows.Pane{.{}};
    // Gathered in tab order, which a drag moves; opened 30 is the newest.
    const wins = [_]Window{
        .{ .name = "~", .key = 1, .opened = 30, .panes = &one },
        .{ .name = "~", .key = 2, .opened = 10, .panes = &one },
        .{ .name = "~", .key = 3, .opened = 20, .panes = &one },
    };
    const items = try build(arena, &wins, null, &shared, null);
    try testing.expectEqual(@as(usize, 1), items[0].window);
    try testing.expectEqual(@as(usize, 2), items[1].window);
    try testing.expectEqual(@as(usize, 0), items[2].window);
    const rail = try railOrder(arena, &wins);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, rail);
}

test "T3558: a search keeps every term's panes, drops windows with none, and unfolds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var shared: Shared = .{};
    defer shared.deinit(testing.allocator);
    _ = shared.setAllWindows(true);

    const a_panes = [_]rows.Pane{
        .{ .title = "vim", .pwd = "/home/ann/src/parser" },
        .{ .title = "make test", .pwd = "/home/ann/src/parser" },
        .{ .title = "zsh", .pwd = "/tmp", .banner = "## Fix the Parser" },
    };
    const b_panes = [_]rows.Pane{.{ .title = "htop", .pwd = "/" }};
    const wins = [_]Window{
        .{ .name = "work", .key = 1, .opened = 1, .panes = &a_panes },
        .{ .name = "ops", .key = 2, .opened = 2, .panes = &b_panes },
    };
    var buf: [32]u8 = undefined;
    // Every term must appear; case does not matter; the banner and the
    // directory (also as ~/...) are searched.
    var items = try build(arena, &wins, "PARSER vim", &shared, "/home/ann");
    try testing.expectEqualStrings("Wp", kinds(items, &buf));
    try testing.expect(!items[0].folded);
    try testing.expectEqual(@as(usize, 1), items[0].count);
    try testing.expectEqual(@as(usize, 0), items[1].pane);

    items = try build(arena, &wins, "parser", &shared, "/home/ann");
    try testing.expectEqualStrings("Wppp", kinds(items, &buf));
    try testing.expectEqual(@as(usize, 0), firstHit(items).?.pane);
    try testing.expectEqual(@as(usize, 2), items[3].pane);

    items = try build(arena, &wins, "~/src", &shared, "/home/ann");
    try testing.expectEqualStrings("Wpp", kinds(items, &buf));

    // The window's own name matches all of its panes.
    items = try build(arena, &wins, "ops", &shared, null);
    try testing.expectEqualStrings("Wp", kinds(items, &buf));
    try testing.expectEqualStrings("ops", items[0].label);

    // Nothing matches: nothing is listed.
    items = try build(arena, &wins, "nope", &shared, null);
    try testing.expectEqual(@as(usize, 0), items.len);
    try testing.expect(firstHit(items) == null);
}

test "T3558: the search filters only in the expanded all-windows panel" {
    try testing.expect(filters("x", true, true));
    try testing.expect(!filters("  ", true, true));
    try testing.expect(!filters("x", false, true));
    try testing.expect(!filters("x", true, false));
}

test "T3558: a window is named by its pinned title, else its tab's, else its pane's" {
    try testing.expectEqualStrings("Mine", name("Mine", "tab", "vim", "/x"));
    try testing.expectEqualStrings("tab", name(null, "tab", "vim", "/x"));
    try testing.expectEqualStrings("vim", name("", null, "vim", "/x"));
    try testing.expectEqualStrings("Window", name(null, null, null, null));
}
