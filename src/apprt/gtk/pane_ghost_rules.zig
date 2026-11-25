//! The card a pane drag carries under the pointer on GTK (T3617, Linux
//! L11b5; Mac `PaneDragGhost.swift`, win32 `pane_drag_ghost.zig`): the pure
//! half. Every size, colour and the hot spot come from win32's module - the
//! Mac's numbers - at GTK's LOGICAL scale (1.0): GTK scales a drag icon to
//! the device itself, so the card is planned in logical pixels and only its
//! texture is rendered at the device scale (`PaneDragGhost.zig`).
//!
//! No GTK imports: none-lane tested (`src/apprt/unit_tests.zig`).
const std = @import("std");
const ghost = @import("../win32/pane_drag_ghost.zig");

pub const Rgb = ghost.Rgb;
pub const Size = ghost.Size;
pub const Rect = ghost.Rect;

/// Everything the renderer draws, in the image's logical coordinates.
pub const Plan = struct {
    /// The card itself, at most 220x150 in the pane's own shape.
    card: Size,
    /// The image: the card plus its shadow margin all round.
    image: Size,
    /// Where the card, its title strip and its body sit in the image.
    lay: ghost.Layout,
    /// The size the pane's content is drawn at so it COVERS the body,
    /// anchored at the body's top-left (the overhang is the bottom/right).
    content: Size,
    /// The point of the image the pointer holds: the middle of the title
    /// strip, so the card hangs below the pointer like a window held by its
    /// titlebar and the drop target stays in view.
    hot_x: i32,
    hot_y: i32,
    /// The card's face, the strip's tint, the title's ink, and the rim's
    /// colour (drawn at `ghost.rim_alpha`).
    bg: Rgb,
    strip: Rgb,
    text: Rgb,
    ink: Rgb,
};

/// The card for a pane drawn `pane_w` x `pane_h` (logical px) whose terminal
/// background is `bg`.
pub fn plan(pane_w: i32, pane_h: i32, bg: Rgb) Plan {
    const scale: f32 = 1.0;
    const card = ghost.cardSize(pane_w, pane_h, scale);
    const image = ghost.imageSize(card, scale);
    const lay = ghost.layout(card, scale);
    const origin = ghost.imageOrigin(.{ .x = 0, .y = 0 }, image, scale);
    return .{
        .card = card,
        .image = image,
        .lay = lay,
        .content = ghost.contentRequest(pane_w, pane_h, .{ .w = lay.body.width(), .h = lay.body.height() }),
        .hot_x = -origin.x,
        .hot_y = -origin.y,
        .bg = bg,
        .strip = ghost.stripColor(bg),
        .text = ghost.textColor(bg),
        .ink = ghost.inkFor(bg),
    };
}

/// The title the strip shows: the pane's label (the rearrange header's, Mac
/// `pane.displayLabel`) trimmed; empty draws a bare strip, as win32's
/// `drawTitle` does.
pub fn title(pane_title: []const u8) []const u8 {
    return std.mem.trim(u8, pane_title, " \t\r\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const dark: Rgb = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e };
const light: Rgb = .{ .r = 0xfa, .g = 0xfa, .b = 0xf5 };

test "plan: a big pane's card fits 220x150 in the pane's own shape" {
    const p = plan(1200, 800, dark);
    try testing.expect(p.card.w <= 220 and p.card.h <= 150);
    // 1200x800 is 3:2; bound by width (220/1200 < 150/800).
    try testing.expectEqual(@as(i32, 220), p.card.w);
    try testing.expectEqual(@as(i32, 147), p.card.h);
}

test "plan: the image is the card plus a 10px shadow margin all round" {
    const p = plan(1200, 800, dark);
    try testing.expectEqual(p.card.w + 20, p.image.w);
    try testing.expectEqual(p.card.h + 20, p.image.h);
    try testing.expectEqual(@as(i32, 10), p.lay.card.left);
    try testing.expectEqual(@as(i32, 10), p.lay.card.top);
}

test "plan: the pointer holds the middle of the title strip" {
    const p = plan(1200, 800, dark);
    try testing.expectEqual(@divTrunc(p.image.w, 2), p.hot_x);
    // 10 margin + half of the 18px strip.
    try testing.expectEqual(@as(i32, 19), p.hot_y);
    try testing.expect(p.hot_y > p.lay.title.top and p.hot_y < p.lay.title.bottom);
}

test "plan: the body sits under an 18px title strip and the content covers it" {
    const p = plan(1200, 800, dark);
    try testing.expectEqual(@as(i32, 18), p.lay.title.height());
    try testing.expectEqual(p.lay.title.bottom, p.lay.body.top);
    try testing.expect(p.content.w >= p.lay.body.width());
    try testing.expect(p.content.h >= p.lay.body.height());
}

test "plan: a sliver of a pane still gets a readable card" {
    const p = plan(40, 900, dark);
    try testing.expect(p.card.w >= 120);
    try testing.expect(p.card.h >= 72);
}

test "plan: an unmeasured pane gets the minimum card, not a crash" {
    const p = plan(0, 0, dark);
    try testing.expectEqual(@as(i32, 120), p.card.w);
    try testing.expectEqual(@as(i32, 72), p.card.h);
}

test "plan: ink is white on a dark card and black on a light one" {
    try testing.expectEqual(@as(u8, 255), plan(800, 600, dark).ink.r);
    try testing.expectEqual(@as(u8, 0), plan(800, 600, light).ink.r);
}

test "plan: the strip is tinted toward the ink, never the bare background" {
    const d = plan(800, 600, dark);
    try testing.expect(d.strip.r > d.bg.r);
    const l = plan(800, 600, light);
    try testing.expect(l.strip.r < l.bg.r);
}

test "title: trimmed; an untitled pane's strip is bare" {
    try testing.expectEqualStrings("", title(""));
    try testing.expectEqualStrings("", title("  \n"));
    try testing.expectEqualStrings("vim notes.md", title(" vim notes.md "));
}
