//! The HWND half of the elevated pane style (T1831): the window-owned
//! pixels around and between the pane cards - the "ocean" desk, every card's
//! shadow, its antialiased corners and its rim - painted into the window's DC
//! in one `BitBlt`. The math is `pane_elevation.zig`; this owns the bitmaps.
//!
//! Two cached 32bpp DIB sections, both the size of the content area:
//!
//!   * `desk` - the gradient alone. Rendered at a quarter of the size and
//!     stretched (`HALFTONE`): the gradient has no detail to lose, and it is
//!     only redone when the size or the light/dark flavour changes.
//!   * `comp` - a copy of the desk with the cards painted on, rebuilt on
//!     every paint, because a divider drag moves the cards every frame.
//!
//! The window paints with `WS_CLIPCHILDREN`, so the blit only reaches the
//! pixels no pane child covers: the gutters, the margin, and the rounded
//! corners each child's window region gives back.

const PaneDesk = @This();

const std = @import("std");
const w32 = @import("win32.zig");
const pane_elevation = @import("pane_elevation.zig");

const log = std.log.scoped(.pane_desk);

/// The desk is rendered at 1/DESK_DOWNSCALE of the window and stretched.
const DESK_DOWNSCALE: usize = 4;

const Dib = struct {
    dc: w32.HDC,
    bmp: w32.HANDLE,
    old: ?*anyopaque,
    bits: [*]u32,
    w: i32,
    h: i32,

    fn create(w: i32, h: i32) ?Dib {
        const dc = w32.CreateCompatibleDC(null) orelse return null;
        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{ .bmiHeader = .{
            .biWidth = w,
            .biHeight = -h, // top-down
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = w32.BI_RGB,
        } };
        const bmp = w32.CreateDIBSection(dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = w32.DeleteDC(dc);
            return null;
        };
        const p = bits orelse {
            _ = w32.DeleteObject(bmp);
            _ = w32.DeleteDC(dc);
            return null;
        };
        return .{
            .dc = dc,
            .bmp = bmp,
            .old = w32.SelectObject(dc, bmp),
            .bits = @ptrCast(@alignCast(p)),
            .w = w,
            .h = h,
        };
    }

    fn destroy(self: Dib) void {
        _ = w32.SelectObject(self.dc, self.old);
        _ = w32.DeleteObject(self.bmp);
        _ = w32.DeleteDC(self.dc);
    }

    fn pixels(self: Dib) []u32 {
        return self.bits[0..@intCast(self.w * self.h)];
    }
};

desk: ?Dib = null,
desk_light: bool = false,
comp: ?Dib = null,

pub fn deinit(self: *PaneDesk) void {
    if (self.desk) |d| d.destroy();
    if (self.comp) |c| c.destroy();
    self.* = .{};
}

/// Paint the desk and `cards` (in content-area pixels, i.e. relative to
/// `origin_x`/`origin_y`) into `hdc` over a `w` x `h` content area.
pub fn paint(
    self: *PaneDesk,
    hdc: w32.HDC,
    origin_x: i32,
    origin_y: i32,
    w: i32,
    h: i32,
    cards: []const pane_elevation.Card,
    style: pane_elevation.CardStyle,
) void {
    if (w <= 0 or h <= 0) return;
    const desk = self.ensureDesk(w, h, style.is_light) orelse return;
    const comp = self.ensureComp(w, h) orelse return;
    @memcpy(comp.pixels(), desk.pixels());
    pane_elevation.paintCards(comp.pixels(), @intCast(w), @intCast(h), cards, style);
    _ = w32.BitBlt(hdc, origin_x, origin_y, w, h, comp.dc, 0, 0, w32.SRCCOPY);
}

fn ensureComp(self: *PaneDesk, w: i32, h: i32) ?Dib {
    if (self.comp) |c| {
        if (c.w == w and c.h == h) return c;
        c.destroy();
        self.comp = null;
    }
    self.comp = Dib.create(w, h);
    return self.comp;
}

fn ensureDesk(self: *PaneDesk, w: i32, h: i32, is_light: bool) ?Dib {
    if (self.desk) |d| {
        if (d.w == w and d.h == h and self.desk_light == is_light) return d;
        d.destroy();
        self.desk = null;
    }
    const full = Dib.create(w, h) orelse return null;

    const sw: usize = @max(@as(usize, @intCast(w)) / DESK_DOWNSCALE, 1) + 1;
    const sh: usize = @max(@as(usize, @intCast(h)) / DESK_DOWNSCALE, 1) + 1;
    const small = std.heap.page_allocator.alloc(u32, sw * sh) catch {
        full.destroy();
        return null;
    };
    defer std.heap.page_allocator.free(small);
    pane_elevation.renderDesk(
        small,
        sw,
        sh,
        @floatFromInt(w),
        @floatFromInt(h),
        pane_elevation.Palette.ocean(is_light),
    );
    const bmi = w32.BITMAPINFO{ .bmiHeader = .{
        .biWidth = @intCast(sw),
        .biHeight = -@as(i32, @intCast(sh)),
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = w32.BI_RGB,
    } };
    _ = w32.SetStretchBltMode(full.dc, w32.HALFTONE);
    _ = w32.SetBrushOrgEx(full.dc, 0, 0, null);
    if (w32.StretchDIBits(
        full.dc,
        0,
        0,
        w,
        h,
        0,
        0,
        @intCast(sw),
        @intCast(sh),
        small.ptr,
        &bmi,
        w32.DIB_RGB_COLORS,
        w32.SRCCOPY,
    ) == 0) log.warn("desk stretch failed {d}x{d}", .{ w, h });
    // GDI may leave the alpha byte of a stretched pixel non-zero; the paint
    // is `SRCCOPY` into an opaque window, but a per-pixel-alpha window would
    // read it, so keep the buffer's contract (0x00RRGGBB) exact.
    for (full.pixels()) |*p| p.* &= 0x00FF_FFFF;
    self.desk = full;
    self.desk_light = is_light;
    return full;
}
