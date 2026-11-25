//! Wheel-delta accumulation for every owner-painted win32 scroller (T3738).
//!
//! A mouse wheel sends WM_MOUSEWHEEL in whole detents of WHEEL_DELTA (120).
//! A precision touchpad - and a trackpad forwarded over Remote Desktop in
//! particular - sends many small deltas instead (15, 20, 40 ...). Scrolling by
//! `@divTrunc(delta, 120)` rounds every one of those to zero, which is how the
//! Settings window came to ignore a trackpad completely while a wheel worked.
//!
//! `Accum` carries the remainder from one message to the next, so N small
//! deltas that add up to one detent scroll exactly one detent's worth. A
//! change of direction drops the carried remainder: a half-detent left over
//! from scrolling down must not swallow the first half-detent of scrolling up.
//!
//! Pure (std only), so it runs in every test lane.

const std = @import("std");

pub const wheel_delta: i32 = 120;

pub const Accum = struct {
    rem: i64 = 0,

    /// How far `delta` moves, in units where one whole detent (120) is
    /// `per_notch`. The sign follows `delta`: a positive delta (the wheel
    /// rolled away from the user) gives a positive result, so a vertical
    /// scroller's offset changes by the NEGATED result, exactly as it did by
    /// `-notches * step`.
    pub fn amount(self: *Accum, delta: i32, per_notch: i32) i32 {
        if (delta == 0 or per_notch == 0) return 0;
        if (self.rem != 0 and (self.rem > 0) != (delta > 0)) self.rem = 0;
        const total: i64 = @as(i64, delta) * @as(i64, per_notch) + self.rem;
        const moved = @divTrunc(total, wheel_delta);
        self.rem = total - moved * wheel_delta;
        return @intCast(std.math.clamp(moved, std.math.minInt(i32), std.math.maxInt(i32)));
    }

    /// Whole detents, for a scroller that moves by discrete steps (a card, a
    /// thumbnail): small deltas add up to one step instead of none.
    pub fn notches(self: *Accum, delta: i32) i32 {
        return self.amount(delta, 1);
    }

    pub fn reset(self: *Accum) void {
        self.rem = 0;
    }
};

/// The signed 16-bit wheel delta in the high word of a WM_MOUSEWHEEL /
/// WM_MOUSEHWHEEL wParam.
pub fn deltaOf(wparam: usize) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(wparam >> 16))));
}

const testing = std.testing;

test "wheel_accum: a whole detent scrolls one step, either way" {
    var a: Accum = .{};
    try testing.expectEqual(@as(i32, 40), a.amount(120, 40));
    try testing.expectEqual(@as(i32, -40), a.amount(-120, 40));
    try testing.expectEqual(@as(i32, 80), a.amount(240, 40));
    try testing.expectEqual(@as(i64, 0), a.rem);
}

test "wheel_accum: six deltas of 20 scroll exactly one wheel step" {
    var a: Accum = .{};
    var total: i32 = 0;
    for (0..6) |_| total += a.amount(20, 48);
    try testing.expectEqual(@as(i32, 48), total);
    try testing.expectEqual(@as(i64, 0), a.rem);
    // And a delta of 15 is never rounded to nothing: eight of them are a detent.
    var b: Accum = .{};
    var moved: i32 = 0;
    for (0..8) |_| moved += b.amount(-15, 48);
    try testing.expectEqual(@as(i32, -48), moved);
}

test "wheel_accum: small deltas move as they arrive, not only at the detent" {
    var a: Accum = .{};
    // 15/120 of a 48px step is 6px - the scroller moves on the first message.
    try testing.expectEqual(@as(i32, 6), a.amount(15, 48));
}

test "wheel_accum: a reversal does not carry the old direction's remainder" {
    var a: Accum = .{};
    try testing.expectEqual(@as(i32, 0), a.notches(60));
    // Without the reset, -60 would cancel the +60 and leave nothing carried.
    try testing.expectEqual(@as(i32, 0), a.notches(-60));
    try testing.expectEqual(@as(i32, -1), a.notches(-60));
    try testing.expectEqual(@as(i32, 0), a.notches(100));
    try testing.expectEqual(@as(i32, 0), a.notches(-100));
    try testing.expectEqual(@as(i64, -100), a.rem);
}

test "wheel_accum: discrete steppers count whole detents from small deltas" {
    var a: Accum = .{};
    var steps: i32 = 0;
    for (0..12) |_| steps += a.notches(20);
    try testing.expectEqual(@as(i32, 2), steps);
}

test "wheel_accum: deltaOf reads the signed high word" {
    try testing.expectEqual(@as(i32, 120), deltaOf(@as(usize, 120) << 16));
    try testing.expectEqual(@as(i32, -15), deltaOf(@as(usize, 0xFFF1) << 16 | 0x0008));
}

test "wheel_accum: zero and huge inputs are safe" {
    var a: Accum = .{};
    try testing.expectEqual(@as(i32, 0), a.amount(0, 48));
    try testing.expectEqual(@as(i32, 0), a.amount(120, 0));
    _ = a.amount(std.math.maxInt(i16), 100_000);
    _ = a.amount(std.math.minInt(i16), 100_000);
}
