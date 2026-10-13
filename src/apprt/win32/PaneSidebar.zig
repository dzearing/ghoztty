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
const outline = @import("pane_sidebar_outline.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const hov = @import("pane_sidebar_hover.zig");
const sidebar_prefs = @import("pane_sidebar_prefs.zig");
const row_menu = @import("pane_sidebar_menu.zig");
const motion = @import("pane_sidebar_motion.zig");
const App = @import("App.zig");
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
/// The motion clock (T1843), on whichever window shows something moving.
const TIMER_ANIM: usize = 3;

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
fn toolHead(k: usize) usize {
    return 1 + 2 * pane_sidebar.max_items + k;
}
const tool_scope: usize = 1 + 2 * pane_sidebar.max_items + pane_sidebar.max_heads;
const tool_trash: usize = tool_scope + 1;

/// What new windows start from: the most recently chosen pin and hidden
/// flags, the way a Finder window's sidebar does (Mac `rememberForNewWindows`),
/// and the panel width - one preference shared by every window (Mac
/// `PaneSidebarWidth`, T1846). Loaded from `pane_sidebar_prefs` before the
/// first window opens and written back on every user change, so it survives
/// a restart (T1847).
pub var remembered: sidebar_prefs.Prefs = .{};
var remembered_loaded = false;

/// Read the persisted defaults into `remembered`, once per process. Called
/// by `Window.init` before it seeds a window from them.
pub fn loadRemembered(alloc: std.mem.Allocator) void {
    if (remembered_loaded) return;
    remembered_loaded = true;
    if (sidebar_prefs.load(alloc)) |p| remembered = p;
}

/// Write `remembered` back. Best-effort, like every chrome preference.
pub fn saveRemembered(alloc: std.mem.Allocator) void {
    sidebar_prefs.save(alloc, remembered);
}

/// A window group of the outline: one tab of one top-level window (a Mac
/// window is a tab here - see `pane_sidebar_outline.zig`).
const Group = struct {
    window: *Window,
    tab: usize,
    /// The tab's stable identity, hashed - the fold key, and how a click
    /// finds the tab again after a reorder.
    key: u64,
    /// The header's text: the worktree inside a project, else the name.
    label: []u16,
    /// The project it is grouped under, as shown (upper-cased), or empty.
    project: []u16,
    project_key: u64,
    /// How many windows the project holds (on its first window only).
    project_size: usize,
    panes: usize,
    stashed: usize,
    question: bool,
    own: bool,
    /// The top-level has other tabs: "This Tab" rather than "This Window".
    tabbed: bool,
};

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
const glyph_windows: u16 = 0xE7C4; // TaskView: "every window"
const glyph_trash: u16 = 0xE74D; // Delete: trash mode (T1845)
const glyph_kill: u16 = 0xE711; // Cancel: trash mode's x
const glyph_chevron_down: u16 = 0xE70D;
const glyph_chevron_right: u16 = 0xE76C;

const Entry = struct {
    pane: *PaneView,
    /// The window and tab the pane lives in: this sidebar's own, or - in the
    /// all-windows scope (T1829) - any. Pointers to ask about, never to use
    /// unchecked: another window can close between a refresh and a click.
    window: *Window,
    tab: usize,
    /// Its window group in the outline (0 in the single roster), and whether
    /// that group is THIS window's active tab.
    group: u16 = 0,
    own: bool = true,
    section: pane_sidebar.Section,
    title: []u16,
    subtitle: []u16,
    mono: []u16,
    icon: u16,
    state: ActivityState,
    /// The bell rang and the pane has not been looked at since.
    bell: bool,
    selected: bool,
};

hwnd: w32.HWND,
window: *Window,
alloc: Allocator,

entries: std.ArrayListUnmanaged(Entry) = .{},
signature: u64 = 0,

// The all-windows scope (T1829). Not persisted, as Mac's is not: the switch,
// and what is folded, belong to one look at every window.
all_windows: bool = false,
/// One per window group, in outline order.
groups: std.ArrayListUnmanaged(Group) = .{},
/// The panel's lines (`pane_sidebar_outline.buildLines`).
lines: std.ArrayListUnmanaged(pane_sidebar.Line) = .{},
/// Folded window groups (by tab identity) and projects (by name), as keys.
folded: std.AutoHashMapUnmanaged(u64, void) = .{},

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
/// Alt was down when the held press went down (T1845's Alt-click swap).
press_alt: bool = false,
/// An edge drag in progress (T1846): the width it measures from
/// (`pane_sidebar.edgeStartDip`) and the screen x it went down at. Screen,
/// not client, so the measure survives the rail turning into the panel
/// under the pointer. Null otherwise.
edge: ?struct { start_dip: f32, start_x: i32 } = null,
/// A pane drag is live somewhere (T1844): the empty "Drop to stash" slot
/// shows while nothing is stashed, and the open card does not contract.
drag_active: bool = false,

/// Trash mode (T1845, Mac `isQuickKill`): every row and tile grows a red x
/// that kills its pane with no confirmation. Transient - never persisted,
/// and per window, as Mac's state object is.
quick_kill: bool = false,
/// A row's right-click menu is up: the open card holds open under it (Mac
/// never contracts under a menu the sidebar put up).
menu_open: bool = false,

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
tip_heads: [2]usize = .{ 0, 0 },
tip_log: [256]u8 = undefined,
tip_log_len: usize = 0,

title_font: ?*anyopaque = null,
/// A window header's name: the body size at the weight a sidebar gives a
/// group (Mac's 12 semibold).
title_bold_font: ?*anyopaque = null,
caption_font: ?*anyopaque = null,
caption_bold_font: ?*anyopaque = null,
font_scale: f32 = 0,
metrics: pane_sidebar.TextMetrics = .{ .title_h = 19, .caption_h = 16 },

// Motion (T1843). Each paint counts the marks it drew into `paint_marks`
// against one clock reading, and leaves the tally in `marks` for its surface:
// the motion timer runs while the last paint of that surface drew something
// that moves, and stops itself on the first tick after it did not.
paint_marks: motion.Marks = .{},
paint_ms: u64 = 0,
paint_motion: bool = true,
marks: [2]motion.Marks = .{ .{}, .{} },
anim_armed: [2]bool = .{ false, false },
/// The last roster tally logged (busy, question, bell), so the log says when
/// it moved rather than on every refresh.
logged_marks: [3]usize = .{ 0, 0, 0 },

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
    self.clearGroups();
    self.groups.deinit(self.alloc);
    self.lines.deinit(self.alloc);
    self.folded.deinit(self.alloc);
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
    if (changed) self.logOutline();
    // A relayout under the open card (a split, a stash from its own row
    // button) moves the column it grows from: keep it glued there.
    if (self.card_open) self.positionCard();
}

/// Re-read the roster: this window's active tab, or - in the all-windows
/// scope - every tab of every window. Cheap when nothing it shows has
/// changed; repaints only when something did.
pub fn refresh(self: *PaneSidebar) void {
    if (self.all_windows) return self.refreshAll();
    const win = self.window;
    if (win.tab_count == 0) {
        if (self.entries.items.len != 0 or self.groups.items.len != 0) {
            self.clearAll();
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
    h.update("one");
    h.update(std.mem.asBytes(&n));
    for (views[0..n]) |v| hashView(&h, v, v == active);
    const sig = h.final();
    if (sig == self.signature) return;
    self.signature = sig;
    self.clearAll();
    self.appendEntries(views[0..n], win, win.active_tab, 0, true, active);
    self.rosterChanged();
}

/// What a row shows about `v`, into the roster's signature.
fn hashView(h: *std.hash.Wyhash, v: *PaneView, selected: bool) void {
    h.update(std.mem.asBytes(&v));
    h.update(std.mem.asBytes(&v.stash_seq));
    const sel: u8 = @intFromBool(selected);
    h.update(std.mem.asBytes(&sel));
    if (v.title()) |t| h.update(t);
    h.update("\x00");
    switch (v.kind) {
        .terminal => |s| {
            h.update(std.mem.asBytes(&s.activity_state));
            h.update(std.mem.asBytes(&s.bell));
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

/// The roster changed: repaint, re-glue the open card, re-sync the tips.
fn rosterChanged(self: *PaneSidebar) void {
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    self.logOutline();
    self.logMarks();
    if (self.card_open) {
        // More or fewer rows: the card is as tall as before, but its region
        // and rows are re-derived with it.
        self.positionCard();
        if (self.card_hwnd) |c| _ = w32.InvalidateRect(c, null, 0);
    }
    self.syncTips();
}

/// Where the outline put everything, in the column's client coordinates -
/// once per roster or mode change, all-windows scope only. A background
/// desktop cannot be photographed row by row, so the acceptance script
/// clicks from this: heads (`W`indow / `P`roject + group), shown items
/// (group, `g`rid / `s`tashed), the hairline count and the scope toggle.
///
/// The single-window roster logs the same shape as `pane sidebar rows ...`
/// (T1845), with each item's pane id after a `#`, so the row-actions script
/// can right-click and Alt-click the row of the pane it means. The trash
/// toggle's center rides at the end.
fn logOutline(self: *PaneSidebar) void {
    if (self.mode == .hidden) return;
    if (!self.all_windows) return self.logRows();
    const l = self.currentLayout();
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.print("mode={s} heads=", .{@tagName(l.mode)}) catch {};
    for (l.heads[0..l.head_count]) |hd| {
        const k: u8 = if (hd.kind == .project) 'P' else 'W';
        w.print("{c}{d}@{d},{d};", .{ k, hd.index, hd.rect.centerX(), hd.rect.centerY() }) catch break;
    }
    w.writeAll(" items=") catch {};
    for (self.entries.items[0..@min(l.count, self.entries.items.len)], 0..) |e, i| {
        if (!l.shown(i)) continue;
        const sec: u8 = if (e.section == .stashed) 's' else 'g';
        w.print("g{d}{c}@{d},{d};", .{ e.group, sec, l.items[i].centerX(), l.items[i].centerY() }) catch break;
    }
    const rules = l.rule_count + @intFromBool(l.section_rule != null);
    w.print(" rules={d} scope={d},{d}", .{ rules, l.scope.centerX(), l.scope.centerY() }) catch {};
    log.info("pane sidebar outline {s}", .{fbs.getWritten()});
}

fn logRows(self: *PaneSidebar) void {
    const l = self.currentLayout();
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.print("mode={s} heads= items=", .{@tagName(l.mode)}) catch {};
    for (self.entries.items[0..@min(l.count, self.entries.items.len)], 0..) |e, i| {
        if (!l.shown(i)) continue;
        const sec: u8 = if (e.section == .stashed) 's' else 'g';
        w.print("g0{c}@{d},{d}#{s};", .{ sec, l.items[i].centerX(), l.items[i].centerY(), e.pane.paneId() }) catch break;
    }
    const rules = l.rule_count + @intFromBool(l.section_rule != null);
    w.print(" rules={d} scope={d},{d} trash={d},{d}", .{ rules, l.scope.centerX(), l.scope.centerY(), l.trash.centerX(), l.trash.centerY() }) catch {};
    log.info("pane sidebar rows {s}", .{fbs.getWritten()});
}

/// The roster's activity marks, logged when the tally moves: how many rows
/// are busy, have a question, and carry a bell dot (a stashed pane whose bell
/// rang). The acceptance script scores the bell from this line, since a dot
/// is a few pixels on a background desktop.
fn logMarks(self: *PaneSidebar) void {
    var tally: [3]usize = .{ 0, 0, 0 };
    for (self.entries.items) |e| {
        if (e.state == .busy) tally[0] += 1;
        if (e.state == .needs_input) tally[1] += 1;
        if (e.bell and e.section == .stashed) tally[2] += 1;
    }
    if (std.mem.eql(usize, &tally, &self.logged_marks)) return;
    self.logged_marks = tally;
    log.info("pane sidebar marks busy={d} question={d} bell={d}", .{ tally[0], tally[1], tally[2] });
}

const TabRef = struct { window: *Window, tab: usize };
const name_cap = 768; // a 256-unit tab title as UTF-8

/// The all-windows roster (T1829): every tab of every window as a group, in
/// outline order (`pane_sidebar_outline.outlineOrder`), each listing its
/// panes the way this window's own roster does.
fn refreshAll(self: *PaneSidebar) void {
    const max_heads = pane_sidebar.max_heads;
    var refs: [max_heads]TabRef = undefined;
    var names_buf: [max_heads][name_cap]u8 = undefined;
    var names: [max_heads][]const u8 = undefined;
    var nref: usize = 0;
    gather: for (self.window.app.windows.items) |w| {
        if (w.closing or w.is_quick_terminal) continue;
        for (0..w.tab_count) |t| {
            if (nref == max_heads) break :gather;
            refs[nref] = .{ .window = w, .tab = t };
            names[nref] = groupName(w, t, &names_buf[nref]);
            nref += 1;
        }
    }
    var placed: [max_heads]outline.Placed = undefined;
    const np = outline.outlineOrder(names[0..nref], &placed);

    const Span = struct { start: usize, grid: usize, stashed: usize };
    var views: [pane_sidebar.max_items]*PaneView = undefined;
    var spans: [max_heads]Span = undefined;
    var nv: usize = 0;
    var h = std.hash.Wyhash.init(0);
    h.update("all");
    h.update(std.mem.asBytes(&np));
    for (placed[0..np], 0..) |p, gi| {
        const r = refs[p.index];
        const own = self.isOwn(r);
        const active = r.window.tab_active_pane[r.tab];
        const got = pane_sidebar.roster(r.window.tab_trees[r.tab], views[nv..]);
        var grid: usize = 0;
        for (views[nv .. nv + got]) |v| {
            if (v.stash_seq == 0) grid += 1;
        }
        spans[gi] = .{ .start = nv, .grid = grid, .stashed = got - grid };
        h.update(std.mem.asBytes(&r.window));
        h.update(std.mem.asBytes(&r.tab));
        h.update(names[p.index]);
        h.update("\x00");
        const o: u8 = @intFromBool(own);
        h.update(std.mem.asBytes(&o));
        const q: u8 = @intFromBool(r.window.tab_count > 1);
        h.update(std.mem.asBytes(&q));
        h.update(std.mem.asBytes(&got));
        for (views[nv .. nv + got]) |v| hashView(&h, v, own and v == active);
        nv += got;
    }
    var fold_acc: u64 = 0;
    var fit = self.folded.keyIterator();
    while (fit.next()) |k| fold_acc ^= k.*;
    h.update(std.mem.asBytes(&fold_acc));
    const sig = h.final();
    if (sig == self.signature) return;
    self.signature = sig;

    self.clearAll();
    var specs: [max_heads]outline.GroupSpec = undefined;
    for (placed[0..np], 0..) |p, gi| {
        const r = refs[p.index];
        const own = self.isOwn(r);
        const sp = spans[gi];
        const key = tabKey(r.window, r.tab);
        const project_key: u64 = if (p.project) |pr| projectKey(pr) else 0;
        self.appendGroup(.{
            .window = r.window,
            .tab = r.tab,
            .key = key,
            .label = &.{},
            .project = &.{},
            .project_key = project_key,
            .project_size = if (outline.opensProject(placed[0..np], gi)) outline.projectSize(placed[0..np], gi) else 0,
            .panes = sp.grid + sp.stashed,
            .stashed = sp.stashed,
            .question = treeHasQuestion(r.window, r.tab),
            .own = own,
            .tabbed = r.window.tab_count > 1,
        }, p.label, p.project);
        self.appendEntries(views[sp.start .. sp.start + sp.grid + sp.stashed], r.window, r.tab, @intCast(gi), own, r.window.tab_active_pane[r.tab]);
        specs[gi] = .{
            .project = p.project,
            .grid = sp.grid,
            .stashed = sp.stashed,
            .folded = self.folded.contains(key),
            .project_folded = p.project != null and self.folded.contains(project_key),
        };
    }
    var lines: [pane_sidebar.max_heads * 5 + pane_sidebar.max_items]pane_sidebar.Line = undefined;
    const nl = outline.buildLines(specs[0..np], &lines);
    self.lines.appendSlice(self.alloc, lines[0..nl]) catch {};
    // The order, for the acceptance script: `project/worktree` or the name.
    var ob: [1024]u8 = undefined;
    var ofs = std.io.fixedBufferStream(&ob);
    for (placed[0..np], 0..) |p, gi| {
        const sep: []const u8 = if (gi == 0) "" else "|";
        if (p.project) |pr| {
            ofs.writer().print("{s}{s}/{s}", .{ sep, pr, p.label }) catch break;
        } else ofs.writer().print("{s}{s}", .{ sep, p.label }) catch break;
    }
    log.info("pane sidebar all-windows groups={d} panes={d} lines={d} order={s}", .{ np, nv, nl, ofs.getWritten() });
    self.rosterChanged();
}

fn isOwn(self: *const PaneSidebar, r: TabRef) bool {
    return r.window == self.window and r.tab == self.window.active_tab;
}

/// A window's name as a person would say it (Mac `windowTitle(of:)`): a title
/// the user set - the window's, else the tab's - and otherwise what its
/// focused pane is called. Never the raw title with its activity suffix.
fn groupName(w: *Window, t: usize, buf: *[name_cap]u8) []const u8 {
    if (w.title_override) |o| {
        if (o.len > 0) return o;
    }
    if (w.tab_title_pinned[t]) {
        const n = std.unicode.utf16LeToUtf8(buf, w.tab_titles[t][0..w.tab_title_lens[t]]) catch 0;
        if (n > 0) return buf[0..n];
    }
    const pane = w.tab_active_pane[t];
    const pwd: ?[]const u8 = if (pane.surface()) |s| (if (s.pwd) |p| p else null) else null;
    return pane_sidebar.displayTitle(if (pane.title()) |x| x else null, pwd, "Window");
}

fn tabKey(w: *const Window, t: usize) u64 {
    return std.hash.Wyhash.hash(0x746162, &w.tab_uuid[t]);
}

fn projectKey(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x70726f6a, name);
}

fn treeHasQuestion(w: *Window, t: usize) bool {
    var it = w.tab_trees[t].iterator();
    while (it.next()) |entry| {
        if (entry.view.surface()) |s| {
            if (s.activity_state == .needs_input) return true;
        }
    }
    return false;
}

fn appendGroup(self: *PaneSidebar, g_in: Group, label8: []const u8, project8: ?[]const u8) void {
    var g = g_in;
    g.label = std.unicode.utf8ToUtf16LeAlloc(self.alloc, label8) catch return;
    var up: [name_cap]u8 = undefined;
    const p8 = project8 orelse "";
    const pn = @min(p8.len, up.len);
    for (p8[0..pn], 0..) |c, i| up[i] = std.ascii.toUpper(c);
    g.project = std.unicode.utf8ToUtf16LeAlloc(self.alloc, up[0..pn]) catch {
        self.alloc.free(g.label);
        return;
    };
    self.groups.append(self.alloc, g) catch {
        self.alloc.free(g.label);
        self.alloc.free(g.project);
    };
}

fn clearEntries(self: *PaneSidebar) void {
    for (self.entries.items) |e| {
        self.alloc.free(e.title);
        self.alloc.free(e.subtitle);
        self.alloc.free(e.mono);
    }
    self.entries.clearRetainingCapacity();
}

fn clearGroups(self: *PaneSidebar) void {
    for (self.groups.items) |g| {
        self.alloc.free(g.label);
        self.alloc.free(g.project);
    }
    self.groups.clearRetainingCapacity();
}

fn clearAll(self: *PaneSidebar) void {
    self.clearEntries();
    self.clearGroups();
    self.lines.clearRetainingCapacity();
}

fn appendEntries(self: *PaneSidebar, views: []const *PaneView, window: *Window, tab: usize, group: u16, own: bool, active: *PaneView) void {
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
            .window = window,
            .tab = tab,
            .group = group,
            .own = own,
            .section = if (v.stash_seq != 0) .stashed else .grid,
            .title = title,
            .subtitle = subtitle,
            .mono = mono,
            .icon = iconFor(v),
            .state = if (v.surface()) |s| s.activity_state else .idle,
            .bell = if (v.surface()) |s| s.bell else false,
            // Only THIS window has a selection (Mac 55352e377): another
            // window's focus is not focus here.
            .selected = own and v == active,
        }) catch {
            self.alloc.free(title);
            self.alloc.free(subtitle);
            self.alloc.free(mono);
        };
    }
}

/// Every OTHER sidebar showing all windows re-reads its roster: something in
/// `except` (or a window that just closed, with `except` null) changed what
/// they list. Cheap - each hashes and returns when nothing it shows moved.
pub fn refreshScopes(windows: []const *Window, except: ?*Window) void {
    for (windows) |w| {
        if (w == except or w.closing) continue;
        const sb = w.sidebar orelse continue;
        if (sb.all_windows) sb.refresh();
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
        items[i] = .{ .section = e.section, .two_line = e.subtitle.len > 0, .group = e.group, .own = e.own };
    }
    self.ensureFonts();
    const lines: ?[]const pane_sidebar.Line = if (self.all_windows) self.lines.items else null;
    var l = switch (which) {
        .rail => pane_sidebar.layoutWith(self.mode, r.right - r.left, r.bottom - r.top, items[0..n], lines, self.metrics, self.scale),
        .card => pane_sidebar.layoutOpenWith(r.right - r.left, r.bottom - r.top, items[0..n], lines, self.metrics, self.scale),
    };
    if (self.drag_active) pane_sidebar.addDropSlot(&l, self.metrics, self.scale);
    l.quick_kill = self.quick_kill;
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
    const end = if (l.outline) l.stash_end else l.count;
    while (i < end and n < rows_out.len) : (i += 1) {
        // A stashed row folded out of sight is no place to drop between.
        if (!l.shown(i)) continue;
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
    // Another window's pane is not dragged from here yet: dropping it into
    // this grid or onto another window's group is the cross-window move,
    // which is its own follow-up (T1829 split).
    if (!self.entries.items[i].own) return false;
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
    self.title_bold_font = makeFont(body.height, type_ramp.weight_semibold);
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
    inline for (.{ "title_font", "title_bold_font", "caption_font", "caption_bold_font" }) |name| {
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
    self.paint_marks = .{};
    self.paint_ms = w32.GetTickCount64();
    self.paint_motion = App.clientAreaAnimationsEnabled();
    if (l.open) {
        self.paintOpen(hdc, &l, t);
    } else switch (l.mode) {
        .hidden => fillRect(hdc, .{ .right = width, .bottom = height }, rgb(t.bg)),
        .expanded => self.paintExpanded(hdc, &l, t),
        .mini => self.paintMini(hdc, &l, t),
    }
    self.marks[@intFromEnum(which)] = self.paint_marks;
    if (self.paint_marks.moving(self.paint_motion)) self.armMotion(which);
}

// -------------------------------------------------------------------------
// Motion (T1843)
// -------------------------------------------------------------------------

/// Start the motion clock on `which`, if it is not already running.
fn armMotion(self: *PaneSidebar, which: Surface) void {
    const k = @intFromEnum(which);
    if (self.anim_armed[k]) return;
    const hwnd = self.surfaceHwnd(which) orelse return;
    if (w32.SetTimer(hwnd, TIMER_ANIM, motion.frame_ms, null) == 0) return;
    self.anim_armed[k] = true;
    const m = self.marks[k];
    log.info("pane sidebar motion on surface={s} busy={d} pulse={d}", .{ @tagName(which), m.busy, m.pulsing });
}

/// A motion frame: repaint while the last paint drew something that moves
/// and the window can be seen; otherwise stop. A paint that draws something
/// moving again re-arms it, so the clock never runs for a still column.
fn onMotionTick(self: *PaneSidebar, which: Surface) void {
    const k = @intFromEnum(which);
    const hwnd = self.surfaceHwnd(which) orelse return;
    const root = w32.GetAncestor(hwnd, w32.GA_ROOT);
    const seen = w32.IsWindowVisible(hwnd) != 0 and !(root != null and w32.IsIconic(root.?) != 0);
    if (seen and self.marks[k].moving(App.clientAreaAnimationsEnabled())) {
        _ = w32.InvalidateRect(hwnd, null, 0);
        return;
    }
    _ = w32.KillTimer(hwnd, TIMER_ANIM);
    self.anim_armed[k] = false;
    log.info("pane sidebar motion off surface={s}", .{@tagName(which)});
}

fn unrgb(c: u32) color_math.Rgb {
    return .{ .r = @truncate(c), .g = @truncate(c >> 8), .b = @truncate(c >> 16) };
}

/// What a pane's mark is drawn with: an icon-font glyph, or the rail's
/// monogram.
const Mark = union(enum) { glyph: u16, text: []const u16 };

fn drawMark(self: *PaneSidebar, hdc: w32.HDC, r: pane_sidebar.Rect, mark: Mark, color: u32) void {
    switch (mark) {
        .glyph => |cp| glyph(hdc, self.scale, r, cp, 12, color),
        .text => |s| {
            if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
            drawText(hdc, s, r, color, w32.DT_CENTER | w32.DT_VCENTER);
        },
    }
}

/// A pane's mark, shimmering while it is busy (Mac `PaneSidebarGlyph`): a
/// solid dim base with a brighter band sweeping across it - the whole busy
/// signal, no spinner and no glow. GDI has no gradient mask for text, so the
/// mark is drawn in vertical slices, each in the band's color at that x over
/// `under` (whatever the mark sits on); adjacent slices of one color are one
/// draw. With motion off it is the plain mark in `ink`, as Mac's is.
fn paintMarkFor(self: *PaneSidebar, hdc: w32.HDC, r: pane_sidebar.Rect, mark: Mark, ink: u32, under: color_math.Rgb, busy: bool) void {
    if (!busy) return self.drawMark(hdc, r, mark, ink);
    self.paint_marks.busy += 1;
    if (!self.paint_motion or r.width() <= 0) return self.drawMark(hdc, r, mark, ink);

    // The band runs across the mark itself, not the box it is centered in.
    const w: i32 = switch (mark) {
        .glyph => pane_sidebar.px(12, self.scale),
        .text => |s| blk: {
            if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
            break :blk @max(textWidth(hdc, s), 1);
        },
    };
    const left = r.centerX() - @divTrunc(w, 2);
    const pos = motion.bandPosition(self.paint_ms);
    const fg = unrgb(ink);
    const colorAt = struct {
        fn f(x: i32, l0: i32, width: i32, p: f64, u: color_math.Rgb, c: color_math.Rgb) u32 {
            const frac = (@as(f64, @floatFromInt(x - l0)) + 0.5) / @as(f64, @floatFromInt(width));
            return rgb(color_math.mix(u, c, motion.shimmerAlpha(frac, p)));
        }
    }.f;
    var x = r.left;
    while (x < r.right) {
        const color = colorAt(x, left, w, pos, under, fg);
        var end = x + 1;
        while (end < r.right and colorAt(end, left, w, pos, under, fg) == color) end += 1;
        const saved = w32.SaveDC(hdc);
        _ = w32.IntersectClipRect(hdc, x, r.top, end, r.bottom);
        self.drawMark(hdc, r, mark, color);
        _ = w32.RestoreDC(hdc, saved);
        x = end;
    }
}

/// The question badge with its breathing ring (Mac `PaneSidebarQuestionBadge`):
/// a soft accent ring outside the disc, so a question in an otherwise quiet
/// list is what draws the eye. `under` is what the ring fades into.
fn paintQuestion(self: *PaneSidebar, hdc: w32.HDC, r: pane_sidebar.Rect, under: color_math.Rgb, t: Theme) void {
    self.paint_marks.pulsing += 1;
    if (self.paint_motion) {
        const a = motion.pulseAlpha(self.paint_ms);
        const ring = @max(pane_sidebar.px(motion.pulse_ring_dip, self.scale), 1);
        // Below one shade step the ring is invisible: skip the fill.
        if (a * 255 >= 1) {
            const halo: pane_sidebar.Rect = .{ .left = r.left - ring, .top = r.top - ring, .right = r.right + ring, .bottom = r.bottom + ring };
            fillRound(hdc, halo, @divTrunc(halo.width(), 2), rgb(color_math.mix(under, t.accent, a)));
        }
    }
    self.paintBadge(hdc, r, .needs_input, t);
}

/// A stashed pane's bell (Mac: a 7 pt accent dot until it is restored).
fn paintBellDot(self: *PaneSidebar, hdc: w32.HDC, cx: i32, cy: i32, t: Theme) void {
    self.paint_marks.bells += 1;
    const d = @max(pane_sidebar.px(7, self.scale), 3);
    const dot: pane_sidebar.Rect = .{ .left = cx - @divTrunc(d, 2), .top = cy - @divTrunc(d, 2), .right = cx - @divTrunc(d, 2) + d, .bottom = cy - @divTrunc(d, 2) + d };
    fillRound(hdc, dot, @divTrunc(d, 2), rgb(t.accent));
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
    // Header: "PANES" (or "ALL WINDOWS") on the label inset, the
    // all-windows toggle and the pin at the trailing edge.
    if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
    // Trash mode says what a click now does, in the destructive red (Mac's
    // "Click × to kill" caption).
    const caption = if (self.quick_kill)
        std.unicode.utf8ToUtf16LeStringLiteral(row_menu.kill_caption)
    else if (self.all_windows)
        std.unicode.utf8ToUtf16LeStringLiteral("ALL WINDOWS")
    else
        std.unicode.utf8ToUtf16LeStringLiteral("PANES");
    drawText(hdc, caption, .{
        .left = l.caption_x,
        .top = l.header.top,
        .right = l.scope.left - pane_sidebar.px(pane_sidebar.sm_dip, self.scale),
        .bottom = l.header.bottom,
    }, if (self.quick_kill) rgb(chrome_theme.dangerInkOn(t.surface)) else t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
    self.paintPin(hdc, l, t);
    self.paintScope(hdc, l, t);
    self.paintTrash(hdc, l, t);

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
    if (l.outline) self.paintOutline(hdc, l, t);

    const emphasized = self.isEmphasized();
    const radius = pane_sidebar.px(toc.row_corner_dip, self.scale);
    for (self.entries.items[0..l.count], 0..) |e, i| {
        if (!l.shown(i)) continue;
        const r = l.items[i];
        const hovered = self.hoverIs(.{ .item = i }) or self.hoverIs(.{ .item_button = i });
        // Trash mode: a hovered row (not the selected one) washes red, so the
        // row a click would kill is the one that says so (Mac: red at 12%).
        const kill_wash = self.quick_kill and hovered and !e.selected;
        const sel = list_selection.rowPaint(t.surface, t.accent, .{
            .selected = e.selected,
            .focused = emphasized,
            .hovered = hovered and !kill_wash,
            .focus_visible = false,
        });
        if (kill_wash) {
            fillRound(hdc, r, radius, rgb(color_math.mix(t.surface, chrome_theme.dangerInkOn(t.surface), 0.12)));
        } else if (sel.fill) |f| fillRound(hdc, r, radius, rgb(f));
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
        const under = sel.fill orelse t.surface;
        const pad_v = pane_sidebar.px(toc.row_v_pad_dip, self.scale);
        const icon_box = pane_sidebar.px(16, self.scale);
        const text_inset = pane_sidebar.px(toc.text_inset_dip, self.scale);
        // The outline indents a row's content, never its fill (Mac).
        const content = r.left + text_inset + l.indent[i];
        const icon_r: pane_sidebar.Rect = .{
            .left = content,
            .top = r.top + pad_v,
            .right = content + icon_box,
            .bottom = r.top + pad_v + self.metrics.title_h,
        };
        // A busy pane's icon is in full ink, shimmering (Mac iconColor).
        const busy = e.state == .busy;
        self.paintMarkFor(hdc, icon_r, .{ .glyph = e.icon }, if (busy) t.text else ink, under, busy);

        // The trailing edge: the hover button replaces the state accessories
        // while the pointer is on the row, so the two never crowd each other.
        const button = l.rowButton(i, self.scale);
        const text_left = icon_r.right + pane_sidebar.px(8, self.scale);
        var text_right = r.right - text_inset;
        const sm = pane_sidebar.px(pane_sidebar.sm_dip, self.scale);
        if (self.quick_kill) {
            // Trash mode's x is always there - no hover needed to find it.
            text_right = button.left - sm;
            self.paintKill(hdc, button, self.hoverIs(.{ .item_button = i }), t);
        } else if (hovered) {
            text_right = button.left - sm;
            self.paintRowButton(hdc, i, button, e.section, t);
        } else {
            // Mac's accessories, trailing first: a stashed pane's bell dot,
            // then the question badge before it.
            if (e.bell and e.section == .stashed) {
                const d = @max(pane_sidebar.px(7, self.scale), 3);
                self.paintBellDot(hdc, text_right - @divTrunc(d, 2), icon_r.centerY(), t);
                text_right -= d + sm;
            }
            if (e.state == .needs_input) {
                const badge = pane_sidebar.px(16, self.scale);
                const br: pane_sidebar.Rect = .{
                    .left = text_right - badge,
                    .top = icon_r.top + @divTrunc(icon_r.height() - badge, 2),
                    .right = text_right,
                    .bottom = icon_r.top + @divTrunc(icon_r.height() - badge, 2) + badge,
                };
                self.paintQuestion(hdc, br, under, t);
                text_right = br.left - sm;
            }
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

/// The all-windows toggle (Mac's `macwindow.on.rectangle` header button).
/// Mac reads on/off from a filled glyph; the icon font has no filled twin,
/// so on is the Windows toggle-button vocabulary instead: the button stays
/// filled, as a checked toolbar toggle does.
fn paintScope(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    if (l.scope.width() <= 0) return;
    const state: icon_button.State = if (self.hoverIs(.scope))
        (if (std.meta.eql(self.pressed, pane_sidebar.Hit.scope)) .pressed else .hover)
    else
        .normal;
    const inset = pane_sidebar.px(2, self.scale); // design system: fill inset xs
    const f: pane_sidebar.Rect = .{ .left = l.scope.left + inset, .top = l.scope.top + inset, .right = l.scope.right - inset, .bottom = l.scope.bottom - inset };
    if (self.all_windows) {
        const checked: icon_button.State = if (state == .normal) .hover else .pressed;
        fillRound(hdc, f, pane_sidebar.px(4, self.scale), rgb(shade(t.surface, icon_button.fillDelta(checked, t.dark) * 2)));
    } else if (icon_button.paintsFill(state)) {
        fillRound(hdc, f, pane_sidebar.px(4, self.scale), rgb(shade(t.surface, icon_button.fillDelta(state, t.dark))));
    }
    glyph(hdc, self.scale, l.scope, glyph_windows, 12, t.text);
}

/// The trash-mode toggle (T1845, Mac's `trash` header button): the trash can,
/// red and held filled while trash mode is on - the same checked-toggle
/// vocabulary as the all-windows button beside it.
fn paintTrash(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    if (l.trash.width() <= 0) return;
    const state: icon_button.State = if (self.hoverIs(.trash))
        (if (std.meta.eql(self.pressed, pane_sidebar.Hit.trash)) .pressed else .hover)
    else
        .normal;
    const inset = pane_sidebar.px(2, self.scale); // design system: fill inset xs
    const f: pane_sidebar.Rect = .{ .left = l.trash.left + inset, .top = l.trash.top + inset, .right = l.trash.right - inset, .bottom = l.trash.bottom - inset };
    const red = chrome_theme.dangerInkOn(t.surface);
    if (self.quick_kill) {
        const wash: f64 = if (state == .normal) 0.18 else 0.28;
        fillRound(hdc, f, pane_sidebar.px(4, self.scale), rgb(color_math.mix(t.surface, red, wash)));
    } else if (icon_button.paintsFill(state)) {
        fillRound(hdc, f, pane_sidebar.px(4, self.scale), rgb(shade(t.surface, icon_button.fillDelta(state, t.dark))));
    }
    glyph(hdc, self.scale, l.trash, glyph_trash, 12, if (self.quick_kill) rgb(red) else t.text);
}

/// Trash mode's kill button: a solid red disc with a white x (Mac's
/// `PaneSidebarKillButton`; Windows' own close-button red and white, the one
/// destructive pairing the chrome uses). Darker under the pointer.
fn paintKill(self: *PaneSidebar, hdc: w32.HDC, b: pane_sidebar.Rect, hot: bool, t: Theme) void {
    const d = @min(b.width(), b.height());
    const r: pane_sidebar.Rect = .{
        .left = b.left + @divTrunc(b.width() - d, 2),
        .top = b.top + @divTrunc(b.height() - d, 2),
        .right = b.left + @divTrunc(b.width() - d, 2) + d,
        .bottom = b.top + @divTrunc(b.height() - d, 2) + d,
    };
    const fill = chrome_theme.dangerFillOn(t.surface);
    fillRound(hdc, r, @divTrunc(d, 2), rgb(if (hot) shade(fill, -24) else fill));
    const on = chrome_theme.on_danger_fixed;
    const dip: f32 = @max(@as(f32, @floatFromInt(d)) / self.scale * 0.5, 6);
    glyph(hdc, self.scale, r, glyph_kill, dip, rgb(on));
}

/// The outline's own furniture (T1829): the hairlines between windows and
/// before a stash, each window's STASHED caption, and the project and window
/// headers. Rows are painted by the caller, as in the single roster.
fn paintOutline(self: *PaneSidebar, hdc: w32.HDC, l: *const pane_sidebar.Layout, t: Theme) void {
    const rule_color = rgb(shade(t.surface, if (t.dark) 24 else -24));
    for (l.rules[0..l.rule_count]) |r| fillRect(hdc, r, rule_color);
    for (l.captions[0..l.caption_count]) |cap| {
        const stashed = if (cap.index < self.groups.items.len) self.groups.items[cap.index].stashed else 0;
        var buf: [32]u8 = undefined;
        const text8 = std.fmt.bufPrint(&buf, "STASHED \u{00B7} {d}", .{stashed}) catch "STASHED";
        var wbuf: [32]u16 = undefined;
        const wn = std.unicode.utf8ToUtf16Le(&wbuf, text8) catch 0;
        if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        drawText(hdc, wbuf[0..wn], .{ .left = cap.x, .top = cap.rect.top, .right = cap.rect.right, .bottom = cap.rect.bottom }, t.secondary, w32.DT_VCENTER);
    }
    for (l.heads[0..l.head_count], 0..) |hd, k| {
        if (hd.index >= self.groups.items.len) continue;
        self.paintHead(hdc, hd, k, self.groups.items[hd.index], t);
    }
}

/// A window header (Mac `PaneSidebarWindowHeader`) or a project header
/// (`PaneSidebarProjectHeader`): chevron, name, and at the trailing edge the
/// window's pane count - or its question badge - or the project's window
/// count. Another window's header lights on hover, since a click raises it.
fn paintHead(self: *PaneSidebar, hdc: w32.HDC, hd: pane_sidebar.Head, k: usize, g: Group, t: Theme) void {
    const sm = pane_sidebar.px(pane_sidebar.sm_dip, self.scale);
    const text_inset = pane_sidebar.px(toc.text_inset_dip, self.scale);
    const hovered = self.hoverIs(.{ .head = k }) or self.hoverIs(.{ .head_fold = k });
    const project = hd.kind == .project;
    var under = t.surface;
    if (hovered and (project or !g.own)) {
        const sel = list_selection.rowPaint(t.surface, t.accent, .{ .selected = false, .focused = false, .hovered = true, .focus_visible = false });
        if (sel.fill) |f| {
            fillRound(hdc, hd.rect, pane_sidebar.px(toc.row_corner_dip, self.scale), rgb(f));
            under = f;
        }
    }
    const folded = if (project) self.folded.contains(g.project_key) else self.folded.contains(g.key);
    glyph(hdc, self.scale, hd.chevron, if (folded) glyph_chevron_right else glyph_chevron_down, 8, t.secondary);

    // The trailing count (or badge) first, so the name knows its room.
    var right = hd.rect.right - text_inset;
    const text_r: pane_sidebar.Rect = .{ .left = hd.label_x, .top = hd.chevron.top - pane_sidebar.px(6, self.scale), .right = right, .bottom = hd.chevron.bottom + pane_sidebar.px(6, self.scale) };
    if (!project and g.question) {
        const badge = pane_sidebar.px(16, self.scale);
        const br: pane_sidebar.Rect = .{ .left = right - badge, .top = hd.chevron.centerY() - @divTrunc(badge, 2), .right = right, .bottom = hd.chevron.centerY() - @divTrunc(badge, 2) + badge };
        self.paintQuestion(hdc, br, under, t);
        right = br.left - sm;
    } else {
        var nb: [16]u8 = undefined;
        const count8 = std.fmt.bufPrint(&nb, "{d}", .{if (project) g.project_size else g.panes}) catch "";
        var cw: [16]u16 = undefined;
        const cn = std.unicode.utf8ToUtf16Le(&cw, count8) catch 0;
        if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        const w = textWidth(hdc, cw[0..cn]);
        drawText(hdc, cw[0..cn], .{ .left = right - w, .top = text_r.top, .right = right, .bottom = text_r.bottom }, t.secondary, w32.DT_VCENTER | w32.DT_RIGHT);
        right -= w + sm;
    }

    if (project) {
        if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        drawText(hdc, g.project, .{ .left = hd.label_x, .top = text_r.top, .right = right, .bottom = text_r.bottom }, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
        return;
    }
    // The PARENT row: the window's name at a group's weight, then - on
    // this window's - a quiet "This Window" (a tab of a tabbed window says
    // "This Tab": its window's other tabs are listed beside it).
    if (self.title_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
    const tag = if (g.tabbed) std.unicode.utf8ToUtf16LeStringLiteral("This Tab") else std.unicode.utf8ToUtf16LeStringLiteral("This Window");
    var name_right = right;
    var tag_w: i32 = 0;
    if (g.own) {
        if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        tag_w = textWidth(hdc, tag);
        if (self.title_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        const gap = pane_sidebar.px(5, self.scale);
        const name_w = textWidth(hdc, g.label);
        // The name takes what it needs; the tag gives way first.
        name_right = @min(right, hd.label_x + name_w);
        if (name_right + gap + tag_w > right) name_right = @max(hd.label_x, right - gap - tag_w);
    }
    drawText(hdc, g.label, .{ .left = hd.label_x, .top = text_r.top, .right = name_right, .bottom = text_r.bottom }, t.text, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
    if (g.own) {
        if (self.caption_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        const left = name_right + pane_sidebar.px(5, self.scale);
        drawText(hdc, tag, .{ .left = left, .top = text_r.top, .right = right, .bottom = text_r.bottom }, t.secondary, w32.DT_VCENTER | w32.DT_END_ELLIPSIS);
    }
}

fn textWidth(hdc: w32.HDC, text: []const u16) i32 {
    if (text.len == 0) return 0;
    var r = w32.RECT{ .left = 0, .top = 0, .right = 100000, .bottom = 0 };
    _ = w32.DrawTextW(hdc, text.ptr, @intCast(text.len), &r, w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
    return r.right - r.left;
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
/// badge). Busy has no badge: its mark shimmers instead (T1843).
fn paintBadge(self: *PaneSidebar, hdc: w32.HDC, r: pane_sidebar.Rect, state: ActivityState, t: Theme) void {
    switch (state) {
        .idle, .busy => {},
        .needs_input => {
            fillRound(hdc, r, @divTrunc(r.width(), 2), rgb(t.accent));
            const on = chrome_theme.textOn(t.accent);
            if (self.caption_bold_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
            drawText(hdc, std.unicode.utf8ToUtf16LeStringLiteral("?"), r, rgb(on), w32.DT_CENTER | w32.DT_VCENTER);
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
    for (l.rules[0..l.rule_count]) |r| fillRect(hdc, r, rgb(shade(t.surface, if (t.dark) 24 else -24)));

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
        const busy = e.state == .busy;
        const ink = if (e.selected or busy) t.text else t.secondary;
        const mark: Mark = if (e.icon == glyph_terminal) .{ .text = e.mono } else .{ .glyph = e.icon };
        self.paintMarkFor(hdc, r, mark, ink, sel.fill orelse t.surface, busy);
        // The corner (Mac): the question disc top-right - still, unlike a
        // row's - or else a stashed pane's bell dot.
        const two = pane_sidebar.px(2, self.scale);
        if (e.state == .needs_input) {
            const d = pane_sidebar.px(12, self.scale);
            self.paintBadge(hdc, .{ .left = r.right - d + two, .top = r.top - two, .right = r.right + two, .bottom = r.top - two + d }, .needs_input, t);
        } else if (e.bell and e.section == .stashed) {
            const d = @max(pane_sidebar.px(7, self.scale), 3);
            self.paintBellDot(hdc, r.right - @divTrunc(d, 2) + @divTrunc(two, 2), r.top + @divTrunc(d, 2) - @divTrunc(two, 2), t);
        }
        // Trash mode's x on the opposite corner from the question disc.
        if (self.quick_kill) self.paintKill(hdc, l.tileKill(i, self.scale), self.hoverIs(.{ .item_button = i }), t);
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
// Edge drag (T1846; Mac `PaneSidebarChrome.resizeHandle`)
// -------------------------------------------------------------------------

fn onEdgeAt(self: *PaneSidebar, which: Surface, x: i32, y: i32) bool {
    const l = self.layoutFor(which);
    return pane_sidebar.onEdge(&l, x, y, self.scale);
}

fn screenX(hwnd: w32.HWND, x: i32, y: i32) i32 {
    var pt = w32.POINT{ .x = x, .y = y };
    _ = w32.ClientToScreen(hwnd, &pt);
    return pt.x;
}

fn setSizeCursor() void {
    _ = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_SIZEWE));
}

fn edgeBegin(self: *PaneSidebar, which: Surface, hwnd: w32.HWND, x: i32, y: i32) void {
    self.disarm();
    self.pressed = .none;
    const start = pane_sidebar.edgeStartDip(self.mode, which == .card, self.window.pane_sidebar_width_dip);
    self.edge = .{ .start_dip = start, .start_x = screenX(hwnd, x, y) };
    _ = w32.SetCapture(hwnd);
    setSizeCursor();
    log.info("pane sidebar edge drag start surface={s} mode={s} from={d:.0}", .{ @tagName(which), @tagName(self.mode), start });
}

fn edgeMove(self: *PaneSidebar, which: Surface, hwnd: w32.HWND, x: i32, y: i32) void {
    const d = self.edge orelse return;
    setSizeCursor();
    const dx = @as(f32, @floatFromInt(screenX(hwnd, x, y) - d.start_x)) / self.scale;
    // The mode as it is NOW: a rail pinned earlier in this drag is the
    // panel from here on, and its edge follows the pointer.
    const open = which == .card and self.card_open;
    switch (pane_sidebar.edgeDrag(self.mode, open, d.start_dip, dx) orelse return) {
        .pin => if (!self.window.pane_sidebar_pinned) {
            log.info("pane sidebar edge drag pinned dx={d:.0}", .{dx});
            self.window.togglePaneSidebarPin();
        },
        .width => |w| if (w != self.window.pane_sidebar_width_dip) self.window.setPaneSidebarWidth(w),
    }
}

/// The drag ended - released, or the capture was taken away.
fn edgeEnd(self: *PaneSidebar) void {
    if (self.edge == null) return;
    self.edge = null;
    // The drag moved `remembered.width_dip` live; the file is written once,
    // when it settles (T1847).
    saveRemembered(self.window.app.core_app.alloc);
    log.info("pane sidebar edge drag end pinned={} width={d:.0}", .{ self.window.pane_sidebar_pinned, self.window.pane_sidebar_width_dip });
}

/// The shared panel width moved (another window's edge, or this one's open
/// card): regrow the open card from it. The pinned panel is relaid out by
/// the window, which owns its column.
pub fn widthChanged(self: *PaneSidebar) void {
    if (self.card_open) self.positionCard();
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
    return seatAfterFor(root, c);
}

/// The same seat for any popup `c` owned by `root` that has to sit above its
/// sibling popups: the pane grab handle (T1830) is drawn over a pane's banner.
pub fn seatAfterFor(root: w32.HWND, c: w32.HWND) ?w32.HWND {
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
    const held = w32.GetCapture() == c or self.drag_active or self.menu_open;
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
// Mac's `.help` strings for the all-windows scope (T1829).
const tip_scope_on = W("Show panes from all windows");
const tip_scope_off = W("Show only this window\u{2019}s panes");
const tip_head_this = W("This window \u{2014} click to hide or show its panes");
const tip_head_other = W("Raise this window");
const tip_head_project = W("Hide or show this project\u{2019}s windows");
// Trash mode (T1845).
const tip_trash_on = W(row_menu.trashTip(true));
const tip_trash_off = W(row_menu.trashTip(false));
const tip_kill = W(row_menu.kill_tip);
const tip_restore_row = W(hov.stashed_row_tip);

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
            // Drop the tools of rows and heads that are gone.
            if (self.tip_items[slot] > n) for (n..self.tip_items[slot]) |i| {
                delTool(tip, hwnd, toolItem(i));
                delTool(tip, hwnd, toolButton(i));
            };
            const nh = if (live) l.head_count else 0;
            if (self.tip_heads[slot] > nh) for (nh..self.tip_heads[slot]) |k| delTool(tip, hwnd, toolHead(k));
            self.tip_heads[slot] = nh;
            if (!live) {
                delTool(tip, hwnd, tool_pin);
                delTool(tip, hwnd, tool_scope);
                delTool(tip, hwnd, tool_trash);
            } else {
                addTool(tip, hwnd, tool_pin, l.pin, if (self.window.pane_sidebar_pinned) tip_unpin else tip_pin);
                const rows = l.mode == .expanded or l.open;
                if (rows) {
                    addTool(tip, hwnd, tool_scope, l.scope, if (self.all_windows) tip_scope_off else tip_scope_on);
                    addTool(tip, hwnd, tool_trash, l.trash, if (self.quick_kill) tip_trash_on else tip_trash_off);
                } else {
                    delTool(tip, hwnd, tool_scope);
                    delTool(tip, hwnd, tool_trash);
                }
                for (l.heads[0..nh], 0..) |hd, k| {
                    const own = hd.index < self.groups.items.len and self.groups.items[hd.index].own;
                    const text = if (hd.kind == .project) tip_head_project else if (own) tip_head_this else tip_head_other;
                    addTool(tip, hwnd, toolHead(k), hd.rect, text);
                }
                for (self.entries.items[0..n], 0..) |e, i| {
                    if (!l.shown(i)) {
                        // Folded away: no row, so no tip.
                        delTool(tip, hwnd, toolItem(i));
                        delTool(tip, hwnd, toolButton(i));
                        continue;
                    }
                    if (rows) {
                        // Only this window's stashed rows can swap (T1845).
                        const row_tip = if (e.section != .stashed) tip_focus else if (e.own) tip_restore_row else tip_restore;
                        addTool(tip, hwnd, toolItem(i), l.items[i], row_tip);
                        const btn_tip = if (self.quick_kill) tip_kill else if (e.section == .stashed) tip_restore_btn else tip_stash_btn;
                        addTool(tip, hwnd, toolButton(i), l.rowButton(i, self.scale), btn_tip);
                    } else {
                        // Another window's tile names its window too (Mac: "in
                        // the mini rail ... the hover label names the window").
                        var named: [hov.tip_cap]u16 = undefined;
                        const title = self.tileTitle(e, &named);
                        const len = hov.tileTip(&self.tip_text[i], title, e.section);
                        addTool(tip, hwnd, toolItem(i), l.items[i], self.tip_text[i][0..len :0]);
                        if (self.quick_kill) {
                            addTool(tip, hwnd, toolButton(i), l.tileKill(i, self.scale), tip_kill);
                        } else delTool(tip, hwnd, toolButton(i));
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

/// A rail tile's tip title: the pane's, and for another window's pane also
/// " \u{2014} <window>".
fn tileTitle(self: *const PaneSidebar, e: Entry, buf: *[hov.tip_cap]u16) []const u16 {
    if (e.own or e.group >= self.groups.items.len) return e.title;
    const label = self.groups.items[e.group].label;
    const sep = std.unicode.utf8ToUtf16LeStringLiteral(" \u{2014} ");
    var n: usize = 0;
    for ([_][]const u16{ e.title, sep, label }) |part| {
        const take = @min(part.len, buf.len - n);
        @memcpy(buf[n .. n + take], part[0..take]);
        n += take;
    }
    return buf[0..n];
}

/// `alt`: Alt was down on the click (Mac's Option-click swap, T1845).
fn activate(self: *PaneSidebar, which: Surface, hit: pane_sidebar.Hit, alt: bool) void {
    switch (hit) {
        .none => {},
        .pin => self.window.togglePaneSidebarPin(),
        .scope => self.toggleScope(),
        .trash => self.setQuickKill(!self.quick_kill),
        .item => |i| {
            if (i >= self.entries.items.len) return;
            const e = self.entries.items[i];
            switch (row_menu.clickVerb(e.section, e.own, alt)) {
                .focus, .restore => self.window.paneSidebarActivate(e.pane),
                .exchange => self.window.paneSidebarExchange(e.pane),
                .reveal => self.focusForeign(e),
            }
        },
        .item_button => |i| {
            if (i >= self.entries.items.len) return;
            const e = self.entries.items[i];
            // Trash mode: the button is the red x. The kill can close this
            // very window (its last pane), so nothing here is touched after.
            if (self.quick_kill) return killEntry(self.window, e);
            if (e.own) return self.window.paneSidebarToggleStash(e.pane);
            // Another window's pane is stashed or restored in ITS window; a
            // pane in a background tab there is left alone (its window's own
            // check refuses it).
            if (!self.window.app.hasWindow(e.window)) return;
            e.window.paneSidebarToggleStash(e.pane);
        },
        .head, .head_fold => |k| self.activateHead(which, k, std.meta.activeTag(hit) == .head_fold),
    }
}

/// The all-windows switch (T1829). Folds survive a round trip, as Mac's do;
/// nothing is persisted.
fn toggleScope(self: *PaneSidebar) void {
    self.all_windows = !self.all_windows;
    self.hover = .none;
    self.signature = 0;
    log.info("pane sidebar scope all_windows={}", .{self.all_windows});
    self.refresh();
}

/// Trash mode on or off (T1845): the header button, or Escape. Repaints both
/// surfaces - the rail's tiles carry the x too - and re-sets the tips, whose
/// row buttons now mean "kill".
pub fn setQuickKill(self: *PaneSidebar, on: bool) void {
    if (self.quick_kill == on) return;
    self.quick_kill = on;
    self.hover = .none;
    log.info("pane sidebar trash mode on={}", .{on});
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    if (self.card_hwnd) |c| _ = w32.InvalidateRect(c, null, 0);
    self.syncTips();
}

/// The window an entry's pane lives in, if it is still open: this sidebar's
/// own, or - for another window's row - that one, asked about first.
fn rowWindow(self: *PaneSidebar, e: Entry) ?*Window {
    if (e.own) return self.window;
    if (!self.window.app.hasWindow(e.window)) return null;
    return e.window;
}

/// Kill an entry's pane in the window that holds it. May close that window -
/// THIS one, when it is the last pane here - so callers return right after.
fn killEntry(own_window: *Window, e: Entry) void {
    const w = if (e.own) own_window else blk: {
        if (!own_window.app.hasWindow(e.window)) return;
        break :blk e.window;
    };
    w.paneSidebarKill(e.pane);
}

/// A row's or tile's right-click menu (T1845, Mac `PaneSidebarRow
/// .contextMenu`). The menu's modal loop pumps messages, so the roster can be
/// rebuilt while it is up: the pane and its window are captured first and
/// asked about again before the chosen command runs.
fn openRowMenu(self: *PaneSidebar, which: Surface, hwnd: w32.HWND, i: usize, x: i32, y: i32) void {
    if (i >= self.entries.items.len) return;
    const e = self.entries.items[i];
    const w = self.rowWindow(e) orelse return;
    var items: [row_menu.max_items]row_menu.Item = undefined;
    const list = row_menu.build(.{
        .section = e.section,
        .own = e.own,
        .can_stash = w.paneSidebarCanStash(e.pane),
        .can_pop_out = w.paneSidebarCanPopOut(e.pane),
    }, &items);

    const popup = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(popup);
    for (list) |item| switch (item) {
        .separator => _ = w32.AppendMenuW(popup, w32.MF_SEPARATOR, 0, null),
        .cmd => |c| {
            var wbuf: [64]u16 = undefined;
            const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], c.title) catch continue;
            wbuf[n] = 0;
            var flags: u32 = w32.MF_STRING;
            if (!c.enabled) flags |= w32.MF_GRAYED;
            _ = w32.AppendMenuW(popup, flags, @intFromEnum(c.id), @ptrCast(&wbuf));
        },
    };

    var pt = w32.POINT{ .x = x, .y = y };
    _ = w32.ClientToScreen(hwnd, &pt);
    log.info("pane sidebar row menu open section={s} own={}", .{ @tagName(e.section), e.own });
    self.menu_open = true;
    const cmd = w32.TrackPopupMenuEx(
        popup,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD | w32.TPM_RIGHTBUTTON,
        pt.x,
        pt.y,
        hwnd,
        null,
    );
    self.menu_open = false;
    // Off the card while the menu held it: the grace period starts now.
    if (which == .card and self.card_open and !self.pointerOn(.card, null)) self.scheduleClose();

    const id = std.meta.intToEnum(row_menu.Id, @as(usize, @intCast(cmd))) catch return; // 0 = dismissed
    // Still open, and the pane still in it?
    if (!self.window.app.hasWindow(w) or w.findTabIndex(e.pane) == null) return;
    log.info("pane sidebar row menu choice={s}", .{@tagName(id)});
    switch (id) {
        .restore => if (e.own) w.paneSidebarActivate(e.pane) else self.focusForeign(e),
        .exchange => w.paneSidebarExchange(e.pane),
        .stash => w.paneSidebarToggleStash(e.pane),
        .show => self.focusForeign(e),
        .pop_out => w.paneSidebarPopOut(e.pane),
        // May free the pane, and close its window: nothing after.
        .close => w.paneSidebarClose(e.pane),
    }
}

/// A header click: a project header folds its windows; a window header's
/// chevron - or THIS window's header anywhere - folds its panes; another
/// window's header raises that window (Mac `PaneSidebarWindowHeader`).
fn activateHead(self: *PaneSidebar, which: Surface, k: usize, fold: bool) void {
    const l = self.layoutFor(which);
    if (k >= l.head_count) return;
    const hd = l.heads[k];
    if (hd.index >= self.groups.items.len) return;
    const g = self.groups.items[hd.index];
    if (hd.kind == .project) return self.toggleFold(g.project_key);
    if (fold or g.own) return self.toggleFold(g.key);
    self.raiseGroup(g);
}

fn toggleFold(self: *PaneSidebar, key: u64) void {
    if (self.folded.remove(key)) {
        log.info("pane sidebar unfold", .{});
    } else {
        self.folded.put(self.alloc, key, {}) catch return;
        log.info("pane sidebar fold", .{});
    }
    self.refresh();
}

/// Raise another window and show the tab the group is (`ghoztty://focus`'s
/// own verb, `IpcHandlers.focusTarget`). The tab is found again by its
/// identity: tabs reorder, and the window may have closed since the refresh.
fn raiseGroup(self: *PaneSidebar, g: Group) void {
    if (!self.window.app.hasWindow(g.window)) return;
    const w = g.window;
    const tab = for (0..w.tab_count) |t| {
        if (tabKey(w, t) == g.key) break t;
    } else return;
    log.info("pane sidebar raise window tab={d} active={d}", .{ tab, w.active_tab });
    IpcHandlers.focusTarget(.{ .window = w });
    if (tab != w.active_tab) w.selectTabIndex(tab);
}

/// Another window's row: raise that window and focus the pane - restoring it
/// there if it is stashed, selecting its tab if it is in the background - the
/// same verb as `ghoztty://focus` (Mac `IPCServer.focusTarget`).
fn focusForeign(self: *PaneSidebar, e: Entry) void {
    if (!self.window.app.hasWindow(e.window)) return;
    if (e.window.tabIndexOfPane(e.pane) == null) return;
    log.info("pane sidebar focus other window section={s}", .{@tagName(e.section)});
    IpcHandlers.focusTarget(.{ .pane = e.pane });
}

/// Alt, from the queue's key state as of the message being handled - mouse
/// messages carry no MK_ flag for it.
fn altDown() bool {
    return w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0;
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
                TIMER_ANIM => self.onMotionTick(which),
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
        // The edge's sizer (T1846): over the band, and for the whole drag.
        w32.WM_SETCURSOR => {
            if (self.edge != null) {
                setSizeCursor();
                return 1;
            }
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0 and w32.ScreenToClient(hwnd, &pt) != 0 and self.onEdgeAt(which, pt.x, pt.y)) {
                setSizeCursor();
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CAPTURECHANGED => {
            self.edgeEnd();
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            const x = xOf(lparam);
            const y = yOf(lparam);
            if (self.edge != null) {
                self.edgeMove(which, hwnd, x, y);
                return 0;
            }
            if (self.maybeStartRowDrag(hwnd, x, y)) return 0;
            // On the edge the pointer means the sizer, not the row under it,
            // and not the rail's hover-open either.
            const on_edge = self.onEdgeAt(which, x, y);
            self.setHover(which, if (on_edge) .none else self.hitAt(which, x, y));
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
                .rail => if (on_edge) self.disarm() else self.railPointer(x, y),
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
            if (self.onEdgeAt(which, self.press_x, self.press_y)) {
                self.edgeBegin(which, hwnd, self.press_x, self.press_y);
                return 0;
            }
            self.pressed = self.hitAt(which, self.press_x, self.press_y);
            // Alt is the click's modifier when it is down at the PRESS (a
            // swap the user started holding Alt is a swap even if Alt comes
            // up first).
            self.press_alt = altDown();
            _ = w32.SetCapture(hwnd);
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (self.edge != null) {
                // The release lands where the last move did; ending here
                // rather than only on WM_CAPTURECHANGED keeps the log line
                // ahead of anything the release triggers.
                self.edgeMove(which, hwnd, xOf(lparam), yOf(lparam));
                self.edgeEnd();
                _ = w32.ReleaseCapture();
                if (which == .card and self.card_open and !self.pointerOn(.card, null)) self.scheduleClose();
                return 0;
            }
            _ = w32.ReleaseCapture();
            const hit = self.hitAt(which, xOf(lparam), yOf(lparam));
            const pressed = self.pressed;
            self.pressed = .none;
            _ = w32.InvalidateRect(hwnd, null, 0);
            const alt = self.press_alt or altDown();
            self.press_alt = false;
            if (std.meta.eql(hit, pressed)) self.activate(which, hit, alt);
            // Let go off the card while it was held open: the grace period
            // the hold deferred starts now.
            if (which == .card and self.card_open and !self.pointerOn(.card, null)) self.scheduleClose();
            return 0;
        },
        // The row menu opens on the release, the Windows convention (a
        // shell list's context menu does), over the row under the pointer.
        w32.WM_RBUTTONDOWN => return 0,
        w32.WM_RBUTTONUP => {
            const x = xOf(lparam);
            const y = yOf(lparam);
            switch (self.hitAt(which, x, y)) {
                .item, .item_button => |i| self.openRowMenu(which, hwnd, i, x, y),
                else => {},
            }
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
