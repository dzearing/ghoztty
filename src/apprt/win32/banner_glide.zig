//! Pure math for the frozen-frame glide behind a pane banner's collapse or
//! expand (T2252, Mac a81db68f9 `BannerGlide`).
//!
//! A toggle resizes the terminal ONCE, at the click, while a copy of its last
//! frame stands in for it. The copy starts where the content was and moves,
//! on the card's own curve, to where the content will land after the resize:
//! the inset change plus the grid's own row shift (`Surface.predictResizeShift`).
//! Text at the top of the screen rides the card's edge; text laid out to the
//! bottom (a shell at the end of its scrollback, an agent's input box) holds
//! still while the card covers or uncovers rows above it. The live terminal
//! comes back once it has redrawn at the new size, in the same place.
//!
//! Unit tested in every app-runtime lane (the banner_layout pattern).

const std = @import("std");
const hero_math = @import("hero_math.zig");

/// How long frames must stop changing at the new size for the resize to have
/// landed (Mac `settleQuiet`, 0.04s).
pub const SETTLE_QUIET_MS: u64 = 40;

/// The longest the frozen copy stands in, landed or not (Mac `settleCap`,
/// 0.5s): a terminal that never redraws must not stay hidden.
pub const SETTLE_CAP_MS: u64 = 500;

/// How far down (px) the frozen copy travels over the whole toggle: the inset
/// change, plus how far the first row moves inside the resized grid.
pub fn travel(old_inset: i32, new_inset: i32, shift: i32) i32 {
    return new_inset - old_inset + shift;
}

/// The copy's offset from where it started, `linear` (0-1) through the
/// card's animation. Same ease as `banner_layout.collapseHeight`, so the copy
/// is exactly as far through its glide as the card is through its travel, and
/// exact at both ends so the swap to the live terminal never steps a pixel.
pub fn offset(delta: i32, linear: f32) i32 {
    const p = hero_math.easeInOutCubic(linear);
    if (p <= 0.0) return 0;
    if (p >= 1.0) return delta;
    const d: f32 = @floatFromInt(delta);
    return @intFromFloat(@round(d * p));
}

/// `offset`'s ease as an f64 curve (T2763), the shape the compositor glide
/// is fitted to (`comp_overlay.fitCurve`), so DWM moves the copy along the
/// same path the stepped glide rounds to.
pub fn easeF64(t: f64) f64 {
    const c = std.math.clamp(t, 0, 1);
    if (c < 0.5) return 4 * c * c * c;
    const u = -2 * c + 2;
    return 1 - (u * u * u) / 2;
}

/// The height the grid will be resized to: the surface gives up (or takes
/// back) exactly what the band gains (or loses). Never below one pixel.
pub fn resizedHeight(old_h: i32, old_inset: i32, new_inset: i32) u32 {
    return @intCast(@max(old_h + old_inset - new_inset, 1));
}

pub const Settle = struct {
    /// The card has finished its travel.
    anim_done: bool,
    /// Since the toggle.
    elapsed_ms: u64,
    /// The last frame the terminal presented is at its new size.
    landed: bool,
    /// Since the presented frame last changed.
    quiet_ms: u64,
};

/// May the live terminal replace the frozen copy now? Never mid-glide (the
/// copy is the only thing on the path); after it, once the resize has landed
/// and gone quiet, or at the cap whatever the terminal is doing.
pub fn shouldRelease(s: Settle) bool {
    if (s.elapsed_ms >= SETTLE_CAP_MS) return true;
    if (!s.anim_done) return false;
    return s.landed and s.quiet_ms >= SETTLE_QUIET_MS;
}

/// The window the frozen copy is seated directly beneath (T2261).
pub const Seat = enum { card, dim };

/// Mac stacks an unfocused pane's dim above everything in the pane, the
/// frozen terminal included (`SurfaceView`'s ZStack), so the copy must sit
/// under the card AND under a shown dim, whichever of the two is lower.
/// Seated under the card alone, it lands above a dim the card covers, and
/// for the length of the glide the unfocused pane shows undimmed.
pub fn copySeat(dim_shown: bool, dim_below_card: bool) Seat {
    return if (dim_shown and dim_below_card) .dim else .card;
}

/// The visual copy (T2617) cannot paint background around itself the way the
/// popup does, so it carries that background: `pad` rows of it above and
/// below the frame, enough to fill whatever gap the glide opens on either side.
pub fn visualPad(delta: i32) u32 {
    return @intCast(if (delta < 0) -delta else delta);
}

/// Where the visual copy's top sits in its parent - the pane's tree root,
/// which hangs `band` px below the pane window's top (T2566) - when the frame
/// started at window row `img_top` and has glided `off` px.
pub fn visualTop(img_top: i32, off: i32, pad: u32, band: u32) i32 {
    return img_top + off - @as(i32, @intCast(pad)) - @as(i32, @intCast(band));
}

/// Build the visual copy's pixels (T2617): the captured frame - BGRA,
/// bottom-up, `w` x `h`, the renderer's capture layout - turned top-down and
/// opaque, between `pad` rows of the pane background (`bg_rgb` a COLORREF,
/// 0x00BBGGRR) above and below. `out` holds `w * (h + 2 * pad)`.
pub fn buildVisualPixels(out: []u32, frame: []const u8, w: u32, h: u32, pad: u32, bg_rgb: u32) void {
    const bg: u32 = 0xFF000000 | ((bg_rgb & 0xFF) << 16) | (bg_rgb & 0xFF00) | ((bg_rgb >> 16) & 0xFF);
    const wi: usize = w;
    const pad_n: usize = @as(usize, pad) * wi;
    @memset(out[0..pad_n], bg);
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const src = frame[(@as(usize, h) - 1 - row) * wi * 4 ..][0 .. wi * 4];
        const dst = out[pad_n + row * wi ..][0..wi];
        for (dst, 0..) |*p, x| p.* = 0xFF000000 | std.mem.readInt(u32, src[x * 4 ..][0..4], .little);
    }
    @memset(out[pad_n + @as(usize, h) * wi ..][0..pad_n], bg);
}

test "visualPad: the glide's distance, either way" {
    try std.testing.expectEqual(@as(u32, 72), visualPad(-72));
    try std.testing.expectEqual(@as(u32, 72), visualPad(72));
    try std.testing.expectEqual(@as(u32, 0), visualPad(0));
}

test "visualTop: the frame's window row, less the pad above it, in the root's coordinates" {
    // Band 120 at the start: the frame sits at the root's origin less the pad.
    try std.testing.expectEqual(@as(i32, -72), visualTop(120, 0, 72, 120));
    // Glided up 72 with the root still at the old band (the renderer has not
    // presented the new one yet).
    try std.testing.expectEqual(@as(i32, -144), visualTop(120, -72, 72, 120));
    // Same window position once the root has moved to the new band 48: the
    // copy stays put on screen across the band change.
    try std.testing.expectEqual(@as(i32, -72), visualTop(120, -72, 72, 48));
}

test "buildVisualPixels: top-down, opaque, background above and below" {
    // 2x2 frame, bottom-up: bottom row first.
    const frame = [_]u8{
        1, 2, 3, 0, 4, 5, 6, 0, // bottom row
        7, 8, 9, 0, 10, 11, 12, 0, // top row
    };
    var out: [2 * (2 + 2)]u32 = undefined;
    // Background RGB(0x11,0x22,0x33) as a COLORREF.
    buildVisualPixels(&out, &frame, 2, 2, 1, 0x00332211);
    const bg: u32 = 0xFF112233;
    try std.testing.expectEqual(bg, out[0]);
    try std.testing.expectEqual(bg, out[1]);
    try std.testing.expectEqual(@as(u32, 0xFF090807), out[2]);
    try std.testing.expectEqual(@as(u32, 0xFF0C0B0A), out[3]);
    try std.testing.expectEqual(@as(u32, 0xFF030201), out[4]);
    try std.testing.expectEqual(@as(u32, 0xFF060504), out[5]);
    try std.testing.expectEqual(bg, out[6]);
    try std.testing.expectEqual(bg, out[7]);
}

test "travel: collapse moves content up by the band it gives back" {
    // Band 120 -> 48, a shell at the top of a fresh screen: no grid shift.
    try std.testing.expectEqual(@as(i32, -72), travel(120, 48, 0));
    // Same collapse, a shell at the bottom of its scrollback: the grid pulls
    // 72px of history in at the top, so the content holds still.
    try std.testing.expectEqual(@as(i32, 0), travel(120, 48, 72));
}

test "travel: expand pushes content down unless rows are trimmed" {
    try std.testing.expectEqual(@as(i32, 72), travel(48, 120, 0));
    try std.testing.expectEqual(@as(i32, 0), travel(48, 120, -72));
}

test "offset: exact endpoints, eased between, never past the travel" {
    try std.testing.expectEqual(@as(i32, 0), offset(-72, 0.0));
    try std.testing.expectEqual(@as(i32, -72), offset(-72, 1.0));
    try std.testing.expectEqual(@as(i32, -36), offset(-72, 0.5));
    try std.testing.expectEqual(@as(i32, 0), offset(0, 0.5));
    var prev: i32 = 0;
    var i: usize = 0;
    while (i <= 20) : (i += 1) {
        const o = offset(100, @as(f32, @floatFromInt(i)) / 20.0);
        try std.testing.expect(o >= prev and o <= 100);
        prev = o;
    }
    // Eased, not linear: a quarter of the way through is well short of 25.
    try std.testing.expect(offset(100, 0.25) < 25);
}

test "easeF64: the stepped glide's ease, so both paths run one path (T2763)" {
    var i: usize = 0;
    while (i <= 100) : (i += 1) {
        const t: f32 = @as(f32, @floatFromInt(i)) / 100.0;
        try std.testing.expectApproxEqAbs(@as(f64, hero_math.easeInOutCubic(t)), easeF64(t), 1e-5);
    }
    try std.testing.expectEqual(@as(f64, 0), easeF64(-1));
    try std.testing.expectEqual(@as(f64, 1), easeF64(2));
}

test "resizedHeight: the surface trades height with the band" {
    try std.testing.expectEqual(@as(u32, 672), resizedHeight(600, 120, 48));
    try std.testing.expectEqual(@as(u32, 528), resizedHeight(600, 48, 120));
    try std.testing.expectEqual(@as(u32, 1), resizedHeight(10, 0, 500));
}

test "shouldRelease: never mid-glide, then landed and quiet, or the cap" {
    // Landed and quiet, but the card is still moving: hold.
    try std.testing.expect(!shouldRelease(.{ .anim_done = false, .elapsed_ms = 100, .landed = true, .quiet_ms = 100 }));
    // Done, landed, not yet quiet: hold.
    try std.testing.expect(!shouldRelease(.{ .anim_done = true, .elapsed_ms = 200, .landed = true, .quiet_ms = 10 }));
    // Done, quiet but not at the new size: hold.
    try std.testing.expect(!shouldRelease(.{ .anim_done = true, .elapsed_ms = 200, .landed = false, .quiet_ms = 100 }));
    // Done, landed, quiet: release.
    try std.testing.expect(shouldRelease(.{ .anim_done = true, .elapsed_ms = 200, .landed = true, .quiet_ms = 40 }));
    // A terminal that never redraws is released at the cap regardless.
    try std.testing.expect(shouldRelease(.{ .anim_done = false, .elapsed_ms = 500, .landed = false, .quiet_ms = 0 }));
}

test "copySeat: under the card, or under the dim when the dim is the lower" {
    // A focused pane (no dim): the card is the only thing to sit under.
    try std.testing.expectEqual(Seat.card, copySeat(false, false));
    try std.testing.expectEqual(Seat.card, copySeat(false, true));
    // The dim is above the card: under the card is under the dim too.
    try std.testing.expectEqual(Seat.card, copySeat(true, false));
    // The dim is below the card: under the card alone would cover it.
    try std.testing.expectEqual(Seat.dim, copySeat(true, true));
}
