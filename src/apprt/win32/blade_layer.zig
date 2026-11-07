//! A stack strip's blade shadow as a picture of its own (T2743, the blade
//! half of T2511): what the compositor can lay over the desk and move, in
//! place of the shadow `blade_shadow.paint` bakes into the desk compose.
//!
//! The same trick as a card's (`shadow_layer`, T2740): the blade shadow only
//! ever pulls the pixel under it toward black by its alpha, which is exactly
//! premultiplied black at that alpha laid over the pixel. So the layer is
//! the blade's shadow painted over white with the alpha read back out.
//!
//! Two things differ from a card's layer:
//!
//! - **What it is kept off.** On the desk each blade's shadow goes down just
//!   before its own band, so it lands on every band BEHIND it (that is the
//!   point: it is cast onto the blade it lies against) and never on a band IN
//!   FRONT of it, which is laid over it afterwards. A layer laid over a desk
//!   that already holds every band would darken those front bands, so the
//!   layer is cleared under each of them by the band's own coverage
//!   (`pane_stack_strip.bandCoverage` at `bandRadius`, the band's exact
//!   shape). Its own band needs nothing: the shadow is outside its shape.
//! - **It depends on the collapse.** A card gliding into or out of its strip
//!   casts this shadow at its collapse (how far into the strip it is), which
//!   sets its blur, strength, lean and how far in its ends start - so the key
//!   carries it, and a card narrowing into its strip is a new layer each
//!   step. A resting strip's collapse is 1 and never changes.
//!
//! The layer is measured from the strip's own corner (as `blade_shadow.paint`
//! is since T2732), so it never depends on where the strip is: a strip that
//! moves along with the bands in front of it keeps its layer.
//!
//! Pure, so the tests need no window.

const std = @import("std");
const blade_shadow = @import("blade_shadow.zig");
const shadow_layer = @import("shadow_layer.zig");
const desk_palette = @import("desk_palette.zig");
const color_math = @import("color_math.zig");
const pane_stack_strip = @import("pane_stack_strip.zig");
const Direction = @import("pane_stack_layout.zig").Direction;

const Rect = pane_stack_strip.Rect;

/// A rendered blade layer: premultiplied BGRA black (alpha = how much of
/// what is under it the shadow takes away), `w` x `h`, top-down. Its
/// top-left sits `reach` pixels above and left of the strip's.
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

    /// Where the layer goes for a strip at `tab`, in the strip's coordinates.
    pub fn origin(self: *const Layer, tab: Rect) [2]i32 {
        return .{ tab.left - self.reach, tab.top - self.reach };
    }

    pub fn alphaAt(self: *const Layer, x: i32, y: i32) u8 {
        return @truncate(self.px[@intCast(y * self.w + x)] >> 24);
    }

    /// `shadow_layer.composite`'s view of it: the same premultiplied pixels.
    pub fn asShadow(self: *const Layer) shadow_layer.Layer {
        return .{ .px = self.px, .w = self.w, .h = self.h, .reach = self.reach, .key = undefined };
    }
};

/// Everything a blade layer's pixels depend on. A strip whose key is
/// unchanged keeps its layer, wherever it has moved to.
pub const Key = struct {
    w: i32,
    h: i32,
    axis: Direction,
    leads: bool,
    collapse: f32,
    is_light: bool,
    scale: f32,
    /// The card corner radius the strips are drawn with, in pixels.
    radius: i32,
    /// The bands in front of this strip it reaches, relative to its top-left.
    mask: Mask = .{},

    pub fn of(s: pane_stack_strip.Band, is_light: bool, scale: f32, radius: i32) Key {
        return .{
            .w = s.tab.width(),
            .h = s.tab.height(),
            .axis = s.axis,
            .leads = s.leads,
            .collapse = std.math.clamp(s.collapse, 0, 1),
            .is_light = is_light,
            .scale = scale,
            .radius = radius,
        };
    }

    /// The key for `strips[i]`, kept off every band laid after it (in front
    /// of it, `strips` bottom first as the desk lays them) that it reaches.
    pub fn inStack(strips: []const pane_stack_strip.Band, i: usize, is_light: bool, scale: f32, radius: i32) Key {
        var k = of(strips[i], is_light, scale, radius);
        k.mask = Mask.of(strips[i].tab, strips[i + 1 ..], k.reach());
        return k;
    }

    /// How far past the strip's rect the shadow reaches at this collapse:
    /// `blade_shadow.paint`'s own bound.
    pub fn reach(self: Key) i32 {
        const p = blade_shadow.params(self.collapse, self.is_light, self.scale);
        return @intFromFloat(@ceil(3 * p.sigma + p.lean) + 1);
    }

    /// Whether the strip casts anything at all.
    pub fn casts(self: Key) bool {
        if (self.w <= 0 or self.h <= 0 or self.collapse <= 0) return false;
        return blade_shadow.params(self.collapse, self.is_light, self.scale).opacity > 0;
    }
};

/// The bands in front of a strip that its layer reaches, relative to the
/// strip's top-left: only where they lie next to it matters, so a stack that
/// moves together keeps its layers. A card still gliding (`band` false) lays
/// no band, so it masks nothing.
pub const Mask = struct {
    pub const max = 8;
    pub const Rel = struct { left: i32, top: i32, right: i32, bottom: i32, axis: Direction };
    n: u8 = 0,
    r: [max]Rel = [_]Rel{.{ .left = 0, .top = 0, .right = 0, .bottom = 0, .axis = .horizontal }} ** max,

    pub fn of(tab: Rect, front: []const pane_stack_strip.Band, reach: i32) Mask {
        var m: Mask = .{};
        for (front) |f| {
            if (m.n >= max) break;
            if (!f.band) continue;
            const o = f.tab;
            if (o.right <= o.left or o.bottom <= o.top) continue;
            if (o.right <= tab.left - reach or o.left >= tab.right + reach or
                o.bottom <= tab.top - reach or o.top >= tab.bottom + reach) continue;
            m.r[m.n] = .{ .left = o.left - tab.left, .top = o.top - tab.top, .right = o.right - tab.left, .bottom = o.bottom - tab.top, .axis = f.axis };
            m.n += 1;
        }
        return m;
    }

    pub fn slice(self: *const Mask) []const Rel {
        return self.r[0..self.n];
    }
};

/// The layer `key` describes. Null when the strip casts nothing.
pub fn render(alloc: std.mem.Allocator, key: Key) error{OutOfMemory}!?Layer {
    if (!key.casts()) return null;
    const reach = key.reach();
    const lw = key.w + 2 * reach;
    const lh = key.h + 2 * reach;
    const px = try alloc.alloc(u32, @intCast(lw * lh));
    errdefer alloc.free(px);
    const white = desk_palette.packRgb(255, 255, 255);
    @memset(px, white);
    const at: Rect = .{ .left = reach, .top = reach, .right = reach + key.w, .bottom = reach + key.h };
    blade_shadow.paint(px, @intCast(lw), @intCast(lh), at, key.axis, key.leads, key.collapse, key.is_light, key.scale, key.radius);
    // White under the shadow: every channel is 255 * (1 - a).
    for (px) |*p| p.* = @as(u32, 255 - ((p.* >> 8) & 0xFF)) << 24;
    for (key.mask.slice()) |o| {
        const tab: Rect = .{ .left = reach + o.left, .top = reach + o.top, .right = reach + o.right, .bottom = reach + o.bottom };
        clearUnderBand(px, lw, lh, tab, o.axis, pane_stack_strip.bandRadius(tab, o.axis, key.radius));
    }
    return .{ .px = px, .w = lw, .h = lh, .reach = reach, .key = key };
}

/// Clear the layer by a band's coverage where the band at `tab` (in the
/// layer's own pixels) lies, clipped to the layer.
fn clearUnderBand(px: []u32, lw: i32, lh: i32, tab: Rect, axis: Direction, rad: i32) void {
    var y = @max(tab.top, 0);
    while (y < @min(tab.bottom, lh)) : (y += 1) {
        var x = @max(tab.left, 0);
        while (x < @min(tab.right, lw)) : (x += 1) {
            const i: usize = @intCast(y * lw + x);
            if (px[i] == 0) continue;
            const cov = pane_stack_strip.bandCoverage(tab, axis, rad, x, y);
            if (cov >= 1) {
                px[i] = 0;
                continue;
            }
            const a: f32 = @floatFromInt(px[i] >> 24);
            px[i] = @as(u32, @intFromFloat(@round(a * (1 - cov)))) << 24;
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
        const r: u32 = @intCast(40 + (x * 150) / w);
        const g: u32 = @intCast(60 + (y * 140) / h);
        const b: u32 = @intCast(90 + ((x + y) * 120) / (w + h));
        buf[y * w + x] = 0xFF00_0000 | (r << 16) | (g << 8) | b;
    };
}

/// The widest gap between the desk compose that bakes every blade shadow
/// (each before its own band, bottom first) and the shadowless compose with
/// each strip's layer laid over it: off every band by 2 px or more (`out`),
/// 2 px or more inside one (`in`), and the antialiased edge between.
const Gap = struct { out: u32 = 0, edge: u32 = 0, in: u32 = 0, laid: u32 = 0 };

fn compare(strips: []const pane_stack_strip.Band, is_light: bool, scale: f32, radius: i32, w: usize, h: usize, mask: bool) !Gap {
    const alloc = testing.allocator;
    const want = try alloc.alloc(u32, w * h);
    defer alloc.free(want);
    const got = try alloc.alloc(u32, w * h);
    defer alloc.free(got);
    testDesk(want, w, h);
    @memcpy(got, want);
    for (strips) |s| {
        blade_shadow.paint(want, w, h, s.tab, s.axis, s.leads, s.collapse, is_light, scale, radius);
        if (s.band) pane_stack_strip.paintBand(want, w, h, s.tab, s.axis, s.rgb, radius);
    }
    for (strips) |s| if (s.band) pane_stack_strip.paintBand(got, w, h, s.tab, s.axis, s.rgb, radius);
    var gap: Gap = .{};
    for (strips, 0..) |s, i| {
        const key = if (mask) Key.inStack(strips, i, is_light, scale, radius) else Key.of(s, is_light, scale, radius);
        var layer = (try render(alloc, key)) orelse continue;
        defer layer.deinit(alloc);
        gap.laid += 1;
        const o = layer.origin(s.tab);
        var as = layer.asShadow();
        shadow_layer.composite(got, @intCast(w), @intCast(h), &as, o[0], o[1]);
    }
    for (0..h) |yu| for (0..w) |xu| {
        const x: i32 = @intCast(xu);
        const y: i32 = @intCast(yu);
        var near = false;
        var deep = false;
        for (strips) |s| {
            if (!s.band) continue;
            const t = s.tab;
            if (x >= t.left - 2 and x < t.right + 2 and y >= t.top - 2 and y < t.bottom + 2) near = true;
            const rad = pane_stack_strip.bandRadius(t, s.axis, radius);
            if (x >= t.left + 2 and x < t.right - 2 and y >= t.top + 2 and y < t.bottom - 2 and
                pane_stack_strip.bandCoverage(.{ .left = t.left + 2, .top = t.top + 2, .right = t.right - 2, .bottom = t.bottom - 2 }, s.axis, @max(0, rad - 2), x, y) >= 1) deep = true;
        }
        const d = channelDiff(want[yu * w + xu], got[yu * w + xu]);
        if (deep) gap.in = @max(gap.in, d) else if (!near) gap.out = @max(gap.out, d) else gap.edge = @max(gap.edge, d);
    };
    return gap;
}

/// Three strips of a horizontal stack before its run, each tucked 6 px under
/// the next one out (the run to the right, so each leans left onto the one
/// behind it).
fn horizontalStack(collapse_last: f32, band_last: bool) [3]pane_stack_strip.Band {
    const rgb: color_math.Rgb = .{ .r = 58, .g = 61, .b = 68 };
    return .{
        .{ .tab = .{ .left = 40, .top = 30, .right = 74, .bottom = 230 }, .axis = .horizontal, .rgb = rgb },
        .{ .tab = .{ .left = 68, .top = 30, .right = 102, .bottom = 230 }, .axis = .horizontal, .rgb = rgb },
        .{ .tab = .{ .left = 96, .top = 30, .right = 130, .bottom = 230 }, .axis = .horizontal, .rgb = rgb, .collapse = collapse_last, .band = band_last },
    };
}

test "T2743: a stack's blade layers over the shadowless desk are the baked blade shadows" {
    const strips = horizontalStack(1, true);
    {
        const alloc = testing.allocator;
        var layer = (try render(alloc, Key.inStack(&strips, 0, false, 1.5, 12))).?;
        defer layer.deinit(alloc);
        // It does darken: the strip's outer side, away from the run.
        try testing.expect(layer.alphaAt(layer.reach - 2, @divTrunc(layer.h, 2)) > 30);
    }
    for ([_]bool{ false, true }) |light| for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const gap = try compare(&strips, light, scale, @intFromFloat(@round(8 * scale)), 200, 260, true);
        try testing.expectEqual(@as(u32, 3), gap.laid);
        // Off the bands: the desk's own rounding and the compositor's.
        try testing.expect(gap.out <= 2);
        // Inside a band - the one each shadow lands on included - the same.
        try testing.expect(gap.in <= 2);
        // The antialiased edge mixes in the other order (as a card's does,
        // T2740): the baked compose shades only the desk part of an edge
        // pixel, the layer the band's part too where it lands on a band
        // behind.
        try testing.expect(gap.edge <= 12);
    };
}

test "T2743: without the mask a layer darkens the band in front of it" {
    // A pale band shows the shadow's tail best: it leans away from the run,
    // so what crosses onto the band in front is only the blur's far side.
    var strips = horizontalStack(1, true);
    for (&strips) |*s| s.rgb = .{ .r = 236, .g = 238, .b = 240 };
    const unmasked = try compare(&strips, false, 2, 16, 220, 280, false);
    const masked = try compare(&strips, false, 2, 16, 220, 280, true);
    // Measured: unmasked 7, masked 3 (the 3 is rounding on a band this pale,
    // where the shadow lands on the band BEHIND, as it should).
    try testing.expect(unmasked.in >= masked.in + 3);
    try testing.expect(masked.in <= 3);
}

test "T2743: a vertical stack after its run, light" {
    const rgb: color_math.Rgb = .{ .r = 226, .g = 228, .b = 232 };
    const strips = [_]pane_stack_strip.Band{
        .{ .tab = .{ .left = 30, .top = 140, .right = 250, .bottom = 170 }, .axis = .vertical, .rgb = rgb, .leads = false },
        .{ .tab = .{ .left = 30, .top = 114, .right = 250, .bottom = 146 }, .axis = .vertical, .rgb = rgb, .leads = false },
    };
    const gap = try compare(&strips, true, 1.25, 10, 280, 220, true);
    try testing.expectEqual(@as(u32, 2), gap.laid);
    try testing.expect(gap.out <= 2);
    try testing.expect(gap.in <= 2);
    try testing.expect(gap.edge <= 12);
}

test "T2743: a card gliding into its strip casts its layer at its collapse, and masks nothing" {
    // The last one out is still a card part way in: no band, its shadow at
    // collapse 0.4, over the two bands behind it.
    const strips = horizontalStack(0.4, false);
    const gap = try compare(&strips, false, 1.5, 12, 200, 260, true);
    try testing.expectEqual(@as(u32, 3), gap.laid);
    try testing.expect(gap.out <= 2);
    try testing.expect(gap.in <= 2);
    try testing.expect(gap.edge <= 12);
    // It is no band, so the strip behind it keeps nothing off it.
    const k1 = Key.inStack(&strips, 1, false, 1.5, 12);
    try testing.expectEqual(@as(u8, 0), k1.mask.n);
    // A card with no collapse yet casts no blade shadow at all.
    try testing.expect(!Key.of(horizontalStack(0, false)[2], false, 1.5, 12).casts());
}

test "T2743: the key never depends on where the stack is; the collapse and a front band's place do" {
    const a = horizontalStack(1, true);
    var b = a;
    for (&b) |*s| {
        s.tab.left += 311;
        s.tab.right += 311;
        s.tab.top -= 17;
        s.tab.bottom -= 17;
    }
    const ka = Key.inStack(&a, 0, false, 1.5, 12);
    const kb = Key.inStack(&b, 0, false, 1.5, 12);
    try testing.expect(std.meta.eql(ka, kb));
    // Same key, same pixels.
    const alloc = testing.allocator;
    var la = (try render(alloc, ka)).?;
    defer la.deinit(alloc);
    var lb = (try render(alloc, kb)).?;
    defer lb.deinit(alloc);
    try testing.expectEqualSlices(u32, la.px, lb.px);
    // The band in front moved alone: a new key.
    var c = a;
    c[1].tab.left += 3;
    c[1].tab.right += 3;
    try testing.expect(!std.meta.eql(ka, Key.inStack(&c, 0, false, 1.5, 12)));
    // A new collapse: a new key (a gliding card re-renders).
    var g = Key.of(a[2], false, 1.5, 12);
    g.collapse = 0.7;
    try testing.expect(!std.meta.eql(Key.of(a[2], false, 1.5, 12), g));
    // The front-most strip keeps nothing off.
    try testing.expectEqual(@as(u8, 0), Key.inStack(&a, 2, false, 1.5, 12).mask.n);
}
