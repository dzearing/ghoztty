//! Which composition mode a window should be in for `background-opacity`
//! (T1789).
//!
//! Mac's `syncAppearance` rule: translucent when the config asks for it AND
//! the user has not toggled this window opaque (`isBackgroundOpaque`). The
//! toggle is its own flag rather than being read back off the window's current
//! mode, because a config reload has to be able to change the answer in both
//! directions without losing it: a window toggled opaque stays opaque across
//! 0.6 -> 0.8, and a window that was opaque only because the config was 1.0
//! turns translucent at 0.6.
//!
//! Pure: `Window.syncTranslucency` applies the answer, so the rule is tested
//! in the `none` lane.

const std = @import("std");

pub fn wantsTranslucent(opacity: f64, toggled_opaque: bool) bool {
    return opacity < 1.0 and !toggled_opaque;
}

test "wantsTranslucent follows the config until the user toggles" {
    try std.testing.expect(wantsTranslucent(0.6, false));
    try std.testing.expect(wantsTranslucent(0.0, false));
    try std.testing.expect(!wantsTranslucent(1.0, false));
}

test "a toggle to opaque wins over a translucent config, never the reverse" {
    try std.testing.expect(!wantsTranslucent(0.6, true));
    // An opaque config is opaque whatever the toggle says, so a toggle left
    // set at 1.0 cannot make a window translucent.
    try std.testing.expect(!wantsTranslucent(1.0, true));
}
