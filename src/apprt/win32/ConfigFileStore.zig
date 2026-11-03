//! Reads and writes the user's config file for the Settings window (T2583;
//! the win32 port of Mac `ConfigFileStore.swift`, 92103f39d).
//!
//! Every write re-reads the file from disk first, so an edit the user made
//! in their editor a moment ago is never clobbered by stale state; then it
//! applies one surgical `ConfigFileText` edit and writes the result back.
//!
//! - A symlinked config (dotfiles) is written through the link, to its
//!   target, so the link survives.
//! - The write is atomic: `managed_file.writeAtomicNoFollow` on the resolved
//!   target (temp beside it, then one NT rename). Mac's "keeps the file's
//!   permissions" has no `mode_t` here; as in `managed_file`, the replaced
//!   file takes the folder's inherited ACL, which for `%LOCALAPPDATA%` is
//!   already owner-only.
//! - Before the first change in a session the current file is copied to
//!   `backup_dir` (`<name>.<yyyyMMdd-HHmmss>`, local time; the newest
//!   `backups_kept` are kept). A missing or empty file isn't backed up.
//! - A missing file (and its directories) is created on first write.
//! - A file that isn't UTF-8 is refused, untouched.
//!
//! Which file and which backup folder are the caller's: the Settings window
//! passes `file_load.preferredDefaultFilePath` (a development build's own
//! `config-debug.ghostty`, T2582) and `defaultBackupDir`.
const ConfigFileStore = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const ConfigFileText = @import("ConfigFileText.zig");
const managed_file = @import("managed_file.zig");

/// A wall-clock reading for a backup's name.
pub const Stamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub const Clock = *const fn () Stamp;

pub const Options = struct {
    backups_kept: usize = 10,
    now: Clock = localNow,
};

/// The store's own refusals, beside the file-system errors it passes on.
pub const Error = error{
    /// The file isn't UTF-8 text, so Settings won't edit it.
    NotUtf8,
    /// A chain of symlinks that never reaches a file.
    SymLinkLoop,
};

/// The biggest config Settings will read.
pub const max_bytes = 16 * 1024 * 1024;

gpa: Allocator,
/// The config file as the app loads it (may be a symlink).
path: []u8,
backup_dir: []u8,
backups_kept: usize,
now: Clock,
/// Where this session's backup went, once one was made.
backup_path: ?[]u8 = null,
backup_done: bool = false,

pub fn init(gpa: Allocator, path: []const u8, backup_dir: []const u8, opts: Options) Allocator.Error!ConfigFileStore {
    const p = try gpa.dupe(u8, path);
    errdefer gpa.free(p);
    return .{
        .gpa = gpa,
        .path = p,
        .backup_dir = try gpa.dupe(u8, backup_dir),
        .backups_kept = opts.backups_kept,
        .now = opts.now,
    };
}

pub fn deinit(self: *ConfigFileStore) void {
    self.gpa.free(self.path);
    self.gpa.free(self.backup_dir);
    if (self.backup_path) |b| self.gpa.free(b);
    self.* = undefined;
}

/// `%LOCALAPPDATA%\ghoztty\config-backups` — beside the rest of the
/// per-user Ghoztty state. Release and development builds share it: a
/// backup is named after its file, and the two builds write different files
/// (`config.ghostty` / `config-debug.ghostty`), so neither prunes the
/// other's. Caller owns the result.
pub fn defaultBackupDir(alloc: Allocator) ![]u8 {
    const base = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
    defer alloc.free(base);
    return std.fs.path.join(alloc, &.{ base, "ghoztty", "config-backups" });
}

/// The file the bytes live in: `path` with symlinks resolved (a dangling
/// link resolves to the file it names). Caller owns the result.
pub fn targetPath(self: *const ConfigFileStore, alloc: Allocator) ![]u8 {
    var current = try alloc.dupe(u8, self.path);
    errdefer alloc.free(current);
    var hops: usize = 0;
    while (hops < 32) : (hops += 1) {
        // Ask first: Windows `readLink` on a plain file is `Unexpected`.
        if (!managed_file.isReparsePoint(std.fs.cwd(), current)) return current;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const link = std.fs.cwd().readLink(current, &buf) catch |err| switch (err) {
            error.NotLink, error.FileNotFound => return current,
            else => return err,
        };
        const next = if (std.fs.path.isAbsolute(link))
            try alloc.dupe(u8, link)
        else
            try std.fs.path.resolve(alloc, &.{ std.fs.path.dirname(current) orelse ".", link });
        alloc.free(current);
        current = next;
    }
    return error.SymLinkLoop;
}

/// The current contents (empty if the file doesn't exist yet).
pub fn read(self: *const ConfigFileStore, alloc: Allocator) !ConfigFileText {
    const target = try self.targetPath(alloc);
    defer alloc.free(target);
    return readText(alloc, target);
}

fn readText(alloc: Allocator, path: []const u8) !ConfigFileText {
    const data = std.fs.cwd().readFileAlloc(alloc, path, max_bytes) catch |err| switch (err) {
        error.FileNotFound => return ConfigFileText.init(alloc, ""),
        else => |e| return e,
    };
    defer alloc.free(data);
    if (!std.unicode.utf8ValidateSlice(data)) return error.NotUtf8;
    return ConfigFileText.init(alloc, data);
}

/// The result of one edit: the file before and after (equal if the edit
/// was a no-op, in which case nothing was written). Caller deinits.
pub const Change = struct {
    before: ConfigFileText,
    after: ConfigFileText,

    pub fn changed(self: *const Change) bool {
        return !self.before.eql(&self.after);
    }

    pub fn deinit(self: *Change) void {
        self.before.deinit();
        self.after.deinit();
    }
};

/// Re-read the file, apply `mutator.apply(*ConfigFileText)`, and write the
/// result if it differs. `mutator` is any value with an
/// `apply(self, *ConfigFileText) !void` method; its errors are returned
/// before anything is written.
pub fn edit(self: *ConfigFileStore, alloc: Allocator, mutator: anytype) !Change {
    var before = try self.read(alloc);
    errdefer before.deinit();
    var after = try before.clone(alloc);
    errdefer after.deinit();
    try mutator.apply(&after);
    const change: Change = .{ .before = before, .after = after };
    if (!change.changed()) return change;

    const target = try self.targetPath(alloc);
    defer alloc.free(target);
    try self.backUpIfNeeded(alloc, target);

    const bytes = try after.string(alloc);
    defer alloc.free(bytes);
    // Creates the file's directories too.
    try managed_file.writeAtomicNoFollow(alloc, std.fs.cwd(), target, bytes);
    return change;
}

/// Copy the file aside once per session, before its first change. A
/// missing or empty file has nothing worth keeping.
fn backUpIfNeeded(self: *ConfigFileStore, alloc: Allocator, target: []const u8) !void {
    if (self.backup_done) return;
    self.backup_done = true;
    const stat = std.fs.cwd().statFile(target) catch return;
    if (stat.size == 0) return;

    try std.fs.cwd().makePath(self.backup_dir);
    var dir = try std.fs.cwd().openDir(self.backup_dir, .{ .iterate = true });
    defer dir.close();

    const base = std.fs.path.basename(target);
    const t = self.now();
    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    const stem = std.fmt.bufPrint(&name_buf, "{s}.{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        base, t.year, t.month, t.day, t.hour, t.minute, t.second,
    }) catch return error.NameTooLong;
    var name: []const u8 = stem;
    var dedup_buf: [std.fs.max_name_bytes]u8 = undefined;
    var n: usize = 2;
    while (exists(dir, name)) : (n += 1) {
        name = std.fmt.bufPrint(&dedup_buf, "{s}-{d}", .{ stem, n }) catch return error.NameTooLong;
    }
    try std.fs.cwd().copyFile(target, dir, name, .{});

    const full = try std.fs.path.join(self.gpa, &.{ self.backup_dir, name });
    if (self.backup_path) |old| self.gpa.free(old);
    self.backup_path = full;

    const prefix = try std.mem.concat(alloc, u8, &.{ base, "." });
    defer alloc.free(prefix);
    self.pruneBackups(alloc, dir, prefix);
}

fn exists(dir: std.fs.Dir, name: []const u8) bool {
    dir.access(name, .{}) catch return false;
    return true;
}

/// Names in `dir` starting with `prefix`, sorted ascending (timestamped
/// names sort chronologically). Caller frees each name and the slice.
fn backupNames(alloc: Allocator, dir: std.fs.Dir, prefix: []const u8) ![][]u8 {
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (names.items) |s| alloc.free(s);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, prefix)) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, lessThan);
    return names.toOwnedSlice(alloc);
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn freeNames(alloc: Allocator, names: [][]u8) void {
    for (names) |s| alloc.free(s);
    alloc.free(names);
}

fn pruneBackups(self: *const ConfigFileStore, alloc: Allocator, dir: std.fs.Dir, prefix: []const u8) void {
    const names = backupNames(alloc, dir, prefix) catch return;
    defer freeNames(alloc, names);
    if (names.len <= self.backups_kept) return;
    for (names[0 .. names.len - self.backups_kept]) |name| dir.deleteFile(name) catch {};
}

/// Backups of this config, newest first, as full paths. Caller frees each
/// path and the slice.
pub fn backups(self: *const ConfigFileStore, alloc: Allocator) ![][]u8 {
    const target = try self.targetPath(alloc);
    defer alloc.free(target);
    const prefix = try std.mem.concat(alloc, u8, &.{ std.fs.path.basename(target), "." });
    defer alloc.free(prefix);

    var dir = std.fs.cwd().openDir(self.backup_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return alloc.alloc([]u8, 0),
        else => |e| return e,
    };
    defer dir.close();
    const names = try backupNames(alloc, dir, prefix);
    defer alloc.free(names);
    std.mem.reverse([]u8, names);
    for (names) |*name| {
        const full = try std.fs.path.join(alloc, &.{ self.backup_dir, name.* });
        alloc.free(name.*);
        name.* = full;
    }
    return alloc.dupe([]u8, names);
}

/// Put a backup's contents back (itself a change, so it is backed up too).
pub fn restore(self: *ConfigFileStore, alloc: Allocator, backup: []const u8) !Change {
    var text = try readText(alloc, backup);
    defer text.deinit();
    const Restore = struct {
        text: *const ConfigFileText,
        pub fn apply(r: @This(), file: *ConfigFileText) !void {
            try file.replaceWith(r.text);
        }
    };
    return self.edit(alloc, Restore{ .text = &text });
}

/// The local wall clock (Windows `GetLocalTime`; UTC elsewhere, where this
/// file is only ever compiled for its tests).
pub fn localNow() Stamp {
    if (builtin.os.tag == .windows) {
        var st: SYSTEMTIME = undefined;
        GetLocalTime(&st);
        return .{
            .year = st.wYear,
            .month = @intCast(st.wMonth),
            .day = @intCast(st.wDay),
            .hour = @intCast(st.wHour),
            .minute = @intCast(st.wMinute),
            .second = @intCast(st.wSecond),
        };
    }
    const secs: u64 = @intCast(@max(0, std.time.timestamp()));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .year = yd.year,
        .month = md.month.numeric(),
        .day = md.day_index + 1,
        .hour = ds.getHoursIntoDay(),
        .minute = ds.getMinutesIntoHour(),
        .second = ds.getSecondsIntoMinute(),
    };
}

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;

// Tests: a port of Mac `ConfigFileStoreTests` — file I/O around the text
// editor: creation, backups, symlinks, no-op edits, outside edits, UTF-8.

const testing = std.testing;

const Set = struct {
    key: []const u8,
    val: []const u8,
    pub fn apply(m: Set, f: *ConfigFileText) !void {
        try f.set(m.key, m.val);
    }
};

/// A test fixture: a temp root with `dir/<name>` as the config and
/// `backups/` beside it.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try tmp.dir.realpathAlloc(testing.allocator, ".") };
    }

    fn deinit(f: *Fixture) void {
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn store(f: *Fixture, kept: usize, clock: Clock) !ConfigFileStore {
        const a = testing.allocator;
        const path = try std.fs.path.join(a, &.{ f.root, "dir", "config.ghostty" });
        defer a.free(path);
        const backup_dir = try std.fs.path.join(a, &.{ f.root, "backups" });
        defer a.free(backup_dir);
        return ConfigFileStore.init(a, path, backup_dir, .{ .backups_kept = kept, .now = clock });
    }

    fn write(f: *Fixture, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |d| try f.tmp.dir.makePath(d);
        try f.tmp.dir.writeFile(.{ .sub_path = sub_path, .data = data });
    }

    fn contents(f: *Fixture, sub_path: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(testing.allocator, sub_path, max_bytes);
    }

    fn expectContents(f: *Fixture, sub_path: []const u8, expected: []const u8) !void {
        const got = try f.contents(sub_path);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(expected, got);
    }
};

fn editSet(s: *ConfigFileStore, key: []const u8, val: []const u8) !bool {
    var change = try s.edit(testing.allocator, Set{ .key = key, .val = val });
    defer change.deinit();
    return change.changed();
}

fn expectBackupCount(s: *const ConfigFileStore, n: usize) !void {
    const list = try s.backups(testing.allocator);
    defer freeNames(testing.allocator, list);
    try testing.expectEqual(n, list.len);
}

const config_sub = "dir" ++ std.fs.path.sep_str ++ "config.ghostty";

var test_tick: u8 = 0;
fn testClock() Stamp {
    return .{ .year = 2027, .month = 1, .day = 15, .hour = 8, .minute = test_tick, .second = 0 };
}

test "ConfigFileStore: creates a missing file and its directory without a backup" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var s = try fx.store(10, localNow);
    defer s.deinit();
    try testing.expect(try editSet(&s, "font-size", "14"));
    try fx.expectContents(config_sub, "font-size = 14\n");
    try testing.expect(s.backup_path == null);
    try expectBackupCount(&s, 0);
}

test "ConfigFileStore: backs up once per session before the first change" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var s = try fx.store(10, localNow);
    defer s.deinit();
    try fx.write(config_sub, "# mine\nfont-size = 12\n");
    _ = try editSet(&s, "font-size", "13");
    _ = try editSet(&s, "font-size", "14");
    try expectBackupCount(&s, 1);
    const backup = try std.fs.cwd().readFileAlloc(testing.allocator, s.backup_path.?, max_bytes);
    defer testing.allocator.free(backup);
    try testing.expectEqualStrings("# mine\nfont-size = 12\n", backup);
    try fx.expectContents(config_sub, "# mine\nfont-size = 14\n");
}

test "ConfigFileStore: a new session backs up again and old backups are pruned" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write(config_sub, "a = 1\n");
    test_tick = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        test_tick += 1;
        var session = try fx.store(2, testClock);
        defer session.deinit();
        var buf: [8]u8 = undefined;
        _ = try editSet(&session, "a", try std.fmt.bufPrint(&buf, "{d}", .{i + 2}));
    }
    var s = try fx.store(2, testClock);
    defer s.deinit();
    const list = try s.backups(testing.allocator);
    defer freeNames(testing.allocator, list);
    try testing.expectEqual(@as(usize, 2), list.len);
    // Newest first: the file as it was before the last session's change.
    const newest = try std.fs.cwd().readFileAlloc(testing.allocator, list[0], max_bytes);
    defer testing.allocator.free(newest);
    try testing.expectEqualStrings("a = 4\n", newest);
    try testing.expect(std.mem.endsWith(u8, list[0], "config.ghostty.20270115-080400"));
}

test "ConfigFileStore: two sessions in the same second do not overwrite a backup" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.write(config_sub, "a = 1\n");
    test_tick = 30;
    for (0..2) |i| {
        var session = try fx.store(10, testClock);
        defer session.deinit();
        _ = try editSet(&session, "a", if (i == 0) "2" else "3");
    }
    var s = try fx.store(10, testClock);
    defer s.deinit();
    const list = try s.backups(testing.allocator);
    defer freeNames(testing.allocator, list);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expect(std.mem.endsWith(u8, list[0], "-083000-2"));
}

test "ConfigFileStore: no-op edits neither write nor back up" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var s = try fx.store(10, localNow);
    defer s.deinit();
    try fx.write(config_sub, "font-size = 14\n");
    const before = try fx.tmp.dir.statFile(config_sub);
    try testing.expect(!try editSet(&s, "font-size", "14"));
    try expectBackupCount(&s, 0);
    const after = try fx.tmp.dir.statFile(config_sub);
    try testing.expectEqual(before.mtime, after.mtime);
    try testing.expectEqual(before.inode, after.inode);
}

test "ConfigFileStore: an edit leaves no temp file behind" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var s = try fx.store(10, localNow);
    defer s.deinit();
    try fx.write(config_sub, "a = 1\n");
    _ = try editSet(&s, "a", "2");
    var dir = try fx.tmp.dir.openDir("dir", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next()) |entry| {
        n += 1;
        try testing.expectEqualStrings("config.ghostty", entry.name);
    }
    try testing.expectEqual(@as(usize, 1), n);
}

test "ConfigFileStore: writes through a symlink and keeps the link" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const a = testing.allocator;
    try fx.write("dotfiles" ++ std.fs.path.sep_str ++ "ghostty.conf", "# from dotfiles\n");
    try fx.tmp.dir.makePath("dir");
    const target = try std.fs.path.join(a, &.{ fx.root, "dotfiles", "ghostty.conf" });
    defer a.free(target);
    fx.tmp.dir.symLink(target, config_sub, .{}) catch |err| switch (err) {
        // No symlink privilege / developer mode on this box.
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    var s = try fx.store(10, localNow);
    defer s.deinit();

    _ = try editSet(&s, "font-size", "14");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try fx.tmp.dir.readLink(config_sub, &buf); // still a link
    try fx.expectContents("dotfiles" ++ std.fs.path.sep_str ++ "ghostty.conf", "# from dotfiles\nfont-size = 14\n");
}

test "ConfigFileStore: a dangling relative symlink creates the file it names" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.makePath("dir");
    fx.tmp.dir.symLink("real.ghostty", config_sub, .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    var s = try fx.store(10, localNow);
    defer s.deinit();
    _ = try editSet(&s, "a", "1");
    try fx.expectContents("dir" ++ std.fs.path.sep_str ++ "real.ghostty", "a = 1\n");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try fx.tmp.dir.readLink(config_sub, &buf);
}

test "ConfigFileStore: picks up edits made outside Settings" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var s = try fx.store(10, localNow);
    defer s.deinit();
    try fx.write(config_sub, "a = 1\n");
    _ = try editSet(&s, "b", "2");
    // The user edits the file in their editor…
    try fx.write(config_sub, "a = 1\n# added by hand\nb = 2\nc = 3\n");
    // …and the next Settings change keeps their edit.
    _ = try editSet(&s, "a", "9");
    try fx.expectContents(config_sub, "a = 9\n# added by hand\nb = 2\nc = 3\n");
}

test "ConfigFileStore: CRLF and BOM survive a store write byte for byte" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var s = try fx.store(10, localNow);
    defer s.deinit();
    try fx.write(config_sub, "\u{FEFF}# win\r\nconfig-file = ?work.ghostty\r\nfont-size = 12\r\n");
    _ = try editSet(&s, "font-size", "13");
    try fx.expectContents(config_sub, "\u{FEFF}# win\r\nconfig-file = ?work.ghostty\r\nfont-size = 13\r\n");
}

test "ConfigFileStore: refuses non-UTF-8 files and leaves them alone" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var s = try fx.store(10, localNow);
    defer s.deinit();
    const bytes = [_]u8{ 0x61, 0x20, 0x3D, 0x20, 0xFF, 0xFE, 0x0A };
    try fx.write(config_sub, &bytes);
    try testing.expectError(error.NotUtf8, s.edit(testing.allocator, Set{ .key = "a", .val = "2" }));
    try fx.expectContents(config_sub, &bytes);
    try expectBackupCount(&s, 0);
}

test "ConfigFileStore: an invalid value is refused before anything is written" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var s = try fx.store(10, localNow);
    defer s.deinit();
    try fx.write(config_sub, "a = 1\n");
    try testing.expectError(error.Multiline, s.edit(testing.allocator, Set{ .key = "title", .val = "x\ny" }));
    try fx.expectContents(config_sub, "a = 1\n");
    try expectBackupCount(&s, 0);
}

test "ConfigFileStore: restores a backup" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var s = try fx.store(10, localNow);
    defer s.deinit();
    try fx.write(config_sub, "a = 1\n");
    _ = try editSet(&s, "a", "2");
    var change = try s.restore(testing.allocator, s.backup_path.?);
    defer change.deinit();
    try testing.expect(change.changed());
    try fx.expectContents(config_sub, "a = 1\n");
}

test "ConfigFileStore: the default backup folder sits under LOCALAPPDATA" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;
    const dir = try defaultBackupDir(a);
    defer a.free(dir);
    try testing.expect(std.mem.endsWith(u8, dir, "\\ghoztty\\config-backups"));
}
