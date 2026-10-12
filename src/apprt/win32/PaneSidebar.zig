//! The pane sidebar on Windows (T1828; Mac 597a193cc, `PaneSidebarView`,
//! `docs/design/pane-sidebar.md`): a child of the window, left of the split
//! grid, listing every pane of the active tab — the panes in the grid with the
//! focused one selected, then the stashed ones (T1827).
//!
//! Pinned, it is a flat panel down the window's side: one more column of the
//! window, on the terminal background lifted by the card wash, separated from
//! the grid by a divider-colored rule. Unpinned, it is the raised card the
//! banner and the viewer side panel use, collapsed to the mini rail — one
//! 28 DIP tile per pane, each labeled with a monogram. Hidden
//! (`toggle_pane_sidebar`), it takes no space.
//!
//! Clicking a row focuses that pane, or restores it when it is stashed. A
//! row's hover button stashes a grid pane or restores a stashed one. The pin
//! flips panel and rail. Everything about modes, widths, text and geometry is
//! `pane_sidebar.zig`, which is unit-tested without a window; this file only
//! paints what that decides and routes the clicks back to `Window`.
//!
//! Unpinned, the rail opens on hover (T1842; Mac `PaneSidebarHostView`): with
//! the pointer on the rail's card for Mac's 100 ms intent delay, the card
//! grows to the panel's full width OVER the grid - in a second window, a
//! popup owned by the top-level, so the column (and every terminal beside it)
//! never resizes, and the card covers the panes' own popups (a dim overlay, a
//! banner strip) instead of being painted over by them. Leaving starts Mac's
//! 280 ms grace, after which it contracts unless the pointer came back or a
//! press on it is still held. Every tile, row, row button and the pin carries
//! a tooltip (Mac `.help`); a tile's names its pane, since the rail shows only
//! a monogram. The timing and wording rules are `pane_sidebar_hover.zig`.
//!
//! The roster is rebuilt only when what it shows changed — `refresh` hashes
//! the panes, their titles, banners, states and the selection first — because
//! it is asked on every layout pass, and a divider drag is a layout pass per
//! mouse move.

const PaneSidebar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const pane_sidebar = @import("pane_sidebar.zig");
const hov = @import("pane_sidebar_hover.zig");
const overlay_zorder = @import("overlay_zorder.zig");
const toc = @import("viewer_toc_layout.zig");
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const system_colors = @import("system_colors.zig");
const banner_card = @import("banner_card.zig");
const type_ramp = @import("type_ramp.zig");
const list_selection = @import("list_selection.zig");
const icon_button = @import("icon_button.zig");
const icon_button_paint = @import("icon_button_paint.zig");
const split_geometry = @import("split_geometry.zig");
const pane_drop = @import("pane_drop.zig");
const drop_highlight = @import("drop_highlight.zig");
const PaneView = @import("PaneView.zig");
const Window = @import("Window.zig");
const ActivityState = @import("../../terminal/main.zig").osc.Command.ActivityState;

const log = std.log.scoped(.pane_sidebar);

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyPaneSidebar");
/// The hover-open card's popup (T1842).
pub const CARD_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyPaneSidebarCard");

/// Timer ids, each on its own window: the intent delay on the rail, the
/// grace period on the card.
const TIMER_OPEN: usize = 1;
const TIMER_CLOSE: usize = 2;

/// Which of the sidebar's two windows a message or a paint is for.
const Surface = enum { rail, card };

/// Why the card opened or closed - logged, so the acceptance script can tell
/// the paths apart on a desktop where nothing can photograph a popup's life.
const CardReason = enum { hover, unpin, pin, left, mode, hidden };

/// Tooltip tool ids, per window: the pin, then one per item, then one per
/// row button.
const tool_pin: usize = 0;
fn toolItem(i: usize) usize {
    return 1 + i;
}
fn toolButton(i: usize) usize {
    return 1 + pane_sidebar.max_items + i;
}

/// What new windows start from: the most recently chosen pin and hidden
/// flags, the way a Finder window's sidebar does (Mac `rememberForNewWindows`).
/// Process lifetime for now; surviving a restart is T1847.
pub var remembered: struct { pinned: bool = false, hidden: bool = false } = .{};

/// Fluent / MDL2 codepoints (the same faces `icon_button_paint` probes).
const glyph_terminal: u16 = 0xE756; // CommandPrompt
const glyph_document: u16 = 0xE8A5; // Document
const glyph_globe: u16 = 0xE774; // Globe
const glyph_photo: u16 = 0xE91B; // Photo
const glyph_code: u16 = 0xE943; // Code
const glyph_pin: u16 = 0xE718; // Pin (unpinned: offer to pin)
const glyph_pinned: u16 = 0xE840; // Pinned
const glyph_stash: u16 = 0xE921; // ChromeMinimize: "put this away"
const glyph_restore: u16 = 0xE7A7; // Undo: "bring it back"

const Entry = struct {
    pane: *PaneView,
    section: pane_sidebar.Section,
    title: []u16,
    subtitle: []u16,
    mono: []u16,
    icon: u16,
    state: ActivityState,
    selected: bool,
};

hwnd: w32.HWND,
window: *Window,
alloc: Allocator,

entries: std.ArrayListUnmanaged(Entry) = .{},
signature: u64 = 0,

mode: pane_sidebar.Mode = .hidden,
scale: f32 = 1.0,
hover: pane_sidebar.Hit = .none,
pressed: pane_sidebar.Hit = .none,
tracking: bool = false,
/// Where the held press went down, in the pressed surface's client
/// coordinates: a press on a row that travels past the drag threshold hands
/// the pane to the window's drag (T1844).
press_x: i32 = 0,
press_y: i32 = 0,
/// A pane drag is live somewhere (T1844): the empty "Drop to stash" slot
/// shows while nothing is stashed, and the open card does not contract.
drag_active: bool = false,

// The hover-open card (T1842).
card_hwnd: ?w32.HWND = null,
card_open: bool = false,
card_tracking: bool = false,
open_armed: bool = false,

// Tooltips: one control, tools on both windows. A tile's text names its pane,
// so it lives here (a tool keeps a pointer to its text); every other tip is a
// constant.
tip: ?w32.HWND = null,
tip_text: [pane_sidebar.max_items][hov.tip_cap]u16 = undefined,
tip_items: [2]usize = .{ 0, 0 },
tip_log: [256]u8 = undefined,
tip_log_len: usize = 0,

title_font: ?*anyopaque = null,
caption_font: ?*anyopaque = null,
caption_bold_font: ?*anyopaque = null,
font_scale: f32 = 0,
metrics: pane_sidebar.TextMetrics = .{ .title_h = 19, .caption_h = 16 },

// The card material behind the rail and behind the open card, each cached
// like the TOC card's (two caches, or the two sizes would thrash one).
rail_card: CardCache = .{},
open_card: CardCache = .{},

const CardCache = struct {
    dc: ?w32.HDC = null,
    bmp: ?*anyopaque = null,
    w: i32 = 0,
    h: i32 = 0,
    bg: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    scale: f32 = 0,

    fn release(self: *CardCache) void {
        if (self.dc) |dc| _ = w32.DeleteDC(dc);
        if (self.bmp) |b| _ = w32.DeleteObject(b);
        self.* = .{};
    }
};

var class_registered: bool = false;
var card_class_registered: bool = false;

fn registerOne(hinstance: ?w32.HINSTANCE, name: [*:0]const u16) bool {
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // CS_HREDRAW | CS_VREDRAW (design system §5c): the panel's rule and
        // the cards are drawn against the window's own bounds.
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // every pixel painted in WM_PAINT
        .lpszMenuName = null,
        .lpszClassName = name,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("pane sidebar class registration failed", .{});
        return false;
    }
    return true;
}

fn registerClass(hinstance: ?w32.HINSTANCE) void {
    if (!class_registered) class_registered = registerOne(hinstance, CLASS_NAME);
    if (!card_class_registered) card_class_registered = registerOne(hinstance, CARD_CLASS_NAME);
}

/// Create the sidebar as a hidden child of `parent`. Null when the window
/// cannot be created: the window then lays its grid out without a column,
/// which is the pre-T1828 world rather than a crash.
pub fn create(alloc: Allocator, window: *Window, parent: w32.HWND) ?*PaneSidebar {
    const hinstance = w32.GetModuleHandleW(null);
    registerClass(hinstance);
    if (!class_registered) return null;
    const self = alloc.create(PaneSidebar) catch return null;
    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        parent,
        null,
        hinstance,
        null,
    ) orelse {
        alloc.destroy(self);
        return null;
    };
    self.* = .{ .hwnd = hwnd, .window = window, .alloc = alloc };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    return self;
}

pub fn destroy(self: *PaneSidebar) void {
    // Clear the back-pointer FIRST: DestroyWindow delivers messages
    // synchronously and they must not find a half-dead object.
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    if (self.card_hwnd) |c| {
        _ = w32.SetWindowLongPtrW(c, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(c);
    }
    if (self.tip) |t| _ = w32.DestroyWindow(t);
    _ = w32.DestroyWindow(self.hwnd);
    self.clearEntries();
    self.entries.deinit(self.alloc);
    self.rail_card.release();
    self.open_card.release();
    self.releaseFonts();
    self.alloc.destroy(self);
}

fn fromHwnd(hwnd: w32.HWND) ?*PaneSidebar {
    const v = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

// -------------------------------------------------------------------------
// State pushed by the window
// -------------------------------------------------------------------------

/// Place the column at `rect` (window client coordinates) in `mode`, hiding
/// it when there is nothing to show.
pub fn place(self: *PaneSidebar, rect: w32.RECT, mode: pane_sidebar.Mode, scale: f32) void {
    const changed = mode != self.mode or scale != self.scale;
    self.mode = mode;
    self.scale = scale;
    // Only the rail opens (Mac: leaving `.mini` clears `isHoverOpen`).
    if (mode != .mini) {
        self.disarm();
        self.closeCard(if (mode == .hidden) .hidden else .mode);
    }
    if (mode == .hidden or rect.right <= rect.left or rect.bottom <= rect.top) {
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        return;
    }
    var cur: w32.RECT = undefined;
    const moved = blk: {
        if (w32.GetWindowRect(self.hwnd, &cur) == 0) break :blk true;
        var tl = w32.POINT{ .x = cur.left, .y = cur.top };
        const parent = w32.GetParent(self.hwnd) orelse break :blk true;
        _ = w32.ScreenToClient(parent, &tl);
        break :blk tl.x != rect.left or tl.y != rect.top or
            cur.right - cur.left != rect.right - rect.left or
            cur.bottom - cur.top != rect.bottom - rect.top;
    };
    if (moved or w32.IsWindowVisible(self.hwnd) == 0) {
        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            w32.SWP_NOZORDER | w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW,
        );
    }
    if (changed) _ = w32.InvalidateRect(self.hwnd, null, 0);
    if (moved or changed) self.syncTips();
    // A relayout under the open card (a split, a stash from its own row
    // button) moves the column it grows from: keep it glued there.
    if (self.card_open) self.positionCard();
}

/// Re-read the roster from the window's active tab. Cheap when nothing it
/// shows has changed; repaints only when something did.
pub fn refresh(self: *PaneSidebar) void {
    const win = self.window;
    if (win.tab_count == 0) {
        if (self.entries.items.len != 0) {
            self.clearEntries();
            self.signature = 0;
            _ = w32.InvalidateRect(self.hwnd, null, 0);
        }
        return;
    }
    const tree = win.tab_trees[win.active_tab];
    const active = win.tab_active_pane[win.active_tab];
    var views: [pane_sidebar.max_items]*PaneView = undefined;
    const n = pane_sidebar.roster(tree, &views);

    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&n));
    for (views[0..n]) |v| {
        h.update(std.mem.asBytes(&v));
        h.update(std.mem.asBytes(&v.stash_seq));
        const sel: u8 = @intFromBool(v == active);
        h.update(std.mem.asBytes(&sel));
        if (v.title()) |t| h.update(t);
        h.update("\x00");
        switch (v.kind) {
            .terminal => |s| {
                h.update(std.mem.asBytes(&s.activity_state));
                if (s.banner_text) |b| h.update(b);
                h.update("\x00");
                if (s.pwd) |p| h.update(p);
            },
            .viewer => |vp| {
                h.update(std.mem.asBytes(&vp.mode));
                if (vp.location) |l| h.update(l);
            },
        }
        h.update("\x01");
    }
    const sig = h.final();
    if (sig == self.signature) return;
    self.signature = sig;
    self.rebuild(views[0..n], active);
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    if (self.card_open) {
        // More or fewer rows: the card is as tall as before, but its region
        // and rows are re-derived with it.
        self.positionCard();
        if (self.card_hwnd) |c| _ = w32.InvalidateRect(c, null, 0);
    }
    self.syncTips();
}

fn clearEntries(self: *PaneSidebar) void {
    for (self.entries.items) |e| {
        self.alloc.free(e.title);
        self.alloc.free(e.subtitle);
        self.alloc.free(e.mono);
    }
    self.entries.clearRetainingCapacity();
}

fn rebuild(self: *PaneSidebar, views: []const *PaneView, active: *PaneView) void {
    self.clearEntries();
    var home_buf: [512]u8 = undefined;
    const home = std.process.getEnvVarOwned(self.alloc, "USERPROFILE") catch null;
    defer if (home) |hm| self.alloc.free(hm);
    for (views) |v| {
        const kind_name: []const u8 = if (v.isViewer()) "Viewer" else "Terminal";
        const pwd: ?[]const u8 = if (v.surface()) |s| (if (s.pwd) |p| p else null) else null;
        const title8 = pane_sidebar.displayTitle(if (v.title()) |t| t else null, pwd, kind_name);

        var line_buf: [512]u8 = undefined;
        const subtitle8: ?[]const u8 = blk: {
            switch (v.kind) {
                .terminal => |s| {
                    if (pane_sidebar.bannerLine(if (s.banner_text) |b| b else null, &line_buf)) |l| break :blk l;
                    if (pwd) |p| {
                        // A shell titled by its own directory (cmd and pwsh
                        // do that) would show the same place twice.
                        if (pane_sidebar.samePath(p, title8)) break :blk null;
                        break :blk pane_sidebar.abbreviatePath(p, home, &home_buf);
                    }
                    break :blk null;
                },
                .viewer => |vp| break :blk if (vp.location) |l| l else null,
            }
        };
        const sub8 = pane_sidebar.distinct(subtitle8, title8) orelse "";

        var mono_buf: [16]u8 = undefined;
        const mono8 = pane_sidebar.monogram(title8, &mono_buf);

        const title = std.unicode.utf8ToUtf16LeAlloc(self.alloc, title8) catch continue;
        const subtitle = std.unicode.utf8ToUtf16LeAlloc(self.alloc, sub8) catch {
            self.alloc.free(title);
            continue;
        };
        const mono = std.unicode.utf8ToUtf16LeAlloc(self.alloc, mono8) catch {
            self.alloc.free(title);
            self.alloc.free(subtitle);
            continue;
        };
        self.entries.append(self.alloc, .{
            .pane = v,
            .section = if (v.stash_seq != 0) .stashed else .grid,
            .title = title,
            .subtitle = subtitle,
            .mono = mono,
            .icon = iconFor(v),
            .state = if (v.surface()) |s| s.activity_state else .idle,
            .selected = v == active,
        }) catch {
            self.alloc.free(title);
            self.alloc.free(subtitle);
            self.alloc.free(mono);
        };
    }
}

fn iconFor(v: *const PaneView) u16 {
    const vp = v.viewer() orelse return glyph_terminal;
    return switch (vp.mode) {
        .markdown => glyph_document,
        .web => glyph_globe,
        .image => glyph_photo,
        else => glyph_code,
    };
}

// -------------------------------------------------------------------------
// Layout
// -------------------------------------------------------------------------

fn currentLayout(self: *PaneSidebar) pane_sidebar.Layout {
    return self.layoutFor(.rail);
}

fn surfaceHwnd(self: *const PaneSidebar, which: Surface) ?w32.HWND {
    return switch (which) {
        .rail => self.hwnd,
        .card => self.card_hwnd,
    };
}

fn layoutFor(self: *PaneSidebar, which: Surface) pane_sidebar.Layout {
    const hwnd = self.surfaceHwnd(which) orelse return .{};
    var r: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &r) == 0) return .{};
    var items: [pane_sidebar.max_items]pane_sidebar.Item = undefined;
    const n = @min(self.entries.items.len, items.len);
    for (self.entries.items[0..n], 0..) |e, i| {
        items[i] = .{ .section = e.section, .two_line = e.subtitle.len > 0 };
    }
    self.ensureFonts();
    var l = switch (which) {
        .rail => pane_sidebar.layout(self.mode, r.right - r.left, r.bottom - r.top, items[0..n], self.metrics, self.scale),
        .card => pane_sidebar.layoutOpen(r.right - r.left, r.bottom - r.top, items[0..n], self.metrics, self.scale),
    };
    if (self.drag_active) pane_sidebar.addDropSlot(&l, self.metrics, self.scale);
    return l;
}

// -------------------------------------------------------------------------
// Drag and drop (T1844)
// -------------------------------------------------------------------------

/// The sidebar as a pane-drop target, in screen coordinates.
pub const DropGeometry = struct {
    /// Anywhere on it means stash: the column, widened to the open card.
    sidebar: pane_drop.Rect,
    /// The stashed rows (rail tiles), top to bottom.
    rows: []const pane_drop.Rect,
    /// The empty "Drop to stash" slot, while a drag shows one.
    slot: ?pane_drop.Rect,
};

/// The drop target this sidebar presents right now, or null while it is
/// hidden (Mac: a sidebar hidden outright is not a target; the rail always
/// is). Rows are written into `rows_out` and borrowed by the answer.
pub fn dropGeometry(self: *PaneSidebar, rows_out: []pane_drop.Rect) ?DropGeometry {
    if (self.mode == .hidden) return null;
    if (w32.IsWindowVisible(self.hwnd) == 0) return null;
    var col: w32.RECT = undefined;
    if (w32.GetWindowRect(self.hwnd, &col) == 0) return null;
    const which: Surface = if (self.card_open and self.card_hwnd != null) .card else .rail;
    const hwnd = self.surfaceHwnd(which) orelse return null;
    var origin = w32.POINT{ .x = 0, .y = 0 };
    _ = w32.ClientToScreen(hwnd, &origin);
    const l = self.layoutFor(which);
    var area: pane_drop.Rect = .{ .left = col.left, .top = col.top, .right = col.right, .bottom = col.bottom };
    // The open card hangs over the grid; all of it is the sidebar. Its
    // trailing margin is not (the region leaves it to the grid).
    if (which == .card) area.right = @max(area.right, origin.x + l.card.right);
    var n: usize = 0;
    var i = l.first_stashed;
    while (i < l.count and n < rows_out.len) : (i += 1) {
        rows_out[n] = toScreen(l.items[i], origin);
        n += 1;
    }
    return .{
        .sidebar = area,
        .rows = rows_out[0..n],
        .slot = if (l.drop_slot) |sl| toScreen(sl, origin) else null,
    };
}

fn toScreen(r: pane_sidebar.Rect, origin: w32.POINT) pane_drop.Rect {
    return .{ .left = r.left + origin.x, .top = r.top + origin.y, .right = r.right + origin.x, .bottom = r.bottom + origin.y };
}

/// A pane drag started or ended (in any window: every sidebar is a target).
pub fn setDragActive(self: *PaneSidebar, on: bool) void {
    if (self.drag_active == on) return;
    self.drag_active = on;
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    if (self.card_hwnd) |c| _ = w32.InvalidateRect(c, null, 0);
    // The grace period the drag deferred starts once it is let go.
    if (!on and self.card_open and !self.pointerOn(.card, null)) self.scheduleClose();
}

/// A press on a row that has travelled far enough is a DRAG of that pane:
/// hand it to the window's pane drag (the one resolver, the one preview).
/// True when it did, and the press is no longer this sidebar's.
fn maybeStartRowDrag(self: *PaneSidebar, hwnd: w32.HWND, x: i32, y: i32) bool {
    if (w32.GetCapture() != hwnd) return false;
    const i = switch (self.pressed) {
        .item => |i| i,
        else => return false,
    };
    if (!drop_highlight.exceedsThreshold(x - self.press_x, y - self.press_y, drop_highlight.thresholdPx(self.scale))) return false;
    if (i >= self.entries.items.len) return false;
    const pane = self.entries.items[i].pane;
    self.pressed = .none;
    _ = w32.InvalidateRect(hwnd, null, 0);
    var press = w32.POINT{ .x = self.press_x, .y = self.press_y };
    _ = w32.ClientToScreen(hwnd, &press);
    var cur = w32.POINT{ .x = x, .y = y };
    _ = w32.ClientToScreen(hwnd, &cur);
    log.info("pane sidebar row drag start item={d} section={s}", .{ i, @tagName(self.entries.items[i].section) });
    self.window.beginSidebarDrag(pane, press, cur);
    return true;
}

fn makeFont(height: i32, weight: i32) ?*anyopaque {
    return w32.CreateFontW(
        -height,
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face),
    );
}

fn ensureFonts(self: *PaneSidebar) void {
    if (self.title_font != null and self.font_scale == self.scale) return;
    self.releaseFonts();
    const body = type_ramp.body(self.scale);
    const cap = type_ramp.caption(self.scale);
    self.title_font = makeFont(body.height, body.weight);
    self.caption_font = makeFont(cap.height, cap.weight);
    self.caption_bold_font = makeFont(cap.height, type_ramp.weight_semibold);
    self.font_scale = self.scale;
    // One line of each, measured rather than assumed from the em size.
    const hdc = w32.GetDC(self.hwnd) orelse return;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);
    self.metrics = .{
        .title_h = lineHeight(hdc, self.title_font),
        .caption_h = lineHeight(hdc, self.caption_font),
    };
}

fn lineHeight(hdc: w32.HDC, font: ?*anyopaque) i32 {
    const f = font orelse return 16;
    const prev = w32.SelectObject(hdc, @ptrCast(f));
    defer if (prev) |p| {
        _ = w32.SelectObject(hdc, p);
    };
    var probe = [_]u16{ 'A', 'g' };
    var r = w32.RECT{ .left = 0, .top = 0, .right = 1000, .bottom = 0 };
    _ = w32.DrawTextW(hdc, &probe, 2, &r, w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
    return @max(r.bottom - r.top, 1);
}

fn releaseFonts(self: *PaneSidebar) void {
    inline for (.{ "title_font", "caption_font", "caption_bold_font" }) |name| {
        if (@field(self, name)) |f| _ = w32.DeleteObject(@ptrCast(f));
        @field(self, name) = null;
    }
    self.font_scale = 0;
}

// -------------------------------------------------------------------------
// Paint
// -------------------------------------------------------------------------

const Theme = struct {
    bg: color_math.Rgb,
    surface: color_math.Rgb,
    text: u32,
    secondary: u32,
    accent: color_math.Rgb,
    dark: bool,
};

fn theme(self: *const PaneSidebar) Theme {
    const c = self.window.app.config.background;
    const bg: color_math.Rgb = .{ .r = c.r, .g = c.g, .b = c.b };
    // Pinned: the terminal background lifted by the card wash. Rail: the
    // card's own fill is the surface its tiles sit on.
    const surface = banner_card.fillColor(bg);
    const text = chrome_theme.textOn(surface);
    const secondary = chrome_theme.textSecondaryOn(surface);
    return .{
        .bg = bg,
        .surface = surface,
        .text = w32.RGB(text.r, text.g, text.b),
        .secondary = w32.RGB(secondary.r, secondary.g, secondary.b),
        .accent = chrome_theme.accentOn(surface, system_colors.accentCached()),
        .dark = !color_math.isLight(bg),
    };
}

fn fillRect(hdc: w32.HDC, r: pane_sidebar.Rect, color: u32) void {
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));
    var rr = w32.RECT{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
    _ = w32.FillRect(hdc, &rr, brush);
}

fn fillRound(hdc: w32.HDC, r: pane_sidebar.Rect, radius: i32, color: u32) void {
    const rgn = w32.CreateRoundRectRgn(r.left, r.top, r.right + 1, r.bottom + 1, 2 * radius, 2 * radius) orelse return;
    defer _ = w32.DeleteObject(rgn);
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));
    _ = w32.FillRgn(hdc, rgn, @ptrCast(brush));
}

fn rgb(c: color_math.Rgb) u32 {
    return w32.RGB(c.r, c.g, c.b);
}

fn shade(c: color_math.Rgb, delta: i32) color_math.Rgb {
    return .{
        .r = icon_button.shadeChannel(c.r, delta),
        .g = icon_button.shadeChannel(c.g, delta),
        .b = icon_button.shadeChannel(c.b, delta),
    };
}

fn drawText(hdc: w32.HDC, text: []const u16, r: pane_sidebar.Rect, color: u32, flags: u32) void {
    if (text.len == 0) return;
    _ = w32.SetTextColor(hdc, color);
    var rr = w32.RECT{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
    _ = w32.DrawTextW(hdc, text.ptr, @intCast(text.len), &rr, flags | w32.DT_NOPREFIX | w32.DT_SINGLELINE);
}

fn glyph(hdc: w32.HDC, scale: f32, r: pane_sidebar.Rect, cp: u16, dip: f32, color: u32) void {
    _ = icon_button_paint.fontCodepoint(
        hdc,
        scale,
        .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom },
        cp,
        dip,
        color,
    );
}

fn paint(self: *PaneSidebar, hdc: w32.HDC, which: Surface, width: i32, height: i32) void {
    const t = self.theme();
    const l = self.layoutFor(which);
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    if (l.open) return self.paintOpen(hdc, &l, t);
    switch (l.mode) {
        .hidden => fillRect(hdc, .{ .right = width, .bottom = height }, rgb(t.bg)),
        .expanded => self.paintExpanded(hdc, &l, t),
        .mini => self.paintMini(hdc, &l, t),
    }
}

fn isEmphasized(self: *const PaneSidebar) bool {
    return w32.windowIsActive(w32.GetAncestor(self.hwnd, w32.GA_ROOT));
}

fn hoverIs(self: *const PaneSidebar, hit: pane_sidebar.Hit) bool {
    return std.meta.eql(self.hover, hit);
}

fn paintPin(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    const state: icon_button.State = if (self.hoverIs(.pin))
        (if (std.meta.eql(self.pressed, pane_sidebar.Hit.pin)) .pressed else .hover)
    else
        .normal;
    if (icon_button.paintsFill(state)) {
        const inset = pane_sidebar.px(2, self.scale); // design system: fill inset xs
        const f: pane_sidebar.Rect = .{ .left = l.pin.left + inset, .top = l.pin.top + inset, .right = l.pin.right - inset, .bottom = l.pin.bottom - inset };
        fillRound(hdc, f, pane_sidebar.px(4, self.scale), rgb(shade(t.surface, icon_button.fillDelta(state, t.dark))));
    }
    glyph(hdc, self.scale, l.pin, if (self.window.pane_sidebar_pinned) glyph_pinned else glyph_pin, 12, t.text);
}

fn paintExpanded(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    // The flat panel: the lifted surface, square, edge to edge.
    fillRect(hdc, .{ .right = l.width, .bottom = l.height }, rgb(t.surface));
    // The rule against the grid, in the split divider's own color and width,
    // so the panel reads as one more column of the window.
    const rule_w = split_geometry.bandPx(self.scale);
    const divider = split_geometry.dividerPaint(self.window.dividerConfiguredColor(), t.bg, false);
    fillRect(hdc, .{ .left = l.width - rule_w, .right = l.width, .bottom = l.height }, rgb(divider));
    self.paintRows(hdc, l, t);
}

/// The unpinned card opened over the grid (T1842): the column as the rail
/// leaves it - terminal background - and on it the raised card at the
/// panel's width, holding the panel's header and rows. The window's region
/// keeps everything right of the column to the card itself, so the grid shows
/// through the trailing margin.
fn paintOpen(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    ensureCardCache(&self.open_card, hdc, l.width, l.height, t.bg, self.scale);
    if (self.open_card.dc) |mem| {
        _ = w32.BitBlt(hdc, 0, 0, l.width, l.height, mem, 0, 0, w32.SRCCOPY);
    } else {
        fillRect(hdc, .{ .right = l.width, .bottom = l.height }, rgb(t.bg));
        fillRound(hdc, l.card, pane_sidebar.px(8, self.scale), rgb(t.surface));
    }
    self.paintRows(hdc, l, t);
}

/// The header (caption + pin), the section rule and caption, and the rows -
/// shared by the pinned panel and the open card, whose layouts place them.
fn paintRows(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    // Header: "PANES" on the label inset, the pin at the trailing edge.
    if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
    drawText(hdc, std.unicode.utf8ToUtf16LeStringLiteral("PANES"), .{
        .left = l.caption_x,
        .top = l.header.top,
        .right = l.pin.left - pane_sidebar.px(pane_sidebar.sm_dip, self.scale),
        .bottom = l.header.bottom,
    }, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
    self.paintPin(hdc, l, t);

    if (l.section_rule) |r| fillRect(hdc, r, rgb(shade(t.surface, if (t.dark) 24 else -24)));
    if (l.stashed_caption) |cap| {
        var buf: [32]u8 = undefined;
        const stashed = self.entries.items.len - l.first_stashed;
        const text8 = std.fmt.bufPrint(&buf, "STASHED \u{00B7} {d}", .{stashed}) catch "STASHED";
        var wbuf: [32]u16 = undefined;
        const wn = std.unicode.utf8ToUtf16Le(&wbuf, text8) catch 0;
        if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        drawText(hdc, wbuf[0..wn], .{ .left = l.caption_x, .top = cap.top, .right = cap.right, .bottom = cap.bottom }, t.secondary, w32.DT_VCENTER);
    }

    const emphasized = self.isEmphasized();
    const radius = pane_sidebar.px(toc.row_corner_dip, self.scale);
    for (self.entries.items[0..l.count], 0..) |e, i| {
        const r = l.items[i];
        const hovered = self.hoverIs(.{ .item = i }) or self.hoverIs(.{ .item_button = i });
        const sel = list_selection.rowPaint(t.surface, t.accent, .{
            .selected = e.selected,
            .focused = emphasized,
            .hovered = hovered,
            .focus_visible = false,
        });
        if (sel.fill) |f| fillRound(hdc, r, radius, rgb(f));
        if (sel.indicator) |c| {
            const bar = toc.selectionIndicator(r.height(), self.scale);
            fillRound(hdc, .{
                .left = r.left + bar.left,
                .top = r.top + bar.top,
                .right = r.left + bar.left + bar.width,
                .bottom = r.top + bar.top + bar.height,
            }, bar.radius, rgb(c));
        }

        const ink = if (e.selected) t.text else t.secondary;
        const pad_v = pane_sidebar.px(toc.row_v_pad_dip, self.scale);
        const icon_box = pane_sidebar.px(16, self.scale);
        const text_inset = pane_sidebar.px(toc.text_inset_dip, self.scale);
        const icon_r: pane_sidebar.Rect = .{
            .left = r.left + text_inset,
            .top = r.top + pad_v,
            .right = r.left + text_inset + icon_box,
            .bottom = r.top + pad_v + self.metrics.title_h,
        };
        glyph(hdc, self.scale, icon_r, e.icon, 12, ink);

        // The trailing edge: the hover button replaces the state badge while
        // the pointer is on the row, so the two never crowd each other.
        const button = l.rowButton(i, self.scale);
        const text_left = icon_r.right + pane_sidebar.px(8, self.scale);
        var text_right = r.right - text_inset;
        if (hovered) {
            text_right = button.left - pane_sidebar.px(pane_sidebar.sm_dip, self.scale);
            self.paintRowButton(hdc, i, button, e.section, t);
        } else if (e.state != .idle) {
            const badge = pane_sidebar.px(16, self.scale);
            const br: pane_sidebar.Rect = .{
                .left = r.right - text_inset - badge,
                .top = icon_r.top + @divTrunc(icon_r.height() - badge, 2),
                .right = r.right - text_inset,
                .bottom = icon_r.top + @divTrunc(icon_r.height() - badge, 2) + badge,
            };
            self.paintBadge(hdc, br, e.state, t);
            text_right = br.left - pane_sidebar.px(pane_sidebar.sm_dip, self.scale);
        }

        if (self.title_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        drawText(hdc, e.title, .{ .left = text_left, .top = icon_r.top, .right = text_right, .bottom = icon_r.bottom }, ink, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
        if (e.subtitle.len > 0) {
            if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
            drawText(hdc, e.subtitle, .{
                .left = text_left,
                .top = icon_r.bottom,
                .right = text_right,
                .bottom = icon_r.bottom + self.metrics.caption_h,
            }, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
        }
    }
    self.paintDropSlot(hdc, l, t);
}

/// The empty "Drop to stash" slot (T1844), shown during a drag with nothing
/// stashed: a recessed well with the stash glyph - and, as a row, Mac's
/// label - so the target is visible before anything is in it.
fn paintDropSlot(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    const r = l.drop_slot orelse return;
    const radius = pane_sidebar.px(toc.row_corner_dip, self.scale);
    fillRound(hdc, r, radius, rgb(shade(t.surface, if (t.dark) 10 else -10)));
    const rows = l.mode == .expanded or l.open;
    if (!rows) {
        glyph(hdc, self.scale, r, glyph_stash, 12, t.secondary);
        return;
    }
    const text_inset = pane_sidebar.px(toc.text_inset_dip, self.scale);
    const icon_box = pane_sidebar.px(16, self.scale);
    const icon_r: pane_sidebar.Rect = .{ .left = r.left + text_inset, .top = r.top, .right = r.left + text_inset + icon_box, .bottom = r.bottom };
    glyph(hdc, self.scale, icon_r, glyph_stash, 12, t.secondary);
    if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
    drawText(hdc, std.unicode.utf8ToUtf16LeStringLiteral("Drop to stash \u{2014} it keeps running"), .{
        .left = icon_r.right + pane_sidebar.px(8, self.scale),
        .top = r.top,
        .right = r.right - text_inset,
        .bottom = r.bottom,
    }, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
}

fn paintRowButton(self: *PaneSidebar, hdc: w32.HDC, i: usize, b: pane_sidebar.Rect, section: pane_sidebar.Section, t: Theme) void {
    const on_button = self.hoverIs(.{ .item_button = i });
    if (on_button) {
        const pressed = std.meta.eql(self.pressed, pane_sidebar.Hit{ .item_button = i });
        const state: icon_button.State = if (pressed) .pressed else .hover;
        fillRound(hdc, b, pane_sidebar.px(4, self.scale), rgb(shade(t.surface, icon_button.fillDelta(state, t.dark) * 2)));
    }
    glyph(hdc, self.scale, b, if (section == .stashed) glyph_restore else glyph_stash, 10, t.text);
}

/// A state badge: `needs_input` is the accent "?" disc (Mac's question
/// badge); `busy` is a small accent dot until the shimmer lands (T1843).
fn paintBadge(self: *PaneSidebar, hdc: w32.HDC, r: pane_sidebar.Rect, state: ActivityState, t: Theme) void {
    switch (state) {
        .idle => {},
        .needs_input => {
            fillRound(hdc, r, @divTrunc(r.width(), 2), rgb(t.accent));
            const on = chrome_theme.textOn(t.accent);
            if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
            drawText(hdc, std.unicode.utf8ToUtf16LeStringLiteral("?"), r, rgb(on), w32.DT_CENTER | w32.DT_VCENTER);
        },
        .busy => {
            const d = @max(pane_sidebar.px(6, self.scale), 2);
            const dot: pane_sidebar.Rect = .{
                .left = r.centerX() - @divTrunc(d, 2),
                .top = r.centerY() - @divTrunc(d, 2),
                .right = r.centerX() - @divTrunc(d, 2) + d,
                .bottom = r.centerY() - @divTrunc(d, 2) + d,
            };
            fillRound(hdc, dot, @divTrunc(d, 2), rgb(t.accent));
        },
    }
}

fn paintMini(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    // The column is the terminal background; the rail is the raised card on
    // it - the banner's material, so the two read as the same family.
    ensureCardCache(&self.rail_card, hdc, l.width, l.height, t.bg, self.scale);
    if (self.rail_card.dc) |mem| {
        _ = w32.BitBlt(hdc, 0, 0, l.width, l.height, mem, 0, 0, w32.SRCCOPY);
    } else {
        fillRect(hdc, .{ .right = l.width, .bottom = l.height }, rgb(t.bg));
        fillRound(hdc, l.card, pane_sidebar.px(8, self.scale), rgb(t.surface));
    }

    self.paintPin(hdc, l, t);
    if (l.section_rule) |r| fillRect(hdc, r, rgb(shade(t.surface, if (t.dark) 24 else -24)));

    const emphasized = self.isEmphasized();
    const radius = pane_sidebar.px(toc.row_corner_dip, self.scale);
    for (self.entries.items[0..l.count], 0..) |e, i| {
        const r = l.items[i];
        const sel = list_selection.rowPaint(t.surface, t.accent, .{
            .selected = e.selected,
            .focused = emphasized,
            .hovered = self.hoverIs(.{ .item = i }),
            .focus_visible = false,
        });
        if (sel.fill) |f| fillRound(hdc, r, radius, rgb(f));
        const ink = if (e.selected) t.text else t.secondary;
        if (e.icon == glyph_terminal) {
            if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
            drawText(hdc, e.mono, r, ink, w32.DT_CENTER | w32.DT_VCENTER);
        } else {
            glyph(hdc, self.scale, r, e.icon, 12, ink);
        }
        // Activity rides as a corner badge (Mac): the question disc
        // top-right, the busy dot bottom-right.
        if (e.state != .idle) {
            const d = pane_sidebar.px(if (e.state == .needs_input) 12 else 8, self.scale);
            const corner: pane_sidebar.Rect = if (e.state == .needs_input)
                .{ .left = r.right - d + pane_sidebar.px(2, self.scale), .top = r.top - pane_sidebar.px(2, self.scale), .right = r.right + pane_sidebar.px(2, self.scale), .bottom = r.top - pane_sidebar.px(2, self.scale) + d }
            else
                .{ .left = r.right - d, .top = r.bottom - d, .right = r.right, .bottom = r.bottom };
            self.paintBadge(hdc, corner, e.state, t);
        }
    }
    self.paintDropSlot(hdc, l, t);
}

fn ensureCardCache(cache: *CardCache, hdc: w32.HDC, w: i32, h: i32, bg: color_math.Rgb, scale: f32) void {
    const stale = cache.dc == null or cache.w != w or cache.h != h or
        !std.meta.eql(cache.bg, bg) or cache.scale != scale;
    if (!stale) return;
    cache.release();
    if (w <= 0 or h <= 0) return;

    var bmi = std.mem.zeroes(w32.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;

    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
    var bits: ?*anyopaque = null;
    const bmp = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
        _ = w32.DeleteDC(mem_dc);
        return;
    };
    const raw = bits orelse {
        _ = w32.DeleteObject(bmp);
        _ = w32.DeleteDC(mem_dc);
        return;
    };
    _ = w32.SelectObject(mem_dc, bmp);
    const pixels = @as([*]u32, @ptrCast(@alignCast(raw)));
    // The banner card's margin IS the rail margin (12 DIP), so the card the
    // material draws lands exactly on `layout().card` - the rail's, and the
    // open card's (`layoutOpen` uses the same margin).
    banner_card.render(pixels[0..@intCast(w * h)], banner_card.Metrics.init(w, h, scale), bg);

    cache.* = .{ .dc = mem_dc, .bmp = bmp, .w = w, .h = h, .bg = bg, .scale = scale };
}

/// Double-buffered: the whole column is drawn into a memory DC and blitted
/// once, so a refresh never shows a half-painted list.
fn paintBuffered(self: *PaneSidebar, hdc: w32.HDC, which: Surface, width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;
    const mem = w32.CreateCompatibleDC(hdc) orelse return self.paint(hdc, which, width, height);
    defer _ = w32.DeleteDC(mem);
    const bmp = w32.CreateCompatibleBitmap(hdc, width, height) orelse return self.paint(hdc, which, width, height);
    defer _ = w32.DeleteObject(bmp);
    const old = w32.SelectObject(mem, bmp);
    defer _ = w32.SelectObject(mem, old);
    self.paint(mem, which, width, height);
    _ = w32.BitBlt(hdc, 0, 0, width, height, mem, 0, 0, w32.SRCCOPY);
}

// -------------------------------------------------------------------------
// Input
// -------------------------------------------------------------------------

fn hitAt(self: *PaneSidebar, which: Surface, x: i32, y: i32) pane_sidebar.Hit {
    const l = self.layoutFor(which);
    return pane_sidebar.hitTest(&l, x, y, self.scale);
}

fn setHover(self: *PaneSidebar, which: Surface, hit: pane_sidebar.Hit) void {
    if (std.meta.eql(self.hover, hit)) return;
    self.hover = hit;
    if (self.surfaceHwnd(which)) |h| _ = w32.InvalidateRect(h, null, 0);
}

// -------------------------------------------------------------------------
// Hover-open (T1842)
// -------------------------------------------------------------------------

/// Whether the real pointer is on `which` (window regions honored, so the
/// open card's trailing margin is not "on" it) and, when given, inside
/// `rect` of that window's client area. Asked at timer time, the way Mac
/// asks `mouseLocationOutsideOfEventStream`, because a leave message alone
/// cannot say whether the pointer has come back.
fn pointerOn(self: *PaneSidebar, which: Surface, rect: ?pane_sidebar.Rect) bool {
    const hwnd = self.surfaceHwnd(which) orelse return false;
    var pt: w32.POINT = undefined;
    if (w32.GetCursorPos_(&pt) == 0) return false;
    if (w32.WindowFromPoint(pt) != hwnd) return false;
    const r = rect orelse return true;
    _ = w32.ScreenToClient(hwnd, &pt);
    return r.contains(pt.x, pt.y);
}

/// Arm (or keep armed) the intent timer for a pointer at (`x`, `y`) on the
/// rail, or disarm it when the point is off the rail's card.
fn railPointer(self: *PaneSidebar, x: i32, y: i32) void {
    const l = self.currentLayout();
    if (!hov.opensOnTimer(self.mode, self.card_open, l.card.contains(x, y))) {
        self.disarm();
        return;
    }
    if (self.open_armed) return;
    if (w32.SetTimer(self.hwnd, TIMER_OPEN, hov.open_delay_ms, null) == 0) return;
    self.open_armed = true;
    log.info("pane sidebar hover-open armed delay={d}ms", .{hov.open_delay_ms});
}

fn disarm(self: *PaneSidebar) void {
    if (!self.open_armed) return;
    _ = w32.KillTimer(self.hwnd, TIMER_OPEN);
    self.open_armed = false;
}

fn onOpenTimer(self: *PaneSidebar) void {
    self.disarm();
    const l = self.currentLayout();
    if (!hov.opensOnTimer(self.mode, self.card_open, self.pointerOn(.rail, l.card))) return;
    self.openCard(.hover);
}

fn ensureCardWindow(self: *PaneSidebar) ?w32.HWND {
    if (self.card_hwnd) |h| return h;
    if (!card_class_registered) return null;
    const root = w32.GetAncestor(self.hwnd, w32.GA_ROOT) orelse return null;
    // A passive popup OWNED by the top-level: it never takes activation (a
    // click on a row must not pull the window's focus around), it hides and
    // minimizes with its owner, and as an owned window it sits above the
    // panes' own popups once seated (`seatCard`).
    const h = w32.CreateWindowExW(
        w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW,
        CARD_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        0,
        0,
        0,
        root,
        null,
        w32.GetModuleHandleW(null),
        null,
    ) orelse return null;
    _ = w32.SetWindowLongPtrW(h, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.card_hwnd = h;
    return h;
}

/// Open the card over the grid. The column - and so the grid - is untouched.
pub fn openCard(self: *PaneSidebar, reason: CardReason) void {
    if (self.mode != .mini) return;
    if (w32.IsWindowVisible(self.hwnd) == 0) return;
    if (self.ensureCardWindow() == null) return;
    self.disarm();
    const was_open = self.card_open;
    self.card_open = true;
    self.hover = .none;
    self.pressed = .none;
    self.positionCard();
    if (self.card_hwnd) |c| {
        _ = w32.InvalidateRect(c, null, 0);
        // A leave is owed whether or not a move ever arrives: tracking
        // starts now, so a pointer that is not on the card (an unpin from
        // the keyboard, a pin clicked and left in one motion) still gets its
        // grace period rather than a card that never closes.
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = c,
            .dwHoverTime = 0,
        };
        self.card_tracking = w32.TrackMouseEvent(&tme) != 0;
        _ = w32.SetTimer(c, TIMER_CLOSE, hov.close_delay_ms, null);
    }
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    self.syncTips();
    if (!was_open) self.logCard("open", reason);
}

pub fn closeCard(self: *PaneSidebar, reason: CardReason) void {
    if (!self.card_open) return;
    self.card_open = false;
    self.card_tracking = false;
    self.hover = .none;
    self.pressed = .none;
    if (self.card_hwnd) |c| {
        _ = w32.KillTimer(c, TIMER_CLOSE);
        if (w32.GetCapture() == c) _ = w32.ReleaseCapture();
        _ = w32.ShowWindow(c, w32.SW_HIDE);
    }
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    self.logCard("close", reason);
}

fn logCard(self: *PaneSidebar, what: []const u8, reason: CardReason) void {
    var col: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetWindowRect(self.hwnd, &col);
    var card: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (self.card_hwnd) |c| _ = w32.GetWindowRect(c, &card);
    log.info("pane sidebar card {s} reason={s} column={d},{d},{d},{d} card={d},{d},{d},{d}", .{
        what,      @tagName(reason),
        col.left,  col.top,
        col.right, col.bottom,
        card.left, card.top,
        card.right, card.bottom,
    });
}

/// Glue the card to the column it grows from: same top-left and height, the
/// panel's width plus the rail's margins, clipped to the column plus the
/// rounded card, and seated above the window's other popups.
fn positionCard(self: *PaneSidebar) void {
    const c = self.card_hwnd orelse return;
    var col: w32.RECT = undefined;
    if (w32.GetWindowRect(self.hwnd, &col) == 0) return;
    const w = pane_sidebar.openWidthPx(self.window.pane_sidebar_width_dip, self.scale);
    const h = col.bottom - col.top;
    if (h <= 0) return;

    // The region: the rail's column, plus the open card's rounded rect.
    const col_rgn = w32.CreateRectRgn(0, 0, col.right - col.left, h);
    const margin = pane_sidebar.px(pane_sidebar.rail_margin_dip, self.scale);
    const radius = @as(i32, @intFromFloat(@round(banner_card.RADIUS * self.scale)));
    const card_rgn = w32.CreateRoundRectRgn(margin, margin, w - margin + 1, @max(h - margin, margin) + 1, 2 * radius, 2 * radius);
    if (col_rgn) |a| {
        if (card_rgn) |b| {
            _ = w32.CombineRgn(a, a, b, w32.RGN_OR);
            _ = w32.DeleteObject(b);
        }
        // The system owns the region from here (also on a repeat call: the
        // previous one is released by SetWindowRgn itself).
        if (w32.SetWindowRgn(c, a, 1) == 0) _ = w32.DeleteObject(a);
    } else if (card_rgn) |b| _ = w32.DeleteObject(b);

    self.seatCard(c);
    _ = w32.SetWindowPos(
        c,
        self.seatAfterHwnd(c),
        col.left,
        col.top,
        w,
        h,
        w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW,
    );
}

/// Clear a stray topmost bit before seating (`overlay_zorder.isStray`): the
/// card is never topmost unless its window is.
fn seatCard(self: *PaneSidebar, c: w32.HWND) void {
    const root = w32.GetAncestor(self.hwnd, w32.GA_ROOT) orelse return;
    if (overlay_zorder.isStray(w32.GetWindowLongW(c, w32.GWL_EXSTYLE), w32.GetWindowLongW(root, w32.GWL_EXSTYLE))) {
        _ = w32.SetWindowPos(c, w32.HWND_NOTOPMOST, 0, 0, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
    }
}

/// Where in the z-order the card goes: directly below the first visible
/// window above the root that is not one of the root's own popups
/// (`hov.seatAfter`), or the top of the band.
fn seatAfterHwnd(self: *PaneSidebar, c: w32.HWND) ?w32.HWND {
    const root = w32.GetAncestor(self.hwnd, w32.GA_ROOT) orelse return null;
    var steps: [64]hov.ZStep = undefined;
    var hwnds: [64]w32.HWND = undefined;
    var n: usize = 0;
    var cur = w32.GetWindow(root, w32.GW_HWNDPREV);
    while (cur) |h| : (cur = w32.GetWindow(h, w32.GW_HWNDPREV)) {
        if (n == steps.len) break;
        steps[n] = .{
            .is_self = h == c,
            .is_sibling = w32.GetWindow(h, w32.GW_OWNER) == root,
            .is_visible = w32.IsWindowVisible(h) != 0,
        };
        hwnds[n] = h;
        n += 1;
    }
    const i = hov.seatAfter(steps[0..n]) orelse return null; // HWND_TOP
    return hwnds[i];
}

fn scheduleClose(self: *PaneSidebar) void {
    const c = self.card_hwnd orelse return;
    _ = w32.SetTimer(c, TIMER_CLOSE, hov.close_delay_ms, null);
}

fn onCloseTimer(self: *PaneSidebar) void {
    const c = self.card_hwnd orelse return;
    _ = w32.KillTimer(c, TIMER_CLOSE);
    if (!self.card_open) return;
    // A press held on the card (a click in progress; later a drag, T1844, or
    // a menu, T1845) keeps it open until it is let go.
    const held = w32.GetCapture() == c or self.drag_active;
    switch (hov.closeVerdict(self.pointerOn(.card, null), held)) {
        .stay => {},
        .retry => self.scheduleClose(),
        .close => self.closeCard(.left),
    }
}

// -------------------------------------------------------------------------
// Tooltips (Mac `.help`)
// -------------------------------------------------------------------------

fn tipEnsure(self: *PaneSidebar) ?w32.HWND {
    if (self.tip) |h| return h;
    var icc = w32.INITCOMMONCONTROLSEX{
        .dwSize = @sizeOf(w32.INITCOMMONCONTROLSEX),
        .dwICC = w32.ICC_TAB_CLASSES,
    };
    _ = w32.InitCommonControlsEx(&icc);
    const tip = w32.CreateWindowExW(
        w32.WS_EX_TOPMOST | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
        w32.TOOLTIPS_CLASS,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.TTS_ALWAYSTIP | w32.TTS_NOPREFIX,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        // UNOWNED, on purpose. Owned by this window, the topmost tooltip
        // dragged its owner up the z-order the moment it was created - and it
        // is created on the first layout of every window, including one
        // opened in the background, which then landed ABOVE the window the
        // user was in (cli-focus-policy.ps1 arm R, measured: new window at
        // z=6 over Ghoztty's frontmost at z=9; unowned, 5 under 4). The tool
        // texts are set directly, so no notification needs a parent.
        null,
        null,
        null,
        null,
    ) orelse return null;
    // A tile's tip is two lines (the title, then the hint): a max width is
    // what makes the control honor the line break at all.
    _ = w32.SendMessageW(tip, w32.TTM_SETMAXTIPWIDTH, 0, pane_sidebar.px(320, self.scale));
    if (self.theme().dark) {
        _ = w32.SetWindowTheme(tip, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
    }
    self.tip = tip;
    return tip;
}

fn toolInfo(hwnd: w32.HWND, id: usize, r: pane_sidebar.Rect, text: [*:0]const u16) w32.TOOLINFOW {
    return .{
        .cbSize = @sizeOf(w32.TOOLINFOW),
        .uFlags = w32.TTF_SUBCLASS,
        .hwnd = hwnd,
        .uId = id,
        .rect = .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom },
        .hinst = null,
        .lpszText = @constCast(@ptrCast(text)),
        .lParam = 0,
        .lpReserved = null,
    };
}

fn addTool(tip: w32.HWND, hwnd: w32.HWND, id: usize, r: pane_sidebar.Rect, text: [*:0]const u16) void {
    var ti = toolInfo(hwnd, id, r, text);
    // Delete first: re-adding an existing id would leave the old rect live.
    _ = w32.SendMessageW(tip, w32.TTM_DELTOOLW, 0, @bitCast(@intFromPtr(&ti)));
    _ = w32.SendMessageW(tip, w32.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&ti)));
}

fn delTool(tip: w32.HWND, hwnd: w32.HWND, id: usize) void {
    var ti = toolInfo(hwnd, id, .{}, std.unicode.utf8ToUtf16LeStringLiteral(""));
    _ = w32.SendMessageW(tip, w32.TTM_DELTOOLW, 0, @bitCast(@intFromPtr(&ti)));
}

const W = std.unicode.utf8ToUtf16LeStringLiteral;
const tip_pin = W(hov.pinTip(false));
const tip_unpin = W(hov.pinTip(true));
const tip_focus = W(hov.rowHint(.grid));
const tip_restore = W(hov.rowHint(.stashed));
const tip_stash_btn = W(hov.buttonTip(.grid));
const tip_restore_btn = W(hov.buttonTip(.stashed));

/// Bring both windows' tools in line with their layouts. Idempotent; cheap
/// enough for every place/refresh (a handful of tool messages).
fn syncTips(self: *PaneSidebar) void {
    const tip = self.tipEnsure() orelse return;
    var line: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&line);
    const lw = fbs.writer();
    inline for (.{ Surface.rail, Surface.card }) |which| {
        const slot = @intFromEnum(which);
        if (self.surfaceHwnd(which)) |hwnd| {
            const live = switch (which) {
                .rail => self.mode != .hidden,
                .card => self.card_open,
            };
            const l = self.layoutFor(which);
            const n = if (live) @min(l.count, self.entries.items.len) else 0;
            // Drop the tools of rows that are gone.
            if (self.tip_items[slot] > n) for (n..self.tip_items[slot]) |i| {
                delTool(tip, hwnd, toolItem(i));
                delTool(tip, hwnd, toolButton(i));
            };
            if (!live) {
                delTool(tip, hwnd, tool_pin);
            } else {
                addTool(tip, hwnd, tool_pin, l.pin, if (self.window.pane_sidebar_pinned) tip_unpin else tip_pin);
                const rows = l.mode == .expanded or l.open;
                for (self.entries.items[0..n], 0..) |e, i| {
                    if (rows) {
                        addTool(tip, hwnd, toolItem(i), l.items[i], if (e.section == .stashed) tip_restore else tip_focus);
                        addTool(tip, hwnd, toolButton(i), l.rowButton(i, self.scale), if (e.section == .stashed) tip_restore_btn else tip_stash_btn);
                    } else {
                        const len = hov.tileTip(&self.tip_text[i], e.title, e.section);
                        addTool(tip, hwnd, toolItem(i), l.items[i], self.tip_text[i][0..len :0]);
                        delTool(tip, hwnd, toolButton(i));
                    }
                }
            }
            self.tip_items[slot] = n;
            lw.print(" {s}={d}", .{ @tagName(which), if (live) n + 1 else 0 }) catch {};
        }
    }
    self.logTips(line[0..fbs.pos]);
}

/// The tooltip set, once per CHANGE, for the acceptance script: tools are
/// windows of comctl32's that a background desktop can never show, so what is
/// scored is that every tile, row and pin got one.
fn logTips(self: *PaneSidebar, counts: []const u8) void {
    // The first tile's text, so the script can check it names the pane. Part
    // of what is compared: the same counts in another mode is another set.
    var first: [hov.tip_cap * 3]u8 = undefined;
    var first_len: usize = 0;
    if (self.mode == .mini and self.tip_items[0] > 0) {
        const t = std.mem.sliceTo(&self.tip_text[0], 0);
        first_len = std.unicode.utf16LeToUtf8(&first, t) catch 0;
        for (first[0..first_len]) |*ch| if (ch.* == 0x0A) {
            ch.* = '|';
        };
    }
    var buf: [hov.tip_cap * 3 + 256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} mode={s} tile0={s}", .{ counts, @tagName(self.mode), first[0..first_len] }) catch counts;
    const key = line[0..@min(line.len, self.tip_log.len)];
    if (key.len == self.tip_log_len and std.mem.eql(u8, self.tip_log[0..self.tip_log_len], key)) return;
    @memcpy(self.tip_log[0..key.len], key);
    self.tip_log_len = key.len;
    log.info("pane sidebar tips{s}", .{line});
}

fn activate(self: *PaneSidebar, hit: pane_sidebar.Hit) void {
    switch (hit) {
        .none => {},
        .pin => self.window.togglePaneSidebarPin(),
        .item => |i| {
            if (i >= self.entries.items.len) return;
            self.window.paneSidebarActivate(self.entries.items[i].pane);
        },
        .item_button => |i| {
            if (i >= self.entries.items.len) return;
            self.window.paneSidebarToggleStash(self.entries.items[i].pane);
        },
    }
}

fn xOf(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF))));
}
fn yOf(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF))));
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const self = fromHwnd(hwnd) orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const which: Surface = if (self.card_hwnd != null and self.card_hwnd.? == hwnd) .card else .rail;
    switch (msg) {
        w32.WM_ERASEBKGND => return 1,
        // The open card never takes activation: a click on a row acts, and the
        // window's focus moves only as that action moves it.
        w32.WM_MOUSEACTIVATE => return if (which == .card) w32.MA_NOACTIVATE else w32.DefWindowProcW(hwnd, msg, wparam, lparam),
        w32.WM_TIMER => {
            switch (wparam) {
                TIMER_OPEN => if (which == .rail) self.onOpenTimer(),
                TIMER_CLOSE => if (which == .card) self.onCloseTimer(),
                else => {},
            }
            return 0;
        },
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) != 0) self.paintBuffered(hdc, which, r.right - r.left, r.bottom - r.top);
            return 0;
        },
        // The same column into a caller's DC, so a pixel probe can photograph
        // it synchronously (the TOC card's T835 reason).
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) == 0) return 0;
            self.paint(@ptrFromInt(wparam), which, r.right - r.left, r.bottom - r.top);
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            const x = xOf(lparam);
            const y = yOf(lparam);
            if (self.maybeStartRowDrag(hwnd, x, y)) return 0;
            self.setHover(which, self.hitAt(which, x, y));
            const tracked = switch (which) {
                .rail => &self.tracking,
                .card => &self.card_tracking,
            };
            if (!tracked.*) {
                var tme = w32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (w32.TrackMouseEvent(&tme) != 0) tracked.* = true;
            }
            switch (which) {
                .rail => self.railPointer(x, y),
                // Back on the card: the grace period is off.
                .card => if (self.card_hwnd) |c| {
                    _ = w32.KillTimer(c, TIMER_CLOSE);
                },
            }
            return 0;
        },
        w32.WM_MOUSELEAVE => {
            switch (which) {
                .rail => {
                    self.tracking = false;
                    self.disarm();
                },
                .card => {
                    self.card_tracking = false;
                    if (self.card_open) self.scheduleClose();
                },
            }
            if (w32.GetCapture() != hwnd) self.pressed = .none;
            self.setHover(which, .none);
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            // Activation is on the up over the same target (the standard
            // button affordance), so a press that slides off does nothing.
            self.press_x = xOf(lparam);
            self.press_y = yOf(lparam);
            self.pressed = self.hitAt(which, self.press_x, self.press_y);
            _ = w32.SetCapture(hwnd);
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            _ = w32.ReleaseCapture();
            const hit = self.hitAt(which, xOf(lparam), yOf(lparam));
            const pressed = self.pressed;
            self.pressed = .none;
            _ = w32.InvalidateRect(hwnd, null, 0);
            if (std.meta.eql(hit, pressed)) self.activate(hit);
            // Let go off the card while it was held open: the grace period
            // the hold deferred starts now.
            if (which == .card and self.card_open and !self.pointerOn(.card, null)) self.scheduleClose();
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
