//! The pure half of the Linux launch handoff (T3598): what a launch of one
//! Ghoztty build does when ANOTHER build already serves the CLI socket.
//! win32's `App.handOffOrTakeOver` / `handoffChoice` (T1022, T1023, T1070),
//! stated over plain values so the rules run in the `none` lane; the GTK half
//! (`launch_handoff.zig`) asks the running instance, shows the dialog and acts.
//!
//! The question and its wording are the shared `os/ipc_handoff.zig`
//! (`mismatchPrompt`); this file only maps the dialog's buttons to an answer,
//! reads the scripted answer, and rebuilds the window a join forwards.

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");

/// What the user chose (win32's `HandoffChoice`, minus the pid it carries).
pub const Choice = enum {
    /// Open the window in the build already running.
    join,
    /// Open nothing.
    cancel,
    /// Quit the running build and start this one in its place.
    switch_build,
};

/// The dialog's buttons, left to right, and which index means what. With a
/// Switch the row is [Switch] [Open Window] [Cancel] - win32's order (T1070);
/// without one, [Open Window] [Cancel]. Enter takes Open Window, the answer
/// that closes nothing; Escape takes Cancel.
pub const Layout = struct {
    labels: [3][]const u8 = .{ "", "", "" },
    len: usize = 0,
    default_index: usize = 0,
    cancel_index: usize = 0,

    pub fn of(ok_label: []const u8, cancel_label: []const u8, switch_label: ?[]const u8) Layout {
        var l: Layout = .{};
        if (switch_label) |s| {
            l.labels[l.len] = s;
            l.len += 1;
        }
        l.default_index = l.len;
        l.labels[l.len] = ok_label;
        l.len += 1;
        l.cancel_index = l.len;
        l.labels[l.len] = cancel_label;
        l.len += 1;
        return l;
    }

    pub fn hasSwitch(self: Layout) bool {
        return self.len == 3;
    }

    /// The answer a dialog response means. Null = the dialog ended without a
    /// button (closed, cancelled, failed), which is Cancel: the user backed
    /// out of a question they were asked, exactly as Escape does.
    pub fn choiceFor(self: Layout, index: ?usize) Choice {
        const i = index orelse return .cancel;
        if (i >= self.len or i == self.cancel_index) return .cancel;
        if (i == self.default_index) return .join;
        return .switch_build;
    }
};

/// The test/automation answer (`GHOZTTY_HANDOFF_PROMPT`, win32's env and
/// values): `join` skips the question and joins, `switch` answers Switch where
/// the running build offers it - and joins where it does not, exactly as the
/// dialog would have no such button. Anything else means: ask.
pub const prompt_env = "GHOZTTY_HANDOFF_PROMPT";

pub fn scripted(mode: ?[]const u8, can_switch: bool) ?Choice {
    const m = mode orelse return null;
    if (std.mem.eql(u8, m, "join")) return .join;
    if (std.mem.eql(u8, m, "switch")) return if (can_switch) .switch_build else .join;
    return null;
}

/// The `+new-window` argv a JOIN forwards to the running build (win32's
/// T487/T1797 `forwardedNewWindowArgs`): `--focus` first (this is a window the
/// user asked for by hand), then the launch's working directory and its `-e`
/// command, so neither is lost because another build answered. Allocated from
/// `alloc` (an arena; the launch exits right after sending).
pub fn forwardArgs(
    alloc: Allocator,
    initial_command: ?configpkg.Config.Command,
    working_directory: ?configpkg.Config.WorkingDirectory,
) Allocator.Error![]const [:0]const u8 {
    var args: std.ArrayList([:0]const u8) = .empty;
    errdefer args.deinit(alloc);

    // Ahead of everything: after a `-e` it would be part of the command.
    try args.append(alloc, try alloc.dupeZ(u8, "--focus"));

    if (working_directory) |wd| if (wd.value()) |path| {
        try args.append(alloc, try std.fmt.allocPrintSentinel(alloc, "--working-directory={s}", .{path}, 0));
    };

    if (initial_command) |cmd| switch (cmd) {
        .direct => |argv| {
            try args.append(alloc, try alloc.dupeZ(u8, "-e"));
            for (argv) |arg| try args.append(alloc, try alloc.dupeZ(u8, arg));
        },
        .shell => |command| try args.append(
            alloc,
            try std.fmt.allocPrintSentinel(alloc, "--command={s}", .{command}, 0),
        ),
    };

    return try args.toOwnedSlice(alloc);
}

/// How long a switching launch waits for the build it asked to quit, then how
/// long it keeps trying the socket after that process is gone (win32's
/// `handoff_exit_wait_ms` / `handoff_bind_retry_ms`). The quit saves the
/// layout and detaches every pane; the GTK app does that 150 ms after it
/// replies.
pub const exit_wait_ms: i64 = 20_000;
pub const free_wait_ms: i64 = 5_000;
pub const poll_ms: u64 = 50;

test "Layout: a switchable build gets [Switch] [Open Window] [Cancel], Enter on Open Window" {
    const testing = std.testing;
    const l = Layout.of("Open Window", "Cancel", "Switch");
    try testing.expect(l.hasSwitch());
    try testing.expectEqual(@as(usize, 3), l.len);
    try testing.expectEqualStrings("Switch", l.labels[0]);
    try testing.expectEqualStrings("Open Window", l.labels[1]);
    try testing.expectEqualStrings("Cancel", l.labels[2]);
    try testing.expectEqual(@as(usize, 1), l.default_index);
    try testing.expectEqual(@as(usize, 2), l.cancel_index);
    try testing.expectEqual(Choice.switch_build, l.choiceFor(0));
    try testing.expectEqual(Choice.join, l.choiceFor(1));
    try testing.expectEqual(Choice.cancel, l.choiceFor(2));
}

test "Layout: an older build gets only [Open Window] [Cancel]" {
    const testing = std.testing;
    const l = Layout.of("Open Window", "Cancel", null);
    try testing.expect(!l.hasSwitch());
    try testing.expectEqual(@as(usize, 2), l.len);
    try testing.expectEqualStrings("Open Window", l.labels[0]);
    try testing.expectEqual(Choice.join, l.choiceFor(0));
    try testing.expectEqual(Choice.cancel, l.choiceFor(1));
}

test "Layout: a dialog that ends without a button is Cancel, never a switch" {
    const testing = std.testing;
    const l = Layout.of("Open Window", "Cancel", "Switch");
    try testing.expectEqual(Choice.cancel, l.choiceFor(null));
    try testing.expectEqual(Choice.cancel, l.choiceFor(7));
}

test "scripted: join, switch where offered, and anything else asks" {
    const testing = std.testing;
    try testing.expectEqual(@as(?Choice, .join), scripted("join", true));
    try testing.expectEqual(@as(?Choice, .switch_build), scripted("switch", true));
    // Against a build that cannot be switched, the dialog would have no
    // Switch button: the scripted answer joins, as win32's does.
    try testing.expectEqual(@as(?Choice, .join), scripted("switch", false));
    try testing.expectEqual(@as(?Choice, null), scripted(null, true));
    try testing.expectEqual(@as(?Choice, null), scripted("ask", true));
}

test "forwardArgs: nothing else to forward is --focus alone" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for ([_]?configpkg.Config.WorkingDirectory{ null, .inherit, .home }) |wd| {
        const args = try forwardArgs(alloc, null, wd);
        try testing.expectEqual(@as(usize, 1), args.len);
        try testing.expectEqualStrings("--focus", args[0]);
    }
}

test "forwardArgs: -e argv and the launch cwd survive a join" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = try forwardArgs(alloc, .{ .direct = &.{ "htop", "-d", "5" } }, .{ .path = "/home/u/proj" });
    try testing.expectEqual(@as(usize, 6), args.len);
    try testing.expectEqualStrings("--focus", args[0]);
    try testing.expectEqualStrings("--working-directory=/home/u/proj", args[1]);
    try testing.expectEqualStrings("-e", args[2]);
    try testing.expectEqualStrings("htop", args[3]);
    try testing.expectEqualStrings("5", args[5]);
}

test "forwardArgs: a shell-form initial-command maps to --command" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = try forwardArgs(arena.allocator(), .{ .shell = "htop -d 5" }, null);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("--command=htop -d 5", args[1]);
}
