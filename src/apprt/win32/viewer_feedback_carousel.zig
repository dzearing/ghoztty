//! The feedback composer's images plane (split out of `ViewerFeedbackBar.zig`
//! by T1781): pictures the page hands up, and the thumbnail carousel that
//! shows them.

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

const Thumb = ViewerFeedbackBar.Thumb;
const log = ViewerFeedbackBar.log;

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
pub fn logCarousel(self: *ViewerFeedbackBar, what: []const u8) void {
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
pub fn thumbFor(self: *ViewerFeedbackBar, number: u32, png: []const u8, box: i32) ?Thumb {
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
pub fn syncCarouselToCaret(self: *ViewerFeedbackBar) void {
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
pub fn showThumb(self: *ViewerFeedbackBar, number: u32) void {
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
pub fn activateThumb(self: *ViewerFeedbackBar, index: usize) void {
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
pub const CueState = enum { none, start, end, both };

pub fn cueState(self: *const ViewerFeedbackBar, l: layout_mod.Layout) CueState {
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
pub fn pageCarousel(self: *ViewerFeedbackBar, side: layout_mod.Side) void {
    const l = self.currentLayout();
    const next = l.pageScroll(self.carousel_scroll, side);
    if (next == self.carousel_scroll) return;
    self.carousel_scroll = next;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    self.logCarousel("page");
}

/// An arrow key while the strip holds focus (T668): move the ring, scroll the
/// tile it landed on into view, and change nothing about the report itself.
pub fn walkTiles(self: *ViewerFeedbackBar, move: layout_mod.TileMove) void {
    const next = layout_mod.moveTile(self.carousel_focus, move, self.images) orelse return;
    const l = self.currentLayout();
    const scroll = l.scrollToShow(next, self.carousel_scroll);
    if (next == self.carousel_focus and scroll == self.carousel_scroll) return;
    self.carousel_focus = next;
    self.carousel_scroll = scroll;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    self.logCarousel("walk");
    self.notifyAccFocus();
}

/// Enter or Space on the focused tile — the same thing a click on it does.
///
/// It selects the picture's chip, which puts the Win32 focus back on the text
/// surface, so the ring goes with it: the strip is a place focus passes
/// through, and leaving a ring on a tile the keyboard no longer drives would
/// be a lie about where the next keystroke lands.
pub fn activateFocusedTile(self: *ViewerFeedbackBar) void {
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
pub fn scrollCarousel(self: *ViewerFeedbackBar, delta: i32) void {
    const l = self.currentLayout();
    if (l.maxScroll() == 0) return;
    // One notch moves one whole tile: a strip of discrete pictures reads
    // better stepped than smeared.
    const next = l.clampScroll(self.carousel_scroll - delta * l.thumb_stride);
    if (next == self.carousel_scroll) return;
    self.carousel_scroll = next;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}
