//! Stacked panes on GTK, the pure half (T3567, Linux L11e;
//! docs/reference/stacked-panes.md).
//!
//! A split tab on GTK is ONE container, the stage, whose children the shared
//! stacked-panes engine places: win32's `pane_stack_layout` /
//! `pane_stack_grid` / `pane_stack_state` / `stack_drag`, which are Mac's
//! `PaneLayout` / `PaneStackState` / `RowDrag` port, pure and with no OS
//! imports. So GTK and win32 compute the same layout from the same tree: a
//! pane is never narrower or shorter than the configured minimum, a row that
//! cannot fit becomes a run on show plus minimized strips, and focusing a pane
//! brings it forward.
//!
//! What is decided here, with no GTK imports so the tests run in the `none`
//! lane:
//!
//!   * where the grid sits in the stage, and where a card is allocated given
//!     the CSS margin the elevated style puts round it;
//!   * the face a strip shows (its tab, less the part tucked under the strip
//!     in front of it), and how its label is turned to run down a vertical
//!     strip;
//!   * the cursor a gutter shows.
const std = @import("std");
const testing = std.testing;
const grid = @import("../win32/pane_stack_grid.zig");
const layout = @import("../win32/pane_stack_layout.zig");

pub const PxRect = grid.PxRect;
pub const Direction = layout.Direction;

/// The elevated style's card margin (`style.css` `.pane-elevated .pane-card`,
/// half of `pane_style.gutter`): GTK takes it out of whatever the card is
/// allocated, so a card is allocated that much larger than the engine's frame
/// for its visible edge to land on the frame.
pub const elevated_card_margin: i32 = 5;

/// The grid's rect in the stage. The elevated style insets it by the card
/// margin, so with the tree's own padding the edge is one whole gutter away,
/// as for a lone pane; the flat style runs edge to edge.
pub fn gridRect(stage_w: i32, stage_h: i32, elevated: bool) PxRect {
    const inset: i32 = if (elevated) elevated_card_margin else 0;
    return .{
        .left = inset,
        .top = inset,
        .right = @max(inset, stage_w - inset),
        .bottom = @max(inset, stage_h - inset),
    };
}

/// Where a card on show is allocated: its frame, grown by the CSS margin GTK
/// will take back out of it.
pub fn cardAllocation(frame: PxRect, elevated: bool) PxRect {
    const m: i32 = if (elevated) elevated_card_margin else 0;
    return .{
        .left = frame.left - m,
        .top = frame.top - m,
        .right = frame.right + m,
        .bottom = frame.bottom + m,
    };
}

/// The part of a strip that shows: its tab, less the `tuck` that reaches under
/// the strip in front of it (toward the run). Faces of neighbouring strips
/// then meet edge to edge instead of overlapping, so no paint order is needed
/// between them. `leads`: the strip lies before its run (its run side is its
/// trailing edge). `axis`: the row's direction.
pub fn stripFace(tab: PxRect, leads: bool, tuck: i32, axis: Direction) PxRect {
    var r = tab;
    const t = @max(tuck, 0);
    switch (axis) {
        .horizontal => if (leads) {
            r.right = @max(r.left, r.right - t);
        } else {
            r.left = @min(r.right, r.left + t);
        },
        .vertical => if (leads) {
            r.bottom = @max(r.top, r.bottom - t);
        } else {
            r.top = @min(r.bottom, r.top + t);
        },
    }
    return r;
}

/// How a strip's label is allocated over its face. In a row (a horizontal
/// split chain) the strip is a vertical bar and its name runs DOWN it (Mac
/// `PaneCardView.titleRect`): the label is laid out `w` x `h` = the face's
/// height x width, then rotated 90 degrees clockwise and moved to (`tx`,
/// `ty`), the face's top-right corner. In a column the strip is a horizontal
/// bar and the label sits on it as is.
pub const LabelPlacement = struct {
    w: i32,
    h: i32,
    tx: f32,
    ty: f32,
    rotate: bool,
};

pub fn labelPlacement(face: PxRect, axis: Direction) LabelPlacement {
    return switch (axis) {
        .horizontal => .{
            .w = face.height(),
            .h = face.width(),
            .tx = @floatFromInt(face.right),
            .ty = @floatFromInt(face.top),
            .rotate = true,
        },
        .vertical => .{
            .w = face.width(),
            .h = face.height(),
            .tx = @floatFromInt(face.left),
            .ty = @floatFromInt(face.top),
            .rotate = false,
        },
    };
}

/// The cursor over a gutter of a row running along `d`: a row's gutters are
/// upright, so they resize sideways.
pub fn gutterCursor(d: Direction) [:0]const u8 {
    return switch (d) {
        .horizontal => "col-resize",
        .vertical => "row-resize",
    };
}

/// A press that moved less than this is a click (Mac's 5pt drag threshold
/// for a strip): a strip clicked is brought forward, one dragged is not.
pub const click_slop: f64 = 5;

pub fn isClick(dx: f64, dy: f64) bool {
    return @abs(dx) < click_slop and @abs(dy) < click_slop;
}

test "the elevated grid sits a card margin in; flat runs edge to edge" {
    try testing.expectEqual(PxRect{ .left = 5, .top = 5, .right = 795, .bottom = 595 }, gridRect(800, 600, true));
    try testing.expectEqual(PxRect{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, gridRect(800, 600, false));
    // A stage too small for its inset is empty, never inverted.
    const tiny = gridRect(6, 6, true);
    try testing.expect(tiny.width() >= 0 and tiny.height() >= 0);
}

test "a card is allocated its frame plus the margin GTK takes back" {
    const f: PxRect = .{ .left = 10, .top = 10, .right = 400, .bottom = 300 };
    try testing.expectEqual(PxRect{ .left = 5, .top = 5, .right = 405, .bottom = 305 }, cardAllocation(f, true));
    try testing.expectEqual(f, cardAllocation(f, false));
}

test "a strip's face gives up its tuck on the run side only" {
    const tab: PxRect = .{ .left = 100, .top = 0, .right = 148, .bottom = 500 };
    // Before the run: the run is to its right.
    try testing.expectEqual(PxRect{ .left = 100, .top = 0, .right = 136, .bottom = 500 }, stripFace(tab, true, 12, .horizontal));
    // After the run: the run is to its left.
    try testing.expectEqual(PxRect{ .left = 112, .top = 0, .right = 148, .bottom = 500 }, stripFace(tab, false, 12, .horizontal));
    // A column: the run is above or below.
    const vt: PxRect = .{ .left = 0, .top = 200, .right = 500, .bottom = 248 };
    try testing.expectEqual(PxRect{ .left = 0, .top = 200, .right = 500, .bottom = 236 }, stripFace(vt, true, 12, .vertical));
    try testing.expectEqual(PxRect{ .left = 0, .top = 212, .right = 500, .bottom = 248 }, stripFace(vt, false, 12, .vertical));
    // No tuck (the strip next to the run) keeps its whole tab; a tuck past
    // the tab never inverts it.
    try testing.expectEqual(tab, stripFace(tab, true, 0, .horizontal));
    const over = stripFace(tab, false, 500, .horizontal);
    try testing.expect(over.width() == 0);
}

test "a vertical strip's label runs down it from the face's top-right corner" {
    const face: PxRect = .{ .left = 100, .top = 20, .right = 136, .bottom = 520 };
    const p = labelPlacement(face, .horizontal);
    try testing.expect(p.rotate);
    try testing.expectEqual(@as(i32, 500), p.w);
    try testing.expectEqual(@as(i32, 36), p.h);
    try testing.expectEqual(@as(f32, 136), p.tx);
    try testing.expectEqual(@as(f32, 20), p.ty);
    // Rotating (x, y) by 90 degrees clockwise is (-y, x): the label's far
    // corner (w, h) lands on the face's bottom-left, so the label covers the
    // face exactly.
    const far_x = p.tx - @as(f32, @floatFromInt(p.h));
    const far_y = p.ty + @as(f32, @floatFromInt(p.w));
    try testing.expectEqual(@as(f32, @floatFromInt(face.left)), far_x);
    try testing.expectEqual(@as(f32, @floatFromInt(face.bottom)), far_y);
}

test "a horizontal strip's label sits on it unturned" {
    const face: PxRect = .{ .left = 0, .top = 200, .right = 500, .bottom = 236 };
    const p = labelPlacement(face, .vertical);
    try testing.expect(!p.rotate);
    try testing.expectEqual(@as(i32, 500), p.w);
    try testing.expectEqual(@as(i32, 36), p.h);
    try testing.expectEqual(@as(f32, 0), p.tx);
    try testing.expectEqual(@as(f32, 200), p.ty);
}

test "gutters resize across their row; a small move is a click" {
    try testing.expectEqualStrings("col-resize", gutterCursor(.horizontal));
    try testing.expectEqualStrings("row-resize", gutterCursor(.vertical));
    try testing.expect(isClick(2, -3));
    try testing.expect(!isClick(6, 0));
    try testing.expect(!isClick(0, -5));
}
