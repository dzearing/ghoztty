//! Settings > Advanced's Config file section and the change toast on GTK
//! (T3633, Linux L11g5) - Mac `ConfigFileSection`
//! (`SettingsCustomSections.swift`) and `SettingsToast` (`SettingsView.swift`),
//! win32 `settings_advanced_view.zig`. The words and decisions are win32's
//! pure `settings_advanced.zig`, shared, so the three seats say the same
//! thing; this file only draws them with libadwaita rows.
//!
//! - **The file**: its name (the link's target when it is a link) with a
//!   "loaded" pill, the path with `~` for home, "Open in Editor" and "Show
//!   in Folder" (Mac's "Show in Finder"; `GtkFileLauncher`, the desktop's
//!   file manager with the file selected). A link adds Mac's "A link to X -
//!   Settings writes through it." A problem with the file (unreadable, a
//!   refused undo, a failed restore) is Mac's red notice.
//! - **Every other file Ghostty loads**, in load order, with an "included" or
//!   "also loaded" pill, the sentence saying which one wins, and Open.
//! - **Backups** with Restore...: a menu of the backups, newest first, as
//!   dates, then "Show Backups in Folder"; a pick asks first (Mac's
//!   confirmation dialog), and the restore is itself a change the toast can
//!   undo.
//! - **Current file**: the file as text, monospaced and selectable, in a
//!   scroller capped at Mac's 220 pt.
//! - **The toast** over the foot of the window after every write:
//!   "Saved <change> - applied live[ - backed up first] - Show Change - Undo -
//!   x". Six seconds untouched (unless expanded) and it slides down and fades
//!   (Mac's `.move(edge: .bottom).combined(with: .opacity)`, the only
//!   animated path); the x and Undo take it away at once. Undo is refused
//!   with Mac's changed-since sentence when the file moved on.
const ConfigFile = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const wk = @import("webkit.zig");

const adv = @import("../win32/settings_advanced.zig");
const SettingsModel = @import("../win32/SettingsModel.zig");
const SettingsWindow = @import("SettingsWindow.zig");
const Viewer = @import("Viewer.zig");

const log = std.log.scoped(.gtk_settings);

/// A file Ghostty loads besides the user's own, copied out of the window's
/// `SettingsSources` (which is replaced on every reload).
pub const Source = struct {
    path: []u8,
    kind: adv.SourceKind,

    pub fn name(self: *const Source) []const u8 {
        return std.fs.path.basename(self.path);
    }
};

/// The leaving toast's frames, for the seam: the opacity each one painted.
pub const Trace = struct {
    pub const max = 64;
    alphas: [max]u8 = undefined,
    len: usize = 0,
    /// The exit ran to its end.
    completed: bool = false,
    /// It went without moving (animations off).
    instant: bool = false,

    fn add(self: *Trace, alpha: u8) void {
        if (self.len == max) return;
        self.alphas[self.len] = alpha;
        self.len += 1;
    }

    pub fn frames(self: *const Trace) []const u8 {
        return self.alphas[0..self.len];
    }
};

// --- What the section shows (refreshed on every reload) ---
/// The path with `~` for home.
display_path: []u8 = &.{},
/// The file a link points at, `~`-shortened; null when the file is no link.
target_display: ?[]u8 = null,
/// The name the row shows: the link target's when it is a link (Mac shows
/// `target.lastPathComponent`).
title: []u8 = &.{},
sources: std.ArrayListUnmanaged(Source) = .empty,
/// This config's backups, newest first.
backup_list: [][]u8 = &.{},
/// Debug: what the last shell action would have run, when
/// `GHOZTTY_SETTINGS_SHELL_DRY` is set (win32's seam).
last_shell: ?[]u8 = null,
/// The last Undo's answer, for the seam.
last_undo: ?SettingsModel.UndoResult = null,

// --- Widgets ---
built: bool = false,
group: *wk.GtkWidget = undefined,
file_row: *wk.GtkWidget = undefined,
editor_button: *wk.GtkWidget = undefined,
reveal_button: *wk.GtkWidget = undefined,
link_row: *wk.GtkWidget = undefined,
error_row: *wk.GtkWidget = undefined,
source_rows: std.ArrayListUnmanaged(*wk.GtkWidget) = .empty,
backups_row: *wk.GtkWidget = undefined,
restore_button: *wk.GtkWidget = undefined,
restore_box: *wk.GtkWidget = undefined,
current_row: *wk.GtkWidget = undefined,
current_label: *wk.GtkWidget = undefined,
/// The open Restore confirmation, and the backup it is about.
confirm: ?*wk.GtkWidget = null,
confirm_index: usize = 0,

// --- The toast ---
revealer: *wk.GtkWidget = undefined,
card: *wk.GtkWidget = undefined,
toast_message: *wk.GtkWidget = undefined,
toast_detail: *wk.GtkWidget = undefined,
show_button: *wk.GtkWidget = undefined,
undo_button: *wk.GtkWidget = undefined,
close_button: *wk.GtkWidget = undefined,
diff_box: *wk.GtkWidget = undefined,
refused_label: *wk.GtkWidget = undefined,
/// The model's `change_seq` the toast was last raised for.
toast_seq: u64 = 0,
expanded: bool = false,
refused: bool = false,
toast_ms: u32 = adv.toast_ms,
toast_timer: c_uint = 0,
leave_tick: c_uint = 0,
/// When the timed-out exit started (monotonic us), null when not leaving.
leave_start: ?i64 = null,
trace: Trace = .{},

/// Before the window's widgets go: stop the exit's frame callback and close
/// an open confirmation, whose signals still point at the window.
pub fn teardown(self: *ConfigFile) void {
    if (!self.built) return;
    self.stopLeave();
    if (self.confirm) |d| wk.adw_dialog_force_close(d);
    self.confirm = null;
}

pub fn deinit(self: *ConfigFile, gpa: Allocator) void {
    if (self.toast_timer != 0) _ = wk.g_source_remove(self.toast_timer);
    self.toast_timer = 0;
    self.clearData(gpa);
    self.source_rows.deinit(gpa);
    self.sources.deinit(gpa);
    if (self.last_shell) |l| gpa.free(l);
}

fn clearData(self: *ConfigFile, gpa: Allocator) void {
    gpa.free(self.display_path);
    self.display_path = &.{};
    gpa.free(self.title);
    self.title = &.{};
    if (self.target_display) |t| gpa.free(t);
    self.target_display = null;
    for (self.sources.items) |s| gpa.free(s.path);
    self.sources.clearRetainingCapacity();
    for (self.backup_list) |b| gpa.free(b);
    gpa.free(self.backup_list);
    self.backup_list = &.{};
}

// ---------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------

/// Re-read what the section shows: where the file links to, the other
/// files and the backups. Called at the end of every window reload.
pub fn reload(self: *ConfigFile, w: *SettingsWindow) void {
    const gpa = w.gpa;
    self.clearData(gpa);
    const home = std.posix.getenv("HOME") orelse "";
    self.display_path = adv.tildePath(gpa, w.main_path, home) catch &.{};

    const target = w.store.targetPath(gpa) catch null;
    defer if (target) |t| gpa.free(t);
    if (target) |t| if (!adv.sameNativePath(t, w.main_path)) {
        self.target_display = adv.tildePath(gpa, t, home) catch null;
    };
    self.title = gpa.dupe(u8, std.fs.path.basename(target orelse w.main_path)) catch &.{};

    if (w.sources) |*s| {
        if (adv.otherSources(gpa, s, w.main_path, target orelse w.main_path)) |others| {
            defer gpa.free(others);
            for (others) |src| {
                const p = gpa.dupe(u8, src.path) catch continue;
                self.sources.append(gpa, .{ .path = p, .kind = adv.sourceKind(src) }) catch gpa.free(p);
            }
        } else |_| {}
    }

    if (w.store.backups(gpa)) |list| {
        self.backup_list = list;
    } else |err| log.warn("settings: listing backups failed err={}", .{err});
}

pub fn backups(self: *const ConfigFile) []const []const u8 {
    return @ptrCast(self.backup_list);
}

// ---------------------------------------------------------------------
// Building
// ---------------------------------------------------------------------

fn caption(text: [*:0]const u8) *wk.GtkWidget {
    const l = wk.gtk_label_new(text);
    wk.gtk_widget_add_css_class(l, "caption");
    wk.gtk_label_set_xalign(l, 0.0);
    return l;
}

/// A small capsule label ("loaded", "included").
fn pill(text: [*:0]const u8, accent: bool) *wk.GtkWidget {
    const l = caption(text);
    wk.gtk_widget_add_css_class(l, "settings-pill");
    if (accent) wk.gtk_widget_add_css_class(l, "accent") else wk.gtk_widget_add_css_class(l, "dim-label");
    wk.gtk_widget_set_valign(l, 3);
    return l;
}

fn button(w: *SettingsWindow, label: [*:0]const u8, handler: *const anyopaque) *wk.GtkWidget {
    const b = wk.gtk_button_new_with_label(label);
    wk.gtk_widget_set_valign(b, 3); // center
    _ = wk.g_signal_connect_data(b, "clicked", handler, w, null, 0);
    return b;
}

/// The Config file group, for Advanced's column.
pub fn build(self: *ConfigFile, w: *SettingsWindow) *wk.GtkWidget {
    const group = wk.adw_preferences_group_new();
    wk.adw_preferences_group_set_title(group, "Config file");
    self.group = group;

    // The file Settings writes.
    self.file_row = wk.adw_action_row_new();
    wk.adw_preferences_row_set_use_markup(self.file_row, 0);
    wk.adw_action_row_add_suffix(self.file_row, pill("loaded", true));
    self.editor_button = button(w, "Open in Editor", @ptrCast(&onEditorClicked));
    self.reveal_button = button(w, "Show in Folder", @ptrCast(&onRevealClicked));
    wk.adw_action_row_add_suffix(self.file_row, self.editor_button);
    wk.adw_action_row_add_suffix(self.file_row, self.reveal_button);
    wk.adw_preferences_group_add(group, self.file_row);

    self.link_row = wk.adw_action_row_new();
    wk.adw_preferences_row_set_use_markup(self.link_row, 0);
    wk.adw_preferences_row_set_title(self.link_row, "Link");
    wk.adw_preferences_group_add(group, self.link_row);

    self.error_row = wk.adw_action_row_new();
    wk.adw_preferences_row_set_use_markup(self.error_row, 0);
    wk.gtk_widget_add_css_class(self.error_row, "error");
    wk.adw_preferences_group_add(group, self.error_row);

    // Backups, then the current file - in a second group, so the source
    // rows (rebuilt on every refresh) stay last in the first.
    self.backups_row = wk.adw_action_row_new();
    wk.adw_preferences_row_set_use_markup(self.backups_row, 0);
    wk.adw_preferences_row_set_title(self.backups_row, "Backups");
    self.restore_button = wk.gtk_menu_button_new();
    wk.gtk_menu_button_set_label(self.restore_button, "Restore\u{2026}");
    wk.gtk_widget_set_valign(self.restore_button, 3);
    const popover = wk.gtk_popover_new();
    self.restore_box = wk.gtk_box_new(1, 0);
    wk.gtk_popover_set_child(popover, self.restore_box);
    wk.gtk_menu_button_set_popover(self.restore_button, popover);
    wk.adw_action_row_add_suffix(self.backups_row, self.restore_button);

    self.current_row = wk.adw_expander_row_new();
    wk.adw_preferences_row_set_use_markup(self.current_row, 0);
    wk.adw_preferences_row_set_title(self.current_row, "Current file");
    self.current_label = wk.gtk_label_new("");
    wk.gtk_widget_add_css_class(self.current_label, "monospace");
    wk.gtk_label_set_xalign(self.current_label, 0.0);
    wk.gtk_widget_set_valign(self.current_label, 1); // start
    wk.gtk_label_set_selectable(self.current_label, 1);
    wk.gtk_widget_set_margin_start(self.current_label, 8);
    wk.gtk_widget_set_margin_end(self.current_label, 8);
    wk.gtk_widget_set_margin_top(self.current_label, 8);
    wk.gtk_widget_set_margin_bottom(self.current_label, 8);
    const scroller = wk.gtk_scrolled_window_new();
    wk.gtk_scrolled_window_set_policy(scroller, 0, 0); // automatic both ways
    wk.gtk_scrolled_window_set_propagate_natural_height(scroller, 1);
    wk.gtk_scrolled_window_set_max_content_height(scroller, 220);
    wk.gtk_scrolled_window_set_child(scroller, self.current_label);
    wk.adw_expander_row_add_row(self.current_row, scroller);

    self.built = true;
    return group;
}

/// The second group: Backups and Current file.
pub fn buildBackups(self: *ConfigFile) *wk.GtkWidget {
    const group = wk.adw_preferences_group_new();
    wk.adw_preferences_group_add(group, self.backups_row);
    wk.adw_preferences_group_add(group, self.current_row);
    return group;
}

/// The toast, as an overlay over the foot of the window. It starts hidden.
pub fn buildToast(self: *ConfigFile, w: *SettingsWindow) *wk.GtkWidget {
    self.revealer = wk.gtk_revealer_new();
    wk.gtk_revealer_set_transition_type(self.revealer, wk.revealer_slide_up);
    wk.gtk_revealer_set_transition_duration(self.revealer, 0);
    wk.gtk_widget_set_halign(self.revealer, 3); // center
    wk.gtk_widget_set_valign(self.revealer, 2); // end
    wk.gtk_widget_set_margin_bottom(self.revealer, 14);
    wk.gtk_widget_set_margin_start(self.revealer, 14);
    wk.gtk_widget_set_margin_end(self.revealer, 14);

    self.card = wk.gtk_box_new(1, 6);
    wk.gtk_widget_add_css_class(self.card, "card");
    wk.gtk_widget_add_css_class(self.card, "settings-toast");

    const line = wk.gtk_box_new(0, 12);
    wk.gtk_widget_set_margin_start(line, 14);
    wk.gtk_widget_set_margin_end(line, 8);
    wk.gtk_widget_set_margin_top(line, 6);
    wk.gtk_widget_set_margin_bottom(line, 6);
    const tick = wk.gtk_label_new("\u{2714}");
    wk.gtk_widget_add_css_class(tick, "success");
    wk.gtk_box_append(line, tick);
    self.toast_message = wk.gtk_label_new("");
    wk.gtk_widget_add_css_class(self.toast_message, "heading");
    wk.gtk_label_set_ellipsize(self.toast_message, 3); // end
    wk.gtk_label_set_max_width_chars(self.toast_message, 48);
    wk.gtk_label_set_xalign(self.toast_message, 0.0);
    wk.gtk_box_append(line, self.toast_message);
    self.toast_detail = wk.gtk_label_new("");
    wk.gtk_widget_add_css_class(self.toast_detail, "dim-label");
    wk.gtk_widget_set_hexpand(self.toast_detail, 1);
    wk.gtk_label_set_xalign(self.toast_detail, 0.0);
    wk.gtk_box_append(line, self.toast_detail);
    self.show_button = button(w, "Show Change", @ptrCast(&onShowClicked));
    self.undo_button = button(w, "Undo", @ptrCast(&onUndoClicked));
    for ([_]*wk.GtkWidget{ self.show_button, self.undo_button }) |b| {
        wk.gtk_widget_add_css_class(b, "flat");
        wk.gtk_widget_add_css_class(b, "accent");
        wk.gtk_box_append(line, b);
    }
    self.close_button = wk.gtk_button_new_from_icon_name("window-close-symbolic");
    wk.gtk_widget_add_css_class(self.close_button, "flat");
    wk.gtk_widget_add_css_class(self.close_button, "circular");
    wk.gtk_widget_set_valign(self.close_button, 3);
    wk.gtk_widget_set_tooltip_text(self.close_button, "Dismiss");
    _ = wk.g_signal_connect_data(self.close_button, "clicked", @ptrCast(&onDismissClicked), w, null, 0);
    wk.gtk_box_append(line, self.close_button);
    wk.gtk_box_append(self.card, line);

    self.diff_box = wk.gtk_box_new(1, 1);
    wk.gtk_widget_set_margin_start(self.diff_box, 14);
    wk.gtk_widget_set_margin_end(self.diff_box, 14);
    wk.gtk_widget_set_margin_bottom(self.diff_box, 8);
    wk.gtk_box_append(self.card, self.diff_box);
    self.refused_label = caption(SettingsModel.changed_since_message);
    wk.gtk_widget_add_css_class(self.refused_label, "error");
    wk.gtk_widget_set_margin_start(self.refused_label, 14);
    wk.gtk_widget_set_margin_end(self.refused_label, 14);
    wk.gtk_widget_set_margin_bottom(self.refused_label, 8);
    wk.gtk_box_append(self.card, self.refused_label);

    wk.gtk_revealer_set_child(self.revealer, self.card);
    wk.gtk_revealer_set_reveal_child(self.revealer, 0);
    return self.revealer;
}

// ---------------------------------------------------------------------
// Refreshing (after every reload, on the window's idle redraw)
// ---------------------------------------------------------------------

fn z(arena: Allocator, s: []const u8) [:0]const u8 {
    return arena.dupeZ(u8, s) catch "";
}

pub fn refresh(self: *ConfigFile, w: *SettingsWindow) void {
    if (!self.built) return;
    var arena_state = std.heap.ArenaAllocator.init(w.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    wk.adw_preferences_row_set_title(self.file_row, z(arena, self.title).ptr);
    wk.adw_action_row_set_subtitle(self.file_row, z(arena, self.display_path).ptr);
    if (self.target_display) |t| {
        const note = std.fmt.allocPrint(arena, "A link to {s} \u{2014} Settings writes through it.", .{t}) catch "";
        wk.adw_action_row_set_subtitle(self.link_row, z(arena, note).ptr);
        wk.gtk_widget_set_visible(self.link_row, 1);
    } else wk.gtk_widget_set_visible(self.link_row, 0);
    if (w.model.file_error) |err| {
        const note = std.fmt.allocPrint(arena, "\u{26A0} {s}", .{err}) catch "";
        wk.adw_preferences_row_set_title(self.error_row, z(arena, note).ptr);
        wk.gtk_widget_set_visible(self.error_row, 1);
    } else wk.gtk_widget_set_visible(self.error_row, 0);

    // Every other file Ghostty loads, in load order.
    for (self.source_rows.items) |r| wk.adw_preferences_group_remove(self.group, r);
    self.source_rows.clearRetainingCapacity();
    for (self.sources.items, 0..) |*s, i| {
        const row = wk.adw_action_row_new();
        wk.adw_preferences_row_set_use_markup(row, 0);
        wk.adw_preferences_row_set_title(row, z(arena, s.name()).ptr);
        wk.adw_action_row_set_subtitle(row, z(arena, s.kind.note()).ptr);
        wk.adw_action_row_add_suffix(row, pill(z(arena, s.kind.tag()).ptr, false));
        const open = button(w, "Open", @ptrCast(&onOpenSourceClicked));
        tag(open, i);
        wk.adw_action_row_add_suffix(row, open);
        wk.adw_preferences_group_add(self.group, row);
        self.source_rows.append(w.gpa, row) catch {};
    }

    // Backups: the caption, and Restore...'s menu.
    wk.adw_action_row_set_subtitle(self.backups_row, z(arena, adv.backupsNote(w.store.backup_path != null)).ptr);
    while (wk.gtk_widget_get_first_child(self.restore_box)) |c| wk.gtk_box_remove(self.restore_box, c);
    if (self.backup_list.len == 0) {
        const none = wk.gtk_label_new("No backups yet");
        wk.gtk_widget_set_sensitive(none, 0);
        wk.gtk_widget_set_margin_start(none, 10);
        wk.gtk_widget_set_margin_end(none, 10);
        wk.gtk_widget_set_margin_top(none, 6);
        wk.gtk_widget_set_margin_bottom(none, 6);
        wk.gtk_box_append(self.restore_box, none);
    }
    var label_buf: [64]u8 = undefined;
    for (self.backup_list, 0..) |b, i| {
        const item = button(w, z(arena, adv.backupLabel(&label_buf, b)).ptr, @ptrCast(&onBackupPicked));
        menuItem(item);
        tag(item, i);
        wk.gtk_box_append(self.restore_box, item);
    }
    if (self.backup_list.len > 0) {
        wk.gtk_box_append(self.restore_box, wk.gtk_separator_new(0));
        const folder = button(w, "Show Backups in Folder", @ptrCast(&onBackupsFolderClicked));
        menuItem(folder);
        wk.gtk_box_append(self.restore_box, folder);
    }

    // The current file.
    const text = w.file.string(arena) catch "";
    wk.gtk_label_set_text(self.current_label, z(arena, if (text.len == 0) "(empty)" else std.mem.trimRight(u8, text, "\r\n")).ptr);

    self.refreshToast(w, arena);
}

fn menuItem(b: *wk.GtkWidget) void {
    wk.gtk_widget_add_css_class(b, "flat");
    if (wk.gtk_widget_get_first_child(b)) |l| wk.gtk_label_set_xalign(l, 0.0);
}

fn tag(widget: *wk.GtkWidget, index: usize) void {
    wk.g_object_set_data(@ptrCast(widget), "settings-config-index", @ptrFromInt(index + 1));
}

fn tagOf(widget: *wk.GtkWidget) ?usize {
    const t = @intFromPtr(wk.g_object_get_data(@ptrCast(widget), "settings-config-index"));
    return if (t == 0) null else t - 1;
}

// ---------------------------------------------------------------------
// The toast
// ---------------------------------------------------------------------

fn refreshToast(self: *ConfigFile, w: *SettingsWindow, arena: Allocator) void {
    const change = w.model.last_change orelse {
        // Gone (Undo, the x): at once, unless the timed exit is playing.
        if (self.leave_start == null) self.hideNow();
        return;
    };
    if (w.model.change_seq != self.toast_seq) {
        // A new change: a fresh, collapsed toast and a fresh six seconds -
        // shown at once, even over one that is sliding away (Mac raises it
        // outside any animation).
        self.toast_seq = w.model.change_seq;
        self.expanded = false;
        self.refused = false;
        self.stopLeave();
        self.restartTimer(w);
    }
    wk.gtk_label_set_text(self.toast_message, z(arena, change.message).ptr);
    wk.gtk_label_set_text(self.toast_detail, z(arena, adv.toastDetail(change.backed_up_to != null)).ptr);
    wk.gtk_button_set_label(self.show_button, if (self.expanded) "Hide Change" else "Show Change");

    while (wk.gtk_widget_get_first_child(self.diff_box)) |c| wk.gtk_box_remove(self.diff_box, c);
    if (self.expanded) {
        for (change.removed) |l| self.diffLine(arena, "\u{2212} ", l, "error");
        for (change.added) |l| self.diffLine(arena, "+ ", l, "success");
    }
    wk.gtk_widget_set_visible(self.diff_box, @intFromBool(self.expanded));
    wk.gtk_widget_set_visible(self.refused_label, @intFromBool(self.refused));

    if (self.leave_start == null) {
        wk.gtk_widget_set_opacity(self.card, 1.0);
        wk.gtk_widget_set_can_target(self.card, 1);
        wk.gtk_revealer_set_transition_duration(self.revealer, 0);
        wk.gtk_revealer_set_reveal_child(self.revealer, 1);
    }
}

fn diffLine(self: *ConfigFile, arena: Allocator, prefix: []const u8, line: []const u8, class: [*:0]const u8) void {
    const text = std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, line }) catch return;
    const l = caption(z(arena, text).ptr);
    wk.gtk_widget_add_css_class(l, "monospace");
    wk.gtk_widget_add_css_class(l, class);
    wk.gtk_label_set_selectable(l, 1);
    wk.gtk_label_set_ellipsize(l, 3);
    wk.gtk_box_append(self.diff_box, l);
}

fn restartTimer(self: *ConfigFile, w: *SettingsWindow) void {
    if (self.toast_timer != 0) _ = wk.g_source_remove(self.toast_timer);
    self.toast_timer = wk.g_timeout_add(self.toast_ms, @ptrCast(&onToastTimeout), w);
}

fn cancelTimer(self: *ConfigFile) void {
    if (self.toast_timer != 0) _ = wk.g_source_remove(self.toast_timer);
    self.toast_timer = 0;
}

fn hideNow(self: *ConfigFile) void {
    wk.gtk_revealer_set_transition_duration(self.revealer, 0);
    wk.gtk_revealer_set_reveal_child(self.revealer, 0);
}

fn stopLeave(self: *ConfigFile) void {
    if (self.leave_tick != 0) wk.gtk_widget_remove_tick_callback(self.revealer, self.leave_tick);
    self.leave_tick = 0;
    self.leave_start = null;
}

/// Does the toast move? The desktop's animation setting decides
/// (libadwaita reads `gtk-enable-animations`).
pub fn animates(self: *const ConfigFile) bool {
    return wk.adw_get_enable_animations(self.card) != 0;
}

pub fn leaving(self: *const ConfigFile) bool {
    return self.leave_start != null;
}

pub fn shown(self: *const ConfigFile) bool {
    return wk.gtk_revealer_get_reveal_child(self.revealer) != 0;
}

/// The six seconds are up: slide down and fade (Mac's `withAnimation {
/// dismissLastChange() }`), or go at once when animations are off. An
/// expanded toast stays until dismissed, as on Mac.
fn onToastTimeout(w: *SettingsWindow) callconv(.c) c_int {
    const self = &w.config_file;
    self.toast_timer = 0;
    if (self.expanded or w.model.last_change == null) return 0;
    self.trace = .{};
    if (!self.animates()) {
        self.trace.instant = true;
        self.dismiss(w);
        return 0;
    }
    self.leave_start = wk.g_get_monotonic_time();
    // Not a target while it leaves, as a SwiftUI view in its removal
    // transition is not.
    wk.gtk_widget_set_can_target(self.card, 0);
    wk.gtk_revealer_set_transition_duration(self.revealer, adv.toast_leave_ms);
    wk.gtk_revealer_set_reveal_child(self.revealer, 0);
    // On the revealer, which stays mapped: the card is unmapped the moment
    // the slide ends, and a frame callback on it would stop short.
    self.leave_tick = wk.gtk_widget_add_tick_callback(self.revealer, &onLeaveTick, w, null);
    log.info("settings: toast leaving", .{});
    return 0; // G_SOURCE_REMOVE
}

fn onLeaveTick(_: *wk.GtkWidget, _: *wk.GdkFrameClock, data: ?*anyopaque) callconv(.c) c_int {
    const w: *SettingsWindow = @ptrCast(@alignCast(data orelse return 0));
    const self = &w.config_file;
    const start = self.leave_start orelse {
        self.leave_tick = 0;
        return 0;
    };
    const elapsed: u64 = @intCast(@max(0, @divTrunc(wk.g_get_monotonic_time() - start, 1000)));
    // The revealer carries the slide; this is its fade, on the same curve
    // win32 paints (`toastLeave`'s alpha).
    const frame = adv.toastLeave(elapsed, wk.gtk_widget_get_height(self.card));
    wk.gtk_widget_set_opacity(self.card, @as(f64, @floatFromInt(frame.alpha)) / 255.0);
    self.trace.add(frame.alpha);
    if (!frame.done) return 1; // G_SOURCE_CONTINUE
    self.leave_tick = 0;
    self.leave_start = null;
    self.trace.completed = true;
    self.dismiss(w);
    return 0;
}

/// The x, and the end of the timed exit.
pub fn dismiss(self: *ConfigFile, w: *SettingsWindow) void {
    self.cancelTimer();
    self.stopLeave();
    w.model.dismissLastChange();
    self.expanded = false;
    self.refused = false;
    self.hideNow();
    log.info("settings: toast dismissed", .{});
}

/// Show Change / Hide Change. An expanded toast stays up: Mac's six
/// seconds dismiss only a collapsed one, and collapsing does not restart them.
pub fn toggleChange(self: *ConfigFile, w: *SettingsWindow) void {
    if (w.model.last_change == null) return;
    self.expanded = !self.expanded;
    var arena_state = std.heap.ArenaAllocator.init(w.gpa);
    defer arena_state.deinit();
    self.refreshToast(w, arena_state.allocator());
}

/// The toast's Undo. Refused (and the file left alone) when it changed
/// after Settings wrote it; the toast then says so and stays.
pub fn undo(self: *ConfigFile, w: *SettingsWindow) SettingsModel.UndoResult {
    const result = w.model.undoLastChange() catch .failed;
    self.last_undo = result;
    self.refused = result == .changed_since;
    self.stopLeave();
    if (result == .changed_since) {
        self.expanded = false;
        self.cancelTimer();
    }
    if (w.model.last_change == null) self.hideNow();
    log.info("settings: undo result={s}", .{@tagName(result)});
    w.afterChange();
    return result;
}

// ---------------------------------------------------------------------
// The section's actions
// ---------------------------------------------------------------------

/// Launch `verb` on `path`: in a debug build with `GHOZTTY_SETTINGS_SHELL_DRY`
/// set, record "<verb> <path>" instead (win32's seam, so a test checks what
/// would open without opening anything).
fn shell(self: *ConfigFile, w: *SettingsWindow, comptime verb: enum { editor, open, reveal, folder }, path: []const u8) void {
    if (comptime build_config.is_debug) {
        if (std.posix.getenv("GHOZTTY_SETTINGS_SHELL_DRY") != null) {
            if (self.last_shell) |l| w.gpa.free(l);
            self.last_shell = std.fmt.allocPrint(w.gpa, "{s} {s}", .{ @tagName(verb), path }) catch null;
            log.info("settings: shell (dry) {s} {s}", .{ @tagName(verb), path });
            return;
        }
    }
    switch (verb) {
        .editor, .open => w.app.openTextFile(path),
        .reveal => Viewer.revealPathFrom(w.window, path),
        .folder => {
            var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const zp = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return;
            std.fs.cwd().makePath(path) catch {};
            const file = wk.g_file_new_for_path(zp.ptr);
            defer wk.g_object_unref(file);
            const launcher = wk.gtk_file_launcher_new(file);
            wk.gtk_file_launcher_launch(launcher, w.window, null, &onLaunchDone, null);
        },
    }
}

fn onLaunchDone(source: ?*wk.GObject, result: *wk.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const launcher: *wk.GtkFileLauncher = @ptrCast(source orelse return);
    defer wk.g_object_unref(launcher);
    var err: ?*wk.GError = null;
    if (wk.gtk_file_launcher_launch_finish(launcher, result, &err) == 0) {
        if (err) |e| {
            defer wk.g_error_free(e);
            log.warn("settings: opening the backups folder failed: {s}", .{std.mem.span(e.message orelse "?")});
        }
    }
}

pub fn openEditor(self: *ConfigFile, w: *SettingsWindow) void {
    self.shell(w, .editor, w.main_path);
}

pub fn revealFile(self: *ConfigFile, w: *SettingsWindow) void {
    self.shell(w, .reveal, w.main_path);
}

pub fn openSource(self: *ConfigFile, w: *SettingsWindow, index: usize) bool {
    if (index >= self.sources.items.len) return false;
    self.shell(w, .open, self.sources.items[index].path);
    return true;
}

pub fn showBackupsFolder(self: *ConfigFile, w: *SettingsWindow) void {
    self.shell(w, .folder, w.store.backup_dir);
}

/// Put backup `index` (newest first) back - the confirmed half of
/// Restore... It is itself a change, so the toast offers its Undo.
pub fn restoreBackupAt(self: *ConfigFile, w: *SettingsWindow, index: usize) bool {
    if (index >= self.backup_list.len) return false;
    const path = w.gpa.dupe(u8, self.backup_list[index]) catch return false;
    defer w.gpa.free(path);
    const ok = w.model.restoreBackup(path) catch false;
    log.info("settings: restore {s} ok={}", .{ path, ok });
    w.afterChange();
    return ok;
}

/// A Restore... pick: ask first, as Mac's confirmation dialog does.
pub fn askRestore(self: *ConfigFile, w: *SettingsWindow, index: usize) bool {
    if (index >= self.backup_list.len) return false;
    if (self.confirm) |d| wk.adw_dialog_force_close(d);
    var label_buf: [64]u8 = undefined;
    var prompt_buf: [256]u8 = undefined;
    var zbuf: [260]u8 = undefined;
    const prompt = adv.restorePrompt(&prompt_buf, adv.backupLabel(&label_buf, self.backup_list[index]));
    const zp = std.fmt.bufPrintZ(&zbuf, "{s}", .{prompt}) catch return false;
    const dialog = wk.adw_alert_dialog_new(adv.restore_title, zp.ptr);
    wk.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    wk.adw_alert_dialog_add_response(dialog, "restore", "Restore");
    wk.adw_alert_dialog_set_response_appearance(dialog, "restore", wk.adw_response_destructive);
    wk.adw_alert_dialog_set_default_response(dialog, "cancel");
    wk.adw_alert_dialog_set_close_response(dialog, "cancel");
    _ = wk.g_signal_connect_data(dialog, "response", @ptrCast(&onConfirmResponse), w, null, 0);
    _ = wk.g_signal_connect_data(dialog, "closed", @ptrCast(&onConfirmClosed), w, null, 0);
    self.confirm = dialog;
    self.confirm_index = index;
    wk.adw_dialog_present(dialog, w.window);
    return true;
}

/// Answer the open confirmation as its button would (the seam's
/// `restore-answer`).
pub fn answerRestore(self: *ConfigFile, response: [:0]const u8) bool {
    const d = self.confirm orelse return false;
    wk.g_signal_emit_by_name(@ptrCast(d), "response", response.ptr);
    if (self.confirm) |still| wk.adw_dialog_force_close(still);
    return true;
}

pub fn toggleCurrentFile(self: *ConfigFile) void {
    wk.adw_expander_row_set_expanded(self.current_row, @intFromBool(wk.adw_expander_row_get_expanded(self.current_row) == 0));
}

pub fn showFile(self: *const ConfigFile) bool {
    return wk.adw_expander_row_get_expanded(self.current_row) != 0;
}

// ---------------------------------------------------------------------
// Signals
// ---------------------------------------------------------------------

fn onEditorClicked(_: *wk.GtkWidget, w: *SettingsWindow) callconv(.c) void {
    w.config_file.openEditor(w);
}

fn onRevealClicked(_: *wk.GtkWidget, w: *SettingsWindow) callconv(.c) void {
    w.config_file.revealFile(w);
}

fn onOpenSourceClicked(b: *wk.GtkWidget, w: *SettingsWindow) callconv(.c) void {
    _ = w.config_file.openSource(w, tagOf(b) orelse return);
}

fn onBackupPicked(b: *wk.GtkWidget, w: *SettingsWindow) callconv(.c) void {
    wk.gtk_menu_button_popdown(w.config_file.restore_button);
    _ = w.config_file.askRestore(w, tagOf(b) orelse return);
}

fn onBackupsFolderClicked(_: *wk.GtkWidget, w: *SettingsWindow) callconv(.c) void {
    wk.gtk_menu_button_popdown(w.config_file.restore_button);
    w.config_file.showBackupsFolder(w);
}

fn onConfirmResponse(_: *wk.GtkWidget, response: [*:0]const u8, w: *SettingsWindow) callconv(.c) void {
    const self = &w.config_file;
    if (std.mem.eql(u8, std.mem.span(response), "restore")) _ = self.restoreBackupAt(w, self.confirm_index);
}

fn onConfirmClosed(_: *wk.GtkWidget, w: *SettingsWindow) callconv(.c) void {
    w.config_file.confirm = null;
}

fn onShowClicked(_: *wk.GtkWidget, w: *SettingsWindow) callconv(.c) void {
    w.config_file.toggleChange(w);
}

fn onUndoClicked(_: *wk.GtkWidget, w: *SettingsWindow) callconv(.c) void {
    _ = w.config_file.undo(w);
}

fn onDismissClicked(_: *wk.GtkWidget, w: *SettingsWindow) callconv(.c) void {
    w.config_file.dismiss(w);
}

/// The seam: click a section or toast button by name, through its own
/// `clicked` signal.
pub fn click(self: *ConfigFile, which: enum { editor, reveal, show, undo, dismiss, folder }) void {
    const b = switch (which) {
        .editor => self.editor_button,
        .reveal => self.reveal_button,
        .show => self.show_button,
        .undo => self.undo_button,
        .dismiss => self.close_button,
        .folder => {
            // The menu's last item.
            var last: ?*wk.GtkWidget = null;
            var c = wk.gtk_widget_get_first_child(self.restore_box);
            while (c) |cur| : (c = wk.gtk_widget_get_next_sibling(cur)) last = cur;
            if (last) |l| if (self.backup_list.len > 0) wk.g_signal_emit_by_name(@ptrCast(l), "clicked");
            return;
        },
    };
    wk.g_signal_emit_by_name(@ptrCast(b), "clicked");
}

/// The seam: a source row's Open, or a Restore... menu item, by index.
pub fn clickIndexed(self: *ConfigFile, which: enum { source, backup }, index: usize) bool {
    switch (which) {
        .source => {
            if (index >= self.source_rows.items.len) return false;
            const b = findTagged(self.source_rows.items[index], index) orelse return false;
            wk.g_signal_emit_by_name(@ptrCast(b), "clicked");
        },
        .backup => {
            if (index >= self.backup_list.len) return false;
            const b = findTagged(self.restore_box, index) orelse return false;
            wk.g_signal_emit_by_name(@ptrCast(b), "clicked");
        },
    }
    return true;
}

/// The descendant of `root` tagged `index` (depth first).
fn findTagged(root: *wk.GtkWidget, index: usize) ?*wk.GtkWidget {
    var c = wk.gtk_widget_get_first_child(root);
    while (c) |cur| : (c = wk.gtk_widget_get_next_sibling(cur)) {
        if (tagOf(cur)) |t| if (t == index) return cur;
        if (findTagged(cur, index)) |f| return f;
    }
    return null;
}

/// The Restore... menu as drawn: each item's label, in order.
pub fn menuLabels(self: *const ConfigFile, alloc: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var c = wk.gtk_widget_get_first_child(self.restore_box);
    while (c) |cur| : (c = wk.gtk_widget_get_next_sibling(cur)) {
        if (SettingsWindow.firstLabelText(cur)) |t| try out.append(alloc, t) else try out.append(alloc, "-");
    }
    return out.toOwnedSlice(alloc);
}
