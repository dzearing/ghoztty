//! The ghost card under the pointer during a pane drag (T2703, Mac
//! 30d13ea14 `PaneDragGhost`): one layered popup per window, created on the
//! first drag that wants one and destroyed with the window. What the card
//! looks like is `pane_drag_ghost.zig`, pure and unit-tested; this file is
//! the window, the GDI text, and placement.
//!
//! The overlay shape every popup of ours takes over child-window content:
//! `WS_EX_LAYERED` so DWM composites it over OpenGL and WebView2 alike,
//! `WS_EX_TRANSPARENT` so it never takes the pointer (the drag's captured
//! coordinate stream must not see it), `WS_EX_NOACTIVATE` so the drag keeps
//! focus. It sits in the always-on-top band for as long as it is shown: the
//! card follows the pointer over other windows and the desktop, where a popup
//! seated by ownership would be drawn behind whatever it crosses.
//!
//! Perf (Mac: "the drag publishes nothing per move"): the card's pixels are
//! committed once per drag - again only if the pane's picture arrives after
//! the first move - and every move after that is a `SetWindowPos` of a
//! window whose bits DWM already holds. Nothing is painted per move, and no
//! pane is invalidated.

const std = @import("std");
const w32 = @import("win32.zig");
const ghost = @import("pane_drag_ghost.zig");

const log = std.log.scoped(.win32_pane_drag_ghost);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyPaneDragGhost");

const ui_face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");

const PaneDragGhost = @This();

/// What to draw: the pane as it is now.
pub const Card = struct {
    /// The pane's size on screen, device px - the card takes its shape.
    pane_w: i32,
    pane_h: i32,
    scale: f32,
    background: ghost.Rgb,
    /// UTF-8; empty draws an empty strip.
    title: []const u8,
    /// The pane's picture: BOTTOM-UP `0x??RRGGBB`, `w` x `h`. Null draws the
    /// card without content - a pane that has not been captured yet still
    /// says what is being carried.
    content: ?Content = null,
};

pub const Content = struct { pixels: []const u32, w: i32, h: i32 };

alloc: std.mem.Allocator,
owner: w32.HWND,
hwnd: w32.HWND,

shown: bool = false,
/// The image's size and the pointer-relative placement, as last committed.
img: ghost.Size = .{ .w = 0, .h = 0 },
scale: f32 = 1.0,
/// Where the image's top-left sits now (screen px).
at: ghost.Point = .{ .x = 0, .y = 0 },
/// Whether the committed card carries the pane's picture.
has_content: bool = false,

/// A copy of the committed pixels (premultiplied, top-down), which WM_PRINT
/// paints from: an `UpdateLayeredWindow` window has no redirection surface
/// for a capture to read, and the acceptance script photographs the card
/// with `PrintWindow` on the background desktop, where the screen cannot be
/// read at all.
px: []u32 = &.{},

pub fn create(alloc: std.mem.Allocator, owner: w32.HWND, hinstance: w32.HINSTANCE) !*PaneDragGhost {
    try registerClassOnce(hinstance);
    const self = try alloc.create(PaneDragGhost);
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
        1, // placeholder - `show` sizes it to the card
        owner,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.hwnd = hwnd;
    return self;
}

pub fn destroy(self: *PaneDragGhost) void {
    _ = w32.DestroyWindow(self.hwnd);
    if (self.px.len > 0) self.alloc.free(self.px);
    self.alloc.destroy(self);
}

/// Draw `card` and put it under `pointer` (screen px). Called when the drag
/// goes live, and once more if the pane's picture lands afterwards.
pub fn show(self: *PaneDragGhost, card: Card, pointer: ghost.Point) void {
    const size = ghost.cardSize(card.pane_w, card.pane_h, card.scale);
    const img = ghost.imageSize(size, card.scale);
    const lay = ghost.layout(size, card.scale);
    if (img.w <= 0 or img.h <= 0) return;

    const screen = w32.GetDC(null) orelse return;
    defer _ = w32.ReleaseDC(null, screen);
    const mem_dc = w32.CreateCompatibleDC(screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    var bits: ?*anyopaque = null;
    const bmi = w32.BITMAPINFO{ .bmiHeader = .{ .biWidth = img.w, .biHeight = -img.h } };
    const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    defer _ = w32.DeleteObject(bitmap);
    const old = w32.SelectObject(mem_dc, bitmap);
    defer _ = w32.SelectObject(mem_dc, old);
    const raw = bits orelse return;
    const w: usize = @intCast(img.w);
    const h: usize = @intCast(img.h);
    const pixels = @as([*]u32, @ptrCast(@alignCast(raw)))[0 .. w * h];

    ghost.fillCard(pixels, w, h, lay, card.background);
    if (card.content) |c| ghost.drawContent(pixels, w, h, lay.body, c.pixels, c.w, c.h, .{ .w = card.pane_w, .h = card.pane_h });
    _ = w32.GdiFlush();
    drawTitle(mem_dc, lay, card);
    _ = w32.GdiFlush();
    ghost.finalize(pixels, w, h, lay, card.background, card.scale);
    self.keep(pixels);

    self.img = img;
    self.scale = card.scale;
    self.has_content = card.content != null;
    self.at = ghost.imageOrigin(pointer, img, card.scale);

    const dst_pt = w32.POINT{ .x = self.at.x, .y = self.at.y };
    const dst_size = w32.SIZE{ .cx = img.w, .cy = img.h };
    const src_pt = w32.POINT{ .x = 0, .y = 0 };
    const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = 255, .AlphaFormat = w32.AC_SRC_ALPHA };
    if (w32.UpdateLayeredWindow(self.hwnd, null, &dst_pt, &dst_size, mem_dc, &src_pt, 0, &blend, w32.ULW_ALPHA) == 0) {
        log.warn("pane drag ghost UpdateLayeredWindow failed err={d}", .{w32.GetLastError()});
        return;
    }
    if (!self.shown) {
        _ = w32.setTopmost(self.hwnd, true);
        _ = w32.SetWindowPos(self.hwnd, null, 0, 0, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_SHOWWINDOW);
        self.shown = true;
    }
    // The acceptance oracle reads these (pane-drag-ghost.ps1).
    log.info("pane drag ghost shown card={d}x{d} image={d}x{d} content={} pane={d}x{d}", .{
        size.w, size.h, img.w, img.h, self.has_content, card.pane_w, card.pane_h,
    });
}

/// Follow the pointer. A move only - the pixels DWM holds are not touched.
pub fn moveTo(self: *PaneDragGhost, pointer: ghost.Point) void {
    if (!self.shown) return;
    const at = ghost.imageOrigin(pointer, self.img, self.scale);
    if (at.x == self.at.x and at.y == self.at.y) return;
    self.at = at;
    _ = w32.SetWindowPos(self.hwnd, null, at.x, at.y, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_NOSIZE);
}

pub fn hide(self: *PaneDragGhost) void {
    if (!self.shown) return;
    self.shown = false;
    self.has_content = false;
    _ = w32.setTopmost(self.hwnd, false);
    _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
    log.info("pane drag ghost hidden", .{});
}

/// The title, in the strip, in GDI: semibold UI text truncated with an
/// ellipsis. Greyscale anti-aliasing, never ClearType - the card is composited
/// with per-pixel alpha, and ClearType's colour fringes would show as such.
fn drawTitle(dc: w32.HDC, lay: ghost.Layout, card: Card) void {
    if (card.title.len == 0) return;
    var wide: [256]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, card.title[0..@min(card.title.len, 255)]) catch return;
    if (n == 0) return;
    const font_px = ghost.px(ghost.title_font_dip, card.scale);
    const font = w32.CreateFontW(-font_px, 0, 0, 0, 600, 0, 0, 0, w32.DEFAULT_CHARSET, 0, 0, w32.ANTIALIASED_QUALITY, 0, ui_face) orelse return;
    defer _ = w32.DeleteObject(font);
    const old_font = w32.SelectObject(dc, font);
    defer _ = w32.SelectObject(dc, old_font);
    const ink = ghost.textColor(card.background);
    _ = w32.SetBkMode(dc, w32.TRANSPARENT);
    _ = w32.SetTextColor(dc, @as(u32, ink.r) | (@as(u32, ink.g) << 8) | (@as(u32, ink.b) << 16));
    const inset = ghost.px(ghost.title_inset_dip, card.scale);
    var r = w32.RECT{
        .left = lay.title.left + inset,
        .top = lay.title.top,
        .right = lay.title.right - inset,
        .bottom = lay.title.bottom,
    };
    _ = w32.DrawTextW(dc, &wide, @intCast(n), &r, w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX);
}

fn keep(self: *PaneDragGhost, pixels: []const u32) void {
    if (self.px.len != pixels.len) {
        if (self.px.len > 0) self.alloc.free(self.px);
        self.px = self.alloc.alloc(u32, pixels.len) catch {
            self.px = &.{};
            return;
        };
    }
    @memcpy(self.px, pixels);
}

fn printInto(self: *const PaneDragGhost, hdc: w32.HDC) void {
    if (self.img.w <= 0 or self.img.h <= 0) return;
    if (self.px.len != @as(usize, @intCast(self.img.w * self.img.h))) return;
    const bmi = w32.BITMAPINFO{ .bmiHeader = .{
        .biWidth = self.img.w,
        .biHeight = -self.img.h,
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = w32.BI_RGB,
    } };
    _ = w32.StretchDIBits(hdc, 0, 0, self.img.w, self.img.h, 0, 0, self.img.w, self.img.h, self.px.ptr, &bmi, w32.DIB_RGB_COLORS, w32.SRCCOPY);
}

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*PaneDragGhost = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_NCHITTEST => return w32.HTTRANSPARENT,
        w32.WM_ERASEBKGND => return 1,
        // A synchronous PrintWindow repaints through WM_PAINT (T1287), so the
        // committed card answers that as well as WM_PRINT.
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            if (self_opt) |self| self.printInto(hdc);
            return 0;
        },
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
