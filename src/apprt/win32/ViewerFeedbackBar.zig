//! The viewer pane's feedback composer (T634, the win32 half of Mac's
//! `ViewerFeedbackBar`): an owner-painted native child window that slides in
//! below the nav bar and above the page, carrying a pill that grows with its
//! content and two circular actions inside the pill's trailing edge.
//!
//! Native, not web content, for the same pinned reason the nav bar is: chrome
//! rendered inside WebView2 would have to be injected into arbitrary
//! third-party pages, would fight their CSS and z-index, and would put the
//! composer inside the very content it is reporting on.
//!
//! ## Who does what
//!
//! The BAR owns its window, its painting and its hit testing. The PANE owns
//! everything that has to survive the bar — whether the composer is open, and
//! the text itself. That split is not a preference: Mac is explicit that
//! composer contents survive toggling the toolbar closed and open again, and
//! the natural win32 mistake is to keep the buffer in the child window, where
//! it dies with the window. So the buffer lives in `ViewerPane` and this file
//! only renders and edits it (`pane.feedbackText`, `feedbackInsert`,
//! `feedbackBackspace`).
//!
//! ## Which text control this IS
//!
//! A **WebView2 contenteditable** (`ViewerFeedbackWeb.zig` +
//! `viewer_feedback_page.zig`): a second `ICoreWebView2Controller` filling the
//! pill's text rect, created on the first open and destroyed on close. That is
//! D43's answer, taken against its own recommendation, and T934 is where the
//! composer stopped contradicting it. What the engine brings — caret,
//! selection, wrap, undo, clipboard, IME, a screen reader that can read the
//! field — is the whole reason; see that file's header.
//!
//! It is the ONLY text surface. The hidden RichEdit that T635 hosted here and
//! T934 kept as a fallback is gone (T1704): a viewer pane cannot exist without
//! WebView2 in the first place, so a composer whose controller fails degrades
//! to where a failed pane already is — the band opens, says so in its footer,
//! and takes no text — rather than to a second editing engine kept alive
//! forever for a case nobody reaches (T830's design). Which surface came up is
//! stated in the pane's own stderr on every open, so the answer is never a
//! guess:
//!
//!     viewer feedback composer surface=web|none(<why>) ...
//!
//! The PANE still owns the text: every snapshot the page pushes is mirrored
//! into `pane.feedbackText()`, which is what outlives this window, and every
//! open re-seeds the page from it.
//!
//! Geometry lives in `viewer_feedback_layout.zig`, where it asserts at
//! 1.0/1.25/1.5/2.0 without a window.
const ViewerFeedbackBar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
// Test-only (T467): the class-level resize/redraw probe. Imported at file
// scope so its own positive and negative controls are queued into the win32
// test lane along with the class test below.
const class_redraw = @import("class_redraw.zig");
const chrome_reposition = @import("chrome_reposition.zig");
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const banner_card = @import("banner_card.zig");
const banner_layout = @import("banner_layout.zig");
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
const ViewerPane = @import("ViewerPane.zig");
const viewer_worktree = @import("viewer_worktree.zig");
const input = @import("../../input.zig");
const build_config = @import("../../build_config.zig");

const log = std.log.scoped(.viewer_feedback);

const class_name_utf8 = "GhozttyViewerFeedback";
pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral(class_name_utf8);

/// "The wrapped line count moved while I was being laid out; ask the pane to
/// lay me out again." Posted, never sent — see `place`.
const WM_APP_RELAYOUT: u32 = w32.WM_APP + 1;

/// The placeholder an empty composer shows, Mac's accessibility label turned
/// into the cue an empty field needs. The page draws it (a CSS `::before` on
/// the empty box); this is where its words live.
const placeholder_utf8 = "What's wrong with what you're looking at?";

/// The key hints in the footer's trailing slot. Spelled in the Windows
/// chords, which is the whole reason it is not Mac's string.
const hints = "Ctrl+Enter send  ·  Esc close";

/// UTF-16 units one action's tooltip may hold. The labels are fixed strings
/// (`viewer_feedback_layout.label`) and the longest is under 50, so this is
/// headroom rather than a limit anything is near.
const tip_text_cap: usize = 128;

/// Bytes the tooltip log line may hold: two buttons, each a name, two rects
/// and its label.
const tip_log_cap: usize = 320;

hwnd: w32.HWND,
/// The web composer, while the composer is open. Null when it is closed (D43's
/// mitigation: the controller is created lazily and given back on close, with
/// the report text kept on the pane) and null when the environment could not
/// produce one — see "Which text control this IS" for what the band does then.
web: ?*ViewerFeedbackWeb = null,
/// How many quote blocks the PAGE's last snapshot reported. The one number that
/// can only come from the DOM: native maintains the pane's spans itself across
/// its own edits (`spliceComposer`), so a span list proves nothing about the
/// page, and this is what the pane's unit test waits on to prove the block was
/// built as a node and reported back (T935).
page_quotes: usize = 0,
/// True while a write to the pane's buffer CAME from the page, so the pane's
/// own "tell the composer" hook does not send it straight back.
suppress_sync: bool = false,
/// Whether the page has echoed anything back since this composer opened. The
/// FIRST echo is the only proof from outside the process that the whole round
/// trip works, so it is logged; see `composerState`.
echoed: bool = false,
/// The scale and pill colour the page's CSS custom properties were last built
/// from. Pushing them is cheap but not free — the page re-measures its wrapped
/// line count on every push — so it happens when they MOVE, not on every
/// bounds sync.
vars_scale: f32 = 0,
vars_pill: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
pane: *ViewerPane,
alloc: Allocator,

hover: ?layout_mod.Button = null,
pressed: ?layout_mod.Button = null,
tracking: bool = false,
focused: bool = false,

/// Where the footer's staging-folder link was last painted, and whether the
/// pointer is on it (T645). Recorded by the paint rather than derived by the
/// layout, because the link's width is the width of a string the layout knows
/// nothing about — the draft's stem — and a hit box that disagreed with the
/// underline would be a link you cannot click where it looks clickable.
link_rect: layout_mod.Rect = .{},
link_hover: bool = false,
link_pressed: bool = false,

/// Which of the composer's three stops holds keyboard focus (T640). `.text`
/// means the text surface has it — the web composer — and is
/// the only value for which this window hands focus straight on; the other two
/// mean the BAND itself holds the Win32 focus and is drawing a ring on that
/// button.
key_focus: layout_mod.Stop = .text,

/// The stop that had focus when a screenshot capture started. The selector is
/// a full-desktop window and TAKES the keyboard, so the band's `WM_KILLFOCUS`
/// has already reset `key_focus` by the time the capture finishes — this is
/// what the ring is restored from.
capture_focus: layout_mod.Stop = .text,

/// The two actions' tooltips, and the one control that shows them both. Same
/// arrangement as `ViewerNavBar`: ONE tool per button, added once and then
/// only moved, with the text living in a buffer comctl32 reads on demand.
tip: ?w32.HWND = null,
tip_text: [layout_mod.button_count][tip_text_cap:0]u16 = undefined,
tip_added: [layout_mod.button_count]bool = [_]bool{false} ** layout_mod.button_count,

/// The last tooltip line handed to the log, so a bounds sync that changes
/// nothing says nothing.
tip_log: [tip_log_cap]u8 = undefined,
tip_log_len: usize = 0,

/// Wrapped lines the control is currently showing, clamped by the layout's own
/// cap. Cached rather than queried per layout pass: `place` is called from
/// every bounds sync, and asking the control there would mean sizing the
/// control from a number the control itself produces.
lines: u32 = 1,

/// Live image chips, i.e. how many tiles the carousel shows (T646). Cached for
/// the same reason `lines` is: `barHeight` is asked on every bounds sync and
/// deriving this means scanning the composer's text.
images: u32 = 0,
/// How far the thumbnail strip is scrolled, in physical pixels.
carousel_scroll: i32 = 0,
/// The viewport width the strip was last REPORTED at, so a resize that changes
/// whether the ribbon overflows re-states it once rather than on every bounds
/// sync (T668).
carousel_view: i32 = 0,
/// The tile whose chip the caret is sitting in, drawn with a selection ring —
/// the visible half of "clicking a chip scrolls to its thumbnail".
carousel_selected: ?usize = null,
/// The tile the mouse went down on, so a click acts on mouse-UP over the same
/// one, the way the two circular actions already do.
pressed_thumb: ?usize = null,
/// The tile the KEYBOARD is on while `key_focus` is `.carousel` (T668), drawn
/// with the same accent focus ring the two actions get. Separate from
/// `carousel_selected`, which follows the caret: walking the strip with the
/// arrow keys moves a ring around WITHOUT touching the report's text, and only
/// Enter or Space commits the walk by selecting that picture's chip.
carousel_focus: ?usize = null,
/// Decoded thumbnails, keyed by image number AND tile size. The size is part
/// of the key rather than something a DPI change has to remember to clear: a
/// new scale simply misses and decodes, and the stale entries age out with the
/// composer.
thumbs: std.ArrayListUnmanaged(Thumb) = .empty,

/// The screenshot region selector while one is up (T647). Non-null means a
/// capture is in flight, which is what makes `+` and Ctrl+Shift+S idempotent
/// rather than a way to stack full-desktop overlays.
selector: ?*RegionSelector = null,

/// The scale the fonts were last built for; rebuilt when the pane's monitor
/// changes.
scale: f32 = 0,
caption_font: ?*anyopaque = null, // HFONT

// Theme, derived from the pane's background in `applyTheme` — the same
// derivation the nav bar runs, so the two bands are one surface.
bar_rgb: color_math.Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 },
pill_rgb: color_math.Rgb = .{ .r = 0x1A, .g = 0x1A, .b = 0x1A },
border_ref: u32 = 0x00404040,
text_ref: u32 = 0x00FFFFFF,
secondary_ref: u32 = 0x00AAAAAA,
/// The wash behind a quoted block, and the bar down its left edge (T641).
quote_rgb: color_math.Rgb = .{ .r = 0x24, .g = 0x24, .b = 0x28 },
accent_ref: u32 = 0x00D47800,
dark: bool = true,

/// One decoded carousel tile. `dib` is null for a picture GDI+ could not read —
/// cached as a FAILURE on purpose, so an unreadable attachment costs one decode
/// rather than one per repaint.
const Thumb = struct {
    number: u32,
    box: i32,
    dib: ?w32.HANDLE,
    w: i32 = 0,
    h: i32 = 0,
};

var class_registered: bool = false;

fn registerClass(hinstance: ?w32.HINSTANCE) void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // CS_HREDRAW | CS_VREDRAW (T467): `paint` fills the client and then
        // lays the pill, the carousel and the send row out from
        // `Layout.init(layoutInput(width, scale))`, so the bar's content is a
        // function of its own bounds. The pane resizes it through
        // `chrome_reposition.place` on every bounds sync (T1392) - that paints
        // whatever is invalid, in the same frame, and without this style the
        // only invalid part is the strip the widen uncovered.
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
        log.warn("viewer feedback class registration failed", .{});
        return;
    }
    class_registered = true;
}

/// Create the composer as a HIDDEN child of the pane's host window. Null when
/// the window cannot be created — the pane then simply has no composer, which
/// degrades to the pre-T634 world (a feedback button that logs its intent)
/// rather than to a crash.
pub fn create(
    alloc: Allocator,
    pane: *ViewerPane,
    hinstance: ?w32.HINSTANCE,
    parent: w32.HWND,
) ?*ViewerFeedbackBar {
    readTestSeams(alloc);
    registerClass(hinstance);
    if (!class_registered) return null;

    const self = alloc.create(ViewerFeedbackBar) catch return null;
    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD, // not visible until the button opens it
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
    // `tip_text` is `undefined` in the initializer above (it is a pair of
    // 128-unit buffers, not a value worth zeroing wholesale); what has to be
    // true before anything reads one is that it terminates.
    for (&self.tip_text) |*t| t[0] = 0;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.applyTheme();
    return self;
}

pub fn destroy(self: *ViewerFeedbackBar) void {
    // The web composer's controller is parented to this window, so it goes
    // FIRST: a renderer whose parent HWND has been destroyed under it is the
    // one teardown order WebView2 does not forgive.
    self.closeComposer();
    // A capture still up has nowhere to deliver to once this is gone, and its
    // overlay covers the whole desktop — so it comes down first, silently.
    if (self.selector) |s| {
        self.selector = null;
        s.cancel();
    }
    // The tooltip is a POPUP owned by the band, not a child of it, so it does
    // NOT go down with the band — and it subclassed the band to get its hover,
    // so it has to go first. Same ordering trap the nav bar's tip documents.
    if (self.tip) |t| {
        _ = w32.DestroyWindow(t);
        self.tip = null;
    }
    // Clear the back-pointer FIRST: DestroyWindow delivers messages
    // synchronously, and they must not find a half-dead object.
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    if (self.caption_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    self.dropThumbs();
    self.alloc.destroy(self);
}

/// The pane's image store was emptied (a report was filed), so the carousel's
/// cache is not just stale but WRONG: it is keyed by chip number and the store
/// restarts that sequence at 1.
/// The count itself is deliberately NOT reset here: `seedControl` runs next and
/// re-derives it from the (now empty) text, and it is that discovery which
/// reports the change and re-insets the page. Zeroing it here would make the
/// discovery a no-op and leave the band still tall enough for a strip that has
/// gone.
pub fn imagesCleared(self: *ViewerFeedbackBar) void {
    self.dropThumbs();
    self.carousel_scroll = 0;
    self.carousel_selected = null;
}

/// Free every cached tile bitmap. GDI objects are a process-wide budget, and a
/// composer that was pasted into a dozen times holds a dozen DIBs.
fn dropThumbs(self: *ViewerFeedbackBar) void {
    for (self.thumbs.items) |t| {
        if (t.dib) |d| _ = w32.DeleteObject(d);
    }
    self.thumbs.deinit(self.alloc);
    self.thumbs = .empty;
}

fn fromHwnd(hwnd: w32.HWND) ?*ViewerFeedbackBar {
    const v = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

// -------------------------------------------------------------------------
// Theme & layout
// -------------------------------------------------------------------------

/// Re-derive every color from the pane's background — the same one-source
/// rule the nav bar and the banner card follow, so the composer's band and
/// the bar above it are one surface rather than two nearly-equal greys.
pub fn applyTheme(self: *ViewerFeedbackBar) void {
    const bg = self.pane.bg;
    self.dark = !color_math.isLight(bg);
    self.bar_rgb = banner_card.fillColor(bg);
    const text = chrome_theme.textOn(self.bar_rgb);
    const secondary = chrome_theme.textSecondaryOn(self.bar_rgb);
    self.text_ref = w32.RGB(text.r, text.g, text.b);
    self.secondary_ref = w32.RGB(secondary.r, secondary.g, secondary.b);
    // The pill sits a step off the band — darker in dark mode, lighter in
    // light — so it reads as a well, exactly as the address field does.
    const d: i32 = if (self.dark) -14 else 14;
    self.pill_rgb = .{
        .r = icon_button.shadeChannel(self.bar_rgb.r, d),
        .g = icon_button.shadeChannel(self.bar_rgb.g, d),
        .b = icon_button.shadeChannel(self.bar_rgb.b, d),
    };
    // A 1 px boundary that carries meaning needs 3:1 (design system §2.3), so
    // the border is shaded AWAY from the pill rather than a hairline of the
    // band's own color.
    const bd: i32 = if (self.dark) 40 else -40;
    self.border_ref = w32.RGB(
        icon_button.shadeChannel(self.pill_rgb.r, bd),
        icon_button.shadeChannel(self.pill_rgb.g, bd),
        icon_button.shadeChannel(self.pill_rgb.b, bd),
    );

    // A quoted block reads as a block through THREE things at once, because no
    // one of them survives on its own: a wash behind its text, an accent bar
    // down its left, and a paragraph indent. The wash is a faint pull of the
    // pill toward the accent rather than a saturated panel — it sits under
    // body text that still has to clear 4.5:1, and `text_ref` is derived from
    // the band, not re-derived per run.
    const accent = chrome_theme.accentOn(self.pill_rgb, system_colors.accentCached());
    self.accent_ref = w32.RGB(accent.r, accent.g, accent.b);
    self.quote_rgb = color_math.mix(self.pill_rgb, accent, 0.14);

    // The page paints the pill's interior, so the same derivations are handed
    // over as CSS custom properties - one source for the band's chrome and the
    // text inside it, which is D43's mitigation in one call.
    self.pushComposerVars(true);

    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

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
fn openComposer(self: *ViewerFeedbackBar) void {
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
fn closeComposer(self: *ViewerFeedbackBar) void {
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
fn seedPage(self: *ViewerFeedbackBar, caret_at: ?usize, undoable: bool) void {
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
fn imageSeedSpans(self: *ViewerFeedbackBar, text: []const u8) []const composer_page.ImageSpan {
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
fn publishQuoteSpans(
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
fn pushComposerVars(self: *ViewerFeedbackBar, force: bool) void {
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
        .image_max_bytes = feedback_images.max_image_bytes,
    });
}

/// `#rrggbb` for a `COLORREF`, which is 0x00BBGGRR - the byte order that makes
/// a hand-written formatter here safer than a `{x}` of the whole word.
fn hexRef(buf: *[8]u8, ref: u32) []const u8 {
    return hexRgb(buf, .{
        .r = @intCast(ref & 0xFF),
        .g = @intCast((ref >> 8) & 0xFF),
        .b = @intCast((ref >> 16) & 0xFF),
    });
}

fn hexRgb(buf: *[8]u8, rgb: color_math.Rgb) []const u8 {
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
fn runComposerChord(self: *ViewerFeedbackBar, vk: u16, mods: input.Mods) void {
    const chord = viewer_accel.composerChord(vk, mods) orelse return;
    self.runChord(chord);
}

/// One place both keyboard surfaces end up: the band's own `WM_KEYDOWN` (via
/// `handleKey`) and the web composer's accelerator hop (via
/// `runComposerChord`). A chord added to the table therefore reaches BOTH
/// without a second switch to keep in step.
fn runChord(self: *ViewerFeedbackBar, chord: viewer_accel.ComposerChord) void {
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
fn lineCount(self: *const ViewerFeedbackBar) u32 {
    return layout_mod.visibleLines(self.lines);
}

/// Re-read the page's wrapped line count from its last snapshot. Returns true
/// when it changed, i.e. when the pill has to grow or shrink and the pane has
/// to re-inset the page. No page means one line — an empty pill.
fn syncLines(self: *ViewerFeedbackBar) bool {
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
fn syncImages(self: *ViewerFeedbackBar) bool {
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
    return true;
}

/// Both cached metrics at once. Kept as one call because every text change can
/// move either — a pasted chip adds a tile AND can wrap a line — and asking for
/// one while forgetting the other is exactly the bug that leaves the page inset
/// by a stale band height.
fn syncMetrics(self: *ViewerFeedbackBar) bool {
    const grew_lines = self.syncLines();
    const grew_images = self.syncImages();
    return grew_lines or grew_images;
}

fn layoutInput(self: *const ViewerFeedbackBar, width: i32, scale: f32) layout_mod.Input {
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

// -------------------------------------------------------------------------
// Quotes (T641)
// -------------------------------------------------------------------------

/// A quoted block's three metrics, in DIPs — the design system's 16 DIP step
/// for the text, a 3 DIP accent bar, 5 DIP in from the pill's left edge. The
/// page is dressed with them as CSS custom properties (T935); they are stated
/// here because the rule is that the design system lives in this file, not in
/// a stylesheet.
const quote_indent_dip: f32 = 16;
const quote_bar_dip: f32 = 3;
const quote_bar_x_dip: f32 = 5;

/// An image chip's two, in DIPs (T936): the design system's 4 DIP step for the
/// wash either side of the chip's text, and the same 4 for its corner — the
/// radius the rest of the win32 chrome uses for a small pill.
const chip_pad_dip: f32 = 4;
const chip_radius_dip: f32 = 4;

// -------------------------------------------------------------------------
// Test seam (T673)
//
// A switch that breaks exactly ONE offset rule this composer's acceptance
// scripts assert, so those scripts can be SHOWN to fail instead of being
// trusted. The alternative was a source edit plus two full rebuilds per
// check, which is friction enough that the check stops happening — the same
// argument that produced `GHOZTTY_TEST_LIVENESS_BREAK` for the restore
// scripts (T532/T652).
//
// Debug builds only, and read once. A stray environment variable must never
// be able to corrupt what a user typed into a report.
//
//   GHOZTTY_TEST_BREAK_UTF16=1  the byte <-> UTF-16 conversion becomes the
//                               identity (`utf16_offset.zig`), which is
//                               exactly the defect T648 fixed. Reds the
//                               offset arms of `viewer-feedback-utf16.ps1`.
//
// It had a sibling, `GHOZTTY_TEST_BREAK_CHIP_RANGE`, that shortened the
// RichEdit's whole-chip selection. The page deletes a chip as one node, so
// there is no native range left to break, and the seam went with the control
// (T1704).
// -------------------------------------------------------------------------

var test_seams_read: bool = false;

/// Read the seam variable once, at the first composer's creation.
fn readTestSeams(alloc: Allocator) void {
    if (comptime !build_config.is_debug) return;
    if (test_seams_read) return;
    test_seams_read = true;

    if (envIsOne(alloc, "GHOZTTY_TEST_BREAK_UTF16")) {
        utf16_offset.break_identity = true;
        log.warn("test seam active: GHOZTTY_TEST_BREAK_UTF16 " ++
            "(byte<->UTF-16 conversion is the identity)", .{});
    }
}

fn envIsOne(alloc: Allocator, name: []const u8) bool {
    const value = std.process.getEnvVarOwned(alloc, name) catch return false;
    defer alloc.free(value);
    return std.mem.eql(u8, value, "1");
}

/// Where the caret is, as a byte offset into the pane's buffer.
///
/// Answered from the last snapshot the page pushed, not from a question asked
/// now: there is no synchronous way to ask a browser where its caret is, which
/// is the whole shape change T934 carries. A snapshot with no caret in it means
/// focus is not in the box — and no page means no caret at all — so the end of
/// the document is where the next insertion belongs.
fn caret(self: *const ViewerFeedbackBar) usize {
    const wv = self.web orelse return self.pane.feedbackText().len;
    const units = wv.caret orelse return self.pane.feedbackText().len;
    return utf16_offset.byteForUnits(self.pane.feedbackText(), units);
}

/// Apply one computed insertion to the PANE's buffer and re-state the page.
///
/// The page cannot be told "insert this here": every native-side edit is "make
/// the document equal the buffer", so the splice happens where the buffer
/// lives and the page is told the result. That seed is marked UNDOABLE (T983):
/// the page keeps the document this one replaced and gives it back on Ctrl+Z
/// once the engine's own steps are spent.
///
/// The quote spans move WITH the text (T1704). `feedbackSetText` drops the
/// spans the page last reported, because they describe the text it replaced;
/// they are put back here shifted past the insertion, plus `quote` — the block
/// this insertion is, when it is one. Before T1704 they were re-derived at seed
/// time by matching each registered passage against the text, which lost the
/// identity of any quote the user had EDITED the moment a second quote or a
/// picture arrived. What happens to a span the insertion lands strictly inside
/// is `doc.shiftSpans`'s call, and is asserted there.
fn spliceComposer(
    self: *ViewerFeedbackBar,
    at: usize,
    insert: []const u8,
    caret_after: usize,
    quote: ?doc.Span,
) void {
    const cur = self.pane.feedbackText();
    const cut = @min(at, cur.len);
    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(self.alloc);
    next.ensureTotalCapacity(self.alloc, cur.len + insert.len) catch return;
    next.appendSliceAssumeCapacity(cur[0..cut]);
    next.appendSliceAssumeCapacity(insert);
    next.appendSliceAssumeCapacity(cur[cut..]);

    // Read BEFORE the write below drops them; shifted against the PRE-insert
    // offsets, which is what they are.
    const old = self.pane.feedbackQuoteSpans(self.alloc);
    defer if (old) |o| self.alloc.free(o);
    const shifted = doc.shiftSpans(self.alloc, old orelse &.{}, cut, insert.len, quote) catch null;
    defer if (shifted) |s| self.alloc.free(s);

    // Suppressed, then seeded by hand: `feedbackSetText`'s own sync would put
    // the caret at the END, and where the caret lands after a quote or a chip
    // is the whole point of `caret_after`.
    self.suppress_sync = true;
    self.pane.feedbackSetText(self.alloc, next.items);
    self.suppress_sync = false;
    if (shifted) |s| self.pane.feedbackSetQuoteSpans(self.alloc, s);

    self.seedPage(caret_after, true);
    // The band's height follows the page's next snapshot, which the seed above
    // is about to produce; all this owes is the repaint of the chrome around
    // it.
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// Drop a quoted passage into the composer at the caret (Mac's Quote button).
///
/// The passage has already been registered by the pane, as the registry's
/// LAST entry, so this is only the editing half: compute the block purely and
/// splice it in with its span. The quote's IDENTITY then belongs to the page:
/// the seed carries the span, the page builds it as a node with the id on it,
/// and every snapshot after that reports where that node actually is (T935).
pub fn insertQuote(self: *ViewerFeedbackBar, passage: []const u8) void {
    const ins = doc.insertion(
        self.alloc,
        self.pane.feedbackText(),
        self.caret(),
        passage,
    ) catch return;
    defer ins.deinit(self.alloc);

    const entries = self.pane.feedback_quotes.entries.items.len;
    const quote: ?doc.Span = if (entries > 0) .{
        .start = ins.block_start,
        .end = ins.block_end,
        .index = entries - 1,
    } else null;
    self.spliceComposer(ins.at, ins.insert, ins.caret_after, quote);
}

// -------------------------------------------------------------------------
// Images (T637)
// -------------------------------------------------------------------------

/// A picture the composer's PAGE took off a paste or a drop (T936).
///
/// The engine decoded it, so there is nothing to intercept and nothing to ask
/// the clipboard: what arrives here is the same PNG `attachImage` has always
/// been handed, and it goes the same way. A picture the page could not hand
/// over says so in the footer rather than vanishing — a paste that appears to
/// do nothing is the failure this whole path exists to end.
pub fn composerImage(self: *ViewerFeedbackBar, image: composer_page.Image) void {
    if (image.png) |png| {
        _ = self.attachImage(png);
        return;
    }
    log.warn("viewer feedback pane={s} image refused by the page: {s} bytes={d}", .{
        self.pane.paneId(),
        @tagName(image.problem),
        image.bytes,
    });
    self.pane.setFeedbackStatus(self.alloc, switch (image.problem) {
        .too_large => "That image is too large to attach",
        else => "That is not an image this can attach",
    });
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// Store one PNG and put its chip at the caret. False when the picture could
/// not be taken, in which case nothing was inserted and the pane has already
/// said why in the footer.
pub fn attachImage(self: *ViewerFeedbackBar, png: []const u8) bool {
    const number = self.pane.feedbackAddImage(self.alloc, png) orelse return false;

    const ins = feedback_images.insertion(
        self.alloc,
        self.pane.feedbackText(),
        self.caret(),
        number,
    ) catch return false;
    defer ins.deinit(self.alloc);

    // Undoable, so Ctrl+Z takes the chip back out the way it takes typing out
    // — and the picture leaves the report with it, because the report is
    // derived from the text.
    self.spliceComposer(ins.at, ins.insert, ins.caret_after, null);
    // The strip scrolls to the picture that just arrived, which is what makes
    // a paste visible once the ribbon is longer than the pane.
    self.showThumb(number);
    log.info("viewer feedback pane={s} image=#{d} bytes={d} live={d}", .{
        self.pane.paneId(),
        number,
        png.len,
        self.pane.feedbackImageCount(self.alloc),
    });
    return true;
}

// -------------------------------------------------------------------------
// The thumbnail carousel (T646)
//
// The strip has NO state of its own about what is in it: every tile is derived
// from the live chips in the composer's text, the same set the report's
// `images` array comes from. Delete a chip and its thumbnail goes with it,
// because there was never a second list to update.
//
// What IS state here is presentation: how far the ribbon is scrolled, which
// tile is ringed, and the decoded bitmaps.
// -------------------------------------------------------------------------

/// Report the strip's whole state on every change: how many tiles, where they
/// are in the BAND's own coordinates, how far the ribbon is scrolled and which
/// tile is ringed.
///
/// This is the acceptance script's only oracle and the reason it is this
/// detailed. The suite runs on a background desktop where nothing can look at
/// painted pixels (T233), so "the thumbnails appeared" has to be a sentence the
/// app says — and geometry it can point a click at, rather than one the script
/// re-derives from design-system constants and gets subtly wrong at 1.25.
fn logCarousel(self: *ViewerFeedbackBar, what: []const u8) void {
    const l = self.currentLayout();
    log.info(
        "viewer feedback pane={s} carousel={s} tiles={d} scroll={d} selected={d} " ++
            "left={d} top={d} thumb={d} stride={d} view={d} max={d} cue={s} focus={d}",
        .{
            self.pane.paneId(),
            what,
            self.images,
            self.carousel_scroll,
            if (self.carousel_selected) |i| @as(i64, @intCast(i)) else -1,
            l.carousel.left,
            l.carousel.top,
            l.thumb,
            l.thumb_stride,
            l.carousel.width(),
            l.maxScroll(),
            @tagName(self.cueState(l)),
            if (self.key_focus == .carousel)
                (if (self.carousel_focus) |i| @as(i64, @intCast(i)) else -1)
            else
                -1,
        },
    );
}

/// The decoded tile for image `number`, at tile side `box`. Decoded on first
/// paint and cached — a repaint of a six-image strip must not be six PNG
/// decodes. Null when GDI+ could not read the picture, which is cached too.
fn thumbFor(self: *ViewerFeedbackBar, number: u32, png: []const u8, box: i32) ?Thumb {
    for (self.thumbs.items) |t| {
        if (t.number == number and t.box == box) return t;
    }
    const size = feedback_images.pngSize(png) orelse return null;
    const fit = layout_mod.fitInto(size.width, size.height, box);
    var entry: Thumb = .{ .number = number, .box = box, .dib = null };
    if (gdiplus_decode.decodeBytes(png, fit.w, fit.h)) |t| {
        entry.dib = t.dib;
        entry.w = t.w;
        entry.h = t.h;
        // Reported because a tile the strip COUNTS and a tile it can actually
        // draw are two different claims, and the acceptance suite runs where
        // no one can look at the pixels to tell them apart.
        log.info("viewer feedback pane={s} thumb=#{d} box={d} decoded={d}x{d}", .{
            self.pane.paneId(),
            number,
            box,
            t.w,
            t.h,
        });
    } else {
        log.warn("viewer feedback thumbnail #{d} could not be decoded", .{number});
    }
    self.thumbs.append(self.alloc, entry) catch {
        // Not cacheable, so it must not leak either: without the cache entry
        // nothing would ever delete this bitmap.
        if (entry.dib) |d| _ = w32.DeleteObject(d);
        return null;
    };
    return entry;
}

/// Point the strip at whichever chip the caret is in: ring its tile and scroll
/// it into view. This is the "vice versa" half of the sync — clicking a chip in
/// the text (or arrowing into one) walks the strip to its picture.
///
/// A caret at either END of a chip counts as inside it, because clicking a chip
/// parks the caret at one of them, and an end that did not count would make the
/// gesture do nothing at all.
fn syncCarouselToCaret(self: *ViewerFeedbackBar) void {
    const spans = self.pane.feedbackImageSpans(self.alloc) orelse return;
    defer self.alloc.free(spans);

    const at = self.caret();
    var found: ?usize = null;
    for (spans, 0..) |s, i| {
        if (at >= s.start and at <= s.end) {
            found = i;
            break;
        }
    }

    const before_sel = self.carousel_selected;
    const before_scroll = self.carousel_scroll;
    self.carousel_selected = found;
    if (found) |i| {
        self.carousel_scroll = self.currentLayout().scrollToShow(i, self.carousel_scroll);
    }
    if (before_sel != self.carousel_selected or before_scroll != self.carousel_scroll) {
        _ = w32.InvalidateRect(self.hwnd, null, 1);
        self.logCarousel("caret");
    }
}

/// Bring image `number`'s tile into view — what a fresh paste does, so the
/// picture that just arrived is the one you can see even when the strip is
/// already longer than the pane.
///
/// Driven by the NUMBER rather than by the caret, because the caret lands past
/// the chip's trailing space and is therefore not "in" it: a paste knows
/// exactly which picture it just added, and guessing from the caret would be a
/// worse answer to a question nobody has to ask.
fn showThumb(self: *ViewerFeedbackBar, number: u32) void {
    const spans = self.pane.feedbackImageSpans(self.alloc) orelse return;
    defer self.alloc.free(spans);
    for (spans, 0..) |s, i| {
        if (self.pane.feedbackImageEntry(s).number != number) continue;
        const next = self.currentLayout().scrollToShow(i, self.carousel_scroll);
        if (next != self.carousel_scroll) {
            self.carousel_scroll = next;
            _ = w32.InvalidateRect(self.hwnd, null, 1);
            self.logCarousel("paste");
        }
        return;
    }
}

/// A tile was clicked: select its chip in the composer and put the caret there.
/// The forward half of the sync, and the reason it selects the whole chip
/// rather than just moving the caret — the chip is one unit, so pointing at it
/// means highlighting all of it.
fn activateThumb(self: *ViewerFeedbackBar, index: usize) void {
    const spans = self.pane.feedbackImageSpans(self.alloc) orelse return;
    defer self.alloc.free(spans);
    if (index >= spans.len) return;
    const s = spans[index];

    if (self.web) |wv| {
        // T936: the chip is a NODE, so pointing at it is selecting the node —
        // not re-seeding the document to park a caret, which would throw the
        // page's undo stack away for a click that changed no text.
        wv.takeFocus();
        wv.pick(self.pane.feedbackImageEntry(s).number);
    }

    self.carousel_selected = index;
    self.carousel_scroll = self.currentLayout().scrollToShow(index, self.carousel_scroll);
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    log.info("viewer feedback pane={s} thumbnail=#{d} chip={d}..{d}", .{
        self.pane.paneId(),
        self.pane.feedbackImageEntry(s).number,
        s.start,
        s.end,
    });
    self.logCarousel("click");
}

/// Which ends of the strip have pictures past them right now (T668) — what the
/// cue paints, and what the acceptance script reads instead of the fade it
/// cannot see.
const CueState = enum { none, start, end, both };

fn cueState(self: *const ViewerFeedbackBar, l: layout_mod.Layout) CueState {
    const at_start = !l.cueRect(.start, self.carousel_scroll).isEmpty();
    const at_end = !l.cueRect(.end, self.carousel_scroll).isEmpty();
    if (at_start and at_end) return .both;
    if (at_start) return .start;
    if (at_end) return .end;
    return .none;
}

/// A click on an overflow cue pages the strip that way — the mouse's half of
/// T668. The wheel already scrolled, but nothing on screen said so; a chevron
/// that does nothing when clicked would be worse than no chevron.
fn pageCarousel(self: *ViewerFeedbackBar, side: layout_mod.Side) void {
    const l = self.currentLayout();
    const next = l.pageScroll(self.carousel_scroll, side);
    if (next == self.carousel_scroll) return;
    self.carousel_scroll = next;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    self.logCarousel("page");
}

/// An arrow key while the strip holds focus (T668): move the ring, scroll the
/// tile it landed on into view, and change nothing about the report itself.
fn walkTiles(self: *ViewerFeedbackBar, move: layout_mod.TileMove) void {
    const next = layout_mod.moveTile(self.carousel_focus, move, self.images) orelse return;
    const l = self.currentLayout();
    const scroll = l.scrollToShow(next, self.carousel_scroll);
    if (next == self.carousel_focus and scroll == self.carousel_scroll) return;
    self.carousel_focus = next;
    self.carousel_scroll = scroll;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    self.logCarousel("walk");
}

/// Enter or Space on the focused tile — the same thing a click on it does.
///
/// It selects the picture's chip, which puts the Win32 focus back on the text
/// surface, so the ring goes with it: the strip is a place focus passes
/// through, and leaving a ring on a tile the keyboard no longer drives would
/// be a lie about where the next keystroke lands.
fn activateFocusedTile(self: *ViewerFeedbackBar) void {
    const i = self.carousel_focus orelse return;
    if (i >= self.images) return;
    // Before the activation, not after: `activateThumb` puts the Win32 focus
    // on the text surface and states the strip on the way past, and a report
    // still naming a focused tile there would be a lie about where the next
    // keystroke lands.
    self.key_focus = .text;
    self.carousel_focus = null;
    self.activateThumb(i);
}

/// Wheel over the band scrolls the strip, when there is anything to scroll.
fn scrollCarousel(self: *ViewerFeedbackBar, delta: i32) void {
    const l = self.currentLayout();
    if (l.maxScroll() == 0) return;
    // One notch moves one whole tile: a strip of discrete pictures reads
    // better stepped than smeared.
    const next = l.clampScroll(self.carousel_scroll - delta * l.thumb_stride);
    if (next == self.carousel_scroll) return;
    self.carousel_scroll = next;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

fn makeFont(f: type_ramp.Font) ?*anyopaque {
    return w32.CreateFontW(
        -f.height,
        0,
        0,
        0,
        f.weight,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face),
    );
}

pub fn setVisible(self: *ViewerFeedbackBar, visible: bool) void {
    // SHOWNA, not SHOW: merely opening the composer must not yank activation
    // away from the page. Focus is given deliberately, by the pane, on the
    // click that opened it.
    _ = w32.ShowWindow(self.hwnd, if (visible) w32.SW_SHOWNA else w32.SW_HIDE);
    // The renderer is created on the way in and given back on the way out.
    // Order matters both times: the band has to be placed (it is, by the
    // pane's bounds sync) before the view can be born the right size, and the
    // view has to go before anything else stops being able to host it.
    if (visible) self.openComposer() else self.closeComposer();
}

/// Put the caret in the composer. Separate from `setVisible` on purpose — see
/// the comment there.
///
/// With no page there is no caret to put anywhere; the band keeps whatever
/// focus it has rather than bouncing it back to itself from its own
/// `WM_SETFOCUS`.
pub fn takeFocus(self: *ViewerFeedbackBar) void {
    if (self.web) |wv| wv.takeFocus();
}

/// Whether keyboard focus is inside the composer right now. The pane's hover
/// poll reads this to hold the nav bar open — and "inside" includes the text
/// surface, which is where focus actually sits while anyone is typing.
pub fn hasFocus(self: *const ViewerFeedbackBar) bool {
    const f = w32.GetFocus() orelse return false;
    if (f == self.hwnd) return true;
    // The web surface's caret lives several windows down inside Chromium's own
    // hierarchy, all of it parented to this band - so the test is descent, not
    // equality.
    return w32.IsChild(self.hwnd, f) != 0;
}

/// The text changed: the pill may have grown or shrunk, so the pane has to
/// re-inset the page. Repaint either way.
fn textChanged(self: *ViewerFeedbackBar) void {
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    self.pane.syncBounds();
}

fn currentLayout(self: *ViewerFeedbackBar) layout_mod.Layout {
    var r: w32.RECT = undefined;
    const w = if (w32.GetClientRect(self.hwnd, &r) != 0) r.right - r.left else 0;
    return layout_mod.Layout.init(self.layoutInput(w, self.scale));
}

// -------------------------------------------------------------------------
// Tooltips (T640)
// -------------------------------------------------------------------------

/// A tool id in this bar's own tool space. Keyed on the button so a tool never
/// has to be renumbered, exactly as `ViewerNavBar.tipId` does it.
fn tipId(b: layout_mod.Button) usize {
    return 0x200 + @as(usize, @intFromEnum(b));
}

/// One tooltip control for both actions, created on demand and kept for the
/// bar's life. A rect tool in `TTF_SUBCLASS` mode — the delay, the placement
/// and the dismissal are then comctl32's, which is the same trade the nav bar
/// makes and for the same reason: this band has no hover machinery of its own
/// worth driving a tip by hand from.
fn tipEnsure(self: *ViewerFeedbackBar) ?w32.HWND {
    if (self.tip) |h| return h;

    var icc = w32.INITCOMMONCONTROLSEX{
        .dwSize = @sizeOf(w32.INITCOMMONCONTROLSEX),
        .dwICC = w32.ICC_TAB_CLASSES,
    };
    _ = w32.InitCommonControlsEx(&icc);

    const tip = w32.CreateWindowExW(
        w32.WS_EX_TOPMOST | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
        w32.TOOLTIPS_CLASS,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.TTS_ALWAYSTIP | w32.TTS_NOPREFIX,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        self.hwnd,
        null,
        null,
        null,
    ) orelse return null;

    // The composer's own theme decides the tip's: this band is already dark or
    // light for the page it sits over, and a light tip over a dark composer is
    // the seam the nav bar's tips do not have.
    if (self.dark) {
        _ = w32.SetWindowTheme(
            tip,
            std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
            null,
        );
    }
    self.tip = tip;
    return tip;
}

fn tipToolInfo(
    self: *ViewerFeedbackBar,
    b: layout_mod.Button,
    rect: w32.RECT,
) w32.TOOLINFOW {
    return .{
        .cbSize = @sizeOf(w32.TOOLINFOW),
        .uFlags = w32.TTF_SUBCLASS,
        .hwnd = self.hwnd,
        .uId = tipId(b),
        .rect = rect,
        .hinst = null,
        .lpszText = @ptrCast(&self.tip_text[@intFromEnum(b)]),
        .lParam = 0,
        .lpReserved = null,
    };
}

/// Bring both tooltips in line with the composer's current rects. Idempotent,
/// and safe before the tip control exists.
///
/// A button the layout has squeezed to nothing has its tool DELETED rather
/// than left pointing at a rectangle nothing paints — a violently narrow pane
/// does exactly that to the actions.
fn syncTip(self: *ViewerFeedbackBar, l: layout_mod.Layout) void {
    const m = icon_button.Metrics.init(self.scale);
    var line: [tip_log_cap]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&line);
    const w = fbs.writer();
    for (std.enums.values(layout_mod.Button)) |b| {
        const i = @intFromEnum(b);
        const box = l.button(b);
        if (box.width() <= 0) {
            self.tipDelete(b);
            continue;
        }

        const text = layout_mod.label(b);
        const n = std.unicode.utf8ToUtf16Le(self.tip_text[i][0 .. tip_text_cap - 1], text) catch 0;
        self.tip_text[i][n] = 0;
        if (n == 0) {
            self.tipDelete(b);
            continue;
        }

        const tip = self.tipEnsure() orelse return;
        // The HIT box, not the paint: a tip should follow the same forgiving
        // target the click does (design system — a hit box may exceed its
        // paint), or the two disagree at the edges.
        const hit = icon_button.hitBox(m, box);
        var ti = self.tipToolInfo(b, .{
            .left = hit.left,
            .top = hit.top,
            .right = hit.right,
            .bottom = hit.bottom,
        });
        if (!self.tip_added[i]) {
            if (w32.SendMessageW(tip, w32.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&ti))) == 0) continue;
            self.tip_added[i] = true;
        } else {
            _ = w32.SendMessageW(tip, w32.TTM_NEWTOOLRECTW, 0, @bitCast(@intFromPtr(&ti)));
            _ = w32.SendMessageW(tip, w32.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&ti)));
        }
        w.print(" {s}:paint={d},{d},{d},{d}:tool={d},{d},{d},{d}:text=\"{s}\"", .{
            @tagName(b),
            box.left, box.top,  box.right,  box.bottom,
            hit.left, hit.top,  hit.right,  hit.bottom,
            text,
        }) catch {};
    }

    self.logTips(line[0..fbs.pos]);
}

/// State the composer's tooltips in the GUI's own stderr, once per CHANGE.
///
/// The band is owner-painted chrome on a desktop nothing can screenshot, so
/// this line is the acceptance script's only view of which tools exist and
/// where they sit — the same oracle, for the same reason, as the nav bar's
/// (T639). Once per change rather than per sync: `place` runs on every bounds
/// pass, and a line per pass would bury the one that changed.
fn logTips(self: *ViewerFeedbackBar, line: []const u8) void {
    if (line.len > self.tip_log.len) return;
    if (std.mem.eql(u8, self.tip_log[0..self.tip_log_len], line)) return;
    @memcpy(self.tip_log[0..line.len], line);
    self.tip_log_len = line.len;
    log.info("viewer feedback tips pane={s}{s}", .{ self.pane.paneId(), line });
}

fn tipDelete(self: *ViewerFeedbackBar, b: layout_mod.Button) void {
    const i = @intFromEnum(b);
    if (!self.tip_added[i]) return;
    var ti = self.tipToolInfo(b, .{ .left = 0, .top = 0, .right = 0, .bottom = 0 });
    if (self.tip) |t| _ = w32.SendMessageW(t, w32.TTM_DELTOOLW, 0, @bitCast(@intFromPtr(&ti)));
    self.tip_added[i] = false;
}

// -------------------------------------------------------------------------
// Keyboard focus (T640)
// -------------------------------------------------------------------------

/// Which actions a Tab may land on right now — the send button is dead while
/// there is nothing to send, and focus does not stop on a dead control.
fn enabledActions(self: *const ViewerFeedbackBar) [layout_mod.button_count]bool {
    var out: [layout_mod.button_count]bool = undefined;
    for (std.enums.values(layout_mod.Button)) |b| {
        out[@intFromEnum(b)] = self.buttonEnabled(b);
    }
    return out;
}

/// Move keyboard focus to `stop` and show it.
///
/// The band itself takes the Win32 focus for a BUTTON stop — there is no child
/// window to focus, the actions are painted by this window — and hands focus
/// straight on to the text surface for `.text`, which is what `WM_SETFOCUS`
/// has always done.
fn focusStop(self: *ViewerFeedbackBar, stop: layout_mod.Stop) void {
    const arriving = stop == .carousel and self.key_focus != .carousel;
    self.key_focus = stop;
    if (stop == .carousel) {
        // The ring arrives on the picture the caret is already in when there
        // is one — walking into the strip from a chip should not throw away
        // where the user was — and on the first tile otherwise.
        if (arriving) self.carousel_focus = self.carousel_selected orelse 0;
        if (self.carousel_focus) |i| {
            if (i >= self.images) self.carousel_focus = if (self.images > 0) 0 else null;
        }
        if (self.carousel_focus) |i| {
            self.carousel_scroll = self.currentLayout().scrollToShow(i, self.carousel_scroll);
        }
    } else self.carousel_focus = null;
    if (stop == .text) {
        self.takeFocus();
    } else if (w32.GetFocus() != self.hwnd) {
        _ = w32.SetFocus(self.hwnd);
    }
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    // The acceptance oracle for the tab order (T640): the ring is painted
    // chrome on a desktop nothing can screenshot, so where focus LANDED is
    // stated rather than looked at.
    log.info("viewer feedback focus pane={s} stop={s}", .{ self.pane.paneId(), @tagName(stop) });
}

/// Tab / shift+Tab.
fn walkFocus(self: *ViewerFeedbackBar, back: bool) void {
    self.focusStop(layout_mod.nextStop(
        self.key_focus,
        back,
        self.enabledActions(),
        self.images > 0,
    ));
    // The strip reports its own focus, so the acceptance oracle can see the
    // ring land on a tile the same way it sees it land on a button.
    if (self.key_focus == .carousel) self.logCarousel("focus");
}

/// Space or Enter on a focused action — the same thing a click does.
///
/// Only ever reached while a BUTTON holds focus, which is the guard that keeps
/// a bare Enter in the text surface a newline (the one behavior this composer
/// must never lose) and a space a space.
fn activateFocused(self: *ViewerFeedbackBar) bool {
    const b = layout_mod.buttonOf(self.key_focus) orelse return false;
    if (!self.buttonEnabled(b)) return true;
    self.activate(b);
    return true;
}

// -------------------------------------------------------------------------
// Painting
// -------------------------------------------------------------------------

fn buttonGlyph(b: layout_mod.Button) icon_button.Glyph {
    return switch (b) {
        .snapshot => .add,
        .send => .send,
    };
}

/// The send button is dead while there is nothing to send (Mac disables it on
/// `model.isEmpty`); the snapshot button never is.
fn buttonEnabled(self: *const ViewerFeedbackBar, b: layout_mod.Button) bool {
    return switch (b) {
        .snapshot => true,
        .send => self.pane.feedbackText().len > 0,
    };
}

fn paint(self: *ViewerFeedbackBar, hdc: w32.HDC, width: i32, height: i32) void {
    const bar_ref = w32.RGB(self.bar_rgb.r, self.bar_rgb.g, self.bar_rgb.b);
    if (w32.CreateSolidBrush(bar_ref)) |brush| {
        defer _ = w32.DeleteObject(@ptrCast(brush));
        var r = w32.RECT{ .left = 0, .top = 0, .right = width, .bottom = height };
        _ = w32.FillRect(hdc, &r, brush);
    }

    const l = layout_mod.Layout.init(self.layoutInput(width, self.scale));
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    self.paintPill(hdc, l);
    // No text here: the page paints its own, in `l.text`. This window draws
    // the pill AROUND it, which is why the page has no border and its
    // background is pushed to match `pill_rgb` (`pushComposerVars`).
    self.paintButtons(hdc, l);
    self.paintCarousel(hdc, l);
    self.paintFooter(hdc, l);
}

/// The thumbnail strip: one tile per live chip, clipped to the viewport, with
/// the caret's own chip ringed.
fn paintCarousel(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
    if (l.carousel.isEmpty()) return;
    const spans = self.pane.feedbackImageSpans(self.alloc) orelse return;
    defer self.alloc.free(spans);
    if (spans.len == 0) return;

    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    _ = w32.IntersectClipRect(
        hdc,
        l.carousel.left,
        l.carousel.top,
        l.carousel.right,
        l.carousel.bottom,
    );

    for (spans, 0..) |s, i| {
        const tile = l.thumbAt(i, self.carousel_scroll);
        // Wholly off one end: nothing to draw, and no decode to pay for.
        if (tile.right <= l.carousel.left or tile.left >= l.carousel.right) continue;

        // The tile's own well, one step off the band exactly as the pill is,
        // so an image with transparent or light edges still reads as a tile.
        self.paintTileFrame(hdc, l, tile, self.carousel_selected == i);

        const e = self.pane.feedbackImageEntry(s);
        const box = l.thumb - 2 * l.thumb_inset;
        const t = self.thumbFor(e.number, e.png, box) orelse continue;
        const dib = t.dib orelse continue;
        blitThumb(hdc, tile, t, dib);
    }

    // The keyboard's ring, on the tile the arrow keys are on (T668) — drawn
    // after every tile, so the next tile's frame cannot paint over it.
    self.paintTileFocus(hdc, l);

    // ...and the overflow cues on top of everything, because their whole job
    // is to say that what is under them continues past the edge.
    for ([_]layout_mod.Side{ .start, .end }) |side| self.paintCue(hdc, l, side);
}

/// The accent focus ring on the tile `key_focus == .carousel` is walking. The
/// same ring the two circular actions get (design system §2.2), on the tile's
/// rounded rect rather than on a circle.
fn paintTileFocus(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
    if (self.key_focus != .carousel) return;
    const i = self.carousel_focus orelse return;
    if (i >= self.images) return;
    const ring = layout_mod.focusRing(self.scale, l.thumbAt(i, self.carousel_scroll));
    const pen = w32.CreatePen(0, ring.width, self.accent_ref) orelse return;
    defer _ = w32.DeleteObject(pen);
    const prev_pen = w32.SelectObject(hdc, pen);
    defer _ = w32.SelectObject(hdc, prev_pen);
    const hollow = w32.GetStockObject(w32.NULL_BRUSH);
    const prev_brush = if (hollow) |b| w32.SelectObject(hdc, b) else null;
    defer if (prev_brush) |b| {
        _ = w32.SelectObject(hdc, b);
    };
    _ = w32.RoundRect(
        hdc,
        ring.path.left,
        ring.path.top,
        ring.path.right,
        ring.path.bottom,
        l.thumb_r * 2,
        l.thumb_r * 2,
    );
}

/// The overflow cue at one end of the strip (T668): the band fading in over
/// whatever continues past the edge, with a chevron pointing that way.
///
/// A fade rather than a hard rule because the thing being communicated is
/// CONTINUATION — a line at the edge says "this stops here", which is the
/// opposite. The chevron carries the meaning on its own for anyone the fade is
/// too subtle for, and it is drawn in the secondary text color, which the
/// design system already holds to a contrast floor against this surface.
fn paintCue(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout, side: layout_mod.Side) void {
    const cue = l.cueRect(side, self.carousel_scroll);
    if (cue.isEmpty()) return;
    const w = cue.width();
    const h = cue.height();
    if (w <= 0 or h <= 0) return;

    // A one-row, `w`-wide premultiplied DIB stretched down the strip: the band
    // background at full alpha on the OUTSIDE edge, transparent on the inside,
    // so the tiles dissolve into the chrome instead of being chopped by it.
    var bmi = std.mem.zeroes(w32.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -1; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;

    if (w32.CreateCompatibleDC(hdc)) |mem_dc| {
        defer _ = w32.DeleteDC(mem_dc);
        var bits: ?*anyopaque = null;
        if (w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0)) |bmp| {
            defer _ = w32.DeleteObject(bmp);
            if (bits) |raw| {
                const pixels = @as([*]u32, @ptrCast(@alignCast(raw)))[0..@intCast(w)];
                for (pixels, 0..) |*p, col| {
                    // Opaque at the outer edge, clear at the inner one.
                    const from_outer: usize = if (side == .start) col else @as(usize, @intCast(w - 1)) - col;
                    const a: u32 = @intCast(255 - @min(255, (from_outer * 255) / @as(usize, @intCast(w))));
                    const r = (@as(u32, self.bar_rgb.r) * a) / 255;
                    const g = (@as(u32, self.bar_rgb.g) * a) / 255;
                    const b = (@as(u32, self.bar_rgb.b) * a) / 255;
                    p.* = (a << 24) | (r << 16) | (g << 8) | b;
                }
                const old = w32.SelectObject(mem_dc, bmp);
                defer _ = w32.SelectObject(mem_dc, old);
                _ = w32.AlphaBlend(
                    hdc,
                    cue.left,
                    cue.top,
                    w,
                    h,
                    mem_dc,
                    0,
                    0,
                    w,
                    1,
                    w32.BLENDFUNCTION{ .SourceConstantAlpha = 255 },
                );
            }
        }
    }

    const m = icon_button.Metrics.init(self.scale);
    const g: icon_button.Glyph = if (side == .start) .back else .forward;
    const box_side = @min(w, l.thumb);
    const cx = @divTrunc(cue.left + cue.right, 2);
    const cy = @divTrunc(cue.top + cue.bottom, 2);
    const box: layout_mod.Rect = .{
        .left = cx - @divTrunc(box_side, 2),
        .top = cy - @divTrunc(box_side, 2),
        .right = cx - @divTrunc(box_side, 2) + box_side,
        .bottom = cy - @divTrunc(box_side, 2) + box_side,
    };
    icon_paint.glyph(hdc, m, icon_button.glyphTarget(m, box, g), g, self.secondary_ref);
}

fn paintTileFrame(
    self: *ViewerFeedbackBar,
    hdc: w32.HDC,
    l: layout_mod.Layout,
    tile: layout_mod.Rect,
    selected: bool,
) void {
    const fill = w32.CreateSolidBrush(w32.RGB(self.pill_rgb.r, self.pill_rgb.g, self.pill_rgb.b));
    // A selected tile is ringed in the accent at 2 px: the ring is the only
    // thing saying "this is the picture the caret is in", so it has to survive
    // sitting next to a bright screenshot.
    const pen = if (selected)
        w32.CreatePen(0, 2, self.accent_ref)
    else
        w32.CreatePen(0, 1, self.border_ref);
    if (fill != null and pen != null) {
        const prev_brush = w32.SelectObject(hdc, @ptrCast(fill.?));
        const prev_pen = w32.SelectObject(hdc, pen.?);
        _ = w32.RoundRect(
            hdc,
            tile.left,
            tile.top,
            tile.right,
            tile.bottom,
            l.thumb_r * 2,
            l.thumb_r * 2,
        );
        _ = w32.SelectObject(hdc, prev_pen);
        _ = w32.SelectObject(hdc, prev_brush);
    }
    if (fill) |b| _ = w32.DeleteObject(@ptrCast(b));
    if (pen) |p| _ = w32.DeleteObject(p);
}

/// Blit one decoded picture into the middle of its tile. Already scaled to fit
/// (see `thumbFor`), so there is no stretch here — the aspect ratio was settled
/// at decode time and cannot be got wrong twice.
///
/// `AlphaBlend` rather than `BitBlt` because the decode keeps the picture's
/// alpha channel (T669): a PNG with a transparent region — a logo, a screenshot
/// cropped to rounded corners — must show the TILE'S OWN FILL through it, which
/// `paintTileFrame` has already laid down underneath. A `BitBlt` would paint
/// whatever the transparent pixels happen to hold, and the decode used to make
/// that opaque black, which is how a see-through picture came out as a black
/// slab in a pale strip.
///
/// The blend is the whole-source kind: `SourceConstantAlpha` 255 so the picture
/// is not additionally faded, and `AC_SRC_ALPHA` because the source really does
/// carry per-pixel alpha, premultiplied, which is what this call reads.
fn blitThumb(hdc: w32.HDC, tile: layout_mod.Rect, t: Thumb, dib: w32.HANDLE) void {
    if (t.w <= 0 or t.h <= 0) return;
    const src = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(src);
    const old = w32.SelectObject(src, dib);
    defer _ = w32.SelectObject(src, old);
    _ = w32.AlphaBlend(
        hdc,
        tile.left + @divTrunc(tile.width() - t.w, 2),
        tile.top + @divTrunc(tile.height() - t.h, 2),
        t.w,
        t.h,
        src,
        0,
        0,
        t.w,
        t.h,
        w32.BLENDFUNCTION{
            .SourceConstantAlpha = 255,
            .AlphaFormat = w32.AC_SRC_ALPHA,
        },
    );
}

fn paintPill(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
    const fill = w32.CreateSolidBrush(w32.RGB(self.pill_rgb.r, self.pill_rgb.g, self.pill_rgb.b));
    const pen = w32.CreatePen(0, 1, self.border_ref); // PS_SOLID
    if (fill != null and pen != null) {
        const prev_brush = w32.SelectObject(hdc, @ptrCast(fill.?));
        const prev_pen = w32.SelectObject(hdc, pen.?);
        // `RoundRect`'s width/height arguments are the ellipse DIAMETERS, so
        // a radius of half the collapsed height becomes that whole height —
        // which is what makes a one-line pill a true capsule.
        _ = w32.RoundRect(
            hdc,
            l.pill.left,
            l.pill.top,
            l.pill.right,
            l.pill.bottom,
            l.pill_r * 2,
            l.pill_r * 2,
        );
        _ = w32.SelectObject(hdc, prev_pen);
        _ = w32.SelectObject(hdc, prev_brush);
    }
    if (fill) |b| _ = w32.DeleteObject(@ptrCast(b));
    if (pen) |p| _ = w32.DeleteObject(p);
}

fn paintButtons(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
    const m = icon_button.Metrics.init(self.scale);
    for (std.enums.values(layout_mod.Button)) |b| {
        const box = l.button(b);
        if (box.width() <= 0) continue;
        const enabled = self.buttonEnabled(b);
        const state: icon_button.State = st: {
            if (!enabled) break :st .normal;
            if (self.pressed == b) break :st .pressed;
            if (self.hover == b and self.pressed == null) break :st .hover;
            break :st .normal;
        };

        // The fill is a CIRCLE rather than the shared rounded rect: these two
        // sit inside a capsule, and a rounded square inside a capsule reads as
        // a control that did not get the memo. Everything else about them —
        // the square they occupy, the shade per state, the glyph centering —
        // is the shared icon-button model, so they stay one set with the
        // toolbar above.
        if (icon_button.paintsFill(state)) {
            const d = icon_button.fillDelta(state, self.dark);
            const fill = w32.CreateSolidBrush(w32.RGB(
                icon_button.shadeChannel(self.pill_rgb.r, d),
                icon_button.shadeChannel(self.pill_rgb.g, d),
                icon_button.shadeChannel(self.pill_rgb.b, d),
            ));
            const pen = w32.CreatePen(5, 1, 0); // PS_NULL — the fill has no ring
            if (fill != null and pen != null) {
                const t = icon_button.targetBox(m, box);
                const prev_brush = w32.SelectObject(hdc, @ptrCast(fill.?));
                const prev_pen = w32.SelectObject(hdc, pen.?);
                _ = w32.Ellipse(hdc, t.left + m.inset, t.top + m.inset, t.right - m.inset, t.bottom - m.inset);
                _ = w32.SelectObject(hdc, prev_pen);
                _ = w32.SelectObject(hdc, prev_brush);
            }
            if (fill) |br| _ = w32.DeleteObject(@ptrCast(br));
            if (pen) |p| _ = w32.DeleteObject(p);
        }

        // Design system §2.2: a control that can be tabbed to draws a 2 DIP
        // accent ring inset 1 DIP inside its painted square whenever it holds
        // keyboard focus — a CIRCLE here, for the same reason the fill above
        // is one. Drawn under the glyph so the mark stays legible over it.
        if (layout_mod.buttonOf(self.key_focus) == b) {
            const ring = layout_mod.focusRing(self.scale, icon_button.targetBox(m, box));
            const pen = w32.CreatePen(w32.PS_SOLID, ring.width, self.accent_ref);
            const hollow = w32.GetStockObject(w32.NULL_BRUSH);
            if (pen) |p| {
                const prev_pen = w32.SelectObject(hdc, p);
                const prev_brush = if (hollow) |h| w32.SelectObject(hdc, h) else null;
                _ = w32.Ellipse(hdc, ring.path.left, ring.path.top, ring.path.right, ring.path.bottom);
                if (prev_brush) |pb| _ = w32.SelectObject(hdc, pb);
                _ = w32.SelectObject(hdc, prev_pen);
                _ = w32.DeleteObject(p);
            }
        }

        const glyph = buttonGlyph(b);
        const color = if (enabled) self.text_ref else self.secondary_ref;
        icon_paint.glyph(hdc, m, icon_button.glyphTarget(m, box, glyph), glyph, color);
    }
}

/// Where the report lands, plus the key hints. Feedback going quietly to the
/// wrong repo is the main failure mode, so the destination is on screen the
/// whole time the composer is open (Mac's footer, same reasoning).
fn paintFooter(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
    // Cleared up front so every path below either paints the link and records
    // where, or leaves no hit box behind. A footer that went away at a narrow
    // width must not keep answering clicks where it used to be.
    self.link_rect = .{};
    if (l.footer.isEmpty()) return;
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    _ = w32.IntersectClipRect(hdc, l.footer.left, l.footer.top, l.footer.right, l.footer.bottom);

    const prev = if (self.caption_font) |f| w32.SelectObject(hdc, f) else null;
    defer if (prev) |p| {
        _ = w32.SelectObject(hdc, p);
    };
    _ = w32.SetTextColor(hdc, self.secondary_ref);

    // Hints trail; the destination leads and gives up its tail first, because
    // a truncated repo name is still readable and a truncated chord is not.
    const hint_w = textWidth(hdc, hints);
    drawUtf8(hdc, @max(l.footer.right - hint_w, l.footer.left), l.footer.top, hints);

    // A send that has landed replaces the destination with what happened to
    // it — Mac's "Filed …". The destination is what the report is ABOUT to do;
    // once it has been done, saying so is the more useful of the two, and the
    // composer closes itself behind the confirmation anyway.
    if (self.pane.feedbackStatus()) |status| {
        const saved2 = w32.SaveDC(hdc);
        defer _ = w32.RestoreDC(hdc, saved2);
        _ = w32.IntersectClipRect(
            hdc,
            l.footer.left,
            l.footer.top,
            @max(l.footer.right - hint_w - 8, l.footer.left),
            l.footer.bottom,
        );
        _ = w32.SetTextColor(hdc, self.text_ref);
        drawUtf8(hdc, l.footer.left, l.footer.top, status);
        // A "Filed …" line has taken the footer, so there is nothing to click
        // where the link was a moment ago — which the reset at the top of this
        // function has already seen to.
        return;
    }

    // The draft's own folder, as a link — the destination the report is about
    // to take, and a folder the user can open and drop files into so they ride
    // along with the report (T645, Mac's `stagingLink`).
    var path_buf: [ViewerPane.staging_path_max]u8 = undefined;
    var line_buf: [ViewerPane.staging_path_max + 260]u8 = undefined;
    const line: ?[]const u8 = if (self.pane.feedbackStagingRelative(&path_buf)) |rel| line: {
        const root = self.pane.feedbackWorktree() orelse break :line null;
        break :line std.fmt.bufPrint(&line_buf, "{s}/{s}", .{
            viewer_worktree.worktreeName(root), rel,
        }) catch null;
    } else null;

    if (line) |text| {
        const saved2 = w32.SaveDC(hdc);
        defer _ = w32.RestoreDC(hdc, saved2);
        const clip_right = @max(l.footer.right - hint_w - 8, l.footer.left);
        _ = w32.IntersectClipRect(hdc, l.footer.left, l.footer.top, clip_right, l.footer.bottom);
        // Hovering brightens it to body text the way every other link in this
        // chrome does; the underline is what says "link" when it is not hovered.
        if (self.link_hover) _ = w32.SetTextColor(hdc, self.text_ref);
        drawUtf8(hdc, l.footer.left, l.footer.top, text);

        const w = @min(textWidth(hdc, text), clip_right - l.footer.left);
        self.paintLinkUnderline(
            hdc,
            l.footer.left,
            l.footer.top,
            w,
            textHeight(hdc, text),
            self.link_hover,
        );
        self.link_rect = .{
            .left = l.footer.left,
            .top = l.footer.top,
            .right = l.footer.left + w,
            .bottom = l.footer.bottom,
        };
        return;
    }

    // No draft and no worktree name to build one from: fall back to naming the
    // working tree, which is the thing a misfiled report gets wrong.
    if (self.pane.feedbackWorktree()) |root| {
        const saved2 = w32.SaveDC(hdc);
        defer _ = w32.RestoreDC(hdc, saved2);
        _ = w32.IntersectClipRect(
            hdc,
            l.footer.left,
            l.footer.top,
            @max(l.footer.right - hint_w - 8, l.footer.left),
            l.footer.bottom,
        );
        drawUtf8(hdc, l.footer.left, l.footer.top, root);
    }
}

/// The rule under a link, in the shape this chrome's other links use (the
/// banner card's): dotted at rest, solid under the pointer, on the same DPI
/// geometry so the two never disagree about where a link's underline sits.
/// Drawn rather than carried on a second underlined font, because the dotted
/// rest state is not something a font can express.
fn paintLinkUnderline(
    self: *ViewerFeedbackBar,
    hdc: w32.HDC,
    x: i32,
    text_y: i32,
    w: i32,
    text_h: i32,
    solid: bool,
) void {
    if (w <= 0) return;
    const u = banner_layout.linkUnderline(text_y, text_h, self.scale);
    const color = if (solid) self.text_ref else self.secondary_ref;
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(brush);

    if (solid) {
        var r: w32.RECT = .{ .left = x, .top = u.y, .right = x + w, .bottom = u.y + u.thickness };
        _ = w32.FillRect(hdc, &r, brush);
        return;
    }
    // Dot phase keyed to the client x, the same absolute phase the banner uses
    // — here there is only one run, but keeping the rule identical is what
    // stops the two link treatments drifting apart.
    const end = x + w;
    var dx: i32 = x - @mod(x, u.period);
    while (dx < end) : (dx += u.period) {
        const left = @max(x, dx);
        const right = @min(end, dx + u.dot);
        if (right <= left) continue;
        var r: w32.RECT = .{ .left = left, .top = u.y, .right = right, .bottom = u.y + u.thickness };
        _ = w32.FillRect(hdc, &r, brush);
    }
}

/// Whether a client point is on the footer's staging link.
fn hitLink(self: *const ViewerFeedbackBar, x: i32, y: i32) bool {
    const r = self.link_rect;
    if (r.right <= r.left) return false;
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

fn drawUtf8(hdc: w32.HDC, x: i32, y: i32, text: []const u8) void {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return;
    if (n == 0) return;
    _ = w32.TextOutW(hdc, x, y, &buf, @intCast(n));
}

/// The drawn height of a run, which is where a link's underline goes. Measured
/// rather than assumed: the caption font's line box changes with the DPI, and
/// an underline placed at a constant offset would cut through the descenders at
/// one scale and float away from the text at another.
fn textHeight(hdc: w32.HDC, text: []const u8) i32 {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return 0;
    if (n == 0) return 0;
    var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = w32.GetTextExtentPoint32W(hdc, &buf, @intCast(n), &size);
    return size.cy;
}

fn textWidth(hdc: w32.HDC, text: []const u8) i32 {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return 0;
    if (n == 0) return 0;
    var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = w32.GetTextExtentPoint32W(hdc, &buf, @intCast(n), &size);
    return size.cx;
}

// -------------------------------------------------------------------------
// Input
// -------------------------------------------------------------------------

fn updateHover(self: *ViewerFeedbackBar, x: i32, y: i32) void {
    const l = self.currentLayout();
    const hot = l.hitButton(self.scale, x, y);
    const hot_enabled: ?layout_mod.Button = if (hot) |b|
        (if (self.buttonEnabled(b)) b else null)
    else
        null;
    const on_link = self.hitLink(x, y);
    if (hot_enabled == self.hover and on_link == self.link_hover) return;
    self.hover = hot_enabled;
    self.link_hover = on_link;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// A button click, delivered on mouse-up over the same button it went down on.
/// `↑` files the report (T636); `+` takes a screenshot (T647).
fn activate(self: *ViewerFeedbackBar, b: layout_mod.Button) void {
    switch (b) {
        .snapshot => self.beginSnapshot(),
        .send => self.pane.sendFeedback(self.alloc),
    }
}

/// Put the region selector up (T647) — the `+` button and Ctrl+Shift+S.
///
/// Idempotent while one is already up: both entry points can be reached while
/// the overlay has focus, and a second full-desktop window over the first is
/// not a second screenshot, it is a stuck screen.
fn beginSnapshot(self: *ViewerFeedbackBar) void {
    if (self.selector != null) return;
    // Before the overlay takes the keyboard — see `capture_focus`.
    self.capture_focus = self.key_focus;
    const hinstance: ?w32.HINSTANCE = @ptrCast(w32.GetModuleHandleW(null));
    self.selector = RegionSelector.begin(
        self.alloc,
        hinstance,
        w32.GetAncestor(self.hwnd, w32.GA_ROOT),
        self.scale,
        self,
        captureDone,
    );
    if (self.selector == null) {
        log.warn("viewer feedback pane={s} capture=unavailable", .{self.pane.paneId()});
    }
}

/// The selector's one callback: attach what it captured, or note the cancel.
///
/// The bytes belong to the selector and are freed as soon as this returns —
/// `attachImage` copies into the pane's store, the same contract the clipboard
/// paste path already relies on.
fn captureDone(ctx: *anyopaque, png: ?[]const u8) void {
    const self: *ViewerFeedbackBar = @ptrCast(@alignCast(ctx));
    // Cleared BEFORE anything else: the selector destroys itself the moment
    // this returns, so the pointer is dead from here on either way.
    self.selector = null;

    if (png) |bytes| {
        _ = self.attachImage(bytes);
    }
    // The overlay took the keyboard to get its Escape; the composer is where
    // the user was typing, and where the chip just landed. Back to whichever
    // stop had focus, so a capture started from the keyboard leaves the ring
    // on the button that started it rather than silently dropping into the
    // text (T640).
    self.focusStop(self.capture_focus);
}

/// Repaint the composer's own chrome — what the pane calls when something it
/// owns and this draws (the footer's status line) has changed.
pub fn repaint(self: *ViewerFeedbackBar) void {
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// The band's own keys while it holds the Win32 focus (a button or the strip
/// has the ring): the composer chords, then Space/Enter/arrows on whatever the
/// ring is on. Keys typed into the PAGE never come here — they reach Chromium,
/// and the chords among them are claimed by `claimsComposerKey` instead.
/// Returns true when consumed.
fn handleKey(self: *ViewerFeedbackBar, vk: u16) bool {
    const mods: input.Mods = .{
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
        .super = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0,
    };
    if (viewer_accel.composerChord(vk, mods)) |chord| {
        self.runChord(chord);
        return true;
    }
    // Space and Enter press the action that has keyboard focus (T640) — the
    // same two keys every Windows button answers. Guarded on a BUTTON holding
    // focus, which is what keeps a bare Enter in the text a newline and a
    // space a space; the guard is exact, so a chorded Space still falls
    // through to whatever else claims it.
    const bare = !mods.ctrl and !mods.shift and !mods.alt and !mods.super;

    // The strip's own keys (T668), claimed ONLY while it holds focus — which
    // also means the band holds the Win32 focus, so an arrow key in the text
    // surface still moves the caret and a Space there is still a space.
    if (bare and self.key_focus == .carousel) {
        if (tileMoveFor(vk)) |move| {
            self.walkTiles(move);
            return true;
        }
        if (vk == w32.VK_SPACE or vk == w32.VK_RETURN) {
            self.activateFocusedTile();
            return true;
        }
    }

    if (bare and (vk == w32.VK_SPACE or vk == w32.VK_RETURN)) {
        if (self.activateFocused()) return true;
    }
    return false;
}

/// The strip's arrow/Home/End walk. Left and Right are the axis the pictures
/// are laid out on; Home and End are what every Windows list answers with.
fn tileMoveFor(vk: u16) ?layout_mod.TileMove {
    return switch (vk) {
        w32.VK_LEFT => .prev,
        w32.VK_RIGHT => .next,
        w32.VK_HOME => .first,
        w32.VK_END => .last,
        else => null,
    };
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

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) != 0) {
                self.paint(hdc, r.right - r.left, r.bottom - r.top);
            }
            return 0;
        },
        // The bar's OWN chrome into a caller's DC, for a synchronous pixel
        // capture that cannot tear (T835/T940). Note what this does not cover:
        // the typed text is a WebView2 composited on its own, which no
        // WM_PRINTCLIENT reaches, so it is not in a synchronous capture of
        // this bar. A probe that needs the composer's contents reads the page
        // (`test\win32\lib\WebViewCdp.ps1`) or the pane's buffer instead.
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) == 0) return 0;
            self.paint(@ptrFromInt(wparam), r.right - r.left, r.bottom - r.top);
            return 0;
        },

        // Focus lands on the text control, not on the band; a click that
        // reaches the band itself hands it straight on so the caret is never
        // somewhere the user cannot type.
        w32.WM_SETFOCUS => {
            self.focused = true;
            // A BUTTON stop means the band itself is the focused control and
            // is drawing the ring — handing focus on to the text there would
            // undo the Tab that just arrived. Every other case is the old
            // behavior: focus lands on the text, never on the band.
            if (self.key_focus == .text) {
                self.takeFocus();
            } else {
                _ = w32.InvalidateRect(hwnd, null, 1);
            }
            return 0;
        },

        w32.WM_KILLFOCUS => {
            self.focused = false;
            // Focus left the band — to the text surface, or out of the
            // composer entirely. Either way no action holds it any more, so
            // the ring goes with it rather than lingering on a control the
            // keyboard no longer reaches — the strip's ring included.
            self.key_focus = .text;
            self.carousel_focus = null;
            _ = w32.InvalidateRect(hwnd, null, 1);
            return 0;
        },

        // The link is the one thing in this band that is not a button, so it
        // needs its own cursor answer; everything else keeps the arrow.
        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                _ = w32.ScreenToClient(hwnd, &pt);
                if (self.hitLink(pt.x, pt.y)) {
                    _ = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_HAND));
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_MOUSEMOVE => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)))));
            self.updateHover(x, y);
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
            if (self.hover != null or self.pressed != null or self.link_hover) {
                self.hover = null;
                self.pressed = null;
                self.link_hover = false;
                _ = w32.InvalidateRect(hwnd, null, 1);
            }
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)))));
            // A click anywhere in the band puts the caret here — clicking a
            // composer to type in it is not a thing a user should have to aim
            // for.
            _ = w32.SetFocus(hwnd);
            if (self.hitLink(x, y)) {
                self.link_pressed = true;
                _ = w32.SetCapture(hwnd);
                return 0;
            }
            const l = self.currentLayout();
            if (l.hitButton(self.scale, x, y)) |b| {
                if (self.buttonEnabled(b)) {
                    self.pressed = b;
                    _ = w32.SetCapture(hwnd);
                    _ = w32.InvalidateRect(hwnd, null, 1);
                }
                return 0;
            }
            // An overflow cue pages the strip, and it is checked BEFORE the
            // tiles: the cue is painted over the tile it is fading out, so the
            // pixels belong to the affordance the user can actually see. It
            // acts on the DOWN, the way a scrollbar's arrow does.
            if (l.hitCue(self.carousel_scroll, x, y)) |side| {
                self.pageCarousel(side);
                return 0;
            }
            // A tile acts on mouse-UP over the same tile, the way the two
            // circular actions do — a click that slid off is a cancelled click
            // everywhere else in this chrome.
            if (l.hitThumb(self.carousel_scroll, x, y)) |i| {
                self.pressed_thumb = i;
                _ = w32.SetCapture(hwnd);
            }
            return 0;
        },

        w32.WM_LBUTTONUP => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)))));
            _ = w32.ReleaseCapture();
            const was = self.pressed;
            const was_thumb = self.pressed_thumb;
            const was_link = self.link_pressed;
            self.pressed = null;
            self.pressed_thumb = null;
            self.link_pressed = false;
            if (was_link) {
                _ = w32.InvalidateRect(hwnd, null, 1);
                // A click that slid off the link is a cancelled click, the same
                // rule the buttons and the tiles follow.
                if (self.hitLink(x, y)) self.pane.revealFeedbackStagingFolder(self.alloc);
                return 0;
            }
            _ = w32.InvalidateRect(hwnd, null, 1);
            const l = self.currentLayout();
            if (was) |b| {
                if (l.hitButton(self.scale, x, y) == b) self.activate(b);
            } else if (was_thumb) |i| {
                if (l.hitThumb(self.carousel_scroll, x, y) == i) self.activateThumb(i);
            }
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            const raw: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
            self.scrollCarousel(@divTrunc(@as(i32, raw), @as(i32, w32.WHEEL_DELTA)));
            return 0;
        },

        WM_APP_RELAYOUT => {
            self.textChanged();
            return 0;
        },

        // A chord the web surface's accelerator handler claimed, delivered here
        // so it runs on the message loop rather than inside the runtime's own
        // callback - where `close` would tear the controller down under its own
        // Invoke frame.
        ViewerFeedbackWeb.WM_APP_COMPOSER_CHORD => {
            const vk: u16 = @intCast(wparam & 0xFFFF);
            const mods: input.Mods = @bitCast(@as(u16, @intCast(@as(usize, @bitCast(lparam)) & 0xFFFF)));
            self.runComposerChord(vk, mods);
            return 0;
        },

        w32.WM_KEYDOWN => {
            if (self.handleKey(@intCast(wparam & 0xFFFF))) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// T467: `paint` fills the client and then places the pill, the image carousel
// and the send row from a layout built on the bar's own width, so a resize
// makes all of it stale — not just the strip Windows uncovers.
test "viewer feedback class: a resize invalidates the whole bar" {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    registerClass(hinst);
    if (!class_registered) return error.SkipZigTest;
    try class_redraw.expectResizeInvalidatesWholeClient(CLASS_NAME);
}
