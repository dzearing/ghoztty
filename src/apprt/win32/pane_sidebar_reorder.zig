//! The pane sidebar's reorder motion (T2304; Mac e77422577 + 543489bca,
//! `PaneSidebarShift`, `PaneSidebarRowDrag`, `slideIndices` in
//! PaneSidebarView.swift / PaneSidebarRow.swift).
//!
//! While a pane is dragged over a sidebar the rows make room: the dragged
//! row is lifted out, leaving its gap, and the rows it passes slide by a
//! row's height to open one where it would land (`pane_sidebar_order.shift`),
//! each slide a short bounded animation. The list, the tray's header (its
//! hairline and caption) and the tray are ONE sequence for that, so a row
//! crossing between the list and the tray slides the header with the rows
//! between. Nothing slides once the drag ends: the drop re-lays the list out
//! where the rows were already drawn.
//!
//! A row dragged from its own sidebar is the row itself: it follows the
//! pointer up and down only, kept inside the bar, over a solid backing with
//! a shadow so it reads as on top; let go, it glides to where it landed and
//! the list draws it again.
//!
//! Pure: indices and pixels in, indices and pixels out.

const std = @import("std");
const order = @import("pane_sidebar_order.zig");
const transition = @import("pane_sidebar_transition.zig");

/// A row sliding to make room (Mac `PaneSidebarShift.animation`, 0.2 s on
/// `.timingCurve(0.2, 0.8, 0.2, 1)`).
pub const shift_ms: u64 = 200;
/// The dragged row gliding from the pointer to where it landed (Mac
/// `PaneSidebarRowDrag.settleDuration`, 0.22 s on the same curve).
pub const settle_ms: u64 = 220;
/// The frame cadence while anything here moves: a row's height in 200 ms
/// wants every display frame.
pub const frame_ms: u32 = transition.frame_ms;

/// The held row's lift (Mac: `scaleEffect(1.04)`, a solid backing at 0.92
/// of the window background with 0.06 of the ink over it, and a shadow of
/// radius 6 pt, 3 pt down, at 0.3 black).
pub const lift_scale: f32 = 1.04;
pub const backing_ink: f32 = 0.06;
pub const shadow_radius_dip: f32 = 6;
pub const shadow_y_dip: f32 = 3;
pub const shadow_peak: f64 = 0.3;

/// Where the dragged row is in a sidebar's one sequence - the list, the
/// tray's header, then the tray - and where it would land, of the sequence
/// without it. Either is null: from elsewhere, or landing elsewhere.
pub const Slide = struct {
    source: ?usize,
    target: ?usize,

    /// How many rows item `index` of the sequence slides (Mac
    /// `PaneSidebarOrder.shift`).
    pub fn rows(self: Slide, index: usize) i32 {
        return order.shift(index, self.source, self.target);
    }
};

/// The slide for a drag over this window's sidebar (Mac `slideIndices`), or
/// null when it would land somewhere else - the rows then stay put.
///
/// `list_count` is the list's rows, the dragged one included; `in_list` /
/// `in_tray` the dragged row's index in the list or the tray (null: it is not
/// there); `list_target` the list index it would land at (of the list without
/// it), `tray_target` the tray index (of the tray without it).
pub fn slide(
    list_count: usize,
    in_list: ?usize,
    in_tray: ?usize,
    list_target: ?usize,
    tray_target: ?usize,
) ?Slide {
    if (list_target == null and tray_target == null) return null;
    const source: ?usize = if (in_list) |i| i else if (in_tray) |t| list_count + 1 + t else null;
    const without = list_count - @intFromBool(in_list != null);
    const target: ?usize = if (list_target) |i| i else if (tray_target) |t| without + 1 + t else null;
    return .{ .source = source, .target = target };
}

/// Where a tray item - null for the header, else a stashed row's index - is
/// in the sequence (Mac `trayIndex`).
pub fn trayIndex(list_count: usize, row: ?usize) usize {
    return if (row) |r| list_count + 1 + r else list_count;
}

/// A tray drop's index as the resolver counts it - among every stashed row,
/// the dragged one included when it is stashed - as an index of the tray
/// WITHOUT the dragged row, the way `slide` reads it.
pub fn trayTargetWithout(index: usize, in_tray: ?usize) usize {
    if (in_tray) |s| if (index > s) return index - 1;
    return index;
}

/// One value easing toward where it is going, from wherever it was when it
/// was last sent somewhere: a row's slide offset, in pixels.
pub const Tween = struct {
    from: f64 = 0,
    to: f64 = 0,
    start_ms: u64 = 0,
    ms: u64 = shift_ms,

    pub fn at(self: Tween, now_ms: u64) f64 {
        const p = transition.progress(now_ms -| self.start_ms, self.ms);
        return self.from + (self.to - self.from) * p;
    }

    pub fn done(self: Tween, now_ms: u64) bool {
        return self.from == self.to or now_ms -| self.start_ms >= self.ms;
    }

    /// Send it to `to`, starting from where it is now. Unchanged when it is
    /// already going there, so a pointer resting on one target does not
    /// restart the motion on every move. `animate` false: there at once.
    pub fn retarget(self: *Tween, to: f64, now_ms: u64, animate: bool) void {
        if (self.to == to and (animate or self.done(now_ms))) return;
        self.from = if (animate) self.at(now_ms) else to;
        self.to = to;
        self.start_ms = now_ms;
    }
};

/// The held row's top while it follows the pointer (Mac `ghost`): its laid
/// out top moved by how far the pointer has travelled since the press, up
/// or down only, and kept inside `lo..hi` (the bar) whole.
pub fn heldTop(laid_top: i32, dy: i32, height: i32, lo: i32, hi: i32) i32 {
    const top = laid_top + dy;
    const max = @max(lo, hi - height);
    return std.math.clamp(top, lo, max);
}

/// The held row gliding from `from` to `to` (its laid-out top where it
/// landed), `elapsed_ms` into the settle.
pub fn settleTop(from: i32, to: i32, elapsed_ms: u64) i32 {
    const p = transition.progress(elapsed_ms, settle_ms);
    const f: f64 = @floatFromInt(from);
    const t: f64 = @floatFromInt(to);
    return @intFromFloat(@round(f + (t - f) * p));
}

/// How far `r` grows on each side to be `lift_scale` of its size.
pub fn liftInset(w: i32, h: i32) struct { x: i32, y: i32 } {
    const g = lift_scale - 1;
    return .{
        .x = @intFromFloat(@round(@as(f32, @floatFromInt(w)) * g / 2)),
        .y = @intFromFloat(@round(@as(f32, @floatFromInt(h)) * g / 2)),
    };
}

/// The held row's shadow at distance `d` (pixels, 0 inside) from its rounded
/// edge, for a blur `radius` pixels wide: `shadow_peak` at the edge, fading
/// smoothly to nothing at `radius`.
pub fn shadowAlpha(d: f64, radius: f64) f64 {
    if (d <= 0) return shadow_peak;
    if (radius <= 0 or d >= radius) return 0;
    const u = 1 - d / radius;
    return shadow_peak * u * u;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "pane_sidebar_reorder: no slide unless the drag would land in this sidebar" {
    try testing.expect(slide(3, 0, null, null, null) == null);
}

test "pane_sidebar_reorder: a list row moved down the list" {
    // Row 0 of three, landing at 2 of the list without it: rows 1 and 2
    // close its gap, the header and the tray stay.
    const s = slide(3, 0, null, 2, null).?;
    try testing.expectEqual(@as(?usize, 0), s.source);
    try testing.expectEqual(@as(?usize, 2), s.target);
    try testing.expectEqual(@as(i32, -1), s.rows(1));
    try testing.expectEqual(@as(i32, -1), s.rows(2));
    try testing.expectEqual(@as(i32, 0), s.rows(trayIndex(3, null)));
}

test "pane_sidebar_reorder: a list row dragged into the tray slides the header up with the rows" {
    // Row 1 of three into the tray at 0: list row 2 and the header close the
    // gap, and the tray's row 0 opens one where it lands.
    const s = slide(3, 1, null, null, 0).?;
    try testing.expectEqual(@as(?usize, 1), s.source);
    try testing.expectEqual(@as(?usize, 3), s.target);
    try testing.expectEqual(@as(i32, 0), s.rows(0));
    try testing.expectEqual(@as(i32, -1), s.rows(2));
    try testing.expectEqual(@as(i32, -1), s.rows(trayIndex(3, null)));
    try testing.expectEqual(@as(i32, 0), s.rows(trayIndex(3, 0)));
}

test "pane_sidebar_reorder: a stashed row dragged up into the list" {
    // Tray row 0, two list rows, landing at list index 1: list row 1 and the
    // header open a gap, and tray row 1 - pushed down by it, and closing the
    // dragged row's gap - stays where it is.
    const s = slide(2, null, 0, 1, null).?;
    try testing.expectEqual(@as(?usize, 3), s.source);
    try testing.expectEqual(@as(?usize, 1), s.target);
    try testing.expectEqual(@as(i32, 0), s.rows(0));
    try testing.expectEqual(@as(i32, 1), s.rows(1));
    try testing.expectEqual(@as(i32, 1), s.rows(trayIndex(2, null)));
    try testing.expectEqual(@as(i32, 0), s.rows(trayIndex(2, 1)));
}

test "pane_sidebar_reorder: a drag from the grid of another window only opens a gap" {
    const s = slide(2, null, null, 0, null).?;
    try testing.expectEqual(@as(?usize, null), s.source);
    try testing.expectEqual(@as(i32, 1), s.rows(0));
    try testing.expectEqual(@as(i32, 1), s.rows(1));
}

test "pane_sidebar_reorder: a tray index counts the tray without the dragged row" {
    try testing.expectEqual(@as(usize, 0), trayTargetWithout(0, 1));
    try testing.expectEqual(@as(usize, 1), trayTargetWithout(1, 1));
    try testing.expectEqual(@as(usize, 1), trayTargetWithout(2, 1));
    try testing.expectEqual(@as(usize, 2), trayTargetWithout(2, null));
}

test "pane_sidebar_reorder: a tween eases from where it is, and holds a repeated target" {
    var t: Tween = .{};
    t.retarget(38, 1000, true);
    try testing.expectEqual(@as(f64, 0), t.at(1000));
    try testing.expectEqual(@as(f64, 38), t.at(1000 + shift_ms));
    const mid = t.at(1100);
    try testing.expect(mid > 19 and mid < 38); // a strong ease-out: past half
    // The same target again does not restart it.
    t.retarget(38, 1100, true);
    try testing.expectEqual(@as(u64, 1000), t.start_ms);
    // Turned back mid-way: from where it is now.
    t.retarget(0, 1100, true);
    try testing.expectApproxEqAbs(mid, t.at(1100), 1e-9);
    try testing.expect(!t.done(1100));
    try testing.expect(t.done(1100 + shift_ms));
    // Without motion it is there at once.
    t.retarget(-38, 1150, false);
    try testing.expectEqual(@as(f64, -38), t.at(1150));
    try testing.expect(t.done(1150));
}

test "pane_sidebar_reorder: the held row follows the pointer inside the bar" {
    try testing.expectEqual(@as(i32, 130), heldTop(100, 30, 38, 0, 400));
    // Not above the bar's top, nor below its bottom.
    try testing.expectEqual(@as(i32, 0), heldTop(100, -500, 38, 0, 400));
    try testing.expectEqual(@as(i32, 362), heldTop(100, 500, 38, 0, 400));
    // A bar shorter than the row pins it to the top.
    try testing.expectEqual(@as(i32, 0), heldTop(10, 5, 38, 0, 20));
}

test "pane_sidebar_reorder: the settle glides from the pointer to the landed place" {
    try testing.expectEqual(@as(i32, 200), settleTop(200, 50, 0));
    try testing.expectEqual(@as(i32, 50), settleTop(200, 50, settle_ms));
    const mid = settleTop(200, 50, settle_ms / 2);
    try testing.expect(mid < 125 and mid > 50);
}

test "pane_sidebar_reorder: the lift and the shadow" {
    const g = liftInset(200, 38);
    try testing.expectEqual(@as(i32, 4), g.x);
    try testing.expectEqual(@as(i32, 1), g.y);
    try testing.expectEqual(shadow_peak, shadowAlpha(0, 6));
    try testing.expectEqual(@as(f64, 0), shadowAlpha(6, 6));
    try testing.expect(shadowAlpha(3, 6) > 0 and shadowAlpha(3, 6) < shadow_peak);
}
