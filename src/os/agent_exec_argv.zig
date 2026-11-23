//! The argv a WINDOWS local session-persistence agent is sent for an `-e`
//! command whose words would not survive being joined into one string (T3402).
//!
//! The agent runs a forwarded `OPEN.command` as `cmd /c <string>`, and the
//! string has always been the words joined with plain spaces. That is lossless
//! for words with nothing to quote, and it is what makes `-e claude` (an npm
//! `.cmd` shim, found through PATHEXT) and `-e echo hi` (a cmd builtin) work.
//! But a word holding a space - `C:\Program Files\...`, a pwsh script block,
//! one argument meant as one - arrives as several.
//!
//! `OPEN.argv` is exec'd verbatim instead, and CreateProcess's quoting
//! (`CommandCore.windowsCreateCommandLine`) carries every word intact. It
//! loses cmd's program search, though: CreateProcess appends only `.exe`, and
//! a builtin is not a file at all. So the argv route is taken ONLY when it is
//! both needed and safe:
//!
//!   - some word needs quoting (empty, or holds a space, tab or `"`) - with
//!     none, the joined string is exactly the argv and nothing changes;
//!   - and the program resolves to a FILE the way cmd would find it (PATH x
//!     PATHEXT, or the path as written). The resolved absolute path goes in
//!     argv[0], which is also what lets a `.cmd`/`.bat` run: CreateProcess
//!     runs a batch file given its full path.
//!
//! Anything else keeps today's string, so no command that works now changes.
//! The agent is THIS machine, which is the only reason resolving here is
//! right; a cross-machine agent never gets an argv from this.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Whether joining `argv` with spaces would lose a word boundary.
pub fn needsQuoting(argv: []const []const u8) bool {
    for (argv) |w| {
        if (w.len == 0) return true;
        if (std.mem.indexOfAny(u8, w, " \t\"") != null) return true;
    }
    return false;
}

/// The `PATHEXT` cmd falls back to when the variable is unset or empty.
pub const default_pathext = ".COM;.EXE;.BAT;.CMD";

/// Where cmd would find `program`, as an absolute (or as-written) path the
/// caller owns, or null when it names no file. `exists` answers "is this a
/// file?" so the search is testable without touching the disk.
///
/// A name with a directory in it is looked up where it says; a bare name is
/// looked up in each `path_env` directory in order. A name that already has an
/// extension is tried as is; one without is tried with each `pathext` entry.
pub fn resolveProgram(
    alloc: Allocator,
    program: []const u8,
    path_env: []const u8,
    pathext_env: []const u8,
    exists: *const fn ([]const u8) bool,
) Allocator.Error!?[]u8 {
    if (program.len == 0) return null;
    const pathext = if (std.mem.trim(u8, pathext_env, " ;").len == 0)
        default_pathext
    else
        pathext_env;

    const base_start = if (std.mem.lastIndexOfAny(u8, program, "\\/:")) |i| i + 1 else 0;
    const has_dir = base_start != 0;
    const has_ext = std.mem.indexOfScalar(u8, program[base_start..], '.') != null;

    if (has_dir) return try tryCandidates(alloc, "", program, has_ext, pathext, exists);

    var dirs = std.mem.tokenizeScalar(u8, path_env, ';');
    while (dirs.next()) |raw| {
        const dir = std.mem.trim(u8, raw, " \"");
        if (dir.len == 0) continue;
        if (try tryCandidates(alloc, dir, program, has_ext, pathext, exists)) |p| return p;
    }
    return null;
}

fn tryCandidates(
    alloc: Allocator,
    dir: []const u8,
    program: []const u8,
    has_ext: bool,
    pathext: []const u8,
    exists: *const fn ([]const u8) bool,
) Allocator.Error!?[]u8 {
    const sep: []const u8 = if (dir.len == 0 or dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/')
        ""
    else
        "\\";
    if (has_ext) {
        const p = try std.mem.concat(alloc, u8, &.{ dir, sep, program });
        if (exists(p)) return p;
        alloc.free(p);
        return null;
    }
    var exts = std.mem.tokenizeScalar(u8, pathext, ';');
    while (exts.next()) |ext| {
        const p = try std.mem.concat(alloc, u8, &.{ dir, sep, program, ext });
        if (exists(p)) return p;
        alloc.free(p);
    }
    return null;
}

fn isFile(p: []const u8) bool {
    const st = std.fs.cwd().statFile(p) catch return false;
    return st.kind != .directory;
}

/// The argv to send the local agent for `.direct` words, or null to keep the
/// joined `OPEN.command` (see the file comment for when). Every element is
/// owned by `alloc`; free with `freeArgv`.
pub fn agentExecArgv(
    alloc: Allocator,
    argv: []const []const u8,
) Allocator.Error!?[]const []const u8 {
    if (comptime builtin.os.tag != .windows) return null;
    if (argv.len == 0 or !needsQuoting(argv)) return null;

    const path_env = std.process.getEnvVarOwned(alloc, "PATH") catch null;
    defer if (path_env) |p| alloc.free(p);
    const pathext_env = std.process.getEnvVarOwned(alloc, "PATHEXT") catch null;
    defer if (pathext_env) |p| alloc.free(p);

    return try buildArgv(alloc, argv, path_env orelse "", pathext_env orelse "", &isFile);
}

/// `agentExecArgv` past its platform and environment reads, for tests.
fn buildArgv(
    alloc: Allocator,
    argv: []const []const u8,
    path_env: []const u8,
    pathext_env: []const u8,
    exists: *const fn ([]const u8) bool,
) Allocator.Error!?[]const []const u8 {
    if (argv.len == 0 or !needsQuoting(argv)) return null;
    const program = (try resolveProgram(alloc, argv[0], path_env, pathext_env, exists)) orelse
        return null;
    errdefer alloc.free(program);

    const out = try alloc.alloc([]const u8, argv.len);
    var filled: usize = 1;
    errdefer {
        for (out[1..filled]) |w| alloc.free(w);
        alloc.free(out);
    }
    out[0] = program;
    for (argv[1..], 1..) |w, i| {
        out[i] = try alloc.dupe(u8, w);
        filled = i + 1;
    }
    return out;
}

pub fn freeArgv(alloc: Allocator, argv: []const []const u8) void {
    for (argv) |w| alloc.free(w);
    alloc.free(argv);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// The stub file system: exactly these paths exist.
fn stubExists(p: []const u8) bool {
    const files = [_][]const u8{
        "C:\\Program Files\\nodejs\\claude.CMD",
        "C:\\Windows\\System32\\cmd.exe",
        "C:\\tools\\prog.exe",
        "C:\\a b\\x.ps1",
        "C:\\a b\\run.bat",
    };
    for (files) |f| if (std.ascii.eqlIgnoreCase(f, p)) return true;
    return false;
}

const stub_path = "C:\\Windows\\System32;;C:\\Program Files\\nodejs\\;\"C:\\tools\"";

test "needsQuoting: only words a plain join would lose" {
    try testing.expect(!needsQuoting(&.{ "claude", "--resume" }));
    try testing.expect(!needsQuoting(&.{ "cmd", "/c", "echo", "a&b" }));
    try testing.expect(needsQuoting(&.{ "prog", "two words" }));
    try testing.expect(needsQuoting(&.{ "prog", "" }));
    try testing.expect(needsQuoting(&.{ "prog", "a\"b" }));
    try testing.expect(needsQuoting(&.{ "prog", "tab\there" }));
}

test "resolveProgram: PATH x PATHEXT, in order, with dirs as written" {
    const alloc = testing.allocator;
    const claude = (try resolveProgram(alloc, "claude", stub_path, ".COM;.EXE;.BAT;.CMD", &stubExists)).?;
    defer alloc.free(claude);
    try testing.expectEqualStrings("C:\\Program Files\\nodejs\\claude.CMD", claude);

    // A quoted PATH entry is unquoted; an explicit extension is tried as is.
    const prog = (try resolveProgram(alloc, "prog.exe", stub_path, "", &stubExists)).?;
    defer alloc.free(prog);
    try testing.expectEqualStrings("C:\\tools\\prog.exe", prog);

    // Empty PATHEXT falls back to cmd's default.
    const cmd = (try resolveProgram(alloc, "cmd", stub_path, "", &stubExists)).?;
    defer alloc.free(cmd);
    try testing.expectEqualStrings("C:\\Windows\\System32\\cmd.EXE", cmd);

    // A builtin is not a file.
    try testing.expect((try resolveProgram(alloc, "echo", stub_path, "", &stubExists)) == null);
}

test "resolveProgram: a path with a directory is looked up where it says" {
    const alloc = testing.allocator;
    const bat = (try resolveProgram(alloc, "C:\\a b\\run", stub_path, "", &stubExists)).?;
    defer alloc.free(bat);
    // The candidate is spelled with the PATHEXT entry's case; Windows paths
    // are case-insensitive, and so is the stub.
    try testing.expectEqualStrings("C:\\a b\\run.BAT", bat);
    try testing.expect((try resolveProgram(alloc, "C:\\nowhere\\prog", stub_path, "", &stubExists)) == null);
}

test "buildArgv: spaced words take the argv route with a resolved program" {
    const alloc = testing.allocator;
    const got = (try buildArgv(alloc, &.{ "claude", "fix the bug" }, stub_path, "", &stubExists)).?;
    defer freeArgv(alloc, got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("C:\\Program Files\\nodejs\\claude.CMD", got[0]);
    try testing.expectEqualStrings("fix the bug", got[1]);
}

test "buildArgv: nothing to quote, or no file to run, keeps the joined string" {
    const alloc = testing.allocator;
    // Nothing to quote: today's join is already exact.
    try testing.expect((try buildArgv(alloc, &.{ "claude", "--resume" }, stub_path, "", &stubExists)) == null);
    // A builtin with a spaced word: only cmd can run it, so the string stays.
    try testing.expect((try buildArgv(alloc, &.{ "echo", "a b" }, stub_path, "", &stubExists)) == null);
    try testing.expect((try buildArgv(alloc, &.{}, stub_path, "", &stubExists)) == null);
}

test "buildArgv: leaks nothing when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(alloc: Allocator) !void {
            const got = try buildArgv(alloc, &.{ "claude", "a b", "c" }, stub_path, "", &stubExists);
            if (got) |a| freeArgv(alloc, a);
        }
    }.f, .{});
}
