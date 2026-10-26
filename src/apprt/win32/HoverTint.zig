//! The tint a pane takes while its sidebar row or tile is under the pointer
//! (T2278): Mac's `PaneSidebarHoverTint`, a 10% wash and a 2 DIP 45% rim in
//! the pane's own hue, faded in quickly and back out a touch slower.
//!
//! The `BellBorder` shape (T1919): a WS_EX_LAYERED popup owned by the pane's
//! child HWND, so DWM composites it above OpenGL and WebView2 content alike,
//! WS_EX_TRANSPARENT so it never takes the pointer (Mac's
//! `.allowsHitTesting(false)`), and per-pixel alpha through
//! UpdateLayeredWindow. The fade is the blend's `SourceConstantAlpha`, stepped
//! by a timer on this popup's own HWND, so a fade step never re-renders. Pure
//! logic (hue, pixels, curve) is `pane_hue.zig`.

const std = @import("std");
const w32 = @import("win32.zig");
const pane_clip = @import("pane_clip.zig");
const pane_hue = @import("pane_hue.zig");
const color_math = @import("color_math.zig");
const chrome_fanout = @import("chrome_fanout.zig");

const log = std.log.scoped(.win32_hover_tint);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyHoverTint");

const FADE_TIMER_ID: usize = 1;
const FADE_TICK_MS: u32 = 16;

pub const HoverTint = struct {
    alloc: std.mem.Allocator,
    /// The pane child HWND this tint covers (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,

    /// The popup is shown (it may be mid fade-out at any alpha).
    shown: bool = false,
    /// What was last rendered: where (screen pixels), in what, in what shape.
    placed: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    color: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    rim_px: i32 = 0,
    shape: pane_hue.Shape = .{},
    alpha: u8 = 0,
    fade_from: u8 = 0,
    fade_to: u8 = 0,
    fade_t0_ms: i64 = 0,
    /// See `DimOverlay.matchOwnerRegion` (T1831).
    region_key: u64 = 0,
    /// Render scratch, grown to the largest pane seen.
    px: []u32 = &.{},

    pub fn create(alloc: std.mem.Allocator, owner: w32.HWND, hinstance: w32.HINSTANCE) !*HoverTint {
        try registerClassOnce(hinstance);
        const self = try alloc.create(HoverTint);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .owner = owner, .hwnd = undefined };
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_TRANSPARENT |
            w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW;
        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP,
            0,
            0,
            1,
            1, // placeholder - update() glues it to the owner
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *HoverTint) void {
        _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
        _ = w32.DestroyWindow(self.hwnd);
        if (self.px.len > 0) self.alloc.free(self.px);
        self.alloc.destroy(self);
    }

    /// Bring the tint in line with `want` (this pane's sidebar row or tile is
    /// hovered), in `c`, following `shape`. Idempotent, so it rides every
    /// layout pass and keeps the tint glued to the pane through a resize, a
    /// divider drag and a move.
    pub fn update(self: *HoverTint, want: bool, c: color_math.Rgb, shape: pane_hue.Shape, scale: f32) void {
        // A pane on a background tab, stashed, behind a zoom or mid-slide has
        // nothing to tint: gone at once, no fade.
        if (!pane_clip.ownerWhollyInView(self.owner)) {
            self.hideNow();
            return;
        }
        if (!want) {
            if (self.shown) self.startFade(0);
            return;
        }
        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(self.owner, &rect) == 0) return;
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        if (w <= 0 or h <= 0) {
            self.hideNow();
            return;
        }
        const rim_px = pane_hue.rimPx(scale);
        const restyled = w != self.placed.right - self.placed.left or
            h != self.placed.bottom - self.placed.top or rim_px != self.rim_px or
            !c.eql(self.color) or !std.meta.eql(shape, self.shape);
        const moved = !std.meta.eql(rect, self.placed);
        const was_shown = self.shown;

        if (!was_shown or restyled) {
            if (!self.render(rect, c, rim_px, shape)) return;
        } else if (moved) {
            chrome_fanout.noteMove(.dim);
            _ = w32.SetWindowPos(self.hwnd, null, rect.left, rect.top, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_NOSIZE);
        }
        self.placed = rect;
        self.color = c;
        self.rim_px = rim_px;
        self.shape = shape;

        if (!was_shown) {
            _ = w32.ShowWindow(self.hwnd, w32.SW_SHOWNOACTIVATE);
            self.shown = true;
            log.info("hover tint shown rgb={d},{d},{d} radius={d} rect={d},{d},{d}x{d}", .{ c.r, c.g, c.b, shape.radius, rect.left, rect.top, w, h });
        }
        if (self.fade_to != 255) self.startFade(255);
        w32.healOverlayZOrderAfterMove(self.hwnd, self.owner, was_shown);
    }

    /// Clip the tint to the owner's window region - an elevated pane is a
    /// rounded card (T1831). Same contract as `DimOverlay.matchOwnerRegion`.
    pub fn matchOwnerRegion(self: *HoverTint, key: u64) void {
        if (key == self.region_key) return;
        self.region_key = key;
        if (key == 0) {
            _ = w32.SetWindowRgn(self.hwnd, null, 1);
            return;
        }
        const rgn = w32.CreateRectRgn(0, 0, 0, 0) orelse return;
        if (w32.GetWindowRgn(self.owner, rgn) == 0 or w32.SetWindowRgn(self.hwnd, rgn, 1) == 0) {
            _ = w32.DeleteObject(rgn);
            self.region_key = 0;
        }
    }

    /// The uniform name every pane popup answers (T2012).
    pub fn hide(self: *HoverTint) void {
        self.hideNow();
    }

    pub fn hideNow(self: *HoverTint) void {
        _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
        self.alpha = 0;
        self.fade_from = 0;
        self.fade_to = 0;
        if (!self.shown) return;
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.shown = false;
        log.info("hover tint hidden", .{});
    }

    fn startFade(self: *HoverTint, to: u8) void {
        if (self.fade_to == to) return;
        self.fade_from = self.alpha;
        self.fade_to = to;
        self.fade_t0_ms = std.time.milliTimestamp();
        _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, FADE_TICK_MS, null);
    }

    fn fadeTick(self: *HoverTint) void {
        const elapsed = std.time.milliTimestamp() - self.fade_t0_ms;
        const a = pane_hue.fadeAlpha(self.fade_from, self.fade_to, elapsed);
        self.setAlpha(a);
        if (a != self.fade_to) return;
        _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
        log.info("hover tint fade done alpha={d} ms={d}", .{ a, elapsed });
        if (a == 0) self.hideNow();
    }

    /// Change only the blend: no source DC, so the tint is not re-rendered.
    fn setAlpha(self: *HoverTint, a: u8) void {
        if (a == self.alpha) return;
        self.alpha = a;
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = a };
        _ = w32.UpdateLayeredWindow(self.hwnd, null, null, null, null, null, 0, &blend, w32.ULW_ALPHA);
    }

    fn render(self: *HoverTint, rect: w32.RECT, c: color_math.Rgb, rim_px: i32, shape: pane_hue.Shape) bool {
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        const n: usize = @intCast(w * h);
        if (self.px.len < n) {
            if (self.px.len > 0) self.alloc.free(self.px);
            self.px = self.alloc.alloc(u32, n) catch {
                self.px = &.{};
                return false;
            };
        }
        pane_hue.renderTint(self.px[0..n], w, h, c, rim_px, shape);

        const screen_dc = w32.GetDC(null) orelse return false;
        defer _ = w32.ReleaseDC(null, screen_dc);
        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return false;
        defer _ = w32.DeleteDC(mem_dc);
        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{ .bmiHeader = .{ .biWidth = w, .biHeight = -h } };
        const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return false;
        defer _ = w32.DeleteObject(bitmap);
        const old_bmp = w32.SelectObject(mem_dc, bitmap) orelse return false;
        defer _ = w32.SelectObject(mem_dc, old_bmp);
        const dst: [*]u32 = @ptrCast(@alignCast(bits.?));
        @memcpy(dst[0..n], self.px[0..n]);

        chrome_fanout.noteMove(.dim);
        const dst_pt = w32.POINT{ .x = rect.left, .y = rect.top };
        const dst_size = w32.SIZE{ .cx = w, .cy = h };
        const src_pt = w32.POINT{ .x = 0, .y = 0 };
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = self.alpha };
        return w32.UpdateLayeredWindow(self.hwnd, screen_dc, &dst_pt, &dst_size, mem_dc, &src_pt, 0, &blend, w32.ULW_ALPHA) != 0;
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = tintWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn tintWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*HoverTint = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_TIMER => {
            if (wparam == FADE_TIMER_ID) self.fadeTick();
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
