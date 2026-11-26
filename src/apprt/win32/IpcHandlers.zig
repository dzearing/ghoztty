//! IPC verb handlers for the win32 apprt: everything that runs on the GUI
//! thread once IpcServer has marshaled a request over. Split from
//! IpcServer.zig (transport) so each file has one job. Handlers byte-match
//! the Mac server's semantics and error strings where the cases overlap
//! (macos/Sources/Features/IPC/IPCServer.swift).
const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const App = @import("App.zig");
const IpcSessionAwait = @import("ipc_session_await.zig");
const window_title_owner = @import("window_title_owner.zig");
const ProcessTree = @import("ProcessTree.zig");
const dial_failure = @import("dial_failure.zig");
const remote_connection = @import("../../remote/connection.zig");
const Surface = @import("Surface.zig");
const ipc_capture = @import("ipc_capture.zig");
const ipc_hover = @import("ipc_hover.zig");
const ipc_agent_integration = @import("ipc_agent_integration.zig");
const ipc_whats_new = @import("ipc_whats_new.zig");
const ipc_frame_pacing = @import("ipc_frame_pacing.zig");
const ipc_shortcut_guide = @import("ipc_shortcut_guide.zig");
const ipc_settings = @import("ipc_settings.zig");
const ipc_workspaces = @import("ipc_workspaces.zig");
const ipc_restart_pane = @import("ipc_restart_pane.zig");
const PaneView = @import("PaneView.zig");
const ViewerPane = @import("ViewerPane.zig");
const Window = @import("Window.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const pane_stash = @import("pane_stash.zig");
const pane_stack_grid = @import("pane_stack_grid.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree(PaneView);
const w32 = @import("win32.zig");
const window_active = @import("window_active.zig");
const color_math = @import("color_math.zig");
const desk_palette = @import("desk_palette.zig");
const apprt = @import("../../apprt.zig");
const terminal = @import("../../terminal/main.zig");
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.win32_ipc);

/// What a handler needs from the server: the app (GUI-thread state) and
/// the response allocator (the listener thread frees responses with it).
pub const Context = struct {
    app: *App,
    alloc: Allocator,
};

// The frontend-independent half of the server (T3334): request shape, the
// action table, the reply builders and the dispatcher live in
// apprt/ipc/server.zig, shared with the GTK frontend. This file IS the win32
// frontend that dispatcher calls: the `pub` decls below (`Context`,
// `CallerScope`, `log_scope`, the caller-scope hooks, one `handle*` per verb,
// `handleSeam`) are its interface, and a missing verb is a compile error.
const ipc_server = apprt.ipc.server;
const verbs = apprt.ipc.verbs;
const Request = ipc_server.Request;
const errorResponse = ipc_server.errorResponse;
const successResponse = ipc_server.successResponse;
const messageResponse = ipc_server.messageResponse;
const nonEmpty = ipc_server.nonEmpty;
const joinArgv = ipc_server.joinArgv;
const foundVerb = ipc_server.foundVerb;

// ---------------------------------------------------------------------------
// The planes (T1782). Verbs whose bodies are win32's alone and large enough
// to be their own subject live in their own files; these aliases ARE this
// file's public surface for them, so the dispatcher (which looks up
// `handle*` here) and every caller elsewhere in the apprt are unchanged.
const ipc_list = @import("ipc_list.zig");
const ipc_rearrange = @import("ipc_rearrange.zig");
const ipc_remote_window = @import("ipc_remote_window.zig");
const ipc_stash = @import("ipc_stash.zig");
const ipc_version = @import("ipc_version.zig");

pub const handleList = ipc_list.handleList;
pub const handleRearrange = ipc_rearrange.handleRearrange;
pub const handleNewRemoteWindow = ipc_remote_window.handleNewRemoteWindow;
pub const RemoteDialJob = ipc_remote_window.RemoteDialJob;
pub const runRemoteDial = ipc_remote_window.runRemoteDial;
pub const finishRemoteWindow = ipc_remote_window.finishRemoteWindow;
pub const resolveAccountToken = ipc_remote_window.resolveAccountToken;
pub const resolveEnvToken = ipc_remote_window.resolveEnvToken;
pub const resolveToken = ipc_remote_window.resolveToken;
pub const handleVersion = ipc_version.handleVersion;
pub const handleHandoffQuit = ipc_version.handleHandoffQuit;
const handoffNote = ipc_version.handoffNote;
const stashOrRestore = ipc_stash.stashOrRestore;

/// Dispatch one request on the GUI thread. Returns the response JSON
/// (allocated; the listener frees it). Error strings byte-match the Mac
/// server where the cases overlap.
pub fn dispatch(ctx: Context, request_json: []const u8) Allocator.Error!?[]u8 {
    return ipc_server.dispatch(@This(), ctx, ctx.alloc, request_json);
}

/// `IPC: received action '<verb>'` keeps the `win32_ipc` scope postmortems
/// and `os/log_gate.zig` read.
pub const log_scope = .win32_ipc;

/// Pane names belong to their window (T2250): every lookup a request makes
/// starts in the caller's. Restored rather than cleared, so a request served
/// inside another's nested wait hands the outer one its scope back.
pub const CallerScope = ?*Window;

pub fn enterCallerScope(ctx: Context, caller_pane: ?[]const u8) CallerScope {
    const outer = ctx.app.ipc_caller_window;
    ctx.app.ipc_caller_window = callerWindow(ctx.app, caller_pane);
    return outer;
}

pub fn leaveCallerScope(ctx: Context, outer: CallerScope) void {
    ctx.app.ipc_caller_window = outer;
}

pub fn handleStash(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return stashOrRestore(ctx, request, false);
}

pub fn handleRestore(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return stashOrRestore(ctx, request, true);
}

/// The DEBUG-ONLY test seams: not CLI verbs, and compiled out of a release
/// build, where each action falls through to `unknown action`.
pub fn handleSeam(ctx: Context, request: Request) Allocator.Error!ipc_server.SeamReply {
    if (ipc_capture.enabled and std.mem.eql(u8, request.action, "capture-pane")) {
        // T275: a DEBUG-ONLY test seam, not a CLI verb — see ipc_capture.zig
        // for why it is gated and why there is no `+capture-pane`. In a
        // release build `enabled` is false and this falls through to the
        // ordinary unknown-action answer.
        return .{ .reply = try ipc_capture.handle(ctx.app, ctx.alloc, request.arguments) };
    } else if (ipc_hover.enabled and std.mem.eql(u8, request.action, "capture-hover")) {
        // T282: the same DEBUG-ONLY test seam for a HOVERED frame, which the
        // harness cannot paint from outside at all — see ipc_hover.zig for the
        // ordering argument. Release builds fall through to unknown-action.
        return .{ .reply = try ipc_hover.handle(ctx.app, ctx.alloc, request.arguments) };
    } else if (ipc_agent_integration.enabled and std.mem.eql(u8, request.action, "agent-integration")) {
        // T872: the DEBUG-ONLY seam the agent-integrations acceptance harness
        // drives install/uninstall/status through — the GUI offers one action
        // per state, so idempotence, refusals, rollback and the banner
        // refcount are unreachable from outside without it. See
        // ipc_agent_integration.zig; release builds fall through to
        // unknown-action.
        return .{ .reply = try ipc_agent_integration.handle(ctx.alloc, request.arguments) };
    } else if (ipc_frame_pacing.enabled and std.mem.eql(u8, request.action, "frame-pacing")) {
        // T1737: the DEBUG-ONLY frame-interval probe a smoothness claim is
        // scored with - see ipc_frame_pacing.zig. Release builds fall through
        // to unknown-action and record nothing.
        return .{ .reply = try ipc_frame_pacing.handle(ctx.app, ctx.alloc, request.arguments) };
    } else if (ipc_whats_new.enabled and std.mem.eql(u8, request.action, "whats-new")) {
        // T624: the DEBUG-ONLY seam for the What's New window. Which bundled
        // versions count as "new" is a decision no screenshot can check, so
        // the harness reads the model out of the same store the window
        // paints. Release builds fall through to unknown-action.
        return .{ .reply = try ipc_whats_new.handle(ctx.app, ctx.alloc, request.arguments) };
    } else if (ipc_shortcut_guide.enabled and std.mem.eql(u8, request.action, "shortcut-guide")) {
        // T2591: the DEBUG-ONLY seam for the keyboard shortcut guide. Which
        // bindings are live, customized or matched by a key-combo search is a
        // model, not pixels. Release builds fall through to unknown-action.
        return .{ .reply = try ipc_shortcut_guide.handle(ctx.app, ctx.alloc, request.arguments) };
    } else if (ipc_settings.enabled and std.mem.eql(u8, request.action, "settings")) {
        // T2675: the DEBUG-ONLY seam for the Settings window. What a row
        // reads (its file line, the effective value, a later include's
        // override, the parser's refusal) is a model, not pixels. Release
        // builds fall through to unknown-action.
        return .{ .reply = try ipc_settings.handle(ctx.app, ctx.alloc, request.arguments) };
    } else if (ipc_workspaces.enabled and std.mem.eql(u8, request.action, "workspaces")) {
        // T3191: the DEBUG-ONLY seam for single-window mode - which workspace
        // holds the shared window, which are parked, and a hand-off by name
        // until the sidebar switch (T3182) lands. Release builds fall through
        // to unknown-action.
        return .{ .reply = try ipc_workspaces.handle(ctx.app, ctx.alloc, request.arguments) };
    } else if (ipc_restart_pane.enabled and std.mem.eql(u8, request.action, "restart-pane")) {
        // T3752: the DEBUG-ONLY seam for Restart Pane with Shell - the user's
        // ways in are a context submenu and palette rows, which a test on the
        // background desktop cannot click. Release builds fall through to
        // unknown-action.
        return .{ .reply = try ipc_restart_pane.handle(ctx.app, ctx.alloc, request.arguments) };
    }

    return .unhandled;
}

/// The window of the pane a request came from, by the pane's own id. Null for
/// no caller pane, or one that is gone.
fn callerWindow(app: *App, caller_pane: ?[]const u8) ?*Window {
    const id = nonEmpty(caller_pane orelse return null) orelse return null;
    return switch (app.ipcLookupFrom(id, null) orelse return null) {
        .pane => |pane| pane.parentWindow(),
        .window => null,
    };
}

/// The reply for a name `ipcLookup` found nothing for: the ambiguity, when
/// panes in several windows hold it and none is the caller's (T2250), else the
/// handler's own not-found text.
pub fn missingResponse(
    ctx: Context,
    name: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error![]u8 {
    if (try ctx.app.ipcAmbiguity(ctx.alloc, name)) |msg| {
        defer ctx.alloc.free(msg);
        return try errorResponse(ctx.alloc, "{s}", .{msg});
    }
    return try errorResponse(ctx.alloc, fmt, args);
}

// Pure verb-argument logic (flag parsing, shell wrap table, ConPTY input
// normalization, layout validation) lives in apprt/ipc/args.zig where it
// is unit tested in the none-runtime build.
const verb_args = apprt.ipc.args;
const shell_family = apprt.ipc.shell_family;
const wsl_distros = @import("wsl_distros.zig");
const split_name_collision = apprt.ipc.split_name_collision;

const VerbArgs = verb_args.VerbArgs;
const parseVerbArgs = verb_args.parseVerbArgs;
const dropPrefix = verb_args.dropPrefix;

/// `--view` on `+new-window`/`+split`. One answer left, and it is permanent:
/// an ambiguous `--view` + command is rejected the same way on both platforms.
/// The interim "file viewers are not supported here" refusal that used to sit
/// beside it is gone — T90e renders files, so both modes build a real pane.
///
/// Returns the error response to send, or null to carry on.
fn viewArgResponse(ctx: Context, args: VerbArgs) Allocator.Error!?[]u8 {
    if (verb_args.viewConflictsWithCommand(args))
        return try errorResponse(ctx.alloc, "{s}", .{verb_args.view_command_conflict_error});
    return null;
}

/// Shell resolution (`--shell` flag → `command-shell` config → cmd.exe),
/// then the pure per-flavor wrap table.
fn wrapCommandArgv(
    ctx: Context,
    arena: Allocator,
    shell_flag: ?[]const u8,
    command: []const u8,
) Allocator.Error![]const [:0]const u8 {
    const shell = shell_flag orelse
        (ctx.app.config.@"command-shell" orelse "cmd.exe");
    return verb_args.wrapShellCommandArgv(arena, shell, command);
}

/// `--shell=wsl:<distro>` naming a distro that is not installed (T3735): the
/// refusal names the ones that are, read from the registry so WSL is never
/// started to answer. `verbs.viewRefusal` calls it for every create verb.
pub fn shellRefusal(alloc: Allocator, args: VerbArgs) Allocator.Error!?[]u8 {
    const spec = nonEmpty(args.shell) orelse return null;
    const want = verb_args.wslDistroSpec(spec) orelse return null;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const installed = try wsl_distros.listInstalled(arena);
    if (wsl_distros.find(installed, want) != null) return null;
    if (installed.len == 0)
        return try errorResponse(alloc, "--shell=wsl:{s}: no WSL distro is installed for this user", .{want});
    const list = try std.mem.join(arena, ", ", installed);
    return try errorResponse(
        alloc,
        "--shell=wsl:{s}: no WSL distro by that name is installed. Installed: {s} (use --shell=wsl:<name>)",
        .{ want, list },
    );
}

/// The WSL shell spec of a pane that opens a WSL shell with no command and no
/// `-e` (T3735), or null. Such a pane is spawned `wsl.exe [-d <distro>] --cd
/// <folder>` (`verb_args.wslInteractiveArgv`) rather than as a bare `wsl.exe`,
/// which would land in the `/mnt/c` mirror of the app's folder.
fn wslInteractive(
    e_args: []const [:0]const u8,
    command: ?[]const u8,
    shell_flag: ?[]const u8,
) ?[]const u8 {
    if (e_args.len > 0 or nonEmpty(command) != null) return null;
    const spec = nonEmpty(shell_flag) orelse return null;
    return if (verb_args.isWslShell(spec)) spec else null;
}

/// The folder a verb ASKED for: `--working-directory` unless the CLI only
/// filled in its own cwd (`--cwd-implicit`, T135). A WSL pane opens at `~`
/// without one (T3735), so the caller's Windows folder must not stand in for
/// a request.
fn explicitFolder(args: VerbArgs) ?[]const u8 {
    if (args.cwd_implicit) return null;
    return nonEmpty(args.working_directory);
}

/// The `OPEN.shell` a LOCAL-agent pane carries: the program, so an agent that
/// predates `wsl:<distro>` is never asked to run that as a file name.
fn agentShell(shell_flag: ?[]const u8) ?[]const u8 {
    return if (nonEmpty(shell_flag)) |s| verb_args.shellProgram(s) else null;
}

/// The exec-path (no session-persistence agent) argv for `-e`/`--command`/
/// `--shell`; see `verb_args.localExecArgv`. T1665: `--shell` alone opens that
/// shell here too, as it always did on the agent path.
fn execArgv(
    ctx: Context,
    arena: Allocator,
    e_args: []const [:0]const u8,
    command: ?[]const u8,
    shell_flag: ?[]const u8,
    working_directory: ?[]const u8,
) Allocator.Error!?[]const [:0]const u8 {
    if (wslInteractive(e_args, command, shell_flag)) |spec|
        return try verb_args.wslInteractiveArgv(arena, spec, nonEmpty(working_directory));
    return verb_args.localExecArgv(
        arena,
        e_args,
        command,
        shell_flag,
        ctx.app.config.@"command-shell" orelse "cmd.exe",
    );
}

/// The overrides that open `spec`'s interactive shell in a new LOCAL pane
/// (T3751): the command palette's "… with Shell" picks. Built from the same
/// pieces `+new-window`/`+split --shell=<spec>` use with no command, so a
/// shell chosen in a menu and one named on the CLI cannot open differently -
/// a WSL spec opens `wsl.exe [-d <distro>] --cd ~`, anything else that
/// program. `conn` is the window's local session-persistence agent, or null
/// for a plain ConPTY pane; `cwd` is a WINDOWS folder for the process, or null
/// for the default. `wsl_folder` is the Linux folder a WSL pane starts in
/// (`wsl --cd`, T3754: a WSL pane opened from a WSL pane keeps its folder), or
/// null for `~`; a Windows shell ignores it.
pub fn shellPaneOverrides(
    app: *App,
    arena: Allocator,
    conn: ?*remote_connection.Connection,
    spec: []const u8,
    cwd: ?[]const u8,
    wsl_folder: ?[]const u8,
) Allocator.Error!Surface.Overrides {
    const ctx: Context = .{ .app = app, .alloc = arena };
    if (conn) |c| return .{ .remote = .{
        .connection = c,
        .working_directory = cwd,
        .shell = agentShell(spec),
        .command_argv = try localAgentArgv(ctx, arena, &.{}, spec, null, wsl_folder),
        .local_agent = true,
    } };
    return .{
        .command_argv = try execArgv(ctx, arena, &.{}, null, spec, wsl_folder),
        .working_directory = cwd,
    };
}

/// The folder a verb's pane PROCESS starts in (T3754): `--working-directory`,
/// unless it is a Linux path - that one only means something to `wsl --cd`,
/// which carries it in the argv, and as a Windows process cwd it would fail
/// the spawn.
fn processFolder(wd: ?[]const u8) ?[]const u8 {
    const w = nonEmpty(wd) orelse return null;
    return if (shell_family.isLinuxPath(w)) null else w;
}

/// The shell family of the pane a verb opens (T3754): `--shell`, else `-e`'s
/// program, else the scripted shell a `--command` runs through, else the
/// configured default shell.
fn childFamily(ctx: Context, args: VerbArgs, command: ?[]const u8) shell_family.Family {
    if (nonEmpty(args.shell)) |s| return shell_family.ofProgram(s);
    if (args.e_args.len > 0) return shell_family.ofProgram(args.e_args[0]);
    if (nonEmpty(command) != null)
        return shell_family.ofProgram(ctx.app.config.@"command-shell" orelse "cmd.exe");
    return Surface.defaultFamily(ctx.app);
}

/// The reason a verb refuses when its `--working-directory` cannot be the
/// starting folder of the shell it opens (T3754): a Linux path for a Windows
/// shell. Null when the folder is fine (or absent). A pane on another machine
/// is that machine's business, so only local panes are asked.
fn folderRefusal(ctx: Context, args: VerbArgs, command: ?[]const u8) Allocator.Error!?[]const u8 {
    const wd = explicitFolder(args) orelse return null;
    const problem = shell_family.folderProblem(childFamily(ctx, args, command), wd) orelse return null;
    return try std.fmt.allocPrint(ctx.alloc, "--working-directory={s} {s}", .{ wd, problem });
}

/// The LOCAL-agent half of `wrapCommandArgv` (T468): the same per-flavor
/// keep-alive invocation, sent to the agent as `OPEN.argv` so it execs it
/// verbatim instead of synthesizing `<shell> /c <cmd>` — which exits the moment
/// the command returns, leaving "Process exited. Press any key" and a pane that
/// `+send-keys` cannot drive.
///
/// The keep-alive convention is argv-shaped on Windows (`cmd /K`, `pwsh -NoExit
/// -Command`), and argv cannot ride a command string the way POSIX's `<cmd>;
/// exec <shell> -li` does — so the agent-backed path cannot get it for free from
/// `OPEN.command` the way the Mac one does. Applying the LOCAL table here is
/// only correct because the session-persistence agent IS this machine; a
/// cross-machine agent keeps applying its own (those call sites pass no
/// `command_argv`).
///
/// Null for `-e` (verbatim argv is the whole point of `-e`; it is not a
/// `--command`) and for a pane with no command at all.
fn keepAliveArgv(
    ctx: Context,
    arena: Allocator,
    shell_flag: ?[]const u8,
    command: ?[]const u8,
) Allocator.Error!?[]const []const u8 {
    const cmd = nonEmpty(command orelse return null) orelse return null;
    const argv = try wrapCommandArgv(ctx, arena, shell_flag, cmd);
    // `[]const [:0]const u8` → `[]const []const u8`: the wire type is not
    // sentinel-terminated (the agent re-dupes every element anyway).
    const out = try arena.alloc([]const u8, argv.len);
    for (argv, 0..) |a, i| out[i] = a;
    return out;
}

/// The `OPEN.argv` a LOCAL-agent pane is sent for a verb that may carry `-e`
/// or `--command` (T3402): for `-e`, `agent_exec_argv`'s verdict, else
/// `keepAliveArgv`.
///
/// `-e` used to travel only as `joinArgv`'s plain space join in
/// `OPEN.command`, which the agent runs `cmd /c <string>` - so a word holding
/// a space (`C:\Program Files\...`, a pwsh script block) arrived as several.
/// When a word needs quoting and the program resolves to a file, the words go
/// as a verbatim argv instead and CreateProcess's quoting carries every one
/// intact; otherwise (nothing to quote, a builtin) the join is kept, so a
/// command that works today is untouched. The join still travels in
/// `OPEN.command` as the pane's label either way.
fn localAgentArgv(
    ctx: Context,
    arena: Allocator,
    e_args: []const [:0]const u8,
    shell_flag: ?[]const u8,
    command: ?[]const u8,
    working_directory: ?[]const u8,
) Allocator.Error!?[]const []const u8 {
    if (wslInteractive(e_args, command, shell_flag)) |spec| {
        const argv = try verb_args.wslInteractiveArgv(arena, spec, nonEmpty(working_directory));
        log.info("wsl shell pane: spec={s} --cd {s}", .{ spec, argv[argv.len - 1] });
        const out = try arena.alloc([]const u8, argv.len);
        for (argv, 0..) |a, i| out[i] = a;
        return out;
    }
    if (e_args.len > 0) {
        const words = try arena.alloc([]const u8, e_args.len);
        for (e_args, 0..) |a, i| words[i] = a;
        return try internal_os.agent_exec_argv.agentExecArgv(arena, words);
    }
    return keepAliveArgv(ctx, arena, shell_flag, command);
}

extern "user32" fn IsIconic(hWnd: w32.HWND) callconv(.winapi) windows.BOOL;

/// The pane a target names: the pane itself, or a window's focused pane.
/// Null when the window has no tabs left.
fn targetPane(entry: App.IpcTarget) ?*PaneView {
    return switch (entry) {
        .pane => |p| p,
        .window => |w| if (w.tab_count == 0) null else w.tab_active_pane[w.active_tab],
    };
}

/// Raise and focus the window that owns `entry` (and the pane itself for
/// pane targets).
///
/// Public because the `ghoztty://` URL scheme's in-app path focuses through it
/// too (T695) — one focus implementation, so a link and a `--target` cannot
/// raise a window two different ways.
pub fn focusTarget(entry: App.IpcTarget) void {
    const window = switch (entry) {
        .window => |w| w,
        .pane => |p| p.parentWindow(),
    };
    // A parked workspace (single-window mode, T3185) has no window to raise:
    // focusing it is the switch - it comes on show in the shared window, the
    // same as a click on it in the sidebar (Mac `bringToFront`).
    if (window.hwnd == null) _ = window.app.showWorkspace(window);
    if (window.hwnd) |hwnd| {
        if (IsIconic(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
        raiseWindow(hwnd);
    }
    switch (entry) {
        .window => {},
        .pane => |p| {
            // A STASHED pane comes back first (T1827, Mac `bringForward`):
            // focusing a pane nobody can see focuses nothing.
            if (pane_stash.isStashed(p)) window.restorePane(p, false);
            // A pane in a BACKGROUND tab must have its tab selected first
            // (T555): its HWND is hidden, and SetFocus on a hidden window
            // routes keys to a pane the user cannot see. Making it the
            // tab's active pane before the switch makes `selectTabIndex`'s
            // own deferred focus land on it.
            if (window.tabIndexOfPane(p)) |tab| {
                if (tab != window.active_tab) {
                    window.tab_active_pane[tab] = p;
                    window.selectTabIndex(tab);
                    return;
                }
            }
            // A pane tucked behind a stack's run comes on show (T2110).
            if (window.tabIndexOfPane(p)) |tab| {
                window.tab_active_pane[tab] = p;
                window.showFocusedPane(tab);
            }
            if (p.hwnd()) |h| {
                App.deferSetFocus(h); // T48
            }
        },
    }
}

/// Bring `hwnd` to the front for a `--focus` request (T1820).
///
/// SetForegroundWindow alone is not enough: Windows refuses it whenever
/// focus-steal prevention is in force (another app holds the foreground and
/// the lock timeout has not run out, which on a box set to "never" is always),
/// and a refused call left an EXISTING target exactly where it was - not even
/// Ghoztty's own active window, so the next Alt+Tab back landed on some other
/// window. Mac's `makeKeyAndOrderFront` makes the window the app's key window
/// even when activating the app is denied; the Windows equivalent is
/// activating it within our own input queue, which never takes the foreground
/// from the user's app and, in a background queue, does not raise it over them.
///
/// It runs unconditionally rather than after asking whether the raise landed:
/// when it did, the window is already active and this is a no-op, and the
/// question itself ("is the foreground window this one?") answers "no" forever
/// on a background desktop (the T730 rule).
fn raiseWindow(hwnd: w32.HWND) void {
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.SetActiveWindow(hwnd);
}

/// Resolve a `--color`/`--split-color` value to a color: `#rgb`/`#rrggbb`
/// hex or `random` (a dark muted color). Unparseable values are silently
/// ignored (Mac rule: `NSColor(hex:)` failing just skips the tint).
fn resolveColor(value: ?[]const u8) ?color_math.Rgb {
    const v = value orelse return null;
    if (std.mem.eql(u8, v, "random")) return color_math.randomDark(std.crypto.random);
    return color_math.parseHex(v);
}

/// The window's own gradient for a `+new-window --color` value (T1832): a
/// fresh random one for `random` in the elevated style, null otherwise (no
/// color, an explicit hex, or the flat style, which has no desk to vary).
fn deskVariantFor(color: ?[]const u8, style: anytype) ?desk_palette.Variant {
    const v = color orelse return null;
    if (style != .elevated or !std.mem.eql(u8, v, "random")) return null;
    return desk_palette.Variant.random();
}

/// `+new-window` is the shared body in `apprt/ipc/verbs.zig` (T3375): the
/// argument checks, the idempotent `focused` answers and their notes, and the
/// inline split's direction. What is win32's is the model below it - opening
/// the window (`openWindow`) and the remote `--from-focused` window.
pub fn handleNewWindow(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.newWindow(@This(), ctx, request);
}

/// `--from-focused` (T68): mirror the keyboard "New Window" action on the
/// focused window so a REMOTE parent's machine is inherited (the Mac
/// newWindowInheritingRemote analog - win32 re-dials the same agent). Null for
/// a local (or no) parent, which opens a plain local window.
pub fn newWindowFromFocused(ctx: Context, arena: Allocator, args: VerbArgs) Allocator.Error!?[]u8 {
    _ = arena;
    const app = ctx.app;
    const front = frontWindow(app) orelse return null;
    if (front.remote_machine == null) return null;
    _ = app.openRemoteWindowFrom(front, .{
        .working_directory = nonEmpty(args.working_directory),
        .shell = nonEmpty(args.shell),
        .command = nonEmpty(args.command),
        .activate = args.focus, // T1797
        .desk_variant = deskVariantFor(args.color, app.config.@"macos-pane-style"),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DialFailed => return try errorResponse(
            ctx.alloc,
            "failed to reach the focused window's remote machine: the agent is not running or not reachable",
            .{},
        ),
        // The machine answered and disagreed (T628). Saying it could not be
        // reached would send a script - and whoever reads its log - after a
        // network that is fine.
        error.IncompatibleVersion => return try errorResponse(
            ctx.alloc,
            "incompatible Ghoztty version on the focused window's remote machine: update one side",
            .{},
        ),
        error.CreateFailed => return try errorResponse(ctx.alloc, "failed to create window", .{}),
    };
    return try successResponse(ctx.alloc, "created", null);
}

/// What a WINDOW name means: the registry with no caller window, since window
/// names are global (T2250). The ambiguity needs no sentence here - a name
/// panes hold is refused as a window name whatever they are.
pub fn lookupWindowName(ctx: Context, arena: Allocator, name: []const u8) Allocator.Error!verbs.TargetLookup(Target) {
    _ = arena;
    const app = ctx.app;
    const held = app.ipc_registry.lookup(app.core_app.alloc, app.windows.items, name, null);
    if (held == .ambiguous) return .{ .ambiguous = "" };
    if (held.target()) |entry| return .{ .found = entry };
    return .not_found;
}

pub fn isPane(entry: Target) bool {
    return entry == .pane;
}

/// Open the window `+new-window` asked for, once the shared checks passed.
pub fn openWindow(
    ctx: Context,
    arena: Allocator,
    request: Request,
    args: VerbArgs,
    plan: verbs.WindowPlan,
) Allocator.Error!verbs.Opened {
    const app = ctx.app;
    const first_pane_name = plan.first_pane_name;
    if (args.view == null) {
        if (try folderRefusal(ctx, args, args.command)) |reason| return .{ .failed = reason };
    }

    // Environment for the first surface: --env flags plus the window/pane
    // name vars the Mac injects for named windows. A `--name` for the first
    // pane (T968) is its pane name; otherwise the window name doubles as it.
    var env: std.ArrayList(Surface.Overrides.EnvVar) = .empty;
    try env.appendSlice(arena, args.env);
    if (args.target) |t| {
        try env.append(arena, .{ .key = "GHOZTTY_WINDOW_NAME", .value = t });
    }
    if (plan.first_pane_env_name) |p| {
        try env.append(arena, .{ .key = "GHOZTTY_PANE_NAME", .value = p });
    }

    // T374: `--view` makes the window's one pane a VIEWER, so none of the shell
    // plumbing below applies to it — no command to wrap, no agent session to
    // open, nothing to bake into an environment. It stays here rather than
    // returning early because everything AFTER the create is kind-agnostic:
    // `--title`, `--no-activate`, and the inline split (whose own pane is still
    // a terminal) all mean the same thing for a viewer window.
    // `--working-directory` rides along as the pane's ORIGIN DIRECTORY (T90h):
    // for a viewer it is not a spawn's cwd — there is no spawn — but the
    // provenance fallback for a pane whose location names no directory of its
    // own, and `+new-window` seeds it with the caller's cwd unconditionally.
    const viewer_open: ?ViewerPane.Open = if (args.view) |v|
        if (nonEmpty(v)) |location| .{
            .location = location,
            .origin_directory = nonEmpty(args.working_directory),
        } else null
    else
        null;

    // T99: with `session-persistence` on, route the first pane through the
    // local agent so its process survives this app (quit/crash/upgrade) and can
    // re-attach — exactly like the startup window. Resolve the shared
    // connection up-front (bounded + cached; the same call createWindow makes to
    // set `window.local_agent_conn` for later tabs/splits). A null result
    // (persistence off, or an unreachable/unspawnable agent) falls back to a
    // plain exec pane, so window creation never hangs on a broken agent.
    //
    // Resolved for a viewer window too: its FIRST pane needs no agent, but its
    // later tabs and splits are ordinary terminals and inherit the connection
    // `createWindow` records from this same call.
    const agent_conn: ?*remote_connection.Connection = if (app.config.@"session-persistence")
        app.local_agent.sharedConnection()
    else
        null;

    const overrides: Surface.Overrides = if (agent_conn) |conn| ov: {
        // Agent-backed: the command is a REMOTE-native string the agent's shell
        // runs (never locally shell-wrapped), and the cwd is a local path the
        // same-machine agent honors. The window/pane-name env rides the OPEN.
        const remote_command: ?[]const u8 = if (args.e_args.len > 0)
            try joinArgv(arena, args.e_args)
        else
            nonEmpty(args.command);
        break :ov .{
            .remote = .{
                .connection = conn,
                .working_directory = processFolder(args.working_directory),
                .shell = agentShell(args.shell),
                .command = remote_command,
                .command_argv = try localAgentArgv(ctx, arena, args.e_args, args.shell, args.command, explicitFolder(args)),
                .local_agent = true,
            },
            .env = env.items,
        };
    } else .{
        .command_argv = try execArgv(ctx, arena, args.e_args, args.command, args.shell, explicitFolder(args)),
        .working_directory = processFolder(args.working_directory),
        .env = env.items,
    };

    // `--color=random` in the elevated pane style (T1832, Mac fe3f7c8da): the
    // panes sit on the window's gradient, so a random color is a random
    // GRADIENT and the terminals keep their theme. An explicit hex is still a
    // terminal tint, as is `random` in the flat style (below).
    const desk_variant = deskVariantFor(args.color, app.config.@"macos-pane-style");

    const window = app.createWindow(.{
        // A viewer first pane has no shell for these to configure; passing them
        // anyway would describe a spawn that is not happening.
        .surface_overrides = if (viewer_open != null) null else &overrides,
        .viewer_open = viewer_open,
        .ipc_name = args.target,
        .desk_variant = desk_variant,
        // T1797: background unless `--focus` - shown without activation,
        // behind Ghoztty's frontmost window, no keyboard focus moved.
        .background = !args.focus,
    }) catch |err| {
        log.warn("IPC new-window failed err={}", .{err});
        return .{ .failed = "failed to create window" };
    };

    // T1612: answer once the first pane's agent session is bound, so the
    // caller's next `+list --json` can read its `session_id`. A viewer or a
    // plain local pane has nothing to bind and settles on the first poll.
    if (viewer_open == null and window.tab_count > 0)
        app.ipc_session_await.add(window.tab_active_pane[0].paneId());

    // T968: register the first pane — terminal or viewer — under `--name`,
    // so the next `--target=<name>` finds it.
    if (first_pane_name) |n| {
        if (window.tab_count > 0) app.ipcRegister(n, .{ .pane = window.tab_active_pane[0] }) catch {};
    }

    // T92: an empty `--title=` means "no pin", not "pin empty".
    if (args.title) |title| {
        if (title.len > 0) window.setTitleOverride(title);
    }

    // `--color` (T67): tint the window's first surface — background +
    // contrast foreground + WCAG-adjusted palette (Mac applyColorScheme).
    // Not when the color became the window's gradient (T1832).
    if (desk_variant == null) {
        if (resolveColor(args.color)) |tint| if (window.tab_count > 0) {
            if (window.tab_active_pane[window.active_tab].surface()) |s|
                s.applyBackgroundTint(tint, true);
        };
    }

    // `--focus` (T1797): the old raise. Without it the window was already
    // shown in the background by its first tab, and nothing here touches it.
    if (args.focus) if (window.hwnd) |hwnd| raiseWindow(hwnd);

    // Inline split (`--split=<dir>`, `--split-command`, `--name`); its
    // direction was checked before the window opened. A split that fails
    // leaves the window, which is what was asked for, so the reply stays
    // `created`.
    if (plan.split) |split_dir| {
        const dir = treeDirection(split_dir);

        var split_env: std.ArrayList(Surface.Overrides.EnvVar) = .empty;
        if (args.target) |t| {
            try split_env.append(arena, .{ .key = "GHOZTTY_WINDOW_NAME", .value = t });
        }
        if (args.name) |n| {
            try split_env.append(arena, .{ .key = "GHOZTTY_PANE_NAME", .value = n });
        }
        // T99: the inline split inherits the window's agent-backing. Mirror
        // handleSplit — no explicit `--split-command` ⇒ a null baton so
        // newSplit's `buildRemoteInherit` injects the agent and inherits the
        // first pane's cwd; otherwise a `.remote{local_agent}` override carrying
        // the agent-native command plus the pane-name env.
        const split_cmd = nonEmpty(args.split_command);
        const split_overrides: ?Surface.Overrides = if (window.local_agent_conn) |conn| ov: {
            if (split_cmd == null) break :ov null;
            break :ov .{
                .remote = .{
                    .connection = conn,
                    .command = split_cmd,
                    .command_argv = try keepAliveArgv(ctx, arena, args.shell, args.split_command),
                    .local_agent = true,
                },
                .env = split_env.items,
            };
        } else .{
            .command_argv = if (args.split_command) |cmd|
                try wrapCommandArgv(ctx, arena, args.shell, cmd)
            else
                null,
            .env = split_env.items,
        };
        if (split_overrides) |*ov| window.pending_surface_overrides = ov;
        defer window.pending_surface_overrides = null;
        // T1797: without `--focus` the window's first pane keeps the keyboard,
        // so it is the pane that has it when the user activates the window
        // (Mac's `keepingFirstResponder`). With it, the split is focused as it
        // always was.
        window.split_background = !args.focus;
        defer window.split_background = false;
        const new_surface = window.newSplit(dir) catch |err| blk: {
            log.warn("IPC inline split failed err={}", .{err});
            break :blk null;
        };
        if (new_surface) |s| {
            // `--split-color` (T67): explicit tint for the inline split
            // (overwrites the parent tint newSplitAt inherited, if any).
            if (resolveColor(args.split_color)) |tint| s.applyBackgroundTint(tint, true);
            if (args.name) |n| if (s.pane_view) |pv| app.ipcRegister(n, .{ .pane = pv }) catch {};
            if (s.pane_view) |pv| app.ipc_session_await.add(pv.paneId()); // T1612
        }
    }

    return .{ .created = try handoffNote(ctx, arena, request) };
}

/// `+split` is the shared body in `apprt/ipc/verbs.zig` (T3375): the name
/// collision check (T2184/T2250), `--percent` and `--direction`, where the
/// split lands, `--focus`, and the reply and its log line. What is win32's is
/// the model below - above all `createSplit`, which builds the pane.
pub fn handleSplit(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.split(@This(), ctx, request);
}

// ---------------------------------------------------------------------------
// The create verbs' model (apprt/ipc/verbs.zig, T3375).

pub const WindowHandle = *Window;
pub const PaneHandle = *PaneView;

pub fn windowOfTarget(entry: Target) *Window {
    return targetWindow(entry);
}

pub fn paneOfTarget(entry: Target) ?*PaneView {
    return switch (entry) {
        .pane => |pane| pane,
        .window => null,
    };
}

pub fn paneTarget(pane: *PaneView) Target {
    return .{ .pane = pane };
}

pub fn paneWindow(pane: *PaneView) *Window {
    return pane.parentWindow();
}

pub fn activePane(window: *Window) ?*PaneView {
    if (window.tab_count == 0) return null;
    return window.tab_active_pane[window.active_tab];
}

pub fn defaultWindow(ctx: Context) ?*Window {
    return frontWindow(ctx.app);
}

pub fn callerPane(ctx: Context, args: VerbArgs) ?*PaneView {
    return callerAnchorPaneView(ctx.app, args);
}

pub fn paneId(pane: *PaneView) []const u8 {
    return pane.paneId();
}

pub fn windowName(_: Context, window: *Window) ?[]const u8 {
    return window.ipc_name;
}

/// What holds `name` where a `+split --name=` into `window` would put it
/// (`App.ipcHolderIn`). Null for a viewer with nothing loaded yet: nothing to
/// compare against, so the name stays the existing pane's and the split goes
/// ahead, as on the Mac.
pub fn nameHolderIn(ctx: Context, name: []const u8, window: *Window) ?verbs.NameHolder(Target) {
    const entry = ctx.app.ipcHolderIn(name, window) orelse return null;
    return .{ .target = entry, .existing = describeExisting(entry) orelse return null };
}

fn describeExisting(entry: App.IpcTarget) ?split_name_collision.Existing {
    const holder: *Window = switch (entry) {
        .window => |w| w,
        .pane => |pane| pane.parentWindow(),
    };
    const kind: split_name_collision.Existing.Kind = switch (entry) {
        .window => .window,
        .pane => |pane| if (pane.viewer()) |viewer| kind: {
            const home: ?[]const u8 = if (viewer.home_location) |h| h else null;
            const location: []const u8 = if (viewer.location) |l| l else home orelse return null;
            break :kind .{ .viewer = .{ .location = location, .home_location = home } };
        } else .terminal,
    };
    return .{
        .kind = kind,
        .window_name = holder.ipc_name orelse "",
    };
}

fn treeDirection(dir: verbs.SplitDirection) SplitTree.Split.Direction {
    return switch (dir) {
        .right => .right,
        .down => .down,
        .left => .left,
        .up => .up,
    };
}

/// Open the pane `+split` asked for at `at`: the new pane, registered under
/// `--name` and awaited for its agent session (T1612), or null when none
/// opened. The new pane does not take the keyboard unless `--focus` (T1797):
/// the pane that had it - normally the caller's own - keeps it.
pub fn createSplit(
    ctx: Context,
    arena: Allocator,
    args: VerbArgs,
    window: *Window,
    at: *PaneView,
    spec: verbs.SplitSpec,
) Allocator.Error!?*PaneView {
    const app = ctx.app;
    const direction = treeDirection(spec.direction);
    window.split_background = !args.focus;
    defer window.split_background = false;

    // `--from-focused` (T68): the keyboard split, passing NO overrides so
    // remote inheritance (same connection + parent command/cwd) is never
    // suppressed (Mac rule). Like the Mac, `--name`/tint plumbing is skipped.
    if (spec.inherit) {
        const inherited = window.newSplitAt(at, direction, spec.ratio) catch |err| {
            log.warn("IPC split --from-focused failed err={}", .{err});
            return null;
        } orelse return null;
        const pv = inherited.pane_view orelse return null;
        app.ipc_session_await.add(pv.paneId()); // T1612
        return pv;
    }

    // `--view` (T374): a VIEWER split. Everything below describes a shell -
    // the overrides, the remote/agent inheritance, the background tint a
    // terminal reads against - and a viewer has none of it.
    if (args.view) |view| if (nonEmpty(view)) |location| {
        // `--working-directory` is the ORIGIN DIRECTORY here, not a cwd:
        // `+split --view=` seeds it with the caller's cwd for exactly this
        // (`cli/split.zig:seedViewWorkingDirectory`).
        const pane = window.newViewerSplitAt(at, direction, spec.ratio, .{
            .location = location,
            .origin_directory = nonEmpty(args.working_directory),
        }) catch |err| {
            log.warn("IPC viewer split failed err={}", .{err});
            return null;
        } orelse return null;
        if (args.name) |name| app.ipcRegister(name, .{ .pane = pane }) catch {};
        return pane;
    };

    // Surface overrides for the new pane.
    var env: std.ArrayList(Surface.Overrides.EnvVar) = .empty;
    try env.appendSlice(arena, args.env);
    if (window.ipc_name) |wn| {
        try env.append(arena, .{ .key = "GHOZTTY_WINDOW_NAME", .value = wn });
    }
    if (args.name) |n| {
        try env.append(arena, .{ .key = "GHOZTTY_PANE_NAME", .value = n });
    }
    const command = args.split_command orelse args.command;

    // T68: a split in a REMOTE window opens a fresh session on the same
    // machine/connection, never a local ConPTY pane. Explicit
    // `--command`/`--working-directory` are REMOTE-native (never wrapped by
    // the local shell table - the agent applies its own shell's convention);
    // a `-e` argv is joined into one command line for the agent's shell.
    // `--shell` alone counts as an explicit value (T1665: it used to take the
    // inherit shortcut below and be dropped without a word).
    // With no explicit values we pass NO overrides at all, so newSplitAt's
    // inheritance (parent pane's command + cwd) applies, like the Mac.
    const remote_command: ?[]const u8 = if (args.e_args.len > 0)
        try joinArgv(arena, args.e_args)
    else
        nonEmpty(command);

    // T515: a split opens where its PARENT pane is unless `--working-directory`
    // says otherwise - and an explicit `--command` must not cost it that. The
    // override branches below used to carry a null cwd whenever no path was
    // passed, and what filled it in was the CORE's own inheritance, which is
    // app-GLOBAL (`apprt/surface.zig` `newConfig` reads `app.focusedSurface`):
    // it answers with whatever pane last had focus - another window's pane when
    // one is in front, and the shell's home when nothing is focused at all -
    // and a cross-machine window never gets even that, because a local path is
    // withheld from a remote agent (`termio.Remote.openWorkingDirectory`). So
    // resolve the split-parent's live cwd here, through the same GET_CWD
    // `Window.buildRemoteInherit` uses. Only when there IS an override to fill:
    // with nothing explicit the branches break to a null baton and
    // `buildRemoteInherit` does this itself.
    //
    // T3754: on THIS machine the parent's folder crosses only within its shell
    // family (`shell_family.inherit`) - a WSL pane's folder means nothing to a
    // Windows shell - and a Linux `--working-directory` is never a process
    // cwd: a WSL shell takes it as `--cd` (`wsl_folder` below).
    const family = childFamily(ctx, args, command);
    const split_cwd: ?[]const u8 = if (window.remote_dialed != null)
        nonEmpty(args.working_directory)
    else
        processFolder(args.working_directory);
    const process_cwd: ?[]const u8 = split_cwd orelse inherited: {
        if (nonEmpty(args.working_directory) != null) break :inherited null;
        if (remote_command == null and nonEmpty(args.shell) == null) break :inherited null;
        const parent = at.surface() orelse break :inherited null;
        if (window.remote_dialed) |d| break :inherited Window.inheritedCwd(arena, d.conn(), parent);
        const conn = window.local_agent_conn orelse break :inherited null;
        if (family != .windows) break :inherited null;
        break :inherited parent.inheritFolder(arena, .windows, Window.inheritedCwd(arena, conn, parent));
    };
    // The Linux folder a WSL pane starts in: the one asked for, else - opened
    // from a WSL pane - that pane's own (its OSC 7 report), else `~`.
    const wsl_folder: ?[]const u8 = explicitFolder(args) orelse inherited: {
        if (family != .wsl or window.remote_dialed != null) break :inherited null;
        const parent = at.surface() orelse break :inherited null;
        break :inherited parent.inheritFolder(arena, .wsl, parent.reportedPwd(arena));
    };

    const overrides: ?Surface.Overrides = if (window.remote_dialed) |dialed| ov: {
        if (remote_command == null and nonEmpty(args.working_directory) == null and
            nonEmpty(args.shell) == null)
            break :ov null; // full inheritance in newSplitAt
        break :ov .{
            .remote = .{
                .connection = dialed.conn(),
                .working_directory = process_cwd,
                .shell = nonEmpty(args.shell),
                .command = remote_command,
            },
            .env = env.items,
        };
    } else if (window.local_agent_conn) |conn| ov: {
        // T99: a split in a LOCAL persistence window opens a fresh AGENT session
        // (survives the app), never a plain ConPTY - mirrors the remote_dialed
        // branch. No explicit command/cwd => a null baton so newSplitAt's
        // `buildRemoteInherit` injects the agent and inherits the split-parent
        // pane's cwd; otherwise a `.remote{local_agent}` override carrying the
        // agent-native command + the name env.
        if (remote_command == null and nonEmpty(args.working_directory) == null and
            nonEmpty(args.shell) == null)
            break :ov null;
        break :ov .{
            .remote = .{
                .connection = conn,
                .working_directory = process_cwd,
                .shell = agentShell(args.shell),
                .command = remote_command,
                .command_argv = try localAgentArgv(ctx, arena, args.e_args, args.shell, command, wsl_folder),
                .local_agent = true,
            },
            .env = env.items,
        };
    } else .{
        .command_argv = try execArgv(ctx, arena, args.e_args, command, args.shell, wsl_folder),
        .working_directory = split_cwd,
        .env = env.items,
    };

    if (overrides) |*ov| window.pending_surface_overrides = ov;
    defer window.pending_surface_overrides = null;
    const new_surface = window.newSplitAt(at, direction, spec.ratio) catch |err| {
        log.warn("IPC split failed err={}", .{err});
        return null;
    } orelse return null;

    // `--color` (T67): explicit tint for the new pane - bg + contrast fg +
    // adjusted palette (overwrites the parent tint newSplitAt inherited).
    if (resolveColor(args.color)) |tint| new_surface.applyBackgroundTint(tint, true);

    const pv = new_surface.pane_view orelse return null;
    if (args.name) |name| app.ipcRegister(name, .{ .pane = pv }) catch {};

    // T1612: answer once the new pane's agent session is bound (see
    // `ipc_session_await.zig`), so `+list --json` right after reads it.
    app.ipc_session_await.add(pv.paneId());
    return pv;
}

/// Whether `pane` is on show in `window` as laid out now: false when its row
/// has no room and it is minimized to a strip, null when the window has no
/// layout for it (not in any tab, or no client area yet).
pub fn paneOnShow(window: *Window, pane: *PaneView) ?bool {
    for (0..window.tab_count) |i| {
        var panes = window.tab_trees[i].iterator();
        while (panes.next()) |v| {
            if (v.view != pane) continue;
            var grid = window.stackGridForTab(i) orelse return null;
            defer grid.deinit();
            const p = grid.placement(pane_stack_grid.viewId(pane)) orelse return null;
            return !p.is_tucked;
        }
    }
    return null;
}

/// T1612: whether every pane in `list` lets the reply go out — gone, a viewer,
/// a plain local pane, or an agent-backed pane whose OPEN/ATTACH has finished
/// (bound or failed). GUI thread only: it walks the live pane set.
pub fn sessionsSettled(app: *App, list: *const IpcSessionAwait) bool {
    for (0..list.n) |i| {
        const entry = app.ipcLookup(list.get(i).id()) orelse continue;
        const pane = switch (entry) {
            .pane => |p| p,
            .window => continue,
        };
        const surface = pane.surface() orelse continue;
        if (!surface.core_surface_ready) return false;
        if (surface.core_surface.remoteBringUpPending()) return false;
    }
    return true;
}

pub fn handleRead(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.read(@This(), ctx, request);
}

/// `+set-state` and `+set-banner` (T35) are the shared bodies in
/// `apprt/ipc/verbs.zig` (T3374), over the window-or-pane model below.
pub fn handleSetState(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.setState(@This(), ctx, request);
}

pub fn handleSetBanner(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.setBanner(@This(), ctx, request);
}

/// `+reload` (T390): reload a named VIEWER pane's content in place. Website
/// viewers re-fetch from origin bypassing caches; file viewers re-render
/// preserving scroll. A window target reloads its focused pane.
///
/// The two terminal refusals are Mac's `handleReload` strings and they are
/// DIFFERENT from each other on purpose: naming a terminal pane is a mistake
/// about that pane, while naming a window whose focused pane happens to be a
/// terminal is a mistake about which pane has focus, and the fix for each is
/// not the same. Neither is the `is a viewer pane, not a terminal` string the
/// terminal-only verbs use — that one points the opposite way.
///
/// The body is shared with the Linux app (`verbs.reload`, T3413); the model is
/// the two functions below.
pub fn handleReload(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.reload(@This(), ctx, request);
}

/// `+reload --config` (T893): re-read the configuration from disk, exactly as
/// the menu's Reload Configuration does - a HARD reload.
pub fn reloadConfig(ctx: Context, arena: Allocator) Allocator.Error!?[]const u8 {
    _ = ctx.app.performAction(.app, .reload_config, .{ .soft = false }) catch |err| {
        return try std.fmt.allocPrint(arena, "config reload failed: {}", .{err});
    };
    return null;
}

/// `+reload` is the explicit "these bytes are stale" verb, so it bypasses
/// caches rather than reloading in place (T601's `ReloadReason`).
pub fn reloadViewer(entry: Target) verbs.ReloadOutcome {
    const view = switch (entry) {
        .pane => |pane| pane.viewer() orelse return .terminal,
        .window => w: {
            const pane = targetPane(entry) orelse return .gone;
            break :w pane.viewer() orelse return .focused_terminal;
        },
    };
    view.reloadContent(.chrome);
    return .reloaded;
}

/// `focus` — raise the window owning `--target` and focus the pane within it,
/// or do nothing at all if the target names nothing currently open. The whole
/// of what the `ghoztty://` URL scheme can do (T695; `apprt/ipc/url_scheme.zig`
/// carries the reasoning for why that is the only verb).
///
/// **There is deliberately no `+focus` CLI verb**, on either platform: the Mac
/// half reaches `IPCServer.focusTarget` straight from its LaunchServices
/// callback, and a verb that exists on one CLI and not the other is the
/// divergence this project does not ship. This is the wire action the Windows
/// URL launcher sends, and nothing else calls it.
///
/// It never creates: a link that LAUNCHED nothing finds an empty registry and
/// correctly answers "not found" rather than opening a window as a side effect,
/// which would smuggle window creation back into the scheme's surface.
pub fn handleFocus(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.focus(@This(), ctx, request);
}

/// `+rename` is the shared body in `apprt/ipc/verbs.zig` (T3375).
pub fn handleRename(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.rename(@This(), ctx, request);
}

/// Pin `title` on the target's window (null clears the pin, T92): the
/// override wins over terminal-reported titles until cleared (Mac
/// BaseTerminalController.titleOverride). T2404: a title the user typed
/// outranks any script's - it is left alone and reported (the skills that tag
/// a title, `(prep)`/`(ready)`, ignore a failed rename). Checked and set on
/// this one UI-thread turn, so a user rename cannot land between them (Mac
/// IPCServer `onMain`).
pub fn renameWindow(_: Context, entry: Target, title: ?[]const u8) verbs.Renamed {
    const window = targetWindow(entry);
    if (window_title_owner.keptFromScript(window.title_override, window.title_set_by_user)) |kept|
        return .{ .kept = kept };
    window.setTitleOverride(title);
    return .renamed;
}

/// `+send-keys` and `+read` are the shared bodies in `apprt/ipc/verbs.zig`
/// (T3361), over the model below. What stays here is only what is win32's:
/// the registry lookup, the ambiguity sentence, and that a ConPTY needs LF
/// mapped to CR.
pub fn handleSendKeys(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.sendKeys(@This(), ctx, request);
}

// ---------------------------------------------------------------------------
// The shared verbs' model (apprt/ipc/verbs.zig).

pub const Terminal = apprt.ipc.CoreTerminal;
pub const input_line_ends: verbs.LineEnds = .conpty;

pub fn replyAllocator(ctx: Context) Allocator {
    return ctx.alloc;
}

/// What a `--target`/`--name` names, by the IPC registry. T181: a pane that
/// died and a pane whose terminal never came up are different states.
/// `core_surface_ready` is false for both; `core_surface_initialized` is set
/// together with it at the end of init, so it stays false only when init
/// never completed.
pub fn lookupTerminal(ctx: Context, name: []const u8) verbs.Lookup(Terminal) {
    const entry = ctx.app.ipcLookup(name) orelse return .not_found;
    const pane = targetPane(entry) orelse return .gone;
    const surface = pane.surface() orelse return .viewer;
    if (!surface.core_surface_ready)
        return if (surface.core_surface_initialized) .gone else .not_started;
    return .{ .ready = .{ .core = &surface.core_surface } };
}

/// A name nothing answers to may be one several windows hold (T2250).
pub fn notFoundResponse(ctx: Context, name: []const u8, fallback: []const u8) Allocator.Error![]u8 {
    return missingResponse(ctx, name, "{s}", .{fallback});
}

/// The window the user is most plausibly working in: the ACTIVE window if it
/// is one of ours, else the most recently created one.
///
/// "Active" rather than "foreground" since T215: on a background desktop
/// there is no foreground window at all, so the old reading matched nothing
/// and every default-target verb silently fell through to "most recently
/// created" — which is not the same window as soon as a test opens two.
/// `window_active.isActive` keeps the interactive answer byte-identical.
pub fn frontWindow(app: *App) ?*Window {
    const activation = w32.activation();
    for (app.windows.items) |window| {
        if (window.is_quick_terminal) continue;
        if (window_active.isActive(activation, @intFromPtr(window.hwnd)))
            return window;
    }
    var i = app.windows.items.len;
    while (i > 0) {
        i -= 1;
        const window = app.windows.items[i];
        if (!window.is_quick_terminal) return window;
    }
    return null;
}

/// The pane a `+split`/`+rearrange` with no explicit anchor was invoked FROM
/// (`--caller-pane=`, seeded from `$GHOZTTY_PANE_ID` by `apprt.ipc.seedCallerPane`),
/// or null to keep the `frontWindow` fallback below it. T1079; the Mac twin is
/// `IPCServer.callerAnchorPane`.
///
/// The precedence rule itself is pure and unit tested (`verb_args.callerAnchorPane`);
/// this is only the live-registry half of it. Resolving to a WINDOW rather than a
/// pane counts as unresolved: the caller pane is always a pane id, so a name that
/// answers with a window is a registry collision, not the caller.
pub fn callerAnchorPaneView(app: *App, args: VerbArgs) ?*PaneView {
    // The lookup that decides `isAlive` also HANDS BACK the pane, so the
    // registry is walked once rather than once to test and once to use.
    const Resolver = struct {
        app: *App,
        found: ?*PaneView = null,

        fn isAlive(self: *@This(), name: []const u8) bool {
            const entry = self.app.ipcLookup(name) orelse return false;
            switch (entry) {
                .pane => |pane| {
                    self.found = pane;
                    return true;
                },
                .window => return false,
            }
        }
    };
    var resolver: Resolver = .{ .app = app };
    _ = verb_args.callerAnchorPane(args, &resolver, Resolver.isAlive) orelse return null;
    return resolver.found;
}

/// `+close` is the shared body in `apprt/ipc/verbs.zig` (T3374), over the
/// window-or-pane model below.
pub fn handleClose(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.close(@This(), ctx, request);
}

// ---------------------------------------------------------------------------
// The window-or-pane verbs' model (apprt/ipc/verbs.zig, T3374): +close,
// focus, +set-state, +set-banner. `focusTarget` above is its focus half.

pub const Target = App.IpcTarget;

/// What a name means by the IPC registry, or the T2250 ambiguity sentence
/// when panes in several windows hold it and none is the caller's.
pub fn lookupTarget(ctx: Context, arena: Allocator, name: []const u8) Allocator.Error!verbs.TargetLookup(Target) {
    if (ctx.app.ipcLookup(name)) |entry| return .{ .found = entry };
    if (try ctx.app.ipcAmbiguity(arena, name)) |msg| return .{ .ambiguous = msg };
    return .not_found;
}

fn targetWindow(entry: Target) *Window {
    return switch (entry) {
        .pane => |pane| pane.parentWindow(),
        .window => |w| w,
    };
}

/// A confirmation dialog is up over the target's window (T2938): its modal
/// loop is on the stack below this dispatch.
pub fn closeConfirmationOpen(entry: Target) bool {
    const hwnd = targetWindow(entry).hwnd orelse return false;
    return ConfirmDialog.openOver(hwnd) > 0;
}

/// `--force` answers the dialog (Cancel), and the close runs once its modal
/// loop has unwound - see `App.forceCloseDeferred`. Closing here would tear
/// the window out from under the loop still on this stack.
pub fn dismissConfirmations(ctx: Context, entry: Target, name: []const u8) verbs.Dismissed {
    const window = targetWindow(entry);
    const dialogs = if (window.hwnd) |h| ConfirmDialog.dismissOver(h) else 0;
    const queued = ctx.app.forceCloseDeferred(.{
        .window = window,
        .pane = switch (entry) {
            .pane => |pane| pane,
            .window => null,
        },
    });
    if (!queued) return .queue_full;
    log.info("IPC: +close --force '{s}': dismissed {d} dialog(s); closing once they unwind", .{ name, dialogs });
    return .closing;
}

/// Close without confirmation (the CLI drives teardown; the Mac server's
/// withConfirmation:false / closeWindowImmediately). Registry entries drop
/// via ipcForget in the destroy paths. `--force` (T2938) also skips the undo
/// window: nothing is parked, every session ENDS and every core is freed now.
pub fn closeTarget(_: Context, entry: Target, force: bool) bool {
    const window = targetWindow(entry);
    switch (entry) {
        .pane => |pane| if (force) window.forceCloseSplitPane(pane) else window.closeSplitPane(pane),
        .window => if (force) window.forceClose() else window.close(),
    }
    return true;
}

/// A pane target sets that pane; a window target sets every terminal pane in
/// the window. False for a viewer pane target.
pub fn setActivityState(entry: Target, state: verbs.ActivityState) bool {
    const core_state: terminal.osc.Command.ActivityState = switch (state) {
        .idle => .idle,
        .busy => .busy,
        .needs_input => .needs_input,
    };
    switch (entry) {
        .pane => |pane| {
            const surface = pane.surface() orelse return false;
            surface.activity_state = core_state;
            surface.parent_window.updateWindowTitle();
        },
        .window => |window| {
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |view_entry| {
                    const surface = view_entry.view.surface() orelse continue;
                    surface.activity_state = core_state;
                }
            }
            window.updateWindowTitle();
        },
    }
    return true;
}

/// The banner of the target's pane (a window's focused pane).
pub fn setPaneBanner(entry: Target, text: ?[]const u8) verbs.BannerSet {
    const pane = targetPane(entry) orelse return .no_pane;
    const surface = pane.surface() orelse return .viewer;
    surface.setPaneBanner(text);
    return .set;
}

test {
    _ = ProcessTree;
}
