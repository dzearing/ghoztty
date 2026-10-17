//! Finishing output a CLI verb wrote to a standard stream.
//!
//! `std.fs.File.Writer.end()` is the wrong call for stdout/stderr. After it
//! flushes, a positional-mode writer TRUNCATES the file at its position
//! (`setEndPos`), and it forgives only `error.NonResizable`. That works on
//! POSIX, where a pipe or a terminal fails ftruncate with EINVAL. On Windows a
//! pipe gets past the positional probe, and its truncate fails as
//! `error.FileTooBig` (T2009). A verb that ended with
//! `try stdout_writer.end()` therefore swapped its own result for that error
//! whenever a script captured its output. `+validate-config` printed the bad
//! keys and then failed, and it exited 1 on a GOOD config too.
//!
//! A standard stream never needs truncating. A `>` redirect is truncated
//! when it is opened, and a `>>` must not be. So flushing is the whole job.

const std = @import("std");
const builtin = @import("builtin");

/// Flush a writer over stdout or stderr at the end of a CLI verb. Use this
/// rather than `end()`.
pub fn finish(w: *std.fs.File.Writer) std.Io.Writer.Error!void {
    try w.interface.flush();
}

const TestPipe = struct {
    read: std.fs.File,
    write: std.fs.File,

    fn open() !TestPipe {
        if (comptime builtin.os.tag == .windows) {
            const windows = std.os.windows;
            var rd: windows.HANDLE = undefined;
            var wr: windows.HANDLE = undefined;
            const sattr: windows.SECURITY_ATTRIBUTES = .{
                .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
                .bInheritHandle = windows.FALSE,
                .lpSecurityDescriptor = null,
            };
            try windows.CreatePipe(&rd, &wr, &sattr);
            return .{ .read = .{ .handle = rd }, .write = .{ .handle = wr } };
        }
        const fds = try std.posix.pipe();
        return .{ .read = .{ .handle = fds[0] }, .write = .{ .handle = fds[1] } };
    }
};

test "finish: a verb's output reaches a PIPE and finishing it does not fail" {
    var p = try TestPipe.open();
    defer p.read.close();

    var buf: [64]u8 = undefined;
    var w = p.write.writer(&buf);
    try w.interface.writeAll("bad.conf:1:font-size: invalid value\n");
    // The T2009 defect: `w.end()` here returned error.FileTooBig on Windows.
    try finish(&w);
    p.write.close();

    var out: [128]u8 = undefined;
    const n = try p.read.readAll(&out);
    try std.testing.expectEqualStrings("bad.conf:1:font-size: invalid value\n", out[0..n]);
}

test "finish: output written to a regular file is left whole" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile("out.txt", .{});
        defer f.close();
        var buf: [16]u8 = undefined;
        var w = f.writer(&buf);
        try w.interface.writeAll("line one\nline two\n");
        try finish(&w);
    }
    var out: [64]u8 = undefined;
    const got = try tmp.dir.readFile("out.txt", &out);
    try std.testing.expectEqualStrings("line one\nline two\n", got);
}
