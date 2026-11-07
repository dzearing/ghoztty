//! `GHOZTTY_RESIZE_TRACE` (T2516, T2577): QPC stamps on a window resize's
//! messages and on every phase of its layout pass, from the UI thread and the
//! pane renderer threads, so a film of the window can be lined up against the
//! pass that should have painted each frame.
//!
//! Since T2600 the lines are kept in memory and written out once the resize
//! has gone quiet. Each stamp used to format and write its log line on the
//! spot - ~0.2 ms apart back to back (T2593) - and a pass carries ~15 of
//! them, so the trace added a few ms to the very ~6 ms pass it measured. A
//! slot in a `trace_ring.Ring` costs microseconds; the text written out is
//! byte for byte what was logged before, so every reader keeps working.
//! `GHOZTTY_RESIZE_TRACE=log` keeps the old write-as-you-go behaviour.
//!
//! The writer is `Window`: it arms a timer on its first traced message and
//! calls `flush` when the size loop has ended and no layout pass has stamped
//! for `quiet_ms` (and on `WM_DESTROY`), so the write never lands inside a
//! pass that is being timed.
const std = @import("std");
const w32 = @import("win32.zig");
const trace_ring = @import("trace_ring.zig");

/// Window's scope, so a flushed line reads exactly as it did when logged.
const log = std.log.scoped(.win32);

/// How long the layout pass must have been quiet before the ring is written.
pub const quiet_ms: i64 = 250;

var mode_state: ?trace_ring.Mode = null;

pub fn mode() trace_ring.Mode {
    if (mode_state) |m| return m;
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_RESIZE_TRACE") catch null;
    defer if (raw) |r| std.heap.page_allocator.free(r);
    const m = trace_ring.resizeModeOf(raw);
    mode_state = m;
    return m;
}

pub fn on() bool {
    return mode() != .off;
}

/// 16384 lines of 224 bytes, zeroed, so the pages stay untouched unless the
/// knob is set. The longest line (`resize trace viewer ...`) is ~190 bytes.
var ring: trace_ring.Ring(16384, 224) = .{};
/// Every pane renders on its own thread and stamps here too.
var lock: std.Thread.Mutex = .{};

/// What a `stamp` itself cost, for the flush's header line (T2600): the
/// trace's own price, measured where it is paid.
var cost: struct { stamps: u64 = 0, ticks: i64 = 0, max: i64 = 0 } = .{};

/// The last layout-pass stamp, on the QPC clock: what `quiet` reads.
var last_stamp = std.atomic.Value(i64).init(0);

/// UI thread only: a flush timer is pending on some window.
pub var armed: bool = false;

/// One trace line, in the ring or (`log` mode) straight to the log.
pub fn line(comptime fmt: []const u8, args: anytype) void {
    switch (mode()) {
        .off => {},
        .log => log.info(fmt, args),
        .ring => {
            lock.lock();
            defer lock.unlock();
            ring.add(fmt, args);
        },
    }
}

/// `resize trace <what> qpc=<t> w=<window width>`: one phase of a layout pass.
pub fn stamp(comptime what: []const u8, hwnd: w32.HWND) void {
    if (!on()) return;
    var t: i64 = 0;
    _ = w32.QueryPerformanceCounter(&t);
    var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetWindowRect(hwnd, &r);
    line("resize trace " ++ what ++ " qpc={d} w={d}", .{ t, r.right - r.left });
    last_stamp.store(t, .monotonic);
    var t1: i64 = 0;
    _ = w32.QueryPerformanceCounter(&t1);
    lock.lock();
    defer lock.unlock();
    cost.stamps += 1;
    cost.ticks += t1 - t;
    cost.max = @max(cost.max, t1 - t);
}

/// `resize trace msg=0x<msg> qpc=<t> w=<window width>`: a top-level message.
pub fn msg(hwnd: w32.HWND, m: u32) void {
    var t: i64 = 0;
    _ = w32.QueryPerformanceCounter(&t);
    var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetWindowRect(hwnd, &r);
    line("resize trace msg=0x{x} qpc={d} w={d}", .{ m, t, r.right - r.left });
}

/// Ring mode with nothing pending yet: the caller should arm its timer.
pub fn wantsTimer() bool {
    return !armed and mode() == .ring;
}

/// No layout pass has stamped for `quiet_ms`.
pub fn quiet() bool {
    var now: i64 = 0;
    _ = w32.QueryPerformanceCounter(&now);
    return @divTrunc((now - last_stamp.load(.monotonic)) * 1000, freq()) >= quiet_ms;
}

fn freq() i64 {
    var f: i64 = 0;
    _ = w32.QueryPerformanceFrequency(&f);
    return @max(f, 1);
}

/// Write the ring out, oldest first, behind one header line that is not a
/// `resize trace` line (no reader's pattern can mistake it for a phase).
pub fn flush() void {
    if (mode() != .ring) return;
    lock.lock();
    defer lock.unlock();
    if (ring.count == 0) return;
    const f = freq();
    const avg_ns: i64 = if (cost.stamps == 0) 0 else @divTrunc(@divTrunc(cost.ticks * 1_000_000_000, f), @as(i64, @intCast(cost.stamps)));
    log.info("trace ring resize lines={d} dropped={d} stamps={d} stamp_avg_ns={d} stamp_max_ns={d}", .{
        ring.count, ring.dropped, cost.stamps, avg_ns, @divTrunc(cost.max * 1_000_000_000, f),
    });
    var it = ring.iterator();
    while (it.next()) |l| log.info("{s}", .{l});
    ring.clear();
    cost = .{};
}
