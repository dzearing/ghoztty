//! Which client rect is a window about to take, so the panes can be laid out
//! and presented at it before the frame changes? (T2578)
//!
//! T2575 timed a window-edge drag: the frame change reaches the screen about
//! one compose after it happens, and the content presented in `WM_SIZE` lands
//! a full compose behind it, because the pass from frame change to last
//! present is about twice a 120 Hz period. Laying the panes out in
//! `WM_WINDOWPOSCHANGING` - the new rect is known and nothing has moved yet -
//! puts the last present about a millisecond before the frame change, inside
//! the same latch period, so both go up together.
//!
//! The client rect is always 0-based, but a left or top edge drag moves its
//! origin on screen: panes placed before the frame moves would be drawn at the
//! old origin and jump. So only a change that keeps the window's top-left
//! corner (a right or bottom edge drag) and grows is laid out ahead (see the
//! shrink note in `pendingClient`); anything else
//! answers null and takes the ordinary `WM_SIZE` pass alone. The borders do
//! not change size with the window, so the new client rect is the current one
//! grown by the change in the outer size. Pure, for the `none` lane.

const std = @import("std");

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    fn width(r: Rect) i32 {
        return r.right - r.left;
    }

    fn height(r: Rect) i32 {
        return r.bottom - r.top;
    }
};

/// `SWP_NOSIZE` / `SWP_NOMOVE`, restated so the rule stays free of win32.
pub const swp_nosize: u32 = 0x0001;
pub const swp_nomove: u32 = 0x0002;

pub const Input = struct {
    /// The window's outer rect now (screen).
    window: Rect,
    /// The client rect now (0-based).
    client: Rect,
    /// The `WINDOWPOS` the change asks for, after DefWindowProc's clamp.
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: u32,
    /// Inside a modal size loop: an edge drag, the one gesture this is for.
    in_size_loop: bool,
    /// Minimized now, or about to be: no layout means anything there.
    iconic: bool,
    /// Lay a shrinking change out ahead too (T2580).
    shrink: bool = false,
};

/// The client rect to lay the panes out at before the frame changes, or null
/// when this change should not be laid out ahead.
pub fn pendingClient(in: Input) ?Rect {
    if (!in.in_size_loop or in.iconic) return null;
    if (in.flags & swp_nosize != 0) return null;
    if (in.flags & swp_nomove == 0 and
        (in.x != in.window.left or in.y != in.window.top)) return null;
    const dw = in.cx - in.window.width();
    const dh = in.cy - in.window.height();
    if (dw == 0 and dh == 0) return null;
    // Growing only. Filmed on 2026-10-31 (T2578), a grow laid out ahead went
    // from 2.5 to 1.5-2.0 bad frames per step and lost all 40 flat frames: a
    // miss is clipped by the old frame and never seen. A shrink did not get
    // better (1.2 -> 1.5): its miss shows the strip the panes left, and the
    // terminal still trails the page by a step either way. Re-filmed with
    // `shrink` (T2580): the page is the surface out of step, not the
    // terminal - see the task for the timing.
    if (!in.shrink and (dw < 0 or dh < 0)) return null;
    const w = in.client.width() + dw;
    const h = in.client.height() + dh;
    if (w <= 0 or h <= 0) return null;
    return .{ .left = 0, .top = 0, .right = w, .bottom = h };
}

/// Whether the `WM_SIZE` that follows a pre-layout still has to lay the panes
/// out (T2603). `laid` is the client rect the pre-layout placed them at (null
/// when none ran, or another pass ran since); `landed` is the client rect the
/// frame change actually produced. The same rect means the panes are already
/// where this size puts them, and the window's origin did not move, so the
/// pass only has the desk to paint over the strip the old frame clipped - a
/// whole second layout pass was about a fifth of a growing step.
pub fn sizePassNeeded(laid: ?Rect, landed: Rect) bool {
    const l = laid orelse return true;
    return l.width() != landed.width() or l.height() != landed.height() or
        l.left != landed.left or l.top != landed.top;
}

const testing = std.testing;

test "sizePassNeeded: only the rect the pre-layout laid out skips the pass" {
    const r: Rect = .{ .left = 0, .top = 0, .right = 1396, .bottom = 792 };
    try testing.expect(!sizePassNeeded(r, r));
    try testing.expect(sizePassNeeded(null, r));
    var other = r;
    other.right = 1400;
    try testing.expect(sizePassNeeded(r, other));
    other = r;
    other.bottom = 790;
    try testing.expect(sizePassNeeded(r, other));
}

fn base() Input {
    return .{
        .window = .{ .left = 100, .top = 50, .right = 1500, .bottom = 850 },
        .client = .{ .left = 0, .top = 0, .right = 1384, .bottom = 792 },
        .x = 100,
        .y = 50,
        .cx = 1412,
        .cy = 800,
        .flags = 0,
        .in_size_loop = true,
        .iconic = false,
    };
}

test "right-edge grow lays out at the client grown by the same step" {
    var in = base();
    in.cx = 1412;
    const r = pendingClient(in).?;
    try testing.expectEqual(@as(i32, 1396), r.right);
    try testing.expectEqual(@as(i32, 792), r.bottom);
    try testing.expectEqual(@as(i32, 0), r.left);
}

test "a shrink, or a grow on one axis with a shrink on the other, is not laid out ahead" {
    var shrink = base();
    shrink.cx = 1388;
    try testing.expect(pendingClient(shrink) == null);
    var in = base();
    in.cx = 1412;
    in.cy = 790;
    try testing.expect(pendingClient(in) == null);
}

test "with shrink set, a right-edge shrink is laid out ahead (T2580 A/B)" {
    var in = base();
    in.cx = 1388;
    in.shrink = true;
    const r = pendingClient(in).?;
    try testing.expectEqual(@as(i32, 1372), r.right);
    try testing.expectEqual(@as(i32, 792), r.bottom);
}

test "bottom-edge grow, origin left alone with SWP_NOMOVE" {
    var in = base();
    in.cx = 1400;
    in.cy = 830;
    in.x = 0;
    in.y = 0;
    in.flags = swp_nomove;
    const r = pendingClient(in).?;
    try testing.expectEqual(@as(i32, 1384), r.right);
    try testing.expectEqual(@as(i32, 822), r.bottom);
}

test "a left or top edge drag moves the origin and is not laid out ahead" {
    var in = base();
    in.x = 112;
    in.cx = 1412;
    try testing.expect(pendingClient(in) == null);
    in = base();
    in.y = 40;
    in.cy = 810;
    try testing.expect(pendingClient(in) == null);
}

test "outside a size loop, minimized, no size, or no change: null" {
    var in = base();
    in.in_size_loop = false;
    try testing.expect(pendingClient(in) == null);
    in = base();
    in.iconic = true;
    try testing.expect(pendingClient(in) == null);
    in = base();
    in.flags = swp_nosize;
    try testing.expect(pendingClient(in) == null);
    in = base();
    in.cx = 1400;
    try testing.expect(pendingClient(in) == null);
}
