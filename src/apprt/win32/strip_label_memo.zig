//! What each tucked pane's strip was last painted saying (T2988).
//!
//! A pane folded into a stack shows its name on a strip (T2109), and that
//! name is its title unless a banner or a user's name outranks it. An agent's
//! spinner changes the title ten times a second, so the window used to
//! repaint ALL of itself - caption, tab strip, desk - on every tick from a
//! pane nobody can see. Now a title change repaints only that strip, and only
//! when the strip would read differently: the paint records the name it put
//! on each strip here, and the title change asks whether the new name is the
//! one already showing.
//!
//! Recorded by the paint, not by the title change, because a banner or a
//! rename changes the strip through other paths: a memo of what the title
//! path last asked for would skip a change the screen never showed.
//!
//! Pure; imports only std. Keyed by the pane's address, compared never
//! dereferenced. A pane freed and another made at the same address with the
//! same name reads "already showing", which it then is.

const std = @import("std");

/// How many strips are remembered. A window rarely tucks more than a handful;
/// past this the oldest entry gives way, which only costs one extra repaint.
pub const capacity = 32;

pub const Memo = struct {
    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    /// The slot the next new key takes once every slot is used.
    next: usize = 0,

    const Entry = struct { id: usize = 0, hash: u64 = 0 };

    /// The strip of pane `id` was just painted saying `text`.
    pub fn record(self: *Memo, id: usize, text: []const u8) void {
        if (id == 0) return;
        const h = hash(text);
        for (&self.entries) |*e| if (e.id == id) {
            e.hash = h;
            return;
        };
        for (&self.entries) |*e| if (e.id == 0) {
            e.* = .{ .id = id, .hash = h };
            return;
        };
        self.entries[self.next] = .{ .id = id, .hash = h };
        self.next = (self.next + 1) % capacity;
    }

    /// Whether pane `id`'s strip was last painted saying `text`: true means
    /// a repaint would draw the same name, so none is owed.
    pub fn shows(self: *const Memo, id: usize, text: []const u8) bool {
        if (id == 0) return false;
        const h = hash(text);
        for (self.entries) |e| if (e.id == id) return e.hash == h;
        return false;
    }

    fn hash(text: []const u8) u64 {
        return std.hash.Wyhash.hash(0x2988, text);
    }
};

test "an unpainted strip is owed a repaint" {
    const m: Memo = .{};
    try std.testing.expect(!m.shows(0x1000, "claude"));
}

test "the same name is already showing; a new one is owed" {
    var m: Memo = .{};
    m.record(0x1000, "⠋ claude working");
    try std.testing.expect(m.shows(0x1000, "⠋ claude working"));
    try std.testing.expect(!m.shows(0x1000, "⠙ claude working"));
    // Another pane's record is not this one's.
    try std.testing.expect(!m.shows(0x2000, "⠋ claude working"));
}

test "a repaint replaces what the strip showed" {
    var m: Memo = .{};
    m.record(0x1000, "a");
    m.record(0x1000, "b");
    try std.testing.expect(m.shows(0x1000, "b"));
    try std.testing.expect(!m.shows(0x1000, "a"));
}

test "a strip whose name changed by another path is not mistaken for current" {
    // Title X painted; a banner then puts Y on the strip and the paint records
    // Y; the title moving to Y is already showing, back to X is owed.
    var m: Memo = .{};
    m.record(0x1000, "X");
    m.record(0x1000, "Y");
    try std.testing.expect(m.shows(0x1000, "Y"));
    try std.testing.expect(!m.shows(0x1000, "X"));
}

test "past capacity the oldest gives way, and is then owed, never wrongly skipped" {
    var m: Memo = .{};
    var i: usize = 1;
    while (i <= capacity) : (i += 1) m.record(i, "n");
    m.record(capacity + 1, "n");
    try std.testing.expect(!m.shows(1, "n"));
    try std.testing.expect(m.shows(2, "n"));
    try std.testing.expect(m.shows(capacity + 1, "n"));
}

test "a null key is never recorded" {
    var m: Memo = .{};
    m.record(0, "x");
    try std.testing.expect(!m.shows(0, "x"));
}
