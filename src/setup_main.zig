//! Root of `ghoztty-setup.exe` (T2197). The exe itself is
//! `apprt/win32/setup_main.zig`; this shim exists only so the module is rooted
//! at `src/`, because Zig resolves every `@import` path in every reachable file
//! eagerly - including the dialogs' `App.zig`, which `dialog_app.zig` never
//! analyzes in this build but whose own imports reach across `src/`.

const setup = @import("apprt/win32/setup_main.zig");

/// The dialogs this exe shows have no `App` behind them; see
/// `apprt/win32/dialog_app.zig`.
pub const ghoztty_dialog_app_less = true;

pub const main = setup.main;
