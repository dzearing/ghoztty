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
//! panes, and there is no per-frame cost to defer.
//!
//! Hovering a panel row shows its buttons (T3606): a pane of this window
//! offers - (stash) or the restore, then x; another window's pane the x
//! alone; a window row, a project and the Ungrouped header + then x where
//! the count was. The panel header has a + of its own (a new window). Every
//! close from here asks nothing and raises nothing, and runs on the next
//! main-loop turn; every + takes focus, as its keybind does.
//!
//! A pane row drags up and down to reorder its window's list (T3607): the
//! LIST only, never the grid - the order is the sidebar's own, one per
//! window (`orders`, win32 `pane_sidebar_order.moving` and `arranged`),
//! read against the tree at every draw, so a split lands beside its parent
//! and a closed pane drops out. The drag offers a private mime type of its
//! own, so a row never drops into a split tree, and it lands among its own
//! window's rows whichever window's list it is let go over. GTK draws its
//! own drag icon; the row following the pointer and the others sliding are
//! not ported (parity is behavior here, not the glide).
//!
//! Groups are edited from the list (T3608): a window row's right-click menu
//! (Create Group..., Move to Group, Remove from Group) and the Ungrouped
//! header's pencil, which open an in-place "Group name" field where a name
//! was. Each retitles windows `<group>: <name>` and pins the title as the
//! user's, the rules win32's pure `pane_sidebar_menu`/`pane_sidebar_rename`.
//!
//! A window always holds its panes (T3695): this window's list starts with
//! its header (chevron, name, count; + and x on hover) with its panes one
//! level in, under its group's header when it is in one, and its fold is the
//! list's own. The rail's first tile is a + standing in for what heads the
//! list: a new pane in Panes, a new window in all windows. The panel's
//! caption is "Panes" / "All Windows".
//!
//! In the expanded all-windows list a window row and a project header drag
//! too (T3697; win32 T2337/T2338): a group among the top level, a window
//! anywhere - into a group (retitled `<group>: <name>`, pinned) or out of
//! one. Picking one up folds every group (or every window) to its row, and
//! letting go puts the folds back. The order is the list's own
//! (`scope.window_order`, keys = the rows' ids), read over the name order
//! at every draw and kept in `pane-sidebar-order[-debug]` beside the flags;
//! its project keys survive a relaunch, its window keys (tab addresses) do
//! not (T3700). A group move from the menu keeps the list's place (win32
//! `keepWindowPlace`).
//!
//! Stashed panes sit in the tray, after the panes on screen, the top of the
//! stash first (T3698; Mac `PaneDropCandidate.Sidebar.trayTop`, win32
//! `pane_drop.sidebarHit`). This window's list draws the tray's head - a
//! hairline and "Stashed <n>" over the stash, or the empty tray's dashed well
//! - and the all-windows outline none: a window's stashed panes just follow
//! its others. A pane row let go at or below where the tray begins stashes
//! there, at that place in the stash (a stashed one moves within it, the last
//! pane on screen is refused); a tray row let go above it is restored,
//! focused, and placed in the list.
//!
//! Not here yet: a row dropped into another
//! window (T3699), and from T3606's
//! remainder rename in place, the hover tint, the busy sheen, the width grip
//! and hero-mode suppression.
//!
//! GTK main thread only.
const PaneSidebar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");

const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const homedir = @import("../../os/homedir.zig");
const wk = @import("webkit.zig");
const rows = @import("pane_sidebar_rows.zig");
const all = @import("pane_sidebar_all.zig");
const search_cap = @import("../win32/pane_sidebar_search.zig").cap;
const pane_stash = @import("../win32/pane_stash.zig");
const add_rules = @import("../win32/pane_sidebar_add.zig");
const sidebar_order = @import("../win32/pane_sidebar_order.zig");
const window_order = @import("../win32/pane_sidebar_window_order.zig");
const shared_mod = @import("../win32/pane_sidebar_shared.zig");
const rename_rules = @import("../win32/pane_sidebar_rename.zig");
const row_menu = @import("../win32/pane_sidebar_menu.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Surface = @import("class/surface.zig").Surface;
const Tab = @import("class/tab.zig").Tab;
const Workspaces = @import("Workspaces.zig");

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
/// Every window's own pane order (T3607), by tab address.
var orders: rows.Orders = .{};

/// A sidebar row's drag offers this, and only a sidebar list takes it: a
/// row dragged in the list only ever rearranges (Mac
/// `PaneDragSession.isListDrag`), so no split tree or terminal accepts it.
const row_mime: [:0]const u8 = "application/x-ghoztty-sidebar-row";
/// The pane whose row is being dragged (GTK runs one pointer drag at a
/// time), or empty.
var row_drag_buf: [64 + 4 * 64]u8 = undefined;
var row_drag_len: usize = 0;

/// A window row or project header picked up (T3697): the folds it took, put
/// back when it is let go (`endLift`).
const Lift = struct {
    which: enum { projects, windows },
    before: shared_mod.KeySet,
};
var lift: ?Lift = null;

fn prefsPath(alloc: Allocator) ?[]u8 {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (homedir.home(&home_buf) catch null) orelse return null;
    return rows.prefsPath(alloc, build_config.is_debug, std.posix.getenv("XDG_CONFIG_HOME"), home) catch null;
}

fn orderPath(alloc: Allocator) ?[]u8 {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (homedir.home(&home_buf) catch null) orelse return null;
    return rows.orderPath(alloc, build_config.is_debug, std.posix.getenv("XDG_CONFIG_HOME"), home) catch null;
}

/// The all-windows list's stored order (T3697), less its window keys: a
/// window's key is its tab's address, which a relaunch does not keep (T3700).
fn loadWindowOrder(alloc: Allocator) void {
    const p = orderPath(alloc) orelse return;
    defer alloc.free(p);
    const f = std.fs.cwd().openFile(p, .{}) catch return;
    defer f.close();
    const text = f.readToEndAlloc(alloc, 1 << 20) catch return;
    defer alloc.free(text);
    var keys: [window_order.max_keys][]const u8 = undefined;
    const n = window_order.parse(text, &keys);
    var kept: [window_order.max_keys][]const u8 = undefined;
    var m: usize = 0;
    for (keys[0..n]) |k| if (window_order.isProject(k)) {
        kept[m] = k;
        m += 1;
    };
    _ = scope.setWindowOrder(alloc, kept[0..m]);
    log.info("pane sidebar window order loaded keys={d} kept={d}", .{ n, m });
}

/// Store the all-windows list's order. Best-effort.
fn saveWindowOrder(alloc: Allocator) void {
    const p = orderPath(alloc) orelse return;
    defer alloc.free(p);
    var buf: [window_order.max_keys][]const u8 = undefined;
    const keys = scope.windowOrder(&buf);
    if (std.fs.path.dirname(p)) |dir| std.fs.cwd().makePath(dir) catch return;
    const f = std.fs.cwd().createFile(p, .{ .truncate = true }) catch return;
    defer f.close();
    var wbuf: [1024]u8 = undefined;
    var w = f.writer(&wbuf);
    window_order.format(&w.interface, keys) catch return;
    w.interface.flush() catch {};
}

/// Make `keys` the list's order, stored and drawn in every window.
fn setWindowOrder(keys: []const []const u8, cause: []const u8) void {
    if (scope.setWindowOrder(shared_alloc, keys)) saveWindowOrder(shared_alloc);
    log.info("pane sidebar window order keys={d} cause={s}", .{ keys.len, cause });
    Window.queueAllSidebarRefresh();
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
    loadWindowOrder(alloc);
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
        // In the list it is drawn in: this window's own header folds in
        // `folded_this`, an all-windows row in the outline's (T3695).
        .window => scope.toggleGroup(shared_alloc, scope.all_windows, key),
        .project, .ungrouped => scope.toggleProject(shared_alloc, key),
        else => return,
    }
    log.info("pane sidebar fold kind={s} key={x}", .{ @tagName(kind), key });
    Window.refreshAllSidebars();
}

// ---------------------------------------------------------------------------
// One window's sidebar

/// `rail_add`: the rail's + at the top of the list (T3695). `tray`: this
/// window's stash tray head (T3698) - the hairline and "Stashed" caption over
/// its stashed panes, or the empty tray's well - the top of the tray.
pub const RowKind = enum { pane, window, project, ungrouped, tile, rail_add, tray };
pub const Tool = rows.Tool;

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
    /// A pane out of its window's layout (T3596): dimmed, and a click
    /// brings it back to its slot and focuses it (Mac's stashed-row click).
    stashed: bool = false,
    count: usize = 0,
    folded: bool = false,
    depth: u8 = 0,
    selection: all.HeadSelection = .none,
    /// A pane of the window (active tab) this sidebar is drawn in.
    own: bool = false,
    /// The buttons hovering offers (T3606), and the box that holds them:
    /// hidden until the pointer is over the row.
    tools: []const rows.Tool = &.{},
    tools_box: ?*wk.GtkWidget = null,
    /// A header's count, which its buttons take the place of on hover.
    count_widget: ?*wk.GtkWidget = null,
    hovered: bool = false,
    /// A header's windows (tab keys), what its x closes; owned.
    members: []const u64 = &.{},
    /// A pane row's window (its tab, by address): the rows it reorders among.
    tab: usize = 0,
    /// A pane row drags to reorder (T3607): a pane on screen. A window row
    /// and a project header of the expanded all-windows list do too (T3697).
    draggable: bool = false,
    /// A window row's group, a project header's name; owned (T3697).
    project: ?[]u8 = null,
};

alloc: Allocator,
window: *Window,
/// The card: a vertical box in the window's content row, before the tabs.
/// Owned by the widget tree.
card: *wk.GtkWidget,
toggle: *wk.GtkWidget,
title: *wk.GtkWidget,
count_label: *wk.GtkWidget,
/// The panel header's + (T3606): a new window, as Ctrl+Shift+N.
add_button: *wk.GtkWidget,
scope_button: *wk.GtkWidget,
search: *wk.GtkWidget,
/// The id of the row under the pointer, kept across a redraw (the rows are
/// rebuilt, the pointer has not moved); null when none is.
hover_id: ?[]u8 = null,
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
/// A window row's right-click menu (T3608): the popover while it is up
/// (parented to the card, which outlives every redraw), and what it was
/// opened on - the window's key and row id and the groups its Move to Group
/// listed, owned until the next menu - so a pick acts on what was shown.
menu_pop: ?*wk.GtkWidget = null,
menu_key: u64 = 0,
menu_row: ?[]u8 = null,
menu_groups: std.ArrayListUnmanaged([]u8) = .empty,
menu_remove: bool = false,
/// The in-place field naming a group (T3608), kept across redraws: a redraw
/// draws it again with what was typed, and gives it the caret back.
edit: ?Edit = null,
edit_focus_idle: c_uint = 0,
/// Set while the rows are torn down, so the field losing the caret to its
/// own removal is not taken for the user clicking away.
clearing: bool = false,

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
    // The + left of the scope button (the panel only, T3606): a new window.
    const add_button = wk.gtk_button_new_from_icon_name("list-add-symbolic");
    wk.gtk_widget_add_css_class(add_button, "flat");
    wk.gtk_widget_set_focus_on_click(add_button, 0);
    wk.gtk_widget_set_focusable(add_button, 0);
    wk.gtk_widget_set_tooltip_text(add_button, rows.toolTip(.add, false));
    _ = wk.g_signal_connect_data(add_button, "clicked", @ptrCast(&onHeaderAddClicked), self, null, 0);
    wk.gtk_box_append(header, add_button);
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
    // Rows dropped on the list reorder it (T3607). The list outlives every
    // redraw, so one target serves each row drawn into it; its signals are
    // connected once `self` is filled in, below.
    const row_types = [_][*:0]const u8{row_mime.ptr};
    const drop_target = wk.gtk_drop_target_async_new(wk.gdk_content_formats_new(&row_types, row_types.len), wk.gdk_action_move);
    wk.gtk_widget_add_controller(list, drop_target);
    wk.gtk_scrolled_window_set_child(scroller, list);
    wk.gtk_box_append(card, scroller);

    self.* = .{
        .alloc = alloc,
        .window = window,
        .card = card,
        .toggle = toggle,
        .title = title,
        .count_label = count_label,
        .add_button = add_button,
        .scope_button = scope_button,
        .search = search,
        .list = list,
    };
    _ = wk.g_signal_connect_data(drop_target, "accept", @ptrCast(&onListAccept), self, null, 0);
    _ = wk.g_signal_connect_data(drop_target, "drag-enter", @ptrCast(&onListMotion), self, null, 0);
    _ = wk.g_signal_connect_data(drop_target, "drag-motion", @ptrCast(&onListMotion), self, null, 0);
    _ = wk.g_signal_connect_data(drop_target, "drop", @ptrCast(&onListDrop), self, null, 0);
    _ = wk.g_signal_connect_data(drop_target, "drag-leave", @ptrCast(&onListLeave), self, null, 0);
    return self;
}

/// Free the struct. The card belongs to the widget tree and goes with it.
pub fn destroy(self: *PaneSidebar) void {
    if (self.idle != 0) _ = wk.g_source_remove(self.idle);
    self.idle = 0;
    if (self.edit_focus_idle != 0) _ = wk.g_source_remove(self.edit_focus_idle);
    self.edit_focus_idle = 0;
    self.edit = null;
    self.clearRows();
    self.drawn.deinit(self.alloc);
    if (self.hover_id) |h| self.alloc.free(h);
    self.freeMenuState();
    self.menu_groups.deinit(self.alloc);
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
    self.clearing = true;
    defer self.clearing = false;
    if (self.edit) |*e| e.entry = null;
    for (self.drawn.items) |r| {
        wk.gtk_box_remove(self.list, r.widget);
        self.alloc.free(r.id);
        self.alloc.free(r.label);
        if (r.subtitle) |s| self.alloc.free(s);
        if (r.tooltip) |t| self.alloc.free(t);
        if (r.members.len > 0) self.alloc.free(r.members);
        if (r.project) |pj| self.alloc.free(pj);
        self.alloc.destroy(r);
    }
    self.drawn.clearRetainingCapacity();
}

/// Draw the sidebar as the shared flags, the window's width and the panes it
/// lists (this window's active tab, or every window's) now are.
pub fn refresh(self: *PaneSidebar) void {
    self.redraw();
    self.settleEdit();
}

fn redraw(self: *PaneSidebar) void {
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
    wk.gtk_widget_set_visible(self.add_button, @intFromBool(expanded));
    wk.gtk_widget_set_tooltip_text(self.scope_button, if (every) "Show This Window's Panes" else "Show All Windows");
    if (every) wk.gtk_widget_add_css_class(self.scope_button, "pane-sidebar-scope-on") else wk.gtk_widget_remove_css_class(self.scope_button, "pane-sidebar-scope-on");
    wk.gtk_widget_set_visible(self.search, @intFromBool(expanded and every));
    self.syncSearchField();
    wk.gtk_widget_set_sensitive(self.toggle, @intFromBool(rows.canExpand(ww)));
    wk.gtk_widget_set_tooltip_text(self.toggle, if (expanded) "Collapse Sidebar" else "Expand Sidebar");
    // The caption names the list (win32 "PANES" / "ALL WINDOWS"): this
    // window's name is its header row's now (T3695).
    wk.gtk_label_set_text(self.title, if (every) "All Windows" else "Panes");

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

    if (expanded) {
        // This window's header over its panes (T3695).
        if (self.refreshOwn(home)) |_| {
            self.dump();
            return;
        } else |err| log.warn("pane sidebar own header rows failed err={}", .{err});
        self.clearRows();
    }

    const tab = self.window.getSelectedTab() orelse {
        self.dump();
        return;
    };
    // The rail: the window header's + alone, in its slot, then a tile per
    // pane (T3695).
    if (!expanded) self.addRailAdd() catch |err| log.warn("pane sidebar rail + failed err={}", .{err});
    const active = tab.getActiveSurface();
    const tree = tab.getSurfaceTree() orelse {
        self.dump();
        return;
    };
    var leaves: std.ArrayListUnmanaged(*Surface) = .empty;
    defer leaves.deinit(self.alloc);
    collectLeaves(self.alloc, tree, &leaves) catch {};
    const tab_key = @intFromPtr(tab);
    arrangeLeaves(tab_key, leaves.items);
    trayLeaves(leaves.items);
    // The tray's head goes over the first stashed tile, or (none) after the
    // last tile as the empty well (T3698).
    const stashed_n = stashedCount(leaves.items);
    var headed = false;
    for (leaves.items) |v| {
        if (!headed and pane_stash.isStashed(v)) {
            headed = true;
            self.addTrayRow(tab_key, stashed_n, expanded) catch |err| log.warn("pane sidebar tray failed err={}", .{err});
        }
        self.addPaneRow(v, v == active, expanded, home, 0, true, tab_key) catch |err| {
            log.warn("pane sidebar row failed err={}", .{err});
            break;
        };
    }
    if (!headed and leaves.items.len > 0) self.addTrayRow(tab_key, 0, expanded) catch |err| log.warn("pane sidebar tray failed err={}", .{err});
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
    /// Each list window's GTK window and tab, parallel to `windows`.
    found: []const FoundTab,
};

fn gather(self: *PaneSidebar, arena: Allocator) Allocator.Error!Gathered {
    return gatherFor(self.window, arena);
}

/// `gather` with `own` as the window the list is drawn in (null: none is).
fn gatherFor(own: ?*Window, arena: Allocator) Allocator.Error!Gathered {
    var windows: std.ArrayListUnmanaged(all.Window) = .empty;
    var surfaces: std.ArrayListUnmanaged([]const *Surface) = .empty;
    var actives: std.ArrayListUnmanaged(?*Surface) = .empty;
    var found: std.ArrayListUnmanaged(FoundTab) = .empty;
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
            arrangeLeaves(key, leaves.items);
            trayLeaves(leaves.items);
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
                .own = if (own) |o| win == o and selected == page else false,
                .panes = panes,
            });
            try surfaces.append(arena, leaves.items);
            try actives.append(arena, active);
            try found.append(arena, .{ .win = win, .tab = tab });
        }
    }

    // Forget the tabs that are gone.
    var stale: std.ArrayListUnmanaged(usize) = .empty;
    var it = opened.keyIterator();
    while (it.next()) |k| if (!live.contains(k.*)) try stale.append(arena, k.*);
    for (stale.items) |k| _ = opened.remove(k);

    return .{ .windows = windows.items, .surfaces = surfaces.items, .actives = actives.items, .found = found.items };
}

/// The all-windows list's windows (GTK window + tab) in the list's order,
/// headers left out (`all.railOrder`, the order the outline draws them in):
/// what goto_tab and goto_window walk in single-window mode (T3649; Mac
/// `TerminalController.sidebarOrder`, win32 `PaneSidebar.allWindowsOrder`).
pub fn listOrder(arena: Allocator) Allocator.Error![]const FoundTab {
    if (!loaded) return &.{};
    const g = try gatherFor(null, arena);
    const at = try all.railOrder(arena, g.windows, &scope);
    const out = try arena.alloc(FoundTab, at.len);
    for (at, out) |i, *o| o.* = g.found[i];
    return out;
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
        // The panel header's + stands over the tiles (T3695): a new window.
        try self.addRailAdd();
        for (try all.railOrder(arena, g.windows, &scope)) |wi| try self.addWindowTile(g.windows[wi]);
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
            try self.addPaneRow(v, w.own and g.actives[item.window] == v, true, home, item.depth, w.own, w.key);
        },
        // A window row and a project header drag (T3697); the Ungrouped
        // header stays on top.
        else => try self.addHeadRow(item, item.kind != .ungrouped),
    };
}

/// This window's own list, expanded (T3695; docs/reference/pane-sidebar.md
/// "Rows and tiles": a window always holds its panes): its header - chevron,
/// name and count, + and x on hover - with its panes one level in under it,
/// and above it its group's header when it is a `<project>: <name>` window.
/// `all.buildOwn` decides; the rows are drawn as all windows draws them.
fn refreshOwn(self: *PaneSidebar, home: ?[]const u8) error{ OutOfMemory, NotListed }!void {
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const g = try self.gather(arena);
    const own = for (g.windows, 0..) |w, i| {
        if (w.own) break i;
    } else return error.NotListed;
    const items = try all.buildOwn(arena, g.windows, own, &scope, home);
    // The tray (T3698): its head over this window's first stashed pane, or
    // after its last pane as the empty well; none while the window is folded.
    const stashed_n = stashedCount(g.surfaces[own]);
    var headed = false;
    var panes_drawn: usize = 0;
    for (items) |item| switch (item.kind) {
        .pane => {
            const v = g.surfaces[item.window][item.pane];
            const w = g.windows[item.window];
            if (!headed and item.window == own and pane_stash.isStashed(v)) {
                headed = true;
                try self.addTrayRow(w.key, stashed_n, true);
            }
            try self.addPaneRow(v, g.actives[item.window] == v, true, home, item.depth, true, w.key);
            if (item.window == own) panes_drawn += 1;
        },
        // This window's own list does not reorder the all-windows one.
        else => try self.addHeadRow(item, false),
    };
    if (!headed and panes_drawn > 0) try self.addTrayRow(g.windows[own].key, 0, true);
}

/// The rail's + (T3695; Mac `PaneSidebarRailAddSlot`): the first tile of the
/// rail, the stand-in for what heads the list - this window's header (a new
/// pane) in Panes, the panel header (a new window) in all windows - so the
/// tiles under it sit where the rows they are sit expanded.
fn addRailAdd(self: *PaneSidebar) Allocator.Error!void {
    const r = try self.alloc.create(Row);
    errdefer self.alloc.destroy(r);
    const id = try self.alloc.dupe(u8, rail_add_id);
    errdefer self.alloc.free(id);
    // The tip of the + it stands in for (a window row's, the panel header's).
    const tip = rows.toolTip(.add, add_rules.railAdd(scope.all_windows) == .new_pane);
    const label = try self.alloc.dupeZ(u8, tip);
    errdefer self.alloc.free(label);
    const tooltip = try self.alloc.dupeZ(u8, tip);
    errdefer self.alloc.free(tooltip);
    const button = rowButton(false, tooltip);
    wk.gtk_widget_add_css_class(button, "pane-sidebar-rail-add");
    const icon = wk.gtk_image_new_from_icon_name("list-add-symbolic");
    wk.gtk_widget_set_halign(icon, align_center);
    wk.gtk_button_set_child(button, icon);
    r.* = .{
        .sidebar = self,
        .widget = button,
        .kind = .rail_add,
        .id = id,
        .label = label,
        .tooltip = tooltip,
    };
    _ = wk.g_signal_connect_data(button, "clicked", @ptrCast(&onRowClicked), r, null, 0);
    try self.drawn.append(self.alloc, r);
    wk.gtk_box_append(self.list, button);
}

/// The rail +'s row id (the seam's `--click=rail-add`).
pub const rail_add_id = "rail-add";

/// The tray head's row id (T3698): one per sidebar, this window's.
pub const tray_id = "tray";

/// Put a window's panes, already in the sidebar's order, in the order it
/// draws them: the ones on screen, then the stash, top first (T3698,
/// `rows.trayed`).
fn trayLeaves(leaves: []*Surface) void {
    const n = @min(leaves.len, sidebar_order.max_ids);
    var seqs: [sidebar_order.max_ids]u64 = undefined;
    var was: [sidebar_order.max_ids]*Surface = undefined;
    for (leaves[0..n], 0..) |v, i| {
        seqs[i] = v.stash_seq;
        was[i] = v;
    }
    var idx: [sidebar_order.max_ids]usize = undefined;
    const m = rows.trayed(seqs[0..n], &idx);
    for (idx[0..m], 0..) |vi, i| leaves[i] = was[vi];
}

fn stashedCount(leaves: []const *Surface) usize {
    var n: usize = 0;
    for (leaves) |v| {
        if (pane_stash.isStashed(v)) n += 1;
    }
    return n;
}

/// This window's tray head (T3698; docs/reference/pane-sidebar.md "Rows and
/// tiles"): with panes stashed, a hairline and (the panel) the "Stashed"
/// caption with their count, over them; with none, the empty tray's well - a
/// faint dashed slot with the stash glyph and (the panel) "Drag a pane here
/// to stash it" - still a place to drop. It is where the tray begins: a row
/// let go on it or below it stashes (`dropRowAt`). Not a button.
fn addTrayRow(self: *PaneSidebar, tab_key: usize, stashed_n: usize, expanded: bool) Allocator.Error!void {
    const r = try self.alloc.create(Row);
    errdefer self.alloc.destroy(r);
    const id = try self.alloc.dupe(u8, tray_id);
    errdefer self.alloc.free(id);
    const label = try self.alloc.dupeZ(u8, if (stashed_n > 0) rows.tray_caption else rows.tray_well_label);
    errdefer self.alloc.free(label);
    const tooltip: ?[:0]u8 = if (expanded or stashed_n > 0) null else try self.alloc.dupeZ(u8, rows.tray_well_label);
    errdefer if (tooltip) |t| self.alloc.free(t);

    const box = wk.gtk_box_new(orientation_vertical, 2);
    wk.gtk_widget_add_css_class(box, "pane-sidebar-tray");
    if (tooltip) |t| wk.gtk_widget_set_tooltip_text(box, t);
    if (stashed_n > 0) {
        wk.gtk_widget_add_css_class(box, "pane-sidebar-tray-head");
        wk.gtk_box_append(box, wk.gtk_separator_new(orientation_horizontal));
        if (expanded) {
            const line = wk.gtk_box_new(orientation_horizontal, 6);
            const cap = wk.gtk_label_new(label);
            wk.gtk_label_set_xalign(cap, 0);
            wk.gtk_widget_set_hexpand(cap, 1);
            wk.gtk_widget_add_css_class(cap, "caption-heading");
            wk.gtk_widget_add_css_class(cap, "dim-label");
            wk.gtk_box_append(line, cap);
            var cb: [16]u8 = undefined;
            const count_z = std.fmt.bufPrintZ(&cb, "{d}", .{stashed_n}) catch "";
            const count = wk.gtk_label_new(count_z.ptr);
            wk.gtk_widget_add_css_class(count, "caption");
            wk.gtk_widget_add_css_class(count, "dim-label");
            wk.gtk_box_append(line, count);
            wk.gtk_widget_add_css_class(line, "pane-sidebar-tray-caption");
            wk.gtk_box_append(box, line);
        }
    } else {
        wk.gtk_widget_add_css_class(box, "pane-sidebar-tray-well");
        const line = wk.gtk_box_new(orientation_horizontal, 8);
        const icon = wk.gtk_image_new_from_icon_name("list-remove-symbolic");
        wk.gtk_widget_set_valign(icon, align_center);
        wk.gtk_box_append(line, icon);
        if (expanded) {
            const words = wk.gtk_label_new(label);
            wk.gtk_label_set_xalign(words, 0);
            wk.gtk_label_set_ellipsize(words, pango_ellipsize_end);
            wk.gtk_widget_set_hexpand(words, 1);
            wk.gtk_widget_add_css_class(words, "caption");
            wk.gtk_box_append(line, words);
        } else {
            wk.gtk_widget_set_halign(line, align_center);
        }
        wk.gtk_box_append(box, line);
    }
    r.* = .{
        .sidebar = self,
        .widget = box,
        .kind = .tray,
        .id = id,
        .key = tab_key,
        .label = label,
        .tooltip = tooltip,
        .count = stashed_n,
        .own = true,
        .tab = tab_key,
    };
    try self.drawn.append(self.alloc, r);
    wk.gtk_box_append(self.list, box);
}

/// A pane's row: its icon, and (expanded) its name with its directory under
/// it. Indented one step under its window in the all-windows outline.
fn addPaneRow(self: *PaneSidebar, surface: *Surface, selected: bool, expanded: bool, home: ?[]const u8, depth: u8, own: bool, tab: usize) Allocator.Error!void {
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
    const stashed = pane_stash.isStashed(surface);
    if (stashed) wk.gtk_widget_add_css_class(button, "pane-sidebar-stashed");
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

    // The row: the button that focuses the pane, then (the panel) the
    // buttons hovering shows at its trailing edge (T3606). Siblings, not
    // children: a button inside a button would take the row's click.
    const outer = wk.gtk_box_new(orientation_horizontal, 2);
    wk.gtk_widget_add_css_class(outer, "pane-sidebar-item");
    wk.gtk_widget_set_hexpand(button, 1);
    wk.gtk_box_append(outer, button);

    r.* = .{
        .sidebar = self,
        .widget = outer,
        .kind = .pane,
        .id = pane_id,
        .label = label,
        .subtitle = subtitle,
        .tooltip = tooltip,
        .selected = selected,
        .viewer = viewer,
        .stashed = stashed,
        .depth = depth,
        .own = own,
        .tools = rows.paneTools(expanded, own, stashed),
        .tab = tab,
        // A stashed pane's row drags too (T3698): up into the list it is
        // restored, within the tray it moves in the stash.
        .draggable = true,
    };
    _ = wk.g_signal_connect_data(button, "clicked", @ptrCast(&onRowClicked), r, null, 0);
    if (r.draggable) addRowDragSource(r, button);
    self.addTools(r, outer, false);
    try self.drawn.append(self.alloc, r);
    wk.gtk_box_append(self.list, outer);
}

/// The row's hover buttons (`r.tools`), in a box at the end of `row` that
/// stays hidden until the pointer is over the row, and the pointer tracking
/// that shows it. `window_row`: a window header (its + adds a pane).
fn addTools(self: *PaneSidebar, r: *Row, row: *wk.GtkWidget, window_row: bool) void {
    const motion = wk.gtk_event_controller_motion_new();
    _ = wk.g_signal_connect_data(motion, "enter", @ptrCast(&onRowEnter), r, null, 0);
    _ = wk.g_signal_connect_data(motion, "leave", @ptrCast(&onRowLeave), r, null, 0);
    wk.gtk_widget_add_controller(row, motion);
    if (r.tools.len == 0) return;

    const box = wk.gtk_box_new(orientation_horizontal, 0);
    wk.gtk_widget_add_css_class(box, "pane-sidebar-tools");
    wk.gtk_widget_set_valign(box, align_center);
    for (r.tools) |t| {
        const b = wk.gtk_button_new_from_icon_name(switch (t) {
            .stash => "list-remove-symbolic",
            .restore => "edit-undo-symbolic",
            .add => "list-add-symbolic",
            .close => "window-close-symbolic",
            .rename => "document-edit-symbolic",
        });
        wk.gtk_widget_add_css_class(b, "flat");
        wk.gtk_widget_add_css_class(b, "circular");
        wk.gtk_widget_add_css_class(b, "pane-sidebar-tool");
        wk.gtk_widget_set_focus_on_click(b, 0);
        wk.gtk_widget_set_focusable(b, 0);
        var tip_buf: [160]u8 = undefined;
        const tip: [:0]const u8 = if (t == .add and (r.kind == .project or r.kind == .ungrouped))
            groupAddTip(r, &tip_buf)
        else
            rows.toolTip(t, window_row);
        wk.gtk_widget_set_tooltip_text(b, tip);
        const cb: *const anyopaque = switch (t) {
            .stash, .restore => @ptrCast(&onToolStash),
            .add => @ptrCast(&onToolAdd),
            .close => @ptrCast(&onToolClose),
            .rename => @ptrCast(&onToolRename),
        };
        _ = wk.g_signal_connect_data(b, "clicked", cb, r, null, 0);
        wk.gtk_box_append(box, b);
    }
    r.tools_box = box;
    wk.gtk_box_append(row, box);
    // A redraw under a still pointer keeps the row it is over hovered.
    const hovered = if (self.hover_id) |h| std.mem.eql(u8, h, r.id) else false;
    showTools(r, hovered);
}

fn groupAddTip(r: *const Row, buf: *[160]u8) [:0]const u8 {
    if (r.kind == .ungrouped) return rows.toolTip(.add, false);
    const t = add_rules.projectAddTip(r.label, buf[0 .. buf.len - 1]);
    buf[t.len] = 0;
    return buf[0..t.len :0];
}

/// Show or hide a row's buttons; a header's count gives them its place.
fn showTools(r: *Row, on: bool) void {
    r.hovered = on;
    if (r.tools_box) |b| wk.gtk_widget_set_visible(b, @intFromBool(on));
    if (r.count_widget) |c| if (r.tools_box != null) wk.gtk_widget_set_visible(c, @intFromBool(!on));
}

fn onRowEnter(_: *wk.GtkEventController, _: f64, _: f64, r: *Row) callconv(.c) void {
    r.sidebar.setHover(r.id);
}

fn onRowLeave(_: *wk.GtkEventController, r: *Row) callconv(.c) void {
    const self = r.sidebar;
    if (self.hover_id) |h| if (std.mem.eql(u8, h, r.id)) self.setHover(null);
}

/// The row under the pointer (by id; null: none): its buttons show, every
/// other row's hide. The seam's `--hover` drives the same path.
pub fn setHover(self: *PaneSidebar, id: ?[]const u8) void {
    if (self.hover_id) |h| self.alloc.free(h);
    self.hover_id = null;
    if (id) |i| self.hover_id = self.alloc.dupe(u8, i) catch null;
    for (self.drawn.items) |r| showTools(r, if (self.hover_id) |h| std.mem.eql(u8, h, r.id) else false);
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
fn addHeadRow(self: *PaneSidebar, item: all.Item, draggable: bool) Allocator.Error!void {
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
    var count_widget: *wk.GtkWidget = undefined;
    const editing = if (self.edit) |*e| std.mem.eql(u8, e.rowId(), id) else false;
    if (editing) {
        // The in-place field naming a group (T3608) stands where the name
        // was; the count stays.
        wk.gtk_box_append(row, self.editField());
        const count = wk.gtk_label_new(count_z);
        wk.gtk_widget_add_css_class(count, "dim-label");
        wk.gtk_box_append(row, count);
        count_widget = count;
    } else if (kind == .window) {
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
        count_widget = count;
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
        count_widget = count;
    }
    const members = try self.alloc.dupe(u64, item.members);
    errdefer self.alloc.free(members);
    const project: ?[]u8 = if (item.project) |pj| try self.alloc.dupe(u8, pj) else null;
    errdefer if (project) |pj| self.alloc.free(pj);

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
        .tools = rows.headTools(true, kind == .ungrouped),
        .count_widget = count_widget,
        .members = members,
        .project = project,
        // Not while its name is being edited: the field takes the pointer.
        .draggable = draggable and !editing,
    };
    _ = wk.g_signal_connect_data(chevron, "clicked", @ptrCast(&onFoldClicked), r, null, 0);
    // The whole row is the handle (Mac `PaneSidebarItemDragView`); the
    // chevron and the hover buttons keep their clicks, since a press that
    // does not travel is never a drag.
    if (r.draggable) addRowDragSource(r, row);
    if (kind == .window) {
        // A window row's right-click menu (T3608): Create Group..., Move to
        // Group, Remove from Group.
        const menu_click = wk.gtk_gesture_click_new();
        wk.gtk_gesture_single_set_button(menu_click, gdk_button_secondary);
        _ = wk.g_signal_connect_data(menu_click, "pressed", @ptrCast(&onWindowRowSecondary), r, null, 0);
        wk.gtk_widget_add_controller(row, menu_click);
    }
    self.addTools(r, row, kind == .window);
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
        .pane => _ = r.sidebar.activatePane(r.id, altHeld()),
        .window, .tile => _ = raiseWindow(r.key),
        .project, .ungrouped => toggleFold(r.kind, r.key),
        .rail_add => r.sidebar.railAddClicked(),
        .tray => {},
    }
}

fn onFoldClicked(_: *wk.GtkWidget, r: *Row) callconv(.c) void {
    toggleFold(r.kind, r.key);
}

// ---------------------------------------------------------------------------
// A row's buttons (T3606; docs/reference/pane-sidebar.md "Rows and tiles",
// "Adding from the sidebar", "Closing from the sidebar")

fn onToolStash(_: *wk.GtkWidget, r: *Row) callconv(.c) void {
    _ = toggleStash(r.id);
}

fn onToolAdd(_: *wk.GtkWidget, r: *Row) callconv(.c) void {
    r.sidebar.addFromRow(r);
}

fn onToolClose(_: *wk.GtkWidget, r: *Row) callconv(.c) void {
    r.sidebar.closeFromRow(r);
}

fn onHeaderAddClicked(_: *wk.GtkWidget, self: *PaneSidebar) callconv(.c) void {
    self.newWindowHere();
}

/// A row's button, by tool and row id (the seam): what a click on it does.
/// False when the row is not drawn or does not offer that button.
pub fn clickTool(self: *PaneSidebar, tool: rows.Tool, id: []const u8) bool {
    const r = self.rowById(id) orelse return false;
    if (std.mem.indexOfScalar(rows.Tool, r.tools, tool) == null) return false;
    switch (tool) {
        .stash, .restore => _ = toggleStash(r.id),
        .add => self.addFromRow(r),
        .close => self.closeFromRow(r),
        .rename => self.beginEdit(.ungrouped, 0),
    }
    return true;
}

fn onToolRename(_: *wk.GtkWidget, r: *Row) callconv(.c) void {
    // Only the Ungrouped header offers it so far (a window's and a group's
    // rename in place is T3695).
    if (r.kind == .ungrouped) r.sidebar.beginEdit(.ungrouped, 0);
}

// ---------------------------------------------------------------------------
// Group editing (T3608; docs/reference/pane-sidebar.md "All windows": the
// window row's menu and the Ungrouped header's pencil). The rules are
// win32's pure `pane_sidebar_menu` / `pane_sidebar_rename`, as on win32.
//
// A move keeps the list's place (T3697; win32 `keepWindowPlace`, Mac
// `renameWindowKeepingPlace`): the list as shown is written into its order
// first (`window_order.renamingWindow`), so nothing it did not move re-sorts.
//
// Not ported: a group title outranking a script's later `+rename` (win32's
// `.user` provenance, T3702).

const gdk_button_secondary: c_uint = 3;
const gdk_key_escape: c_uint = 0xff1b;

/// The most bytes the field keeps of what was typed.
const edit_cap = 256;
/// A window's name, as the list shows it.
const name_cap = 512;

/// What the in-place field names.
pub const EditPurpose = enum {
    /// A window row's Create Group...: Return makes the window `<group>:
    /// <name>`, into that group, new or existing.
    create_group,
    /// The Ungrouped header's pencil: each lone window becomes `<group>:
    /// <its title>`.
    ungrouped,
};

pub const Edit = struct {
    purpose: EditPurpose,
    /// The window a Create Group... names (its tab's key).
    key: u64 = 0,
    row_buf: [40]u8 = undefined,
    row_len: usize = 0,
    text_buf: [edit_cap]u8 = undefined,
    text_len: usize = 0,
    /// The field as drawn now; null between a teardown and the next draw.
    entry: ?*wk.GtkWidget = null,

    pub fn rowId(self: *const Edit) []const u8 {
        return self.row_buf[0..self.row_len];
    }

    pub fn text(self: *const Edit) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    fn setText(self: *Edit, t: []const u8) void {
        var n = @min(t.len, self.text_buf.len);
        while (n > 0 and n < t.len and (t[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(self.text_buf[0..n], t[0..n]);
        self.text_len = n;
    }
};

/// Open the in-place field: on window row `key` (Create Group...) or on the
/// Ungrouped header. It opens empty, with the placeholder "Group name".
pub fn beginEdit(self: *PaneSidebar, purpose: EditPurpose, key: u64) void {
    var e: Edit = .{ .purpose = purpose, .key = key };
    const id = switch (purpose) {
        .create_group => std.fmt.bufPrint(&e.row_buf, "window:{x}", .{key}) catch return,
        .ungrouped => std.fmt.bufPrint(&e.row_buf, "ungrouped", .{}) catch return,
    };
    e.row_len = id.len;
    self.edit = e;
    log.info("pane sidebar group field open purpose={s} row={s}", .{ @tagName(purpose), id });
    self.queueRefresh();
}

/// The field, drawn for `self.edit`: what was typed so far, the caret given
/// to it once it is on screen.
fn editField(self: *PaneSidebar) *wk.GtkWidget {
    const e = &self.edit.?;
    const entry = wk.gtk_entry_new();
    wk.gtk_entry_set_placeholder_text(entry, rows.group_placeholder);
    wk.gtk_widget_set_hexpand(entry, 1);
    wk.gtk_widget_add_css_class(entry, "pane-sidebar-rename");
    var tb: [edit_cap + 1]u8 = undefined;
    const t = std.fmt.bufPrintZ(&tb, "{s}", .{e.text()}) catch "";
    wk.gtk_editable_set_text(entry, t);
    _ = wk.g_signal_connect_data(entry, "changed", @ptrCast(&onEditChanged), self, null, 0);
    _ = wk.g_signal_connect_data(entry, "activate", @ptrCast(&onEditActivate), self, null, 0);
    const keys = wk.gtk_event_controller_key_new();
    // Ahead of the entry's own text, which would otherwise see Escape first.
    wk.gtk_event_controller_set_propagation_phase(keys, wk.phase_capture);
    _ = wk.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onEditKey), self, null, 0);
    wk.gtk_widget_add_controller(entry, keys);
    const focus = wk.gtk_event_controller_focus_new();
    _ = wk.g_signal_connect_data(focus, "leave", @ptrCast(&onEditLeave), self, null, 0);
    wk.gtk_widget_add_controller(entry, focus);
    e.entry = entry;
    return entry;
}

/// After a draw: a field whose row is no longer listed (its window closed,
/// or the Ungrouped header went with the last group) is dropped; one that
/// is drawn takes the caret at once - every redraw builds the field anew -
/// or, not yet able to (a first draw), on the next idle turn.
fn settleEdit(self: *PaneSidebar) void {
    const e = if (self.edit) |*x| x else return;
    const entry = e.entry orelse {
        log.info("pane sidebar group field dropped: row={s} no longer listed", .{e.rowId()});
        self.edit = null;
        return;
    };
    _ = wk.gtk_widget_grab_focus(entry);
    wk.gtk_editable_set_position(entry, -1);
    if (entryFocused(entry)) return;
    if (self.edit_focus_idle == 0) self.edit_focus_idle = wk.g_idle_add(@ptrCast(&onEditFocusIdle), self);
}

fn onEditFocusIdle(self: *PaneSidebar) callconv(.c) c_int {
    self.edit_focus_idle = 0;
    const e = if (self.edit) |*x| x else return 0;
    if (e.entry) |entry| {
        if (!entryFocused(entry)) {
            _ = wk.gtk_widget_grab_focus(entry);
            wk.gtk_editable_set_position(entry, -1);
        }
    }
    return 0; // G_SOURCE_REMOVE
}

/// Whether the field has the keyboard: a GtkEntry's caret is in its text
/// child.
fn entryFocused(entry: *wk.GtkWidget) bool {
    const root = wk.gtk_widget_get_root(entry) orelse return false;
    const f = wk.gtk_root_get_focus(root) orelse return false;
    return f == entry or wk.gtk_widget_get_parent(f) == entry;
}

fn onEditChanged(entry: *wk.GtkWidget, self: *PaneSidebar) callconv(.c) void {
    const e = if (self.edit) |*x| x else return;
    if (e.entry == null or e.entry.? != entry) return;
    e.setText(std.mem.span(wk.gtk_editable_get_text(entry)));
}

fn onEditActivate(_: *wk.GtkWidget, self: *PaneSidebar) callconv(.c) void {
    self.commitEdit("return");
}

fn onEditKey(_: *wk.GtkEventController, keyval: c_uint, _: c_uint, _: c_uint, self: *PaneSidebar) callconv(.c) c_int {
    if (keyval != gdk_key_escape) return 0;
    self.cancelEdit();
    return 1;
}

/// The caret left the field - the user clicked away - which keeps what was
/// typed, as Return does. Its own teardown in a redraw is not that.
fn onEditLeave(ctl: *wk.GtkEventController, self: *PaneSidebar) callconv(.c) void {
    if (self.clearing) return;
    const e = if (self.edit) |*x| x else return;
    if (e.entry == null or e.entry.? != wk.gtk_event_controller_get_widget(ctl)) return;
    self.commitEdit("away");
}

/// Escape: nothing changes.
pub fn cancelEdit(self: *PaneSidebar) void {
    const e = self.edit orelse return;
    log.info("pane sidebar group field cancelled row={s}", .{e.rowId()});
    self.edit = null;
    self.queueRefresh();
}

/// Return (or clicking away): what was typed names the group. Nothing
/// typed changes nothing.
pub fn commitEdit(self: *PaneSidebar, how: []const u8) void {
    const e = self.edit orelse return;
    // Closed first: the retitles below redraw, and the field must not be
    // drawn again or commit twice.
    self.edit = null;
    defer Window.queueAllSidebarRefresh();
    const name = switch (rename_rules.decide(e.text(), "")) {
        .set => |n| n,
        .keep, .clear => {
            log.info("pane sidebar group field committed empty by={s}: unchanged", .{how});
            return;
        },
    };
    log.info("pane sidebar group field committed by={s} purpose={s} name={s}", .{ how, @tagName(e.purpose), name });
    switch (e.purpose) {
        .create_group => _ = moveWindowToGroup(e.key, name),
        .ungrouped => self.groupUngrouped(name),
    }
}

/// The Ungrouped header's pencil committed `name` (Mac
/// `groupUngroupedFromSidebar`, win32 `groupUngrouped`): each window it lists
/// - the matching ones while searching - is retitled `<name>: <its title>`,
/// pinned as the user's. A name that cannot head a group changes nothing.
fn groupUngrouped(self: *PaneSidebar, name: []const u8) void {
    if (!rename_rules.namesGroup(name)) return log.info("pane sidebar ungrouped not grouped: not a group name", .{});
    const r = self.rowById("ungrouped") orelse return;
    // Copied: the retitles queue redraws, which replace the row.
    var keys: [row_menu.max_groups * 4]u64 = undefined;
    const n = @min(keys.len, r.members.len);
    @memcpy(keys[0..n], r.members[0..n]);
    var grouped: usize = 0;
    for (keys[0..n]) |k| {
        if (moveWindowToGroup(k, name)) grouped += 1;
    }
    log.info("pane sidebar ungrouped grouped windows={d}", .{grouped});
}

/// Window `key` moved into group `project` - or, null, out of any - its own
/// name kept (win32 `moveWindowToGroup`, Mac `moveToGroupFromSidebar`).
/// False when the window is gone, the name cannot head a group, or nothing
/// would change.
fn moveWindowToGroup(key: u64, project: ?[]const u8) bool {
    // The list as it is shown, read before the retitle: nothing it did not
    // move re-sorts (win32 `keepWindowPlace`, Mac
    // `renameWindowKeepingPlace`, T2405).
    var arena_state = std.heap.ArenaAllocator.init(shared_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pinned: ?[]const []const u8 = blk: {
        const g = gatherFor(null, arena) catch break :blk null;
        break :blk all.shownOrderKeys(arena, g.windows, &scope) catch null;
    };
    if (!retitleIntoGroup(key, project)) return false;
    const p = pinned orelse return true;
    const wkey = all.windowOrderKey(arena, key) catch return true;
    var kb: window_order.Key = .{};
    var out: [window_order.max_keys][]const u8 = undefined;
    const n = window_order.renamingWindow(p, wkey, project, &kb, &out);
    setWindowOrder(out[0..n], "group move");
    return true;
}

/// Retitle window `key` into group `project` (null: out of any), its own
/// name kept and pinned as the user's. False when nothing would change.
fn retitleIntoGroup(key: u64, project: ?[]const u8) bool {
    var nb: [name_cap]u8 = undefined;
    const title = windowName(key, &nb) orelse return false;
    var gb: [name_cap + 64]u8 = undefined;
    const titled = rename_rules.titleInGroup(&gb, title, project) orelse {
        log.info("pane sidebar window group unchanged: not a group name", .{});
        return false;
    };
    if (std.mem.eql(u8, titled, title)) return false;
    log.info("pane sidebar window group move to={s} title={s}", .{ project orelse "", titled });
    return pinWindowName(key, titled);
}

/// Pin window `key`'s name as the user's: the tab's title (Change Tab
/// Title) - unless its window carries a window-wide pin (`+rename`, Change
/// Window Title), which is what the row shows and so what is renamed.
fn pinWindowName(key: u64, name: []const u8) bool {
    const f = findTab(key) orelse return false;
    if (f.win.titleOverride()) |o| if (o.len > 0) {
        f.win.setTitleOverride(name);
        return true;
    };
    var zb: [name_cap + 65]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{name}) catch return false;
    f.tab.setTitleOverride(z);
    return true;
}

/// The name window `key` (a tab) shows in the list, copied into `buf`; null
/// when it is gone. Read as `gather` reads it.
fn windowName(key: u64, buf: []u8) ?[]const u8 {
    var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
    while (node) |n| {
        node = n.f_next;
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const win = gobject.ext.cast(Window, obj) orelse continue;
        if (win.paneSidebar() == null) continue;
        const tab_view = win.getTabView();
        const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
        for (0..pages) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            if (@intFromPtr(tab) != key) continue;
            const active = tab.getActiveSurface();
            const pwd: ?[]const u8 = if (active) |a| (if (a.getPwd()) |d| d else null) else null;
            const nm = all.name(win.titleOverride(), if (tab.titleOverride()) |t| t else null, std.mem.span(page.getTitle()), pwd);
            var len = @min(nm.len, buf.len);
            while (len > 0 and len < nm.len and (nm[len] & 0xC0) == 0x80) len -= 1;
            @memcpy(buf[0..len], nm[0..len]);
            return buf[0..len];
        }
    }
    return null;
}

fn freeMenuState(self: *PaneSidebar) void {
    if (self.menu_row) |r| self.alloc.free(r);
    self.menu_row = null;
    for (self.menu_groups.items) |g| self.alloc.free(g);
    self.menu_groups.clearRetainingCapacity();
    self.menu_remove = false;
}

fn onWindowRowSecondary(_: *wk.GtkEventController, _: c_int, x: f64, y: f64, r: *Row) callconv(.c) void {
    _ = r.sidebar.openWindowMenu(r, x, y);
}

/// Pop window row `r`'s menu at (`x`, `y`) of the row (Mac
/// `PaneSidebarView.windowMenu`): Create Group..., Move to Group with every
/// other group as listed (only when there is one), and Remove from Group
/// for a grouped window. False when the row is not a window's or is gone.
pub fn openWindowMenu(self: *PaneSidebar, r: *const Row, x: f64, y: f64) bool {
    if (r.kind != .window) return false;
    if (self.menu_pop) |p| wk.gtk_popover_popdown(p);
    self.menu_pop = null;
    self.freeMenuState();

    var nb: [name_cap]u8 = undefined;
    const title = windowName(r.key, &nb) orelse return false;
    // Every group the list shows, in its order.
    var listed: [row_menu.max_groups]?[]const u8 = undefined;
    var nl: usize = 0;
    for (self.drawn.items) |d| {
        if (d.kind != .project or nl == listed.len) continue;
        listed[nl] = d.label;
        nl += 1;
    }
    var gbuf: [row_menu.max_groups][]const u8 = undefined;
    const groups = row_menu.movingTo(title, listed[0..nl], &gbuf);
    for (groups) |g| {
        const copy = self.alloc.dupe(u8, g) catch break;
        self.menu_groups.append(self.alloc, copy) catch {
            self.alloc.free(copy);
            break;
        };
    }
    self.menu_key = r.key;
    self.menu_row = self.alloc.dupe(u8, r.id) catch null;
    self.menu_remove = row_menu.offersRemove(title);

    const group = wk.g_simple_action_group_new();
    defer wk.g_object_unref(group);
    const menu = wk.g_menu_new();
    defer wk.g_object_unref(menu);
    addMenuAction(group, "create", self);
    wk.g_menu_append(menu, rows.create_group_label, "sbmenu.create");
    if (self.menu_groups.items.len > 0) {
        const sub = wk.g_menu_new();
        defer wk.g_object_unref(sub);
        for (self.menu_groups.items, 0..) |g, i| {
            var an: [24]u8 = undefined;
            const action = std.fmt.bufPrintZ(&an, "move-{d}", .{i}) catch continue;
            addMenuAction(group, action, self);
            var dn: [40]u8 = undefined;
            const detailed = std.fmt.bufPrintZ(&dn, "sbmenu.{s}", .{action}) catch continue;
            var lb: [name_cap]u8 = undefined;
            wk.g_menu_append(sub, rows.menuLabel(&lb, g).ptr, detailed.ptr);
        }
        wk.g_menu_append_submenu(menu, rows.move_to_group_label, sub);
    }
    if (self.menu_remove) {
        addMenuAction(group, "remove", self);
        wk.g_menu_append(menu, rows.remove_from_group_label, "sbmenu.remove");
    }
    wk.gtk_widget_insert_action_group(self.card, "sbmenu", group);

    const pop = wk.gtk_popover_menu_new_from_model(menu);
    wk.gtk_widget_set_parent(pop, self.card);
    wk.gtk_popover_set_has_arrow(pop, 0);
    var cx: f64 = 0;
    var cy: f64 = 0;
    if (wk.gtk_widget_translate_coordinates(r.widget, self.card, x, y, &cx, &cy) == 0) {
        cx = 0;
        cy = 0;
    }
    const rect: wk.GdkRectangle = .{
        .x = @intFromFloat(@max(0, cx)),
        .y = @intFromFloat(@max(0, cy)),
        .width = 1,
        .height = 1,
    };
    wk.gtk_popover_set_pointing_to(pop, &rect);
    _ = wk.g_signal_connect_data(pop, "closed", @ptrCast(&onMenuClosed), self, null, 0);
    self.menu_pop = pop;
    log.info("pane sidebar window menu open title={s} groups={d} remove={}", .{ title, self.menu_groups.items.len, self.menu_remove });
    wk.gtk_popover_popup(pop);
    return true;
}

fn addMenuAction(group: *wk.GSimpleActionGroup, name: [:0]const u8, self: *PaneSidebar) void {
    const action = wk.g_simple_action_new(name.ptr, null);
    _ = wk.g_signal_connect_data(action, "activate", @ptrCast(&onMenuAction), self, null, 0);
    wk.g_action_map_add_action(group, action);
    wk.g_object_unref(action);
}

fn onMenuAction(action: *wk.GSimpleAction, _: ?*anyopaque, self: *PaneSidebar) callconv(.c) void {
    const name = std.mem.span(wk.g_action_get_name(action));
    const cmd: row_menu.WindowCmd = if (std.mem.eql(u8, name, "create"))
        .create_group
    else if (std.mem.eql(u8, name, "remove"))
        .remove_from_group
    else if (std.mem.startsWith(u8, name, "move-"))
        .{ .move_to_group = std.fmt.parseInt(usize, name["move-".len..], 10) catch return }
    else
        return;
    _ = self.pickMenu(cmd);
}

/// A pick from the window menu (the live menu and the seam's `--menu-pick`
/// both come here), acting on the window it was opened on.
pub fn pickMenu(self: *PaneSidebar, cmd: row_menu.WindowCmd) bool {
    if (self.menu_row == null) return false;
    const key = self.menu_key;
    log.info("pane sidebar window menu choice={s}", .{@tagName(cmd)});
    const ok = switch (cmd) {
        .create_group => blk: {
            self.beginEdit(.create_group, key);
            break :blk true;
        },
        .move_to_group => |i| blk: {
            if (i >= self.menu_groups.items.len) break :blk false;
            // Copied: the move redraws, and the next menu frees the list.
            var pb: [name_cap]u8 = undefined;
            const g = self.menu_groups.items[i];
            const n = @min(g.len, pb.len);
            @memcpy(pb[0..n], g[0..n]);
            break :blk moveWindowToGroup(key, pb[0..n]);
        },
        .remove_from_group => moveWindowToGroup(key, null),
    };
    if (self.menu_pop) |p| wk.gtk_popover_popdown(p);
    // Picked: the menu is spent.
    self.freeMenuState();
    Window.queueAllSidebarRefresh();
    return ok;
}

pub const WindowCmd = row_menu.WindowCmd;

/// Which of the menu's Move to Group entries names `group`.
pub fn menuGroupIndex(self: *const PaneSidebar, group: []const u8) ?usize {
    for (self.menu_groups.items, 0..) |g, i| if (std.mem.eql(u8, g, group)) return i;
    return null;
}

/// Whether the menu last opened, and not yet picked from, offers `cmd`. The
/// popover being up is not asked: a compositor with no seat (the headless
/// harness) closes it at once for want of a grab, and what was offered is
/// the same either way.
pub fn menuOffers(self: *const PaneSidebar, cmd: WindowCmd) bool {
    if (self.menu_row == null) return false;
    return switch (cmd) {
        .create_group => true,
        .move_to_group => |i| i < self.menu_groups.items.len,
        .remove_from_group => self.menu_remove,
    };
}

/// The seam's report of the menu last opened and not yet picked from.
fn menuReport(self: *PaneSidebar, arena: Allocator) Allocator.Error!?rows.Report.Menu {
    if (self.menu_row == null) return null;
    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    try items.append(arena, rows.create_group_label);
    if (self.menu_groups.items.len > 0) try items.append(arena, rows.move_to_group_label);
    if (self.menu_remove) try items.append(arena, rows.remove_from_group_label);
    const groups = try arena.alloc([]const u8, self.menu_groups.items.len);
    for (self.menu_groups.items, groups) |g, *o| o.* = try arena.dupe(u8, g);
    return .{
        .row = try arena.dupe(u8, self.menu_row orelse ""),
        .items = items.items,
        .groups = groups,
        .popped = self.menu_pop != null,
    };
}

fn editReport(self: *PaneSidebar, arena: Allocator) Allocator.Error!?rows.Report.Editing {
    const e = if (self.edit) |*x| x else return null;
    return .{
        .row = try arena.dupe(u8, e.rowId()),
        .purpose = @tagName(e.purpose),
        .placeholder = rows.group_placeholder,
        .text = try arena.dupe(u8, e.text()),
        .shown = e.entry != null,
        .focused = if (e.entry) |en| entryFocused(en) else false,
    };
}

/// Type `text` into the open field, as the keyboard would (the seam's
/// `--edit`). False when no field is open.
pub fn typeEdit(self: *PaneSidebar, text: []const u8) bool {
    const e = if (self.edit) |*x| x else return false;
    if (e.entry) |entry| {
        var tb: [edit_cap + 1]u8 = undefined;
        const z = std.fmt.bufPrintZ(&tb, "{s}", .{text[0..@min(text.len, edit_cap)]}) catch return false;
        wk.gtk_editable_set_text(entry, z);
    } else e.setText(text);
    return true;
}

fn onMenuClosed(pop: *wk.GtkWidget, self: *PaneSidebar) callconv(.c) void {
    if (self.menu_pop == pop) self.menu_pop = null;
    // Unparented once GTK has finished with the activation that closed it.
    _ = wk.g_object_ref(pop);
    _ = wk.g_idle_add(&unparentMenu, pop);
}

fn unparentMenu(data: ?*anyopaque) callconv(.c) c_int {
    const pop: *wk.GtkWidget = @ptrCast(@alignCast(data orelse return 0));
    if (wk.gtk_widget_get_parent(pop) != null) wk.gtk_widget_unparent(pop);
    wk.g_object_unref(pop);
    return 0;
}

// ---------------------------------------------------------------------------
// Drag to reorder (T3607; docs/reference/pane-sidebar.md "Drag to reorder")

/// Put a window's panes (tree order) in the sidebar's own order for that
/// window, in place. No order yet: left as they are.
fn arrangeLeaves(key: usize, leaves: []*Surface) void {
    const cur = orders.get(key);
    if (cur.len == 0) return;
    const n = @min(leaves.len, sidebar_order.max_ids);
    var ids: [sidebar_order.max_ids][]const u8 = undefined;
    var was: [sidebar_order.max_ids]*Surface = undefined;
    for (leaves[0..n], 0..) |v, i| {
        ids[i] = v.paneId();
        was[i] = v;
    }
    var idx: [sidebar_order.max_ids]usize = undefined;
    const m = sidebar_order.arranged(ids[0..n], cur, &idx);
    for (idx[0..m], 0..) |vi, i| leaves[i] = was[vi];
}

/// A pane row's drag source: the pointer pressed on the row and moved
/// starts it, a press without moving is still the row's click.
fn addRowDragSource(r: *Row, button: *wk.GtkWidget) void {
    const source = wk.gtk_drag_source_new();
    wk.gtk_drag_source_set_actions(source, wk.gdk_action_move);
    _ = wk.g_signal_connect_data(source, "prepare", @ptrCast(&onRowDragPrepare), r, null, 0);
    _ = wk.g_signal_connect_data(source, "drag-begin", @ptrCast(&onRowDragBegin), r, null, 0);
    // drag-end gets no row: the list may have been redrawn (and the row
    // freed) while the pointer was down.
    _ = wk.g_signal_connect_data(source, "drag-end", @ptrCast(&onRowDragEnd), null, null, 0);
    wk.gtk_widget_add_controller(button, source);
}

fn rowDragged() ?[]const u8 {
    if (row_drag_len == 0) return null;
    return row_drag_buf[0..row_drag_len];
}

fn onRowDragPrepare(_: *wk.GtkEventController, _: f64, _: f64, r: *Row) callconv(.c) ?*wk.GdkContentProvider {
    const bytes = wk.g_bytes_new(r.id.ptr, r.id.len);
    defer wk.g_bytes_unref(bytes);
    return wk.gdk_content_provider_new_for_bytes(row_mime.ptr, bytes);
}

fn onRowDragBegin(_: *wk.GtkEventController, _: *wk.GdkDrag, r: *Row) callconv(.c) void {
    const n = @min(r.id.len, row_drag_buf.len);
    @memcpy(row_drag_buf[0..n], r.id[0..n]);
    row_drag_len = n;
    log.info("pane sidebar row drag began pane={s}", .{r.id});
    // A window or a group picked up folds the list to rows (T3697).
    if (r.kind == .window or r.kind == .project) _ = r.sidebar.liftItem(r.id);
}

fn onRowDragEnd(_: *wk.GtkEventController, _: *wk.GdkDrag, _: c_int, _: ?*anyopaque) callconv(.c) void {
    if (rowDragged()) |id| log.info("pane sidebar row drag ended pane={s}", .{id});
    row_drag_len = 0;
    endLift();
}

/// Whether a dragged row id is a window row's or a project header's.
fn isItemId(id: []const u8) bool {
    return std.mem.startsWith(u8, id, window_order.window_prefix) or window_order.isProject(id);
}

/// Pick up window row or project header `id` (T3697; win32
/// `maybeStartItemDrag`): every group folds to its header for a group, every
/// window to its row for a window, so each is one row high and easy to
/// place; `endLift` puts them back. Only in the expanded all-windows list.
/// False when `id` is not such a row here, or something is already lifted.
pub fn liftItem(self: *PaneSidebar, id: []const u8) bool {
    if (lift != null) return false;
    const r = self.rowById(id) orelse return false;
    if ((r.kind != .window and r.kind != .project) or !r.draggable) return false;
    if (r.kind == .project) {
        var projects: std.ArrayListUnmanaged(u64) = .empty;
        defer projects.deinit(self.alloc);
        for (self.drawn.items) |o| if (o.kind == .project) {
            projects.append(self.alloc, o.key) catch return false;
        };
        lift = .{ .which = .projects, .before = scope.foldProjects(shared_alloc, projects.items) };
    } else {
        lift = .{ .which = .windows, .before = scope.foldWindows(shared_alloc) };
    }
    log.info("pane sidebar item lifted id={s} folds={s}", .{ id, @tagName(lift.?.which) });
    Window.queueAllSidebarRefresh();
    return true;
}

/// Let go of whatever `liftItem` picked up: its folds come back.
pub fn endLift() void {
    var l = lift orelse return;
    lift = null;
    scope.restoreFolds(shared_alloc, switch (l.which) {
        .projects => .projects,
        .windows => .windows,
    }, &l.before);
    log.info("pane sidebar item lift ended", .{});
    Window.queueAllSidebarRefresh();
}

/// Window row or project header `id` let go with the pointer at `y` (the
/// list's coordinates), read against the rows as laid out (`all.dropItem`):
/// a group among the top level, a window anywhere - into a group or out of
/// one, retitled to say so. The order changes in every window's list; no
/// window moves on screen. Returns the index it landed at among its new
/// siblings, or null when `id` is not such a row here or is not laid out.
pub fn dropItemAt(self: *PaneSidebar, id: []const u8, y: f64) ?usize {
    const r = self.rowById(id) orelse return null;
    if ((r.kind != .window and r.kind != .project) or !r.draggable) return null;
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var laid: std.ArrayListUnmanaged(all.Laid) = .empty;
    var list_bottom: i32 = 0;
    for (self.drawn.items) |o| {
        const b = self.rowBounds(o) orelse continue;
        const top: i32 = @intFromFloat(@round(b.y));
        const bottom: i32 = @intFromFloat(@round(b.y + b.h));
        list_bottom = @max(list_bottom, bottom);
        const kind: all.Kind = switch (o.kind) {
            .window => .window,
            .project => .project,
            .ungrouped => .ungrouped,
            else => continue,
        };
        laid.append(arena, .{ .kind = kind, .key = o.id, .project = o.project, .top = top, .head_bottom = bottom }) catch return null;
    }
    const g = gatherFor(null, arena) catch return null;
    const existing = all.allOrderKeys(arena, g.windows) catch return null;
    var cur_buf: [window_order.max_keys][]const u8 = undefined;
    const cur = scope.windowOrder(&cur_buf);
    const yi: i32 = @intFromFloat(@round(y));
    const d = (all.dropItem(arena, laid.items, list_bottom, id, yi, cur, existing) catch return null) orelse return null;
    log.info("pane sidebar item drop id={s} y={d} index={d} regroup={} to={s}", .{ id, yi, d.index, d.regroup, d.project orelse "" });
    // The retitle first (it only queues redraws, so the rows `d` borrows
    // stay put); `setWindowOrder` copies the keys before it frees `cur`.
    if (d.regroup) _ = retitleIntoGroup(r.key, d.project);
    setWindowOrder(d.order, "drag");
    return d.index;
}

fn onListAccept(_: *wk.GtkEventController, _: *wk.GdkDrop, _: *PaneSidebar) callconv(.c) c_int {
    // Only a row drag of this app: another app offering the type has no row
    // here to move.
    return @intFromBool(rowDragged() != null);
}

fn onListMotion(_: *wk.GtkEventController, _: *wk.GdkDrop, _: f64, y: f64, self: *PaneSidebar) callconv(.c) c_int {
    const id = rowDragged() orelse return 0;
    // A pane row over its own window's tray lights it (T3698).
    const lit = if (isItemId(id)) false else if (self.rowById(id)) |r| rows.inTray(self.trayTop(r.tab), y) else false;
    self.lightTray(lit);
    return wk.gdk_action_move;
}

fn onListLeave(_: *wk.GtkEventController, _: *wk.GdkDrop, self: *PaneSidebar) callconv(.c) void {
    self.lightTray(false);
}

fn onListDrop(_: *wk.GtkEventController, drop: *wk.GdkDrop, _: f64, y: f64, self: *PaneSidebar) callconv(.c) c_int {
    const id = rowDragged() orelse {
        wk.gdk_drop_finish(drop, 0);
        return 0;
    };
    // Copied: the move redraws every list, and the drag's end clears it.
    var buf: [64]u8 = undefined;
    const own = buf[0..id.len];
    @memcpy(own, id);
    self.lightTray(false);
    const moved = (if (isItemId(own)) self.dropItemAt(own, y) else self.dropRowAt(own, y)) != null;
    wk.gdk_drop_finish(drop, if (moved) wk.gdk_action_move else 0);
    return @intFromBool(moved);
}

/// A drawn row's bounds in the list's coordinates, or null before layout.
fn rowBounds(self: *PaneSidebar, r: *const Row) ?wk.GrapheneRect {
    var b: wk.GrapheneRect = .{};
    if (wk.gtk_widget_compute_bounds(r.widget, self.list, &b) == 0) return null;
    if (b.h <= 0) return null;
    return b;
}

/// The row with this id let go at `y` (the list's coordinates): it lands
/// among its own window's rows level with the pointer - wherever in the list
/// that is (Mac: a row dragged in the list only ever rearranges). Returns
/// the index it landed at, of its window's list without it, or null when
/// the row is not drawn here, does not drag, or the move was refused. The
/// live drop and the seam's `--drag` both come here.
pub fn dropRowAt(self: *PaneSidebar, id: []const u8, y: f64) ?usize {
    const r = self.rowById(id) orelse return null;
    if (r.kind != .pane or !r.draggable) return null;
    // Two lists, split where the tray begins (T3698, win32
    // `pane_drop.sidebarHit`): above it the window's panes on screen, at or
    // below it the tray.
    const tray = rows.inTray(self.trayTop(r.tab), y);
    var mids: [sidebar_order.max_ids]f64 = undefined;
    var n: usize = 0;
    for (self.drawn.items) |o| {
        if (o == r or o.kind != .pane or o.tab != r.tab or o.stashed != tray) continue;
        const b = self.rowBounds(o) orelse continue;
        if (n == mids.len) break;
        mids[n] = b.y + b.h / 2;
        n += 1;
    }
    const index = rows.dropIndex(mids[0..n], y);
    log.info("pane sidebar row drop pane={s} y={d:.0} into={s} index={d}", .{ id, y, if (tray) "tray" else "list", index });
    if (tray) {
        if (!stashRowAt(id, index)) return null;
        return index;
    }
    // Out of the tray, it comes back to the slot it left, focused (win32
    // `commitListDrop`), then takes its place in the list.
    if (r.stashed) {
        const f = findPane(id) orelse return null;
        if (!f.tab.getSplitTree().restoreSurface(f.surface, true)) return null;
        log.info("pane sidebar restore pane={s} from=tray", .{id});
    }
    if (!self.moveRow(id, index)) return null;
    return index;
}

/// Where window (tab) `tab`'s tray begins in the list's coordinates
/// (T3698): the top of its tray head where one is drawn (this window's list),
/// else between its rows on screen and its stashed rows (the all-windows
/// outline, `rows.trayTopBetween`). Null when none of its rows is laid out.
fn trayTop(self: *PaneSidebar, tab: usize) ?f64 {
    var last_list: ?f64 = null;
    var first_stashed: ?f64 = null;
    for (self.drawn.items) |o| {
        if (o.tab != tab) continue;
        const b = self.rowBounds(o) orelse continue;
        switch (o.kind) {
            .tray => return b.y,
            .pane => if (o.stashed) {
                if (first_stashed == null) first_stashed = b.y;
            } else {
                last_list = b.y + b.h;
            },
            else => {},
        }
    }
    return rows.trayTopBetween(last_list, first_stashed);
}

/// Stash pane `pane_id` at `index` of its window's stash, 0 the top (T3698;
/// win32 `commitStashDrop`): a pane on screen is stashed there - refused for
/// the last one on screen - and a stashed one moves to that gap. False when
/// the pane is gone or refused.
fn stashRowAt(pane_id: []const u8, index: usize) bool {
    const f = findPane(pane_id) orelse return false;
    f.tab.getSplitTree().stashSurfaceAt(f.surface, index) catch |err| {
        log.info("pane sidebar stash refused pane={s} err={}", .{ pane_id, err });
        return false;
    };
    log.info("pane sidebar stash pane={s} index={d} from=drag", .{ pane_id, index });
    return true;
}

/// Light the tray while a drag held over this list would land in it (T3698,
/// Mac: the empty tray's well "lit in the accent while a drag would land in
/// it"). The class goes on the tray head, which the next redraw rebuilds
/// unlit.
fn lightTray(self: *PaneSidebar, on: bool) void {
    for (self.drawn.items) |o| if (o.kind == .tray) {
        if (on) wk.gtk_widget_add_css_class(o.widget, "pane-sidebar-tray-lit") else wk.gtk_widget_remove_css_class(o.widget, "pane-sidebar-tray-lit");
    };
}

/// Put the pane at `index` of its window's sidebar list (counted without
/// it): the list's own order, never the grid (win32
/// `Window.placeInPaneSidebar`). False when the pane is gone or stashed.
fn moveRow(self: *PaneSidebar, pane_id: []const u8, index: usize) bool {
    const f = findPane(pane_id) orelse return false;
    if (pane_stash.isStashed(f.surface)) return false;
    const tree = f.tab.getSurfaceTree() orelse return false;
    var leaves: std.ArrayListUnmanaged(*Surface) = .empty;
    defer leaves.deinit(self.alloc);
    collectLeaves(self.alloc, tree, &leaves) catch return false;
    const n = @min(leaves.items.len, sidebar_order.max_ids);
    // `index` counts the list as drawn: the panes on screen (T3698). Every
    // pane is in the order, so a stashed one keeps its place there for when
    // it comes back (win32 `placeInPaneSidebar`).
    var visible: [sidebar_order.max_ids][]const u8 = undefined;
    var existing: [sidebar_order.max_ids][]const u8 = undefined;
    var nv: usize = 0;
    for (leaves.items[0..n], 0..) |v, i| {
        existing[i] = v.paneId();
        if (pane_stash.isStashed(v)) continue;
        visible[nv] = v.paneId();
        nv += 1;
    }
    const key = @intFromPtr(f.tab);
    var next: [sidebar_order.max_ids][]const u8 = undefined;
    const got = sidebar_order.moving(pane_id, index, visible[0..nv], orders.get(key), existing[0..n], &next);
    orders.set(self.alloc, key, next[0..got]) catch return false;
    orders.prune(self.alloc, {}, tabIsOpen);
    log.info("pane sidebar reorder pane={s} index={d} panes={d}", .{ pane_id, index, got });
    Window.queueAllSidebarRefresh();
    return true;
}

fn tabIsOpen(_: void, key: usize) bool {
    return findTab(key) != null;
}

const FoundPane = struct { win: *Window, tab: *Tab, surface: *Surface };

/// The pane with this id in any window (any tab), or null.
fn findPane(pane_id: []const u8) ?FoundPane {
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
                if (std.mem.eql(u8, entry.view.paneId(), pane_id)) return .{ .win = win, .tab = tab, .surface = entry.view };
            }
        }
    }
    return null;
}

pub const FoundTab = struct { win: *Window, tab: *Tab };

/// The window (a tab) with this key, or null when it is gone.
fn findTab(key: u64) ?FoundTab {
    var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
    while (node) |n| {
        node = n.f_next;
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const win = gobject.ext.cast(Window, obj) orelse continue;
        if (win.paneSidebar() == null) continue;
        const tab_view = win.getTabView();
        const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
        for (0..pages) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            if (@intFromPtr(tab) == key) return .{ .win = win, .tab = tab };
        }
    }
    return null;
}

/// A row's - or its restore: stash the pane, or bring a stashed one back to
/// its slot, focused (win32 `paneSidebarToggleStash`). The last pane on
/// screen is not stashed. False when the pane is gone or refused.
fn toggleStash(pane_id: []const u8) bool {
    const f = findPane(pane_id) orelse return false;
    const tree = f.tab.getSplitTree();
    if (pane_stash.isStashed(f.surface)) {
        log.info("pane sidebar restore pane={s}", .{pane_id});
        return tree.restoreSurface(f.surface, true);
    }
    tree.stashSurface(f.surface) catch |err| {
        log.info("pane sidebar stash refused pane={s} err={}", .{ pane_id, err });
        return false;
    };
    log.info("pane sidebar stash pane={s}", .{pane_id});
    return true;
}

/// A row's x: a pane's closes that pane (its window too, when it was the
/// last), a header's every window it heads (`Row.members`). Nothing is asked
/// and nothing is raised; the sessions end, parked for undo as any close.
/// The close runs on the next main-loop turn, so a window can close itself
/// from its own sidebar - this row is freed by then.
fn closeFromRow(self: *PaneSidebar, r: *const Row) void {
    const p = self.alloc.create(PendingClose) catch return;
    p.* = .{ .alloc = self.alloc };
    switch (r.kind) {
        .pane => p.pane = self.alloc.dupe(u8, r.id) catch null,
        .window, .project, .ungrouped => p.keys = self.alloc.dupe(u64, r.members) catch &.{},
        .tile, .rail_add, .tray => {},
    }
    log.info("pane sidebar close {s} id={s} windows={d}", .{ @tagName(r.kind), r.id, p.keys.len });
    _ = wk.g_idle_add(@ptrCast(&onPendingClose), p);
}

const PendingClose = struct {
    alloc: Allocator,
    pane: ?[]u8 = null,
    keys: []const u64 = &.{},
};

fn onPendingClose(p: *PendingClose) callconv(.c) c_int {
    defer {
        if (p.pane) |id| p.alloc.free(id);
        p.alloc.free(p.keys);
        p.alloc.destroy(p);
    }
    // Found again by identity: a window may have closed since the click.
    if (p.pane) |id| if (findPane(id)) |f| {
        _ = f.tab.getSplitTree().closeSurfaceNow(f.surface);
    };
    for (p.keys) |k| if (findTab(k)) |f| {
        _ = f.win.closeTabNow(f.tab);
    };
    return 0; // G_SOURCE_REMOVE
}

/// A header's + (Mac `PaneSidebarAdd`): a window row's raises that window
/// and splits its focused pane the way the user last split one by hand; a
/// project's opens a window from its first window as listed, titled into the
/// group under a free placeholder name; the Ungrouped header's an untitled
/// window from its first. Each takes focus, as the keybinds do.
fn addFromRow(self: *PaneSidebar, r: *const Row) void {
    if (r.members.len == 0) return;
    const first = findTab(r.members[0]) orelse return;
    const parent: ?*Surface = first.tab.getActiveSurface();
    switch (r.kind) {
        .window => addPaneTo(first, r.key, "row"),
        .ungrouped => {
            log.info("pane sidebar add ungrouped window", .{});
            _ = first.win.as(gtk.Widget).activateAction("win.new-window", null);
        },
        .project => {
            var arena_state = std.heap.ArenaAllocator.init(self.alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const g = self.gather(arena) catch return;
            const taken = arena.alloc([]const u8, g.windows.len) catch return;
            for (g.windows, taken) |w, *t| t.* = w.name;
            var tb: [512]u8 = undefined;
            const title = add_rules.newWindowTitle(&tb, r.label, taken);
            if (title.len == 0) return;
            log.info("pane sidebar add window in group title={s}", .{title});
            const core = if (parent) |s| s.core() else null;
            _ = Application.default().newWindowFromSidebar(core, title);
        },
        .pane, .tile, .rail_add, .tray => {},
    }
}

/// A new pane in window (tab) `key`: raised, and its focused pane split the
/// way the user last split one by hand (`add_rules.split_memory`). What a
/// window row's + and this window's rail + do.
fn addPaneTo(f: FoundTab, key: u64, from: []const u8) void {
    const dir = add_rules.split_memory.last;
    log.info("pane sidebar add pane dir={s} from={s}", .{ @tagName(dir), from });
    _ = raiseWindow(key);
    f.tab.getSplitTree().newSplit(add_rules.as(Surface.Tree.Split.Direction, dir), f.tab.getActiveSurface(), .none) catch |err| {
        log.warn("pane sidebar add pane failed err={}", .{err});
    };
}

/// The rail's + (T3695; Mac `PaneSidebarRailAddSlot`, win32 `railAdd`): it
/// heads the list it sits over, so in this window's panes it is the window
/// header's + - a new pane here - and in all windows the panel header's - a
/// new window, as Ctrl+Shift+N.
fn railAddClicked(self: *PaneSidebar) void {
    switch (add_rules.railAdd(scope.all_windows)) {
        .new_window => {
            log.info("pane sidebar add window (rail)", .{});
            _ = self.window.as(gtk.Widget).activateAction("win.new-window", null);
        },
        .new_pane => {
            const tab = self.window.getSelectedTab() orelse return;
            const key = @intFromPtr(tab);
            const f = findTab(key) orelse return;
            addPaneTo(f, key, "rail");
        },
    }
}

/// The panel header's +: a new window, exactly Ctrl+Shift+N from this
/// window's focused pane.
fn newWindowHere(self: *PaneSidebar) void {
    log.info("pane sidebar add window (header)", .{});
    _ = self.window.as(gtk.Widget).activateAction("win.new-window", null);
}

/// The panel header's + (the seam). False when it is not on screen.
pub fn clickHeaderAdd(self: *PaneSidebar) bool {
    if (wk.gtk_widget_get_visible(self.add_button) == 0) return false;
    self.newWindowHere();
    return true;
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
    if (r.kind == .pane or r.kind == .tile or r.kind == .rail_add) return false;
    toggleFold(r.kind, r.key);
    return true;
}

/// A row's Alt-click, by id (the seam; T3667).
pub fn altClickRow(self: *PaneSidebar, id: []const u8) bool {
    const r = self.rowById(id) orelse return false;
    if (r.kind != .pane) return false;
    return self.activatePane(r.id, true);
}

/// Whether Alt is held on the keyboard right now: what makes a row's click
/// an Alt-click (a button's `clicked` carries no event state in GTK4).
fn altHeld() bool {
    const display = gdk.Display.getDefault() orelse return false;
    const seat = display.getDefaultSeat() orelse return false;
    const keyboard = seat.getKeyboard() orelse return false;
    return keyboard.getModifierState().alt_mask;
}

/// Focus the pane with this id: in this window's active tab, or - from the
/// all-windows list - in any window, selecting its tab and raising its
/// window. False when no window holds it.
pub fn focusPane(self: *PaneSidebar, pane_id: []const u8) bool {
    return self.activatePane(pane_id, false);
}

/// `focusPane`, or with `exchange` the Alt-click (T3667, win32
/// `paneSidebarExchange` T1845, Mac `exchangeStashedPane`): a stashed pane
/// of the tab on show takes the focused pane's slot, and the focused pane
/// takes its place in the stash. Anywhere else an Alt-click is a click.
fn activatePane(self: *PaneSidebar, pane_id: []const u8, exchange: bool) bool {
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
                log.info("pane sidebar row clicked pane={s} other_window={} stashed={} alt={}", .{ pane_id, !here, pane_stash.isStashed(entry.view), exchange });
                // A stashed pane's row restores it to its slot, focused (T3596);
                // Alt swaps it with the focused pane instead (T3667).
                if (exchange and here and pane_stash.isStashed(entry.view))
                    _ = tab.getSplitTree().exchangeStashed(entry.view)
                else if (pane_stash.isStashed(entry.view))
                    _ = tab.getSplitTree().restoreSurface(entry.view, true)
                else
                    tab.getSplitTree().focusSurface(entry.view);
                // Another window's (or tab's) pane: its own present request
                // selects its tab and raises its window - in single-window
                // mode, puts its workspace on show, a turn later (T3649).
                if (!here) {
                    if (Workspaces.applies(win) and win != self.window)
                        raiseLater(.{ .pane = pane_id })
                    else
                        entry.view.present();
                }
                return true;
            }
        }
    }
    return false;
}

/// A switch the all-windows list asked for, run on the next idle turn
/// (T3649, win32 `showWorkspaceLater`): in single-window mode the hand-off
/// takes the clicked sidebar's own workspace out of the window, in the
/// middle of the click's signal. The latest request wins; what it names is
/// looked up again when it runs, never trusted.
const PendingRaise = union(enum) { tab: u64, pane: []const u8 };
var pending_raise_kind: enum { none, tab, pane } = .none;
var pending_raise_tab: u64 = 0;
var pending_raise_pane: [64]u8 = undefined;
var pending_raise_pane_len: usize = 0;

fn raiseLater(req: PendingRaise) void {
    const first = pending_raise_kind == .none;
    switch (req) {
        .tab => |k| {
            pending_raise_kind = .tab;
            pending_raise_tab = k;
        },
        .pane => |id| {
            const n = @min(id.len, pending_raise_pane.len);
            @memcpy(pending_raise_pane[0..n], id[0..n]);
            pending_raise_pane_len = n;
            pending_raise_kind = .pane;
        },
    }
    if (first) _ = wk.g_idle_add(@ptrCast(&onRaiseIdle), null);
}

fn onRaiseIdle(_: ?*anyopaque) callconv(.c) c_int {
    const kind = pending_raise_kind;
    pending_raise_kind = .none;
    switch (kind) {
        .none => {},
        .tab => if (findTab(pending_raise_tab)) |f| {
            log.info("workspace switch from the sidebar key={x}", .{pending_raise_tab});
            f.win.getTabView().setSelectedPage(f.win.getTabView().getPage(f.tab.as(gtk.Widget)));
            f.win.bringForward();
        },
        .pane => if (findPane(pending_raise_pane[0..pending_raise_pane_len])) |f| {
            log.info("workspace switch from the sidebar pane={s}", .{pending_raise_pane[0..pending_raise_pane_len]});
            f.surface.present();
        },
    }
    return 0; // G_SOURCE_REMOVE
}

/// Bring the window (tab) with this key forward: select its tab and raise
/// its window - in single-window mode, put its workspace on show (Mac
/// `bringForward`), a turn later. False when it is gone.
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
            if (Workspaces.applies(win)) {
                raiseLater(.{ .tab = key });
                return true;
            }
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
        .stashed = r.stashed,
        .kind = switch (r.kind) {
            .pane => if (r.viewer) "viewer" else "terminal",
            else => @tagName(r.kind),
        },
        .count = r.count,
        .folded = r.folded,
        .depth = r.depth,
        .selection = @tagName(r.selection),
        .tools = r.tools,
        .hovered = r.hovered,
        .tools_shown = if (r.tools_box) |b| wk.gtk_widget_get_visible(b) != 0 else false,
        .draggable = r.draggable,
        .top = if (self.rowBounds(r)) |b| @intFromFloat(@round(b.y)) else -1,
        .height = if (self.rowBounds(r)) |b| @intFromFloat(@round(b.h)) else 0,
    };
    var qb: [search_cap * 3]u8 = undefined;
    return .{
        .menu = try self.menuReport(arena),
        .editing = try self.editReport(arena),
        .add_shown = wk.gtk_widget_get_visible(self.add_button) != 0,
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
