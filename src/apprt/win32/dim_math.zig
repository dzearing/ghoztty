//! Pure logic for the unfocused-split dim overlay (T74). No OS imports so
//! these unit tests run in every app-runtime lane (the hero_math.zig
//! pattern). The windowing half lives in DimOverlay.zig.

const std = @import("std");
const testing = std.testing;

/// The overlay's layered-window alpha for a given `unfocused-split-opacity`.
/// Mac parity (Ghostty.Config.swift `unfocusedSplitOpacity`): the dim
/// rectangle is drawn at 1 - opacity, so opacity 1 disables dimming
/// entirely (alpha 0) and the config-clamped minimum 0.15 gives the
/// strongest allowed dim.
pub fn overlayAlpha(opacity: f64) u8 {
    const clamped = std.math.clamp(opacity, 0.0, 1.0);
    return @intFromFloat(@round((1.0 - clamped) * 255.0));
}

/// Whether one pane of a tab should be dimmed right now. Mirrors the Mac
/// condition (SurfaceView.swift: `isSplit && !isFocusedSurface`) plus the
/// win32 layout states where the pane grid isn't showing normally: a
/// zoomed pane covers its siblings and hero mode has its own hardcoded
/// thumbnail dimming.
pub const DimState = struct {
    /// overlayAlpha() of the current config.
    alpha: u8,
    /// The pane's tab is the window's active tab.
    active_tab: bool,
    /// The tab has more than one pane.
    is_split: bool,
    /// The tab has a zoomed pane.
    zoomed: bool,
    /// The tab is in hero mode.
    hero: bool,
    /// This pane is the tab's active (last-focused) pane.
    focused_pane: bool,
    /// This pane is a viewer (markdown, HTML, code, diff, website, image).
    /// Viewers never dim (T1809, user directive 2026-10-10), which is also
    /// what Mac does: its viewer panes never had the overlay. T380 had added
    /// one here, and a click into the web content does not always move the
    /// tab's active pane, so the dim could strand on a pane being used.
    viewer: bool,
};

pub fn shouldDim(state: DimState) bool {
    return state.alpha > 0 and state.active_tab and state.is_split and
        !state.zoomed and !state.hero and !state.focused_pane and !state.viewer;
}

/// A screen-space placement of the overlay, in the units `SetWindowPos`
/// takes. Kept OS-free so the reposition decision below is testable in every
/// lane.
pub const Placement = struct {
    left: i32,
    top: i32,
    width: i32,
    height: i32,

    pub fn eql(a: Placement, b: Placement) bool {
        return a.left == b.left and a.top == b.top and
            a.width == b.width and a.height == b.height;
    }
};

/// Everything `DimOverlay.show` knows when it is deciding whether to touch
/// the window at all.
pub const RepositionState = struct {
    /// The overlay is currently on screen at `Placement` last applied.
    shown: bool,
    /// The owner's rect moved or resized since the last applied placement.
    placement_changed: bool,
    /// `SetLayeredWindowAttributes` was just called with a new alpha.
    alpha_changed: bool,
    /// The fill brush was just recreated for a new color.
    color_changed: bool,
};

/// Whether `show()` must issue a `SetWindowPos`/z-order pass, or can return
/// having done nothing (T1295).
///
/// `show()` is called from every layout, focus, move, activate and config
/// event, and it USED to reposition unconditionally — a `SetWindowPos` with
/// `SWP_SHOWWINDOW` on an already-visible layered popup that had not moved.
/// On a composited desktop that is free and invisible. In a Remote Desktop
/// session the layered blend is not reliably idempotent, so every redundant
/// re-blend is another wash of `unfocused-split-fill` over pixels that
/// already carry one — which is what "the white kept getting dimmer, and
/// closing the pane fixed it" looks like from the outside.
pub fn needsReposition(state: RepositionState) bool {
    return !state.shown or state.placement_changed or
        state.alpha_changed or state.color_changed;
}

/// A glass pane's wash is the desk itself (T2086): Mac fades an unfocused
/// glass terminal whole, so what shows through it is the desk under the pane,
/// never a background-coloured sheet - that made the unfocused pane the MORE
/// opaque one. Copy the `w` x `h` slice of the `dw` x `dh` desk whose top-left
/// is (`ox`, `oy`) into `out`; a pixel off the desk takes the nearest edge
/// pixel, so a pane mid-drag past the desk's edge never shows a seam.
pub fn cropWash(out: []u32, w: usize, h: usize, desk: []const u32, dw: usize, dh: usize, ox: i32, oy: i32) void {
    std.debug.assert(out.len >= w * h);
    if (dw == 0 or dh == 0 or desk.len < dw * dh) {
        @memset(out[0 .. w * h], 0);
        return;
    }
    const max_x: i32 = @intCast(dw - 1);
    const max_y: i32 = @intCast(dh - 1);
    for (0..h) |row| {
        const sy: usize = @intCast(std.math.clamp(oy + @as(i32, @intCast(row)), 0, max_y));
        const src = desk[sy * dw ..][0..dw];
        const dst = out[row * w ..][0..w];
        for (dst, 0..) |*p, col| {
            const sx: usize = @intCast(std.math.clamp(ox + @as(i32, @intCast(col)), 0, max_x));
            p.* = src[sx] & 0x00FF_FFFF;
        }
    }
}

test "T2086: cropWash is the desk under the pane, edge-clamped past the desk" {
    var desk: [4 * 3]u32 = undefined;
    for (&desk, 0..) |*p, i| p.* = 0xFF00_0000 | @as(u32, @intCast(i));
    var out: [2 * 2]u32 = undefined;
    cropWash(&out, 2, 2, &desk, 4, 3, 1, 1);
    // The coverage byte is dropped: a layered wash takes its alpha uniformly.
    try testing.expectEqualSlices(u32, &.{ 5, 6, 9, 10 }, &out);
    // Off the top-left and the bottom-right: the nearest edge pixel.
    cropWash(&out, 2, 2, &desk, 4, 3, -1, -1);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, &out);
    cropWash(&out, 2, 2, &desk, 4, 3, 3, 2);
    try testing.expectEqualSlices(u32, &.{ 11, 11, 11, 11 }, &out);
    // No desk: black rather than a read past the slice.
    cropWash(&out, 2, 2, &desk, 0, 0, 0, 0);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, &out);
}

test "overlayAlpha: opacity 1 disables dimming" {
    try testing.expectEqual(@as(u8, 0), overlayAlpha(1.0));
}

test "overlayAlpha: default 0.7 maps to 77" {
    // (1 - 0.7) * 255 = 76.5, rounds to 77 (Mac draws at 0.3 opacity).
    try testing.expectEqual(@as(u8, 77), overlayAlpha(0.7));
}

test "overlayAlpha: config minimum 0.15 maps to 217" {
    try testing.expectEqual(@as(u8, 217), overlayAlpha(0.15));
}

test "overlayAlpha: half" {
    try testing.expectEqual(@as(u8, 128), overlayAlpha(0.5));
}

test "overlayAlpha: out-of-range values are clamped" {
    try testing.expectEqual(@as(u8, 255), overlayAlpha(-1.0));
    try testing.expectEqual(@as(u8, 0), overlayAlpha(2.0));
}

test "shouldDim: unfocused pane of a split active tab dims" {
    try testing.expect(shouldDim(.{
        .alpha = 77,
        .active_tab = true,
        .is_split = true,
        .zoomed = false,
        .hero = false,
        .focused_pane = false,
        .viewer = false,
    }));
}

test "shouldDim: focused pane never dims" {
    try testing.expect(!shouldDim(.{
        .alpha = 77,
        .active_tab = true,
        .is_split = true,
        .zoomed = false,
        .hero = false,
        .focused_pane = true,
        .viewer = false,
    }));
}

test "shouldDim: single pane never dims" {
    try testing.expect(!shouldDim(.{
        .alpha = 77,
        .active_tab = true,
        .is_split = false,
        .zoomed = false,
        .hero = false,
        .focused_pane = false,
        .viewer = false,
    }));
}

test "shouldDim: alpha 0 (opacity 1) disables dimming" {
    try testing.expect(!shouldDim(.{
        .alpha = 0,
        .active_tab = true,
        .is_split = true,
        .zoomed = false,
        .hero = false,
        .focused_pane = false,
        .viewer = false,
    }));
}

test "shouldDim: inactive tab, zoom, and hero suppress dimming" {
    const base: DimState = .{
        .alpha = 77,
        .active_tab = true,
        .is_split = true,
        .zoomed = false,
        .hero = false,
        .focused_pane = false,
        .viewer = false,
    };
    var s = base;
    s.active_tab = false;
    try testing.expect(!shouldDim(s));
    s = base;
    s.zoomed = true;
    try testing.expect(!shouldDim(s));
    s = base;
    s.hero = true;
    try testing.expect(!shouldDim(s));
}

test "shouldDim: a viewer pane never dims, in any state (T1809)" {
    // Every combination of the other inputs, including the one that dims a
    // terminal: the viewer flag alone must keep the overlay off.
    for (0..32) |bits| {
        const s: DimState = .{
            .alpha = if (bits & 1 != 0) 77 else 0,
            .active_tab = bits & 2 != 0,
            .is_split = bits & 4 != 0,
            .zoomed = bits & 8 != 0,
            .hero = false,
            .focused_pane = bits & 16 != 0,
            .viewer = true,
        };
        try testing.expect(!shouldDim(s));
    }
    // Positive control: the same dimming state with a terminal does dim.
    try testing.expect(shouldDim(.{
        .alpha = 77,
        .active_tab = true,
        .is_split = true,
        .zoomed = false,
        .hero = false,
        .focused_pane = false,
        .viewer = false,
    }));
}

test "needsReposition: a steady, already-shown overlay does nothing" {
    try testing.expect(!needsReposition(.{
        .shown = true,
        .placement_changed = false,
        .alpha_changed = false,
        .color_changed = false,
    }));
}

test "needsReposition: the first show always repositions" {
    try testing.expect(needsReposition(.{
        .shown = false,
        .placement_changed = false,
        .alpha_changed = false,
        .color_changed = false,
    }));
}

test "needsReposition: any one change is enough" {
    const base: RepositionState = .{
        .shown = true,
        .placement_changed = false,
        .alpha_changed = false,
        .color_changed = false,
    };
    var s = base;
    s.placement_changed = true;
    try testing.expect(needsReposition(s));
    s = base;
    s.alpha_changed = true;
    try testing.expect(needsReposition(s));
    s = base;
    s.color_changed = true;
    try testing.expect(needsReposition(s));
}

test "Placement.eql: identical placements compare equal" {
    const a: Placement = .{ .left = 10, .top = 20, .width = 300, .height = 400 };
    try testing.expect(Placement.eql(a, a));
}

test "Placement.eql: a move and a resize are both changes" {
    const a: Placement = .{ .left = 10, .top = 20, .width = 300, .height = 400 };
    var b = a;
    b.left = 11;
    try testing.expect(!Placement.eql(a, b));
    b = a;
    b.height = 401;
    try testing.expect(!Placement.eql(a, b));
}
