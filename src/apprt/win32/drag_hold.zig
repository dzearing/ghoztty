//! Terminals hold their size under a drag (T2459; Mac `PaneStageView`'s
//! content freeze, `glideFreeze`).
//!
//! A divider or stack-grip drag moves the layout on every pointer step, and a
//! glide the drag starts follows it every frame. Resized each time, every
//! terminal on show would reflow and send its program a resize - a
//! clear-and-repaint for a full-screen TUI - dozens of times a drag, all of it
//! for sizes nobody stops at. So while the hand is reshaping the row each
//! terminal keeps the grid it had (`Surface.holdResize`): its window still
//! moves and sizes with its card, and the renderer draws the grid it has, cut
//! by the card. The grid takes its new size once - when the motion settles, or
//! when the hand rests for `quiet_ms` mid-drag.
//!
//! Pure, so the rule is tested without a window.

const std = @import("std");
const testing = std.testing;

/// How long the pointer rests mid-drag before the terminals take the size the
/// layout has them at: long enough that a hand in motion never reaches it
/// (pointer moves come every few ms), short enough that a pause to read the
/// pane shows it reflowed.
pub const quiet_ms: u32 = 150;

pub const Live = struct {
    /// A divider or grip drag is under way (`Window.stackGesturing`).
    gesturing: bool,
    /// A glide a drag started is still under way after it (a `resize` slide).
    glide_resizing: bool,
    /// The hand has rested `quiet_ms` since its last move.
    quiet: bool,
};

/// Whether the terminals on show hold their size now.
pub fn wanted(l: Live) bool {
    return (l.gesturing or l.glide_resizing) and !l.quiet;
}

/// Whether one pane's terminal holds: only the active tab's, and never one
/// opening out of its strip, which is presized exactly before it shows
/// (T2458).
pub fn holds(want: bool, on_active_tab: bool, unfolding: bool) bool {
    return want and on_active_tab and !unfolding;
}

/// Whether a quiet period that ran out releases the holds now. A glide still
/// catching up is motion too, so it waits for the next period.
pub fn quietReleases(gesturing: bool, glide_moving: bool) bool {
    return gesturing and !glide_moving;
}

test "a drag holds every terminal on show until the hand rests or the motion ends" {
    try testing.expect(wanted(.{ .gesturing = true, .glide_resizing = false, .quiet = false }));
    try testing.expect(wanted(.{ .gesturing = true, .glide_resizing = true, .quiet = false }));
    // The glide a drag started runs on after the release, still holding.
    try testing.expect(wanted(.{ .gesturing = false, .glide_resizing = true, .quiet = false }));
    // A rest mid-drag lets the terminals take their size.
    try testing.expect(!wanted(.{ .gesturing = true, .glide_resizing = false, .quiet = true }));
    // Nothing moving: nothing held.
    try testing.expect(!wanted(.{ .gesturing = false, .glide_resizing = false, .quiet = false }));
}

test "only the active tab's panes hold, and never one opening out of its strip" {
    try testing.expect(holds(true, true, false));
    try testing.expect(!holds(true, false, false));
    try testing.expect(!holds(true, true, true));
    try testing.expect(!holds(false, true, false));
}

test "a rest releases only once the glide has caught up" {
    try testing.expect(quietReleases(true, false));
    try testing.expect(!quietReleases(true, true));
    // After the release the glide's end releases instead.
    try testing.expect(!quietReleases(false, false));
}

test "a drag of many steps applies one size per pane per settle" {
    // A model of the hold: the size the terminal is at, the size the layout
    // reports, and how often the terminal took one.
    const Pane = struct {
        held: bool = false,
        pending: ?u32 = null,
        size: u32 = 800,
        applied: u32 = 0,
        fn report(p: *@This(), w: u32) void {
            if (w == p.size and p.pending == null) return;
            if (p.held) {
                p.pending = w;
            } else {
                p.size = w;
                p.applied += 1;
            }
        }
        fn hold(p: *@This(), on: bool) void {
            const was = p.held;
            p.held = on;
            if (was and !on) if (p.pending) |w| {
                p.pending = null;
                if (w != p.size) {
                    p.size = w;
                    p.applied += 1;
                }
            };
        }
    };
    var pane: Pane = .{};
    // 60 pointer steps, then a rest, then 40 more, then the release.
    var w: u32 = 800;
    pane.hold(holds(wanted(.{ .gesturing = true, .glide_resizing = false, .quiet = false }), true, false));
    for (0..60) |_| {
        w -= 4;
        pane.report(w);
    }
    try testing.expectEqual(@as(u32, 0), pane.applied);
    pane.hold(holds(wanted(.{ .gesturing = true, .glide_resizing = false, .quiet = true }), true, false));
    try testing.expectEqual(@as(u32, 1), pane.applied);
    try testing.expectEqual(w, pane.size);
    pane.hold(holds(wanted(.{ .gesturing = true, .glide_resizing = false, .quiet = false }), true, false));
    for (0..40) |_| {
        w += 3;
        pane.report(w);
    }
    pane.hold(holds(wanted(.{ .gesturing = false, .glide_resizing = false, .quiet = false }), true, false));
    try testing.expectEqual(@as(u32, 2), pane.applied);
    try testing.expectEqual(w, pane.size);
}
