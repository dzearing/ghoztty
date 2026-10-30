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

    pub const com: RefOps = .{ .add = comAddRef, .release = comRelease };
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

fn releaseShared(s: Shared, ops: RefOps) void {
    ops.release(s.root);
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
// IDCompositionVisual.
const slot_visual_set_effect = 10;
const slot_visual_set_content = 15;
const slot_visual_add_visual = 16;
const slot_visual_remove_visual = 17;
// IDCompositionEffectGroup: SetOpacity(animation) 3, SetOpacity(float) 4.
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

    /// Whole-layer opacity, the popup path's `SourceConstantAlpha`.
    pub fn setOpacity(self: *Layer, a: u8) void {
        if (a == self.opacity) return;
        self.opacity = a;
        if (self.effect == null) return;
        self.applyOpacity();
        self.commit();
    }

    fn applyOpacity(self: *Layer) void {
        const e = self.effect orelse return;
        const f: f32 = @as(f32, @floatFromInt(self.opacity)) / 255.0;
        _ = slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, e, slot_effect_set_opacity_float)(e, f);
    }

    /// On or off the pane: added to / removed from the root's children.
    pub fn setVisible(self: *Layer, on: bool) void {
        const d = self.dev orelse return;
        const vis = self.visual orelse return;
        if (on == self.attached) return;
        if (on) {
            // insertAbove = TRUE with no reference: on top of its siblings.
            if (!ok(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, d.root, slot_visual_add_visual)(d.root, vis, 1, null))) return;
        } else {
            _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, d.root, slot_visual_remove_visual)(d.root, vis);
        }
        self.attached = on;
        self.commit();
    }

    fn commit(self: *Layer) void {
        const d = self.dev orelse return;
        _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, d.dcomp, slot_dcomp_commit)(d.dcomp);
    }

    /// Let go of everything built on the current tree.
    pub fn drop(self: *Layer) void {
        if (self.dev) |d| {
            if (self.attached) {
                if (self.visual) |vis| _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, d.root, slot_visual_remove_visual)(d.root, vis);
                _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, d.dcomp, slot_dcomp_commit)(d.dcomp);
            }
        }
        if (self.surface) |o| comRelease(o);
        if (self.effect) |o| comRelease(o);
        if (self.visual) |o| comRelease(o);
        if (self.dev) |d| releaseShared(d, RefOps.com);
        self.* = .{ .generation = self.generation, .opacity = self.opacity };
    }

    pub fn deinit(self: *Layer) void {
        self.drop();
        self.generation = 0;
    }
};

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
    }
    const ops: RefOps = .{ .add = add, .release = rel };
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

test "uploadBox places the pixels at the BeginDraw offset" {
    const b = uploadBox(16, 32, 100, 50);
    try std.testing.expectEqual(D3D11_BOX{ .left = 16, .top = 32, .front = 0, .right = 116, .bottom = 82, .back = 1 }, b);
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(D3D11_BOX));
    try std.testing.expectEqual(@as(u32, 0x8000 + 44), WM_APP_COMP_OVERLAY);
}
