//! The frozen copy of a terminal that stands in for it while its banner
//! collapses or expands (T2252, Mac a81db68f9 `FrozenTerminalView`).
//!
//! A click-through popup over the pane, seated directly behind the banner
//! card, holding the terminal's last frame from before the resize. The
//! banner moves it along `banner_glide.offset` with the card and takes it
//! down once the live terminal has redrawn at its new size, so the resize is
//! never seen happening. Rows above the card's moving edge are under the
//! card, so the copy is masked there the way Mac masks it at `bannerReveal`.
//!
//! Owned by `BannerOverlay`; the window is created on first use and kept,
//! hidden, for the next toggle.

const std = @import("std");
const w32 = @import("win32.zig");

const BannerFreeze = @This();

const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyBannerFreeze");
var class_registered: bool = false;

alloc: std.mem.Allocator,
hwnd: ?w32.HWND = null,
/// The frame, BGRA bottom-up, `img_w` x `img_h` (the renderer's capture
/// layout, `Surface.captureContent`).
pixels: []u8 = &.{},
img_w: i32 = 0,
img_h: i32 = 0,
/// Where the frame sits in this window at the start of the glide: the old
/// band height, since the window's top is the pane's top.
img_top: i32 = 0,
/// Current glide offset, px down from `img_top`.
offset: i32 = 0,
/// The card's band edge right now, in this window's coordinates: nothing of
/// the frame shows above it.
edge: i32 = 0,
bg: u32 = 0,
bg_brush: ?w32.HBRUSH = null,

pub fn init(alloc: std.mem.Allocator) BannerFreeze {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *BannerFreeze) void {
    if (self.hwnd) |h| {
        _ = w32.SetWindowLongPtrW(h, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(h);
        self.hwnd = null;
    }
    if (self.pixels.len > 0) self.alloc.free(self.pixels);
    self.pixels = &.{};
    if (self.bg_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
    self.bg_brush = null;
}

/// Is the copy on screen?
pub fn active(self: *const BannerFreeze) bool {
    const h = self.hwnd orelse return false;
    return w32.IsWindowVisible_(h) != 0;
}

/// The pixel buffer a capture of `w` x `h` goes into, reused across toggles.
pub fn buffer(self: *BannerFreeze, w: u32, h: u32) ?[]u8 {
    const len: usize = @as(usize, w) * @as(usize, h) * 4;
    if (self.pixels.len != len) {
        if (self.pixels.len > 0) self.alloc.free(self.pixels);
        self.pixels = self.alloc.alloc(u8, len) catch {
            self.pixels = &.{};
            return null;
        };
    }
    return self.pixels;
}

pub const Placement = struct {
    /// The pane's slot on screen: band top to terminal bottom.
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    /// Old band height: where the frame's top row sits in the slot.
    img_top: i32,
    /// The card's band edge at the start, slot coordinates.
    edge: i32,
};

/// Put the captured frame (already in `buffer`) on screen over the pane, just
/// behind `card` (the banner popup), both owned by `owner` (the terminal).
pub fn show(
    self: *BannerFreeze,
    hinstance: w32.HINSTANCE,
    owner: w32.HWND,
    card: w32.HWND,
    w: u32,
    h: u32,
    at: Placement,
    bg: u32,
) bool {
    const hwnd = self.window(hinstance, owner) orelse return false;
    self.img_w = @intCast(w);
    self.img_h = @intCast(h);
    self.img_top = at.img_top;
    self.edge = at.edge;
    self.offset = 0;
    if (self.bg_brush == null or self.bg != bg) {
        if (self.bg_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
        self.bg_brush = w32.CreateSolidBrush(bg);
        self.bg = bg;
    }
    // Paint before showing, so the first composited frame is the copy and
    // never this window's empty client.
    _ = w32.SetWindowPos(hwnd, card, at.left, at.top, @max(at.width, 1), @max(at.height, 1), w32.SWP_NOACTIVATE);
    _ = w32.InvalidateRect(hwnd, null, 0);
    _ = w32.SetWindowPos(hwnd, card, 0, 0, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_SHOWWINDOW);
    _ = w32.UpdateWindow(hwnd);
    return true;
}

/// Move the copy along its glide and the mask with the card's edge.
pub fn update(self: *BannerFreeze, card: w32.HWND, offset: i32, edge: i32) void {
    const hwnd = self.hwnd orelse return;
    if (offset == self.offset and edge == self.edge) return;
    self.offset = offset;
    self.edge = edge;
    // Re-seat behind the card every step: anything that lifted another popup
    // between them must not leave the copy over the card.
    _ = w32.SetWindowPos(hwnd, card, 0, 0, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
    _ = w32.InvalidateRect(hwnd, null, 0);
    _ = w32.UpdateWindow(hwnd);
}

pub fn hide(self: *BannerFreeze) void {
    const hwnd = self.hwnd orelse return;
    _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
}

fn window(self: *BannerFreeze, hinstance: w32.HINSTANCE, owner: w32.HWND) ?w32.HWND {
    if (self.hwnd) |h| return h;
    registerClassOnce(hinstance) catch return null;
    // Layered + transparent: composited above the GL surface, and every click
    // in the instant it is up goes to the terminal under it.
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
        1,
        owner,
        null,
        hinstance,
        null,
    ) orelse return null;
    _ = w32.SetLayeredWindowAttributes(hwnd, 0, 255, w32.LWA_ALPHA);
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.hwnd = hwnd;
    return hwnd;
}

fn paint(self: *BannerFreeze, hdc: w32.HDC) void {
    const hwnd = self.hwnd orelse return;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client) == 0) return;
    const y = self.img_top + self.offset;
    const visible = self.pixels.len == @as(usize, @intCast(self.img_w)) * @as(usize, @intCast(self.img_h)) * 4;
    // The frame first, clipped below the card's edge, then the background
    // everywhere else: never a fill under the frame, so no frame of this
    // window ever shows background where text was.
    if (visible) {
        const mask = @max(self.edge, 0);
        const saved = w32.SaveDC(hdc);
        _ = w32.IntersectClipRect(hdc, 0, mask, client.right, client.bottom);
        const bmi: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = self.img_w, .biHeight = self.img_h } };
        _ = w32.StretchDIBits(hdc, 0, y, self.img_w, self.img_h, 0, 0, self.img_w, self.img_h, self.pixels.ptr, &bmi, w32.DIB_RGB_COLORS, w32.SRCCOPY);
        _ = w32.RestoreDC(hdc, saved);
        _ = w32.ExcludeClipRect(hdc, 0, @max(y, mask), self.img_w, y + self.img_h);
    }
    if (self.bg_brush) |b| _ = w32.FillRect(hdc, &client, b);
}

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = freezeWndProc,
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

fn freezeWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self: *BannerFreeze = if (ud == 0)
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam)
    else
        @ptrFromInt(@as(usize, @bitCast(ud)));
    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_NCHITTEST => return w32.HTTRANSPARENT,
        w32.WM_ERASEBKGND => return 1,
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            self.paint(hdc);
            return 0;
        },
        // A probe's synchronous capture (T940): the same paint into its DC,
        // so the copy can be photographed rather than torn from DWM.
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            self.paint(@ptrFromInt(wparam));
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
