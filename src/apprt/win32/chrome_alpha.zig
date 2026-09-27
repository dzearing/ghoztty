//! Alpha-correct chrome on a per-pixel-alpha window (T1787).
//!
//! A translucent window is composed by DWM from the ALPHA of its pixels (see
//! `Window.setTranslucent`), which is what keeps terminal text opaque while the
//! background shows through - the renderer already writes premultiplied alpha.
//! GDI does not: every GDI write (FillRect, text, regions, a DDB blit) leaves
//! the alpha byte 0, so the caption, tab strip, dividers and pane headers would
//! vanish into the desktop behind them.
//!
//! The fix is one wrapper rather than an edit per painter: the chrome is
//! painted into a 32bpp DIB pre-filled with a MARKER - the terminal background
//! at `background-opacity`, premultiplied, so a painter that blends against
//! what is underneath blends against the terminal colour - and afterwards any
//! pixel that no longer holds the marker was written by a painter and is made
//! opaque, while every pixel nobody painted is made transparent so it leaves
//! the window alone. Future painters inherit this for free, which an audit of
//! every GDI call site could not promise.
//!
//! Pure: no Win32 here, so the rule is tested in the `none` lane.

const std = @import("std");

/// The marker a DIB is filled with before the chrome is painted into it:
/// `rgb` premultiplied by `opacity`, alpha = `opacity`, as 0xAARRGGBB (the
/// BI_RGB byte order GDI and DWM read).
///
/// Never 0: an all-zero marker is also exactly what GDI writes for black ink
/// (black text, a black fill), and a painted black pixel would then be taken
/// for background and stay transparent. At `background-opacity = 0` the marker
/// is alpha 1 instead - one step off invisible, and distinguishable.
pub fn marker(r: u8, g: u8, b: u8, opacity: f64) u32 {
    const a_f = std.math.clamp(opacity, 0.0, 1.0);
    const a: u32 = @max(1, @as(u32, @intFromFloat(@round(a_f * 255.0))));
    const pr = premul(r, a);
    const pg = premul(g, a);
    const pb = premul(b, a);
    return (a << 24) | (@as(u32, pr) << 16) | (@as(u32, pg) << 8) | pb;
}

fn premul(c: u8, a: u32) u32 {
    return (@as(u32, c) * a + 127) / 255;
}

/// Make every pixel a painter touched fully opaque, and every pixel nobody
/// touched fully TRANSPARENT (premultiplied 0).
///
/// "Touched" is "no longer equal to the marker". GDI writes alpha 0, and the
/// tab strip's own per-pixel compositing writes alpha 0 too, so a painted
/// pixel can only collide with the marker by carrying the marker's exact
/// non-zero alpha AND its exact premultiplied colour.
///
/// Untouched goes to 0 rather than staying the marker because the buffer is
/// laid down with a source-over `AlphaBlend`: a 0 pixel leaves the window's
/// pixel as it was. A pass that paints only the divider bands (the
/// post-layout `GetDC` pass) must not overwrite the caption the paint cycle
/// drew - which is exactly what an opaque blit of the whole clip box did.
pub fn resolve(pixels: []u32, fill: u32) void {
    for (pixels) |*p| {
        p.* = if (p.* == fill) 0 else p.* | 0xFF00_0000;
    }
}

test "marker premultiplies the background by the opacity" {
    // #101010 at 0.6: alpha 153, each channel 16 * 153 / 255 = 9.6 -> 10.
    try std.testing.expectEqual(@as(u32, 0x990A0A0A), marker(0x10, 0x10, 0x10, 0.6));
    // Opaque: the colour itself.
    try std.testing.expectEqual(@as(u32, 0xFF123456), marker(0x12, 0x34, 0x56, 1.0));
}

test "marker is never zero, so painted black stays distinguishable" {
    try std.testing.expect(marker(0, 0, 0, 0.0) != 0);
    try std.testing.expectEqual(@as(u32, 0x01000000), marker(0, 0, 0, 0.0));
    // Out-of-range opacity clamps rather than wrapping.
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), marker(0xFF, 0xFF, 0xFF, 7.0));
}

test "painted pixels go opaque, untouched pixels go transparent" {
    const fill = marker(0x10, 0x10, 0x10, 0.6);
    var px = [_]u32{
        fill, // nobody painted it
        0x00202020, // GDI fill: alpha 0
        0x00000000, // GDI black text
        0x00FFFFFF, // GDI white text
        fill,
    };
    resolve(&px, fill);
    try std.testing.expectEqual(@as(u32, 0), px[0]);
    try std.testing.expectEqual(@as(u32, 0xFF202020), px[1]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[2]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[3]);
    try std.testing.expectEqual(@as(u32, 0), px[4]);
}

test "black ink on a fully transparent window is still painted" {
    const fill = marker(0, 0, 0, 0.0);
    var px = [_]u32{ fill, 0x00000000 };
    resolve(&px, fill);
    try std.testing.expectEqual(@as(u32, 0), px[0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[1]);
}
