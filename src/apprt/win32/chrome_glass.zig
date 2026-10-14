//! The glass title bar (T1886): with glass panes, Mac runs the window's
//! gradient up under a cleared titlebar (main 8174d96fc,
//! `titlebarAppearsTransparent` + `.fullSizeContentView`), so the window is
//! one surface. On Windows the caption band and the tab strip are the
//! window's own pixels, so they paint their slice of the same desk instead of
//! the chrome bar colour, and the tabs and buttons draw over it.
//!
//! The one thing the bar colour guaranteed that the desk does not is the
//! chrome-contrast floor (T306): the title is `Palette.text` at 4.5:1 against
//! the bar. Over the desk that is measured against the band's own pixels, and
//! where some pixel would miss it the bar is laid over the desk as a scrim at
//! the least strength that clears it - at full strength the band is the bar
//! again, which meets the floor by construction. The desk and the chrome
//! palette both take their light/dark flavour from the terminal background,
//! so on every shipped palette the scrim is zero; it is the floor, not the
//! look.
//!
//! Pure: buffers in, buffers out, no OS imports - tested in the `none` lane.

const std = @import("std");
const color_math = @import("color_math.zig");

const Rgb = color_math.Rgb;

/// Scrim strengths are searched in steps of this much.
pub const SCRIM_STEP: f32 = 0.1;

/// Every `SAMPLE_STRIDE`th pixel on both axes is measured: the desk is a
/// smooth gradient (rendered at a quarter size and stretched), so this sees
/// every value it has without paying for each pixel on every caption hover.
pub const SAMPLE_STRIDE: usize = 3;

fn unpack(p: u32) Rgb {
    return .{
        .r = @truncate(p >> 16),
        .g = @truncate(p >> 8),
        .b = @truncate(p),
    };
}

fn pack(c: Rgb) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

fn mixChannel(a: u8, b: u8, t: f32) u8 {
    const fa: f32 = @floatFromInt(a);
    const fb: f32 = @floatFromInt(b);
    return @intFromFloat(std.math.clamp(@round(fa + (fb - fa) * t), 0, 255));
}

/// `over` at strength `a` over `under`, in display space - the same mix the
/// GDI chrome paints in.
pub fn scrim(under: Rgb, over: Rgb, a: f32) Rgb {
    if (a <= 0) return under;
    if (a >= 1) return over;
    return .{
        .r = mixChannel(under.r, over.r, a),
        .g = mixChannel(under.g, over.g, a),
        .b = mixChannel(under.b, over.b, a),
    };
}

/// The least scrim (a multiple of `SCRIM_STEP`, 0...1) of `bar` over the
/// `w` x `h` `band` at which `text` reads at `floor`:1 against every
/// sampled pixel. 1 when even that misses (the bar itself is then the best
/// there is, and the bar is what the solid chrome paints).
pub fn scrimAlpha(band: []const u32, w: usize, h: usize, text: Rgb, bar: Rgb, floor: f64) f32 {
    if (w == 0 or h == 0 or band.len < w * h) return 1;
    const text_lum = color_math.wcagLuminance(text);
    var steps: u32 = 0;
    const max_steps: u32 = @intFromFloat(@round(1.0 / SCRIM_STEP));
    while (steps < max_steps) : (steps += 1) {
        const a = @as(f32, @floatFromInt(steps)) * SCRIM_STEP;
        if (bandClears(band, w, h, text_lum, bar, a, floor)) return a;
    }
    return 1;
}

fn bandClears(band: []const u32, w: usize, h: usize, text_lum: f64, bar: Rgb, a: f32, floor: f64) bool {
    var y: usize = 0;
    while (y < h) : (y += SAMPLE_STRIDE) {
        var x: usize = 0;
        while (x < w) : (x += SAMPLE_STRIDE) {
            const c = scrim(unpack(band[y * w + x]), bar, a);
            if (color_math.wcagContrastRatio(text_lum, color_math.wcagLuminance(c)) < floor) return false;
        }
    }
    return true;
}

/// The glass band, ready to paint over: `out` (`w` x `h`) gets rows `y0`..
/// of the `desk_w` x `desk_h` `desk` (both top-down `0x00RRGGBB`, sharing a
/// left edge), anything the desk does not cover as `bar`, and `bar` laid over
/// it all at the strength that keeps `text` at the chrome's 4.5:1 floor.
/// Returns that strength (0 on every shipped palette).
pub fn fillBand(
    out: []u32,
    w: usize,
    h: usize,
    desk: []const u32,
    desk_w: usize,
    desk_h: usize,
    y0: usize,
    text: Rgb,
    bar: Rgb,
) f32 {
    if (out.len < w * h) return 1;
    const fill = pack(bar);
    for (0..h) |y| {
        const row = out[y * w ..][0..w];
        const dy = y0 + y;
        if (dy >= desk_h or desk.len < (dy + 1) * desk_w) {
            @memset(row, fill);
            continue;
        }
        const n = @min(w, desk_w);
        @memcpy(row[0..n], desk[dy * desk_w ..][0..n]);
        if (n < w) @memset(row[n..], fill);
    }
    const a = scrimAlpha(out[0 .. w * h], w, h, text, bar, color_math.contrast_target);
    if (a > 0) {
        for (out[0 .. w * h]) |*p| p.* = pack(scrim(unpack(p.*), bar, a));
    }
    return a;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const desk_palette = @import("desk_palette.zig");
const chrome_theme = @import("chrome_theme.zig");

fn ratio(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(color_math.wcagLuminance(a), color_math.wcagLuminance(b));
}

/// The top `h` rows of a `w`-wide desk laid out over a `w` x `full_h`
/// window, as the window renders it.
fn deskBand(buf: []u32, w: usize, h: usize, full_h: usize, pal: desk_palette.Palette) void {
    for (0..h) |y| for (0..w) |x| {
        const c = pal.at(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, @floatFromInt(w), @floatFromInt(full_h));
        buf[y * w + x] = c.pack() & 0x00FF_FFFF;
    };
}

test "the band is the desk's own rows, offset by y0, with bar past its end" {
    const desk = [_]u32{ 1, 2, 3, 4, 5, 6 }; // 2 wide, 3 tall
    var out: [6]u32 = undefined;
    // Black text over near-black pixels would need a scrim; white text over
    // them does not, so this measures only the copy.
    const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    const bar: Rgb = .{ .r = 0, .g = 0, .b = 9 };
    const a = fillBand(&out, 2, 3, &desk, 2, 3, 1, white, bar);
    try testing.expectEqual(@as(f32, 0), a);
    try testing.expectEqualSlices(u32, &.{ 3, 4, 5, 6, 9, 9 }, &out);
}

test "no scrim on any shipped desk: the title reads on the gradient itself" {
    var buf: [240 * 40]u32 = undefined;
    const backgrounds = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0x28, .g = 0x2c, .b = 0x34 },
        .{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 0xfd, .g = 0xf6, .b = 0xe3 },
    };
    for (backgrounds) |bg| {
        const pal = chrome_theme.resolve(bg, .{ .r = 0x00, .g = 0x78, .b = 0xd4 });
        const is_light = color_math.isLight(bg);
        var seed: u64 = 1;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const dp = if (i == 0) desk_palette.Palette.ocean(is_light) else (desk_palette.Variant{ .seed = seed }).palette(is_light);
            seed = seed *% 0x9E37_79B9_7F4A_7C15 +% 1;
            deskBand(&buf, 240, 40, 160, dp);
            try testing.expectEqual(@as(f32, 0), scrimAlpha(&buf, 240, 40, pal.text, pal.bar, color_math.contrast_target));
        }
    }
}

test "a band the title cannot read on gets the least scrim that clears the floor" {
    // White text over a near-white band: unreadable bare.
    const w = 12;
    const h = 6;
    var band: [w * h]u32 = undefined;
    @memset(&band, 0x00F0F0F0);
    const text: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    const bar: Rgb = .{ .r = 0x20, .g = 0x22, .b = 0x28 };
    const a = scrimAlpha(&band, w, h, text, bar, 4.5);
    try testing.expect(a > 0 and a <= 1);
    try testing.expect(ratio(text, scrim(unpack(0x00F0F0F0), bar, a)) >= 4.5);
    // ...and the step below it does not.
    try testing.expect(ratio(text, scrim(unpack(0x00F0F0F0), bar, a - SCRIM_STEP)) < 4.5);

    var out: [w * h]u32 = undefined;
    const got = fillBand(&out, w, h, &band, w, h, 0, text, bar);
    try testing.expectEqual(a, got);
    for (out) |p| try testing.expect(ratio(text, unpack(p)) >= 4.5);
}

test "a band nothing clears is the bar" {
    const band = [_]u32{0x00FFFFFF} ** 4;
    const text: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    const bar: Rgb = .{ .r = 250, .g = 250, .b = 250 };
    try testing.expectEqual(@as(f32, 1), scrimAlpha(&band, 2, 2, text, bar, 4.5));
}
