//! The sticky pane banner on GTK (T3339, Linux L10; docs/reference/banners.md).
//!
//! A card above a terminal pane's content, set by `+set-banner` or OSC 7778,
//! that survives scrolling and screen clears until it is changed or cleared.
//! The Mac draws it in SwiftUI and win32 paints it by hand; GTK has stock
//! widgets for every piece, so this is a vertical box of them, rebuilt from
//! the shared parser's blocks on every change:
//!
//! - a text line or a heading: a wrapping `GtkLabel` in Pango markup
//!   (`banner_markup.zig`), whose `<a>` links GTK draws and clicks for us;
//! - a list: a grid with a shared marker gutter (a bullet, `N.`, or a real
//!   `GtkCheckButton` that ignores the pointer - Mac's native box);
//! - a table: a grid with a bold header, `:` alignment, cells that wrap to at
//!   most three lines and end in an ellipsis past that;
//! - a rule: a `GtkSeparator`.
//!
//! The box sits ABOVE the GL area in the pane's own vertical box, so the
//! terminal is laid out below it and resized for it - the Mac's "the banner
//! never covers a row". Parity is behavior and information, not pixels
//! (docs/design/linux-port.md).
//!
//! A click on a link goes to `on_link` with the modifiers held at the press,
//! so the surface can apply the click table (`banner_link.clickAction`).
//!
//! **Collapse (T3559).** A click anywhere else on the card, or on its
//! chevron, collapses a multi-line banner to its title row and back
//! (`pane_banner_rules`). The terminal sees ONE resize per click: the card is
//! rebuilt at its new height and GTK lays the pane out once - there is no
//! animated height for it to follow frame by frame, which is the Mac's
//! "the user never sees the terminal resize" without its frozen-frame
//! machinery. The state is ephemeral: a cleared banner comes back expanded.
const PaneBanner = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const wk = @import("webkit.zig");
const md = @import("../win32/banner_markdown.zig");
const markup = @import("banner_markup.zig");
const rules = @import("pane_banner_rules.zig");

const log = std.log.scoped(.gtk_banner);

const orientation_horizontal: c_int = 0;
const orientation_vertical: c_int = 1;
const pango_wrap_word_char: c_int = 2;
const pango_ellipsize_end: c_int = 3;
const phase_capture: c_int = 1;
const gdk_shift_mask: c_uint = 1 << 0;
const gdk_control_mask: c_uint = 1 << 2;

/// Rows a table cell wraps to before it ends in an ellipsis (banners.md).
const max_cell_lines: c_int = 3;

pub const LinkCallback = *const fn (owner: *anyopaque, target: []const u8, ctrl: bool, shift: bool) void;

alloc: Allocator,
/// The card: a horizontal box, styled `.pane-banner`, hidden while there is
/// no banner - the content on its leading side, the chevron on its trailing
/// one. Owned by the widget tree it is put in.
box: *wk.GtkWidget,
/// The blocks: a vertical box inside the card, rebuilt on every render.
content: *wk.GtkWidget,
/// The collapse/expand chevron, shown only while the banner is collapsible.
chevron: *wk.GtkWidget,
/// Collapsed to the title row (ephemeral; a clear expands it again).
collapsed: bool = false,
/// A press on the card turned into a link click or a chevron click: the
/// card's own toggle, queued at the release, stands down.
click_taken: bool = false,
/// The card-click toggle queued for the next idle, if any.
pending_toggle: bool = false,
/// `destroy` ran while a toggle was queued; the idle frees the struct and
/// touches no widget.
destroyed: bool = false,
/// The banner's source text, or null. Owned.
text: ?[]u8 = null,
/// What relative links resolve against. The strings are borrowed for one
/// `render` only.
paths: md.PathContext = .{ .posix = true },
/// The modifiers held when the pointer last went down on the card.
mods: c_uint = 0,
/// Who a link click is handed to (the surface), and the pane id the test
/// seam names it by.
owner: ?*anyopaque = null,
on_link: ?LinkCallback = null,
pane_id: []const u8 = "",

pub fn create(alloc: Allocator) Allocator.Error!*PaneBanner {
    const self = try alloc.create(PaneBanner);
    const box = wk.gtk_box_new(orientation_horizontal, 4);
    wk.gtk_widget_add_css_class(box, "pane-banner");
    wk.gtk_widget_set_hexpand(box, 1);
    wk.gtk_widget_set_vexpand(box, 0);
    wk.gtk_widget_set_focusable(box, 0);
    wk.gtk_widget_set_visible(box, 0);

    const content = wk.gtk_box_new(orientation_vertical, 4);
    wk.gtk_widget_set_hexpand(content, 1);
    wk.gtk_box_append(box, content);

    // chevron.up expanded, chevron.down collapsed (the Mac's glyphs), flat
    // so it reads as part of the card. Never focusable: the terminal keeps
    // the keyboard.
    const chevron = wk.gtk_button_new_from_icon_name("pan-up-symbolic");
    wk.gtk_widget_add_css_class(chevron, "flat");
    wk.gtk_widget_add_css_class(chevron, "pane-banner-chevron");
    wk.gtk_widget_set_valign(chevron, 1); // GTK_ALIGN_START
    wk.gtk_widget_set_focusable(chevron, 0);
    wk.gtk_widget_set_focus_on_click(chevron, 0);
    wk.gtk_widget_set_visible(chevron, 0);
    _ = wk.g_signal_connect_data(chevron, "clicked", @ptrCast(&onChevronClicked), self, null, 0);
    wk.gtk_box_append(box, chevron);

    // The modifiers of a click are not on `activate-link`; read them off the
    // press, in the capture phase so the label's own gesture cannot hide it.
    // The release, in the same phase, queues the card's collapse toggle -
    // which stands down if the click turns out to be a link's or the
    // chevron's, both of which are decided after it.
    const click = wk.gtk_gesture_click_new();
    wk.gtk_event_controller_set_propagation_phase(click, phase_capture);
    _ = wk.g_signal_connect_data(click, "pressed", @ptrCast(&onPressed), self, null, 0);
    _ = wk.g_signal_connect_data(click, "released", @ptrCast(&onReleased), self, null, 0);
    wk.gtk_widget_add_controller(box, click);

    self.* = .{ .alloc = alloc, .box = box, .content = content, .chevron = chevron };
    return self;
}

/// Free the struct. The box belongs to the widget tree and goes with it.
/// A card-click toggle still queued holds a pointer to this struct, so it is
/// left to free it (`onIdleToggle`).
pub fn destroy(self: *PaneBanner) void {
    if (self.text) |t| self.alloc.free(t);
    self.text = null;
    if (self.pending_toggle) {
        self.owner = null;
        self.on_link = null;
        self.destroyed = true;
        return;
    }
    self.alloc.destroy(self);
}

/// The banner's source text, or null when there is none.
pub fn getText(self: *const PaneBanner) ?[]const u8 {
    return self.text;
}

/// Set (or with null or "" clear) the banner and redraw it.
pub fn setText(self: *PaneBanner, text: ?[]const u8) void {
    if (self.text) |t| self.alloc.free(t);
    self.text = null;
    if (text) |t| if (t.len > 0) {
        self.text = self.alloc.dupe(u8, t) catch null;
    };
    // A cleared banner comes back expanded (banners.md); one with nothing
    // under its title has no collapsed form. A new multi-line text keeps the
    // state, as on win32: the user folded this pane's card, not one text.
    if (!rules.collapsible(self.text)) self.collapsed = false;
    self.render();
}

/// Whether the card can collapse: it has a line under its title.
pub fn isCollapsible(self: *const PaneBanner) bool {
    return rules.collapsible(self.text);
}

/// Collapse the card to its title row, or expand it (the chevron, a click
/// on the card). Does nothing to a banner that cannot collapse. `why` names
/// the caller in the log.
pub fn toggleCollapsed(self: *PaneBanner, why: []const u8) void {
    if (!self.isCollapsible()) return;
    self.collapsed = !self.collapsed;
    log.info("banner: collapse pane={s} collapsed={} via={s}", .{ self.pane_id, self.collapsed, why });
    self.render();
}

/// A click on the card itself - not on a link, not on the chevron - toggles
/// the collapse (the Mac's tap gesture on the card). What the queued
/// release runs, and what the test seam calls.
pub fn cardClicked(self: *PaneBanner) void {
    if (self.click_taken) {
        self.click_taken = false;
        return;
    }
    self.toggleCollapsed("card");
}

/// The pane's working directory moved: a banner with `./` links points
/// somewhere else now (T758's rule), so redraw it. Anything else is unchanged.
pub fn cwdChanged(self: *PaneBanner) void {
    const t = self.text orelse return;
    if (md.dependsOnCwd(t)) self.render();
}

/// Rebuild the card from `text`.
pub fn render(self: *PaneBanner) void {
    while (wk.gtk_widget_get_first_child(self.content)) |child| wk.gtk_box_remove(self.content, child);

    const text = self.text orelse {
        wk.gtk_widget_set_visible(self.chevron, 0);
        wk.gtk_widget_set_visible(self.box, 0);
        self.dump("cleared");
        return;
    };

    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList(u8) = .empty;
    const collapsible = self.isCollapsible();
    const collapsed = collapsible and self.collapsed;
    lines.appendSlice(arena, if (!collapsible) "  state fixed\n" else if (collapsed) "  state collapsed\n" else "  state expanded\n") catch return;
    const parsed = md.parseBlocks(arena, self.paths, text) catch {
        log.warn("banner: out of memory parsing pane={s}", .{self.pane_id});
        return;
    };
    var title_row: [1]md.Block = undefined;
    const blocks = if (collapsed) rules.collapsedBlocks(parsed, &title_row) else parsed;
    for (blocks) |block| {
        const widget = self.blockWidget(arena, block, &lines) catch {
            log.warn("banner: out of memory building pane={s}", .{self.pane_id});
            return;
        };
        // Collapsed, a text line or heading is the title row: one line,
        // ellipsized, however wide the source.
        if (collapsed and (block == .text or block == .heading)) {
            wk.gtk_label_set_lines(widget, 1);
            wk.gtk_label_set_ellipsize(widget, pango_ellipsize_end);
        }
        wk.gtk_box_append(self.content, widget);
    }
    wk.gtk_button_set_icon_name(self.chevron, if (collapsed) "pan-down-symbolic" else "pan-up-symbolic");
    wk.gtk_widget_set_tooltip_text(self.chevron, if (collapsed) "Expand banner" else "Collapse banner");
    wk.gtk_widget_set_visible(self.chevron, @intFromBool(collapsible));
    // The whole card is the toggle while it can collapse; a link keeps its
    // own hand cursor over it.
    wk.gtk_widget_set_cursor_from_name(self.box, if (collapsible) "pointer" else null);
    wk.gtk_widget_set_visible(self.box, 1);
    self.dump(lines.items);
    log.info("banner: set pane={s} blocks={d} collapsed={}", .{ self.pane_id, blocks.len, collapsed });
}

fn blockWidget(self: *PaneBanner, arena: Allocator, block: md.Block, lines: *std.ArrayList(u8)) Allocator.Error!*wk.GtkWidget {
    switch (block) {
        .text => |items| {
            const m = try markup.markup(arena, items, null);
            try dumpLine(arena, lines, "text", m);
            return self.label(m, 0.0);
        },
        .heading => |h| {
            const m = try markup.markup(arena, h.content, markup.headingSpan(h.level));
            try dumpLine(arena, lines, "heading", m);
            return self.label(m, 0.0);
        },
        .rule => {
            try dumpLine(arena, lines, "rule", "");
            return wk.gtk_separator_new(orientation_horizontal);
        },
        .list => |items| {
            const grid = wk.gtk_grid_new();
            wk.gtk_grid_set_column_spacing(grid, 6);
            wk.gtk_grid_set_row_spacing(grid, 2);
            var buf: [16]u8 = undefined;
            for (items, 0..) |item, row| {
                const marker = if (markup.listMarker(&buf, item.marker)) |t| blk: {
                    const z = try arena.dupeZ(u8, t);
                    const l = wk.gtk_label_new(z.ptr);
                    wk.gtk_label_set_xalign(l, 1.0);
                    wk.gtk_widget_set_valign(l, 1); // GTK_ALIGN_START
                    try dumpLine(arena, lines, "item", z);
                    break :blk l;
                } else blk: {
                    const checked = item.marker.checkbox;
                    const cb = wk.gtk_check_button_new();
                    wk.gtk_check_button_set_active(cb, @intFromBool(checked));
                    wk.gtk_widget_set_can_target(cb, 0);
                    wk.gtk_widget_set_focusable(cb, 0);
                    wk.gtk_widget_set_valign(cb, 1);
                    try dumpLine(arena, lines, "item", if (checked) "[x]" else "[ ]");
                    break :blk cb;
                };
                const m = try markup.markup(arena, item.content, null);
                try dumpLine(arena, lines, "  content", m);
                wk.gtk_grid_attach(grid, marker, 0, @intCast(row), 1, 1);
                const content = self.label(m, 0.0);
                wk.gtk_widget_set_hexpand(content, 1);
                wk.gtk_grid_attach(grid, content, 1, @intCast(row), 1, 1);
            }
            return grid;
        },
        .table => |t| {
            const grid = wk.gtk_grid_new();
            wk.gtk_grid_set_column_spacing(grid, 16);
            wk.gtk_grid_set_row_spacing(grid, 2);
            const cols = t.header.len;
            try dumpLine(arena, lines, "table", try std.fmt.allocPrint(arena, "cols={d} rows={d} header={}", .{ cols, t.rows.len, t.hasVisibleHeader() }));
            var row: c_int = 0;
            if (t.hasVisibleHeader()) {
                for (t.header, 0..) |hcell, col| {
                    const m = try markup.markup(arena, hcell, "weight=\"bold\"");
                    try dumpLine(arena, lines, "  th", m);
                    wk.gtk_grid_attach(grid, self.cell(m, t.alignments[col]), @intCast(col), row, 1, 1);
                }
                row += 1;
                wk.gtk_grid_attach(grid, wk.gtk_separator_new(orientation_horizontal), 0, row, @intCast(cols), 1);
                row += 1;
            }
            for (t.rows) |cells| {
                for (cells, 0..) |bcell, col| {
                    const m = try markup.markup(arena, bcell, null);
                    try dumpLine(arena, lines, "  td", m);
                    wk.gtk_grid_attach(grid, self.cell(m, t.alignments[col]), @intCast(col), row, 1, 1);
                }
                row += 1;
            }
            return grid;
        },
    }
}

/// A wrapping markup label whose links come to `onActivateLink`.
fn label(self: *PaneBanner, m: [:0]const u8, xalign: f32) *wk.GtkWidget {
    const l = wk.gtk_label_new(null);
    wk.gtk_label_set_markup(l, m.ptr);
    wk.gtk_label_set_xalign(l, xalign);
    wk.gtk_label_set_wrap(l, 1);
    wk.gtk_label_set_wrap_mode(l, pango_wrap_word_char);
    // The terminal keeps the keyboard: a banner is read and clicked, never
    // tabbed into.
    wk.gtk_widget_set_focusable(l, 0);
    wk.gtk_widget_set_focus_on_click(l, 0);
    _ = wk.g_signal_connect_data(l, "activate-link", @ptrCast(&onActivateLink), self, null, 0);
    return l;
}

fn cell(self: *PaneBanner, m: [:0]const u8, alignment: ?md.ColumnAlignment) *wk.GtkWidget {
    const l = self.label(m, markup.cellXalign(alignment));
    wk.gtk_label_set_lines(l, max_cell_lines);
    wk.gtk_label_set_ellipsize(l, pango_ellipsize_end);
    return l;
}

fn onPressed(gesture: *wk.GtkEventController, _: c_int, _: f64, _: f64, self: *PaneBanner) callconv(.c) void {
    self.mods = wk.gtk_event_controller_get_current_event_state(gesture);
    self.click_taken = false;
}

/// The release of a click on the card. A link's `activate-link` and the
/// chevron's `clicked` both come AFTER this capture-phase handler, so the
/// card's toggle is queued for the next idle, where it can see whether one
/// of them took the click.
fn onReleased(_: *wk.GtkEventController, n_press: c_int, _: f64, _: f64, self: *PaneBanner) callconv(.c) void {
    if (n_press != 1 or self.pending_toggle) return;
    if (!self.isCollapsible()) return;
    self.pending_toggle = true;
    _ = wk.g_idle_add(&onIdleToggle, self);
}

fn onIdleToggle(data: ?*anyopaque) callconv(.c) c_int {
    const self: *PaneBanner = @ptrCast(@alignCast(data orelse return 0));
    self.pending_toggle = false;
    if (self.destroyed) {
        self.alloc.destroy(self);
        return 0;
    }
    self.cardClicked();
    return 0; // G_SOURCE_REMOVE
}

fn onChevronClicked(_: *wk.GtkWidget, self: *PaneBanner) callconv(.c) void {
    self.click_taken = true;
    self.toggleCollapsed("chevron");
}

/// The chevron, as the test seam presses it: its own `clicked` handler.
pub fn chevronClicked(self: *PaneBanner) void {
    onChevronClicked(self.chevron, self);
    // No release queued a card toggle, so nothing will consume the mark.
    self.click_taken = false;
}

fn onActivateLink(_: *wk.GtkWidget, uri: [*:0]const u8, self: *PaneBanner) callconv(.c) c_int {
    const target = std.mem.span(uri);
    const ctrl = self.mods & gdk_control_mask != 0;
    const shift = self.mods & gdk_shift_mask != 0;
    self.mods = 0;
    // The click was the link's: the card does not also collapse under it.
    self.click_taken = true;
    log.info("banner: link clicked pane={s} ctrl={} shift={} target={s}", .{ self.pane_id, ctrl, shift, target });
    const cb = self.on_link orelse return 1;
    cb(self.owner orelse return 1, target, ctrl, shift);
    // Handled: never GTK's default, which would hand a bare path to the
    // desktop as a URI.
    return 1;
}

// ---- The test seam -----------------------------------------------------------

fn dumpLine(arena: Allocator, lines: *std.ArrayList(u8), kind: []const u8, text: []const u8) Allocator.Error!void {
    try lines.appendSlice(arena, "  ");
    try lines.appendSlice(arena, kind);
    if (text.len > 0) {
        try lines.append(arena, ' ');
        try lines.appendSlice(arena, text);
    }
    try lines.append(arena, '\n');
}

/// Debug builds append what each render drew to `$GHOZTTY_TEST_BANNER_DUMP`,
/// one `BANNER <pane-id> ...` header and one line per widget, so an
/// acceptance script in a headless compositor can read the card back.
fn dump(self: *PaneBanner, body: []const u8) void {
    if (comptime !build_config.is_debug) return;
    const path = std.posix.getenv("GHOZTTY_TEST_BANNER_DUMP") orelse return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch return;
    const shown = self.text != null;
    var head: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "BANNER {s} {s}\n", .{ self.pane_id, if (shown) "shown" else "cleared" }) catch return;
    f.writeAll(h) catch return;
    if (shown) f.writeAll(body) catch return;
    f.writeAll("END\n") catch return;
}
