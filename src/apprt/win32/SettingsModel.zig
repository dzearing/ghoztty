//! The Settings window's write path (T2664; the win32 port of the writing
//! half of Mac `SettingsModel.swift`, 92103f39d). Two rules live here rather
//! than in `ConfigFileText`/`ConfigFileStore`:
//!
//! - **Invalid values are never written.** Every action renders its new
//!   line(s) with `ConfigFileText.render` and has Ghostty's own parser check
//!   them first (`ConfigValidator`). A rejection is recorded as the row's
//!   problem (`problem(key)`, e.g. `invalid value "abc"`), the action returns
//!   false, and the file is untouched — no write, no backup, no reload.
//! - **Undo never clobbers someone else's edit.** The last change keeps the
//!   file before and after the edit; `undoLastChange` puts `before` back only
//!   if the file on disk still holds exactly `after`. The comparison runs
//!   inside the store's own re-read, so there is no gap between "checked" and
//!   "written" for an editor save to land in. If the file moved on, undo
//!   refuses with `file_error` and the user's text stays.
//!
//! Each successful write calls `reload` so the change applies live, the same
//! hook Mac's `afterWrite` drives. Which file Ghostty loads after this one
//! (a later `config-file` include that overrides a key) and the window
//! itself are T2584's; this is the model they write through.
const SettingsModel = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const ConfigFileText = @import("ConfigFileText.zig");
const ConfigFileStore = @import("ConfigFileStore.zig");
const ConfigValidator = @import("ConfigValidator.zig");
const SettingsSources = @import("SettingsSources.zig");

/// Called after every write, so the running app reloads its config.
pub const Reload = struct {
    ctx: ?*anyopaque = null,
    func: ?*const fn (?*anyopaque) void = null,

    fn call(self: Reload) void {
        if (self.func) |f| f(self.ctx);
    }
};

/// What undo refuses with when the file changed after Settings wrote it
/// (Mac's text, word for word).
pub const changed_since_message = "The config file changed since \u{2014} open it to undo by hand.";

/// The last change, for the "Saved · Show change · Undo" toast.
pub const LastChange = struct {
    message: []u8,
    /// Lines only in the file before / only after (multiset difference).
    removed: [][]u8,
    added: [][]u8,
    /// Where this session's backup went, if one was made.
    backed_up_to: ?[]u8,
    before: ConfigFileText,
    after: ConfigFileText,

    fn deinit(self: *LastChange, gpa: Allocator) void {
        gpa.free(self.message);
        freeLines(gpa, self.removed);
        freeLines(gpa, self.added);
        if (self.backed_up_to) |b| gpa.free(b);
        self.before.deinit();
        self.after.deinit();
        self.* = undefined;
    }
};

pub const UndoResult = enum {
    /// There was no change to undo.
    nothing,
    /// The file is back the way it was before the last change.
    undone,
    /// The file changed since Settings wrote it; nothing was written.
    changed_since,
    /// Reading or writing the file failed; see `file_error`.
    failed,
};

gpa: Allocator,
store: *ConfigFileStore,
reload: Reload,
/// Row-level problems (a value that wasn't written), by key.
problems: std.StringHashMapUnmanaged([]u8) = .empty,
/// A problem with the file itself (unreadable, not UTF-8, changed since...).
file_error: ?[]u8 = null,
last_change: ?LastChange = null,
/// Bumped each time a change is recorded, so the toast can tell a new change
/// from the one it is already showing (T2676).
change_seq: u64 = 0,
/// The files Ghostty loads, when the window has read them (T2584a). A key
/// (or keybind trigger) that a file loading AFTER the user's also sets is
/// refused with the row's "Set in X, which loads after your config" note:
/// the write would be silently overridden. `null` checks nothing.
sources: ?*const SettingsSources = null,

pub fn init(gpa: Allocator, store: *ConfigFileStore, reload: Reload) SettingsModel {
    return .{ .gpa = gpa, .store = store, .reload = reload };
}

pub fn deinit(self: *SettingsModel) void {
    var it = self.problems.iterator();
    while (it.next()) |e| {
        self.gpa.free(e.key_ptr.*);
        self.gpa.free(e.value_ptr.*);
    }
    self.problems.deinit(self.gpa);
    if (self.file_error) |f| self.gpa.free(f);
    if (self.last_change) |*c| c.deinit(self.gpa);
    self.* = undefined;
}

/// The problem shown on `key`'s row, if its last value was refused.
pub fn problem(self: *const SettingsModel, key: []const u8) ?[]const u8 {
    return self.problems.get(key);
}

// Writing

/// Set a plain key. False (with the row's problem recorded) if Ghostty
/// rejects the value; nothing is written then.
pub fn set(self: *SettingsModel, key: []const u8, val: []const u8) Allocator.Error!bool {
    if (self.sources) |s| if (s.overriding(key)) |src| {
        try self.setProblemOwned(key, try SettingsSources.overrideMessage(self.gpa, src, null));
        return false;
    };
    if (!try self.validate(key, key, &.{val})) return false;
    const Set = struct {
        key: []const u8,
        val: []const u8,
        pub fn apply(m: @This(), f: *ConfigFileText) ConfigFileText.EditError!void {
            try f.set(m.key, m.val);
        }
    };
    return self.apply(key, "Saved", key, Set{ .key = key, .val = val });
}

/// Back to the default: remove the key from the user's file.
pub fn reset(self: *SettingsModel, key: []const u8) Allocator.Error!bool {
    self.clearProblem(key);
    const Remove = struct {
        key: []const u8,
        pub fn apply(m: @This(), f: *ConfigFileText) ConfigFileText.EditError!void {
            try f.remove(m.key);
        }
    };
    return self.applyMessage(key, "Reset {s} to its default", key, Remove{ .key = key });
}

/// Make a repeatable key's lines in the user's file exactly `vals`.
pub fn setList(self: *SettingsModel, key: []const u8, vals: []const []const u8) Allocator.Error!bool {
    if (!try self.validate(key, key, vals)) return false;
    const SetList = struct {
        key: []const u8,
        vals: []const []const u8,
        pub fn apply(m: @This(), f: *ConfigFileText) ConfigFileText.EditError!void {
            try f.setList(m.key, m.vals);
        }
    };
    return self.apply(key, "Saved", key, SetList{ .key = key, .vals = vals });
}

/// Set (or with `rest == null`, remove) one keyed entry of a repeatable key
/// (a keybind trigger, a palette index). `problem_key` is the row the
/// problem shows on, when it isn't `key` itself.
pub fn setKeyed(
    self: *SettingsModel,
    key: []const u8,
    subkey: []const u8,
    rest: ?[]const u8,
    opts: ConfigFileText.KeyedOptions,
    problem_key: ?[]const u8,
) Allocator.Error!bool {
    const row = problem_key orelse key;
    if (self.sources) |s| {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const target = try opts.normalize(arena.allocator(), subkey);
        if (try s.overridingKeyed(arena.allocator(), key, target, opts)) |src| {
            try self.setProblemOwned(row, try SettingsSources.overrideMessage(self.gpa, src, subkey));
            return false;
        }
    }
    if (rest) |r| {
        const entry = try std.fmt.allocPrint(self.gpa, "{s}={s}", .{ subkey, r });
        defer self.gpa.free(entry);
        if (!try self.validate(row, key, &.{entry})) return false;
    }
    self.clearProblem(row);
    const SetKeyed = struct {
        key: []const u8,
        subkey: []const u8,
        rest: ?[]const u8,
        opts: ConfigFileText.KeyedOptions,
        pub fn apply(m: @This(), f: *ConfigFileText) ConfigFileText.EditError!void {
            try f.setKeyed(m.key, m.subkey, m.rest, m.opts);
        }
    };
    return self.apply(row, "Saved", key, SetKeyed{ .key = key, .subkey = subkey, .rest = rest, .opts = opts });
}

/// Append a raw value to a repeatable key (Add Custom Binding).
pub fn add(self: *SettingsModel, key: []const u8, val: []const u8, problem_key: ?[]const u8) Allocator.Error!bool {
    const row = problem_key orelse key;
    if (!try self.validate(row, key, &.{val})) return false;
    const Add = struct {
        key: []const u8,
        val: []const u8,
        pub fn apply(m: @This(), f: *ConfigFileText) ConfigFileText.EditError!void {
            try f.add(m.key, m.val);
        }
    };
    return self.apply(row, "Saved", key, Add{ .key = key, .val = val });
}

/// Put the file back the way it was before the last change — only if it
/// hasn't been edited since, so Undo never clobbers someone else's edit.
pub fn undoLastChange(self: *SettingsModel) Allocator.Error!UndoResult {
    const change = if (self.last_change) |*c| c else return .nothing;
    const Undo = struct {
        expected: *const ConfigFileText,
        restore: *const ConfigFileText,
        pub fn apply(m: @This(), f: *ConfigFileText) (Allocator.Error || error{ChangedSince})!void {
            // `f` is the store's fresh re-read: compare and replace in one
            // step, so an editor save can't land in between.
            if (!f.eql(m.expected)) return error.ChangedSince;
            try f.replaceWith(m.restore);
        }
    };
    var result = self.store.edit(self.gpa, Undo{ .expected = &change.after, .restore = &change.before }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ChangedSince => {
            try self.setFileError(changed_since_message);
            return .changed_since;
        },
        else => {
            try self.setFileError(errorText(err));
            return .failed;
        },
    };
    result.deinit();
    self.dismissLastChange();
    self.afterWrite();
    return .undone;
}

pub fn dismissLastChange(self: *SettingsModel) void {
    if (self.last_change) |*c| c.deinit(self.gpa);
    self.last_change = null;
}

/// Put a backup back (itself a change, so it can be undone).
pub fn restoreBackup(self: *SettingsModel, backup: []const u8) Allocator.Error!bool {
    var change = self.store.restore(self.gpa, backup) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try self.setFileError(errorText(err));
            return false;
        },
    };
    errdefer change.deinit();
    const msg = try std.fmt.allocPrint(self.gpa, "Restored {s}", .{std.fs.path.basename(backup)});
    errdefer self.gpa.free(msg);
    try self.record(&change, msg);
    self.afterWrite();
    return true;
}

// Internals

/// Render `vals` as `config_key` lines and have Ghostty parse them; on a
/// problem record it on `row` and return false.
fn validate(self: *SettingsModel, row: []const u8, config_key: []const u8, vals: []const []const u8) Allocator.Error!bool {
    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (lines.items) |l| self.gpa.free(l);
        lines.deinit(self.gpa);
    }
    for (vals) |v| {
        const line = ConfigFileText.render(self.gpa, config_key, v) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| {
                const msg = try ConfigFileText.message(self.gpa, e, config_key);
                try self.setProblemOwned(row, msg);
                return false;
            },
        };
        lines.append(self.gpa, line) catch |err| {
            self.gpa.free(line);
            return err;
        };
    }
    const const_lines: []const []const u8 = @ptrCast(lines.items);
    if (try ConfigValidator.firstProblem(self.gpa, const_lines)) |msg| {
        try self.setProblemOwned(row, msg);
        return false;
    }
    self.clearProblem(row);
    return true;
}

fn apply(self: *SettingsModel, row: []const u8, comptime verb: []const u8, key: []const u8, mutator: anytype) Allocator.Error!bool {
    return self.applyMessage(row, verb ++ " {s}", key, mutator);
}

fn applyMessage(self: *SettingsModel, row: []const u8, comptime fmt: []const u8, key: []const u8, mutator: anytype) Allocator.Error!bool {
    var change = self.store.edit(self.gpa, mutator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Multiline, error.LineTooLong => |e| {
            try self.setProblemOwned(row, try ConfigFileText.message(self.gpa, e, key));
            return false;
        },
        else => {
            try self.setProblem(row, errorText(err));
            return false;
        },
    };
    errdefer change.deinit();
    if (!change.changed()) {
        change.deinit();
        return true;
    }
    const msg = try std.fmt.allocPrint(self.gpa, fmt, .{key});
    errdefer self.gpa.free(msg);
    try self.record(&change, msg);
    self.afterWrite();
    return true;
}

/// Take ownership of `change` and `msg` as the last change.
fn record(self: *SettingsModel, change: *ConfigFileStore.Change, msg: []u8) Allocator.Error!void {
    const diff = try lineDiff(self.gpa, &change.before, &change.after);
    errdefer {
        freeLines(self.gpa, diff.removed);
        freeLines(self.gpa, diff.added);
    }
    const backed: ?[]u8 = if (self.store.backup_path) |b| try self.gpa.dupe(u8, b) else null;
    self.dismissLastChange();
    self.change_seq +%= 1;
    self.last_change = .{
        .message = msg,
        .removed = diff.removed,
        .added = diff.added,
        .backed_up_to = backed,
        .before = change.before,
        .after = change.after,
    };
}

fn afterWrite(self: *SettingsModel) void {
    if (self.file_error) |f| self.gpa.free(f);
    self.file_error = null;
    self.reload.call();
}

fn setProblem(self: *SettingsModel, key: []const u8, msg: []const u8) Allocator.Error!void {
    try self.setProblemOwned(key, try self.gpa.dupe(u8, msg));
}

/// Record `msg` (owned, freed on failure) as `key`'s problem.
fn setProblemOwned(self: *SettingsModel, key: []const u8, msg: []u8) Allocator.Error!void {
    errdefer self.gpa.free(msg);
    const gop = try self.problems.getOrPut(self.gpa, key);
    if (gop.found_existing) {
        self.gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = self.gpa.dupe(u8, key) catch |err| {
            self.problems.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    gop.value_ptr.* = msg;
}

fn clearProblem(self: *SettingsModel, key: []const u8) void {
    if (self.problems.fetchRemove(key)) |kv| {
        self.gpa.free(kv.key);
        self.gpa.free(kv.value);
    }
}

fn setFileError(self: *SettingsModel, msg: []const u8) Allocator.Error!void {
    const owned = try self.gpa.dupe(u8, msg);
    if (self.file_error) |f| self.gpa.free(f);
    self.file_error = owned;
}

/// The row/file text for a store failure.
fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.NotUtf8 => "The config file isn't UTF-8 text, so Settings won't edit it.",
        error.SymLinkLoop => "The config file is a chain of links that never reaches a file.",
        error.AccessDenied => "Settings isn't allowed to write the config file.",
        error.FileNotFound => "The file couldn't be found.",
        else => "The config file couldn't be read or written.",
    };
}

pub const Diff = struct { removed: [][]u8, added: [][]u8 };

/// Lines only in `a` / only in `b` (multiset difference — enough for the
/// toast, which shows what one surgical edit touched). Caller frees both.
pub fn lineDiff(gpa: Allocator, a: *const ConfigFileText, b: *const ConfigFileText) Allocator.Error!Diff {
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    defer counts.deinit(gpa);
    for (a.lines.items) |line| {
        const gop = try counts.getOrPut(gpa, line.text);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    var added: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer freeList(gpa, &added);
    for (b.lines.items) |line| {
        if (counts.getPtr(line.text)) |n| if (n.* > 0) {
            n.* -= 1;
            continue;
        };
        try appendDupe(gpa, &added, line.text);
    }
    // What is left in `counts` is only in `a`, taken in `a`'s order.
    var removed: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer freeList(gpa, &removed);
    for (a.lines.items) |line| {
        const n = counts.getPtr(line.text) orelse continue;
        if (n.* == 0) continue;
        n.* -= 1;
        try appendDupe(gpa, &removed, line.text);
    }
    const r = try removed.toOwnedSlice(gpa);
    errdefer freeLines(gpa, r);
    return .{ .removed = r, .added = try added.toOwnedSlice(gpa) };
}

fn appendDupe(gpa: Allocator, list: *std.ArrayListUnmanaged([]u8), text: []const u8) Allocator.Error!void {
    const owned = try gpa.dupe(u8, text);
    list.append(gpa, owned) catch |err| {
        gpa.free(owned);
        return err;
    };
}

fn freeList(gpa: Allocator, list: *std.ArrayListUnmanaged([]u8)) void {
    for (list.items) |s| gpa.free(s);
    list.deinit(gpa);
}

fn freeLines(gpa: Allocator, lines: [][]u8) void {
    for (lines) |s| gpa.free(s);
    gpa.free(lines);
}

// Tests: a port of the Mac `SettingsModelTests` write-path cases
// (validValuesAreWrittenAndReloaded, invalidValuesAreShownAndNeverWritten,
// resetRemovesTheKey, undoPutsTheFileBack, undoNeverClobbersAnOutsideEdit,
// keybindsAreKeyedByTrigger, listsAndFlagsRoundTrip).

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    path: []u8,
    backups: []u8,
    store: ConfigFileStore,
    reloads: usize = 0,
    model: SettingsModel,

    /// Heap-allocated so the model's pointers into it stay put.
    fn create(text: ?[]const u8) !*Fixture {
        const a = testing.allocator;
        const f = try a.create(Fixture);
        errdefer a.destroy(f);
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        const root = try f.tmp.dir.realpathAlloc(a, ".");
        defer a.free(root);
        f.path = try std.fs.path.join(a, &.{ root, "config.ghostty" });
        f.backups = try std.fs.path.join(a, &.{ root, "backups" });
        if (text) |t| try f.tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = t });
        f.store = try ConfigFileStore.init(a, f.path, f.backups, .{});
        f.reloads = 0;
        f.model = SettingsModel.init(a, &f.store, .{ .ctx = f, .func = countReload });
        return f;
    }

    fn countReload(ctx: ?*anyopaque) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        f.reloads += 1;
    }

    fn destroy(f: *Fixture) void {
        const a = testing.allocator;
        f.model.deinit();
        f.store.deinit();
        a.free(f.path);
        a.free(f.backups);
        f.tmp.cleanup();
        a.destroy(f);
    }

    fn write(f: *Fixture, data: []const u8) !void {
        try f.tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = data });
    }

    fn expectContents(f: *Fixture, expected: []const u8) !void {
        const got = try f.tmp.dir.readFileAlloc(testing.allocator, "config.ghostty", ConfigFileStore.max_bytes);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(expected, got);
    }

    fn backupCount(f: *Fixture) !usize {
        const list = try f.store.backups(testing.allocator);
        defer freeLines(testing.allocator, list);
        return list.len;
    }
};

test "SettingsModel: valid values are written and reloaded" {
    const f = try Fixture.create("# mine\n");
    defer f.destroy();
    try testing.expect(try f.model.set("font-size", "15"));
    try f.expectContents("# mine\nfont-size = 15\n");
    try testing.expectEqual(@as(usize, 1), f.reloads);
    const c = f.model.last_change.?;
    try testing.expectEqualStrings("Saved font-size", c.message);
    try testing.expectEqual(@as(usize, 1), c.added.len);
    try testing.expectEqualStrings("font-size = 15", c.added[0]);
    try testing.expectEqual(@as(usize, 0), c.removed.len);
    try testing.expect(c.backed_up_to != null);
}

test "SettingsModel: invalid values are shown and never written" {
    const f = try Fixture.create("# mine\n");
    defer f.destroy();
    try testing.expect(!try f.model.set("font-size", "huge"));
    try testing.expectEqualStrings("invalid value \"huge\"", f.model.problem("font-size").?);
    try f.expectContents("# mine\n");
    try testing.expectEqual(@as(usize, 0), f.reloads);
    try testing.expect(f.model.last_change == null);
    // A refusal is not a change: no backup was taken for it.
    try testing.expectEqual(@as(usize, 0), try f.backupCount());
    // A good value clears the problem.
    try testing.expect(try f.model.set("font-size", "12"));
    try testing.expect(f.model.problem("font-size") == null);
    try f.expectContents("# mine\nfont-size = 12\n");
}

test "SettingsModel: a value render refuses is a row problem too" {
    const f = try Fixture.create("# mine\n");
    defer f.destroy();
    try testing.expect(!try f.model.set("font-family", "a\nb"));
    try testing.expect(std.mem.indexOf(u8, f.model.problem("font-family").?, "line break") != null);
    try f.expectContents("# mine\n");
    try testing.expectEqual(@as(usize, 0), f.reloads);
}

test "SettingsModel: one bad line in a list refuses the whole list" {
    const f = try Fixture.create("font-feature = -liga\n");
    defer f.destroy();
    try testing.expect(!try f.model.setList("font-size", &.{ "12", "nope" }));
    try testing.expect(f.model.problem("font-size") != null);
    try f.expectContents("font-feature = -liga\n");
}

test "SettingsModel: reset removes the key" {
    const f = try Fixture.create("font-size = 15\n# keep\n");
    defer f.destroy();
    try testing.expect(try f.model.reset("font-size"));
    try f.expectContents("# keep\n");
    try testing.expectEqualStrings("Reset font-size to its default", f.model.last_change.?.message);
    try testing.expectEqualStrings("font-size = 15", f.model.last_change.?.removed[0]);
}

test "SettingsModel: undo puts the file back" {
    const f = try Fixture.create("# a\nfont-size = 12\n");
    defer f.destroy();
    try testing.expect(try f.model.set("font-size", "16"));
    try f.expectContents("# a\nfont-size = 16\n");
    try testing.expectEqual(UndoResult.undone, try f.model.undoLastChange());
    try f.expectContents("# a\nfont-size = 12\n");
    try testing.expect(f.model.last_change == null);
    try testing.expectEqual(@as(usize, 2), f.reloads);
    try testing.expectEqual(UndoResult.nothing, try f.model.undoLastChange());
}

test "SettingsModel: undo never clobbers an outside edit" {
    const f = try Fixture.create("font-size = 12\n");
    defer f.destroy();
    try testing.expect(try f.model.set("font-size", "16"));
    try f.write("font-size = 16\n# typed by hand\n");
    try testing.expectEqual(UndoResult.changed_since, try f.model.undoLastChange());
    try f.expectContents("font-size = 16\n# typed by hand\n");
    try testing.expectEqualStrings(changed_since_message, f.model.file_error.?);
    try testing.expectEqual(@as(usize, 1), f.reloads);
    // The change is still offered, so undo works again once the file is back.
    try testing.expect(f.model.last_change != null);
    try f.write("font-size = 16\n");
    try testing.expectEqual(UndoResult.undone, try f.model.undoLastChange());
    try f.expectContents("font-size = 12\n");
    try testing.expect(f.model.file_error == null);
}

test "SettingsModel: undo refuses even an edit that only changed line endings" {
    const f = try Fixture.create("font-size = 12\n");
    defer f.destroy();
    try testing.expect(try f.model.set("font-size", "16"));
    try f.write("font-size = 16\r\n");
    try testing.expectEqual(UndoResult.changed_since, try f.model.undoLastChange());
    try f.expectContents("font-size = 16\r\n");
}

test "SettingsModel: undo refuses when the file was deleted" {
    const f = try Fixture.create("font-size = 12\n");
    defer f.destroy();
    try testing.expect(try f.model.set("font-size", "16"));
    try f.tmp.dir.deleteFile("config.ghostty");
    try testing.expectEqual(UndoResult.changed_since, try f.model.undoLastChange());
    try testing.expectError(error.FileNotFound, f.tmp.dir.access("config.ghostty", .{}));
}

fn testTrigger(alloc: Allocator, val: []const u8) Allocator.Error!?[]const u8 {
    // `trigger=action` -> trigger, with cmd folded to super.
    const eq = std.mem.lastIndexOfScalar(u8, val, '=') orelse return null;
    return try std.mem.replaceOwned(u8, alloc, val[0..eq], "cmd", "super");
}

fn testNormalize(alloc: Allocator, s: []const u8) Allocator.Error![]const u8 {
    return std.mem.replaceOwned(u8, alloc, s, "cmd", "super");
}

test "SettingsModel: keybinds are keyed by trigger, and an unknown action is refused" {
    const f = try Fixture.create("keybind = ctrl+k=clear_screen\n");
    defer f.destroy();
    const opts: ConfigFileText.KeyedOptions = .{ .subkeyOf = testTrigger, .normalize = testNormalize };
    try testing.expect(try f.model.setKeyed("keybind", "ctrl+k", "new_tab", opts, null));
    try f.expectContents("keybind = ctrl+k=new_tab\n");
    try testing.expect(!try f.model.setKeyed("keybind", "ctrl+j", "not_an_action", opts, "binding:ctrl+j"));
    try testing.expect(f.model.problem("binding:ctrl+j") != null);
    try testing.expect(f.model.problem("keybind") == null);
    try f.expectContents("keybind = ctrl+k=new_tab\n");
    // Removing a keyed entry needs no validation.
    try testing.expect(try f.model.setKeyed("keybind", "ctrl+k", null, opts, null));
    try f.expectContents("");
}

test "SettingsModel: a key a later include sets is refused, not silently overridden" {
    const original = "config-file = work.ghostty\nfont-size = 12\n";
    const f = try Fixture.create(original);
    defer f.destroy();
    try f.tmp.dir.writeFile(.{ .sub_path = "work.ghostty", .data = "font-size = 16\nkeybind = cmd+k=clear_screen\n" });
    var sources = try SettingsSources.load(testing.allocator, f.path, &.{});
    defer sources.deinit();
    f.model.sources = &sources;

    try testing.expect(!try f.model.set("font-size", "14"));
    try testing.expectEqualStrings(
        "Set in work.ghostty, which loads after your config \u{2014} change it there.",
        f.model.problem("font-size").?,
    );
    // The keybind trigger matches after normalization (`super` = `cmd`).
    const opts: ConfigFileText.KeyedOptions = .{ .subkeyOf = testTrigger, .normalize = testNormalize };
    try testing.expect(!try f.model.setKeyed("keybind", "super+k", "new_tab", opts, null));
    try testing.expect(f.model.problem("keybind") != null);
    try f.expectContents(original);
    try testing.expectEqual(@as(usize, 0), f.reloads);

    // A key nothing later sets is still written.
    try testing.expect(try f.model.set("cursor-style", "bar"));
    try testing.expect(try f.model.setKeyed("keybind", "ctrl+j", "new_tab", opts, null));
}

test "SettingsModel: lists, flags and custom bindings round-trip" {
    const f = try Fixture.create("");
    defer f.destroy();
    try testing.expect(try f.model.setList("font-feature", &.{ "-calt", "ss01" }));
    try testing.expect(try f.model.set("shell-integration-features", "cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path"));
    try testing.expect(try f.model.add("keybind", "ctrl+shift+y=new_window", null));
    try testing.expect(!try f.model.add("keybind", "ctrl+shift+u=bogus_action", null));
    try f.expectContents("font-feature = -calt\nfont-feature = ss01\n" ++
        "shell-integration-features = cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path\n" ++
        "keybind = ctrl+shift+y=new_window\n");
}

test "SettingsModel: a no-op edit records no change and doesn't reload" {
    const f = try Fixture.create("font-size = 12\n");
    defer f.destroy();
    try testing.expect(try f.model.set("font-size", "12"));
    try testing.expect(f.model.last_change == null);
    try testing.expectEqual(@as(usize, 0), f.reloads);
}

test "SettingsModel: a file that isn't UTF-8 is a row problem and stays untouched" {
    const f = try Fixture.create("font-size = \xff\n");
    defer f.destroy();
    try testing.expect(!try f.model.set("font-size", "14"));
    try testing.expect(std.mem.indexOf(u8, f.model.problem("font-size").?, "UTF-8") != null);
    try f.expectContents("font-size = \xff\n");
}

test "SettingsModel: restoring a backup is itself an undoable change" {
    const f = try Fixture.create("font-size = 12\n");
    defer f.destroy();
    try testing.expect(try f.model.set("font-size", "16"));
    const backup = try testing.allocator.dupe(u8, f.model.last_change.?.backed_up_to.?);
    defer testing.allocator.free(backup);
    try testing.expect(try f.model.restoreBackup(backup));
    try f.expectContents("font-size = 12\n");
    try testing.expect(std.mem.startsWith(u8, f.model.last_change.?.message, "Restored config.ghostty."));
    try testing.expectEqual(UndoResult.undone, try f.model.undoLastChange());
    try f.expectContents("font-size = 16\n");
}

test "SettingsModel: lineDiff is a multiset difference" {
    var a = try ConfigFileText.init(testing.allocator, "x\ny\nx\nz\n");
    defer a.deinit();
    var b = try ConfigFileText.init(testing.allocator, "x\nz\nw\n");
    defer b.deinit();
    const d = try lineDiff(testing.allocator, &a, &b);
    defer freeLines(testing.allocator, d.removed);
    defer freeLines(testing.allocator, d.added);
    try testing.expectEqual(@as(usize, 2), d.removed.len);
    try testing.expectEqualStrings("x", d.removed[0]);
    try testing.expectEqualStrings("y", d.removed[1]);
    try testing.expectEqual(@as(usize, 1), d.added.len);
    try testing.expectEqualStrings("w", d.added[0]);
}
