//! The remote connection pill on a GTK window (T3675, Linux L11a-3): Mac's
//! `MachinePillView` (the machine capsule plus the connection status), win32's
//! caption-band pill (`remote_pill.zig`, T367/T610/T628). It names the machine
//! a window's panes run on, says when the link to it is retrying or gone, and
//! is the button that brings it back.
//!
//! Every word is win32's: `remote_pill.parts` (the name, then the status
//! appended to it, D93) and `remote_pill.tooltip`, over the ladder state the
//! window's link carries (`RemoteLink.Reconnect`). Only the widgets are GTK's:
//! a header-bar button holding a status dot (or the refresh glyph), the name
//! and the status. The colors are libadwaita's own `success` / `warning`
//! classes on the dot and `destructive-action` on a broken pill - parity is
//! behavior and information, not pixels (docs/design/linux-port.md).
//!
//! A window has TWO: one in the header bar and one in the tab bar's end box,
//! because the `titlebar-style = tabs` layout hides the header bar and draws
//! the window controls in the tab bar. Whichever bar is shown carries it.
//!
//! Click: a broken pill reconnects now (`RemoteReconnect.manualReconnect`).
//! A working one opens the Remote Activity Monitor on Mac and Windows; the GTK
//! app has none yet (T3818), so there it does nothing but say so in the log.
//!
//! GTK main thread only.

const std = @import("std");
const wk = @import("webkit.zig");
const pill_words = @import("../win32/remote_pill.zig");
const RemoteLink = @import("RemoteLink.zig");

const log = std.log.scoped(.gtk_remote_pill);

const orientation_horizontal: c_int = 0;
const pango_ellipsize_end: c_int = 3;
const align_center: c_int = 3;

/// One pill's widgets. Owned by the widget tree they are packed into.
pub const Widgets = struct {
    button: *wk.GtkWidget,
    dot: *wk.GtkWidget,
    glyph: *wk.GtkWidget,
    name: *wk.GtkWidget,
    status: *wk.GtkWidget,
};

/// What the last click on any pill did (the seam reports it).
pub const Click = enum { none, reconnect, activity };
pub var last_click: Click = .none;

/// Build one pill (hidden) and prepend it to `box`. `handler` is the click
/// callback, `data` its user data (the window).
pub fn create(box: *wk.GtkWidget, handler: *const anyopaque, data: *anyopaque) Widgets {
    const button = wk.gtk_button_new();
    wk.gtk_widget_add_css_class(button, "flat");
    wk.gtk_widget_add_css_class(button, "remote-pill");
    wk.gtk_widget_set_focus_on_click(button, 0);
    wk.gtk_widget_set_focusable(button, 0);
    wk.gtk_widget_set_valign(button, align_center);

    const row = wk.gtk_box_new(orientation_horizontal, 4);
    const dot = wk.gtk_label_new("\u{25CF}");
    wk.gtk_widget_add_css_class(dot, "remote-pill-dot");
    const glyph = wk.gtk_image_new_from_icon_name("view-refresh-symbolic");
    const name = wk.gtk_label_new("");
    wk.gtk_label_set_ellipsize(name, pango_ellipsize_end);
    // The name gives way, never the status (remote_pill's module doc): a
    // degraded pill caps it tighter so the widened capsule keeps the tabs.
    wk.gtk_label_set_max_width_chars(name, 18);
    const status = wk.gtk_label_new("");
    inline for (.{ dot, glyph, name, status }) |w| wk.gtk_box_append(row, w);
    wk.gtk_button_set_child(button, row);

    _ = wk.g_signal_connect_data(button, "clicked", handler, data, null, 0);
    wk.gtk_widget_set_visible(button, 0);
    wk.gtk_box_prepend(box, button);
    return .{ .button = button, .dot = dot, .glyph = glyph, .name = name, .status = status };
}

/// Paint `w` for `link` (null: a local window, no pill).
pub fn paint(w: Widgets, link: ?*RemoteLink.Link) void {
    const l = link orelse {
        wk.gtk_widget_set_visible(w.button, 0);
        return;
    };
    const state = l.reconnect.ladder;
    const mode = pill_words.modeFor(state);
    const machine = l.machine.displayName();

    var buf: [pill_words.label_cap]u8 = undefined;
    const p = pill_words.parts(&buf, state, machine);
    var name_z: [pill_words.name_cap + 1]u8 = undefined;
    var status_z: [pill_words.status_cap + 1]u8 = undefined;
    wk.gtk_label_set_text(w.name, zcopy(&name_z, p.name));
    wk.gtk_label_set_text(w.status, zcopy(&status_z, p.status));
    wk.gtk_widget_set_visible(w.status, @intFromBool(p.status.len > 0));
    wk.gtk_label_set_max_width_chars(w.name, if (mode == .connected) 18 else 10);

    const is_dot = pill_words.mark(mode) == .dot;
    wk.gtk_widget_set_visible(w.dot, @intFromBool(is_dot));
    wk.gtk_widget_set_visible(w.glyph, @intFromBool(!is_dot));
    setClass(w.dot, "success", mode == .connected);
    setClass(w.dot, "warning", mode == .reconnecting);
    const action = pill_words.isAction(mode);
    setClass(w.button, "destructive-action", action);
    setClass(w.button, "flat", !action);

    var tip_buf: [pill_words.tooltip_cap + pill_words.name_cap + 1]u8 = undefined;
    const tip = pill_words.tooltip(tip_buf[0 .. tip_buf.len - 1], state, machine);
    tip_buf[tip.len] = 0;
    wk.gtk_widget_set_tooltip_text(w.button, @ptrCast(tip_buf[0..tip.len :0]));
    wk.gtk_widget_set_visible(w.button, 1);
}

/// A click on the pill of a window riding `link`.
pub fn clicked(link: ?*RemoteLink.Link, reconnect: *const fn (*RemoteLink.Link) void) void {
    const l = link orelse return;
    switch (pill_words.clickAction(pill_words.modeFor(l.reconnect.ladder))) {
        .reconnect => {
            last_click = .reconnect;
            log.info("remote pill: reconnect clicked for {s}", .{l.machine.displayName()});
            reconnect(l);
        },
        .activity => {
            last_click = .activity;
            log.info("remote pill: {s} clicked while connected; the Linux app has no Remote Activity Monitor yet (T3818)", .{l.machine.displayName()});
        },
    }
}

fn setClass(w: *wk.GtkWidget, class: [*:0]const u8, on: bool) void {
    if (on) wk.gtk_widget_add_css_class(w, class) else wk.gtk_widget_remove_css_class(w, class);
}

fn zcopy(buf: []u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf[0..n :0]);
}
