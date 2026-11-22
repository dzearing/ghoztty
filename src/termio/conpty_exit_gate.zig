//! When to tell the surface a ConPTY child has exited (T65, T3383).
//!
//! ConPTY keeps rendering after the process exits: its frames reach the read
//! thread AFTER the process-exit callback. Notify the surface too early and
//! the late frame overwrites what the surface draws in response, which is
//! the in-terminal "Process exited" notice or the abnormal-exit diagnostic.
//!
//! The T65 gate waited for one quiet poll tick. That cannot tell "conhost
//! has finished painting" from "conhost has not painted yet". A child that
//! exits in ~10 ms (`cmd /c exit 0`) has only produced conhost's 16-byte
//! mode preamble (`CSI ? 9001 h CSI ? 1004 h`) when the process exits; the
//! FIRST paint (`CSI ? 25 l CSI 2 J ...`, an erase plus the blank frame)
//! arrived ~100 ms after the preamble on 2026-11-22, a full tick after the
//! gate had fired, and erased the notice. So the gate also waits until a
//! real paint has been read, bounded by `max_ticks` as before.

const std = @import("std");

/// The gate's poll period.
pub const poll_ms = 50;

/// Out of patience: fire anyway after this many ticks (1 s).
pub const max_ticks = 20;

/// Fire once pty output has been quiet for a full tick AND conhost has
/// painted at least once, or when out of patience.
pub fn shouldFire(snapshot: u64, activity: u64, ticks: u32, painted: bool) bool {
    if (ticks >= max_ticks) return true;
    return painted and activity == snapshot;
}

/// True when a batch read from the pty counts as conhost having painted:
/// anything but an empty read or the mode preamble below.
pub fn isPaint(bytes: []const u8) bool {
    return bytes.len > 0 and !isModePreambleOnly(bytes);
}

/// True when non-empty `bytes` is nothing but DEC private mode sets/resets
/// (`ESC [ ? n[;n...] h|l`): conhost's startup preamble, which arrives before
/// its first paint and paints nothing.
fn isModePreambleOnly(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes.len - i < 4) return false;
        if (bytes[i] != 0x1b or bytes[i + 1] != '[' or bytes[i + 2] != '?') return false;
        i += 3;
        const params_start = i;
        while (i < bytes.len and (std.ascii.isDigit(bytes[i]) or bytes[i] == ';')) i += 1;
        if (i == params_start or i >= bytes.len) return false;
        if (bytes[i] != 'h' and bytes[i] != 'l') return false;
        i += 1;
    }
    return true;
}

test "shouldFire waits for a paint, then for quiet" {
    const testing = std.testing;
    // Quiet but nothing painted yet: the 2026-11-22 race. Hold.
    try testing.expect(!shouldFire(16, 16, 1, false));
    // Painted and quiet: fire.
    try testing.expect(shouldFire(5, 5, 1, true));
    // Painted but still moving: hold.
    try testing.expect(!shouldFire(5, 9, 1, true));
    // Out of patience fires whatever the state.
    try testing.expect(shouldFire(5, 9, max_ticks, false));
    try testing.expect(shouldFire(5, 5, max_ticks, false));
}

test "isModePreambleOnly recognises conhost's startup preamble" {
    const testing = std.testing;
    try testing.expect(isModePreambleOnly("\x1b[?9001h\x1b[?1004h"));
    try testing.expect(isModePreambleOnly("\x1b[?25l"));
    try testing.expect(isModePreambleOnly("\x1b[?1;2h"));
    // The first paint is not a preamble: it erases and moves the cursor.
    try testing.expect(!isModePreambleOnly("\x1b[?25l\x1b[2J\x1b[m\x1b[H\r\n"));
    // Preamble and paint coalesced into one batch (T3060): a paint.
    try testing.expect(!isModePreambleOnly("\x1b[?9001h\x1b[?1004h\x1b[?25l\x1b[2J"));
    try testing.expect(!isModePreambleOnly("hello"));
    try testing.expect(!isModePreambleOnly(""));
    // Truncated or malformed sequences are not a preamble.
    try testing.expect(!isModePreambleOnly("\x1b[?9001"));
    try testing.expect(!isModePreambleOnly("\x1b[?h"));
    try testing.expect(!isModePreambleOnly("\x1b[2J"));
}

test "isPaint: the first paint and ordinary output count, the preamble and nothing do not" {
    const testing = std.testing;
    try testing.expect(!isPaint(""));
    try testing.expect(!isPaint("\x1b[?9001h\x1b[?1004h"));
    try testing.expect(isPaint("\x1b[?25l\x1b[2J\x1b[m\x1b[H\r\n"));
    try testing.expect(isPaint("\x1b[?9001h\x1b[?1004h\x1b[?25l\x1b[2J"));
    try testing.expect(isPaint("C:\\>"));
}
