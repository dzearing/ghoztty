//! Restart Pane with Shell (T3752, child of T3735): the pure half.
//!
//! The pane keeps its id, its name and its slot in the split tree; only the
//! process tree inside it is replaced by the shell the user picked. This file
//! holds what can be decided without the OS - the list a picker offers, the
//! folder the new shell starts in, and the words the user reads - so the none
//! lane can assert it. The swap itself is `pane_restart.zig`.
//!
//! The list is the installed shells the Settings Shell menu already finds
//! (`settings_controls.common_shells`, filtered to the ones on PATH) with the
//! one generic `wsl.exe` entry replaced by one entry per installed distro,
//! because "WSL" alone does not say which Linux you get. T3750 grows the
//! shared catalog (Git Bash, ...); when it lands, `pane_restart` hands its
//! list here instead of the common shells.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One entry a picker offers.
pub const Choice = struct {
    /// The `--shell` value the pane opens with: a program (`pwsh.exe`) or
    /// `wsl:<distro>` - the same spec `+new-window`/`+split --shell` take, so
    /// the restart and the CLI cannot open the same choice two ways.
    spec: []const u8,
    /// What the menu shows.
    label: []const u8,
};

/// An installed shell, as `settings_controls.CommonShell` describes one.
pub const Installed = struct { program: []const u8, label: []const u8 };

/// Upper bound on the entries a picker shows (the context submenu's command
/// ids are `submenu_base + index`, so the range has to be fixed).
pub const max_choices: usize = 24;

/// First command id of the context menu's submenu entries. Above every
/// `context_menu.Id` so a submenu pick can never read as a top-level item.
pub const submenu_base: usize = 0x100;

pub const title = "Restart Pane with Shell";
pub const palette_prefix = title ++ ": ";

/// Shown when something other than the shell is running in the pane - the
/// close-confirm rule, because a restart ends that program exactly as a close
/// would.
pub const confirm_text = "A process is still running in this terminal.\nRestart it anyway?";
pub const confirm_ok = "Restart";

/// The picker's entries: every installed shell, with `wsl.exe` replaced by
/// one `WSL: <distro>` entry per installed distro (none when no distro is
/// installed, since a bare wsl.exe would then open nothing). Strings are
/// allocated in `arena`. At most `max_choices`.
pub fn choices(
    arena: Allocator,
    installed: []const Installed,
    distros: []const []const u8,
) Allocator.Error![]Choice {
    var out: std.ArrayList(Choice) = .empty;
    for (installed) |s| {
        if (out.items.len >= max_choices) break;
        if (isWslProgram(s.program)) {
            for (distros) |d| {
                if (out.items.len >= max_choices) break;
                try out.append(arena, .{
                    .spec = try std.fmt.allocPrint(arena, "wsl:{s}", .{d}),
                    .label = try std.fmt.allocPrint(arena, "WSL: {s}", .{d}),
                });
            }
            continue;
        }
        try out.append(arena, .{ .spec = s.program, .label = s.label });
    }
    return out.items;
}

fn isWslProgram(program: []const u8) bool {
    return std.ascii.eqlIgnoreCase(program, "wsl.exe") or std.ascii.eqlIgnoreCase(program, "wsl");
}

/// A `wsl` / `wsl:<distro>` spec.
pub fn isWslSpec(spec: []const u8) bool {
    if (isWslProgram(spec)) return true;
    return spec.len > 4 and std.ascii.eqlIgnoreCase(spec[0..4], "wsl:");
}

/// The folder the new shell starts in, given the folder the old one was in.
///
/// A WSL shell starts in the distro's home (null: `wsl.exe --cd ~`, T3749),
/// never in the slow `/mnt/c` mirror of a Windows folder. A Windows shell
/// keeps the old folder when it IS a Windows folder; a Linux path from a WSL
/// pane means nothing to cmd or PowerShell, so it falls back to the shell's
/// default (null). Per-shell starting folders are T3754.
pub fn carriedCwd(spec: []const u8, old_cwd: ?[]const u8) ?[]const u8 {
    if (isWslSpec(spec)) return null;
    const cwd = old_cwd orelse return null;
    return if (isWindowsPath(cwd)) cwd else null;
}

/// `C:\...`, `C:/...` or a UNC `\\server\share`.
pub fn isWindowsPath(p: []const u8) bool {
    if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/'))
        return true;
    return p.len >= 3 and p[0] == '\\' and p[1] == '\\' and p[2] != '\\' and p[2] != '?' and p[2] != '.';
}

/// The command palette row for `c`.
pub fn paletteLabel(arena: Allocator, c: Choice) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, palette_prefix ++ "{s}", .{c.label});
}

/// The submenu index a context-menu command id names, or null when the id
/// is not one of the `count` submenu entries.
pub fn submenuIndex(cmd: usize, count: usize) ?usize {
    if (cmd < submenu_base) return null;
    const i = cmd - submenu_base;
    return if (i < count) i else null;
}

const testing = std.testing;

const sample_installed = [_]Installed{
    .{ .program = "pwsh.exe", .label = "PowerShell 7 (pwsh.exe)" },
    .{ .program = "cmd.exe", .label = "Command Prompt (cmd.exe)" },
    .{ .program = "wsl.exe", .label = "WSL (wsl.exe)" },
};

test "choices: one WSL entry per distro replaces the bare wsl.exe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try choices(arena.allocator(), &sample_installed, &.{ "Debian", "Ubuntu" });
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqualStrings("pwsh.exe", got[0].spec);
    try testing.expectEqualStrings("cmd.exe", got[1].spec);
    try testing.expectEqualStrings("wsl:Debian", got[2].spec);
    try testing.expectEqualStrings("WSL: Debian", got[2].label);
    try testing.expectEqualStrings("wsl:Ubuntu", got[3].spec);
}

test "choices: no distro installed offers no WSL entry at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try choices(arena.allocator(), &sample_installed, &.{});
    try testing.expectEqual(@as(usize, 2), got.len);
    for (got) |c| try testing.expect(!isWslSpec(c.spec));
}

test "choices: capped at max_choices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var many: [max_choices + 10][]const u8 = undefined;
    for (&many) |*d| d.* = "D";
    const got = try choices(arena.allocator(), &sample_installed, &many);
    try testing.expectEqual(max_choices, got.len);
}

test "carriedCwd: WSL starts at home, Windows keeps a Windows folder only" {
    try testing.expect(carriedCwd("wsl:Ubuntu", "C:\\src") == null);
    try testing.expect(carriedCwd("wsl", "C:\\src") == null);
    try testing.expectEqualStrings("C:\\src", carriedCwd("pwsh.exe", "C:\\src").?);
    try testing.expectEqualStrings("D:/git", carriedCwd("cmd.exe", "D:/git").?);
    try testing.expectEqualStrings("\\\\nas\\share", carriedCwd("cmd.exe", "\\\\nas\\share").?);
    // A Linux cwd from a WSL pane means nothing to cmd.
    try testing.expect(carriedCwd("cmd.exe", "/home/me") == null);
    try testing.expect(carriedCwd("cmd.exe", "\\\\?\\C:\\x") == null);
    try testing.expect(carriedCwd("cmd.exe", null) == null);
}

test "isWslSpec" {
    try testing.expect(isWslSpec("wsl:Ubuntu"));
    try testing.expect(isWslSpec("WSL.EXE"));
    try testing.expect(!isWslSpec("wsl:"));
    try testing.expect(!isWslSpec("pwsh.exe"));
}

test "palette label and submenu ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const l = try paletteLabel(arena.allocator(), .{ .spec = "wsl:Ubuntu", .label = "WSL: Ubuntu" });
    try testing.expectEqualStrings("Restart Pane with Shell: WSL: Ubuntu", l);
    try testing.expect(submenuIndex(5, 3) == null);
    try testing.expectEqual(@as(?usize, 0), submenuIndex(submenu_base, 3));
    try testing.expectEqual(@as(?usize, 2), submenuIndex(submenu_base + 2, 3));
    try testing.expect(submenuIndex(submenu_base + 3, 3) == null);
}
