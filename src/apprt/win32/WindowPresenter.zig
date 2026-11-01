//! The window presenter (T2610 step 3b, T2614): one GL child per top-level
//! window that every terminal pane of that window reaches the screen through.
//!
//! Why one: a top-level that has had two plain WGL children swap into it
//! leaks a window's worth of video memory on every hide/show and
//! minimize/restore (T2599). Where it sits and why is
//! `docs/design/win32-window-presenter.md`; the parts with no HWND or GL in
//! them (the knob, the slot handoff, the compose plan, the z-order rule) are
//! `renderer/gl_window_presenter.zig`.
//!
//! Shape:
//!
//! - The HWND is created on the UI thread, like the panes, because
//!   `HTTRANSPARENT` only hands a hit to the window beneath on the SAME
//!   thread. It sits directly above the topmost terminal pane and below every
//!   other child, with `WS_CLIPSIBLINGS`, so chrome above it clips it for
//!   free. Its window region is the union of the terminal pane rectangles, so
//!   the parent keeps painting the dividers and gutters between them.
//! - NOT `WS_EX_TRANSPARENT`, against the design note's first draft: that
//!   style takes a window out of its lower siblings' clipping, so the panes
//!   under it would keep a visible region and keep painting into the
//!   presenter's pixels. Without it the panes are fully covered and get no
//!   `WM_PAINT` at all, which is the property the note relies on. No harness
//!   hit-tests with `ChildWindowFromPointEx`, which is all the style bought.
//! - The GL context and the compose loop live on the presenter's own thread.
//!   It wakes on an event: a layout pass that moved the panes, a `WM_PAINT`
//!   the presenter got, and (from step 3c) a renderer that published a frame.
//!
//! Step 3b composes background only: renderers still swap their own panes
//! until step 3c hands their frames over (T2615), so with the knob on a pane
//! shows its background color and no text yet. The knob is off by default.
const WindowPresenter = @This();

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const gl_loader = @import("../../renderer/gl_loader.zig");
const gl_robust = @import("../../renderer/gl_robust.zig");
const core = @import("../../renderer/gl_window_presenter.zig");
const Surface = @import("Surface.zig");
const App = @import("App.zig");

const log = std.log.scoped(.win32_window_presenter);

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyPresenter");

/// Terminal panes one presenter composes. A window with more panes than this
/// composes the first `MAX_PANES` and logs it once; the rest show background.
pub const MAX_PANES = 64;

hwnd: w32.HWND,
parent: w32.HWND,
/// Auto-reset: one wake per batch of reasons, however many arrived.
wake: w32.HANDLE,
/// Manual-reset: the thread has finished creating its context (or failed).
ready: w32.HANDLE,
thread: ?std.Thread = null,
stop: std.atomic.Value(bool) = .init(false),

/// The context, once the thread has made it. Pane renderers join its share
/// group from step 3c. Null when creation failed: the caller then keeps the
/// per-pane path.
context: ?gl_robust.Created = null,

/// What the thread composes, written by the UI thread's layout pass.
mutex: std.Thread.Mutex = .{},
panes: [MAX_PANES]core.Rect = undefined,
pane_len: usize = 0,
client_w: u32 = 0,
client_h: u32 = 0,
bg: [4]f32,

/// Composes done, for the log and the acceptance oracle.
composes: std.atomic.Value(u64) = .init(0),
/// What the last debug self-check reported, so it logs on a change only.
last_check: [5]usize = .{ std.math.maxInt(usize), 0, 0, 0, 0 },
overflow_logged: bool = false,

var class_atom: u16 = 0;

fn registerClass(hinstance: w32.HINSTANCE) bool {
    if (class_atom != 0) return true;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // A DC for life, which the thread's context is made current on.
        .style = w32.CS_OWNDC,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    class_atom = w32.RegisterClassExW(&wc);
    return class_atom != 0;
}

/// Create the presenter for top-level `parent` and wait (bounded) for its
/// thread to make the context. UI thread only. Null when any part of it
/// fails; the window then presents per pane, as before.
pub fn create(
    alloc: std.mem.Allocator,
    hinstance: w32.HINSTANCE,
    parent: w32.HWND,
    bg: [4]f32,
) ?*WindowPresenter {
    if (comptime builtin.os.tag != .windows) return null;
    if (!registerClass(hinstance)) {
        log.warn("window presenter: class registration failed", .{});
        return null;
    }
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(parent, &client) == 0) return null;

    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_CLIPSIBLINGS | w32.WS_VISIBLE_STYLE,
        0,
        0,
        @max(client.right - client.left, 1),
        @max(client.bottom - client.top, 1),
        parent,
        null,
        hinstance,
        null,
    ) orelse {
        log.warn("window presenter: CreateWindowExW failed", .{});
        return null;
    };
    // An empty region until the first layout pass names the panes, so the
    // presenter never covers anything it has not composed.
    if (w32.CreateRectRgn(0, 0, 0, 0)) |rgn| _ = w32.SetWindowRgn(hwnd, rgn, 0);

    const wake = w32.CreateEventW(null, 0, 0, null) orelse {
        _ = w32.DestroyWindow(hwnd);
        return null;
    };
    const ready = w32.CreateEventW(null, 1, 0, null) orelse {
        _ = w32.CloseHandle(wake);
        _ = w32.DestroyWindow(hwnd);
        return null;
    };

    const self = alloc.create(WindowPresenter) catch {
        _ = w32.CloseHandle(ready);
        _ = w32.CloseHandle(wake);
        _ = w32.DestroyWindow(hwnd);
        return null;
    };
    self.* = .{ .hwnd = hwnd, .parent = parent, .wake = wake, .ready = ready, .bg = bg };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |err| {
        log.warn("window presenter: thread spawn failed: {}", .{err});
        self.destroyHandles(alloc);
        return null;
    };
    // The pane that asked for the presenter is about to make its own
    // context, and from step 3c that context joins this one's group, so the
    // group has to exist first. Bounded: a driver that hangs here must not
    // hang the UI.
    _ = w32.WaitForSingleObject(ready, 5000);
    if (self.context == null) {
        log.warn("window presenter: no GL context; the window presents per pane", .{});
        self.destroy(alloc);
        return null;
    }
    log.info("window presenter created hwnd=0x{x} robust={}", .{ @intFromPtr(hwnd), self.context.?.robust });
    return self;
}

/// Stop the thread, then take the window down. UI thread only, and before
/// the parent's children are destroyed (the parent's `WM_DESTROY`): the
/// thread's context is current on this window's DC until it exits.
pub fn destroy(self: *WindowPresenter, alloc: std.mem.Allocator) void {
    self.stop.store(true, .release);
    _ = w32.SetEvent(self.wake);
    if (self.thread) |t| t.join();
    self.thread = null;
    self.destroyHandles(alloc);
}

fn destroyHandles(self: *WindowPresenter, alloc: std.mem.Allocator) void {
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    _ = w32.CloseHandle(self.ready);
    _ = w32.CloseHandle(self.wake);
    alloc.destroy(self);
}

/// Ask the thread for a compose.
pub fn requestCompose(self: *WindowPresenter) void {
    _ = w32.SetEvent(self.wake);
}

/// Follow a layout pass. UI thread only: walk the parent's children, put the
/// presenter directly above the topmost terminal pane (`presenterZFix`),
/// size it to the parent's client, set its region to the union of the
/// visible terminal panes, hand the thread their rectangles and ask it to
/// compose. Cheap enough for every pass: one walk of the children and one
/// region.
pub fn sync(self: *WindowPresenter) void {
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(self.parent, &client) == 0) return;
    const cw = @max(client.right - client.left, 1);
    const ch = @max(client.bottom - client.top, 1);

    var walk: [MAX_PANES * 2]core.ZChild = undefined;
    var walk_hwnd: [MAX_PANES * 2]w32.HWND = undefined;
    var walk_len: usize = 0;
    var rects: [MAX_PANES]core.Rect = undefined;
    var pane_hwnds: [MAX_PANES]w32.HWND = undefined;
    var n: usize = 0;
    var overflow = false;

    // Owned by the window once `SetWindowRgn` takes it, below.
    const rgn = w32.CreateRectRgn(0, 0, 0, 0);

    var child = w32.GetWindow(self.parent, w32.GW_CHILD);
    while (child) |c| : (child = w32.GetWindow(c, w32.GW_HWNDNEXT)) {
        const kind: core.ZChild = if (c == self.hwnd) .presenter else if (isTerminal(c)) .terminal else .other;
        if (walk_len < walk.len) {
            walk[walk_len] = kind;
            walk_hwnd[walk_len] = c;
            walk_len += 1;
        }
        if (kind != .terminal or w32.IsWindowVisible(c) == 0) continue;
        var wr: w32.RECT = undefined;
        if (w32.GetWindowRect(c, &wr) == 0) continue;
        var pts = [2]w32.POINT{ .{ .x = wr.left, .y = wr.top }, .{ .x = wr.right, .y = wr.bottom } };
        _ = w32.MapWindowPoints(null, self.parent, &pts, 2);
        if (n == MAX_PANES) {
            overflow = true;
            continue;
        }
        rects[n] = .{ .left = pts[0].x, .top = pts[0].y, .right = pts[1].x, .bottom = pts[1].y };
        pane_hwnds[n] = c;
        if (rgn) |dst| if (w32.CreateRectRgn(pts[0].x, pts[0].y, pts[1].x, pts[1].y)) |one| {
            _ = w32.CombineRgn(dst, dst, one, w32.RGN_OR);
            _ = w32.DeleteObject(one);
        };
        n += 1;
    }
    if (overflow and !self.overflow_logged) {
        self.overflow_logged = true;
        log.warn("window presenter: more than {d} terminal panes; the rest show background", .{MAX_PANES});
    }

    var insert: ?w32.HWND = null; // HWND_TOP
    var zorder = true;
    switch (core.presenterZFix(walk[0..walk_len])) {
        .keep => zorder = false,
        .top => {},
        .after => |i| insert = walk_hwnd[i],
    }
    const flags: u32 = w32.SWP_NOACTIVATE | w32.SWP_NOOWNERZORDER | w32.SWP_NOREDRAW |
        (if (zorder) 0 else w32.SWP_NOZORDER);
    _ = w32.SetWindowPos(self.hwnd, insert, 0, 0, cw, ch, flags);
    // bRedraw FALSE: the compose below repaints it, and a redraw here would
    // be a GDI erase of a GL window.
    if (rgn) |r| {
        if (w32.SetWindowRgn(self.hwnd, r, 0) == 0) _ = w32.DeleteObject(r);
    }

    self.mutex.lock();
    @memcpy(self.panes[0..n], rects[0..n]);
    self.pane_len = n;
    self.client_w = @intCast(cw);
    self.client_h = @intCast(ch);
    self.mutex.unlock();
    self.requestCompose();

    if (comptime builtin.mode == .Debug) self.selfCheck(rects[0..n], pane_hwnds[0..n]);
}

/// Debug-build oracle for `test\win32\window-presenter.ps1`: where does a
/// hit at each pane's center land, and is each pane fully covered (an empty
/// visible region, so it never paints)? Asked here, on the UI thread, because
/// `HTTRANSPARENT` is honored for windows of the calling thread only, so the
/// question cannot be asked from another process. A hit is counted as
/// reaching the PANE, the PRESENTER (the defect: it took the input), or
/// another top-level that overlaps this one at that point (no verdict either
/// way). Logs on a change only.
fn selfCheck(self: *WindowPresenter, rects: []const core.Rect, hwnds: []const w32.HWND) void {
    var through: usize = 0;
    var on_presenter: usize = 0;
    var occluded: usize = 0;
    var covered: usize = 0;
    for (rects, hwnds) |r, h| {
        var pt = [1]w32.POINT{.{ .x = @divTrunc(r.left + r.right, 2), .y = @divTrunc(r.top + r.bottom, 2) }};
        _ = w32.MapWindowPoints(self.parent, null, &pt, 1);
        const hit = w32.WindowFromPoint(pt[0]);
        if (hit == h) {
            through += 1;
        } else if (hit == self.hwnd) {
            on_presenter += 1;
        } else if (hit) |other| {
            if (w32.GetAncestor(other, w32.GA_ROOT) != self.parent) occluded += 1;
        }
        if (w32.GetDCEx(h, null, w32.DCX_CACHE | w32.DCX_CLIPSIBLINGS)) |dc| {
            var box: w32.RECT = undefined;
            if (w32.GetClipBox(dc, &box) == NULLREGION) covered += 1;
            _ = w32.ReleaseDC(h, dc);
        }
    }
    const now = [5]usize{ rects.len, through, on_presenter, occluded, covered };
    if (std.mem.eql(usize, &now, &self.last_check)) return;
    self.last_check = now;
    log.info("window presenter check panes={d} hit_through={d} hit_presenter={d} occluded={d} covered={d}", .{ now[0], now[1], now[2], now[3], now[4] });
}

const NULLREGION: i32 = 1;

fn isTerminal(h: w32.HWND) bool {
    var cls: [32]u16 = undefined;
    const len = w32.GetClassNameW(h, &cls, cls.len);
    if (len <= 0) return false;
    return std.mem.eql(u16, cls[0..@intCast(len)], App.TERMINAL_CLASS_NAME);
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        // Every hit goes to the terminal pane beneath, on this (the UI)
        // thread: input, the cursor, mouse activation and drag-drop targets.
        w32.WM_NCHITTEST => return w32.HTTRANSPARENT,
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_ERASEBKGND => return 1,
        w32.WM_PAINT => {
            // Validate and let the thread draw: GL, not GDI, owns these
            // pixels.
            var ps: w32.PAINTSTRUCT = undefined;
            _ = w32.BeginPaint(hwnd, &ps);
            _ = w32.EndPaint(hwnd, &ps);
            const ptr = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
            if (ptr != 0) {
                const self: *WindowPresenter = @ptrFromInt(@as(usize, @bitCast(ptr)));
                self.requestCompose();
            }
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// -------------------------------------------------------------------------
// The presenter thread.
// -------------------------------------------------------------------------

const GLenum = u32;
const GLbitfield = u32;
const GL_SCISSOR_TEST: GLenum = 0x0C11;
const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;

const Gl = struct {
    viewport: *const fn (i32, i32, i32, i32) callconv(.winapi) void,
    scissor: *const fn (i32, i32, i32, i32) callconv(.winapi) void,
    enable: *const fn (GLenum) callconv(.winapi) void,
    disable: *const fn (GLenum) callconv(.winapi) void,
    clearColor: *const fn (f32, f32, f32, f32) callconv(.winapi) void,
    clear: *const fn (GLbitfield) callconv(.winapi) void,
    swapInterval: ?*const fn (i32) callconv(.winapi) i32,

    fn load() ?Gl {
        const api = gl_loader.active();
        return .{
            .viewport = @ptrCast(api.proc("glViewport") orelse return null),
            .scissor = @ptrCast(api.proc("glScissor") orelse return null),
            .enable = @ptrCast(api.proc("glEnable") orelse return null),
            .disable = @ptrCast(api.proc("glDisable") orelse return null),
            .clearColor = @ptrCast(api.proc("glClearColor") orelse return null),
            .clear = @ptrCast(api.proc("glClear") orelse return null),
            .swapInterval = if (api.proc("wglSwapIntervalEXT")) |p| @ptrCast(p) else null,
        };
    }
};

fn threadMain(self: *WindowPresenter) void {
    const api = gl_loader.active();
    const hdc = w32.GetDC(self.hwnd) orelse {
        log.warn("window presenter: GetDC failed", .{});
        _ = w32.SetEvent(self.ready);
        return;
    };
    defer _ = w32.ReleaseDC(self.hwnd, hdc);

    Surface.setupGlPixelFormat(hdc) catch {
        log.warn("window presenter: pixel format failed", .{});
        _ = w32.SetEvent(self.ready);
        return;
    };
    const created = gl_robust.createContext(@ptrCast(hdc)) orelse {
        log.warn("window presenter: context creation failed", .{});
        _ = w32.SetEvent(self.ready);
        return;
    };
    defer _ = api.deleteContext(created.hglrc);
    if (api.makeCurrent(@ptrCast(hdc), created.hglrc) == 0) {
        log.warn("window presenter: makeCurrent failed", .{});
        _ = w32.SetEvent(self.ready);
        return;
    }
    defer _ = api.makeCurrent(null, null);
    const gl = Gl.load() orelse {
        log.warn("window presenter: GL 1.1 entry points missing", .{});
        _ = w32.SetEvent(self.ready);
        return;
    };
    // One swap per vblank serves every pane of the window: the throttle each
    // pane's own swap used to give its renderer (design note, frame path 3).
    if (gl.swapInterval) |si| _ = si(1);

    self.context = created;
    _ = w32.SetEvent(self.ready);

    while (true) {
        _ = w32.WaitForSingleObject(self.wake, w32.INFINITE);
        if (self.stop.load(.acquire)) break;
        self.compose(gl, hdc);
    }
}

fn compose(self: *WindowPresenter, gl: Gl, hdc: w32.HDC) void {
    var rects: [MAX_PANES]core.Rect = undefined;
    self.mutex.lock();
    const n = self.pane_len;
    @memcpy(rects[0..n], self.panes[0..n]);
    const w = self.client_w;
    const h = self.client_h;
    const bg = self.bg;
    self.mutex.unlock();
    if (w == 0 or h == 0) return;

    gl.viewport(0, 0, @intCast(w), @intCast(h));
    gl.enable(GL_SCISSOR_TEST);
    gl.clearColor(bg[0], bg[1], bg[2], bg[3]);
    for (rects[0..n]) |r| {
        // No frames until step 3c: every pane is its background.
        const plan = core.planPane(r, null, h);
        for (plan.fills[0..plan.fill_len]) |f| {
            gl.scissor(f[0], f[1], f[2] - f[0], f[3] - f[1]);
            gl.clear(GL_COLOR_BUFFER_BIT);
        }
    }
    gl.disable(GL_SCISSOR_TEST);
    _ = gl_loader.active().swapBuffers(@ptrCast(hdc));

    const done = self.composes.fetchAdd(1, .monotonic) + 1;
    if (done == 1) log.info("window presenter composed panes={d} client={d}x{d}", .{ n, w, h });
}
