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
    /// The dragged pane will become a NEW TAB, landing at this seam in the
    /// strip (T1537). The rect is an insertion caret, not a footprint: the
    /// pane's eventual rect is the whole of a tab that does not exist yet, so
    /// promising it as a wash over the content area would say "it lands here"
    /// about an area the drop is about to replace entirely.
    new_tab,
    /// The dragged pane will become a WINDOW OF ITS OWN, and this rect is
    /// where that window lands (T1538). A footprint, like `split` and
    /// `top_level` — the window is about to exist and the user is entitled to
    /// know where.
    new_window,
};

pub const Highlight = struct {
    rect: Rect,
    kind: Kind,
};

/// Everything the preview needs to know about the window it is being drawn
/// in. A struct rather than five positional arguments because T1537 added the
/// tab strip to it and the call is already the kind that a reader has to count
/// commas to check.
pub const Context = struct {
    window: WindowRef,

    /// The split-tree area, in screen coordinates.
    content_rect: Rect,

    /// Every leaf pane's frame, in screen coordinates.
    pane_rects: []const PaneRect = &.{},

    /// The tab strip's band, when this window shows one.
    tab_strip: ?Rect = null,

    /// The tab buttons in visual order, left to right.
    tab_rects: []const Rect = &.{},

    /// Whether a new-tab drop is one this window will actually HONOUR
    /// (T1537). A pane that is its tab's only pane is already a tab of its
    /// own, so the drop is refused — and a preview drawn for it would be the
    /// one thing this module exists to prevent, a promise the release breaks.
    can_new_tab: bool = false,

    /// The monitor scale, for the caret's thickness.
    scale: f32 = 1.0,

    /// Where a `.new_window` drop would put the window it creates, in screen
    /// coordinates (T1538) — `pane_relocate.newWindowFrame` against the live
    /// window's size and the monitor under the pointer.
    ///
    /// Supplied by the caller rather than computed here because it needs the
    /// monitor's work area, which is an OS question and this module has no OS.
    /// Null ⇒ nothing is promised for that drop, which is what a caller that
    /// cannot answer must say.
    new_window_frame: ?Rect = null,
};

/// The preview for `target`, or null when there is nothing to draw in
/// `window`.
///
/// `ctx` describes the window the TARGET names — which since T1538 is not
/// necessarily the window the drag started in. The caller resolves the target
/// first and then hands over that window's geometry; the guard below is what
/// makes a mismatched pair impossible to draw from.
///
/// Null covers three "nothing here" cases on purpose: no target at all (the
/// pointer is over a divider or over the dragged pane itself), a context that
/// is not the target's window (a caller bug), and a new-tab drop the window
/// would refuse (`can_new_tab`). A preview is a promise, so it is drawn only
/// where the release is honoured.
pub fn forTarget(target: ?Target, ctx: Context) ?Highlight {
    const t = target orelse return null;
    if (t.window()) |w| {
        if (w != ctx.window) return null;
    } else {
        // `.new_window`: no window owns it, so the frame is whatever the
        // caller measured — and nothing is promised when it could not.
        return .{ .rect = ctx.new_window_frame orelse return null, .kind = .new_window };
    }

    return switch (t) {
        .split => |s| .{
            .rect = halfOn(paneRect(ctx.pane_rects, s.pane) orelse return null, s.side),
            .kind = .split,
        },
        .swap => |s| .{
            .rect = paneRect(ctx.pane_rects, s.pane) orelse return null,
            .kind = .swap,
        },
        .top_level => |s| .{
            .rect = halfOn(ctx.content_rect, s.side),
            .kind = .top_level,
        },
        .new_tab => |s| blk: {
            if (!ctx.can_new_tab) break :blk null;
            const strip = ctx.tab_strip orelse break :blk null;
            break :blk .{
                .rect = newTabCaret(strip, ctx.tab_rects, s.index, ctx.scale),
                .kind = .new_tab,
            };
        },
        // Answered above, before the per-window arms are reached.
        .new_window => unreachable,
    };
}

/// How thick the new-tab insertion caret is, in DIP.
pub const caret_dip: i32 = 4;

pub fn caretPx(scale: f32) i32 {
    const v: f32 = @round(@as(f32, @floatFromInt(caret_dip)) * scale);
    return @max(@as(i32, @intFromFloat(v)), 1);
}

/// The insertion caret for a new tab landing at `index`: a slim bar the height
/// of the strip, standing on the SEAM the tab will open at.
///
/// The seam is the left edge of the tab currently at `index`, or the right
/// edge of the last tab when the drop appends. It is centred on that seam and
/// then clamped into the strip, so a caret at index 0 does not hang off the
/// window — a preview half outside the thing it is previewing reads as a
/// glitch rather than as a position.
pub fn newTabCaret(strip: Rect, tabs: []const Rect, index: usize, scale: f32) Rect {
    const w = caretPx(scale);
    const seam: i32 = seam: {
        // A tab the strip could not lay out reports an EMPTY rect, and its
        // `left` is 0 — a coordinate that means "the far edge of the primary
        // monitor", not "the seam before this tab". Walk to the first tab that
        // actually has a rect, then fall back to the last one that does.
        var i = index;
        while (i < tabs.len) : (i += 1) {
            if (tabs[i].right > tabs[i].left) break :seam tabs[i].left;
        }
        i = tabs.len;
        while (i > 0) {
            i -= 1;
            if (tabs[i].right > tabs[i].left) break :seam tabs[i].right;
        }
        break :seam strip.left;
    };

    var left = seam - @divFloor(w, 2);
    left = @max(left, strip.left);
    left = @min(left, @max(strip.right - w, strip.left));
    return .{
        .left = left,
        .top = strip.top,
        .right = left + w,
        .bottom = strip.bottom,
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

const empty_rect: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
const test_strip: Rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 40 };
const test_tabs = [_]Rect{
    .{ .left = 0, .top = 0, .right = 200, .bottom = 40 },
    .{ .left = 200, .top = 0, .right = 400, .bottom = 40 },
    .{ .left = 400, .top = 0, .right = 600, .bottom = 40 },
};

fn baseCtx() Context {
    return .{ .window = win, .content_rect = content, .pane_rects = &panes };
}

test "T1531: a split preview is the half of the target pane the pane will take" {
    const h = forTarget(
        .{ .split = .{ .window = win, .pane = panes[1].id, .side = .left } },
        baseCtx(),
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
        baseCtx(),
    ).?;
    try testing.expectEqual(Kind.swap, h.kind);
    try testing.expectEqual(pane_a, h.rect);
}

test "T1531: a top-level preview is half the window's CONTENT, not half a pane" {
    const h = forTarget(
        .{ .top_level = .{ .window = win, .side = .down } },
        baseCtx(),
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
        baseCtx(),
    ).?;
    try testing.expectEqual(pane_a, h.rect);
}

test "T1531: nothing is previewed without a target" {
    try testing.expectEqual(@as(?Highlight, null), forTarget(null, baseCtx()));
}

test "T1531: a target in ANOTHER window draws nothing in this one" {
    try testing.expectEqual(@as(?Highlight, null), forTarget(
        .{ .swap = .{ .window = win + 1, .pane = panes[0].id } },
        baseCtx(),
    ));
}

test "T1538: a new-window drop previews the frame that window will take" {
    var c = baseCtx();
    c.new_window_frame = .{ .left = 40, .top = 60, .right = 840, .bottom = 660 };
    const h = forTarget(.{ .new_window = .{ .x = 100, .y = 76 } }, c).?;
    try testing.expectEqual(Kind.new_window, h.kind);
    try testing.expectEqual(@as(i32, 40), h.rect.left);
    try testing.expectEqual(@as(i32, 840), h.rect.right);
}

test "T1538: a caller that could not measure the frame promises nothing" {
    try testing.expectEqual(@as(?Highlight, null), forTarget(
        .{ .new_window = .{ .x = 10, .y = 10 } },
        baseCtx(),
    ));
}

test "T1537: a new-tab drop previews a caret on the seam the tab opens at" {
    var c = baseCtx();
    c.tab_strip = test_strip;
    c.tab_rects = &test_tabs;
    c.can_new_tab = true;

    const h = forTarget(.{ .new_tab = .{ .window = win, .index = 1 } }, c).?;
    try testing.expectEqual(Kind.new_tab, h.kind);
    // Centred on tab 1's left edge (200), 4px wide at scale 1.
    try testing.expectEqual(@as(i32, 198), h.rect.left);
    try testing.expectEqual(@as(i32, 202), h.rect.right);
    // ...and it stands the full height of the strip.
    try testing.expectEqual(test_strip.top, h.rect.top);
    try testing.expectEqual(test_strip.bottom, h.rect.bottom);
}

test "T1537: appending past the last tab puts the caret after it" {
    var c = baseCtx();
    c.tab_strip = test_strip;
    c.tab_rects = &test_tabs;
    c.can_new_tab = true;

    const h = forTarget(.{ .new_tab = .{ .window = win, .index = test_tabs.len } }, c).?;
    // The last tab's right edge (600).
    try testing.expectEqual(@as(i32, 598), h.rect.left);
    try testing.expectEqual(@as(i32, 602), h.rect.right);
}

test "T1537: the caret never hangs off the strip it is drawn in" {
    const one = [_]Rect{.{ .left = 0, .top = 0, .right = 100, .bottom = 40 }};
    const narrow: Rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 40 };
    const at_start = newTabCaret(narrow, &one, 0, 1.0);
    try testing.expectEqual(@as(i32, 0), at_start.left);
    try testing.expectEqual(@as(i32, 4), at_start.right);
    const at_end = newTabCaret(narrow, &one, 1, 1.0);
    try testing.expect(at_end.right <= narrow.right);
    try testing.expectEqual(@as(i32, 96), at_end.left);
    // A strip with no tabs at all still answers inside itself.
    const empty = newTabCaret(narrow, &.{}, 0, 1.0);
    try testing.expectEqual(@as(i32, 0), empty.left);
    // ...and a strip narrower than the caret clamps rather than inverting.
    const hair: Rect = .{ .left = 10, .top = 0, .right = 12, .bottom = 40 };
    const clamped = newTabCaret(hair, &.{}, 0, 1.0);
    try testing.expectEqual(@as(i32, 10), clamped.left);
}

test "T1537: a tab the strip could not lay out is not mistaken for x = 0" {
    // The middle tab did not fit, so it reports an empty rect. Its index must
    // fall through to a real seam rather than parking the caret at the far
    // edge of the monitor.
    const gappy = [_]Rect{
        .{ .left = 100, .top = 0, .right = 300, .bottom = 40 },
        empty_rect,
        .{ .left = 300, .top = 0, .right = 500, .bottom = 40 },
    };
    const h = newTabCaret(test_strip, &gappy, 1, 1.0);
    try testing.expectEqual(@as(i32, 298), h.left);
    // ...and an index past every laid-out tab appends after the last real one.
    const tail = newTabCaret(test_strip, &gappy, 3, 1.0);
    try testing.expectEqual(@as(i32, 498), tail.left);
    // A strip where NOTHING was laid out falls back to the band's own edge.
    const none = [_]Rect{ empty_rect, empty_rect };
    try testing.expectEqual(test_strip.left, newTabCaret(test_strip, &none, 0, 1.0).left);
}

test "T1537: the caret thickness scales with the monitor and never rounds away" {
    try testing.expectEqual(@as(i32, 4), caretPx(1.0));
    try testing.expectEqual(@as(i32, 5), caretPx(1.25));
    try testing.expectEqual(@as(i32, 8), caretPx(2.0));
    try testing.expectEqual(@as(i32, 1), caretPx(0.01));
}

test "T1537: a new-tab drop this window will REFUSE previews nothing" {
    // A pane that is its tab's only pane is already a tab of its own, so the
    // release is a no-op — and a caret promising otherwise is the lie this
    // module exists to prevent.
    var c = baseCtx();
    c.tab_strip = test_strip;
    c.tab_rects = &test_tabs;
    c.can_new_tab = false;
    try testing.expectEqual(@as(?Highlight, null), forTarget(
        .{ .new_tab = .{ .window = win, .index = 1 } },
        c,
    ));
}

test "T1537: a window showing no strip previews no new-tab drop" {
    var c = baseCtx();
    c.can_new_tab = true;
    c.tab_rects = &test_tabs;
    try testing.expectEqual(@as(?Highlight, null), forTarget(
        .{ .new_tab = .{ .window = win, .index = 1 } },
        c,
    ));
}

test "T1531: a target naming a pane this window does not have draws nothing" {
    try testing.expectEqual(@as(?Highlight, null), forTarget(
        .{ .split = .{ .window = win, .pane = "cccccccccccccccccccccccccccccccc", .side = .up } },
        baseCtx(),
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
