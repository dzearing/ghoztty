//! The keyboard shortcut guide window (T2591) - the win32 counterpart of
//! Mac's `ShortcutGuideController` + `ShortcutGuideView`
//! (docs/reference/keyboard-shortcuts.md).
//!
//! Opened by Help > Keyboard Shortcuts, the `show_keyboard_shortcuts` action
//! (Ctrl+Shift+/ here: Mac's Cmd+/ carried the way every Cmd chord in the
//! Windows defaults is, Cmd -> Ctrl+Shift; plain Ctrl+/ is the shell's ^_
//! undo) or the command palette's "Show Keyboard Shortcuts".
//!
//! One window per process, reused, a plain top-level `WS_OVERLAPPEDWINDOW`
//! like What's New: the user can leave it open behind the terminal. Layout:
//! categories with live counts in a sidebar, a search field over a scrolling
//! list of shortcut rows grouped by category, and a footer with the counts,
//! "Open Config File" and "Print Cheat Sheet\u{2026}".
//!
//! Every row comes from `shortcut_catalog.zig`, built from the LIVE config
//! (`App.config`) against a freshly built default config, so a rebind, an
//! unbind or a key table shows up as it is; the catalog is rebuilt when the
//! config changes (`configChanged`, from App's `config_change`).
//!
//! The search field is drawn here rather than being an EDIT child: the guide
//! routes every key itself (Mac's local key monitor does the same) - typing
//! filters, Up/Down move the selection even while typing, Enter runs it, Esc
//! clears the search, then the selection, then closes.
//!
//! Instrumentation: the debug-only `shortcut-guide` IPC action
//! (`ipc_shortcut_guide.zig`) drives this window and reports its model, which
//! is what `test/win32/shortcut-guide.ps1` asserts.

const ShortcutGuideWindow = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Window = @import("Window.zig");
const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const keybind_list = @import("../../config/keybind_list.zig");
const catalog_mod = @import("shortcut_catalog.zig");
const layout = @import("shortcut_guide_layout.zig");
const notes_render = @import("whats_new_notes.zig");
const panel_theme = @import("panel_theme.zig");
const system_colors = @import("system_colors.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const Catalog = catalog_mod.Catalog;
const Category = catalog_mod.Category;
const Row = catalog_mod.Row;
const Rect = layout.Rect;
const dip = layout.dip;

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyShortcutGuide");
/// Mac's window title (`ShortcutGuideController`).
const TITLE = std.unicode.utf8ToUtf16LeStringLiteral("Keyboard Shortcuts");

var class_registered: bool = false;
/// The open window, if any. GUI thread only.
var active: ?*ShortcutGuideWindow = null;

/// One painted line of the list: a category header or a row.
const Item = struct {
    y: i32,
    h: i32,
    /// Index into `rows`, or null for a category header.
    row: ?usize,
    category: Category,
};

app: *App,
hwnd: w32.HWND,
scale: f32,
/// Fonts and text drawing, shared with What's New.
text: notes_render.Renderer,
/// Owns the catalog (rebuilt on config change).
catalog_arena: std.heap.ArenaAllocator,
catalog: Catalog = .{ .rows = &.{} },
/// Owns `rows`, `items` and the counts (rebuilt on every filter change).
view_arena: std.heap.ArenaAllocator,
rows: []const Row = &.{},
items: []const Item = &.{},
counts: [Category.count]usize = @splat(0),
all_count: usize = 0,
bound_total: usize = 0,
customized_total: usize = 0,

query_buf: [256]u8 = undefined,
query_len: usize = 0,
/// Null is "All Shortcuts".
category: ?Category = null,
include_unbound: bool = false,
/// Index into `rows`.
selection: ?usize = null,
hover: ?usize = null,
hover_run: bool = false,
scroll: i32 = 0,
content_h: i32 = 0,
thumb_drag_dy: i32 = -1,
tracking_leave: bool = false,
/// The terminal window the guide was opened from: the first choice for
/// running a row (Mac's `TerminalController.preferredParent`).
owner: ?w32.HWND = null,
/// The last action a Run performed, and where - the IPC seam reports it.
last_run: [128]u8 = undefined,
last_run_len: usize = 0,

// Hit rects recorded by the last paint.
run_rect: ?Rect = null,
clear_rect: ?Rect = null,
config_link_rect: ?Rect = null,
print_rect: ?Rect = null,

// ---------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------

/// Open the guide, or focus the one already open.
pub fn open(app: *App, window: ?*Window) void {
    if (window) |w| openFor(app, w.hwnd, w.scale) else openFor(app, null, 1.0);
}

pub fn openFor(app: *App, owner: ?w32.HWND, scale: f32) void {
    if (active) |existing| {
        if (owner) |o| existing.owner = o;
        _ = w32.ShowWindow(existing.hwnd, w32.SW_SHOW);
        _ = w32.SetForegroundWindow(existing.hwnd);
        return;
    }
    registerClass(app) orelse return;
    const alloc = app.core_app.alloc;
    const self = alloc.create(ShortcutGuideWindow) catch return;
    self.* = .{
        .app = app,
        .hwnd = undefined,
        .scale = scale,
        .text = .init(alloc, scale, .spacious, system_colors.panelFor(app)),
        .catalog_arena = .init(alloc),
        .view_arena = .init(alloc),
        .owner = owner,
        .include_unbound = loadIncludeUnbound(alloc),
    };
    self.rebuildCatalog();

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
    const hwnd = w32.CreateWindowExW(0, CLASS_NAME, TITLE, style, x, y, ow, oh, null, null, app.hinstance, null) orelse {
        self.destroyState();
        return;
    };
    self.hwnd = hwnd;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    system_colors.applyPanelChrome(hwnd, self.pal());
    active = self;
    self.refresh();
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    log.info("shortcut guide: opened rows={d} bound={d} customized={d}", .{
        self.catalog.rows.len, self.bound_total, self.customized_total,
    });
}

fn destroyState(self: *ShortcutGuideWindow) void {
    const alloc = self.app.core_app.alloc;
    self.text.deinit();
    self.view_arena.deinit();
    self.catalog_arena.deinit();
    alloc.destroy(self);
}

fn close(self: *ShortcutGuideWindow) void {
    active = null;
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    self.destroyState();
}

/// App shutdown.
pub fn closeAll() void {
    if (active) |a| a.close();
}

pub fn current() ?*ShortcutGuideWindow {
    return active;
}

/// The config changed (App's `config_change`): rebuild from the new one, so
/// a reloaded rebind shows up live.
pub fn configChanged() void {
    const self = active orelse return;
    self.rebuildCatalog();
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

/// Effective bindings from the live config; defaults from a fresh one.
fn rebuildCatalog(self: *ShortcutGuideWindow) void {
    _ = self.catalog_arena.reset(.retain_capacity);
    const arena = self.catalog_arena.allocator();
    const effective = keybind_list.entries(arena, &self.app.config.keybind) catch &.{};
    var defaults: []const catalog_mod.Entry = &.{};
    if (configpkg.Config.default(self.app.core_app.alloc)) |cfg_val| {
        var cfg = cfg_val;
        defer cfg.deinit();
        cfg.finalize() catch {};
        defaults = keybind_list.entries(arena, &cfg.keybind) catch &.{};
        // `entries` dupes everything into `arena`, so the strings outlive cfg.
    } else |_| {}
    self.catalog = Catalog.build(arena, effective, defaults) catch .{ .rows = &.{} };
}

pub fn query(self: *const ShortcutGuideWindow) []const u8 {
    return self.query_buf[0..self.query_len];
}

fn options(self: *const ShortcutGuideWindow) Catalog.Options {
    return .{ .query = self.query(), .category = self.category, .include_unbound = self.include_unbound };
}

/// Re-filter, re-count and re-lay-out the list.
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
    self.hover = null;
    self.layoutItems();
    self.scroll = layout.clampScroll(self.scroll, self.content_h, self.listRect().h);
    if (self.isWindow()) _ = w32.InvalidateRect(self.hwnd, null, 0);
}

fn isWindow(self: *const ShortcutGuideWindow) bool {
    return active == self;
}

fn rowHeight(self: *const ShortcutGuideWindow) i32 {
    const pad = layout.px(dip.row_pad_y, self.scale);
    return pad + self.text.lineHeight(.body) + layout.px(2, self.scale) + self.text.lineHeight(.caption) + pad;
}

fn layoutItems(self: *ShortcutGuideWindow) void {
    const arena = self.view_arena.allocator();
    var list: std.ArrayList(Item) = .empty;
    var y: i32 = 0;
    const header_h = layout.px(dip.header_h, self.scale);
    const row_h = self.rowHeight();
    var current_cat: ?Category = null;
    for (self.rows, 0..) |r, i| {
        if (current_cat != r.category) {
            list.append(arena, .{ .y = y, .h = header_h, .row = null, .category = r.category }) catch break;
            y += header_h;
            current_cat = r.category;
        }
        list.append(arena, .{ .y = y, .h = row_h, .row = i, .category = r.category }) catch break;
        y += row_h;
    }
    self.items = list.items;
    self.content_h = y + layout.px(dip.gap, self.scale);
}

// ---------------------------------------------------------------------
// Commands (the window's verbs; the IPC seam calls these too)
// ---------------------------------------------------------------------

pub fn setQuery(self: *ShortcutGuideWindow, text: []const u8) void {
    const n = @min(text.len, self.query_buf.len);
    @memcpy(self.query_buf[0..n], text[0..n]);
    self.query_len = n;
    // Typing a query always searches every category (Mac).
    if (n > 0) self.category = null;
    self.scroll = 0;
    self.refresh();
    self.selection = if (n > 0 and self.rows.len > 0) 0 else null;
    self.invalidate();
}

pub fn setCategory(self: *ShortcutGuideWindow, cat: ?Category) void {
    self.query_len = 0;
    self.category = cat;
    self.selection = null;
    self.scroll = 0;
    self.refresh();
}

pub fn setIncludeUnbound(self: *ShortcutGuideWindow, on: bool) void {
    self.include_unbound = on;
    saveIncludeUnbound(self.app.core_app.alloc, on);
    self.refresh();
}

pub fn moveSelection(self: *ShortcutGuideWindow, delta: i32) void {
    if (self.rows.len == 0) return;
    const last: i32 = @intCast(self.rows.len - 1);
    const next: i32 = if (self.selection) |s|
        std.math.clamp(@as(i32, @intCast(s)) + delta, 0, last)
    else if (delta > 0) 0 else last;
    self.selection = @intCast(next);
    self.scrollSelectionIntoView();
    self.invalidate();
}

/// Run the selected row when it is runnable. Returns whether it ran.
pub fn runSelection(self: *ShortcutGuideWindow) bool {
    const sel = self.selection orelse return false;
    if (sel >= self.rows.len) return false;
    return self.runRow(self.rows[sel]);
}

pub fn selectedRow(self: *const ShortcutGuideWindow) ?Row {
    const sel = self.selection orelse return null;
    if (sel >= self.rows.len) return null;
    return self.rows[sel];
}

pub fn lastRun(self: *const ShortcutGuideWindow) []const u8 {
    return self.last_run[0..self.last_run_len];
}

/// Esc: clear the search, then the selection, then close (Mac).
pub fn escape(self: *ShortcutGuideWindow) void {
    if (self.query_len > 0) {
        self.setQuery("");
    } else if (self.selection != null) {
        self.selection = null;
        self.invalidate();
    } else {
        self.close();
    }
}

/// The terminal window a Run goes to: the window the guide was opened from
/// while it is still open, else the highest of ours in the z-order below
/// the guide (the most recently used one), else the first.
fn targetWindow(self: *ShortcutGuideWindow) ?*Window {
    if (self.owner) |o| if (self.windowFor(o)) |w| return w;
    var h: ?w32.HWND = w32.GetWindow(self.hwnd, w32.GW_HWNDNEXT);
    var guard: usize = 0;
    while (h) |hw| : (guard += 1) {
        if (guard > 4096) break;
        if (self.windowFor(hw)) |w| return w;
        h = w32.GetWindow(hw, w32.GW_HWNDNEXT);
    }
    for (self.app.windows.items) |w| if (!w.is_quick_terminal) return w;
    return null;
}

fn windowFor(self: *ShortcutGuideWindow, hwnd: w32.HWND) ?*Window {
    for (self.app.windows.items) |w| {
        if (w.is_quick_terminal) continue;
        if (w.hwnd) |wh| if (wh == hwnd) return w;
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
    if (win.hwnd) |wh| _ = w32.SetForegroundWindow(wh);
    _ = surface.core_surface.performBindingAction(action) catch |err| {
        log.warn("shortcut guide: run {s} failed err={}", .{ row.action(), err });
        return false;
    };
    const n = @min(row.action().len, self.last_run.len);
    @memcpy(self.last_run[0..n], row.action()[0..n]);
    self.last_run_len = n;
    log.info("shortcut guide: ran {s}", .{row.action()});
    return true;
}

/// Write the cheat sheet to `%TEMP%` and return its path (caller frees).
pub fn writeCheatSheet(self: *ShortcutGuideWindow, alloc: Allocator) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try self.catalog.visible(arena, .{});
    const html = try catalog_mod.cheatSheetHtml(arena, rows);
    const tmp = try std.process.getEnvVarOwned(arena, "TEMP");
    const path = try std.fs.path.join(alloc, &.{ tmp, if (build_config.is_debug) "ghoztty-shortcuts-debug.html" else "ghoztty-shortcuts.html" });
    errdefer alloc.free(path);
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(html);
    return path;
}

/// Paint the client area into a DIB and save it as a PNG (the debug IPC
/// seam's `shot`): the window is on a background desktop in tests, where no
/// cross-process capture sees it.
pub fn snapshot(self: *ShortcutGuideWindow, alloc: Allocator, path: []const u8) !void {
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

fn printCheatSheet(self: *ShortcutGuideWindow) void {
    const alloc = self.app.core_app.alloc;
    const path = self.writeCheatSheet(alloc) catch |err| {
        log.warn("shortcut guide: cheat sheet failed err={}", .{err});
        return;
    };
    defer alloc.free(path);
    self.app.openUrl(path);
}

// ---------------------------------------------------------------------
// The "Show unbound actions" preference (Mac: ShortcutGuideIncludeUnbound)
// ---------------------------------------------------------------------

fn prefPath(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{
        dir,
        "ghoztty",
        if (build_config.is_debug) "shortcut-guide-unbound-debug" else "shortcut-guide-unbound",
    }) catch null;
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
    if (std.fs.path.dirname(path)) |dir| std.fs.makeDirAbsolute(dir) catch {};
    const f = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
    defer f.close();
    f.writeAll(if (on) "1" else "0") catch {};
}

// ---------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------

fn pal(self: *const ShortcutGuideWindow) panel_theme.Panel {
    return system_colors.panelFor(self.app);
}

fn clientRect(self: *const ShortcutGuideWindow) w32.RECT {
    var rc: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (self.isWindow()) _ = w32.GetClientRect(self.hwnd, &rc);
    return rc;
}

fn frame(self: *const ShortcutGuideWindow) layout.Frame {
    const rc = self.clientRect();
    return layout.frameFor(self.scale, rc.right - rc.left, rc.bottom - rc.top);
}

fn listRect(self: *const ShortcutGuideWindow) Rect {
    return self.frame().list;
}

fn invalidate(self: *ShortcutGuideWindow) void {
    if (self.isWindow()) _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// The sidebar's entries in slot order: All, then every category that is
/// not empty-and-Other (Other only shows when something lands in it).
fn sidebarSlots(self: *const ShortcutGuideWindow, out: *[Category.count + 1]?Category) []const ?Category {
    var n: usize = 0;
    out[n] = null;
    n += 1;
    for (std.enums.values(Category)) |c| {
        if (c == .other and self.counts[@intFromEnum(c)] == 0) continue;
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

fn slotRect(self: *const ShortcutGuideWindow, f: layout.Frame, slot: usize) Rect {
    // "All Shortcuts" sits above the "Categories" label; the rest below it.
    if (slot == 0) return layout.categoryRow(self.scale, f, 0, false);
    return layout.categoryRow(self.scale, f, slot, true);
}

fn scrollSelectionIntoView(self: *ShortcutGuideWindow) void {
    const sel = self.selection orelse return;
    const view = self.listRect();
    for (self.items, 0..) |it, idx| {
        if (it.row != sel) continue;
        // Keep the category header in view above the first row of a section.
        const top = if (idx > 0 and self.items[idx - 1].row == null) self.items[idx - 1].y else it.y;
        if (top < self.scroll) self.scroll = top;
        if (it.y + it.h > self.scroll + view.h) self.scroll = it.y + it.h - view.h;
        self.scroll = layout.clampScroll(self.scroll, self.content_h, view.h);
        return;
    }
}

fn scrollBy(self: *ShortcutGuideWindow, dy: i32) void {
    const next = layout.clampScroll(self.scroll + dy, self.content_h, self.listRect().h);
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

fn paint(self: *ShortcutGuideWindow, hdc_screen: w32.HDC) void {
    const rc = self.clientRect();
    const w = rc.right - rc.left;
    const h = rc.bottom - rc.top;
    if (w <= 0 or h <= 0) return;
    // Double-buffered: the list repaints on every keystroke.
    const mem = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem);
    const bmp = w32.CreateCompatibleBitmap(hdc_screen, w, h) orelse return;
    defer _ = w32.DeleteObject(bmp);
    const old = w32.SelectObject(mem, bmp);
    defer _ = w32.SelectObject(mem, old);

    const p = self.pal();
    self.text.palette = p;
    _ = w32.SetBkMode(mem, w32.TRANSPARENT);
    const f = layout.frameFor(self.scale, w, h);
    fillRect(mem, .{ .x = 0, .y = 0, .w = w, .h = h }, cr(p.bg));
    self.paintSidebar(mem, f, p);
    fillRect(mem, f.rule, cr(p.divider));
    self.paintSearch(mem, f, p);
    self.paintList(mem, f, p);
    fillRect(mem, f.footer_rule, cr(p.divider));
    self.paintFooter(mem, f, p);
    _ = w32.BitBlt(hdc_screen, 0, 0, w, h, mem, 0, 0, w32.SRCCOPY);
}

fn paintSidebar(self: *ShortcutGuideWindow, hdc: w32.HDC, f: layout.Frame, p: panel_theme.Panel) void {
    fillRect(hdc, f.sidebar, cr(p.header));
    const pad = layout.px(dip.gap, self.scale);
    const radius = layout.px(dip.radius_button, self.scale);
    var slots_buf: [Category.count + 1]?Category = undefined;
    const slots = self.sidebarSlots(&slots_buf);
    for (slots, 0..) |slot, i| {
        const r = self.slotRect(f, i);
        const selected = slot == self.category;
        const count = if (slot) |c| self.counts[@intFromEnum(c)] else self.all_count;
        if (selected) roundRect(hdc, r, radius, cr(p.select), null, 1);
        const lh = self.text.lineHeight(.body);
        const ty = r.y + @divTrunc(r.h - lh, 2);
        const fg = if (selected) cr(p.text_on_select) else if (count == 0 and slot != null) cr(p.secondary) else cr(p.text);
        _ = self.text.drawText(hdc, r.x + pad, ty, if (slot) |c| c.title() else "All Shortcuts", .{ .bold = selected }, .body, fg, true);
        if (count > 0) {
            var nb: [16]u8 = undefined;
            const ns = std.fmt.bufPrint(&nb, "{d}", .{count}) catch "";
            const cw = self.text.measure(hdc, ns, .{}, .caption).cx;
            const ch = self.text.lineHeight(.caption);
            _ = self.text.drawText(hdc, r.x + r.w - pad - cw, r.y + @divTrunc(r.h - ch, 2), ns, .{}, .caption, if (selected) cr(p.secondary_on_select) else cr(p.secondary), true);
        }
        if (i == 0) {
            // The "Categories" label between All and the first category.
            const lr = layout.categoryRow(self.scale, f, 1, false);
            const ch = self.text.lineHeight(.caption);
            _ = self.text.drawText(hdc, lr.x + pad, lr.y + @divTrunc(layout.px(dip.cat_label_h, self.scale) - ch, 2), "Categories", .{ .bold = true }, .caption, cr(p.label), true);
        }
    }

    // "Show unbound actions".
    const box = f.check;
    if (self.include_unbound) {
        roundRect(hdc, box, radius, cr(p.accent), null, 1);
        const mark = "\u{2713}";
        const mw = self.text.measure(hdc, mark, .{ .bold = true }, .caption).cx;
        const mh = self.text.lineHeight(.caption);
        _ = self.text.drawText(hdc, box.x + @divTrunc(box.w - mw, 2), box.y + @divTrunc(box.h - mh, 2), mark, .{ .bold = true }, .caption, cr(p.on_accent), true);
    } else {
        roundRect(hdc, box, radius, cr(p.field), cr(p.boundary), @max(1, layout.px(1, self.scale)));
    }
    const lh = self.text.lineHeight(.body);
    _ = self.text.drawText(hdc, box.x + box.w + pad, f.check_row.y + @divTrunc(f.check_row.h - lh, 2), "Show unbound actions", .{}, .body, cr(p.secondary), true);
}

fn paintSearch(self: *ShortcutGuideWindow, hdc: w32.HDC, f: layout.Frame, p: panel_theme.Panel) void {
    const r = f.search;
    const radius = layout.px(dip.radius_button, self.scale);
    const focused = w32.GetFocus() == self.hwnd;
    const ring = if (focused) @max(2, layout.px(2, self.scale)) else @max(1, layout.px(1, self.scale));
    roundRect(hdc, r, radius, cr(p.field), if (focused) cr(p.accent) else cr(p.boundary), ring);
    const pad = layout.px(dip.gap, self.scale) + layout.px(dip.tight, self.scale);
    const lh = self.text.lineHeight(.body);
    const ty = r.y + @divTrunc(r.h - lh, 2);
    var x = r.x + pad;
    if (self.query_len == 0) {
        _ = self.text.drawText(hdc, x, ty, "Search actions or keys (e.g. Ctrl+D, split)", .{}, .body, cr(p.secondary), true);
        self.clear_rect = null;
    } else {
        x += self.text.drawText(hdc, x, ty, self.query(), .{}, .body, cr(p.text), true);
        // The clear button: a glyph in a square hit box at the trailing edge.
        const glyph = "\u{2715}";
        const gw = self.text.measure(hdc, glyph, .{}, .caption).cx;
        const box = r.h;
        const hit: Rect = .{ .x = r.x + r.w - box, .y = r.y, .w = box, .h = box };
        const ch = self.text.lineHeight(.caption);
        _ = self.text.drawText(hdc, hit.x + @divTrunc(hit.w - gw, 2), hit.y + @divTrunc(hit.h - ch, 2), glyph, .{}, .caption, cr(p.secondary), true);
        self.clear_rect = hit;
    }
    if (focused) {
        // The caret: a filled bar, never a pen stroke.
        const cw: i32 = @max(1, layout.px(1, self.scale));
        fillRect(hdc, .{ .x = x + (if (self.query_len == 0) -cw else cw), .y = ty, .w = cw, .h = lh }, cr(p.text));
    }
}

fn paintList(self: *ShortcutGuideWindow, hdc: w32.HDC, f: layout.Frame, p: panel_theme.Panel) void {
    const view = f.list;
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    _ = w32.IntersectClipRect(hdc, view.x, view.y, view.x + view.w, view.y + view.h);
    self.run_rect = null;

    if (self.rows.len == 0) {
        const msg = if (self.query_len > 0) "No shortcuts match your search." else "No shortcuts in this category.";
        const mw = self.text.measure(hdc, msg, .{}, .body).cx;
        _ = self.text.drawText(hdc, view.x + @divTrunc(view.w - mw, 2), view.y + layout.px(dip.margin * 2, self.scale), msg, .{}, .body, cr(p.secondary), true);
        return;
    }

    const m = layout.px(dip.margin, self.scale);
    const sb_room = f.scrollbar.w + 2 * layout.px(dip.tight, self.scale);
    const left = view.x + m;
    const right = view.x + view.w - sb_room - m;
    for (self.items) |it| {
        const y = view.y + it.y - self.scroll;
        if (y + it.h < view.y or y > view.y + view.h) continue;
        if (it.row) |ri| {
            self.paintRow(hdc, p, self.rows[ri], ri, .{ .x = left - layout.px(dip.gap, self.scale), .y = y, .w = right - left + 2 * layout.px(dip.gap, self.scale), .h = it.h });
        } else {
            const lh = self.text.lineHeight(.strong);
            const ty = y + it.h - layout.px(dip.gap, self.scale) - lh;
            const tw = self.text.drawText(hdc, left, ty, it.category.title(), .{}, .strong, cr(p.text), true);
            if (it.category.subtitle()) |sub| {
                const ch = self.text.lineHeight(.caption);
                _ = self.text.drawText(hdc, left + tw + layout.px(dip.gap, self.scale), ty + lh - ch, sub, .{}, .caption, cr(p.secondary), true);
            }
        }
    }

    if (layout.thumb(self.scale, f.scrollbar, self.content_h, self.scroll)) |t| {
        roundRect(hdc, t, @divTrunc(t.w, 2), cr(p.boundary), null, 1);
    }
}

fn paintRow(self: *ShortcutGuideWindow, hdc: w32.HDC, p: panel_theme.Panel, row: Row, index: usize, r: Rect) void {
    const selected = self.selection == index;
    const hovered = self.hover == index;
    const radius = layout.px(dip.radius_button, self.scale);
    const tight = layout.px(dip.tight, self.scale);
    const inner: Rect = .{ .x = r.x, .y = r.y + @divTrunc(tight, 2), .w = r.w, .h = r.h - tight };
    if (selected) roundRect(hdc, inner, radius, cr(p.select), null, 1) else if (hovered) roundRect(hdc, inner, radius, cr(p.card), null, 1);
    const text_c = if (selected) cr(p.text_on_select) else cr(p.text);
    const sec_c = if (selected) cr(p.secondary_on_select) else cr(p.secondary);

    const pad_x = layout.px(dip.row_pad_x, self.scale);
    const pad_y = layout.px(dip.row_pad_y, self.scale);
    const x0 = r.x + pad_x;
    const title_lh = self.text.lineHeight(.body);
    const ty = r.y + pad_y;
    const dy = ty + title_lh + layout.px(2, self.scale);

    // Keycaps (or the unbound note) right-aligned; measured first so the
    // title and detail stop short of them.
    const caps_w = self.paintCaps(hdc, p, row, r.x + r.w - pad_x, r.y, r.h, selected, false);
    var text_right = r.x + r.w - pad_x - caps_w - layout.px(dip.margin, self.scale);

    // Run, offered on the selected or hovered runnable row.
    if (row.runnable and (selected or hovered)) {
        const label = "\u{25B6} Run";
        const lw = self.text.measure(hdc, label, .{}, .caption).cx;
        const bh = layout.px(dip.cap_h, self.scale);
        const bw = lw + 2 * layout.px(dip.button_pad_x, self.scale);
        const br: Rect = .{ .x = text_right - bw, .y = r.y + @divTrunc(r.h - bh, 2), .w = bw, .h = bh };
        const hot = hovered and self.hover_run;
        roundRect(hdc, br, radius, if (hot) cr(p.accent) else cr(p.field), cr(p.accent), @max(1, layout.px(1, self.scale)));
        const ch = self.text.lineHeight(.caption);
        _ = self.text.drawText(hdc, br.x + layout.px(dip.button_pad_x, self.scale), br.y + @divTrunc(bh - ch, 2), label, .{}, .caption, if (hot) cr(p.on_accent) else cr(p.accent), true);
        self.run_rect = br;
        text_right = br.x - layout.px(dip.gap, self.scale);
    }
    _ = self.paintCaps(hdc, p, row, r.x + r.w - pad_x, r.y, r.h, selected, true);

    const saved = w32.SaveDC(hdc);
    _ = w32.IntersectClipRect(hdc, x0, r.y, @max(x0, text_right), r.y + r.h);
    var x = x0 + self.text.drawText(hdc, x0, ty, row.title, .{ .bold = selected }, .body, text_c, true);

    // Badges after the title.
    const bh = layout.px(dip.badge_h, self.scale);
    const by = ty + @divTrunc(title_lh - bh, 2);
    const g = layout.px(dip.gap, self.scale);
    if (row.customized) x += g + self.badge(hdc, x + g, by, "CUSTOM", cr(p.accent), cr(p.on_accent), null);
    if (row.isGlobal()) x += g + self.badge(hdc, x + g, by, "GLOBAL", cr(p.field), sec_c, cr(p.boundary));
    if (row.table()) |t| {
        var tb: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&tb, "TABLE {s}", .{t}) catch "TABLE";
        x += g + self.badge(hdc, x + g, by, s, cr(p.field), sec_c, cr(p.boundary));
    }
    if (row.kind == .built_in) x += g + self.badge(hdc, x + g, by, "BUILT-IN", cr(p.field), sec_c, cr(p.boundary));
    _ = self.text.drawText(hdc, x0, dy, row.detail, .{}, .caption, sec_c, true);
    _ = w32.RestoreDC(hdc, saved);
}

fn badge(self: *ShortcutGuideWindow, hdc: w32.HDC, x: i32, y: i32, label: []const u8, fill: u32, fg: u32, border: ?u32) i32 {
    const pad = layout.px(dip.badge_pad_x, self.scale);
    const lw = self.text.measure(hdc, label, .{ .bold = true }, .caption).cx;
    const bh = layout.px(dip.badge_h, self.scale);
    const r: Rect = .{ .x = x, .y = y, .w = lw + 2 * pad, .h = bh };
    roundRect(hdc, r, layout.px(dip.radius_button, self.scale), fill, border, @max(1, layout.px(1, self.scale)));
    const ch = self.text.lineHeight(.caption);
    _ = self.text.drawText(hdc, x + pad, y + @divTrunc(bh - ch, 2), label, .{ .bold = true }, .caption, fg, true);
    return r.w;
}

/// Draw (or, with `draw` false, measure) a row's keycaps right-aligned at
/// `right`. Returns the width they take.
fn paintCaps(self: *ShortcutGuideWindow, hdc: w32.HDC, p: panel_theme.Panel, row: Row, right: i32, top: i32, h: i32, selected: bool, draw: bool) i32 {
    var arena_state: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sec_c = if (selected) cr(p.secondary_on_select) else cr(p.secondary);
    if (!row.isBound()) {
        const note = if (row.unbound_by_user) "Unbound in your config" else "Not bound";
        const nw = self.text.measure(hdc, note, .{ .italic = true }, .caption).cx;
        if (draw) {
            const ch = self.text.lineHeight(.caption);
            _ = self.text.drawText(hdc, right - nw, top + @divTrunc(h - ch, 2), note, .{ .italic = true }, .caption, sec_c, true);
        }
        return nw;
    }
    const cap_h = layout.px(dip.cap_h, self.scale);
    const cap_pad = layout.px(dip.cap_pad_x, self.scale);
    const tight = layout.px(dip.tight, self.scale);
    const g = layout.px(dip.gap, self.scale);
    const ch = self.text.lineHeight(.caption);
    const cy = top + @divTrunc(h - cap_h, 2);

    // At most three bindings drawn, the rest named as "+N" (they are all in
    // the cheat sheet). Mac wraps; a row here stays one line.
    const max_drawn: usize = 3;
    const shown = @min(row.bindings.len, max_drawn);
    var more_buf: [16]u8 = undefined;
    const more: []const u8 = if (row.bindings.len > shown)
        std.fmt.bufPrint(&more_buf, "+{d}", .{row.bindings.len - shown}) catch ""
    else
        "";

    // Total width first.
    var total: i32 = 0;
    for (row.bindings[0..shown], 0..) |b, bi| {
        if (bi > 0) total += g;
        const cs = catalog_mod.caps(arena, b) catch continue;
        for (cs, 0..) |c, ci| {
            if (ci > 0) total += tight;
            const lw = self.text.measure(hdc, c.label, .{}, .caption).cx;
            total += if (c.is_joiner) lw else @max(lw + 2 * cap_pad, cap_h);
        }
    }
    if (more.len > 0) total += g + self.text.measure(hdc, more, .{}, .caption).cx;
    if (!draw) return total;

    var x = right - total;
    for (row.bindings[0..shown], 0..) |b, bi| {
        if (bi > 0) x += g;
        const cs = catalog_mod.caps(arena, b) catch continue;
        for (cs, 0..) |c, ci| {
            if (ci > 0) x += tight;
            const lw = self.text.measure(hdc, c.label, .{}, .caption).cx;
            if (c.is_joiner) {
                _ = self.text.drawText(hdc, x, top + @divTrunc(h - ch, 2), c.label, .{}, .caption, sec_c, true);
                x += lw;
                continue;
            }
            const cw = @max(lw + 2 * cap_pad, cap_h);
            roundRect(hdc, .{ .x = x, .y = cy, .w = cw, .h = cap_h }, layout.px(dip.radius_button, self.scale), cr(p.field), cr(p.boundary), @max(1, layout.px(1, self.scale)));
            _ = self.text.drawText(hdc, x + @divTrunc(cw - lw, 2), cy + @divTrunc(cap_h - ch, 2), c.label, .{}, .caption, cr(p.text), true);
            x += cw;
        }
    }
    if (more.len > 0) _ = self.text.drawText(hdc, x + g, top + @divTrunc(h - ch, 2), more, .{}, .caption, sec_c, true);
    return total;
}

fn paintFooter(self: *ShortcutGuideWindow, hdc: w32.HDC, f: layout.Frame, p: panel_theme.Panel) void {
    const r = f.footer;
    const m = layout.px(dip.margin, self.scale);
    const g = layout.px(dip.gap, self.scale) + layout.px(dip.tight, self.scale);
    const ch = self.text.lineHeight(.caption);
    const ty = r.y + @divTrunc(r.h - ch, 2);
    var buf: [96]u8 = undefined;
    const counts = if (self.customized_total > 0)
        std.fmt.bufPrint(&buf, "{d} shortcuts \u{00B7} {d} customized", .{ self.bound_total, self.customized_total }) catch ""
    else
        std.fmt.bufPrint(&buf, "{d} shortcuts", .{self.bound_total}) catch "";
    var x = r.x + m;
    x += self.text.drawText(hdc, x, ty, counts, .{}, .caption, cr(p.secondary), true) + g;
    _ = self.text.drawText(hdc, x, ty, "\u{2191}\u{2193} select \u{00B7} Enter run \u{00B7} Esc close", .{}, .caption, cr(p.secondary), true);

    // Right: [Open Config File]  [Print Cheat Sheet...]
    const bh = layout.px(dip.button_h, self.scale);
    const bpad = layout.px(dip.button_pad_x, self.scale);
    const print_label = "Print Cheat Sheet\u{2026}";
    const pw = self.text.measure(hdc, print_label, .{}, .caption).cx + 2 * bpad;
    const pr: Rect = .{ .x = r.x + r.w - m - pw, .y = r.y + @divTrunc(r.h - bh, 2), .w = pw, .h = bh };
    roundRect(hdc, pr, layout.px(dip.radius_button, self.scale), cr(p.card), cr(p.card_border), @max(1, layout.px(1, self.scale)));
    _ = self.text.drawText(hdc, pr.x + bpad, pr.y + @divTrunc(bh - ch, 2), print_label, .{}, .caption, cr(p.text), true);
    self.print_rect = pr;

    const link = "Open Config File";
    const lw = self.text.measure(hdc, link, .{}, .caption).cx;
    const lr: Rect = .{ .x = pr.x - g - lw, .y = ty, .w = lw, .h = ch };
    _ = self.text.drawText(hdc, lr.x, lr.y, link, .{}, .caption, cr(p.accent), true);
    self.config_link_rect = lr;
}

// ---------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------

fn rowAt(self: *const ShortcutGuideWindow, x: i32, y: i32) ?usize {
    const view = self.listRect();
    if (!view.contains(x, y)) return null;
    const cy = y - view.y + self.scroll;
    for (self.items) |it| {
        if (cy >= it.y and cy < it.y + it.h) return it.row;
    }
    return null;
}

fn onLeftDown(self: *ShortcutGuideWindow, x: i32, y: i32, double: bool) void {
    const f = self.frame();
    if (self.clear_rect) |r| if (r.contains(x, y)) {
        self.setQuery("");
        return;
    };
    if (self.print_rect) |r| if (r.contains(x, y)) {
        self.printCheatSheet();
        return;
    };
    if (self.config_link_rect) |r| if (r.contains(x, y)) {
        self.app.openConfigFile();
        return;
    };
    if (f.check_row.contains(x, y)) {
        self.setIncludeUnbound(!self.include_unbound);
        return;
    }
    var slots_buf: [Category.count + 1]?Category = undefined;
    for (self.sidebarSlots(&slots_buf), 0..) |slot, i| {
        if (self.slotRect(f, i).contains(x, y)) {
            self.setCategory(slot);
            return;
        }
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
    if (self.run_rect) |r| if (r.contains(x, y)) {
        _ = self.runSelectionAt(self.rowAt(x, y));
        return;
    };
    if (self.rowAt(x, y)) |ri| {
        self.selection = ri;
        self.invalidate();
        if (double) _ = self.runRow(self.rows[ri]);
    }
}

fn runSelectionAt(self: *ShortcutGuideWindow, ri: ?usize) bool {
    const i = ri orelse return false;
    self.selection = i;
    return self.runRow(self.rows[i]);
}

fn onMouseMove(self: *ShortcutGuideWindow, x: i32, y: i32) void {
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
    const over_run = if (self.run_rect) |r| r.contains(x, y) else false;
    if (over != self.hover or over_run != self.hover_run) {
        self.hover = over;
        self.hover_run = over_run;
        self.invalidate();
    }
    const hand = over_run or
        (if (self.config_link_rect) |r| r.contains(x, y) else false) or
        (if (self.print_rect) |r| r.contains(x, y) else false);
    _ = w32.SetCursor(w32.LoadCursorW(null, if (hand) w32.IDC_HAND else w32.IDC_ARROW));
}

fn onKey(self: *ShortcutGuideWindow, vk: u16) bool {
    const page: i32 = @max(1, @divTrunc(self.listRect().h, @max(1, self.rowHeight())) - 1);
    switch (vk) {
        w32.VK_ESCAPE => self.escape(),
        w32.VK_DOWN => self.moveSelection(1),
        w32.VK_UP => self.moveSelection(-1),
        w32.VK_NEXT => self.moveSelection(page),
        w32.VK_PRIOR => self.moveSelection(-page),
        w32.VK_RETURN => _ = self.runSelection(),
        else => return false,
    }
    return true;
}

fn onChar(self: *ShortcutGuideWindow, ch: u16) void {
    switch (ch) {
        // Backspace: one codepoint.
        0x08 => {
            var n = self.query_len;
            while (n > 0) {
                n -= 1;
                if (self.query_buf[n] & 0xC0 != 0x80) break;
            }
            var tmp: [256]u8 = undefined;
            @memcpy(tmp[0..n], self.query_buf[0..n]);
            self.setQuery(tmp[0..n]);
        },
        // Ctrl+Backspace: the last word.
        0x7F => {
            var n = self.query_len;
            while (n > 0 and self.query_buf[n - 1] == ' ') n -= 1;
            while (n > 0 and self.query_buf[n - 1] != ' ') n -= 1;
            var tmp: [256]u8 = undefined;
            @memcpy(tmp[0..n], self.query_buf[0..n]);
            self.setQuery(tmp[0..n]);
        },
        // Ctrl+V.
        0x16 => self.pasteClipboard(),
        else => {
            if (ch < 0x20) return;
            // Surrogates arrive as two WM_CHARs; the guide's search is for
            // action names and keys, so a lone surrogate is dropped.
            if (ch >= 0xD800 and ch <= 0xDFFF) return;
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(ch, &enc) catch return;
            if (self.query_len + n > self.query_buf.len) return;
            var tmp: [256]u8 = undefined;
            @memcpy(tmp[0..self.query_len], self.query_buf[0..self.query_len]);
            @memcpy(tmp[self.query_len..][0..n], enc[0..n]);
            self.setQuery(tmp[0 .. self.query_len + n]);
        },
    }
}

fn pasteClipboard(self: *ShortcutGuideWindow) void {
    if (w32.OpenClipboard(self.hwnd) == 0) return;
    defer _ = w32.CloseClipboard();
    const hmem = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return;
    const ptr = w32.GlobalLock(hmem) orelse return;
    defer _ = w32.GlobalUnlock(hmem);
    const wide: [*:0]const u16 = @ptrCast(@alignCast(ptr));
    const wslice = std.mem.sliceTo(wide, 0);
    var tmp: [256]u8 = undefined;
    @memcpy(tmp[0..self.query_len], self.query_buf[0..self.query_len]);
    var n = self.query_len;
    for (wslice) |wc| {
        // One line: stop at the first line break.
        if (wc == '\r' or wc == '\n') break;
        if (wc < 0x20 or (wc >= 0xD800 and wc <= 0xDFFF)) continue;
        var enc: [4]u8 = undefined;
        const k = std.unicode.utf8Encode(wc, &enc) catch continue;
        if (n + k > tmp.len) break;
        @memcpy(tmp[n..][0..k], enc[0..k]);
        n += k;
    }
    self.setQuery(tmp[0..n]);
}

// ---------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *ShortcutGuideWindow = @ptrFromInt(@as(usize, @bitCast(userdata)));

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
            self.scroll = layout.clampScroll(self.scroll, self.content_h, self.listRect().h);
            self.invalidate();
            return 0;
        },
        w32.WM_SETFOCUS, w32.WM_KILLFOCUS => {
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
            self.onLeftDown(loWordSigned(lparam), hiWordSigned(lparam), msg == w32.WM_LBUTTONDBLCLK);
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
        w32.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            if (self.hover != null) {
                self.hover = null;
                self.hover_run = false;
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
