//! The configuration schema as the Settings window reads it (T2584a; the
//! win32 port of Mac `ConfigSchema.swift`, 9287de0ff). It is built from
//! `src/config/schema_json.zig`, which is generated from `Config.zig` and its
//! doc comments, so a key added to `Config.zig` shows up in Settings (under
//! Advanced -> All Settings) with its docs and default and no hand-kept list
//! to update.
//!
//! Two of these exist at once in the window: the CATALOG (`defaults`, every
//! key with its docs and default values) and the EFFECTIVE values
//! (`describe` on the live config, no docs). Mac reads both through the
//! `ghostty_config_schema_json` C call; Windows links the core directly, so
//! it calls `schema_json.allocJson` instead and parses the same JSON.
const SettingsCatalog = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("../../config.zig").Config;
const schema_json = @import("../../config/schema_json.zig");

pub const Kind = enum { bool, int, float, @"enum", @"union", flags, string, other };

pub const Entry = struct {
    key: []const u8,
    /// What `+show-config` prints after `key = `, one string per line.
    values: []const []const u8,
    kind: Kind,
    optional: bool,
    repeatable: bool,
    /// Enum tags, flag names, or union tags.
    options: ?[]const []const u8 = null,
    doc: ?[]const u8 = null,

    /// The single value of a plain key ("" for an unset optional).
    pub fn value(self: *const Entry) []const u8 {
        return if (self.values.len > 0) self.values[0] else "";
    }

    /// `values` joined with ", " - how a default reads on a row. Caller
    /// owns the result.
    pub fn joined(self: *const Entry, alloc: Allocator) Allocator.Error![]u8 {
        return std.mem.join(alloc, ", ", self.values);
    }
};

arena: std.heap.ArenaAllocator,
entries: []const Entry,
by_key: std.StringHashMapUnmanaged(usize),

pub const ParseError = Allocator.Error || error{InvalidSchema};

/// Parse the JSON `schema_json` writes. The catalog owns every string.
pub fn parse(gpa: Allocator, json: []const u8) ParseError!SettingsCatalog {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const Raw = struct {
        key: []const u8,
        values: []const []const u8,
        kind: []const u8,
        optional: bool,
        repeatable: bool,
        options: ?[]const []const u8 = null,
        doc: ?[]const u8 = null,
    };
    const raw = std.json.parseFromSliceLeaky([]const Raw, alloc, json, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSchema,
    };

    const entries = try alloc.alloc(Entry, raw.len);
    var by_key: std.StringHashMapUnmanaged(usize) = .empty;
    for (raw, 0..) |r, i| {
        entries[i] = .{
            .key = r.key,
            .values = r.values,
            // An unknown kind (a newer core than this frontend) degrades to
            // a text row rather than hiding the key.
            .kind = std.meta.stringToEnum(Kind, r.kind) orelse .other,
            .optional = r.optional,
            .repeatable = r.repeatable,
            .options = r.options,
            .doc = r.doc,
        };
        // First wins, as Mac's `uniquingKeysWith: { a, _ in a }`.
        const gop = try by_key.getOrPut(alloc, r.key);
        if (!gop.found_existing) gop.value_ptr.* = i;
    }
    return .{ .arena = arena, .entries = entries, .by_key = by_key };
}

/// Describe a config: its effective values (and, with `docs`, its docs).
pub fn describe(gpa: Allocator, config: *const Config, docs: bool) !SettingsCatalog {
    const json = try schema_json.allocJson(gpa, config, docs);
    defer gpa.free(json);
    return parse(gpa, json);
}

/// The catalog: every key with its docs and default values.
pub fn defaults(gpa: Allocator) !SettingsCatalog {
    var cfg = try Config.default(gpa);
    defer cfg.deinit();
    return describe(gpa, &cfg, true);
}

pub fn deinit(self: *SettingsCatalog) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn get(self: *const SettingsCatalog, key: []const u8) ?*const Entry {
    const i = self.by_key.get(key) orelse return null;
    return &self.entries[i];
}

/// The doc's first paragraph on one line - a row's subtitle. Mac's
/// `ConfigSchema.Entry.summary`: lines are trimmed and joined with spaces, a
/// trailing lead-in to a list ("... Valid values:") is cut back to the last
/// full sentence, and inline-code backticks are dropped. Caller owns it.
pub fn summary(alloc: Allocator, doc: ?[]const u8) Allocator.Error![]u8 {
    const d = doc orelse return alloc.dupe(u8, "");
    const para_end = std.mem.indexOf(u8, d, "\n\n") orelse d.len;
    const first = d[0..para_end];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, first, '\n');
    var any = false;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (any) try out.append(alloc, ' ');
        try out.appendSlice(alloc, t);
        any = true;
    }

    var text = out.items;
    if (text.len > 0 and text[text.len - 1] == ':') {
        if (std.mem.lastIndexOfScalar(u8, text[0 .. text.len - 1], '.')) |stop| {
            text = text[0 .. stop + 1];
        }
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(alloc);
    for (text) |c| if (c != '`') try result.append(alloc, c);
    out.deinit(alloc);
    return result.toOwnedSlice(alloc);
}

/// Case-insensitive substring match, the way Swift's
/// `localizedCaseInsensitiveContains` behaves for the ASCII text config
/// keys, docs and values are written in. An empty needle matches.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// Tests: the Zig half of Mac's catalog behaviour. The `schema json:
// defaults, kinds and docs` test in `schema_json.zig` covers the JSON
// itself; these cover reading it.

const testing = std.testing;

test "SettingsCatalog: the defaults catalog carries every key with docs" {
    var cat = try defaults(testing.allocator);
    defer cat.deinit();

    try testing.expect(cat.entries.len > 100);
    const size = cat.get("font-size").?;
    try testing.expectEqual(Kind.float, size.kind);
    try testing.expect(size.doc != null);
    try testing.expect(!size.repeatable);

    const style = cat.get("cursor-style").?;
    try testing.expectEqual(Kind.@"enum", style.kind);
    try testing.expectEqualStrings("block", style.value());
    try testing.expect(style.options.?.len >= 3);

    try testing.expect(cat.get("keybind").?.repeatable);
    try testing.expectEqual(Kind.flags, cat.get("shell-integration-features").?.kind);

    const cursor_color = cat.get("cursor-color").?;
    try testing.expect(cursor_color.optional);
    try testing.expectEqualStrings("", cursor_color.value());

    try testing.expect(cat.get("no-such-key") == null);
}

test "SettingsCatalog: a key added to Config appears with no list to update" {
    // Every Config field that is not internal is in the catalog, in order -
    // the property that makes All Settings need no hand-kept list.
    var cat = try defaults(testing.allocator);
    defer cat.deinit();
    var n: usize = 0;
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        try testing.expectEqualStrings(field.name, cat.entries[n].key);
        n += 1;
    }
    try testing.expectEqual(n, cat.entries.len);
}

test "SettingsCatalog: describe reads a loaded config's effective values" {
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    cfg.@"font-size" = 21;
    var eff = try describe(testing.allocator, &cfg, false);
    defer eff.deinit();
    try testing.expectEqualStrings("21", eff.get("font-size").?.value());
    try testing.expect(eff.get("font-size").?.doc == null);
}

test "SettingsCatalog: parse tolerates an unknown kind and refuses garbage" {
    var cat = try parse(testing.allocator,
        \\[{"key":"a","values":["1"],"kind":"tensor","optional":false,"repeatable":false},
        \\ {"key":"a","values":["2"],"kind":"int","optional":false,"repeatable":false}]
    );
    defer cat.deinit();
    try testing.expectEqual(Kind.other, cat.get("a").?.kind);
    try testing.expectEqualStrings("1", cat.get("a").?.value());
    try testing.expectError(error.InvalidSchema, parse(testing.allocator, "{not json"));
}

test "SettingsCatalog: summary is the first paragraph on one line" {
    const a = testing.allocator;
    const s1 = try summary(a, "The size of the `font`\n  in points.\n\nMore detail.");
    defer a.free(s1);
    try testing.expectEqualStrings("The size of the font in points.", s1);

    const s2 = try summary(a, "Sets the style. The cursor is drawn as\nconfigured. Valid values:\n\n* block");
    defer a.free(s2);
    try testing.expectEqualStrings("Sets the style. The cursor is drawn as configured.", s2);

    const s3 = try summary(a, null);
    defer a.free(s3);
    try testing.expectEqualStrings("", s3);

    // A colon with no earlier sentence stays as written.
    const s4 = try summary(a, "Valid values:");
    defer a.free(s4);
    try testing.expectEqualStrings("Valid values:", s4);
}

test "SettingsCatalog: containsIgnoreCase" {
    try testing.expect(containsIgnoreCase("font-size", "SIZE"));
    try testing.expect(containsIgnoreCase("anything", ""));
    try testing.expect(!containsIgnoreCase("font", "fonts"));
}
