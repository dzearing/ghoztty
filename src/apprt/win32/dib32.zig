//! A top-down 32bpp DIB section selected into its own memory DC: pixels as
//! `0x00RRGGBB` words a painter can write directly, then `BitBlt` from `dc`.
//! Shared by the surfaces that lay a glass sheet down themselves - the pane
//! banner (T1884) and the viewer host (T1885).
const Dib32 = @This();

const std = @import("std");
const w32 = @import("win32.zig");

dc: w32.HDC,
bmp: *anyopaque,
pixels: []u32,

pub fn create(hdc: w32.HDC, w: i32, h: i32) ?Dib32 {
    var bmi = std.mem.zeroes(w32.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return null;
    var bits: ?*anyopaque = null;
    const bmp = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
        _ = w32.DeleteDC(mem_dc);
        return null;
    };
    const raw = bits orelse {
        _ = w32.DeleteObject(bmp);
        _ = w32.DeleteDC(mem_dc);
        return null;
    };
    _ = w32.SelectObject(mem_dc, bmp);
    const n: usize = @intCast(w * h);
    return .{ .dc = mem_dc, .bmp = bmp, .pixels = @as([*]u32, @ptrCast(@alignCast(raw)))[0..n] };
}

pub fn destroy(self: Dib32) void {
    _ = w32.DeleteDC(self.dc);
    _ = w32.DeleteObject(self.bmp);
}
