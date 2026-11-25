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
const pane_stack_slide = @import("../../win32/pane_stack_slide.zig");
const strip_face = @import("../../win32/strip_face.zig");
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

        /// The glide under way (T3625; win32's pure follower, Mac
        /// `PaneStageView.glide`): every card and strip easing toward where
        /// the layout puts it. Outlives a rebuild - a split or a close
        /// changes what is on show and glides across the new stage - and
        /// ends when the tab stops showing a stage (`endGlide`).
        slide: ?pane_stack_slide.Slide = null,
        /// The layout the last placement saw, as the glide reads it (each
        /// minimized card at its held size), and the grid rect it was in.
        placed: [pane_stack_slide.max_cards]pane_stack_slide.Placed = undefined,
        placed_len: usize = 0,
        placed_grid: pane_stack_grid.PxRect = .{},
        /// Each minimized pane's held size: what it last had on show.
        held: std.AutoHashMapUnmanaged(pane_stack_layout.Id, pane_stack_slide.Size) = .empty,
        /// The cards whose content a glide holds at another size this frame,
        /// by card widget (`cardAllocate` reads it).
        holds: std.AutoHashMapUnmanaged(usize, pane_stage.HeldContent) = .empty,
        /// The glide's frame-clock tick on this tree, while it runs.
        glide_tick: ?c_uint = null,
        glide_last_us: ?i64 = null,
        /// When the last gutter drag was let go (the 50ms gesture tail).
        drag_released_us: ?i64 = null,

        pub var offset: c_int = 0;
    };

    // ---- The pane style (T3566; docs/reference/pane-style.md) ---------------

    const PaneLook = struct { style: pane_style.Style, is_light: bool, glass: bool = false };

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
            .glass = pane_style.hasGlass(Window.paneStyleOf(cfg), cfg.@"macos-pane-glass"),
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
        setClass(tree_widget, pane_style.tree_class_glass, look.glass);

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
            // The pane's glass sheet (T3622) follows a reload that turns
            // glass on or off; the viewer's page follows it too.
            entry.view.as(gtk.Widget).queueDraw();
            entry.view.syncGlass();
        }
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

    /// Enable or disable every pane's pop-out button (T3618): `allowed` is
    /// the window's answer for this tree (`Window.popOutAllowedFor`).
    pub fn syncPopOut(self: *Self, allowed: bool) void {
        const tree = self.private().tree orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| entry.view.setPopOutAllowed(allowed);
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

        // A pane from another tab of this window - the tab a 500ms dwell
        // on the tab bar switched away from (T3615).
        if (pane_drop_apply.handleOf(Surface.Tree, tree, surfaceId, dragged_id) == null) {
            result.outcome = self.dropArriving(dragged_id, target);
            return result;
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

    /// The drop of a pane that is in ANOTHER tree into this one - another tab
    /// of this window (T3615), or a tab of another window (T3616): both trees
    /// change, the pane that lands is the very one that left, and a tab it
    /// was the last pane of closes - and with it a window that had no other
    /// tab. That is the Mac's rule too (`PaneMoveCoordinator.allows`: joining
    /// an EXISTING window is always allowed, a window's last pane included;
    /// nothing is closed, its contents moved).
    fn dropArriving(self: *Self, dragged_id: []const u8, target: pane_drop.Target) []const u8 {
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse return "not_here";
        const home = Window.paneHome(dragged_id, window) orelse return "not_here";
        const source = home.tree;
        if (source == self) return "not_here";
        const cross_window = home.window != window;
        // Held through the move: the source's tab - and window - may close
        // under it when it empties.
        _ = source.as(gobject.Object).ref();
        defer source.as(gobject.Object).unref();
        _ = home.window.as(gobject.Object).ref();
        defer home.window.as(gobject.Object).unref();
        const source_mode = home.window.rearrangeMode();
        const src_tree = source.private().tree orelse return "not_here";
        const dest_tree = self.private().tree orelse return "not_here";
        const alloc = Application.default().allocator();
        const out = pane_drop_apply.applyArriving(Surface.Tree, alloc, src_tree, dest_tree, surfaceId, dragged_id, target) catch |err| {
            log.warn("pane drop from another tab failed err={}", .{err});
            return "not_here";
        };
        switch (out) {
            .not_here => return "not_here",
            .moved => |moved| {
                var m = moved;
                defer m.source.deinit();
                defer m.dest.deinit();
                const dragged_surface: *Surface = dragged: {
                    const h = pane_drop_apply.handleOf(Surface.Tree, &m.dest, surfaceId, dragged_id) orelse return "not_here";
                    break :dragged m.dest.nodes[h.idx()].leaf;
                };
                // A swap sends the pane it landed on the other way.
                const partner: ?*Surface = partner: {
                    if (target != .swap) break :partner null;
                    const h = pane_drop_apply.handleOf(Surface.Tree, &m.source, surfaceId, target.swap.pane) orelse break :partner null;
                    break :partner m.source.nodes[h.idx()].leaf;
                };
                // The source first: it may empty, and its tab then closes;
                // the pane lives on in `m.dest` meanwhile.
                source.rearrange(&m.source);
                self.rearrange(&m.dest);
                self.private().last_focused.set(dragged_surface);
                self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
                if (cross_window) {
                    if (partner) |p| {
                        window.finishArrival(&.{ dragged_surface, p }, source_mode);
                    } else {
                        window.finishArrival(&.{dragged_surface}, source_mode);
                    }
                    log.info("pane {s} arrived from another window", .{dragged_id});
                } else {
                    log.info("pane {s} arrived from another tab", .{dragged_id});
                }
                return "moved";
            },
        }
    }

    /// Show `surface`, a pane moved here from another tab, as this tree's
    /// only pane and focus it (`Tab.newAdopting`, T3615).
    pub fn adoptSurface(self: *Self, surface: *Surface) Allocator.Error!void {
        const alloc = Application.default().allocator();
        var single = try Surface.Tree.init(alloc, surface);
        defer single.deinit();
        self.private().last_focused.set(surface);
        self.setTree(&single);
    }

    /// Take `surface` out of this tree without closing it, for a move to a
    /// new tab (T3615). The caller holds a reference across the move. False
    /// when it is not here or is the tree's only pane (that tab IS the
    /// pane's own tab already).
    pub fn releaseSurface(self: *Self, surface: *Surface) Allocator.Error!bool {
        const tree = self.private().tree orelse return false;
        if (!tree.isSplit()) return false;
        const h = pane_drop_apply.handleOf(Surface.Tree, tree, surfaceId, surface.paneId()) orelse return false;
        const alloc = Application.default().allocator();
        var rest = try tree.remove(alloc, h);
        defer rest.deinit();
        self.rearrange(&rest);
        return true;
    }

    /// Take `surface` out of this tree without closing it, even when it is
    /// the only pane - the tree then empties and its tab closes (T3616: a
    /// pane leaving for ANOTHER window, which `releaseSurface` refuses for a
    /// lone pane because within one window its tab is already its own). The
    /// caller holds a reference to `surface`, and one to this tree's window,
    /// across the move. False when the pane is not here.
    pub fn takeSurface(self: *Self, surface: *Surface) Allocator.Error!bool {
        const tree = self.private().tree orelse return false;
        const h = pane_drop_apply.handleOf(Surface.Tree, tree, surfaceId, surface.paneId()) orelse return false;
        const alloc = Application.default().allocator();
        var rest = try tree.remove(alloc, h);
        defer rest.deinit();
        _ = self.as(gobject.Object).ref();
        defer self.as(gobject.Object).unref();
        self.rearrange(&rest);
        return true;
    }

    /// Whether the pane `id` is in this tree.
    pub fn holds(self: *Self, id: []const u8) bool {
        const tree = self.private().tree orelse return false;
        return pane_drop_apply.handleOf(Surface.Tree, tree, surfaceId, id) != null;
    }

    /// The surface of the pane `id` in this tree, or null.
    pub fn surfaceById(self: *Self, id: []const u8) ?*Surface {
        const tree = self.private().tree orelse return null;
        const h = pane_drop_apply.handleOf(Surface.Tree, tree, surfaceId, id) orelse return null;
        return tree.nodes[h.idx()].leaf;
    }

    /// Push this tree's is-split to each of its panes (T3615). It was a
    /// property binding from the tree that made the pane, which went on
    /// driving a pane after it moved to another tab.
    fn syncIsSplit(self: *Self) void {
        const tree = self.private().tree orelse return;
        const split = self.getIsSplit();
        var it = tree.iterator();
        while (it.next()) |entry| entry.view.setIsSplit(split);
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
        for (cards) |c| {
            wk.gtk_box_append(stage, @ptrCast(c));
            installCardLayout(@ptrCast(c));
        }

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

    // ---- A card holding its content through a glide (T3625) ----------------
    //
    // A card is a `SurfaceScrolledWindow` (overflow hidden, its rim and
    // rounded corners its own) with one child. Its layout is a bin's - the
    // child fills it - unless a glide holds the pane at another size: then
    // the child keeps that size, offset where the glide pins it, and the card
    // cuts it. So a card narrows into its strip around a terminal that is
    // never resized, and every terminal takes its new size once, when its
    // card lands.

    const card_layout_key: [*:0]const u8 = "ghoztty-glide-card-layout";

    fn installCardLayout(card: *wk.GtkWidget) void {
        // Only a real card: a widget that is not a SurfaceScrolledWindow
        // keeps its own layout (it glides at its held size, uncut).
        if (gobject.ext.cast(SurfaceScrolledWindow, @as(*gtk.Widget, @ptrCast(@alignCast(card)))) == null) return;
        if (wk.g_object_get_data(@ptrCast(card), card_layout_key) != null) return;
        wk.gtk_widget_set_layout_manager(card, wk.gtk_custom_layout_new(null, &cardMeasure, &cardAllocate));
        wk.g_object_set_data(@ptrCast(card), card_layout_key, @ptrFromInt(1));
    }

    fn hasCardLayout(card: *wk.GtkWidget) bool {
        return wk.g_object_get_data(@ptrCast(card), card_layout_key) != null;
    }

    /// What a glide holds `card`'s content at this frame, if anything.
    fn heldFor(card: *wk.GtkWidget) ?pane_stage.HeldContent {
        const tree = ext.getAncestor(Self, @ptrCast(@alignCast(card))) orelse return null;
        return tree.private().holds.get(@intFromPtr(card));
    }

    fn cardMeasure(widget: *wk.GtkWidget, orientation: c_int, for_size: c_int, minimum: *c_int, natural: *c_int, min_base: *c_int, nat_base: *c_int) callconv(.c) void {
        minimum.* = 0;
        natural.* = 0;
        min_base.* = -1;
        nat_base.* = -1;
        const child = wk.gtk_widget_get_first_child(widget) orelse return;
        const held = heldFor(widget) != null;
        wk.gtk_widget_measure(child, orientation, if (held) -1 else for_size, minimum, natural, null, null);
        // A held card may be drawn narrower than its content: the content
        // keeps its size inside it.
        if (held) minimum.* = 0;
    }

    fn cardAllocate(widget: *wk.GtkWidget, width: c_int, height: c_int, baseline: c_int) callconv(.c) void {
        const child = wk.gtk_widget_get_first_child(widget) orelse return;
        const hc = heldFor(widget) orelse {
            wk.gtk_widget_allocate(child, width, height, baseline, null);
            return;
        };
        var min_w: c_int = 0;
        var min_h: c_int = 0;
        wk.gtk_widget_measure(child, wk.orientation_horizontal, -1, &min_w, null, null, null);
        wk.gtk_widget_measure(child, wk.orientation_vertical, -1, &min_h, null, null, null);
        const tr = wk.gsk_transform_translate(null, &.{ .x = @floatFromInt(hc.dx), .y = @floatFromInt(hc.dy) });
        wk.gtk_widget_allocate(child, @max(hc.w, min_w), @max(hc.h, min_h), -1, tr);
    }

    /// The card's content: what fades out as it narrows into its strip.
    fn cardContent(card: *wk.GtkWidget) *wk.GtkWidget {
        return wk.gtk_widget_get_first_child(card) orelse card;
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

        // A change in what is on show glides (T3625).
        self.planGlide(tree, &grid, rect);
        const slide: ?*const pane_stack_slide.Slide = if (priv.slide) |*s| s else null;
        const fade = strip_face.fadeOf(1);
        const alloc_holds = Application.default().allocator();
        // Last frame's holds: a card no longer held lays its content out
        // again at its own size.
        var prev_holds = priv.holds;
        priv.holds = .empty;
        defer prev_holds.deinit(alloc_holds);

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
            const axis = p.tab_axis orelse .horizontal;

            // A card on its way somewhere: drawn where the glide has it, its
            // pane held at the size it slid from (or the size it had on
            // show, going into its strip), cut by the card.
            if (slide) |s| if (s.cardRect(id)) |drawn| {
                const pane_r = s.placed(id) orelse drawn;
                const cut = hasCardLayout(card);
                var content_alpha: f64 = 1;
                if (s.stripFace(id)) |sf| {
                    const fa = pane_stage.fadeAt(pane_stack_slide.collapse(
                        pane_stack_slide.Edges.of(sf.card).extent(),
                        fade.strip,
                        fade.span,
                    ));
                    content_alpha = fa.content;
                    if (face) |f| {
                        placeFace(f, sf.card, sf.axis, entry.view, home);
                        wk.gtk_widget_set_opacity(f, fa.face);
                    }
                } else if (face) |f| wk.gtk_widget_set_child_visible(f, 0);
                wk.gtk_widget_set_child_visible(card, 1);
                wk.gtk_widget_set_opacity(cardContent(card), content_alpha);
                // The card cuts a held pane whichever the style.
                wk.gtk_widget_set_overflow(card, 1);
                if (cut) {
                    priv.holds.put(alloc_holds, @intFromPtr(card), pane_stage.heldContent(drawn, pane_r)) catch {};
                    wk.gtk_widget_queue_allocate(card);
                    allocateCard(card, pane_stage.cardAllocation(drawn, elevated));
                } else {
                    // Not a card that can cut its content: it glides at its
                    // held size, whole.
                    allocateCard(card, pane_stage.cardAllocation(pane_r, elevated));
                }
                continue;
            };
            // Not gliding: content at full strength, the style's overflow.
            if (prev_holds.contains(@intFromPtr(card))) wk.gtk_widget_queue_allocate(card);
            wk.gtk_widget_set_opacity(cardContent(card), 1);
            wk.gtk_widget_set_overflow(card, if (elevated) 1 else 0);
            if (face) |f| wk.gtk_widget_set_opacity(f, 1);

            if (p.is_tucked or p.is_sliver) {
                // Minimized: the card keeps its last size on show, out of
                // sight, and its strip's face takes its place.
                wk.gtk_widget_set_child_visible(card, 0);
                const f = face orelse continue;
                const laid = p.tab orelse {
                    wk.gtk_widget_set_child_visible(f, 0);
                    continue;
                };
                const leads = p.strip_leads orelse true;
                // A strip that stays a strip and moves is drawn where the
                // glide has it, its reach under a newcomer held until the
                // glide is over (`Slide.shownStrip`).
                const tab = if (slide) |s| s.shownStrip(id, laid, axis, leads) else laid;
                placeFace(f, pane_stage.stripFace(tab, leads, p.strip_tuck, axis), axis, entry.view, home);
                continue;
            }
            if (face) |f| wk.gtk_widget_set_child_visible(f, 0);
            wk.gtk_widget_set_child_visible(card, 1);
            allocateCard(card, pane_stage.cardAllocation(p.rect, elevated));
        }
    }

    /// Allocate `card` at `a` (stage coordinates), never under its minimum.
    fn allocateCard(card: *wk.GtkWidget, a: pane_stack_grid.PxRect) void {
        var min_w: c_int = 0;
        var min_h: c_int = 0;
        wk.gtk_widget_measure(card, wk.orientation_horizontal, -1, &min_w, null, null, null);
        wk.gtk_widget_measure(card, wk.orientation_vertical, -1, &min_h, null, null, null);
        const tr = wk.gsk_transform_translate(null, &.{ .x = @floatFromInt(a.left), .y = @floatFromInt(a.top) });
        wk.gtk_widget_allocate(card, @max(a.width(), min_w), @max(a.height(), min_h), -1, tr);
    }

    /// Show `f`, a strip's face, over `fr`, named by the sidebar row's rule
    /// and turned to run down a vertical strip.
    fn placeFace(f: *wk.GtkWidget, fr: pane_stack_grid.PxRect, axis: pane_stack_layout.Direction, view: *Surface, home: ?[]const u8) void {
        var lb: [pane_sidebar_rows.TEXT_BUF_LEN]u8 = undefined;
        var sb: [pane_sidebar_rows.TEXT_BUF_LEN]u8 = undefined;
        const t = pane_sidebar_rows.text(PaneSidebar.paneOf(view), home, &lb, &sb);
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
    }

    // ---- Glides: a change in what is on show (T3625) ----------------------

    /// The glide's time constant: Mac's (`pane_stack_slide.glide_ms`), or
    /// stretched by `GHOZTTY_STACK_SLIDE_MS` so a test can sample a card
    /// mid-motion (win32's knob; 0 is no glide).
    fn glideMs() f64 {
        if (std.process.parseEnvVarInt("GHOZTTY_STACK_SLIDE_MS", u32, 10)) |ms| {
            return pane_stack_slide.stretchedGlideMs(@floatFromInt(ms));
        } else |_| {}
        return pane_stack_slide.glide_ms;
    }

    /// A gutter drag is reshaping the row, or was let go under 50ms ago
    /// (Mac `PaneStackState.isGesturing`).
    fn stackGesturing(self: *Self) bool {
        const priv = self.private();
        return pane_stage.gesturing(priv.row_drag != null, priv.drag_released_us, wk.g_get_monotonic_time());
    }

    /// Compare this layout with the last one and start, carry on, or end the
    /// glide (win32 `planStackSlide`; Mac `PaneStageView.apply`). Only a
    /// change in which cards are on show glides, in the grid rect the last
    /// layout used: a window resize lays out at once. Under a drag the glide
    /// follows the hand's layout from wherever each card is drawn.
    fn planGlide(self: *Self, tree: *const Surface.Tree, grid: *const pane_stack_grid.Grid, rect: pane_stack_grid.PxRect) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        var now: [pane_stack_slide.max_cards]pane_stack_slide.Placed = undefined;
        var n: usize = 0;
        const before = priv.placed[0..priv.placed_len];
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (n == now.len) break;
            if (pane_stash.isStashed(entry.view)) continue;
            const id = paneKey(entry.view);
            const p = grid.placement(id) orelse continue;
            const mini = p.is_tucked or p.is_sliver;
            // A minimized card is held at its last size on show, and
            // glides forward from there.
            var at = p.rect;
            if (mini) {
                const last: ?pane_stack_slide.Placed = for (before) |b| {
                    if (b.id == id) break b;
                } else null;
                const s = pane_stack_slide.hold(priv.held.get(id), last, p.rect);
                priv.held.put(alloc, id, s) catch {};
                at = pane_stack_slide.heldRect(p.rect, s);
            } else _ = priv.held.remove(id);
            now[n] = .{
                .id = id,
                .rect = at,
                .tucked = mini,
                .strip = if (mini) p.tab else null,
                .axis = p.tab_axis orelse .horizontal,
            };
            n += 1;
        }
        const same_view = before.len > 0 and std.meta.eql(priv.placed_grid, rect);
        const gesturing = self.stackGesturing();
        if (!same_view) {
            self.endGlide(false);
            self.paintByElevation(tree, grid);
        } else if (pane_stack_slide.runsChanged(before, now[0..n])) {
            const animate = wk.adw_get_enable_animations(@ptrCast(self)) != 0;
            const current: ?*const pane_stack_slide.Slide = if (priv.slide) |*s| s else null;
            var next = if (animate)
                pane_stack_slide.plan(before, now[0..n], current, glideMs(), gesturing)
            else
                pane_stack_slide.Slide{};
            next.fade = strip_face.fadeOf(1);
            if (next.active()) {
                priv.slide = next;
                log.debug("stack glide: cards={d} strips={d} resize={}", .{ next.len, next.strips_len, next.resize });
                self.startGlideClock();
            } else self.endGlide(false);
            self.paintByElevation(tree, grid);
        } else if (priv.slide) |*s| {
            // The drag goes on under a glide: the cards ease toward where
            // the hand has the layout now. One that has caught up once the
            // drag is over is done.
            if (s.retarget(now[0..n])) {
                self.startGlideClock();
            } else if (s.settled() and !gesturing) self.endGlide(false);
        }
        @memcpy(priv.placed[0..n], now[0..n]);
        priv.placed_len = n;
        priv.placed_grid = rect;
    }

    fn startGlideClock(self: *Self) void {
        const priv = self.private();
        if (priv.glide_tick != null) return;
        priv.glide_last_us = null;
        priv.glide_tick = wk.gtk_widget_add_tick_callback(@ptrCast(self), &glideTick, self, null);
    }

    /// End the glide under way, if any; `forget` also drops the layout it
    /// would start from (the tab stopped showing a stage).
    fn endGlide(self: *Self, forget: bool) void {
        const priv = self.private();
        if (priv.glide_tick) |id| wk.gtk_widget_remove_tick_callback(@ptrCast(self), id);
        priv.glide_tick = null;
        priv.glide_last_us = null;
        // Called from a placement (which places everything at its slot right
        // after) or as the stage goes: nothing to queue.
        priv.slide = null;
        if (forget) {
            priv.placed_len = 0;
            priv.held.clearRetainingCapacity();
            priv.holds.clearRetainingCapacity();
        }
    }

    /// One frame of the glide (Mac `PaneStageView.stepGlide`): every card
    /// eases on, and the stage places them where they are drawn now. A glide
    /// that has caught up rests while a drag is held (the next move wakes
    /// it) and ends once the drag is over.
    fn glideTick(_: *wk.GtkWidget, clock: *wk.GdkFrameClock, ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        const s = &(priv.slide orelse {
            priv.glide_tick = null;
            return 0;
        });
        const now = wk.gdk_frame_clock_get_frame_time(clock);
        const dt = pane_stage.frameStep(priv.glide_last_us, now);
        priv.glide_last_us = now;
        const done = s.step(dt);
        self.relayoutStage();
        if (!done) return 1;
        if (self.stackGesturing()) {
            // Resting under the hand. A drag still held is woken by its
            // next move (`retarget`); one just let go comes back here
            // until its 50ms tail is over.
            if (priv.row_drag != null) {
                priv.glide_tick = null;
                priv.glide_last_us = null;
                return 0;
            }
            return 1;
        }
        priv.slide = null;
        priv.glide_tick = null;
        priv.glide_last_us = null;
        log.debug("stack glide landed", .{});
        return 0;
    }

    /// Stack the cards and strip faces in the layout's paint order, bottom
    /// first (`Leaf.elevation`): the run highest and strips lower the
    /// farther they are from it, so a card tucking away passes under the run
    /// rather than across it. Each face sits just above its own card.
    fn paintByElevation(self: *Self, tree: *const Surface.Tree, grid: *const pane_stack_grid.Grid) void {
        const priv = self.private();
        const stage = priv.stage orelse return;
        var ids: [pane_stack_slide.max_cards]pane_stack_layout.Id = undefined;
        var views: [pane_stack_slide.max_cards]*Surface = undefined;
        var n: usize = 0;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (n == ids.len) break;
            if (pane_stash.isStashed(entry.view)) continue;
            const id = paneKey(entry.view);
            if (grid.placement(id) == null) continue;
            ids[n] = id;
            views[n] = entry.view;
            n += 1;
        }
        pane_stack_layout.paintOrder(ids[0..n], &grid.result);
        var order: [2 * pane_stack_slide.max_cards]*wk.GtkWidget = undefined;
        var m: usize = 0;
        for (ids[0..n]) |id| {
            const view: *Surface = for (views[0..n]) |v| {
                if (paneKey(v) == id) break v;
            } else continue;
            const card: *wk.GtkWidget = @ptrCast(cardOf(view));
            if (wk.gtk_widget_get_parent(card) != stage) continue;
            order[m] = card;
            m += 1;
            if (priv.faces.get(id)) |f| {
                order[m] = f;
                m += 1;
            }
        }
        // Already in that order (the usual case): leave the stage alone.
        var child = wk.gtk_widget_get_first_child(stage);
        var in_order = true;
        for (order[0..m]) |w| {
            // Skip anything not in the order (a face of a pane not laid out).
            while (child) |c| : (child = wk.gtk_widget_get_next_sibling(c)) {
                if (c == w) break;
                if (std.mem.indexOfScalar(*wk.GtkWidget, order[0..m], c) != null) {
                    in_order = false;
                    break;
                }
            }
            if (!in_order or child == null) {
                in_order = false;
                break;
            }
            child = wk.gtk_widget_get_next_sibling(child.?);
        }
        if (in_order) return;
        for (order[0..m]) |w| wk.gtk_widget_insert_before(w, stage, null);
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
            // The drag is over 50ms from now (T3625): a glide under way, or
            // resting under the hand, goes on to where it was headed.
            priv.drag_released_us = wk.g_get_monotonic_time();
            if (priv.slide != null) self.startGlideClock();
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
            /// Where its card is drawn this frame (T3625): mid-glide, between
            /// where it was and `frame` (or its strip); else `frame`, or the
            /// strip as it shows.
            drawn: [4]i32,
            /// Its card is on its way somewhere.
            gliding: bool,
            /// Into or out of its strip: how far (`collapse`, 0 a card, 1 the
            /// strip) - its content's opacity is 1 - this.
            fade: ?f64,
            /// Its content's real allocated width and its terminal's size
            /// changes so far: a glide resizes each terminal once, after it.
            content_w: c_int,
            resizes: u32,
        };
        pub const Gutter = struct { kind: []const u8, direction: []const u8, rect: [4]i32 };
        width: c_int,
        height: c_int,
        /// A glide is under way (T3625).
        gliding: bool,
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
            const id = paneKey(entry.view);
            const p = grid.placement(id) orelse continue;
            const mini = p.is_tucked or p.is_sliver;
            const slide: ?*const pane_stack_slide.Slide = if (priv.slide) |*s| s else null;
            const drawn_card: ?pane_stack_grid.PxRect = if (slide) |s| s.cardRect(id) else null;
            const axis = p.tab_axis orelse .horizontal;
            const drawn = drawn_card orelse if (mini) (if (p.tab) |t|
                (if (slide) |s| s.shownStrip(id, t, axis, p.strip_leads orelse true) else t)
            else
                p.rect) else p.rect;
            const fade: ?f64 = if (slide) |s| if (s.stripFace(id)) |sf| blk: {
                const f = strip_face.fadeOf(1);
                break :blk pane_stack_slide.collapse(pane_stack_slide.Edges.of(sf.card).extent(), f.strip, f.span);
            } else null else null;
            const card: *wk.GtkWidget = @ptrCast(cardOf(entry.view));
            try panes.append(arena, .{
                .pane = try arena.dupe(u8, entry.view.paneId()),
                .minimized = mini,
                .focused = focused == entry.view,
                .frame = rectArr(p.rect),
                .strip = if (mini) if (p.tab) |t| rectArr(t) else null else null,
                .drawn = rectArr(drawn),
                .gliding = drawn_card != null,
                .fade = fade,
                .content_w = wk.gtk_widget_get_width(cardContent(card)),
                .resizes = entry.view.sizeChanges(),
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
            .gliding = priv.slide != null,
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

        // Its is-split is pushed by every rebuild (`syncIsSplit`, T3615).

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
        // The stacked-panes stage and its state (T3567), and any glide
        // (T3625): its clock dies with the tree.
        self.endGlide(true);
        self.dropStage();
        priv.faces.deinit(Application.default().allocator());
        priv.faces = .empty;
        priv.held.deinit(Application.default().allocator());
        priv.held = .empty;
        priv.holds.deinit(Application.default().allocator());
        priv.holds = .empty;
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
            self.endGlide(true);
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
            self.endGlide(true);
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
            self.endGlide(true);
            self.dropStage();
            priv.tree_bin.setChild(built.widget);
        }

        // A pane that arrived while its window is in rearrange mode - a new
        // split, a drop - grows its header like the rest (T3564); one that
        // arrived from a window in the mode into one out of it - the pane a
        // cross-window swap sends back (T3616) - loses its header.
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |window| {
            self.syncRearrangeHeaders(window.rearrangeMode());
            // A pane more or fewer changes who may pop out (T3618).
            window.syncPopOut();
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
        self.syncIsSplit();

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
