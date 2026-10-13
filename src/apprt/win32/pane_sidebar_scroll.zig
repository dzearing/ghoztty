//! Pure scrolling for the win32 pane sidebar (T1878; Mac's list is a
//! `ScrollView`, and in the all-windows scope its project headers are sticky
//! section headers, b4a3216cc).
//!
//! The layout (`pane_sidebar.zig`) places every row as if the column were as
//! tall as its content. `apply` then takes a wanted offset and turns that
//! layout into the scrolled one: it finds the viewport - everything below the
//! header and the search field, or the rail's tiles below its pin - clamps
//! the offset to what the content can scroll, moves every scrolled rect up
//! by it, and pins the project header whose windows are passing under the
//! viewport's top. The layout records the viewport, and `hitTest` refuses a
//! point outside it, so a click, a drop row and a tooltip can only ever land
//! on what is drawn.
//!
//! The header, its buttons and the search field never scroll (Mac keeps them
//! above the `ScrollView`).
//!
//! Imports only `pane_sidebar.zig`, so it runs in every test lane.

const std = @import("std");
const sb = @import("pane_sidebar.zig");

const Layout = sb.Layout;
const Rect = sb.Rect;
const px = sb.px;

/// The scrolled region of `l` before any scroll pass. Empty while hidden.
pub fn viewportOf(l: *const Layout, scale: f32) Rect {
    const sm = px(sb.sm_dip, scale);
    switch (l.mode) {
        .hidden => return .{},
        .expanded => {},
        .mini => if (!l.open) {
            // The rail: from just under the pin to the card's bottom inset,
            // so the first tile's corner badges (which overhang it by 2 DIP)
            // stay inside.
            const top = l.pin.bottom + sm;
            return .{ .left = l.card.left, .top = top, .right = l.card.right, .bottom = @max(l.card.bottom - sm, top) };
        },
    }
    const area: Rect = if (l.open) l.card else .{ .right = l.width, .bottom = l.height };
    // Where the rows start: the outline's below the search field (and its
    // `sm`), the single roster's straight under the header.
    const top = if (l.search.width() > 0) l.search.bottom + sm else l.header.bottom;
    return .{ .left = area.left, .top = top, .right = area.right, .bottom = @max(area.bottom, top) };
}

/// The bottom of everything that scrolls (unscrolled coordinates).
fn contentBottom(l: *const Layout, floor: i32) i32 {
    var b = floor;
    for (0..l.count) |i| {
        if (l.shown(i)) b = @max(b, l.items[i].bottom);
    }
    for (l.heads[0..l.head_count]) |hd| b = @max(b, hd.rect.bottom);
    for (l.rules[0..l.rule_count]) |r| b = @max(b, r.bottom);
    for (l.captions[0..l.caption_count]) |c| b = @max(b, c.rect.bottom);
    inline for (.{ l.section_rule, l.stashed_caption, l.drop_slot, l.no_match }) |opt| {
        if (opt) |r| b = @max(b, r.bottom);
    }
    return b;
}

/// How far `l` (unscrolled) can scroll: the content past the viewport's
/// bottom, plus `sm` so the last row is not flush with the edge.
pub fn maxScroll(l: *const Layout, scale: f32) i32 {
    const vp = viewportOf(l, scale);
    if (vp.height() <= 0) return 0;
    const end = contentBottom(l, vp.top) + px(sb.sm_dip, scale);
    return @max(end - vp.bottom, 0);
}

pub fn clampOffset(l: *const Layout, want: i32, scale: f32) i32 {
    return std.math.clamp(want, 0, maxScroll(l, scale));
}

fn shift(r: *Rect, dy: i32) void {
    r.top += dy;
    r.bottom += dy;
}

fn shiftOpt(r: *?Rect, dy: i32) void {
    if (r.*) |*v| shift(v, dy);
}

/// Scroll the freshly laid-out `l` to `want` (clamped): record the viewport,
/// move everything below the controls up, and pin the project header whose
/// section is passing under the top.
pub fn apply(l: *Layout, want: i32, scale: f32) void {
    const vp = viewportOf(l, scale);
    l.viewport = vp;
    l.max_scroll = maxScroll(l, scale);
    l.scroll = std.math.clamp(want, 0, l.max_scroll);
    l.sticky = null;
    const dy = -l.scroll;
    if (dy != 0) {
        for (0..l.count) |i| {
            // A folded pane's empty rect stays empty (`shown` reads width).
            if (l.shown(i)) shift(&l.items[i], dy);
        }
        for (l.heads[0..l.head_count]) |*hd| {
            shift(&hd.rect, dy);
            shift(&hd.chevron, dy);
        }
        for (l.rules[0..l.rule_count]) |*r| shift(r, dy);
        for (l.captions[0..l.caption_count]) |*c| shift(&c.rect, dy);
        shiftOpt(&l.section_rule, dy);
        shiftOpt(&l.stashed_caption, dy);
        shiftOpt(&l.drop_slot, dy);
        shiftOpt(&l.no_match, dy);
    }
    pinHead(l);
}

/// The section a head at `k` leads ends where the next top-level head
/// starts (a project's windows are one level deeper than it).
fn sectionEnd(l: *const Layout, k: usize) ?i32 {
    for (l.heads[k + 1 .. l.head_count]) |hd| {
        if (hd.depth == 0) return hd.rect.top;
    }
    return null;
}

/// Mac's sticky project header: the project whose windows are scrolling
/// under the viewport's top keeps its header there, until the next section's
/// header arrives and pushes it up and out.
fn pinHead(l: *Layout) void {
    if (!l.outline or l.viewport.height() <= 0) return;
    const top = l.viewport.top;
    for (l.heads[0..l.head_count], 0..) |*hd, k| {
        if (hd.kind != .project or hd.rect.top >= top) continue;
        const h = hd.rect.height();
        const end = sectionEnd(l, k) orelse std.math.maxInt(i32);
        if (end <= top) continue;
        const pinned = @min(top, end - h);
        const dy = pinned - hd.rect.top;
        shift(&hd.rect, dy);
        shift(&hd.chevron, dy);
        l.sticky = k;
        return;
    }
}

/// The part of `r` (scrolled coordinates) a reader can see: inside the
/// viewport, and - for anything but the sticky header itself - below it.
/// Empty when none of it shows. Before a scroll pass, `r` as it is.
pub fn visible(l: *const Layout, r: Rect) Rect {
    if (l.viewport.height() <= 0) return r;
    var top = @max(r.top, l.viewport.top);
    if (l.sticky) |k| {
        const s = l.heads[k].rect;
        const is_sticky = r.top == s.top and r.bottom == s.bottom and r.left == s.left;
        if (!is_sticky and r.top < s.bottom) top = @max(top, s.bottom);
    }
    const bottom = @min(r.bottom, l.viewport.bottom);
    if (bottom <= top or r.width() <= 0) return .{};
    return .{ .left = r.left, .top = top, .right = r.right, .bottom = bottom };
}

/// The offset that brings `r` into view in the UNSCROLLED layout `l`,
/// starting from `current`: unchanged when it already shows, else the least
/// move that shows all of it - under a pinned project header, when its row
/// sits in a project's section.
pub fn revealOffset(l: *const Layout, r: Rect, current: i32, scale: f32) i32 {
    const vp = viewportOf(l, scale);
    if (vp.height() <= 0 or r.height() <= 0) return clampOffset(l, current, scale);
    // The header that would be pinned over this row, if any.
    var cover: i32 = 0;
    if (l.outline) {
        var k: usize = l.head_count;
        while (k > 0) {
            k -= 1;
            const hd = l.heads[k];
            if (hd.depth != 0 or hd.rect.top > r.top) continue;
            if (hd.kind == .project and hd.rect.top != r.top) cover = hd.rect.height();
            break;
        }
    }
    var want = current;
    if (r.top - want < vp.top + cover) {
        want = r.top - vp.top - cover;
    } else if (r.bottom - want > vp.bottom) {
        want = r.bottom - vp.bottom;
    }
    return clampOffset(l, want, scale);
}

/// Turns wheel deltas into pixels, carrying the remainder so a precision
/// touchpad's small deltas add up instead of rounding away. Positive delta
/// (the wheel rolled away from the user) scrolls up, which lowers the offset.
pub const Wheel = struct {
    rem: i32 = 0,

    pub fn step(self: *Wheel, delta: i32, lines: u32, line_h: i32) i32 {
        const total = delta * @as(i32, @intCast(@min(lines, 100))) * line_h + self.rem;
        const moved = @divTrunc(total, 120);
        self.rem = total - moved * 120;
        return -moved;
    }

    pub fn reset(self: *Wheel) void {
        self.rem = 0;
    }
};

/// The overlay thumb's width: the app's thin overlay idiom, inside the
/// trailing fill inset of a row (or the rail card's tile inset), so it
/// never covers a row's own trailing button.
pub const thumb_dip: f32 = 4;
pub const rail_thumb_dip: f32 = 3;
pub const thumb_edge_dip: f32 = 2;
pub const thumb_min_dip: f32 = 20;

/// The overlay thumb in the scrolled layout `l`, or null when it all fits.
/// Proportional, as `Scrollbar.thumbRect` is (not imported: that module pulls
/// the terminal in, and this one runs in every lane).
pub fn thumb(l: *const Layout, scale: f32) ?Rect {
    if (l.max_scroll <= 0) return null;
    const vp = l.viewport;
    const track = vp.height();
    if (track <= 0) return null;
    const total = track + l.max_scroll;
    const min_h = @min(px(thumb_min_dip, scale), track);
    const h = @max(min_h, @divTrunc(track * track, total));
    const range = track - h;
    const y = if (range <= 0) 0 else @divTrunc(range * l.scroll + @divTrunc(l.max_scroll, 2), l.max_scroll);
    const rows = l.mode == .expanded or l.open;
    const w = @max(px(if (rows) thumb_dip else rail_thumb_dip, scale), 2);
    const right = vp.right - px(thumb_edge_dip, scale);
    return .{ .left = right - w, .top = vp.top + y, .right = right, .bottom = vp.top + y + h };
}

/// The offset a thumb drag asks for: the thumb's top follows the pointer
/// (`grab` is where in the thumb it was taken), mapped back over the range.
pub fn dragOffset(l: *const Layout, pointer_y: i32, grab: i32, scale: f32) i32 {
    const t = thumb(l, scale) orelse return 0;
    const range = l.viewport.height() - t.height();
    if (range <= 0) return 0;
    const pos = std.math.clamp(pointer_y - grab - l.viewport.top, 0, range);
    return @divTrunc(pos * l.max_scroll + @divTrunc(range, 2), range);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

fn tm(s: f32) sb.TextMetrics {
    return .{ .title_h = px(19, s), .caption_h = px(16, s) };
}

fn manyItems(comptime n: usize) [n]sb.Item {
    var items: [n]sb.Item = undefined;
    for (&items) |*it| it.* = .{ .section = .grid };
    return items;
}

test "pane_sidebar_scroll: a list that fits never scrolls, one that does not clamps to its end" {
    for (scales) |s| {
        const few = manyItems(3);
        var l = sb.layout(.expanded, px(240, s), px(600, s), &few, tm(s), s);
        apply(&l, 500, s);
        try testing.expectEqual(@as(i32, 0), l.max_scroll);
        try testing.expectEqual(@as(i32, 0), l.scroll);
        try testing.expect(thumb(&l, s) == null);

        const lots = manyItems(30);
        var raw = sb.layout(.expanded, px(240, s), px(300, s), &lots, tm(s), s);
        const last_bottom = raw.items[29].bottom;
        var big = raw;
        apply(&big, 1_000_000, s);
        try testing.expect(big.max_scroll > 0);
        try testing.expectEqual(big.max_scroll, big.scroll);
        // At the end the last row sits `sm` above the viewport's bottom.
        try testing.expectEqual(big.viewport.bottom - px(sb.sm_dip, s), big.items[29].bottom);
        try testing.expectEqual(last_bottom - big.scroll, big.items[29].bottom);
        // Negative offsets clamp to the top.
        apply(&raw, -40, s);
        try testing.expectEqual(@as(i32, 0), raw.scroll);
    }
}

test "pane_sidebar_scroll: the header and its buttons never move; rows past the fold are reachable" {
    for (scales) |s| {
        const lots = manyItems(30);
        const raw = sb.layout(.expanded, px(240, s), px(300, s), &lots, tm(s), s);
        var l = raw;
        apply(&l, px(200, s), s);
        try testing.expectEqual(raw.pin, l.pin);
        try testing.expectEqual(raw.header, l.header);
        try testing.expectEqual(raw.header.bottom, l.viewport.top);
        // A row past the fold before the scroll: unreachable, then hit.
        const i: usize = 12;
        const x = raw.items[i].centerX();
        var before = raw;
        apply(&before, 0, s);
        try testing.expect(raw.items[i].centerY() > before.viewport.bottom);
        try testing.expectEqual(sb.Hit.none, sb.hitTest(&before, x, raw.items[i].centerY(), s));
        try testing.expectEqual(sb.Hit{ .item = i }, sb.hitTest(&l, x, l.items[i].centerY(), s));
        // A row scrolled up under the header is no longer a hit there, and
        // the header's own buttons still are.
        try testing.expect(l.items[0].bottom <= l.viewport.top);
        try testing.expectEqual(sb.Hit.pin, sb.hitTest(&l, l.pin.centerX(), l.pin.centerY(), s));
        try testing.expectEqual(Rect{}, visible(&l, l.items[0]));
    }
}

test "pane_sidebar_scroll: the rail scrolls its tiles under a fixed pin" {
    for (scales) |s| {
        const lots = manyItems(20);
        const raw = sb.layout(.mini, px(68, s), px(300, s), &lots, tm(s), s);
        var l = raw;
        apply(&l, 1_000_000, s);
        try testing.expect(l.max_scroll > 0);
        try testing.expectEqual(raw.pin, l.pin);
        try testing.expectEqual(raw.card, l.card);
        try testing.expect(l.viewport.top >= raw.pin.bottom);
        const last = l.items[19];
        try testing.expect(last.bottom <= l.viewport.bottom);
        try testing.expectEqual(sb.Hit{ .item = 19 }, sb.hitTest(&l, last.centerX(), last.centerY(), s));
        // The thumb sits inside the card, clear of the tiles.
        const t = thumb(&l, s).?;
        try testing.expect(t.right <= l.card.right and t.left >= last.right);
        try testing.expectEqual(l.viewport.bottom, t.bottom);
    }
}

/// A project with two windows of `per` panes each, then a lone window.
fn Fixture(comptime per: usize) type {
    return struct { items: [3 * per]sb.Item, lines: [4 + 3 * per]sb.Line };
}

fn projectFixture(comptime per: usize) Fixture(per) {
    var f: Fixture(per) = undefined;
    for (&f.items, 0..) |*it, i| it.* = .{ .section = .grid, .group = @intCast(i / per), .own = i / per == 2 };
    var n: usize = 0;
    f.lines[n] = .{ .kind = .project, .index = 0 };
    n += 1;
    for (0..2) |g| {
        f.lines[n] = .{ .kind = .window, .index = g, .depth = 1 };
        n += 1;
        for (0..per) |p| {
            f.lines[n] = .{ .kind = .pane, .index = g * per + p, .depth = 2 };
            n += 1;
        }
    }
    f.lines[n] = .{ .kind = .window, .index = 2 };
    n += 1;
    for (0..per) |p| {
        f.lines[n] = .{ .kind = .pane, .index = 2 * per + p, .depth = 1 };
        n += 1;
    }
    return f;
}

test "pane_sidebar_scroll: a project header sticks while its windows scroll under it, then is pushed out" {
    for (scales) |s| {
        const f = projectFixture(6);
        const raw = sb.layoutWith(.expanded, px(240, s), px(320, s), &f.items, &f.lines, tm(s), s);
        try testing.expectEqual(sb.HeadKind.project, raw.heads[0].kind);
        const head_h = raw.heads[0].rect.height();

        // Scrolled a little into the project: its header is pinned at the top.
        var l = raw;
        apply(&l, px(60, s), s);
        try testing.expectEqual(@as(?usize, 0), l.sticky);
        try testing.expectEqual(l.viewport.top, l.heads[0].rect.top);
        try testing.expectEqual(head_h, l.heads[0].rect.height());
        // Its chevron rides with it.
        try testing.expectEqual(raw.heads[0].chevron.top - raw.heads[0].rect.top, l.heads[0].chevron.top - l.heads[0].rect.top);
        // A click on the pinned header is the header's, never the row under it.
        const hx = l.heads[0].label_x + px(4, s);
        try testing.expectEqual(sb.Hit{ .head = 0 }, sb.hitTest(&l, hx, l.heads[0].rect.centerY(), s));
        // A row partly under it shows only below it.
        for (0..l.count) |i| {
            const v = visible(&l, l.items[i]);
            if (v.height() > 0) try testing.expect(v.top >= l.heads[0].rect.bottom);
        }

        // The lone window's header (depth 0) arriving pushes the project up.
        var lone: usize = 0;
        for (raw.heads[0..raw.head_count], 0..) |hd, k| {
            if (hd.depth == 0 and hd.kind == .window) lone = k;
        }
        var p = raw;
        const at = raw.heads[lone].rect.top - viewportOf(&raw, s).top - @divTrunc(head_h, 2);
        apply(&p, at, s);
        try testing.expectEqual(@as(?usize, 0), p.sticky);
        try testing.expectEqual(p.heads[lone].rect.top, p.heads[0].rect.bottom);
        try testing.expect(p.heads[0].rect.top < p.viewport.top);

        // Past it: nothing is pinned (a lone window does not stick). A
        // shorter column, so the lone window's rows can scroll that far.
        var q = sb.layoutWith(.expanded, px(240, s), px(200, s), &f.items, &f.lines, tm(s), s);
        apply(&q, q.heads[lone].rect.top - viewportOf(&q, s).top + px(10, s), s);
        try testing.expect(q.heads[lone].rect.top < q.viewport.top);
        try testing.expectEqual(@as(?usize, null), q.sticky);
    }
}

test "pane_sidebar_scroll: revealing a row moves the least, and clears a pinned project header" {
    for (scales) |s| {
        const lots = manyItems(30);
        const raw = sb.layout(.expanded, px(240, s), px(300, s), &lots, tm(s), s);
        const vp = viewportOf(&raw, s);
        // Already in view: nothing moves.
        try testing.expectEqual(@as(i32, 0), revealOffset(&raw, raw.items[1], 0, s));
        // Below the fold: its bottom lands on the viewport's bottom.
        const r = raw.items[20];
        try testing.expectEqual(r.bottom - vp.bottom, revealOffset(&raw, r, 0, s));
        // Above the top: its top lands on the viewport's top.
        try testing.expectEqual(raw.items[3].top - vp.top, revealOffset(&raw, raw.items[3], 100_000, s));

        // In a project's section, the row clears the header that would pin.
        const f = projectFixture(6);
        const out = sb.layoutWith(.expanded, px(240, s), px(320, s), &f.items, &f.lines, tm(s), s);
        const row = out.items[7]; // the second window's second pane
        const off = revealOffset(&out, row, 100_000, s);
        var l = out;
        apply(&l, off, s);
        try testing.expectEqual(@as(?usize, 0), l.sticky);
        try testing.expectEqual(l.heads[0].rect.bottom, l.items[7].top);
    }
}

test "pane_sidebar_scroll: the wheel carries remainders and scrolls the right way" {
    var w: Wheel = .{};
    // One notch toward the user (negative) scrolls down three lines.
    try testing.expectEqual(@as(i32, 90), w.step(-120, 3, 30));
    try testing.expectEqual(@as(i32, -90), w.step(120, 3, 30));
    // A touchpad's small deltas add up rather than round to nothing.
    var total: i32 = 0;
    for (0..12) |_| total += w.step(-10, 3, 30);
    try testing.expectEqual(@as(i32, 90), total);
}

test "pane_sidebar_scroll: the thumb tracks the offset and a drag maps back to it" {
    for (scales) |s| {
        const lots = manyItems(40);
        const raw = sb.layout(.expanded, px(240, s), px(300, s), &lots, tm(s), s);
        var top = raw;
        apply(&top, 0, s);
        const t0 = thumb(&top, s).?;
        try testing.expectEqual(top.viewport.top, t0.top);
        try testing.expect(t0.right <= top.viewport.right and t0.left >= top.items[0].right - px(1, s));
        var end = raw;
        apply(&end, 1_000_000, s);
        const t1 = thumb(&end, s).?;
        try testing.expectEqual(end.viewport.bottom, t1.bottom);
        // Dragging the thumb to the bottom asks for the end, to the top for 0.
        try testing.expectEqual(end.max_scroll, dragOffset(&top, top.viewport.bottom, 0, s));
        try testing.expectEqual(@as(i32, 0), dragOffset(&end, top.viewport.top - 50, 0, s));
    }
}
