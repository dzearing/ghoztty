//! The Linux session-layout manifest (T3397, Linux L8b): what the GTK app
//! writes so that the next launch can rebuild its windows, tabs and splits
//! and re-ATTACH every pane to the session the local `ghoztty-agent` kept
//! alive through the quit, crash or kill. The Mac's `SessionLayoutManifest`
//! and win32's `App.syncSessionLayout` / `restoreSessionLayout` are the
//! models; the on-disk schema is win32's (`apprt/win32/session_layout.zig`,
//! std-only, so it serves every platform).
//!
//! What it records, per window: its target name, pinned title, size (T3549;
//! Wayland gives no position), maximized state and selected tab; per tab its
//! pinned title (T3549) and its split tree with exact directions and
//! ratios; per terminal pane its agent session id, pane id, target name,
//! pinned title and the directory its shell is in; per viewer pane its pane
//! id and name, where it is, where it was opened (Home) and the directory it
//! was opened from (T3420) - re-opening there IS a viewer's restore, so an
//! image comes back at best fit, a diff re-runs in that directory and a file
//! deleted meanwhile shows the viewer's own error card. At quit each pane's screen is
//! snapshotted too, so a re-attached pane paints its last frame at once while
//! the agent gap-fills from the snapshot's offset.
//!
//! When it writes: a change-checked capture every `sync_interval_ms` (the Mac
//! debounces each change by 250 ms; GTK has no single change hook across tree,
//! title, name and directory changes, and a once-a-second capture of a few
//! panes is cheap and only writes when the bytes changed), and a final one
//! with snapshots when a quit begins, before any window is torn down. Once the
//! quit's write is done nothing writes again, so the teardown can never
//! record an empty app. A window the user closed is gone from the next
//! capture, so its panes - whose sessions that close ended - never come back.
//!
//! Who: only the instance that serves this user's IPC socket owns the file. A
//! second instance (`--gtk-single-instance=false`) neither restores nor
//! writes, so it can never take the first one's panes or overwrite its
//! layout. `session-persistence = false` turns both off.
//!
//! Where: `<config root>/ghoztty/session-layout[-debug][-<lineage>].json`,
//! beside the local agent's state dir and under the same root
//! (`$XDG_CONFIG_HOME`, else `~/.config`), so a test harness that gives the
//! agent a private config dir gives the manifest one too.
//!
//! GTK main thread only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../build_config.zig");
const schema = @import("../win32/session_layout.zig");
const agent_lineage = @import("../../remote/agent_lineage.zig");
const connection = @import("../../remote/connection.zig");

const Application = @import("class/application.zig").Application;
const WindowSize = @import("class/application.zig").WindowSize;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;

/// The pure half - the path, the first leaf, the size rules, a viewer's
/// restore - std-only so every test lane runs its tests (T3551).
const rules = @import("session_layout_rules.zig");
const firstLeaf = rules.firstLeaf;
const frameFromSize = rules.frameFromSize;
pub const layoutPathFrom = rules.layoutPathFrom;

const log = std.log.scoped(.gtk_session_layout);

/// How often the running app re-captures its layout.
const sync_interval_ms: c_uint = 1000;

/// How long a restore waits for the agent's session roster before it tries
/// every recorded session anyway (a probe that never lands is not "gone").
const roster_timeout_ns: u64 = 2 * std.time.ns_per_s;

/// How long one pane's quit-time snapshot may wait on its renderer lock.
const snapshot_lock_ns: u64 = 50 * std.time.ns_per_ms;

var timer: ?c_uint = null;
/// Set when the quit's final write is done: nothing writes after it.
var finished = false;
/// Hash of the body last written, or of "" after a delete; null before any.
var last_body: ?u64 = null;

// ---------------------------------------------------------------------------
// Where the file lives (`rules.layoutPathFrom`).

fn layoutPath(alloc: Allocator) ?[]u8 {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (@import("../../os/homedir.zig").home(&home_buf) catch null) orelse return null;
    var sfx_buf: [agent_lineage.max_len]u8 = undefined;
    const instance = agent_lineage.fromEnv(&sfx_buf);
    return layoutPathFrom(alloc, build_config.is_debug, instance, std.posix.getenv("XDG_CONFIG_HOME"), home) catch null;
}

/// Whether this app owns the manifest: persistence on, and it is the
/// instance serving the IPC socket.
fn owns(app: *Application) bool {
    if (!app.getConfig().get().@"session-persistence") return false;
    return app.rt().ipc_server != null;
}

// ---------------------------------------------------------------------------
// Capture.

/// The app's layout now, allocated in `arena`. `snapshots` adds each
/// agent-backed pane's screen (the quit-time capture).
pub fn capture(arena: Allocator, app: *Application, snapshots: bool) Allocator.Error!schema.File {
    var windows: std.ArrayList(schema.Window) = .empty;
    var budget: schema.SnapshotBudget = .{};
    // Most recently focused first (gtk_application_get_windows).
    var node: ?*glib.List = app.as(gtk.Application).getWindows();
    while (node) |n| : (node = n.f_next) {
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const window = gobject.ext.cast(Window, obj) orelse continue;
        if (window.isQuickTerminal()) continue;
        const w = try captureWindow(arena, window, windows.items.len, snapshots, &budget) orelse continue;
        try windows.append(arena, w);
    }
    if (windows.items.len > 0) windows.items[0].frontmost = true;
    return .{ .windows = windows.items };
}

fn captureWindow(
    arena: Allocator,
    window: *Window,
    index: usize,
    snapshots: bool,
    budget: *schema.SnapshotBudget,
) Allocator.Error!?schema.Window {
    const tab_view = window.getTabView();
    const pages: usize = @intCast(@max(tab_view.getNPages(), 0));
    const selected = tab_view.getSelectedPage();
    var tabs: std.ArrayList(schema.Tab) = .empty;
    var active_tab: u32 = 0;
    for (0..pages) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
        const tree = tab.getSplitTree().getTree() orelse continue;
        const nodes = try arena.alloc(schema.Node, tree.nodes.len);
        for (tree.nodes, nodes) |src, *dst| dst.* = switch (src) {
            .leaf => |s| .{ .leaf = try captureLeaf(arena, s, snapshots, budget) },
            .split => |sp| .{ .split = .{
                .layout = @tagName(sp.layout),
                .ratio = @floatCast(sp.ratio),
                .left = @intFromEnum(sp.left),
                .right = @intFromEnum(sp.right),
            } },
        };
        const is_active = selected != null and selected.? == page;
        if (is_active) active_tab = @intCast(tabs.items.len);
        try tabs.append(arena, .{
            .nodes = nodes,
            .active = is_active,
            // The tab's pinned title (T3549); a shell's own title is not.
            .title = if (tab.titleOverride()) |t| try arena.dupe(u8, t) else null,
        });
    }
    if (tabs.items.len == 0) return null;

    // The window's size (T3549). GTK4 keeps a window's default size in step
    // with the user's resizes and leaves it at the normal size while the
    // window is maximized, so it is exactly the schema's "restored rect" for
    // a maximized window. A window nobody sized yet reports 0: take what it
    // is showing at. Wayland gives a client no position, so x/y record 0.
    const gw = window.as(gtk.Window);
    const maximized = gw.isMaximized() != 0;
    var dw: c_int = 0;
    var dh: c_int = 0;
    gw.getDefaultSize(&dw, &dh);
    if ((dw <= 0 or dh <= 0) and !maximized) {
        dw = window.as(gtk.Widget).getWidth();
        dh = window.as(gtk.Widget).getHeight();
    }

    const name = window.ipcName();
    return .{
        .id = if (name) |n| try arena.dupe(u8, n) else try std.fmt.allocPrint(arena, "win-{d}", .{index}),
        .ipc_name = if (name) |n| try arena.dupe(u8, n) else null,
        .title_override = if (window.titleOverride()) |t| try arena.dupe(u8, t) else null,
        .frame = frameFromSize(dw, dh),
        .maximized = maximized,
        .active_tab = active_tab,
        .tabs = tabs.items,
    };
}

fn captureLeaf(
    arena: Allocator,
    surface: *Surface,
    snapshots: bool,
    budget: *schema.SnapshotBudget,
) Allocator.Error!schema.Leaf {
    const name: ?[]const u8 = if (surface.ipcName()) |n| try arena.dupe(u8, n) else null;
    if (surface.getViewer()) |viewer| return .{
        .kind = schema.kind_viewer,
        .viewer_location = try arena.dupe(u8, viewer.currentLocation()),
        .viewer_home_location = try arena.dupe(u8, viewer.homeLocation()),
        .viewer_origin_directory = if (viewer.originDirectory()) |d| try arena.dupe(u8, d) else null,
        .ipc_name = name,
        .pane_id = try arena.dupe(u8, surface.paneId()),
    };

    var leaf: schema.Leaf = .{
        .session_id = if (surface.agentSessionId()) |id| try arena.dupe(u8, id) else null,
        .pane_id = try arena.dupe(u8, surface.paneId()),
        .ipc_name = name,
        .working_directory = if (surface.getPwd()) |p| try arena.dupe(u8, p) else null,
    };
    if (surface.titleOverride()) |t| {
        leaf.title = try arena.dupe(u8, t);
        leaf.title_set_by_user = true;
    }
    // The pane's banner, as its markdown source (T3560).
    if (rules.bannerToRecord(surface.getPaneBanner())) |b| leaf.banner = try arena.dupe(u8, b);
    if (snapshots and leaf.session_id != null) captureSnapshot(arena, surface, &leaf, budget);
    return leaf;
}

/// Base64 the pane's screen and offset into `leaf`, within the file budget.
/// A pane with nothing to snapshot, or over budget, records none: it
/// restores from the agent's full replay, as before snapshots existed.
fn captureSnapshot(arena: Allocator, surface: *Surface, leaf: *schema.Leaf, budget: *schema.SnapshotBudget) void {
    var data: []const u8 = undefined;
    var offset: u64 = 0;
    if (surface.pendingRestoreSnapshot()) |pending| {
        data = pending.data;
        offset = pending.offset;
    } else {
        const core = surface.core() orelse return;
        const snap = (core.sessionSnapshotTimeout(arena, snapshot_lock_ns) catch return) orelse return;
        data = snap.data;
        offset = snap.byte_offset;
    }
    if (data.len == 0 or offset == 0) return;
    const enc = std.base64.standard.Encoder;
    const len = enc.calcSize(data.len);
    if (!budget.take(len)) return;
    const out = arena.alloc(u8, len) catch return;
    leaf.screen_snapshot = enc.encode(out, data);
    leaf.screen_snapshot_offset = offset;
}

// ---------------------------------------------------------------------------
// Writing.

/// Capture and write the manifest if it changed; with no windows, remove
/// it. `snapshots` is the quit-time capture, which always writes.
pub fn syncNow(app: *Application, snapshots: bool) void {
    if (finished or !owns(app)) return;
    const gpa = std.heap.c_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = layoutPath(arena) orelse return;
    const file = capture(arena, app, snapshots) catch |err| {
        log.warn("session layout: capture failed err={}", .{err});
        return;
    };
    if (file.windows.len == 0) {
        const empty = std.hash.Wyhash.hash(0, "");
        if (last_body != null and last_body.? == empty) return;
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                log.warn("session layout: cannot remove {s} err={}", .{ path, err });
                return;
            },
        };
        last_body = empty;
        log.info("session layout: no windows; removed {s}", .{path});
        return;
    }
    const body = schema.serialize(arena, file) catch |err| {
        log.warn("session layout: encode failed err={}", .{err});
        return;
    };
    const h = std.hash.Wyhash.hash(0, body);
    if (!snapshots and last_body != null and last_body.? == h) return;
    schema.writeAtomic(arena, path, body) catch |err| {
        log.warn("session layout: write {s} failed err={}", .{ path, err });
        return;
    };
    last_body = h;
    log.debug("session layout: wrote {d} window(s), {d} pane(s) to {s}", .{ file.windows.len, file.paneCount(), path });
}

/// Start the periodic capture (after the launch's restore).
pub fn startSync(app: *Application) void {
    if (timer != null or !owns(app)) return;
    timer = glib.timeoutAdd(sync_interval_ms, tick, app);
}

fn tick(ud: ?*anyopaque) callconv(.c) c_int {
    const app: *Application = @ptrCast(@alignCast(ud orelse return 0));
    if (finished) {
        timer = null;
        return 0;
    }
    syncNow(app, false);
    return 1;
}

/// The quit's final write: snapshots included, before any window closes.
/// Nothing writes after it.
pub fn finishForQuit(app: *Application) void {
    if (finished) return;
    syncNow(app, true);
    finished = true;
    if (timer) |t| {
        _ = glib.Source.remove(t);
        timer = null;
    }
}

// ---------------------------------------------------------------------------
// Restore.

const AttachSet = struct {
    /// Null: the roster never landed, so every recorded session is tried.
    ids: ?std.StringHashMapUnmanaged(void) = null,

    /// Whether `id` may be attached, claiming it so no second pane takes it
    /// (one pane per session, T1684).
    fn claim(self: *AttachSet, id: []const u8, claimed: *std.StringHashMapUnmanaged(void), gpa: Allocator) bool {
        if (claimed.contains(id)) return false;
        if (self.ids) |m| if (!m.contains(id)) return false;
        claimed.put(gpa, id, {}) catch {};
        return true;
    }
};

/// Rebuild the windows the manifest records, re-attaching their sessions.
/// Returns how many windows it opened (0: nothing to restore).
pub fn restore(app: *Application) usize {
    if (!owns(app)) return 0;
    const gpa = std.heap.c_allocator;
    const path = layoutPath(gpa) orelse return 0;
    defer gpa.free(path);
    var parsed = (schema.load(gpa, path) catch |err| {
        log.warn("session layout: cannot read {s} err={}; starting fresh", .{ path, err });
        return 0;
    }) orelse return 0;
    defer parsed.deinit();
    const windows = parsed.value.windows;
    if (windows.len == 0) return 0;

    // Arena for the roster ids and the per-pane strings handed to new().
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var attach: AttachSet = .{};
    if (app.rt().local_agent.sharedConnection()) |conn| roster: {
        var roster = conn.requestSessions(roster_timeout_ns) catch |err| {
            log.warn("session layout: agent roster unavailable err={}; trying every recorded session", .{err});
            break :roster;
        };
        defer roster.deinit();
        var ids: std.StringHashMapUnmanaged(void) = .empty;
        for (roster.sessions) |s| {
            // Alive and nobody's, or a tombstone the agent can relaunch.
            const usable = (s.alive and !s.attached) or (!s.alive and s.relaunchable);
            if (!usable) continue;
            ids.put(arena, arena.dupe(u8, s.id) catch continue, {}) catch continue;
        }
        attach.ids = ids;
    } else {
        // No agent: nothing to attach to. Every pane opens fresh where it was.
        attach.ids = .empty;
    }

    var claimed: std.StringHashMapUnmanaged(void) = .empty;
    var ctx: Ctx = .{ .arena = arena, .attach = &attach, .claimed = &claimed };

    // The front window last, so it ends up in front.
    var opened: usize = 0;
    var i = windows.len;
    while (i > 0) {
        i -= 1;
        if (restoreWindow(app, &ctx, windows[i])) opened += 1;
    }
    log.info("session layout: restored {d} of {d} window(s), {d} pane(s) re-attached", .{ opened, windows.len, ctx.attached });
    return opened;
}

const Ctx = struct {
    arena: Allocator,
    attach: *AttachSet,
    claimed: *std.StringHashMapUnmanaged(void),
    attached: usize = 0,

    const viewLocation = ctxViewLocation;
    const setPending = ctxSetPending;
};

fn restoreWindow(app: *Application, ctx: *Ctx, win: schema.Window) bool {
    var window: ?*Window = null;
    var tabs_built: usize = 0;
    for (win.tabs) |tab| {
        if (tab.nodes.len == 0) continue;
        const first = firstLeaf(tab.nodes, 0, 0) orelse continue;
        const view = ctx.viewLocation(first);
        ctx.setPending(first);
        const t: *Tab = if (window) |w| (w.newTabForRestore(view) orelse continue) else t: {
            const w = app.newWindowForRestore(view, restoreSize(win.frame));
            window = w;
            break :t w.getSelectedTab() orelse continue;
        };
        Surface.pending_restore = null;
        // The tab's pinned title (T3549), before its panes add theirs.
        if (tab.title) |title| if (title.len > 0) {
            if (ctx.arena.dupeZ(u8, title)) |tz| t.setTitleOverride(tz) else |_| {}
        };
        const tree = t.getSplitTree();
        const anchor = tree.getActiveSurface() orelse continue;
        buildSubtree(ctx, tree, tab.nodes, 0, anchor, 0) catch |err|
            log.warn("session layout: a tab's split tree is corrupt err={}; kept what was built", .{err});
        tabs_built += 1;
    }
    const w = window orelse return false;
    if (win.ipc_name) |n| w.setIpcName(n);
    if (win.title_override) |title| w.setTitleOverride(title);
    if (win.maximized) w.as(gtk.Window).maximize();
    const tv = w.getTabView();
    const pages = tv.getNPages();
    if (pages > 0) {
        const want: c_int = @intCast(@min(schema.activeTabIndex(win), @as(usize, @intCast(pages - 1))));
        tv.setSelectedPage(tv.getNthPage(want));
    }
    return tabs_built > 0;
}

/// Reproduce `nodes[idx]`'s subtree in the region `anchor` occupies: a leaf
/// takes its name and title; a split creates the right child's first pane
/// beside `anchor` at the recorded ratio, then recurses into both children.
/// Bounded against a cyclic or out-of-range manifest.
fn buildSubtree(
    ctx: *Ctx,
    tree: anytype,
    nodes: []const schema.Node,
    idx: usize,
    anchor: *Surface,
    depth: usize,
) !void {
    if (depth > nodes.len or idx >= nodes.len) return error.CorruptLayout;
    const node = nodes[idx];
    if (node.leaf) |lf| {
        if (lf.ipc_name) |n| anchor.setIpcName(n);
        if (lf.title) |t| if (lf.title_set_by_user orelse false) {
            const tz = ctx.arena.dupeZ(u8, t) catch return;
            anchor.setTitleOverride(tz);
        };
        return;
    }
    const sp = node.split orelse return error.CorruptLayout;
    if (sp.left >= nodes.len or sp.right >= nodes.len) return error.CorruptLayout;
    const dir: Surface.Tree.Split.Direction = if (std.mem.eql(u8, sp.layout, "vertical")) .down else .right;
    const right = firstLeaf(nodes, sp.right, 0) orelse return error.CorruptLayout;
    const view = ctx.viewLocation(right);
    ctx.setPending(right);
    const new_pane = tree.newSplitAt(dir, null, .{
        .view = view,
        .at = anchor,
        .ratio = @floatCast(std.math.clamp(sp.ratio, 0.05, 0.95)),
        .focus = false,
    }) catch |err| {
        Surface.pending_restore = null;
        return err;
    };
    Surface.pending_restore = null;
    try buildSubtree(ctx, tree, nodes, sp.left, anchor, depth + 1);
    try buildSubtree(ctx, tree, nodes, sp.right, new_pane, depth + 1);
}

/// The size a restored window opens at (T3549; `rules.restoreSize`), as the
/// application's `WindowSize`.
fn restoreSize(frame: ?schema.Frame) ?WindowSize {
    const s = rules.restoreSize(frame) orelse return null;
    return .{ .w = s.w, .h = s.h };
}

fn ctxViewLocation(ctx: *Ctx, leaf: schema.Leaf) ?[:0]const u8 {
    if (!leaf.isViewer()) return null;
    const loc = leaf.viewer_location orelse "about:blank";
    return ctx.arena.dupeZ(u8, loc) catch null;
}

/// Hand the next `Surface.new` its recorded pane: ATTACH its session when
/// the agent still has it and no other pane took it, else a fresh shell in
/// its directory. Either way it keeps its pane id. A viewer (T3420) has no
/// session: it keeps its pane id, its Home and its origin directory.
fn ctxSetPending(ctx: *Ctx, leaf: schema.Leaf) void {
    if (leaf.isViewer()) {
        Surface.pending_restore = viewerRestore(leaf);
        return;
    }
    const sid: ?[]const u8 = if (leaf.session_id) |id|
        (if (ctx.attach.claim(id, ctx.claimed, ctx.arena)) id else null)
    else
        null;
    if (leaf.session_id != null and sid == null)
        log.info("session layout: session {s} is gone; its pane opens a fresh shell", .{leaf.session_id.?});
    if (sid != null) ctx.attached += 1;
    var snap: ?[]const u8 = null;
    var offset: u64 = 0;
    if (sid != null) if (leaf.screen_snapshot) |enc| if (leaf.screen_snapshot_offset) |off| decode: {
        const dec = std.base64.standard.Decoder;
        const len = dec.calcSizeForSlice(enc) catch break :decode;
        const buf = ctx.arena.alloc(u8, len) catch break :decode;
        dec.decode(buf, enc) catch break :decode;
        snap = buf;
        offset = off;
    };
    Surface.pending_restore = .{
        .session_id = sid,
        .pane_id = leaf.pane_id,
        .working_directory = leaf.working_directory,
        .snapshot = snap,
        .snapshot_offset = offset,
        // The pane's banner comes back whatever happened to its session
        // (T3560): it is the pane's own state, and a fresh shell keeps it.
        .banner = rules.bannerToRestore(leaf),
    };
}

/// A viewer leaf's restore (T3420; `rules.viewerRestore`) as the pane's
/// `Surface.Restore`: its id, Home and origin directory, never a session.
fn viewerRestore(leaf: schema.Leaf) Surface.Restore {
    const r = rules.viewerRestore(leaf);
    return .{
        .pane_id = r.pane_id,
        .working_directory = r.working_directory,
        .viewer_home = r.viewer_home,
    };
}
