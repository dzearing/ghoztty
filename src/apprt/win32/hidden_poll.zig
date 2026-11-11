//! Pure logic for a poll that pauses while nobody can see it (T2913, port of
//! Mac 68a8344f0 `ViewerView.startWatchingDiff` / `catchUpDiffIfShown`). No
//! OS imports, so its unit tests run in every app-runtime lane.
//!
//! A `git-status:` viewer pane re-runs git every two seconds to follow the
//! working tree. In a window that is minimized or covered, or a tab nobody is
//! looking at, that is a process spawn every two seconds whose answer nobody
//! can read. So a tick that lands while the pane is hidden is SKIPPED and
//! remembered, and the pane asks once - straight away - when it shows again,
//! so what was changed meanwhile is on screen the moment it is, not one
//! interval later.
//!
//! Animated images need nothing from here: the viewer draws them in WebView2,
//! and a hidden pane's controller is told `IsVisible = false`, which stops the
//! page producing frames - a GIF holds its frame and goes on when shown.

const std = @import("std");

pub const Gate = struct {
    /// A tick was skipped while hidden: the pane owes one catch-up.
    missed: bool = false,

    /// The poll timer fired. True means ask now; false means the pane is
    /// hidden and the tick was skipped (and remembered).
    pub fn tick(self: *Gate, shown: bool) bool {
        if (!shown) {
            self.missed = true;
            return false;
        }
        self.missed = false;
        return true;
    }

    /// The pane was shown. True means it missed a tick while hidden and
    /// should ask once now; the debt is paid either way.
    pub fn reveal(self: *Gate) bool {
        const owed = self.missed;
        self.missed = false;
        return owed;
    }

    /// The pane stopped polling (navigated away, or to a fixed diff): a debt
    /// from the old location must not fire a catch-up for the new one.
    pub fn reset(self: *Gate) void {
        self.missed = false;
    }
};

const testing = std.testing;

test "hidden_poll: a shown pane polls on every tick and owes nothing" {
    var g: Gate = .{};
    try testing.expect(g.tick(true));
    try testing.expect(g.tick(true));
    try testing.expect(!g.reveal());
}

test "hidden_poll: a hidden pane skips its ticks and catches up once when shown" {
    var g: Gate = .{};
    try testing.expect(!g.tick(false));
    try testing.expect(!g.tick(false));
    try testing.expect(!g.tick(false));
    // One catch-up, however many ticks were skipped.
    try testing.expect(g.reveal());
    try testing.expect(!g.reveal());
}

test "hidden_poll: a reveal with no skipped tick asks nothing" {
    // Hidden and shown again between two ticks: nothing was missed, so the
    // reveal must not spend a git run the next tick is about to spend anyway.
    var g: Gate = .{};
    try testing.expect(g.tick(true));
    try testing.expect(!g.reveal());
}

test "hidden_poll: a shown tick pays a debt the reveal never collected" {
    var g: Gate = .{};
    try testing.expect(!g.tick(false));
    try testing.expect(g.tick(true));
    try testing.expect(!g.reveal());
}

test "hidden_poll: reset drops a debt from a location the pane left" {
    var g: Gate = .{};
    try testing.expect(!g.tick(false));
    g.reset();
    try testing.expect(!g.reveal());
}
