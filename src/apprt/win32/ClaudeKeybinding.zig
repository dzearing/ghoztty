//! Ctrl+V attaches a clipboard image in Claude Code on Windows (T2694).
//!
//! Claude Code binds `chat:imagePaste` to Ctrl+V on macOS but to Alt+V on
//! Windows, so a Windows user who takes a screenshot and presses Ctrl+V in a
//! Ghoztty pane gets nothing: Ghoztty passes ^V through when the clipboard
//! holds no text (T154), and Claude has nothing bound to it. The Mac user
//! never meets this - Ctrl+V already attaches the image there - so the
//! platform-symmetric fix is to make the Windows experience match, and the
//! Mac half of the integration needs no counterpart.
//!
//! The fix is a binding in the user's `~/.claude/keybindings.json`, written
//! as one more component of Ghoztty's Claude integration (installed from the
//! first-run offer, the Agent Integrations dialog and `+agent-setup
//! --install=claude`). Ghoztty deliberately does NOT rewrite Ctrl+V into
//! Alt+V at the terminal: every other program in a pane owns its own ^V.
//!
//! The file is the USER's, exactly like `settings.json` (`HookComponent`):
//!
//! - A Chat-context `ctrl+v` binding that is already there - to anything,
//!   `null` (an explicit unbind) included - is the user's choice. It reads as
//!   installed and is never overwritten.
//! - Ownership of the binding we add is recorded in a sidecar file beside
//!   the config, because keybindings.json has no room for a marker Claude
//!   would not reject. Uninstall removes the binding only when that sidecar
//!   exists AND the binding still says `chat:imagePaste` - a user who rebound
//!   it since keeps their binding.
//! - A keybindings.json that exists but is not JSON we can merge into is
//!   left alone and reads as installed: refusing would fail the whole Claude
//!   integration over a file Claude itself will report, and "outdated" would
//!   offer an Update that can never succeed.
//!
//! Plain `std.fs` + the T865 writer, no OS imports, so the tempdir tests run
//! in every app-runtime lane on both seats.
const std = @import("std");
const Allocator = std.mem.Allocator;

const marker_mod = @import("managed_marker.zig");
const managed_file = @import("managed_file.zig");
const stable_json = @import("stable_json.zig");

const ClaudeKeybinding = @This();

pub const InstallState = marker_mod.InstallState;

/// Home-relative path of Claude Code's keybindings file.
pub const keybindings_sub_path = ".claude/keybindings.json";
/// Sidecar that says Ghoztty added the binding (see module doc).
pub const owned_sub_path = keybindings_sub_path ++ ".ghoztty-owned";

pub const context = "Chat";
pub const key = "ctrl+v";
pub const action = "chat:imagePaste";

const schema_url = "https://www.schemastore.org/claude-code-keybindings.json";
const docs_url = "https://code.claude.com/docs/en/keybindings";

/// The user's home directory (a tempdir in tests).
home: std.fs.Dir,

pub const Error = managed_file.WriteError || error{RemoveFailed} || Allocator.Error;

// -----------------------------------------------------------------------------
// Pure JSON logic
// -----------------------------------------------------------------------------

/// What the config currently says about Chat's Ctrl+V.
pub const Binding = union(enum) {
    /// No Chat block binds it.
    absent,
    /// Bound to this action string.
    action: []const u8,
    /// Bound to something that is not a string (`null` = an explicit unbind).
    other,
};

/// The first Chat-context `ctrl+v` entry in `root`.
pub fn binding(root: std.json.Value) Binding {
    const blocks = bindingsArray(root) orelse return .absent;
    for (blocks.items) |block| {
        const map = chatBindings(block) orelse continue;
        const v = map.get(key) orelse continue;
        return switch (v) {
            .string => |s| .{ .action = s },
            else => .other,
        };
    }
    return .absent;
}

/// `root` with Chat's Ctrl+V bound to image paste, added to the first Chat
/// block (or a new one). Precondition: `binding(root) == .absent` and `root`
/// is an object. Expects an ARENA: the result aliases `root`.
pub fn merge(arena: Allocator, root: std.json.Value) Allocator.Error!std.json.Value {
    var obj = root.object;
    if (obj.count() == 0) {
        try obj.put("$schema", .{ .string = schema_url });
        try obj.put("$docs", .{ .string = docs_url });
    }
    if (bindingsArray(.{ .object = obj }) == null) {
        try obj.put("bindings", .{ .array = std.json.Array.init(arena) });
    }
    const arr = &obj.getPtr("bindings").?.array;
    for (arr.items) |*block| {
        if (chatBindingsPtr(block)) |map| {
            try map.put(key, .{ .string = action });
            return .{ .object = obj };
        }
    }
    var map = std.json.ObjectMap.init(arena);
    try map.put(key, .{ .string = action });
    var block = std.json.ObjectMap.init(arena);
    try block.put("context", .{ .string = context });
    try block.put("bindings", .{ .object = map });
    try arr.append(.{ .object = block });
    return .{ .object = obj };
}

/// `root` without Chat's image-paste Ctrl+V; a Chat block left empty goes
/// with it. Anything bound to another action is untouched. ARENA, as above.
pub fn remove(root: std.json.Value) std.json.Value {
    const arr_v = switch (root) {
        .object => |o| o.getPtr("bindings") orelse return root,
        else => return root,
    };
    if (arr_v.* != .array) return root;
    const arr = &arr_v.array;
    var i: usize = 0;
    while (i < arr.items.len) {
        if (chatBindingsPtr(&arr.items[i])) |map| {
            const ours = if (map.get(key)) |v|
                v == .string and std.mem.eql(u8, v.string, action)
            else
                false;
            if (ours) _ = map.orderedRemove(key);
            if (map.count() == 0) {
                _ = arr.orderedRemove(i);
                continue;
            }
        }
        i += 1;
    }
    return root;
}

fn bindingsArray(root: std.json.Value) ?std.json.Array {
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get("bindings") orelse return null;
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

fn isChat(block: std.json.ObjectMap) bool {
    const c = block.get("context") orelse return false;
    return c == .string and std.mem.eql(u8, c.string, context);
}

fn chatBindings(block: std.json.Value) ?std.json.ObjectMap {
    if (block != .object or !isChat(block.object)) return null;
    const b = block.object.get("bindings") orelse return null;
    return if (b == .object) b.object else null;
}

fn chatBindingsPtr(block: *std.json.Value) ?*std.json.ObjectMap {
    if (block.* != .object or !isChat(block.object)) return null;
    const b = block.object.getPtr("bindings") orelse return null;
    return if (b.* == .object) &b.object else null;
}

// -----------------------------------------------------------------------------
// Component
// -----------------------------------------------------------------------------

const Read = union(enum) {
    /// Absent or empty: start from `{}`.
    fresh: std.json.Value,
    parsed: std.json.Value,
    /// Present but not a JSON object we can merge into, or unreadable.
    unmergeable,
};

fn read(self: ClaudeKeybinding, arena: Allocator) Allocator.Error!Read {
    const contents = self.home.readFileAlloc(
        arena,
        keybindings_sub_path,
        managed_file.max_managed_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{ .fresh = .{ .object = std.json.ObjectMap.init(arena) } },
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unmergeable,
    };
    if (std.mem.trim(u8, contents, " \t\r\n").len == 0)
        return .{ .fresh = .{ .object = std.json.ObjectMap.init(arena) } };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, contents, .{}) catch
        return .unmergeable;
    if (root != .object) return .unmergeable;
    if (root.object.get("bindings")) |b| {
        if (b != .array) return .unmergeable;
    }
    return .{ .parsed = root };
}

/// Installed when Chat's Ctrl+V is bound to anything (the user's choice
/// stands) or the file is one we must not touch; not_installed only when we
/// could and would add the binding.
pub fn state(self: ClaudeKeybinding, alloc: Allocator) InstallState {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const r = self.read(arena_state.allocator()) catch return .installed;
    return switch (r) {
        .unmergeable => .installed,
        .fresh => .not_installed,
        .parsed => |root| if (binding(root) == .absent) .not_installed else .installed,
    };
}

pub fn install(self: ClaudeKeybinding, alloc: Allocator) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = switch (try self.read(arena)) {
        .unmergeable => return,
        .fresh => |r| r,
        .parsed => |r| r,
    };
    if (binding(root) != .absent) return;
    const merged = try merge(arena, root);
    // The sidecar first: a crash between the two leaves a sidecar with no
    // binding, which uninstall reads as nothing to remove. The other order
    // would strand a binding nobody owns.
    try managed_file.writeAtomicNoFollow(arena, self.home, owned_sub_path, marker_mod.token ++ "\n");
    try managed_file.writeAtomicNoFollow(arena, self.home, keybindings_sub_path, try stable_json.prettyAlloc(arena, merged));
}

pub fn uninstall(self: ClaudeKeybinding, alloc: Allocator) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = self.home.statFile(owned_sub_path) catch return;
    switch (try self.read(arena)) {
        .parsed => |root| switch (binding(root)) {
            .action => |a| if (std.mem.eql(u8, a, action)) {
                try managed_file.writeAtomicNoFollow(
                    arena,
                    self.home,
                    keybindings_sub_path,
                    try stable_json.prettyAlloc(arena, remove(root)),
                );
            },
            else => {},
        },
        else => {},
    }
    self.home.deleteFile(owned_sub_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return error.RemoveFailed,
    };
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

fn parse(arena: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

fn readBack(arena: Allocator, dir: std.fs.Dir) !std.json.Value {
    return parse(arena, try dir.readFileAlloc(arena, keybindings_sub_path, 1 << 20));
}

test "a fresh home gets the binding, a schema, and an ownership sidecar" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: ClaudeKeybinding = .{ .home = tmp.dir };

    try testing.expectEqual(InstallState.not_installed, c.state(arena));
    try c.install(arena);
    try testing.expectEqual(InstallState.installed, c.state(arena));
    const root = try readBack(arena, tmp.dir);
    try testing.expectEqualStrings(action, binding(root).action);
    try testing.expectEqualStrings(schema_url, root.object.get("$schema").?.string);
    _ = try tmp.dir.statFile(owned_sub_path);

    try c.uninstall(arena);
    try testing.expectEqual(InstallState.not_installed, c.state(arena));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(owned_sub_path));
    try testing.expectEqual(Binding.absent, binding(try readBack(arena, tmp.dir)));
}

test "the user's other bindings survive install and uninstall" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".claude");
    try tmp.dir.writeFile(.{ .sub_path = keybindings_sub_path, .data =
        \\{"bindings":[{"context":"Global","bindings":{"ctrl+t":"app:toggleTodos"}},
        \\ {"context":"Chat","bindings":{"ctrl+e":"chat:externalEditor"}}]}
    });
    const c: ClaudeKeybinding = .{ .home = tmp.dir };
    try c.install(arena);
    var root = try readBack(arena, tmp.dir);
    const arr = root.object.get("bindings").?.array;
    // Added to the existing Chat block, not a second one.
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    try testing.expectEqualStrings(action, arr.items[1].object.get("bindings").?.object.get(key).?.string);
    try testing.expectEqualStrings("chat:externalEditor", arr.items[1].object.get("bindings").?.object.get("ctrl+e").?.string);

    try c.uninstall(arena);
    root = try readBack(arena, tmp.dir);
    const after = root.object.get("bindings").?.array;
    try testing.expectEqual(@as(usize, 2), after.items.len);
    try testing.expectEqual(Binding.absent, binding(root));
    try testing.expectEqualStrings("app:toggleTodos", after.items[0].object.get("bindings").?.object.get("ctrl+t").?.string);
    try testing.expectEqualStrings("chat:externalEditor", after.items[1].object.get("bindings").?.object.get("ctrl+e").?.string);
}

test "a Ctrl+V the user already bound is theirs: never overwritten, never removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    inline for (.{
        \\{"bindings":[{"context":"Chat","bindings":{"ctrl+v":"chat:submit"}}]}
        ,
        \\{"bindings":[{"context":"Chat","bindings":{"ctrl+v":null}}]}
        ,
        // The user's own workaround, byte for byte the binding we would add:
        // no sidecar, so uninstall must leave it.
        \\{"bindings":[{"context":"Chat","bindings":{"ctrl+v":"chat:imagePaste"}}]}
    }) |text| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.makePath(".claude");
        try tmp.dir.writeFile(.{ .sub_path = keybindings_sub_path, .data = text });
        const c: ClaudeKeybinding = .{ .home = tmp.dir };
        try testing.expectEqual(InstallState.installed, c.state(arena));
        try c.install(arena);
        try c.uninstall(arena);
        const got = try tmp.dir.readFileAlloc(arena, keybindings_sub_path, 1 << 20);
        try testing.expectEqualStrings(text, got);
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(owned_sub_path));
    }
}

test "uninstall keeps a binding the user changed after we added it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: ClaudeKeybinding = .{ .home = tmp.dir };
    try c.install(arena);
    const rebound =
        \\{"bindings":[{"context":"Chat","bindings":{"ctrl+v":"chat:submit"}}]}
    ;
    try tmp.dir.writeFile(.{ .sub_path = keybindings_sub_path, .data = rebound });
    try c.uninstall(arena);
    try testing.expectEqualStrings(rebound, try tmp.dir.readFileAlloc(arena, keybindings_sub_path, 1 << 20));
}

test "a keybindings.json we cannot merge into is left alone and never blocks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    inline for (.{ "{ not json", "[1,2]", "{\"bindings\":{}}" }) |text| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.makePath(".claude");
        try tmp.dir.writeFile(.{ .sub_path = keybindings_sub_path, .data = text });
        const c: ClaudeKeybinding = .{ .home = tmp.dir };
        try testing.expectEqual(InstallState.installed, c.state(arena));
        try c.install(arena);
        try testing.expectEqualStrings(text, try tmp.dir.readFileAlloc(arena, keybindings_sub_path, 1 << 20));
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(owned_sub_path));
    }
}

test "only a Chat-context block counts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try parse(arena,
        \\{"bindings":[{"context":"Global","bindings":{"ctrl+v":"chat:imagePaste"}}]}
    );
    try testing.expectEqual(Binding.absent, binding(root));
    const merged = try merge(arena, root);
    try testing.expectEqualStrings(action, binding(merged).action);
    try testing.expectEqual(@as(usize, 2), merged.object.get("bindings").?.array.items.len);
}
