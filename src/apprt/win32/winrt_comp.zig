//! Windows.UI.Composition from Zig, as raw COM/WinRT vtable calls (T2360).
//!
//! The Visual Layer is the Windows counterpart of Mac's CoreAnimation: the
//! compositor (DWM) runs keyframe animations on its own clock at the display's
//! refresh, so a stall on our UI thread does not drop a frame of a glide that
//! has already been declared. It is hosted in a plain Win32 window through
//! `ICompositorDesktopInterop::CreateDesktopWindowTarget`; no XAML, no WinUI.
//!
//! Every slot index below was checked against
//! `Windows Kits\10\Include\10.0.22621.0\winrt\windows.ui.composition.h`
//! (the C vtable structs) and `windows.ui.composition.interop.h`. IInspectable
//! takes slots 0-5 (QueryInterface, AddRef, Release, GetIids,
//! GetRuntimeClassName, GetTrustLevel), so an interface's first own method is
//! slot 6. A wrong slot is a call into a different method with a different
//! signature, so a new method gets its slot from the header, never by counting.
//!
//! The runtime entry points (`RoInitialize`, `RoActivateInstance`, the HSTRING
//! calls, `CreateDispatcherQueueController`) are loaded with `GetProcAddress`
//! rather than linked, so a machine without them (pre-1803, a stripped image)
//! reports `error.Unavailable` and the caller falls back instead of failing to
//! start. That is the fallback chain T2360 requires.
const std = @import("std");

pub const GUID = std.os.windows.GUID;
pub const HRESULT = std.os.windows.HRESULT;
pub const HWND = std.os.windows.HWND;
pub const HSTRING = ?*anyopaque;
/// Any COM interface pointer; its first word is the vtable pointer.
pub const Obj = *anyopaque;

pub const Vector2 = extern struct { x: f32, y: f32 };
pub const Vector3 = extern struct { x: f32, y: f32, z: f32 };
/// Windows.UI.Color: A, R, G, B bytes in that order.
pub const Color = extern struct { a: u8, r: u8, g: u8, b: u8 };
/// Windows.Foundation.TimeSpan, in 100 ns ticks.
pub const TimeSpan = i64;

pub fn ms(v: u32) TimeSpan {
    return @as(i64, v) * 10_000;
}

pub fn failed(hr: HRESULT) bool {
    return hr < 0;
}

fn guid(comptime s: []const u8) GUID {
    return GUID.parse("{" ++ s ++ "}");
}

pub const IID_ICompositor = guid("b403ca50-7f8c-4e83-985f-cc45060036d8");
pub const IID_IVisual = guid("117e202d-a859-4c89-873b-c2aa566788e3");
pub const IID_IContainerVisual = guid("02f6bc74-ed20-4773-afe6-d49b4a93db32");
pub const IID_ISpriteVisual = guid("08e05581-1ad1-4f97-9757-402d76e4233b");
pub const IID_ICompositionObject = guid("bcb4ad45-7609-4550-934f-16002a68fded");
pub const IID_ICompositionTarget = guid("a1bea8ba-d726-4663-8129-6b5e7927ffa6");
pub const IID_ICompositionBrush = guid("ab0d7608-30c0-40e9-b568-b60a6bd1fb46");
pub const IID_ICompositionEasingFunction = guid("5145e356-bf79-4ea8-8cc2-6b5b472e6c9a");
pub const IID_ICompositionAnimation = guid("464c4c2c-1caa-4061-9b40-e13fde1503ca");
pub const IID_IKeyFrameAnimation = guid("126e7f22-3ae9-4540-9a8a-deae8a4a4a84");
pub const IID_IVector2KeyFrameAnimation = guid("df414515-4e29-4f11-b55e-bf2a6eb36294");
pub const IID_IVector3KeyFrameAnimation = guid("c8039daa-a281-43c2-a73d-b68e3c533c40");
pub const IID_ICompositorDesktopInterop = guid("29e691fa-4567-4dca-b319-d0f207eb6807");

pub const Error = error{ Unavailable, ComFailed };

/// The HRESULT of the last failed call on this thread, for the report.
pub threadlocal var last_hr: HRESULT = 0;

fn check(hr: HRESULT) Error!void {
    if (failed(hr)) {
        last_hr = hr;
        return error.ComFailed;
    }
}

fn slot(comptime F: type, obj: Obj, index: usize) F {
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(vtbl.*[index]);
}

// ---- IUnknown -------------------------------------------------------------

pub fn query(obj: Obj, iid: *const GUID) Error!Obj {
    const F = *const fn (Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT;
    var out: ?Obj = null;
    try check(slot(F, obj, 0)(obj, iid, &out));
    return out orelse error.ComFailed;
}

pub fn release(obj: Obj) void {
    const F = *const fn (Obj) callconv(.winapi) u32;
    _ = slot(F, obj, 2)(obj);
}

/// Call an `HRESULT method(this, out**)` at `index` and return the result.
fn getObj(obj: Obj, index: usize) Error!Obj {
    const F = *const fn (Obj, *?Obj) callconv(.winapi) HRESULT;
    var out: ?Obj = null;
    try check(slot(F, obj, index)(obj, &out));
    return out orelse error.ComFailed;
}

// ---- runtime entry points -------------------------------------------------

const Runtime = struct {
    ro_initialize: *const fn (u32) callconv(.winapi) HRESULT,
    ro_activate: *const fn (HSTRING, *?Obj) callconv(.winapi) HRESULT,
    create_string: *const fn ([*]const u16, u32, *HSTRING) callconv(.winapi) HRESULT,
    delete_string: *const fn (HSTRING) callconv(.winapi) HRESULT,
    create_dq: *const fn (DispatcherQueueOptions, *?Obj) callconv(.winapi) HRESULT,
};

pub const DispatcherQueueOptions = extern struct {
    dwSize: u32 = @sizeOf(DispatcherQueueOptions),
    threadType: u32 = 2, // DQTYPE_THREAD_CURRENT
    apartmentType: u32 = 2, // DQTAT_COM_STA
};

extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;

var runtime: ?Runtime = null;

fn sym(comptime T: type, lib: *anyopaque, name: [*:0]const u8) Error!T {
    return @ptrCast(GetProcAddress(lib, name) orelse return error.Unavailable);
}

fn loadRuntime() Error!*const Runtime {
    if (runtime) |*r| return r;
    const combase = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("combase.dll")) orelse
        return error.Unavailable;
    const coremsg = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("CoreMessaging.dll")) orelse
        return error.Unavailable;
    runtime = .{
        .ro_initialize = try sym(@FieldType(Runtime, "ro_initialize"), combase, "RoInitialize"),
        .ro_activate = try sym(@FieldType(Runtime, "ro_activate"), combase, "RoActivateInstance"),
        .create_string = try sym(@FieldType(Runtime, "create_string"), combase, "WindowsCreateString"),
        .delete_string = try sym(@FieldType(Runtime, "delete_string"), combase, "WindowsDeleteString"),
        .create_dq = try sym(@FieldType(Runtime, "create_dq"), coremsg, "CreateDispatcherQueueController"),
    };
    return &runtime.?;
}

pub const HString = struct {
    h: HSTRING,

    pub fn init(comptime s: []const u8) Error!HString {
        const r = try loadRuntime();
        const w = std.unicode.utf8ToUtf16LeStringLiteral(s);
        var h: HSTRING = null;
        try check(r.create_string(w, @intCast(w.len), &h));
        return .{ .h = h };
    }

    pub fn deinit(self: HString) void {
        if (runtime) |r| _ = r.delete_string(self.h);
    }
};

/// Prepare THIS thread to own a Compositor: a single-threaded WinRT apartment
/// and a DispatcherQueue bound to the thread. The thread must pump messages
/// for the queue. Returns the DispatcherQueueController (keep it alive).
pub fn initThread() Error!Obj {
    const r = try loadRuntime();
    const hr = r.ro_initialize(0); // RO_INIT_SINGLETHREADED
    // S_FALSE (already initialised) and RPC_E_CHANGED_MODE are both usable.
    if (failed(hr) and hr != @as(HRESULT, @bitCast(@as(u32, 0x80010106)))) try check(hr);
    var dq: ?Obj = null;
    try check(r.create_dq(.{}, &dq));
    return dq orelse error.ComFailed;
}

// ---- Compositor -----------------------------------------------------------

pub const Compositor = struct {
    obj: Obj,

    pub fn create() Error!Compositor {
        const r = try loadRuntime();
        const name = try HString.init("Windows.UI.Composition.Compositor");
        defer name.deinit();
        var insp: ?Obj = null;
        try check(r.ro_activate(name.h, &insp));
        const i = insp orelse return error.ComFailed;
        defer release(i);
        return .{ .obj = try query(i, &IID_ICompositor) };
    }

    pub fn deinit(self: Compositor) void {
        release(self.obj);
    }

    /// ICompositorDesktopInterop::CreateDesktopWindowTarget, then the
    /// ICompositionTarget view of it (which carries `put_Root`).
    pub fn createTarget(self: Compositor, hwnd: HWND, topmost: bool) Error!Obj {
        const interop = try query(self.obj, &IID_ICompositorDesktopInterop);
        defer release(interop);
        const F = *const fn (Obj, HWND, i32, *?Obj) callconv(.winapi) HRESULT;
        var dwt: ?Obj = null;
        try check(slot(F, interop, 3)(interop, hwnd, @intFromBool(topmost), &dwt));
        const t = dwt orelse return error.ComFailed;
        defer release(t);
        return query(t, &IID_ICompositionTarget);
    }

    /// ICompositor slot 9.
    pub fn createContainerVisual(self: Compositor) Error!Obj {
        return getObj(self.obj, 9);
    }

    /// ICompositor slot 22.
    pub fn createSpriteVisual(self: Compositor) Error!Obj {
        return getObj(self.obj, 22);
    }

    /// ICompositor slot 8 (CreateColorBrushWithColor), as an ICompositionBrush.
    pub fn createColorBrush(self: Compositor, c: Color) Error!Obj {
        const F = *const fn (Obj, Color, *?Obj) callconv(.winapi) HRESULT;
        var out: ?Obj = null;
        try check(slot(F, self.obj, 8)(self.obj, c, &out));
        const b = out orelse return error.ComFailed;
        defer release(b);
        return query(b, &IID_ICompositionBrush);
    }

    /// ICompositor slot 10, as an ICompositionEasingFunction.
    pub fn createCubicBezier(self: Compositor, p1: Vector2, p2: Vector2) Error!Obj {
        const F = *const fn (Obj, Vector2, Vector2, *?Obj) callconv(.winapi) HRESULT;
        var out: ?Obj = null;
        try check(slot(F, self.obj, 10)(self.obj, p1, p2, &out));
        const e = out orelse return error.ComFailed;
        defer release(e);
        return query(e, &IID_ICompositionEasingFunction);
    }

    /// ICompositor slot 26 (CreateVector2KeyFrameAnimation).
    pub fn createVector2Animation(self: Compositor) Error!Obj {
        return getObj(self.obj, 26);
    }

    /// ICompositor slot 27 (CreateVector3KeyFrameAnimation).
    pub fn createVector3Animation(self: Compositor) Error!Obj {
        return getObj(self.obj, 27);
    }
};

/// ICompositionTarget slot 7.
pub fn targetSetRoot(target: Obj, visual: Obj) Error!void {
    const iv = try query(visual, &IID_IVisual);
    defer release(iv);
    const F = *const fn (Obj, Obj) callconv(.winapi) HRESULT;
    try check(slot(F, target, 7)(target, iv));
}

/// IContainerVisual slot 6 (get_Children), then IVisualCollection slot 9
/// (InsertAtTop).
pub fn containerAppend(container: Obj, child: Obj) Error!void {
    const cv = try query(container, &IID_IContainerVisual);
    defer release(cv);
    const children = try getObj(cv, 6);
    defer release(children);
    const iv = try query(child, &IID_IVisual);
    defer release(iv);
    const F = *const fn (Obj, Obj) callconv(.winapi) HRESULT;
    try check(slot(F, children, 9)(children, iv));
}

/// ISpriteVisual slot 7 (put_Brush).
pub fn spriteSetBrush(sprite: Obj, brush: Obj) Error!void {
    const F = *const fn (Obj, Obj) callconv(.winapi) HRESULT;
    try check(slot(F, sprite, 7)(sprite, brush));
}

/// IVisual slot 21 (put_Offset).
pub fn visualSetOffset(visual: Obj, v: Vector3) Error!void {
    const iv = try query(visual, &IID_IVisual);
    defer release(iv);
    const F = *const fn (Obj, Vector3) callconv(.winapi) HRESULT;
    try check(slot(F, iv, 21)(iv, v));
}

/// IVisual slot 36 (put_Size).
pub fn visualSetSize(visual: Obj, v: Vector2) Error!void {
    const iv = try query(visual, &IID_IVisual);
    defer release(iv);
    const F = *const fn (Obj, Vector2) callconv(.winapi) HRESULT;
    try check(slot(F, iv, 36)(iv, v));
}

/// IKeyFrameAnimation slot 9 (put_Duration).
pub fn animationSetDuration(anim: Obj, d: TimeSpan) Error!void {
    const kf = try query(anim, &IID_IKeyFrameAnimation);
    defer release(kf);
    const F = *const fn (Obj, TimeSpan) callconv(.winapi) HRESULT;
    try check(slot(F, kf, 9)(kf, d));
}

/// IVector2KeyFrameAnimation slot 7 (InsertKeyFrameWithEasingFunction).
pub fn vector2InsertKey(anim: Obj, progress: f32, v: Vector2, easing: Obj) Error!void {
    const F = *const fn (Obj, f32, Vector2, Obj) callconv(.winapi) HRESULT;
    try check(slot(F, anim, 7)(anim, progress, v, easing));
}

/// IVector3KeyFrameAnimation slot 7 (InsertKeyFrameWithEasingFunction).
pub fn vector3InsertKey(anim: Obj, progress: f32, v: Vector3, easing: Obj) Error!void {
    const F = *const fn (Obj, f32, Vector3, Obj) callconv(.winapi) HRESULT;
    try check(slot(F, anim, 7)(anim, progress, v, easing));
}

/// ICompositionObject slot 9 (StartAnimation) on `visual`'s `property`.
pub fn startAnimation(visual: Obj, comptime property: []const u8, anim: Obj) Error!void {
    const co = try query(visual, &IID_ICompositionObject);
    defer release(co);
    const ca = try query(anim, &IID_ICompositionAnimation);
    defer release(ca);
    const name = try HString.init(property);
    defer name.deinit();
    const F = *const fn (Obj, HSTRING, Obj) callconv(.winapi) HRESULT;
    try check(slot(F, co, 9)(co, name.h, ca));
}

test "TimeSpan ticks" {
    try std.testing.expectEqual(@as(i64, 3_000_000), ms(300));
}

test "IID parse round-trips the header's spelling" {
    try std.testing.expectEqual(@as(u32, 0xb403ca50), IID_ICompositor.Data1);
    try std.testing.expectEqual(@as(u16, 0x4567), IID_ICompositorDesktopInterop.Data2);
}

test "struct layouts match the WinRT ABI" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Vector2));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Vector3));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Color));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(DispatcherQueueOptions));
}
