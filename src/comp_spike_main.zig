//! `ghoztty-comp-spike`: T2360 step 1. One window, a sidebar blade that
//! collapses and expands, driven two ways so the frame cadence of each can be
//! measured on the same box:
//!
//!   --mode=gdi   today's shape: the blade and the card beside it are child
//!                HWNDs, hand-stepped by a 16 ms SetTimer on the UI thread.
//!   --mode=comp  Windows.UI.Composition: the blade and card are SpriteVisuals
//!                under a desktop window target, and each glide is ONE
//!                declaration (keyframe animations on Size/Offset) that DWM
//!                runs on its own clock.
//!   --mode=idle  the same schedule with nothing animating: the noise floor.
//!
//! `--stall-ms=N` blocks the UI thread for N ms halfway through every glide
//! (the "motion never waits on the UI thread" criterion). `--thread=worker`
//! puts the Compositor on its own thread with its own DispatcherQueue, which
//! answers the design's open question: can a desktop window target be created
//! by a Compositor that does not live on the HWND's thread?
//!
//! The oracle is DWM's compose clock (DComp frame statistics), scored per glide by
//! `apprt/win32/comp_spike_stats.zig`. The report goes to `--out=<path>` (text lines,
//! one `GLIDE` per glide and a `SUMMARY`). The window never activates
//! (WS_EX_NOACTIVATE, SW_SHOWNOACTIVATE), and the harness runs it on the
//! background test desktop unless told to run live.
const std = @import("std");
const w32 = @import("apprt/win32/win32.zig");
const rt = @import("apprt/win32/winrt_comp.zig");
const stats = @import("apprt/win32/comp_spike_stats.zig");

const Mode = enum { gdi, comp, idle };
const ThreadKind = enum { ui, worker };

const Opts = struct {
    mode: Mode = .comp,
    thread: ThreadKind = .ui,
    glides: u32 = 8,
    duration_ms: u32 = 300,
    gap_ms: u32 = 450,
    stall_ms: u32 = 0,
    out: []const u8 = "comp-spike.txt",
};

const WS_VISIBLE: u32 = 0x10000000;
const WS_EX_NOREDIRECTIONBITMAP: u32 = 0x00200000;
const WS_EX_TOOLWINDOW: u32 = 0x00000080;
const TIMER_NEXT: usize = 1;
const TIMER_STEP: usize = 2;
const TIMER_STALL: usize = 3;
const WM_APP_GLIDE: u32 = w32.WM_APP + 1;
const WM_APP_QUIT: u32 = w32.WM_APP + 2;

const client_w: f32 = 1000;
const client_h: f32 = 640;
const blade_open: f32 = 280;
const blade_closed: f32 = 44;
const gutter: f32 = 10;
/// The glide curve, the same in both modes: CSS `ease`.
const ease_p1: rt.Vector2 = .{ .x = 0.25, .y = 0.1 };
const ease_p2: rt.Vector2 = .{ .x = 0.25, .y = 1.0 };

const Glide = struct { t0: i64 = 0, t1: i64 = 0, steps: u32 = 0, stalled_ms: u32 = 0 };

var opts: Opts = .{};
var qpf: i64 = 1;
var hwnd_main: ?w32.HWND = null;
var hwnd_blade: ?w32.HWND = null;
var hwnd_card: ?w32.HWND = null;
var glides: [64]Glide = [_]Glide{.{}} ** 64;
var glide_i: u32 = 0;
var running_glide: ?u32 = null;
var report_buf: [16 * 1024]u8 = undefined;
var report_len: usize = 0;

// ---- report -----------------------------------------------------------------

fn say(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(report_buf[report_len..], fmt ++ "\n", args) catch return;
    report_len += s.len;
}

fn flushReport() void {
    const f = std.fs.cwd().createFile(opts.out, .{}) catch return;
    defer f.close();
    f.writeAll(report_buf[0..report_len]) catch {};
}

fn now() i64 {
    var t: i64 = 0;
    _ = w32.QueryPerformanceCounter(&t);
    return t;
}

fn qpcFromMs(v: u32) i64 {
    return @divTrunc(@as(i64, v) * qpf, 1000);
}

// ---- DWM compose sampler ---------------------------------------------------

/// The oracle is DirectComposition's frame statistics (Windows 11): every
/// frame DWM composes gets an id, and `DCompositionGetStatistics` names the
/// vblank it targeted. `DwmGetCompositionTimingInfo` cannot serve: measured on
/// this box (2026-10-29) its `cRefresh`/`cFrame` advance by one per CALL, not
/// per frame, so a poller counts its own polls.
const COMPOSITION_FRAME_ID_COMPLETED: u32 = 2;
const FrameStats = extern struct { start: u64, target: u64, period: u64 };
const GetFrameIdFn = *const fn (u32, *u64) callconv(.winapi) rt.HRESULT;
const GetStatsFn = *const fn (u64, *FrameStats, u32, ?*anyopaque, ?*u32) callconv(.winapi) rt.HRESULT;

const Sampler = struct {
    get_id: GetFrameIdFn,
    get_stats: GetStatsFn,
    stop: std.atomic.Value(bool) = .init(false),
    ts: [65536]i64 = undefined,
    n: usize = 0,
    period: f64 = 0,
    hz: f64 = 0,
    frames: u64 = 0,
    lost: u64 = 0,

    fn run(self: *Sampler) void {
        var last: u64 = 0;
        while (!self.stop.load(.acquire)) {
            var id: u64 = 0;
            if (!rt.failed(self.get_id(COMPOSITION_FRAME_ID_COMPLETED, &id)) and id != last) {
                // Every frame completed since the last poll, oldest first.
                var f = if (last == 0 or id - last > 64) id else last + 1;
                while (f <= id) : (f += 1) {
                    var st: FrameStats = undefined;
                    if (rt.failed(self.get_stats(f, &st, 0, null, null))) {
                        self.lost += 1;
                        continue;
                    }
                    if (self.period == 0 and st.period != 0) {
                        self.period = @floatFromInt(st.period);
                        self.hz = @as(f64, @floatFromInt(qpf)) / self.period;
                    }
                    if (last != 0 and self.n < self.ts.len) {
                        self.ts[self.n] = @intCast(st.target);
                        self.n += 1;
                        self.frames += 1;
                    }
                }
                last = id;
            }
            std.Thread.sleep(500 * std.time.ns_per_us);
        }
    }
};

var sampler: ?*Sampler = null;
var sampler_thread: ?std.Thread = null;

fn startSampler() void {
    const dcomp = rtLoad("dcomp.dll") orelse return;
    const get_id: GetFrameIdFn = @ptrCast(rtSym(dcomp, "DCompositionGetFrameId") orelse return);
    const get_stats: GetStatsFn = @ptrCast(rtSym(dcomp, "DCompositionGetStatistics") orelse return);
    const s = std.heap.page_allocator.create(Sampler) catch return;
    s.* = .{ .get_id = get_id, .get_stats = get_stats };
    sampler = s;
    sampler_thread = std.Thread.spawn(.{}, Sampler.run, .{s}) catch null;
}

extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "user32" fn PostThreadMessageW(u32, u32, usize, isize) callconv(.winapi) i32;

fn rtLoad(comptime name: []const u8) ?*anyopaque {
    return LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral(name));
}

fn rtSym(lib: *anyopaque, name: [*:0]const u8) ?*anyopaque {
    return GetProcAddress(lib, name);
}

// ---- the scene, both ways ---------------------------------------------------

fn bladeTarget(i: u32) f32 {
    return if (i % 2 == 0) blade_closed else blade_open;
}

fn bladeStart(i: u32) f32 {
    return if (i % 2 == 0) blade_open else blade_closed;
}

/// CSS cubic-bezier evaluated the way the compositor does: solve x(t) = p
/// for t, return y(t).
fn bezier(p: f32) f32 {
    const ax = 3 * ease_p1.x - 3 * ease_p2.x + 1;
    const bx = 3 * ease_p2.x - 6 * ease_p1.x;
    const cx = 3 * ease_p1.x;
    const ay = 3 * ease_p1.y - 3 * ease_p2.y + 1;
    const by = 3 * ease_p2.y - 6 * ease_p1.y;
    const cy = 3 * ease_p1.y;
    var t = p;
    var k: u32 = 0;
    while (k < 8) : (k += 1) {
        const x = ((ax * t + bx) * t + cx) * t - p;
        const dx = (3 * ax * t + 2 * bx) * t + cx;
        if (@abs(dx) < 1e-6) break;
        t -= x / dx;
    }
    t = std.math.clamp(t, 0, 1);
    return ((ay * t + by) * t + cy) * t;
}

fn gdiLayout(blade_w: f32) void {
    const hdwp = w32.BeginDeferWindowPos(2) orelse return;
    const bw: i32 = @intFromFloat(blade_w);
    const cx: i32 = @intFromFloat(blade_w + gutter);
    const h: i32 = @intFromFloat(client_h);
    const flags = w32.SWP_NOZORDER | w32.SWP_NOACTIVATE;
    const a = w32.DeferWindowPos(hdwp, hwnd_blade.?, null, 0, 0, bw, h, flags) orelse return;
    const b = w32.DeferWindowPos(a, hwnd_card.?, null, cx, 0, @as(i32, @intFromFloat(client_w)) - cx, h, flags) orelse return;
    _ = w32.EndDeferWindowPos(b);
}

const Comp = struct {
    dq: rt.Obj,
    compositor: rt.Compositor,
    target: rt.Obj,
    blade: rt.Obj,
    card: rt.Obj,
    easing: rt.Obj,

    fn init(hwnd: w32.HWND) !Comp {
        const dq = try stage("dispatcher-queue", rt.initThread());
        const c = try stage("compositor", rt.Compositor.create());
        const target = try stage("desktop-window-target", c.createTarget(hwnd, false));
        const root = try stage("visuals", c.createContainerVisual());
        try stage("visuals", rt.targetSetRoot(target, root));
        const desk = try c.createSpriteVisual();
        const blade = try c.createSpriteVisual();
        const card = try c.createSpriteVisual();
        try sprite(c, root, desk, .{ .a = 255, .r = 0x16, .g = 0x18, .b = 0x1d }, .{ .x = 0, .y = 0, .z = 0 }, .{ .x = client_w, .y = client_h });
        try sprite(c, root, blade, .{ .a = 255, .r = 0x2b, .g = 0x6c, .b = 0xd8 }, .{ .x = 0, .y = 0, .z = 0 }, .{ .x = blade_open, .y = client_h });
        try sprite(c, root, card, .{ .a = 255, .r = 0x3a, .g = 0x3f, .b = 0x4a }, .{ .x = blade_open + gutter, .y = 0, .z = 0 }, .{ .x = client_w - blade_open - gutter, .y = client_h });
        return .{
            .dq = dq,
            .compositor = c,
            .target = target,
            .blade = blade,
            .card = card,
            .easing = try c.createCubicBezier(ease_p1, ease_p2),
        };
    }

    fn sprite(c: rt.Compositor, root: rt.Obj, v: rt.Obj, color: rt.Color, off: rt.Vector3, size: rt.Vector2) !void {
        const brush = try c.createColorBrush(color);
        defer rt.release(brush);
        try rt.spriteSetBrush(v, brush);
        try rt.visualSetOffset(v, off);
        try rt.visualSetSize(v, size);
        try rt.containerAppend(root, v);
    }

    /// One glide is three declarations; DWM runs them from here on.
    fn glide(self: *Comp, i: u32) !void {
        const from = bladeStart(i);
        const to = bladeTarget(i);
        const d = rt.ms(opts.duration_ms);

        const bsize = try self.compositor.createVector2Animation();
        defer rt.release(bsize);
        try rt.vector2InsertKey(bsize, 0, .{ .x = from, .y = client_h }, self.easing);
        try rt.vector2InsertKey(bsize, 1, .{ .x = to, .y = client_h }, self.easing);
        try rt.animationSetDuration(bsize, d);

        const coff = try self.compositor.createVector3Animation();
        defer rt.release(coff);
        try rt.vector3InsertKey(coff, 0, .{ .x = from + gutter, .y = 0, .z = 0 }, self.easing);
        try rt.vector3InsertKey(coff, 1, .{ .x = to + gutter, .y = 0, .z = 0 }, self.easing);
        try rt.animationSetDuration(coff, d);

        const csize = try self.compositor.createVector2Animation();
        defer rt.release(csize);
        try rt.vector2InsertKey(csize, 0, .{ .x = client_w - from - gutter, .y = client_h }, self.easing);
        try rt.vector2InsertKey(csize, 1, .{ .x = client_w - to - gutter, .y = client_h }, self.easing);
        try rt.animationSetDuration(csize, d);

        try rt.startAnimation(self.blade, "Size", bsize);
        try rt.startAnimation(self.card, "Offset", coff);
        try rt.startAnimation(self.card, "Size", csize);
    }
};

var failed_stage: []const u8 = "";

fn stage(comptime name: []const u8, r: anytype) @TypeOf(r) {
    if (r) |_| {} else |_| failed_stage = name;
    return r;
}

var comp: ?Comp = null;

// ---- worker-thread compositor ---------------------------------------------

var worker_tid: std.atomic.Value(u32) = .init(0);
var worker_ready: std.Thread.ResetEvent = .{};
var worker_hr: rt.HRESULT = 0;
var worker_ok: bool = false;

fn workerMain(hwnd: w32.HWND) void {
    var msg: w32.MSG = undefined;
    _ = w32.PeekMessageW(&msg, null, 0, 0, 0); // create this thread's queue
    worker_tid.store(GetCurrentThreadId(), .release);
    var c = Comp.init(hwnd) catch {
        worker_hr = rt.last_hr;
        worker_ready.set();
        return;
    };
    worker_ok = true;
    worker_ready.set();
    while (w32.GetMessageW(&msg, null, 0, 0) > 0) {
        if (msg.message == WM_APP_GLIDE) {
            c.glide(@intCast(msg.wParam)) catch {};
            continue;
        }
        if (msg.message == WM_APP_QUIT) break;
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

// ---- schedule ---------------------------------------------------------------

fn startGlide(hwnd: w32.HWND) void {
    const i = glide_i;
    const t0 = now();
    glides[i] = .{ .t0 = t0, .t1 = t0 + qpcFromMs(opts.duration_ms) };
    running_glide = i;
    switch (opts.mode) {
        .gdi => _ = w32.SetTimer(hwnd, TIMER_STEP, 16, null),
        .comp => switch (opts.thread) {
            .ui => if (comp) |*c| c.glide(i) catch {
                say("GLIDE_ERROR i={d} hr=0x{x}", .{ i, @as(u32, @bitCast(rt.last_hr)) });
            },
            .worker => _ = PostThreadMessageW(worker_tid.load(.acquire), WM_APP_GLIDE, i, 0),
        },
        .idle => {},
    }
    if (opts.stall_ms > 0) _ = w32.SetTimer(hwnd, TIMER_STALL, opts.duration_ms / 2, null);
    glide_i += 1;
    _ = w32.SetTimer(hwnd, TIMER_NEXT, opts.duration_ms + opts.gap_ms, null);
}

fn gdiStep(hwnd: w32.HWND) void {
    const i = running_glide orelse return;
    const g = &glides[i];
    const p: f32 = @floatCast(@min(1.0, @as(f64, @floatFromInt(now() - g.t0)) /
        @as(f64, @floatFromInt(g.t1 - g.t0))));
    const from = bladeStart(i);
    gdiLayout(from + (bladeTarget(i) - from) * bezier(p));
    g.steps += 1;
    if (p >= 1) {
        _ = w32.KillTimer(hwnd, TIMER_STEP);
        running_glide = null;
    }
}

fn finish() void {
    const s = sampler orelse {
        say("SUMMARY mode={s} oracle=UNAVAILABLE (no DCompositionGetFrameId: needs Windows 11)", .{@tagName(opts.mode)});
        return;
    };
    s.stop.store(true, .release);
    if (sampler_thread) |t| t.join();
    say("CLOCK refresh_hz={d:.2} period_ms={d:.3} frames_seen={d} stats_lost={d}", .{
        s.hz,
        s.period * 1000 / @as(f64, @floatFromInt(qpf)),
        s.frames,
        s.lost,
    });
    var scratch: [4096]f64 = undefined;
    var adv_min: f64 = std.math.inf(f64);
    var adv_sum: f64 = 0;
    var skipped: u32 = 0;
    var gap_max: f64 = 0;
    const to_ms = 1000 / @as(f64, @floatFromInt(qpf));
    for (glides[0..glide_i], 0..) |g, i| {
        const sc = stats.score(s.ts[0..s.n], g.t0, g.t1, s.period, &scratch);
        say("GLIDE i={d} dir={s} composes={d} refreshes={d:.1} advance={d:.3} skipped={d} max_gap_ms={d:.2} p95_gap_ms={d:.2} ui_steps={d} stalled_ms={d}", .{
            i,
            if (i % 2 == 0) "collapse" else "expand",
            sc.composes,
            sc.refreshes,
            sc.advance,
            sc.skipped,
            sc.max_gap * to_ms,
            sc.p95_gap * to_ms,
            g.steps,
            g.stalled_ms,
        });
        adv_min = @min(adv_min, sc.advance);
        adv_sum += sc.advance;
        skipped += sc.skipped;
        gap_max = @max(gap_max, sc.max_gap * to_ms);
    }
    say("SUMMARY mode={s} thread={s} stall_ms={d} glides={d} advance_min={d:.3} advance_mean={d:.3} skipped_total={d} max_gap_ms={d:.2}", .{
        @tagName(opts.mode),
        @tagName(opts.thread),
        opts.stall_ms,
        glide_i,
        adv_min,
        adv_sum / @as(f64, @floatFromInt(@max(1, glide_i))),
        skipped,
        gap_max,
    });
}

fn wndProc(hwnd: w32.HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    switch (msg) {
        w32.WM_TIMER => {
            switch (wp) {
                TIMER_NEXT => {
                    _ = w32.KillTimer(hwnd, TIMER_NEXT);
                    if (glide_i < opts.glides) {
                        startGlide(hwnd);
                    } else {
                        finish();
                        _ = w32.DestroyWindow(hwnd);
                    }
                },
                TIMER_STEP => gdiStep(hwnd),
                TIMER_STALL => {
                    _ = w32.KillTimer(hwnd, TIMER_STALL);
                    Sleep(opts.stall_ms);
                    if (glide_i > 0) glides[glide_i - 1].stalled_ms = opts.stall_ms;
                },
                else => {},
            }
            return 0;
        },
        w32.WM_DESTROY => {
            w32.PostQuitMessage(0);
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn registerClass(name: [*:0]const u16, proc: anytype, color: ?u32) void {
    const wc: w32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = proc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = null,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = if (color) |c| w32.CreateSolidBrush(c) else null,
        .lpszMenuName = null,
        .lpszClassName = name,
        .hIconSm = null,
    };
    _ = w32.RegisterClassExW(&wc);
}

fn parseArgs(alloc: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(alloc);
    for (args[1..]) |a| {
        if (std.mem.startsWith(u8, a, "--mode=")) {
            opts.mode = std.meta.stringToEnum(Mode, a[7..]) orelse return error.BadMode;
        } else if (std.mem.startsWith(u8, a, "--thread=")) {
            opts.thread = std.meta.stringToEnum(ThreadKind, a[9..]) orelse return error.BadThread;
        } else if (std.mem.startsWith(u8, a, "--glides=")) {
            opts.glides = @min(64, try std.fmt.parseInt(u32, a[9..], 10));
        } else if (std.mem.startsWith(u8, a, "--duration-ms=")) {
            opts.duration_ms = try std.fmt.parseInt(u32, a[14..], 10);
        } else if (std.mem.startsWith(u8, a, "--gap-ms=")) {
            opts.gap_ms = try std.fmt.parseInt(u32, a[9..], 10);
        } else if (std.mem.startsWith(u8, a, "--stall-ms=")) {
            opts.stall_ms = try std.fmt.parseInt(u32, a[11..], 10);
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            opts.out = a[6..];
        } else return error.UnknownArg;
    }
}

pub fn main() !u8 {
    var gpa: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer gpa.deinit();
    parseArgs(gpa.allocator()) catch |e| {
        say("SPIKE init=FAILED stage=args error={s}", .{@errorName(e)});
        flushReport();
        return 2;
    };
    qpf = @intCast(std.os.windows.QueryPerformanceFrequency());

    const main_class = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyCompSpike");
    const blade_class = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyCompSpikeBlade");
    const card_class = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyCompSpikeCard");
    // COLORREF is 0x00BBGGRR.
    registerClass(main_class, &wndProc, if (opts.mode == .comp) null else 0x001d1816);
    registerClass(blade_class, &w32.DefWindowProcW, 0x00d86c2b);
    registerClass(card_class, &w32.DefWindowProcW, 0x004a3f3a);

    const ex: u32 = w32.WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW |
        (if (opts.mode == .comp) WS_EX_NOREDIRECTIONBITMAP else 0);
    // Window size for a 1000x640 client at 96 dpi; the scene is laid out in
    // client pixels, so exact chrome size does not matter to the oracle.
    const hwnd = w32.CreateWindowExW(
        ex,
        main_class,
        std.unicode.utf8ToUtf16LeStringLiteral("ghoztty comp spike"),
        w32.WS_OVERLAPPEDWINDOW | w32.WS_CLIPCHILDREN,
        40,
        40,
        1016,
        679,
        null,
        null,
        null,
        null,
    ) orelse {
        say("SPIKE init=FAILED stage=window", .{});
        flushReport();
        return 2;
    };
    hwnd_main = hwnd;

    if (opts.mode == .gdi) {
        hwnd_blade = w32.CreateWindowExW(0, blade_class, std.unicode.utf8ToUtf16LeStringLiteral(""), w32.WS_CHILD | WS_VISIBLE, 0, 0, 1, 1, hwnd, null, null, null);
        hwnd_card = w32.CreateWindowExW(0, card_class, std.unicode.utf8ToUtf16LeStringLiteral(""), w32.WS_CHILD | WS_VISIBLE, 0, 0, 1, 1, hwnd, null, null, null);
        gdiLayout(blade_open);
    }

    var target_hr: rt.HRESULT = 0;
    if (opts.mode == .comp) switch (opts.thread) {
        .ui => {
            comp = Comp.init(hwnd) catch {
                say("SPIKE mode=comp thread=ui init=FAILED stage={s} hr=0x{x}", .{ failed_stage, @as(u32, @bitCast(rt.last_hr)) });
                flushReport();
                return 3;
            };
        },
        .worker => {
            _ = std.Thread.spawn(.{}, workerMain, .{hwnd}) catch return 2;
            worker_ready.wait();
            target_hr = worker_hr;
            if (!worker_ok) {
                say("SPIKE mode=comp thread=worker init=FAILED stage={s} hr=0x{x}", .{ failed_stage, @as(u32, @bitCast(worker_hr)) });
                flushReport();
                return 3;
            }
        },
    };

    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
    say("SPIKE mode={s} thread={s} init=ok target_hr=0x{x} glides={d} duration_ms={d} stall_ms={d} ui_tid={d} worker_tid={d}", .{
        @tagName(opts.mode),
        @tagName(opts.thread),
        @as(u32, @bitCast(target_hr)),
        opts.glides,
        opts.duration_ms,
        opts.stall_ms,
        GetCurrentThreadId(),
        worker_tid.load(.acquire),
    });

    startSampler();
    // Warm-up before the first glide: the first composes after showing a
    // window are the window appearing, not the glide.
    _ = w32.SetTimer(hwnd, TIMER_NEXT, 800, null);

    var msg: w32.MSG = undefined;
    while (w32.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
    if (opts.thread == .worker) _ = PostThreadMessageW(worker_tid.load(.acquire), WM_APP_QUIT, 0, 0);
    flushReport();
    return 0;
}

test {
    _ = stats;
    _ = rt;
}

test "the GDI curve matches the compositor's endpoints and is monotonic" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), bezier(0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), bezier(1), 1e-4);
    var prev: f32 = 0;
    var i: u32 = 1;
    while (i <= 20) : (i += 1) {
        const y = bezier(@as(f32, @floatFromInt(i)) / 20);
        try std.testing.expect(y >= prev);
        prev = y;
    }
}
