//! The command palette's "… with Shell" rows on GTK (T3737, the Linux half of
//! win32's T3751): "New Tab with Shell…", "New Window with Shell…", "Split
//! Right with Shell…" and "Split Down with Shell…". Picking one keeps the
//! palette open and swaps its list for the installed shells; picking a shell
//! opens that target on it.
//!
//! The shell list is the one Settings > Shell offers on Linux
//! (`settings_controls.posix_shells` - zsh, bash, fish, nu, the Mac's list -
//! each one found on `PATH`, by the absolute path the walk finds), so a shell
//! picked here and one picked in Settings are the same program. Not
//! `/etc/shells`: on a stock Ubuntu it lists `/bin/bash` and `/usr/bin/bash`
//! (one program, twice), `rbash`, and `tmux`/`screen`, none of which a person
//! means by "a different shell".
//!
//! The pane runs the shell the way `+new-window --shell=<path>` with no
//! `--command` runs it (`IpcHandlers.paneCommand`: argv `[<path>]`), so a
//! shell chosen in a menu and one named on the CLI cannot open differently.
//!
//! No GTK imports: the none lane tests it (`src/apprt/unit_tests.zig`).
const std = @import("std");
const Allocator = std.mem.Allocator;

const controls = @import("../win32/settings_controls.zig");

/// Where a "… with Shell" row opens the shell the user picks.
pub const Target = enum(c_int) {
    new_tab,
    new_window,
    split_right,
    split_down,

    /// The row's title. The ellipsis says "a choice follows", as on win32.
    pub fn title(self: Target) [:0]const u8 {
        return switch (self) {
            .new_tab => "New Tab with Shell\u{2026}",
            .new_window => "New Window with Shell\u{2026}",
            .split_right => "Split Right with Shell\u{2026}",
            .split_down => "Split Down with Shell\u{2026}",
        };
    }

    /// The row's identity, shown as its subtitle the way a keybind row
    /// shows its action, and matched by the palette's search (so "shell"
    /// finds all four).
    pub fn key(self: Target) [:0]const u8 {
        return switch (self) {
            .new_tab => "new_tab_with_shell",
            .new_window => "new_window_with_shell",
            .split_right => "split_right_with_shell",
            .split_down => "split_down_with_shell",
        };
    }

    /// The search field's cue while the shell list is up: says what the
    /// pick will open, since the list itself is just shell names (win32
    /// `ShellTarget.prompt`, word for word).
    pub fn prompt(self: Target) [:0]const u8 {
        return switch (self) {
            .new_tab => "New tab with which shell?",
            .new_window => "New window with which shell?",
            .split_right => "Split right with which shell?",
            .split_down => "Split down with which shell?",
        };
    }

    pub fn description(self: Target) [:0]const u8 {
        return switch (self) {
            .new_tab => "Open a new tab on a shell you pick",
            .new_window => "Open a new window on a shell you pick",
            .split_right => "Split the pane to the right on a shell you pick",
            .split_down => "Split the pane downward on a shell you pick",
        };
    }
};

/// The palette's top-level placeholder, put back when Escape leaves the
/// shell list (the blueprint's own text).
pub const commands_prompt: [:0]const u8 = "Execute a command\u{2026}";

/// One installed shell: the name the row shows and the absolute path the
/// pane runs (also the row's subtitle).
pub const Shell = struct {
    name: [:0]const u8,
    path: [:0]const u8,
};

/// The installed shells, in Settings > Shell's order: each of
/// `posix_shells` that `path_env` (`:`-separated) holds as an executable,
/// by the absolute path found. `exists` answers "is this an executable
/// file" (the SettingsWindow's `isExecutable` in the app). A name found
/// twice is listed once; an empty list means none of them is installed.
pub fn catalog(
    arena: Allocator,
    path_env: []const u8,
    ctx: anytype,
    comptime exists: fn (@TypeOf(ctx), []const u8) bool,
) Allocator.Error![]const Shell {
    var out: std.ArrayList(Shell) = .empty;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (controls.posix_shells) |name| {
        const full = controls.resolvePosix(&buf, name, path_env, ctx, exists) orelse continue;
        try out.append(arena, .{
            .name = try arena.dupeZ(u8, name),
            .path = try arena.dupeZ(u8, full),
        });
    }
    return out.items;
}

/// The argv a picked shell's pane runs: the shell itself, interactive,
/// exactly as `--shell=<path>` alone opens it.
pub fn argv(arena: Allocator, path: []const u8) Allocator.Error![]const [:0]const u8 {
    const out = try arena.alloc([:0]const u8, 1);
    out[0] = try arena.dupeZ(u8, path);
    return out;
}

// ---------------------------------------------------------------------
// Tests

const testing = std.testing;

const FakeFs = struct {
    present: []const []const u8,
    fn has(self: FakeFs, path: []const u8) bool {
        for (self.present) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }
};

test "the four rows: one per target, each titled '… with Shell…' and keyed apart (T3737)" {
    var seen_keys = std.StringHashMap(void).init(testing.allocator);
    defer seen_keys.deinit();
    for (std.enums.values(Target)) |t| {
        try testing.expect(std.mem.endsWith(u8, t.title(), "with Shell\u{2026}"));
        try testing.expect(std.mem.indexOf(u8, t.key(), "with_shell") != null);
        try testing.expect(!seen_keys.contains(t.key()));
        try seen_keys.put(t.key(), {});
        try testing.expect(std.mem.endsWith(u8, t.prompt(), "which shell?"));
        try testing.expect(t.description().len > 0);
    }
    try testing.expectEqual(@as(usize, 4), seen_keys.count());
}

test "a prompt names what the pick opens (win32 ShellTarget.prompt)" {
    try testing.expect(std.mem.indexOf(u8, Target.new_tab.prompt(), "tab") != null);
    try testing.expect(std.mem.indexOf(u8, Target.new_window.prompt(), "window") != null);
    try testing.expect(std.mem.indexOf(u8, Target.split_right.prompt(), "right") != null);
    try testing.expect(std.mem.indexOf(u8, Target.split_down.prompt(), "down") != null);
}

test "catalog: the Settings > Shell list, in its order, by the path PATH finds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fs: FakeFs = .{ .present = &.{ "/usr/bin/bash", "/bin/bash", "/usr/local/bin/fish", "/usr/bin/zsh" } };
    const got = try catalog(arena, "/usr/local/bin:/usr/bin:/bin", fs, FakeFs.has);
    try testing.expectEqual(@as(usize, 3), got.len);
    // zsh, bash, fish: posix_shells order, not PATH order.
    try testing.expectEqualStrings("zsh", got[0].name);
    try testing.expectEqualStrings("/usr/bin/zsh", got[0].path);
    try testing.expectEqualStrings("bash", got[1].name);
    // The first PATH dir that holds it: one bash row, not one per dir.
    try testing.expectEqualStrings("/usr/bin/bash", got[1].path);
    try testing.expectEqualStrings("fish", got[2].name);
    try testing.expectEqualStrings("/usr/local/bin/fish", got[2].path);
}

test "catalog: nothing installed is an empty list, and an empty PATH entry is never the cwd" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fs: FakeFs = .{ .present = &.{ "/bash", "bash" } };
    try testing.expectEqual(@as(usize, 0), (try catalog(arena, "::/nowhere", fs, FakeFs.has)).len);
}

test "argv: the shell alone, as --shell=<path> with no --command runs it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try argv(arena_state.allocator(), "/usr/bin/fish");
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("/usr/bin/fish", got[0]);
}
