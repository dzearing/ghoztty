//! The WebView2 SUBFRAME interfaces we call, hand-declared (T928).
//!
//! Split out of `webview2_iface.zig` rather than appended to it: that file is
//! the top-level view's contract and already the size a module should stop
//! at, and everything here is one feature — reaching the iframes of a page, so
//! a right-click on a link inside one gets the same menu as a link outside it.
//!
//! The derivation rules are that file's, unchanged: every vtable was
//! transcribed from the `MIDL_INTERFACE` C vtable structs in `WebView2.h`
//! (`Microsoft.Web.WebView2` 1.0.3485.44), whose `DECLSPEC_XFGVIRT` lines name
//! the contributing interface per slot; slots we do not call are opaque, so
//! they cannot be called by mistake; a later revision is reached by
//! `QueryInterface`, never by assuming trailing slots; and the slot each named
//! method sits in is asserted with `@offsetOf` at the bottom.
//!
//! Why frames need their own plumbing at all: WebView2 delivers a subframe's
//! `window.chrome.webview.postMessage` to that frame's
//! `ICoreWebView2Frame2::add_WebMessageReceived`, never to the web view's. So
//! the host has to be told each frame exists (`ICoreWebView2_4::FrameCreated`
//! for the page's own iframes, `ICoreWebView2Frame7::FrameCreated` for an
//! iframe inside an iframe) and subscribe to each one.
const std = @import("std");
const com = @import("com.zig");
const iface = @import("webview2_iface.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const BOOL = iface.BOOL;
const EventRegistrationToken = iface.EventRegistrationToken;

// ------------------------------------------------------------------- IIDs

// {20D02D59-6DF2-42DC-BD06-F98A694B1302}
pub const IID_ICoreWebView2_4: GUID = .{
    .Data1 = 0x20D02D59,
    .Data2 = 0x6DF2,
    .Data3 = 0x42DC,
    .Data4 = .{ 0xBD, 0x06, 0xF9, 0x8A, 0x69, 0x4B, 0x13, 0x02 },
};

// {7A6A5834-D185-4DBF-B63F-4A9BC43107D4}
pub const IID_ICoreWebView2Frame2: GUID = .{
    .Data1 = 0x7A6A5834,
    .Data2 = 0xD185,
    .Data3 = 0x4DBF,
    .Data4 = .{ 0xB6, 0x3F, 0x4A, 0x9B, 0xC4, 0x31, 0x07, 0xD4 },
};

// {3598CFA2-D85D-5A9F-9228-4DDE1F59EC64}
pub const IID_ICoreWebView2Frame7: GUID = .{
    .Data1 = 0x3598CFA2,
    .Data2 = 0xD85D,
    .Data3 = 0x5A9F,
    .Data4 = .{ 0x92, 0x28, 0x4D, 0xDE, 0x1F, 0x59, 0xEC, 0x64 },
};

// {38059770-9BAA-11EB-A8B3-0242AC130003}
/// `ICoreWebView2FrameCreatedEventHandler` — the web view's: an iframe of the
/// top-level page. `Invoke(ICoreWebView2 *sender, ICoreWebView2FrameCreatedEventArgs *args)`.
pub const IID_FrameCreatedHandler: GUID = .{
    .Data1 = 0x38059770,
    .Data2 = 0x9BAA,
    .Data3 = 0x11EB,
    .Data4 = .{ 0xA8, 0xB3, 0x02, 0x42, 0xAC, 0x13, 0x00, 0x03 },
};

// {569E40E7-46B7-563D-83AE-1073155664D7}
/// `ICoreWebView2FrameChildFrameCreatedEventHandler` — a frame's: an iframe
/// inside that frame. Same args as the web view's, but the sender is the
/// parent FRAME. `Invoke(ICoreWebView2Frame *sender, ICoreWebView2FrameCreatedEventArgs *args)`.
pub const IID_FrameChildFrameCreatedHandler: GUID = .{
    .Data1 = 0x569E40E7,
    .Data2 = 0x46B7,
    .Data3 = 0x563D,
    .Data4 = .{ 0x83, 0xAE, 0x10, 0x73, 0x15, 0x56, 0x64, 0xD7 },
};

// {E371E005-6D1D-4517-934B-A8F1629C62A5}
/// `ICoreWebView2FrameWebMessageReceivedEventHandler`. The args are the SAME
/// `ICoreWebView2WebMessageReceivedEventArgs` the web view's event carries, so
/// the payload decodes exactly the way a main-frame message does.
/// `Invoke(ICoreWebView2Frame *sender, ICoreWebView2WebMessageReceivedEventArgs *args)`.
pub const IID_FrameWebMessageReceivedHandler: GUID = .{
    .Data1 = 0xE371E005,
    .Data2 = 0x6D1D,
    .Data3 = 0x4517,
    .Data4 = .{ 0x93, 0x4B, 0xA8, 0xF1, 0x62, 0x9C, 0x62, 0xA5 },
};

// ---------------------------------------------------------- ICoreWebView2_4

/// Revision 4 of the web view, for its one addition we need:
/// `add_FrameCreated` (slot 73). Reached by `ICoreWebView2.QueryInterface`; a
/// runtime without it (older than 1.0.902) simply has no iframe menu, which is
/// how every page behaved before T928.
pub const ICoreWebView2_4 = extern struct {
    vtable: *const Vtbl,

    /// Slots 3..72: `ICoreWebView2` (58) through `ICoreWebView2_3`'s
    /// `ClearVirtualHostNameToFolderMapping`. We call none of them here.
    pub const inherited_slots = 70;

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2_4, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2_4) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2_4) callconv(.winapi) u32,
        inherited: [inherited_slots]*const anyopaque,
        add_FrameCreated: *const fn (*ICoreWebView2_4, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ICoreWebView2_4) void {
        _ = self.vtable.Release(self);
    }

    /// Subscribe to "the top-level page created an iframe".
    pub fn addFrameCreated(self: *ICoreWebView2_4, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_FrameCreated(self, handler, &token));
    }
};

/// The `ICoreWebView2_4` view of a web view, or null on a runtime that
/// predates it. Caller owns the reference.
pub fn queryV4(web: *iface.ICoreWebView2) ?*ICoreWebView2_4 {
    var out: ?*anyopaque = null;
    if (com.failed(web.vtable.QueryInterface(web, &IID_ICoreWebView2_4, &out))) return null;
    return @ptrCast(@alignCast(out orelse return null));
}

// --------------------------------------------------------- ICoreWebView2Frame

/// One iframe. The base interface is only ever QI'd onward, plus the one
/// question the pane asks of a frame it is holding: has it gone
/// (`IsDestroyed`, slot 10), so the reference can be dropped.
pub const ICoreWebView2Frame = extern struct {
    vtable: *const Vtbl,

    /// Slots 3..9: `get_Name` through `remove_Destroyed`.
    pub const pre_destroyed_slots = 7;

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Frame, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2Frame) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2Frame) callconv(.winapi) u32,
        pre_destroyed: [pre_destroyed_slots]*const anyopaque,
        IsDestroyed: *const fn (*ICoreWebView2Frame, *BOOL) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ICoreWebView2Frame) void {
        _ = self.vtable.Release(self);
    }

    /// Whether the frame has left the page. A call that fails is read as
    /// "gone": the only thing the answer decides is whether to keep holding a
    /// reference, and a frame that cannot answer is not one to hold.
    pub fn isDestroyed(self: *ICoreWebView2Frame) bool {
        var destroyed: BOOL = 0;
        if (com.failed(self.vtable.IsDestroyed(self, &destroyed))) return true;
        return destroyed != 0;
    }

    /// The `ICoreWebView2Frame2` view, or null. Caller owns the reference.
    pub fn queryV2(self: *ICoreWebView2Frame) ?*ICoreWebView2Frame2 {
        var out: ?*anyopaque = null;
        if (com.failed(self.vtable.QueryInterface(self, &IID_ICoreWebView2Frame2, &out))) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }

    /// The `ICoreWebView2Frame7` view, or null on a runtime older than the
    /// nested-frame event. Caller owns the reference.
    pub fn queryV7(self: *ICoreWebView2Frame) ?*ICoreWebView2Frame7 {
        var out: ?*anyopaque = null;
        if (com.failed(self.vtable.QueryInterface(self, &IID_ICoreWebView2Frame7, &out))) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }
};

/// Revision 2 of the frame, for `add_WebMessageReceived` (slot 22) — where a
/// subframe's `postMessage` actually arrives.
pub const ICoreWebView2Frame2 = extern struct {
    vtable: *const Vtbl,

    /// Slots 3..21: the base frame's eight methods, then revision 2's
    /// navigation / DOM-content / script / post methods up to
    /// `PostWebMessageAsString`.
    pub const inherited_slots = 19;

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Frame2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2Frame2) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2Frame2) callconv(.winapi) u32,
        inherited: [inherited_slots]*const anyopaque,
        add_WebMessageReceived: *const fn (*ICoreWebView2Frame2, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ICoreWebView2Frame2) void {
        _ = self.vtable.Release(self);
    }

    pub fn addWebMessageReceived(self: *ICoreWebView2Frame2, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_WebMessageReceived(self, handler, &token));
    }
};

/// Revision 7 of the frame, for its `add_FrameCreated` (slot 30): an iframe
/// nested inside this one. Without it only the page's DIRECT iframes are
/// reached, which is the degrade on an older runtime.
pub const ICoreWebView2Frame7 = extern struct {
    vtable: *const Vtbl,

    /// Slots 3..29: everything from the base frame through revision 6's
    /// `remove_ScreenCaptureStarting`.
    pub const inherited_slots = 27;

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2Frame7, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2Frame7) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2Frame7) callconv(.winapi) u32,
        inherited: [inherited_slots]*const anyopaque,
        add_FrameCreated: *const fn (*ICoreWebView2Frame7, *anyopaque, *EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ICoreWebView2Frame7) void {
        _ = self.vtable.Release(self);
    }

    pub fn addFrameCreated(self: *ICoreWebView2Frame7, handler: *anyopaque) bool {
        var token: EventRegistrationToken = .{};
        return !com.failed(self.vtable.add_FrameCreated(self, handler, &token));
    }
};

/// What both frame-created events carry: the new frame.
pub const ICoreWebView2FrameCreatedEventArgs = extern struct {
    vtable: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*ICoreWebView2FrameCreatedEventArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ICoreWebView2FrameCreatedEventArgs) callconv(.winapi) u32,
        Release: *const fn (*ICoreWebView2FrameCreatedEventArgs) callconv(.winapi) u32,
        get_Frame: *const fn (*ICoreWebView2FrameCreatedEventArgs, *?*ICoreWebView2Frame) callconv(.winapi) HRESULT,
    };

    /// The new frame. Caller owns the reference.
    pub fn frame(self: *ICoreWebView2FrameCreatedEventArgs) ?*ICoreWebView2Frame {
        var out: ?*ICoreWebView2Frame = null;
        if (com.failed(self.vtable.get_Frame(self, &out))) return null;
        return out;
    }
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "the slots we call sit where WebView2.h puts them" {
    const ptr = @sizeOf(*const anyopaque);
    // Numbered from the header's own DECLSPEC_XFGVIRT listing, 0-based.
    try testing.expectEqual(73 * ptr, @offsetOf(ICoreWebView2_4.Vtbl, "add_FrameCreated"));
    try testing.expectEqual(10 * ptr, @offsetOf(ICoreWebView2Frame.Vtbl, "IsDestroyed"));
    try testing.expectEqual(22 * ptr, @offsetOf(ICoreWebView2Frame2.Vtbl, "add_WebMessageReceived"));
    try testing.expectEqual(30 * ptr, @offsetOf(ICoreWebView2Frame7.Vtbl, "add_FrameCreated"));
    try testing.expectEqual(3 * ptr, @offsetOf(ICoreWebView2FrameCreatedEventArgs.Vtbl, "get_Frame"));

    // And nothing trails the last named slot: a declaration that ran past it
    // would be a guess about a revision we never read.
    try testing.expectEqual(74 * ptr, @sizeOf(ICoreWebView2_4.Vtbl));
    try testing.expectEqual(11 * ptr, @sizeOf(ICoreWebView2Frame.Vtbl));
    try testing.expectEqual(23 * ptr, @sizeOf(ICoreWebView2Frame2.Vtbl));
    try testing.expectEqual(31 * ptr, @sizeOf(ICoreWebView2Frame7.Vtbl));
}

test "every frame interface puts its vtable pointer first" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2_4, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2Frame, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2Frame2, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2Frame7, "vtable"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ICoreWebView2FrameCreatedEventArgs, "vtable"));
}
