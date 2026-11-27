//! How a GTK pane drag's live drop preview is drawn (T3708, Linux L11b5b).
//! Pure - no GTK - so these tests run in every app-runtime lane, the
//! `pane_ghost_rules.zig` pattern.
//!
//! WHERE the preview goes is win32's `drop_highlight.forTarget`, unchanged:
//! the half a split takes, half the area for a top-level insert, the landing
//! rect of a divider insert, and the centre box that means a swap - the rect
//! the pane will actually occupy, from the same geometry the release
//! commits with (Mac `PaneDropFeedbackView`, `SplitDropFill`,
//! `SwapDropBox`). This module answers the rest: which CSS classes paint it
//! (a filled area with a seam where the new divider runs, or a swap box with
//! a glyph), and where that rect sits as a widget inside the split area.

const std = @import("std");
const testing = std.testing;
const drop_highlight = @import("../win32/drop_highlight.zig");
const pane_drop = @import("../win32/pane_drop.zig");

pub const Highlight = drop_highlight.Highlight;
pub const Rect = pane_drop.Rect;

/// Every class `look` may set, so a new look can clear the last one.
pub const classes = [_][:0]const u8{
    fill_class,       swap_class,
    "seam-left",      "seam-right",
    "seam-top",       "seam-bottom",
    "seams-sides",    "seams-ends",
};

pub const fill_class: [:0]const u8 = "pane-drop-fill";
pub const swap_class: [:0]const u8 = "pane-drop-swap";

/// The swap box's glyph (the Mac's ⇄).
pub const swap_glyph: [:0]const u8 = "\u{21C4}";

pub const Look = struct {
    /// `pane-drop-fill` (split, top-level, divider insert) or
    /// `pane-drop-swap`.
    kind: [:0]const u8,
    /// The edge or edges the new divider(s) run along, or null for a swap.
    seam: ?[:0]const u8,
    /// Whether the swap glyph shows.
    glyph: bool,
};

/// The paint for `hl`, or null for a kind a split area never draws (a new
/// tab's caret is the tab bar's, a new window's frame and the sidebar's
/// carets are elsewhere).
pub fn look(hl: Highlight) ?Look {
    return switch (hl.kind) {
        .split, .top_level => .{ .kind = fill_class, .seam = seamClass(hl.seam), .glyph = false },
        .insert => .{
            .kind = fill_class,
            // A left|right divider's gap is seamed down its sides.
            .seam = if (hl.seams) |d| switch (d) {
                .horizontal => "seams-sides",
                .vertical => "seams-ends",
            } else null,
            .glyph = false,
        },
        .swap => .{ .kind = swap_class, .seam = null, .glyph = true },
        .new_tab, .new_window, .stash, .stash_slot, .reorder, .sidebar_order => null,
    };
}

fn seamClass(side: ?pane_drop.Side) ?[:0]const u8 {
    const s = side orelse return null;
    return switch (s) {
        .left => "seam-left",
        .right => "seam-right",
        .up => "seam-top",
        .down => "seam-bottom",
    };
}

/// A widget's place in the split area: its margins from the top-left and
/// its size.
pub const Place = struct { x: c_int, y: c_int, w: c_int, h: c_int };

/// Where `rect` (split-area coordinates) sits as a widget in an area of
/// `area_w` x `area_h`: clipped to the area, since an overlay child that
/// overhangs its parent pushes the parent's size instead of being cut. Null
/// when nothing of it is inside.
pub fn place(rect: Rect, area_w: c_int, area_h: c_int) ?Place {
    const l = @max(rect.left, 0);
    const t = @max(rect.top, 0);
    const r = @min(rect.right, area_w);
    const b = @min(rect.bottom, area_h);
    if (r <= l or b <= t) return null;
    return .{ .x = l, .y = t, .w = r - l, .h = b - t };
}

// -- tests ----------------------------------------------------------------

const area: Rect = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
const pane_a: Rect = .{ .left = 0, .top = 0, .right = 400, .bottom = 600 };
const pane_b: Rect = .{ .left = 400, .top = 0, .right = 800, .bottom = 600 };
const panes = [_]pane_drop.PaneRect{
    .{ .id = "AAAAAAAA-0000-4000-8000-00000000000A", .rect = pane_a },
    .{ .id = "BBBBBBBB-0000-4000-8000-00000000000B", .rect = pane_b },
};
const ctx: drop_highlight.Context = .{ .window = 1, .content_rect = area, .pane_rects = &panes };

test "T3708: a split previews the half of the pane it takes, seamed toward the middle" {
    const hl = drop_highlight.forTarget(.{ .split = .{ .window = 1, .pane = panes[1].id, .side = .down } }, ctx).?;
    try testing.expectEqual(Rect{ .left = 400, .top = 300, .right = 800, .bottom = 600 }, hl.rect);
    const l = look(hl).?;
    try testing.expectEqualStrings(fill_class, l.kind);
    try testing.expectEqualStrings("seam-top", l.seam.?);
    try testing.expect(!l.glyph);
}

test "T3708: a swap previews the pane's centre box, with the glyph" {
    const hl = drop_highlight.forTarget(.{ .swap = .{ .window = 1, .pane = panes[1].id } }, ctx).?;
    // Inside pane b, centred on it, smaller than it.
    try testing.expect(hl.rect.left > pane_b.left and hl.rect.right < pane_b.right);
    try testing.expectEqual(@divFloor(pane_b.left + pane_b.right, 2), @divFloor(hl.rect.left + hl.rect.right, 2));
    const l = look(hl).?;
    try testing.expectEqualStrings(swap_class, l.kind);
    try testing.expect(l.seam == null);
    try testing.expect(l.glyph);
}

test "T3708: a top-level insert previews half the whole area" {
    const hl = drop_highlight.forTarget(.{ .top_level = .{ .window = 1, .side = .left } }, ctx).?;
    try testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 400, .bottom = 600 }, hl.rect);
    try testing.expectEqualStrings("seam-right", look(hl).?.seam.?);
}

test "T3708: a divider insert is seamed on its divider's axis" {
    const landing: Rect = .{ .left = 300, .top = 0, .right = 500, .bottom = 600 };
    const hl = drop_highlight.forTarget(.{ .insert = .{
        .window = 1,
        .layout = .horizontal,
        .before = &.{panes[0].id},
        .after = &.{panes[1].id},
        .landing = landing,
    } }, ctx).?;
    try testing.expectEqual(landing, hl.rect);
    try testing.expectEqualStrings("seams-sides", look(hl).?.seam.?);
}

test "T3708: kinds drawn outside the split area have no look here" {
    try testing.expect(look(.{ .rect = area, .kind = .new_tab }) == null);
    try testing.expect(look(.{ .rect = area, .kind = .new_window }) == null);
    try testing.expect(look(.{ .rect = area, .kind = .stash }) == null);
}

test "T3708: a preview never overhangs the area it is drawn in" {
    try testing.expectEqual(Place{ .x = 400, .y = 300, .w = 400, .h = 300 }, place(.{ .left = 400, .top = 300, .right = 800, .bottom = 600 }, 800, 600).?);
    try testing.expectEqual(Place{ .x = 0, .y = 0, .w = 10, .h = 600 }, place(.{ .left = -5, .top = -1, .right = 10, .bottom = 700 }, 800, 600).?);
    try testing.expect(place(.{ .left = 900, .top = 0, .right = 950, .bottom = 10 }, 800, 600) == null);
    try testing.expect(place(.{ .left = 10, .top = 10, .right = 10, .bottom = 20 }, 800, 600) == null);
}
