//! Whether a terminal pane window gets a composition surface of its own
//! (T2499). Pure, so the none lane can hold the rule.
//!
//! A plain WGL child presents into its TOP-LEVEL's redirection surface, and on
//! the box that found it (RTX 4090, WGL) each child that ever ran
//! `SwapBuffers` left a top-level-sized GPU allocation behind that only the
//! top-level's destruction released: 3 MB a closed pane at the default window
//! size, 8 MB at 1800x1100. Bisected in T2499 - present on, leak; present off
//! for the new pane only, flat; context deleted, window destroyed early,
//! hidden, re-parented or frame-nudged first, all still leak. Making the pane a
//! LAYERED child (Windows 8+, constant alpha 255, `Window.composeOpaqueLayer`)
//! gives it its own pane-sized surface that dies with it: flat across closes,
//! and an open pane costs ~6 MB of GPU instead of ~9.
//!
//! Two limits decide when it may be used:
//! - A constant-alpha layer is composed OPAQUE whatever alpha its pixels
//!   carry, so a translucent window (`background-opacity` < 1) keeps the plain
//!   child - layering it would stop the desktop showing through the panes.
//! - It is ON by default since T2502, after a layered pane was photographed on
//!   the real desktop (text, cursor, split, resize, divider drag, stack folds)
//!   and T2503 showed resize-flicker reads the same with and without it.
//!   `GHOZTTY_PANE_LAYER=0` turns it off, as an escape hatch and for A/B runs.
const std = @import("std");
const builtin = @import("builtin");

/// The environment knob that opts panes OUT of their own layer. Read per pane.
pub const env_knob = "GHOZTTY_PANE_LAYER";

/// Whether the knob's value allows it: unset, or anything but
/// "0"/"false"/"off", leaves the default (on).
pub fn knobAllows(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return true, " \t\r\n");
    return !(std.mem.eql(u8, v, "0") or
        std.ascii.eqlIgnoreCase(v, "false") or
        std.ascii.eqlIgnoreCase(v, "off"));
}

pub fn enabled() bool {
    if (comptime builtin.os.tag != .windows) return false;
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, env_knob) catch return true;
    defer std.heap.page_allocator.free(raw);
    return knobAllows(raw);
}

/// Should a pane in a window in this state be its own layer?
pub fn wantOwnLayer(opted_in: bool, window_translucent: bool) bool {
    return opted_in and !window_translucent;
}

test "knobAllows is on unless the knob says off" {
    try std.testing.expect(knobAllows(null));
    try std.testing.expect(knobAllows(""));
    try std.testing.expect(knobAllows("1"));
    try std.testing.expect(knobAllows("on"));
    try std.testing.expect(!knobAllows("0"));
    try std.testing.expect(!knobAllows(" FALSE\r\n"));
    try std.testing.expect(!knobAllows("off"));
}

test "a translucent window never layers its panes" {
    try std.testing.expect(wantOwnLayer(true, false));
    try std.testing.expect(!wantOwnLayer(true, true));
    try std.testing.expect(!wantOwnLayer(false, false));
    try std.testing.expect(!wantOwnLayer(false, true));
}
