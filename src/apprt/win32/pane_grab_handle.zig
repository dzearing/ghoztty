//! The hover grab handle at the top of a pane (T1830), as rules and pixels.
//! No OS imports, so every number here is asserted in every app-runtime lane;
//! the window half is `PaneGrabHandle.zig`.
//!
//! Mac parity: `PaneGrabHandle` in `SurfaceGrabHandle.swift` (597a193cc,
//! bba09ae7d, a235110ff). Any pane — a terminal or a viewer — reveals a grip
//! centered at its top edge while the pointer is in the pane's top band, and
//! dragging the grip moves the pane through the same drop resolver rearrange
//! mode uses (into a split, onto a tab, out to a window, onto the pane
//! sidebar). Before this, Windows could only drag a pane from its
//! rearrange-mode header, and a viewer pane had no way to be dragged at all.
//!
//! Two states, so the grip reads as the thing you are about to grab:
//!
//!   * `hinted` — the pointer is in the pane's top band: a translucent capsule
//!     with dimmed dots.
//!   * `engaged` — the pointer is ON the grip, or the grip is being dragged: a
//!     solid capsule a shade off the pane background, full-strength dots and a
//!     slight shadow.
//!
//! Sizes are Mac's, moved onto the 4 DIP grid where Mac's are off it (the
//! capsule is 46x14pt there, 48x16 DIP here) and inset so the grip does not
//! touch the pane's top edge (Mac lets it overhang by 3pt; the design system's
//! "nothing touches anything" rule does not).

const std = @import("std");
const color_math = @import("color_math.zig");
const card = @import("banner_card.zig");

const Rgb = color_math.Rgb;

/// The drag surface: Mac's `handleSize.width`. Taller than Mac's 12pt because
/// the grip sits inside the pane here rather than overhanging its edge, and
/// the hit box has to cover the grip plus its inset above and below.
pub const HIT_W: f32 = 80.0;
pub const HIT_H: f32 = 24.0;
/// The painted capsule.
pub const GRIP_W: f32 = 48.0;
pub const GRIP_H: f32 = 16.0;
/// From the pane's top edge to the capsule's.
pub const GRIP_TOP: f32 = 4.0;
/// The three dots (Mac's `ellipsis` glyph).
pub const DOT: f32 = 4.0;
pub const DOT_GAP: f32 = 4.0;
/// Mac `hoverHeightFactor`: the band is the top fifth of the pane.
pub const BAND_FACTOR: f32 = 0.2;
/// Mac's engaged shadow: `.shadow(color: .black.opacity(0.35), radius: 2, y: 1)`.
pub const SHADOW_BLUR: f32 = 2.0;
pub const SHADOW_DY: f32 = 1.0;
pub const SHADOW_ALPHA: f32 = 0.35;

/// Mac's hinted capsule: `Color.gray.opacity(0.22)`.
pub const HINT_FILL_ALPHA: f32 = 0.22;
pub const HINT_FILL = Rgb{ .r = 128, .g = 128, .b = 128 };
/// Mac's hinted dots: `Color.primary.opacity(0.6)`.
pub const HINT_DOT_ALPHA: f32 = 0.6;
/// The dots on the solid capsule are chrome glyphs: 3:1 against it.
pub const DOT_CONTRAST: f64 = 3.0;

/// Coverage of every hit-box pixel the grip does not paint. Zero-alpha pixels
/// of a layered window are click-through, so a hit box drawn at alpha 0 would
/// shrink to the capsule; one step above zero is invisible and still catches
/// the press.
pub const HIT_ALPHA: u8 = 1;

/// Every metric in physical pixels at one DPI scale.
pub const Metrics = struct {
    scale: f32,
    hit_w: i32,
    hit_h: i32,
    grip_w: i32,
    grip_h: i32,
    grip_top: i32,
    dot: i32,
    dot_gap: i32,
    shadow_blur: i32,
    shadow_dy: i32,

    pub fn forScale(scale: f32) Metrics {
        const s = @max(scale, 0.1);
        return .{
            .scale = s,
            .hit_w = px(HIT_W, s),
            .hit_h = px(HIT_H, s),
            .grip_w = px(GRIP_W, s),
            .grip_h = px(GRIP_H, s),
            .grip_top = px(GRIP_TOP, s),
            .dot = px(DOT, s),
            .dot_gap = px(DOT_GAP, s),
            .shadow_blur = px(SHADOW_BLUR, s),
            .shadow_dy = px(SHADOW_DY, s),
        };
    }
};

fn px(v: f32, scale: f32) i32 {
    return @max(@as(i32, @intFromFloat(@round(v * scale))), 1);
}

/// An integer rect, right/bottom exclusive.
pub const Rect = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }
    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }
};

/// The band at the top of `pane` that reveals the grip: full width, the top
/// fifth of the pane, and never shorter than the hit box (Mac
/// `PaneGrabHandle.hoverRect`). Empty for an empty pane.
pub fn band(pane: Rect, m: Metrics) Rect {
    const h = pane.height();
    if (h <= 0 or pane.width() <= 0) return .{};
    const fifth: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(h)) * BAND_FACTOR));
    const bh = @min(h, @max(m.hit_h, fifth));
    return .{ .left = pane.left, .top = pane.top, .right = pane.right, .bottom = pane.top + bh };
}

/// Where the handle goes for a pane at `pane`.
pub const Layout = struct {
    /// The handle window (the hit box), in the pane's coordinate space.
    win: Rect,
    /// The capsule, in the handle window's own coordinates.
    grip: Rect,
};

/// The handle for `pane`, or null when the pane is too small to carry one: a
/// pane narrower than the hit box, or so short the band would be most of it.
pub fn layout(pane: Rect, m: Metrics) ?Layout {
    if (pane.width() < m.hit_w) return null;
    if (pane.height() < m.hit_h * 2) return null;
    const left = pane.left + @divFloor(pane.width() - m.hit_w, 2);
    const win: Rect = .{
        .left = left,
        .top = pane.top,
        .right = left + m.hit_w,
        .bottom = pane.top + m.hit_h,
    };
    const gl = @divFloor(m.hit_w - m.grip_w, 2);
    return .{
        .win = win,
        .grip = .{
            .left = gl,
            .top = m.grip_top,
            .right = gl + m.grip_w,
            .bottom = m.grip_top + m.grip_h,
        },
    };
}

/// What the handle shows.
pub const State = enum { hidden, hinted, engaged };

pub const Inputs = struct {
    /// The pointer is showing. A terminal hides it while you type, and Mac
    /// never shows the handle then — not even mid-drag.
    cursor_visible: bool,
    /// Something else owns the pane's top edge right now (see `suppressed`).
    suppressed: bool = false,
    pointer_in_band: bool = false,
    /// The pointer is on the handle itself.
    over_handle: bool = false,
    /// This pane is being dragged from its handle.
    dragging: bool = false,
};

/// Mac `PaneGrabHandle.reveals` plus its two states.
pub fn state(in: Inputs) State {
    if (!in.cursor_visible or in.suppressed) return .hidden;
    if (in.over_handle or in.dragging) return .engaged;
    if (in.pointer_in_band) return .hinted;
    return .hidden;
}

/// Whether a window shows grab handles at all right now.
///
/// Mac `SurfaceGrabHandle.handleVisible`: always, except a fullscreen window
/// with a single pane — there is nowhere to drag it to that fullscreen is not
/// already hiding. Two Windows-only cases join it: rearrange mode, where every
/// pane already wears a header that drags (two grips on one edge is one too
/// many), and a hero tab, whose panes are a carousel rather than a grid.
pub fn suppressed(rearrange_mode: bool, hero: bool, fullscreen: bool, panes: usize) bool {
    if (rearrange_mode or hero) return true;
    return fullscreen and panes <= 1;
}

/// How often the pointer is sampled while it is over the window, and for how
/// many still samples a terminal-only window keeps sampling.
///
/// The sample exists because a viewer's page is another process's window:
/// moving from the page into the band (or out of it) raises nothing this
/// process can see, the way Mac's tracking area over the web view does. Over
/// a terminal every move IS seen, so once the pointer has been still for a
/// while the timer stops and the next move restarts it — a terminal you are
/// only typing into costs nothing.
pub const poll_ms: u32 = 50;
pub const idle_ticks: u32 = 10;

pub fn keepPolling(shown: bool, over_window: bool, over_viewer: bool, still_ticks: u32) bool {
    if (shown) return true;
    if (!over_window) return false;
    if (over_viewer) return true;
    return still_ticks < idle_ticks;
}

// ---------------------------------------------------------------------------
// Colors

/// Mac `solidFill`: the pane background lifted (or, on a light theme, sunk)
/// far enough to stand off it.
pub fn solidFill(pane_bg: Rgb) Rgb {
    return if (color_math.isLight(pane_bg))
        color_math.darken(pane_bg, 0.14)
    else
        color_math.lighten(pane_bg, 0.22);
}

/// The dots' full-strength color (Mac `Color.primary`): the better of black
/// and white against the pane, moved further only if the solid capsule needs
/// it to clear the chrome-glyph floor.
pub fn dotColor(pane_bg: Rgb) Rgb {
    const fill = solidFill(pane_bg);
    const base = color_math.contrastForeground(pane_bg);
    if (ratio(base, fill) >= DOT_CONTRAST) return base;
    return color_math.contrastForeground(fill);
}

fn ratio(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(color_math.wcagLuminance(a), color_math.wcagLuminance(b));
}

// ---------------------------------------------------------------------------
// Pixels

/// Paint the handle for `st` into a top-down premultiplied BGRA surface the
/// size of `l.win` (what `UpdateLayeredWindow` takes). Every pixel of the hit
/// box is written: the grip where it paints, `HIT_ALPHA` everywhere else.
pub fn render(px_out: []u32, m: Metrics, l: Layout, st: State, pane_bg: Rgb) void {
    const w: usize = @intCast(@max(l.win.width(), 0));
    const h: usize = @intCast(@max(l.win.height(), 0));
    if (w == 0 or h == 0 or px_out.len < w * h) return;

    const engaged = st == .engaged;
    const fill = if (engaged) solidFill(pane_bg) else HINT_FILL;
    const fill_a: f32 = if (engaged) 1.0 else HINT_FILL_ALPHA;
    const dot = dotColor(pane_bg);
    const dot_a: f32 = if (engaged) 1.0 else HINT_DOT_ALPHA;

    const g = card.Rect{
        .left = @floatFromInt(l.grip.left),
        .top = @floatFromInt(l.grip.top),
        .right = @floatFromInt(l.grip.right),
        .bottom = @floatFromInt(l.grip.bottom),
    };
    const radius = (g.bottom - g.top) / 2.0;
    const dy: f32 = @floatFromInt(m.shadow_dy);
    const blur: f32 = @floatFromInt(@max(m.shadow_blur, 1));
    const shadow = card.Rect{ .left = g.left, .top = g.top + dy, .right = g.right, .bottom = g.bottom + dy };

    // Three dots, centered in the capsule.
    const d: f32 = @floatFromInt(m.dot);
    const step: f32 = d + @as(f32, @floatFromInt(m.dot_gap));
    const cx = (g.left + g.right) / 2.0;
    const cy = (g.top + g.bottom) / 2.0;
    const r = d / 2.0;

    for (0..h) |row| {
        const y = @as(f32, @floatFromInt(row)) + 0.5;
        for (0..w) |col| {
            const x = @as(f32, @floatFromInt(col)) + 0.5;
            const i = row * w + col;

            const cov = cov1(card.sdRoundRect(x, y, g, radius)) * fill_a;
            var dots: f32 = 0;
            inline for (.{ -1.0, 0.0, 1.0 }) |k| {
                const dx = x - (cx + k * step);
                const ddy = y - cy;
                dots = @max(dots, cov1(@sqrt(dx * dx + ddy * ddy) - r));
            }
            dots *= dot_a;

            var shade: f32 = 0;
            if (engaged) {
                const body = cov1(card.sdRoundRect(x, y, g, radius));
                if (body < 1.0) {
                    const sds = card.sdRoundRect(x, y, shadow, radius);
                    shade = SHADOW_ALPHA * (1.0 - smooth(-blur, blur, sds)) * (1.0 - body);
                }
            }

            // Back to front: shadow (black), capsule, dots - premultiplied
            // "over" each time.
            var pr: f32 = 0;
            var pg: f32 = 0;
            var pb: f32 = 0;
            var pa: f32 = shade;
            over(&pr, &pg, &pb, &pa, fill, cov);
            over(&pr, &pg, &pb, &pa, dot, dots);

            var a8: u32 = @intFromFloat(@round(std.math.clamp(pa, 0, 1) * 255.0));
            if (a8 < HIT_ALPHA) {
                px_out[i] = @as(u32, HIT_ALPHA) << 24;
                continue;
            }
            if (a8 > 255) a8 = 255;
            px_out[i] = (a8 << 24) |
                (ch(pr) << 16) |
                (ch(pg) << 8) |
                ch(pb);
        }
    }
}

fn over(r: *f32, g: *f32, b: *f32, a: *f32, c: Rgb, alpha: f32) void {
    if (alpha <= 0) return;
    const k = 1.0 - alpha;
    r.* = @as(f32, @floatFromInt(c.r)) / 255.0 * alpha + r.* * k;
    g.* = @as(f32, @floatFromInt(c.g)) / 255.0 * alpha + g.* * k;
    b.* = @as(f32, @floatFromInt(c.b)) / 255.0 * alpha + b.* * k;
    a.* = alpha + a.* * k;
}

fn ch(v: f32) u32 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
}

fn cov1(sd: f32) f32 {
    return std.math.clamp(0.5 - sd, 0.0, 1.0);
}

fn smooth(e0: f32, e1: f32, x: f32) f32 {
    if (e1 <= e0) return if (x < e0) 0.0 else 1.0;
    const t = std.math.clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "T1830: the reveal rule is Mac's, and a hidden pointer hides everything" {
    try testing.expectEqual(State.hidden, state(.{ .cursor_visible = true }));
    try testing.expectEqual(State.hinted, state(.{ .cursor_visible = true, .pointer_in_band = true }));
    try testing.expectEqual(State.engaged, state(.{ .cursor_visible = true, .over_handle = true }));
    try testing.expectEqual(State.engaged, state(.{ .cursor_visible = true, .dragging = true }));
    // On the handle beats merely being in the band.
    try testing.expectEqual(State.engaged, state(.{ .cursor_visible = true, .pointer_in_band = true, .over_handle = true }));
    // Typing hides the pointer, and the handle with it - even mid-drag.
    try testing.expectEqual(State.hidden, state(.{ .cursor_visible = false, .pointer_in_band = true, .over_handle = true, .dragging = true }));
    try testing.expectEqual(State.hidden, state(.{ .cursor_visible = true, .suppressed = true, .pointer_in_band = true }));
}

test "T1830: fullscreen with one pane, rearrange mode and hero tabs show no handle" {
    try testing.expect(!suppressed(false, false, false, 1));
    try testing.expect(!suppressed(false, false, true, 2));
    try testing.expect(suppressed(false, false, true, 1));
    try testing.expect(suppressed(true, false, false, 3));
    try testing.expect(suppressed(false, true, false, 3));
}

test "T1830: the band is the top fifth, never shorter than the hit box, never taller than the pane" {
    for (scales) |s| {
        const m = Metrics.forScale(s);
        const tall: Rect = .{ .left = 10, .top = 20, .right = 810, .bottom = 1020 };
        const b = band(tall, m);
        try testing.expectEqual(tall.top, b.top);
        try testing.expectEqual(tall.left, b.left);
        try testing.expectEqual(tall.right, b.right);
        try testing.expectEqual(@as(i32, 200), b.height());
        const short: Rect = .{ .left = 0, .top = 0, .right = 400, .bottom = m.hit_h * 3 };
        try testing.expectEqual(m.hit_h, band(short, m).height());
        const tiny: Rect = .{ .left = 0, .top = 0, .right = 400, .bottom = 5 };
        try testing.expectEqual(@as(i32, 5), band(tiny, m).height());
        try testing.expectEqual(@as(i32, 0), band(.{}, m).height());
    }
}

test "T1830: the handle is centered at the pane's top edge, the grip inside it" {
    for (scales) |s| {
        const m = Metrics.forScale(s);
        const pane: Rect = .{ .left = 100, .top = 50, .right = 901, .bottom = 650 };
        const l = layout(pane, m).?;
        try testing.expectEqual(pane.top, l.win.top);
        try testing.expectEqual(m.hit_w, l.win.width());
        try testing.expectEqual(m.hit_h, l.win.height());
        const left_gap = l.win.left - pane.left;
        const right_gap = pane.right - l.win.right;
        try testing.expect(@abs(left_gap - right_gap) <= 1);
        // The grip is centered in the hit box and inside it with room to spare.
        try testing.expect(@abs(l.grip.left - (l.win.width() - l.grip.right)) <= 1);
        try testing.expect(l.grip.top >= 1);
        try testing.expect(l.grip.bottom < l.win.height());
        // And it lies inside the band, so revealing it never needs the pointer
        // somewhere it cannot be.
        try testing.expect(l.win.top + l.grip.bottom <= band(pane, m).bottom);
    }
}

test "T1830: the grip never touches the pane's top edge (design system: >= 4 DIP)" {
    for (scales) |s| {
        const m = Metrics.forScale(s);
        const l = layout(.{ .right = 800, .bottom = 600 }, m).?;
        try testing.expect(@as(f32, @floatFromInt(l.grip.top)) >= @round(4.0 * s));
    }
}

test "T1830: a pane too small for a handle gets none" {
    const m = Metrics.forScale(1.0);
    try testing.expect(layout(.{ .right = m.hit_w - 1, .bottom = 600 }, m) == null);
    try testing.expect(layout(.{ .right = m.hit_w, .bottom = 600 }, m) != null);
    try testing.expect(layout(.{ .right = 600, .bottom = m.hit_h * 2 - 1 }, m) == null);
    try testing.expect(layout(.{ .right = 600, .bottom = m.hit_h * 2 }, m) != null);
}

test "T1830: polling stops on a still terminal and runs over a page it cannot hear" {
    try testing.expect(keepPolling(true, false, false, 99));
    try testing.expect(!keepPolling(false, false, true, 0));
    try testing.expect(keepPolling(false, true, true, 99));
    try testing.expect(keepPolling(false, true, false, idle_ticks - 1));
    try testing.expect(!keepPolling(false, true, false, idle_ticks));
}

test "T1830: the solid capsule stands off the pane, and its dots clear 3:1" {
    const bgs = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 40, .g = 44, .b = 52 },
        .{ .r = 128, .g = 128, .b = 128 },
        .{ .r = 200, .g = 200, .b = 200 },
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 0, .g = 43, .b = 54 },
    };
    for (bgs) |bg| {
        const fill = solidFill(bg);
        try testing.expect(!std.meta.eql(fill, bg));
        try testing.expect(ratio(dotColor(bg), fill) >= DOT_CONTRAST);
        // Dark backgrounds lift, light ones sink (Mac `isLightColor`).
        if (color_math.isLight(bg))
            try testing.expect(color_math.luminance(fill) < color_math.luminance(bg))
        else
            try testing.expect(color_math.luminance(fill) > color_math.luminance(bg));
    }
}

fn renderFor(st: State, bg: Rgb, buf: []u32) Layout {
    const m = Metrics.forScale(1.0);
    const l = layout(.{ .right = 800, .bottom = 600 }, m).?;
    render(buf, m, l, st, bg);
    return l;
}

fn alphaAt(buf: []const u32, l: Layout, x: i32, y: i32) u32 {
    const w = l.win.width();
    return buf[@intCast(y * w + x)] >> 24;
}

test "T1830: every hit-box pixel catches the press, and the corners stay invisible" {
    var buf: [80 * 24]u32 = undefined;
    const l = renderFor(.hinted, .{ .r = 30, .g = 30, .b = 30 }, &buf);
    for (buf) |p| try testing.expect((p >> 24) >= HIT_ALPHA);
    // Outside the capsule is the invisible hit alpha, not paint.
    try testing.expectEqual(@as(u32, HIT_ALPHA), alphaAt(&buf, l, 0, 0));
    try testing.expectEqual(@as(u32, HIT_ALPHA), alphaAt(&buf, l, l.win.width() - 1, l.win.height() - 1));
}

test "T1830: engaged is opaque where hinted is translucent, and premultiplied" {
    const bg = Rgb{ .r = 30, .g = 30, .b = 30 };
    var hint: [80 * 24]u32 = undefined;
    var eng: [80 * 24]u32 = undefined;
    const l = renderFor(.hinted, bg, &hint);
    _ = renderFor(.engaged, bg, &eng);
    // A point inside the capsule but between dots: the left end of the grip.
    const x = l.grip.left + 4;
    const y = @divFloor(l.grip.top + l.grip.bottom, 2);
    try testing.expectEqual(@as(u32, 255), alphaAt(&eng, l, x, y));
    const ha = alphaAt(&hint, l, x, y);
    try testing.expect(ha > HIT_ALPHA and ha < 128);
    // The center dot is full strength engaged and dimmed hinted.
    const cx = @divFloor(l.grip.left + l.grip.right, 2);
    try testing.expectEqual(@as(u32, 255), alphaAt(&eng, l, cx, y));
    try testing.expect(alphaAt(&hint, l, cx, y) < 255);
    // Premultiplied: no channel exceeds its alpha.
    for ([_][]const u32{ &hint, &eng }) |b| for (b) |p| {
        const a = p >> 24;
        try testing.expect(((p >> 16) & 0xFF) <= a);
        try testing.expect(((p >> 8) & 0xFF) <= a);
        try testing.expect((p & 0xFF) <= a);
    };
}

test "T1830: the engaged grip casts a shadow below it, and hinted does not" {
    const bg = Rgb{ .r = 30, .g = 30, .b = 30 };
    var hint: [80 * 24]u32 = undefined;
    var eng: [80 * 24]u32 = undefined;
    const l = renderFor(.hinted, bg, &hint);
    _ = renderFor(.engaged, bg, &eng);
    const cx = @divFloor(l.grip.left + l.grip.right, 2);
    try testing.expect(alphaAt(&eng, l, cx, l.grip.bottom) > alphaAt(&hint, l, cx, l.grip.bottom));
}

test "T1830: the three dots are symmetric about the grip's center" {
    var buf: [80 * 24]u32 = undefined;
    const l = renderFor(.engaged, .{ .r = 30, .g = 30, .b = 30 }, &buf);
    const y = @divFloor(l.grip.top + l.grip.bottom, 2);
    var x = l.grip.left;
    while (x < l.grip.right) : (x += 1) {
        const mirror = l.grip.right - 1 - (x - l.grip.left);
        try testing.expectEqual(buf[@intCast(y * l.win.width() + x)], buf[@intCast(y * l.win.width() + mirror)]);
    }
}
