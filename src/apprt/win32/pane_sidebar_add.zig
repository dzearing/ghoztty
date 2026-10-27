//! The pane sidebar's + buttons, as rules (T2323; Mac 44aa923f0
//! `PaneSidebarAdd.swift`).
//!
//! - **Header +** (the panel's header, left of the all-windows toggle; the
//!   rail's header is its toggle alone): a new window, exactly Ctrl+Shift+N
//!   from this window's focused pane - its working directory, a random
//!   gradient, a remote window's machine.
//! - **Project header +**: the same, opened from the group's first window as
//!   listed, with its title pinned to `<project>: new` - or the first free
//!   `new-2`, `new-3`, ... checked against every window's name at click time
//!   (`newWindowTitle`) - so it lands in the group.
//! - **Window header +**: raises that window and splits its focused pane in
//!   the last direction split BY HAND, app-wide (`SplitMemory`, default
//!   right, not persisted). A keybind, the command palette, a pane's context
//!   menu or a viewer's split chord sets it; `ghoztty +split` and a session
//!   restore never do, so an agent laying out panes doesn't skew it.
//!
//! All three are manual surfaces: they take focus, as the keybinds do - the
//! CLI's background-by-default policy does not apply.
//!
//! No OS imports, so this unit-tests in every app-runtime lane; the window
//! half is `PaneSidebar.zig`.

const std = @import("std");

/// A split's direction, by name - the same four every split type in the
/// runtime spells (`as` converts).
pub const Direction = enum { left, right, up, down };

/// `d` as any enum with the same four tags (a `SplitTree` direction, an
/// apprt action's).
pub fn as(comptime T: type, d: Direction) T {
    return switch (d) {
        inline else => |tag| @field(T, @tagName(tag)),
    };
}

/// The direction of the last split made by hand (Mac `PaneSplitMemory`),
/// for a window header's + to repeat. One per process, like Mac's.
pub const SplitMemory = struct {
    last: Direction = .right,

    pub fn noteManual(self: *SplitMemory, d: Direction) void {
        self.last = d;
    }
};

pub var split_memory: SplitMemory = .{};

/// Record a split asked for by hand. Takes any four-tag direction enum.
pub fn noteManualSplit(d: anytype) void {
    split_memory.noteManual(switch (d) {
        inline else => |tag| @field(Direction, @tagName(tag)),
    });
}

/// The placeholder after `<project>: ` (Mac `PaneSidebarNewWindowName`).
pub const placeholder = "new";

/// A project group's +: the new window's title - `<project>: new`, or the
/// first free `new-2`, `new-3`, ... - so it is grouped under `project` with a
/// name no window in `existing` has. Written into `buf`; truncated to it.
pub fn newWindowTitle(buf: []u8, project: []const u8, existing: []const []const u8) []const u8 {
    const base = std.fmt.bufPrint(buf, "{s}: {s}", .{ project, placeholder }) catch return buf[0..0];
    if (!contains(existing, base)) return base;
    var n: usize = 2;
    while (true) : (n += 1) {
        const name = std.fmt.bufPrint(buf, "{s}: {s}-{d}", .{ project, placeholder, n }) catch return buf[0..0];
        if (!contains(existing, name)) return name;
    }
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The tips (Mac's `.help`).
pub const new_window_tip = "New window";
pub const new_pane_tip = "New pane";

/// A project header's +: "New window in <project>".
pub fn projectAddTip(project: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "New window in {s}", .{project}) catch new_window_tip;
}

const testing = std.testing;

test "T2323: a project's new window is `<project>: new`, else the first free new-N (Mac PaneSidebarNewWindowNameTests)" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("ghoztty: new", newWindowTitle(&buf, "ghoztty", &.{ "ghoztty: main", "other" }));
    try testing.expectEqualStrings("ghoztty: new-2", newWindowTitle(&buf, "ghoztty", &.{"ghoztty: new"}));
    try testing.expectEqualStrings("ghoztty: new-4", newWindowTitle(&buf, "ghoztty", &.{ "ghoztty: new", "ghoztty: new-2", "ghoztty: new-3" }));
    // A gap is reused: the FIRST free one.
    try testing.expectEqualStrings("ghoztty: new-2", newWindowTitle(&buf, "ghoztty", &.{ "ghoztty: new", "ghoztty: new-3" }));
    // Another project's placeholder is not this one's.
    try testing.expectEqualStrings("a: new", newWindowTitle(&buf, "a", &.{"b: new"}));
    // A project too long for the buffer gives nothing rather than a torn name.
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("", newWindowTitle(&tiny, "ghoztty", &.{}));
}

test "T2323: the split memory defaults to right, follows each manual split, and converts both ways" {
    var m: SplitMemory = .{};
    try testing.expectEqual(Direction.right, m.last);
    m.noteManual(.down);
    try testing.expectEqual(Direction.down, m.last);
    m.noteManual(.left);
    try testing.expectEqual(Direction.left, m.last);
    const Other = enum { up, down, left, right };
    try testing.expectEqual(Other.left, as(Other, m.last));
    const saved = split_memory;
    defer split_memory = saved;
    noteManualSplit(Other.up);
    try testing.expectEqual(Direction.up, split_memory.last);
}

test "T2323: a project +'s tip names the project" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("New window in ghoztty", projectAddTip("ghoztty", &buf));
}
