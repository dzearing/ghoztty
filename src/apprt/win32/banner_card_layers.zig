//! The banner card's collapse/expand as compositor animations (T2798,
//! composition step 5d-3b).
//!
//! On the visual path (T2559) the card is a child visual of the pane's
//! composition root. Until this module, a toggle re-rendered the whole card
//! on every frame-clock tick for 180 ms - the card at its animated height,
//! the body dissolving, the tail fading at the moving edge - and uploaded it
//! again, so a busy UI thread froze the card while the frozen terminal copy
//! (T2763) glided on under it.
//!
//! Here the toggle is rendered ONCE, as three children of the banner's own
//! layer, and each one's motion is handed to DirectComposition:
//!
//! - `card`: the card at the taller of the two heights with its body
//!   dissolved away (head line, chevron, backdrop), clipped by a rectangle
//!   whose bottom runs with the card's edge.
//! - `body`: the same frame with the body solid, under the same clip, its
//!   opacity running on `banner_layout.collapseBodyAlpha`'s curve. Over
//!   `card` at opacity a it is exactly the stepped `paintBodyFade` blend.
//! - `edge`: the card's bottom (rounded corners, shadow, margin) from a
//!   frame at the shorter height, with the tail fade's translucent ramp
//!   above it, its offset running with the edge.
//!
//! The banner layer itself holds the band's own fill at the settled height,
//! which is what shows below an expanding card's edge. All three motions are
//! the one ease `banner_layout.collapseHeight` steps, fitted to cubics.
const std = @import("std");
const banner_glide = @import("banner_glide.zig");
const banner_layout = @import("banner_layout.zig");
const comp_overlay = @import("../../renderer/comp_overlay.zig");

const Layer = comp_overlay.Layer;

/// Where every piece starts and lands, in banner-layer pixels.
pub const Plan = struct {
    /// Card height the `card` and `body` pieces are rendered at.
    big_h: i32,
    /// Card height the `edge` piece is cut from.
    small_h: i32,
    /// Rows of the card's bottom the `edge` carries opaque.
    edge_rows: i32,
    /// Rows of tail-fade ramp riding on top of them (0: nothing overflows).
    ramp_rows: i32,
    /// The ramp's full height in the stepped frame it reproduces.
    fade_h: i32,
    clip_from: f32,
    clip_to: f32,
    edge_from: f32,
    edge_to: f32,
    body_from: u8,
    body_to: u8,

    /// Rows of the `card`/`body` frame (the tall band).
    pub fn bigBand(self: Plan, margin: i32) i32 {
        return banner_layout.bandHeight(self.big_h, margin);
    }

    /// Rows of the frame the `edge` is cut from (the short band).
    pub fn smallBand(self: Plan, margin: i32) i32 {
        return banner_layout.bandHeight(self.small_h, margin);
    }

    pub fn edgeHeight(self: Plan) i32 {
        return self.ramp_rows + self.edge_rows;
    }
};

/// The pieces of a toggle from card height `from_h` to `to_h`, with the card
/// `margin` inside its band and `pad` inside the card, and `wanted_h` the
/// height the content asks for (above it, nothing overflows and there is no
/// tail fade). Null when there is nothing to move.
pub fn plan(from_h: i32, to_h: i32, margin: i32, pad: i32, wanted_h: i32) ?Plan {
    if (from_h == to_h or from_h <= 0 or to_h <= 0) return null;
    const big = @max(from_h, to_h);
    const small = @min(from_h, to_h);
    // The card's bottom padding and the band's margin under it: no content
    // is ever laid out there, so a cut through its top is clean.
    const edge = @max(margin, 0) + @max(pad, 0);
    const small_band = banner_layout.bandHeight(small, margin);
    if (edge <= 0 or edge >= small_band) return null;
    // `paintCollapseFade`'s ramp at the short frame: from 45% down the card
    // to its bottom, wherever the content is cut short.
    var ramp: i32 = 0;
    var fade_h: i32 = 0;
    if (small < wanted_h) {
        const fade_top = margin + @divTrunc(small * 45, 100);
        fade_h = (small_band - margin) - fade_top;
        ramp = @max((small_band - edge) - fade_top, 0);
    }
    const band = struct {
        fn of(h: i32, m: i32) f32 {
            return @floatFromInt(banner_layout.bandHeight(h, m));
        }
    }.of;
    const e: f32 = @floatFromInt(edge);
    const r: f32 = @floatFromInt(ramp);
    return .{
        .big_h = big,
        .small_h = small,
        .edge_rows = edge,
        .ramp_rows = ramp,
        .fade_h = fade_h,
        .clip_from = band(from_h, margin) - e,
        .clip_to = band(to_h, margin) - e,
        .edge_from = band(from_h, margin) - e - r,
        .edge_to = band(to_h, margin) - e - r,
        .body_from = banner_layout.collapseBodyAlpha(from_h, to_h, 0),
        .body_to = banner_layout.collapseBodyAlpha(from_h, to_h, 1),
    };
}

/// The ramp's alpha `row` rows into a fade `fade_h` tall: the stepped
/// `paintCollapseFade` row rule, so both paths lay down the same steps.
pub fn rampAlpha(row: usize, fade_h: usize) u32 {
    if (fade_h == 0) return 255;
    return @min(255, (row * 255) / fade_h);
}

/// Premultiplied BGRA of the opaque pixel `s` at alpha `a`.
pub fn premul(s: u32, a: u32) u32 {
    const r = (((s >> 16) & 0xFF) * a) / 255;
    const g = (((s >> 8) & 0xFF) * a) / 255;
    const b = ((s & 0xFF) * a) / 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

/// What the ramp fades into: one flat colour (0x00RRGGBB), or - on glass -
/// the card's own rows from the ramp's first row down (T1884).
pub const RampSource = union(enum) {
    flat: u32,
    rows: []const u32,
};

/// Lay out the `edge` piece in `out` (`w * p.edgeHeight()` pixels): the
/// ramp rows, translucent, then the last `p.edge_rows` rows of the short
/// frame `small` (`w` wide, `p.smallBand(margin)` tall), opaque.
pub fn fillEdge(out: []u32, w: usize, p: Plan, margin: i32, small: []const u32, src: RampSource) bool {
    const ramp: usize = @intCast(p.ramp_rows);
    const edge: usize = @intCast(p.edge_rows);
    const band: usize = @intCast(p.smallBand(margin));
    if (out.len < w * (ramp + edge) or small.len < w * band or edge > band) return false;
    const fade_h: usize = @intCast(@max(p.fade_h, 0));
    for (0..ramp) |row| {
        const a = rampAlpha(row, fade_h);
        const line = out[row * w ..][0..w];
        switch (src) {
            .flat => |c| @memset(line, premul(c, a)),
            .rows => |rows| {
                if (rows.len < (row + 1) * w) return false;
                for (line, rows[row * w ..][0..w]) |*d, s| d.* = premul(s, a);
            },
        }
    }
    @memcpy(out[ramp * w ..][0 .. edge * w], small[(band - edge) * w ..][0 .. edge * w]);
    // The frame is opaque (T131); GDI leaves the alpha byte clear.
    for (out[ramp * w ..][0 .. edge * w]) |*px| px.* |= 0xFF000000;
    return true;
}

/// The three children of the banner layer while a toggle runs.
pub const CardLayers = struct {
    card: Layer = .{},
    body: Layer = .{},
    edge: Layer = .{},
    /// Declared and on screen: the toggle is the compositor's.
    active: bool = false,
    /// The band width the pieces were rendered at.
    width: u32 = 0,

    pub const Frames = struct {
        /// The tall frame with the body dissolved and with it solid, both
        /// `w * p.bigBand(margin)`, opaque.
        no_body: []const u32,
        full: []const u32,
        /// The `edge` piece, from `fillEdge`.
        edge: []const u32,
    };

    /// Put the pieces on `parent` and hand their motion to the compositor,
    /// `elapsed_s` into a toggle `duration_s` long. False: nothing is left
    /// on screen and the caller steps the toggle.
    pub fn declare(self: *CardLayers, slot: *comp_overlay.Slot, parent: *Layer, p: Plan, margin: i32, w: u32, f: Frames, elapsed_s: f64, duration_s: f64) bool {
        if (self.declareImpl(slot, parent, p, margin, w, f, elapsed_s, duration_s)) {
            self.active = true;
            self.width = w;
            return true;
        }
        self.drop();
        return false;
    }

    fn declareImpl(self: *CardLayers, slot: *comp_overlay.Slot, parent: *Layer, p: Plan, margin: i32, w: u32, f: Frames, elapsed_s: f64, duration_s: f64) bool {
        const left = duration_s - elapsed_s;
        if (left <= 0) return false;
        var segs: [comp_overlay.ease_segments]comp_overlay.Cubic = undefined;
        comp_overlay.fitCurve(banner_glide.easeF64, duration_s, &segs);
        var buf: [comp_overlay.ease_segments]comp_overlay.Cubic = undefined;
        const tail = comp_overlay.tailOf(&segs, elapsed_s, &buf);
        // Where the tail starts: the stepped curve, `elapsed_s` in.
        const done: f32 = @floatCast(banner_glide.easeF64(elapsed_s / duration_s));
        const at = struct {
            fn v(a: f32, b: f32, k: f32) f32 {
                return a + (b - a) * k;
            }
        }.v;

        const big: u32 = @intCast(p.bigBand(margin));
        const eh: u32 = @intCast(p.edgeHeight());
        const right: f32 = @floatFromInt(w);
        for ([_]*Layer{ &self.card, &self.body, &self.edge }) |l| {
            if (!l.sync(slot) or l.generation != parent.generation) return false;
        }
        if (!self.card.setPixels(f.no_body, w, big)) return false;
        if (!self.body.setPixels(f.full, w, big)) return false;
        if (!self.edge.setPixels(f.edge, w, eh)) return false;
        _ = self.edge.setNearest();
        const clip0 = at(p.clip_from, p.clip_to, done);
        if (!self.card.animateClipBottom(0, right, clip0, p.clip_to, tail, left)) return false;
        if (!self.body.animateClipBottom(0, right, clip0, p.clip_to, tail, left)) return false;
        const a0: f32 = at(@floatFromInt(p.body_from), @floatFromInt(p.body_to), done);
        if (!self.body.animateOpacity(@intFromFloat(@round(a0)), p.body_to, tail, left)) return false;
        if (!self.edge.animateOffsetY(at(p.edge_from, p.edge_to, done), p.edge_to, tail, left)) return false;
        // Front to back: each attach goes in front of the last.
        self.card.attachUnder(parent);
        self.body.attachUnder(parent);
        self.edge.attachUnder(parent);
        return self.card.attached and self.body.attached and self.edge.attached;
    }

    /// Still on the tree `parent` is on, at `w`: false means the pieces can
    /// no longer stand for the card and the caller falls back to stepping.
    pub fn current(self: *const CardLayers, parent: *const Layer, w: u32) bool {
        return self.active and w == self.width and
            self.card.generation == parent.generation and parent.active();
    }

    /// Take the pieces off and let go of them.
    pub fn drop(self: *CardLayers) void {
        self.edge.deinit();
        self.body.deinit();
        self.card.deinit();
        self.active = false;
        self.width = 0;
    }
};

// --- tests ------------------------------------------------------------------

test "plan: a collapse cuts the edge from the short frame and runs the clip down (T2798)" {
    // Expanded card 200 tall, collapsed 60, margin 8, pad 12.
    const p = plan(200, 60, 8, 12, 200).?;
    try std.testing.expectEqual(@as(i32, 200), p.big_h);
    try std.testing.expectEqual(@as(i32, 60), p.small_h);
    try std.testing.expectEqual(@as(i32, 20), p.edge_rows);
    // Band 216 -> 76; the clip stops `edge` rows above the band's bottom.
    try std.testing.expectEqual(@as(f32, 196), p.clip_from);
    try std.testing.expectEqual(@as(f32, 56), p.clip_to);
    // The short frame overflows: fade from 8 + 27 = 35 to 68, the ramp is
    // the part above the edge (35..56).
    try std.testing.expectEqual(@as(i32, 33), p.fade_h);
    try std.testing.expectEqual(@as(i32, 21), p.ramp_rows);
    try std.testing.expectEqual(@as(f32, 196 - 21), p.edge_from);
    try std.testing.expectEqual(@as(f32, 56 - 21), p.edge_to);
    // The body dissolves out.
    try std.testing.expectEqual(@as(u8, 255), p.body_from);
    try std.testing.expectEqual(@as(u8, 0), p.body_to);
}

test "plan: an expand runs the same pieces the other way" {
    const p = plan(60, 200, 8, 12, 200).?;
    try std.testing.expectEqual(@as(f32, 56), p.clip_from);
    try std.testing.expectEqual(@as(f32, 196), p.clip_to);
    try std.testing.expectEqual(@as(u8, 0), p.body_from);
    try std.testing.expectEqual(@as(u8, 255), p.body_to);
    try std.testing.expectEqual(p.edge_to - p.edge_from, p.clip_to - p.clip_from);
}

test "plan: nothing to move, and a short frame with nothing cut has no ramp" {
    try std.testing.expect(plan(80, 80, 8, 12, 200) == null);
    try std.testing.expect(plan(0, 80, 8, 12, 200) == null);
    // Content fits the short frame: no tail fade to carry.
    const p = plan(120, 80, 8, 12, 80).?;
    try std.testing.expectEqual(@as(i32, 0), p.ramp_rows);
}

test "fillEdge: ramp rows are premultiplied, edge rows are the short frame's bottom, opaque" {
    const p = plan(40, 20, 2, 2, 40).?;
    const w: usize = 3;
    const band: usize = @intCast(p.smallBand(2));
    var small: [3 * 24]u32 = undefined;
    for (0..band) |row| @memset(small[row * w ..][0..w], @intCast(row));
    var out: [3 * 24]u32 = undefined;
    try std.testing.expect(fillEdge(&out, w, p, 2, small[0 .. w * band], .{ .flat = 0x00FF0000 }));
    const ramp: usize = @intCast(p.ramp_rows);
    try std.testing.expect(ramp > 0);
    // First ramp row: fully clear. Each later one: red at the row's alpha.
    try std.testing.expectEqual(@as(u32, 0), out[0]);
    const a1 = rampAlpha(1, @intCast(p.fade_h));
    try std.testing.expectEqual(premul(0x00FF0000, a1), out[w]);
    // Edge rows: the last `edge_rows` of the short frame, alpha forced on.
    const first_edge = band - @as(usize, @intCast(p.edge_rows));
    try std.testing.expectEqual(@as(u32, 0xFF000000) | @as(u32, @intCast(first_edge)), out[ramp * w]);
    try std.testing.expectEqual(@as(u32, 0xFF000000) | @as(u32, @intCast(band - 1)), out[(ramp + @as(usize, @intCast(p.edge_rows)) - 1) * w + 2]);
}

test "rampAlpha matches paintCollapseFade's row rule" {
    try std.testing.expectEqual(@as(u32, 0), rampAlpha(0, 10));
    try std.testing.expectEqual(@as(u32, 127), rampAlpha(5, 10));
    try std.testing.expectEqual(@as(u32, 255), rampAlpha(10, 10));
    try std.testing.expectEqual(@as(u32, 0x80402010), premul(0x00804020, 0x80));
}
