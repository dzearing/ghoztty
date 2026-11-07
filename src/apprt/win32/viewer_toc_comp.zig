//! The viewer contents card's slide on the compositor (T2764, composition
//! step 5d-4 of T2555).
//!
//! The compact contents card is a `WS_CHILD` of the viewer's host window,
//! floating over the WebView2 child. Until now it slid by moving that window
//! on every frame-clock tick, so a busy UI thread froze it mid-pane. Here the
//! card's picture goes up on a DirectComposition visual of the HOST window
//! for the length of a slide, and the whole slide is declared once: the
//! card's x is one cubic in time (`viewer_toc_layout.slidePlan`), handed to
//! `IDCompositionAnimation` and then run by DWM at the display's refresh.
//!
//! The target is `topmost=TRUE`, so the visual composes OVER the host's child
//! windows (the page, the nav bar): the same stacking the card's window has
//! as `HWND_TOP`. While a slide runs the card's window is hidden and this
//! visual is the card; at the end the window is shown at its resting place
//! first and the visual taken down after, so the hand-over shows the same
//! pixels throughout.
//!
//! Window thread only. Any failure leaves the caller to step the slide the
//! old way, and says which step failed in the log; the next slide builds the
//! host again from nothing (which is also the whole device-loss story - a
//! slide is 150 ms of motion, not state worth recovering).
//!
//! Vtable slots are the ones `chrome_comp.zig` uses, checked there against
//! the 10.0.26100.0 SDK headers (d3d11.h, dxgi.h, dcomp.h).
const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const toc = @import("viewer_toc_layout.zig");

const log = std.log.scoped(.viewer_toc_comp);

const GUID = std.os.windows.GUID;
const HRESULT = std.os.windows.HRESULT;
const HWND = std.os.windows.HWND;
const Obj = *anyopaque;

pub const Error = error{ Unavailable, ComFailed };

fn guid(comptime s: []const u8) GUID {
    return GUID.parse("{" ++ s ++ "}");
}

const IID_IDXGIDevice = guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
const IID_IDCompositionDevice = guid("c37ea93a-e7aa-450d-b16f-9746cb0407f3");
const IID_ID3D11Texture2D = guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D_DRIVER_TYPE_WARP: u32 = 5;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_SDK_VERSION: u32 = 7;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const DXGI_ALPHA_MODE_PREMULTIPLIED: u32 = 1;

const slot_dcomp_device_commit = 3;
const slot_dcomp_device_wait_commit = 4;
const slot_dcomp_device_create_target = 6;
const slot_dcomp_device_create_visual = 7;
const slot_dcomp_device_create_surface = 8;
const slot_dcomp_device_create_animation = 25;
const slot_dcomp_surface_begin_draw = 3;
const slot_dcomp_surface_end_draw = 4;
const slot_dcomp_target_set_root = 3;
// IDCompositionVisual: an overloaded setter's animation form comes first,
// its value form second (SetOffsetX(animation) 3 / (float) 4).
const slot_dcomp_visual_set_offset_x_anim = 3;
const slot_dcomp_visual_set_offset_x = 4;
const slot_dcomp_visual_set_offset_y = 6;
const slot_dcomp_visual_set_content = 15;
const slot_dcomp_visual_add_visual = 16;
const slot_dcomp_visual_remove_visual = 17;
const slot_dcomp_anim_add_cubic = 5;
const slot_dcomp_anim_end = 8;
const slot_d3d11_context_update_subresource = 48;

const D3D11_BOX = extern struct { left: u32, top: u32, front: u32, right: u32, bottom: u32, back: u32 };

fn slot(comptime F: type, obj: Obj, index: usize) F {
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(vtbl.*[index]);
}

var stage: []const u8 = "";
var last_hr: HRESULT = 0;

fn check(hr: HRESULT) Error!void {
    if (hr < 0) {
        last_hr = hr;
        return error.ComFailed;
    }
}

fn release(obj: Obj) void {
    _ = slot(*const fn (Obj) callconv(.winapi) u32, obj, 2)(obj);
}

fn query(obj: Obj, iid: *const GUID) Error!Obj {
    var out: ?Obj = null;
    try check(slot(*const fn (Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT, obj, 0)(obj, iid, &out));
    return out orelse error.ComFailed;
}

extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;

const D3D11CreateDeviceFn = *const fn (?Obj, u32, ?*anyopaque, u32, ?*const u32, u32, u32, *?Obj, ?*u32, *?Obj) callconv(.winapi) HRESULT;
const DCompCreateDeviceFn = *const fn (?Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT;

/// One host per viewer pane, built on the pane's first slide.
pub const Host = struct {
    device: Obj, // ID3D11Device
    context: Obj, // ID3D11DeviceContext
    dcomp: Obj, // IDCompositionDevice
    target: Obj, // IDCompositionTarget, topmost=TRUE on the viewer host
    root: Obj, // IDCompositionVisual, the target's root
    card: Obj, // IDCompositionVisual carrying the card's picture
    surface: ?Obj = null, // IDCompositionSurface, `surf_w` x `surf_h`
    surf_w: i32 = 0,
    surf_h: i32 = 0,
    /// The card visual is among the root's children.
    shown: bool = false,

    pub fn init(hwnd: HWND) Error!Host {
        if (comptime builtin.os.tag != .windows) return error.Unavailable;
        last_hr = 0;
        stage = "load-libraries";
        const d3d11 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse return error.Unavailable;
        const dcomp_lib = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll")) orelse return error.Unavailable;
        const d3d_create: D3D11CreateDeviceFn = @ptrCast(GetProcAddress(d3d11, "D3D11CreateDevice") orelse return error.Unavailable);
        const dcomp_create: DCompCreateDeviceFn = @ptrCast(GetProcAddress(dcomp_lib, "DCompositionCreateDevice") orelse return error.Unavailable);

        stage = "d3d11-device";
        var device: ?Obj = null;
        var context: ?Obj = null;
        if (d3d_create(null, D3D_DRIVER_TYPE_HARDWARE, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context) < 0) {
            try check(d3d_create(null, D3D_DRIVER_TYPE_WARP, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context));
        }
        const dev = device orelse return error.ComFailed;
        errdefer release(dev);
        const ctx = context orelse return error.ComFailed;
        errdefer release(ctx);

        stage = "dxgi-device";
        const dxgi = try query(dev, &IID_IDXGIDevice);
        defer release(dxgi);

        stage = "dcomp-device";
        var dcomp: ?Obj = null;
        try check(dcomp_create(dxgi, &IID_IDCompositionDevice, &dcomp));
        const dc = dcomp orelse return error.ComFailed;
        errdefer release(dc);

        stage = "dcomp-target";
        var target: ?Obj = null;
        // topmost=TRUE: over the host's child windows, as the card's own
        // window is (HWND_TOP over the page).
        try check(slot(*const fn (Obj, HWND, i32, *?Obj) callconv(.winapi) HRESULT, dc, slot_dcomp_device_create_target)(dc, hwnd, 1, &target));
        const tg = target orelse return error.ComFailed;
        errdefer release(tg);

        stage = "visuals";
        const root = try newVisual(dc);
        errdefer release(root);
        const card = try newVisual(dc);
        errdefer release(card);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, tg, slot_dcomp_target_set_root)(tg, root));
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, dc, slot_dcomp_device_commit)(dc));
        stage = "";
        return .{ .device = dev, .context = ctx, .dcomp = dc, .target = tg, .root = root, .card = card };
    }

    pub fn deinit(self: *Host) void {
        if (self.shown) {
            _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, self.root, slot_dcomp_visual_remove_visual)(self.root, self.card);
            self.shown = false;
        }
        _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, null);
        _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp);
        if (self.surface) |s| release(s);
        release(self.card);
        release(self.root);
        release(self.target);
        release(self.dcomp);
        release(self.context);
        release(self.device);
        self.* = undefined;
    }

    /// The step that failed and its HRESULT, for the caller's log line.
    pub fn lastFailure() struct { stage: []const u8, hr: u32 } {
        return .{ .stage = stage, .hr = @bitCast(last_hr) };
    }

    /// Put `px` (premultiplied BGRA rows, `w` x `h`) on the card visual.
    pub fn setPicture(self: *Host, px: []const u32, w: i32, h: i32) Error!void {
        if (w <= 0 or h <= 0 or px.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return error.ComFailed;
        stage = "surface";
        defer stage = "";
        if (self.surface == null or self.surf_w != w or self.surf_h != h) {
            var made: ?Obj = null;
            try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, @intCast(w), @intCast(h), DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &made));
            const surf = made orelse return error.ComFailed;
            if (self.surface) |old| release(old);
            self.surface = surf;
            self.surf_w = w;
            self.surf_h = h;
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.card, slot_dcomp_visual_set_content)(self.card, surf));
        }
        const surf = self.surface.?;
        const update: w32.RECT = .{ .left = 0, .top = 0, .right = w, .bottom = h };
        var tex: ?Obj = null;
        var at: w32.POINT = .{ .x = 0, .y = 0 };
        try check(slot(*const fn (Obj, ?*const w32.RECT, *const GUID, *?Obj, *w32.POINT) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_begin_draw)(surf, &update, &IID_ID3D11Texture2D, &tex, &at));
        const t = tex orelse {
            _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_end_draw)(surf);
            return error.ComFailed;
        };
        // A surface may live in an atlas: the rows land at BeginDraw's offset.
        const box: D3D11_BOX = .{
            .left = @intCast(@max(at.x, 0)),
            .top = @intCast(@max(at.y, 0)),
            .front = 0,
            .right = @intCast(@max(at.x, 0) + w),
            .bottom = @intCast(@max(at.y, 0) + h),
            .back = 1,
        };
        slot(*const fn (Obj, Obj, u32, *const D3D11_BOX, *const anyopaque, u32, u32) callconv(.winapi) void, self.context, slot_d3d11_context_update_subresource)(self.context, t, 0, &box, px.ptr, @intCast(w * 4), 0);
        release(t);
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_end_draw)(surf));
    }

    /// Declare the slide: the card's top at `y`, its x along `plan`, all on
    /// the compositor's clock. Shows the visual, commits, and waits for the
    /// commit to reach DWM, so a caller hiding the card's window next cannot
    /// open a frame with neither on screen.
    pub fn play(self: *Host, y: i32, plan: toc.SlidePlan) Error!void {
        stage = "animation";
        defer stage = "";
        var made: ?Obj = null;
        try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_animation)(self.dcomp, &made));
        const anim = made orelse return error.ComFailed;
        // The visual keeps its own snapshot of the function once it is set.
        defer release(anim);
        const c = plan.c;
        try check(slot(*const fn (Obj, f64, f32, f32, f32, f32) callconv(.winapi) HRESULT, anim, slot_dcomp_anim_add_cubic)(anim, 0, @floatCast(c[0]), @floatCast(c[1]), @floatCast(c[2]), @floatCast(c[3])));
        try check(slot(*const fn (Obj, f64, f32) callconv(.winapi) HRESULT, anim, slot_dcomp_anim_end)(anim, plan.span_s, @floatCast(plan.end_x)));
        try check(slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, self.card, slot_dcomp_visual_set_offset_x_anim)(self.card, anim));
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, self.card, slot_dcomp_visual_set_offset_y)(self.card, @floatFromInt(y)));
        if (!self.shown) {
            try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, self.root, slot_dcomp_visual_add_visual)(self.root, self.card, 1, null));
            self.shown = true;
        }
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp));
        _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_wait_commit)(self.dcomp);
    }

    /// Take the card visual down (the slide ended, or was cancelled). Pins
    /// the offset where `x` says first, so a later `play` never inherits a
    /// stale animation. Commits.
    pub fn stop(self: *Host, x: f64) void {
        _ = slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, self.card, slot_dcomp_visual_set_offset_x)(self.card, @floatCast(x));
        if (self.shown) {
            _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, self.root, slot_dcomp_visual_remove_visual)(self.root, self.card);
            self.shown = false;
        }
        _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp);
    }
};

fn newVisual(dc: Obj) Error!Obj {
    var v: ?Obj = null;
    try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, dc, slot_dcomp_device_create_visual)(dc, &v));
    return v orelse error.ComFailed;
}

/// Turn a GDI-painted card (alpha bytes undefined) into premultiplied pixels:
/// opaque where `mask` is non-zero, fully clear elsewhere. `mask` is the
/// card's window region painted white on black, so the rounded corners show
/// the page underneath exactly as the window region lets them.
pub fn premultiplyByMask(px: []u32, mask: []const u32) void {
    for (px, mask) |*p, m| {
        p.* = if ((m & 0x00FFFFFF) != 0) (p.* | 0xFF000000) else 0;
    }
}

test "T2764 card pixels: inside the region opaque, outside fully clear" {
    var px = [_]u32{ 0x00112233, 0x00445566, 0xAB778899 };
    const mask = [_]u32{ 0x00FFFFFF, 0, 0x00FFFFFF };
    premultiplyByMask(&px, &mask);
    try std.testing.expectEqual(@as(u32, 0xFF112233), px[0]);
    try std.testing.expectEqual(@as(u32, 0), px[1]);
    try std.testing.expectEqual(@as(u32, 0xFF778899), px[2]);
}
