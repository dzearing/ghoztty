//! The hover grab handle (T1830): the window half. Rules, geometry and pixels
//! are `pane_grab_handle.zig`; this file owns the popup, the pointer sampling
//! and the press that starts a drag.
//!
//! ONE handle per window, not one per pane: only one pane's top band can hold
//! the pointer at a time, so a single popup that moves to whichever pane that
//! is shows exactly what a handle per pane would, with nothing to create or
//! destroy as panes come and go.
//!
//! Like the read-only badge it is a `WS_EX_LAYERED` popup owned by the
//! window, which is what puts it over the pane's OpenGL content and over a
//! pane's banner strip, and it is painted with per-pixel alpha so the hinted
//! capsule is genuinely translucent over the terminal. It is NOT
//! `WS_EX_TRANSPARENT`: the press on it is the whole point.
//!
//! **Where the pointer is.** Every mouse move this process sees on any of the
//! window's own HWNDs pokes `poke()` (the run loop routes them, `App.zig`), and
//! a short timer then samples `GetCursorPos` while the pointer stays over the
//! window. The timer is what covers a viewer: its page is another process's
//! window, so moving across it raises nothing here.
//!
//! **The drag.** A press on the handle hands the pane to the window's pane-drag
//! machinery (`Window.beginGrabHandleDrag`), which takes the mouse capture, so
//! from the press on this is the same drag rearrange mode and the pane sidebar
//! start: the same threshold, preview, drop resolver and commit.

const std = @import("std");
const w32 = @import("win32.zig");
const grab = @import("pane_grab_handle.zig");
const color_math = @import("color_math.zig");
const chrome_fanout = @import("chrome_fanout.zig");
const overlay_zorder = @import("overlay_zorder.zig");
const PaneSidebar = @import("PaneSidebar.zig");
const PaneView = @import("PaneView.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_grab_handle);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyPaneGrabHandle");

/// The sampling timer, on the handle's own hwnd (its own id space).
const TIMER_POLL: usize = 1;

/// `grab.State` as a number on the handle window: 0 hidden, 1 hinted,
/// 2 engaged. Read by `test\win32\pane-grab-handle.ps1`.
pub const STATE_PROP = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyGrabState");

/// What the window answers about a point on screen.
pub const Probe = struct {
    /// The pointer is over this window (and not over a dialog or another
    /// application's window in front of it).
    over_window: bool = false,
    /// The pane under the pointer is a viewer, whose page this process
    /// cannot hear the pointer move over.
    over_viewer: bool = false,
    /// The window shows no handles right now (`grab.suppressed`).
    suppressed: bool = false,
    /// The pane under the pointer, if any.
    hit: ?Target = null,
    /// The pointer is in that pane's top band.
    in_band: bool = false,
};

/// A pane the handle can sit on.
pub const Target = struct {
    view: *PaneView,
    /// The pane's rect, in SCREEN coordinates.
    pane: w32.RECT,
    /// What the pane is drawn on, for the capsule's colors.
    bg: color_math.Rgb,
    /// False while a terminal has hidden the pointer for typing.
    cursor_visible: bool,
};

pub const PaneGrabHandle = struct {
    alloc: std.mem.Allocator,
    window: *Window,
    owner: w32.HWND,
    hwnd: w32.HWND,

    /// The pane the handle is on while it is shown.
    view: ?*PaneView = null,
    shown: grab.State = .hidden,
    placed: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    painted_bg: ?color_math.Rgb = null,
    painted_scale: f32 = 0,

    /// The pointer is on the handle itself (tracked by its own leave).
    over_handle: bool = false,
    tracking: bool = false,

    polling: bool = false,
    /// Where the pointer is believed to be, in screen coordinates: the point
    /// of the last mouse message, or the last sample that MOVED.
    pt: w32.POINT = .{ .x = std.math.minInt(i32), .y = std.math.minInt(i32) },
    /// The last `GetCursorPos` reading. A sample only replaces `pt` when it
    /// differs from this one, so a still cursor never overrides the point a
    /// message carried - which is what lets posted input (the acceptance
    /// suite's background desktop, where the real cursor never moves) drive
    /// the handle exactly as real input does.
    sampled: ?w32.POINT = null,
    still_ticks: u32 = 0,

    pixels: []u32 = &.{},

    pub fn create(
        alloc: std.mem.Allocator,
        window: *Window,
        owner: w32.HWND,
        hinstance: w32.HINSTANCE,
    ) !*PaneGrabHandle {
        try registerClassOnce(hinstance);
        const self = try alloc.create(PaneGrabHandle);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .window = window, .owner = owner, .hwnd = undefined };

        // WS_EX_LAYERED — composited above OpenGL content, per-pixel alpha.
        // WS_EX_NOACTIVATE — a press never moves activation to the popup.
        // WS_EX_TOOLWINDOW — out of the taskbar / Alt-Tab list.
        const hwnd = w32.CreateWindowExW(
            w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP,
            0,
            0,
            1,
            1,
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        var cur: w32.POINT = undefined;
        if (w32.GetCursorPos_(&cur) != 0) self.sampled = cur;
        return self;
    }

    pub fn destroy(self: *PaneGrabHandle) void {
        _ = w32.KillTimer(self.hwnd, TIMER_POLL);
        _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(self.hwnd);
        if (self.pixels.len > 0) self.alloc.free(self.pixels);
        self.alloc.destroy(self);
    }

    /// The pointer moved to `pt` (screen) somewhere over the window: look
    /// now, and keep looking while it stays.
    pub fn poke(self: *PaneGrabHandle, pt: w32.POINT) void {
        self.pt = pt;
        self.still_ticks = 0;
        if (!self.polling) {
            _ = w32.SetTimer(self.hwnd, TIMER_POLL, grab.poll_ms, null);
            self.polling = true;
        }
        self.evaluate();
    }

    /// Hide now, whatever the pointer is doing — the pane it was on is
    /// moving, closing or the window's layout changed under it. The next
    /// poke puts it back where it belongs.
    pub fn hide(self: *PaneGrabHandle) void {
        self.view = null;
        self.over_handle = false;
        if (self.shown == .hidden) return;
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.setShown(.hidden);
    }

    /// Publish the state as a window property, so a script on the background
    /// desktop - where nothing can read a layered window's pixels back - can
    /// tell hinted from engaged (the `GhozttyDragCursor` pattern, T1536).
    fn setShown(self: *PaneGrabHandle, st: grab.State) void {
        if (st == self.shown) return;
        self.shown = st;
        _ = w32.SetPropW(self.hwnd, STATE_PROP, @ptrFromInt(@as(usize, @intFromEnum(st))));
        log.debug("grab handle state={s}", .{@tagName(st)});
    }

    fn tick(self: *PaneGrabHandle) void {
        var cur: w32.POINT = undefined;
        if (w32.GetCursorPos_(&cur) != 0 and
            (self.sampled == null or cur.x != self.sampled.?.x or cur.y != self.sampled.?.y))
        {
            self.sampled = cur;
            self.pt = cur;
            self.still_ticks = 0;
        } else {
            self.still_ticks +|= 1;
        }
        self.evaluate();
    }

    fn evaluate(self: *PaneGrabHandle) void {
        const pt = self.pt;
        const probe = self.window.grabHandleProbe(pt, self.hwnd);

        // Held: on the handle, or carrying its pane. The handle stays on THAT
        // pane wherever the pointer goes, the way Mac's stays engaged for the
        // whole drag.
        const held_view: ?*PaneView = if (self.view) |v|
            (if (self.window.grabDragging(v) or (self.over_handle and self.shown != .hidden)) v else null)
        else
            null;

        if (held_view) |v| {
            if (self.window.grabHandleTarget(v)) |t| {
                self.show(t, grab.state(.{
                    .cursor_visible = t.cursor_visible,
                    .suppressed = probe.suppressed and !self.window.grabDragging(v),
                    .over_handle = self.over_handle,
                    .dragging = self.window.grabDragging(v),
                }));
            } else self.hide();
        } else if (probe.hit) |t| {
            const st = grab.state(.{
                .cursor_visible = t.cursor_visible,
                .suppressed = probe.suppressed,
                .pointer_in_band = probe.in_band,
                .over_handle = self.over_handle and self.view == t.view,
            });
            if (st == .hidden) self.hide() else self.show(t, st);
        } else self.hide();

        if (!grab.keepPolling(self.shown != .hidden, probe.over_window, probe.over_viewer, self.still_ticks))
            self.stopPolling();
    }

    fn stopPolling(self: *PaneGrabHandle) void {
        if (!self.polling) return;
        _ = w32.KillTimer(self.hwnd, TIMER_POLL);
        self.polling = false;
    }

    fn show(self: *PaneGrabHandle, t: Target, st: grab.State) void {
        if (st == .hidden) return self.hide();
        const scale = self.window.scale;
        const m = grab.Metrics.forScale(scale);
        const pane: grab.Rect = .{
            .left = t.pane.left,
            .top = t.pane.top,
            .right = t.pane.right,
            .bottom = t.pane.bottom,
        };
        const l = grab.layout(pane, m) orelse return self.hide();
        const rect: w32.RECT = .{
            .left = l.win.left,
            .top = l.win.top,
            .right = l.win.right,
            .bottom = l.win.bottom,
        };

        const was_shown = self.shown != .hidden;
        const moved = !std.meta.eql(self.placed, rect);
        const restyled = st != self.shown or
            self.painted_bg == null or !std.meta.eql(self.painted_bg.?, t.bg) or
            scale != self.painted_scale;
        self.view = t.view;
        self.setShown(st);
        self.placed = rect;

        if (moved or restyled or !was_shown) {
            self.paint(m, l, st, t.bg, rect);
            self.painted_bg = t.bg;
            self.painted_scale = scale;
        }

        if (!was_shown) {
            // Seat it above the window's other popups — a pane's banner is
            // one, and the handle is drawn over it — and below everything
            // that is not this window's. A stray topmost bit goes first.
            const root_ex = w32.GetWindowLongW(self.owner, w32.GWL_EXSTYLE);
            if (overlay_zorder.isStray(w32.GetWindowLongW(self.hwnd, w32.GWL_EXSTYLE), root_ex)) {
                _ = w32.SetWindowPos(self.hwnd, w32.HWND_NOTOPMOST, 0, 0, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
            }
            chrome_fanout.noteMove(.badge);
            _ = w32.SetWindowPos(
                self.hwnd,
                PaneSidebar.seatAfterFor(self.owner, self.hwnd),
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW,
            );
        }
    }

    /// Render and push the pixels; `UpdateLayeredWindow` also places the
    /// window, so a move and a restyle are one call.
    fn paint(self: *PaneGrabHandle, m: grab.Metrics, l: grab.Layout, st: grab.State, bg: color_math.Rgb, rect: w32.RECT) void {
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        if (w <= 0 or h <= 0) return;
        const n: usize = @intCast(w * h);
        if (self.pixels.len < n) {
            if (self.pixels.len > 0) self.alloc.free(self.pixels);
            self.pixels = self.alloc.alloc(u32, n) catch {
                self.pixels = &.{};
                return;
            };
        }
        grab.render(self.pixels[0..n], m, l, st, bg);

        const screen_dc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, screen_dc);
        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);
        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{ .bmiHeader = .{ .biWidth = w, .biHeight = -h } };
        const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
        defer _ = w32.DeleteObject(bitmap);
        const old_bmp = w32.SelectObject(mem_dc, bitmap) orelse return;
        defer _ = w32.SelectObject(mem_dc, old_bmp);
        const dst: [*]u32 = @ptrCast(@alignCast(bits.?));
        @memcpy(dst[0..n], self.pixels[0..n]);

        const dst_pt = w32.POINT{ .x = rect.left, .y = rect.top };
        const dst_size = w32.SIZE{ .cx = w, .cy = h };
        const src_pt = w32.POINT{ .x = 0, .y = 0 };
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = 255 };
        _ = w32.UpdateLayeredWindow(self.hwnd, screen_dc, &dst_pt, &dst_size, mem_dc, &src_pt, 0, &blend, w32.ULW_ALPHA);
    }

    fn onMouseMove(self: *PaneGrabHandle) void {
        if (!self.tracking) {
            var tme = w32.TRACKMOUSEEVENT{
                .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                .dwFlags = w32.TME_LEAVE,
                .hwndTrack = self.hwnd,
                .dwHoverTime = 0,
            };
            if (w32.TrackMouseEvent(&tme) != 0) self.tracking = true;
        }
        if (!self.over_handle) {
            self.over_handle = true;
            self.evaluate();
        }
    }

    fn onMouseLeave(self: *PaneGrabHandle) void {
        self.tracking = false;
        if (!self.over_handle) return;
        self.over_handle = false;
        self.evaluate();
    }

    /// A press on the handle starts the pane drag. The point comes from the
    /// message (client coordinates of this popup), not from the cursor, for
    /// the same reason `pt` does.
    fn onPress(self: *PaneGrabHandle, lparam: isize) void {
        const view = self.view orelse return;
        var pt: w32.POINT = .{
            .x = @as(i16, @truncate(lparam & 0xFFFF)),
            .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)),
        };
        _ = w32.ClientToScreen(self.hwnd, &pt);
        self.pt = pt;
        self.window.beginGrabHandleDrag(view, pt);
        self.evaluate();
    }
};

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
        // The whole handle drags, so the move pointer is the class cursor -
        // the same one a rearrange-mode header shows (`rearrange_header.Cursor`,
        // T1536: Windows has no open-hand pointer that does not mean "link").
        .hCursor = w32.LoadCursorW(null, w32.IDC_SIZEALL),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*PaneGrabHandle = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        // Never take activation from the pane underneath, but DO deliver the
        // press (MA_NOACTIVATE, not MA_NOACTIVATEANDEAT).
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_MOUSEMOVE => {
            self.onMouseMove();
            return 0;
        },
        w32.WM_MOUSELEAVE => {
            self.onMouseLeave();
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            self.onPress(lparam);
            return 0;
        },
        w32.WM_TIMER => {
            if (wparam == TIMER_POLL) self.tick();
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

test "T1830: the handle's class cursor is the drag pointer rearrange mode uses" {
    const rearrange_header = @import("rearrange_header.zig");
    try std.testing.expectEqual(w32.IDC_SIZEALL, rearrange_header.Cursor.move.idc());
}

test "T1830: the published state numbers are the enum's, which scripts read" {
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(grab.State.hidden));
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum(grab.State.hinted));
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum(grab.State.engaged));
}
