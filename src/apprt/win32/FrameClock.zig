//! The app's one frame clock (T2365): every animation steps on the display's
//! vblank instead of owning a 16 ms `SetTimer`.
//!
//! A worker thread blocks on the compositor clock
//! (`DCompositionWaitForCompositorClock`, Windows 11) - or, where that is
//! missing, a high-resolution waitable timer at the display period - and
//! posts ONE `WM_APP_FRAME` to `App.msg_hwnd` per tick while anything is
//! subscribed. The UI thread answers it by sending each subscriber the
//! `WM_TIMER` its animation already handles, so a converted animation swaps
//! `SetTimer`/`KillTimer` for `arm`/`disarm` and keeps its handler as is, and
//! every animation in the app steps in the same frame. Why the old clock
//! judders, and the coalescing rule that keeps input ahead of frames, are in
//! `frame_clock.zig`.
//!
//! With no clock running (unit tests, a window on another thread, a full
//! subscription table) `arm` falls back to the `SetTimer` it replaced, so an
//! animation always runs. `GHOZTTY_FRAME_CLOCK=settimer` drives the same
//! dispatch from the old 16 ms WM_TIMER instead, and `=hrtimer` skips the
//! compositor clock: that is how `test\win32\frame-clock.ps1` measures the
//! clock this replaced on one build. Under `GHOZTTY_PERF` each finished run
//! prints a `frame clock id=..` line with its intervals and handler cost, and
//! `GHOZTTY_FRAME_CLOCK_PROBE=<delay_ms>,<duration_ms>` adds a subscriber
//! whose tick does nothing, so the clock's cadence is measured apart from
//! any animation's paint cost.
const FrameClock = @This();

const std = @import("std");
const w32 = @import("win32.zig");
const frame_clock = @import("frame_clock.zig");
const msg_timer = @import("msg_timer.zig");

const log = std.log.scoped(.frame_clock);

/// Posted to `App.msg_hwnd` once per vblank while an animation is live.
pub const WM_APP_FRAME: u32 = w32.WM_APP + 43;

pub const Source = enum { compositor, hrtimer, settimer };

const WaitForCompositorClockFn = *const fn (
    count: u32,
    handles: ?[*]const w32.HANDLE,
    timeout_ms: u32,
) callconv(.winapi) u32;

/// The running clock; null until `App` starts one.
var current: ?*FrameClock = null;

alloc: std.mem.Allocator,
msg_hwnd: w32.HWND,
ui_thread: u32,
source: Source,
wait_clock: ?WaitForCompositorClockFn = null,
wake: ?w32.HANDLE = null,
timer: ?w32.HANDLE = null,
thread: ?std.Thread = null,
base: std.time.Instant,
perf: bool,

stopping: std.atomic.Value(bool) = .init(false),
live: std.atomic.Value(usize) = .init(0),
pending: std.atomic.Value(bool) = .init(false),
period_ns: std.atomic.Value(u64) = .init(frame_clock.default_period_ns),

/// UI thread only.
set: frame_clock.Set = .{},
dispatching: bool = false,
/// `GHOZTTY_FRAME_CLOCK_PROBE=<delay_ms>,<duration_ms>`: how long the probe
/// runs once started, and when it started (UI thread only).
probe_duration_ns: u64 = 0,
probe_t0_ns: u64 = 0,

/// Start the app's frame clock on the UI thread, delivering to `msg_hwnd`.
/// A clock that cannot start leaves every animation on its own `SetTimer`.
pub fn start(alloc: std.mem.Allocator, msg_hwnd: w32.HWND) void {
    if (current != null) return;
    const self = alloc.create(FrameClock) catch return;
    self.* = .{
        .alloc = alloc,
        .msg_hwnd = msg_hwnd,
        .ui_thread = w32.GetCurrentThreadId(),
        .source = .compositor,
        .base = std.time.Instant.now() catch {
            alloc.destroy(self);
            return;
        },
        .perf = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PERF"),
    };
    self.source = requestedSource();
    if (self.source == .compositor) {
        self.wait_clock = loadCompositorClock();
        if (self.wait_clock == null) self.source = .hrtimer;
    }
    if (self.source != .settimer) {
        self.wake = w32.CreateEventW(null, 0, 0, null);
        if (self.wake == null) return self.destroy();
        if (self.source == .hrtimer) {
            self.timer = w32.CreateWaitableTimerExW(
                null,
                null,
                w32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                w32.TIMER_ALL_ACCESS,
            );
            if (self.timer == null) return self.destroy();
        }
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch return self.destroy();
    }
    current = self;
    log.debug("frame clock started source={s}", .{@tagName(self.source)});
    self.armProbe();
}

fn armProbe(self: *FrameClock) void {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const v = std.process.getEnvVarOwned(fba.allocator(), "GHOZTTY_FRAME_CLOCK_PROBE") catch return;
    var it = std.mem.splitScalar(u8, v, ',');
    const delay = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
    const duration = std.fmt.parseInt(u64, it.next() orelse return, 10) catch return;
    self.probe_duration_ns = duration * std.time.ns_per_ms;
    _ = w32.SetTimer(self.msg_hwnd, msg_timer.frame_clock_probe_start, @max(1, delay), null);
}

/// `App.msg_hwnd`'s answer to the probe's start delay: subscribe the probe.
pub fn onProbeStart() void {
    const c = current orelse return;
    _ = w32.KillTimer(c.msg_hwnd, msg_timer.frame_clock_probe_start);
    c.probe_t0_ns = c.nowNs();
    _ = arm(c.msg_hwnd, msg_timer.frame_clock_probe, 16);
}

/// A probe tick does nothing but end the run when its time is up, so its
/// intervals are the clock's own cadence plus the dispatch around it.
pub fn onProbeTick() void {
    const c = current orelse return;
    if (c.nowNs() -| c.probe_t0_ns >= c.probe_duration_ns) disarm(c.msg_hwnd, msg_timer.frame_clock_probe);
}

/// Stop the clock (App teardown, before `msg_hwnd` goes). Animations still
/// subscribed simply stop ticking; their windows are going too.
pub fn stop() void {
    const self = current orelse return;
    current = null;
    self.stopping.store(true, .release);
    if (self.wake) |e| _ = w32.SetEvent(e);
    if (self.thread) |t| t.join();
    self.thread = null;
    if (self.source == .settimer) _ = w32.KillTimer(self.msg_hwnd, msg_timer.frame_clock_settimer);
    self.destroy();
}

fn destroy(self: *FrameClock) void {
    if (self.wake) |e| _ = w32.CloseHandle(e);
    if (self.timer) |t| _ = w32.CloseHandle(t);
    self.alloc.destroy(self);
}

/// Start stepping `(hwnd, id)` on the frame clock: `hwnd` receives
/// `WM_TIMER` with `wParam == id` once per displayed frame until `disarm`.
/// The drop-in for `SetTimer(hwnd, id, fallback_ms, null)`, which is what
/// runs instead when no clock can take it. False when neither could start
/// (no window, or `SetTimer` refused), the same answer `SetTimer`'s zero gave.
pub fn arm(hwnd: ?w32.HWND, id: usize, fallback_ms: u32) bool {
    const h = hwnd orelse return false;
    if (current) |c| if (c.subscribe(h, id)) return true;
    return w32.SetTimer(h, id, fallback_ms, null) != 0;
}

/// Stop `(hwnd, id)`, however `arm` started it. Safe on a pair that is not
/// running, like `KillTimer`.
pub fn disarm(hwnd: ?w32.HWND, id: usize) void {
    const h = hwnd orelse return;
    _ = w32.KillTimer(h, id);
    if (current) |c| c.unsubscribe(@intFromPtr(h), id);
}

/// Whether `(hwnd, id)` is stepping on the frame clock right now.
pub fn isArmed(hwnd: w32.HWND, id: usize) bool {
    const c = current orelse return false;
    return c.set.contains(@intFromPtr(hwnd), id);
}

/// `App.msg_hwnd`'s answer to `WM_APP_FRAME`, and to the legacy cadence's
/// `WM_TIMER` under `GHOZTTY_FRAME_CLOCK=settimer`.
pub fn onFrame() void {
    const c = current orelse return;
    c.dispatch();
}

fn requestedSource() Source {
    var buf: [32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const v = std.process.getEnvVarOwned(fba.allocator(), "GHOZTTY_FRAME_CLOCK") catch return .compositor;
    if (std.ascii.eqlIgnoreCase(v, "settimer")) return .settimer;
    if (std.ascii.eqlIgnoreCase(v, "hrtimer")) return .hrtimer;
    return .compositor;
}

fn loadCompositorClock() ?WaitForCompositorClockFn {
    const lib = w32.LoadLibraryExW(
        std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll"),
        null,
        w32.LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) orelse return null;
    const proc = w32.GetProcAddress(lib, "DCompositionWaitForCompositorClock") orelse return null;
    return @ptrCast(proc);
}

fn nowNs(self: *const FrameClock) u64 {
    const now = std.time.Instant.now() catch return 0;
    return now.since(self.base);
}

fn subscribe(self: *FrameClock, hwnd: w32.HWND, id: usize) bool {
    // Delivery is a same-thread SendMessage; a window on another thread would
    // turn it into a cross-thread wait, so that one keeps its own timer.
    if (w32.GetCurrentThreadId() != self.ui_thread) return false;
    if (w32.GetWindowThreadProcessId(hwnd, null) != self.ui_thread) return false;
    switch (self.set.arm(@intFromPtr(hwnd), id)) {
        .full => return false,
        .already => return true,
        .added => {
            // A SetTimer armed before the clock took this pair would tick it twice.
            _ = w32.KillTimer(hwnd, id);
            if (self.live.fetchAdd(1, .acq_rel) == 0) self.resume_();
            return true;
        },
    }
}

fn unsubscribe(self: *FrameClock, hwnd: usize, id: usize) void {
    const sub = self.set.disarm(hwnd, id) orelse return;
    if (self.live.fetchSub(1, .acq_rel) == 1 and self.source == .settimer) {
        _ = w32.KillTimer(self.msg_hwnd, msg_timer.frame_clock_settimer);
    }
    self.report(sub);
}

fn resume_(self: *FrameClock) void {
    switch (self.source) {
        .settimer => _ = w32.SetTimer(self.msg_hwnd, msg_timer.frame_clock_settimer, 16, null),
        else => if (self.wake) |e| {
            _ = w32.SetEvent(e);
        },
    }
}

fn report(self: *const FrameClock, sub: frame_clock.Sub) void {
    if (!self.perf or !sub.stats.reportable()) return;
    const st = sub.stats;
    log.info(
        "frame clock id=0x{x} ticks={d} intervals={d} mean_us={d} max_us={d} doubled={d} " ++
            "period_us={d} cost_mean_us={d} cost_max_us={d} source={s}",
        .{
            sub.id,
            st.ticks,
            st.intervals,
            st.meanIntervalUs(),
            st.interval_max_ns / std.time.ns_per_us,
            st.doubled,
            self.period_ns.load(.acquire) / std.time.ns_per_us,
            st.meanCostUs(),
            st.cost_max_ns / std.time.ns_per_us,
            @tagName(self.source),
        },
    );
}

fn dispatch(self: *FrameClock) void {
    // A handler that pumps messages cannot re-enter: `pending` stays set until
    // the outer walk is done, so the worker posts nothing meanwhile.
    if (self.dispatching) return;
    self.dispatching = true;
    defer {
        self.dispatching = false;
        self.pending.store(false, .release);
    }

    const Key = struct { hwnd: usize, id: usize };
    var keys: [frame_clock.capacity]Key = undefined;
    const n = self.set.len;
    for (self.set.slice(), 0..) |s, i| keys[i] = .{ .hwnd = s.hwnd, .id = s.id };

    const period = self.period_ns.load(.acquire);
    for (keys[0..n]) |k| {
        // An earlier tick this frame may have stopped this one.
        const sub = self.set.get(k.hwnd, k.id) orelse continue;
        const hwnd: w32.HWND = @ptrFromInt(k.hwnd);
        if (w32.IsWindow(hwnd) == 0) {
            self.unsubscribe(k.hwnd, k.id);
            continue;
        }
        const t0 = self.nowNs();
        if (sub.last_ns) |last| sub.stats.recordInterval(t0 -| last, period);
        sub.last_ns = t0;
        _ = w32.SendMessageW(hwnd, w32.WM_TIMER, k.id, 0);
        // The handler may have disarmed (and freed the slot of) this pair.
        if (self.set.get(k.hwnd, k.id)) |still| still.stats.recordCost(self.nowNs() -| t0);
    }
}

fn run(self: *FrameClock) void {
    var est: frame_clock.PeriodEstimator = .{};
    var last: ?u64 = null;
    var next_due: u64 = 0;
    while (!self.stopping.load(.acquire)) {
        if (self.live.load(.acquire) == 0) {
            last = null;
            _ = w32.WaitForSingleObject(self.wake.?, w32.INFINITE);
            continue;
        }
        if (!self.waitTick(&next_due)) continue;
        const now = self.nowNs();
        if (last) |l| {
            est.record(now -| l);
            self.period_ns.store(est.periodNs(), .release);
        }
        last = now;
        if (frame_clock.shouldPost(self.live.load(.acquire), self.pending.load(.acquire))) {
            self.pending.store(true, .release);
            if (w32.PostMessageW(self.msg_hwnd, WM_APP_FRAME, 0, 0) == 0) {
                self.pending.store(false, .release);
            }
        }
    }
}

/// Block until the next frame. False when woken for another reason (an arm,
/// a stop), which the loop re-checks.
fn waitTick(self: *FrameClock, next_due: *u64) bool {
    const handles = [_]w32.HANDLE{self.wake.?};
    if (self.wait_clock) |wait| {
        // The compositor can pause its clock while nothing on screen changes,
        // and an animation's first frame is what changes it: a missing tick
        // after two periods is taken as one rather than waited out.
        const timeout_ms: u32 = @intCast(@max(1, 2 * self.period_ns.load(.acquire) / std.time.ns_per_ms));
        const r = wait(1, &handles, timeout_ms);
        if (r == w32.WAIT_OBJECT_0) return false;
        if (r == w32.WAIT_OBJECT_0 + 1 or r == w32.WAIT_TIMEOUT) return true;
        // The call itself failed: step on the high-resolution timer from here.
        log.warn("compositor clock wait failed ({x}); falling back to a timer", .{r});
        self.wait_clock = null;
        self.timer = w32.CreateWaitableTimerExW(null, null, w32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, w32.TIMER_ALL_ACCESS);
        self.source = .hrtimer;
        if (self.timer == null) {
            // Nothing to wait on at all: a plain sleep still steps evenly enough
            // to keep animations moving rather than freezing them.
            std.Thread.sleep(self.period_ns.load(.acquire));
            return true;
        }
        return false;
    }
    const timer = self.timer orelse {
        std.Thread.sleep(self.period_ns.load(.acquire));
        return true;
    };
    // Even steps on an absolute schedule: a late wakeup does not push every
    // later frame back with it.
    const period = frame_clock.default_period_ns;
    const now = self.nowNs();
    if (next_due.* <= now) next_due.* = now + period;
    const due: i64 = -@as(i64, @intCast(@max(1, (next_due.* - now) / 100)));
    if (w32.SetWaitableTimer(timer, &due, 0, null, null, 0) == 0) {
        std.Thread.sleep(period);
        next_due.* += period;
        return true;
    }
    const pair = [_]w32.HANDLE{ self.wake.?, timer };
    const r = w32.WaitForMultipleObjects(2, &pair, 0, 100);
    if (r == w32.WAIT_OBJECT_0 + 1) {
        next_due.* += period;
        return true;
    }
    return false;
}
