//! Appearance > Theme's tile grid (T2682, Mac `ThemeSection` in
//! SettingsCustomSections.swift): which tiles are shown for a tab, a filter
//! and the "All N themes..." disclosure, in which order, and how many columns
//! the grid's width holds. Pure - the painting is `SettingsWindow`.
//!
//! Mac's rules, kept exactly:
//! - a tab lists ONLY themes of its kind (light or dark);
//! - the filter is a case-insensitive substring of the name;
//! - the theme the tab picks for (the slot's theme in light & dark mode, the
//!   one theme otherwise) comes first when it is in the list;
//! - collapsed, at most `collapsed_max` tiles show, then an "All N <kind>
//!   themes..." tile; a non-empty filter or the disclosure shows them all.
const std = @import("std");
const Allocator = std.mem.Allocator;

const theme_catalog = @import("theme_catalog.zig");
const text_search = @import("text_search.zig");

pub const Tab = enum {
    light,
    dark,

    pub fn slot(self: Tab) theme_catalog.Slot {
        return switch (self) {
            .light => .light,
            .dark => .dark,
        };
    }
};

/// Mac's `ordered.prefix(11)`.
pub const collapsed_max = 11;

/// The theme the tab's tiles mark as picked: in light & dark mode the tab's
/// own slot, otherwise the one theme whichever tab is showing.
pub fn current(sel: ?theme_catalog.Selection, tab: Tab) ?[]const u8 {
    const s = sel orelse return null;
    if (!s.follows_system) return s.light;
    return s.slotName(tab.slot());
}

pub const Grid = struct {
    /// Indices into `cat.themes`, in tile order. Owned by the caller's
    /// allocator.
    shown: []usize,
    /// Themes of the tab's kind (the filter field's "Filter N <kind> themes").
    kind_total: usize,
    /// Of those, the ones the filter matches (Mac's `ordered.count`).
    matched: usize,
    /// The "All N <kind> themes..." tile is drawn after the shown ones.
    more: bool,

    pub fn deinit(self: Grid, alloc: Allocator) void {
        alloc.free(self.shown);
    }
};

pub fn build(
    alloc: Allocator,
    cat: *const theme_catalog.Catalog,
    tab: Tab,
    filter: []const u8,
    picked: ?[]const u8,
    show_all: bool,
) Allocator.Error!Grid {
    const want_light = tab == .light;
    var kind_total: usize = 0;
    var ordered: std.ArrayListUnmanaged(usize) = .empty;
    errdefer ordered.deinit(alloc);
    var first: ?usize = null;
    for (cat.themes, 0..) |*t, i| {
        if (t.isLight() != want_light) continue;
        kind_total += 1;
        if (filter.len > 0 and !text_search.containsIgnoreCase(t.name, filter)) continue;
        if (first == null) if (picked) |p| if (std.mem.eql(u8, t.name, p)) {
            first = i;
            continue;
        };
        try ordered.append(alloc, i);
    }
    if (first) |f| try ordered.insert(alloc, 0, f);
    const matched = ordered.items.len;
    const expand = show_all or filter.len > 0;
    if (!expand and ordered.items.len > collapsed_max) ordered.shrinkRetainingCapacity(collapsed_max);
    return .{
        .shown = try ordered.toOwnedSlice(alloc),
        .kind_total = kind_total,
        .matched = matched,
        .more = !expand and matched > collapsed_max,
    };
}

/// Mac's `GridItem(.adaptive(minimum:), spacing:)`: as many columns of at
/// least `min_w` as fit `width` with `spacing` between them (always one),
/// each column then stretched to share the width.
pub const Columns = struct { n: usize, tile_w: i32 };

pub fn columns(width: i32, min_w: i32, spacing: i32) Columns {
    if (width <= min_w or min_w <= 0) return .{ .n = 1, .tile_w = @max(0, width) };
    const n: i32 = @max(1, @divTrunc(width + spacing, min_w + spacing));
    return .{ .n = @intCast(n), .tile_w = @divTrunc(width - (n - 1) * spacing, n) };
}

/// Rows a grid of `tiles` cells takes at `n` columns.
pub fn rows(tiles: usize, n: usize) usize {
    if (n == 0) return 0;
    return (tiles + n - 1) / n;
}

const testing = std.testing;

fn fixture() !theme_catalog.Catalog {
    // Light: Alpha Light, Beta Light, ...; dark: the Night ones.
    var entries: std.ArrayListUnmanaged(theme_catalog.Entry) = .empty;
    defer entries.deinit(testing.allocator);
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| testing.allocator.free(n);
        names.deinit(testing.allocator);
    }
    const light = "background = #fafafa\nforeground = #222222\n";
    const dark = "background = #101010\nforeground = #eeeeee\n";
    for (0..14) |i| {
        const n = try std.fmt.allocPrint(testing.allocator, "Light {c}", .{@as(u8, 'A') + @as(u8, @intCast(i))});
        try names.append(testing.allocator, n);
        try entries.append(testing.allocator, .{ .name = n, .text = light, .is_user = false });
    }
    for ([_][]const u8{ "Night Owl", "Catppuccin Mocha", "Dracula" }) |n| {
        try entries.append(testing.allocator, .{ .name = n, .text = dark, .is_user = false });
    }
    return theme_catalog.build(testing.allocator, entries.items);
}

fn shownNames(cat: *const theme_catalog.Catalog, g: Grid, buf: [][]const u8) [][]const u8 {
    for (g.shown, 0..) |idx, i| buf[i] = cat.themes[idx].name;
    return buf[0..g.shown.len];
}

test "settings_theme_grid: a tab lists only its kind, collapsed to 11 then More" {
    var cat = try fixture();
    defer cat.deinit();
    const g = try build(testing.allocator, &cat, .light, "", null, false);
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 14), g.kind_total);
    try testing.expectEqual(@as(usize, 14), g.matched);
    try testing.expectEqual(@as(usize, collapsed_max), g.shown.len);
    try testing.expect(g.more);
    for (g.shown) |i| try testing.expect(cat.themes[i].isLight());

    const d = try build(testing.allocator, &cat, .dark, "", null, false);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), d.shown.len);
    try testing.expect(!d.more);
    for (d.shown) |i| try testing.expect(!cat.themes[i].isLight());
}

test "settings_theme_grid: show-all and a filter expand; the filter folds case" {
    var cat = try fixture();
    defer cat.deinit();
    const all = try build(testing.allocator, &cat, .light, "", null, true);
    defer all.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 14), all.shown.len);
    try testing.expect(!all.more);

    const f = try build(testing.allocator, &cat, .dark, "MOCHA", null, false);
    defer f.deinit(testing.allocator);
    var buf: [16][]const u8 = undefined;
    const got = shownNames(&cat, f, &buf);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("Catppuccin Mocha", got[0]);
    try testing.expectEqual(@as(usize, 3), f.kind_total);
    try testing.expectEqual(@as(usize, 1), f.matched);

    const none = try build(testing.allocator, &cat, .dark, "zzz", null, false);
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), none.shown.len);
    try testing.expect(!none.more);
}

test "settings_theme_grid: the picked theme comes first, even past the collapse" {
    var cat = try fixture();
    defer cat.deinit();
    const g = try build(testing.allocator, &cat, .light, "", "Light N", false);
    defer g.deinit(testing.allocator);
    try testing.expectEqualStrings("Light N", cat.themes[g.shown[0]].name);
    try testing.expectEqualStrings("Light A", cat.themes[g.shown[1]].name);
    try testing.expectEqual(@as(usize, collapsed_max), g.shown.len);
    // A pick of the other kind is not in this tab: plain order.
    const d = try build(testing.allocator, &cat, .light, "", "Dracula", false);
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("Light A", cat.themes[d.shown[0]].name);
}

test "settings_theme_grid: current follows the tab only in light & dark mode" {
    const pair = theme_catalog.Selection.pair("Light A", "Dracula");
    try testing.expectEqualStrings("Light A", current(pair, .light).?);
    try testing.expectEqualStrings("Dracula", current(pair, .dark).?);
    const one = theme_catalog.Selection.single("Dracula");
    try testing.expectEqualStrings("Dracula", current(one, .light).?);
    try testing.expectEqualStrings("Dracula", current(one, .dark).?);
    try testing.expect(current(null, .dark) == null);
}

test "settings_theme_grid: adaptive columns share the width" {
    // 600 wide, 120 minimum, 8 between: 4 columns of 144.
    const c = columns(600, 120, 8);
    try testing.expectEqual(@as(usize, 4), c.n);
    try testing.expectEqual(@as(i32, 144), c.tile_w);
    try testing.expect(c.tile_w >= 120);
    // Exactly fits 5: 5*120 + 4*8 = 632.
    try testing.expectEqual(@as(usize, 5), columns(632, 120, 8).n);
    try testing.expectEqual(@as(usize, 4), columns(631, 120, 8).n);
    // Narrower than one tile: one column, the whole width.
    try testing.expectEqual(@as(usize, 1), columns(90, 120, 8).n);
    try testing.expectEqual(@as(i32, 90), columns(90, 120, 8).tile_w);
    try testing.expectEqual(@as(usize, 3), rows(12, 4));
    try testing.expectEqual(@as(usize, 4), rows(13, 4));
    try testing.expectEqual(@as(usize, 0), rows(5, 0));
}
