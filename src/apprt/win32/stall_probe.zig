//! Where a stalled glide tick waited (T2952), under `GHOZTTY_STACK_TRACE`.
//!
//! A rare 4K fold-glide tick runs 20-40 ms where its neighbours run 5: a
//! desk blit of almost no area, or a pane's present at its new size, blocks
//! for a frame or more while the box is otherwise idle (32 cores, under two
//! busy). Three questions settle whose wait that is, and this answers them
//! for every laid tick:
//!
//! - **Did the UI thread run, or wait?** Its own CPU time (thread cycles)
//!   against the tick's wall time. A stall with few cycles was spent blocked
//!   (or descheduled), not computing.
//! - **Which call?** Every desk blit to the window is timed on its own, with
//!   its cycles: the longest one, and the sum.
//! - **Was the compositor composing?** The frames DWM completed while the
//!   tick ran (`DCompositionGetFrameId`/`DCompositionGetStatistics`, Windows
//!   11) and the longest stretch with none (`compose_gap.zig`).
//!
//! Off - one load of a bool per blit - unless the trace is on.
const std = @import("std");
const w32 = @import("win32.zig");
const compose_gap = @import("compose_gap.zig");

/// Set for the length of a traced glide tick; blits outside one are not
/// counted.
pub var armed: bool = false;

var tick_qpc: i64 = 0;
var tick_cycles: u64 = 0;
var tick_frame: u64 = 0;
var blits: u32 = 0;
var blit_sum: i64 = 0;
var blit_max: i64 = 0;
var blit_max_cycles: u64 = 0;
var blit_max_kind: Kind = .none;
var blit_max_area: i64 = 0;
var cycles_per_us: ?f64 = null;

/// What a timed blit was: a DIB straight to the window (`stretch`), a DC
/// to DC copy GDI may batch (`bitblt`), or the flush that puts a batch out.
pub const Kind = enum(u8) { none, stretch, bitblt, flush };

pub const Report = struct {
    /// The UI thread's own CPU over the tick, in microseconds.
    cpu_us: i64 = 0,
    blits: u32 = 0,
    blit_sum_us: i64 = 0,
    blit_max_us: i64 = 0,
    /// The UI thread's CPU inside the longest blit.
    blit_max_cpu_us: i64 = 0,
    blit_max_kind: Kind = .none,
    /// The longest blit's area in pixels (0 for a flush).
    blit_max_area: i64 = 0,
    /// Frames DWM completed during the tick; -1 where it cannot be asked.
    dwm_frames: i32 = -1,
    /// The longest stretch inside the tick with no completed frame.
    dwm_gap_us: i64 = 0,
    /// How far DWM's completed-frame id moved over the tick; -1 where it
    /// cannot be asked. Kept beside `dwm_frames`, whose targets can fall
    /// before the tick began (a frame aimed at an earlier vblank completes
    /// inside it).
    dwm_ids: i64 = -1,
    /// The tick's end less the target vblank of the newest completed frame:
    /// how stale DWM's last compose was when the tick finished.
    dwm_age_us: i64 = 0,
};

/// One timed blit; `end` it when the call returns.
pub const Lap = struct {
    qpc: i64 = 0,
    cycles: u64 = 0,
    kind: Kind = .none,
    area: i64 = 0,

    pub fn end(self: Lap) void {
        if (self.qpc == 0) return;
        var q: i64 = 0;
        var c: u64 = 0;
        _ = w32.QueryPerformanceCounter(&q);
        _ = w32.QueryThreadCycleTime(w32.GetCurrentThread(), &c);
        const d = q - self.qpc;
        blits +|= 1;
        blit_sum +|= d;
        if (d > blit_max) {
            blit_max = d;
            blit_max_cycles = c -% self.cycles;
            blit_max_kind = self.kind;
            blit_max_area = self.area;
        }
    }
};

pub fn blitBegin(kind: Kind, w: i32, h: i32) Lap {
    if (!armed) return .{};
    var l: Lap = .{ .kind = kind, .area = @as(i64, @max(w, 0)) * @max(h, 0) };
    _ = w32.QueryThreadCycleTime(w32.GetCurrentThread(), &l.cycles);
    _ = w32.QueryPerformanceCounter(&l.qpc);
    return l;
}

/// The start of a traced tick.
pub fn tickBegin() void {
    if (cycles_per_us == null) calibrate();
    blits = 0;
    blit_sum = 0;
    blit_max = 0;
    blit_max_cycles = 0;
    blit_max_kind = .none;
    blit_max_area = 0;
    tick_frame = completedFrame() orelse 0;
    _ = w32.QueryThreadCycleTime(w32.GetCurrentThread(), &tick_cycles);
    _ = w32.QueryPerformanceCounter(&tick_qpc);
    armed = true;
}

/// The end of a traced tick: what it ran, what it blitted, what DWM did.
pub fn tickEnd() Report {
    armed = false;
    var q: i64 = 0;
    var c: u64 = 0;
    _ = w32.QueryPerformanceCounter(&q);
    _ = w32.QueryThreadCycleTime(w32.GetCurrentThread(), &c);
    var r: Report = .{
        .cpu_us = cyclesUs(c -% tick_cycles),
        .blits = blits,
        .blit_sum_us = qpcUs(blit_sum),
        .blit_max_us = qpcUs(blit_max),
        .blit_max_cpu_us = cyclesUs(blit_max_cycles),
        .blit_max_kind = blit_max_kind,
        .blit_max_area = blit_max_area,
    };
    if (tick_frame != 0) if (completedFrame()) |last| {
        r.dwm_ids = @as(i64, @intCast(last)) - @as(i64, @intCast(tick_frame));
        if (frameTarget(last)) |t| r.dwm_age_us = qpcUs(q - t);
        var targets: [32]i64 = undefined;
        var n: usize = 0;
        // Back from the last completed frame to the one the tick began on:
        // DWM keeps only recent frames' statistics, so the newest go first.
        var id = last;
        while (id > tick_frame and n < targets.len) : (id -= 1) {
            if (frameTarget(id)) |t| {
                targets[n] = t;
                n += 1;
            }
        }
        std.mem.reverse(i64, targets[0..n]);
        const g = compose_gap.score(targets[0..n], tick_qpc, q);
        r.dwm_frames = @intCast(g.frames);
        r.dwm_gap_us = qpcUs(g.max_gap);
    };
    return r;
}

fn calibrate() void {
    const th = w32.GetCurrentThread();
    var c0: u64 = 0;
    var c1: u64 = 0;
    var q0: i64 = 0;
    var q1: i64 = 0;
    _ = w32.QueryThreadCycleTime(th, &c0);
    _ = w32.QueryPerformanceCounter(&q0);
    while (true) {
        _ = w32.QueryPerformanceCounter(&q1);
        if (qpcUs(q1 - q0) >= 3000) break;
    }
    _ = w32.QueryThreadCycleTime(th, &c1);
    const us: f64 = @floatFromInt(qpcUs(q1 - q0));
    cycles_per_us = @as(f64, @floatFromInt(c1 -% c0)) / @max(us, 1);
}

fn cyclesUs(c: u64) i64 {
    const rate = cycles_per_us orelse return 0;
    return @intFromFloat(@as(f64, @floatFromInt(c)) / @max(rate, 1));
}

fn qpcUs(t: i64) i64 {
    const S = struct {
        var f: i64 = 0;
    };
    if (S.f == 0) {
        _ = w32.QueryPerformanceFrequency(&S.f);
        S.f = @max(S.f, 1);
    }
    return @divTrunc(t * 1_000_000, S.f);
}

const FrameStats = extern struct { start: u64, target: u64, period: u64 };
const GetIdFn = *const fn (u32, *u64) callconv(.winapi) i32;
const GetStatsFn = *const fn (u64, *FrameStats, u32, ?*anyopaque, ?*u32) callconv(.winapi) i32;
var loaded = false;
var get_id: ?GetIdFn = null;
var get_stats: ?GetStatsFn = null;

fn load() void {
    if (loaded) return;
    loaded = true;
    const lib = w32.LoadLibraryExW(
        std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll"),
        null,
        w32.LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) orelse return;
    if (w32.GetProcAddress(lib, "DCompositionGetFrameId")) |p| get_id = @ptrCast(p);
    if (w32.GetProcAddress(lib, "DCompositionGetStatistics")) |p| get_stats = @ptrCast(p);
}

/// The id of the last frame DWM finished composing
/// (COMPOSITION_FRAME_ID_COMPLETED).
fn completedFrame() ?u64 {
    load();
    const f = get_id orelse return null;
    var id: u64 = 0;
    if (f(2, &id) < 0 or id == 0) return null;
    return id;
}

/// The vblank frame `id` was composed for, in QPC ticks.
fn frameTarget(id: u64) ?i64 {
    const f = get_stats orelse return null;
    var st: FrameStats = undefined;
    if (f(id, &st, 0, null, null) < 0 or st.target == 0) return null;
    return @intCast(st.target);
}
