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
