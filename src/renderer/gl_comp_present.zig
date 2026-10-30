//! Terminal pane presentation through a DXGI flip-model swap chain hosted in
//! a composition visual (T2466, T2360 step 2), instead of WGL `SwapBuffers`
//! into the pane's GDI-redirected window.
//!
//! The renderer keeps drawing with OpenGL into its offscreen target, exactly
//! as before. Only the last hop changes: the target is blitted into a D3D11
//! texture that `WGL_NV_DX_interop2` shares with GL, copied into the back
//! buffer of a composition swap chain, and `Present`ed. The swap chain is the
//! content of a DirectComposition visual on the pane's own window, so DWM
//! composes the pane from a flip-model surface rather than from the window's
//! redirection bitmap.
//!
//! Hosting is DirectComposition rather than Windows.UI.Composition's
//! `CreateCompositionSurfaceForSwapChain` for THIS step, and that is a
//! mechanism call recorded in T2466: everything here lives on the renderer
//! thread, which runs a libxev loop and pumps no messages. A WinRT Compositor
//! commits implicitly from its DispatcherQueue's pump, so on this thread its
//! visual tree would never be committed; a DComp device commits explicitly from
//! any thread. The swap chain - the part with real weight - is the same object
//! either way, so step 5 wraps it with `CreateCompositionSurfaceForSwapChain`
//! when the pane visual joins the window's composition tree.
//!
//! Why an intermediate texture instead of registering the back buffer with GL:
//! a flip-model swap chain rotates its buffers on every Present, and an interop
//! registration names one D3D resource for its lifetime. Copying into buffer 0
//! after the GL write is correct on every driver, at the cost of one GPU copy.
//!
//! Opt-in while it is proven (`GHOZTTY_COMP_PRESENT=1`); any failure falls back
//! to the WGL path for the life of the pane and says why in the log. Every slot
//! below was checked against the 10.0.22621.0 SDK headers (d3d11.h, dxgi.h,
//! dxgi1_2.h, dcomp.h) and the WGL_NV_DX_interop2 spec.
const std = @import("std");
const builtin = @import("builtin");
const gl = @import("opengl");
const gl_loader = @import("gl_loader.zig");
const gl_robust = @import("gl_robust.zig");
const comp_overlay = @import("comp_overlay.zig");

const log = std.log.scoped(.comp_present);

const GUID = std.os.windows.GUID;
const HRESULT = std.os.windows.HRESULT;
const HWND = std.os.windows.HWND;
const HANDLE = ?*anyopaque;
const Obj = *anyopaque;

pub const Error = error{
    Disabled,
    Unavailable,
    NoInterop,
    ComFailed,
    InteropFailed,
    GLFailed,
};

/// The environment knob that opts a pane into this path. Read once per pane.
pub const env_knob = "GHOZTTY_COMP_PRESENT";

/// Whether the knob's value asks for the composition path. "1"/"true"/"on".
pub fn knobOn(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return false, " \t\r\n");
    return std.mem.eql(u8, v, "1") or
        std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "on");
}

pub fn enabled() bool {
    if (comptime builtin.os.tag != .windows) return false;
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, env_knob) catch return false;
    defer std.heap.page_allocator.free(raw);
    return knobOn(raw);
}

fn debugFailAfter() ?u64 {
    if (comptime builtin.mode != .Debug) return null;
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_COMP_PRESENT_FAIL_AFTER") catch return null;
    defer std.heap.page_allocator.free(raw);
    return std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null;
}

/// The blit rectangle that copies a GL target (origin bottom-left) into a
/// D3D texture (origin top-left) the right way up: the destination's Y runs
/// from `h` down to 0.
pub const Blit = struct { src: [4]i32, dst: [4]i32 };
pub fn flipBlit(w: u32, h: u32) Blit {
    const wi: i32 = @intCast(w);
    const hi: i32 = @intCast(h);
    return .{ .src = .{ 0, 0, wi, hi }, .dst = .{ 0, hi, wi, 0 } };
}

fn guid(comptime s: []const u8) GUID {
    return GUID.parse("{" ++ s ++ "}");
}

const IID_IDXGIDevice = guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
const IID_IDXGIFactory2 = guid("50c83a1c-e072-4c48-87b0-3630fa36a6d0");
const IID_ID3D11Texture2D = guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
const IID_IDCompositionDevice = guid("c37ea93a-e7aa-450d-b16f-9746cb0407f3");

const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
const DXGI_SCALING_STRETCH: u32 = 0;
const DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL: u32 = 3;
const DXGI_ALPHA_MODE_IGNORE: u32 = 3;
const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D_DRIVER_TYPE_WARP: u32 = 5;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_SDK_VERSION: u32 = 7;
const D3D11_USAGE_DEFAULT: u32 = 0;
const D3D11_BIND_SHADER_RESOURCE: u32 = 0x8;
const D3D11_BIND_RENDER_TARGET: u32 = 0x20;
const WGL_ACCESS_WRITE_DISCARD_NV: u32 = 0x0002;
const GL_RENDERBUFFER: u32 = 0x8D41;

const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    width: u32,
    height: u32,
    format: u32,
    stereo: i32,
    sample_count: u32,
    sample_quality: u32,
    buffer_usage: u32,
    buffer_count: u32,
    scaling: u32,
    swap_effect: u32,
    alpha_mode: u32,
    flags: u32,
};

const D3D11_TEXTURE2D_DESC = extern struct {
    width: u32,
    height: u32,
    mip_levels: u32,
    array_size: u32,
    format: u32,
    sample_count: u32,
    sample_quality: u32,
    usage: u32,
    bind_flags: u32,
    cpu_access_flags: u32,
    misc_flags: u32,
};

// Vtable slots (IUnknown 0-2 everywhere).
const slot_dxgi_device_get_adapter = 7; // IDXGIObject 3-6, IDXGIDevice::GetAdapter
const slot_dxgi_object_get_parent = 6;
const slot_factory2_create_for_composition = 24;
const slot_swapchain_present = 8;
const slot_swapchain_get_buffer = 9;
const slot_swapchain_resize_buffers = 13;
const slot_d3d11_device_create_texture2d = 5;
const slot_d3d11_context_copy_resource = 47;
const slot_dcomp_device_commit = 3;
const slot_dcomp_device_create_target = 6;
const slot_dcomp_device_create_visual = 7;
const slot_dcomp_target_set_root = 3;
const slot_dcomp_visual_set_content = 15;

fn slot(comptime F: type, obj: Obj, index: usize) F {
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(vtbl.*[index]);
}

threadlocal var last_hr: HRESULT = 0;
/// The step in progress on this thread, so a failure names it in the log.
threadlocal var stage: []const u8 = "";

fn check(hr: HRESULT) Error!void {
    if (hr < 0) {
        last_hr = hr;
        return error.ComFailed;
    }
}

fn query(obj: Obj, iid: *const GUID) Error!Obj {
    const F = *const fn (Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT;
    var out: ?Obj = null;
    try check(slot(F, obj, 0)(obj, iid, &out));
    return out orelse error.ComFailed;
}

fn release(obj: Obj) void {
    const F = *const fn (Obj) callconv(.winapi) u32;
    _ = slot(F, obj, 2)(obj);
}

extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;

const D3D11CreateDeviceFn = *const fn (?Obj, u32, ?*anyopaque, u32, ?*const u32, u32, u32, *?Obj, ?*u32, *?Obj) callconv(.winapi) HRESULT;
const DCompCreateDeviceFn = *const fn (?Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT;

/// The WGL_NV_DX_interop2 entry points, resolved from the current context.
const Interop = struct {
    open: *const fn (?*anyopaque) callconv(.winapi) HANDLE,
    close: *const fn (HANDLE) callconv(.winapi) i32,
    register: *const fn (HANDLE, ?*anyopaque, u32, u32, u32) callconv(.winapi) HANDLE,
    unregister: *const fn (HANDLE, HANDLE) callconv(.winapi) i32,
    lock: *const fn (HANDLE, i32, [*]HANDLE) callconv(.winapi) i32,
    unlock: *const fn (HANDLE, i32, [*]HANDLE) callconv(.winapi) i32,

    const GetExtensionsStringFn = *const fn (?*anyopaque) callconv(.winapi) ?[*:0]const u8;

    fn resolve() Error!Interop {
        const api = gl_loader.active();
        const ext_proc = api.proc("wglGetExtensionsStringARB") orelse return error.NoInterop;
        const get_ext: GetExtensionsStringFn = @ptrCast(ext_proc);
        const exts = get_ext(api.getCurrentDC()) orelse return error.NoInterop;
        if (!gl_robust.hasExtension(std.mem.sliceTo(exts, 0), "WGL_NV_DX_interop2"))
            return error.NoInterop;
        return .{
            .open = @ptrCast(api.proc("wglDXOpenDeviceNV") orelse return error.NoInterop),
            .close = @ptrCast(api.proc("wglDXCloseDeviceNV") orelse return error.NoInterop),
            .register = @ptrCast(api.proc("wglDXRegisterObjectNV") orelse return error.NoInterop),
            .unregister = @ptrCast(api.proc("wglDXUnregisterObjectNV") orelse return error.NoInterop),
            .lock = @ptrCast(api.proc("wglDXLockObjectsNV") orelse return error.NoInterop),
            .unlock = @ptrCast(api.proc("wglDXUnlockObjectsNV") orelse return error.NoInterop),
        };
    }
};

/// One pane's presenter. Created, used and destroyed on the renderer thread,
/// with the pane's GL context current.
pub const Presenter = struct {
    device: Obj, // ID3D11Device
    context: Obj, // ID3D11DeviceContext
    swap: Obj, // IDXGISwapChain1
    dcomp: Obj, // IDCompositionDevice
    target: Obj, // IDCompositionTarget
    visual: Obj, // IDCompositionVisual
    interop: Interop,
    interop_device: HANDLE,

    // Per-size state: the shared texture, its interop registration and the
    // GL framebuffer that writes into it.
    texture: ?Obj = null,
    registered: HANDLE = null,
    rbo: ?gl.Renderbuffer = null,
    fbo: ?gl.Framebuffer = null,
    width: u32 = 0,
    height: u32 = 0,

    locked: bool = false,
    warp: bool = false,

    /// Frames presented, for the debug-only failure seam below.
    presents: u64 = 0,
    /// `GHOZTTY_COMP_PRESENT_FAIL_AFTER=<n>`: debug builds fail the n+1th
    /// present, so the fallback to SwapBuffers can be watched happening
    /// (test\win32\comp-present.ps1). Never read in a release build.
    fail_after: ?u64 = null,

    /// Build the whole chain for `hwnd`. Needs the pane's GL context current.
    pub fn init(hwnd: HWND, width: u32, height: u32) Error!Presenter {
        if (comptime builtin.os.tag != .windows) return error.Unavailable;

        stage = "wgl-interop";
        const interop = try Interop.resolve();

        stage = "load-libraries";
        const d3d11 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse
            return error.Unavailable;
        const dcomp_lib = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll")) orelse
            return error.Unavailable;
        const d3d11_create: D3D11CreateDeviceFn = @ptrCast(GetProcAddress(d3d11, "D3D11CreateDevice") orelse
            return error.Unavailable);
        const dcomp_create: DCompCreateDeviceFn = @ptrCast(GetProcAddress(dcomp_lib, "DCompositionCreateDevice") orelse
            return error.Unavailable);

        stage = "d3d11-device";
        var device: ?Obj = null;
        var context: ?Obj = null;
        var warp = false;
        if (d3d11_create(null, D3D_DRIVER_TYPE_HARDWARE, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context) < 0) {
            warp = true;
            try check(d3d11_create(null, D3D_DRIVER_TYPE_WARP, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context));
        }
        const dev = device orelse return error.ComFailed;
        errdefer release(dev);
        const ctx = context orelse return error.ComFailed;
        errdefer release(ctx);

        stage = "dxgi-factory";
        const dxgi_device = try query(dev, &IID_IDXGIDevice);
        defer release(dxgi_device);
        var adapter: ?Obj = null;
        try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, dxgi_device, slot_dxgi_device_get_adapter)(dxgi_device, &adapter));
        const adp = adapter orelse return error.ComFailed;
        defer release(adp);
        var factory: ?Obj = null;
        try check(slot(*const fn (Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT, adp, slot_dxgi_object_get_parent)(adp, &IID_IDXGIFactory2, &factory));
        const fac = factory orelse return error.ComFailed;
        defer release(fac);

        stage = "swap-chain";
        const desc: DXGI_SWAP_CHAIN_DESC1 = .{
            .width = @max(width, 1),
            .height = @max(height, 1),
            .format = DXGI_FORMAT_B8G8R8A8_UNORM,
            .stereo = 0,
            .sample_count = 1,
            .sample_quality = 0,
            .buffer_usage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .buffer_count = 2,
            .scaling = DXGI_SCALING_STRETCH,
            .swap_effect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            .alpha_mode = DXGI_ALPHA_MODE_IGNORE,
            .flags = 0,
        };
        var swap: ?Obj = null;
        try check(slot(*const fn (Obj, Obj, *const DXGI_SWAP_CHAIN_DESC1, ?Obj, *?Obj) callconv(.winapi) HRESULT, fac, slot_factory2_create_for_composition)(fac, dev, &desc, null, &swap));
        const sc = swap orelse return error.ComFailed;
        errdefer release(sc);

        stage = "dcomp-device";
        var dcomp: ?Obj = null;
        try check(dcomp_create(dxgi_device, &IID_IDCompositionDevice, &dcomp));
        const dc = dcomp orelse return error.ComFailed;
        errdefer release(dc);

        stage = "dcomp-target";
        var target: ?Obj = null;
        // topmost: the visual draws over the window's own (GDI) content.
        try check(slot(*const fn (Obj, HWND, i32, *?Obj) callconv(.winapi) HRESULT, dc, slot_dcomp_device_create_target)(dc, hwnd, 1, &target));
        const tg = target orelse return error.ComFailed;
        errdefer release(tg);

        stage = "dcomp-visual";
        var visual: ?Obj = null;
        try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, dc, slot_dcomp_device_create_visual)(dc, &visual));
        const vis = visual orelse return error.ComFailed;
        errdefer release(vis);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, sc));
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, tg, slot_dcomp_target_set_root)(tg, vis));
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, dc, slot_dcomp_device_commit)(dc));

        stage = "wgl-open-device";
        const interop_device = interop.open(dev) orelse return error.InteropFailed;

        var self: Presenter = .{
            .device = dev,
            .context = ctx,
            .swap = sc,
            .dcomp = dc,
            .target = tg,
            .visual = vis,
            .interop = interop,
            .interop_device = interop_device,
            .width = desc.width,
            .height = desc.height,
            .warp = warp,
            .fail_after = debugFailAfter(),
        };
        errdefer self.deinit();

        stage = "shared-texture";
        try self.createShared(desc.width, desc.height);
        stage = "";
        return self;
    }

    /// The failing step and HRESULT of the last `init`/frame error on this
    /// thread, for the fallback log line.
    pub fn lastFailure() struct { stage: []const u8, hr: HRESULT } {
        return .{ .stage = stage, .hr = last_hr };
    }

    fn createShared(self: *Presenter, w: u32, h: u32) Error!void {
        const desc: D3D11_TEXTURE2D_DESC = .{
            .width = w,
            .height = h,
            .mip_levels = 1,
            .array_size = 1,
            .format = DXGI_FORMAT_B8G8R8A8_UNORM,
            .sample_count = 1,
            .sample_quality = 0,
            .usage = D3D11_USAGE_DEFAULT,
            .bind_flags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE,
            .cpu_access_flags = 0,
            .misc_flags = 0,
        };
        var tex: ?Obj = null;
        try check(slot(*const fn (Obj, *const D3D11_TEXTURE2D_DESC, ?*const anyopaque, *?Obj) callconv(.winapi) HRESULT, self.device, slot_d3d11_device_create_texture2d)(self.device, &desc, null, &tex));
        const t = tex orelse return error.ComFailed;
        errdefer release(t);

        const rbo = gl.Renderbuffer.create() catch return error.GLFailed;
        errdefer rbo.destroy();
        const reg = self.interop.register(self.interop_device, t, rbo.id, GL_RENDERBUFFER, WGL_ACCESS_WRITE_DISCARD_NV) orelse
            return error.InteropFailed;
        errdefer _ = self.interop.unregister(self.interop_device, reg);

        const fbo = gl.Framebuffer.create() catch return error.GLFailed;
        errdefer fbo.destroy();
        {
            const fb = fbo.bind(.framebuffer) catch return error.GLFailed;
            defer fb.unbind();
            fb.renderbuffer(.color0, rbo) catch return error.GLFailed;
        }

        self.texture = t;
        self.registered = reg;
        self.rbo = rbo;
        self.fbo = fbo;
        self.width = w;
        self.height = h;
    }

    fn destroyShared(self: *Presenter) void {
        if (self.locked) {
            var objs = [_]HANDLE{self.registered};
            _ = self.interop.unlock(self.interop_device, 1, &objs);
            self.locked = false;
        }
        if (self.fbo) |f| f.destroy();
        if (self.registered != null) _ = self.interop.unregister(self.interop_device, self.registered);
        if (self.rbo) |r| r.destroy();
        if (self.texture) |t| release(t);
        self.fbo = null;
        self.registered = null;
        self.rbo = null;
        self.texture = null;
    }

    /// Make the swap chain and the shared texture `w` x `h`, lock the shared
    /// texture for GL and return the GL framebuffer to blit the frame into.
    pub fn begin(self: *Presenter, w: u32, h: u32) Error!gl.Framebuffer {
        if (w == 0 or h == 0) return error.GLFailed;
        if (w != self.width or h != self.height or self.texture == null) {
            self.destroyShared();
            stage = "resize-buffers";
            try check(slot(*const fn (Obj, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT, self.swap, slot_swapchain_resize_buffers)(self.swap, 0, w, h, 0, 0));
            stage = "shared-texture";
            try self.createShared(w, h);
        }
        if (!self.locked) {
            stage = "lock";
            var objs = [_]HANDLE{self.registered};
            if (self.interop.lock(self.interop_device, 1, &objs) == 0) return error.InteropFailed;
            self.locked = true;
        }
        return self.fbo.?;
    }

    /// Hand the frame GL wrote to D3D and present it. `present` false drops
    /// the frame (the layout outran it, T2418) but still releases the lock.
    pub fn end(self: *Presenter, present: bool) Error!void {
        if (!self.locked) return;
        stage = "unlock";
        var objs = [_]HANDLE{self.registered};
        self.locked = false;
        if (self.interop.unlock(self.interop_device, 1, &objs) == 0) return error.InteropFailed;
        if (!present) return;

        if (self.fail_after) |n| if (self.presents >= n) {
            stage = "simulated (debug test hook)";
            last_hr = 0;
            return error.ComFailed;
        };
        self.presents +%= 1;

        stage = "back-buffer";
        var back: ?Obj = null;
        try check(slot(*const fn (Obj, u32, *const GUID, *?Obj) callconv(.winapi) HRESULT, self.swap, slot_swapchain_get_buffer)(self.swap, 0, &IID_ID3D11Texture2D, &back));
        const bb = back orelse return error.ComFailed;
        defer release(bb);
        slot(*const fn (Obj, Obj, Obj) callconv(.winapi) void, self.context, slot_d3d11_context_copy_resource)(self.context, bb, self.texture.?);

        stage = "present";
        // Sync interval 1: one frame per vblank, the same pacing SwapBuffers had.
        try check(slot(*const fn (Obj, u32, u32) callconv(.winapi) HRESULT, self.swap, slot_swapchain_present)(self.swap, 1, 0));
    }

    /// The tree the pane's window thread hangs its overlay visuals under
    /// (T2467, `comp_overlay.zig`). Null when the D3D11 context cannot be made
    /// multithread-protected: the window thread uploads overlay pixels through
    /// it while this thread copies frames, so an unprotected context is not
    /// shared and the overlays stay popups.
    pub fn overlayTree(self: *Presenter) ?comp_overlay.Shared {
        const mt = query(self.device, &comp_overlay.IID_ID3D10Multithread) catch {
            log.warn("ID3D10Multithread unavailable; overlays stay popups", .{});
            return null;
        };
        defer release(mt);
        _ = slot(*const fn (Obj, i32) callconv(.winapi) i32, mt, comp_overlay.slot_multithread_set_protected)(mt, 1);
        return .{ .dcomp = self.dcomp, .context = self.context, .root = self.visual };
    }

    /// Tear everything down. Needs the GL context that `init` ran under to be
    /// current (the GL names and the interop device belong to it).
    pub fn deinit(self: *Presenter) void {
        self.destroyShared();
        if (self.interop_device != null) _ = self.interop.close(self.interop_device);
        self.interop_device = null;
        self.releaseCom();
    }

    /// The GL context is gone (device lost): its names and the interop handles
    /// died with it, so they are dropped, never freed. Only the D3D/DComp side
    /// is released, which also removes the visual from the window.
    pub fn abandon(self: *Presenter) void {
        if (self.texture) |t| release(t);
        self.texture = null;
        self.fbo = null;
        self.rbo = null;
        self.registered = null;
        self.interop_device = null;
        self.locked = false;
        self.releaseCom();
    }

    fn releaseCom(self: *Presenter) void {
        // Detach the visual before the target goes, so the window falls back
        // to its own content in the same commit.
        _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, null);
        _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp);
        release(self.visual);
        release(self.target);
        release(self.dcomp);
        release(self.swap);
        release(self.context);
        release(self.device);
    }
};

test "knobOn accepts 1/true/on and nothing else" {
    try std.testing.expect(knobOn("1"));
    try std.testing.expect(knobOn(" true\r\n"));
    try std.testing.expect(knobOn("ON"));
    try std.testing.expect(!knobOn(null));
    try std.testing.expect(!knobOn(""));
    try std.testing.expect(!knobOn("0"));
    try std.testing.expect(!knobOn("yes please"));
}

test "flipBlit turns the GL target right way up in a D3D texture" {
    const b = flipBlit(640, 480);
    try std.testing.expectEqual([4]i32{ 0, 0, 640, 480 }, b.src);
    // Source row 0 (GL bottom) lands at destination y=480 side, i.e. the
    // D3D bottom; the destination rectangle runs top-down from h to 0.
    try std.testing.expectEqual([4]i32{ 0, 480, 640, 0 }, b.dst);
}

test "swap chain desc matches the SDK layout" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(DXGI_SWAP_CHAIN_DESC1));
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(D3D11_TEXTURE2D_DESC));
}
