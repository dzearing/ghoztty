//! The Settings window on GTK (T3569, Linux L11g): `open_config` opens a
//! window that edits the user's config visually, instead of handing the file
//! to a text editor - Mac `Features/Settings/` and win32 `SettingsWindow.zig`.
//!
//! The rules are the Mac's (`docs/reference/settings.md`), and they are not
//! re-implemented here: the write path is win32's pure model, shared rather
//! than a third copy.
//!
//! - **The file is the source of truth.** Every change is ONE surgical edit
//!   (`ConfigFileText` through `SettingsModel`): only that key's line moves;
//!   comments, blank lines, includes and unknown keys stay byte for byte.
//! - **Every write re-reads the file first** (`ConfigFileStore.edit`), so an
//!   edit made in an editor a moment ago is never clobbered.
//! - **Invalid values are never written** (`ConfigValidator`, Ghostty's own
//!   parser on a scratch config): the row shows the problem, the file is
//!   untouched.
//! - **A key a later file overrides is read-only** here (`SettingsSources`),
//!   with the sentence naming that file.
//! - **Changes apply live**: a write performs `reload_config`, and a row
//!   reads its value straight from the file when the file sets it.
//! - **Which file**: `preferredDefaultFilePath` - in a debug build its own
//!   `config-debug.ghostty`, never the installed release's (`file_load`).
//!   Backups: `$XDG_STATE_HOME/ghoztty/config-backups`.
//!
//! **The curated pages (T3631)** are win32's presentation catalog
//! (`settings_pages.zig`), not a GTK table: a sidebar of pages, each key on
//! its page with its label and control, drawn with libadwaita rows -
//! `AdwSwitchRow` for a bool, `AdwComboRow` for an enum (listing any schema
//! option nobody curated, under its raw name), `AdwSpinRow` for a bounded
//! number or a size in MB, a `GtkScale` for a 0-1 slider (written once the
//! drag settles), an `AdwExpanderRow` of switches for packed flags, and a
//! shell picker that only accepts an executable that exists. A row carries
//! the changed-from-default dot and a reset button; a key a later file
//! overrides, or whose condition does not hold (Glass panes off the Elevated
//! style), is dimmed with the reason as its subtitle. Advanced holds the
//! config file and All Settings with Mac's All / Changed / Not on other
//! pages filter; a curated key's row there links to its page.
//!
//! **The Font row (T3765)** is Mac's `FontControl`: an `AdwComboRow` over the
//! monospaced families fontconfig knows (`font_families.zig`), Default
//! (JetBrains Mono) first, which removes the key. A pick replaces the first
//! `font-family` value of the user's file and keeps the fallbacks; "+N
//! fallback" sits beside it with the rest as its tooltip, and the fallbacks
//! are chips on a row below once the file names a font. A primary no
//! installed family matches is listed "(not installed)" and the subtitle
//! says Ghoztty uses the next font. The rules are `settings_controls.zig`'s,
//! shared with win32.
//!
//! **A repeatable key (T3632)** - Font features on its page, and every list
//! key under All Settings - is Mac's
//! `ListControl`: the user's file's values as removable chips, then an "add a
//! value" field. Both write through `SettingsModel.setList`, so the longest
//! run of existing lines that still matches stays put with its comments; a
//! value Ghostty refuses is not written and stays in the field with the
//! reason. All Settings adds Mac's "In effect:" line under a list row.
//!
//! **Advanced > Config file and the change toast (T3633)** are
//! `SettingsConfigFile.zig`: the file with Open in Editor / Show in Folder,
//! where it links to, every other file Ghostty loads, Backups with
//! Restore..., the current file, and the "Saved - Show Change - Undo" toast
//! over the foot of the window after every write.
//!
//! **Sessions & Agent's agent status and the Remote Machines page (T3635)**
//! are `SettingsLive.zig`: the agent read without spawning it, re-read each
//! time the page is shown, and the enrolled machines from the remembered
//! directory with a background presence fetch and Host Settings....
//!
//! **Appearance's theme picker and live preview (T3636)** are
//! `SettingsTheme.zig`: Mac's "Use" switch (one theme / light & dark), tabs
//! that list only their kind, the filter, a tile per theme with the picked
//! one ringed, and the preview card in the effective theme, font, opacity,
//! padding, pane style and cursor - on win32's shared `theme_catalog`,
//! `settings_theme_grid` and `settings_preview`.
//!
//! Rows are built once and refreshed in place after every write (a rebuild
//! would lose the page's scroll), from the same reader the seam reports.
const SettingsWindow = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const wk = @import("webkit.zig");

const ConfigFileStore = @import("../win32/ConfigFileStore.zig");
const ConfigFileText = @import("../win32/ConfigFileText.zig");
const SettingsCatalog = @import("../win32/SettingsCatalog.zig");
const SettingsModel = @import("../win32/SettingsModel.zig");
const SettingsSources = @import("../win32/SettingsSources.zig");
const pages = @import("../win32/settings_pages.zig");
const controls = @import("../win32/settings_controls.zig");
const shell_pick = @import("shell_pick.zig");

const Application = @import("class/application.zig").Application;
const ShortcutGuideWindow = @import("ShortcutGuideWindow.zig");
const font_families = @import("font_families.zig");
const ConfigFile = @import("SettingsConfigFile.zig");
pub const SettingsLive = @import("SettingsLive.zig");
pub const SettingsTheme = @import("SettingsTheme.zig");

const log = std.log.scoped(.gtk_settings);

pub const PageId = pages.PageId;
pub const Filter = SettingsSources.Reader.Filter;

/// One All Settings row as built: the key (borrowed from the catalog) and
/// the widgets a change touches.
const Row = struct {
    key: []const u8,
    /// A plain key's value field, or a repeatable key's "add a value" field.
    entry: *wk.GtkWidget,
    note: *wk.GtkWidget,
    /// A repeatable key's chip box (Mac `ListControl`) and its "In effect:"
    /// line; null for a plain key.
    chips: ?*wk.GtkWidget = null,
    in_effect: ?*wk.GtkWidget = null,
};

/// How a curated row is drawn.
pub const Kind = enum { toggle, choice, shell, spin, slider, flags, text, list, font };

/// One curated row as built. Widgets live as long as the window; strings and
/// slices are in `build_arena`.
pub const Curated = struct {
    def: *const pages.Row,
    /// The catalog's copy of the key.
    key: []const u8,
    kind: Kind,
    row: *wk.GtkWidget,
    dot: *wk.GtkWidget,
    reset: *wk.GtkWidget,
    /// A text row's field, a shell row's Other... field, or a list row's
    /// "add a value" field.
    entry: ?*wk.GtkWidget = null,
    /// A list row's chip box: one chip per value in the user's file.
    chips: ?*wk.GtkWidget = null,
    /// The row holding a shell row's Other... field, or the Font row's
    /// fallback chips.
    other_row: ?*wk.GtkWidget = null,
    /// The Font row's "+N fallback" (Mac's caption beside the picker).
    fallback_label: ?*wk.GtkWidget = null,
    /// The Font row's not-installed primary while its picker lists one
    /// (in `font_arena`); the items are rebuilt when this changes.
    font_extra: ?[]const u8 = null,
    scale: ?*wk.GtkWidget = null,
    /// A choice or shell row's items, in the popup's order (a shell row's
    /// list ends with Other..., which is not in here).
    choices: []const pages.Option = &.{},
    /// A flags row's switch per schema flag, in schema order.
    flag_rows: []*wk.GtkWidget = &.{},
    flag_names: []const []const u8 = &.{},
    /// The subtitle when nothing else needs saying: the hint, else the
    /// doc summary.
    base: [:0]const u8 = "",
    /// The subtitle as last set (what the row shows).
    subtitle: []const u8 = "",
};

gpa: Allocator,
app: *Application,
window: *wk.GtkWidget,
search: *wk.GtkWidget,
list: *wk.GtkWidget,
sidebar: *wk.GtkWidget,
stack: *wk.GtkWidget,
filter_dd: *wk.GtkWidget,

main_path: []u8,
default_paths: [][]u8,
store: ConfigFileStore,
model: SettingsModel,
/// The defaults, with docs: the schema every row is listed from.
catalog: SettingsCatalog,
/// The live config's values; null until the first describe succeeds.
effective: ?SettingsCatalog = null,
sources: ?SettingsSources = null,
/// The user's file as last read.
file: ConfigFileText,
query: std.ArrayListUnmanaged(u8) = .empty,
rows: std.ArrayListUnmanaged(Row) = .empty,

/// Strings and slices the curated rows keep (labels, choices, subtitles).
build_arena: std.heap.ArenaAllocator,
curated: std.ArrayListUnmanaged(Curated) = .empty,
/// The section groups, with their title, for the seam.
groups: std.ArrayListUnmanaged(Group) = .empty,
/// The sidebar's pages in order, and each one's count label.
shown_pages: std.ArrayListUnmanaged(PageId) = .empty,
counts: std.ArrayListUnmanaged(*wk.GtkWidget) = .empty,
page: PageId = .appearance,
filter: Filter = .all,
/// Set while the window itself moves a control, so its signal is not a
/// user's gesture.
syncing: bool = false,
/// The pending redraw (idle) and slider write (timeout), 0 when none.
refresh_source: c_uint = 0,
slide_source: c_uint = 0,
slide_index: usize = 0,
slide_value: f64 = 0,
/// A list value the file refused: its key and the typed text, kept in the
/// "add a value" field across the redraw, as Mac's field keeps it.
draft_key: std.ArrayListUnmanaged(u8) = .empty,
draft_text: std.ArrayListUnmanaged(u8) = .empty,
/// The installed font families the Font row offers (T3765), in
/// `build_arena`; and the Font row's current items, in `font_arena`.
fonts: font_families.Families = .{ .mono = &.{}, .all = &.{} },
font_arena: std.heap.ArenaAllocator,
/// Advanced > Config file and the change toast (T3633).
config_file: ConfigFile = .{},
/// Sessions & Agent's agent status and Remote Machines (T3635).
live: SettingsLive = .{},
/// Appearance's theme picker and live preview (T3636).
theme: SettingsTheme = .{},

const Group = struct { page: PageId, title: ?[]const u8, widget: *wk.GtkWidget };

var open_window: ?*SettingsWindow = null;

/// A slider's value is written this long after the last movement - the drag
/// settling stands in for Mac's release.
const slide_settle_ms: c_uint = 250;

/// The open window, for the test seam.
pub fn current() ?*SettingsWindow {
    return open_window;
}

/// Open the Settings window, or bring the open one forward.
pub fn open(app: *Application) void {
    if (open_window) |w| {
        wk.gtk_window_present(w.window);
        log.info("settings: already open", .{});
        return;
    }
    const self = create(app) catch |err| {
        log.warn("settings: opening failed err={}", .{err});
        return;
    };
    open_window = self;
    self.rebuild();
    self.refreshCurated();
    self.refreshCounts();
    self.config_file.refresh(self);
    self.theme.refresh();
    wk.gtk_window_present(self.window);
    log.info("settings: opened keys={d} curated={d} file={s}", .{ self.catalog.entries.len, self.curated.items.len, self.main_path });
}

fn create(app: *Application) !*SettingsWindow {
    const gpa = app.allocator();
    var catalog = try SettingsCatalog.defaults(gpa);
    errdefer catalog.deinit();
    const main_path = try configpkg.preferredDefaultFilePath(gpa);
    errdefer gpa.free(main_path);
    const default_paths = try SettingsSources.defaultFilePaths(gpa);
    errdefer freePaths(gpa, default_paths);
    const backup_dir = try backupDir(gpa);
    defer gpa.free(backup_dir);
    var store = try ConfigFileStore.init(gpa, main_path, backup_dir, .{});
    errdefer store.deinit();
    var file = try ConfigFileText.init(gpa, "");
    errdefer file.deinit();

    const self = try gpa.create(SettingsWindow);
    self.* = .{
        .gpa = gpa,
        .app = app,
        .window = wk.gtk_window_new(),
        .search = wk.gtk_search_entry_new(),
        .list = wk.gtk_list_box_new(),
        .sidebar = wk.gtk_list_box_new(),
        .stack = wk.gtk_stack_new(),
        .filter_dd = undefined,
        .main_path = @constCast(main_path),
        .default_paths = default_paths,
        .store = store,
        .model = undefined,
        .catalog = catalog,
        .file = file,
        .build_arena = std.heap.ArenaAllocator.init(gpa),
        .font_arena = std.heap.ArenaAllocator.init(gpa),
    };
    self.model = SettingsModel.init(gpa, &self.store, .{ .ctx = self, .func = reloadHook });
    self.reloadData();
    try self.buildChrome();
    return self;
}

/// `$XDG_STATE_HOME/ghoztty/config-backups`, or in a debug build the folder
/// `GHOZTTY_SETTINGS_BACKUP_DIR` names (win32's seam, so a test run never
/// adds to or prunes the real backups).
fn backupDir(gpa: Allocator) ![]u8 {
    if (comptime build_config.is_debug) {
        if (std.posix.getenv("GHOZTTY_SETTINGS_BACKUP_DIR")) |v| {
            if (v.len > 0) return gpa.dupe(u8, v);
        }
    }
    return ConfigFileStore.defaultBackupDir(gpa);
}

fn freePaths(gpa: Allocator, paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

fn connect(self: *SettingsWindow, obj: *wk.GtkWidget, signal: [*:0]const u8, handler: *const anyopaque) void {
    _ = wk.g_signal_connect_data(obj, signal, handler, self, null, 0);
}

fn tag(widget: *wk.GtkWidget, name: [*:0]const u8, index: usize) void {
    wk.g_object_set_data(@ptrCast(widget), name, @ptrFromInt(index + 1));
}

fn tagOf(widget: *wk.GtkWidget, name: [*:0]const u8) ?usize {
    const t = @intFromPtr(wk.g_object_get_data(@ptrCast(widget), name));
    return if (t == 0) null else t - 1;
}

// ---------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------

/// Sections with their own UI that this window draws (the others are
/// their own cards; see the file comment).
fn customBuilt(c: pages.Custom) bool {
    return switch (c) {
        .shortcut_guide, .version, .config_file, .all_settings, .agent_status, .remote_machines, .preview, .theme => true,
    };
}

/// Whether the sidebar lists `p`: it has a row or a section drawn here.
pub fn pageShown(p: *const pages.Page) bool {
    for (p.sections) |s| {
        if (s.rows.len > 0) return true;
        if (s.custom) |c| if (customBuilt(c)) return true;
    }
    return false;
}

fn buildChrome(self: *SettingsWindow) !void {
    const w = self.window;
    wk.gtk_window_set_title(w, "Settings");
    wk.gtk_window_set_default_size(w, 920, 680);
    self.connect(w, "close-request", @ptrCast(&onCloseRequest));

    const outer = wk.gtk_box_new(0, 0);

    // The sidebar: search over every setting, then the pages.
    const side = wk.gtk_box_new(1, 6);
    wk.gtk_widget_set_size_request(side, 230, -1);
    wk.gtk_widget_set_margin_start(side, 8);
    wk.gtk_widget_set_margin_end(side, 8);
    wk.gtk_widget_set_margin_top(side, 10);
    wk.gtk_widget_set_margin_bottom(side, 10);
    wk.gtk_search_entry_set_placeholder_text(self.search, "Search settings");
    self.connect(self.search, "search-changed", @ptrCast(&onSearchChanged));
    wk.gtk_box_append(side, self.search);
    wk.gtk_list_box_set_selection_mode(self.sidebar, 1); // single
    wk.gtk_widget_add_css_class(self.sidebar, "navigation-sidebar");
    wk.gtk_widget_set_vexpand(self.sidebar, 1);
    wk.gtk_box_append(side, self.sidebar);
    wk.gtk_box_append(outer, side);
    wk.gtk_box_append(outer, wk.gtk_separator_new(1));

    wk.gtk_widget_set_hexpand(self.stack, 1);
    wk.gtk_widget_set_vexpand(self.stack, 1);
    // The change toast floats over the foot of the pages (Mac's
    // `.overlay(alignment: .bottom)`).
    const overlay = wk.gtk_overlay_new();
    wk.gtk_widget_set_hexpand(overlay, 1);
    wk.gtk_widget_set_vexpand(overlay, 1);
    wk.gtk_overlay_set_child(overlay, self.stack);
    wk.gtk_overlay_add_overlay(overlay, self.config_file.buildToast(self));
    wk.gtk_box_append(outer, overlay);

    for (pages.all) |p| {
        if (!pageShown(p)) continue;
        const content = if (p.id == .advanced) try self.buildAdvanced() else try self.buildPage(p);
        _ = wk.gtk_stack_add_named(self.stack, content, @tagName(p.id).ptr);
        try self.addSidebarRow(p);
    }
    self.connect(self.sidebar, "row-selected", @ptrCast(&onSidebarSelected));
    _ = self.setPage(self.shown_pages.items[0]);

    wk.gtk_window_set_child(w, outer);
}

fn addSidebarRow(self: *SettingsWindow, p: *const pages.Page) !void {
    const line = wk.gtk_box_new(0, 8);
    wk.gtk_widget_set_margin_start(line, 6);
    wk.gtk_widget_set_margin_end(line, 6);
    wk.gtk_widget_set_margin_top(line, 4);
    wk.gtk_widget_set_margin_bottom(line, 4);
    const title = wk.gtk_label_new((try self.build_arena.allocator().dupeZ(u8, p.title)).ptr);
    wk.gtk_label_set_xalign(title, 0.0);
    wk.gtk_widget_set_hexpand(title, 1);
    wk.gtk_box_append(line, title);
    const count = wk.gtk_label_new(null);
    wk.gtk_widget_add_css_class(count, "dim-label");
    wk.gtk_widget_add_css_class(count, "caption");
    wk.gtk_box_append(line, count);
    const row = wk.gtk_list_box_row_new();
    wk.gtk_list_box_row_set_child(row, line);
    wk.gtk_list_box_append(self.sidebar, row);
    try self.shown_pages.append(self.gpa, p.id);
    try self.counts.append(self.gpa, count);
}

fn buildPage(self: *SettingsWindow, p: *const pages.Page) !*wk.GtkWidget {
    const arena = self.build_arena.allocator();
    const page = wk.adw_preferences_page_new();
    for (p.sections) |*sec| {
        if (sec.custom) |c| if (!customBuilt(c)) continue;
        if (sec.custom == null and sec.rows.len == 0) continue;
        const group = wk.adw_preferences_group_new();
        // A group's title and description are markup in libadwaita, and
        // Mac's titles carry "&" (Copy & paste).
        if (sec.title) |t| wk.adw_preferences_group_set_title(group, (try markup(arena, t)).ptr);
        if (sec.footer) |f| wk.adw_preferences_group_set_description(group, (try markup(arena, f)).ptr);
        try self.groups.append(self.gpa, .{ .page = p.id, .title = sec.title, .widget = group });
        if (sec.custom) |c| try self.addCustom(group, c);
        for (sec.rows) |*row| self.addCurated(group, row) catch |err| {
            log.warn("settings: curated row {s} failed err={}", .{ row.key, err });
        };
        wk.adw_preferences_page_add(page, group);
    }
    return page;
}

fn markup(arena: Allocator, text: []const u8) ![:0]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (text) |ch| switch (ch) {
        '&' => try out.appendSlice(arena, "&amp;"),
        '<' => try out.appendSlice(arena, "&lt;"),
        '>' => try out.appendSlice(arena, "&gt;"),
        else => try out.append(arena, ch),
    };
    return out.toOwnedSliceSentinel(arena, 0);
}

/// A row titled `title` with markup off (Mac's labels are plain text).
fn plainTitle(row: *wk.GtkWidget, title: [:0]const u8) void {
    wk.adw_preferences_row_set_use_markup(row, 0);
    wk.adw_preferences_row_set_title(row, title.ptr);
}

fn addCustom(self: *SettingsWindow, group: *wk.GtkWidget, c: pages.Custom) !void {
    const arena = self.build_arena.allocator();
    switch (c) {
        // Mac's Keyboard page shows the shortcut guide first; the guide is
        // its own window here (T3570), so the page opens it.
        .shortcut_guide => {
            const row = wk.adw_action_row_new();
            plainTitle(row, "Keyboard shortcuts");
            wk.adw_action_row_set_subtitle(row, "Every shortcut, searchable, with the action it runs. Rebind one with keybind under Advanced.");
            const button = wk.gtk_button_new_with_label("Open Shortcut Guide\u{2026}");
            wk.gtk_widget_set_valign(button, 3); // center
            self.connect(button, "clicked", @ptrCast(&onShortcutGuideClicked));
            wk.adw_action_row_add_suffix(row, button);
            wk.adw_preferences_group_add(group, row);
        },
        .version => {
            const row = wk.adw_action_row_new();
            plainTitle(row, "Version");
            wk.adw_action_row_set_subtitle(row, (try arena.dupeZ(u8, build_config.version_string)).ptr);
            wk.adw_preferences_group_add(group, row);
        },
        // Advanced draws its own (buildAdvanced, SettingsConfigFile.zig).
        // T3635: SettingsLive draws both and re-reads them when shown.
        .agent_status => self.live.buildAgent(group),
        .remote_machines => self.live.buildRemote(group),
        // T3636: SettingsTheme draws both and refreshes them after a write.
        .preview => self.theme.buildPreview(group),
        .theme => self.theme.buildTheme(group),
        .config_file, .all_settings => {},
    }
}

/// Advanced: the config file (T3633), then All Settings - its filter and
/// the generated list. The page scrolls as one, as Mac's form does.
fn buildAdvanced(self: *SettingsWindow) !*wk.GtkWidget {
    const column = wk.gtk_box_new(1, 8);
    wk.gtk_widget_set_margin_start(column, 16);
    wk.gtk_widget_set_margin_end(column, 16);
    wk.gtk_widget_set_margin_top(column, 12);
    // Room under the last row for the toast.
    wk.gtk_widget_set_margin_bottom(column, 72);

    const file_group = self.config_file.build(self);
    try self.groups.append(self.gpa, .{ .page = .advanced, .title = "Config file", .widget = file_group });
    wk.gtk_box_append(column, file_group);
    wk.gtk_box_append(column, self.config_file.buildBackups());

    const head = wk.gtk_box_new(0, 8);
    const heading = wk.gtk_label_new("All Settings");
    wk.gtk_widget_add_css_class(heading, "heading");
    wk.gtk_label_set_xalign(heading, 0.0);
    wk.gtk_widget_set_hexpand(heading, 1);
    wk.gtk_box_append(head, heading);
    const filters = [_:null]?[*:0]const u8{ "All", "Changed", "Not on other pages" };
    self.filter_dd = wk.gtk_drop_down_new_from_strings(&filters);
    self.connect(self.filter_dd, "notify::selected", @ptrCast(&onFilterSelected));
    wk.gtk_box_append(head, self.filter_dd);
    wk.gtk_box_append(column, head);

    const footer = wk.gtk_label_new("Every option, straight from the config schema.");
    wk.gtk_widget_add_css_class(footer, "dim-label");
    wk.gtk_widget_add_css_class(footer, "caption");
    wk.gtk_label_set_xalign(footer, 0.0);
    wk.gtk_box_append(column, footer);

    wk.gtk_list_box_set_selection_mode(self.list, 0); // none
    wk.gtk_widget_add_css_class(self.list, "boxed-list");
    wk.gtk_box_append(column, self.list);
    const scroller = wk.gtk_scrolled_window_new();
    wk.gtk_scrolled_window_set_policy(scroller, 2, 0); // never, automatic
    wk.gtk_widget_set_vexpand(scroller, 1);
    wk.gtk_scrolled_window_set_child(scroller, column);
    return scroller;
}

/// One curated row: its control, dot and reset button, tagged with its
/// index so a signal finds it.
fn addCurated(self: *SettingsWindow, group: *wk.GtkWidget, def: *const pages.Row) !void {
    const arena = self.build_arena.allocator();
    const entry_def = self.catalog.get(def.key) orelse {
        log.warn("settings: curated key {s} is not in the schema", .{def.key});
        return;
    };
    const index = self.curated.items.len;
    var c: Curated = .{
        .def = def,
        .key = entry_def.key,
        .kind = undefined,
        .row = undefined,
        .dot = wk.gtk_label_new("\u{25CF}"),
        .reset = wk.gtk_button_new_from_icon_name("edit-undo-symbolic"),
    };
    c.base = if (def.hint) |h|
        try arena.dupeZ(u8, h)
    else if (entry_def.doc) |doc|
        try arena.dupeZ(u8, try SettingsCatalog.summary(arena, doc))
    else
        "";
    const label = try arena.dupeZ(u8, def.label);

    switch (def.control) {
        .toggle => {
            c.kind = .toggle;
            c.row = wk.adw_switch_row_new();
            self.connect(c.row, "notify::active", @ptrCast(&onSwitchActive));
        },
        .picker, .segmented, .cards => {
            c.kind = .choice;
            c.row = wk.adw_combo_row_new();
            c.choices = try pages.choices(arena, def, entry_def.options);
            try setComboItems(arena, c.row, c.choices, false);
        },
        .shell => |sh| {
            c.kind = .shell;
            c.row = wk.adw_combo_row_new();
            c.choices = try self.shellChoices(arena, sh.scripted);
            try setComboItems(arena, c.row, c.choices, true);
            // Other...: a typed command, checked before it is written.
            const other = wk.adw_action_row_new();
            plainTitle(other, try std.fmt.allocPrintSentinel(arena, "{s}: other command", .{def.label}, 0));
            const field = wk.gtk_entry_new();
            wk.gtk_editable_set_width_chars(field, 24);
            wk.gtk_widget_set_valign(field, 3);
            wk.gtk_entry_set_placeholder_text(field, "/usr/bin/zsh -l");
            wk.adw_action_row_add_suffix(other, field);
            tag(field, "settings-curated", index);
            self.connect(field, "activate", @ptrCast(&onShellOtherActivate));
            c.entry = field;
            c.other_row = other;
        },
        .stepper => |s| {
            c.kind = .spin;
            c.row = wk.adw_spin_row_new_with_range(s.min, s.max, s.step);
            wk.adw_spin_row_set_digits(c.row, if (s.step == @round(s.step)) 0 else 1);
            self.connect(c.row, "notify::value", @ptrCast(&onSpinValue));
        },
        .megabytes => |m| {
            c.kind = .spin;
            c.row = wk.adw_spin_row_new_with_range(0, m.max, 1);
            wk.adw_spin_row_set_digits(c.row, 1);
            self.connect(c.row, "notify::value", @ptrCast(&onSpinValue));
        },
        .slider => |s| {
            c.kind = .slider;
            c.row = wk.adw_action_row_new();
            const scale = wk.gtk_scale_new_with_range(0, s.min, s.max, s.step);
            wk.gtk_widget_set_size_request(scale, 220, -1);
            wk.gtk_widget_set_valign(scale, 3);
            wk.gtk_scale_set_draw_value(scale, 1);
            tag(scale, "settings-curated", index);
            wk.gtk_scale_set_format_value_func(scale, &formatScale, self, null);
            self.connect(scale, "value-changed", @ptrCast(&onScaleChanged));
            wk.adw_action_row_add_suffix(c.row, scale);
            c.scale = scale;
        },
        .flags => {
            c.kind = .flags;
            c.row = wk.adw_expander_row_new();
            const opts = entry_def.options orelse &.{};
            c.flag_names = opts;
            c.flag_rows = try arena.alloc(*wk.GtkWidget, opts.len);
            for (opts, 0..) |o, i| {
                const sw = wk.adw_switch_row_new();
                plainTitle(sw, try arena.dupeZ(u8, o));
                tag(sw, "settings-curated", index);
                tag(sw, "settings-flag", i);
                self.connect(sw, "notify::active", @ptrCast(&onFlagActive));
                wk.adw_expander_row_add_row(c.row, sw);
                c.flag_rows[i] = sw;
            }
        },
        // Mac's `FontControl` (T3765): a picker over the installed
        // monospaced families - Default removes the key, a pick replaces the
        // first value and keeps the fallbacks - with "+N fallback" beside it.
        // The fallbacks are chips on a row under it (T3632's editor), shown
        // once the file names a font for them to follow.
        .font => {
            c.kind = .font;
            c.row = wk.adw_combo_row_new();
            self.fonts = font_families.load(arena) catch |err| blk: {
                log.warn("settings: listing fonts failed err={}", .{err});
                break :blk .{ .mono = &.{}, .all = &.{} };
            };
            log.info("settings: font picker lists {d} monospaced families of {d}", .{ self.fonts.mono.len, self.fonts.all.len });
            const fb = wk.gtk_label_new("");
            wk.gtk_widget_add_css_class(fb, "caption");
            wk.gtk_widget_add_css_class(fb, "dim-label");
            wk.gtk_widget_set_valign(fb, 3);
            wk.adw_action_row_add_suffix(c.row, fb);
            c.fallback_label = fb;
            const other = wk.adw_action_row_new();
            plainTitle(other, "Fallback fonts");
            wk.adw_action_row_set_subtitle(other, "Used in order for characters the font does not have.");
            const ed = try self.buildListEditor(arena, "add a fallback", "settings-curated", index);
            wk.adw_action_row_add_suffix(other, ed.box);
            c.chips = ed.chips;
            c.entry = ed.entry;
            c.other_row = other;
            self.connect(ed.entry, "activate", @ptrCast(&onCuratedListActivate));
        },
        // A repeatable key (Font features): Mac's `ListControl` - the file's
        // values as removable chips, then a field that adds one (T3632).
        .list => |l| if (entry_def.repeatable) {
            c.kind = .list;
            c.row = wk.adw_action_row_new();
            const ed = try self.buildListEditor(arena, l.placeholder, "settings-curated", index);
            wk.adw_action_row_add_suffix(c.row, ed.box);
            c.chips = ed.chips;
            c.entry = ed.entry;
            self.connect(ed.entry, "activate", @ptrCast(&onCuratedListActivate));
        } else {
            c.kind = .text;
            c.row = wk.adw_action_row_new();
            const field = wk.gtk_entry_new();
            wk.gtk_editable_set_width_chars(field, 22);
            wk.gtk_widget_set_valign(field, 3);
            tag(field, "settings-curated", index);
            self.connect(field, "activate", @ptrCast(&onCuratedEntryActivate));
            wk.adw_action_row_add_suffix(c.row, field);
            c.entry = field;
        },
        // A color, folder or free text: edited as its value text, the All
        // Settings way.
        .text, .color, .folder => {
            c.kind = .text;
            c.row = wk.adw_action_row_new();
            const field = wk.gtk_entry_new();
            wk.gtk_editable_set_width_chars(field, 22);
            wk.gtk_widget_set_valign(field, 3);
            switch (def.control) {
                .text => |t| wk.gtk_entry_set_placeholder_text(field, (try arena.dupeZ(u8, t.placeholder)).ptr),
                .color => |col| wk.gtk_entry_set_placeholder_text(field, (try arena.dupeZ(u8, col.none_label)).ptr),
                else => {},
            }
            tag(field, "settings-curated", index);
            self.connect(field, "activate", @ptrCast(&onCuratedEntryActivate));
            wk.adw_action_row_add_suffix(c.row, field);
            c.entry = field;
        },
    }
    if (c.kind == .choice or c.kind == .shell or c.kind == .font) self.connect(c.row, "notify::selected", @ptrCast(&onComboSelected));
    plainTitle(c.row, label);
    tag(c.row, "settings-curated", index);

    wk.gtk_widget_add_css_class(c.dot, "accent");
    wk.gtk_widget_set_tooltip_text(c.dot, "Changed from the default");
    wk.gtk_widget_set_tooltip_text(c.reset, "Reset to default");
    wk.gtk_widget_add_css_class(c.reset, "flat");
    wk.gtk_widget_set_valign(c.reset, 3);
    tag(c.reset, "settings-curated", index);
    self.connect(c.reset, "clicked", @ptrCast(&onCuratedReset));
    if (c.kind == .flags) {
        wk.adw_expander_row_add_prefix(c.row, c.dot);
        wk.adw_expander_row_add_suffix(c.row, c.reset);
    } else {
        wk.adw_action_row_add_prefix(c.row, c.dot);
        wk.adw_action_row_add_suffix(c.row, c.reset);
    }

    try self.curated.append(self.gpa, c);
    wk.adw_preferences_group_add(group, c.row);
    if (c.other_row) |o| wk.adw_preferences_group_add(group, o);
}

fn setComboItems(arena: Allocator, row: *wk.GtkWidget, choices: []const pages.Option, other: bool) !void {
    const strs = try arena.alloc(?[*:0]const u8, choices.len + @intFromBool(other) + 1);
    for (choices, 0..) |o, i| strs[i] = (try arena.dupeZ(u8, o.label)).ptr;
    if (other) strs[choices.len] = controls.other_shell_label;
    strs[strs.len - 1] = null;
    const model = wk.gtk_string_list_new(strs.ptr);
    wk.adw_combo_row_set_model(row, model);
    wk.g_object_unref(model);
}

const ListEditor = struct { box: *wk.GtkWidget, chips: *wk.GtkWidget, entry: *wk.GtkWidget };

/// Mac's `ListControl`: a horizontally scrolling run of chips, then an
/// "add a value" field. `tag_name`/`index` say whose row it is, so the
/// chips' remove buttons and the field's Return find it.
fn buildListEditor(self: *SettingsWindow, arena: Allocator, placeholder: []const u8, tag_name: [*:0]const u8, index: usize) !ListEditor {
    _ = self;
    const box = wk.gtk_box_new(0, 6);
    wk.gtk_widget_set_valign(box, 3);
    const chips = wk.gtk_box_new(0, 4);
    const scroller = wk.gtk_scrolled_window_new();
    wk.gtk_scrolled_window_set_policy(scroller, 1, 2); // automatic, never
    wk.gtk_scrolled_window_set_propagate_natural_width(scroller, 1);
    wk.gtk_scrolled_window_set_max_content_width(scroller, 360);
    wk.gtk_scrolled_window_set_child(scroller, chips);
    wk.gtk_widget_set_valign(scroller, 3);
    wk.gtk_box_append(box, scroller);
    const entry = wk.gtk_entry_new();
    wk.gtk_editable_set_width_chars(entry, 12);
    wk.gtk_widget_set_valign(entry, 3);
    wk.gtk_entry_set_placeholder_text(entry, (try arena.dupeZ(u8, placeholder)).ptr);
    tag(entry, tag_name, index);
    wk.gtk_box_append(box, entry);
    return .{ .box = box, .chips = chips, .entry = entry };
}

/// Make `chips` show `vals`: one chip each, its x button removing that
/// value. `editable` false (a later file owns the key) leaves them inert.
fn fillChips(self: *SettingsWindow, chips: *wk.GtkWidget, vals: []const []const u8, tag_name: [*:0]const u8, index: usize, editable: bool) !void {
    while (wk.gtk_widget_get_first_child(chips)) |ch| wk.gtk_box_remove(chips, ch);
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (vals, 0..) |v, i| {
        const chip = wk.gtk_box_new(0, 2);
        wk.gtk_widget_add_css_class(chip, "card");
        wk.gtk_widget_set_valign(chip, 3);
        const label = wk.gtk_label_new((try arena.dupeZ(u8, v)).ptr);
        wk.gtk_widget_add_css_class(label, "monospace");
        wk.gtk_widget_add_css_class(label, "caption");
        wk.gtk_label_set_ellipsize(label, 3); // end
        wk.gtk_label_set_max_width_chars(label, 40);
        wk.gtk_widget_set_margin_start(label, 6);
        wk.gtk_box_append(chip, label);
        const x = wk.gtk_button_new_from_icon_name("window-close-symbolic");
        wk.gtk_widget_add_css_class(x, "flat");
        wk.gtk_widget_add_css_class(x, "circular");
        wk.gtk_widget_set_tooltip_text(x, (try std.fmt.allocPrintSentinel(arena, "Remove {s}", .{v}, 0)).ptr);
        wk.gtk_widget_set_sensitive(x, @intFromBool(editable));
        tag(x, tag_name, index);
        tag(x, "settings-chip", i);
        self.connect(x, "clicked", @ptrCast(if (std.mem.eql(u8, std.mem.span(tag_name), "settings-curated"))
            &onCuratedChipRemove
        else
            &onRowChipRemove));
        wk.gtk_box_append(chip, x);
        wk.gtk_box_append(chips, chip);
    }
}

/// The values a chip box shows, read back from its labels. Caller frees the
/// outer slice; the strings are GTK's.
pub fn chipValues(alloc: Allocator, chips: *wk.GtkWidget) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var chip = wk.gtk_widget_get_first_child(chips);
    while (chip) |ch| : (chip = wk.gtk_widget_get_next_sibling(ch)) {
        const label = wk.gtk_widget_get_first_child(ch) orelse continue;
        try out.append(alloc, std.mem.span(wk.gtk_label_get_text(label)));
    }
    return out.toOwnedSlice(alloc);
}

/// Mac's "In effect:" line: the first four effective values, then a count.
fn inEffectText(arena: Allocator, vals: []const []const u8) ![:0]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "In effect: ");
    for (vals[0..@min(vals.len, 4)], 0..) |v, i| {
        if (i > 0) try out.appendSlice(arena, "  \u{00B7}  ");
        try out.appendSlice(arena, v);
    }
    if (vals.len > 4) try out.print(arena, "  \u{00B7}  \u{2026} ({d})", .{vals.len});
    return out.toOwnedSliceSentinel(arena, 0);
}

/// A shell row's items: the default line (unset), then each common shell
/// found on PATH, by the absolute path the row writes.
fn shellChoices(self: *SettingsWindow, arena: Allocator, scripted: bool) ![]const pages.Option {
    _ = self;
    var out: std.ArrayListUnmanaged(pages.Option) = .empty;
    try out.append(arena, .{ .value = "", .label = controls.shellDefaultLabelPosix(scripted) });
    // One catalog with the command palette's "… with Shell" list (T3737).
    for (try installedShells(arena)) |sh| {
        try out.append(arena, .{ .value = sh.path, .label = try std.fmt.allocPrint(arena, "{s} ({s})", .{ sh.name, sh.path }) });
    }
    return out.toOwnedSlice(arena);
}

/// The installed shells Settings > Shell and the command palette's "… with
/// Shell" rows offer (T3737): `shell_pick.catalog` over this process's PATH.
pub fn installedShells(arena: Allocator) Allocator.Error![]const shell_pick.Shell {
    return shell_pick.catalog(arena, std.posix.getenv("PATH") orelse "", {}, isExecutable);
}

/// Mac's `isExecutableFile`: a regular file this user may execute.
fn isExecutable(_: void, path: []const u8) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    if (st.kind != .file) return false;
    std.posix.access(path, std.posix.X_OK) catch return false;
    return true;
}

// ---------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------

/// Read the file, the other config files and the live config again.
pub fn reloadData(self: *SettingsWindow) void {
    if (self.store.read(self.gpa)) |t| {
        self.file.deinit();
        self.file = t;
    } else |err| log.warn("settings: reading {s} failed err={}", .{ self.main_path, err });

    const paths: []const []const u8 = @ptrCast(self.default_paths);
    if (SettingsSources.load(self.gpa, self.main_path, paths)) |s| {
        self.model.sources = null;
        if (self.sources) |*old| old.deinit();
        self.sources = s;
        self.model.sources = &self.sources.?;
    } else |_| {}

    const cfg = self.app.getConfig();
    defer cfg.unref();
    if (SettingsCatalog.describe(self.gpa, cfg.get(), false)) |e| {
        if (self.effective) |*old| old.deinit();
        self.effective = e;
    } else |err| log.warn("settings: describing the live config failed err={}", .{err});

    self.config_file.reload(self);
}

pub fn reader(self: *const SettingsWindow) ?SettingsSources.Reader {
    const sources = if (self.sources) |*s| s else return null;
    return .{
        .catalog = &self.catalog,
        .effective = if (self.effective) |*e| e else &self.catalog,
        .sources = sources,
        .file = &self.file,
    };
}

/// The keys All Settings lists for the current search and filter. Caller
/// frees.
pub fn visibleKeys(self: *const SettingsWindow, alloc: Allocator) Allocator.Error![]const []const u8 {
    const r = self.reader() orelse return alloc.alloc([]const u8, 0);
    return r.allSettings(alloc, self.filter, self.query.items);
}

/// The sidebar's count for a page (Mac `changedCount`): the page's keys the
/// user's file sets, or for Advanced every file key no curated page shows.
pub fn changedOn(self: *const SettingsWindow, id: PageId) usize {
    const r = self.reader() orelse return 0;
    var n: usize = 0;
    if (id == .advanced) {
        for (self.catalog.entries) |*e| {
            if (!pages.isCurated(e.key) and r.isSetInFile(e.key)) n += 1;
        }
        return n;
    }
    for (pages.page(id).sections) |sec| for (sec.rows) |row| {
        if (r.isSetInFile(row.key)) n += 1;
    };
    return n;
}

/// Whether a curated row's control is live: not dimmed by its condition.
pub fn rowEnabled(self: *const SettingsWindow, def: *const pages.Row) bool {
    const cond = def.enabled_when orelse return true;
    const r = self.reader() orelse return true;
    return cond.holds(r.value(cond.key));
}

pub fn curatedFor(self: *SettingsWindow, key: []const u8) ?*Curated {
    for (self.curated.items) |*c| if (std.mem.eql(u8, c.key, key)) return c;
    return null;
}

fn curatedIndex(self: *const SettingsWindow, c: *const Curated) usize {
    return (@intFromPtr(c) - @intFromPtr(self.curated.items.ptr)) / @sizeOf(Curated);
}

fn curatedOf(self: *SettingsWindow, widget: *wk.GtkWidget) ?*Curated {
    const i = tagOf(widget, "settings-curated") orelse return null;
    if (i >= self.curated.items.len) return null;
    return &self.curated.items[i];
}

/// What a curated control should show for its key's value, as text - the
/// model's answer, which the seam holds the widget's own (`display`) to.
pub fn expectedDisplay(self: *const SettingsWindow, buf: []u8, c: *const Curated) []const u8 {
    const r = self.reader() orelse return "";
    const cur = r.value(c.key);
    return switch (c.def.control) {
        .slider => |s| controls.sliderLabel(buf, controls.snap(controls.parseOr(cur, s.min), s.min, s.max, s.step), s.percent, s.inverted),
        .stepper => |s| controls.formatNumber(buf, std.math.clamp(controls.parseOr(cur, s.min), s.min, s.max)),
        .megabytes => controls.bytesAsMegabytes(buf, cur),
        .shell => |sh| blk: {
            if (!r.isSetInFile(c.key) or cur.len == 0) break :blk controls.shellDefaultLabelPosix(sh.scripted);
            for (c.choices) |o| if (std.mem.eql(u8, o.value, cur)) break :blk o.label;
            break :blk cur;
        },
        .flags => cur,
        .font => blk: {
            const vals = r.values(self.gpa, c.key) catch break :blk "";
            defer self.gpa.free(vals);
            const primary = if (vals.len > 0) vals[0] else "";
            if (primary.len == 0) break :blk controls.font_default_label;
            if (controls.hasFamily(self.fonts.mono, primary)) {
                for (self.fonts.mono) |f| if (std.ascii.eqlIgnoreCase(f, primary)) break :blk f;
            }
            if (controls.hasFamily(self.fonts.all, primary)) break :blk std.fmt.bufPrint(buf, "{s}", .{primary}) catch "";
            break :blk std.fmt.bufPrint(buf, "{s} (not installed)", .{primary}) catch "";
        },
        .text, .color, .folder, .list => if (c.kind == .list) self.fileListShown(buf, c.key) else self.textShown(buf, c),
        else => c.def.labelFor(cur),
    };
}

/// A text row's value text: a list joined by ", ".
fn textShown(self: *const SettingsWindow, buf: []u8, c: *const Curated) []const u8 {
    const r = self.reader() orelse return "";
    const entry_def = self.catalog.get(c.key) orelse return "";
    if (!entry_def.repeatable) return r.value(c.key);
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const vals = r.values(self.gpa, c.key) catch return "";
    defer self.gpa.free(vals);
    return std.mem.join(fba.allocator(), ", ", vals) catch "";
}

/// The user's file's values for a list key, joined by ", " - what its chips
/// should read (Mac's `ListControl` lists `model.file.values`).
fn fileListShown(self: *const SettingsWindow, buf: []u8, key: []const u8) []const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const vals = self.file.values(self.gpa, key) catch return "";
    defer self.gpa.free(vals);
    return std.mem.join(fba.allocator(), ", ", vals) catch "";
}

/// What a chip box shows, read back from its labels and joined by ", ".
fn chipsShown(self: *const SettingsWindow, buf: []u8, chips: *wk.GtkWidget) []const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const vals = chipValues(self.gpa, chips) catch return "";
    defer self.gpa.free(vals);
    return std.mem.join(fba.allocator(), ", ", vals) catch "";
}

/// What a curated control shows right now, read back from the widget.
pub fn widgetDisplay(self: *const SettingsWindow, buf: []u8, c: *const Curated) []const u8 {
    switch (c.kind) {
        .list => return self.chipsShown(buf, c.chips.?),
        .font => {
            const sel = wk.adw_combo_row_get_selected(c.row);
            return if (sel < c.choices.len) c.choices[sel].label else "";
        },
        .toggle => return if (wk.adw_switch_row_get_active(c.row) != 0) "On" else "Off",
        .choice, .shell => {
            const sel = wk.adw_combo_row_get_selected(c.row);
            if (sel < c.choices.len) return c.choices[sel].label;
            if (c.kind == .shell and sel == c.choices.len) return std.mem.span(wk.gtk_editable_get_text(c.entry.?));
            return "";
        },
        .spin => return controls.formatNumber(buf, wk.adw_spin_row_get_value(c.row)),
        .slider => {
            const s = c.def.control.slider;
            return controls.sliderLabel(buf, wk.gtk_range_get_value(c.scale.?), s.percent, s.inverted);
        },
        .flags => {
            var n: usize = 0;
            for (c.flag_names, c.flag_rows, 0..) |name, sw, i| {
                const part = std.fmt.bufPrint(buf[n..], "{s}{s}{s}", .{
                    if (i > 0) "," else "",
                    if (wk.adw_switch_row_get_active(sw) != 0) "" else "no-",
                    name,
                }) catch break;
                n += part.len;
            }
            return buf[0..n];
        },
        .text => return std.mem.span(wk.gtk_editable_get_text(c.entry.?)),
    }
}

/// Whether the row's widget can be used (not dimmed).
pub fn widgetSensitive(c: *const Curated) bool {
    return wk.gtk_widget_get_sensitive(c.row) != 0 and
        (c.entry == null or c.kind != .text or wk.gtk_widget_get_sensitive(c.entry.?) != 0);
}

/// The first label text under `widget`, depth first (a group's title as
/// drawn - the seam's proof the markup reads as Mac's words).
pub fn firstLabelText(widget: *wk.GtkWidget) ?[]const u8 {
    if (wk.g_type_check_instance_is_a(@ptrCast(widget), wk.gtk_label_get_type()) != 0) {
        return std.mem.span(wk.gtk_label_get_text(widget));
    }
    var child = wk.gtk_widget_get_first_child(widget);
    while (child) |ch| : (child = wk.gtk_widget_get_next_sibling(ch)) {
        if (firstLabelText(ch)) |t| if (t.len > 0) return t;
    }
    return null;
}

// ---------------------------------------------------------------------
// Refreshing
// ---------------------------------------------------------------------

/// Move every curated control to its key's value, and its dot, reset,
/// dimming and subtitle to the key's state - in place.
fn refreshCurated(self: *SettingsWindow) void {
    const r = self.reader() orelse return;
    self.syncing = true;
    defer self.syncing = false;
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (self.curated.items) |*c| self.refreshOne(r, arena, c) catch |err| {
        log.warn("settings: refreshing {s} failed err={}", .{ c.key, err });
    };
}

fn refreshOne(self: *SettingsWindow, r: SettingsSources.Reader, arena: Allocator, c: *Curated) !void {
    const cur = r.value(c.key);
    // Mac's orange line under the Font picker, when its font is missing.
    var warning: ?[]const u8 = null;
    switch (c.kind) {
        .font => warning = try self.refreshFont(r, arena, c),
        .toggle => wk.adw_switch_row_set_active(c.row, @intFromBool(std.mem.eql(u8, cur, "true"))),
        .choice => {
            var sel: c_uint = wk.invalid_list_position;
            for (c.choices, 0..) |o, i| if (std.mem.eql(u8, o.value, cur)) {
                sel = @intCast(i);
            };
            // An optional key the file does not set reads as its "unset"
            // item (App decides, System default).
            if (sel == wk.invalid_list_position and !r.isSetInFile(c.key)) {
                for (c.choices, 0..) |o, i| if (o.value.len == 0) {
                    sel = @intCast(i);
                };
            }
            wk.adw_combo_row_set_selected(c.row, sel);
        },
        .shell => {
            var sel: c_uint = 0;
            const other: c_uint = @intCast(c.choices.len);
            if (r.isSetInFile(c.key) and cur.len > 0) {
                sel = other;
                for (c.choices, 0..) |o, i| if (o.value.len > 0 and std.mem.eql(u8, o.value, cur)) {
                    sel = @intCast(i);
                };
            }
            // Keep Other... up while the user is on it with a refused command.
            const on_other = wk.adw_combo_row_get_selected(c.row) == other and self.model.problem(c.key) != null;
            if (!on_other) wk.adw_combo_row_set_selected(c.row, sel);
            if (sel == other and !on_other) wk.gtk_editable_set_text(c.entry.?, (try arena.dupeZ(u8, cur)).ptr);
            wk.gtk_widget_set_visible(c.other_row.?, @intFromBool(wk.adw_combo_row_get_selected(c.row) == other));
        },
        .spin => switch (c.def.control) {
            .megabytes => wk.adw_spin_row_set_value(c.row, controls.parseOr(cur, 0) / controls.megabyte),
            .stepper => |s| wk.adw_spin_row_set_value(c.row, controls.parseOr(cur, s.min)),
            else => {},
        },
        .slider => {
            // Not while a drag is still settling, or it would jump back.
            if (!(self.slide_source != 0 and &self.curated.items[self.slide_index] == c)) {
                wk.gtk_range_set_value(c.scale.?, controls.parseOr(cur, c.def.control.slider.min));
            }
        },
        .flags => for (c.flag_names, c.flag_rows) |name, sw| {
            wk.adw_switch_row_set_active(sw, @intFromBool(controls.flagState(cur, name) orelse false));
        },
        .text => {
            const field = c.entry.?;
            var buf: [4096]u8 = undefined;
            if (wk.gtk_widget_has_focus(field) == 0 or self.model.problem(c.key) == null) {
                wk.gtk_editable_set_text(field, (try arena.dupeZ(u8, self.textShown(&buf, c))).ptr);
            }
        },
        .list => {
            const vals = try self.file.values(arena, c.key);
            const editable = if (self.sources) |*s| s.overriding(c.key) == null else true;
            try self.fillChips(c.chips.?, vals, "settings-curated", self.curatedIndex(c), editable);
            wk.gtk_widget_set_sensitive(c.entry.?, @intFromBool(editable));
            // The field is left alone: the add empties it when it writes,
            // and a refused value stays there to be fixed.
        },
    }

    const entry_def = self.catalog.get(c.key);
    const repeatable = if (entry_def) |e| e.repeatable else false;
    const overriding = if (self.sources) |*s| s.overriding(c.key) else null;
    const enabled = self.rowEnabled(c.def);
    wk.gtk_widget_set_visible(c.dot, @intFromBool(r.isModified(c.key)));
    wk.gtk_widget_set_visible(c.reset, @intFromBool(r.isSetInFile(c.key) and overriding == null));
    wk.gtk_widget_set_sensitive(c.row, @intFromBool(overriding == null and enabled));
    if (c.kind == .text) wk.gtk_widget_set_sensitive(c.entry.?, @intFromBool(!repeatable));

    // The subtitle says the most pressing thing: the refusal, the file that
    // owns the key, why it is dimmed, else what the setting does.
    const subtitle: []const u8 = if (self.model.problem(c.key)) |p|
        p
    else if (overriding) |src|
        try SettingsSources.overrideMessage(arena, src, null)
    else if (warning) |w|
        w
    else if (!enabled)
        c.def.enabled_when.?.reason
    else
        c.base;
    const z = try arena.dupeZ(u8, subtitle);
    if (c.kind == .flags) wk.adw_expander_row_set_subtitle(c.row, z.ptr) else wk.adw_action_row_set_subtitle(c.row, z.ptr);
    c.subtitle = if (c.kind == .flags)
        std.mem.span(wk.adw_expander_row_get_subtitle(c.row) orelse "")
    else
        std.mem.span(wk.adw_action_row_get_subtitle(c.row) orelse "");
}

/// The Font row (Mac `FontControl`): its items (rebuilt only when the
/// not-installed primary they end with changes), the selection, "+N
/// fallback" with the fallbacks as its tooltip, and the fallback chips - the
/// user's file's values after the first. Returns the not-installed warning.
fn refreshFont(self: *SettingsWindow, r: SettingsSources.Reader, arena: Allocator, c: *Curated) !?[]const u8 {
    const eff = try r.values(arena, c.key);
    const primary: []const u8 = if (eff.len > 0) eff[0] else "";
    const extra: ?[]const u8 = if (primary.len > 0 and !controls.hasFamily(self.fonts.mono, primary)) primary else null;
    const same = if (c.font_extra) |old| (extra != null and std.mem.eql(u8, old, extra.?)) else extra == null;
    if (!same or c.choices.len == 0) {
        _ = self.font_arena.reset(.retain_capacity);
        const fa = self.font_arena.allocator();
        const fc = try controls.fontChoices(fa, self.fonts.mono, self.fonts.all, if (extra) |e| try fa.dupe(u8, e) else "");
        const opts = try fa.alloc(pages.Option, fc.len);
        for (fc, opts) |f, *o| o.* = .{ .value = f.value, .label = f.label };
        c.choices = opts;
        c.font_extra = if (extra != null) fc[fc.len - 1].value else null;
        try setComboItems(arena, c.row, c.choices, false);
    }
    const sel = controls.fontChoiceIndex(c.choices, primary) orelse 0;
    wk.adw_combo_row_set_selected(c.row, @intCast(sel));

    var buf: [64]u8 = undefined;
    if (controls.fontFallbackLabel(&buf, eff.len)) |t| {
        wk.gtk_label_set_text(c.fallback_label.?, (try arena.dupeZ(u8, t)).ptr);
        wk.gtk_widget_set_tooltip_text(c.fallback_label.?, (try arena.dupeZ(u8, try std.mem.join(arena, ", ", eff[1..]))).ptr);
        wk.gtk_widget_set_visible(c.fallback_label.?, 1);
    } else {
        wk.gtk_label_set_text(c.fallback_label.?, "");
        wk.gtk_widget_set_visible(c.fallback_label.?, 0);
    }

    const file_vals = try self.file.values(arena, c.key);
    const editable = if (self.sources) |*s| s.overriding(c.key) == null else true;
    try self.fillChips(c.chips.?, if (file_vals.len > 1) file_vals[1..] else &.{}, "settings-curated", self.curatedIndex(c), editable);
    wk.gtk_widget_set_sensitive(c.entry.?, @intFromBool(editable));
    // A fallback follows a font the file names; with none, there is
    // nothing for it to fall back from (and an add would become the font).
    wk.gtk_widget_set_visible(c.other_row.?, @intFromBool(file_vals.len > 0));

    if (primary.len == 0 or controls.hasFamily(self.fonts.all, primary)) return null;
    var wbuf: [512]u8 = undefined;
    return try arena.dupe(u8, controls.fontNotInstalledText(&wbuf, primary));
}

fn refreshCounts(self: *SettingsWindow) void {
    var buf: [16]u8 = undefined;
    for (self.shown_pages.items, self.counts.items) |id, label| {
        const n = self.changedOn(id);
        const text = if (n == 0) "" else std.fmt.bufPrintZ(&buf, "{d}", .{n}) catch "";
        wk.gtk_label_set_text(label, text.ptr);
    }
}

/// Rebuild the All Settings rows for the current search and filter.
fn rebuild(self: *SettingsWindow) void {
    wk.gtk_list_box_remove_all(self.list);
    self.rows.clearRetainingCapacity();
    const keys = self.visibleKeys(self.gpa) catch return;
    defer self.gpa.free(keys);
    for (keys) |key| self.addRow(key) catch |err| {
        log.warn("settings: row {s} failed err={}", .{ key, err });
    };
}

fn addRow(self: *SettingsWindow, key: []const u8) !void {
    const r = self.reader() orelse return;
    const entry_def = self.catalog.get(key) orelse return;
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const outer = wk.gtk_box_new(1, 2);
    wk.gtk_widget_set_margin_start(outer, 12);
    wk.gtk_widget_set_margin_end(outer, 12);
    wk.gtk_widget_set_margin_top(outer, 6);
    wk.gtk_widget_set_margin_bottom(outer, 6);

    const line = wk.gtk_box_new(0, 8);
    const name = wk.gtk_label_new((try arena.dupeZ(u8, key)).ptr);
    wk.gtk_label_set_xalign(name, 0.0);
    wk.gtk_widget_set_hexpand(name, 1);
    if (r.isModified(key)) wk.gtk_widget_add_css_class(name, "heading");
    if (entry_def.doc) |doc| {
        const summary = try SettingsCatalog.summary(arena, doc);
        wk.gtk_widget_set_tooltip_text(name, (try arena.dupeZ(u8, summary)).ptr);
    }
    wk.gtk_box_append(line, name);

    // Mac's "<Page> >" link: the key has a curated home this window shows.
    const index = self.rows.items.len;
    if (pages.pageFor(key)) |id| if (pageShown(pages.page(id))) {
        const link = wk.gtk_button_new_with_label((try std.fmt.allocPrintSentinel(arena, "{s} \u{203A}", .{pages.page(id).title}, 0)).ptr);
        wk.gtk_widget_add_css_class(link, "flat");
        wk.gtk_widget_set_tooltip_text(link, "Show this setting on its page");
        tag(link, "settings-row", index);
        self.connect(link, "clicked", @ptrCast(&onRevealClicked));
        wk.gtk_box_append(line, link);
    };

    const overriding = if (self.sources) |*s| s.overriding(key) else null;
    // A plain key is one field; a repeatable key is Mac's `ListControl` -
    // the file's values as chips, then an "add a value" field (T3632).
    var chips: ?*wk.GtkWidget = null;
    var in_effect: ?*wk.GtkWidget = null;
    const entry = if (entry_def.repeatable) blk: {
        const ed = try self.buildListEditor(arena, "add a value", "settings-row", index);
        try self.fillChips(ed.chips, try self.file.values(arena, key), "settings-row", index, overriding == null);
        wk.gtk_editable_set_text(ed.entry, (try arena.dupeZ(u8, self.draftFor(key))).ptr);
        wk.gtk_box_append(line, ed.box);
        chips = ed.chips;
        break :blk ed.entry;
    } else blk: {
        const field = wk.gtk_entry_new();
        wk.gtk_editable_set_width_chars(field, 28);
        wk.gtk_editable_set_text(field, (try arena.dupeZ(u8, r.value(key))).ptr);
        wk.gtk_box_append(line, field);
        break :blk field;
    };

    const reset = wk.gtk_button_new_with_label("Reset");
    wk.gtk_widget_set_sensitive(reset, @intFromBool(r.isSetInFile(key)));
    wk.gtk_box_append(line, reset);
    wk.gtk_box_append(outer, line);

    // A list's values in effect, from every file and the defaults.
    if (entry_def.repeatable) {
        const vals = try r.values(arena, key);
        if (vals.len > 0) {
            const l = wk.gtk_label_new((try inEffectText(arena, vals)).ptr);
            wk.gtk_widget_add_css_class(l, "caption");
            wk.gtk_widget_add_css_class(l, "monospace");
            wk.gtk_widget_add_css_class(l, "dim-label");
            wk.gtk_label_set_xalign(l, 0.0);
            wk.gtk_label_set_ellipsize(l, 3);
            wk.gtk_box_append(outer, l);
            in_effect = l;
        }
    }

    const note = wk.gtk_label_new(null);
    wk.gtk_widget_add_css_class(note, "caption");
    wk.gtk_label_set_xalign(note, 0.0);
    wk.gtk_label_set_wrap(note, 1);
    wk.gtk_box_append(outer, note);

    // A key a later file overrides is shown but not edited here.
    if (overriding) |src| {
        const msg = try SettingsSources.overrideMessage(arena, src, null);
        wk.gtk_label_set_text(note, (try arena.dupeZ(u8, msg)).ptr);
        wk.gtk_widget_set_sensitive(entry, 0);
        wk.gtk_widget_set_sensitive(reset, 0);
    }
    if (self.model.problem(key)) |p| {
        wk.gtk_label_set_text(note, (try arena.dupeZ(u8, p)).ptr);
        wk.gtk_widget_add_css_class(note, "error");
    }
    wk.gtk_widget_set_visible(note, @intFromBool(overriding != null or self.model.problem(key) != null));

    try self.rows.append(self.gpa, .{ .key = entry_def.key, .entry = entry, .note = note, .chips = chips, .in_effect = in_effect });
    self.connect(entry, "activate", @ptrCast(&onEntryActivate));
    self.connect(reset, "clicked", @ptrCast(&onResetClicked));
    // The row index rides on the widgets, so a signal finds its key.
    tag(entry, "settings-row", index);
    tag(reset, "settings-row", index);
    wk.gtk_list_box_append(self.list, outer);
}

fn rowOf(self: *SettingsWindow, widget: *wk.GtkWidget) ?*Row {
    const i = tagOf(widget, "settings-row") orelse return null;
    if (i >= self.rows.items.len) return null;
    return &self.rows.items[i];
}

/// What a plain key's All Settings row now shows (the seam's read-back).
pub fn shownValue(self: *const SettingsWindow, key: []const u8) ?[]const u8 {
    for (self.rows.items) |row| {
        if (std.mem.eql(u8, row.key, key)) return std.mem.span(wk.gtk_editable_get_text(row.entry));
    }
    return null;
}

/// A list key's All Settings row as drawn: its chips (read back from the
/// labels), its "add a value" field and its "In effect:" line. Null when the
/// key is not listed or is not a list. The strings are GTK's.
pub const ListShown = struct {
    chips: []const []const u8,
    field: []const u8,
    in_effect: ?[]const u8,
    removable: bool,
};

pub fn listShown(self: *const SettingsWindow, alloc: Allocator, key: []const u8) Allocator.Error!?ListShown {
    for (self.rows.items) |row| {
        if (!std.mem.eql(u8, row.key, key)) continue;
        const chips = row.chips orelse return null;
        var removable = true;
        var chip = wk.gtk_widget_get_first_child(chips);
        while (chip) |ch| : (chip = wk.gtk_widget_get_next_sibling(ch)) {
            if (wk.gtk_widget_get_last_child(ch)) |x| removable = removable and wk.gtk_widget_get_sensitive(x) != 0;
        }
        return .{
            .chips = try chipValues(alloc, chips),
            .field = std.mem.span(wk.gtk_editable_get_text(row.entry)),
            .in_effect = if (row.in_effect) |l| std.mem.span(wk.gtk_label_get_text(l)) else null,
            .removable = removable and wk.gtk_widget_get_sensitive(row.entry) != 0,
        };
    }
    return null;
}

/// The "add a value" field of a curated list row, as typed.
pub fn listField(c: *const Curated) ?[]const u8 {
    if (c.kind != .list and c.kind != .font) return null;
    return std.mem.span(wk.gtk_editable_get_text(c.entry.?));
}

/// The effective value a row reads (file line first), for the seam.
pub fn value(self: *const SettingsWindow, key: []const u8) ?[]const u8 {
    const r = self.reader() orelse return null;
    if (self.catalog.get(key) == null) return null;
    return r.value(key);
}

pub fn isSetInFile(self: *const SettingsWindow, key: []const u8) bool {
    const r = self.reader() orelse return false;
    return r.isSetInFile(key);
}

pub fn isModified(self: *const SettingsWindow, key: []const u8) bool {
    const r = self.reader() orelse return false;
    return r.isModified(key);
}

pub fn overrideFor(self: *const SettingsWindow, alloc: Allocator, key: []const u8) Allocator.Error!?[]u8 {
    const s = if (self.sources) |*s| s else return null;
    const src = s.overriding(key) orelse return null;
    return try SettingsSources.overrideMessage(alloc, src, null);
}

pub fn problem(self: *const SettingsWindow, key: []const u8) ?[]const u8 {
    return self.model.problem(key);
}

pub fn mainPath(self: *const SettingsWindow) []const u8 {
    return self.main_path;
}

// ---------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------

/// Show page `id` (a sidebar click). False when this window does not list it.
pub fn setPage(self: *SettingsWindow, id: PageId) bool {
    const i = std.mem.indexOfScalar(PageId, self.shown_pages.items, id) orelse return false;
    self.page = id;
    wk.gtk_stack_set_visible_child_name(self.stack, @tagName(id).ptr);
    // Mac's `.onAppear` / `.task`: the live sections re-read when shown.
    self.live.shown(self, id);
    const row = wk.gtk_list_box_get_row_at_index(self.sidebar, @intCast(i));
    if (wk.gtk_list_box_get_selected_row(self.sidebar) != row) {
        self.syncing = true;
        defer self.syncing = false;
        wk.gtk_list_box_select_row(self.sidebar, row);
    }
    return true;
}

/// The page the stack is showing, as GTK reports it.
pub fn visiblePageName(self: *const SettingsWindow) []const u8 {
    return std.mem.span(wk.gtk_stack_get_visible_child_name(self.stack) orelse "");
}

/// The All Settings filter (its dropdown).
pub fn setFilter(self: *SettingsWindow, f: Filter) void {
    const pos: c_uint = @intFromEnum(f);
    if (wk.gtk_drop_down_get_selected(self.filter_dd) != pos) {
        // The dropdown's own signal applies it.
        wk.gtk_drop_down_set_selected(self.filter_dd, pos);
        return;
    }
    if (self.filter == f) return;
    self.filter = f;
    self.rebuild();
}

/// What typing in the search field does: All Settings narrows, and shows.
pub fn setQuery(self: *SettingsWindow, q: []const u8) void {
    self.query.clearRetainingCapacity();
    self.query.appendSlice(self.gpa, q) catch return;
    if (std.mem.trim(u8, q, " \t").len > 0) _ = self.setPage(.advanced);
    self.rebuild();
}

/// All Settings' "<Page> >" link: the key's page, its row focused.
pub fn reveal(self: *SettingsWindow, key: []const u8) bool {
    const id = pages.pageFor(key) orelse return false;
    if (!self.setPage(id)) return false;
    if (self.curatedFor(key)) |c| _ = wk.gtk_widget_grab_focus(c.row);
    return true;
}

// ---------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------

pub const EditError = error{ UnknownKey, Overridden, List };

/// Set a plain key to `val`: what typing in its row and pressing Return
/// does. False when the value was refused (the row shows why) or the file
/// could not be written.
pub fn setValue(self: *SettingsWindow, key: []const u8, val: []const u8) (EditError || Allocator.Error)!bool {
    const def = self.catalog.get(key) orelse return error.UnknownKey;
    if (def.repeatable) return error.List;
    if (self.sources) |*s| if (s.overriding(key) != null) return error.Overridden;
    const ok = try self.model.set(def.key, val);
    log.info("settings: set {s} ok={}", .{ def.key, ok });
    self.afterChange();
    return ok;
}

/// Remove every line for `key` from the file: a row's Reset button.
pub fn resetKey(self: *SettingsWindow, key: []const u8) (EditError || Allocator.Error)!bool {
    const def = self.catalog.get(key) orelse return error.UnknownKey;
    if (self.sources) |*s| if (s.overriding(key) != null) return error.Overridden;
    const ok = try self.model.reset(def.key);
    log.info("settings: reset {s} ok={}", .{ def.key, ok });
    self.afterChange();
    return ok;
}

/// A curated control's pick (win32 `chooseValue`). "" is "unset": the key
/// leaves the user's file. Picking what the file already says writes
/// nothing.
pub fn chooseValue(self: *SettingsWindow, key: []const u8, val: []const u8) bool {
    const def = self.catalog.get(key) orelse return false;
    if (self.sources) |*s| if (s.overriding(def.key) != null) return false;
    const r = self.reader() orelse return false;
    if (val.len == 0) {
        if (!r.isSetInFile(def.key)) return true;
        return self.resetKey(def.key) catch false;
    }
    if (r.isSetInFile(def.key) and std.mem.eql(u8, r.value(def.key), val)) return true;
    const ok = self.model.set(def.key, val) catch false;
    log.info("settings: choose {s}={s} ok={}", .{ def.key, val, ok });
    self.afterChange();
    return ok;
}

/// A list field's Return (Mac `ListControl.onSubmit`): the user's file's
/// values plus `text`, through `setList`. Blank writes nothing. A refused
/// value keeps its text in the field (`draftFor`) and the row says why.
pub fn addListValue(self: *SettingsWindow, key: []const u8, text: []const u8) bool {
    const v = std.mem.trim(u8, text, " \t");
    if (v.len == 0) return false;
    const def = self.catalog.get(key) orelse return false;
    // The list as the file says NOW: an editor's save a moment ago is kept.
    self.rereadFile();
    const vals = self.file.values(self.gpa, def.key) catch return false;
    defer self.gpa.free(vals);
    var next: std.ArrayListUnmanaged([]const u8) = .empty;
    defer next.deinit(self.gpa);
    next.appendSlice(self.gpa, vals) catch return false;
    next.append(self.gpa, v) catch return false;
    const ok = self.writeList(def.key, next.items);
    self.setDraft(if (ok) null else def.key, text);
    self.afterChange();
    return ok;
}

/// A chip's x: the user's file keeps every other value, in order.
pub fn removeListValue(self: *SettingsWindow, key: []const u8, index: usize) bool {
    const def = self.catalog.get(key) orelse return false;
    const vals = self.file.values(self.gpa, def.key) catch return false;
    defer self.gpa.free(vals);
    if (index >= vals.len) return false;
    var next: std.ArrayListUnmanaged([]const u8) = .empty;
    defer next.deinit(self.gpa);
    for (vals, 0..) |v, i| if (i != index) next.append(self.gpa, v) catch return false;
    const ok = self.writeList(def.key, next.items);
    self.afterChange();
    return ok;
}

fn rereadFile(self: *SettingsWindow) void {
    if (self.store.read(self.gpa)) |t| {
        self.file.deinit();
        self.file = t;
    } else |_| {}
}

fn writeList(self: *SettingsWindow, key: []const u8, vals: []const []const u8) bool {
    if (self.sources) |*s| if (s.overriding(key) != null) return false;
    if (!(self.catalog.get(key) orelse return false).repeatable) return false;
    const ok = self.model.setList(key, vals) catch false;
    log.info("settings: list {s} n={d} ok={}", .{ key, vals.len, ok });
    return ok;
}

fn setDraft(self: *SettingsWindow, key: ?[]const u8, text: []const u8) void {
    self.draft_key.clearRetainingCapacity();
    self.draft_text.clearRetainingCapacity();
    const k = key orelse return;
    self.draft_key.appendSlice(self.gpa, k) catch return;
    self.draft_text.appendSlice(self.gpa, text) catch {};
}

/// The refused text a list row's field keeps, or "".
fn draftFor(self: *const SettingsWindow, key: []const u8) []const u8 {
    if (!std.mem.eql(u8, self.draft_key.items, key)) return "";
    if (self.model.problem(key) == null) return "";
    return self.draft_text.items;
}

/// The Font picker's pick (Mac `FontControl`'s setter): "" (Default)
/// removes the key; a family replaces the FIRST value of the user's file -
/// as the file says now - and keeps every fallback.
pub fn pickFont(self: *SettingsWindow, key: []const u8, family: []const u8) bool {
    const def = self.catalog.get(key) orelse return false;
    if (self.sources) |*s| if (s.overriding(def.key) != null) return false;
    if (family.len == 0) return self.chooseValue(def.key, "");
    self.rereadFile();
    const vals = self.file.values(self.gpa, def.key) catch return false;
    defer self.gpa.free(vals);
    const next = (controls.fontPick(self.gpa, vals, family) catch return false) orelse return true;
    defer self.gpa.free(next);
    const ok = self.writeList(def.key, next);
    log.info("settings: font {s} ok={}", .{ family, ok });
    self.afterChange();
    return ok;
}

/// A flag's switch: every schema flag is written explicitly, as Mac's.
pub fn setFlag(self: *SettingsWindow, key: []const u8, flag: []const u8, on: bool) bool {
    const entry_def = self.catalog.get(key) orelse return false;
    const options = entry_def.options orelse return false;
    const r = self.reader() orelse return false;
    var known = false;
    for (options) |o| known = known or std.mem.eql(u8, o, flag);
    if (!known) return false;
    const next = controls.composeFlags(self.gpa, options, r.value(key), flag, on) catch return false;
    defer self.gpa.free(next);
    return self.chooseValue(key, next);
}

/// A shell row's write (a menu pick, or Other...'s typed command): refused
/// with Mac's inline problem when its program is not an executable.
pub fn chooseShell(self: *SettingsWindow, key: []const u8, command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t");
    if (trimmed.len == 0) return self.chooseValue(key, "");
    var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const path_env = std.posix.getenv("PATH") orelse "";
    if (controls.shellProblemPosix(&buf, trimmed, path_env, {}, isExecutable)) |p| {
        self.model.setProblem(key, p) catch {};
        log.info("settings: shell {s} refused: {s}", .{ key, p });
        self.afterChange();
        return false;
    }
    return self.chooseValue(key, trimmed);
}

/// A write (or a refusal) changed what the rows show: read everything again
/// and redraw on idle - never under the signal of a widget the All Settings
/// rebuild is about to destroy.
pub fn afterChange(self: *SettingsWindow) void {
    self.reloadData();
    if (self.refresh_source == 0) self.refresh_source = wk.g_idle_add(@ptrCast(&onIdleRefresh), self);
}

/// Run a pending redraw now (the seam reads the widgets right after an op).
pub fn flush(self: *SettingsWindow) void {
    if (self.slide_source != 0) {
        _ = wk.g_source_remove(self.slide_source);
        self.slide_source = 0;
        self.writeSlide();
    }
    if (self.refresh_source != 0) {
        _ = wk.g_source_remove(self.refresh_source);
        self.refresh_source = 0;
        self.redraw();
    }
    self.theme.flush();
}

/// The slider key whose drag has not been written yet (the preview shows
/// its value meanwhile), else null.
pub fn slidingKey(self: *const SettingsWindow) ?[]const u8 {
    if (self.slide_source == 0) return null;
    if (self.slide_index >= self.curated.items.len) return null;
    return self.curated.items[self.slide_index].key;
}

fn redraw(self: *SettingsWindow) void {
    self.rebuild();
    self.refreshCurated();
    self.refreshCounts();
    self.config_file.refresh(self);
    self.theme.refresh();
}

fn onIdleRefresh(self: *SettingsWindow) callconv(.c) c_int {
    self.refresh_source = 0;
    if (open_window == self) self.redraw();
    return 0; // G_SOURCE_REMOVE
}

fn writeSlide(self: *SettingsWindow) void {
    if (self.slide_index >= self.curated.items.len) return;
    const c = &self.curated.items[self.slide_index];
    const s = c.def.control.slider;
    var buf: [32]u8 = undefined;
    _ = self.chooseValue(c.key, controls.formatValue(&buf, controls.snap(self.slide_value, s.min, s.max, s.step)));
}

fn onSlideSettled(self: *SettingsWindow) callconv(.c) c_int {
    self.slide_source = 0;
    if (open_window == self) self.writeSlide();
    return 0;
}

/// `SettingsModel`'s after-write hook: apply the change live.
fn reloadHook(ctx: ?*anyopaque) void {
    const self: *SettingsWindow = @ptrCast(@alignCast(ctx orelse return));
    // Hard, like `+reload --config`: the files are read again.
    _ = self.app.performAction(.app, .reload_config, .{ .soft = false }) catch |err| {
        log.warn("settings: reload after write failed err={}", .{err});
    };
}

// ---------------------------------------------------------------------
// The gestures, as the seam drives them: each moves the WIDGET, and the
// widget's own signal does the write. A field's Return and a button's click
// are emitted as the signals themselves: `gtk_widget_activate` on a GtkButton
// only clicks after a ~250 ms pressed-look timeout, and on a GtkEntry it
// never reached the `activate` handler (measured in T3631's first run).
// ---------------------------------------------------------------------

pub const GestureError = error{ NotCurated, WrongControl, BadValue, NotListed };

/// Type into a curated list row's "add a value" field and press Return.
pub fn gestureListAdd(self: *SettingsWindow, key: []const u8, text: []const u8) GestureError!void {
    const c = self.curatedFor(key) orelse return error.NotCurated;
    if (c.kind != .list and c.kind != .font) return error.WrongControl;
    wk.gtk_editable_set_text(c.entry.?, (self.gpa.dupeZ(u8, text) catch return error.BadValue).ptr);
    wk.g_signal_emit_by_name(c.entry.?, "activate");
}

/// Click the x on a curated list row's `index`th chip.
pub fn gestureListRemove(self: *SettingsWindow, key: []const u8, index: usize) GestureError!void {
    const c = self.curatedFor(key) orelse return error.NotCurated;
    if (c.kind != .list and c.kind != .font) return error.WrongControl;
    try emitChipRemove(c.chips.?, index);
}

/// Type into an All Settings list row's "add a value" field and press
/// Return. The row must be listed (search for it first).
pub fn gestureRowAdd(self: *SettingsWindow, key: []const u8, text: []const u8) GestureError!void {
    const row = self.listRow(key) orelse return error.NotListed;
    wk.gtk_editable_set_text(row.entry, (self.gpa.dupeZ(u8, text) catch return error.BadValue).ptr);
    wk.g_signal_emit_by_name(row.entry, "activate");
}

/// Click the x on an All Settings list row's `index`th chip.
pub fn gestureRowRemove(self: *SettingsWindow, key: []const u8, index: usize) GestureError!void {
    const row = self.listRow(key) orelse return error.NotListed;
    try emitChipRemove(row.chips.?, index);
}

fn listRow(self: *SettingsWindow, key: []const u8) ?*Row {
    for (self.rows.items) |*row| {
        if (std.mem.eql(u8, row.key, key)) return if (row.chips != null) row else null;
    }
    return null;
}

fn emitChipRemove(chips: *wk.GtkWidget, index: usize) GestureError!void {
    var i: usize = 0;
    var chip = wk.gtk_widget_get_first_child(chips);
    while (chip) |ch| : (chip = wk.gtk_widget_get_next_sibling(ch)) {
        if (i == index) {
            const x = wk.gtk_widget_get_last_child(ch) orelse return error.BadValue;
            // An inert x (a later file owns the key) does nothing, as a
            // click on an insensitive button does.
            if (wk.gtk_widget_get_sensitive(x) != 0) wk.g_signal_emit_by_name(x, "clicked");
            return;
        }
        i += 1;
    }
    return error.BadValue;
}

/// Flip a curated switch.
pub fn gestureToggle(self: *SettingsWindow, key: []const u8) GestureError!void {
    const c = self.curatedFor(key) orelse return error.NotCurated;
    if (c.kind != .toggle) return error.WrongControl;
    wk.adw_switch_row_set_active(c.row, @intFromBool(wk.adw_switch_row_get_active(c.row) == 0));
}

/// Pick the popup item whose value is `val` ("" picks the unset item; on a
/// shell row anything not listed goes through Other...).
pub fn gestureChoose(self: *SettingsWindow, key: []const u8, val: []const u8) GestureError!void {
    const c = self.curatedFor(key) orelse return error.NotCurated;
    if (c.kind != .choice and c.kind != .shell and c.kind != .font) return error.WrongControl;
    for (c.choices, 0..) |o, i| if (std.mem.eql(u8, o.value, val)) {
        wk.adw_combo_row_set_selected(c.row, @intCast(i));
        return;
    };
    if (c.kind != .shell) return error.BadValue;
    wk.adw_combo_row_set_selected(c.row, @intCast(c.choices.len));
    wk.gtk_editable_set_text(c.entry.?, (self.gpa.dupeZ(u8, val) catch return error.BadValue).ptr);
    wk.g_signal_emit_by_name(c.entry.?, "activate");
}

/// One click of a spin row's arrow (`dir` +1 up, -1 down).
pub fn gestureStep(self: *SettingsWindow, key: []const u8, dir: i32) GestureError!void {
    const c = self.curatedFor(key) orelse return error.NotCurated;
    if (c.kind != .spin) return error.WrongControl;
    const step: f64 = switch (c.def.control) {
        .stepper => |s| s.step,
        else => 1,
    };
    wk.adw_spin_row_set_value(c.row, wk.adw_spin_row_get_value(c.row) + @as(f64, @floatFromInt(dir)) * step);
}

/// Drag a slider to `v` (the write follows once it settles; `flush` runs it).
pub fn gestureSlide(self: *SettingsWindow, key: []const u8, v: f64) GestureError!void {
    const c = self.curatedFor(key) orelse return error.NotCurated;
    if (c.kind != .slider) return error.WrongControl;
    wk.gtk_range_set_value(c.scale.?, v);
}

/// Set one flag's switch.
pub fn gestureFlag(self: *SettingsWindow, key: []const u8, flag: []const u8, on: bool) GestureError!void {
    const c = self.curatedFor(key) orelse return error.NotCurated;
    if (c.kind != .flags) return error.WrongControl;
    for (c.flag_names, c.flag_rows) |name, sw| if (std.mem.eql(u8, name, flag)) {
        wk.adw_switch_row_set_active(sw, @intFromBool(on));
        return;
    };
    return error.BadValue;
}

/// Type into a curated text row and press Return.
pub fn gestureText(self: *SettingsWindow, key: []const u8, text: []const u8) GestureError!void {
    const c = self.curatedFor(key) orelse return error.NotCurated;
    if (c.kind != .text) return error.WrongControl;
    wk.gtk_editable_set_text(c.entry.?, (self.gpa.dupeZ(u8, text) catch return error.BadValue).ptr);
    wk.g_signal_emit_by_name(c.entry.?, "activate");
}

/// A curated row's reset button.
pub fn gestureReset(self: *SettingsWindow, key: []const u8) GestureError!void {
    const c = self.curatedFor(key) orelse return error.NotCurated;
    wk.g_signal_emit_by_name(c.reset, "clicked");
}

// ---------------------------------------------------------------------
// Lifetime
// ---------------------------------------------------------------------

/// Close the window: the button in its title bar, and the seam's `close`.
pub fn close(self: *SettingsWindow) void {
    self.config_file.teardown();
    wk.gtk_window_destroy(self.window);
    self.destroy();
}

fn destroy(self: *SettingsWindow) void {
    if (open_window != self) return;
    open_window = null;
    if (self.refresh_source != 0) _ = wk.g_source_remove(self.refresh_source);
    if (self.slide_source != 0) _ = wk.g_source_remove(self.slide_source);
    const gpa = self.gpa;
    self.config_file.deinit(gpa);
    self.live.deinit(gpa);
    self.theme.deinit(gpa);
    self.rows.deinit(gpa);
    self.curated.deinit(gpa);
    self.groups.deinit(gpa);
    self.shown_pages.deinit(gpa);
    self.counts.deinit(gpa);
    self.build_arena.deinit();
    self.font_arena.deinit();
    self.query.deinit(gpa);
    self.draft_key.deinit(gpa);
    self.draft_text.deinit(gpa);
    self.model.deinit();
    if (self.sources) |*s| s.deinit();
    if (self.effective) |*e| e.deinit();
    self.catalog.deinit();
    self.file.deinit();
    self.store.deinit();
    freePaths(gpa, self.default_paths);
    gpa.free(self.main_path);
    gpa.destroy(self);
    log.info("settings: closed", .{});
}

// ---------------------------------------------------------------------
// Signals
// ---------------------------------------------------------------------

fn onCloseRequest(_: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) c_int {
    self.config_file.teardown();
    self.destroy();
    return 0; // let GTK destroy the window
}

fn onShortcutGuideClicked(_: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    ShortcutGuideWindow.open(self.app);
}

fn onSearchChanged(entry: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const text = std.mem.span(wk.gtk_editable_get_text(entry));
    // GtkSearchEntry reports after the fact, even for text set here (T3570).
    if (std.mem.eql(u8, text, self.query.items)) return;
    self.setQuery(text);
}

fn onSidebarSelected(_: *wk.GtkWidget, row: ?*wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    if (self.syncing) return;
    const r = row orelse return;
    const idx = wk.gtk_list_box_row_get_index(r);
    if (idx < 0) return;
    const i: usize = @intCast(idx);
    if (i < self.shown_pages.items.len) _ = self.setPage(self.shown_pages.items[i]);
}

fn onFilterSelected(dd: *wk.GtkWidget, _: ?*anyopaque, self: *SettingsWindow) callconv(.c) void {
    const pos = wk.gtk_drop_down_get_selected(dd);
    const f: Filter = switch (pos) {
        1 => .changed,
        2 => .uncovered,
        else => .all,
    };
    if (self.filter == f) return;
    self.filter = f;
    self.rebuild();
}

fn onEntryActivate(entry: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const row = self.rowOf(entry) orelse return;
    const text = std.mem.span(wk.gtk_editable_get_text(entry));
    if (row.chips != null) {
        _ = self.addListValue(row.key, text);
        return;
    }
    _ = self.setValue(row.key, text) catch |err| log.warn("settings: set {s} err={}", .{ row.key, err });
}

fn onResetClicked(button: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const row = self.rowOf(button) orelse return;
    _ = self.resetKey(row.key) catch |err| log.warn("settings: reset {s} err={}", .{ row.key, err });
}

fn onRevealClicked(button: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const row = self.rowOf(button) orelse return;
    _ = self.reveal(row.key);
}

fn onSwitchActive(sw: *wk.GtkWidget, _: ?*anyopaque, self: *SettingsWindow) callconv(.c) void {
    if (self.syncing) return;
    const c = self.curatedOf(sw) orelse return;
    _ = self.chooseValue(c.key, if (wk.adw_switch_row_get_active(sw) != 0) "true" else "false");
}

fn onComboSelected(row: *wk.GtkWidget, _: ?*anyopaque, self: *SettingsWindow) callconv(.c) void {
    if (self.syncing) return;
    const c = self.curatedOf(row) orelse return;
    const sel = wk.adw_combo_row_get_selected(row);
    if (c.kind == .font) {
        if (sel < c.choices.len) _ = self.pickFont(c.key, c.choices[sel].value);
        return;
    }
    if (c.kind == .shell) {
        if (sel == c.choices.len) {
            // Other...: its field opens; nothing is written until Return.
            wk.gtk_widget_set_visible(c.other_row.?, 1);
            _ = wk.gtk_widget_grab_focus(c.entry.?);
            return;
        }
        wk.gtk_widget_set_visible(c.other_row.?, 0);
        if (sel < c.choices.len) _ = self.chooseShell(c.key, c.choices[sel].value);
        return;
    }
    if (sel < c.choices.len) _ = self.chooseValue(c.key, c.choices[sel].value);
}

fn onShellOtherActivate(field: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const c = self.curatedOf(field) orelse return;
    _ = self.chooseShell(c.key, std.mem.span(wk.gtk_editable_get_text(field)));
}

fn onSpinValue(row: *wk.GtkWidget, _: ?*anyopaque, self: *SettingsWindow) callconv(.c) void {
    if (self.syncing) return;
    const c = self.curatedOf(row) orelse return;
    const v = wk.adw_spin_row_get_value(row);
    switch (c.def.control) {
        .megabytes => |m| {
            var mb: [64]u8 = undefined;
            const bytes = controls.megabytesToBytes(controls.formatNumber(&mb, v), m.max) orelse return;
            var buf: [32]u8 = undefined;
            _ = self.chooseValue(c.key, std.fmt.bufPrint(&buf, "{d}", .{bytes}) catch return);
        },
        else => {
            var buf: [64]u8 = undefined;
            _ = self.chooseValue(c.key, controls.formatNumber(&buf, v));
        },
    }
}

fn onScaleChanged(scale: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    if (self.syncing) return;
    const i = tagOf(scale, "settings-curated") orelse return;
    self.slide_index = i;
    self.slide_value = wk.gtk_range_get_value(scale);
    if (self.slide_source != 0) _ = wk.g_source_remove(self.slide_source);
    self.slide_source = wk.g_timeout_add(slide_settle_ms, @ptrCast(&onSlideSettled), self);
    // Mac: a slider drag previews before it is written.
    self.theme.refreshPreview();
}

/// A slider's readout: Mac's percent (inverted for Dim unfocused panes).
fn formatScale(scale: *wk.GtkWidget, v: f64, data: ?*anyopaque) callconv(.c) [*:0]u8 {
    const self: *SettingsWindow = @ptrCast(@alignCast(data.?));
    var buf: [32]u8 = undefined;
    const c = self.curatedOf(scale) orelse return wk.g_strdup("");
    const s = c.def.control.slider;
    const text = controls.sliderLabel(buf[0 .. buf.len - 1], v, s.percent, s.inverted);
    buf[text.len] = 0;
    return wk.g_strdup(buf[0..text.len :0].ptr);
}

fn onFlagActive(sw: *wk.GtkWidget, _: ?*anyopaque, self: *SettingsWindow) callconv(.c) void {
    if (self.syncing) return;
    const c = self.curatedOf(sw) orelse return;
    const i = tagOf(sw, "settings-flag") orelse return;
    if (i >= c.flag_names.len) return;
    _ = self.setFlag(c.key, c.flag_names[i], wk.adw_switch_row_get_active(sw) != 0);
}

fn onCuratedEntryActivate(field: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const c = self.curatedOf(field) orelse return;
    _ = self.setValue(c.key, std.mem.span(wk.gtk_editable_get_text(field))) catch |err|
        log.warn("settings: set {s} err={}", .{ c.key, err });
}

fn onCuratedListActivate(field: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const c = self.curatedOf(field) orelse return;
    const key = c.key;
    // Copy: the write's redraw may replace the field's text buffer.
    const text = self.gpa.dupe(u8, std.mem.span(wk.gtk_editable_get_text(field))) catch return;
    defer self.gpa.free(text);
    if (self.addListValue(key, text)) wk.gtk_editable_set_text(field, "");
}

fn onCuratedChipRemove(button: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const c = self.curatedOf(button) orelse return;
    const i = tagOf(button, "settings-chip") orelse return;
    // The Font row's chips are the fallbacks: the file's values after the
    // first.
    _ = self.removeListValue(c.key, i + @intFromBool(c.kind == .font));
}

fn onRowChipRemove(button: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const row = self.rowOf(button) orelse return;
    const i = tagOf(button, "settings-chip") orelse return;
    _ = self.removeListValue(row.key, i);
}

fn onCuratedReset(button: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const c = self.curatedOf(button) orelse return;
    _ = self.resetKey(c.key) catch |err| log.warn("settings: reset {s} err={}", .{ c.key, err });
}
