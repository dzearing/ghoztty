//! A link is a clickable element that can be used to trigger some action.
//! A link is NOT just a URL that opens in a browser. A link is any generic
//! regular expression match over terminal text that can trigger various
//! action types.
const Link = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const Mods = @import("key.zig").Mods;

/// The regular expression that will be used to match the link. Ownership
/// of this memory is up to the caller. The link will never free this memory.
regex: []const u8,

/// The action that will be triggered when the link is clicked.
action: Action,

/// The situations in which the link will be highlighted. A link is only
/// clickable by the mouse when it is highlighted, so this also controls
/// when the link is clickable.
highlight: Highlight,

pub const Action = union(enum) {
    /// Open the full matched value using the default open program.
    /// For example, on macOS this is "open" and on Linux this is "xdg-open".
    open: void,

    /// Open the OSC8 hyperlink under the mouse position. _-prefixed means
    /// this can't be user-specified, it's only used internally.
    _open_osc8: void,
};

pub const Highlight = union(enum) {
    /// Always highlight the link.
    always: void,

    /// Only highlight the link when the mouse is hovering over it.
    hover: void,

    /// Highlight anytime the given mods are pressed, either when
    /// hovering or always. For always, all links will be highlighted
    /// when the mods are pressed regardless of if the mouse is hovering
    /// over them.
    ///
    /// Note that if "shift" is specified here, this will NEVER match in
    /// TUI programs that capture mouse events. "Shift" with mouse capture
    /// escapes the mouse capture but strips the "shift" so it can't be
    /// detected.
    always_mods: Mods,
    hover_mods: Mods,

    /// True when a mouse holding `mods` meets this highlight's modifier
    /// requirement (position is not considered). Link hover checks this
    /// across every configured link BEFORE it reads the line under the
    /// mouse, so the default ctrl/cmd-hover link costs nothing on a move
    /// without the modifier (T3064, PA-C09).
    pub fn allowsMods(self: Highlight, mods: Mods) bool {
        return switch (self) {
            .always, .hover => true,
            .always_mods, .hover_mods => |v| v.equal(mods),
        };
    }
};

test "Highlight.allowsMods" {
    const testing = std.testing;
    const ctrl: Mods = .{ .ctrl = true };
    const none: Mods = .{};
    try testing.expect((Highlight{ .always = {} }).allowsMods(none));
    try testing.expect((Highlight{ .hover = {} }).allowsMods(ctrl));
    try testing.expect(!(Highlight{ .hover_mods = ctrl }).allowsMods(none));
    try testing.expect((Highlight{ .hover_mods = ctrl }).allowsMods(ctrl));
    try testing.expect(!(Highlight{ .always_mods = ctrl }).allowsMods(.{ .ctrl = true, .shift = true }));
}

/// Returns a new oni.Regex that can be used to match the link.
pub fn oniRegex(self: *const Link) !oni.Regex {
    return try oni.Regex.init(
        self.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
}

/// Deep clone the link.
pub fn clone(self: *const Link, alloc: Allocator) Allocator.Error!Link {
    return .{
        .regex = try alloc.dupe(u8, self.regex),
        .action = self.action,
        .highlight = self.highlight,
    };
}

/// Check if two links are equal.
pub fn equal(self: *const Link, other: *const Link) bool {
    return std.meta.eql(self.action, other.action) and
        std.meta.eql(self.highlight, other.highlight) and
        std.mem.eql(u8, self.regex, other.regex);
}
