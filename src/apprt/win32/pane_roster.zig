//! When another window's all-windows pane sidebar re-reads its roster
//! (T2347, Mac `PaneRoster` + `PaneSidebarState.isLive`).
//!
//! Mac redraws a background window's list only when that window next becomes
//! key. Here the flood is the coalesced title/activity refresh (T1935): a
//! dozen spinner titles re-read every window's list per tick. That one waits
//! for a background window to be activated. A layout, focus or close
//! refresh still re-reads every list at once, because a list's rows point at
//! panes and windows that paint, hover and sheens read through: a list that
//! waited across a pane being closed could outlive the pane it names.

const std = @import("std");

/// Which lists a refresh of the other windows reaches.
pub const Policy = enum {
    /// Every list now: something may have left the roster (layout, focus,
    /// a window closing, a workspace hand-off).
    every,
    /// Titles and activity only: the window in use now, the rest on
    /// activation.
    live,
};

pub const Action = enum {
    /// Re-read now.
    refresh,
    /// Background: mark stale, and say so once.
    defer_first,
    /// Background and already stale: nothing.
    already_stale,
};

/// What another window's change does to one window's all-windows list.
pub fn scopeAction(policy: Policy, activated: bool, stale: bool) Action {
    if (policy == .every or activated) return .refresh;
    return if (stale) .already_stale else .defer_first;
}

test "T2347: a title/activity refresh reaches the window in use at once" {
    try std.testing.expectEqual(Action.refresh, scopeAction(.live, true, false));
    try std.testing.expectEqual(Action.refresh, scopeAction(.live, true, true));
}

test "T2347: a background list defers a title/activity refresh once, then holds still" {
    try std.testing.expectEqual(Action.defer_first, scopeAction(.live, false, false));
    try std.testing.expectEqual(Action.already_stale, scopeAction(.live, false, true));
}

test "T2347: a layout/focus/close refresh reaches every list, background or stale" {
    try std.testing.expectEqual(Action.refresh, scopeAction(.every, false, false));
    try std.testing.expectEqual(Action.refresh, scopeAction(.every, false, true));
    try std.testing.expectEqual(Action.refresh, scopeAction(.every, true, false));
}
