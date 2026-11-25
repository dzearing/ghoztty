const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const apprt = @import("../../../apprt.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const disconnect_offer = @import("../disconnect_offer.zig");
const CloseUndo = @import("../CloseUndo.zig");
const Surface = @import("surface.zig").Surface;
const SurfaceScrolledWindow = @import("surface_scrolled_window.zig").SurfaceScrolledWindow;
const color_math = @import("../../win32/color_math.zig");
const Window = @import("window.zig").Window;
const PaneDrag = @import("../PaneDrag.zig");
const pane_drop = @import("../../win32/pane_drop.zig");
const pane_drop_apply = @import("../pane_drop_apply.zig");
const pane_style = @import("../pane_style.zig");
const pane_stage = @import("../pane_stage_rules.zig");
const pane_stack_grid = @import("../../win32/pane_stack_grid.zig");
const pane_stash = @import("../../win32/pane_stash.zig");
const pane_sidebar_add = @import("../../win32/pane_sidebar_add.zig");
const pane_stack_layout = @import("../../win32/pane_stack_layout.zig");
const pane_stack_state = @import("../../win32/pane_stack_state.zig");
const stack_drag = @import("../../win32/stack_drag.zig");
const PaneSidebar = @import("../PaneSidebar.zig");
const pane_sidebar_rows = @import("../pane_sidebar_rows.zig");
const homedir = @import("../../../os/homedir.zig");
const wk = @import("../webkit.zig");

const log = std.log.scoped(.gtk_ghostty_split_tree);

pub const SplitTree = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitTree",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const @"has-surfaces" = struct {
            pub const name = "has-surfaces";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getHasSurfaces,
                        },
                    ),
                },
            );
        };

        pub const @"is-zoomed" = struct {
            pub const name = "is-zoomed";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getIsZoomed,
                        },
                    ),
                },
            );
        };

        pub const tree = struct {
            pub const name = "tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = .{
                        .getter = getTreeValue,
                        .setter = setTreeValue,
                    },
                },
            );
        };

        pub const @"is-split" = struct {
            pub const name = "is-split";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getIsSplit,
                        },
                    ),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the tree property has changed, with access
        /// to the previous and new values.
        pub const changed = struct {
            pub const name = "changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ ?*const Surface.Tree, ?*const Surface.Tree },
                void,
            );
        };
    };

    const Private = struct {
        /// The tree datastructure containing all of our surface views.
        tree: ?*Surface.Tree,

        // Template bindings
        tree_bin: *adw.Bin,

        /// Last focused surface in the tree. We need this to handle various
        /// tree change states.
        last_focused: WeakRef(Surface) = .empty,

        /// The source that we use to rebuild the tree. This is also
        /// used to debounce updates.
        rebuild_source: ?c_uint = null,

        /// Used to store state about a pending surface close for the
        /// close dialog.
        pending_close: ?Surface.Tree.Node.Handle,

        /// The gradient desk under the cards in the elevated pane style
        /// (T3566): a small texture of the window's gradient, stretched
        /// over the tree, and what it was rendered for. Owned.
        desk_texture: ?*wk.GdkTexture = null,
        desk_key: pane_style.DeskKey = .{},

        /// Stacked panes (T3567): a split tab is one stage the shared
        /// layout places (`placeStage`), not nested `GtkPaned`s. Null while
        /// the tab shows one pane (a lone pane, or zoomed).
        stage: ?*wk.GtkWidget = null,
        /// Each pane's strip face on the stage, by pane id.
        faces: std.AutoHashMapUnmanaged(pane_stack_layout.Id, *wk.GtkWidget) = .empty,
        /// The focus history and the rows the user collapsed (Mac
        /// `PaneStackState`). Lives as long as the tab.
        stacks: ?pane_stack_state.PaneStackState = null,
        /// The layout the stage was last placed by: what a press is
        /// hit-tested against.
        grid: ?pane_stack_grid.Grid = null,
        /// A gutter drag under way (a divider or a grip).
        row_drag: ?stack_drag.RowDrag = null,
        /// The pane whose strip was pressed, until the press is let go.
        strip_press: ?pane_stack_layout.Id = null,

        pub var offset: c_int = 0;
    };

    // ---- The pane style (T3566; docs/reference/pane-style.md) ---------------

    const PaneLook = struct { style: pane_style.Style, is_light: bool };

    /// The style every window draws now (`macos-pane-style`, which applies
    /// to every window at once) and whether its desk is the light one.
    fn paneLook() PaneLook {
        const config_obj = Application.default().getConfig();
        defer config_obj.unref();
        const cfg = config_obj.get();
        const bg = cfg.background;
        return .{
            .style = Window.paneStyleOf(cfg),
            .is_light = pane_style.isLight(.{ .r = bg.r, .g = bg.g, .b = bg.b }),
        };
    }

    fn setClass(widget: *wk.GtkWidget, class: [:0]const u8, on: bool) void {
        if (on) wk.gtk_widget_add_css_class(widget, class) else wk.gtk_widget_remove_css_class(widget, class);
    }

    /// Mark the tree and its panes for `style.css`: the tree carries the
    /// style (and the light desk), every pane's scrolled window is a card
    /// that clips its terminal to its rounded corners, and the focused pane
    /// of several is the backlit one. Run after every rebuild and focus move.
    pub fn syncPaneStyle(self: *Self) void {
        const look = paneLook();
        const elevated = pane_style.hasDesk(look.style);
        const tree_widget: *wk.GtkWidget = @ptrCast(self);
        setClass(tree_widget, pane_style.tree_class_elevated, elevated);
        setClass(tree_widget, pane_style.tree_class_light, elevated and look.is_light);

        const priv = self.private();
        const tree = priv.tree orelse return;
        // A zoomed tree shows one pane, which has nothing to stand out from.
        var count: usize = 0;
        if (tree.zoomed != null) count = 1 else {
            var it = tree.iterator();
            while (it.next()) |_| count += 1;
        }
        const focused = priv.last_focused.get();
        defer if (focused) |f| f.unref();

        var it = tree.iterator();
        while (it.next()) |entry| {
            const card = ext.getAncestor(SurfaceScrolledWindow, entry.view.as(gtk.Widget)) orelse continue;
            const w: *wk.GtkWidget = @ptrCast(card);
            setClass(w, pane_style.card_class, elevated);
            // GTK_OVERFLOW_HIDDEN: the terminal is clipped to the card's
            // rounded corners; the rim and the shadow are the card's own.
            wk.gtk_widget_set_overflow(w, if (elevated) 1 else 0);
            setClass(w, pane_style.card_class_focused, pane_style.isFocusedCard(look.style, count, focused == entry.view));
        }
    }

    /// The desk, drawn before the children so every card sits on it.
    fn snapshotDesk(self: *Self, snap: *wk.GtkSnapshot) void {
        const look = paneLook();
        if (!pane_style.hasDesk(look.style)) return;
        const widget = self.as(gtk.Widget);
        const w = widget.getWidth();
        const h = widget.getHeight();
        if (w <= 0 or h <= 0) return;
        const variant: ?pane_style.Variant = if (ext.getAncestor(Window, widget)) |win| win.deskVariant() else null;

        const priv = self.private();
        const key: pane_style.DeskKey = .{
            .w = @intCast(w),
            .h = @intCast(h),
            .seed = if (variant) |v| v.seed else null,
            .is_light = look.is_light,
        };
        if (priv.desk_texture == null or !priv.desk_key.eql(key)) {
            const size = pane_style.deskSize(key.w, key.h);
            const alloc = Application.default().allocator();
            const buf = alloc.alloc(u32, size.w * size.h) catch return;
            defer alloc.free(buf);
            pane_style.renderDesk(buf, size, @floatFromInt(w), @floatFromInt(h), pane_style.Palette.forWindow(variant, look.is_light));
            const bytes = wk.g_bytes_new(buf.ptr, buf.len * @sizeOf(u32));
            defer wk.g_bytes_unref(bytes);
            const tex = wk.gdk_memory_texture_new(
                @intCast(size.w),
                @intCast(size.h),
                wk.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED,
                bytes,
                size.w * @sizeOf(u32),
            ) orelse return;
            if (priv.desk_texture) |old| wk.g_object_unref(old);
            priv.desk_texture = tex;
            priv.desk_key = key;
        }
        const rect: wk.GrapheneRect = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        wk.gtk_snapshot_append_scaled_texture(snap, priv.desk_texture.?, wk.GSK_SCALING_FILTER_LINEAR, &rect);
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        self.snapshotDesk(@ptrCast(snap));
        gtk.Widget.virtual_methods.snapshot.call(Class.parent, self.as(Parent), snap);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Initialize our actions
        self.initActionMap();

        // Initialize some basic state
        const priv = self.private();
        priv.pending_close = null;

        // Pane drags land here (T3564): the whole split area answers, in
        // its own coordinates.
        PaneDrag.installDropTarget(@ptrCast(priv.tree_bin), self, &dropFromTarget);
    }

    // ---- Pane rearrange mode and drops (T3564) -------------------------------

    /// Show or hide every pane's rearrange header.
    pub fn syncRearrangeHeaders(self: *Self, on: bool) void {
        const tree = self.private().tree orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| entry.view.setRearrangeHeader(on);
    }

    fn dropFromTarget(owner: *anyopaque, dragged_id: []const u8, x: f64, y: f64) PaneDrag.DropResult {
        const self: *Self = @ptrCast(@alignCast(owner));
        return self.dropPaneAt(dragged_id, x, y);
    }

    /// Drop the pane `dragged_id` at (x, y) in the split area's coordinates:
    /// resolve the point against this tab's panes and dividers, then make the
    /// move. A drag's release and the `pane-drag` seam both come here.
    pub fn dropPaneAt(self: *Self, dragged_id: []const u8, x: f64, y: f64) PaneDrag.DropResult {
        const priv = self.private();
        const tree = priv.tree orelse return .{};
        const space: *wk.GtkWidget = @ptrCast(priv.tree_bin);

        var rects_buf: [pane_drop_apply.max_leaves]pane_drop.PaneRect = undefined;
        var n: usize = 0;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (n == rects_buf.len) break;
            const leaf: *gtk.Widget = if (ext.getAncestor(SurfaceScrolledWindow, entry.view.as(gtk.Widget))) |w|
                w.as(gtk.Widget)
            else
                entry.view.as(gtk.Widget);
            const r = PaneDrag.rectOf(@ptrCast(leaf), space) orelse continue;
            rects_buf[n] = .{ .id = entry.view.paneId(), .rect = r };
            n += 1;
        }
        const rects = rects_buf[0..n];
        const metrics = pane_drop.Metrics.forScale(1.0);
        var ids: [pane_drop_apply.max_leaves][]const u8 = undefined;
        var divs: [pane_drop_apply.max_leaves]pane_drop.Divider = undefined;
        const candidate: pane_drop.Candidate = .{
            .window = @intFromPtr(self),
            .z_order = 0,
            .content_rect = .{ .left = 0, .top = 0, .right = wk.gtk_widget_get_width(space), .bottom = wk.gtk_widget_get_height(space) },
            .pane_rects = rects,
            .dividers = pane_drop_apply.dividers(Surface.Tree, tree, surfaceId, rects, metrics, &ids, &divs),
        };
        const point: pane_drop.Point = .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
        const target = pane_drop.resolve(point, &.{candidate}, dragged_id, metrics) orelse return .{};

        var result: PaneDrag.DropResult = .{ .target = @tagName(target) };
        switch (target) {
            .split => |s| {
                result.side = @tagName(s.side);
                result.pane = s.pane;
            },
            .swap => |s| result.pane = s.pane,
            .top_level => |s| result.side = @tagName(s.side),
            else => {},
        }

        const alloc = Application.default().allocator();
        const outcome = pane_drop_apply.apply(Surface.Tree, alloc, tree, surfaceId, dragged_id, target) catch |err| {
            log.warn("pane drop failed err={}", .{err});
            result.outcome = "not_here";
            return result;
        };
        switch (outcome) {
            .moved => |moved| {
                var t = moved;
                defer t.deinit();
                // The pane that moved is the one the user is holding: it
                // takes focus where it lands.
                const dragged_surface: ?*Surface = dragged: {
                    const h = pane_drop_apply.handleOf(Surface.Tree, &t, surfaceId, dragged_id) orelse break :dragged null;
                    break :dragged t.nodes[h.idx()].leaf;
                };
                self.rearrange(&t);
                if (dragged_surface) |s| {
                    priv.last_focused.set(s);
                    self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
                }
                result.outcome = "moved";
            },
            .in_place => result.outcome = "in_place",
            .not_here => result.outcome = "not_here",
        }
        return result;
    }

    fn surfaceId(s: *Surface) []const u8 {
        return s.paneId();
    }

    /// `surface`'s pane as drawn (header and banner included), in the split
    /// area's coordinates - the space `dropPaneAt` takes its point in.
    pub fn paneRect(self: *Self, surface: *Surface) ?pane_drop.Rect {
        const leaf: *gtk.Widget = if (ext.getAncestor(SurfaceScrolledWindow, surface.as(gtk.Widget))) |w|
            w.as(gtk.Widget)
        else
            surface.as(gtk.Widget);
        return PaneDrag.rectOf(@ptrCast(leaf), @ptrCast(self.private().tree_bin));
    }

    /// The split area's size, for a point named relative to it.
    pub fn areaSize(self: *Self) struct { w: c_int, h: c_int } {
        const space: *wk.GtkWidget = @ptrCast(self.private().tree_bin);
        return .{ .w = wk.gtk_widget_get_width(space), .h = wk.gtk_widget_get_height(space) };
    }

    // ---- Stacked panes (T3567; docs/reference/stacked-panes.md) --------------
    //
    // A split tab is ONE stage: a box whose layout manager places every card
    // where the shared engine puts it (win32's `pane_stack_grid`, Mac's
    // `PaneLayout.compute`), so a pane is never under the configured minimum
    // and a row that cannot fit stacks into a run plus strips. A strip is its
    // pane's face: the card is hidden (never resized while minimized, so its
    // terminal keeps its last size on show) and a label named like its
    // sidebar row is drawn down the strip. Every gutter - a divider, a grip
    // between cards, a grip where the run meets its strips - is a row drag
    // (`stack_drag.RowDrag`, Mac `dragRow`), and clicking a strip focuses
    // its pane, which is what brings it forward.

    const strip_class: [:0]const u8 = "pane-strip";

    fn paneKey(s: *Surface) pane_stack_layout.Id {
        return @intFromPtr(s);
    }

    fn stackState(self: *Self) *pane_stack_state.PaneStackState {
        const priv = self.private();
        if (priv.stacks == null) priv.stacks = pane_stack_state.PaneStackState.init(Application.default().allocator());
        return &priv.stacks.?;
    }

    /// `macos-pane-min-width` / `-height`, read on every layout, so a reload
    /// restacks on the next one (win32 `paneMinimum`).
    fn paneMinimum() pane_stack_layout.Metrics.Minimum {
        const config_obj = Application.default().getConfig();
        defer config_obj.unref();
        const cfg = config_obj.get();
        return .fromConfig(cfg.@"macos-pane-min-width", cfg.@"macos-pane-min-height");
    }

    /// The card widget a surface sits in.
    fn cardOf(s: *Surface) *gtk.Widget {
        return if (ext.getAncestor(SurfaceScrolledWindow, s.as(gtk.Widget))) |w| w.as(gtk.Widget) else s.as(gtk.Widget);
    }

    /// A new stage holding `cards` (in tree order) and one strip face per pane.
    fn newStage(self: *Self, tree: *const Surface.Tree, cards: []const *gtk.Widget) *gtk.Widget {
        const priv = self.private();
        const stage = wk.gtk_box_new(wk.orientation_horizontal, 0);
        wk.gtk_widget_set_hexpand(stage, 1);
        wk.gtk_widget_set_vexpand(stage, 1);
        wk.gtk_widget_set_layout_manager(stage, wk.gtk_custom_layout_new(null, &stageMeasure, &stageAllocate));
        for (cards) |c| wk.gtk_box_append(stage, @ptrCast(c));

        const alloc = Application.default().allocator();
        priv.faces.clearRetainingCapacity();
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (pane_stash.isStashed(entry.view)) continue; // T3596: no card, no strip
            const face = wk.gtk_label_new(null);
            wk.gtk_widget_add_css_class(face, strip_class);
            wk.gtk_label_set_ellipsize(face, 3); // PANGO_ELLIPSIZE_END
            wk.gtk_widget_set_cursor_from_name(face, "pointer");
            wk.gtk_widget_set_child_visible(face, 0);
            wk.gtk_box_append(stage, face);
            priv.faces.put(alloc, paneKey(entry.view), face) catch {};
        }

        // Every gutter and every strip answers one drag gesture on the stage;
        // a press anywhere else is denied and left to the pane under it.
        const drag = wk.gtk_gesture_drag_new();
        _ = wk.g_signal_connect_data(@ptrCast(drag), "drag-begin", @ptrCast(&stageDragBegin), self, null, 0);
        _ = wk.g_signal_connect_data(@ptrCast(drag), "drag-update", @ptrCast(&stageDragUpdate), self, null, 0);
        _ = wk.g_signal_connect_data(@ptrCast(drag), "drag-end", @ptrCast(&stageDragEnd), self, null, 0);
        wk.gtk_widget_add_controller(stage, drag);
        const motion = wk.gtk_event_controller_motion_new();
        _ = wk.g_signal_connect_data(@ptrCast(motion), "motion", @ptrCast(&stageMotion), self, null, 0);
        wk.gtk_widget_add_controller(stage, motion);

        priv.stage = stage;
        return @ptrCast(@alignCast(stage));
    }

    fn stageMeasure(_: *wk.GtkWidget, _: c_int, _: c_int, minimum: *c_int, natural: *c_int, min_base: *c_int, nat_base: *c_int) callconv(.c) void {
        // The stage never holds the window open: a row that does not fit
        // stacks instead.
        minimum.* = 0;
        natural.* = 0;
        min_base.* = -1;
        nat_base.* = -1;
    }

    fn stageAllocate(widget: *wk.GtkWidget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
        const tree_widget = ext.getAncestor(Self, @ptrCast(@alignCast(widget))) orelse return;
        tree_widget.placeStage(widget, width, height, true);
    }

    /// Lay the tab out with the shared engine and place every card and face.
    fn placeStage(self: *Self, stage: *wk.GtkWidget, width: c_int, height: c_int, place: bool) void {
        const priv = self.private();
        if (priv.stage != stage) return;
        const tree = priv.tree orelse return;
        const alloc = Application.default().allocator();
        const state = self.stackState();

        var built = pane_stack_grid.buildWith(alloc, tree, paneKey, .visible) catch return;
        defer built.deinit(alloc);
        // Carry each collapse over whatever changed the tree since the last
        // layout (a close, a split, a drop), as win32's layout does.
        {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            if (built.root) |root| {
                if (pane_stack_layout.rows(arena.allocator(), built.nodes, root)) |rows| {
                    state.noteRows(rows) catch |err| log.warn("stacked rows not carried over: {}", .{err});
                } else |_| {}
            }
        }
        if (priv.last_focused.get()) |f| {
            defer f.unref();
            const id = paneKey(f);
            if (state.recency.first() != id) state.noteFocus(id);
        }

        const look = paneLook();
        const elevated = pane_style.hasDesk(look.style);
        const gap: ?f64 = if (elevated) @floatFromInt(pane_style.gutter) else null;
        const rect = pane_stage.gridRect(width, height, elevated);
        var grid = pane_stack_grid.computeBuilt(
            alloc,
            built,
            rect,
            1,
            pane_stack_grid.metrics(gap, paneMinimum()),
            state.provider(),
        ) catch return;
        // The runs on show stick to the next layout (`stickyRun`).
        state.noteStacks(grid.result.stacks.items) catch {};
        defer {
            if (priv.grid) |*old| old.deinit();
            priv.grid = grid;
        }
        // The test seam asks for the layout as it stands now, between frames.
        if (!place) return;

        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const home = homedir.home(&home_buf) catch null;
        var it = tree.iterator();
        while (it.next()) |entry| {
            // A stashed pane is not on this stage (T3596).
            if (pane_stash.isStashed(entry.view)) continue;
            const id = paneKey(entry.view);
            const card: *wk.GtkWidget = @ptrCast(cardOf(entry.view));
            const face = priv.faces.get(id);
            const p = grid.placement(id) orelse {
                wk.gtk_widget_set_child_visible(card, 0);
                if (face) |f| wk.gtk_widget_set_child_visible(f, 0);
                continue;
            };
            if (p.is_tucked or p.is_sliver) {
                // Minimized: the card keeps its last size on show, out of
                // sight, and its strip's face takes its place.
                wk.gtk_widget_set_child_visible(card, 0);
                const f = face orelse continue;
                const tab = p.tab orelse {
                    wk.gtk_widget_set_child_visible(f, 0);
                    continue;
                };
                const axis = p.tab_axis orelse .horizontal;
                const fr = pane_stage.stripFace(tab, p.strip_leads orelse true, p.strip_tuck, axis);
                var lb: [pane_sidebar_rows.TEXT_BUF_LEN]u8 = undefined;
                var sb: [pane_sidebar_rows.TEXT_BUF_LEN]u8 = undefined;
                const t = pane_sidebar_rows.text(PaneSidebar.paneOf(entry.view), home, &lb, &sb);
                var zbuf: [pane_sidebar_rows.TEXT_BUF_LEN + 1]u8 = undefined;
                const n = @min(t.label.len, zbuf.len - 1);
                @memcpy(zbuf[0..n], t.label[0..n]);
                zbuf[n] = 0;
                wk.gtk_label_set_text(f, @ptrCast(&zbuf));
                wk.gtk_widget_set_child_visible(f, 1);
                const lp = pane_stage.labelPlacement(fr, axis);
                var min_w: c_int = 0;
                var min_h: c_int = 0;
                wk.gtk_widget_measure(f, wk.orientation_horizontal, -1, &min_w, null, null, null);
                wk.gtk_widget_measure(f, wk.orientation_vertical, -1, &min_h, null, null, null);
                var tr = wk.gsk_transform_translate(null, &.{ .x = lp.tx, .y = lp.ty });
                if (lp.rotate) tr = wk.gsk_transform_rotate(tr, 90);
                wk.gtk_widget_allocate(f, @max(lp.w, min_w), @max(lp.h, min_h), -1, tr);
                continue;
            }
            if (face) |f| wk.gtk_widget_set_child_visible(f, 0);
            wk.gtk_widget_set_child_visible(card, 1);
            const a = pane_stage.cardAllocation(p.rect, elevated);
            var min_w: c_int = 0;
            var min_h: c_int = 0;
            wk.gtk_widget_measure(card, wk.orientation_horizontal, -1, &min_w, null, null, null);
            wk.gtk_widget_measure(card, wk.orientation_vertical, -1, &min_h, null, null, null);
            const tr = wk.gsk_transform_translate(null, &.{ .x = @floatFromInt(a.left), .y = @floatFromInt(a.top) });
            wk.gtk_widget_allocate(card, @max(a.width(), min_w), @max(a.height(), min_h), -1, tr);
        }
    }

    /// Recompute the stage's layout now, without placing anything (the next
    /// frame places it): what the `pane-stack` seam reads after a drag step.
    pub fn layoutNow(self: *Self) void {
        const stage = self.private().stage orelse return;
        self.placeStage(stage, wk.gtk_widget_get_width(stage), wk.gtk_widget_get_height(stage), false);
    }

    /// Whether `surface` is minimized into a strip as the stage was last laid
    /// out (`+list`'s `minimized`, win32 T2103).
    pub fn isMinimized(self: *Self, surface: *Surface) bool {
        const grid = &(self.private().grid orelse return false);
        const p = grid.placement(paneKey(surface)) orelse return false;
        return p.is_tucked or p.is_sliver;
    }

    fn relayoutStage(self: *Self) void {
        if (self.private().stage) |s| wk.gtk_widget_queue_allocate(s);
    }

    /// The surface with pane id `id`, if it is still in the tree.
    fn surfaceByKey(self: *Self, id: pane_stack_layout.Id) ?*Surface {
        const tree = self.private().tree orelse return null;
        var it = tree.iterator();
        while (it.next()) |entry| if (paneKey(entry.view) == id) return entry.view;
        return null;
    }

    fn endRowDrag(self: *Self) void {
        const priv = self.private();
        if (priv.row_drag) |*rd| rd.deinit(self.stackState());
        priv.row_drag = null;
    }

    /// Begin a gutter drag on `row`, before item `boundary`; `centre` is the
    /// gutter's centre measured from the row's start.
    fn beginRowDrag(self: *Self, row: pane_stack_layout.Row, d: pane_stack_layout.Direction, boundary: usize, centre: f64) bool {
        self.endRowDrag();
        const priv = self.private();
        const alloc = Application.default().allocator();
        var rd = stack_drag.RowDrag.begin(alloc, self.stackState(), row, boundary, centre) catch return false;
        rd.direction = d;
        if (self.rowRatios(d, row.items, null)) |ratios| {
            defer alloc.free(ratios);
            rd.noteRatios(ratios) catch {};
        }
        priv.row_drag = rd;
        return true;
    }

    /// The splits of the row of `items` along `d`, with the ratios that give
    /// each item its share of `shares` (null: the ratios they have). Caller
    /// frees.
    fn rowRatios(self: *Self, d: pane_stack_layout.Direction, items: []const []const pane_stack_layout.Id, shares: ?[]const f64) ?[]pane_stack_layout.RowRatio {
        const tree = self.private().tree orelse return null;
        const alloc = Application.default().allocator();
        var built = pane_stack_grid.buildWith(alloc, tree, paneKey, .visible) catch return null;
        defer built.deinit(alloc);
        const root = built.root orelse return null;
        return pane_stack_layout.settingRow(alloc, built.nodes, root, d, items, shares) catch null;
    }

    /// What a press on the stage took hold of.
    pub const Press = enum { none, divider, grip, strip };

    /// A press at (x, y) in the stage's coordinates: a gutter begins a row
    /// drag, a strip is held until it is let go; anything else is the pane's.
    /// The real gesture and the `pane-stack` test seam both come here.
    pub fn stagePress(self: *Self, x: f64, y: f64) Press {
        const priv = self.private();
        priv.strip_press = null;
        const grid = &(priv.grid orelse return .none);
        const px: i32 = @intFromFloat(@round(x));
        const py: i32 = @intFromFloat(@round(y));
        if (grid.dividerAt(px, py)) |i| {
            const d = grid.result.dividers.items[i];
            const centre = d.node_frame.start(d.direction) + d.position - d.row.start;
            if (self.beginRowDrag(d.row, d.direction, d.index, centre)) return .divider;
        } else if (grid.stackHandleAt(px, py)) |i| {
            const h = grid.result.stack_handles.items[i];
            const centre = h.frame.start(h.direction) + h.position - h.row.start;
            if (self.beginRowDrag(h.row, h.direction, stack_drag.gripBoundary(h), centre)) return .grip;
        } else if (grid.stripAt(px, py)) |id| {
            priv.strip_press = id;
            return .strip;
        }
        return .none;
    }

    /// The pointer `dx`, `dy` from where the press was.
    pub fn stageDrag(self: *Self, dx: f64, dy: f64) void {
        const priv = self.private();
        const rd = &(priv.row_drag orelse return);
        const position = if (rd.direction == .horizontal) dx else dy;
        const step = rd.moved(self.stackState(), position) catch |err| {
            log.warn("row drag step failed: {}", .{err});
            return;
        };
        self.applyRowDrag(step);
        if (step.restacked) self.focusOnShowAfterRestack();
        self.relayoutStage();
    }

    /// The press let go `dx`, `dy` from where it was.
    pub fn stageRelease(self: *Self, dx: f64, dy: f64) void {
        const priv = self.private();
        if (priv.row_drag != null) {
            self.endRowDrag();
            self.relayoutStage();
            return;
        }
        const id = priv.strip_press orelse return;
        priv.strip_press = null;
        if (!pane_stage.isClick(dx, dy)) return;
        // Bringing a strip forward IS focusing its pane (Mac
        // `PaneStackState.noteFocus`): the row follows the focus.
        const s = self.surfaceByKey(id) orelse return;
        self.stackState().noteFocus(id);
        priv.last_focused.set(s);
        self.relayoutStage();
        s.grabFocus();
    }

    fn stageDragBegin(gesture: *wk.GtkEventController, x: f64, y: f64, self: *Self) callconv(.c) void {
        const held = self.stagePress(x, y);
        _ = wk.gtk_gesture_set_state(gesture, if (held == .none) wk.sequence_denied else wk.sequence_claimed);
    }

    fn stageDragUpdate(_: *wk.GtkEventController, dx: f64, dy: f64, self: *Self) callconv(.c) void {
        self.stageDrag(dx, dy);
    }

    fn stageDragEnd(_: *wk.GtkEventController, dx: f64, dy: f64, self: *Self) callconv(.c) void {
        self.stageRelease(dx, dy);
    }

    /// The stage as last laid out, for the `pane-stack` test seam: each
    /// pane's frame, whether it is minimized and the strip that shows, and
    /// every gutter that takes the mouse. Allocated in `arena`. Null when the
    /// tab shows one pane.
    pub const StageReport = struct {
        pub const Pane = struct {
            pane: []const u8,
            minimized: bool,
            focused: bool,
            frame: [4]i32,
            strip: ?[4]i32,
        };
        pub const Gutter = struct { kind: []const u8, direction: []const u8, rect: [4]i32 };
        width: c_int,
        height: c_int,
        panes: []const Pane,
        gutters: []const Gutter,
    };

    fn rectArr(r: pane_stack_grid.PxRect) [4]i32 {
        return .{ r.left, r.top, r.width(), r.height() };
    }

    pub fn stageReport(self: *Self, arena: Allocator) Allocator.Error!?StageReport {
        const priv = self.private();
        const stage = priv.stage orelse return null;
        const grid = &(priv.grid orelse return null);
        const tree = priv.tree orelse return null;
        const focused = priv.last_focused.get();
        defer if (focused) |f| f.unref();
        var panes: std.ArrayList(StageReport.Pane) = .empty;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const p = grid.placement(paneKey(entry.view)) orelse continue;
            const mini = p.is_tucked or p.is_sliver;
            try panes.append(arena, .{
                .pane = try arena.dupe(u8, entry.view.paneId()),
                .minimized = mini,
                .focused = focused == entry.view,
                .frame = rectArr(p.rect),
                .strip = if (mini) if (p.tab) |t| rectArr(t) else null else null,
            });
        }
        var gutters: std.ArrayList(StageReport.Gutter) = .empty;
        for (0..grid.result.dividers.items.len) |i| try gutters.append(arena, .{
            .kind = "divider",
            .direction = @tagName(grid.result.dividers.items[i].direction),
            .rect = rectArr(grid.dividerGutter(i)),
        });
        for (0..grid.result.stack_handles.items.len) |i| try gutters.append(arena, .{
            .kind = switch (grid.result.stack_handles.items[i].kind) {
                .between => "grip",
                .expand => "edge",
            },
            .direction = @tagName(grid.result.stack_handles.items[i].direction),
            .rect = rectArr(grid.stackHandleGutter(i)),
        });
        return .{
            .width = wk.gtk_widget_get_width(stage),
            .height = wk.gtk_widget_get_height(stage),
            .panes = panes.items,
            .gutters = gutters.items,
        };
    }

    /// After a step of a row drag, the tree's side of it (Mac `dragRow`): all
    /// of the row on show, its splits sized by the step's shares; part of it
    /// folded away, its splits as the drag found them.
    fn applyRowDrag(self: *Self, step: stack_drag.Step) void {
        const priv = self.private();
        const rd = &(priv.row_drag orelse return);
        const tree = priv.tree orelse return;
        const alloc = Application.default().allocator();
        const fresh = if (step.all_shown) self.rowRatios(rd.direction, rd.row.items, rd.shares) else null;
        defer if (fresh) |f| alloc.free(f);
        for (fresh orelse rd.ratios) |r| {
            if (r.node >= tree.nodes.len) continue;
            switch (tree.nodes[r.node]) {
                .split => tree.resizeInPlace(@enumFromInt(r.node), @floatCast(r.ratio)),
                else => {},
            }
        }
    }

    /// A pane that folded away while it had the caret gives it to the nearest
    /// pane still on show (Mac `splitDidRestack`).
    fn focusOnShowAfterRestack(self: *Self) void {
        const priv = self.private();
        const rd = &(priv.row_drag orelse return);
        const focused = priv.last_focused.get() orelse return;
        defer focused.unref();
        const id = rd.focusAfterRestack(self.stackState(), paneKey(focused)) orelse return;
        const s = self.surfaceByKey(id) orelse return;
        priv.last_focused.set(s);
        s.grabFocus();
    }

    fn stageMotion(_: *wk.GtkEventController, x: f64, y: f64, self: *Self) callconv(.c) void {
        const priv = self.private();
        const stage = priv.stage orelse return;
        if (priv.row_drag != null) return;
        const grid = &(priv.grid orelse return);
        const px: i32 = @intFromFloat(@round(x));
        const py: i32 = @intFromFloat(@round(y));
        const cursor: ?[*:0]const u8 = if (grid.dividerAt(px, py)) |i|
            pane_stage.gutterCursor(grid.result.dividers.items[i].direction)
        else if (grid.stackHandleAt(px, py)) |i|
            pane_stage.gutterCursor(grid.result.stack_handles.items[i].direction)
        else
            null;
        wk.gtk_widget_set_cursor_from_name(stage, cursor);
    }

    /// Drop the stage's state when the tab stops showing one.
    fn dropStage(self: *Self) void {
        const priv = self.private();
        self.endRowDrag();
        priv.strip_press = null;
        priv.stage = null;
        priv.faces.clearRetainingCapacity();
        if (priv.grid) |*g| g.deinit();
        priv.grid = null;
    }

    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            // All of these will eventually take a target surface parameter.
            // For now all our targets originate from the focused surface.
            .init("new-split", actionNewSplit, s_variant_type),
            .init("equalize", actionEqualize, null),
            .init("zoom", actionZoom, null),
        };

        _ = ext.actions.addAsGroup(Self, self, "split-tree", &actions);
    }

    /// Create a new split in the given direction from the currently
    /// active surface.
    ///
    /// If the tree is empty this will create a new tree with a new surface
    /// and ignore the direction.
    ///
    /// The parent will be used as the parent of the surface regardless of
    /// if that parent is in this split tree or not. This allows inheriting
    /// surface properties from anywhere.
    pub fn newSplit(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        parent_: ?*Surface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,
            env: []const []const u8 = &.{},
            view: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) Allocator.Error!void {
        _ = try self.newSplitAt(direction, parent_, .{
            .command = overrides.command,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
            .env = overrides.env,
            .view = overrides.view,
        });
    }

    /// `newSplit` with the knobs an IPC `+split` needs (T3370): split next to
    /// `at` (else the active surface), at `ratio`, and - with `focus` false -
    /// leave the keyboard on the pane that had it (the T1797 background
    /// default). Returns the new surface; the tree holds its reference.
    pub fn newSplitAt(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        parent_: ?*Surface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,
            env: []const []const u8 = &.{},
            view: ?[:0]const u8 = null,
            at: ?*Surface = null,
            ratio: f16 = 0.5,
            focus: bool = true,
            /// For a split of a REMOTE machine's pane (T3597): the command
            /// that machine's shell runs, verbatim. `command` is the local
            /// one and never reaches a remote agent.
            remote_command: ?[]const u8 = null,

            pub const none: @This() = .{};
        },
    ) Allocator.Error!*Surface {
        const alloc = Application.default().allocator();

        // Create our new surface.
        const surface: *Surface = .new(.{
            .command = overrides.command,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
            .env = overrides.env,
            .view = overrides.view,
        });
        defer surface.unref();
        _ = surface.refSink();

        // Inherit properly if we were asked to.
        if (parent_) |p| {
            if (p.core()) |core| {
                surface.setParent(core, .split);
            }
            // A split takes its parent's tint (T67, T3382; the Mac
            // BaseTerminalController.newSplit, win32 newSplitAt). An IPC
            // `--color` / `--split-color` overwrites it afterwards.
            if (color_math.splitTint(p.backgroundTint())) |tint|
                surface.applyBackgroundTint(tint);
            // T3597: a split of a remote machine's pane opens on that
            // machine, in the parent's REMOTE cwd (a bounded query on the
            // link, win32's / the Mac's split-time inheritance), running
            // only a command asked of that machine.
            if (overrides.view == null) if (p.remoteLink()) |link| {
                var cwd: ?[]u8 = null;
                defer if (cwd) |c| link.conn().alloc.free(c);
                if (p.core()) |core| if (core.remoteSessionId()) |sid| {
                    cwd = link.conn().queryCwdTimeout(sid, 1500 * std.time.ns_per_ms) catch |err| c: {
                        log.debug("remote split: cwd query failed err={}", .{err});
                        break :c null;
                    };
                };
                surface.adoptRemote(.{
                    .link = link,
                    .working_directory = cwd,
                    .command = overrides.remote_command,
                });
            };
        }

        // Bind is-split property for new surface
        _ = self.as(gobject.Object).bindProperty(
            "is-split",
            surface.as(gobject.Object),
            "is-split",
            .{ .sync_create = true },
        );

        // Create our tree
        var single_tree = try Surface.Tree.init(alloc, surface);
        defer single_tree.deinit();

        // We want to move our focus to the new surface (unless the caller
        // asked to keep it where it is, and there is somewhere to keep it).
        // But we need to be careful to restore state if we fail.
        const old_last_focused = self.private().last_focused.get();
        defer if (old_last_focused) |v| v.unref(); // unref strong ref from get
        const old_tree_ = self.getTree();
        if (overrides.focus or old_tree_ == null)
            self.private().last_focused.set(surface)
        else
            // It never receives focus, so it would never receive the leave
            // that clears the "focused" a new surface starts with, and the
            // tree would read IT as the active pane forever (T3367).
            surface.startUnfocused();
        errdefer self.private().last_focused.set(old_last_focused);

        // If we have no tree yet, then this becomes our tree and we're done.
        const old_tree = old_tree_ orelse {
            self.setTree(&single_tree);
            return surface;
        };

        // The handle we create the split relative to: `at` when it is in
        // this tree, else the active surface.
        const handle = handle: {
            if (overrides.at) |at| {
                var it = old_tree.iterator();
                while (it.next()) |entry| {
                    if (entry.view == at) break :handle entry.handle;
                }
            }
            break :handle self.getActiveSurfaceHandle() orelse .root;
        };

        // Create our split!
        var new_tree = try old_tree.split(
            alloc,
            handle,
            direction,
            overrides.ratio,
            &single_tree,
        );
        defer new_tree.deinit();
        log.debug(
            "new split at={} direction={} old_tree={f} new_tree={f}",
            .{ handle, direction, old_tree, &new_tree },
        );

        // Replace our tree
        self.setTree(&new_tree);
        return surface;
    }

    pub fn resize(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        amount: u16,
    ) Allocator.Error!bool {
        // Avoid useless work
        if (amount == 0) return false;

        const old_tree = self.getTree() orelse return false;
        const active = self.getActiveSurfaceHandle() orelse return false;

        // Get all our dimensions we're going to need to turn our
        // amount into a percentage.
        const priv = self.private();
        const width = priv.tree_bin.as(gtk.Widget).getWidth();
        const height = priv.tree_bin.as(gtk.Widget).getHeight();
        if (width == 0 or height == 0) return false;
        const width_f64: f64 = @floatFromInt(width);
        const height_f64: f64 = @floatFromInt(height);
        const amount_f64: f64 = @floatFromInt(amount);

        // Get our ratio and use positive/neg for directions.
        const ratio: f64 = switch (direction) {
            .right => amount_f64 / width_f64,
            .left => -(amount_f64 / width_f64),
            .down => amount_f64 / height_f64,
            .up => -(amount_f64 / height_f64),
        };

        const layout: Surface.Tree.Split.Layout = switch (direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };

        var new_tree = try old_tree.resize(
            Application.default().allocator(),
            active,
            layout,
            @floatCast(ratio),
        );
        defer new_tree.deinit();
        self.setTree(&new_tree);
        return true;
    }

    /// Move focus from the currently focused surface to the given
    /// direction. Returns true if focus switched to a new surface.
    pub fn goto(self: *Self, to: Surface.Tree.Goto) bool {
        const tree = self.getTree() orelse return false;
        const active = self.getActiveSurfaceHandle() orelse return false;
        // With panes stashed, navigate the arrangement on screen (T3596,
        // win32 `gotoVisible`): a stashed pane is never a focus target.
        if (pane_stash.stashedCount(tree.*) > 0) {
            const from = tree.nodes[active.idx()].leaf;
            const surface = gotoVisible(tree, from, to) orelse return false;
            if (surface == from) return false;
            self.focusSurface(surface);
            return true;
        }
        const target = if (tree.goto(
            Application.default().allocator(),
            active,
            to,
        )) |handle_|
            handle_ orelse return false
        else |err| switch (err) {
            // Nothing we can do in this scenario. This is highly unlikely
            // since split trees don't use that much memory. The application
            // is probably about to crash in other ways.
            error.OutOfMemory => return false,
        };

        // If we aren't changing targets then we did nothing.
        if (active == target) return false;

        // Get the surface at the target location and grab focus.
        const surface = tree.nodes[target.idx()].leaf;
        surface.grabFocus();

        // We also need to setup our last_focused to this because if we
        // trigger a tree change like below, the grab focus above never
        // actually triggers in time to set this and this ensures we
        // grab focus to the right thing.
        const old_last_focused = self.private().last_focused.get();
        defer if (old_last_focused) |v| v.unref(); // unref strong ref from get
        self.private().last_focused.set(surface);
        errdefer self.private().last_focused.set(old_last_focused);

        if (tree.zoomed != null) {
            const app = Application.default();
            const config_obj = app.getConfig();
            defer config_obj.unref();
            const config = config_obj.get();

            if (!config.@"split-preserve-zoom".navigation) {
                tree.zoomed = null;
            } else {
                tree.zoom(target);
            }

            // When the zoom state changes our tree state changes and
            // we need to send the proper notifications to trigger
            // relayout.
            const object = self.as(gobject.Object);
            object.notifyByPspec(properties.tree.impl.param_spec);
            object.notifyByPspec(properties.@"is-zoomed".impl.param_spec);
        }

        return true;
    }

    fn disconnectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }

    fn connectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = Surface.signals.@"close-request".connect(
                surface,
                *Self,
                surfaceCloseRequest,
                self,
                .{},
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                propSurfaceFocused,
                self,
                .{ .detail = "focused" },
            );
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Returns true if this split tree needs confirmation before quitting based
    /// on the various Ghostty configurations.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const tree = self.getTree() orelse return false;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.core()) |core| {
                if (core.needsConfirmQuit()) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Add every pane here a Disconnect would spare to `offer` (T3563).
    pub fn addDisconnectOffer(self: *Self, offer: *disconnect_offer.Offer) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| entry.view.addDisconnectOffer(offer);
    }

    /// The user answered Disconnect for a close of this tree (T3563): pin
    /// every pane riding a remote machine, so its teardown DETACHes. Local
    /// panes - a local-agent pane included - are left to close as usual.
    pub fn pinRemoteDetach(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.remoteLink() != null) entry.view.pinDetach();
        }
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tree = self.getTree() orelse return null;
        const handle = self.getActiveSurfaceHandle() orelse return null;
        return tree.nodes[handle.idx()].leaf;
    }

    fn getActiveSurfaceHandle(self: *Self) ?Surface.Tree.Node.Handle {
        const tree = self.getTree() orelse return null;
        var it = tree.iterator();
        while (it.next()) |entry| {
            // A stashed pane is out of sight (T3596): never the active one.
            if (pane_stash.isStashed(entry.view)) continue;
            if (entry.view.getFocused()) return entry.handle;
        }

        // If none are currently focused, the most previously focused
        // surface (if it exists) is our active surface. This lets things
        // like apprt actions and bell ringing continue to work in the
        // background.
        if (self.private().last_focused.get()) |v| {
            defer v.unref();

            // We need to find the handle of the last focused surface.
            it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == v and !pane_stash.isStashed(v)) return entry.handle;
            }
        }

        return null;
    }

    /// Returns the last focused surface in the tree.
    pub fn getLastFocusedSurface(self: *Self) ?*Surface {
        const surface = self.private().last_focused.get() orelse return null;
        // We unref because get() refs the surface. We don't use the weakref
        // in a multi-threaded context so this is safe.
        surface.unref();
        return surface;
    }

    pub fn getHasSurfaces(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        return !tree.isEmpty();
    }

    pub fn getIsZoomed(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        return tree.zoomed != null;
    }

    /// Make `surface` this tree's focused pane (the `focus` action, T3367).
    /// Like `goto`, it records it as `last_focused` as well as grabbing
    /// focus: a grab alone is lost when a rebuild is still pending (a split
    /// made just before), since the rebuild re-focuses `last_focused`.
    pub fn focusSurface(self: *Self, surface: *Surface) void {
        self.private().last_focused.set(surface);
        surface.grabFocus();
        // Focus brings a minimized pane forward (T3567), whether or not the
        // window holds the keyboard to report the focus back.
        self.relayoutStage();
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    // -- Stash (T3596, win32 T1827, Mac `stashPane` / `restorePane`) --------
    //
    // A stashed pane stays a leaf of the tree - running, targetable, listed -
    // and only the layout skips it: no card on the stage, and a split with a
    // stashed side collapses into the other (`pane_stack_grid`'s `.visible`).
    // The mark is on the Surface (`stash_seq`), so a restore puts it back in
    // exactly the slot it left. `setTree` re-establishes the invariants after
    // every tree change (`pane_stash.normalize`).

    pub const StashError = pane_stash.StashError;

    /// Stash `surface`. Idempotent: stashing a stashed pane changes nothing.
    /// Refused when it is the last pane on screen (`LastVisiblePane`) or not
    /// in this tree (`NotInTree`). When it was the tab's focused pane, focus
    /// goes to the neighbor a close would pick; otherwise it stays put.
    pub fn stashSurface(self: *Self, surface: *Surface) StashError!void {
        const tree = self.getTree() orelse return error.NotInTree;
        if (!pane_stash.contains(tree.*, surface)) return error.NotInTree;
        if (pane_stash.isStashed(surface)) return;
        try pane_stash.checkStash(tree.*, surface);

        // Decide focus against the layout before the pane leaves it.
        const was_active = if (self.getActiveSurface()) |a| a == surface else false;
        const next: ?*Surface = if (was_active)
            gotoVisible(tree, surface, .previous) orelse gotoVisible(tree, surface, .next)
        else
            null;

        pane_stash.mark(surface);
        self.stashChanged();
        if (next) |n| self.focusSurface(n);
        log.info("stashed pane={s} visible={}", .{ surface.paneId(), pane_stash.visibleLeafCount(self.getTree().?.*) });
    }

    /// Put a stashed `surface` back in the slot it left. With `focus` it
    /// becomes the tab's focused pane; without, focus is untouched (a CLI
    /// `+restore` without `--focus`). Restoring a pane on screen succeeds.
    /// False when it is not in this tree.
    pub fn restoreSurface(self: *Self, surface: *Surface, focus: bool) bool {
        const tree = self.getTree() orelse return false;
        if (!pane_stash.contains(tree.*, surface)) return false;
        if (pane_stash.isStashed(surface)) {
            pane_stash.unmark(surface);
            self.stashChanged();
            log.info("restored pane={s} visible={}", .{ surface.paneId(), pane_stash.visibleLeafCount(self.getTree().?.*) });
        }
        if (focus) self.focusSurface(surface);
        return true;
    }

    /// The `restore_stashed_pane` keybind: the top of the stash, focused.
    /// False when nothing is stashed.
    pub fn restoreTopStashed(self: *Self) bool {
        const tree = self.getTree() orelse return false;
        const top = pane_stash.topStashed(tree.*) orelse return false;
        return self.restoreSurface(top, true);
    }

    /// The stash moved but the tree did not: re-set it, so every listener of
    /// a tree change - the rebuild, the window's sidebar and title - redraws.
    fn stashChanged(self: *Self) void {
        const tree = self.getTree() orelse return;
        var copy = tree.clone(Application.default().allocator()) catch |err| {
            log.warn("stash change not redrawn: {}", .{err});
            return;
        };
        defer copy.deinit();
        self.setTree(&copy);
    }

    /// The leaf a single-pane build shows: the first on screen, else the
    /// root (a tree with nothing stashed, or a broken invariant).
    fn firstVisibleHandle(tree: *const Surface.Tree) Surface.Tree.Node.Handle {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (!pane_stash.isStashed(entry.view)) return entry.handle;
        }
        return .root;
    }

    /// `Tree.goto` over the arrangement on screen (win32 `gotoVisible`): from
    /// `from` (on screen now) to the pane `to` names, mapped back BY VIEW -
    /// the visible clone numbers its nodes differently. Null when there is
    /// none, or on OOM.
    fn gotoVisible(tree: *const Surface.Tree, from: *Surface, to: Surface.Tree.Goto) ?*Surface {
        const alloc = Application.default().allocator();
        var visible = pane_stash.visibleClone(tree.*, alloc) catch return null;
        defer visible.deinit();
        var it = visible.iterator();
        const start = while (it.next()) |entry| {
            if (entry.view == from) break entry.handle;
        } else return null;
        const target = (visible.goto(alloc, start, to) catch return null) orelse return null;
        const view = visible.nodes[target.idx()].leaf;
        return if (view == from) null else view;
    }

    /// Close `surface` now, with no confirmation: the CLI's `+close` drives
    /// teardown, as the Mac server's `closeSurface(withConfirmation: false)`
    /// and win32's `closeSplitPane` do (T3367). It takes the same path a
    /// confirmed close takes, so the focus hand-off and the empty-tree tab
    /// close (which closes a window left with no tabs) are the keyboard
    /// close's. False when `surface` is not in this tree.
    pub fn closeSurfaceNow(self: *Self, surface: *Surface) bool {
        const tree = self.getTree() orelse return false;
        var it = tree.iterator();
        const handle = while (it.next()) |entry| {
            if (entry.view == surface) break entry.handle;
        } else return false;
        self.private().pending_close = handle;
        closeConfirmationClose(null, self);
        return true;
    }

    /// Put `replacement` in the slot `old` occupies, touching nothing else:
    /// the tree keeps its shape, ratios and zoom, and every other pane -
    /// viewers included - stays alive (T3400, win32's T399 surgical rebuild
    /// over `SplitTree.replaceLeaf`). The new pane inherits `old`'s focus
    /// standing and tint. `old` leaves the hierarchy and is released by the
    /// old tree; whether its session survives is the caller's business
    /// (`Surface.spareSession`). False when `old` is not in this tree.
    pub fn replaceSurface(self: *Self, old: *Surface, replacement: *Surface) Allocator.Error!bool {
        const alloc = Application.default().allocator();
        const tree = self.getTree() orelse return false;
        var it = tree.iterator();
        const handle = while (it.next()) |entry| {
            if (entry.view == old) break entry.handle;
        } else return false;

        _ = self.as(gobject.Object).bindProperty(
            "is-split",
            replacement.as(gobject.Object),
            "is-split",
            .{ .sync_create = true },
        );
        if (old.backgroundTint()) |tint| replacement.applyBackgroundTint(tint);

        const was_focused = focused: {
            const lf = self.private().last_focused.get() orelse break :focused false;
            defer lf.unref();
            break :focused lf == old;
        };
        if (was_focused) self.private().last_focused.set(replacement) else replacement.startUnfocused();

        var new_tree = try tree.replaceLeaf(alloc, handle, replacement);
        defer new_tree.deinit();
        self.setTree(&new_tree);
        return true;
    }

    /// Replace the whole layout with `new_tree` (cloned): the IPC
    /// `+rearrange` (T3368). Every leaf of `new_tree` must already be a
    /// surface of this tree, so this MOVES panes; a surface `new_tree` leaves
    /// out leaves the widget hierarchy and is destroyed, exactly as a closed
    /// one is (win32 T128, Mac `handleRearrange`). Focus stays on the pane
    /// that had it when that pane survives, else goes to the top-left one on
    /// screen (Mac `leftmostLeaf()`, win32 T1371) - never storage order.
    pub fn rearrange(self: *Self, new_tree: *const Surface.Tree) void {
        const priv = self.private();
        const survivor: ?*Surface = survivor: {
            const active = self.getActiveSurface() orelse break :survivor null;
            var it = new_tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == active) break :survivor active;
            }
            break :survivor null;
        };
        const focus: ?*Surface = survivor orelse if (new_tree.isEmpty())
            null
        else
            new_tree.nodes[new_tree.deepest(.left, .root).idx()].leaf;

        self.setTree(new_tree);

        // The rebuild re-focuses `last_focused`, so this is what takes the
        // keyboard; a grab now would be undone by the pending rebuild.
        if (focus) |f| {
            priv.last_focused.set(f);
            self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
        }
    }

    /// Get the tree data model that we're showing in this widget. This
    /// does not clone the tree.
    pub fn getTree(self: *Self) ?*Surface.Tree {
        return self.private().tree;
    }

    /// Set the tree data model that we're showing in this widget. This
    /// will clone the given tree.
    pub fn setTree(self: *Self, tree_: ?*const Surface.Tree) void {
        const priv = self.private();

        // We always normalize our tree parameter so that empty trees
        // become null so that we don't have to deal with callers being
        // confused about that.
        const tree: ?*const Surface.Tree = tree: {
            const tree = tree_ orelse break :tree null;
            if (tree.isEmpty()) break :tree null;
            break :tree tree;
        };

        // Emit the signal so that handlers can witness both the before and
        // after values of the tree.
        signals.changed.impl.emit(
            self,
            null,
            .{ priv.tree, tree },
            null,
        );

        if (priv.tree) |old_tree| {
            self.disconnectSurfaceHandlers();
            ext.boxedFree(Surface.Tree, old_tree);
            priv.tree = null;
        }

        if (tree) |new_tree| {
            assert(priv.tree == null);
            assert(!new_tree.isEmpty());
            priv.tree = ext.boxedCopy(Surface.Tree, new_tree);
            // Whatever changed the tree, a tab always shows a pane and never
            // zooms into a stashed one (T3596, win32 `pane_stash.normalize`).
            _ = pane_stash.normalize(priv.tree.?);
            self.connectSurfaceHandlers();
        }

        self.as(gobject.Object).notifyByPspec(properties.tree.impl.param_spec);
    }

    fn getTreeValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().tree,
        );
    }

    fn setTreeValue(self: *Self, value: *const gobject.Value) void {
        self.setTree(gobject.ext.Value.get(
            value,
            ?*Surface.Tree,
        ));
    }

    pub fn getIsSplit(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        if (tree.isEmpty()) return false;

        const root_handle: Surface.Tree.Node.Handle = .root;
        const root = tree.nodes[root_handle.idx()];
        return switch (root) {
            .leaf => false,
            .split => true,
        };
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.last_focused.set(null);
        if (priv.desk_texture) |t| wk.g_object_unref(t);
        priv.desk_texture = null;
        // The stacked-panes stage and its state (T3567).
        self.dropStage();
        priv.faces.deinit(Application.default().allocator());
        priv.faces = .empty;
        if (priv.stacks) |*st| st.deinit();
        priv.stacks = null;
        if (priv.rebuild_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove rebuild source", .{});
            }
            priv.rebuild_source = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tree) |tree| {
            ext.boxedFree(Surface.Tree, tree);
            priv.tree = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    pub fn actionNewSplit(
        _: *gio.SimpleAction,
        args_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const args = args_ orelse {
            log.warn("split-tree.new-split called without a parameter", .{});
            return;
        };

        var dir: ?[*:0]const u8 = null;
        args.get("&s", &dir);

        const direction = std.meta.stringToEnum(
            Surface.Tree.Split.Direction,
            std.mem.span(dir) orelse return,
        ) orelse {
            // Need to be defensive here since actions can be triggered externally.
            log.warn("invalid split direction for split-tree.new-split: {s}", .{dir.?});
            return;
        };

        // A split by hand (a keybind, the menu, the palette): the direction
        // a sidebar window row's + repeats (T3606, Mac `PaneSplitMemory`).
        // `+split` calls `newSplitAt` directly and never lands here.
        pane_sidebar_add.noteManualSplit(direction);

        self.newSplit(
            direction,
            self.getActiveSurface(),
            .none,
        ) catch |err| {
            log.warn("new split failed error={}", .{err});
        };
    }

    pub fn actionEqualize(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = parameter_;

        const old_tree = self.getTree() orelse return;
        var new_tree = old_tree.equalize(Application.default().allocator()) catch |err| {
            log.warn("unable to equalize tree: {}", .{err});
            return;
        };
        defer new_tree.deinit();
        self.setTree(&new_tree);
    }

    pub fn swapSplit(self: *Self, to: Surface.Tree.Goto) bool {
        const tree = self.getTree() orelse return false;
        const active = self.getActiveSurfaceHandle() orelse return false;
        const target = if (tree.goto(
            Application.default().allocator(),
            active,
            to,
        )) |handle_|
            handle_ orelse return false
        else |err| switch (err) {
            error.OutOfMemory => return false,
        };

        if (active == target) return false;

        const gpa = Application.default().allocator();
        var new_tree = tree.swap(gpa, active, target) catch |err| {
            log.warn("unable to swap splits: {}", .{err});
            return false;
        };
        defer new_tree.deinit();
        self.setTree(&new_tree);

        const surface = self.getTree().?.nodes[target.idx()].leaf;
        surface.grabFocus();

        return true;
    }

    pub fn actionZoom(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tree = self.getTree() orelse return;
        if (tree.zoomed != null) {
            tree.zoomed = null;
        } else {
            // One pane on screen, the rest stashed: nothing to zoom (T3596).
            if (!pane_stash.isVisiblySplit(tree.*)) return;
            const active = self.getActiveSurfaceHandle() orelse return;
            if (tree.zoomed == active) return;
            tree.zoom(active);
        }

        self.as(gobject.Object).notifyByPspec(properties.tree.impl.param_spec);
    }

    fn surfaceCloseRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        // A viewer pane has no core and nothing running, so it never asks
        // (T3411); any other core-less surface is not ours to close yet.
        const core = surface.core();
        if (core == null and !surface.isViewer()) return;

        // Reset our pending close state
        const priv = self.private();
        priv.pending_close = null;

        // Find the surface in the tree to verify this is valid and
        // set our pending close handle.
        priv.pending_close = handle: {
            const tree = self.getTree() orelse return;
            var it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == surface) {
                    break :handle entry.handle;
                }
            }

            return;
        };

        // T3563: a remote pane asks even when idle, and offers Disconnect.
        var offer: disconnect_offer.Offer = .{};
        surface.addDisconnectOffer(&offer);
        const needs_confirm = if (core) |c| c.needsConfirmQuit() else false;
        const step = disconnect_offer.step(needs_confirm, offer);

        // If we don't need to confirm then just close immediately.
        if (step == .close) {
            closeConfirmationClose(
                null,
                self,
            );
            return;
        }

        // Show a confirmation dialog
        log.info("pane close request: asking (disconnect offered: {})", .{offer.offered()});
        const dialog: *CloseConfirmationDialog = .new(.surface);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Self,
            closeConfirmationClose,
            self,
            .{},
        );
        if (step == .ask_disconnect) {
            dialog.offerDisconnect(offer);
            _ = CloseConfirmationDialog.signals.@"disconnect-request".connect(
                dialog,
                *Self,
                closeConfirmationDisconnect,
                self,
                .{},
            );
        }
        dialog.present(self.as(gtk.Widget));
    }

    /// Disconnect (T3563): close the pending pane, pinned so its remote
    /// session keeps running.
    fn closeConfirmationDisconnect(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        const handle = self.private().pending_close orelse return;
        const tree = self.getTree() orelse return;
        switch (tree.nodes[handle.idx()]) {
            .leaf => |v| v.pinDetach(),
            .split => return,
        }
        closeConfirmationClose(null, self);
    }

    fn closeConfirmationClose(
        _: ?*CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        // Get the handle we're closing
        const priv = self.private();
        const handle = priv.pending_close orelse return;
        priv.pending_close = null;

        // Figure out our next focus target. The next focus target is
        // always the "previous" surface unless we're the leftmost then
        // its the next.
        const old_tree = self.getTree() orelse return;

        // T3590: the tab's only pane closing is its tab closing. With undo
        // on, the tab closes whole, tree intact, so it is parked as a tab.
        if (CloseUndo.closeTabInstead(self, old_tree, handle)) return;
        // Read now: `setTree` below frees `old_tree`.
        const had_stash = pane_stash.stashedCount(old_tree.*) > 0;

        const next_focus: ?*Surface = next_focus: {
            const alloc = Application.default().allocator();
            // With panes stashed, the neighbor is one on screen (T3596).
            if (had_stash) {
                const from = old_tree.nodes[handle.idx()].leaf;
                break :next_focus gotoVisible(old_tree, from, .previous) orelse
                    gotoVisible(old_tree, from, .next);
            }
            const next_handle: Surface.Tree.Node.Handle =
                (old_tree.goto(alloc, handle, .previous) catch null) orelse
                (old_tree.goto(alloc, handle, .next) catch null) orelse
                break :next_focus null;
            if (next_handle == handle) break :next_focus null;

            // Note: we don't need to ref this or anything because its
            // guaranteed to remain in the new tree since its not part
            // of the handle we're removing.
            break :next_focus old_tree.nodes[next_handle.idx()].leaf;
        };

        // T3384: with undo on, the pane is parked (one reference held) for
        // Ctrl+Shift+Z rather than ended by the removal below. Its tab's
        // only pane is not: closing that is closing the tab.
        _ = CloseUndo.parkClosedPane(self, old_tree, handle);

        // Remove it from the tree.
        var new_tree = old_tree.remove(
            Application.default().allocator(),
            handle,
        ) catch |err| {
            log.warn("unable to remove surface from tree: {}", .{err});
            return;
        };
        defer new_tree.deinit();
        self.setTree(&new_tree);

        // Grab focus. We have to set this on the "last focused" because our
        // focus will be set when the tree is redrawn. A close that left only
        // stashed panes brought the top one back (`normalize`): it takes it.
        if (next_focus) |v| {
            priv.last_focused.set(v);
        } else if (had_stash) {
            if (self.getTree()) |t| {
                if (pane_stash.keepOrFirstVisible(t.*, null)) |v| priv.last_focused.set(v);
            }
        }
    }

    fn propSurfaceFocused(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We never CLEAR our last_focused because the property is specifically
        // the last focused surface. We let the weakref clear itself when
        // the surface is destroyed.
        if (!surface.getFocused()) return;
        self.private().last_focused.set(surface);
        self.syncPaneStyle();
        // Focus brings a pane forward (T3567): the row follows it.
        self.relayoutStage();

        // Our active surface probably changed
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn propTree(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();

        // No matter what we notify
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.@"has-surfaces".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"is-zoomed".impl.param_spec);

        // If we were planning a rebuild, always remove that so we can
        // start from a clean slate.
        if (priv.rebuild_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove rebuild source", .{});
            }
            priv.rebuild_source = null;
        }

        // If we transitioned to an empty tree, clear immediately instead of
        // waiting for an idle callback. Delaying teardown can keep the last
        // surface alive during shutdown if the main loop exits first.
        if (priv.tree == null) {
            self.dropStage();
            priv.tree_bin.setChild(null);
            return;
        }

        // Build on an idle callback so rapid tree changes are debounced.
        // We keep the existing tree attached until the rebuild runs,
        // which avoids transient empty frames.
        assert(priv.rebuild_source == null);
        priv.rebuild_source = glib.idleAdd(
            onRebuild,
            self,
        );
    }

    fn onRebuild(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always mark our rebuild source as null since we're done.
        const priv = self.private();
        priv.rebuild_source = null;

        // Rebuild our tree
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        if (tree.isEmpty()) {
            self.dropStage();
            priv.tree_bin.setChild(null);
        } else if (tree.zoomed == null and pane_stash.isVisiblySplit(tree.*)) {
            // Several panes on show: one stage the shared layout places
            // (T3567). Each card is detached from the old widgets first. A
            // stashed pane gets no card (T3596): its old one goes with the
            // old stage, and a restore builds it a new one.
            var results: [pane_drop_apply.max_leaves]BuildTreeResult = undefined;
            var cards: [pane_drop_apply.max_leaves]*gtk.Widget = undefined;
            var n: usize = 0;
            var it = tree.iterator();
            while (it.next()) |entry| {
                if (pane_stash.isStashed(entry.view)) continue;
                if (n == results.len) break;
                results[n] = self.buildTree(tree, entry.handle);
                cards[n] = results[n].widget;
                n += 1;
            }
            defer for (results[0..n]) |r| r.deinit();
            self.dropStage();
            priv.tree_bin.setChild(self.newStage(tree, cards[0..n]));
        } else {
            // Zoomed, or one pane on show: the zoomed pane, else the one
            // on-screen leaf (the others stashed, T3596), else the root.
            const built = self.buildTree(
                tree,
                tree.zoomed orelse firstVisibleHandle(tree),
            );
            defer built.deinit();
            self.dropStage();
            priv.tree_bin.setChild(built.widget);
        }

        // A pane that arrived while its window is in rearrange mode - a new
        // split, a drop - grows its header like the rest (T3564).
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |window| {
            if (window.rearrangeMode()) self.syncRearrangeHeaders(true);
        }

        // Every pane is a card, and the focused one of several is lit (T3566).
        self.syncPaneStyle();

        // Replacing our tree widget hierarchy can reset focus state.
        // If we have a last-focused surface, restore focus to it.
        if (priv.last_focused.get()) |v| {
            defer v.unref();
            v.grabFocus();
        }

        // Our split status may have changed
        self.as(gobject.Object).notifyByPspec(properties.@"is-split".impl.param_spec);

        // Our active surface may have changed
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);

        return 0;
    }

    /// Builds the widget tree associated with a surface split tree.
    ///
    /// Returned widgets are expected to be attached to a parent by the caller.
    ///
    /// If `release_ref` is true then `widget` has an extra temporary
    /// reference that must be released once it is parented in the rebuilt
    /// tree.
    const BuildTreeResult = struct {
        widget: *gtk.Widget,
        release_ref: bool,

        pub fn initNew(widget: *gtk.Widget) BuildTreeResult {
            return .{ .widget = widget, .release_ref = false };
        }

        pub fn initReused(widget: *gtk.Widget) BuildTreeResult {
            // We add a temporary ref to the widget to ensure it doesn't
            // get destroyed while we're rebuilding the tree and detaching
            // it from its old parent. The caller is expected to release
            // this ref once the widget is attached to its new parent.
            _ = widget.as(gobject.Object).ref();

            // Detach after we ref it so that this doesn't mark the
            // widget for destruction.
            detachWidget(widget);

            return .{ .widget = widget, .release_ref = true };
        }

        pub fn deinit(self: BuildTreeResult) void {
            // If we have to release a ref, do it.
            if (self.release_ref) self.widget.as(gobject.Object).unref();
        }
    };

    fn buildTree(
        self: *Self,
        tree: *const Surface.Tree,
        current: Surface.Tree.Node.Handle,
    ) BuildTreeResult {
        return switch (tree.nodes[current.idx()]) {
            .leaf => |v| leaf: {
                const window = ext.getAncestor(
                    SurfaceScrolledWindow,
                    v.as(gtk.Widget),
                ) orelse {
                    // The surface isn't in a window already so we don't
                    // have to worry about reuse.
                    break :leaf .initNew(gobject.ext.newInstance(
                        SurfaceScrolledWindow,
                        .{ .surface = v },
                    ).as(gtk.Widget));
                };

                // Keep this widget alive while we detach it from the
                // old tree and adopt it into the new one.
                break :leaf .initReused(window.as(gtk.Widget));
            },
            .split => |s| split: {
                const left = self.buildTree(tree, s.left);
                defer left.deinit();
                const right = self.buildTree(tree, s.right);
                defer right.deinit();

                break :split .initNew(SplitTreeSplit.new(
                    current,
                    &s,
                    left.widget,
                    right.widget,
                ).as(gtk.Widget));
            },
        };
    }

    /// Detach a split widget from its current parent.
    ///
    /// We intentionally use parent-specific child APIs when possible
    /// (`GtkPaned.setStartChild/setEndChild`, `AdwBin.setChild`) instead of
    /// calling `gtk.Widget.unparent` directly. Container implementations track
    /// child pointers/properties internally, and those setters are the path
    /// that keeps container state and notifications in sync.
    fn detachWidget(widget: *gtk.Widget) void {
        const parent = widget.getParent() orelse return;

        // A card on a stacked-panes stage (T3567).
        if (gobject.ext.cast(gtk.Box, parent)) |box| {
            box.remove(widget);
            return;
        }

        // Surface will be in a paned when it is split.
        if (gobject.ext.cast(gtk.Paned, parent)) |paned| {
            if (paned.getStartChild()) |child| {
                if (child == widget) {
                    paned.setStartChild(null);
                    return;
                }
            }

            if (paned.getEndChild()) |child| {
                if (child == widget) {
                    paned.setEndChild(null);
                    return;
                }
            }
        }

        // Surface will be in a bin when it is not split.
        if (gobject.ext.cast(adw.Bin, parent)) |bin| {
            if (bin.getChild()) |child| {
                if (child == widget) {
                    bin.setChild(null);
                    return;
                }
            }
        }

        // Fallback for unexpected parents where we don't have a typed
        // container API available.
        widget.unparent();
    }

    //---------------------------------------------------------------
    // Class

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-tree",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.@"has-surfaces".impl,
                properties.@"is-zoomed".impl,
                properties.tree.impl,
                properties.@"is-split".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tree_bin", .{});

            // Template Callbacks
            class.bindTemplateCallback("notify_tree", &propTree);

            // Signals
            signals.changed.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            // The elevated pane style's gradient desk (T3566).
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// This is an internal-only widget that represents a split in the
/// split tree. This is a wrapper around gtk.Paned that allows us to handle
/// ratio (0 to 1) based positioning of the split, and also allows us to
/// write back the updated ratio to the split tree when the user manually
/// adjusts the split position.
///
/// Since this is internal, it expects to be nested within a SplitTree and
/// will use `getAncestor` to find the SplitTree it belongs to.
///
/// This is an _immutable_ widget. It isn't meant to be updated after
/// creation. As such, there are no properties or APIs to change the split,
/// access the paned, etc.
const SplitTreeSplit = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitTreeSplit",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The handle of the node in the tree that this split represents.
        /// Assumed to be correct.
        handle: Surface.Tree.Node.Handle,

        /// Source to handle repositioning the split when properties change.
        idle: ?c_uint = null,

        // Template bindings
        paned: *gtk.Paned,

        pub var offset: c_int = 0;
    };

    /// Create a new split.
    ///
    /// The reason we don't use GObject properties here is because this is
    /// an immutable widget and we don't want to deal with the overhead of
    /// all the boilerplate for properties, signals, bindings, etc.
    pub fn new(
        handle: Surface.Tree.Node.Handle,
        split: *const Surface.Tree.Split,
        start_child: *gtk.Widget,
        end_child: *gtk.Widget,
    ) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.handle = handle;

        // Setup our paned fields
        const paned = priv.paned;
        paned.setStartChild(start_child);
        paned.setEndChild(end_child);
        paned.as(gtk.Orientable).setOrientation(switch (split.layout) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        });

        // Signals and so on are setup in the template.

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn refresh(self: *Self) void {
        const priv = self.private();
        if (priv.idle == null) priv.idle = glib.idleAdd(
            onIdle,
            self,
        );
    }

    fn onIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        const paned = priv.paned;

        // Our idle source is always over
        priv.idle = null;

        // Get our split. This is the most dangerous part of this entire
        // widget. We assume that this widget is always a child of a
        // SplitTree, we assume that our handle is valid, and we assume
        // the handle is always a split node.
        const split_tree = ext.getAncestor(
            SplitTree,
            self.as(gtk.Widget),
        ) orelse return 0;
        const tree = split_tree.getTree() orelse return 0;
        const split: *const Surface.Tree.Split = &tree.nodes[priv.handle.idx()].split;

        // Current, min, and max positions as pixels.
        const pos = paned.getPosition();
        const min = min: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "min-position",
                &val,
            );
            break :min gobject.ext.Value.get(&val, c_int);
        };
        const max = max: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "max-position",
                &val,
            );
            break :max gobject.ext.Value.get(&val, c_int);
        };
        const pos_set: bool = max: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "position-set",
                &val,
            );
            break :max gobject.ext.Value.get(&val, c_int) != 0;
        };

        // We don't actually use min, but we don't expect this to ever
        // be non-zero, so let's add an assert to ensure that.
        assert(min == 0);

        // If our max is zero then we can't do any math. I don't know
        // if this is possible but I suspect it can be if you make a nested
        // split completely minimized.
        if (max == 0) return 0;

        // Determine our current ratio.
        const current_ratio: f64 = ratio: {
            const pos_f64: f64 = @floatFromInt(pos);
            const max_f64: f64 = @floatFromInt(max);
            break :ratio pos_f64 / max_f64;
        };
        const desired_ratio: f64 = @floatCast(split.ratio);

        // If our ratio is close enough to our desired ratio, then
        // we ignore the update. This is to avoid constant split updates
        // for lossy floating point math.
        if (std.math.approxEqAbs(
            f64,
            current_ratio,
            desired_ratio,
            0.001,
        )) {
            return 0;
        }

        // If we're out of bounds, then we need to either set the position
        // to what we expect OR update our expected ratio.

        // If we've never set the position, then we set it to the desired.
        if (!pos_set) {
            const desired_pos: c_int = desired_pos: {
                const max_f64: f64 = @floatFromInt(max);
                break :desired_pos @intFromFloat(@round(max_f64 * desired_ratio));
            };
            paned.setPosition(desired_pos);
            return 0;
        }

        // If we've set the position, then this is a manual human update
        // and we need to write our update back to the tree.
        tree.resizeInPlace(priv.handle, @floatCast(current_ratio));

        return 0;
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn propPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    fn propMaxPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    fn propMinPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.idle) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove idle source", .{});
            }
            priv.idle = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-tree-split",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("paned", .{});

            // Template Callbacks
            class.bindTemplateCallback("notify_max_position", &propMaxPosition);
            class.bindTemplateCallback("notify_min_position", &propMinPosition);
            class.bindTemplateCallback("notify_position", &propPosition);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
