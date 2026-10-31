//! A JSON view of the configuration schema, for GUIs (the macOS Settings
//! window). One entry per config key, in declaration order:
//!
//!   { "key": "font-size", "values": ["13"], "kind": "float",
//!     "optional": false, "repeatable": false, "options": [...], "doc": "..." }
//!
//! `values` are exactly what `+show-config` prints after `key = ` for that
//! config (one string per line, so a repeatable key can have many, and an
//! unset optional has one empty string). Run it on `Config.default` with
//! `docs` to get the catalog (docs + defaults), and on a loaded config to get
//! the effective values. `options` lists an enum's tags, a packed struct's
//! flag names, or a tagged union's tags; it is omitted otherwise.
//!
//! This is generated from `Config` and `help_strings` at compile time, so a
//! new key appears here with no hand-maintained list to update.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const formatter = @import("formatter.zig");
const help_strings = @import("help_strings");

pub fn write(
    alloc: Allocator,
    config: *const Config,
    docs: bool,
    writer: *std.Io.Writer,
) !void {
    @setEvalBranchQuota(100_000);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    var s: std.json.Stringify = .{ .writer = writer };
    try s.beginArray();
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;

        buf.clearRetainingCapacity();
        try formatter.formatEntry(
            field.type,
            field.name,
            @field(config, field.name),
            &buf.writer,
        );

        try s.beginObject();
        try s.objectField("key");
        try s.write(field.name);

        try s.objectField("values");
        try s.beginArray();
        var lines = std.mem.splitScalar(u8, buf.written(), '\n');
        while (lines.next()) |line| {
            if (valueOf(field.name, line)) |v| try s.write(v);
        }
        try s.endArray();

        try writeKind(&s, field.type);

        if (docs and @hasDecl(help_strings.Config, field.name)) {
            try s.objectField("doc");
            try s.write(@as([]const u8, @field(help_strings.Config, field.name)));
        }
        try s.endObject();
    }
    try s.endArray();
}

/// Allocate the JSON for `config`. Caller frees.
pub fn allocJson(gpa: Allocator, config: *const Config, docs: bool) ![:0]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try write(gpa, config, docs, &out.writer);
    return try out.toOwnedSliceSentinel(0);
}

/// `name = value` → `value`. Formatters always write `name = ` (a void or
/// an unset optional writes the bare `name = `).
fn valueOf(name: []const u8, line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, name)) return null;
    const rest = line[name.len..];
    if (std.mem.startsWith(u8, rest, " = ")) return rest[3..];
    if (std.mem.eql(u8, std.mem.trimRight(u8, rest, " "), " =")) return "";
    return null;
}

fn writeKind(s: *std.json.Stringify, comptime T: type) !void {
    const optional = @typeInfo(T) == .optional;
    const U = if (optional) @typeInfo(T).optional.child else T;

    try s.objectField("optional");
    try s.write(optional);
    try s.objectField("repeatable");
    try s.write(comptime isRepeatable(U));

    try s.objectField("kind");
    switch (@typeInfo(U)) {
        .bool => try s.write("bool"),
        .int => try s.write("int"),
        .float => try s.write("float"),
        .@"enum" => |e| {
            try s.write("enum");
            try s.objectField("options");
            try s.beginArray();
            inline for (e.fields) |f| try s.write(f.name);
            try s.endArray();
        },
        .@"union" => |u| if (u.tag_type != null) {
            try s.write("union");
            try s.objectField("options");
            try s.beginArray();
            inline for (u.fields) |f| try s.write(f.name);
            try s.endArray();
        } else try s.write("other"),
        .@"struct" => |st| if (st.layout == .@"packed" and comptime allBool(st.fields)) {
            try s.write("flags");
            try s.objectField("options");
            try s.beginArray();
            inline for (st.fields) |f| {
                if (f.name[0] != '_') try s.write(f.name);
            }
            try s.endArray();
        } else try s.write("other"),
        .pointer => |p| if (p.child == u8) try s.write("string") else try s.write("other"),
        else => try s.write("other"),
    }
}

fn allBool(comptime fields: anytype) bool {
    for (fields) |f| {
        if (f.name[0] == '_') continue;
        if (f.type != bool) return false;
    }
    return true;
}

/// A key whose every line adds a value (`keybind`, `font-family`, `palette`,
/// …) rather than replacing the last one.
fn isRepeatable(comptime U: type) bool {
    const name = @typeName(U);
    return std.mem.indexOf(u8, name, "Repeatable") != null or
        std.mem.endsWith(u8, name, ".Keybinds") or
        std.mem.endsWith(u8, name, ".Palette") or
        std.mem.endsWith(u8, name, ".KeyRemapSet");
}

test "schema json: defaults, kinds and docs" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    const json = try allocJson(testing.allocator, &cfg, true);
    defer testing.allocator.free(json);

    const Entry = struct {
        key: []const u8,
        values: []const []const u8,
        kind: []const u8,
        optional: bool,
        repeatable: bool,
        options: ?[]const []const u8 = null,
        doc: ?[]const u8 = null,
    };
    const parsed = try std.json.parseFromSlice([]Entry, testing.allocator, json, .{});
    defer parsed.deinit();

    var seen_size = false;
    var seen_style = false;
    var seen_keybind = false;
    var seen_features = false;
    for (parsed.value) |e| {
        if (std.mem.eql(u8, e.key, "font-size")) {
            seen_size = true;
            try testing.expectEqualStrings("float", e.kind);
            try testing.expectEqual(@as(usize, 1), e.values.len);
            try testing.expect(e.doc != null);
        } else if (std.mem.eql(u8, e.key, "cursor-style")) {
            seen_style = true;
            try testing.expectEqualStrings("enum", e.kind);
            try testing.expectEqualStrings("block", e.values[0]);
            try testing.expect(e.options.?.len >= 3);
        } else if (std.mem.eql(u8, e.key, "keybind")) {
            seen_keybind = true;
            try testing.expect(e.repeatable);
            try testing.expect(e.values.len > 10);
        } else if (std.mem.eql(u8, e.key, "shell-integration-features")) {
            seen_features = true;
            try testing.expectEqualStrings("flags", e.kind);
        } else if (std.mem.eql(u8, e.key, "font-family")) {
            try testing.expect(e.repeatable);
        } else if (std.mem.eql(u8, e.key, "cursor-color")) {
            try testing.expect(e.optional);
            try testing.expectEqualStrings("", e.values[0]);
        }
    }
    try testing.expect(seen_size and seen_style and seen_keybind and seen_features);
}
