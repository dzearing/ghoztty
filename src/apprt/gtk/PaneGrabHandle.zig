//! The hover grab handle at the top of a pane on GTK (T3709, Linux L11b5c).
//!
//! Mac parity: `PaneGrabHandle` in `SurfaceGrabHandle.swift`; win32
//! `PaneGrabHandle.zig` (T1830). With rearrange mode OFF, any pane - a
//! terminal or a viewer - reveals a grip centred at its top edge while the
//! pointer is in the pane's top band, and dragging the grip moves the pane
//! exactly as the rearrange header does: the same `PaneDrag.Source`, so the
//! same mime type, ghost card, drop targets, drop preview and
//! release-over-nothing pop-out. A drop never knows which grip started it.
//!
//! Every rule and every pixel is win32's pure `pane_grab_handle.zig`, shared
//! rather than copied: the band is the top fifth of the pane (never shorter
//! than the hit box), the hit box is 80x24 centred on the top edge, the
//! capsule 48x16 four pixels down, hinted (pointer in the band: a
//! translucent capsule, dimmed dots) or engaged (pointer on the grip, or the
//! grip being dragged: a solid capsule a shade off the pane background, a
//! slight shadow). Its `render` paints the capsule into a premultiplied BGRA
//! buffer at the widget's device scale, which becomes the texture of a
//! `GtkPicture` overlaid on the pane (`terminal_page`, the surface's
//! `GtkOverlay`), so the Linux grip is the Windows grip pixel for pixel.
//!
//! The pointer is read by a CAPTURE-phase motion controller on the overlay:
//! a terminal and a WebKit page both sit under it, and a capture-phase
//! controller sees every motion before either child can claim it - the
//! sampling win32 needs for a viewer's out-of-process page is unnecessary
//! here. Hidden, the picture is not visible, so it takes no press from the
//! terminal under it; shown, its whole hit box takes the press (GTK picks by
//! bounds, as win32's alpha-1 hit pixels do).
//!
//! No handle while rearrange mode is on (every pane already wears a header
//! that drags), in a fullscreen window holding a single pane, while the
//! pointer is hidden for typing, or while some other drag is in flight.
const std = @import("std");
const wk = @import("webkit.zig");
const grab = @import("../win32/pane_grab_handle.zig");
const color_math = @import("../win32/color_math.zig");
const PaneDrag = @import("PaneDrag.zig");

const log = std.log.scoped(.gtk_pane_grab);

/// What the pane says about itself each time the handle re-decides.
pub const Env = struct {
    /// Rearrange mode is on, or the window is fullscreen with one pane.
    suppressed: bool,
    /// The pointer is showing (a terminal hides it while you type).
    cursor_visible: bool,
    /// The pane's background, which the engaged capsule stands off.
    pane_bg: color_math.Rgb,
};

pub const EnvFn = *const fn (owner: *anyopaque) Env;

const gtk_phase_capture: c_int = 1;
const gtk_align_start: c_int = 1;
const gtk_align_center: c_int = 3;
const gtk_content_fit_fill: c_int = 0;

/// Geometry in logical pixels: GTK lays out and reports pointer positions
/// in them, and renders the texture at the device scale itself.
const logical = grab.Metrics.forScale(1.0);

pub const Handle = struct {
    /// The surface's overlay the handle sits on and reads the pointer over.
    overlay: *wk.GtkWidget,
    /// The handle itself: a picture of the grip, the size of the hit box.
    pic: *wk.GtkWidget,
    drag: PaneDrag.Source,
    owner: *anyopaque,
    env: EnvFn,
    /// Where the pointer is over the overlay, or null when it is not.
    pointer: ?[2]f64 = null,
    /// This pane is being dragged from its handle.
    dragging: bool = false,
    st: grab.State = .hidden,
    /// What the picture's texture was last rendered for.
    painted: ?Painted = null,

    const Painted = struct { st: grab.State, scale: c_int, bg: color_math.Rgb };

    /// Put a handle on `overlay` for the pane `pane` (a borrow of the
    /// surface's own id buffer, as a header's is).
    pub fn create(alloc: std.mem.Allocator, overlay: *wk.GtkWidget, pane: []const u8, owner: *anyopaque, env: EnvFn) !*Handle {
        const self = try alloc.create(Handle);
        const pic = wk.gtk_picture_new_for_paintable(null);
        wk.gtk_picture_set_content_fit(pic, gtk_content_fit_fill);
        wk.gtk_picture_set_can_shrink(pic, 1);
        wk.gtk_widget_set_size_request(pic, logical.hit_w, logical.hit_h);
        wk.gtk_widget_set_halign(pic, gtk_align_center);
        wk.gtk_widget_set_valign(pic, gtk_align_start);
        wk.gtk_widget_add_css_class(pic, "ghoztty-grab-handle");
        // An open hand over the grip (Mac `NSCursor.openHand`); GTK shows
        // its own closed hand for the drag itself.
        wk.gtk_widget_set_cursor_from_name(pic, "grab");
        wk.gtk_widget_set_tooltip_text(pic, "Drag to move this pane");
        wk.gtk_widget_set_visible(pic, 0);
        self.* = .{ .overlay = overlay, .pic = pic, .drag = undefined, .owner = owner, .env = env };
        self.drag.install(pic, pane);
        self.drag.hooks = .{ .owner = self, .begin = &onDragBegin, .end = &onDragEnd };
        wk.gtk_overlay_add_overlay(overlay, pic);

        const motion = wk.gtk_event_controller_motion_new();
        wk.gtk_event_controller_set_propagation_phase(motion, gtk_phase_capture);
        _ = wk.g_signal_connect_data(motion, "enter", @ptrCast(&onMotion), self, null, 0);
        _ = wk.g_signal_connect_data(motion, "motion", @ptrCast(&onMotion), self, null, 0);
        _ = wk.g_signal_connect_data(motion, "leave", @ptrCast(&onLeave), self, null, 0);
        wk.gtk_widget_add_controller(overlay, motion);
        return self;
    }

    /// The pointer is at `x`,`y` over the pane (the overlay's coordinates):
    /// the motion controller's call, and the `pane-drag --grab-at` seam's.
    pub fn pointerAt(self: *Handle, x: f64, y: f64) void {
        self.pointer = .{ x, y };
        self.refresh();
    }

    /// The pointer left the pane.
    pub fn pointerLeft(self: *Handle) void {
        self.pointer = null;
        self.refresh();
    }

    /// The pane as a rect in its own coordinates.
    fn paneRect(self: *Handle) grab.Rect {
        return .{ .right = wk.gtk_widget_get_width(self.overlay), .bottom = wk.gtk_widget_get_height(self.overlay) };
    }

    /// Where the handle's hit box goes on this pane, or null when the pane
    /// is too small to carry one.
    pub fn planned(self: *Handle) ?grab.Rect {
        const l = grab.layout(self.paneRect(), logical) orelse return null;
        return l.win;
    }

    /// The top band that reveals the grip.
    pub fn band(self: *Handle) grab.Rect {
        return grab.band(self.paneRect(), logical);
    }

    pub fn inputs(self: *Handle) grab.Inputs {
        const e = self.env(self.owner);
        // Another drag in flight (a header, a strip, another pane's handle):
        // a grip lighting up under it would be a second grip on the gesture
        // already in hand. Our own drag is answered by `dragging`.
        const other_drag = PaneDrag.dragged() != null and !self.dragging;
        var in: grab.Inputs = .{
            .cursor_visible = e.cursor_visible,
            .suppressed = e.suppressed or other_drag,
            .dragging = self.dragging,
        };
        const win = self.planned() orelse {
            // Too small for a handle: nothing to hint at or stand on.
            in.dragging = false;
            return in;
        };
        if (self.pointer) |p| {
            const x: i32 = @intFromFloat(@floor(p[0]));
            const y: i32 = @intFromFloat(@floor(p[1]));
            in.pointer_in_band = self.band().contains(x, y);
            in.over_handle = win.contains(x, y);
        }
        return in;
    }

    /// Re-decide what the handle shows, and show it.
    pub fn refresh(self: *Handle) void {
        const in = self.inputs();
        const st = if (self.planned() == null) grab.State.hidden else grab.state(in);
        if (st != self.st) log.debug("grab handle pane={s} {s} -> {s}", .{ self.drag.pane_id, @tagName(self.st), @tagName(st) });
        self.st = st;
        if (st == .hidden) {
            wk.gtk_widget_set_visible(self.pic, 0);
            return;
        }
        self.paint(st, self.env(self.owner).pane_bg);
        wk.gtk_widget_set_visible(self.pic, 1);
    }

    pub fn state(self: *Handle) grab.State {
        return self.st;
    }

    /// The handle as laid out on the last frame, in the pane's coordinates.
    pub fn laidOut(self: *Handle) ?grab.Rect {
        if (wk.gtk_widget_get_visible(self.pic) == 0) return null;
        const r = PaneDrag.rectOf(self.pic, self.overlay) orelse return null;
        return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
    }

    /// Render the grip for `st` into the picture's texture, at the device
    /// scale - only when something it depends on changed.
    fn paint(self: *Handle, st: grab.State, bg: color_math.Rgb) void {
        const scale = @max(wk.gtk_widget_get_scale_factor(self.pic), 1);
        const want: Painted = .{ .st = st, .scale = scale, .bg = bg };
        if (self.painted) |p| if (std.meta.eql(p, want)) return;
        const m = grab.Metrics.forScale(@floatFromInt(scale));
        const l = grab.layout(.{ .right = m.hit_w, .bottom = m.hit_h * 2 }, m) orelse return;
        const w: usize = @intCast(l.win.width());
        const h: usize = @intCast(l.win.height());
        const buf = std.heap.c_allocator.alloc(u32, w * h) catch return;
        defer std.heap.c_allocator.free(buf);
        grab.render(buf, m, l, st, bg);
        const bytes = wk.g_bytes_new(buf.ptr, buf.len * 4);
        defer wk.g_bytes_unref(bytes);
        const tex = wk.gdk_memory_texture_new(@intCast(w), @intCast(h), wk.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, w * 4) orelse return;
        defer wk.g_object_unref(tex);
        wk.gtk_picture_set_paintable(self.pic, tex);
        self.painted = want;
    }

    fn onDragBegin(owner: *anyopaque) void {
        const self: *Handle = @ptrCast(@alignCast(owner));
        self.dragging = true;
        self.refresh();
    }

    fn onDragEnd(owner: *anyopaque) void {
        const self: *Handle = @ptrCast(@alignCast(owner));
        self.dragging = false;
        // Where the pointer is now is the next motion's to say: a drop that
        // moved the pane has it somewhere else entirely.
        self.pointer = null;
        self.refresh();
    }

    fn onMotion(_: *wk.GtkEventController, x: f64, y: f64, self: *Handle) callconv(.c) void {
        self.pointerAt(x, y);
    }

    fn onLeave(_: *wk.GtkEventController, self: *Handle) callconv(.c) void {
        self.pointerLeft();
    }
};
