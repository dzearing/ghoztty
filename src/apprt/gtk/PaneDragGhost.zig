//! The card a pane drag carries under the pointer on GTK (T3617, Linux
//! L11b5; Mac `PaneDragGhost.swift`, win32 `PaneDragGhost.zig`).
//!
//! A card rather than GTK's default drag icon, for the Mac's reason: a bare
//! snapshot reads as glyphs on nothing at drag size, and the card has to say
//! WHAT is being carried. So it is the pane's background, a title strip with
//! the pane's label, the pane's own content scaled into the body, a rim and a
//! shadow - every number the Mac's, planned by `pane_ghost_rules.zig`.
//!
//! Drawn with `GtkSnapshot` (rounded clip, colour, the content widget's
//! paintable, a Pango layout, outset shadow, border), rendered ONCE to a
//! texture by the window's own GSK renderer at the device scale - so the card
//! is a still picture of the pane at the moment the drag began, the way the
//! Mac's `NSImage` is, and not a live view that would redraw the terminal
//! under the pointer for the whole drag - and handed to
//! `gtk_drag_source_set_icon` with the hot spot in the middle of the title
//! strip.
const std = @import("std");
const wk = @import("webkit.zig");
const rules = @import("pane_ghost_rules.zig");
const ghost = @import("../win32/pane_drag_ghost.zig");

const log = std.log.scoped(.gtk_pane_drag);

pub const Rgb = rules.Rgb;

/// A rendered card. `paintable` is what the drag shows (the texture at the
/// card's logical size); the caller unrefs both.
pub const Built = struct {
    paintable: *wk.GdkPaintable,
    texture: *wk.GdkTexture,
    plan: rules.Plan,
    scale: c_int,

    pub fn deinit(self: Built) void {
        wk.g_object_unref(self.paintable);
        wk.g_object_unref(self.texture);
    }
};

fn rgba(c: Rgb, a: f32) wk.GdkRGBA {
    return .{
        .red = @as(f32, @floatFromInt(c.r)) / 255.0,
        .green = @as(f32, @floatFromInt(c.g)) / 255.0,
        .blue = @as(f32, @floatFromInt(c.b)) / 255.0,
        .alpha = a,
    };
}

fn grect(r: ghost.Rect) wk.GrapheneRect {
    return .{
        .x = @floatFromInt(r.left),
        .y = @floatFromInt(r.top),
        .w = @floatFromInt(r.width()),
        .h = @floatFromInt(r.height()),
    };
}

/// The card for the pane whose content (terminal or viewer page) is
/// `content`, labelled `title`, on the background `bg`. Null when the content
/// is not on screen or the window's renderer cannot draw it; the drag then
/// keeps GTK's own icon.
pub fn build(content: *wk.GtkWidget, title: []const u8, bg: Rgb) ?Built {
    const pw = wk.gtk_widget_get_width(content);
    const ph = wk.gtk_widget_get_height(content);
    const native = wk.gtk_widget_get_native(content) orelse return null;
    const renderer = wk.gtk_native_get_renderer(native) orelse return null;
    const scale = @max(1, wk.gtk_widget_get_scale_factor(content));
    const s: f32 = @floatFromInt(scale);
    const p = rules.plan(pw, ph, bg);
    const lay = p.lay;

    const snap = wk.gtk_snapshot_new();
    if (scale != 1) wk.gtk_snapshot_scale(snap, s, s);

    var card_rr: wk.GskRoundedRect = .{};
    const card_r = grect(lay.card);
    _ = wk.gsk_rounded_rect_init_from_rect(&card_rr, &card_r, lay.radius);

    // The shadow first, under the card: black at 40%, blur 6, dropped 2.
    const shadow = rgba(.{ .r = 0, .g = 0, .b = 0 }, ghost.shadow_alpha);
    wk.gtk_snapshot_append_outset_shadow(snap, &card_rr, &shadow, 0, ghost.shadow_drop_dip, 0, ghost.shadow_blur_dip);

    wk.gtk_snapshot_push_rounded_clip(snap, &card_rr);
    {
        const face = rgba(p.bg, 1);
        wk.gtk_snapshot_append_color(snap, &face, &card_r);

        // The pane's content, covering the body from its top-left (where a
        // fresh prompt is); the overhang is the bottom and the right.
        if (pw > 0 and ph > 0) {
            const body_r = grect(lay.body);
            wk.gtk_snapshot_push_clip(snap, &body_r);
            wk.gtk_snapshot_save(snap);
            wk.gtk_snapshot_translate(snap, &.{ .x = body_r.x, .y = body_r.y });
            const paintable = wk.gtk_widget_paintable_new(content);
            wk.gdk_paintable_snapshot(paintable, snap, @floatFromInt(p.content.w), @floatFromInt(p.content.h));
            wk.g_object_unref(paintable);
            wk.gtk_snapshot_restore(snap);
            wk.gtk_snapshot_pop(snap);
        }

        const strip = rgba(p.strip, 1);
        const strip_r = grect(lay.title);
        wk.gtk_snapshot_append_color(snap, &strip, &strip_r);
        drawTitle(snap, content, title, p);
    }
    wk.gtk_snapshot_pop(snap);

    // The rim: the ink at 18%, one device pixel wide.
    const rim = rgba(p.ink, ghost.rim_alpha);
    const w = 1.0 / s;
    wk.gtk_snapshot_append_border(snap, &card_rr, &.{ w, w, w, w }, &.{ rim, rim, rim, rim });

    const node = wk.gtk_snapshot_free_to_node(snap) orelse return null;
    defer wk.gsk_render_node_unref(node);
    const viewport: wk.GrapheneRect = .{
        .w = @as(f32, @floatFromInt(p.image.w)) * s,
        .h = @as(f32, @floatFromInt(p.image.h)) * s,
    };
    const texture = wk.gsk_renderer_render_texture(renderer, node, &viewport) orelse {
        log.warn("pane drag ghost: the renderer produced no texture", .{});
        return null;
    };

    // The icon: the device-scale texture at the card's LOGICAL size, so a
    // HiDPI display shows it sharp and at the Mac's size.
    const icon = wk.gtk_snapshot_new();
    const bounds: wk.GrapheneRect = .{ .w = @floatFromInt(p.image.w), .h = @floatFromInt(p.image.h) };
    wk.gtk_snapshot_append_texture(icon, texture, &bounds);
    const size: wk.GrapheneSize = .{ .width = bounds.w, .height = bounds.h };
    const paintable = wk.gtk_snapshot_free_to_paintable(icon, &size) orelse {
        wk.g_object_unref(texture);
        return null;
    };
    return .{ .paintable = paintable, .texture = texture, .plan = p, .scale = scale };
}

/// The title in the strip: 10px semibold, inset 8 each side, ellipsized at
/// the end, centred on the strip's height, in the ink at 85% over the strip.
fn drawTitle(snap: *wk.GtkSnapshot, widget: *wk.GtkWidget, title_text: []const u8, p: rules.Plan) void {
    const t = rules.title(title_text);
    if (t.len == 0) return;
    var buf: [256]u8 = undefined;
    const n = @min(t.len, buf.len - 1);
    @memcpy(buf[0..n], t[0..n]);
    buf[n] = 0;

    const layout = wk.gtk_widget_create_pango_layout(widget, @ptrCast(&buf));
    defer wk.g_object_unref(layout);
    const desc = wk.pango_font_description_from_string("Sans Semi-Bold");
    defer wk.pango_font_description_free(desc);
    wk.pango_font_description_set_absolute_size(desc, ghost.title_font_dip * @as(f64, @floatFromInt(wk.pango_scale)));
    wk.pango_layout_set_font_description(layout, desc);
    const inset: i32 = @intFromFloat(ghost.title_inset_dip);
    const avail = @max(1, p.lay.title.width() - 2 * inset);
    wk.pango_layout_set_width(layout, avail * wk.pango_scale);
    wk.pango_layout_set_ellipsize(layout, wk.pango_ellipsize_end);
    var th: c_int = 0;
    wk.pango_layout_get_pixel_size(layout, null, &th);

    wk.gtk_snapshot_save(snap);
    wk.gtk_snapshot_translate(snap, &.{
        .x = @floatFromInt(p.lay.title.left + inset),
        .y = @as(f32, @floatFromInt(p.lay.title.top)) + @as(f32, @floatFromInt(p.lay.title.height() - th)) / 2.0,
    });
    const ink = rgba(p.text, 1);
    wk.gtk_snapshot_append_layout(snap, layout, &ink);
    wk.gtk_snapshot_restore(snap);
}

/// A rendered card's pixels, downloaded once (the `pane-drag --ghost` seam's
/// samples). `deinit` frees them.
pub const Pixels = struct {
    data: []u8,
    w: i32,
    h: i32,
    scale: c_int,

    pub fn of(b: Built) ?Pixels {
        const tw = wk.gdk_texture_get_width(b.texture);
        const th = wk.gdk_texture_get_height(b.texture);
        if (tw <= 0 or th <= 0) return null;
        const stride: usize = @as(usize, @intCast(tw)) * 4;
        const data = std.heap.c_allocator.alloc(u8, stride * @as(usize, @intCast(th))) catch return null;
        // GDK_MEMORY_DEFAULT: B8G8R8A8 premultiplied.
        wk.gdk_texture_download(b.texture, data.ptr, stride);
        return .{ .data = data, .w = tw, .h = th, .scale = b.scale };
    }

    pub fn deinit(self: Pixels) void {
        std.heap.c_allocator.free(self.data);
    }

    /// The pixel at LOGICAL `(x, y)`, unpremultiplied `[r, g, b, a]`.
    pub fn at(self: Pixels, x: i32, y: i32) ?[4]u8 {
        const dx = x * self.scale;
        const dy = y * self.scale;
        if (dx < 0 or dy < 0 or dx >= self.w or dy >= self.h) return null;
        const i = (@as(usize, @intCast(dy)) * @as(usize, @intCast(self.w)) + @as(usize, @intCast(dx))) * 4;
        const a = self.data[i + 3];
        if (a == 0) return .{ 0, 0, 0, 0 };
        const un = struct {
            fn f(v: u8, alpha: u8) u8 {
                return @intCast(@min(255, (@as(u32, v) * 255 + alpha / 2) / alpha));
            }
        }.f;
        return .{ un(self.data[i + 2], a), un(self.data[i + 1], a), un(self.data[i], a), a };
    }
};
