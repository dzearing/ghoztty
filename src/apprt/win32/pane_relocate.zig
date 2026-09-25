//! The pure rules behind moving a LIVE pane from one top-level window into
//! another (T1538). No OS imports, so these run in every app-runtime lane —
//! the `split_geometry.zig` / `pane_drop.zig` pattern.
//!
//! Two questions are decided here rather than inline in `Window.zig`, because
//! both are stated once and read in three places each (the preview, the
//! commit, and the acceptance script's expectations):
//!
//!   * what happens to the window the pane LEAVES, and
//!   * where a brand-new window holding the pane goes on screen.
//!
//! Mac parity: `PaneMoveCoordinator.finishRelocation` collapses the source the
//! same way, and `TerminalController.newWindow(at:)` places the popped-out
//! window against the drop point.

const std = @import("std");

/// What the source window must do once the pane is out of its tree.
///
/// Deliberately three states rather than a bool: "the tab is now empty" and
/// "the window is now empty" are different repairs, and conflating them is how
/// a relocation either leaves a dead tab button behind or closes a window that
/// still holds work.
pub const SourceAftermath = enum {
    /// The tab still has panes; it just re-lays out.
    keep_tab,
    /// The tab is empty and its slot goes — but NOT through the close path,
    /// which would end the sessions of a tree that no longer holds any.
    drop_tab,
    /// That was the window's last pane in its last tab: the window goes.
    close_window,
};

pub fn sourceAftermath(leaves_in_tab: usize, tab_count: usize) SourceAftermath {
    if (leaves_in_tab > 1) return .keep_tab;
    if (tab_count > 1) return .drop_tab;
    return .close_window;
}

/// May this pane be popped out into a window of its OWN?
///
/// Mac's rule (`PaneHeaderView.canPopOut`): a window's last pane cannot, because
/// the move would close one window and open another around the very same pane —
/// a gesture that costs the user their window position and gives nothing back.
/// Dropping that same last pane onto ANOTHER window is a different act and is
/// allowed; that one has a destination.
pub fn popOutAllowed(leaves_in_tab: usize, tab_count: usize) bool {
    return leaves_in_tab > 1 or tab_count > 1;
}

/// Where a tab ends up when its ONLY pane is dropped on strip seam `seam`
/// (T1542), or null when the drop leaves it where it already is.
///
/// A pane that is its tab's whole tree is already a tab of its own, so a
/// strip drop cannot make it one — but the user pointed at a place in the
/// strip, and moving the tab there is what the gesture means. `seam` is an
/// INSERTION index (0 = before the first tab, `tab_count` = after the last),
/// the way the resolver answers it; the result is the tab's final index once
/// its own slot has been taken out. The two seams either side of the tab are
/// both "right here", and answer null so the preview draws no promise the
/// release would not keep.
pub fn tabReorderIndex(source: usize, seam: usize, tab_count: usize) ?usize {
    if (source >= tab_count) return null;
    const s = @min(seam, tab_count);
    const to = if (s > source) s - 1 else s;
    if (to == source) return null;
    return to;
}

/// A screen rectangle in physical pixels, win32 convention (`right`/`bottom`
/// exclusive).
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
};

pub const Point = struct { x: i32, y: i32 };

/// How far in from the new window's left edge the drop point lands, in DIP.
/// The pointer should come to rest ON the window it just created, near where
/// the pane's header will be, rather than at its top-left corner — a window
/// whose corner is under the cursor reads as having jumped away from the drop.
pub const grab_inset_dip: i32 = 64;

/// ...and how far down. Deliberately small: the pane header of the first pane
/// is a few dozen pixels below the top, which is what the hand was carrying.
pub const grab_drop_dip: i32 = 16;

fn scaled(dip: i32, scale: f32) i32 {
    const v: f32 = @round(@as(f32, @floatFromInt(dip)) * scale);
    return @max(@as(i32, @intFromFloat(v)), 1);
}

/// Where a window of `w` x `h` holding the popped-out pane goes when the drop
/// happened at `point`, clamped into `work` (the monitor's work area).
///
/// Clamping rather than centering: the user pointed at a place, and a window
/// that ignores the point and lands in the middle of the screen reads as a
/// different gesture. A window larger than the work area pins to its origin —
/// there is no placement that satisfies both edges, and the top-left is the one
/// that keeps the caption reachable.
pub fn newWindowFrame(point: Point, w: i32, h: i32, work: Rect, scale: f32) Rect {
    const width = @max(w, 1);
    const height = @max(h, 1);

    var left = point.x - scaled(grab_inset_dip, scale);
    var top = point.y - scaled(grab_drop_dip, scale);

    if (width >= work.width()) {
        left = work.left;
    } else {
        left = @min(@max(left, work.left), work.right - width);
    }
    if (height >= work.height()) {
        top = work.top;
    } else {
        top = @min(@max(top, work.top), work.bottom - height);
    }

    return .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a pane leaving a tab that still has panes only re-lays that tab out" {
    try std.testing.expectEqual(SourceAftermath.keep_tab, sourceAftermath(2, 1));
    try std.testing.expectEqual(SourceAftermath.keep_tab, sourceAftermath(5, 3));
}

test "the last pane of a tab drops the tab when the window has others" {
    try std.testing.expectEqual(SourceAftermath.drop_tab, sourceAftermath(1, 2));
    try std.testing.expectEqual(SourceAftermath.drop_tab, sourceAftermath(1, 9));
}

test "the last pane of the last tab closes the window" {
    try std.testing.expectEqual(SourceAftermath.close_window, sourceAftermath(1, 1));
}

test "a lone pane dropped on a seam ahead of its tab moves the tab left" {
    // Three tabs, the last one dragged to the front.
    try std.testing.expectEqual(@as(?usize, 0), tabReorderIndex(2, 0, 3));
    try std.testing.expectEqual(@as(?usize, 1), tabReorderIndex(2, 1, 3));
}

test "a lone pane dropped on a seam past its tab moves the tab right" {
    // The seam counts the tab's own slot, which the move takes out first.
    try std.testing.expectEqual(@as(?usize, 2), tabReorderIndex(0, 3, 3));
    try std.testing.expectEqual(@as(?usize, 1), tabReorderIndex(0, 2, 3));
}

test "the seams either side of the tab are where it already is" {
    try std.testing.expectEqual(@as(?usize, null), tabReorderIndex(1, 1, 3));
    try std.testing.expectEqual(@as(?usize, null), tabReorderIndex(1, 2, 3));
    // A window with one tab has nowhere else to put it.
    try std.testing.expectEqual(@as(?usize, null), tabReorderIndex(0, 0, 1));
    try std.testing.expectEqual(@as(?usize, null), tabReorderIndex(0, 1, 1));
}

test "a seam past the strip's end is the end, and a stale source is refused" {
    try std.testing.expectEqual(@as(?usize, 2), tabReorderIndex(0, 99, 3));
    try std.testing.expectEqual(@as(?usize, null), tabReorderIndex(2, 99, 3));
    try std.testing.expectEqual(@as(?usize, null), tabReorderIndex(3, 0, 3));
}

test "a window's last pane cannot pop out into a window of its own" {
    try std.testing.expect(!popOutAllowed(1, 1));
    try std.testing.expect(popOutAllowed(2, 1));
    try std.testing.expect(popOutAllowed(1, 2));
}

test "the new window lands under the drop point, offset so the pointer is on it" {
    const work: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1440 };
    const f = newWindowFrame(.{ .x = 800, .y = 500 }, 900, 600, work, 1.0);
    try std.testing.expectEqual(@as(i32, 736), f.left);
    try std.testing.expectEqual(@as(i32, 484), f.top);
    try std.testing.expectEqual(@as(i32, 900), f.width());
    try std.testing.expectEqual(@as(i32, 600), f.height());
}

test "the offset scales with the monitor, like every other distance here" {
    const work: Rect = .{ .left = 0, .top = 0, .right = 3840, .bottom = 2160 };
    const f = newWindowFrame(.{ .x = 1000, .y = 700 }, 900, 600, work, 2.0);
    try std.testing.expectEqual(@as(i32, 1000 - 128), f.left);
    try std.testing.expectEqual(@as(i32, 700 - 32), f.top);
}

test "a drop near an edge pulls the whole window back inside the work area" {
    const work: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
    const f = newWindowFrame(.{ .x = 1910, .y = 1035 }, 900, 600, work, 1.0);
    try std.testing.expectEqual(@as(i32, 1020), f.left);
    try std.testing.expectEqual(@as(i32, 440), f.top);
    try std.testing.expectEqual(@as(i32, 1920), f.right);
    try std.testing.expectEqual(@as(i32, 1040), f.bottom);
}

test "a drop past the top-left corner clamps to the work area's origin" {
    const work: Rect = .{ .left = -1920, .top = 100, .right = 0, .bottom = 1140 };
    const f = newWindowFrame(.{ .x = -1900, .y = 105 }, 800, 500, work, 1.0);
    try std.testing.expectEqual(@as(i32, -1920), f.left);
    try std.testing.expectEqual(@as(i32, 100), f.top);
}

test "a window bigger than the work area pins to its origin rather than hanging off" {
    const work: Rect = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    const f = newWindowFrame(.{ .x = 400, .y = 300 }, 1200, 900, work, 1.0);
    try std.testing.expectEqual(@as(i32, 0), f.left);
    try std.testing.expectEqual(@as(i32, 0), f.top);
    try std.testing.expectEqual(@as(i32, 1200), f.width());
}
