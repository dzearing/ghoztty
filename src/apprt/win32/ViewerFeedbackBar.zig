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

pub const log = std.log.scoped(.viewer_feedback);

// -------------------------------------------------------------------------
// Split modules (T1775)
// -------------------------------------------------------------------------
//
// This file is the band: its state, construction, theme, layout, quotes and
// window procedure. The planes below used to live inline here (T1781); each
// is imported back as method-call aliases so every `self.f(x)` call site
// reads as it always did. The aliases are the planes' public surface: a
// function the band calls is a function a plane promised, listed here in one
// place.

const paint_plane = @import("viewer_feedback_paint.zig");
pub const buttonGlyph = paint_plane.buttonGlyph;
pub const buttonEnabled = paint_plane.buttonEnabled;
pub const paint = paint_plane.paint;
pub const paintGlass = paint_plane.paintGlass;
pub const glassBand = paint_plane.glassBand;
pub const cueAlpha = paint_plane.cueAlpha;
pub const premultiplied = paint_plane.premultiplied;
pub const paintCarousel = paint_plane.paintCarousel;
pub const paintTileFocus = paint_plane.paintTileFocus;
pub const paintCue = paint_plane.paintCue;
pub const paintTileFrame = paint_plane.paintTileFrame;
pub const blitThumb = paint_plane.blitThumb;
pub const paintPill = paint_plane.paintPill;
pub const paintButtons = paint_plane.paintButtons;
pub const paintFooter = paint_plane.paintFooter;
pub const paintLinkUnderline = paint_plane.paintLinkUnderline;
pub const hitLink = paint_plane.hitLink;
pub const drawUtf8 = paint_plane.drawUtf8;
pub const textHeight = paint_plane.textHeight;
pub const textWidth = paint_plane.textWidth;

const focus_plane = @import("viewer_feedback_focus.zig");
pub const tipId = focus_plane.tipId;
pub const tipEnsure = focus_plane.tipEnsure;
pub const tipToolInfo = focus_plane.tipToolInfo;
pub const syncTip = focus_plane.syncTip;
pub const logTips = focus_plane.logTips;
pub const tipDelete = focus_plane.tipDelete;
pub const enabledActions = focus_plane.enabledActions;
pub const focusStop = focus_plane.focusStop;
pub const walkFocus = focus_plane.walkFocus;
pub const activateFocused = focus_plane.activateFocused;
pub const accTileNumber = focus_plane.accTileNumber;
pub const AccAction = focus_plane.AccAction;
pub const postAccAction = focus_plane.postAccAction;
pub const runAccAction = focus_plane.runAccAction;
pub const notifyAccFocus = focus_plane.notifyAccFocus;

const carousel_plane = @import("viewer_feedback_carousel.zig");
pub const composerImage = carousel_plane.composerImage;
pub const attachImage = carousel_plane.attachImage;
pub const logCarousel = carousel_plane.logCarousel;
pub const thumbFor = carousel_plane.thumbFor;
pub const syncCarouselToCaret = carousel_plane.syncCarouselToCaret;
pub const showThumb = carousel_plane.showThumb;
pub const activateThumb = carousel_plane.activateThumb;
pub const CueState = carousel_plane.CueState;
pub const cueState = carousel_plane.cueState;
pub const pageCarousel = carousel_plane.pageCarousel;
pub const walkTiles = carousel_plane.walkTiles;
pub const activateFocusedTile = carousel_plane.activateFocusedTile;
pub const scrollCarousel = carousel_plane.scrollCarousel;

const composer_plane = @import("viewer_feedback_composer.zig");
pub const openComposer = composer_plane.openComposer;
pub const closeComposer = composer_plane.closeComposer;
pub const composerReady = composer_plane.composerReady;
pub const composerJournal = composer_plane.composerJournal;
pub const dropJournal = composer_plane.dropJournal;
pub const seedPage = composer_plane.seedPage;
pub const imageSeedSpans = composer_plane.imageSeedSpans;
pub const composerState = composer_plane.composerState;
pub const publishQuoteSpans = composer_plane.publishQuoteSpans;
pub const composerSync = composer_plane.composerSync;
pub const pushComposerVars = composer_plane.pushComposerVars;
pub const hexRef = composer_plane.hexRef;
pub const hexRgb = composer_plane.hexRgb;
pub const keyMods = composer_plane.keyMods;
pub const claimsComposerKey = composer_plane.claimsComposerKey;
pub const runComposerChord = composer_plane.runComposerChord;
pub const runChord = composer_plane.runChord;
pub const lineCount = composer_plane.lineCount;
pub const syncLines = composer_plane.syncLines;
pub const syncImages = composer_plane.syncImages;
pub const syncMetrics = composer_plane.syncMetrics;
pub const layoutInput = composer_plane.layoutInput;
pub const barHeight = composer_plane.barHeight;
pub const place = composer_plane.place;
pub const seedControl = composer_plane.seedControl;

// (end of split modules)

const class_name_utf8 = "GhozttyViewerFeedback";
pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral(class_name_utf8);

/// "The wrapped line count moved while I was being laid out; ask the pane to
/// lay me out again." Posted, never sent — see `place`.
pub const WM_APP_RELAYOUT: u32 = w32.WM_APP + 1;

/// "A screen reader asked a painted part to do something" (T1468): wParam is
/// the `AccAction`, lParam the child id. Posted by `viewer_feedback_acc.zig`
/// from inside a COM call, so the action runs from the message loop the way a
/// click's does. `WM_APP + 2` is the web surface's chord post.
pub const WM_APP_ACC_ACTION: u32 = w32.WM_APP + 3;

/// The placeholder an empty composer shows, Mac's accessibility label turned
/// into the cue an empty field needs. The page draws it (a CSS `::before` on
/// the empty box); this is where its words live.
pub const placeholder_utf8 = "What's wrong with what you're looking at?";

/// The key hints in the footer's trailing slot. Spelled in the Windows
/// chords, which is the whole reason it is not Mac's string.
pub const hints = "Ctrl+Enter send  ·  Esc close";

/// UTF-16 units one action's tooltip may hold. The labels are fixed strings
/// (`viewer_feedback_layout.label`) and the longest is under 50, so this is
/// headroom rather than a limit anything is near.
pub const tip_text_cap: usize = 128;

/// Bytes the tooltip log line may hold: two buttons, each a name, two rects
/// and its label.
pub const tip_log_cap: usize = 320;

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
/// The page's undo journal as it last reported it, kept HERE because the page
/// does not outlive a close and the report text does (T1006). A `journal`
/// message verbatim — the same JSON goes back down to a fresh page, which is
/// all native ever does with it. Null when there is nothing to undo, and
/// dropped by every native write that is not an insertion, for the reason the
/// page drops its own copy: an undo must never resurrect a report that was
/// already sent.
journal: ?[]u8 = null,
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

/// The band's accessible object (T1468), created on the first `WM_GETOBJECT`
/// and detached in `destroy`. Null until a screen reader (or anything else
/// reading MSAA) has asked.
acc: ?*Accessible = null,

/// The scale the fonts were last built for; rebuilt when the pane's monitor
/// changes.
scale: f32 = 0,
caption_font: ?*anyopaque = null, // HFONT

/// Where `place` last put the band in the host's client area - under the nav
/// bar, never at the host's top-left - which is the band's slice of the glass
/// sheet (T1926).
top: i32 = 0,

// Theme, derived from the pane's background in `applyTheme` — the same
// derivation the nav bar runs, so the two bands are one surface.
bar_rgb: color_math.Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 },
pill_rgb: color_math.Rgb = .{ .r = 0x1A, .g = 0x1A, .b = 0x1A },
border_ref: u32 = 0x00404040,
text_ref: u32 = 0x00FFFFFF,
secondary_ref: u32 = 0x00AAAAAA,
/// The wash behind a quoted block, and the bar down its left edge (T641).
quote_rgb: color_math.Rgb = .{ .r = 0x24, .g = 0x24, .b = 0x28 },
/// The image chip's label and edge (T986), from the same `accentTokenOn` as
/// `quote_rgb`.
chip_ink_rgb: color_math.Rgb = .{ .r = 0x60, .g = 0xCD, .b = 0xFF },
chip_edge_rgb: color_math.Rgb = .{ .r = 0x2A, .g = 0x5A, .b = 0x7A },
accent_ref: u32 = 0x00D47800,
dark: bool = true,

/// One decoded carousel tile. `dib` is null for a picture GDI+ could not read —
/// cached as a FAILURE on purpose, so an unreadable attachment costs one decode
/// rather than one per repaint.
pub const Thumb = struct {
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
    // A screen reader may hold the accessible object past this point; from
    // here on it answers "disconnected" rather than reading a freed band.
    if (self.acc) |a| {
        self.acc = null;
        a.detach();
    }
    _ = w32.DestroyWindow(self.hwnd);
    if (self.caption_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    self.dropThumbs();
    self.dropJournal();
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
    const token = chrome_theme.accentTokenOn(self.pill_rgb, accent);
    self.quote_rgb = token.wash;
    // The image chip sits on that same wash, labelled and edged in the accent
    // the way Mac's chip is (T986).
    self.chip_ink_rgb = token.ink;
    self.chip_edge_rgb = token.edge;

    // The page paints the pill's interior, so the same derivations are handed
    // over as CSS custom properties - one source for the band's chrome and the
    // text inside it, which is D43's mitigation in one call.
    self.pushComposerVars(true);

    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

// -------------------------------------------------------------------------
// Quotes (T641)
// -------------------------------------------------------------------------

/// A quoted block's three metrics, in DIPs — the design system's 16 DIP step
/// for the text, a 3 DIP accent bar, 5 DIP in from the pill's left edge. The
/// page is dressed with them as CSS custom properties (T935); they are stated
/// here because the rule is that the design system lives in this file, not in
/// a stylesheet.
pub const quote_indent_dip: f32 = 16;
pub const quote_bar_dip: f32 = 3;
pub const quote_bar_x_dip: f32 = 5;

/// An image chip's two, in DIPs (T936): the design system's 4 DIP step for the
/// wash either side of the chip's text, and the same 4 for its corner — the
/// radius the rest of the win32 chrome uses for a small pill.
pub const chip_pad_dip: f32 = 4;
pub const chip_radius_dip: f32 = 4;

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
pub fn caret(self: *const ViewerFeedbackBar) usize {
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
pub fn spliceComposer(
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

    // With no page there is nobody to journal this insertion, so a kept
    // history would skip over it: its first undo would take this edit AND the
    // one it was recorded for (T1006).
    if (self.web == null) self.dropJournal();
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

pub fn makeFont(f: type_ramp.Font) ?*anyopaque {
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
pub fn textChanged(self: *ViewerFeedbackBar) void {
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    self.pane.syncBounds();
}

pub fn currentLayout(self: *ViewerFeedbackBar) layout_mod.Layout {
    var r: w32.RECT = undefined;
    const w = if (w32.GetClientRect(self.hwnd, &r) != 0) r.right - r.left else 0;
    return layout_mod.Layout.init(self.layoutInput(w, self.scale));
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
pub fn activate(self: *ViewerFeedbackBar, b: layout_mod.Button) void {
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
pub fn beginSnapshot(self: *ViewerFeedbackBar) void {
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
                self.notifyAccFocus();
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

        // T1468: the painted parts' accessible object. Only OBJID_CLIENT is
        // ours; the window frame and everything else stay the system's. The
        // id is compared as the 32-bit value it is - on x64 the LPARAM can
        // arrive zero- rather than sign-extended.
        w32.WM_GETOBJECT => {
            if (@as(i32, @truncate(lparam)) == Accessible.OBJID_CLIENT) {
                if (self.acc == null) self.acc = Accessible.create(self.alloc, self) catch null;
                if (self.acc) |a| return a.lresult(wparam);
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        WM_APP_ACC_ACTION => {
            self.runAccAction(@enumFromInt(@as(u1, @truncate(wparam))), @truncate(lparam));
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
