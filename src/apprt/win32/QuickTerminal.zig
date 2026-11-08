//! Vendored from InsipidPoint/ghostty-windows (MIT, same license as upstream
//! Ghostty) and adapted for the Ghoztty fork (branding, fork apprt actions).
//! Quick Terminal: a borderless popup window that slides in/out from a
//! screen edge. Owned by App, separate from the normal windows list.
const QuickTerminal = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");

const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");
const FrameClock = @import("FrameClock.zig");
const msg_timer = @import("msg_timer.zig");
const builtin = @import("builtin");
const slide = @import("quick_terminal_slide.zig");
const Slider = @import("QuickTerminalSlider.zig");
const gl_comp_present = @import("../../renderer/gl_comp_present.zig");

const log = std.log.scoped(.win32_quick_terminal);

/// Animation timer ID (must not collide with QUIT_TIMER_ID=1 or notification=2).
pub const ANIM_TIMER_ID: usize = msg_timer.quick_terminal_anim;

/// The slider thread's answer for a DWM slide, posted to `App.msg_hwnd`.
pub const WM_APP_QT_SLIDE: u32 = Slider.WM_APP_QT_SLIDE;

/// Animation tick interval in milliseconds (~60fps).
const ANIM_TICK_MS: u32 = 16;

app: *App,
window: *Window,
visible: bool = false,
animating: bool = false,
animation_direction: enum { in, out } = .in,
animation_start_time: i64 = 0,
animation_duration: f64 = 0.2,
perf_freq: i64 = 1, // avoid division by zero

// Cached rects for animation interpolation.
target_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
hidden_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
/// The monitor the rects were computed on (`rcMonitor`), which clips the
/// DWM slide's host (T2766).
monitor_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

// The DWM slide (T2766, `QuickTerminalSlider.zig`). While `dwm_slide` is
// set the slide belongs to the slider thread: the window sits cloaked at
// `target_rect` and the frame clock is not armed.
slider: ?*Slider = null,
dwm_slide: bool = false,
dwm_gen: u32 = 0,
/// Slides carried by the slider / that fell back to the frame clock. Three
/// failures and the quick terminal stops asking for the rest of its life.
dwm_slides: u32 = 0,
dwm_failures: u32 = 0,

pub fn init(app: *App) !*QuickTerminal {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(QuickTerminal);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .window = undefined,
    };

    // Query performance counter frequency for animation timing.
    _ = w32.QueryPerformanceFrequency(&self.perf_freq);

    // Read animation duration from config.
    self.animation_duration = app.config.@"quick-terminal-animation-duration";

    // Create the window in quick terminal mode.
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(app, .{ .is_quick_terminal = true });
    self.window = window;

    // Add a single tab (surface) to the window.
    _ = try window.addTab();

    return self;
}

pub fn deinit(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;
    const app = self.app;

    // Kill animation timer if running.
    if (self.animating) {
        FrameClock.disarm(app.msg_hwnd, ANIM_TIMER_ID);
        self.animating = false;
    }
    self.dropSlider();

    // Prevent onDestroy from calling onWindowDestroyed (we're cleaning up ourselves).
    app.quick_terminal = null;

    // Clean up the window.
    self.window.close();
    alloc.destroy(self.window);
    alloc.destroy(self);
}

/// Toggle the quick terminal in or out. Called from App.performAction.
pub fn toggle(self: *QuickTerminal) void {
    if (self.animating) {
        // Mid-animation: reverse direction from current position.
        self.animation_direction = if (self.animation_direction == .in) .out else .in;
        // Adjust start time so progress continues smoothly from current position.
        const elapsed_ticks = self.now() - self.animation_start_time;
        const elapsed = @as(f64, @floatFromInt(elapsed_ticks)) / @as(f64, @floatFromInt(self.perf_freq));
        const progress = @min(elapsed / self.animation_duration, 1.0);
        const remaining = (1.0 - progress) * self.animation_duration;
        self.animation_start_time = self.now() - @as(i64, @intFromFloat(remaining * @as(f64, @floatFromInt(self.perf_freq))));
        if (self.dwm_slide) {
            if (self.slider) |s| {
                self.dwm_gen = s.reverse(toSlideDir(self.animation_direction), self.animation_start_time);
                log.info("quick terminal slide on dwm reversed dir={s} gen={d}", .{ @tagName(self.animation_direction), self.dwm_gen });
            }
        }
        return;
    }

    if (self.visible) {
        self.animateOut();
    } else {
        self.animateIn();
    }
}

fn animateIn(self: *QuickTerminal) void {
    // Recalculate position each time (handles monitor changes, config reload).
    self.calculateRects();

    const hwnd = self.window.hwnd orelse return;

    // A slide the slider will carry (T2766) shows the window cloaked, so not
    // one frame of it is drawn before the thumbnail takes over.
    const cloaked = self.animation_duration > 0 and self.dwmWanted() and setCloak(hwnd, true);

    // Position at hidden rect before showing.
    _ = w32.SetWindowPos(
        hwnd,
        w32.HWND_TOPMOST,
        self.hidden_rect.left,
        self.hidden_rect.top,
        self.hidden_rect.right - self.hidden_rect.left,
        self.hidden_rect.bottom - self.hidden_rect.top,
        w32.SWP_NOACTIVATE,
    );
    // The band half of that call is not self-reporting: with no foreground
    // window `SetWindowPos` returns TRUE having left the window in the
    // ordinary band (T277), and a quick terminal that is not topmost slides
    // under whatever it was summoned over. Confirm it — a no-op once seated.
    _ = w32.setTopmost(hwnd, true);

    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);

    if (self.animation_duration <= 0) {
        // Instant: jump to target.
        _ = w32.SetWindowPos(
            hwnd,
            w32.HWND_TOPMOST,
            self.target_rect.left,
            self.target_rect.top,
            self.target_rect.right - self.target_rect.left,
            self.target_rect.bottom - self.target_rect.top,
            w32.SWP_NOACTIVATE,
        );
        _ = w32.setTopmost(hwnd, true);
        self.visible = true;
        self.forceForeground();
        return;
    }

    self.animation_direction = .in;
    self.animation_start_time = self.now();
    self.animating = true;
    if (self.startDwmSlide()) return;
    if (cloaked) _ = setCloak(hwnd, false);
    _ = FrameClock.arm(self.app.msg_hwnd, ANIM_TIMER_ID, ANIM_TICK_MS);
}

fn animateOut(self: *QuickTerminal) void {
    if (self.animation_duration <= 0) {
        // Instant hide.
        if (self.window.hwnd) |hwnd| {
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
        }
        self.visible = false;
        return;
    }

    self.animation_direction = .out;
    self.animation_start_time = self.now();
    self.animating = true;
    if (self.startDwmSlide()) return;
    _ = FrameClock.arm(self.app.msg_hwnd, ANIM_TIMER_ID, ANIM_TICK_MS);
}

// -----------------------------------------------------------------------
// The DWM slide (T2766)
// -----------------------------------------------------------------------

/// Whether slides go to the slider thread: the composition knob's default
/// (`GHOZTTY_COMP_PRESENT=0` opts the whole app out, this slide included),
/// not backed off after repeated failures, and not the oracle's stepped arm
/// (`GHOZTTY_DEBUG_QT_SLIDE_STEPPED=1`, debug builds).
fn dwmWanted(self: *const QuickTerminal) bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (self.dwm_failures >= 3) return false;
    if (comptime builtin.mode == .Debug) {
        if (std.process.hasNonEmptyEnvVarConstant("GHOZTTY_DEBUG_QT_SLIDE_STEPPED")) return false;
    }
    return gl_comp_present.enabled();
}

/// Hand the slide just set up (`animation_direction`, `animation_start_time`)
/// to the slider thread. True: it is the slider's, and the window is cloaked
/// at its target rect. False: nothing was handed over and the caller steps it.
fn startDwmSlide(self: *QuickTerminal) bool {
    if (!self.dwmWanted()) return false;
    const hwnd = self.window.hwnd orelse return false;
    const host = slide.hostRect(toRect(self.hidden_rect), toRect(self.target_rect), toRect(self.monitor_rect)) orelse return false;
    if (self.slider == null) {
        const notify = self.app.msg_hwnd orelse return false;
        self.slider = Slider.create(self.app.core_app.alloc, hwnd, notify) catch |err| {
            log.warn("quick terminal slide slider unavailable err={}; stepping it", .{err});
            self.dwm_failures +|= 1;
            return false;
        };
    }
    if (self.animation_direction == .in) {
        // The window waits at its final place, cloaked: composed (so the
        // slider's thumbnail of it is live) but not drawn, and taking no
        // input until it lands. animateIn showed it cloaked already.
        if (!setCloak(hwnd, true)) {
            log.warn("quick terminal slide could not cloak the window; stepping it", .{});
            self.dwm_failures +|= 1;
            return false;
        }
        _ = w32.SetWindowPos(
            hwnd,
            w32.HWND_TOPMOST,
            self.target_rect.left,
            self.target_rect.top,
            self.target_rect.right - self.target_rect.left,
            self.target_rect.bottom - self.target_rect.top,
            w32.SWP_NOACTIVATE,
        );
    }
    // An out slide: the slider cloaks the window itself once its thumbnail
    // is on screen, so there is never a frame showing neither.
    self.dwm_gen = self.slider.?.start(.{
        .hidden = toRect(self.hidden_rect),
        .target = toRect(self.target_rect),
        .host = host,
        .dir = toSlideDir(self.animation_direction),
        .start_qpc = self.animation_start_time,
        .duration_s = self.animation_duration,
    });
    self.dwm_slide = true;
    self.dwm_slides +|= 1;
    log.info("quick terminal slide on dwm dir={s} gen={d} ms={d} host={d},{d} {d}x{d}", .{
        @tagName(self.animation_direction),
        self.dwm_gen,
        @as(u32, @intFromFloat(@ceil(self.animation_duration * 1000.0))),
        host.left,
        host.top,
        host.width(),
        host.height(),
    });
    debugStall();
    return true;
}

/// The slider's answer for a slide (App's `WM_APP_QT_SLIDE`).
pub fn onSlideMessage(self: *QuickTerminal, gen: u32, status_raw: isize) void {
    // An answer for a slide since turned round, or one already over, is not
    // this slide's.
    if (!self.dwm_slide or gen != self.dwm_gen) return;
    const s = self.slider orelse return;
    const hwnd = self.window.hwnd orelse return;
    const status: Slider.Status = std.meta.intToEnum(Slider.Status, status_raw) catch .failed;
    switch (status) {
        .in_done => {
            self.dwm_slide = false;
            self.animating = false;
            _ = setCloak(hwnd, false);
            s.release(gen);
            self.visible = true;
            log.info("quick terminal slide landed dir=in frames={d} ms={d}", .{ s.last_frames.load(.acquire), s.last_ms.load(.acquire) });
            self.forceForeground();
        },
        .out_done => {
            self.dwm_slide = false;
            self.animating = false;
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
            _ = setCloak(hwnd, false);
            self.visible = false;
            log.info("quick terminal slide landed dir=out frames={d} ms={d}", .{ s.last_frames.load(.acquire), s.last_ms.load(.acquire) });
        },
        .failed => {
            self.dwm_slide = false;
            self.dwm_failures +|= 1;
            log.warn("quick terminal slide could not stay on dwm at {s} hr=0x{x:0>8}; stepping the rest", .{ s.fail_stage, @as(u32, @bitCast(s.fail_hr)) });
            // The frame clock carries on from the same start and direction:
            // place the window where the slide has got to, then show it.
            _ = FrameClock.arm(self.app.msg_hwnd, ANIM_TIMER_ID, ANIM_TICK_MS);
            self.onAnimationTick();
            _ = setCloak(hwnd, false);
        },
    }
}

fn dropSlider(self: *QuickTerminal) void {
    if (self.slider) |s| s.destroy();
    self.slider = null;
    self.dwm_slide = false;
}

fn setCloak(hwnd: w32.HWND, on: bool) bool {
    const v: i32 = @intFromBool(on);
    return w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_CLOAK, &v, @sizeOf(i32)) >= 0;
}

fn toRect(r: w32.RECT) slide.Rect {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

fn toSlideDir(d: anytype) slide.Direction {
    return switch (d) {
        .in => .in,
        .out => .out,
    };
}

/// `GHOZTTY_DEBUG_QT_SLIDE_STALL_MS=<n>` (debug builds, T2766): block the UI
/// thread for n ms the moment a slide starts - the oracle's stand-in for a
/// busy UI thread. A DWM slide moves through it; a stepped one waits.
fn debugStall() void {
    if (comptime builtin.mode != .Debug) return;
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_DEBUG_QT_SLIDE_STALL_MS") catch return;
    defer std.heap.page_allocator.free(raw);
    const ms = std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return;
    if (ms == 0) return;
    log.info("quick terminal slide debug stall ms={d}", .{ms});
    std.Thread.sleep(@as(u64, @min(ms, 5000)) * std.time.ns_per_ms);
}

/// Called from App's WM_TIMER handler on each animation tick.
pub fn onAnimationTick(self: *QuickTerminal) void {
    if (!self.animating) return;

    const elapsed_ticks = self.now() - self.animation_start_time;
    const elapsed = @as(f64, @floatFromInt(elapsed_ticks)) / @as(f64, @floatFromInt(self.perf_freq));
    const progress = @min(elapsed / self.animation_duration, 1.0);

    // For animate-out, invert progress so interpolation goes from visible→hidden.
    const t = slide.easedT(progress, toSlideDir(self.animation_direction));

    const hwnd = self.window.hwnd orelse return;

    // Interpolate position.
    const x = slide.lerp(self.hidden_rect.left, self.target_rect.left, t);
    const y = slide.lerp(self.hidden_rect.top, self.target_rect.top, t);
    const w = self.target_rect.right - self.target_rect.left;
    const h = self.target_rect.bottom - self.target_rect.top;

    _ = w32.SetWindowPos(hwnd, w32.HWND_TOPMOST, x, y, w, h, w32.SWP_NOACTIVATE);

    if (progress >= 1.0) {
        // Animation complete.
        FrameClock.disarm(self.app.msg_hwnd, ANIM_TIMER_ID);
        self.animating = false;

        if (self.animation_direction == .in) {
            self.visible = true;
            self.forceForeground();
        } else {
            self.visible = false;
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
        }
    }
}

/// Called when the quick terminal window loses focus.
pub fn onFocusLost(self: *QuickTerminal) void {
    if (!self.visible) return;
    if (self.animating and self.animation_direction == .out) return;
    if (!self.app.config.@"quick-terminal-autohide") return;

    self.animateOut();
}

/// Called when the quick terminal's window is destroyed (shell exited).
/// At this point Window.onDestroy has already cleaned up font/hwnd.
pub fn onWindowDestroyed(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;
    const app = self.app;

    // Kill the animation timer unconditionally — `self.animating` may
    // be false but a stray WM_TIMER could already be queued. Once `self`
    // is freed below, dispatching that timer would touch freed memory.
    FrameClock.disarm(app.msg_hwnd, ANIM_TIMER_ID);
    // The slider's thumbnail names a window that is gone; its thread and
    // host go with it.
    self.dropSlider();

    alloc.destroy(self.window);
    app.quick_terminal = null;
    alloc.destroy(self);

    // Check if we should start the quit timer (after self is freed).
    if (app.windows.items.len == 0) {
        app.startQuitTimer();
    }
}

/// Update cached config values after a config reload.
pub fn onConfigChange(self: *QuickTerminal, config: *const configpkg.Config) void {
    self.animation_duration = config.@"quick-terminal-animation-duration";
}

// -----------------------------------------------------------------------
// Position calculation
// -----------------------------------------------------------------------

/// Compute the target (visible) and hidden (off-screen) rects based on
/// the current monitor and config.
fn calculateRects(self: *QuickTerminal) void {
    const config = &self.app.config;
    const position = config.@"quick-terminal-position";

    // Get monitor work area.
    const monitor = self.getMonitor() orelse return;
    var mi = w32.MONITORINFO{
        .cbSize = @sizeOf(w32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    if (w32.GetMonitorInfoW(monitor, &mi) == 0) return;

    const work = mi.rcWork;
    self.monitor_rect = mi.rcMonitor;
    const mw: u32 = @intCast(work.right - work.left);
    const mh: u32 = @intCast(work.bottom - work.top);

    // Use the config's calculate() method for size.
    const size = config.@"quick-terminal-size".calculate(position, .{
        .width = mw,
        .height = mh,
    });

    // Apply DPI scaling to default pixel values (calculate() returns
    // unscaled defaults like 400px).
    const scale = self.window.scale;
    var qw: i32 = if (config.@"quick-terminal-size".primary != null or config.@"quick-terminal-size".secondary != null)
        @intCast(size.width)
    else
        @intFromFloat(@round(@as(f32, @floatFromInt(size.width)) * scale));
    var qh: i32 = if (config.@"quick-terminal-size".primary != null or config.@"quick-terminal-size".secondary != null)
        @intCast(size.height)
    else
        @intFromFloat(@round(@as(f32, @floatFromInt(size.height)) * scale));

    // Clamp to work area.
    if (qw > @as(i32, @intCast(mw))) qw = @intCast(mw);
    if (qh > @as(i32, @intCast(mh))) qh = @intCast(mh);

    switch (position) {
        .top => {
            self.target_rect = .{ .left = work.left, .top = work.top, .right = work.left + qw, .bottom = work.top + qh };
            self.hidden_rect = .{ .left = work.left, .top = work.top - qh, .right = work.left + qw, .bottom = work.top };
        },
        .bottom => {
            self.target_rect = .{ .left = work.left, .top = work.bottom - qh, .right = work.left + qw, .bottom = work.bottom };
            self.hidden_rect = .{ .left = work.left, .top = work.bottom, .right = work.left + qw, .bottom = work.bottom + qh };
        },
        .left => {
            self.target_rect = .{ .left = work.left, .top = work.top, .right = work.left + qw, .bottom = work.top + qh };
            self.hidden_rect = .{ .left = work.left - qw, .top = work.top, .right = work.left, .bottom = work.top + qh };
        },
        .right => {
            self.target_rect = .{ .left = work.right - qw, .top = work.top, .right = work.right, .bottom = work.top + qh };
            self.hidden_rect = .{ .left = work.right, .top = work.top, .right = work.right + qw, .bottom = work.top + qh };
        },
        .center => {
            const cx = work.left + @divTrunc(@as(i32, @intCast(mw)) - qw, 2);
            const cy = work.top + @divTrunc(@as(i32, @intCast(mh)) - qh, 2);
            self.target_rect = .{ .left = cx, .top = cy, .right = cx + qw, .bottom = cy + qh };
            self.hidden_rect = .{ .left = cx, .top = work.top - qh, .right = cx + qw, .bottom = work.top };
        },
    }
}

fn getMonitor(self: *QuickTerminal) ?w32.HMONITOR {
    const screen = self.app.config.@"quick-terminal-screen";
    switch (screen) {
        .main, .@"macos-menu-bar" => {
            return w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY);
        },
        .mouse => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                return w32.MonitorFromPoint(pt, w32.MONITOR_DEFAULTTONEAREST);
            }
            return w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY);
        },
    }
}

// -----------------------------------------------------------------------
// Animation helpers
// -----------------------------------------------------------------------

/// Force the quick terminal to the foreground, even when Ghostty is a
/// background process. Uses AttachThreadInput to work around the Win32
/// SetForegroundWindow restriction.
fn forceForeground(self: *QuickTerminal) void {
    const hwnd = self.window.hwnd orelse return;
    // foreground-audit: this is the AttachThreadInput dance that BECOMES the
    // foreground window, so it needs the raw foreground owner's thread - it is
    // not asking "is one of our windows active", which is window_active's
    // question. Off the input desktop there is no foreground window and the
    // null branch below is the right answer.
    const fg = w32.GetForegroundWindow();
    if (fg) |fg_hwnd| {
        const fg_tid = w32.GetWindowThreadProcessId(fg_hwnd, null);
        const our_tid = w32.GetCurrentThreadId();
        if (fg_tid != our_tid) {
            _ = w32.AttachThreadInput(our_tid, fg_tid, 1);
            _ = w32.SetForegroundWindow(hwnd);
            _ = w32.AttachThreadInput(our_tid, fg_tid, 0);
        } else {
            _ = w32.SetForegroundWindow(hwnd);
        }
    } else {
        _ = w32.SetForegroundWindow(hwnd);
    }
    // Focus the terminal surface inside the window (deferred — T48).
    if (self.window.getActiveSurface()) |s| {
        if (s.hwnd) |sh| App.deferSetFocus(sh);
    }
}

fn now(_: *QuickTerminal) i64 {
    var count: i64 = 0;
    _ = w32.QueryPerformanceCounter(&count);
    return count;
}

// The ease and the lerp live in `quick_terminal_slide.zig` (T2766), where
// both slide paths share them and the `none` lane asserts them.
