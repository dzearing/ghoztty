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
//! Pages: the curated pages (`settings_pages.zig`, T2585) - Panes &
//! Windows, Terminal, Keyboard, Sessions & Agent, Remote Machines, Updates -
//! list their keys with Mac's labels and controls (an on/off switch, a value
//! popup, or the value as text); Advanced > All Settings lists every schema
//! key (`SettingsSources.Reader.allSettings`), with the All / Changed / Not
//! on other pages filter and a "<Page> >" link on each curated key. Search
//! lists curated rows first, under "<Page> > <Section>", then the keys no
//! page shows. Advanced opens with Mac's Config file section (T2676,
//! `settings_advanced_view.zig`): the file with Open in Editor / Show in
//! Explorer, every other file Ghostty loads with Open, Backups with
//! Restore..., and the Current file disclosure. Every write raises the
//! "Saved - Show Change - Undo" toast over the foot of the form. Appearance
//! is its own task.
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
const settings_pages = @import("settings_pages.zig");
const settings_advanced = @import("settings_advanced.zig");
const settings_live = @import("settings_live.zig");
const advanced_view = @import("settings_advanced_view.zig");
const banner_link = @import("banner_link.zig");
const theme_catalog = @import("theme_catalog.zig");
const settings_theme = @import("settings_theme.zig");
const controls = @import("settings_controls.zig");
const folder_dialog = @import("folder_dialog.zig");
const ShortcutGuideWindow = @import("ShortcutGuideWindow.zig");
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

pub const PageId = settings_pages.PageId;

/// The sidebar, in order.
pub const pages = settings_pages.all;

pub const Filter = Reader.Filter;

/// One laid-out line of the form.
const Item = struct {
    y: i32,
    h: i32,
    kind: Kind,
    /// Catalog-owned (rows), so it survives every reload.
    key: []const u8 = "",
    summary: []const u8 = "",
    /// The curated row this line draws (null: a raw All Settings row).
    row: ?*const settings_pages.Row = null,
    /// A header's text (view-arena owned).
    title: []const u8 = "",
    custom: settings_pages.Custom = .all_settings,

    const Kind = enum { header, row, custom, more, empty };
};

/// A clickable region recorded by the last paint.
pub const Hit = struct {
    rect: Rect,
    kind: Kind,
    key: []const u8 = "",
    index: usize = 0,

    pub const Kind = enum {
        page,
        filter,
        config_link,
        search_clear,
        field,
        add_field,
        reset,
        info,
        open,
        chip_remove,
        toggle,
        choice,
        reveal,
        guide_link,
        // The live sections (T2680).
        check_updates,
        pane_style,
        // Advanced > Config file (T2676).
        open_editor,
        reveal_file,
        open_source,
        restore_menu,
        show_file,
        // The change toast (T2676).
        toast_body,
        toast_show,
        toast_undo,
        toast_dismiss,
        // Appearance > Theme (T2586).
        theme_mode,
        theme_slot,
        // The curated controls (T2681): a slider's track, a stepper's
        // arrows, a color well and its "Use <default>" link, and one flag's
        // checkbox (`index` = the flag's schema position).
        slider,
        step_up,
        step_down,
        color_well,
        color_reset,
        flag,
    };
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
/// The themes the `theme` key can name, read on first use (Mac
/// `ThemeCatalog.shared`); kept for the window's life.
themes: ?theme_catalog.Catalog = null,
/// True while a model write runs: the reload it triggers re-enters through
/// `configChanged`, and the window refreshes once the write returns instead.
in_write: bool = false,

// Advanced > Config file (T2676), re-read with the rest on every reload.
/// Where `main_path` links to, as the section shows it, when it is a link.
target_display: ?[]u8 = null,
/// The files Ghostty loads besides the user's (point into `sources`).
others: []const *const SettingsSources.Source = &.{},
/// This config's backups, newest first.
backup_list: [][]u8 = &.{},
/// The Current file disclosure is open.
show_file: bool = false,

// The change toast (T2676).
/// The model's `change_seq` the toast was last started for.
toast_seq: u64 = 0,
toast_expanded: bool = false,
/// The last Undo was refused because the file changed since.
toast_refused: bool = false,
toast_ms: u32 = settings_advanced.toast_ms,
/// Debug builds: `GHOZTTY_SETTINGS_SHELL_DRY` records what an Open / Show
/// in Explorer would launch here instead of launching it (the seam's).
last_shell: ?[]u8 = null,

// The live sections (T2680), re-read on every refresh - never by dialing or
// spawning the agent.
live_agent: settings_live.Agent = .{},
live_pipe_buf: [256]u8 = undefined,
live_build_buf: [96]u8 = undefined,

// What the form shows.
page: PageId = .appearance,
filter: Filter = .all,
search: LineEdit = .{},
/// Owns `items`, the listed keys and their summaries (rebuilt per refresh).
view_arena: std.heap.ArenaAllocator,
items: []const Item = &.{},
/// Uncurated rows that matched before the search cap (= the keys listed
/// on Advanced).
matched: usize = 0,
/// Curated rows a search found (listed above the uncurated block).
curated_hits: usize = 0,
/// The un-laid-out lines `refresh` planned (view-arena owned).
plan: []const Item = &.{},
listed: []const []const u8 = &.{},
/// The row whose full documentation is shown.
doc_key: ?[]const u8 = null,
/// The row the last "<Page> >" link revealed (drawn highlighted until the
/// next page change).
revealed_key: ?[]const u8 = null,

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
/// A slider being dragged (T2681): its key, its track, and the value it
/// previews; Mac's slider writes once, on release.
slide_key: ?[]const u8 = null,
slide_track: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
slide_preview: ?f64 = null,

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
    if (self.target_display) |t| gpa.free(t);
    gpa.free(self.others);
    freePaths(gpa, self.backup_list);
    if (self.last_shell) |l| gpa.free(l);
    self.model.deinit();
    self.store.deinit();
    if (self.sources) |*s| s.deinit();
    if (self.effective) |*e| e.deinit();
    self.catalog.deinit();
    if (self.themes) |*t| t.deinit();
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

    self.reloadConfigFileSection();
}

/// The Config file section's own reads: where the file links to, the other
/// files, and the backups.
fn reloadConfigFileSection(self: *SettingsWindow) void {
    const gpa = self.gpa;
    if (self.target_display) |t| gpa.free(t);
    self.target_display = null;
    if (self.store.targetPath(gpa)) |target| {
        defer gpa.free(target);
        if (!settings_advanced.samePath(target, self.main_path)) self.target_display = displayPath(gpa, target) catch null;
    } else |_| {}

    gpa.free(self.others);
    self.others = &.{};
    if (self.sources) |*s| {
        const target = self.store.targetPath(gpa) catch null;
        defer if (target) |t| gpa.free(t);
        self.others = settings_advanced.otherSources(gpa, s, self.main_path, target orelse self.main_path) catch &.{};
    }

    if (self.store.backups(gpa)) |list| {
        freePaths(gpa, self.backup_list);
        self.backup_list = list;
    } else |err| log.warn("settings: listing backups failed err={}", .{err});
}

pub fn otherSources(self: *const SettingsWindow) []const *const SettingsSources.Source {
    return self.others;
}

pub fn backups(self: *const SettingsWindow) []const []const u8 {
    return @ptrCast(self.backup_list);
}

/// Run a model write: the reload it triggers is folded into one refresh
/// after it returns.
fn write(self: *SettingsWindow, comptime f: anytype, args: anytype) bool {
    self.in_write = true;
    const ok = @call(.auto, f, .{&self.model} ++ args) catch false;
    self.in_write = false;
    self.reloadData();
    self.noteChange();
    self.refresh();
    return ok;
}

/// A write recorded a new change: raise the toast for it (Mac restarts its
/// six-second timer per change, collapsed).
fn noteChange(self: *SettingsWindow) void {
    if (self.model.last_change == null or self.model.change_seq == self.toast_seq) return;
    self.toast_seq = self.model.change_seq;
    self.toast_expanded = false;
    self.toast_refused = false;
    if (self.isWindow()) _ = w32.SetTimer(self.hwnd, toast_timer_id, self.toast_ms, null);
}

/// The toast's timer, on this window's own hwnd (not `App.msg_hwnd`).
const toast_timer_id: usize = 1;

fn onToastTimer(self: *SettingsWindow) void {
    _ = w32.KillTimer(self.hwnd, toast_timer_id);
    // Mac keeps an expanded toast up until it is dismissed.
    if (self.toast_expanded or self.model.last_change == null) return;
    self.dismissToast();
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

/// The sidebar's count for a page (Mac `changedCount`): the page's keys the
/// user's file sets, or for Advanced every file key no curated page shows.
pub fn changedOn(self: *const SettingsWindow, id: PageId) usize {
    const r = self.reader() orelse return 0;
    var n: usize = 0;
    if (id == .advanced) {
        for (self.catalog.entries) |*e| {
            if (!settings_pages.isCurated(e.key) and r.isSetInFile(e.key)) n += 1;
        }
        return n;
    }
    for (settings_pages.page(id).sections) |sec| for (sec.rows) |row| {
        if (r.isSetInFile(row.key)) n += 1;
    };
    return n;
}

/// How many keys the user's file sets, on any page.
pub fn changedInFile(self: *const SettingsWindow) usize {
    const r = self.reader() orelse return 0;
    var n: usize = 0;
    for (self.catalog.entries) |*e| {
        if (r.isSetInFile(e.key)) n += 1;
    }
    return n;
}

/// Take the agent snapshot Sessions & Agent paints (Mac
/// `AgentStatusModel.refresh`): the info file's live pid, then the build the
/// shared connection already reported. Never dials, never spawns.
fn snapLive(self: *SettingsWindow) void {
    const la = &self.app.local_agent;
    var a: settings_live.Agent = .{ .bundled_build = la.bundledVersionIfProbed() };
    if (la.liveStatus(&self.live_pipe_buf)) |st| {
        a.running = true;
        a.pid = st.pid;
        a.pipe = st.pipe;
        if (la.runningVersion()) |v| {
            const n = @min(v.len, self.live_build_buf.len);
            @memcpy(self.live_build_buf[0..n], v[0..n]);
            a.running_build = self.live_build_buf[0..n];
        }
    }
    self.live_agent = a;
}

/// The Updates section's Check for Updates... (Mac `checkForUpdates`): the
/// same manual check the command palette runs; its answer is the app's own
/// update notification.
pub fn checkForUpdates(self: *SettingsWindow) void {
    self.commitEdit();
    self.app.startUpdateCheck(.manual);
    self.refresh();
}

/// Re-filter and re-lay-out the form.
fn refresh(self: *SettingsWindow) void {
    self.snapLive();
    _ = self.view_arena.reset(.retain_capacity);
    const arena = self.view_arena.allocator();
    self.listed = &.{};
    self.plan = &.{};
    self.matched = 0;
    self.curated_hits = 0;
    var plan: std.ArrayList(Item) = .empty;
    var keys: std.ArrayList([]const u8) = .empty;
    if (self.reader()) |r| {
        if (self.searching()) {
            self.planSearch(arena, r, &plan, &keys) catch {};
        } else if (self.page == .advanced) {
            // Mac's Advanced: "Config file", then All settings (its title and
            // filter scroll with the list, under the section above them).
            plan.append(arena, .{ .y = 0, .h = 0, .kind = .header, .title = "Config file" }) catch {};
            plan.append(arena, .{ .y = 0, .h = 0, .kind = .custom, .custom = .config_file }) catch {};
            plan.append(arena, .{ .y = 0, .h = 0, .kind = .custom, .custom = .all_settings }) catch {};
            const listed = r.allSettings(arena, self.filter, "") catch &.{};
            self.matched = listed.len;
            for (listed) |k| self.planRaw(arena, &plan, &keys, k) catch break;
            if (listed.len == 0) plan.append(arena, .{ .y = 0, .h = 0, .kind = .empty }) catch {};
        } else {
            self.planPage(arena, r, settings_pages.page(self.page), &plan, &keys) catch {};
        }
    }
    self.plan = plan.items;
    self.listed = keys.items;
    if (self.edit_key) |k| if (!contains(self.listed, k)) {
        self.edit_key = null;
        self.focus = .search;
    };
    self.layoutItems();
    self.scroll = layout.clampScroll(self.scroll, self.content_h, self.frame().list.h);
    self.invalidate();
}

fn planRaw(self: *SettingsWindow, arena: Allocator, plan: *std.ArrayList(Item), keys: *std.ArrayList([]const u8), key: []const u8) Allocator.Error!void {
    const doc = if (self.catalog.get(key)) |e| e.doc else null;
    try plan.append(arena, .{ .y = 0, .h = 0, .kind = .row, .key = key, .summary = try SettingsCatalog.summary(arena, doc) });
    try keys.append(arena, key);
}

fn planRow(self: *SettingsWindow, arena: Allocator, plan: *std.ArrayList(Item), keys: *std.ArrayList([]const u8), row: *const settings_pages.Row) Allocator.Error!void {
    // A key this build's schema lacks is skipped, never drawn half-made (the
    // drift test fails first on a real build).
    const key = self.catalogKey(row.key) orelse return;
    const summary = if (row.hint) |h| h else try SettingsCatalog.summary(arena, if (self.catalog.get(key)) |e| e.doc else null);
    try plan.append(arena, .{ .y = 0, .h = 0, .kind = .row, .key = key, .summary = summary, .row = row });
    try keys.append(arena, key);
}

fn planPage(self: *SettingsWindow, arena: Allocator, r: Reader, pg: *const settings_pages.Page, plan: *std.ArrayList(Item), keys: *std.ArrayList([]const u8)) Allocator.Error!void {
    _ = r;
    for (pg.sections) |*sec| {
        if (sec.title) |t| try plan.append(arena, .{ .y = 0, .h = 0, .kind = .header, .title = t });
        if (sec.custom) |c| try plan.append(arena, .{ .y = 0, .h = 0, .kind = .custom, .custom = c });
        for (sec.rows) |*row| try self.planRow(arena, plan, keys, row);
    }
}

/// Mac `searchResults`: curated rows first, each under "<Page> > <Section>",
/// with custom sections matching their own words; then every key no page
/// shows, capped at `search_cap`.
fn planSearch(self: *SettingsWindow, arena: Allocator, r: Reader, plan: *std.ArrayList(Item), keys: *std.ArrayList([]const u8)) Allocator.Error!void {
    const q = self.query();
    for (pages) |pg| {
        for (pg.sections) |*sec| {
            // Advanced's keys are the uncurated block below; only its
            // Config file section is searched here.
            if (pg.id == .advanced and sec.custom != .config_file) continue;
            const heading = if (sec.title) |t|
                try std.fmt.allocPrint(arena, "{s} \u{203A} {s}", .{ pg.title, t })
            else
                pg.title;
            if (sec.custom) |c| {
                const words = c.searchText();
                if (SettingsCatalog.containsIgnoreCase(words, q) or
                    (sec.title != null and SettingsCatalog.containsIgnoreCase(sec.title.?, q)))
                {
                    try plan.append(arena, .{ .y = 0, .h = 0, .kind = .header, .title = heading });
                    try plan.append(arena, .{ .y = 0, .h = 0, .kind = .custom, .custom = c });
                }
                continue;
            }
            var first = true;
            for (sec.rows) |*row| {
                if (self.catalog.get(row.key) == null) continue;
                if (!settings_pages.rowMatchesText(row, q) and !try r.matches(arena, row.key, q)) continue;
                if (first) try plan.append(arena, .{ .y = 0, .h = 0, .kind = .header, .title = heading });
                first = false;
                try self.planRow(arena, plan, keys, row);
                self.curated_hits += 1;
            }
        }
    }
    const uncurated = try r.allSettings(arena, .uncovered, q);
    self.matched = uncurated.len;
    if (uncurated.len > 0) {
        const heading = try std.fmt.allocPrint(arena, "Advanced \u{203A} All settings ({d})", .{uncurated.len});
        try plan.append(arena, .{ .y = 0, .h = 0, .kind = .header, .title = heading });
        for (uncurated[0..@min(uncurated.len, search_cap)]) |k| try self.planRaw(arena, plan, keys, k);
        if (uncurated.len > search_cap) try plan.append(arena, .{ .y = 0, .h = 0, .kind = .more });
    }
    if (plan.items.len == 0) try plan.append(arena, .{ .y = 0, .h = 0, .kind = .empty });
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

    for (self.plan) |planned| {
        var item = planned;
        item.y = y;
        item.h = switch (item.kind) {
            .header, .more => header_h,
            .empty => header_h * 2,
            .row => if (hdc) |dc| self.paintRow(dc, self.pal(), item, 0, false) else header_h,
            .custom => if (hdc) |dc| self.paintCustom(dc, self.pal(), item, 0, false) else header_h,
        };
        list.append(arena, item) catch break;
        y += item.h;
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
    self.revealed_key = null;
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
    if (repeatable) self.field.clear() else if (settings_pages.rowFor(k)) |row| switch (row.control) {
        // A stepper edits its number, the megabytes row its MB (Mac's
        // `NumberControl` / `MegabytesControl` fields).
        .stepper, .megabytes => {
            var buf: [64]u8 = undefined;
            self.field.set(self.controlDisplay(&buf, row));
        },
        // Shell's Other...: the command as it stands, or empty for the
        // default (Mac seeds its sheet with the value).
        .shell => self.field.set(if (r.isSetInFile(k)) r.value(k) else ""),
        else => self.field.set(r.value(k)),
    } else self.field.set(r.value(k));
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
    if (settings_pages.rowFor(key)) |row| if (self.commitControl(row, typed)) {
        self.invalidate();
        return;
    };
    if (std.mem.trim(u8, typed, " \t").len == 0) {
        if (r.isSetInFile(key)) _ = self.write(SettingsModel.reset, .{key});
    } else if (!std.mem.eql(u8, typed, r.value(key))) {
        _ = self.write(SettingsModel.set, .{ key, @as([]const u8, typed) });
    }
    self.invalidate();
}

/// A curated control's field commit (T2681): the stepper's range check, the
/// MB conversion, the shell's existence check. False for a row whose field
/// writes its text as typed. A refused value shows Mac's inline problem
/// and writes nothing (a refused shell keeps its field open, as Mac's sheet
/// stays up).
fn commitControl(self: *SettingsWindow, row: *const settings_pages.Row, typed: []const u8) bool {
    const key = row.key;
    const r = self.reader() orelse return true;
    const empty = std.mem.trim(u8, typed, " \t").len == 0;
    var buf: [128]u8 = undefined;
    var shown_buf: [64]u8 = undefined;
    switch (row.control) {
        .stepper => |s| {
            if (std.mem.eql(u8, typed, self.controlDisplay(&shown_buf, row))) return true;
            if (empty) {
                if (r.isSetInFile(key)) _ = self.write(SettingsModel.reset, .{key});
                return true;
            }
            const v = controls.parseInRange(typed, s.min, s.max) orelse return self.refuse(key, controls.rangeProblem(&buf, s.min, s.max));
            _ = self.chooseValue(key, controls.formatNumber(&buf, v));
            return true;
        },
        .megabytes => |m| {
            if (std.mem.eql(u8, typed, self.controlDisplay(&shown_buf, row))) return true;
            if (empty) {
                if (r.isSetInFile(key)) _ = self.write(SettingsModel.reset, .{key});
                return true;
            }
            const bytes = controls.megabytesToBytes(typed, m.max) orelse return self.refuse(key, controls.megabytesProblem(&buf, m.max));
            const text = std.fmt.bufPrint(&buf, "{d}", .{bytes}) catch return true;
            _ = self.chooseValue(key, text);
            return true;
        },
        .shell => {
            if (!self.chooseShell(key, typed)) {
                self.edit_key = key;
                self.focus = .field;
            }
            return true;
        },
        else => return false,
    }
}

/// Record `msg` as `key`'s problem; the field closes and shows the value
/// again (Mac's `NumberControl.commit` drops the typed text first).
fn refuse(self: *SettingsWindow, key: []const u8, msg: []const u8) bool {
    self.model.setProblem(key, msg) catch {};
    return true;
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

/// A curated switch: flips a bool key between true and false.
pub fn toggleKey(self: *SettingsWindow, key: []const u8) bool {
    const k = self.catalogKey(key) orelse return false;
    if (self.overridingSource(k) != null) return false;
    const r = self.reader() orelse return false;
    const on = std.mem.eql(u8, r.value(k), "true");
    self.commitEdit();
    return self.write(SettingsModel.set, .{ k, @as([]const u8, if (on) "false" else "true") });
}

/// A curated popup's pick. "" is "unset": the key leaves the user's file.
pub fn chooseValue(self: *SettingsWindow, key: []const u8, value: []const u8) bool {
    const k = self.catalogKey(key) orelse return false;
    if (self.overridingSource(k) != null) return false;
    const r = self.reader() orelse return false;
    self.commitEdit();
    if (value.len == 0) return if (r.isSetInFile(k)) self.write(SettingsModel.reset, .{k}) else true;
    if (r.isSetInFile(k) and std.mem.eql(u8, r.value(k), value)) return true;
    return self.write(SettingsModel.set, .{ k, value });
}

// ---------------------------------------------------------------------
// The curated controls (T2681) - Mac `SettingsRowView.swift`'s Slider,
// Number, Megabytes, Color, Flags, Shell and Folder controls. Each turns a
// gesture into the value text the parser accepts and writes it through
// `chooseValue`, so the model validates it like every other write.
// ---------------------------------------------------------------------

/// A curated row of `key` whose control is `tag`, if that is what it is.
fn controlRow(key: []const u8, comptime tag: std.meta.Tag(settings_pages.Control)) ?*const settings_pages.Row {
    const row = settings_pages.rowFor(key) orelse return null;
    return if (row.control == tag) row else null;
}

/// A slider's release: `value` snapped to the row's step and range.
pub fn slideTo(self: *SettingsWindow, key: []const u8, value: f64) bool {
    const row = controlRow(key, .slider) orelse return false;
    const s = row.control.slider;
    var buf: [32]u8 = undefined;
    return self.chooseValue(key, controls.formatValue(&buf, controls.snap(value, s.min, s.max, s.step)));
}

/// What a slider shows now: the value being dragged, else the key's.
pub fn sliderValue(self: *const SettingsWindow, row: *const settings_pages.Row) f64 {
    if (self.slide_key) |k| if (std.mem.eql(u8, k, row.key)) if (self.slide_preview) |v| return v;
    const r = self.reader() orelse return row.control.slider.min;
    return controls.parseOr(r.value(row.key), row.control.slider.min);
}

/// One click of a stepper's arrow (`dir` +1 up, -1 down).
pub fn stepKey(self: *SettingsWindow, key: []const u8, dir: i32) bool {
    const row = controlRow(key, .stepper) orelse return false;
    const s = row.control.stepper;
    const r = self.reader() orelse return false;
    const now = controls.parseOr(r.value(key), s.min);
    var buf: [64]u8 = undefined;
    return self.chooseValue(key, controls.formatNumber(&buf, controls.stepBy(now, dir, s.min, s.max, s.step)));
}

/// A flag's checkbox: every schema flag is written explicitly, as Mac's.
pub fn setFlag(self: *SettingsWindow, key: []const u8, flag: []const u8, on: bool) bool {
    _ = controlRow(key, .flags) orelse return false;
    const options = (self.catalog.get(key) orelse return false).options orelse return false;
    const r = self.reader() orelse return false;
    var known = false;
    for (options) |o| if (std.mem.eql(u8, o, flag)) {
        known = true;
    };
    if (!known) return false;
    const next = controls.composeFlags(self.gpa, options, r.value(key), flag, on) catch return false;
    defer self.gpa.free(next);
    return self.chooseValue(key, next);
}

/// The color well's pick, as `#rrggbb`.
pub fn applyColor(self: *SettingsWindow, key: []const u8, rgb: u32) bool {
    _ = controlRow(key, .color) orelse return false;
    var buf: [7]u8 = undefined;
    return self.chooseValue(key, controls.formatHex(&buf, rgb));
}

/// The color well: the system color dialog, starting on the key's color.
fn pickColor(self: *SettingsWindow, key: []const u8) void {
    const r = self.reader() orelse return;
    const start = controls.parseHex(r.value(key)) orelse 0x808080;
    const Static = struct {
        var custom: [16]u32 = [_]u32{0xFFFFFF} ** 16;
    };
    var cc: w32.CHOOSECOLORW = .{
        .hwndOwner = self.hwnd,
        .rgbResult = controls.toColorref(start),
        .lpCustColors = &Static.custom,
        .Flags = w32.CC_RGBINIT | w32.CC_FULLOPEN | w32.CC_ANYCOLOR,
    };
    if (w32.ChooseColorW(&cc) == 0) return;
    _ = self.applyColor(key, controls.fromColorref(cc.rgbResult));
}

/// A shell row's write (a menu pick, or Other...'s typed command): refused
/// with Mac's inline problem when its program does not exist.
pub fn chooseShell(self: *SettingsWindow, key: []const u8, command: []const u8) bool {
    _ = controlRow(key, .shell) orelse return false;
    const trimmed = std.mem.trim(u8, command, " \t");
    if (trimmed.len == 0) return self.chooseValue(key, "");
    var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    if (shellProblem(self.gpa, &buf, trimmed)) |problem| {
        self.model.setProblem(key, problem) catch {};
        self.invalidate();
        return false;
    }
    return self.chooseValue(key, trimmed);
}

fn shellProblem(gpa: Allocator, buf: []u8, command: []const u8) ?[]const u8 {
    const path = std.process.getEnvVarOwned(gpa, "PATH") catch gpa.dupe(u8, "") catch return null;
    defer gpa.free(path);
    const pathext = std.process.getEnvVarOwned(gpa, "PATHEXT") catch gpa.dupe(u8, ".COM;.EXE;.BAT;.CMD") catch return null;
    defer gpa.free(pathext);
    const Fs = struct {
        fn exists(_: void, p: []const u8) bool {
            const st = std.fs.cwd().statFile(p) catch return false;
            return st.kind == .file;
        }
    };
    return controls.shellProblem(buf, command, path, pathext, {}, Fs.exists);
}

/// The common Windows shells that are installed (Mac filters its list by
/// `isExecutableFile`).
fn installedShells(self: *SettingsWindow, out: *[controls.common_shells.len]controls.CommonShell) []const controls.CommonShell {
    var n: usize = 0;
    var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    for (controls.common_shells) |s| if (shellProblem(self.gpa, &buf, s.program) == null) {
        out[n] = s;
        n += 1;
    };
    return out[0..n];
}

/// "Choose Folder..." in the folder row: the system folder picker.
fn pickFolder(self: *SettingsWindow, key: []const u8) void {
    const r = self.reader() orelse return;
    const now = r.value(key);
    const start: ?[]const u8 = if (std.mem.eql(u8, now, "home") or std.mem.eql(u8, now, "inherit")) null else now;
    const chosen = folder_dialog.pick(self.gpa, self.hwnd, start) orelse return;
    defer self.gpa.free(chosen);
    _ = self.chooseValue(key, chosen);
}

/// The profile folder, for the folder row's `~` (caller frees).
fn homeDir(self: *const SettingsWindow) ?[]u8 {
    return std.process.getEnvVarOwned(self.gpa, "USERPROFILE") catch null;
}

/// What a curated control shows for its key, as text (the slider's
/// readout, the stepper's number, the MB, the color or its default label,
/// the shell or folder popup's label) - painted, and reported by the seam.
pub fn controlDisplay(self: *const SettingsWindow, buf: []u8, row: *const settings_pages.Row) []const u8 {
    const r = self.reader() orelse return "";
    const value = r.value(row.key);
    return switch (row.control) {
        .slider => |s| controls.sliderLabel(buf, self.sliderValue(row), s.percent, s.inverted),
        .stepper => |s| controls.formatNumber(buf, controls.parseOr(value, s.min)),
        .megabytes => controls.bytesAsMegabytes(buf, value),
        .color => |c| if (controls.parseHex(value) != null) value else if (value.len > 0) value else c.none_label,
        .shell => |s| if (!r.isSetInFile(row.key) or value.len == 0) controls.shellDefaultLabel(s.scripted) else value,
        .folder => blk: {
            const home = self.homeDir();
            defer if (home) |h| self.gpa.free(h);
            const shown = controls.folderLabel(buf, if (r.isSetInFile(row.key)) value else "", home orelse "");
            // folderLabel may return `value` itself; copy into buf so the
            // result outlives nothing borrowed.
            if (shown.ptr == buf.ptr) break :blk shown;
            const n = @min(shown.len, buf.len);
            std.mem.copyForwards(u8, buf[0..n], shown[0..n]);
            break :blk buf[0..n];
        },
        else => row.labelFor(value),
    };
}

/// All Settings' "<Page> >" link (Mac `reveal`): clear the search, open the
/// key's page and scroll the row into view.
pub fn reveal(self: *SettingsWindow, key: []const u8) bool {
    const id = settings_pages.pageFor(key) orelse return false;
    self.setPage(id);
    for (self.items) |it| if (it.kind == .row and std.mem.eql(u8, it.key, key)) {
        // Keep the section header above the row in view.
        self.scroll = layout.clampScroll(it.y - layout.px(dip.header_h, self.scale), self.content_h, self.frame().list.h);
        self.revealed_key = it.key;
        self.invalidate();
        return true;
    };
    return true;
}

/// Whether a curated row's control is live: not dimmed by its condition.
pub fn rowEnabled(self: *const SettingsWindow, row: *const settings_pages.Row) bool {
    const cond = row.enabled_when orelse return true;
    const r = self.reader() orelse return true;
    return cond.holds(r.value(cond.key));
}

/// The value popup for a curated row, hung under its control.
fn openChoice(self: *SettingsWindow, key: []const u8, anchor: Rect) void {
    const row = settings_pages.rowFor(key) orelse return;
    switch (row.control) {
        .shell => |sh| return self.openShellMenu(key, sh.scripted, anchor),
        .folder => return self.openFolderMenu(key, anchor),
        else => {},
    }
    const r = self.reader() orelse return;
    const entry = self.catalog.get(key);
    const opts = settings_pages.choices(self.gpa, row, if (entry) |e| e.options else null) catch return;
    defer self.gpa.free(opts);
    const now = r.value(key);
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);
    for (opts, 0..) |o, i| {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.gpa, o.label) catch return;
        defer self.gpa.free(wide);
        const checked = std.mem.eql(u8, o.value, now);
        _ = w32.AppendMenuW(menu, w32.MF_STRING | (if (checked) w32.MF_CHECKED else 0), i + 1, wide.ptr);
    }
    var pt: w32.POINT = .{ .x = anchor.x, .y = anchor.y + anchor.h };
    _ = w32.ClientToScreen(self.hwnd, &pt);
    const cmd = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, pt.x, pt.y, self.hwnd, null);
    if (cmd <= 0) return;
    const idx: usize = @intCast(cmd - 1);
    if (idx < opts.len) _ = self.chooseValue(key, opts[idx].value);
}

/// A popup of `labels` under `anchor` (`checked` marks one, `null` labels
/// are separators); returns the picked index.
fn popupPick(self: *SettingsWindow, anchor: Rect, labels: []const ?[]const u8, checked: ?usize) ?usize {
    const menu = w32.CreatePopupMenu() orelse return null;
    defer _ = w32.DestroyMenu(menu);
    for (labels, 0..) |maybe, i| {
        const label = maybe orelse {
            _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
            continue;
        };
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.gpa, label) catch return null;
        defer self.gpa.free(wide);
        const on = checked != null and checked.? == i;
        _ = w32.AppendMenuW(menu, w32.MF_STRING | (if (on) w32.MF_CHECKED else 0), i + 1, wide.ptr);
    }
    var pt: w32.POINT = .{ .x = anchor.x, .y = anchor.y + anchor.h };
    _ = w32.ClientToScreen(self.hwnd, &pt);
    const cmd = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, pt.x, pt.y, self.hwnd, null);
    if (cmd <= 0) return null;
    return @intCast(cmd - 1);
}

/// Mac `ShellControl`: the default, the installed common shells, the
/// current command when it is none of them, then Other... (which edits the
/// command in place; Mac asks in a sheet).
fn openShellMenu(self: *SettingsWindow, key: []const u8, scripted: bool, anchor: Rect) void {
    const r = self.reader() orelse return;
    const set = r.isSetInFile(key);
    const value = r.value(key);
    var found_buf: [controls.common_shells.len]controls.CommonShell = undefined;
    const found = self.installedShells(&found_buf);
    var labels: [controls.common_shells.len + 5]?[]const u8 = undefined;
    var values: [controls.common_shells.len + 5][]const u8 = undefined;
    var n: usize = 0;
    var checked: ?usize = null;
    labels[n] = controls.shellDefaultLabel(scripted);
    values[n] = "";
    if (!set) checked = n;
    n += 1;
    labels[n] = null;
    n += 1;
    var current_listed = false;
    for (found) |sh| {
        labels[n] = sh.label;
        values[n] = sh.program;
        if (set and std.ascii.eqlIgnoreCase(value, sh.program)) {
            checked = n;
            current_listed = true;
        }
        n += 1;
    }
    if (set and !current_listed and value.len > 0) {
        labels[n] = value;
        values[n] = value;
        checked = n;
        n += 1;
    }
    labels[n] = null;
    n += 1;
    const other = n;
    labels[n] = controls.other_shell_label;
    n += 1;
    const idx = self.popupPick(anchor, labels[0..n], checked) orelse return;
    if (idx == other) {
        _ = self.beginEdit(key);
        return;
    }
    if (labels[idx] == null) return;
    // Copy: a write reloads the reader `value` points into.
    var copy: [512]u8 = undefined;
    const v = values[idx];
    const n2 = @min(v.len, copy.len);
    @memcpy(copy[0..n2], v[0..n2]);
    _ = self.chooseShell(key, copy[0..n2]);
}

/// Mac `FolderControl`: Home folder (unset), Where Ghoztty was launched
/// (`inherit`), the chosen folder when there is one, then Choose Folder...
fn openFolderMenu(self: *SettingsWindow, key: []const u8, anchor: Rect) void {
    const r = self.reader() orelse return;
    const value = if (r.isSetInFile(key)) r.value(key) else "";
    const custom = value.len > 0 and !std.mem.eql(u8, value, "home") and !std.mem.eql(u8, value, "inherit");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = self.homeDir();
    defer if (home) |h| self.gpa.free(h);
    var labels: [5]?[]const u8 = undefined;
    var n: usize = 0;
    labels[n] = controls.folder_home_label;
    n += 1;
    labels[n] = controls.folder_inherit_label;
    n += 1;
    var checked: usize = if (std.mem.eql(u8, value, "inherit")) 1 else 0;
    if (custom) {
        labels[n] = controls.folderLabel(&buf, value, home orelse "");
        checked = n;
        n += 1;
    }
    labels[n] = null;
    n += 1;
    const choose = n;
    labels[n] = controls.folder_choose_label;
    n += 1;
    const idx = self.popupPick(anchor, labels[0..n], checked) orelse return;
    if (idx == 0) {
        _ = self.chooseValue(key, "");
    } else if (idx == 1) {
        _ = self.chooseValue(key, "inherit");
    } else if (idx == choose) {
        self.pickFolder(key);
    }
}

/// The Keyboard page's "Open Shortcut Guide..." link.
pub fn openShortcutGuide(self: *SettingsWindow) void {
    self.commitEdit();
    ShortcutGuideWindow.open(self.app, null);
}

/// The override note's Open link: the file that sets the key.
pub fn openOverridingFile(self: *SettingsWindow, key: []const u8) void {
    const src = self.overridingSource(key) orelse return;
    self.shell(null, src.path);
}

// ---------------------------------------------------------------------
// Advanced > Config file and the toast (T2676)
// ---------------------------------------------------------------------

/// "Open in Editor" and the sidebar's "Open Config File...": the file
/// Settings writes, in whatever the system opens it with.
pub fn openEditor(self: *SettingsWindow) void {
    self.commitEdit();
    self.shell(null, self.main_path);
}

/// "Show in Explorer": the folder, with the file selected (Mac's "Show in
/// Finder"). A file that does not exist yet opens its folder.
pub fn revealConfigFile(self: *SettingsWindow) void {
    var buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const args = banner_link.revealArgs(&buf, banner_link.revealTarget(self.main_path, &banner_link.pathExists)) orelse return;
    self.shell("explorer.exe", args);
}

/// A loaded file's Open.
pub fn openSource(self: *SettingsWindow, index: usize) void {
    if (index >= self.others.len) return;
    self.shell(null, self.others[index].path);
}

/// "Show Backups in Explorer".
pub fn showBackupsFolder(self: *SettingsWindow) void {
    self.shell(null, self.store.backup_dir);
}

pub fn toggleCurrentFile(self: *SettingsWindow) void {
    self.show_file = !self.show_file;
    self.layoutItems();
    self.invalidate();
}

/// Put backup `index` (newest first) back - the confirmed half of
/// Restore... (the seam calls this directly). It is itself a change, so
/// the toast offers its Undo.
pub fn restoreBackupAt(self: *SettingsWindow, index: usize) bool {
    if (index >= self.backup_list.len) return false;
    self.commitEdit();
    const path = self.gpa.dupe(u8, self.backup_list[index]) catch return false;
    defer self.gpa.free(path);
    return self.write(SettingsModel.restoreBackup, .{@as([]const u8, path)});
}

/// Restore...: the backups, newest first, as dates, then "Show Backups in
/// Explorer"; picking one asks first, as Mac's confirmation dialog does.
fn openRestoreMenu(self: *SettingsWindow, anchor: Rect) void {
    self.commitEdit();
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);
    var label_buf: [64]u8 = undefined;
    if (self.backup_list.len == 0) {
        _ = w32.AppendMenuW(menu, w32.MF_STRING | w32.MF_GRAYED, 0, std.unicode.utf8ToUtf16LeStringLiteral("No backups yet"));
    }
    for (self.backup_list, 0..) |b, i| {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.gpa, settings_advanced.backupLabel(&label_buf, b)) catch return;
        defer self.gpa.free(wide);
        _ = w32.AppendMenuW(menu, w32.MF_STRING, i + 1, wide.ptr);
    }
    const folder_cmd = self.backup_list.len + 1;
    if (self.backup_list.len > 0) {
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
        _ = w32.AppendMenuW(menu, w32.MF_STRING, folder_cmd, std.unicode.utf8ToUtf16LeStringLiteral("Show Backups in Explorer"));
    }
    var pt: w32.POINT = .{ .x = anchor.x, .y = anchor.y + anchor.h };
    _ = w32.ClientToScreen(self.hwnd, &pt);
    const cmd = w32.TrackPopupMenuEx(menu, w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD, pt.x, pt.y, self.hwnd, null);
    if (cmd <= 0) return;
    const picked: usize = @intCast(cmd);
    if (picked == folder_cmd) return self.showBackupsFolder();
    const idx = picked - 1;
    if (idx >= self.backup_list.len) return;
    var prompt_buf: [256]u8 = undefined;
    const prompt = settings_advanced.restorePrompt(&prompt_buf, settings_advanced.backupLabel(&label_buf, self.backup_list[idx]));
    const wprompt = std.unicode.utf8ToUtf16LeAllocZ(self.gpa, prompt) catch return;
    defer self.gpa.free(wprompt);
    const answer = w32.MessageBoxW(self.hwnd, wprompt.ptr, std.unicode.utf8ToUtf16LeStringLiteral(settings_advanced.restore_title), w32.MB_OKCANCEL | w32.MB_ICONWARNING);
    if (answer == w32.IDOK) _ = self.restoreBackupAt(idx);
}

/// The toast's Undo. Refused (and the file left alone) when it changed
/// after Settings wrote it; the toast then says so.
pub fn undoLast(self: *SettingsWindow) SettingsModel.UndoResult {
    self.commitEdit();
    self.in_write = true;
    const result = self.model.undoLastChange() catch .failed;
    self.in_write = false;
    self.toast_refused = result == .changed_since;
    if (result == .changed_since) {
        // Mac's toast keeps its change; it stays up until dismissed.
        self.toast_expanded = false;
        if (self.isWindow()) _ = w32.KillTimer(self.hwnd, toast_timer_id);
    }
    self.reloadData();
    self.refresh();
    return result;
}

pub fn dismissToast(self: *SettingsWindow) void {
    if (self.isWindow()) _ = w32.KillTimer(self.hwnd, toast_timer_id);
    self.model.dismissLastChange();
    self.toast_expanded = false;
    self.toast_refused = false;
    self.invalidate();
}

/// Show Change / Hide Change. An expanded toast stays up (Mac's timer only
/// dismisses a collapsed one).
pub fn toggleToastChange(self: *SettingsWindow) void {
    if (self.model.last_change == null) return;
    self.toast_expanded = !self.toast_expanded;
    self.invalidate();
}

/// Launch `file` with `args` (or open `file` when `program` is null). In a
/// debug build with `GHOZTTY_SETTINGS_SHELL_DRY` set, record it in
/// `last_shell` instead - the acceptance script's seam, so it can check what
/// a button opens without an editor appearing.
fn shell(self: *SettingsWindow, program: ?[]const u8, target: []const u8) void {
    if (comptime build_config.is_debug) {
        if (std.process.hasEnvVarConstant("GHOZTTY_SETTINGS_SHELL_DRY")) {
            if (self.last_shell) |l| self.gpa.free(l);
            self.last_shell = std.fmt.allocPrint(self.gpa, "{s} {s}", .{ program orelse "open", target }) catch null;
            return;
        }
    }
    if (program) |prog| {
        const wprog = std.unicode.utf8ToUtf16LeAllocZ(self.gpa, prog) catch return;
        defer self.gpa.free(wprog);
        const wargs = std.unicode.utf8ToUtf16LeAllocZ(self.gpa, target) catch return;
        defer self.gpa.free(wargs);
        _ = w32.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), wprog.ptr, wargs.ptr, null, w32.SW_SHOW);
    } else shellOpen(self.gpa, target);
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

/// The All Settings title and filter used to be pinned over Advanced's
/// list; since T2676 they scroll with it, under the Config file section
/// (Mac's order), so no page has a pinned band.
fn showsFilter(self: *const SettingsWindow) bool {
    _ = self;
    return false;
}

fn isWindow(self: *const SettingsWindow) bool {
    return active == self;
}

fn clientRect(self: *const SettingsWindow) w32.RECT {
    var rc: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (self.isWindow()) _ = w32.GetClientRect(self.hwnd, &rc);
    return rc;
}

pub fn frame(self: *const SettingsWindow) layout.Frame {
    const rc = self.clientRect();
    return layout.frameFor(self.scale, rc.right - rc.left, rc.bottom - rc.top, self.showsFilter());
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

pub fn roundRect(hdc: w32.HDC, r: Rect, radius: i32, fill: u32, border: ?u32, border_w: i32) void {
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

pub fn hit(self: *SettingsWindow, h: Hit) void {
    self.hits.append(self.gpa, h) catch {};
}

pub fn hair(self: *const SettingsWindow) i32 {
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
    const f = layout.frameFor(self.scale, w, h, self.showsFilter());
    fillRect(mem, .{ .x = 0, .y = 0, .w = w, .h = h }, cr(p.bg));
    self.paintSidebar(mem, f, p);
    fillRect(mem, f.rule, cr(p.divider));
    self.paintTitle(mem, f, p);
    self.paintList(mem, f, p);
    advanced_view.paintToast(self, mem, p, f);
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
        roundRect(hdc, tile, radius, tintColor(page.tint), null, 1);
        const gw = self.text.measure(hdc, page.glyph, .{ .bold = true }, .caption).cx;
        const ch = self.text.lineHeight(.caption);
        _ = self.text.drawText(hdc, tile.x + @divTrunc(tile.w - gw, 2), tile.y + @divTrunc(tile.h - ch, 2), page.glyph, .{ .bold = true }, .caption, cr(p.on_accent), true);
        const lh = self.text.lineHeight(.body);
        _ = self.text.drawText(hdc, tile.x + tile.w + g, r.y + @divTrunc(r.h - lh, 2), page.title, .{}, .body, if (selected) cr(p.text_on_select) else cr(p.text), true);
        const count = self.changedOn(page.id);
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
}

/// "All Settings" and its All N / Changed / Not on other pages segmented
/// control, in `band`.
fn paintFilterBand(self: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, band: Rect) void {
    const sh = self.text.lineHeight(.strong);
    _ = self.text.drawText(hdc, band.x, band.y + @divTrunc(band.h - sh, 2), "All Settings", .{}, .strong, cr(p.text), true);
    const seg_h = layout.px(dip.filter_h, self.scale);
    const pad = layout.px(dip.filter_pad_x, self.scale);
    const radius = layout.px(dip.radius, self.scale);
    var all_buf: [32]u8 = undefined;
    const all_label = std.fmt.bufPrint(&all_buf, "All {d}", .{self.catalog.entries.len}) catch "All";
    const labels = [_][]const u8{ all_label, "Changed", "Not on other pages" };
    const values = filter_values;
    var widths: [labels.len]i32 = undefined;
    var total: i32 = 0;
    for (labels, 0..) |l, i| {
        widths[i] = self.text.measure(hdc, l, .{ .bold = true }, .caption).cx + 2 * pad;
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

fn pageInfo(id: PageId) *const settings_pages.Page {
    return settings_pages.page(id);
}

/// A page tile's 0xRRGGBB tint as a COLORREF.
fn tintColor(rgb: u32) u32 {
    return w32.RGB(@truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb));
}

/// The All Settings filter, in its segmented control's order.
const filter_values = [_]Filter{ .all, .changed, .uncovered };

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
                const lh = self.text.lineHeight(.strong);
                self.text.drawEllipsized(hdc, .{ .x = view.x + m, .y = y + it.h - layout.px(dip.gap, self.scale) - lh, .w = view.w - 2 * m, .h = lh }, it.title, .{}, .strong, cr(p.text), true);
            },
            .custom => _ = self.paintCustom(hdc, p, it, y, true),
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
    const cards: ?[]const settings_pages.Option = if (item.row) |row| (if (row.control == .cards) row.control.cards else null) else null;
    const card_band = layout.px(dip.card_h, self.scale) + layout.px(dip.tight, self.scale) + ch;
    // Line 1 (label, dot, buttons) keeps the plain row height; `band` is the
    // control's, taller for the Pane style cards.
    const line_band = @max(lh, fh);
    // Flags are a two-column grid of checkboxes under line 1 (Mac's
    // `FlagsControl` LazyVGrid).
    const flag_lines: i32 = if (item.row) |row| (if (row.control == .flags) @intCast((self.flagOptions(key).len + 1) / 2) else 0) else 0;
    const flag_band = if (flag_lines > 0) flag_lines * lh + (flag_lines - 1) * t else 0;
    const band = if (cards != null) card_band else if (flag_lines > 0) @max(line_band, flag_band) else line_band;
    const control_w: i32 = if (cards) |c| @intCast(c.len * dip.card_w + (c.len -| 1) * dip.card_gap) else if (repeatable or flag_lines > 0) dip.list_w else dip.field_w;
    const cols = layout.rowColumns(self.scale, f.list, f.scrollbar.w, y + pad_y, lh, control_w);
    const width = cols.right - cols.left;
    const hovered = self.hover_key != null and std.mem.eql(u8, self.hover_key.?, key);
    const editing = self.edit_key != null and std.mem.eql(u8, self.edit_key.?, key);
    const enabled = if (item.row) |row| self.rowEnabled(row) else true;

    var cy = y + pad_y;
    if (draw) {
        if (self.revealed_key != null and std.mem.eql(u8, self.revealed_key.?, key)) {
            fillRect(hdc, .{ .x = cols.left - t, .y = y, .w = width + 2 * t, .h = self.rowHeightHint(item) }, cr(p.select));
        }
        // Line 1: the label (a curated row) or the key, the changed dot,
        // the doc button, Reset.
        const ky = cy + @divTrunc(line_band - lh, 2);
        var x = cols.left;
        x += if (item.row) |row|
            self.text.drawText(hdc, x, ky, row.label, .{}, .body, if (enabled) cr(p.text) else cr(p.secondary), true) + g
        else
            self.text.drawText(hdc, x, ky, key, .{ .code = true }, .body, cr(p.text), true) + g;
        if (r.isModified(key)) {
            const d = layout.px(dip.dot, self.scale);
            roundRect(hdc, .{ .x = x, .y = cy + @divTrunc(line_band - d, 2), .w = d, .h = d }, @divTrunc(d, 2), cr(p.accent), null, 1);
            x += d + g;
        }
        const icon = layout.px(dip.icon_hit, self.scale);
        const shown = self.doc_key != null and std.mem.eql(u8, self.doc_key.?, key);
        x += self.iconButton(hdc, x, cy, line_band, icon, "\u{24D8}", if (shown) cr(p.accent) else cr(p.secondary), .info, key);
        // Mac shows Reset on hover; it is also shown while the row is edited.
        if (r.isSetInFile(key) and (hovered or editing)) {
            _ = self.iconButton(hdc, x, cy, line_band, icon, "\u{21BA}", cr(p.accent), .reset, key);
        }

        // A curated key on a raw row links to its page (Mac's "<Page> >").
        if (item.row == null) if (settings_pages.pageFor(key)) |id| {
            var lb: [64]u8 = undefined;
            const link = std.fmt.bufPrint(&lb, "{s} \u{203A}", .{pageInfo(id).title}) catch "";
            const lw = self.text.measure(hdc, link, .{}, .caption).cx;
            const lx = cols.control.x - g - lw;
            if (lx > x) {
                _ = self.text.drawText(hdc, lx, cy + @divTrunc(line_band - ch, 2), link, .{}, .caption, cr(p.accent), true);
                self.hit(.{ .rect = .{ .x = lx, .y = cy, .w = lw, .h = line_band }, .kind = .reveal, .key = key });
            }
        };

        // The control.
        const choice_row: ?*const settings_pages.Row = if (item.row) |row| (if (row.control.isChoice() and !repeatable) row else null) else null;
        const drawn_row: ?*const settings_pages.Row = if (item.row) |row| (if (drawnControl(row.control) and !repeatable) row else null) else null;
        if (drawn_row) |row| {
            const box: Rect = if (row.control == .flags) .{ .x = cols.control.x, .y = cy, .w = cols.control.w, .h = flag_band } else cols.control;
            self.paintControl(hdc, p, row, box, enabled and override == null, editing);
        } else if (choice_row) |row| {
            const live = enabled and override == null;
            if (cards) |opts| {
                self.paintCards(hdc, p, opts, r.value(key), cols.control.x, cols.control.y, live);
            } else if (row.control == .toggle) {
                const on = std.mem.eql(u8, r.value(key), "true");
                const sh = @divTrunc(fh * 3, 4);
                const sw = sh * 2 - @divTrunc(sh, 3);
                const sr: Rect = .{ .x = cols.control.x + cols.control.w - sw, .y = cols.control.y + @divTrunc(fh - sh, 2), .w = sw, .h = sh };
                const track = if (!live) cr(p.divider) else if (on) cr(p.accent) else cr(p.boundary);
                roundRect(hdc, sr, @divTrunc(sh, 2), track, null, 1);
                const kn = sh - 2 * self.hair() - 2;
                const kx = if (on) sr.x + sr.w - kn - self.hair() - 1 else sr.x + self.hair() + 1;
                roundRect(hdc, .{ .x = kx, .y = sr.y + @divTrunc(sh - kn, 2), .w = kn, .h = kn }, @divTrunc(kn, 2), cr(p.field), null, 1);
                if (live) self.hit(.{ .rect = sr, .kind = .toggle, .key = key });
            } else {
                self.paintChoiceBox(hdc, p, cols.control, row.labelFor(r.value(key)), live);
                if (live) self.hit(.{ .rect = cols.control, .kind = .choice, .key = key });
            }
        } else if (repeatable) {
            self.paintValueList(hdc, p, key, cols.control, editing);
        } else {
            const value = r.value(key);
            const placeholder = if (entry) |e| (if (e.value().len == 0) "unset" else e.value()) else "unset";
            const text = if (editing) self.field.text() else value;
            self.paintField(hdc, p, cols.control, text, placeholder, editing and w32.GetFocus() == self.hwnd, if (editing) self.field.caret else text.len, true, override != null or !enabled);
            if (override == null and enabled) self.hit(.{ .rect = cols.control, .kind = .field, .key = key });
        }
    }
    cy += band;

    // The doc summary (Pane style says what its two cards mean, as Mac).
    const summary = if (cards != null) settings_live.pane_style_caption else item.summary;
    if (summary.len > 0) {
        cy += t;
        if (draw) self.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = width, .h = ch }, summary, .{}, .caption, cr(p.secondary), false);
        cy += ch;
    }

    // A dimmed curated row says why (Mac's `enabledWhen` reason).
    if (!enabled) {
        cy += t;
        if (draw) self.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = width, .h = ch }, item.row.?.enabled_when.?.reason, .{ .italic = true }, .caption, cr(p.secondary), false);
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

/// The curated controls `paintControl` draws (T2681); the rest are a
/// switch, a popup, cards or a text field.
fn drawnControl(c: settings_pages.Control) bool {
    return switch (c) {
        .slider, .stepper, .megabytes, .color, .flags, .shell, .folder => true,
        else => false,
    };
}

/// A flags key's names, in schema order (empty when the schema has none).
fn flagOptions(self: *const SettingsWindow, key: []const u8) []const []const u8 {
    const e = self.catalog.get(key) orelse return &.{};
    return e.options orelse &.{};
}

/// One curated control in `box` (Mac `SettingControl`'s cases). `live` is
/// false for a dimmed or overridden row: drawn, but no hits.
fn paintControl(self: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, row: *const settings_pages.Row, box: Rect, live: bool, editing: bool) void {
    const key = row.key;
    const r = self.reader() orelse return;
    const g = layout.px(dip.gap, self.scale);
    const t = layout.px(dip.tight, self.scale);
    const lh = self.text.lineHeight(.body);
    const ch = self.text.lineHeight(.caption);
    const radius = layout.px(dip.radius, self.scale);
    const text_y = box.y + @divTrunc(box.h - lh, 2);
    const muted = cr(p.secondary);
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const focused = editing and w32.GetFocus() == self.hwnd;
    switch (row.control) {
        .slider => |sl| {
            // Track, filled to the knob in the accent, and the readout at
            // the right (Mac: a 160pt slider and a 42pt monospaced label).
            const label = self.controlDisplay(&dbuf, row);
            const lw = layout.px(42, self.scale);
            const tw = self.text.measure(hdc, label, .{}, .body).cx;
            _ = self.text.drawText(hdc, box.x + box.w - tw, text_y, label, .{}, .body, muted, true);
            const track: Rect = .{ .x = box.x, .y = box.y, .w = @max(0, box.w - lw - g), .h = box.h };
            const knob = layout.px(14, self.scale);
            const th = @max(2, layout.px(4, self.scale));
            const ux = track.x + @divTrunc(knob, 2);
            const uw = @max(1, track.w - knob);
            const mid = box.y + @divTrunc(box.h, 2);
            const frac = controls.fraction(self.sliderValue(row), sl.min, sl.max);
            const kx = ux + @as(i32, @intFromFloat(@round(frac * @as(f64, @floatFromInt(uw)))));
            roundRect(hdc, .{ .x = ux, .y = mid - @divTrunc(th, 2), .w = uw, .h = th }, @divTrunc(th, 2), cr(p.boundary), null, 1);
            if (kx > ux) roundRect(hdc, .{ .x = ux, .y = mid - @divTrunc(th, 2), .w = kx - ux, .h = th }, @divTrunc(th, 2), if (live) cr(p.accent) else cr(p.divider), null, 1);
            roundRect(hdc, .{ .x = kx - @divTrunc(knob, 2), .y = mid - @divTrunc(knob, 2), .w = knob, .h = knob }, @divTrunc(knob, 2), cr(p.field), cr(p.boundary), self.hair());
            if (live) self.hit(.{ .rect = track, .kind = .slider, .key = key });
        },
        .stepper, .megabytes => {
            // [ number ][^v] unit - the number right of the row, Mac's
            // 64pt field + Stepper + unit (megabytes: 72pt, no arrows).
            const unit = switch (row.control) {
                .stepper => |st| st.unit,
                else => controls.megabytes_unit,
            };
            const uw = self.text.measure(hdc, unit, .{}, .body).cx;
            var x = box.x + box.w - uw;
            _ = self.text.drawText(hdc, x, text_y, unit, .{}, .body, muted, true);
            x -= g;
            if (row.control == .stepper) {
                const aw = layout.px(16, self.scale);
                x -= aw;
                const arrows: Rect = .{ .x = x, .y = box.y, .w = aw, .h = box.h };
                roundRect(hdc, arrows, radius, if (live) cr(p.field) else cr(p.bg), cr(p.boundary), self.hair());
                const half = @divTrunc(box.h, 2);
                fillRect(hdc, .{ .x = x, .y = box.y + half, .w = aw, .h = self.hair() }, cr(p.boundary));
                const up = "\u{25B4}";
                const down = "\u{25BE}";
                const gw = self.text.measure(hdc, up, .{}, .caption).cx;
                _ = self.text.drawText(hdc, x + @divTrunc(aw - gw, 2), box.y + @divTrunc(half - ch, 2), up, .{}, .caption, if (live) cr(p.text) else muted, true);
                _ = self.text.drawText(hdc, x + @divTrunc(aw - gw, 2), box.y + half + @divTrunc(box.h - half - ch, 2), down, .{}, .caption, if (live) cr(p.text) else muted, true);
                if (live) {
                    self.hit(.{ .rect = .{ .x = x, .y = box.y, .w = aw, .h = half }, .kind = .step_up, .key = key });
                    self.hit(.{ .rect = .{ .x = x, .y = box.y + half, .w = aw, .h = box.h - half }, .kind = .step_down, .key = key });
                }
                x -= t;
            }
            const fw = layout.px(if (row.control == .stepper) 64 else 72, self.scale);
            const field: Rect = .{ .x = x - fw, .y = box.y, .w = fw, .h = box.h };
            const shown = if (editing) self.field.text() else self.controlDisplay(&dbuf, row);
            self.paintField(hdc, p, field, shown, "", focused, if (editing) self.field.caret else shown.len, false, !live);
            if (live) self.hit(.{ .rect = field, .kind = .field, .key = key });
        },
        .color => |c| {
            // A color well at the right; left of it the default's name
            // when unset, or "Use <default>" when the file sets a color
            // (Mac `ColorControl`).
            const value = r.value(key);
            const rgb = controls.parseHex(value);
            const ww = layout.px(44, self.scale);
            const well: Rect = .{ .x = box.x + box.w - ww, .y = box.y, .w = ww, .h = box.h };
            roundRect(hdc, well, radius, cr(p.field), cr(p.boundary), self.hair());
            const inset = @max(3, layout.px(3, self.scale));
            const swatch: Rect = .{ .x = well.x + inset, .y = well.y + inset, .w = well.w - 2 * inset, .h = well.h - 2 * inset };
            if (rgb) |v| {
                roundRect(hdc, swatch, @max(1, radius - inset), w32.RGB(@intCast((v >> 16) & 0xFF), @intCast((v >> 8) & 0xFF), @intCast(v & 0xFF)), cr(p.boundary), self.hair());
            } else {
                // No color of its own: an empty well with Mac's gray.
                roundRect(hdc, swatch, @max(1, radius - inset), w32.RGB(128, 128, 128), cr(p.boundary), self.hair());
            }
            if (live) self.hit(.{ .rect = well, .kind = .color_well, .key = key });
            if (rgb == null) {
                const label = self.controlDisplay(&dbuf, row);
                const lw = self.text.measure(hdc, label, .{}, .body).cx;
                _ = self.text.drawText(hdc, well.x - g - lw, text_y, label, .{}, .body, muted, true);
            } else if (r.isSetInFile(key)) {
                var lb: [96]u8 = undefined;
                const link = std.fmt.bufPrint(&lb, "Use {s}", .{c.none_label}) catch "Use default";
                const lw = self.text.measure(hdc, link, .{}, .body).cx;
                const lx = well.x - g - lw;
                _ = self.text.drawText(hdc, lx, text_y, link, .{}, .body, if (live) cr(p.accent) else muted, true);
                if (live) self.hit(.{ .rect = .{ .x = lx, .y = box.y, .w = lw, .h = box.h }, .kind = .color_reset, .key = key });
            }
        },
        .flags => {
            const options = self.flagOptions(key);
            const value = r.value(key);
            const colw = @divTrunc(box.w, 2);
            const bs = layout.px(14, self.scale);
            for (options, 0..) |o, i| {
                const cx = box.x + @as(i32, @intCast(i % 2)) * colw;
                const cyy = box.y + @as(i32, @intCast(i / 2)) * (lh + t);
                const on = controls.flagState(value, o) orelse false;
                const cb: Rect = .{ .x = cx, .y = cyy + @divTrunc(lh - bs, 2), .w = bs, .h = bs };
                const fill = if (on) (if (live) cr(p.accent) else cr(p.divider)) else cr(p.field);
                roundRect(hdc, cb, layout.px(3, self.scale), fill, if (on) fill else cr(p.boundary), self.hair());
                if (on) {
                    const tick = "\u{2713}";
                    const tw = self.text.measure(hdc, tick, .{ .bold = true }, .caption).cx;
                    _ = self.text.drawText(hdc, cb.x + @divTrunc(bs - tw, 2), cb.y + @divTrunc(bs - ch, 2), tick, .{ .bold = true }, .caption, w32.RGB(255, 255, 255), true);
                }
                _ = self.text.drawText(hdc, cb.x + bs + t + t, cyy, o, .{}, .body, if (live) cr(p.text) else muted, true);
                if (live) self.hit(.{ .rect = .{ .x = cx, .y = cyy, .w = colw, .h = lh }, .kind = .flag, .key = key, .index = i });
            }
        },
        .shell, .folder => {
            if (editing and row.control == .shell) {
                // Other...: the command typed in place.
                self.paintField(hdc, p, box, self.field.text(), "pwsh.exe -NoLogo", focused, self.field.caret, true, false);
                self.hit(.{ .rect = box, .kind = .field, .key = key });
            } else {
                self.paintChoiceBox(hdc, p, box, self.controlDisplay(&dbuf, row), live);
                if (live) self.hit(.{ .rect = box, .kind = .choice, .key = key });
            }
        },
        else => {},
    }
}

/// Pane style's preview cards (Mac `PaneStyleSection`): a thumbnail per
/// option - raised cards on the window gradient, or edge-to-edge panes split
/// by a hairline - with its label under it; the chosen one is ringed and its
/// label set in the accent. A click writes the option (`.pane_style` hit).
fn paintCards(self: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, opts: []const settings_pages.Option, chosen: []const u8, x0: i32, y0: i32, live: bool) void {
    const cw = layout.px(dip.card_w, self.scale);
    const chh = layout.px(dip.card_h, self.scale);
    const gap = layout.px(dip.card_gap, self.scale);
    const radius = layout.px(dip.card_radius, self.scale);
    const t = layout.px(dip.tight, self.scale);
    const ch = self.text.lineHeight(.caption);
    var x = x0;
    for (opts) |o| {
        const selected = std.mem.eql(u8, chosen, o.value);
        const card: Rect = .{ .x = x, .y = y0, .w = cw, .h = chh };
        self.paintCardThumb(hdc, card, radius, std.mem.eql(u8, o.value, "elevated"));
        const ring: i32 = if (selected) @max(2, layout.px(2, self.scale)) else self.hair();
        frameRound(hdc, card, radius, if (selected) cr(p.accent) else cr(p.boundary), ring);
        const lw = self.text.measure(hdc, o.label, .{ .bold = selected }, .caption).cx;
        const color = if (!live) cr(p.secondary) else if (selected) cr(p.accent) else cr(p.text);
        _ = self.text.drawText(hdc, x + @divTrunc(cw - lw, 2), y0 + chh + t, o.label, .{ .bold = selected }, .caption, color, true);
        if (live) self.hit(.{ .rect = .{ .x = x, .y = y0, .w = cw, .h = chh + t + ch }, .kind = .pane_style, .key = o.value });
        x += cw + gap;
    }
}

/// One card's picture, clipped to its rounded outline.
fn paintCardThumb(self: *SettingsWindow, hdc: w32.HDC, r: Rect, radius: i32, elevated: bool) void {
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    if (w32.CreateRoundRectRgn(r.x, r.y, r.x + r.w + 1, r.y + r.h + 1, radius * 2, radius * 2)) |rgn| {
        _ = w32.SelectClipRgn(hdc, rgn);
        _ = w32.DeleteObject(rgn);
    }
    if (elevated) {
        // Mac's window gradient, top-left (0.36,0.55,0.84) to bottom-right
        // (0.25,0.71,0.69), as diagonal bands.
        const a = [3]f32{ 92, 140, 214 };
        const b = [3]f32{ 64, 181, 176 };
        const span = r.w + r.h;
        var i: i32 = 0;
        const step: i32 = @max(1, self.hair());
        while (i < r.w) : (i += step) {
            const f: f32 = @as(f32, @floatFromInt(i + @divTrunc(r.h, 2))) / @as(f32, @floatFromInt(span));
            fillRect(hdc, .{ .x = r.x + i, .y = r.y, .w = step, .h = r.h }, thumbRgb(lerp(a[0], b[0], f), lerp(a[1], b[1], f), lerp(a[2], b[2], f)));
        }
        // Two raised panes (Mac: 6pt padding and spacing, radius 5 - here on
        // the 4 DIP scale).
        const pad = layout.px(dip.gap, self.scale);
        const pw = @divTrunc(r.w - 3 * pad, 2);
        const pr = layout.px(dip.radius, self.scale);
        roundRect(hdc, .{ .x = r.x + pad, .y = r.y + pad, .w = pw, .h = r.h - 2 * pad }, pr, thumbRgb(38, 41, 47), null, 1);
        roundRect(hdc, .{ .x = r.x + 2 * pad + pw, .y = r.y + pad, .w = pw, .h = r.h - 2 * pad }, pr, thumbRgb(48, 52, 58), null, 1);
    } else {
        // Edge-to-edge panes and the divider between them.
        fillRect(hdc, r, thumbRgb(41, 43, 51));
        fillRect(hdc, .{ .x = r.x + @divTrunc(r.w, 2), .y = r.y, .w = self.hair(), .h = r.h }, thumbRgb(89, 89, 89));
    }
}

fn lerp(a: f32, b: f32, f: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(a + (b - a) * f, 0, 255)));
}

fn thumbRgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

/// A rounded outline with no fill.
fn frameRound(hdc: w32.HDC, r: Rect, radius: i32, color: u32, width: i32) void {
    const pen = w32.CreatePen(0, width, color) orelse return;
    defer _ = w32.DeleteObject(pen);
    const old_pen = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, old_pen);
    const old_brush = w32.SelectObject(hdc, w32.GetStockObject(w32.NULL_BRUSH));
    defer _ = w32.SelectObject(hdc, old_brush);
    const inset = @divTrunc(width, 2);
    _ = w32.RoundRect(hdc, r.x + inset, r.y + inset, r.x + r.w - inset + 1, r.y + r.h - inset + 1, radius * 2, radius * 2);
}

/// The row's laid-out height, for the reveal highlight (0 before layout).
fn rowHeightHint(self: *const SettingsWindow, item: Item) i32 {
    for (self.items) |it| if (it.kind == .row and std.mem.eql(u8, it.key, item.key)) return it.h;
    return 0;
}

/// A custom section (Mac `SettingsCustomSection`). Returns its height.
fn paintCustom(self: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, item: Item, y: i32, draw: bool) i32 {
    const f = self.frame();
    switch (item.custom) {
        .config_file => return advanced_view.paintConfigFile(self, hdc, p, y, draw),
        .agent_status, .version => return self.paintLive(hdc, p, item.custom, y, draw),
        .all_settings => {
            const bh = layout.px(dip.filter_band_h, self.scale);
            if (draw) {
                const cols = layout.rowColumns(self.scale, f.list, f.scrollbar.w, y, bh, dip.field_w);
                self.paintFilterBand(hdc, p, .{ .x = cols.left, .y = y, .w = cols.right - cols.left, .h = bh });
            }
            return bh;
        },
        else => {},
    }
    const g = layout.px(dip.gap, self.scale);
    const t = layout.px(dip.tight, self.scale);
    const pad_y = layout.px(dip.row_pad_y, self.scale);
    const lh = self.text.lineHeight(.body);
    const ch = self.text.lineHeight(.caption);
    const cols = layout.rowColumns(self.scale, f.list, f.scrollbar.w, y + pad_y, lh, dip.field_w);
    const width = cols.right - cols.left;
    var cy = y + pad_y;
    const Line = struct { text: []const u8, caption: bool = true, link: ?Hit.Kind = null };
    const lines: []const Line = switch (item.custom) {
        .theme => return self.paintTheme(hdc, p, y, draw),
        .shortcut_guide => &.{
            .{ .text = "Every shortcut, searchable, with what it does.", .caption = false },
            .{ .text = "Open Shortcut Guide\u{2026}", .link = .guide_link },
            .{ .text = "To change a shortcut, edit keybind under Advanced \u{203A} All Settings." },
        },
        .version, .agent_status => unreachable,
        .remote_machines => &.{
            .{ .text = "Your machines and their host settings are in the machine chooser (New Remote Window)." },
        },
        .config_file, .all_settings => unreachable,
    };
    for (lines, 0..) |line, i| {
        if (i > 0) cy += t;
        const style: notes_render.SizeClass = if (line.caption) .caption else .body;
        const h = if (line.caption) ch else lh;
        if (draw) {
            const color = if (line.link != null) cr(p.accent) else if (line.caption) cr(p.secondary) else cr(p.text);
            if (line.link) |kind| {
                const w = self.text.drawText(hdc, cols.left, cy, line.text, .{}, style, color, true);
                self.hit(.{ .rect = .{ .x = cols.left, .y = cy, .w = w, .h = h }, .kind = kind });
            } else {
                self.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = width, .h = h }, line.text, .{}, style, color, false);
            }
        }
        cy += h;
    }
    cy += pad_y + g;
    if (draw) fillRect(hdc, .{ .x = cols.left, .y = cy - self.hair(), .w = width, .h = self.hair() }, cr(p.divider));
    return cy - y;
}

/// A value popup's closed box: the field, the label ellipsized short of
/// the arrow, the arrow.
fn paintChoiceBox(self: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, box: Rect, label: []const u8, live: bool) void {
    const lh = self.text.lineHeight(.body);
    const ch = self.text.lineHeight(.caption);
    const fpad = layout.px(dip.gap, self.scale);
    self.paintField(hdc, p, box, "", "", false, 0, false, !live);
    const arrow = "\u{25BE}";
    const aw = self.text.measure(hdc, arrow, .{}, .caption).cx;
    self.text.drawEllipsized(hdc, .{
        .x = box.x + fpad,
        .y = box.y + @divTrunc(box.h - lh, 2),
        .w = @max(0, box.w - 3 * fpad - aw),
        .h = lh,
    }, label, .{}, .body, if (live) cr(p.text) else cr(p.secondary), true);
    _ = self.text.drawText(hdc, box.x + box.w - aw - fpad, box.y + @divTrunc(box.h - ch, 2), arrow, .{}, .caption, cr(p.secondary), true);
}

/// Appearance > Theme (Mac `ThemeSection`): "Use" picks one theme or a
/// light and a dark one; then one popup per slot, each listing only its
/// kind, and Mac's warnings. Returns the height.
fn paintTheme(self: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, y: i32, draw: bool) i32 {
    const f = self.frame();
    const g = layout.px(dip.gap, self.scale);
    const t = layout.px(dip.tight, self.scale);
    const pad_y = layout.px(dip.row_pad_y, self.scale);
    const lh = self.text.lineHeight(.body);
    const ch = self.text.lineHeight(.caption);
    const fh = layout.px(dip.field_h, self.scale);
    const band = @max(lh, fh);
    const cat = self.themeCatalog();
    const sel = self.themeSelection();
    const follows = if (sel) |s| s.follows_system else false;
    const live = self.overridingSource("theme") == null;
    const Line = struct { label: []const u8, value: []const u8, caption: []const u8, kind: Hit.Kind, index: usize = 0 };
    var b1: [96]u8 = undefined;
    var b2: [96]u8 = undefined;
    const lines = [_]?Line{
        .{
            .label = "Use",
            .value = if (follows) "Light & dark themes" else "One theme",
            .caption = if (follows) "Switches between a light and a dark theme with the system appearance." else "One theme, whatever the system appearance.",
            .kind = .theme_mode,
        },
        if (follows) .{
            .label = "Light mode",
            .value = sel.?.light,
            .caption = std.fmt.bufPrint(&b1, "Lists only the {d} light themes.", .{cat.count(true)}) catch "",
            .kind = .theme_slot,
            .index = 0,
        } else .{
            .label = "Theme",
            .value = if (sel) |s| s.light else "Default",
            .caption = std.fmt.bufPrint(&b1, "{d} light and {d} dark themes.", .{ cat.count(true), cat.count(false) }) catch "",
            .kind = .theme_slot,
            .index = 2,
        },
        if (follows) .{
            .label = "Dark mode",
            .value = sel.?.dark,
            .caption = std.fmt.bufPrint(&b2, "Lists only the {d} dark themes.", .{cat.count(false)}) catch "",
            .kind = .theme_slot,
            .index = 1,
        } else null,
    };
    var cy = y;
    var cols = layout.rowColumns(self.scale, f.list, f.scrollbar.w, cy, lh, dip.field_w);
    for (lines) |maybe| {
        const line = maybe orelse continue;
        cy += pad_y;
        cols = layout.rowColumns(self.scale, f.list, f.scrollbar.w, cy, lh, dip.field_w);
        if (draw) {
            _ = self.text.drawText(hdc, cols.left, cy + @divTrunc(band - lh, 2), line.label, .{}, .body, cr(p.text), true);
            self.paintChoiceBox(hdc, p, cols.control, line.value, live);
            if (live) self.hit(.{ .rect = cols.control, .kind = line.kind, .index = line.index });
        }
        cy += band + t;
        if (draw) self.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = cols.right - cols.left, .h = ch }, line.caption, .{}, .caption, cr(p.secondary), false);
        cy += ch + pad_y;
    }
    // Mac's notices: a hand-edited slot holding the wrong kind, no themes
    // found, a later include that sets the key.
    var nb: [400]u8 = undefined;
    const notice: ?[]const u8 = blk: {
        if (!live) break :blk "Set in a file that loads after your config - edit it there.";
        if (cat.themes.len == 0) break :blk "No themes were found in the bundled or your own themes folder.";
        if (sel) |s| if (theme_catalog.mismatch(cat, s)) |slot| {
            const bad = s.slotName(slot);
            const want = @tagName(slot);
            const is = if (slot == .light) "dark" else "light";
            break :blk std.fmt.bufPrint(&nb, "\u{26A0} {s} is a {s} theme but is set for {s} mode. Pick a {s} theme to fix it.", .{ bad, is, want, want }) catch null;
        };
        break :blk null;
    };
    if (notice) |n| {
        if (draw) self.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = cols.right - cols.left, .h = ch }, n, .{}, .caption, cr(p.warn), false);
        cy += ch + pad_y;
    }
    cy += g;
    if (draw) fillRect(hdc, .{ .x = cols.left, .y = cy - self.hair(), .w = cols.right - cols.left, .h = self.hair() }, cr(p.divider));
    return cy - y;
}

/// The theme catalog, read on first use.
pub fn themeCatalog(self: *SettingsWindow) *const theme_catalog.Catalog {
    if (self.themes == null) {
        self.themes = settings_theme.loadCatalog(self.gpa) catch .{ .arena = std.heap.ArenaAllocator.init(self.gpa) };
    }
    return &self.themes.?;
}

/// The `theme` key as a selection (null: no theme set). Borrows the
/// reader's value, so it is good until the next reload.
pub fn themeSelection(self: *const SettingsWindow) ?theme_catalog.Selection {
    const r = self.reader() orelse return null;
    return theme_catalog.Selection.parse(r.value("theme"));
}

/// "Use" (Mac `switchMode`): light & dark seeds the other slot from the
/// current theme's family; one theme keeps the slot the system shows.
pub fn setThemeFollows(self: *SettingsWindow, follow: bool) bool {
    if (self.overridingSource("theme") != null) return false;
    const cat = self.themeCatalog();
    const res = theme_catalog.switchMode(self.gpa, cat, self.themeSelection(), follow, !system_colors.usesLightTheme()) catch return false;
    return switch (res) {
        .set => |v| blk: {
            defer self.gpa.free(v);
            break :blk self.chooseValue("theme", v);
        },
        .reset => self.chooseValue("theme", ""),
        .unchanged => true,
    };
}

/// A theme picked for `slot` (Mac `pick`). Only a catalog theme is taken.
pub fn pickTheme(self: *SettingsWindow, name: []const u8, slot: theme_catalog.Slot) bool {
    if (self.overridingSource("theme") != null) return false;
    const theme = self.themeCatalog().named(name) orelse return false;
    const v = theme_catalog.pick(self.gpa, self.themeSelection(), theme.name, slot) catch return false;
    defer self.gpa.free(v);
    return self.chooseValue("theme", v);
}

fn openThemeMode(self: *SettingsWindow, anchor: Rect) void {
    const follows = if (self.themeSelection()) |s| s.follows_system else false;
    var pt: w32.POINT = .{ .x = anchor.x, .y = anchor.y + anchor.h };
    _ = w32.ClientToScreen(self.hwnd, &pt);
    const pick = settings_theme.modeMenu(self.gpa, self.hwnd, pt, follows) orelse return;
    _ = self.setThemeFollows(pick);
}

/// A slot's theme menu: 0 light, 1 dark, 2 the one theme (both kinds).
fn openThemeMenu(self: *SettingsWindow, which: usize, anchor: Rect) void {
    const cat = self.themeCatalog();
    const sel = self.themeSelection();
    const slot: theme_catalog.Slot = if (which == 1) .dark else .light;
    const now = if (sel) |s| s.slotName(slot) else "";
    const kinds: settings_theme.Kinds = switch (which) {
        0 => .light,
        1 => .dark,
        else => .both,
    };
    var pt: w32.POINT = .{ .x = anchor.x, .y = anchor.y + anchor.h };
    _ = w32.ClientToScreen(self.hwnd, &pt);
    const idx = settings_theme.themeMenu(self.gpa, self.hwnd, pt, cat, kinds, now) orelse return;
    _ = self.pickTheme(cat.themes[idx].name, slot);
}

/// Sessions & Agent's Agent and Updates' version (T2680, Mac
/// `AgentStatusSection` / `VersionSection`): label-and-value lines from the
/// snapshot `refresh` took, so painting never touches the agent.
fn paintLive(self: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, which: settings_pages.Custom, y: i32, draw: bool) i32 {
    const f = self.frame();
    const g = layout.px(dip.gap, self.scale);
    const t = layout.px(dip.tight, self.scale);
    const pad_y = layout.px(dip.row_pad_y, self.scale);
    const lh = self.text.lineHeight(.body);
    const ch = self.text.lineHeight(.caption);
    const cols = layout.rowColumns(self.scale, f.list, f.scrollbar.w, y + pad_y, lh, dip.field_w);
    const width = cols.right - cols.left;
    // label (body, leading) | value (trailing); a line with no label is a
    // caption across the row.
    const Line = struct { label: ?[]const u8 = null, value: []const u8, mono: bool = false, dot: ?bool = null, link: ?Hit.Kind = null };
    var lines: [6]Line = undefined;
    var n: usize = 0;
    var b1: [128]u8 = undefined;
    var b2: [160]u8 = undefined;
    var b3: [160]u8 = undefined;
    switch (which) {
        .agent_status => {
            const a = self.live_agent;
            lines[n] = .{ .label = "Status", .value = settings_live.statusLine(&b1, a), .dot = a.running };
            n += 1;
            if (settings_live.runningBuildLine(&b2, a)) |rb| {
                lines[n] = .{ .label = "Running build", .value = rb, .mono = true };
                n += 1;
            }
            if (a.bundled_build) |bb| {
                lines[n] = .{ .label = "This app\u{2019}s agent", .value = bb, .mono = true };
                n += 1;
            }
            if (a.pipe.len > 0) {
                lines[n] = .{ .label = "Pipe", .value = a.pipe, .mono = true };
                n += 1;
            }
            lines[n] = .{ .value = "The agent keeps your shells alive when the app quits or restarts." };
            n += 1;
        },
        .version => {
            const full = build_config.version_string;
            const plus = std.mem.indexOfScalar(u8, full, '+');
            const ver = std.mem.trimRight(u8, if (plus) |i| full[0..i] else full, "-");
            const build = if (plus) |i| full[i + 1 ..] else "";
            const last: ?i64 = if (self.app.update_last_check_ms != 0) self.app.update_last_check_ms else null;
            lines[n] = .{ .label = std.fmt.bufPrint(&b1, "Ghoztty {s}", .{ver}) catch "Ghoztty", .value = "Check for Updates\u{2026}", .link = .check_updates };
            n += 1;
            lines[n] = .{ .value = settings_live.versionCaption(&b3, build, last, std.time.milliTimestamp()) };
            n += 1;
        },
        else => unreachable,
    }
    var cy = y + pad_y;
    for (lines[0..n], 0..) |line, i| {
        if (i > 0) cy += t;
        const h = if (line.label != null) lh else ch;
        if (draw) {
            if (line.label) |label| {
                const lw = self.text.drawText(hdc, cols.left, cy, label, .{}, .body, cr(p.text), true);
                const style: @import("banner_markdown.zig").Style = .{ .code = line.mono };
                const vw = self.text.measure(hdc, line.value, style, .body).cx;
                const room = @max(0, width - lw - 3 * g);
                const shown_w = @min(vw, room);
                const vx = cols.right - shown_w;
                if (line.dot) |on| {
                    const d = layout.px(dip.dot, self.scale);
                    roundRect(hdc, .{ .x = vx - d - g, .y = cy + @divTrunc(lh - d, 2), .w = d, .h = d }, @divTrunc(d, 2), if (on) cr(p.good) else cr(p.secondary), null, 1);
                }
                const color = if (line.link != null) cr(p.accent) else cr(p.text);
                self.text.drawEllipsized(hdc, .{ .x = vx, .y = cy, .w = shown_w, .h = lh }, line.value, style, .body, color, true);
                if (line.link) |kind| self.hit(.{ .rect = .{ .x = vx, .y = cy, .w = shown_w, .h = lh }, .kind = kind });
            } else {
                self.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = width, .h = ch }, line.value, .{}, .caption, cr(p.secondary), false);
            }
        }
        cy += h;
    }
    cy += pad_y + g;
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
            .field, .add_field, .reset, .info, .open, .chip_remove, .toggle, .choice, .reveal, .guide_link, .filter => true,
            .check_updates, .pane_style => true,
            .open_editor, .reveal_file, .open_source, .restore_menu, .show_file => true,
            .toast_body, .toast_show, .toast_undo, .toast_dismiss => true,
            .theme_mode, .theme_slot => true,
            .slider, .step_up, .step_down, .color_well, .color_reset, .flag => true,
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

/// Click the painted hit of `kind` (and `key`, when given) at its centre,
/// through the same path a mouse click takes. False when none is painted.
pub fn clickHit(self: *SettingsWindow, kind: Hit.Kind, key: []const u8) bool {
    for (self.hits.items) |h| {
        if (h.kind != kind) continue;
        if (key.len > 0 and !std.mem.eql(u8, h.key, key)) continue;
        self.onLeftDown(h.rect.x + @divTrunc(h.rect.w, 2), h.rect.y + @divTrunc(h.rect.h, 2));
        // A slider press is a drag; the seam's click is press + release.
        if (self.slide_key != null) self.endSlide();
        return true;
    }
    return false;
}

fn onLeftDown(self: *SettingsWindow, x: i32, y: i32) void {
    const f = self.frame();
    if (self.hitAt(x, y)) |h| {
        switch (h.kind) {
            .page => self.setPage(pages[h.index].id),
            .filter => self.setFilter(filter_values[@min(h.index, filter_values.len - 1)]),
            .toggle => _ = self.toggleKey(h.key),
            .choice => self.openChoice(h.key, h.rect),
            .reveal => _ = self.reveal(h.key),
            .guide_link => self.openShortcutGuide(),
            .check_updates => self.checkForUpdates(),
            .pane_style => _ = self.chooseValue("macos-pane-style", h.key),
            .config_link, .open_editor => self.openEditor(),
            .reveal_file => self.revealConfigFile(),
            .open_source => self.openSource(h.index),
            .restore_menu => self.openRestoreMenu(h.rect),
            .show_file => self.toggleCurrentFile(),
            .toast_body => {},
            .toast_show => self.toggleToastChange(),
            .toast_undo => _ = self.undoLast(),
            .toast_dismiss => self.dismissToast(),
            .theme_mode => self.openThemeMode(h.rect),
            .theme_slot => self.openThemeMenu(h.index, h.rect),
            .slider => self.beginSlide(h.key, h.rect, x),
            .step_up => _ = self.stepKey(h.key, 1),
            .step_down => _ = self.stepKey(h.key, -1),
            .color_well => self.pickColor(h.key),
            .color_reset => _ = self.resetKey(h.key),
            .flag => {
                const opts = self.flagOptions(h.key);
                if (h.index < opts.len) {
                    const r = self.reader() orelse return;
                    const on = controls.flagState(r.value(h.key), opts[h.index]) orelse false;
                    _ = self.setFlag(h.key, opts[h.index], !on);
                }
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

/// A press on a slider's track: the knob jumps there and follows the
/// mouse; the value is written once, on release (Mac's `onEditingChanged`).
fn beginSlide(self: *SettingsWindow, key: []const u8, track: Rect, x: i32) void {
    self.commitEdit();
    self.slide_key = key;
    self.slide_track = track;
    self.slideMove(x);
    _ = w32.SetCapture(self.hwnd);
}

fn slideMove(self: *SettingsWindow, x: i32) void {
    const key = self.slide_key orelse return;
    const row = controlRow(key, .slider) orelse return;
    const sl = row.control.slider;
    const knob = layout.px(14, self.scale);
    const ux = self.slide_track.x + @divTrunc(knob, 2);
    const uw = @max(1, self.slide_track.w - knob);
    const frac = @as(f64, @floatFromInt(x - ux)) / @as(f64, @floatFromInt(uw));
    self.slide_preview = controls.valueAt(frac, sl.min, sl.max, sl.step);
    self.invalidate();
}

fn endSlide(self: *SettingsWindow) void {
    const key = self.slide_key orelse return;
    const v = self.slide_preview;
    self.slide_key = null;
    self.slide_preview = null;
    if (w32.GetCapture() == self.hwnd) _ = w32.ReleaseCapture();
    if (v) |value| _ = self.slideTo(key, value) else self.invalidate();
}

fn onMouseMove(self: *SettingsWindow, x: i32, y: i32) void {
    if (self.slide_key != null) {
        self.slideMove(x);
        return;
    }
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
            if (self.slide_key != null) {
                self.slideMove(loWordSigned(lparam));
                self.endSlide();
                return 0;
            }
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
        w32.WM_TIMER => {
            if (wparam == toast_timer_id) {
                self.onToastTimer();
                return 0;
            }
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
