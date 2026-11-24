//! The window's UI Automation provider (T2122): what Narrator, NVDA and JAWS
//! find for a tucked pane's strip - a button named `Tucked pane: <name>`,
//! help `Brings the pane forward`, whose Invoke brings the pane forward the
//! way a click on the strip does (Mac `PaneStackTabView`).
//!
//! ## Why UI Automation, and only for the window's root
//!
//! The strips are pixels the top-level window paints, so the window has to
//! describe them itself. Its MSAA client object is deliberately NOT answered
//! (`Window.zig`'s `WM_GETOBJECT`, T48: oleacc's default proxy, torn down
//! inside a focus change, re-entered the window procedure and deadlocked), and
//! this provider leaves that opt-out alone: it answers only `UiaRootObjectId`,
//! which is a separate question UI Automation asks, and builds no oleacc proxy.
//! The window's own properties (its name, its frame, its child windows) still
//! come from the HWND host provider UIA lays under this one
//! (`get_HostRawElementProvider`); this object adds the strips as children.
//!
//! The pure half - names, reading order, navigation, hit test, runtime ids -
//! is `strip_uia.zig`.
//!
//! ## Objects
//!
//! `Root` is the fragment root, one per window, made on the first ask and held
//! by the window. `Strip` is one fragment per strip, made fresh whenever a
//! client navigates to one and identified by its pane - UIA tells elements
//! apart by runtime id, not by object, so a fresh object per walk is enough.
//! Strips come and go with every layout, so a `Strip` never caches where it
//! is: each call asks the window for the strips on show now and finds its pane
//! among them (compared by address, never dereferenced), and a strip that is
//! no longer there answers `UIA_E_ELEMENTNOTAVAILABLE`.
//!
//! ## Lifetime and threading
//!
//! A client holds these objects across processes for as long as it likes, so
//! they outlive the window: on destroy the window `detach`es the root, after
//! which every call on it or any strip answers `UIA_E_ELEMENTNOTAVAILABLE`.
//! UIA calls a server-side provider on the thread that owns its window (no
//! `ProviderOptions_UseComThreading`), so no call here races the window.
//!
//! ## Nothing runs inside a call
//!
//! `Invoke` arrives over COM inside a message the window is already handling.
//! It posts the request back (`Window.WM_APP_STRIP_INVOKE`) and returns, and
//! the pane is brought forward from the message loop exactly as a click is.
const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const com = @import("com.zig");
const strip_uia = @import("strip_uia.zig");
const Window = @import("Window.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const BSTR = ?[*:0]u16;

const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007_000E));
const UIA_E_ELEMENTNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x8004_0201));

/// `WM_GETOBJECT`'s lParam for UIA's question (UIAutomationCore.h).
pub const UiaRootObjectId: i32 = -25;

const ProviderOptions_ServerSideProvider: i32 = 0x1;
const UiaAppendRuntimeId: i32 = 3;

const UIA_InvokePatternId: i32 = 10000;
const UIA_ButtonControlTypeId: i32 = 50000;
const UIA_ControlTypePropertyId: i32 = 30003;
const UIA_NamePropertyId: i32 = 30005;
const UIA_IsKeyboardFocusablePropertyId: i32 = 30009;
const UIA_IsEnabledPropertyId: i32 = 30010;
const UIA_AutomationIdPropertyId: i32 = 30011;
const UIA_ClassNamePropertyId: i32 = 30012;
const UIA_HelpTextPropertyId: i32 = 30013;
const UIA_IsInvokePatternAvailablePropertyId: i32 = 30031;

const VT_EMPTY: u16 = 0;
const VT_I4: u16 = 3;
const VT_BSTR: u16 = 8;
const VT_BOOL: u16 = 11;

/// The strips a call looks at. The window shows far fewer; a strip past this
/// many is not described (and is a stack nobody could read anyway).
const MAX_STRIPS = 64;

/// The `AutomationId` / `ClassName` a test or a script can find a strip by.
const automation_id = "TuckedPaneStrip";
const class_name = "GhozttyTuckedPaneStrip";

const IID_IRawElementProviderSimple: GUID = .{ .Data1 = 0xd6dd68d1, .Data2 = 0x86fd, .Data3 = 0x4332, .Data4 = .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c } };
const IID_IRawElementProviderFragment: GUID = .{ .Data1 = 0xf7063da8, .Data2 = 0x8359, .Data3 = 0x439c, .Data4 = .{ 0x92, 0x97, 0xbb, 0xc5, 0x29, 0x9a, 0x7d, 0x87 } };
const IID_IRawElementProviderFragmentRoot: GUID = .{ .Data1 = 0x620ce2a5, .Data2 = 0xab8f, .Data3 = 0x40a9, .Data4 = .{ 0x86, 0xcb, 0xde, 0x3c, 0x75, 0x59, 0x9b, 0x58 } };
const IID_IInvokeProvider: GUID = .{ .Data1 = 0x54fcb24b, .Data2 = 0xe18e, .Data3 = 0x47a2, .Data4 = .{ 0xb4, 0xd3, 0xec, 0xcb, 0xe7, 0x75, 0x99, 0xa2 } };

/// `VARIANT`, as `viewer_feedback_acc` spells it: a tag, three reserved words,
/// a union two pointers wide.
const VARIANT = extern struct {
    vt: u16 = VT_EMPTY,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    data: extern union {
        lVal: i32,
        boolVal: i16,
        bstrVal: BSTR,
        raw: [2]usize,
    } = .{ .raw = .{ 0, 0 } },
};

comptime {
    std.debug.assert(@sizeOf(VARIANT) == 8 + 2 * @sizeOf(usize));
}

const UiaRect = extern struct { left: f64, top: f64, width: f64, height: f64 };

/// `SAFEARRAY*`, opaque: only made here, and handed to UIA, which frees it.
const SAFEARRAY = opaque {};

extern "uiautomationcore" fn UiaReturnRawElementProvider(hwnd: w32.HWND, wParam: usize, lParam: isize, el: ?*anyopaque) callconv(.winapi) isize;
extern "uiautomationcore" fn UiaHostProviderFromHwnd(hwnd: w32.HWND, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "uiautomationcore" fn UiaDisconnectProvider(el: *anyopaque) callconv(.winapi) HRESULT;
extern "oleaut32" fn SysAllocStringLen(s: ?[*]const u16, len: u32) callconv(.winapi) BSTR;
extern "oleaut32" fn SafeArrayCreateVector(vt: u16, lLbound: i32, cElements: u32) callconv(.winapi) ?*SAFEARRAY;
extern "oleaut32" fn SafeArrayPutElement(psa: *SAFEARRAY, rgIndices: *const i32, pv: *const anyopaque) callconv(.winapi) HRESULT;
extern "oleaut32" fn SafeArrayDestroy(psa: *SAFEARRAY) callconv(.winapi) HRESULT;

// ---------------------------------------------------------------------------
// Vtables. Each object carries one vtable pointer per interface; a call on
// interface pointer `p` finds its object with @fieldParentPtr on that field.
// ---------------------------------------------------------------------------

const P = *anyopaque;

const SimpleVtbl = extern struct {
    QueryInterface: *const fn (P, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (P) callconv(.winapi) u32,
    Release: *const fn (P) callconv(.winapi) u32,
    get_ProviderOptions: *const fn (P, *i32) callconv(.winapi) HRESULT,
    GetPatternProvider: *const fn (P, i32, *?*anyopaque) callconv(.winapi) HRESULT,
    GetPropertyValue: *const fn (P, i32, *VARIANT) callconv(.winapi) HRESULT,
    get_HostRawElementProvider: *const fn (P, *?*anyopaque) callconv(.winapi) HRESULT,
};

const FragmentVtbl = extern struct {
    QueryInterface: *const fn (P, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (P) callconv(.winapi) u32,
    Release: *const fn (P) callconv(.winapi) u32,
    Navigate: *const fn (P, i32, *?*anyopaque) callconv(.winapi) HRESULT,
    GetRuntimeId: *const fn (P, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    get_BoundingRectangle: *const fn (P, *UiaRect) callconv(.winapi) HRESULT,
    GetEmbeddedFragmentRoots: *const fn (P, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    SetFocus: *const fn (P) callconv(.winapi) HRESULT,
    get_FragmentRoot: *const fn (P, *?*anyopaque) callconv(.winapi) HRESULT,
};

const FragmentRootVtbl = extern struct {
    QueryInterface: *const fn (P, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (P) callconv(.winapi) u32,
    Release: *const fn (P) callconv(.winapi) u32,
    ElementProviderFromPoint: *const fn (P, f64, f64, *?*anyopaque) callconv(.winapi) HRESULT,
    GetFocus: *const fn (P, *?*anyopaque) callconv(.winapi) HRESULT,
};

const InvokeVtbl = extern struct {
    QueryInterface: *const fn (P, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (P) callconv(.winapi) u32,
    Release: *const fn (P) callconv(.winapi) u32,
    Invoke: *const fn (P) callconv(.winapi) HRESULT,
};

/// IUnknown and the object behind interface field `field` of `T`.
fn Thunks(comptime T: type, comptime field: []const u8) type {
    return struct {
        fn obj(p: P) *T {
            const fp: *@FieldType(T, field) = @ptrCast(@alignCast(p));
            return @fieldParentPtr(field, fp);
        }
        fn qi(p: P, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return obj(p).queryInterface(riid, out);
        }
        fn addRef(p: P) callconv(.winapi) u32 {
            return obj(p).addRef();
        }
        fn release(p: P) callconv(.winapi) u32 {
            return obj(p).release();
        }
    };
}

/// Shared by both objects: refcount and the allocator that frees them.
fn RefCounted(comptime T: type) type {
    return struct {
        fn addRef(self: *T) u32 {
            const prev = @atomicRmw(i32, &self.refs, .Add, 1, .monotonic);
            return @intCast(prev + 1);
        }
        fn release(self: *T) u32 {
            const prev = @atomicRmw(i32, &self.refs, .Sub, 1, .acq_rel);
            const now = prev - 1;
            if (now == 0) self.destroy();
            return @intCast(@max(now, 0));
        }
    };
}

fn putBstr(out: *VARIANT, s: []const u8) HRESULT {
    var wide: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, s[0..@min(s.len, wide.len)]) catch 0;
    const b = SysAllocStringLen(&wide, @intCast(n)) orelse return E_OUTOFMEMORY;
    out.* = .{ .vt = VT_BSTR, .data = .{ .bstrVal = b } };
    return com.S_OK;
}

fn putBool(out: *VARIANT, v: bool) void {
    out.* = .{ .vt = VT_BOOL, .data = .{ .boolVal = if (v) -1 else 0 } };
}

fn putI4(out: *VARIANT, v: i32) void {
    out.* = .{ .vt = VT_I4, .data = .{ .lVal = v } };
}

// ---------------------------------------------------------------------------
// Root: the window's fragment root.
// ---------------------------------------------------------------------------

pub const Root = struct {
    simple: *const SimpleVtbl,
    fragment: *const FragmentVtbl,
    froot: *const FragmentRootVtbl,
    refs: i32,
    /// Null once the window is gone (`detach`).
    window: ?*Window,
    hwnd: w32.HWND,
    alloc: Allocator,

    const S = Thunks(Root, "simple");
    const F = Thunks(Root, "fragment");
    const R = Thunks(Root, "froot");
    const rc = RefCounted(Root);

    const simple_vtbl: SimpleVtbl = .{
        .QueryInterface = S.qi,
        .AddRef = S.addRef,
        .Release = S.release,
        .get_ProviderOptions = struct {
            fn f(_: P, out: *i32) callconv(.winapi) HRESULT {
                out.* = ProviderOptions_ServerSideProvider;
                return com.S_OK;
            }
        }.f,
        .GetPatternProvider = struct {
            fn f(_: P, _: i32, out: *?*anyopaque) callconv(.winapi) HRESULT {
                out.* = null;
                return com.S_OK;
            }
        }.f,
        // Every property of the window itself comes from the HWND host
        // provider; an empty answer here lets it.
        .GetPropertyValue = struct {
            fn f(_: P, _: i32, out: *VARIANT) callconv(.winapi) HRESULT {
                out.* = .{};
                return com.S_OK;
            }
        }.f,
        .get_HostRawElementProvider = struct {
            fn f(p: P, out: *?*anyopaque) callconv(.winapi) HRESULT {
                const self = S.obj(p);
                out.* = null;
                if (self.window == null) return UIA_E_ELEMENTNOTAVAILABLE;
                return UiaHostProviderFromHwnd(self.hwnd, out);
            }
        }.f,
    };

    const fragment_vtbl: FragmentVtbl = .{
        .QueryInterface = F.qi,
        .AddRef = F.addRef,
        .Release = F.release,
        .Navigate = struct {
            fn f(p: P, dir: i32, out: *?*anyopaque) callconv(.winapi) HRESULT {
                return F.obj(p).navigateFrom(null, dir, out);
            }
        }.f,
        // The host provider supplies the window's runtime id and rectangle.
        .GetRuntimeId = struct {
            fn f(_: P, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
                out.* = null;
                return com.S_OK;
            }
        }.f,
        .get_BoundingRectangle = struct {
            fn f(_: P, out: *UiaRect) callconv(.winapi) HRESULT {
                out.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
                return com.S_OK;
            }
        }.f,
        .GetEmbeddedFragmentRoots = struct {
            fn f(_: P, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
                out.* = null;
                return com.S_OK;
            }
        }.f,
        .SetFocus = struct {
            fn f(_: P) callconv(.winapi) HRESULT {
                return com.S_OK;
            }
        }.f,
        .get_FragmentRoot = struct {
            fn f(p: P, out: *?*anyopaque) callconv(.winapi) HRESULT {
                const self = F.obj(p);
                _ = self.addRef();
                out.* = @ptrCast(&self.froot);
                return com.S_OK;
            }
        }.f,
    };

    const froot_vtbl: FragmentRootVtbl = .{
        .QueryInterface = R.qi,
        .AddRef = R.addRef,
        .Release = R.release,
        .ElementProviderFromPoint = struct {
            fn f(p: P, x: f64, y: f64, out: *?*anyopaque) callconv(.winapi) HRESULT {
                return R.obj(p).fromPoint(x, y, out);
            }
        }.f,
        // Keyboard focus is always in a pane's own window, never on a strip.
        .GetFocus = struct {
            fn f(_: P, out: *?*anyopaque) callconv(.winapi) HRESULT {
                out.* = null;
                return com.S_OK;
            }
        }.f,
    };

    /// Born with one reference: the window's.
    pub fn create(alloc: Allocator, window: *Window, hwnd: w32.HWND) Allocator.Error!*Root {
        const self = try alloc.create(Root);
        self.* = .{
            .simple = &simple_vtbl,
            .fragment = &fragment_vtbl,
            .froot = &froot_vtbl,
            .refs = 1,
            .window = window,
            .hwnd = hwnd,
            .alloc = alloc,
        };
        return self;
    }

    /// `WM_GETOBJECT(UiaRootObjectId)`'s answer.
    pub fn lresult(self: *Root, wparam: usize, lparam: isize) isize {
        return UiaReturnRawElementProvider(self.hwnd, wparam, lparam, @ptrCast(&self.simple));
    }

    /// The window is going away: tell UIA to drop what clients hold, answer
    /// `UIA_E_ELEMENTNOTAVAILABLE` from now on, and drop the window's
    /// reference. Called from `WM_DESTROY`, while the HWND is still valid.
    pub fn detach(self: *Root) void {
        _ = UiaReturnRawElementProvider(self.hwnd, 0, 0, null);
        self.window = null;
        _ = UiaDisconnectProvider(@ptrCast(&self.simple));
        _ = self.release();
    }

    fn destroy(self: *Root) void {
        self.alloc.destroy(self);
    }

    fn addRef(self: *Root) u32 {
        return rc.addRef(self);
    }
    fn release(self: *Root) u32 {
        return rc.release(self);
    }

    fn queryInterface(self: *Root, riid: *const GUID, out: *?*anyopaque) HRESULT {
        out.* = if (com.guidEql(riid, &com.IID_IUnknown) or com.guidEql(riid, &IID_IRawElementProviderSimple))
            @ptrCast(&self.simple)
        else if (com.guidEql(riid, &IID_IRawElementProviderFragment))
            @ptrCast(&self.fragment)
        else if (com.guidEql(riid, &IID_IRawElementProviderFragmentRoot))
            @ptrCast(&self.froot)
        else
            null;
        if (out.* == null) return com.E_NOINTERFACE;
        _ = self.addRef();
        return com.S_OK;
    }

    /// The strips on show now, in reading order.
    fn strips(self: *Root, buf: []Window.UiaStrip) ?[]Window.UiaStrip {
        const w = self.window orelse return null;
        return buf[0..w.uiaStrips(buf)];
    }

    /// A step from strip `from_view` (null: from the root) in direction `dir`.
    fn navigateFrom(self: *Root, from_view: ?usize, dir: i32, out: *?*anyopaque) HRESULT {
        out.* = null;
        var buf: [MAX_STRIPS]Window.UiaStrip = undefined;
        const list = self.strips(&buf) orelse return UIA_E_ELEMENTNOTAVAILABLE;
        const d: strip_uia.NavigateDirection = @enumFromInt(dir);
        const from: ?usize = if (from_view) |v| (indexOf(list, v) orelse return UIA_E_ELEMENTNOTAVAILABLE) else null;
        if (from != null and d == .parent) {
            _ = self.addRef();
            out.* = @ptrCast(&self.fragment);
            return com.S_OK;
        }
        const to = strip_uia.navigate(list.len, from, d) orelse return com.S_OK;
        const s = Strip.create(self, list[to].view_addr) catch return E_OUTOFMEMORY;
        out.* = @ptrCast(&s.fragment);
        return com.S_OK;
    }

    fn fromPoint(self: *Root, x: f64, y: f64, out: *?*anyopaque) HRESULT {
        out.* = null;
        var buf: [MAX_STRIPS]Window.UiaStrip = undefined;
        const list = self.strips(&buf) orelse return UIA_E_ELEMENTNOTAVAILABLE;
        var rects: [MAX_STRIPS]strip_uia.Rect = undefined;
        var paint: [MAX_STRIPS]usize = undefined;
        for (list, 0..) |s, i| {
            rects[i] = s.rect;
            paint[i] = s.paint;
        }
        const hit = strip_uia.hitTest(rects[0..list.len], paint[0..list.len], @intFromFloat(@floor(x)), @intFromFloat(@floor(y))) orelse return com.S_OK;
        const s = Strip.create(self, list[hit].view_addr) catch return E_OUTOFMEMORY;
        out.* = @ptrCast(&s.fragment);
        return com.S_OK;
    }
};

fn indexOf(list: []const Window.UiaStrip, view_addr: usize) ?usize {
    for (list, 0..) |s, i| if (s.view_addr == view_addr) return i;
    return null;
}

// ---------------------------------------------------------------------------
// Strip: one tucked pane's strip.
// ---------------------------------------------------------------------------

const Strip = struct {
    simple: *const SimpleVtbl,
    fragment: *const FragmentVtbl,
    invoke: *const InvokeVtbl,
    refs: i32,
    /// Holds a reference: a strip asks its root for the window.
    root: *Root,
    /// The pane, by address: compared against the strips on show, never
    /// dereferenced here.
    view_addr: usize,

    const S = Thunks(Strip, "simple");
    const F = Thunks(Strip, "fragment");
    const I = Thunks(Strip, "invoke");
    const rc = RefCounted(Strip);

    const simple_vtbl: SimpleVtbl = .{
        .QueryInterface = S.qi,
        .AddRef = S.addRef,
        .Release = S.release,
        .get_ProviderOptions = struct {
            fn f(_: P, out: *i32) callconv(.winapi) HRESULT {
                out.* = ProviderOptions_ServerSideProvider;
                return com.S_OK;
            }
        }.f,
        .GetPatternProvider = struct {
            fn f(p: P, pattern: i32, out: *?*anyopaque) callconv(.winapi) HRESULT {
                const self = S.obj(p);
                out.* = null;
                if (pattern != UIA_InvokePatternId) return com.S_OK;
                _ = self.addRef();
                out.* = @ptrCast(&self.invoke);
                return com.S_OK;
            }
        }.f,
        .GetPropertyValue = struct {
            fn f(p: P, prop: i32, out: *VARIANT) callconv(.winapi) HRESULT {
                return S.obj(p).property(prop, out);
            }
        }.f,
        // A strip lives inside the window's root; it has no window of its own.
        .get_HostRawElementProvider = struct {
            fn f(_: P, out: *?*anyopaque) callconv(.winapi) HRESULT {
                out.* = null;
                return com.S_OK;
            }
        }.f,
    };

    const fragment_vtbl: FragmentVtbl = .{
        .QueryInterface = F.qi,
        .AddRef = F.addRef,
        .Release = F.release,
        .Navigate = struct {
            fn f(p: P, dir: i32, out: *?*anyopaque) callconv(.winapi) HRESULT {
                const self = F.obj(p);
                return self.root.navigateFrom(self.view_addr, dir, out);
            }
        }.f,
        .GetRuntimeId = struct {
            fn f(p: P, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
                const self = F.obj(p);
                out.* = null;
                const sa = SafeArrayCreateVector(VT_I4, 0, 2) orelse return E_OUTOFMEMORY;
                const parts = [2]i32{ UiaAppendRuntimeId, strip_uia.runtimeIdPart(self.view_addr) };
                for (parts, 0..) |v, i| {
                    const idx: i32 = @intCast(i);
                    if (com.failed(SafeArrayPutElement(sa, &idx, &v))) {
                        _ = SafeArrayDestroy(sa);
                        return E_OUTOFMEMORY;
                    }
                }
                out.* = sa;
                return com.S_OK;
            }
        }.f,
        .get_BoundingRectangle = struct {
            fn f(p: P, out: *UiaRect) callconv(.winapi) HRESULT {
                const self = F.obj(p);
                out.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
                const s = self.current() orelse return UIA_E_ELEMENTNOTAVAILABLE;
                out.* = .{
                    .left = @floatFromInt(s.rect.left),
                    .top = @floatFromInt(s.rect.top),
                    .width = @floatFromInt(s.rect.right - s.rect.left),
                    .height = @floatFromInt(s.rect.bottom - s.rect.top),
                };
                return com.S_OK;
            }
        }.f,
        .GetEmbeddedFragmentRoots = struct {
            fn f(_: P, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
                out.* = null;
                return com.S_OK;
            }
        }.f,
        // Not keyboard-focusable (Mac's strip is not in the key-view loop
        // either); a reader moves to it, and Invoke is how it acts.
        .SetFocus = struct {
            fn f(_: P) callconv(.winapi) HRESULT {
                return com.S_OK;
            }
        }.f,
        .get_FragmentRoot = struct {
            fn f(p: P, out: *?*anyopaque) callconv(.winapi) HRESULT {
                const self = F.obj(p);
                _ = self.root.addRef();
                out.* = @ptrCast(&self.root.froot);
                return com.S_OK;
            }
        }.f,
    };

    const invoke_vtbl: InvokeVtbl = .{
        .QueryInterface = I.qi,
        .AddRef = I.addRef,
        .Release = I.release,
        .Invoke = struct {
            fn f(p: P) callconv(.winapi) HRESULT {
                const self = I.obj(p);
                const w = self.root.window orelse return UIA_E_ELEMENTNOTAVAILABLE;
                if (self.current() == null) return UIA_E_ELEMENTNOTAVAILABLE;
                if (!w.uiaInvokeStrip(self.view_addr)) return UIA_E_ELEMENTNOTAVAILABLE;
                return com.S_OK;
            }
        }.f,
    };

    /// Born with one reference: the caller's out-parameter's.
    fn create(root: *Root, view_addr: usize) Allocator.Error!*Strip {
        const self = try root.alloc.create(Strip);
        _ = root.addRef();
        self.* = .{
            .simple = &simple_vtbl,
            .fragment = &fragment_vtbl,
            .invoke = &invoke_vtbl,
            .refs = 1,
            .root = root,
            .view_addr = view_addr,
        };
        return self;
    }

    fn destroy(self: *Strip) void {
        const root = self.root;
        root.alloc.destroy(self);
        _ = root.release();
    }

    fn addRef(self: *Strip) u32 {
        return rc.addRef(self);
    }
    fn release(self: *Strip) u32 {
        return rc.release(self);
    }

    fn queryInterface(self: *Strip, riid: *const GUID, out: *?*anyopaque) HRESULT {
        out.* = if (com.guidEql(riid, &com.IID_IUnknown) or com.guidEql(riid, &IID_IRawElementProviderSimple))
            @ptrCast(&self.simple)
        else if (com.guidEql(riid, &IID_IRawElementProviderFragment))
            @ptrCast(&self.fragment)
        else if (com.guidEql(riid, &IID_IInvokeProvider))
            @ptrCast(&self.invoke)
        else
            null;
        if (out.* == null) return com.E_NOINTERFACE;
        _ = self.addRef();
        return com.S_OK;
    }

    /// This strip as the window shows it now, or null when it is gone.
    fn current(self: *Strip) ?Window.UiaStrip {
        var buf: [MAX_STRIPS]Window.UiaStrip = undefined;
        const list = self.root.strips(&buf) orelse return null;
        const i = indexOf(list, self.view_addr) orelse return null;
        return list[i];
    }

    fn property(self: *Strip, prop: i32, out: *VARIANT) HRESULT {
        out.* = .{};
        const w = self.root.window orelse return UIA_E_ELEMENTNOTAVAILABLE;
        switch (prop) {
            UIA_NamePropertyId => {
                var label_buf: [512]u8 = undefined;
                const label = w.uiaStripLabel(self.view_addr, &label_buf) orelse return UIA_E_ELEMENTNOTAVAILABLE;
                var name_buf: [512]u8 = undefined;
                return putBstr(out, strip_uia.name(label, &name_buf));
            },
            UIA_HelpTextPropertyId => return putBstr(out, strip_uia.help_text),
            UIA_ControlTypePropertyId => putI4(out, UIA_ButtonControlTypeId),
            UIA_AutomationIdPropertyId => return putBstr(out, automation_id),
            UIA_ClassNamePropertyId => return putBstr(out, class_name),
            UIA_IsKeyboardFocusablePropertyId => putBool(out, false),
            UIA_IsEnabledPropertyId => putBool(out, true),
            UIA_IsInvokePatternAvailablePropertyId => putBool(out, true),
            else => {},
        }
        return com.S_OK;
    }
};
