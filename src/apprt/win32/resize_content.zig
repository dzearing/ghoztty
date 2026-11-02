//! What a terminal does with its content while the window edge is dragged
//! (T2609 step 1): the A/B that says where an edge-drag step's time goes.
//!
//! `GHOZTTY_RESIZE_NO_CONTENT` picks the arm:
//!
//!   unset   - every step resizes the content: grid reflow, renderer
//!             viewport, PTY resize, and a wait for a frame at the new size.
//!   `1`     - the content keeps its pre-drag size under the drag. The pane
//!             window still follows the layout and its uncovered strips are
//!             filled with background (`resize_paint`), but the core is not
//!             told and no frame is waited for. The size lands once, when
//!             the size loop ends.
//!   `empty` - the floor: a pane's resize does nothing at all under the drag,
//!             not even the strip fill, so a step costs only the layout of
//!             the windows and the chrome. The size still lands at the end.
//!
//! Pure, so the parse and the rule are tested without a window.

const std = @import("std");
const testing = std.testing;

pub const Mode = enum { content, held, empty };

pub const env_name = "GHOZTTY_RESIZE_NO_CONTENT";

pub fn parse(value: ?[]const u8) Mode {
    const v = value orelse return .content;
    if (v.len == 0) return .content;
    if (std.ascii.eqlIgnoreCase(v, "empty")) return .empty;
    if (std.mem.eql(u8, v, "0")) return .content;
    return .held;
}

/// What a pane's `WM_SIZE` does now.
pub const Action = enum {
    /// Resize the content, as always.
    apply,
    /// Fill the uncovered strips, keep the size for later, touch nothing else.
    hold,
    /// Keep the size for later and do nothing else.
    skip,
};

pub fn action(mode: Mode, in_size_loop: bool) Action {
    if (!in_size_loop) return .apply;
    return switch (mode) {
        .content => .apply,
        .held => .hold,
        .empty => .skip,
    };
}

test "unset, empty and 0 resize the content; anything else holds it" {
    try testing.expectEqual(Mode.content, parse(null));
    try testing.expectEqual(Mode.content, parse(""));
    try testing.expectEqual(Mode.content, parse("0"));
    try testing.expectEqual(Mode.held, parse("1"));
    try testing.expectEqual(Mode.held, parse("yes"));
    try testing.expectEqual(Mode.empty, parse("empty"));
    try testing.expectEqual(Mode.empty, parse("EMPTY"));
}

test "only a step inside the size loop is held or skipped" {
    try testing.expectEqual(Action.apply, action(.held, false));
    try testing.expectEqual(Action.apply, action(.empty, false));
    try testing.expectEqual(Action.apply, action(.content, true));
    try testing.expectEqual(Action.hold, action(.held, true));
    try testing.expectEqual(Action.skip, action(.empty, true));
}
