//! Pane rearrange mode and pane drag-and-drop on GTK (T3564, Linux L11b;
//! docs/reference/pane-rearrange.md).
//!
//! **The header.** While a window is in rearrange mode every pane grows a
//! header: a drag grip, then the pane's title. It sits ABOVE the banner in the
//! pane's own vertical box (the box `Surface.createBanner` turns vertical), so
//! it takes real layout space and entering or leaving the mode resizes every
//! terminal once each way - the Mac's "a header that occludes nothing costs a
//! reflow". Parity is behavior and information, not pixels
//! (docs/design/linux-port.md): a stock `GtkBox` of an icon and a label.
//!
//! **The drag.** The header is a `GtkDragSource` offering one private mime
//! type, `application/x-ghoztty-pane`, so no terminal's own drop target (files
//! and text) can take it: only a split tree's `GtkDropTargetAsync` accepts
//! it. GTK runs one pointer drag at a time, so the pane being dragged is
//! module state set at `drag-begin` - the drop never needs to read the bytes,
//! the Mac's `PaneDragSession` shape. The pointer is an open hand over the
//! header, and the drag carries a ghost card of the pane held by its title
//! strip (T3617, `PaneDragGhost.zig`); the hover handle with the mode off and
//! the live drop preview are follow-up cards.
//!
//! **The tab bar (T3615).** The window's `AdwTabBar` takes pane drops too: a
//! release there moves the pane into a new tab of its own at the index under
//! the pointer, and resting 500ms on another tab's button selects it so the
//! drag can go on into that tab's layout (`Window.dropOnTabBar`,
//! `Window.tabDwellAt`).
//!
//! **The drop.** Resolved by win32's pure resolver (`win32/pane_drop.zig`,
//! Mac's `PaneDropResolver`) against the split tree's own geometry, and made
//! by `pane_drop_apply.zig`: one code path for the live drop and the
//! `pane-drag` test seam. Wayland gives a client no global pointer
//! position, so each window answers for its own area - which is also what
//! makes a later cross-window drop the same code: the compositor delivers the
//! drop to the window under the pointer.
const std = @import("std");
const wk = @import("webkit.zig");
const pane_drop = @import("../win32/pane_drop.zig");
const Ghost = @import("PaneDragGhost.zig");

const log = std.log.scoped(.gtk_pane_drag);

pub const mime: [:0]const u8 = "application/x-ghoztty-pane";

const orientation_horizontal: c_int = 0;
const pango_ellipsize_end: c_int = 3;

/// The header's height in logical pixels: the Mac's 24pt.
pub const header_height: c_int = 24;

// ---- The drag in flight ------------------------------------------------------

var dragged_buf: [64]u8 = undefined;
var dragged_len: usize = 0;

/// The pane id being dragged right now, or null when no pane drag is up.
pub fn dragged() ?[]const u8 {
    if (dragged_len == 0) return null;
    return dragged_buf[0..dragged_len];
}

fn setDragged(id: ?[]const u8) void {
    const v = id orelse {
        dragged_len = 0;
        return;
    };
    const n = @min(v.len, dragged_buf.len);
    @memcpy(dragged_buf[0..n], v[0..n]);
    dragged_len = n;
}

// ---- The header ---------------------------------------------------------------

pub const Header = struct {
    box: *wk.GtkWidget,
    label: *wk.GtkWidget,
    /// The pane this header drags: a borrow of the surface's own id buffer.
    pane_id: []const u8,
    /// The drag source, for the ghost card set as its icon at drag-begin.
    source: *wk.GtkEventController,
    /// Builds the pane's ghost card (T3617; `Surface.dragGhost`), or null to
    /// keep GTK's own icon.
    ghost: ?GhostSource = null,

    pub const GhostSource = struct {
        owner: *anyopaque,
        build: *const fn (owner: *anyopaque) ?Ghost.Built,
    };

    pub fn create(alloc: std.mem.Allocator, pane: []const u8) !*Header {
        const self = try alloc.create(Header);
        const box = wk.gtk_box_new(orientation_horizontal, 6);
        wk.gtk_widget_add_css_class(box, "ghoztty-rearrange-header");
        wk.gtk_widget_set_size_request(box, -1, header_height);
        wk.gtk_widget_set_margin_start(box, 6);
        wk.gtk_widget_set_margin_end(box, 6);
        // The grip owns the cursor: an open hand over the whole header
        // (Mac `PaneDragSourceView`). GTK shows its own closed hand for the
        // drag itself.
        wk.gtk_widget_set_cursor_from_name(box, "grab");
        wk.gtk_widget_set_tooltip_text(box, "Drag to move this pane");

        const grip = wk.gtk_image_new_from_icon_name("list-drag-handle-symbolic");
        wk.gtk_box_append(box, grip);
        const label = wk.gtk_label_new(null);
        wk.gtk_label_set_ellipsize(label, pango_ellipsize_end);
        wk.gtk_widget_set_hexpand(label, 1);
        wk.gtk_widget_set_halign(label, 1); // GTK_ALIGN_START
        wk.gtk_box_append(box, label);

        const source = wk.gtk_drag_source_new();
        self.* = .{ .box = box, .label = label, .pane_id = pane, .source = source };
        wk.gtk_drag_source_set_actions(source, wk.gdk_action_move);
        _ = wk.g_signal_connect_data(source, "prepare", @ptrCast(&onPrepare), self, null, 0);
        _ = wk.g_signal_connect_data(source, "drag-begin", @ptrCast(&onDragBegin), self, null, 0);
        _ = wk.g_signal_connect_data(source, "drag-end", @ptrCast(&onDragEnd), self, null, 0);
        wk.gtk_widget_add_controller(box, source);
        return self;
    }

    /// Show or hide the header. Hidden takes no space at all.
    pub fn setShown(self: *Header, shown: bool) void {
        wk.gtk_widget_set_visible(self.box, @intFromBool(shown));
    }

    pub fn isShown(self: *Header) bool {
        return wk.gtk_widget_get_visible(self.box) != 0;
    }

    pub fn setTitle(self: *Header, text: []const u8) void {
        var buf: [256]u8 = undefined;
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        wk.gtk_label_set_text(self.label, @ptrCast(&buf));
    }

    /// The title the header shows (the `pane-drag` seam).
    pub fn title(self: *Header) []const u8 {
        return std.mem.span(wk.gtk_label_get_text(self.label));
    }

    /// The height it is laid out at, 0 while hidden.
    pub fn height(self: *Header) c_int {
        if (!self.isShown()) return 0;
        return wk.gtk_widget_get_height(self.box);
    }

    fn onPrepare(_: *wk.GtkEventController, _: f64, _: f64, self: *Header) callconv(.c) ?*wk.GdkContentProvider {
        const bytes = wk.g_bytes_new(self.pane_id.ptr, self.pane_id.len);
        defer wk.g_bytes_unref(bytes);
        return wk.gdk_content_provider_new_for_bytes(mime.ptr, bytes);
    }

    fn onDragBegin(_: *wk.GtkEventController, _: *wk.GdkDrag, self: *Header) callconv(.c) void {
        setDragged(self.pane_id);
        // The ghost card under the pointer, held by its title strip (Mac
        // `PaneDragGhost`); the drag source keeps its own reference.
        const g = if (self.ghost) |src| src.build(src.owner) else null;
        if (g) |b| {
            defer b.deinit();
            wk.gtk_drag_source_set_icon(self.source, b.paintable, b.plan.hot_x, b.plan.hot_y);
            log.info("drag began pane={s} ghost={d}x{d} hot={d},{d}", .{ self.pane_id, b.plan.image.w, b.plan.image.h, b.plan.hot_x, b.plan.hot_y });
        } else log.info("drag began pane={s} ghost=none", .{self.pane_id});
    }

    fn onDragEnd(_: *wk.GtkEventController, _: *wk.GdkDrag, _: c_int, self: *Header) callconv(.c) void {
        log.info("drag ended pane={s}", .{self.pane_id});
        setDragged(null);
    }
};

// ---- The drop target ------------------------------------------------------------

/// What a drop on a split tree did, for the log and the test seam.
pub const DropResult = struct {
    /// The resolved target's kind (`split`, `swap`, `top_level`, `insert`,
    /// ...), or `none` when the point means nothing.
    target: []const u8 = "none",
    /// `moved`, `in_place`, `not_here`, or `none` (nothing resolved).
    outcome: []const u8 = "none",
    /// For a split: the side; for a split or swap: the other pane.
    side: ?[]const u8 = null,
    pane: ?[]const u8 = null,
    /// For a tab-bar drop (T3615): the insertion index the resolver named.
    index: ?usize = null,
};

/// The split tree's half of a drop: resolve and apply at a point in the
/// widget's own coordinates.
pub const DropFn = *const fn (owner: *anyopaque, dragged_id: []const u8, x: f64, y: f64) DropResult;

/// A pane drag moving over the widget, in its own coordinates (T3615: the
/// tab bar's dwell clock), and leaving it or ending over it.
pub const MotionFn = *const fn (owner: *anyopaque, x: f64, y: f64) void;
pub const LeaveFn = *const fn (owner: *anyopaque) void;

pub const Hover = struct {
    motion: MotionFn,
    leave: LeaveFn,
};

const DropTarget = struct {
    owner: *anyopaque,
    drop: DropFn,
    hover: ?Hover = null,
};

/// Make `widget` take pane drops, answered by `drop(owner, ...)`. The
/// target lives as long as the widget (it is never freed: one per split
/// tree or tab bar, a few bytes).
pub fn installDropTarget(widget: *wk.GtkWidget, owner: *anyopaque, drop: DropFn) void {
    installDropTargetHover(widget, owner, drop, null);
}

/// `installDropTarget`, with `hover` told where a pane drag is over the
/// widget and when it leaves or ends there.
pub fn installDropTargetHover(widget: *wk.GtkWidget, owner: *anyopaque, drop: DropFn, hover: ?Hover) void {
    const t = std.heap.c_allocator.create(DropTarget) catch return;
    t.* = .{ .owner = owner, .drop = drop, .hover = hover };
    const types = [_][*:0]const u8{mime.ptr};
    const formats = wk.gdk_content_formats_new(&types, types.len);
    const target = wk.gtk_drop_target_async_new(formats, wk.gdk_action_move);
    _ = wk.g_signal_connect_data(target, "accept", @ptrCast(&onAccept), t, null, 0);
    _ = wk.g_signal_connect_data(target, "drag-enter", @ptrCast(&onMotion), t, null, 0);
    _ = wk.g_signal_connect_data(target, "drag-motion", @ptrCast(&onMotion), t, null, 0);
    _ = wk.g_signal_connect_data(target, "drag-leave", @ptrCast(&onLeave), t, null, 0);
    _ = wk.g_signal_connect_data(target, "drop", @ptrCast(&onDrop), t, null, 0);
    wk.gtk_widget_add_controller(widget, target);
}

fn onAccept(_: *wk.GtkEventController, _: *wk.GdkDrop, _: *DropTarget) callconv(.c) c_int {
    // Only a pane drag of this app: another app offering the mime type has
    // no pane here to move.
    return @intFromBool(dragged() != null);
}

fn onMotion(_: *wk.GtkEventController, _: *wk.GdkDrop, x: f64, y: f64, t: *DropTarget) callconv(.c) c_int {
    if (dragged() == null) return 0;
    if (t.hover) |h| h.motion(t.owner, x, y);
    return wk.gdk_action_move;
}

fn onLeave(_: *wk.GtkEventController, _: *wk.GdkDrop, t: *DropTarget) callconv(.c) void {
    if (t.hover) |h| h.leave(t.owner);
}

fn onDrop(_: *wk.GtkEventController, drop: *wk.GdkDrop, x: f64, y: f64, t: *DropTarget) callconv(.c) c_int {
    const id = dragged() orelse {
        wk.gdk_drop_finish(drop, 0);
        return 0;
    };
    // The id is copied: the drop rebuilds the tree, and the drag's end
    // clears the buffer.
    var buf: [64]u8 = undefined;
    const own = buf[0..id.len];
    @memcpy(own, id);
    if (t.hover) |h| h.leave(t.owner);
    const r = t.drop(t.owner, own, x, y);
    log.info("drop pane={s} at={d:.0},{d:.0} target={s} outcome={s}", .{ own, x, y, r.target, r.outcome });
    const moved = std.mem.eql(u8, r.outcome, "moved");
    wk.gdk_drop_finish(drop, if (moved) wk.gdk_action_move else 0);
    return @intFromBool(moved);
}

/// A widget rect as the resolver's `Rect`, in the coordinates of `space`.
pub fn rectOf(widget: *wk.GtkWidget, space: *wk.GtkWidget) ?pane_drop.Rect {
    var r: wk.GrapheneRect = .{};
    if (wk.gtk_widget_compute_bounds(widget, space, &r) == 0) return null;
    if (r.w <= 0 or r.h <= 0) return null;
    return .{
        .left = @intFromFloat(@round(r.x)),
        .top = @intFromFloat(@round(r.y)),
        .right = @intFromFloat(@round(r.x + r.w)),
        .bottom = @intFromFloat(@round(r.y + r.h)),
    };
}
