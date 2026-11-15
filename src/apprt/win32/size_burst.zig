//! A burst of window-size changes outside the modal size loop (T2986).
//!
//! A window-edge drag paints the desk on a canvas that holds still under it
//! (`PaneDesk.liveResize`, T2577), armed from `WM_ENTERSIZEMOVE`. Nothing else
//! raises that: a `SetWindowPos` loop (a script, a tiling tool, an animated
//! snap), a maximize, a restore. Each of those steps used to take a whole new
//! desk - the gradient rendered and upscaled, the compose bitmap recreated, a
//! full compose - about 4 ms a step, which a 50 ms resize loop pays ~110 times
//! over 8 s.
//!
//! So the canvas is armed on a BURST too: the second size change that lands
//! within `window_ms` of the one before it. The first is left alone on
//! purpose - a single maximize or restore is one step, and arming it would
//! make it lay the desk out twice (once on the canvas, once at the settle).
//! The canvas then goes when no size change has come for `quiet_ms`, and the
//! settle repaint lays the desk out for the window again, exactly as the end
//! of an edge drag does.
//!
//! Pure, so the rule is tested without a window.

const std = @import("std");
const testing = std.testing;

/// Two size changes this close together are one burst. A resize loop steps
/// every few to few-dozen ms; two unrelated resizes (a maximize, then a
/// restore by hand) are seconds apart.
pub const window_ms: i64 = 200;

/// How long after a burst's last size change the canvas goes and the desk is
/// laid out for the window again. Long enough that a loop stepping every
/// 50 ms (perf-baseline's resize phase) never reaches it mid-burst.
pub const quiet_ms: u32 = 150;

pub const Step = enum {
    /// Not a burst (yet): the step takes the exact size, as it always did.
    none,
    /// This step starts a burst: arm the canvas, and the quiet timer.
    arm,
    /// A burst already armed goes on: re-arm the quiet timer only.
    extend,
};

pub const State = struct {
    /// When the last size change landed, and the client size it landed at.
    last_ms: ?i64 = null,
    last_w: i32 = 0,
    last_h: i32 = 0,
    /// The canvas is armed for a burst (and the quiet timer is running).
    armed: bool = false,
    /// Size changes since the burst armed, and the desk generation it armed
    /// at, for the `GHOZTTY_PERF` report.
    steps: u32 = 0,
    gen_at_arm: u32 = 0,

    /// A `WM_SIZE` at client size `w` x `h`, `now_ms` on a monotonic clock.
    /// `in_size_loop`: a modal size loop owns the canvas, so this is not ours.
    pub fn step(self: *State, now_ms: i64, w: i32, h: i32, in_size_loop: bool) Step {
        const same = self.last_ms != null and w == self.last_w and h == self.last_h;
        if (same) return .none;
        const prev = self.last_ms;
        self.last_ms = now_ms;
        self.last_w = w;
        self.last_h = h;
        if (in_size_loop) return .none;
        if (self.armed) {
            self.steps +|= 1;
            return .extend;
        }
        const p = prev orelse return .none;
        if (now_ms - p > window_ms) return .none;
        self.armed = true;
        self.steps = 1;
        return .arm;
    }

    /// The quiet timer fired (or a modal size loop took the canvas over):
    /// returns whether a burst was armed, and forgets it.
    pub fn settle(self: *State) bool {
        const was = self.armed;
        self.armed = false;
        self.steps = 0;
        return was;
    }
};

test "T2986: a single resize is not a burst" {
    var s: State = .{};
    try testing.expectEqual(Step.none, s.step(1000, 800, 600, false));
    // A maximize seconds later is not one either.
    try testing.expectEqual(Step.none, s.step(4000, 1920, 1040, false));
    try testing.expect(!s.settle());
}

test "T2986: the second change within the window arms; later ones extend" {
    var s: State = .{};
    try testing.expectEqual(Step.none, s.step(1000, 800, 600, false));
    try testing.expectEqual(Step.arm, s.step(1050, 810, 600, false));
    try testing.expectEqual(Step.extend, s.step(1100, 820, 600, false));
    // Even a slow step extends an armed burst: the quiet timer decides its end.
    try testing.expectEqual(Step.extend, s.step(1400, 830, 600, false));
    try testing.expectEqual(@as(u32, 3), s.steps);
    try testing.expect(s.settle());
    try testing.expect(!s.armed);
    // After the settle, it takes two close changes again.
    try testing.expectEqual(Step.none, s.step(5000, 840, 600, false));
    try testing.expectEqual(Step.arm, s.step(5010, 850, 600, false));
}

test "T2986: a change to the same size is not a step" {
    var s: State = .{};
    try testing.expectEqual(Step.none, s.step(1000, 800, 600, false));
    try testing.expectEqual(Step.none, s.step(1010, 800, 600, false));
    try testing.expectEqual(Step.arm, s.step(1020, 801, 600, false));
    try testing.expectEqual(Step.none, s.step(1030, 801, 600, false));
    try testing.expectEqual(@as(u32, 1), s.steps);
}

test "T2986: the modal size loop owns its own steps" {
    var s: State = .{};
    try testing.expectEqual(Step.none, s.step(1000, 800, 600, true));
    try testing.expectEqual(Step.none, s.step(1010, 810, 600, true));
    try testing.expect(!s.armed);
    // Its last step still counts as the one before the next change.
    try testing.expectEqual(Step.arm, s.step(1020, 820, 600, false));
}
