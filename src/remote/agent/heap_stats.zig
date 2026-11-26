//! The Debug agent's live-heap counter (T3646).
//!
//! ## Why
//! A Debug agent runs on Zig's `DebugAllocator`, which never reuses a freed
//! slot and returns a page only once EVERY slot on it is freed. So one
//! long-lived small allocation made between a session's allocations pins that
//! whole page, and the process's private memory climbs per closed session
//! even when every byte the session asked for was given back. `/proc`'s
//! `smaps_rollup` cannot tell that apart from a real leak; the allocator's
//! own count of bytes currently handed out can.
//!
//! `main` points `live_bytes` at its `DebugAllocator`'s
//! `total_requested_bytes` (Debug builds only, where the allocator is built
//! with `enable_memory_limit`); release builds run on `smp_allocator`, which
//! keeps no such count, and leave it null. The session table logs it each
//! time a session is created or freed, so `test/linux/pane-close-memory.sh`
//! reads the agent's real per-session retention out of `agent.log`.

const std = @import("std");

/// Bytes the process allocator has handed out and not had back. Null when the
/// allocator does not count (every release mode). Set once by `main` before
/// any thread starts; read racily afterwards, which is fine for a diagnostic
/// (a word-sized load of a counter that only the allocator writes).
pub var live_bytes: ?*const usize = null;

/// The current count, or null when nothing counts.
pub fn current() ?usize {
    const p = live_bytes orelse return null;
    return @as(*const volatile usize, p).*;
}

/// One `heap:` line for the agent log: `event`, the live bytes, and how many
/// sessions the table holds (`live`/`dead`). Silent when nothing counts.
pub fn logEvent(comptime event: []const u8, live: usize, dead: usize) void {
    const bytes = current() orelse return;
    std.log.scoped(.heap).debug(event ++ ": live_bytes={d} sessions_live={d} sessions_dead={d}", .{ bytes, live, dead });
}

test "heap_stats: silent and null until main points it at a counter" {
    const saved = live_bytes;
    defer live_bytes = saved;
    live_bytes = null;
    try std.testing.expectEqual(@as(?usize, null), current());
    var n: usize = 4242;
    live_bytes = &n;
    try std.testing.expectEqual(@as(?usize, 4242), current());
    n = 7;
    try std.testing.expectEqual(@as(?usize, 7), current());
}
