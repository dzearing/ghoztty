//! Single-window mode's launch latch (T3180) - the win32 port of Mac
//! `WindowMode` (`macos/Sources/Features/Terminal/WindowMode.swift`, Mac
//! 3f772a2f0). Spec: docs/reference/window-modes.md.
//!
//! `macos-window-mode` (`separate` | `single`) is read ONCE, when the app
//! starts: a window is built for one mode or the other, so a change in the
//! config file (a reload, the Settings row) takes effect at the next launch,
//! where the windows that were open come back in the new mode. `App.init`
//! latches the startup config's value; everything after asks `current()`,
//! never the live config.
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
