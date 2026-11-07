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
const banner_glide = @import("banner_glide.zig");
const comp_overlay = @import("../../renderer/comp_overlay.zig");

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

/// The composition path's copy (T2617): when the banner card is a child
/// visual of the pane, a popup copy would cover it, so the copy is a visual
/// too - at the BACK of the pane's overlays, over only the swap chain, so the
/// card, a dim wash and every other overlay stay above it.
layer: comp_overlay.Layer = .{},
/// The layer's pixels (`banner_glide.buildVisualPixels`), reused.
vis_px: []u32 = &.{},
/// Background rows above and below the frame in `vis_px`.
vis_pad: u32 = 0,
/// Is the copy the visual (rather than the popup) right now?
on_visual: bool = false,

pub fn init(alloc: std.mem.Allocator) BannerFreeze {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *BannerFreeze) void {
    self.layer.deinit();
    if (self.vis_px.len > 0) self.alloc.free(self.vis_px);
    self.vis_px = &.{};
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
    if (self.on_visual) return self.layer.attached;
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
/// behind `card` (the banner popup) and under `dim` (the pane's unfocused
/// dim, when shown), all owned by `owner` (the terminal).
pub fn show(
    self: *BannerFreeze,
    hinstance: w32.HINSTANCE,
    owner: w32.HWND,
    card: w32.HWND,
    dim: ?w32.HWND,
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
    const seat = seatAfter(owner, card, dim);
    _ = w32.SetWindowPos(hwnd, seat, at.left, at.top, @max(at.width, 1), @max(at.height, 1), w32.SWP_NOACTIVATE);
    _ = w32.InvalidateRect(hwnd, null, 0);
    _ = w32.SetWindowPos(hwnd, seat, 0, 0, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_SHOWWINDOW);
    _ = w32.UpdateWindow(hwnd);
    return true;
}

/// Put the captured frame (already in `buffer`) on the pane's composition
/// tree (T2617), at the back of its overlays. `img_top` is the frame's row in
/// the pane WINDOW (the band above the grid), `band` where the tree's root
/// sits in that window now, `delta` the glide's whole travel. No mask is
/// needed: rows above the card's edge are under the card's own opaque visual.
pub fn showVisual(self: *BannerFreeze, s: *comp_overlay.Slot, w: u32, h: u32, img_top: i32, delta: i32, band: u32, bg: u32) bool {
    if (self.placeVisual(s, w, h, img_top, delta, band, bg)) return true;
    // Nothing half-built is kept: the caller falls back to the reflow.
    self.on_visual = false;
    self.layer.deinit();
    return false;
}

fn placeVisual(self: *BannerFreeze, s: *comp_overlay.Slot, w: u32, h: u32, img_top: i32, delta: i32, band: u32, bg: u32) bool {
    if (!self.layer.sync(s)) return false;
    const pad = banner_glide.visualPad(delta);
    const rows = h + 2 * pad;
    const len: usize = @as(usize, w) * rows;
    if (self.vis_px.len != len) {
        if (self.vis_px.len > 0) self.alloc.free(self.vis_px);
        self.vis_px = self.alloc.alloc(u32, len) catch {
            self.vis_px = &.{};
            return false;
        };
    }
    if (self.pixels.len != @as(usize, w) * h * 4) return false;
    banner_glide.buildVisualPixels(self.vis_px, self.pixels, w, h, pad, bg);
    self.img_w = @intCast(w);
    self.img_h = @intCast(h);
    self.img_top = img_top;
    self.offset = 0;
    self.vis_pad = pad;
    // Placed before it is attached, so its first composited frame is in the
    // right place.
    if (!self.layer.setOffset(0, banner_glide.visualTop(img_top, 0, pad, band))) return false;
    if (!self.layer.setPixels(self.vis_px, w, rows)) return false;
    self.layer.setVisible(false);
    self.layer.attach(.back);
    if (!self.layer.attached) return false;
    self.on_visual = true;
    return true;
}

/// Move the visual copy along its glide (T2617). `band` is read every step:
/// the root moves to the new band once the renderer presents, and the copy
/// has to hold its place in the window across that.
pub fn updateVisual(self: *BannerFreeze, offset: i32, band: u32) void {
    if (!self.on_visual) return;
    self.offset = offset;
    _ = self.layer.setOffset(0, banner_glide.visualTop(self.img_top, offset, self.vis_pad, band));
}

/// Move the copy along its glide and the mask with the card's edge.
pub fn update(self: *BannerFreeze, owner: w32.HWND, card: w32.HWND, dim: ?w32.HWND, offset: i32, edge: i32) void {
    const hwnd = self.hwnd orelse return;
    if (offset == self.offset and edge == self.edge) return;
    self.offset = offset;
    self.edge = edge;
    // Re-seat behind the card every step: anything that lifted another popup
    // between them must not leave the copy over the card, or over the dim.
    _ = w32.SetWindowPos(hwnd, seatAfter(owner, card, dim), 0, 0, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
    _ = w32.InvalidateRect(hwnd, null, 0);
    _ = w32.UpdateWindow(hwnd);
}

/// Negative control for `pane-banner.ps1`'s T2261 section. Flipping it seats
/// the copy under the card alone, as before T2261, so it can land above an
/// unfocused pane's dim and the section's "dim over the copy" goes red.
pub const T2261_NEUTERED = false;

/// The window the copy goes directly beneath (T2261, `banner_glide.copySeat`):
/// the card, or a shown dim when the dim is the lower of the two. The order of
/// two popups with one owner is whatever last moved them, so it is read, not
/// assumed.
fn seatAfter(owner: w32.HWND, card: w32.HWND, dim: ?w32.HWND) w32.HWND {
    if (T2261_NEUTERED) return card;
    const d = dim orelse return card;
    const shown = w32.IsWindowVisible_(d) != 0;
    return switch (banner_glide.copySeat(shown, shown and isBelow(owner, card, d))) {
        .card => card,
        .dim => d,
    };
}

/// Is `lower` anywhere beneath `upper`? A pathological chain answers "not
/// below", which seats under the card exactly as before.
fn isBelow(owner: w32.HWND, upper: w32.HWND, lower: w32.HWND) bool {
    return w32.isBelowInBand(owner, upper, lower);
}

/// Debug oracle for `pane-banner.ps1`'s T2261 section: is a shown `dim`
/// stacked over the copy right now?
pub fn dimOver(self: *const BannerFreeze, owner: w32.HWND, dim: ?w32.HWND) enum { none, over, under } {
    const d = dim orelse return .none;
    const hwnd = self.hwnd orelse return .none;
    if (w32.IsWindowVisible_(d) == 0) return .none;
    return if (isBelow(owner, d, hwnd)) .over else .under;
}

test "BannerFreeze: the T2261 negative control ships clear" {
    try std.testing.expect(!T2261_NEUTERED);
}

pub fn hide(self: *BannerFreeze) void {
    if (self.on_visual) {
        self.on_visual = false;
        // Let go of the whole visual, not just detach it: its surface is a
        // pane-sized texture, and a toggle is rare. `deinit` (generation 0)
        // rather than `drop`, so the next `sync` borrows the tree afresh.
        self.layer.deinit();
    }
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
