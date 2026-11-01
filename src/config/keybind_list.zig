//! A flat, structured listing of a config's effective keybindings, for UIs
//! that show them (the macOS keyboard shortcut guide and the Settings
//! window's Keyboard page) via `ghostty_config_keybinds_json`.
//!
//! Unlike the `keybind = …` lines `+list-keybinds` prints, every entry keeps
//! its flags (`global:`, `all:`, `unconsumed:`, `performable:`), its key table
//! and its chained actions, so a UI can label them instead of guessing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const inputpkg = @import("../input.zig");
const Binding = inputpkg.Binding;
const Config = @import("Config.zig");

/// One effective binding. Field names are a public (JSON) contract: add
/// fields, never rename or retype one.
pub const Entry = struct {
    /// The full trigger as config spells it, e.g. `super+shift+d` or
    /// `ctrl+a>n` for a sequence. Never includes the flag prefixes.
    trigger: []const u8,
    /// The canonical action string, e.g. `new_split:right`.
    action: []const u8,
    /// The action's tag alone, e.g. `new_split`.
    action_key: []const u8,
    /// Further actions run after `action` (`chain=` lines), canonical form.
    chain: []const []const u8,
    /// The key table the binding lives in; empty for the root set.
    table: []const u8,
    global: bool,
    all: bool,
    consumed: bool,
    performable: bool,
};

/// Every effective binding in `keybinds`: the root set first, then each key
/// table. All memory is owned by `arena`.
pub fn entries(arena: Allocator, keybinds: *const Config.Keybinds) ![]const Entry {
    var list: std.ArrayList(Entry) = .empty;
    var prefix: std.ArrayList(u8) = .empty;
    try walk(arena, &list, &prefix, "", &keybinds.set);
    var it = keybinds.tables.iterator();
    while (it.next()) |table| {
        prefix.clearRetainingCapacity();
        try walk(arena, &list, &prefix, table.key_ptr.*, table.value_ptr);
    }
    return list.items;
}

/// The JSON array of `entries`, NUL-terminated, allocated with `alloc`.
pub fn json(alloc: Allocator, keybinds: *const Config.Keybinds) ![:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const list = try entries(arena.allocator(), keybinds);
    const out = try std.json.Stringify.valueAlloc(arena.allocator(), list, .{});
    return try alloc.dupeZ(u8, out);
}

/// Every action tag `keybind` accepts, one per line — the complete list a UI
/// catalog must cover (its tests compare against this).
pub const action_keys: [:0]const u8 = keys: {
    @setEvalBranchQuota(100_000);
    var result: [:0]const u8 = "";
    for (@typeInfo(Binding.Action.Key).@"enum".fields, 0..) |field, i| {
        result = result ++ (if (i == 0) "" else "\n") ++ field.name;
    }
    break :keys result;
};

fn walk(
    arena: Allocator,
    list: *std.ArrayList(Entry),
    prefix: *std.ArrayList(u8),
    table: []const u8,
    set: *const Binding.Set,
) !void {
    var it = set.bindings.iterator();
    while (it.next()) |binding| {
        const start = prefix.items.len;
        defer prefix.shrinkRetainingCapacity(start);
        if (start > 0) try prefix.append(arena, '>');
        try prefix.print(arena, "{f}", .{binding.key_ptr.*});

        switch (binding.value_ptr.*) {
            .leader => |sub| try walk(arena, list, prefix, table, sub),
            .leaf => |leaf| try list.append(arena, try entry(arena, prefix.items, table, leaf.action, &.{}, leaf.flags)),
            .leaf_chained => |leaf| {
                const actions = leaf.actions.items;
                if (actions.len == 0) continue;
                const rest = try arena.alloc([]const u8, actions.len - 1);
                for (actions[1..], rest) |a, *out| out.* = try formatAction(arena, a);
                try list.append(arena, try entry(arena, prefix.items, table, actions[0], rest, leaf.flags));
            },
        }
    }
}

fn entry(
    arena: Allocator,
    trigger: []const u8,
    table: []const u8,
    action: Binding.Action,
    chain: []const []const u8,
    flags: Binding.Flags,
) !Entry {
    return .{
        .trigger = try arena.dupe(u8, trigger),
        .action = try formatAction(arena, action),
        .action_key = @tagName(action),
        .chain = chain,
        .table = table,
        .global = flags.global,
        .all = flags.all,
        .consumed = flags.consumed,
        .performable = flags.performable,
    };
}

fn formatAction(arena: Allocator, action: Binding.Action) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(arena);
    try action.format(&buf.writer);
    return buf.written();
}

test "entries: defaults, a sequence, flags, an unbind and a table" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try cfg.keybind.parseCLI(cfg._arena.?.allocator(), "ctrl+a>n=new_window");
    try cfg.keybind.parseCLI(cfg._arena.?.allocator(), "global:super+grave_accent=toggle_quick_terminal");
    try cfg.keybind.parseCLI(cfg._arena.?.allocator(), "super+d=unbind");
    try cfg.keybind.parseCLI(cfg._arena.?.allocator(), "vim/j=scroll_page_lines:1");

    const list = try entries(arena, &cfg.keybind);
    var saw_sequence = false;
    var saw_global = false;
    var saw_table = false;
    for (list) |e| {
        // The unbound default is gone.
        try testing.expect(!std.mem.eql(u8, e.trigger, "super+d"));
        if (std.mem.eql(u8, e.trigger, "ctrl+a>n")) {
            saw_sequence = true;
            try testing.expectEqualStrings("new_window", e.action);
        }
        if (std.mem.eql(u8, e.action, "toggle_quick_terminal")) {
            saw_global = e.global;
            try testing.expectEqualStrings("super+backquote", e.trigger);
        }
        if (std.mem.eql(u8, e.table, "vim")) {
            saw_table = true;
            try testing.expectEqualStrings("j", e.trigger);
            try testing.expectEqualStrings("scroll_page_lines", e.action_key);
        }
    }
    try testing.expect(saw_sequence);
    try testing.expect(saw_global);
    try testing.expect(saw_table);

    // And the JSON form round-trips through a parser.
    const text = try json(alloc, &cfg.keybind);
    defer alloc.free(text);
    const parsed = try std.json.parseFromSlice([]const Entry, alloc, text, .{});
    defer parsed.deinit();
    try testing.expectEqual(list.len, parsed.value.len);
}

test "action_keys lists every action tag" {
    const testing = std.testing;
    var it = std.mem.splitScalar(u8, action_keys, '\n');
    var n: usize = 0;
    while (it.next()) |name| : (n += 1) {
        try testing.expect(std.meta.stringToEnum(Binding.Action.Key, name) != null);
    }
    try testing.expectEqual(@typeInfo(Binding.Action.Key).@"enum".fields.len, n);
}
