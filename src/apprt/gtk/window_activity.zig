//! A GTK window's activity state, shown (T3561, Linux L10; cli-commands.md
//! `+set-state`): the pure half. `+set-state` / OSC 7777 set a pane's state;
//! the window shows the most urgent of its panes' states (`needs_input` >
//! `busy` > `idle`) as a title suffix - " (busy)", " (question)" - exactly as
//! the Mac's `computeTitle` and win32's `composeTitle` do. The suffix is the
//! state's HUMAN name (`displayLabel`), never its machine token.
//!
//! Each tab carries its own panes' state on its tab-bar entry as well:
//! `AdwTabPage:loading` (a spinner) while busy, `needs-attention` while one
//! waits on a question. That is the GTK-native mark; the Mac and win32 show
//! the window aggregate only. `class/window.zig` is the GTK half.
//!
//! No GTK imports.
const std = @import("std");
const ActivityState = @import("../../terminal/osc.zig").Command.ActivityState;

pub const State = ActivityState;

/// The more urgent of two states (`needs_input` > `busy` > `idle`).
pub fn worse(a: State, b: State) State {
    return if (rank(b) > rank(a)) b else a;
}

fn rank(s: State) u2 {
    return switch (s) {
        .idle => 0,
        .busy => 1,
        .needs_input => 2,
    };
}

/// The title suffix for the window's aggregate: none while idle.
pub fn titleSuffix(state: State) []const u8 {
    return switch (state) {
        .idle => "",
        inline else => |s| " (" ++ comptime s.displayLabel() ++ ")",
    };
}

/// The window's title: its base (a pinned title, else the active tab's) and
/// the activity suffix. Null base (no tab yet, nothing pinned) is no title.
pub fn composeTitle(alloc: std.mem.Allocator, base: ?[]const u8, state: State) std.mem.Allocator.Error!?[:0]u8 {
    const b = base orelse return null;
    return try std.mem.concatWithSentinel(alloc, u8, &.{ b, titleSuffix(state) }, 0);
}

/// What a tab's entry in the tab bar shows for its panes' aggregate.
pub const TabMarks = struct {
    /// `AdwTabPage:loading`: a spinner in place of the icon.
    loading: bool,
    /// `AdwTabPage:needs-attention`, or null to leave it as it is - the bell
    /// owns the same mark, so only a move into or out of `needs_input`
    /// touches it, and selecting the tab clears it as it does a bell's.
    attention: ?bool,
};

/// The marks for a tab whose aggregate moved from `old` to `new`.
pub fn tabMarks(old: State, new: State) TabMarks {
    const was = old == .needs_input;
    const is = new == .needs_input;
    return .{
        .loading = new == .busy,
        .attention = if (was == is) null else is,
    };
}

const testing = std.testing;

test "worse: needs_input beats busy beats idle, either order" {
    try testing.expectEqual(State.idle, worse(.idle, .idle));
    try testing.expectEqual(State.busy, worse(.idle, .busy));
    try testing.expectEqual(State.busy, worse(.busy, .idle));
    try testing.expectEqual(State.needs_input, worse(.busy, .needs_input));
    try testing.expectEqual(State.needs_input, worse(.needs_input, .busy));
    try testing.expectEqual(State.needs_input, worse(.needs_input, .idle));
}

test "titleSuffix: the human label, never the token" {
    try testing.expectEqualStrings("", titleSuffix(.idle));
    try testing.expectEqualStrings(" (busy)", titleSuffix(.busy));
    try testing.expectEqualStrings(" (question)", titleSuffix(.needs_input));
}

test "composeTitle: base plus suffix, nothing without a base" {
    const a = testing.allocator;
    const t1 = (try composeTitle(a, "~/src", .busy)).?;
    defer a.free(t1);
    try testing.expectEqualStrings("~/src (busy)", t1);
    const t2 = (try composeTitle(a, "pinned", .idle)).?;
    defer a.free(t2);
    try testing.expectEqualStrings("pinned", t2);
    try testing.expectEqual(@as(?[:0]u8, null), try composeTitle(a, null, .needs_input));
}

test "tabMarks: spinner while busy; attention only on a move across needs_input" {
    try testing.expectEqual(TabMarks{ .loading = true, .attention = null }, tabMarks(.idle, .busy));
    try testing.expectEqual(TabMarks{ .loading = false, .attention = true }, tabMarks(.busy, .needs_input));
    try testing.expectEqual(TabMarks{ .loading = false, .attention = null }, tabMarks(.needs_input, .needs_input));
    try testing.expectEqual(TabMarks{ .loading = false, .attention = false }, tabMarks(.needs_input, .idle));
    try testing.expectEqual(TabMarks{ .loading = false, .attention = null }, tabMarks(.busy, .idle));
}
