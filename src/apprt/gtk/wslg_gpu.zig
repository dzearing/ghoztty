//! Picking WSLg's GPU for the GTK app's own renderer (T3350).
//!
//! Under WSL2/WSLg Mesa reaches the host GPU through the `d3d12` gallium
//! driver (`/dev/dxg`, libraries in `/usr/lib/wsl/lib`), but it does not pick
//! it on its own: measured 2026-11-21, both `glxinfo -B` and the app report
//! `llvmpipe` (software) until `GALLIUM_DRIVER=d3d12` is set, and with it the
//! app loads OpenGL 4.6 on the real card. So the app sets the override itself,
//! before GTK brings up GL, when nothing says otherwise:
//!
//! - only when `/dev/dxg` exists (it is WSL's GPU paravirtualisation device;
//!   no other Linux has it, so a desktop Linux box is never touched);
//! - never over a `GALLIUM_DRIVER` or `MESA_LOADER_DRIVER_OVERRIDE` the user
//!   set - even an empty one, which is still a choice;
//! - never when `LIBGL_ALWAYS_SOFTWARE` asks for software rendering (Mesa's
//!   true spellings: 1/true/y/yes).
//!
//! The override is the app's, not the user's, so it must not reach anything
//! the app spawns: once GDK's GL is up (Mesa reads the variable when the EGL
//! display initializes, and every later context reuses that display) it is
//! removed again. That also keeps it from WebKit's sandboxed web processes,
//! which cannot open `/dev/dxg` and abort if they inherit it (T3410; see
//! `Viewer.prepareWebProcessEnv`).
//!
//! The decision is pure, so it runs in the none lane on every seat;
//! `class/application.zig` is the half that reads the environment and sets it.
const std = @import("std");

pub const env_name = "GALLIUM_DRIVER";
pub const driver = "d3d12";
pub const device_path = "/dev/dxg";

/// What the decision reads.
pub const Inputs = struct {
    /// `/dev/dxg` exists.
    dxg: bool,
    /// `$GALLIUM_DRIVER`, null when unset.
    gallium_driver: ?[]const u8,
    /// `$MESA_LOADER_DRIVER_OVERRIDE`, null when unset.
    loader_override: ?[]const u8,
    /// `$LIBGL_ALWAYS_SOFTWARE`, null when unset.
    always_software: ?[]const u8,
};

pub const Decision = enum {
    /// Set `GALLIUM_DRIVER=d3d12` before GTK initializes GL.
    set,
    /// Not WSL (no `/dev/dxg`): Mesa's own choice is the right one.
    not_wsl,
    /// The user already chose a driver (or software); leave it.
    user_choice,
};

pub fn decide(in: Inputs) Decision {
    if (!in.dxg) return .not_wsl;
    if (in.gallium_driver != null) return .user_choice;
    if (in.loader_override != null) return .user_choice;
    if (in.always_software) |v| if (mesaTrue(v)) return .user_choice;
    return .set;
}

/// Once GDK's display is open, before its GL comes up (T3783): d3d12 cannot
/// present to an X11 window under WSLg - Mesa needs MIT-SHM for it and that
/// fails across the WSLg boundary, so every frame is dropped and the window
/// is see-through. Software GL draws.
pub const OnDisplay = enum {
    /// Wayland (or not WSL): keep whatever was chosen.
    keep,
    /// X11 with the d3d12 the APP set: take it back before GL comes up, so
    /// Mesa picks software rendering, and warn once.
    drop_for_x11,
    /// X11 with a d3d12 the USER set: it is their choice, but say once,
    /// loudly, that it will draw nothing.
    warn_user_d3d12,
};

pub fn onDisplay(in: struct {
    dxg: bool,
    x11: bool,
    /// The app set `GALLIUM_DRIVER` itself (`decide` returned `.set`).
    app_set: bool,
    /// `$GALLIUM_DRIVER` now, null when unset.
    gallium_driver: ?[]const u8,
}) OnDisplay {
    if (!in.dxg or !in.x11) return .keep;
    if (in.app_set) return .drop_for_x11;
    if (in.gallium_driver) |g| if (std.mem.eql(u8, g, driver)) return .warn_user_d3d12;
    return .keep;
}

test "wslg gpu on display: wayland and non-WSL keep the choice" {
    try std.testing.expectEqual(OnDisplay.keep, onDisplay(.{ .dxg = true, .x11 = false, .app_set = true, .gallium_driver = driver }));
    try std.testing.expectEqual(OnDisplay.keep, onDisplay(.{ .dxg = false, .x11 = true, .app_set = false, .gallium_driver = driver }));
}

test "wslg gpu on display: X11 drops the app's d3d12, warns over the user's, ignores other drivers" {
    try std.testing.expectEqual(OnDisplay.drop_for_x11, onDisplay(.{ .dxg = true, .x11 = true, .app_set = true, .gallium_driver = driver }));
    try std.testing.expectEqual(OnDisplay.warn_user_d3d12, onDisplay(.{ .dxg = true, .x11 = true, .app_set = false, .gallium_driver = driver }));
    try std.testing.expectEqual(OnDisplay.keep, onDisplay(.{ .dxg = true, .x11 = true, .app_set = false, .gallium_driver = "llvmpipe" }));
    try std.testing.expectEqual(OnDisplay.keep, onDisplay(.{ .dxg = true, .x11 = true, .app_set = false, .gallium_driver = null }));
}

/// Mesa's `env_var_as_boolean` true spellings; anything else is false.
fn mesaTrue(v: []const u8) bool {
    inline for (.{ "1", "true", "y", "yes" }) |t| {
        if (std.ascii.eqlIgnoreCase(v, t)) return true;
    }
    return false;
}

test "wslg gpu: sets d3d12 on WSL when nothing chose a driver" {
    try std.testing.expectEqual(Decision.set, decide(.{ .dxg = true, .gallium_driver = null, .loader_override = null, .always_software = null }));
}

test "wslg gpu: never touches a box without /dev/dxg" {
    try std.testing.expectEqual(Decision.not_wsl, decide(.{ .dxg = false, .gallium_driver = null, .loader_override = null, .always_software = null }));
}

test "wslg gpu: a user's GALLIUM_DRIVER wins, even an empty one" {
    try std.testing.expectEqual(Decision.user_choice, decide(.{ .dxg = true, .gallium_driver = "llvmpipe", .loader_override = null, .always_software = null }));
    try std.testing.expectEqual(Decision.user_choice, decide(.{ .dxg = true, .gallium_driver = "", .loader_override = null, .always_software = null }));
}

test "wslg gpu: a user's MESA_LOADER_DRIVER_OVERRIDE wins" {
    try std.testing.expectEqual(Decision.user_choice, decide(.{ .dxg = true, .gallium_driver = null, .loader_override = "zink", .always_software = null }));
}

test "wslg gpu: LIBGL_ALWAYS_SOFTWARE is honoured, its off spellings are not a request" {
    try std.testing.expectEqual(Decision.user_choice, decide(.{ .dxg = true, .gallium_driver = null, .loader_override = null, .always_software = "1" }));
    try std.testing.expectEqual(Decision.user_choice, decide(.{ .dxg = true, .gallium_driver = null, .loader_override = null, .always_software = "true" }));
    try std.testing.expectEqual(Decision.user_choice, decide(.{ .dxg = true, .gallium_driver = null, .loader_override = null, .always_software = "Yes" }));
    try std.testing.expectEqual(Decision.set, decide(.{ .dxg = true, .gallium_driver = null, .loader_override = null, .always_software = "" }));
    try std.testing.expectEqual(Decision.set, decide(.{ .dxg = true, .gallium_driver = null, .loader_override = null, .always_software = "0" }));
    try std.testing.expectEqual(Decision.set, decide(.{ .dxg = true, .gallium_driver = null, .loader_override = null, .always_software = "FALSE" }));
}
