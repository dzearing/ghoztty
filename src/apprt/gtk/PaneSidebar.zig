//! The pane sidebar on GTK (T3557, Linux L10b; docs/reference/pane-sidebar.md).
//!
//! A column at the window's leading edge that lists every pane of the
//! window's active tab - the Mac's per-window list (a Mac window is a tab
//! here, as on win32) - in tree order, the focused pane selected. A row names
//! its pane by its banner's title, else its title, with the working directory
//! under it (`pane_sidebar_rows.text`); clicking a row focuses that pane.
//!
//! Two modes, switched by ONE button at the top of the card: the full panel
//! (rows with their text) and the narrow rail (each row its icon alone, the
//! name in a tooltip), so the icons sit where they were. A window narrower
//! than the panel's breakpoint (720) shows the rail whatever the flag says,
//! and its button is off. `toggle_pane_sidebar` (Ctrl+Shift+S, Windows'
//! carry of the Mac's Ctrl+Cmd+S) hides and shows the whole column.
//!
//! The flags are ONE state shared by every window (Mac
//! `PaneSidebarSharedState`): a toggle in one window changes all of them. They
//! persist across launches in a small file under the config root, and
//! `macos-pane-sidebar` forces how they start (`remember` | `expanded` |
//! `collapsed` | `hidden`) without writing over the user's own choice - the
//! rules are win32's pure `pane_sidebar_prefs.StartState`.
//!
//! The header's scope button (expanded) widens the list to EVERY window
//! (T3558): an outline of windows - a tab of a GTK window is a window here,
//! as on win32 - grouped by `<project>: <worktree>`, each folded to its row
//! until unfolded, with a search field over it; the rail is one tile per
//! window. The rules are `pane_sidebar_all.zig`; the scope, its search and
//! the folds are one state every window shares (`scope`), so every window's
//! list redraws when any window's panes change while the scope is on.
//!
//! Parity is behavior and information, not pixels (docs/design/linux-port.md):
//! stock libadwaita widgets, no glide. Every window redraws for a shared
//! change at once rather than when it is next key - a GTK window lists a few
//! panes, and there is no per-frame cost to defer. Not here yet: drag to
//! reorder and the stash tray (T3607), group editing (T3608), a row's tools,
//! the hover tint and the busy sheen (T3606).
//!
//! GTK main thread only.
const PaneSidebar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const homedir = @import("../../os/homedir.zig");
const wk = @import("webkit.zig");
const rows = @import("pane_sidebar_rows.zig");
const all = @import("pane_sidebar_all.zig");
const search_cap = @import("../win32/pane_sidebar_search.zig").cap;
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Surface = @import("class/surface.zig").Surface;
const Tab = @import("class/tab.zig").Tab;

const log = std.log.scoped(.gtk_pane_sidebar);

const orientation_horizontal: c_int = 0;
const orientation_vertical: c_int = 1;
const pango_ellipsize_end: c_int = 3;
const align_start: c_int = 1;
const align_center: c_int = 3;
const policy_never: c_int = 2;
const policy_automatic: c_int = 1;

// ---------------------------------------------------------------------------
// The state every window shares

/// What every window's sidebar draws: the expanded and hidden flags and the
/// panel width.
pub var shared: rows.Prefs = .{};
/// The all-windows scope, its search and the folds (T3558; win32's
/// `pane_sidebar_shared.Shared`, Mac `PaneSidebarSharedState`): one state for
/// every window. `shared.all_windows` is the persisted choice it launches in.
pub var scope: all.Shared = .{};
/// `macos-pane-sidebar` against the user's own flags: what the file keeps.
var start_state: rows.StartState = .{};
var loaded = false;
var shared_alloc: Allocator = undefined;
/// When each listed window (a tab, by address) was first seen: namesakes
/// list in this order (Mac `openedOrder`). Pruned to the live tabs at every
/// gather, so a reused address starts over.
var opened: std.AutoHashMapUnmanaged(usize, u64) = .empty;
var opened_next: u64 = 0;

fn prefsPath(alloc: Allocator) ?[]u8 {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (homedir.home(&home_buf) catch null) orelse return null;
    return rows.prefsPath(alloc, build_config.is_debug, std.posix.getenv("XDG_CONFIG_HOME"), home) catch null;
}

/// Read the persisted flags once per process and start them as
/// `macos-pane-sidebar` says. Called before the first window draws its
/// sidebar, so a restored window starts as configured too.
pub fn loadShared(alloc: Allocator, start: configpkg.Config.MacPaneSidebar) void {
    if (loaded) return;
    if (prefsPath(alloc)) |p| {
        defer alloc.free(p);
        if (rows.load(p)) |prefs| shared = prefs;
    }
    start_state = .init(shared);
    shared_alloc = alloc;
    loaded = true;
    // The scope the app launches in: the persisted choice (all windows on a
    // first launch), every window folded, no search (Mac 8aefd0c91).
    scope.launchScope(shared.all_windows);
    log.info("pane sidebar scope at launch all_windows={}", .{shared.all_windows});
    _ = applyStart(start);
}

/// Start the sidebar as `macos-pane-sidebar` says: at launch, and on a config
/// change only when the value changed, so a reload never undoes the user's
/// toggles. True when the flags moved; every window then redraws.
pub fn applyStart(start: configpkg.Config.MacPaneSidebar) bool {
    if (!loaded) return false;
    const s = std.meta.stringToEnum(rows.Start, @tagName(start)) orelse .remember;
    const moved = start_state.apply(&shared, s);
    log.info("pane sidebar start={s} moved={} expanded={} hidden={}", .{ @tagName(s), moved, shared.expanded, shared.hidden });
    return moved;
}

/// The user set the flags (the button, the toggle shortcut): theirs, so they
/// are kept and written. Every mode change is logged with its cause - the
/// sidebar must never change mode on its own (pane-sidebar.md).
pub fn userSetFlags(alloc: Allocator, expanded: bool, hidden: bool, cause: []const u8) void {
    start_state.userSet(&shared, expanded, hidden);
    log.info("pane sidebar flags expanded={} hidden={} cause={s}", .{ expanded, hidden, cause });
    saveShared(alloc);
}

fn saveShared(alloc: Allocator) void {
    if (prefsPath(alloc)) |p| {
        defer alloc.free(p);
        rows.save(p, start_state.toSave(shared));
    }
}

/// The header's scope button: this window's panes or every window's, for
/// every window at once. On folds every window to its row; off forgets the
/// search and the folds (`Shared.setAllWindows`). The choice persists.
pub fn toggleScope(alloc: Allocator, cause: []const u8) void {
    _ = scope.setAllWindows(!scope.all_windows);
    shared.all_windows = scope.all_windows;
    saveShared(alloc);
    log.info("pane sidebar scope all_windows={} cause={s}", .{ scope.all_windows, cause });
    Window.refreshAllSidebars();
}

/// The search's text as typed (UTF-8), borrowed from `buf`.
pub fn query(buf: []u8) []const u8 {
    return scope.search.utf8(buf);
}

/// Replace the search's text (the field was edited, or the seam typed).
/// True when it changed; the caller redraws every window's list.
pub fn setQuery(text: []const u8) bool {
    var cur_buf: [search_cap * 3]u8 = undefined;
    if (std.mem.eql(u8, query(&cur_buf), text)) return false;
    var units: [search_cap]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&units, text[0..@min(text.len, search_cap)]) catch 0;
    _ = scope.search.clear();
    _ = scope.search.insert(units[0..n]);
    scope.searchEdited();
    log.info("pane sidebar search len={d}", .{text.len});
    return true;
}

/// A fold flipped (a window's chevron, a project header): every list.
fn toggleFold(kind: RowKind, key: u64) void {
    switch (kind) {
        .window => scope.toggleGroup(shared_alloc, true, key),
        .project, .ungrouped => scope.toggleProject(shared_alloc, key),
        else => return,
    }
    log.info("pane sidebar fold kind={s} key={x}", .{ @tagName(kind), key });
    Window.refreshAllSidebars();
}

// ---------------------------------------------------------------------------
// One window's sidebar

pub const RowKind = enum { pane, window, project, ungrouped, tile };

/// One drawn row: what the seam reports, and what a click does.
pub const Row = struct {
    sidebar: *PaneSidebar,
    /// The row's widget in the list.
    widget: *wk.GtkWidget,
    kind: RowKind = .pane,
    /// A pane's id; a header's or tile's `window:<key>`, `project:<name>`,
    /// `ungrouped`.
    id: []u8,
    /// A window's (tab's) address; a project's fold key.
    key: u64 = 0,
    label: [:0]u8,
    subtitle: ?[:0]u8 = null,
    tooltip: ?[:0]u8 = null,
    selected: bool = false,
    viewer: bool = false,
    count: usize = 0,
    folded: bool = false,
    depth: u8 = 0,
    selection: all.HeadSelection = .none,
};

alloc: Allocator,
window: *Window,
/// The card: a vertical box in the window's content row, before the tabs.
/// Owned by the widget tree.
card: *wk.GtkWidget,
toggle: *wk.GtkWidget,
title: *wk.GtkWidget,
count_label: *wk.GtkWidget,
scope_button: *wk.GtkWidget,
search: *wk.GtkWidget,
list: *wk.GtkWidget,
drawn: std.ArrayListUnmanaged(*Row) = .empty,
mode: rows.Mode = .mini,
window_width: i32 = 0,
/// How many windows the all-windows list gathered (its caption's count).
window_count: usize = 0,
idle: c_uint = 0,
/// Set while the field is written from the shared search, so its own
/// change signal is not taken for typing.
syncing_search: bool = false,

pub fn create(alloc: Allocator, window: *Window) Allocator.Error!*PaneSidebar {
    const self = try alloc.create(PaneSidebar);
    errdefer alloc.destroy(self);

    const card = wk.gtk_box_new(orientation_vertical, 2);
    wk.gtk_widget_add_css_class(card, "pane-sidebar");
    wk.gtk_widget_set_vexpand(card, 1);
    wk.gtk_widget_set_hexpand(card, 0);
    wk.gtk_widget_set_margin_start(card, rows.card_margin);
    wk.gtk_widget_set_margin_end(card, 0);
    wk.gtk_widget_set_margin_top(card, rows.card_margin);
    wk.gtk_widget_set_margin_bottom(card, rows.card_margin);
    wk.gtk_widget_set_focusable(card, 0);

    // The header: the mode button first, centred on the rail's width so it
    // does not move when toggled, then (expanded) the window's name.
    const header = wk.gtk_box_new(orientation_horizontal, 4);
    wk.gtk_widget_add_css_class(header, "pane-sidebar-header");
    const toggle = wk.gtk_button_new_from_icon_name("sidebar-show-symbolic");
    wk.gtk_widget_add_css_class(toggle, "flat");
    wk.gtk_widget_set_focus_on_click(toggle, 0);
    wk.gtk_widget_set_focusable(toggle, 0);
    wk.gtk_widget_set_size_request(toggle, rows.railCardWidth(), -1);
    _ = wk.g_signal_connect_data(toggle, "clicked", @ptrCast(&onToggleClicked), self, null, 0);
    wk.gtk_box_append(header, toggle);
    const title = wk.gtk_label_new("");
    wk.gtk_widget_add_css_class(title, "heading");
    wk.gtk_label_set_xalign(title, 0);
    wk.gtk_label_set_ellipsize(title, pango_ellipsize_end);
    wk.gtk_widget_set_hexpand(title, 1);
    wk.gtk_box_append(header, title);
    // All windows: how many, beside the caption.
    const count_label = wk.gtk_label_new("");
    wk.gtk_widget_add_css_class(count_label, "dim-label");
    wk.gtk_widget_add_css_class(count_label, "caption");
    wk.gtk_box_append(header, count_label);
    // The scope button at the trailing edge (the panel only).
    const scope_button = wk.gtk_button_new_from_icon_name("view-list-symbolic");
    wk.gtk_widget_add_css_class(scope_button, "flat");
    wk.gtk_widget_set_focus_on_click(scope_button, 0);
    wk.gtk_widget_set_focusable(scope_button, 0);
    _ = wk.g_signal_connect_data(scope_button, "clicked", @ptrCast(&onScopeClicked), self, null, 0);
    wk.gtk_box_append(header, scope_button);
    wk.gtk_box_append(card, header);

    // The all-windows search (the panel only). It takes the caret only when
    // clicked: a window's focus goes to its terminal, never here.
    const search = wk.gtk_search_entry_new();
    wk.gtk_search_entry_set_placeholder_text(search, "Search");
    wk.gtk_search_entry_set_search_delay(search, 0);
    wk.gtk_widget_set_focus_on_click(search, 1);
    wk.gtk_widget_add_css_class(search, "pane-sidebar-search");
    _ = wk.g_signal_connect_data(search, "search-changed", @ptrCast(&onSearchChanged), self, null, 0);
    _ = wk.g_signal_connect_data(search, "activate", @ptrCast(&onSearchActivate), self, null, 0);
    _ = wk.g_signal_connect_data(search, "stop-search", @ptrCast(&onSearchStop), self, null, 0);
    wk.gtk_box_append(card, search);

    const scroller = wk.gtk_scrolled_window_new();
    wk.gtk_scrolled_window_set_policy(scroller, policy_never, policy_automatic);
    wk.gtk_widget_set_vexpand(scroller, 1);
    const list = wk.gtk_box_new(orientation_vertical, 4);
    wk.gtk_widget_add_css_class(list, "pane-sidebar-list");
    wk.gtk_scrolled_window_set_child(scroller, list);
    wk.gtk_box_append(card, scroller);

    self.* = .{
        .alloc = alloc,
        .window = window,
        .card = card,
        .toggle = toggle,
        .title = title,
        .count_label = count_label,
        .scope_button = scope_button,
        .search = search,
        .list = list,
    };
    return self;
}

/// Free the struct. The card belongs to the widget tree and goes with it.
pub fn destroy(self: *PaneSidebar) void {
    if (self.idle != 0) _ = wk.g_source_remove(self.idle);
    self.idle = 0;
    self.clearRows();
    self.drawn.deinit(self.alloc);
    self.alloc.destroy(self);
}

/// Redraw on the next idle turn: a tab switch, a split, a focus change and
/// a title change often come together, and one redraw covers them.
pub fn queueRefresh(self: *PaneSidebar) void {
    if (self.idle != 0) return;
    self.idle = wk.g_idle_add(@ptrCast(&onIdle), self);
}

fn onIdle(self: *PaneSidebar) callconv(.c) c_int {
    self.idle = 0;
    self.refresh();
    return 0; // G_SOURCE_REMOVE
}

/// The window's width in logical pixels, or 0 before it is laid out.
fn currentWindowWidth(self: *PaneSidebar) i32 {
    const w: *wk.GtkWidget = @ptrCast(self.window);
    const allocated = wk.gtk_widget_get_width(w);
    if (allocated > 0) return allocated;
    var dw: c_int = 0;
    var dh: c_int = 0;
    self.window.as(gtk.Window).getDefaultSize(&dw, &dh);
    return dw;
}

fn clearRows(self: *PaneSidebar) void {
    for (self.drawn.items) |r| {
        wk.gtk_box_remove(self.list, r.widget);
        self.alloc.free(r.id);
        self.alloc.free(r.label);
        if (r.subtitle) |s| self.alloc.free(s);
        if (r.tooltip) |t| self.alloc.free(t);
        self.alloc.destroy(r);
    }
    self.drawn.clearRetainingCapacity();
}

/// Draw the sidebar as the shared flags, the window's width and the panes it
/// lists (this window's active tab, or every window's) now are.
pub fn refresh(self: *PaneSidebar) void {
    const ww = self.currentWindowWidth();
    self.window_width = ww;
    // A quick terminal (the drop-down) has no sidebar, as on the Mac: hidden
    // for that window only, the shared flags untouched.
    const m: rows.Mode = if (self.window.isQuickTerminal()) .hidden else rows.mode(shared, ww);
    if (m != self.mode) log.info("pane sidebar mode {s} -> {s} window_width={d}", .{ @tagName(self.mode), @tagName(m), ww });
    self.mode = m;

    wk.gtk_widget_set_visible(self.card, @intFromBool(m != .hidden));
    wk.gtk_widget_set_size_request(self.card, rows.cardWidth(m, shared), -1);
    const expanded = m == .expanded;
    const every = scope.all_windows;
    wk.gtk_widget_set_visible(self.title, @intFromBool(expanded));
    wk.gtk_widget_set_visible(self.count_label, @intFromBool(expanded and every));
    wk.gtk_widget_set_visible(self.scope_button, @intFromBool(expanded));
    wk.gtk_widget_set_tooltip_text(self.scope_button, if (every) "Show This Window's Panes" else "Show All Windows");
    if (every) wk.gtk_widget_add_css_class(self.scope_button, "pane-sidebar-scope-on") else wk.gtk_widget_remove_css_class(self.scope_button, "pane-sidebar-scope-on");
    wk.gtk_widget_set_visible(self.search, @intFromBool(expanded and every));
    self.syncSearchField();
    wk.gtk_widget_set_sensitive(self.toggle, @intFromBool(rows.canExpand(ww)));
    wk.gtk_widget_set_tooltip_text(self.toggle, if (expanded) "Collapse Sidebar" else "Expand Sidebar");
    if (every) {
        wk.gtk_label_set_text(self.title, "All Windows");
    } else {
        const wtitle = self.window.currentTitle();
        wk.gtk_label_set_text(self.title, if (wtitle) |t| t else "");
    }

    self.clearRows();
    if (m == .hidden) {
        self.dump();
        return;
    }

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = homedir.home(&home_buf) catch null;

    if (every) {
        self.refreshAll(expanded, home) catch |err| log.warn("pane sidebar all-windows rows failed err={}", .{err});
        self.dump();
        return;
    }

    const tab = self.window.getSelectedTab() orelse {
        self.dump();
        return;
    };
    const active = tab.getActiveSurface();
    const tree = tab.getSurfaceTree() orelse {
        self.dump();
        return;
    };
    var leaves: std.ArrayListUnmanaged(*Surface) = .empty;
    defer leaves.deinit(self.alloc);
    collectLeaves(self.alloc, tree, &leaves) catch {};
    for (leaves.items) |v| self.addPaneRow(v, v == active, expanded, home, 0) catch |err| {
        log.warn("pane sidebar row failed err={}", .{err});
        break;
    };
    self.dump();
}

/// The panes of a tree in reading order: a split's left (or top) side first
/// - the order `+list` walks, and the Mac's tree order. The node array itself
/// is in no spatial order.
fn collectLeaves(alloc: Allocator, tree: *const Surface.Tree, out: *std.ArrayListUnmanaged(*Surface)) Allocator.Error!void {
    if (tree.nodes.len == 0) return;
    try walk(alloc, tree, .root, out);
}

fn walk(alloc: Allocator, tree: *const Surface.Tree, h: Surface.Tree.Node.Handle, out: *std.ArrayListUnmanaged(*Surface)) Allocator.Error!void {
    switch (tree.nodes[h.idx()]) {
        .leaf => |v| try out.append(alloc, v),
        .split => |s| {
            try walk(alloc, tree, s.left, out);
            try walk(alloc, tree, s.right, out);
        },
    }
}

/// A pane's sidebar text inputs; a stacked strip is named by the same rule
/// (T3567, docs/reference/stacked-panes.md "Strip labels").
pub fn paneOf(surface: *Surface) rows.Pane {
    return .{
        .title = if (surface.getTitle()) |s| s else null,
        .title_override = surface.titleOverride(),
        .pwd = if (surface.getPwd()) |s| s else null,
        .banner = surface.getPaneBanner(),
        .viewer = surface.isViewer(),
    };
}

/// Every window of the all-windows list - each tab of each window, quick
/// terminals left out - with its panes, gathered into `arena`.
const Gathered = struct {
    windows: []all.Window,
    surfaces: []const []const *Surface,
    actives: []const ?*Surface,
};

fn gather(self: *PaneSidebar, arena: Allocator) Allocator.Error!Gathered {
    var windows: std.ArrayListUnmanaged(all.Window) = .empty;
    var surfaces: std.ArrayListUnmanaged([]const *Surface) = .empty;
    var actives: std.ArrayListUnmanaged(?*Surface) = .empty;
    var live: std.AutoHashMapUnmanaged(usize, void) = .empty;

    var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
    while (node) |n| {
        node = n.f_next;
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const win = gobject.ext.cast(Window, obj) orelse continue;
        // A window being disposed has dropped its sidebar: never reach into it.
        if (win.paneSidebar() == null) continue;
        if (win.isQuickTerminal()) continue;
        const tab_view = win.getTabView();
        const selected = tab_view.getSelectedPage();
        const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
        for (0..pages) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const key = @intFromPtr(tab);
            try live.put(arena, key, {});
            const seq = opened.get(key) orelse seq: {
                opened_next += 1;
                opened.put(shared_alloc, key, opened_next) catch {};
                break :seq opened_next;
            };
            var leaves: std.ArrayListUnmanaged(*Surface) = .empty;
            if (tab.getSurfaceTree()) |tree| try collectLeaves(arena, tree, &leaves);
            const panes = try arena.alloc(rows.Pane, leaves.items.len);
            for (leaves.items, panes) |v, *p| p.* = paneOf(v);
            const active = tab.getActiveSurface();
            const active_pwd: ?[]const u8 = if (active) |a| (if (a.getPwd()) |d| d else null) else null;
            const page_title = page.getTitle();
            try windows.append(arena, .{
                .name = try arena.dupe(u8, all.name(
                    win.titleOverride(),
                    if (tab.titleOverride()) |t| t else null,
                    std.mem.span(page_title),
                    active_pwd,
                )),
                .key = key,
                .opened = seq,
                .own = win == self.window and selected == page,
                .panes = panes,
            });
            try surfaces.append(arena, leaves.items);
            try actives.append(arena, active);
        }
    }

    // Forget the tabs that are gone.
    var stale: std.ArrayListUnmanaged(usize) = .empty;
    var it = opened.keyIterator();
    while (it.next()) |k| if (!live.contains(k.*)) try stale.append(arena, k.*);
    for (stale.items) |k| _ = opened.remove(k);

    return .{ .windows = windows.items, .surfaces = surfaces.items, .actives = actives.items };
}

/// The all-windows list: the outline (expanded) or a tile per window (the
/// rail).
fn refreshAll(self: *PaneSidebar, expanded: bool, home: ?[]const u8) Allocator.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const g = try self.gather(arena);
    self.window_count = g.windows.len;
    var cb: [16]u8 = undefined;
    const count_z = std.fmt.bufPrintZ(&cb, "{d}", .{g.windows.len}) catch "";
    wk.gtk_label_set_text(self.count_label, count_z);

    if (!expanded) {
        for (try all.railOrder(arena, g.windows)) |wi| try self.addWindowTile(g.windows[wi]);
        return;
    }

    var qb: [search_cap * 3]u8 = undefined;
    const q = query(&qb);
    const filtering = all.filters(q, true, true);
    const items = try all.build(arena, g.windows, if (filtering) q else null, &scope, home);
    for (items) |item| switch (item.kind) {
        .pane => {
            const v = g.surfaces[item.window][item.pane];
            const w = g.windows[item.window];
            try self.addPaneRow(v, w.own and g.actives[item.window] == v, true, home, item.depth);
        },
        else => try self.addHeadRow(item),
    };
}

/// A pane's row: its icon, and (expanded) its name with its directory under
/// it. Indented one step under its window in the all-windows outline.
fn addPaneRow(self: *PaneSidebar, surface: *Surface, selected: bool, expanded: bool, home: ?[]const u8, depth: u8) Allocator.Error!void {
    var lb: [rows.TEXT_BUF_LEN]u8 = undefined;
    var sb: [rows.TEXT_BUF_LEN]u8 = undefined;
    const viewer = surface.isViewer();
    const t = rows.text(paneOf(surface), home, &lb, &sb);

    const r = try self.alloc.create(Row);
    errdefer self.alloc.destroy(r);
    const pane_id = try self.alloc.dupe(u8, surface.paneId());
    errdefer self.alloc.free(pane_id);
    const label = try self.alloc.dupeZ(u8, t.label);
    errdefer self.alloc.free(label);
    const subtitle: ?[:0]u8 = if (t.subtitle) |s| try self.alloc.dupeZ(u8, s) else null;
    errdefer if (subtitle) |s| self.alloc.free(s);
    // The rail shows no text, so its tile names the pane in a tooltip.
    const tooltip: ?[:0]u8 = if (expanded)
        null
    else if (subtitle) |s|
        try std.fmt.allocPrintSentinel(self.alloc, "{s}\n{s}", .{ label, s }, 0)
    else
        try self.alloc.dupeZ(u8, label);

    const button = rowButton(selected, tooltip);
    const content = wk.gtk_box_new(orientation_horizontal, 8);
    // An outline pane sits one step in from its window's row (the only
    // indent the outline has; grouped windows line up with lone ones).
    if (depth > 0) wk.gtk_widget_set_margin_start(content, outline_indent);
    const icon = wk.gtk_image_new_from_icon_name(if (viewer) "text-x-generic-symbolic" else "utilities-terminal-symbolic");
    wk.gtk_widget_set_valign(icon, align_center);
    wk.gtk_box_append(content, icon);
    if (expanded) {
        wk.gtk_box_append(content, textBox(label, subtitle));
    } else {
        wk.gtk_widget_set_halign(content, align_center);
    }
    wk.gtk_button_set_child(button, content);

    r.* = .{
        .sidebar = self,
        .widget = button,
        .kind = .pane,
        .id = pane_id,
        .label = label,
        .subtitle = subtitle,
        .tooltip = tooltip,
        .selected = selected,
        .viewer = viewer,
        .depth = depth,
    };
    _ = wk.g_signal_connect_data(button, "clicked", @ptrCast(&onRowClicked), r, null, 0);
    try self.drawn.append(self.alloc, r);
    wk.gtk_box_append(self.list, button);
}

const outline_indent: c_int = 16;

fn rowButton(selected: bool, tooltip: ?[:0]const u8) *wk.GtkWidget {
    const button = wk.gtk_button_new();
    wk.gtk_widget_add_css_class(button, "flat");
    wk.gtk_widget_add_css_class(button, "pane-sidebar-row");
    if (selected) wk.gtk_widget_add_css_class(button, "pane-sidebar-selected");
    wk.gtk_widget_set_focus_on_click(button, 0);
    wk.gtk_widget_set_focusable(button, 0);
    if (tooltip) |tt| wk.gtk_widget_set_tooltip_text(button, tt);
    return button;
}

fn textBox(label: [:0]const u8, subtitle: ?[:0]const u8) *wk.GtkWidget {
    const text_box = wk.gtk_box_new(orientation_vertical, 0);
    wk.gtk_widget_set_hexpand(text_box, 1);
    const l1 = wk.gtk_label_new(label);
    wk.gtk_label_set_xalign(l1, 0);
    wk.gtk_label_set_ellipsize(l1, pango_ellipsize_end);
    wk.gtk_box_append(text_box, l1);
    if (subtitle) |s| {
        const l2 = wk.gtk_label_new(s);
        wk.gtk_label_set_xalign(l2, 0);
        wk.gtk_label_set_ellipsize(l2, pango_ellipsize_end);
        wk.gtk_widget_add_css_class(l2, "dim-label");
        wk.gtk_widget_add_css_class(l2, "caption");
        wk.gtk_box_append(text_box, l2);
    }
    return text_box;
}

/// A header row of the outline: a window (its fold chevron, then its name
/// and pane count, which raise it), a project or the Ungrouped header (one
/// button that folds it).
fn addHeadRow(self: *PaneSidebar, item: all.Item) Allocator.Error!void {
    const r = try self.alloc.create(Row);
    errdefer self.alloc.destroy(r);
    const kind: RowKind = switch (item.kind) {
        .window => .window,
        .project => .project,
        .ungrouped => .ungrouped,
        .pane => unreachable,
    };
    const id = switch (kind) {
        .window => try std.fmt.allocPrint(self.alloc, "window:{x}", .{item.key}),
        .project => try std.fmt.allocPrint(self.alloc, "project:{s}", .{item.label}),
        else => try self.alloc.dupe(u8, "ungrouped"),
    };
    errdefer self.alloc.free(id);
    const label = try self.alloc.dupeZ(u8, item.label);
    errdefer self.alloc.free(label);

    const row = wk.gtk_box_new(orientation_horizontal, 0);
    wk.gtk_widget_add_css_class(row, if (kind == .window) "pane-sidebar-window" else "pane-sidebar-project");
    switch (item.selection) {
        .accent => wk.gtk_widget_add_css_class(row, "pane-sidebar-selected"),
        .unemphasized => wk.gtk_widget_add_css_class(row, "pane-sidebar-current"),
        .none => {},
    }
    const chevron = wk.gtk_button_new_from_icon_name(if (item.folded) "pan-end-symbolic" else "pan-down-symbolic");
    wk.gtk_widget_add_css_class(chevron, "flat");
    wk.gtk_widget_set_focus_on_click(chevron, 0);
    wk.gtk_widget_set_focusable(chevron, 0);
    wk.gtk_widget_set_tooltip_text(chevron, if (item.folded) "Expand" else "Collapse");
    wk.gtk_box_append(row, chevron);

    var cb: [16]u8 = undefined;
    const count_z = std.fmt.bufPrintZ(&cb, "{d}", .{item.count}) catch "";
    if (kind == .window) {
        // The name raises the window; the chevron folds it.
        const button = rowButton(false, null);
        wk.gtk_widget_set_hexpand(button, 1);
        const content = wk.gtk_box_new(orientation_horizontal, 8);
        const l1 = wk.gtk_label_new(label);
        wk.gtk_label_set_xalign(l1, 0);
        wk.gtk_label_set_ellipsize(l1, pango_ellipsize_end);
        wk.gtk_widget_set_hexpand(l1, 1);
        wk.gtk_box_append(content, l1);
        const count = wk.gtk_label_new(count_z);
        wk.gtk_widget_add_css_class(count, "dim-label");
        wk.gtk_box_append(content, count);
        wk.gtk_button_set_child(button, content);
        wk.gtk_box_append(row, button);
        _ = wk.g_signal_connect_data(button, "clicked", @ptrCast(&onRowClicked), r, null, 0);
    } else {
        const l1 = wk.gtk_label_new(label);
        wk.gtk_widget_add_css_class(l1, "heading");
        wk.gtk_label_set_xalign(l1, 0);
        wk.gtk_label_set_ellipsize(l1, pango_ellipsize_end);
        wk.gtk_widget_set_hexpand(l1, 1);
        wk.gtk_box_append(row, l1);
        const count = wk.gtk_label_new(count_z);
        wk.gtk_widget_add_css_class(count, "dim-label");
        wk.gtk_box_append(row, count);
    }

    r.* = .{
        .sidebar = self,
        .widget = row,
        .kind = kind,
        .id = id,
        .key = item.key,
        .label = label,
        .count = item.count,
        .folded = item.folded,
        .depth = item.depth,
        .selection = item.selection,
        .selected = item.selection == .accent,
    };
    _ = wk.g_signal_connect_data(chevron, "clicked", @ptrCast(&onFoldClicked), r, null, 0);
    try self.drawn.append(self.alloc, r);
    wk.gtk_box_append(self.list, row);
}

/// The rail's tile for one window of the all-windows list: click raises it,
/// its tooltip is its full name, selected when it is this window.
fn addWindowTile(self: *PaneSidebar, w: all.Window) Allocator.Error!void {
    const r = try self.alloc.create(Row);
    errdefer self.alloc.destroy(r);
    const id = try std.fmt.allocPrint(self.alloc, "window:{x}", .{w.key});
    errdefer self.alloc.free(id);
    const label = try self.alloc.dupeZ(u8, w.name);
    errdefer self.alloc.free(label);
    const tooltip = try self.alloc.dupeZ(u8, w.name);
    errdefer self.alloc.free(tooltip);
    const button = rowButton(w.own, tooltip);
    const icon = wk.gtk_image_new_from_icon_name("window-restore-symbolic");
    wk.gtk_widget_set_halign(icon, align_center);
    wk.gtk_button_set_child(button, icon);
    r.* = .{
        .sidebar = self,
        .widget = button,
        .kind = .tile,
        .id = id,
        .key = w.key,
        .label = label,
        .tooltip = tooltip,
        .selected = w.own,
        .count = w.panes.len,
    };
    _ = wk.g_signal_connect_data(button, "clicked", @ptrCast(&onRowClicked), r, null, 0);
    try self.drawn.append(self.alloc, r);
    wk.gtk_box_append(self.list, button);
}

fn onRowClicked(_: *wk.GtkWidget, r: *Row) callconv(.c) void {
    switch (r.kind) {
        .pane => _ = r.sidebar.focusPane(r.id),
        .window, .tile => _ = raiseWindow(r.key),
        .project, .ungrouped => toggleFold(r.kind, r.key),
    }
}

fn onFoldClicked(_: *wk.GtkWidget, r: *Row) callconv(.c) void {
    toggleFold(r.kind, r.key);
}

/// The row with this id as drawn now (the seam's clicks).
pub fn rowById(self: *PaneSidebar, id: []const u8) ?*Row {
    for (self.drawn.items) |r| if (std.mem.eql(u8, r.id, id)) return r;
    return null;
}

/// A row's click, by id (the seam).
pub fn clickRow(self: *PaneSidebar, id: []const u8) bool {
    const r = self.rowById(id) orelse return false;
    onRowClicked(r.widget, r);
    return true;
}

/// A header's fold chevron, by id (the seam).
pub fn clickFold(self: *PaneSidebar, id: []const u8) bool {
    const r = self.rowById(id) orelse return false;
    if (r.kind == .pane or r.kind == .tile) return false;
    toggleFold(r.kind, r.key);
    return true;
}

/// Focus the pane with this id: in this window's active tab, or - from the
/// all-windows list - in any window, selecting its tab and raising its
/// window. False when no window holds it.
pub fn focusPane(self: *PaneSidebar, pane_id: []const u8) bool {
    var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
    while (node) |n| {
        node = n.f_next;
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const win = gobject.ext.cast(Window, obj) orelse continue;
        // A window being disposed has dropped its sidebar: never reach into it.
        if (win.paneSidebar() == null) continue;
        const tab_view = win.getTabView();
        const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
        for (0..pages) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const tree = tab.getSurfaceTree() orelse continue;
            var it = tree.iterator();
            while (it.next()) |entry| {
                if (!std.mem.eql(u8, entry.view.paneId(), pane_id)) continue;
                const here = win == self.window and tab_view.getSelectedPage() == page;
                log.info("pane sidebar row clicked pane={s} other_window={}", .{ pane_id, !here });
                tab.getSplitTree().focusSurface(entry.view);
                // Another window's (or tab's) pane: its own present request
                // selects its tab and raises its window.
                if (!here) entry.view.present();
                return true;
            }
        }
    }
    return false;
}

/// Bring the window (tab) with this key forward: select its tab and raise
/// its window. False when it is gone.
fn raiseWindow(key: u64) bool {
    var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
    while (node) |n| {
        node = n.f_next;
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const win = gobject.ext.cast(Window, obj) orelse continue;
        // A window being disposed has dropped its sidebar: never reach into it.
        if (win.paneSidebar() == null) continue;
        const tab_view = win.getTabView();
        const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
        for (0..pages) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            if (@intFromPtr(tab) != key) continue;
            log.info("pane sidebar window clicked key={x}", .{key});
            tab_view.setSelectedPage(page);
            win.as(gtk.Window).present();
            return true;
        }
    }
    return false;
}

fn onScopeClicked(_: *wk.GtkWidget, self: *PaneSidebar) callconv(.c) void {
    toggleScope(self.alloc, "button");
}

/// Show the shared search in this window's field (another window's typing,
/// or the scope turning off).
fn syncSearchField(self: *PaneSidebar) void {
    var qb: [search_cap * 3 + 1]u8 = undefined;
    const q = query(qb[0 .. qb.len - 1]);
    const cur = std.mem.span(wk.gtk_editable_get_text(self.search));
    if (std.mem.eql(u8, cur, q)) return;
    qb[q.len] = 0;
    self.syncing_search = true;
    defer self.syncing_search = false;
    wk.gtk_editable_set_text(self.search, qb[0..q.len :0]);
}

fn onSearchChanged(_: *wk.GtkWidget, self: *PaneSidebar) callconv(.c) void {
    if (self.syncing_search) return;
    const text = std.mem.span(wk.gtk_editable_get_text(self.search));
    if (setQuery(text)) Window.refreshAllSidebars();
}

/// Return in the field: the first pane it lists, as a click on it would.
fn onSearchActivate(_: *wk.GtkWidget, self: *PaneSidebar) callconv(.c) void {
    _ = self.searchReturn();
}

/// Escape in the field: clear the query; on an empty field, give the caret
/// back to the terminal.
fn onSearchStop(_: *wk.GtkWidget, self: *PaneSidebar) callconv(.c) void {
    self.searchEscape();
}

/// Return: focus the first pane the search lists. False when it lists none.
pub fn searchReturn(self: *PaneSidebar) bool {
    for (self.drawn.items) |r| if (r.kind == .pane) {
        log.info("pane sidebar search return pane={s}", .{r.id});
        return self.focusPane(r.id);
    };
    return false;
}

pub fn searchEscape(self: *PaneSidebar) void {
    if (setQuery("")) {
        Window.refreshAllSidebars();
        return;
    }
    const tab = self.window.getSelectedTab() orelse return;
    const active = tab.getActiveSurface() orelse return;
    log.info("pane sidebar search escape: caret back to the terminal", .{});
    tab.getSplitTree().focusSurface(active);
}

fn onToggleClicked(_: *wk.GtkWidget, self: *PaneSidebar) callconv(.c) void {
    self.toggleExpanded("button");
}

/// The header's button: expand or collapse every window's sidebar. Off in a
/// window too narrow for the panel.
pub fn toggleExpanded(self: *PaneSidebar, cause: []const u8) void {
    if (!rows.canExpand(self.currentWindowWidth())) return;
    userSetFlags(self.alloc, !shared.expanded, shared.hidden, cause);
    Window.refreshAllSidebars();
}

/// `toggle_pane_sidebar`: hide or show the sidebar in every window.
pub fn toggleHidden(alloc: Allocator, cause: []const u8) void {
    userSetFlags(alloc, shared.expanded, !shared.hidden, cause);
    Window.refreshAllSidebars();
}

/// What this sidebar shows, for the debug seam. Strings are borrowed from
/// the drawn rows until the next refresh.
pub fn report(self: *PaneSidebar, arena: Allocator) Allocator.Error!rows.Report {
    const out = try arena.alloc(rows.Report.Row, self.drawn.items.len);
    for (self.drawn.items, out) |r, *o| o.* = .{
        .pane = r.id,
        .label = r.label,
        .subtitle = r.subtitle,
        .label_shown = self.mode == .expanded,
        .tooltip = r.tooltip,
        .selected = r.selected,
        .kind = switch (r.kind) {
            .pane => if (r.viewer) "viewer" else "terminal",
            else => @tagName(r.kind),
        },
        .count = r.count,
        .folded = r.folded,
        .depth = r.depth,
        .selection = @tagName(r.selection),
    };
    var qb: [search_cap * 3]u8 = undefined;
    return .{
        .mode = @tagName(self.mode),
        .expanded = shared.expanded,
        .hidden = shared.hidden,
        .can_expand = rows.canExpand(self.window_width),
        .visible = wk.gtk_widget_get_visible(self.card) != 0,
        .width = rows.cardWidth(self.mode, shared),
        .window_width = self.window_width,
        .all_windows = scope.all_windows,
        .search = try arena.dupe(u8, query(&qb)),
        .search_shown = wk.gtk_widget_get_visible(self.search) != 0,
        .search_field = try arena.dupe(u8, std.mem.span(wk.gtk_editable_get_text(self.search))),
        .scope_button_shown = wk.gtk_widget_get_visible(self.scope_button) != 0,
        .window_count = if (scope.all_windows) self.window_count else 0,
        .title = try arena.dupe(u8, std.mem.span(wk.gtk_label_get_text(self.title))),
        .rows = out,
    };
}

/// Debug builds append one line per redraw to `$GHOZTTY_TEST_SIDEBAR_DUMP`
/// (`SIDEBAR <mode> rows=<n>`), so a script can wait for a redraw to land
/// before it asks the seam what is shown.
fn dump(self: *PaneSidebar) void {
    if (comptime !build_config.is_debug) return;
    const path = std.posix.getenv("GHOZTTY_TEST_SIDEBAR_DUMP") orelse return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch return;
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "SIDEBAR {s} rows={d}\n", .{ @tagName(self.mode), self.drawn.items.len }) catch return;
    f.writeAll(line) catch {};
}
