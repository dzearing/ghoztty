//! Which family a pane's shell belongs to, and what folder a new pane may
//! inherit from its parent across families (T3754, split from T3735).
//!
//! Two families exist on Windows: the Windows shells (pwsh, powershell, cmd,
//! Git Bash, nu ...), whose folders are Windows paths, and WSL, whose folders
//! are Linux paths inside a distro. A folder only means something within its
//! own family, so a new pane inherits its parent's folder only when both are
//! the same family:
//!
//!   parent   child    inherits
//!   Windows  Windows  the parent's Windows folder
//!   WSL      WSL      the parent's Linux folder (its OSC 7 report) -> wsl --cd
//!   WSL      Windows  nothing: the child's own starting folder
//!   Windows  WSL      nothing: `~`, the distro's home
//!
//! Before this, a Windows split of a WSL pane took either the Windows folder
//! `wsl.exe` happened to be started in, or the WSL pane's OSC 7 report
//! (`/home/me/src`, which the core stores as `\home\me\src`) - a folder that
//! does not exist on the Windows side. A WSL split of a WSL pane always went
//! to `~`.
//!
//! Pure: no win32, no allocation beyond the one the caller hands in, so the
//! none lane tests every row.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Family = enum { windows, wsl };

/// The prefix that names one WSL distro as a shell: `wsl:Ubuntu`.
const wsl_spec_prefix = "wsl:";

/// The family of a program or shell spec: `wsl`, `wsl.exe`, a path ending in
/// `wsl.exe`, or `wsl:<distro>` is WSL; anything else is a Windows shell.
pub fn ofProgram(program: []const u8) Family {
    const p = std.mem.trim(u8, program, " \t\"");
    if (p.len > wsl_spec_prefix.len and std.ascii.startsWithIgnoreCase(p, wsl_spec_prefix)) return .wsl;
    var base = basename(p);
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    return if (std.ascii.eqlIgnoreCase(base, "wsl")) .wsl else .windows;
}

/// The family of a whole command line (`wsl.exe -d Ubuntu --cd ~`,
/// `"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo`): its first token's.
pub fn ofCommandLine(command: []const u8) Family {
    const c = std.mem.trimLeft(u8, command, " \t");
    if (c.len == 0) return .windows;
    if (c[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, c, 1, '"') orelse c.len;
        return ofProgram(c[1..end]);
    }
    const end = std.mem.indexOfAny(u8, c, " \t") orelse c.len;
    return ofProgram(c[0..end]);
}

/// Both separators, whatever the host: a Windows program path read on any
/// box still names its program.
fn basename(p: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, p, "/\\") orelse return p;
    return p[i + 1 ..];
}

/// Whether `path` is a Windows folder a Windows process can start in: a drive
/// path (`C:\src`, `C:/src`) or a UNC one (`\\server\share`) - never a device
/// path (`\\?\`, `\\.\`).
pub fn isWindowsPath(path: []const u8) bool {
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        (path[2] == '\\' or path[2] == '/')) return true;
    return path.len >= 3 and isSep(path[0]) and isSep(path[1]) and
        !isSep(path[2]) and path[2] != '?' and path[2] != '.';
}

/// Whether `path` is a Linux folder: `/home/me`, `~`, `~/src`, or the
/// backslashed form the core stores a WSL pane's OSC 7 report in on Windows
/// (`\home\me`). Never a drive or UNC path.
pub fn isLinuxPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (isWindowsPath(path)) return false;
    if (path[0] == '~') return path.len == 1 or path[1] == '/';
    // A lone root, or a rooted path that is not UNC (`\\server`).
    return isSep(path[0]) and (path.len == 1 or !isSep(path[1]));
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// `path` as a Linux path: separators flipped to `/`. Null when it is not a
/// Linux path at all. Owned by `alloc`.
pub fn toLinuxPath(alloc: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    if (!isLinuxPath(path)) return null;
    const out = try alloc.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

/// The folder a new `child`-family pane inherits from a `parent`-family pane
/// whose folder is `folder` (see the table at the top). The answer is a slice
/// of `folder` for a Windows child and a fresh `alloc` copy (separators
/// flipped) for a WSL one; null means "the child's own starting folder".
pub fn inherit(
    alloc: Allocator,
    parent: Family,
    child: Family,
    folder: ?[]const u8,
) Allocator.Error!?[]const u8 {
    const f = folder orelse return null;
    if (parent != child) return null;
    return switch (child) {
        .windows => if (isWindowsPath(f)) f else null,
        // `~` is the default already; only a real folder is worth passing.
        .wsl => if (isLinuxPath(f) and f[0] != '~') try toLinuxPath(alloc, f) else null,
    };
}

/// Why `folder` cannot be the starting folder of a `family` shell, or null
/// when it can. A Linux path names nothing on the Windows side, so asking a
/// Windows shell to start in one is refused rather than silently ignored.
pub fn folderProblem(family: Family, folder: []const u8) ?[]const u8 {
    return switch (family) {
        .windows => if (isLinuxPath(folder))
            "is a Linux path; only a WSL shell (--shell=wsl:<distro>) can start in one"
        else
            null,
        .wsl => null, // `wsl --cd` takes a Linux path or a Windows one.
    };
}

const testing = std.testing;

test "ofProgram: every WSL spelling is WSL, every other program is Windows" {
    for ([_][]const u8{ "wsl", "wsl.exe", "WSL.EXE", "C:\\Windows\\System32\\wsl.exe", "wsl:Ubuntu", "WSL:Debian", "\"wsl.exe\"" }) |p|
        try testing.expectEqual(Family.wsl, ofProgram(p));
    for ([_][]const u8{ "pwsh", "pwsh.exe", "cmd.exe", "C:\\Program Files\\Git\\bin\\bash.exe", "wsl:", "wslconfig.exe", "nu" }) |p|
        try testing.expectEqual(Family.windows, ofProgram(p));
}

test "ofCommandLine: reads the first token, quoted or not" {
    try testing.expectEqual(Family.wsl, ofCommandLine("wsl.exe -d Ubuntu --cd ~"));
    try testing.expectEqual(Family.wsl, ofCommandLine("  \"C:\\Windows\\System32\\wsl.exe\" --cd ~"));
    try testing.expectEqual(Family.windows, ofCommandLine("\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo"));
    try testing.expectEqual(Family.windows, ofCommandLine("cmd.exe /K echo wsl"));
    try testing.expectEqual(Family.windows, ofCommandLine(""));
}

test "isWindowsPath and isLinuxPath never both claim a path" {
    const cases = [_]struct { p: []const u8, win: bool, linux: bool }{
        .{ .p = "C:\\src", .win = true, .linux = false },
        .{ .p = "d:/git", .win = true, .linux = false },
        .{ .p = "\\\\server\\share", .win = true, .linux = false },
        .{ .p = "\\\\?\\C:\\x", .win = false, .linux = false },
        .{ .p = "\\\\.\\pipe\\x", .win = false, .linux = false },
        .{ .p = "/home/me/src", .win = false, .linux = true },
        .{ .p = "\\home\\me\\src", .win = false, .linux = true },
        .{ .p = "/", .win = false, .linux = true },
        .{ .p = "~", .win = false, .linux = true },
        .{ .p = "~/src", .win = false, .linux = true },
        .{ .p = "~user", .win = false, .linux = false },
        .{ .p = "src", .win = false, .linux = false },
        .{ .p = "", .win = false, .linux = false },
        .{ .p = "C:", .win = false, .linux = false },
    };
    for (cases) |c| {
        try testing.expectEqual(c.win, isWindowsPath(c.p));
        try testing.expectEqual(c.linux, isLinuxPath(c.p));
    }
}

test "inherit: a folder crosses only within its own family" {
    const a = testing.allocator;
    // Windows -> Windows keeps the folder.
    try testing.expectEqualStrings("C:\\src", (try inherit(a, .windows, .windows, "C:\\src")).?);
    // WSL -> WSL keeps the OSC 7 folder, as a Linux path.
    {
        const got = (try inherit(a, .wsl, .wsl, "\\home\\me\\src")).?;
        defer a.free(got);
        try testing.expectEqualStrings("/home/me/src", got);
    }
    // ...but not the Windows folder wsl.exe itself was started in.
    try testing.expectEqual(@as(?[]const u8, null), try inherit(a, .wsl, .wsl, "C:\\Users\\me"));
    // Across families: the child's own starting folder.
    try testing.expectEqual(@as(?[]const u8, null), try inherit(a, .wsl, .windows, "\\home\\me\\src"));
    try testing.expectEqual(@as(?[]const u8, null), try inherit(a, .wsl, .windows, "C:\\Users\\me"));
    try testing.expectEqual(@as(?[]const u8, null), try inherit(a, .windows, .wsl, "C:\\src"));
    // Nothing known, nothing inherited; `~` is the default already.
    try testing.expectEqual(@as(?[]const u8, null), try inherit(a, .windows, .windows, null));
    try testing.expectEqual(@as(?[]const u8, null), try inherit(a, .wsl, .wsl, "~"));
    // A Linux folder reported by a Windows-family pane (Git Bash's OSC 7 is
    // drive-shaped, so this is a stray) is not a Windows folder.
    try testing.expectEqual(@as(?[]const u8, null), try inherit(a, .windows, .windows, "\\home\\me"));
}

test "folderProblem: a Linux folder is refused for a Windows shell only" {
    try testing.expect(folderProblem(.windows, "/home/me") != null);
    try testing.expect(folderProblem(.windows, "~/src") != null);
    try testing.expect(folderProblem(.windows, "C:\\src") == null);
    try testing.expect(folderProblem(.wsl, "/home/me") == null);
    try testing.expect(folderProblem(.wsl, "C:\\src") == null);
}
