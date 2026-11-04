//! The one-line text editor the Settings window draws for its search box and
//! a row's value field (T2675) - the pure half: a UTF-8 buffer with a caret.
//!
//! The window paints the field and routes every key itself (the keyboard
//! shortcut guide's search works the same way), so there is no EDIT child to
//! theme and nothing for a cross-process `SetWindowText` to bypass. What a
//! key DOES to the text lives here, with no OS imports, so it is unit tested
//! in every app-runtime lane.
const LineEdit = @This();

const std = @import("std");

pub const capacity = 1024;

buf: [capacity]u8 = undefined,
len: usize = 0,
/// Byte offset of the caret, always on a codepoint boundary.
caret: usize = 0,

pub fn text(self: *const LineEdit) []const u8 {
    return self.buf[0..self.len];
}

/// Replace the whole text (truncated at a codepoint boundary if it does not
/// fit) and put the caret at the end.
pub fn set(self: *LineEdit, value: []const u8) void {
    var n = @min(value.len, capacity);
    while (n > 0 and n < value.len and isContinuation(value[n])) n -= 1;
    @memcpy(self.buf[0..n], value[0..n]);
    self.len = n;
    self.caret = n;
}

pub fn clear(self: *LineEdit) void {
    self.len = 0;
    self.caret = 0;
}

/// Insert UTF-8 at the caret. Line breaks end the insert (a config value is
/// one line); other control characters are dropped. False when nothing fit.
pub fn insert(self: *LineEdit, s: []const u8) bool {
    var inserted = false;
    var view = std.unicode.Utf8View.init(s) catch return false;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (cp.len == 1 and (cp[0] == '\r' or cp[0] == '\n')) break;
        if (cp.len == 1 and (cp[0] < 0x20 or cp[0] == 0x7F)) continue;
        if (self.len + cp.len > capacity) break;
        std.mem.copyBackwards(u8, self.buf[self.caret + cp.len .. self.len + cp.len], self.buf[self.caret..self.len]);
        @memcpy(self.buf[self.caret..][0..cp.len], cp);
        self.len += cp.len;
        self.caret += cp.len;
        inserted = true;
    }
    return inserted;
}

/// Insert one UTF-16 code unit from WM_CHAR. A lone surrogate is dropped.
pub fn insertUnit(self: *LineEdit, unit: u16) bool {
    if (unit >= 0xD800 and unit <= 0xDFFF) return false;
    var enc: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(unit, &enc) catch return false;
    return self.insert(enc[0..n]);
}

/// Delete the codepoint before the caret.
pub fn backspace(self: *LineEdit) bool {
    if (self.caret == 0) return false;
    const start = self.prevBoundary(self.caret);
    self.removeRange(start, self.caret);
    self.caret = start;
    return true;
}

/// Delete the word before the caret (Ctrl+Backspace): trailing spaces, then
/// the run of non-spaces before them.
pub fn backspaceWord(self: *LineEdit) bool {
    if (self.caret == 0) return false;
    var start = self.caret;
    while (start > 0 and self.buf[start - 1] == ' ') start -= 1;
    while (start > 0 and self.buf[start - 1] != ' ') start -= 1;
    self.removeRange(start, self.caret);
    self.caret = start;
    return true;
}

/// Delete the codepoint after the caret.
pub fn delete(self: *LineEdit) bool {
    if (self.caret >= self.len) return false;
    const stop = self.nextBoundary(self.caret);
    self.removeRange(self.caret, stop);
    return true;
}

pub fn left(self: *LineEdit) void {
    self.caret = self.prevBoundary(self.caret);
}

pub fn right(self: *LineEdit) void {
    self.caret = self.nextBoundary(self.caret);
}

pub fn home(self: *LineEdit) void {
    self.caret = 0;
}

pub fn end(self: *LineEdit) void {
    self.caret = self.len;
}

fn removeRange(self: *LineEdit, start: usize, stop: usize) void {
    std.mem.copyForwards(u8, self.buf[start .. self.len - (stop - start)], self.buf[stop..self.len]);
    self.len -= stop - start;
}

fn prevBoundary(self: *const LineEdit, at: usize) usize {
    var i = at;
    while (i > 0) {
        i -= 1;
        if (!isContinuation(self.buf[i])) break;
    }
    return i;
}

fn nextBoundary(self: *const LineEdit, at: usize) usize {
    if (at >= self.len) return self.len;
    var i = at + 1;
    while (i < self.len and isContinuation(self.buf[i])) i += 1;
    return i;
}

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

const testing = std.testing;

test "LineEdit: typing inserts at the caret" {
    var e: LineEdit = .{};
    try testing.expect(e.insert("ac"));
    e.left();
    try testing.expect(e.insert("b"));
    try testing.expectEqualStrings("abc", e.text());
    try testing.expectEqual(@as(usize, 2), e.caret);
}

test "LineEdit: backspace and delete work on codepoints" {
    var e: LineEdit = .{};
    e.set("a\u{00e9}b");
    e.left();
    try testing.expect(e.backspace());
    try testing.expectEqualStrings("ab", e.text());
    e.home();
    try testing.expect(e.delete());
    try testing.expectEqualStrings("b", e.text());
    e.end();
    try testing.expect(!e.delete());
    try testing.expect(e.backspace());
    try testing.expect(!e.backspace());
    try testing.expectEqualStrings("", e.text());
}

test "LineEdit: a line break ends a paste, control characters drop" {
    var e: LineEdit = .{};
    try testing.expect(e.insert("one\ttwo\nthree"));
    try testing.expectEqualStrings("onetwo", e.text());
    try testing.expect(!e.insert("\n"));
}

test "LineEdit: ctrl+backspace removes the last word" {
    var e: LineEdit = .{};
    e.set("font family  ");
    try testing.expect(e.backspaceWord());
    try testing.expectEqualStrings("font ", e.text());
}

test "LineEdit: set truncates on a codepoint boundary" {
    var e: LineEdit = .{};
    var big: [capacity + 1]u8 = undefined;
    @memset(big[0 .. capacity - 1], 'x');
    // A two-byte codepoint straddling the capacity is dropped whole.
    big[capacity - 1] = 0xC3;
    big[capacity] = 0xA9;
    e.set(&big);
    try testing.expectEqual(@as(usize, capacity - 1), e.len);
    try testing.expect(std.unicode.utf8ValidateSlice(e.text()));
}

test "LineEdit: a lone surrogate from WM_CHAR is dropped" {
    var e: LineEdit = .{};
    try testing.expect(!e.insertUnit(0xD83D));
    try testing.expect(e.insertUnit('x'));
    try testing.expectEqualStrings("x", e.text());
}
