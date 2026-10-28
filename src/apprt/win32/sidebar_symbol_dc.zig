//! The GDI half of `sidebar_symbol` (T2357): one Mac sidebar symbol laid
//! over what a DC already shows, the way `gutter_bar_dc` lays its bar - the
//! pixels under the icon are read back, the symbol's coverage tints them, and
//! the result goes back on the same pixels. Antialiasing therefore blends
//! with whatever the sidebar painted there (a selection fill, a hover pill,
//! the sheen) instead of an assumed background.
//!
//! The alpha byte the DC holds is kept as it was: a layered surface's
//! coverage is not this function's to change.

const std = @import("std");
const w32 = @import("win32.zig");
const sidebar_symbol = @import("sidebar_symbol.zig");

pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

/// The largest symbol drawn: a 15 DIP header icon at 400%.
const max_px = 64;

/// Draw `sym` at `dip` DIP, centred in `target`, in `color` (a COLORREF,
/// 0x00BBGGRR).
pub fn paint(
    hdc: w32.HDC,
    target: Rect,
    sym: sidebar_symbol.Symbol,
    dip: f32,
    scale: f32,
    color: u32,
) void {
    const n: i32 = @intCast(@min(sidebar_symbol.pixelSize(dip, scale), max_px));
    const left = target.left + @divTrunc((target.right - target.left) - n, 2);
    const top = target.top + @divTrunc((target.bottom - target.top) - n, 2);

    var mask: [max_px * max_px]u8 = undefined;
    const un: usize = @intCast(n);
    sidebar_symbol.render(sym, un, mask[0 .. un * un]);

    var bmi = std.mem.zeroes(w32.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = n;
    bmi.bmiHeader.biHeight = -n; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    const mem = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(mem);
    var bits: ?*anyopaque = null;
    const bmp = w32.CreateDIBSection(mem, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    defer _ = w32.DeleteObject(bmp);
    const raw = bits orelse return;
    const old = w32.SelectObject(mem, bmp);
    defer _ = w32.SelectObject(mem, old);

    _ = w32.BitBlt(mem, 0, 0, n, n, hdc, left, top, w32.SRCCOPY);
    _ = w32.GdiFlush();
    const pixels = @as([*]u32, @ptrCast(@alignCast(raw)))[0 .. un * un];
    sidebar_symbol.tint(pixels, mask[0 .. un * un], color);
    _ = w32.BitBlt(hdc, left, top, n, n, mem, 0, 0, w32.SRCCOPY);
}
