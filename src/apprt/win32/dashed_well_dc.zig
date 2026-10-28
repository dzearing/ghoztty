//! The GDI half of `dashed_well` (T2358): the empty stash tray's well laid
//! over what a DC already shows, the way `sidebar_symbol_dc` lays a symbol -
//! the pixels under the well are read back, the fill and then the dashed
//! stroke tint them by their coverage, and the result goes back on the same
//! pixels. The alpha byte the DC holds is kept as it was.

const std = @import("std");
const w32 = @import("win32.zig");
const dashed_well = @import("dashed_well.zig");
const sidebar_symbol = @import("sidebar_symbol.zig");

pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

/// Draw `well` (sized to `target`) at `target`: `fill` (a COLORREF) at
/// `fill_alpha` over the shape, then the dashed outline in `stroke`.
pub fn paint(
    alloc: std.mem.Allocator,
    hdc: w32.HDC,
    target: Rect,
    well: dashed_well.Well,
    stroke: u32,
    fill: u32,
    fill_alpha: f32,
) void {
    const w = target.right - target.left;
    const h = target.bottom - target.top;
    if (w <= 0 or h <= 0) return;
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    const n = uw * uh;

    var sized = well;
    sized.w = @floatFromInt(w);
    sized.h = @floatFromInt(h);
    const masks = alloc.alloc(u8, 2 * n) catch return;
    defer alloc.free(masks);
    const stroke_mask = masks[0..n];
    const fill_mask = masks[n..];
    dashed_well.render(sized, stroke_mask, fill_mask);

    var bmi = std.mem.zeroes(w32.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // top-down
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

    _ = w32.BitBlt(mem, 0, 0, w, h, hdc, target.left, target.top, w32.SRCCOPY);
    _ = w32.GdiFlush();
    const pixels = @as([*]u32, @ptrCast(@alignCast(raw)))[0..n];
    if (fill_alpha > 0) {
        const a = std.math.clamp(fill_alpha, 0, 1);
        for (fill_mask) |*c| c.* = @intFromFloat(@round(@as(f32, @floatFromInt(c.*)) * a));
        sidebar_symbol.tint(pixels, fill_mask, fill);
    }
    sidebar_symbol.tint(pixels, stroke_mask, stroke);
    _ = w32.BitBlt(hdc, target.left, target.top, w, h, mem, 0, 0, w32.SRCCOPY);
}
