//! The window CHROME's composition host (T2508, T2360 step 4a): a
//! DirectComposition target on the top-level window, with a Direct2D device
//! context over the same D3D11 device, ready for the chrome painters to move
//! onto.
//!
//! A DComp target's visual tree composes ABOVE the window's own redirected
//! GDI pixels - `topmost=FALSE` only puts it BELOW the window's child windows
//! (the panes) - so any visual hung here hides every GDI chrome painter under
//! it. Two visuals hang from a container root. The desk (T2509): `PaneDesk`'s
//! composed buffer, uploaded rectangle by rectangle as it changes, clipped to
//! the content area below the caption. The window carries it only while no
//! GDI painter draws over the desk (an opaque window, no hero tab, no
//! rearrange header); otherwise the desk stays a GDI blit. Above it, while
//! the desk is up, the caption band (T2543): the caption and tab bar painted
//! by their own GDI painters into a persistent `Mirror` and uploaded by the
//! paint's dirty rect. A window paint batches both into one commit
//! (`beginBatch`/`flush`), so the band and the desk change in the same frame.
//! T2544/T2545/T2541 move the remaining painters over.
//!
//! Why DirectComposition and not Windows.UI.Composition, same call as the pane
//! presenter (`renderer/gl_comp_present.zig`): a DComp device commits
//! explicitly from the thread that owns it, and the shape of the chrome's
//! later painters (paint, upload, commit) wants exactly that.
//!
//! Opt-in while it is proven (`GHOZTTY_COMP_CHROME=1`, read per window). Any
//! failure leaves the window on its GDI chrome, which is the same picture,
//! and says which step failed in the log. Device loss (a driver reset, a GPU
//! removed, a remote-session switch) is noticed on the next paint and the
//! whole chain is rebuilt from scratch.
//!
//! Two debug-only seams (Debug/ReleaseSafe, never a release build), both for
//! test\win32\comp-chrome.ps1 and scripts\comp-chrome-onscreen.ps1:
//!   - `GHOZTTY_COMP_CHROME_FORCE_LOSS=1`: the first device check reports the
//!     device lost, so the rebuild can be watched happening.
//!   - `GHOZTTY_COMP_CHROME_TEST_FILL=1`: hang one magenta visual the size of
//!     the client area on the target, drawn through the Direct2D context. On
//!     screen it must cover the GDI chrome and sit under the panes - the
//!     ordering every later step relies on.
//!   - `GHOZTTY_COMP_CHROME_CAPTION_FREEZE=1` (scripts\comp-desk-onscreen.ps1
//!     -NegativeControl): the caption visual takes its whole uploads and drops
//!     every dirty-rect one, so a frozen band is something the oracle sees.
//!
//! Every slot below was checked against the 10.0.26100.0 SDK headers
//! (d3d11.h, dxgi.h, dcomp.h, d2d1.h, d2d1_1.h).
const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");

const log = std.log.scoped(.comp_chrome);

const GUID = std.os.windows.GUID;
const HRESULT = std.os.windows.HRESULT;
const HWND = std.os.windows.HWND;
const Obj = *anyopaque;

pub const Error = error{ Unavailable, ComFailed };

/// The environment knob that opts a window's chrome into this host.
pub const env_knob = "GHOZTTY_COMP_CHROME";

/// Whether the knob's value asks for the host. "1"/"true"/"on".
pub fn knobOn(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return false, " \t\r\n");
    return std.mem.eql(u8, v, "1") or
        std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "on");
}

fn envOn(comptime name: []const u8) bool {
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(raw);
    return knobOn(raw);
}

pub fn enabled() bool {
    if (comptime builtin.os.tag != .windows) return false;
    return envOn(env_knob);
}

fn seamBuild() bool {
    return builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
}

fn guid(comptime s: []const u8) GUID {
    return GUID.parse("{" ++ s ++ "}");
}

const IID_IDXGIDevice = guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
const IID_IDXGISurface = guid("cafcb56c-6ac3-4889-bf47-9e23bbd260ec");
const IID_IDCompositionDevice = guid("c37ea93a-e7aa-450d-b16f-9746cb0407f3");
const IID_ID2D1Factory1 = guid("bb12d362-daee-4b9a-aa1d-14ba401cfa1f");

const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D_DRIVER_TYPE_WARP: u32 = 5;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_SDK_VERSION: u32 = 7;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const DXGI_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
const D2D1_FACTORY_TYPE_SINGLE_THREADED: u32 = 0;
const D2D1_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
const D2D1_BITMAP_OPTIONS_TARGET: u32 = 0x1;
const D2D1_BITMAP_OPTIONS_CANNOT_DRAW: u32 = 0x2;
const D2D1_ANTIALIAS_MODE_ALIASED: u32 = 1;

const D2D1_COLOR_F = extern struct { r: f32, g: f32, b: f32, a: f32 };
const D2D1_RECT_F = extern struct { left: f32, top: f32, right: f32, bottom: f32 };
const D2D1_BITMAP_PROPERTIES1 = extern struct {
    format: u32,
    alpha_mode: u32,
    dpi_x: f32,
    dpi_y: f32,
    options: u32,
    color_context: ?Obj,
};

// Vtable slots (IUnknown 0-2 everywhere; ID2D1Resource::GetFactory is 3).
const slot_d3d11_device_get_removed_reason = 39;
const slot_d2d_factory1_create_device = 17;
const slot_d2d_device_create_context = 4;
const slot_d2d_rt_push_clip = 45;
const slot_d2d_rt_pop_clip = 46;
const slot_d2d_rt_clear = 47;
const slot_d2d_rt_begin_draw = 48;
const slot_d2d_rt_end_draw = 49;
const slot_d2d_dc_bitmap_from_dxgi = 62;
const slot_d2d_dc_set_target = 74;
const slot_dcomp_device_commit = 3;
const slot_dcomp_device_create_target = 6;
const slot_dcomp_device_create_visual = 7;
const slot_dcomp_device_create_surface = 8;
const slot_dcomp_device_create_surface_from_handle = 10;
const slot_dcomp_device_check_state = 26;
const slot_dcomp_surface_begin_draw = 3;
const slot_dcomp_surface_end_draw = 4;
const slot_dcomp_target_set_root = 3;
// IDCompositionVisual: each overloaded setter's object form comes first,
// its value form second (SetTransform(transform) 7 / (matrix) 8, as
// `renderer/comp_overlay.zig` uses).
const slot_dcomp_visual_set_offset_x = 4;
const slot_dcomp_visual_set_offset_y = 6;
const slot_dcomp_visual_set_clip_rect = 14;
const slot_dcomp_visual_set_content = 15;
const slot_dcomp_visual_add_visual = 16;
const slot_dcomp_visual_remove_visual = 17;
// ID3D11DeviceContext (ID3D11DeviceChild 3-6, CopyResource 47).
const slot_d3d11_context_update_subresource = 48;

const IID_ID3D11Texture2D = guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
/// The desk is opaque: its buffer's alpha byte is coverage for a
/// translucent window's blend (`PaneDesk`), not transparency.
const DXGI_ALPHA_MODE_IGNORE: u32 = 3;

const D3D11_BOX = extern struct { left: u32, top: u32, front: u32, right: u32, bottom: u32, back: u32 };

/// A rectangle of the desk's buffer, in its own pixels.
pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

/// The part of a `w` x `h` band (client origin) that a paint clipped to
/// `clip` reached, or null when it reached none of it.
pub fn bandDirty(clip: Rect, w: i32, h: i32) ?Rect {
    const r: Rect = .{
        .left = std.math.clamp(clip.left, 0, w),
        .top = std.math.clamp(clip.top, 0, h),
        .right = std.math.clamp(clip.right, 0, w),
        .bottom = std.math.clamp(clip.bottom, 0, h),
    };
    if (r.right <= r.left or r.bottom <= r.top) return null;
    return r;
}

/// The caption band's persistent mirror (T2543): a top-down 32bpp DIB the
/// width of the client area and the chrome's height, selected into a memory
/// DC whose origin is the client's. The caption and tab bar painters draw
/// into it exactly as they would into the window, and the band goes to the
/// compositor (or, off it, to the window) from these pixels.
pub const Mirror = struct {
    dc: ?w32.HDC = null,
    bmp: ?w32.HANDLE = null,
    old: ?*anyopaque = null,
    px: []u32 = &.{},
    w: i32 = 0,
    h: i32 = 0,

    /// The mirror's DC at `w` x `h`, rebuilt (and so fresh) on a new size.
    /// Null when GDI refused, and the caller paints the window instead.
    pub fn ensure(self: *Mirror, ref: w32.HDC, w: i32, h: i32) ?w32.HDC {
        if (w <= 0 or h <= 0) return null;
        if (self.dc != null and w == self.w and h == self.h) return self.dc;
        self.deinit();
        const dc = w32.CreateCompatibleDC(ref) orelse return null;
        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{ .bmiHeader = .{
            .biWidth = w,
            .biHeight = -h, // top-down
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = w32.BI_RGB,
        } };
        const bmp = w32.CreateDIBSection(dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = w32.DeleteDC(dc);
            return null;
        };
        const p = bits orelse {
            _ = w32.DeleteObject(bmp);
            _ = w32.DeleteDC(dc);
            return null;
        };
        self.* = .{
            .dc = dc,
            .bmp = bmp,
            .old = w32.SelectObject(dc, bmp),
            .px = @as([*]u32, @ptrCast(@alignCast(p)))[0..@intCast(w * h)],
            .w = w,
            .h = h,
        };
        return dc;
    }

    pub fn deinit(self: *Mirror) void {
        if (self.dc) |dc| {
            if (self.old) |o| _ = w32.SelectObject(dc, o);
            if (self.bmp) |b| _ = w32.DeleteObject(b);
            _ = w32.DeleteDC(dc);
        }
        self.* = .{};
    }
};

fn slot(comptime F: type, obj: Obj, index: usize) F {
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(vtbl.*[index]);
}

/// The step in progress and the HRESULT it failed with, for the log line.
var stage: []const u8 = "";
var last_hr: HRESULT = 0;

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

/// An HRESULT the way the SDK prints it, for the log.
pub fn hex(hr: HRESULT) u32 {
    return @bitCast(hr);
}

extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;

const D3D11CreateDeviceFn = *const fn (?Obj, u32, ?*anyopaque, u32, ?*const u32, u32, u32, *?Obj, ?*u32, *?Obj) callconv(.winapi) HRESULT;
const DCompCreateDeviceFn = *const fn (?Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT;
const D2D1CreateFactoryFn = *const fn (u32, *const GUID, ?*const anyopaque, *?Obj) callconv(.winapi) HRESULT;

const Entry = struct {
    d3d11_create: D3D11CreateDeviceFn,
    dcomp_create: DCompCreateDeviceFn,
    d2d_create: D2D1CreateFactoryFn,

    fn load() Error!Entry {
        const d3d11 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse return error.Unavailable;
        const dcomp = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll")) orelse return error.Unavailable;
        const d2d1 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d2d1.dll")) orelse return error.Unavailable;
        return .{
            .d3d11_create = @ptrCast(GetProcAddress(d3d11, "D3D11CreateDevice") orelse return error.Unavailable),
            .dcomp_create = @ptrCast(GetProcAddress(dcomp, "DCompositionCreateDevice") orelse return error.Unavailable),
            .d2d_create = @ptrCast(GetProcAddress(d2d1, "D2D1CreateFactory") orelse return error.Unavailable),
        };
    }
};

/// Why `lostReason` said the device is gone.
pub const Loss = enum {
    d3d_removed,
    dcomp_invalid,
    simulated,

    pub fn label(self: Loss) []const u8 {
        return switch (self) {
            .d3d_removed => "d3d11 device removed",
            .dcomp_invalid => "dcomp device invalid",
            .simulated => "simulated (debug test hook)",
        };
    }
};

/// One top-level window's chrome host. Created, used and destroyed on the
/// window's own thread.
pub const Host = struct {
    hwnd: HWND,
    device: Obj, // ID3D11Device
    context: Obj, // ID3D11DeviceContext
    d2d_factory: Obj, // ID2D1Factory1
    d2d_device: Obj, // ID2D1Device
    d2d: Obj, // ID2D1DeviceContext
    dcomp: Obj, // IDCompositionDevice
    target: Obj, // IDCompositionTarget, topmost=FALSE
    warp: bool,
    /// HRESULTs of the two steps the oracle names.
    target_hr: HRESULT = 0,
    d2d_hr: HRESULT = 0,

    /// The debug test fill (`GHOZTTY_COMP_CHROME_TEST_FILL`), or null.
    fill_visual: ?Obj = null,
    fill_surface: ?Obj = null,

    /// The desk (T2509): `PaneDesk`'s composed buffer as the bottom visual,
    /// placed at the content area and clipped to below the caption. Null
    /// while the desk is on GDI.
    desk_visual: ?Obj = null,
    desk_surface: ?Obj = null,
    desk_w: i32 = 0,
    desk_h: i32 = 0,
    desk_x: i32 = 0,
    desk_y: i32 = 0,
    desk_clip: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    /// Uploads since the window last read them: whole buffers, rectangles,
    /// and the pixels the rectangles covered.
    desk_full: u32 = 0,
    desk_partial: u32 = 0,
    desk_partial_px: u64 = 0,
    /// A step of the desk visual failed on this host; its desk stays GDI
    /// until the host is rebuilt.
    desk_failed: bool = false,

    /// The target's root while the desk is up: a container whose children
    /// are the desk and, above it, the caption band.
    root_visual: ?Obj = null,
    /// The caption band (T2543): the caption and tab bar's `Mirror`, at the
    /// client origin above the desk. Lives only while the desk does.
    cap_visual: ?Obj = null,
    cap_surface: ?Obj = null,
    cap_w: i32 = 0,
    cap_h: i32 = 0,
    /// Band uploads since the window last read them: whole, and rectangles.
    cap_full: u32 = 0,
    cap_partial: u32 = 0,
    /// A step of the caption visual failed on this host; the band stays GDI
    /// (over the desk visual's clip) until the host is rebuilt.
    cap_failed: bool = false,
    /// `GHOZTTY_COMP_CHROME_CAPTION_FREEZE`: drop dirty-rect band uploads.
    cap_freeze: bool = false,

    /// Set across a window paint: uploads leave the commit to `flush`, so
    /// the desk and the caption band reach the screen in the same frame.
    defer_commit: bool = false,
    commit_pending: bool = false,

    /// The pane layer (T2553): a second target, topmost=TRUE so it composes
    /// over the pane child windows, whose root holds one visual per pane
    /// presenting into a composition surface handle. Made on first adopt.
    pane_target: ?Obj = null,
    pane_root: ?Obj = null,
    /// Pane visuals adopted since the host was built, for the log.
    pane_adopts: u32 = 0,

    /// How many times this window's host was rebuilt after a device loss.
    rebuilds: u32 = 0,
    /// `GHOZTTY_COMP_CHROME_FORCE_LOSS`: report the device lost once.
    force_loss: bool = false,

    /// Build the host for `hwnd`. Never attaches a visual unless the debug
    /// test fill asks for one.
    pub fn init(hwnd: HWND) Error!Host {
        if (comptime builtin.os.tag != .windows) return error.Unavailable;
        last_hr = 0;

        stage = "load-libraries";
        const entry = try Entry.load();

        stage = "d3d11-device";
        var device: ?Obj = null;
        var context: ?Obj = null;
        var warp = false;
        if (entry.d3d11_create(null, D3D_DRIVER_TYPE_HARDWARE, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context) < 0) {
            warp = true;
            try check(entry.d3d11_create(null, D3D_DRIVER_TYPE_WARP, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context));
        }
        const dev = device orelse return error.ComFailed;
        errdefer release(dev);
        const ctx = context orelse return error.ComFailed;
        errdefer release(ctx);

        stage = "dxgi-device";
        const dxgi_device = try query(dev, &IID_IDXGIDevice);
        defer release(dxgi_device);

        stage = "d2d-factory";
        var factory: ?Obj = null;
        try check(entry.d2d_create(D2D1_FACTORY_TYPE_SINGLE_THREADED, &IID_ID2D1Factory1, null, &factory));
        const fac = factory orelse return error.ComFailed;
        errdefer release(fac);

        stage = "d2d-device";
        var d2d_device: ?Obj = null;
        const d2d_hr = slot(*const fn (Obj, Obj, *?Obj) callconv(.winapi) HRESULT, fac, slot_d2d_factory1_create_device)(fac, dxgi_device, &d2d_device);
        try check(d2d_hr);
        const d2d_dev = d2d_device orelse return error.ComFailed;
        errdefer release(d2d_dev);

        stage = "d2d-context";
        var d2d_ctx: ?Obj = null;
        try check(slot(*const fn (Obj, u32, *?Obj) callconv(.winapi) HRESULT, d2d_dev, slot_d2d_device_create_context)(d2d_dev, 0, &d2d_ctx));
        const d2d = d2d_ctx orelse return error.ComFailed;
        errdefer release(d2d);

        stage = "dcomp-device";
        var dcomp: ?Obj = null;
        try check(entry.dcomp_create(dxgi_device, &IID_IDCompositionDevice, &dcomp));
        const dc = dcomp orelse return error.ComFailed;
        errdefer release(dc);

        stage = "dcomp-target";
        var target: ?Obj = null;
        // topmost=FALSE: under the pane child windows, over this window's
        // own GDI pixels (the reason nothing is attached yet).
        const target_hr = slot(*const fn (Obj, HWND, i32, *?Obj) callconv(.winapi) HRESULT, dc, slot_dcomp_device_create_target)(dc, hwnd, 0, &target);
        try check(target_hr);
        const tg = target orelse return error.ComFailed;
        errdefer release(tg);

        var self: Host = .{
            .hwnd = hwnd,
            .device = dev,
            .context = ctx,
            .d2d_factory = fac,
            .d2d_device = d2d_dev,
            .d2d = d2d,
            .dcomp = dc,
            .target = tg,
            .warp = warp,
            .target_hr = target_hr,
            .d2d_hr = d2d_hr,
            .force_loss = seamBuild() and envOn("GHOZTTY_COMP_CHROME_FORCE_LOSS"),
            .cap_freeze = seamBuild() and envOn("GHOZTTY_COMP_CHROME_CAPTION_FREEZE"),
        };
        if (seamBuild() and envOn("GHOZTTY_COMP_CHROME_TEST_FILL")) {
            // The fill is a test seam: failing it costs the probe, not the host.
            self.attachTestFill() catch log.warn(
                "chrome composition test fill failed at {s}: hr=0x{x:0>8}",
                .{ stage, hex(last_hr) },
            );
        }
        stage = "";
        return self;
    }

    /// The failing step and HRESULT of the last `init` error, for the log.
    pub fn lastFailure() struct { stage: []const u8, hr: HRESULT } {
        return .{ .stage = stage, .hr = last_hr };
    }

    pub fn adapter(self: *const Host) []const u8 {
        return if (self.warp) "warp" else "hardware";
    }

    /// One magenta visual over the whole client area, drawn with Direct2D
    /// into a composition surface - so the probe also proves the D2D context
    /// can target what the compositor shows.
    fn attachTestFill(self: *Host) Error!void {
        var rc: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &rc) == 0) return error.ComFailed;
        const w: u32 = @intCast(@max(rc.right - rc.left, 1));
        const h: u32 = @intCast(@max(rc.bottom - rc.top, 1));

        stage = "fill-surface";
        var surface: ?Obj = null;
        try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, w, h, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &surface));
        const surf = surface orelse return error.ComFailed;
        errdefer release(surf);

        stage = "fill-draw";
        var dxgi_surface: ?Obj = null;
        var offset: w32.POINT = .{ .x = 0, .y = 0 };
        try check(slot(*const fn (Obj, ?*const w32.RECT, *const GUID, *?Obj, *w32.POINT) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_begin_draw)(surf, null, &IID_IDXGISurface, &dxgi_surface, &offset));
        const ds = dxgi_surface orelse return error.ComFailed;
        {
            defer release(ds);
            const props: D2D1_BITMAP_PROPERTIES1 = .{
                .format = DXGI_FORMAT_B8G8R8A8_UNORM,
                .alpha_mode = D2D1_ALPHA_MODE_PREMULTIPLIED,
                .dpi_x = 96,
                .dpi_y = 96,
                .options = D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                .color_context = null,
            };
            var bitmap: ?Obj = null;
            const bhr = slot(*const fn (Obj, Obj, *const D2D1_BITMAP_PROPERTIES1, *?Obj) callconv(.winapi) HRESULT, self.d2d, slot_d2d_dc_bitmap_from_dxgi)(self.d2d, ds, &props, &bitmap);
            if (bhr < 0 or bitmap == null) {
                _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_end_draw)(surf);
                try check(if (bhr < 0) bhr else -1);
            }
            const bmp = bitmap.?;
            defer release(bmp);
            slot(*const fn (Obj, ?Obj) callconv(.winapi) void, self.d2d, slot_d2d_dc_set_target)(self.d2d, bmp);
            slot(*const fn (Obj) callconv(.winapi) void, self.d2d, slot_d2d_rt_begin_draw)(self.d2d);
            // The surface may live in an atlas: draw only inside our update
            // rect, which starts at `offset`.
            const clip: D2D1_RECT_F = .{
                .left = @floatFromInt(offset.x),
                .top = @floatFromInt(offset.y),
                .right = @floatFromInt(offset.x + @as(i32, @intCast(w))),
                .bottom = @floatFromInt(offset.y + @as(i32, @intCast(h))),
            };
            slot(*const fn (Obj, *const D2D1_RECT_F, u32) callconv(.winapi) void, self.d2d, slot_d2d_rt_push_clip)(self.d2d, &clip, D2D1_ANTIALIAS_MODE_ALIASED);
            const magenta: D2D1_COLOR_F = .{ .r = 1, .g = 0, .b = 1, .a = 1 };
            slot(*const fn (Obj, *const D2D1_COLOR_F) callconv(.winapi) void, self.d2d, slot_d2d_rt_clear)(self.d2d, &magenta);
            slot(*const fn (Obj) callconv(.winapi) void, self.d2d, slot_d2d_rt_pop_clip)(self.d2d);
            const ehr = slot(*const fn (Obj, ?*u64, ?*u64) callconv(.winapi) HRESULT, self.d2d, slot_d2d_rt_end_draw)(self.d2d, null, null);
            slot(*const fn (Obj, ?Obj) callconv(.winapi) void, self.d2d, slot_d2d_dc_set_target)(self.d2d, null);
            const shr = slot(*const fn (Obj) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_end_draw)(surf);
            try check(ehr);
            try check(shr);
        }

        stage = "fill-visual";
        var visual: ?Obj = null;
        try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_visual)(self.dcomp, &visual));
        const vis = visual orelse return error.ComFailed;
        errdefer release(vis);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, surf));
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, vis));
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp));
        self.fill_surface = surf;
        self.fill_visual = vis;
        log.info("chrome composition test fill attached: {d}x{d} at +{d}+{d}", .{ w, h, offset.x, offset.y });
    }

    /// Whether the desk can be carried here. Not under the debug test fill,
    /// whose probe measures the fill over the desk's margins.
    pub fn deskAvailable(self: *const Host) bool {
        return self.fill_visual == null and !self.desk_failed;
    }

    pub fn deskLive(self: *const Host) bool {
        return self.desk_visual != null;
    }

    /// Put the desk visual at `(x, y)` in the client area, showing only
    /// `clip` (client pixels). Building it the first time; the next
    /// `deskUpload` commits.
    pub fn deskPlace(self: *Host, x: i32, y: i32, clip: Rect) Error!void {
        if (self.desk_visual == null) {
            stage = "desk-visual";
            const root = try self.ensureRoot();
            const vis = try self.newVisual();
            errdefer release(vis);
            // The desk is the bottom child: below the caption band if one is
            // already there, named explicitly rather than leaning on what a
            // null reference means.
            try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, root, slot_dcomp_visual_add_visual)(root, vis, 0, self.cap_visual));
            self.desk_visual = vis;
            // Placed below whatever it was before.
            self.desk_x = std.math.minInt(i32);
            log.info("chrome desk visual attached", .{});
        }
        const vis = self.desk_visual.?;
        if (x != self.desk_x or y != self.desk_y) {
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_x)(vis, @floatFromInt(x)));
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_y)(vis, @floatFromInt(y)));
            self.desk_x = x;
            self.desk_y = y;
            self.desk_clip = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        }
        if (!std.meta.eql(clip, self.desk_clip)) {
            // In the visual's own space, which starts at its offset.
            const r: D2D1_RECT_F = .{
                .left = @floatFromInt(clip.left - x),
                .top = @floatFromInt(clip.top - y),
                .right = @floatFromInt(clip.right - x),
                .bottom = @floatFromInt(clip.bottom - y),
            };
            try check(slot(*const fn (Obj, *const D2D1_RECT_F) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_clip_rect)(vis, &r));
            self.desk_clip = clip;
        }
    }

    /// The desk's composed buffer, `w` x `h` BGRA rows, into the visual:
    /// only `rects` of it when the surface already holds the rest (null:
    /// all of it), then one commit. A new size, or a surface lost with the
    /// device, takes the whole buffer whatever `rects` says.
    pub fn deskUpload(self: *Host, px: []const u32, w: i32, h: i32, rects: ?[]const Rect) Error!void {
        const vis = self.desk_visual orelse return error.Unavailable;
        if (w <= 0 or h <= 0 or px.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return error.ComFailed;
        var whole = rects == null;
        if (self.desk_surface == null or w != self.desk_w or h != self.desk_h) {
            stage = "desk-surface";
            if (self.desk_surface) |old| release(old);
            self.desk_surface = null;
            var surface: ?Obj = null;
            try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, @intCast(w), @intCast(h), DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_IGNORE, &surface));
            const surf = surface orelse return error.ComFailed;
            errdefer release(surf);
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, surf));
            self.desk_surface = surf;
            self.desk_w = w;
            self.desk_h = h;
            whole = true;
        }
        stage = "desk-upload";
        if (whole) {
            try self.deskDraw(px, w, .{ .left = 0, .top = 0, .right = w, .bottom = h });
            self.desk_full +|= 1;
        } else for (rects.?) |r| {
            const c: Rect = .{
                .left = std.math.clamp(r.left, 0, w),
                .top = std.math.clamp(r.top, 0, h),
                .right = std.math.clamp(r.right, 0, w),
                .bottom = std.math.clamp(r.bottom, 0, h),
            };
            if (c.right <= c.left or c.bottom <= c.top) continue;
            try self.deskDraw(px, w, c);
            self.desk_partial +|= 1;
            self.desk_partial_px +|= @intCast(@as(i64, c.right - c.left) * (c.bottom - c.top));
        }
        try self.commit();
    }

    fn deskDraw(self: *Host, px: []const u32, w: i32, r: Rect) Error!void {
        try self.drawRect(self.desk_surface.?, px, w, r);
    }

    /// Commit now, or at `flush` when a paint is batching its uploads.
    fn commit(self: *Host) Error!void {
        if (self.defer_commit) {
            self.commit_pending = true;
            return;
        }
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp));
    }

    /// Start batching a paint's uploads into one commit.
    pub fn beginBatch(self: *Host) void {
        self.defer_commit = true;
    }

    /// End the batch: everything the paint uploaded goes up in one commit.
    pub fn flush(self: *Host) Error!void {
        self.defer_commit = false;
        if (!self.commit_pending) return;
        self.commit_pending = false;
        try self.commit();
    }

    fn newVisual(self: *Host) Error!Obj {
        var visual: ?Obj = null;
        try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_visual)(self.dcomp, &visual));
        return visual orelse error.ComFailed;
    }

    /// The container the desk and the caption band hang from, made the
    /// target's root the first time.
    fn ensureRoot(self: *Host) Error!Obj {
        if (self.root_visual) |r| return r;
        const root = try self.newVisual();
        errdefer release(root);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, root));
        self.root_visual = root;
        return root;
    }

    pub fn capLive(self: *const Host) bool {
        return self.cap_visual != null;
    }

    /// The caption band's mirror, `w` x `h` client pixels from the client
    /// origin, into the visual above the desk: only `dirty` when the surface
    /// already holds the rest (null: all of it). A new size, or a band that
    /// was not up, takes the whole mirror. Only while the desk is up.
    pub fn capUpload(self: *Host, px: []const u32, w: i32, h: i32, dirty: ?Rect) Error!void {
        const desk = self.desk_visual orelse return error.Unavailable;
        if (w <= 0 or h <= 0 or px.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return error.ComFailed;
        var whole = dirty == null;
        if (self.cap_visual == null) {
            stage = "caption-visual";
            const vis = try self.newVisual();
            errdefer release(vis);
            try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, self.root_visual.?, slot_dcomp_visual_add_visual)(self.root_visual.?, vis, 1, desk));
            self.cap_visual = vis;
            log.info("chrome caption visual attached: {d}x{d}", .{ w, h });
            whole = true;
        }
        if (self.cap_surface == null or w != self.cap_w or h != self.cap_h) {
            stage = "caption-surface";
            if (self.cap_surface) |old| release(old);
            self.cap_surface = null;
            var surface: ?Obj = null;
            // Opaque, like the desk: GDI leaves the alpha byte at zero, and
            // on an opaque window every pixel of the band is painted.
            try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, @intCast(w), @intCast(h), DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_IGNORE, &surface));
            const surf = surface orelse return error.ComFailed;
            errdefer release(surf);
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.cap_visual.?, slot_dcomp_visual_set_content)(self.cap_visual.?, surf));
            self.cap_surface = surf;
            self.cap_w = w;
            self.cap_h = h;
            whole = true;
        }
        stage = "caption-upload";
        if (!whole and self.cap_freeze) return;
        const r = if (whole) Rect{ .left = 0, .top = 0, .right = w, .bottom = h } else bandDirty(dirty.?, w, h) orelse return;
        try self.drawRect(self.cap_surface.?, px, w, r);
        if (whole) self.cap_full +|= 1 else self.cap_partial +|= 1;
        try self.commit();
    }

    /// Take the caption band off the compositor; the desk stays.
    pub fn capHide(self: *Host) void {
        const vis = self.cap_visual orelse return;
        if (self.root_visual) |root| _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, root, slot_dcomp_visual_remove_visual)(root, vis);
        self.commit() catch {};
        self.releaseCap();
        log.info("chrome caption visual detached", .{});
    }

    fn releaseCap(self: *Host) void {
        if (self.cap_surface) |s| release(s);
        if (self.cap_visual) |v| release(v);
        self.cap_surface = null;
        self.cap_visual = null;
        self.cap_w = 0;
        self.cap_h = 0;
    }

    /// One rectangle of a `w`-wide buffer into `surf`. A surface may live in
    /// an atlas, so the rows land at the offset `BeginDraw` hands back.
    fn drawRect(self: *Host, surf: Obj, px: []const u32, w: i32, r: Rect) Error!void {
        const update: w32.RECT = .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
        var tex: ?Obj = null;
        var at: w32.POINT = .{ .x = 0, .y = 0 };
        try check(slot(*const fn (Obj, ?*const w32.RECT, *const GUID, *?Obj, *w32.POINT) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_begin_draw)(surf, &update, &IID_ID3D11Texture2D, &tex, &at));
        const t = tex orelse {
            _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_end_draw)(surf);
            return error.ComFailed;
        };
        const box: D3D11_BOX = .{
            .left = @intCast(@max(at.x, 0)),
            .top = @intCast(@max(at.y, 0)),
            .front = 0,
            .right = @intCast(@max(at.x, 0) + (r.right - r.left)),
            .bottom = @intCast(@max(at.y, 0) + (r.bottom - r.top)),
            .back = 1,
        };
        const first = @as(usize, @intCast(r.top)) * @as(usize, @intCast(w)) + @as(usize, @intCast(r.left));
        slot(*const fn (Obj, Obj, u32, *const D3D11_BOX, *const anyopaque, u32, u32) callconv(.winapi) void, self.context, slot_d3d11_context_update_subresource)(self.context, t, 0, &box, px[first..].ptr, @intCast(w * 4), 0);
        release(t);
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_end_draw)(surf));
    }

    /// Wrap a pane renderer's composition surface handle in a visual of the
    /// pane layer, on top of the panes adopted before it. The caller owns
    /// the returned visual's reference and hands it back to `paneDrop`.
    /// Nothing is on screen until `panePlace` commits.
    pub fn paneAdopt(self: *Host, handle: *anyopaque) Error!Obj {
        const root = try self.ensurePaneRoot();
        stage = "pane-surface";
        var surface: ?Obj = null;
        try check(slot(*const fn (Obj, *anyopaque, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface_from_handle)(self.dcomp, handle, &surface));
        const surf = surface orelse return error.ComFailed;
        defer release(surf);
        stage = "pane-visual";
        const vis = try self.newVisual();
        errdefer release(vis);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, surf));
        // Start clipped to nothing, so the visual cannot flash at the origin
        // before its first placement.
        const none: D2D1_RECT_F = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        try check(slot(*const fn (Obj, *const D2D1_RECT_F) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_clip_rect)(vis, &none));
        try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, root, slot_dcomp_visual_add_visual)(root, vis, 1, null));
        stage = "";
        self.pane_adopts +|= 1;
        log.info("pane visual adopted into the window tree (adopts={d})", .{self.pane_adopts});
        return vis;
    }

    /// Put a pane's visual at `(x, y)` in the client area, clipped to
    /// `w` x `h` of its own pixels (0 x 0 hides it), and commit.
    pub fn panePlace(self: *Host, vis: Obj, x: i32, y: i32, w: i32, h: i32) Error!void {
        stage = "pane-place";
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_x)(vis, @floatFromInt(x)));
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_y)(vis, @floatFromInt(y)));
        const clip: D2D1_RECT_F = .{ .left = 0, .top = 0, .right = @floatFromInt(@max(w, 0)), .bottom = @floatFromInt(@max(h, 0)) };
        try check(slot(*const fn (Obj, *const D2D1_RECT_F) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_clip_rect)(vis, &clip));
        stage = "";
        try self.commit();
    }

    /// Take a pane's visual out of the layer and drop the caller's reference.
    pub fn paneDrop(self: *Host, vis: Obj) void {
        if (self.pane_root) |root| _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, root, slot_dcomp_visual_remove_visual)(root, vis);
        release(vis);
        self.commit() catch {};
    }

    fn ensurePaneRoot(self: *Host) Error!Obj {
        if (self.pane_root) |r| return r;
        if (self.pane_target == null) {
            stage = "pane-target";
            var target: ?Obj = null;
            // topmost=TRUE: over the pane child windows, whose own pixels
            // are then never seen - they stay for input only.
            try check(slot(*const fn (Obj, HWND, i32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_target)(self.dcomp, self.hwnd, 1, &target));
            self.pane_target = target orelse return error.ComFailed;
        }
        stage = "pane-root";
        const root = try self.newVisual();
        errdefer release(root);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.pane_target.?, slot_dcomp_target_set_root)(self.pane_target.?, root));
        self.pane_root = root;
        return root;
    }

    /// Take the desk off the compositor: the window's own pixels show again
    /// in the same commit.
    /// The caption band goes with it: it lives only above the desk.
    pub fn deskHide(self: *Host) void {
        if (self.desk_visual == null) return;
        const had_cap = self.cap_visual != null;
        _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, null);
        _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp);
        self.commit_pending = false;
        self.releaseDesk();
        if (had_cap) log.info("chrome caption visual detached", .{});
        log.info("chrome desk visual detached", .{});
    }

    fn releaseDesk(self: *Host) void {
        self.releaseCap();
        if (self.root_visual) |r| release(r);
        self.root_visual = null;
        if (self.desk_surface) |s| release(s);
        if (self.desk_visual) |v| release(v);
        self.desk_surface = null;
        self.desk_visual = null;
        self.desk_w = 0;
        self.desk_h = 0;
    }

    /// Whether the device under this host is gone, and why. Cheap: two
    /// vtable calls, so it runs on every paint.
    pub fn lostReason(self: *Host) ?Loss {
        if (self.force_loss) {
            self.force_loss = false;
            return .simulated;
        }
        const removed = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.device, slot_d3d11_device_get_removed_reason)(self.device);
        if (removed < 0) return .d3d_removed;
        var valid: i32 = 1;
        const hr = slot(*const fn (Obj, *i32) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_check_state)(self.dcomp, &valid);
        if (hr < 0 or valid == 0) return .dcomp_invalid;
        return null;
    }

    pub fn deinit(self: *Host) void {
        // Detach before the target goes, so the window falls back to its own
        // pixels in the same commit.
        _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, null);
        _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp);
        if (self.pane_target) |pt| {
            _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, pt, slot_dcomp_target_set_root)(pt, null);
            _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp);
        }
        if (self.pane_root) |r| release(r);
        if (self.pane_target) |t| release(t);
        if (self.fill_visual) |v| release(v);
        if (self.fill_surface) |s| release(s);
        self.releaseDesk();
        release(self.target);
        release(self.dcomp);
        release(self.d2d);
        release(self.d2d_device);
        release(self.d2d_factory);
        release(self.context);
        release(self.device);
        self.* = undefined;
    }
};

/// Build a host for `hwnd` when the knob asks for one, logging the outcome
/// either way. Null means the window's chrome stays GDI.
pub fn create(hwnd: HWND, rebuilds: u32) ?Host {
    var host = Host.init(hwnd) catch {
        const f = Host.lastFailure();
        log.warn("chrome composition host unavailable at {s}: hr=0x{x:0>8}; chrome stays GDI", .{ f.stage, hex(f.hr) });
        return null;
    };
    host.rebuilds = rebuilds;
    // The loss seam fires on the first build only; a rebuilt host that read
    // it again would be lost again on every paint.
    if (rebuilds > 0) host.force_loss = false;
    log.info("chrome composition host ready: target_hr=0x{x:0>8} d2d_hr=0x{x:0>8} adapter={s} rebuilds={d}", .{
        hex(host.target_hr), hex(host.d2d_hr), host.adapter(), rebuilds,
    });
    return host;
}

/// Check `slot_host` for device loss and rebuild it in place when the device
/// went away. Called from the window's paint.
pub fn poll(slot_host: *?Host) void {
    if (slot_host.* == null) return;
    const h = &slot_host.*.?;
    const reason = h.lostReason() orelse return;
    const hwnd = h.hwnd;
    const next = h.rebuilds + 1;
    log.warn("chrome composition device lost ({s}); rebuilding", .{reason.label()});
    h.deinit();
    slot_host.* = create(hwnd, next);
}

test "knobOn accepts 1/true/on and nothing else" {
    try std.testing.expect(knobOn("1"));
    try std.testing.expect(knobOn(" On\r\n"));
    try std.testing.expect(knobOn("TRUE"));
    try std.testing.expect(!knobOn(null));
    try std.testing.expect(!knobOn(""));
    try std.testing.expect(!knobOn("0"));
    try std.testing.expect(!knobOn("off"));
}

test "D2D structs match the SDK layout" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(D2D1_BITMAP_PROPERTIES1));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(D2D1_COLOR_F));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(D2D1_RECT_F));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(D3D11_BOX));
}

test "T2543: a paint's clip reaches the caption band only where they overlap" {
    // A caption hover: the band's own rect, wider than any client.
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 800, .bottom = 40 }, bandDirty(.{ .left = 0, .top = 0, .right = 10000, .bottom = 40 }, 800, 40).?);
    // A paint straddling the band's bottom edge keeps only the band's part.
    try std.testing.expectEqual(Rect{ .left = 100, .top = 30, .right = 300, .bottom = 40 }, bandDirty(.{ .left = 100, .top = 30, .right = 300, .bottom = 400 }, 800, 40).?);
    // A desk-only paint below the band reaches none of it.
    try std.testing.expect(bandDirty(.{ .left = 0, .top = 40, .right = 800, .bottom = 600 }, 800, 40) == null);
    try std.testing.expect(bandDirty(.{ .left = 0, .top = 0, .right = 0, .bottom = 40 }, 800, 40) == null);
}

test "loss labels name the cause" {
    try std.testing.expectEqualStrings("simulated (debug test hook)", Loss.simulated.label());
    try std.testing.expect(std.mem.indexOf(u8, Loss.d3d_removed.label(), "removed") != null);
}
