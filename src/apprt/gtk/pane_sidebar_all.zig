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
//! A header's hover + and x (T3606) read `Item.members` for what they close.
//! This window's own list is built here too (`buildOwn`, T3695): the same
//! window header over its panes, with its group's header above it.
//!
//! The list has an order of its own (T3697; win32 T2337/T2338, Mac
//! `PaneSidebarItemDrag` / `PaneSidebarCrossDrop`): `Shared.window_order`,
//! keys `project:<name>` and `window:<tab key, hex>` - the very ids the rows
//! carry - read over the name order by `win32/pane_sidebar_window_order`
//! (`arrange`). `dropItem` is a drag let go: a project header among the top
//! level, a window row anywhere, into or out of a group
//! (`win32/pane_sidebar_cross_drop`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const outline = @import("../win32/pane_sidebar_outline.zig");
const shared_mod = @import("../win32/pane_sidebar_shared.zig");
const search_field = @import("../win32/pane_sidebar_search.zig");
const ps = @import("../win32/pane_sidebar.zig");
const window_order = @import("../win32/pane_sidebar_window_order.zig");
const cross_drop = @import("../win32/pane_sidebar_cross_drop.zig");
const window_title_owner = @import("../win32/window_title_owner.zig");
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
    /// The windows (their keys) a header's x closes (T3606): a window row's
    /// own; a project's (or Ungrouped's) every window it lists - while
    /// searching, only the matching ones it counts, folded or not.
    members: []const u64 = &.{},
    /// The group a window row is in, a project header's own name; null for
    /// a lone window (T3697: where a drag takes it from).
    project: ?[]const u8 = null,
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

/// The title a script's `+rename` of a window must leave alone, or null when
/// the rename may go ahead (T3702; win32 T2404, Mac `windowTitleIsUsers`).
/// A rename pins the WINDOW, and that pin outranks every tab's in `name`, so
/// it would hide whatever the user put up: a window pin they set (the
/// sidebar's group move, Create Group, the Ungrouped pencil on a window that
/// already carries a window-wide pin), or a tab's pin - which only the user
/// sets here (Change Tab Title, the same sidebar moves, a restore of one).
/// The targeted tab's pin is the one named; another tab's is named when the
/// targeted tab has none. A script's own window pin already hides every
/// tab's, so another script may replace it.
pub fn renameKept(
    window_pinned: ?[]const u8,
    window_by_user: bool,
    target_tab_pinned: ?[]const u8,
    other_tab_pinned: ?[]const u8,
) ?[]const u8 {
    if (window_pinned) |w| if (w.len > 0)
        return window_title_owner.keptFromScript(w, window_by_user);
    if (target_tab_pinned) |t| if (t.len > 0) return t;
    if (other_tab_pinned) |t| if (t.len > 0) return t;
    return null;
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

/// A window's key in the list's order (`window_order.windowKey`): its row's
/// id, `window:<tab key, hex>`.
pub fn windowOrderKey(arena: Allocator, key: u64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{x}", .{ window_order.window_prefix, key });
}

/// A project's key in the list's order: its header row's id.
pub fn projectOrderKey(arena: Allocator, project: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ window_order.project_prefix, project });
}

/// Every window's order key, indexed like `windows`.
fn windowKeys(arena: Allocator, windows: []const Window) Allocator.Error![]const []const u8 {
    const keys = try arena.alloc([]const u8, windows.len);
    for (windows, keys) |w, *k| k.* = try windowOrderKey(arena, w.key);
    return keys;
}

/// The windows in the list's order (T3697): the name order (`nameOrder`)
/// arranged by the user's (`window_order.arrange`) - lone windows ahead of
/// the groups, a group's windows together, anything never dragged placed by
/// its name neighbours. Indices into `windows`; `placed` holds `windows.len`.
fn order(arena: Allocator, windows: []const Window, placed: []outline.Placed, shared: *const Shared) Allocator.Error!void {
    const by_name = try arena.alloc(outline.Placed, windows.len);
    try nameOrder(arena, windows, by_name);
    var buf: [window_order.max_keys][]const u8 = undefined;
    const user = shared.windowOrder(&buf);
    if (user.len == 0 or windows.len > window_order.max_keys) {
        @memcpy(placed, by_name);
        return;
    }
    const n = window_order.arrange(by_name, try windowKeys(arena, windows), user, placed);
    std.debug.assert(n == windows.len);
}

/// Every key the list has, unfiltered (win32 `allOrderKeys`, Mac
/// `PaneSidebarWindowGrouping.keys`): each window's and each project's once.
/// A drop's `existing`, so a key outside it - a closed window - is pruned.
pub fn allOrderKeys(arena: Allocator, windows: []const Window) Allocator.Error![]const []const u8 {
    const placed = try arena.alloc(outline.Placed, windows.len);
    try nameOrder(arena, windows, placed);
    return keysOf(arena, windows, placed);
}

/// The list's keys as it is shown now (win32 `pinned`, Mac
/// `PaneSidebarWindowGrouping.pinned`): what a group move keeps, so nothing
/// it did not move re-sorts (`window_order.renamingWindow`).
pub fn shownOrderKeys(arena: Allocator, windows: []const Window, shared: *const Shared) Allocator.Error![]const []const u8 {
    const placed = try arena.alloc(outline.Placed, windows.len);
    try order(arena, windows, placed, shared);
    return keysOf(arena, windows, placed);
}

fn keysOf(arena: Allocator, windows: []const Window, placed: []const outline.Placed) Allocator.Error![]const []const u8 {
    const n = @min(placed.len, window_order.max_keys);
    const bufs = try arena.alloc(window_order.Key, n);
    const out = try arena.alloc([]const u8, 2 * n);
    // `allKeys` borrows `bufs`, which the arena keeps.
    const got = window_order.allKeys(placed[0..n], try windowKeys(arena, windows), bufs, out);
    return out[0..got];
}

/// The windows by name: lone windows by name, then each project by name
/// with its windows by worktree (`outline.outlineOrder`), namesakes in the
/// order they opened. Indices into `windows`; `placed` holds `windows.len`.
fn nameOrder(arena: Allocator, windows: []const Window, placed: []outline.Placed) Allocator.Error!void {
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
    return buildFor(arena, windows, query, shared, home, null);
}

/// This window's own list (T3695; Mac e94a9737e / 32bc9a6b5, win32
/// `addThisWindowHeads`): the window `own` (an index into `windows`) held by
/// its header - its chevron, name and count, and on hover + and x - with its
/// panes one level in under it, exactly as all windows draws a window. A
/// `<project>: <name>` window has its group's header above its own, and a
/// folded group shows that header alone. The folds are this list's own
/// (`folded_this`, not the all-windows ones), and the header is drawn
/// selected only while it is folded: open, its focused pane's row has the
/// accent. The group's header counts, and its x closes, every window of the
/// group, not only this one - so `windows` is every window, and only `own`'s
/// rows are listed.
pub fn buildOwn(arena: Allocator, windows: []const Window, own: usize, shared: *const Shared, home: ?[]const u8) Allocator.Error![]Item {
    return buildFor(arena, windows, null, shared, home, own);
}

fn buildFor(arena: Allocator, windows: []const Window, query: ?[]const u8, shared: *const Shared, home: ?[]const u8, only: ?usize) Allocator.Error![]Item {
    const placed = try arena.alloc(outline.Placed, windows.len);
    try order(arena, windows, placed, shared);
    const searching = query != null;
    const all_windows = only == null;

    // The windows listed (a search drops the ones with no hit) and each one's
    // hits, in the order the panes were gathered (reading order).
    const Listed = struct { placed: outline.Placed, hits: []usize };
    var listed: std.ArrayListUnmanaged(Listed) = .empty;
    for (placed) |p| {
        if (only) |o| if (p.index != o) continue;
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
        .folded = shared.groupFolded(all_windows, windows[l.placed.index].key, searching),
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
                    // This window's own list counts (and closes) the whole
                    // group, every window of which `placed` holds.
                    .count = if (all_windows) outline.projectSize(listed_placed, line.index) else countProject(placed, pj),
                    .folded = spec.project_folded,
                    .key = projectKey(pj),
                    .members = try memberKeys(arena, windows, if (all_windows) listed_placed else placed, pj),
                    .project = pj,
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
                    .members = try memberKeys(arena, windows, listed_placed, null),
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
                .selection = ps.headSelection(.window, w.own, spec.folded, false, all_windows),
                .members = try arena.dupe(u64, &.{w.key}),
                .project = l.placed.project,
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

fn countProject(placed: []const outline.Placed, project: []const u8) usize {
    var n: usize = 0;
    for (placed) |p| if (p.project) |q| {
        if (std.mem.eql(u8, q, project)) n += 1;
    };
    return n;
}

/// The keys of the listed windows grouped under `project` (null: the lone
/// ones the Ungrouped header heads), in the list's order.
fn memberKeys(arena: Allocator, windows: []const Window, listed: []const outline.Placed, project: ?[]const u8) Allocator.Error![]u64 {
    var out: std.ArrayListUnmanaged(u64) = .empty;
    for (listed) |p| {
        const same = if (project) |pj|
            (if (p.project) |q| std.mem.eql(u8, q, pj) else false)
        else
            p.project == null;
        if (same) try out.append(arena, windows[p.index].key);
    }
    return out.items;
}

/// The collapsed all-windows rail: one tile per window, in the list's order,
/// headers left out. Indices into `windows`.
pub fn railOrder(arena: Allocator, windows: []const Window, shared: *const Shared) Allocator.Error![]usize {
    const placed = try arena.alloc(outline.Placed, windows.len);
    try order(arena, windows, placed, shared);
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
// Dragging windows and groups (T3697; docs/reference/pane-sidebar.md
// "Reordering windows and groups"; win32 `maybeStartItemDrag` /
// `placeItem` / `placeWindow`)
//
// The drag is read against the list as laid out once it has folded (every
// group to its header for a group drag, every window to its row for a window
// drag), the way win32 and the Mac read it. GTK draws its own drag icon and
// nothing glides (parity is behavior here), so only the release is computed.

/// A header row of the expanded all-windows list as laid out, in drawing
/// order. Pane rows are not listed: a header's extent runs to the next
/// header's top (its panes, if it shows any, are under it).
pub const Laid = struct {
    kind: Kind,
    /// Its order key, which is its row's id: `window:<hex>` or
    /// `project:<name>`; anything for the Ungrouped header.
    key: []const u8,
    /// A window row's group, a project header's own name; null for a lone
    /// window.
    project: ?[]const u8 = null,
    /// Its top, in the list's coordinates.
    top: i32,
    /// Its own row's bottom (its height is the drag's).
    head_bottom: i32,
};

/// A drop's outcome.
pub const Dropped = struct {
    /// The list's new order (arena-owned).
    order: []const []const u8,
    /// The index it lands at among its new siblings, without it.
    index: usize,
    /// A window let go into another group, or out of its own: it is retitled
    /// into `project` (null: no group) - `<project>: <name>`, or its name.
    regroup: bool = false,
    project: ?[]const u8 = null,
};

fn sameProject(a: ?[]const u8, b: ?[]const u8) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.mem.eql(u8, x, y);
}

/// Each laid row's extent, top to the next header's top (the last to
/// `list_bottom`): a window's panes and a group's windows hang under it.
fn extent(laid: []const Laid, i: usize, list_bottom: i32) window_order.Span {
    const bottom = if (i + 1 < laid.len) laid[i + 1].top else @max(list_bottom, laid[i].head_bottom);
    return .{ .top = laid[i].top, .bottom = @max(bottom, laid[i].head_bottom) };
}

/// The item keyed `dragged` (a window row's or a project header's key) let
/// go with the pointer at `y`, held by its middle: where it lands, and the
/// order that says so. A project header moves among the top level (lone
/// windows lead, so it stops below them); a window row moves anywhere,
/// into a group or out of one (`cross_drop.resolve`). `current` is the
/// stored order, `existing` every key the list has (`allOrderKeys`). Null
/// when `dragged` is not a draggable row of `laid`.
pub fn dropItem(
    arena: Allocator,
    laid: []const Laid,
    list_bottom: i32,
    dragged: []const u8,
    y: i32,
    current: []const []const u8,
    existing: []const []const u8,
) Allocator.Error!?Dropped {
    const n = @min(laid.len, window_order.max_keys);
    const src_row = for (laid[0..n], 0..) |l, i| {
        if (l.kind != .ungrouped and std.mem.eql(u8, l.key, dragged)) break i;
    } else return null;
    const height = laid[src_row].head_bottom - laid[src_row].top;
    const out = try arena.alloc([]const u8, window_order.max_keys);

    if (laid[src_row].kind == .project) {
        // A group's siblings: the top level, each group (its header and its
        // windows) and each lone window (Ungrouped heads nothing here).
        var spans: [window_order.max_keys]window_order.Span = undefined;
        var keys: [window_order.max_keys][]const u8 = undefined;
        var is_group: [window_order.max_keys]bool = undefined;
        var m: usize = 0;
        var source: ?usize = null;
        for (laid[0..n], 0..) |l, i| {
            const e = extent(laid[0..n], i, list_bottom);
            switch (l.kind) {
                .ungrouped, .pane => {},
                .project => {
                    if (i == src_row) source = m;
                    spans[m] = e;
                    keys[m] = l.key;
                    is_group[m] = true;
                    m += 1;
                },
                .window => if (l.project == null) {
                    spans[m] = e;
                    keys[m] = l.key;
                    is_group[m] = false;
                    m += 1;
                } else if (m > 0 and is_group[m - 1]) {
                    // One of the group's windows: the group reaches down.
                    spans[m - 1].bottom = e.bottom;
                },
            }
        }
        const src = source orelse return null;
        const f = spans[0..m];
        const top = window_order.clamp(y - @divTrunc(height, 2), src, f, null);
        const to = window_order.banded(window_order.target(top, src, f), src, is_group[0..m]);
        var without: [window_order.max_keys][]const u8 = undefined;
        var nw: usize = 0;
        for (keys[0..m], 0..) |k, j| if (j != src) {
            without[nw] = k;
            nw += 1;
        };
        const got = window_order.moving(dragged, to, without[0..nw], current, existing, out);
        return .{ .order = out[0..got], .index = to };
    }

    // A window: the whole list as rows - each group's header, each window
    // (Mac `listRows`, win32 `crossRelayout`).
    var cross: [window_order.max_keys]cross_drop.Row = undefined;
    var keys: [window_order.max_keys][]const u8 = undefined;
    var spans: [window_order.max_keys]window_order.Span = undefined;
    var m: usize = 0;
    var source: ?usize = null;
    for (laid[0..n], 0..) |l, i| {
        if (l.kind != .project and l.kind != .window) continue;
        if (i == src_row) source = m;
        const e = extent(laid[0..n], i, list_bottom);
        cross[m] = .{ .project = l.project, .header = l.kind == .project, .span = e };
        spans[m] = e;
        keys[m] = l.key;
        m += 1;
    }
    const src = source orelse return null;
    // Pitch 0: nothing slides while a GTK drag is held (no glide), so the
    // pointer is read against the rows where they are drawn, not closed up
    // where the dragged one left (win32/Mac `window_order.pitch`) - as a
    // pane row's drop reads it (`rows.dropIndex`).
    const top = window_order.clamp(y - @divTrunc(height, 2), src, spans[0..m], null);
    const r = cross_drop.resolve(cross[0..m], src, 0, top);
    const dest_project = r.dest.project();
    // Its new siblings, in the list's order, without it: the group's
    // windows, or the top level - each group once, and every lone window.
    var among: [window_order.max_keys][]const u8 = undefined;
    var na: usize = 0;
    for (cross[0..m], 0..) |c, j| {
        if (j == src) continue;
        const take = if (dest_project) |p|
            !c.header and sameProject(c.project, p)
        else
            c.header or c.project == null;
        if (!take) continue;
        among[na] = keys[j];
        na += 1;
    }
    const index = switch (r.dest) {
        .group => |g| g.index,
        .top_level => |i| i,
    };
    const got = window_order.moving(dragged, index, among[0..na], current, existing, out);
    const regroup = !sameProject(dest_project, cross[src].project);
    return .{
        .order = out[0..got],
        .index = index,
        .regroup = regroup,
        .project = if (dest_project) |p| try arena.dupe(u8, p) else null,
    };
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

test "T3702: a script rename leaves the user's window or tab title alone" {
    // A window pin the user set wins; a script's may be replaced.
    try testing.expectEqualStrings("app: build", renameKept("app: build", true, null, null).?);
    try testing.expect(renameKept("deploy", false, null, null) == null);
    // A script's window pin already hides the tabs' pins.
    try testing.expect(renameKept("deploy", false, "app: build", null) == null);
    // With no window pin, a tab's pin is the user's: the targeted tab's first.
    try testing.expectEqualStrings("app: build", renameKept(null, false, "app: build", "other").?);
    try testing.expectEqualStrings("other", renameKept(null, false, null, "other").?);
    try testing.expectEqualStrings("other", renameKept("", false, "", "other").?);
    // Nothing pinned: the rename goes ahead.
    try testing.expect(renameKept(null, false, null, null) == null);
    try testing.expect(renameKept("", true, "", "") == null);
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
    // T3606: each header's x closes the windows it heads.
    try testing.expectEqualSlices(u64, &.{2}, items[0].members);
    try testing.expectEqualSlices(u64, &.{2}, items[1].members);
    try testing.expectEqualSlices(u64, &.{ 3, 1 }, items[2].members);

    // Folding the project hides its windows' rows; the header stays.
    shared.toggleProject(testing.allocator, items[2].key);
    items = try build(arena, &wins, null, &shared, null);
    try testing.expectEqualStrings("UWP", kinds(items, &buf));
    try testing.expect(items[2].folded);
    try testing.expectEqualSlices(u64, &.{ 3, 1 }, items[2].members);

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
    const rail = try railOrder(arena, &wins, &shared);
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

    // T3606: while searching, a header closes only the windows it lists.
    const g_wins = [_]Window{
        .{ .name = "p: a", .key = 7, .opened = 1, .panes = &a_panes },
        .{ .name = "p: b", .key = 8, .opened = 2, .panes = &b_panes },
    };
    items = try build(arena, &g_wins, "htop", &shared, null);
    try testing.expectEqualStrings("PWp", kinds(items, &buf));
    try testing.expectEqualSlices(u64, &.{8}, items[0].members);

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

test "T3695: this window's own list is its header over its panes, its group's header above, folded on its own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var shared: Shared = .{};
    defer shared.deinit(testing.allocator);

    const two = [_]rows.Pane{ .{ .title = "vim" }, .{ .title = "make" } };
    const one = [_]rows.Pane{.{ .title = "sh" }};
    const wins = [_]Window{
        .{ .name = "notes", .key = 1, .opened = 1, .own = true, .panes = &two },
        .{ .name = "ghoztty: wt-2", .key = 2, .opened = 2, .panes = &one },
        .{ .name = "ghoztty: wt-10", .key = 3, .opened = 3, .panes = &one },
    };
    var buf: [32]u8 = undefined;

    // A lone window: its header (no Ungrouped over it), its panes a level
    // in, open; the header is not selected (the focused pane's row is).
    var items = try buildOwn(arena, &wins, 0, &shared, null);
    try testing.expectEqualStrings("Wpp", kinds(items, &buf));
    try testing.expectEqualStrings("notes", items[0].label);
    try testing.expectEqual(@as(usize, 2), items[0].count);
    try testing.expect(!items[0].folded);
    try testing.expectEqual(HeadSelection.none, items[0].selection);
    try testing.expectEqualSlices(u64, &.{1}, items[0].members);
    try testing.expectEqual(@as(u8, 1), items[1].depth);
    try testing.expectEqual(@as(usize, 1), items[2].pane);

    // Its fold is this list's own: folded here, the header carries the
    // selection, and all windows' folds are untouched by it.
    shared.toggleGroup(testing.allocator, false, 1);
    items = try buildOwn(arena, &wins, 0, &shared, null);
    try testing.expectEqualStrings("W", kinds(items, &buf));
    try testing.expect(items[0].folded);
    try testing.expectEqual(HeadSelection.accent, items[0].selection);
    _ = shared.setAllWindows(true);
    shared.toggleGroup(testing.allocator, true, 1);
    const every = try build(arena, &wins, null, &shared, null);
    try testing.expectEqualStrings("UWppPWW", kinds(every, &buf));
    _ = shared.setAllWindows(false);

    // A grouped window: the group's header above its own, which is labeled
    // by worktree; the group's header counts and closes the whole group.
    items = try buildOwn(arena, &wins, 2, &shared, null);
    try testing.expectEqualStrings("PWp", kinds(items, &buf));
    try testing.expectEqualStrings("ghoztty", items[0].label);
    try testing.expectEqual(@as(usize, 2), items[0].count);
    try testing.expectEqualSlices(u64, &.{ 2, 3 }, items[0].members);
    try testing.expectEqualStrings("wt-10", items[1].label);
    try testing.expectEqual(@as(u8, 1), items[1].depth);
    // A folded group is its header alone.
    shared.toggleProject(testing.allocator, items[0].key);
    items = try buildOwn(arena, &wins, 2, &shared, null);
    try testing.expectEqualStrings("P", kinds(items, &buf));
}

fn labels(items: []const Item, buf: []u8) []const u8 {
    var w: usize = 0;
    for (items) |it| {
        if (it.kind == .pane) continue;
        const l = it.label;
        @memcpy(buf[w..][0..l.len], l);
        w += l.len;
        buf[w] = ' ';
        w += 1;
    }
    return std.mem.trimRight(u8, buf[0..w], " ");
}

test "T3697: the list follows the stored order; what it never saw keeps its name place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var shared: Shared = .{};
    defer shared.deinit(testing.allocator);
    _ = shared.setAllWindows(true);
    const one = [_]rows.Pane{.{}};
    const wins = [_]Window{
        .{ .name = "a", .key = 0xa, .opened = 1, .panes = &one },
        .{ .name = "b", .key = 0xb, .opened = 2, .panes = &one },
        .{ .name = "p: x", .key = 0xc, .opened = 3, .panes = &one },
        .{ .name = "q: y", .key = 0xd, .opened = 4, .panes = &one },
    };
    var buf: [128]u8 = undefined;
    var items = try build(arena, &wins, null, &shared, null);
    try testing.expectEqualStrings("Ungrouped a b p x q y", labels(items, &buf));

    // Dragged: b above a, q above p.
    try testing.expect(shared.setWindowOrder(testing.allocator, &.{ "window:b", "window:a", "project:q", "project:p" }));
    items = try build(arena, &wins, null, &shared, null);
    try testing.expectEqualStrings("Ungrouped b a q y p x", labels(items, &buf));
    try testing.expectEqualSlices(usize, &.{ 1, 0, 3, 2 }, try railOrder(arena, &wins, &shared));
    // A window row carries its group; a project header its own name.
    try testing.expectEqualStrings("q", items[4].project.?);
    try testing.expect(items[1].project == null);

    // Every key once, by name; as shown, in the user's order.
    const every = try allOrderKeys(arena, &wins);
    try testing.expectEqual(@as(usize, 6), every.len);
    const shown = try shownOrderKeys(arena, &wins, &shared);
    try testing.expectEqualStrings("window:b", shown[0]);
    try testing.expectEqualStrings("project:q", shown[2]);
    try testing.expectEqualStrings("window:d", shown[3]);
}

/// The list `UWPWPW` (Ungrouped, lone, group a, its x, group b, its y), each
/// row 20 high, all folded - as a drag lays it out.
const folded_list = [_]Laid{
    .{ .kind = .ungrouped, .key = "ungrouped", .top = 0, .head_bottom = 20 },
    .{ .kind = .window, .key = "window:1", .top = 20, .head_bottom = 40 },
    .{ .kind = .project, .key = "project:a", .project = "a", .top = 40, .head_bottom = 60 },
    .{ .kind = .window, .key = "window:2", .project = "a", .top = 60, .head_bottom = 80 },
    .{ .kind = .project, .key = "project:b", .project = "b", .top = 80, .head_bottom = 100 },
    .{ .kind = .window, .key = "window:3", .project = "b", .top = 100, .head_bottom = 120 },
};
const folded_keys = [_][]const u8{ "window:1", "project:a", "window:2", "project:b", "window:3" };

test "T3697: a group header moves among the top level, never above the lone windows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // In a group drag only the groups fold: b's header is 80..100, its
    // window 100..120. Let go over a's header: b goes first of the groups.
    const groups = [_]Laid{ folded_list[0], folded_list[1], folded_list[2], folded_list[4] };
    var d = (try dropItem(arena, &groups, 100, "project:b", 45, &.{}, &folded_keys)).?;
    try testing.expectEqual(@as(usize, 1), d.index);
    try testing.expect(!d.regroup);
    try testing.expectEqualStrings("project:b", d.order[1]);
    try testing.expectEqualStrings("project:a", d.order[2]);
    // Held at the very top it still stops below the lone window.
    d = (try dropItem(arena, &groups, 100, "project:b", 0, &.{}, &folded_keys)).?;
    try testing.expectEqual(@as(usize, 1), d.index);
    // Let go where it was: nothing moves.
    d = (try dropItem(arena, &groups, 100, "project:b", 90, &.{}, &folded_keys)).?;
    try testing.expectEqual(@as(usize, 2), d.index);
    // The Ungrouped header and a stranger do not drag.
    try testing.expect((try dropItem(arena, &groups, 100, "ungrouped", 10, &.{}, &folded_keys)) == null);
    try testing.expect((try dropItem(arena, &groups, 100, "project:zz", 10, &.{}, &folded_keys)) == null);
}

test "T3697: a window row lands in a group, out of one, or among its own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The lone window let go low on a's x: into a, after x. Read against
    // the rows where they are drawn: its middle on x's middle is not past x.
    var d = (try dropItem(arena, &folded_list, 120, "window:1", 70, &.{}, &folded_keys)).?;
    try testing.expectEqual(@as(usize, 0), d.index);
    d = (try dropItem(arena, &folded_list, 120, "window:1", 78, &.{}, &folded_keys)).?;
    try testing.expect(d.regroup);
    try testing.expectEqualStrings("a", d.project.?);
    try testing.expectEqual(@as(usize, 1), d.index);
    // Its key now follows x's.
    var at_x: ?usize = null;
    var at_1: ?usize = null;
    for (d.order, 0..) |k, i| {
        if (std.mem.eql(u8, k, "window:2")) at_x = i;
        if (std.mem.eql(u8, k, "window:1")) at_1 = i;
    }
    try testing.expect(at_x.? < at_1.?);

    // a's x let go at the top of the list: out of its group, a lone window.
    d = (try dropItem(arena, &folded_list, 120, "window:2", 0, &.{}, &folded_keys)).?;
    try testing.expect(d.regroup);
    try testing.expect(d.project == null);
    try testing.expectEqual(@as(usize, 0), d.index);

    // b's y let go just under b's header: still b's, no rename.
    d = (try dropItem(arena, &folded_list, 120, "window:3", 110, &.{}, &folded_keys)).?;
    try testing.expect(!d.regroup);
    try testing.expectEqualStrings("b", d.project.?);

    // y let go past a's x: it joins a.
    d = (try dropItem(arena, &folded_list, 120, "window:3", 72, &.{}, &folded_keys)).?;
    try testing.expect(d.regroup);
    try testing.expectEqualStrings("a", d.project.?);
}
