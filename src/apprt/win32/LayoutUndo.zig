//! Undo for `+rearrange`, on the desktop (T2234).
//!
//! Mac's `+rearrange` registers "Rearrange Layout" with the window's undo
//! manager: Cmd+Z puts the previous layout back for `undo-timeout`, panes the
//! layout left out included, and Cmd+Shift+Z puts the rearranged one back
//! again. This is the Windows half, on the same per-window stack as a closed
//! pane (`CloseUndo.zig`), so Ctrl+Shift+Z and Ctrl+Shift+Y reach it in the
//! order things happened.
//!
//! A rearrange that leaves a pane out used to END that pane on the spot. With
//! undo on, it is PARKED instead, exactly as a closed pane is: one reference
//! held, its HWND hidden, its shell and agent session untouched, its IPC name
//! kept aside. The previous layout itself is recorded by pane identity
//! (`layout_undo.Shape`), never by reference - see that file for why, and for
//! what an undo does about panes split, closed or lost in the meantime. When
//! the undo expires, the parked panes get the teardown the rearrange would
//! have given them.
//!
//! `apply` is the swap itself, shared by `+rearrange` and by a redo, so the
//! two can never disagree about what replacing a tab's layout means.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Window = @import("Window.zig");
const PaneView = @import("PaneView.zig");
const CloseUndo = @import("CloseUndo.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const agent_recovery = @import("agent_recovery.zig");
const layout_undo = @import("layout_undo.zig");
const pane_id = @import("pane_id.zig");
const pane_stash = @import("pane_stash.zig");
const pane_stack_state = @import("pane_stack_state.zig");

const log = std.log.scoped(.layout_undo);

const Tree = SplitTree(PaneView);
pub const Shape = layout_undo.Shape(PaneView, pane_id.Buf);

/// A rearranged tab's previous layout, held for its undo.
pub const Parked = struct {
    window: *Window,
    /// The tab, by identity: an index would name a different tab once any
    /// tab before it closed.
    tab_uuid: pane_id.Buf,
    /// The layout before the rearrange, stash marks included. Owned.
    before: Shape,
    /// The pane that had focus before it.
    active: pane_id.Buf,
    /// The panes the rearrange left out: hidden, in no tree, alive only
    /// through the reference each entry holds. Owned.
    left_out: std.ArrayListUnmanaged(LeftOut),
    /// Which panes of each stacked row were on show (T2126). Owned.
    stack: ?pane_stack_state.Saved,
};

pub const LeftOut = struct {
    /// Holds ONE reference: the one the old tree used to.
    pane: *PaneView,
    /// Its IPC name, registered again by the undo. Owned.
    name: ?[]u8,
    /// Whether the rearrange would have ended its session (T128): false for a
    /// pane whose session another pane in the new layout still shows.
    close: bool,
};

/// What a redo puts back: the rearranged layout, by identity.
pub const Redo = struct {
    tab_uuid: pane_id.Buf,
    after: Shape,
};

fn idOf(v: *const PaneView) pane_id.Buf {
    return v.paneId()[0..pane_id.len].*;
}

pub fn capture(alloc: Allocator, tree: *const Tree) Allocator.Error!Shape {
    return Shape.capture(alloc, tree, idOf);
}

fn inTree(tree: *const Tree, v: *const PaneView) bool {
    var it = tree.iterator();
    while (it.next()) |entry| if (entry.view == v) return true;
    return false;
}

fn findTab(window: *Window, uuid: *const pane_id.Buf) ?usize {
    for (0..window.tab_count) |t| {
        if (pane_id.eql(window.tabUuid(t), uuid)) return t;
    }
    return null;
}

/// Where a parked layout's identities resolve: the tab's panes as they are
/// now, plus the panes the rearrange left out.
const Panes = struct {
    tree: *const Tree,
    left_out: []const LeftOut,

    fn find(self: Panes, id: pane_id.Buf) ?*PaneView {
        var it = self.tree.iterator();
        while (it.next()) |entry| {
            if (pane_id.eql(entry.view.paneId(), &id)) return entry.view;
        }
        for (self.left_out) |l| if (pane_id.eql(l.pane.paneId(), &id)) return l.pane;
        return null;
    }
};

fn sessionId(view: *PaneView) ?[]const u8 {
    const s = view.surface() orelse return null;
    return if (s.core_surface_ready) s.core_surface.remoteSessionId() else null;
}

/// Replace tab `tab`'s tree with `new_tree`, the way `+rearrange` does, and
/// register its undo. Takes over `new_tree` and `before` (the layout as it
/// was, captured before the caller touched any stash mark) on every path. A
/// pane `new_tree` leaves out is parked for the undo when undo is on, and
/// ended (T128) as before when it is not. Fails only before anything changed.
pub fn apply(
    app: *App,
    window: *Window,
    tab: usize,
    new_tree: Tree,
    before: Shape,
) Allocator.Error!void {
    const gpa = app.core_app.alloc;
    var next = new_tree;
    var shape = before;
    var shape_owned = true;
    defer if (shape_owned) shape.deinit(gpa);
    errdefer next.deinit();

    // T128: the session ids the NEW layout still references. Collected while
    // allocating is still free to fail.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var surviving_ids: std.ArrayList([]const u8) = .empty;
    {
        var it = next.iterator();
        while (it.next()) |entry| {
            if (sessionId(entry.view)) |sid| try surviving_ids.append(arena, sid);
        }
    }

    const park = app.close_undo.parkable(window);
    var left_out: std.ArrayListUnmanaged(LeftOut) = .empty;
    errdefer left_out.deinit(gpa);
    const tree = &window.tab_trees[tab];
    if (park) {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (inTree(&next, entry.view)) continue;
            try left_out.append(gpa, .{ .pane = entry.view, .name = null, .close = false });
        }
    }

    // Nothing below fails. Every pane of the old tree learns where it stands:
    // kept, parked, or ended.
    {
        var it = tree.iterator();
        while (it.next()) |entry| {
            const view = entry.view;
            const in_new_tree = inTree(&next, view);
            const closes = agent_recovery.closesDepartingLeaf(in_new_tree, sessionId(view), surviving_ids.items);
            if (!in_new_tree and park) continue; // parked below
            if (closes) {
                view.setSessionCloseIntent(true);
            } else if (in_new_tree) {
                // Re-adoption releases a Disconnect pin (T1390): this pane is
                // live in the new layout, so a LATER close is a close like any
                // other.
                view.clearDetachPin();
            }
            // A pane leaving the layout takes its popups with it NOW (T2012):
            // no sweep walks it once the tree is swapped.
            if (!in_new_tree) view.hideOverlays();
        }
    }
    for (left_out.items) |*l| {
        l.close = agent_recovery.closesDepartingLeaf(false, sessionId(l.pane), surviving_ids.items);
        l.name = if (app.ipcNameOf(.{ .pane = l.pane })) |n| gpa.dupe(u8, n) catch null else null;
        _ = l.pane.ref(gpa) catch unreachable; // PaneView.ref cannot fail
        CloseUndo.hidePane(l.pane);
    }
    var stack = if (park) window.stackSaved() else null;
    var active: pane_id.Buf = undefined;
    const current_focus = window.tab_active_pane[tab];
    @memcpy(&active, current_focus.paneId()[0..pane_id.len]);

    // Swap trees. Old-tree deinit unrefs every old view: a pane left out with
    // undo off reaches refcount 0 and is destroyed; a parked one keeps the
    // reference taken above.
    var old_tree = window.tab_trees[tab];
    window.tab_trees[tab] = next;
    old_tree.deinit();

    if (park) {
        var parked: Parked = .{
            .window = window,
            .tab_uuid = undefined,
            .before = shape,
            .active = active,
            .left_out = left_out,
            .stack = stack,
        };
        @memcpy(&parked.tab_uuid, window.tabUuid(tab)[0..pane_id.len]);
        if (app.close_undo.parkLayout(window, parked)) {
            shape_owned = false;
            log.info("parked rearranged layout for undo ({} pane(s) left out)", .{left_out.items.len});
        } else |_| {
            // No room on the stack: the rearrange ends what it left out, as
            // it did before undo existed.
            if (stack) |*st| st.deinit(gpa);
            stack = null;
            for (left_out.items) |l| endLeftOut(gpa, l);
            left_out.deinit(gpa);
        }
    }

    _ = pane_stash.normalize(&window.tab_trees[tab]);

    // Focus: keep the focused pane if it survived, else the top-left one on
    // screen (Mac `leftmostLeaf()`, T1371) - never storage order.
    if (pane_stash.keepOrFirstVisible(window.tab_trees[tab], current_focus)) |focus| {
        window.tab_active_pane[tab] = focus;
        window.heroOnTreeChanged(tab);
        window.layoutSplits();
        if (focus.hwnd()) |h| App.deferSetFocus(h); // T48
    }
    window.updateWindowTitle();
    // T110: the whole tree (topology AND every split ratio) just changed -
    // re-persist, else a restore rebuilds the PRE-rearrange shape.
    app.markLayoutDirty();
}

/// The teardown the rearrange would have given a left-out pane.
fn endLeftOut(gpa: Allocator, l: LeftOut) void {
    if (l.name) |n| gpa.free(n);
    if (l.close) l.pane.setSessionCloseIntent(true);
    l.pane.unref(gpa);
}

/// Put a parked layout back. Returns what a redo puts back again, or null when
/// it could not be restored - in which case it has been finalized instead, so
/// a failed undo never strands a hidden live pane.
pub fn restore(app: *App, parked: Parked) ?Redo {
    var p = parked;
    const gpa = app.core_app.alloc;
    const window = p.window;
    const t = findTab(window, &p.tab_uuid) orelse {
        // The tab closed since: nothing to put the layout back into.
        finalize(app, p);
        return null;
    };

    const panes: Panes = .{ .tree = &window.tab_trees[t], .left_out = p.left_out.items };
    var tree = (p.before.rebuild(gpa, panes, Panes.find) catch null) orelse {
        finalize(app, p);
        return null;
    };
    layout_undo.appendMissing(PaneView, gpa, &tree, &window.tab_trees[t]) catch {
        tree.deinit();
        finalize(app, p);
        return null;
    };
    const redo: ?Redo = if (capture(gpa, &window.tab_trees[t])) |after|
        .{ .tab_uuid = p.tab_uuid, .after = after }
    else |_|
        null;

    p.before.restoreStash(panes, Panes.find);
    var old = window.tab_trees[t];
    window.tab_trees[t] = tree;
    old.deinit(); // every pane in it is in the restored tree too

    for (p.left_out.items) |l| {
        if (inTree(&window.tab_trees[t], l.pane)) {
            if (l.name) |n| app.ipcRegister(n, .{ .pane = l.pane }) catch {};
            if (l.name) |n| gpa.free(n);
            l.pane.unref(gpa); // the tree holds it now
        } else endLeftOut(gpa, l);
    }
    p.left_out.deinit(gpa);
    p.before.deinit(gpa);

    _ = pane_stash.normalize(&window.tab_trees[t]);
    if (p.stack) |*st| {
        window.restoreStackRows(t, st);
        st.deinit(gpa);
    }

    var focus: ?*PaneView = null;
    {
        var it = window.tab_trees[t].iterator();
        while (it.next()) |entry| {
            if (pane_id.eql(entry.view.paneId(), &p.active)) focus = entry.view;
        }
    }
    if (pane_stash.keepOrFirstVisible(window.tab_trees[t], focus)) |f| window.tab_active_pane[t] = f;
    if (t != window.active_tab) {
        window.selectTabIndex(t);
    } else {
        window.heroOnTreeChanged(t);
        window.layoutSplits();
        if (window.tab_active_pane[t].hwnd()) |h| App.deferSetFocus(h);
    }
    window.updateWindowTitle();
    app.markLayoutDirty();
    log.info("undo: rearranged layout restored", .{});
    return redo;
}

/// Put the rearranged layout back, as `+rearrange` did it. Consumes `redo`.
pub fn reapply(app: *App, window: *Window, redo: Redo) void {
    var r = redo;
    const gpa = app.core_app.alloc;
    defer r.after.deinit(gpa);
    const t = findTab(window, &r.tab_uuid) orelse return;
    const panes: Panes = .{ .tree = &window.tab_trees[t], .left_out = &.{} };
    const tree = (r.after.rebuild(gpa, panes, Panes.find) catch null) orelse return;
    const before = capture(gpa, &window.tab_trees[t]) catch {
        var tr = tree;
        tr.deinit();
        return;
    };
    r.after.restoreStash(panes, Panes.find);
    apply(app, window, t, tree, before) catch |err| log.warn("redo: rearrange failed: {}", .{err});
}

/// End a parked layout for good: every pane it left out gets the teardown the
/// rearrange would have given it.
pub fn finalize(app: *App, parked: Parked) void {
    const gpa = app.core_app.alloc;
    var p = parked;
    for (p.left_out.items) |l| endLeftOut(gpa, l);
    p.left_out.deinit(gpa);
    p.before.deinit(gpa);
    if (p.stack) |*st| st.deinit(gpa);
}

/// A left-out pane's shell exited while it waited for the undo: let it go
/// now. True when `parked` held it.
pub fn paneGone(app: *App, parked: *Parked, pane: *PaneView) bool {
    for (parked.left_out.items, 0..) |l, i| {
        if (l.pane != pane) continue;
        var gone = l;
        gone.close = true;
        endLeftOut(app.core_app.alloc, gone);
        _ = parked.left_out.swapRemove(i);
        return true;
    }
    return false;
}
