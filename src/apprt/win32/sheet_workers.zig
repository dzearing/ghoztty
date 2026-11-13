//! Glass sheets rendered across a small persistent pool of workers (T2702).
//!
//! On glass a viewer host lays `pane_elevation.glassSheetRegion` under its
//! whole client on every paint, and an edge drag changes the desk size every
//! step, so nothing can be reused: ~420k px a step, 1.5 ms ReleaseFast and
//! 3.8 ms Debug on the UI thread (T2695's `burst-sheet` trace). Each row of the
//! region is a pure function of its y, so the rows are split into bands, the
//! bands go to the workers, and the calling thread renders a band of its own
//! while it waits. The pixels are byte-for-byte `glassSheetRegion`'s - the
//! bands are the same function over the same rows - which is what the viewer's
//! pixel probes, and the tests below, compare against.
//!
//! The pool is made once, on the first region big enough to want it, and lives
//! for the process. A box with one CPU, a pool that could not be made, or a
//! region under `min_parallel_px` renders on the caller exactly as before.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const color_math = @import("color_math.zig");
const desk_palette = @import("desk_palette.zig");
const pane_elevation = @import("pane_elevation.zig");

/// Below this many pixels the hand-off costs more than it saves: a worker's
/// wake-up is tens of microseconds, and a 256x256 region renders in about that.
pub const min_parallel_px: usize = 64 * 1024;

/// At most this many workers beside the caller. The sheet is memory-light
/// arithmetic, so a few bands take most of the win, and a drag must not
/// occupy every core of the box the user is working on. Measured on a 700x600
/// sheet, ReleaseFast for the shipped x86-64 baseline (32-CPU box): serial
/// 1.10 ms; 3 workers 0.29 ms, 4 workers 0.25 ms, 6 workers 0.21 ms.
pub const max_workers: usize = 4;

var pool: std.Thread.Pool = undefined;
var pool_workers: usize = 0;
var pool_once = std.once(initPool);

fn initPool() void {
    if (builtin.single_threaded) return;
    const cpus = std.Thread.getCpuCount() catch 1;
    const want = @min(cpus -| 1, max_workers);
    if (want == 0) return;
    pool.init(.{ .allocator = std.heap.smp_allocator, .n_jobs = want }) catch return;
    pool_workers = want;
}

/// The shared pool for other pure per-pixel work (T2946: a desk's partial
/// compose), and how many workers it has beside the caller; null on a box with
/// one CPU or where the pool could not be made. The same pool as the sheets':
/// a drag runs one or the other on a tick, never both at once.
pub fn shared() ?struct { pool: *std.Thread.Pool, workers: usize } {
    pool_once.call();
    if (pool_workers == 0) return null;
    return .{ .pool = &pool, .workers = pool_workers };
}

/// Bands per thread (the workers and the caller). One band each left the whole
/// sheet waiting on whichever worker woke last: in a Debug viewer edge drag the
/// render read ~0.85 ms on most steps and 1.4-2.0 ms on a third of them, one
/// band's worth late (T2715). With several small bands a thread that is
/// awake takes the next one off the queue - the caller included, through
/// `waitAndWork` - so a late worker costs at most a small band.
pub const bands_per_thread: usize = 4;

/// No band smaller than this: below it the hand-off is a real share of the
/// band's own cost.
pub const min_band_px: usize = 16 * 1024;

/// How many bands a `w` x `h` region is cut into: 1 (the caller alone) when it
/// is small or there are no workers, else `bands_per_thread` for each worker
/// and the caller - fewer when that would make a band under `min_band_px`,
/// never fewer than one per thread, never more than there are rows.
pub fn bandCount(w: usize, h: usize, workers: usize) usize {
    if (workers == 0 or h < 2 or w * h < min_parallel_px) return 1;
    const threads = workers + 1;
    const by_size = @max(w * h / min_band_px, threads);
    return @min(@min(threads * bands_per_thread, by_size), h);
}

/// The rows of band `i` of `bands` over `h` rows: [start, end). Bands differ by
/// at most one row, so no band is left holding the tail of the work.
pub fn bandRows(h: usize, bands: usize, i: usize) struct { start: usize, end: usize } {
    return .{ .start = h * i / bands, .end = h * (i + 1) / bands };
}

fn renderBand(
    out: []u32,
    w: usize,
    start: usize,
    end: usize,
    rx: i32,
    ry: i32,
    full_w: i32,
    full_h: i32,
    pal: desk_palette.Palette,
    tint: color_math.Rgb,
    sheet: pane_elevation.Sheet,
) void {
    if (end <= start) return;
    pane_elevation.glassSheetRegion(
        out[start * w .. end * w],
        w,
        end - start,
        rx,
        ry + @as(i32, @intCast(start)),
        full_w,
        full_h,
        pal,
        tint,
        sheet,
    );
}

/// `pane_elevation.glassSheetRegion`, with the rows shared among the workers.
/// Same arguments, same pixels.
pub fn glassSheetRegion(
    out: []u32,
    w: usize,
    h: usize,
    rx: i32,
    ry: i32,
    full_w: i32,
    full_h: i32,
    pal: desk_palette.Palette,
    tint: color_math.Rgb,
    sheet: pane_elevation.Sheet,
) void {
    std.debug.assert(out.len >= w * h);
    if (w * h >= min_parallel_px) pool_once.call();
    const bands = bandCount(w, h, pool_workers);
    if (bands <= 1) {
        pane_elevation.glassSheetRegion(out, w, h, rx, ry, full_w, full_h, pal, tint, sheet);
        return;
    }
    var wg: std.Thread.WaitGroup = .{};
    for (1..bands) |i| {
        const b = bandRows(h, bands, i);
        pool.spawnWg(&wg, renderBand, .{ out, w, b.start, b.end, rx, ry, full_w, full_h, pal, tint, sheet });
    }
    const first = bandRows(h, bands, 0);
    renderBand(out, w, first.start, first.end, rx, ry, full_w, full_h, pal, tint, sheet);
    pool.waitAndWork(&wg);
}

test "T2702: bands cover every row exactly once" {
    for ([_]usize{ 2, 3, 7, 100, 333, 1080 }) |h| {
        for (1..6) |bands| {
            if (bands > h) continue;
            var next: usize = 0;
            for (0..bands) |i| {
                const b = bandRows(h, bands, i);
                try testing.expectEqual(next, b.start);
                try testing.expect(b.end >= b.start);
                try testing.expect(b.end - b.start + 1 >= h / bands);
                next = b.end;
            }
            try testing.expectEqual(h, next);
        }
    }
}

test "T2702: a small region, a one-row region or no workers stays on the caller" {
    try testing.expectEqual(@as(usize, 1), bandCount(100, 100, 3));
    try testing.expectEqual(@as(usize, 1), bandCount(1_000_000, 1, 3));
    try testing.expectEqual(@as(usize, 1), bandCount(1000, 1000, 0));
    try testing.expectEqual(@as(usize, 3), bandCount(100_000, 3, 7));
}

test "T2715: a big region is cut into several bands a thread, none tiny" {
    // A viewer's client (481x864, 4 workers): 4 bands for each of 5 threads.
    try testing.expectEqual(@as(usize, 20), bandCount(481, 864, 4));
    // 1000x1000, 3 workers: 16 bands, each ~62k px.
    try testing.expectEqual(@as(usize, 16), bandCount(1000, 1000, 3));
    // Just over the parallel threshold: the size floor holds it to one band
    // a thread, not 4.
    const n = bandCount(256, 260, 4);
    try testing.expectEqual(@as(usize, 5), n);
    // Never a band under the floor once there is more than one a thread.
    for ([_][2]usize{ .{ 481, 864 }, .{ 300, 400 }, .{ 1920, 1080 }, .{ 700, 600 } }) |c| {
        const b = bandCount(c[0], c[1], 4);
        if (b > 5) try testing.expect(c[0] * c[1] / b >= min_band_px);
    }
}

test "T2702: the shared sheet is byte-identical to the serial one" {
    const alloc = testing.allocator;
    const tint: color_math.Rgb = .{ .r = 0x1E, .g = 0x22, .b = 0x2A };
    const Case = struct { w: usize, h: usize, rx: i32, ry: i32, fw: i32, fh: i32, sheet: pane_elevation.Sheet, light: bool };
    const cases = [_]Case{
        // A viewer pane's client: wide, tall, off the desk's origin.
        .{ .w = 700, .h = 600, .rx = 310, .ry = 42, .fw = 1600, .fh = 900, .sheet = .{}, .light = false },
        // Odd sizes, so bands are uneven and the SIMD tail is exercised.
        .{ .w = 517, .h = 263, .rx = -5, .ry = 13, .fw = 900, .fh = 700, .sheet = .{ .t = 0.3, .fade = 0.25 }, .light = true },
        // Running past the desk's far edge (the plain tint there).
        .{ .w = 400, .h = 400, .rx = 1500, .ry = 800, .fw = 1600, .fh = 900, .sheet = .{}, .light = true },
        // Under the threshold: the serial path through the same entry point.
        .{ .w = 64, .h = 64, .rx = 0, .ry = 0, .fw = 800, .fh = 600, .sheet = .{}, .light = false },
    };
    for (cases) |c| {
        const pal = desk_palette.Palette.ocean(c.light);
        const want = try alloc.alloc(u32, c.w * c.h);
        defer alloc.free(want);
        const got = try alloc.alloc(u32, c.w * c.h);
        defer alloc.free(got);
        @memset(got, 0xDEAD_BEEF);
        pane_elevation.glassSheetRegion(want, c.w, c.h, c.rx, c.ry, c.fw, c.fh, pal, tint, c.sheet);
        glassSheetRegion(got, c.w, c.h, c.rx, c.ry, c.fw, c.fh, pal, tint, c.sheet);
        try testing.expectEqualSlices(u32, want, got);
    }
}

test "T2702: the pool is shared, not remade per region" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const pal = desk_palette.Palette.ocean(false);
    const tint: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const buf = try testing.allocator.alloc(u32, 512 * 512);
    defer testing.allocator.free(buf);
    glassSheetRegion(buf, 512, 512, 0, 0, 1024, 1024, pal, tint, .{});
    const first = pool_workers;
    glassSheetRegion(buf, 512, 512, 0, 0, 1024, 1024, pal, tint, .{});
    try testing.expectEqual(first, pool_workers);
    try testing.expect(pool_workers <= max_workers);
}
