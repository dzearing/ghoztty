//! The feedback composer's web-composer plane (split out of
//! `ViewerFeedbackBar.zig` by T1781): the seam between the band and
//! `ViewerFeedbackWeb` - opening and closing the page, seeding it, mirroring
//! its snapshots, composer chords, and the line and image counts the band's
//! layout is built on.

const ViewerFeedbackBar = @import("ViewerFeedbackBar.zig");

const std = @import("std");
const w32 = @import("win32.zig");
const class_redraw = @import("class_redraw.zig");
const chrome_reposition = @import("chrome_reposition.zig");
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const banner_card = @import("banner_card.zig");
const banner_layout = @import("banner_layout.zig");
const pane_elevation = @import("pane_elevation.zig");
const Dib32 = @import("dib32.zig");
const type_ramp = @import("type_ramp.zig");
const icon_button = @import("icon_button.zig");
const icon_paint = @import("icon_button_paint.zig");
const layout_mod = @import("viewer_feedback_layout.zig");
const doc = @import("viewer_feedback_doc.zig");
const ViewerFeedbackWeb = @import("ViewerFeedbackWeb.zig");
const composer_page = @import("viewer_feedback_page.zig");
const feedback_images = @import("viewer_feedback_images.zig");
const utf16_offset = @import("utf16_offset.zig");
const gdiplus_decode = @import("gdiplus_decode.zig");
const RegionSelector = @import("RegionSelector.zig");
const system_colors = @import("system_colors.zig");
const viewer_accel = @import("viewer_accel.zig");
const Accessible = @import("viewer_feedback_acc.zig");
const a11y = @import("viewer_feedback_a11y.zig");
const ViewerPane = @import("ViewerPane.zig");
const viewer_worktree = @import("viewer_worktree.zig");
const input = @import("../../input.zig");
const build_config = @import("../../build_config.zig");
const paint_plane = @import("viewer_feedback_paint.zig");
const focus_plane = @import("viewer_feedback_focus.zig");
const carousel_plane = @import("viewer_feedback_carousel.zig");

const WM_APP_RELAYOUT = ViewerFeedbackBar.WM_APP_RELAYOUT;
const chip_pad_dip = ViewerFeedbackBar.chip_pad_dip;
const chip_radius_dip = ViewerFeedbackBar.chip_radius_dip;
const log = ViewerFeedbackBar.log;
const makeFont = ViewerFeedbackBar.makeFont;
const placeholder_utf8 = ViewerFeedbackBar.placeholder_utf8;
const quote_bar_dip = ViewerFeedbackBar.quote_bar_dip;
const quote_bar_x_dip = ViewerFeedbackBar.quote_bar_x_dip;
const quote_indent_dip = ViewerFeedbackBar.quote_indent_dip;

// -------------------------------------------------------------------------
// The web composer (T934)
//
// Everything below is the seam between this band and `ViewerFeedbackWeb`. The
// band keeps owning its window, its paint, its hit testing and its geometry;
// the web view owns the text rect's interior and pushes a snapshot up whenever
// it changes.
// -------------------------------------------------------------------------

/// Create the web composer, or say plainly that there is none.
///
/// Called from `setVisible(true)` rather than from `create`, which is D43's
/// mitigation for the memory and startup cost: a pane whose composer nobody
/// opens never pays for a renderer.
///
/// No fallback surface (T1704). Both failures below are a pane whose WebView2
/// is already broken — it has no environment, or the environment that renders
/// its page refused a second controller — so the band is left open with its
/// footer saying why, and the report text stays safe on the pane for the next
/// open. A dead pill with no word of explanation is the one outcome ruled out.
pub fn openComposer(self: *ViewerFeedbackBar) void {
    if (self.web != null) return;

    const surface: []const u8 = surface: {
        const env = self.pane.env orelse break :surface "none(no-environment)";
        const wv = ViewerFeedbackWeb.create(self.alloc, self, self.hwnd, env) orelse
            break :surface "none(controller-refused)";
        self.web = wv;
        // The band has already been placed by the pane's bounds sync, so the
        // text rect is current and the view can be born the right size - a
        // controller adopted at 0x0 lays its document out twice.
        const l = self.currentLayout();
        wv.setScale(self.scale);
        wv.setBounds(.{
            .left = l.text.left,
            .top = l.text.top,
            .right = l.text.left + @max(l.text.width(), 0),
            .bottom = l.text.top + @max(l.text.height(), 0),
        });
        wv.setVisible(true);
        break :surface "web";
    };
    if (self.web == null) {
        log.warn("viewer feedback composer surface={s} pane={s}", .{ surface, self.pane.paneId() });
        self.pane.setFeedbackStatus(self.alloc, "The feedback box could not start");
        _ = w32.InvalidateRect(self.hwnd, null, 1);
        return;
    }
    // The acceptance scripts' oracle that the composer came up on the surface
    // users get, rather than on nothing.
    log.info("viewer feedback composer surface={s} pane={s}", .{ surface, self.pane.paneId() });
}

/// Give the renderer back. The report text is untouched - it lives on the pane,
/// which is what makes destroying the controller on every close affordable.
pub fn closeComposer(self: *ViewerFeedbackBar) void {
    const wv = self.web orelse return;
    self.web = null;
    self.vars_scale = 0;
    self.echoed = false;
    self.page_quotes = 0;
    wv.destroy();
}

/// The page loaded (or reloaded itself). Dress it and fill it - in that order,
/// so the wrapped line count it measures on the way back is measured against
/// the right line box.
pub fn composerReady(self: *ViewerFeedbackBar) void {
    self.pushComposerVars(true);
    self.seedPage(null, false);
    // ...and then give it back its history (T1006). After the seed, because a
    // seed that is not an edit clears the page's journal; the page applies
    // the two in the order they were posted.
    if (self.journal) |j| {
        if (self.web) |wv| wv.restoreJournal(j);
    }
}

/// The page's undo journal changed. Kept verbatim so a page created after the
/// next close can be handed it back (T1006); an empty one is the same as none.
pub fn composerJournal(self: *ViewerFeedbackBar, j: composer_page.Journal) void {
    self.dropJournal();
    if (j.empty) return;
    self.journal = self.alloc.dupe(u8, j.json) catch null;
}

pub fn dropJournal(self: *ViewerFeedbackBar) void {
    if (self.journal) |j| self.alloc.free(j);
    self.journal = null;
}

/// Make the page equal the pane's buffer, with the caret at byte offset
/// `caret` (null means the end) and every live quote rebuilt as a block.
///
/// The one write path down, and the reason it is one: the page cannot be told
/// "insert this here", so every native edit is a whole-document seed — and a
/// seed that forgot the quotes would silently flatten every washed block into
/// plain text, which is precisely the regression T935 exists to end. Building
/// the span list HERE rather than at each call site is what makes that
/// impossible to forget.
///
/// `undoable` is the other thing only this path can say: a seed that carries
/// one insertion is an EDIT, and the page journals what it replaced so Ctrl+Z
/// takes the quote or the chip back out (T983). Every other seed replaces the
/// document with something unrelated and clears that journal.
pub fn seedPage(self: *ViewerFeedbackBar, caret_at: ?usize, undoable: bool) void {
    const wv = self.web orelse return;
    const text = self.pane.feedbackText();
    const units: ?u32 = if (caret_at) |b|
        @intCast(utf16_offset.unitsBeforeByte(text, b))
    else
        null;

    // The live image chips, derived from the buffer exactly as the carousel and
    // the report's `images` array are (T936) — so the nodes the page builds and
    // the pictures the report will carry cannot disagree, and the two rules
    // that derivation enforces (an unknown chip is plain text, an entry is live
    // at most once) hold for the nodes without being restated.
    const images = self.imageSeedSpans(text);
    defer if (images.len > 0) self.alloc.free(images);

    // Byte spans, as the pane knows them — from the page's own last snapshot
    // when there is one, and derived from the registry when the buffer has
    // moved behind the page's back (a reopen, a native insertion, a clear).
    const spans = self.pane.feedbackQuoteSpans(self.alloc) orelse {
        wv.seed(text, units, &.{}, images, undoable);
        return;
    };
    defer self.alloc.free(spans);

    const out = self.alloc.alloc(composer_page.QuoteSpan, spans.len) catch {
        // Seeding without the quotes still gets the user's words onto the
        // page; dropping the seed would lose them.
        wv.seed(text, units, &.{}, images, undoable);
        return;
    };
    defer self.alloc.free(out);
    var n: usize = 0;
    for (spans) |s| {
        const entries = self.pane.feedback_quotes.entries.items;
        if (s.index >= entries.len) continue;
        out[n] = .{
            .id = entries[s.index].id,
            .start = @intCast(utf16_offset.unitsBeforeByte(text, s.start)),
            .end = @intCast(utf16_offset.unitsBeforeByte(text, s.end)),
        };
        n += 1;
    }
    wv.seed(text, units, out[0..n], images, undoable);
}

/// Every live chip in `text`, as the page's UTF-16 spans. Empty rather than
/// null on any failure: a seed without its chips still carries the report's
/// words, which is the half that cannot be recovered.
pub fn imageSeedSpans(self: *ViewerFeedbackBar, text: []const u8) []const composer_page.ImageSpan {
    const spans = self.pane.feedbackImageSpans(self.alloc) orelse return &.{};
    defer self.alloc.free(spans);
    if (spans.len == 0) return &.{};
    const out = self.alloc.alloc(composer_page.ImageSpan, spans.len) catch return &.{};
    for (spans, 0..) |s, i| {
        out[i] = .{
            .n = self.pane.feedbackImageEntry(s).number,
            .start = @intCast(utf16_offset.unitsBeforeByte(text, s.start)),
            .end = @intCast(utf16_offset.unitsBeforeByte(text, s.end)),
        };
    }
    return out;
}

/// One snapshot from the page: the document as it now stands.
///
/// It does three things - mirror into the pane's buffer (the thing that outlives
/// this window), re-inset the page if the band's height moved, and keep the
/// carousel's selection with the caret.
pub fn composerState(
    self: *ViewerFeedbackBar,
    text: []const u8,
    quotes: []const composer_page.QuoteSpan,
) void {
    self.suppress_sync = true;
    defer self.suppress_sync = false;
    self.pane.feedbackSetText(self.alloc, text);
    // ...then where its quote BLOCKS are, converted against the buffer that
    // was just written. Order is load-bearing twice over: the offsets only
    // mean anything against this text, and `feedbackSetText` drops the
    // previous snapshot's spans on the way through, so a page that reports no
    // quotes leaves the pane with none rather than with yesterday's.
    self.publishQuoteSpans(text, quotes);
    self.page_quotes = quotes.len;
    const grew = self.syncMetrics();
    // The acceptance oracle for a surface nothing outside the process can look
    // at (T233: no screenshots, no SendInput on the test desktop). Bounded on
    // purpose - the FIRST echo after an open, then only when the pill's VISIBLE
    // line count moves - because a line per keystroke would be a log nobody can
    // read in a terminal somebody is working in.
    if (!self.echoed or grew) {
        self.echoed = true;
        log.info("viewer composer echo pane={s} bytes={d} lines={d}", .{
            self.pane.paneId(),
            self.pane.feedbackText().len,
            self.lineCount(),
        });
    }
    if (grew) self.textChanged() else _ = w32.InvalidateRect(self.hwnd, null, 1);
    self.syncCarouselToCaret();
}

/// Turn one snapshot's quote blocks into the spans the report is written from.
///
/// UTF-16 code units in, bytes out (the T648 boundary, unchanged), and ids in,
/// registry indices out — a block whose id this composer session never issued
/// is dropped rather than matched to a neighbour, because the metadata it would
/// carry would be some other passage's.
pub fn publishQuoteSpans(
    self: *ViewerFeedbackBar,
    text: []const u8,
    quotes: []const composer_page.QuoteSpan,
) void {
    if (quotes.len == 0) {
        self.pane.feedbackSetQuoteSpans(self.alloc, &.{});
        return;
    }
    const out = self.alloc.alloc(doc.Span, quotes.len) catch return;
    defer self.alloc.free(out);
    var n: usize = 0;
    for (quotes) |q| {
        const index = self.pane.feedback_quotes.indexOfId(q.id) orelse continue;
        out[n] = .{
            .start = utf16_offset.byteForUnits(text, q.start),
            .end = utf16_offset.byteForUnits(text, q.end),
            .index = index,
        };
        n += 1;
    }
    self.pane.feedbackSetQuoteSpans(self.alloc, out[0..n]);
}

/// The pane's buffer changed from the NATIVE side; make the page equal it.
///
/// Called from `feedbackSetText` itself, so it covers every writer rather than
/// the ones anybody remembered — including a test and the post-send clear. Skip
/// it for a write that came from the page, which would otherwise be an echo
/// that fights the user's typing.
pub fn composerSync(self: *ViewerFeedbackBar) void {
    if (self.suppress_sync) return;
    // Whatever the history described is not the document any more — and with
    // the composer closed there is no page to clear its own copy, so this is
    // the only place the stale one can go (T1006).
    self.dropJournal();
    if (self.web == null) return;
    self.seedPage(null, false);
}

/// Push the design-system numbers into the page's CSS custom properties.
///
/// `force` is for the two moments the numbers themselves moved (a theme change,
/// a fresh page); otherwise this is a no-op unless the scale or the pill colour
/// has changed since the last push. The dedupe is load-bearing rather than an
/// optimisation: every push makes the page re-measure and re-report, and a
/// report arriving from inside a bounds sync is a bounds sync that runs again.
pub fn pushComposerVars(self: *ViewerFeedbackBar, force: bool) void {
    const wv = self.web orelse return;
    if (!force and self.vars_scale == self.scale and
        std.meta.eql(self.vars_pill, self.pill_rgb)) return;
    const scale = if (self.scale > 0) self.scale else 1.0;

    // Physical metrics divided by the rasterization scale, so one CSS pixel is
    // exactly one of the physical pixels the layout module reserved. Dividing
    // here rather than passing DIP constants is what keeps the two in step at
    // 1.25, where `@round` moves the font and the leading independently.
    const body = type_ramp.body(scale);
    const line_h = type_ramp.lineBox(body, scale);

    var fg_buf: [8]u8 = undefined;
    var bg_buf: [8]u8 = undefined;
    var ph_buf: [8]u8 = undefined;
    var sel_buf: [8]u8 = undefined;
    var qbg_buf: [8]u8 = undefined;
    var qac_buf: [8]u8 = undefined;
    var iink_buf: [8]u8 = undefined;
    var iedge_buf: [8]u8 = undefined;

    self.vars_scale = self.scale;
    self.vars_pill = self.pill_rgb;
    wv.pushVars(.{
        .face = type_ramp.face,
        .font_px = @as(f32, @floatFromInt(body.height)) / scale,
        .line_px = @as(f32, @floatFromInt(line_h)) / scale,
        .fg = hexRef(&fg_buf, self.text_ref),
        .bg = hexRgb(&bg_buf, self.pill_rgb),
        .placeholder = hexRef(&ph_buf, self.secondary_ref),
        .selection = hexRef(&sel_buf, self.accent_ref),
        .placeholder_text = placeholder_utf8,
        // A quoted block's wash and bar (T935) - the pill pulled 14% toward
        // the accent, and the accent itself, both derived in `applyTheme`. Its metrics go over in CSS pixels, which are
        // DIPs here because the controller rasterizes at the pane's scale.
        .quote_bg = hexRgb(&qbg_buf, self.quote_rgb),
        .quote_accent = hexRef(&qac_buf, self.accent_ref),
        .quote_indent_px = quote_indent_dip,
        .quote_bar_px = quote_bar_dip,
        .quote_bar_x_px = quote_bar_x_dip,
        // The chip's own shape, and the cap the page refuses a picture at —
        // the store's own number, so a drop the store would reject is rejected
        // before 40 MB of base64 crosses the channel to be rejected here
        // (T936).
        .image_pad_px = chip_pad_dip,
        .image_radius_px = chip_radius_dip,
        .image_ink = hexRgb(&iink_buf, self.chip_ink_rgb),
        .image_edge = hexRgb(&iedge_buf, self.chip_edge_rgb),
        .image_max_bytes = feedback_images.max_image_bytes,
    });
}

/// `#rrggbb` for a `COLORREF`, which is 0x00BBGGRR - the byte order that makes
/// a hand-written formatter here safer than a `{x}` of the whole word.
pub fn hexRef(buf: *[8]u8, ref: u32) []const u8 {
    return hexRgb(buf, .{
        .r = @intCast(ref & 0xFF),
        .g = @intCast((ref >> 8) & 0xFF),
        .b = @intCast((ref >> 16) & 0xFF),
    });
}

pub fn hexRgb(buf: *[8]u8, rgb: color_math.Rgb) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b }) catch "#000000";
}

/// The modifier state right now. Shared with `ViewerFeedbackWeb`'s accelerator
/// handler, which runs while the browser process is blocked on its answer and
/// so cannot be handed a stale copy.
pub fn keyMods() input.Mods {
    return .{
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
        .super = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0,
    };
}

/// Whether a chord belongs to the composer or the pane rather than to the page.
///
/// Keys typed into the page reach a Chromium window, not our message loop, so
/// the claim has to be made inside `AcceleratorKeyPressed` - and made
/// there rather than in the page's own `keydown`, because only `put_Handled`
/// stops the browser ALSO acting on it (an unclaimed Ctrl+R would reload the
/// composer's page out from under a half-written report).
pub fn claimsComposerKey(self: *const ViewerFeedbackBar, vk: u16, mods: input.Mods) bool {
    _ = self;
    return viewer_accel.composerChord(vk, mods) != null;
}

/// Run a chord the accelerator handler claimed. Posted to this window rather
/// than run inside the runtime's `Invoke`, because closing the composer tears
/// the controller down and it must not happen under its own callback frame.
pub fn runComposerChord(self: *ViewerFeedbackBar, vk: u16, mods: input.Mods) void {
    const chord = viewer_accel.composerChord(vk, mods) orelse return;
    self.runChord(chord);
}

/// One place both keyboard surfaces end up: the band's own `WM_KEYDOWN` (via
/// `handleKey`) and the web composer's accelerator hop (via
/// `runComposerChord`). A chord added to the table therefore reaches BOTH
/// without a second switch to keep in step.
pub fn runChord(self: *ViewerFeedbackBar, chord: viewer_accel.ComposerChord) void {
    switch (chord) {
        .send => self.pane.sendFeedback(self.alloc),
        .close => self.pane.setFeedbackOpen(false),
        .snapshot => self.beginSnapshot(),
        .focus_next => self.walkFocus(false),
        .focus_prev => self.walkFocus(true),
    }
}

/// How many lines the composer currently shows: the page's own WRAPPED line
/// count, clamped by the layout's cap. Cached in `self.lines` by `syncLines`,
/// because `place` sizes the view from this and must not wait on the view it
/// is about to move.
pub fn lineCount(self: *const ViewerFeedbackBar) u32 {
    return layout_mod.visibleLines(self.lines);
}

/// Re-read the page's wrapped line count from its last snapshot. Returns true
/// when it changed, i.e. when the pill has to grow or shrink and the pane has
/// to re-inset the page. No page means one line — an empty pill.
pub fn syncLines(self: *ViewerFeedbackBar) bool {
    const lines: u32 = if (self.web) |wv| @max(wv.lines, 1) else 1;
    if (layout_mod.visibleLines(lines) == layout_mod.visibleLines(self.lines)) {
        self.lines = lines;
        return false;
    }
    self.lines = lines;
    return true;
}

/// Re-count the live image chips. Returns true when the count changed, i.e.
/// when the carousel row appeared, disappeared, or grew — all of which move the
/// page, so the pane has to re-inset.
pub fn syncImages(self: *ViewerFeedbackBar) bool {
    const n: u32 = @intCast(@min(
        self.pane.feedbackImageCount(self.alloc),
        std.math.maxInt(u32),
    ));
    if (n == self.images) return false;
    self.images = n;
    // A strip that just lost tiles can be scrolled past its own end.
    self.carousel_scroll = self.currentLayout().clampScroll(self.carousel_scroll);
    if (self.carousel_selected) |i| {
        if (i >= n) self.carousel_selected = null;
    }
    // The keyboard ring cannot outlive the tiles it was on: deleting the last
    // picture while the strip held focus hands focus back to the text, and
    // deleting one from under the ring pulls it onto the last survivor.
    if (n == 0) {
        if (self.key_focus == .carousel) self.focusStop(.text) else self.carousel_focus = null;
    } else if (self.carousel_focus) |i| {
        if (i >= n) self.carousel_focus = n - 1;
    }
    self.logCarousel("tiles");
    // The band's children just changed: a reader re-reads them.
    Accessible.notify(Accessible.EVENT_OBJECT_REORDER, self.hwnd, 0);
    return true;
}

/// Both cached metrics at once. Kept as one call because every text change can
/// move either — a pasted chip adds a tile AND can wrap a line — and asking for
/// one while forgetting the other is exactly the bug that leaves the page inset
/// by a stale band height.
pub fn syncMetrics(self: *ViewerFeedbackBar) bool {
    const grew_lines = self.syncLines();
    const grew_images = self.syncImages();
    return grew_lines or grew_images;
}

pub fn layoutInput(self: *const ViewerFeedbackBar, width: i32, scale: f32) layout_mod.Input {
    return .{
        .scale = scale,
        .width = width,
        .lines = self.lineCount(),
        .line_h = type_ramp.lineBox(type_ramp.body(scale), scale),
        .footer_h = type_ramp.lineBox(type_ramp.caption(scale), scale),
        .images = self.images,
    };
}

/// The band height this composer needs at `width`/`scale`. The pane asks for
/// it BEFORE placing anything (it has to inset the page by nav + composer in
/// one pass), which is why it is derivable without a DC: every input is the
/// type ramp and the DPI scale, never a measured string.
pub fn barHeight(self: *const ViewerFeedbackBar, width: i32, scale: f32) i32 {
    return layout_mod.Layout.init(self.layoutInput(width, scale)).bar_h;
}

/// Position the composer across the pane, directly under the nav bar.
/// Idempotent and cheap; the pane calls it from every bounds sync while the
/// composer is open.
pub fn place(self: *ViewerFeedbackBar, top: i32, width: i32, scale: f32) void {
    const l = layout_mod.Layout.init(self.layoutInput(width, scale));
    // Resize-aware, in-frame reposition (T1392) — see `chrome_reposition`.
    _ = chrome_reposition.place(self.hwnd, 0, top, width, l.bar_h, 0);
    // On glass a band that only MOVED (the nav bar grew a row) covers a
    // different slice of the desk, and a move can carry the old pixels along.
    if (top != self.top) {
        self.top = top;
        if (self.pane.glass != null) _ = w32.InvalidateRect(self.hwnd, null, 0);
    }
    if (self.scale != scale) {
        self.scale = scale;
        if (self.caption_font) |f| _ = w32.DeleteObject(@ptrCast(f));
        self.caption_font = makeFont(type_ramp.caption(scale));
    }
    // The web surface fills the text rect exactly, which is what makes the
    // pill's 12 DIP lead and the gap to the buttons the view's OWN margins — no
    // second inset to keep in step with the layout module. The controller is
    // parented to this band, so `Layout`'s own client-space numbers are
    // already what `put_Bounds` wants.
    if (self.web) |wv| {
        wv.setScale(scale);
        wv.setBounds(.{
            .left = l.text.left,
            .top = l.text.top,
            .right = l.text.left + @max(l.text.width(), 0),
            .bottom = l.text.top + @max(l.text.height(), 0),
        });
        // Only when the scale actually moved — see `pushComposerVars`.
        self.pushComposerVars(false);
    }

    // A narrower pane re-wraps the text, so the line count this layout was
    // built from can be wrong the moment the control is moved — which is how
    // a composer ends up two lines tall around three lines of text after a
    // split divider is dragged. Corrected on the next message rather than
    // in-place: `place` is called FROM the pane's bounds sync, and calling
    // back into it here would re-enter it. The correction converges after one
    // pass, because the text rect's WIDTH does not depend on the line count.
    if (self.syncLines()) _ = w32.PostMessageW(self.hwnd, WM_APP_RELAYOUT, 0, 0);

    // Re-synced HERE rather than only at creation: a tool is a RECTANGLE in
    // this window's client space, so every reposition, DPI change and re-wrap
    // moves the two buttons out from under their tips.
    self.syncTip(l);

    // A narrower band is the OTHER way a strip starts overflowing (T668) — the
    // pictures did not change, the room for them did. The scroll is re-clamped
    // to the new viewport and the strip re-states itself, so "is there more
    // this way" is answerable after a resize and not only after a paste.
    if (self.images > 0) {
        const clamped = l.clampScroll(self.carousel_scroll);
        const moved = clamped != self.carousel_scroll;
        self.carousel_scroll = clamped;
        if (moved or l.carousel.width() != self.carousel_view) {
            self.carousel_view = l.carousel.width();
            self.logCarousel("resize");
        }
    }
}

/// Push the pane's buffer into the page — what opening the composer does, so
/// contents survive a close/reopen. The page takes the buffer whole, caret at
/// the end, in one message: it owns the document, so there is no line-ending
/// conversion and no formatting to re-derive on this side. Before the page
/// exists (the pane seeds BEFORE it shows the band) this only re-counts, and
/// the page seeds itself from the buffer once it loads (`composerReady`).
pub fn seedControl(self: *ViewerFeedbackBar) void {
    self.seedPage(null, false);
    // Seeding can change the band's height — most visibly after a report is
    // filed, where the text and every chip in it went at once. Posted rather
    // than called: the pane's own `setFeedbackOpen` calls this from inside its
    // bounds sync, and re-entering that sync from here would nest it.
    if (self.syncMetrics()) _ = w32.PostMessageW(self.hwnd, WM_APP_RELAYOUT, 0, 0);
}
