//! The GTK frontend's IPC verb handlers (T3335, Linux L6), plugged into the
//! shared dispatcher in `apprt/ipc/server.zig` exactly as win32's are. The
//! dispatcher refuses to compile a frontend that misses a verb, so every verb
//! has a handler here even before its body exists.
//!
//! Served now: `+list` (windows, tabs, the split tree, each pane's stable id,
//! name, title, cwd, shell pid and tty, plus the serving build so a caller can
//! see WHICH app answered), `+version`, `+send-keys` / `+read` (T3336),
//! `+new-window` / `+split` / `+rename` over a pane-name registry (T3370),
//! `+close` plus the `focus` action (T3367), `+rearrange` (T3368), and
//! `--view` viewer panes on `+new-window` / `+split` (T3411): a viewer is a
//! `Surface` showing a web view instead of a terminal, listed as `type:
//! viewer` with its `url`, and refused by the terminal verbs. `handoff-quit`
//! (T3595) quits for a launch of another build. `+new-remote-window`
//! (T3597) opens a window whose panes a remote `ghoztty-agent` hosts.
//! Every other verb answers a plain "not served by the Linux app yet" error
//! naming the task that brings it, so a script learns the gap instead of
//! hanging or guessing.
//!
//! ## Names (T3370)
//!
//! Win32's rules, from `apprt/ipc/target_lookup.zig` (T2250): a window name is
//! global and unique (`+new-window --target`, else a minted `window-N`); a
//! pane name (`--name`) belongs to the window the pane is in, and a lookup
//! starts in the CALLER's window (`request.caller_pane`). The names live on
//! the GTK objects themselves (`Window.ipcName`, `Surface.ipcName`) and every
//! lookup walks the live windows, so a closed pane can never be reached
//! through a stale name - the job win32's `IpcRegistry.forget` does by hand.
//!
//! Runs on the GTK main thread (`IpcServer` marshals every request there).
//! Replies are allocated with `std.heap.c_allocator`, which the transport
//! frees.
const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const glib = @import("glib");
const gdk = @import("gdk");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../apprt.zig");
const renderer = @import("../../renderer.zig");
const CoreSurface = @import("../../Surface.zig");
const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const server = apprt.ipc.server;
const List = apprt.ipc.List;
const Request = server.Request;
const verbs = apprt.ipc.verbs;
const verb_args = apprt.ipc.args;
const target_lookup = @import("../ipc/target_lookup.zig");
const viewer_scheme = @import("viewer_scheme.zig");
const capture_seam = @import("capture_seam.zig");
const pane_snapshot = @import("pane_snapshot.zig");
const wk = @import("webkit.zig");
const PaneDrag = @import("PaneDrag.zig");
const url_scheme = @import("../ipc/url_scheme.zig");
const url_activation = @import("url_activation.zig");
const gtk_url_scheme = @import("url_scheme.zig");
const terminal_osc = @import("../../terminal/osc.zig").Command;
const color_math = @import("../win32/color_math.zig");
const pane_style = @import("pane_style.zig");

const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const pane_drop = @import("../win32/pane_drop.zig");
const PaneDragGhost = @import("PaneDragGhost.zig");
const PaneSidebar = @import("PaneSidebar.zig");
const BannerEditor = @import("BannerEditor.zig");
const pane_banner_rules = @import("pane_banner_rules.zig");
const viewer_links = @import("viewer_links.zig");
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;
const SplitTree = @import("class/split_tree.zig").SplitTree;
const ext = @import("ext.zig");
const CloseUndo = @import("CloseUndo.zig");
const ipc_stash = @import("ipc_stash.zig");
const ipc_remote_window = @import("ipc_remote_window.zig");
const RemoteLink = @import("RemoteLink.zig");
const IpcServer = @import("IpcServer.zig");
const pane_stash = @import("../win32/pane_stash.zig");

const log = std.log.scoped(.gtk_ipc);

pub const Context = *Application;
pub const log_scope = .gtk_ipc;

const c_alloc = std.heap.c_allocator;

/// The `IpcServer.Handler` this frontend hands the transport.
pub fn serve(ctx: *anyopaque, request: []const u8) ?[]u8 {
    const app: *Application = @ptrCast(@alignCast(ctx));
    return server.dispatch(@This(), app, c_alloc, request) catch null;
}

// ---------------------------------------------------------------------------
// Caller scope: pane names belong to their window (T2250), so a request's
// lookups start in the window of the pane it was run from. Everything here
// runs on the one GTK main thread, so a file-level slot is the whole state.

pub const CallerScope = ?*Window;

var caller_window: ?*Window = null;

pub fn enterCallerScope(app: Context, caller_pane: ?[]const u8) CallerScope {
    const outer = caller_window;
    caller_window = callerWindow(app, caller_pane);
    return outer;
}

pub fn leaveCallerScope(_: Context, outer: CallerScope) void {
    caller_window = outer;
}

fn callerWindow(app: Context, caller_pane: ?[]const u8) ?*Window {
    const id = server.nonEmpty(caller_pane orelse return null) orelse return null;
    var it = paneIterator(app);
    while (it.next()) |p| {
        if (std.mem.eql(u8, p.surface.paneId(), id)) return p.window;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Verbs that are not served yet.

fn notYet(comptime verb: server.Verb, comptime task: []const u8) Allocator.Error!?[]u8 {
    return try server.errorResponse(
        c_alloc,
        "+{s} is not served by the Linux app yet ({s})",
        .{ verb.action(), task },
    );
}

/// `+new-remote-window` (T3597): win32's validation and dial over the GTK
/// window model, in `ipc_remote_window.zig`. The dial runs off this thread
/// (`takeDeferred`).
pub fn handleNewRemoteWindow(app: Context, request: Request) Allocator.Error!?[]u8 {
    return ipc_remote_window.handle(app, request);
}

/// `IpcServer.TakeDeferred`: work a handler left to finish off the GTK
/// thread - today only `+new-remote-window`'s dial.
pub fn takeDeferred(ctx: *anyopaque) ?IpcServer.Deferred {
    return ipc_remote_window.takeDeferred(ctx);
}

/// `--from-focused` (T68): on a window riding a remote machine, the new
/// window re-dials that machine (`ipc_remote_window.fromFocused`); null for a
/// local (or no) front window, which opens a plain local window.
pub fn newWindowFromFocused(app: Context, arena: Allocator, args: verb_args.VerbArgs) Allocator.Error!?[]u8 {
    const front = frontWindow(app) orelse return null;
    const link = remoteLinkOf(front) orelse return null;
    // Inherit the active pane's command and its REMOTE cwd (a bounded query
    // on the parent's own connection), unless the flags name their own.
    var command: ?[]const u8 = null;
    var cwd: ?[]const u8 = null;
    if (front.getActiveSurface()) |s| if (s.remoteLink() == link) if (s.core()) |core| {
        if (core.remoteCommand()) |c| command = try arena.dupe(u8, c);
        if (server.nonEmpty(args.working_directory) == null) if (core.remoteSessionId()) |sid| {
            if (link.conn().queryCwdTimeout(sid, 1500 * std.time.ns_per_ms)) |path| {
                defer link.conn().alloc.free(path);
                cwd = try arena.dupe(u8, path);
            } else |err| log.debug("new window remote inherit: cwd query failed err={}", .{err});
        };
    };
    return try ipc_remote_window.fromFocused(app, arena, link, .{
        .command = command,
        .working_directory = cwd,
    }, args);
}

/// The remote machine link `window`'s panes ride (T3597), or null for a
/// local window: the first terminal pane in it that rides one.
pub fn remoteLinkOf(window: *Window) ?*RemoteLink.Link {
    const tab_view = window.getTabView();
    const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
    for (0..pages) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
        const tree = tab.getSplitTree().getTree() orelse continue;
        var it = tree.iterator();
        while (it.next()) |entry| if (entry.view.remoteLink()) |l| return l;
    }
    return null;
}

/// `+stash` / `+restore` (T3596): win32's bodies over the GTK split tree,
/// in `ipc_stash.zig`.
pub fn handleStash(app: Context, request: Request) Allocator.Error!?[]u8 {
    return ipc_stash.stashOrRestore(app, request, false);
}
pub fn handleRestore(app: Context, request: Request) Allocator.Error!?[]u8 {
    return ipc_stash.stashOrRestore(app, request, true);
}

// ---------------------------------------------------------------------------
// DEBUG-ONLY test seams: not CLI verbs, compiled out of a release build, where
// the action falls through to `unknown action` (the dispatcher's contract).

/// `capture-pane` (T3359): a PNG of a pane, or with `--window` its whole
/// window, from the app's own render - the headless Weston the Linux tests
/// run in has no capture a client can ask for. Wire shape and reasons:
/// `capture_seam.zig`.
pub fn handleSeam(app: Context, request: Request) Allocator.Error!server.SeamReply {
    if (comptime !build_config.is_debug) return .unhandled;
    if (std.mem.eql(u8, request.action, "press-key")) return .{ .reply = try pressKey(app, request) };
    if (std.mem.eql(u8, request.action, "pane-sidebar")) return .{ .reply = try paneSidebar(app, request) };
    if (std.mem.eql(u8, request.action, "pane-banner")) return .{ .reply = try paneBanner(app, request) };
    if (std.mem.eql(u8, request.action, "pane-drag")) return .{ .reply = try paneDrag(app, request) };
    if (std.mem.eql(u8, request.action, "pane-mouse")) return .{ .reply = try paneMouse(app, request) };
    if (std.mem.eql(u8, request.action, "pane-stack")) return .{ .reply = try paneStack(app, request) };
    if (std.mem.eql(u8, request.action, "read-clipboard")) return .{ .reply = try readClipboard(app, request) };
    if (std.mem.eql(u8, request.action, "settings")) return .{ .reply = try settingsSeam(app, request) };
    if (std.mem.eql(u8, request.action, "shortcut-guide")) return .{ .reply = try shortcutGuideSeam(app, request) };
    if (std.mem.eql(u8, request.action, "pane-seen")) return .{ .reply = try paneSeenSeam(app, request) };
    if (std.mem.eql(u8, request.action, "close-dialog")) return .{ .reply = try closeDialogSeam(app, request) };
    if (!std.mem.eql(u8, request.action, "capture-pane")) return .unhandled;
    return .{ .reply = try capturePane(app, request) };
}

/// `pane-sidebar --target=<pane|window> [--search=<text>]
/// [--search-key=enter|escape] [--hover=<row id>|]
/// [--click=toggle|scope|add|<row id>|fold:<row id>|tool:<button>:<row id>]
/// [--layout] [--drag=<row id>:<y>]
/// [--menu=<window row id>] [--menu-pick=create|remove|move:<group>]
/// [--edit=<text>] [--edit-key=enter|escape]`
///
/// `--menu` pops a window row's right-click menu (T3608) and the reply's
/// `menu` lists it while it is up; `--menu-pick` picks from it, through the
/// live menu's own code. `--edit` types into the in-place group field that
/// Create Group... or the Ungrouped header's pencil (`--click=tool:rename:
/// ungrouped`) opened, replacing what it holds; `--edit-key` is Return or
/// Escape in it. The reply's `editing` describes the field while it is open.
///
/// (T3557, T3558): what the target window's pane sidebar shows - its mode,
/// the shared flags, the scope and search, and every row as drawn (id,
/// label, subtitle, tooltip, selected; a header's count and fold) - after an
/// optional edit of the search field, a Return or Escape in it, and a click
/// on its mode button, its scope button, a row (a pane focuses, a window
/// raises, a header folds) or a header's fold chevron: the pointer and
/// keyboard the headless harness does not have. The reply is drawn state,
/// so the sidebar is redrawn first: a click or a change still queued is in
/// it.
///
/// `--layout` (T3607) reads the rows as they are laid out on screen instead,
/// with no redraw on either side: a redraw builds new rows, which have no
/// place until GTK's next frame, so only this read carries each row's
/// `top`/`height`. `--drag=<row id>:<y>` lets that row go at `y` of the list
/// (the coordinates `top` is in) through the live drop's own code - the
/// harness has no seat to start a pointer drag - and is read the same way.
fn paneSidebar(app: Context, request: Request) Allocator.Error![]u8 {
    var target_arg: ?[]const u8 = null;
    var click_arg: ?[]const u8 = null;
    var search_arg: ?[]const u8 = null;
    var key_arg: ?[]const u8 = null;
    var hover_arg: ?[]const u8 = null;
    var drag_arg: ?[]const u8 = null;
    var menu_arg: ?[]const u8 = null;
    var pick_arg: ?[]const u8 = null;
    var edit_arg: ?[]const u8 = null;
    var edit_key_arg: ?[]const u8 = null;
    var as_laid_out = false;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--drag=")) drag_arg = arg["--drag=".len..];
        if (std.mem.eql(u8, arg, "--layout")) as_laid_out = true;
        if (std.mem.startsWith(u8, arg, "--target=")) target_arg = arg["--target=".len..];
        if (std.mem.startsWith(u8, arg, "--click=")) click_arg = arg["--click=".len..];
        if (std.mem.startsWith(u8, arg, "--search=")) search_arg = arg["--search=".len..];
        if (std.mem.startsWith(u8, arg, "--search-key=")) key_arg = arg["--search-key=".len..];
        if (std.mem.startsWith(u8, arg, "--hover=")) hover_arg = arg["--hover=".len..];
        if (std.mem.startsWith(u8, arg, "--menu=")) menu_arg = arg["--menu=".len..];
        if (std.mem.startsWith(u8, arg, "--menu-pick=")) pick_arg = arg["--menu-pick=".len..];
        if (std.mem.startsWith(u8, arg, "--edit=")) edit_arg = arg["--edit=".len..];
        if (std.mem.startsWith(u8, arg, "--edit-key=")) edit_key_arg = arg["--edit-key=".len..];
    }
    const target_name = target_arg orelse return server.errorResponse(c_alloc, "--target is required for pane-sidebar", .{});

    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = switch (try resolve(arena, app, target_name)) {
        .found => |t| t,
        .ambiguous => |windows| return server.errorResponse(c_alloc, "{s}", .{
            try target_lookup.ambiguityError(arena, target_name, windows),
        }),
        .not_found => return server.errorResponse(c_alloc, "pane '{s}' not found in registry", .{target_name}),
    };
    const sidebar = target.window_().paneSidebar() orelse
        return server.errorResponse(c_alloc, "the window has no pane sidebar", .{});

    if (drag_arg) |d| {
        const colon = std.mem.lastIndexOfScalar(u8, d, ':') orelse
            return server.errorResponse(c_alloc, "--drag=<row id>:<y>", .{});
        const y = std.fmt.parseFloat(f64, d[colon + 1 ..]) catch
            return server.errorResponse(c_alloc, "--drag y '{s}' is not a number", .{d[colon + 1 ..]});
        const index = sidebar.dropRowAt(d[0..colon], y) orelse
            return server.errorResponse(c_alloc, "sidebar row '{s}' did not drop (not drawn here, not a pane on screen, or not laid out)", .{d[0..colon]});
        const rep = try sidebar.report(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(.{ .success = true, .index = index, .sidebar = rep }, .{}, &out.writer) catch return error.OutOfMemory;
        return c_alloc.dupe(u8, out.written());
    }
    if (as_laid_out) {
        const rep = try sidebar.report(arena);
        var out: std.Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(.{ .success = true, .sidebar = rep }, .{}, &out.writer) catch return error.OutOfMemory;
        return c_alloc.dupe(u8, out.written());
    }

    // Pending redraws first, so a click lands on the rows as they now are.
    sidebar.refresh();
    if (search_arg) |q| {
        if (PaneSidebar.setQuery(q)) Window.refreshAllSidebars();
    }
    if (key_arg) |k| {
        if (std.mem.eql(u8, k, "enter")) {
            if (!sidebar.searchReturn()) return server.errorResponse(c_alloc, "the search lists no pane", .{});
        } else if (std.mem.eql(u8, k, "escape")) {
            sidebar.searchEscape();
        } else return server.errorResponse(c_alloc, "--search-key must be enter or escape", .{});
    }
    if (click_arg) |click| {
        if (std.mem.eql(u8, click, "toggle")) {
            sidebar.toggleExpanded("pane-sidebar seam");
        } else if (std.mem.eql(u8, click, "scope")) {
            PaneSidebar.toggleScope(c_alloc, "pane-sidebar seam");
        } else if (std.mem.startsWith(u8, click, "fold:")) {
            if (!sidebar.clickFold(click["fold:".len..]))
                return server.errorResponse(c_alloc, "no sidebar header '{s}'", .{click["fold:".len..]});
        } else if (std.mem.eql(u8, click, "add")) {
            if (!sidebar.clickHeaderAdd()) return server.errorResponse(c_alloc, "the header's + is not shown", .{});
        } else if (std.mem.startsWith(u8, click, "tool:")) {
            // tool:<stash|restore|add|close>:<row id> (T3606).
            const rest = click["tool:".len..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse
                return server.errorResponse(c_alloc, "--click=tool:<name>:<row id>", .{});
            const tool = std.meta.stringToEnum(PaneSidebar.Tool, rest[0..colon]) orelse
                return server.errorResponse(c_alloc, "no sidebar button '{s}'", .{rest[0..colon]});
            if (!sidebar.clickTool(tool, rest[colon + 1 ..]))
                return server.errorResponse(c_alloc, "no '{s}' button on sidebar row '{s}'", .{ rest[0..colon], rest[colon + 1 ..] });
        } else if (!sidebar.clickRow(click)) {
            return server.errorResponse(c_alloc, "no sidebar row for '{s}'", .{click});
        }
    }
    // A window row's right-click menu (T3608): opened on the row, then an
    // item picked from it - create, remove, or move:<group>.
    if (menu_arg) |id| {
        const r = sidebar.rowById(id) orelse
            return server.errorResponse(c_alloc, "no sidebar row '{s}'", .{id});
        if (!sidebar.openWindowMenu(r, 12, 12))
            return server.errorResponse(c_alloc, "sidebar row '{s}' has no window menu", .{id});
    }
    if (pick_arg) |p| {
        const cmd: PaneSidebar.WindowCmd = if (std.mem.eql(u8, p, "create"))
            .create_group
        else if (std.mem.eql(u8, p, "remove"))
            .remove_from_group
        else if (std.mem.startsWith(u8, p, "move:")) cmd: {
            const i = sidebar.menuGroupIndex(p["move:".len..]) orelse
                return server.errorResponse(c_alloc, "the window menu lists no group '{s}'", .{p["move:".len..]});
            break :cmd .{ .move_to_group = i };
        } else return server.errorResponse(c_alloc, "--menu-pick must be create, remove or move:<group>", .{});
        if (!sidebar.menuOffers(cmd))
            return server.errorResponse(c_alloc, "the window menu is not up, or does not offer '{s}'", .{p});
        _ = sidebar.pickMenu(cmd);
    }
    // The in-place group field (T3608): typed into, then Return or Escape.
    // A queued redraw lands first, so the field is drawn when typed into.
    if (edit_arg != null or edit_key_arg != null) sidebar.refresh();
    if (edit_arg) |t| {
        if (!sidebar.typeEdit(t)) return server.errorResponse(c_alloc, "no sidebar field is open", .{});
    }
    if (edit_key_arg) |k| {
        if (sidebar.edit == null) return server.errorResponse(c_alloc, "no sidebar field is open", .{});
        if (std.mem.eql(u8, k, "enter")) {
            sidebar.commitEdit("return");
        } else if (std.mem.eql(u8, k, "escape")) {
            sidebar.cancelEdit();
        } else return server.errorResponse(c_alloc, "--edit-key must be enter or escape", .{});
    }
    sidebar.refresh();
    // The pointer over a row (its buttons show), or with an empty value off
    // every row - the motion controller's enter and leave (T3606).
    if (hover_arg) |h| sidebar.setHover(if (h.len == 0) null else h);
    const rep = try sidebar.report(arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(.{ .success = true, .sidebar = rep }, .{}, &out.writer) catch return error.OutOfMemory;
    return c_alloc.dupe(u8, out.written());
}

/// `pane-banner --target=<pane> [--click=card|chevron]
/// [--editor-text=<text>] [--editor-key=return|ctrl+return|escape]` (T3559):
/// the pointer and keyboard the headless harness does not have, for the
/// banner card and its editor. `--click=card` is a click on the card away
/// from any link (what its release queues), `--click=chevron` the chevron's
/// own `clicked`. `--editor-text` replaces the open editor's text and
/// `--editor-key` presses one key in it through the text box's handler -
/// `pass` in the reply means the key was left to the text view (Return: a
/// newline). Reply: the card (`shown`, `collapsible`, `collapsed`) and the
/// editor (`open`, its `pane`, its `text`), after the clicks and keys.
///
/// The link menu (T3561): `--link-menu=<target>` is a right-click on a banner
/// link to `<target>` (the label's own gesture finds the link under a real
/// pointer; there is none here), and `--menu-pick=<row>` runs a row of the
/// last one (`open_browser`, `reveal`, `side_pane`, `new_window`,
/// `open_default_app`, `copy`, `focus`). Under `GHOZTTY_TEST_VIEWER_LINKS`
/// the menu is recorded, not popped (`menu <kind> <target> rows=...`), and
/// the rows' hand-offs are recorded the way the viewer's are.
fn paneBanner(app: Context, request: Request) Allocator.Error![]u8 {
    var target_arg: ?[]const u8 = null;
    var click_arg: ?[]const u8 = null;
    var text_arg: ?[]const u8 = null;
    var key_arg: ?[]const u8 = null;
    var menu_arg: ?[]const u8 = null;
    var pick_arg: ?[]const u8 = null;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--link-menu=")) menu_arg = arg["--link-menu=".len..];
        if (std.mem.startsWith(u8, arg, "--menu-pick=")) pick_arg = arg["--menu-pick=".len..];
        if (std.mem.startsWith(u8, arg, "--target=")) target_arg = arg["--target=".len..];
        if (std.mem.startsWith(u8, arg, "--click=")) click_arg = arg["--click=".len..];
        if (std.mem.startsWith(u8, arg, "--editor-text=")) text_arg = arg["--editor-text=".len..];
        if (std.mem.startsWith(u8, arg, "--editor-key=")) key_arg = arg["--editor-key=".len..];
    }
    const target_name = target_arg orelse return server.errorResponse(c_alloc, "--target is required for pane-banner", .{});

    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = switch (try resolve(arena, app, target_name)) {
        .found => |t| t,
        .ambiguous => |windows| return server.errorResponse(c_alloc, "{s}", .{
            try target_lookup.ambiguityError(arena, target_name, windows),
        }),
        .not_found => return server.errorResponse(c_alloc, "pane '{s}' not found in registry", .{target_name}),
    };
    const surface = target.surface() orelse
        return server.errorResponse(c_alloc, "pane '{s}' is no longer alive", .{target_name});
    const card = surface.paneBannerCard();

    if (click_arg) |click| {
        const c = card orelse return server.errorResponse(c_alloc, "pane '{s}' has no banner", .{target_name});
        if (std.mem.eql(u8, click, "card")) {
            c.cardClicked();
        } else if (std.mem.eql(u8, click, "chevron")) {
            c.chevronClicked();
        } else return server.errorResponse(c_alloc, "--click must be card or chevron", .{});
    }

    if (menu_arg) |m| {
        const c = card orelse return server.errorResponse(c_alloc, "pane '{s}' has no banner", .{target_name});
        c.linkMenu(m, 0, 0);
    }
    if (pick_arg) |p| {
        const id = viewer_links.idFromActionName(p) orelse
            return server.errorResponse(c_alloc, "--menu-pick: no menu row '{s}'", .{p});
        if (!surface.pickBannerMenuRow(id))
            return server.errorResponse(c_alloc, "no banner link menu was opened on '{s}'", .{target_name});
    }

    var effect: ?pane_banner_rules.EditorKey = null;
    if (text_arg != null or key_arg != null) {
        const editor = BannerEditor.current() orelse
            return server.errorResponse(c_alloc, "no banner editor is open", .{});
        if (text_arg) |t| editor.setText(t);
        if (key_arg) |k| {
            const r = pane_banner_rules;
            const press: [2]c_uint = if (std.mem.eql(u8, k, "return"))
                .{ r.key_return, 0 }
            else if (std.mem.eql(u8, k, "ctrl+return"))
                .{ r.key_return, r.mod_control }
            else if (std.mem.eql(u8, k, "escape"))
                .{ r.key_escape, 0 }
            else
                return server.errorResponse(c_alloc, "--editor-key must be return, ctrl+return or escape", .{});
            effect = editor.key(press[0], press[1]);
        }
    }

    const editor = BannerEditor.current();
    const shown = if (card) |c| c.getText() != null else false;
    const rep = .{
        .success = true,
        .banner = .{
            .shown = shown,
            .collapsible = if (card) |c| c.isCollapsible() else false,
            .collapsed = if (card) |c| shown and c.isCollapsible() and c.collapsed else false,
            .text = surface.getPaneBanner(),
        },
        .editor = .{
            .open = editor != null,
            .pane = if (editor) |e| e.surface.paneId() else null,
            .text = if (editor) |e| try e.text(arena) else null,
        },
        .key_effect = if (effect) |e| @tagName(e) else null,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(rep, .{}, &out.writer) catch return error.OutOfMemory;
    return c_alloc.dupe(u8, out.written());
}

/// `pane-stack --target=<pane> [--press=<x>,<y>] [--drag=<dx>,<dy>]...
/// [--release=<dx>,<dy>]` (T3567): the stacked-panes stage of the target's
/// tab - each pane's frame, whether it is minimized and the strip that shows,
/// and every gutter that takes the mouse (`divider`, `grip`, `edge`) - after
/// an optional press, drag steps and release, in order, at the stage's
/// coordinates, through the same `SplitTree.stagePress`/`stageDrag`/
/// `stageRelease` the stage's real drag gesture calls. The headless harness
/// has no seat, so no pointer can press. Reply `press`: what the press took
/// hold of (`none|divider|grip|strip`); `stage`: null when the tab shows one
/// pane.
fn paneStack(app: Context, request: Request) Allocator.Error![]u8 {
    var target_arg: ?[]const u8 = null;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--target=")) target_arg = arg["--target=".len..];
    }
    const target_name = target_arg orelse return server.errorResponse(c_alloc, "--target is required for pane-stack", .{});

    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = switch (try resolve(arena, app, target_name)) {
        .found => |t| t,
        .ambiguous => |windows| return server.errorResponse(c_alloc, "{s}", .{
            try target_lookup.ambiguityError(arena, target_name, windows),
        }),
        .not_found => return server.errorResponse(c_alloc, "pane '{s}' not found in registry", .{target_name}),
    };
    const surface = target.surface() orelse
        return server.errorResponse(c_alloc, "pane '{s}' is no longer alive", .{target_name});
    const tree = ext.getAncestor(SplitTree, surface.as(gtk.Widget)) orelse
        return server.errorResponse(c_alloc, "pane '{s}' is not in a split tree", .{target_name});

    const pair = struct {
        fn parse(s: []const u8) ?[2]f64 {
            var parts = std.mem.splitScalar(u8, s, ',');
            const a = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
            const b = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
            return .{ a, b };
        }
    }.parse;

    tree.layoutNow();
    var press: ?[]const u8 = null;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--press=")) {
            const p = pair(arg["--press=".len..]) orelse return server.errorResponse(c_alloc, "--press must be <x>,<y>", .{});
            press = @tagName(tree.stagePress(p[0], p[1]));
        } else if (std.mem.startsWith(u8, arg, "--drag=")) {
            const p = pair(arg["--drag=".len..]) orelse return server.errorResponse(c_alloc, "--drag must be <dx>,<dy>", .{});
            tree.stageDrag(p[0], p[1]);
            tree.layoutNow();
        } else if (std.mem.startsWith(u8, arg, "--release=")) {
            const p = pair(arg["--release=".len..]) orelse return server.errorResponse(c_alloc, "--release must be <dx>,<dy>", .{});
            tree.stageRelease(p[0], p[1]);
            tree.layoutNow();
        }
    }

    const Rep = struct {
        success: bool = true,
        press: ?[]const u8,
        stage: ?SplitTree.StageReport,
    };
    const rep: Rep = .{ .press = press, .stage = try tree.stageReport(arena) };
    var out: std.Io.Writer.Allocating = .init(c_alloc);
    defer out.deinit();
    std.json.Stringify.value(rep, .{}, &out.writer) catch return error.OutOfMemory;
    return c_alloc.dupe(u8, out.written());
}

/// `pane-drag --target=<pane> [--key=escape]
/// [--drop-on=<pane> --fx=<0..1> --fy=<0..1> | --drop-at=<x>,<y> |
/// --drop-tab=<n>] [--hover-tab=<n> | --hover-leave]` (T3564, T3615):
/// the target window's rearrange mode as drawn - the mode, the tab bar's
/// visible/autohide, and every pane's header (shown, laid-out height, title,
/// and the pane's content height under it) - after an optional Escape through
/// the window's own key handler and an optional drop of the TARGET pane,
/// through the same `SplitTree.dropPaneAt` / `Window.dropOnTabBar` a real
/// release calls. The headless harness has no seat, so no pointer drag can
/// start; this is the drop half of one. `--drop-on` names a point as a
/// fraction of a pane's drawn rect, in THAT pane's tab (so a drop can land in
/// a tab the dwell switched to), `--drop-at` one in the selected tab's split
/// area, `--drop-tab` the middle of the n-th tab's button on the bar.
/// `--hover-tab` moves the drag onto the n-th tab's button (the dwell clock,
/// `Window.tabDwellAt`); `--hover-leave` takes it off the bar.
/// `--bar-of=<pane>` aims `--drop-tab`, `--hover-tab` and `--hover-leave`
/// at the tab bar of THAT pane's window instead of the target's - a drag
/// that ends in another window (T3616). Reply `drop`:
/// the resolved `target` kind, its `side`/`pane`/`index`, and `outcome`
/// (`moved|in_place|not_here|none`); `tab_count`, `selected_tab`,
/// `dwell_tab` and `tab_buttons` (the bar's buttons the resolver reads),
/// all of the window the target pane is in AFTER any drop, and
/// `window_count`, the app's windows (a window a drop emptied is gone).
/// `--release-nowhere` is a drag of the target let go over nothing, and
/// `--pop-out` a click of its header's pop-out button (T3618): both move it
/// into a new window of its own through the very call the drag's no-target
/// cancel and the button make, and report as a drop (`target` new_window,
/// `outcome` moved|refused|not_here; `none` when `--pop-out` met a disabled
/// or missing button). Each header reports `pop_out`, its button enabled.
fn paneDrag(app: Context, request: Request) Allocator.Error![]u8 {
    var target_arg: ?[]const u8 = null;
    var key_arg: ?[]const u8 = null;
    var on_arg: ?[]const u8 = null;
    var at_arg: ?[]const u8 = null;
    var tab_arg: ?[]const u8 = null;
    var hover_arg: ?[]const u8 = null;
    var bar_of_arg: ?[]const u8 = null;
    var hover_leave = false;
    var release_nowhere = false;
    var pop_out = false;
    var ghost_arg = false;
    var ghost_png: ?[]const u8 = null;
    var fx: f64 = 0.5;
    var fy: f64 = 0.5;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--target=")) target_arg = arg["--target=".len..];
        if (std.mem.startsWith(u8, arg, "--key=")) key_arg = arg["--key=".len..];
        if (std.mem.startsWith(u8, arg, "--drop-on=")) on_arg = arg["--drop-on=".len..];
        if (std.mem.startsWith(u8, arg, "--drop-at=")) at_arg = arg["--drop-at=".len..];
        if (std.mem.startsWith(u8, arg, "--drop-tab=")) tab_arg = arg["--drop-tab=".len..];
        if (std.mem.startsWith(u8, arg, "--hover-tab=")) hover_arg = arg["--hover-tab=".len..];
        if (std.mem.eql(u8, arg, "--hover-leave")) hover_leave = true;
        if (std.mem.eql(u8, arg, "--release-nowhere")) release_nowhere = true;
        if (std.mem.eql(u8, arg, "--pop-out")) pop_out = true;
        if (std.mem.startsWith(u8, arg, "--bar-of=")) bar_of_arg = arg["--bar-of=".len..];
        if (std.mem.eql(u8, arg, "--ghost")) ghost_arg = true;
        if (std.mem.startsWith(u8, arg, "--ghost-png=")) {
            ghost_arg = true;
            ghost_png = arg["--ghost-png=".len..];
        }
        if (std.mem.startsWith(u8, arg, "--fx=")) fx = std.fmt.parseFloat(f64, arg["--fx=".len..]) catch fx;
        if (std.mem.startsWith(u8, arg, "--fy=")) fy = std.fmt.parseFloat(f64, arg["--fy=".len..]) catch fy;
    }
    const target_name = target_arg orelse return server.errorResponse(c_alloc, "--target is required for pane-drag", .{});

    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = switch (try resolve(arena, app, target_name)) {
        .found => |t| t,
        .ambiguous => |windows| return server.errorResponse(c_alloc, "{s}", .{
            try target_lookup.ambiguityError(arena, target_name, windows),
        }),
        .not_found => return server.errorResponse(c_alloc, "pane '{s}' not found in registry", .{target_name}),
    };
    var window = target.window_();
    const surface = target.surface() orelse
        return server.errorResponse(c_alloc, "pane '{s}' is no longer alive", .{target_name});

    // The card a drag of the target would carry, built before any drop the
    // way a drag builds it at drag-begin (T3617).
    const ghost_rep: ?GhostRep = if (ghost_arg) ghostReport(arena, surface, ghost_png) else null;

    var key_effect: ?[]const u8 = null;
    if (key_arg) |k| {
        if (!std.mem.eql(u8, k, "escape")) return server.errorResponse(c_alloc, "--key must be escape", .{});
        key_effect = if (window.rearrangeKey(0xff1b, 0)) "consumed" else "passed";
    }

    // The middle of the n-th tab's button, in the bar's coordinates.
    const buttonPoint = struct {
        fn f(w: *Window, arg: []const u8) ?struct { x: f64, y: f64 } {
            const n = std.fmt.parseInt(usize, arg, 10) catch return null;
            var buf: [Window.max_tab_buttons]pane_drop.Rect = undefined;
            const cand = w.tabBarCandidate(&buf) orelse return null;
            if (n >= cand.tab_button_rects.len) return null;
            const r = cand.tab_button_rects[n];
            return .{
                .x = @as(f64, @floatFromInt(r.left + @divTrunc(r.width(), 2))),
                .y = @as(f64, @floatFromInt(r.top + @divTrunc(r.height(), 2))),
            };
        }
    }.f;

    // The window whose tab bar the drag is over: the target's own, or the
    // one `--bar-of` names.
    const bar_window: *Window = if (bar_of_arg) |b| switch (try resolve(arena, app, b)) {
        .found => |t| t.window_(),
        else => return server.errorResponse(c_alloc, "--bar-of: pane '{s}' not found", .{b}),
    } else window;

    if (hover_leave) bar_window.cancelTabDwell();
    if (hover_arg) |h| {
        const p = buttonPoint(bar_window, h) orelse
            return server.errorResponse(c_alloc, "--hover-tab: no tab button {s} on a visible tab bar", .{h});
        bar_window.tabDwellAt(p.x, p.y);
    }

    const Drop = struct { target: []const u8, outcome: []const u8, side: ?[]const u8, pane: ?[]const u8, index: ?usize, x: f64, y: f64 };
    var drop: ?Drop = null;
    if (tab_arg) |t| {
        const p = buttonPoint(bar_window, t) orelse
            return server.errorResponse(c_alloc, "--drop-tab: no tab button {s} on a visible tab bar", .{t});
        const id = try arena.dupe(u8, surface.paneId());
        const r = bar_window.dropOnTabBar(id, p.x, p.y);
        drop = .{ .target = r.target, .outcome = r.outcome, .side = null, .pane = null, .index = r.index, .x = p.x, .y = p.y };
    }
    if (on_arg != null or at_arg != null) {
        // The tab under the drop: the named pane's, else the one on show.
        var tree: *SplitTree = tree: {
            const sel = window.getSelectedTab() orelse
                return server.errorResponse(c_alloc, "the window has no tab on show", .{});
            break :tree sel.getSplitTree();
        };
        var x: f64 = 0;
        var y: f64 = 0;
        if (on_arg) |on| {
            const other = switch (try resolve(arena, app, on)) {
                .found => |t| t.surface() orelse return server.errorResponse(c_alloc, "pane '{s}' is no longer alive", .{on}),
                else => return server.errorResponse(c_alloc, "--drop-on: pane '{s}' not found", .{on}),
            };
            tree = ext.getAncestor(SplitTree, other.as(gtk.Widget)) orelse
                return server.errorResponse(c_alloc, "--drop-on: pane '{s}' is not in a split tree", .{on});
            const r = tree.paneRect(other) orelse
                return server.errorResponse(c_alloc, "--drop-on: pane '{s}' is not on screen in its tab", .{on});
            x = @as(f64, @floatFromInt(r.left)) + fx * @as(f64, @floatFromInt(r.width()));
            y = @as(f64, @floatFromInt(r.top)) + fy * @as(f64, @floatFromInt(r.height()));
        } else if (at_arg) |at| {
            var parts = std.mem.splitScalar(u8, at, ',');
            x = std.fmt.parseFloat(f64, parts.next() orelse "") catch
                return server.errorResponse(c_alloc, "--drop-at must be <x>,<y>", .{});
            y = std.fmt.parseFloat(f64, parts.next() orelse "") catch
                return server.errorResponse(c_alloc, "--drop-at must be <x>,<y>", .{});
        }
        // The id is the pane's own buffer; copy it, the drop rebuilds the tree.
        const id = try arena.dupe(u8, surface.paneId());
        const r = tree.dropPaneAt(id, x, y);
        drop = .{
            .target = r.target,
            .outcome = r.outcome,
            .side = r.side,
            .pane = if (r.pane) |p| try arena.dupe(u8, p) else null,
            .index = r.index,
            .x = x,
            .y = y,
        };
    }
    // A release over nothing, or the header's pop-out button (T3618): the
    // pane into a new window. Both need the header, as a real one does - a
    // drag starts from it and the button is on it.
    if (release_nowhere or pop_out) {
        const h = surface.rearrangeHeader() orelse
            return server.errorResponse(c_alloc, "pane '{s}' has no rearrange header (the mode was never on)", .{target_name});
        const r: PaneDrag.DropResult = if (release_nowhere)
            h.releaseOverNothing()
        else
            h.pressPopOut() orelse .{ .target = "new_window", .outcome = "none" };
        drop = .{ .target = r.target, .outcome = r.outcome, .side = null, .pane = null, .index = null, .x = 0, .y = 0 };
    }

    // A drop can carry the pane into another window, and close the one it
    // left: report the window it is in now. Found by its tree, not by
    // widget ancestry - the tree it landed in rebuilds its widgets later.
    if (drop != null) window = landed: {
        var it = windowIterator(app);
        while (it.next()) |w| if (w.splitTreeHolding(surface.paneId()) != null) break :landed w;
        return server.errorResponse(c_alloc, "pane '{s}' is in no window after the drop", .{target_name});
    };
    var window_count: usize = 0;
    var wins = windowIterator(app);
    while (wins.next()) |_| window_count += 1;

    var bar_buf: [Window.max_tab_buttons]pane_drop.Rect = undefined;
    const bar = window.tabBarCandidate(&bar_buf);

    const HeaderRep = struct { pane: []const u8, shown: bool, height: c_int, title: []const u8, content_height: c_int, is_split: bool, pop_out: bool };
    var headers: std.ArrayList(HeaderRep) = .empty;
    var panes = paneIterator(app);
    while (panes.next()) |p| {
        if (p.window != window) continue;
        const h = p.surface.rearrangeHeader();
        try headers.append(arena, .{
            .pane = p.surface.paneId(),
            .shown = if (h) |v| v.isShown() else false,
            .height = if (h) |v| v.height() else 0,
            .title = if (h) |v| try arena.dupe(u8, v.title()) else "",
            .content_height = p.surface.contentHeight(),
            .is_split = p.surface.isSplit(),
            .pop_out = if (h) |v| v.popOutEnabled() else false,
        });
    }
    const Rep = struct {
        success: bool = true,
        mode: bool,
        tabs_visible: bool,
        tabs_autohide: bool,
        key_effect: ?[]const u8,
        headers: []const HeaderRep,
        drop: ?Drop,
        tab_count: c_int,
        selected_tab: ?usize,
        dwell_tab: ?usize,
        tab_buttons: usize,
        window_count: usize,
        ghost: ?GhostRep,
    };
    const rep: Rep = .{
        .ghost = ghost_rep,
        .mode = window.rearrangeMode(),
        .tabs_visible = window.getTabsVisible(),
        .tabs_autohide = window.getTabsAutohide(),
        .key_effect = key_effect,
        .headers = headers.items,
        .drop = drop,
        .tab_count = window.getTabView().getNPages(),
        .selected_tab = window.selectedTabIndex(),
        .dwell_tab = window.tabDwell(),
        .tab_buttons = if (bar) |b| b.tab_button_rects.len else 0,
        .window_count = window_count,
    };
    var out: std.Io.Writer.Allocating = .init(c_alloc);
    defer out.deinit();
    std.json.Stringify.value(rep, .{}, &out.writer) catch return error.OutOfMemory;
    return c_alloc.dupe(u8, out.written());
}

/// The `pane-drag --ghost` report (T3617): the card's planned geometry, the
/// texture the renderer actually produced, and pixels sampled from it - the
/// shadow margin, the shadow under the card, the strip against the colour it
/// was planned in, the body, and how many of the strip's pixels the title's
/// ink changed. `built` false means the drag would keep GTK's own icon.
const GhostRep = struct {
    built: bool,
    title: []const u8 = "",
    image_w: i32 = 0,
    image_h: i32 = 0,
    card_w: i32 = 0,
    card_h: i32 = 0,
    hot_x: i32 = 0,
    hot_y: i32 = 0,
    title_top: i32 = 0,
    title_bottom: i32 = 0,
    scale: c_int = 0,
    texture_w: c_int = 0,
    texture_h: c_int = 0,
    // u16, not u8: std.json writes a `[N]u8` that happens to be valid UTF-8
    // as a STRING, so the colour 40,44,52 arrived as "(,4".
    bg: [3]u16 = .{ 0, 0, 0 },
    strip_planned: [3]u16 = .{ 0, 0, 0 },
    margin_px: ?[4]u16 = null,
    shadow_px: ?[4]u16 = null,
    strip_px: ?[4]u16 = null,
    body_px: ?[4]u16 = null,
    title_ink_px: usize = 0,
    png: ?[]const u8 = null,
};

fn wide4(v: ?[4]u8) ?[4]u16 {
    const x = v orelse return null;
    return .{ x[0], x[1], x[2], x[3] };
}

fn ghostReport(arena: Allocator, surface: *Surface, png_path: ?[]const u8) GhostRep {
    const b = surface.dragGhost() orelse return .{ .built = false };
    defer b.deinit();
    const p = b.plan;
    const lay = p.lay;
    var rep: GhostRep = .{
        .built = true,
        .title = if (surface.rearrangeHeader()) |h| arena.dupe(u8, h.title()) catch "" else "",
        .image_w = p.image.w,
        .image_h = p.image.h,
        .card_w = p.card.w,
        .card_h = p.card.h,
        .hot_x = p.hot_x,
        .hot_y = p.hot_y,
        .title_top = lay.title.top,
        .title_bottom = lay.title.bottom,
        .scale = b.scale,
        .texture_w = wk.gdk_texture_get_width(b.texture),
        .texture_h = wk.gdk_texture_get_height(b.texture),
        .bg = .{ p.bg.r, p.bg.g, p.bg.b },
        .strip_planned = .{ p.strip.r, p.strip.g, p.strip.b },
    };
    if (PaneDragGhost.Pixels.of(b)) |px| {
        defer px.deinit();
        rep.margin_px = wide4(px.at(1, 1));
        rep.shadow_px = wide4(px.at(@divTrunc(p.image.w, 2), lay.card.bottom + 3));
        const strip_y = lay.title.top + @divTrunc(lay.title.height(), 2);
        rep.strip_px = wide4(px.at(lay.card.right - 4, strip_y));
        rep.body_px = wide4(px.at(lay.body.right - 12, lay.body.bottom - 12));
        // The title's ink: strip pixels in the left half (where the label
        // starts) that are far from the strip's own colour.
        var y = lay.title.top + 2;
        while (y < lay.title.bottom - 2) : (y += 1) {
            var x = lay.title.left + 8;
            while (x < lay.title.left + @divTrunc(lay.title.width(), 2)) : (x += 1) {
                const v = px.at(x, y) orelse continue;
                const d = @max(@abs(@as(i32, v[0]) - p.strip.r), @max(@abs(@as(i32, v[1]) - p.strip.g), @abs(@as(i32, v[2]) - p.strip.b)));
                if (d > 48) rep.title_ink_px += 1;
            }
        }
    }
    if (png_path) |path| {
        const bytes = wk.gdk_texture_save_to_png_bytes(b.texture);
        defer wk.g_bytes_unref(bytes);
        var len: usize = 0;
        if (wk.g_bytes_get_data(bytes, &len)) |data| {
            if (std.fs.cwd().writeFile(.{ .sub_path = path, .data = data[0..len] })) |_| {
                rep.png = path;
            } else |err| log.warn("pane-drag --ghost-png: {s}: {}", .{ path, err });
        }
    }
    return rep;
}

/// `close-dialog --target=<pane|window> [--op=pane|tab|window]
/// [--answer=disconnect|close|cancel]` (T3563): start an INTERACTIVE close
/// the way the pane keybind, a tab's x or the window's x does (`--op`), then
/// report the close confirmation up over the target's window - whether there
/// is one, whether it offers Disconnect, its body - and optionally answer it
/// as a press of that button would. Wayland gives the headless harness no
/// pointer to click a dialog with.
fn closeDialogSeam(app: Context, request: Request) Allocator.Error![]u8 {
    var target_arg: ?[]const u8 = null;
    var op_arg: ?[]const u8 = null;
    var answer_arg: ?[]const u8 = null;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--target=")) target_arg = arg["--target=".len..];
        if (std.mem.startsWith(u8, arg, "--op=")) op_arg = arg["--op=".len..];
        if (std.mem.startsWith(u8, arg, "--answer=")) answer_arg = arg["--answer=".len..];
    }
    const target_name = target_arg orelse return server.errorResponse(c_alloc, "--target is required for close-dialog", .{});
    // A dialog answered in the same main-loop turn that presented it never
    // leaves the window's dialog stack: start the close and answer it in two
    // requests, as a person would.
    if (op_arg != null and answer_arg != null)
        return server.errorResponse(c_alloc, "close-dialog: --op and --answer go in separate requests", .{});
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const target = switch (try resolve(arena_state.allocator(), app, target_name)) {
        .found => |t| t,
        .ambiguous => |windows| return server.errorResponse(c_alloc, "{s}", .{
            try target_lookup.ambiguityError(arena_state.allocator(), target_name, windows),
        }),
        .not_found => return server.errorResponse(c_alloc, "'{s}' not found in registry", .{target_name}),
    };
    const window = target.window_();
    if (op_arg) |op| {
        if (std.mem.eql(u8, op, "window")) {
            window.as(gtk.Window).close();
        } else if (std.mem.eql(u8, op, "tab")) {
            const tab = window.getSelectedTab() orelse
                return server.errorResponse(c_alloc, "the window has no tab", .{});
            const tab_view = window.getTabView();
            tab_view.closePage(tab_view.getPage(tab.as(gtk.Widget)));
        } else if (std.mem.eql(u8, op, "pane")) {
            const surface = target.surface() orelse
                return server.errorResponse(c_alloc, "--op=pane needs a pane --target", .{});
            surface.close();
        } else return server.errorResponse(c_alloc, "--op must be pane, tab or window", .{});
    }
    const Rep = struct {
        success: bool = true,
        open: bool,
        disconnect: bool = false,
        body: []const u8 = "",
        answered: ?[]const u8 = null,
        /// What the dialog closes: app, tab, window or surface.
        scope: ?[]const u8 = null,
        /// Some OTHER dialog is up over the window (its type name).
        other: ?[]const u8 = null,
    };
    var rep: Rep = .{ .open = false };
    if (window.openCloseConfirmation() == null) if (window.openDialogTypeName()) |n| {
        rep.other = n;
    };
    if (window.openCloseConfirmation()) |dialog| {
        rep.open = true;
        rep.disconnect = dialog.offersDisconnect();
        rep.scope = dialog.scopeName();
        rep.body = try arena_state.allocator().dupe(u8, std.mem.span(dialog.bodyText()));
        if (answer_arg) |a| {
            const id: [*:0]const u8 = if (std.mem.eql(u8, a, "disconnect"))
                "disconnect"
            else if (std.mem.eql(u8, a, "close"))
                "close"
            else if (std.mem.eql(u8, a, "cancel"))
                "cancel"
            else
                return server.errorResponse(c_alloc, "--answer must be disconnect, close or cancel", .{});
            log.info("close-dialog target={s}: answering {s}", .{ target_name, a });
            dialog.answer(id);
            rep.answered = a;
        }
    }
    var out: std.Io.Writer.Allocating = .init(c_alloc);
    defer out.deinit();
    std.json.Stringify.value(rep, .{}, &out.writer) catch return error.OutOfMemory;
    return c_alloc.dupe(u8, out.written());
}

/// `press-key --target=<pane> --key=<trigger>` (T3384): one press and release
/// of a key chord (`ctrl+shift+z`, the keybind syntax) on a terminal pane, fed
/// through its core `keyCallback` - so the configured binding table decides
/// what it does, exactly as a real key would. Wayland has no global input
/// injection and the headless harness has no seat, so this is how a Linux
/// test reaches a keyboard-only action (undo, redo). Reply: `effect` is the
/// press's `InputEffect` (`consumed`, `ignored`, `closed`).
fn pressKey(app: Context, request: Request) Allocator.Error![]u8 {
    var target_arg: ?[]const u8 = null;
    var key_arg: ?[]const u8 = null;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--target=")) target_arg = arg["--target=".len..];
        if (std.mem.startsWith(u8, arg, "--key=")) key_arg = arg["--key=".len..];
    }
    const target_name = target_arg orelse return server.errorResponse(c_alloc, "--target is required for press-key", .{});
    const key_name = key_arg orelse return server.errorResponse(c_alloc, "--key is required for press-key", .{});
    const trigger = input.Binding.Trigger.parse(key_name) catch
        return server.errorResponse(c_alloc, "--key '{s}' is not a key chord", .{key_name});

    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const target = switch (try resolve(arena_state.allocator(), app, target_name)) {
        .found => |t| t,
        .ambiguous => |windows| return server.errorResponse(c_alloc, "{s}", .{
            try target_lookup.ambiguityError(arena_state.allocator(), target_name, windows),
        }),
        .not_found => return server.errorResponse(c_alloc, "pane '{s}' not found in registry", .{target_name}),
    };
    const surface = target.surface() orelse
        return server.errorResponse(c_alloc, "pane '{s}' is no longer alive", .{target_name});
    const core = surface.core() orelse
        return server.errorResponse(c_alloc, "pane '{s}' has no terminal to type into", .{target_name});

    var event: input.KeyEvent = .{ .action = .press, .mods = trigger.mods };
    switch (trigger.key) {
        .physical => |k| event.key = k,
        .unicode => |cp| event.unshifted_codepoint = cp,
        .catch_all => return server.errorResponse(c_alloc, "--key '{s}' names no key", .{key_name}),
    }
    const effect = core.keyCallback(event) catch |err|
        return server.errorResponse(c_alloc, "press-key failed ({s})", .{@errorName(err)});
    // The press may have closed the pane; only a surviving one gets its release.
    if (effect != .closed) {
        event.action = .release;
        _ = core.keyCallback(event) catch {};
    }
    log.info("press-key target={s} key={s} effect={s}", .{ target_name, key_name, @tagName(effect) });
    return std.fmt.allocPrint(c_alloc, "{{\"success\":true,\"effect\":\"{s}\"}}", .{@tagName(effect)});
}

/// The terminal pane a seam request names (`--target=`), or the error reply
/// that says why there is none.
const TerminalTarget = union(enum) {
    ok: struct { surface: *Surface, core: *CoreSurface },
    reply: []u8,
};

fn terminalTarget(app: Context, target_name: []const u8) Allocator.Error!TerminalTarget {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const target = switch (try resolve(arena_state.allocator(), app, target_name)) {
        .found => |t| t,
        .ambiguous => |windows| return .{ .reply = try server.errorResponse(c_alloc, "{s}", .{
            try target_lookup.ambiguityError(arena_state.allocator(), target_name, windows),
        }) },
        .not_found => return .{ .reply = try server.errorResponse(c_alloc, "pane '{s}' not found in registry", .{target_name}) },
    };
    const surface = target.surface() orelse
        return .{ .reply = try server.errorResponse(c_alloc, "pane '{s}' is no longer alive", .{target_name}) };
    const core = surface.core() orelse
        return .{ .reply = try server.errorResponse(c_alloc, "pane '{s}' has no terminal", .{target_name}) };
    return .{ .ok = .{ .surface = surface, .core = core } };
}

/// `pane-mouse --target=<pane> [--cell=<col>,<row>] [--mods=ctrl|shift|none]
/// [--button=press|release|click]` (T3565): the pointer the headless harness
/// does not have, over a terminal pane. `--cell` moves it to the CENTRE of
/// that viewport cell (0-based, converted through the pane's own cell size
/// and padding, so it lands where a real pointer over that glyph would),
/// delivered as a motion event with `--mods` held; `--button` then presses,
/// releases or clicks (press + release) the left button there with the same
/// mods. One request can do both, in that order; a drag is a press at one
/// cell and a release at another. Reply: `over_link` (the hover state a
/// link highlight and Copy URL key on) and the pixel position used.
fn paneMouse(app: Context, request: Request) Allocator.Error![]u8 {
    var target_arg: ?[]const u8 = null;
    var cell_arg: ?[]const u8 = null;
    var mods_arg: []const u8 = "none";
    var button_arg: ?[]const u8 = null;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--target=")) target_arg = arg["--target=".len..];
        if (std.mem.startsWith(u8, arg, "--cell=")) cell_arg = arg["--cell=".len..];
        if (std.mem.startsWith(u8, arg, "--mods=")) mods_arg = arg["--mods=".len..];
        if (std.mem.startsWith(u8, arg, "--button=")) button_arg = arg["--button=".len..];
    }
    const target_name = target_arg orelse return server.errorResponse(c_alloc, "--target is required for pane-mouse", .{});
    var mods: input.Mods = .{};
    if (std.mem.eql(u8, mods_arg, "ctrl")) {
        mods.ctrl = true;
    } else if (std.mem.eql(u8, mods_arg, "shift")) {
        mods.shift = true;
    } else if (!std.mem.eql(u8, mods_arg, "none")) {
        return server.errorResponse(c_alloc, "--mods must be ctrl, shift or none", .{});
    }

    const t = switch (try terminalTarget(app, target_name)) {
        .ok => |ok| ok,
        .reply => |r| return r,
    };

    if (cell_arg) |cell| {
        const comma = std.mem.indexOfScalar(u8, cell, ',') orelse
            return server.errorResponse(c_alloc, "--cell must be <col>,<row>", .{});
        const col = std.fmt.parseInt(u32, cell[0..comma], 10) catch
            return server.errorResponse(c_alloc, "--cell must be <col>,<row>", .{});
        const row = std.fmt.parseInt(u32, cell[comma + 1 ..], 10) catch
            return server.errorResponse(c_alloc, "--cell must be <col>,<row>", .{});
        const size = t.core.size;
        const corner = (renderer.Coordinate{ .grid = .{ .x = @intCast(col), .y = @intCast(row) } })
            .convert(.surface, size).surface;
        const pos: apprt.CursorPos = .{
            .x = @floatCast(corner.x + @as(f64, @floatFromInt(size.cell.width)) / 2),
            .y = @floatCast(corner.y + @as(f64, @floatFromInt(size.cell.height)) / 2),
        };
        if (!t.surface.testPointerMove(pos, mods))
            return server.errorResponse(c_alloc, "pane-mouse could not move the pointer", .{});
    }

    if (button_arg) |button| {
        const press = std.mem.eql(u8, button, "press") or std.mem.eql(u8, button, "click");
        const release = std.mem.eql(u8, button, "release") or std.mem.eql(u8, button, "click");
        if (!press and !release) return server.errorResponse(c_alloc, "--button must be press, release or click", .{});
        if (press) _ = t.core.mouseButtonCallback(.press, .left, mods) catch |err|
            return server.errorResponse(c_alloc, "pane-mouse press failed ({s})", .{@errorName(err)});
        if (release) _ = t.core.mouseButtonCallback(.release, .left, mods) catch |err|
            return server.errorResponse(c_alloc, "pane-mouse release failed ({s})", .{@errorName(err)});
    }

    const pos = t.surface.getCursorPos();
    log.info("pane-mouse target={s} x={d} y={d} over_link={}", .{ target_name, pos.x, pos.y, t.core.mouse.over_link });
    return std.fmt.allocPrint(c_alloc, "{{\"success\":true,\"over_link\":{},\"x\":{d},\"y\":{d}}}", .{
        t.core.mouse.over_link, pos.x, pos.y,
    });
}

/// `read-clipboard --target=<pane> --out=<file> [--primary]` (T3565): read
/// back what a copy in that pane offered - the standard clipboard, or with
/// `--primary` the PRIMARY selection copy-on-select fills - from the same
/// `GdkClipboard` the copy set (`Surface.testClipboard`). The headless Weston
/// the tests run in has no seat, so no OTHER Wayland client can be offered a
/// selection there at all; this is the reader that remains. GDK reads are
/// asynchronous and this runs on the main loop, so the reply only says the
/// read started: the text lands in `<out>` (written beside it and renamed
/// into place, so a waiter never sees half of it), or `<out>.err` with the
/// reason.
fn readClipboard(app: Context, request: Request) Allocator.Error![]u8 {
    var target_arg: ?[]const u8 = null;
    var out_arg: ?[]const u8 = null;
    var primary = false;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--target=")) target_arg = arg["--target=".len..];
        if (std.mem.startsWith(u8, arg, "--out=")) out_arg = arg["--out=".len..];
        if (std.mem.eql(u8, arg, "--primary")) primary = true;
    }
    const target_name = target_arg orelse return server.errorResponse(c_alloc, "--target is required for read-clipboard", .{});
    const out = out_arg orelse return server.errorResponse(c_alloc, "--out is required for read-clipboard", .{});
    if (out.len == 0 or out[0] != '/') return server.errorResponse(c_alloc, "--out must be an absolute path", .{});

    const t = switch (try terminalTarget(app, target_name)) {
        .ok => |ok| ok,
        .reply => |r| return r,
    };
    const clipboard = t.surface.testClipboard(if (primary) .selection else .standard) orelse
        return server.errorResponse(c_alloc, "the pane has no clipboard", .{});

    const path = try c_alloc.dupeZ(u8, out);
    clipboard.readTextAsync(null, readClipboardDone, path.ptr);
    log.info("read-clipboard target={s} primary={} local={} -> {s}", .{ target_name, primary, clipboard.isLocal() != 0, out });
    return std.fmt.allocPrint(c_alloc, "{{\"success\":true,\"started\":true,\"local\":{}}}", .{clipboard.isLocal() != 0});
}

/// `settings --op=<op>` (T3569): the Settings window, by the op names
/// win32's `ipc_settings.zig` uses, so the two acceptance scripts read
/// alike. Every op calls what the window's own signal handlers call.
///
///   --op=action                  perform `open_config` (the app action)
///   --op=state [--key=<k>]       open?, file, query, row count, and one key
///   --op=search --value=<q>      typing in the search field
///   --op=set --key=<k> --value=<v>   typing in the row + Return
///   --op=reset --key=<k>         the row's Reset button
///   --op=close                   the window's close button
fn settingsSeam(app: Context, request: Request) Allocator.Error![]u8 {
    const SettingsWindow = @import("SettingsWindow.zig");
    var op: []const u8 = "state";
    var key: ?[]const u8 = null;
    var val: ?[]const u8 = null;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--op=")) op = arg["--op=".len..];
        if (std.mem.startsWith(u8, arg, "--key=")) key = arg["--key=".len..];
        if (std.mem.startsWith(u8, arg, "--value=")) val = arg["--value=".len..];
    }

    var ok: ?bool = null;
    if (std.mem.eql(u8, op, "action")) {
        _ = app.performAction(.app, .open_config, {}) catch |err|
            return server.errorResponse(c_alloc, "open_config failed: {}", .{err});
    } else if (std.mem.eql(u8, op, "close")) {
        if (SettingsWindow.current()) |w| w.close();
    } else if (!std.mem.eql(u8, op, "state")) {
        const w = SettingsWindow.current() orelse
            return server.errorResponse(c_alloc, "the Settings window is not open", .{});
        if (std.mem.eql(u8, op, "search")) {
            w.setQuery(val orelse "");
        } else if (std.mem.eql(u8, op, "set") or std.mem.eql(u8, op, "reset")) {
            const k = key orelse return server.errorResponse(c_alloc, "--key is required for --op={s}", .{op});
            const result = if (std.mem.eql(u8, op, "set"))
                w.setValue(k, val orelse return server.errorResponse(c_alloc, "--value is required for --op=set", .{}))
            else
                w.resetKey(k);
            ok = result catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnknownKey => return server.errorResponse(c_alloc, "no setting named '{s}'", .{k}),
                error.Overridden => return server.errorResponse(c_alloc, "'{s}' is set by a file that loads later", .{k}),
                error.List => return server.errorResponse(c_alloc, "'{s}' is a list; this slice edits plain keys only", .{k}),
            };
        } else return server.errorResponse(c_alloc, "unknown --op '{s}'", .{op});
    }

    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(c_alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    writeSettingsState(&jws, arena, SettingsWindow.current(), key, ok) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeSettingsState(jws: *std.json.Stringify, arena: Allocator, w_opt: anytype, key: ?[]const u8, ok: ?bool) !void {
    try jws.beginObject();
    try jws.objectField("success");
    try jws.write(true);
    if (ok) |o| {
        try jws.objectField("ok");
        try jws.write(o);
    }
    try jws.objectField("open");
    try jws.write(w_opt != null);
    if (w_opt) |w| {
        try jws.objectField("file");
        try jws.write(w.mainPath());
        try jws.objectField("query");
        try jws.write(w.query.items);
        const keys = try w.visibleKeys(arena);
        try jws.objectField("matched");
        try jws.write(keys.len);
        try jws.objectField("rows");
        try jws.write(w.rows.items.len);
        if (key) |k| {
            try jws.objectField("key");
            try jws.beginObject();
            try jws.objectField("name");
            try jws.write(k);
            try jws.objectField("value");
            try jws.write(w.value(k));
            try jws.objectField("shown");
            try jws.write(w.shownValue(k));
            try jws.objectField("set_in_file");
            try jws.write(w.isSetInFile(k));
            try jws.objectField("modified");
            try jws.write(w.isModified(k));
            try jws.objectField("problem");
            try jws.write(w.problem(k));
            try jws.objectField("override");
            try jws.write(try w.overrideFor(arena, k));
            try jws.endObject();
        }
    }
    try jws.endObject();
}

/// `shortcut-guide --op=<op>` (T3570): the keyboard shortcut guide, by the op
/// names and reply shape of win32's `ipc_shortcut_guide.zig`, so the two
/// acceptance scripts read alike. Every op calls what the window's own
/// signal handlers call.
///
///   --op=action      perform `show_keyboard_shortcuts` (the app action)
///   --op=open        open the guide directly
///   --op=state       the model it shows
///   --op=select --down=<n>   Up/Down
///   --op=run         Return
///   --op=escape      Escape
///   --op=cheat-sheet write the cheat sheet (never opens it); reply names it
///   --op=shot --path=<file.png>   the window from its own render
///   --op=close       the title bar's close button
///   filters on any op: --query=<q> --category=<all|name> --unbound=<0|1>
/// `pane-seen --target=<pane|window> [--toplevel=minimized|suspended|shown|real]`
/// (T3571, docs/reference/background-windows.md): whether the target's
/// window and each of its panes can be seen, and the window's title as set
/// on the window beside the one it is holding. `--toplevel` stands in for
/// the compositor's toplevel state (`real` reads it again): the headless
/// Weston the harness runs in never minimizes or suspends a window, and the
/// reply's `reported` says what the compositor itself reports.
fn paneSeenSeam(app: Context, request: Request) Allocator.Error![]u8 {
    const window_seen = @import("window_seen.zig");
    var target_arg: ?[]const u8 = null;
    var toplevel_arg: ?[]const u8 = null;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--target=")) target_arg = arg["--target=".len..];
        if (std.mem.startsWith(u8, arg, "--toplevel=")) toplevel_arg = arg["--toplevel=".len..];
    }
    const target_name = target_arg orelse return server.errorResponse(c_alloc, "--target is required for pane-seen", .{});

    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = switch (try resolve(arena, app, target_name)) {
        .found => |t| t,
        .ambiguous => |windows| return server.errorResponse(c_alloc, "{s}", .{
            try target_lookup.ambiguityError(arena, target_name, windows),
        }),
        .not_found => return server.errorResponse(c_alloc, "pane '{s}' not found in registry", .{target_name}),
    };
    const window = target.window_();

    if (toplevel_arg) |t| {
        const state: ?window_seen.Toplevel = if (std.mem.eql(u8, t, "minimized"))
            .{ .minimized = true }
        else if (std.mem.eql(u8, t, "suspended"))
            .{ .suspended = true }
        else if (std.mem.eql(u8, t, "shown"))
            .{}
        else if (std.mem.eql(u8, t, "real"))
            null
        else
            return server.errorResponse(c_alloc, "--toplevel must be minimized, suspended, shown or real", .{});
        window.setToplevelOverride(state);
    }

    // What the compositor reports, with any stand-in set aside.
    const reported = window.reportedToplevelState();

    var out: std.Io.Writer.Allocating = .init(c_alloc);
    defer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    (struct {
        fn write(j: *std.json.Stringify, a: Context, w: *Window, rep: window_seen.Toplevel) !void {
            try j.beginObject();
            try j.objectField("success");
            try j.write(true);
            try j.objectField("data");
            try j.beginObject();
            try j.objectField("window");
            try j.beginObject();
            try j.objectField("seen");
            try j.write(w.isSeen());
            try j.objectField("mapped");
            try j.write(w.as(gtk.Widget).getMapped() != 0);
            try j.objectField("override");
            try j.write(w.hasToplevelOverride());
            try j.objectField("reported");
            try j.beginObject();
            try j.objectField("minimized");
            try j.write(rep.minimized);
            try j.objectField("suspended");
            try j.write(rep.suspended);
            try j.endObject();
            try j.objectField("title");
            try j.write(cstr(w.as(gtk.Window).getTitle()));
            try j.objectField("held_title");
            try j.write(w.heldTitle());
            try j.endObject();
            try j.objectField("panes");
            try j.beginArray();
            var it = paneIterator(a);
            while (it.next()) |p| {
                if (p.window != w) continue;
                try j.beginObject();
                try j.objectField("pane");
                try j.write(p.surface.paneId());
                try j.objectField("seen");
                try j.write(p.surface.isSeen());
                try j.objectField("mapped");
                try j.write(p.surface.as(gtk.Widget).getMapped() != 0);
                try j.endObject();
            }
            try j.endArray();
            try j.endObject();
            try j.endObject();
        }
    }).write(&jws, app, window, reported) catch return error.OutOfMemory;
    return c_alloc.dupe(u8, out.written());
}

fn shortcutGuideSeam(app: Context, request: Request) Allocator.Error![]u8 {
    const Guide = @import("ShortcutGuideWindow.zig");
    var op: []const u8 = "state";
    var q: ?[]const u8 = null;
    var cat: ?[]const u8 = null;
    var unbound: ?bool = null;
    var down: i32 = 1;
    var shot_path: ?[]const u8 = null;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--op=")) op = arg["--op=".len..];
        if (std.mem.startsWith(u8, arg, "--path=")) shot_path = arg["--path=".len..];
        if (std.mem.startsWith(u8, arg, "--query=")) q = arg["--query=".len..];
        if (std.mem.startsWith(u8, arg, "--category=")) cat = arg["--category=".len..];
        if (std.mem.startsWith(u8, arg, "--unbound=")) unbound = std.mem.eql(u8, arg["--unbound=".len..], "1");
        if (std.mem.startsWith(u8, arg, "--down=")) down = std.fmt.parseInt(i32, arg["--down=".len..], 10) catch
            return server.errorResponse(c_alloc, "--down must be an integer", .{});
    }
    const category: ?Guide.Category = if (cat) |c|
        (if (std.mem.eql(u8, c, "all")) null else std.meta.stringToEnum(Guide.Category, c) orelse
            return server.errorResponse(c_alloc, "--category must be all or a category name", .{}))
    else
        null;

    if (std.mem.eql(u8, op, "action")) {
        _ = app.performAction(.app, .show_keyboard_shortcuts, {}) catch |err|
            return server.errorResponse(c_alloc, "show_keyboard_shortcuts failed: {}", .{err});
    } else if (std.mem.eql(u8, op, "open")) {
        Guide.open(app);
    } else if (std.mem.eql(u8, op, "close")) {
        if (Guide.current()) |w| w.close();
        return writeGuideState(null, null, null);
    }
    const w = Guide.current() orelse
        return server.errorResponse(c_alloc, "the keyboard shortcut guide is not open", .{});

    // Filters apply in win32's fixed order: the toggle, the category, the
    // query (a query clears the category, so it goes last - as typing does).
    if (unbound) |u| w.setIncludeUnbound(u);
    if (cat != null) w.setCategory(category);
    if (q) |text| w.setQuery(text);

    var ran: ?bool = null;
    var sheet: ?[]u8 = null;
    defer if (sheet) |s| c_alloc.free(s);
    if (std.mem.eql(u8, op, "select")) {
        w.moveSelection(down);
    } else if (std.mem.eql(u8, op, "run")) {
        ran = w.runSelection();
    } else if (std.mem.eql(u8, op, "escape")) {
        w.escape();
    } else if (std.mem.eql(u8, op, "cheat-sheet")) {
        sheet = w.writeCheatSheet(c_alloc) catch |err|
            return server.errorResponse(c_alloc, "cheat sheet failed ({s})", .{@errorName(err)});
    } else if (std.mem.eql(u8, op, "shot")) {
        // The window from its own render (`pane_snapshot`), as win32's `shot`.
        const path = shot_path orelse return server.errorResponse(c_alloc, "--path=<file.png> is required for --op=shot", .{});
        const bytes = pane_snapshot.png(w.window) orelse
            return server.errorResponse(c_alloc, "the guide produced no frame to capture", .{});
        defer wk.g_bytes_unref(bytes);
        var len: usize = 0;
        const data = wk.g_bytes_get_data(bytes, &len) orelse
            return server.errorResponse(c_alloc, "the guide produced no frame to capture", .{});
        writeCapture(path, data[0..len]) catch |err|
            return server.errorResponse(c_alloc, "could not write '{s}' ({s})", .{ path, @errorName(err) });
    } else if (!std.mem.eql(u8, op, "state") and !std.mem.eql(u8, op, "open") and !std.mem.eql(u8, op, "action")) {
        return server.errorResponse(c_alloc, "unknown --op '{s}'", .{op});
    }
    return writeGuideState(Guide.current(), ran, sheet);
}

fn writeGuideState(w_opt: ?*const @import("ShortcutGuideWindow.zig"), ran: ?bool, sheet: ?[]const u8) Allocator.Error![]u8 {
    const catalog_mod = @import("../win32/shortcut_catalog.zig");
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(c_alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    (struct {
        fn write(j: *std.json.Stringify, a: Allocator, wo: anytype, r: ?bool, s: ?[]const u8) !void {
            try j.beginObject();
            try j.objectField("success");
            try j.write(true);
            try j.objectField("data");
            try j.beginObject();
            try j.objectField("open");
            try j.write(wo != null);
            if (r) |v| {
                try j.objectField("ran");
                try j.write(v);
            }
            if (s) |v| {
                try j.objectField("cheat_sheet");
                try j.write(v);
            }
            if (wo) |w| {
                try j.objectField("query");
                try j.write(w.query());
                try j.objectField("category");
                try j.write(if (w.category) |c| @tagName(c) else null);
                try j.objectField("include_unbound");
                try j.write(w.include_unbound);
                try j.objectField("bound");
                try j.write(w.bound_total);
                try j.objectField("customized");
                try j.write(w.customized_total);
                try j.objectField("all_count");
                try j.write(w.all_count);
                try j.objectField("selected");
                try j.write(if (w.selectedRow()) |row| row.id else null);
                try j.objectField("last_run");
                try j.write(w.lastRun());
                try j.objectField("counts");
                try j.beginObject();
                for (std.enums.values(catalog_mod.Category)) |c| {
                    try j.objectField(@tagName(c));
                    try j.write(w.counts[@intFromEnum(c)]);
                }
                try j.endObject();
                try j.objectField("rows");
                try j.beginArray();
                for (w.rows) |row| {
                    try j.beginObject();
                    try j.objectField("id");
                    try j.write(row.id);
                    try j.objectField("kind");
                    try j.write(@tagName(row.kind));
                    try j.objectField("title");
                    try j.write(row.title);
                    try j.objectField("category");
                    try j.write(@tagName(row.category));
                    try j.objectField("keys");
                    try j.beginArray();
                    for (row.bindings) |b| try j.write(try catalog_mod.bindingText(a, b));
                    try j.endArray();
                    try j.objectField("customized");
                    try j.write(row.customized);
                    try j.objectField("unbound_by_user");
                    try j.write(row.unbound_by_user);
                    try j.objectField("global");
                    try j.write(row.isGlobal());
                    try j.objectField("table");
                    try j.write(row.table());
                    try j.objectField("runnable");
                    try j.write(row.runnable);
                    try j.endObject();
                }
                try j.endArray();
            }
            try j.endObject();
            try j.endObject();
        }
    }).write(&jws, arena, w_opt, ran, sheet) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn readClipboardDone(source: ?*gobject.Object, res: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
    const path_ptr: [*:0]u8 = @ptrCast(ud orelse return);
    const path = std.mem.sliceTo(path_ptr, 0);
    defer c_alloc.free(path_ptr[0 .. path.len + 1]);
    const clipboard = gobject.ext.cast(gdk.Clipboard, source orelse return) orelse return;

    var gerr: ?*glib.Error = null;
    const text_ = clipboard.readTextFinish(res, &gerr);
    if (gerr) |err| {
        defer err.free();
        writeSeamFile(path, ".err", std.mem.sliceTo(err.f_message orelse "(no message)", 0));
        return;
    }
    const text = text_ orelse {
        writeSeamFile(path, ".err", "the clipboard holds no text");
        return;
    };
    defer glib.free(text);
    writeSeamFile(path, "", std.mem.sliceTo(text, 0));
}

/// Write `data` to `<path><suffix>` by way of a `.part` file renamed into
/// place, so a test polling for the file never reads a partial write.
fn writeSeamFile(path: []const u8, suffix: []const u8, data: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const final = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, suffix }) catch return;
    var part_buf: [std.fs.max_path_bytes]u8 = undefined;
    const part = std.fmt.bufPrint(&part_buf, "{s}.part", .{final}) catch return;
    const f = std.fs.createFileAbsolute(part, .{ .truncate = true }) catch return;
    f.writeAll(data) catch {
        f.close();
        return;
    };
    f.close();
    std.fs.renameAbsolute(part, final) catch {};
}

fn capturePane(app: Context, request: Request) Allocator.Error![]u8 {
    const req = capture_seam.parse(request.arguments) catch |err| return switch (err) {
        error.MissingTarget => server.errorResponse(c_alloc, "--target is required for capture-pane", .{}),
        error.MissingPath => server.errorResponse(c_alloc, "--path is required for capture-pane", .{}),
        error.BadDimension => server.errorResponse(c_alloc, "--width/--height must be 1..{d}", .{capture_seam.max_dimension}),
    };

    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const target = switch (try resolve(arena_state.allocator(), app, req.target)) {
        .found => |t| t,
        .ambiguous => |windows| return server.errorResponse(c_alloc, "{s}", .{
            try target_lookup.ambiguityError(arena_state.allocator(), req.target, windows),
        }),
        .not_found => return server.errorResponse(c_alloc, "pane '{s}' not found in registry", .{req.target}),
    };

    // Every failure names a different state, as win32's do: a harness that
    // cannot tell "no such pane" from "never drew" reports a product bug for
    // a fixture mistake.
    const window = target.window_();
    const widget: *gtk.Widget = if (req.window) window.as(gtk.Widget) else widget: {
        const surface = target.surface() orelse
            return server.errorResponse(c_alloc, "pane '{s}' is no longer alive", .{req.target});
        if (!surface.isViewer() and surface.core() == null)
            return server.errorResponse(c_alloc, "pane '{s}' is not capturable: its terminal never finished starting up", .{req.target});
        break :widget surface.as(gtk.Widget);
    };
    const w: *wk.GtkWidget = @ptrCast(widget);

    const scale = wk.gtk_widget_get_scale_factor(w);
    const p = capture_seam.plan(wk.gtk_widget_get_width(w), wk.gtk_widget_get_height(w), scale, .{
        .target = req.target,
        .path = req.path,
        .width = req.width,
        .height = req.height,
    }) orelse return server.errorResponse(c_alloc, "pane '{s}' has no content area to capture", .{req.target});

    const bytes = pane_snapshot.render(w, p.w, p.h, p.sx, p.sy) orelse
        return server.errorResponse(c_alloc, "pane '{s}' produced no frame to capture", .{req.target});
    defer wk.g_bytes_unref(bytes);
    var len: usize = 0;
    const data = wk.g_bytes_get_data(bytes, &len) orelse
        return server.errorResponse(c_alloc, "pane '{s}' produced no frame to capture", .{req.target});
    const png = data[0..len];

    writeCapture(req.path, png) catch |err|
        return server.errorResponse(c_alloc, "could not write '{s}' ({s})", .{ req.path, @errorName(err) });

    // Where the widget sits in its window, device pixels (Wayland has no
    // screen coordinates; a window capture is at 0,0 by definition).
    const s: f32 = @floatFromInt(@max(1, scale));
    var bounds: wk.GrapheneRect = .{};
    if (!req.window) _ = wk.gtk_widget_compute_bounds(w, @ptrCast(window.as(gtk.Widget)), &bounds);
    const client_w: u32 = @intCast(@max(1, wk.gtk_widget_get_width(w)) * @max(1, scale));
    const client_h: u32 = @intCast(@max(1, wk.gtk_widget_get_height(w)) * @max(1, scale));

    log.info("capture-pane target={s} scope={s} {d}x{d} -> {s} ({d} bytes)", .{
        req.target, if (req.window) "window" else "pane", p.w, p.h, req.path, png.len,
    });
    return capture_seam.successJson(c_alloc, .{
        .path = req.path,
        .width = p.w,
        .height = p.h,
        .bytes = png.len,
        .x = @intFromFloat(@round(bounds.x * s)),
        .y = @intFromFloat(@round(bounds.y * s)),
        .client_width = client_w,
        .client_height = client_h,
        .window = req.window,
    });
}

/// Create/truncate, not atomic: the reader is the harness that asked for this
/// exact path a moment ago (win32's `ipc_capture.writeFile`).
fn writeCapture(path: []const u8, bytes: []const u8) !void {
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{ .truncate = true })
    else
        try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

// ---------------------------------------------------------------------------
// +set-state and +set-banner (T3339): the shared bodies in
// `apprt/ipc/verbs.zig` (T3374), over the two model functions below.

pub fn handleSetState(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.setState(@This(), app, request);
}

pub fn handleSetBanner(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.setBanner(@This(), app, request);
}

/// A pane target sets that pane; a window target every terminal pane in the
/// window (the Mac's `handleSetState`). A viewer pane has no state to carry.
pub fn setActivityState(target: Target, state: verbs.ActivityState) bool {
    const core_state: terminal_osc.ActivityState = switch (state) {
        .idle => .idle,
        .busy => .busy,
        .needs_input => .needs_input,
    };
    switch (target) {
        .pane => |p| {
            if (p.surface.isViewer()) return false;
            p.surface.setActivityState(core_state);
        },
        .window => |w| {
            var it = paneIterator(Application.default());
            while (it.next()) |p| {
                if (p.window != w or p.surface.isViewer()) continue;
                p.surface.setActivityState(core_state);
            }
        },
    }
    return true;
}

/// The pane's banner, or a window's focused pane's (banners are per pane).
pub fn setPaneBanner(target: Target, text: ?[]const u8) verbs.BannerSet {
    const s = target.surface() orelse return .no_pane;
    if (s.isViewer()) return .viewer;
    s.setPaneBanner(text);
    return .set;
}

// ---------------------------------------------------------------------------
// Walking the live windows and panes.

const WindowIterator = struct {
    node: ?*glib.List,

    fn next(self: *WindowIterator) ?*Window {
        while (self.node) |n| {
            self.node = n.f_next;
            const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
            if (gobject.ext.cast(Window, obj)) |w| return w;
        }
        return null;
    }
};

fn windowIterator(app: Context) WindowIterator {
    return .{ .node = app.as(gtk.Application).getWindows() };
}

pub const PaneAt = struct { window: *Window, surface: *Surface };

/// Every terminal pane in every window and tab, in order.
const PaneIterator = struct {
    windows: WindowIterator,
    window: ?*Window = null,
    tab: usize = 0,
    tree: ?*const Surface.Tree = null,
    leaf: usize = 0,

    fn next(self: *PaneIterator) ?PaneAt {
        while (true) {
            if (self.tree) |tree| {
                while (self.leaf < tree.nodes.len) {
                    const i = self.leaf;
                    self.leaf += 1;
                    switch (tree.nodes[i]) {
                        .leaf => |s| return .{ .window = self.window.?, .surface = s },
                        .split => {},
                    }
                }
                self.tree = null;
            }
            const window = self.window orelse {
                self.window = self.windows.next() orelse return null;
                self.tab = 0;
                continue;
            };
            const tab_view = window.getTabView();
            const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
            if (self.tab >= pages) {
                self.window = null;
                continue;
            }
            const page = tab_view.getNthPage(@intCast(self.tab));
            self.tab += 1;
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            self.tree = tab.getSplitTree().getTree() orelse continue;
            self.leaf = 0;
        }
    }
};

fn paneIterator(app: Context) PaneIterator {
    return .{ .windows = windowIterator(app) };
}

/// A window's IPC name, minting `window-N` the first time one is asked for
/// (win32 mints at creation; the name a caller sees is the same either way).
/// Null only on OOM.
var window_counter: u64 = 0;

pub fn windowName(app: Context, window: *Window) ?[]const u8 {
    if (window.ipcName()) |n| return n;
    var buf: [32]u8 = undefined;
    // Bounded: a pane can be named `window-N` too.
    for (0..64) |_| {
        window_counter += 1;
        const name = std.fmt.bufPrint(&buf, "window-{d}", .{window_counter}) catch return null;
        if (nameTaken(app, name)) continue;
        window.setIpcName(name);
        return window.ipcName();
    }
    return null;
}

/// Whether any window or pane already holds `name` (for minting, and for a
/// restored relay window that must not steal a name, T3671).
pub fn nameTaken(app: Context, name: []const u8) bool {
    var windows = windowIterator(app);
    while (windows.next()) |w| {
        if (w.ipcName()) |n| if (std.mem.eql(u8, n, name)) return true;
    }
    var panes = paneIterator(app);
    while (panes.next()) |p| {
        if (p.surface.ipcName()) |n| if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// A window or a pane: the window-or-pane verbs' `Target` (verbs.zig, T3374).
pub const Target = union(enum) {
    window: *Window,
    pane: PaneAt,

    fn window_(self: Target) *Window {
        return switch (self) {
            .window => |w| w,
            .pane => |p| p.window,
        };
    }

    /// The pane a target means: the pane, or a window's active pane.
    fn surface(self: Target) ?*Surface {
        return switch (self) {
            .window => |w| w.getActiveSurface(),
            .pane => |p| p.surface,
        };
    }
};

pub const Resolved = union(enum) {
    found: Target,
    /// Panes in several windows hold the name, none of them the caller's.
    ambiguous: []const []const u8,
    not_found,
};

/// What `name` means, by T2250's order: a pane id first (an id names exactly
/// one pane), then `target_lookup.pick` over the named windows and panes.
pub fn resolve(arena: Allocator, app: Context, name: []const u8) Allocator.Error!Resolved {
    var panes = paneIterator(app);
    while (panes.next()) |p| {
        if (std.mem.eql(u8, p.surface.paneId(), name)) return .{ .found = .{ .pane = p } };
    }

    var candidates: std.ArrayList(target_lookup.Candidate) = .empty;
    var targets: std.ArrayList(Target) = .empty;
    var windows = windowIterator(app);
    while (windows.next()) |w| {
        const wn = windowName(app, w) orelse continue;
        if (!std.mem.eql(u8, wn, name)) continue;
        try candidates.append(arena, .{ .kind = .window, .window_name = wn });
        try targets.append(arena, .{ .window = w });
    }
    panes = paneIterator(app);
    while (panes.next()) |p| {
        const n = p.surface.ipcName() orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        try candidates.append(arena, .{
            .kind = .pane,
            .window_name = windowName(app, p.window) orelse "",
            .in_caller_window = caller_window != null and p.window == caller_window.?,
        });
        try targets.append(arena, .{ .pane = p });
    }

    return switch (try target_lookup.pick(arena, candidates.items)) {
        .found => |i| .{ .found = targets.items[i] },
        .ambiguous => |w| .{ .ambiguous = w },
        .not_found => .not_found,
    };
}

/// `resolve` with no caller window: what a GLOBAL name (a window's) means.
fn resolveGlobal(arena: Allocator, app: Context, name: []const u8) Allocator.Error!Resolved {
    const saved = caller_window;
    caller_window = null;
    defer caller_window = saved;
    return resolve(arena, app, name);
}

/// The reply for a name `resolve` did not find: the ambiguity sentence when
/// several windows hold it, else the handler's own not-found text.
pub fn missingResponse(
    arena: Allocator,
    resolved: Resolved,
    name: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error![]u8 {
    switch (resolved) {
        .ambiguous => |windows| {
            const msg = try target_lookup.ambiguityError(arena, name, windows);
            return try server.errorResponse(c_alloc, "{s}", .{msg});
        },
        else => return try server.errorResponse(c_alloc, fmt, args),
    }
}

/// The window a default-target verb means: the active one, else the most
/// recently created (the head of GTK's window list is the most recent).
fn frontWindow(app: Context) ?*Window {
    var first: ?*Window = null;
    var windows = windowIterator(app);
    while (windows.next()) |w| {
        if (w.as(gtk.Window).isActive() != 0) return w;
        if (first == null) first = w;
    }
    return first;
}

// ---------------------------------------------------------------------------
// The pane a new window or split runs.

/// The shell `--command` runs in: `--shell`, then `command-shell`, then
/// `$SHELL`, then `/bin/sh` (the Mac's `resolveShell`, less its passwd
/// lookup: a pane without `$SHELL` is a broken login anyway).
fn resolveShell(app: Context, shell_flag: ?[]const u8) []const u8 {
    if (server.nonEmpty(shell_flag)) |s| return s;
    const config = app.getConfig();
    defer config.unref();
    if (config.get().@"command-shell") |s| if (s.len > 0) return s;
    if (std.posix.getenv("SHELL")) |s| if (s.len > 0) return s;
    return "/bin/sh";
}

/// The command a new pane runs (null: the configured shell). `-e` execs its
/// argv verbatim; `--command` runs in a login shell that stays open after it
/// (the Mac's `wrapCommandInShell`: `<sh> -lic '<cmd>; exec <sh> -li'`), so a
/// pane opened to run something is still a pane `+send-keys` can drive;
/// `--shell` alone opens that shell (T1665).
fn paneCommand(
    arena: Allocator,
    app: Context,
    e_args: []const [:0]const u8,
    command: ?[]const u8,
    shell_flag: ?[]const u8,
) Allocator.Error!?configpkg.Command {
    if (e_args.len > 0) return .{ .direct = e_args };
    if (server.nonEmpty(command)) |cmd| {
        const sh = resolveShell(app, shell_flag);
        var escaped: std.ArrayList(u8) = .empty;
        for (cmd) |ch| {
            if (ch == '\'') try escaped.appendSlice(arena, "'\\''") else try escaped.append(arena, ch);
        }
        return .{ .shell = try std.fmt.allocPrintSentinel(
            arena,
            "{s} -lic '{s}; exec {s} -li'",
            .{ sh, escaped.items, sh },
            0,
        ) };
    }
    if (server.nonEmpty(shell_flag)) |sh| {
        const argv = try arena.alloc([:0]const u8, 1);
        argv[0] = try arena.dupeZ(u8, sh);
        return .{ .direct = argv };
    }
    return null;
}

/// `--env` plus the pane/window name variables, as `KEY=VALUE` strings.
fn paneEnv(
    arena: Allocator,
    env: []const verb_args.EnvVar,
    window_name: ?[]const u8,
    pane_name: ?[]const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (env) |e| try out.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ e.key, e.value }));
    if (window_name) |w| try out.append(arena, try std.fmt.allocPrint(arena, "GHOZTTY_WINDOW_NAME={s}", .{w}));
    if (pane_name) |p| try out.append(arena, try std.fmt.allocPrint(arena, "GHOZTTY_PANE_NAME={s}", .{p}));
    return out.items;
}

fn workingDirectory(arena: Allocator, wd: ?[]const u8) Allocator.Error!?[:0]const u8 {
    const v = server.nonEmpty(wd) orelse return null;
    return try arena.dupeZ(u8, v);
}

/// A `ghoztty://` link clicked in a viewer pane (T3415; win32's
/// `handleUrlSchemeLink`): the scheme's one action, `focus`, run in THIS app
/// through the shared verb body - so the name is looked up from the clicking
/// pane's window first and an unknown or ambiguous name fails the way the
/// CLI's does. Never handed to the desktop, which would reach whichever build
/// registered the scheme. A link that focuses nothing - a malformed one, or a
/// name nothing (or more than one window) holds - says so in the scheme's
/// `Can't focus` dialog (T3579), as the Mac's `GhozttyURLScheme.Failure` and
/// win32's `handleInApp` do; it never logs alone.
pub fn focusLink(app: Context, url: []const u8, caller_pane: ?[]const u8) void {
    var name_buf: [url_activation.max_target]u8 = undefined;
    const cmd = url_scheme.parse(url, &name_buf) orelse {
        log.info("viewer link: unsupported ghoztty link {s}", .{url});
        return gtk_url_scheme.present(.{ .unsupported_link = url }, app);
    };
    switch (cmd) {
        .focus => |name| {
            var arg_buf: [600]u8 = undefined;
            const arg = std.fmt.bufPrint(&arg_buf, "--target={s}", .{name}) catch
                return gtk_url_scheme.present(.{ .unsupported_link = url }, app);
            const argv = [_][]const u8{arg};
            const reply = verbs.focus(@This(), app, .{
                .action = "focus",
                .arguments = &argv,
                .caller_pane = caller_pane,
            }) catch return;
            const r = reply orelse return;
            defer replyAllocator(app).free(r);
            log.info("viewer link: focus {s}: {s}", .{ name, r });
            const outcome = url_activation.replyOutcome(r);
            if (url_activation.failureFor(outcome, name)) |f| gtk_url_scheme.present(f, app);
        },
    }
}

/// Raise and focus a target: `--focus` on a verb, and the `focus` action. A
/// pane goes through the surface's own present request, which selects its
/// tab first (a pane in a background tab is otherwise focused out of sight,
/// win32's T555) and then raises the window - the one path a bell or a
/// notification click takes too. Raising is `gtk_window_present`, which on
/// Wayland is an xdg-activation request the compositor may decline; inside
/// the app the pane is focused either way. The default (no `--focus`) never
/// asks. Whether the compositor said yes is logged a moment later
/// (`watchActivation`), since it answers after the reply has gone (T3381).
pub fn focusTarget(target: Target) void {
    const window = target.window_();
    if (target.surface()) |s| {
        if (tabOf(window, s)) |tab| tab.getSplitTree().focusSurface(s);
        s.present();
    } else window.as(gtk.Window).present();
    watchActivation(window);
}

/// The note a `--focus` reply carries when the request cannot be expected to
/// raise anything: no window of this app holds the keyboard, so the
/// activation request goes out with no recent input of ours behind it, and a
/// Wayland compositor (or an X11 window manager's focus-stealing prevention)
/// may keep the window behind the active app. Null when one of ours is
/// active, which is the usual case of a command run from a Ghoztty pane.
/// Read BEFORE anything is created or raised (T3381).
pub fn focusNote(app: Context) ?[]const u8 {
    var windows = windowIterator(app);
    while (windows.next()) |w| if (w.as(gtk.Window).isActive() != 0) return null;
    return focus_may_be_declined;
}

pub const focus_may_be_declined = "--focus: Ghoztty is not the active app, so the compositor may keep the window behind the app that is (it asks through xdg-activation); the pane is focused inside its window either way";

/// How long the compositor gets to answer an activation request before the
/// app logs what it decided.
const activation_check_ms = 1000;

/// Log, once the compositor has had time to answer, whether `--focus`
/// actually activated `window` - the only place a declined request shows,
/// since `present` returns before the compositor decides (T3381).
fn watchActivation(window: *Window) void {
    _ = window.as(gobject.Object).ref();
    _ = glib.timeoutAdd(activation_check_ms, activationChecked, window);
}

fn activationChecked(ud: ?*anyopaque) callconv(.c) c_int {
    const window: *Window = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
    defer window.as(gobject.Object).unref();
    if (window.as(gtk.Window).isActive() != 0)
        log.info("focus: the compositor activated the window", .{})
    else
        log.info("focus: the compositor declined to activate the window; the pane is focused inside it", .{});
    return @intFromBool(glib.SOURCE_REMOVE);
}

// ---------------------------------------------------------------------------
// focus (the `ghoztty://` scheme's one action) and +close

/// `focus` (the `ghoztty://` scheme's one action) and `+close` are the shared
/// bodies in `apprt/ipc/verbs.zig` (T3374), over the model below: the same
/// arguments, the same sentences and the same idempotence as win32.
pub fn handleFocus(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.focus(@This(), app, request);
}

pub fn handleClose(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.close(@This(), app, request);
}

/// `+reload` (T3413): the shared body in `apprt/ipc/verbs.zig`, win32's
/// arguments and sentences. A viewer pane (or a window's focused one) reloads
/// in place, bypassing caches; `--config` reloads the app's configuration.
pub fn handleReload(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.reload(@This(), app, request);
}

/// `+reload --config` (T3369): the GTK `reload_config` action, hard (the
/// config files are read again, as SIGUSR2 and the menu item do), app-wide -
/// win32's T893 body, so both answer with the same sentence on failure. The
/// action propagates through `config_change` to every window and terminal.
pub fn reloadConfig(app: Context, arena: Allocator) Allocator.Error!?[]const u8 {
    _ = app.performAction(.app, .reload_config, .{ .soft = false }) catch |err| {
        return try std.fmt.allocPrint(arena, "config reload failed: {}", .{err});
    };
    return null;
}

pub fn reloadViewer(target: Target) verbs.ReloadOutcome {
    const s = target.surface() orelse return .gone;
    const viewer = s.getViewer() orelse return switch (target) {
        .pane => .terminal,
        .window => .focused_terminal,
    };
    viewer.reloadContent(.chrome);
    return .reloaded;
}

/// What a name means, by T2250's order (`resolve`), or the ambiguity sentence.
pub fn lookupTarget(app: Context, arena: Allocator, name: []const u8) Allocator.Error!verbs.TargetLookup(Target) {
    return switch (try resolve(arena, app, name)) {
        .found => |t| .{ .found = t },
        .ambiguous => |windows| .{ .ambiguous = try target_lookup.ambiguityError(arena, name, windows) },
        .not_found => .not_found,
    };
}

/// A dialog is up over the window (T2938, Mac `attachedSheet`).
pub fn closeConfirmationOpen(target: Target) bool {
    return target.window_().hasOpenDialog();
}

/// `--force` dismisses it unanswered. GTK dialogs are not modal loops on this
/// stack (win32's are), so the close follows at once.
pub fn dismissConfirmations(_: Context, target: Target, name: []const u8) verbs.Dismissed {
    const window = target.window_();
    // Bounded: a dialog may still read as visible while it animates out.
    for (0..8) |_| if (!window.dismissOpenDialog()) break;
    log.info("IPC: +close --force '{s}': dismissed the confirmation", .{name});
    return .close_now;
}

/// Close a pane (its window too, when it was the last one) or a window, with
/// no confirmation. A pane is parked for undo like a keyboard close (T3384),
/// unless `--force` (T2938, Mac `forceCloseSurface`): no undo, it ends now.
pub fn closeTarget(_: Context, target: Target, force: bool) bool {
    switch (target) {
        .pane => |p| {
            const tab = tabOf(p.window, p.surface) orelse return false;
            const was = CloseUndo.bypass;
            CloseUndo.bypass = force;
            defer CloseUndo.bypass = was;
            return tab.getSplitTree().closeSurfaceNow(p.surface);
        },
        .window => |w| w.as(gtk.Window).destroy(),
    }
    return true;
}

// ---------------------------------------------------------------------------
// +new-window, +split, +rename: the shared bodies in `apprt/ipc/verbs.zig`
// (T3375) - win32's argument checks, idempotence, name collisions, anchor
// precedence, sentences and replies - over the model below, which only builds
// the window or the pane.

pub fn handleNewWindow(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.newWindow(@This(), app, request);
}

pub fn handleSplit(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.split(@This(), app, request);
}

pub fn handleRename(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.rename(@This(), app, request);
}

/// What a WINDOW name means: `resolve` with no caller window, since window
/// names are global (T2250). A name panes hold is refused as a window name
/// whatever they are, so the ambiguity needs no sentence.
pub fn lookupWindowName(app: Context, arena: Allocator, name: []const u8) Allocator.Error!verbs.TargetLookup(Target) {
    return switch (try resolveGlobal(arena, app, name)) {
        .found => |t| .{ .found = t },
        .ambiguous => .{ .ambiguous = "" },
        .not_found => .not_found,
    };
}

pub fn isPane(target: Target) bool {
    return target == .pane;
}

/// Open the window `+new-window` asked for, once the shared checks passed.
/// A `--from-focused` window on a REMOTE front window never reaches here:
/// `newWindowFromFocused` opens it on that machine (T3597).
pub fn openWindow(
    app: Context,
    arena: Allocator,
    request: Request,
    args: verb_args.VerbArgs,
    plan: verbs.WindowPlan,
) Allocator.Error!verbs.Opened {
    _ = request;
    // `--focus` (T1797, T3381): only then is the window presented (an
    // activation request); without it the window is shown in the background.
    // Whether the request can be expected to work is read before the window
    // exists, since the new window is not active yet either.
    const note: ?[]const u8 = if (args.focus) focusNote(app) else null;
    // `--view` (T3411): the first pane is a VIEWER, with no shell to build a
    // command, cwd or environment for. The inline split's pane is still a
    // terminal, as on win32.
    const view = try viewLocation(arena, args);
    // A viewer keeps the cwd, though: it is the repository a `git-diff:` /
    // `git-status:` view diffs (T3417).
    const window = if (view) |location|
        app.newWindowForIpc(null, try workingDirectory(arena, args.working_directory), &.{}, location, args.focus)
    else
        app.newWindowForIpc(
            try paneCommand(arena, app, args.e_args, args.command, args.shell),
            try workingDirectory(arena, args.working_directory),
            try paneEnv(arena, args.env, args.target, plan.first_pane_env_name),
            null,
            args.focus,
        );
    if (args.focus) watchActivation(window);

    if (args.target) |t| window.setIpcName(t) else _ = windowName(app, window);
    if (plan.first_pane_name) |n| if (window.getActiveSurface()) |s| s.setIpcName(n);

    // T92: an empty `--title=` means "no pin".
    if (args.title) |title| if (title.len > 0) window.setTitleOverride(title);

    // The window's gradient desk (T3566): a programmatic window is on the
    // shared ocean unless `--color=random` in the elevated style gives it
    // its OWN gradient - and then the terminal keeps its theme colour.
    // Otherwise `--color` (T67, T3382) tints the window's first pane -
    // background, contrast foreground and adjusted palette (Mac
    // applyColorScheme).
    const style = style: {
        const config = app.getConfig();
        defer config.unref();
        break :style Window.paneStyleOf(config.get());
    };
    window.setDeskVariant(pane_style.variantForColor(args.color, style));
    if (!pane_style.colorIsWindowGradient(args.color, style)) {
        if (resolveColor(args.color)) |tint| if (window.getActiveSurface()) |s| s.applyBackgroundTint(tint);
    }

    // DEBUG-ONLY test seam (T3367): the window named by
    // GHOZTTY_TEST_ASK_TO_CLOSE opens with its close confirmation up, so
    // `+close` over a dialog can be tested with no input to raise one.
    if (comptime build_config.is_debug) if (std.posix.getenv("GHOZTTY_TEST_ASK_TO_CLOSE")) |want| {
        if (args.target) |t| if (std.mem.eql(u8, t, want)) window.testAskToClose();
    };

    // The inline split. One that fails leaves the window, which is what was
    // asked for, so the reply stays `created` (win32's answer).
    if (plan.split) |dir| split: {
        const tab = window.getSelectedTab() orelse {
            log.warn("IPC inline split failed: the new window has no tab", .{});
            break :split;
        };
        const parent = window.getActiveSurface();
        const split_cmd = server.nonEmpty(args.split_command);
        const s = tab.getSplitTree().newSplitAt(treeDirection(dir), parent, .{
            .command = if (split_cmd) |cmd| try paneCommand(arena, app, &.{}, cmd, args.shell) else null,
            .env = try paneEnv(arena, &.{}, args.target, args.name),
            .at = parent,
            .focus = args.focus,
        }) catch |err| {
            log.warn("IPC inline split failed err={}", .{err});
            break :split;
        };
        // `--split-color` (T67): the inline split's own tint, over the one
        // it inherited from the first pane.
        if (resolveColor(args.split_color)) |tint| s.applyBackgroundTint(tint);
        if (args.name) |n| s.setIpcName(n);
    }

    return .{ .created = note };
}

pub const WindowHandle = *Window;
pub const PaneHandle = PaneAt;

pub fn windowOfTarget(target: Target) *Window {
    return target.window_();
}

pub fn paneOfTarget(target: Target) ?PaneAt {
    return switch (target) {
        .pane => |p| p,
        .window => null,
    };
}

pub fn paneTarget(pane: PaneAt) Target {
    return .{ .pane = pane };
}

pub fn paneWindow(pane: PaneAt) *Window {
    return pane.window;
}

pub fn activePane(window: *Window) ?PaneAt {
    const surface = window.getActiveSurface() orelse return null;
    return .{ .window = window, .surface = surface };
}

pub fn defaultWindow(app: Context) ?*Window {
    return frontWindow(app);
}

pub fn callerPane(app: Context, args: verb_args.VerbArgs) ?PaneAt {
    return callerAnchor(app, args);
}

pub fn paneId(pane: PaneAt) []const u8 {
    return pane.surface.paneId();
}

/// What holds `name` where a `+split --name` into `window` would put it, for
/// `split_name_collision`: a window of that name anywhere (window names are
/// global), else a pane of that name in `window`.
pub fn nameHolderIn(app: Context, name: []const u8, window: *Window) ?verbs.NameHolder(Target) {
    var windows = windowIterator(app);
    while (windows.next()) |w| {
        const wn = windowName(app, w) orelse continue;
        if (std.mem.eql(u8, wn, name)) return .{
            .target = .{ .window = w },
            .existing = .{ .kind = .window, .window_name = wn },
        };
    }
    const p = namedPaneIn(window, app, name) orelse return null;
    // A viewer of that name is "already what was asked for" only when it
    // shows the same thing (T2184's reuse rule, decided in the shared code).
    const kind: @FieldType(verbs.NameHolder(Target), "existing").Kind = if (p.surface.getViewer()) |v|
        .{ .viewer = .{ .location = v.currentLocation(), .home_location = v.location } }
    else
        .terminal;
    return .{
        .target = .{ .pane = p },
        .existing = .{ .kind = kind, .window_name = windowName(app, window) orelse "" },
    };
}

/// The resolved `--view` location, or null when this is not a viewer
/// request (T3411). Relative paths resolve against `--working-directory`,
/// which the CLI seeds with the caller's cwd; `git-*:` specs, URLs and
/// `about:blank` pass through.
fn viewLocation(arena: Allocator, args: verb_args.VerbArgs) Allocator.Error!?[:0]const u8 {
    const view = server.nonEmpty(args.view) orelse return null;
    return try viewer_scheme.resolveLocation(arena, view, server.nonEmpty(args.working_directory));
}

fn treeDirection(dir: verbs.SplitDirection) Surface.Tree.Split.Direction {
    return switch (dir) {
        .right => .right,
        .down => .down,
        .left => .left,
        .up => .up,
    };
}

/// Open the pane `+split` asked for at `at`, named `--name` (not for
/// `--from-focused`, which mirrors the keyboard split: it inherits everything
/// and names nothing). Null when none opened.
pub fn createSplit(
    app: Context,
    arena: Allocator,
    args: verb_args.VerbArgs,
    window: *Window,
    at: PaneAt,
    spec: verbs.SplitSpec,
) Allocator.Error!?PaneAt {
    const tab = tabOf(window, at.surface) orelse return null;
    const inherit = spec.inherit;
    const name: ?[]const u8 = if (inherit) null else args.name;

    // `--view` (T3411): a VIEWER split. None of the shell plumbing below
    // applies - no command, cwd or environment to give a pane with no pty.
    if (try viewLocation(arena, args)) |location| {
        const surface = tab.getSplitTree().newSplitAt(treeDirection(spec.direction), at.surface, .{
            .view = location,
            // The repository a diff view diffs (T3417).
            .working_directory = try workingDirectory(arena, args.working_directory),
            .at = at.surface,
            .ratio = spec.ratio,
            .focus = args.focus,
        }) catch |err| {
            log.warn("IPC viewer split failed err={}", .{err});
            return null;
        };
        if (name) |n| surface.setIpcName(n);
        return .{ .window = window, .surface = surface };
    }

    const command = args.split_command orelse args.command;
    const surface = tab.getSplitTree().newSplitAt(treeDirection(spec.direction), at.surface, .{
        .command = if (inherit) null else try paneCommand(arena, app, args.e_args, command, args.shell),
        .working_directory = if (inherit) null else try workingDirectory(arena, args.working_directory),
        .env = if (inherit) &.{} else try paneEnv(arena, args.env, windowName(app, window), name),
        .at = at.surface,
        .ratio = spec.ratio,
        .focus = args.focus,
        // T3597: off a remote machine's pane, `--command` is that machine's
        // to run, verbatim - never the local shell wrapping above.
        .remote_command = if (inherit) null else server.nonEmpty(command),
    }) catch |err| {
        log.warn("IPC split failed err={}", .{err});
        return null;
    };
    // `--color` (T67): the new pane's own tint, over the one it inherited.
    if (resolveColor(args.color)) |tint| surface.applyBackgroundTint(tint);
    if (name) |n| surface.setIpcName(n);
    return .{ .window = window, .surface = surface };
}

/// A `--color` / `--split-color` value: `#rgb`, `#rrggbb`, or `random` (a
/// fresh dark muted color, the Mac randomDarkColor). Null for none or for
/// anything else (win32 `resolveColor`).
fn resolveColor(value: ?[]const u8) ?color_math.Rgb {
    const v = value orelse return null;
    if (std.mem.eql(u8, v, "random")) return color_math.randomDark(std.crypto.random);
    return color_math.parseHex(v);
}

/// Pin `title` on the target's window (null clears it, T92). The GTK app has
/// no user-set WINDOW title yet (its prompts title a tab or a pane), so
/// T2404's "the user's title outranks a script's" has nothing to keep here.
pub fn renameWindow(_: Context, target: Target, title: ?[]const u8) verbs.Renamed {
    target.window_().setTitleOverride(title);
    return .renamed;
}

/// The pane in `window` named `name`.
fn namedPaneIn(window: *Window, app: Context, name: []const u8) ?PaneAt {
    var it = paneIterator(app);
    while (it.next()) |p| {
        if (p.window != window) continue;
        const n = p.surface.ipcName() orelse continue;
        if (std.mem.eql(u8, n, name)) return p;
    }
    return null;
}

/// The tab holding `surface` in `window`.
pub fn tabOf(window: *Window, surface: *Surface) ?*Tab {
    const tab_view = window.getTabView();
    const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
    for (0..pages) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
        const tree = tab.getSplitTree().getTree() orelse continue;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return tab;
        }
    }
    return null;
}

/// The pane a command with no explicit anchor splits off: the one it was run
/// from (`--caller-pane`, T1079), when it still exists.
fn callerAnchor(app: Context, args: verb_args.VerbArgs) ?PaneAt {
    const id = verb_args.callerAnchorPane(args, app, paneAlive) orelse return null;
    var it = paneIterator(app);
    while (it.next()) |p| {
        if (std.mem.eql(u8, p.surface.paneId(), id)) return p;
    }
    return null;
}

fn paneAlive(app: Context, id: []const u8) bool {
    var it = paneIterator(app);
    while (it.next()) |p| {
        if (std.mem.eql(u8, p.surface.paneId(), id)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// +rearrange (T3368)

/// `+rearrange --layout=<json>`: replace the active tab's whole split layout
/// with one whose every leaf names a pane already in it, so panes MOVE rather
/// than being created. Win32's `handleRearrange` order and sentences: the
/// shared `validateLayout` / `firstDuplicate` checks first, then the window
/// (`--target`, else the caller's window, T1079, else the front one), then
/// every pane against that window's active tab. A pane the layout omits is
/// closed (T128) - parked for `undo-timeout` first, so Ctrl+Shift+Z puts the
/// previous layout back with it (T3384, `CloseUndo.rearrange`).
pub fn handleRearrange(app: Context, request: Request) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);
    const layout_json = args.layout orelse
        return try server.errorResponse(c_alloc, "--layout is required for +rearrange", .{});

    const layout = std.json.parseFromSliceLeaky(std.json.Value, arena, layout_json, .{}) catch
        return try server.errorResponse(c_alloc, "invalid layout JSON", .{});

    var names: std.ArrayList([]const u8) = .empty;
    if (try verb_args.validateLayout(arena, layout, &names)) |msg|
        return try server.errorResponse(c_alloc, "{s}", .{msg});
    if (names.items.len == 0)
        return try server.errorResponse(c_alloc, "layout must contain at least one pane", .{});
    if (verb_args.firstDuplicate(names.items)) |dupe|
        return try server.errorResponse(c_alloc, "duplicate pane name in layout: '{s}'", .{dupe});

    const window: *Window = if (args.target) |target| window: {
        const resolved = try resolve(arena, app, target);
        break :window switch (resolved) {
            .found => |e| e.window_(),
            else => return try missingResponse(arena, resolved, target, "target window '{s}' not found", .{target}),
        };
    } else if (callerAnchor(app, args)) |caller|
        // T1079: "rearrange this window" is the caller's window, not the one
        // the user clicked into since - the layout names ITS panes.
        caller.window
    else
        frontWindow(app) orelse
            return try server.errorResponse(c_alloc, "no focused window found", .{});

    const tab = window.getSelectedTab() orelse
        return try server.errorResponse(c_alloc, "no focused window found", .{});
    const split_tree = tab.getSplitTree();
    const tree = split_tree.getTree() orelse
        return try server.errorResponse(c_alloc, "no focused window found", .{});

    // Every leaf, resolved inside THIS tab. A pane name belongs to its window
    // (T2250), so a name is looked up in the target window rather than from
    // the caller's; a pane id names one pane wherever it is.
    var surfaces: std.StringHashMapUnmanaged(*Surface) = .empty;
    for (names.items) |name| {
        const surface = layoutPane(app, window, name) orelse
            return try server.errorResponse(c_alloc, "pane '{s}' not found in registry", .{name});
        if (!treeHas(tree, surface))
            return try server.errorResponse(c_alloc, "pane '{s}' is not in the target window", .{name});
        try surfaces.put(arena, name, surface);
    }

    // The replacement tree borrows the kept surfaces in a scratch arena;
    // `rearrange` clones it, taking the tree's own references (the boxed
    // copy clones with this arena's child allocator, so it is the app's -
    // the one every other tree in the widget is built with).
    var nodes: std.ArrayList(Surface.Tree.Node) = .empty;
    _ = try buildLayoutNode(arena, &nodes, layout, &surfaces);
    const borrowed: Surface.Tree = .{
        .arena = std.heap.ArenaAllocator.init(app.allocator()),
        .nodes = nodes.items,
        .zoomed = null,
    };
    CloseUndo.rearrange(split_tree, &borrowed);

    log.info("IPC +rearrange: window={s} panes={d}", .{ window.ipcName() orelse "-", names.items.len });
    return try c_alloc.dupe(u8, "{\"success\":true}");
}

/// The pane a `+rearrange` leaf names: a pane id anywhere, else a pane of
/// that name in `window`, else the same name in another window (which the
/// caller then refuses as "not in the target window").
fn layoutPane(app: Context, window: *Window, name: []const u8) ?*Surface {
    var it = paneIterator(app);
    while (it.next()) |p| {
        if (std.mem.eql(u8, p.surface.paneId(), name)) return p.surface;
    }
    if (namedPaneIn(window, app, name)) |p| return p.surface;
    it = paneIterator(app);
    while (it.next()) |p| {
        const n = p.surface.ipcName() orelse continue;
        if (std.mem.eql(u8, n, name)) return p.surface;
    }
    return null;
}

fn treeHas(tree: *const Surface.Tree, surface: *Surface) bool {
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (entry.view == surface) return true;
    }
    return false;
}

/// Append the nodes for `node` (already passed `validateLayout`) preorder,
/// so the root lands at index 0; win32's `buildLayoutNode`. Returns its
/// handle.
fn buildLayoutNode(
    arena: Allocator,
    nodes: *std.ArrayList(Surface.Tree.Node),
    node: std.json.Value,
    surfaces: *const std.StringHashMapUnmanaged(*Surface),
) Allocator.Error!Surface.Tree.Node.Handle {
    const handle: Surface.Tree.Node.Handle = @enumFromInt(nodes.items.len);
    try nodes.append(arena, undefined);
    const obj = node.object;

    if (obj.get("pane")) |pane| {
        nodes.items[handle.idx()] = .{ .leaf = surfaces.get(pane.string).? };
        return handle;
    }

    // The ratio arrives as a percent (default 50), clamped like the Mac.
    const ratio_percent: f64 = switch (obj.get("ratio") orelse std.json.Value{ .float = 50 }) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => 50,
    };
    const ratio: f16 = @floatCast(@min(0.9, @max(0.1, ratio_percent / 100.0)));
    const split_layout: Surface.Tree.Split.Layout = if (std.ascii.eqlIgnoreCase(
        obj.get("direction").?.string,
        "horizontal",
    )) .horizontal else .vertical;

    const left = try buildLayoutNode(arena, nodes, obj.get("left").?, surfaces);
    const right = try buildLayoutNode(arena, nodes, obj.get("right").?, surfaces);
    nodes.items[handle.idx()] = .{ .split = .{
        .layout = split_layout,
        .ratio = ratio,
        .left = left,
        .right = right,
    } };
    return handle;
}

// ---------------------------------------------------------------------------
// +send-keys and +read: the shared bodies in apprt/ipc/verbs.zig (T3361),
// over the model below - the same argument handling, sentences and replies
// win32 answers with. A POSIX pty takes a bare LF as a line end, so nothing
// is rewritten on the way in; that mapping is a ConPTY necessity only win32
// has.

pub fn handleSendKeys(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.sendKeys(@This(), app, request);
}

pub fn handleRead(app: Context, request: Request) Allocator.Error!?[]u8 {
    return verbs.read(@This(), app, request);
}

pub const Terminal = apprt.ipc.CoreTerminal;
pub const input_line_ends: verbs.LineEnds = .pty;

pub fn replyAllocator(_: Context) Allocator {
    return c_alloc;
}

/// A pane id, a pane name or a window name (its active pane). A surface
/// whose core never came up is the "never finished starting up" state.
pub fn lookupTerminal(app: Context, name: []const u8) verbs.Lookup(Terminal) {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const resolved = resolve(arena_state.allocator(), app, name) catch return .not_found;
    const entry = switch (resolved) {
        .found => |e| e,
        else => return .not_found,
    };
    const surface = entry.surface() orelse return .gone;
    // A viewer pane has no pty to read or type into (T3411).
    if (surface.isViewer()) return .viewer;
    const core = surface.core() orelse return .not_started;
    return .{ .ready = .{ .core = core } };
}

/// A name nothing answers to may be one several windows hold (T2250).
pub fn notFoundResponse(app: Context, name: []const u8, fallback: []const u8) Allocator.Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return missingResponse(arena, try resolve(arena, app, name), name, "{s}", .{fallback});
}

// ---------------------------------------------------------------------------
// +version

/// The build's comptime identity, the same constants win32's provenance
/// reads (T3361).
const build_identity = @import("../ipc/build_identity.zig");

fn selfExe(buf: []u8) []const u8 {
    return std.fs.selfExePath(buf) catch "";
}

/// `handoff-quit` (win32's T1070, shared refusal in `os/ipc_handoff.zig`): a
/// launch of a DIFFERENT build asks this instance to quit so it can start in
/// its place. Not a CLI verb - only a launch carries the `handoff` identity -
/// and refused when the launch is this same build (quitting would close the
/// user's app for nothing). The quit itself is deferred until the reply is out.
pub fn handleHandoffQuit(app: Context, request: Request) Allocator.Error!?[]u8 {
    const own: ipc_handoff.Identity = .{
        .version = build_identity.version,
        .commit = build_identity.commit,
    };
    if (ipc_handoff.refuseHandoffQuit(request.handoff, own)) |why| {
        log.warn("handoff-quit refused: {s}", .{why});
        return try server.errorResponse(c_alloc, "{s}", .{why});
    }
    const launcher = request.handoff.?;
    log.warn("handoff-quit: quitting so the launch of {s} ({s}) can take over (persistence={})", .{
        launcher.version, launcher.exe, app.getConfig().get().@"session-persistence",
    });
    app.scheduleHandoffQuit();
    return try c_alloc.dupe(u8, "{\"success\":true}");
}

const ipc_handoff = @import("../../os/ipc_handoff.zig");

pub fn handleVersion(app: Context, _: Request) Allocator.Error!?[]u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = selfExe(&exe_buf);

    var out: std.Io.Writer.Allocating = .init(c_alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        jws.objectField("version") catch break :write;
        jws.write(build_identity.version) catch break :write;
        jws.objectField("commit") catch break :write;
        jws.write(build_identity.commit) catch break :write;
        jws.objectField("mode") catch break :write;
        jws.write(build_identity.mode) catch break :write;
        jws.objectField("runtime") catch break :write;
        jws.write(build_identity.runtime) catch break :write;
        jws.objectField("update_check") catch break :write;
        jws.write(false) catch break :write;
        jws.objectField("exe") catch break :write;
        jws.write(exe) catch break :write;
        jws.objectField("pid") catch break :write;
        jws.write(@as(i64, std.c.getpid())) catch break :write;
        // T3399a: what a launch of another build reads before it offers
        // "Switch" (win32's T1070 fields): this app serves `handoff-quit`,
        // and whether quitting keeps the terminals (agent-hosted) or ends them.
        jws.objectField("handoff_quit") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("session_persistence") catch break :write;
        jws.write(app.getConfig().get().@"session-persistence") catch break :write;
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// +list

pub fn handleList(app: Context, request: Request) Allocator.Error!?[]u8 {
    // `--pid` is the Windows spelling of "which pane is this process in";
    // Linux has real ttys and the CLI answers `--tty` from the tree below.
    if (request.arguments) |argv| for (argv) |a| {
        if (std.mem.startsWith(u8, a, "--pid")) return try server.errorResponse(
            c_alloc,
            "--pid is the Windows form; on Linux use --tty=$(tty), or $GHOZTTY_PANE_ID names the pane directly",
            .{},
        );
    };

    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var windows: std.ArrayList(List.Window) = .empty;
    var it = windowIterator(app);
    while (it.next()) |window| {
        try windows.append(arena, try buildWindow(arena, app, window));
    }

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const list: List = .{
        .windows = windows.items,
        .build = .{
            .version = build_identity.version,
            .commit = build_identity.commit,
            .mode = build_identity.mode,
            .runtime = build_identity.runtime,
            .exe = try arena.dupe(u8, selfExe(&exe_buf)),
            .exe_modified = "",
            .pid = std.c.getpid(),
        },
    };
    return try list.serializeResponse(c_alloc);
}

fn cstr(p: ?[*:0]const u8) []const u8 {
    return if (p) |s| std.mem.span(s) else "";
}

fn buildWindow(arena: Allocator, app: Context, window: *Window) Allocator.Error!List.Window {
    const tab_view = window.getTabView();
    const selected = tab_view.getSelectedPage();
    const n: usize = @intCast(@max(tab_view.getNPages(), 0));

    const tabs = try arena.alloc(List.Tab, n);
    for (tabs, 0..) |*t, i| {
        const page = tab_view.getNthPage(@intCast(i));
        const tab = gobject.ext.cast(Tab, page.getChild());
        const active: ?*Surface = if (tab) |tb| tb.getActiveSurface() else null;
        const splits: *const List.Node = if (tab) |tb| splits: {
            if (tb.getSplitTree().getTree()) |tree|
                break :splits try verbs.listSplitNode(Surface.Tree, arena, tree, .root, ListLeaves{ .active = active });
            break :splits try emptyNode(arena);
        } else try emptyNode(arena);
        t.* = .{
            .id = try std.fmt.allocPrint(arena, "{d}", .{i}),
            .title = try arena.dupe(u8, cstr(page.getTitle())),
            .index = @intCast(i),
            .selected = selected == page,
            .splits = splits,
        };
    }

    const name: ?[]const u8 = if (windowName(app, window)) |wn| try arena.dupe(u8, wn) else null;
    const remote = remoteLinkOf(window);
    return .{
        .id = try std.fmt.allocPrint(arena, "{d}", .{
            window.as(gtk.ApplicationWindow).getId(),
        }),
        .title = try arena.dupe(u8, cstr(window.currentTitle())),
        .target = name,
        .focused = window.as(gtk.Window).isActive() != 0,
        .tabs = tabs,
        // T3597: a cross-machine window names its machine (T1557) and its
        // link's state (T609); a local window has neither field.
        .machine = if (remote) |l| List.machineField(try arena.dupe(u8, l.machine.displayName())) else null,
        .connection = if (remote) |l| .{ .state = RemoteLink.listState(l.conn().state(), l.retired) } else null,
    };
}

fn emptyNode(arena: Allocator) Allocator.Error!*const List.Node {
    const node = try arena.create(List.Node);
    node.* = .{ .leaf = List.empty_terminal };
    return node;
}

/// The leaves of one tab's `+list` split tree, for the shared walk
/// (`verbs.listSplitNode`, T3375).
const ListLeaves = struct {
    active: ?*Surface,

    pub fn terminal(self: ListLeaves, arena: Allocator, surface: *Surface) Allocator.Error!List.Terminal {
        const id = try arena.dupe(u8, surface.paneId());
        const shell = surface.shellInfo();
        return .{
            .id = id,
            .title = try arena.dupe(u8, surface.getTitle() orelse ""),
            .working_directory = try arena.dupe(u8, surface.getPwd() orelse ""),
            .pid = shell.pid,
            .tty = try arena.dupe(u8, shell.tty),
            // An unnamed pane answers to its id, the Mac's fallback.
            .name = if (surface.ipcName()) |nm| try arena.dupe(u8, nm) else id,
            .focused = surface == self.active,
            // T3596: out of the layout, still in the tree (win32 T1827).
            .stashed = pane_stash.isStashed(surface),
            // T3567: minimized into a stacked row's strip (win32 T2103).
            .minimized = if (ext.getAncestor(SplitTree, surface.as(gtk.Widget))) |t| t.isMinimized(surface) else false,
            .exit_code = null,
            // T3411: a viewer leaf says so, with what it shows now (the Mac's
            // `type`/`url`; `+list` prints it as `view: <title>  <url>`).
            .pane_type = if (surface.isViewer()) "viewer" else "terminal",
            .url = if (surface.getViewer()) |v| try arena.dupe(u8, v.currentLocation()) else null,
            // T3339: the banner's source (absent with none) and the activity
            // state's token - for every terminal pane, never a viewer (Mac).
            .banner = if (surface.getPaneBanner()) |b| try arena.dupe(u8, b) else null,
            .state = if (surface.isViewer()) null else surface.getActivityState().token(),
            // T3382: the pane's tint, absent without one (additive, T67).
            .background_tint = if (surface.backgroundTint()) |tint| tint: {
                const buf = try arena.alloc(u8, 7);
                break :tint color_math.hexString(tint, buf[0..7]);
            } else null,
        };
    }
};

comptime {
    server.checkFrontend(@This());
}
