//! The pane sidebar's list transitions on the compositor (T2802,
//! composition step 5d-5c).
//!
//! The stepped path (`pane_sidebar_transition.composeSlide` /
//! `composeFold`) paints the material, the frame after the change and the
//! picture from before into three DIBs and composes them on EVERY
//! TIMER_XFADE tick, so a busy UI thread freezes the slide or the fold
//! mid-way. Here each transition is rendered ONCE, as three layers on the
//! column's own composition tree (T2765), and DirectComposition plays the
//! motion:
//!
//! - `base`: the bare material over the band that moves, opaque and still,
//!   clipped to that band - it hides the live frame painted under it, and
//!   its clip cuts the children where the band ends, as Mac's clipped list
//!   is cut.
//! - Scope slide: `back` is the list from before and `front` the list after,
//!   each cut to the band and masked to where it differs from the material
//!   (`cropMasked`), so the glass holds still while the rows travel. Their
//!   X offsets and opacities run on `slideAt`'s numbers, end to end.
//! - Fold: `front` is the group's own rows in place (the tall frame), its
//!   clip's bottom running with the open band; `back` is everything below
//!   the group (the short frame, masked), its Y offset riding the band's
//!   edge - `composeFold`'s top-anchored mask, never a move through the
//!   header.
//!
//! The live GDI frame under the layers is the frame after the change, so
//! when the layers go at the end the column is already right.
const std = @import("std");
const comp_overlay = @import("../../renderer/comp_overlay.zig");
const tr = @import("pane_sidebar_transition.zig");

const Layer = comp_overlay.Layer;

/// A band of the column in client pixels.
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

    /// Inside a `w` x `h` surface and not empty.
    pub fn fits(self: Rect, w: i32, h: i32) bool {
        return self.left >= 0 and self.top >= 0 and self.right <= w and self.bottom <= h and
            self.right > self.left and self.bottom > self.top;
    }

    pub fn area(self: Rect) usize {
        return @as(usize, @intCast(self.width())) * @as(usize, @intCast(self.height()));
    }
};

/// `r` of `src` (`w` wide) into `out` (`r.width()` wide), opaque: GDI leaves
/// the alpha byte clear and the frame is opaque.
pub fn cropOpaque(out: []u32, src: []const u32, w: i32, r: Rect) void {
    const rw: usize = @intCast(r.width());
    const uw: usize = @intCast(w);
    var y = r.top;
    var row: usize = 0;
    while (y < r.bottom) : ({
        y += 1;
        row += 1;
    }) {
        const from = @as(usize, @intCast(y)) * uw + @as(usize, @intCast(r.left));
        for (out[row * rw ..][0..rw], src[from..][0..rw]) |*d, s| d.* = s | 0xFF000000;
    }
}

/// `r` of `src` into `out` as a list laid over the material `bg` (both `w`
/// wide): opaque where the list differs from the material, clear where it IS
/// the material. Over the same material that reproduces the stepped path's
/// `bg + (src - bg)` exactly, and at a layer opacity `a` its
/// `bg + a * (src - bg)` - so the glass and the card's edges hold still while
/// the rows travel.
pub fn cropMasked(out: []u32, src: []const u32, bg: []const u32, w: i32, r: Rect) void {
    const rw: usize = @intCast(r.width());
    const uw: usize = @intCast(w);
    var y = r.top;
    var row: usize = 0;
    while (y < r.bottom) : ({
        y += 1;
        row += 1;
    }) {
        const from = @as(usize, @intCast(y)) * uw + @as(usize, @intCast(r.left));
        for (out[row * rw ..][0..rw], src[from..][0..rw], bg[from..][0..rw]) |*d, s, b| {
            d.* = if ((s & 0x00FFFFFF) == (b & 0x00FFFFFF)) 0 else s | 0xFF000000;
        }
    }
}

/// Where a scope slide's two lists start and land, as X offsets in band
/// pixels: `slideAt` at both ends.
pub const SlidePlan = struct {
    old_to: f32,
    new_from: f32,
};

pub fn slidePlan(to_all: bool, slide_px: i32) SlidePlan {
    return .{
        .old_to = @floatFromInt(tr.slideAt(1, to_all, slide_px).old_dx),
        .new_from = @floatFromInt(tr.slideAt(0, to_all, slide_px).new_dx),
    };
}

/// A fold's moving band, in pixels below the group's header: the open band
/// `composeFold` reveals grows 0 -> `group_h` opening and shrinks back
/// closing. Null when there is nothing to fold or the group does not start
/// inside the region.
pub const FoldPlan = struct {
    /// The rows below the header the layers cover: header bottom to the
    /// region's bottom.
    rect: Rect,
    /// Rows of the group's own (tall) frame carried, cut at the region.
    tall_rows: i32,
    band_from: f32,
    band_to: f32,
};

pub fn foldPlan(region: Rect, y0: i32, group_h: i32, opening: bool) ?FoldPlan {
    if (group_h <= 0 or y0 < region.top or y0 >= region.bottom) return null;
    const rect: Rect = .{ .left = region.left, .top = y0, .right = region.right, .bottom = region.bottom };
    const g: f32 = @floatFromInt(group_h);
    return .{
        .rect = rect,
        .tall_rows = @min(group_h, rect.height()),
        .band_from = if (opening) 0 else g,
        .band_to = if (opening) g else 0,
    };
}

/// The pictures a transition is cut from, each `w` x `h` (the column's
/// client size), `0x00RRGGBB` top-down.
pub const Frames = struct {
    w: i32,
    h: i32,
    /// The bare material.
    bg: []const u32,
    /// Slide: the frame before and after. Fold: the frame that shows the
    /// group's rows (`a`) and the one that does not (`b`).
    a: []const u32,
    b: []const u32,
};

/// The three layers while a transition runs on the compositor.
pub const ListLayers = struct {
    base: Layer = .{},
    back: Layer = .{},
    front: Layer = .{},
    /// Declared and on screen: the transition is the compositor's.
    active: bool = false,

    /// Put a scope slide on the tree: `region` is the band the lists move
    /// in, `f.a` the frame before and `f.b` the frame after, `elapsed_s`
    /// into a slide `duration_s` long. `scratch` holds one band
    /// (`region.area()`). False: nothing is left on screen and the caller
    /// steps the slide.
    pub fn declareSlide(self: *ListLayers, s: *comp_overlay.Slot, region: Rect, f: Frames, to_all: bool, slide_px: i32, elapsed_s: f64, duration_s: f64, scratch: []u32) bool {
        if (self.slideImpl(s, region, f, to_all, slide_px, elapsed_s, duration_s, scratch)) {
            self.active = true;
            return true;
        }
        self.drop();
        return false;
    }

    /// Put a fold on the tree: `f.a` is the tall frame (the group's rows
    /// showing) and `f.b` the short one. False: nothing is left on screen.
    pub fn declareFold(self: *ListLayers, s: *comp_overlay.Slot, p: FoldPlan, f: Frames, elapsed_s: f64, duration_s: f64, scratch: []u32) bool {
        if (self.foldImpl(s, p, f, elapsed_s, duration_s, scratch)) {
            self.active = true;
            return true;
        }
        self.drop();
        return false;
    }

    const Tail = struct {
        buf: [comp_overlay.ease_segments]comp_overlay.Cubic = undefined,
        len: usize = 0,
        /// The curve's value where the tail starts.
        done: f32 = 0,
        left_s: f64 = 0,

        fn curve(self: *const Tail) []const comp_overlay.Cubic {
            return self.buf[0..self.len];
        }

        fn at(self: *const Tail, from: f32, to: f32) f32 {
            return from + (to - from) * self.done;
        }
    };

    /// The ease from `elapsed_s` on; null when the transition is over.
    fn tailFrom(elapsed_s: f64, duration_s: f64) ?Tail {
        if (duration_s <= 0 or elapsed_s >= duration_s) return null;
        var segs: [comp_overlay.ease_segments]comp_overlay.Cubic = undefined;
        comp_overlay.fitCurve(tr.ease, duration_s, &segs);
        var t: Tail = .{};
        t.len = comp_overlay.tailOf(&segs, elapsed_s, &t.buf).len;
        t.done = @floatCast(tr.ease(@max(elapsed_s, 0) / duration_s));
        t.left_s = duration_s - @max(elapsed_s, 0);
        return t;
    }

    /// The still base: the material over `r`, clipped to itself.
    fn putBase(self: *ListLayers, s: *comp_overlay.Slot, r: Rect, f: Frames, scratch: []u32) bool {
        for ([_]*Layer{ &self.base, &self.back, &self.front }) |l| {
            if (!l.sync(s)) return false;
        }
        if (self.back.generation != self.base.generation or self.front.generation != self.base.generation) return false;
        const rw: u32 = @intCast(r.width());
        const rh: u32 = @intCast(r.height());
        cropOpaque(scratch, f.bg, f.w, r);
        if (!self.base.setPixels(scratch, rw, rh)) return false;
        if (!self.base.setOffset(r.left, r.top)) return false;
        return self.base.setClip(0, 0, @floatFromInt(rw), @floatFromInt(rh));
    }

    fn slideImpl(self: *ListLayers, s: *comp_overlay.Slot, r: Rect, f: Frames, to_all: bool, slide_px: i32, elapsed_s: f64, duration_s: f64, scratch: []u32) bool {
        if (!r.fits(f.w, f.h) or scratch.len < r.area()) return false;
        const t = tailFrom(elapsed_s, duration_s) orelse return false;
        if (!self.putBase(s, r, f, scratch)) return false;
        const rw: u32 = @intCast(r.width());
        const rh: u32 = @intCast(r.height());
        const plan = slidePlan(to_all, slide_px);
        cropMasked(scratch, f.a, f.bg, f.w, r);
        if (!self.back.setPixels(scratch, rw, rh)) return false;
        cropMasked(scratch, f.b, f.bg, f.w, r);
        if (!self.front.setPixels(scratch, rw, rh)) return false;
        for ([_]*Layer{ &self.back, &self.front }) |l| _ = l.setNearest();
        if (!self.back.animateOffsetX(t.at(0, plan.old_to), plan.old_to, t.curve(), t.left_s)) return false;
        if (!self.back.animateOpacity(@intFromFloat(@round(t.at(255, 0))), 0, t.curve(), t.left_s)) return false;
        if (!self.front.animateOffsetX(t.at(plan.new_from, 0), 0, t.curve(), t.left_s)) return false;
        if (!self.front.animateOpacity(@intFromFloat(@round(t.at(0, 255))), 255, t.curve(), t.left_s)) return false;
        return self.attachAll();
    }

    fn foldImpl(self: *ListLayers, s: *comp_overlay.Slot, p: FoldPlan, f: Frames, elapsed_s: f64, duration_s: f64, scratch: []u32) bool {
        const r = p.rect;
        if (!r.fits(f.w, f.h) or scratch.len < r.area() or p.tall_rows <= 0) return false;
        const t = tailFrom(elapsed_s, duration_s) orelse return false;
        if (!self.putBase(s, r, f, scratch)) return false;
        const rw: u32 = @intCast(r.width());
        // Below the band: the short frame from the header down, riding the
        // band's edge.
        cropMasked(scratch, f.b, f.bg, f.w, r);
        if (!self.back.setPixels(scratch, rw, @intCast(r.height()))) return false;
        if (!self.back.animateOffsetY(t.at(p.band_from, p.band_to), p.band_to, t.curve(), t.left_s)) return false;
        // The band: the group's own rows in place, uncovered top-down.
        const tall: Rect = .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.top + p.tall_rows };
        cropOpaque(scratch, f.a, f.w, tall);
        if (!self.front.setPixels(scratch, rw, @intCast(p.tall_rows))) return false;
        if (!self.front.animateClipBottom(0, @floatFromInt(rw), t.at(p.band_from, p.band_to), p.band_to, t.curve(), t.left_s)) return false;
        for ([_]*Layer{ &self.back, &self.front }) |l| _ = l.setNearest();
        return self.attachAll();
    }

    /// The children go on the base first and the base on the tree last, so
    /// the whole set appears in one commit rather than a bare base for a
    /// frame.
    fn attachAll(self: *ListLayers) bool {
        // Front to back: each attach goes in front of the last.
        self.back.attachUnder(&self.base);
        self.front.attachUnder(&self.base);
        self.base.attach(.front);
        return self.base.attached and self.back.attached and self.front.attached;
    }

    /// Still on the tree `s` publishes: false means the layers can no longer
    /// stand for the transition (the device was lost) and the caller steps it.
    pub fn current(self: *const ListLayers, s: *const comp_overlay.Slot) bool {
        return self.active and self.base.generation == s.generation and self.base.active();
    }

    /// Take the layers off and let go of them.
    pub fn drop(self: *ListLayers) void {
        self.front.deinit();
        self.back.deinit();
        self.base.deinit();
        self.active = false;
    }
};

// --- tests ------------------------------------------------------------------

test "cropMasked: the material is clear, the list is opaque, both cut to the band (T2802)" {
    // 4 x 3, material 0x10 everywhere, the list's pixel at (2,1).
    const bg = [_]u32{0x10} ** 12;
    var src = bg;
    src[1 * 4 + 2] = 0x00AABBCC;
    // GDI's stray alpha byte does not count as a difference.
    src[1 * 4 + 1] = 0x7F000010;
    var out: [4]u32 = undefined;
    cropMasked(&out, &src, &bg, 4, .{ .left = 1, .top = 1, .right = 3, .bottom = 3 });
    try std.testing.expectEqual(@as(u32, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), out[1]);
    try std.testing.expectEqual(@as(u32, 0), out[2]);
    try std.testing.expectEqual(@as(u32, 0), out[3]);
}

test "cropOpaque forces the alpha byte on and keeps the band's pixels" {
    var src: [12]u32 = undefined;
    for (&src, 0..) |*p, i| p.* = @intCast(i);
    var out: [2]u32 = undefined;
    cropOpaque(&out, &src, 4, .{ .left = 2, .top = 2, .right = 4, .bottom = 3 });
    try std.testing.expectEqual(@as(u32, 0xFF00000A), out[0]);
    try std.testing.expectEqual(@as(u32, 0xFF00000B), out[1]);
}

test "a masked list over its material reproduces the stepped compose (T2802)" {
    // The stepped path lays `bg + a * (src - bg)`; the layer path lays
    // `a * layer + (1 - a) * bg` where the layer is opaque, `bg` where clear.
    // On the flat material the column paints, those are the same pixel.
    const bg: u32 = 0x00202830;
    const row: u32 = 0x00E0E8F0;
    const bgs = [_]u32{ bg, bg };
    const src = [_]u32{ bg, row };
    var layer: [2]u32 = undefined;
    cropMasked(&layer, &src, &bgs, 2, .{ .left = 0, .top = 0, .right = 2, .bottom = 1 });
    const a: f64 = 0.4;
    for (layer, src) |l, s| {
        for ([_]u5{ 0, 8, 16 }) |sh| {
            const b: f64 = @floatFromInt((bg >> sh) & 0xFF);
            const sv: f64 = @floatFromInt((s >> sh) & 0xFF);
            const stepped = b + a * (sv - b);
            const la: f64 = if (l >> 24 == 0) 0 else 1;
            const lv: f64 = @floatFromInt((l >> sh) & 0xFF);
            const comp = a * la * lv + (1 - a * la) * b;
            try std.testing.expectApproxEqAbs(stepped, comp, 0.5);
        }
    }
}

test "slidePlan: the lists start and land where slideAt puts them" {
    const to_all = slidePlan(true, 48);
    try std.testing.expectEqual(@as(f32, -48), to_all.old_to);
    try std.testing.expectEqual(@as(f32, 48), to_all.new_from);
    const back = slidePlan(false, 48);
    try std.testing.expectEqual(@as(f32, 48), back.old_to);
    try std.testing.expectEqual(@as(f32, -48), back.new_from);
}

test "foldPlan: the band opens 0 -> group_h, closes back, and is cut at the region" {
    const region: Rect = .{ .left = 4, .top = 40, .right = 200, .bottom = 300 };
    const open = foldPlan(region, 100, 80, true).?;
    try std.testing.expectEqual(@as(i32, 100), open.rect.top);
    try std.testing.expectEqual(@as(i32, 300), open.rect.bottom);
    try std.testing.expectEqual(@as(i32, 80), open.tall_rows);
    try std.testing.expectEqual(@as(f32, 0), open.band_from);
    try std.testing.expectEqual(@as(f32, 80), open.band_to);
    const close = foldPlan(region, 100, 80, false).?;
    try std.testing.expectEqual(@as(f32, 80), close.band_from);
    try std.testing.expectEqual(@as(f32, 0), close.band_to);
    // A group taller than what is left of the region is cut there.
    try std.testing.expectEqual(@as(i32, 40), foldPlan(region, 260, 120, true).?.tall_rows);
    // Nothing to fold, or a head outside the region: step it.
    try std.testing.expect(foldPlan(region, 100, 0, true) == null);
    try std.testing.expect(foldPlan(region, 20, 80, true) == null);
    try std.testing.expect(foldPlan(region, 300, 80, true) == null);
}

test "Rect.fits: inside the surface and not empty" {
    const r: Rect = .{ .left = 0, .top = 10, .right = 50, .bottom = 60 };
    try std.testing.expect(r.fits(50, 60));
    try std.testing.expect(!r.fits(49, 60));
    try std.testing.expect(!(Rect{ .left = 5, .top = 5, .right = 5, .bottom = 9 }).fits(50, 60));
    try std.testing.expectEqual(@as(usize, 2500), r.area());
}
