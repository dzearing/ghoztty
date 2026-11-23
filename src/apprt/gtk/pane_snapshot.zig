//! A widget's picture from the app's OWN render (T3546, Linux L9j-4; the
//! linux-port.md translation table's "pane/window screenshots" row).
//!
//! The Mac takes `screencapture`, win32 a region selector over the screen.
//! Wayland gives a client no global capture at all - and the headless Weston
//! the Linux tests run in has nothing a client can ask for either - so the
//! picture comes from GTK itself: the widget's paintable is snapshotted into a
//! render node, the window's own GSK renderer renders that node to a texture,
//! and GDK saves the texture as PNG. A WebKit page is part of that node (the
//! web view snapshots its composited layer like any other child), so a viewer
//! pane's capture is the page as the user sees it.
//!
//! Built once for every caller: the feedback composer's `+` / Ctrl+Shift+S
//! and the headless harness's `capture-pane` seam (T3359, `render`, which
//! also takes a whole window and a requested size).
const std = @import("std");
const wk = @import("webkit.zig");
const shot = @import("viewer_shot.zig");

const log = std.log.scoped(.gtk_viewer);

/// `widget` as it is drawn now, as PNG bytes at device pixels. Null when it
/// has no area, is not in a window, or the renderer could not produce a
/// texture. The caller owns the bytes (`g_bytes_unref`).
pub fn png(widget: *wk.GtkWidget) ?*wk.GBytes {
    const w = wk.gtk_widget_get_width(widget);
    const h = wk.gtk_widget_get_height(widget);
    const scale = wk.gtk_widget_get_scale_factor(widget);
    const size = shot.captureSize(w, h, scale) orelse {
        log.warn("pane snapshot: the widget has no area ({d}x{d})", .{ w, h });
        return null;
    };
    const s: f32 = @floatFromInt(@max(1, scale));
    return render(widget, size.w, size.h, s, s);
}

/// `widget` rendered into an `out_w`x`out_h` PNG, its logical size scaled by
/// `sx`/`sy` (the harness's `capture-pane`, T3359, which may name a size).
/// Null on the same failures as `png`.
pub fn render(widget: *wk.GtkWidget, out_w: u32, out_h: u32, sx: f32, sy: f32) ?*wk.GBytes {
    const w = wk.gtk_widget_get_width(widget);
    const h = wk.gtk_widget_get_height(widget);
    if (w <= 0 or h <= 0 or out_w == 0 or out_h == 0) return null;
    const native = wk.gtk_widget_get_native(widget) orelse return null;
    const renderer = wk.gtk_native_get_renderer(native) orelse {
        log.warn("pane snapshot: the window has no renderer", .{});
        return null;
    };

    const paintable = wk.gtk_widget_paintable_new(widget);
    defer wk.g_object_unref(paintable);
    const snapshot = wk.gtk_snapshot_new();
    if (sx != 1 or sy != 1) wk.gtk_snapshot_scale(snapshot, sx, sy);
    wk.gdk_paintable_snapshot(paintable, snapshot, @floatFromInt(w), @floatFromInt(h));
    const node = wk.gtk_snapshot_free_to_node(snapshot) orelse {
        log.warn("pane snapshot: the widget drew nothing", .{});
        return null;
    };
    defer wk.gsk_render_node_unref(node);

    const viewport: wk.GrapheneRect = .{ .w = @floatFromInt(out_w), .h = @floatFromInt(out_h) };
    const texture = wk.gsk_renderer_render_texture(renderer, node, &viewport) orelse {
        log.warn("pane snapshot: the renderer produced no texture", .{});
        return null;
    };
    defer wk.g_object_unref(texture);
    return wk.gdk_texture_save_to_png_bytes(texture);
}
