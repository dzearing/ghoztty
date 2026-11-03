//! The text of a Ghostty config file, edited surgically (T2583; the win32
//! port of Mac `ConfigFileText.swift`, 92103f39d).
//!
//! The Settings window never rewrites the config from parsed state: it
//! changes only the lines for the key being set and leaves every other byte —
//! comments, blank lines, ordering, `config-file` includes, keys it doesn't
//! know, line endings, a BOM — exactly as the user wrote them.
//!
//! The grammar mirrors `LineIterator` in `src/cli/args.zig`: a line is
//! trimmed (spaces, tabs, CR); blank lines and lines starting with `#` are
//! ignored; `key = value` sets a key (the value trimmed, one pair of outer
//! double quotes stripped); a bare `key` is the flag form (`--key`). There are
//! no sections — conditional values live inside a value
//! (`theme = light:A,dark:B`). For a plain key the LAST line wins; for a
//! repeatable key (`keybind`, `font-family`, `palette`, …) every line adds a
//! value and an empty value resets the list.
//!
//! Pure logic, no OS imports: its tests run in every app-runtime lane. All
//! text is owned by an internal arena, so an edit's old strings live until
//! `deinit` — fine for a value that lives for one Settings action.
const ConfigFileText = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Ending = enum {
    lf,
    crlf,
    /// A last line with no newline.
    none,

    pub fn bytes(self: Ending) []const u8 {
        return switch (self) {
            .lf => "\n",
            .crlf => "\r\n",
            .none => "",
        };
    }
};

pub const Line = struct {
    text: []const u8,
    ending: Ending,
};

/// A line that sets a key.
pub const Entry = struct {
    index: usize,
    key: []const u8,
    /// The value as Ghostty reads it (trimmed, outer quotes stripped).
    /// `null` for the bare flag form.
    value: ?[]const u8,
};

pub const Parsed = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const EditError = error{
    /// The value contains a line break.
    Multiline,
    /// The rendered line is longer than Ghostty reads (`max_line_bytes`).
    LineTooLong,
} || Allocator.Error;

/// Ghostty's `LineIterator.MAX_LINE_SIZE`, less the `--` it prepends.
pub const max_line_bytes = 4094;

const bom_bytes = "\u{FEFF}";

/// Ghostty trims spaces, tabs and CR around a line (`whitespace ++ "\r"`).
const line_whitespace = " \t\r";

arena: std.heap.ArenaAllocator,
lines: std.ArrayListUnmanaged(Line),
/// The newline new lines get: the file's own (CRLF if most lines use it).
newline: Ending,
/// A UTF-8 byte-order mark the file started with, written back as-is.
bom: bool,

pub fn init(gpa: Allocator, contents: []const u8) Allocator.Error!ConfigFileText {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const bom = std.mem.startsWith(u8, contents, bom_bytes);
    const owned = try alloc.dupe(u8, if (bom) contents[bom_bytes.len..] else contents);

    // Split on "\n" only, as Ghostty does: a lone "\r" stays part of its
    // line's text, while "\r\n" is recognized as one ending.
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var crlf: usize = 0;
    var lf: usize = 0;
    var rest: []const u8 = owned;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        var text = rest[0..nl];
        var ending: Ending = .lf;
        if (text.len > 0 and text[text.len - 1] == '\r') {
            text = text[0 .. text.len - 1];
            ending = .crlf;
            crlf += 1;
        } else lf += 1;
        try lines.append(alloc, .{ .text = text, .ending = ending });
        rest = rest[nl + 1 ..];
    }
    if (rest.len > 0) try lines.append(alloc, .{ .text = rest, .ending = .none });

    return .{
        .arena = arena,
        .lines = lines,
        .newline = if (crlf > lf) .crlf else .lf,
        .bom = bom,
    };
}

pub fn deinit(self: *ConfigFileText) void {
    self.arena.deinit();
    self.* = undefined;
}

/// An independent copy (its own arena).
pub fn clone(self: *const ConfigFileText, gpa: Allocator) Allocator.Error!ConfigFileText {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var lines: std.ArrayListUnmanaged(Line) = try .initCapacity(alloc, self.lines.items.len);
    for (self.lines.items) |line| lines.appendAssumeCapacity(.{
        .text = try alloc.dupe(u8, line.text),
        .ending = line.ending,
    });
    return .{ .arena = arena, .lines = lines, .newline = self.newline, .bom = self.bom };
}

/// Replace this text with a copy of `other` (keeps this value's arena).
pub fn replaceWith(self: *ConfigFileText, other: *const ConfigFileText) Allocator.Error!void {
    const alloc = self.arena.allocator();
    var lines: std.ArrayListUnmanaged(Line) = try .initCapacity(alloc, other.lines.items.len);
    for (other.lines.items) |line| lines.appendAssumeCapacity(.{
        .text = try alloc.dupe(u8, line.text),
        .ending = line.ending,
    });
    self.lines = lines;
    self.newline = other.newline;
    self.bom = other.bom;
}

pub fn eql(a: *const ConfigFileText, b: *const ConfigFileText) bool {
    if (a.bom != b.bom or a.newline != b.newline) return false;
    if (a.lines.items.len != b.lines.items.len) return false;
    for (a.lines.items, b.lines.items) |x, y| {
        if (x.ending != y.ending or !std.mem.eql(u8, x.text, y.text)) return false;
    }
    return true;
}

/// The file's bytes. Caller owns the result.
pub fn string(self: *const ConfigFileText, alloc: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    if (self.bom) try out.appendSlice(alloc, bom_bytes);
    for (self.lines.items) |line| {
        try out.appendSlice(alloc, line.text);
        try out.appendSlice(alloc, line.ending.bytes());
    }
    return out.toOwnedSlice(alloc);
}

// Reading

/// Parse one line the way Ghostty does. `null` for blank lines and comments.
/// The result slices into `line`.
pub fn parse(line: []const u8) ?Parsed {
    const trimmed = std.mem.trim(u8, line, line_whitespace);
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse
        return .{ .key = trimmed, .value = null };
    const key = std.mem.trim(u8, trimmed[0..eq], line_whitespace);
    var val = std.mem.trim(u8, trimmed[eq + 1 ..], line_whitespace);
    if (isQuoted(val)) val = val[1 .. val.len - 1];
    return .{ .key = key, .value = val };
}

fn isQuoted(val: []const u8) bool {
    return val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"';
}

fn entryAt(self: *const ConfigFileText, index: usize) ?Entry {
    const p = parse(self.lines.items[index].text) orelse return null;
    return .{ .index = index, .key = p.key, .value = p.value };
}

/// Every line that sets a key, in order. Caller owns the slice.
pub fn entries(self: *const ConfigFileText, alloc: Allocator) Allocator.Error![]Entry {
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer out.deinit(alloc);
    for (0..self.lines.items.len) |i| {
        if (self.entryAt(i)) |e| try out.append(alloc, e);
    }
    return out.toOwnedSlice(alloc);
}

/// The lines that set `key`, in order. Caller owns the slice.
pub fn entriesFor(self: *const ConfigFileText, alloc: Allocator, key: []const u8) Allocator.Error![]Entry {
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer out.deinit(alloc);
    for (0..self.lines.items.len) |i| {
        const e = self.entryAt(i) orelse continue;
        if (std.mem.eql(u8, e.key, key)) try out.append(alloc, e);
    }
    return out.toOwnedSlice(alloc);
}

fn lastEntry(self: *const ConfigFileText, key: []const u8) ?Entry {
    var i = self.lines.items.len;
    while (i > 0) {
        i -= 1;
        const e = self.entryAt(i) orelse continue;
        if (std.mem.eql(u8, e.key, key)) return e;
    }
    return null;
}

/// The value the file gives a plain key (its last line), if it sets it:
/// `null` when unset, `@as(?[]const u8, null)` for the bare flag form.
pub fn value(self: *const ConfigFileText, key: []const u8) ??[]const u8 {
    const last = self.lastEntry(key) orelse return null;
    return last.value;
}

/// The values the file adds for a repeatable key, in order, honoring an
/// empty-value reset (only the values after the last reset count). The
/// strings slice into this text; caller owns the outer slice.
pub fn values(self: *const ConfigFileText, alloc: Allocator, key: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(alloc);
    for (0..self.lines.items.len) |i| {
        const e = self.entryAt(i) orelse continue;
        if (!std.mem.eql(u8, e.key, key)) continue;
        const v = e.value orelse "";
        if (v.len == 0) out.clearRetainingCapacity() else try out.append(alloc, v);
    }
    return out.toOwnedSlice(alloc);
}

// Editing

/// Set a plain (non-repeatable) key. Rewrites the LAST line that sets it
/// (the one Ghostty honors), keeping its indentation, and leaves earlier
/// lines alone — they are already overridden. Appends if the key is unset.
pub fn set(self: *ConfigFileText, key: []const u8, val: []const u8) EditError!void {
    const alloc = self.arena.allocator();
    const line = try render(alloc, key, val);
    if (self.lastEntry(key)) |last| {
        self.lines.items[last.index].text = try self.indented(last.index, line);
    } else {
        try self.append(&.{line});
    }
}

/// Remove every line that sets `key`, so it goes back to its default.
pub fn remove(self: *ConfigFileText, key: []const u8) Allocator.Error!void {
    const alloc = self.arena.allocator();
    const existing = try self.entriesFor(alloc, key);
    const indices = try alloc.alloc(usize, existing.len);
    for (existing, indices) |e, *i| i.* = e.index;
    try self.removeLines(indices);
}

/// Make a repeatable key's lines produce exactly `vals`, with the smallest
/// change: the longest run of existing lines that already matches `vals` in
/// order stays untouched (and so do the comments between them), other lines
/// for the key are removed, and each new value goes just before the next
/// kept line — or after the last kept one, where the key first appeared, or
/// at the end.
pub fn setList(self: *ConfigFileText, key: []const u8, vals: []const []const u8) EditError!void {
    const alloc = self.arena.allocator();
    const rendered = try alloc.alloc([]const u8, vals.len);
    for (vals, rendered) |v, *r| r.* = try render(alloc, key, v);

    const existing = try self.entriesFor(alloc, key);
    const existing_values = try alloc.alloc([]const u8, existing.len);
    for (existing, existing_values) |e, *v| v.* = e.value orelse "";
    const matched = try longestCommonSubsequence(alloc, existing_values, vals);
    const indent: []const u8 = if (existing.len > 0) indentation(self.lines.items[existing[0].index].text) else "";

    const n = self.lines.items.len;
    const Bucket = std.ArrayListUnmanaged([]const u8);
    const before = try alloc.alloc(Bucket, n); // line index → new lines inserted before it
    const after = try alloc.alloc(Bucket, n); // line index → new lines inserted after it
    @memset(before, .empty);
    @memset(after, .empty);
    var at_end: Bucket = .empty;

    const kept_value = try alloc.alloc(bool, vals.len);
    @memset(kept_value, false);
    for (matched) |m| kept_value[m.b] = true;

    for (rendered, 0..) |line, j| {
        if (kept_value[j]) continue;
        const next: ?Pair = for (matched) |m| {
            if (m.b > j) break m;
        } else null;
        if (next) |m| {
            try before[existing[m.a].index].append(alloc, try concat(alloc, indent, line));
        } else if (matched.len > 0) {
            try after[existing[matched[matched.len - 1].a].index].append(alloc, try concat(alloc, indent, line));
        } else if (existing.len > 0) {
            try before[existing[0].index].append(alloc, try concat(alloc, indent, line));
        } else {
            try at_end.append(alloc, line);
        }
    }

    const removed = try alloc.alloc(bool, n);
    @memset(removed, false);
    for (existing) |e| removed[e.index] = true;
    for (matched) |m| removed[existing[m.a].index] = false;

    const terminated = if (self.lines.items.len > 0) self.lines.items[n - 1].ending != .none else true;
    var out: std.ArrayListUnmanaged(Line) = .empty;
    for (self.lines.items, 0..) |line, index| {
        for (before[index].items) |t| try out.append(alloc, .{ .text = t, .ending = self.newline });
        if (!removed[index]) {
            var l = line;
            if (l.ending == .none) l.ending = self.newline;
            try out.append(alloc, l);
        }
        for (after[index].items) |t| try out.append(alloc, .{ .text = t, .ending = self.newline });
    }
    for (at_end.items) |t| try out.append(alloc, .{ .text = t, .ending = self.newline });
    if (!terminated and out.items.len > 0) out.items[out.items.len - 1].ending = .none;
    self.lines = out;
}

const Pair = struct { a: usize, b: usize };

/// Index pairs (into `a`, into `b`) of a longest common subsequence.
fn longestCommonSubsequence(alloc: Allocator, a: []const []const u8, b: []const []const u8) Allocator.Error![]Pair {
    if (a.len == 0 or b.len == 0) return &.{};
    const w = b.len + 1;
    const table = try alloc.alloc(usize, (a.len + 1) * w);
    @memset(table, 0);
    var i = a.len;
    while (i > 0) {
        i -= 1;
        var j = b.len;
        while (j > 0) {
            j -= 1;
            table[i * w + j] = if (std.mem.eql(u8, a[i], b[j]))
                table[(i + 1) * w + j + 1] + 1
            else
                @max(table[(i + 1) * w + j], table[i * w + j + 1]);
        }
    }
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    i = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.mem.eql(u8, a[i], b[j])) {
            try pairs.append(alloc, .{ .a = i, .b = j });
            i += 1;
            j += 1;
        } else if (table[(i + 1) * w + j] >= table[i * w + j + 1]) {
            i += 1;
        } else {
            j += 1;
        }
    }
    return pairs.items;
}

/// How a keyed repeatable entry's subkey is found and compared.
pub const KeyedOptions = struct {
    /// Extract (and normalize) an entry's subkey; `null` if it has none.
    subkeyOf: *const fn (Allocator, []const u8) Allocator.Error!?[]const u8 = subkeyBeforeEqualsAlloc,
    /// The same normalization, applied to the subkey being set.
    normalize: *const fn (Allocator, []const u8) Allocator.Error![]const u8 = identity,
};

/// Set (or with `rest == null`, remove) one keyed entry of a repeatable key
/// whose values are `subkey=rest` — a `keybind` trigger, a `palette` index,
/// an `env` name. `opts.subkeyOf` extracts (and normalizes) an entry's
/// subkey, so `cmd+k` and `super+k` can be the same keybind;
/// `opts.normalize` must apply the same normalization to `subkey`. The last
/// matching line is rewritten in place and earlier matches removed; with no
/// match the new line goes after the key's last line, or at the end.
pub fn setKeyed(
    self: *ConfigFileText,
    key: []const u8,
    subkey: []const u8,
    rest: ?[]const u8,
    opts: KeyedOptions,
) EditError!void {
    const alloc = self.arena.allocator();
    const target = try opts.normalize(alloc, subkey);
    const of_key = try self.entriesFor(alloc, key);
    var matches: std.ArrayListUnmanaged(usize) = .empty;
    for (of_key) |e| {
        const v = e.value orelse continue;
        const sk = (try opts.subkeyOf(alloc, v)) orelse continue;
        if (std.mem.eql(u8, sk, target)) try matches.append(alloc, e.index);
    }
    const r = rest orelse return self.removeLines(matches.items);
    const line = try render(alloc, key, try std.fmt.allocPrint(alloc, "{s}={s}", .{ subkey, r }));
    if (matches.items.len > 0) {
        const last = matches.items[matches.items.len - 1];
        self.lines.items[last].text = try self.indented(last, line);
        try self.removeLines(matches.items[0 .. matches.items.len - 1]);
    } else if (of_key.len > 0) {
        const last = of_key[of_key.len - 1].index;
        try self.insert(&.{try self.indented(last, line)}, last + 1);
    } else {
        try self.append(&.{line});
    }
}

/// Add one value to a repeatable key, after its last line (or at the end).
pub fn add(self: *ConfigFileText, key: []const u8, val: []const u8) EditError!void {
    const alloc = self.arena.allocator();
    const line = try render(alloc, key, val);
    if (self.lastEntry(key)) |last| {
        try self.insert(&.{try self.indented(last.index, line)}, last.index + 1);
    } else {
        try self.append(&.{line});
    }
}

// Helpers

/// `0=#1d1f21` → `0`, `FOO=bar` → `FOO`: the text before the first `=`.
pub fn subkeyBeforeEquals(val: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, val, '=') orelse return null;
    return std.mem.trim(u8, val[0..eq], line_whitespace);
}

fn subkeyBeforeEqualsAlloc(_: Allocator, val: []const u8) Allocator.Error!?[]const u8 {
    return subkeyBeforeEquals(val);
}

fn identity(_: Allocator, s: []const u8) Allocator.Error![]const u8 {
    return s;
}

/// `key = value`, quoting the value when Ghostty would otherwise change it
/// (surrounding whitespace is trimmed, one pair of outer quotes stripped).
/// Caller owns the result.
pub fn render(alloc: Allocator, key: []const u8, val: []const u8) EditError![]u8 {
    if (hasLineBreak(val)) return error.Multiline;
    const needs_quotes = val.len != std.mem.trim(u8, val, line_whitespace).len or isQuoted(val);
    const line = if (needs_quotes)
        try std.fmt.allocPrint(alloc, "{s} = \"{s}\"", .{ key, val })
    else
        try std.fmt.allocPrint(alloc, "{s} = {s}", .{ key, val });
    if (line.len > max_line_bytes) {
        alloc.free(line);
        return error.LineTooLong;
    }
    return line;
}

/// Swift's `Character.isNewline`: LF, VT, FF, CR, NEL, LS, PS.
fn hasLineBreak(s: []const u8) bool {
    if (std.mem.indexOfAny(u8, s, "\n\x0B\x0C\r") != null) return true;
    return std.mem.indexOf(u8, s, "\u{0085}") != null or
        std.mem.indexOf(u8, s, "\u{2028}") != null or
        std.mem.indexOf(u8, s, "\u{2029}") != null;
}

/// The message the Settings row shows for an edit error.
pub fn message(alloc: Allocator, err: EditError, key: []const u8) Allocator.Error![]u8 {
    return switch (err) {
        error.Multiline => std.fmt.allocPrint(alloc, "A value for {s} can't contain a line break.", .{key}),
        error.LineTooLong => std.fmt.allocPrint(alloc, "The line for {s} would be longer than Ghostty reads (4096 bytes).", .{key}),
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn indentation(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return text[0..i];
}

fn indented(self: *ConfigFileText, index: usize, line: []const u8) Allocator.Error![]const u8 {
    return concat(self.arena.allocator(), indentation(self.lines.items[index].text), line);
}

fn concat(alloc: Allocator, a: []const u8, b: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(alloc, u8, &.{ a, b });
}

fn removeLines(self: *ConfigFileText, indices: []const usize) Allocator.Error!void {
    const sorted = try self.arena.allocator().dupe(usize, indices);
    std.mem.sort(usize, sorted, {}, std.sort.desc(usize));
    for (sorted) |index| {
        const removed = self.lines.orderedRemove(index);
        // Removing the unterminated last line must not leave the new last
        // line with a dangling newline the file didn't have.
        if (index == self.lines.items.len and removed.ending == .none and self.lines.items.len > 0) {
            self.lines.items[self.lines.items.len - 1].ending = .none;
        }
    }
}

fn insert(self: *ConfigFileText, texts: []const []const u8, index: usize) Allocator.Error!void {
    if (index >= self.lines.items.len) return self.append(texts);
    const alloc = self.arena.allocator();
    const new = try alloc.alloc(Line, texts.len);
    for (texts, new) |t, *l| l.* = .{ .text = t, .ending = self.newline };
    try self.lines.insertSlice(alloc, index, new);
}

fn append(self: *ConfigFileText, texts: []const []const u8) Allocator.Error!void {
    if (texts.len == 0) return;
    const alloc = self.arena.allocator();
    // Terminate an unterminated last line first; never glue onto it.
    const items = self.lines.items;
    const had_trailing_newline = if (items.len > 0) items[items.len - 1].ending != .none else true;
    if (items.len > 0 and items[items.len - 1].ending == .none) items[items.len - 1].ending = self.newline;
    for (texts) |t| try self.lines.append(alloc, .{ .text = t, .ending = self.newline });
    if (!had_trailing_newline) self.lines.items[self.lines.items.len - 1].ending = .none;
}

// Tests: a case-for-case port of Mac `ConfigFileTextTests` (the store's
// half lives in ConfigFileStore.zig). Each pins the rule that an edit
// changes only the lines for its key.

const testing = std.testing;

fn open(contents: []const u8) !ConfigFileText {
    return ConfigFileText.init(testing.allocator, contents);
}

fn expectText(file: *const ConfigFileText, expected: []const u8) !void {
    const got = try file.string(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

fn expectParsed(line: []const u8, key: []const u8, val: ?[]const u8) !void {
    const p = parse(line) orelse return error.TestExpectedParsed;
    try testing.expectEqualStrings(key, p.key);
    if (val) |v| try testing.expectEqualStrings(v, p.value orelse return error.TestExpectedValue) else try testing.expect(p.value == null);
}

test "ConfigFileText: parses like Ghostty" {
    try expectParsed("font-size = 14", "font-size", "14");
    try expectParsed("  font-size=14\t\r", "font-size", "14");
    try expectParsed("title = \"  hi  \"", "title", "  hi  ");
    try expectParsed("maximize", "maximize", null);
    try expectParsed("keybind = super+==increase_font_size:1", "keybind", "super+==increase_font_size:1");
    try testing.expect(parse("# font-size = 20") == null);
    try testing.expect(parse("   # indented comment") == null);
    try testing.expect(parse("   ") == null);
}

test "ConfigFileText: round trips untouched bytes" {
    const samples = [_][]const u8{
        "",                  "\n",                    "a = 1",        "a = 1\n", "# c\r\na = 1\r\n", "\u{FEFF}a = 1\n",
        "a = 1\r\n\nb = 2", "x = a\rb\n", "\n\n# only comments\n\n",
        // A lone CR at the very end, and a CR right before a CRLF.
        "a = 1\r",          "a = 1\r\r\n",
    };
    for (samples) |sample| {
        var f = try open(sample);
        defer f.deinit();
        try expectText(&f, sample);
    }
}

test "ConfigFileText: set appends to empty and missing files" {
    var f = try open("");
    defer f.deinit();
    try f.set("font-size", "14");
    try expectText(&f, "font-size = 14\n");
}

test "ConfigFileText: set replaces in place keeping everything else" {
    var f = try open(
        \\# My config — hand written
        \\font-family = JetBrains Mono
        \\
        \\  font-size = 13
        \\config-file = ?work.ghostty
        \\some-future-key = kept as-is
        \\# trailing comment
        \\
    );
    defer f.deinit();
    try f.set("font-size", "15");
    try expectText(&f,
        \\# My config — hand written
        \\font-family = JetBrains Mono
        \\
        \\  font-size = 15
        \\config-file = ?work.ghostty
        \\some-future-key = kept as-is
        \\# trailing comment
        \\
    );
}

test "ConfigFileText: set rewrites only the last occurrence" {
    var f = try open("font-size = 12\n# later\nfont-size = 13\n");
    defer f.deinit();
    try f.set("font-size", "16");
    try expectText(&f, "font-size = 12\n# later\nfont-size = 16\n");
    try testing.expectEqualStrings("16", f.value("font-size").?.?);
}

test "ConfigFileText: set replaces the bare flag form" {
    var f = try open("maximize\n");
    defer f.deinit();
    try testing.expect(f.value("maximize").? == null);
    try f.set("maximize", "false");
    try expectText(&f, "maximize = false\n");
}

test "ConfigFileText: set keeps a missing trailing newline" {
    {
        var f = try open("a = 1");
        defer f.deinit();
        try f.set("b", "2");
        try expectText(&f, "a = 1\nb = 2");
    }
    {
        var f = try open("a = 1");
        defer f.deinit();
        try f.set("a", "3");
        try expectText(&f, "a = 3");
    }
}

test "ConfigFileText: commented-out keys are not touched" {
    var f = try open("# font-size = 20\n");
    defer f.deinit();
    try f.set("font-size", "14");
    try expectText(&f, "# font-size = 20\nfont-size = 14\n");
}

test "ConfigFileText: remove deletes every occurrence" {
    var f = try open("font-size = 12\n# keep me\nmaximize\nfont-size = 13\nmaximize = true\n");
    defer f.deinit();
    try f.remove("font-size");
    try f.remove("maximize");
    try expectText(&f, "# keep me\n");
    try testing.expect(f.value("font-size") == null);
}

test "ConfigFileText: removing the unterminated last line keeps no trailing newline" {
    var f = try open("a = 1\nb = 2");
    defer f.deinit();
    try f.remove("b");
    try expectText(&f, "a = 1");
}

test "ConfigFileText: a conditional theme value is one value" {
    var f = try open("theme = Dracula\n");
    defer f.deinit();
    try f.set("theme", "light:Catppuccin Latte,dark:Catppuccin Mocha");
    try expectText(&f, "theme = light:Catppuccin Latte,dark:Catppuccin Mocha\n");
}

test "ConfigFileText: includes and unknown keys survive edits" {
    const original = "config-file = ?work.ghostty\nconfig-file = theme.conf\nmystery = 1\n";
    var f = try open(original);
    defer f.deinit();
    try f.set("font-size", "14");
    try f.remove("cursor-style");
    try expectText(&f, original ++ "font-size = 14\n");
}

test "ConfigFileText: quotes values Ghostty would otherwise change" {
    const a = testing.allocator;
    const padded = try render(a, "title", " padded ");
    defer a.free(padded);
    try testing.expectEqualStrings("title = \" padded \"", padded);
    const quoted = try render(a, "title", "\"quoted\"");
    defer a.free(quoted);
    try testing.expectEqualStrings("title = \"\"quoted\"\"", quoted);
    const plain = try render(a, "font-family", "JetBrains Mono");
    defer a.free(plain);
    try testing.expectEqualStrings("font-family = JetBrains Mono", plain);

    // …and reading it back gives the value we meant.
    const line = try std.mem.concat(a, u8, &.{ padded, "\n" });
    defer a.free(line);
    var f = try open(line);
    defer f.deinit();
    try testing.expectEqualStrings(" padded ", f.value("title").?.?);
}

test "ConfigFileText: rejects line breaks without changing the file" {
    var f = try open("a = 1\n");
    defer f.deinit();
    try testing.expectError(error.Multiline, f.set("title", "two\nlines"));
    try testing.expectError(error.Multiline, f.set("title", "two\r\nlines"));
    try testing.expectError(error.Multiline, f.set("title", "two\u{2028}lines"));
    try testing.expectError(error.Multiline, f.setList("font-family", &.{ "A", "B\nC" }));
    try expectText(&f, "a = 1\n");
}

test "ConfigFileText: rejects lines Ghostty cannot read" {
    var f = try open("");
    defer f.deinit();
    const long = [_]u8{'x'} ** 5000;
    try testing.expectError(error.LineTooLong, f.set("title", &long));
    try expectText(&f, "");

    // The limit is the line, not the value: exactly max_line_bytes fits.
    const fits = [_]u8{'x'} ** (max_line_bytes - "title = ".len);
    try f.set("title", &fits);
    const over = [_]u8{'x'} ** (max_line_bytes - "title = ".len + 1);
    try testing.expectError(error.LineTooLong, f.set("title", &over));
}

test "ConfigFileText: edit errors have the row's message" {
    const a = testing.allocator;
    const m = try message(a, error.Multiline, "title");
    defer a.free(m);
    try testing.expectEqualStrings("A value for title can't contain a line break.", m);
    const l = try message(a, error.LineTooLong, "title");
    defer a.free(l);
    try testing.expectEqualStrings("The line for title would be longer than Ghostty reads (4096 bytes).", l);
}

test "ConfigFileText: CRLF files stay CRLF" {
    var f = try open("# win\r\nfont-size = 12\r\n\r\ncursor-style = bar\r\n");
    defer f.deinit();
    try f.set("font-size", "14");
    try f.set("theme", "Nord");
    try expectText(&f, "# win\r\nfont-size = 14\r\n\r\ncursor-style = bar\r\ntheme = Nord\r\n");
}

test "ConfigFileText: mixed endings keep each line's own" {
    var f = try open("a = 1\r\nb = 2\nc = 3\n");
    defer f.deinit();
    try f.set("b", "9");
    try expectText(&f, "a = 1\r\nb = 9\nc = 3\n");
}

test "ConfigFileText: BOM is preserved" {
    var f = try open("\u{FEFF}a = 1\n");
    defer f.deinit();
    try f.set("a", "2");
    try expectText(&f, "\u{FEFF}a = 2\n");
    // The BOM is not part of the first key.
    try testing.expectEqualStrings("2", f.value("a").?.?);
}

test "ConfigFileText: values honor an empty reset" {
    var f = try open("font-family = A\nfont-family =\nfont-family = B\nfont-family = C\n");
    defer f.deinit();
    const vals = try f.values(testing.allocator, "font-family");
    defer testing.allocator.free(vals);
    try testing.expectEqual(@as(usize, 2), vals.len);
    try testing.expectEqualStrings("B", vals[0]);
    try testing.expectEqualStrings("C", vals[1]);
}

test "ConfigFileText: setList keeps matching lines and interleaved comments" {
    var f = try open(
        \\font-family = JetBrains Mono
        \\# fallback for symbols
        \\font-family = Symbols Nerd Font
        \\font-size = 13
        \\
    );
    defer f.deinit();
    // Replace the primary font, keep the fallback line (and its comment).
    try f.setList("font-family", &.{ "Fira Code", "Symbols Nerd Font" });
    try expectText(&f,
        \\# fallback for symbols
        \\font-family = Fira Code
        \\font-family = Symbols Nerd Font
        \\font-size = 13
        \\
    );
    const vals = try f.values(testing.allocator, "font-family");
    defer testing.allocator.free(vals);
    try testing.expectEqual(@as(usize, 2), vals.len);
    try testing.expectEqualStrings("Fira Code", vals[0]);
    try testing.expectEqualStrings("Symbols Nerd Font", vals[1]);
}

test "ConfigFileText: setList reorders with the fewest moved lines" {
    var f = try open("font-family = A\nfont-family = B\nfont-family = C\n");
    defer f.deinit();
    try f.setList("font-family", &.{ "B", "C", "A" });
    try expectText(&f, "font-family = B\nfont-family = C\nfont-family = A\n");
}

test "ConfigFileText: setList keeps a missing trailing newline" {
    {
        var f = try open("font-family = A");
        defer f.deinit();
        try f.setList("font-family", &.{ "A", "B" });
        try expectText(&f, "font-family = A\nfont-family = B");
    }
    {
        var f = try open("x = 1\nfont-family = A");
        defer f.deinit();
        try f.setList("font-family", &.{});
        try expectText(&f, "x = 1");
    }
}

test "ConfigFileText: setList adds after the last kept line" {
    var f = try open("font-feature = -calt\nfont-size = 13\n");
    defer f.deinit();
    try f.setList("font-feature", &.{ "-calt", "ss01" });
    try expectText(&f, "font-feature = -calt\nfont-feature = ss01\nfont-size = 13\n");
}

test "ConfigFileText: setList replaces in place when nothing is kept" {
    var f = try open("# top\nfont-feature = -calt\nfont-size = 13\n");
    defer f.deinit();
    try f.setList("font-feature", &.{"ss02"});
    try expectText(&f, "# top\nfont-feature = ss02\nfont-size = 13\n");
}

test "ConfigFileText: setList empty removes the key" {
    var f = try open("font-feature = -calt\n# x\nfont-feature = ss01\n");
    defer f.deinit();
    try f.setList("font-feature", &.{});
    try expectText(&f, "# x\n");
}

test "ConfigFileText: setList appends a new key" {
    var f = try open("a = 1\n");
    defer f.deinit();
    try f.setList("font-family", &.{ "A", "B" });
    try expectText(&f, "a = 1\nfont-family = A\nfont-family = B\n");
}

test "ConfigFileText: setList keeps the key's indentation and the file's CRLF" {
    var f = try open("  font-family = A\r\nx = 1\r\n");
    defer f.deinit();
    try f.setList("font-family", &.{ "A", "B" });
    try expectText(&f, "  font-family = A\r\n  font-family = B\r\nx = 1\r\n");
}

test "ConfigFileText: add goes after the key's last line" {
    var f = try open("env = A=1\nfont-size = 3\n");
    defer f.deinit();
    try f.add("env", "B=2");
    try expectText(&f, "env = A=1\nenv = B=2\nfont-size = 3\n");
}

// Keyed repeatable entries (keybind, palette, env)

/// `cmd`/`command` are aliases of `super`, as Ghostty's trigger parser has
/// them. Mirrors the Mac test's `^(.+?)=([a-z_]+(?::.*)?)$` trigger regex.
fn testTrigger(alloc: Allocator, val: []const u8) Allocator.Error!?[]const u8 {
    var i: usize = 1;
    while (i < val.len) : (i += 1) {
        if (val[i] != '=') continue;
        const action = val[i + 1 ..];
        var n: usize = 0;
        while (n < action.len and (std.ascii.isLower(action[n]) or action[n] == '_')) n += 1;
        if (n > 0 and (n == action.len or action[n] == ':')) return try testNormalize(alloc, val[0..i]);
    }
    return null;
}

fn testNormalize(alloc: Allocator, trigger: []const u8) Allocator.Error![]const u8 {
    const aliases = [_][2][]const u8{
        .{ "cmd", "super" },   .{ "command", "super" }, .{ "opt", "alt" },
        .{ "option", "alt" }, .{ "control", "ctrl" },
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, trigger, '+');
    var first = true;
    while (it.next()) |part| {
        if (!first) try out.append(alloc, '+');
        first = false;
        const mapped = for (aliases) |pair| {
            if (std.mem.eql(u8, pair[0], part)) break pair[1];
        } else part;
        try out.appendSlice(alloc, mapped);
    }
    return out.items;
}

const trigger_opts: KeyedOptions = .{ .subkeyOf = testTrigger, .normalize = testNormalize };

test "ConfigFileText: keybind replaces the same trigger written differently" {
    var f = try open("keybind = cmd+shift+d=new_split:down\nkeybind = cmd+k=clear_screen\n# end\n");
    defer f.deinit();
    try f.setKeyed("keybind", "super+k", "new_tab", trigger_opts);
    try expectText(&f, "keybind = cmd+shift+d=new_split:down\nkeybind = super+k=new_tab\n# end\n");
}

test "ConfigFileText: keybind unbind is just another action" {
    var f = try open("font-size = 3\n");
    defer f.deinit();
    try f.setKeyed("keybind", "super+d", "unbind", trigger_opts);
    try expectText(&f, "font-size = 3\nkeybind = super+d=unbind\n");
}

test "ConfigFileText: keybind triggers may contain equals" {
    var f = try open("keybind = super+==increase_font_size:1\nkeybind = super+-=decrease_font_size:1\n");
    defer f.deinit();
    try f.setKeyed("keybind", "super+=", null, trigger_opts);
    try expectText(&f, "keybind = super+-=decrease_font_size:1\n");
}

test "ConfigFileText: keyed removes duplicates and keeps the last position" {
    var f = try open("palette = 1=#ff0000\n# mine\npalette = 2=#00ff00\npalette = 1=#aa0000\n");
    defer f.deinit();
    try f.setKeyed("palette", "1", "#123456", .{});
    try expectText(&f, "# mine\npalette = 2=#00ff00\npalette = 1=#123456\n");
}

test "ConfigFileText: keyed new entry goes after the key's last line" {
    var f = try open("env = A=1\nfont-size = 3\n");
    defer f.deinit();
    try f.setKeyed("env", "B", "2", .{});
    try expectText(&f, "env = A=1\nenv = B=2\nfont-size = 3\n");
}

test "ConfigFileText: keyed null removes only that entry" {
    var f = try open("env = A=1\nenv = B=2\n");
    defer f.deinit();
    try f.setKeyed("env", "A", null, .{});
    try expectText(&f, "env = B=2\n");
}

test "ConfigFileText: clone and replaceWith copy, eql compares" {
    var f = try open("\u{FEFF}a = 1\r\nb = 2");
    defer f.deinit();
    var c = try f.clone(testing.allocator);
    defer c.deinit();
    try testing.expect(f.eql(&c));
    try c.set("a", "3");
    try testing.expect(!f.eql(&c));
    try expectText(&f, "\u{FEFF}a = 1\r\nb = 2");
    try c.replaceWith(&f);
    try testing.expect(f.eql(&c));
    try expectText(&c, "\u{FEFF}a = 1\r\nb = 2");
}
