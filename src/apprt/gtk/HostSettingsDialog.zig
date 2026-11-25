//! The "Host Settings" editor on GTK (T3635; Mac `MachineHostSettings.prompt`,
//! win32 `HostSettingsDialog.zig`): the per-host defaults - a working
//! directory and a shell - that NEW remote sessions on one machine start
//! with. Settings > Remote Machines opens it today; the machine chooser's
//! row menu (T3674) is meant to open the same one.
//!
//! An `AdwAlertDialog` (libadwaita's NSAlert): Mac's title, body and
//! buttons, a "Working directory:" field and a "Shell:" field, both with the
//! "Remote default" placeholder, and the shell field's presets
//! (`host_defaults.shell_presets`, Mac's list) behind a drop-down button -
//! Mac's editable combo box, which GTK 4 has no undeprecated widget for.
//! Empty means "use the remote's own default": saving an empty field clears
//! it (`host_defaults.normalize`). Values are REMOTE-native, never checked
//! against this machine.
//!
//! One dialog at a time. Save writes through `host_defaults.update`, keyed on
//! the relay device id, then calls `on_saved` so the caller re-reads the
//! store (Mac bumps `settingsRevision`).
const HostSettingsDialog = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const wk = @import("webkit.zig");
const host_defaults = @import("../win32/host_defaults.zig");

const log = std.log.scoped(.gtk_host_settings);

pub const body =
    "Defaults for new terminals on this machine. Both are values on the remote " ++
    "machine (e.g. wsl.exe or C:\\dev on a Windows host). Leave a field empty " ++
    "to use the remote's own default.";
pub const placeholder = "Remote default";

/// "Host Settings for “name”" (Mac's `messageText`).
pub fn title(buf: []u8, name: []const u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "Host Settings for \u{201c}{s}\u{201d}", .{name}) catch "Host Settings";
}

pub const OnSaved = *const fn (ctx: ?*anyopaque, id: []const u8) void;

gpa: Allocator,
dialog: *wk.GtkWidget,
wd: *wk.GtkWidget,
shell: *wk.GtkWidget,
presets: *wk.GtkWidget,
id_buf: [host_defaults.MAX_KEY_LEN]u8 = undefined,
id_len: usize = 0,
title_buf: [320]u8 = undefined,
title_len: usize = 0,
handlers: [2]c_ulong = .{ 0, 0 },
on_saved: ?OnSaved = null,
ctx: ?*anyopaque = null,
/// What the last answer was ("save" / "cancel"), for the seam.
last_answer: [8]u8 = .{0} ** 8,

var open_dialog: ?*HostSettingsDialog = null;
/// The last answer of a dialog already gone (the seam reads it after).
var last_answer_buf: [8]u8 = .{0} ** 8;

/// The open dialog, for the seam.
pub fn current() ?*HostSettingsDialog {
    return open_dialog;
}

pub fn lastAnswer() []const u8 {
    return std.mem.sliceTo(&last_answer_buf, 0);
}

/// Open the editor over `id`'s stored defaults, on `parent`. Replaces any
/// dialog already open.
pub fn present(
    gpa: Allocator,
    parent: *wk.GtkWidget,
    id: []const u8,
    name: []const u8,
    on_saved: ?OnSaved,
    ctx: ?*anyopaque,
) bool {
    if (id.len == 0 or id.len > host_defaults.MAX_KEY_LEN) return false;
    if (open_dialog) |d| d.close();

    var current_defaults: host_defaults.Resolved = .{};
    host_defaults.lookup(gpa, .{ .relay = id }, &current_defaults);

    const self = gpa.create(HostSettingsDialog) catch return false;
    var tbuf: [320]u8 = undefined;
    const t = title(&tbuf, name);
    self.* = .{
        .gpa = gpa,
        .dialog = wk.adw_alert_dialog_new(t.ptr, body),
        .wd = wk.gtk_entry_new(),
        .shell = wk.gtk_entry_new(),
        .presets = wk.gtk_menu_button_new(),
        .on_saved = on_saved,
        .ctx = ctx,
    };
    @memcpy(self.id_buf[0..id.len], id);
    self.id_len = id.len;
    @memcpy(self.title_buf[0..t.len], t);
    self.title_len = t.len;

    const d = self.dialog;
    wk.adw_alert_dialog_add_response(d, "cancel", "Cancel");
    wk.adw_alert_dialog_add_response(d, "save", "Save");
    wk.adw_alert_dialog_set_response_appearance(d, "save", wk.adw_response_suggested);
    wk.adw_alert_dialog_set_default_response(d, "save");
    wk.adw_alert_dialog_set_close_response(d, "cancel");

    // Mac's two labelled rows: right-aligned labels, then the fields.
    const grid = wk.gtk_grid_new();
    wk.gtk_grid_set_column_spacing(grid, 8);
    wk.gtk_grid_set_row_spacing(grid, 8);
    const wd_label = wk.gtk_label_new("Working directory:");
    wk.gtk_label_set_xalign(wd_label, 1.0);
    const shell_label = wk.gtk_label_new("Shell:");
    wk.gtk_label_set_xalign(shell_label, 1.0);
    wk.gtk_entry_set_placeholder_text(self.wd, placeholder);
    wk.gtk_entry_set_placeholder_text(self.shell, placeholder);
    wk.gtk_widget_set_hexpand(self.wd, 1);
    wk.gtk_widget_set_hexpand(self.shell, 1);
    setText(self.wd, current_defaults.workingDirectory() orelse "");
    setText(self.shell, current_defaults.shell() orelse "");
    // Return in a field is the default response (Save), as in NSAlert.
    _ = wk.g_signal_connect_data(self.wd, "activate", @ptrCast(&onFieldActivate), self, null, 0);
    _ = wk.g_signal_connect_data(self.shell, "activate", @ptrCast(&onFieldActivate), self, null, 0);

    // The presets: a drop-down beside the shell field.
    const list = wk.gtk_box_new(1, 2);
    for (host_defaults.shell_presets, 0..) |p, i| {
        var zb: [64]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zb, "{s}", .{p}) catch continue;
        const b = wk.gtk_button_new_with_label(z.ptr);
        wk.gtk_button_set_has_frame(b, 0);
        wk.g_object_set_data(@ptrCast(b), "ghoztty-preset", @ptrFromInt(i + 1));
        _ = wk.g_signal_connect_data(b, "clicked", @ptrCast(&onPresetClicked), self, null, 0);
        wk.gtk_box_append(list, b);
    }
    const pop = wk.gtk_popover_new();
    wk.gtk_popover_set_child(pop, list);
    wk.gtk_menu_button_set_popover(self.presets, pop);
    wk.gtk_menu_button_set_icon_name(self.presets, "pan-down-symbolic");
    wk.gtk_widget_set_tooltip_text(self.presets, "Common shells");

    wk.gtk_grid_attach(grid, wd_label, 0, 0, 1, 1);
    wk.gtk_grid_attach(grid, self.wd, 1, 0, 2, 1);
    wk.gtk_grid_attach(grid, shell_label, 0, 1, 1, 1);
    wk.gtk_grid_attach(grid, self.shell, 1, 1, 1, 1);
    wk.gtk_grid_attach(grid, self.presets, 2, 1, 1, 1);
    wk.adw_alert_dialog_set_extra_child(d, grid);

    self.handlers = .{
        wk.g_signal_connect_data(d, "response", @ptrCast(&onResponse), self, null, 0),
        wk.g_signal_connect_data(d, "closed", @ptrCast(&onClosed), self, null, 0),
    };
    open_dialog = self;
    @memset(&last_answer_buf, 0);
    wk.adw_dialog_present(d, parent);
    log.info("host settings: opened for {s}", .{id});
    return true;
}

pub fn id(self: *const HostSettingsDialog) []const u8 {
    return self.id_buf[0..self.id_len];
}

pub fn titleText(self: *const HostSettingsDialog) []const u8 {
    return self.title_buf[0..self.title_len];
}

pub fn workingDirectory(self: *const HostSettingsDialog) []const u8 {
    return std.mem.span(wk.gtk_editable_get_text(self.wd));
}

pub fn shellText(self: *const HostSettingsDialog) []const u8 {
    return std.mem.span(wk.gtk_editable_get_text(self.shell));
}

/// Type into a field (the seam's `host-settings-fill`).
pub fn fill(self: *HostSettingsDialog, field: enum { working_directory, shell }, text: []const u8) void {
    setText(if (field == .working_directory) self.wd else self.shell, text);
}

/// Pick the i-th preset, by clicking its button.
pub fn pickPreset(self: *HostSettingsDialog, index: usize) bool {
    const pop = wk.gtk_menu_button_get_popover(self.presets) orelse return false;
    const list = wk.gtk_popover_get_child(pop) orelse return false;
    var child = wk.gtk_widget_get_first_child(list);
    var i: usize = 0;
    while (child) |c| : (i += 1) {
        if (i == index) {
            wk.g_signal_emit_by_name(@ptrCast(c), "clicked");
            return true;
        }
        child = wk.gtk_widget_get_next_sibling(c);
    }
    return false;
}

/// Answer as a button would ("save" / "cancel"), then close.
pub fn answer(self: *HostSettingsDialog, response: [:0]const u8) void {
    wk.g_signal_emit_by_name(@ptrCast(self.dialog), "response", response.ptr);
    self.close();
}

/// Close now. `closed` arrives only after the close animation, so the
/// dialog is forgotten here, its handlers cut first (SettingsConfigFile's
/// confirmation trap).
pub fn close(self: *HostSettingsDialog) void {
    if (open_dialog == self) open_dialog = null;
    const d = self.dialog;
    for (self.handlers) |h| if (h != 0) wk.g_signal_handler_disconnect(@ptrCast(d), h);
    self.handlers = .{ 0, 0 };
    wk.adw_dialog_force_close(d);
    self.gpa.destroy(self);
}

fn setText(entry: *wk.GtkWidget, text: []const u8) void {
    var zb: [host_defaults.MAX_VALUE_LEN + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{text}) catch return;
    wk.gtk_editable_set_text(entry, z.ptr);
}

fn save(self: *HostSettingsDialog) void {
    const key = self.id();
    host_defaults.update(self.gpa, .{ .relay = key }, .{
        .working_directory = self.workingDirectory(),
        .shell = self.shellText(),
    });
    log.info("host settings: saved for {s}", .{key});
    if (self.on_saved) |f| f(self.ctx, key);
}

fn onResponse(_: *wk.GtkWidget, response: [*:0]const u8, self: *HostSettingsDialog) callconv(.c) void {
    const r = std.mem.span(response);
    const n = @min(r.len, last_answer_buf.len - 1);
    @memset(&last_answer_buf, 0);
    @memcpy(last_answer_buf[0..n], r[0..n]);
    if (std.mem.eql(u8, r, "save")) self.save();
}

fn onClosed(_: *wk.GtkWidget, self: *HostSettingsDialog) callconv(.c) void {
    // A person's own answer: the dialog is going, forget it (its handlers
    // die with it, and `close` would force-close a closed dialog).
    if (open_dialog == self) open_dialog = null;
    self.handlers = .{ 0, 0 };
    self.gpa.destroy(self);
}

fn onFieldActivate(_: *wk.GtkWidget, self: *HostSettingsDialog) callconv(.c) void {
    self.answer("save");
}

fn onPresetClicked(b: *wk.GtkWidget, self: *HostSettingsDialog) callconv(.c) void {
    const t = @intFromPtr(wk.g_object_get_data(@ptrCast(b), "ghoztty-preset"));
    if (t == 0 or t > host_defaults.shell_presets.len) return;
    setText(self.shell, host_defaults.shell_presets[t - 1]);
    wk.gtk_menu_button_popdown(self.presets);
}
