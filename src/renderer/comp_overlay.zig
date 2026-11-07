//! Overlay layers as child visuals of a pane's composition visual (T2467,
//! T2360 step 3).
//!
//! A pane presenting through `gl_comp_present` owns a DirectComposition
//! device whose root visual carries the pane's swap chain. The scrollbar, dim
//! wash, bell border and banner were each a `WS_EX_LAYERED` popup that had to
//! be moved by hand whenever the pane moved. A child visual of that root is
//! pane-local instead: it rides the pane window for free, and DWM composes it
//! over the swap chain in the same frame.
//!
//! Two threads meet here. The renderer thread builds and tears down the
//! presenter; the window thread owns the overlays. They meet through a
//! `Slot` on the apprt surface: the renderer `publish`es AddRef'd pointers to
//! the device, the D3D11 immediate context and the root visual, and
//! `retract`s them before the presenter goes, bumping a generation each time.
//! A `Layer` on the window thread borrows its own references and rebuilds
//! itself whenever the generation moves, so it never touches a tree that was
//! torn down under it. DirectComposition objects are free-threaded; the D3D11
//! immediate context is not, which is why the presenter turns on
//! `ID3D10Multithread` protection before it publishes the context.
//!
//! Vtable slots are from the 10.0.26100 SDK's dcomp.h / d3d11.h, with MSVC's
//! reversed overload order (the `IDCompositionAnimation*` overload sits before
//! the `float` one; mingw's dcomp.h spells that order out for non-MSVC).
const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.comp_overlay);

const GUID = std.os.windows.GUID;
const HRESULT = std.os.windows.HRESULT;
const HWND = std.os.windows.HWND;
pub const Obj = *anyopaque;

/// Posted to the pane window by the renderer thread after a publish or a
/// retract, so the window thread re-syncs its overlays onto (or off) the new
/// tree. WM_APP + 44; the WM_APP + n registry is spread across the win32
/// modules (App.zig, FrameClock.zig, Window.zig, ...).
pub const WM_APP_COMP_OVERLAY: u32 = 0x8000 + 44;

/// What a presenter shares with the pane's window thread.
pub const Shared = struct {
    dcomp: Obj, // IDCompositionDevice
    context: Obj, // ID3D11DeviceContext, multithread-protected
    root: Obj, // IDCompositionVisual carrying the swap chain
};

/// AddRef/Release, injectable so the slot's bookkeeping is unit-testable
/// without COM.
pub const RefOps = struct {
    add: *const fn (Obj) void,
    release: *const fn (Obj) void,
    /// IDCompositionDevice::Commit (T2606): DComp destroys a released visual
    /// only at the device's next commit.
    commit: *const fn (Obj) void,

    pub const com: RefOps = .{ .add = comAddRef, .release = comRelease, .commit = comCommit };
};

/// The meeting point between a pane's renderer thread and its window thread.
/// The slot owns one reference to each published pointer.
pub const Slot = struct {
    mutex: std.Thread.Mutex = .{},
    shared: ?Shared = null,
    /// Moves on every publish and retract. A layer built on generation g is
    /// stale as soon as this reads anything else.
    generation: u64 = 0,

    /// Renderer thread: hand over a presenter's tree. Takes its own refs.
    pub fn publish(self: *Slot, s: Shared, ops: RefOps) void {
        ops.add(s.dcomp);
        ops.add(s.context);
        ops.add(s.root);
        self.mutex.lock();
        const old = self.shared;
        self.shared = s;
        self.generation +%= 1;
        self.mutex.unlock();
        if (old) |o| releaseShared(o, ops);
    }

    /// Renderer thread: the presenter is going. Drops the slot's refs; a
    /// layer still holding its own keeps the old objects alive until it next
    /// syncs and lets go. Returns whether anything was published.
    pub fn retract(self: *Slot, ops: RefOps) bool {
        self.mutex.lock();
        const old = self.shared;
        self.shared = null;
        if (old != null) self.generation +%= 1;
        self.mutex.unlock();
        if (old) |o| releaseShared(o, ops);
        return old != null;
    }

    /// Window thread (T2562): retract only if the published tree is the one
    /// rooted at `root`. In pane-tree mode the window publishes its own tree
    /// for the pane's visual; when it lets that visual go it must not take
    /// down a tree the renderer has published since (a fallback presenter).
    pub fn retractRoot(self: *Slot, root: Obj, ops: RefOps) bool {
        self.mutex.lock();
        const old = self.shared;
        const mine = if (old) |o| o.root == root else false;
        if (mine) {
            self.shared = null;
            self.generation +%= 1;
        }
        self.mutex.unlock();
        if (mine) releaseShared(old.?, ops);
        return mine;
    }

    pub const Borrow = struct { generation: u64, shared: ?Shared };

    /// Window thread: the current generation, and - when it differs from
    /// `have` and something is published - the tree with a reference taken
    /// on each pointer for the caller (taken under the lock, so a racing
    /// retract cannot free them first). Same generation: `shared` is null
    /// and nothing was taken.
    pub fn borrow(self: *Slot, have: u64, ops: RefOps) Borrow {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.generation == have) return .{ .generation = have, .shared = null };
        const s = self.shared orelse return .{ .generation = self.generation, .shared = null };
        ops.add(s.dcomp);
        ops.add(s.context);
        ops.add(s.root);
        return .{ .generation = self.generation, .shared = s };
    }
};

/// T2606: the root visual carries the pane's swap chain, and whoever lets go
/// of it last - the presenter, the slot or an overlay layer - may be dropping
/// its final reference. DComp frees a released visual only at the device's
/// next Commit, so the commit comes AFTER the root's release and before the
/// device's: committing first (as every caller did) left the root and the
/// swap-chain buffers under it - ~3 MB a window-sized pane - pending on a
/// device nobody committed again, once for every closed window whose overlay
/// layer outlived its presenter.
fn releaseShared(s: Shared, ops: RefOps) void {
    ops.release(s.root);
    ops.commit(s.dcomp);
    ops.release(s.context);
    ops.release(s.dcomp);
}

// --- COM plumbing -----------------------------------------------------------

fn guid(comptime s: []const u8) GUID {
    return GUID.parse("{" ++ s ++ "}");
}

pub const IID_ID3D10Multithread = guid("9b7e4e00-342c-4106-a19f-4f2704f689f0");
const IID_ID3D11Texture2D = guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const DXGI_ALPHA_MODE_PREMULTIPLIED: u32 = 1;

// IDCompositionDevice (IUnknown 0-2).
const slot_dcomp_commit = 3;
const slot_dcomp_create_visual = 7;
const slot_dcomp_create_surface = 8;
const slot_dcomp_create_effect_group = 23;
const slot_dcomp_create_animation = 25;
// IDCompositionAnimation (dcompanimation.h): Reset 3, SetAbsoluteBeginTime 4,
// AddCubic 5, AddSinusoidal 6, AddRepeat 7, End 8.
const slot_anim_add_cubic = 5;
const slot_anim_end = 8;
// IDCompositionVisual. SetOffsetX(animation) 3, SetOffsetX(float) 4,
// SetOffsetY(animation) 5, SetOffsetY(float) 6 - the same overload order as
// SetTransform(transform) 7, SetTransform(matrix) 8.
const slot_visual_set_offset_x_float = 4;
const slot_visual_set_offset_y_float = 6;
const slot_visual_set_transform_matrix = 8;
const slot_visual_set_effect = 10;
const slot_visual_set_bitmap_interpolation_mode = 11;
const slot_visual_set_content = 15;
const slot_visual_add_visual = 16;
const slot_visual_remove_visual = 17;
// IDCompositionEffectGroup: SetOpacity(animation) 3, SetOpacity(float) 4.
const slot_effect_set_opacity_anim = 3;
const slot_effect_set_opacity_float = 4;
// IDCompositionSurface.
const slot_surface_begin_draw = 3;
const slot_surface_end_draw = 4;
// ID3D11DeviceContext (ID3D11DeviceChild 3-6, CopyResource 47).
const slot_d3d11_context_update_subresource = 48;
// ID3D10Multithread: Enter 3, Leave 4, SetMultithreadProtected 5.
pub const slot_multithread_set_protected = 5;

pub const D3D11_BOX = extern struct {
    left: u32,
    top: u32,
    front: u32,
    right: u32,
    bottom: u32,
    back: u32,
};

const POINT = extern struct { x: i32, y: i32 };

/// D2D_MATRIX_3X2_F, row-major: (m11 m12; m21 m22; dx dy).
pub const Matrix3x2 = extern struct {
    m11: f32 = 1,
    m12: f32 = 0,
    m21: f32 = 0,
    m22: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,

    pub fn scale(sx: f32, sy: f32) Matrix3x2 {
        return .{ .m11 = sx, .m22 = sy };
    }
};

/// DCOMPOSITION_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR.
const DCOMPOSITION_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR: u32 = 0;

/// How far a stretched solid layer reaches, in pane pixels (`Layer.cover`):
/// past any pane a window can hold, so the pane window's own bounds are what
/// clip it and no move or resize ever has to touch it.
pub const cover_extent: f32 = 16384;

pub fn slot(comptime F: type, obj: Obj, index: usize) F {
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(vtbl.*[index]);
}

fn comAddRef(obj: Obj) void {
    _ = slot(*const fn (Obj) callconv(.winapi) u32, obj, 1)(obj);
}

fn comRelease(obj: Obj) void {
    _ = slot(*const fn (Obj) callconv(.winapi) u32, obj, 2)(obj);
}

fn comCommit(dcomp: Obj) void {
    _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, dcomp, slot_dcomp_commit)(dcomp);
}

fn ok(hr: HRESULT) bool {
    return hr >= 0;
}

extern "user32" fn PostMessageW(?HWND, u32, usize, isize) callconv(.winapi) i32;

/// Renderer thread: tell the pane window its overlay tree changed.
pub fn notify(hwnd: HWND) void {
    if (comptime builtin.os.tag != .windows) return;
    _ = PostMessageW(hwnd, WM_APP_COMP_OVERLAY, 0, 0);
}

/// The box that places a w x h upload at a surface's BeginDraw offset.
pub fn uploadBox(x: i32, y: i32, w: u32, h: u32) D3D11_BOX {
    const l: u32 = @intCast(@max(x, 0));
    const t: u32 = @intCast(@max(y, 0));
    return .{ .left = l, .top = t, .front = 0, .right = l + w, .bottom = t + h, .back = 1 };
}

/// One `IDCompositionAnimation::AddCubic` segment (T2469): from `begin_s`
/// on, the value is c0 + c1*s + c2*s^2 + c3*s^3, with `s` the seconds since
/// `begin_s`. DirectComposition has no easing curves, only these polynomials,
/// so an ease is handed to it as a run of them (`fitCurve`).
pub const Cubic = struct {
    begin_s: f64,
    c0: f64,
    c1: f64,
    c2: f64,
    c3: f64,

    pub fn at(self: Cubic, t_s: f64) f64 {
        const s = t_s - self.begin_s;
        return self.c0 + s * (self.c1 + s * (self.c2 + s * self.c3));
    }
};

/// How many cubics an ease is cut into: enough that the fitted curve is
/// within a quarter of one 8-bit opacity step of the exact one.
pub const ease_segments = 8;

/// Fit a 0..1 easing curve `curve(t)` (t a 0..1 time fraction) over
/// `duration_s` as `out.len` C1-continuous Hermite cubics, each matching the
/// curve's value and slope at both of its ends.
pub fn fitCurve(curve: *const fn (f64) f64, duration_s: f64, out: []Cubic) void {
    const n: f64 = @floatFromInt(out.len);
    const h = duration_s / n;
    for (out, 0..) |*c, i| {
        const t0 = @as(f64, @floatFromInt(i)) / n;
        const t1 = @as(f64, @floatFromInt(i + 1)) / n;
        const p0 = curve(t0);
        const p1 = curve(t1);
        // Slopes per second: the curve's per-fraction slope over the duration.
        const m0 = slope(curve, t0) / duration_s;
        const m1 = slope(curve, t1) / duration_s;
        c.* = .{
            .begin_s = h * @as(f64, @floatFromInt(i)),
            .c0 = p0,
            .c1 = m0,
            .c2 = (3 * (p1 - p0) / h - 2 * m0 - m1) / h,
            .c3 = (2 * (p0 - p1) / h + m0 + m1) / (h * h),
        };
    }
}

/// How many cubics a follower is cut into (`fitFollower`): over the longest
/// glide on a screen (about 8 time constants) each piece spans half of one,
/// close enough that the fitted path is within half a pixel of the exact one.
pub const follower_segments = 16;

/// Fit the stack glide's follower (T2572; Mac a81db68f9, `pane_stack_slide`)
/// for a value `dist_px` away from its target: every moment it closes
/// `1 - exp(-dt / tau_s)` of what is left, and snaps once it is within
/// `snap_px`. Its whole path is known up front, so it is handed to the
/// compositor as `out.len` C1 Hermite cubics in 0..1 units of the way, the
/// last one landing exactly on 1 at the snap. Returns the snap time in
/// seconds; 0 (and `out` untouched) for a distance already within the snap.
pub fn fitFollower(dist_px: f64, tau_s: f64, snap_px: f64, out: []Cubic) f64 {
    const d = @abs(dist_px);
    if (d <= snap_px or tau_s <= 0) return 0;
    const span = tau_s * @log(d / snap_px);
    // Scaled so the snap's last half pixel is spread over the way instead
    // of jumping at the end.
    const scale = 1 / (1 - snap_px / d);
    const n: f64 = @floatFromInt(out.len);
    const h = span / n;
    for (out, 0..) |*c, i| {
        const t0 = h * @as(f64, @floatFromInt(i));
        const t1 = h * @as(f64, @floatFromInt(i + 1));
        const p0 = scale * (1 - @exp(-t0 / tau_s));
        const p1 = if (i + 1 == out.len) 1 else scale * (1 - @exp(-t1 / tau_s));
        const m0 = scale * @exp(-t0 / tau_s) / tau_s;
        const m1 = scale * @exp(-t1 / tau_s) / tau_s;
        c.* = .{
            .begin_s = t0,
            .c0 = p0,
            .c1 = m0,
            .c2 = (3 * (p1 - p0) / h - 2 * m0 - m1) / h,
            .c3 = (2 * (p0 - p1) / h + m0 + m1) / (h * h),
        };
    }
    return span;
}

/// Where a follower `fitFollower` declared is, `t_s` after it began, in 0..1
/// units of the way: the exact curve the cubics stand in for, for a glide
/// re-declared mid-way from the value it has reached (T2572).
pub fn followerAt(dist_px: f64, tau_s: f64, snap_px: f64, t_s: f64) f64 {
    const d = @abs(dist_px);
    if (d <= snap_px or tau_s <= 0) return 1;
    const span = tau_s * @log(d / snap_px);
    if (t_s >= span) return 1;
    if (t_s <= 0) return 0;
    return (1 - @exp(-t_s / tau_s)) / (1 - snap_px / d);
}

/// A curve's slope at `t`, one-sided at the ends so it never samples
/// outside 0..1 (where an ease is clamped flat).
fn slope(curve: *const fn (f64) f64, t: f64) f64 {
    const d = 1e-5;
    const lo = @max(t - d, 0);
    const hi = @min(t + d, 1);
    return (curve(hi) - curve(lo)) / (hi - lo);
}

/// One overlay as a child visual of a pane's root visual. Window thread only.
/// The visual is pane-local at (0,0); its pixels are premultiplied BGRA rows,
/// the same ones the popup path hands UpdateLayeredWindow.
pub const Layer = struct {
    /// The slot generation this layer is built on; 0 = not built.
    generation: u64 = 0,
    dev: ?Shared = null,
    visual: ?Obj = null,
    effect: ?Obj = null,
    surface: ?Obj = null,
    width: u32 = 0,
    height: u32 = 0,
    attached: bool = false,
    opacity: u8 = 255,
    /// The visual's offset in the pane (`setOffset`); a new visual is at 0,0.
    offset_x: i32 = 0,
    offset_y: i32 = 0,

    /// Bring the layer onto the slot's current tree. False: nothing is
    /// published (the pane presents with SwapBuffers), so the caller uses its
    /// popup. A generation change drops everything built on the old tree, so
    /// the caller must re-upload its pixels (`hasPixels` reads false).
    pub fn sync(self: *Layer, s: *Slot) bool {
        if (comptime builtin.os.tag != .windows) return false;
        const b = s.borrow(self.generation, RefOps.com);
        if (b.generation == self.generation) return self.dev != null;
        self.drop();
        self.generation = b.generation;
        const shared = b.shared orelse return false;
        self.dev = shared;
        self.build() catch {
            log.warn("overlay visual build failed; this overlay stays a popup", .{});
            self.drop();
            self.generation = b.generation;
            return false;
        };
        return true;
    }

    pub fn active(self: *const Layer) bool {
        return self.dev != null;
    }

    pub fn hasPixels(self: *const Layer) bool {
        return self.surface != null;
    }

    fn build(self: *Layer) error{ComFailed}!void {
        const d = self.dev.?;
        var v: ?Obj = null;
        if (!ok(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, d.dcomp, slot_dcomp_create_visual)(d.dcomp, &v))) return error.ComFailed;
        self.visual = v orelse return error.ComFailed;
        var e: ?Obj = null;
        if (!ok(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, d.dcomp, slot_dcomp_create_effect_group)(d.dcomp, &e))) return error.ComFailed;
        self.effect = e orelse return error.ComFailed;
        if (!ok(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.visual.?, slot_visual_set_effect)(self.visual.?, self.effect))) return error.ComFailed;
        self.applyOpacity();
    }

    /// Replace the pixels. `px` is `w * h` premultiplied BGRA, row-major.
    pub fn setPixels(self: *Layer, px: []const u32, w: u32, h: u32) bool {
        const d = self.dev orelse return false;
        const vis = self.visual orelse return false;
        if (w == 0 or h == 0 or px.len < @as(usize, w) * h) return false;
        if (self.surface == null or w != self.width or h != self.height) {
            if (self.surface) |old| comRelease(old);
            self.surface = null;
            var sf: ?Obj = null;
            if (!ok(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, d.dcomp, slot_dcomp_create_surface)(d.dcomp, w, h, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &sf))) return false;
            self.surface = sf orelse return false;
            self.width = w;
            self.height = h;
            if (!ok(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_visual_set_content)(vis, self.surface))) return false;
        }
        const sf = self.surface.?;
        var tex: ?Obj = null;
        var at: POINT = .{ .x = 0, .y = 0 };
        if (!ok(slot(*const fn (Obj, ?*const anyopaque, *const GUID, *?Obj, *POINT) callconv(.winapi) HRESULT, sf, slot_surface_begin_draw)(sf, null, &IID_ID3D11Texture2D, &tex, &at))) return false;
        const t = tex orelse {
            _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, sf, slot_surface_end_draw)(sf);
            return false;
        };
        const box = uploadBox(at.x, at.y, w, h);
        slot(*const fn (Obj, Obj, u32, *const D3D11_BOX, *const anyopaque, u32, u32) callconv(.winapi) void, d.context, slot_d3d11_context_update_subresource)(d.context, t, 0, &box, px.ptr, w * 4, 0);
        comRelease(t);
        if (!ok(slot(*const fn (Obj) callconv(.winapi) HRESULT, sf, slot_surface_end_draw)(sf))) return false;
        self.commit();
        return true;
    }

    /// Fill the whole pane with one premultiplied BGRA colour (T2491): a 1x1
    /// surface stretched, without filtering, to `cover_extent`. The pane
    /// window clips it, so it covers the pane at any size and a move or a
    /// resize is nothing to it - no re-upload, no transform, no commit.
    pub fn cover(self: *Layer, px: u32) bool {
        const vis = self.visual orelse return false;
        if (!self.setPixels(&.{px}, 1, 1)) return false;
        if (!ok(slot(*const fn (Obj, u32) callconv(.winapi) HRESULT, vis, slot_visual_set_bitmap_interpolation_mode)(vis, DCOMPOSITION_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR))) return false;
        const m = Matrix3x2.scale(cover_extent, cover_extent);
        if (!ok(slot(*const fn (Obj, *const Matrix3x2) callconv(.winapi) HRESULT, vis, slot_visual_set_transform_matrix)(vis, &m))) return false;
        self.commit();
        return true;
    }

    /// Where the layer's top-left sits in the pane, in pane pixels (T2492):
    /// a layer that is not the whole pane, like the scrollbar strip on the
    /// right edge. Only a pane resize moves it; a pane move never does.
    pub fn setOffset(self: *Layer, x: i32, y: i32) bool {
        const vis = self.visual orelse return false;
        if (x == self.offset_x and y == self.offset_y) return true;
        if (!ok(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_visual_set_offset_x_float)(vis, @floatFromInt(x)))) return false;
        if (!ok(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_visual_set_offset_y_float)(vis, @floatFromInt(y)))) return false;
        self.offset_x = x;
        self.offset_y = y;
        self.commit();
        return true;
    }

    /// Whole-layer opacity, the popup path's `SourceConstantAlpha`.
    pub fn setOpacity(self: *Layer, a: u8) void {
        if (a == self.opacity) return;
        self.opacity = a;
        if (self.effect == null) return;
        self.applyOpacity();
        self.commit();
    }

    /// Hand a whole fade to the compositor (T2469): `from` -> `to` along
    /// `curve` (from `fitCurve`, in 0..1 units) over `duration_s`, declared in
    /// one commit and then run by DWM at the display's refresh. No step of it
    /// waits on this thread. False: nothing was declared and the caller steps
    /// the fade itself with `setOpacity`.
    pub fn animateOpacity(self: *Layer, from: u8, to: u8, curve: []const Cubic, duration_s: f64) bool {
        if (comptime builtin.os.tag != .windows) return false;
        const d = self.dev orelse return false;
        const e = self.effect orelse return false;
        var made: ?Obj = null;
        if (!ok(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, d.dcomp, slot_dcomp_create_animation)(d.dcomp, &made))) return false;
        const anim = made orelse return false;
        // The effect keeps its own snapshot of the function once it is set.
        defer comRelease(anim);
        const f0: f64 = @as(f64, @floatFromInt(from)) / 255.0;
        const span: f64 = (@as(f64, @floatFromInt(to)) - @as(f64, @floatFromInt(from))) / 255.0;
        const add = slot(*const fn (Obj, f64, f32, f32, f32, f32) callconv(.winapi) HRESULT, anim, slot_anim_add_cubic);
        for (curve) |c| {
            if (!ok(add(anim, c.begin_s, @floatCast(f0 + span * c.c0), @floatCast(span * c.c1), @floatCast(span * c.c2), @floatCast(span * c.c3)))) return false;
        }
        const end_v: f32 = @as(f32, @floatFromInt(to)) / 255.0;
        if (!ok(slot(*const fn (Obj, f64, f32) callconv(.winapi) HRESULT, anim, slot_anim_end)(anim, duration_s, end_v))) return false;
        if (!ok(slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, e, slot_effect_set_opacity_anim)(e, anim))) return false;
        // Where the fade lands: a later static `setOpacity(to)` is a no-op.
        self.opacity = to;
        self.commit();
        return true;
    }

    fn applyOpacity(self: *Layer) void {
        const e = self.effect orelse return;
        const f: f32 = @as(f32, @floatFromInt(self.opacity)) / 255.0;
        _ = slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, e, slot_effect_set_opacity_float)(e, f);
    }

    /// Where `attach` puts a layer among the root's other children.
    pub const Place = enum { front, back };

    /// On or off the pane: added to / removed from the root's children.
    /// Added at the BACK of its siblings: with no reference visual,
    /// `AddVisual`'s insertAbove = TRUE means "above no sibling", which the
    /// docs spell out renders it below all of them. (This comment used to say
    /// "on top"; T2617 read the docs. Which overlay should win where two
    /// overlap is T2771.)
    pub fn setVisible(self: *Layer, on: bool) void {
        if (on) self.attach(.back) else self.detach();
    }

    /// On the pane at an explicit end of the sibling order (T2617): `.back`
    /// is under every other overlay and over only the swap chain the root
    /// itself carries. A no-op when already attached.
    pub fn attach(self: *Layer, place: Place) void {
        const d = self.dev orelse return;
        const vis = self.visual orelse return;
        if (self.attached) return;
        if (!ok(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, d.root, slot_visual_add_visual)(d.root, vis, addVisualInsertAbove(place), null))) return;
        self.attached = true;
        self.commit();
    }

    fn detach(self: *Layer) void {
        const d = self.dev orelse return;
        const vis = self.visual orelse return;
        if (!self.attached) return;
        _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, d.root, slot_visual_remove_visual)(d.root, vis);
        self.attached = false;
        self.commit();
    }

    fn commit(self: *Layer) void {
        const d = self.dev orelse return;
        _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, d.dcomp, slot_dcomp_commit)(d.dcomp);
    }

    /// Let go of everything built on the current tree.
    pub fn drop(self: *Layer) void {
        if (self.dev) |d| if (self.attached) if (self.visual) |vis| {
            _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, d.root, slot_visual_remove_visual)(d.root, vis);
        };
        if (self.surface) |o| comRelease(o);
        if (self.effect) |o| comRelease(o);
        if (self.visual) |o| comRelease(o);
        if (self.dev) |d| {
            // T2772: the commit comes AFTER the releases. It takes the visual
            // off the pane, and DComp destroys a released object only at the
            // device's next Commit: committing before the releases (as this
            // once did) left the surface, effect and visual pending, and they
            // kept the device - and the pane's whole D3D11 device, ~55 driver
            // threads and its GPU memory - alive after every closed window.
            // `releaseShared` commits after its root release too (T2606), so
            // that one commit covers this layer's objects as well.
            releaseShared(d, RefOps.com);
        }
        self.* = .{ .generation = self.generation, .opacity = self.opacity };
    }

    pub fn deinit(self: *Layer) void {
        self.drop();
        self.generation = 0;
    }
};

/// `AddVisual`'s insertAbove for a placement with no reference visual. The
/// flag reads backwards there: TRUE is "above no sibling", i.e. at the back.
pub fn addVisualInsertAbove(place: Layer.Place) i32 {
    return switch (place) {
        .back => 1,
        .front => 0,
    };
}

test "addVisualInsertAbove: with no reference, TRUE is the back (dcomp.h AddVisual remarks)" {
    try std.testing.expectEqual(@as(i32, 1), addVisualInsertAbove(.back));
    try std.testing.expectEqual(@as(i32, 0), addVisualInsertAbove(.front));
}

// --- tests ------------------------------------------------------------------

const Fake = struct {
    var refs: [3]i32 = .{ 0, 0, 0 };
    var objs: [3]u8 = .{ 0, 0, 0 };
    fn idx(o: Obj) usize {
        const p: *u8 = @ptrCast(o);
        return @intCast((@intFromPtr(p) - @intFromPtr(&objs[0])));
    }
    fn add(o: Obj) void {
        refs[idx(o)] += 1;
    }
    fn rel(o: Obj) void {
        refs[idx(o)] -= 1;
        record(if (idx(o) == 2) 'r' else if (idx(o) == 1) 'x' else 'd');
    }
    fn commit(o: Obj) void {
        _ = o;
        record('C');
    }
    /// The order releases and commits happened in (T2606).
    var trail: [32]u8 = undefined;
    var trail_len: usize = 0;
    fn record(c: u8) void {
        if (trail_len < trail.len) {
            trail[trail_len] = c;
            trail_len += 1;
        }
    }
    const ops: RefOps = .{ .add = add, .release = rel, .commit = commit };
    fn shared() Shared {
        return .{ .dcomp = &objs[0], .context = &objs[1], .root = &objs[2] };
    }
};

test "slot publish/borrow/retract keeps references balanced and moves the generation" {
    Fake.refs = .{ 0, 0, 0 };
    var s: Slot = .{};
    // Nothing published: a borrow at generation 0 sees nothing new.
    var b = s.borrow(0, Fake.ops);
    try std.testing.expectEqual(@as(u64, 0), b.generation);
    try std.testing.expect(b.shared == null);

    s.publish(Fake.shared(), Fake.ops);
    try std.testing.expectEqual([3]i32{ 1, 1, 1 }, Fake.refs);
    b = s.borrow(0, Fake.ops);
    try std.testing.expectEqual(@as(u64, 1), b.generation);
    try std.testing.expect(b.shared != null);
    try std.testing.expectEqual([3]i32{ 2, 2, 2 }, Fake.refs);

    // Same generation: nothing taken.
    const again = s.borrow(1, Fake.ops);
    try std.testing.expect(again.shared == null);
    try std.testing.expectEqual([3]i32{ 2, 2, 2 }, Fake.refs);

    // Retract drops only the slot's refs; the borrower's survive.
    try std.testing.expect(s.retract(Fake.ops));
    try std.testing.expectEqual(@as(u64, 2), s.generation);
    try std.testing.expectEqual([3]i32{ 1, 1, 1 }, Fake.refs);
    // A stale borrower learns the tree is gone.
    b = s.borrow(1, Fake.ops);
    try std.testing.expectEqual(@as(u64, 2), b.generation);
    try std.testing.expect(b.shared == null);
    releaseShared(Fake.shared(), Fake.ops);
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, Fake.refs);

    // A second retract is a no-op and does not move the generation.
    try std.testing.expect(!s.retract(Fake.ops));
    try std.testing.expectEqual(@as(u64, 2), s.generation);
}

test "publish over a live publish releases the old tree" {
    Fake.refs = .{ 0, 0, 0 };
    var s: Slot = .{};
    s.publish(Fake.shared(), Fake.ops);
    s.publish(Fake.shared(), Fake.ops);
    try std.testing.expectEqual([3]i32{ 1, 1, 1 }, Fake.refs);
    try std.testing.expectEqual(@as(u64, 2), s.generation);
    _ = s.retract(Fake.ops);
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, Fake.refs);
}

test "the last holder of a tree commits after the root goes and before the device does (T2606)" {
    Fake.refs = .{ 0, 0, 0 };
    var s: Slot = .{};
    s.publish(Fake.shared(), Fake.ops);
    // An overlay layer borrows the tree, then the presenter retracts it: the
    // layer is the root visual's last holder.
    const b = s.borrow(0, Fake.ops);
    try std.testing.expect(s.retract(Fake.ops));
    Fake.trail_len = 0;
    releaseShared(b.shared.?, Fake.ops);
    // root, commit, context, device: the commit that frees the root (and the
    // swap chain under it) runs while the device is still held.
    try std.testing.expectEqualStrings("rCxd", Fake.trail[0..Fake.trail_len]);
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, Fake.refs);
}

test "retractRoot takes back only its own tree (T2562)" {
    Fake.refs = .{ 0, 0, 0 };
    var s: Slot = .{};
    // Nothing published: nothing to take, the generation stays.
    try std.testing.expect(!s.retractRoot(&Fake.objs[2], Fake.ops));
    try std.testing.expectEqual(@as(u64, 0), s.generation);

    s.publish(Fake.shared(), Fake.ops);
    // A different root (the renderer's tree, say) is left alone.
    try std.testing.expect(!s.retractRoot(&Fake.objs[0], Fake.ops));
    try std.testing.expectEqual(@as(u64, 1), s.generation);
    try std.testing.expectEqual([3]i32{ 1, 1, 1 }, Fake.refs);

    // Its own root: retracted, refs released, generation moved.
    try std.testing.expect(s.retractRoot(&Fake.objs[2], Fake.ops));
    try std.testing.expectEqual(@as(u64, 2), s.generation);
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, Fake.refs);
    try std.testing.expect(s.shared == null);
}

test "uploadBox places the pixels at the BeginDraw offset" {
    const b = uploadBox(16, 32, 100, 50);
    try std.testing.expectEqual(D3D11_BOX{ .left = 16, .top = 32, .front = 0, .right = 116, .bottom = 82, .back = 1 }, b);
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(D3D11_BOX));
    try std.testing.expectEqual(@as(u32, 0x8000 + 44), WM_APP_COMP_OVERLAY);
}

fn smoothstep(t: f64) f64 {
    const c = std.math.clamp(t, 0, 1);
    return c * c * (3 - 2 * c);
}

test "fitCurve: segments tile the duration, are C0 at every joint and land on the curve" {
    var segs: [ease_segments]Cubic = undefined;
    fitCurve(smoothstep, 0.3, &segs);
    try std.testing.expectEqual(@as(f64, 0), segs[0].begin_s);
    try std.testing.expectApproxEqAbs(@as(f64, 0), segs[0].c0, 1e-12);
    for (segs[1..], 1..) |s, i| {
        // Each segment starts where the previous one ends.
        try std.testing.expectApproxEqAbs(segs[i - 1].at(s.begin_s), s.c0, 1e-9);
        try std.testing.expectApproxEqAbs(0.3 * @as(f64, @floatFromInt(i)) / ease_segments, s.begin_s, 1e-12);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1), segs[ease_segments - 1].at(0.3), 1e-9);
    // A cubic curve is reproduced (up to the slope estimate).
    for (0..301) |k| {
        const t_s = @as(f64, @floatFromInt(k)) / 1000.0;
        const i = @min(@as(usize, @intFromFloat(t_s / 0.3 * ease_segments)), ease_segments - 1);
        try std.testing.expectApproxEqAbs(smoothstep(t_s / 0.3), segs[i].at(t_s), 1e-6);
    }
}

fn easeInOutCubic(t: f64) f64 {
    if (t < 0.5) return 4 * t * t * t;
    const u = -2 * t + 2;
    return 1 - u * u * u / 2;
}

test "fitCurve: the hero slide's ease holds a 2000 px slide within half a pixel and lands exactly (T2573)" {
    var segs: [ease_segments]Cubic = undefined;
    fitCurve(easeInOutCubic, 0.35, &segs);
    try std.testing.expectApproxEqAbs(@as(f64, 0), segs[0].at(0), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), segs[ease_segments - 1].at(0.35), 1e-9);
    for (0..3501) |k| {
        const t_s = 0.35 * @as(f64, @floatFromInt(k)) / 3500.0;
        const i = @min(@as(usize, @intFromFloat(t_s / 0.35 * ease_segments)), ease_segments - 1);
        try std.testing.expect(@abs(segs[i].at(t_s) - easeInOutCubic(t_s / 0.35)) * 2000 < 0.5);
    }
}

test "fitFollower: the cubics track the exact follower within half a pixel and land at the snap (T2572)" {
    var segs: [follower_segments]Cubic = undefined;
    const tau = 0.045;
    // The widest glide a screen holds, and an ordinary one.
    for ([_]f64{ 2400, -900, 40 }) |dist| {
        const span = fitFollower(dist, tau, 0.5, &segs);
        try std.testing.expectApproxEqAbs(tau * @log(@abs(dist) / 0.5), span, 1e-12);
        try std.testing.expectApproxEqAbs(@as(f64, 0), segs[0].c0, 1e-12);
        try std.testing.expectApproxEqAbs(@as(f64, 1), segs[follower_segments - 1].at(span), 1e-9);
        for (segs[1..], 1..) |s, i| try std.testing.expectApproxEqAbs(segs[i - 1].at(s.begin_s), s.c0, 1e-9);
        for (0..1001) |k| {
            const t_s = span * @as(f64, @floatFromInt(k)) / 1000.0;
            const i = @min(@as(usize, @intFromFloat(t_s / span * follower_segments)), follower_segments - 1);
            const exact = followerAt(dist, tau, 0.5, t_s);
            try std.testing.expect(@abs(segs[i].at(t_s) - exact) * @abs(dist) < 0.5);
            // And the exact path is the stepped follower's, within the snap.
            const stepped = 1 - @exp(-t_s / tau);
            try std.testing.expect(@abs(exact - stepped) * @abs(dist) <= 0.5 + 1e-9);
        }
    }
    // Within the snap there is nothing to declare.
    try std.testing.expectEqual(@as(f64, 0), fitFollower(0.4, tau, 0.5, &segs));
    try std.testing.expectEqual(@as(f64, 1), followerAt(0.4, tau, 0.5, 0));
}

test "Matrix3x2 is D2D_MATRIX_3X2_F: six floats, scale on the diagonal" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Matrix3x2));
    const m = Matrix3x2.scale(3, 5);
    try std.testing.expectEqual([6]f32{ 3, 0, 0, 5, 0, 0 }, @as([6]f32, @bitCast(m)));
}
