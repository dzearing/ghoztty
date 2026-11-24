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
//! This first slice is the window and Advanced -> All Settings: every key in
//! the generated catalog, searchable, a plain key edited in place (Return
//! saves) with a Reset button. The curated pages, list editing, the theme
//! grid and the backup/undo UI are their own cards (filed from T3569).
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

const Application = @import("class/application.zig").Application;

const log = std.log.scoped(.gtk_settings);

/// One All Settings row as built: the key (borrowed from the catalog) and
/// the widgets a change touches.
const Row = struct {
    key: []const u8,
    entry: *wk.GtkWidget,
    note: *wk.GtkWidget,
};

gpa: Allocator,
app: *Application,
window: *wk.GtkWidget,
search: *wk.GtkWidget,
list: *wk.GtkWidget,

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

var open_window: ?*SettingsWindow = null;

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
    wk.gtk_window_present(self.window);
    log.info("settings: opened keys={d} file={s}", .{ self.catalog.entries.len, self.main_path });
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
        .main_path = @constCast(main_path),
        .default_paths = default_paths,
        .store = store,
        .model = undefined,
        .catalog = catalog,
        .file = file,
    };
    self.model = SettingsModel.init(gpa, &self.store, .{ .ctx = self, .func = reloadHook });
    self.reloadData();
    self.buildChrome();
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

fn buildChrome(self: *SettingsWindow) void {
    const w = self.window;
    wk.gtk_window_set_title(w, "Settings");
    wk.gtk_window_set_default_size(w, 760, 640);
    _ = wk.g_signal_connect_data(w, "close-request", @ptrCast(&onCloseRequest), self, null, 0);

    const column = wk.gtk_box_new(1, 8);
    wk.gtk_widget_set_margin_start(column, 16);
    wk.gtk_widget_set_margin_end(column, 16);
    wk.gtk_widget_set_margin_top(column, 12);
    wk.gtk_widget_set_margin_bottom(column, 12);

    const heading = wk.gtk_label_new("All Settings");
    wk.gtk_widget_add_css_class(heading, "title-2");
    wk.gtk_label_set_xalign(heading, 0.0);
    wk.gtk_box_append(column, heading);

    // Which file the window writes, so a debug build visibly is not the
    // release's config.
    const path_z = self.gpa.dupeZ(u8, self.main_path) catch null;
    defer if (path_z) |p| self.gpa.free(p);
    const file_label = wk.gtk_label_new(if (path_z) |p| p.ptr else null);
    wk.gtk_widget_add_css_class(file_label, "dim-label");
    wk.gtk_widget_add_css_class(file_label, "caption");
    wk.gtk_label_set_xalign(file_label, 0.0);
    wk.gtk_label_set_ellipsize(file_label, 1); // start
    wk.gtk_widget_set_hexpand(file_label, 1);
    const file_line = wk.gtk_box_new(0, 8);
    wk.gtk_box_append(file_line, file_label);
    const open_file = wk.gtk_button_new_with_label("Open File");
    wk.gtk_widget_set_tooltip_text(open_file, "Open the config file in your text editor");
    _ = wk.g_signal_connect_data(open_file, "clicked", @ptrCast(&onOpenFileClicked), self, null, 0);
    wk.gtk_box_append(file_line, open_file);
    wk.gtk_box_append(column, file_line);

    wk.gtk_search_entry_set_placeholder_text(self.search, "Search settings");
    _ = wk.g_signal_connect_data(self.search, "search-changed", @ptrCast(&onSearchChanged), self, null, 0);
    wk.gtk_box_append(column, self.search);

    wk.gtk_list_box_set_selection_mode(self.list, 0); // none
    wk.gtk_widget_add_css_class(self.list, "boxed-list");
    const scroller = wk.gtk_scrolled_window_new();
    wk.gtk_scrolled_window_set_policy(scroller, 2, 0); // never, automatic
    wk.gtk_widget_set_vexpand(scroller, 1);
    wk.gtk_scrolled_window_set_child(scroller, self.list);
    wk.gtk_box_append(column, scroller);

    wk.gtk_window_set_child(w, column);
}

/// Read the file, the other config files and the live config again.
fn reloadData(self: *SettingsWindow) void {
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
}

fn reader(self: *const SettingsWindow) ?SettingsSources.Reader {
    const sources = if (self.sources) |*s| s else return null;
    return .{
        .catalog = &self.catalog,
        .effective = if (self.effective) |*e| e else &self.catalog,
        .sources = sources,
        .file = &self.file,
    };
}

/// The keys All Settings lists for the current search. Caller frees.
pub fn visibleKeys(self: *const SettingsWindow, alloc: Allocator) Allocator.Error![]const []const u8 {
    const r = self.reader() orelse return alloc.alloc([]const u8, 0);
    return r.allSettings(alloc, .all, self.query.items);
}

/// Rebuild the rows for the current search.
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

    const entry = wk.gtk_entry_new();
    wk.gtk_editable_set_width_chars(entry, 28);
    const shown: []const u8 = if (entry_def.repeatable) blk: {
        const vals = try r.values(arena, key);
        break :blk try std.mem.join(arena, ", ", vals);
    } else r.value(key);
    wk.gtk_editable_set_text(entry, (try arena.dupeZ(u8, shown)).ptr);
    wk.gtk_box_append(line, entry);

    const reset = wk.gtk_button_new_with_label("Reset");
    wk.gtk_widget_set_sensitive(reset, @intFromBool(r.isSetInFile(key)));
    wk.gtk_box_append(line, reset);
    wk.gtk_box_append(outer, line);

    const note = wk.gtk_label_new(null);
    wk.gtk_widget_add_css_class(note, "caption");
    wk.gtk_label_set_xalign(note, 0.0);
    wk.gtk_label_set_wrap(note, 1);
    wk.gtk_box_append(outer, note);

    // A key a later file overrides, or a list (its editor is a later
    // card), is shown but not edited here.
    const overriding = if (self.sources) |*s| s.overriding(key) else null;
    if (overriding) |src| {
        const msg = try SettingsSources.overrideMessage(arena, src, null);
        wk.gtk_label_set_text(note, (try arena.dupeZ(u8, msg)).ptr);
        wk.gtk_widget_set_sensitive(entry, 0);
        wk.gtk_widget_set_sensitive(reset, 0);
    } else if (entry_def.repeatable) {
        wk.gtk_widget_set_sensitive(entry, 0);
    }
    if (self.model.problem(key)) |p| {
        wk.gtk_label_set_text(note, (try arena.dupeZ(u8, p)).ptr);
        wk.gtk_widget_add_css_class(note, "error");
    }
    wk.gtk_widget_set_visible(note, @intFromBool(overriding != null or self.model.problem(key) != null));

    const index = self.rows.items.len;
    try self.rows.append(self.gpa, .{ .key = entry_def.key, .entry = entry, .note = note });
    _ = wk.g_signal_connect_data(entry, "activate", @ptrCast(&onEntryActivate), self, null, 0);
    _ = wk.g_signal_connect_data(reset, "clicked", @ptrCast(&onResetClicked), self, null, 0);
    // The row index rides on the widgets, so a signal finds its key.
    wk.g_object_set_data(@ptrCast(entry), "settings-row", @ptrFromInt(index + 1));
    wk.g_object_set_data(@ptrCast(reset), "settings-row", @ptrFromInt(index + 1));
    wk.gtk_list_box_append(self.list, outer);
}

fn rowOf(self: *SettingsWindow, widget: *wk.GtkWidget) ?*Row {
    const tag = @intFromPtr(wk.g_object_get_data(@ptrCast(widget), "settings-row"));
    if (tag == 0 or tag > self.rows.items.len) return null;
    return &self.rows.items[tag - 1];
}

/// What a plain key's row now shows (the test seam's read-back).
pub fn shownValue(self: *const SettingsWindow, key: []const u8) ?[]const u8 {
    for (self.rows.items) |row| {
        if (std.mem.eql(u8, row.key, key)) return std.mem.span(wk.gtk_editable_get_text(row.entry));
    }
    return null;
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

/// What typing in the search field does.
pub fn setQuery(self: *SettingsWindow, q: []const u8) void {
    self.query.clearRetainingCapacity();
    self.query.appendSlice(self.gpa, q) catch return;
    self.rebuild();
}

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

/// Remove every line for `key` from the file: the row's Reset button.
pub fn resetKey(self: *SettingsWindow, key: []const u8) (EditError || Allocator.Error)!bool {
    const def = self.catalog.get(key) orelse return error.UnknownKey;
    if (self.sources) |*s| if (s.overriding(key) != null) return error.Overridden;
    const ok = try self.model.reset(def.key);
    log.info("settings: reset {s} ok={}", .{ def.key, ok });
    self.afterChange();
    return ok;
}

/// A write (or a refusal) changed what the rows show: read everything again
/// and redraw. Rows are rebuilt from scratch, so the redraw runs on idle -
/// never under the signal of a widget it is about to destroy.
fn afterChange(self: *SettingsWindow) void {
    self.reloadData();
    _ = wk.g_idle_add(@ptrCast(&onIdleRebuild), self);
}

fn onIdleRebuild(self: *SettingsWindow) callconv(.c) c_int {
    if (open_window == self) self.rebuild();
    return 0; // G_SOURCE_REMOVE
}

/// `SettingsModel`'s after-write hook: apply the change live.
fn reloadHook(ctx: ?*anyopaque) void {
    const self: *SettingsWindow = @ptrCast(@alignCast(ctx orelse return));
    // Hard, like `+reload --config`: the files are read again.
    _ = self.app.performAction(.app, .reload_config, .{ .soft = false }) catch |err| {
        log.warn("settings: reload after write failed err={}", .{err});
    };
}

/// Close the window: the button in its title bar, and the seam's `close`.
pub fn close(self: *SettingsWindow) void {
    wk.gtk_window_destroy(self.window);
    self.destroy();
}

fn destroy(self: *SettingsWindow) void {
    if (open_window == self) open_window = null;
    const gpa = self.gpa;
    self.rows.deinit(gpa);
    self.query.deinit(gpa);
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

fn onCloseRequest(_: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) c_int {
    self.destroy();
    return 0; // let GTK destroy the window
}

fn onOpenFileClicked(_: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    self.app.openConfigFile();
}

fn onSearchChanged(entry: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    self.setQuery(std.mem.span(wk.gtk_editable_get_text(entry)));
}

fn onEntryActivate(entry: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const row = self.rowOf(entry) orelse return;
    const text = std.mem.span(wk.gtk_editable_get_text(entry));
    _ = self.setValue(row.key, text) catch |err| log.warn("settings: set {s} err={}", .{ row.key, err });
}

fn onResetClicked(button: *wk.GtkWidget, self: *SettingsWindow) callconv(.c) void {
    const row = self.rowOf(button) orelse return;
    _ = self.resetKey(row.key) catch |err| log.warn("settings: reset {s} err={}", .{ row.key, err });
}
