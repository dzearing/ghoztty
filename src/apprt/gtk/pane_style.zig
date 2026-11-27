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

// ---- Glass panes (T3622; pane-style.md "Glass panes") ---------------------

/// How much of the terminal's background a glass sheet keeps over the desk
/// (Mac `PaneGlass.tint`; win32 `pane_elevation.GLASS_TINT`), focused or not.
pub const glass_tint: f32 = 0.40;
/// ... and under a banner card, which is a pane of glass of its own laid on
/// the pane, so the pane's sheet thins there (Mac `PaneGlass.bannerTint`).
pub const glass_banner_tint: f32 = 0.25;

/// The tree's class while its panes are glass: `style.css` turns the banner
/// strip into a rim-and-shadow card with no wash of its own.
pub const tree_class_glass: [:0]const u8 = "pane-glass";

/// Whether a window's panes are glass sheets: `macos-pane-glass` (default
/// true), in the elevated style only - the flat style has no desk to show.
pub fn hasGlass(style: Style, glass: bool) bool {
    return hasDesk(style) and glass;
}

// ---- The desk under the whole window (T3623) --------------------------------

/// The window's classes while it paints the desk (Mac: the desk sits behind
/// the whole content stack, up under the transparent titlebar). `style.css`
/// turns the header bar and the tab bar transparent over it, and on glass
/// gives the pane sidebar an unfocused pane's card. Distinct from the tree's
/// classes, whose `.pane-elevated` padding must not land on the window.
pub const window_class_desk: [:0]const u8 = "pane-desk-window";
pub const window_class_light: [:0]const u8 = "pane-desk-window-light";
pub const window_class_glass: [:0]const u8 = "pane-desk-window-glass";

/// The pane sidebar's card on glass IS an unfocused pane's card (Mac
/// `PaneSidebarCard` -> `PaneCard`): the same corner radius and the same
/// sheet - the terminal's background at `glass_tint` - so the gradient reads
/// through it the way it reads through the panes beside it. Null off glass,
/// where the card keeps its own light wash over the desk.
pub fn sidebarSheet(style: Style, glass: bool, bg: color_math.Rgb) ?SheetColor {
    if (!hasGlass(style, glass)) return null;
    return sheetColor(bg, false);
}

/// The sidebar card's corner radius: a pane card's.
pub const sidebar_radius: f32 = @floatFromInt(card_radius);

/// Upstream's unfocused dimming - a wash of `unfocused-split-fill` over an
/// unfocused pane of a split - is not drawn on glass: focus changes only the
/// rim and the glow there, and a background-coloured wash would make the
/// unfocused pane the MORE solid one (Mac 9da9618f8; win32 `dim_math`,
/// T2281). Flat, and elevated without glass, keep it.
pub fn showsUnfocusedWash(glass: bool, search_active: bool, focused: bool, is_split: bool) bool {
    return !glass and !search_active and !focused and is_split;
}

/// One band of a pane's sheet: `bg` at `alpha`, premultiplied by nothing
/// (GdkRGBA is straight alpha).
pub const SheetColor = struct { r: f32, g: f32, b: f32, a: f32 };

/// The sheet's colour: the terminal's own background at the glass tint, or
/// the thinner banner tint under a banner card.
pub fn sheetColor(bg: color_math.Rgb, under_banner: bool) SheetColor {
    return .{
        .r = @as(f32, @floatFromInt(bg.r)) / 255.0,
        .g = @as(f32, @floatFromInt(bg.g)) / 255.0,
        .b = @as(f32, @floatFromInt(bg.b)) / 255.0,
        .a = if (under_banner) glass_banner_tint else glass_tint,
    };
}

/// The background a glass sheet is tinted with (T3719): the colour a program
/// set at runtime (OSC 11, or OSC 111's reset to the default) when there is
/// one, else the pane's `--color` tint, else the configured background. The
/// renderer draws no background on glass, so this is the only place the
/// terminal's background shows; a newer tint clears the runtime colour (the
/// Mac's one `backgroundColor`, which the latest of the two sets).
pub fn sheetBackground(runtime: ?color_math.Rgb, tint: ?color_math.Rgb, configured: color_math.Rgb) color_math.Rgb {
    return runtime orelse tint orelse configured;
}

/// A rectangle in the pane's own coordinates.
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// The sheet split into the bands that are drawn: the whole pane at the
/// glass tint, except a banner card's frame, which gets the banner tint.
/// With no banner (or one with no area) it is one band. The bands never
/// overlap, so no part of the pane is tinted twice.
pub const Bands = struct {
    /// Up to four rects around the banner, at `glass_tint`.
    outer: [4]Rect = undefined,
    outer_len: usize = 0,
    /// The banner's frame, at `glass_banner_tint`.
    banner: ?Rect = null,
};

pub fn sheetBands(pane: Rect, banner_: ?Rect) Bands {
    var out: Bands = .{};
    const b = clipRect(banner_ orelse {
        out.outer[0] = pane;
        out.outer_len = 1;
        return out;
    }, pane) orelse {
        out.outer[0] = pane;
        out.outer_len = 1;
        return out;
    };
    out.banner = b;
    const candidates = [4]Rect{
        // above, below (full width), then left and right of the banner's rows
        .{ .x = pane.x, .y = pane.y, .w = pane.w, .h = b.y - pane.y },
        .{ .x = pane.x, .y = b.y + b.h, .w = pane.w, .h = (pane.y + pane.h) - (b.y + b.h) },
        .{ .x = pane.x, .y = b.y, .w = b.x - pane.x, .h = b.h },
        .{ .x = b.x + b.w, .y = b.y, .w = (pane.x + pane.w) - (b.x + b.w), .h = b.h },
    };
    for (candidates) |c| if (c.w > 0 and c.h > 0) {
        out.outer[out.outer_len] = c;
        out.outer_len += 1;
    };
    return out;
}

fn clipRect(r: Rect, to: Rect) ?Rect {
    const x0 = @max(r.x, to.x);
    const y0 = @max(r.y, to.y);
    const x1 = @min(r.x + r.w, to.x + to.w);
    const y1 = @min(r.y + r.h, to.y + to.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

test "T3622: glass is the elevated style's only" {
    try testing.expect(hasGlass(.elevated, true));
    try testing.expect(!hasGlass(.elevated, false));
    try testing.expect(!hasGlass(.flat, true));
}

test "T3622: no unfocused wash on glass; flat and solid cards keep it" {
    try testing.expect(!showsUnfocusedWash(true, false, false, true));
    try testing.expect(showsUnfocusedWash(false, false, false, true));
    // Upstream's own conditions still hold off glass.
    try testing.expect(!showsUnfocusedWash(false, true, false, true));
    try testing.expect(!showsUnfocusedWash(false, false, true, true));
    try testing.expect(!showsUnfocusedWash(false, false, false, false));
}

test "T3622: the sheet is the terminal background at 40%, 25% under a banner" {
    const c = sheetColor(.{ .r = 255, .g = 0, .b = 51 }, false);
    try testing.expectEqual(@as(f32, 1.0), c.r);
    try testing.expectEqual(@as(f32, 0.0), c.g);
    try testing.expectApproxEqAbs(@as(f32, 0.2), c.b, 0.001);
    try testing.expectEqual(glass_tint, c.a);
    try testing.expectEqual(glass_banner_tint, sheetColor(.{ .r = 0, .g = 0, .b = 0 }, true).a);
    try testing.expect(glass_banner_tint < glass_tint);
}

test "T3719: a runtime background (OSC 11) beats the tint, which beats the config" {
    const cfg: color_math.Rgb = .{ .r = 0x20, .g = 0x30, .b = 0x40 };
    const tint: color_math.Rgb = .{ .r = 0x80, .g = 0x10, .b = 0x10 };
    const osc: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 };
    try testing.expectEqual(cfg, sheetBackground(null, null, cfg));
    try testing.expectEqual(tint, sheetBackground(null, tint, cfg));
    try testing.expectEqual(osc, sheetBackground(osc, tint, cfg));
    try testing.expectEqual(osc, sheetBackground(osc, null, cfg));
}

test "T3622: the sheet's bands cover the pane once, the banner at its own tint" {
    const pane: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 80 };
    // No banner: one band, the pane.
    const none = sheetBands(pane, null);
    try testing.expectEqual(@as(usize, 1), none.outer_len);
    try testing.expect(none.banner == null);

    // A banner inset 6px at the top: above, below, left, right.
    const b = sheetBands(pane, .{ .x = 6, .y = 6, .w = 88, .h = 20 });
    try testing.expectEqual(@as(usize, 4), b.outer_len);
    var area: f32 = b.banner.?.w * b.banner.?.h;
    for (b.outer[0..b.outer_len]) |r| area += r.w * r.h;
    try testing.expectEqual(pane.w * pane.h, area);

    // A banner flush with the top and both sides: only the band below.
    const flush = sheetBands(pane, .{ .x = 0, .y = 0, .w = 100, .h = 20 });
    try testing.expectEqual(@as(usize, 1), flush.outer_len);
    try testing.expectEqual(@as(f32, 20), flush.outer[0].y);

    // A banner outside the pane (or empty) is no banner.
    try testing.expect(sheetBands(pane, .{ .x = 200, .y = 0, .w = 10, .h = 10 }).banner == null);
    try testing.expect(sheetBands(pane, .{ .x = 0, .y = 0, .w = 0, .h = 10 }).banner == null);
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

test "T3623: on glass the sidebar card is an unfocused pane's 40% sheet; off glass and flat it has none" {
    const bg: color_math.Rgb = .{ .r = 0x20, .g = 0x30, .b = 0x40 };
    const s = sidebarSheet(.elevated, true, bg).?;
    const pane = sheetColor(bg, false);
    try testing.expectEqual(pane.a, s.a);
    try testing.expectEqual(pane.r, s.r);
    try testing.expectEqual(glass_tint, s.a);
    try testing.expect(sidebarSheet(.elevated, false, bg) == null);
    try testing.expect(sidebarSheet(.flat, true, bg) == null);
    try testing.expectEqual(@as(f32, 11), sidebar_radius);
}

test "T3623: the window's desk classes never reuse the tree's (whose padding would land on the window)" {
    for ([_][:0]const u8{ window_class_desk, window_class_light, window_class_glass }) |c| {
        try testing.expect(!std.mem.eql(u8, c, tree_class_elevated));
        try testing.expect(!std.mem.eql(u8, c, tree_class_light));
        try testing.expect(!std.mem.eql(u8, c, tree_class_glass));
    }
}
