//! The busy pills' sheens on the column's composition tree (T2801).
//!
//! The stepped sheen repaints every busy pill on every vblank, so a stall on
//! the window thread stutters it - and an agent working is exactly when the
//! app is busiest. Here each busy pill that is fully on show gets the pieces
//! `pane_sidebar_sheen_layers` cuts its sheen into, hung on the sidebar's own
//! tree (`child_comp`, T2765): declared once, then played by DWM. The paint
//! asks `place` for every moving pill it draws; a pill that is placed is left
//! out of the GDI paint and out of the motion frames, and one that cannot be
//! (no tree, a transition running, half scrolled away) is stepped as before.
//!
//! What it gives up: the tree is TOPMOST on the sidebar's window, so the
//! sheen lies over the pill's glyph and text instead of under them (Mac's is
//! a background). On dark the white glint over light text does not read as
//! a difference; on light it dims the label while it passes. T2844 lays the
//! text over it.

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const comp_overlay = @import("../../renderer/comp_overlay.zig");
const child_comp = @import("child_comp.zig");
const motion = @import("pane_sidebar_motion.zig");
const layers = @import("pane_sidebar_sheen_layers.zig");
const Rect = @import("pane_sidebar.zig").Rect;

const log = std.log.scoped(.pane_sidebar);
const Layer = comp_overlay.Layer;

/// One busy pill on the tree.
const Entry = struct {
    key: u64,
    rect: Rect,
    radius: i32,
    dark: bool,
    rim_w: f64,
    /// Which way the declared fade runs.
    on: bool,
    /// The slot generation the pieces were built on.
    generation: u64,
    /// Asked for by the paint that is running.
    seen: bool,
    box: Layer = .{},
    drift: Layer = .{},
    band: Layer = .{},
    rim: Layer = .{},

    fn deinit(self: *Entry) void {
        // Children before the box they hang on.
        self.rim.deinit();
        self.band.deinit();
        self.drift.deinit();
        self.box.deinit();
    }
};

pub const cap = motion.Dirty.cap;

pub const SheenComp = struct {
    entries: [cap]Entry = undefined,
    count: usize = 0,
    /// Pills placed (and so not stepped) since `beginPaint`.
    placed: usize = 0,
    /// Pieces built in this run, for the log and the oracle.
    builds: u64 = 0,

    pub fn beginPaint(self: *SheenComp) void {
        self.placed = 0;
        for (self.entries[0..self.count]) |*e| e.seen = false;
    }

    fn find(self: *SheenComp, key: u64) ?usize {
        for (self.entries[0..self.count], 0..) |e, i| if (e.key == key) return i;
        return null;
    }

    fn remove(self: *SheenComp, i: usize) void {
        self.entries[i].deinit();
        self.count -= 1;
        if (i != self.count) self.entries[i] = self.entries[self.count];
    }

    /// The pill `key` is stepped by the paint instead (or is gone): take its
    /// pieces off the tree. True when it had any.
    pub fn forget(self: *SheenComp, key: u64) bool {
        const i = self.find(key) orelse return false;
        self.remove(i);
        return true;
    }

    /// Everything off the tree: a transition is running, motion is off, or
    /// the column is going.
    pub fn dropAll(self: *SheenComp) void {
        while (self.count > 0) self.remove(self.count - 1);
    }

    /// After a paint that drew the whole column: what it did not ask for is
    /// no longer on show.
    pub fn endFullPaint(self: *SheenComp) void {
        var i: usize = 0;
        while (i < self.count) {
            if (!self.entries[i].seen) self.remove(i) else i += 1;
        }
    }

    /// Pills whose fade-out has run its course come off the tree; returns
    /// their rects (at most `cap`) so the caller repaints them and the next
    /// tally no longer counts them.
    pub fn reap(self: *SheenComp, fades: anytype, now_ms: u64, out: *motion.Dirty) void {
        var i: usize = 0;
        while (i < self.count) {
            const e = self.entries[i];
            const settled_off = for (fades) |f| {
                if (f.key == e.key) break !f.fade.on and f.fade.settled(now_ms);
            } else true;
            if (settled_off) {
                out.add(e.rect);
                log.debug("pane sidebar sheen comp reaped key={x}", .{e.key});
                self.remove(i);
            } else i += 1;
        }
    }

    /// Put the sheen `key` names on the tree at `r` (column px), fading as
    /// `fade` says. True: it is the compositor's now, and the paint draws no
    /// sheen there. False: nothing is on the tree for it and the caller
    /// steps it.
    pub fn place(self: *SheenComp, host: *child_comp.Host, alloc: std.mem.Allocator, key: u64, r: Rect, radius: i32, rim_w: f64, dark: bool, fade: motion.Fade, now_ms: u64) bool {
        if (comptime builtin.os.tag != .windows) return false;
        const w = r.width();
        const h = r.height();
        if (w <= 0 or h <= 0) {
            _ = self.forget(key);
            return false;
        }
        const s = host.ensure(now_ms, "sheen") orelse {
            _ = self.forget(key);
            return false;
        };
        const i = self.find(key) orelse blk: {
            if (self.count == cap) return false;
            self.entries[self.count] = .{ .key = key, .rect = r, .radius = radius, .dark = dark, .rim_w = rim_w, .on = fade.on, .generation = 0, .seen = false };
            self.count += 1;
            break :blk self.count - 1;
        };
        const e = &self.entries[i];
        e.seen = true;
        const same_shape = e.rect.width() == w and e.rect.height() == h and e.radius == radius and e.dark == dark and e.rim_w == rim_w;
        const fresh = e.generation == 0 or e.generation != s.generation or !same_shape;
        if (fresh) {
            e.deinit();
            e.* = .{ .key = key, .rect = r, .radius = radius, .dark = dark, .rim_w = rim_w, .on = fade.on, .generation = 0, .seen = true };
            if (!build(e, s, alloc, now_ms)) {
                self.remove(i);
                return false;
            }
            e.generation = s.generation;
            self.builds += 1;
            declareFade(e, fade, now_ms);
            log.debug("pane sidebar sheen comp placed key={x} rect={d},{d},{d},{d} generation={d} builds={d}", .{ key, r.left, r.top, w, h, s.generation, self.builds });
        } else {
            if (e.rect.left != r.left or e.rect.top != r.top) {
                if (!e.box.setOffset(r.left, r.top)) {
                    self.remove(i);
                    return false;
                }
                e.rect = r;
            }
            if (e.on != fade.on) declareFade(e, fade, now_ms);
        }
        self.placed += 1;
        return true;
    }
};

fn declareFade(e: *Entry, fade: motion.Fade, now_ms: u64) void {
    e.on = fade.on;
    var buf: [comp_overlay.ease_segments]comp_overlay.Cubic = undefined;
    const from: u8 = if (fade.on) 0 else 255;
    const to: u8 = if (fade.on) 255 else 0;
    if (layers.fadeRest(fade, now_ms, &buf)) |rest| {
        // Force the declare even when the static opacity already reads `to`.
        e.box.opacity = from;
        if (e.box.animateOpacity(from, to, rest.curve, rest.duration_s)) return;
    }
    e.box.setOpacity(to);
}

/// The box at the pill, clipped to it, and the three pieces under it.
fn build(e: *Entry, s: *comp_overlay.Slot, alloc: std.mem.Allocator, now_ms: u64) bool {
    const w: u32 = @intCast(e.rect.width());
    const h: u32 = @intCast(e.rect.height());
    const plan = layers.Plan.init(w, h, @floatFromInt(e.radius), e.rim_w, e.dark);
    if (!e.box.sync(s)) return false;
    e.box.setOpacity(0);
    if (!e.box.setOffset(e.rect.left, e.rect.top)) return false;
    if (!e.box.setRoundClip(@floatFromInt(w), @floatFromInt(h), @floatFromInt(e.radius))) return false;
    // Phase both loops to the shared origin on the performance counter.
    const freq = std.os.windows.QueryPerformanceFrequency();
    const qpc: i64 = @intCast(std.os.windows.QueryPerformanceCounter());
    const tick = w32.GetTickCount64();
    const origin = layers.originQpc(qpc, @intCast(freq), tick);
    _ = now_ms;
    inline for (.{ .{ &e.drift, layers.Plan.Piece.drift }, .{ &e.band, layers.Plan.Piece.band }, .{ &e.rim, layers.Plan.Piece.rim } }) |pc| {
        const layer = pc[0];
        const sz = plan.size(pc[1]);
        const px = alloc.alloc(u32, @as(usize, sz[0]) * sz[1]) catch return false;
        defer alloc.free(px);
        plan.render(pc[1], px);
        if (!layer.sync(s)) return false;
        if (!layer.setPixels(px, sz[0], sz[1])) return false;
        switch (pc[1]) {
            .drift => {
                const segs = plan.driftLoop();
                if (!layer.loopOffsetX(&segs, layers.drift_period_s, origin)) return false;
            },
            .band => {
                const segs = plan.bandLoop();
                if (!layer.loopOffsetX(&segs, layers.glint_period_s, origin)) return false;
            },
            .rim => {},
        }
        layer.attachUnder(&e.box);
        if (!layer.attached) return false;
    }
    e.box.attach(.front);
    return e.box.attached;
}
