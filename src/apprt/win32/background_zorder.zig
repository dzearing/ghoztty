//! Where a window opened in the BACKGROUND goes in the z-order (T1797, the
//! win32 half of main 3081022ec).
//!
//! A `ghoztty +new-window` without `--focus` must appear without taking the
//! user out of what they are doing: not activated, and not drawn over the app
//! they are in. The Mac orders such a window directly behind Ghoztty's
//! frontmost window (`orderBack` was tried first and buried it behind every
//! app, so the user could not find it either). Windows has the same two
//! failure modes - a no-activate show still lands at the TOP of the z-order,
//! over the user's app, and `HWND_BOTTOM` loses the window under everything -
//! so the same rule is applied here explicitly, after the show.
//!
//! Pure: the caller walks the real z-order and describes it. No win32 import,
//! so the rule is unit tested in the none-runtime lane.

const std = @import("std");

/// One top-level window, as the walk from the top of the z-order meets it.
pub const Entry = struct {
    /// One of this app's terminal windows, other than the one being placed.
    ours: bool,
    /// Carries `WS_EX_TOPMOST`.
    topmost: bool,
    /// `GetForegroundWindow()`.
    foreground: bool,
};

pub const Placement = union(enum) {
    /// Insert directly after (behind) the entry at this index.
    after: usize,
    /// The top of the non-topmost band (`HWND_TOP`): nothing better to sit
    /// behind. Every topmost window - including a topmost foreground app -
    /// stays above it.
    top,
};

/// The rule, in order:
///
///   1. Behind our frontmost NON-topmost window. Ours is where the user will
///      look for it, and sitting behind it is below whatever app is in front
///      of Ghoztty too. A topmost window of ours (`float-on-top`) is skipped:
///      inserting after a topmost window would carry the new one into the
///      topmost band and over the user's app.
///   2. No such window: behind the foreground window, so the user's app stays
///      in front - unless that window is topmost, which the top of the normal
///      band is already behind.
///   3. Otherwise the top of the normal band.
pub fn place(z_order: []const Entry) Placement {
    for (z_order, 0..) |e, i| {
        if (e.ours and !e.topmost) return .{ .after = i };
    }
    for (z_order, 0..) |e, i| {
        if (e.foreground and !e.topmost) return .{ .after = i };
    }
    return .top;
}

const testing = std.testing;

const other: Entry = .{ .ours = false, .topmost = false, .foreground = false };
const user_app: Entry = .{ .ours = false, .topmost = false, .foreground = true };
const ghoztty: Entry = .{ .ours = true, .topmost = false, .foreground = false };

test "behind our frontmost window, even when the user's app is in front of it" {
    try testing.expectEqual(Placement{ .after = 2 }, place(&.{ user_app, other, ghoztty, ghoztty }));
}

test "behind our window when the user is typing in it" {
    var focused = ghoztty;
    focused.foreground = true;
    try testing.expectEqual(Placement{ .after = 0 }, place(&.{ focused, ghoztty, other }));
}

test "a float-on-top window of ours is skipped, never inserted after" {
    var floating = ghoztty;
    floating.topmost = true;
    try testing.expectEqual(Placement{ .after = 2 }, place(&.{ floating, user_app, ghoztty }));
    // ...and with nothing else of ours, the user's app is what we sit behind.
    try testing.expectEqual(Placement{ .after = 1 }, place(&.{ floating, user_app, other }));
}

test "no window of ours: behind the app the user is in" {
    try testing.expectEqual(Placement{ .after = 1 }, place(&.{ other, user_app, other }));
}

test "a topmost foreground app, or none at all: the top of the normal band" {
    var pinned = user_app;
    pinned.topmost = true;
    try testing.expectEqual(Placement.top, place(&.{ pinned, other }));
    try testing.expectEqual(Placement.top, place(&.{ other, other }));
    try testing.expectEqual(Placement.top, place(&.{}));
}
