//! The comctl32 tooltip flags, held to commctrl.h (T1744).
//!
//! `win32.zig` carried `TTF_SUBCLASS = 0x0001` from T633 until T1744. That is
//! `TTF_IDISHWND`'s value, so every tool the viewer's nav bar and feedback
//! composer registered "in subclass mode" was really a WINDOW tool keyed on a
//! small integer no window has: comctl32 accepted it, `TTM_GETTOOLCOUNT`
//! counted it, the app logged its rect — and no mouse message ever reached the
//! tooltip, so none of those tips could show. Every oracle the harnesses had
//! read the registration, never the relay.
//!
//! So this file checks two things, and the second is the one that matters:
//!
//!   1. the values are the header's, so a typo is caught by name;
//!   2. a rect tool registered with `w32.TTF_SUBCLASS` on a real window is
//!      actually RELAYED: a mouse move over the rect, sent to the owner window
//!      and to nothing else, makes that tool the tooltip's current tool. That
//!      is the whole contract the flag buys, observed in-process — against the
//!      0x0001 value it fails, which is the demonstration that it can.

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");

const TTM_GETCURRENTTOOLW: u32 = w32.WM_USER + 59;

/// `TTTOOLINFOW_V2_SIZE`: the struct up to (not including) `lpReserved`. The
/// test binary carries no comctl32 v6 manifest, so it gets v5, which refuses
/// the v6 size the app (manifested) registers with. The flag under test means
/// the same thing in both.
const toolinfo_v2_size: u32 = @offsetOf(w32.TOOLINFOW, "lpReserved");

test "tooltip flags carry commctrl.h's values" {
    try std.testing.expectEqual(@as(u32, 0x0001), w32.TTF_IDISHWND);
    try std.testing.expectEqual(@as(u32, 0x0010), w32.TTF_SUBCLASS);
    try std.testing.expectEqual(@as(u32, 0x0020), w32.TTF_TRACK);
    try std.testing.expectEqual(@as(u32, 0x0080), w32.TTF_ABSOLUTE);
}

test "a TTF_SUBCLASS rect tool is relayed the owner's mouse moves" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var icc = w32.INITCOMMONCONTROLSEX{
        .dwSize = @sizeOf(w32.INITCOMMONCONTROLSEX),
        .dwICC = w32.ICC_TAB_CLASSES,
    };
    _ = w32.InitCommonControlsEx(&icc);

    // A plain STATIC as the owner: nothing about the tool depends on the
    // owner's class, and a system class needs no registration. Never shown —
    // the relay is a wndproc subclass and does not care about visibility.
    const owner = w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        0,
        200,
        40,
        null,
        null,
        null,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = w32.DestroyWindow(owner);

    const tip = w32.CreateWindowExW(
        w32.WS_EX_TOPMOST | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
        w32.TOOLTIPS_CLASS,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.TTS_ALWAYSTIP | w32.TTS_NOPREFIX,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        owner,
        null,
        null,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = w32.DestroyWindow(tip);

    // The viewer bars' shape exactly: an id in the owner's tool space, well
    // clear of any HWND value, and a rect inside the owner's client area.
    var text = std.unicode.utf8ToUtf16LeStringLiteral("relayed").*;
    var ti = w32.TOOLINFOW{
        .cbSize = toolinfo_v2_size,
        .uFlags = w32.TTF_SUBCLASS,
        .hwnd = owner,
        .uId = 0x200,
        .rect = .{ .left = 10, .top = 5, .right = 60, .bottom = 30 },
        .hinst = null,
        .lpszText = &text,
        .lParam = 0,
        .lpReserved = null,
    };
    try std.testing.expect(w32.SendMessageW(tip, w32.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&ti))) != 0);

    // Nothing hovered yet, so no current tool.
    try std.testing.expectEqual(@as(isize, 0), w32.SendMessageW(tip, TTM_GETCURRENTTOOLW, 0, 0));

    // A move over the rect, delivered to the OWNER only. Only the subclass
    // can carry it to the tooltip.
    const x: isize = 20;
    const y: isize = 12;
    _ = w32.SendMessageW(owner, w32.WM_MOUSEMOVE, 0, (y << 16) | x);

    var cur = std.mem.zeroes(w32.TOOLINFOW);
    cur.cbSize = toolinfo_v2_size;
    try std.testing.expect(w32.SendMessageW(tip, TTM_GETCURRENTTOOLW, 0, @bitCast(@intFromPtr(&cur))) != 0);
    try std.testing.expectEqual(@as(usize, 0x200), cur.uId);
    try std.testing.expectEqual(@as(?w32.HWND, owner), cur.hwnd);
}
