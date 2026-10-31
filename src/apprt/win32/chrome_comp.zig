//! The window CHROME's composition host (T2508, T2360 step 4a): a
//! DirectComposition target on the top-level window, with a Direct2D device
//! context over the same D3D11 device, ready for the chrome painters to move
//! onto.
//!
//! Infrastructure only. No visual is attached in a normal run, and that is the
//! point of this step rather than a gap in it: a DComp target's visual tree
//! composes ABOVE the window's own redirected GDI pixels - `topmost=FALSE`
//! only puts it BELOW the window's child windows (the panes) - so the first
//! visual hung here hides every GDI chrome painter under it. T2509 attaches
//! the desk as the bottom visual; T2510 moves the remaining painters over it.
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
const slot_dcomp_device_check_state = 26;
const slot_dcomp_surface_begin_draw = 3;
const slot_dcomp_surface_end_draw = 4;
const slot_dcomp_target_set_root = 3;
const slot_dcomp_visual_set_content = 15;

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
        if (self.fill_visual) |v| release(v);
        if (self.fill_surface) |s| release(s);
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
}

test "loss labels name the cause" {
    try std.testing.expectEqualStrings("simulated (debug test hook)", Loss.simulated.label());
    try std.testing.expect(std.mem.indexOf(u8, Loss.d3d_removed.label(), "removed") != null);
}
