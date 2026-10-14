//! The `bell-features = border` frame (T1919): Mac's
//! `SurfaceView.BellBorderOverlay`, a soft yellow stroke around a pane that
//! rang its bell, there until the pane is looked at.
//!
//! Like DimOverlay it is a WS_EX_LAYERED popup owned by the surface HWND, so
//! DWM composites it above the pane's OpenGL content, and WS_EX_TRANSPARENT
//! makes it click-through (Mac's `.allowsHitTesting(false)`). Unlike the dim
//! wash it is HOLLOW, so it paints with per-pixel alpha through
//! UpdateLayeredWindow (the ReadonlyBadge/Scrollbar path): the frame pixels
//! carry the 50% yellow, the interior is fully transparent.
//!
//! The 0.3s easeInOut fade is the blend's `SourceConstantAlpha`, stepped by a
//! timer on this popup's own HWND. A fade step re-issues UpdateLayeredWindow
//! with no source DC - the documented way to change only the blend - so it
//! never re-renders the frame. Pure logic (stroke width, frame pixels, the
//! curve) is in bell_math.zig and unit-tested in every lane.

const std = @import("std");
const w32 = @import("win32.zig");
const bell_math = @import("bell_math.zig");
const chrome_fanout = @import("chrome_fanout.zig");

const log = std.log.scoped(.win32_bell_border);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyBellBorder");

/// The fade tick, on this popup's own HWND (its own timer-id space).
const FADE_TIMER_ID: usize = 1;
const FADE_TICK_MS: u32 = 16;

pub const BellBorder = struct {
    alloc: std.mem.Allocator,
    /// The surface HWND this frame surrounds (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,

    /// The popup is shown (it may be mid fade-out at any alpha).
    shown: bool = false,
    /// Where the frame was last placed, in screen pixels.
    placed: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    /// The stroke width the frame was last rendered at.
    width_px: i32 = 0,
    /// The blend's current whole-window opacity, and the fade under way.
    alpha: u8 = 0,
    fade_from: u8 = 0,
    fade_to: u8 = 0,
    fade_t0_ms: i64 = 0,
    /// The owner's region the frame was last clipped to; see
    /// `DimOverlay.matchOwnerRegion` (T1831).
    region_key: u64 = 0,
    /// Render scratch, grown to the largest pane seen.
    px: []u32 = &.{},

    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        hinstance: w32.HINSTANCE,
    ) !*BellBorder {
        try registerClassOnce(hinstance);

        const self = try alloc.create(BellBorder);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .owner = owner, .hwnd = undefined };

        // The DimOverlay set: composited above OpenGL, click-through, never
        // activates, out of the taskbar and Alt-Tab.
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

    pub fn destroy(self: *BellBorder) void {
        _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
        _ = w32.DestroyWindow(self.hwnd);
        if (self.px.len > 0) self.alloc.free(self.px);
        self.alloc.destroy(self);
    }

    /// Bring the frame in line with `want` (the feature is on and the pane
    /// has an unacknowledged bell). Idempotent, so it rides every layout,
    /// focus, move and config event the dim overlays do: it also keeps the
    /// frame glued to the pane through a resize, a divider drag and a move.
    pub fn update(self: *BellBorder, want: bool, scale: f32) void {
        // A pane on a background tab, behind a zoom or being torn down has
        // nothing to frame: gone at once, no fade (there is nothing to watch).
        if (w32.IsWindowVisible_(self.owner) == 0) {
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
        const width_px = bell_math.borderWidthPx(scale);
        const resized = w != self.placed.right - self.placed.left or
            h != self.placed.bottom - self.placed.top or width_px != self.width_px;
        const moved = !std.meta.eql(rect, self.placed);
        const was_shown = self.shown;

        if (!was_shown or resized) {
            // A new shape: render and place in one UpdateLayeredWindow.
            if (!self.render(rect, width_px)) return;
        } else if (moved) {
            chrome_fanout.noteMove(.dim);
            _ = w32.SetWindowPos(
                self.hwnd,
                null,
                rect.left,
                rect.top,
                0,
                0,
                w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_NOSIZE,
            );
        }
        self.placed = rect;
        self.width_px = width_px;

        if (!was_shown) {
            _ = w32.ShowWindow(self.hwnd, w32.SW_SHOWNOACTIVATE);
            self.shown = true;
            log.info("bell border shown px={d} rect={d},{d},{d}x{d}", .{ width_px, rect.left, rect.top, w, h });
        }
        if (self.fade_to != 255) self.startFade(255);
        w32.healOverlayZOrderAfterMove(self.hwnd, self.owner, was_shown);
    }

    /// Clip the frame to the owner's window region - an elevated pane is a
    /// rounded card (T1831). Same contract as `DimOverlay.matchOwnerRegion`.
    pub fn matchOwnerRegion(self: *BellBorder, key: u64) void {
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

    /// Off screen now, with no fade.
    pub fn hideNow(self: *BellBorder) void {
        _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
        self.alpha = 0;
        self.fade_from = 0;
        self.fade_to = 0;
        if (!self.shown) return;
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.shown = false;
        log.info("bell border hidden", .{});
    }

    fn startFade(self: *BellBorder, to: u8) void {
        if (self.fade_to == to) return;
        self.fade_from = self.alpha;
        self.fade_to = to;
        self.fade_t0_ms = std.time.milliTimestamp();
        _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, FADE_TICK_MS, null);
    }

    fn fadeTick(self: *BellBorder) void {
        const elapsed = std.time.milliTimestamp() - self.fade_t0_ms;
        const a = bell_math.fadeAlpha(self.fade_from, self.fade_to, elapsed);
        self.setAlpha(a);
        if (a != self.fade_to) return;
        _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
        log.info("bell border fade done alpha={d} ms={d}", .{ a, elapsed });
        if (a == 0) self.hideNow();
    }

    /// Change only the blend: no source DC, so the frame is not re-rendered.
    fn setAlpha(self: *BellBorder, a: u8) void {
        if (a == self.alpha) return;
        self.alpha = a;
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = a };
        _ = w32.UpdateLayeredWindow(self.hwnd, null, null, null, null, null, 0, &blend, w32.ULW_ALPHA);
    }

    /// Render the frame at `rect` (screen pixels) and place the popup there,
    /// at the current fade alpha.
    fn render(self: *BellBorder, rect: w32.RECT, width_px: i32) bool {
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
        bell_math.renderFrame(self.px[0..n], w, h, width_px);

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
        return w32.UpdateLayeredWindow(
            self.hwnd,
            screen_dc,
            &dst_pt,
            &dst_size,
            mem_dc,
            &src_pt,
            0,
            &blend,
            w32.ULW_ALPHA,
        ) != 0;
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = borderWndProc,
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

fn borderWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*BellBorder = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
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
