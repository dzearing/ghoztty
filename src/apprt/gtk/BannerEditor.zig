//! The Set Pane Banner editor on GTK (T3559, Linux L10b): the Mac's Cmd+R
//! "Set Pane Banner..." sheet and win32's `BannerDialog`, as a libadwaita
//! alert dialog over the pane's window.
//!
//! - It opens on `prompt_surface_banner` (Ctrl+Shift+B on Linux - Windows'
//!   chord, since plain Ctrl+R is the shell's reverse history search), filled
//!   with the pane's current banner source.
//! - The text box is multi-line: Return inserts a newline, Ctrl+Return saves,
//!   Escape cancels (`pane_banner_rules.editorKey`), and the Save / Cancel
//!   buttons do the same.
//! - Saving goes through `Surface.setPaneBanner`, the path `+set-banner` and
//!   OSC 7778 take; empty text clears the banner.
//! - One editor at a time: asking again while one is open focuses it, so an
//!   edit in progress is never thrown away for a new one.
//!
//! The dialog is modal to its window, so nothing else in the window takes the
//! keyboard while it is open; the app's main loop (renderer, IPC) runs on.
const BannerEditor = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const wk = @import("webkit.zig");
const rules = @import("pane_banner_rules.zig");
const Surface = @import("class/surface.zig").Surface;

const log = std.log.scoped(.gtk_banner);

alloc: Allocator,
/// The pane whose banner is edited. Held with a reference until the dialog
/// closes, so a pane closed under the dialog is still a valid object.
surface: *Surface,
dialog: *wk.GtkWidget,
view: *wk.GtkWidget,
/// Save or cancel already ran: the response that closing emits is ignored.
done: bool = false,

/// The open editor, if any (one at a time, like win32's per-window one: the
/// dialog is modal, so a second can only come from a script).
var open_editor: ?*BannerEditor = null;

/// The open editor, for the test seam.
pub fn current() ?*BannerEditor {
    return open_editor;
}

/// Open the editor for `surface`'s banner, or focus the one already open.
pub fn open(alloc: Allocator, surface: *Surface) void {
    if (open_editor) |e| {
        _ = wk.gtk_widget_grab_focus(e.view);
        log.info("banner editor: already open pane={s}", .{e.surface.paneId()});
        return;
    }
    const self = alloc.create(BannerEditor) catch return;

    const dialog = wk.adw_alert_dialog_new("Set Pane Banner", "Markdown; a blank banner clears it.");
    wk.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    wk.adw_alert_dialog_add_response(dialog, "save", "Save");
    wk.adw_alert_dialog_set_response_appearance(dialog, "save", wk.adw_response_suggested);
    wk.adw_alert_dialog_set_default_response(dialog, "save");
    wk.adw_alert_dialog_set_close_response(dialog, "cancel");

    const view = wk.gtk_text_view_new();
    wk.gtk_text_view_set_wrap_mode(view, wk.wrap_word_char);
    wk.gtk_text_view_set_monospace(view, 1);
    wk.gtk_text_view_set_accepts_tab(view, 0);
    wk.gtk_widget_add_css_class(view, "pane-banner-editor");
    const initial = surface.getPaneBanner() orelse "";
    const buffer = wk.gtk_text_view_get_buffer(view);
    wk.gtk_text_buffer_set_text(buffer, initial.ptr, @intCast(initial.len));
    // Everything selected, so typing replaces the banner and an arrow key
    // keeps it.
    var start: wk.GtkTextIter = .{};
    var end: wk.GtkTextIter = .{};
    wk.gtk_text_buffer_get_bounds(buffer, &start, &end);
    wk.gtk_text_buffer_select_range(buffer, &start, &end);

    // Capture phase: the text view's own Return handling must not see a
    // Ctrl+Return first.
    const keys = wk.gtk_event_controller_key_new();
    wk.gtk_event_controller_set_propagation_phase(keys, 1); // GTK_PHASE_CAPTURE
    _ = wk.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKeyPressed), self, null, 0);
    wk.gtk_widget_add_controller(view, keys);

    const scroller = wk.gtk_scrolled_window_new();
    wk.gtk_scrolled_window_set_policy(scroller, 2, 0); // never, automatic
    wk.gtk_widget_set_size_request(scroller, 420, 120);
    wk.gtk_widget_add_css_class(scroller, "card");
    wk.gtk_scrolled_window_set_child(scroller, view);

    const hint = wk.gtk_label_new("Return adds a line \u{00b7} Ctrl+Return saves \u{00b7} Escape cancels");
    wk.gtk_widget_add_css_class(hint, "dim-label");
    wk.gtk_widget_add_css_class(hint, "caption");
    wk.gtk_label_set_xalign(hint, 0.0);

    const column = wk.gtk_box_new(1, 6);
    wk.gtk_box_append(column, scroller);
    wk.gtk_box_append(column, hint);
    wk.adw_alert_dialog_set_extra_child(dialog, column);
    wk.adw_dialog_set_focus_widget(dialog, view);

    _ = wk.g_signal_connect_data(dialog, "response", @ptrCast(&onResponse), self, null, 0);
    _ = wk.g_signal_connect_data(dialog, "closed", @ptrCast(&onClosed), self, null, 0);

    _ = wk.g_object_ref(@ptrCast(surface));
    self.* = .{ .alloc = alloc, .surface = surface, .dialog = dialog, .view = view };
    open_editor = self;
    log.info("banner editor: open pane={s} len={d}", .{ surface.paneId(), initial.len });
    wk.adw_dialog_present(dialog, @ptrCast(surface));
}

/// The text box's current contents. Caller frees with `g_free`.
fn rawText(self: *BannerEditor) [*:0]u8 {
    const buffer = wk.gtk_text_view_get_buffer(self.view);
    var start: wk.GtkTextIter = .{};
    var end: wk.GtkTextIter = .{};
    wk.gtk_text_buffer_get_bounds(buffer, &start, &end);
    return wk.gtk_text_buffer_get_text(buffer, &start, &end, 0);
}

/// The text box's contents, copied into `alloc` (the test seam's reply).
pub fn text(self: *BannerEditor, alloc: Allocator) Allocator.Error![]u8 {
    const raw = self.rawText();
    defer wk.g_free(raw);
    return alloc.dupe(u8, std.mem.span(raw));
}

/// Replace the text box's contents (the test seam's typing).
pub fn setText(self: *BannerEditor, value: []const u8) void {
    const buffer = wk.gtk_text_view_get_buffer(self.view);
    wk.gtk_text_buffer_set_text(buffer, value.ptr, @intCast(value.len));
}

/// Apply the text as the pane's banner (empty clears it), or with `save`
/// false drop it. Runs once; the dialog closes itself after a response and
/// is closed here after a key.
fn finish(self: *BannerEditor, save: bool) void {
    if (self.done) return;
    self.done = true;
    if (!save) {
        log.info("banner editor: cancelled pane={s}", .{self.surface.paneId()});
        return;
    }
    const raw = self.rawText();
    defer wk.g_free(raw);
    const value = rules.editorText(std.mem.span(raw));
    log.info("banner editor: saved pane={s} len={d}", .{ self.surface.paneId(), value.len });
    self.surface.setPaneBanner(if (value.len > 0) value else null);
}

/// One key in the text box, as `key-pressed` delivers it. Returns whether
/// it was handled here (a save or a cancel); anything else, plain Return
/// included, is the text view's. The test seam presses keys through this.
pub fn key(self: *BannerEditor, keyval: c_uint, state: c_uint) rules.EditorKey {
    const what = rules.editorKey(keyval, state);
    switch (what) {
        .pass => {},
        .save, .cancel => {
            self.finish(what == .save);
            wk.adw_dialog_force_close(self.dialog);
        },
    }
    return what;
}

fn onKeyPressed(_: *wk.GtkEventController, keyval: c_uint, _: c_uint, state: c_uint, self: *BannerEditor) callconv(.c) c_int {
    return @intFromBool(self.key(keyval, state) != .pass);
}

fn onResponse(_: *wk.GtkWidget, response: [*:0]const u8, self: *BannerEditor) callconv(.c) void {
    self.finish(std.mem.eql(u8, std.mem.span(response), "save"));
}

fn onClosed(_: *wk.GtkWidget, self: *BannerEditor) callconv(.c) void {
    if (open_editor == self) open_editor = null;
    // The dialog has left the window; give the keyboard back to the pane.
    // Only while the pane is still in a window: one closed under the dialog
    // is held alive by our reference alone.
    if (wk.gtk_widget_get_root(@ptrCast(self.surface)) != null) self.surface.grabFocus();
    wk.g_object_unref(@ptrCast(self.surface));
    self.alloc.destroy(self);
}
