//! What a screen reader is told about the feedback composer's owner-drawn
//! parts (T1468) — the pure half, with no OS imports, so its unit tests run in
//! every app-runtime lane next to `viewer_feedback_layout.zig`.
//!
//! The composer's two circular actions and its strip of pictures are PAINTED by
//! the band rather than being child windows, so Windows has nothing to announce
//! for them on its own: Tab reaches all of them (T640, T668) and Narrator said
//! nothing. The band now answers `WM_GETOBJECT` with an accessible object of
//! its own (`viewer_feedback_acc.zig`), and this file is every answer that
//! object gives which does not need a window to compute: which child id names
//! which part, what each part is called, what role and state it reports, and
//! which part holds focus.
//!
//! ## The children, in order
//!
//! The order is the composer's TAB order, so walking the children with a
//! screen reader's "next item" visits the parts in the same sequence the
//! keyboard does:
//!
//!   1. the band's child windows — today exactly one, the web composer's text
//!      surface, which has an accessibility tree of its own (Chromium's) and is
//!      handed out as an object rather than described here;
//!   2. one LIST ITEM per picture, in strip order, named after the chip the
//!      picture is in the text (`Image #3`), so what the strip says and what
//!      the report says agree;
//!   3. the two actions, as PUSH BUTTONS named with Mac's help strings, the
//!      chord carried as the keyboard shortcut rather than inside the name.
//!
//! Child id 0 (`CHILDID_SELF`) is the band itself, a grouping called
//! "Feedback composer".
const std = @import("std");
const layout = @import("viewer_feedback_layout.zig");

/// One accessible part of the composer.
pub const Item = union(enum) {
    /// The band itself (`CHILDID_SELF`).
    self,
    /// One of the band's own child windows, by its index among them. Described
    /// by the window, not by this file.
    window: usize,
    /// A picture in the strip, by its index in strip order.
    tile: usize,
    /// One of the two circular actions.
    button: layout.Button,

    pub fn eql(a: Item, b: Item) bool {
        return switch (a) {
            .self => b == .self,
            .window => |i| b == .window and b.window == i,
            .tile => |i| b == .tile and b.tile == i,
            .button => |x| b == .button and b.button == x,
        };
    }
};

/// How many of each kind of part the composer has right now. Every child id is
/// a function of this and nothing else, so the numbering cannot drift from the
/// paint.
pub const Shape = struct {
    windows: usize,
    tiles: usize,

    pub fn count(s: Shape) usize {
        return s.windows + s.tiles + layout.button_count;
    }

    /// The part a child id names, or null for an id past the end. Ids are
    /// 1-based, as MSAA's are; 0 is the band.
    pub fn itemOf(s: Shape, id: i32) ?Item {
        if (id == 0) return .self;
        if (id < 0) return null;
        var idx: usize = @intCast(id - 1);
        if (idx < s.windows) return .{ .window = idx };
        idx -= s.windows;
        if (idx < s.tiles) return .{ .tile = idx };
        idx -= s.tiles;
        if (idx < layout.button_count) return .{ .button = @enumFromInt(idx) };
        return null;
    }

    /// The child id of a part. The inverse of `itemOf`.
    pub fn idOf(s: Shape, item: Item) i32 {
        const base: usize = switch (item) {
            .self => return 0,
            .window => |i| i,
            .tile => |i| s.windows + i,
            .button => |b| s.windows + s.tiles + @intFromEnum(b),
        };
        return @intCast(base + 1);
    }

    /// Where a screen reader's "next / previous / first / last" lands, or null
    /// when there is nothing there. `first` and `last` are asked of the band
    /// (its first and last child); `next` and `previous` of a child, and they
    /// stop at the ends rather than wrapping — the band's siblings are the
    /// parent's business, not this object's.
    pub fn navigate(s: Shape, from: i32, dir: Nav) ?i32 {
        const n: i32 = @intCast(s.count());
        return switch (dir) {
            .first_child => if (from == 0 and n > 0) 1 else null,
            .last_child => if (from == 0 and n > 0) n else null,
            .next => if (from >= 1 and from < n) from + 1 else null,
            .previous => if (from > 1 and from <= n) from - 1 else null,
        };
    }
};

pub const Nav = enum { next, previous, first_child, last_child };

/// The band's own name. What a reader says when focus enters the group.
pub const self_name = "Feedback composer";

/// A button's accessible NAME: Mac's help string without the chord, which is
/// reported separately as the keyboard shortcut (`shortcut`). Together they are
/// exactly the tooltip (`layout.label`) — a test holds them to that, so the
/// three strings cannot drift apart.
pub fn buttonName(b: layout.Button) []const u8 {
    return switch (b) {
        .snapshot => "Add a screenshot of the screen",
        .send => "Send feedback",
    };
}

pub fn shortcut(b: layout.Button) []const u8 {
    return switch (b) {
        .snapshot => "Ctrl+Shift+S",
        .send => "Ctrl+Enter",
    };
}

/// A tile's name: the words of the chip the picture is in the report, so the
/// strip and the text name each picture the same way. `number` is the image
/// number, which survives deletions (`#2` stays `#2` when `#1` goes).
pub fn tileName(buf: []u8, number: u32) []const u8 {
    return std.fmt.bufPrint(buf, "Image #{d}", .{number}) catch "Image";
}

/// A tile's description: where it sits in the strip, which a flat list of
/// children cannot otherwise say.
pub fn tileDescription(buf: []u8, index: usize, total: usize) []const u8 {
    return std.fmt.bufPrint(buf, "Attached picture {d} of {d}", .{ index + 1, total }) catch "";
}

/// What pressing a part does, in a reader's words.
pub fn defaultAction(item: Item) ?[]const u8 {
    return switch (item) {
        .button => "Press",
        .tile => "Select in report",
        .self, .window => null,
    };
}

/// MSAA role constants (oleacc.h) for the roles this composer reports.
pub const role_grouping: u32 = 0x14;
pub const role_list_item: u32 = 0x22;
pub const role_push_button: u32 = 0x2B;

/// The role a part reports. Null for a child window, which reports its own.
pub fn role(item: Item) ?u32 {
    return switch (item) {
        .self => role_grouping,
        .tile => role_list_item,
        .button => role_push_button,
        .window => null,
    };
}

/// MSAA state bits (oleacc.h) this composer reports.
pub const state_unavailable: u32 = 0x1;
pub const state_selected: u32 = 0x2;
pub const state_focused: u32 = 0x4;
pub const state_invisible: u32 = 0x8000;
pub const state_offscreen: u32 = 0x10000;
pub const state_focusable: u32 = 0x100000;
pub const state_selectable: u32 = 0x200000;

/// Everything the state of a part depends on, read off the band by the caller.
pub const StateInput = struct {
    /// Which actions can be pressed (`send` is dead while the report is empty).
    enabled: [layout.button_count]bool,
    /// Which actions the layout actually drew — a pane narrow enough squeezes
    /// them to nothing (T1153).
    drawn: [layout.button_count]bool,
    /// The part holding keyboard focus, if any part of THIS band does.
    focused: ?Item,
    /// The tile whose chip the caret is in.
    selected_tile: ?usize,
    /// Whether the tile being asked about is scrolled wholly out of the
    /// strip's viewport. Only read for a tile.
    tile_offscreen: bool = false,
};

pub fn state(item: Item, in: StateInput) u32 {
    var s: u32 = 0;
    const is_focused = if (in.focused) |f| f.eql(item) else false;
    switch (item) {
        .self, .window => {},
        .button => |b| {
            const i = @intFromEnum(b);
            if (!in.drawn[i]) s |= state_invisible;
            if (!in.enabled[i]) s |= state_unavailable else s |= state_focusable;
        },
        .tile => |i| {
            s |= state_focusable | state_selectable;
            if (in.selected_tile == i) s |= state_selected;
            if (in.tile_offscreen) s |= state_offscreen;
        },
    }
    if (is_focused) s |= state_focused;
    return s;
}

/// The part that holds keyboard focus inside the band, from the band's own
/// focus model (T640/T668). Null when the band itself does not hold the Win32
/// focus — the text surface, or something outside the composer, has it — so
/// nothing this object describes is focused.
pub fn focusedItem(
    band_has_focus: bool,
    key_focus: layout.Stop,
    carousel_focus: ?usize,
) ?Item {
    if (!band_has_focus) return null;
    if (layout.buttonOf(key_focus)) |b| return .{ .button = b };
    if (key_focus == .carousel) {
        if (carousel_focus) |i| return .{ .tile = i };
    }
    // The band holds focus but no part of it is ringed: the group itself.
    return .self;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a11y: child ids follow the tab order - text window, tiles, then the actions" {
    const s: Shape = .{ .windows = 1, .tiles = 3 };
    try testing.expectEqual(@as(usize, 6), s.count());
    try testing.expect(s.itemOf(0).?.eql(.self));
    try testing.expect(s.itemOf(1).?.eql(.{ .window = 0 }));
    try testing.expect(s.itemOf(2).?.eql(.{ .tile = 0 }));
    try testing.expect(s.itemOf(4).?.eql(.{ .tile = 2 }));
    try testing.expect(s.itemOf(5).?.eql(.{ .button = .snapshot }));
    try testing.expect(s.itemOf(6).?.eql(.{ .button = .send }));
    try testing.expectEqual(@as(?Item, null), s.itemOf(7));
    try testing.expectEqual(@as(?Item, null), s.itemOf(-4));
}

test "a11y: idOf is the inverse of itemOf for every child" {
    for ([_]Shape{
        .{ .windows = 0, .tiles = 0 },
        .{ .windows = 1, .tiles = 0 },
        .{ .windows = 1, .tiles = 5 },
        .{ .windows = 2, .tiles = 1 },
    }) |s| {
        var id: i32 = 0;
        while (id <= @as(i32, @intCast(s.count()))) : (id += 1) {
            try testing.expectEqual(id, s.idOf(s.itemOf(id).?));
        }
    }
}

test "a11y: with no pictures the actions follow the text directly" {
    const s: Shape = .{ .windows = 1, .tiles = 0 };
    try testing.expectEqual(@as(i32, 2), s.idOf(.{ .button = .snapshot }));
    try testing.expectEqual(@as(i32, 3), s.idOf(.{ .button = .send }));
}

test "a11y: navigation walks the children and stops at the ends" {
    const s: Shape = .{ .windows = 1, .tiles = 2 };
    try testing.expectEqual(@as(?i32, 1), s.navigate(0, .first_child));
    try testing.expectEqual(@as(?i32, 5), s.navigate(0, .last_child));
    try testing.expectEqual(@as(?i32, 3), s.navigate(2, .next));
    try testing.expectEqual(@as(?i32, 1), s.navigate(2, .previous));
    try testing.expectEqual(@as(?i32, null), s.navigate(5, .next));
    try testing.expectEqual(@as(?i32, null), s.navigate(1, .previous));
    // first/last are the band's questions, not a child's.
    try testing.expectEqual(@as(?i32, null), s.navigate(3, .first_child));
    // The band has no siblings this object can name.
    try testing.expectEqual(@as(?i32, null), s.navigate(0, .next));
}

test "a11y: a button's name and shortcut ARE its tooltip" {
    var buf: [128]u8 = undefined;
    for (std.enums.values(layout.Button)) |b| {
        const joined = try std.fmt.bufPrint(&buf, "{s} ({s})", .{ buttonName(b), shortcut(b) });
        try testing.expectEqualStrings(layout.label(b), joined);
    }
}

test "a11y: a tile is named after its chip, and says where it sits" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Image #7", tileName(&buf, 7));
    try testing.expectEqualStrings("Attached picture 2 of 3", tileDescription(&buf, 1, 3));
}

test "a11y: roles - group, list items, push buttons" {
    try testing.expectEqual(@as(?u32, role_grouping), role(.self));
    try testing.expectEqual(@as(?u32, role_list_item), role(.{ .tile = 0 }));
    try testing.expectEqual(@as(?u32, role_push_button), role(.{ .button = .send }));
    try testing.expectEqual(@as(?u32, null), role(.{ .window = 0 }));
}

test "a11y: focus follows the band's own stop model" {
    // The text surface has the Win32 focus: nothing here is focused.
    try testing.expectEqual(@as(?Item, null), focusedItem(false, .snapshot, null));
    try testing.expect(focusedItem(true, .send, null).?.eql(.{ .button = .send }));
    try testing.expect(focusedItem(true, .carousel, 2).?.eql(.{ .tile = 2 }));
    try testing.expect(focusedItem(true, .text, null).?.eql(.self));
}

test "a11y: state - a dead send button is unavailable, a live one focusable" {
    var in: StateInput = .{
        .enabled = .{ true, false },
        .drawn = .{ true, true },
        .focused = .{ .button = .snapshot },
        .selected_tile = 1,
    };
    const snap = state(.{ .button = .snapshot }, in);
    try testing.expect(snap & state_focused != 0);
    try testing.expect(snap & state_focusable != 0);
    const send = state(.{ .button = .send }, in);
    try testing.expect(send & state_unavailable != 0);
    try testing.expect(send & state_focusable == 0);
    try testing.expect(send & state_focused == 0);

    in.drawn = .{ true, false };
    try testing.expect(state(.{ .button = .send }, in) & state_invisible != 0);

    const tile = state(.{ .tile = 1 }, in);
    try testing.expect(tile & state_selected != 0);
    try testing.expect(state(.{ .tile = 0 }, in) & state_selected == 0);
}

test "a11y: state - a tile scrolled out of the strip is offscreen" {
    var in: StateInput = .{
        .enabled = .{ true, true },
        .drawn = .{ true, true },
        .focused = null,
        .selected_tile = null,
    };
    try testing.expect(state(.{ .tile = 1 }, in) & state_offscreen == 0);
    in.tile_offscreen = true;
    try testing.expect(state(.{ .tile = 3 }, in) & state_offscreen != 0);
    // A button never reads it.
    try testing.expect(state(.{ .button = .send }, in) & state_offscreen == 0);
}
