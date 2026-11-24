//! The pane style on GTK, the pure half (T3566, Linux L11d;
//! docs/reference/pane-style.md).
//!
//! The Mac's `PaneElevation` / `PaneDesk` / `PaneCard`: in the `elevated`
//! style (`macos-pane-style`, the default) a window's panes are raised
//! rounded cards on a gradient "desk", one 10pt gutter between every card and
//! around the edge, and the focused pane of several is backlit by a soft
//! light that spills onto the desk. GTK draws the desk in the split tree's
//! snapshot (a small texture of the shared gradient, stretched) and the cards
//! in CSS (`style.css`, `.pane-elevated`). What is decided here:
//!
//!   * the desk's colours - win32's `desk_palette.zig`, which is Mac's
//!     `PaneDeskPalette`/`PaneDeskVariant` draw for draw, so one seed is one
//!     gradient on every platform;
//!   * which window gets its OWN gradient (a hand-opened window, and
//!     `+new-window --color=random`) and which `--color` still tints the
//!     terminal instead;
//!   * which card is the focused one.
//!
//! No GTK imports, so the tests run in the `none` lane.
const std = @import("std");
const testing = std.testing;
const desk = @import("../win32/desk_palette.zig");
const color_math = @import("../win32/color_math.zig");

pub const Palette = desk.Palette;
pub const Variant = desk.Variant;

/// `macos-pane-style`, mirrored so this module stays free of the config.
pub const Style = desk.Variant.Style;
/// `macos-window-gradient`, mirrored likewise.
pub const NewWindowGradient = desk.Variant.NewWindowGradient;

/// ONE spacing is every gutter in the elevated style - pane to pane and pane
/// to window edge (Mac `PaneLayout.Metrics`, 10pt). The CSS splits it: each
/// card takes half as margin, and the tree takes the other half as padding,
/// so two neighbours sit a whole gutter apart and the edge is a gutter away.
pub const gutter: u32 = 10;
/// A card's corner radius (Mac `PaneCard`, 11pt).
pub const card_radius: u32 = 11;
/// The hairline rim's white, unfocused and focused (Mac `PaneGlass`: 10%
/// against 34%; black on a light theme).
pub const rim_unfocused: f32 = 0.10;
pub const rim_focused: f32 = 0.34;

/// The CSS classes the split tree carries for a style. `style.css` keys
/// everything on these; `flat` carries none and stays the stock look.
pub const tree_class_elevated: [:0]const u8 = "pane-elevated";
pub const tree_class_light: [:0]const u8 = "pane-desk-light";
/// ... and each pane's card (its scrolled window), and the backlit one.
pub const card_class: [:0]const u8 = "pane-card";
pub const card_class_focused: [:0]const u8 = "pane-focused";

/// Whether the desk and its cards are drawn at all.
pub fn hasDesk(style: Style) bool {
    return style == .elevated;
}

/// The focused pane OF SEVERAL is backlit (Mac `PaneFocusGlow`, driven by
/// `PaneView.isFocusedPane`); a window's only pane has nothing to stand out
/// from, so it is never lit.
pub fn isFocusedCard(style: Style, pane_count: usize, is_focused_pane: bool) bool {
    return hasDesk(style) and pane_count > 1 and is_focused_pane;
}

/// A desk is light when the terminal background it sits behind is (win32
/// reads the same luminance; Mac `isLight`).
pub fn isLight(background: color_math.Rgb) bool {
    return color_math.isLight(background);
}

/// Whether a `+new-window --color` value becomes the window's OWN gradient
/// rather than a terminal tint: `random`, in the elevated style (Mac
/// `PaneDeskVariant`; win32 `deskVariantFor`, T1832). An explicit `#hex`, no
/// colour, and anything in the flat style (no desk to vary) are not.
pub fn colorIsWindowGradient(color: ?[]const u8, style: Style) bool {
    const v = color orelse return false;
    return hasDesk(style) and std.mem.eql(u8, v, "random");
}

/// The window's gradient for a `+new-window --color` value: a fresh random
/// variant when the colour is the window's gradient, else none (the shared
/// ocean). A programmatic window never takes the hand-opened default.
pub fn variantForColor(color: ?[]const u8, style: Style) ?Variant {
    return if (colorIsWindowGradient(color, style)) Variant.random() else null;
}

/// The gradient a window opened BY HAND starts with (Mac
/// `PaneDeskVariant.forNewWindow`): its own random one under
/// `macos-window-gradient = random` (the default), the ocean under `ocean`,
/// none in the flat style.
pub fn variantForNewWindow(style: Style, gradient: NewWindowGradient) ?Variant {
    return Variant.forNewWindow(style, gradient);
}

/// The size the desk is rendered at for a `w` x `h` (logical) tree, before
/// it is stretched over it: win32's downscale (`deskDownscale`, an eighth of
/// a big window, a quarter of a small one), at least one texel each way.
pub const DeskSize = struct { w: usize, h: usize };
pub fn deskSize(w: usize, h: usize) DeskSize {
    const d = desk.deskDownscale(w, h);
    return .{ .w = @max(1, (w + d - 1) / d), .h = @max(1, (h + d - 1) / d) };
}

/// What a cached desk texture was rendered for; a new one is rendered only
/// when this changes (a resize, a theme flip, a new variant).
pub const DeskKey = struct {
    w: usize = 0,
    h: usize = 0,
    seed: ?u64 = null,
    is_light: bool = false,

    pub fn eql(a: DeskKey, b: DeskKey) bool {
        return a.w == b.w and a.h == b.h and a.seed == b.seed and a.is_light == b.is_light;
    }
};

/// Render the desk of a `full_w` x `full_h` tree into `buf` (`size.w` x
/// `size.h` texels) as opaque 0xAARRGGBB words - in memory on a
/// little-endian machine, GDK's `B8G8R8A8_PREMULTIPLIED`.
pub fn renderDesk(buf: []u32, size: DeskSize, full_w: f32, full_h: f32, pal: Palette) void {
    desk.renderDesk(buf, size.w, size.h, full_w, full_h, pal);
    for (buf[0 .. size.w * size.h]) |*p| p.* |= 0xFF00_0000;
}

test "T3566: only the elevated style has a desk and cards" {
    try testing.expect(hasDesk(.elevated));
    try testing.expect(!hasDesk(.flat));
}

test "T3566: the focused pane is lit only when it is one of several" {
    try testing.expect(isFocusedCard(.elevated, 2, true));
    try testing.expect(!isFocusedCard(.elevated, 2, false));
    try testing.expect(!isFocusedCard(.elevated, 1, true));
    try testing.expect(!isFocusedCard(.flat, 3, true));
}

test "T3566: --color=random is the window's gradient only in the elevated style" {
    try testing.expect(colorIsWindowGradient("random", .elevated));
    try testing.expect(!colorIsWindowGradient("random", .flat));
    try testing.expect(!colorIsWindowGradient("#336699", .elevated));
    try testing.expect(!colorIsWindowGradient(null, .elevated));
    try testing.expect(variantForColor("random", .elevated) != null);
    try testing.expect(variantForColor("#336699", .elevated) == null);
    try testing.expect(variantForColor(null, .elevated) == null);
}

test "T3566: a hand-opened window follows macos-window-gradient" {
    try testing.expect(variantForNewWindow(.elevated, .random) != null);
    try testing.expect(variantForNewWindow(.elevated, .ocean) == null);
    try testing.expect(variantForNewWindow(.flat, .random) == null);
}

test "T3566: the desk is rendered small and never empty" {
    try testing.expectEqual(DeskSize{ .w = 100, .h = 75 }, deskSize(800, 600));
    try testing.expectEqual(DeskSize{ .w = 75, .h = 50 }, deskSize(300, 200));
    try testing.expectEqual(DeskSize{ .w = 1, .h = 1 }, deskSize(0, 0));
}

test "T3566: the rendered desk is opaque and is the shared gradient" {
    const size = deskSize(800, 600);
    var buf: [100 * 75]u32 = undefined;
    const pal = Palette.ocean(false);
    renderDesk(&buf, size, 800, 600, pal);
    for (buf) |p| try testing.expectEqual(@as(u32, 0xFF), p >> 24);
    // The same texel as the shared renderer, alpha aside.
    var ref: [100 * 75]u32 = undefined;
    desk.renderDesk(&ref, size.w, size.h, 800, 600, pal);
    try testing.expectEqual(ref[0] & 0xFFFFFF, buf[0] & 0xFFFFFF);
    try testing.expectEqual(ref[ref.len - 1] & 0xFFFFFF, buf[buf.len - 1] & 0xFFFFFF);
    // The ocean's two corners differ (a gradient, not a fill).
    try testing.expect(buf[0] != buf[buf.len - 1]);
}

test "T3566: a desk key changes with size, theme and variant" {
    const a: DeskKey = .{ .w = 10, .h = 10, .seed = 7, .is_light = false };
    try testing.expect(a.eql(a));
    try testing.expect(!a.eql(.{ .w = 11, .h = 10, .seed = 7 }));
    try testing.expect(!a.eql(.{ .w = 10, .h = 10, .seed = null }));
    try testing.expect(!a.eql(.{ .w = 10, .h = 10, .seed = 7, .is_light = true }));
}
