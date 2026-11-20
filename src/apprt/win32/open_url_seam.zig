//! Where an opened link WOULD have gone - a test seam, read by Debug builds
//! only (T1555).
//!
//! Every link the app follows into the shell - the About box's row, Help, a
//! clicked URL in a terminal - ends in `App.openUrl` -> `ShellExecuteW`, which
//! launches the user's browser. An acceptance script that activated one would
//! open a browser on every run, so until this seam nothing on the box proved
//! that activating an About link reached the right URL at all: `ipc-version.ps1`
//! could say the links were there and labelled, never where they went.
//!
//! `GHOZTTY_TEST_OPEN_URL_LOG=<path>` turns `openUrl` into a recorder: each URL
//! is appended to that file as one line and the shell is never asked. This is
//! the out-of-process twin of the viewer's in-process `LinkSink` (T594), which
//! a unit test reads directly but a script cannot reach.
//!
//! `GHOZTTY_TEST_ABOUT_VERSION=<X.Y.Z>` stands in for the version the About
//! box builds its links from, so a dev build - whose version carries a branch
//! and a commit and therefore earns no release link - can show the row a
//! published release shows, and the `win-v` tag URL that row is wired to can be
//! proven end to end.
//!
//! Release builds compile both reads to null, so a user's environment can never
//! stop their links from opening or change what About says.
const std = @import("std");
const builtin = @import("builtin");

pub const log_env = "GHOZTTY_TEST_OPEN_URL_LOG";
pub const about_version_env = "GHOZTTY_TEST_ABOUT_VERSION";

/// The longest value either variable may carry. A path longer than this is
/// not a test's recorder, and a version longer than this is not a version.
pub const max_value_len = 1024;

/// The recorder file, or null when links should open for real. Caller frees.
pub fn logPath(alloc: std.mem.Allocator) ?[]u8 {
    if (comptime builtin.mode != .Debug) return null;
    return readEnv(alloc, log_env);
}

/// The About box's stand-in version, or null for the build's own. Caller frees.
pub fn aboutVersion(alloc: std.mem.Allocator) ?[]u8 {
    if (comptime builtin.mode != .Debug) return null;
    return readEnv(alloc, about_version_env);
}

fn readEnv(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    const raw = std.process.getEnvVarOwned(alloc, name) catch return null;
    const kept = accept(raw) orelse {
        alloc.free(raw);
        return null;
    };
    if (kept.len == raw.len) return raw;
    const out = alloc.dupe(u8, kept) catch {
        alloc.free(raw);
        return null;
    };
    alloc.free(raw);
    return out;
}

/// The pure half of the env reads: the trimmed value, or null when it says
/// nothing (empty, blank, or too long to be meant).
pub fn accept(raw: []const u8) ?[]const u8 {
    const v = std.mem.trim(u8, raw, " \t\r\n");
    if (v.len == 0 or v.len > max_value_len) return null;
    return v;
}

/// The line `record` appends for `url`: the URL alone, newline-terminated, with
/// any CR/LF inside it flattened so one activation is always exactly one line a
/// script can compare.
pub fn formatLine(buf: []u8, url: []const u8) ?[]const u8 {
    if (url.len + 1 > buf.len) return null;
    for (url, 0..) |c, i| buf[i] = if (c == '\r' or c == '\n') ' ' else c;
    buf[url.len] = '\n';
    return buf[0 .. url.len + 1];
}

/// Append `url` to the recorder at `path`. Best effort: a test that cannot
/// write its own recorder fails on the missing line, which is the right place.
pub fn record(path: []const u8, url: []const u8) void {
    var buf: [4096]u8 = undefined;
    const line = formatLine(&buf, url) orelse return;
    const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(line) catch return;
}

test "open_url_seam: blank and oversized values say nothing" {
    try std.testing.expect(accept("") == null);
    try std.testing.expect(accept("  \t\r\n") == null);
    const long = [_]u8{'x'} ** (max_value_len + 1);
    try std.testing.expect(accept(&long) == null);
}

test "open_url_seam: a value is trimmed" {
    try std.testing.expectEqualStrings("1.37.2", accept(" 1.37.2\r\n").?);
    try std.testing.expectEqualStrings("C:\\t\\urls.txt", accept("C:\\t\\urls.txt").?);
}

test "open_url_seam: one URL is exactly one line" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://example.com/a\n",
        formatLine(&buf, "https://example.com/a").?,
    );
    try std.testing.expectEqualStrings(
        "https://x/a  b\n",
        formatLine(&buf, "https://x/a\r\nb").?,
    );
}

test "open_url_seam: a URL that does not fit is refused, not truncated" {
    var buf: [8]u8 = undefined;
    try std.testing.expect(formatLine(&buf, "https://example.com") == null);
    try std.testing.expectEqualStrings("1234567\n", formatLine(&buf, "1234567").?);
}

test "open_url_seam: record appends one line per URL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "urls.txt" });
    defer std.testing.allocator.free(path);

    record(path, "https://a/1");
    record(path, "https://b/2");
    const got = try tmp.dir.readFileAlloc(std.testing.allocator, "urls.txt", 1024);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("https://a/1\nhttps://b/2\n", got);
}
