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
