//! Reaching WSLg's Wayland compositor when the runtime dir has no socket
//! (T3783).
//!
//! WSLg runs one Weston for the whole distro; its socket is
//! `/mnt/wslg/runtime-dir/wayland-0`, and WSL links it into the DEFAULT user's
//! `/run/user/<uid>` only. Any other user - root above all, which is how the
//! distro is driven from this box - inherits `WAYLAND_DISPLAY=wayland-0` with
//! no such socket under its `$XDG_RUNTIME_DIR`. GDK then silently falls back
//! to X11 (XWayland `:0`), where Mesa's d3d12 driver cannot present: it needs
//! MIT-SHM, which fails across the WSLg boundary, so every frame is dropped and
//! the window is see-through (user report 2026-11-25).
//!
//! So before GDK opens its display the app checks whether the Wayland socket
//! libwayland is about to try exists, and when it does not and WSLg's does,
//! points `WAYLAND_DISPLAY` at WSLg's socket by absolute path (libwayland
//! accepts an absolute name since 1.15).
//!
//! Why `WAYLAND_DISPLAY` and not `XDG_RUNTIME_DIR`: the runtime dir is where
//! the app's own CLI socket lives (`$XDG_RUNTIME_DIR/ghostty[-debug]-<uid>.sock`,
//! T3335), and every `ghoztty +verb` client resolves it from ITS environment.
//! Moving the server's runtime dir would put the socket somewhere no client
//! looks. `WAYLAND_DISPLAY` is read by nothing but libwayland.
//!
//! The override is the app's, not the user's: once the display is open the
//! original value is put back, so a shell in a pane sees exactly what WSLg
//! gave the app. Never touched when:
//!
//! - WSLg's socket is not there (not WSLg: a desktop Linux box is never
//!   touched);
//! - `WAYLAND_SOCKET` hands the app an already-connected fd;
//! - `GDK_BACKEND` names backends and Wayland is not among them (the user
//!   asked for X11);
//! - the socket libwayland would use already exists (the default user, or a
//!   launcher that already fixed it).
//!
//! The decision is pure, so it runs in the none lane on every seat;
//! `class/application.zig` is the half that reads the environment and sets it.
const std = @import("std");

pub const env_name = "WAYLAND_DISPLAY";
pub const wslg_socket = "/mnt/wslg/runtime-dir/wayland-0";
/// Debug builds only: the path to treat as WSLg's socket. The headless
/// harness points it at its private Weston (or at nothing), so no test can
/// reach the user's WSLg desktop through this fallback.
pub const debug_override_env = "GHOZTTY_DEBUG_WSLG_SOCKET";

pub const Inputs = struct {
    /// `wslg_socket` exists and is a socket.
    wslg_socket: bool,
    /// `$WAYLAND_SOCKET`, null when unset.
    wayland_socket: ?[]const u8,
    /// `$GDK_BACKEND`, null when unset.
    gdk_backend: ?[]const u8,
    /// The socket libwayland would connect to (`socketPath`) exists.
    current_resolves: bool,
};

pub const Decision = enum {
    /// Set `WAYLAND_DISPLAY` to `wslg_socket` until the display is open.
    use_wslg,
    /// Not WSLg (no WSLg socket): libwayland's own choice is the right one.
    not_wslg,
    /// The user chose: a connected fd, or a backend list without Wayland.
    user_choice,
    /// The socket libwayland will try is there; nothing to fix.
    reachable,
};

pub fn decide(in: Inputs) Decision {
    if (!in.wslg_socket) return .not_wslg;
    if (in.wayland_socket != null) return .user_choice;
    if (in.gdk_backend) |b| if (!backendAllowsWayland(b)) return .user_choice;
    if (in.current_resolves) return .reachable;
    return .use_wslg;
}

/// `GDK_BACKEND` is a comma-separated list; `*` means any. An empty value
/// restricts nothing.
fn backendAllowsWayland(list: []const u8) bool {
    if (std.mem.trim(u8, list, " ").len == 0) return true;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (std.mem.eql(u8, name, "wayland") or std.mem.eql(u8, name, "*")) return true;
    }
    return false;
}

/// The path libwayland's `wl_display_connect(NULL)` tries: an absolute
/// `$WAYLAND_DISPLAY` as-is, otherwise `$XDG_RUNTIME_DIR/<name>` with the
/// name defaulting to `wayland-0`. Null when there is no runtime dir to join
/// it to (libwayland fails there too) or the path does not fit.
pub fn socketPath(
    buf: []u8,
    wayland_display: ?[]const u8,
    xdg_runtime_dir: ?[]const u8,
) ?[]const u8 {
    const name = if (wayland_display) |d| (if (d.len == 0) "wayland-0" else d) else "wayland-0";
    if (name[0] == '/') {
        if (name.len > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    const dir = xdg_runtime_dir orelse return null;
    if (dir.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.trimRight(u8, dir, "/"), name }) catch null;
}

const base: Inputs = .{ .wslg_socket = true, .wayland_socket = null, .gdk_backend = null, .current_resolves = false };

fn with(comptime field: []const u8, value: anytype) Inputs {
    var in = base;
    @field(in, field) = value;
    return in;
}

test "wslg display: root on WSLg with no socket in its runtime dir uses WSLg's" {
    try std.testing.expectEqual(Decision.use_wslg, decide(base));
}

test "wslg display: never touches a box without WSLg's socket" {
    try std.testing.expectEqual(Decision.not_wslg, decide(with("wslg_socket", false)));
}

test "wslg display: the default user's linked socket is left alone" {
    try std.testing.expectEqual(Decision.reachable, decide(with("current_resolves", true)));
}

test "wslg display: WAYLAND_SOCKET is the user's connection" {
    try std.testing.expectEqual(Decision.user_choice, decide(with("wayland_socket", @as(?[]const u8, "5"))));
}

test "wslg display: GDK_BACKEND without wayland is honoured; with it, or *, or empty, is not a veto" {
    try std.testing.expectEqual(Decision.user_choice, decide(with("gdk_backend", @as(?[]const u8, "x11"))));
    try std.testing.expectEqual(Decision.user_choice, decide(with("gdk_backend", @as(?[]const u8, "x11,broadway"))));
    try std.testing.expectEqual(Decision.use_wslg, decide(with("gdk_backend", @as(?[]const u8, "wayland"))));
    try std.testing.expectEqual(Decision.use_wslg, decide(with("gdk_backend", @as(?[]const u8, "x11, wayland"))));
    try std.testing.expectEqual(Decision.use_wslg, decide(with("gdk_backend", @as(?[]const u8, "*"))));
    try std.testing.expectEqual(Decision.use_wslg, decide(with("gdk_backend", @as(?[]const u8, ""))));
}

test "wslg display: socketPath follows libwayland's resolution" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/run/user/0/wayland-0", socketPath(&buf, "wayland-0", "/run/user/0").?);
    try std.testing.expectEqualStrings("/run/user/0/wayland-0", socketPath(&buf, null, "/run/user/0/").?);
    try std.testing.expectEqualStrings("/run/user/0/wayland-0", socketPath(&buf, "", "/run/user/0").?);
    try std.testing.expectEqualStrings("/run/user/0/wayland-1", socketPath(&buf, "wayland-1", "/run/user/0").?);
    try std.testing.expectEqualStrings(wslg_socket, socketPath(&buf, wslg_socket, null).?);
    try std.testing.expect(socketPath(&buf, "wayland-0", null) == null);
    try std.testing.expect(socketPath(&buf, "wayland-0", "") == null);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(socketPath(&tiny, "wayland-0", "/run/user/0") == null);
    try std.testing.expect(socketPath(&tiny, wslg_socket, null) == null);
}
