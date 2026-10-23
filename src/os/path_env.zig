//! Pure logic for Windows `;`-separated PATH values: deciding whether a
//! directory is already on one and building the appended value when it is
//! not. No OS imports, so the unit tests run in every app-runtime lane (the
//! hero_math/dim_math pattern).
//!
//! Two callers share it, which is why it lives in `src/os` rather than under
//! an apprt (T42): the GUI's user-PATH self-heal (T70,
//! `apprt/win32/PathInstaller.zig`, which owns the registry write) and the
//! agent's user-environment overlay (`os/user_env.zig`, which owns the
//! registry read). A second copy of `normalize`/`eqlDir` is exactly the
//! four-copies-four-chances-to-be-wrong trap T257 wrote down.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Normalize a single PATH entry for comparison: trim whitespace, strip one
/// pair of surrounding double quotes (cmd.exe accepts quoted entries), and
/// strip trailing path separators — except the one in a bare drive root
/// ("C:\"), which is meaningful. Returns a slice into `entry`.
pub fn normalize(entry: []const u8) []const u8 {
    var s = std.mem.trim(u8, entry, " \t");
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"')
        s = std.mem.trim(u8, s[1 .. s.len - 1], " \t");
    while (s.len > 0 and (s[s.len - 1] == '\\' or s[s.len - 1] == '/')) {
        // Keep the separator of a drive root: "C:\" != "C:" (the latter
        // means "current directory on C:").
        if (s.len == 3 and s[1] == ':') break;
        s = s[0 .. s.len - 1];
    }
    return s;
}

/// Whether two directory paths refer to the same PATH entry after
/// normalization. Case-insensitive (ASCII), like Windows path resolution.
pub fn eqlDir(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(normalize(a), normalize(b));
}

/// Whether the `;`-separated PATH value already contains `dir`. Empty
/// segments (";;") are skipped. Callers wanting `%VAR%`-aware matching
/// expand the value first and call this on both raw and expanded forms.
pub fn contains(path_value: []const u8, dir: []const u8) bool {
    var it = std.mem.splitScalar(u8, path_value, ';');
    while (it.next()) |entry| {
        if (normalize(entry).len == 0) continue;
        if (eqlDir(entry, dir)) return true;
    }
    return false;
}

/// Build the PATH value with `dir` appended. The caller owns the result.
pub fn append(alloc: Allocator, path_value: []const u8, dir: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, path_value, " \t");
    if (trimmed.len == 0) return alloc.dupe(u8, dir);
    const sep: []const u8 = if (trimmed[trimmed.len - 1] == ';') "" else ";";
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ trimmed, sep, dir });
}

/// What a launch asks of the user PATH when the entry it writes is a single
/// OWNED value rather than an append (T2169). Every copy of Ghoztty that heals
/// the PATH would otherwise leave an entry nothing removes, and the earliest
/// one keeps winning, so a copy launched later would not even get the CLI.
pub const Repoint = struct {
    /// The directory this launch runs from: the entry to own.
    dir: []const u8,
    /// The entry an earlier launch recorded as owned, if any. Dropped unless
    /// it is `dir` or `install_dir`.
    previous: ?[]const u8 = null,
    /// The installed release's directory, whose entry the MSI owns: never
    /// removed, and an owned entry for any other copy is placed AHEAD of it so
    /// the copy launched last is the one `ghoztty` resolves to. Empty when
    /// unknown.
    install_dir: []const u8 = "",
};

/// The user PATH value after this launch takes ownership of its entry, or
/// null when `path_value` already says what it should. The caller owns the
/// result.
///
/// `expander.expand(entry)` returns the `%VAR%`-expanded form of one entry
/// (the entry itself when there is nothing to expand), so an entry written as
/// `%LOCALAPPDATA%\...` is matched like the literal path. Every segment that
/// is not dropped keeps its exact bytes, and a plain append is `append`'s
/// shape, so a PATH this launch has nothing to say about is never rewritten.
pub fn repoint(
    alloc: Allocator,
    path_value: []const u8,
    r: Repoint,
    expander: anytype,
) Allocator.Error!?[]u8 {
    const is_install = r.install_dir.len > 0 and eqlDir(r.dir, r.install_dir);

    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(alloc);
    var dir_idx: ?usize = null;
    var install_idx: ?usize = null;
    var dropped = false;

    var it = std.mem.splitScalar(u8, path_value, ';');
    while (it.next()) |entry| {
        if (normalize(entry).len == 0) {
            try kept.append(alloc, entry);
            continue;
        }
        const expanded = expander.expand(entry);
        const m_dir = eqlDir(entry, r.dir) or eqlDir(expanded, r.dir);
        const m_install = r.install_dir.len > 0 and
            (eqlDir(entry, r.install_dir) or eqlDir(expanded, r.install_dir));
        if (r.previous) |prev| {
            if (!m_dir and !m_install and (eqlDir(entry, prev) or eqlDir(expanded, prev))) {
                dropped = true;
                continue;
            }
        }
        if (m_dir and dir_idx == null) dir_idx = kept.items.len;
        if (m_install and install_idx == null) install_idx = kept.items.len;
        try kept.append(alloc, entry);
    }

    if (dir_idx) |di| {
        // Present. A copy other than the install must sit ahead of the
        // install's entry, or the install keeps answering `ghoztty`.
        if (!is_install) if (install_idx) |ii| if (di > ii) {
            const entry = kept.orderedRemove(di);
            try kept.insert(alloc, ii, entry);
            return try join(alloc, kept.items);
        };
        if (!dropped) return null;
        return try join(alloc, kept.items);
    }

    if (!is_install) if (install_idx) |ii| {
        try kept.insert(alloc, ii, r.dir);
        return try join(alloc, kept.items);
    };
    if (!dropped) return try append(alloc, path_value, r.dir);
    const rest = try join(alloc, kept.items);
    defer alloc.free(rest);
    return try append(alloc, rest, r.dir);
}

fn join(alloc: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    return std.mem.join(alloc, ";", parts);
}

/// An expander for callers (and tests) whose PATH holds no `%VAR%` forms.
pub const no_expansion = struct {
    pub fn expand(_: @This(), entry: []const u8) []const u8 {
        return entry;
    }
}{};

test "normalize: quotes, trailing separators, drive root" {
    const testing = std.testing;
    try testing.expectEqualStrings("C:\\x\\bin", normalize("C:\\x\\bin\\"));
    try testing.expectEqualStrings("C:\\x\\bin", normalize(" \"C:\\x\\bin\\\" "));
    try testing.expectEqualStrings("C:\\x", normalize("C:\\x\\\\"));
    try testing.expectEqualStrings("C:\\", normalize("C:\\"));
    try testing.expectEqualStrings("", normalize("  "));
    try testing.expectEqualStrings("%LOCALAPPDATA%\\Programs", normalize("%LOCALAPPDATA%\\Programs\\"));
}

test "eqlDir: case and trailing-separator insensitive" {
    const testing = std.testing;
    try testing.expect(eqlDir("C:\\Users\\D\\bin", "c:\\users\\d\\BIN\\"));
    try testing.expect(eqlDir("\"C:\\a b\\bin\"", "C:\\a b\\bin"));
    try testing.expect(!eqlDir("C:\\a\\bin", "C:\\a\\bin2"));
    try testing.expect(!eqlDir("C:\\", "C:"));
}

test "contains: finds entries in any accepted form" {
    const testing = std.testing;
    const dir = "C:\\Users\\D\\AppData\\Local\\Programs\\Ghoztty";
    try testing.expect(contains("C:\\w;" ++ dir ++ ";C:\\x", dir));
    try testing.expect(contains(dir ++ "\\", dir));
    try testing.expect(contains("\"" ++ dir ++ "\\\";C:\\x", dir));
    try testing.expect(contains("c:\\users\\d\\appdata\\local\\programs\\ghoztty", dir));
    try testing.expect(!contains("", dir));
    try testing.expect(!contains(";;", dir));
    try testing.expect(!contains("C:\\w;C:\\x", dir));
    // Prefix is not membership.
    try testing.expect(!contains(dir ++ "2", dir));
}

test "append: empty, trailing semicolon, normal" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const a = try append(alloc, "", "C:\\g");
    defer alloc.free(a);
    try testing.expectEqualStrings("C:\\g", a);

    const b = try append(alloc, "C:\\x;", "C:\\g");
    defer alloc.free(b);
    try testing.expectEqualStrings("C:\\x;C:\\g", b);

    const c = try append(alloc, "C:\\x", "C:\\g");
    defer alloc.free(c);
    try testing.expectEqualStrings("C:\\x;C:\\g", c);
}

fn expectRepoint(expected: ?[]const u8, path_value: []const u8, r: Repoint) !void {
    const testing = std.testing;
    const got = try repoint(testing.allocator, path_value, r, no_expansion);
    defer if (got) |g| testing.allocator.free(g);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(e, got.?);
    } else {
        try testing.expect(got == null);
    }
}

const t_install = "C:\\Users\\D\\AppData\\Local\\Programs\\Ghoztty";
const t_portable = "D:\\Desktop\\Ghoztty-portable\\Ghoztty";
const t_share = "\\\\nas\\share\\Ghoztty";

test "repoint: the install launch appends when absent and is idempotent" {
    try expectRepoint("C:\\x;" ++ t_install, "C:\\x", .{ .dir = t_install, .install_dir = t_install });
    try expectRepoint(null, "C:\\x;" ++ t_install, .{ .dir = t_install, .install_dir = t_install });
}

test "repoint: a portable launch is placed ahead of the install entry" {
    try expectRepoint(
        "C:\\x;" ++ t_portable ++ ";" ++ t_install ++ ";C:\\y",
        "C:\\x;" ++ t_install ++ ";C:\\y",
        .{ .dir = t_portable, .install_dir = t_install },
    );
    // Already there, and already ahead: nothing to write.
    try expectRepoint(
        null,
        t_portable ++ ";" ++ t_install,
        .{ .dir = t_portable, .previous = t_portable, .install_dir = t_install },
    );
    // Present but behind the install: moved, not duplicated.
    try expectRepoint(
        t_portable ++ ";" ++ t_install ++ ";C:\\x",
        t_install ++ ";C:\\x;" ++ t_portable,
        .{ .dir = t_portable, .install_dir = t_install },
    );
}

test "repoint: a portable launch with no install entry appends" {
    try expectRepoint("C:\\x;" ++ t_portable, "C:\\x", .{ .dir = t_portable, .install_dir = t_install });
    try expectRepoint(t_portable, "", .{ .dir = t_portable });
}

test "repoint: the last launch replaces the previous owned entry" {
    try expectRepoint(
        "C:\\x;" ++ t_share ++ ";" ++ t_install,
        "C:\\x;" ++ t_portable ++ ";" ++ t_install,
        .{ .dir = t_share, .previous = t_portable, .install_dir = t_install },
    );
    // No install entry: the old one goes, the new one is appended.
    try expectRepoint(
        "C:\\x;C:\\y;" ++ t_share,
        "C:\\x;" ++ t_portable ++ ";C:\\y",
        .{ .dir = t_share, .previous = t_portable, .install_dir = t_install },
    );
}

test "repoint: the install launch takes the command back from a portable" {
    try expectRepoint(
        "C:\\x;" ++ t_install,
        "C:\\x;" ++ t_portable ++ ";" ++ t_install,
        .{ .dir = t_install, .previous = t_portable, .install_dir = t_install },
    );
}

test "repoint: the install entry is never dropped, even when recorded as previous" {
    try expectRepoint(
        t_portable ++ ";" ++ t_install,
        t_install,
        .{ .dir = t_portable, .previous = t_install, .install_dir = t_install },
    );
}

test "repoint: an entry someone else wrote is left alone" {
    // A hand-added ghoztty dir is not ours: only the RECORDED entry is dropped.
    try expectRepoint(
        "C:\\tools\\ghoztty;C:\\x;" ++ t_share,
        "C:\\tools\\ghoztty;C:\\x",
        .{ .dir = t_share, .previous = t_portable, .install_dir = t_install },
    );
}

test "repoint: spellings of the same dir match, and untouched bytes survive" {
    try expectRepoint(
        null,
        "C:\\x;;\"" ++ t_portable ++ "\\\";" ++ t_install ++ ";",
        .{ .dir = t_portable, .install_dir = t_install },
    );
    try expectRepoint(
        "C:\\x;;" ++ t_share ++ ";" ++ t_install ++ ";",
        "C:\\x;;D:\\DESKTOP\\ghoztty-portable\\Ghoztty\\;" ++ t_install ++ ";",
        .{ .dir = t_share, .previous = t_portable, .install_dir = t_install },
    );
}

test "repoint: %VAR% entries are matched through the expander" {
    const testing = std.testing;
    const Exp = struct {
        pub fn expand(_: @This(), entry: []const u8) []const u8 {
            if (std.mem.eql(u8, entry, "%LOCALAPPDATA%\\Programs\\Ghoztty")) return t_install;
            return entry;
        }
    };
    const got = try repoint(
        testing.allocator,
        "C:\\x;%LOCALAPPDATA%\\Programs\\Ghoztty",
        .{ .dir = t_portable, .install_dir = t_install },
        Exp{},
    );
    defer if (got) |g| testing.allocator.free(g);
    try testing.expectEqualStrings("C:\\x;" ++ t_portable ++ ";%LOCALAPPDATA%\\Programs\\Ghoztty", got.?);
}
