//! Pure geometry for keeping a pane's popups inside its window (T2227).
//!
//! A pane is a WS_CHILD, so the window clips it: whatever part of it lies
//! past the window's edge is simply not drawn. Its popups - the unfocused dim
//! wash, the scrollbar, the banner, the badges, the bell frame - are top-level
//! layered windows placed over it in screen coordinates, and nothing clips
//! them. A pane that is partly outside its window (a folding card sliding to
//! its held rect past the edge, T2186) therefore had its wash, painted in the
//! background colour, bleed out over the desktop.
//!
//! The rule the popups follow: the wash is clipped to the part of the pane in
//! view (`clip`), and a popup with content of its own is shown only while the
//! whole pane is in view - half a scrollbar or a banner cut mid-word is not a
//! thing to show, and the pane is on its way behind the run anyway.
//!
//! No OS imports, so the tests run in every app-runtime lane (the
//! hero_math/dim_math pattern). The window walk is `pane_clip.zig`.

const std = @import("std");

/// A rectangle, right/bottom exclusive (the win32 `RECT` convention).
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn isEmpty(r: Rect) bool {
        return r.right <= r.left or r.bottom <= r.top;
    }

    pub fn eql(a: Rect, b: Rect) bool {
        return std.meta.eql(a, b);
    }
};

/// The overlap of `a` and `b`, or null when they do not overlap.
pub fn intersect(a: Rect, b: Rect) ?Rect {
    const r: Rect = .{
        .left = @max(a.left, b.left),
        .top = @max(a.top, b.top),
        .right = @min(a.right, b.right),
        .bottom = @min(a.bottom, b.bottom),
    };
    return if (r.isEmpty()) null else r;
}

/// Whether all of `inner` lies inside `outer`.
pub fn contains(outer: Rect, inner: Rect) bool {
    return inner.left >= outer.left and inner.top >= outer.top and
        inner.right <= outer.right and inner.bottom <= outer.bottom;
}

/// How much of a pane is in view.
pub const Clip = union(enum) {
    /// All of it: nothing to clip.
    whole,
    /// Only this part, in the pane's OWN coordinates (origin at its top-left
    /// corner) - the space a popup placed exactly over the pane draws in, and
    /// the space `SetWindowRgn` takes.
    part: Rect,
    /// None of it.
    none,
};

/// How much of `pane` (screen coordinates) is in view, given `visible`, the
/// part of it its ancestors do not clip (null: none).
pub fn clip(pane: Rect, visible: ?Rect) Clip {
    if (pane.isEmpty()) return .none;
    const v = visible orelse return .none;
    const in = intersect(pane, v) orelse return .none;
    if (in.eql(pane)) return .whole;
    return .{ .part = .{
        .left = in.left - pane.left,
        .top = in.top - pane.top,
        .right = in.right - pane.left,
        .bottom = in.bottom - pane.top,
    } };
}

const testing = std.testing;

fn rc(l: i32, t: i32, rt: i32, b: i32) Rect {
    return .{ .left = l, .top = t, .right = rt, .bottom = b };
}

test "intersect: overlap, touching edges and no overlap" {
    try testing.expectEqual(rc(50, 0, 100, 80), intersect(rc(0, 0, 100, 80), rc(50, -10, 200, 90)).?);
    // Right/bottom exclusive: rects that only touch share nothing.
    try testing.expect(intersect(rc(0, 0, 100, 80), rc(100, 0, 200, 80)) == null);
    try testing.expect(intersect(rc(0, 0, 10, 10), rc(20, 20, 30, 30)) == null);
}

test "contains: edges are inside, one pixel over is not" {
    try testing.expect(contains(rc(0, 0, 100, 100), rc(0, 0, 100, 100)));
    try testing.expect(contains(rc(0, 0, 100, 100), rc(10, 10, 90, 90)));
    try testing.expect(!contains(rc(0, 0, 100, 100), rc(10, 10, 101, 90)));
    try testing.expect(!contains(rc(0, 0, 100, 100), rc(-1, 10, 90, 90)));
}

test "clip: a pane wholly in view needs nothing" {
    try testing.expect(clip(rc(100, 50, 600, 650), rc(0, 0, 1500, 700)) == .whole);
}

test "clip: a folding card past the right edge keeps only its part in view (T2227)" {
    // The card slides from 1461 toward its held rect at 1821; the window's
    // client area ends at 1512. In its own coordinates the part in view is
    // its first 1512 - 1500 = 12 columns, and its rows down to the client's
    // bottom.
    const c = clip(rc(1500, 40, 1917, 700), rc(8, 31, 1512, 708));
    try testing.expectEqual(rc(0, 0, 12, 660), c.part);
}

test "clip: a card sliding past the LEFT edge is clipped from its own left" {
    const c = clip(rc(-100, 0, 300, 600), rc(0, 0, 1500, 700));
    try testing.expectEqual(rc(100, 0, 400, 600), c.part);
}

test "clip: a pane wholly outside, an empty pane, and nothing visible are none" {
    try testing.expect(clip(rc(1600, 0, 1900, 600), rc(0, 0, 1500, 700)) == .none);
    try testing.expect(clip(rc(10, 10, 10, 600), rc(0, 0, 1500, 700)) == .none);
    try testing.expect(clip(rc(10, 10, 100, 600), null) == .none);
}
