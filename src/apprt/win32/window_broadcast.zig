//! What a top-level window owes its panes when Windows tells IT something
//! (T1579).
//!
//! Two messages carry news every pane needs and only the top-level window is
//! ever sent: `WM_DPICHANGED` (the window crossed onto a monitor with a
//! different scale) and the `WM_SETTINGCHANGE` broadcast (among other things,
//! the "automatically hide scroll bars" accessibility setting that picks the
//! scrollbar mode). A terminal pane is a `WS_CHILD`, so it hears neither. Until
//! T1579 the only receivers in a pane's orbit were its search and palette
//! POPUPS, which are top-level — so a monitor move rescaled the terminal if and
//! only if one of those happened to be open, and otherwise left it rendering
//! at the old monitor's scale.
//!
//! The window therefore forwards both, to every pane in every tab (a hidden
//! tab is still on the new monitor when it is next shown). This file is the
//! rule for what each pane kind is owed; `Window.forwardToPanes` walks the
//! trees and dispatches on it.

const std = @import("std");

/// The top-level message being forwarded.
pub const Event = enum { dpi_changed, setting_changed };

/// What kind of pane a leaf holds.
pub const PaneKind = enum { terminal, viewer };

/// What a pane must do for an event.
pub const Action = struct {
    /// Adopt the new scale: a terminal re-sizes its font and popups, a viewer
    /// pushes a new rasterization scale.
    rescale: bool = false,
    /// Re-read the scrollbar mode, re-flowing the grid if it moved.
    reread_scrollbar: bool = false,

    pub fn any(self: Action) bool {
        return self.rescale or self.reread_scrollbar;
    }
};

pub fn actionFor(event: Event, kind: PaneKind) Action {
    return switch (event) {
        .dpi_changed => .{ .rescale = true },
        .setting_changed => switch (kind) {
            .terminal => .{ .reread_scrollbar = true },
            // A viewer has no Win32 scrollbar of ours - WebView2 draws its own
            // and follows the setting itself.
            .viewer => .{},
        },
    };
}

/// The new DPI a `WM_DPICHANGED` carries. X and Y are always equal on Windows
/// and the docs say to read LOWORD; a zero is not a DPI, so it is refused
/// rather than turned into a scale of 0.
pub fn dpiFromWparam(wparam: usize) ?u32 {
    const dpi: u32 = @intCast(wparam & 0xFFFF);
    if (dpi == 0) return null;
    return dpi;
}

pub fn scaleFromDpi(dpi: u32) f32 {
    return @as(f32, @floatFromInt(dpi)) / 96.0;
}

test "a DPI change rescales every kind of pane" {
    try std.testing.expect(actionFor(.dpi_changed, .terminal).rescale);
    try std.testing.expect(actionFor(.dpi_changed, .viewer).rescale);
    try std.testing.expect(!actionFor(.dpi_changed, .terminal).reread_scrollbar);
}

test "a setting change re-reads the terminal's scrollbar and leaves a viewer alone" {
    const term = actionFor(.setting_changed, .terminal);
    try std.testing.expect(term.reread_scrollbar);
    try std.testing.expect(!term.rescale);
    try std.testing.expect(!actionFor(.setting_changed, .viewer).any());
}

test "every event owes the terminal something" {
    // The defect this file exists for: a terminal pane that no top-level
    // message ever reaches. If an event is added and forgotten here, this
    // fails instead of the pane going quietly stale.
    inline for (std.meta.fields(Event)) |f| {
        try std.testing.expect(actionFor(@enumFromInt(f.value), .terminal).any());
    }
}

test "the DPI is LOWORD of wparam and zero is refused" {
    try std.testing.expectEqual(@as(?u32, 144), dpiFromWparam(0x0090_0090));
    try std.testing.expectEqual(@as(?u32, 120), dpiFromWparam(0x0078_0078));
    try std.testing.expectEqual(@as(?u32, null), dpiFromWparam(0));
    try std.testing.expectEqual(@as(?u32, null), dpiFromWparam(0x0090_0000));
}

test "scale is DPI over 96" {
    try std.testing.expectEqual(@as(f32, 1.0), scaleFromDpi(96));
    try std.testing.expectEqual(@as(f32, 1.25), scaleFromDpi(120));
    try std.testing.expectEqual(@as(f32, 1.5), scaleFromDpi(144));
    try std.testing.expectEqual(@as(f32, 2.0), scaleFromDpi(192));
}
