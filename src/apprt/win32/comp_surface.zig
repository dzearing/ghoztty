//! Drawn content for Windows.UI.Composition: a D3D11 device (hardware first,
//! then WARP) behind a `CompositionGraphicsDevice`, one `CompositionDrawingSurface`
//! painted from the CPU, and the device-loss recovery the composition path must
//! have before it can ship (T2360 hard constraint, T2465).
//!
//! Why this exists apart from `winrt_comp.zig`: colour sprites need no device
//! at all, so the spike's first runs never touched Direct3D and said nothing
//! about the case the user named - a Remote Desktop session or a machine with
//! no GPU, where the only D3D adapter is WARP, the CPU rasterizer built into
//! every Windows install. Anything the real app draws (glyphs, chrome) arrives
//! through a surface like this one, so this is the piece that has to survive.
//!
//! Recovery shape. A Remote Desktop connect or disconnect, a driver update, or
//! a GPU reset can remove the adapter under a running app; every D3D call then
//! fails with DXGI_ERROR_DEVICE_REMOVED and the surfaces go blank. The
//! composition objects themselves (visuals, brushes, the surfaces' identity)
//! survive: `ICompositionGraphicsDeviceInterop::SetRenderingDevice` swaps a
//! fresh D3D device in underneath, and the content is drawn again. So recovery
//! is "new device, rebind, redraw", never "rebuild the scene", and the visual
//! tree - including any animation already running on DWM's clock - is left
//! alone.
//!
//! Slots are from `Windows Kits\10\Include\10.0.22621.0`:
//! `winrt\windows.ui.composition.interop.h` (IUnknown-based, own methods from
//! slot 3), `winrt\windows.ui.composition.h` (IInspectable, own methods from
//! slot 6), and `um\d3d11.h`.
const std = @import("std");
const rt = @import("winrt_comp.zig");

const Obj = rt.Obj;
const GUID = rt.GUID;
const HRESULT = rt.HRESULT;

fn guid(comptime s: []const u8) GUID {
    return GUID.parse("{" ++ s ++ "}");
}

const IID_ICompositorInterop = guid("25297d5c-3ad4-4c9c-b5cf-e36a38512330");
const IID_ICompositionGraphicsDeviceInterop = guid("a116ff71-f8bf-4c8a-9c98-70779a32a9c8");
const IID_ICompositionDrawingSurfaceInterop = guid("fd04e6e3-fe0c-4c3c-ab19-a07601a576ee");
const IID_ICompositionSurface = guid("1527540d-42c7-47a6-a408-668f79a90dfb");
const IID_IDXGISurface = guid("cafcb56c-6ac3-4889-bf47-9e23bbd260ec");
const IID_ID3D11Texture2D = guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D_DRIVER_TYPE_WARP: u32 = 5;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_SDK_VERSION: u32 = 7;
/// Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized.
const PIXEL_BGRA8: u32 = 87;
/// Windows.Graphics.DirectX.DirectXAlphaMode.Premultiplied.
const ALPHA_PREMULTIPLIED: u32 = 1;

pub const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
pub const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));

pub const Error = rt.Error;

/// Which adapter to ask for. `auto` is the shipping rule: hardware, and WARP
/// when there is no hardware adapter to be had.
pub const DeviceKind = enum { auto, hardware, warp };

threadlocal var last_hr: HRESULT = 0;

pub fn lastHr() HRESULT {
    return last_hr;
}

fn check(hr: HRESULT) Error!void {
    if (rt.failed(hr)) {
        last_hr = hr;
        return error.ComFailed;
    }
}

fn slot(comptime F: type, obj: Obj, index: usize) F {
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(vtbl.*[index]);
}

fn query(obj: Obj, iid: *const GUID) Error!Obj {
    const F = *const fn (Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT;
    var out: ?Obj = null;
    try check(slot(F, obj, 0)(obj, iid, &out));
    return out orelse error.ComFailed;
}

const release = rt.release;

extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;

const D3D11CreateDeviceFn = *const fn (?Obj, u32, ?*anyopaque, u32, ?*const u32, u32, u32, *?Obj, ?*u32, *?Obj) callconv(.winapi) HRESULT;

var d3d11_create: ?D3D11CreateDeviceFn = null;

fn loadD3D11() Error!D3D11CreateDeviceFn {
    if (d3d11_create) |f| return f;
    const lib = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse
        return error.Unavailable;
    const f: D3D11CreateDeviceFn = @ptrCast(GetProcAddress(lib, "D3D11CreateDevice") orelse
        return error.Unavailable);
    d3d11_create = f;
    return f;
}

/// The driver types to try, in order, for `kind`. Pure so the fallback rule
/// is a unit test: `auto` must end at WARP, because "never fail to start
/// because there is no GPU" is the constraint this whole path is held to.
pub fn driverOrder(kind: DeviceKind) []const u32 {
    return switch (kind) {
        .auto => &.{ D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP },
        .hardware => &.{D3D_DRIVER_TYPE_HARDWARE},
        .warp => &.{D3D_DRIVER_TYPE_WARP},
    };
}

pub const Device = struct {
    d3d: Obj, // ID3D11Device
    context: Obj, // ID3D11DeviceContext
    warp: bool,

    pub fn create(kind: DeviceKind) Error!Device {
        const create_fn = try loadD3D11();
        var hr: HRESULT = 0;
        for (driverOrder(kind)) |driver| {
            var dev: ?Obj = null;
            var ctx: ?Obj = null;
            hr = create_fn(null, driver, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &dev, null, &ctx);
            if (!rt.failed(hr)) {
                return .{
                    .d3d = dev orelse return error.ComFailed,
                    .context = ctx orelse return error.ComFailed,
                    .warp = driver == D3D_DRIVER_TYPE_WARP,
                };
            }
        }
        try check(hr);
        unreachable;
    }

    pub fn deinit(self: Device) void {
        release(self.context);
        release(self.d3d);
    }

    /// ID3D11Device::GetDeviceRemovedReason (slot 39): S_OK while the device
    /// is usable, otherwise why it went away.
    pub fn removedReason(self: Device) HRESULT {
        const F = *const fn (Obj) callconv(.winapi) HRESULT;
        return slot(F, self.d3d, 39)(self.d3d);
    }
};

/// What a `WM_WTSSESSION_CHANGE` code means for the rendering device. The
/// session events that move the session between the console and a remote
/// client are the ones that swap the display adapter under a running app, so
/// they are checked; the rest (lock, logon, remote control) are not.
pub fn sessionEventChecksDevice(code: usize) bool {
    return switch (code) {
        0x1, // WTS_CONSOLE_CONNECT
        0x2, // WTS_CONSOLE_DISCONNECT
        0x3, // WTS_REMOTE_CONNECT
        0x4, // WTS_REMOTE_DISCONNECT
        0x8, // WTS_SESSION_UNLOCK: the reconnect path after a disconnect
        => true,
        else => false,
    };
}

pub fn sessionEventName(code: usize) []const u8 {
    return switch (code) {
        0x1 => "console-connect",
        0x2 => "console-disconnect",
        0x3 => "remote-connect",
        0x4 => "remote-disconnect",
        0x5 => "logon",
        0x6 => "logoff",
        0x7 => "lock",
        0x8 => "unlock",
        0x9 => "remote-control",
        else => "other",
    };
}

/// Fill `w` x `h` BGRA pixels (premultiplied; opaque here) with one colour.
pub fn fill(buf: []u8, w: u32, h: u32, bgra: [4]u8) void {
    const n = @as(usize, w) * h;
    std.debug.assert(buf.len >= n * 4);
    var i: usize = 0;
    while (i < n) : (i += 1) @memcpy(buf[i * 4 ..][0..4], &bgra);
}

/// One drawing surface on one graphics device, wrapped in a surface brush a
/// SpriteVisual can wear. The brush stretches the surface to the visual, so
/// a Size animation on the visual needs no redraw.
pub const Surface = struct {
    device: Device,
    kind: DeviceKind,
    graphics: Obj, // ICompositionGraphicsDevice
    drawing: Obj, // ICompositionDrawingSurface
    brush: Obj, // ICompositionSurfaceBrush (as ICompositionBrush)
    w: u32,
    h: u32,
    bgra: [4]u8,
    pixels: []u8,
    alloc: std.mem.Allocator,
    /// How many times the content has been drawn, and the device rebound.
    draws: u32 = 0,
    rebinds: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, compositor: rt.Compositor, kind: DeviceKind, w: u32, h: u32, bgra: [4]u8) Error!Surface {
        const device = try Device.create(kind);
        errdefer device.deinit();

        // ICompositorInterop::CreateGraphicsDevice (slot 5).
        const interop = try query(compositor.obj, &IID_ICompositorInterop);
        defer release(interop);
        const CreateGraphicsDevice = *const fn (Obj, Obj, *?Obj) callconv(.winapi) HRESULT;
        var gd: ?Obj = null;
        try check(slot(CreateGraphicsDevice, interop, 5)(interop, device.d3d, &gd));
        const graphics = gd orelse return error.ComFailed;
        errdefer release(graphics);

        // ICompositionGraphicsDevice::CreateDrawingSurface (slot 6).
        const Size = extern struct { w: f32, h: f32 };
        const CreateDrawingSurface = *const fn (Obj, Size, u32, u32, *?Obj) callconv(.winapi) HRESULT;
        var ds: ?Obj = null;
        try check(slot(CreateDrawingSurface, graphics, 6)(graphics, .{ .w = @floatFromInt(w), .h = @floatFromInt(h) }, PIXEL_BGRA8, ALPHA_PREMULTIPLIED, &ds));
        const drawing = ds orelse return error.ComFailed;
        errdefer release(drawing);

        // ICompositor::CreateSurfaceBrushWithSurface (slot 24).
        const surface = try query(drawing, &IID_ICompositionSurface);
        defer release(surface);
        const CreateSurfaceBrush = *const fn (Obj, Obj, *?Obj) callconv(.winapi) HRESULT;
        var sb: ?Obj = null;
        try check(slot(CreateSurfaceBrush, compositor.obj, 24)(compositor.obj, surface, &sb));
        const sbrush = sb orelse return error.ComFailed;
        defer release(sbrush);
        const brush = try query(sbrush, &rt.IID_ICompositionBrush);
        errdefer release(brush);

        const pixels = alloc.alloc(u8, @as(usize, w) * h * 4) catch return error.ComFailed;
        fill(pixels, w, h, bgra);

        var self: Surface = .{
            .device = device,
            .kind = kind,
            .graphics = graphics,
            .drawing = drawing,
            .brush = brush,
            .w = w,
            .h = h,
            .bgra = bgra,
            .pixels = pixels,
            .alloc = alloc,
        };
        try self.draw();
        return self;
    }

    pub fn deinit(self: *Surface) void {
        release(self.brush);
        release(self.drawing);
        release(self.graphics);
        self.device.deinit();
        self.alloc.free(self.pixels);
    }

    /// Paint the whole surface: BeginDraw hands back a slice of an atlas
    /// texture at `offset`, so the copy targets exactly that box and nothing
    /// else in the atlas.
    pub fn draw(self: *Surface) Error!void {
        const di = try query(self.drawing, &IID_ICompositionDrawingSurfaceInterop);
        defer release(di);
        const POINT = extern struct { x: i32, y: i32 };
        const BeginDraw = *const fn (Obj, ?*const anyopaque, *const GUID, *?Obj, *POINT) callconv(.winapi) HRESULT;
        const EndDraw = *const fn (Obj) callconv(.winapi) HRESULT;
        var upd: ?Obj = null;
        var off: POINT = .{ .x = 0, .y = 0 };
        try check(slot(BeginDraw, di, 3)(di, null, &IID_IDXGISurface, &upd, &off));
        const dxgi_surface = upd orelse return error.ComFailed;
        defer release(dxgi_surface);
        // A drawing session must be closed even when the copy fails, or the
        // surface stays locked for every later draw.
        defer _ = slot(EndDraw, di, 4)(di);
        const tex = try query(dxgi_surface, &IID_ID3D11Texture2D);
        defer release(tex);

        // ID3D11DeviceContext::UpdateSubresource (slot 48), on the device the
        // surface was drawn with: the graphics device's current one.
        const Box = extern struct { left: u32, top: u32, front: u32, right: u32, bottom: u32, back: u32 };
        const box: Box = .{
            .left = @intCast(off.x),
            .top = @intCast(off.y),
            .front = 0,
            .right = @as(u32, @intCast(off.x)) + self.w,
            .bottom = @as(u32, @intCast(off.y)) + self.h,
            .back = 1,
        };
        const UpdateSubresource = *const fn (Obj, Obj, u32, ?*const Box, [*]const u8, u32, u32) callconv(.winapi) void;
        slot(UpdateSubresource, self.device.context, 48)(self.device.context, tex, 0, &box, self.pixels.ptr, self.w * 4, 0);
        self.draws += 1;
    }

    /// Swap a fresh D3D device in under the graphics device and draw again.
    /// The visual tree, the brush, and any animation running on it are not
    /// touched. Returns whether the new device is WARP.
    pub fn rebind(self: *Surface, kind: DeviceKind) Error!bool {
        const fresh = try Device.create(kind);
        errdefer fresh.deinit();
        const gi = try query(self.graphics, &IID_ICompositionGraphicsDeviceInterop);
        defer release(gi);
        const SetRenderingDevice = *const fn (Obj, Obj) callconv(.winapi) HRESULT;
        try check(slot(SetRenderingDevice, gi, 4)(gi, fresh.d3d));
        self.device.deinit();
        self.device = fresh;
        self.kind = kind;
        self.rebinds += 1;
        try self.draw();
        return fresh.warp;
    }

    /// Check the device and recover it when it has gone. Returns null when it
    /// was healthy, otherwise the removed reason it recovered from.
    pub fn recoverIfLost(self: *Surface) Error!?HRESULT {
        const why = self.device.removedReason();
        if (!rt.failed(why)) return null;
        _ = try self.rebind(self.kind);
        return why;
    }
};

test "auto falls back to WARP; explicit kinds take one driver" {
    const auto = driverOrder(.auto);
    try std.testing.expectEqual(@as(usize, 2), auto.len);
    try std.testing.expectEqual(D3D_DRIVER_TYPE_HARDWARE, auto[0]);
    try std.testing.expectEqual(D3D_DRIVER_TYPE_WARP, auto[auto.len - 1]);
    try std.testing.expectEqualSlices(u32, &.{D3D_DRIVER_TYPE_WARP}, driverOrder(.warp));
    try std.testing.expectEqualSlices(u32, &.{D3D_DRIVER_TYPE_HARDWARE}, driverOrder(.hardware));
}

test "session events that move the session between console and remote check the device" {
    try std.testing.expect(sessionEventChecksDevice(0x3));
    try std.testing.expect(sessionEventChecksDevice(0x4));
    try std.testing.expect(sessionEventChecksDevice(0x1));
    try std.testing.expect(sessionEventChecksDevice(0x2));
    try std.testing.expect(sessionEventChecksDevice(0x8));
    try std.testing.expect(!sessionEventChecksDevice(0x7));
    try std.testing.expect(!sessionEventChecksDevice(0x5));
    try std.testing.expectEqualStrings("remote-connect", sessionEventName(0x3));
    try std.testing.expectEqualStrings("other", sessionEventName(0x42));
}

test "fill writes every pixel in BGRA order" {
    var buf: [3 * 2 * 4]u8 = undefined;
    fill(&buf, 3, 2, .{ 0x2b, 0x6c, 0xd8, 0xff });
    var i: usize = 0;
    while (i < 6) : (i += 1) try std.testing.expectEqualSlices(u8, &.{ 0x2b, 0x6c, 0xd8, 0xff }, buf[i * 4 ..][0..4]);
}

test "DXGI removed/reset codes are failures" {
    try std.testing.expect(rt.failed(DXGI_ERROR_DEVICE_REMOVED));
    try std.testing.expect(rt.failed(DXGI_ERROR_DEVICE_RESET));
}
