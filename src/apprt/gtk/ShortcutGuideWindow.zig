//! The keyboard shortcut guide on GTK (T3570, Linux L11h) - Mac's
//! `ShortcutGuideController` + `ShortcutGuideView` and win32's
//! `ShortcutGuideWindow.zig` (docs/reference/keyboard-shortcuts.md).
//!
//! Opened by the main menu's "Keyboard Shortcuts", the
//! `show_keyboard_shortcuts` action (Ctrl+Shift+/ - GTK's own Ctrl+? - on
//! Linux; plain Ctrl+/ is the shell's ^_ undo) or the command palette's
//! "Show Keyboard Shortcuts".
//!
//! Nothing here is a list of shortcuts: every row is win32's pure
//! `shortcut_catalog.zig`, built from the LIVE config against a freshly built
//! default config, so a rebind, an unbind or a key table shows up as it is,
//! and the curation (titles, categories, what may be run) is the one table
//! both non-Mac frontends share. The window is rebuilt when the config
//! changes (`configChanged`, from the app's `config_change`).
//!
//! Layout: categories with live counts in a sidebar; a search field over the
//! rows grouped under category headers, each with its keycaps and badges; a
//! footer with the counts, "Show unbound actions", "Open Config File" and
//! "Print Cheat Sheet…".
//!
//! Keys (Mac's local key monitor, scoped to this window): Up/Down move the
//! selection even while typing in the search field, Return runs it, Escape
//! clears the search, then the selection, then closes; Ctrl+F focuses the
//! search.
//!
//! Instrumentation: the debug-only `shortcut-guide` seam in `IpcHandlers.zig`
//! (win32's op names and reply shape) drives this window and reports its
//! model, which `test/linux/shortcut-guide.sh` asserts.
const ShortcutGuideWindow = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const keybind_list = @import("../../config/keybind_list.zig");
const catalog_mod = @import("../win32/shortcut_catalog.zig");
const wk = @import("webkit.zig");

const gobject = @import("gobject");
const gtk = @import("gtk");

const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;

const log = std.log.scoped(.gtk_shortcut_guide);

const Catalog = catalog_mod.Catalog;
pub const Category = catalog_mod.Category;
pub const Row = catalog_mod.Row;

/// GDK keyvals the guide routes itself.
const key_up: c_uint = 0xff52;
const key_down: c_uint = 0xff54;
const key_return: c_uint = 0xff0d;
const key_kp_enter: c_uint = 0xff8d;
const key_escape: c_uint = 0xff1b;
const key_f: c_uint = 0x066;
const key_F: c_uint = 0x046;
const control_mask: c_uint = 1 << 2;

gpa: Allocator,
app: *Application,
window: *wk.GtkWidget,
search: *wk.GtkWidget,
sidebar: *wk.GtkWidget,
list: *wk.GtkWidget,
scroller: *wk.GtkWidget,
footer: *wk.GtkWidget,
unbound_check: *wk.GtkWidget,

/// Owns the catalog (rebuilt on config change).
catalog_arena: std.heap.ArenaAllocator,
catalog: Catalog = .{ .rows = &.{} },
/// Owns `rows` and `items` (rebuilt on every filter change).
view_arena: std.heap.ArenaAllocator,
rows: []const Row = &.{},
/// One entry per list-box row: the index into `rows`, or null for a
/// category header.
items: []const ?usize = &.{},
/// The Run button of each row in `rows` (null when not runnable).
run_buttons: []?*wk.GtkWidget = &.{},
counts: [Category.count]usize = @splat(0),
all_count: usize = 0,
bound_total: usize = 0,
customized_total: usize = 0,

query_buf: std.ArrayListUnmanaged(u8) = .empty,
/// Null is "All Shortcuts".
category: ?Category = null,
include_unbound: bool = false,
/// Index into `rows`.
selection: ?usize = null,
/// The last action a Run performed - the seam reports it.
last_run: std.ArrayListUnmanaged(u8) = .empty,
/// Set while the guide itself rebuilds or selects, so the list's and the
/// sidebar's own signals do not feed back into the model.
updating: bool = false,
/// The category a sidebar click picked, applied on idle.
pending_category: ?Category = null,

var open_window: ?*ShortcutGuideWindow = null;

/// The open guide, for the test seam.
pub fn current() ?*ShortcutGuideWindow {
    return open_window;
}

/// Open the guide, or bring the open one forward.
pub fn open(app: *Application) void {
    if (open_window) |w| {
        wk.gtk_window_present(w.window);
        log.info("shortcut guide: already open", .{});
        return;
    }
    const gpa = app.allocator();
    const self = gpa.create(ShortcutGuideWindow) catch return;
    self.* = .{
        .gpa = gpa,
        .app = app,
        .window = wk.gtk_window_new(),
        .search = wk.gtk_search_entry_new(),
        .sidebar = wk.gtk_list_box_new(),
        .list = wk.gtk_list_box_new(),
        .scroller = wk.gtk_scrolled_window_new(),
        .footer = wk.gtk_label_new(null),
        .unbound_check = wk.gtk_check_button_new_with_label("Show unbound actions"),
        .catalog_arena = .init(gpa),
        .view_arena = .init(gpa),
        .include_unbound = loadIncludeUnbound(gpa),
    };
    open_window = self;
    self.rebuildCatalog();
    self.buildChrome();
    self.refresh();
    wk.gtk_window_present(self.window);
    _ = wk.gtk_widget_grab_focus(self.search);
    log.info("shortcut guide: opened rows={d} bound={d} customized={d}", .{
        self.catalog.rows.len, self.bound_total, self.customized_total,
    });
}

/// The config changed: rebuild from the new one, so a reloaded rebind shows
/// up live (Mac reloads on `ghosttyConfigDidChange`).
pub fn configChanged() void {
    const self = open_window orelse return;
    self.rebuildCatalog();
    self.refresh();
    log.info("shortcut guide: config changed rows={d}", .{self.catalog.rows.len});
}

// ---------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------

/// Effective bindings from the live config; defaults from a fresh one.
fn rebuildCatalog(self: *ShortcutGuideWindow) void {
    _ = self.catalog_arena.reset(.retain_capacity);
    const arena = self.catalog_arena.allocator();
    const cfg = self.app.getConfig();
    defer cfg.unref();
    const effective = keybind_list.entries(arena, &cfg.get().keybind) catch &.{};
    var defaults: []const catalog_mod.Entry = &.{};
    if (configpkg.Config.default(self.gpa)) |cfg_val| {
        var def = cfg_val;
        defer def.deinit();
        def.finalize() catch {};
        // `entries` dupes everything into `arena`, so the strings outlive def.
        defaults = keybind_list.entries(arena, &def.keybind) catch &.{};
    } else |_| {}
    self.catalog = Catalog.build(arena, effective, defaults) catch .{ .rows = &.{} };
}

pub fn query(self: *const ShortcutGuideWindow) []const u8 {
    return self.query_buf.items;
}

fn options(self: *const ShortcutGuideWindow) Catalog.Options {
    return .{ .query = self.query(), .category = self.category, .include_unbound = self.include_unbound };
}

/// Re-filter, re-count and redraw the list, the sidebar and the footer.
fn refresh(self: *ShortcutGuideWindow) void {
    _ = self.view_arena.reset(.retain_capacity);
    const arena = self.view_arena.allocator();
    self.rows = self.catalog.visible(arena, self.options()) catch &.{};
    self.counts = self.catalog.counts(arena, self.options()) catch @splat(0);
    self.all_count = 0;
    for (self.counts) |c| self.all_count += c;
    if (self.catalog.summary(arena)) |s| {
        self.bound_total = s.bound;
        self.customized_total = s.customized;
    } else |_| {}
    if (self.selection) |sel| if (sel >= self.rows.len) {
        self.selection = null;
    };
    self.updating = true;
    defer self.updating = false;
    self.fillSidebar();
    self.fillList() catch |err| log.warn("shortcut guide: list failed err={}", .{err});
    self.fillFooter();
    self.showSelection();
}

pub fn selectedRow(self: *const ShortcutGuideWindow) ?Row {
    const sel = self.selection orelse return null;
    if (sel >= self.rows.len) return null;
    return self.rows[sel];
}

pub fn lastRun(self: *const ShortcutGuideWindow) []const u8 {
    return self.last_run.items;
}

// ---------------------------------------------------------------------
// Commands (the window's verbs; the IPC seam calls these too)
// ---------------------------------------------------------------------

/// Typing in the search field.
pub fn setQuery(self: *ShortcutGuideWindow, text: []const u8) void {
    self.query_buf.clearRetainingCapacity();
    self.query_buf.appendSlice(self.gpa, text) catch return;
    // Typing a query always searches every category (Mac).
    if (text.len > 0) self.category = null;
    self.selection = null;
    self.refresh();
    if (text.len > 0 and self.rows.len > 0) {
        self.selection = 0;
        self.showSelection();
    }
    // Keep the field in step when the seam (not the user) typed.
    const shown = std.mem.span(wk.gtk_editable_get_text(self.search));
    if (!std.mem.eql(u8, shown, text)) {
        const z = self.gpa.dupeZ(u8, text) catch return;
        defer self.gpa.free(z);
        self.updating = true;
        defer self.updating = false;
        wk.gtk_editable_set_text(self.search, z.ptr);
    }
}

/// Picking a category in the sidebar (null is "All Shortcuts").
pub fn setCategory(self: *ShortcutGuideWindow, cat: ?Category) void {
    self.category = cat;
    self.selection = null;
    if (self.query_buf.items.len > 0) {
        // Picking a category clears the search, as on the Mac.
        self.query_buf.clearRetainingCapacity();
        self.updating = true;
        wk.gtk_editable_set_text(self.search, "");
        self.updating = false;
    }
    self.refresh();
}

/// The "Show unbound actions" toggle, remembered across launches.
pub fn setIncludeUnbound(self: *ShortcutGuideWindow, on: bool) void {
    self.include_unbound = on;
    saveIncludeUnbound(self.gpa, on);
    if ((wk.gtk_check_button_get_active(self.unbound_check) != 0) != on) {
        self.updating = true;
        wk.gtk_check_button_set_active(self.unbound_check, @intFromBool(on));
        self.updating = false;
    }
    self.refresh();
}

/// Up/Down.
pub fn moveSelection(self: *ShortcutGuideWindow, delta: i32) void {
    if (self.rows.len == 0) return;
    const last: i32 = @intCast(self.rows.len - 1);
    const next: i32 = if (self.selection) |s|
        std.math.clamp(@as(i32, @intCast(s)) + delta, 0, last)
    else if (delta > 0) 0 else last;
    self.selection = @intCast(next);
    self.showSelection();
}

/// Escape: clear the search, then the selection, then close (Mac).
pub fn escape(self: *ShortcutGuideWindow) void {
    if (self.query_buf.items.len > 0) {
        self.setQuery("");
    } else if (self.selection != null) {
        self.selection = null;
        self.showSelection();
    } else {
        self.close();
    }
}

/// Return, or the row's Run button: run the selected row when it may be run.
pub fn runSelection(self: *ShortcutGuideWindow) bool {
    const row = self.selectedRow() orelse return false;
    return self.runRow(row);
}

/// The terminal window a Run goes to: the most recently focused one
/// (`gtk_application_get_windows` is in focus order; the guide is not one of
/// the application's windows), else none.
fn targetWindow(self: *ShortcutGuideWindow) ?*Window {
    var node: ?*@import("glib").List = self.app.as(gtk.Application).getWindows();
    while (node) |n| : (node = n.f_next) {
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const w = gobject.ext.cast(Window, obj) orelse continue;
        if (w.isQuickTerminal()) continue;
        return w;
    }
    return null;
}

fn runRow(self: *ShortcutGuideWindow, row: Row) bool {
    if (!row.runnable or row.actions.len == 0) return false;
    const action = input.Binding.Action.parse(row.action()) catch |err| {
        log.warn("shortcut guide: cannot parse action {s} err={}", .{ row.action(), err });
        return false;
    };
    const win = self.targetWindow() orelse return false;
    const surface = win.getActiveSurface() orelse return false;
    win.as(gtk.Window).present();
    if (surface.core()) |core_surface| {
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("shortcut guide: run {s} failed err={}", .{ row.action(), err });
            return false;
        };
    } else if (surface.isViewer()) {
        // A viewer pane has no core surface: its chord's own route (T3430).
        if (!self.app.performViewerAction(surface, action)) return false;
    } else return false;
    self.last_run.clearRetainingCapacity();
    self.last_run.appendSlice(self.gpa, row.action()) catch {};
    log.info("shortcut guide: ran {s}", .{row.action()});
    return true;
}

/// Write the cheat sheet - every bound shortcut by category - as HTML and
/// return its path (caller frees). Mac's "Print Cheat Sheet…" prints; here,
/// as on Windows, the page opens in the browser, whose Print does the rest.
pub fn writeCheatSheet(self: *ShortcutGuideWindow, alloc: Allocator) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try self.catalog.visible(arena, .{});
    const html = try catalog_mod.cheatSheetHtml(arena, rows);
    const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse std.posix.getenv("TMPDIR") orelse "/tmp";
    const path = try std.fs.path.join(alloc, &.{
        dir,
        if (build_config.is_debug) "ghoztty-shortcuts-debug.html" else "ghoztty-shortcuts.html",
    });
    errdefer alloc.free(path);
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(html);
    return path;
}

/// Close the guide: its title-bar button, Escape, and the seam's `close`.
pub fn close(self: *ShortcutGuideWindow) void {
    wk.gtk_window_destroy(self.window);
    self.destroy();
}

fn destroy(self: *ShortcutGuideWindow) void {
    if (open_window == self) open_window = null;
    const gpa = self.gpa;
    self.query_buf.deinit(gpa);
    self.last_run.deinit(gpa);
    self.view_arena.deinit();
    self.catalog_arena.deinit();
    gpa.destroy(self);
    log.info("shortcut guide: closed", .{});
}

// ---------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------

fn buildChrome(self: *ShortcutGuideWindow) void {
    const w = self.window;
    // Mac's title and size (`ShortcutGuideController`: 880x640).
    wk.gtk_window_set_title(w, "Keyboard Shortcuts");
    wk.gtk_window_set_default_size(w, 880, 640);
    wk.gtk_widget_add_css_class(w, "ghoztty-shortcut-guide");
    _ = wk.g_signal_connect_data(w, "close-request", @ptrCast(&onCloseRequest), self, null, 0);

    // The window's own key routing, ahead of the focused widget (capture),
    // so Up/Down/Return/Escape work while the search field has the caret.
    const keys = wk.gtk_event_controller_key_new();
    wk.gtk_event_controller_set_propagation_phase(keys, 1); // GTK_PHASE_CAPTURE
    _ = wk.g_signal_connect_data(@ptrCast(keys), "key-pressed", @ptrCast(&onKeyPressed), self, null, 0);
    wk.gtk_widget_add_controller(w, keys);

    const outer = wk.gtk_box_new(0, 0);

    // Sidebar: All Shortcuts + one entry per category, with counts.
    wk.gtk_list_box_set_selection_mode(self.sidebar, 1); // single
    wk.gtk_widget_add_css_class(self.sidebar, "navigation-sidebar");
    wk.gtk_widget_set_focusable(self.sidebar, 0);
    _ = wk.g_signal_connect_data(self.sidebar, "row-selected", @ptrCast(&onSidebarSelected), self, null, 0);
    const side_scroll = wk.gtk_scrolled_window_new();
    wk.gtk_scrolled_window_set_policy(side_scroll, 2, 0);
    wk.gtk_widget_set_size_request(side_scroll, 200, -1);
    wk.gtk_scrolled_window_set_child(side_scroll, self.sidebar);
    wk.gtk_box_append(outer, side_scroll);
    wk.gtk_box_append(outer, wk.gtk_separator_new(1));

    const column = wk.gtk_box_new(1, 8);
    wk.gtk_widget_set_hexpand(column, 1);
    wk.gtk_widget_set_margin_start(column, 16);
    wk.gtk_widget_set_margin_end(column, 16);
    wk.gtk_widget_set_margin_top(column, 12);
    wk.gtk_widget_set_margin_bottom(column, 12);

    wk.gtk_search_entry_set_placeholder_text(self.search, "Search shortcuts or press keys like ctrl shift p");
    wk.gtk_search_entry_set_search_delay(self.search, 0);
    _ = wk.g_signal_connect_data(self.search, "search-changed", @ptrCast(&onSearchChanged), self, null, 0);
    wk.gtk_box_append(column, self.search);

    wk.gtk_list_box_set_selection_mode(self.list, 1); // single
    wk.gtk_list_box_set_activate_on_single_click(self.list, 0);
    wk.gtk_widget_add_css_class(self.list, "boxed-list");
    _ = wk.g_signal_connect_data(self.list, "row-selected", @ptrCast(&onListSelected), self, null, 0);
    _ = wk.g_signal_connect_data(self.list, "row-activated", @ptrCast(&onListActivated), self, null, 0);
    wk.gtk_scrolled_window_set_policy(self.scroller, 2, 0); // never, automatic
    wk.gtk_widget_set_vexpand(self.scroller, 1);
    wk.gtk_scrolled_window_set_child(self.scroller, self.list);
    wk.gtk_box_append(column, self.scroller);

    // Footer: counts, the unbound toggle, Open Config File, the cheat sheet.
    const foot = wk.gtk_box_new(0, 12);
    wk.gtk_widget_add_css_class(self.footer, "dim-label");
    wk.gtk_widget_add_css_class(self.footer, "caption");
    wk.gtk_label_set_xalign(self.footer, 0.0);
    wk.gtk_widget_set_hexpand(self.footer, 1);
    wk.gtk_box_append(foot, self.footer);
    wk.gtk_check_button_set_active(self.unbound_check, @intFromBool(self.include_unbound));
    _ = wk.g_signal_connect_data(self.unbound_check, "toggled", @ptrCast(&onUnboundToggled), self, null, 0);
    wk.gtk_box_append(foot, self.unbound_check);
    const open_file = wk.gtk_button_new_with_label("Open Config File");
    wk.gtk_widget_set_tooltip_text(open_file, "Open the config file in your text editor");
    _ = wk.g_signal_connect_data(open_file, "clicked", @ptrCast(&onOpenFileClicked), self, null, 0);
    wk.gtk_box_append(foot, open_file);
    const print = wk.gtk_button_new_with_label("Print Cheat Sheet\u{2026}");
    wk.gtk_widget_set_tooltip_text(print, "Every bound shortcut by category, as a page to print or save as PDF");
    _ = wk.g_signal_connect_data(print, "clicked", @ptrCast(&onPrintClicked), self, null, 0);
    wk.gtk_box_append(foot, print);
    wk.gtk_box_append(column, foot);

    wk.gtk_box_append(outer, column);
    wk.gtk_window_set_child(w, outer);
}

fn fillSidebar(self: *ShortcutGuideWindow) void {
    wk.gtk_list_box_remove_all(self.sidebar);
    var buf: [128]u8 = undefined;
    const all = std.fmt.bufPrintZ(&buf, "All Shortcuts  {d}", .{self.all_count}) catch "All Shortcuts";
    wk.gtk_list_box_append(self.sidebar, sidebarLabel(all));
    for (std.enums.values(Category)) |c| {
        const text = std.fmt.bufPrintZ(&buf, "{s}  {d}", .{ c.title(), self.counts[@intFromEnum(c)] }) catch continue;
        wk.gtk_list_box_append(self.sidebar, sidebarLabel(text));
    }
    // While a query searches every category nothing is picked.
    const idx: ?c_int = if (self.query_buf.items.len > 0)
        null
    else if (self.category) |c| @as(c_int, @intCast(@intFromEnum(c))) + 1 else 0;
    const row = if (idx) |i| wk.gtk_list_box_get_row_at_index(self.sidebar, i) else null;
    wk.gtk_list_box_select_row(self.sidebar, row);
}

fn sidebarLabel(text: [*:0]const u8) *wk.GtkWidget {
    const l = wk.gtk_label_new(text);
    wk.gtk_label_set_xalign(l, 0.0);
    wk.gtk_widget_set_margin_start(l, 8);
    wk.gtk_widget_set_margin_top(l, 4);
    wk.gtk_widget_set_margin_bottom(l, 4);
    return l;
}

fn fillList(self: *ShortcutGuideWindow) !void {
    wk.gtk_list_box_remove_all(self.list);
    const arena = self.view_arena.allocator();
    var items: std.ArrayList(?usize) = .empty;
    self.run_buttons = try arena.alloc(?*wk.GtkWidget, self.rows.len);
    @memset(self.run_buttons, null);
    var current_cat: ?Category = null;
    for (self.rows, 0..) |r, i| {
        if (current_cat != r.category) {
            current_cat = r.category;
            const header = wk.gtk_list_box_row_new();
            wk.gtk_list_box_row_set_selectable(header, 0);
            wk.gtk_list_box_row_set_activatable(header, 0);
            const label = wk.gtk_label_new((try arena.dupeZ(u8, r.category.title())).ptr);
            wk.gtk_widget_add_css_class(label, "heading");
            wk.gtk_label_set_xalign(label, 0.0);
            wk.gtk_widget_set_margin_start(label, 12);
            wk.gtk_widget_set_margin_top(label, 10);
            wk.gtk_widget_set_margin_bottom(label, 4);
            wk.gtk_list_box_row_set_child(header, label);
            wk.gtk_list_box_append(self.list, header);
            try items.append(arena, null);
        }
        const row = wk.gtk_list_box_row_new();
        wk.gtk_list_box_row_set_child(row, try self.rowWidget(arena, r, i));
        wk.gtk_list_box_append(self.list, row);
        try items.append(arena, i);
    }
    if (self.rows.len == 0) {
        const empty = wk.gtk_list_box_row_new();
        wk.gtk_list_box_row_set_selectable(empty, 0);
        const label = wk.gtk_label_new(if (self.query_buf.items.len > 0) "No shortcuts match your search." else "No shortcuts here.");
        wk.gtk_widget_add_css_class(label, "dim-label");
        wk.gtk_widget_set_margin_top(label, 24);
        wk.gtk_widget_set_margin_bottom(label, 24);
        wk.gtk_list_box_row_set_child(empty, label);
        wk.gtk_list_box_append(self.list, empty);
        try items.append(arena, null);
    }
    self.items = items.items;
}

fn rowWidget(self: *ShortcutGuideWindow, arena: Allocator, r: Row, index: usize) !*wk.GtkWidget {
    const line = wk.gtk_box_new(0, 12);
    wk.gtk_widget_set_margin_start(line, 12);
    wk.gtk_widget_set_margin_end(line, 12);
    wk.gtk_widget_set_margin_top(line, 6);
    wk.gtk_widget_set_margin_bottom(line, 6);

    const text = wk.gtk_box_new(1, 2);
    wk.gtk_widget_set_hexpand(text, 1);
    const title_line = wk.gtk_box_new(0, 6);
    const title = wk.gtk_label_new((try arena.dupeZ(u8, r.title)).ptr);
    wk.gtk_label_set_xalign(title, 0.0);
    wk.gtk_box_append(title_line, title);
    if (r.customized or r.unbound_by_user) wk.gtk_box_append(title_line, badge("CUSTOM"));
    if (r.kind == .built_in) wk.gtk_box_append(title_line, badge("BUILT-IN"));
    if (r.isGlobal()) wk.gtk_box_append(title_line, badge("GLOBAL"));
    if (r.table()) |t| wk.gtk_box_append(title_line, badge((try arena.dupeZ(u8, try std.fmt.allocPrint(arena, "TABLE {s}", .{t}))).ptr));
    wk.gtk_box_append(text, title_line);
    const detail_text = if (r.unbound_by_user)
        try std.fmt.allocPrint(arena, "{s} Unbound in your config.", .{r.detail})
    else
        r.detail;
    const detail = wk.gtk_label_new((try arena.dupeZ(u8, detail_text)).ptr);
    wk.gtk_widget_add_css_class(detail, "dim-label");
    wk.gtk_widget_add_css_class(detail, "caption");
    wk.gtk_label_set_xalign(detail, 0.0);
    wk.gtk_label_set_wrap(detail, 1);
    wk.gtk_box_append(text, detail);
    wk.gtk_box_append(line, text);

    // Keycaps: one group per binding.
    const caps_col = wk.gtk_box_new(1, 4);
    wk.gtk_widget_set_valign(caps_col, 3); // center
    if (r.bindings.len == 0) {
        const none = wk.gtk_label_new("Not bound");
        wk.gtk_widget_add_css_class(none, "dim-label");
        wk.gtk_box_append(caps_col, none);
    }
    for (r.bindings) |b| {
        const group = wk.gtk_box_new(0, 3);
        wk.gtk_widget_set_halign(group, 2); // end
        for (try catalog_mod.caps(arena, b)) |cap| {
            const l = wk.gtk_label_new((try arena.dupeZ(u8, cap.label)).ptr);
            wk.gtk_widget_add_css_class(l, if (cap.is_joiner) "dim-label" else "ghoztty-keycap");
            wk.gtk_box_append(group, l);
        }
        wk.gtk_box_append(caps_col, group);
    }
    wk.gtk_box_append(line, caps_col);

    // Run, offered only for rows safe to run from here; shown on the
    // selected row (Mac shows it on hover/selection).
    if (r.runnable) {
        const run = wk.gtk_button_new_from_icon_name("media-playback-start-symbolic");
        wk.gtk_widget_add_css_class(run, "flat");
        wk.gtk_widget_set_valign(run, 3);
        wk.gtk_widget_set_tooltip_text(run, "Run in the terminal window (Return)");
        wk.gtk_widget_set_focusable(run, 0);
        wk.g_object_set_data(@ptrCast(run), "guide-row", @ptrFromInt(index + 1));
        _ = wk.g_signal_connect_data(run, "clicked", @ptrCast(&onRunClicked), self, null, 0);
        wk.gtk_widget_set_visible(run, 0);
        wk.gtk_box_append(line, run);
        self.run_buttons[index] = run;
    }
    return line;
}

fn badge(text: [*:0]const u8) *wk.GtkWidget {
    const l = wk.gtk_label_new(text);
    wk.gtk_widget_add_css_class(l, "ghoztty-badge");
    wk.gtk_widget_set_valign(l, 3);
    return l;
}

fn fillFooter(self: *ShortcutGuideWindow) void {
    var buf: [160]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "{d} shortcuts \u{00B7} {d} customized", .{
        self.bound_total, self.customized_total,
    }) catch return;
    wk.gtk_label_set_text(self.footer, text.ptr);
}

/// Mirror `selection` into the list (and its Run button), and scroll it
/// into view.
fn showSelection(self: *ShortcutGuideWindow) void {
    const was = self.updating;
    self.updating = true;
    defer self.updating = was;
    for (self.run_buttons, 0..) |b, i| if (b) |btn| {
        wk.gtk_widget_set_visible(btn, @intFromBool(self.selection == i));
    };
    const sel = self.selection orelse {
        wk.gtk_list_box_unselect_all(self.list);
        return;
    };
    const li = self.listIndexOf(sel) orelse return;
    const row = wk.gtk_list_box_get_row_at_index(self.list, @intCast(li)) orelse return;
    wk.gtk_list_box_select_row(self.list, row);
    // Scroll: the row's top in list coordinates against the viewport.
    var origin: wk.GraphenePoint = .{ .x = 0, .y = 0 };
    var at: wk.GraphenePoint = .{ .x = 0, .y = 0 };
    if (wk.gtk_widget_compute_point(row, self.list, &origin, &at) == 0) return;
    const adj = wk.gtk_scrolled_window_get_vadjustment(self.scroller);
    const top = wk.gtk_adjustment_get_value(adj);
    const page = wk.gtk_adjustment_get_page_size(adj);
    const h: f64 = @floatFromInt(wk.gtk_widget_get_height(row));
    const y: f64 = at.y;
    if (y < top) wk.gtk_adjustment_set_value(adj, y) else if (y + h > top + page) wk.gtk_adjustment_set_value(adj, y + h - page);
}

fn listIndexOf(self: *const ShortcutGuideWindow, row_index: usize) ?usize {
    for (self.items, 0..) |it, li| if (it) |ri| if (ri == row_index) return li;
    return null;
}

// ---------------------------------------------------------------------
// Signals
// ---------------------------------------------------------------------

fn onCloseRequest(_: *wk.GtkWidget, self: *ShortcutGuideWindow) callconv(.c) c_int {
    self.destroy();
    return 0; // let GTK destroy the window
}

fn onKeyPressed(_: *wk.GtkEventController, keyval: c_uint, _: c_uint, state: c_uint, self: *ShortcutGuideWindow) callconv(.c) c_int {
    switch (keyval) {
        key_up => self.moveSelection(-1),
        key_down => self.moveSelection(1),
        key_return, key_kp_enter => {
            if (self.selection == null) return 0;
            _ = self.runSelection();
        },
        key_escape => {
            // On idle: Escape may close the window, which must not happen
            // under its own controller's signal.
            _ = wk.g_idle_add(@ptrCast(&onIdleEscape), self);
        },
        key_f, key_F => {
            if (state & control_mask == 0) return 0;
            _ = wk.gtk_widget_grab_focus(self.search);
        },
        else => return 0,
    }
    return 1; // handled
}

fn onIdleEscape(self: *ShortcutGuideWindow) callconv(.c) c_int {
    if (open_window == self) self.escape();
    return 0; // G_SOURCE_REMOVE
}

fn onSearchChanged(entry: *wk.GtkWidget, self: *ShortcutGuideWindow) callconv(.c) void {
    if (self.updating) return;
    self.setQuery(std.mem.span(wk.gtk_editable_get_text(entry)));
}

fn onSidebarSelected(_: *wk.GtkWidget, row: ?*wk.GtkWidget, self: *ShortcutGuideWindow) callconv(.c) void {
    if (self.updating) return;
    const r = row orelse return;
    const idx = wk.gtk_list_box_row_get_index(r);
    const cat: ?Category = if (idx <= 0) null else std.meta.intToEnum(Category, idx - 1) catch null;
    // Rebuilding the sidebar under its own signal is not safe: on idle.
    self.pending_category = cat;
    _ = wk.g_idle_add(@ptrCast(&onIdleCategory), self);
}

fn onIdleCategory(self: *ShortcutGuideWindow) callconv(.c) c_int {
    if (open_window == self) self.setCategory(self.pending_category);
    return 0;
}

fn onListSelected(_: *wk.GtkWidget, row: ?*wk.GtkWidget, self: *ShortcutGuideWindow) callconv(.c) void {
    if (self.updating) return;
    const r = row orelse return;
    const li: usize = @intCast(@max(0, wk.gtk_list_box_row_get_index(r)));
    if (li >= self.items.len) return;
    self.selection = self.items[li] orelse return;
    for (self.run_buttons, 0..) |b, i| if (b) |btn| {
        wk.gtk_widget_set_visible(btn, @intFromBool(self.selection == i));
    };
}

fn onListActivated(_: *wk.GtkWidget, row: *wk.GtkWidget, self: *ShortcutGuideWindow) callconv(.c) void {
    const li: usize = @intCast(@max(0, wk.gtk_list_box_row_get_index(row)));
    if (li >= self.items.len) return;
    const ri = self.items[li] orelse return;
    _ = self.runRow(self.rows[ri]);
}

fn onRunClicked(button: *wk.GtkWidget, self: *ShortcutGuideWindow) callconv(.c) void {
    const tag = @intFromPtr(wk.g_object_get_data(@ptrCast(button), "guide-row"));
    if (tag == 0 or tag > self.rows.len) return;
    _ = self.runRow(self.rows[tag - 1]);
}

fn onUnboundToggled(button: *wk.GtkWidget, self: *ShortcutGuideWindow) callconv(.c) void {
    if (self.updating) return;
    self.setIncludeUnbound(wk.gtk_check_button_get_active(button) != 0);
}

fn onOpenFileClicked(_: *wk.GtkWidget, self: *ShortcutGuideWindow) callconv(.c) void {
    self.app.openConfigFile();
}

fn onPrintClicked(_: *wk.GtkWidget, self: *ShortcutGuideWindow) callconv(.c) void {
    const path = self.writeCheatSheet(self.gpa) catch |err| {
        log.warn("shortcut guide: cheat sheet failed err={}", .{err});
        return;
    };
    defer self.gpa.free(path);
    self.app.openHtmlFile(path);
}

// ---------------------------------------------------------------------
// The "Show unbound actions" preference (Mac: ShortcutGuideIncludeUnbound)
// ---------------------------------------------------------------------

/// `$XDG_STATE_HOME/ghoztty/shortcut-guide-unbound[-debug]`.
fn prefPath(alloc: Allocator) ?[]u8 {
    const name = if (build_config.is_debug) "shortcut-guide-unbound-debug" else "shortcut-guide-unbound";
    if (std.posix.getenv("XDG_STATE_HOME")) |s| if (s.len > 0) {
        return std.fs.path.join(alloc, &.{ s, "ghoztty", name }) catch null;
    };
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fs.path.join(alloc, &.{ home, ".local", "state", "ghoztty", name }) catch null;
}

fn loadIncludeUnbound(alloc: Allocator) bool {
    const path = prefPath(alloc) orelse return false;
    defer alloc.free(path);
    const f = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer f.close();
    var buf: [8]u8 = undefined;
    const n = f.readAll(&buf) catch return false;
    return n > 0 and buf[0] == '1';
}

fn saveIncludeUnbound(alloc: Allocator, on: bool) void {
    const path = prefPath(alloc) orelse return;
    defer alloc.free(path);
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch return;
    const f = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
    defer f.close();
    f.writeAll(if (on) "1" else "0") catch {};
}
