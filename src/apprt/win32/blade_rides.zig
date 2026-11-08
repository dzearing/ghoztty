//! The tucked strips' blade shadows on the compositor (T2796): each resting
//! strip's shadow goes up as a `blade_layer` picture of its own, under the
//! chrome host's shadow root, and the desk composes that strip without it -
//! so a desk whose only change is a blade it no longer bakes, or a stack
//! that moves while its strips keep their keys, recomposes less.
//!
//! The window holds one `Set`, keyed by the strip's pane (as its glow layers
//! are), because a strip has no pane visual to own its layer the way
//! `Surface.tree_shadow` is owned. A slot is re-rendered only when its
//! `blade_layer.Key` changes - its size, the style, the collapse, or a band
//! in front of it moving next to it - and otherwise only moved.
//!
//! Which strips ride (`ridable`): a strip at rest with a solid band. A card
//! still gliding into or out of its strip stays baked: its key changes every
//! frame (the collapse, and the rect with it), so riding it trades the
//! desk's partial recompose of the strip it is already redrawing for a
//! render and an upload per frame (measured in the T2796 test below). A
//! glass band reads the bare desk through it, and the mask is only proven
//! against solid bands (T2743), so a glass stack keeps baking.

const std = @import("std");
const chrome_comp = @import("chrome_comp.zig");
const blade_layer = @import("blade_layer.zig");
const pane_stack_strip = @import("pane_stack_strip.zig");

pub const max = 32;

const Slot = struct {
    /// The strip's pane, as an address; 0 is a free slot.
    id: usize = 0,
    sv: chrome_comp.ShadowVis = .{},
    key: ?blade_layer.Key = null,
    /// The host build (`Host.rebuilds`) it was uploaded under.
    epoch: u32 = 0,
};

/// The on-screen oracle's controls (scripts\comp-shadow-onscreen.ps1 shape):
/// the desk keeps baking a blade that went up, and a layer laid without
/// keeping off the bands in front.
pub const Knobs = struct { double: bool = false, nomask: bool = false };

/// Whether a strip's blade shadow may ride: at rest, with a solid band.
pub fn ridable(b: pane_stack_strip.Band) bool {
    return b.band and b.collapse >= 1 and b.glass == null;
}

/// The layer key for `bands[i]`, or null when it does not ride (or casts
/// nothing, which the desk does not lay either).
pub fn keyFor(bands: []const pane_stack_strip.Band, i: usize, is_light: bool, scale: f32, radius: i32, nomask: bool) ?blade_layer.Key {
    if (!ridable(bands[i])) return null;
    const k = if (nomask)
        blade_layer.Key.of(bands[i], is_light, scale, radius)
    else
        blade_layer.Key.inStack(bands, i, is_light, scale, radius);
    return if (k.casts()) k else null;
}

pub const Set = struct {
    slots: [max]Slot = [_]Slot{.{}} ** max,
    /// How many were up after the last `sync`, for the log line.
    up: usize = 0,

    /// Window thread, from the desk paint, before the desk composes: put
    /// up every ridable strip of `bands` (desk pixels, bottom first; `ids`
    /// the strips' panes in the same order) and clear its `blade`, so the
    /// desk lays it without its shadow; take down every other slot. `on`
    /// false takes every layer down, back into the compose. Returns how
    /// many are up.
    pub fn sync(
        self: *Set,
        alloc: std.mem.Allocator,
        host: *chrome_comp.Host,
        bands: []pane_stack_strip.Band,
        ids: []const usize,
        is_light: bool,
        scale: f32,
        radius: i32,
        on: bool,
        knobs: Knobs,
    ) usize {
        var seen = [_]bool{false} ** max;
        var up: usize = 0;
        if (on and host.shadowAvailable()) {
            // Keys first: `inStack` reads the bands in front, and clearing a
            // `blade` changes nothing it reads, but the keys must all be of
            // the same picture.
            var keys: [max]?blade_layer.Key = [_]?blade_layer.Key{null} ** max;
            const n = @min(bands.len, ids.len, max);
            for (0..n) |i| keys[i] = keyFor(bands, i, is_light, scale, radius, knobs.nomask);
            for (0..n) |i| {
                const key = keys[i] orelse continue;
                const s = self.find(ids[i]) orelse continue;
                if (!self.ride(alloc, host, &self.slots[s], ids[i], key, bands[i].tab)) continue;
                seen[s] = true;
                if (!knobs.double) bands[i].blade = false;
                up += 1;
            }
        }
        for (&self.slots, 0..) |*sl, s| {
            if (sl.id != 0 and !seen[s]) drop(host, sl);
        }
        self.up = up;
        return up;
    }

    /// The slot holding `id`, else a free one; null when every slot is taken
    /// (that strip keeps baking).
    fn find(self: *const Set, id: usize) ?usize {
        for (self.slots, 0..) |sl, s| if (sl.id == id) return s;
        for (self.slots, 0..) |sl, s| if (sl.id == 0) return s;
        return null;
    }

    fn ride(self: *Set, alloc: std.mem.Allocator, host: *chrome_comp.Host, sl: *Slot, id: usize, key: blade_layer.Key, tab: pane_stack_strip.Rect) bool {
        _ = self;
        // A rebuilt host's tree no longer holds it: only the references go.
        if (sl.sv.live() and sl.epoch != host.rebuilds) {
            chrome_comp.Host.releaseShadow(&sl.sv);
            sl.key = null;
        }
        sl.id = id;
        const fresh = !host.shadowCurrent(&sl.sv) or sl.key == null or !std.meta.eql(sl.key.?, key);
        if (fresh) {
            var layer = (blade_layer.render(alloc, key) catch null) orelse {
                drop(host, sl);
                return false;
            };
            defer layer.deinit(alloc);
            host.bladeUpload(&sl.sv, layer.px, layer.w, layer.h) catch {
                const f = chrome_comp.Host.lastFailure();
                log.warn("blade layer visual failed at {s}: hr=0x{x:0>8}; the desk keeps its shadow", .{ f.stage, chrome_comp.hex(f.hr) });
                drop(host, sl);
                return false;
            };
            sl.key = key;
            sl.epoch = host.rebuilds;
        }
        const reach: f32 = @floatFromInt(key.reach());
        const at = [2]f32{ @as(f32, @floatFromInt(tab.left)) - reach, @as(f32, @floatFromInt(tab.top)) - reach };
        host.shadowShow(&sl.sv, 1, at) catch {
            const f = chrome_comp.Host.lastFailure();
            log.warn("blade layer visual show failed at {s}: hr=0x{x:0>8}; the desk keeps its shadow", .{ f.stage, chrome_comp.hex(f.hr) });
            drop(host, sl);
            return false;
        };
        return true;
    }

    /// Take every layer down (the desk is off the compositor).
    pub fn dropAll(self: *Set, host: ?*chrome_comp.Host) void {
        for (&self.slots) |*sl| {
            if (sl.id == 0) continue;
            if (host) |h| drop(h, sl) else {
                chrome_comp.Host.releaseShadow(&sl.sv);
                sl.* = .{};
            }
        }
        self.up = 0;
    }
};

fn drop(host: *chrome_comp.Host, sl: *Slot) void {
    if (sl.sv.live()) {
        if (host.rebuilds == sl.epoch) host.shadowDrop(&sl.sv) else chrome_comp.Host.releaseShadow(&sl.sv);
    }
    sl.* = .{};
}

const log = std.log.scoped(.blade_rides);

const testing = std.testing;
const color_math = @import("color_math.zig");

fn stack(collapse_last: f32, band_last: bool) [3]pane_stack_strip.Band {
    const rgb: color_math.Rgb = .{ .r = 58, .g = 61, .b = 68 };
    return .{
        .{ .tab = .{ .left = 40, .top = 30, .right = 74, .bottom = 230 }, .axis = .horizontal, .rgb = rgb },
        .{ .tab = .{ .left = 68, .top = 30, .right = 102, .bottom = 230 }, .axis = .horizontal, .rgb = rgb },
        .{ .tab = .{ .left = 96, .top = 30, .right = 130, .bottom = 230 }, .axis = .horizontal, .rgb = rgb, .collapse = collapse_last, .band = band_last },
    };
}

test "T2796: resting solid strips ride; a gliding card and a glass band stay baked" {
    const s = stack(0.4, false);
    try testing.expect(ridable(s[0]));
    try testing.expect(ridable(s[1]));
    try testing.expect(!ridable(s[2]));
    var g = s[0];
    g.glass = .{ .bg = .{ .r = 0, .g = 0, .b = 0 }, .sheet = .{} };
    try testing.expect(!ridable(g));
    // The key is the stack's: the front-most resting strip keeps off nothing
    // once the strip in front of it is a card still gliding.
    try testing.expectEqual(@as(u8, 0), keyFor(&s, 1, false, 1.5, 12, false).?.mask.n);
    try testing.expect(keyFor(&s, 0, false, 1.5, 12, false).?.mask.n > 0);
    try testing.expect(keyFor(&s, 2, false, 1.5, 12, false) == null);
    // `nomask` lays it bare.
    try testing.expectEqual(@as(u8, 0), keyFor(&s, 0, false, 1.5, 12, true).?.mask.n);
}

test "T2796: a desk that skips a riding strip's blade is the baked desk with the layer over it" {
    // The same picture blade_layer's own test holds, through the `blade`
    // flag the desk reads: the strips whose blade rides are composed by the
    // desk without it.
    const strips = stack(1, true);
    const alloc = testing.allocator;
    const w = 200;
    const h = 260;
    const want = try alloc.alloc(u32, w * h);
    defer alloc.free(want);
    const got = try alloc.alloc(u32, w * h);
    defer alloc.free(got);
    for (want, 0..) |*p, i| p.* = 0xFF00_0000 | @as(u32, @intCast(60 + (i % w) / 2)) << 8 | 90;
    @memcpy(got, want);
    var desk_bands = strips;
    for (&desk_bands, 0..) |*b, i| {
        if (keyFor(&strips, i, false, 1.5, 12, false) != null) b.blade = false;
    }
    const blade_shadow = @import("blade_shadow.zig");
    const shadow_layer = @import("shadow_layer.zig");
    for (strips, desk_bands) |s, d| {
        blade_shadow.paint(want, w, h, s.tab, s.axis, s.leads, s.collapse, false, 1.5, 12);
        pane_stack_strip.paintBand(want, w, h, s.tab, s.axis, s.rgb, 12);
        if (d.blade) blade_shadow.paint(got, w, h, d.tab, d.axis, d.leads, d.collapse, false, 1.5, 12);
        pane_stack_strip.paintBand(got, w, h, d.tab, d.axis, d.rgb, 12);
    }
    var laid: usize = 0;
    for (0..strips.len) |i| {
        const key = keyFor(&strips, i, false, 1.5, 12, false) orelse continue;
        var layer = (try blade_layer.render(alloc, key)).?;
        defer layer.deinit(alloc);
        const o = layer.origin(strips[i].tab);
        var as = layer.asShadow();
        shadow_layer.composite(got, w, h, &as, o[0], o[1]);
        laid += 1;
    }
    try testing.expectEqual(@as(usize, 3), laid);
    var worst: u32 = 0;
    for (want, got) |a, b| {
        var k: u5 = 0;
        while (k < 24) : (k += 8) {
            const x: i32 = @intCast((a >> k) & 0xFF);
            const y: i32 = @intCast((b >> k) & 0xFF);
            worst = @max(worst, @abs(x - y));
        }
    }
    // blade_layer's bound for the antialiased band edges.
    try testing.expect(worst <= 12);
}

test "T2796: what a gliding card's layer would cost per frame" {
    // The measurement behind keeping a gliding card baked: one render of
    // a full-height card part way into its strip, the work a ride would do
    // every frame of the glide (before its upload). Logged, not bounded:
    // a test that timed the box would be a flake.
    const alloc = testing.allocator;
    var b = stack(0.5, false)[2];
    b.tab = .{ .left = 0, .top = 0, .right = 400, .bottom = 900 };
    const key = blade_layer.Key.of(b, false, 1.5, 12);
    var timer = try std.time.Timer.start();
    const rounds = 5;
    for (0..rounds) |_| {
        var layer = (try blade_layer.render(alloc, key)).?;
        layer.deinit(alloc);
    }
    const us = timer.read() / rounds / std.time.ns_per_us;
    // Measured 2026-11-08 (Debug, this box): 2247 us a frame, before the
    // upload - most of a 120 Hz frame for one strip.
    std.log.scoped(.blade_rides).debug("gliding blade layer render 400x900 @1.5: {d} us", .{us});
}
