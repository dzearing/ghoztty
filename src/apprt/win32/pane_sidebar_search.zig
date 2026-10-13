//! The pane sidebar's all-windows search field on Windows - its editing model
//! (T1877; Mac 7855941f7, e898f5a00: `PaneSidebarSearchField`).
//!
//! Mac's field is a borderless `NSTextField` in a soft capsule under the
//! header: a magnifier, a "Search" placeholder, a clear button once there is a
//! query. Return goes to the first hit, as clicking it would; Escape clears
//! the query, and on an empty field gives the caret back. Only the all-windows
//! scope has one, and only the panel and the open card - the rail has no room.
//!
//! The field is painted by `PaneSidebar.zig` rather than being a native EDIT:
//! the open card is a layered popup fed through `UpdateLayeredWindow`
//! (T1865), and a child control of such a window never reaches the screen. One
//! painted field serves both surfaces, so the panel's and the card's cannot
//! drift apart. What it edits - a single line of UTF-16, a caret, the keys a
//! one-line text box answers - is this file, unit-tested in every lane. The
//! search rules themselves are `pane_sidebar_outline.matches`.

const std = @import("std");

/// UTF-16 units the field holds. A query is a few words; this is room for a
/// pasted path with some to spare.
pub const cap: usize = 128;

pub const Move = enum { left, right, home, end, word_left, word_right };

pub const Field = struct {
    buf: [cap]u16 = undefined,
    len: usize = 0,
    caret: usize = 0,

    pub fn text(self: *const Field) []const u16 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const Field) bool {
        return self.len == 0;
    }

    /// Empty the field. True when anything changed.
    pub fn clear(self: *Field) bool {
        const changed = self.len != 0 or self.caret != 0;
        self.len = 0;
        self.caret = 0;
        return changed;
    }

    /// Insert typed or pasted text at the caret. One line: a tab or line
    /// break becomes a space (a pasted path with a trailing newline still
    /// searches), every other control character is dropped, and what does not
    /// fit is cut at a character boundary. True when anything was inserted.
    pub fn insert(self: *Field, units: []const u16) bool {
        var changed = false;
        var i: usize = 0;
        while (i < units.len) : (i += 1) {
            var u = units[i];
            if (u == '\t' or u == '\r' or u == '\n') u = ' ' else if (u < 0x20 or u == 0x7F) continue;
            // A surrogate pair goes in whole or not at all.
            const pair = isHigh(u) and i + 1 < units.len and isLow(units[i + 1]);
            const need: usize = if (pair) 2 else 1;
            if (self.len + need > cap) break;
            std.mem.copyBackwards(u16, self.buf[self.caret + need .. self.len + need], self.buf[self.caret..self.len]);
            self.buf[self.caret] = u;
            if (pair) {
                self.buf[self.caret + 1] = units[i + 1];
                i += 1;
            }
            self.caret += need;
            self.len += need;
            changed = true;
        }
        return changed;
    }

    /// Backspace: the character before the caret, or (`word`, Ctrl) back to
    /// the start of the word. True when anything was removed.
    pub fn backspace(self: *Field, word: bool) bool {
        if (self.caret == 0) return false;
        const from = if (word) self.wordLeft() else self.charLeft();
        self.remove(from, self.caret);
        self.caret = from;
        return true;
    }

    /// Delete: the character after the caret, or to the end of the word.
    pub fn delete(self: *Field, word: bool) bool {
        if (self.caret == self.len) return false;
        const to = if (word) self.wordRight() else self.charRight();
        self.remove(self.caret, to);
        return true;
    }

    /// Move the caret. True when it moved.
    pub fn move(self: *Field, m: Move) bool {
        const to = switch (m) {
            .left => self.charLeft(),
            .right => self.charRight(),
            .home => 0,
            .end => self.len,
            .word_left => self.wordLeft(),
            .word_right => self.wordRight(),
        };
        if (to == self.caret) return false;
        self.caret = to;
        return true;
    }

    /// Put the caret at `at` (clamped, never inside a surrogate pair).
    pub fn setCaret(self: *Field, at: usize) void {
        var c = @min(at, self.len);
        if (c > 0 and c < self.len and isLow(self.buf[c]) and isHigh(self.buf[c - 1])) c -= 1;
        self.caret = c;
    }

    /// The query as UTF-8 for the search rules. An unpaired surrogate is
    /// dropped rather than failing the whole query.
    pub fn utf8(self: *const Field, out: []u8) []const u8 {
        var n: usize = 0;
        var it = std.unicode.Utf16LeIterator.init(self.text());
        while (true) {
            const cp = it.nextCodepoint() catch continue orelse break;
            const len = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
            if (n + len > out.len) break;
            _ = std.unicode.utf8Encode(cp, out[n .. n + len]) catch continue;
            n += len;
        }
        return out[0..n];
    }

    fn remove(self: *Field, from: usize, to: usize) void {
        std.mem.copyForwards(u16, self.buf[from .. self.len - (to - from)], self.buf[to..self.len]);
        self.len -= to - from;
    }

    fn charLeft(self: *const Field) usize {
        if (self.caret == 0) return 0;
        if (self.caret >= 2 and isLow(self.buf[self.caret - 1]) and isHigh(self.buf[self.caret - 2])) return self.caret - 2;
        return self.caret - 1;
    }

    fn charRight(self: *const Field) usize {
        if (self.caret == self.len) return self.len;
        if (self.caret + 1 < self.len and isHigh(self.buf[self.caret]) and isLow(self.buf[self.caret + 1])) return self.caret + 2;
        return self.caret + 1;
    }

    /// The Windows text-box word step: skip spaces, then the word.
    fn wordLeft(self: *const Field) usize {
        var c = self.caret;
        while (c > 0 and self.buf[c - 1] == ' ') c -= 1;
        while (c > 0 and self.buf[c - 1] != ' ') c -= 1;
        return c;
    }

    fn wordRight(self: *const Field) usize {
        var c = self.caret;
        while (c < self.len and self.buf[c] != ' ') c += 1;
        while (c < self.len and self.buf[c] == ' ') c += 1;
        return c;
    }
};

fn isHigh(u: u16) bool {
    return u >= 0xD800 and u <= 0xDBFF;
}

fn isLow(u: u16) bool {
    return u >= 0xDC00 and u <= 0xDFFF;
}

/// What Escape does in the field (Mac `cancelOperation`): clear a query, or -
/// on an empty field - give the caret back to the pane it came from.
pub const EscapeVerb = enum { clear, release };

pub fn escapeVerb(empty: bool) EscapeVerb {
    return if (empty) .release else .clear;
}

/// Whether the outline is filtered: a query, in the all-windows scope, on a
/// surface that shows the field - the panel, or the open card. The rail has
/// no field, so it never filters (Mac `searchMatches`: "nil ... the rail").
pub fn filters(has_query: bool, all_windows: bool, expanded: bool, card_open: bool) bool {
    return has_query and all_windows and (expanded or card_open);
}

/// The text's horizontal scroll so the caret stays in view: zero until the
/// caret would pass the field's right edge, then just enough to keep it there.
pub fn scrollFor(caret_x: i32, avail: i32) i32 {
    return @max(0, caret_x - @max(avail, 0));
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

fn expectText(f: *const Field, want: []const u8) !void {
    var b: [cap * 3]u8 = undefined;
    try testing.expectEqualStrings(want, f.utf8(&b));
}

test "search field: typing inserts at the caret, backspace and delete remove" {
    var f: Field = .{};
    try testing.expect(f.insert(L("ghoz")));
    try testing.expect(f.insert(L("tty")));
    try expectText(&f, "ghoztty");
    try testing.expectEqual(@as(usize, 7), f.caret);
    _ = f.move(.home);
    try testing.expect(f.insert(L("x ")));
    try expectText(&f, "x ghoztty");
    try testing.expect(f.backspace(false));
    try expectText(&f, "xghoztty");
    try testing.expect(f.delete(false));
    try expectText(&f, "xhoztty");
    _ = f.move(.end);
    try testing.expect(!f.delete(false)); // nothing after the caret
    try testing.expect(f.clear());
    try testing.expect(f.isEmpty());
    try testing.expect(!f.backspace(false)); // nothing before it
    try testing.expect(!f.clear());
}

test "search field: one line - breaks and tabs become spaces, controls vanish" {
    var f: Field = .{};
    try testing.expect(f.insert(L("a\tb\r\nc\x1b\x08d")));
    try expectText(&f, "a b  cd");
    // The Return / Escape a key press also delivers as a character insert
    // nothing.
    var g: Field = .{};
    try testing.expect(!g.insert(L("\x1b")));
    try testing.expect(g.isEmpty());
}

test "search field: word steps and Ctrl+Backspace" {
    var f: Field = .{};
    _ = f.insert(L("ghoztty  pane sidebar"));
    try testing.expect(f.backspace(true));
    try expectText(&f, "ghoztty  pane ");
    try testing.expect(f.backspace(true));
    try expectText(&f, "ghoztty  ");
    _ = f.move(.home);
    _ = f.move(.word_right);
    try testing.expectEqual(@as(usize, 9), f.caret);
    _ = f.move(.word_left);
    try testing.expectEqual(@as(usize, 0), f.caret);
    try testing.expect(f.delete(true));
    try expectText(&f, "");
}

test "search field: a surrogate pair is one character to every key" {
    var f: Field = .{};
    _ = f.insert(L("a\u{1F47B}b"));
    try testing.expectEqual(@as(usize, 4), f.len);
    _ = f.move(.left); // over b
    _ = f.move(.left); // over the ghost, both units
    try testing.expectEqual(@as(usize, 1), f.caret);
    _ = f.move(.right);
    try testing.expectEqual(@as(usize, 3), f.caret);
    try testing.expect(f.backspace(false));
    try expectText(&f, "ab");
    f.setCaret(99);
    try testing.expectEqual(@as(usize, 2), f.caret);
    var g: Field = .{};
    _ = g.insert(L("\u{1F47B}"));
    g.setCaret(1); // mid-pair snaps back
    try testing.expectEqual(@as(usize, 0), g.caret);
}

test "search field: a full field cuts at a character, never mid-pair" {
    var f: Field = .{};
    var long: [cap]u16 = undefined;
    @memset(&long, 'x');
    _ = f.insert(long[0 .. cap - 1]);
    try testing.expect(!f.insert(L("\u{1F47B}"))); // two units, one slot
    try testing.expect(f.insert(L("y")));
    try testing.expectEqual(cap, f.len);
    try testing.expect(!f.insert(L("z")));
}

test "search field: Escape clears a query, then gives the caret back" {
    try testing.expectEqual(EscapeVerb.clear, escapeVerb(false));
    try testing.expectEqual(EscapeVerb.release, escapeVerb(true));
}

test "search field: only the panel and the open card filter, and only all-windows" {
    try testing.expect(filters(true, true, true, false));
    try testing.expect(filters(true, true, false, true));
    try testing.expect(!filters(true, true, false, false)); // the rail
    try testing.expect(!filters(true, false, true, false)); // this window only
    try testing.expect(!filters(false, true, true, true)); // no query
}

test "search field: the text scrolls only once the caret passes the edge" {
    try testing.expectEqual(@as(i32, 0), scrollFor(40, 100));
    try testing.expectEqual(@as(i32, 0), scrollFor(100, 100));
    try testing.expectEqual(@as(i32, 20), scrollFor(120, 100));
    try testing.expectEqual(@as(i32, 5), scrollFor(5, -3));
}
