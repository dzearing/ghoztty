//! The pane sidebar's own icon set (T2357): Mac's `PaneSidebarSymbol`
//! (`macos/Sources/Features/PaneSidebar/PaneSidebarSymbol.swift`), drawn from
//! the same 16-unit coordinates rather than approximated with the icon font.
//!
//! The Mac draws these itself on purpose - the design mock's lighter, rounder
//! strokes, with SF Symbols rejected as "a different family" - so a Fluent
//! glyph standing in for one is exactly the mismatch the user reported ("they
//! don't match the mac icons"). Where the Mac uses an SF Symbol (an image
//! pane's `photo`, the search field's `xmark.circle.fill`) the nearest Fluent
//! glyph is still the translation (design system §4).
//!
//! Pure geometry, no OS imports, so its tests run in every app-runtime lane:
//! `render` turns a symbol into a square coverage mask, stroked with round
//! caps and joins at Mac's line widths (a distance field, which is what makes
//! every cap and join round for free) and antialiased over one pixel. The
//! GDI half that lays a mask over a DC is `sidebar_symbol_dc.zig`.
//!
//! Mac's rounded rects are SwiftUI's `.continuous` corners; these are
//! circular ones of the same radius. At a 1.8-2.2 unit radius on a 14-15 pt
//! icon the difference is under a quarter pixel.

const std = @import("std");

pub const Symbol = union(enum) {
    /// The all-windows toggle: two stacked windows, the front one filled
    /// while every window is shown.
    windows: bool,
    /// The collapse/expand button: a window with its sidebar, the sidebar
    /// filled while it is expanded.
    sidebar: bool,
    /// The header's new-window button.
    plus,
    terminal,
    document,
    globe,
    diff,
    /// The empty stash tray's mark (T2358): Mac's SF Symbol
    /// `tray.and.arrow.down`, which no Fluent glyph on the box matches (every
    /// codepoint E700-F3FF of Segoe Fluent Icons was looked at), so it is
    /// drawn here as the font-first rule's fallback - an open tray with an
    /// arrow dropping into it, at SF's medium weight.
    tray,

    /// The stroke, in 16-unit space (Mac `lineWidth`).
    pub fn lineWidth(self: Symbol) f32 {
        return switch (self) {
            .terminal, .document, .globe => 1.3,
            .diff => 1.4,
            .tray => 1.5,
            .windows, .sidebar, .plus => 1.25,
        };
    }
};

const V = struct { x: f32, y: f32 };

fn v(x: f32, y: f32) V {
    return .{ .x = x, .y = y };
}

/// One stroked piece of an outline, in 16-unit space.
const Prim = union(enum) {
    seg: struct { a: V, b: V },
    /// A rounded rect's outline (`addRoundedRect`).
    rrect: RRect,
    /// An ellipse's outline, inscribed in the box (`addEllipse`).
    ellipse: struct { x: f32, y: f32, w: f32, h: f32 },
    /// A circular arc from angle `a0` sweeping `sweep` radians, y down (the
    /// corners `addArc(tangent1End:tangent2End:radius:)` draws).
    arc: struct { c: V, r: f32, a0: f32, sweep: f32 },
};

const RRect = struct { x: f32, y: f32, w: f32, h: f32, r: f32 };

const max_prims = 16;

const Shape = struct {
    prims: [max_prims]Prim = undefined,
    n: usize = 0,
    /// What is filled (and stroked) beneath the outline: a toggle's "on".
    fill: ?RRect = null,

    fn add(self: *Shape, p: Prim) void {
        self.prims[self.n] = p;
        self.n += 1;
    }

    fn seg(self: *Shape, ax: f32, ay: f32, bx: f32, by: f32) void {
        self.add(.{ .seg = .{ .a = v(ax, ay), .b = v(bx, by) } });
    }
};

const half_pi = std.math.pi / 2.0;

/// Mac's `outline` and `fill`, primitive for primitive.
fn shape(sym: Symbol) Shape {
    var s: Shape = .{};
    switch (sym) {
        .windows => |filled| {
            const front: RRect = .{ .x = 4.4, .y = 1.8, .w = 9.8, .h = 8, .r = 1.8 };
            s.add(.{ .rrect = front });
            // The window behind, peeking out below and to the left.
            s.seg(11.6, 11.6, 11.6, 12.2);
            s.add(.{ .arc = .{ .c = v(9.8, 12.2), .r = 1.8, .a0 = 0, .sweep = half_pi } });
            s.seg(9.8, 14, 3.6, 14);
            s.add(.{ .arc = .{ .c = v(3.6, 12.2), .r = 1.8, .a0 = half_pi, .sweep = half_pi } });
            s.seg(1.8, 12.2, 1.8, 6.4);
            s.add(.{ .arc = .{ .c = v(3.6, 6.4), .r = 1.8, .a0 = 2 * half_pi, .sweep = half_pi } });
            s.seg(3.6, 4.6, 4.4, 4.6);
            if (filled) s.fill = front;
        },
        .sidebar => |expanded| {
            s.add(.{ .rrect = .{ .x = 1.8, .y = 2.6, .w = 12.4, .h = 10.8, .r = 2 } });
            s.seg(6.2, 2.6, 6.2, 13.4);
            if (expanded) s.fill = .{ .x = 1.8, .y = 2.6, .w = 4.4, .h = 10.8, .r = 2 };
        },
        .plus => {
            s.seg(8, 2.8, 8, 13.2);
            s.seg(2.8, 8, 13.2, 8);
        },
        .terminal => {
            s.add(.{ .rrect = .{ .x = 1.5, .y = 2.5, .w = 13, .h = 11, .r = 2.2 } });
            s.seg(4.5, 6.2, 6.8, 8);
            s.seg(6.8, 8, 4.5, 9.8);
            s.seg(8.2, 10, 11.4, 10);
        },
        .document => {
            // The page, its corner folded: one closed path...
            s.seg(4, 1.8, 9.2, 1.8);
            s.seg(9.2, 1.8, 12.5, 5);
            s.seg(12.5, 5, 12.5, 14.2);
            s.seg(12.5, 14.2, 4, 14.2);
            s.seg(4, 14.2, 4, 1.8);
            // ...the fold...
            s.seg(9, 1.8, 9, 5.3);
            s.seg(9, 5.3, 12.5, 5.3);
            // ...and three lines of text, which overflow `max_prims` as
            // separate segments, so they are added below.
        },
        .globe => {
            s.add(.{ .ellipse = .{ .x = 1.7, .y = 1.7, .w = 12.6, .h = 12.6 } });
            s.add(.{ .ellipse = .{ .x = 5.3, .y = 1.7, .w = 5.4, .h = 12.6 } });
            s.seg(1.9, 6, 14.1, 6);
            s.seg(1.9, 10, 14.1, 10);
        },
        .diff => {
            s.seg(5, 2.5, 5, 7.5);
            s.seg(2.5, 5, 7.5, 5);
            s.seg(2.5, 12.5, 7.5, 12.5);
            s.seg(10, 3, 13.5, 13);
        },
        .tray => {
            // The tray: its walls and rounded floor...
            s.seg(1.8, 8.6, 1.8, 12.2);
            s.add(.{ .arc = .{ .c = v(3.6, 12.2), .r = 1.8, .a0 = half_pi, .sweep = half_pi } });
            s.seg(3.6, 14, 12.4, 14);
            s.add(.{ .arc = .{ .c = v(12.4, 12.2), .r = 1.8, .a0 = 0, .sweep = half_pi } });
            s.seg(14.2, 12.2, 14.2, 8.6);
            // ...its lip, dipping where things drop in...
            s.seg(1.8, 10.2, 5, 10.2);
            s.seg(5, 10.2, 5.7, 11.6);
            s.seg(5.7, 11.6, 10.3, 11.6);
            s.seg(10.3, 11.6, 11, 10.2);
            s.seg(11, 10.2, 14.2, 10.2);
            // ...and the arrow coming down into it.
            s.seg(8, 1.8, 8, 8.4);
            s.seg(5.4, 5.8, 8, 8.4);
            s.seg(10.6, 5.8, 8, 8.4);
        },
    }
    return s;
}

/// The document's text lines (Mac: `(8.0, 4.5), (10.3, 4.5), (12.5, 3.0)`
/// from x 6), kept apart so `Shape` stays one small fixed array.
const document_lines = [_]struct { y: f32, len: f32 }{
    .{ .y = 8.0, .len = 4.5 },
    .{ .y = 10.3, .len = 4.5 },
    .{ .y = 12.5, .len = 3.0 },
};

fn segDist(p: V, a: V, b: V) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    const t = if (len2 == 0) 0 else std.math.clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0, 1);
    const qx = a.x + t * dx - p.x;
    const qy = a.y + t * dy - p.y;
    return @sqrt(qx * qx + qy * qy);
}

/// Signed distance to a rounded rect: negative inside.
fn rrectSigned(p: V, r: RRect) f32 {
    const hx = r.w / 2;
    const hy = r.h / 2;
    const qx = @abs(p.x - (r.x + hx)) - hx + r.r;
    const qy = @abs(p.y - (r.y + hy)) - hy + r.r;
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - r.r;
}

/// Distance to an ellipse's outline: a circle exactly, anything else from a
/// 64-segment polygon (well under a hundredth of a unit off at this size).
fn ellipseDist(p: V, x: f32, y: f32, w: f32, h: f32) f32 {
    const cx = x + w / 2;
    const cy = y + h / 2;
    if (w == h) return @abs(@sqrt((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)) - w / 2);
    const n = 64;
    var best: f32 = std.math.inf(f32);
    var prev = v(cx + w / 2, cy);
    for (1..n + 1) |i| {
        const a = @as(f32, @floatFromInt(i)) * (2 * std.math.pi / @as(f32, n));
        const cur = v(cx + @cos(a) * w / 2, cy + @sin(a) * h / 2);
        best = @min(best, segDist(p, prev, cur));
        prev = cur;
    }
    return best;
}

fn arcDist(p: V, c: V, r: f32, a0: f32, sweep: f32) f32 {
    const dx = p.x - c.x;
    const dy = p.y - c.y;
    var t = std.math.atan2(dy, dx) - a0;
    while (t < 0) t += 2 * std.math.pi;
    while (t >= 2 * std.math.pi) t -= 2 * std.math.pi;
    if (t <= sweep) return @abs(@sqrt(dx * dx + dy * dy) - r);
    const e0 = v(c.x + @cos(a0) * r, c.y + @sin(a0) * r);
    const e1 = v(c.x + @cos(a0 + sweep) * r, c.y + @sin(a0 + sweep) * r);
    const d0 = @sqrt((p.x - e0.x) * (p.x - e0.x) + (p.y - e0.y) * (p.y - e0.y));
    const d1 = @sqrt((p.x - e1.x) * (p.x - e1.x) + (p.y - e1.y) * (p.y - e1.y));
    return @min(d0, d1);
}

fn primDist(p: V, prim: Prim) f32 {
    return switch (prim) {
        .seg => |s| segDist(p, s.a, s.b),
        .rrect => |r| @abs(rrectSigned(p, r)),
        .ellipse => |e| ellipseDist(p, e.x, e.y, e.w, e.h),
        .arc => |a| arcDist(p, a.c, a.r, a.a0, a.sweep),
    };
}

/// How much of the pixel centred on `p` (16-unit space) the symbol covers,
/// 0..1, at `unit` pixels per unit.
pub fn coverageAt(sym: Symbol, p: V, unit: f32) f32 {
    const s = shape(sym);
    var d: f32 = std.math.inf(f32);
    for (s.prims[0..s.n]) |prim| d = @min(d, primDist(p, prim));
    if (sym == .document) for (document_lines) |ln| {
        d = @min(d, segDist(p, v(6, ln.y), v(6 + ln.len, ln.y)));
    };
    // Mac fills the "on" shape and then strokes it too, so its edge sits
    // where the outline's would.
    if (s.fill) |f| d = @min(d, @abs(rrectSigned(p, f)));
    const half = sym.lineWidth() / 2 * unit;
    var cov = std.math.clamp(half + 0.5 - d * unit, 0, 1);
    if (s.fill) |f| cov = @max(cov, std.math.clamp(0.5 - rrectSigned(p, f) * unit, 0, 1));
    return cov;
}

/// The symbol drawn `size` pixels square into `out` (row-major, at least
/// `size * size` bytes), as coverage 0..255.
pub fn render(sym: Symbol, size: usize, out: []u8) void {
    std.debug.assert(out.len >= size * size);
    const unit = @as(f32, @floatFromInt(size)) / 16.0;
    for (0..size) |row| {
        for (0..size) |col| {
            const p = v(
                (@as(f32, @floatFromInt(col)) + 0.5) / unit,
                (@as(f32, @floatFromInt(row)) + 0.5) / unit,
            );
            out[row * size + col] = @intFromFloat(@round(coverageAt(sym, p, unit) * 255));
        }
    }
}

/// The pixel size of a `dip`-sized symbol at `scale`.
pub fn pixelSize(dip: f32, scale: f32) usize {
    return @max(@as(usize, @intFromFloat(@round(dip * scale))), 1);
}

/// Blend `color` (COLORREF) over `pixels` (DIB 0xAARRGGBB) by `mask`,
/// keeping each pixel's alpha byte.
pub fn tint(pixels: []u32, mask: []const u8, color: u32) void {
    const sr: u32 = color & 0xFF;
    const sg: u32 = (color >> 8) & 0xFF;
    const sb: u32 = (color >> 16) & 0xFF;
    for (pixels, mask) |*p, c| {
        if (c == 0) continue;
        const a: u32 = c;
        const d = p.*;
        const r = mix((d >> 16) & 0xFF, sr, a);
        const g = mix((d >> 8) & 0xFF, sg, a);
        const b = mix(d & 0xFF, sb, a);
        p.* = (d & 0xFF00_0000) | (r << 16) | (g << 8) | b;
    }
}

fn mix(dst: u32, src: u32, a: u32) u32 {
    return (dst * (255 - a) + src * a + 127) / 255;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

const all = [_]Symbol{
    .{ .windows = false }, .{ .windows = true },
    .{ .sidebar = false }, .{ .sidebar = true },
    .plus,                 .terminal,
    .document,             .globe,
    .diff,                 .tray,
};

/// The sizes the sidebar draws at - rows 14, header buttons 15 (Mac's own
/// `size`s) - at 1x, 1.5x and 2x.
const sizes = [_]usize{ 14, 15, 21, 23, 28, 30 };

fn at(mask: []const u8, size: usize, x16: f32, y16: f32) u8 {
    const unit = @as(f32, @floatFromInt(size)) / 16.0;
    const col: usize = @intFromFloat(@floor(x16 * unit));
    const row: usize = @intFromFloat(@floor(y16 * unit));
    return mask[row * size + col];
}

fn ink(mask: []const u8) u64 {
    var sum: u64 = 0;
    for (mask) |c| sum += c;
    return sum;
}

test "every symbol inks at every size and leaves the box's corners clear" {
    var buf: [64 * 64]u8 = undefined;
    for (all) |sym| for (sizes) |n| {
        const m = buf[0 .. n * n];
        render(sym, n, m);
        try testing.expect(ink(m) > 0);
        // Every outline is rounded or inset at the corners of its box.
        try testing.expectEqual(@as(u8, 0), m[0]);
        try testing.expectEqual(@as(u8, 0), m[n - 1]);
        try testing.expectEqual(@as(u8, 0), m[(n - 1) * n]);
        try testing.expectEqual(@as(u8, 0), m[n * n - 1]);
    };
}

test "a stroke centre is solid and empty space is clear" {
    var buf: [64 * 64]u8 = undefined;
    for (sizes) |n| {
        const m = buf[0 .. n * n];
        render(.plus, n, m);
        // The plus's centre, and a point on each arm (at an even size the
        // line straddles two pixels, so half-ink on each is the solid case).
        try testing.expect(at(m, n, 8, 8) > 100);
        try testing.expect(at(m, n, 8, 4) > 100);
        try testing.expect(at(m, n, 4, 8) > 100);
        // A quadrant's middle is untouched.
        try testing.expectEqual(@as(u8, 0), at(m, n, 4.5, 4.5));
    }
}

test "the plus is mirror-symmetric" {
    var buf: [64 * 64]u8 = undefined;
    for (sizes) |n| {
        const m = buf[0 .. n * n];
        render(.plus, n, m);
        for (0..n) |r| for (0..n) |c| {
            try testing.expectEqual(m[r * n + c], m[r * n + (n - 1 - c)]);
            try testing.expectEqual(m[r * n + c], m[(n - 1 - r) * n + c]);
        };
    }
}

test "a toggle's on state fills its shape and adds ink" {
    var buf: [64 * 64]u8 = undefined;
    var on: [64 * 64]u8 = undefined;
    for (sizes) |n| {
        const off_m = buf[0 .. n * n];
        const on_m = on[0 .. n * n];

        render(.{ .windows = false }, n, off_m);
        render(.{ .windows = true }, n, on_m);
        // The front window's middle: hollow off, solid on.
        try testing.expectEqual(@as(u8, 0), at(off_m, n, 9.3, 5.8));
        try testing.expectEqual(@as(u8, 255), at(on_m, n, 9.3, 5.8));
        try testing.expect(ink(on_m) > ink(off_m));

        render(.{ .sidebar = false }, n, off_m);
        render(.{ .sidebar = true }, n, on_m);
        // The sidebar strip fills; the window's main area never does.
        try testing.expectEqual(@as(u8, 0), at(off_m, n, 4, 8));
        try testing.expectEqual(@as(u8, 255), at(on_m, n, 4, 8));
        try testing.expectEqual(@as(u8, 0), at(on_m, n, 10.5, 8));
    }
}

test "the windows symbol's back window turns its corners" {
    var buf: [64 * 64]u8 = undefined;
    // Large enough that the arc and a square corner land on different pixels.
    for ([_]usize{60}) |n| {
        const m = buf[0 .. n * n];
        render(.{ .windows = false }, n, m);
        // On the bottom-left arc (centre 3.6,12.2, r 1.8, at 135 degrees)...
        try testing.expect(at(m, n, 3.6 - 1.27, 12.2 + 1.27) > 150);
        // ...while the square corner it rounds off stays clear.
        try testing.expect(at(m, n, 1.8, 14) < 60);
    }
}

test "each kind is a distinct picture" {
    var a: [30 * 30]u8 = undefined;
    var b: [30 * 30]u8 = undefined;
    for (all, 0..) |x, i| for (all[i + 1 ..]) |y| {
        render(x, 30, &a);
        render(y, 30, &b);
        try testing.expect(!std.mem.eql(u8, &a, &b));
    };
}

test "the document carries its text lines and the globe its meridian" {
    var buf: [30 * 30]u8 = undefined;
    render(.document, 30, &buf);
    for (document_lines) |ln| try testing.expect(at(&buf, 30, 6 + ln.len / 2, ln.y) > 150);
    render(.globe, 30, &buf);
    // The inner ellipse's flank (x 5.3) at the equator, between the bands.
    try testing.expect(at(&buf, 30, 5.3, 8) > 150);
    try testing.expectEqual(@as(u8, 0), at(&buf, 30, 3.5, 8));
}

test "the tray has its arrow, its lip and an open top" {
    var buf: [30 * 30]u8 = undefined;
    render(.tray, 30, &buf);
    // The arrow's shaft, and its tip above the lip.
    try testing.expect(at(&buf, 30, 8, 4) > 150);
    try testing.expect(at(&buf, 30, 8, 8) > 150);
    // The lip's dip and the floor.
    try testing.expect(at(&buf, 30, 8, 11.6) > 150);
    try testing.expect(at(&buf, 30, 8, 14) > 150);
    // Open at the top: nothing beside the arrow above the walls.
    try testing.expectEqual(@as(u8, 0), at(&buf, 30, 2, 4));
    try testing.expectEqual(@as(u8, 0), at(&buf, 30, 14, 4));
}

test "pixelSize rounds and never reaches zero" {
    try testing.expectEqual(@as(usize, 14), pixelSize(14, 1));
    try testing.expectEqual(@as(usize, 21), pixelSize(14, 1.5));
    try testing.expectEqual(@as(usize, 23), pixelSize(15, 1.5));
    try testing.expectEqual(@as(usize, 1), pixelSize(0.1, 1));
}

test "tint keeps alpha and lands on the ink at full coverage" {
    var px = [_]u32{ 0x80_10_20_30, 0xFF_10_20_30, 0x00_FF_FF_FF };
    const mask = [_]u8{ 255, 0, 128 };
    // COLORREF red 0xAA, green 0xBB, blue 0xCC.
    tint(&px, &mask, 0x00_CC_BB_AA);
    try testing.expectEqual(@as(u32, 0x80_AA_BB_CC), px[0]);
    try testing.expectEqual(@as(u32, 0xFF_10_20_30), px[1]);
    try testing.expectEqual(@as(u32, 0x00), px[2] >> 24);
    try testing.expect((px[2] >> 16) & 0xFF < 0xFF and (px[2] >> 16) & 0xFF > 0xAA);
}
