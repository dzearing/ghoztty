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
const controls = @import("settings_controls.zig");
const wsl_distros = @import("wsl_distros.zig");
const restart_shell = @import("restart_shell.zig");
const verb_args = @import("../ipc/args.zig");
const pane_id_mod = @import("../ipc/pane_id.zig");

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

/// The installed shells a picker offers, strings in `arena`. Reads the PATH
/// and the WSL registry key only, so building the list never starts WSL.
pub fn installedChoices(arena: Allocator) Allocator.Error![]Choice {
    var installed: std.ArrayList(restart_shell.Installed) = .empty;
    const path = std.process.getEnvVarOwned(arena, "PATH") catch try arena.dupe(u8, "");
    const pathext = std.process.getEnvVarOwned(arena, "PATHEXT") catch try arena.dupe(u8, ".COM;.EXE;.BAT;.CMD");
    const Fs = struct {
        fn exists(_: void, p: []const u8) bool {
            const st = std.fs.cwd().statFile(p) catch return false;
            return st.kind == .file;
        }
    };
    var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    for (controls.common_shells) |s| {
        if (controls.shellProblem(&buf, s.program, path, pathext, {}, Fs.exists) != null) continue;
        try installed.append(arena, .{ .program = s.program, .label = s.label });
    }
    const distros = try wsl_distros.listInstalled(arena);
    return restart_shell.choices(arena, installed.items, distros);
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
    const cwd = restart_shell.carriedCwd(spec, old_cwd);
    const kept_stack = window.stackPersisted(arena, tab);

    var env: std.ArrayList(Surface.Overrides.EnvVar) = .empty;
    if (window.ipc_name) |wn| env.append(arena, .{ .key = "GHOZTTY_WINDOW_NAME", .value = wn }) catch return .failed;
    if (name) |n| env.append(arena, .{ .key = "GHOZTTY_PANE_NAME", .value = n }) catch return .failed;

    const wsl = verb_args.isWslShell(spec);
    const exec_argv: []const [:0]const u8 = if (wsl)
        verb_args.wslInteractiveArgv(arena, spec, null) catch return .failed
    else argv: {
        const one = arena.alloc([:0]const u8, 1) catch return .failed;
        one[0] = arena.dupeZ(u8, spec) catch return .failed;
        break :argv one;
    };

    var ov: Surface.Overrides = if (window.local_agent_conn) |conn| .{
        .pane_id = id,
        .env = env.items,
        .remote = .{
            .connection = conn,
            .working_directory = cwd,
            // The program, never `wsl:<distro>`: an older agent would try to
            // run that as a file name (T3749's `agentShell`).
            .shell = verb_args.shellProgram(spec),
            .command_argv = if (wsl) widen(arena, exec_argv) catch return .failed else null,
            .local_agent = true,
        },
    } else .{
        .pane_id = id,
        .env = env.items,
        .command_argv = exec_argv,
        .working_directory = cwd,
    };

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
