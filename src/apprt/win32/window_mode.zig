//! Single-window mode's launch latch (T3180) - the win32 port of Mac
//! `WindowMode` (`macos/Sources/Features/Terminal/WindowMode.swift`, Mac
//! 3f772a2f0). Spec: docs/reference/window-modes.md.
//!
//! `macos-window-mode` (`separate` | `single`) is read ONCE, when the app
//! starts: a window is built for one mode or the other, so a change in the
//! config file (a reload, the Settings row) takes effect at the next launch,
//! where the windows that were open come back in the new mode. `App.init`
//! latches the startup config's value; everything after asks `current()`,
//! never the live config. The one Windows addition (T3212): the app stays
//! resident with no window open, so the first window opened while none is
//! open counts as the next launch and reads the mode again (`relatchIdle`).
//!
//! Pure (no OS imports), so its tests run in every app-runtime lane.
const std = @import("std");
const Config = @import("../../config.zig").Config;

pub const Mode = Config.MacWindowMode;

/// The value the app started with; null until `latch` runs.
var latched: ?Mode = null;

/// Tests only: the mode, whatever was latched (Mac `overrideForTesting`).
pub var override_for_testing: ?Mode = null;

/// Record the mode the app starts in. Only the first call counts: a config
/// reload that calls it again cannot move the mode until the next launch.
/// Returns the mode now in force.
pub fn latch(mode: Mode) Mode {
    if (latched == null) latched = mode;
    return latched.?;
}

/// Read the mode again because no window is open (T3212). On Windows the app
/// stays resident when its last window closes (`quit-after-last-window-closed`
/// is off) and nothing on screen says it is still running, so to the user
/// closing every window IS quitting, and the next window they open is the
/// next launch. Without this a mode chosen in Settings waited for a quit the
/// user had no way to see they owed. The caller asks only while no terminal
/// window exists, so no window is ever left built for the other mode.
/// Returns the mode it replaced, or null when nothing moved.
pub fn relatchIdle(mode: Mode) ?Mode {
    const old = latched orelse {
        latched = mode;
        return null;
    };
    if (old == mode) return null;
    latched = mode;
    return old;
}

/// The mode this launch runs in: the test override, else the latched launch
/// value, else `separate` (nothing latched yet - exactly as before the
/// option existed).
pub fn current() Mode {
    if (override_for_testing) |m| return m;
    return latched orelse .separate;
}

pub fn isSingle() bool {
    return current() == .single;
}

/// Tests only: forget the latch, as a fresh launch would.
pub fn resetForTesting() void {
    latched = null;
    override_for_testing = null;
}

test "window_mode: separate until latched, then the first latch wins" {
    resetForTesting();
    defer resetForTesting();
    try std.testing.expectEqual(Mode.separate, current());
    try std.testing.expect(!isSingle());

    try std.testing.expectEqual(Mode.single, latch(.single));
    try std.testing.expect(isSingle());

    // A reload with the file now saying `separate` does not move it.
    try std.testing.expectEqual(Mode.single, latch(.separate));
    try std.testing.expectEqual(Mode.single, current());

    // A fresh launch reads the file again.
    resetForTesting();
    try std.testing.expectEqual(Mode.separate, latch(.separate));
    try std.testing.expectEqual(Mode.separate, latch(.single));
    try std.testing.expect(!isSingle());
}

test "window_mode: with no window open the mode is read again (T3212)" {
    resetForTesting();
    defer resetForTesting();
    _ = latch(.separate);
    // A reload alone does not move it...
    try std.testing.expectEqual(Mode.separate, latch(.single));
    // ...the next window opened with none open does.
    try std.testing.expectEqual(@as(?Mode, .separate), relatchIdle(.single));
    try std.testing.expect(isSingle());
    // Same value: nothing moved.
    try std.testing.expectEqual(@as(?Mode, null), relatchIdle(.single));
    // And back.
    try std.testing.expectEqual(@as(?Mode, .single), relatchIdle(.separate));
    try std.testing.expect(!isSingle());
    // Nothing latched yet: it latches, and reports no move.
    resetForTesting();
    try std.testing.expectEqual(@as(?Mode, null), relatchIdle(.single));
    try std.testing.expect(isSingle());
}

test "window_mode: the test override beats the latch" {
    resetForTesting();
    defer resetForTesting();
    _ = latch(.separate);
    override_for_testing = .single;
    try std.testing.expect(isSingle());
    override_for_testing = null;
    try std.testing.expect(!isSingle());
}

test "window_mode: the config default is separate" {
    var cfg = try Config.default(std.testing.allocator);
    defer cfg.deinit();
    try std.testing.expectEqual(Mode.separate, cfg.@"macos-window-mode");
}
