//! Can anybody see this GTK window or pane? (T3571, Linux L11i;
//! docs/reference/background-windows.md): the pure half.
//!
//! The rule the Mac set: work that only matters to the eye runs only where
//! someone can see it, and state never pauses. A terminal nobody can see
//! skips building its frames (the shared renderer's `visible` flag, fed by
//! `CoreSurface.occlusionCallback`) and catches up once when it shows; a
//! window nobody can see holds its title and lands it when it shows, or at
//! most every `held_title_interval_ms` meanwhile. Activity (`+set-state`),
//! notifications and banners are untouched - they are state.
//!
//! GTK translation of the Mac's two questions:
//!
//! - **The window can be seen** when it is mapped and its `GdkToplevel`
//!   state is neither MINIMIZED nor SUSPENDED. SUSPENDED (GTK 4.12,
//!   `xdg_toplevel` `suspended` on Wayland) is the compositor saying the
//!   window is fully covered or on another workspace - the Mac's
//!   `WindowCoverage` - and a compositor that never sends it (WSLg's Weston
//!   today) simply leaves a covered window drawing, which errs toward visible
//!   exactly as win32's `occlusion.zig` does. Wayland gives a client no
//!   window list to compute coverage from itself.
//! - **A pane can be seen** when its widget is mapped (a background tab, a
//!   pane hidden behind a stacked row's strip, a parked page are not) and its
//!   window can be seen.
//!
//! No GTK imports: `class/window.zig` and `class/surface.zig` are the GTK half.
const std = @import("std");

/// The `GdkToplevel` state bits that decide whether a window is seen.
pub const Toplevel = struct {
    minimized: bool = false,
    /// GDK_TOPLEVEL_STATE_SUSPENDED: covered, or on another workspace.
    suspended: bool = false,
};

/// Whether a window can be seen.
pub fn windowSeen(mapped: bool, state: Toplevel) bool {
    return mapped and !state.minimized and !state.suspended;
}

/// Whether a pane can be seen: its widget is mapped and its window is seen.
/// A pane in no window (between a detach and its re-attach) is unmapped.
pub fn paneSeen(widget_mapped: bool, window_seen: bool) bool {
    return widget_mapped and window_seen;
}

/// The core call a pane owes when its seen state is recomputed: the new
/// value when it changed, null when it did not. A pane starts seen, which is
/// what the shared renderer assumes until it is told otherwise.
pub fn change(last: bool, now: bool) ?bool {
    return if (last == now) null else now;
}

/// How long a hidden window holds a new title before landing it anyway, so
/// the compositor's window list and accessibility readers are never far
/// behind (the Mac's `hiddenWindowTitleInterval`).
pub const held_title_interval_ms: i64 = 5000;

/// What to do with a window title that just changed.
pub const TitleAction = union(enum) {
    /// Set it on the window now.
    land,
    /// Hold it; land it when the window shows, or after `ms` more.
    hold: i64,
};

/// A window's new title lands at once when the window is seen, when it is
/// the window's first title, or when the last one landed at least
/// `held_title_interval_ms` ago; otherwise it is held until the window shows
/// or that interval has passed since the last landing.
pub fn titleAction(seen: bool, last_landed_ms: ?i64, now_ms: i64) TitleAction {
    if (seen) return .land;
    const last = last_landed_ms orelse return .land;
    const since = now_ms - last;
    if (since >= held_title_interval_ms or since < 0) return .land;
    return .{ .hold = held_title_interval_ms - since };
}

test "T3571: a window is seen only while mapped, not minimized and not suspended" {
    try std.testing.expect(windowSeen(true, .{}));
    try std.testing.expect(!windowSeen(false, .{}));
    try std.testing.expect(!windowSeen(true, .{ .minimized = true }));
    try std.testing.expect(!windowSeen(true, .{ .suspended = true }));
    try std.testing.expect(!windowSeen(true, .{ .minimized = true, .suspended = true }));
}

test "T3571: a pane is seen only while its widget is mapped in a seen window" {
    try std.testing.expect(paneSeen(true, true));
    // A background tab or a pane minimized into a strip.
    try std.testing.expect(!paneSeen(false, true));
    // A pane on screen in a minimized window.
    try std.testing.expect(!paneSeen(true, false));
    try std.testing.expect(!paneSeen(false, false));
}

test "T3571: the core is told only when a pane's seen state changes" {
    try std.testing.expectEqual(@as(?bool, null), change(true, true));
    try std.testing.expectEqual(@as(?bool, null), change(false, false));
    try std.testing.expectEqual(@as(?bool, false), change(true, false));
    try std.testing.expectEqual(@as(?bool, true), change(false, true));
}

test "T3571: a seen window's title lands at once" {
    try std.testing.expectEqual(TitleAction.land, titleAction(true, 1000, 1001));
    try std.testing.expectEqual(TitleAction.land, titleAction(true, null, 0));
}

test "T3571: a hidden window's first title always lands" {
    try std.testing.expectEqual(TitleAction.land, titleAction(false, null, 123));
}

test "T3571: a hidden window holds a title until the interval since the last landing has passed" {
    try std.testing.expectEqual(TitleAction{ .hold = 4000 }, titleAction(false, 10_000, 11_000));
    try std.testing.expectEqual(TitleAction{ .hold = 1 }, titleAction(false, 10_000, 14_999));
    try std.testing.expectEqual(TitleAction.land, titleAction(false, 10_000, 15_000));
    try std.testing.expectEqual(TitleAction.land, titleAction(false, 10_000, 60_000));
}

test "T3571: a clock that went backwards lands rather than holding forever" {
    try std.testing.expectEqual(TitleAction.land, titleAction(false, 10_000, 9_000));
}
