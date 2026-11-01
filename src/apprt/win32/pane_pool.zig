//! T2597: closed terminal pane windows parked for the next pane in the same
//! top-level, instead of destroyed. Pure, so the none lane can hold the rules.
//!
//! A PLAIN WGL child (no layer of its own, `pane_layer.zig`) presents into its
//! top-level's redirection surface, and every child that ever ran
//! `SwapBuffers` leaves a top-level-sized GPU allocation behind that only the
//! top-level's destruction frees (T2499: 3 MB a closed pane at the default
//! window size, 8 MB at 1800x1100). The layered child avoids it but its
//! resize shows DWM's black reallocation (T2592), so the plain child is the
//! one worth keeping. Reusing the window bounds the allocations by the most
//! panes the top-level ever held at once, not by how many ever closed.
//!
//! What is parked is the bare HWND: hidden, `GWLP_USERDATA` cleared, its pixel
//! format already set (a window takes one pixel format for life, so the next
//! pane skips `SetPixelFormat`). The GL context is NOT kept; the next pane
//! creates its own on the same DC.
//!
//! `GHOZTTY_PANE_REUSE=0` turns it off, for A/B runs and as an escape hatch.
const std = @import("std");
const builtin = @import("builtin");

/// The environment knob that opts OUT of window reuse. Read per pane.
pub const env_knob = "GHOZTTY_PANE_REUSE";

/// Parked windows a top-level keeps at most. Past it a closed pane's window is
/// destroyed as before, so a window that once held a huge split tree does not
/// keep all of it parked; the allocations are then bounded by this instead.
pub const capacity = 16;

/// Whether the knob's value allows reuse: unset, or anything but
/// "0"/"false"/"off", leaves the default (on).
pub fn knobAllows(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return true, " \t\r\n");
    return !(std.mem.eql(u8, v, "0") or
        std.ascii.eqlIgnoreCase(v, "false") or
        std.ascii.eqlIgnoreCase(v, "off"));
}

pub fn enabled() bool {
    if (comptime builtin.os.tag != .windows) return false;
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, env_knob) catch return true;
    defer std.heap.page_allocator.free(raw);
    return knobAllows(raw);
}

/// What a closing pane knows about its window and the top-level it is in.
pub const Closing = struct {
    /// Reuse is switched on.
    enabled: bool,
    /// The pane is a layered child (`Surface.own_layer`). Its surface dies
    /// with it already, and a layered window must not be handed to a pane
    /// that wants a plain one.
    own_layer: bool,
    /// The top-level is closing: it is about to destroy its children itself,
    /// and a window parked now would be destroyed on the stack that just
    /// deleted the pane's GL context - the T681 crash shape.
    window_closing: bool,
    /// The pane window is still a child of that top-level. A pane re-parented
    /// mid-teardown, or whose top-level is already gone, is reaped instead.
    parent_matches: bool,
};

/// May this closing pane's window be parked rather than reaped?
pub fn mayPark(c: Closing) bool {
    return c.enabled and !c.own_layer and !c.window_closing and c.parent_matches;
}

/// What a parked handle looks like at the moment a new pane wants it. Any
/// leg false and the handle is dropped: a stale posted reap (T681) may have
/// destroyed it, or Win32 recycled it onto something else.
pub const Parked = struct {
    /// Still a window of the terminal class.
    class_matches: bool,
    /// `GWLP_USERDATA` still zero - no live surface has claimed it.
    userdata: usize,
    /// Still a child of the top-level that parked it.
    parent_matches: bool,
};

pub fn reusable(p: Parked) bool {
    return p.class_matches and p.userdata == 0 and p.parent_matches;
}

/// A LIFO of parked handles. `H` is the handle type (`w32.HWND` in the app,
/// an integer in the tests).
pub fn Pool(comptime H: type) type {
    return struct {
        const Self = @This();

        items: [capacity]H = undefined,
        len: usize = 0,

        /// Park `h`. False when full: the caller reaps it as before.
        pub fn give(self: *Self, h: H) bool {
            if (self.len >= capacity) return false;
            for (self.items[0..self.len]) |x| if (x == h) return true;
            self.items[self.len] = h;
            self.len += 1;
            return true;
        }

        /// The most recently parked handle, or null.
        pub fn take(self: *Self) ?H {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.items[self.len];
        }

        /// Forget `h` if it is parked (it was destroyed, or re-parented).
        pub fn remove(self: *Self, h: H) void {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.items[i] == h) {
                    self.items[i] = self.items[self.len - 1];
                    self.len -= 1;
                    return;
                }
            }
        }

        /// Everything parked, emptied out: what the top-level destroys when it
        /// no longer wants them.
        pub fn drain(self: *Self) []const H {
            const out = self.items[0..self.len];
            self.len = 0;
            return out;
        }
    };
}

test "knobAllows is on unless the knob says off" {
    try std.testing.expect(knobAllows(null));
    try std.testing.expect(knobAllows("1"));
    try std.testing.expect(!knobAllows("0"));
    try std.testing.expect(!knobAllows(" Off\r\n"));
    try std.testing.expect(!knobAllows("false"));
}

test "only a plain child of a live, open top-level is parked" {
    const ok: Closing = .{ .enabled = true, .own_layer = false, .window_closing = false, .parent_matches = true };
    try std.testing.expect(mayPark(ok));
    var c = ok;
    c.enabled = false;
    try std.testing.expect(!mayPark(c));
    c = ok;
    c.own_layer = true;
    try std.testing.expect(!mayPark(c));
    c = ok;
    c.window_closing = true;
    try std.testing.expect(!mayPark(c));
    c = ok;
    c.parent_matches = false;
    try std.testing.expect(!mayPark(c));
}

test "a parked handle is reused only while still ours" {
    try std.testing.expect(reusable(.{ .class_matches = true, .userdata = 0, .parent_matches = true }));
    try std.testing.expect(!reusable(.{ .class_matches = false, .userdata = 0, .parent_matches = true }));
    try std.testing.expect(!reusable(.{ .class_matches = true, .userdata = 0x1000, .parent_matches = true }));
    try std.testing.expect(!reusable(.{ .class_matches = true, .userdata = 0, .parent_matches = false }));
}

test "pool is LIFO, bounded, deduplicated, and drains empty" {
    var p: Pool(usize) = .{};
    try std.testing.expectEqual(@as(?usize, null), p.take());
    try std.testing.expect(p.give(1));
    try std.testing.expect(p.give(2));
    try std.testing.expect(p.give(2));
    try std.testing.expectEqual(@as(usize, 2), p.len);
    try std.testing.expectEqual(@as(?usize, 2), p.take());
    try std.testing.expectEqual(@as(?usize, 1), p.take());
    try std.testing.expectEqual(@as(?usize, null), p.take());

    var i: usize = 0;
    while (i < capacity) : (i += 1) try std.testing.expect(p.give(100 + i));
    try std.testing.expect(!p.give(999));
    p.remove(100);
    try std.testing.expectEqual(@as(usize, capacity - 1), p.len);
    try std.testing.expect(p.give(999));
    const all = p.drain();
    try std.testing.expectEqual(@as(usize, capacity), all.len);
    try std.testing.expectEqual(@as(usize, 0), p.len);
}
