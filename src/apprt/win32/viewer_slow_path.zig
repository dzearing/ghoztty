//! A simulated slow disk for the viewer's file reads (T3245) - a test seam,
//! read by Debug builds only.
//!
//! The viewer's reads (the document, `ViewerDocumentRead`; every resource the
//! page asks for, `ViewerResourceServe`) run on a worker so that a document on a
//! slow or network path never freezes the GUI thread every terminal in the
//! window draws on. Nothing on this box IS a slow path, so the acceptance probe
//! (`test\win32\viewer-slow-path.ps1`) makes one: `GHOZTTY_TEST_VIEWER_SLOW_MS`
//! adds that many milliseconds to every such read, wherever it runs.
//! `GHOZTTY_TEST_VIEWER_INLINE=1` is the probe's negative control - it refuses
//! the worker, so every read runs inline on the GUI thread the way it did
//! before, and the probe must then see the window stall.
//!
//! Release builds compile both reads to the defaults, so a user's environment
//! can never slow their viewer down.
const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    /// Added to every viewer file read, in milliseconds.
    delay_ms: u32 = 0,
    /// Refuse the workers: every read runs inline on the GUI thread.
    force_inline: bool = false,

    /// Sleep for the configured delay. Runs wherever the read runs.
    pub fn pause(self: Config) void {
        if (self.delay_ms > 0) std.Thread.sleep(@as(u64, self.delay_ms) * std.time.ns_per_ms);
    }
};

/// Never more than this, so a typo cannot wedge a test run for an hour.
pub const max_delay_ms: u32 = 10_000;

/// The configuration this process was started with. Debug builds read the
/// environment; every other build returns the defaults.
pub fn fromEnv() Config {
    if (comptime builtin.mode != .Debug) return .{};
    const alloc = std.heap.page_allocator;
    const delay_raw = std.process.getEnvVarOwned(alloc, "GHOZTTY_TEST_VIEWER_SLOW_MS") catch null;
    defer if (delay_raw) |r| alloc.free(r);
    const inline_raw = std.process.getEnvVarOwned(alloc, "GHOZTTY_TEST_VIEWER_INLINE") catch null;
    defer if (inline_raw) |r| alloc.free(r);
    return parse(delay_raw, inline_raw);
}

/// The pure half of `fromEnv`. A delay that is not a number is none.
pub fn parse(delay_raw: ?[]const u8, inline_raw: ?[]const u8) Config {
    var cfg: Config = .{};
    if (delay_raw) |r| {
        const n = std.fmt.parseInt(u32, std.mem.trim(u8, r, " \t"), 10) catch 0;
        cfg.delay_ms = @min(n, max_delay_ms);
    }
    if (inline_raw) |r| cfg.force_inline = std.mem.eql(u8, std.mem.trim(u8, r, " \t"), "1");
    return cfg;
}

test "viewer_slow_path: unset is no delay and the worker" {
    const cfg = parse(null, null);
    try std.testing.expectEqual(@as(u32, 0), cfg.delay_ms);
    try std.testing.expect(!cfg.force_inline);
}

test "viewer_slow_path: a delay is read, capped, and garbage is none" {
    try std.testing.expectEqual(@as(u32, 250), parse("250", null).delay_ms);
    try std.testing.expectEqual(@as(u32, 250), parse(" 250 ", null).delay_ms);
    try std.testing.expectEqual(max_delay_ms, parse("999999", null).delay_ms);
    try std.testing.expectEqual(@as(u32, 0), parse("slow", null).delay_ms);
    try std.testing.expectEqual(@as(u32, 0), parse("-5", null).delay_ms);
}

test "viewer_slow_path: only 1 forces the reads inline" {
    try std.testing.expect(parse(null, "1").force_inline);
    try std.testing.expect(!parse(null, "0").force_inline);
    try std.testing.expect(!parse(null, "yes").force_inline);
}
