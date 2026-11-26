//! `+list` for the win32 apprt (T1782, split from IpcHandlers.zig): the
//! window/tab/pane tree the CLI prints, `--pid` ancestry lookup, and the
//! published chrome geometry. The split-tree walk itself is shared with the
//! Linux app (`verbs.listSplitNode`, T3375); this file is win32's model of it.
const std = @import("std");
const Allocator = std.mem.Allocator;

const IpcHandlers = @import("IpcHandlers.zig");
const Context = IpcHandlers.Context;
const apprt = @import("../../apprt.zig");
const ipc_server = apprt.ipc.server;
const Request = ipc_server.Request;
const errorResponse = ipc_server.errorResponse;
const nonEmpty = ipc_server.nonEmpty;
const verb_args = apprt.ipc.args;
const parseVerbArgs = verb_args.parseVerbArgs;
const verbs = apprt.ipc.verbs;

const App = @import("App.zig");
const PaneView = @import("PaneView.zig");
const ProcessTree = @import("ProcessTree.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree(PaneView);
const color_math = @import("color_math.zig");
const pane_stack_grid = @import("pane_stack_grid.zig");
const pane_stash = @import("pane_stash.zig");
const provenance = @import("provenance.zig");
const tab_strip = @import("tab_strip_layout.zig");
const w32 = @import("win32.zig");
const window_active = @import("window_active.zig");
const window_title_owner = @import("window_title_owner.zig");

const log = std.log.scoped(.win32_ipc);

pub fn handleList(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    const app = ctx.app;

    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);

    // `--pid=<pid>`: resolve the pane whose shell is an ancestor of the
    // given process (the Windows equivalent of the Mac's `--tty` — panes
    // have no tty here). Answers with data.match = the pane's name.
    if (args.pid) |query_pid| {
        var pid_map = try ProcessTree.snapshot(arena);
        for (app.windows.items) |window| {
            if (window.is_quick_terminal) continue;
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |entry| {
                    // A viewer runs no shell, so it can never be the pane a
                    // pid lives in.
                    const surface = entry.view.surface() orelse continue;
                    const shell_pid = surfaceShellPid(surface);
                    if (shell_pid == 0) continue;
                    if (!ProcessTree.isAncestor(&pid_map, shell_pid, query_pid)) continue;
                    const name = app.ipcNameOf(.{ .pane = entry.view }) orelse name: {
                        // Register the fallback name so the returned value is
                        // immediately usable as a target, matching buildNode.
                        const id = try arena.dupe(u8, entry.view.paneId());
                        app.ipcRegister(id, .{ .pane = entry.view }) catch {};
                        break :name id;
                    };
                    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
                    errdefer out.deinit();
                    var jws: std.json.Stringify = .{ .writer = &out.writer };
                    write: {
                        jws.beginObject() catch break :write;
                        jws.objectField("success") catch break :write;
                        jws.write(true) catch break :write;
                        jws.objectField("data") catch break :write;
                        jws.beginObject() catch break :write;
                        jws.objectField("match") catch break :write;
                        jws.write(name) catch break :write;
                        jws.endObject() catch break :write;
                        jws.endObject() catch break :write;
                        return try out.toOwnedSlice();
                    }
                    return error.OutOfMemory;
                }
            }
        }
        // T153: name the better route in the failure. A pane whose shell pid
        // is unknown (a cross-machine pane, a surface still starting up) can
        // never match, so a process inside one gets this error through no
        // fault of its own — and $GHOZTTY_PANE_ID is baked into every pane's
        // env precisely so it never needs pid ancestry to name itself.
        return try errorResponse(
            ctx.alloc,
            "no pane found for pid {d}: no pane's shell is an ancestor of that " ++
                "process (panes with no known shell pid cannot match). From inside " ++
                "a pane, $GHOZTTY_PANE_ID names the pane directly.",
            .{query_pid},
        );
    }

    // T215: `focused` is the ACTIVE window, not `GetForegroundWindow() ==
    // hwnd`. Off the input desktop the latter is null for every window, so
    // `+list --json` used to report no focused window at all — a caller
    // cannot tell that apart from "the app lost focus".
    const activation = w32.activation();

    var window_list: std.ArrayList(apprt.ipc.List.Window) = .empty;
    for (try listOrder(arena, app)) |window| {
        // Quick terminals are not listable/addressable targets.
        if (window.is_quick_terminal) continue;
        const id = listId(app, window) orelse continue;

        var tabs: std.ArrayList(apprt.ipc.List.Tab) = .empty;
        for (0..window.tab_count) |i| {
            const tab_title = try utf16ToUtf8Arena(
                arena,
                window.tab_titles[i][0..window.tab_title_lens[i]],
            );
            var grid = window.stackGridForTab(i);
            defer if (grid) |*g| g.deinit();
            const node = try verbs.listSplitNode(SplitTree, arena, &window.tab_trees[i], .root, ListLeaves{
                .ctx = ctx,
                .active_pane = window.tab_active_pane[i],
                .grid = if (grid) |*g| g else null,
            });
            try tabs.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "{d}", .{i}),
                .title = tab_title,
                .index = @intCast(i),
                .selected = i == window.active_tab,
                .splits = node,
            });
        }

        // The title as of now, one held while the window is hidden included
        // (T2912): a covered window's caption lags, `+list` never does.
        var title_buf: [512]u16 = undefined;
        const win_title = try utf16ToUtf8Arena(arena, window.currentTitle(&title_buf));

        try window_list.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "{d}", .{id}),
            .title = win_title,
            .target = window.ipc_name,
            // A parked workspace has no window to be active (T3185).
            .focused = if (window.hwnd) |hwnd|
                window_active.isActive(activation, @intFromPtr(hwnd))
            else
                false,
            .tabs = tabs.items,
            .title_set_by_user = window_title_owner.keptFromScript(window.title_override, window.title_set_by_user) != null,
            .chrome = try windowChrome(arena, window),
            // T609: a cross-machine window publishes its reconnect ladder's
            // state; a local one has no link to report on, and the absent
            // field is what says so.
            .connection = if (window.hasRemotePill())
                window.reconnect.ladder.listConnection()
            else
                null,
            // T1557: the machine the window is on, named exactly as its pill
            // names it; absent for a local window (no machine record). Copied
            // into the arena because a relay listing can rename the machine
            // in place (`adoptRelayNames`).
            .machine = if (apprt.ipc.List.machineField(window.machineDisplayName())) |m|
                try arena.dupe(u8, m)
            else
                null,
        });
    }

    const prov = try provenance.collect(arena);
    const json = (apprt.ipc.List{
        .windows = window_list.items,
        .build = .{
            .version = prov.version,
            .commit = prov.commit,
            .mode = prov.mode,
            .runtime = prov.runtime,
            .update_check = prov.update_check,
            .exe = prov.exe,
            .exe_modified = prov.exe_modified,
            .pid = prov.pid,
        },
    }).serializeResponse(arena) catch
        return error.OutOfMemory;
    return try ctx.alloc.dupe(u8, json);
}

/// The windows `+list` reports, in its order (T3185, Mac
/// `everyControllerFrontToBack`). In single-window mode every workspace is a
/// window to the CLI: the one on show first, then the parked ones most
/// recently shown first - a parked workspace has no HWND, and enumerating
/// HWNDs is what used to drop it. Anything the workspace host does not manage
/// (every window, in `separate` mode) follows in creation order.
fn listOrder(arena: Allocator, app: *App) Allocator.Error![]const *Window {
    var out: std.ArrayList(*Window) = .empty;
    for (app.workspaces.order.items) |w| try out.append(arena, w);
    for (app.windows.items) |w| {
        if (!app.workspaces.manages(w)) try out.append(arena, w);
    }
    return out.items;
}

/// A window's `+list` id (T3185). In `separate` mode it is the HWND, which
/// lives exactly as long as the window and is what scripts hand to win32. A
/// workspace's is its controller's instead (Mac `ScriptWindow.stableID`): the
/// one shared HWND changes hands, so it would name a different workspace after
/// every switch and none at all while parked. Null for a window with no HWND
/// that is not a workspace (one being torn down), which is not listed.
fn listId(app: *App, window: *Window) ?usize {
    if (app.workspaces.manages(window)) return @intFromPtr(window);
    return if (window.hwnd) |h| @intFromPtr(h) else null;
}

/// This window's published chrome geometry (T231): the tab strip's hit
/// regions, in client coordinates, exactly as the window's own hit tests hold
/// them. A test asks for these instead of re-implementing `tab_strip_layout`
/// in PowerShell, which is a second source of truth for a layout the product
/// owns and had already rotted twice.
///
/// The rects come from `Window.stripRegions`, which does no arithmetic of its
/// own beyond moving them into client coordinates — so this cannot report
/// something the window would not hit.
fn windowChrome(arena: Allocator, window: *Window) Allocator.Error!apprt.ipc.List.Chrome {
    const dpi: i64 = @intFromFloat(@round(window.scale * 96.0));
    // A parked workspace (T3185) has no strip on screen: nothing to hit.
    if (window.hwnd == null) return .{ .dpi = dpi };
    const regions = window.stripRegions() orelse return .{ .dpi = dpi };

    // An EMPTY rect is `null` on the wire: "there is nothing here to hit" —
    // the "≡" on a caption window (T260), a tab that did not fit, and every
    // region of a strip that has not painted yet. A consumer that took a
    // zero rect's center would click x = 0, which is tab 1.
    const rect = struct {
        fn opt(r: tab_strip.Rect) ?apprt.ipc.List.Rect {
            if (r.isEmpty()) return null;
            return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
        }
    };

    const tabs = try arena.alloc(?apprt.ipc.List.Rect, window.tab_count);
    for (tabs, 0..) |*t, i| t.* = rect.opt(regions.tabs[i]);

    return .{
        .dpi = dpi,
        .tab_strip = .{
            .band = .{
                .left = regions.band.left,
                .top = regions.band.top,
                .right = regions.band.right,
                .bottom = regions.band.bottom,
            },
            .tabs = tabs,
            .new_tab = rect.opt(regions.new_tab),
            .new_tab_menu = rect.opt(regions.new_tab_menu),
            .menu = rect.opt(regions.menu),
        },
    };
}

/// The leaves of one tab's `+list` split tree, for the shared walk
/// (`verbs.listSplitNode`, T3375). Every leaf is auto-registered under its
/// fallback name (the surface id), matching the Mac server.
const ListLeaves = struct {
    ctx: Context,
    active_pane: *PaneView,
    /// The tab's stacked layout, for `minimized` (T2103); null reports none.
    grid: ?*const pane_stack_grid.Grid,

    pub fn terminal(self: ListLeaves, arena: Allocator, pane: *PaneView) Allocator.Error!apprt.ipc.List.Terminal {
        const ctx = self.ctx;
        const active_pane = self.active_pane;
        const grid = self.grid;
        // A viewer leaf reports the Mac's additive `type`/`url` shape and
        // none of the terminal fields — it has no shell, no pwd, and no
        // banner (docs/claude/cli.md: `+list` marks viewer panes with a `view:`
        // prefix; JSON `"type": "viewer"` plus `"url"`).
        const surface = pane.surface() orelse {
            const vid = try arena.dupe(u8, pane.paneId());
            const vname = ctx.app.ipcNameOf(.{ .pane = pane }) orelse name: {
                ctx.app.ipcRegister(vid, .{ .pane = pane }) catch {};
                break :name vid;
            };
            const viewer = pane.viewer().?;
            return .{
                .id = vid,
                .title = viewer.title orelse "",
                .working_directory = "",
                .pid = 0,
                .tty = "",
                .name = vname,
                .focused = pane == active_pane,
                .exit_code = null,
                .pane_type = "viewer",
                .url = if (viewer.location) |loc| try arena.dupe(u8, loc) else null,
                .stashed = pane_stash.isStashed(pane),
                .minimized = isMinimized(grid, pane),
            };
        };
        // T113: the leaf `id` is the pane's stable ghoztty-owned id, the
        // same value its processes see as `$GHOZTTY_PANE_ID` and the same
        // shape the Mac reports (`pane.id.uuidString`). It used to be the
        // decimal `core_surface.id`, which changed on every re-attach and
        // matched nothing in the pane's environment.
        const id = try arena.dupe(u8, surface.paneId());
        const name = ctx.app.ipcNameOf(.{ .pane = pane }) orelse name: {
            ctx.app.ipcRegister(id, .{ .pane = pane }) catch {};
            break :name id;
        };
        // T111b: read the pane's CACHED working directory. This used to
        // call `core_surface.pwd()`, which takes that pane's renderer
        // mutex — under a flood the IO thread holds it nearly
        // continuously, so `+list`, the liveness probe every automation
        // bar here is written against, was the one call that queued
        // behind the flood (one handler measured at 29.3 s). Core pushes
        // every change to the cache as a `.pwd` action, so the only
        // value the cache can miss is the initial cwd termio sets at
        // startup with no action: the first `+list` to see a pane seeds
        // that, and no `+list` after it takes a terminal lock at all.
        const pwd: []const u8 = pwd: {
            // T185: a shell that never reports OSC 7 (cmd.exe) leaves
            // the cache frozen at its STARTING directory — ask the OS
            // for the shell process's real cwd instead, which tracks
            // the user's `cd`s. Null (shell reports OSC 7, no pid, or
            // read failure) falls through to the cached path. This is
            // two bounded syscall reads with no ghoztty lock, so the
            // T111b "no terminal mutex in +list" rule holds.
            if (surface.livePwd(arena)) |live| break :pwd live;
            if (surface.pwd) |cached| break :pwd cached;
            // Cache miss: this is the ONLY path in `+list` that can touch
            // a terminal lock, so GHOZTTY_PERF names the leaf and times
            // it — a miss that repeats every call is the whole bug back.
            const perf = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PERF");
            const t0: ?std.time.Instant =
                if (perf) (std.time.Instant.now() catch null) else null;
            const copy = surface.core_surface.pwd(arena) catch null;
            if (perf) perf: {
                const now = std.time.Instant.now() catch break :perf;
                const start = t0 orelse break :perf;
                log.info("ipcperf list pwd-miss name={s} ms={d} got={s}", .{
                    name,
                    now.since(start) / std.time.ns_per_ms,
                    if (copy != null) "yes" else "no",
                });
            }
            // Seed even when the terminal has NO pwd, or the miss repeats
            // forever: a pane launched without a working directory (every
            // `+split` that doesn't pass one) never gets a terminal pwd,
            // and re-asking put `+list` right back on that pane's mutex —
            // measured at 183/298/535/584 ms per call on a flooded pane
            // and, under the section-E double storm, a 68 s handler.
            // "No pwd" is a permanent answer, not a not-yet: the initial
            // pwd is set synchronously by `Termio.init` →
            // `backend.initTerminal`, so it is already there (or already
            // absent) before `core_surface_ready`, and every later change
            // arrives as a `.pwd` action.
            surface.setPwd(copy orelse "");
            break :pwd surface.pwd orelse "";
        };
        return .{
                .id = id,
                .title = surface.getTitle() orelse "",
                .working_directory = pwd,
                // The shell's process id. There is no tty name on
                // Windows (ConPTY); the Mac reports /dev/ttysNNN here.
                .pid = @intCast(surfaceShellPid(surface)),
                .tty = "",
                .name = name,
                .focused = pane == active_pane,
                .exit_code = null,
                .background_tint = if (surface.background_tint) |tint| tint: {
                    const buf = try arena.alloc(u8, 7);
                    break :tint color_math.hexString(tint, buf[0..7]);
                } else null,
                .banner = if (surface.banner_text) |t|
                    try arena.dupe(u8, t)
                else
                    null,
                // T574: read-only mode, the machine-readable half of the
                // badge T445 paints. Absent when off (and for viewers),
                // so it is additive for every existing caller.
                .readonly = if (surface.core_surface.readonly) true else null,
                // T1827: stashed out of the layout but still a live,
                // targetable pane - `+list` marks it, as Mac does.
                .stashed = pane_stash.isStashed(pane),
                // T2103: folded into a stacked row's strip.
                .minimized = isMinimized(grid, pane),
                // main eb8162e59: the activity state's machine token,
                // written for every terminal pane as Mac does.
                .state = surface.activity_state.token(),
                // T332: the agent session this pane is bound to — the join
                // key against `+sessions --json`. Lock-free read (the
                // backend publishes the id atomically), duped because the
                // borrow must not outlive the call; null for a plain
                // local ConPTY pane, so the field is omitted there.
                .session_id = if (surface.core_surface.remoteSessionId()) |sid|
                    try arena.dupe(u8, sid)
                else
                    null,
        };
    }
};

/// The pane's shell process id, or 0 when unavailable. Lives on the Surface
/// (`Surface.shellPid`) because the close-confirmation path needs the same
/// answer; this used to be a private copy here that returned 0 for EVERY
/// remote pane, which with session-persistence on (the default) is every local
/// pane — so `+list --pid` could not find a pane it was run from inside.
/// Whether `pane` is a strip in its tab's stacked layout (T2103). A stashed
/// pane has no place in the grid, and so is never also minimized.
fn isMinimized(grid: ?*const pane_stack_grid.Grid, pane: *PaneView) bool {
    const g = grid orelse return false;
    const p = g.placement(pane_stack_grid.viewId(pane)) orelse return false;
    return p.is_tucked;
}

fn surfaceShellPid(surface: *Surface) u32 {
    return surface.shellPid();
}

fn utf16ToUtf8Arena(arena: Allocator, utf16: []const u16) Allocator.Error![]const u8 {
    return std.unicode.utf16LeToUtf8Alloc(arena, utf16) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => "",
    };
}
