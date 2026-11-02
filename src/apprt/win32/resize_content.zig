//! What a terminal does with its content while the window edge is dragged
//! (T2609, shipped by T2623).
//!
//! T2609's A/B (ReleaseFast) found that a third or more of every edge-drag
//! step was the wait for each terminal to draw a frame at its new size, and
//! that a step with the content held still cost exactly what a window with no
//! content did. So the default is the held arm: under an edge drag every
//! terminal keeps its grid (`Surface.holdResize`, the same hold a divider drag
//! takes - `drag_hold.zig`), its window still follows the layout, the renderer
//! draws the grid it has cut by the window with its own background past it,
//! and nobody waits for a frame. The grid - reflow and PTY resize - takes the
//! new size once when the hand rests `drag_hold.quiet_ms`, and once at
//! release.
//!
//! `GHOZTTY_RESIZE_NO_CONTENT` keeps the other arms for A/B runs:
//!
//!   unset   - held (the default).
//!   `0`     - every step resizes the content: grid reflow, renderer
//!             viewport, PTY resize, and a wait for a frame at the new size.
//!             What shipped before T2623.
//!   `empty` - the floor: a pane's resize does nothing at all under the drag,
//!             not even the strip fill, so a step costs only the layout of
//!             the windows and the chrome. The size still lands at the end.
//!   other   - held.
//!
//! Pure, so the parse and the rule are tested without a window.

const std = @import("std");
const testing = std.testing;

pub const Mode = enum { content, held, empty };

pub const env_name = "GHOZTTY_RESIZE_NO_CONTENT";

pub fn parse(value: ?[]const u8) Mode {
    const v = value orelse return .held;
    if (v.len == 0) return .held;
    if (std.ascii.eqlIgnoreCase(v, "empty")) return .empty;
    if (std.mem.eql(u8, v, "0")) return .content;
    return .held;
}

/// What a pane's `WM_SIZE` does now.
pub const Action = enum {
    /// Resize the content (under a held grid, that is the renderer's view
    /// only; the window's drag hold decides the grid).
    apply,
    /// Keep the size for later and do nothing else (`empty`).
    skip,
};

pub fn action(mode: Mode, in_size_loop: bool) Action {
    if (in_size_loop and mode == .empty) return .skip;
    return .apply;
}

/// Whether an edge drag holds the terminals' grids: the held arm, inside a
/// size loop that has changed the window's size (a title-bar move is a size
/// loop too, and holds nothing).
pub fn edgeHolds(mode: Mode, sizing: bool) bool {
    return mode == .held and sizing;
}

test "unset and anything but 0 or empty hold the content" {
    try testing.expectEqual(Mode.held, parse(null));
    try testing.expectEqual(Mode.held, parse(""));
    try testing.expectEqual(Mode.content, parse("0"));
    try testing.expectEqual(Mode.held, parse("1"));
    try testing.expectEqual(Mode.held, parse("yes"));
    try testing.expectEqual(Mode.empty, parse("empty"));
    try testing.expectEqual(Mode.empty, parse("EMPTY"));
}

test "only the empty arm skips a step, and only inside the size loop" {
    try testing.expectEqual(Action.apply, action(.held, true));
    try testing.expectEqual(Action.apply, action(.content, true));
    try testing.expectEqual(Action.skip, action(.empty, true));
    try testing.expectEqual(Action.apply, action(.empty, false));
}

test "only the held arm holds, and only while the edge is sizing the window" {
    try testing.expect(edgeHolds(.held, true));
    try testing.expect(!edgeHolds(.held, false));
    try testing.expect(!edgeHolds(.content, true));
    try testing.expect(!edgeHolds(.empty, true));
}

test "T2623: an edge drag resizes each terminal once per pause and once at release" {
    // A model of the window's rule: every step re-arms the rest clock and the
    // pass holds the grid; a rest of `quiet` ms releases it; the release lets
    // go. The grid takes a size only when it is released with a size pending.
    const drag_hold = @import("drag_hold.zig");
    const quiet = drag_hold.quiet_ms;
    const Model = struct {
        grid: u32 = 80,
        view: u32 = 80,
        held: bool = false,
        rested: bool = false,
        resizes: u32 = 0,
        fn release(m: *@This()) void {
            m.held = false;
            if (m.grid != m.view) {
                m.grid = m.view;
                m.resizes += 1;
            }
        }
        fn step(m: *@This(), cols: u32) void {
            m.rested = false;
            if (drag_hold.wanted(.{ .gesturing = true, .glide_resizing = false, .quiet = m.rested })) m.held = true;
            m.view = cols;
            if (!m.held) m.release();
        }
    };
    var m: Model = .{};
    // 30 steps 8 ms apart: never quiet.
    var t: u32 = 0;
    var cols: u32 = 80;
    while (t < 240) : (t += 8) {
        cols += 1;
        m.step(cols);
        try testing.expect(8 < quiet);
    }
    try testing.expectEqual(@as(u32, 0), m.resizes);
    try testing.expectEqual(@as(u32, 80), m.grid);
    // The hand rests: one resize, to where it rests.
    m.rested = true;
    m.release();
    try testing.expectEqual(@as(u32, 1), m.resizes);
    try testing.expectEqual(cols, m.grid);
    // More steps, then the release.
    for (0..20) |_| {
        cols -= 1;
        m.step(cols);
    }
    m.release();
    try testing.expectEqual(@as(u32, 2), m.resizes);
    try testing.expectEqual(cols, m.grid);
    // A release with nothing pending after a rest resizes nothing more.
    m.release();
    try testing.expectEqual(@as(u32, 2), m.resizes);
}
