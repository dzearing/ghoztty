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

/// A rectangle in the pane window's own pixels (its client origin, banner
/// band included).
pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

/// The card shape the window path gives a pane child with `SetWindowRgn`
/// (T2570): mid-slide, the part a sliding card shows; in the elevated style,
/// the card's rounded rect. A region does not clip a visual on a topmost
/// target, so the tree visual carries the same shape as its clip.
pub const Shape = struct {
    /// Null: the whole window.
    rect: ?Rect = null,
    /// Corner radius in px; 0 is a plain rectangle.
    radius: f32 = 0,
    /// A header or banner above carries the card's top curve, so the pane's
    /// own top corners stay square.
    square_top: bool = false,
};

/// A visual's clip, in its own pixels.
pub const Clip = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    top_radius: f32 = 0,
    bottom_radius: f32 = 0,

    pub fn rounded(self: Clip) bool {
        return self.top_radius > 0 or self.bottom_radius > 0;
    }
};

/// Where a pane visual is and what of it shows (T2572): its offset in the
/// window and its clip, in fractional pixels - the two ends of a glide the
/// compositor runs.
pub const Pose = struct {
    x: f32 = 0,
    y: f32 = 0,
    clip: Clip = .{},

    pub fn of(at: Placement, c: Clip) Pose {
        return .{ .x = @floatFromInt(at.x), .y = @floatFromInt(at.y), .clip = c };
    }

    /// `f` of the way from `a` to `b`, every value on its own.
    pub fn lerp(a: Pose, b: Pose, f: f32) Pose {
        const L = struct {
            fn v(p: f32, q: f32, t: f32) f32 {
                return p + (q - p) * t;
            }
        };
        return .{
            .x = L.v(a.x, b.x, f),
            .y = L.v(a.y, b.y, f),
            .clip = .{
                .left = L.v(a.clip.left, b.clip.left, f),
                .top = L.v(a.clip.top, b.clip.top, f),
                .right = L.v(a.clip.right, b.clip.right, f),
                .bottom = L.v(a.clip.bottom, b.clip.bottom, f),
                .top_radius = b.clip.top_radius,
                .bottom_radius = b.clip.bottom_radius,
            },
        };
    }

    /// The farthest any one value has to go from `a` to `b`, in px.
    pub fn distance(a: Pose, b: Pose) f32 {
        var d = @max(@abs(b.x - a.x), @abs(b.y - a.y));
        inline for (.{ "left", "top", "right", "bottom" }) |f| d = @max(d, @abs(@field(b.clip, f) - @field(a.clip, f)));
        return d;
    }
};

/// A folding card's face, declared (T2778): every value of it that moves on
/// the glide's follower, in the window's client pixels. `clip` is the card -
/// what of the face shows; `content_x`/`_y` the carried frame's top-left,
/// pinned where the glide has the pane; `name_x`/`_y` the strip name's
/// picture; `opacity` the carried frame's strength, on its UNCLAMPED line
/// (it can run past 0 before the card lands; the compositor holds it there).
pub const FacePose = struct {
    clip: Clip = .{},
    content_x: f32 = 0,
    content_y: f32 = 0,
    name_x: f32 = 0,
    name_y: f32 = 0,
    opacity: f32 = 1,

    /// `f` of the way from `a` to `b`, every value on its own; the opacity
    /// held inside 0..1, as the compositor shows it.
    pub fn lerp(a: FacePose, b: FacePose, f: f32) FacePose {
        const L = struct {
            fn v(p: f32, q: f32, t: f32) f32 {
                return p + (q - p) * t;
            }
        };
        const c = Pose.lerp(.{ .clip = a.clip }, .{ .clip = b.clip }, f).clip;
        return .{
            .clip = c,
            .content_x = L.v(a.content_x, b.content_x, f),
            .content_y = L.v(a.content_y, b.content_y, f),
            .name_x = L.v(a.name_x, b.name_x, f),
            .name_y = L.v(a.name_y, b.name_y, f),
            .opacity = std.math.clamp(L.v(a.opacity, b.opacity, f), 0, 1),
        };
    }

    /// The farthest any one place has to go from `a` to `b`, in px (the
    /// opacity is not a distance).
    pub fn distance(a: FacePose, b: FacePose) f32 {
        var d = Pose.distance(.{ .clip = a.clip }, .{ .clip = b.clip });
        inline for (.{ "content_x", "content_y", "name_x", "name_y" }) |f| d = @max(d, @abs(@field(b, f) - @field(a, f)));
        return d;
    }

    /// Where along the way (0..1) the opacity line leaves 0..1, or null when
    /// it stays inside all the way: from there the compositor holds it.
    pub fn fadeKnee(a: FacePose, b: FacePose) ?f32 {
        const lo = @min(a.opacity, b.opacity);
        const hi = @max(a.opacity, b.opacity);
        if (lo >= 0 and hi <= 1) return null;
        if (a.opacity == b.opacity) return null;
        const edge: f32 = if (b.opacity < 0) 0 else 1;
        return std.math.clamp((edge - a.opacity) / (b.opacity - a.opacity), 0, 1);
    }
};

test "FacePose: lerp, distance and the fade's knee (T2778)" {
    const a: FacePose = .{ .clip = .{ .left = 100, .right = 500, .bottom = 600 }, .content_x = 100, .name_x = 100, .opacity = 1 };
    const b: FacePose = .{ .clip = .{ .left = 20, .right = 56, .bottom = 600, .top_radius = 6 }, .content_x = 20, .name_x = -162, .opacity = -0.25 };
    try std.testing.expectEqual(@as(f32, 444), FacePose.distance(a, b));
    const mid = FacePose.lerp(a, b, 0.5);
    try std.testing.expectEqual(@as(f32, 60), mid.content_x);
    try std.testing.expectEqual(@as(f32, 278), mid.clip.right);
    try std.testing.expectEqual(@as(f32, 0.375), mid.opacity);
    // The line crosses 0 at 0.8 of the way; the pose holds it there.
    try std.testing.expectEqual(@as(f32, 0.8), FacePose.fadeKnee(a, b).?);
    try std.testing.expectEqual(@as(f32, 0), FacePose.lerp(a, b, 0.9).opacity);
    // Inside 0..1 all the way: no knee.
    try std.testing.expectEqual(@as(?f32, null), FacePose.fadeKnee(a, .{ .opacity = 0 }));
}

test "Pose: lerp moves every value on its own; distance is the farthest one (T2572)" {
    const a: Pose = .{ .x = 100, .y = 0, .clip = .{ .left = 0, .top = -20, .right = 400, .bottom = 600 } };
    const b: Pose = .{ .x = 20, .y = 0, .clip = .{ .left = 0, .top = -20, .right = 10, .bottom = 600, .top_radius = 6 } };
    try std.testing.expectEqual(@as(f32, 390), Pose.distance(a, b));
    const mid = Pose.lerp(a, b, 0.5);
    try std.testing.expectEqual(@as(f32, 60), mid.x);
    try std.testing.expectEqual(@as(f32, 205), mid.clip.right);
    try std.testing.expectEqual(@as(f32, -20), mid.clip.top);
    try std.testing.expectEqual(b, Pose.lerp(a, b, 1));
    try std.testing.expectEqual(@as(f32, 0), Pose.distance(b, b));
}

/// The clip for a placed visual whose origin sits `above` px below the pane
/// window's top (the banner band), unclipped over that band, cut to `shape`.
/// An empty placement or an empty cut clips to nothing.
pub fn clip(at: Placement, above: i32, shape: Shape) Clip {
    if (at.w <= 0 or at.h <= 0) return .{};
    const band = @max(above, 0);
    var c: Clip = .{
        .left = 0,
        .top = -@as(f32, @floatFromInt(band)),
        .right = @floatFromInt(at.w),
        .bottom = @floatFromInt(at.h),
    };
    const r = shape.rect orelse return c;
    c.left = @max(c.left, @as(f32, @floatFromInt(r.left)));
    c.top = @max(c.top, @as(f32, @floatFromInt(r.top - band)));
    c.right = @min(c.right, @as(f32, @floatFromInt(r.right)));
    c.bottom = @min(c.bottom, @as(f32, @floatFromInt(r.bottom - band)));
    if (c.right <= c.left or c.bottom <= c.top) return .{};
    if (shape.radius > 0) {
        c.bottom_radius = shape.radius;
        if (!shape.square_top) c.top_radius = shape.radius;
    }
    return c;
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

test "clip with no shape is the whole placement, unclipped over the band" {
    const c = clip(placement(10, 40, 300, 200, true), 24, .{});
    try std.testing.expectEqual(Clip{ .left = 0, .top = -24, .right = 300, .bottom = 200 }, c);
    try std.testing.expect(!c.rounded());
    // Hidden: nothing, whatever the shape.
    try std.testing.expectEqual(Clip{}, clip(placement(10, 40, 300, 200, false), 24, .{ .radius = 8 }));
}

test "a slide cut clips the visual to what the card shows" {
    // The pane going into its strip keeps its full size; the cut leaves its
    // left 120 px, and the band moves the cut up into the visual's pixels.
    const at = placement(0, 30, 300, 200, true);
    const c = clip(at, 30, .{ .rect = .{ .left = 0, .top = 0, .right = 120, .bottom = 230 } });
    try std.testing.expectEqual(Clip{ .left = 0, .top = -30, .right = 120, .bottom = 200 }, c);
    // A cut past the window is held to the placement.
    const wide = clip(at, 0, .{ .rect = .{ .left = -50, .top = -50, .right = 900, .bottom = 900 } });
    try std.testing.expectEqual(Clip{ .left = 0, .top = 0, .right = 300, .bottom = 200 }, wide);
    // A cut to nothing hides it.
    try std.testing.expectEqual(Clip{}, clip(at, 0, .{ .rect = .{ .left = 40, .top = 0, .right = 40, .bottom = 200 } }));
}

test "an elevated card rounds its corners, and a square top keeps them square" {
    const at = placement(0, 0, 300, 200, true);
    const card: Rect = .{ .left = 0, .top = 0, .right = 300, .bottom = 200 };
    const round = clip(at, 0, .{ .rect = card, .radius = 8 });
    try std.testing.expectEqual(@as(f32, 8), round.top_radius);
    try std.testing.expectEqual(@as(f32, 8), round.bottom_radius);
    try std.testing.expect(round.rounded());
    const square = clip(at, 0, .{ .rect = card, .radius = 8, .square_top = true });
    try std.testing.expectEqual(@as(f32, 0), square.top_radius);
    try std.testing.expectEqual(@as(f32, 8), square.bottom_radius);
}
