//! The live drop preview of a rearrange-mode pane drag (T1531): one layered
//! popup, glued to the rect the dragged pane would occupy if the button were
//! released right now.
//!
//! A popup rather than paint into the window's own DC, for the reason every
//! other overlay in this apprt is one: the panes are CHILD windows (and a
//! terminal pane's content is OpenGL), so anything drawn into the parent's DC
//! is immediately covered. `DimOverlay` is the model here — `WS_EX_LAYERED`
//! for the DWM composite, `WS_EX_TRANSPARENT` so it never eats the mouse
//! (during a drag the mouse is captured by the window, and a preview that
//! hit-tested would break the capture's coordinate stream), `WS_EX_NOACTIVATE`
//! so the drag keeps focus.
//!
//! One overlay per window, created lazily on the first drag and destroyed with
//! the window. The geometry it is handed is decided by `drop_highlight.zig`,
//! which is pure and unit-tested; everything here is placement and paint.

const std = @import("std");
const w32 = @import("win32.zig");
const drop_highlight = @import("drop_highlight.zig");
const chrome_theme = @import("chrome_theme.zig");

const log = std.log.scoped(.win32_drop_highlight);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyDropHighlight");

/// How opaque the wash is, by what the drop means.
///
/// An INSERT fills the rect the pane will take, so it is drawn as that pane's
/// footprint. A SWAP is not a footprint — the pane under it stays where it is
/// and the two exchange — so it is washed lighter and framed, which reads as
/// "this one" rather than "here".
pub const alpha_insert: u8 = 110;
pub const alpha_swap: u8 = 72;

/// A new-tab caret is a solid mark rather than a wash (T1537): it is a few
/// pixels wide, and a 43%-opaque sliver on chrome is not a thing the eye
/// finds. It is the one preview that says "the tab opens HERE" rather than
/// "the pane covers this", so it reads as a caret, not as a footprint.
pub const alpha_caret: u8 = 235;

/// The frame's thickness, in DIP, around a swap preview.
pub const frame_dip: i32 = 3;

const DropHighlight = @This();

alloc: std.mem.Allocator,
/// The window this preview belongs to (popup owner).
owner: w32.HWND,
hwnd: w32.HWND,

/// What is currently being previewed, in SCREEN coordinates. Null when the
/// overlay is hidden.
shown: ?drop_highlight.Highlight = null,

fill: ?w32.HBRUSH = null,
fill_color: u32 = 0,
frame: ?w32.HBRUSH = null,
frame_color: u32 = 0,
frame_px: i32 = 1,
alpha: u8 = 0,

/// Is the preview currently in the always-on-top band (T1538)? Tracked rather
/// than re-read from the ex-style because the band change is retried, and a
/// no-op `show` must not pay for it on every mouse move.
topmost: bool = false,

pub fn create(
    alloc: std.mem.Allocator,
    owner: w32.HWND,
    hinstance: w32.HINSTANCE,
) !*DropHighlight {
    try registerClassOnce(hinstance);

    const self = try alloc.create(DropHighlight);
    errdefer alloc.destroy(self);

    self.* = .{
        .alloc = alloc,
        .owner = owner,
        .hwnd = undefined,
    };

    const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_TRANSPARENT |
        w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW;

    const hwnd = w32.CreateWindowExW(
        ex_style,
        WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        0,
        1,
        1, // placeholder — show() glues it to the resolved drop rect
        owner,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.hwnd = hwnd;
    return self;
}

pub fn destroy(self: *DropHighlight) void {
    _ = w32.DestroyWindow(self.hwnd);
    if (self.fill) |b| _ = w32.DeleteObject(@ptrCast(b));
    if (self.frame) |b| _ = w32.DeleteObject(@ptrCast(b));
    self.alloc.destroy(self);
}

/// Put the preview over `hl` (screen coordinates), in the window's accent.
///
/// Idempotent: a move that resolves to the same highlight touches nothing, so
/// the preview does not re-blend on every `WM_MOUSEMOVE` — the same rule
/// `DimOverlay.show` follows, and for the same Remote-Desktop reason.
pub fn show(
    self: *DropHighlight,
    hl: drop_highlight.Highlight,
    pal: chrome_theme.Palette,
    scale: f32,
    over_other_window: bool,
) void {
    if (self.shown) |cur| {
        if (eql(cur, hl) and self.fill != null and self.topmost == over_other_window) return;
    }

    self.setBrushes(pal, scale);

    const want_alpha: u8 = switch (hl.kind) {
        .swap => alpha_swap,
        .split, .top_level, .new_window => alpha_insert,
        .new_tab => alpha_caret,
    };
    if (want_alpha != self.alpha) {
        _ = w32.SetLayeredWindowAttributes(self.hwnd, 0, want_alpha, w32.LWA_ALPHA);
        self.alpha = want_alpha;
    }

    self.shown = hl;

    // A preview over ANOTHER top-level window (T1538) cannot be seated by
    // ownership: this popup is owned by the window the drag started in, so
    // z-order puts it above THAT window and behind the one the pointer is
    // over — a promise drawn where nobody can see it. The always-on-top band
    // is the only place a window can outrank a window it does not own, and it
    // is given up the moment the drop comes back home or the drag ends.
    if (self.topmost != over_other_window) {
        _ = w32.setTopmost(self.hwnd, over_other_window);
        self.topmost = over_other_window;
    }

    _ = w32.SetWindowPos(
        self.hwnd,
        null,
        hl.rect.left,
        hl.rect.top,
        @max(hl.rect.width(), 1),
        @max(hl.rect.height(), 1),
        w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW,
    );
    // Above the panes it is previewing, exactly like every other overlay of
    // ours that has to sit over a child surface. A topmost preview is already
    // above everything, and re-seating it against its owner would pull it back
    // down behind the window it is being drawn over.
    if (!self.topmost) w32.healOverlayZOrderAfterMove(self.hwnd, self.owner, false);
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    _ = w32.UpdateWindow(self.hwnd);
}

pub fn hide(self: *DropHighlight) void {
    if (self.shown == null) return;
    self.shown = null;
    if (self.topmost) {
        _ = w32.setTopmost(self.hwnd, false);
        self.topmost = false;
    }
    _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
}

fn eql(a: drop_highlight.Highlight, b: drop_highlight.Highlight) bool {
    return a.kind == b.kind and
        a.rect.left == b.rect.left and a.rect.top == b.rect.top and
        a.rect.right == b.rect.right and a.rect.bottom == b.rect.bottom;
}

fn setBrushes(self: *DropHighlight, pal: chrome_theme.Palette, scale: f32) void {
    const fill_rgb = w32.RGB(pal.accent.r, pal.accent.g, pal.accent.b);
    if (self.fill == null or fill_rgb != self.fill_color) {
        if (self.fill) |b| _ = w32.DeleteObject(@ptrCast(b));
        self.fill = w32.CreateSolidBrush(fill_rgb);
        self.fill_color = fill_rgb;
    }
    const frame_rgb = w32.RGB(pal.on_accent.r, pal.on_accent.g, pal.on_accent.b);
    if (self.frame == null or frame_rgb != self.frame_color) {
        if (self.frame) |b| _ = w32.DeleteObject(@ptrCast(b));
        self.frame = w32.CreateSolidBrush(frame_rgb);
        self.frame_color = frame_rgb;
    }
    self.frame_px = framePx(scale);
}

fn framePx(scale: f32) i32 {
    const v: f32 = @round(@as(f32, @floatFromInt(frame_dip)) * scale);
    return @max(@as(i32, @intFromFloat(v)), 1);
}

/// The preview, into whichever DC this overlay is handed — its own paint
/// cycle's, or a caller's under `WM_PRINTCLIENT` so a pixel probe can
/// photograph it synchronously (T940).
fn paintInto(self: *const DropHighlight, hwnd: w32.HWND, hdc: w32.HDC) void {
    const fill = self.fill orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) return;
    _ = w32.FillRect(hdc, &rect, fill);

    const hl = self.shown orelse return;
    // A swap reads as "these two trade places", and the new window a pop-out
    // creates is not on screen yet — both want the outline that says the rect
    // is a destination rather than a fill over something already there.
    if (hl.kind != .swap and hl.kind != .new_window) return;
    const brush = self.frame orelse return;

    // Four fills rather than `FrameRect`: the win32 binding has no
    // `FrameRect`, and a frame of an arbitrary thickness needs one anyway
    // (`FrameRect` draws a one-unit border in logical units).
    const t = @min(self.frame_px, @divFloor(@max(rect.right - rect.left, 1), 2));
    const u = @min(self.frame_px, @divFloor(@max(rect.bottom - rect.top, 1), 2));
    var band: w32.RECT = undefined;
    band = .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + u };
    _ = w32.FillRect(hdc, &band, brush);
    band = .{ .left = rect.left, .top = rect.bottom - u, .right = rect.right, .bottom = rect.bottom };
    _ = w32.FillRect(hdc, &band, brush);
    band = .{ .left = rect.left, .top = rect.top, .right = rect.left + t, .bottom = rect.bottom };
    _ = w32.FillRect(hdc, &band, brush);
    band = .{ .left = rect.right - t, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
    _ = w32.FillRect(hdc, &band, brush);
}

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*DropHighlight = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_ERASEBKGND => {
            if (wparam == 0) return 0;
            self.paintInto(hwnd, @ptrFromInt(wparam));
            return 1;
        },

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            self.paintInto(hwnd, hdc);
            return 0;
        },

        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            self.paintInto(hwnd, @ptrFromInt(wparam));
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
