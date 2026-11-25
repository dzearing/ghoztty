//! The WSL distros installed for this user (T3735), read from the registry
//! rather than from `wsl -l`, because asking wsl.exe can boot the WSL VM and
//! nothing here may start WSL unasked (CLAUDE.md). Each distro registers a
//! subkey of HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss carrying a
//! `DistributionName` value; that is the same list `wsl -l -q` prints.
//!
//! This is the one place the per-distro shell entries come from: the
//! `--shell=wsl:<distro>` refusal names them today, and the shell pickers
//! (command palette, the + dropdown, Settings > Shell) list them.

const std = @import("std");
const builtin = @import("builtin");
// Only `listInstalled` touches it, so the pure half (and its tests) compiles
// in every lane: Zig analyzes the import lazily.
const w32 = @import("win32.zig");

const lxss_subkey = std.unicode.utf8ToUtf16LeStringLiteral(
    "Software\\Microsoft\\Windows\\CurrentVersion\\Lxss",
);
const distribution_name = std.unicode.utf8ToUtf16LeStringLiteral("DistributionName");

const ERROR_NO_MORE_ITEMS: u32 = 259;
const KEY_ENUMERATE_SUB_KEYS: u32 = 0x0008;

extern "advapi32" fn RegEnumKeyExW(
    hKey: w32.HKEY,
    dwIndex: u32,
    lpName: [*]u16,
    lpcchName: *u32,
    lpReserved: ?*u32,
    lpClass: ?[*]u16,
    lpcchClass: ?*u32,
    lpftLastWriteTime: ?*anyopaque,
) callconv(.winapi) u32;

/// Whether a registered distro is one a person would pick as a shell. Docker
/// Desktop registers its own backing distros (`docker-desktop`,
/// `docker-desktop-data`); they are not shells.
pub fn isUserDistro(name: []const u8) bool {
    if (name.len == 0) return false;
    return !std.ascii.startsWithIgnoreCase(name, "docker-desktop");
}

/// The picker list from the raw registry names: user distros only, without
/// duplicates (case-insensitive), sorted case-insensitively so the menu reads
/// the same on every launch. Sorts and compacts `names` in place.
pub fn catalog(names: [][]const u8) [][]const u8 {
    var n: usize = 0;
    for (names) |name| {
        if (!isUserDistro(name)) continue;
        const dup = for (names[0..n]) |kept| {
            if (std.ascii.eqlIgnoreCase(kept, name)) break true;
        } else false;
        if (dup) continue;
        names[n] = name;
        n += 1;
    }
    const out = names[0..n];
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lt);
    return out;
}

/// The installed distro whose name matches `want` (case-insensitive, the way
/// `wsl -d` matches), as the registry spells it; null when none does.
pub fn find(installed: []const []const u8, want: []const u8) ?[]const u8 {
    for (installed) |name| if (std.ascii.eqlIgnoreCase(name, want)) return name;
    return null;
}

/// The installed user distros, sorted. Empty when WSL is not installed (no
/// Lxss key). Strings live in `arena`.
pub fn listInstalled(arena: std.mem.Allocator) std.mem.Allocator.Error![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var key: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(
        w32.HKEY_CURRENT_USER,
        lxss_subkey,
        0,
        w32.KEY_READ | KEY_ENUMERATE_SUB_KEYS,
        &key,
    ) != w32.ERROR_SUCCESS) return names.items;
    defer _ = w32.RegCloseKey(key);

    var index: u32 = 0;
    while (index < 256) : (index += 1) {
        var buf: [256]u16 = undefined;
        var len: u32 = buf.len;
        const rc = RegEnumKeyExW(key, index, &buf, &len, null, null, null, null);
        if (rc == ERROR_NO_MORE_ITEMS) break;
        if (rc != w32.ERROR_SUCCESS) continue;
        buf[len] = 0;
        var sub: w32.HKEY = undefined;
        if (w32.RegOpenKeyExW(key, buf[0..len :0], 0, w32.KEY_QUERY_VALUE, &sub) != w32.ERROR_SUCCESS) continue;
        defer _ = w32.RegCloseKey(sub);
        const name = (try readString(arena, sub, distribution_name)) orelse continue;
        try names.append(arena, name);
    }
    return catalog(names.items);
}

fn readString(arena: std.mem.Allocator, key: w32.HKEY, name: [*:0]const u16) std.mem.Allocator.Error!?[]const u8 {
    var vtype: u32 = 0;
    var size: u32 = 0;
    if (w32.RegQueryValueExW(key, name, null, &vtype, null, &size) != w32.ERROR_SUCCESS) return null;
    if (vtype != w32.REG_SZ and vtype != w32.REG_EXPAND_SZ) return null;
    if (size < 2) return null;
    const buf = try arena.alloc(u16, (size + 1) / 2);
    var got: u32 = @intCast(buf.len * 2);
    if (w32.RegQueryValueExW(key, name, null, &vtype, @ptrCast(buf.ptr), &got) != w32.ERROR_SUCCESS) return null;
    var wide: []const u16 = buf[0 .. got / 2];
    while (wide.len > 0 and wide[wide.len - 1] == 0) wide = wide[0 .. wide.len - 1];
    if (wide.len == 0) return null;
    return std.unicode.utf16LeToUtf8Alloc(arena, wide) catch null;
}

test "catalog: user distros only, deduped, sorted (T3735)" {
    var names = [_][]const u8{ "Ubuntu", "docker-desktop", "debian", "Docker-Desktop-Data", "ubuntu", "", "Alpine" };
    const out = catalog(&names);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("Alpine", out[0]);
    try std.testing.expectEqualStrings("debian", out[1]);
    try std.testing.expectEqualStrings("Ubuntu", out[2]);
}

test "find: matches the way wsl -d does (T3735)" {
    const installed = [_][]const u8{ "Debian", "Ubuntu-22.04" };
    try std.testing.expectEqualStrings("Ubuntu-22.04", find(&installed, "ubuntu-22.04").?);
    try std.testing.expect(find(&installed, "Ubuntu") == null);
}

test "listInstalled: reads without failing on this box (T3735)" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try listInstalled(arena.allocator());
    for (got) |name| try std.testing.expect(isUserDistro(name));
}
