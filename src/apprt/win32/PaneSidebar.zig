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
//! The roster is rebuilt only when what it shows changed — `refresh` hashes
//! the panes, their titles, banners, states and the selection first — because
//! it is asked on every layout pass, and a divider drag is a layout pass per
//! mouse move.

const PaneSidebar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const pane_sidebar = @import("pane_sidebar.zig");
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
const PaneView = @import("PaneView.zig");
const Window = @import("Window.zig");
const ActivityState = @import("../../terminal/main.zig").osc.Command.ActivityState;

const log = std.log.scoped(.pane_sidebar);

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyPaneSidebar");

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

title_font: ?*anyopaque = null,
caption_font: ?*anyopaque = null,
caption_bold_font: ?*anyopaque = null,
font_scale: f32 = 0,
metrics: pane_sidebar.TextMetrics = .{ .title_h = 19, .caption_h = 16 },

// The rail's card backdrop, cached like the TOC card's.
card_dc: ?w32.HDC = null,
card_bmp: ?*anyopaque = null,
card_w: i32 = 0,
card_h: i32 = 0,
card_bg: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
card_scale: f32 = 0,

var class_registered: bool = false;

fn registerClass(hinstance: ?w32.HINSTANCE) void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // CS_HREDRAW | CS_VREDRAW (design system §5c): the panel's rule and
        // the rail's card are drawn against the window's own bounds.
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // every pixel painted in WM_PAINT
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("pane sidebar class registration failed", .{});
        return;
    }
    class_registered = true;
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
    _ = w32.DestroyWindow(self.hwnd);
    self.clearEntries();
    self.entries.deinit(self.alloc);
    self.releaseCard();
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
    var r: w32.RECT = undefined;
    if (w32.GetClientRect(self.hwnd, &r) == 0) return .{};
    var items: [pane_sidebar.max_items]pane_sidebar.Item = undefined;
    const n = @min(self.entries.items.len, items.len);
    for (self.entries.items[0..n], 0..) |e, i| {
        items[i] = .{ .section = e.section, .two_line = e.subtitle.len > 0 };
    }
    self.ensureFonts();
    return pane_sidebar.layout(self.mode, r.right - r.left, r.bottom - r.top, items[0..n], self.metrics, self.scale);
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

fn paint(self: *PaneSidebar, hdc: w32.HDC, width: i32, height: i32) void {
    const t = self.theme();
    const l = self.currentLayout();
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
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
        drawText(hdc, wbuf[0..wn], .{ .left = l.caption_x, .top = cap.top, .right = l.width, .bottom = cap.bottom }, t.secondary, w32.DT_VCENTER);
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
    self.ensureCard(hdc, l.width, l.height, t.bg);
    if (self.card_dc) |mem| {
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
}

fn ensureCard(self: *PaneSidebar, hdc: w32.HDC, w: i32, h: i32, bg: color_math.Rgb) void {
    const stale = self.card_dc == null or self.card_w != w or self.card_h != h or
        !std.meta.eql(self.card_bg, bg) or self.card_scale != self.scale;
    if (!stale) return;
    self.releaseCard();
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
    // material draws lands exactly on `layout().card`.
    banner_card.render(pixels[0..@intCast(w * h)], banner_card.Metrics.init(w, h, self.scale), bg);

    self.card_dc = mem_dc;
    self.card_bmp = bmp;
    self.card_w = w;
    self.card_h = h;
    self.card_bg = bg;
    self.card_scale = self.scale;
}

fn releaseCard(self: *PaneSidebar) void {
    if (self.card_dc) |dc| _ = w32.DeleteDC(dc);
    if (self.card_bmp) |b| _ = w32.DeleteObject(b);
    self.card_dc = null;
    self.card_bmp = null;
    self.card_w = 0;
    self.card_h = 0;
    self.card_scale = 0;
}

/// Double-buffered: the whole column is drawn into a memory DC and blitted
/// once, so a refresh never shows a half-painted list.
fn paintBuffered(self: *PaneSidebar, hdc: w32.HDC, width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;
    const mem = w32.CreateCompatibleDC(hdc) orelse return self.paint(hdc, width, height);
    defer _ = w32.DeleteDC(mem);
    const bmp = w32.CreateCompatibleBitmap(hdc, width, height) orelse return self.paint(hdc, width, height);
    defer _ = w32.DeleteObject(bmp);
    const old = w32.SelectObject(mem, bmp);
    defer _ = w32.SelectObject(mem, old);
    self.paint(mem, width, height);
    _ = w32.BitBlt(hdc, 0, 0, width, height, mem, 0, 0, w32.SRCCOPY);
}

// -------------------------------------------------------------------------
// Input
// -------------------------------------------------------------------------

fn hitAt(self: *PaneSidebar, x: i32, y: i32) pane_sidebar.Hit {
    const l = self.currentLayout();
    return pane_sidebar.hitTest(&l, x, y, self.scale);
}

fn setHover(self: *PaneSidebar, hit: pane_sidebar.Hit) void {
    if (std.meta.eql(self.hover, hit)) return;
    self.hover = hit;
    _ = w32.InvalidateRect(self.hwnd, null, 0);
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
    switch (msg) {
        w32.WM_ERASEBKGND => return 1,
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) != 0) self.paintBuffered(hdc, r.right - r.left, r.bottom - r.top);
            return 0;
        },
        // The same column into a caller's DC, so a pixel probe can photograph
        // it synchronously (the TOC card's T835 reason).
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) == 0) return 0;
            self.paint(@ptrFromInt(wparam), r.right - r.left, r.bottom - r.top);
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            self.setHover(self.hitAt(xOf(lparam), yOf(lparam)));
            if (!self.tracking) {
                var tme = w32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (w32.TrackMouseEvent(&tme) != 0) self.tracking = true;
            }
            return 0;
        },
        w32.WM_MOUSELEAVE => {
            self.tracking = false;
            self.pressed = .none;
            self.setHover(.none);
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            // Activation is on the up over the same target (the standard
            // button affordance), so a press that slides off does nothing.
            self.pressed = self.hitAt(xOf(lparam), yOf(lparam));
            _ = w32.SetCapture(hwnd);
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            _ = w32.ReleaseCapture();
            const hit = self.hitAt(xOf(lparam), yOf(lparam));
            const pressed = self.pressed;
            self.pressed = .none;
            _ = w32.InvalidateRect(hwnd, null, 0);
            if (std.meta.eql(hit, pressed)) self.activate(hit);
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
