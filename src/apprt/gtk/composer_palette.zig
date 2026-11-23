//! The GTK feedback composer's colours (T3552, Linux L9j-5; win32
//! `ViewerFeedbackBar.applyTheme`, Mac `ViewerFeedbackToolbar`).
//!
//! The composer's page (`src/viewer/composer.js`) paints the pill's interior
//! from CSS custom properties the host pushes down. T3544 pushed fixed
//! Adwaita LIGHT values, so on a dark style the pill was a white slab in a
//! dark pane. This file derives every one of those colours from the two
//! things libadwaita actually tells the app - whether the style is dark, and
//! what its accent is - through win32's own `chrome_theme` derivations, so the
//! text, placeholder, quote wash and image chip clear the same contrast
//! floors on Linux that they do on Windows.
//!
//! No GTK imports: the whole file asserts in the none lane. The GTK half
//! (`ViewerFeedback.pushVars`) reads the style manager and the theme's named
//! colours and hands them here.
const std = @import("std");
const color_math = @import("../win32/color_math.zig");
const chrome_theme = @import("../win32/chrome_theme.zig");

pub const Rgb = color_math.Rgb;

/// libadwaita's `@card_bg_color` on the window, when the theme cannot be
/// asked: white in light; in dark, `rgba(255,255,255,0.08)` over
/// `@window_bg_color` #242424.
pub const card_light: Rgb = .{ .r = 0xff, .g = 0xff, .b = 0xff };
pub const card_dark: Rgb = .{ .r = 0x36, .g = 0x36, .b = 0x36 };
/// libadwaita's default `@accent_bg_color` (blue 3), both styles.
pub const accent_default: Rgb = .{ .r = 0x35, .g = 0x84, .b = 0xe4 };

/// How far the selection is pulled from the pill toward the accent: a wash the
/// body text (4.5:1 against the pill) still reads on.
pub const selection_mix: f64 = 0.35;

pub const Palette = struct {
    dark: bool,
    bg: Rgb,
    fg: Rgb,
    placeholder: Rgb,
    selection: Rgb,
    quote_bg: Rgb,
    quote_accent: Rgb,
    image_ink: Rgb,
    image_edge: Rgb,
};

/// The pill's fill. `theme_card` is the theme's own card colour, already
/// composited onto the window; it is used only when it agrees with `dark` -
/// the style manager announces a flip before the theme's stylesheet has
/// necessarily reloaded, and a light card read while the style says dark is a
/// stale read, not the theme.
pub fn surfaceFor(dark: bool, theme_card: ?Rgb) Rgb {
    if (theme_card) |c| {
        if (color_math.isLight(c) != dark) return c;
    }
    return if (dark) card_dark else card_light;
}

/// Every composer colour for a style. `theme_card`/`theme_accent` are what the
/// theme says (null when it could not be asked).
pub fn derive(dark: bool, theme_card: ?Rgb, theme_accent: ?Rgb) Palette {
    const bg = surfaceFor(dark, theme_card);
    const accent_in = theme_accent orelse accent_default;
    const accent = chrome_theme.accentOn(bg, accent_in);
    const token = chrome_theme.accentTokenOn(bg, accent);
    return .{
        .dark = dark,
        .bg = bg,
        .fg = chrome_theme.textOn(bg),
        .placeholder = chrome_theme.textSecondaryOn(bg),
        .selection = color_math.mix(bg, accent_in, selection_mix),
        .quote_bg = token.wash,
        .quote_accent = accent,
        .image_ink = token.ink,
        .image_edge = token.edge,
    };
}

/// `rgba(r,g,b,a)` with channels in 0..1, as GDK reports a named colour,
/// composited over an opaque `under` (a translucent card over the window).
pub fn composite(r: f32, g: f32, b: f32, a: f32, under: Rgb) Rgb {
    const al = std.math.clamp(a, 0.0, 1.0);
    const ch = struct {
        fn one(top: f32, bottom: u8, alpha: f32) u8 {
            const t = std.math.clamp(top, 0.0, 1.0) * 255.0;
            const v = t * alpha + @as(f32, @floatFromInt(bottom)) * (1.0 - alpha);
            return @intFromFloat(@round(std.math.clamp(v, 0.0, 255.0)));
        }
    };
    return .{ .r = ch.one(r, under.r, al), .g = ch.one(g, under.g, al), .b = ch.one(b, under.b, al) };
}

/// `#rrggbb`.
pub fn hex(buf: *[7]u8, c: Rgb) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch "#000000";
}

// --- tests ---

const testing = std.testing;

fn ratio(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(color_math.wcagLuminance(a), color_math.wcagLuminance(b));
}

test "light style: a white pill with dark text, like T3544's" {
    const p = derive(false, null, null);
    try testing.expect(!p.dark);
    try testing.expectEqual(card_light, p.bg);
    try testing.expect(!color_math.isLight(p.fg));
    try testing.expect(ratio(p.fg, p.bg) >= 4.5);
}

test "dark style: a dark pill with light text - never the white slab" {
    const p = derive(true, null, null);
    try testing.expect(p.dark);
    try testing.expectEqual(card_dark, p.bg);
    try testing.expect(!color_math.isLight(p.bg));
    try testing.expect(color_math.isLight(p.fg));
    try testing.expect(ratio(p.fg, p.bg) >= 4.5);
    // Every wash stays dark too: no light quote block or chip in a dark pill.
    try testing.expect(!color_math.isLight(p.quote_bg));
    try testing.expect(!color_math.isLight(p.selection));
}

test "every style clears the text and mark floors" {
    for ([_]bool{ false, true }) |dark| {
        const p = derive(dark, null, null);
        try testing.expect(ratio(p.placeholder, p.bg) >= 3.0);
        try testing.expect(ratio(p.quote_accent, p.bg) >= 3.0);
        try testing.expect(ratio(p.image_ink, p.quote_bg) >= 4.5);
        try testing.expect(ratio(p.fg, p.quote_bg) >= 4.5);
        try testing.expect(ratio(p.fg, p.selection) >= 4.5);
    }
}

test "the theme's card is used when it agrees with the style, ignored when stale" {
    const custom: Rgb = .{ .r = 0x20, .g = 0x24, .b = 0x30 };
    try testing.expectEqual(custom, surfaceFor(true, custom));
    // A light card read while the style already says dark: the stylesheet has
    // not reloaded yet, so the fallback wins.
    try testing.expectEqual(card_dark, surfaceFor(true, card_light));
    try testing.expectEqual(card_light, surfaceFor(false, card_dark));
}

test "the theme's accent drives the quote and the chip" {
    const green: Rgb = .{ .r = 0x2e, .g = 0xc2, .b = 0x7e };
    const blue = derive(true, null, null);
    const g = derive(true, null, green);
    try testing.expect(!std.meta.eql(blue.quote_accent, g.quote_accent));
    try testing.expect(g.quote_accent.g > g.quote_accent.r);
}

test "composite: libadwaita's dark card over its window is the fallback" {
    const window: Rgb = .{ .r = 0x24, .g = 0x24, .b = 0x24 };
    try testing.expectEqual(card_dark, composite(1, 1, 1, 0.08, window));
    try testing.expectEqual(card_light, composite(1, 1, 1, 1, window));
}

test "hex" {
    var b: [7]u8 = undefined;
    try testing.expectEqualStrings("#3584e4", hex(&b, accent_default));
}
