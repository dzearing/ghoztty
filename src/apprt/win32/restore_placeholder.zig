//! The launch's stand-in window after a LATE restore (T1003) — when may it go?
//!
//! A launch whose restore could not finish (the local agent had not come up
//! yet, T976) opens one blank terminal so the user is never looking at nothing.
//! When the deferred pass then rebuilds the real windows around it, that blank
//! window is a leftover the user never asked for. T976 deliberately left it
//! alone, because closing a window the user has already started using is far
//! worse than an extra one. This module draws the line between the two.
//!
//! The rule is INPUT, not output. A fresh shell prints a banner and a prompt
//! the moment it starts, so "nothing has appeared in it" can never be true of
//! a pane worth keeping or of one worth closing — it cannot tell them apart.
//! What can is whether anything was ever sent TO the shell: a key, a paste, a
//! mouse report, a `+send-keys`. Every one of those reaches the pty through the
//! same queue (`termio.Termio.queueMessage`), which is where the fact is kept.
//!
//! The mechanism (which window, how it closes) lives in `App.zig`; the decision
//! lives here, pure, so both app-runtime lanes test it without a window.

const std = @import("std");

/// Everything the decision needs to know about the stand-in window, read by
/// the caller at the moment the deferred restore finishes.
pub const Facts = struct {
    /// The window is still in the app's list and not already closing.
    alive: bool,
    /// Tabs in the window.
    tabs: usize,
    /// Panes in its (only) tab.
    panes: usize,
    /// That pane is a viewer (markdown, website, diff), not a terminal. A
    /// viewer in the stand-in window can only have been put there on purpose.
    viewer: bool,
    /// The pane's terminal finished initializing. One that did not is not
    /// "pristine", it is broken, and closing it would hide that.
    initialized: bool,
    /// Anything was ever written to the pane's shell.
    input_seen: bool,
};

/// Whether the stand-in window is exactly as the launch left it.
pub fn isPristine(f: Facts) bool {
    return f.alive and
        f.tabs == 1 and
        f.panes == 1 and
        !f.viewer and
        f.initialized and
        !f.input_seen;
}

/// Whether to close it: only when the deferred restore actually put at least
/// one window on screen (otherwise closing it would leave the user with
/// nothing, or with less than they had), and only while it is pristine.
pub fn shouldClose(restored_windows: bool, f: Facts) bool {
    return restored_windows and isPristine(f);
}

const pristine: Facts = .{
    .alive = true,
    .tabs = 1,
    .panes = 1,
    .viewer = false,
    .initialized = true,
    .input_seen = false,
};

test "a stand-in window nobody touched is closed once the late restore lands" {
    try std.testing.expect(isPristine(pristine));
    try std.testing.expect(shouldClose(true, pristine));
}

test "a late restore that rebuilt nothing never closes the only window" {
    try std.testing.expect(!shouldClose(false, pristine));
}

test "any sign of use keeps the window" {
    const testing = std.testing;
    var f = pristine;

    // Typed into (or pasted, or sent keys by a script).
    f = pristine;
    f.input_seen = true;
    try testing.expect(!shouldClose(true, f));

    // A second tab or a split is something the user built.
    f = pristine;
    f.tabs = 2;
    try testing.expect(!shouldClose(true, f));
    f = pristine;
    f.panes = 2;
    try testing.expect(!shouldClose(true, f));

    // A viewer was opened in it.
    f = pristine;
    f.viewer = true;
    try testing.expect(!shouldClose(true, f));
}

test "a window that is already gone, closing, or broken is left alone" {
    const testing = std.testing;
    var f = pristine;
    f.alive = false;
    try testing.expect(!shouldClose(true, f));

    // No tabs at all is not the launch's shape either.
    f = pristine;
    f.tabs = 0;
    try testing.expect(!shouldClose(true, f));
    f = pristine;
    f.panes = 0;
    try testing.expect(!shouldClose(true, f));

    f = pristine;
    f.initialized = false;
    try testing.expect(!shouldClose(true, f));
}
