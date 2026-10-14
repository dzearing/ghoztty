//! A viewer pane on a glass sheet (T1885; Mac 8174d96fc): the rules for what
//! goes see-through, kept apart from the window and the web view so they
//! can be tested without either.
//!
//! Mac's `ViewerView.drawsOnGlass`: our own pages - markdown, code, a diff,
//! an image - are transparent on a glass pane, so the tinted sheet behind is
//! their background, as it is a terminal's. A website or a rendered `.html`
//! file keeps its own: a page that sets no background was written for a
//! white one.
//!
//! The Windows half has one more rule than Mac's. A page on glass shows ink
//! over the SHEET, and the sheet is the terminal background tinted over the
//! desk - so the page's light/dark has to follow that background, not the
//! OS. Mac gets this for free (the window's appearance follows the terminal
//! background, and the web view follows the window); here the viewer's
//! scheme follows the OS report, which was only self-consistent while every
//! page painted its own background under its own ink.
const std = @import("std");
const color_math = @import("color_math.zig");
const content = @import("viewer_content.zig");

/// Whether a pane in `mode` draws its page over the sheet. `on_glass` is
/// whether the pane sits on a glass sheet at all (`macos-pane-glass`, and
/// the window not translucent).
pub fn drawsOnGlass(on_glass: bool, mode: content.Mode) bool {
    return on_glass and !mode.isLivePage();
}

pub const Scheme = enum { light, dark };

/// The page's `prefers-color-scheme`. On glass it is the terminal
/// background's, since that is what the ink sits on; otherwise the OS's.
///
/// Keyed on the pane being ON glass, not on it drawing there: the scheme is
/// a profile setting every pane in the app shares, and a website on a glass
/// window must not flip it back under the markdown pane beside it. That is
/// also Mac's shape - a site in a dark-backgrounded window is told dark.
///
/// Generic over the scheme type so the pane can pass WebView2's own enum
/// (which also has `auto`, the OS-follow degrade) straight through.
pub fn pageScheme(comptime S: type, os: S, on_glass: bool, bg: color_math.Rgb) S {
    if (!on_glass) return os;
    return if (color_math.isLight(bg)) .light else .dark;
}

/// What WebView2 paints under the page, as ARGB (`COREWEBVIEW2_COLOR`). Fully
/// transparent over the sheet - the runtime then shows the host window's
/// pixels, which is where the sheet is painted - and the runtime's own white
/// otherwise, which is what every pane had before T1885.
pub const Argb = struct { a: u8, r: u8, g: u8, b: u8 };

pub fn defaultBackground(draws_on_glass: bool) Argb {
    return if (draws_on_glass)
        .{ .a = 0, .r = 0, .g = 0, .b = 0 }
    else
        .{ .a = 0xFF, .r = 0xFF, .g = 0xFF, .b = 0xFF };
}

/// The template's own background yields to the sheet (`viewer.css`
/// `html.pane-glass`), the exact call Mac's `pushGlassToPage` makes.
pub fn classToggleJs(draws_on_glass: bool) []const u8 {
    return if (draws_on_glass)
        "document.documentElement.classList.toggle('pane-glass', true)"
    else
        "document.documentElement.classList.toggle('pane-glass', false)";
}

const testing = std.testing;

test "T1885: our own pages go see-through on glass; a website and an html file keep their own" {
    try testing.expect(drawsOnGlass(true, .markdown));
    try testing.expect(drawsOnGlass(true, .code));
    try testing.expect(drawsOnGlass(true, .diff));
    try testing.expect(drawsOnGlass(true, .image));
    try testing.expect(!drawsOnGlass(true, .web));
    try testing.expect(!drawsOnGlass(true, .html));
    // Off glass, nothing does.
    inline for (.{ .markdown, .code, .diff, .image, .web, .html }) |m| {
        try testing.expect(!drawsOnGlass(false, m));
    }
}

test "T1885: on glass the page's scheme is the terminal background's, off it the OS's" {
    const dark_bg: color_math.Rgb = .{ .r = 0x28, .g = 0x2C, .b = 0x34 };
    const light_bg: color_math.Rgb = .{ .r = 0xFA, .g = 0xFA, .b = 0xFA };
    // The mismatch this exists for: a light OS over the dark default
    // terminal would be dark ink on a dark sheet.
    try testing.expectEqual(Scheme.dark, pageScheme(Scheme, .light, true, dark_bg));
    try testing.expectEqual(Scheme.light, pageScheme(Scheme, .dark, true, light_bg));
    try testing.expectEqual(Scheme.light, pageScheme(Scheme, .light, false, dark_bg));
    try testing.expectEqual(Scheme.dark, pageScheme(Scheme, .dark, false, light_bg));
}

test "T1885: the web view's own background is clear only over the sheet" {
    try testing.expectEqual(@as(u8, 0), defaultBackground(true).a);
    const solid = defaultBackground(false);
    try testing.expectEqual(@as(u8, 0xFF), solid.a);
    try testing.expectEqual(@as(u8, 0xFF), solid.r);
    try testing.expect(std.mem.endsWith(u8, classToggleJs(true), "true)"));
    try testing.expect(std.mem.endsWith(u8, classToggleJs(false), "false)"));
}
