//! Where the `claude` CLI lives (T1620) - the search behind
//! `AgentIntegration.findClaude`, split from the process-global environment
//! and the filesystem so every branch of it runs under test.
//!
//! Order, the Mac `findClaude` Windows-flavored:
//!
//! 1. `GHOZTTY_CLAUDE_EXE`, when set at all. Set-but-empty means "there is
//!    no claude" (the test hook that switches the migration's uninstall
//!    off), and a set path that does not exist is a miss too - it never
//!    falls through to PATH, so a test that names a stub cannot be rescued
//!    by the real install on the box.
//! 2. Each `PATH` entry, in order, trying `claude.exe`, `claude.cmd`,
//!    `claude.bat` (the native installer, then npm's shims). Entries are
//!    normalized the way the PATH editor reads them (quotes, trailing
//!    separators), and an empty entry is skipped rather than read as the
//!    current directory.
//! 3. The well-known install locations the process PATH can miss: the
//!    native installer's `%USERPROFILE%\.local\bin\claude.exe` and
//!    `%USERPROFILE%\.claude\local\claude.exe`, then npm's global
//!    `%APPDATA%\npm\claude.cmd`.
//!
//! No OS imports, so its tests run in every app-runtime lane (T59a).
const std = @import("std");
const path_env = @import("../../os/path_env.zig");

/// The environment the search reads. `null` means the variable is unset,
/// which for `override` is different from set-but-empty.
pub const Env = struct {
    override: ?[]const u8 = null,
    path: ?[]const u8 = null,
    userprofile: ?[]const u8 = null,
    appdata: ?[]const u8 = null,
};

/// Answers whether a candidate path names a file that can be run.
pub const Exists = *const fn (ctx: ?*anyopaque, path: []const u8) bool;

pub const exts = [_][]const u8{ ".exe", ".cmd", ".bat" };

const home_rels = [_][]const u8{
    "\\.local\\bin\\claude.exe",
    "\\.claude\\local\\claude.exe",
};

/// The claude path to run, or null when there is none. Candidates are
/// allocated in `arena`; the returned slice is one of them (or `env.override`).
pub fn locate(
    arena: std.mem.Allocator,
    env: Env,
    exists_ctx: ?*anyopaque,
    exists: Exists,
) ?[]const u8 {
    if (env.override) |override| {
        if (override.len == 0) return null;
        return if (exists(exists_ctx, override)) override else null;
    }

    if (env.path) |path_value| {
        var it = std.mem.splitScalar(u8, path_value, ';');
        while (it.next()) |entry| {
            const dir = path_env.normalize(entry);
            if (dir.len == 0) continue;
            for (exts) |ext| {
                const candidate = join(arena, dir, "claude", ext) orelse continue;
                if (exists(exists_ctx, candidate)) return candidate;
            }
        }
    }

    if (nonEmpty(env.userprofile)) |home| {
        for (home_rels) |rel| {
            const candidate = std.mem.concat(arena, u8, &.{ trimSep(home), rel }) catch continue;
            if (exists(exists_ctx, candidate)) return candidate;
        }
    }
    if (nonEmpty(env.appdata)) |appdata| {
        const candidate = std.mem.concat(
            arena,
            u8,
            &.{ trimSep(appdata), "\\npm\\claude.cmd" },
        ) catch return null;
        if (exists(exists_ctx, candidate)) return candidate;
    }
    return null;
}

/// `dir\name ext`, without doubling the separator of a drive root (`C:\`).
fn join(arena: std.mem.Allocator, dir: []const u8, name: []const u8, ext: []const u8) ?[]const u8 {
    const sep: []const u8 = if (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/') "" else "\\";
    return std.mem.concat(arena, u8, &.{ dir, sep, name, ext }) catch null;
}

fn trimSep(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\\/");
}

/// An unset or empty variable names no location: an empty USERPROFILE must
/// not turn `\.local\bin\claude.exe` into a probe at the drive root.
fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (std.mem.trim(u8, s, " \t").len == 0) null else s;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A fake filesystem: a fixed set of existing paths (compared
/// case-insensitively, like Windows), plus a record of every probe.
const FakeFs = struct {
    present: []const []const u8,
    probes: std.ArrayList([]const u8) = .empty,
    alloc: std.mem.Allocator,

    fn exists(ctx: ?*anyopaque, path: []const u8) bool {
        const self: *FakeFs = @ptrCast(@alignCast(ctx.?));
        self.probes.append(self.alloc, path) catch {};
        for (self.present) |p| if (std.ascii.eqlIgnoreCase(p, path)) return true;
        return false;
    }

    fn run(self: *FakeFs, env: Env) ?[]const u8 {
        return locate(self.alloc, env, self, exists);
    }
};

fn fake(arena: std.mem.Allocator, present: []const []const u8) FakeFs {
    return .{ .present = present, .alloc = arena };
}

test "claude_locate: a PATH hit on claude.exe" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var fs = fake(a.allocator(), &.{"C:\\tools\\claude.exe"});
    const got = fs.run(.{ .path = "C:\\Windows;C:\\tools" });
    try testing.expectEqualStrings("C:\\tools\\claude.exe", got.?);
}

test "claude_locate: a PATH hit on an npm .cmd shim and on a .bat" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var fs = fake(a.allocator(), &.{"D:\\npm\\claude.cmd"});
    try testing.expectEqualStrings("D:\\npm\\claude.cmd", fs.run(.{ .path = "D:\\npm" }).?);

    var fs2 = fake(a.allocator(), &.{"D:\\bin\\claude.bat"});
    try testing.expectEqualStrings("D:\\bin\\claude.bat", fs2.run(.{ .path = "D:\\bin" }).?);
}

test "claude_locate: within one directory .exe beats .cmd beats .bat" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var fs = fake(a.allocator(), &.{ "C:\\x\\claude.bat", "C:\\x\\claude.cmd", "C:\\x\\claude.exe" });
    try testing.expectEqualStrings("C:\\x\\claude.exe", fs.run(.{ .path = "C:\\x" }).?);
    var fs2 = fake(a.allocator(), &.{ "C:\\x\\claude.bat", "C:\\x\\claude.cmd" });
    try testing.expectEqualStrings("C:\\x\\claude.cmd", fs2.run(.{ .path = "C:\\x" }).?);
}

test "claude_locate: PATH order wins over extension order" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    // An earlier directory's .cmd outranks a later directory's .exe - the
    // same answer `where claude` gives.
    var fs = fake(a.allocator(), &.{ "C:\\late\\claude.exe", "C:\\early\\claude.cmd" });
    try testing.expectEqualStrings(
        "C:\\early\\claude.cmd",
        fs.run(.{ .path = "C:\\early;C:\\late" }).?,
    );
}

test "claude_locate: quoted, padded and trailing-separator entries are normalized; empty ones skipped" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var fs = fake(a.allocator(), &.{"C:\\Program Files\\Claude\\claude.exe"});
    const got = fs.run(.{ .path = ";; \"C:\\Program Files\\Claude\\\" ;" });
    try testing.expectEqualStrings("C:\\Program Files\\Claude\\claude.exe", got.?);
    // The empty entries never became a probe of a bare "\claude.exe".
    for (fs.probes.items) |p| try testing.expect(p[0] != '\\');
}

test "claude_locate: a drive-root PATH entry does not double the separator" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var fs = fake(a.allocator(), &.{"E:\\claude.exe"});
    try testing.expectEqualStrings("E:\\claude.exe", fs.run(.{ .path = "E:\\" }).?);
}

test "claude_locate: a miss everywhere is null, after probing every candidate in order" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var fs = fake(a.allocator(), &.{});
    const got = fs.run(.{
        .path = "C:\\a;C:\\b",
        .userprofile = "C:\\Users\\u",
        .appdata = "C:\\Users\\u\\AppData\\Roaming",
    });
    try testing.expect(got == null);
    const want = [_][]const u8{
        "C:\\a\\claude.exe",                         "C:\\a\\claude.cmd",
        "C:\\a\\claude.bat",                         "C:\\b\\claude.exe",
        "C:\\b\\claude.cmd",                         "C:\\b\\claude.bat",
        "C:\\Users\\u\\.local\\bin\\claude.exe",     "C:\\Users\\u\\.claude\\local\\claude.exe",
        "C:\\Users\\u\\AppData\\Roaming\\npm\\claude.cmd",
    };
    try testing.expectEqual(want.len, fs.probes.items.len);
    for (want, fs.probes.items) |w, p| try testing.expectEqualStrings(w, p);
}

test "claude_locate: the well-known locations catch an install the PATH misses" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const env: Env = .{
        .path = "C:\\Windows",
        .userprofile = "C:\\Users\\u\\",
        .appdata = "C:\\Users\\u\\AppData\\Roaming",
    };
    var native = fake(a.allocator(), &.{"C:\\Users\\u\\.local\\bin\\claude.exe"});
    try testing.expectEqualStrings("C:\\Users\\u\\.local\\bin\\claude.exe", native.run(env).?);

    var legacy = fake(a.allocator(), &.{"C:\\Users\\u\\.claude\\local\\claude.exe"});
    try testing.expectEqualStrings("C:\\Users\\u\\.claude\\local\\claude.exe", legacy.run(env).?);

    var npm = fake(a.allocator(), &.{"C:\\Users\\u\\AppData\\Roaming\\npm\\claude.cmd"});
    try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Roaming\\npm\\claude.cmd", npm.run(env).?);
}

test "claude_locate: PATH outranks the well-known locations" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var fs = fake(a.allocator(), &.{ "C:\\Users\\u\\.local\\bin\\claude.exe", "C:\\p\\claude.cmd" });
    const got = fs.run(.{ .path = "C:\\p", .userprofile = "C:\\Users\\u" });
    try testing.expectEqualStrings("C:\\p\\claude.cmd", got.?);
}

test "claude_locate: an empty USERPROFILE/APPDATA probes nothing at the drive root" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var fs = fake(a.allocator(), &.{"\\.local\\bin\\claude.exe"});
    try testing.expect(fs.run(.{ .userprofile = "", .appdata = " " }) == null);
    try testing.expectEqual(@as(usize, 0), fs.probes.items.len);
}

test "claude_locate: an empty override means no claude, even with one on PATH" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var fs = fake(a.allocator(), &.{"C:\\tools\\claude.exe"});
    try testing.expect(fs.run(.{ .override = "", .path = "C:\\tools" }) == null);
    try testing.expectEqual(@as(usize, 0), fs.probes.items.len);
}

test "claude_locate: a set override is the only answer - a missing stub never falls back to PATH" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var hit = fake(a.allocator(), &.{"T:\\stub\\claude.cmd"});
    try testing.expectEqualStrings(
        "T:\\stub\\claude.cmd",
        hit.run(.{ .override = "T:\\stub\\claude.cmd", .path = "C:\\tools" }).?,
    );

    var miss = fake(a.allocator(), &.{"C:\\tools\\claude.exe"});
    try testing.expect(miss.run(.{ .override = "T:\\gone.exe", .path = "C:\\tools" }) == null);
    try testing.expectEqual(@as(usize, 1), miss.probes.items.len);
}

test "claude_locate: nothing set at all is null without a probe" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var fs = fake(a.allocator(), &.{});
    try testing.expect(fs.run(.{}) == null);
    try testing.expectEqual(@as(usize, 0), fs.probes.items.len);
}
