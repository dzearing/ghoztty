//! When a pane's grow-only GPU storage gives back what it no longer needs
//! (T2974).
//!
//! On Win32 a pane's render target, the composition path's shared texture and
//! swap chain, and the window presenter's slot textures all grow in 256 px
//! buckets and keep any larger allocation (T2577/T2598): a window-edge drag
//! changes the size on every step, and rebuilding the storage per step was
//! most of the first frame at each size. Left at that, the storage only ever
//! grows - a pane that was once maximized on a 4K screen kept ~150 MB of GPU
//! memory for life, whatever its size now.
//!
//! The policy here keeps grow-only exactly where it pays (while the size is
//! moving) and trims once the size has held still for `settle_ns`: one
//! rebuild frame per settle, never mid-drag. Pure, so the none lane tests it.
const std = @import("std");

/// How long the size must hold still before oversized storage is trimmed.
/// Long enough that a drag, a glide or a maximize animation never pays a
/// rebuild in the middle; short enough that the memory comes back while the
/// user is still looking at the result.
pub const settle_ns: u64 = std.time.ns_per_s;

/// How many trim frames one settle may spend. A trim that leaves storage
/// oversized (the window presenter has two slots and draws one per frame)
/// earns another try; past this, the pane stops waking itself for it until
/// the size moves again, so a surface that cannot shrink costs nothing.
pub const max_attempts: u8 = 3;

/// `GHOZTTY_STORAGE_TRIM=0` keeps storage at its high-water size, as before
/// T2974: the A/B knob, and the negative control of
/// `test\win32\storage-trim-memory.ps1`. Read once per process.
pub fn enabled() bool {
    const cached = enabled_cache.load(.acquire);
    if (cached != 0) return cached == 1;
    const on = knobOn();
    enabled_cache.store(if (on) 1 else 2, .release);
    return on;
}

var enabled_cache: std.atomic.Value(u8) = .init(0);

fn knobOn() bool {
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_STORAGE_TRIM") catch return true;
    defer std.heap.page_allocator.free(raw);
    return knobValue(raw);
}

/// Only an explicit off turns it off.
pub fn knobValue(raw: []const u8) bool {
    const v = std.mem.trim(u8, raw, " \t");
    return !(std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "false"));
}

/// The storage a grow-only surface allocates for a `need` px side.
pub fn bucketed(need: usize, bucket: usize) usize {
    return (std.math.divCeil(usize, @max(need, 1), bucket) catch unreachable) * bucket;
}

/// The storage holds more than a fresh allocation for `need` would.
pub fn oversized(have: usize, need: usize, bucket: usize) bool {
    return have > bucketed(need, bucket);
}

/// `oversized` on either axis.
pub fn oversized2(have_w: usize, have_h: usize, need_w: usize, need_h: usize, bucket: usize) bool {
    return oversized(have_w, need_w, bucket) or oversized(have_h, need_h, bucket);
}

/// Nanoseconds left before a size last changed `elapsed_ns` ago counts as
/// settled; 0 once it has. A null elapsed (no change seen yet, or no clock)
/// counts as settled: nothing is moving.
pub fn remainingNs(elapsed_ns: ?u64) u64 {
    const e = elapsed_ns orelse return 0;
    return if (e >= settle_ns) 0 else settle_ns - e;
}

/// The milliseconds to wait before the trim frame, rounded up so the timer
/// never fires a hair before the settle and finds nothing to do; at least 1.
pub fn waitMs(remaining_ns: u64) u64 {
    return @max(1, std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch unreachable);
}

/// One pane's settle tracking. Renderer thread only.
pub const Settle = struct {
    w: u32 = 0,
    h: u32 = 0,
    changed_at: ?std.time.Instant = null,
    /// Trim frames spent since the size last moved.
    attempts: u8 = 0,
    /// The last frame left some storage oversized (`OpenGL.noteStorage`).
    oversized: bool = false,

    /// Record the size the frame in progress is drawn at.
    pub fn note(self: *Settle, w: u32, h: u32, now: ?std.time.Instant) void {
        if (w == self.w and h == self.h) return;
        self.w = w;
        self.h = h;
        self.changed_at = now;
        self.attempts = 0;
    }

    fn elapsed(self: *const Settle, now: ?std.time.Instant) ?u64 {
        const c = self.changed_at orelse return null;
        const n = now orelse return null;
        return n.since(c);
    }

    /// Whether the frame in progress should trim: settled, something was
    /// oversized, and the settle has tries left. Spends one when true.
    pub fn takeTrim(self: *Settle, now: ?std.time.Instant) bool {
        return self.takeTrimAfter(self.elapsed(now));
    }

    pub fn takeTrimAfter(self: *Settle, elapsed_ns: ?u64) bool {
        if (!self.oversized or self.attempts >= max_attempts) return false;
        if (remainingNs(elapsed_ns) != 0) return false;
        self.attempts += 1;
        return true;
    }

    /// Milliseconds until a frame should come back to trim, or null when
    /// nothing is owed (nothing oversized, or the tries are spent).
    pub fn dueInMs(self: *const Settle, now: ?std.time.Instant) ?u64 {
        return self.dueInMsAfter(self.elapsed(now));
    }

    pub fn dueInMsAfter(self: *const Settle, elapsed_ns: ?u64) ?u64 {
        if (!self.oversized or self.attempts >= max_attempts) return null;
        return waitMs(remainingNs(elapsed_ns));
    }
};

test "knobValue: only an explicit off disables the trim" {
    const t = std.testing;
    try t.expect(!knobValue("0"));
    try t.expect(!knobValue(" off "));
    try t.expect(!knobValue("FALSE"));
    try t.expect(knobValue("1"));
    try t.expect(knobValue(""));
}

test "bucketed and oversized follow the 256 px grow bucket" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 512), bucketed(469, 256));
    try t.expectEqual(@as(usize, 256), bucketed(256, 256));
    try t.expectEqual(@as(usize, 256), bucketed(0, 256));
    // A pane once 1400 px wide, now 451: 1536 is three buckets too many.
    try t.expect(oversized(1536, 451, 256));
    // Inside its own bucket is not oversized: that is the grow-only slack.
    try t.expect(!oversized(512, 451, 256));
    try t.expect(!oversized(512, 512, 256));
    try t.expect(oversized2(512, 1024, 500, 700, 256));
    try t.expect(!oversized2(512, 768, 500, 700, 256));
}

test "remainingNs and waitMs: settled after one quiet second" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 0), remainingNs(null));
    try t.expectEqual(@as(u64, 0), remainingNs(settle_ns));
    try t.expectEqual(@as(u64, 0), remainingNs(settle_ns + 5));
    try t.expectEqual(settle_ns - 1, remainingNs(1));
    try t.expectEqual(@as(u64, 1), waitMs(0));
    try t.expectEqual(@as(u64, 1), waitMs(1));
    try t.expectEqual(@as(u64, 1000), waitMs(settle_ns));
    try t.expectEqual(@as(u64, 2), waitMs(std.time.ns_per_ms + 1));
}

test "Settle: no trim mid-move, one trim once settled, re-armed by a move" {
    const t = std.testing;
    var s: Settle = .{};
    // Nothing oversized: never due, never trims.
    try t.expectEqual(@as(?u64, null), s.dueInMsAfter(settle_ns));
    try t.expect(!s.takeTrimAfter(settle_ns));

    s.oversized = true;
    // Mid-move (the size changed 100 ms ago): due later, no trim now.
    try t.expectEqual(@as(?u64, 900), s.dueInMsAfter(100 * std.time.ns_per_ms));
    try t.expect(!s.takeTrimAfter(100 * std.time.ns_per_ms));
    // Settled: trims, spending a try.
    try t.expect(s.takeTrimAfter(settle_ns));
    try t.expectEqual(@as(u8, 1), s.attempts);
    // The trim fixed it: nothing more is owed.
    s.oversized = false;
    try t.expectEqual(@as(?u64, null), s.dueInMsAfter(2 * settle_ns));

    // A trim that cannot shrink stops after max_attempts.
    s.oversized = true;
    var n: u8 = 1;
    while (n < max_attempts) : (n += 1) try t.expect(s.takeTrimAfter(settle_ns));
    try t.expect(!s.takeTrimAfter(settle_ns));
    try t.expectEqual(@as(?u64, null), s.dueInMsAfter(settle_ns));

    // The size moving again restores the tries.
    s.note(800, 600, null);
    try t.expectEqual(@as(u8, 0), s.attempts);
    try t.expect(s.takeTrimAfter(settle_ns));
    // The same size again is not a move.
    s.note(800, 600, null);
    try t.expectEqual(@as(u8, 1), s.attempts);
}
