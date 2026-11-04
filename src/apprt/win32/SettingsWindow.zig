//! The Settings window (T2675) - the win32 counterpart of Mac's
//! `SettingsWindowController` + `SettingsView` (docs/reference/settings.md,
//! Mac 9287de0ff).
//!
//! Opened by `open_config`: Ctrl+, (the Windows defaults carry Mac's Cmd+,
//! as Ctrl+,), the menu bar's Settings item and the command palette's "Open
//! Config". The raw file stays one click away ("Open Config File..." at the
//! foot of the sidebar), and if the schema cannot be read at all the action
//! falls back to opening the file, as Mac's does.
//!
//! One window per process, reused, a plain top-level `WS_OVERLAPPEDWINDOW`
//! like the shortcut guide, so the user can leave it open behind the
//! terminal. Layout: a sidebar of pages with a Search field over it and the
//! file's path along its foot; the page's form on the right.
//!
//! Pages: this is the window SHELL. Advanced > All Settings lists every
//! schema key (`SettingsSources.Reader.allSettings`), with the All / Changed
//! filter; the curated pages (Appearance, Panes & Windows, ...) are T2585 and
//! the rest of Advanced (path, includes, backups, the change toast) is T2676.
//!
//! Every row is Mac's `RawSettingRow`: the key, the changed-from-default dot,
//! the doc summary with the full doc on demand, Reset when the user's file
//! sets it, a text field for a plain key or the value list for a repeatable
//! one, the model's inline problem ("invalid value ... - not saved") and,
//! when a file that loads later sets the key, a read-only field and Mac's
//! "Set in X, which loads after your config." note with an Open link.
//!
//! Every write goes through `SettingsModel` (validated by Ghostty's own
//! parser first, so an invalid value never reaches the file) and applies
//! live through the normal config reload; the window re-reads the file, the
//! load order and the effective values on every reload (`configChanged`).
//!
//! Text fields are drawn here rather than being EDIT children: the window
//! routes every key itself, the shortcut guide's way (`settings_line_edit`).
//!
//! Instrumentation: the debug-only `settings` IPC action
//! (`ipc_settings.zig`) drives this window through the same functions its
//! clicks and keys call and reports the rows it paints, which is what
//! `test/win32/settings-window.ps1` asserts.

const SettingsWindow = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Window = @import("Window.zig");
const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const ConfigFileStore = @import("ConfigFileStore.zig");
const ConfigFileText = @import("ConfigFileText.zig");
const SettingsCatalog = @import("SettingsCatalog.zig");
const SettingsModel = @import("SettingsModel.zig");
const SettingsSources = @import("SettingsSources.zig");
const LineEdit = @import("settings_line_edit.zig");
const layout = @import("settings_window_layout.zig");
const notes_render = @import("whats_new_notes.zig");
const panel_theme = @import("panel_theme.zig");
const system_colors = @import("system_colors.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const Rect = layout.Rect;
const dip = layout.dip;
const Reader = SettingsSources.Reader;

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttySettings");
/// Mac's window title.
const TITLE = std.unicode.utf8ToUtf16LeStringLiteral("Settings");

/// Mac caps the uncurated search results at 40 ("N more - keep typing").
pub const search_cap = 40;

var class_registered: bool = false;
/// The open window, if any. GUI thread only.
var active: ?*SettingsWindow = null;

pub const PageId = enum { advanced };

const PageInfo = struct {
    id: PageId,
    title: []const u8,
    /// Drawn on the page's tinted tile (Mac: an SF Symbol on a gradient).
    glyph: []const u8,
};

/// The sidebar, in order. T2585 adds the curated pages ahead of Advanced.
pub const pages = [_]PageInfo{
    .{ .id = .advanced, .title = "Advanced", .glyph = "\u{22EF}" },
};

pub const Filter = Reader.Filter;

/// One laid-out line of the form.
const Item = struct {
    y: i32,
    h: i32,
    kind: Kind,
    /// Catalog-owned (rows), so it survives every reload.
    key: []const u8 = "",
    summary: []const u8 = "",

    const Kind = enum { header, row, more, empty };
};

/// A clickable region recorded by the last paint.
const Hit = struct {
    rect: Rect,
    kind: Kind,
    key: []const u8 = "",
    index: usize = 0,

    const Kind = enum { page, filter, config_link, search_clear, field, add_field, reset, info, open, chip_remove };
};

const Focus = enum { search, field };

app: *App,
gpa: Allocator,
hwnd: w32.HWND,
scale: f32,
text: notes_render.Renderer,

// The model. `catalog` is built once (defaults never change in a session);
// `effective`, `sources` and `file` are re-read on every reload.
main_path: []u8,
/// `main_path` as the sidebar shows it: `~` for the profile folder and one
/// kind of separator, so the path ellipsis keeps the file name.
display_path: []u8,
default_paths: [][]u8,
store: ConfigFileStore,
model: SettingsModel,
catalog: SettingsCatalog,
effective: ?SettingsCatalog = null,
sources: ?SettingsSources = null,
file: ConfigFileText,
/// True while a model write runs: the reload it triggers re-enters through
/// `configChanged`, and the window refreshes once the write returns instead.
in_write: bool = false,

// What the form shows.
page: PageId = .advanced,
filter: Filter = .all,
search: LineEdit = .{},
/// Owns `items`, the listed keys and their summaries (rebuilt per refresh).
view_arena: std.heap.ArenaAllocator,
items: []const Item = &.{},
/// Rows that matched before the search cap.
matched: usize = 0,
listed: []const []const u8 = &.{},
/// The row whose full documentation is shown.
doc_key: ?[]const u8 = null,

// Editing.
focus: Focus = .search,
edit_key: ?[]const u8 = null,
field: LineEdit = .{},

// Pointer state.
hover_key: ?[]const u8 = null,
hover_hand: bool = false,
scroll: i32 = 0,
content_h: i32 = 0,
thumb_drag_dy: i32 = -1,
tracking_leave: bool = false,
hits: std.ArrayListUnmanaged(Hit) = .empty,

// ---------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------

/// Open the window, or focus the one already open (Mac re-reads the file
/// on a re-show, so this does too).
pub fn open(app: *App, window: ?*Window) void {
    if (active) |existing| {
        existing.reloadData();
        existing.refresh();
        _ = w32.ShowWindow(existing.hwnd, if (w32.IsIconic(existing.hwnd) != 0) w32.SW_RESTORE else w32.SW_SHOW);
        _ = w32.SetForegroundWindow(existing.hwnd);
        return;
    }
    const owner: ?w32.HWND = if (window) |w| w.hwnd else null;
    const scale: f32 = if (window) |w| w.scale else 1.0;
    const self = create(app, scale) catch |err| {
        // Mac: "could not read the config schema; opening the config file
        // instead".
        log.err("settings: could not open the Settings window ({}); opening the config file instead", .{err});
        app.openConfigFile();
        return;
    };

    const style: u32 = w32.WS_OVERLAPPEDWINDOW;
    const sz = layout.defaultSize(scale);
    var outer: w32.RECT = .{ .left = 0, .top = 0, .right = sz.w, .bottom = sz.h };
    _ = w32.AdjustWindowRectEx(&outer, style, 0, 0);
    const ow = outer.right - outer.left;
    const oh = outer.bottom - outer.top;
    var x: i32 = w32.CW_USEDEFAULT;
    var y: i32 = w32.CW_USEDEFAULT;
    if (owner) |o| {
        var r: w32.RECT = undefined;
        if (w32.GetWindowRect(o, &r) != 0) {
            x = r.left + @divTrunc((r.right - r.left) - ow, 2);
            y = r.top + @divTrunc((r.bottom - r.top) - oh, 2);
        }
    }
    registerClass(app) orelse {
        self.destroyState();
        app.openConfigFile();
        return;
    };
    const hwnd = w32.CreateWindowExW(0, CLASS_NAME, TITLE, style, x, y, ow, oh, null, null, app.hinstance, null) orelse {
        self.destroyState();
        app.openConfigFile();
        return;
    };
    self.hwnd = hwnd;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    system_colors.applyPanelChrome(hwnd, self.pal());
    active = self;
    self.refresh();
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    log.info("settings: opened keys={d} file={s}", .{ self.catalog.entries.len, self.main_path });
}

fn create(app: *App, scale: f32) !*SettingsWindow {
    const gpa = app.core_app.alloc;
    var catalog = try SettingsCatalog.defaults(gpa);
    errdefer catalog.deinit();
    const preferred = try configpkg.preferredDefaultFilePath(gpa);
    defer gpa.free(preferred);
    const main_path = try gpa.dupe(u8, preferred);
    errdefer gpa.free(main_path);
    const default_paths = try SettingsSources.defaultFilePaths(gpa);
    errdefer freePaths(gpa, default_paths);
    const backup_dir = try backupDir(gpa);
    defer gpa.free(backup_dir);
    const display_path = try displayPath(gpa, main_path);
    errdefer gpa.free(display_path);
    var store = try ConfigFileStore.init(gpa, main_path, backup_dir, .{});
    errdefer store.deinit();
    var file = try ConfigFileText.init(gpa, "");
    errdefer file.deinit();

    const self = try gpa.create(SettingsWindow);
    self.* = .{
        .app = app,
        .gpa = gpa,
        .hwnd = undefined,
        .scale = scale,
        .text = .init(gpa, scale, .spacious, system_colors.panelFor(app)),
        .main_path = main_path,
        .display_path = display_path,
        .default_paths = default_paths,
        .store = store,
        .model = undefined,
        .catalog = catalog,
        .file = file,
        .view_arena = .init(gpa),
    };
    self.model = SettingsModel.init(gpa, &self.store, .{ .ctx = self, .func = reloadHook });
    self.reloadData();
    return self;
}

/// `%LOCALAPPDATA%\ghoztty\config-backups`, or in a debug build the folder
/// `GHOZTTY_SETTINGS_BACKUP_DIR` names - the acceptance script's seam, so a
/// test run never adds to (or prunes) the box's real backups.
fn backupDir(gpa: Allocator) ![]u8 {
    if (comptime build_config.is_debug) {
        if (std.process.getEnvVarOwned(gpa, "GHOZTTY_SETTINGS_BACKUP_DIR")) |v| {
            if (v.len > 0) return v;
            gpa.free(v);
        } else |_| {}
    }
    return ConfigFileStore.defaultBackupDir(gpa);
}

/// `C:\Users\me\AppData/...` -> `~\AppData\...` (Mac abbreviates the home
/// folder the same way). Caller owns the result.
fn displayPath(gpa: Allocator, path: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    const home = std.process.getEnvVarOwned(gpa, "USERPROFILE") catch return out;
    defer gpa.free(home);
    if (home.len == 0 or out.len <= home.len) return out;
    if (!std.ascii.eqlIgnoreCase(out[0..home.len], home) or out[home.len] != '\\') return out;
    defer gpa.free(out);
    return std.fmt.allocPrint(gpa, "~{s}", .{out[home.len..]});
}

fn freePaths(gpa: Allocator, paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

fn destroyState(self: *SettingsWindow) void {
    const gpa = self.gpa;
    self.model.deinit();
    self.store.deinit();
    if (self.sources) |*s| s.deinit();
    if (self.effective) |*e| e.deinit();
    self.catalog.deinit();
    self.file.deinit();
    gpa.free(self.main_path);
    gpa.free(self.display_path);
    freePaths(gpa, self.default_paths);
    self.hits.deinit(gpa);
    self.text.deinit();
    self.view_arena.deinit();
    gpa.destroy(self);
}

fn close(self: *SettingsWindow) void {
    // A field being edited commits on close, as it does on losing focus.
    self.commitEdit();
    active = null;
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    self.destroyState();
}

/// App shutdown.
pub fn closeAll() void {
    if (active) |a| a.close();
}

pub fn current() ?*SettingsWindow {
    return active;
}

/// The config reloaded (App's `config_change`): re-read what the rows show.
pub fn configChanged() void {
    const self = active orelse return;
    if (self.in_write) return;
    self.reloadData();
    self.refresh();
}

fn registerClass(app: *App) ?void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW | w32.CS_DBLCLKS,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = app.hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return null;
    class_registered = true;
}

// ---------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------

fn reloadHook(ctx: ?*anyopaque) void {
    const self: *SettingsWindow = @ptrCast(@alignCast(ctx orelse return));
    _ = self.app.performAction(.app, .reload_config, .{ .soft = false }) catch |err| {
        log.err("settings: config reload after a write failed err={}", .{err});
    };
}

/// Re-read the user's file, every file Ghostty loads, and the live config's
/// effective values. A read that fails keeps what the window had.
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

    if (SettingsCatalog.describe(self.gpa, &self.app.config, false)) |e| {
        if (self.effective) |*old| old.deinit();
        self.effective = e;
    } else |err| log.warn("settings: describing the live config failed err={}", .{err});
}

/// Run a model write: the reload it triggers is folded into one refresh
/// after it returns.
fn write(self: *SettingsWindow, comptime f: anytype, args: anytype) bool {
    self.in_write = true;
    const ok = @call(.auto, f, .{&self.model} ++ args) catch false;
    self.in_write = false;
    self.reloadData();
    self.refresh();
    return ok;
}

pub fn reader(self: *const SettingsWindow) ?Reader {
    const sources = if (self.sources) |*s| s else return null;
    return .{
        .catalog = &self.catalog,
        .effective = if (self.effective) |*e| e else &self.catalog,
        .sources = sources,
        .file = &self.file,
    };
}

pub fn query(self: *const SettingsWindow) []const u8 {
    return std.mem.trim(u8, self.search.text(), " \t");
}

pub fn searching(self: *const SettingsWindow) bool {
    return self.query().len > 0;
}

/// The keys the form lists right now, in order.
pub fn listedKeys(self: *const SettingsWindow) []const []const u8 {
    return self.listed;
}

/// Rows that matched the search before the cap (= listed on a page).
pub fn matchedCount(self: *const SettingsWindow) usize {
    return self.matched;
}

/// The file that sets `key` and loads after the user's, if any.
pub fn overridingSource(self: *const SettingsWindow, key: []const u8) ?*const SettingsSources.Source {
    const s = if (self.sources) |*s| s else return null;
    return s.overriding(key);
}

/// How many keys the user's file sets (Mac's Advanced page count: every
/// file key no curated page shows, which until T2585 is all of them).
pub fn changedInFile(self: *const SettingsWindow) usize {
    const r = self.reader() orelse return 0;
    var n: usize = 0;
    for (self.catalog.entries) |*e| {
        if (r.isSetInFile(e.key)) n += 1;
    }
    return n;
}

/// Re-filter and re-lay-out the form.
fn refresh(self: *SettingsWindow) void {
    _ = self.view_arena.reset(.retain_capacity);
    const arena = self.view_arena.allocator();
    self.listed = &.{};
    self.matched = 0;
    if (self.reader()) |r| {
        if (self.searching()) {
            const all = r.allSettings(arena, .all, self.query()) catch &.{};
            self.matched = all.len;
            self.listed = all[0..@min(all.len, search_cap)];
        } else {
            self.listed = r.allSettings(arena, self.filter, "") catch &.{};
            self.matched = self.listed.len;
        }
    }
    if (self.edit_key) |k| if (!contains(self.listed, k)) {
        self.edit_key = null;
        self.focus = .search;
    };
    self.layoutItems();
    self.scroll = layout.clampScroll(self.scroll, self.content_h, self.frame().list.h);
    self.invalidate();
}

fn contains(list: []const []const u8, key: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

fn layoutItems(self: *SettingsWindow) void {
    const arena = self.view_arena.allocator();
    var list: std.ArrayList(Item) = .empty;
    const header_h = layout.px(dip.header_h, self.scale);
    var y: i32 = 0;

    const hdc = if (self.isWindow()) w32.GetDC(self.hwnd) else null;
    defer if (hdc) |dc| {
        _ = w32.ReleaseDC(self.hwnd, dc);
    };

    if (self.searching()) {
        if (self.listed.len == 0) {
            list.append(arena, .{ .y = y, .h = header_h * 2, .kind = .empty }) catch {};
            y += header_h * 2;
        } else {
            list.append(arena, .{ .y = y, .h = header_h, .kind = .header }) catch {};
            y += header_h;
        }
    } else if (self.listed.len == 0) {
        list.append(arena, .{ .y = y, .h = header_h * 2, .kind = .empty }) catch {};
        y += header_h * 2;
    }
    for (self.listed) |key| {
        const doc = if (self.catalog.get(key)) |e| e.doc else null;
        const summary = SettingsCatalog.summary(arena, doc) catch "";
        var item: Item = .{ .y = y, .h = 0, .kind = .row, .key = key, .summary = summary };
        item.h = if (hdc) |dc| self.paintRow(dc, self.pal(), item, 0, false) else header_h;
        list.append(arena, item) catch break;
        y += item.h;
    }
    if (self.searching() and self.matched > self.listed.len) {
        list.append(arena, .{ .y = y, .h = header_h, .kind = .more }) catch {};
        y += header_h;
    }
    self.items = list.items;
    self.content_h = y + layout.px(dip.margin, self.scale);
}

// ---------------------------------------------------------------------
// Actions (the IPC seam calls these, the same as clicks and keys)
// ---------------------------------------------------------------------

pub fn setQuery(self: *SettingsWindow, text: []const u8) void {
    self.commitEdit();
    self.search.set(text);
    self.focus = .search;
    self.scroll = 0;
    self.refresh();
}

/// Mac: switching page clears the search.
pub fn setPage(self: *SettingsWindow, page: PageId) void {
    self.commitEdit();
    self.page = page;
    if (self.search.len > 0) self.search.clear();
    self.scroll = 0;
    self.refresh();
}

pub fn setFilter(self: *SettingsWindow, filter: Filter) void {
    self.commitEdit();
    self.filter = filter;
    self.scroll = 0;
    self.refresh();
}

pub fn toggleDoc(self: *SettingsWindow, key: []const u8) void {
    const k = self.catalogKey(key) orelse return;
    self.doc_key = if (self.doc_key != null and std.mem.eql(u8, self.doc_key.?, k)) null else k;
    self.layoutItems();
    self.invalidate();
}

/// Start editing `key`'s field (a plain key's value, or a repeatable key's
/// "add a value" field). False for an unknown or overridden key.
pub fn beginEdit(self: *SettingsWindow, key: []const u8) bool {
    const k = self.catalogKey(key) orelse return false;
    if (self.edit_key) |cur| {
        if (std.mem.eql(u8, cur, k)) return true;
        self.commitEdit();
    }
    if (self.overridingSource(k) != null) return false;
    const r = self.reader() orelse return false;
    const repeatable = if (self.catalog.get(k)) |e| e.repeatable else false;
    if (repeatable) self.field.clear() else self.field.set(r.value(k));
    self.edit_key = k;
    self.focus = .field;
    self.invalidate();
    return true;
}

/// Replace the field's text (the seam's typing).
pub fn setFieldText(self: *SettingsWindow, text: []const u8) void {
    self.field.set(text);
    self.invalidate();
}

/// Enter / losing focus: write what was typed. A plain key cleared to
/// nothing goes back to its default (Mac's `CommitTextField`); an unchanged
/// value writes nothing. A repeatable key appends the typed value.
pub fn commitEdit(self: *SettingsWindow) void {
    const key = self.edit_key orelse return;
    self.edit_key = null;
    self.focus = .search;
    const r = self.reader() orelse return;
    const repeatable = if (self.catalog.get(key)) |e| e.repeatable else false;
    var typed_buf: [LineEdit.capacity]u8 = undefined;
    const typed = typed_buf[0..self.field.len];
    @memcpy(typed, self.field.text());
    if (repeatable) {
        const v = std.mem.trim(u8, typed, " \t");
        if (v.len == 0) {
            self.invalidate();
            return;
        }
        const current_vals = self.file.values(self.gpa, key) catch return;
        defer self.gpa.free(current_vals);
        var next: std.ArrayListUnmanaged([]const u8) = .empty;
        defer next.deinit(self.gpa);
        next.appendSlice(self.gpa, current_vals) catch return;
        next.append(self.gpa, v) catch return;
        const ok = self.write(SettingsModel.setList, .{ key, @as([]const []const u8, next.items) });
        if (!ok) {
            // Keep the rejected text in the field, as Mac's does.
            self.edit_key = key;
            self.focus = .field;
        }
        self.invalidate();
        return;
    }
    if (std.mem.trim(u8, typed, " \t").len == 0) {
        if (r.isSetInFile(key)) _ = self.write(SettingsModel.reset, .{key});
    } else if (!std.mem.eql(u8, typed, r.value(key))) {
        _ = self.write(SettingsModel.set, .{ key, @as([]const u8, typed) });
    }
    self.invalidate();
}

/// Esc in a field: drop what was typed.
pub fn cancelEdit(self: *SettingsWindow) void {
    self.edit_key = null;
    self.focus = .search;
    self.invalidate();
}

/// The Reset button.
pub fn resetKey(self: *SettingsWindow, key: []const u8) bool {
    const k = self.catalogKey(key) orelse return false;
    if (self.edit_key) |e| if (std.mem.eql(u8, e, k)) self.cancelEdit();
    return self.write(SettingsModel.reset, .{k});
}

/// A value chip's remove button: the user's file keeps every other value.
pub fn removeValue(self: *SettingsWindow, key: []const u8, index: usize) bool {
    const k = self.catalogKey(key) orelse return false;
    const vals = self.file.values(self.gpa, k) catch return false;
    defer self.gpa.free(vals);
    if (index >= vals.len) return false;
    var next: std.ArrayListUnmanaged([]const u8) = .empty;
    defer next.deinit(self.gpa);
    for (vals, 0..) |v, i| if (i != index) next.append(self.gpa, v) catch return false;
    return self.write(SettingsModel.setList, .{ k, @as([]const []const u8, next.items) });
}

/// The override note's Open link: the file that sets the key.
pub fn openOverridingFile(self: *SettingsWindow, key: []const u8) void {
    const src = self.overridingSource(key) orelse return;
    shellOpen(self.gpa, src.path);
}

pub fn editingKey(self: *const SettingsWindow) ?[]const u8 {
    return self.edit_key;
}

/// The catalog's own copy of `key`, which outlives every reload.
fn catalogKey(self: *const SettingsWindow, key: []const u8) ?[]const u8 {
    const e = self.catalog.get(key) orelse return null;
    return e.key;
}

fn shellOpen(gpa: Allocator, path: []const u8) void {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(gpa, path) catch return;
    defer gpa.free(wide);
    _ = w32.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), wide.ptr, null, null, w32.SW_SHOW);
}

/// Write the window's pixels to a PNG (the seam's `shot`): WM_PRINTCLIENT
/// into a memory DC, so it works on the background test desktop.
pub fn snapshot(self: *SettingsWindow, alloc: Allocator, path: []const u8) !void {
    const rc = self.clientRect();
    const w = rc.right - rc.left;
    const h = rc.bottom - rc.top;
    if (w <= 0 or h <= 0) return error.EmptyWindow;
    const screen = w32.GetDC(self.hwnd) orelse return error.NoDc;
    defer _ = w32.ReleaseDC(self.hwnd, screen);
    const dib = @import("dib32.zig").create(screen, w, h) orelse return error.NoDib;
    defer dib.destroy();
    self.paint(dib.dc);
    const rgb = try alloc.alloc(u8, dib.pixels.len * 3);
    defer alloc.free(rgb);
    for (dib.pixels, 0..) |px, i| {
        rgb[i * 3] = @truncate(px >> 16);
        rgb[i * 3 + 1] = @truncate(px >> 8);
        rgb[i * 3 + 2] = @truncate(px);
    }
    const png = try @import("png_encode.zig").encode(alloc, .{ .data = rgb, .width = @intCast(w), .height = @intCast(h), .channels = .rgb });
    defer alloc.free(png);
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(png);
}

// ---------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------

fn pal(self: *const SettingsWindow) panel_theme.Panel {
    return system_colors.panelFor(self.app);
}

fn isWindow(self: *const SettingsWindow) bool {
    return active == self;
}

fn clientRect(self: *const SettingsWindow) w32.RECT {
    var rc: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (self.isWindow()) _ = w32.GetClientRect(self.hwnd, &rc);
    return rc;
}

fn frame(self: *const SettingsWindow) layout.Frame {
    const rc = self.clientRect();
    return layout.frameFor(self.scale, rc.right - rc.left, rc.bottom - rc.top, !self.searching());
}

fn invalidate(self: *SettingsWindow) void {
    if (self.isWindow()) _ = w32.InvalidateRect(self.hwnd, null, 0);
}

fn scrollBy(self: *SettingsWindow, dy: i32) void {
    const next = layout.clampScroll(self.scroll + dy, self.content_h, self.frame().list.h);
    if (next == self.scroll) return;
    self.scroll = next;
    self.invalidate();
}

// ---------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------

const cr = notes_render.cr;
const fillRect = notes_render.fillRect;

fn roundRect(hdc: w32.HDC, r: Rect, radius: i32, fill: u32, border: ?u32, border_w: i32) void {
    const brush = w32.CreateSolidBrush(fill) orelse return;
    defer _ = w32.DeleteObject(brush);
    const pen = w32.CreatePen(0, if (border != null) border_w else 1, border orelse fill) orelse return;
    defer _ = w32.DeleteObject(pen);
    const ob = w32.SelectObject(hdc, @ptrCast(brush));
    defer _ = w32.SelectObject(hdc, ob);
    const op = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, op);
    _ = w32.RoundRect(hdc, r.x, r.y, r.x + r.w, r.y + r.h, radius * 2, radius * 2);
}

fn hit(self: *SettingsWindow, h: Hit) void {
    self.hits.append(self.gpa, h) catch {};
}

fn hair(self: *const SettingsWindow) i32 {
    return @max(1, layout.px(1, self.scale));
}

fn paint(self: *SettingsWindow, hdc_screen: w32.HDC) void {
    const rc = self.clientRect();
    const w = rc.right - rc.left;
    const h = rc.bottom - rc.top;
    if (w <= 0 or h <= 0) return;
    const mem = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem);
    const bmp = w32.CreateCompatibleBitmap(hdc_screen, w, h) orelse return;
    defer _ = w32.DeleteObject(bmp);
    const old = w32.SelectObject(mem, bmp);
    defer _ = w32.SelectObject(mem, old);

    const p = self.pal();
    self.text.palette = p;
    self.hits.clearRetainingCapacity();
    _ = w32.SetBkMode(mem, w32.TRANSPARENT);
    const f = layout.frameFor(self.scale, w, h, !self.searching());
    fillRect(mem, .{ .x = 0, .y = 0, .w = w, .h = h }, cr(p.bg));
    self.paintSidebar(mem, f, p);
    fillRect(mem, f.rule, cr(p.divider));
    self.paintTitle(mem, f, p);
    self.paintList(mem, f, p);
    _ = w32.BitBlt(hdc_screen, 0, 0, w, h, mem, 0, 0, w32.SRCCOPY);
}

fn paintSidebar(self: *SettingsWindow, hdc: w32.HDC, f: layout.Frame, p: panel_theme.Panel) void {
    fillRect(hdc, f.sidebar, cr(p.header));
    self.paintField(hdc, p, f.search, self.search.text(), "Search", self.focus == .search and w32.GetFocus() == self.hwnd, self.search.caret, false, false);
    if (self.search.len > 0) {
        const glyph = "\u{2715}";
        const box: Rect = .{ .x = f.search.x + f.search.w - f.search.h, .y = f.search.y, .w = f.search.h, .h = f.search.h };
        const gw = self.text.measure(hdc, glyph, .{}, .caption).cx;
        const ch = self.text.lineHeight(.caption);
        _ = self.text.drawText(hdc, box.x + @divTrunc(box.w - gw, 2), box.y + @divTrunc(box.h - ch, 2), glyph, .{}, .caption, cr(p.secondary), true);
        self.hit(.{ .rect = box, .kind = .search_clear });
    }

    const g = layout.px(dip.gap, self.scale);
    const radius = layout.px(dip.radius, self.scale);
    for (pages, 0..) |page, i| {
        const r = layout.pageRow(self.scale, f, i);
        const selected = !self.searching() and page.id == self.page;
        if (selected) roundRect(hdc, r, radius, cr(p.select), null, 1);
        const icon = layout.px(dip.page_icon, self.scale);
        const tile: Rect = .{ .x = r.x + g, .y = r.y + @divTrunc(r.h - icon, 2), .w = icon, .h = icon };
        roundRect(hdc, tile, radius, cr(p.accent), null, 1);
        const gw = self.text.measure(hdc, page.glyph, .{ .bold = true }, .caption).cx;
        const ch = self.text.lineHeight(.caption);
        _ = self.text.drawText(hdc, tile.x + @divTrunc(tile.w - gw, 2), tile.y + @divTrunc(tile.h - ch, 2), page.glyph, .{ .bold = true }, .caption, cr(p.on_accent), true);
        const lh = self.text.lineHeight(.body);
        _ = self.text.drawText(hdc, tile.x + tile.w + g, r.y + @divTrunc(r.h - lh, 2), page.title, .{}, .body, if (selected) cr(p.text_on_select) else cr(p.text), true);
        const count = self.changedInFile();
        if (count > 0) {
            var nb: [16]u8 = undefined;
            const ns = std.fmt.bufPrint(&nb, "{d}", .{count}) catch "";
            const cw = self.text.measure(hdc, ns, .{}, .caption).cx;
            _ = self.text.drawText(hdc, r.x + r.w - g - cw, r.y + @divTrunc(r.h - ch, 2), ns, .{}, .caption, if (selected) cr(p.secondary_on_select) else cr(p.secondary), true);
        }
        self.hit(.{ .rect = r, .kind = .page, .index = i });
    }

    // "Settings are saved to" / the path / "Open Config File...".
    const foot = f.sidebar_footer;
    fillRect(hdc, .{ .x = foot.x, .y = foot.y, .w = foot.w, .h = self.hair() }, cr(p.divider));
    const ch = self.text.lineHeight(.caption);
    const t = layout.px(dip.tight, self.scale);
    var y = foot.y + g;
    _ = self.text.drawText(hdc, foot.x, y, "Settings are saved to", .{}, .caption, cr(p.secondary), true);
    y += ch + t;
    self.text.drawEllipsized(hdc, .{ .x = foot.x, .y = y, .w = foot.w, .h = ch }, self.display_path, .{ .code = true }, .caption, cr(p.secondary), true);
    y += ch + t;
    const link = "Open Config File\u{2026}";
    const lw = self.text.drawText(hdc, foot.x, y, link, .{}, .caption, cr(p.accent), true);
    self.hit(.{ .rect = .{ .x = foot.x, .y = y, .w = lw, .h = ch }, .kind = .config_link });
}

fn paintTitle(self: *SettingsWindow, hdc: w32.HDC, f: layout.Frame, p: panel_theme.Panel) void {
    const title = if (self.searching()) "Search" else pageInfo(self.page).title;
    const lh = self.text.lineHeight(.version);
    _ = self.text.drawText(hdc, f.title.x, f.title.y + @divTrunc(f.title.h - lh, 2), title, .{}, .version, cr(p.text), true);
    if (f.filter.h == 0) return;

    // "All Settings" and its All N / Changed segmented control.
    const band = f.filter;
    const sh = self.text.lineHeight(.strong);
    _ = self.text.drawText(hdc, band.x, band.y + @divTrunc(band.h - sh, 2), "All Settings", .{}, .strong, cr(p.text), true);
    const seg_h = layout.px(dip.filter_h, self.scale);
    const pad = layout.px(dip.filter_pad_x, self.scale);
    const radius = layout.px(dip.radius, self.scale);
    var all_buf: [32]u8 = undefined;
    const all_label = std.fmt.bufPrint(&all_buf, "All {d}", .{self.catalog.entries.len}) catch "All";
    const labels = [_][]const u8{ all_label, "Changed" };
    const values = [_]Filter{ .all, .changed };
    var widths: [2]i32 = undefined;
    var total: i32 = 0;
    for (labels, 0..) |l, i| {
        widths[i] = self.text.measure(hdc, l, .{}, .caption).cx + 2 * pad;
        total += widths[i];
    }
    var x = band.x + band.w - total;
    const y = band.y + @divTrunc(band.h - seg_h, 2);
    roundRect(hdc, .{ .x = x, .y = y, .w = total, .h = seg_h }, radius, cr(p.field), cr(p.boundary), self.hair());
    const ch = self.text.lineHeight(.caption);
    for (labels, 0..) |l, i| {
        const r: Rect = .{ .x = x, .y = y, .w = widths[i], .h = seg_h };
        const on = self.filter == values[i];
        if (on) roundRect(hdc, r, radius, cr(p.select), cr(p.boundary), self.hair());
        _ = self.text.drawText(hdc, r.x + pad, r.y + @divTrunc(seg_h - ch, 2), l, .{ .bold = on }, .caption, if (on) cr(p.text_on_select) else cr(p.text), true);
        self.hit(.{ .rect = r, .kind = .filter, .index = i });
        x += widths[i];
    }
}

fn pageInfo(id: PageId) PageInfo {
    for (pages) |pg| if (pg.id == id) return pg;
    return pages[0];
}

fn paintList(self: *SettingsWindow, hdc: w32.HDC, f: layout.Frame, p: panel_theme.Panel) void {
    const view = f.list;
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    _ = w32.IntersectClipRect(hdc, view.x, view.y, view.x + view.w, view.y + view.h);
    const m = layout.px(dip.margin, self.scale);
    for (self.items) |it| {
        const y = view.y + it.y - self.scroll;
        if (y + it.h < view.y or y > view.y + view.h) continue;
        switch (it.kind) {
            .row => _ = self.paintRow(hdc, p, it, y, true),
            .header => {
                var buf: [96]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "Advanced \u{203A} All settings ({d})", .{self.matched}) catch "";
                const lh = self.text.lineHeight(.strong);
                _ = self.text.drawText(hdc, view.x + m, y + it.h - layout.px(dip.gap, self.scale) - lh, label, .{}, .strong, cr(p.text), true);
            },
            .more => {
                var buf: [96]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{d} more \u{2014} keep typing to narrow.", .{self.matched - self.listed.len}) catch "";
                const ch = self.text.lineHeight(.caption);
                _ = self.text.drawText(hdc, view.x + m, y + @divTrunc(it.h - ch, 2), label, .{}, .caption, cr(p.secondary), true);
            },
            .empty => {
                var buf: [LineEdit.capacity + 64]u8 = undefined;
                const msg = if (self.searching())
                    std.fmt.bufPrint(&buf, "No settings match \u{201C}{s}\u{201D}.", .{self.query()}) catch "No settings match."
                else
                    "No settings match.";
                const lh = self.text.lineHeight(.body);
                self.text.drawEllipsized(hdc, .{ .x = view.x + m, .y = y + @divTrunc(it.h - lh, 2), .w = view.w - 2 * m, .h = lh }, msg, .{}, .body, cr(p.secondary), false);
            },
        }
    }
    if (layout.thumb(self.scale, f.scrollbar, self.content_h, self.scroll)) |t| {
        roundRect(hdc, t, @divTrunc(t.w, 2), cr(p.boundary), null, 1);
    }
}

/// Paint (or, with `draw` false, only measure) one setting row whose top is
/// `y`; returns its height. Layout and paint share this so they cannot drift.
fn paintRow(self: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, item: Item, y: i32, draw: bool) i32 {
    const key = item.key;
    const r = self.reader() orelse return 0;
    const entry = self.catalog.get(key);
    const repeatable = if (entry) |e| e.repeatable else false;
    const override = self.overridingSource(key);
    const f = self.frame();
    const g = layout.px(dip.gap, self.scale);
    const t = layout.px(dip.tight, self.scale);
    const pad_y = layout.px(dip.row_pad_y, self.scale);
    const lh = self.text.lineHeight(.body);
    const ch = self.text.lineHeight(.caption);
    const fh = layout.px(dip.field_h, self.scale);
    const band = @max(lh, fh);
    const cols = layout.rowColumns(self.scale, f.list, f.scrollbar.w, y + pad_y, lh, if (repeatable) dip.list_w else dip.field_w);
    const width = cols.right - cols.left;
    const hovered = self.hover_key != null and std.mem.eql(u8, self.hover_key.?, key);
    const editing = self.edit_key != null and std.mem.eql(u8, self.edit_key.?, key);

    var cy = y + pad_y;
    if (draw) {
        // Line 1: the key, the changed dot, the doc button, Reset.
        const ky = cy + @divTrunc(band - lh, 2);
        var x = cols.left;
        x += self.text.drawText(hdc, x, ky, key, .{ .code = true }, .body, cr(p.text), true) + g;
        if (r.isModified(key)) {
            const d = layout.px(dip.dot, self.scale);
            roundRect(hdc, .{ .x = x, .y = cy + @divTrunc(band - d, 2), .w = d, .h = d }, @divTrunc(d, 2), cr(p.accent), null, 1);
            x += d + g;
        }
        const icon = layout.px(dip.icon_hit, self.scale);
        const shown = self.doc_key != null and std.mem.eql(u8, self.doc_key.?, key);
        x += self.iconButton(hdc, x, cy, band, icon, "\u{24D8}", if (shown) cr(p.accent) else cr(p.secondary), .info, key);
        // Mac shows Reset on hover; it is also shown while the row is edited.
        if (r.isSetInFile(key) and (hovered or editing)) {
            _ = self.iconButton(hdc, x, cy, band, icon, "\u{21BA}", cr(p.accent), .reset, key);
        }

        // The control.
        if (repeatable) {
            self.paintValueList(hdc, p, key, cols.control, editing);
        } else {
            const value = r.value(key);
            const placeholder = if (entry) |e| (if (e.value().len == 0) "unset" else e.value()) else "unset";
            const text = if (editing) self.field.text() else value;
            self.paintField(hdc, p, cols.control, text, placeholder, editing and w32.GetFocus() == self.hwnd, if (editing) self.field.caret else text.len, true, override != null);
            if (override == null) self.hit(.{ .rect = cols.control, .kind = .field, .key = key });
        }
    }
    cy += band;

    // The doc summary.
    if (item.summary.len > 0) {
        cy += t;
        if (draw) self.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = width, .h = ch }, item.summary, .{}, .caption, cr(p.secondary), false);
        cy += ch;
    }

    // A repeatable key's values in effect.
    if (repeatable) {
        const vals = r.values(self.gpa, key) catch &.{};
        defer self.gpa.free(vals);
        if (vals.len > 0) {
            cy += t;
            if (draw) {
                var buf: [480]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                const wr = fbs.writer();
                wr.writeAll("In effect: ") catch {};
                for (vals[0..@min(vals.len, 4)], 0..) |v, i| {
                    if (i > 0) wr.writeAll("  \u{00B7}  ") catch {};
                    wr.writeAll(v) catch {};
                }
                if (vals.len > 4) wr.print("  \u{00B7}  \u{2026} ({d})", .{vals.len}) catch {};
                self.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = width, .h = ch }, fbs.getWritten(), .{ .code = true }, .caption, cr(p.secondary), false);
            }
            cy += ch;
        }
    }

    // A later include sets it: read-only, with an Open link.
    if (override) |src| {
        cy += t;
        if (draw) {
            var buf: [512]u8 = undefined;
            const note = std.fmt.bufPrint(&buf, "\u{21AA} Set in {s}, which loads after your config.", .{src.name()}) catch "";
            const nw = self.text.drawText(hdc, cols.left, cy, note, .{}, .caption, cr(p.warn), true);
            const ow = self.text.drawText(hdc, cols.left + nw + g, cy, "Open", .{}, .caption, cr(p.accent), true);
            self.hit(.{ .rect = .{ .x = cols.left + nw + g, .y = cy, .w = ow, .h = ch }, .kind = .open, .key = key });
        }
        cy += ch;
    }

    // The model refused the last value.
    if (self.model.problem(key)) |problem| {
        cy += t;
        if (draw) {
            var buf: [512]u8 = undefined;
            const note = std.fmt.bufPrint(&buf, "\u{26A0} {s} \u{2014} not saved.", .{problem}) catch problem;
            self.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = width, .h = ch }, note, .{}, .caption, cr(p.bad), false);
        }
        cy += ch;
    }

    // The full documentation, on demand.
    if (self.doc_key != null and std.mem.eql(u8, self.doc_key.?, key)) {
        if (entry) |e| if (e.doc) |doc| {
            cy += g;
            cy += self.paintDoc(hdc, cols.left, cy, width, doc, cr(p.text), draw);
        };
    }

    cy += pad_y;
    if (draw) fillRect(hdc, .{ .x = cols.left, .y = cy - self.hair(), .w = width, .h = self.hair() }, cr(p.divider));
    return cy - y;
}

/// The full documentation as Mac's doc popover reads it: paragraphs stay
/// paragraphs, a bullet starts its own line, and an indented example keeps
/// its own block - the doc comments are hard-wrapped, so lines inside a
/// block are rejoined before wrapping to the row. Returns the height.
fn paintDoc(self: *SettingsWindow, hdc: w32.HDC, x: i32, top: i32, width: i32, doc: []const u8, color: u32, draw: bool) i32 {
    var block: std.ArrayListUnmanaged(u8) = .empty;
    defer block.deinit(self.gpa);
    const g = layout.px(dip.gap, self.scale);
    const t = layout.px(dip.tight, self.scale);
    var y = top;
    var in_bullet = false;
    var pending_gap: i32 = 0;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (true) {
        const raw = lines.next();
        const line = if (raw) |l| std.mem.trimRight(u8, l, " \t\r") else "";
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        const indent = line.len - trimmed.len;
        const bullet = std.mem.startsWith(u8, trimmed, "* ") or std.mem.startsWith(u8, trimmed, "- ");
        const example = !in_bullet and indent >= 4 and trimmed.len > 0;
        const breaks = raw == null or trimmed.len == 0 or bullet or example or (in_bullet and indent == 0);
        if (breaks and block.items.len > 0) {
            y += pending_gap;
            y += self.text.drawWrapped(hdc, x, y, width, block.items, .{}, .caption, color, draw);
            block.clearRetainingCapacity();
            pending_gap = t;
        }
        if (raw == null) break;
        if (trimmed.len == 0) {
            in_bullet = false;
            if (y > top) pending_gap = g;
            continue;
        }
        if (bullet) in_bullet = true else if (indent == 0) in_bullet = false;
        if (block.items.len > 0) block.append(self.gpa, ' ') catch {};
        if (bullet) {
            block.appendSlice(self.gpa, "\u{2022} ") catch {};
            block.appendSlice(self.gpa, trimmed[2..]) catch {};
        } else block.appendSlice(self.gpa, trimmed) catch {};
        // An example line is a block of its own, set in a little.
        if (example) {
            y += pending_gap;
            y += self.text.drawWrapped(hdc, x + g, y, width - g, block.items, .{}, .caption, color, draw);
            block.clearRetainingCapacity();
            pending_gap = t;
        }
    }
    return y - top;
}

fn iconButton(self: *SettingsWindow, hdc: w32.HDC, x: i32, top: i32, band: i32, size: i32, glyph: []const u8, color: u32, kind: Hit.Kind, key: []const u8) i32 {
    const r: Rect = .{ .x = x, .y = top + @divTrunc(band - size, 2), .w = size, .h = size };
    const gw = self.text.measure(hdc, glyph, .{}, .body).cx;
    const lh = self.text.lineHeight(.body);
    _ = self.text.drawText(hdc, r.x + @divTrunc(r.w - gw, 2), r.y + @divTrunc(r.h - lh, 2), glyph, .{}, .body, color, true);
    self.hit(.{ .rect = r, .kind = kind, .key = key });
    return size + layout.px(dip.tight, self.scale);
}

/// A text field: `text` (or the placeholder, dimmed), the caret when
/// focused, clipped to the box and scrolled so the caret stays in view.
fn paintField(self: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, r: Rect, text: []const u8, placeholder: []const u8, focused: bool, caret: usize, mono: bool, disabled: bool) void {
    const radius = layout.px(dip.radius, self.scale);
    const ring = if (focused) @max(2, layout.px(2, self.scale)) else self.hair();
    roundRect(hdc, r, radius, if (disabled) cr(p.bg) else cr(p.field), if (focused) cr(p.accent) else cr(p.boundary), ring);
    const pad = layout.px(dip.gap, self.scale);
    const style: @import("banner_markdown.zig").Style = .{ .code = mono };
    const lh = self.text.lineHeight(.body);
    const ty = r.y + @divTrunc(r.h - lh, 2);
    const inner = r.w - 2 * pad;
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    _ = w32.IntersectClipRect(hdc, r.x + ring, r.y + ring, r.x + r.w - ring, r.y + r.h - ring);
    const shown = clampUtf8(text, 400);
    const caret_at = @min(caret, shown.len);
    const caret_x = self.text.measure(hdc, shown[0..caret_at], style, .body).cx;
    const offset: i32 = if (focused) @max(0, caret_x - inner + 2) else 0;
    if (shown.len == 0) {
        if (!focused or placeholder.len > 0) _ = self.text.drawText(hdc, r.x + pad, ty, placeholder, style, .body, cr(p.secondary), true);
    } else {
        _ = self.text.drawText(hdc, r.x + pad - offset, ty, shown, style, .body, if (disabled) cr(p.secondary) else cr(p.text), true);
    }
    if (focused) {
        const cw: i32 = self.hair();
        fillRect(hdc, .{ .x = r.x + pad - offset + caret_x, .y = ty, .w = cw, .h = lh }, cr(p.text));
    }
}

/// A repeatable key's value list (Mac's `ListControl`): the user's file's
/// values as removable chips, then an "add a value" field.
fn paintValueList(self: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, key: []const u8, area: Rect, editing: bool) void {
    const override = self.overridingSource(key) != null;
    const add_w = @min(layout.px(dip.add_w, self.scale), area.w);
    const add: Rect = .{ .x = area.x + area.w - add_w, .y = area.y, .w = add_w, .h = area.h };
    self.paintField(hdc, p, add, if (editing) self.field.text() else "", "add a value", editing and w32.GetFocus() == self.hwnd, self.field.caret, true, override);
    if (!override) self.hit(.{ .rect = add, .kind = .add_field, .key = key });

    const vals = self.file.values(self.gpa, key) catch return;
    defer self.gpa.free(vals);
    const g = layout.px(dip.tight, self.scale);
    const chip_h = layout.px(dip.chip_h, self.scale);
    const cpad = layout.px(dip.chip_pad_x, self.scale);
    const ch = self.text.lineHeight(.caption);
    const radius = layout.px(dip.radius, self.scale);
    const x_glyph = "\u{2715}";
    const xw = self.text.measure(hdc, x_glyph, .{}, .caption).cx;
    var x = area.x;
    const limit = add.x - g;
    for (vals, 0..) |v, i| {
        const shown = clampUtf8(v, 120);
        const tw = self.text.measure(hdc, shown, .{ .code = true }, .caption).cx;
        const w = cpad + tw + g + xw + cpad;
        if (x + w > limit) {
            var buf: [16]u8 = undefined;
            const more = std.fmt.bufPrint(&buf, "+{d}", .{vals.len - i}) catch "";
            _ = self.text.drawText(hdc, x, area.y + @divTrunc(area.h - ch, 2), more, .{}, .caption, cr(p.secondary), true);
            break;
        }
        const chip: Rect = .{ .x = x, .y = area.y + @divTrunc(area.h - chip_h, 2), .w = w, .h = chip_h };
        roundRect(hdc, chip, radius, cr(p.card), cr(p.card_border), self.hair());
        const ty = chip.y + @divTrunc(chip_h - ch, 2);
        _ = self.text.drawText(hdc, chip.x + cpad, ty, shown, .{ .code = true }, .caption, cr(p.text), true);
        const xr: Rect = .{ .x = chip.x + cpad + tw + g, .y = chip.y, .w = xw + cpad, .h = chip_h };
        _ = self.text.drawText(hdc, xr.x, ty, x_glyph, .{}, .caption, cr(p.secondary), true);
        if (!override) self.hit(.{ .rect = xr, .kind = .chip_remove, .key = key, .index = i });
        x += w + g;
    }
}

/// At most `max` bytes of `s`, cut at a codepoint boundary.
fn clampUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

// ---------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------

fn hitAt(self: *const SettingsWindow, x: i32, y: i32) ?Hit {
    // The list's hits are only live inside the list's viewport.
    const f = self.frame();
    var i = self.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = self.hits.items[i];
        if (!h.rect.contains(x, y)) continue;
        const in_list = switch (h.kind) {
            .field, .add_field, .reset, .info, .open, .chip_remove => true,
            else => false,
        };
        if (in_list and !f.list.contains(x, y)) continue;
        return h;
    }
    return null;
}

fn rowAt(self: *const SettingsWindow, x: i32, y: i32) ?[]const u8 {
    const view = self.frame().list;
    if (!view.contains(x, y)) return null;
    const cy = y - view.y + self.scroll;
    for (self.items) |it| {
        if (it.kind == .row and cy >= it.y and cy < it.y + it.h) return it.key;
    }
    return null;
}

fn onLeftDown(self: *SettingsWindow, x: i32, y: i32) void {
    const f = self.frame();
    if (self.hitAt(x, y)) |h| {
        switch (h.kind) {
            .page => self.setPage(pages[h.index].id),
            .filter => self.setFilter(if (h.index == 0) .all else .changed),
            .config_link => {
                self.commitEdit();
                self.app.openConfigFile();
            },
            .search_clear => self.setQuery(""),
            .field, .add_field => _ = self.beginEdit(h.key),
            .reset => _ = self.resetKey(h.key),
            .info => self.toggleDoc(h.key),
            .open => self.openOverridingFile(h.key),
            .chip_remove => _ = self.removeValue(h.key, h.index),
        }
        return;
    }
    if (f.search.contains(x, y)) {
        self.commitEdit();
        self.focus = .search;
        self.invalidate();
        return;
    }
    if (layout.thumb(self.scale, f.scrollbar, self.content_h, self.scroll)) |t| {
        if (t.contains(x, y)) {
            self.thumb_drag_dy = y - t.y;
            _ = w32.SetCapture(self.hwnd);
            return;
        }
        if (f.scrollbar.contains(x, y)) {
            self.scrollBy(if (y < t.y) -f.list.h else f.list.h);
            return;
        }
    }
    // Anywhere else commits the field, the way losing focus does on Mac.
    self.commitEdit();
}

fn onMouseMove(self: *SettingsWindow, x: i32, y: i32) void {
    if (self.thumb_drag_dy >= 0) {
        const f = self.frame();
        const t = layout.thumb(self.scale, f.scrollbar, self.content_h, self.scroll) orelse return;
        const travel = @max(1, f.scrollbar.h - t.h);
        const want = y - self.thumb_drag_dy - f.scrollbar.y;
        const max_scroll = @max(0, self.content_h - f.list.h);
        self.scroll = layout.clampScroll(@divTrunc(want * max_scroll, travel), self.content_h, f.list.h);
        self.invalidate();
        return;
    }
    if (!self.tracking_leave) {
        var tme: w32.TRACKMOUSEEVENT = .{ .cbSize = @sizeOf(w32.TRACKMOUSEEVENT), .dwFlags = w32.TME_LEAVE, .hwndTrack = self.hwnd, .dwHoverTime = 0 };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_leave = true;
    }
    const over = self.rowAt(x, y);
    const changed = if (over) |o| (self.hover_key == null or !std.mem.eql(u8, o, self.hover_key.?)) else self.hover_key != null;
    if (changed) {
        self.hover_key = over;
        self.invalidate();
    }
    const h = self.hitAt(x, y);
    const cursor = if (h) |hh| switch (hh.kind) {
        .field, .add_field => w32.IDC_IBEAM,
        else => w32.IDC_HAND,
    } else if (self.frame().search.contains(x, y)) w32.IDC_IBEAM else w32.IDC_ARROW;
    _ = w32.SetCursor(w32.LoadCursorW(null, cursor));
}

fn editor(self: *SettingsWindow) *LineEdit {
    return if (self.focus == .field and self.edit_key != null) &self.field else &self.search;
}

fn edited(self: *SettingsWindow) void {
    if (self.focus == .search) {
        self.scroll = 0;
        self.refresh();
    } else self.invalidate();
}

fn onKey(self: *SettingsWindow, vk: u16) bool {
    const ctrl = w32.GetKeyState(w32.VK_CONTROL) < 0;
    const e = self.editor();
    switch (vk) {
        w32.VK_ESCAPE => {
            if (self.edit_key != null) {
                self.cancelEdit();
            } else if (self.search.len > 0) {
                self.setQuery("");
            } else {
                self.close();
            }
        },
        w32.VK_RETURN => {
            if (self.edit_key != null) self.commitEdit();
        },
        w32.VK_TAB => {
            // Tab leaves a field the way a click elsewhere does.
            if (self.edit_key != null) self.commitEdit() else return false;
        },
        w32.VK_LEFT => {
            e.left();
            self.invalidate();
        },
        w32.VK_RIGHT => {
            e.right();
            self.invalidate();
        },
        w32.VK_HOME => {
            if (ctrl and self.edit_key == null) self.scrollBy(-self.content_h) else {
                e.home();
                self.invalidate();
            }
        },
        w32.VK_END => {
            if (ctrl and self.edit_key == null) self.scrollBy(self.content_h) else {
                e.end();
                self.invalidate();
            }
        },
        w32.VK_DELETE => {
            if (e.delete()) self.edited();
        },
        w32.VK_DOWN => self.scrollBy(layout.px(dip.wheel_step, self.scale)),
        w32.VK_UP => self.scrollBy(-layout.px(dip.wheel_step, self.scale)),
        w32.VK_NEXT => self.scrollBy(self.frame().list.h),
        w32.VK_PRIOR => self.scrollBy(-self.frame().list.h),
        else => return false,
    }
    return true;
}

fn onChar(self: *SettingsWindow, ch: u16) void {
    const e = self.editor();
    const changed = switch (ch) {
        0x08 => e.backspace(),
        0x7F => e.backspaceWord(),
        0x16 => self.pasteClipboard(e),
        // Enter, Tab and Esc are handled in WM_KEYDOWN.
        0x0D, 0x09, 0x1B => false,
        else => if (ch < 0x20) false else e.insertUnit(ch),
    };
    if (changed) self.edited();
}

fn pasteClipboard(self: *SettingsWindow, e: *LineEdit) bool {
    if (w32.OpenClipboard(self.hwnd) == 0) return false;
    defer _ = w32.CloseClipboard();
    const hmem = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return false;
    const ptr = w32.GlobalLock(hmem) orelse return false;
    defer _ = w32.GlobalUnlock(hmem);
    const wide: [*:0]const u16 = @ptrCast(@alignCast(ptr));
    const utf8 = std.unicode.utf16LeToUtf8Alloc(self.gpa, std.mem.sliceTo(wide, 0)) catch return false;
    defer self.gpa.free(utf8);
    return e.insert(utf8);
}

// ---------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *SettingsWindow = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_ERASEBKGND => return 1,
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            self.paint(hdc);
            _ = w32.EndPaint(hwnd, &ps);
            return 0;
        },
        // The same pixels into a caller's DC, so a probe photographs this
        // window synchronously (T835).
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            self.paint(@ptrFromInt(wparam));
            return 0;
        },
        w32.WM_SIZE => {
            // Row heights depend on the width (the full doc wraps).
            self.layoutItems();
            self.scroll = layout.clampScroll(self.scroll, self.content_h, self.frame().list.h);
            self.invalidate();
            return 0;
        },
        w32.WM_SETFOCUS => {
            self.invalidate();
            return 0;
        },
        w32.WM_KILLFOCUS => {
            // Losing focus commits the field (Mac's `onChange(of: focused)`).
            self.commitEdit();
            self.invalidate();
            return 0;
        },
        w32.WM_GETMINMAXINFO => {
            const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const min = layout.minSize(self.scale);
            var fr: w32.RECT = .{ .left = 0, .top = 0, .right = min.w, .bottom = min.h };
            _ = w32.AdjustWindowRectEx(&fr, w32.WS_OVERLAPPEDWINDOW, 0, 0);
            mmi.ptMinTrackSize = .{ .x = fr.right - fr.left, .y = fr.bottom - fr.top };
            return 0;
        },
        w32.WM_DPICHANGED => {
            self.scale = @as(f32, @floatFromInt(@as(u16, @intCast(wparam & 0xFFFF)))) / 96.0;
            const s: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = w32.SetWindowPos(hwnd, null, s.left, s.top, s.right - s.left, s.bottom - s.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
            self.text.setScale(self.scale);
            self.layoutItems();
            self.invalidate();
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
            const notches = @divTrunc(@as(i32, delta), w32.WHEEL_DELTA);
            self.scrollBy(-notches * layout.px(dip.wheel_step, self.scale));
            return 0;
        },
        w32.WM_LBUTTONDOWN, w32.WM_LBUTTONDBLCLK => {
            _ = w32.SetFocus(hwnd);
            self.onLeftDown(loWordSigned(lparam), hiWordSigned(lparam));
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (self.thumb_drag_dy >= 0) {
                self.thumb_drag_dy = -1;
                _ = w32.ReleaseCapture();
            }
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            self.onMouseMove(loWordSigned(lparam), hiWordSigned(lparam));
            return 0;
        },
        w32.WM_SETCURSOR => {
            // The arrow/beam/hand is set on every mouse move.
            if ((@as(usize, @bitCast(lparam)) & 0xFFFF) == w32.HTCLIENT) return 1;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            if (self.hover_key != null) {
                self.hover_key = null;
                self.invalidate();
            }
            return 0;
        },
        w32.WM_KEYDOWN => {
            if (self.onKey(@intCast(wparam & 0xFFFF))) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CHAR => {
            self.onChar(@intCast(wparam & 0xFFFF));
            return 0;
        },
        w32.WM_SETTINGCHANGE => {
            system_colors.applyPanelChrome(hwnd, self.pal());
            self.invalidate();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CLOSE => {
            self.close();
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn loWordSigned(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast(@as(usize, @bitCast(lparam)) & 0xFFFF))));
}

fn hiWordSigned(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
}
