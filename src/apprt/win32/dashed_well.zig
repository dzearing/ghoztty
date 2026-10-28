//! The empty stash tray's well (T2358): Mac's `PaneSidebarEmptyStashSlot`
//! outline - `RoundedRectangle.strokeBorder(_, StrokeStyle(lineWidth:, dash:
//! [4, 3]))` - as per-pixel coverage, so it can be antialiased and DIP-scaled
//! rather than drawn with a cosmetic GDI pen. That pen was always one device
//! pixel, aliased, and its user-style dash around a `RoundRect` did not read
//! as dashed at all (the user: "this dotted line around the stash target is
//! not a dotted line").
//!
//! Pure geometry, no OS imports, so its tests run in every app-runtime lane.
//! `strokeBorder` strokes the shape inset by half the line, so the line sits
//! wholly inside the box; the inset path's corner radius shrinks by the same
//! half line, the way SwiftUI's `InsettableShape` insets a rounded rect. The
//! dash runs along the path's arc length with butt ends (SwiftUI's default
//! cap), so it turns the corners the way Mac's does instead of restarting on
//! each side. The fill is the whole shape, for the accent wash a drag that
//! would land here lays under the outline.
//!
//! The GDI half that lays the coverage over a DC is in `PaneSidebar.zig`
//! (`paintWell`), through `sidebar_symbol.tint`.

const std = @import("std");

/// A well `w` x `h` pixels with its outline, all in device pixels.
pub const Well = struct {
    w: f32,
    h: f32,
    /// The shape's corner radius (before the half-line inset).
    radius: f32,
    /// The stroke's width.
    line: f32,
    /// The dash: `on` pixels drawn, then `off` skipped.
    on: f32,
    off: f32,

    /// The path the stroke is centred on: the box inset by half the line.
    fn path(self: Well) Path {
        const half = self.line / 2;
        const x0 = half;
        const y0 = half;
        const x1 = @max(self.w - half, x0);
        const y1 = @max(self.h - half, y0);
        const r = std.math.clamp(self.radius - half, 0, @min(x1 - x0, y1 - y0) / 2);
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .r = r };
    }
};

/// What one pixel gets: how much of it the dashed stroke covers and how much
/// the filled shape does, each 0..1.
pub const Coverage = struct { stroke: f32, fill: f32 };

const Path = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    r: f32,

    /// The nearest point of the path to (`px`, `py`): how far it is, and how
    /// far along the path (clockwise from the top edge's start) it lies.
    fn nearest(self: Path, px: f32, py: f32) struct { d: f32, s: f32 } {
        const r = self.r;
        const top = self.x1 - self.x0 - 2 * r;
        const side = self.y1 - self.y0 - 2 * r;
        const quarter = r * std.math.pi / 2.0;

        var best_d: f32 = std.math.inf(f32);
        var best_s: f32 = 0;
        var s0: f32 = 0;
        // The four edges, each followed by the corner it runs into, in the
        // order a clockwise walk meets them.
        const edges = [4]struct { ax: f32, ay: f32, dx: f32, dy: f32, len: f32, cx: f32, cy: f32, a0: f32 }{
            .{ .ax = self.x0 + r, .ay = self.y0, .dx = 1, .dy = 0, .len = top, .cx = self.x1 - r, .cy = self.y0 + r, .a0 = -std.math.pi / 2.0 },
            .{ .ax = self.x1, .ay = self.y0 + r, .dx = 0, .dy = 1, .len = side, .cx = self.x1 - r, .cy = self.y1 - r, .a0 = 0 },
            .{ .ax = self.x1 - r, .ay = self.y1, .dx = -1, .dy = 0, .len = top, .cx = self.x0 + r, .cy = self.y1 - r, .a0 = std.math.pi / 2.0 },
            .{ .ax = self.x0, .ay = self.y1 - r, .dx = 0, .dy = -1, .len = side, .cx = self.x0 + r, .cy = self.y0 + r, .a0 = std.math.pi },
        };
        for (edges) |e| {
            // The straight run.
            const t = std.math.clamp((px - e.ax) * e.dx + (py - e.ay) * e.dy, 0, e.len);
            const qx = e.ax + e.dx * t - px;
            const qy = e.ay + e.dy * t - py;
            const d = @sqrt(qx * qx + qy * qy);
            if (d < best_d) {
                best_d = d;
                best_s = s0 + t;
            }
            s0 += e.len;
            // The corner after it: a quarter circle swept clockwise (y down).
            if (r > 0) {
                const ox = px - e.cx;
                const oy = py - e.cy;
                var a = std.math.atan2(oy, ox) - e.a0;
                while (a < 0) a += 2 * std.math.pi;
                while (a >= 2 * std.math.pi) a -= 2 * std.math.pi;
                if (a <= std.math.pi / 2.0) {
                    const dc = @abs(@sqrt(ox * ox + oy * oy) - r);
                    if (dc < best_d) {
                        best_d = dc;
                        best_s = s0 + a * r;
                    }
                }
            }
            s0 += quarter;
        }
        return .{ .d = best_d, .s = best_s };
    }

    /// Signed distance to the filled shape: negative inside.
    fn signed(self: Path, px: f32, py: f32, grow: f32) f32 {
        const r = self.r + grow;
        const hx = (self.x1 - self.x0) / 2 + grow;
        const hy = (self.y1 - self.y0) / 2 + grow;
        const qx = @abs(px - (self.x0 + self.x1) / 2) - hx + r;
        const qy = @abs(py - (self.y0 + self.y1) / 2) - hy + r;
        const ox = @max(qx, 0);
        const oy = @max(qy, 0);
        return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - r;
    }
};

/// The coverage of the pixel centred on (`px`, `py`).
pub fn coverageAt(well: Well, px: f32, py: f32) Coverage {
    const p = well.path();
    // The fill is the shape itself - the path grown back out by half the
    // line - antialiased over one pixel.
    const fill = std.math.clamp(0.5 - p.signed(px, py, well.line / 2), 0, 1);

    const n = p.nearest(px, py);
    const across = std.math.clamp(well.line / 2 + 0.5 - n.d, 0, 1);
    if (across == 0) return .{ .stroke = 0, .fill = fill };

    // Along the path: inside a dash, how far to its nearer end; in a gap,
    // how far to the nearer dash - each antialiased over one pixel.
    const period = well.on + well.off;
    if (period <= 0 or well.off <= 0) return .{ .stroke = across, .fill = fill };
    const m = @mod(n.s, period);
    const along = if (m < well.on)
        std.math.clamp(0.5 + @min(m, well.on - m), 0, 1)
    else
        std.math.clamp(0.5 - @min(m - well.on, period - m), 0, 1);
    return .{ .stroke = across * along, .fill = fill };
}

/// The well drawn into `stroke` and `fill` (row-major, `w * h` bytes each,
/// `w` and `h` the well's own size rounded), as coverage 0..255.
pub fn render(well: Well, stroke: []u8, fill: []u8) void {
    const w: usize = @intFromFloat(@round(well.w));
    const h: usize = @intFromFloat(@round(well.h));
    std.debug.assert(stroke.len >= w * h and fill.len >= w * h);
    // Deep inside, the stroke cannot reach: skip the walk there.
    const reach = well.line + well.radius + 2;
    for (0..h) |row| {
        const py = @as(f32, @floatFromInt(row)) + 0.5;
        for (0..w) |col| {
            const px = @as(f32, @floatFromInt(col)) + 0.5;
            const i = row * w + col;
            const interior = px > reach and px < well.w - reach and py > reach and py < well.h - reach;
            if (interior) {
                stroke[i] = 0;
                fill[i] = 255;
                continue;
            }
            const c = coverageAt(well, px, py);
            stroke[i] = @intFromFloat(@round(c.stroke * 255));
            fill[i] = @intFromFloat(@round(c.fill * 255));
        }
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// A rail-sized well at `scale`: 52 x 30 DIP, 6 DIP corners, 1 DIP line,
/// Mac's 4/3 dash.
fn railWell(scale: f32, line_dip: f32) Well {
    return .{
        .w = @round(52 * scale),
        .h = @round(30 * scale),
        .radius = 6 * scale,
        .line = line_dip * scale,
        .on = 4 * scale,
        .off = 3 * scale,
    };
}

/// Runs of on (> half covered) and off pixels along the top edge's stroke
/// row, between the corners.
fn topRuns(well: Well, out_on: *std.ArrayList(usize), out_off: *std.ArrayList(usize)) !void {
    // Row 0 is solid across the line at every width from 1 px up.
    const y: f32 = 0.5;
    const start: usize = @intFromFloat(@ceil(well.radius));
    const end: usize = @intFromFloat(@floor(well.w - well.radius));
    var on_run: usize = 0;
    var off_run: usize = 0;
    var x = start;
    while (x < end) : (x += 1) {
        const c = coverageAt(well, @as(f32, @floatFromInt(x)) + 0.5, y);
        if (c.stroke > 0.5) {
            if (off_run > 0) try out_off.append(testing.allocator, off_run);
            off_run = 0;
            on_run += 1;
        } else {
            if (on_run > 0) try out_on.append(testing.allocator, on_run);
            on_run = 0;
            off_run += 1;
        }
    }
}

test "the top edge alternates dashes and gaps at 4/3 DIP" {
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        var on: std.ArrayList(usize) = .empty;
        defer on.deinit(testing.allocator);
        var off: std.ArrayList(usize) = .empty;
        defer off.deinit(testing.allocator);
        try topRuns(railWell(scale, 1), &on, &off);
        // Several of each, and none of either swallowing the edge.
        try testing.expect(on.items.len >= 3);
        try testing.expect(off.items.len >= 3);
        // Interior runs (the first and last can be cut by the corners).
        for (on.items[1 .. on.items.len - 1]) |n| {
            try testing.expect(@abs(@as(f32, @floatFromInt(n)) - 4 * scale) <= 1.01);
        }
        for (off.items[1 .. off.items.len - 1]) |n| {
            try testing.expect(@abs(@as(f32, @floatFromInt(n)) - 3 * scale) <= 1.01);
        }
    }
}

test "the dash keeps going round the corners" {
    // A corner's arc is ~8.6 DIP long at 6 DIP: at least one dash lands on
    // it, so the outline reads as one dashed line rather than four.
    const well = railWell(2, 1);
    const p = well.path();
    var inked: usize = 0;
    var steps: usize = 0;
    var a: f32 = 0;
    while (a <= std.math.pi / 2.0) : (a += 0.05) {
        // The top-left corner, swept from the left edge to the top.
        const x = p.x0 + p.r - @cos(a) * p.r;
        const y = p.y0 + p.r - @sin(a) * p.r;
        if (coverageAt(well, x, y).stroke > 0.5) inked += 1;
        steps += 1;
    }
    try testing.expect(inked > 0 and inked < steps);
}

test "the stroke is antialiased and sits inside the box" {
    // 1.5 DIP at 1x: a pixel and a half wide, so its inner edge pixel is part
    // covered - neither empty nor solid.
    const well = railWell(1, 1.5);
    const mid_dash_x = blk: {
        var x: f32 = @ceil(well.radius) + 0.5;
        while (x < well.w) : (x += 1) {
            if (coverageAt(well, x, 0.5).stroke > 0.99) break :blk x;
        }
        return error.NoDash;
    };
    try testing.expect(coverageAt(well, mid_dash_x, 0.5).stroke > 0.99);
    const inner = coverageAt(well, mid_dash_x, 1.5).stroke;
    try testing.expect(inner > 0.2 and inner < 0.8);
    try testing.expectEqual(@as(f32, 0), coverageAt(well, mid_dash_x, 3.5).stroke);
    // Outside the box there is nothing at all.
    try testing.expectEqual(@as(f32, 0), coverageAt(well, mid_dash_x, -0.5).stroke);
}

test "the hot outline is wider than the resting one" {
    var rest: usize = 0;
    var hot: usize = 0;
    const a = railWell(1.5, 1);
    const b = railWell(1.5, 1.5);
    var y: f32 = 0.5;
    while (y < 6) : (y += 1) {
        var x: f32 = 10.5;
        while (x < 60) : (x += 1) {
            if (coverageAt(a, x, y).stroke > 0) rest += 1;
            if (coverageAt(b, x, y).stroke > 0) hot += 1;
        }
    }
    try testing.expect(hot > rest);
}

test "the fill covers the inside and rounds the corners off" {
    const well = railWell(1, 1);
    try testing.expectEqual(@as(f32, 1), coverageAt(well, 26, 15).fill);
    try testing.expectEqual(@as(f32, 0), coverageAt(well, 0.5, 0.5).fill);
    try testing.expectEqual(@as(f32, 1), coverageAt(well, 26, 0.5).fill);
}

test "render matches coverageAt, interior shortcut included" {
    const well = railWell(1.5, 1);
    const w: usize = @intFromFloat(well.w);
    const h: usize = @intFromFloat(well.h);
    const stroke = try testing.allocator.alloc(u8, w * h);
    defer testing.allocator.free(stroke);
    const fill = try testing.allocator.alloc(u8, w * h);
    defer testing.allocator.free(fill);
    render(well, stroke, fill);
    for (0..h) |row| for (0..w) |col| {
        const c = coverageAt(well, @as(f32, @floatFromInt(col)) + 0.5, @as(f32, @floatFromInt(row)) + 0.5);
        try testing.expectEqual(@as(u8, @intFromFloat(@round(c.stroke * 255))), stroke[row * w + col]);
        try testing.expectEqual(@as(u8, @intFromFloat(@round(c.fill * 255))), fill[row * w + col]);
    };
}
