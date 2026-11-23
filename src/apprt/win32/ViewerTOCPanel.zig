//! The viewer pane's native table-of-contents card (T160, design P5): an
//! owner-painted child window listing the document's headings, nested by
//! level, with the section being read highlighted as the page scrolls.
//!
//! The Windows port of Mac's `ViewerTOCPanel` + `ViewerSidePanel`. The card
//! chrome IS the banner's glass card (`banner_card.zig` renders the backdrop
//! — T131's port of `GlassCardBackground`), so a TOC card and a banner in the
//! pane next door read as the same component; the row metrics, the selection
//! pill, the gutter⇄overlay switch and the drag-to-resize handle come from
//! `viewer_toc_layout.zig`, where they assert at every scale without a
//! window.
//!
//! ## Who does what
//!
//! The panel OWNS its window, fonts, painting, scrolling, hover, and the
//! resize drag's mouse tracking. The PANE owns the policy: when the card
//! exists, which layout it is in, the width preference, pushing the page
//! gutter, and what a row click means (`tocRowClicked` runs the page's
//! `scrollToAnchor`, which pins the scroll spy — the pin itself lives in
//! `viewer.js` and this side must not fight it; the highlight simply follows
//! the `active` messages the page posts).
//!
//! Heading ids and the active id are BORROWED from the pane's own storage
//! (`ViewerPane.headings` / `active_heading`): everything runs on the UI
//! thread, and the pane rebuilds this panel's rows in the same call that
//! replaces that storage, so no borrow outlives its owner. Row TEXT is
//! converted to UTF-16 once at sync time and owned here — paint runs far more
//! often than headings change.
//!
//! ## Planes (T1784)
//!
//! This file keeps the state, the window's lifetime, the state the pane
//! pushes, scrolling, hit testing and the window procedure. Measurement,
//! placement and the show/hide slide live in `viewer_toc_place.zig`; painting
//! lives in `viewer_toc_paint.zig`. The alias blocks where each plane's code
//! used to sit are this file's surface for it, so `self.f(x)` reads the same
//! at every call site whichever file `f` lives in.
const ViewerTOCPanel = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
// Test-only (T467): the class-level resize/redraw probe. Imported at file
// scope so its own positive and negative controls are queued into the win32
// test lane along with the class test below.
const class_redraw = @import("class_redraw.zig");
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const system_colors = @import("system_colors.zig");
const banner_card = @import("banner_card.zig");
const toc = @import("viewer_toc_layout.zig");
const file_tree = @import("viewer_file_tree.zig");
const diff = @import("viewer_diff.zig");
const icon_button = @import("icon_button.zig");
const viewer_find = @import("viewer_find.zig");
const viewer_accel = @import("viewer_accel.zig");
const input = @import("../../input.zig");
const utf16_text = @import("utf16_text.zig");
const ViewerPane = @import("ViewerPane.zig");

const log = std.log.scoped(.viewer_toc);
const paint_probe = @import("paint_probe.zig");
const gutter_bar = @import("gutter_bar.zig");
const toc_comp = @import("viewer_toc_comp.zig");

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyViewerTOC");
const class_name_utf8 = "GhozttyViewerTOC";

/// The diff card's filter field (T1336): its control id, and how much it may
/// hold. A path query longer than this is not a query anybody types.
const filter_edit_id: usize = 1;
const filter_cap_utf16: usize = 256;

/// The compact overlay's slide timer (T543) and its frame interval. 15ms is a
/// hair under a 60Hz frame, so a frame is never skipped waiting for the next
/// tick; the step is time-based, so a slower tick shortens the animation
/// rather than stretching it.
pub const SLIDE_TIMER_ID: usize = 1;
pub const SLIDE_TICK_MS: u32 = 15;
/// The one end-of-slide tick of a slide declared to the compositor (T2764):
/// a plain timer, because nothing moves on it - it only hands the card back
/// from the visual to its window.
pub const SLIDE_END_TIMER_ID: usize = 2;

/// The document page's own background, kept in step with viewer.css (and with
/// Mac's `SidePanelCard.documentBackground`) so the card's opaque composite is
/// the same color as the page it sits on: white in light, GitHub's `#0d1117`
/// in dark.
pub fn documentBackground(dark: bool) color_math.Rgb {
    return if (dark)
        .{ .r = 13, .g = 17, .b = 23 }
    else
        .{ .r = 255, .g = 255, .b = 255 };
}

/// What a row IS, which decides how it paints and what clicking it does.
/// A contents card is all `.heading`; a diff card is the other three.
const Kind = enum { heading, section, folder, file };

/// One display row: a borrowed id, owned UTF-16 label, indent depth, and its
/// measured slot in the list (list coordinates: y=0 at the top of the first
/// row's padding, i.e. just under the header's own inset).
///
/// A diff row carries two more owned labels — the one-letter git status and
/// the `+12 −3` line counts — because they are drawn on their own baselines
/// beside the name rather than being part of it.
pub const Row = struct {
    id: []const u8,
    text16: []u16,
    depth: u8,
    kind: Kind = .heading,
    /// `.file` rows: the status badge's letter, and what it means. `.folder`
    /// rows: the disclosure chevron.
    badge16: []u16 = &.{},
    tone: chrome_theme.Tone = .neutral,
    /// `.file` rows: the line counts, as two runs so each can carry its own
    /// color — `+12` in the added green and `−3` in the removed red, the
    /// idiom every diff tool shares. A binary file has no counts, so `adds16`
    /// carries `bin` and `binary` says to draw it neutral.
    adds16: []u16 = &.{},
    dels16: []u16 = &.{},
    binary: bool = false,
    /// `.folder` rows: whether the reader has clicked it shut.
    collapsed: bool = false,
    /// `.file` rows of a FILTERED tree: the file's directory, owned, drawn as
    /// a second line under the name (T1336). Empty otherwise.
    detail16: []u16 = &.{},
    y: i32 = 0,
    h: i32 = 0,
    /// Measured widths of the two side labels, filled by `measureRows`.
    badge_w: i32 = 0,
    counts_w: i32 = 0,

    /// A row a click selects or toggles. A section header is a label.
    pub fn interactive(self: Row) bool {
        return self.kind != .section;
    }
};

hwnd: w32.HWND,
pane: *ViewerPane,
alloc: Allocator,

/// The filter field (T1336): a real `EDIT`, shown only while the card lists a
/// diff's files. Null when it could not be created, which leaves a card that
/// lists and cannot filter rather than no card.
filter_edit: ?w32.HWND = null,
/// The EDIT's single-line height in its font, measured with the rows.
filter_edit_h: i32 = 14,
/// Set while this side writes the field's text itself, so the EN_CHANGE that
/// write raises is not mistaken for the reader typing.
filter_syncing: bool = false,
/// The clear button's pointer state.
clear_hover: bool = false,
clear_pressed: bool = false,

rows: std.ArrayList(Row) = .empty,
/// Total measured list height (rows + inter-row spacing), px.
list_h: i32 = 0,
/// Whether rows need re-measuring before the next placement (new items, new
/// width, or new scale).
dirty: bool = true,

/// Index of the active (highlighted) row, -1 when none.
active: i32 = -1,
hover: i32 = -1,
tracking: bool = false,

/// Scroll offset into the list, px, >= 0.
scroll: i32 = 0,

/// The layout of the last placement, in this window's client coordinates
/// (window origin). `place` refreshes it; every hit test reads it.
layout: toc.Layout = .{ .which = .hidden },
/// The measured card width the rows were laid against, px.
measured_w: i32 = 0,
measured_scale: f32 = 0,

/// Resize drag state: the card width (DIP) when the drag started, and the
/// mouse x (client px) it started at. Null when not dragging.
drag: ?struct { start_dip: f32, start_x: i32 } = null,
/// The pointer is over the resize handle (T2265): its accent bar shows at
/// half strength, as a split divider's does.
handle_hover: bool = false,
/// The handle bar last painted, for the debug-log oracle.
handle_bar_logged: ?gutter_bar.Strength = null,

/// Compact-overlay slide (T543). `slide` is where the card IS — 0 parked off
/// the pane's left edge, 1 fully in — and `slide_want` is where the toggle
/// says it should end up; a timer walks the first toward the second. Storing
/// the position rather than an animation start/end is what makes a fast
/// double-toggle correct for free: reversing changes the target, and the card
/// carries on from wherever it had got to.
slide: f32 = 1.0,
slide_want: f32 = 1.0,
slide_timer: bool = false,
slide_last_ms: i64 = 0,
/// The window geometry the slide moves over, from the last placement: the
/// resting (fully-in) origin and the window size.
slide_x: i32 = 0,
slide_y: i32 = 0,
slide_w: i32 = 1,
slide_h: i32 = 1,
/// Frame-clock steps the stepped slide has taken, for the done line.
slide_steps: u32 = 0,

/// The slide on the compositor (T2764). `comp` is the viewer host's
/// DirectComposition target, built when a slide is declared and released
/// when it ends or is cancelled (T3040: a viewer at rest holds no device of
/// the card's, and the D3D11 device is the process's own). While `comp_slide`
/// is set the card's window is hidden at its resting place and the visual is
/// the card, moving from `comp_t0` toward `comp_want` since `comp_start_ms`
/// along `comp_plan`; `comp_geom` is the resting rect the plan was made for.
comp: ?toc_comp.Host = null,
comp_slide: bool = false,
comp_t0: f32 = 0,
comp_want: f32 = 0,
comp_start_ms: i64 = 0,
comp_plan: toc.SlidePlan = .{ .c = .{ 0, 0, 0, 0 }, .span_s = 0, .end_x = 0 },
comp_geom: [4]i32 = .{ 0, 0, 0, 0 },
/// Slides declared to the compositor, and slides that could not be (for the
/// pane's own test, which asserts the path it took).
comp_slides: u32 = 0,
comp_failures: u32 = 0,
/// The presentation the last placement chose. A change of MODE snaps — the
/// pane growing past the gutter threshold is a layout switch, not a toggle,
/// and a card sliding out from under a window someone is dragging narrower
/// reads as a glitch rather than as an animation.
last_mode: toc.Mode = .hidden,
/// The window region `place()` last applied (T2946), so a bounds sync that
/// leaves the card's shape alone - every tick of a divider drag or fold glide
/// past a narrow viewer - does not rebuild it. `SetWindowRgn` is synchronous
/// with the window manager and cost 0.4-1.6 ms a sync at 4K; the repaint it
/// used to imply is the class's CS_HREDRAW|CS_VREDRAW (T467).
applied_rgn: ?RgnKey = null,
/// The rect (x, y, w, h, client coordinates of the pane) the card's window
/// was last left resting at by a full `place()`, or null when a slide was
/// still running then (T2946).
placed_rect: ?[4]i32 = null,

/// The card box last reported by `logCardMetrics`, so the line is emitted once
/// per change rather than once per bounds sync.
logged_header: i32 = -1,
logged_card_w: i32 = -1,
logged_card_h: i32 = -1,

scale: f32 = 1.0,
row_font: ?*anyopaque = null,
header_font: ?*anyopaque = null,
line_h: i32 = 16,
caption_line_h: i32 = 14,

// Theme, derived in applyTheme.
dark: bool = true,
doc_bg: color_math.Rgb = .{ .r = 13, .g = 17, .b = 23 },
card_fill: color_math.Rgb = .{ .r = 28, .g = 31, .b = 37 },
text_ref: u32 = 0x00FFFFFF,
secondary_ref: u32 = 0x00AAAAAA,
/// The filter's recessed well, and the brush its EDIT paints its background
/// with so the control and the well are one surface.
field_rgb: color_math.Rgb = .{ .r = 20, .g = 23, .b = 29 },
edit_brush: ?w32.HBRUSH = null,

// Cached card backdrop DIB (the BannerOverlay pattern): regenerated when the
// band size, the theme, or the scale moves.
card_dc: ?w32.HDC = null,
card_bmp: ?*anyopaque = null,
card_w: i32 = 0,
card_h: i32 = 0,
card_bg: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
card_scale: f32 = 0,

var class_registered: bool = false;

fn registerClass(hinstance: ?w32.HINSTANCE) void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // CS_HREDRAW | CS_VREDRAW (T467): the card is a rounded band drawn
        // against the window's own bounds - the rim and its shadow sit on the
        // edges, and in gutter mode the card is inset inside a strip whose
        // width `place()` re-derives from the pane. `place()` happens to redraw
        // today because `SetWindowRgn(.., TRUE)` runs right after its
        // `MoveWindow`, but that is a side effect of the rounded-corner clip,
        // not a repaint contract: the gutter branch that passes a null region
        // would lose it. The class style is the property being relied on, so
        // it is the class that states it.
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // every pixel painted in WM_PAINT
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("viewer TOC class registration failed", .{});
        return;
    }
    class_registered = true;
}

/// Create the panel as a HIDDEN child of the pane's host window. Null when
/// the window cannot be created — the pane then has no card, which degrades
/// to the pre-T160 world rather than to a crash.
pub fn create(
    alloc: Allocator,
    pane: *ViewerPane,
    hinstance: ?w32.HINSTANCE,
    parent: w32.HWND,
) ?*ViewerTOCPanel {
    registerClass(hinstance);
    if (!class_registered) return null;

    const self = alloc.create(ViewerTOCPanel) catch return null;

    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        // Shown by place() when a layout calls for it. WS_CLIPCHILDREN so the
        // card's own paint never draws over the filter field (T1336), which
        // would flash the well's fill across the text on every repaint.
        w32.WS_CHILD | w32.WS_CLIPCHILDREN,
        0,
        0,
        0,
        0,
        parent,
        null,
        hinstance,
        null,
    ) orelse {
        alloc.destroy(self);
        return null;
    };

    self.* = .{
        .hwnd = hwnd,
        .pane = pane,
        .alloc = alloc,
    };
    self.filter_edit = createFilterEdit(hwnd, hinstance);
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.applyTheme();
    return self;
}

/// The filter field: a borderless single-line EDIT, hidden until the card
/// lists files. No WS_BORDER for the find card's reason — it sits in a well
/// painted on a card that already has an edge, and a second rectangle inside
/// it reads as a dialog. The cue banner is Mac's placeholder, and the
/// Windows-native way to label a search box without a caption.
fn createFilterEdit(parent: w32.HWND, hinstance: ?w32.HINSTANCE) ?w32.HWND {
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.ES_AUTOHSCROLL,
        0,
        0,
        0,
        0,
        parent,
        @ptrFromInt(filter_edit_id),
        hinstance,
        null,
    ) orelse {
        log.warn("viewer TOC filter field could not be created; the file list cannot be filtered", .{});
        return null;
    };
    _ = w32.SendMessageW(edit, w32.EM_LIMITTEXT, filter_cap_utf16 - 1, 0);
    _ = w32.SendMessageW(
        edit,
        w32.EM_SETCUEBANNER,
        1,
        @bitCast(@intFromPtr(std.unicode.utf8ToUtf16LeStringLiteral("Filter files"))),
    );
    return edit;
}

/// The card whose FILTER FIELD is `hwnd`, if any — the main message loop's
/// routing hook, identified by the parent's class exactly like
/// `ViewerNavBar.owningEdit`.
pub fn owningEdit(hwnd: w32.HWND) ?*ViewerTOCPanel {
    const parent = w32.GetParent(hwnd) orelse return null;
    var name: [24:0]u16 = undefined;
    const n = w32.GetClassNameW(parent, &name, name.len);
    if (n <= 0) return null;
    const expect = std.unicode.utf8ToUtf16LeStringLiteral(class_name_utf8);
    if (!std.mem.eql(u16, name[0..@intCast(n)], expect)) return null;
    const self = fromHwnd(parent) orelse return null;
    if (self.filter_edit != hwnd) return null;
    return self;
}

pub fn destroy(self: *ViewerTOCPanel) void {
    self.stopSlide();
    self.cancelCompSlide();
    if (self.comp) |*h| h.deinit();
    self.comp = null;
    // Clear the back-pointer FIRST: DestroyWindow delivers messages
    // synchronously and they must not find a half-dead object.
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    self.clearRows();
    self.rows.deinit(self.alloc);
    self.releaseCardSurface();
    if (self.row_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    if (self.header_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    if (self.edit_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
    self.alloc.destroy(self);
}

fn fromHwnd(hwnd: w32.HWND) ?*ViewerTOCPanel {
    const v = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

// -------------------------------------------------------------------------
// State pushed by the pane
// -------------------------------------------------------------------------

fn clearRows(self: *ViewerTOCPanel) void {
    for (self.rows.items) |r| {
        self.alloc.free(r.text16);
        if (r.badge16.len > 0) self.alloc.free(r.badge16);
        if (r.adds16.len > 0) self.alloc.free(r.adds16);
        if (r.dels16.len > 0) self.alloc.free(r.dels16);
        if (r.detail16.len > 0) self.alloc.free(r.detail16);
    }
    self.rows.clearRetainingCapacity();
    self.list_h = 0;
}

/// How many items the card is OF, for the gutter/overlay/hidden decision: the
/// diff's whole file list, not the rows a filter happens to be showing. A
/// filter narrowed to one hit — or to none — must not retract the card, and
/// the field the reader is typing into with it (the same rule
/// `ViewerPane.updateTOC` applies to shut folders).
pub fn itemCount(self: *const ViewerTOCPanel) usize {
    if (self.pane.diffTree()) |tree| return tree.total_files;
    return self.rows.items.len;
}

/// The pinned header's height: the caption band, plus the filter while the
/// card lists files.
pub fn headerH(self: *const ViewerTOCPanel) i32 {
    return toc.headerHeightWith(
        self.caption_line_h,
        self.scale,
        self.showsFiles() and self.filter_edit != null,
    );
}

/// True while the filter field holds keyboard focus — what the pane asks to
/// answer `viewer_find.Focus.diff_filter`.
pub fn filterFocused(self: *const ViewerTOCPanel) bool {
    const edit = self.filter_edit orelse return false;
    return w32.GetFocus() == @as(?w32.HWND, edit);
}

/// Empty the field without that reading as the reader typing. The pane owns
/// the filter itself; this only keeps the control in step with it.
pub fn clearFilterField(self: *ViewerTOCPanel) void {
    const edit = self.filter_edit orelse return;
    if (w32.GetWindowTextLengthW(edit) == 0) return;
    self.filter_syncing = true;
    defer self.filter_syncing = false;
    _ = w32.SetWindowTextW(edit, std.unicode.utf8ToUtf16LeStringLiteral(""));
    self.clear_hover = false;
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// The field's text moved: hand it to the pane as UTF-8.
fn filterChanged(self: *ViewerTOCPanel) void {
    if (self.filter_syncing) return;
    const edit = self.filter_edit orelse return;
    var wide: [filter_cap_utf16]u16 = undefined;
    const n = w32.GetWindowTextW(edit, &wide, wide.len);
    var buf: [filter_cap_utf16 * 3]u8 = undefined;
    const len = if (n > 0) utf16_text.toUtf8Truncating(&buf, wide[0..@intCast(n)]) else 0;
    // Repaint first: the clear button appears with the first letter and goes
    // with the last, whatever the tree does with the text.
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    self.pane.setDiffFilter(buf[0..len]);
}

pub fn filterHasText(self: *const ViewerTOCPanel) bool {
    const edit = self.filter_edit orelse return false;
    return w32.GetWindowTextLengthW(edit) > 0;
}

// -------------------------------------------------------------------------
// Main-loop hooks (the filter EDIT's keys)
// -------------------------------------------------------------------------

/// Escape and Return while the filter field holds focus, routed here by the
/// main message loop (an EDIT never delivers these itself). Returns true when
/// consumed.
///
/// Escape goes through `viewer_find.fieldKeyAction`, the one precedence table
/// for the pane's fields, so it cannot drift from the address bar's and the
/// find card's rules. Return is the field's own: it opens the top hit.
pub fn handleEditKey(self: *ViewerTOCPanel, vk: u16) bool {
    const mods: viewer_find.Mods = .{
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
        .super = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0,
    };
    if (vk == w32.VK_RETURN) {
        if (mods.ctrl or mods.alt or mods.super or mods.shift) return false;
        self.pane.diffFilterSubmitted();
        return true;
    }
    const action = viewer_find.fieldKeyAction(vk, mods, .{
        .diff_filter = true,
        .find_open = self.pane.find_open,
    }) orelse return false;
    switch (action) {
        .clear_diff_filter => self.pane.diffFilterEscaped(),
        // Not reachable with the filter focused, and answering them here
        // would be acting on another field's behalf.
        .revert_address, .close_find, .find_next, .find_previous => return false,
    }
    return true;
}

/// The pane-scoped chords while the filter holds focus: the chords belong to
/// the PANE, and this card is inside the pane (the find card's rule).
pub fn handleEditChord(self: *ViewerTOCPanel, vk: u16) bool {
    const mods: input.Mods = .{
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
        .super = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0,
    };
    const chord = viewer_accel.paneChord(vk, mods) orelse return false;
    self.pane.handlePaneChord(chord);
    return true;
}

/// True when this card is listing a diff's changed files rather than a
/// document's headings. The pane owns the mode; the card simply follows it,
/// which is what makes one card serve both (Mac's `ViewerSidePanel`, with
/// `ViewerTOC` or `ViewerDiffPanel` inside it).
pub fn showsFiles(self: *const ViewerTOCPanel) bool {
    return self.pane.diffTree() != null;
}

/// How many FILE rows the card is showing — not how many rows it has, so the
/// header counts files rather than the folders between them.
pub fn fileRowCount(self: *const ViewerTOCPanel) usize {
    var n: usize = 0;
    for (self.rows.items) |r| {
        if (r.kind == .file) n += 1;
    }
    return n;
}

/// Rebuild the display rows from whichever list the pane is showing. Called by
/// the pane in the same breath as it replaces that list, so the borrowed ids
/// can never dangle. Measurement is deferred to `place` (it needs the card
/// width).
///
/// `keep_scroll` holds the list where it is — what shutting a folder wants,
/// since the row you clicked must not jump out from under the pointer. A new
/// document (or a new diff) starts at the top.
pub fn setItems(self: *ViewerTOCPanel, keep_scroll: bool) void {
    const scroll_before = self.scroll;
    self.clearRows();
    self.active = -1;
    self.hover = -1;
    self.scroll = 0;
    self.dirty = true;

    if (self.pane.diffTree()) |tree| {
        self.buildFileRows(tree);
    } else {
        self.buildHeadingRows();
    }
    // The pane dropped its filter (it left the diff): the field follows, so a
    // diff opened later in this pane does not show a stale query over an
    // unfiltered list.
    if (self.pane.diffFilter().len == 0) self.clearFilterField();

    if (keep_scroll) {
        self.scroll = scroll_before;
        self.clampScroll();
    }
    // Keep the selection continuous across a re-index (a live reload posts a
    // fresh headings list, then an active id; a diff poll rebuilds the tree
    // while the same file stays open).
    self.syncActiveFromPane(false);
}

fn buildHeadingRows(self: *ViewerTOCPanel) void {
    const items = self.pane.headings;
    // Depth is relative to the document's own top level (Mac's
    // `ViewerTOCItem.list`), so a file whose headings start at ## is not
    // indented for no reason.
    var top: u8 = 255;
    for (items) |h| top = @min(top, h.level);
    for (items) |h| {
        const text16 = std.unicode.utf8ToUtf16LeAlloc(self.alloc, h.text) catch continue;
        self.rows.append(self.alloc, .{
            .id = h.id,
            .text16 = text16,
            .depth = toc.depthOf(h.level, top),
            .kind = .heading,
        }) catch {
            self.alloc.free(text16);
            return;
        };
    }
}

/// The disclosure chevrons: a right-pointing single angle quote for a shut
/// folder, a down-pointing one for an open one.
const chevron_shut = std.unicode.utf8ToUtf16LeStringLiteral("\u{203A}");
const chevron_open = std.unicode.utf8ToUtf16LeStringLiteral("\u{2304}");

fn buildFileRows(self: *ViewerTOCPanel, tree: *const file_tree.Tree) void {
    for (tree.rows) |r| {
        const text16 = std.unicode.utf8ToUtf16LeAlloc(self.alloc, r.title) catch continue;
        var row: Row = .{
            .id = r.id,
            .text16 = text16,
            // The indent cap is the card's, not the tree's: a path nested
            // deeper than the card can indent still has to fit inside it.
            .depth = @min(r.depth, toc.max_depth),
            .collapsed = r.collapsed,
        };
        switch (r.kind) {
            .section => row.kind = .section,
            .folder => {
                row.kind = .folder;
                const glyph = if (r.collapsed) chevron_shut else chevron_open;
                row.badge16 = self.alloc.dupe(u16, glyph) catch &.{};
            },
            .file => {
                row.kind = .file;
                row.tone = file_tree.statusTone(r.status);
                row.badge16 = std.unicode.utf8ToUtf16LeAlloc(
                    self.alloc,
                    r.status.letter(),
                ) catch &.{};
                self.fillCounts(&row, r);
                if (r.detail.len > 0) {
                    row.detail16 = std.unicode.utf8ToUtf16LeAlloc(self.alloc, r.detail) catch &.{};
                }
            },
        }
        self.rows.append(self.alloc, row) catch {
            self.alloc.free(text16);
            if (row.badge16.len > 0) self.alloc.free(row.badge16);
            if (row.adds16.len > 0) self.alloc.free(row.adds16);
            if (row.dels16.len > 0) self.alloc.free(row.dels16);
            if (row.detail16.len > 0) self.alloc.free(row.detail16);
            return;
        };
    }
}

/// `+12` and `−3` for a text file, `bin` for one git would not diff. The minus
/// is U+2212, matching the page's own summary line rather than a hyphen. A
/// zero side is omitted rather than drawn as `+0`: a pure deletion should read
/// as a deletion at a glance.
fn fillCounts(self: *ViewerTOCPanel, row: *Row, f: file_tree.Row) void {
    if (f.binary) {
        row.binary = true;
        row.adds16 = std.unicode.utf8ToUtf16LeAlloc(self.alloc, "bin") catch &.{};
        return;
    }
    var buf: [24]u8 = undefined;
    if (f.additions > 0) {
        const t = std.fmt.bufPrint(&buf, "+{d}", .{f.additions}) catch return;
        row.adds16 = std.unicode.utf8ToUtf16LeAlloc(self.alloc, t) catch &.{};
    }
    if (f.deletions > 0) {
        const t = std.fmt.bufPrint(&buf, "\u{2212}{d}", .{f.deletions}) catch return;
        row.dels16 = std.unicode.utf8ToUtf16LeAlloc(self.alloc, t) catch &.{};
    }
}

/// Re-derive the highlighted row from `pane.active_heading` and reveal it.
/// `reveal` scrolls the list the minimum needed to show the row (Mac's
/// `proxy.scrollTo`); a plain re-sync after a rebuild skips that so a restore
/// does not yank the list around.
pub fn syncActiveFromPane(self: *ViewerTOCPanel, reveal: bool) void {
    // A diff card's selection is the file the pane has OPEN — there is no
    // scroll spy, because the page shows one file's patch at a time and the
    // click that opened it is the whole story.
    const id = if (self.showsFiles()) self.pane.diff_file else self.pane.active_heading;
    var next: i32 = -1;
    if (id) |wanted| {
        for (self.rows.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.id, wanted)) {
                next = @intCast(i);
                break;
            }
        }
    }
    if (next == self.active) return;
    self.active = next;
    if (reveal and next >= 0) self.revealRow(@intCast(next));
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// The DPI scale moved (monitor change): fonts and measurements are stale.
pub fn setScale(self: *ViewerTOCPanel, scale: f32) void {
    if (self.scale == scale) return;
    self.scale = scale;
    self.dirty = true;
}

/// Re-derive every color from the pane's color scheme. The card sits on the
/// DOCUMENT, so its composite base is the page background, not the terminal's.
pub fn applyTheme(self: *ViewerTOCPanel) void {
    self.dark = self.pane.pageScheme() != .light;
    self.doc_bg = documentBackground(self.dark);
    self.card_fill = banner_card.fillColor(self.doc_bg);
    const text = chrome_theme.textOn(self.card_fill);
    const secondary = chrome_theme.textSecondaryOn(self.card_fill);
    self.text_ref = w32.RGB(text.r, text.g, text.b);
    self.secondary_ref = w32.RGB(secondary.r, secondary.g, secondary.b);
    // The filter's well is a step off the card — darker in dark mode, lighter
    // in light — so it reads as a recess rather than as paint missing from the
    // card. The find card's well, by the same rule and the same step.
    const d: i32 = if (self.dark) -14 else 14;
    self.field_rgb = .{
        .r = icon_button.shadeChannel(self.card_fill.r, d),
        .g = icon_button.shadeChannel(self.card_fill.g, d),
        .b = icon_button.shadeChannel(self.card_fill.b, d),
    };
    if (self.edit_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
    self.edit_brush = w32.CreateSolidBrush(w32.RGB(self.field_rgb.r, self.field_rgb.g, self.field_rgb.b));
    if (self.filter_edit) |edit| {
        system_colors.applyControlThemeDark(edit, self.dark);
        _ = w32.InvalidateRect(edit, null, 1);
    }
    self.releaseCardSurface();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

// The code in `viewer_toc_place.zig` (T1784). These aliases ARE this file's surface for
// that code: they keep `self.f(x)` working at every call site.
const viewer_toc_place = @import("viewer_toc_place.zig");
pub const px = viewer_toc_place.px;
pub const ensureFonts = viewer_toc_place.ensureFonts;
pub const measureRows = viewer_toc_place.measureRows;
pub const measureText = viewer_toc_place.measureText;
pub const neededHeight = viewer_toc_place.neededHeight;
pub const Placement = viewer_toc_place.Placement;
pub const place = viewer_toc_place.place;
pub const filterBoxes = viewer_toc_place.filterBoxes;
pub const placeFilterEdit = viewer_toc_place.placeFilterEdit;
pub const logCardMetrics = viewer_toc_place.logCardMetrics;
pub const showAbove = viewer_toc_place.showAbove;
pub const setVisible = viewer_toc_place.setVisible;
pub const compWanted = viewer_toc_place.compWanted;
pub const currentT = viewer_toc_place.currentT;
pub const slideOnCompositor = viewer_toc_place.slideOnCompositor;
pub const declareCompSlide = viewer_toc_place.declareCompSlide;
pub const compFailed = viewer_toc_place.compFailed;
pub const slideMs = viewer_toc_place.slideMs;
pub const debugStall = viewer_toc_place.debugStall;
pub const compSlideTick = viewer_toc_place.compSlideTick;
pub const finishCompSlide = viewer_toc_place.finishCompSlide;
pub const cancelCompSlide = viewer_toc_place.cancelCompSlide;
pub const releaseComp = viewer_toc_place.releaseComp;
pub const compHost = viewer_toc_place.compHost;
pub const snapshotCard = viewer_toc_place.snapshotCard;
pub const paintToPixels = viewer_toc_place.paintToPixels;
pub const windowX = viewer_toc_place.windowX;
pub const moveToSlide = viewer_toc_place.moveToSlide;
pub const startSlide = viewer_toc_place.startSlide;
pub const stopSlide = viewer_toc_place.stopSlide;
pub const tickSlide = viewer_toc_place.tickSlide;
pub const settleSlide = viewer_toc_place.settleSlide;
pub const sliding = viewer_toc_place.sliding;
pub const slidingOnCompositor = viewer_toc_place.slidingOnCompositor;
pub const hide = viewer_toc_place.hide;
// -------------------------------------------------------------------------
// Scrolling
// -------------------------------------------------------------------------

/// The list viewport's height: the card minus its pinned header and the list
/// insets.
pub fn viewportHeight(self: *const ViewerTOCPanel) i32 {
    return @max(
        self.layout.card.height() -
            self.headerH() -
            2 * self.px(toc.fill_inset_dip),
        1,
    );
}

pub fn maxScroll(self: *const ViewerTOCPanel) i32 {
    return @max(self.list_h - self.viewportHeight(), 0);
}

pub fn clampScroll(self: *ViewerTOCPanel) void {
    self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll());
}

/// Scroll the minimum needed to bring a row into view (Mac's un-anchored
/// `proxy.scrollTo`): a long TOC must not jump around while the user reads.
fn revealRow(self: *ViewerTOCPanel, index: usize) void {
    if (index >= self.rows.items.len) return;
    const row = self.rows.items[index];
    const view_h = self.viewportHeight();
    if (row.y < self.scroll) {
        self.scroll = row.y;
    } else if (row.y + row.h > self.scroll + view_h) {
        self.scroll = row.y + row.h - view_h;
    }
    self.clampScroll();
}

// -------------------------------------------------------------------------
// Hit testing
// -------------------------------------------------------------------------

/// The row under a client point, honoring the header (points on it belong to
/// nothing) and the scroll offset.
fn hitRow(self: *const ViewerTOCPanel, x: i32, y: i32) i32 {
    const l = self.layout;
    if (l.which == .hidden) return -1;
    const header_h = self.headerH();
    const list_top = l.card.top + header_h + self.px(toc.fill_inset_dip);
    if (x < l.card.left or x >= l.card.right) return -1;
    if (y < list_top or y >= l.card.bottom - self.px(toc.fill_inset_dip)) return -1;
    const ly = y - list_top + self.scroll;
    for (self.rows.items, 0..) |r, i| {
        if (ly >= r.y and ly < r.y + r.h) return @intCast(i);
    }
    return -1;
}

pub fn onHandle(self: *const ViewerTOCPanel, x: i32, y: i32) bool {
    return self.layout.which == .gutter and self.layout.handle.containsPoint(x, y);
}

// The code in `viewer_toc_paint.zig` (T1784). These aliases ARE this file's surface for
// that code: they keep `self.f(x)` working at every call site.
const viewer_toc_paint = @import("viewer_toc_paint.zig");
pub const ensureCardSurface = viewer_toc_paint.ensureCardSurface;
pub const releaseCardSurface = viewer_toc_paint.releaseCardSurface;
pub const fillRoundRect = viewer_toc_paint.fillRoundRect;
pub const paint = viewer_toc_paint.paint;
pub const paintHandleBar = viewer_toc_paint.paintHandleBar;
pub const setHandleHover = viewer_toc_paint.setHandleHover;
pub const recheckHandleHover = viewer_toc_paint.recheckHandleHover;
pub const paintCard = viewer_toc_paint.paintCard;
pub const paintFilter = viewer_toc_paint.paintFilter;
pub const iconRect = viewer_toc_paint.iconRect;
pub const onClear = viewer_toc_paint.onClear;
pub const onFilter = viewer_toc_paint.onFilter;
pub const paintTreeRow = viewer_toc_paint.paintTreeRow;
pub const isEmphasized = viewer_toc_paint.isEmphasized;
pub const onActivationChanged = viewer_toc_paint.onActivationChanged;
// -------------------------------------------------------------------------
// Window procedure
// -------------------------------------------------------------------------

fn xOf(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF))));
}
fn yOf(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF))));
}

fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const self = fromHwnd(hwnd) orelse
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_ERASEBKGND => return 1,

        // The compact overlay's slide (T543).
        w32.WM_TIMER => {
            if (wparam == SLIDE_TIMER_ID) {
                self.tickSlide();
                return 0;
            }
            if (wparam == SLIDE_END_TIMER_ID) {
                self.compSlideTick();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_PAINT => {
            // T1405: the card is the quiet surface the accent-repaint oracle
            // watches - it repaints only when something invalidated it, and a
            // child never receives the color-change broadcast itself. Counted
            // here and deliberately NOT in `WM_PRINTCLIENT` below, which is
            // the camera (`paint_probe.zig`).
            paint_probe.record(.viewer_toc);
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) != 0) {
                self.paint(hdc, r.right - r.left, r.bottom - r.top);
            }
            return 0;
        },
        // The same card into a caller's DC, so a pixel probe can photograph it
        // synchronously rather than through DWM's asynchronous copy of the
        // composited surface, which tears mid-row (T835/T940).
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) == 0) return 0;
            self.paint(@ptrFromInt(wparam), r.right - r.left, r.bottom - r.top);
            return 0;
        },

        // The card is chrome: interacting with it must not steal keyboard
        // focus from the document (or the address bar).
        // The filter field is the exception (T1336): a click in its well is a
        // request for the caret, which an un-activated window cannot give.
        w32.WM_MOUSEACTIVATE => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0 and w32.ScreenToClient(hwnd, &pt) != 0) {
                if (self.onFilter(pt.x, pt.y) and !self.onClear(pt.x, pt.y)) return w32.MA_ACTIVATE;
            }
            return w32.MA_NOACTIVATE;
        },

        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, self.text_ref);
            _ = w32.SetBkColor(hdc, w32.RGB(self.field_rgb.r, self.field_rgb.g, self.field_rgb.b));
            if (self.edit_brush) |b| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_COMMAND => {
            const code: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const id: u16 = @intCast(wparam & 0xFFFF);
            if (id == filter_edit_id and code == w32.EN_CHANGE) self.filterChanged();
            return 0;
        },

        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0 and w32.ScreenToClient(hwnd, &pt) != 0) {
                if (self.drag != null or self.onHandle(pt.x, pt.y)) {
                    _ = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_SIZEWE));
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_MOUSEMOVE => {
            const x = xOf(lparam);
            const y = yOf(lparam);
            if (self.drag) |d| {
                const dx = @as(f32, @floatFromInt(x - d.start_x)) / self.scale;
                self.pane.setTOCWidthLive(d.start_dip + dx);
                return 0;
            }
            self.setHandleHover(hwnd, self.onHandle(x, y));
            const hot = self.hitRow(x, y);
            const clear_hot = self.onClear(x, y);
            if (hot != self.hover or clear_hot != self.clear_hover) {
                self.hover = hot;
                self.clear_hover = clear_hot;
                _ = w32.InvalidateRect(hwnd, null, 0);
            }
            if (!self.tracking) {
                var tme = w32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (w32.TrackMouseEvent(&tme) != 0) self.tracking = true;
            }
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            self.tracking = false;
            if (self.drag == null) self.setHandleHover(hwnd, false);
            if (self.hover != -1 or self.clear_hover) {
                self.hover = -1;
                self.clear_hover = false;
                _ = w32.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            const delta: i32 = @as(i16, @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF))));
            // Three text lines per notch — the Windows list default.
            const step = @divTrunc(delta * 3 * self.line_h, 120);
            const before = self.scroll;
            self.scroll -= step;
            self.clampScroll();
            if (self.scroll != before) _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const x = xOf(lparam);
            const y = yOf(lparam);
            if (self.onHandle(x, y)) {
                self.drag = .{ .start_dip = self.layout.card_w_dip, .start_x = x };
                _ = w32.SetCapture(hwnd);
                _ = w32.InvalidateRect(hwnd, null, 0);
                return 0;
            }
            if (self.onClear(x, y)) {
                self.clear_pressed = true;
                _ = w32.SetCapture(hwnd);
                _ = w32.InvalidateRect(hwnd, null, 0);
                return 0;
            }
            // The rest of the well (the magnifier, the padding) is the field's
            // too: a click anywhere in it puts the caret in the field.
            if (self.onFilter(x, y)) {
                if (self.filter_edit) |edit| _ = w32.SetFocus(edit);
                return 0;
            }
            // Row activation happens on the up over the same row (standard
            // button affordance); remember the press via hover.
            return 0;
        },

        w32.WM_LBUTTONUP => {
            const x = xOf(lparam);
            const y = yOf(lparam);
            if (self.drag != null) {
                self.drag = null;
                _ = w32.ReleaseCapture();
                self.pane.commitTOCWidth();
                self.recheckHandleHover(hwnd);
                return 0;
            }
            if (self.clear_pressed) {
                self.clear_pressed = false;
                _ = w32.ReleaseCapture();
                _ = w32.InvalidateRect(hwnd, null, 0);
                // Mouse-up over the same button it went down on: the whole
                // list comes back, and the caret goes to the field so the
                // next query can be typed straight away (a search box's
                // clear button, Mac's and Windows' alike).
                if (self.onClear(x, y)) {
                    log.info("viewer tree pane={s} filter-clear", .{self.pane.paneId()});
                    self.clearFilterField();
                    self.pane.setDiffFilter("");
                    if (self.filter_edit) |edit| _ = w32.SetFocus(edit);
                }
                return 0;
            }
            const hit = self.hitRow(x, y);
            if (hit >= 0) {
                const row = self.rows.items[@intCast(hit)];
                switch (row.kind) {
                    // A heading scrolls the document to itself.
                    .heading => self.pane.tocRowClicked(row.id),
                    // A file OPENS: the page shows one patch at a time, so
                    // selecting the row and loading it are the same act.
                    .file => self.pane.diffFileClicked(row.id),
                    // A folder is a disclosure triangle wearing a row.
                    .folder => self.pane.diffFolderClicked(row.id),
                    // A section header is a label.
                    .section => {},
                }
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// The shape `place()` gives the card's window (T2946): a rounded clip of
/// `w` x `h` with corner radius `r` for the compact overlay, no region for
/// the gutter card (which ignores the size, since nothing is clipped).
pub const RgnKey = struct {
    round: bool,
    w: i32 = 0,
    h: i32 = 0,
    r: i32 = 0,

    pub fn same(applied: ?RgnKey, want: RgnKey) bool {
        const a = applied orelse return false;
        return std.meta.eql(a, want);
    }
};

pub fn rgnKey(which: toc.Mode, w: i32, h: i32, r: i32) RgnKey {
    return if (which == .compact) .{ .round = true, .w = w, .h = h, .r = r } else .{ .round = false };
}

/// Whether `place()` may leave the card's window alone (T2946): a compact
/// card that was compact last time too, stays closed, has no slide running
/// on either path, and whose window is already hidden.
pub fn parkedHidden(which: toc.Mode, last: toc.Mode, visible: bool, slide_timer: bool, comp_slide: bool, shown: bool) bool {
    return which == .compact and last == .compact and !visible and !slide_timer and !comp_slide and !shown;
}

test "T2946: only a closed, still, hidden compact card skips its window work" {
    try std.testing.expect(parkedHidden(.compact, .compact, false, false, false, false));
    // Opening it, or a slide (stepped or on the compositor) still running.
    try std.testing.expect(!parkedHidden(.compact, .compact, true, false, false, false));
    try std.testing.expect(!parkedHidden(.compact, .compact, false, true, false, false));
    try std.testing.expect(!parkedHidden(.compact, .compact, false, false, true, false));
    // Its window still on screen (a slide-out that has not hidden it yet).
    try std.testing.expect(!parkedHidden(.compact, .compact, false, false, false, true));
    // A layout switch is placed in full either way.
    try std.testing.expect(!parkedHidden(.compact, .gutter, false, false, false, false));
    try std.testing.expect(!parkedHidden(.compact, .hidden, false, false, false, false));
    try std.testing.expect(!parkedHidden(.gutter, .gutter, false, false, false, false));
}

test "T2946: an unchanged card shape is not re-applied, a changed one is" {
    const k = rgnKey(.compact, 300, 143, 12);
    // Nothing applied yet (or the last apply failed): apply.
    try std.testing.expect(!RgnKey.same(null, k));
    // A sync that moved nothing about the card: skip.
    try std.testing.expect(RgnKey.same(k, rgnKey(.compact, 300, 143, 12)));
    // Any of the size, the radius (a scale change), or the mode: apply.
    try std.testing.expect(!RgnKey.same(k, rgnKey(.compact, 301, 143, 12)));
    try std.testing.expect(!RgnKey.same(k, rgnKey(.compact, 300, 150, 12)));
    try std.testing.expect(!RgnKey.same(k, rgnKey(.compact, 300, 143, 18)));
    try std.testing.expect(!RgnKey.same(k, rgnKey(.gutter, 300, 143, 12)));
    // The gutter card has no region, so its width moving on every drag tick
    // never re-applies the null one.
    try std.testing.expect(RgnKey.same(rgnKey(.gutter, 280, 900, 12), rgnKey(.gutter, 310, 700, 18)));
}

// T467: the panel is a rounded card drawn against its own bounds — the rim and
// its shadow sit on the edges — and `place()` re-derives its width from the
// pane on every bounds sync. It survives today only because
// `SetWindowRgn(.., TRUE)` happens to follow the `MoveWindow`; this asserts the
// property directly, on the class, where it does not depend on that.
test "viewer TOC class: a resize invalidates the whole card" {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    registerClass(hinst);
    if (!class_registered) return error.SkipZigTest;
    try class_redraw.expectResizeInvalidatesWholeClient(CLASS_NAME);
}
