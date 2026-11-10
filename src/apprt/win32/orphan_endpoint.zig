//! A launch that loses the IPC endpoint to an instance that never answers
//! (T2892).
//!
//! A second launch normally forwards its window to the instance that owns the
//! endpoint and exits (Mac single-app behavior). That is only right while the
//! owner is alive to open the window. Windows' crash relaunch (T2839) breaks
//! the assumption: Windows Error Reporting keeps the crashed process alive
//! while it writes the dump, and the relaunch it scheduled starts inside that
//! window - so the new process finds the pipe name still taken, forwards into a
//! process that will never answer, and exits. On 2026-11-10 that left the user
//! with no terminal for 42 minutes while every session sat alive in the agent.
//!
//! The answer is to tell a REFUSAL (the owner answered "no": it is alive, there
//! is nothing to take over) from NO ANSWER (it could not be reached, never
//! replied, or replied with something that is not a reply), and on no answer
//! to wait for the endpoint to come free and start as the app. The waiting
//! itself lives in `App.zig` (it binds the server); this module holds the
//! pieces a lane can check.

const std = @import("std");
const ipc_client = @import("../../os/main.zig").ipc_client;

/// What became of a launch's forwarded new-window.
pub const ForwardOutcome = enum {
    /// The running instance opened (or focused) the window.
    delivered,
    /// The running instance answered and said no, or this process failed on
    /// its own (out of memory): nothing says the owner is gone.
    refused,
    /// No usable answer at all. A healthy instance does not do that; a crashed
    /// one still holding its pipe does.
    unanswered,
};

pub fn classify(sent: ipc_client.Error!bool) ForwardOutcome {
    const ok = sent catch |err| return switch (err) {
        error.OutOfMemory => .refused,
        else => .unanswered,
    };
    return if (ok) .delivered else .refused;
}

/// How long a launch whose forward went unanswered waits for the endpoint to
/// come free. WER writes a dump in seconds for a typical process and longer for
/// a big one on a slow disk; past this the owner is not dying, it is hung, and
/// the launch gives up as it always did.
pub const default_wait_ms: i64 = 120_000;

/// How often the bind is retried while waiting.
pub const poll_ms: u64 = 250;

/// The debug-only override (`GHOZTTY_ORPHAN_WAIT_MS`), read by `App.zig`
/// through its debug-gated env helper so a release build never honors it. An
/// unparseable or negative value is the default, never "forever" or "never".
pub const wait_env = "GHOZTTY_ORPHAN_WAIT_MS";

pub fn parseWaitMs(raw: ?[]const u8) i64 {
    const s = std.mem.trim(u8, raw orelse return default_wait_ms, " \t\r\n");
    const v = std.fmt.parseInt(i64, s, 10) catch return default_wait_ms;
    return if (v < 0) default_wait_ms else v;
}

test "classify: only a missing answer is grounds to take over" {
    const testing = std.testing;
    try testing.expectEqual(ForwardOutcome.delivered, classify(true));
    try testing.expectEqual(ForwardOutcome.refused, classify(false));
    try testing.expectEqual(ForwardOutcome.refused, classify(error.OutOfMemory));
    try testing.expectEqual(ForwardOutcome.unanswered, classify(error.NoRunningInstance));
    try testing.expectEqual(ForwardOutcome.unanswered, classify(error.IPCFailed));
}

test "parseWaitMs: absent, garbage and negative all mean the default" {
    const testing = std.testing;
    try testing.expectEqual(default_wait_ms, parseWaitMs(null));
    try testing.expectEqual(default_wait_ms, parseWaitMs(""));
    try testing.expectEqual(default_wait_ms, parseWaitMs("soon"));
    try testing.expectEqual(default_wait_ms, parseWaitMs("-5"));
    try testing.expectEqual(@as(i64, 3000), parseWaitMs("3000"));
    try testing.expectEqual(@as(i64, 0), parseWaitMs(" 0 "));
}
