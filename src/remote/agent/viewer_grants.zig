//! Tunnelled file viewers, agent side (T2219; docs/design/remote-viewer-tunnel.md
//! decisions 1 and 4).
//!
//! A viewer pane on the user's machine can show a file that lives on THIS
//! machine. It never names an arbitrary path to read: it OPENs one file, which
//! grants that file's directory, and every later read names the grant and a
//! path RELATIVE to its root - how a page reaches its own `img/x.png` and
//! linked `notes.md`. This module is the whole policy for those reads:
//!
//!   - a relative path that climbs out (`../x`), an absolute one (`/etc/x`,
//!     `C:\x`) and a drive-relative one (`C:x`) are refused before the
//!     filesystem is asked anything;
//!   - the candidate is then resolved by the OS (links followed) and checked
//!     against the root AGAIN, so a link inside the root that points out of it
//!     is refused too - the textual check alone would let it through;
//!   - a file over `protocol.max_viewer_file_bytes` is refused before a byte is
//!     read, and one read returns at most `protocol.max_viewer_chunk_bytes`.
//!
//! The root is the directory of the opened file's REAL path, so the file
//! itself is always readable through its own grant, and relative links resolve
//! from where the bytes actually live.
//!
//! One `Grants` per connection, touched only from that connection's control
//! reader thread, so it takes no lock.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("../protocol.zig");

const Allocator = std.mem.Allocator;
const E = protocol.ViewerError;

pub const Grants = struct {
    alloc: Allocator,
    /// grant id -> the granted root (a real path). Owned.
    roots: std.AutoArrayHashMapUnmanaged(u64, []u8) = .empty,
    /// Never reused within a connection, so a stale id from a closed pane can
    /// never read through a newer pane's grant.
    next_id: u64 = 1,

    pub fn init(alloc: Allocator) Grants {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Grants) void {
        for (self.roots.values()) |r| self.alloc.free(r);
        self.roots.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn count(self: *const Grants) usize {
        return self.roots.count();
    }

    pub const Opened = struct {
        grant: u64,
        /// Borrowed from the grant; valid until it is closed.
        root: []const u8,
        /// The file's name inside `root`. Owned by the caller.
        name: []u8,
        size: u64,
    };

    pub const OpenResult = union(enum) {
        ok: Opened,
        refused: []const u8, // a `protocol.ViewerError` string
    };

    /// Grant the directory of the file at `path` (absolute, on this machine).
    pub fn open(self: *Grants, path: []const u8) Allocator.Error!OpenResult {
        if (!std.fs.path.isAbsolute(path) or hasNul(path)) return .{ .refused = E.not_absolute };
        if (self.roots.count() >= protocol.max_viewer_grants) return .{ .refused = E.too_many_grants };

        const real = realpath(self.alloc, path) catch |err| return .{ .refused = refusalFor(err) };
        defer self.alloc.free(real);
        const size = switch (statFile(real)) {
            .size => |n| n,
            .refused => |r| return .{ .refused = r },
        };
        const dir = std.fs.path.dirname(real) orelse return .{ .refused = E.not_found };
        const base = std.fs.path.basename(real);

        const root = try self.alloc.dupe(u8, dir);
        errdefer self.alloc.free(root);
        const name = try self.alloc.dupe(u8, base);
        errdefer self.alloc.free(name);

        const id = self.next_id;
        self.next_id += 1;
        try self.roots.put(self.alloc, id, root);
        return .{ .ok = .{ .grant = id, .root = root, .name = name, .size = size } };
    }

    /// Drop a grant. Unknown ids are a no-op.
    pub fn close(self: *Grants, grant: u64) void {
        if (self.roots.fetchSwapRemove(grant)) |kv| self.alloc.free(kv.value);
    }

    pub fn rootOf(self: *const Grants, grant: u64) ?[]const u8 {
        return self.roots.get(grant);
    }

    pub const Chunk = struct {
        /// Owned by the caller.
        bytes: []u8,
        size: u64,
        offset: u64,
        eof: bool,
    };

    pub const ReadResult = union(enum) {
        ok: Chunk,
        refused: []const u8,
    };

    /// Read up to `max_len` bytes at `offset` of `rel` under `grant`'s root.
    pub fn read(
        self: *const Grants,
        grant: u64,
        rel: []const u8,
        offset: u64,
        max_len: u32,
    ) Allocator.Error!ReadResult {
        const granted = self.roots.get(grant) orelse return .{ .refused = E.no_grant };

        const candidate = (try candidateUnder(self.alloc, granted, rel)) orelse
            return .{ .refused = E.outside_root };
        defer self.alloc.free(candidate);

        // The OS's answer, links followed, measured against the root again.
        const real = realpath(self.alloc, candidate) catch |err| return .{ .refused = refusalFor(err) };
        defer self.alloc.free(real);
        if (!isUnder(real, granted)) return .{ .refused = E.outside_root };

        var file = std.fs.openFileAbsolute(real, .{}) catch |err| return .{ .refused = refusalFor(err) };
        defer file.close();
        const st = file.stat() catch return .{ .refused = E.read_failed };
        if (st.kind != .file) return .{ .refused = E.not_found };
        if (st.size > protocol.max_viewer_file_bytes) return .{ .refused = E.too_large };

        const start = @min(offset, st.size);
        const want: u64 = @min(@as(u64, @min(max_len, protocol.max_viewer_chunk_bytes)), st.size - start);
        const buf = try self.alloc.alloc(u8, @intCast(want));
        errdefer self.alloc.free(buf);
        const n = file.preadAll(buf, start) catch {
            self.alloc.free(buf);
            return .{ .refused = E.read_failed };
        };
        // A file that shrank under us returns what is there; `eof` follows the
        // bytes actually read so the client stops rather than spinning.
        const bytes = if (n == buf.len) buf else blk: {
            const short = try self.alloc.realloc(buf, n);
            break :blk short;
        };
        return .{ .ok = .{
            .bytes = bytes,
            .size = st.size,
            .offset = start,
            .eof = n < want or start + n >= st.size,
        } };
    }
};

const StatResult = union(enum) { size: u64, refused: []const u8 };

fn statFile(path: []const u8) StatResult {
    var file = std.fs.openFileAbsolute(path, .{}) catch |err| return .{ .refused = refusalFor(err) };
    defer file.close();
    const st = file.stat() catch return .{ .refused = E.read_failed };
    if (st.kind != .file) return .{ .refused = E.not_found };
    if (st.size > protocol.max_viewer_file_bytes) return .{ .refused = E.too_large };
    return .{ .size = st.size };
}

fn realpath(alloc: Allocator, path: []const u8) ![]u8 {
    return std.fs.realpathAlloc(alloc, path);
}

fn refusalFor(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir, error.BadPathName, error.NameTooLong => E.not_found,
        else => E.read_failed,
    };
}

fn hasNul(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, 0) != null;
}

fn hasDriveLetter(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

/// The path `rel` names under `root`, or null when it would leave it. Textual
/// only - `Grants.read` re-checks the OS's resolved path, which is what catches
/// a link. Caller owns the result.
pub fn candidateUnder(alloc: Allocator, root: []const u8, rel: []const u8) Allocator.Error!?[]u8 {
    if (root.len == 0 or rel.len == 0 or hasNul(rel)) return null;
    // An absolute `rel` makes `resolve` discard `root` outright. A leading
    // separator counts as absolute on every OS here: on Windows `/x` means the
    // current drive's root, which is not `root` either.
    if (std.fs.path.isAbsolute(rel)) return null;
    if (rel[0] == '/' or rel[0] == '\\') return null;
    // `C:x` is rooted at that drive's own working directory.
    if (hasDriveLetter(rel)) return null;

    const joined = try std.fs.path.resolve(alloc, &.{ root, rel });
    if (!isUnder(joined, root)) {
        alloc.free(joined);
        return null;
    }
    return joined;
}

/// Whether `path` is `root` itself or inside it, by this OS's case rules.
pub fn isUnder(path: []const u8, root: []const u8) bool {
    if (root.len == 0 or path.len < root.len) return false;
    if (!eqlPath(path[0..root.len], root)) return false;
    if (path.len == root.len) return true;
    if (isSep(root[root.len - 1])) return true;
    return isSep(path[root.len]);
}

fn isSep(c: u8) bool {
    return c == '/' or (builtin.os.tag == .windows and c == '\\');
}

fn eqlPath(a: []const u8, b: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

test "T2219 candidateUnder refuses every way out of the root" {
    const alloc = testing.allocator;
    const root = if (builtin.os.tag == .windows) "C:\\docs\\site" else "/docs/site";

    const ok = (try candidateUnder(alloc, root, "img/a.png")).?;
    defer alloc.free(ok);
    try testing.expect(isUnder(ok, root));

    const back_in = (try candidateUnder(alloc, root, "img/../notes.md")).?;
    defer alloc.free(back_in);
    try testing.expect(isUnder(back_in, root));

    for ([_][]const u8{
        "../secret.txt",
        "img/../../secret.txt",
        "/etc/passwd",
        "\\Windows\\win.ini",
        "C:\\Windows\\win.ini",
        "C:win.ini",
        "",
        "a\x00b",
    }) |rel| {
        if (try candidateUnder(alloc, root, rel)) |p| {
            defer alloc.free(p);
            std.debug.print("escaped: {s} -> {s}\n", .{ rel, p });
            return error.TestEscaped;
        }
    }
}

test "T2219 isUnder needs a separator boundary, not a string prefix" {
    const root = if (builtin.os.tag == .windows) "C:\\docs" else "/docs";
    const sibling = if (builtin.os.tag == .windows) "C:\\docs-private\\x" else "/docs-private/x";
    const child = if (builtin.os.tag == .windows) "C:\\docs\\x" else "/docs/x";
    try testing.expect(!isUnder(sibling, root));
    try testing.expect(isUnder(child, root));
    try testing.expect(isUnder(root, root));
    if (builtin.os.tag == .windows) try testing.expect(isUnder("c:\\DOCS\\x", root));
}

fn writeFile(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    var f = try dir.createFile(name, .{});
    defer f.close();
    try f.writeAll(bytes);
}

test "T2219 Grants: open grants the file's directory; reads stay inside it" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("site/img");
    try writeFile(tmp.dir, "site/README.md", "# hi\n![](img/a.png)\n");
    try writeFile(tmp.dir, "site/img/a.png", "PNGDATA");
    try writeFile(tmp.dir, "secret.txt", "do not read");

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);
    const readme = try std.fs.path.join(alloc, &.{ base, "site", "README.md" });
    defer alloc.free(readme);

    var g = Grants.init(alloc);
    defer g.deinit();

    const opened = switch (try g.open(readme)) {
        .ok => |o| o,
        .refused => |r| {
            std.debug.print("refused: {s}\n", .{r});
            return error.TestUnexpectedRefusal;
        },
    };
    defer alloc.free(opened.name);
    try testing.expectEqualStrings("README.md", opened.name);
    try testing.expectEqual(@as(u64, 20), opened.size);
    try testing.expect(std.mem.endsWith(u8, opened.root, "site"));

    // The file itself, through its own grant.
    switch (try g.read(opened.grant, opened.name, 0, 1024)) {
        .ok => |c| {
            defer alloc.free(c.bytes);
            try testing.expectEqualStrings("# hi\n![](img/a.png)\n", c.bytes);
            try testing.expect(c.eof);
        },
        .refused => return error.TestUnexpectedRefusal,
    }
    // A relative picture.
    switch (try g.read(opened.grant, "img/a.png", 0, 1024)) {
        .ok => |c| {
            defer alloc.free(c.bytes);
            try testing.expectEqualStrings("PNGDATA", c.bytes);
        },
        .refused => return error.TestUnexpectedRefusal,
    }
    // Pieces: offset + max_len, eof only on the last one.
    switch (try g.read(opened.grant, "img/a.png", 3, 2)) {
        .ok => |c| {
            defer alloc.free(c.bytes);
            try testing.expectEqualStrings("DA", c.bytes);
            try testing.expectEqual(@as(u64, 3), c.offset);
            try testing.expectEqual(@as(u64, 7), c.size);
            try testing.expect(!c.eof);
        },
        .refused => return error.TestUnexpectedRefusal,
    }
    switch (try g.read(opened.grant, "img/a.png", 5, 100)) {
        .ok => |c| {
            defer alloc.free(c.bytes);
            try testing.expectEqualStrings("TA", c.bytes);
            try testing.expect(c.eof);
        },
        .refused => return error.TestUnexpectedRefusal,
    }

    // Out of the root, a directory, a missing file, a bogus grant.
    try testing.expectEqualStrings(E.outside_root, (try g.read(opened.grant, "../secret.txt", 0, 64)).refused);
    try testing.expectEqualStrings(E.outside_root, (try g.read(opened.grant, base, 0, 64)).refused);
    try testing.expectEqualStrings(E.not_found, (try g.read(opened.grant, "img", 0, 64)).refused);
    try testing.expectEqualStrings(E.not_found, (try g.read(opened.grant, "nope.md", 0, 64)).refused);
    try testing.expectEqualStrings(E.no_grant, (try g.read(opened.grant + 100, opened.name, 0, 64)).refused);

    // Closed grants read nothing, and ids are not reused.
    g.close(opened.grant);
    g.close(opened.grant); // twice is fine
    try testing.expectEqualStrings(E.no_grant, (try g.read(opened.grant, opened.name, 0, 64)).refused);
    switch (try g.open(readme)) {
        .ok => |o| {
            defer alloc.free(o.name);
            try testing.expect(o.grant != opened.grant);
        },
        .refused => return error.TestUnexpectedRefusal,
    }
}

test "T2219 Grants: open refuses relative paths, directories and missing files" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    var g = Grants.init(alloc);
    defer g.deinit();
    try testing.expectEqualStrings(E.not_absolute, (try g.open("README.md")).refused);
    try testing.expectEqualStrings(E.not_found, (try g.open(base)).refused);
    const missing = try std.fs.path.join(alloc, &.{ base, "missing.md" });
    defer alloc.free(missing);
    try testing.expectEqualStrings(E.not_found, (try g.open(missing)).refused);
    try testing.expectEqual(@as(usize, 0), g.count());
}

test "T2219 Grants: a file over the size cap is refused before it is read" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var f = try tmp.dir.createFile("big.md", .{});
        defer f.close();
        // Sparse where the OS allows it: only the size matters.
        try f.setEndPos(protocol.max_viewer_file_bytes + 1);
    }
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);
    const big = try std.fs.path.join(alloc, &.{ base, "big.md" });
    defer alloc.free(big);

    var g = Grants.init(alloc);
    defer g.deinit();
    try testing.expectEqualStrings(E.too_large, (try g.open(big)).refused);
}

test "T2219 Grants: the grant count is bounded and nothing is evicted" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.md", "a");
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);
    const a = try std.fs.path.join(alloc, &.{ base, "a.md" });
    defer alloc.free(a);

    var g = Grants.init(alloc);
    defer g.deinit();
    var first: u64 = 0;
    for (0..protocol.max_viewer_grants) |i| switch (try g.open(a)) {
        .ok => |o| {
            alloc.free(o.name);
            if (i == 0) first = o.grant;
        },
        .refused => return error.TestUnexpectedRefusal,
    };
    try testing.expectEqualStrings(E.too_many_grants, (try g.open(a)).refused);
    // The first grant still reads.
    switch (try g.read(first, "a.md", 0, 8)) {
        .ok => |c| alloc.free(c.bytes),
        .refused => return error.TestUnexpectedRefusal,
    }
}

test "T2219 Grants: a link inside the root that points out of it is refused" {
    // Creating a symlink needs a privilege Windows does not grant by default.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("site");
    try writeFile(tmp.dir, "site/README.md", "x");
    try writeFile(tmp.dir, "secret.txt", "do not read");
    try tmp.dir.symLink("../secret.txt", "site/leak.txt", .{});

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);
    const readme = try std.fs.path.join(alloc, &.{ base, "site", "README.md" });
    defer alloc.free(readme);

    var g = Grants.init(alloc);
    defer g.deinit();
    const o = (try g.open(readme)).ok;
    defer alloc.free(o.name);
    try testing.expectEqualStrings(E.outside_root, (try g.read(o.grant, "leak.txt", 0, 64)).refused);
}
