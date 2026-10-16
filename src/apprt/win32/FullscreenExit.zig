//! The "Exit full screen" button (T2011): a chip in the top-right corner of
//! a full-screen window. It shows as a notice on entry ("Press F11 to exit
//! full screen") and again whenever the pointer is pushed against the top
//! edge. Clicking it leaves full screen.
//!
//! The window half of `fullscreen_exit.zig`, which owns every decision,
//! number and color. It is the read-only badge's machinery (`ReadonlyBadge`)
//! owned by the TOP-LEVEL window instead of a pane, because full screen is a
//! window state: a `WS_EX_LAYERED` popup painted by `UpdateLayeredWindow`,
//! never `WM_PAINT`, `WS_EX_NOACTIVATE` so a click never takes focus from
//! the terminal, and NOT `WS_EX_TRANSPARENT`, because the chip is the way
//! out.

const std = @import("std");
const w32 = @import("win32.zig");
const fx = @import("fullscreen_exit.zig");
const badge = @import("readonly_badge.zig");
const icon_paint = @import("icon_button_paint.zig");
const color_math = @import("color_math.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_fullscreen_exit);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyFullscreenExit");

/// Fluent/MDL2 `BackToWindow`: the system's own "leave full screen" mark
/// (Movies & TV, Photos). The label carries the meaning on a machine with
/// neither icon face.
const GLYPH: u16 = 0xE73F;

const ui_face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");

pub const FullscreenExit = struct {
    alloc: std.mem.Allocator,
    /// The full-screen window. It owns this button and destroys it in its
    /// own deinit, so the pointer cannot outlive it.
    window: *Window,
    owner: w32.HWND,
    hwnd: w32.HWND,

    font: ?*anyopaque = null,
    scale: f32 = 0,
    mode: fx.Mode = .hidden,
    /// The label currently painted, UTF-16, and its length.
    text: [96]u16 = undefined,
    text_len: usize = 0,
    /// Last placed rect (screen) and painted background, so an unchanged
    /// tick repaints nothing.
    placed: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    painted_bg: ?color_math.Rgb = null,
    /// Bottom of the card relative to the owner's top, for the hold zone.
    card_bottom: i32 = 0,
    visible: bool = false,

    bgr: []u32 = &.{},
    mask: []u8 = &.{},

    pub fn create(
        alloc: std.mem.Allocator,
        window: *Window,
        owner: w32.HWND,
        hinstance: w32.HINSTANCE,
    ) !*FullscreenExit {
        try registerClassOnce(hinstance);
        const self = try alloc.create(FullscreenExit);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .window = window, .owner = owner, .hwnd = undefined };

        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE |
            w32.WS_EX_TOOLWINDOW;
        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP,
            0,
            0,
            1,
            1,
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *FullscreenExit) void {
        _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(self.hwnd);
        if (self.font) |f| _ = w32.DeleteObject(f);
        if (self.bgr.len > 0) self.alloc.free(self.bgr);
        if (self.mask.len > 0) self.alloc.free(self.mask);
        self.alloc.destroy(self);
    }

    /// Show the chip in `mode` (hide on `.hidden`). `key` is the live
    /// trigger text for the notice. Idempotent and cheap when nothing
    /// changed, because the poll calls it ten times a second.
    pub fn show(self: *FullscreenExit, mode: fx.Mode, key: ?[]const u8, scale: f32, bg: color_math.Rgb) void {
        if (mode == .hidden) {
            self.hide();
            return;
        }
        var owner_rect: w32.RECT = undefined;
        if (w32.GetWindowRect(self.owner, &owner_rect) == 0) return;

        const m = badge.Metrics.init(scale);
        var relabel = mode != self.mode;
        if (scale != self.scale) {
            self.scale = scale;
            if (self.font) |f| _ = w32.DeleteObject(f);
            self.font = w32.CreateFontW(-m.font_px, 0, 0, 0, 600, 0, 0, 0, w32.DEFAULT_CHARSET, 0, 0, w32.ANTIALIASED_QUALITY, 0, ui_face);
            relabel = true;
        }
        if (relabel) {
            var buf: [96]u8 = undefined;
            const utf8 = fx.label(mode, key, &buf);
            self.text_len = std.unicode.utf8ToUtf16Le(&self.text, utf8) catch 0;
            self.placed = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        }
        self.mode = mode;

        const ext = self.measure();
        const l = fx.layout(m, owner_rect.right - owner_rect.left, owner_rect.bottom - owner_rect.top, ext.cx, ext.cy);
        if (l.hidden) {
            self.hide();
            return;
        }
        const rect = w32.RECT{
            .left = owner_rect.left + l.win.left,
            .top = owner_rect.top + l.win.top,
            .right = owner_rect.left + l.win.right,
            .bottom = owner_rect.top + l.win.bottom,
        };
        self.card_bottom = l.win.top + l.card.bottom;
        const moved = !std.meta.eql(self.placed, rect);
        const bg_changed = self.painted_bg == null or !self.painted_bg.?.eql(bg);
        if (!moved and !bg_changed and self.visible) return;
        self.placed = rect;
        self.painted_bg = bg;

        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            rect.left,
            rect.top,
            @max(rect.right - rect.left, 1),
            @max(rect.bottom - rect.top, 1),
            w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW,
        );
        if (!self.visible) log.info("fullscreen exit button shown mode={t}", .{mode});
        self.visible = true;
        self.repaint(m, l, bg, rect);
    }

    pub fn hide(self: *FullscreenExit) void {
        self.mode = .hidden;
        if (!self.visible) return;
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.visible = false;
    }

    fn measure(self: *FullscreenExit) w32.SIZE {
        var size = w32.SIZE{ .cx = 0, .cy = 0 };
        const font = self.font orelse return size;
        const dc = w32.GetDC(null) orelse return size;
        defer _ = w32.ReleaseDC(null, dc);
        const old = w32.SelectObject(dc, font) orelse return size;
        defer _ = w32.SelectObject(dc, old);
        _ = w32.GetTextExtentPoint32W(dc, &self.text, @intCast(self.text_len), &size);
        return size;
    }

    /// The badge's paint, in this chip's colors: card into a DIB, GDI glyph
    /// and label on top, then the mask re-applied and premultiplied (see
    /// `ReadonlyBadge.repaint` for why the order is the whole trick).
    fn repaint(self: *FullscreenExit, m: badge.Metrics, l: badge.Layout, bg: color_math.Rgb, rect: w32.RECT) void {
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        if (w <= 0 or h <= 0) return;
        const n: usize = @intCast(w * h);
        if (!self.ensureSurfaces(n)) return;
        fx.render(self.bgr[0..n], self.mask[0..n], m, l, bg);

        const screen_dc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, screen_dc);
        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);
        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{ .bmiHeader = .{ .biWidth = w, .biHeight = -h } };
        const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
        defer _ = w32.DeleteObject(bitmap);
        const old_bmp = w32.SelectObject(mem_dc, bitmap) orelse return;
        defer _ = w32.SelectObject(mem_dc, old_bmp);

        const pxs: [*]u32 = @ptrCast(@alignCast(bits.?));
        @memcpy(pxs[0..n], self.bgr[0..n]);

        const fg = fx.labelColor(fx.fillColor(bg));
        const text_color = w32.RGB(fg.r, fg.g, fg.b);
        _ = icon_paint.fontCodepoint(
            mem_dc,
            m.scale,
            .{ .left = l.glyph.left, .top = l.glyph.top, .right = l.glyph.right, .bottom = l.glyph.bottom },
            GLYPH,
            badge.GLYPH,
            text_color,
        );
        if (self.font) |font| {
            const old_font = w32.SelectObject(mem_dc, font);
            defer if (old_font) |f| {
                _ = w32.SelectObject(mem_dc, f);
            };
            const old_bk = w32.SetBkMode(mem_dc, w32.TRANSPARENT);
            defer _ = w32.SetBkMode(mem_dc, old_bk);
            const old_color = w32.SetTextColor(mem_dc, text_color);
            defer _ = w32.SetTextColor(mem_dc, old_color);
            var tr = w32.RECT{ .left = l.text.left, .top = l.text.top, .right = l.text.right, .bottom = l.text.bottom };
            _ = w32.DrawTextW(
                mem_dc,
                &self.text,
                @intCast(self.text_len),
                &tr,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX | w32.DT_END_ELLIPSIS,
            );
        }

        for (pxs[0..n], self.mask[0..n]) |*p, a| {
            if (a == 0) {
                p.* = 0;
                continue;
            }
            const af: u32 = a;
            const r = (((p.* >> 16) & 0xFF) * af + 127) / 255;
            const g = (((p.* >> 8) & 0xFF) * af + 127) / 255;
            const b = ((p.* & 0xFF) * af + 127) / 255;
            p.* = (af << 24) | (r << 16) | (g << 8) | b;
        }

        const dst_pt = w32.POINT{ .x = rect.left, .y = rect.top };
        const dst_size = w32.SIZE{ .cx = w, .cy = h };
        const src_pt = w32.POINT{ .x = 0, .y = 0 };
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = 255 };
        _ = w32.UpdateLayeredWindow(self.hwnd, screen_dc, &dst_pt, &dst_size, mem_dc, &src_pt, 0, &blend, w32.ULW_ALPHA);
    }

    fn ensureSurfaces(self: *FullscreenExit, n: usize) bool {
        if (self.bgr.len >= n and self.mask.len >= n) return true;
        if (self.bgr.len > 0) self.alloc.free(self.bgr);
        if (self.mask.len > 0) self.alloc.free(self.mask);
        self.bgr = self.alloc.alloc(u32, n) catch {
            self.bgr = &.{};
            self.mask = &.{};
            return false;
        };
        self.mask = self.alloc.alloc(u8, n) catch {
            self.alloc.free(self.bgr);
            self.bgr = &.{};
            self.mask = &.{};
            return false;
        };
        return true;
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = exitWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_HAND),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn exitWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*FullscreenExit = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        // Deliver the click, never the activation.
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_LBUTTONUP => {
            // Leaving full screen hides and may destroy nothing here (the
            // window keeps the button for the next entry), so `self` stays
            // valid across the call.
            self.window.leaveFullscreen(.exit_button);
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
