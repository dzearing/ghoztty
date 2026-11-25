//! The `App` the shared dialogs are written against (T2197).
//!
//! `ConfirmDialog` and the files split out of it reach the app for a handful of
//! things: the window-class instance, a theme to paint from, `openUrl` for a
//! link row, an allocator for the release-notes accessory, and the deferred-
//! focus message the T48 fix routes through the run loop. Every one of those is
//! optional already - the app-less paths (`showStandalone`, the updater, the
//! startup-failure box) pass `null` - but the TYPE still named `App.zig`, and
//! naming it drags the whole terminal (config, renderer, fonts, the core app)
//! into any binary that wants the dialog.
//!
//! `Ghoztty-Setup.exe` is that binary: a small front door that runs the MSI and
//! speaks in this same dialog when Windows Installer refuses (T2197). Its root
//! declares `ghoztty_dialog_app_less = true`, and every dialog file imports
//! `App` from here, so in that build the type is `Stub` - a struct no value of
//! which can ever exist, carrying exactly the surface the dialogs name. Every
//! other root (the app, every test lane) gets the real `App.zig`, unchanged.

const std = @import("std");
const root = @import("root");
const w32 = @import("win32.zig");
const system_colors = @import("system_colors.zig");

/// True in a binary whose root opted out of the app (`Ghoztty-Setup.exe`).
pub const app_less: bool = @hasDecl(root, "ghoztty_dialog_app_less") and root.ghoztty_dialog_app_less;

pub const App = if (app_less) Stub else @import("App.zig");

/// The app-less build's stand-in. Never instantiated: an app-less binary has
/// no `App` to pass, so every `?*App` it holds is `null` and every branch that
/// unwraps one is dead at run time. The members exist so those branches still
/// type-check, and the two that ARE reached without an app (the run loop's
/// deferred-focus message, `deferSetFocus`) do what the real ones do.
pub const Stub = struct {
    hinstance: ?w32.HINSTANCE,
    core_app: *const struct { alloc: std.mem.Allocator },
    config: struct {
        background: struct { r: u8, g: u8, b: u8 },
        @"window-theme": system_colors.SystemTheme,
    },

    /// Same id as `App.WM_APP_SETFOCUS`; nothing posts it in an app-less
    /// process, but the modal loop compares against it.
    pub const WM_APP_SETFOCUS: u32 = w32.WM_APP + 5;

    pub fn deferSetFocus(hwnd: w32.HWND) void {
        _ = w32.PostMessageW(hwnd, WM_APP_SETFOCUS, 0, 0);
    }

    pub fn performDeferredFocus(hwnd: w32.HWND) void {
        _ = w32.SetFocus(hwnd);
    }

    pub fn openUrl(self: *Stub, url: []const u8) void {
        _ = self;
        _ = url;
    }
};
