//! Which files Ghostty loads, in order, and what the Settings window reads
//! from them (T2584a; the win32 port of the reading half of Mac
//! `SettingsModel.swift`, 9287de0ff: `loadSources`, `overridingSource`,
//! `value`, `values`, `isModified`, and the All Settings search).
//!
//! Load order, as `Config.loadDefaultFiles` + `loadRecursiveFiles` run it on
//! Windows: the XDG legacy file (`ghostty\config`), the XDG file
//! (`ghostty\config.ghostty`), a development build's own
//! `config-debug.ghostty`, then `config-file` includes in the order Ghostty
//! processes them (after every default file; nested includes appended; a
//! relative path is relative to the including file; a leading `?` marks an
//! optional include). Windows does not expand `~` in config paths, so
//! neither does this.
//!
//! A key set by a file that loads AFTER the user's own file wins, so the
//! window shows that row read-only and refuses to write it; `overriding`
//! and `overrideMessage` are that rule. A keybind trigger set in a later
//! include is refused the same way (`overridingKeyed`).
const SettingsSources = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const ConfigFileText = @import("ConfigFileText.zig");
const ConfigFileStore = @import("ConfigFileStore.zig");
const SettingsCatalog = @import("SettingsCatalog.zig");
const file_load = @import("../../config/file_load.zig");

pub const Source = struct {
    path: []u8,
    text: ConfigFileText,
    /// Reached through `config-file` rather than a default location.
    included: bool,

    /// The file name, as the row's "Set in work.ghostty" names it.
    pub fn name(self: *const Source) []const u8 {
        return std.fs.path.basename(self.path);
    }
};

gpa: Allocator,
sources: std.ArrayListUnmanaged(Source) = .empty,
/// Where the user's own file sits in the load order.
main_index: ?usize = null,

/// Read every file Ghostty would load. `main_path` is the file Settings
/// writes (it anchors relative includes even when it does not exist yet);
/// `default_paths` are the default locations in load order
/// (`defaultFilePaths`, or a test's own).
pub fn load(gpa: Allocator, main_path: []const u8, default_paths: []const []const u8) Allocator.Error!SettingsSources {
    var self: SettingsSources = .{ .gpa = gpa };
    errdefer self.deinit();

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (default_paths) |p| {
        const key = try identity(sa, p);
        if (seen.contains(key)) continue;
        var text = (try readText(gpa, p)) orelse continue;
        errdefer text.deinit();
        try seen.put(sa, key, {});
        try self.append(p, text, false);
    }

    const main_key = try identity(sa, main_path);
    if (!seen.contains(main_key)) {
        try seen.put(sa, main_key, {});
        var text = (try readText(gpa, main_path)) orelse try ConfigFileText.init(gpa, "");
        errdefer text.deinit();
        try self.append(main_path, text, false);
    }

    // Breadth-first over includes, appending as Ghostty does.
    var index: usize = 0;
    while (index < self.sources.items.len) : (index += 1) {
        // Copy what we need: `append` below may move `sources`.
        const from = try sa.dupe(u8, self.sources.items[index].path);
        const includes = try self.sources.items[index].text.values(sa, "config-file");
        for (includes) |raw| {
            const target = try includePath(sa, from, raw) orelse continue;
            const key = try identity(sa, target);
            if (seen.contains(key)) continue;
            var text = (try readText(gpa, target)) orelse continue;
            errdefer text.deinit();
            try seen.put(sa, key, {});
            try self.append(target, text, true);
        }
    }

    // The LAST source that is the user's file (Mac: `lastIndex`).
    var i = self.sources.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, try identity(sa, self.sources.items[i].path), main_key)) {
            self.main_index = i;
            break;
        }
    }
    return self;
}

pub fn deinit(self: *SettingsSources) void {
    for (self.sources.items) |*s| {
        self.gpa.free(s.path);
        s.text.deinit();
    }
    self.sources.deinit(self.gpa);
    self.* = undefined;
}

fn append(self: *SettingsSources, path: []const u8, text: ConfigFileText, included: bool) Allocator.Error!void {
    const owned = try self.gpa.dupe(u8, path);
    errdefer self.gpa.free(owned);
    try self.sources.append(self.gpa, .{ .path = owned, .text = text, .included = included });
}

/// The default files Ghostty loads on this platform, in load order. Caller
/// frees each path and the slice.
pub fn defaultFilePaths(alloc: Allocator) ![][]u8 {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p);
        out.deinit(alloc);
    }
    try out.append(alloc, @constCast(try file_load.legacyDefaultXdgPath(alloc)));
    try out.append(alloc, @constCast(try file_load.defaultXdgPath(alloc)));
    if (comptime file_load.uses_dev_xdg_path) {
        try out.append(alloc, @constCast(try file_load.devXdgPath(alloc)));
    }
    return out.toOwnedSlice(alloc);
}

/// `config-file` value -> the path Ghostty opens: `?` (optional) and one
/// pair of quotes dropped, relative paths taken from the including file's
/// folder. `null` for an empty value (a reset line).
pub fn includePath(alloc: Allocator, including_file: []const u8, raw: []const u8) Allocator.Error!?[]const u8 {
    var p = raw;
    if (p.len > 0 and p[0] == '?') p = p[1..];
    if (p.len >= 2 and p[0] == '"' and p[p.len - 1] == '"') p = p[1 .. p.len - 1];
    if (p.len == 0) return null;
    if (std.fs.path.isAbsolute(p)) return try alloc.dupe(u8, p);
    const dir = std.fs.path.dirname(including_file) orelse ".";
    return try std.fs.path.join(alloc, &.{ dir, p });
}

/// A path's identity for "is this the same file": symlinks resolved when
/// the file exists, `.`/`..` collapsed, and - on Windows, whose file system
/// is case-insensitive - ASCII-lowercased with `/` read as `\`.
fn identity(alloc: Allocator, path: []const u8) Allocator.Error![]u8 {
    const resolved = std.fs.cwd().realpathAlloc(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try std.fs.path.resolve(alloc, &.{path}),
    };
    if (builtin.os.tag == .windows) {
        for (resolved) |*c| {
            c.* = if (c.* == '/') '\\' else std.ascii.toLower(c.*);
        }
    }
    return resolved;
}

/// A config file's text, or null when it is missing, unreadable or not
/// UTF-8 (Mac skips those the same way).
fn readText(gpa: Allocator, path: []const u8) Allocator.Error!?ConfigFileText {
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, ConfigFileStore.max_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(bytes);
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    return try ConfigFileText.init(gpa, bytes);
}

/// Does `text` have a line setting `key`?
pub fn setsKey(text: *const ConfigFileText, key: []const u8) bool {
    for (text.lines.items) |line| {
        const p = ConfigFileText.parse(line.text) orelse continue;
        if (std.mem.eql(u8, p.key, key)) return true;
    }
    return false;
}

/// The user's own file, if it is in the load order.
pub fn main(self: *const SettingsSources) ?*const Source {
    const i = self.main_index orelse return null;
    return &self.sources.items[i];
}

/// A file Ghostty loads AFTER the user's file that also sets `key`: it
/// wins, so an edit here would be silently overridden. The last such file
/// (the one whose value is the effective one).
pub fn overriding(self: *const SettingsSources, key: []const u8) ?*const Source {
    const mine = self.main_index orelse return null;
    var i = self.sources.items.len;
    while (i > mine + 1) {
        i -= 1;
        if (setsKey(&self.sources.items[i].text, key)) return &self.sources.items[i];
    }
    return null;
}

/// The same, for one keyed entry of a repeatable key (a keybind trigger, a
/// palette index). `subkey` is already normalized; `opts.subkeyOf` reads
/// (and normalizes) each line's subkey.
pub fn overridingKeyed(
    self: *const SettingsSources,
    alloc: Allocator,
    key: []const u8,
    subkey: []const u8,
    opts: ConfigFileText.KeyedOptions,
) Allocator.Error!?*const Source {
    const mine = self.main_index orelse return null;
    var i = self.sources.items.len;
    while (i > mine + 1) {
        i -= 1;
        for (self.sources.items[i].text.lines.items) |line| {
            const p = ConfigFileText.parse(line.text) orelse continue;
            if (!std.mem.eql(u8, p.key, key)) continue;
            const v = p.value orelse continue;
            const sk = (try opts.subkeyOf(alloc, v)) orelse continue;
            if (std.mem.eql(u8, sk, subkey)) return &self.sources.items[i];
        }
    }
    return null;
}

/// The row's read-only note for an overridden key (Mac's text, word for
/// word). `subkey` names a keyed entry. Caller owns the result.
pub fn overrideMessage(alloc: Allocator, source: *const Source, subkey: ?[]const u8) Allocator.Error![]u8 {
    if (subkey) |sk| return std.fmt.allocPrint(
        alloc,
        "{s} is set in {s}, which loads after your config \u{2014} change it there.",
        .{ sk, source.name() },
    );
    return std.fmt.allocPrint(
        alloc,
        "Set in {s}, which loads after your config \u{2014} change it there.",
        .{source.name()},
    );
}

/// How many loaded files set `key`.
pub fn countSetting(self: *const SettingsSources, key: []const u8) usize {
    var n: usize = 0;
    for (self.sources.items) |*s| {
        if (setsKey(&s.text, key)) n += 1;
    }
    return n;
}

/// What a Settings row reads. `catalog` is the defaults (with docs),
/// `effective` the live config, `file` the user's own file as last read.
pub const Reader = struct {
    catalog: *const SettingsCatalog,
    effective: *const SettingsCatalog,
    sources: *const SettingsSources,
    file: *const ConfigFileText,

    /// The effective value of a plain key. When the user's file sets it and
    /// no later file overrides it, that line IS the effective value - read
    /// straight from the file, which also shows a change at once rather
    /// than after the reload round-trip. A bare flag line reads "true".
    pub fn value(self: Reader, key: []const u8) []const u8 {
        const repeatable = if (self.catalog.get(key)) |e| e.repeatable else false;
        if (!repeatable and self.sources.overriding(key) == null) {
            if (self.file.value(key)) |file_value| return file_value orelse "true";
        }
        if (self.effective.get(key)) |e| return e.value();
        if (self.catalog.get(key)) |e| return e.value();
        return "";
    }

    /// The effective values of a repeatable key. For a key with no default
    /// values (`font-family`, `env`, ...) that only the user's file sets,
    /// the file's lines are the whole list. Caller owns the outer slice; the
    /// strings are borrowed.
    pub fn values(self: Reader, alloc: Allocator, key: []const u8) Allocator.Error![]const []const u8 {
        const file_values = try self.file.values(alloc, key);
        const defaults_empty = if (self.catalog.get(key)) |e| allEmpty(e.values) else true;
        const set_elsewhere = self.sources.countSetting(key) > 1;
        if (file_values.len > 0 and defaults_empty and !set_elsewhere) return file_values;
        alloc.free(file_values);
        const src = self.effective.get(key) orelse self.catalog.get(key) orelse return alloc.alloc([]const u8, 0);
        return alloc.dupe([]const u8, src.values);
    }

    /// The user's file sets this key.
    pub fn isSetInFile(self: Reader, key: []const u8) bool {
        return setsKey(self.file, key);
    }

    /// Differs from the default - set here or in another file. Drives the
    /// row's changed dot and the "Changed" filter.
    pub fn isModified(self: Reader, key: []const u8) bool {
        if (self.isSetInFile(key)) return true;
        const eff: []const []const u8 = if (self.effective.get(key)) |e| e.values else &.{};
        const def: []const []const u8 = if (self.catalog.get(key)) |e| e.values else &.{};
        if (eff.len != def.len) return true;
        for (eff, def) |a, b| if (!std.mem.eql(u8, a, b)) return true;
        return false;
    }

    /// All Settings search: the key, its documentation, or any current
    /// value contains `query`, case-insensitively.
    pub fn matches(self: Reader, alloc: Allocator, key: []const u8, query: []const u8) Allocator.Error!bool {
        if (SettingsCatalog.containsIgnoreCase(key, query)) return true;
        const repeatable = if (self.catalog.get(key)) |e| e.repeatable else false;
        if (self.catalog.get(key)) |e| {
            if (e.doc) |d| if (SettingsCatalog.containsIgnoreCase(d, query)) return true;
        }
        // A plain key matches on what its row shows, which is the file's
        // line before the reload lands (Mac's `values` would still read the
        // old live value there).
        if (!repeatable) return SettingsCatalog.containsIgnoreCase(self.value(key), query);
        const vals = try self.values(alloc, key);
        defer alloc.free(vals);
        for (vals) |v| if (SettingsCatalog.containsIgnoreCase(v, query)) return true;
        return false;
    }

    pub const Filter = enum { all, changed };

    /// The keys All Settings lists, in schema order. Caller owns the slice.
    pub fn allSettings(self: Reader, alloc: Allocator, filter: Filter, query: []const u8) Allocator.Error![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(alloc);
        const q = std.mem.trim(u8, query, " \t");
        for (self.catalog.entries) |*e| {
            if (filter == .changed and !self.isModified(e.key)) continue;
            if (q.len > 0 and !try self.matches(alloc, e.key, q)) continue;
            try out.append(alloc, e.key);
        }
        return out.toOwnedSlice(alloc);
    }
};

fn allEmpty(vals: []const []const u8) bool {
    for (vals) |v| if (v.len > 0) return false;
    return true;
}

// Tests: a port of Mac `SettingsModelTests`' read-side cases (include
// overrides, load order, values straight from the file) plus the All
// Settings filter.

const testing = std.testing;

const Dir = struct {
    tmp: testing.TmpDir,
    root: []u8,

    fn init() !Dir {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try tmp.dir.realpathAlloc(testing.allocator, ".") };
    }

    fn deinit(d: *Dir) void {
        testing.allocator.free(d.root);
        d.tmp.cleanup();
    }

    fn write(d: *Dir, name: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(name)) |sub| try d.tmp.dir.makePath(sub);
        try d.tmp.dir.writeFile(.{ .sub_path = name, .data = data });
    }

    fn path(d: *Dir, name: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ d.root, name });
    }
};

fn names(s: *const SettingsSources) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s.sources.items, 0..) |src, i| {
        if (i > 0) try out.append(testing.allocator, ',');
        try out.appendSlice(testing.allocator, src.name());
        if (src.included) try out.append(testing.allocator, '+');
    }
    return out.toOwnedSlice(testing.allocator);
}

test "SettingsSources: default files, then the user's file, then includes in Ghostty's order" {
    var d = try Dir.init();
    defer d.deinit();
    try d.write("xdg/config", "font-size = 10\n");
    try d.write("xdg/config.ghostty", "config-file = a.ghostty\n");
    try d.write("xdg/a.ghostty", "config-file = nested/b.ghostty\n");
    try d.write("xdg/nested/b.ghostty", "font-size = 12\n");
    try d.write("mine/config-debug.ghostty", "config-file = ?\"c.ghostty\"\nconfig-file = ?missing.ghostty\n");
    try d.write("mine/c.ghostty", "theme = x\n");

    const legacy = try d.path("xdg/config");
    defer testing.allocator.free(legacy);
    const xdg = try d.path("xdg/config.ghostty");
    defer testing.allocator.free(xdg);
    const mine = try d.path("mine/config-debug.ghostty");
    defer testing.allocator.free(mine);

    var s = try load(testing.allocator, mine, &.{ legacy, xdg, mine });
    defer s.deinit();
    const got = try names(&s);
    defer testing.allocator.free(got);
    // Includes run after EVERY default file, breadth-first; a missing
    // optional include is skipped.
    try testing.expectEqualStrings("config,config.ghostty,config-debug.ghostty,a.ghostty+,c.ghostty+,b.ghostty+", got);
    try testing.expectEqual(@as(?usize, 2), s.main_index);
}

test "SettingsSources: a missing user file still anchors its includes" {
    var d = try Dir.init();
    defer d.deinit();
    try d.write("other.ghostty", "font-size = 9\n");
    const mine = try d.path("config.ghostty");
    defer testing.allocator.free(mine);
    var s = try load(testing.allocator, mine, &.{});
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.sources.items.len);
    try testing.expectEqual(@as(?usize, 0), s.main_index);
    try testing.expectEqual(@as(usize, 0), s.main().?.text.lines.items.len);
}

test "SettingsSources: an include cycle and a file included twice are read once" {
    var d = try Dir.init();
    defer d.deinit();
    try d.write("config.ghostty", "config-file = a.ghostty\nconfig-file = A.ghostty\n");
    try d.write("a.ghostty", "config-file = config.ghostty\n");
    const mine = try d.path("config.ghostty");
    defer testing.allocator.free(mine);
    var s = try load(testing.allocator, mine, &.{});
    defer s.deinit();
    // On Windows `A.ghostty` IS `a.ghostty`; elsewhere it does not exist.
    try testing.expectEqual(@as(usize, 2), s.sources.items.len);
}

test "SettingsSources: a later include overrides, an earlier file does not" {
    var d = try Dir.init();
    defer d.deinit();
    try d.write("shared", "font-size = 10\ncursor-style = bar\n");
    try d.write("config.ghostty", "config-file = work.ghostty\nfont-size = 14\ncursor-style = block\n");
    try d.write("work.ghostty", "font-size = 16\nkeybind = ctrl+k=clear_screen\n");
    const shared = try d.path("shared");
    defer testing.allocator.free(shared);
    const mine = try d.path("config.ghostty");
    defer testing.allocator.free(mine);

    var s = try load(testing.allocator, mine, &.{shared});
    defer s.deinit();

    const over = s.overriding("font-size").?;
    try testing.expectEqualStrings("work.ghostty", over.name());
    // The shared file loads BEFORE the user's, so it never overrides.
    try testing.expect(s.overriding("cursor-style") == null);
    try testing.expect(s.overriding("theme") == null);

    const msg = try overrideMessage(testing.allocator, over, null);
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("Set in work.ghostty, which loads after your config \u{2014} change it there.", msg);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keyed = try s.overridingKeyed(arena.allocator(), "keybind", "ctrl+k", .{});
    try testing.expectEqualStrings("work.ghostty", keyed.?.name());
    try testing.expect(try s.overridingKeyed(arena.allocator(), "keybind", "ctrl+j", .{}) == null);

    const kmsg = try overrideMessage(testing.allocator, keyed.?, "ctrl+k");
    defer testing.allocator.free(kmsg);
    try testing.expectEqualStrings("ctrl+k is set in work.ghostty, which loads after your config \u{2014} change it there.", kmsg);
}

test "SettingsSources: non-UTF-8 includes are skipped" {
    var d = try Dir.init();
    defer d.deinit();
    try d.write("config.ghostty", "config-file = bad.ghostty\n");
    try d.write("bad.ghostty", "font-size = \xff\xfe\n");
    const mine = try d.path("config.ghostty");
    defer testing.allocator.free(mine);
    var s = try load(testing.allocator, mine, &.{});
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.sources.items.len);
}

test "SettingsSources: includePath" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try includePath(a, "/x/config", "") == null);
    try testing.expect(try includePath(a, "/x/config", "?") == null);
    const rel = (try includePath(a, "/x/y/config", "?\"a b.ghostty\"")).?;
    try testing.expectEqualStrings("a b.ghostty", std.fs.path.basename(rel));
    try testing.expect(std.mem.indexOf(u8, rel, "y") != null);
}

test "SettingsSources: the Reader reads the file first, then the live config" {
    var d = try Dir.init();
    defer d.deinit();
    try d.write("config.ghostty", "font-size = 15\nmaximize\nfont-family = A\nfont-family = B\nconfig-file = work.ghostty\n");
    try d.write("work.ghostty", "cursor-style = bar\n");
    const mine = try d.path("config.ghostty");
    defer testing.allocator.free(mine);
    var s = try load(testing.allocator, mine, &.{});
    defer s.deinit();

    var cat = try SettingsCatalog.defaults(testing.allocator);
    defer cat.deinit();
    // The live config, as if only `cursor-style = bar` had been loaded so
    // far (the reload round-trip for the user's own edits is pending).
    var cfg = try @import("../../config.zig").Config.default(testing.allocator);
    defer cfg.deinit();
    cfg.@"cursor-style" = .bar;
    var eff = try SettingsCatalog.describe(testing.allocator, &cfg, false);
    defer eff.deinit();

    const r: Reader = .{ .catalog = &cat, .effective = &eff, .sources = &s, .file = &s.main().?.text };

    // Straight from the file, before any reload.
    try testing.expectEqualStrings("15", r.value("font-size"));
    try testing.expectEqualStrings("true", r.value("maximize"));
    // Not in the file: the live value.
    try testing.expectEqualStrings("bar", r.value("cursor-style"));
    // Neither: the live value, which is the default.
    try testing.expectEqualStrings(cat.get("window-padding-x").?.value(), r.value("window-padding-x"));
    // Not a key at all.
    try testing.expectEqualStrings("", r.value("no-such-key"));

    const fams = try r.values(testing.allocator, "font-family");
    defer testing.allocator.free(fams);
    try testing.expectEqual(@as(usize, 2), fams.len);
    try testing.expectEqualStrings("B", fams[1]);

    try testing.expect(r.isSetInFile("font-size"));
    try testing.expect(!r.isSetInFile("cursor-style"));
    try testing.expect(r.isModified("font-size"));
    // Set only in another file: modified, not set here.
    try testing.expect(r.isModified("cursor-style"));
    try testing.expect(!r.isModified("theme"));
}

test "SettingsSources: All Settings filters by changed and by search" {
    var d = try Dir.init();
    defer d.deinit();
    try d.write("config.ghostty", "font-size = 15\n");
    const mine = try d.path("config.ghostty");
    defer testing.allocator.free(mine);
    var s = try load(testing.allocator, mine, &.{});
    defer s.deinit();
    var cat = try SettingsCatalog.defaults(testing.allocator);
    defer cat.deinit();
    var eff = try SettingsCatalog.defaults(testing.allocator);
    defer eff.deinit();
    const r: Reader = .{ .catalog = &cat, .effective = &eff, .sources = &s, .file = &s.main().?.text };

    const all = try r.allSettings(testing.allocator, .all, "");
    defer testing.allocator.free(all);
    try testing.expectEqual(cat.entries.len, all.len);

    const changed = try r.allSettings(testing.allocator, .changed, "");
    defer testing.allocator.free(changed);
    try testing.expectEqual(@as(usize, 1), changed.len);
    try testing.expectEqualStrings("font-size", changed[0]);

    // Matches the key...
    const by_key = try r.allSettings(testing.allocator, .all, "  CURSOR-STYLE ");
    defer testing.allocator.free(by_key);
    try testing.expect(by_key.len >= 1);
    for (by_key) |k| try testing.expect(
        SettingsCatalog.containsIgnoreCase(k, "cursor-style") or
            SettingsCatalog.containsIgnoreCase(cat.get(k).?.doc orelse "", "cursor-style") or
            try r.matches(testing.allocator, k, "cursor-style"),
    );
    // ...and a current value only the file holds.
    try testing.expect(try r.matches(testing.allocator, "font-size", "15"));
    const none = try r.allSettings(testing.allocator, .all, "zz-no-such-text-zz");
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}
