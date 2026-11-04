//! Hand DWM the new frame and the content in the same latch (T2666).
//!
//! T2659 measured an edge drag against DWM's compose clock (120 Hz, composes
//! 8.33 ms apart): DWM takes whatever was submitted by a latch about 3.4 ms
//! before each compose, and anything later waits a whole compose. A frame
//! change 3.55 ms ahead of a compose made it and 3.15 ms did not; a terminal
//! present 6.8 ms ahead made it and 3.46 ms did not. So the content and the
//! frame agree on screen only when no latch falls between their submissions.
//!
//! The burst: lay out and draw early (T2578's pre-layout in
//! `WM_WINDOWPOSCHANGING`), but HOLD every visible submission - the terminal
//! swaps - until the end of that message, right before the frame change, and
//! then let them all go together. The gap between the first submission and
//! the frame change is then about a millisecond. What is left is the chance
//! that a latch falls inside that millisecond; `stepPast` reads DWM's clock
//! and, when one would, says how long to wait so the whole burst lands after
//! it - one compose later, but whole.
//!
//! Pure, for the `none` lane: the QPC reads and `DwmGetCompositionTimingInfo`
//! are the caller's.

const std = @import("std");

/// DWM's compose clock, in QPC ticks, as `DwmGetCompositionTimingInfo`
/// reports it, plus the QPC time it was read at.
pub const Clock = struct {
    /// `QueryPerformanceCounter` now.
    now: i64,
    /// `qpcVBlank`: a vblank DWM composed on (the last one it knows of).
    vblank: i64,
    /// `qpcRefreshPeriod`: ticks between composes.
    period: i64,
    /// `QueryPerformanceFrequency`: ticks per second.
    freq: i64,
};

/// The latch rule's constants, in microseconds.
pub const Rule = struct {
    /// How far before a compose DWM stops taking submissions (T2659: ~3.4 ms).
    lead_us: u32 = 3400,
    /// How long the burst takes from its first release to the frame change.
    burst_us: u32 = 1500,
    /// How far past the latch to wait, so a burst released on the edge of
    /// it is not judged against the wrong side.
    margin_us: u32 = 300,
};

/// `sizeof(DWM_TIMING_INFO)`: dwmapi.h declares it under `pshpack1.h`, so it
/// is byte-packed and the caller hands `DwmGetCompositionTimingInfo` a raw
/// buffer rather than a Zig struct that would pad the QPC fields.
pub const timing_info_size: u32 = 292;

/// The two fields of a filled `DWM_TIMING_INFO` the latch rule reads:
/// `qpcRefreshPeriod` at offset 12 (after `cbSize` and `rateRefresh`) and
/// `qpcVBlank` at 28 (after `rateCompose`).
pub fn parseTiming(buf: *const [timing_info_size]u8) struct { period: i64, vblank: i64 } {
    return .{
        .period = @bitCast(std.mem.readInt(u64, buf[12..20], .little)),
        .vblank = @bitCast(std.mem.readInt(u64, buf[28..36], .little)),
    };
}

/// `GHOZTTY_RESIZE_BURST` turns the burst on (T2666). Off by default until a
/// film on a lit display has scored it against T2659's baseline.
pub fn enabledFromEnv(raw: ?[]const u8) bool {
    const v = std.mem.trim(u8, raw orelse return false, " \t\r\n");
    if (v.len == 0) return false;
    return !(std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off"));
}

fn usToTicks(us: u32, freq: i64) i64 {
    return @divTrunc(@as(i64, us) * freq, std.time.us_per_s);
}

/// The next latch strictly after `c.now`, in QPC ticks, or null when the
/// clock is unusable (no period, no frequency).
pub fn nextLatch(c: Clock, r: Rule) ?i64 {
    if (c.period <= 0 or c.freq <= 0) return null;
    const lead = usToTicks(r.lead_us, c.freq);
    // The first compose after `now`, then its latch; a latch already behind
    // `now` belongs to the compose after that one.
    const since = c.now - c.vblank;
    const k: i64 = if (since < 0) 0 else @divFloor(since, c.period) + 1;
    var latch = c.vblank + k * c.period - lead;
    while (latch <= c.now) latch += c.period;
    // A clock read after a stall can sit many periods back; the loop above
    // is bounded by `lead < period` in practice, but never trust it blindly.
    return latch;
}

/// Microseconds to wait before releasing the burst so no latch falls inside
/// it, or 0 when the burst fits before the next latch as it stands.
pub fn stepPast(c: Clock, r: Rule) u32 {
    const latch = nextLatch(c, r) orelse return 0;
    const burst_end = c.now + usToTicks(r.burst_us, c.freq);
    if (burst_end < latch) return 0;
    const wait_ticks = latch - c.now + usToTicks(r.margin_us, c.freq);
    if (wait_ticks <= 0) return 0;
    // Never more than one compose: a longer wait means the clock was wrong.
    const cap = c.period;
    const ticks = @min(wait_ticks, cap);
    return @intCast(@divTrunc(ticks * std.time.us_per_s, c.freq));
}

test "a burst well clear of the next latch waits for nothing" {
    // 10 MHz QPC, 120 Hz: period 83333 ticks, lead 34000, burst 15000.
    const c: Clock = .{ .now = 1_000_000, .vblank = 1_000_000, .period = 83_333, .freq = 10_000_000 };
    // Next compose at +83333, latch at +49333; burst ends at +15000.
    try std.testing.expectEqual(@as(u32, 0), stepPast(c, .{}));
    try std.testing.expectEqual(@as(?i64, 1_049_333), nextLatch(c, .{}));
}

test "a latch inside the burst is stepped past, with the margin" {
    const freq: i64 = 10_000_000;
    // Latch at vblank + 49333; now 1 ms before it, so a 1.5 ms burst spans it.
    const c: Clock = .{ .now = 1_000_000 + 49_333 - 10_000, .vblank = 1_000_000, .period = 83_333, .freq = freq };
    // Wait to the latch (1000 us) plus the 300 us margin.
    try std.testing.expectEqual(@as(u32, 1300), stepPast(c, .{}));
}

test "a latch already behind now belongs to the next compose" {
    // now is 0.5 ms past this compose's latch: the next latch is a period on.
    const c: Clock = .{ .now = 1_000_000 + 49_333 + 5_000, .vblank = 1_000_000, .period = 83_333, .freq = 10_000_000 };
    try std.testing.expectEqual(@as(?i64, 1_000_000 + 49_333 + 83_333), nextLatch(c, .{}));
    try std.testing.expectEqual(@as(u32, 0), stepPast(c, .{}));
}

test "a stale vblank many periods back still finds the right latch" {
    const c: Clock = .{ .now = 1_000_000 + 10 * 83_333 + 40_000, .vblank = 1_000_000, .period = 83_333, .freq = 10_000_000 };
    try std.testing.expectEqual(@as(?i64, 1_000_000 + 10 * 83_333 + 49_333), nextLatch(c, .{}));
    // 0.9333 ms to the latch: inside the burst, so wait 933 + 300 us.
    try std.testing.expectEqual(@as(u32, 1233), stepPast(c, .{}));
}

test "a vblank stamp in the future is read from its own latch" {
    const c: Clock = .{ .now = 900_000, .vblank = 1_000_000, .period = 83_333, .freq = 10_000_000 };
    // Latch for that compose is 966000, 6.6 ms away: clear.
    try std.testing.expectEqual(@as(?i64, 966_000), nextLatch(c, .{}));
    try std.testing.expectEqual(@as(u32, 0), stepPast(c, .{}));
}

test "an unusable clock never waits" {
    try std.testing.expectEqual(@as(u32, 0), stepPast(.{ .now = 5, .vblank = 0, .period = 0, .freq = 10_000_000 }, .{}));
    try std.testing.expectEqual(@as(u32, 0), stepPast(.{ .now = 5, .vblank = 0, .period = 100, .freq = 0 }, .{}));
}

test "the packed DWM_TIMING_INFO is read at its byte-packed offsets" {
    var buf = [_]u8{0} ** timing_info_size;
    std.mem.writeInt(u32, buf[0..4], timing_info_size, .little);
    std.mem.writeInt(u32, buf[4..8], 120, .little); // rateRefresh.uiNumerator
    std.mem.writeInt(u64, buf[12..20], 83_333, .little);
    std.mem.writeInt(u64, buf[28..36], 123_456_789, .little);
    const t = parseTiming(&buf);
    try std.testing.expectEqual(@as(i64, 83_333), t.period);
    try std.testing.expectEqual(@as(i64, 123_456_789), t.vblank);
}

test "the knob is on for any value but empty, 0 and off" {
    try std.testing.expect(!enabledFromEnv(null));
    try std.testing.expect(!enabledFromEnv(""));
    try std.testing.expect(!enabledFromEnv("0"));
    try std.testing.expect(!enabledFromEnv("OFF\r\n"));
    try std.testing.expect(enabledFromEnv("1"));
    try std.testing.expect(enabledFromEnv("on"));
}

test "the wait never exceeds one compose" {
    // A rule whose margin alone exceeds a period is capped at the period.
    const c: Clock = .{ .now = 1_049_000, .vblank = 1_000_000, .period = 83_333, .freq = 10_000_000 };
    try std.testing.expectEqual(@as(u32, 8333), stepPast(c, .{ .margin_us = 20_000 }));
}
