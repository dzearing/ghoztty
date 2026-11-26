//! What a GTK terminal pane's frames and resizes cost (T3792, Linux): the
//! pure half of the debug `pane-seen` seam's `draw` block.
//!
//! A live window resize on GTK runs on the main thread, once per compositor
//! configure: `glareaResize` (the core's `sizeCallback`) and then
//! `glareaRender` (`drawFrame`). Whether a drag "feels slow" is a question
//! about those two numbers and about the gaps between frames, so the seam
//! reports all three and a test can measure a resize storm instead of
//! guessing at it. Counters only - no allocation, no GTK - so it costs a
//! clock read per frame and is safe to keep in every build.
const std = @import("std");

/// One running series of durations (or gaps): count, total, worst.
pub const Series = struct {
    count: u32 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,

    pub fn add(self: *Series, ns: u64) void {
        self.count +%= 1;
        self.total_ns +%= ns;
        if (ns > self.max_ns) self.max_ns = ns;
    }

    /// The mean in microseconds, 0 when empty.
    pub fn meanUs(self: Series) u64 {
        if (self.count == 0) return 0;
        return self.total_ns / self.count / std.time.ns_per_us;
    }

    pub fn maxUs(self: Series) u64 {
        return self.max_ns / std.time.ns_per_us;
    }
};

pub const DrawStats = struct {
    /// `drawFrame` calls from the GL area's render signal.
    draws: Series = .{},
    /// The core's resize work per GL area resize that changed the size.
    resizes: Series = .{},
    /// The gap between consecutive draws that ran while resizes were
    /// arriving - the frame interval a person sees during a drag. A gap
    /// spanning an idle stretch (no resize since the previous draw) is not
    /// a dropped frame and is not counted.
    resize_gaps: Series = .{},
    /// Monotonic ns of the last draw's start, 0 before the first.
    last_draw_ns: u64 = 0,
    /// A resize has arrived since the last draw.
    resized_since_draw: bool = false,

    pub fn recordResize(self: *DrawStats, ns: u64) void {
        self.resizes.add(ns);
        self.resized_since_draw = true;
    }

    /// `start_ns` is the draw's monotonic start, `ns` its duration.
    pub fn recordDraw(self: *DrawStats, start_ns: u64, ns: u64) void {
        if (self.resized_since_draw and self.last_draw_ns != 0 and start_ns > self.last_draw_ns)
            self.resize_gaps.add(start_ns - self.last_draw_ns);
        self.resized_since_draw = false;
        self.last_draw_ns = start_ns;
        self.draws.add(ns);
    }

    pub fn reset(self: *DrawStats) void {
        self.* = .{};
    }
};

test "Series keeps count, mean and worst" {
    var s: Series = .{};
    try std.testing.expectEqual(@as(u64, 0), s.meanUs());
    s.add(2 * std.time.ns_per_ms);
    s.add(4 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 2), s.count);
    try std.testing.expectEqual(@as(u64, 3000), s.meanUs());
    try std.testing.expectEqual(@as(u64, 4000), s.maxUs());
}

test "a gap counts only when a resize came between two draws" {
    var d: DrawStats = .{};
    const ms = std.time.ns_per_ms;
    d.recordDraw(100 * ms, 1 * ms); // first draw: no gap yet
    d.recordDraw(5000 * ms, 1 * ms); // idle redraw: no resize, no gap
    try std.testing.expectEqual(@as(u32, 0), d.resize_gaps.count);
    d.recordResize(2 * ms);
    d.recordDraw(5016 * ms, 1 * ms);
    d.recordResize(2 * ms);
    d.recordDraw(5066 * ms, 1 * ms);
    try std.testing.expectEqual(@as(u32, 2), d.resize_gaps.count);
    try std.testing.expectEqual(@as(u64, 50_000), d.resize_gaps.maxUs());
    try std.testing.expectEqual(@as(u32, 4), d.draws.count);
    try std.testing.expectEqual(@as(u32, 2), d.resizes.count);
    d.reset();
    try std.testing.expectEqual(@as(u32, 0), d.draws.count);
    try std.testing.expectEqual(@as(u64, 0), d.last_draw_ns);
}
