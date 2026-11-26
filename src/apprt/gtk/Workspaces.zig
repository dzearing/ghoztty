//! Single-window mode on GTK, the foundation (T3648; Mac `WorkspaceHost`,
//! win32 T3181/T3191/T3192). Spec: docs/reference/window-modes.md.
//!
//! In `single` mode (latched at launch, T3573) the person sees ONE toplevel.
//! Every window the app opens is a WORKSPACE of it, and every workspace keeps
//! its own `Window` GObject - tabs, split trees, sidebar, config binding,
//! IPC name, title. Only the toplevel is shared:
//!
//! - The toplevel is the GtkWindow of the first workspace that loaded it
//!   (`toplevel`). It is the only workspace window ever mapped.
//! - A workspace's CONTENT is its template's root, the `Adw.TabOverview`
//!   (`Window.contentRoot`). On show it is the toplevel's content; parked,
//!   it is out of every window, held by the workspace's own reference
//!   (`Window.holdContent`). The template bindings inside it keep pointing at
//!   its own `Window`, so titles and config stay right with no rebinding.
//! - Every widget-to-window lookup (`ext.getAncestor(Window, ...)`) asks the
//!   content root which workspace it belongs to (`Window.workspace_qdata_key`)
//!   before the widget tree, so a pane in a workspace on show answers its own
//!   workspace, not the toplevel's (Mac `owner(of:)`).
//! - The workspace's `win` actions are inserted on its content root, so its
//!   menus, accelerators and the palette reach the workspace on show.
//! - Membership and every decision come from win32's pure
//!   `workspace_host.zig` `Host(*Window)`, so the policy is one function on
//!   both frontends and is unit-tested in every lane.
//! - Parked counts as hidden: a parked workspace's `Window.syncSeen` reads
//!   unseen and its content is unmapped, so its terminals build no frames.
//!
//! Switching (T3649): `Window.bringForward` is "go to this window" - the
//! sidebar's all-windows list, `--focus`, a pane's present request - and
//! `gotoTab` / `gotoWindow` walk the list's order; a new tab, a tab or pane
//! dragged out, and every new-window path open a workspace.
//!
//! Parked layout (T3650): a parked workspace is laid out by hand at the size
//! of the content on show - when it parks, 0.3s after the toplevel's resize
//! settles, and at once on a tree change - and its started terminals take the
//! new size at the shared window's pixel scale, so a switch never changes a
//! grid. A terminal made while parked starts on first show (T3786).
//!
//! Shade fade (T3651): the toplevel draws the desk of the workspace on show
//! (`deskOwner`), and a hand-off crossfades from the old workspace's
//! gradient to the new one's over 0.35s (`Window.beginDeskFade`).
//!
//! Closing (T3652): closing the workspace on show hands the window to the
//! one shown before it, a parked one closes in place, the last one's close
//! closes the window. The toplevel's close button closes the workspace on
//! show (`closeRequestTarget`), a confirmation puts a parked workspace on
//! show first and is presented inside the toplevel (`dialogParent`), and
//! when the toplevel's OWN workspace closes while others are open its
//! GtkWindow stays on as their frame (`retire`, `Window.becomeFrame`) -
//! GTK cannot move a GtkWindow between `Window` objects the way AppKit
//! moves an NSWindow between controllers, so the window that would
//! otherwise go is kept, emptied, and closed with the last workspace.
//! Undo of a workspace close waits on GTK window-close undo (T3665).
//!
//! Activity (T3654): state never pauses. The shared window's activity is the
//! most urgent of every workspace's (`refreshActivity`), a parked workspace
//! that starts waiting on a question marks the toplevel urgent
//! (`attentionWindow`), and the title suffix stays the workspace on show's.
//!
//! Not here (their own cards): the CLI (T3653), persistence (T3655).
const Workspaces = @This();

const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const wk = @import("webkit.zig");
const Application = @import("class/application.zig").Application;
const window_mode = @import("../win32/window_mode.zig");
const workspace_host = @import("../win32/workspace_host.zig");
const window_order = @import("../win32/pane_sidebar_window_order.zig");
const PaneSidebar = @import("PaneSidebar.zig");

const log = std.log.scoped(.gtk_workspaces);

pub const Host = workspace_host.Host(*Window);

/// Every workspace and who is on show. One per app.
var host: Host = .{};

/// The GtkWindow the person sees: the workspace that loaded it. Null before
/// the first single-mode window and after the last one closed.
var toplevel: ?*Window = null;

/// Whether `win` is (or would be) a workspace: single mode, and never the
/// quick terminal.
pub fn applies(win: *Window) bool {
    return window_mode.current() == .single and !win.isQuickTerminal();
}

pub fn manages(win: *Window) bool {
    return host.manages(win);
}

pub fn isParked(win: *Window) bool {
    return host.isParked(win);
}

pub fn active() ?*Window {
    return host.active;
}

pub fn physical() ?*Window {
    return toplevel;
}

/// Every workspace, the one on show first, then most recently shown first.
pub fn order() []const *Window {
    return host.order.items;
}

/// The window whose map state and toplevel bits decide whether `win` can
/// be seen: the toplevel for the workspace on show, null for a parked one
/// (parked counts as hidden), and `win` itself when it is no workspace.
pub fn seenThrough(win: *Window) ?*Window {
    if (!host.manages(win)) return win;
    if (host.isParked(win)) return null;
    return toplevel orelse win;
}

/// The toplevel's map or toplevel state changed: the workspace on show is
/// seen (or not) through it.
pub fn toplevelSeenChanged(win: *Window) void {
    if (toplevel != win) return;
    const a = host.active orelse return;
    if (a != win) a.syncSeen();
}

/// A new window's first presentation (`Application.initAndShowWindow`).
/// True when this module presented it (or parked it) and the caller must not;
/// false when the caller presents it as an ordinary window (separate mode,
/// the quick terminal, or the workspace that loads the toplevel).
pub fn present(win: *Window, activate: bool) bool {
    if (!applies(win)) return false;
    if (host.manages(win)) return false;
    watchRemovals();
    const alloc = Application.default().allocator();
    const parked = host.startsParked();
    host.admit(alloc, win, parked) catch |err| {
        log.warn("workspace: could not admit window={s} err={}; it opens as a window", .{ name(win), err });
        return false;
    };
    win.adoptWinActionsOnContent();
    defer refreshActivity();

    if (!parked) {
        load(win);
        log.info("workspace: window={s} loads the shared window", .{name(win)});
        return false;
    }

    // Out of its own GtkWindow, held by its own reference: it never maps.
    win.holdContent();
    switch (host.present(win, activate)) {
        .not_managed => unreachable,
        .show => {
            log.info("workspace: window={s} opened on show", .{name(win)});
            _ = show(win, activate);
        },
        .stay_parked => {
            log.info("workspace: window={s} opened parked", .{name(win)});
            win.syncSeen();
            layoutParked(win, "birth");
        },
        .promote_background, .own_window_background => {
            // Nothing has the window: this one loads it, in the background.
            win.releaseContent();
            load(win);
            log.info("workspace: window={s} loads the shared window (none had it)", .{name(win)});
            return false;
        },
    }
    return true;
}

var watching = false;

/// A destroyed GtkWindow is released by its application, and that is the
/// moment a workspace leaves the host (`Window.leaveWorkspace`): dispose
/// may never come while its content root's `win` group still references
/// it, and GTK clears the window's `application` without a notify.
fn watchRemovals() void {
    if (watching) return;
    watching = true;
    _ = wk.g_signal_connect_data(
        @ptrCast(Application.default()),
        "window-removed",
        @ptrCast(&windowRemoved),
        null,
        null,
        0,
    );
}

fn windowRemoved(_: *gtk.Application, w: *gtk.Window, _: ?*anyopaque) callconv(.c) void {
    const win = gobject.ext.cast(Window, w) orelse return;
    win.leaveWorkspace();
}

/// `win` is the workspace whose own GtkWindow is the toplevel.
fn load(win: *Window) void {
    toplevel = win;
    host.didLoadWindow(win);
}

/// Put `win` on show (Mac `WorkspaceHost.show`): the workspace on show
/// surrenders the toplevel's content, `win` adopts it. No widget is rebuilt
/// and no process touched. `raise` presents the toplevel afterwards. False
/// when `win` is not a workspace or nothing could take it.
pub fn show(win: *Window, raise: bool) bool {
    const sw = host.show(win);
    switch (sw) {
        .refused => return false,
        .already => {
            if (raise) if (toplevel) |t| t.as(gtk.Window).present();
            return true;
        },
        .own_window => {
            win.releaseContent();
            load(win);
            if (raise) win.as(gtk.Window).present() else win.as(gtk.Widget).setVisible(1);
            return true;
        },
        .load_first => |l| {
            l.releaseContent();
            load(l);
            l.as(gtk.Widget).setVisible(1);
            return show(win, raise);
        },
        .hand_off => |h| {
            handOff(h.from, h.to);
            if (raise) if (toplevel) |t| t.as(gtk.Window).present();
            return true;
        },
    }
}

fn handOff(from: *Window, to: *Window) void {
    const t = toplevel orelse return;
    // Surrender: `from`'s content comes out of the toplevel, kept whole by
    // its own reference.
    if (from == t) from.holdContent() else from.holdContentFrom(t);
    // Adopt: `to`'s content becomes the toplevel's.
    if (to == t) to.releaseContent() else to.releaseContentInto(t);
    // The title lands at once, never held back (Mac adoptWindow).
    if (to.currentTitle()) |title| t.as(gtk.Window).setTitle(title);
    // The shade fades from `from`'s gradient to `to`'s (T3651; Mac
    // `deskEntrance`, 0.35s; nothing fades in the flat style).
    t.beginDeskFade(from.deskVariant(), to.deskVariant());
    from.syncSeen();
    to.syncSeen();
    // Focus goes back where it was in `to` (Mac adoptWindow): the focused
    // pane of `from` left the window with its content, so nothing would
    // have it otherwise.
    if (to.getActiveSurface()) |s| s.grabFocus();
    t.queueSidebarRefresh();
    to.queueSidebarRefresh();
    log.info("workspace: show window={s} (from {s})", .{ name(to), name(from) });
}

// ---- Parked layout (T3650) ---------------------------------------------

/// A pending settled-resize pass over every parked workspace.
var resize_timer: ?c_uint = null;
/// Parked workspaces whose tree changed, laid out on the next low idle.
var tree_idle: ?c_uint = null;

/// Lay `win`'s parked content out at the shared window's size (T3650; Mac
/// `prepareParkedContent` / `layoutParkedContent`, win32 T3193): no window
/// lays it out, so the content root is measured and allocated by hand at
/// the size of the content on show, and every started terminal in it takes
/// its new size at the shared window's pixel scale (Mac
/// `SurfaceView.backingSize`). So a switch never changes a parked grid, and
/// the shell saw a resize while it was parked. No-op unless parked.
pub fn layoutParked(win: *Window, why: []const u8) void {
    if (!host.isParked(win) or !win.isContentHeld()) return;
    const a = host.active orelse return;
    if (a == win) return;
    const live = a.contentRoot().as(gtk.Widget);
    const w = live.getWidth();
    const h = live.getHeight();
    if (w <= 0 or h <= 0) return;
    const scale: f64 = scale: {
        if (a.getActiveSurface()) |s| if (s.pixelScale()) |v| break :scale v;
        break :scale @floatFromInt(@max(live.getScaleFactor(), 1));
    };

    const root = win.contentRoot();
    var min: c_int = 0;
    var nat: c_int = 0;
    root.measure(.horizontal, -1, &min, &nat, null, null);
    root.measure(.vertical, w, &min, &nat, null, null);
    root.allocate(w, h, -1, null);

    var panes: usize = 0;
    var resized: usize = 0;
    const tab_view = win.getTabView();
    const n: usize = @intCast(@max(tab_view.getNPages(), 0));
    for (0..n) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
        const tree = tab.getSurfaceTree() orelse continue;
        var it = tree.iterator();
        while (it.next()) |entry| {
            panes += 1;
            if (entry.view.layoutParked(scale)) resized += 1;
        }
    }
    log.info("workspace: parked window={s} laid out at {d}x{d} scale={d:.2} why={s} panes={d} resized={d}", .{
        name(win), w, h, scale, why, panes, resized,
    });
}

/// Every parked workspace, at the shared window's size.
fn layoutAllParked(why: []const u8) void {
    var buf: [64]*Window = undefined;
    for (host.parkedInto(&buf)) |w| layoutParked(w, why);
}

/// The toplevel's surface changed size (`Window.propGdkSurfaceDims`):
/// once the resize has settled (Mac `windowDidResize`, 0.3s) every parked
/// workspace is laid out at the new size, so each is ready when shown.
pub fn toplevelResized(win: *Window) void {
    if (toplevel != win) return;
    if (resize_timer) |t| _ = glib.Source.remove(t);
    resize_timer = glib.timeoutAdd(workspace_host.resize_settle_ms, resizeSettled, null);
}

fn resizeSettled(_: ?*anyopaque) callconv(.c) c_int {
    resize_timer = null;
    layoutAllParked("resize");
    return 0;
}

/// A tab's split tree changed in `win` (`Window.tabSplitTreeChanged`): a
/// parked workspace's content is laid out at once (Mac
/// `layoutParkedContent`) - no window will - after the split tree's own
/// widget rebuild, which runs on a default idle.
pub fn treeChanged(win: *Window) void {
    if (!host.isParked(win)) return;
    if (tree_idle != null) return;
    tree_idle = glib.idleAddFull(glib.PRIORITY_LOW, treeSettled, null, null);
}

fn treeSettled(_: ?*anyopaque) callconv(.c) c_int {
    tree_idle = null;
    layoutAllParked("tree");
    return 0;
}

/// The workspace whose gradient `win` draws as its desk (T3651): the
/// toplevel draws the desk of the workspace on show in it; every other
/// window its own.
pub fn deskOwner(win: *Window) *Window {
    if (toplevel == win) if (host.active) |a| return a;
    return win;
}

/// The workspace a controller on `win`'s own GtkWindow acts for: in single
/// mode the toplevel's controllers see keys for the workspace on show in it
/// (T3649), not for the toplevel's own workspace.
pub fn keyTarget(win: *Window) *Window {
    if (toplevel == win) if (host.active) |a| return a;
    return win;
}

/// `goto_tab` in single mode (T3649; Mac `onGotoTab` over `sidebarOrder`,
/// win32 `gotoWorkspaceTab`): there are no tabs - a new tab is a new
/// workspace - so previous/next/last/N walk the windows of the pane
/// sidebar's all-windows list, and going to one puts its workspace on show.
/// `raw` is `apprt.action.GotoTab`'s value. False when `win` is no workspace
/// (the caller selects a tab as before) or there is nowhere else to go.
pub fn gotoTab(win: *Window, raw: c_int) bool {
    if (!applies(win) or !host.manages(win)) return false;
    var arena_state = std.heap.ArenaAllocator.init(Application.default().allocator());
    defer arena_state.deinit();
    const list = PaneSidebar.listOrder(arena_state.allocator()) catch return false;
    const at = indexOf(list, win);
    const to = window_order.gotoTab(list.len, at, raw) orelse {
        log.info("goto_tab {d} over workspaces: nowhere else to go ({d} listed)", .{ raw, list.len });
        return false;
    };
    log.info("goto_tab {d} over workspaces: {d} -> {d} of {d} window={s}", .{ raw, at orelse list.len, to, list.len, name(list[to].win) });
    goTo(list[to]);
    return true;
}

/// `goto_window` in single mode (T3649; Mac `gotoWindow` over
/// `sidebarOrder`): one along the all-windows list, wrapping. False when
/// single mode is not in force (the caller walks the toplevels as before).
pub fn gotoWindow(next: bool) bool {
    if (window_mode.current() != .single) return false;
    const a = host.active orelse return false;
    var arena_state = std.heap.ArenaAllocator.init(Application.default().allocator());
    defer arena_state.deinit();
    const list = PaneSidebar.listOrder(arena_state.allocator()) catch return false;
    const at = indexOf(list, a);
    const to = window_order.stepped(list.len, at, if (next) .next else .previous) orelse {
        log.info("goto_window over workspaces: nowhere else to go ({d} listed)", .{list.len});
        return false;
    };
    log.info("goto_window {s} over workspaces: {d} -> {d} of {d} window={s}", .{ if (next) "next" else "previous", at orelse list.len, to, list.len, name(list[to].win) });
    goTo(list[to]);
    return true;
}

/// The list entry of the workspace on show's selected tab, else its first.
fn indexOf(list: []const PaneSidebar.FoundTab, win: *Window) ?usize {
    const sel = win.getSelectedTab();
    var first: ?usize = null;
    for (list, 0..) |f, i| {
        if (f.win != win) continue;
        if (sel) |s| if (s == f.tab) return i;
        if (first == null) first = i;
    }
    return first;
}

fn goTo(f: PaneSidebar.FoundTab) void {
    const tv = f.win.getTabView();
    tv.setSelectedPage(tv.getPage(f.tab.as(gtk.Widget)));
    f.win.bringForward();
}

/// A new tab in single mode is a new workspace (T3649; Mac
/// `TerminalController.newTab`): opened exactly as Ctrl+Shift+N opens one
/// from `parent`, on show. False when `win` is no workspace: the caller
/// opens a tab as before.
pub fn newTabIsWindow(win: *Window, parent: anytype) bool {
    if (!applies(win)) return false;
    log.info("new_tab in single-window mode opens a workspace (from window={s})", .{name(win)});
    _ = Application.default().newWindowFromSidebar(parent, null);
    return true;
}

// ---- Closing (T3652) -----------------------------------------------------

/// The workspace a close request on `win`'s own GtkWindow is for (T3652):
/// the shared toplevel's close button and the compositor's close act on the
/// workspace ON SHOW in it (Mac: the red button is the window controller's,
/// and the window controller is the workspace on show's). Null when the
/// request is `win`'s own.
pub fn closeRequestTarget(win: *Window) ?*Window {
    if (toplevel != win) return null;
    const a = host.active orelse return null;
    if (a == win) return null;
    return a;
}

/// The widget a workspace's dialog is presented over: inside the shared
/// toplevel while it is on show there (an `Adw.Dialog` lands in its
/// widget's root), else its own window.
pub fn dialogParent(win: *Window) *gtk.Widget {
    if (host.manages(win) and !host.isParked(win)) if (toplevel) |t| if (t != win)
        return win.contentRoot();
    return win.as(gtk.Widget);
}

/// The window a workspace's open dialog is up over: the shared toplevel
/// for the workspace on show, none for a parked one or a frame (the
/// toplevel's own window holds the dialog of whichever workspace is on
/// show, which is not theirs). `win` itself when it is no workspace.
pub fn dialogHost(win: *Window) ?*Window {
    if (win.isFrame()) return null;
    if (!host.manages(win)) return win;
    if (host.isParked(win)) return null;
    return toplevel orelse win;
}

/// `win` is closing for good (`Window.closeNow`). When it is the shared
/// toplevel's own workspace and others are open, close the WORKSPACE and keep
/// its GtkWindow as their frame (Mac: the NSWindow outlives the controller
/// that loaded it; win32 T3184 hands the same HWND on). On show, it first
/// hands the window to the workspace shown before it. True when it was
/// retired, so the caller must not destroy the window.
pub fn retire(win: *Window) bool {
    if (toplevel != win or !host.manages(win) or win.isFrame()) return false;
    if (host.count() < 2) return false;
    if (Application.default().isQuitting()) return false;
    // It leaves the host here, not in `forget` (T3654).
    defer refreshActivity();
    switch (host.close(win)) {
        .hand_to => |next| {
            win.holdContent();
            adopt(win, win, next);
            log.info("workspace: close window={s} hands the shared window to {s}", .{ name(win), name(next) });
        },
        .in_place => log.info("workspace: close parked window={s} (the shared window's own) in place", .{name(win)}),
        .close_window, .not_managed => return false,
    }
    win.becomeFrame();
    return true;
}

/// `to` adopts the toplevel `t` after `from` left it (a close hand-off):
/// content, title, shade fade, seen, focus, sidebar - as `handOff` does.
fn adopt(t: *Window, from: *Window, to: *Window) void {
    if (to == t) to.releaseContent() else to.releaseContentInto(t);
    if (to.currentTitle()) |title| t.as(gtk.Window).setTitle(title);
    t.beginDeskFade(from.deskVariant(), to.deskVariant());
    to.syncSeen();
    if (to.getActiveSurface()) |s| s.grabFocus();
    t.queueSidebarRefresh();
    to.queueSidebarRefresh();
}

/// No workspace is left: the frame goes too, on the next idle - never from
/// inside the disposing workspace's own teardown.
fn dropFrameIfEmpty() void {
    if (host.count() != 0) return;
    const t = toplevel orelse return;
    if (!t.isFrame()) return;
    toplevel = null;
    _ = t.as(gobject.Object).ref();
    _ = glib.idleAdd(destroyFrame, t);
    log.info("workspace: the last workspace closed; the shared window closes", .{});
}

fn destroyFrame(data: ?*anyopaque) callconv(.c) c_int {
    const t: *Window = @ptrCast(@alignCast(data orelse return 0));
    t.as(gtk.Window).destroy();
    t.as(gobject.Object).unref();
    return 0;
}

/// `win` is being disposed. Its content must never go down with a toplevel
/// it was borrowing, nor take another workspace's content down with its own
/// toplevel. A close of the workspace on show hands the window to the one
/// shown before it (T3652); the last one's close takes the frame with it.
pub fn forget(win: *Window) void {
    if (!host.manages(win)) return;
    defer dropFrameIfEmpty();
    // Its activity leaves the roll-up with it (T3654).
    defer refreshActivity();
    const quitting = Application.default().isQuitting();
    const t = toplevel;
    const was_active = if (host.active) |a| a == win else false;

    if (t == win) {
        // The toplevel goes. The workspace on show (if another) takes its
        // content back into its own GtkWindow and loads a window of its own.
        if (host.active) |a| if (a != win) a.holdContentFrom(win);
        win.releaseContent();
        closeInHost(win);
        toplevel = null;
        if (host.active) |a| {
            a.releaseContent();
            load(a);
            if (!quitting) a.as(gtk.Widget).setVisible(1);
            a.syncSeen();
            log.info("workspace: the shared window closed; window={s} loads its own", .{name(a)});
        } else if (host.order.items.len > 0 and !quitting) {
            const next = host.order.items[0];
            _ = show(next, false);
        }
        return;
    }

    if (was_active) {
        // Borrowing the toplevel: give it back its own content first.
        if (t) |tw| win.holdContentFrom(tw);
        win.releaseContent();
        switch (host.close(win)) {
            .hand_to => |next| if (t) |tw| {
                if (!quitting) {
                    adopt(tw, win, next);
                    log.info("workspace: close window={s} hands the shared window to {s}", .{ name(win), name(next) });
                } else if (next == tw) next.releaseContent() else next.releaseContentInto(tw);
            },
            .close_window => _ = host.windowDidClose(win, true),
            .in_place, .not_managed => {},
        }
        return;
    }

    // Parked: it closes in place.
    win.releaseContent();
    closeInHost(win);
}

/// Drop `win` from the host whatever it held: the last workspace's
/// `close_window` drops it through `windowDidClose`.
fn closeInHost(win: *Window) void {
    switch (host.close(win)) {
        .close_window => _ = host.windowDidClose(win, true),
        .hand_to, .in_place, .not_managed => {},
    }
}

// ---- Rolled-up activity (T3654) ------------------------------------------

/// The shared window's activity: the most urgent of EVERY workspace's, parked
/// ones included (Mac `WorkspaceHost.refreshWindowActivity`, the window's
/// `AXWindowActivityState`; win32 T3186). The title suffix stays the
/// workspace on show's own (`Window.syncTitle`).
var rolled: workspace_host.Activity = .idle;

pub fn activity() workspace_host.Activity {
    return rolled;
}

/// Recompute the roll-up: on every activity change of a workspace, parked or
/// not, and whenever a workspace comes or goes. Logs a move, the oracle for
/// window-workspace-activity.sh.
pub fn refreshActivity() void {
    const now = host.rolledUpActivity({}, workspaceActivity);
    if (now == rolled) return;
    rolled = now;
    log.info("window activity rolled up state={s} workspaces={d}", .{ @tagName(now), host.count() });
}

fn workspaceActivity(_: void, w: *Window) workspace_host.Activity {
    return switch (w.activityAggregate()) {
        .idle => .idle,
        .busy => .busy,
        .needs_input => .needs_input,
    };
}

/// The GtkWindow an attention request from `win` marks urgent: its own, or -
/// for any workspace - the shared toplevel, the only one the person can see
/// (Mac: a parked workspace's `requestUserAttention` is the app's; win32
/// `attentionHwnd`). Null when no workspace has the window yet.
pub fn attentionWindow(win: *Window) ?*Window {
    if (!host.manages(win)) return win;
    return toplevel;
}

/// The window's workspace name for logs.
fn name(win: *Window) []const u8 {
    return win.ipcName() orelse "?";
}

/// Debug seam (`workspaces`): reset between harness runs is never needed -
/// a process holds one host - but tests read it through these.
pub fn snapshot() struct { active: ?*Window, toplevel: ?*Window, order: []const *Window } {
    return .{ .active = host.active, .toplevel = toplevel, .order = host.order.items };
}

comptime {
    _ = adw;
    _ = gio;
    _ = gobject;
}
