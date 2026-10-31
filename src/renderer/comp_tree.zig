//! A pane's swap chain as a visual in its WINDOW's composition tree (T2553,
//! T2360 step 5b).
//!
//! Before this, each pane presented into a DirectComposition target on its
//! own child window (`gl_comp_present`, T2466). DWM moves that picture only
//! when the child window moves, so every pane motion was a `SetWindowPos`
//! and no compositor animation could reach it. Under `GHOZTTY_COMP_PANE_TREE`
//! the renderer makes the swap chain over a composition SURFACE HANDLE
//! instead (`DCompositionCreateSurfaceHandle` +
//! `CreateSwapChainForCompositionSurfaceHandle`), and the window thread wraps
//! that handle in a visual of the top-level window's own tree
//! (`chrome_comp.Host.paneAdopt`). The renderer keeps presenting on its own
//! thread and device; the window device places the visual. The child window
//! stays, at the pane's rect, for input, IME and focus only.
//!
//! The two threads meet in a `Slot` on the apprt surface, the same shape as
//! `comp_overlay.Slot`: the renderer `publish`es the handle and `retract`s it
//! before the presenter goes, each bumping a generation, and the window
//! thread re-adopts whenever the generation it adopted is not the current
//! one. The window thread reads the handle under the slot's lock, so a
//! retract can never close it in the middle of an adopt.
//!
//! Two flags travel the other way. `host_ready` is the window's promise that
//! it can carry the visual (its chrome host exists); the renderer only makes
//! a handle swap chain when it reads true, because a handle nobody adopts is
//! a pane that never appears. `refused` is the window saying an adopt failed:
//! the renderer drops to its own target-on-the-child-window path - the same
//! fallback any other composition failure takes.
const std = @import("std");

pub const HANDLE = *anyopaque;

/// The knob that opts panes into the window's tree. Also needs
/// `GHOZTTY_COMP_PRESENT` (the swap chain) and `GHOZTTY_COMP_CHROME` (the
/// window's host); without both it does nothing.
pub const env_knob = "GHOZTTY_COMP_PANE_TREE";

pub fn Adopted(comptime R: type) type {
    return struct { gen: u64, result: R };
}

pub const Slot = struct {
    mutex: std.Thread.Mutex = .{},
    handle: ?HANDLE = null,
    /// Moves on every publish and retract.
    generation: std.atomic.Value(u64) = .init(0),
    host_ready: std.atomic.Value(bool) = .init(false),
    refused: std.atomic.Value(bool) = .init(false),

    /// Renderer thread: the presenter's surface handle. The slot does not
    /// own it; the presenter closes it after `retract`.
    pub fn publish(self: *Slot, h: HANDLE) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.handle = h;
        self.refused.store(false, .release);
        _ = self.generation.fetchAdd(1, .acq_rel);
    }

    /// Renderer thread: the presenter is going. True when there was a handle
    /// to take back; once this returns no adopt is using it, so the caller
    /// may close it.
    pub fn retract(self: *Slot) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.handle == null) return false;
        self.handle = null;
        _ = self.generation.fetchAdd(1, .acq_rel);
        return true;
    }

    pub fn currentGeneration(self: *Slot) u64 {
        return self.generation.load(.acquire);
    }

    /// Window thread: run `adoptFn(ctx, handle)` with the handle held, so a
    /// concurrent retract waits for it. Returns null when nothing is
    /// published, else the generation the result belongs to with it.
    pub fn adopt(
        self: *Slot,
        ctx: anytype,
        comptime adoptFn: anytype,
    ) ?Adopted(@typeInfo(@TypeOf(adoptFn)).@"fn".return_type.?) {
        self.mutex.lock();
        defer self.mutex.unlock();
        const h = self.handle orelse return null;
        return .{ .gen = self.generation.load(.acquire), .result = adoptFn(ctx, h) };
    }

    /// Window thread: whether a handle is waiting to be adopted.
    pub fn published(self: *Slot) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.handle != null;
    }

    /// Window thread: the adopt failed; the renderer falls back.
    pub fn refuse(self: *Slot) void {
        self.refused.store(true, .release);
    }
};

/// Where a pane's visual goes, from the child window's client rect mapped
/// into the top-level client area. Hidden panes keep their offset and take
/// an empty clip, so nothing of a stale swap chain shows.
pub const Placement = struct {
    x: i32,
    y: i32,
    /// The clip, in the visual's own pixels: the pane's client size, so a
    /// swap chain that has not caught up with a shrink never covers the
    /// neighbour. Zero when hidden.
    w: i32,
    h: i32,
};

pub fn placement(x: i32, y: i32, w: i32, h: i32, visible: bool) Placement {
    if (!visible or w <= 0 or h <= 0) return .{ .x = x, .y = y, .w = 0, .h = 0 };
    return .{ .x = x, .y = y, .w = w, .h = h };
}

test "publish and retract move the generation; retract twice is a no-op" {
    var s: Slot = .{};
    var dummy: u8 = 0;
    const h: HANDLE = @ptrCast(&dummy);
    try std.testing.expectEqual(@as(u64, 0), s.currentGeneration());
    s.publish(h);
    try std.testing.expectEqual(@as(u64, 1), s.currentGeneration());
    try std.testing.expect(s.retract());
    try std.testing.expectEqual(@as(u64, 2), s.currentGeneration());
    try std.testing.expect(!s.retract());
    try std.testing.expectEqual(@as(u64, 2), s.currentGeneration());
}

test "adopt sees the handle and its generation, and nothing once retracted" {
    var s: Slot = .{};
    var dummy: u8 = 0;
    const h: HANDLE = @ptrCast(&dummy);
    const Ctx = struct {
        seen: ?HANDLE = null,
        fn take(self: *@This(), got: HANDLE) error{}!u32 {
            self.seen = got;
            return 7;
        }
    };
    var ctx: Ctx = .{};
    try std.testing.expect(s.adopt(&ctx, Ctx.take) == null);
    try std.testing.expect(!s.published());
    s.publish(h);
    try std.testing.expect(s.published());
    const r = s.adopt(&ctx, Ctx.take).?;
    try std.testing.expectEqual(@as(u64, 1), r.gen);
    try std.testing.expectEqual(@as(u32, 7), try r.result);
    try std.testing.expectEqual(h, ctx.seen.?);
    _ = s.retract();
    try std.testing.expect(s.adopt(&ctx, Ctx.take) == null);
}

test "a refusal is cleared by the next publish" {
    var s: Slot = .{};
    var dummy: u8 = 0;
    s.refuse();
    try std.testing.expect(s.refused.load(.acquire));
    s.publish(@ptrCast(&dummy));
    try std.testing.expect(!s.refused.load(.acquire));
}

test "placement clips to the pane and hides to an empty clip" {
    const shown = placement(10, 40, 300, 200, true);
    try std.testing.expectEqual(Placement{ .x = 10, .y = 40, .w = 300, .h = 200 }, shown);
    const hidden = placement(10, 40, 300, 200, false);
    try std.testing.expectEqual(@as(i32, 0), hidden.w);
    try std.testing.expectEqual(@as(i32, 0), hidden.h);
    try std.testing.expectEqual(@as(i32, 10), hidden.x);
    const empty = placement(0, 0, 0, 50, true);
    try std.testing.expectEqual(@as(i32, 0), empty.w);
}
