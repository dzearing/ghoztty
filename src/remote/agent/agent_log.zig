//! Where `ghoztty-agent` and its pty holders write their `std.log` lines (T1721).
//!
//! ## Why
//! On macOS the agent runs under a LaunchAgent whose `StandardOutPath` /
//! `StandardErrorPath` are `<agent state dir>/agent.log`
//! (`LocalAgentManager.swift`), so every warning it raises lands in a file. On
//! Windows the app spawns the agent `DETACHED_PROCESS` through
//! `spawnEscapingJob`, with no `STARTF_USESTDHANDLES`, and the agent spawns
//! each holder the same way: neither has a stderr at all. Every durability
//! warning - `holder replay gap`, the T970 "dropped ... not yet saved" line,
//! adoption failures - was written into the void on a user's box.
//!
//! The Windows-native translation of the LaunchAgent redirect is the process
//! appending to the same-named file itself: `agent.log` in the agent's own
//! state dir, `%LOCALAPPDATA%\ghoztty\local-agent[-debug][-<instance>]\`
//! (the directory `+sessions` and the app already derive). The agent and every
//! holder of a lineage share it, which is exactly the several-writers shape
//! `log_rotate` was built for: one append-only write per line, two generations
//! of `log_rotate.max_bytes` each.
//!
//! stderr is still written as before (`std.log.defaultLog`), so a Debug
//! build's harness captures and the dev deploy watcher's `agent.err.log` keep
//! working, and on macOS this module adds nothing: launchd already did it.

const std = @import("std");
const builtin = @import("builtin");
const log_rotate = @import("../../os/log_rotate.zig");
const log_stamp = @import("../../os/log_stamp.zig");
const agent_lineage = @import("../agent_lineage.zig");

pub const file_name = "agent.log";
pub const rotated_name = file_name ++ ".1";

/// Which kind of process is writing, so a line in the shared file says whether
/// the agent or one of its holders raised it (the pid alone does not).
pub const Role = enum { agent, holder };

/// Set once, by `main`, before the mode runs. Not atomic on purpose: it is
/// written before any thread exists and only read after.
pub var role: Role = .agent;

/// The state-dir segment under `%LOCALAPPDATA%\ghoztty\`: the same
/// `local-agent[-debug][-<instance>]` `LocalAgent.agentDir` and `+sessions`
/// spell, so the log sits beside the `port.json` and `sessions.json` it
/// explains. Pure, so the derivation is testable without an environment.
pub fn dirSegment(buf: []u8, is_debug: bool, instance: ?[]const u8) error{NameTooLong}![]const u8 {
    const base = if (is_debug) "local-agent-debug" else "local-agent";
    return agent_lineage.appendSuffix(buf, base, instance);
}

/// `<stamp><role prefix><level>(<scope>): <message>\n`, formatted into `buf`
/// as ONE slice so it goes out as one append (the T270 rule: a prefix written
/// separately can be split from its line by another writer).
pub fn formatLine(
    buf: []u8,
    stamp: []const u8,
    r: Role,
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) ?[]const u8 {
    const role_txt = switch (r) {
        .agent => "",
        .holder => "holder ",
    };
    const level_txt = comptime level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const head_len = stamp.len + role_txt.len;
    if (head_len > buf.len) return null;
    @memcpy(buf[0..stamp.len], stamp);
    @memcpy(buf[stamp.len..head_len], role_txt);
    const body = std.fmt.bufPrint(
        buf[head_len..],
        level_txt ++ prefix ++ format ++ "\n",
        args,
    ) catch return null;
    return buf[0 .. head_len + body.len];
}

/// The agent's `std.log` sink. Installed as `std_options.logFn` by
/// `src/agent_main.zig`; must never fail or block on a missing directory.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime builtin.os.tag == .windows) {
        // Debug lines stay on stderr: they are the expensive, chatty ones,
        // and the file is the durable record of what went wrong, not a trace.
        if (level != .debug) writeFile(level, scope, format, args);
    }
    std.log.defaultLog(level, scope, format, args);
}

fn writeFile(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const w = std.os.windows;
    const local_w = std.process.getenvW(
        std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"),
    ) orelse return;
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (local_w.len * 3 > base_buf.len) return;
    const n = std.unicode.wtf16LeToWtf8(&base_buf, local_w);

    var seg_buf: [64]u8 = undefined;
    var sfx_buf: [agent_lineage.max_len]u8 = undefined;
    const seg = dirSegment(
        &seg_buf,
        @import("agent_build_options").is_debug,
        agent_lineage.fromEnv(&sfx_buf),
    ) catch return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&path_buf, "{s}\\ghoztty\\{s}", .{ base_buf[0..n], seg }) catch return;
    var dir = std.fs.cwd().makeOpenPath(dir_path, .{}) catch return;
    defer dir.close();

    // FILE_APPEND_DATA without FILE_WRITE_DATA: each write lands at the
    // current end of file as one operation, so the agent and its holders
    // interleave whole lines (see `openAppendW` in main_ghostty.zig).
    const handle = w.OpenFile(std.unicode.utf8ToUtf16LeStringLiteral(file_name), .{
        .dir = dir.fd,
        .access_mask = w.SYNCHRONIZE | w.FILE_APPEND_DATA | w.FILE_READ_ATTRIBUTES,
        .creation = w.FILE_OPEN_IF,
    }) catch return;
    const file: std.fs.File = .{ .handle = handle };
    defer file.close();

    var msg_buf: [2048 + log_stamp.max_len]u8 = undefined;
    var stamp_buf: [log_stamp.max_len]u8 = undefined;
    const stamp = log_stamp.format(&stamp_buf, std.time.milliTimestamp(), w.GetCurrentProcessId());
    const line = formatLine(&msg_buf, stamp, role, level, scope, format, args) orelse return;
    _ = file.write(line) catch {};

    if (log_rotate.oversize(file)) log_rotate.rotateNamed(dir, file_name, rotated_name);
}

test "dirSegment: spells the same state dir the app and +sessions derive" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("local-agent", try dirSegment(&buf, false, null));
    try testing.expectEqualStrings("local-agent-debug", try dirSegment(&buf, true, null));
    try testing.expectEqualStrings("local-agent-debug-sbx1", try dirSegment(&buf, true, "sbx1"));
    try testing.expectEqualStrings("local-agent-sbx1", try dirSegment(&buf, false, "sbx1"));
}

test "formatLine: one slice carrying stamp, role, level, scope and message" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const agent_line = formatLine(&buf, "STAMP ", .agent, .warn, .pty_host, "lost {d}", .{7}).?;
    try testing.expectEqualStrings("STAMP warning(pty_host): lost 7\n", agent_line);
    const holder_line = formatLine(&buf, "STAMP ", .holder, .err, .default, "bad {s}", .{"id"}).?;
    try testing.expectEqualStrings("STAMP holder error: bad id\n", holder_line);
}

test "formatLine: a message that does not fit is dropped, never truncated mid-line" {
    var buf: [16]u8 = undefined;
    try std.testing.expect(formatLine(&buf, "STAMP ", .agent, .info, .default, "{s}", .{"x" ** 64}) == null);
}

test "agent.log names stay distinct from the app's shared sink" {
    try std.testing.expect(!std.mem.eql(u8, file_name, log_rotate.live_name));
    try std.testing.expectEqualStrings("agent.log.1", rotated_name);
}
