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
//! strip (T3617, `PaneDragGhost.zig`). With the mode off the same drag starts
//! from the hover grab handle at the pane's top edge (T3709,
//! `PaneGrabHandle.zig`): the header and the handle are each a `Source`.
//!
//! **A new window (T3618).** A drag let go over nothing - no pane drop target
//! of this app took it - moves the pane into a new window of its own, and so
//! does the header's right-hand button (Mac `PaneHeaderView`'s pop-out). GTK
//! says "nothing took it" as a `drag-cancel` with `GDK_DRAG_CANCEL_NO_TARGET`;
//! a release one of our targets saw - even one that resolved to "leave it
//! where it is" - never pops out, and neither does an Escape. A window's last
//! pane may not pop out (the button is disabled on it), so a drag never closes
//! a window. The move runs on an idle, after the drag has ended: it rebuilds
//! the tree the dragging header sits in.
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

/// `GdkDragCancelReason`: nothing would take the drop.
const drag_cancel_no_target: c_int = 0;

/// Whether one of this app's pane drop targets received the drop of the drag
/// in flight - set by `onDrop` whatever it resolved to, cleared at
/// `drag-begin` - so a release over a target that chose to do nothing is not
/// read as a release over nothing.
var drop_seen: bool = false;

var dragged_buf: [64]u8 = undefined;
var dragged_len: usize = 0;

/// Whether the drag in flight began on a STRIP (T3629): a minimized pane's
/// face, whose drop has a strip's own targets (`pane_drop.resolveBlade`)
/// rather than a pane's.
var dragged_blade: bool = false;

/// The drag in flight is a strip's (`dragged()` is its pane).
pub fn draggingBlade() bool {
    return dragged_len != 0 and dragged_blade;
}

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

/// Builds the pane's ghost card (T3617; `Surface.dragGhost`).
pub const GhostSource = struct {
    owner: *anyopaque,
    build: *const fn (owner: *anyopaque) ?Ghost.Built,
};

/// Moves the pane into a new window (T3618; `Surface.popOutThunk`).
pub const PopOutSource = struct {
    owner: *anyopaque,
    pop: *const fn (owner: *anyopaque) DropResult,
};

/// Told when a drag from a source begins and ends (T3709: the grab handle
/// stays engaged while it is the thing being dragged).
pub const DragHooks = struct {
    owner: *anyopaque,
    begin: *const fn (owner: *anyopaque) void,
    end: *const fn (owner: *anyopaque) void,
};

/// A widget that picks its pane up. The rearrange header (T3564) and the
/// hover grab handle (T3709) are two grips on ONE drag - the same mime type,
/// the same ghost card, the same release-over-nothing pop-out - so both are
/// this, and a drop never knows which one started it (Mac: the handle and
/// the header both start a `PaneDragSession`).
pub const Source = struct {
    /// The pane this source drags: a borrow of the surface's own id buffer.
    pane_id: []const u8,
    /// The drag source, for the ghost card set as its icon at drag-begin.
    source: *wk.GtkEventController,
    /// Builds the pane's ghost card, or null to keep GTK's own icon.
    ghost: ?GhostSource = null,
    /// Moves the pane into a new window: a drag released over nothing.
    pop_out: ?PopOutSource = null,
    hooks: ?DragHooks = null,

    /// Make `widget` a drag source for `pane`. `self` must not move: the
    /// signals hold it.
    pub fn install(self: *Source, widget: *wk.GtkWidget, pane: []const u8) void {
        const source = wk.gtk_drag_source_new();
        self.* = .{ .pane_id = pane, .source = source };
        wk.gtk_drag_source_set_actions(source, wk.gdk_action_move);
        _ = wk.g_signal_connect_data(source, "prepare", @ptrCast(&onPrepare), self, null, 0);
        _ = wk.g_signal_connect_data(source, "drag-begin", @ptrCast(&onDragBegin), self, null, 0);
        _ = wk.g_signal_connect_data(source, "drag-cancel", @ptrCast(&onDragCancel), self, null, 0);
        _ = wk.g_signal_connect_data(source, "drag-end", @ptrCast(&onDragEnd), self, null, 0);
        wk.gtk_widget_add_controller(widget, source);
    }

    /// The released-over-nothing half (T3618), as `drag-cancel` with no
    /// target runs it - but at once, for the `pane-drag --release-nowhere`
    /// seam, which has no drag to end first.
    pub fn releaseOverNothing(self: *Source) DropResult {
        const src = self.pop_out orelse return .{ .target = "new_window", .outcome = "none" };
        return src.pop(src.owner);
    }

    fn onPrepare(_: *wk.GtkEventController, _: f64, _: f64, self: *Source) callconv(.c) ?*wk.GdkContentProvider {
        const bytes = wk.g_bytes_new(self.pane_id.ptr, self.pane_id.len);
        defer wk.g_bytes_unref(bytes);
        return wk.gdk_content_provider_new_for_bytes(mime.ptr, bytes);
    }

    /// GTK says why a drag ended without a drop. Only "nothing would take
    /// it", with none of our targets having seen the release, is a release
    /// over nothing; an Escape or an error leaves the pane where it is.
    /// Returning true says the cancel was handled, so GTK skips the card's
    /// fly-back to where the drag began - the pane is going somewhere.
    fn onDragCancel(_: *wk.GtkEventController, _: *wk.GdkDrag, reason: c_int, self: *Source) callconv(.c) c_int {
        if (reason != drag_cancel_no_target or drop_seen) {
            log.info("drag cancelled pane={s} reason={d} drop_seen={}", .{ self.pane_id, reason, drop_seen });
            return 0;
        }
        if (self.pop_out == null) return 0;
        const pending = std.heap.c_allocator.create(PendingPop) catch return 0;
        pending.* = .{ .source = self };
        log.info("drag released over nothing pane={s}: a new window", .{self.pane_id});
        _ = wk.g_idle_add(&runPendingPop, pending);
        return 1;
    }

    fn onDragBegin(_: *wk.GtkEventController, _: *wk.GdkDrag, self: *Source) callconv(.c) void {
        self.begin();
    }

    fn onDragEnd(_: *wk.GtkEventController, _: *wk.GdkDrag, _: c_int, self: *Source) callconv(.c) void {
        self.end();
    }

    /// What `drag-begin` runs: this pane becomes the drag in flight and the
    /// ghost card its icon. Public for the `pane-drag --grab-begin` seam,
    /// which has no pointer to start a real drag with.
    pub fn begin(self: *Source) void {
        setDragged(self.pane_id);
        dragged_blade = false;
        drop_seen = false;
        if (self.hooks) |h| h.begin(h.owner);
        // The ghost card under the pointer, held by its title strip (Mac
        // `PaneDragGhost`); the drag source keeps its own reference.
        const g = if (self.ghost) |src| src.build(src.owner) else null;
        if (g) |b| {
            defer b.deinit();
            wk.gtk_drag_source_set_icon(self.source, b.paintable, b.plan.hot_x, b.plan.hot_y);
            log.info("drag began pane={s} ghost={d}x{d} hot={d},{d}", .{ self.pane_id, b.plan.image.w, b.plan.image.h, b.plan.hot_x, b.plan.hot_y });
        } else log.info("drag began pane={s} ghost=none", .{self.pane_id});
    }

    /// What `drag-end` runs (and the `--grab-end` seam).
    pub fn end(self: *Source) void {
        log.info("drag ended pane={s}", .{self.pane_id});
        setDragged(null);
        if (self.hooks) |h| h.end(h.owner);
    }
};

pub const Header = struct {
    box: *wk.GtkWidget,
    label: *wk.GtkWidget,
    /// The pane this header drags: a borrow of the surface's own id buffer.
    pane_id: []const u8,
    /// The drag itself; the ghost card and the pop-out a release over
    /// nothing runs are set on it (`drag.ghost`, `drag.pop_out`).
    drag: Source,
    /// The right-hand button that moves the pane into a new window (T3618).
    pop_button: *wk.GtkWidget,

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

        // The pop-out button, on the right (Mac `PaneHeaderView`). Flat, so
        // it reads as part of the header; the arrow cursor over it says it
        // is a button and not more grip.
        const pop = wk.gtk_button_new_from_icon_name("window-new-symbolic");
        wk.gtk_button_set_has_frame(pop, 0);
        wk.gtk_widget_add_css_class(pop, "ghoztty-rearrange-popout");
        wk.gtk_widget_set_cursor_from_name(pop, "default");
        wk.gtk_widget_set_tooltip_text(pop, "Move this pane to a new window");
        wk.gtk_widget_set_valign(pop, 3); // GTK_ALIGN_CENTER
        wk.gtk_box_append(box, pop);

        self.* = .{ .box = box, .label = label, .pane_id = pane, .drag = undefined, .pop_button = pop };
        self.drag.install(box, pane);
        _ = wk.g_signal_connect_data(pop, "clicked", @ptrCast(&onPopClicked), self, null, 0);
        return self;
    }

    /// Enable or disable the pop-out button: disabled on a window's last
    /// pane, which has nowhere to go that is not where it already is.
    pub fn setPopOutEnabled(self: *Header, enabled: bool) void {
        wk.gtk_widget_set_sensitive(self.pop_button, @intFromBool(enabled));
    }

    /// Whether the pop-out button is enabled (the `pane-drag` seam).
    pub fn popOutEnabled(self: *Header) bool {
        return wk.gtk_widget_get_sensitive(self.pop_button) != 0;
    }

    /// Press the pop-out button as a click would (the `pane-drag --pop-out`
    /// seam): its own `clicked` signal, so the handler a pointer click runs
    /// is the one that runs. Not `gtk_widget_activate`: GTK4 animates an
    /// activated button and emits `clicked` only after a timeout, past the
    /// seam's reply. An insensitive button gets no click from GTK, and none
    /// here: null when the button is disabled or hidden.
    pub fn pressPopOut(self: *Header) ?DropResult {
        if (!self.popOutEnabled() or !self.isShown()) return null;
        pop_click_result = null;
        wk.g_signal_emit_by_name(self.pop_button, "clicked");
        return pop_click_result;
    }

    /// The released-over-nothing half (T3618), for the seam.
    pub fn releaseOverNothing(self: *Header) DropResult {
        return self.drag.releaseOverNothing();
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

    fn onPopClicked(_: *wk.GtkWidget, self: *Header) callconv(.c) void {
        const src = self.drag.pop_out orelse return;
        const r = src.pop(src.owner);
        pop_click_result = r;
        log.info("pop-out button pane={s} outcome={s}", .{ self.pane_id, r.outcome });
    }
};

// ---- A strip as a drag source (T3629) ----------------------------------------

/// A strip's face - a minimized pane's label on the stage - as a drag source
/// (docs/reference/stacked-panes.md "Dragging a strip", Mac `PaneBladeDrag`).
/// Dragging it past GTK's drag threshold picks its pane up; the drop has a
/// strip's own targets (`pane_drop.resolveBlade`: a slot in its row, a
/// window's edge band), and a release over nothing settles the strip back -
/// never a new window, unlike a header drag. A plain click stays the stage
/// gesture's (it focuses the pane), which is why that gesture never claims a
/// strip press.
///
/// The face is rebuilt with every stage, so the source names its pane by the
/// stage's key and asks the owner (the split tree) for the pane id at
/// drag-begin: a face never holds a surface pointer that a close could free.
pub const StripSource = struct {
    owner: *anyopaque,
    key: u64,
    source: *wk.GtkEventController,
    /// The pane the strip stands for, or null when it has gone.
    pane: *const fn (owner: *anyopaque, key: u64) ?[]const u8,
    /// The card the drag carries (T3617), or null for GTK's own icon.
    ghost: *const fn (owner: *anyopaque, key: u64) ?Ghost.Built,

    /// Make `face` a strip drag source for the pane `key` of `owner`. Freed
    /// with the face.
    pub fn install(
        face: *wk.GtkWidget,
        owner: *anyopaque,
        key: u64,
        pane: *const fn (owner: *anyopaque, key: u64) ?[]const u8,
        ghost: *const fn (owner: *anyopaque, key: u64) ?Ghost.Built,
    ) void {
        const self = std.heap.c_allocator.create(StripSource) catch return;
        const source = wk.gtk_drag_source_new();
        self.* = .{ .owner = owner, .key = key, .source = source, .pane = pane, .ghost = ghost };
        wk.gtk_drag_source_set_actions(source, wk.gdk_action_move);
        // The destroy notify on `prepare` frees the struct with the source.
        _ = wk.g_signal_connect_data(source, "prepare", @ptrCast(&onPrepare), self, @ptrCast(&onFree), 0);
        _ = wk.g_signal_connect_data(source, "drag-begin", @ptrCast(&onDragBegin), self, null, 0);
        _ = wk.g_signal_connect_data(source, "drag-cancel", @ptrCast(&onDragCancel), self, null, 0);
        _ = wk.g_signal_connect_data(source, "drag-end", @ptrCast(&onDragEnd), self, null, 0);
        wk.gtk_widget_add_controller(face, source);
    }

    fn onFree(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const self: *StripSource = @ptrCast(@alignCast(data orelse return));
        std.heap.c_allocator.destroy(self);
    }

    fn onPrepare(_: *wk.GtkEventController, _: f64, _: f64, self: *StripSource) callconv(.c) ?*wk.GdkContentProvider {
        const id = self.pane(self.owner, self.key) orelse return null;
        const bytes = wk.g_bytes_new(id.ptr, id.len);
        defer wk.g_bytes_unref(bytes);
        return wk.gdk_content_provider_new_for_bytes(mime.ptr, bytes);
    }

    fn onDragBegin(_: *wk.GtkEventController, _: *wk.GdkDrag, self: *StripSource) callconv(.c) void {
        const id = self.pane(self.owner, self.key) orelse return;
        setDragged(id);
        dragged_blade = true;
        drop_seen = false;
        const g = self.ghost(self.owner, self.key);
        if (g) |b| {
            defer b.deinit();
            wk.gtk_drag_source_set_icon(self.source, b.paintable, b.plan.hot_x, b.plan.hot_y);
        }
        log.info("strip drag began pane={s} ghost={}", .{ id, g != null });
    }

    /// A strip let go over nothing settles back where it was (Mac
    /// `resolveBlade`: "anywhere else, nothing - not a new window"), so the
    /// cancel is GTK's to animate.
    fn onDragCancel(_: *wk.GtkEventController, _: *wk.GdkDrag, reason: c_int, _: *StripSource) callconv(.c) c_int {
        log.info("strip drag cancelled reason={d} drop_seen={}: the strip settles back", .{ reason, drop_seen });
        return 0;
    }

    fn onDragEnd(_: *wk.GtkEventController, _: *wk.GdkDrag, _: c_int, _: *StripSource) callconv(.c) void {
        log.info("strip drag ended", .{});
        setDragged(null);
        dragged_blade = false;
    }
};

/// What the last pop-out click did (the seam reads it after activating).
var pop_click_result: ?DropResult = null;

/// A pop-out a drag released over nothing asked for, run on an idle so the
/// drag has ended and its source is no longer mid-signal when the tree that
/// holds it rebuilds. The source (a header or a grab handle) lives as long as its surface, and the
/// surface is not freed by a drag ending.
const PendingPop = struct { source: *Source };

fn runPendingPop(data: ?*anyopaque) callconv(.c) c_int {
    const pending: *PendingPop = @ptrCast(@alignCast(data orelse return 0));
    defer std.heap.c_allocator.destroy(pending);
    const r = pending.source.releaseOverNothing();
    log.info("released over nothing pane={s} target={s} outcome={s}", .{ pending.source.pane_id, r.target, r.outcome });
    return 0; // G_SOURCE_REMOVE
}

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
    drop_seen = true;
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
