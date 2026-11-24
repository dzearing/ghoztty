//! Undo for closing a pane and for `+rearrange`, on Linux (T3384).
//!
//! Mac registers both with the window's `ExpiringUndoManager`: for
//! `undo-timeout` (5 s by default) a closed pane, or a pane a rearranged
//! layout left out, stays alive - shell running, agent session bound - and
//! Cmd+Z puts it back where it was, by name; Cmd+Shift+Z does it again.
//! Windows does the same (T1825 `CloseUndo.zig`, T2234 `LayoutUndo.zig`), on
//! Ctrl+Shift+Z / Ctrl+Shift+Y, and so does this file, on the same keys.
//!
//! A closed pane is PARKED rather than freed: the split tree drops it, so it
//! leaves the widget hierarchy, `+list` and every name lookup at once (they
//! all walk the live trees), but one GObject reference held here keeps the
//! Surface - and with it the core surface and its pty - alive. When the undo
//! expires that reference goes, which is the moment the pane is torn down
//! exactly as an immediate close would have done it (its agent session is
//! ended, not detached, even when the expiry is a quit).
//!
//! Where a closed pane goes back is win32's pure `close_undo.Anchor` (the
//! sibling subtree that took its place); a rearranged layout is win32's pure
//! `layout_undo.Shape` (the tree by pane id, so the entry never keeps a pane
//! alive that the user closed since). One undo stack and one redo stack for
//! the app, each entry owned by its window, so an undo in one window never
//! resurrects a pane in another.
//!
//! A closed TAB is parked the same way (T3590, win32 T1825): its Tab widget
//! leaves the tab view - and with it every lookup - while one reference
//! held here keeps its split tree, and every pane and session in it, alive.
//! Undo puts it back at the position it had, selected. Closing a tab's only
//! pane is closing that tab, so it parks as a tab, whole. Close Other Tabs
//! and Close Tabs to the Right are ONE undo (a group). A window closing - or
//! its last tab, which closes it - is not undoable here yet (T3665).

const std = @import("std");
const Allocator = std.mem.Allocator;

const glib = @import("glib");
const gtk = @import("gtk");

const ext = @import("ext.zig");
const Application = @import("class/application.zig").Application;
const Surface = @import("class/surface.zig").Surface;
const SplitTree = @import("class/split_tree.zig").SplitTree;
const Tab = @import("class/tab.zig").Tab;
const Window = @import("class/window.zig").Window;
const WeakRef = @import("weak_ref.zig").WeakRef;
const close_undo = @import("../win32/close_undo.zig");
const layout_undo = @import("../win32/layout_undo.zig");
const pane_id = @import("../ipc/pane_id.zig");

const log = std.log.scoped(.gtk_close_undo);

const Tree = Surface.Tree;
const Anchor = close_undo.Anchor(Surface);
const Shape = layout_undo.Shape(Surface, pane_id.Buf);

/// The tab an entry belongs to, held weakly: a closed tab simply stops
/// answering. Boxed, because a GWeakRef must never move once set and the
/// stacks below reallocate.
const Home = WeakRef(SplitTree);

/// A tab a redo closes again, held weakly (boxed, as `Home`).
const TabRef = WeakRef(Tab);

const Entry = union(enum) {
    /// Undo: put a closed pane back.
    pane: struct {
        /// Holds ONE reference: the one the tree used to.
        surface: *Surface,
        anchor: Anchor,
        home: *Home,
    },
    /// Undo: put the layout before a `+rearrange` back.
    layout: struct {
        before: Shape,
        /// The pane that had focus before it.
        active: ?pane_id.Buf,
        /// The panes it left out, one reference each. Owned.
        left_out: []*Surface,
        home: *Home,
    },
    /// Undo: put a closed tab back (T3590).
    tab: struct {
        /// Holds ONE reference: the one the tab view used to.
        tab: *Tab,
        /// Where it was in its window's tab view.
        position: c_int,
    },
    /// Redo: close that pane again.
    pane_redo: struct { id: pane_id.Buf, home: *Home },
    /// Redo: close that tab again.
    tab_redo: struct { tab: *TabRef },
    /// Redo: put the rearranged layout back.
    layout_redo: struct { after: Shape, home: *Home },
};

const Stack = close_undo.Stack(Entry);

var undos: Stack = .{};
var redos: Stack = .{};
var timer: ?c_uint = null;
/// Set while a redo re-closes or re-rearranges, so the undo that action
/// registers does not wipe the rest of the redo stack (NSUndoManager keeps
/// it; only a NEW action clears it).
var in_redo: bool = false;
/// Set by `+close --force` (T2938, Mac `forceCloseSurface`): the close it
/// makes is not parked - no undo, the pane ends now.
pub var bypass: bool = false;
/// A tab whose close needs no confirmation: its only pane's close already
/// asked, or a redo is closing it (T3590). Set only around `closePage`.
pub var confirmed_tab: ?*Tab = null;
/// Non-zero while one user action closes several tabs (T3590): every entry
/// it registers carries it, and one undo brings them all back.
var group: u64 = 0;
var next_group: u64 = 1;

fn takeGroupId() u64 {
    const g = next_group;
    next_group +%= 1;
    if (next_group == 0) next_group = 1;
    return g;
}

pub fn beginGroup() void {
    group = takeGroupId();
}

pub fn endGroup() void {
    group = 0;
}

fn gpa() Allocator {
    return Application.default().allocator();
}

fn nowMs() u64 {
    return @intCast(@max(0, std.time.milliTimestamp()));
}

/// `undo-timeout` in ms, or null when undo is off (`undo-timeout = 0`, which
/// Mac documents as disabling it: a close is the immediate close it was) or
/// bypassed.
fn timeoutMs() ?u64 {
    if (bypass) return null;
    const config = Application.default().getConfig();
    return close_undo.timeoutMs(config.get().@"undo-timeout".duration);
}

fn ownerOf(split_tree: *SplitTree) ?usize {
    const window = ext.getAncestor(Window, split_tree.as(gtk.Widget)) orelse return null;
    return @intFromPtr(window);
}

fn idOf(v: *const Surface) pane_id.Buf {
    var buf: pane_id.Buf = undefined;
    @memcpy(&buf, @constCast(v).paneId()[0..pane_id.len]);
    return buf;
}

fn newHome(split_tree: *SplitTree) Allocator.Error!*Home {
    const home = try gpa().create(Home);
    home.* = .empty;
    home.set(split_tree);
    return home;
}

fn freeHome(home: *Home) void {
    home.set(null);
    gpa().destroy(home);
}

fn treeHas(tree: *const Tree, surface: *const Surface) bool {
    var it = tree.iterator();
    while (it.next()) |entry| if (entry.view == surface) return true;
    return false;
}

/// The teardown a close would have given the pane: a close, not a quit, so
/// an agent-backed pane ends its session even when the app is quitting.
fn endSurface(surface: *Surface) void {
    // T3563: unless the close was a Disconnect (its pin refuses this).
    surface.markSessionClose();
    surface.unref();
}

/// A parked tab's teardown: every pane in it ends as a close would end it,
/// then the tab goes with the last reference.
fn endTab(tab: *Tab) void {
    if (tab.getSurfaceTree()) |tree| {
        var it = tree.iterator();
        while (it.next()) |entry| entry.view.markSessionClose();
    }
    tab.unref();
}

fn newTabRef(tab: *Tab) Allocator.Error!*TabRef {
    const ref = try gpa().create(TabRef);
    ref.* = .empty;
    ref.set(tab);
    return ref;
}

fn freeTabRef(ref: *TabRef) void {
    ref.set(null);
    gpa().destroy(ref);
}

/// Free an entry for good, ending whatever it kept alive.
fn finalize(entry: *Entry) void {
    const alloc = gpa();
    switch (entry.*) {
        .pane => |*p| {
            endSurface(p.surface);
            p.anchor.deinit(alloc);
            freeHome(p.home);
        },
        .layout => |*l| {
            for (l.left_out) |s| endSurface(s);
            alloc.free(l.left_out);
            l.before.deinit(alloc);
            freeHome(l.home);
        },
        .tab => |*t| endTab(t.tab),
        .pane_redo => |*r| freeHome(r.home),
        .tab_redo => |*r| freeTabRef(r.tab),
        .layout_redo => |*r| {
            r.after.deinit(alloc);
            freeHome(r.home);
        },
    }
}

fn push(stack: *Stack, owner: usize, payload: Entry) bool {
    const ms = timeoutMs() orelse return false;
    stack.push(gpa(), .{
        .payload = payload,
        .owner = owner,
        .deadline = nowMs() + ms,
        .group = group,
    }) catch return false;
    arm();
    return true;
}

/// A new undoable action clears its window's redos, as NSUndoManager does.
fn clearRedos(owner: usize) void {
    if (in_redo) return;
    while (redos.takeOwnedBy(owner)) |item| {
        var it = item;
        finalize(&it.payload);
    }
}

// ---------------------------------------------------------------------------
// Expiry

fn arm() void {
    if (timer) |t| {
        _ = glib.Source.remove(t);
        timer = null;
    }
    const a = undos.nextDeadline();
    const b = redos.nextDeadline();
    const soonest = if (a != null and b != null) @min(a.?, b.?) else a orelse b orelse return;
    timer = glib.timeoutAdd(close_undo.timerDelay(soonest, nowMs()), onTimer, null);
}

fn onTimer(_: ?*anyopaque) callconv(.c) c_int {
    timer = null;
    const now = nowMs();
    var ended: usize = 0;
    while (undos.takeExpired(now)) |item| {
        var it = item;
        finalize(&it.payload);
        ended += 1;
    }
    while (redos.takeExpired(now)) |item| {
        var it = item;
        finalize(&it.payload);
    }
    if (ended > 0) log.info("undo expired: {d} entr{s} ended", .{ ended, if (ended == 1) "y" else "ies" });
    arm();
    return 0;
}

/// End every entry a window owns: it is going away, and nothing could put
/// its panes back.
pub fn dropWindow(window: *Window) void {
    const owner = @intFromPtr(window);
    var ended: usize = 0;
    while (undos.takeOwnedBy(owner)) |item| {
        var it = item;
        finalize(&it.payload);
        ended += 1;
    }
    while (redos.takeOwnedBy(owner)) |item| {
        var it = item;
        finalize(&it.payload);
    }
    if (ended > 0) log.info("window closed: {d} undo entr{s} ended", .{ ended, if (ended == 1) "y" else "ies" });
    arm();
}

/// End everything: the app is quitting.
pub fn dropAll() void {
    while (undos.takeAny()) |item| {
        var it = item;
        finalize(&it.payload);
    }
    while (redos.takeAny()) |item| {
        var it = item;
        finalize(&it.payload);
    }
    if (timer) |t| {
        _ = glib.Source.remove(t);
        timer = null;
    }
}

// ---------------------------------------------------------------------------
// Registering

/// Park the pane at `handle` of `tree` (`split_tree`'s tree, BEFORE the close
/// removes it) for its undo. Takes a reference, so the caller's removal does
/// not end it. False when undo is off, or the pane is its tab's only one
/// (closing it is closing the tab), or anything failed - then the close is
/// the immediate one it always was.
pub fn parkClosedPane(
    split_tree: *SplitTree,
    tree: *const Tree,
    handle: Tree.Node.Handle,
) bool {
    if (timeoutMs() == null) return false;
    const owner = ownerOf(split_tree) orelse return false;
    const surface = switch (tree.nodes[handle.idx()]) {
        .leaf => |v| v,
        .split => return false,
    };
    const alloc = gpa();
    var anchor = (Anchor.capture(alloc, tree, handle) catch return false) orelse return false;
    const home = newHome(split_tree) catch {
        anchor.deinit(alloc);
        return false;
    };
    if (!push(&undos, owner, .{ .pane = .{
        .surface = surface.ref(),
        .anchor = anchor,
        .home = home,
    } })) {
        surface.unref();
        anchor.deinit(alloc);
        freeHome(home);
        return false;
    }
    clearRedos(owner);
    log.info("parked closed pane {s} for undo", .{surface.paneId()});
    return true;
}

/// Park `tab`, which `window`'s tab view is about to close from `position`,
/// for its undo (T3590). Takes a reference, so the close only detaches it.
/// False when undo is off, the tab is its window's last (closing it closes
/// the window, which is not undoable here yet), or nothing in it is still
/// running - then the close is the immediate one it always was.
pub fn parkTab(window: *Window, tab: *Tab, position: c_int) bool {
    if (timeoutMs() == null) return false;
    if (window.getTabView().getNPages() <= 1) return false;
    const tree = tab.getSurfaceTree() orelse return false;
    if (!anyRunning(tree)) return false;
    const owner = @intFromPtr(window);
    if (!push(&undos, owner, .{ .tab = .{ .tab = tab.ref(), .position = position } })) {
        tab.unref();
        return false;
    }
    window.detachParkedTab(tab);
    clearRedos(owner);
    log.info("parked closed tab at {d} for undo", .{position});
    return true;
}

fn anyRunning(tree: *const Tree) bool {
    var it = tree.iterator();
    while (it.next()) |entry| if (!entry.view.hasChildExited()) return true;
    return false;
}

/// The close of the pane at `handle` when it is its tab's only one: with
/// undo on, close the TAB instead, its tree intact, so the tab parks whole
/// (T3590; win32 closes the tab from the same spot). True when it did - the
/// caller then removes nothing. False leaves the pane close as it was: undo
/// off, other panes in the tab, a shell that already exited, or the
/// window's last tab.
pub fn closeTabInstead(split_tree: *SplitTree, tree: *const Tree, handle: Tree.Node.Handle) bool {
    if (timeoutMs() == null) return false;
    const surface = switch (tree.nodes[handle.idx()]) {
        .leaf => |v| v,
        .split => return false,
    };
    var it = tree.iterator();
    while (it.next()) |entry| if (entry.view != surface) return false;
    if (surface.hasChildExited()) return false;
    const tab = ext.getAncestor(Tab, split_tree.as(gtk.Widget)) orelse return false;
    const window = ext.getAncestor(Window, split_tree.as(gtk.Widget)) orelse return false;
    if (window.getTabView().getNPages() <= 1) return false;
    return window.closeTabNow(tab);
}

/// `+rearrange`: replace `split_tree`'s layout with `new_tree` (as
/// `SplitTree.rearrange` does) and register its undo. A pane `new_tree`
/// leaves out is parked rather than ended while the undo lasts.
pub fn rearrange(split_tree: *SplitTree, new_tree: *const Tree) void {
    const alloc = gpa();
    const old = split_tree.getTree() orelse return split_tree.rearrange(new_tree);
    const owner = ownerOf(split_tree) orelse return split_tree.rearrange(new_tree);
    if (timeoutMs() == null) return split_tree.rearrange(new_tree);

    var before = Shape.capture(alloc, old, idOf) catch return split_tree.rearrange(new_tree);
    var left_out: std.ArrayListUnmanaged(*Surface) = .empty;
    const home = newHome(split_tree) catch {
        before.deinit(alloc);
        return split_tree.rearrange(new_tree);
    };
    {
        var it = old.iterator();
        while (it.next()) |entry| {
            if (treeHas(new_tree, entry.view)) continue;
            left_out.append(alloc, entry.view) catch {
                left_out.deinit(alloc);
                before.deinit(alloc);
                freeHome(home);
                return split_tree.rearrange(new_tree);
            };
        }
    }
    const owned = left_out.toOwnedSlice(alloc) catch {
        left_out.deinit(alloc);
        before.deinit(alloc);
        freeHome(home);
        return split_tree.rearrange(new_tree);
    };
    // Taken before the swap frees the old tree's references.
    for (owned) |s| _ = s.ref();
    const active: ?pane_id.Buf = if (split_tree.getActiveSurface()) |a| idOf(a) else null;

    split_tree.rearrange(new_tree);

    var entry: Entry = .{ .layout = .{
        .before = before,
        .active = active,
        .left_out = owned,
        .home = home,
    } };
    if (!push(&undos, owner, entry)) {
        finalize(&entry);
        return;
    }
    clearRedos(owner);
    log.info("parked rearranged layout for undo ({d} pane(s) left out)", .{owned.len});
}

// ---------------------------------------------------------------------------
// Undo / redo

/// Where a parked layout's ids resolve: the tab's panes now, plus the ones
/// the rearrange left out.
const Panes = struct {
    tree: *const Tree,
    left_out: []const *Surface,

    fn find(self: Panes, id: pane_id.Buf) ?*Surface {
        var it = self.tree.iterator();
        while (it.next()) |entry| {
            if (pane_id.eql(entry.view.paneId(), &id)) return entry.view;
        }
        for (self.left_out) |s| if (pane_id.eql(s.paneId(), &id)) return s;
        return null;
    }
};

/// The window an undo with this target acts on: the surface's window, or for
/// the app target the window of the most recent entry anywhere.
fn ownerFor(stack: *const Stack, target: ?*Surface) ?usize {
    if (target) |s| {
        const window = ext.getAncestor(Window, s.as(gtk.Widget)) orelse return null;
        return @intFromPtr(window);
    }
    return stack.topOwner();
}

/// Undo the most recent close or rearrange in `target`'s window (the app
/// target: anywhere). An entry whose tab has closed since is ended and the
/// next one tried. False when nothing was undone.
pub fn undo(target: ?*Surface) bool {
    const owner = ownerFor(&undos, target) orelse return false;
    while (undos.popFor(owner)) |first| {
        // A group (Close Other Tabs) comes back as one, and its redo closes
        // them again as one.
        const g = first.group;
        const was = group;
        group = if (g != 0) takeGroupId() else 0;
        defer group = was;
        var done = undoOne(owner, first);
        while (undos.popGroupFor(owner, g)) |more| {
            if (undoOne(owner, more)) done = true;
        }
        arm();
        if (done) return true;
    }
    return false;
}

fn undoOne(owner: usize, item: Stack.Item) bool {
    var it = item;
    return switch (it.payload) {
        .pane => restorePane(owner, &it.payload),
        .layout => restoreLayout(owner, &it.payload),
        .tab => restoreTab(owner, &it.payload),
        .pane_redo, .layout_redo, .tab_redo => unreachable,
    };
}

/// Redo the most recently undone close or rearrange in `target`'s window.
pub fn redo(target: ?*Surface) bool {
    const owner = ownerFor(&redos, target) orelse return false;
    while (redos.popFor(owner)) |first| {
        const g = first.group;
        const was = group;
        group = if (g != 0) takeGroupId() else 0;
        defer group = was;
        var done = redoOne(first);
        while (redos.popGroupFor(owner, g)) |more| {
            if (redoOne(more)) done = true;
        }
        arm();
        if (done) return true;
    }
    return false;
}

fn redoOne(item: Stack.Item) bool {
    var it = item;
    return switch (it.payload) {
        .pane_redo => reclosePane(&it.payload),
        .layout_redo => reapplyLayout(&it.payload),
        .tab_redo => recloseTab(&it.payload),
        .pane, .layout, .tab => unreachable,
    };
}

/// Consumes `entry`. The owner IS the window: `dropWindow` ends every entry
/// a window owns before it goes, so the pointer is live here.
fn restoreTab(owner: usize, entry: *Entry) bool {
    const t = &entry.tab;
    const window: *Window = @ptrFromInt(owner);
    const tree = t.tab.getSurfaceTree() orelse {
        finalize(entry);
        return false;
    };
    // Every shell in it exited while it waited: nothing to bring back.
    if (tree.isEmpty()) {
        finalize(entry);
        return false;
    }
    window.restoreParkedTab(t.tab, t.position);
    // T3563: back in a live tree, a later close is a close again.
    {
        var it = tree.iterator();
        while (it.next()) |e| e.view.clearDetachPin();
    }
    log.info("undo: closed tab restored at {d}", .{t.position});
    const ref = newTabRef(t.tab) catch null;
    t.tab.unref(); // the tab view holds it now
    if (ref) |r| {
        if (!push(&redos, owner, .{ .tab_redo = .{ .tab = r } })) freeTabRef(r);
    }
    return true;
}

/// Consumes `entry`.
fn recloseTab(entry: *Entry) bool {
    const r = &entry.tab_redo;
    defer finalize(entry);
    const tab = r.tab.get() orelse return false;
    defer tab.unref();
    const window = ext.getAncestor(Window, tab.as(gtk.Widget)) orelse return false;
    in_redo = true;
    defer in_redo = false;
    log.info("redo: closing tab again", .{});
    return window.closeTabNow(tab);
}

/// Consumes `entry`.
fn restorePane(owner: usize, entry: *Entry) bool {
    const p = &entry.pane;
    const alloc = gpa();
    const split_tree = p.home.get() orelse {
        finalize(entry);
        return false;
    };
    defer split_tree.unref();
    const tree = split_tree.getTree() orelse {
        finalize(entry);
        return false;
    };
    const place = (p.anchor.locate(alloc, tree) catch null) orelse {
        finalize(entry);
        return false;
    };
    var next = p.anchor.restore(alloc, tree, place.at, p.surface) catch {
        finalize(entry);
        return false;
    };
    defer next.deinit();
    split_tree.setTree(&next);
    split_tree.focusSurface(p.surface);
    // T3563: back in a live tree, a later close is a close again.
    p.surface.clearDetachPin();

    const id = idOf(p.surface);
    log.info("undo: closed pane {s} restored (exact={})", .{ p.surface.paneId(), place.exact });
    p.surface.unref(); // the tree holds it now
    p.anchor.deinit(alloc);
    // The redo reuses the same home.
    if (!push(&redos, owner, .{ .pane_redo = .{ .id = id, .home = p.home } })) freeHome(p.home);
    return true;
}

/// Consumes `entry`.
fn restoreLayout(owner: usize, entry: *Entry) bool {
    const l = &entry.layout;
    const alloc = gpa();
    const split_tree = l.home.get() orelse {
        finalize(entry);
        return false;
    };
    defer split_tree.unref();
    const tree = split_tree.getTree() orelse {
        finalize(entry);
        return false;
    };
    const panes: Panes = .{ .tree = tree, .left_out = l.left_out };
    var rebuilt = (l.before.rebuild(alloc, panes, Panes.find) catch null) orelse {
        finalize(entry);
        return false;
    };
    defer rebuilt.deinit();
    // A pane the tab gained since the rearrange joins on the right.
    layout_undo.appendMissing(Surface, alloc, &rebuilt, tree) catch {
        finalize(entry);
        return false;
    };
    const after: ?Shape = Shape.capture(alloc, tree, idOf) catch null;

    split_tree.rearrange(&rebuilt);
    if (l.active) |id| if (split_tree.getTree()) |now| {
        const found: Panes = .{ .tree = now, .left_out = &.{} };
        if (found.find(id)) |s| split_tree.focusSurface(s);
    };

    // A left-out pane the restored layout holds is the tree's now; one it
    // could not place (its id lost) is ended as the rearrange would have.
    const now_tree = split_tree.getTree();
    for (l.left_out) |s| {
        if (now_tree != null and treeHas(now_tree.?, s)) s.unref() else endSurface(s);
    }
    alloc.free(l.left_out);
    l.before.deinit(alloc);
    log.info("undo: rearranged layout restored", .{});

    if (after) |a| {
        if (push(&redos, owner, .{ .layout_redo = .{ .after = a, .home = l.home } })) return true;
        var shape = a;
        shape.deinit(alloc);
    }
    freeHome(l.home);
    return true;
}

/// Consumes `entry`.
fn reclosePane(entry: *Entry) bool {
    const r = &entry.pane_redo;
    defer finalize(entry);
    const split_tree = r.home.get() orelse return false;
    defer split_tree.unref();
    const tree = split_tree.getTree() orelse return false;
    const found: Panes = .{ .tree = tree, .left_out = &.{} };
    const surface = found.find(r.id) orelse return false;
    in_redo = true;
    defer in_redo = false;
    log.info("redo: closing pane {s} again", .{surface.paneId()});
    return split_tree.closeSurfaceNow(surface);
}

/// Consumes `entry`.
fn reapplyLayout(entry: *Entry) bool {
    const r = &entry.layout_redo;
    defer finalize(entry);
    const alloc = gpa();
    const split_tree = r.home.get() orelse return false;
    defer split_tree.unref();
    const tree = split_tree.getTree() orelse return false;
    const panes: Panes = .{ .tree = tree, .left_out = &.{} };
    var next = (r.after.rebuild(alloc, panes, Panes.find) catch null) orelse return false;
    defer next.deinit();
    in_redo = true;
    defer in_redo = false;
    log.info("redo: rearranged layout applied again", .{});
    rearrange(split_tree, &next);
    return true;
}
