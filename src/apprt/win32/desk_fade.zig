//! Single-window mode's shade crossfade (T3183; Mac `PaneDeskEntrance` /
//! `PaneDeskFade`): when a workspace goes on show, the window's gradient goes
//! from the workspace that left to the one that came - the old desk drawn
//! over the new one and faded out over 0.35s, SwiftUI `.easeInOut`. Nothing
//! fades in the flat style, which has no desk, or between two workspaces with
//! the same gradient (Mac: `leavingShade != deskVariant`).
//!
//! The pure half: when a fade is owed, how much of the old desk is left at a
//! moment of it, and the blend itself. `PaneDesk.ensureDesk` blends the two
//! gradients at the small size it renders them at, before the stretch, so a
//! frame of the fade costs one more small gradient and nothing at full size.
//! No OS imports, so the tests run in every app-runtime lane.
const std = @import("std");
const bell_math = @import("bell_math.zig");

/// Mac `PaneDeskEntrance.duration`.
pub const duration_ms: i64 = 350;

/// Whether a switch to a workspace shaded `to` from one shaded `from` fades
/// (null: the ocean). `elevated` - the style has a desk at all; `animations` -
/// the OS's "Animation effects" (`App.clientAreaAnimationsEnabled`): off, the
/// shade swaps at once like every other in-window motion.
pub fn owed(comptime V: type, elevated: bool, animations: bool, from: ?V, to: ?V) bool {
    if (!elevated or !animations) return false;
    return !std.meta.eql(from, to);
}

/// How much of the OLD desk shows `elapsed_ms` into the fade, 255..0 on the
/// ease-in-out curve; null once the fade is over (the new desk alone).
pub fn keep(elapsed_ms: i64) ?u8 {
    if (elapsed_ms >= duration_ms) return null;
    if (elapsed_ms <= 0) return 255;
    const t = @as(f64, @floatFromInt(elapsed_ms)) / @as(f64, @floatFromInt(duration_ms));
    const left = 1.0 - bell_math.easeInOut(t);
    return @intFromFloat(std.math.clamp(@round(left * 255.0), 0, 255));
}

/// Lay `old` over `new` at `k`/255 (0x00RRGGBB pixels): `new` takes the
/// result. The top byte stays `new`'s.
pub fn blend(new: []u32, old: []const u32, k: u8) void {
    std.debug.assert(old.len >= new.len);
    if (k == 0) return;
    if (k == 255) {
        for (new, old[0..new.len]) |*n, o| n.* = (n.* & 0xFF00_0000) | (o & 0x00FF_FFFF);
        return;
    }
    const a: u32 = k;
    const b: u32 = 255 - k;
    for (new, old[0..new.len]) |*n, o| {
        const nv = n.*;
        n.* = (nv & 0xFF00_0000) |
            (mix((o >> 16) & 0xFF, (nv >> 16) & 0xFF, a, b) << 16) |
            (mix((o >> 8) & 0xFF, (nv >> 8) & 0xFF, a, b) << 8) |
            mix(o & 0xFF, nv & 0xFF, a, b);
    }
}

fn mix(o: u32, n: u32, a: u32, b: u32) u32 {
    return (o * a + n * b + 127) / 255;
}

const testing = std.testing;
const TV = struct { seed: u64 };

test "T3183: a switch fades only between two different shades, elevated, with animations on" {
    try testing.expect(owed(TV, true, true, .{ .seed = 1 }, .{ .seed = 2 }));
    // The ocean is a shade too.
    try testing.expect(owed(TV, true, true, null, .{ .seed = 2 }));
    try testing.expect(owed(TV, true, true, .{ .seed = 1 }, null));
    // Mac: `leavingShade != deskVariant`.
    try testing.expect(!owed(TV, true, true, .{ .seed = 7 }, .{ .seed = 7 }));
    try testing.expect(!owed(TV, true, true, null, null));
    // The flat style has no desk; Animation effects off swaps at once.
    try testing.expect(!owed(TV, false, true, .{ .seed = 1 }, .{ .seed = 2 }));
    try testing.expect(!owed(TV, true, false, .{ .seed = 1 }, .{ .seed = 2 }));
}

test "T3183: the old desk starts whole, eases out over 0.35s, and is gone at the end" {
    try testing.expectEqual(@as(?u8, 255), keep(0));
    try testing.expectEqual(@as(?u8, 255), keep(-5));
    try testing.expectEqual(@as(?u8, null), keep(duration_ms));
    try testing.expectEqual(@as(?u8, null), keep(10_000));
    // Halfway in time is halfway in opacity (the curve is symmetric).
    const mid = keep(@divTrunc(duration_ms, 2)).?;
    try testing.expect(mid >= 126 and mid <= 129);
    // Ease-in: slow to leave at first - well over a straight line's 237.
    try testing.expect(keep(25).? > 245);
    // Never rises.
    var last: u8 = 255;
    var ms: i64 = 0;
    while (ms < duration_ms) : (ms += 1) {
        const k = keep(ms).?;
        try testing.expect(k <= last);
        last = k;
    }
}

test "T3183: the blend lays the old desk over the new at its strength" {
    var new = [_]u32{ 0x00_00_00_00, 0x00_FF_FF_FF, 0xAB_10_20_30 };
    const old = [_]u32{ 0x00_FF_FF_FF, 0x00_00_00_00, 0x00_30_20_10 };
    var n1 = new;
    blend(&n1, &old, 0);
    try testing.expectEqualSlices(u32, &new, &n1);
    var n2 = new;
    blend(&n2, &old, 255);
    try testing.expectEqual(@as(u32, 0x00_FF_FF_FF), n2[0]);
    try testing.expectEqual(@as(u32, 0x00_00_00_00), n2[1]);
    // The top byte is the new desk's.
    try testing.expectEqual(@as(u32, 0xAB_30_20_10), n2[2]);
    blend(&new, &old, 128);
    try testing.expectEqual(@as(u32, 0x00_80_80_80), new[0]);
    try testing.expectEqual(@as(u32, 0x00_7F_7F_7F), new[1]);
    try testing.expectEqual(@as(u32, 0xAB_20_20_20), new[2]);
}
