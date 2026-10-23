//! Does this launch open the blank startup window, and when? (T2162)
//!
//! `ghoztty +new-window --target=X` with no app running auto-launches one and
//! then re-sends the request to it. Before T2162 the launched instance opened
//! its own blank window first, so the caller got TWO windows: the one it asked
//! for and a stray `window-1` it had to close. macOS never shows that second
//! window: the app honors `initial-window`, and a launch that is serving a
//! pending IPC request skips the first window altogether.
//!
//! Windows now honors `initial-window` too, and the auto-launch passes
//! `--initial-window=false`. What cannot be carried across exactly is "no
//! window at all": a Mac app with no window still has a Dock icon to click, and
//! a Windows app with no window is invisible — the silent headless start T1177
//! refuses. So `false` DEFERS the blank window instead of dropping it: the app
//! waits `grace_ms`, and opens one then only if nothing else did (the request
//! failed, the CLI died before it re-sent, or the user set the key by hand).
//!
//! The mechanism (the timer, the window) lives in `App.zig`; the decision lives
//! here, pure, so both app-runtime lanes test it without a window.

const std = @import("std");

/// How long a deferred startup waits for somebody else's window before it
/// opens its own. The auto-launching CLI re-sends every
/// `ipc_timeout.auto_launch_poll_ms` (250ms) from the moment it spawned us, so
/// its request lands well inside this on any box; the margin is for a cold
/// debug start on a loaded one.
pub const grace_ms: u32 = 5_000;

pub const Plan = enum {
    /// Open the blank startup window now (every ordinary launch).
    create,
    /// Open none now; arm the grace timer, which opens one if the app still
    /// has no window when it fires.
    deferred,
    /// Open none: a window already exists or restore rebuilt the real ones.
    none,
};

/// `initial_window` is the resolved `initial-window` config value.
/// `have_window` is true when the launch command's window or session restore
/// already put something on screen. `force_no_window` is the T1177 test seam,
/// which must reach the no-window refusal rather than be rescued by the grace
/// timer.
pub fn plan(initial_window: bool, have_window: bool, force_no_window: bool) Plan {
    if (have_window or force_no_window) return .none;
    return if (initial_window) .create else .deferred;
}

/// At the grace timer: open the stand-in only if the app still has no window.
pub fn fallbackNeeded(window_count: usize) bool {
    return window_count == 0;
}

test "plan: an ordinary launch opens its startup window" {
    try std.testing.expectEqual(Plan.create, plan(true, false, false));
}

test "plan: initial-window=false defers instead of dropping (T2162)" {
    try std.testing.expectEqual(Plan.deferred, plan(false, false, false));
}

test "plan: restore or a launch command already showed a window" {
    try std.testing.expectEqual(Plan.none, plan(true, true, false));
    try std.testing.expectEqual(Plan.none, plan(false, true, false));
}

test "plan: the T1177 seam is never rescued by the grace timer" {
    try std.testing.expectEqual(Plan.none, plan(true, false, true));
    try std.testing.expectEqual(Plan.none, plan(false, false, true));
}

test "fallbackNeeded: only when nothing else opened a window" {
    try std.testing.expect(fallbackNeeded(0));
    try std.testing.expect(!fallbackNeeded(1));
}

test "grace_ms outlasts the auto-launch poll by a wide margin" {
    const ipc_timeout = @import("../../os/ipc_timeout.zig");
    try std.testing.expect(grace_ms >= 10 * ipc_timeout.auto_launch_poll_ms);
}
