//! A starting folder per shell (T3770, split from T3754).
//!
//! `shell-working-directory = <shell>=<folder>` (repeatable) names the folder
//! a pane opened on `<shell>` starts in when nothing else gives it one - no
//! `--working-directory`, nothing inherited from a pane of the same shell
//! family (`shell_family.inherit`). `<shell>` is spelled the way `--shell`
//! takes it: `pwsh.exe`, `pwsh`, `C:\Program Files\PowerShell\7\pwsh.exe`,
//! `cmd`, `wsl:Ubuntu`, or a bare `wsl` (any distro without its own entry).
//!
//! The folder follows the shell's family: a WSL shell takes a Linux path
//! (`/srv/app`, `~`, `~/src`) - it rides `wsl.exe --cd` - and a Windows shell
//! a Windows path that exists. Before this, every Windows shell started in
//! the one global `working-directory` and every WSL shell in `~`.
//!
//! Matching is by program name (`pwsh` == `pwsh.exe` == a path ending in
//! `pwsh.exe`, case-insensitive), plus the distro for WSL. A later entry for
//! the same shell wins, as a later value does for every other key.
//!
//! Pure: no win32, no filesystem (the existence check is a callback), so the
//! none lane tests every rule.

const std = @import("std");
const Allocator = std.mem.Allocator;
const shell_family = @import("shell_family.zig");

pub const Family = shell_family.Family;

/// One `<shell>=<folder>` value, split at its first `=` (a folder may hold
/// one; a shell spec never does). Both halves trimmed. Null when either half
/// is empty or there is no `=`.
pub const Entry = struct {
    shell: []const u8,
    folder: []const u8,

    pub fn parse(raw: []const u8) ?Entry {
        const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return null;
        const shell = trimQuotes(std.mem.trim(u8, raw[0..eq], " \t"));
        const folder = trimQuotes(std.mem.trim(u8, raw[eq + 1 ..], " \t"));
        if (shell.len == 0 or folder.len == 0) return null;
        return .{ .shell = shell, .folder = folder };
    }
};

fn trimQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

/// Which shell a pane runs, for matching: its program's base name without
/// `.exe` (`pwsh`, `cmd`, `wsl`, `bash`) and, for WSL, the distro (`-d`).
pub const Identity = struct {
    program: []const u8,
    distro: ?[]const u8 = null,

    pub fn family(self: Identity) Family {
        return shell_family.ofProgram(self.program);
    }

    fn eql(a: Identity, b: Identity) bool {
        if (!std.ascii.eqlIgnoreCase(a.program, b.program)) return false;
        const ad = a.distro orelse return b.distro == null;
        const bd = b.distro orelse return false;
        return std.ascii.eqlIgnoreCase(ad, bd);
    }
};

fn programName(p: []const u8) []const u8 {
    const t = trimQuotes(std.mem.trim(u8, p, " \t"));
    const i = std.mem.lastIndexOfAny(u8, t, "/\\");
    var base = if (i) |n| t[n + 1 ..] else t;
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    return base;
}

/// The identity of a shell spec as `--shell` and this key take it.
pub fn ofSpec(spec: []const u8) Identity {
    const s = std.mem.trim(u8, spec, " \t");
    if (s.len > 4 and std.ascii.startsWithIgnoreCase(s, "wsl:")) {
        const d = std.mem.trim(u8, s[4..], " \t");
        if (d.len > 0) return .{ .program = "wsl", .distro = d };
    }
    return .{ .program = programName(s) };
}

/// The identity of a launch argv: `argv[0]`'s program, plus `-d` /
/// `--distribution <name>` for WSL.
pub fn ofArgv(argv: anytype) ?Identity {
    if (argv.len == 0) return null;
    const program = programName(argv[0]);
    if (program.len == 0) return null;
    var id: Identity = .{ .program = program };
    if (std.ascii.eqlIgnoreCase(program, "wsl")) {
        var i: usize = 1;
        while (i + 1 < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "-d") or std.mem.eql(u8, argv[i], "--distribution")) {
                id.distro = argv[i + 1];
                break;
            }
        }
    }
    return id;
}

/// Split a command line the way the Windows exec path splits a `.shell`
/// command (whitespace; a leading quoted program is kept whole).
pub fn splitCommandLine(alloc: Allocator, command: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var rest = std.mem.trim(u8, command, " \t");
    if (rest.len > 0 and rest[0] == '"') {
        if (std.mem.indexOfScalarPos(u8, rest, 1, '"')) |end| {
            try out.append(alloc, rest[1..end]);
            rest = rest[end + 1 ..];
        }
    }
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    while (it.next()) |tok| try out.append(alloc, tok);
    return out.toOwnedSlice(alloc);
}

/// The folder configured for `id` among `values` (raw `<shell>=<folder>`
/// strings, file order), or null. An exact entry wins over a bare `wsl` one
/// for a distro; among equals the last wins.
pub fn find(values: anytype, id: Identity) ?[]const u8 {
    var exact: ?[]const u8 = null;
    var any_wsl: ?[]const u8 = null;
    for (values) |raw| {
        const e = Entry.parse(raw) orelse continue;
        const want = ofSpec(e.shell);
        if (want.eql(id)) {
            exact = e.folder;
        } else if (id.distro != null and want.distro == null and
            std.ascii.eqlIgnoreCase(want.program, "wsl") and
            std.ascii.eqlIgnoreCase(id.program, "wsl"))
        {
            any_wsl = e.folder;
        }
    }
    return exact orelse any_wsl;
}

/// Why `folder` cannot be a `family` shell's starting folder, or null. A WSL
/// folder is a Linux path (`/...`, `~`, `~/...`); a Windows folder is a drive
/// or UNC path that `exists` (the caller's filesystem check).
pub fn folderProblem(
    family: Family,
    folder: []const u8,
    ctx: anytype,
    comptime exists: fn (@TypeOf(ctx), []const u8) bool,
) ?[]const u8 {
    const f = std.mem.trim(u8, folder, " \t");
    if (f.len == 0) return "Enter a folder.";
    return switch (family) {
        .wsl => if (f[0] == '/' or (f[0] == '~' and (f.len == 1 or f[1] == '/')))
            null
        else
            "A WSL shell starts in a Linux folder: /path, ~ or ~/path.",
        .windows => if (!shell_family.isWindowsPath(f))
            "A Windows shell starts in a full Windows folder, like C:\\src."
        else if (!exists(ctx, f))
            "That folder doesn't exist."
        else
            null,
    };
}

/// Why `raw` cannot be a `shell-working-directory` value, or null: the
/// `<shell>=<folder>` shape, then the folder for that shell's family.
pub fn valueProblem(
    raw: []const u8,
    ctx: anytype,
    comptime exists: fn (@TypeOf(ctx), []const u8) bool,
) ?[]const u8 {
    const e = Entry.parse(raw) orelse
        return "Write it as shell=folder, like wsl:Ubuntu=~/src or pwsh.exe=C:\\src.";
    return folderProblem(ofSpec(e.shell).family(), e.folder, ctx, exists);
}

/// `argv` with a WSL `--cd ~` (the default home, T3749) replaced by
/// `folder`, or null when the argv already names another folder or has no
/// `--cd` to replace. Allocated in `alloc` (an arena in every caller).
pub fn withWslFolder(
    alloc: Allocator,
    argv: anytype,
    folder: []const u8,
) Allocator.Error!?[]const [:0]const u8 {
    var at: ?usize = null;
    for (argv, 0..) |a, i| if (std.mem.eql(u8, a, "--cd") and i + 1 < argv.len) {
        at = i + 1;
    };
    const i = at orelse return null;
    if (!std.mem.eql(u8, argv[i], "~")) return null;
    const out = try alloc.alloc([:0]const u8, argv.len);
    for (argv, 0..) |a, n| out[n] = try alloc.dupeZ(u8, if (n == i) folder else a);
    return out;
}

/// `argv` starting in `folder` (T3772): a WSL shell's default `--cd ~`
/// replaced the way `withWslFolder` does, or, for an interactive `wsl.exe`
/// that names no folder at all (`wsl.exe`, `wsl.exe -d Ubuntu`), `--cd
/// <folder>` appended. Null when the argv already names another folder, or
/// runs a command - any word that is not one of wsl.exe's own options starts
/// the command line, and a `--cd` after it would be that command's argument.
pub fn withWslStartFolder(
    alloc: Allocator,
    argv: anytype,
    folder: []const u8,
) Allocator.Error!?[]const [:0]const u8 {
    if (try withWslFolder(alloc, argv, folder)) |out| return out;
    if (argv.len == 0) return null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a: []const u8 = argv[i];
        const takes_value = for ([_][]const u8{ "-d", "--distribution", "-u", "--user", "--shell-type" }) |o| {
            if (std.mem.eql(u8, a, o)) break true;
        } else false;
        if (takes_value) {
            if (i + 1 >= argv.len) return null;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--system")) continue;
        // `--cd` (already a folder), `-e`/`--exec`/`--` (a command) or a
        // command word: not ours to add to.
        return null;
    }
    const out = try alloc.alloc([:0]const u8, argv.len + 2);
    for (argv, 0..) |a, n| out[n] = try alloc.dupeZ(u8, a);
    out[argv.len] = try alloc.dupeZ(u8, "--cd");
    out[argv.len + 1] = try alloc.dupeZ(u8, folder);
    return out;
}

/// `argv` back as the whitespace-split command line `splitCommandLine`
/// reads: the program quoted when it holds a space. Null when any later word
/// holds whitespace - that line would split it in two.
pub fn joinCommandLine(alloc: Allocator, argv: []const [:0]const u8) Allocator.Error!?[:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |a, i| {
        const spaced = std.mem.indexOfAny(u8, a, " \t") != null;
        if (i > 0) try out.append(alloc, ' ');
        if (spaced) {
            if (i > 0) return null;
            try out.append(alloc, '"');
            try out.appendSlice(alloc, a);
            try out.append(alloc, '"');
        } else try out.appendSlice(alloc, a);
    }
    return try out.toOwnedSliceSentinel(alloc, 0);
}

test "joinCommandLine round-trips through splitCommandLine" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const line = (try joinCommandLine(arena, &.{ "C:\\Program Files\\x\\wsl.exe", "-d", "Ubuntu", "--cd", "/srv" })).?;
    try std.testing.expectEqualStrings("\"C:\\Program Files\\x\\wsl.exe\" -d Ubuntu --cd /srv", line);
    const back = try splitCommandLine(arena, line);
    try std.testing.expectEqual(@as(usize, 5), back.len);
    try std.testing.expectEqualStrings("C:\\Program Files\\x\\wsl.exe", back[0]);
    try std.testing.expect((try joinCommandLine(arena, &.{ "wsl.exe", "--cd", "/my src" })) == null);
}

const testing = std.testing;
const A = []const []const u8;

const Fake = struct {
    fn yes(_: void, _: []const u8) bool {
        return true;
    }
    fn no(_: void, _: []const u8) bool {
        return false;
    }
};

test "Entry.parse splits at the first =, trims, and refuses a half" {
    const e = Entry.parse(" wsl:Ubuntu = ~/src ").?;
    try testing.expectEqualStrings("wsl:Ubuntu", e.shell);
    try testing.expectEqualStrings("~/src", e.folder);
    const q = Entry.parse("\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\"=C:\\a=b").?;
    try testing.expectEqualStrings("C:\\Program Files\\PowerShell\\7\\pwsh.exe", q.shell);
    try testing.expectEqualStrings("C:\\a=b", q.folder);
    try testing.expect(Entry.parse("pwsh.exe") == null);
    try testing.expect(Entry.parse("=C:\\src") == null);
    try testing.expect(Entry.parse("pwsh=") == null);
}

test "ofSpec / ofArgv name the same shell however it is spelled" {
    const pw = ofSpec("pwsh.exe");
    try testing.expect(pw.eql(ofSpec("PWSH")));
    try testing.expect(pw.eql(ofSpec("C:\\Program Files\\PowerShell\\7\\pwsh.exe")));
    try testing.expect(pw.eql(ofArgv(@as(A, &.{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo" })).?));
    const ub = ofSpec("wsl:Ubuntu");
    try testing.expect(ub.eql(ofArgv(@as(A, &.{ "wsl.exe", "-d", "ubuntu", "--cd", "~" })).?));
    try testing.expect(ub.eql(ofArgv(@as(A, &.{ "C:\\Windows\\System32\\wsl.exe", "--distribution", "Ubuntu" })).?));
    try testing.expect(!ub.eql(ofArgv(@as(A, &.{ "wsl.exe", "--cd", "~" })).?));
    try testing.expect(ofSpec("wsl").eql(ofArgv(@as(A, &.{ "wsl.exe", "--cd", "~" })).?));
    try testing.expect(!pw.eql(ofSpec("powershell.exe")));
    try testing.expectEqual(Family.wsl, ub.family());
    try testing.expectEqual(Family.windows, pw.family());
    try testing.expect(ofArgv(@as(A, &.{})) == null);
}

test "splitCommandLine keeps a quoted program whole" {
    const a = testing.allocator;
    const got = try splitCommandLine(a, "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo");
    defer a.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("C:\\Program Files\\PowerShell\\7\\pwsh.exe", got[0]);
    const w = try splitCommandLine(a, "  wsl.exe -d Ubuntu  --cd ~ ");
    defer a.free(w);
    try testing.expectEqual(@as(usize, 5), w.len);
    try testing.expect(ofSpec("wsl:Ubuntu").eql(ofArgv(w).?));
}

test "find: exact entry, then a bare wsl entry for a distro, last wins" {
    const values = [_][]const u8{
        "pwsh.exe=C:\\one",
        "wsl=~/any",
        "garbage",
        "PWSH=C:\\two",
        "wsl:Ubuntu=/srv/app",
    };
    try testing.expectEqualStrings("C:\\two", find(&values, ofSpec("pwsh")).?);
    try testing.expectEqualStrings("/srv/app", find(&values, ofSpec("wsl:ubuntu")).?);
    try testing.expectEqualStrings("~/any", find(&values, ofSpec("wsl:Debian")).?);
    try testing.expectEqualStrings("~/any", find(&values, ofArgv(@as(A, &.{ "wsl.exe", "--cd", "~" })).?).?);
    try testing.expect(find(&values, ofSpec("cmd.exe")) == null);
    try testing.expect(find(@as(A, &.{}), ofSpec("pwsh")) == null);
}

test "folderProblem: WSL takes a Linux folder, Windows an existing Windows one" {
    try testing.expect(folderProblem(.wsl, "~", {}, Fake.no) == null);
    try testing.expect(folderProblem(.wsl, "~/src", {}, Fake.no) == null);
    try testing.expect(folderProblem(.wsl, "/srv/app", {}, Fake.no) == null);
    try testing.expect(folderProblem(.wsl, "C:\\src", {}, Fake.yes) != null);
    try testing.expect(folderProblem(.wsl, "~user", {}, Fake.yes) != null);
    try testing.expect(folderProblem(.wsl, "src", {}, Fake.yes) != null);
    try testing.expect(folderProblem(.windows, "C:\\src", {}, Fake.yes) == null);
    try testing.expect(folderProblem(.windows, "\\\\server\\share", {}, Fake.yes) == null);
    try testing.expect(folderProblem(.windows, "C:\\nope", {}, Fake.no) != null);
    try testing.expect(folderProblem(.windows, "/home/me", {}, Fake.yes) != null);
    try testing.expect(folderProblem(.windows, "~", {}, Fake.yes) != null);
    try testing.expect(folderProblem(.windows, "  ", {}, Fake.yes) != null);
}

test "valueProblem checks the shape, then the folder for the shell's family" {
    try testing.expect(valueProblem("wsl:Ubuntu=~/src", {}, Fake.no) == null);
    try testing.expect(valueProblem("pwsh.exe=C:\\src", {}, Fake.yes) == null);
    try testing.expect(valueProblem("pwsh.exe=~/src", {}, Fake.yes) != null);
    try testing.expect(valueProblem("wsl:Ubuntu=C:\\src", {}, Fake.yes) != null);
    try testing.expect(valueProblem("~/src", {}, Fake.yes) != null);
}

test "withWslFolder replaces only the default ~" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = (try withWslFolder(arena, @as(A, &.{ "wsl.exe", "-d", "Ubuntu", "--cd", "~" }), "/srv/app")).?;
    try testing.expectEqual(@as(usize, 5), got.len);
    try testing.expectEqualStrings("/srv/app", got[4]);
    try testing.expectEqualStrings("Ubuntu", got[2]);
    try testing.expect((try withWslFolder(arena, @as(A, &.{ "wsl.exe", "--cd", "/home/me/src" }), "/srv")) == null);
    try testing.expect((try withWslFolder(arena, @as(A, &.{"wsl.exe"}), "/srv")) == null);
    try testing.expect((try withWslFolder(arena, @as(A, &.{ "wsl.exe", "--cd" }), "/srv")) == null);
}

test "T3772 withWslStartFolder: replaces ~, appends to a folderless shell, leaves a command alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const home = (try withWslStartFolder(arena, @as(A, &.{ "wsl.exe", "-d", "Ubuntu", "--cd", "~" }), "/srv/app")).?;
    try testing.expectEqual(@as(usize, 5), home.len);
    try testing.expectEqualStrings("/srv/app", home[4]);

    const bare = (try withWslStartFolder(arena, @as(A, &.{"wsl.exe"}), "/srv")).?;
    try testing.expectEqual(@as(usize, 3), bare.len);
    try testing.expectEqualStrings("--cd", bare[1]);
    try testing.expectEqualStrings("/srv", bare[2]);

    const distro = (try withWslStartFolder(arena, @as(A, &.{ "wsl.exe", "-d", "Debian", "-u", "me", "--system" }), "/srv")).?;
    try testing.expectEqual(@as(usize, 8), distro.len);
    try testing.expectEqualStrings("Debian", distro[2]);
    try testing.expectEqualStrings("--cd", distro[6]);
    try testing.expectEqualStrings("/srv", distro[7]);

    // Already somewhere else, a command, or a dangling option: untouched.
    try testing.expect((try withWslStartFolder(arena, @as(A, &.{ "wsl.exe", "--cd", "/home/me" }), "/srv")) == null);
    try testing.expect((try withWslStartFolder(arena, @as(A, &.{ "wsl.exe", "-e", "htop" }), "/srv")) == null);
    try testing.expect((try withWslStartFolder(arena, @as(A, &.{ "wsl.exe", "--", "ls" }), "/srv")) == null);
    try testing.expect((try withWslStartFolder(arena, @as(A, &.{ "wsl.exe", "ls", "-l" }), "/srv")) == null);
    try testing.expect((try withWslStartFolder(arena, @as(A, &.{ "wsl.exe", "-d" }), "/srv")) == null);
    try testing.expect((try withWslStartFolder(arena, @as(A, &.{}), "/srv")) == null);
}
