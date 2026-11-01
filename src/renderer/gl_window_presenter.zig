//! One GL presenter per window (T2610): the pure core.
//!
//! A top-level window that has had two plain WGL children swap into it leaks
//! about one window's worth of video memory on every hide/show and every
//! minimize/restore, and again when a second child that has swapped is
//! destroyed (T2599, proven with no Ghoztty code in
//! `test\zig-repro\t2599-wgl-multichild`). One GL child that composes every
//! pane and swaps once stays flat. So on this path each window owns one
//! presenter child; pane renderers stop swapping, draw into a slot texture in
//! the presenter's share group, and hand it over. The design, including where
//! the presenter sits among the window's children and why, is
//! `docs/design/win32-window-presenter.md`.
//!
//! This file is the part with no GL and no HWND in it, so the lanes can test
//! it: the knob, the renderer-to-presenter slot handoff, and the compose plan
//! (where a pane's texture goes in the presenter's back buffer and which
//! strips get the background). The window, thread and context halves build on
//! it.
const std = @import("std");
const builtin = @import("builtin");
const gl_comp_present = @import("gl_comp_present.zig");
const resize_paint = @import("../apprt/win32/resize_paint.zig");

/// The environment knob that puts a window's terminal panes on this path.
/// Off by default until T2610 step 5 makes it the default; until then it is
/// the A/B switch against the per-pane present.
pub const env_knob = "GHOZTTY_WINDOW_PRESENTER";

pub fn enabled() bool {
    if (comptime builtin.os.tag != .windows) return false;
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, env_knob) catch return false;
    defer std.heap.page_allocator.free(raw);
    return gl_comp_present.knobOn(raw);
}

/// How a window's terminal panes reach the screen.
pub const Path = enum {
    /// Each pane swaps its own child window, as before.
    per_pane,
    /// Each pane hands its frame to the window's one presenter.
    window_presenter,
};

pub const Choice = struct {
    path: Path,
    /// Set when the presenter knob was on and lost: the log says why.
    overridden_by_comp: bool = false,
};

/// The composition present (`GHOZTTY_COMP_PRESENT`, T2466) and this path both
/// replace the pane's swap, so they cannot both run. The composition knob
/// wins, because it is the older opt-in and a run that sets both is an A/B of
/// the composition path; the presenter knob is reported as ignored.
pub fn choose(presenter_knob: bool, comp_knob: bool) Choice {
    if (!presenter_knob) return .{ .path = .per_pane };
    if (comp_knob) return .{ .path = .per_pane, .overridden_by_comp = true };
    return .{ .path = .window_presenter };
}

// -------------------------------------------------------------------------
// The slot handoff.
// -------------------------------------------------------------------------

/// One published frame. `fence` is the renderer's `glFenceSync` object, held
/// opaquely here so this file needs no GL; the presenter `glWaitSync`s it
/// before sampling the slot's texture.
pub const Frame = struct {
    fence: usize,
    frame_id: u64,
    width: u32,
    height: u32,
};

/// The two slot textures between one pane renderer and its window's
/// presenter.
///
/// The presenter keeps HOLDING the slot it last composed until a newer one
/// replaces it, because a layout pass can ask it to re-compose without any
/// new frame: a resize re-draws the texture it already has, which is what
/// keeps the T2592 strip from ever reading black. So the renderer may only
/// write the slot the presenter is not holding.
///
/// Back-pressure replaces the vsync throttle the pane's own swap used to give
/// it: while a published frame has not been taken, `acquire` answers null and
/// the renderer waits for the presenter's signal, so it is never more than one
/// frame ahead.
pub const SlotPair = struct {
    mutex: std.Thread.Mutex = .{},
    frames: [2]?Frame = .{ null, null },
    /// Published and not yet taken by the presenter.
    pending: ?u1 = null,
    /// Taken by the presenter and still being composed from.
    held: ?u1 = null,

    /// The slot the renderer may draw into next, or null when it must wait
    /// for the presenter to take the frame it already published.
    pub fn acquire(self: *SlotPair) ?u1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending != null) return null;
        return if (self.held) |h| ~h else 0;
    }

    /// Hand a drawn slot to the presenter. Returns the fence of the frame this
    /// slot carried before, for the renderer to delete: sync objects belong to
    /// the share group, and by the time the renderer may reuse a slot the
    /// presenter has taken a newer frame, so nobody waits on the old fence
    /// again.
    pub fn publish(self: *SlotPair, slot: u1, frame: Frame) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.held == null or self.held.? != slot);
        const replaced: ?usize = if (self.frames[slot]) |old| old.fence else null;
        self.frames[slot] = frame;
        self.pending = slot;
        return replaced;
    }

    pub const Take = struct {
        slot: u1,
        frame: Frame,
        /// True when this is a frame the presenter has not composed before,
        /// so its fence still wants waiting on.
        fresh: bool,
    };

    /// The presenter's side: the newest frame to compose from, or null when
    /// the renderer has not published one yet. A fresh frame becomes the held
    /// one and frees the slot held before it for the renderer.
    pub fn take(self: *SlotPair) ?Take {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending) |p| {
            self.pending = null;
            self.held = p;
            return .{ .slot = p, .frame = self.frames[p].?, .fresh = true };
        }
        const h = self.held orelse return null;
        return .{ .slot = h, .frame = self.frames[h].?, .fresh = false };
    }

    /// Forget every frame: the share group was rebuilt (lost device, or the
    /// window turned translucent), so every texture and fence named here is
    /// gone with it.
    pub fn reset(self: *SlotPair) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Field by field: `self.* = .{}` would also reset the mutex held here.
        self.frames = .{ null, null };
        self.pending = null;
        self.held = null;
    }
};

// -------------------------------------------------------------------------
// The compose plan.
// -------------------------------------------------------------------------

/// A rectangle in the presenter's client, top-left origin (window space).
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) u32 {
        return @intCast(@max(self.right - self.left, 0));
    }
    pub fn height(self: Rect) u32 {
        return @intCast(@max(self.bottom - self.top, 0));
    }
};

/// A rectangle in GL window coordinates (bottom-left origin), as
/// `glBlitFramebuffer` and `glScissor` take it: x0, y0, x1, y1.
pub const GlRect = [4]i32;

/// Flip a window-space rectangle into the GL back buffer of a presenter
/// `client_h` pixels tall.
pub fn toGl(r: Rect, client_h: u32) GlRect {
    const h: i32 = @intCast(client_h);
    return .{ r.left, h - r.bottom, r.right, h - r.top };
}

/// Where one pane's frame goes this compose.
pub const PanePlan = struct {
    /// Null when there is no frame yet: the whole pane is background.
    blit: ?struct { src: GlRect, dst: GlRect },
    /// Background fills, GL coordinates. A pane with no frame has one fill,
    /// itself; a frame smaller than its pane (the layout outran the renderer)
    /// leaves at most a right strip and a bottom strip.
    fills: [2]GlRect,
    fill_len: u8,
};

/// Plan one pane: its rectangle in the presenter client, and the size of the
/// newest frame it published (null for none yet).
///
/// The frame is anchored at the pane's TOP-left, the way a terminal grid is
/// laid out: a frame shorter than its pane leaves its strip at the bottom,
/// and a frame larger than the pane (the pane just shrank) is cropped from the
/// bottom and right. Strips are `resize_paint.uncoveredStrips`, the same
/// geometry `fillUncoveredStrips` paints per pane today, moved here so the
/// presenter lays the background into the same back buffer it swaps.
pub fn planPane(pane: Rect, frame: ?struct { width: u32, height: u32 }, client_h: u32) PanePlan {
    var plan: PanePlan = .{ .blit = null, .fills = undefined, .fill_len = 0 };
    const pw = pane.width();
    const ph = pane.height();
    if (pw == 0 or ph == 0) return plan;

    const f = frame orelse {
        plan.fills[0] = toGl(pane, client_h);
        plan.fill_len = 1;
        return plan;
    };
    if (f.width == 0 or f.height == 0) {
        plan.fills[0] = toGl(pane, client_h);
        plan.fill_len = 1;
        return plan;
    }

    const dw = @min(f.width, pw);
    const dh = @min(f.height, ph);
    const fh: i32 = @intCast(f.height);
    // The frame's top rows are its HIGHEST GL rows, so a crop keeps
    // [fh - dh, fh).
    const dst: Rect = .{
        .left = pane.left,
        .top = pane.top,
        .right = pane.left + @as(i32, @intCast(dw)),
        .bottom = pane.top + @as(i32, @intCast(dh)),
    };
    plan.blit = .{
        .src = .{ 0, fh - @as(i32, @intCast(dh)), @intCast(dw), fh },
        .dst = toGl(dst, client_h),
    };

    const presented: u64 = (@as(u64, dw) << 32) | dh;
    const strips = resize_paint.uncoveredStrips(presented, pw, ph);
    for (strips.strips[0..strips.len]) |s| {
        const r: Rect = .{
            .left = pane.left + @as(i32, @intCast(s.left)),
            .top = pane.top + @as(i32, @intCast(s.top)),
            .right = pane.left + @as(i32, @intCast(s.right)),
            .bottom = pane.top + @as(i32, @intCast(s.bottom)),
        };
        plan.fills[plan.fill_len] = toGl(r, client_h);
        plan.fill_len += 1;
    }
    return plan;
}

// -------------------------------------------------------------------------
// Tests.
// -------------------------------------------------------------------------

const testing = std.testing;

test "choose: off by default, on with the knob, and the composition knob wins" {
    try testing.expectEqual(Path.per_pane, choose(false, false).path);
    try testing.expectEqual(Path.per_pane, choose(false, true).path);
    try testing.expect(!choose(false, true).overridden_by_comp);
    try testing.expectEqual(Path.window_presenter, choose(true, false).path);
    const both = choose(true, true);
    try testing.expectEqual(Path.per_pane, both.path);
    try testing.expect(both.overridden_by_comp);
}

fn frameN(n: u64) Frame {
    return .{ .fence = @intCast(100 + n), .frame_id = n, .width = 80, .height = 24 };
}

test "SlotPair: first frame goes to slot 0 and nothing is composed before it" {
    var s: SlotPair = .{};
    try testing.expectEqual(@as(?SlotPair.Take, null), s.take());
    try testing.expectEqual(@as(?u1, 0), s.acquire());
    try testing.expectEqual(@as(?usize, null), s.publish(0, frameN(1)));
    const t = s.take().?;
    try testing.expectEqual(@as(u1, 0), t.slot);
    try testing.expect(t.fresh);
    try testing.expectEqual(@as(u64, 1), t.frame.frame_id);
}

test "SlotPair: the renderer never writes the slot the presenter holds" {
    var s: SlotPair = .{};
    _ = s.publish(s.acquire().?, frameN(1));
    _ = s.take();
    // Held = 0, so the renderer gets 1, then 0 once 1 is taken.
    const a = s.acquire().?;
    try testing.expectEqual(@as(u1, 1), a);
    _ = s.publish(a, frameN(2));
    try testing.expectEqual(@as(u1, 1), s.take().?.slot);
    try testing.expectEqual(@as(?u1, 0), s.acquire());
}

test "SlotPair: back-pressure holds the renderer one frame ahead at most" {
    var s: SlotPair = .{};
    _ = s.publish(s.acquire().?, frameN(1));
    // Published and not taken: the renderer waits.
    try testing.expectEqual(@as(?u1, null), s.acquire());
    _ = s.take();
    try testing.expect(s.acquire() != null);
}

test "SlotPair: a re-compose with no new frame keeps the held one, not fresh" {
    var s: SlotPair = .{};
    _ = s.publish(s.acquire().?, frameN(7));
    try testing.expect(s.take().?.fresh);
    const again = s.take().?;
    try testing.expect(!again.fresh);
    try testing.expectEqual(@as(u64, 7), again.frame.frame_id);
    try testing.expectEqual(@as(u1, 0), again.slot);
}

test "SlotPair: publish hands back the fence of the frame it overwrote" {
    var s: SlotPair = .{};
    _ = s.publish(s.acquire().?, frameN(1)); // slot 0
    _ = s.take(); // held 0
    _ = s.publish(s.acquire().?, frameN(2)); // slot 1
    _ = s.take(); // held 1, slot 0 free again
    // Slot 0 still names frame 1's fence; reusing it returns that fence.
    try testing.expectEqual(@as(?usize, 101), s.publish(s.acquire().?, frameN(3)));
}

test "SlotPair: reset forgets every frame" {
    var s: SlotPair = .{};
    _ = s.publish(s.acquire().?, frameN(1));
    _ = s.take();
    s.reset();
    try testing.expectEqual(@as(?SlotPair.Take, null), s.take());
    try testing.expectEqual(@as(?u1, 0), s.acquire());
}

test "toGl: flips the Y axis against the client height" {
    const r: Rect = .{ .left = 10, .top = 20, .right = 110, .bottom = 70 };
    try testing.expectEqual(GlRect{ 10, 930, 110, 980 }, toGl(r, 1000));
}

test "planPane: no frame yet paints the whole pane with the background" {
    const pane: Rect = .{ .left = 0, .top = 0, .right = 400, .bottom = 300 };
    const p = planPane(pane, null, 300);
    try testing.expect(p.blit == null);
    try testing.expectEqual(@as(u8, 1), p.fill_len);
    try testing.expectEqual(GlRect{ 0, 0, 400, 300 }, p.fills[0]);
}

test "planPane: an exact frame blits whole and fills nothing" {
    const pane: Rect = .{ .left = 405, .top = 0, .right = 805, .bottom = 300 };
    const p = planPane(pane, .{ .width = 400, .height = 300 }, 300);
    try testing.expectEqual(@as(u8, 0), p.fill_len);
    try testing.expectEqual(GlRect{ 0, 0, 400, 300 }, p.blit.?.src);
    try testing.expectEqual(GlRect{ 405, 0, 805, 300 }, p.blit.?.dst);
}

test "planPane: a frame smaller than its pane is top-anchored with right and bottom strips" {
    // Pane 400x300 at (0,100) in a 400-tall client; frame 350x250.
    const pane: Rect = .{ .left = 0, .top = 100, .right = 400, .bottom = 400 };
    const p = planPane(pane, .{ .width = 350, .height = 250 }, 400);
    // Window rows 100..350 -> GL rows 50..300.
    try testing.expectEqual(GlRect{ 0, 50, 350, 300 }, p.blit.?.dst);
    try testing.expectEqual(GlRect{ 0, 0, 350, 250 }, p.blit.?.src);
    try testing.expectEqual(@as(u8, 2), p.fill_len);
    // Right strip: x 350..400, window rows 100..400 -> GL 0..300.
    try testing.expectEqual(GlRect{ 350, 0, 400, 300 }, p.fills[0]);
    // Bottom strip: x 0..350, window rows 350..400 -> GL 0..50.
    try testing.expectEqual(GlRect{ 0, 0, 350, 50 }, p.fills[1]);
}

test "planPane: a frame larger than its pane is cropped from the bottom and right" {
    const pane: Rect = .{ .left = 0, .top = 0, .right = 200, .bottom = 100 };
    const p = planPane(pane, .{ .width = 300, .height = 160 }, 100);
    try testing.expectEqual(@as(u8, 0), p.fill_len);
    // Keep the frame's TOP 100 rows: GL rows 60..160.
    try testing.expectEqual(GlRect{ 0, 60, 200, 160 }, p.blit.?.src);
    try testing.expectEqual(GlRect{ 0, 0, 200, 100 }, p.blit.?.dst);
}

test "planPane: an empty pane plans nothing" {
    const pane: Rect = .{ .left = 5, .top = 5, .right = 5, .bottom = 50 };
    const p = planPane(pane, .{ .width = 10, .height = 10 }, 100);
    try testing.expect(p.blit == null);
    try testing.expectEqual(@as(u8, 0), p.fill_len);
}
