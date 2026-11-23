//! The one constructor for a product tooltip control (T1866): a comctl32
//! `TOOLTIPS_CLASS` popup, topmost, never activated, and UNOWNED.
//!
//! Why unowned. Every tooltip in this app is `WS_EX_TOPMOST`, which is how
//! comctl32 keeps a tip above whatever it explains. Created OWNED by a window
//! that is in the background, such a tip dragged its owner up the z-order:
//! T1842 measured the pane sidebar's tip, created on the first layout of a
//! window opened by `+new-remote-window`, lifting that window over Ghoztty's
//! frontmost one (`cli-focus-policy.ps1` arm R: z=6 over z=9, both runs) -
//! and gone the moment the tip was created unowned. It does not happen on
//! every creation (an isolated owned topmost tip measured no lift, and a viewer
//! split into a background window did not lift either), which is exactly why
//! the rule is structural rather than per site: no product tooltip is owned,
//! and arm T of `cli-focus-policy.ps1` reads every tooltip the run created
//! and fails on any that has an owner.
//!
//! What ownership was not buying. The tools name their window in
//! `TOOLINFOW.hwnd` - that is what `TTF_SUBCLASS` subclasses and what a
//! `TTN_*` notification goes to - so the relay and the text do not need the
//! control to be owned. Topmost keeps the tip above its window without the
//! owner pin. The one thing ownership did do is destroy the tip with its
//! owner, so EVERY caller destroys its control explicitly; the owners that
//! did not (`Window`'s tab tip) were given a teardown in the same change.

const std = @import("std");
const w32 = @import("win32.zig");

/// The extended style every product tooltip is created with: above everything
/// it explains, out of the taskbar and Alt-Tab, and never activated.
pub const ex_style: u32 = w32.WS_EX_TOPMOST | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE;

/// The window style: comctl32 shows the tip even while the app is inactive
/// (a background window's chrome explains itself on hover like a foreground
/// one), and an `&` in a label is a character, not a mnemonic.
pub const style: u32 = w32.WS_POPUP | w32.TTS_ALWAYSTIP | w32.TTS_NOPREFIX;

/// Create the control, after registering the common-controls class it needs.
/// Null when the window could not be made; callers treat that as "no tip".
pub fn create(hinstance: ?w32.HINSTANCE) ?w32.HWND {
    var icc = w32.INITCOMMONCONTROLSEX{
        .dwSize = @sizeOf(w32.INITCOMMONCONTROLSEX),
        .dwICC = w32.ICC_TAB_CLASSES,
    };
    _ = w32.InitCommonControlsEx(&icc);

    return w32.CreateWindowExW(
        ex_style,
        w32.TOOLTIPS_CLASS,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        style,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        // UNOWNED, on purpose - the whole point of this file.
        null,
        null,
        hinstance,
        null,
    );
}

test "a product tooltip is topmost, unactivatable and unowned" {
    const builtin = @import("builtin");
    try std.testing.expect(ex_style & w32.WS_EX_TOPMOST != 0);
    try std.testing.expect(ex_style & w32.WS_EX_NOACTIVATE != 0);
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const tip = create(null) orelse return error.SkipZigTest;
    defer _ = w32.DestroyWindow(tip);
    try std.testing.expectEqual(@as(?w32.HWND, null), w32.GetWindow(tip, w32.GW_OWNER));
}
