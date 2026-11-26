//! Restart Pane with Shell (T3752, child of T3735): replace one pane's shell
//! in place.
//!
//! The pane keeps its id (`$GHOZTTY_PANE_ID` in the new shell names the same
//! pane), its IPC name, its tint and its slot in the split tree - ratios, zoom,
//! stash and blade state included - and only the process tree inside it is
//! replaced. An agent-backed pane's session is ENDED (the old shell and
//! whatever ran under it are gone, exactly as a close would leave them) and a
//! fresh session is opened in the same surface slot.
//!
//! The swap is `Window.replaceTabLeaf`, the in-place leaf rebuild crash
//! recovery uses (T399), with one difference that matters: recovery re-ATTACHes
//! the departing session, so it leaves it to DETACH; a restart marks it CLOSE
//! first, or the old shell would live on, invisible, in the agent.
//!
//! Before anything is replaced the close-confirm rule is asked
//! (`Surface.closeNeedsConfirmNow`): a restart ends the running program the
//! same way Ctrl+Shift+W would, so it asks the same question.
//!
//! Every user entry (the pane context menu's submenu, the command palette's
//! "Restart Pane with Shell: <shell>" rows) goes through `request`, which
//! defers the swap to the top of the message loop: the menu and the palette
//! both run inside the departing surface's own window procedure, and freeing
//! that surface underneath its caller is the reentrancy `Surface.close` posts
//! WM_CLOSE to avoid.

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const PaneView = @import("PaneView.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const SettingsWindow = @import("SettingsWindow.zig");
const restart_shell = @import("restart_shell.zig");
const verb_args = @import("../ipc/args.zig");
const pane_id_mod = @import("../ipc/pane_id.zig");
const remote_connection = @import("../../remote/connection.zig");

const log = std.log.scoped(.pane_restart);

pub const Choice = restart_shell.Choice;

/// What a restart came to.
pub const Outcome = enum {
    restarted,
    /// Something other than the shell is running and the caller asked not to
    /// be shown the dialog (`Mode.probe`): nothing was replaced.
    confirm_needed,
    /// The user answered Cancel.
    cancelled,
    /// A viewer pane has no shell.
    not_terminal,
    /// A pane on another machine: its shells are that machine's, and this
    /// list is this machine's. Its picker is not offered.
    remote_pane,
    failed,
};

pub const Mode = enum {
    /// Ask the user when the close-confirm rule says to.
    ask,
    /// Never ask: report `confirm_needed` instead (the test seam's default,
    /// which proves the rule without a modal).
    probe,
    /// Restart whatever is running.
    force,
};

/// The installed shells a picker offers, strings in `arena`: the catalog
/// Settings > Shell and the new-tab menus read (`SettingsWindow.installedShells`,
/// T3750 - Git Bash included), so every shell picker lists the same shells in
/// the same order (T3753). Reads PATH, the Git install folders and the WSL
/// registry key only, so building the list never starts WSL.
pub fn installedChoices(arena: Allocator) Allocator.Error![]Choice {
    const entries = try SettingsWindow.installedShells(arena, arena);
    const n = @min(entries.len, restart_shell.max_choices);
    const out = try arena.alloc(Choice, n);
    for (entries[0..n], out) |e, *c| c.* = .{ .spec = e.spec, .label = e.label };
    return out;
}

/// Whether `pane` can be restarted from a picker at all: a terminal in a
/// window on this machine.
pub fn offered(pane: *PaneView) bool {
    const s = pane.surface() orelse return false;
    return s.parent_window.remote_dialed == null;
}

/// Replace `pane`'s shell with `spec` now. Must be called from the top of the
/// message loop (or an IPC dispatch, which runs there), never from inside the
/// departing surface's own window procedure - `request` is the way in from a
/// menu.
pub fn restart(app: *App, pane: *PaneView, spec: []const u8, mode: Mode) Outcome {
    const old = pane.surface() orelse return .not_terminal;
    const window = old.parent_window;
    if (window.remote_dialed != null) return .remote_pane;
    if (window.closing) return .failed;
    const tab = window.findTabIndex(pane) orelse return .failed;

    if (mode != .force and
        old.closeNeedsConfirmNow(old.core_surface_ready and old.core_surface.needsConfirmQuit()))
    {
        if (mode == .probe) return .confirm_needed;
        var text: [restart_shell.confirm_text.len + 1:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&text, restart_shell.confirm_text) catch 0;
        text[n] = 0;
        const answer = ConfirmDialog.show(app, window.hwnd, window.scale, old.hwnd, .{
            .title = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty"),
            .text = text[0..n :0],
            .ok_label = std.unicode.utf8ToUtf16LeStringLiteral(restart_shell.confirm_ok),
        });
        if (answer != .ok) return .cancelled;
        // The dialog pumped messages: the pane may be gone, or moved.
        if (!app.hasWindow(window) or window.closing) return .failed;
        if (window.findTabIndex(pane) != tab) return .failed;
    }

    var arena_state = std.heap.ArenaAllocator.init(app.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Everything the fresh surface must carry, read off the departing one
    // BEFORE the swap frees it.
    const id = arena.dupe(u8, old.paneId()) catch return .failed;
    const name: ?[]const u8 = if (app.ipcNameOf(.{ .pane = pane })) |n|
        (arena.dupe(u8, n) catch return .failed)
    else
        null;
    const tint = old.background_tint;
    const had_focus = if (old.hwnd) |h| w32.GetFocus() == h else false;
    const old_cwd: ?[]const u8 = if (old.remote_is_local_agent)
        (if (window.local_agent_conn) |conn| Window.inheritedCwd(arena, conn, old) else null)
    else
        (old.livePwd(arena) orelse old.pwd);
    const cwd = restart_shell.carriedCwd(spec, old.shell_family, old_cwd);
    const wsl_folder = restart_shell.carriedWslFolder(arena, spec, old.shell_family, old.reportedPwd(arena) orelse old.pwd) catch
        return .failed;
    const kept_stack = window.stackPersisted(arena, tab);

    var env: std.ArrayList(Surface.Overrides.EnvVar) = .empty;
    if (window.ipc_name) |wn| env.append(arena, .{ .key = "GHOZTTY_WINDOW_NAME", .value = wn }) catch return .failed;
    if (name) |n| env.append(arena, .{ .key = "GHOZTTY_PANE_NAME", .value = n }) catch return .failed;

    var ov = shellOverrides(arena, window.local_agent_conn, spec, cwd, wsl_folder, id, env.items) catch
        return .failed;

    // A restart ENDS the old session. Marked before the swap releases the
    // surface; un-marked if the swap fails, so the pane the user still has is
    // not left to end its session on some later, unrelated detach.
    old.setSessionCloseIntent(true);
    const fresh = window.replaceTabLeaf(tab, pane, .{ .terminal = &ov }) catch |err| {
        log.warn("restart pane {s} with {s} failed err={}", .{ id, spec, err });
        old.setSessionCloseIntent(false);
        return .failed;
    };

    if (name) |n| app.ipcRegister(n, .{ .pane = fresh }) catch |err|
        log.warn("restart pane: re-register '{s}' failed err={}", .{ n, err });
    if (fresh.surface()) |s| if (tint) |t| s.applyBackgroundTint(t, true);
    if (kept_stack) |s| window.adoptStackPersisted(tab, s);
    if (tab != window.active_tab) window.setTabSurfacesVisible(tab, false);
    window.layoutSplits();
    if (had_focus) if (fresh.hwnd()) |h| {
        _ = w32.SetFocus(h);
    };
    app.markLayoutDirty();
    log.info("restarted pane {s} with {s} (cwd={s})", .{ id, spec, cwd orelse "<shell default>" });
    return .restarted;
}

/// The overrides that open a pane on the shell `spec` (a program, a path, or
/// `wsl:<distro>`) with no command: what a restart (above) and a new tab on a
/// chosen shell (`new_tab_shell.zig`, T3753) both hand the new surface, so the
/// two cannot open one choice two ways. `conn` is the window's local agent, or
/// null for a plain ConPTY pane. A WSL spec opens `wsl.exe [-d <distro>] --cd
/// <wsl_folder>` (T3749; `~` when null, T3754 carries a WSL pane's own Linux
/// folder); `cwd` is the folder a Windows shell starts in (null: its
/// default). Strings are borrowed or allocated in `arena`.
pub fn shellOverrides(
    arena: Allocator,
    conn: ?*remote_connection.Connection,
    spec: []const u8,
    cwd: ?[]const u8,
    wsl_folder: ?[]const u8,
    pane_id: ?[]const u8,
    env: []const Surface.Overrides.EnvVar,
) Allocator.Error!Surface.Overrides {
    const wsl = verb_args.isWslShell(spec);
    const exec_argv: []const [:0]const u8 = if (wsl)
        try verb_args.wslInteractiveArgv(arena, spec, wsl_folder)
    else argv: {
        const one = try arena.alloc([:0]const u8, 1);
        one[0] = try arena.dupeZ(u8, spec);
        break :argv one;
    };
    if (conn) |c| return .{
        .pane_id = pane_id,
        .env = env,
        .remote = .{
            .connection = c,
            .working_directory = cwd,
            // The program, never `wsl:<distro>`: an older agent would try to
            // run that as a file name (T3749's `agentShell`).
            .shell = verb_args.shellProgram(spec),
            .command_argv = if (wsl) try widen(arena, exec_argv) else null,
            .local_agent = true,
        },
    };
    return .{
        .pane_id = pane_id,
        .env = env,
        .command_argv = exec_argv,
        .working_directory = cwd,
    };
}

fn widen(arena: Allocator, argv: []const [:0]const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| out[i] = a;
    return out;
}

/// A restart a menu asked for, waiting for the top of the loop.
pub const Pending = struct {
    id: pane_id_mod.Buf = undefined,
    spec: [256]u8 = undefined,
    spec_len: usize = 0,
};

/// Queue a restart of the pane `pane_id` with `spec` and run it from the top
/// of the message loop (see the file comment). One at a time: a second request
/// before the first ran replaces it, which is what a user picking twice meant.
pub fn request(app: *App, pane_id: []const u8, spec: []const u8) void {
    if (!pane_id_mod.isValid(pane_id) or spec.len == 0 or spec.len > 256) return;
    var p: Pending = .{};
    @memcpy(&p.id, pane_id);
    @memcpy(p.spec[0..spec.len], spec);
    p.spec_len = spec.len;
    app.pending_restart = p;
    const msg = app.msg_hwnd orelse return perform(app);
    _ = w32.PostMessageW(msg, App.WM_APP_RESTART_PANE, 0, 0);
}

/// The `WM_APP_RESTART_PANE` handler. The pane is re-resolved by id, so one
/// closed in between dissolves into a no-op.
pub fn perform(app: *App) void {
    const p = app.pending_restart orelse return;
    app.pending_restart = null;
    const target = app.ipcLookup(&p.id) orelse return;
    const pane = switch (target) {
        .pane => |pv| pv,
        .window => return,
    };
    const outcome = restart(app, pane, p.spec[0..p.spec_len], .ask);
    log.info("restart pane request outcome={s}", .{@tagName(outcome)});
}
