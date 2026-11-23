//! A markdown viewer pane's table of contents (T3418, Linux L9i):
//! docs/reference/viewer-panes.md, "Table of contents".
//!
//! The page does the reading: the template's `viewer.js` indexes the rendered
//! headings (two or more, or none at all), posts them on the `viewerTOC`
//! handler, and posts the section at the top of the pane as the reader
//! scrolls - the scroll spy. A row click runs the page's `scrollToAnchor`,
//! which PINS the spy to that heading through the smooth scroll and posts it
//! back as `active`; the reader's own next scroll gesture releases it. All of
//! that lives in the page; this side only follows the `active` reports, so
//! it can never fight the pin.
//!
//! What lives here is the card - a libadwaita `card` over the page's top-left,
//! a pinned "CONTENTS" caption, the headings in a `navigation-sidebar` list
//! (the selection pill), indented by depth and wrapped to two lines - and
//! where it sits, which is the pure `viewer_toc.zig`:
//!
//! - **Wide pane** (720 px and up): the card floats in a left gutter the page
//!   reserves as its own padding (`setGutter`), so the strip behind the card
//!   is the document's background, not a seam of window. Its right edge drags
//!   the width, which is the preference every viewer pane shares with the
//!   diff panel (`viewer_prefs`).
//! - **Narrow pane**: an overlay over the document, opened and closed by the
//!   nav bar's contents button (its first item), dismissed by a row click.
//!   The switch follows the pane's own width live - a split divider drag
//!   reflows it - measured by a zero-cost `GtkDrawingArea` overlay whose
//!   `resize` reports the page area.
//! - The open state is ephemeral: nothing is persisted but the width.
//!
//! The acceptance oracle is the `viewer toc ...` log lines and the steps
//! runner's `toc` / `toc-row` / `toc-drag` steps (test/linux/viewer-toc.sh).
const ViewerTOC = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Viewer = @import("Viewer.zig");
const wk = @import("webkit.zig");
const bridge = @import("../win32/viewer_bridge.zig");
const content = @import("../win32/viewer_content.zig");
const prefs = @import("../win32/viewer_prefs.zig");
const toc_layout = @import("../win32/viewer_toc_layout.zig");
const policy = @import("viewer_toc.zig");

const log = std.log.scoped(.gtk_viewer);

/// One heading row. Both strings owned.
const Item = struct {
    id: []u8,
    text: [:0]u8,
    depth: u8,
};

items: std.ArrayList(Item) = .empty,
/// The heading the page says the reader is in. Owned.
active: ?[]u8 = null,
state: policy.State = .{},
/// The shared width preference, loaded on the first layout pass; 0 = not yet.
width: f32 = 0,
/// The page area's size (the overlay the web view sits in), from `sizer`.
/// 0 until the pane is first allocated: no layout pass runs before that, or a
/// wide pane would flash its compact button.
pane_w: f32 = 0,
pane_h: f32 = 0,
/// The gutter the page was last told to reserve. Reset when a new page loads
/// (its body has no padding yet).
gutter_pushed: f32 = 0,
/// The card width a drag started from.
drag_start: f32 = 0,
/// Counters and the last presentation, for the steps runner.
layouts: u32 = 0,
last: policy.Presentation = .{ .state = .{}, .card = false, .card_w = 0, .gutter_css = 0, .button = false, .handle = false },
/// Filling the list box or moving its selection must not read as a click.
filling: bool = false,
ui: ?Ui = null,

pub const Ui = struct {
    /// The card and its drag edge, as one overlay child.
    holder: *wk.GtkWidget,
    card: *wk.GtkWidget,
    header: *wk.GtkWidget,
    scroller: *wk.GtkWidget,
    list: *wk.GtkWidget,
    handle: *wk.GtkWidget,
    /// The nav bar's contents button (compact layout only).
    button: *wk.GtkWidget,
    /// Reports the page area's size; draws nothing, takes no input.
    sizer: *wk.GtkWidget,
};

// -------------------------------------------------------------------------
// Widgets
// -------------------------------------------------------------------------

/// Build the card over `overlay` (the overlay holding the web view) and the
/// contents button at the front of `bar_row`. Call before anything that
/// should paint over the card (the find card) is added to the overlay.
pub fn buildUi(self: *ViewerTOC, v: *Viewer, overlay: *wk.GtkWidget, bar_row: *wk.GtkWidget) void {
    const sizer = wk.gtk_drawing_area_new();
    wk.gtk_widget_set_hexpand(sizer, 1);
    wk.gtk_widget_set_vexpand(sizer, 1);
    wk.gtk_widget_set_can_target(sizer, 0);
    wk.gtk_overlay_add_overlay(overlay, sizer);

    const margin: c_int = @intFromFloat(toc_layout.margin_dip);
    const holder = wk.gtk_box_new(wk.orientation_horizontal, 0);
    wk.gtk_widget_set_halign(holder, wk.align_start);
    wk.gtk_widget_set_valign(holder, wk.align_start);
    wk.gtk_widget_set_margin_start(holder, margin);
    wk.gtk_widget_set_margin_top(holder, margin);
    wk.gtk_widget_set_margin_bottom(holder, margin);

    const card = wk.gtk_box_new(wk.orientation_vertical, 0);
    wk.gtk_widget_add_css_class(card, "card");
    wk.gtk_widget_set_overflow(card, wk.overflow_hidden);

    // The pinned caption: outside the scroller, so the rows scroll under it
    // and the scrollbar's track stops below it.
    const header = wk.gtk_label_new("CONTENTS");
    wk.gtk_label_set_xalign(header, 0);
    wk.gtk_widget_add_css_class(header, "caption-heading");
    wk.gtk_widget_add_css_class(header, "dim-label");
    wk.gtk_widget_set_margin_start(header, @intFromFloat(toc_layout.label_inset_dip));
    wk.gtk_widget_set_margin_end(header, @intFromFloat(toc_layout.label_inset_dip));
    wk.gtk_widget_set_margin_top(header, @intFromFloat(toc_layout.header_pad_v_dip));
    wk.gtk_widget_set_margin_bottom(header, @intFromFloat(toc_layout.header_pad_v_dip));

    const list = wk.gtk_list_box_new();
    wk.gtk_widget_add_css_class(list, "navigation-sidebar");
    wk.gtk_list_box_set_activate_on_single_click(list, 1);
    const scroller = wk.gtk_scrolled_window_new();
    wk.gtk_scrolled_window_set_policy(scroller, wk.policy_never, wk.policy_automatic);
    wk.gtk_scrolled_window_set_propagate_natural_height(scroller, 1);
    wk.gtk_scrolled_window_set_child(scroller, list);
    wk.gtk_box_append(card, header);
    wk.gtk_box_append(card, scroller);

    // The drag edge, beside the card's right edge in the margin it leaves.
    const handle = wk.gtk_drawing_area_new();
    wk.gtk_widget_set_size_request(handle, @intFromFloat(toc_layout.handle_grab_dip), -1);
    wk.gtk_widget_set_cursor_from_name(handle, "col-resize");
    const drag = wk.gtk_gesture_drag_new();
    wk.gtk_widget_add_controller(handle, drag);

    wk.gtk_box_append(holder, card);
    wk.gtk_box_append(holder, handle);
    wk.gtk_widget_set_visible(holder, 0);
    wk.gtk_overlay_add_overlay(overlay, holder);

    const button = wk.gtk_button_new_from_icon_name("sidebar-show-symbolic");
    wk.gtk_widget_set_tooltip_text(button, "Show Contents");
    wk.gtk_widget_add_css_class(button, "flat");
    wk.gtk_widget_set_focus_on_click(button, 0);
    wk.gtk_widget_set_visible(button, 0);
    wk.gtk_box_prepend(bar_row, button);

    self.ui = .{
        .holder = holder,
        .card = card,
        .header = header,
        .scroller = scroller,
        .list = list,
        .handle = handle,
        .button = button,
        .sizer = sizer,
    };
    _ = wk.g_signal_connect_data(sizer, "resize", @ptrCast(&onResize), v, null, 0);
    _ = wk.g_signal_connect_data(list, "row-activated", @ptrCast(&onRowActivated), v, null, 0);
    _ = wk.g_signal_connect_data(button, "clicked", @ptrCast(&onButtonClicked), v, null, 0);
    _ = wk.g_signal_connect_data(drag, "drag-begin", @ptrCast(&onDragBegin), v, null, 0);
    _ = wk.g_signal_connect_data(drag, "drag-update", @ptrCast(&onDragUpdate), v, null, 0);
    _ = wk.g_signal_connect_data(drag, "drag-end", @ptrCast(&onDragEnd), v, null, 0);
}

/// Free what this side owns. The widgets belong to the viewer's box and may
/// already be gone (the web view's `destroy` runs this), so none is touched.
pub fn deinit(self: *ViewerTOC) void {
    self.clearItems();
    self.items.deinit(std.heap.c_allocator);
    self.setActiveId(null);
}

fn clearItems(self: *ViewerTOC) void {
    const alloc = std.heap.c_allocator;
    for (self.items.items) |it| {
        alloc.free(it.id);
        alloc.free(it.text);
    }
    self.items.clearRetainingCapacity();
}

fn setActiveId(self: *ViewerTOC, id: ?[]const u8) void {
    const alloc = std.heap.c_allocator;
    const dup: ?[]u8 = if (id) |s| (alloc.dupe(u8, s) catch null) else null;
    if (self.active) |old| alloc.free(old);
    self.active = dup;
}

// -------------------------------------------------------------------------
// What the page reports
// -------------------------------------------------------------------------

/// The page's heading index (`viewer.js` `indexHeadings`). Empty is real: it
/// is how a document with fewer than two headings, or none, retracts the
/// card. A website posting the same message finds a pane that is not
/// markdown, and `layout` shows nothing for it.
pub fn setHeadings(self: *ViewerTOC, v: *Viewer, headings: []const bridge.Heading) void {
    const alloc = std.heap.c_allocator;
    self.clearItems();
    self.setActiveId(null);
    var levels_buf: [512]u8 = undefined;
    var depths_buf: [512]u8 = undefined;
    const n = @min(headings.len, levels_buf.len);
    for (headings[0..n], 0..) |h, i| levels_buf[i] = h.level;
    policy.depths(levels_buf[0..n], depths_buf[0..n]);
    for (headings[0..n], 0..) |h, i| {
        const id = alloc.dupe(u8, h.id) catch break;
        const text = alloc.dupeZ(u8, h.text) catch {
            alloc.free(id);
            break;
        };
        self.items.append(alloc, .{ .id = id, .text = text, .depth = depths_buf[i] }) catch {
            alloc.free(id);
            alloc.free(text);
            break;
        };
    }
    log.info("viewer toc headings={d}", .{self.items.items.len});
    self.fillList();
    self.layout(v);
}

/// The section at the top of the pane (or the one a row click pinned).
pub fn setActive(self: *ViewerTOC, id: ?[]const u8) void {
    self.setActiveId(id);
    self.syncSelection(true);
}

/// The pane moved to another page: its body has no gutter, and a pane that
/// left markdown has no contents. Called from the viewer's chrome sync.
pub fn syncMode(self: *ViewerTOC, v: *Viewer) void {
    if (v.mode != .markdown and self.items.items.len > 0) {
        self.clearItems();
        self.setActiveId(null);
        self.fillList();
    }
    self.layout(v);
}

/// A new page started loading: whatever padding the old one had is gone.
pub fn pageGone(self: *ViewerTOC) void {
    self.gutter_pushed = 0;
}

// -------------------------------------------------------------------------
// Layout
// -------------------------------------------------------------------------

/// One layout pass: decide (`viewer_toc.present`), then place the card,
/// the edge, the button and the page gutter to match.
fn layout(self: *ViewerTOC, v: *Viewer) void {
    const ui = self.ui orelse return;
    if (self.pane_w <= 0) return;
    if (self.width == 0) self.width = prefs.loadWidth(std.heap.c_allocator);
    const p = policy.present(self.state, self.pane_w, self.items.items.len, self.width, v.mode == .markdown);
    if (p.state.mode != self.state.mode or p.card != self.last.card) {
        log.info("viewer toc layout={s} open={} items={d} pane={d:.0} card={d:.0}", .{
            @tagName(p.state.mode),
            p.state.open,
            self.items.items.len,
            self.pane_w,
            p.card_w,
        });
    }
    self.state = p.state;
    self.last = p;
    self.layouts += 1;

    if (p.card) {
        wk.gtk_widget_set_size_request(ui.card, @intFromFloat(p.card_w), -1);
        const header_h: f32 = @floatFromInt(@max(wk.gtk_widget_get_height(ui.header), 16) +
            2 * @as(c_int, @intFromFloat(toc_layout.header_pad_v_dip)));
        wk.gtk_scrolled_window_set_max_content_height(ui.scroller, policy.maxRowsHeight(self.pane_h, header_h));
    }
    wk.gtk_widget_set_visible(ui.holder, @intFromBool(p.card));
    wk.gtk_widget_set_visible(ui.handle, @intFromBool(p.handle));
    wk.gtk_widget_set_visible(ui.button, @intFromBool(p.button));
    wk.gtk_widget_set_tooltip_text(ui.button, if (p.state.open) "Hide Contents" else "Show Contents");
    self.pushGutter(v, p.gutter_css);
    if (p.card) self.syncSelection(true);
}

/// Tell the page how much left padding to reserve (CSS px == GTK px). The
/// card floats OVER the web view; insetting the view instead would leave a
/// strip of window background where the document's own should be.
fn pushGutter(self: *ViewerTOC, v: *Viewer, css: f32) void {
    if (css == self.gutter_pushed) return;
    if (!v.page_live or !v.mode.usesTemplate()) return;
    self.gutter_pushed = css;
    var buf: [96]u8 = undefined;
    const js = std.fmt.bufPrint(&buf, "window.__viewer && window.__viewer.setGutter({d})", .{css}) catch return;
    v.runQuiet(js);
}

fn onResize(_: *wk.GtkWidget, w: c_int, h: c_int, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    const self = &v.toc;
    const nw: f32 = @floatFromInt(w);
    const nh: f32 = @floatFromInt(h);
    if (nw == self.pane_w and nh == self.pane_h) return;
    self.pane_w = nw;
    self.pane_h = nh;
    self.layout(v);
}

// -------------------------------------------------------------------------
// The rows
// -------------------------------------------------------------------------

fn fillList(self: *ViewerTOC) void {
    const ui = self.ui orelse return;
    self.filling = true;
    defer self.filling = false;
    wk.gtk_list_box_remove_all(ui.list);
    for (self.items.items) |it| {
        const l = wk.gtk_label_new(it.text.ptr);
        wk.gtk_label_set_xalign(l, 0);
        // Two lines, then an ellipsis (Mac's `.lineLimit(2)`). A tiny
        // max-width keeps a long heading from widening the card: the card's
        // width is the layout's, and the label wraps inside it.
        wk.gtk_label_set_wrap(l, 1);
        wk.gtk_label_set_wrap_mode(l, wk.wrap_word_char);
        wk.gtk_label_set_lines(l, toc_layout.max_row_lines);
        wk.gtk_label_set_ellipsize(l, wk.ellipsize_end);
        wk.gtk_label_set_max_width_chars(l, 1);
        wk.gtk_widget_set_margin_start(l, policy.rowIndent(it.depth));
        wk.gtk_widget_set_margin_end(l, @intFromFloat(toc_layout.text_inset_dip));
        wk.gtk_list_box_append(ui.list, l);
    }
}

/// Select the active heading's row (the selection pill) without it reading as
/// a click, and keep it in view when `reveal` - a long contents list must
/// follow the reader, not strand the highlight off the bottom of the card.
fn syncSelection(self: *ViewerTOC, reveal: bool) void {
    const ui = self.ui orelse return;
    const was = self.filling;
    self.filling = true;
    defer self.filling = was;
    const want = self.active orelse return wk.gtk_list_box_select_row(ui.list, null);
    for (self.items.items, 0..) |it, i| {
        if (!std.mem.eql(u8, it.id, want)) continue;
        const row = wk.gtk_list_box_get_row_at_index(ui.list, @intCast(i)) orelse return;
        wk.gtk_list_box_select_row(ui.list, row);
        if (reveal) revealRow(ui, row);
        return;
    }
    wk.gtk_list_box_select_row(ui.list, null);
}

fn revealRow(ui: Ui, row: *wk.GtkWidget) void {
    var r: wk.GrapheneRect = .{};
    // Fails before the rows are allocated; the next active report retries.
    if (wk.gtk_widget_compute_bounds(row, ui.list, &r) == 0) return;
    const adj = wk.gtk_scrolled_window_get_vadjustment(ui.scroller);
    const top = wk.gtk_adjustment_get_value(adj);
    const page = wk.gtk_adjustment_get_page_size(adj);
    if (page <= 0) return;
    const y0: f64 = r.y;
    const y1: f64 = r.y + r.h;
    if (y0 < top) {
        wk.gtk_adjustment_set_value(adj, y0);
    } else if (y1 > top + page) {
        wk.gtk_adjustment_set_value(adj, y1 - page);
    }
}

fn onRowActivated(_: *wk.GtkWidget, row: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    if (v.toc.filling) return;
    const i = wk.gtk_list_box_row_get_index(row);
    if (i < 0) return;
    v.toc.clickRow(v, @intCast(i));
}

/// A row was clicked: scroll the page there. The page pins its spy to the
/// heading for the length of the smooth scroll and posts it back as
/// `active`, which is what moves the selection - so the highlight cannot
/// walk off the row the reader asked for.
pub fn clickRow(self: *ViewerTOC, v: *Viewer, index: usize) void {
    if (index >= self.items.items.len) return;
    const id = self.items.items[index].id;
    const alloc = std.heap.c_allocator;
    var js: std.ArrayList(u8) = .empty;
    defer js.deinit(alloc);
    js.appendSlice(alloc, "window.__viewer.scrollToAnchor(") catch return;
    content.appendJsString(alloc, &js, id) catch return;
    js.append(alloc, ')') catch return;
    log.info("viewer toc click id={s}", .{id});
    v.runQuiet(js.items);
    const next = policy.afterRowClick(self.state);
    if (next.open != self.state.open) {
        self.state = next;
        self.layout(v);
    }
}

/// Click the row whose heading id is `id` (the steps runner's `toc-row`).
pub fn clickRowById(self: *ViewerTOC, v: *Viewer, id: []const u8) bool {
    for (self.items.items, 0..) |it, i| {
        if (!std.mem.eql(u8, it.id, id)) continue;
        self.clickRow(v, i);
        return true;
    }
    return false;
}

// -------------------------------------------------------------------------
// The contents button and the drag edge
// -------------------------------------------------------------------------

fn onButtonClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    v.toc.toggle(v);
}

/// The contents button: slide the overlay in or out.
pub fn toggle(self: *ViewerTOC, v: *Viewer) void {
    self.state = policy.toggle(self.state);
    self.layout(v);
}

fn onDragBegin(_: *wk.GtkEventController, _: f64, _: f64, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    v.toc.beginDrag();
}

fn onDragUpdate(_: *wk.GtkEventController, dx: f64, _: f64, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    v.toc.updateDrag(v, dx);
}

fn onDragEnd(_: *wk.GtkEventController, dx: f64, _: f64, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    v.toc.endDrag(v, dx);
}

pub fn beginDrag(self: *ViewerTOC) void {
    self.drag_start = self.last.card_w;
}

/// The card and the page's gutter follow the edge in the same pass.
pub fn updateDrag(self: *ViewerTOC, v: *Viewer, dx: f64) void {
    if (!self.last.handle or self.drag_start == 0) return;
    self.width = policy.dragWidth(self.drag_start, dx, self.pane_w);
    self.layout(v);
}

/// The drag is over: the width is every viewer pane's from now on.
pub fn endDrag(self: *ViewerTOC, v: *Viewer, dx: f64) void {
    if (!self.last.handle or self.drag_start == 0) return;
    self.updateDrag(v, dx);
    self.drag_start = 0;
    prefs.saveWidth(std.heap.c_allocator, self.width);
    log.info("viewer toc width={d:.0} saved", .{self.width});
}

// -------------------------------------------------------------------------
// Test seam
// -------------------------------------------------------------------------

/// `mode= open= card= button= handle= rows= active= selected= width=
/// cardw= gutter= pane=WxH layouts=` - what the steps runner's `toc` prints.
pub fn describe(self: *const ViewerTOC, buf: []u8) []const u8 {
    var selected: []const u8 = "-";
    var shown_w: c_int = 0;
    var button_shown = false;
    if (self.ui) |ui| {
        if (wk.gtk_list_box_get_selected_row(ui.list)) |row| {
            const i = wk.gtk_list_box_row_get_index(row);
            if (i >= 0 and @as(usize, @intCast(i)) < self.items.items.len) selected = self.items.items[@intCast(i)].id;
        }
        if (wk.gtk_widget_get_visible(ui.holder) != 0) shown_w = wk.gtk_widget_get_width(ui.card);
        button_shown = wk.gtk_widget_get_visible(ui.button) != 0;
    }
    return std.fmt.bufPrint(buf, "mode={s} open={} card={} button={} handle={} rows={d} active={s} selected={s} width={d:.0} cardw={d:.0} shownw={d} gutter={d:.0} pane={d:.0}x{d:.0} layouts={d}", .{
        @tagName(self.state.mode),
        self.state.open,
        self.last.card,
        button_shown,
        self.last.handle,
        self.items.items.len,
        self.active orelse "-",
        selected,
        self.width,
        self.last.card_w,
        shown_w,
        self.gutter_pushed,
        self.pane_w,
        self.pane_h,
        self.layouts,
    }) catch buf[0..0];
}

/// The heading rows' ids and depths, `id:depth|id:depth...`.
pub fn describeRows(self: *const ViewerTOC, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (self.items.items, 0..) |it, i| {
        if (i > 0) w.writeByte('|') catch break;
        w.print("{s}:{d}", .{ it.id, it.depth }) catch break;
    }
    return w.buffered();
}

/// The contents button, for the steps runner's `click contents`.
pub fn buttonWidget(self: *const ViewerTOC) ?*wk.GtkWidget {
    return if (self.ui) |ui| ui.button else null;
}
