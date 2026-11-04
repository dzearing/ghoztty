//! The themes the `theme` key can name (T2586) - the win32 port of Mac
//! `ThemeCatalog.swift` (9287de0ff).
//!
//! Two folders, read once: the bundled themes (`<resources>\themes`) and the
//! user's own (`%XDG_CONFIG_HOME%\ghostty\themes`, else the profile's
//! `.config`). A user theme wins a name clash, as in Ghostty's own theme
//! lookup (`config/theme.zig` searches the user folder first). Each file is
//! read for the colors the Settings window shows: background, foreground,
//! cursor, ANSI 0-15.
//!
//! Light or dark comes from the BACKGROUND's luminance (Mac
//! `OSColor.isLightColor`: 0.299 R + 0.587 G + 0.114 B over 0.5), so the
//! light and dark lists can never mix and a light theme cannot land in the
//! dark slot.
//!
//! `Selection` is a `theme` value: one name, or Ghostty's conditional
//! `light:A,dark:B` form, with Mac's mode switch (seeding the other slot
//! from the same family - "Catppuccin Latte" <-> "Catppuccin Mocha") and
//! the hand-edited mismatch Mac warns about.
//!
//! Pure logic: no win32, so it is unit-tested in the `none` lane.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rgb = packed struct(u24) {
    b: u8,
    g: u8,
    r: u8,

    /// `#RRGGBB` / `RRGGBB` (Mac `NSColor(hex:)`); anything else is null.
    pub fn parse(text: []const u8) ?Rgb {
        var s = std.mem.trim(u8, text, " \t\r\"");
        if (s.len > 0 and s[0] == '#') s = s[1..];
        if (s.len != 6) return null;
        const v = std.fmt.parseInt(u24, s, 16) catch return null;
        return @bitCast(v);
    }

    /// 0xRRGGBB, the shape the win32 painters take.
    pub fn hex(self: Rgb) u32 {
        return @as(u24, @bitCast(self));
    }

    /// Mac `OSColor.luminance` (Rec. 601 weights, sRGB components 0-1).
    pub fn luminance(self: Rgb) f64 {
        const r: f64 = @floatFromInt(self.r);
        const g: f64 = @floatFromInt(self.g);
        const b: f64 = @floatFromInt(self.b);
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;
    }

    pub fn isLight(self: Rgb) bool {
        return self.luminance() > 0.5;
    }
};

pub const Theme = struct {
    name: []const u8,
    background: Rgb,
    foreground: Rgb,
    cursor: ?Rgb,
    /// ANSI 0-15; a missing entry falls back to the foreground.
    palette: [16]Rgb,
    is_user: bool,

    pub fn isLight(self: *const Theme) bool {
        return self.background.isLight();
    }
};

/// One `key = value` line of a theme file (the config syntax: `#` comments,
/// blank lines, optional quotes are the caller's to strip).
fn splitLine(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    return .{
        .key = std.mem.trim(u8, t[0..eq], " \t"),
        .value = std.mem.trim(u8, t[eq + 1 ..], " \t"),
    };
}

/// A theme file's colors, or null when it names no background or no
/// foreground (Mac skips such a file). `name` is borrowed.
pub fn parse(name: []const u8, text: []const u8, is_user: bool) ?Theme {
    var bg: ?Rgb = null;
    var fg: ?Rgb = null;
    var cursor: ?Rgb = null;
    var pal: [16]?Rgb = @splat(null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const kv = splitLine(line) orelse continue;
        if (std.mem.eql(u8, kv.key, "background")) {
            bg = Rgb.parse(kv.value) orelse bg;
        } else if (std.mem.eql(u8, kv.key, "foreground")) {
            fg = Rgb.parse(kv.value) orelse fg;
        } else if (std.mem.eql(u8, kv.key, "cursor-color")) {
            cursor = Rgb.parse(kv.value) orelse cursor;
        } else if (std.mem.eql(u8, kv.key, "palette")) {
            const eq = std.mem.indexOfScalar(u8, kv.value, '=') orelse continue;
            const idx = std.fmt.parseInt(usize, std.mem.trim(u8, kv.value[0..eq], " \t"), 10) catch continue;
            if (idx >= 16) continue;
            pal[idx] = Rgb.parse(kv.value[eq + 1 ..]) orelse pal[idx];
        }
    }
    const background = bg orelse return null;
    const foreground = fg orelse return null;
    var palette: [16]Rgb = undefined;
    for (&palette, pal) |*out, p| out.* = p orelse foreground;
    return .{
        .name = name,
        .background = background,
        .foreground = foreground,
        .cursor = cursor,
        .palette = palette,
        .is_user = is_user,
    };
}

/// A folder to read, in priority order LOW to HIGH: a later folder's theme
/// replaces an earlier one of the same name.
pub const Source = struct { dir: []const u8, is_user: bool };

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    /// Sorted by name, case-insensitively (Mac `localizedCaseInsensitiveCompare`).
    themes: []const Theme = &.{},

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
    }

    pub fn named(self: *const Catalog, name: []const u8) ?*const Theme {
        for (self.themes) |*t| if (std.mem.eql(u8, t.name, name)) return t;
        return null;
    }

    /// How many themes are of the given kind.
    pub fn count(self: *const Catalog, light: bool) usize {
        var n: usize = 0;
        for (self.themes) |*t| {
            if (t.isLight() == light) n += 1;
        }
        return n;
    }

    /// The first theme of the given kind whose name starts with
    /// `family ` (Mac's counterpart rule), else the first of that kind.
    pub fn counterpart(self: *const Catalog, light: bool, family: []const u8) ?*const Theme {
        if (family.len > 0) for (self.themes) |*t| {
            if (t.isLight() != light) continue;
            if (t.name.len > family.len and std.mem.startsWith(u8, t.name, family) and t.name[family.len] == ' ') return t;
        };
        for (self.themes) |*t| if (t.isLight() == light) return t;
        return null;
    }
};

/// Build a catalog from (name, text) pairs already read, in `Source` order
/// (later wins a clash). The pure half of `load`, which the tests drive.
pub const Entry = struct { name: []const u8, text: []const u8, is_user: bool };

pub fn build(gpa: Allocator, entries: []const Entry) Allocator.Error!Catalog {
    var cat: Catalog = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer cat.deinit();
    const a = cat.arena.allocator();
    var by_name: std.StringArrayHashMapUnmanaged(Theme) = .empty;
    for (entries) |e| {
        if (e.name.len == 0 or e.name[0] == '.') continue;
        const name = try a.dupe(u8, e.name);
        const theme = parse(name, e.text, e.is_user) orelse continue;
        try by_name.put(a, name, theme);
    }
    const list = try a.dupe(Theme, by_name.values());
    std.mem.sort(Theme, list, {}, struct {
        fn lt(_: void, x: Theme, y: Theme) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.lt);
    cat.themes = list;
    return cat;
}

/// Read every theme in `sources` (low to high priority). A folder that does
/// not exist, or a file that cannot be read, is skipped - Mac's `try?`.
pub fn load(gpa: Allocator, sources: []const Source) Allocator.Error!Catalog {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const s = scratch.allocator();
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    for (sources) |src| {
        var dir = std.fs.cwd().openDir(src.dir, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |ent| {
            if (ent.kind != .file and ent.kind != .sym_link) continue;
            if (ent.name.len == 0 or ent.name[0] == '.') continue;
            const text = dir.readFileAlloc(s, ent.name, 1 << 20) catch continue;
            try entries.append(s, .{ .name = try s.dupe(u8, ent.name), .text = text, .is_user = src.is_user });
        }
    }
    return build(gpa, entries.items);
}

pub const Slot = enum { light, dark };

/// A `theme` value: one theme, or `light:A,dark:B`.
pub const Selection = struct {
    light: []const u8,
    dark: []const u8,
    follows_system: bool,

    pub fn single(name: []const u8) Selection {
        return .{ .light = name, .dark = name, .follows_system = false };
    }

    pub fn pair(light: []const u8, dark: []const u8) Selection {
        return .{ .light = light, .dark = dark, .follows_system = true };
    }

    /// Parse a `theme` value ("" is no theme). Mirrors `Theme.parseCLI` and
    /// Mac `ThemeSelection(configValue:)`: a value with ':' but without both
    /// halves (a path such as `C:\themes\x`) is one theme. Borrows `value`.
    pub fn parse(value_in: []const u8) ?Selection {
        const value = std.mem.trim(u8, value_in, " \t");
        if (value.len == 0) return null;
        if (std.mem.indexOfScalar(u8, value, ':') == null) return single(value);
        var light: ?[]const u8 = null;
        var dark: ?[]const u8 = null;
        var parts = std.mem.splitScalar(u8, value, ',');
        while (parts.next()) |part| {
            const colon = std.mem.indexOfScalar(u8, part, ':') orelse continue;
            const k = std.mem.trim(u8, part[0..colon], " \t");
            const v = std.mem.trim(u8, part[colon + 1 ..], " \t");
            if (std.mem.eql(u8, k, "light")) light = v;
            if (std.mem.eql(u8, k, "dark")) dark = v;
        }
        if (light != null and dark != null) return pair(light.?, dark.?);
        return single(value);
    }

    /// The `theme` value to write. Caller owns it.
    pub fn format(self: Selection, alloc: Allocator) Allocator.Error![]u8 {
        if (self.follows_system) return std.fmt.allocPrint(alloc, "light:{s},dark:{s}", .{ self.light, self.dark });
        return alloc.dupe(u8, self.light);
    }

    /// The name in effect for `slot` (both slots read the one theme).
    pub fn slotName(self: Selection, slot: Slot) []const u8 {
        return switch (slot) {
            .light => self.light,
            .dark => self.dark,
        };
    }
};

/// The slot holding a theme of the wrong kind, if any (Mac
/// `mismatchedSlot`): a hand-edited `light:<a dark theme>`.
pub fn mismatch(cat: *const Catalog, sel: Selection) ?Slot {
    if (!sel.follows_system) return null;
    if (cat.named(sel.light)) |t| if (!t.isLight()) return .light;
    if (cat.named(sel.dark)) |t| if (t.isLight()) return .dark;
    return null;
}

/// Picking `name` (Mac `pick`): in light & dark mode it fills `slot`,
/// otherwise it becomes the one theme. Caller owns the value.
pub fn pick(alloc: Allocator, current: ?Selection, name: []const u8, slot: Slot) Allocator.Error![]u8 {
    var sel = current orelse return Selection.single(name).format(alloc);
    if (!sel.follows_system) return Selection.single(name).format(alloc);
    switch (slot) {
        .light => sel.light = name,
        .dark => sel.dark = name,
    }
    return sel.format(alloc);
}

/// The `theme` value after the "Use" switch (Mac `switchMode`), or null
/// meaning "remove the key" (one theme, and there was none) or "nothing to
/// do" (no theme of a kind exists to seed with) - `.unchanged` tells them
/// apart. `system_dark` is the current system appearance.
pub const ModeResult = union(enum) { set: []u8, reset, unchanged };

pub fn switchMode(alloc: Allocator, cat: *const Catalog, current: ?Selection, to_follow: bool, system_dark: bool) Allocator.Error!ModeResult {
    if (!to_follow) {
        const sel = current orelse return .reset;
        const keep = if (system_dark) sel.dark else sel.light;
        return .{ .set = try Selection.single(keep).format(alloc) };
    }
    if (current) |c| if (c.follows_system) return .unchanged;
    const current_name = if (current) |c| c.light else if (system_dark) "Ghostty Default Style Dark" else "";
    const theme = cat.named(current_name);
    const family = blk: {
        const sp = std.mem.indexOfScalar(u8, current_name, ' ') orelse break :blk current_name;
        break :blk current_name[0..sp];
    };
    const light: ?[]const u8 = if (theme != null and theme.?.isLight()) current_name else if (cat.counterpart(true, family)) |t| t.name else null;
    const dark: ?[]const u8 = if (theme != null and !theme.?.isLight()) current_name else if (cat.counterpart(false, family)) |t| t.name else null;
    if (light == null or dark == null) return .unchanged;
    return .{ .set = try Selection.pair(light.?, dark.?).format(alloc) };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

const latte =
    \\palette = 1=#d20f39
    \\palette = 2=#40a02b
    \\background = #eff1f5
    \\foreground = #4c4f69
    \\cursor-color = #dc8a78
;
const mocha =
    \\background = #1e1e2e
    \\foreground = #cdd6f4
;
const night =
    \\# a comment
    \\background = 101010
    \\foreground = #eeeeee
;
const day =
    \\background = #fafafa
    \\foreground = #222222
;

fn testCatalog() !Catalog {
    return build(testing.allocator, &.{
        .{ .name = "Catppuccin Latte", .text = latte, .is_user = false },
        .{ .name = "Catppuccin Mocha", .text = mocha, .is_user = false },
        .{ .name = "3024 Night", .text = night, .is_user = false },
        .{ .name = "3024 Day", .text = day, .is_user = false },
        .{ .name = "broken", .text = "background = #000000\n", .is_user = false },
        .{ .name = ".hidden", .text = mocha, .is_user = false },
        // The user's own "3024 Day" is dark: it replaces the bundled one.
        .{ .name = "3024 Day", .text = mocha, .is_user = true },
    });
}

test "theme_catalog: parse reads colors, palette falls back to the foreground" {
    const t = parse("Catppuccin Latte", latte, false).?;
    try testing.expectEqual(@as(u32, 0xeff1f5), t.background.hex());
    try testing.expectEqual(@as(u32, 0x4c4f69), t.foreground.hex());
    try testing.expectEqual(@as(u32, 0xdc8a78), t.cursor.?.hex());
    try testing.expectEqual(@as(u32, 0xd20f39), t.palette[1].hex());
    try testing.expectEqual(@as(u32, 0x4c4f69), t.palette[0].hex());
    try testing.expectEqual(@as(u32, 0x4c4f69), t.palette[15].hex());
    try testing.expect(t.isLight());
    try testing.expect(!parse("m", mocha, false).?.isLight());
    try testing.expect(parse("x", "foreground = #ffffff", false) == null);
    try testing.expect(parse("x", "background = nope\nforeground = #fff", false) == null);
}

test "theme_catalog: luminance split matches Mac's 0.5 threshold" {
    // 0.299*0x80 + 0.587*0x80 + 0.114*0x80 = 128/255 = 0.502 -> light.
    try testing.expect(Rgb.parse("#808080").?.isLight());
    try testing.expect(!Rgb.parse("#7f7f7f").?.isLight());
    // Green weighs most: pure green is light, pure blue is dark.
    try testing.expect(Rgb.parse("00ff00").?.isLight());
    try testing.expect(!Rgb.parse("0000ff").?.isLight());
    try testing.expect(Rgb.parse("#12345") == null);
}

test "theme_catalog: user theme wins a clash; sorted; unreadable and hidden skipped" {
    var cat = try testCatalog();
    defer cat.deinit();
    try testing.expectEqual(@as(usize, 4), cat.themes.len);
    try testing.expectEqualStrings("3024 Day", cat.themes[0].name);
    try testing.expectEqualStrings("3024 Night", cat.themes[1].name);
    try testing.expectEqualStrings("Catppuccin Latte", cat.themes[2].name);
    const d = cat.named("3024 Day").?;
    try testing.expect(d.is_user);
    try testing.expect(!d.isLight());
    try testing.expect(cat.named("broken") == null);
    try testing.expect(cat.named(".hidden") == null);
    try testing.expectEqual(@as(usize, 1), cat.count(true));
    try testing.expectEqual(@as(usize, 3), cat.count(false));
}

test "theme_catalog: selection parse and format round-trip" {
    const one = Selection.parse(" Catppuccin Mocha ").?;
    try testing.expect(!one.follows_system);
    try testing.expectEqualStrings("Catppuccin Mocha", one.slotName(.dark));
    const two = Selection.parse("light:Catppuccin Latte, dark:Catppuccin Mocha").?;
    try testing.expect(two.follows_system);
    try testing.expectEqualStrings("Catppuccin Latte", two.light);
    try testing.expectEqualStrings("Catppuccin Mocha", two.dark);
    const v = try two.format(testing.allocator);
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("light:Catppuccin Latte,dark:Catppuccin Mocha", v);
    // A Windows path holds a ':' but is one theme.
    const path = Selection.parse("C:\\themes\\mine").?;
    try testing.expect(!path.follows_system);
    try testing.expectEqualStrings("C:\\themes\\mine", path.light);
    try testing.expect(Selection.parse("  ") == null);
}

test "theme_catalog: mismatch names the slot holding the wrong kind" {
    var cat = try testCatalog();
    defer cat.deinit();
    try testing.expectEqual(@as(?Slot, null), mismatch(&cat, Selection.pair("Catppuccin Latte", "Catppuccin Mocha")));
    try testing.expectEqual(@as(?Slot, .light), mismatch(&cat, Selection.pair("Catppuccin Mocha", "Catppuccin Mocha")));
    try testing.expectEqual(@as(?Slot, .dark), mismatch(&cat, Selection.pair("Catppuccin Latte", "Catppuccin Latte")));
    // One theme never mismatches; an unknown name is not judged.
    try testing.expectEqual(@as(?Slot, null), mismatch(&cat, Selection.single("Catppuccin Latte")));
    try testing.expectEqual(@as(?Slot, null), mismatch(&cat, Selection.pair("nope", "nope")));
}

test "theme_catalog: pick fills the slot in light & dark mode, else replaces" {
    const a = testing.allocator;
    const v1 = try pick(a, Selection.pair("Catppuccin Latte", "Catppuccin Mocha"), "3024 Night", .dark);
    defer a.free(v1);
    try testing.expectEqualStrings("light:Catppuccin Latte,dark:3024 Night", v1);
    const v2 = try pick(a, Selection.single("Catppuccin Latte"), "3024 Night", .dark);
    defer a.free(v2);
    try testing.expectEqualStrings("3024 Night", v2);
    const v3 = try pick(a, null, "3024 Night", .light);
    defer a.free(v3);
    try testing.expectEqualStrings("3024 Night", v3);
}

test "theme_catalog: switching to light & dark seeds the other slot from the family" {
    const a = testing.allocator;
    var cat = try testCatalog();
    defer cat.deinit();
    // Latte (light) keeps its slot; dark gets Mocha, its family's dark.
    const r1 = try switchMode(a, &cat, Selection.single("Catppuccin Latte"), true, false);
    defer a.free(r1.set);
    try testing.expectEqualStrings("light:Catppuccin Latte,dark:Catppuccin Mocha", r1.set);
    // Mocha (dark) keeps its slot; light gets Latte.
    const r2 = try switchMode(a, &cat, Selection.single("Catppuccin Mocha"), true, true);
    defer a.free(r2.set);
    try testing.expectEqualStrings("light:Catppuccin Latte,dark:Catppuccin Mocha", r2.set);
    // No family match: the first theme of the kind.
    const r3 = try switchMode(a, &cat, Selection.single("3024 Night"), true, true);
    defer a.free(r3.set);
    try testing.expectEqualStrings("light:Catppuccin Latte,dark:3024 Night", r3.set);
    // Already light & dark: nothing to do.
    try testing.expect(try switchMode(a, &cat, Selection.pair("Catppuccin Latte", "Catppuccin Mocha"), true, false) == .unchanged);
    // Back to one theme keeps the slot the system is showing.
    const r4 = try switchMode(a, &cat, Selection.pair("Catppuccin Latte", "Catppuccin Mocha"), false, true);
    defer a.free(r4.set);
    try testing.expectEqualStrings("Catppuccin Mocha", r4.set);
    // One theme with no theme set removes the key.
    try testing.expect(try switchMode(a, &cat, null, false, false) == .reset);
}

test "theme_catalog: load reads folders, the later (user) folder wins" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("bundled");
    try tmp.dir.makePath("user");
    try tmp.dir.writeFile(.{ .sub_path = "bundled/Catppuccin Latte", .data = latte });
    try tmp.dir.writeFile(.{ .sub_path = "bundled/Solo", .data = day });
    try tmp.dir.writeFile(.{ .sub_path = "user/Catppuccin Latte", .data = mocha });
    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const b = try std.fs.path.join(testing.allocator, &.{ base, "bundled" });
    defer testing.allocator.free(b);
    const u = try std.fs.path.join(testing.allocator, &.{ base, "user" });
    defer testing.allocator.free(u);
    var cat = try load(testing.allocator, &.{
        .{ .dir = b, .is_user = false },
        .{ .dir = u, .is_user = true },
        .{ .dir = "Z:\\definitely\\not\\here", .is_user = true },
    });
    defer cat.deinit();
    try testing.expectEqual(@as(usize, 2), cat.themes.len);
    const l = cat.named("Catppuccin Latte").?;
    try testing.expect(l.is_user);
    try testing.expect(!l.isLight());
    try testing.expect(cat.named("Solo").?.isLight());
}
