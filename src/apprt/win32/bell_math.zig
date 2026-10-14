//! Pure logic for the win32 bell (T1890): the title glyph a rung pane puts in
//! front of its window and tab title, and the MCI command strings that play
//! `bell-audio-path` at `bell-audio-volume`. No OS imports, so the tests run
//! in every app-runtime lane (the hero_math/dim_math pattern). The playback
//! itself is `bell_audio.zig`.

const std = @import("std");

/// What Mac puts in front of a title whose focused surface has an unacknowledged
/// bell (`BaseTerminalController.computeTitle`): the bell emoji and a space.
pub const title_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\u{1F514} ");

/// The prefix a title gets, which is none unless `bell-features` has `title`
/// AND the pane that names the title has rung since it was last looked at.
pub fn titlePrefix(title_feature: bool, bell: bool) []const u16 {
    return if (title_feature and bell) title_prefix else &.{};
}

/// The MCI alias the one bell sound device is opened under.
pub const alias = "ghozttybell";

/// `bell-audio-volume` (0.0 silence .. 1.0 loudest, relative to the system
/// volume, exactly as Mac's `NSSound.volume`) onto MCI's `setaudio` scale of
/// 0..1000. Out-of-range values clamp; NaN takes the config default of 0.5.
pub fn mciVolume(volume: f64) u32 {
    if (std.math.isNan(volume)) return 500;
    const clamped = std.math.clamp(volume, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 1000.0));
}

pub const CommandError = error{ NoSpaceLeft, InvalidPath };

/// `open "<path>" type mpegvideo alias ghozttybell`. The `mpegvideo` device is
/// DirectShow's, which plays every format Windows has a codec for (wav, mp3,
/// aiff, wma, m4a) and is the only MCI device type that honours `setaudio
/// volume` - the `waveaudio` one plays wav alone and has no volume at all.
///
/// A path holding a double quote cannot be quoted for MCI; Windows file names
/// cannot contain one either, so refusing it costs nothing real.
pub fn openCommand(buf: []u8, path: []const u8) CommandError![:0]const u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, '"') != null) return error.InvalidPath;
    return std.fmt.bufPrintZ(buf, "open \"{s}\" type mpegvideo alias " ++ alias, .{path});
}

pub fn volumeCommand(buf: []u8, volume: f64) CommandError![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "setaudio " ++ alias ++ " volume to {d}", .{mciVolume(volume)});
}

/// Restart from the top on every ring, so a bell that rings while the last
/// one is still sounding is heard as a new bell rather than ignored.
pub const play_command = "play " ++ alias ++ " from 0";
pub const close_command = "close " ++ alias;

test "titlePrefix needs both the feature and a rung pane" {
    try std.testing.expectEqual(@as(usize, 0), titlePrefix(false, false).len);
    try std.testing.expectEqual(@as(usize, 0), titlePrefix(false, true).len);
    try std.testing.expectEqual(@as(usize, 0), titlePrefix(true, false).len);
    try std.testing.expectEqualSlices(u16, title_prefix, titlePrefix(true, true));
}

test "title prefix is the bell emoji and a space, as Mac writes it" {
    // U+1F514 is a surrogate pair in UTF-16, then the space.
    try std.testing.expectEqualSlices(u16, &.{ 0xD83D, 0xDD14, ' ' }, title_prefix);
}

test "mciVolume maps the 0..1 config onto 0..1000 and clamps" {
    try std.testing.expectEqual(@as(u32, 0), mciVolume(0.0));
    try std.testing.expectEqual(@as(u32, 500), mciVolume(0.5));
    try std.testing.expectEqual(@as(u32, 1000), mciVolume(1.0));
    try std.testing.expectEqual(@as(u32, 250), mciVolume(0.25));
    try std.testing.expectEqual(@as(u32, 0), mciVolume(-3.0));
    try std.testing.expectEqual(@as(u32, 1000), mciVolume(7.0));
    try std.testing.expectEqual(@as(u32, 500), mciVolume(std.math.nan(f64)));
}

test "openCommand quotes the path and names the mpegvideo device" {
    var buf: [512]u8 = undefined;
    const cmd = try openCommand(&buf, "C:\\Users\\me\\My Sounds\\ding.mp3");
    try std.testing.expectEqualStrings(
        "open \"C:\\Users\\me\\My Sounds\\ding.mp3\" type mpegvideo alias ghozttybell",
        cmd,
    );
}

test "openCommand refuses an empty or unquotable path and a too-small buffer" {
    var buf: [512]u8 = undefined;
    try std.testing.expectError(error.InvalidPath, openCommand(&buf, ""));
    try std.testing.expectError(error.InvalidPath, openCommand(&buf, "a\"b.wav"));
    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, openCommand(&tiny, "C:\\x.wav"));
}

test "volumeCommand carries the mapped volume" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("setaudio ghozttybell volume to 300", try volumeCommand(&buf, 0.3));
}

// ---------------------------------------------------------------------------
// The `border` feature (T1919): Mac's `SurfaceView.BellBorderOverlay`, a 3pt
// `strokeBorder` of rgb(1.0, 0.8, 0.0) at 50% opacity around the surface's
// edges, faded in and out over 0.3s easeInOut. The window half is
// `BellBorder.zig`; everything that can be decided without a window is here.
// ---------------------------------------------------------------------------

/// Mac's `lineWidth: 3`, in DIP.
pub const border_width_dip: f32 = 3.0;

/// `.animation(.easeInOut(duration: 0.3))`.
pub const fade_ms: i64 = 300;

/// The frame as one premultiplied BGRA pixel (what `UpdateLayeredWindow`
/// takes): rgb(255, 204, 0) at alpha 0.5. A `strokeBorder` with a translucent
/// colour paints every frame pixel at that opacity once, so the frame is a
/// single flat value - 128 alpha, each channel scaled by 128/255.
pub const frame_pixel: u32 = premultiply(255, 204, 0, 128);

fn premultiply(r: u32, g: u32, b: u32, a: u32) u32 {
    return (a << 24) | (((r * a + 127) / 255) << 16) | (((g * a + 127) / 255) << 8) | ((b * a + 127) / 255);
}

/// The stroke's width in device pixels at `scale`: Mac's 3pt, never thinner
/// than one pixel.
pub fn borderWidthPx(scale: f32) i32 {
    const s = if (std.math.isNan(scale) or scale <= 0) 1.0 else scale;
    return @max(1, @as(i32, @intFromFloat(@round(border_width_dip * s))));
}

/// Fill `px` (a top-down `w` x `h` buffer) with the frame: `frame_pixel` in
/// the outer `width` pixels on every side, fully transparent inside - the
/// `strokeBorder` (inset, so the stroke never spills past the pane). A pane
/// narrower than two strokes is all frame.
pub fn renderFrame(px: []u32, w: i32, h: i32, width: i32) void {
    if (w <= 0 or h <= 0) return;
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    std.debug.assert(px.len >= uw * uh);
    const bw: usize = @intCast(@max(width, 0));
    for (0..uh) |y| {
        const row = px[y * uw ..][0..uw];
        if (y < bw or y + bw >= uh) {
            @memset(row, frame_pixel);
            continue;
        }
        const side = @min(bw, uw);
        @memset(row, 0);
        @memset(row[0..side], frame_pixel);
        @memset(row[uw - side ..], frame_pixel);
    }
}

/// SwiftUI's `.easeInOut`: the cubic Bezier (0.42, 0) (0.58, 1), as y for a
/// time fraction `t` in 0..1. x(u) is monotonic, so u is found by bisection.
pub fn easeInOut(t: f64) f64 {
    if (!(t > 0)) return 0;
    if (t >= 1) return 1;
    const bez = struct {
        fn at(u: f64, p1: f64, p2: f64) f64 {
            const v = 1 - u;
            return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u;
        }
    };
    var lo: f64 = 0;
    var hi: f64 = 1;
    for (0..40) |_| {
        const mid = (lo + hi) / 2;
        if (bez.at(mid, 0.42, 0.58) < t) lo = mid else hi = mid;
    }
    return bez.at((lo + hi) / 2, 0, 1);
}

/// The frame's whole-window opacity (0..255, the `SourceConstantAlpha` of the
/// blend) `elapsed_ms` into a fade from `from` toward `to`. A fade that
/// reverses part-way starts from where the last one got to, the way SwiftUI
/// retargets a running animation, so `from` is wherever the frame was.
pub fn fadeAlpha(from: u8, to: u8, elapsed_ms: i64) u8 {
    if (elapsed_ms >= fade_ms) return to;
    const t = @as(f64, @floatFromInt(@max(elapsed_ms, 0))) / @as(f64, @floatFromInt(fade_ms));
    const e = easeInOut(t);
    const f: f64 = @floatFromInt(from);
    const g: f64 = @floatFromInt(to);
    return @intFromFloat(std.math.clamp(@round(f + (g - f) * e), 0, 255));
}

test "frame pixel is Mac's yellow at half opacity, premultiplied" {
    try std.testing.expectEqual(@as(u32, 128), frame_pixel >> 24);
    try std.testing.expectEqual(@as(u32, 128), (frame_pixel >> 16) & 0xFF); // 255 * .5
    try std.testing.expectEqual(@as(u32, 102), (frame_pixel >> 8) & 0xFF); // 204 * .5
    try std.testing.expectEqual(@as(u32, 0), frame_pixel & 0xFF);
}

test "borderWidthPx is 3 DIP scaled, at least one pixel" {
    try std.testing.expectEqual(@as(i32, 3), borderWidthPx(1.0));
    try std.testing.expectEqual(@as(i32, 4), borderWidthPx(1.25));
    try std.testing.expectEqual(@as(i32, 5), borderWidthPx(1.5));
    try std.testing.expectEqual(@as(i32, 6), borderWidthPx(2.0));
    try std.testing.expectEqual(@as(i32, 1), borderWidthPx(0.1));
    try std.testing.expectEqual(@as(i32, 3), borderWidthPx(0));
    try std.testing.expectEqual(@as(i32, 3), borderWidthPx(std.math.nan(f32)));
}

test "renderFrame strokes the outer width on every side and leaves the inside clear" {
    var px: [8 * 6]u32 = undefined;
    renderFrame(&px, 8, 6, 2);
    for (0..6) |y| for (0..8) |x| {
        const edge = x < 2 or x >= 6 or y < 2 or y >= 4;
        try std.testing.expectEqual(if (edge) frame_pixel else @as(u32, 0), px[y * 8 + x]);
    };
}

test "renderFrame on a pane narrower than two strokes is all frame" {
    var px: [3 * 3]u32 = undefined;
    renderFrame(&px, 3, 3, 3);
    for (px) |p| try std.testing.expectEqual(frame_pixel, p);
}

test "easeInOut is anchored, symmetric and slow at both ends" {
    try std.testing.expectEqual(@as(f64, 0), easeInOut(0));
    try std.testing.expectEqual(@as(f64, 1), easeInOut(1));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), easeInOut(0.5), 1e-6);
    try std.testing.expectApproxEqAbs(1 - easeInOut(0.2), easeInOut(0.8), 1e-6);
    // Slower than linear at the start, faster in the middle.
    try std.testing.expect(easeInOut(0.1) < 0.1);
    try std.testing.expect(easeInOut(0.4) > 0.3);
    try std.testing.expectEqual(@as(f64, 0), easeInOut(-1));
    try std.testing.expectEqual(@as(f64, 0), easeInOut(std.math.nan(f64)));
}

test "fadeAlpha runs from..to over 0.3s and retargets from where it is" {
    try std.testing.expectEqual(@as(u8, 0), fadeAlpha(0, 255, 0));
    // Halfway in time is halfway in opacity (127.5, either side of it).
    const mid = fadeAlpha(0, 255, 150);
    try std.testing.expect(mid == 127 or mid == 128);
    try std.testing.expectEqual(@as(u8, 255), fadeAlpha(0, 255, 300));
    try std.testing.expectEqual(@as(u8, 255), fadeAlpha(0, 255, 10_000));
    try std.testing.expectEqual(@as(u8, 0), fadeAlpha(255, 0, 300));
    // A fade-out caught at 128 runs 128 -> 0, not 255 -> 0.
    try std.testing.expectEqual(@as(u8, 64), fadeAlpha(128, 0, 150));
    try std.testing.expectEqual(@as(u8, 40), fadeAlpha(40, 200, -5));
}
