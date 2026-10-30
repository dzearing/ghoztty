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
//! - What a layered GL pane looks like on screen has not been photographed:
//!   DWM composes only the input desktop, so the off-desktop harnesses cannot
//!   see it. Until that check is made it is opt-in, `GHOZTTY_PANE_LAYER=1`,
//!   the same shape as `GHOZTTY_COMP_PRESENT`.
const std = @import("std");
const builtin = @import("builtin");

/// The environment knob that opts panes into their own layer. Read per pane.
pub const env_knob = "GHOZTTY_PANE_LAYER";

/// Whether the knob's value asks for it. "1"/"true"/"on".
pub fn knobOn(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return false, " \t\r\n");
    return std.mem.eql(u8, v, "1") or
        std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "on");
}

pub fn enabled() bool {
    if (comptime builtin.os.tag != .windows) return false;
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, env_knob) catch return false;
    defer std.heap.page_allocator.free(raw);
    return knobOn(raw);
}

/// Should a pane in a window in this state be its own layer?
pub fn wantOwnLayer(opted_in: bool, window_translucent: bool) bool {
    return opted_in and !window_translucent;
}

test "knobOn accepts the usual spellings and nothing else" {
    try std.testing.expect(knobOn("1"));
    try std.testing.expect(knobOn(" TRUE\r\n"));
    try std.testing.expect(knobOn("on"));
    try std.testing.expect(!knobOn(null));
    try std.testing.expect(!knobOn(""));
    try std.testing.expect(!knobOn("0"));
    try std.testing.expect(!knobOn("yes please"));
}

test "a translucent window never layers its panes" {
    try std.testing.expect(wantOwnLayer(true, false));
    try std.testing.expect(!wantOwnLayer(true, true));
    try std.testing.expect(!wantOwnLayer(false, false));
    try std.testing.expect(!wantOwnLayer(false, true));
}
