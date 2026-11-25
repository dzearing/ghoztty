//! A new tab on a chosen shell (T3753, child of T3735): the list the "+"
//! dropdown and File > New Tab offer, and the tab a pick opens.
//!
//! The rows and their ids are `shell_menu.zig`; the menus that show them are
//! built in `Window.zig` (`appendNewTabShellRows`). This file is the half that
//! needs the OS: reading the catalog off the box, and opening the tab.
//!
//! The pane a pick opens is built by `pane_restart.shellOverrides`, the same
//! function Restart Pane with Shell uses, so "open a tab on WSL: Ubuntu" and
//! "restart this pane on WSL: Ubuntu" cannot start that shell two ways: a WSL
//! entry opens the distro in its home (`wsl.exe -d <distro> --cd ~`, T3749),
//! and an agent-backed window opens an agent session like any other tab.

const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const SettingsWindow = @import("SettingsWindow.zig");
const controls = @import("settings_controls.zig");
const pane_restart = @import("pane_restart.zig");
const restart_shell = @import("restart_shell.zig");
const shell_menu = @import("shell_menu.zig");

const log = std.log.scoped(.new_tab_shell);

/// Whether `window` offers the list at all. A window on another machine opens
/// that machine's shells, and this list is this machine's, so there the "+"
/// and New Tab stay the single default-shell action they always were.
pub fn offered(window: *const Window) bool {
    return window.remote_dialed == null and !window.closing;
}

/// The shells a menu lists, in Settings > Shell's order (T3750): the found
/// common shells, Git Bash, one `WSL: <distro>` per installed distro. Reads
/// PATH, the Git install folders and the WSL registry key only, so opening the
/// menu never starts WSL. Strings in `arena`; at most `shell_menu.max_entries`.
pub fn catalog(arena: Allocator) []const controls.ShellEntry {
    const all = SettingsWindow.installedShells(arena, arena) catch |err| {
        log.warn("shell catalog unavailable err={}", .{err});
        return &.{};
    };
    return all[0..@min(all.len, shell_menu.max_entries)];
}

/// Open a new tab in `window` on `spec` (a catalog entry's `spec`: a program,
/// a path, or `wsl:<distro>`). In single-window mode a new tab is a new
/// workspace (T3182), so it opens one there, on the same shell.
///
/// The tab starts where a plain new tab would - the active pane's folder,
/// when `tab-inherit-working-directory` is on - unless that folder means
/// nothing to the chosen shell: a WSL tab starts in the distro's home, and a
/// Linux folder from a WSL pane does not follow a Windows shell
/// (`restart_shell.carriedCwd`).
pub fn open(window: *Window, spec: []const u8) void {
    if (!offered(window)) return;
    const app = window.app;
    var arena_state = std.heap.ArenaAllocator.init(app.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const old_cwd: ?[]const u8 = folder: {
        if (!apprt.surface.shouldInheritWorkingDirectory(.tab, &app.config)) break :folder null;
        const parent = window.getActiveSurface() orelse break :folder null;
        if (parent.remote_is_local_agent) {
            const conn = window.local_agent_conn orelse break :folder null;
            break :folder Window.inheritedCwd(arena, conn, parent);
        }
        break :folder parent.livePwd(arena) orelse parent.pwd;
    };
    const cwd = restart_shell.carriedCwd(spec, old_cwd);

    var env: std.ArrayList(Surface.Overrides.EnvVar) = .empty;
    if (window.ipc_name) |wn| env.append(arena, .{ .key = "GHOZTTY_WINDOW_NAME", .value = wn }) catch return;

    var ov = pane_restart.shellOverrides(arena, window.local_agent_conn, spec, cwd, null, env.items) catch |err| {
        log.warn("new tab on {s}: overrides failed err={}", .{ spec, err });
        return;
    };

    if (window.isWorkspace()) {
        _ = app.createWindow(.{
            .surface_overrides = &ov,
            .force_opaque = window.isForcedOpaque(),
            .desk_variant = app.newWindowDeskVariant(),
        }) catch |err| {
            log.warn("new workspace on {s} failed err={}", .{ spec, err });
            return;
        };
        log.info("new workspace on shell {s} (cwd={s})", .{ spec, cwd orelse "<shell default>" });
        return;
    }

    window.pending_surface_overrides = &ov;
    defer window.pending_surface_overrides = null;
    _ = window.addTab() catch |err| {
        log.warn("new tab on {s} failed err={}", .{ spec, err });
        return;
    };
    log.info("new tab on shell {s} (cwd={s})", .{ spec, cwd orelse "<shell default>" });
}
