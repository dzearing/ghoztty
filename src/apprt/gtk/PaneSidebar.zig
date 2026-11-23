//! The pane sidebar on GTK (T3557, Linux L10b; docs/reference/pane-sidebar.md).
//!
//! A column at the window's leading edge that lists every pane of the
//! window's active tab - the Mac's per-window list (a Mac window is a tab
//! here, as on win32) - in tree order, the focused pane selected. A row names
//! its pane by its banner's title, else its title, with the working directory
//! under it (`pane_sidebar_rows.text`); clicking a row focuses that pane.
//!
//! Two modes, switched by ONE button at the top of the card: the full panel
//! (rows with their text) and the narrow rail (each row its icon alone, the
//! name in a tooltip), so the icons sit where they were. A window narrower
//! than the panel's breakpoint (720) shows the rail whatever the flag says,
//! and its button is off. `toggle_pane_sidebar` (Ctrl+Shift+S, Windows'
//! carry of the Mac's Ctrl+Cmd+S) hides and shows the whole column.
//!
//! The flags are ONE state shared by every window (Mac
//! `PaneSidebarSharedState`): a toggle in one window changes all of them. They
//! persist across launches in a small file under the config root, and
//! `macos-pane-sidebar` forces how they start (`remember` | `expanded` |
//! `collapsed` | `hidden`) without writing over the user's own choice - the
//! rules are win32's pure `pane_sidebar_prefs.StartState`.
//!
//! Parity is behavior and information, not pixels (docs/design/linux-port.md):
//! stock libadwaita widgets, no glide. Every window redraws for a shared
//! change at once rather than when it is next key - a GTK window lists a few
//! panes, and there is no per-frame cost to defer. Not here yet: the stash
//! tray, all windows, drag to reorder, hover tint and the busy sheen (T3558).
//!
//! GTK main thread only.
const PaneSidebar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const homedir = @import("../../os/homedir.zig");
const wk = @import("webkit.zig");
const rows = @import("pane_sidebar_rows.zig");
const Window = @import("class/window.zig").Window;
const Surface = @import("class/surface.zig").Surface;

const log = std.log.scoped(.gtk_pane_sidebar);

const orientation_horizontal: c_int = 0;
const orientation_vertical: c_int = 1;
const pango_ellipsize_end: c_int = 3;
const align_start: c_int = 1;
const align_center: c_int = 3;
const policy_never: c_int = 2;
const policy_automatic: c_int = 1;

// ---------------------------------------------------------------------------
// The state every window shares

/// What every window's sidebar draws: the expanded and hidden flags and the
/// panel width.
pub var shared: rows.Prefs = .{};
/// `macos-pane-sidebar` against the user's own flags: what the file keeps.
var start_state: rows.StartState = .{};
var loaded = false;

fn prefsPath(alloc: Allocator) ?[]u8 {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (homedir.home(&home_buf) catch null) orelse return null;
    return rows.prefsPath(alloc, build_config.is_debug, std.posix.getenv("XDG_CONFIG_HOME"), home) catch null;
}

/// Read the persisted flags once per process and start them as
/// `macos-pane-sidebar` says. Called before the first window draws its
/// sidebar, so a restored window starts as configured too.
pub fn loadShared(alloc: Allocator, start: configpkg.Config.MacPaneSidebar) void {
    if (loaded) return;
    if (prefsPath(alloc)) |p| {
        defer alloc.free(p);
        if (rows.load(p)) |prefs| shared = prefs;
    }
    start_state = .init(shared);
    loaded = true;
    _ = applyStart(start);
}

/// Start the sidebar as `macos-pane-sidebar` says: at launch, and on a config
/// change only when the value changed, so a reload never undoes the user's
/// toggles. True when the flags moved; every window then redraws.
pub fn applyStart(start: configpkg.Config.MacPaneSidebar) bool {
    if (!loaded) return false;
    const s = std.meta.stringToEnum(rows.Start, @tagName(start)) orelse .remember;
    const moved = start_state.apply(&shared, s);
    log.info("pane sidebar start={s} moved={} expanded={} hidden={}", .{ @tagName(s), moved, shared.expanded, shared.hidden });
    return moved;
}

/// The user set the flags (the button, the toggle shortcut): theirs, so they
/// are kept and written. Every mode change is logged with its cause - the
/// sidebar must never change mode on its own (pane-sidebar.md).
pub fn userSetFlags(alloc: Allocator, expanded: bool, hidden: bool, cause: []const u8) void {
    start_state.userSet(&shared, expanded, hidden);
    log.info("pane sidebar flags expanded={} hidden={} cause={s}", .{ expanded, hidden, cause });
    if (prefsPath(alloc)) |p| {
        defer alloc.free(p);
        rows.save(p, start_state.toSave(shared));
    }
}

// ---------------------------------------------------------------------------
// One window's sidebar

/// One drawn row: what the seam reports, and what a click focuses.
pub const Row = struct {
    sidebar: *PaneSidebar,
    button: *wk.GtkWidget,
    pane_id: []u8,
    label: [:0]u8,
    subtitle: ?[:0]u8,
    tooltip: ?[:0]u8,
    selected: bool,
    viewer: bool,
};

alloc: Allocator,
window: *Window,
/// The card: a vertical box in the window's content row, before the tabs.
/// Owned by the widget tree.
card: *wk.GtkWidget,
toggle: *wk.GtkWidget,
title: *wk.GtkWidget,
list: *wk.GtkWidget,
drawn: std.ArrayListUnmanaged(*Row) = .empty,
mode: rows.Mode = .mini,
window_width: i32 = 0,
idle: c_uint = 0,

pub fn create(alloc: Allocator, window: *Window) Allocator.Error!*PaneSidebar {
    const self = try alloc.create(PaneSidebar);
    errdefer alloc.destroy(self);

    const card = wk.gtk_box_new(orientation_vertical, 2);
    wk.gtk_widget_add_css_class(card, "pane-sidebar");
    wk.gtk_widget_set_vexpand(card, 1);
    wk.gtk_widget_set_hexpand(card, 0);
    wk.gtk_widget_set_margin_start(card, rows.card_margin);
    wk.gtk_widget_set_margin_end(card, 0);
    wk.gtk_widget_set_margin_top(card, rows.card_margin);
    wk.gtk_widget_set_margin_bottom(card, rows.card_margin);
    wk.gtk_widget_set_focusable(card, 0);

    // The header: the mode button first, centred on the rail's width so it
    // does not move when toggled, then (expanded) the window's name.
    const header = wk.gtk_box_new(orientation_horizontal, 4);
    wk.gtk_widget_add_css_class(header, "pane-sidebar-header");
    const toggle = wk.gtk_button_new_from_icon_name("sidebar-show-symbolic");
    wk.gtk_widget_add_css_class(toggle, "flat");
    wk.gtk_widget_set_focus_on_click(toggle, 0);
    wk.gtk_widget_set_focusable(toggle, 0);
    wk.gtk_widget_set_size_request(toggle, rows.railCardWidth(), -1);
    _ = wk.g_signal_connect_data(toggle, "clicked", @ptrCast(&onToggleClicked), self, null, 0);
    wk.gtk_box_append(header, toggle);
    const title = wk.gtk_label_new("");
    wk.gtk_widget_add_css_class(title, "heading");
    wk.gtk_label_set_xalign(title, 0);
    wk.gtk_label_set_ellipsize(title, pango_ellipsize_end);
    wk.gtk_widget_set_hexpand(title, 1);
    wk.gtk_box_append(header, title);
    wk.gtk_box_append(card, header);

    const scroller = wk.gtk_scrolled_window_new();
    wk.gtk_scrolled_window_set_policy(scroller, policy_never, policy_automatic);
    wk.gtk_widget_set_vexpand(scroller, 1);
    const list = wk.gtk_box_new(orientation_vertical, 4);
    wk.gtk_widget_add_css_class(list, "pane-sidebar-list");
    wk.gtk_scrolled_window_set_child(scroller, list);
    wk.gtk_box_append(card, scroller);

    self.* = .{
        .alloc = alloc,
        .window = window,
        .card = card,
        .toggle = toggle,
        .title = title,
        .list = list,
    };
    return self;
}

/// Free the struct. The card belongs to the widget tree and goes with it.
pub fn destroy(self: *PaneSidebar) void {
    if (self.idle != 0) _ = wk.g_source_remove(self.idle);
    self.idle = 0;
    self.clearRows();
    self.drawn.deinit(self.alloc);
    self.alloc.destroy(self);
}

/// Redraw on the next idle turn: a tab switch, a split, a focus change and
/// a title change often come together, and one redraw covers them.
pub fn queueRefresh(self: *PaneSidebar) void {
    if (self.idle != 0) return;
    self.idle = wk.g_idle_add(@ptrCast(&onIdle), self);
}

fn onIdle(self: *PaneSidebar) callconv(.c) c_int {
    self.idle = 0;
    self.refresh();
    return 0; // G_SOURCE_REMOVE
}

/// The window's width in logical pixels, or 0 before it is laid out.
fn currentWindowWidth(self: *PaneSidebar) i32 {
    const w: *wk.GtkWidget = @ptrCast(self.window);
    const allocated = wk.gtk_widget_get_width(w);
    if (allocated > 0) return allocated;
    var dw: c_int = 0;
    var dh: c_int = 0;
    self.window.as(gtk.Window).getDefaultSize(&dw, &dh);
    return dw;
}

fn clearRows(self: *PaneSidebar) void {
    for (self.drawn.items) |r| {
        wk.gtk_box_remove(self.list, r.button);
        self.alloc.free(r.pane_id);
        self.alloc.free(r.label);
        if (r.subtitle) |s| self.alloc.free(s);
        if (r.tooltip) |t| self.alloc.free(t);
        self.alloc.destroy(r);
    }
    self.drawn.clearRetainingCapacity();
}

/// Draw the sidebar as the shared flags, the window's width and its active
/// tab's panes now are.
pub fn refresh(self: *PaneSidebar) void {
    const ww = self.currentWindowWidth();
    self.window_width = ww;
    const m = rows.mode(shared, ww);
    if (m != self.mode) log.info("pane sidebar mode {s} -> {s} window_width={d}", .{ @tagName(self.mode), @tagName(m), ww });
    self.mode = m;

    wk.gtk_widget_set_visible(self.card, @intFromBool(m != .hidden));
    wk.gtk_widget_set_size_request(self.card, rows.cardWidth(m, shared), -1);
    const expanded = m == .expanded;
    wk.gtk_widget_set_visible(self.title, @intFromBool(expanded));
    wk.gtk_widget_set_sensitive(self.toggle, @intFromBool(rows.canExpand(ww)));
    wk.gtk_widget_set_tooltip_text(self.toggle, if (expanded) "Collapse Sidebar" else "Expand Sidebar");
    const wtitle = self.window.as(gtk.Window).getTitle();
    wk.gtk_label_set_text(self.title, if (wtitle) |t| t else "");

    self.clearRows();
    if (m == .hidden) {
        self.dump();
        return;
    }

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = homedir.home(&home_buf) catch null;

    const tab = self.window.getSelectedTab() orelse {
        self.dump();
        return;
    };
    const active = tab.getActiveSurface();
    const tree = tab.getSurfaceTree() orelse {
        self.dump();
        return;
    };
    if (tree.nodes.len > 0) self.addTree(tree, .root, active, expanded, home) catch |err| {
        log.warn("pane sidebar row failed err={}", .{err});
    };
    self.dump();
}

/// The rows of a subtree in reading order: a split's left (or top) side
/// first - the order `+list` walks, and the Mac's tree order. The node array
/// itself is in no spatial order.
fn addTree(self: *PaneSidebar, tree: *const Surface.Tree, h: Surface.Tree.Node.Handle, active: ?*Surface, expanded: bool, home: ?[]const u8) Allocator.Error!void {
    switch (tree.nodes[h.idx()]) {
        .leaf => |v| try self.addRow(v, v == active, expanded, home),
        .split => |s| {
            try self.addTree(tree, s.left, active, expanded, home);
            try self.addTree(tree, s.right, active, expanded, home);
        },
    }
}

fn addRow(self: *PaneSidebar, surface: *Surface, selected: bool, expanded: bool, home: ?[]const u8) Allocator.Error!void {
    var lb: [rows.TEXT_BUF_LEN]u8 = undefined;
    var sb: [rows.TEXT_BUF_LEN]u8 = undefined;
    const viewer = surface.isViewer();
    const t = rows.text(.{
        .title = if (surface.getTitle()) |s| s else null,
        .title_override = surface.titleOverride(),
        .pwd = if (surface.getPwd()) |s| s else null,
        .banner = surface.getPaneBanner(),
        .viewer = viewer,
    }, home, &lb, &sb);

    const r = try self.alloc.create(Row);
    errdefer self.alloc.destroy(r);
    const pane_id = try self.alloc.dupe(u8, surface.paneId());
    errdefer self.alloc.free(pane_id);
    const label = try self.alloc.dupeZ(u8, t.label);
    errdefer self.alloc.free(label);
    const subtitle: ?[:0]u8 = if (t.subtitle) |s| try self.alloc.dupeZ(u8, s) else null;
    errdefer if (subtitle) |s| self.alloc.free(s);
    // The rail shows no text, so its tile names the pane in a tooltip.
    const tooltip: ?[:0]u8 = if (expanded)
        null
    else if (subtitle) |s|
        try std.fmt.allocPrintSentinel(self.alloc, "{s}\n{s}", .{ label, s }, 0)
    else
        try self.alloc.dupeZ(u8, label);

    const button = wk.gtk_button_new();
    wk.gtk_widget_add_css_class(button, "flat");
    wk.gtk_widget_add_css_class(button, "pane-sidebar-row");
    if (selected) wk.gtk_widget_add_css_class(button, "pane-sidebar-selected");
    wk.gtk_widget_set_focus_on_click(button, 0);
    wk.gtk_widget_set_focusable(button, 0);
    if (tooltip) |tt| wk.gtk_widget_set_tooltip_text(button, tt);

    const content = wk.gtk_box_new(orientation_horizontal, 8);
    const icon = wk.gtk_image_new_from_icon_name(if (viewer) "text-x-generic-symbolic" else "utilities-terminal-symbolic");
    wk.gtk_widget_set_valign(icon, align_center);
    wk.gtk_box_append(content, icon);
    if (expanded) {
        const text_box = wk.gtk_box_new(orientation_vertical, 0);
        wk.gtk_widget_set_hexpand(text_box, 1);
        const l1 = wk.gtk_label_new(label);
        wk.gtk_label_set_xalign(l1, 0);
        wk.gtk_label_set_ellipsize(l1, pango_ellipsize_end);
        wk.gtk_box_append(text_box, l1);
        if (subtitle) |s| {
            const l2 = wk.gtk_label_new(s);
            wk.gtk_label_set_xalign(l2, 0);
            wk.gtk_label_set_ellipsize(l2, pango_ellipsize_end);
            wk.gtk_widget_add_css_class(l2, "dim-label");
            wk.gtk_widget_add_css_class(l2, "caption");
            wk.gtk_box_append(text_box, l2);
        }
        wk.gtk_box_append(content, text_box);
    } else {
        wk.gtk_widget_set_halign(content, align_center);
    }
    wk.gtk_button_set_child(button, content);

    r.* = .{
        .sidebar = self,
        .button = button,
        .pane_id = pane_id,
        .label = label,
        .subtitle = subtitle,
        .tooltip = tooltip,
        .selected = selected,
        .viewer = viewer,
    };
    _ = wk.g_signal_connect_data(button, "clicked", @ptrCast(&onRowClicked), r, null, 0);
    try self.drawn.append(self.alloc, r);
    wk.gtk_box_append(self.list, button);
}

fn onRowClicked(_: *wk.GtkWidget, r: *Row) callconv(.c) void {
    _ = r.sidebar.focusPane(r.pane_id);
}

/// Focus the pane with this id in the window's active tab (a row's click).
/// False when the tab no longer holds it.
pub fn focusPane(self: *PaneSidebar, pane_id: []const u8) bool {
    const tab = self.window.getSelectedTab() orelse return false;
    const tree = tab.getSurfaceTree() orelse return false;
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.view.paneId(), pane_id)) continue;
        log.info("pane sidebar row clicked pane={s}", .{pane_id});
        tab.getSplitTree().focusSurface(entry.view);
        return true;
    }
    return false;
}

fn onToggleClicked(_: *wk.GtkWidget, self: *PaneSidebar) callconv(.c) void {
    self.toggleExpanded("button");
}

/// The header's button: expand or collapse every window's sidebar. Off in a
/// window too narrow for the panel.
pub fn toggleExpanded(self: *PaneSidebar, cause: []const u8) void {
    if (!rows.canExpand(self.currentWindowWidth())) return;
    userSetFlags(self.alloc, !shared.expanded, shared.hidden, cause);
    Window.refreshAllSidebars();
}

/// `toggle_pane_sidebar`: hide or show the sidebar in every window.
pub fn toggleHidden(alloc: Allocator, cause: []const u8) void {
    userSetFlags(alloc, shared.expanded, !shared.hidden, cause);
    Window.refreshAllSidebars();
}

/// What this sidebar shows, for the debug seam. Strings are borrowed from
/// the drawn rows until the next refresh.
pub fn report(self: *PaneSidebar, arena: Allocator) Allocator.Error!rows.Report {
    const out = try arena.alloc(rows.Report.Row, self.drawn.items.len);
    for (self.drawn.items, out) |r, *o| o.* = .{
        .pane = r.pane_id,
        .label = r.label,
        .subtitle = r.subtitle,
        .label_shown = self.mode == .expanded,
        .tooltip = r.tooltip,
        .selected = r.selected,
        .kind = if (r.viewer) "viewer" else "terminal",
    };
    return .{
        .mode = @tagName(self.mode),
        .expanded = shared.expanded,
        .hidden = shared.hidden,
        .can_expand = rows.canExpand(self.window_width),
        .visible = wk.gtk_widget_get_visible(self.card) != 0,
        .width = rows.cardWidth(self.mode, shared),
        .window_width = self.window_width,
        .rows = out,
    };
}

/// Debug builds append one line per redraw to `$GHOZTTY_TEST_SIDEBAR_DUMP`
/// (`SIDEBAR <mode> rows=<n>`), so a script can wait for a redraw to land
/// before it asks the seam what is shown.
fn dump(self: *PaneSidebar) void {
    if (comptime !build_config.is_debug) return;
    const path = std.posix.getenv("GHOZTTY_TEST_SIDEBAR_DUMP") orelse return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch return;
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "SIDEBAR {s} rows={d}\n", .{ @tagName(self.mode), self.drawn.items.len }) catch return;
    f.writeAll(line) catch {};
}
