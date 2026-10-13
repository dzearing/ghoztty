//! Undo for closing a pane or a tab, on the desktop (T1825).
//!
//! Mac's close registers an undo for `undo-timeout` (default 5s); within it
//! Cmd+Z brings the pane back with its shell still running and its agent
//! session still bound, and only when the undo expires is the session ended.
//! This is the Windows half of that, built the same way: a close PARKS what it
//! closed instead of freeing it.
//!
//!   * A pane closed out of a split keeps one reference, its HWND is hidden,
//!     and `close_undo.Anchor` records where in the tree it sat.
//!   * A tab closed out of a window keeps its whole tree (and therefore every
//!     pane's reference), hidden, plus the tab's title, colour and identity.
//!
//! Nothing below the pane can tell it was closed: its shell keeps running, its
//! ConPTY or agent session stays attached, and the agent keeps reporting it
//! as attached - which is why the chooser's "held by this viewer" filter
//! (T1791) has something to hide. When the entry expires it is FINALIZED: the
//! pane is marked CLOSE-on-free and the parked reference dropped, which is
//! exactly the teardown an immediate close used to run. A window going away
//! (closed, or the app quitting) finalizes the entries it owns first, while
//! the HWNDs they hide under still exist.
//!
//! The pure parts - the expiring stack and the re-insertion anchor - live in
//! `close_undo.zig` and are tested in every lane; this file is the glue that
//! needs a Window.

const CloseUndo = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Window = @import("Window.zig");
const PaneView = @import("PaneView.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const close_undo = @import("close_undo.zig");
const msg_timer = @import("msg_timer.zig");
const pane_id = @import("pane_id.zig");
const tab_color = @import("tab_color.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.close_undo);

pub const TIMER_ID: usize = msg_timer.close_undo;

const Tree = SplitTree(PaneView);
const Anchor = close_undo.Anchor(PaneView);

/// A closed pane or tab, held for its undo.
pub const Parked = union(enum) {
    pane: ParkedPane,
    tab: ParkedTab,
};

const ParkedPane = struct {
    /// Holds ONE reference: the one the tree used to.
    pane: *PaneView,
    window: *Window,
    /// The tab it was closed out of, by identity: an index would name a
    /// different tab once any tab before it closed.
    tab_uuid: pane_id.Buf,
    anchor: Anchor,
    /// The IPC name it was registered under, if any, so `--target=<name>`
    /// works again after the undo. Owned.
    name: ?[]u8,
};

const ParkedTab = struct {
    /// Owns the tree, and with it a reference on every pane.
    tree: Tree,
    window: *Window,
    index: usize,
    active: *PaneView,
    uuid: pane_id.Buf,
    title: [256]u16,
    title_len: u16,
    title_pinned: bool,
    color: tab_color.TabColor,
};

/// What a redo closes again. By identity, never by pointer: the pane a redo
/// names may have been closed or moved since the undo brought it back.
pub const Reclose = union(enum) {
    pane: pane_id.Buf,
    tab: pane_id.Buf,
};

app: *App,
undo_stack: close_undo.Stack(Parked) = .{},
redo_stack: close_undo.Stack(Reclose) = .{},

/// Non-zero while one user action is closing several things (Close Other
/// Tabs), so the undo brings them all back together.
group: u64 = 0,
next_group: u64 = 1,

/// True while an undo or redo is itself closing or restoring: those must not
/// throw away the redo history the way a fresh close does.
replaying: bool = false,

/// True while the pane sidebar's trash mode is killing a pane (T1845): that
/// close is immediate by definition - no undo window, so nothing holds the
/// pane and its session ends now rather than when the window would expire.
bypass: bool = false,

pub fn init(app: *App) CloseUndo {
    return .{ .app = app };
}

/// App teardown: every window has already finalized its own entries on its
/// way out; anything left is ended here rather than leaked.
pub fn deinit(self: *CloseUndo) void {
    while (self.undo_stack.takeAny()) |item| self.finalize(item.payload);
    const alloc = self.app.core_app.alloc;
    self.undo_stack.deinit(alloc);
    self.redo_stack.deinit(alloc);
    self.* = undefined;
}

fn timeoutMs(self: *const CloseUndo) ?u64 {
    return close_undo.timeoutMs(self.app.config.@"undo-timeout".duration);
}

fn now() u64 {
    return w32.GetTickCount64();
}

fn owner(window: *const Window) usize {
    return @intFromPtr(window);
}

/// Start collecting the closes of ONE user action into one undo.
pub fn beginGroup(self: *CloseUndo) void {
    self.group = self.next_group;
    self.next_group +%= 1;
    if (self.next_group == 0) self.next_group = 1;
}

pub fn endGroup(self: *CloseUndo) void {
    self.group = 0;
}

/// Whether a close of `pane` should be parked at all. A pane whose shell has
/// already exited has nothing to bring back, and a window that is itself
/// going away cannot hold anything.
fn parkable(self: *const CloseUndo, window: *const Window) bool {
    if (self.timeoutMs() == null) return false;
    if (self.bypass) return false;
    if (window.closing) return false;
    return true;
}

fn exited(pane: *const PaneView) bool {
    const s = pane.surface() orelse return false;
    return s.core_surface_ready and s.core_surface.child_exited;
}

/// Park `pane`, about to be removed from tab `tab` at `handle`. Called BEFORE
/// the removal (the anchor is read from the tree it is still in). True means
/// the entry took a reference and the caller must NOT mark the pane's session
/// for CLOSE; false means undo does not apply and the close is the immediate
/// one it always was.
pub fn parkPane(
    self: *CloseUndo,
    window: *Window,
    tab: usize,
    handle: Tree.Node.Handle,
    pane: *PaneView,
) bool {
    if (!self.parkable(window) or exited(pane)) return false;
    const alloc = self.app.core_app.alloc;
    var anchor = (Anchor.capture(alloc, &window.tab_trees[tab], handle) catch return false) orelse return false;

    const name: ?[]u8 = if (self.app.ipcNameOf(.{ .pane = pane })) |n|
        alloc.dupe(u8, n) catch null
    else
        null;

    var uuid: pane_id.Buf = undefined;
    @memcpy(&uuid, window.tabUuid(tab)[0..pane_id.len]);
    _ = pane.ref(alloc) catch unreachable; // PaneView.ref cannot fail
    self.push(window, .{ .pane = .{
        .pane = pane,
        .window = window,
        .tab_uuid = uuid,
        .anchor = anchor,
        .name = name,
    } }) catch {
        anchor.deinit(alloc);
        if (name) |n| alloc.free(n);
        // Undo the extra reference without tearing anything down: the tree
        // still holds the pane at this point.
        pane.unref(alloc);
        return false;
    };
    log.info("parked closed pane for undo", .{});
    return true;
}

/// Park tab `idx` of `window`, whose slot the caller removes next. True means
/// the tree now belongs to the entry (the caller must not deinit it or mark
/// its sessions); false means close it as before. The last tab is never
/// parked: its window closes with it, and a window close finalizes.
pub fn parkTab(self: *CloseUndo, window: *Window, idx: usize) bool {
    if (!self.parkable(window) or window.tab_count <= 1) return false;
    const tree = window.tab_trees[idx];
    var any_live = false;
    {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (!exited(entry.view)) any_live = true;
        }
    }
    if (!any_live) return false;

    var parked: ParkedTab = .{
        .tree = tree,
        .window = window,
        .index = idx,
        .active = window.tab_active_pane[idx],
        .uuid = undefined,
        .title = window.tab_titles[idx],
        .title_len = window.tab_title_lens[idx],
        .title_pinned = window.tab_title_pinned[idx],
        .color = window.tab_colors[idx],
    };
    @memcpy(&parked.uuid, window.tabUuid(idx)[0..pane_id.len]);
    self.push(window, .{ .tab = parked }) catch return false;
    hideTree(&parked.tree);
    log.info("parked closed tab for undo", .{});
    return true;
}

fn push(self: *CloseUndo, window: *Window, payload: Parked) Allocator.Error!void {
    const ms = self.timeoutMs() orelse unreachable; // parkable() checked
    try self.undo_stack.push(self.app.core_app.alloc, .{
        .payload = payload,
        .owner = owner(window),
        .deadline = now() +| ms,
        .group = self.group,
    });
    // A fresh close is a new branch of history: what was undone before it can
    // no longer be redone (every undo manager, Mac's included).
    if (!self.replaying) self.redo_stack.items.clearRetainingCapacity();
    self.arm();
}

/// Hide a parked pane. Its renderer parks, its HWND leaves the screen, and
/// nothing else about it changes.
pub fn hidePane(pane: *PaneView) void {
    pane.setVisible(false);
    if (pane.hwnd()) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
}

fn hideTree(tree: *const Tree) void {
    var it = tree.iterator();
    while (it.next()) |entry| hidePane(entry.view);
}

/// Bring back the most recent close in `window` (or, with no window, the most
/// recent close anywhere). False when there is nothing to undo.
pub fn undo(self: *CloseUndo, window: ?*Window) bool {
    const key = if (window) |w| owner(w) else self.undo_stack.topOwner() orelse return false;
    const first = self.undo_stack.popFor(key) orelse return false;
    self.replaying = true;
    defer self.replaying = false;

    const redo_group: u64 = if (first.group != 0) self.takeGroupId() else 0;
    var item = first;
    while (true) {
        if (self.restore(item.payload)) |again| {
            self.redo_stack.push(self.app.core_app.alloc, .{
                .payload = again,
                .owner = key,
                .deadline = now() +| (self.timeoutMs() orelse 0),
                .group = redo_group,
            }) catch {};
        }
        item = self.undo_stack.popGroupFor(key, first.group) orelse break;
    }
    self.arm();
    return true;
}

/// Close again what the last undo in `window` brought back.
pub fn redo(self: *CloseUndo, window: ?*Window) bool {
    const key = if (window) |w| owner(w) else self.redo_stack.topOwner() orelse return false;
    const first = self.redo_stack.popFor(key) orelse return false;
    self.replaying = true;
    defer self.replaying = false;

    if (first.group != 0) self.beginGroup();
    defer if (first.group != 0) self.endGroup();
    var item = first;
    while (true) {
        self.closeAgain(key, item.payload);
        item = self.redo_stack.popGroupFor(key, first.group) orelse break;
    }
    self.arm();
    return true;
}

fn takeGroupId(self: *CloseUndo) u64 {
    const g = self.next_group;
    self.next_group +%= 1;
    if (self.next_group == 0) self.next_group = 1;
    return g;
}

pub fn canUndo(self: *const CloseUndo, window: *const Window) bool {
    return self.undo_stack.hasFor(owner(window));
}

pub fn canRedo(self: *const CloseUndo, window: *const Window) bool {
    return self.redo_stack.hasFor(owner(window));
}

fn findWindow(self: *CloseUndo, key: usize) ?*Window {
    for (self.app.windows.items) |w| if (owner(w) == key) return w;
    return null;
}

fn closeAgain(self: *CloseUndo, key: usize, what: Reclose) void {
    const window = self.findWindow(key) orelse return;
    switch (what) {
        .pane => |id| {
            for (0..window.tab_count) |t| {
                var it = window.tab_trees[t].iterator();
                while (it.next()) |entry| {
                    if (pane_id.eql(entry.view.paneId(), &id)) {
                        window.closeSplitPane(entry.view);
                        return;
                    }
                }
            }
        },
        .tab => |uuid| {
            for (0..window.tab_count) |t| {
                if (pane_id.eql(window.tabUuid(t), &uuid)) {
                    window.closeTab(window.tab_active_pane[t]);
                    return;
                }
            }
        },
    }
}

/// Put a parked close back. Returns what a redo would close again, or null
/// when it could not be restored - in which case it has been finalized
/// instead, so a failed undo never strands a hidden live pane.
fn restore(self: *CloseUndo, parked: Parked) ?Reclose {
    switch (parked) {
        .pane => |p| return self.restorePane(p),
        .tab => |t| return self.restoreTab(t),
    }
}

fn restorePane(self: *CloseUndo, parked: ParkedPane) ?Reclose {
    var p = parked;
    const alloc = self.app.core_app.alloc;
    const window = p.window;
    const pane = p.pane;
    defer {
        p.anchor.deinit(alloc);
        if (p.name) |n| alloc.free(n);
    }

    var again: Reclose = .{ .pane = undefined };
    @memcpy(&again.pane, pane.paneId()[0..pane_id.len]);

    const tab: ?usize = for (0..window.tab_count) |t| {
        if (pane_id.eql(window.tabUuid(t), &p.tab_uuid)) break t;
    } else null;

    if (tab) |t| {
        const tree = &window.tab_trees[t];
        const place = (p.anchor.locate(alloc, tree) catch null) orelse placement: {
            // Every neighbour it had is gone; it goes back beside whatever is
            // focused in that tab, on the side it was closed from.
            const h = window.findHandle(t, window.tab_active_pane[t]) orelse break :placement null;
            break :placement Anchor.Placement{ .at = h, .exact = false };
        };
        if (place) |pl| {
            if (p.anchor.restore(alloc, tree, pl.at, pane)) |new_tree| {
                var old = window.tab_trees[t];
                window.tab_trees[t] = new_tree;
                old.deinit();
                pane.unref(alloc); // the tree holds it now
                window.tab_active_pane[t] = pane;
                if (t != window.active_tab) {
                    window.selectTabIndex(t);
                } else {
                    window.heroOnTreeChanged(t);
                    window.layoutSplits();
                    if (pane.hwnd()) |h| App.deferSetFocus(h);
                }
                self.app.markLayoutDirty();
                self.reregister(pane, p.name);
                log.info("undo: pane restored (exact={})", .{pl.exact});
                return again;
            } else |err| log.warn("undo: pane restore failed: {}", .{err});
        }
    } else {
        // The tab it came from has closed since: it comes back as a tab.
        if (Tree.init(alloc, pane)) |tree| {
            window.insertPaneAsTab(pane, tree);
            pane.unref(alloc);
            self.reregister(pane, p.name);
            log.info("undo: pane restored as a new tab", .{});
            return again;
        } else |err| log.warn("undo: pane restore failed: {}", .{err});
    }

    pane.setSessionCloseIntent(true);
    pane.unref(alloc);
    return null;
}

fn restoreTab(self: *CloseUndo, parked: ParkedTab) ?Reclose {
    _ = self;
    const window = parked.window;
    const pos = @min(parked.index, window.tab_count);
    window.insertPaneAsTabAt(parked.active, parked.tree, pos);
    window.adoptTabUuid(pos, &parked.uuid);
    window.tab_colors[pos] = parked.color;
    if (parked.title_pinned) {
        window.tab_titles[pos] = parked.title;
        window.tab_title_lens[pos] = parked.title_len;
        window.tab_title_pinned[pos] = true;
    }
    window.refreshTabTitle(pos);
    window.invalidateTabBar();
    log.info("undo: tab restored at index {}", .{pos});
    return .{ .tab = parked.uuid };
}

fn reregister(self: *CloseUndo, pane: *PaneView, name: ?[]u8) void {
    const n = name orelse return;
    self.app.ipcRegister(n, .{ .pane = pane }) catch {};
}

/// End a parked close for good: the teardown an immediate close would have
/// run, CLOSE intent and all.
fn finalize(self: *CloseUndo, parked: Parked) void {
    const alloc = self.app.core_app.alloc;
    switch (parked) {
        .pane => |p| {
            var pp = p;
            pp.anchor.deinit(alloc);
            if (pp.name) |n| alloc.free(n);
            pp.pane.setSessionCloseIntent(true);
            pp.pane.unref(alloc);
        },
        .tab => |t| {
            var tree = t.tree;
            var it = tree.iterator();
            while (it.next()) |entry| entry.view.setSessionCloseIntent(true);
            tree.deinit();
        },
    }
}

/// The expiry timer fired: finalize everything whose undo ran out.
pub fn onTimer(self: *CloseUndo) void {
    const t = now();
    var ended: usize = 0;
    while (self.undo_stack.takeExpired(t)) |item| {
        self.finalize(item.payload);
        ended += 1;
    }
    while (self.redo_stack.takeExpired(t)) |_| {}
    if (ended > 0) log.info("undo expired: {} close(s) finalized", .{ended});
    self.arm();
}

/// `window` is going away (closed, or the app is quitting). Its parked panes
/// are children of its HWND, so they are finalized now, before that HWND and
/// the GL contexts under it are destroyed.
pub fn finalizeWindow(self: *CloseUndo, window: *Window) void {
    const key = owner(window);
    while (self.undo_stack.takeOwnedBy(key)) |item| self.finalize(item.payload);
    while (self.redo_stack.takeOwnedBy(key)) |_| {}
    self.arm();
}

/// Take back a `parkPane` whose close then failed: the pane never left its
/// tree, so the entry lets go of its reference WITHOUT marking the session.
pub fn cancelPark(self: *CloseUndo, pane: *PaneView) void {
    const pred = struct {
        fn f(target: *PaneView, p: *const Parked) bool {
            return switch (p.*) {
                .pane => |pp| pp.pane == target,
                .tab => false,
            };
        }
    }.f;
    const item = self.undo_stack.takeMatching(pane, pred) orelse return;
    const alloc = self.app.core_app.alloc;
    var pp = item.payload.pane;
    pp.anchor.deinit(alloc);
    if (pp.name) |n| alloc.free(n);
    pp.pane.unref(alloc);
    self.arm();
}

/// A parked pane's shell exited while it waited for its undo (its surface
/// asked to close, and found no tree to close out of). The entry holding it
/// lets go now: nothing is left to bring back. True when one did.
pub fn paneGone(self: *CloseUndo, pane: *PaneView) bool {
    const pred = struct {
        fn f(target: *PaneView, p: *const Parked) bool {
            return switch (p.*) {
                .pane => |pp| pp.pane == target,
                .tab => false,
            };
        }
    }.f;
    if (self.undo_stack.takeMatching(pane, pred)) |item| {
        self.finalize(item.payload);
        self.arm();
        return true;
    }

    // In a parked tab: take it out of that tab's tree; an emptied tab goes.
    const alloc = self.app.core_app.alloc;
    for (self.undo_stack.items.items, 0..) |*item, i| {
        switch (item.payload) {
            .pane => {},
            .tab => |*t| {
                var it = t.tree.iterator();
                const handle = while (it.next()) |entry| {
                    if (entry.view == pane) break entry.handle;
                } else continue;
                pane.setSessionCloseIntent(true);
                if (handle == .root) {
                    const gone = self.undo_stack.items.orderedRemove(i);
                    self.finalize(gone.payload);
                } else if (t.tree.remove(alloc, handle)) |smaller| {
                    var old = t.tree;
                    t.tree = smaller;
                    if (t.active == pane) {
                        var first = t.tree.iterator();
                        if (first.next()) |entry| t.active = entry.view;
                    }
                    old.deinit();
                } else |_| {
                    const gone = self.undo_stack.items.orderedRemove(i);
                    self.finalize(gone.payload);
                }
                self.arm();
                return true;
            },
        }
    }
    return false;
}

/// (Re-)arm the expiry timer for the soonest deadline on either stack, or
/// stop it when both are empty.
fn arm(self: *CloseUndo) void {
    const hwnd = self.app.msg_hwnd orelse return;
    const a = self.undo_stack.nextDeadline();
    const b = self.redo_stack.nextDeadline();
    const next: ?u64 = if (a) |x| (if (b) |y| @min(x, y) else x) else b;
    if (next) |d| {
        _ = w32.SetTimer(hwnd, TIMER_ID, close_undo.timerDelay(d, now()), null);
    } else {
        _ = w32.KillTimer(hwnd, TIMER_ID);
    }
}
