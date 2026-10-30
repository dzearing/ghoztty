//! Windows.Graphics.Capture of ONE window, as raw COM/WinRT vtable calls
//! (T2463). This is the per-window frame oracle the composition spike needs.
//!
//! Why it exists: the spike's first clock was system-wide. DComp frame
//! statistics count every frame DWM composes for the whole desktop, so on a
//! desktop where anything else moves, a window with nothing animating scored
//! advance 1.000 (T2360 spike report, 2026-10-29). WGC hands back a frame of
//! one window's picture each time DWM produced a new one, stamped with the
//! QPC time of that compose (`SystemRelativeTime`). Reading the picture as
//! well as the stamp lets the caller count a frame only when what it shows
//! changed, so even a frame DWM re-delivers without a visual change scores 0.
//!
//! Slots were checked against the 10.0.22621.0 SDK: winrt/
//! windows.graphics.capture.h (C vtable structs), um/
//! Windows.Graphics.Capture.Interop.h, um/
//! windows.graphics.directx.direct3d11.interop.h and um/d3d11.h. IInspectable
//! interfaces start their own methods at slot 6, IUnknown ones at slot 3.
//!
//! Everything is loaded with GetProcAddress, like winrt_comp.zig, so a machine
//! without WGC (pre-1903) reports `error.Unavailable` rather than failing to
//! start.
const std = @import("std");
const rt = @import("winrt_comp.zig");

const GUID = rt.GUID;
const HRESULT = rt.HRESULT;
const HWND = rt.HWND;
const Obj = rt.Obj;

fn guid(comptime s: []const u8) GUID {
    return GUID.parse("{" ++ s ++ "}");
}

const IID_IGraphicsCaptureItemInterop = guid("3628e81b-3cac-4c60-b7f4-23ce0e0c3356");
const IID_IGraphicsCaptureItem = guid("79c3f95b-31f7-4ec2-a464-632ef5d30760");
const IID_IDirect3D11CaptureFramePoolStatics2 = guid("589b103f-6bbc-5df5-a991-02e28b3b66d5");
const IID_IGraphicsCaptureSession2 = guid("2c39ae40-7d2e-5044-804e-8b6799d4cf9e");
const IID_IGraphicsCaptureSession3 = guid("f2cdd966-22ae-5ea1-9596-3a289344c3be");
/// 10.0.26100.0 SDK (UniversalApiContract 19): MinUpdateInterval.
const IID_IGraphicsCaptureSession5 = guid("67c0ea62-1f85-5061-925a-239be0ac09cb");
const IID_IClosable = guid("30d5a829-7fa4-4026-83bb-d75bae4ea99e");
const IID_IDirect3DDxgiInterfaceAccess = guid("a9b3d012-3df2-4ee3-b8d1-8695f457d3c1");
const IID_IDXGIDevice = guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
const IID_ID3D11Texture2D = guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

pub const SizeInt32 = extern struct { w: i32, h: i32 };

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
const D3D11_BOX = extern struct { left: u32, top: u32, front: u32, right: u32, bottom: u32, back: u32 };
const D3D11_MAPPED_SUBRESOURCE = extern struct { data: ?[*]u8, row_pitch: u32, depth_pitch: u32 };

const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
/// Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized.
const PIXEL_BGRA8: u32 = 87;
const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D_DRIVER_TYPE_WARP: u32 = 5;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_SDK_VERSION: u32 = 7;
const D3D11_USAGE_STAGING: u32 = 3;
const D3D11_CPU_ACCESS_READ: u32 = 0x20000;
const D3D11_MAP_READ: u32 = 1;

pub const Error = rt.Error;

threadlocal var last_hr: HRESULT = 0;
/// The `init` step in progress on this thread, so a failure names it.
pub threadlocal var stage: []const u8 = "";
/// The window size the capture item reported, for the report.
pub threadlocal var item_size: SizeInt32 = .{ .w = 0, .h = 0 };

/// The HRESULT of the last failed call on this thread, for the report.
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

const Entry = struct {
    ro_initialize: *const fn (u32) callconv(.winapi) HRESULT,
    ro_factory: *const fn (rt.HSTRING, *const GUID, *?Obj) callconv(.winapi) HRESULT,
    create_string: *const fn ([*]const u16, u32, *rt.HSTRING) callconv(.winapi) HRESULT,
    delete_string: *const fn (rt.HSTRING) callconv(.winapi) HRESULT,
    d3d11_create: *const fn (?Obj, u32, ?*anyopaque, u32, ?*const u32, u32, u32, *?Obj, ?*u32, *?Obj) callconv(.winapi) HRESULT,
    winrt_device: *const fn (Obj, *?Obj) callconv(.winapi) HRESULT,
};

fn sym(comptime T: type, lib: *anyopaque, name: [*:0]const u8) Error!T {
    return @ptrCast(GetProcAddress(lib, name) orelse return error.Unavailable);
}

fn loadEntry() Error!Entry {
    const combase = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("combase.dll")) orelse
        return error.Unavailable;
    const d3d11 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse
        return error.Unavailable;
    return .{
        .ro_initialize = try sym(@FieldType(Entry, "ro_initialize"), combase, "RoInitialize"),
        .ro_factory = try sym(@FieldType(Entry, "ro_factory"), combase, "RoGetActivationFactory"),
        .create_string = try sym(@FieldType(Entry, "create_string"), combase, "WindowsCreateString"),
        .delete_string = try sym(@FieldType(Entry, "delete_string"), combase, "WindowsDeleteString"),
        .d3d11_create = try sym(@FieldType(Entry, "d3d11_create"), d3d11, "D3D11CreateDevice"),
        .winrt_device = try sym(@FieldType(Entry, "winrt_device"), d3d11, "CreateDirect3D11DeviceFromDXGIDevice"),
    };
}

fn factory(e: *const Entry, comptime class: []const u8, iid: *const GUID) Error!Obj {
    const w = std.unicode.utf8ToUtf16LeStringLiteral(class);
    var h: rt.HSTRING = null;
    try check(e.create_string(w, @intCast(w.len), &h));
    defer _ = e.delete_string(h);
    var out: ?Obj = null;
    try check(e.ro_factory(h, iid, &out));
    return out orelse error.ComFailed;
}

/// One captured frame, reduced to what the oracle needs.
pub const Frame = struct {
    /// QPC ticks converted to 100 ns units (`SystemRelativeTime`).
    time_100ns: i64,
    /// The sampled row, BGRA, `width` pixels. Valid until the next `next()`.
    row: []const u8,
    width: u32,
};

/// One whole captured frame (`Capture.grab`): BGRA, `width * 4` bytes per
/// row, top row first. The caller frees `pixels`.
pub const Image = struct {
    time_100ns: i64,
    width: u32,
    height: u32,
    pixels: []u8,
};

/// A capture session on one window. Create, use and destroy it on ONE thread;
/// the frame pool is free-threaded, so that thread needs no message pump.
pub const Capture = struct {
    entry: Entry,
    device: Obj, // ID3D11Device
    context: Obj, // ID3D11DeviceContext
    winrt_device: Obj, // IDirect3DDevice
    item: Obj,
    pool: Obj,
    session: Obj,
    staging: ?Obj = null,
    staging_w: u32 = 0,
    row_buf: []u8 = &.{},
    alloc: std.mem.Allocator,
    /// `true` when the yellow capture border could be turned off.
    borderless: bool = false,
    /// `true` when the device is WARP (no hardware adapter).
    warp: bool = false,
    /// MinUpdateInterval before we lowered it (100 ns ticks); null when the
    /// OS predates IGraphicsCaptureSession5.
    default_min_interval: ?i64 = null,

    pub fn init(alloc: std.mem.Allocator, hwnd: HWND) Error!Capture {
        const e = try loadEntry();
        stage = "ro-initialize";
        const hr = e.ro_initialize(1); // RO_INIT_MULTITHREADED
        if (rt.failed(hr) and hr != @as(HRESULT, @bitCast(@as(u32, 0x80010106)))) try check(hr);

        stage = "d3d11-device";
        var device: ?Obj = null;
        var context: ?Obj = null;
        var warp = false;
        if (rt.failed(e.d3d11_create(null, D3D_DRIVER_TYPE_HARDWARE, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context))) {
            warp = true;
            try check(e.d3d11_create(null, D3D_DRIVER_TYPE_WARP, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context));
        }
        const dev = device orelse return error.ComFailed;
        errdefer release(dev);
        const ctx = context orelse return error.ComFailed;
        errdefer release(ctx);

        stage = "winrt-device";
        const dxgi = try query(dev, &IID_IDXGIDevice);
        defer release(dxgi);
        var wd: ?Obj = null;
        try check(e.winrt_device(dxgi, &wd));
        const winrt_dev = wd orelse return error.ComFailed;
        errdefer release(winrt_dev);

        stage = "create-for-window";
        // IGraphicsCaptureItemInterop::CreateForWindow (IUnknown slot 3).
        const interop = try factory(&e, "Windows.Graphics.Capture.GraphicsCaptureItem", &IID_IGraphicsCaptureItemInterop);
        defer release(interop);
        var it: ?Obj = null;
        const CreateForWindow = *const fn (Obj, HWND, *const GUID, *?Obj) callconv(.winapi) HRESULT;
        try check(slot(CreateForWindow, interop, 3)(interop, hwnd, &IID_IGraphicsCaptureItem, &it));
        const item = it orelse return error.ComFailed;
        errdefer release(item);

        stage = "item-size";
        // IGraphicsCaptureItem slot 7: get_Size.
        var size: SizeInt32 = undefined;
        const GetSize = *const fn (Obj, *SizeInt32) callconv(.winapi) HRESULT;
        try check(slot(GetSize, item, 7)(item, &size));
        item_size = size;
        // A window DWM is not composing reports 0x0, which CreateFreeThreaded
        // rejects as E_INVALIDARG. Size the pool anyway so the failure lands
        // where it means something: on a background desktop (measured
        // 2026-10-29) CreateCaptureSession then refuses with
        // ERROR_INVALID_STATE (0x8007139F). WGC needs the input desktop.
        if (size.w <= 0 or size.h <= 0) size = .{ .w = 1024, .h = 720 };

        stage = "frame-pool";
        // IDirect3D11CaptureFramePoolStatics2 slot 6: CreateFreeThreaded.
        const statics = try factory(&e, "Windows.Graphics.Capture.Direct3D11CaptureFramePool", &IID_IDirect3D11CaptureFramePoolStatics2);
        defer release(statics);
        var p: ?Obj = null;
        const CreateFreeThreaded = *const fn (Obj, Obj, u32, i32, SizeInt32, *?Obj) callconv(.winapi) HRESULT;
        try check(slot(CreateFreeThreaded, statics, 6)(statics, winrt_dev, PIXEL_BGRA8, 3, size, &p));
        const pool = p orelse return error.ComFailed;
        errdefer closeAndRelease(pool);

        stage = "session";
        // IDirect3D11CaptureFramePool slot 10: CreateCaptureSession.
        var s: ?Obj = null;
        const CreateSession = *const fn (Obj, Obj, *?Obj) callconv(.winapi) HRESULT;
        try check(slot(CreateSession, pool, 10)(pool, item, &s));
        const session = s orelse return error.ComFailed;
        errdefer closeAndRelease(session);

        // IGraphicsCaptureSession2 slot 7: put_IsCursorCaptureEnabled(false),
        // so a pointer passing over the window never reads as a new frame.
        if (query(session, &IID_IGraphicsCaptureSession2)) |s2| {
            defer release(s2);
            const PutBool = *const fn (Obj, u8) callconv(.winapi) HRESULT;
            _ = slot(PutBool, s2, 7)(s2, 0);
        } else |_| {}
        // IGraphicsCaptureSession3 slot 7: put_IsBorderRequired(false).
        var borderless = false;
        if (query(session, &IID_IGraphicsCaptureSession3)) |s3| {
            defer release(s3);
            const PutBool = *const fn (Obj, u8) callconv(.winapi) HRESULT;
            borderless = !rt.failed(slot(PutBool, s3, 7)(s3, 0));
        } else |_| {}
        // IGraphicsCaptureSession5 slots 6/7: MinUpdateInterval. WGC may
        // rate-limit delivery below the refresh; record the default and ask
        // for every frame, so the oracle measures DWM, not the capture.
        var min_interval: ?i64 = null;
        if (query(session, &IID_IGraphicsCaptureSession5)) |s5| {
            defer release(s5);
            const GetSpan = *const fn (Obj, *i64) callconv(.winapi) HRESULT;
            const PutSpan = *const fn (Obj, i64) callconv(.winapi) HRESULT;
            var d: i64 = 0;
            if (!rt.failed(slot(GetSpan, s5, 6)(s5, &d))) min_interval = d;
            _ = slot(PutSpan, s5, 7)(s5, 1);
        } else |_| {}

        stage = "start-capture";
        // IGraphicsCaptureSession slot 6: StartCapture.
        const Start = *const fn (Obj) callconv(.winapi) HRESULT;
        try check(slot(Start, session, 6)(session));

        return .{
            .entry = e,
            .device = dev,
            .context = ctx,
            .winrt_device = winrt_dev,
            .item = item,
            .pool = pool,
            .session = session,
            .alloc = alloc,
            .borderless = borderless,
            .warp = warp,
            .default_min_interval = min_interval,
        };
    }

    pub fn deinit(self: *Capture) void {
        closeAndRelease(self.session);
        closeAndRelease(self.pool);
        release(self.item);
        if (self.staging) |t| release(t);
        release(self.winrt_device);
        release(self.context);
        release(self.device);
        if (self.row_buf.len > 0) self.alloc.free(self.row_buf);
    }

    /// The next frame DWM produced for the window, with one row of it read
    /// back at `row_frac` of its height, or null when none is waiting.
    pub fn next(self: *Capture, row_frac: f32) Error!?Frame {
        const t = try self.take() orelse return null;
        defer t.done();
        try self.ensureStaging(t.desc.width);

        const y: u32 = @min(t.desc.height -| 1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(t.desc.height)) * row_frac)));
        const box: D3D11_BOX = .{ .left = 0, .top = y, .front = 0, .right = t.desc.width, .bottom = y + 1, .back = 1 };
        // ID3D11DeviceContext slot 46: CopySubresourceRegion.
        const CopyRegion = *const fn (Obj, Obj, u32, u32, u32, u32, Obj, u32, *const D3D11_BOX) callconv(.winapi) void;
        slot(CopyRegion, self.context, 46)(self.context, self.staging.?, 0, 0, 0, 0, t.tex, 0, &box);

        const mapped = try self.map(self.staging.?);
        defer self.unmap(self.staging.?);
        const n = t.desc.width * 4;
        @memcpy(self.row_buf[0..n], (mapped.data orelse return error.ComFailed)[0..n]);
        return .{ .time_100ns = t.time, .row = self.row_buf[0..n], .width = t.desc.width };
    }

    /// The next frame DWM produced for the window, read back WHOLE (T2488):
    /// tightly packed BGRA rows, top row first, owned by the caller. Null when
    /// none is waiting. The texture WGC hands back is the window's composed
    /// picture top-down, so a caller can judge orientation directly from it.
    pub fn grab(self: *Capture, alloc: std.mem.Allocator) Error!?Image {
        const t = try self.take() orelse return null;
        defer t.done();
        const w = t.desc.width;
        const h = t.desc.height;
        if (w == 0 or h == 0) return error.ComFailed;

        const desc: D3D11_TEXTURE2D_DESC = .{
            .width = w,
            .height = h,
            .mip_levels = 1,
            .array_size = 1,
            .format = DXGI_FORMAT_B8G8R8A8_UNORM,
            .sample_count = 1,
            .sample_quality = 0,
            .usage = D3D11_USAGE_STAGING,
            .bind_flags = 0,
            .cpu_access_flags = D3D11_CPU_ACCESS_READ,
            .misc_flags = 0,
        };
        var out: ?Obj = null;
        const Create = *const fn (Obj, *const D3D11_TEXTURE2D_DESC, ?*const anyopaque, *?Obj) callconv(.winapi) HRESULT;
        try check(slot(Create, self.device, 5)(self.device, &desc, null, &out));
        const staging = out orelse return error.ComFailed;
        defer release(staging);

        const box: D3D11_BOX = .{ .left = 0, .top = 0, .front = 0, .right = w, .bottom = h, .back = 1 };
        const CopyRegion = *const fn (Obj, Obj, u32, u32, u32, u32, Obj, u32, *const D3D11_BOX) callconv(.winapi) void;
        slot(CopyRegion, self.context, 46)(self.context, staging, 0, 0, 0, 0, t.tex, 0, &box);

        const mapped = try self.map(staging);
        defer self.unmap(staging);
        const src = mapped.data orelse return error.ComFailed;
        const pixels = alloc.alloc(u8, @as(usize, w) * h * 4) catch return error.ComFailed;
        var y: usize = 0;
        while (y < h) : (y += 1) {
            @memcpy(pixels[y * w * 4 ..][0 .. w * 4], src[y * mapped.row_pitch ..][0 .. w * 4]);
        }
        return .{ .time_100ns = t.time, .width = w, .height = h, .pixels = pixels };
    }

    const Taken = struct {
        frame: Obj,
        tex: Obj,
        time: i64,
        desc: D3D11_TEXTURE2D_DESC,

        fn done(self: Taken) void {
            rt.release(self.tex);
            closeAndRelease(self.frame);
        }
    };

    /// TryGetNextFrame plus the D3D11 texture behind it; the caller releases.
    fn take(self: *Capture) Error!?Taken {
        // IDirect3D11CaptureFramePool slot 7: TryGetNextFrame.
        var f: ?Obj = null;
        const TryGet = *const fn (Obj, *?Obj) callconv(.winapi) HRESULT;
        try check(slot(TryGet, self.pool, 7)(self.pool, &f));
        const frame = f orelse return null;
        errdefer closeAndRelease(frame);

        // IDirect3D11CaptureFrame slot 7: get_SystemRelativeTime.
        var t: i64 = 0;
        const GetTime = *const fn (Obj, *i64) callconv(.winapi) HRESULT;
        try check(slot(GetTime, frame, 7)(frame, &t));

        // Slot 6: get_Surface, then the D3D11 texture behind it.
        var sf: ?Obj = null;
        const GetSurface = *const fn (Obj, *?Obj) callconv(.winapi) HRESULT;
        try check(slot(GetSurface, frame, 6)(frame, &sf));
        const surface = sf orelse return error.ComFailed;
        defer release(surface);
        const access = try query(surface, &IID_IDirect3DDxgiInterfaceAccess);
        defer release(access);
        var tx: ?Obj = null;
        const GetInterface = *const fn (Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT;
        try check(slot(GetInterface, access, 3)(access, &IID_ID3D11Texture2D, &tx));
        const tex = tx orelse return error.ComFailed;

        // ID3D11Texture2D slot 10: GetDesc.
        var desc: D3D11_TEXTURE2D_DESC = undefined;
        const GetDesc = *const fn (Obj, *D3D11_TEXTURE2D_DESC) callconv(.winapi) void;
        slot(GetDesc, tex, 10)(tex, &desc);
        return .{ .frame = frame, .tex = tex, .time = t, .desc = desc };
    }

    // ID3D11DeviceContext slot 14: Map; slot 15: Unmap.
    fn map(self: *Capture, res: Obj) Error!D3D11_MAPPED_SUBRESOURCE {
        var mapped: D3D11_MAPPED_SUBRESOURCE = undefined;
        const Map = *const fn (Obj, Obj, u32, u32, u32, *D3D11_MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT;
        try check(slot(Map, self.context, 14)(self.context, res, 0, D3D11_MAP_READ, 0, &mapped));
        return mapped;
    }

    fn unmap(self: *Capture, res: Obj) void {
        const Unmap = *const fn (Obj, Obj, u32) callconv(.winapi) void;
        slot(Unmap, self.context, 15)(self.context, res, 0);
    }

    fn ensureStaging(self: *Capture, width: u32) Error!void {
        if (self.staging != null and self.staging_w >= width) return;
        if (self.staging) |old| release(old);
        self.staging = null;
        if (self.row_buf.len > 0) self.alloc.free(self.row_buf);
        self.row_buf = self.alloc.alloc(u8, width * 4) catch return error.ComFailed;
        const desc: D3D11_TEXTURE2D_DESC = .{
            .width = width,
            .height = 1,
            .mip_levels = 1,
            .array_size = 1,
            .format = DXGI_FORMAT_B8G8R8A8_UNORM,
            .sample_count = 1,
            .sample_quality = 0,
            .usage = D3D11_USAGE_STAGING,
            .bind_flags = 0,
            .cpu_access_flags = D3D11_CPU_ACCESS_READ,
            .misc_flags = 0,
        };
        // ID3D11Device slot 5: CreateTexture2D.
        var out: ?Obj = null;
        const Create = *const fn (Obj, *const D3D11_TEXTURE2D_DESC, ?*const anyopaque, *?Obj) callconv(.winapi) HRESULT;
        try check(slot(Create, self.device, 5)(self.device, &desc, null, &out));
        self.staging = out orelse return error.ComFailed;
        self.staging_w = width;
    }
};

/// IClosable::Close (slot 6), then Release. WGC objects hold DWM resources
/// until closed, so a dropped reference alone is not enough.
fn closeAndRelease(obj: Obj) void {
    if (query(obj, &IID_IClosable)) |c| {
        const Close = *const fn (Obj) callconv(.winapi) HRESULT;
        _ = slot(Close, c, 6)(c);
        release(c);
    } else |_| {}
    release(obj);
}

/// Length of the first run of pixels matching `bgr` (within `tol` per
/// channel) in a BGRA row, scanning from the left; 0 when the colour is
/// absent. The spike's blade is the leftmost thing in the client area, so its
/// run length IS the blade's width, whatever the window chrome adds before it.
pub fn runLength(row: []const u8, bgr: [3]u8, tol: u8) u32 {
    var i: usize = 0;
    var start: ?usize = null;
    while (i + 3 < row.len) : (i += 4) {
        const hit = near(row[i], bgr[0], tol) and near(row[i + 1], bgr[1], tol) and near(row[i + 2], bgr[2], tol);
        if (hit) {
            if (start == null) start = i;
        } else if (start) |s| {
            return @intCast((i - s) / 4);
        }
    }
    return if (start) |s| @intCast((row.len - s) / 4) else 0;
}

fn near(a: u8, b: u8, tol: u8) bool {
    return @max(a, b) - @min(a, b) <= tol;
}

const testing = std.testing;

test "runLength measures the first matching run, past leading chrome" {
    const chrome = [_]u8{ 10, 10, 10, 255 };
    const blade = [_]u8{ 0xd8, 0x6c, 0x2b, 255 };
    const card = [_]u8{ 0x4a, 0x3f, 0x3a, 255 };
    const row = chrome ++ chrome ++ blade ++ blade ++ blade ++ card ++ blade;
    try testing.expectEqual(@as(u32, 3), runLength(&row, .{ 0xd8, 0x6c, 0x2b }, 8));
}

test "runLength tolerates small colour drift and reports 0 when absent" {
    const blade_ish = [_]u8{ 0xd4, 0x70, 0x2b, 255 };
    const row = blade_ish ++ blade_ish;
    try testing.expectEqual(@as(u32, 2), runLength(&row, .{ 0xd8, 0x6c, 0x2b }, 8));
    try testing.expectEqual(@as(u32, 0), runLength(&row, .{ 0x00, 0x00, 0xff }, 8));
}

test "a run reaching the end of the row counts to the end" {
    const blade = [_]u8{ 0xd8, 0x6c, 0x2b, 255 };
    const row = [_]u8{ 0, 0, 0, 255 } ++ blade ++ blade;
    try testing.expectEqual(@as(u32, 2), runLength(&row, .{ 0xd8, 0x6c, 0x2b }, 8));
}

test "Win32 struct layouts match d3d11.h" {
    try testing.expectEqual(@as(usize, 44), @sizeOf(D3D11_TEXTURE2D_DESC));
    try testing.expectEqual(@as(usize, 24), @sizeOf(D3D11_BOX));
    try testing.expectEqual(@as(usize, 16), @sizeOf(D3D11_MAPPED_SUBRESOURCE));
}
