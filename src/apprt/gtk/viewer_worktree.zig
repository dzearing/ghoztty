//! Which git working tree a GTK viewer pane's content belongs to (T3419,
//! Linux L9j; Mac `ViewerWorktreeResolver`, win32 `viewer_worktree.zig`).
//!
//! The strategy is the shared one - win32's `Plan`, `Cache`, `loopbackPort`,
//! `tooltipText` and `parseRootPosix` are used as they are - and this module
//! supplies only what a POSIX host spells differently:
//!
//! - **Paths.** win32's `fileDirectory` reasons about Windows paths and turns
//!   every `/` into `\`; a Linux viewer's file is `/home/...`, so leg 1 is
//!   re-stated here with the POSIX path functions.
//! - **Leg 2, port -> pid -> cwd.** The Mac asks `lsof`; win32 asks
//!   `GetExtendedTcpTable` and a PEB read. Linux has the answer in `/proc`:
//!   the LISTEN row for the port in `/proc/net/tcp` / `tcp6` names a socket
//!   inode, the process holding `socket:[<inode>]` among its
//!   `/proc/<pid>/fd` links owns it, and `/proc/<pid>/cwd` is its working
//!   directory. The parsing is pure and tested here; the reads are
//!   `ViewerFeedback.zig`'s. A process of another user has an unreadable fd
//!   table, which reads as "no listener" - the origin fallback, exactly what
//!   the Mac does with a port it cannot inspect.
//!
//! No GTK imports: this file runs in the none lane.
const std = @import("std");
const content = @import("../win32/viewer_content.zig");
const shared = @import("../win32/viewer_worktree.zig");

pub const Plan = shared.Plan;
pub const PortPlan = shared.PortPlan;
pub const DirProbe = shared.DirProbe;
pub const Cache = shared.Cache;
pub const loopbackPort = shared.loopbackPort;
pub const parseRoot = shared.parseRootPosix;
pub const tooltipText = shared.tooltipText;
pub const realDirExists = shared.realDirExists;

/// Candidate `git` binaries, in order: the PATH hit first, then the two
/// places a distro or a hand install puts one, for an app launched with a
/// thin PATH (a desktop file, a session restore).
pub const git_paths = [_][]const u8{ "git", "/usr/bin/git", "/usr/local/bin/git" };

/// The repo-root query with `git_paths[index]` as the binary. Win32's argv,
/// with this platform's binary list.
pub fn rootArgv(index: usize, dir: []const u8) [5][]const u8 {
    return .{ git_paths[index], "-C", dir, "rev-parse", "--show-toplevel" };
}

/// The feedback report's branch and commit queries (T3544), asked at SEND
/// time - a revision cached with the root would be as old as the pane.
/// Win32's argv, with this platform's binary list; its parsers unchanged.
pub fn branchArgv(index: usize, root: []const u8) [6][]const u8 {
    return .{ git_paths[index], "-C", root, "rev-parse", "--abbrev-ref", "HEAD" };
}

pub fn commitArgv(index: usize, root: []const u8) [5][]const u8 {
    return .{ git_paths[index], "-C", root, "rev-parse", "HEAD" };
}

pub const parseBranch = shared.parseBranch;
pub const parseCommit = shared.parseCommit;

/// Strategy D's plan for a POSIX host: the viewed file's directory, else a
/// loopback port to look up (with the origin behind it), else the origin.
/// Win32's `plan` with leg 1 spelled for POSIX paths.
pub fn plan(
    buf: []u8,
    location: []const u8,
    origin_directory: ?[]const u8,
    dir_exists: DirProbe,
) Plan {
    if (fileDirectory(buf, location)) |dir| {
        // A viewer showing a missing file must not attribute feedback to a
        // directory nobody has: it falls through to the origin.
        if (dir_exists(dir)) return .{ .directory = dir };
        return fallback(origin_directory);
    }
    if (loopbackPort(location)) |port| {
        return .{ .port = .{ .port = port, .fallback = nonEmpty(origin_directory) } };
    }
    return fallback(origin_directory);
}

fn nonEmpty(dir: ?[]const u8) ?[]const u8 {
    const d = dir orelse return null;
    return if (d.len == 0) null else d;
}

fn fallback(origin_directory: ?[]const u8) Plan {
    return if (nonEmpty(origin_directory)) |o| .{ .directory = o } else .none;
}

/// The directory of the file a location names, or null for anything else.
/// The path must be ABSOLUTE, which is what keeps a `git-diff:<rev>` spec (a
/// revspec, not a path) out of leg 1 - the Mac's `hasPrefix("/")`.
pub fn fileDirectory(buf: []u8, location: []const u8) ?[]const u8 {
    if (location.len == 0) return null;
    if (!content.modeFor(location).isFile()) return null;
    const path = content.filePath(buf, location) orelse return null;
    if (!std.fs.path.isAbsolutePosix(path)) return null;
    const dir = std.fs.path.dirnamePosix(path) orelse return null;
    if (dir.len == 0) return null;
    return dir;
}

/// The last component of a worktree root: the button's accessible name.
pub fn worktreeName(root: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, root, "/");
    if (trimmed.len == 0) return root;
    return std.fs.path.basenamePosix(trimmed);
}

// -----------------------------------------------------------------------------
// Leg 2 on Linux: /proc/net/tcp -> socket inode -> pid -> cwd
// -----------------------------------------------------------------------------

/// The tables to read, IPv4 first. A dev server bound to `::` listens in
/// `tcp6` only (and still answers 127.0.0.1 through the v4-mapped space), so
/// both are needed for `localhost`.
pub const tcp_tables = [_][]const u8{ "/proc/net/tcp", "/proc/net/tcp6" };

/// The `st` column's value for a listening socket.
const tcp_listen: u8 = 0x0A;

/// The socket inode of the first row in a `/proc/net/tcp`-shaped table that
/// is LISTENING on `port`, whatever address it is bound to (a loopback
/// location reaches a wildcard listener as well as a loopback one). Null when
/// no row matches.
///
/// A row is `sl local_address rem_address st tx:rx tr:when retrnsmt uid
/// timeout inode ...`, the local address `<hex ip>:<hex port>` (8 hex digits
/// of address in `tcp`, 32 in `tcp6`). The first line is the header.
pub fn listenInode(table: []const u8, port: u16) ?u64 {
    var lines = std.mem.splitScalar(u8, table, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // "0:"
        const local = fields.next() orelse continue;
        _ = fields.next() orelse continue; // remote
        const st = fields.next() orelse continue;
        const state = std.fmt.parseInt(u8, st, 16) catch continue;
        if (state != tcp_listen) continue;
        const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
        const row_port = std.fmt.parseInt(u16, local[colon + 1 ..], 16) catch continue;
        if (row_port != port) continue;
        // tx:rx, tr:when, retrnsmt, uid, timeout, then the inode.
        var skip: usize = 0;
        while (skip < 5) : (skip += 1) _ = fields.next() orelse break;
        if (skip < 5) continue;
        const inode_text = fields.next() orelse continue;
        const inode = std.fmt.parseInt(u64, inode_text, 10) catch continue;
        // Inode 0 is a socket in a state with no owner left (TIME_WAIT
        // style); it names no process.
        if (inode == 0) continue;
        return inode;
    }
    return null;
}

/// The inode a `/proc/<pid>/fd/<n>` link names when it is a socket
/// (`socket:[12345]`), else null.
pub fn socketInode(link: []const u8) ?u64 {
    const prefix = "socket:[";
    if (!std.mem.startsWith(u8, link, prefix)) return null;
    if (link.len < prefix.len + 2 or link[link.len - 1] != ']') return null;
    return std.fmt.parseInt(u64, link[prefix.len .. link.len - 1], 10) catch null;
}

/// Whether a `/proc` entry name is a process id (all digits).
pub fn isPid(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

fn allDirs(_: []const u8) bool {
    return true;
}

fn noDirs(_: []const u8) bool {
    return false;
}

test "leg 1: a file is attributed to its own directory, a file:// URL too" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "/home/u/repo/docs",
        plan(&buf, "/home/u/repo/docs/design.md", null, allDirs).directory,
    );
    try testing.expectEqualStrings(
        "/home/u/repo",
        plan(&buf, "file:///home/u/repo/README.md", null, allDirs).directory,
    );
    // The file wins over the origin: the pane moved.
    try testing.expectEqualStrings(
        "/home/u/repo/docs",
        plan(&buf, "/home/u/repo/docs/design.md", "/elsewhere", allDirs).directory,
    );
    // An image pane is a file viewer like any other.
    try testing.expectEqualStrings(
        "/home/u/repo/shots",
        plan(&buf, "/home/u/repo/shots/a.png", null, allDirs).directory,
    );
}

test "leg 1 falls back to the origin when the file's directory is gone" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/home/u/repo", plan(&buf, "/gone/x.md", "/home/u/repo", noDirs).directory);
    try testing.expect(plan(&buf, "/gone/x.md", null, noDirs) == .none);
}

test "leg 2: a loopback page plans a port lookup with the origin behind it" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = plan(&buf, "http://localhost:3000/app", "/home/u/repo", allDirs);
    try testing.expectEqual(@as(u16, 3000), p.port.port);
    try testing.expectEqualStrings("/home/u/repo", p.port.fallback.?);
    const q = plan(&buf, "http://127.0.0.1:8080/", "", allDirs);
    try testing.expectEqual(@as(u16, 8080), q.port.port);
    try testing.expect(q.port.fallback == null);
}

test "leg 3: a website, a blank pane and a diff spec fall back to the origin" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "https://example.com/docs", "about:blank", "", "git-status:", "git-diff:main...HEAD" }) |loc| {
        try testing.expectEqualStrings("/home/u/repo", plan(&buf, loc, "/home/u/repo", allDirs).directory);
        try testing.expect(plan(&buf, loc, null, allDirs) == .none);
        // An empty origin is no origin: nothing to attribute the pane to.
        try testing.expect(plan(&buf, loc, "", allDirs) == .none);
    }
}

test "a relative path is not a file location (only absolute paths count)" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(fileDirectory(&buf, "docs/x.md") == null);
}

test "worktreeName is the root's last component" {
    try testing.expectEqualStrings("ghoztty-l", worktreeName("/home/u/ghoztty-l"));
    try testing.expectEqualStrings("ghoztty-l", worktreeName("/home/u/ghoztty-l/"));
    try testing.expectEqualStrings("/", worktreeName("/"));
}

test "parseRoot keeps a POSIX root as git printed it" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/repo", parseRoot(&buf, "/home/u/repo\n").?);
    try testing.expect(parseRoot(&buf, "\n") == null);
}

test "rootArgv asks git for the toplevel of the directory" {
    const argv = rootArgv(0, "/home/u/repo/docs");
    try testing.expectEqualStrings("git", argv[0]);
    try testing.expectEqualStrings("/home/u/repo/docs", argv[2]);
    try testing.expectEqualStrings("--show-toplevel", argv[4]);
}

const tcp_fixture =
    "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" ++
    "   0: 0100007F:1F90 0100007F:C350 01 00000000:00000000 00:00000000 00000000  1000        0 99999 1 0000000000000000 20 4 30 10 -1\n" ++
    "   1: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 41234 1 0000000000000000 100 0 0 10 0\n" ++
    "   2: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 55555 1 0000000000000000 100 0 0 10 0\n" ++
    "   3: 00000000:2328 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 0 1 0000000000000000 100 0 0 10 0\n";

const tcp6_fixture =
    "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" ++
    "   0: 00000000000000000000000000000000:1388 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 777 1 0000000000000000 100 0 0 10 0\n";

test "branchArgv and commitArgv use this platform's git" {
    const b = branchArgv(1, "/r");
    try std.testing.expectEqualStrings("/usr/bin/git", b[0]);
    try std.testing.expectEqualStrings("--abbrev-ref", b[4]);
    const c = commitArgv(0, "/r");
    try std.testing.expectEqualStrings("git", c[0]);
    try std.testing.expectEqualStrings("/r", c[2]);
    try std.testing.expectEqualStrings("HEAD", c[4]);
    try std.testing.expect(parseBranch("HEAD\n") == null);
    try std.testing.expectEqualStrings("main", parseBranch("main\n").?);
}

test "listenInode finds the LISTEN row for a port, any bound address" {
    // :3000 on 127.0.0.1.
    try testing.expectEqual(@as(?u64, 41234), listenInode(tcp_fixture, 3000));
    // :8080 has an ESTABLISHED row first (st 01, not a listener) and a
    // wildcard listener after it: the listener wins.
    try testing.expectEqual(@as(?u64, 55555), listenInode(tcp_fixture, 8080));
    // :9000's row has inode 0: no owner to find.
    try testing.expect(listenInode(tcp_fixture, 9000) == null);
    // Nothing on :1234.
    try testing.expect(listenInode(tcp_fixture, 1234) == null);
    // tcp6: `::`:5000.
    try testing.expectEqual(@as(?u64, 777), listenInode(tcp6_fixture, 5000));
    try testing.expect(listenInode("", 3000) == null);
    try testing.expect(listenInode("header only\n", 3000) == null);
}

test "socketInode reads a socket fd link and nothing else" {
    try testing.expectEqual(@as(?u64, 41234), socketInode("socket:[41234]"));
    try testing.expect(socketInode("pipe:[41234]") == null);
    try testing.expect(socketInode("/dev/pts/0") == null);
    try testing.expect(socketInode("socket:[]") == null);
    try testing.expect(socketInode("socket:[12") == null);
}

test "isPid accepts only all-digit /proc names" {
    try testing.expect(isPid("4242"));
    try testing.expect(!isPid("self"));
    try testing.expect(!isPid(""));
    try testing.expect(!isPid("12a"));
}
