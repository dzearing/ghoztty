//! One card's drop shadow as a picture of its own (T2740, the first step of
//! T2511): what the compositor can place under a pane visual and move with
//! it, instead of the shadow pixels `PaneDesk` bakes into the desk on every
//! compose.
//!
//! The desk's shadow only ever SCALES the pixel under it (`pane_elevation`'s
//! `darken`: each channel times a keep factor `k`). Premultiplied black at
//! alpha `1 - k` laid over a pixel is exactly that scale - `src + dst * (1 -
//! a)` with `src = 0` - so the shadow can leave the desk without changing a
//! pixel: lay the card's shadows over white, read the keep back out of the
//! channel, and that is the layer. Several overlapping shadows multiply their
//! keeps on the desk; laid one over another they do the same.
//!
//! The layer is the card's size plus its shadow's reach on every side, and
//! is measured from the card's own edges, so it depends on the card's width,
//! height and shadow share (and the style) - never on where the card is. A
//! glide that moves a card moves its layer and renders nothing (`Key`).
//!
//! Where the card itself lies the layer is clear: there the desk shows the
//! card's fill and rim, which a shadow never darkened (`paintCards` lays
//! every fill over every shadow), and the pane visual covers the rest. The
//! card's antialiased edge takes the shadow by the share of the pixel the
//! card leaves uncovered.

const std = @import("std");
const pane_elevation = @import("pane_elevation.zig");

/// A rendered layer: premultiplied BGRA (black, alpha = how much of what is
/// under it the shadow takes away), `w` x `h`, top-down. Its top-left sits
/// `reach` pixels above and left of the card's.
pub const Layer = struct {
    px: []u32,
    w: i32,
    h: i32,
    reach: i32,
    key: Key,

    pub fn deinit(self: *Layer, alloc: std.mem.Allocator) void {
        alloc.free(self.px);
        self.* = undefined;
    }

    /// Where the layer goes for `card`, in the card's coordinates.
    pub fn origin(self: *const Layer, card: pane_elevation.Card) [2]i32 {
        return .{ card.left - self.reach, card.top - self.reach };
    }

    pub fn alphaAt(self: *const Layer, x: i32, y: i32) u8 {
        return @truncate(self.px[@intCast(y * self.w + x)] >> 24);
    }
};

/// Everything a layer's pixels depend on. A card whose key is unchanged
/// keeps its layer, wherever it has moved to.
pub const Key = struct {
    w: i32,
    h: i32,
    shadow: f32,
    scale: f32,
    is_light: bool,
    glass: bool,

    pub fn of(card: pane_elevation.Card, style: pane_elevation.CardStyle) Key {
        return .{
            .w = card.right - card.left,
            .h = card.bottom - card.top,
            .shadow = std.math.clamp(card.shadow, 0, 1),
            .scale = style.scale,
            .is_light = style.is_light,
            .glass = style.glass,
        };
    }

    /// Whether the card casts anything at all.
    pub fn casts(self: Key) bool {
        return self.shadow > 0 and self.w > 0 and self.h > 0;
    }
};

/// Render `card`'s shadow on its own. `prepared` is `pane_elevation.prepare`
/// for `style` when the caller keeps one (the shadow's corner patch), or null.
/// Null when the card casts nothing.
pub fn render(
    alloc: std.mem.Allocator,
    card: pane_elevation.Card,
    style: pane_elevation.CardStyle,
    prepared: ?*const pane_elevation.Prepared,
) error{OutOfMemory}!?Layer {
    const key = Key.of(card, style);
    if (!key.casts()) return null;
    const reach = pane_elevation.shadowReachPx(style.scale);
    const lw = key.w + 2 * reach;
    const lh = key.h + 2 * reach;
    const px = try alloc.alloc(u32, @intCast(lw * lh));
    errdefer alloc.free(px);
    @memset(px, 0xFFFF_FFFF);
    const at: pane_elevation.Card = .{
        .left = reach,
        .top = reach,
        .right = reach + key.w,
        .bottom = reach + key.h,
        .shadow = key.shadow,
    };
    pane_elevation.paintCardShadows(px, @intCast(lw), @intCast(lh), &.{at}, style, prepared);
    // White under the shadow: every channel is 255 * k. Its alpha is 1 - k.
    for (px) |*p| p.* = @as(u32, 255 - ((p.* >> 8) & 0xFF)) << 24;
    clearUnderCard(px, lw, at, @floatFromInt(pane_elevation.radiusPx(style.scale)));
    return .{ .px = px, .w = lw, .h = lh, .reach = reach, .key = key };
}

/// Clear the layer where the card covers it: wholly inside its straight
/// sides, and by the card's coverage along its antialiased edge and corners.
fn clearUnderCard(px: []u32, lw: i32, card: pane_elevation.Card, radius: f32) void {
    const ri: i32 = @intFromFloat(radius);
    var y = card.top;
    while (y < card.bottom) : (y += 1) {
        const row = px[@intCast(y * lw)..][0..@intCast(lw)];
        const side_rows = y >= card.top + ri and y < card.bottom - ri;
        const edge_rows = y >= card.top + 2 and y < card.bottom - 2;
        var x = card.left;
        while (x < card.right) : (x += 1) {
            // Two pixels in from a straight side, or past the corners'
            // radius, a pixel is the card's alone.
            const deep = (side_rows and x >= card.left + 2 and x < card.right - 2) or
                (edge_rows and x >= card.left + ri and x < card.right - ri);
            const i: usize = @intCast(x);
            if (deep) {
                row[i] = 0;
                continue;
            }
            const d = pane_elevation.roundRectDistance(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, card, radius);
            const open = std.math.clamp(0.5 + d, 0, 1);
            const a: f32 = @floatFromInt(row[i] >> 24);
            row[i] = @as(u32, @intFromFloat(@round(a * open))) << 24;
        }
    }
}

/// `src` (premultiplied) over an opaque `dst`: what the compositor shows
/// where a layer pixel lies over the desk.
pub fn over(dst: u32, src: u32) u32 {
    const a = src >> 24;
    if (a == 0) return dst;
    const keep = 255 - a;
    var out: u32 = dst & 0xFF00_0000;
    var k: u5 = 0;
    while (k < 24) : (k += 8) {
        const c = (dst >> k) & 0xFF;
        const s = (src >> k) & 0xFF;
        const v: u32 = @min(255, s + (c * keep + 127) / 255);
        out |= v << k;
    }
    return out;
}

/// Lay `layer` over `buf` (`w` x `h`) at `x`, `y`, clipped to the buffer.
pub fn composite(buf: []u32, w: i32, h: i32, layer: *const Layer, x: i32, y: i32) void {
    var ly: i32 = 0;
    while (ly < layer.h) : (ly += 1) {
        const by = y + ly;
        if (by < 0 or by >= h) continue;
        var lx: i32 = 0;
        while (lx < layer.w) : (lx += 1) {
            const bx = x + lx;
            if (bx < 0 or bx >= w) continue;
            const i: usize = @intCast(by * w + bx);
            buf[i] = over(buf[i], layer.px[@intCast(ly * layer.w + lx)]);
        }
    }
}

const testing = std.testing;

fn channelDiff(a: u32, b: u32) u32 {
    var m: u32 = 0;
    var k: u5 = 0;
    while (k < 24) : (k += 8) {
        const x: i32 = @intCast((a >> k) & 0xFF);
        const y: i32 = @intCast((b >> k) & 0xFF);
        m = @max(m, @abs(x - y));
    }
    return m;
}

fn testDesk(buf: []u32, w: usize, h: usize) void {
    for (0..h) |y| for (0..w) |x| {
        const r: u32 = @intCast(30 + (x * 90) / w);
        const g: u32 = @intCast(50 + (y * 70) / h);
        const b: u32 = @intCast(80 + ((x + y) * 60) / (w + h));
        buf[y * w + x] = 0xFF00_0000 | (r << 16) | (g << 8) | b;
    };
}

/// The widest gap, over pixels that are `margin` or more outside every card
/// (`out`) or the same distance inside one (`in`), between the desk compose
/// with its shadows and the shadowless one with each card's layer laid over.
const Gap = struct { out: u32 = 0, edge: u32 = 0, in: u32 = 0 };

fn compareCompose(cards: []const pane_elevation.Card, style: pane_elevation.CardStyle, w: usize, h: usize) !Gap {
    return compareWith(cards, style, w, h, true);
}

fn compareWith(cards: []const pane_elevation.Card, style: pane_elevation.CardStyle, w: usize, h: usize, lay: bool) !Gap {
    const alloc = testing.allocator;
    const want = try alloc.alloc(u32, w * h);
    defer alloc.free(want);
    const got = try alloc.alloc(u32, w * h);
    defer alloc.free(got);
    testDesk(want, w, h);
    @memcpy(got, want);
    pane_elevation.paintCards(want, w, h, cards, style);
    const bare = try alloc.alloc(pane_elevation.Card, cards.len);
    defer alloc.free(bare);
    for (cards, bare) |c, *b| {
        b.* = c;
        b.shadow = 0;
    }
    pane_elevation.paintCards(got, w, h, bare, style);
    var prep = pane_elevation.prepare(style);
    defer prep.deinit();
    if (lay) for (cards) |c| {
        var layer = (try render(alloc, c, style, &prep)) orelse continue;
        defer layer.deinit(alloc);
        const o = layer.origin(c);
        composite(got, @intCast(w), @intCast(h), &layer, o[0], o[1]);
    };
    const radius: f32 = @floatFromInt(pane_elevation.radiusPx(style.scale));
    var gap: Gap = .{};
    for (0..h) |y| for (0..w) |x| {
        var nearest: f32 = std.math.inf(f32);
        for (cards) |c| nearest = @min(nearest, pane_elevation.roundRectDistance(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, c, radius));
        const diff = channelDiff(want[y * w + x], got[y * w + x]);
        if (nearest >= 1.5) gap.out = @max(gap.out, diff) else if (nearest <= -1.5) gap.in = @max(gap.in, diff) else gap.edge = @max(gap.edge, diff);
    };
    return gap;
}

test "T2740: a card's layer over the shadowless desk is the desk compose's shadow" {
    const style: pane_elevation.CardStyle = .{ .fill = .{ .r = 24, .g = 26, .b = 30 }, .is_light = false, .scale = 1.5 };
    // Far enough apart that neither shadow reaches the other card.
    const cards = [_]pane_elevation.Card{
        .{ .left = 40, .top = 30, .right = 210, .bottom = 160 },
        .{ .left = 300, .top = 60, .right = 420, .bottom = 250, .shadow = 0.55 },
    };
    // The comparison can fail: the shadowless desk with no layer over it is
    // far from the baked shadow.
    try testing.expect((try compareWith(&cards, style, 480, 300, false)).out > 20);
    const gap = try compareCompose(&cards, style, 480, 300);
    // On the desk: the two levels the patch already allows itself (T2450),
    // and one more for the compositor's own rounding.
    try testing.expect(gap.out <= 3);
    // Under the card the fill is the same pixels: no shadow reaches it.
    try testing.expectEqual(@as(u32, 0), gap.in);
    // The one-pixel antialiased edge mixes in the other order: the desk has
    // the fill over the plain desk, the layer then darkens the mix by the
    // share the card leaves open, where the baked compose darkened only the
    // desk part. The gap is fill * cov * (1 - cov) * alpha, at most a
    // quarter of the shadow's strength over a light fill (9 levels on a
    // near-white card).
    try testing.expect(gap.edge <= 12);
}

test "T2740: the same holds on a light window and a glass one" {
    const cards = [_]pane_elevation.Card{.{ .left = 50, .top = 40, .right = 230, .bottom = 170 }};
    const light: pane_elevation.CardStyle = .{ .fill = .{ .r = 250, .g = 250, .b = 248 }, .is_light = true, .scale = 1.0 };
    const g1 = try compareCompose(&cards, light, 300, 230);
    try testing.expect(g1.out <= 3 and g1.in == 0 and g1.edge <= 12);
    const glass: pane_elevation.CardStyle = .{ .fill = .{ .r = 20, .g = 22, .b = 28 }, .is_light = false, .scale = 2.0, .glass = true };
    const g2 = try compareCompose(&cards, glass, 300, 230);
    try testing.expect(g2.out <= 3 and g2.in == 0 and g2.edge <= 12);
}

test "T2740: overlapping shadows on the desk multiply, laid one over the other" {
    const style: pane_elevation.CardStyle = .{ .fill = .{ .r = 24, .g = 26, .b = 30 }, .is_light = false, .scale = 1.0 };
    // Side by side across a gap narrower than the reach: the shadows meet in
    // the gap. Only the desk is compared - a neighbour's rim under the other
    // card's layer is the compositor tree's question (T2741), not this one's.
    const cards = [_]pane_elevation.Card{
        .{ .left = 20, .top = 20, .right = 150, .bottom = 140 },
        .{ .left = 162, .top = 20, .right = 290, .bottom = 140 },
    };
    const gap = try compareCompose(&cards, style, 320, 180);
    try testing.expect(gap.out <= 4);
}

test "T2740: a layer depends on the card's size and share, never on where it is" {
    const style: pane_elevation.CardStyle = .{ .fill = .{ .r = 24, .g = 26, .b = 30 }, .is_light = false, .scale = 1.25 };
    const a: pane_elevation.Card = .{ .left = 10, .top = 10, .right = 130, .bottom = 90 };
    const b: pane_elevation.Card = .{ .left = 517, .top = -33, .right = 637, .bottom = 47 };
    try testing.expectEqual(Key.of(a, style), Key.of(b, style));
    var la = (try render(testing.allocator, a, style, null)).?;
    defer la.deinit(testing.allocator);
    var lb = (try render(testing.allocator, b, style, null)).?;
    defer lb.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, la.px, lb.px);
    try testing.expectEqual([2]i32{ 10 - la.reach, 10 - la.reach }, la.origin(a));
    // A new width or share is a new picture.
    var wider = a;
    wider.right += 1;
    try testing.expect(!std.meta.eql(Key.of(a, style), Key.of(wider, style)));
    var fainter = a;
    fainter.shadow = 0.5;
    try testing.expect(!std.meta.eql(Key.of(a, style), Key.of(fainter, style)));
    // Nothing to render for a card that casts nothing.
    fainter.shadow = 0;
    try testing.expect((try render(testing.allocator, fainter, style, null)) == null);
}

test "T2740: the layer is clear under the card, darkest just below it, and gone at its reach" {
    const style: pane_elevation.CardStyle = .{ .fill = .{ .r = 24, .g = 26, .b = 30 }, .is_light = false, .scale = 1.0 };
    const card: pane_elevation.Card = .{ .left = 0, .top = 0, .right = 200, .bottom = 120 };
    var l = (try render(testing.allocator, card, style, null)).?;
    defer l.deinit(testing.allocator);
    const r = l.reach;
    try testing.expectEqual(@as(i32, 200 + 2 * r), l.w);
    try testing.expectEqual(@as(i32, 120 + 2 * r), l.h);
    // Under the middle of the card, and in from its corners.
    try testing.expectEqual(@as(u8, 0), l.alphaAt(r + 100, r + 60));
    try testing.expectEqual(@as(u8, 0), l.alphaAt(r + 20, r + 20));
    // Below the card's bottom edge the shadow is stronger than above its top
    // (it falls downwards) and fades out towards the reach.
    const below = l.alphaAt(r + 100, r + 121);
    const above = l.alphaAt(r + 100, r - 2);
    try testing.expect(below > 0);
    try testing.expect(below > above);
    try testing.expect(l.alphaAt(r + 100, l.h - 1) < below);
    try testing.expectEqual(@as(u8, 0), l.alphaAt(0, 0));
    // Black, premultiplied: nothing in the colour channels.
    for (l.px) |p| try testing.expectEqual(@as(u32, 0), p & 0x00FF_FFFF);
}

test "T2740: over() is darken - premultiplied black scales what is under it" {
    try testing.expectEqual(@as(u32, 0xFF20_4080), over(0xFF20_4080, 0));
    try testing.expectEqual(@as(u32, 0xFF00_0000), over(0xFF20_4080, 0xFF00_0000));
    const half = over(0xFF80_4020, 0x8000_0000);
    try testing.expect(channelDiff(half, 0xFF40_2010) <= 1);
}
