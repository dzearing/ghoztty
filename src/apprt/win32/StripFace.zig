//! The strip's face over a card gliding into or out of its strip (T2288,
//! Mac a81db68f9): the strip's band and name, laid over what of the card is
//! drawn at the card's `collapse` constant alpha, so the content fades out
//! as the title fades in. Pure logic (how far in, the alpha, the pixels) is
//! `strip_face.zig`.
//!
//! The `DimOverlay` shape: a WS_EX_LAYERED popup owned by the pane's child
//! HWND, so DWM composites it above OpenGL and WebView2 content alike, and
//! WS_EX_TRANSPARENT so it never takes the pointer. Uniform alpha, committed
//! with UpdateLayeredWindow (T2485 D7) from the frame the window drew into
//! its DIB (`begin`/`commit`). A copy of that frame answers WM_PRINT, so a
//! pixel probe can still photograph it, where DefWindowProc would read an
//! UpdateLayeredWindow face back black.

const std = @import("std");
const w32 = @import("win32.zig");
const chrome_fanout = @import("chrome_fanout.zig");

const log = std.log.scoped(.win32_strip_face);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyStripFace");

pub const StripFace = struct {
    alloc: std.mem.Allocator,
    /// The pane child HWND this face covers (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,

    shown: bool = false,
    /// The constant alpha last committed.
    alpha: u8 = 0,

    /// The frame being painted (`begin` to `commit`).
    mem_dc: ?w32.HDC = null,
    bitmap: ?*anyopaque = null,
    old_bmp: ?*anyopaque = null,
    bits: ?[*]u32 = null,
    w: i32 = 0,
    h: i32 = 0,

    /// A copy of the frame on screen, which WM_PRINT paints from.
    px: []u32 = &.{},
    px_w: i32 = 0,
    px_h: i32 = 0,

    pub fn create(alloc: std.mem.Allocator, owner: w32.HWND, hinstance: w32.HINSTANCE) !*StripFace {
        try registerClassOnce(hinstance);
        const self = try alloc.create(StripFace);
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
            1, // placeholder - commit() places it
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *StripFace) void {
        self.releaseFrame();
        _ = w32.DestroyWindow(self.hwnd);
        if (self.px.len > 0) self.alloc.free(self.px);
        self.alloc.destroy(self);
    }

    /// A `w` x `h` frame to paint the face into: a memory DC over a top-down
    /// 32-bit DIB, and its pixels. Null when GDI said no; the face is then
    /// left as it was.
    pub fn begin(self: *StripFace, w: i32, h: i32) ?struct { dc: w32.HDC, pixels: []u32 } {
        self.releaseFrame();
        if (w <= 0 or h <= 0) return null;
        const screen_dc = w32.GetDC(null) orelse return null;
        defer _ = w32.ReleaseDC(null, screen_dc);
        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return null;
        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{ .bmiHeader = .{ .biWidth = w, .biHeight = -h } };
        const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = w32.DeleteDC(mem_dc);
            return null;
        };
        const old = w32.SelectObject(mem_dc, bitmap) orelse {
            _ = w32.DeleteObject(bitmap);
            _ = w32.DeleteDC(mem_dc);
            return null;
        };
        self.mem_dc = mem_dc;
        self.bitmap = bitmap;
        self.old_bmp = old;
        self.bits = @ptrCast(@alignCast(bits.?));
        self.w = w;
        self.h = h;
        return .{ .dc = mem_dc, .pixels = self.bits.?[0..@intCast(w * h)] };
    }

    /// Put the frame `begin` handed out on screen at `left`/`top` (screen
    /// pixels), blended at `alpha`, cut to `region` (in the face's own
    /// coordinates; null for none - the system owns it once set).
    pub fn commit(self: *StripFace, left: i32, top: i32, alpha: u8, region: ?*anyopaque) void {
        defer self.releaseFrame();
        if (self.mem_dc == null) {
            if (region) |r| _ = w32.DeleteObject(r);
            return;
        }
        _ = w32.GdiFlush();
        self.keep();
        chrome_fanout.noteMove(.dim);
        if (w32.SetWindowRgn(self.hwnd, region, 0) == 0) if (region) |r| {
            _ = w32.DeleteObject(r);
        };
        // Pixels, place and alpha in one UpdateLayeredWindow, which DWM takes
        // whole at its next composition (T2485 D7). Painting the redirection
        // surface through WM_PAINT after a SetLayeredWindowAttributes reached
        // the screen 1-3 frames after the pane under it was hidden, so a
        // fold's first frames showed neither. The source alpha is not read
        // (AlphaFormat 0): the face is uniform, as the dim wash is.
        const dst_pt = w32.POINT{ .x = left, .y = top };
        const dst_size = w32.SIZE{ .cx = self.w, .cy = self.h };
        const src_pt = w32.POINT{ .x = 0, .y = 0 };
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = alpha, .AlphaFormat = 0 };
        if (w32.UpdateLayeredWindow(self.hwnd, null, &dst_pt, &dst_size, self.mem_dc, &src_pt, 0, &blend, w32.ULW_ALPHA) == 0)
            log.warn("strip face UpdateLayeredWindow failed err={d}", .{w32.GetLastError()});
        self.alpha = alpha;
        if (!self.shown)
            _ = w32.SetWindowPos(self.hwnd, null, 0, 0, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_SHOWWINDOW);
        const was_shown = self.shown;
        if (!was_shown) {
            self.shown = true;
            log.info("strip face shown alpha={d} rect={d},{d},{d}x{d}", .{ alpha, left, top, self.px_w, self.px_h });
        }
        w32.healOverlayZOrderAfterMove(self.hwnd, self.owner, was_shown);
    }
    /// The uniform name every pane popup answers (T2012).
    pub fn hide(self: *StripFace) void {
        self.releaseFrame();
        if (!self.shown) return;
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.shown = false;
        log.info("strip face hidden", .{});
    }

    /// Copy the committed frame for WM_PRINTCLIENT.
    fn keep(self: *StripFace) void {
        const bits = self.bits orelse return;
        const n: usize = @intCast(self.w * self.h);
        if (self.px.len < n) {
            if (self.px.len > 0) self.alloc.free(self.px);
            self.px = self.alloc.alloc(u32, n) catch {
                self.px = &.{};
                self.px_w = 0;
                self.px_h = 0;
                return;
            };
        }
        @memcpy(self.px[0..n], bits[0..n]);
        self.px_w = self.w;
        self.px_h = self.h;
    }

    /// The frame on screen, into a DC (WM_PAINT, WM_PRINT).
    fn printInto(self: *const StripFace, hdc: w32.HDC) void {
        if (self.px_w <= 0 or self.px_h <= 0) return;
        const bmi = w32.BITMAPINFO{ .bmiHeader = .{
            .biWidth = self.px_w,
            .biHeight = -self.px_h,
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = w32.BI_RGB,
        } };
        _ = w32.StretchDIBits(hdc, 0, 0, self.px_w, self.px_h, 0, 0, self.px_w, self.px_h, self.px.ptr, &bmi, w32.DIB_RGB_COLORS, w32.SRCCOPY);
    }

    fn releaseFrame(self: *StripFace) void {
        const mem_dc = self.mem_dc orelse return;
        if (self.old_bmp) |o| _ = w32.SelectObject(mem_dc, o);
        if (self.bitmap) |b| _ = w32.DeleteObject(b);
        _ = w32.DeleteDC(mem_dc);
        self.mem_dc = null;
        self.bitmap = null;
        self.old_bmp = null;
        self.bits = null;
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = faceWndProc,
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

fn faceWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*StripFace = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_ERASEBKGND => return 1, // every pixel is painted below
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            if (self_opt) |self| self.printInto(hdc);
            return 0;
        },
        // The face into a caller's DC, so a pixel probe can photograph it
        // synchronously (T835/T940). PrintWindow sends WM_PRINT, whose
        // default would ask for the erase and the client in turn; answered
        // here whole, since this window has no frame and no erase of its own.
        w32.WM_PRINT => {
            if (wparam == 0) return 0;
            if (self_opt) |self| self.printInto(@ptrFromInt(wparam));
            return 0;
        },
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            if (self_opt) |self| self.printInto(@ptrFromInt(wparam));
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
