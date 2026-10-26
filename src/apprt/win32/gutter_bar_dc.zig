//! A gutter bar laid over what a DC already shows (T2265): for views that
//! paint with GDI and have one draggable edge - the pinned pane sidebar's and
//! the viewer side panel's (Mac `SidePanelResizeHandle.gutterBar`). The
//! window's own gutters compose the bar into the desk's buffer instead
//! (`PaneDesk.paint`, `Window.paintFlatGutterBar`), where the pixels under it
//! are known; here they are read back from the DC, which every caller has
//! just painted, so the glow tints exactly what is on show.
//!
//! The surface is opaque: whatever alpha the DC holds is ignored. A layered
//! window's premultiplied pixels are not this function's to touch.

const std = @import("std");
const w32 = @import("win32.zig");
const gutter_bar = @import("gutter_bar.zig");
const color_math = @import("color_math.zig");

/// Lay the bar whose core is `core` (in `hdc`'s coordinates) over `hdc`, its
/// glow kept inside `clip` (the view's own client rect).
pub fn paintOn(
    hdc: w32.HDC,
    core: gutter_bar.Rect,
    clip: gutter_bar.Rect,
    color: color_math.Rgb,
    scale: f32,
    strength: gutter_bar.Strength,
) void {
    const reach = core.inflate(gutter_bar.glowReach(scale));
    const left = @max(reach.left, clip.left);
    const top = @max(reach.top, clip.top);
    const right = @min(reach.right, clip.right);
    const bottom = @min(reach.bottom, clip.bottom);
    if (right <= left or bottom <= top) return;
    const w = right - left;
    const h = bottom - top;

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

    _ = w32.BitBlt(mem, 0, 0, w, h, hdc, left, top, w32.SRCCOPY);
    _ = w32.GdiFlush();
    const pixels = @as([*]u32, @ptrCast(@alignCast(raw)))[0..@intCast(w * h)];
    // Opaque: the bar's own blend reads the alpha byte as coverage.
    for (pixels) |*p| p.* |= 0xFF00_0000;
    gutter_bar.paint(pixels, @intCast(w), @intCast(h), .{
        .left = core.left - left,
        .top = core.top - top,
        .right = core.right - left,
        .bottom = core.bottom - top,
    }, color, scale, strength);
    _ = w32.BitBlt(hdc, left, top, w, h, mem, 0, 0, w32.SRCCOPY);
}
