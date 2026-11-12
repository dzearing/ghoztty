//! Pure logic for the attention request a window makes when one of its panes
//! starts waiting on the user (T2907). Mac
//! (`BaseTerminalController.setupActivityStatePublisher`) aggregates the
//! window's panes (`needs_input` > `busy` > `idle`), drops repeats, and calls
//! `NSApp.requestUserAttention` - the Dock bounce - when the aggregate moves
//! INTO `needs_input` while the window is not key. The Windows translation of
//! the Dock bounce is the taskbar-button flash the bell's `attention` feature
//! already uses. No OS imports, so the tests run in every app-runtime lane
//! (the bell_math pattern); the flash itself is in Window.zig.

const std = @import("std");

/// The window's last-seen aggregate, reduced to the one bit the rule needs.
pub const Tracker = struct {
    needs_input: bool = false,

    /// Record the window's current aggregate. Returns true when the window
    /// should ask for attention: this observation is a transition INTO
    /// `needs_input` and the window is in the background. A repeat (already
    /// `needs_input`) never asks again, and an active window never asks - the
    /// user is already looking at it, and Mac's `isKeyWindow` guard skips it
    /// too. The tracker moves either way, so a pane that went `needs_input`
    /// while the window was active does not flash later when it loses focus.
    pub fn observe(self: *Tracker, needs_input: bool, window_active: bool) bool {
        const entering = needs_input and !self.needs_input;
        self.needs_input = needs_input;
        return entering and !window_active;
    }
};

test "a background window flashes on the transition into needs_input" {
    var t: Tracker = .{};
    try std.testing.expect(t.observe(true, false));
}

test "a repeat needs_input never flashes again" {
    var t: Tracker = .{};
    try std.testing.expect(t.observe(true, false));
    try std.testing.expect(!t.observe(true, false));
    try std.testing.expect(!t.observe(true, false));
}

test "leaving needs_input and coming back flashes again" {
    var t: Tracker = .{};
    try std.testing.expect(t.observe(true, false));
    try std.testing.expect(!t.observe(false, false)); // idle or busy
    try std.testing.expect(t.observe(true, false));
}

test "an active window never flashes, and does not owe one later" {
    var t: Tracker = .{};
    try std.testing.expect(!t.observe(true, true));
    // Same aggregate, window now in the background: not a transition.
    try std.testing.expect(!t.observe(true, false));
}

test "idle and busy never flash" {
    var t: Tracker = .{};
    try std.testing.expect(!t.observe(false, false));
    try std.testing.expect(!t.observe(false, true));
    try std.testing.expect(!t.needs_input);
}
