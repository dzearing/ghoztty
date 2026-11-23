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
//! now, and the headless harness's screenshot (T3359) next.
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
    const native = wk.gtk_widget_get_native(widget) orelse return null;
    const renderer = wk.gtk_native_get_renderer(native) orelse {
        log.warn("pane snapshot: the window has no renderer", .{});
        return null;
    };

    const paintable = wk.gtk_widget_paintable_new(widget);
    defer wk.g_object_unref(paintable);
    const snapshot = wk.gtk_snapshot_new();
    if (scale > 1) {
        const s: f32 = @floatFromInt(scale);
        wk.gtk_snapshot_scale(snapshot, s, s);
    }
    wk.gdk_paintable_snapshot(paintable, snapshot, @floatFromInt(w), @floatFromInt(h));
    const node = wk.gtk_snapshot_free_to_node(snapshot) orelse {
        log.warn("pane snapshot: the widget drew nothing", .{});
        return null;
    };
    defer wk.gsk_render_node_unref(node);

    const viewport: wk.GrapheneRect = .{ .w = @floatFromInt(size.w), .h = @floatFromInt(size.h) };
    const texture = wk.gsk_renderer_render_texture(renderer, node, &viewport) orelse {
        log.warn("pane snapshot: the renderer produced no texture", .{});
        return null;
    };
    defer wk.g_object_unref(texture);
    return wk.gdk_texture_save_to_png_bytes(texture);
}
