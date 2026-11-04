//! Appearance's live preview (T2683) - the win32 port of Mac
//! `SettingsPreview` (SettingsCustomSections.swift, 9287de0ff): a small
//! terminal drawn with the effective theme, font, size, background opacity,
//! padding, pane style and cursor, so each change shows at once (a slider
//! being dragged previews here before it is written).
//!
//! This file is the part that decides WHAT the preview shows: the settings'
//! raw values in, the resolved inputs and the caption out. Painting is
//! `settings_preview_view.zig`. Pure logic: no win32, so it is unit-tested in
//! the `none` lane.
const std = @import("std");
const theme_catalog = @import("theme_catalog.zig");

const Rgb = theme_catalog.Rgb;

/// Mac's card height (`.frame(height: 180)`), DIP.
pub const height_dip = 180;
/// Mac's backdrop inset around the raised terminal in the elevated style.
pub const elevated_inset_dip = 22;
/// The raised terminal's corner radius (elevated) and the card's own.
pub const terminal_radius_dip = 11;
pub const card_radius_dip = 10;
/// Text inset beyond the configured padding (Mac `padX + 10`, `padY + 8`).
pub const text_pad_x_dip = 10;
pub const text_pad_y_dip = 8;
/// The caption pill's distance from the bottom-right corner.
pub const caption_inset_dip = 8;
pub const caption_inset_elevated_dip = 30;
/// Mac's cursor blink half-period.
pub const blink_ms = 530;

/// The caption's family when none is configured (Mac's literal).
pub const default_family = "JetBrains Mono";
/// Mac's default colors when no theme is set.
pub const default_background: Rgb = @bitCast(@as(u24, 0x282c34));
pub const default_foreground: Rgb = @bitCast(@as(u24, 0xffffff));

pub const CursorStyle = enum {
    block,
    bar,
    underline,
    block_hollow,

    pub fn parse(text: []const u8) CursorStyle {
        return std.meta.stringToEnum(CursorStyle, std.mem.trim(u8, text, " \t")) orelse .block;
    }
};

/// The keys the preview reads, as the window's reader returns them.
/// Repeatable keys are lists.
pub const Raw = struct {
    theme: []const u8 = "",
    background: []const u8 = "",
    foreground: []const u8 = "",
    palette: []const []const u8 = &.{},
    cursor_color: []const u8 = "",
    font_family: []const []const u8 = &.{},
    font_size: []const u8 = "",
    font_feature: []const []const u8 = &.{},
    background_opacity: []const u8 = "",
    window_padding_x: []const u8 = "",
    window_padding_y: []const u8 = "",
    pane_style: []const u8 = "",
    cursor_style: []const u8 = "",
    cursor_style_blink: []const u8 = "",
    cursor_opacity: []const u8 = "",
};

/// What the preview draws with.
pub const Inputs = struct {
    theme_name: []const u8,
    /// A catalog theme (false: the configured / default colors).
    from_catalog: bool,
    background: Rgb,
    foreground: Rgb,
    cursor: Rgb,
    palette: [16]Rgb,
    /// The configured family; null draws the monospaced fallback.
    family: ?[]const u8,
    /// font-size, points.
    size: f64,
    opacity: f64,
    pad_x: f64,
    pad_y: f64,
    elevated: bool,
    ligatures: bool,
    cursor_style: CursorStyle,
    blink: bool,
    cursor_opacity: f64,

    /// ANSI color `i` (0-15).
    pub fn ansi(self: *const Inputs, i: usize) Rgb {
        return self.palette[@min(i, 15)];
    }

    /// The text size the lines are drawn at (Mac `size * 0.9`), points.
    pub fn textSize(self: *const Inputs) f64 {
        return self.size * 0.9;
    }
};

fn number(text: []const u8, fallback: f64) f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t")) catch fallback;
}

/// `window-padding-x = 4,8` pads 4 on the leading side; the preview reads
/// the first number (Mac `split(separator: ",").first`).
pub fn firstNumber(text: []const u8, fallback: f64) f64 {
    var it = std.mem.splitScalar(u8, text, ',');
    return number(it.first(), fallback);
}

/// The palette entry `i=#rrggbb` among `palette` lines, else `fallback`.
fn paletteEntry(lines: []const []const u8, i: usize, fallback: Rgb) Rgb {
    var prefix_buf: [4]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{d}=", .{i}) catch return fallback;
    for (lines) |line| {
        const l = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, l, prefix)) return Rgb.parse(l[prefix.len..]) orelse fallback;
    }
    return fallback;
}

/// The theme the window shows now (Mac `currentTheme`): the selection's
/// slot for the system appearance, from the catalog; else the configured
/// colors with Mac's defaults.
pub fn resolve(raw: Raw, cat: *const theme_catalog.Catalog, dark: bool) Inputs {
    const selection = theme_catalog.Selection.parse(raw.theme);
    const slot_name: ?[]const u8 = if (selection) |s| (if (dark) s.dark else s.light) else null;
    const cursor_override = Rgb.parse(raw.cursor_color);

    var in: Inputs = .{
        .theme_name = slot_name orelse "Default colors",
        .from_catalog = false,
        .background = Rgb.parse(raw.background) orelse default_background,
        .foreground = Rgb.parse(raw.foreground) orelse default_foreground,
        .cursor = undefined,
        .palette = undefined,
        .family = null,
        .size = number(raw.font_size, 13),
        .opacity = std.math.clamp(number(raw.background_opacity, 1), 0, 1),
        .pad_x = @max(0, firstNumber(raw.window_padding_x, 2)),
        .pad_y = @max(0, firstNumber(raw.window_padding_y, 2)),
        .elevated = std.mem.eql(u8, std.mem.trim(u8, raw.pane_style, " \t"), "elevated"),
        .ligatures = true,
        .cursor_style = CursorStyle.parse(raw.cursor_style),
        // Mac: anything but an explicit `false` blinks.
        .blink = !std.mem.eql(u8, std.mem.trim(u8, raw.cursor_style_blink, " \t"), "false"),
        .cursor_opacity = std.math.clamp(number(raw.cursor_opacity, 1), 0, 1),
    };
    if (!(in.size > 0)) in.size = 13;

    var theme_cursor: ?Rgb = null;
    if (slot_name) |name| if (cat.named(name)) |t| {
        in.from_catalog = true;
        in.theme_name = t.name;
        in.background = t.background;
        in.foreground = t.foreground;
        in.palette = t.palette;
        theme_cursor = t.cursor;
    };
    if (!in.from_catalog) {
        for (&in.palette, 0..) |*c, i| c.* = paletteEntry(raw.palette, i, in.foreground);
    }
    in.cursor = cursor_override orelse theme_cursor orelse in.foreground;

    for (raw.font_family) |f| {
        const name = std.mem.trim(u8, f, " \t\"");
        if (name.len > 0) {
            in.family = name;
            break;
        }
    }
    for (raw.font_feature) |f| {
        if (std.mem.eql(u8, std.mem.trim(u8, f, " \t"), "-calt")) in.ligatures = false;
    }
    return in;
}

/// Mac's corner caption: `<family> <size>pt · <theme>`, plus
/// `· N% opaque` below full opacity.
pub fn caption(buf: []u8, in: *const Inputs) []const u8 {
    var num: [32]u8 = undefined;
    const size = formatNumber(&num, in.size);
    const family = in.family orelse default_family;
    if (in.opacity < 1) {
        const pct: i64 = @intFromFloat(@floor(in.opacity * 100));
        return std.fmt.bufPrint(buf, "{s} {s}pt \u{00B7} {s} \u{00B7} {d}% opaque", .{ family, size, in.theme_name, pct }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{s} {s}pt \u{00B7} {s}", .{ family, size, in.theme_name }) catch buf[0..0];
}

/// Mac `NumberControlFormat.trim`: `13`, `13.5`.
fn formatNumber(buf: []u8, value: f64) []const u8 {
    if (value == @round(value) and @abs(value) < 1e15) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(value))}) catch "";
    }
    const text = std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch return "";
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    return text[0..end];
}

/// The cursor's box in points for a text size `ts` (Mac `PreviewCursor`:
/// a bar is 2 wide, an underline 2 tall, otherwise 0.6 x 1.15 of the size;
/// it sits on the bottom of a `ts * 1.15` line).
pub const CursorBox = struct { w: f64, h: f64, line_h: f64, hollow: bool };

pub fn cursorBox(style: CursorStyle, ts: f64) CursorBox {
    return .{
        .w = if (style == .bar) 2 else ts * 0.6,
        .h = if (style == .underline) 2 else ts * 1.15,
        .line_h = ts * 1.15,
        .hollow = style == .block_hollow,
    };
}

/// One colored run of a preview line.
pub const Span = struct {
    text: []const u8,
    /// ANSI index, or null for the foreground.
    ansi: ?u4 = null,
};

/// Mac's four lines. The last is the prompt the cursor follows. The prompt
/// glyph is its own span: a face without it draws it from a symbol font,
/// and the space after it keeps the terminal face's width.
pub const sample = [_][]const Span{
    &.{ .{ .text = "\u{276F}", .ansi = 2 }, .{ .text = " git status " }, .{ .text = "-sb", .ansi = 4 } },
    &.{.{ .text = "## users/dzearing/settings-ui", .ansi = 2 }},
    &.{ .{ .text = " M ", .ansi = 1 }, .{ .text = "SettingsView.swift  " }, .{ .text = "=> != ->", .ansi = 5 } },
    &.{ .{ .text = "~/git/ghoztty ", .ansi = 3 }, .{ .text = "\u{276F}", .ansi = 2 }, .{ .text = " " } },
};

/// `c` over `under` at `alpha` (0-1), the way a translucent terminal shows
/// what is behind it.
pub fn blend(c: Rgb, under: Rgb, alpha: f64) Rgb {
    const a = std.math.clamp(alpha, 0, 1);
    const mix = struct {
        fn f(x: u8, y: u8, k: f64) u8 {
            const v = @as(f64, @floatFromInt(x)) * k + @as(f64, @floatFromInt(y)) * (1 - k);
            return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
        }
    }.f;
    return .{ .r = mix(c.r, under.r, a), .g = mix(c.g, under.g, a), .b = mix(c.b, under.b, a) };
}

// ---------------------------------------------------------------------

const testing = std.testing;

fn testCatalog() !theme_catalog.Catalog {
    var cat: theme_catalog.Catalog = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    const a = cat.arena.allocator();
    var pal: [16]Rgb = undefined;
    for (&pal, 0..) |*c, i| c.* = @bitCast(@as(u24, @intCast(0x101010 * (i % 15 + 1))));
    const themes = try a.alloc(theme_catalog.Theme, 2);
    themes[0] = .{ .name = "Day", .background = @bitCast(@as(u24, 0xfafafa)), .foreground = @bitCast(@as(u24, 0x202020)), .cursor = @bitCast(@as(u24, 0xff0000)), .palette = pal, .is_user = false };
    themes[1] = .{ .name = "Night", .background = @bitCast(@as(u24, 0x101418)), .foreground = @bitCast(@as(u24, 0xd0d0d0)), .cursor = null, .palette = pal, .is_user = false };
    cat.themes = themes;
    return cat;
}

test "settings_preview: a light/dark theme follows the system appearance" {
    var cat = try testCatalog();
    defer cat.deinit();
    const raw: Raw = .{ .theme = "light:Day,dark:Night" };
    const light = resolve(raw, &cat, false);
    try testing.expectEqualStrings("Day", light.theme_name);
    try testing.expect(light.from_catalog);
    try testing.expectEqual(@as(u32, 0xfafafa), light.background.hex());
    try testing.expectEqual(@as(u32, 0xff0000), light.cursor.hex());
    const dark = resolve(raw, &cat, true);
    try testing.expectEqualStrings("Night", dark.theme_name);
    // No theme cursor: the foreground.
    try testing.expectEqual(@as(u32, 0xd0d0d0), dark.cursor.hex());
    // A single theme is the same either way.
    try testing.expectEqualStrings("Night", resolve(.{ .theme = "Night" }, &cat, false).theme_name);
}

test "settings_preview: no theme reads the configured colors and Mac's defaults" {
    var cat = try testCatalog();
    defer cat.deinit();
    const none = resolve(.{}, &cat, true);
    try testing.expectEqualStrings("Default colors", none.theme_name);
    try testing.expect(!none.from_catalog);
    try testing.expectEqual(@as(u32, 0x282c34), none.background.hex());
    try testing.expectEqual(@as(u32, 0xffffff), none.foreground.hex());
    // Unset palette entries fall back to the foreground.
    try testing.expectEqual(@as(u32, 0xffffff), none.ansi(2).hex());

    const set = resolve(.{
        .background = "#000000",
        .foreground = "ababab",
        .palette = &.{ "2=#00ff00", " 4=#0000ff", "junk" },
        .cursor_color = "#123456",
    }, &cat, false);
    try testing.expectEqual(@as(u32, 0x000000), set.background.hex());
    try testing.expectEqual(@as(u32, 0x00ff00), set.ansi(2).hex());
    try testing.expectEqual(@as(u32, 0x0000ff), set.ansi(4).hex());
    try testing.expectEqual(@as(u32, 0xababab), set.ansi(1).hex());
    try testing.expectEqual(@as(u32, 0x123456), set.cursor.hex());

    // A theme the catalog does not have keeps its name (Mac) over the
    // configured colors.
    const missing = resolve(.{ .theme = "Gone", .background = "#111111" }, &cat, false);
    try testing.expectEqualStrings("Gone", missing.theme_name);
    try testing.expect(!missing.from_catalog);
    try testing.expectEqual(@as(u32, 0x111111), missing.background.hex());
}

test "settings_preview: cursor-color overrides the theme's cursor" {
    var cat = try testCatalog();
    defer cat.deinit();
    const in = resolve(.{ .theme = "Day", .cursor_color = "#00aa00" }, &cat, false);
    try testing.expectEqual(@as(u32, 0x00aa00), in.cursor.hex());
}

test "settings_preview: font, size, opacity, padding, pane style and cursor" {
    var cat = try testCatalog();
    defer cat.deinit();
    const in = resolve(.{
        .font_family = &.{ "", "\"Cascadia Code\"", "Consolas" },
        .font_size = "14.5",
        .font_feature = &.{ "ss01", "-calt" },
        .background_opacity = "0.85",
        .window_padding_x = "4,8",
        .window_padding_y = " 6 ",
        .pane_style = "elevated",
        .cursor_style = "bar",
        .cursor_style_blink = "false",
        .cursor_opacity = "0.5",
    }, &cat, false);
    try testing.expectEqualStrings("Cascadia Code", in.family.?);
    try testing.expectEqual(@as(f64, 14.5), in.size);
    try testing.expect(!in.ligatures);
    try testing.expectEqual(@as(f64, 0.85), in.opacity);
    try testing.expectEqual(@as(f64, 4), in.pad_x);
    try testing.expectEqual(@as(f64, 6), in.pad_y);
    try testing.expect(in.elevated);
    try testing.expectEqual(CursorStyle.bar, in.cursor_style);
    try testing.expect(!in.blink);
    try testing.expectEqual(@as(f64, 0.5), in.cursor_opacity);

    const d = resolve(.{ .font_size = "nonsense", .background_opacity = "7", .pane_style = "flat", .cursor_style = "?" }, &cat, false);
    try testing.expect(d.family == null);
    try testing.expectEqual(@as(f64, 13), d.size);
    try testing.expectEqual(@as(f64, 1), d.opacity);
    try testing.expectEqual(@as(f64, 2), d.pad_x);
    try testing.expect(!d.elevated);
    try testing.expect(d.ligatures);
    try testing.expectEqual(CursorStyle.block, d.cursor_style);
    // Blink unset ("App decides") blinks, as Mac's preview does.
    try testing.expect(d.blink);
}

test "settings_preview: caption names font, size, theme and opacity" {
    var cat = try testCatalog();
    defer cat.deinit();
    var buf: [160]u8 = undefined;
    const full = resolve(.{ .theme = "Night", .font_size = "13" }, &cat, true);
    try testing.expectEqualStrings("JetBrains Mono 13pt \u{00B7} Night", caption(&buf, &full));
    const thin = resolve(.{ .font_family = &.{"Consolas"}, .font_size = "12.5", .background_opacity = "0.857" }, &cat, true);
    try testing.expectEqualStrings("Consolas 12.5pt \u{00B7} Default colors \u{00B7} 85% opaque", caption(&buf, &thin));
}

test "settings_preview: cursor box and blend" {
    const bar = cursorBox(.bar, 10);
    try testing.expectEqual(@as(f64, 2), bar.w);
    try testing.expectEqual(@as(f64, 11.5), bar.h);
    const ul = cursorBox(.underline, 10);
    try testing.expectEqual(@as(f64, 6), ul.w);
    try testing.expectEqual(@as(f64, 2), ul.h);
    try testing.expect(cursorBox(.block_hollow, 10).hollow);

    const white: Rgb = @bitCast(@as(u24, 0xffffff));
    const black: Rgb = @bitCast(@as(u24, 0x000000));
    try testing.expectEqual(@as(u32, 0xffffff), blend(white, black, 1).hex());
    try testing.expectEqual(@as(u32, 0x000000), blend(white, black, 0).hex());
    try testing.expectEqual(@as(u32, 0x808080), blend(white, black, 0.5).hex());
}
