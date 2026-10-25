//! One reposition path for the win32 floating chrome (T1392).
//!
//! Every bar and card the viewer floats over its content — the nav bar, the
//! find card, the feedback composer, the TOC card, the banner — is moved and
//! resized from the pane's bounds sync, which a divider drag re-runs on every
//! mouse move. What Windows is asked to do there decides whether the chrome
//! looks glued to the edge being dragged or a frame behind it:
//!
//! * `MoveWindow(.., TRUE)` INVALIDATES and lets the repaint fall out to the
//!   next idle. During a live drag the message loop is busy pumping sizing
//!   messages, so that paint lands a frame or more after the move — and since
//!   these classes carry `CS_HREDRAW | CS_VREDRAW`, the late frame is a full
//!   redraw of the whole bar. That is the "I watch it painting" the user
//!   reported against the address bar.
//! * Until that repaint the old bits sit 1:1 at the client origin — never
//!   stretched — beside whatever the grow uncovered, so the frame shows a card
//!   laid out for the old width (T1348 measured it).
//!
//! The banner solved both in T456 by hand; this module is that solution
//! extracted, so the next overlay does not have to rediscover it:
//!
//! 1. Decide from the rects whether this is a RESIZE or just a MOVE.
//! 2. On a resize add `SWP_NOCOPYBITS` — the class already invalidates every
//!    pixel, so blitting the stale bits buys nothing but the smear.
//! 3. On a resize follow with `UpdateWindow`, which paints in THIS frame.
//!
//! A pure move keeps neither: nothing about the pixels changed, `NOCOPYBITS`
//! would throw away a perfectly good blit and force a needless repaint, and a
//! synchronous paint on a move is work with no visible payoff.
//!
//! **`SWP_NOCOPYBITS` stays, and T1348 measured why.** The case against it was
//! that discarding the old bits shows undefined pixels for the instant before
//! the synchronous repaint, where keeping them would show the previous frame.
//! Read back from a real layered popup on this box, neither half holds:
//!
//! * On a `CS_HREDRAW | CS_VREDRAW` class (the banner, the bars) the flag
//!   changes no pixel at all. The class already invalidates everything on a
//!   size change, and between the resize and the repaint the surviving region
//!   still holds the previous frame WITH the flag — Windows does not clear it.
//!   The strip a grow uncovers is uninitialised either way; that comes from
//!   growing, not from the flag, and `UpdateWindow` covers it in this frame.
//! * On a class WITHOUT those bits (the TOC panel's edit control, say) the flag
//!   is the only thing that repaints the stale part: without it Windows keeps
//!   the old bits as valid and paints only the uncovered sliver.
//!
//! So it is redundant where the T1348 theory looked and load-bearing where it
//! did not. The tests at the bottom hold both measurements.

const std = @import("std");
const w32 = @import("win32.zig");

/// A window's outer size in pixels. Screen or client space does not matter —
/// only the extents are ever compared, and a move does not change those.
pub const Size = struct {
    w: i32,
    h: i32,
};

/// What a reposition owes Windows, decided from the old and new extents alone.
pub const Decision = struct {
    /// The extents changed (or the old ones could not be read, which is the
    /// safe answer: assume everything is stale).
    resized: bool,
    /// Add `SWP_NOCOPYBITS` to the `SetWindowPos` flags.
    no_copy_bits: bool,
    /// Force the `WM_PAINT` now, in the same frame as the move.
    sync_paint: bool,
};

/// The whole decision, as a pure function of the two rects.
///
/// `old` is null when the current rect is unknown — a window that has not been
/// placed yet, or a `GetWindowRect` that failed. Both mean "nothing on screen
/// can be trusted", which is the resize answer.
pub fn decide(old: ?Size, new: Size) Decision {
    const resized = if (old) |o| o.w != new.w or o.h != new.h else true;
    return .{
        .resized = resized,
        .no_copy_bits = resized,
        .sync_paint = resized,
    };
}

/// Read a window's current outer size, or null when Windows will not say.
pub fn currentSize(hwnd: w32.HWND) ?Size {
    var r: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &r) == 0) return null;
    return .{ .w = r.right - r.left, .h = r.bottom - r.top };
}

/// Move and/or resize a piece of floating chrome the way a live drag needs.
///
/// Drop-in for `MoveWindow(hwnd, x, y, w, h, TRUE)`. `base_flags` carries
/// whatever else the call site means (`SWP_SHOWWINDOW` on a popup that may be
/// coming back from hidden, say); the resize flags are added on top.
pub fn place(
    hwnd: w32.HWND,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    base_flags: u32,
) Decision {
    const d = decide(currentSize(hwnd), .{ .w = width, .h = height });
    var flags = base_flags | w32.SWP_NOACTIVATE | w32.SWP_NOZORDER;
    if (d.no_copy_bits) flags |= w32.SWP_NOCOPYBITS;
    _ = w32.SetWindowPos(hwnd, null, x, y, width, height, flags);
    if (d.sync_paint) _ = w32.UpdateWindow(hwnd);
    return d;
}

test "resize: no stale blit, and the paint is in this frame" {
    const d = decide(.{ .w = 400, .h = 40 }, .{ .w = 520, .h = 40 });
    try std.testing.expect(d.resized);
    try std.testing.expect(d.no_copy_bits);
    try std.testing.expect(d.sync_paint);
}

test "height-only resize counts too" {
    const d = decide(.{ .w = 400, .h = 40 }, .{ .w = 400, .h = 64 });
    try std.testing.expect(d.resized);
    try std.testing.expect(d.no_copy_bits);
    try std.testing.expect(d.sync_paint);
}

// The negative half, and the one T1392's validation names explicitly: a pure
// move must NOT take either. `SWP_NOCOPYBITS` on a move throws away a valid
// blit for a full repaint, and a synchronous paint there is a frame of work
// buying nothing — that is how a fix for one flicker becomes another.
test "pure move: keeps the blit and defers the paint" {
    const d = decide(.{ .w = 400, .h = 40 }, .{ .w = 400, .h = 40 });
    try std.testing.expect(!d.resized);
    try std.testing.expect(!d.no_copy_bits);
    try std.testing.expect(!d.sync_paint);
}

// A window nobody has measured yet has nothing worth blitting, so the unknown
// case has to land on the resize side. It is also what a failed
// `GetWindowRect` returns, and treating that as a move would silently restore
// the exact defect on any window Windows declines to measure.
test "unknown old rect is treated as a resize" {
    const d = decide(null, .{ .w = 400, .h = 40 });
    try std.testing.expect(d.resized);
    try std.testing.expect(d.no_copy_bits);
    try std.testing.expect(d.sync_paint);
}

// Negative control (T1133): the decision is a real fork, not a constant
// wearing a struct. If these two ever agree, every test above passes while
// the module has stopped deciding anything.
test "T1392 negative control: move and resize do not decide the same thing" {
    const same: Size = .{ .w = 400, .h = 40 };
    const move = decide(same, same);
    const resize = decide(same, .{ .w = 401, .h = 40 });
    try std.testing.expect(!std.meta.eql(move, resize));
}

// --- T1348: what `SWP_NOCOPYBITS` does to real pixels ----------------------
//
// These read the window's own surface back with GetPixel, because the claim
// in question is about pixels and no pure function can stand in for what
// Windows keeps across a resize. Every window is a layered popup ON-SCREEN at
// alpha 0, the same shape as the banner's class tests: visible to the window
// manager (an off-monitor window has an empty visible region and Windows
// invalidates nothing), painting nothing a user could see.

/// The colour the probe class paints with; tests flip it between frames so a
/// pixel says which frame it came from.
var probe_color: u32 = 0;

fn probePaintInto(hwnd: w32.HWND, hdc: w32.HDC) void {
    var rc: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rc);
    if (w32.CreateSolidBrush(probe_color)) |brush| {
        defer _ = w32.DeleteObject(brush);
        _ = w32.FillRect(hdc, &rc, brush);
    }
}

fn probeWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            probePaintInto(hwnd, hdc);
            return 0;
        },
        // Every painting class answers a capture too (T940's printclient audit).
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            probePaintInto(hwnd, @ptrFromInt(wparam));
            return 0;
        },
        // No erase: a pixel must only ever change because WM_PAINT painted it.
        w32.WM_ERASEBKGND => return 1,
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const ProbeWindow = struct {
    hwnd: w32.HWND,
    hinst: w32.HINSTANCE,
    class: [*:0]const u16,

    /// A shown 200x40 probe, already painted with `first`.
    fn open(class: [*:0]const u16, class_style: u32, first: u32) !ProbeWindow {
        const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
        const wc = w32.WNDCLASSEXW{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = class_style,
            .lpfnWndProc = probeWndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinst,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class,
            .hIconSm = null,
        };
        if (w32.RegisterClassExW(&wc) == 0) return error.SkipZigTest;
        errdefer _ = w32.UnregisterClassW(class, hinst);
        const hwnd = w32.CreateWindowExW(
            w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW,
            class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP,
            0,
            0,
            200,
            40,
            null,
            null,
            hinst,
            null,
        ) orelse return error.SkipZigTest;
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, 0, w32.LWA_ALPHA);
        probe_color = first;
        _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
        _ = w32.UpdateWindow(hwnd);
        return .{ .hwnd = hwnd, .hinst = hinst, .class = class };
    }

    fn close(self: ProbeWindow) void {
        _ = w32.DestroyWindow(self.hwnd);
        _ = w32.UnregisterClassW(self.class, self.hinst);
    }

    /// A pixel well inside the region that survives a grow.
    fn pixel(self: ProbeWindow) !u32 {
        const hdc = w32.GetDC(self.hwnd) orelse return error.SkipZigTest;
        defer _ = w32.ReleaseDC(self.hwnd, hdc);
        const c = w32.GetPixel(hdc, 5, 5);
        if (c == w32.CLR_INVALID) return error.SkipZigTest;
        return c;
    }

    /// Grow to 320x64 with exactly the flags given — no paint.
    fn grow(self: ProbeWindow, flags: u32) void {
        _ = w32.SetWindowPos(self.hwnd, null, 0, 0, 320, 64, flags | w32.SWP_NOMOVE |
            w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    }
};

const old_frame = w32.RGB(255, 0, 0);
const new_frame = w32.RGB(0, 0, 255);

/// The banner's class, and what the gap between the resize and its repaint
/// holds, with and without the flag. Returns {gap pixel, painted pixel}.
fn redrawClassResize(no_copy_bits: bool) ![2]u32 {
    const w = try ProbeWindow.open(
        std.unicode.utf8ToUtf16LeStringLiteral("GhozttyT1348Redraw"),
        w32.CS_HREDRAW | w32.CS_VREDRAW,
        old_frame,
    );
    defer w.close();
    if (try w.pixel() != old_frame) return error.SkipZigTest;
    probe_color = new_frame;
    w.grow(if (no_copy_bits) w32.SWP_NOCOPYBITS else 0);
    const gap = try w.pixel();
    _ = w32.UpdateWindow(w.hwnd);
    return .{ gap, try w.pixel() };
}

// The T1348 theory, measured: on a CS_HREDRAW | CS_VREDRAW class the flag does
// not put undefined pixels in the gap. Before the repaint the surviving region
// holds the PREVIOUS frame whether or not the flag is set, and the repaint
// lands the new frame either way — so dropping the flag would change nothing a
// user could see.
test "T1348: on a redraw class SWP_NOCOPYBITS changes no pixel" {
    const with_flag = try redrawClassResize(true);
    const without = try redrawClassResize(false);
    try std.testing.expectEqual(without, with_flag);
    try std.testing.expectEqual(old_frame, with_flag[0]);
    try std.testing.expectEqual(new_frame, with_flag[1]);
}

// The other half, and the reason the flag stays: on a class WITHOUT the redraw
// bits it is what repaints the stale region. `place()` must land the new frame
// there too, and the negative control proves the flag is what does it —
// without it Windows keeps the old bits as valid, the synchronous paint covers
// only the uncovered sliver, and the old frame is still on screen afterwards.
test "T1348: on a plain class SWP_NOCOPYBITS is what repaints the stale card" {
    const class = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyT1348Plain");
    {
        const w = try ProbeWindow.open(class, 0, old_frame);
        defer w.close();
        if (try w.pixel() != old_frame) return error.SkipZigTest;
        probe_color = new_frame;
        const d = place(w.hwnd, 0, 0, 320, 64, 0);
        try std.testing.expect(d.no_copy_bits);
        try std.testing.expectEqual(new_frame, try w.pixel());
    }
    {
        const w = try ProbeWindow.open(class, 0, old_frame);
        defer w.close();
        probe_color = new_frame;
        w.grow(0);
        _ = w32.UpdateWindow(w.hwnd);
        try std.testing.expectEqual(old_frame, try w.pixel());
    }
}
