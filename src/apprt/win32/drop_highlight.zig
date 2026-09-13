//! Where the drop preview is drawn during a rearrange-mode pane drag (T1531).
//! Pure — no OS imports — so these unit tests run in every app-runtime lane,
//! the `pane_drop.zig` / `split_geometry.zig` pattern.
//!
//! The rule this module exists to keep: **the highlight is the rect the
//! dragged pane will actually occupy**, not a decoration near it. `pane_drop`
//! answers *what* a release would mean; this answers *where that lands*, from
//! the same geometry the commit will use — a split at ratio 0.5 takes half of
//! the pane it splits, a top-level insert takes half the window's content, and
//! a swap takes the whole of the pane it trades with. A preview derived any
//! other way (a fixed band, a whole-pane wash for a half-pane split) is a
//! preview that lies, and the user only finds out after letting go.
//!
//! Rects are win32 screen coordinates — `left`/`top` inclusive,
//! `right`/`bottom` exclusive, y growing downward — because that is the space
//! `pane_drop` resolves in and the space a layered overlay is placed in.

const std = @import("std");
const testing = std.testing;
const pane_drop = @import("pane_drop.zig");
const pane_id = @import("pane_id.zig");

pub const Rect = pane_drop.Rect;
pub const Side = pane_drop.Side;
pub const Target = pane_drop.Target;
pub const WindowRef = pane_drop.WindowRef;
pub const PaneRect = pane_drop.PaneRect;

/// The ratio every rearrange drop inserts at. One constant shared by the
/// preview and the commit, so the two cannot drift apart.
pub const insert_ratio: f16 = 0.5;

/// What the highlight is previewing. The rect is the same shape either way;
/// the kind is for the paint, which draws a swap differently from an insert
/// because "these two trade places" is not "this lands here".
pub const Kind = enum {
    /// The dragged pane will occupy this rect, taken out of the pane it is
    /// splitting.
    split,
    /// The dragged pane will occupy this rect, taken out of the window.
    top_level,
    /// The dragged pane and the pane filling this rect will exchange places.
    swap,
};

pub const Highlight = struct {
    rect: Rect,
    kind: Kind,
};

/// The preview for `target`, or null when there is nothing to draw in
/// `window`.
///
/// Null covers three different "nothing here" cases on purpose: no target at
/// all (the pointer is over a divider or over the dragged pane itself), a
/// target in a DIFFERENT window (T1532's cross-window drag — this window has
/// no preview to draw for it, and drawing one in the wrong window is worse
/// than drawing none), and the two drops this task does not commit yet, a new
/// tab and a new window. A preview is a promise, so it is drawn only where the
/// release is honoured.
pub fn forTarget(
    target: ?Target,
    window: WindowRef,
    content_rect: Rect,
    pane_rects: []const PaneRect,
) ?Highlight {
    const t = target orelse return null;
    if (t.window()) |w| {
        if (w != window) return null;
    } else return null; // .new_window

    return switch (t) {
        .split => |s| .{
            .rect = halfOn(paneRect(pane_rects, s.pane) orelse return null, s.side),
            .kind = .split,
        },
        .swap => |s| .{
            .rect = paneRect(pane_rects, s.pane) orelse return null,
            .kind = .swap,
        },
        .top_level => |s| .{
            .rect = halfOn(content_rect, s.side),
            .kind = .top_level,
        },
        // T1532 owns the drop; until it does, nothing is promised.
        .new_tab => null,
        .new_window => null,
    };
}

fn paneRect(pane_rects: []const PaneRect, id: []const u8) ?Rect {
    for (pane_rects) |p| {
        if (pane_id.eql(p.id, id)) return p.rect;
    }
    return null;
}

/// The half of `rect` that a pane inserted on `side` at `insert_ratio` takes.
///
/// `@divFloor` on the extent, matching `split_geometry`'s own rounding, so the
/// preview and the pane that lands are within a pixel rather than within a
/// rounding mode.
pub fn halfOn(rect: Rect, side: Side) Rect {
    const w = rect.width();
    const h = rect.height();
    const half_w = @divFloor(w, 2);
    const half_h = @divFloor(h, 2);
    return switch (side) {
        .left => .{ .left = rect.left, .top = rect.top, .right = rect.left + half_w, .bottom = rect.bottom },
        .right => .{ .left = rect.right - half_w, .top = rect.top, .right = rect.right, .bottom = rect.bottom },
        .up => .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + half_h },
        .down => .{ .left = rect.left, .top = rect.bottom - half_h, .right = rect.right, .bottom = rect.bottom },
    };
}

/// Has the pointer travelled far enough from the press to be a DRAG rather
/// than a click?
///
/// A press on the header is also how a pane is focused, so a drag that began
/// at the first pixel of jitter would make every header click a one-pixel
/// move. Chebyshev distance (the larger of the two deltas), which is what the
/// tab-strip reorder drag already uses — a diagonal wobble should not need to
/// travel further than a straight one to count.
pub fn exceedsThreshold(dx: i32, dy: i32, threshold: i32) bool {
    return @max(@abs(dx), @abs(dy)) > threshold;
}

/// The travel, in DIP, a press must exceed before it is a drag. Matches the
/// tab-strip reorder threshold so the two gestures feel the same.
pub const threshold_dip: i32 = 5;

pub fn thresholdPx(scale: f32) i32 {
    const v: f32 = @round(@as(f32, @floatFromInt(threshold_dip)) * scale);
    return @max(@as(i32, @intFromFloat(v)), 1);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const content: Rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 600 };
const pane_a: Rect = .{ .left = 0, .top = 0, .right = 500, .bottom = 600 };
const pane_b: Rect = .{ .left = 500, .top = 0, .right = 1000, .bottom = 600 };

const panes = [_]PaneRect{
    .{ .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .rect = pane_a },
    .{ .id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .rect = pane_b },
};

const win: WindowRef = 7;

test "T1531: a split preview is the half of the target pane the pane will take" {
    const h = forTarget(
        .{ .split = .{ .window = win, .pane = panes[1].id, .side = .left } },
        win,
        content,
        &panes,
    ).?;
    try testing.expectEqual(Kind.split, h.kind);
    try testing.expectEqual(@as(i32, 500), h.rect.left);
    try testing.expectEqual(@as(i32, 750), h.rect.right);
    try testing.expectEqual(@as(i32, 0), h.rect.top);
    try testing.expectEqual(@as(i32, 600), h.rect.bottom);
}

test "T1531: each side takes its own half of the pane" {
    const r: Rect = .{ .left = 100, .top = 200, .right = 300, .bottom = 400 };
    try testing.expectEqual(Rect{ .left = 100, .top = 200, .right = 200, .bottom = 400 }, halfOn(r, .left));
    try testing.expectEqual(Rect{ .left = 200, .top = 200, .right = 300, .bottom = 400 }, halfOn(r, .right));
    try testing.expectEqual(Rect{ .left = 100, .top = 200, .right = 300, .bottom = 300 }, halfOn(r, .up));
    try testing.expectEqual(Rect{ .left = 100, .top = 300, .right = 300, .bottom = 400 }, halfOn(r, .down));
}

test "T1531: an odd extent never overflows the rect it is halving" {
    const r: Rect = .{ .left = 0, .top = 0, .right = 101, .bottom = 101 };
    for ([_]Side{ .left, .right, .up, .down }) |s| {
        const h = halfOn(r, s);
        try testing.expect(h.left >= r.left);
        try testing.expect(h.top >= r.top);
        try testing.expect(h.right <= r.right);
        try testing.expect(h.bottom <= r.bottom);
        try testing.expectEqual(@as(i32, 50), @min(h.width(), h.height()));
    }
}

test "T1531: a swap preview is the WHOLE pane being traded with" {
    const h = forTarget(
        .{ .swap = .{ .window = win, .pane = panes[0].id } },
        win,
        content,
        &panes,
    ).?;
    try testing.expectEqual(Kind.swap, h.kind);
    try testing.expectEqual(pane_a, h.rect);
}

test "T1531: a top-level preview is half the window's CONTENT, not half a pane" {
    const h = forTarget(
        .{ .top_level = .{ .window = win, .side = .down } },
        win,
        content,
        &panes,
    ).?;
    try testing.expectEqual(Kind.top_level, h.kind);
    // Spans the whole width — that is the difference from splitting a pane.
    try testing.expectEqual(@as(i32, 0), h.rect.left);
    try testing.expectEqual(@as(i32, 1000), h.rect.right);
    try testing.expectEqual(@as(i32, 300), h.rect.top);
    try testing.expectEqual(@as(i32, 600), h.rect.bottom);
}

test "T1531: pane ids match case-insensitively, as everywhere else" {
    const h = forTarget(
        .{ .swap = .{ .window = win, .pane = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" } },
        win,
        content,
        &panes,
    ).?;
    try testing.expectEqual(pane_a, h.rect);
}

test "T1531: nothing is previewed without a target" {
    try testing.expectEqual(@as(?Highlight, null), forTarget(null, win, content, &panes));
}

test "T1531: a target in ANOTHER window draws nothing in this one" {
    try testing.expectEqual(@as(?Highlight, null), forTarget(
        .{ .swap = .{ .window = win + 1, .pane = panes[0].id } },
        win,
        content,
        &panes,
    ));
}

test "T1531: the drops T1532 owns promise nothing yet" {
    try testing.expectEqual(@as(?Highlight, null), forTarget(
        .{ .new_tab = .{ .window = win, .index = 0 } },
        win,
        content,
        &panes,
    ));
    try testing.expectEqual(@as(?Highlight, null), forTarget(
        .{ .new_window = .{ .x = 10, .y = 10 } },
        win,
        content,
        &panes,
    ));
}

test "T1531: a target naming a pane this window does not have draws nothing" {
    try testing.expectEqual(@as(?Highlight, null), forTarget(
        .{ .split = .{ .window = win, .pane = "cccccccccccccccccccccccccccccccc", .side = .up } },
        win,
        content,
        &panes,
    ));
}

test "T1531: the drag threshold is exceeded, not merely reached" {
    try testing.expect(!exceedsThreshold(5, 0, 5));
    try testing.expect(!exceedsThreshold(0, -5, 5));
    try testing.expect(exceedsThreshold(6, 0, 5));
    try testing.expect(exceedsThreshold(0, -6, 5));
    // Chebyshev: a diagonal wobble counts on its larger axis.
    try testing.expect(exceedsThreshold(-6, 2, 5));
    try testing.expect(!exceedsThreshold(4, 4, 5));
}

test "T1531: the threshold scales with the monitor and never rounds to zero" {
    try testing.expectEqual(@as(i32, 5), thresholdPx(1.0));
    try testing.expectEqual(@as(i32, 6), thresholdPx(1.25));
    try testing.expectEqual(@as(i32, 10), thresholdPx(2.0));
    try testing.expectEqual(@as(i32, 1), thresholdPx(0.01));
}
