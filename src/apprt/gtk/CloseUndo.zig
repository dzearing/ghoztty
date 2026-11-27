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
//! and Close Tabs to the Right are ONE undo (a group).
//!
//! A closed WINDOW parks too (T3665, win32 T1874) - closed by its close
//! button, `win.close`, `+close`, or its last tab or last pane going. It is
//! hidden and taken out of the application's window list, which every
//! window walk reads (`+list`, targeting, sidebars, session layout), while
//! every tab, pane and shell in it stays as it was. Its entry is owned by
//! `shared_owner`: the window it would be scoped to is the one that closed,
//! so any other window's undo reaches it, in recency order with that
//! window's own closes. The last window is never parked - with nothing left
//! on screen there is nowhere to press undo. A single-window-mode workspace
//! is not parked here (T3790).

const std = @import("std");
const Allocator = std.mem.Allocator;

const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("ext.zig");
const Application = @import("class/application.zig").Application;
const Surface = @import("class/surface.zig").Surface;
const SplitTree = @import("class/split_tree.zig").SplitTree;
const Tab = @import("class/tab.zig").Tab;
const Window = @import("class/window.zig").Window;
const Workspaces = @import("Workspaces.zig");
const WeakRef = @import("weak_ref.zig").WeakRef;
const close_undo = @import("../win32/close_undo.zig");
const layout_undo = @import("../win32/layout_undo.zig");
const pane_id = @import("../ipc/pane_id.zig");
const pane_stack_state = @import("../win32/pane_stack_state.zig");
const move_undo_rules = @import("move_undo_rules.zig");

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

/// A window a redo closes again, held weakly (boxed, as `Home`).
const WindowRef = WeakRef(Window);

/// The owner key of an entry no window scopes: a closed window's own close
/// (T3665). Never a real window's key (`owner` is a pointer).
const shared_owner: usize = 0;

const Entry = union(enum) {
    /// Undo: put a closed pane back.
    pane: struct {
        /// Holds ONE reference: the one the tree used to.
        surface: *Surface,
        anchor: Anchor,
        home: *Home,
        /// The tab's stacked rows as they were before the close (T3627,
        /// win32 T2126): the undo puts them back exactly. Owned.
        stack: ?pane_stack_state.Saved,
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
    /// Undo: show a closed window again (T3665). Owned by `shared_owner`.
    window: struct {
        /// Holds ONE reference; parked (hidden, out of the app's list).
        window: *Window,
    },
    /// Redo: close that pane again.
    pane_redo: struct { id: pane_id.Buf, home: *Home },
    /// Redo: close that tab again.
    tab_redo: struct { tab: *TabRef },
    /// Redo: put the rearranged layout back.
    layout_redo: struct { after: Shape, home: *Home },
    /// Redo: close that window again (T3665).
    window_redo: struct { window: *WindowRef },
    /// Undo or redo: put back the trees a pane drag changed (T3706). The
    /// same shape on both stacks - applying one records its mirror image.
    move: Move,
};

/// One tree a pane move touched, as it was before (T3706).
const MoveSide = struct {
    home: *Home,
    /// The tree by pane identity; empty for a tab the move created.
    shape: Shape,
    /// Its stacked rows (T3627). Owned.
    stack: ?pane_stack_state.Saved,
};

/// A tab or window the move EMPTIED, kept so the undo can bring it back.
const MoveParked = union(enum) {
    /// Out of its window's tab view; holds ONE reference.
    tab: struct { tab: *Tab, window: *WindowRef, position: c_int },
    /// Parked (hidden, out of the app's list); holds ONE reference.
    window: *Window,
};

/// A pane drag as one undoable step (T3706; Mac `PaneMoveCoordinator`,
/// undo action "Move Pane").
const Move = struct {
    /// Owned.
    sides: []MoveSide,
    /// Owned.
    parked: []MoveParked,
    /// The pane that takes focus when this is applied.
    focus: ?pane_id.Buf,
    /// The pane the mirror image focuses.
    refocus: ?pane_id.Buf,
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

fn newWindowRef(window: *Window) Allocator.Error!*WindowRef {
    const ref = try gpa().create(WindowRef);
    ref.* = .empty;
    ref.set(window);
    return ref;
}

fn freeWindowRef(ref: *WindowRef) void {
    ref.set(null);
    gpa().destroy(ref);
}

/// Every pane of every tab of `window`.
fn forEachPane(window: *Window, comptime f: fn (*Surface) void) void {
    const tab_view = window.getTabView();
    const n: usize = @intCast(tab_view.getNPages());
    for (0..n) |i| {
        const tab = gobject.ext.cast(Tab, tab_view.getNthPage(@intCast(i)).getChild()) orelse continue;
        const tree = tab.getSurfaceTree() orelse continue;
        var it = tree.iterator();
        while (it.next()) |entry| f(entry.view);
    }
}

fn markClose(s: *Surface) void {
    s.markSessionClose();
}

fn clearPin(s: *Surface) void {
    s.clearDetachPin();
}

/// A parked window's teardown: every pane ends as a close would end it,
/// then the window goes.
fn endWindow(window: *Window) void {
    forEachPane(window, markClose);
    window.endParked();
    window.unref();
}

/// Free an entry for good, ending whatever it kept alive.
fn finalize(entry: *Entry) void {
    const alloc = gpa();
    switch (entry.*) {
        .pane => |*p| {
            endSurface(p.surface);
            p.anchor.deinit(alloc);
            if (p.stack) |*st| st.deinit(alloc);
            freeHome(p.home);
        },
        .layout => |*l| {
            for (l.left_out) |s| endSurface(s);
            alloc.free(l.left_out);
            l.before.deinit(alloc);
            freeHome(l.home);
        },
        .tab => |*t| endTab(t.tab),
        .window => |*w| endWindow(w.window),
        .window_redo => |*r| freeWindowRef(r.window),
        .pane_redo => |*r| freeHome(r.home),
        .tab_redo => |*r| freeTabRef(r.tab),
        .layout_redo => |*r| {
            r.after.deinit(alloc);
            freeHome(r.home);
        },
        .move => |*m| {
            freeMoveSides(m.sides);
            for (m.parked) |p| endMoveParked(p);
            alloc.free(m.parked);
        },
    }
}

fn freeMoveSide(s: *MoveSide) void {
    const alloc = gpa();
    s.shape.deinit(alloc);
    if (s.stack) |*st| st.deinit(alloc);
    freeHome(s.home);
}

fn freeMoveSides(sides: []MoveSide) void {
    for (sides) |*s| freeMoveSide(s);
    gpa().free(sides);
}

/// A tab or window a move emptied ends: nothing runs in it.
fn endMoveParked(p: MoveParked) void {
    switch (p) {
        .tab => |t| {
            endTab(t.tab);
            freeWindowRef(t.window);
        },
        .window => |w| endWindow(w),
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
    var stack = split_tree.stackSaved();
    if (!push(&undos, owner, .{ .pane = .{
        .surface = surface.ref(),
        .anchor = anchor,
        .home = home,
        .stack = stack,
    } })) {
        surface.unref();
        anchor.deinit(alloc);
        if (stack) |*st| st.deinit(alloc);
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
    if (captureMovedTab(window, tab, position)) return true;
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

/// Whether closing `window` now would park it (T3665): undo on, an
/// ordinary window (not the quick terminal, not a single-window-mode
/// workspace or frame, not already parked), another window still open to
/// press undo in, and a shell still running in it.
pub fn canParkWindow(window: *Window) bool {
    if (timeoutMs() == null) return false;
    if (window.isQuickTerminal() or window.isFrame() or window.isParkedForUndo()) return false;
    // A workspace close's undo is T3790.
    if (Workspaces.applies(window) or Workspaces.manages(window)) return false;
    const others = others: {
        var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
        while (node) |n| {
            node = n.f_next;
            const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
            const w = gobject.ext.cast(Window, obj) orelse continue;
            if (w != window and !w.isFrame()) break :others true;
        }
        break :others false;
    };
    if (!others) return false;
    const tab_view = window.getTabView();
    const n: usize = @intCast(tab_view.getNPages());
    for (0..n) |i| {
        const tab = gobject.ext.cast(Tab, tab_view.getNthPage(@intCast(i)).getChild()) orelse continue;
        const tree = tab.getSurfaceTree() orelse continue;
        if (anyRunning(tree)) return true;
    }
    return false;
}

/// Park `window`, which the user just closed (T3665, win32 T1874). True
/// means it is hidden and out of the application's window list with every
/// tab and shell intact, and the caller must NOT close it; false means
/// close it as before (see `canParkWindow`).
pub fn parkWindow(window: *Window) bool {
    if (captureMovedWindow(window)) return true;
    if (!canParkWindow(window)) return false;
    if (!push(&undos, shared_owner, .{ .window = .{ .window = window.ref() } })) {
        window.unref();
        return false;
    }
    clearRedos(shared_owner);
    window.parkForUndo();
    log.info("parked closed window for undo", .{});
    return true;
}

fn isWindowEntry(target: *Window, entry: *const Entry) bool {
    return switch (entry.*) {
        .window => |w| w.window == target,
        else => false,
    };
}

/// A parked window is closing for real (its last shell exited while it
/// waited): its undo goes, without the teardown - the caller runs that.
pub fn forgetWindow(window: *Window) void {
    if (undos.takeMatching(window, isWindowEntry)) |item| {
        item.payload.window.window.unref();
        arm();
    }
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
    // The window's last tab closing closes the window: that parks it whole
    // when it can (T3665), and is the pane close it always was when not.
    if (window.getTabView().getNPages() <= 1 and !canParkWindow(window)) return false;
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
// Pane moves (T3706)
//
// A pane drag changes one tree (a drop in its own tab) or two (another tab,
// another window), and may empty a tab - closing it - and with it a window.
// Mac undoes all of that as ONE step ("Move Pane"). Here a drag's commit is
// bracketed by `beginMove` / `endMove`: the first records each tree's shape
// by pane id, and while it is open a tab or window the move empties is kept
// rather than destroyed (`parkTab` / `parkWindow` hand it to the open move).
// Undo rebuilds every tree together (`move_undo_rules.rebuildAcross`), so a
// pane goes back to the tree it left, puts back what was emptied, and
// records the mirror image the same way - which is the redo, and which in
// turn keeps a tab or window the UNDO empties (a drag's new tab or window).

const MoveTx = struct {
    sides: std.ArrayListUnmanaged(MoveSide) = .empty,
    parked: std.ArrayListUnmanaged(MoveParked) = .empty,
    windows: std.ArrayListUnmanaged(usize) = .empty,
    focus: ?pane_id.Buf = null,
    refocus: ?pane_id.Buf = null,
    /// Something could not be recorded: the move happens, unrecorded.
    failed: bool = false,
};

var move_tx: ?MoveTx = null;

fn idBuf(id: []const u8) ?pane_id.Buf {
    if (id.len != pane_id.len) return null;
    var buf: pane_id.Buf = undefined;
    @memcpy(&buf, id[0..pane_id.len]);
    return buf;
}

fn addMoveSide(tx: *MoveTx, split_tree: *SplitTree, created: bool) void {
    const alloc = gpa();
    for (tx.sides.items) |*s| {
        const t = s.home.get() orelse continue;
        defer t.unref();
        if (t == split_tree) return;
    }
    const empty: Tree = .empty;
    const now: *const Tree = if (created) &empty else split_tree.getTree() orelse &empty;
    var shape = Shape.capture(alloc, now, idOf) catch {
        tx.failed = true;
        return;
    };
    const home = newHome(split_tree) catch {
        shape.deinit(alloc);
        tx.failed = true;
        return;
    };
    var stack: ?pane_stack_state.Saved = if (created) null else split_tree.stackSaved();
    tx.sides.append(alloc, .{ .home = home, .shape = shape, .stack = stack }) catch {
        shape.deinit(alloc);
        if (stack) |*st| st.deinit(alloc);
        freeHome(home);
        tx.failed = true;
        return;
    };
    if (ownerOf(split_tree)) |w| tx.windows.append(alloc, w) catch {
        tx.failed = true;
    };
}

/// A pane drag is about to change `trees` (the tree it leaves first):
/// record them for its undo. `moved` is the dragged pane, which a redo
/// focuses. False when undo is off or a move is already open - the drag
/// then happens unrecorded, as before; `endMove` is still safe to call.
pub fn beginMove(trees: []const *SplitTree, moved: []const u8) bool {
    if (move_tx != null) return false;
    if (timeoutMs() == null) return false;
    move_tx = .{};
    const tx = &move_tx.?;
    for (trees) |t| addMoveSide(tx, t, false);
    if (trees.len > 0) if (trees[0].getActiveSurface()) |s| {
        tx.focus = idOf(s);
    };
    tx.refocus = idBuf(moved);
    return true;
}

/// `split_tree` is a tab the open move just MADE (a drop on the tab bar,
/// a pop-out): its undo empties it again.
pub fn moveCreated(split_tree: *SplitTree) void {
    const tx = &(move_tx orelse return);
    addMoveSide(tx, split_tree, true);
}

/// The open move is done: register it as one undo.
pub fn endMove() void {
    const owner = owner: {
        const tx = &(move_tx orelse return);
        break :owner move_undo_rules.ownerFor(tx.windows.items, shared_owner);
    };
    if (finishMove(owner, &undos)) clearRedos(owner);
}

/// Close the open move onto `stack`, owned by `owner`. False when nothing
/// was recorded (then whatever it kept is ended).
fn finishMove(owner: usize, stack: *Stack) bool {
    const alloc = gpa();
    var tx = move_tx orelse return false;
    move_tx = null;
    defer tx.windows.deinit(alloc);
    defer {
        // Whatever was not handed to an entry ends here.
        for (tx.sides.items) |*s| freeMoveSide(s);
        tx.sides.deinit(alloc);
        for (tx.parked.items) |p| endMoveParked(p);
        tx.parked.deinit(alloc);
    }
    if (tx.failed or tx.sides.items.len == 0) return false;
    const sides = tx.sides.toOwnedSlice(alloc) catch return false;
    const parked = tx.parked.toOwnedSlice(alloc) catch {
        freeMoveSides(sides);
        return false;
    };
    var entry: Entry = .{ .move = .{
        .sides = sides,
        .parked = parked,
        .focus = tx.focus,
        .refocus = tx.refocus,
    } };
    if (!push(stack, owner, entry)) {
        finalize(&entry);
        return false;
    }
    log.info("pane move recorded for undo ({d} tree(s), {d} emptied)", .{ sides.len, parked.len });
    return true;
}

/// A tab the open move emptied is closing: keep it (one reference, out of
/// its window) instead of letting it go. True when it was taken.
fn captureMovedTab(window: *Window, tab: *Tab, position: c_int) bool {
    const tx = &(move_tx orelse return false);
    if (tab.getSurfaceTree()) |t| if (!t.isEmpty()) return false;
    const ref = newWindowRef(window) catch {
        tx.failed = true;
        return false;
    };
    tx.parked.append(gpa(), .{ .tab = .{ .tab = tab.ref(), .window = ref, .position = position } }) catch {
        tab.unref();
        freeWindowRef(ref);
        tx.failed = true;
        return false;
    };
    window.detachParkedTab(tab);
    log.info("pane move emptied the tab at {d}: kept for undo", .{position});
    return true;
}

/// The open move emptied `window`'s last tab: park the window whole, as a
/// close would (T3665), instead of letting it go. True when it was taken.
fn captureMovedWindow(window: *Window) bool {
    const tx = &(move_tx orelse return false);
    if (window.isQuickTerminal() or window.isFrame() or window.isParkedForUndo()) return false;
    if (Workspaces.applies(window) or Workspaces.manages(window)) return false;
    const tab_view = window.getTabView();
    const n: usize = @intCast(tab_view.getNPages());
    for (0..n) |i| {
        const tab = gobject.ext.cast(Tab, tab_view.getNthPage(@intCast(i)).getChild()) orelse continue;
        if (tab.getSurfaceTree()) |t| if (!t.isEmpty()) return false;
    }
    tx.parked.append(gpa(), .{ .window = window.ref() }) catch {
        window.unref();
        tx.failed = true;
        return false;
    };
    window.parkForUndo();
    log.info("pane move emptied a window: kept for undo", .{});
    return true;
}

fn isMoveParkedWindow(m: *const Move, w: *Window) bool {
    for (m.parked) |p| switch (p) {
        .window => |pw| if (pw == w) return true,
        .tab => {},
    };
    return false;
}

const max_move_sides = 8;

/// Consumes `entry`. Put every tree the move touched back as its shape has
/// it, bring back what it emptied, and record the mirror image on `into`.
fn applyMove(owner: usize, entry: *Entry, into: *Stack) bool {
    const m = &entry.move;
    const alloc = gpa();
    if (m.sides.len == 0 or m.sides.len > max_move_sides or move_tx != null) {
        finalize(entry);
        return false;
    }

    // Every tree must still be here, in a window that is on screen or that
    // this very move parked.
    var trees_buf: [max_move_sides]*SplitTree = undefined;
    var got: usize = 0;
    defer for (trees_buf[0..got]) |t| t.unref();
    for (m.sides) |*s| {
        trees_buf[got] = s.home.get() orelse {
            finalize(entry);
            return false;
        };
        got += 1;
    }
    const trees = trees_buf[0..got];
    for (trees) |t| {
        const w = ext.getAncestor(Window, t.as(gtk.Widget)) orelse continue;
        if (w.isParkedForUndo() and !isMoveParkedWindow(m, w)) {
            finalize(entry);
            return false;
        }
    }
    // A kept tab goes back into its window, which must still be open.
    if (m.parked.len > max_move_sides) {
        finalize(entry);
        return false;
    }
    var windows_buf: [max_move_sides]?*Window = .{null} ** max_move_sides;
    defer for (windows_buf) |w| if (w) |x| x.unref();
    for (m.parked, 0..) |p, i| switch (p) {
        .tab => |t| {
            windows_buf[i] = t.window.get() orelse {
                finalize(entry);
                return false;
            };
        },
        .window => {},
    };

    var current: [max_move_sides]?*const Tree = undefined;
    var shapes: [max_move_sides]Shape = undefined;
    for (trees, m.sides, 0..) |t, *s, i| {
        current[i] = t.getTree();
        shapes[i] = s.shape;
    }
    const rebuilt = move_undo_rules.rebuildAcross(
        Surface,
        pane_id.Buf,
        alloc,
        shapes[0..trees.len],
        current[0..trees.len],
        idOf,
    ) catch {
        finalize(entry);
        return false;
    };
    defer move_undo_rules.freeAll(Surface, alloc, rebuilt);

    // What it emptied comes back first: windows, then tabs into them.
    for (m.parked) |p| switch (p) {
        .window => |w| w.unparkFromUndo(),
        .tab => {},
    };
    for (m.parked, 0..) |p, i| switch (p) {
        .tab => |t| windows_buf[i].?.restoreParkedTab(t.tab, t.position),
        .window => {},
    };

    // The mirror image, from the trees as they are now. A tree this empties
    // closes its tab - and window - into it.
    move_tx = .{};
    for (trees) |t| addMoveSide(&move_tx.?, t, false);
    move_tx.?.focus = m.refocus;
    move_tx.?.refocus = m.focus;

    for (trees, rebuilt, m.sides) |t, *next, *s| {
        t.rearrange(next);
        if (s.stack) |*st| if (!next.isEmpty()) t.restoreStackRows(st);
    }
    if (m.focus) |id| for (trees) |t| {
        if (t.surfaceById(&id)) |s| {
            if (!t.isStackMinimized(s)) t.focusSurface(s);
            break;
        }
    };
    // T3563: a pane back in a live tree closes as a close again.
    for (trees) |t| if (t.getTree()) |now| {
        var it = now.iterator();
        while (it.next()) |e| e.view.clearDetachPin();
    };

    // The tab views and the application hold what came back now.
    for (m.parked) |p| switch (p) {
        .tab => |t| {
            t.tab.unref();
            freeWindowRef(t.window);
        },
        .window => |w| w.unref(),
    };
    alloc.free(m.parked);
    m.parked = &.{};
    freeMoveSides(m.sides);
    m.sides = &.{};

    if (!finishMove(owner, into)) log.info("pane move put back; its mirror image was not recorded", .{});
    return true;
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

/// The most recent entry an undo (or redo) with this target acts on: one of
/// the surface's window, or a closed window's (`shared_owner`, T3665); for
/// the app target, the most recent entry anywhere.
fn popFirst(stack: *Stack, target: ?*Surface) ?Stack.Item {
    if (target) |s| {
        const window = ext.getAncestor(Window, s.as(gtk.Widget)) orelse return null;
        return stack.popForEither(@intFromPtr(window), shared_owner);
    }
    const top = stack.topOwner() orelse return null;
    return stack.popFor(top);
}

/// Undo the most recent close or rearrange in `target`'s window (the app
/// target: anywhere). An entry whose tab has closed since is ended and the
/// next one tried. False when nothing was undone.
pub fn undo(target: ?*Surface) bool {
    while (popFirst(&undos, target)) |first| {
        const owner = first.owner;
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
        .window => restoreWindow(&it.payload),
        .move => applyMove(owner, &it.payload, &redos),
        .pane_redo, .layout_redo, .tab_redo, .window_redo => unreachable,
    };
}

/// Redo the most recently undone close or rearrange in `target`'s window.
pub fn redo(target: ?*Surface) bool {
    while (popFirst(&redos, target)) |first| {
        const owner = first.owner;
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
        .window_redo => recloseWindow(&it.payload),
        .move => applyMove(it.owner, &it.payload, &undos),
        .pane, .layout, .tab, .window => unreachable,
    };
}

/// Consumes `entry`. Back in the application, shown, the same tabs and
/// shells (T3665).
fn restoreWindow(entry: *Entry) bool {
    const window = entry.window.window;
    // Every shell in it exited while it waited: nothing to bring back.
    if (window.getTabView().getNPages() == 0) {
        finalize(entry);
        return false;
    }
    window.unparkFromUndo();
    // T3563: back in a live window, a later close is a close again.
    forEachPane(window, clearPin);
    log.info("undo: closed window restored with {d} tab(s)", .{window.getTabView().getNPages()});
    const ref = newWindowRef(window) catch null;
    window.unref(); // the application holds it now
    if (ref) |r| {
        if (!push(&redos, shared_owner, .{ .window_redo = .{ .window = r } })) freeWindowRef(r);
    }
    return true;
}

/// Consumes `entry`.
fn recloseWindow(entry: *Entry) bool {
    const r = &entry.window_redo;
    defer finalize(entry);
    const window = r.window.get() orelse return false;
    defer window.unref();
    if (window.isParkedForUndo()) return false;
    in_redo = true;
    defer in_redo = false;
    log.info("redo: closing window again", .{});
    window.closeNow();
    return true;
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
    // Its row comes back exactly as it was (T3627). A pane that comes back
    // as a strip stays one: focusing it would bring it out, and the row is
    // meant to be as it was - the caret stays where it is.
    if (p.stack) |*st| {
        split_tree.restoreStackRows(st);
        st.deinit(alloc);
        p.stack = null;
    }
    if (!split_tree.isStackMinimized(p.surface)) split_tree.focusSurface(p.surface);
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
