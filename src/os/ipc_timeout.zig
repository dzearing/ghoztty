//! How long a CLI verb waits for the running Ghoztty instance to answer, and
//! what it says when it gives up (T755).
//!
//! The transport is a request/response exchange over a named pipe (Windows) or
//! a unix socket (posix), and the server marshals every request to its GUI
//! thread. That thread is legitimately busy for seconds during a cold start or
//! a session restore — but it can also be wedged, and until this module existed
//! the two were the same experience: `ghoztty +list` blocked with no output and
//! no error, forever. It was MEASURED at 34 minutes on 2026-08-11 while
//! `ipc-p1.ps1` ran against an app that had auto-launched in the same second.
//!
//! So the wait is bounded, and it is bounded in two stages rather than one,
//! because "slow" and "dead" deserve different answers:
//!
//!   - at `notice_ms` the CLI says it is still waiting, and why it might be.
//!     A verb that explains itself is not a hung terminal even when it is slow.
//!   - at the resolved timeout it fails with a sentence naming what it was
//!     waiting for, so the caller can act instead of guessing.
//!
//! This module is the POLICY only (numbers, env parsing, wording) so it is
//! pure and asserted in the `none` lane; the per-platform mechanics that
//! enforce it live in `ipc_client.zig`.

const std = @import("std");

/// The default bound on one exchange. Chosen well above any healthy round trip
/// (a warm `+list` answers in single-digit milliseconds) and well below the
/// point where a human decides their terminal is dead. A cold app start, a
/// session restore, or an agent that is answering slowly all fit inside it.
pub const default_ms: u32 = 30_000;

/// When the CLI first says out loud that it is still waiting. Short enough
/// that nobody stares at a blank line wondering, long enough that no ordinary
/// verb ever prints it.
pub const notice_ms: u32 = 5_000;

/// Environment override for the bound, in milliseconds. `0` restores the
/// pre-T755 behavior — wait forever — for a caller that genuinely wants it
/// (a debugger attached to a stopped app, say).
pub const env_var = "GHOZTTY_IPC_TIMEOUT_MS";

/// How long `+new-window` waits for the instance it AUTO-LAUNCHED to bind its
/// endpoint and start answering, before reporting that no instance is running.
///
/// This is a different question from `default_ms` — there the peer exists and
/// is not answering; here we are waiting on a process we just started, whose
/// cold start includes the loader, Defender scanning a freshly built binary,
/// config parsing and a session restore. The old budget was 20 fixed attempts
/// of 500ms and it was reached: `ipc-p1.ps1`'s first section failed three
/// assertions on one cold auto-launch (2026-08-11) and passed on the warm
/// re-run, which reads as a regression and is not one.
pub const auto_launch_ms: u32 = 30_000;

/// How often the auto-launch wait re-tries the send. Short enough that a fast
/// cold start is not padded by the poll interval.
pub const auto_launch_poll_ms: u32 = 250;

/// What the client was waiting for when the bound ran out. The two halves of
/// an exchange fail for different reasons and a caller should be able to tell
/// them apart: a peer that will not take the request is a different state from
/// one that took it and never answered.
pub const Phase = enum {
    /// Writing the request. The peer is not draining the pipe.
    request,
    /// Reading the reply. The peer has the request and has not answered.
    response,

    pub fn describe(self: Phase) []const u8 {
        return switch (self) {
            .request => "send the request to",
            .response => "get a response from",
        };
    }
};

/// Resolve the bound from the environment value (null when unset). Anything
/// unparseable falls back to the default rather than to "forever": a typo in
/// an env var must never reinstate the hang this module exists to remove.
/// `0` is the one value that means forever, and it has to be spelled exactly.
pub fn resolve(env_value: ?[]const u8) u32 {
    const raw = env_value orelse return default_ms;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return default_ms;
    return std.fmt.parseInt(u32, trimmed, 10) catch default_ms;
}

/// The wait a caller should perform before printing the notice, given the
/// resolved bound. A bound at or below `notice_ms` skips the notice entirely
/// (there is nothing left to wait for after it), and an unbounded wait still
/// gets one — "forever" is exactly the case where saying so matters most.
pub fn firstWaitMs(timeout_ms: u32) u32 {
    if (timeout_ms == 0) return notice_ms;
    if (timeout_ms <= notice_ms) return timeout_ms;
    return notice_ms;
}

/// What remains of the bound after the notice fired. `null` means "keep
/// waiting with no bound" (the opt-out), which is the only case a caller must
/// treat differently from a number.
pub fn remainingWaitMs(timeout_ms: u32) ?u32 {
    if (timeout_ms == 0) return null;
    if (timeout_ms <= notice_ms) return 0;
    return timeout_ms - notice_ms;
}

/// The line printed when a reply's four-byte length prefix cannot be a length
/// (T1509): zero, or more than the client will accept. It used to print the
/// decoded integer — `IPC response has invalid length: 1768842863` — which is
/// the ASCII text `invo` read as a big-endian u32: the client had fallen out of
/// step with the stream and was reading the middle of a reply where a prefix
/// was due. The number was a fragment of the very text that would have
/// explained it, so the message now quotes those bytes as text when they are
/// printable, says what the state means, and says whether to retry — the
/// house wording T755 set for the timeout case.
pub fn writeBadFrame(
    w: *std.Io.Writer,
    action: []const u8,
    prefix: [4]u8,
    max_len: u32,
) void {
    const len = std.mem.readInt(u32, &prefix, .big);
    if (len == 0) {
        w.print(
            "Ghoztty sent an empty reply to '{s}'. " ++
                "The app may have closed the connection while starting up or shutting down; " ++
                "retrying the command is reasonable.\n",
            .{action},
        ) catch {};
    } else if (isPrintable(&prefix)) {
        w.print(
            "Ghoztty's reply to '{s}' could not be read: it began with the text \"{s}\" " ++
                "where a message length was due, so this command fell out of step with the app " ++
                "(this can happen while the app is still starting up). " ++
                "Retrying the command is reasonable.\n",
            .{ action, &prefix },
        ) catch {};
    } else {
        w.print(
            "Ghoztty's reply to '{s}' could not be read: it announced {d} bytes, " ++
                "more than the {d} this command accepts, so the connection is out of step " ++
                "or the reply is not from Ghoztty. Retrying the command is reasonable; " ++
                "if it keeps happening, another program may be holding Ghoztty's pipe name.\n",
            .{ action, len, max_len },
        ) catch {};
    }
    w.flush() catch {};
}

/// Every byte is printable ASCII, so quoting the prefix as text says more than
/// its integer value does. A length the app would really send (at most 1 MiB)
/// has a zero high byte and is never printable, so the two cases cannot meet.
fn isPrintable(bytes: []const u8) bool {
    for (bytes) |b| if (b < 0x20 or b > 0x7e) return false;
    return true;
}

/// The line printed once, at `notice_ms`, while the wait continues.
pub fn writeNotice(w: *std.Io.Writer, action: []const u8) void {
    w.print(
        "Waiting for Ghoztty to answer '{s}' (the app may still be starting up)...\n",
        .{action},
    ) catch {};
    w.flush() catch {};
}

/// The line printed when the bound runs out, naming the verb, the phase, and
/// the way out. It names the env var because the honest remedy for a genuinely
/// slow box is a longer bound, not a retry loop in the caller.
pub fn writeTimeout(
    w: *std.Io.Writer,
    action: []const u8,
    phase: Phase,
    timeout_ms: u32,
) void {
    w.print(
        "Timed out after {d}.{d:0>1}s trying to {s} Ghoztty for '{s}'. " ++
            "The app may be busy starting up, or not responding. " ++
            "Set {s} to wait longer (0 waits forever).\n",
        .{
            timeout_ms / 1000,
            (timeout_ms % 1000) / 100,
            phase.describe(),
            action,
            env_var,
        },
    ) catch {};
    w.flush() catch {};
}

test "resolve: unset, empty and garbage all mean the default" {
    const testing = std.testing;
    try testing.expectEqual(default_ms, resolve(null));
    try testing.expectEqual(default_ms, resolve(""));
    try testing.expectEqual(default_ms, resolve("   "));
    try testing.expectEqual(default_ms, resolve("soon"));
    try testing.expectEqual(default_ms, resolve("-1"));
    try testing.expectEqual(default_ms, resolve("12.5"));
}

test "resolve: an explicit number wins, and 0 means forever" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 1500), resolve("1500"));
    try testing.expectEqual(@as(u32, 1500), resolve(" 1500\n"));
    try testing.expectEqual(@as(u32, 0), resolve("0"));
}

test "firstWaitMs/remainingWaitMs: the two stages always sum to the bound" {
    const testing = std.testing;

    // Ordinary bound: notice, then the rest.
    try testing.expectEqual(notice_ms, firstWaitMs(default_ms));
    try testing.expectEqual(@as(?u32, default_ms - notice_ms), remainingWaitMs(default_ms));

    // A bound shorter than the notice never prints one.
    try testing.expectEqual(@as(u32, 900), firstWaitMs(900));
    try testing.expectEqual(@as(?u32, 0), remainingWaitMs(900));

    // Forever still gets the notice — that is when it matters most.
    try testing.expectEqual(notice_ms, firstWaitMs(0));
    try testing.expectEqual(@as(?u32, null), remainingWaitMs(0));
}

test "writeTimeout: the message names the verb, the phase and the way out" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeTimeout(&w, "+list", .response, 30_000);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "30.0s") != null);
    try testing.expect(std.mem.indexOf(u8, out, "'+list'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "get a response from") != null);
    try testing.expect(std.mem.indexOf(u8, out, env_var) != null);
}

test "writeBadFrame: a text prefix is quoted as text, never as its integer (T1509)" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // The 2026-09-12 sighting: 0x696E766F, printed then as 1768842863.
    writeBadFrame(&w, "+new-window", "invo".*, 1_048_576);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"invo\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1768842863") == null);
    try testing.expect(std.mem.indexOf(u8, out, "'+new-window'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Retrying the command is reasonable") != null);
}

test "writeBadFrame: an oversized binary prefix names the size and the limit" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeBadFrame(&w, "+list", .{ 0x7f, 0x00, 0x00, 0x01 }, 1_048_576);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "2130706433 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1048576") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Retrying the command is reasonable") != null);
}

test "writeBadFrame: a zero length reads as an empty reply" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeBadFrame(&w, "+read", .{ 0, 0, 0, 0 }, 1_048_576);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "empty reply to '+read'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "retrying the command is reasonable") != null);
}

test "writeBadFrame: no real length is ever printable" {
    // The largest reply the client accepts has a zero high byte, so the
    // "quote it as text" branch can never swallow a genuine length.
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, 1_048_576, .big);
    try std.testing.expect(!isPrintable(&prefix));
}

test "the auto-launch budget is not shorter than one bounded exchange" {
    // Otherwise the budget is a fiction: a single attempt inside the retry
    // loop could wait longer than the whole loop is allowed to, so "give up
    // after auto_launch_ms" would be decided by whichever attempt happened to
    // reach a connected-but-silent peer first.
    const testing = std.testing;
    try testing.expect(auto_launch_ms >= default_ms);
    try testing.expect(auto_launch_poll_ms > 0);
    try testing.expect(auto_launch_poll_ms < auto_launch_ms);
}

test "writeTimeout: the request phase reads differently from the response one" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeTimeout(&w, "+send-keys", .request, 1_500);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "send the request to") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.5s") != null);
}
