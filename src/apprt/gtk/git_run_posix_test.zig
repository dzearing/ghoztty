//! POSIX acceptance for win32's `git_run.zig` (T3417), which the Linux diff
//! pane runs git through. Its own tests drive Windows jobs and skip here; these
//! prove the POSIX half of the same contract - the deadline and the cancel end
//! the WHOLE process group, so a child still holding the stdout pipe cannot
//! keep the reader (and the pane's teardown join behind it) waiting.
//!
//! The stub "git" is a shell script whose `sleep` child inherits the pipe: the
//! shape that hangs when only the launched process is killed. On Windows every
//! test here skips.
const std = @import("std");
const builtin = @import("builtin");
const git_run = @import("../win32/git_run.zig");

const testing = std.testing;

/// A `git` that answers nothing for eight seconds, through a child.
fn slowStub(tmp: *std.testing.TmpDir) ![]u8 {
    const f = try tmp.dir.createFile("git", .{ .mode = 0o755 });
    defer f.close();
    try f.writeAll("#!/bin/sh\nsleep 8\necho late\n");
    return try tmp.dir.realpathAlloc(testing.allocator, "git");
}

test "T3417: the deadline ends a slow git's whole process group (POSIX)" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const stub = try slowStub(&tmp);
    defer testing.allocator.free(stub);

    var timer = try std.time.Timer.start();
    const out = git_run.captureAllocDeadline(testing.allocator, &.{stub}, 1024, 400) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(out.bytes);
    const elapsed_ms = timer.read() / std.time.ns_per_ms;
    // Killing only the shell would leave `sleep` holding the pipe for 8 s.
    try testing.expect(elapsed_ms < 3_000);
    try testing.expect(out.timed_out);
    try testing.expect(!out.ok);
    try testing.expectEqual(@as(usize, 0), out.bytes.len);
}

test "T3417: a cancel ends the git in flight and refuses the next (POSIX)" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const stub = try slowStub(&tmp);
    defer testing.allocator.free(stub);

    const Worker = struct {
        fn run(cancel: *git_run.Cancel, argv0: []const u8, first: *?git_run.Output, second_launched: *bool) void {
            git_run.cancel_on_thread = cancel;
            defer git_run.cancel_on_thread = null;
            first.* = git_run.captureAlloc(testing.allocator, &.{argv0}, 1024);
            second_launched.* = git_run.captureAlloc(testing.allocator, &.{argv0}, 1024) != null;
        }
    };
    var cancel: git_run.Cancel = .{};
    var first: ?git_run.Output = null;
    var second_launched = true;
    // Started before the spawn so nothing between the spawn and the join can
    // return early and leave the worker running.
    var timer = try std.time.Timer.start();
    const t = try std.Thread.spawn(.{}, Worker.run, .{ &cancel, stub, &first, &second_launched });
    std.Thread.sleep(300 * std.time.ns_per_ms);
    const requested_at = timer.read();
    cancel.request();
    t.join();
    const elapsed_ms = (timer.read() - requested_at) / std.time.ns_per_ms;
    try testing.expect(elapsed_ms < 3_000);
    // A cancelled run answers nothing, and nothing after it starts.
    if (first) |o| testing.allocator.free(o.bytes);
    try testing.expect(first == null);
    try testing.expect(!second_launched);
}

test "T3417: a git that answers is read to EOF and reports ok (POSIX)" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const out = git_run.captureAlloc(testing.allocator, &.{ "/bin/sh", "-c", "printf 'a\\nb\\n'" }, 1024) orelse
        return error.SkipZigTest;
    defer testing.allocator.free(out.bytes);
    try testing.expect(out.ok);
    try testing.expectEqualStrings("a\nb\n", out.bytes);
}
