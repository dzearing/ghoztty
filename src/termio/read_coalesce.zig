//! When the Windows ConPTY reader should wait for more output before it
//! parses (T3060, finding PA-C03).
//!
//! Under a flood conhost hands the reader one small write at a time
//! (60-110 bytes measured by T1464/T3059), and the T62 top-up only batches
//! bytes that are ALREADY waiting, so one batch was about one conhost write:
//! ~30k lock cycles, renderer posts and context switches a second for
//! ~2 MB/s. The cure is to let a streaming producer fill the pipe for up to
//! `max_wait_ns` (or until `target_bytes` are pending) before taking the
//! terminal lock.
//!
//! The one thing it must never do is delay an isolated keystroke echo. The
//! signal that separates the two is how long the blocking read WAITED: an
//! echo on a quiet pane waited for the user (tens of ms at the least), a
//! flood's next write is already on its way (tens of µs). Pure logic, so it
//! is unit-tested off-box in the `none` lane.

const std = @import("std");

/// Stop waiting once this much is buffered: one parse of 16 KiB is the T111
/// lock-hold budget's order, and the reader buffer is 64 KiB.
pub const target_bytes: usize = 16 * 1024;

/// The longest a batch is held back. Under a frame (60 Hz is 16.7 ms), so a
/// flood still renders every frame; the tail of a burst lands this late.
pub const max_wait_ns: u64 = 1 * std.time.ns_per_ms;

/// One timer wait. Two slices per `max_wait_ns`, so a fast producer that
/// reaches `target_bytes` early is parsed early.
pub const slice_ns: u64 = 500 * std.time.ns_per_us;

/// A blocking read that returned within this long is part of a stream. A
/// human typing cannot produce two echoes this close together.
pub const stream_gap_ns: u64 = 2 * std.time.ns_per_ms;

/// Whether to hold `filled` bytes back and wait for more, given how long the
/// blocking read that produced the batch's first bytes waited (`blocked_ns`).
pub fn shouldWait(filled: usize, blocked_ns: u64) bool {
    if (filled == 0) return false;
    if (filled >= target_bytes) return false;
    return blocked_ns < stream_gap_ns;
}

/// The next timer wait, or null when the deadline has passed. `waited_ns` is
/// time spent since the coalescing started.
pub fn nextWait(waited_ns: u64) ?u64 {
    if (waited_ns >= max_wait_ns) return null;
    return @min(slice_ns, max_wait_ns - waited_ns);
}

test "an echo after a quiet spell parses at once" {
    // A keystroke echo: a few bytes, read after the user paused.
    try std.testing.expect(!shouldWait(3, 120 * std.time.ns_per_ms));
    // Even fast typing (10 keys/s) is far outside the stream gap.
    try std.testing.expect(!shouldWait(1, 100 * std.time.ns_per_ms));
    // The boundary belongs to the echo side.
    try std.testing.expect(!shouldWait(80, stream_gap_ns));
}

test "a flood write waits for more" {
    try std.testing.expect(shouldWait(94, 30 * std.time.ns_per_us));
    try std.testing.expect(shouldWait(target_bytes - 1, 0));
}

test "a full batch or an empty one never waits" {
    try std.testing.expect(!shouldWait(target_bytes, 0));
    try std.testing.expect(!shouldWait(64 * 1024, 0));
    try std.testing.expect(!shouldWait(0, 0));
}

test "the wait is sliced and bounded by max_wait_ns" {
    try std.testing.expectEqual(@as(?u64, slice_ns), nextWait(0));
    try std.testing.expectEqual(@as(?u64, max_wait_ns - 700 * std.time.ns_per_us), nextWait(700 * std.time.ns_per_us));
    try std.testing.expectEqual(@as(?u64, null), nextWait(max_wait_ns));
    try std.testing.expectEqual(@as(?u64, null), nextWait(max_wait_ns + 1));

    // Summing the slices never exceeds the cap.
    var waited: u64 = 0;
    var waits: u32 = 0;
    while (nextWait(waited)) |w| {
        waited += w;
        waits += 1;
    }
    try std.testing.expectEqual(max_wait_ns, waited);
    try std.testing.expectEqual(@as(u32, 2), waits);
}
