//! Appearance's theme picker and live preview on GTK (T3636, Linux L11g4) -
//! Mac `ThemeSection` and `SettingsPreview` (SettingsCustomSections.swift),
//! win32 `SettingsWindow.paintTheme` and `settings_preview_view.zig`.
//!
//! None of the rules live here. They are win32's pure modules, shared, so
//! the three seats pick, list and seed themes the same way:
//!
//! - `theme_catalog.zig` - the bundled themes plus the user's
//!   (`$XDG_CONFIG_HOME/ghostty/themes`; a user theme wins a name clash),
//!   light vs dark by the background's luminance, `theme = light:A,dark:B`,
//!   the mode switch that seeds the other slot from the same family (Latte
//!   <-> Mocha) and the hand-edited mismatch warning;
//! - `settings_theme_grid.zig` - a tab lists ONLY its kind, the filter, the
//!   picked theme first, 11 tiles then "All N <kind> themes...";
//! - `settings_preview.zig` - what the preview draws with (theme, font,
//!   size, opacity, padding, pane style, cursor) and its caption.
//!
//! **The section**: "Use" is an `AdwActionRow` whose suffix is two linked
//! toggle buttons (GNOME's segmented control: Light & dark themes / One
//! theme), its subtitle Mac's sentence. Then the light / dark tabs - linked
//! toggles whose labels ARE the two picked names in light & dark mode - the
//! tab's caption with the filter field trailing, Mac's notices, and a
//! `GtkFlowBox` of tiles (Mac's adaptive 118pt grid): each a button showing
//! `❯ ls` / `src docs err` / `~/git $` in the theme's own colors over its
//! background, the name under it, the picked one ringed in the accent.
//!
//! **The preview**: a 180 px card - the window's backdrop (Mac's gradient in
//! the elevated pane style, else the window color), the terminal in the
//! theme's background at the configured opacity (a CSS rgba, so the backdrop
//! shows through exactly as on Mac), four lines in the configured family and
//! size (Pango markup), the cursor in its style and opacity, blinking at
//! Mac's 530 ms only while the card is on screen, and the corner caption.
//! A slider being dragged previews its unwritten value.
//!
//! Colors reach GTK as CSS: one provider on the window's display holds a rule
//! per catalog theme (`.gz-tile-<i>`) and the fixed shapes, a second holds the
//! terminal's rgba and is reloaded when it changes. Both leave with the
//! window.
const SettingsTheme = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const wk = @import("webkit.zig");

const theme_catalog = @import("../win32/theme_catalog.zig");
const settings_theme = @import("../win32/settings_theme.zig");
const grid = @import("../win32/settings_theme_grid.zig");
const preview = @import("../win32/settings_preview.zig");
const controls = @import("../win32/settings_controls.zig");
const SettingsWindow = @import("SettingsWindow.zig");

const log = std.log.scoped(.gtk_settings);

const Rgb = theme_catalog.Rgb;
pub const Tab = grid.Tab;

/// Mac `LazyVGrid(.adaptive(minimum: 118), spacing: 10)`.
const tile_min_w = 118;
const tile_spacing = 10;

/// Read once, on the first build of the section.
themes: ?theme_catalog.Catalog = null,
themes_ms: u64 = 0,
/// A tab click; null follows the system appearance (Mac `colorScheme`).
tab: ?Tab = null,
filter: std.ArrayListUnmanaged(u8) = .empty,
show_all: bool = false,
/// Set while the section moves its own controls.
syncing: bool = false,
/// The grid needs drawing again (a tab, the filter, All N...): on idle,
/// never under the signal of the tile or button it is about to remove.
grid_source: c_uint = 0,

display: ?*wk.GdkDisplay = null,
tile_css: ?*wk.GtkCssProvider = null,
preview_css: ?*wk.GtkCssProvider = null,
/// The terminal's rule as last loaded (reloaded only on a change).
term_rule: std.ArrayListUnmanaged(u8) = .empty,

ui: ?Ui = null,
card: ?Card = null,
tiles: std.ArrayListUnmanaged(Tile) = .empty,
all_button: ?*wk.GtkWidget = null,

blink_source: c_uint = 0,
cursor_on: bool = true,

const Ui = struct {
    use_row: *wk.GtkWidget,
    follow: *wk.GtkWidget,
    one: *wk.GtkWidget,
    tab_light: *wk.GtkWidget,
    tab_dark: *wk.GtkWidget,
    tab_caption: *wk.GtkWidget,
    filter: *wk.GtkWidget,
    notices: [4]*wk.GtkWidget,
    flow: *wk.GtkWidget,
    empty: *wk.GtkWidget,
};

const Card = struct {
    overlay: *wk.GtkWidget,
    desk: *wk.GtkWidget,
    term: *wk.GtkWidget,
    lines: [preview.sample.len]*wk.GtkWidget,
    caption: *wk.GtkWidget,
};

pub const Tile = struct { button: *wk.GtkWidget, name: *wk.GtkWidget, index: usize, picked: bool };

fn window(self: *SettingsTheme) *SettingsWindow {
    return @alignCast(@fieldParentPtr("theme", self));
}

fn constWindow(self: *const SettingsTheme) *const SettingsWindow {
    return @alignCast(@fieldParentPtr("theme", self));
}

pub fn deinit(self: *SettingsTheme, gpa: Allocator) void {
    if (self.grid_source != 0) _ = wk.g_source_remove(self.grid_source);
    if (self.blink_source != 0) _ = wk.g_source_remove(self.blink_source);
    if (self.display) |d| {
        if (self.tile_css) |p| wk.gtk_style_context_remove_provider_for_display(d, p);
        if (self.preview_css) |p| wk.gtk_style_context_remove_provider_for_display(d, p);
    }
    if (self.tile_css) |p| wk.g_object_unref(@ptrCast(p));
    if (self.preview_css) |p| wk.g_object_unref(@ptrCast(p));
    if (self.themes) |*c| c.deinit();
    self.filter.deinit(gpa);
    self.term_rule.deinit(gpa);
    self.tiles.deinit(gpa);
    self.* = .{};
}

// ---------------------------------------------------------------------
// The model, as the section and the seam read it
// ---------------------------------------------------------------------

/// The theme catalog, read on first use (bundled, then the user's).
pub fn catalog(self: *SettingsTheme) *const theme_catalog.Catalog {
    if (self.themes == null) {
        const gpa = self.window().gpa;
        var timer = std.time.Timer.start() catch null;
        self.themes = settings_theme.loadCatalog(gpa) catch .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        self.themes_ms = if (timer) |*t| t.read() / std.time.ns_per_ms else 0;
        log.info("settings: themes light={d} dark={d} ms={d}", .{ self.themes.?.count(true), self.themes.?.count(false), self.themes_ms });
    }
    return &self.themes.?;
}

/// The `theme` key as a selection (null: no theme). Borrows the reader's
/// value: good until the next reload.
pub fn selection(self: *const SettingsTheme) ?theme_catalog.Selection {
    const r = self.constWindow().reader() orelse return null;
    return theme_catalog.Selection.parse(r.value("theme"));
}

/// The system appearance libadwaita applies to the window.
pub fn systemDark() bool {
    return wk.adw_style_manager_get_dark(wk.adw_style_manager_get_default()) != 0;
}

/// The tab the grid shows: the one clicked, else the system's appearance.
pub fn currentTab(self: *const SettingsTheme) Tab {
    return self.tab orelse if (systemDark()) .dark else .light;
}

/// Whether the user's file may set `theme` (no later file overrides it).
pub fn editable(self: *const SettingsTheme) bool {
    const w = self.constWindow();
    const s = if (w.sources) |*s| s else return true;
    return s.overriding("theme") == null;
}

/// The tiles for the current tab, filter and disclosure. Caller deinits.
pub fn gridNow(self: *SettingsTheme, alloc: Allocator) Allocator.Error!grid.Grid {
    const tab = self.currentTab();
    return grid.build(alloc, self.catalog(), tab, self.filter.items, grid.current(self.selection(), tab), self.show_all);
}

/// The preview's inputs from the window's effective values; a slider being
/// dragged previews its unwritten value (win32 `preview_view.inputs`).
pub fn previewInputs(self: *SettingsTheme, arena: Allocator) preview.Inputs {
    const w = self.window();
    const cat = self.catalog();
    const dark = systemDark();
    const r = w.reader() orelse return preview.resolve(.{}, cat, dark);
    const raw: preview.Raw = .{
        .theme = r.value("theme"),
        .background = r.value("background"),
        .foreground = r.value("foreground"),
        .palette = r.values(arena, "palette") catch &.{},
        .cursor_color = r.value("cursor-color"),
        .font_family = r.values(arena, "font-family") catch &.{},
        .font_size = r.value("font-size"),
        .font_feature = r.values(arena, "font-feature") catch &.{},
        .background_opacity = r.value("background-opacity"),
        .window_padding_x = r.value("window-padding-x"),
        .window_padding_y = r.value("window-padding-y"),
        .pane_style = r.value("macos-pane-style"),
        .cursor_style = r.value("cursor-style"),
        .cursor_style_blink = r.value("cursor-style-blink"),
        .cursor_opacity = r.value("cursor-opacity"),
    };
    var in = preview.resolve(raw, cat, dark);
    if (w.slidingKey()) |k| {
        if (std.mem.eql(u8, k, "background-opacity")) in.opacity = std.math.clamp(w.slide_value, 0, 1);
        if (std.mem.eql(u8, k, "cursor-opacity")) in.cursor_opacity = std.math.clamp(w.slide_value, 0, 1);
    }
    return in;
}

// ---------------------------------------------------------------------
// Writing (Mac `pick` / `switchMode`)
// ---------------------------------------------------------------------

/// "Use": light & dark seeds the other slot from the current theme's
/// family; one theme keeps the slot the system shows.
pub fn setFollows(self: *SettingsTheme, follow: bool) bool {
    if (!self.editable()) return false;
    const w = self.window();
    const res = theme_catalog.switchMode(w.gpa, self.catalog(), self.selection(), follow, systemDark()) catch return false;
    const ok = switch (res) {
        .set => |v| blk: {
            defer w.gpa.free(v);
            break :blk w.chooseValue("theme", v);
        },
        .reset => w.chooseValue("theme", ""),
        .unchanged => true,
    };
    log.info("settings: theme mode follow={} ok={}", .{ follow, ok });
    return ok;
}

/// A theme picked for `slot`: in light & dark mode it fills the slot, else
/// it becomes the one theme. Only a catalog theme is taken.
pub fn pick(self: *SettingsTheme, name: []const u8, slot: theme_catalog.Slot) bool {
    if (!self.editable()) return false;
    const w = self.window();
    const theme = self.catalog().named(name) orelse return false;
    const v = theme_catalog.pick(w.gpa, self.selection(), theme.name, slot) catch return false;
    defer w.gpa.free(v);
    const ok = w.chooseValue("theme", v);
    log.info("settings: theme pick {s} slot={s} ok={}", .{ theme.name, @tagName(slot), ok });
    return ok;
}

// ---------------------------------------------------------------------
// Building (once, from SettingsWindow.addCustom)
// ---------------------------------------------------------------------

fn connect(self: *SettingsTheme, obj: *wk.GtkWidget, signal: [*:0]const u8, handler: *const anyopaque) void {
    _ = wk.g_signal_connect_data(obj, signal, handler, self, null, 0);
}

fn caption(text: ?[*:0]const u8) *wk.GtkWidget {
    const l = wk.gtk_label_new(text);
    wk.gtk_label_set_xalign(l, 0.0);
    wk.gtk_label_set_wrap(l, 1);
    wk.gtk_widget_add_css_class(l, "caption");
    return l;
}

/// Two toggles in a linked box, GNOME's segmented control.
fn segmented(a: *wk.GtkWidget, b: *wk.GtkWidget) *wk.GtkWidget {
    const box = wk.gtk_box_new(0, 0);
    wk.gtk_widget_add_css_class(box, "linked");
    wk.gtk_toggle_button_set_group(b, a);
    wk.gtk_box_append(box, a);
    wk.gtk_box_append(box, b);
    return box;
}

/// Appearance > Theme.
pub fn buildTheme(self: *SettingsTheme, group: *wk.GtkWidget) void {
    self.ensureCss(group);
    const use_row = wk.adw_action_row_new();
    wk.adw_preferences_row_set_use_markup(use_row, 0);
    wk.adw_preferences_row_set_title(use_row, "Use");
    const follow = wk.gtk_toggle_button_new_with_label("Light & dark themes");
    const one = wk.gtk_toggle_button_new_with_label("One theme");
    const seg = segmented(follow, one);
    wk.gtk_widget_set_valign(seg, 3); // center
    wk.adw_action_row_add_suffix(use_row, seg);
    self.connect(follow, "toggled", @ptrCast(&onModeToggled));
    self.connect(one, "toggled", @ptrCast(&onModeToggled));
    wk.adw_preferences_group_add(group, use_row);

    const column = wk.gtk_box_new(1, 8);
    wk.gtk_widget_set_margin_top(column, 12);

    // The tabs (Mac caps them at 440pt), two equal halves.
    const tab_light = wk.gtk_toggle_button_new_with_label("\u{2600}  Light themes");
    const tab_dark = wk.gtk_toggle_button_new_with_label("\u{263E}  Dark themes");
    for ([_]*wk.GtkWidget{ tab_light, tab_dark }) |t| {
        wk.gtk_widget_set_size_request(t, 220, -1);
        wk.gtk_widget_set_hexpand(t, 1);
        if (wk.gtk_widget_get_first_child(t)) |l| wk.gtk_label_set_ellipsize(l, wk.ellipsize_end);
        self.connect(t, "toggled", @ptrCast(&onTabToggled));
    }
    const tabs = segmented(tab_light, tab_dark);
    wk.gtk_widget_set_halign(tabs, 1); // start
    wk.gtk_box_append(column, tabs);

    // The tab's caption, the filter field trailing it.
    const line = wk.gtk_box_new(0, 12);
    const tab_caption = caption(null);
    wk.gtk_widget_add_css_class(tab_caption, "dim-label");
    wk.gtk_widget_set_hexpand(tab_caption, 1);
    wk.gtk_box_append(line, tab_caption);
    const filter = wk.gtk_search_entry_new();
    wk.gtk_widget_set_size_request(filter, 192, -1);
    wk.gtk_search_entry_set_search_delay(filter, 0);
    self.connect(filter, "search-changed", @ptrCast(&onFilterChanged));
    wk.gtk_box_append(line, filter);
    wk.gtk_box_append(column, line);

    // Mac's notices: a later file sets the key, no themes / loading, a
    // hand-edited slot of the wrong kind, a value the parser refused.
    var notices: [4]*wk.GtkWidget = undefined;
    for (&notices) |*n| {
        n.* = caption(null);
        wk.gtk_widget_set_visible(n.*, 0);
        wk.gtk_box_append(column, n.*);
    }

    const flow = wk.gtk_flow_box_new();
    wk.gtk_flow_box_set_selection_mode(flow, 0); // none
    wk.gtk_flow_box_set_homogeneous(flow, 1);
    wk.gtk_flow_box_set_min_children_per_line(flow, 1);
    wk.gtk_flow_box_set_max_children_per_line(flow, 12);
    wk.gtk_flow_box_set_column_spacing(flow, tile_spacing);
    wk.gtk_flow_box_set_row_spacing(flow, tile_spacing);
    wk.gtk_box_append(column, flow);
    const empty = caption(null);
    wk.gtk_widget_add_css_class(empty, "dim-label");
    wk.gtk_widget_set_visible(empty, 0);
    wk.gtk_box_append(column, empty);

    wk.adw_preferences_group_add(group, column);
    self.ui = .{
        .use_row = use_row,
        .follow = follow,
        .one = one,
        .tab_light = tab_light,
        .tab_dark = tab_dark,
        .tab_caption = tab_caption,
        .filter = filter,
        .notices = notices,
        .flow = flow,
        .empty = empty,
    };
}

/// Appearance's preview card.
pub fn buildPreview(self: *SettingsTheme, group: *wk.GtkWidget) void {
    self.ensureCss(group);
    const overlay = wk.gtk_overlay_new();
    wk.gtk_widget_set_size_request(overlay, -1, preview.height_dip);
    wk.gtk_widget_set_overflow(overlay, wk.overflow_hidden);
    wk.gtk_widget_add_css_class(overlay, "gz-preview-card");
    const desk = wk.gtk_box_new(1, 0);
    wk.gtk_widget_add_css_class(desk, "gz-preview-desk");
    const term = wk.gtk_box_new(1, 0);
    wk.gtk_widget_set_vexpand(term, 1);
    wk.gtk_widget_set_overflow(term, wk.overflow_hidden);
    wk.gtk_widget_add_css_class(term, "gz-preview-term");
    var lines: [preview.sample.len]*wk.GtkWidget = undefined;
    for (&lines) |*l| {
        l.* = wk.gtk_label_new(null);
        wk.gtk_label_set_xalign(l.*, 0.0);
        wk.gtk_box_append(term, l.*);
    }
    wk.gtk_box_append(desk, term);
    wk.gtk_overlay_set_child(overlay, desk);
    const cap = wk.gtk_label_new(null);
    wk.gtk_widget_add_css_class(cap, "caption");
    wk.gtk_widget_add_css_class(cap, "gz-preview-caption");
    wk.gtk_widget_set_halign(cap, 2); // end
    wk.gtk_widget_set_valign(cap, 2);
    wk.gtk_overlay_add_overlay(overlay, cap);
    // The blink runs only while the card is on screen.
    self.connect(overlay, "map", @ptrCast(&onPreviewMap));
    wk.adw_preferences_group_add(group, overlay);
    self.card = .{ .overlay = overlay, .desk = desk, .term = term, .lines = lines, .caption = cap };
}

/// The two style providers, added to the window's display once.
fn ensureCss(self: *SettingsTheme, widget: *wk.GtkWidget) void {
    if (self.tile_css != null) return;
    const gpa = self.window().gpa;
    const display = wk.gtk_widget_get_display(widget);
    self.display = display;
    var css: std.ArrayListUnmanaged(u8) = .empty;
    defer css.deinit(gpa);
    css.appendSlice(gpa,
        \\button.gz-tile { padding: 0; border-radius: 10px; border: 1px solid alpha(currentColor, 0.18); background: none; box-shadow: none; }
        \\button.gz-tile.gz-tile-picked { border: 2px solid @accent_color; }
        \\.gz-tile-preview { padding: 7px 8px; font-family: monospace; font-size: 0.85em; }
        \\.gz-tile-name { padding: 3px 4px 4px 4px; }
        \\.gz-tile-name.gz-picked { color: @accent_color; font-weight: bold; }
        \\.gz-preview-card { border-radius: 10px; }
        \\.gz-preview-desk { background-color: @window_bg_color; }
        \\.gz-preview-desk.gz-elevated { background-image: linear-gradient(to bottom right, rgb(92,140,214), rgb(64,181,176)); }
        \\.gz-preview-desk.gz-elevated .gz-preview-term { border-radius: 11px; }
        \\.gz-preview-caption { background-color: rgba(0,0,0,0.35); color: rgba(255,255,255,0.85); border-radius: 5px; padding: 2px 6px; }
        \\
    ) catch {};
    const cat = self.catalog();
    for (cat.themes, 0..) |*t, i| {
        css.print(gpa, ".gz-tile-{d} {{ background-color: #{x:0>6}; }}\n", .{ i, t.background.hex() }) catch break;
    }
    css.append(gpa, 0) catch {};
    const tiles = wk.gtk_css_provider_new();
    wk.gtk_css_provider_load_from_string(tiles, @ptrCast(css.items.ptr));
    wk.gtk_style_context_add_provider_for_display(display, tiles, wk.style_provider_priority_application);
    self.tile_css = tiles;
    const pv = wk.gtk_css_provider_new();
    wk.gtk_style_context_add_provider_for_display(display, pv, wk.style_provider_priority_application + 1);
    self.preview_css = pv;
}

// ---------------------------------------------------------------------
// Refreshing (after every write, from SettingsWindow.redraw)
// ---------------------------------------------------------------------

pub fn refresh(self: *SettingsTheme) void {
    self.refreshTheme();
    self.refreshPreview();
}

fn setCaption(label: *wk.GtkWidget, text: []const u8, buf: []u8) void {
    const z = std.fmt.bufPrintZ(buf, "{s}", .{text}) catch return;
    wk.gtk_label_set_text(label, z.ptr);
}

pub fn refreshTheme(self: *SettingsTheme) void {
    const ui = self.ui orelse return;
    const w = self.window();
    const cat = self.catalog();
    const sel = self.selection();
    const follows = if (sel) |s| s.follows_system else false;
    const live = self.editable();
    const tab = self.currentTab();
    const kind = @tagName(tab);
    var buf: [600]u8 = undefined;

    self.syncing = true;
    defer self.syncing = false;
    wk.gtk_toggle_button_set_active(if (follows) ui.follow else ui.one, 1);
    wk.gtk_widget_set_sensitive(ui.follow, @intFromBool(live));
    wk.gtk_widget_set_sensitive(ui.one, @intFromBool(live));
    wk.adw_action_row_set_subtitle(ui.use_row, if (follows)
        "Switches between a light and a dark theme with the system appearance."
    else
        "One theme, whatever the system appearance.");

    const names = [2][]const u8{
        if (follows) sel.?.light else "Light themes",
        if (follows) sel.?.dark else "Dark themes",
    };
    const glyphs = [2][]const u8{ "\u{2600}", "\u{263E}" };
    for ([_]*wk.GtkWidget{ ui.tab_light, ui.tab_dark }, 0..) |t, i| {
        const l = std.fmt.bufPrintZ(&buf, "{s}  {s}", .{ glyphs[i], names[i] }) catch continue;
        wk.gtk_button_set_label(t, l.ptr);
        if (wk.gtk_widget_get_first_child(t)) |lbl| wk.gtk_label_set_ellipsize(lbl, wk.ellipsize_end);
    }
    wk.gtk_toggle_button_set_active(if (tab == .light) ui.tab_light else ui.tab_dark, 1);

    if (follows) {
        const c = std.fmt.bufPrint(&buf, "Showing {s} themes \u{2014} your pick is used in {s} mode.", .{ kind, kind }) catch "";
        var cb: [200]u8 = undefined;
        setCaption(ui.tab_caption, c, &cb);
    } else wk.gtk_label_set_text(ui.tab_caption, "Filter only \u{2014} the theme you pick is used all the time.");
    const ph = std.fmt.bufPrintZ(&buf, "Filter {d} {s} themes", .{ cat.count(tab == .light), kind }) catch "";
    wk.gtk_search_entry_set_placeholder_text(ui.filter, ph.ptr);
    if (!std.mem.eql(u8, std.mem.span(wk.gtk_editable_get_text(ui.filter)), self.filter.items)) {
        const z = w.gpa.dupeZ(u8, self.filter.items) catch null;
        defer if (z) |s| w.gpa.free(s);
        if (z) |s| wk.gtk_editable_set_text(ui.filter, s.ptr);
    }

    // The notices, in Mac's order; an empty one is hidden.
    var nb: [4][600]u8 = undefined;
    const Notice = struct { text: []const u8, class: [*:0]const u8 };
    const notices = [4]?Notice{
        if (!live) .{ .text = "Set in a file that loads after your config - edit it there.", .class = "warning" } else null,
        if (cat.themes.len == 0) .{ .text = "No themes were found in the bundled or your own themes folder.", .class = "warning" } else null,
        blk: {
            const s = sel orelse break :blk null;
            if (!s.follows_system) break :blk null;
            const slot = theme_catalog.mismatch(cat, s) orelse break :blk null;
            const want = @tagName(slot);
            const is = if (slot == .light) "dark" else "light";
            break :blk .{ .text = std.fmt.bufPrint(&nb[2], "\u{26A0} {s} is a {s} theme but is set for {s} mode. Pick a {s} theme to fix it.", .{ s.slotName(slot), is, want, want }) catch "", .class = "warning" };
        },
        if (w.problem("theme")) |prob| .{ .text = std.fmt.bufPrint(&nb[3], "\u{26A0} {s} \u{2014} not saved.", .{prob}) catch prob, .class = "error" } else null,
    };
    for (ui.notices, notices) |label, maybe| {
        wk.gtk_widget_remove_css_class(label, "warning");
        wk.gtk_widget_remove_css_class(label, "error");
        const n = maybe orelse {
            wk.gtk_widget_set_visible(label, 0);
            continue;
        };
        var tb: [700]u8 = undefined;
        setCaption(label, n.text, &tb);
        wk.gtk_widget_add_css_class(label, n.class);
        wk.gtk_widget_set_visible(label, 1);
    }

    self.drawGrid();
}

/// The tiles, from the same answer the seam reports.
fn drawGrid(self: *SettingsTheme) void {
    const ui = self.ui orelse return;
    const w = self.window();
    const gpa = w.gpa;
    const cat = self.catalog();
    const sel = self.selection();
    const tab = self.currentTab();
    const live = self.editable();
    const g = self.gridNow(gpa) catch return;
    defer g.deinit(gpa);
    const picked = grid.current(sel, tab);

    wk.gtk_flow_box_remove_all(ui.flow);
    self.tiles.clearRetainingCapacity();
    self.all_button = null;
    for (g.shown) |idx| {
        const th = &cat.themes[idx];
        const is_picked = if (picked) |p| std.mem.eql(u8, p, th.name) else false;
        const tile = self.makeTile(idx, th, is_picked, live) catch continue;
        self.tiles.append(gpa, tile) catch {};
        wk.gtk_flow_box_append(ui.flow, tile.button);
    }
    var buf: [200]u8 = undefined;
    if (g.more) {
        const l = std.fmt.bufPrintZ(&buf, "All {d} {s} themes\u{2026}", .{ g.matched, @tagName(tab) }) catch "All themes\u{2026}";
        const b = wk.gtk_button_new_with_label(l.ptr);
        wk.gtk_widget_add_css_class(b, "gz-tile");
        wk.gtk_widget_set_size_request(b, tile_min_w, -1);
        self.connect(b, "clicked", @ptrCast(&onAllClicked));
        wk.gtk_flow_box_append(ui.flow, b);
        self.all_button = b;
    }
    if (g.matched == 0 and cat.themes.len > 0) {
        const e = std.fmt.bufPrintZ(&buf, "No {s} themes match \u{201C}{s}\u{201D}.", .{ @tagName(tab), self.filter.items[0..@min(self.filter.items.len, 120)] }) catch "";
        wk.gtk_label_set_text(ui.empty, e.ptr);
        wk.gtk_widget_set_visible(ui.empty, 1);
    } else wk.gtk_widget_set_visible(ui.empty, 0);
}

/// One tile (Mac `ThemeTile`): three sample lines in the theme's colors over
/// its background, the name under it - accent and bold when picked - and
/// the accent ring when picked.
fn makeTile(self: *SettingsTheme, idx: usize, th: *const theme_catalog.Theme, picked: bool, live: bool) !Tile {
    var mb: [1024]u8 = undefined;
    const a = th.palette;
    const fg = th.foreground;
    const markup = try std.fmt.bufPrintZ(&mb,
        \\<span foreground="#{x:0>6}">{s} </span><span foreground="#{x:0>6}">ls</span>
        \\<span foreground="#{x:0>6}">src </span><span foreground="#{x:0>6}">docs </span><span foreground="#{x:0>6}">err</span>
        \\<span foreground="#{x:0>6}">~/git </span><span foreground="#{x:0>6}">$</span>
    , .{ a[2].hex(), "\u{276F}", fg.hex(), a[4].hex(), a[5].hex(), a[1].hex(), a[3].hex(), fg.hex() });
    const lines = wk.gtk_label_new(null);
    wk.gtk_label_set_markup(lines, markup.ptr);
    wk.gtk_label_set_xalign(lines, 0.0);
    wk.gtk_widget_add_css_class(lines, "gz-tile-preview");
    var cb: [32]u8 = undefined;
    wk.gtk_widget_add_css_class(lines, (try std.fmt.bufPrintZ(&cb, "gz-tile-{d}", .{idx})).ptr);

    var nb: [300]u8 = undefined;
    const name = wk.gtk_label_new((try std.fmt.bufPrintZ(&nb, "{s}", .{th.name})).ptr);
    wk.gtk_label_set_ellipsize(name, wk.ellipsize_end);
    wk.gtk_widget_add_css_class(name, "caption");
    wk.gtk_widget_add_css_class(name, "gz-tile-name");
    if (picked) wk.gtk_widget_add_css_class(name, "gz-picked");

    const box = wk.gtk_box_new(1, 0);
    wk.gtk_box_append(box, lines);
    wk.gtk_box_append(box, name);
    const button = wk.gtk_button_new();
    wk.gtk_button_set_child(button, box);
    wk.gtk_widget_set_overflow(button, wk.overflow_hidden);
    wk.gtk_widget_add_css_class(button, "gz-tile");
    if (picked) wk.gtk_widget_add_css_class(button, "gz-tile-picked");
    wk.gtk_widget_set_size_request(button, tile_min_w, -1);
    wk.gtk_widget_set_tooltip_text(button, (try std.fmt.bufPrintZ(&nb, "{s}", .{th.name})).ptr);
    wk.gtk_widget_set_sensitive(button, @intFromBool(live));
    wk.g_object_set_data(@ptrCast(button), "gz-theme-tile", @ptrFromInt(idx + 1));
    self.connect(button, "clicked", @ptrCast(&onTileClicked));
    return .{ .button = button, .name = name, .index = idx, .picked = picked };
}

/// Text for Pango markup.
fn escape(out: *std.ArrayListUnmanaged(u8), gpa: Allocator, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        else => try out.append(gpa, ch),
    };
}

fn pct(v: f64) u32 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 100));
}

/// The cursor as a run of the last line (Mac `PreviewCursor`): a block is
/// the cell's background, a bar and an underline the eighth-block glyphs in
/// the cursor color, hollow the outlined box; off-phase it is a plain space.
fn cursorMarkup(out: *std.ArrayListUnmanaged(u8), gpa: Allocator, in: *const preview.Inputs, on: bool) !void {
    if (!on) return out.append(gpa, ' ');
    const c = in.cursor.hex();
    const a = @max(1, pct(in.cursor_opacity));
    switch (in.cursor_style) {
        .block => try out.print(gpa, "<span background=\"#{x:0>6}\" bgalpha=\"{d}%\"> </span>", .{ c, a }),
        .bar => try out.print(gpa, "<span foreground=\"#{x:0>6}\" alpha=\"{d}%\">\u{258F}</span>", .{ c, a }),
        .underline => try out.print(gpa, "<span foreground=\"#{x:0>6}\" alpha=\"{d}%\">\u{2581}</span>", .{ c, a }),
        .block_hollow => try out.print(gpa, "<span foreground=\"#{x:0>6}\" alpha=\"{d}%\">\u{25AF}</span>", .{ c, a }),
    }
}

/// One preview line as Pango markup, in the configured face and size.
pub fn lineMarkup(gpa: Allocator, in: *const preview.Inputs, i: usize, cursor_on: bool) ![:0]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "<span font_family=\"");
    try escape(&out, gpa, in.family orelse "monospace");
    const size: u32 = @intFromFloat(@round(in.textSize() * 1024));
    try out.print(gpa, "\" size=\"{d}\"", .{size});
    if (!in.ligatures) try out.appendSlice(gpa, " font_features=\"calt 0, liga 0\"");
    try out.append(gpa, '>');
    for (preview.sample[i]) |span| {
        const color = if (span.ansi) |n| in.ansi(n) else in.foreground;
        try out.print(gpa, "<span foreground=\"#{x:0>6}\">", .{color.hex()});
        try escape(&out, gpa, span.text);
        try out.appendSlice(gpa, "</span>");
    }
    if (i == preview.sample.len - 1) try cursorMarkup(&out, gpa, in, cursor_on);
    try out.appendSlice(gpa, "</span>");
    return out.toOwnedSliceSentinel(gpa, 0);
}

pub fn refreshPreview(self: *SettingsTheme) void {
    const card = self.card orelse return;
    const gpa = self.window().gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const in = self.previewInputs(arena_state.allocator());

    if (in.elevated) wk.gtk_widget_add_css_class(card.desk, "gz-elevated") else wk.gtk_widget_remove_css_class(card.desk, "gz-elevated");
    const inset: c_int = if (in.elevated) preview.elevated_inset_dip else 0;
    wk.gtk_widget_set_margin_start(card.term, inset);
    wk.gtk_widget_set_margin_end(card.term, inset);
    wk.gtk_widget_set_margin_top(card.term, inset);
    wk.gtk_widget_set_margin_bottom(card.term, inset);

    var rb: [160]u8 = undefined;
    const bg = in.background;
    const rule = std.fmt.bufPrint(&rb, ".gz-preview-term {{ background-color: rgba({d},{d},{d},{d:.2}); }}", .{ bg.r, bg.g, bg.b, in.opacity }) catch "";
    if (!std.mem.eql(u8, rule, self.term_rule.items)) {
        self.term_rule.clearRetainingCapacity();
        self.term_rule.appendSlice(gpa, rule) catch {};
        var z: [161]u8 = undefined;
        @memcpy(z[0..rule.len], rule);
        z[rule.len] = 0;
        if (self.preview_css) |p| wk.gtk_css_provider_load_from_string(p, @ptrCast(&z));
    }

    // Mac: the text sits `padX + 10`, `padY + 8` in.
    const px: c_int = @intFromFloat(@round(in.pad_x + preview.text_pad_x_dip));
    const py: c_int = @intFromFloat(@round(in.pad_y + preview.text_pad_y_dip));
    for (card.lines, 0..) |l, i| {
        wk.gtk_widget_set_margin_start(l, px);
        wk.gtk_widget_set_margin_end(l, px);
        wk.gtk_widget_set_margin_top(l, if (i == 0) py else 0);
        const m = lineMarkup(gpa, &in, i, self.cursor_on or !in.blink) catch continue;
        defer gpa.free(m);
        wk.gtk_label_set_markup(l, m.ptr);
    }

    var cb: [200]u8 = undefined;
    const text = preview.caption(cb[0 .. cb.len - 1], &in);
    cb[text.len] = 0;
    wk.gtk_label_set_text(card.caption, @ptrCast(&cb));
    const ci: c_int = if (in.elevated) preview.caption_inset_elevated_dip else preview.caption_inset_dip;
    wk.gtk_widget_set_margin_end(card.caption, ci);
    wk.gtk_widget_set_margin_bottom(card.caption, ci);

    // The blink: on while it blinks and the card is on screen.
    if (in.blink and wk.gtk_widget_get_mapped(card.overlay) != 0) {
        if (self.blink_source == 0) self.blink_source = wk.g_timeout_add(preview.blink_ms, @ptrCast(&onBlink), self);
    } else self.stopBlink();
}

fn stopBlink(self: *SettingsTheme) void {
    if (self.blink_source != 0) _ = wk.g_source_remove(self.blink_source);
    self.blink_source = 0;
    self.cursor_on = true;
}

/// Run a pending grid redraw now (the seam reads the tiles right after).
pub fn flush(self: *SettingsTheme) void {
    if (self.grid_source == 0) return;
    _ = wk.g_source_remove(self.grid_source);
    self.grid_source = 0;
    self.refreshTheme();
}

fn scheduleGrid(self: *SettingsTheme) void {
    if (self.grid_source == 0) self.grid_source = wk.g_idle_add(@ptrCast(&onGridIdle), self);
}

// ---------------------------------------------------------------------
// The gestures, as the seam drives them: each moves the widget, and the
// widget's own signal does the rest.
// ---------------------------------------------------------------------

pub const GestureError = error{ NotDrawn, Insensitive };

/// Click "Light & dark themes" (true) or "One theme".
pub fn gestureMode(self: *SettingsTheme, follow: bool) GestureError!void {
    const ui = self.ui orelse return error.NotDrawn;
    const b = if (follow) ui.follow else ui.one;
    if (wk.gtk_widget_get_sensitive(b) == 0) return error.Insensitive;
    wk.gtk_toggle_button_set_active(b, 1);
}

/// Click a tab.
pub fn gestureTab(self: *SettingsTheme, tab: Tab) GestureError!void {
    const ui = self.ui orelse return error.NotDrawn;
    wk.gtk_toggle_button_set_active(if (tab == .light) ui.tab_light else ui.tab_dark, 1);
}

/// Type into the filter field.
pub fn gestureFilter(self: *SettingsTheme, text: []const u8) GestureError!void {
    const ui = self.ui orelse return error.NotDrawn;
    const gpa = self.window().gpa;
    const z = gpa.dupeZ(u8, text) catch return error.NotDrawn;
    defer gpa.free(z);
    wk.gtk_editable_set_text(ui.filter, z.ptr);
    // GtkSearchEntry reports after the fact; apply it now (its own signal
    // then finds nothing new).
    self.applyFilter(text);
}

/// Click "All N <kind> themes...".
pub fn gestureAll(self: *SettingsTheme) GestureError!void {
    const b = self.all_button orelse return error.NotDrawn;
    wk.g_signal_emit_by_name(@ptrCast(b), "clicked");
}

/// Click the drawn tile named `name`.
pub fn gestureTile(self: *SettingsTheme, name: []const u8) GestureError!void {
    const cat = self.catalog();
    for (self.tiles.items) |t| {
        if (!std.mem.eql(u8, cat.themes[t.index].name, name)) continue;
        if (wk.gtk_widget_get_sensitive(t.button) == 0) return error.Insensitive;
        wk.g_signal_emit_by_name(@ptrCast(t.button), "clicked");
        return;
    }
    return error.NotDrawn;
}

fn applyFilter(self: *SettingsTheme, text: []const u8) void {
    if (std.mem.eql(u8, text, self.filter.items)) return;
    self.filter.clearRetainingCapacity();
    self.filter.appendSlice(self.window().gpa, text) catch return;
    self.scheduleGrid();
}

// ---------------------------------------------------------------------
// Signals
// ---------------------------------------------------------------------

fn onModeToggled(button: *wk.GtkWidget, self: *SettingsTheme) callconv(.c) void {
    if (self.syncing) return;
    if (wk.gtk_toggle_button_get_active(button) == 0) return;
    const ui = self.ui orelse return;
    _ = self.setFollows(button == ui.follow);
}

fn onTabToggled(button: *wk.GtkWidget, self: *SettingsTheme) callconv(.c) void {
    if (self.syncing) return;
    if (wk.gtk_toggle_button_get_active(button) == 0) return;
    const ui = self.ui orelse return;
    const tab: Tab = if (button == ui.tab_light) .light else .dark;
    // Mac collapses the grid again on a tab change.
    self.tab = tab;
    self.show_all = false;
    self.scheduleGrid();
}

fn onFilterChanged(entry: *wk.GtkWidget, self: *SettingsTheme) callconv(.c) void {
    if (self.syncing) return;
    self.applyFilter(std.mem.span(wk.gtk_editable_get_text(entry)));
}

fn onTileClicked(button: *wk.GtkWidget, self: *SettingsTheme) callconv(.c) void {
    const t = @intFromPtr(wk.g_object_get_data(@ptrCast(button), "gz-theme-tile"));
    if (t == 0) return;
    const cat = self.catalog();
    if (t - 1 >= cat.themes.len) return;
    _ = self.pick(cat.themes[t - 1].name, self.currentTab().slot());
}

fn onAllClicked(_: *wk.GtkWidget, self: *SettingsTheme) callconv(.c) void {
    self.show_all = true;
    self.scheduleGrid();
}

fn onGridIdle(self: *SettingsTheme) callconv(.c) c_int {
    self.grid_source = 0;
    self.refreshTheme();
    return 0;
}

fn onPreviewMap(_: *wk.GtkWidget, self: *SettingsTheme) callconv(.c) void {
    self.refreshPreview();
}

fn onBlink(self: *SettingsTheme) callconv(.c) c_int {
    const card = self.card orelse {
        self.blink_source = 0;
        return 0;
    };
    if (wk.gtk_widget_get_mapped(card.overlay) == 0) {
        // Off screen: stop until the card maps again.
        self.blink_source = 0;
        self.cursor_on = true;
        return 0;
    }
    self.cursor_on = !self.cursor_on;
    self.refreshPreview();
    return 1; // G_SOURCE_CONTINUE
}

// ---------------------------------------------------------------------
// The seam's state
// ---------------------------------------------------------------------

fn hex(buf: *[7]u8, c: Rgb) []const u8 {
    return controls.formatHex(buf, c.hex());
}

/// "theme" and "preview": the model beside what the widgets draw.
pub fn writeState(self: *SettingsTheme, jws: *std.json.Stringify, alloc: Allocator) !void {
    const cat = self.catalog();
    const sel = self.selection();
    const tab = self.currentTab();
    var hb: [7]u8 = undefined;
    try jws.objectField("theme");
    try jws.beginObject();
    try jws.objectField("follows");
    try jws.write(if (sel) |s| s.follows_system else false);
    try jws.objectField("light");
    try jws.write(if (sel) |s| s.light else null);
    try jws.objectField("dark");
    try jws.write(if (sel) |s| s.dark else null);
    try jws.objectField("mismatch");
    try jws.write(if (sel) |s| (if (theme_catalog.mismatch(cat, s)) |m| @tagName(m) else null) else null);
    try jws.objectField("light_count");
    try jws.write(cat.count(true));
    try jws.objectField("dark_count");
    try jws.write(cat.count(false));
    try jws.objectField("load_ms");
    try jws.write(self.themes_ms);
    try jws.objectField("system_dark");
    try jws.write(systemDark());
    try jws.objectField("editable");
    try jws.write(self.editable());
    try jws.objectField("tab");
    try jws.write(@tagName(tab));
    try jws.objectField("filter");
    try jws.write(self.filter.items);
    try jws.objectField("show_all");
    try jws.write(self.show_all);
    try jws.objectField("selected");
    try jws.write(grid.current(sel, tab));
    if (self.gridNow(alloc)) |g| {
        defer g.deinit(alloc);
        try jws.objectField("kind_total");
        try jws.write(g.kind_total);
        try jws.objectField("matched");
        try jws.write(g.matched);
        try jws.objectField("more");
        try jws.write(g.more);
        try jws.objectField("tiles");
        try jws.beginArray();
        for (g.shown) |i| try jws.write(cat.themes[i].name);
        try jws.endArray();
    } else |_| {}
    // A named theme's colors (the catalog's answer, user theme included).
    try jws.objectField("catalog");
    try jws.beginArray();
    for (cat.themes) |*t| {
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(t.name);
        try jws.objectField("light");
        try jws.write(t.isLight());
        try jws.objectField("user");
        try jws.write(t.is_user);
        try jws.objectField("background");
        try jws.write(hex(&hb, t.background));
        try jws.endObject();
    }
    try jws.endArray();
    try jws.objectField("drawn");
    if (self.ui) |ui| {
        try jws.beginObject();
        try jws.objectField("follow_active");
        try jws.write(wk.gtk_toggle_button_get_active(ui.follow) != 0);
        try jws.objectField("one_active");
        try jws.write(wk.gtk_toggle_button_get_active(ui.one) != 0);
        try jws.objectField("mode_sensitive");
        try jws.write(wk.gtk_widget_get_sensitive(ui.follow) != 0);
        try jws.objectField("use_caption");
        try jws.write(std.mem.span(wk.adw_action_row_get_subtitle(ui.use_row) orelse ""));
        try jws.objectField("tab_labels");
        try jws.beginArray();
        for ([_]*wk.GtkWidget{ ui.tab_light, ui.tab_dark }) |t| try jws.write(std.mem.span(wk.gtk_button_get_label(t) orelse ""));
        try jws.endArray();
        try jws.objectField("tab_active");
        try jws.write(if (wk.gtk_toggle_button_get_active(ui.tab_light) != 0) "light" else if (wk.gtk_toggle_button_get_active(ui.tab_dark) != 0) "dark" else null);
        try jws.objectField("tab_caption");
        try jws.write(std.mem.span(wk.gtk_label_get_text(ui.tab_caption)));
        try jws.objectField("filter");
        try jws.write(std.mem.span(wk.gtk_editable_get_text(ui.filter)));
        try jws.objectField("notices");
        try jws.beginArray();
        for (ui.notices) |n| if (wk.gtk_widget_get_visible(n) != 0) try jws.write(std.mem.span(wk.gtk_label_get_text(n)));
        try jws.endArray();
        try jws.objectField("tiles");
        try jws.beginArray();
        for (self.tiles.items) |t| {
            const th = &cat.themes[t.index];
            try jws.beginObject();
            try jws.objectField("name");
            try jws.write(std.mem.span(wk.gtk_label_get_text(t.name)));
            try jws.objectField("light");
            try jws.write(th.isLight());
            try jws.objectField("picked");
            try jws.write(wk.gtk_widget_has_css_class(t.button, "gz-tile-picked") != 0);
            try jws.objectField("sensitive");
            try jws.write(wk.gtk_widget_get_sensitive(t.button) != 0);
            try jws.objectField("background");
            try jws.write(hex(&hb, th.background));
            try jws.endObject();
        }
        try jws.endArray();
        try jws.objectField("all");
        try jws.write(if (self.all_button) |b| std.mem.span(wk.gtk_button_get_label(b) orelse "") else null);
        try jws.objectField("empty");
        try jws.write(if (wk.gtk_widget_get_visible(ui.empty) != 0) std.mem.span(wk.gtk_label_get_text(ui.empty)) else null);
        try jws.endObject();
    } else try jws.write(null);
    try jws.endObject();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const in = self.previewInputs(arena_state.allocator());
    var cap_buf: [200]u8 = undefined;
    try jws.objectField("preview");
    try jws.beginObject();
    try jws.objectField("theme");
    try jws.write(in.theme_name);
    try jws.objectField("from_catalog");
    try jws.write(in.from_catalog);
    try jws.objectField("background");
    try jws.write(hex(&hb, in.background));
    try jws.objectField("foreground");
    try jws.write(hex(&hb, in.foreground));
    try jws.objectField("cursor_color");
    try jws.write(hex(&hb, in.cursor));
    try jws.objectField("family");
    try jws.write(in.family);
    try jws.objectField("size");
    try jws.write(in.size);
    try jws.objectField("opacity");
    try jws.write(in.opacity);
    try jws.objectField("pad_x");
    try jws.write(in.pad_x);
    try jws.objectField("pad_y");
    try jws.write(in.pad_y);
    try jws.objectField("elevated");
    try jws.write(in.elevated);
    try jws.objectField("ligatures");
    try jws.write(in.ligatures);
    try jws.objectField("cursor_style");
    try jws.write(@tagName(in.cursor_style));
    try jws.objectField("blink");
    try jws.write(in.blink);
    try jws.objectField("cursor_opacity");
    try jws.write(in.cursor_opacity);
    try jws.objectField("caption");
    try jws.write(preview.caption(&cap_buf, &in));
    try jws.objectField("drawn");
    if (self.card) |card| {
        try jws.beginObject();
        try jws.objectField("caption");
        try jws.write(std.mem.span(wk.gtk_label_get_text(card.caption)));
        try jws.objectField("term_rule");
        try jws.write(self.term_rule.items);
        try jws.objectField("elevated");
        try jws.write(wk.gtk_widget_has_css_class(card.desk, "gz-elevated") != 0);
        try jws.objectField("lines");
        try jws.beginArray();
        for (card.lines) |l| try jws.write(std.mem.span(wk.gtk_label_get_label(l)));
        try jws.endArray();
        try jws.objectField("text_margin");
        try jws.write(wk.gtk_widget_get_margin_start(card.lines[0]));
        try jws.objectField("mapped");
        try jws.write(wk.gtk_widget_get_mapped(card.overlay) != 0);
        try jws.objectField("blinking");
        try jws.write(self.blink_source != 0);
        try jws.endObject();
    } else try jws.write(null);
    try jws.endObject();
}
