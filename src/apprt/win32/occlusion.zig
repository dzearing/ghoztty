//! Can anybody see this window? (T1951)
//!
//! A window nobody can see should present nothing. Minimized windows and
//! background tabs already stop their renderers (`Window.setActiveTabVisible`,
//! `showTabIndex`); this adds the two cases Windows sends no message for: a
//! window DWM has cloaked (another virtual desktop, a shell-hidden window) and
//! one that other windows cover completely. On a GPU those frames are nearly
//! free; on a Cloud PC with no GPU every one of them is rasterized by WARP on
//! the CPU, and eleven overlapping windows is most of the 12-16 cores GitHub
//! #13 measured.
//!
//! The coverage test is pure (`fullyCovered`, rectangle subtraction) so it is
//! unit tested; `windowHidden` is the half that asks Windows. It errs toward
//! VISIBLE: a window that might be translucent (layered, click-through) or that
//! belongs to the target (its own overlays) never counts as covering it, and a
//! coverage too fragmented to track reads as not covered.

const std = @import("std");
const w32 = @import("win32.zig");

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn empty(self: Rect) bool {
        return self.right <= self.left or self.bottom <= self.top;
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        return .{
            .left = @max(a.left, b.left),
            .top = @max(a.top, b.top),
            .right = @min(a.right, b.right),
            .bottom = @min(a.bottom, b.bottom),
        };
    }
};

/// Most pieces the uncovered remainder may split into before the test gives
/// up and calls the target visible.
const max_pieces = 64;

/// Is every pixel of `target` under one of `covers`?
pub fn fullyCovered(target: Rect, covers: []const Rect) bool {
    if (target.empty()) return true;
    var a: [max_pieces]Rect = undefined;
    var b: [max_pieces]Rect = undefined;
    var cur: []Rect = a[0..1];
    cur[0] = target;
    var use_b = true;
    for (covers) |c| {
        if (c.empty()) continue;
        const dst = if (use_b) &b else &a;
        var n: usize = 0;
        for (cur) |piece| {
            const i = piece.intersect(c);
            if (i.empty()) {
                if (n == max_pieces) return false;
                dst[n] = piece;
                n += 1;
                continue;
            }
            // Up to four strips of `piece` outside `c`.
            const strips = [_]Rect{
                .{ .left = piece.left, .top = piece.top, .right = piece.right, .bottom = i.top },
                .{ .left = piece.left, .top = i.bottom, .right = piece.right, .bottom = piece.bottom },
                .{ .left = piece.left, .top = i.top, .right = i.left, .bottom = i.bottom },
                .{ .left = i.right, .top = i.top, .right = piece.right, .bottom = i.bottom },
            };
            for (strips) |s| {
                if (s.empty()) continue;
                if (n == max_pieces) return false;
                dst[n] = s;
                n += 1;
            }
        }
        if (n == 0) return true;
        cur = dst[0..n];
        use_b = !use_b;
    }
    return false;
}

/// Why a window is hidden, or `.visible`.
pub const State = enum { visible, minimized, cloaked, covered };

/// Can anybody see `hwnd` right now?
pub fn windowHidden(hwnd: w32.HWND) State {
    if (w32.IsIconic(hwnd) != 0) return .minimized;
    if (cloaked(hwnd)) return .cloaked;

    // The client area, on screen, clipped to the virtual desktop: what part
    // of this window could be seen at all.
    var cr: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &cr) == 0) return .visible;
    var tl = w32.POINT{ .x = cr.left, .y = cr.top };
    var br = w32.POINT{ .x = cr.right, .y = cr.bottom };
    _ = w32.ClientToScreen(hwnd, &tl);
    _ = w32.ClientToScreen(hwnd, &br);
    const vx = w32.GetSystemMetrics(w32.SM_XVIRTUALSCREEN);
    const vy = w32.GetSystemMetrics(w32.SM_YVIRTUALSCREEN);
    const screen = Rect{
        .left = vx,
        .top = vy,
        .right = vx + w32.GetSystemMetrics(w32.SM_CXVIRTUALSCREEN),
        .bottom = vy + w32.GetSystemMetrics(w32.SM_CYVIRTUALSCREEN),
    };
    const target = (Rect{ .left = tl.x, .top = tl.y, .right = br.x, .bottom = br.y }).intersect(screen);
    if (target.empty()) return .covered;

    // Every window above this one in z-order that is certainly opaque.
    var covers: [128]Rect = undefined;
    var n: usize = 0;
    var h = w32.GetWindow(hwnd, w32.GW_HWNDPREV);
    while (h) |above| : (h = w32.GetWindow(above, w32.GW_HWNDPREV)) {
        if (n == covers.len) return .visible;
        if (w32.IsWindowVisible(above) == 0) continue;
        if (w32.IsIconic(above) != 0) continue;
        if (w32.GetWindow(above, w32.GW_OWNER) == hwnd) continue;
        const ex: u32 = @bitCast(w32.GetWindowLongW(above, w32.GWL_EXSTYLE));
        if (ex & (w32.WS_EX_LAYERED | w32.WS_EX_TRANSPARENT) != 0) continue;
        if (cloaked(above)) continue;
        var wr: w32.RECT = undefined;
        if (w32.GetWindowRect(above, &wr) == 0) continue;
        const above_rect = Rect{ .left = wr.left, .top = wr.top, .right = wr.right, .bottom = wr.bottom };
        if (above_rect.intersect(target).empty()) continue;
        covers[n] = above_rect;
        n += 1;
    }
    return if (fullyCovered(target, covers[0..n])) .covered else .visible;
}

fn cloaked(hwnd: w32.HWND) bool {
    var v: u32 = 0;
    if (w32.DwmGetWindowAttribute(hwnd, w32.DWMWA_CLOAKED, &v, @sizeOf(u32)) != 0) return false;
    return v != 0;
}

const testing = std.testing;

fn r(l: i32, t: i32, rt: i32, b: i32) Rect {
    return .{ .left = l, .top = t, .right = rt, .bottom = b };
}

test "occlusion: nothing above is not covered" {
    try testing.expect(!fullyCovered(r(0, 0, 100, 100), &.{}));
}

test "occlusion: one bigger window covers it" {
    try testing.expect(fullyCovered(r(10, 10, 90, 90), &.{r(0, 0, 100, 100)}));
}

test "occlusion: a sliver left uncovered keeps it visible" {
    try testing.expect(!fullyCovered(r(0, 0, 100, 100), &.{r(0, 0, 100, 99)}));
    try testing.expect(!fullyCovered(r(0, 0, 100, 100), &.{r(1, 0, 100, 100)}));
}

test "occlusion: two halves together cover it" {
    try testing.expect(fullyCovered(r(0, 0, 100, 100), &.{ r(-5, -5, 50, 105), r(50, -5, 105, 105) }));
}

test "occlusion: a window with a hole in the cover is visible" {
    // Four windows framing a 10x10 hole in the middle.
    const frame = [_]Rect{
        r(0, 0, 100, 45), r(0, 55, 100, 100), r(0, 45, 45, 55), r(55, 45, 100, 55),
    };
    try testing.expect(!fullyCovered(r(0, 0, 100, 100), &frame));
    // Plug the hole.
    const plugged = frame ++ [_]Rect{r(44, 44, 56, 56)};
    try testing.expect(fullyCovered(r(0, 0, 100, 100), &plugged));
}

test "occlusion: an empty target is covered, empty covers are ignored" {
    try testing.expect(fullyCovered(r(5, 5, 5, 50), &.{}));
    try testing.expect(!fullyCovered(r(0, 0, 10, 10), &.{r(3, 3, 3, 3)}));
}

test "occlusion: too fragmented to track reads as visible" {
    // A comb of thin covers splits the remainder past the piece cap.
    var covers: [80]Rect = undefined;
    for (&covers, 0..) |*c, i| {
        const x: i32 = @intCast(i * 4);
        c.* = r(x, 0, x + 2, 100);
    }
    try testing.expect(!fullyCovered(r(0, 0, 320, 100), &covers));
}
