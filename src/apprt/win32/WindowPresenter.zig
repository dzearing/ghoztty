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
//! - From step 3c (T2615) each terminal pane's renderer stops swapping: its
//!   context is current on a hidden helper window (`createHelper`), shares
//!   this one's group, blits each frame into one of two slot textures and
//!   publishes it through the pane's `PaneLink`. The compose blits the newest
//!   frame of every visible pane into its rectangle and swaps once. The knob
//!   is off by default.
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
/// The share handshake (`createSharedContext`). Auto-reset both: the thread
/// sets `share_paused` once its context is current nowhere, and waits on
/// `share_done` before making it current again.
share_req: std.atomic.Value(bool) = .init(false),
share_paused: w32.HANDLE,
share_done: w32.HANDLE,
thread: ?std.Thread = null,
stop: std.atomic.Value(bool) = .init(false),

/// The context, once the thread has made it. Pane renderers join its share
/// group from step 3c. Null when creation failed: the caller then keeps the
/// per-pane path.
context: ?gl_robust.Created = null,

/// What the thread composes, written by the UI thread's layout pass. Also
/// guards `links`, and the compose holds it throughout, so once `unlink`
/// returns the presenter never touches that pane's textures again.
mutex: std.Thread.Mutex = .{},
panes: [MAX_PANES]core.Rect = undefined,
pane_hwnds: [MAX_PANES]w32.HWND = undefined,
pane_len: usize = 0,
/// One per terminal pane whose renderer hands frames over (T2615).
links: std.ArrayListUnmanaged(*PaneLink) = .empty,
alloc: std.mem.Allocator,
client_w: u32 = 0,
client_h: u32 = 0,
bg: [4]f32,

/// Composes done, for the log and the acceptance oracle.
composes: std.atomic.Value(u64) = .init(0),
/// What the last debug self-check reported, so it logs on a change only.
last_check: [5]usize = .{ std.math.maxInt(usize), 0, 0, 0, 0 },
overflow_logged: bool = false,
/// Presenter thread only: the first compose that blitted a pane frame has
/// been logged (the acceptance oracle's line).
first_frame_logged: bool = false,
/// Debug builds: `probeCenters` is on (`GHOZTTY_PRESENTER_PROBE`), and what it
/// last logged.
probe: bool = false,
probe_last: [4]u32 = .{ 0, 0, 0, 0 },
probe_len: usize = std.math.maxInt(usize),

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
    const share_paused = w32.CreateEventW(null, 0, 0, null) orelse {
        _ = w32.CloseHandle(ready);
        _ = w32.CloseHandle(wake);
        _ = w32.DestroyWindow(hwnd);
        return null;
    };
    const share_done = w32.CreateEventW(null, 0, 0, null) orelse {
        _ = w32.CloseHandle(share_paused);
        _ = w32.CloseHandle(ready);
        _ = w32.CloseHandle(wake);
        _ = w32.DestroyWindow(hwnd);
        return null;
    };

    const self = alloc.create(WindowPresenter) catch {
        _ = w32.CloseHandle(share_done);
        _ = w32.CloseHandle(share_paused);
        _ = w32.CloseHandle(ready);
        _ = w32.CloseHandle(wake);
        _ = w32.DestroyWindow(hwnd);
        return null;
    };
    self.* = .{
        .hwnd = hwnd,
        .parent = parent,
        .wake = wake,
        .ready = ready,
        .share_paused = share_paused,
        .share_done = share_done,
        .bg = bg,
        .alloc = alloc,
    };
    if (comptime builtin.mode == .Debug) self.probe = probeEnabled();
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
    self.detachLinks();
    self.destroyHandles(alloc);
}

/// The window goes before its panes' renderers stop (`Window` destroys the
/// presenter first), so every link forgets this presenter and every renderer
/// waiting on one is woken: from here its frames go nowhere, which is right
/// for a window that is being destroyed.
fn detachLinks(self: *WindowPresenter) void {
    self.mutex.lock();
    var links = self.links;
    self.links = .empty;
    self.mutex.unlock();
    for (links.items) |l| {
        // `unlink` holds the link's lock across its use of this presenter,
        // so taking it here is what makes freeing the presenter safe.
        l.mutex.lock();
        l.presenter = null;
        l.mutex.unlock();
        _ = w32.SetEvent(l.signal);
    }
    links.deinit(self.alloc);
}

// -------------------------------------------------------------------------
// Pane links (T2615): one per terminal pane renderer on this path.
// -------------------------------------------------------------------------

/// The handoff between one pane's renderer and its window's presenter. Made
/// by the surface on the UI thread (`link`), used by the renderer thread,
/// forgotten by the renderer thread as it exits (`unlink`) and freed by the
/// surface after that (`freeLink`).
pub const PaneLink = struct {
    hwnd: w32.HWND,
    slots: core.SlotPair = .{},
    /// The two slot textures, names in the window's share group. The renderer
    /// creates and sizes them; the presenter only samples the one it took.
    /// A slot's name is written before the slot is published, and the
    /// SlotPair's lock orders that write before the presenter's read.
    tex: [2]u32 = .{ 0, 0 },
    /// Guards `presenter`. Taken BEFORE the presenter's lock (`unlink`),
    /// never while holding it.
    mutex: std.Thread.Mutex = .{},
    presenter: ?*WindowPresenter,
    /// Guards `release`. A leaf: the compose takes it under the presenter's
    /// lock, and nothing is taken while holding it.
    rel_mutex: std.Thread.Mutex = .{},
    /// Fences the presenter set behind the composes that read a slot it has
    /// since let go of. The renderer waits on one before drawing into that
    /// slot again, and deletes it.
    release: [2]usize = .{ 0, 0 },
    /// Auto-reset: set when the presenter has taken a frame (so `acquire`
    /// can succeed) or has gone.
    signal: w32.HANDLE,

    /// The renderer published a frame: ask for a compose. False when the
    /// presenter is gone.
    pub fn notify(self: *PaneLink) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.presenter orelse return false;
        p.requestCompose();
        return true;
    }

    pub fn attached(self: *PaneLink) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.presenter != null;
    }

    /// Hand the renderer the release fence for `slot`, if the presenter set
    /// one. The renderer owns it from here.
    pub fn takeRelease(self: *PaneLink, slot: u1) usize {
        self.rel_mutex.lock();
        defer self.rel_mutex.unlock();
        const f = self.release[slot];
        self.release[slot] = 0;
        return f;
    }

    /// Every fence and texture name the link still carries, for the
    /// renderer to delete as it exits, with its context current.
    pub const Leftovers = struct { fences: [4]usize, tex: [2]u32 };

    /// Renderer thread, as it exits: stop the presenter from composing this
    /// pane, and hand back what is left to delete. Once this returns the
    /// presenter never touches the link's textures again: the compose holds
    /// the presenter's lock throughout, and this takes it to drop the link.
    pub fn unlink(self: *PaneLink) Leftovers {
        self.mutex.lock();
        if (self.presenter) |p| {
            p.mutex.lock();
            for (p.links.items, 0..) |l, i| if (l == self) {
                _ = p.links.swapRemove(i);
                break;
            };
            p.mutex.unlock();
            p.requestCompose();
        }
        self.presenter = null;
        self.mutex.unlock();
        self.rel_mutex.lock();
        var out: Leftovers = .{ .fences = .{ self.release[0], self.release[1], 0, 0 }, .tex = self.tex };
        self.release = .{ 0, 0 };
        self.rel_mutex.unlock();
        for (self.slots.frames, 0..) |f, i| {
            if (f) |fr| out.fences[2 + i] = fr.fence;
        }
        self.slots.reset();
        self.tex = .{ 0, 0 };
        return out;
    }
};

/// Make the link for terminal pane `hwnd`. UI thread, at surface creation.
pub fn link(self: *WindowPresenter, hwnd: w32.HWND) ?*PaneLink {
    const signal = w32.CreateEventW(null, 0, 0, null) orelse return null;
    const l = self.alloc.create(PaneLink) catch {
        _ = w32.CloseHandle(signal);
        return null;
    };
    l.* = .{ .hwnd = hwnd, .presenter = self, .signal = signal };
    self.mutex.lock();
    defer self.mutex.unlock();
    self.links.append(self.alloc, l) catch {
        self.alloc.destroy(l);
        _ = w32.CloseHandle(signal);
        return null;
    };
    return l;
}

/// Free a link whose renderer has stopped (or never started). Unlinks it
/// first in case `unlink` never ran; the link's GL names are the renderer's
/// to delete, so anything still named here lives only as long as the share
/// group does.
pub fn freeLink(alloc: std.mem.Allocator, l: *PaneLink) void {
    _ = l.unlink();
    _ = w32.CloseHandle(l.signal);
    alloc.destroy(l);
}

/// A never-shown popup for a pane renderer's context to be current on, so
/// the pane window itself has no pixel format and no surface of its own
/// (the design note's `pres-helper` shape). The caller sets the pane pixel
/// format on its DC.
pub fn createHelper(hinstance: w32.HINSTANCE) ?w32.HWND {
    if (!registerClass(hinstance)) return null;
    return w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        0,
        1,
        1,
        null,
        null,
        hinstance,
        null,
    );
}

fn destroyHandles(self: *WindowPresenter, alloc: std.mem.Allocator) void {
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    _ = w32.CloseHandle(self.share_done);
    _ = w32.CloseHandle(self.share_paused);
    _ = w32.CloseHandle(self.ready);
    _ = w32.CloseHandle(self.wake);
    alloc.destroy(self);
}

/// Make a pane renderer's context on `hdc` in this presenter's share group
/// (T2615). UI thread, at surface creation.
///
/// The driver refuses to share with a context that is current on another
/// thread, and the presenter's is current on its own thread for life, so the
/// thread lets go of it for the moment the new context is made: it is asked
/// to (`share_req`), says it has (`share_paused`), and takes it back when
/// told (`share_done`). The T2599 spike never hit this because its presenter
/// context was current only while it presented. Bounded both ways: a thread
/// busy past the wait is answered with null, and the pane presents itself.
pub fn createSharedContext(self: *WindowPresenter, hdc: w32.HDC) ?gl_robust.Created {
    const share = self.context orelse return null;
    self.share_req.store(true, .release);
    _ = w32.SetEvent(self.wake);
    const paused = w32.WaitForSingleObject(self.share_paused, 2000) == w32.WAIT_OBJECT_0;
    const created: ?gl_robust.Created = if (paused) gl_robust.createSharedContext(@ptrCast(hdc), share) else null;
    const err = if (paused and created == null) w32.GetLastError() else 0;
    // Set even on a timeout: a thread that pauses late finds it already set
    // and takes its context straight back.
    _ = w32.SetEvent(self.share_done);
    if (!paused) log.warn("window presenter: its thread did not release its context in time", .{});
    if (paused and created == null) log.warn("window presenter: wglCreateContextAttribsARB refused to share (error {d})", .{err});
    return created;
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
    @memcpy(self.pane_hwnds[0..n], pane_hwnds[0..n]);
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
    // T2615: a pane that hands its frames over has no pixel format of its
    // own (its context is current on a helper), so it has no GL surface.
    var formatted: usize = 0;
    for (hwnds) |h| if (w32.GetDC(h)) |dc| {
        if (GetPixelFormat(dc) != 0) formatted += 1;
        _ = w32.ReleaseDC(h, dc);
    };
    log.info("window presenter panes={d} with_pixel_format={d}", .{ rects.len, formatted });
}

const NULLREGION: i32 = 1;

// Through GDI rather than the chosen GL implementation: the question is only
// whether the pane window carries a format at all, and a debug oracle.
extern "gdi32" fn GetPixelFormat(hdc: w32.HDC) callconv(.winapi) i32;

fn probeEnabled() bool {
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_PRESENTER_PROBE") catch return false;
    defer std.heap.page_allocator.free(raw);
    return std.mem.eql(u8, raw, "1");
}

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
const GL_FRAMEBUFFER_SRGB: GLenum = 0x8DB9;
const GL_READ_FRAMEBUFFER: GLenum = 0x8CA8;
const GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0;
const GL_TEXTURE_2D: GLenum = 0x0DE1;
const GL_NEAREST: GLenum = 0x2600;
const GL_SYNC_GPU_COMMANDS_COMPLETE: GLenum = 0x9117;
const GL_TIMEOUT_IGNORED: u64 = 0xFFFFFFFFFFFFFFFF;
const GL_RGBA: GLenum = 0x1908;
const GL_UNSIGNED_BYTE: GLenum = 0x1401;

const Gl = struct {
    viewport: *const fn (i32, i32, i32, i32) callconv(.winapi) void,
    scissor: *const fn (i32, i32, i32, i32) callconv(.winapi) void,
    enable: *const fn (GLenum) callconv(.winapi) void,
    disable: *const fn (GLenum) callconv(.winapi) void,
    clearColor: *const fn (f32, f32, f32, f32) callconv(.winapi) void,
    clear: *const fn (GLbitfield) callconv(.winapi) void,
    flush: *const fn () callconv(.winapi) void,
    readPixels: *const fn (i32, i32, i32, i32, GLenum, GLenum, *[4]u8) callconv(.winapi) void,
    swapInterval: ?*const fn (i32) callconv(.winapi) i32,
    // Frame handoff (T2615). GL 3.2 entry points, reached through the
    // context: absent on a GDI 1.1 context, where no pane frame is composed
    // and every pane shows its background.
    frames: ?struct {
        genFramebuffers: *const fn (i32, *u32) callconv(.winapi) void,
        bindFramebuffer: *const fn (GLenum, u32) callconv(.winapi) void,
        framebufferTexture2D: *const fn (GLenum, GLenum, GLenum, u32, i32) callconv(.winapi) void,
        blitFramebuffer: *const fn (i32, i32, i32, i32, i32, i32, i32, i32, GLbitfield, GLenum) callconv(.winapi) void,
        fenceSync: *const fn (GLenum, GLbitfield) callconv(.winapi) usize,
        waitSync: *const fn (usize, GLbitfield, u64) callconv(.winapi) void,
        deleteSync: *const fn (usize) callconv(.winapi) void,
    },

    fn load() ?Gl {
        const api = gl_loader.active();
        return .{
            .viewport = @ptrCast(api.proc("glViewport") orelse return null),
            .scissor = @ptrCast(api.proc("glScissor") orelse return null),
            .enable = @ptrCast(api.proc("glEnable") orelse return null),
            .disable = @ptrCast(api.proc("glDisable") orelse return null),
            .clearColor = @ptrCast(api.proc("glClearColor") orelse return null),
            .clear = @ptrCast(api.proc("glClear") orelse return null),
            .flush = @ptrCast(api.proc("glFlush") orelse return null),
            .readPixels = @ptrCast(api.proc("glReadPixels") orelse return null),
            .swapInterval = if (api.proc("wglSwapIntervalEXT")) |p| @ptrCast(p) else null,
            .frames = frames: {
                break :frames .{
                    .genFramebuffers = @ptrCast(api.proc("glGenFramebuffers") orelse break :frames null),
                    .bindFramebuffer = @ptrCast(api.proc("glBindFramebuffer") orelse break :frames null),
                    .framebufferTexture2D = @ptrCast(api.proc("glFramebufferTexture2D") orelse break :frames null),
                    .blitFramebuffer = @ptrCast(api.proc("glBlitFramebuffer") orelse break :frames null),
                    .fenceSync = @ptrCast(api.proc("glFenceSync") orelse break :frames null),
                    .waitSync = @ptrCast(api.proc("glWaitSync") orelse break :frames null),
                    .deleteSync = @ptrCast(api.proc("glDeleteSync") orelse break :frames null),
                };
            },
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
    // The one read framebuffer every pane's slot texture is attached to in
    // turn. FBOs are per context; the textures are the group's.
    var read_fbo: u32 = 0;
    if (gl.frames) |f| f.genFramebuffers(1, &read_fbo);
    if (gl.frames == null) log.warn("window presenter: no GL 3.2 blit/sync entry points; panes show background only", .{});

    self.context = created;
    _ = w32.SetEvent(self.ready);

    while (true) {
        _ = w32.WaitForSingleObject(self.wake, w32.INFINITE);
        if (self.stop.load(.acquire)) break;
        if (self.share_req.swap(false, .acq_rel)) {
            // A pane is joining the group (`createSharedContext`).
            _ = api.makeCurrent(null, null);
            _ = w32.SetEvent(self.share_paused);
            _ = w32.WaitForSingleObject(self.share_done, 5000);
            if (api.makeCurrent(@ptrCast(hdc), created.hglrc) == 0) {
                log.warn("window presenter: could not take its context back after a share", .{});
                break;
            }
        }
        self.compose(gl, hdc, read_fbo);
    }
}

/// A link a compose took a fresh frame from, and the slot that freed.
const Taken = struct { link: *PaneLink, released: ?u1 };

fn compose(self: *WindowPresenter, gl: Gl, hdc: w32.HDC, read_fbo: u32) void {
    // Held throughout, so an `unlink` waits for this compose to finish with
    // the pane's textures (`PaneLink.unlink`).
    self.mutex.lock();
    defer self.mutex.unlock();
    const n = self.pane_len;
    const w = self.client_w;
    const h = self.client_h;
    const bg = self.bg;
    if (w == 0 or h == 0) return;

    var taken: [MAX_PANES]Taken = undefined;
    var taken_len: usize = 0;
    var blitted: usize = 0;

    gl.viewport(0, 0, @intCast(w), @intCast(h));
    // The slot holds the renderer's sRGB-encoded values; copy them as they
    // are, the way the pane's own present did.
    gl.disable(GL_FRAMEBUFFER_SRGB);
    gl.clearColor(bg[0], bg[1], bg[2], bg[3]);
    for (self.panes[0..n], self.pane_hwnds[0..n]) |r, hwnd| {
        const l = self.findLink(hwnd);
        const t: ?core.SlotPair.Take = if (l != null and gl.frames != null) l.?.slots.take() else null;
        const plan = core.planPane(r, if (t) |tk| .{ .width = tk.frame.width, .height = tk.frame.height } else null, h);

        gl.enable(GL_SCISSOR_TEST);
        for (plan.fills[0..plan.fill_len]) |f| {
            gl.scissor(f[0], f[1], f[2] - f[0], f[3] - f[1]);
            gl.clear(GL_COLOR_BUFFER_BIT);
        }
        // A blit is scissored too, and its rectangle is already exact.
        gl.disable(GL_SCISSOR_TEST);

        const tk = t orelse continue;
        const fx = gl.frames.?;
        if (tk.fresh) {
            if (tk.frame.fence != 0) fx.waitSync(tk.frame.fence, 0, GL_TIMEOUT_IGNORED);
            taken[taken_len] = .{ .link = l.?, .released = tk.released };
            taken_len += 1;
        }
        const b = plan.blit orelse continue;
        const tex = l.?.tex[tk.slot];
        if (tex == 0) continue;
        fx.bindFramebuffer(GL_READ_FRAMEBUFFER, read_fbo);
        fx.framebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
        fx.blitFramebuffer(b.src[0], b.src[1], b.src[2], b.src[3], b.dst[0], b.dst[1], b.dst[2], b.dst[3], GL_COLOR_BUFFER_BIT, GL_NEAREST);
        // Detach, so this context holds no reference to a texture its
        // renderer may delete once it unlinks.
        fx.framebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        fx.bindFramebuffer(GL_READ_FRAMEBUFFER, 0);
        blitted += 1;
    }
    if (comptime builtin.mode == .Debug) {
        if (self.probe) self.probeCenters(gl, n);
    }
    _ = gl_loader.active().swapBuffers(@ptrCast(hdc));

    // Every slot this compose let go of may be drawn into again once the GPU
    // is past the composes that read it: fence it, and wake its renderer,
    // which is waiting for exactly this (`SlotPair.acquire`).
    if (gl.frames) |fx| {
        for (taken[0..taken_len]) |tk| {
            if (tk.released) |slot| {
                const fence = fx.fenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
                tk.link.rel_mutex.lock();
                const old = tk.link.release[slot];
                tk.link.release[slot] = fence;
                tk.link.rel_mutex.unlock();
                if (old != 0) fx.deleteSync(old);
            }
        }
        if (taken_len > 0) gl.flush();
    }
    for (taken[0..taken_len]) |tk| _ = w32.SetEvent(tk.link.signal);

    const done = self.composes.fetchAdd(1, .monotonic) + 1;
    if (done == 1) log.info("window presenter composed panes={d} client={d}x{d}", .{ n, w, h });
    if (blitted > 0 and !self.first_frame_logged) {
        self.first_frame_logged = true;
        log.info("window presenter composed a pane frame panes={d} blitted={d}", .{ n, blitted });
    }
}

/// Debug builds, `GHOZTTY_PRESENTER_PROBE=1`: read back the composed pixel at
/// each pane's center (the first four) and log the list when it changes.
/// The oracle `test\win32\window-presenter.ps1` uses to see a pane's frame
/// arrive in the back buffer this window swaps, on a test desktop DWM never
/// composes: a planted magenta frame (T2383) can only get there through the
/// renderer's slot. Caller holds `mutex`. A readback stalls the pipeline,
/// which is why it is opt-in.
fn probeCenters(self: *WindowPresenter, gl: Gl, n: usize) void {
    var now: [4]u32 = .{ 0, 0, 0, 0 };
    const k = @min(n, now.len);
    for (self.panes[0..k], 0..) |r, i| {
        const g = core.toGl(r, self.client_h);
        var px: [4]u8 = .{ 0, 0, 0, 0 };
        gl.readPixels(@divTrunc(g[0] + g[2], 2), @divTrunc(g[1] + g[3], 2), 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &px);
        now[i] = (@as(u32, px[0]) << 16) | (@as(u32, px[1]) << 8) | px[2];
    }
    if (k == self.probe_len and std.mem.eql(u32, now[0..k], self.probe_last[0..k])) return;
    self.probe_last = now;
    self.probe_len = k;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (now[0..k], 0..) |c, i| w.print("{s}{x:0>6}", .{ if (i == 0) "" else ",", c }) catch break;
    log.info("window presenter probe panes={d} centers={s}", .{ k, w.buffered() });
}

/// The link for pane `hwnd`, or null when its renderer does not hand frames
/// over. Caller holds `mutex`.
fn findLink(self: *WindowPresenter, hwnd: w32.HWND) ?*PaneLink {
    for (self.links.items) |l| if (l.hwnd == hwnd) return l;
    return null;
}
