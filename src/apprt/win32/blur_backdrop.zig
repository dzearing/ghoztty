//! Which DWM mechanism carries `background-blur` on a window (T1788).
//!
//! Mac blurs whatever is behind a translucent window
//! (`CGSSetWindowBackgroundBlurRadius`). On Windows 11 22H2+ the documented
//! counterpart is the system backdrop attribute set to the TRANSIENT-WINDOW
//! material (acrylic), which T1016 measured blurring other windows as well as
//! the wallpaper. Mica (the MAIN-WINDOW material) is NOT a translation: it
//! samples only the wallpaper, so a window behind the terminal vanishes rather
//! than blurring.
//!
//! Below 22H2 the attribute does not exist and `DwmSetWindowAttribute` fails,
//! so the older accent blur-behind (undocumented `SetWindowCompositionAttribute`)
//! stays as the fallback. The two are never on together: the accent draws its
//! own blur, and stacking it under acrylic would double the effect.
//!
//! Pure: the Win32 calls are made by `Window.applyBackgroundBlur`, which asks
//! this module what to do with the answer it got back. Tested in the `none`
//! lane.

const std = @import("std");

/// `DWMWA_SYSTEMBACKDROP_TYPE` values (`DWM_SYSTEMBACKDROP_TYPE`).
pub const Backdrop = enum(u32) {
    /// Let DWM decide - the default, and what "no backdrop requested" restores.
    auto = 0,
    none = 1,
    /// Mica. Wallpaper only - not background-blur (see the module doc).
    main_window = 2,
    /// Acrylic. Blurs everything behind the window.
    transient_window = 3,
};

/// The backdrop to ask DWM for.
pub fn requested(enabled: bool) Backdrop {
    return if (enabled) .transient_window else .auto;
}

/// What carried the blur, once the backdrop request was answered.
pub const Mechanism = enum {
    /// Blur is off.
    off,
    /// The documented Windows 11 acrylic backdrop.
    acrylic,
    /// The accent blur-behind, because this Windows has no backdrop attribute.
    accent,

    /// Whether the accent policy should be ENABLED for this outcome.
    pub fn accentOn(self: Mechanism) bool {
        return self == .accent;
    }
};

/// Decide from the HRESULT of the backdrop request. A failed request while
/// DISABLING needs no fallback: there is nothing to turn on, and the accent is
/// switched off either way.
pub fn resolve(enabled: bool, backdrop_hr: i32) Mechanism {
    if (!enabled) return .off;
    return if (backdrop_hr >= 0) .acrylic else .accent;
}

test "blur_backdrop: enabling asks for acrylic, never Mica" {
    try std.testing.expectEqual(Backdrop.transient_window, requested(true));
    try std.testing.expect(requested(true) != .main_window);
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(requested(true)));
}

test "blur_backdrop: disabling restores DWM's default" {
    try std.testing.expectEqual(Backdrop.auto, requested(false));
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(requested(false)));
}

test "blur_backdrop: an accepted backdrop is acrylic with the accent off" {
    const m = resolve(true, 0);
    try std.testing.expectEqual(Mechanism.acrylic, m);
    try std.testing.expect(!m.accentOn());
}

test "blur_backdrop: a refused backdrop falls back to the accent" {
    // E_INVALIDARG, what DWM answers for an attribute it does not know.
    const m = resolve(true, @bitCast(@as(u32, 0x80070057)));
    try std.testing.expectEqual(Mechanism.accent, m);
    try std.testing.expect(m.accentOn());
}

test "blur_backdrop: off is off whatever DWM answered" {
    try std.testing.expectEqual(Mechanism.off, resolve(false, 0));
    try std.testing.expectEqual(Mechanism.off, resolve(false, @bitCast(@as(u32, 0x80070057))));
    try std.testing.expect(!resolve(false, -1).accentOn());
}
