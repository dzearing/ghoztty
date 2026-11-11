//! The feedback composer band's accessible object (T1468): an `IAccessible`
//! the band hands out from `WM_GETOBJECT`, so a screen reader can name — and
//! follow focus onto — the parts the band PAINTS rather than hosts as windows:
//! the two circular actions and each picture in the strip.
//!
//! ## Why MSAA and not a UI Automation provider
//!
//! Narrator, NVDA and JAWS all read an `IAccessible` — UI Automation wraps one
//! in its MSAA proxy and exposes it as an ordinary UIA element — and the
//! interface's whole surface is the twenty-one flat calls below, answered by
//! child id. A UIA fragment provider tree is the richer API, but every answer
//! this composer has to give (name, role, state, location, focus, the default
//! action) is expressible here, and a hand-built COM object is the part of
//! this that has to be right in someone else's process.
//!
//! ## What it answers, and what it hands on
//!
//! The pure half — which id is which part, and every name, role and state —
//! is `viewer_feedback_a11y.zig`. This file is the COM object and the window
//! questions: rectangles in screen coordinates, the band's child windows, the
//! Win32 focus. A child WINDOW (the web composer's text surface) is not
//! described here at all: it is handed out as its own object
//! (`AccessibleObjectFromWindow`), because Chromium already gives it a full
//! accessibility tree and a second, shallower description would only compete
//! with it.
//!
//! ## Lifetime
//!
//! A screen reader holds this object across processes for as long as it likes,
//! so it can outlive the band. The band therefore holds one reference and, on
//! destroy, `detach`es it: every call after that answers
//! `RPC_E_DISCONNECTED`, the COM answer for "the thing behind this is gone",
//! instead of reading a freed band.
//!
//! ## Nothing runs inside a call
//!
//! `accDoDefaultAction` and `accSelect` are requests that arrive over COM,
//! inside a message the band is already handling. Pressing send from there
//! would tear the web composer down under the very call that asked; so both
//! POST the request back to the band (`WM_APP_ACC_ACTION`) and return, and the
//! action runs from the message loop exactly as a click does.
const Accessible = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const com = @import("com.zig");
const a11y = @import("viewer_feedback_a11y.zig");
const layout_mod = @import("viewer_feedback_layout.zig");
const ViewerFeedbackBar = @import("ViewerFeedbackBar.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const BSTR = ?[*:0]u16;

const S_FALSE: HRESULT = 1;
const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x8007_0057));
const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x8000_4001));
const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007_000E));
const DISP_E_MEMBERNOTFOUND: HRESULT = @bitCast(@as(u32, 0x8002_0003));
const RPC_E_DISCONNECTED: HRESULT = @bitCast(@as(u32, 0x8001_0108));

pub const VT_EMPTY: u16 = 0;
pub const VT_I4: u16 = 3;
pub const VT_DISPATCH: u16 = 9;

/// `OBJID_WINDOW` / `OBJID_CLIENT` as the DWORD `AccessibleObjectFromWindow`
/// and `NotifyWinEvent` take.
const OBJID_WINDOW: u32 = 0;
pub const OBJID_CLIENT: i32 = -4;

pub const EVENT_OBJECT_FOCUS: u32 = 0x8005;
pub const EVENT_OBJECT_REORDER: u32 = 0x8004;
pub const EVENT_OBJECT_STATECHANGE: u32 = 0x800A;
pub const EVENT_OBJECT_SELECTION: u32 = 0x8006;

const SELFLAG_TAKEFOCUS: i32 = 0x1;

/// `NAVDIR_*` from oleacc.h. The four spatial directions are not answered.
const NAVDIR_NEXT: i32 = 5;
const NAVDIR_PREVIOUS: i32 = 6;
const NAVDIR_FIRSTCHILD: i32 = 7;
const NAVDIR_LASTCHILD: i32 = 8;

pub const IID_IAccessible: GUID = .{
    .Data1 = 0x618736E0,
    .Data2 = 0x3C3D,
    .Data3 = 0x11CF,
    .Data4 = .{ 0x81, 0x0C, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 },
};

pub const IID_IDispatch: GUID = .{
    .Data1 = 0x00020400,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

/// `VARIANT`: a type tag, three reserved words, then a union two pointers
/// wide (the `BRECORD` arm). 24 bytes on x64, 16 on x86.
pub const VARIANT = extern struct {
    vt: u16 = VT_EMPTY,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    data: extern union {
        lVal: i32,
        pdispVal: ?*anyopaque,
        raw: [2]usize,
    } = .{ .raw = .{ 0, 0 } },
};

comptime {
    std.debug.assert(@sizeOf(VARIANT) == 8 + 2 * @sizeOf(usize));
}

extern "oleacc" fn LresultFromObject(riid: *const GUID, wParam: usize, punk: *anyopaque) callconv(.winapi) isize;
extern "oleacc" fn AccessibleObjectFromWindow(
    hwnd: w32.HWND,
    dwId: u32,
    riid: *const GUID,
    ppvObject: *?*anyopaque,
) callconv(.winapi) HRESULT;
extern "oleaut32" fn SysAllocStringLen(s: ?[*]const u16, len: u32) callconv(.winapi) BSTR;
extern "user32" fn NotifyWinEvent(event: u32, hwnd: w32.HWND, idObject: i32, idChild: i32) callconv(.winapi) void;

/// Tell any listening screen reader that something about the band changed.
/// Free when nobody is listening, which is the normal case.
pub fn notify(event: u32, hwnd: w32.HWND, child: i32) void {
    NotifyWinEvent(event, hwnd, OBJID_CLIENT, child);
}

// ---------------------------------------------------------------------------
// The object
// ---------------------------------------------------------------------------

/// Must stay first: it is the only part of the object COM dereferences.
vtable: *const Vtbl,
refs: i32,
/// Null once the band is gone (`detach`).
bar: ?*ViewerFeedbackBar,
alloc_ptr: *anyopaque,
alloc_vtable: *const Allocator.VTable,

// A VARIANT passed BY VALUE is, on both Windows ABIs this builds for, passed as
// a pointer to the caller's copy once it is wider than 8 bytes — which it
// always is — so the slots spell it as the pointer the ABI actually passes
// rather than trusting a by-value aggregate to be lowered the same way.
const V = *const VARIANT;

const Vtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*Accessible, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*Accessible) callconv(.winapi) u32,
    Release: *const fn (*Accessible) callconv(.winapi) u32,
    // IDispatch
    GetTypeInfoCount: *const fn (*Accessible, *u32) callconv(.winapi) HRESULT,
    GetTypeInfo: *const fn (*Accessible, u32, u32, *?*anyopaque) callconv(.winapi) HRESULT,
    GetIDsOfNames: *const fn (*Accessible, *const GUID, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) HRESULT,
    Invoke: *const fn (*Accessible, i32, *const GUID, u32, u16, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*u32) callconv(.winapi) HRESULT,
    // IAccessible
    get_accParent: *const fn (*Accessible, *?*anyopaque) callconv(.winapi) HRESULT,
    get_accChildCount: *const fn (*Accessible, *i32) callconv(.winapi) HRESULT,
    get_accChild: *const fn (*Accessible, V, *?*anyopaque) callconv(.winapi) HRESULT,
    get_accName: *const fn (*Accessible, V, *BSTR) callconv(.winapi) HRESULT,
    get_accValue: *const fn (*Accessible, V, *BSTR) callconv(.winapi) HRESULT,
    get_accDescription: *const fn (*Accessible, V, *BSTR) callconv(.winapi) HRESULT,
    get_accRole: *const fn (*Accessible, V, *VARIANT) callconv(.winapi) HRESULT,
    get_accState: *const fn (*Accessible, V, *VARIANT) callconv(.winapi) HRESULT,
    get_accHelp: *const fn (*Accessible, V, *BSTR) callconv(.winapi) HRESULT,
    get_accHelpTopic: *const fn (*Accessible, *BSTR, V, *i32) callconv(.winapi) HRESULT,
    get_accKeyboardShortcut: *const fn (*Accessible, V, *BSTR) callconv(.winapi) HRESULT,
    get_accFocus: *const fn (*Accessible, *VARIANT) callconv(.winapi) HRESULT,
    get_accSelection: *const fn (*Accessible, *VARIANT) callconv(.winapi) HRESULT,
    get_accDefaultAction: *const fn (*Accessible, V, *BSTR) callconv(.winapi) HRESULT,
    accSelect: *const fn (*Accessible, i32, V) callconv(.winapi) HRESULT,
    accLocation: *const fn (*Accessible, *i32, *i32, *i32, *i32, V) callconv(.winapi) HRESULT,
    accNavigate: *const fn (*Accessible, i32, V, *VARIANT) callconv(.winapi) HRESULT,
    accHitTest: *const fn (*Accessible, i32, i32, *VARIANT) callconv(.winapi) HRESULT,
    accDoDefaultAction: *const fn (*Accessible, V) callconv(.winapi) HRESULT,
    put_accName: *const fn (*Accessible, V, BSTR) callconv(.winapi) HRESULT,
    put_accValue: *const fn (*Accessible, V, BSTR) callconv(.winapi) HRESULT,
};

const vtable_impl: Vtbl = .{
    .QueryInterface = queryInterface,
    .AddRef = addRef,
    .Release = release,
    .GetTypeInfoCount = getTypeInfoCount,
    .GetTypeInfo = getTypeInfo,
    .GetIDsOfNames = getIDsOfNames,
    .Invoke = invoke,
    .get_accParent = getParent,
    .get_accChildCount = getChildCount,
    .get_accChild = getChild,
    .get_accName = getName,
    .get_accValue = getValue,
    .get_accDescription = getDescription,
    .get_accRole = getRole,
    .get_accState = getState,
    .get_accHelp = getHelp,
    .get_accHelpTopic = getHelpTopic,
    .get_accKeyboardShortcut = getKeyboardShortcut,
    .get_accFocus = getFocus,
    .get_accSelection = getSelection,
    .get_accDefaultAction = getDefaultAction,
    .accSelect = select,
    .accLocation = location,
    .accNavigate = navigate,
    .accHitTest = hitTest,
    .accDoDefaultAction = doDefaultAction,
    .put_accName = putName,
    .put_accValue = putValue,
};

/// Born with one reference: the band's.
pub fn create(alloc: Allocator, bar: *ViewerFeedbackBar) Allocator.Error!*Accessible {
    const self = try alloc.create(Accessible);
    self.* = .{
        .vtable = &vtable_impl,
        .refs = 1,
        .bar = bar,
        .alloc_ptr = alloc.ptr,
        .alloc_vtable = alloc.vtable,
    };
    return self;
}

/// The band is going away: answer `RPC_E_DISCONNECTED` from now on, then drop
/// the band's reference. A reader still holding the object keeps it alive
/// harmlessly until it lets go.
pub fn detach(self: *Accessible) void {
    self.bar = null;
    _ = release(self);
}

/// `WM_GETOBJECT`'s answer: this object marshalled for whoever asked.
pub fn lresult(self: *Accessible, wparam: usize) isize {
    return LresultFromObject(&IID_IAccessible, wparam, @ptrCast(self));
}

fn queryInterface(self: *Accessible, riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (com.guidEql(riid, &com.IID_IUnknown) or
        com.guidEql(riid, &IID_IDispatch) or
        com.guidEql(riid, &IID_IAccessible))
    {
        _ = addRef(self);
        out.* = @ptrCast(self);
        return com.S_OK;
    }
    out.* = null;
    return com.E_NOINTERFACE;
}

fn addRef(self: *Accessible) callconv(.winapi) u32 {
    const prev = @atomicRmw(i32, &self.refs, .Add, 1, .monotonic);
    return @intCast(prev + 1);
}

fn release(self: *Accessible) callconv(.winapi) u32 {
    const prev = @atomicRmw(i32, &self.refs, .Sub, 1, .acq_rel);
    const now = prev - 1;
    if (now == 0) {
        const alloc: Allocator = .{ .ptr = self.alloc_ptr, .vtable = self.alloc_vtable };
        alloc.destroy(self);
    }
    return @intCast(@max(now, 0));
}

// IDispatch: answered as "no type information". Every MSAA client calls the
// vtable; late binding by name is not a route any screen reader takes.
fn getTypeInfoCount(_: *Accessible, n: *u32) callconv(.winapi) HRESULT {
    n.* = 0;
    return com.S_OK;
}
fn getTypeInfo(_: *Accessible, _: u32, _: u32, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    return E_NOTIMPL;
}
fn getIDsOfNames(_: *Accessible, _: *const GUID, _: ?*anyopaque, _: u32, _: u32, _: ?*anyopaque) callconv(.winapi) HRESULT {
    return E_NOTIMPL;
}
fn invoke(_: *Accessible, _: i32, _: *const GUID, _: u32, _: u16, _: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: ?*u32) callconv(.winapi) HRESULT {
    return E_NOTIMPL;
}

// ---------------------------------------------------------------------------
// What the band looks like right now
// ---------------------------------------------------------------------------

/// Up to this many child windows are described. The band has one (the web
/// composer's host); the cap only bounds a stack array.
const max_windows = 8;

/// One call's view of the band: everything the answers are computed from,
/// read once so the parts of one answer cannot disagree with each other.
const View = struct {
    bar: *ViewerFeedbackBar,
    shape: a11y.Shape,
    windows: [max_windows]w32.HWND,
    layout: layout_mod.Layout,

    fn of(bar: *ViewerFeedbackBar) View {
        var v: View = .{
            .bar = bar,
            .shape = .{ .windows = 0, .tiles = bar.images },
            .windows = undefined,
            .layout = bar.currentLayout(),
        };
        // The band's VISIBLE child windows, in z order — the web composer's
        // host while the composer is open. The tooltip is an owned popup, not
        // a child, so it is never among them.
        var c = w32.GetWindow(bar.hwnd, w32.GW_CHILD);
        while (c) |h| : (c = w32.GetWindow(h, w32.GW_HWNDNEXT)) {
            if (w32.IsWindowVisible(h) == 0) continue;
            if (v.shape.windows == max_windows) break;
            v.windows[v.shape.windows] = h;
            v.shape.windows += 1;
        }
        return v;
    }

    fn item(v: *const View, child: V) ?a11y.Item {
        if (child.vt != VT_I4) return null;
        return v.shape.itemOf(child.data.lVal);
    }

    /// The part holding keyboard focus inside the band, if the band has it.
    fn focused(v: *const View) ?a11y.Item {
        return a11y.focusedItem(
            w32.GetFocus() == v.bar.hwnd,
            v.bar.key_focus,
            v.bar.carousel_focus,
        );
    }

    fn stateOf(v: *const View, it: a11y.Item) u32 {
        var drawn: [layout_mod.button_count]bool = undefined;
        var enabled: [layout_mod.button_count]bool = undefined;
        for (std.enums.values(layout_mod.Button)) |b| {
            const i = @intFromEnum(b);
            drawn[i] = v.layout.button(b).width() > 0;
            enabled[i] = v.bar.buttonEnabled(b);
        }
        var s = a11y.state(it, .{
            .enabled = enabled,
            .drawn = drawn,
            .focused = v.focused(),
            .selected_tile = v.bar.carousel_selected,
            .tile_offscreen = switch (it) {
                .tile => |i| v.tileClientRect(i).isEmpty(),
                else => false,
            },
        });
        if (it == .self) {
            if (w32.IsWindowVisible(v.bar.hwnd) == 0) s |= a11y.state_invisible;
            s |= a11y.state_focusable;
        }
        return s;
    }

    /// Tile `i`'s visible part in the band's client coordinates — clipped to
    /// the strip's viewport, empty when it is scrolled wholly out of it.
    fn tileClientRect(v: *const View, i: usize) layout_mod.Rect {
        const t = v.layout.thumbAt(i, v.bar.carousel_scroll);
        const c = v.layout.carousel;
        const r: layout_mod.Rect = .{
            .left = @max(t.left, c.left),
            .top = @max(t.top, c.top),
            .right = @min(t.right, c.right),
            .bottom = @min(t.bottom, c.bottom),
        };
        if (r.right <= r.left or r.bottom <= r.top) return .{};
        return r;
    }

    /// A child window's own accessible object, as the `IDispatch` the
    /// interface hands children out as.
    fn windowObject(v: *const View, i: usize) ?*anyopaque {
        if (i >= v.shape.windows) return null;
        var out: ?*anyopaque = null;
        if (com.failed(AccessibleObjectFromWindow(v.windows[i], OBJID_WINDOW, &IID_IDispatch, &out))) return null;
        return out;
    }

    /// Put a child id into `out` the way MSAA wants it back: a simple
    /// element as its id, a child window as its object.
    fn answer(v: *const View, id: i32, out: *VARIANT) HRESULT {
        out.* = .{};
        const it = v.shape.itemOf(id) orelse return S_FALSE;
        switch (it) {
            .window => |i| {
                const obj = v.windowObject(i) orelse return S_FALSE;
                out.vt = VT_DISPATCH;
                out.data = .{ .pdispVal = obj };
            },
            else => {
                out.vt = VT_I4;
                out.data = .{ .lVal = id };
            },
        }
        return com.S_OK;
    }
};

/// The part child id `id` names on `bar` right now — how the band resolves a
/// posted request against its CURRENT children.
pub fn itemFor(bar: *ViewerFeedbackBar, id: i32) ?a11y.Item {
    return View.of(bar).shape.itemOf(id);
}

/// The child id `item` has on `bar` right now.
pub fn idFor(bar: *ViewerFeedbackBar, item: a11y.Item) i32 {
    return View.of(bar).shape.idOf(item);
}

fn view(self: *Accessible) ?View {
    const bar = self.bar orelse return null;
    return View.of(bar);
}

fn bstr(text: []const u8, out: *BSTR) HRESULT {
    var buf: [256]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return E_INVALIDARG;
    out.* = SysAllocStringLen(&buf, @intCast(n)) orelse return E_OUTOFMEMORY;
    return com.S_OK;
}

fn none(out: *BSTR) HRESULT {
    out.* = null;
    return S_FALSE;
}

// ---------------------------------------------------------------------------
// IAccessible
// ---------------------------------------------------------------------------

fn getParent(self: *Accessible, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    const bar = self.bar orelse return RPC_E_DISCONNECTED;
    // The band's WINDOW object is its parent in the MSAA tree: the client
    // area lives inside the window's frame, and the frame knows the band's
    // parent window.
    return AccessibleObjectFromWindow(bar.hwnd, OBJID_WINDOW, &IID_IDispatch, out);
}

fn getChildCount(self: *Accessible, out: *i32) callconv(.winapi) HRESULT {
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    out.* = @intCast(v.shape.count());
    return com.S_OK;
}

fn getChild(self: *Accessible, child: V, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    const it = v.item(child) orelse return E_INVALIDARG;
    switch (it) {
        .self => return E_INVALIDARG,
        .window => |i| {
            out.* = v.windowObject(i) orelse return S_FALSE;
            return com.S_OK;
        },
        // A painted part has no object of its own: S_FALSE tells the caller
        // to ask THIS object about it by id.
        .tile, .button => return S_FALSE,
    }
}

fn getName(self: *Accessible, child: V, out: *BSTR) callconv(.winapi) HRESULT {
    out.* = null;
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    const it = v.item(child) orelse return E_INVALIDARG;
    var buf: [64]u8 = undefined;
    return switch (it) {
        .self => bstr(a11y.self_name, out),
        .button => |b| bstr(a11y.buttonName(b), out),
        .tile => |i| bstr(a11y.tileName(&buf, v.bar.accTileNumber(i) orelse @intCast(i + 1)), out),
        .window => E_INVALIDARG,
    };
}

fn getValue(self: *Accessible, _: V, out: *BSTR) callconv(.winapi) HRESULT {
    out.* = null;
    if (self.bar == null) return RPC_E_DISCONNECTED;
    return DISP_E_MEMBERNOTFOUND;
}

fn getDescription(self: *Accessible, child: V, out: *BSTR) callconv(.winapi) HRESULT {
    out.* = null;
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    const it = v.item(child) orelse return E_INVALIDARG;
    var buf: [64]u8 = undefined;
    return switch (it) {
        .tile => |i| bstr(a11y.tileDescription(&buf, i, v.shape.tiles), out),
        .window => E_INVALIDARG,
        else => none(out),
    };
}

fn getRole(self: *Accessible, child: V, out: *VARIANT) callconv(.winapi) HRESULT {
    out.* = .{};
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    const it = v.item(child) orelse return E_INVALIDARG;
    const r = a11y.role(it) orelse return E_INVALIDARG;
    out.vt = VT_I4;
    out.data = .{ .lVal = @bitCast(r) };
    return com.S_OK;
}

fn getState(self: *Accessible, child: V, out: *VARIANT) callconv(.winapi) HRESULT {
    out.* = .{};
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    const it = v.item(child) orelse return E_INVALIDARG;
    if (it == .window) return E_INVALIDARG;
    out.vt = VT_I4;
    out.data = .{ .lVal = @bitCast(v.stateOf(it)) };
    return com.S_OK;
}

fn getHelp(self: *Accessible, _: V, out: *BSTR) callconv(.winapi) HRESULT {
    if (self.bar == null) {
        out.* = null;
        return RPC_E_DISCONNECTED;
    }
    return none(out);
}

fn getHelpTopic(self: *Accessible, file: *BSTR, _: V, topic: *i32) callconv(.winapi) HRESULT {
    file.* = null;
    topic.* = 0;
    if (self.bar == null) return RPC_E_DISCONNECTED;
    return DISP_E_MEMBERNOTFOUND;
}

fn getKeyboardShortcut(self: *Accessible, child: V, out: *BSTR) callconv(.winapi) HRESULT {
    out.* = null;
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    const it = v.item(child) orelse return E_INVALIDARG;
    return switch (it) {
        .button => |b| bstr(a11y.shortcut(b), out),
        .window => E_INVALIDARG,
        else => none(out),
    };
}

fn getFocus(self: *Accessible, out: *VARIANT) callconv(.winapi) HRESULT {
    out.* = .{};
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    if (v.focused()) |it| return v.answer(v.shape.idOf(it), out);
    // Focus is inside one of the band's child windows — the text surface,
    // several Chromium windows down. Answer with that child's object.
    const f = w32.GetFocus() orelse return S_FALSE;
    for (v.windows[0..v.shape.windows], 0..) |h, i| {
        if (f == h or w32.IsChild(h, f) != 0) return v.answer(v.shape.idOf(.{ .window = i }), out);
    }
    return S_FALSE;
}

fn getSelection(self: *Accessible, out: *VARIANT) callconv(.winapi) HRESULT {
    out.* = .{};
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    const i = v.bar.carousel_selected orelse return S_FALSE;
    if (i >= v.shape.tiles) return S_FALSE;
    return v.answer(v.shape.idOf(.{ .tile = i }), out);
}

fn getDefaultAction(self: *Accessible, child: V, out: *BSTR) callconv(.winapi) HRESULT {
    out.* = null;
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    const it = v.item(child) orelse return E_INVALIDARG;
    if (it == .window) return E_INVALIDARG;
    const text = a11y.defaultAction(it) orelse return none(out);
    return bstr(text, out);
}

fn select(self: *Accessible, flags: i32, child: V) callconv(.winapi) HRESULT {
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    const it = v.item(child) orelse return E_INVALIDARG;
    if (flags & SELFLAG_TAKEFOCUS == 0) return DISP_E_MEMBERNOTFOUND;
    switch (it) {
        .tile, .button => {
            v.bar.postAccAction(.focus, v.shape.idOf(it));
            return com.S_OK;
        },
        else => return DISP_E_MEMBERNOTFOUND,
    }
}

fn location(self: *Accessible, x: *i32, y: *i32, cx: *i32, cy: *i32, child: V) callconv(.winapi) HRESULT {
    x.* = 0;
    y.* = 0;
    cx.* = 0;
    cy.* = 0;
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    const it = v.item(child) orelse return E_INVALIDARG;
    const r: layout_mod.Rect = switch (it) {
        .self => {
            var wr: w32.RECT = undefined;
            if (w32.GetWindowRect(v.bar.hwnd, &wr) == 0) return S_FALSE;
            x.* = wr.left;
            y.* = wr.top;
            cx.* = wr.right - wr.left;
            cy.* = wr.bottom - wr.top;
            return com.S_OK;
        },
        .window => return E_INVALIDARG,
        .button => |b| v.layout.button(b),
        // A tile scrolled out of view reports where it WOULD be — with the
        // offscreen state saying so — rather than nothing at all.
        .tile => |i| blk: {
            const vis = v.tileClientRect(i);
            break :blk if (vis.isEmpty()) v.layout.thumbAt(i, v.bar.carousel_scroll) else vis;
        },
    };
    var pt: w32.POINT = .{ .x = r.left, .y = r.top };
    _ = w32.ClientToScreen(v.bar.hwnd, &pt);
    x.* = pt.x;
    y.* = pt.y;
    cx.* = r.width();
    cy.* = r.bottom - r.top;
    return com.S_OK;
}

fn navigate(self: *Accessible, dir: i32, start: V, out: *VARIANT) callconv(.winapi) HRESULT {
    out.* = .{};
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    if (start.vt != VT_I4) return E_INVALIDARG;
    const nav: a11y.Nav = switch (dir) {
        NAVDIR_NEXT => .next,
        NAVDIR_PREVIOUS => .previous,
        NAVDIR_FIRSTCHILD => .first_child,
        NAVDIR_LASTCHILD => .last_child,
        else => return DISP_E_MEMBERNOTFOUND,
    };
    const id = v.shape.navigate(start.data.lVal, nav) orelse return S_FALSE;
    return v.answer(id, out);
}

fn hitTest(self: *Accessible, sx: i32, sy: i32, out: *VARIANT) callconv(.winapi) HRESULT {
    out.* = .{};
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    var wr: w32.RECT = undefined;
    if (w32.GetWindowRect(v.bar.hwnd, &wr) == 0) return S_FALSE;
    if (sx < wr.left or sx >= wr.right or sy < wr.top or sy >= wr.bottom) return S_FALSE;
    for (v.windows[0..v.shape.windows], 0..) |h, i| {
        var cr: w32.RECT = undefined;
        if (w32.GetWindowRect(h, &cr) == 0) continue;
        if (sx >= cr.left and sx < cr.right and sy >= cr.top and sy < cr.bottom) {
            return v.answer(v.shape.idOf(.{ .window = i }), out);
        }
    }
    var pt: w32.POINT = .{ .x = sx, .y = sy };
    _ = w32.ScreenToClient(v.bar.hwnd, &pt);
    const id: i32 = if (v.layout.hitButton(v.bar.scale, pt.x, pt.y)) |b|
        v.shape.idOf(.{ .button = b })
    else if (v.layout.hitThumb(v.bar.carousel_scroll, pt.x, pt.y)) |i|
        v.shape.idOf(.{ .tile = i })
    else
        0;
    out.vt = VT_I4;
    out.data = .{ .lVal = id };
    return com.S_OK;
}

fn doDefaultAction(self: *Accessible, child: V) callconv(.winapi) HRESULT {
    const v = view(self) orelse return RPC_E_DISCONNECTED;
    const it = v.item(child) orelse return E_INVALIDARG;
    switch (it) {
        .button => |b| if (!v.bar.buttonEnabled(b)) return DISP_E_MEMBERNOTFOUND,
        .tile => {},
        else => return DISP_E_MEMBERNOTFOUND,
    }
    v.bar.postAccAction(.press, v.shape.idOf(it));
    return com.S_OK;
}

fn putName(self: *Accessible, _: V, _: BSTR) callconv(.winapi) HRESULT {
    if (self.bar == null) return RPC_E_DISCONNECTED;
    return DISP_E_MEMBERNOTFOUND;
}

fn putValue(self: *Accessible, _: V, _: BSTR) callconv(.winapi) HRESULT {
    if (self.bar == null) return RPC_E_DISCONNECTED;
    return DISP_E_MEMBERNOTFOUND;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "viewer feedback acc: the vtable is IAccessible's 28 slots in order" {
    // 3 IUnknown + 4 IDispatch + 21 IAccessible. A slot out of place is a call
    // to the wrong function from another process, so the count and the two
    // ends are pinned.
    try std.testing.expectEqual(@as(usize, 28 * @sizeOf(usize)), @sizeOf(Vtbl));
    try std.testing.expectEqual(@as(usize, 7 * @sizeOf(usize)), @offsetOf(Vtbl, "get_accParent"));
    try std.testing.expectEqual(@as(usize, 27 * @sizeOf(usize)), @offsetOf(Vtbl, "put_accValue"));
}

test "viewer feedback acc: VARIANT is the platform's size" {
    try std.testing.expectEqual(@as(usize, 8 + 2 * @sizeOf(usize)), @sizeOf(VARIANT));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(VARIANT, "data"));
}

test "viewer feedback acc: a detached object refuses every call and frees on last release" {
    var obj = try create(std.testing.allocator, undefined);
    obj.bar = null;
    _ = addRef(obj); // a reader's reference
    detach(obj); // the band's goes
    var n: i32 = -1;
    try std.testing.expectEqual(RPC_E_DISCONNECTED, getChildCount(obj, &n));
    var name: BSTR = null;
    const self_id: VARIANT = .{ .vt = VT_I4, .data = .{ .lVal = 0 } };
    try std.testing.expectEqual(RPC_E_DISCONNECTED, getName(obj, &self_id, &name));
    try std.testing.expectEqual(@as(BSTR, null), name);
    // The reader lets go; the testing allocator fails the test on a leak.
    try std.testing.expectEqual(@as(u32, 0), release(obj));
}

test "viewer feedback acc: answers for IAccessible, IDispatch and IUnknown only" {
    const obj = try create(std.testing.allocator, undefined);
    defer _ = release(obj);
    obj.bar = null;
    var out: ?*anyopaque = null;
    try std.testing.expectEqual(com.S_OK, queryInterface(obj, &IID_IAccessible, &out));
    _ = release(obj);
    try std.testing.expectEqual(com.S_OK, queryInterface(obj, &IID_IDispatch, &out));
    _ = release(obj);
    const other: GUID = .{ .Data1 = 1, .Data2 = 2, .Data3 = 3, .Data4 = .{ 0, 0, 0, 0, 0, 0, 0, 0 } };
    try std.testing.expectEqual(com.E_NOINTERFACE, queryInterface(obj, &other, &out));
    try std.testing.expectEqual(@as(?*anyopaque, null), out);
}
