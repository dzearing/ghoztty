//! A pane drag's rows on the column's composition tree (T2803).
//!
//! While a pane is dragged over the sidebar, the rows slide aside to open a
//! gap (`pane_sidebar_reorder.Tween`, 200 ms on the shift curve) and the
//! dragged row follows the pointer. Stepped, the reorder clock repainted the
//! whole column every display frame for as long as any row was on its way,
//! so a busy window thread stuttered the slide. Here each row that slides is
//! captured once into a bitmap and hung on the sidebar's own tree
//! (`child_comp`, T2765) under a box clipped to the scrolling viewport; each
//! retarget is ONE declared offset animation that DWM plays. The held row
//! rides on the tree too, above them - the tree is topmost on the sidebar's
//! window, so a GDI-drawn held row would pass under the composed ones - and
//! moves per pointer input with a static offset, never per frame.
//!
//! The capture is a two-background matte: the row is painted over black and
//! over white, and the difference is its coverage, so the visual carries the
//! row's own antialiased edges, the lift's glass and its soft shadow with
//! whatever the column shows beneath it.
//!
//! Stays stepped: the held row's settle once let go (T2848), the tray
//! header's hairline and caption, and window/group drags in the all-windows
//! list (T2849).

const std = @import("std");
const builtin = @import("builtin");
const comp_overlay = @import("../../renderer/comp_overlay.zig");
const child_comp = @import("child_comp.zig");
const transition = @import("pane_sidebar_transition.zig");
const reorder = @import("pane_sidebar_reorder.zig");
const Rect = @import("pane_sidebar.zig").Rect;

const log = std.log.scoped(.pane_sidebar);
const Layer = comp_overlay.Layer;

/// Premultiplied BGRA from the same picture painted over black (`black`) and
/// over white (`white`), both `0x00RRGGBB`. A pixel's coverage is what the
/// background still shows through: `1 - (white - black) / 255`, averaged
/// over the channels (ClearType's per-channel coverage collapses to its
/// mean); the colour is what it put over black, never more than its alpha.
pub fn matte(black: []const u32, white: []const u32, out: []u32) void {
    for (out, 0..) |*o, i| {
        const b = black[i];
        const w = white[i];
        var through: u32 = 0;
        inline for (.{ 0, 8, 16 }) |sh| {
            const bc = (b >> sh) & 0xff;
            const wc = (w >> sh) & 0xff;
            through += if (wc > bc) wc - bc else 0;
        }
        const a: u32 = 255 - @min(255, (through + 1) / 3);
        var px: u32 = a << 24;
        inline for (.{ 0, 8, 16 }) |sh| {
            px |= @min((b >> sh) & 0xff, a) << sh;
        }
        o.* = px;
    }
}

/// How many of `px` carry any of the picture, and how many are solid: a
/// capture that came out empty, or as a block, is not a row (the log's
/// oracle, T2803).
pub fn coverage(px: []const u32) struct { any: usize, solid: usize } {
    var any: usize = 0;
    var solid: usize = 0;
    for (px) |p| {
        const a = p >> 24;
        if (a > 0) any += 1;
        if (a == 255) solid += 1;
    }
    return .{ .any = any, .solid = solid };
}

/// The shift curve over `ms`, from `elapsed_ms` in: what is left of a slide
/// that began before it could be declared. Empty once it is over.
pub fn slideCurve(ms: u64, elapsed_ms: u64, full: *[comp_overlay.ease_segments]comp_overlay.Cubic, out: *[comp_overlay.ease_segments + 1]comp_overlay.Cubic) []comp_overlay.Cubic {
    if (elapsed_ms >= ms) return out[0..0];
    const dur_s = @as(f64, @floatFromInt(ms)) / 1000;
    comp_overlay.fitCurve(transition.ease, dur_s, full);
    return comp_overlay.tailOf(full, @as(f64, @floatFromInt(elapsed_ms)) / 1000, out);
}

/// One row on the tree.
const Row = struct {
    key: usize,
    layer: Layer = .{},
    /// Its laid-out place (column px) with no slide.
    left: i32,
    top: i32,
    /// The tween last declared: a retarget restarts it.
    to: f64,
    start_ms: u64,
};

pub const cap = 64;

pub const ReorderComp = struct {
    /// At the viewport, clipped to it: a row sliding under the pinned head
    /// is cut there, as the paint cuts it.
    box: Layer = .{},
    /// The sliding rows, on the box under the held row.
    rows_box: Layer = .{},
    /// The viewport the box sits at.
    view: Rect = .{},
    generation: u64 = 0,
    rows: [cap]Row = undefined,
    count: usize = 0,
    held: Layer = .{},
    held_key: usize = 0,
    held_pad: [2]i32 = .{ 0, 0 },
    /// Slides declared and captures taken this drag, for the log and the oracle.
    declared: u64 = 0,
    captures: u64 = 0,

    pub fn active(self: *const ReorderComp) bool {
        return self.box.active();
    }

    /// Everything off the tree: the drag ended, a transition began, or the
    /// tree went.
    pub fn dropAll(self: *ReorderComp) void {
        if (!self.box.active()) return;
        self.held.deinit();
        self.held = .{};
        while (self.count > 0) {
            self.count -= 1;
            self.rows[self.count].layer.deinit();
        }
        self.rows_box.deinit();
        self.rows_box = .{};
        self.box.deinit();
        self.box = .{};
        log.info("pane sidebar reorder comp off slides={d} captures={d}", .{ self.declared, self.captures });
        self.declared = 0;
        self.captures = 0;
    }

    /// Ready the box at `view` on the tree. False: nothing can go on it, and
    /// the caller steps the drag.
    pub fn begin(self: *ReorderComp, host: *child_comp.Host, view: Rect, now_ms: u64) bool {
        if (comptime builtin.os.tag != .windows) return false;
        if (view.width() <= 0 or view.height() <= 0) return false;
        const s = host.ensure(now_ms, "reorder") orelse {
            self.dropAll();
            return false;
        };
        if (self.box.active() and (self.generation != s.generation or !std.meta.eql(self.view, view))) self.dropAll();
        if (self.box.active()) return true;
        if (!self.box.sync(s)) return self.fail();
        if (!self.box.setOffset(view.left, view.top)) return self.fail();
        if (!self.box.setRoundClip(@floatFromInt(view.width()), @floatFromInt(view.height()), 0)) return self.fail();
        self.box.attach(.front);
        if (!self.box.attached) return self.fail();
        if (!self.rows_box.sync(s)) return self.fail();
        self.rows_box.attachUnder(&self.box);
        if (!self.rows_box.attached) return self.fail();
        self.view = view;
        self.generation = s.generation;
        log.info("pane sidebar reorder comp on view={d},{d},{d},{d} generation={d}", .{ view.left, view.top, view.width(), view.height(), s.generation });
        return true;
    }

    fn fail(self: *ReorderComp) bool {
        self.rows_box.deinit();
        self.rows_box = .{};
        self.box.deinit();
        self.box = .{};
        self.dropAll();
        return false;
    }

    pub fn has(self: *const ReorderComp, key: usize) bool {
        for (self.rows[0..self.count]) |r| if (r.key == key) return true;
        return false;
    }

    pub fn find(self: *ReorderComp, key: usize) ?*Row {
        for (self.rows[0..self.count]) |*r| if (r.key == key) return r;
        return null;
    }

    /// Put row `key` on the tree from its captured pixels `px` (`w`x`h`,
    /// premultiplied), laid out at `r` (column px). False: it stays the
    /// paint's.
    pub fn addRow(self: *ReorderComp, host: *child_comp.Host, key: usize, px: []const u32, r: Rect, tw: reorder.Tween, now_ms: u64) bool {
        if (self.count == cap) return false;
        const s = host.ensure(now_ms, "reorder") orelse return false;
        self.rows[self.count] = .{ .key = key, .left = r.left, .top = r.top, .to = std.math.nan(f64), .start_ms = 0 };
        const row = &self.rows[self.count];
        const ok = row.layer.sync(s) and
            row.layer.setPixels(px, @intCast(r.width()), @intCast(r.height()));
        if (!ok) {
            row.layer.deinit();
            return false;
        }
        row.layer.attachUnder(&self.rows_box);
        if (!row.layer.attached) {
            row.layer.deinit();
            return false;
        }
        self.count += 1;
        self.captures += 1;
        const cv = coverage(px);
        log.debug("pane sidebar reorder comp row key={x} size={d}x{d} any={d} solid={d}", .{ key, r.width(), r.height(), cv.any, cv.solid });
        self.slide(row, tw, now_ms);
        return true;
    }

    /// Bring row `key` to where its slide `tw` has it - declared once per
    /// retarget, played by DWM until the next one.
    pub fn follow(self: *ReorderComp, key: usize, laid: Rect, tw: reorder.Tween, now_ms: u64) void {
        const row = self.find(key) orelse return;
        if (row.left != laid.left or row.top != laid.top) {
            // The list laid out again under the drag: re-place from scratch.
            row.left = laid.left;
            row.top = laid.top;
            row.to = std.math.nan(f64);
        }
        self.slide(row, tw, now_ms);
    }

    fn slide(self: *ReorderComp, row: *Row, tw: reorder.Tween, now_ms: u64) void {
        if (row.to == tw.to and row.start_ms == tw.start_ms) return;
        row.to = tw.to;
        row.start_ms = tw.start_ms;
        const x = row.left - self.view.left;
        const y: f64 = @floatFromInt(row.top - self.view.top);
        var full: [comp_overlay.ease_segments]comp_overlay.Cubic = undefined;
        var tail: [comp_overlay.ease_segments + 1]comp_overlay.Cubic = undefined;
        const elapsed = now_ms -| tw.start_ms;
        const curve = if (tw.from == tw.to) tail[0..0] else slideCurve(tw.ms, elapsed, &full, &tail);
        if (curve.len > 0) {
            _ = row.layer.setOffset(x, @intFromFloat(@round(y + tw.at(now_ms))));
            const left_s = @as(f64, @floatFromInt(tw.ms - elapsed)) / 1000;
            if (row.layer.animateOffsetY(@floatCast(y + tw.from), @floatCast(y + tw.to), curve, left_s)) {
                self.declared += 1;
                log.debug("pane sidebar reorder comp slide key={x} from={d:.0} to={d:.0} left_ms={d}", .{ row.key, tw.from, tw.to, tw.ms - elapsed });
                return;
            }
        }
        _ = row.layer.setOffset(x, @intFromFloat(@round(y + tw.to)));
    }

    /// The held row on the tree, above every sliding one: `px` (`w`x`h`) is
    /// its lifted picture, padded by `pad` around the row for the glass and
    /// shadow. Built once per drag; `moveHeld` follows the pointer.
    pub fn setHeld(self: *ReorderComp, host: *child_comp.Host, key: usize, px: []const u32, w: i32, h: i32, pad: [2]i32, now_ms: u64) bool {
        const s = host.ensure(now_ms, "reorder") orelse return false;
        self.held.deinit();
        self.held = .{};
        const ok = self.held.sync(s) and self.held.setPixels(px, @intCast(w), @intCast(h));
        if (!ok) {
            self.held.deinit();
            self.held = .{};
            return false;
        }
        self.held.attachUnder(&self.box);
        if (!self.held.attached) {
            self.held.deinit();
            self.held = .{};
            return false;
        }
        self.held_key = key;
        self.held_pad = pad;
        self.captures += 1;
        const cv = coverage(px);
        log.info("pane sidebar reorder comp held key={x} size={d}x{d} any={d} solid={d}", .{ key, w, h, cv.any, cv.solid });
        return true;
    }

    pub fn holds(self: *const ReorderComp, key: usize) bool {
        return self.held.active() and self.held_key == key;
    }

    /// The held row's place: its row at `left`,`top` (column px).
    pub fn moveHeld(self: *ReorderComp, left: i32, top: i32) void {
        if (!self.held.active()) return;
        _ = self.held.setOffset(left - self.held_pad[0] - self.view.left, top - self.held_pad[1] - self.view.top);
    }
};

test "matte: opaque, clear and half-covered pixels" {
    const black = [_]u32{ 0x00102030, 0x00000000, 0x00404040, 0x00ff0000 };
    const white = [_]u32{ 0x00102030, 0x00ffffff, 0x00c0c0c0, 0x00ff0000 };
    var out: [4]u32 = undefined;
    matte(&black, &white, &out);
    // Painted solid: the background never shows - its colour, fully opaque.
    try std.testing.expectEqual(@as(u32, 0xff102030), out[0]);
    // Painted nothing: fully clear.
    try std.testing.expectEqual(@as(u32, 0x00000000), out[1]);
    // Half white over the background: alpha half, colour premultiplied.
    try std.testing.expectEqual(@as(u32, 0x7f404040), out[2]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), out[3]);
}

test "matte: the colour never exceeds the alpha (premultiplied stays valid)" {
    // A ClearType fringe: one channel covered, two not.
    const black = [_]u32{0x00ff0000};
    const white = [_]u32{0x00ffffff};
    var out: [1]u32 = undefined;
    matte(&black, &white, &out);
    const a = out[0] >> 24;
    try std.testing.expect(((out[0] >> 16) & 0xff) <= a);
    try std.testing.expect((out[0] & 0xff) <= a);
}

test "matte: compositing the result over either background gives the paint back" {
    var prng = std.Random.DefaultPrng.init(2803);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        // A grey at coverage a over each background.
        const a: u32 = rnd.intRangeAtMost(u32, 0, 255);
        const g: u32 = rnd.intRangeAtMost(u32, 0, 255);
        const over = struct {
            fn f(cov: u32, col: u32, bg: u32) u32 {
                return (col * cov + bg * (255 - cov) + 127) / 255;
            }
        }.f;
        const bk = over(a, g, 0);
        const wh = over(a, g, 255);
        const black = [_]u32{bk | (bk << 8) | (bk << 16)};
        const white = [_]u32{wh | (wh << 8) | (wh << 16)};
        var out: [1]u32 = undefined;
        matte(&black, &white, &out);
        const oa = out[0] >> 24;
        const oc = out[0] & 0xff;
        for ([_]u32{ 0, 128, 255 }) |bg| {
            const want = over(a, g, bg);
            const got = oc + (bg * (255 - oa) + 127) / 255;
            try std.testing.expect(@abs(@as(i64, got) - @as(i64, want)) <= 2);
        }
    }
}

test "slideCurve: the whole shift, a tail, and nothing once over" {
    var full: [comp_overlay.ease_segments]comp_overlay.Cubic = undefined;
    var tail: [comp_overlay.ease_segments + 1]comp_overlay.Cubic = undefined;
    const all = slideCurve(reorder.shift_ms, 0, &full, &tail);
    try std.testing.expect(all.len > 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0), all[0].at(0), 1e-6);
    const part = slideCurve(reorder.shift_ms, 80, &full, &tail);
    try std.testing.expect(part.len > 0);
    // 80 ms in, the tail starts where the stepped tween is.
    try std.testing.expectApproxEqAbs(transition.progress(80, reorder.shift_ms), part[0].at(0), 0.01);
    try std.testing.expectEqual(@as(usize, 0), slideCurve(reorder.shift_ms, 200, &full, &tail).len);
}
