//! The quick terminal's slide, off the UI thread (T2766, composition step
//! 5d-6). The numbers are `quick_terminal_slide.zig`; this is the thread and
//! the window that carry them.
//!
//! One slider per quick terminal, created on its first slide. It owns a
//! thread, and that thread owns a host window: a topmost, non-activating,
//! click-through popup over the slide's travel area (clipped to the monitor)
//! with no redirection bitmap, so the only thing it ever shows is a live DWM
//! thumbnail of the quick terminal. The quick terminal itself sits at its
//! final rect, CLOAKED, for the length of the slide - composed by DWM, so
//! the thumbnail is live, but not drawn and taking no input.
//!
//! Each frame the thread reads the plan, moves the thumbnail's destination
//! to where the window would be, and waits for the next composition
//! (`DwmFlush`). Nothing it does goes through the UI thread, so a busy UI
//! thread cannot freeze the slide: it keeps moving, and once it lands the
//! host keeps showing the live window there until the UI thread takes it
//! back (`release`).
//!
//! The UI thread talks to it through `start`, `reverse` and `release`; it
//! answers with one posted `WM_APP_QT_SLIDE` per slide (wParam = the slide's
//! generation, lParam = a `Status`). A slide the thread cannot carry - the
//! host or the thumbnail could not be made, the cloak was refused - answers
//! `.failed` with the host already down, and the quick terminal steps the
//! rest of it on its frame clock as before.
//!
//! Why a thumbnail and not a DirectComposition visual: DComp cannot move a
//! top-level window, and the window's own root visual would leave the panes
//! behind - each terminal pane composes on its OWN child window's target
//! (`renderer/gl_comp_present.zig`). A DWM thumbnail is the one compositor
//! object that shows a whole top-level window, children and all, wherever we
//! put it.
const Slider = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("win32.zig");
const slide = @import("quick_terminal_slide.zig");

const log = std.log.scoped(.win32_quick_terminal);

pub const Rect = slide.Rect;
pub const Direction = slide.Direction;

/// The slider's one message to the UI thread, posted to `App.msg_hwnd`.
/// WM_APP+43 is FrameClock's; nothing else takes +44.
pub const WM_APP_QT_SLIDE: u32 = w32.WM_APP + 44;

pub const Status = enum(isize) {
    /// An in slide reached the target; the host shows the live window there
    /// until `release`.
    in_done = 0,
    /// An out slide reached hidden; the host is already down.
    out_done = 1,
    /// The thread could not carry the slide; the host is already down.
    failed = 2,
};

pub const Plan = struct {
    hidden: Rect,
    target: Rect,
    host: Rect,
    dir: Direction,
    /// QueryPerformanceCounter value the slide's progress counts from.
    start_qpc: i64,
    duration_s: f64,
};

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyQuickSlide");

alloc: Allocator,
qt_hwnd: w32.HWND,
notify_hwnd: w32.HWND,
perf_freq: i64,
thread: ?std.Thread = null,
/// Auto-reset; set whenever the shared state below changes.
event: w32.HANDLE,

mutex: std.Thread.Mutex = .{},
// Shared, under `mutex`.
plan: Plan = undefined,
gen: u32 = 0,
release_gen: u32 = 0,
quit: bool = false,

/// Frames the thread composed for the last slide that finished, and over how
/// many milliseconds (the log and the harness read these).
last_frames: std.atomic.Value(u32) = .init(0),
last_ms: std.atomic.Value(u32) = .init(0),

// The thread's own. Nothing else touches these.
host: ?w32.HWND = null,
host_rect: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
host_shown: bool = false,
thumb: ?*anyopaque = null,
/// Why the last slide failed, for the UI thread's log line (written before
/// the post, read after it).
fail_stage: [:0]const u8 = "",
fail_hr: i32 = 0,

pub fn create(alloc: Allocator, qt_hwnd: w32.HWND, notify_hwnd: w32.HWND) !*Slider {
    const self = try alloc.create(Slider);
    errdefer alloc.destroy(self);
    const ev = w32.CreateEventW(null, 0, 0, null) orelse return error.Unavailable;
    errdefer _ = w32.CloseHandle(ev);
    var freq: i64 = 1;
    _ = w32.QueryPerformanceFrequency(&freq);
    self.* = .{
        .alloc = alloc,
        .qt_hwnd = qt_hwnd,
        .notify_hwnd = notify_hwnd,
        .perf_freq = if (freq > 0) freq else 1,
        .event = ev,
    };
    self.thread = try std.Thread.spawn(.{}, run, .{self});
    return self;
}

/// Stop the thread (it takes its host window down with it) and free.
pub fn destroy(self: *Slider) void {
    self.mutex.lock();
    self.quit = true;
    self.mutex.unlock();
    _ = w32.SetEvent(self.event);
    if (self.thread) |t| t.join();
    _ = w32.CloseHandle(self.event);
    self.alloc.destroy(self);
}

/// Begin a slide. Returns its generation; the answer for it carries the same.
pub fn start(self: *Slider, plan: Plan) u32 {
    self.mutex.lock();
    self.plan = plan;
    self.gen +%= 1;
    const g = self.gen;
    self.mutex.unlock();
    _ = w32.SetEvent(self.event);
    return g;
}

/// Turn the running slide round: same rects, a new direction and the start
/// the UI thread credited it with (`quick_terminal_slide.reversedElapsed`).
/// A new generation, so the answer to the old one (if already posted) is
/// recognisably stale.
pub fn reverse(self: *Slider, dir: Direction, start_qpc: i64) u32 {
    self.mutex.lock();
    self.plan.dir = dir;
    self.plan.start_qpc = start_qpc;
    self.gen +%= 1;
    const g = self.gen;
    self.mutex.unlock();
    _ = w32.SetEvent(self.event);
    return g;
}

/// The UI thread has the window an in slide (`gen`) landed uncloaked: take
/// the host down - unless a newer slide has it by then.
pub fn release(self: *Slider, gen: u32) void {
    self.mutex.lock();
    self.release_gen = gen;
    self.mutex.unlock();
    _ = w32.SetEvent(self.event);
}

// -----------------------------------------------------------------------
// The thread
// -----------------------------------------------------------------------

fn run(self: *Slider) void {
    var seen_gen: u32 = 0;
    var seen_release: u32 = 0;
    while (true) {
        self.mutex.lock();
        const quit = self.quit;
        const g = self.gen;
        const rel = self.release_gen;
        self.mutex.unlock();
        if (quit) break;
        if (g != seen_gen) {
            seen_gen = self.runSlide();
            continue;
        }
        if (rel != seen_release) {
            seen_release = rel;
            // Only the slide this thread last answered: a release that lost
            // a race with a newer slide is that slide's to undo, not this.
            if (rel == seen_gen) {
                // One composition with the window uncloaked under the host,
                // so taking the host down never shows a frame of neither.
                _ = w32.DwmFlush();
                self.hideHost();
            }
            continue;
        }
        // Idle: the event, or a message for the host (a broadcast must never
        // hang on a window whose thread is asleep).
        _ = w32.MsgWaitForMultipleObjects(1, @ptrCast(&self.event), 0, w32.INFINITE, w32.QS_ALLINPUT);
        self.pump();
    }
    self.hideHost();
    if (self.host) |h| _ = w32.DestroyWindow(h);
    self.host = null;
}

/// Carry the slide to its end, following reversals. Returns the generation
/// it answered.
fn runSlide(self: *Slider) u32 {
    var frames: u32 = 0;
    const t0 = self.now();
    var cloaked = false;
    self.fail_stage = "";
    self.fail_hr = 0;
    while (true) {
        self.mutex.lock();
        const plan = self.plan;
        const g = self.gen;
        const quit = self.quit;
        self.mutex.unlock();
        if (quit) return g;

        if (!self.ensureHost(plan)) return self.fail(g);
        const el = @as(f64, @floatFromInt(self.now() - plan.start_qpc)) / @as(f64, @floatFromInt(self.perf_freq));
        const p = slide.progressAt(el, plan.duration_s);
        const r = slide.slideRect(plan.hidden, plan.target, slide.easedT(p, plan.dir));
        if (!self.place(r)) return self.fail(g);
        if (!self.host_shown) {
            _ = w32.SetWindowPos(self.host.?, w32.HWND_TOPMOST, 0, 0, 0, 0, w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW);
            self.host_shown = true;
        }
        // Wait for the composition that shows this frame.
        if (w32.DwmFlush() < 0) std.Thread.sleep(8 * std.time.ns_per_ms);
        if (!cloaked) {
            // The thumbnail is on screen now, so the window can go: an out
            // slide starts with it uncloaked (an in slide's UI thread cloaked
            // it before showing it, and this is then a no-op).
            const on: i32 = 1;
            const hr = w32.DwmSetWindowAttribute(self.qt_hwnd, w32.DWMWA_CLOAK, &on, @sizeOf(i32));
            if (hr < 0) {
                self.fail_stage = "cloak";
                self.fail_hr = hr;
                return self.fail(g);
            }
            cloaked = true;
        }
        self.pump();
        frames +|= 1;
        if (p >= 1.0) {
            self.mutex.lock();
            const turned = self.gen != g;
            self.mutex.unlock();
            if (turned) continue;
            const ms = @as(f64, @floatFromInt(self.now() - t0)) * 1000.0 / @as(f64, @floatFromInt(self.perf_freq));
            self.last_frames.store(frames, .release);
            self.last_ms.store(@intFromFloat(@max(ms, 0)), .release);
            const status: Status = switch (plan.dir) {
                .in => .in_done,
                .out => blk: {
                    self.hideHost();
                    break :blk .out_done;
                },
            };
            _ = w32.PostMessageW(self.notify_hwnd, WM_APP_QT_SLIDE, g, @intFromEnum(status));
            return g;
        }
    }
}

fn fail(self: *Slider, g: u32) u32 {
    if (self.fail_stage.len == 0) self.fail_stage = "unknown";
    self.hideHost();
    _ = w32.PostMessageW(self.notify_hwnd, WM_APP_QT_SLIDE, g, @intFromEnum(Status.failed));
    return g;
}

/// The host window at the plan's travel rect, with a thumbnail of the quick
/// terminal registered on it.
fn ensureHost(self: *Slider, plan: Plan) bool {
    if (self.host == null) {
        const hinst = w32.GetModuleHandleW(null);
        const wc: w32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = hostProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinst,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CLASS_NAME,
            .hIconSm = null,
        };
        // A second quick terminal (after the first's shell exited) registers
        // again; the class is already there and that is fine.
        _ = w32.RegisterClassExW(&wc);
        const r = plan.host;
        self.host = w32.CreateWindowExW(
            w32.WS_EX_TOPMOST | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE |
                w32.WS_EX_NOREDIRECTIONBITMAP | w32.WS_EX_TRANSPARENT,
            CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty quick terminal slide"),
            w32.WS_POPUP,
            r.left,
            r.top,
            r.width(),
            r.height(),
            null,
            null,
            hinst,
            null,
        );
        if (self.host == null) {
            self.fail_stage = "host";
            self.fail_hr = @bitCast(w32.GetLastError());
            return false;
        }
        self.host_rect = r;
        self.host_shown = false;
    }
    const host = self.host.?;
    if (!std.meta.eql(self.host_rect, plan.host)) {
        const r = plan.host;
        _ = w32.SetWindowPos(host, w32.HWND_TOPMOST, r.left, r.top, r.width(), r.height(), w32.SWP_NOACTIVATE);
        self.host_rect = r;
    }
    if (self.thumb == null) {
        var th: ?*anyopaque = null;
        const hr = w32.DwmRegisterThumbnail(host, self.qt_hwnd, &th);
        if (hr < 0 or th == null) {
            self.fail_stage = "thumbnail";
            self.fail_hr = hr;
            return false;
        }
        self.thumb = th;
    }
    return true;
}

/// Put the thumbnail where the window is at `r` (screen coordinates).
fn place(self: *Slider, r: Rect) bool {
    const th = self.thumb orelse return false;
    const props = slide.thumbProps(.{
        .dest = slide.destInHost(r, self.host_rect),
        .source = .{ .left = 0, .top = 0, .right = r.width(), .bottom = r.height() },
    });
    const hr = w32.DwmUpdateThumbnailProperties(th, &props);
    if (hr < 0) {
        self.fail_stage = "thumbnail-props";
        self.fail_hr = hr;
        return false;
    }
    return true;
}

fn hideHost(self: *Slider) void {
    if (self.thumb) |th| _ = w32.DwmUnregisterThumbnail(th);
    self.thumb = null;
    if (self.host) |h| {
        if (self.host_shown) {
            _ = w32.SetWindowPos(h, null, 0, 0, 0, 0, w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE | w32.SWP_HIDEWINDOW);
        }
    }
    self.host_shown = false;
}

fn pump(self: *Slider) void {
    _ = self;
    var m: w32.MSG = undefined;
    while (w32.PeekMessageW(&m, null, 0, 0, w32.PM_REMOVE) != 0) {
        _ = w32.TranslateMessage(&m);
        _ = w32.DispatchMessageW(&m);
    }
}

fn now(_: *const Slider) i64 {
    var c: i64 = 0;
    _ = w32.QueryPerformanceCounter(&c);
    return c;
}

fn hostProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        // The host is a picture of the quick terminal, never a target: a
        // click in the few frames of a slide is not the quick terminal's.
        w32.WM_NCHITTEST => return w32.HTTRANSPARENT,
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
