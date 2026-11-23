//! Measurement, placement and the slide of the viewer pane's table-of-contents
//! card (T1784, split from ViewerTOCPanel.zig): fonts and row measurement,
//! `place` (gutter vs overlay geometry and the filter EDIT's position), and
//! the show/hide slide - on the compositor (`viewer_toc_comp.zig`) when it
//! can, on a timer moving the window when it cannot.
const ViewerTOCPanel = @import("ViewerTOCPanel.zig");

const std = @import("std");
const w32 = @import("win32.zig");
const FrameClock = @import("FrameClock.zig");
const chrome_reposition = @import("chrome_reposition.zig");
const banner_card = @import("banner_card.zig");
const type_ramp = @import("type_ramp.zig");
const toc = @import("viewer_toc_layout.zig");
const log = std.log.scoped(.viewer_toc);
const builtin = @import("builtin");
const toc_comp = @import("viewer_toc_comp.zig");
const gl_comp_present = @import("../../renderer/gl_comp_present.zig");

const RgnKey = ViewerTOCPanel.RgnKey;
const SLIDE_END_TIMER_ID = ViewerTOCPanel.SLIDE_END_TIMER_ID;
const SLIDE_TICK_MS = ViewerTOCPanel.SLIDE_TICK_MS;
const SLIDE_TIMER_ID = ViewerTOCPanel.SLIDE_TIMER_ID;
const parkedHidden = ViewerTOCPanel.parkedHidden;
const rgnKey = ViewerTOCPanel.rgnKey;

// -------------------------------------------------------------------------
// Measurement & placement
// -------------------------------------------------------------------------

pub fn px(self: *const ViewerTOCPanel, dip: f32) i32 {
    return toc.px(dip, self.scale);
}

pub fn ensureFonts(self: *ViewerTOCPanel) void {
    if (self.row_font != null and self.measured_scale == self.scale) return;
    // The filter field holds the row font, so the old one is released only
    // AFTER the field has been handed its replacement.
    const old_row = self.row_font;
    const old_header = self.header_font;
    defer {
        if (old_row) |f| _ = w32.DeleteObject(@ptrCast(f));
        if (old_header) |f| _ = w32.DeleteObject(@ptrCast(f));
    }
    defer if (self.filter_edit) |edit| {
        if (self.row_font) |f| _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    };
    const row_ramp = type_ramp.caption(self.scale);
    self.row_font = w32.CreateFontW(
        -row_ramp.height,
        0,
        0,
        0,
        row_ramp.weight,
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
    self.header_font = w32.CreateFontW(
        -row_ramp.height,
        0,
        0,
        0,
        type_ramp.weight_semibold,
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

/// Measure every row's wrapped height against `card_w`, filling `y`/`h` and
/// `list_h`. Uses a screen DC — measurement is font metrics, not painting.
pub fn measureRows(self: *ViewerTOCPanel, card_w: i32) void {
    self.ensureFonts();
    const hdc = w32.GetDC(self.hwnd) orelse return;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);

    const font = self.row_font orelse return;
    const prev = w32.SelectObject(hdc, @ptrCast(font));
    defer if (prev) |p| {
        _ = w32.SelectObject(hdc, p);
    };

    // One line's height, measured rather than assumed from the em size.
    var probe = [_]u16{ 'A', 'g' };
    var pr = w32.RECT{ .left = 0, .top = 0, .right = 1000, .bottom = 0 };
    _ = w32.DrawTextW(hdc, &probe, 2, &pr, w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
    self.line_h = @max(pr.bottom - pr.top, 1);
    self.caption_line_h = self.line_h;
    // The filter EDIT draws in this same font, so one line of it is exactly
    // this tall.
    self.filter_edit_h = self.line_h;

    const gap = self.px(1); // Mac: VStack spacing 1 between rows
    var y: i32 = 0;
    for (self.rows.items, 0..) |*row, i| {
        if (i != 0) y += gap;

        // A tree row is one line by construction: its name is a file or folder
        // NAME, and wrapping one across two lines would make a list of them
        // impossible to scan. It is the side labels that decide how much room
        // the name gets, so they are measured first.
        if (row.kind != .heading) {
            row.badge_w = if (row.badge16.len > 0)
                toc.badgeWidth(measureText(hdc, row.badge16), self.line_h, self.scale)
            else
                0;
            const adds_w = measureText(hdc, row.adds16);
            const dels_w = measureText(hdc, row.dels16);
            const both = if (adds_w > 0 and dels_w > 0) self.px(toc.row_gap_dip) else 0;
            row.counts_w = adds_w + both + dels_w;
            row.y = y;
            // A filter hit carries its folder on a second line (T1336).
            const lines: i32 = if (row.detail16.len > 0) 2 else 1;
            row.h = toc.rowHeight(lines, self.line_h, self.scale);
            y += row.h;
            continue;
        }

        const text_w = toc.rowTextWidth(card_w, row.depth, self.scale);
        var r = w32.RECT{ .left = 0, .top = 0, .right = text_w, .bottom = 0 };
        _ = w32.DrawTextW(
            hdc,
            row.text16.ptr,
            @intCast(row.text16.len),
            &r,
            w32.DT_CALCRECT | w32.DT_WORDBREAK | w32.DT_NOPREFIX,
        );
        const measured_lines = std.math.divCeil(i32, @max(r.bottom - r.top, 1), self.line_h) catch 1;
        const lines = std.math.clamp(measured_lines, 1, @as(i32, toc.max_row_lines));
        row.y = y;
        row.h = toc.rowHeight(lines, self.line_h, self.scale);
        y += row.h;
    }
    self.list_h = y;
    self.measured_w = card_w;
    self.measured_scale = self.scale;
    self.dirty = false;
}

/// One run's width in the DC's current font.
pub fn measureText(hdc: w32.HDC, text: []const u16) i32 {
    if (text.len == 0) return 0;
    var r = w32.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.DrawTextW(
        hdc,
        text.ptr,
        @intCast(text.len),
        &r,
        w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
    );
    return @max(r.right - r.left, 0);
}

/// The card content's needed height: header + list inset above and below.
pub fn neededHeight(self: *const ViewerTOCPanel) i32 {
    return self.headerH() +
        2 * self.px(toc.fill_inset_dip) + self.list_h;
}

/// The result of a placement, for the pane's gutter push.
pub const Placement = struct {
    which: toc.Mode,
    card_w_dip: f32,
};

/// Lay the panel out for the pane's current content area and show or hide it.
///
/// `content_top` is where the pane's content begins in host-client
/// coordinates (the nav bar's band when it is visible); `content_w`/`content_h`
/// are the content area's size. `visible` lets the pane keep a compact card
/// hidden while it is toggled closed — the layout is still computed so the
/// nav button knows the card exists.
pub fn place(
    self: *ViewerTOCPanel,
    scale: f32,
    content_top: i32,
    content_w: i32,
    content_h: i32,
    pref_dip: f32,
    visible: bool,
) Placement {
    self.setScale(scale);

    const pane_w_dip = @as(f32, @floatFromInt(content_w)) / scale;
    const which = toc.mode(pane_w_dip, self.itemCount());
    if (which == .hidden) {
        self.hide();
        return .{ .which = .hidden, .card_w_dip = 0 };
    }

    // Measure against the width this mode gives the card; re-measure only
    // when the width, scale, or items moved.
    const card_w_dip = switch (which) {
        .gutter => toc.clampWidth(pref_dip, pane_w_dip),
        .compact => toc.compactCardWidth(pref_dip, pane_w_dip),
        .hidden => unreachable,
    };
    const card_w = self.px(card_w_dip);
    if (self.dirty or self.measured_w != card_w or self.measured_scale != scale) {
        self.measureRows(card_w);
    }

    self.layout = toc.Layout.init(
        scale,
        content_w,
        content_h,
        pref_dip,
        self.neededHeight(),
        self.itemCount(),
    );
    const l = self.layout;

    // Clamp the scroll to the new viewport (a taller card may have absorbed
    // the overflow the old scroll compensated for).
    self.clampScroll();

    // Geometry the compact slide moves over (T543): the card's RESTING
    // origin, which is where it sits at every point of the animation except
    // while one is in flight.
    self.slide_x = l.window.left;
    self.slide_y = content_top + l.window.top;
    self.slide_w = @max(l.window.width(), 1);
    self.slide_h = @max(l.window.height(), 1);

    // A compact card that is closed, stays closed, is not mid-slide, and
    // whose window is already at this rect with this shape (T2946): moving,
    // re-shaping and re-hiding it on every bounds sync cost a divider drag or
    // fold glide past a narrow viewer ~0.3 ms a tick at 4K, for a hidden
    // window that ends up exactly where it was. A sync that DOES move or size
    // it takes the full path, so even a hidden card's window never sits
    // outside the pane (viewer-narrow-pane.ps1 measures hidden ones too).
    const want_rect: [4]i32 = .{ self.slide_x, self.slide_y, self.slide_w, self.slide_h };
    const key = rgnKey(which, l.window.width(), l.window.height(), self.px(banner_card.RADIUS));
    if (parkedHidden(which, self.last_mode, visible, self.slide_timer, self.comp_slide, w32.IsWindowVisible(self.hwnd) != 0) and
        self.placed_rect != null and std.mem.eql(i32, &self.placed_rect.?, &want_rect) and
        RgnKey.same(self.applied_rgn, key))
    {
        self.logCardMetrics();
        return .{ .which = which, .card_w_dip = l.card_w_dip };
    }
    self.placed_rect = null;

    // Resize-aware, in-frame reposition (T1392) — see `chrome_reposition`.
    // The gutter card is as wide as the pane's reserved column, so a divider
    // drag resizes it on every mouse-move.
    _ = chrome_reposition.place(
        self.hwnd,
        self.windowX(),
        self.slide_y,
        self.slide_w,
        self.slide_h,
        0,
    );

    // The compact card floats over live document text, so the WINDOW is
    // clipped to the card's rounded shape — its corners show the page, not a
    // squared-off patch of card fill. The gutter window sits over the page's
    // reserved padding and needs no region.
    if (!RgnKey.same(self.applied_rgn, key)) {
        if (key.round) {
            const rgn = w32.CreateRoundRectRgn(0, 0, key.w + 1, key.h + 1, 2 * key.r, 2 * key.r);
            // The system owns the region on success; on failure the window
            // just keeps square corners (and the next placement tries again).
            self.applied_rgn = if (w32.SetWindowRgn(self.hwnd, rgn, 1) != 0) key else null;
            if (self.applied_rgn == null) {
                if (rgn) |owned| _ = w32.DeleteObject(owned);
            }
        } else {
            self.applied_rgn = if (w32.SetWindowRgn(self.hwnd, null, 1) != 0) key else null;
        }
    }

    // The gutter card is part of the layout and the compact card is an
    // overlay, so only the second one animates — and only when the TOGGLE
    // moved, not when the pane crossed the threshold between the two.
    const animate = which == .compact and self.last_mode == .compact;
    self.last_mode = which;
    self.placeFilterEdit();
    self.setVisible(visible, animate);
    _ = w32.InvalidateRect(self.hwnd, null, 0);
    self.logCardMetrics();
    // Where the window now RESTS, for the parked fast path above: only a
    // placement that left no slide running put it exactly there.
    if (!self.slide_timer and !self.comp_slide) self.placed_rect = want_rect;

    return .{ .which = which, .card_w_dip = l.card_w_dip };
}

/// The filter's boxes in THIS window's client coordinates: the layout's card
/// origin plus `toc.filterBox`'s card-relative geometry.
pub fn filterBoxes(self: *const ViewerTOCPanel) toc.FilterBox {
    const l = self.layout;
    var b = toc.filterBox(l.card.width(), self.caption_line_h, self.filter_edit_h, self.scale);
    inline for (.{ &b.well, &b.glyph, &b.edit, &b.clear }) |r| {
        r.left += l.card.left;
        r.right += l.card.left;
        r.top += l.card.top;
        r.bottom += l.card.top;
    }
    return b;
}

/// Put the filter field in its well, or hide it when the card is listing a
/// document's headings.
pub fn placeFilterEdit(self: *ViewerTOCPanel) void {
    const edit = self.filter_edit orelse return;
    if (!self.showsFiles() or self.layout.which == .hidden) {
        _ = w32.ShowWindow(edit, w32.SW_HIDE);
        return;
    }
    const b = self.filterBoxes();
    _ = chrome_reposition.place(edit, b.edit.left, b.edit.top, b.edit.width(), b.edit.height(), 0);
    _ = w32.ShowWindow(edit, w32.SW_SHOWNA);
}

/// Report the card's measured box, once per CHANGE of it.
///
/// The pinned header's height is a font metric resolved at this scale, not a
/// DIP constant a script could restate — so an acceptance script that wants to
/// look at the header band (T543's translucency check) has no way to find it
/// except to be told. `place` runs on every bounds sync, so a line per call
/// would be noise; a line per change is the same rule `logPanelLayout` follows
/// one level up.
pub fn logCardMetrics(self: *ViewerTOCPanel) void {
    const header_h = self.headerH();
    const w = self.layout.card.width();
    const h = self.layout.card.height();
    if (header_h == self.logged_header and w == self.logged_card_w and
        h == self.logged_card_h) return;
    self.logged_header = header_h;
    self.logged_card_w = w;
    self.logged_card_h = h;
    log.info("viewer toc card pane={s} header={d} card={d}x{d} margin={d}", .{
        self.pane.paneId(),
        header_h,
        w,
        h,
        self.px(toc.margin_dip),
    });
}

/// Raise the card above the WebView2 sibling and show it: the card floats
/// over the document.
pub fn showAbove(self: *ViewerTOCPanel) void {
    _ = w32.SetWindowPos(
        self.hwnd,
        null, // HWND_TOP
        0,
        0,
        0,
        0,
        w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW,
    );
}

/// Drive the card toward `visible`, sliding when `animate` says the change is
/// a toggle and snapping when it is not.
pub fn setVisible(self: *ViewerTOCPanel, visible: bool, animate: bool) void {
    self.slide_want = if (visible) 1.0 else 0.0;
    if (!animate) {
        self.cancelCompSlide();
        self.slide = self.slide_want;
        self.stopSlide();
    } else if (self.compWanted()) {
        // T2764: the whole slide declared to the compositor, which then owns
        // where the card is drawn until it ends. False: there was nothing to
        // slide, or the compositor could not take it, and `slide` holds where
        // the card is for the stepped path below to carry on from.
        if (self.slideOnCompositor()) return;
        if (self.slide != self.slide_want) self.startSlide();
    } else if (self.slide != self.slide_want) {
        // The timer is armed BEFORE the first frame is placed: the parked
        // position is a thing that exists only while one is running.
        self.startSlide();
    }
    self.moveToSlide();
    // A card sliding OUT is still on screen — that is the animation — and one
    // sliding IN has to be shown before it can be seen doing it.
    if (visible or self.slide_timer) {
        self.showAbove();
    } else {
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
    }
}

/// Whether slides go to the compositor: the composition knob's default
/// (`GHOZTTY_COMP_PRESENT=0` opts the whole app out, this card included), and
/// not the oracle's stepped arm. `GHOZTTY_DEBUG_TOC_SLIDE_STEPPED=1` (debug
/// builds) steps the slide on this thread instead - the A/B control, so the
/// compositor rows of the pane's oracle can be watched going red.
pub fn compWanted(self: *const ViewerTOCPanel) bool {
    _ = self;
    if (comptime builtin.os.tag != .windows) return false;
    if (comptime builtin.mode == .Debug) {
        if (std.process.hasNonEmptyEnvVarConstant("GHOZTTY_DEBUG_TOC_SLIDE_STEPPED")) return false;
    }
    return gl_comp_present.enabled();
}

/// Where the card is right now, in slide `t`: read off the declared slide by
/// the clock while one is on the compositor, else the stepped value.
pub fn currentT(self: *const ViewerTOCPanel) f32 {
    if (!self.comp_slide) return self.slide;
    const el: f32 = @floatFromInt(std.time.milliTimestamp() - self.comp_start_ms);
    return toc.slideStep(self.comp_t0, self.comp_want, el);
}

/// Declare the slide from wherever the card is to `slide_want`. True: it is
/// on the compositor and the card's window is hidden at its resting place
/// for the length of it.
pub fn slideOnCompositor(self: *ViewerTOCPanel) bool {
    const want = self.slide_want;
    const geom: [4]i32 = .{ self.slide_x, self.slide_y, self.slide_w, self.slide_h };
    // A bounds sync that changed nothing while a slide runs: it carries on.
    if (self.comp_slide and want == self.comp_want and std.mem.eql(i32, &geom, &self.comp_geom)) return true;
    const t = self.currentT();
    if (t == want) {
        // Already there (or nothing to do): hand the card back to its window.
        if (self.comp_slide) self.finishCompSlide();
        self.slide = want;
        return false;
    }
    // Never both clocks at once: the stepped timer stops here, and `slide`
    // keeps the value it reached.
    self.stopSlide();
    self.slide = t;
    if (!self.declareCompSlide(t, want, geom)) {
        self.comp_failures +|= 1;
        // The stepped path carries on from `slide`, with the window shown.
        self.cancelCompSlide();
        self.slide = t;
        return false;
    }
    return true;
}

pub fn declareCompSlide(self: *ViewerTOCPanel, t: f32, want: f32, geom: [4]i32) bool {
    if (self.comp == null) {
        const parent = w32.GetParent(self.hwnd) orelse return false;
        self.comp = toc_comp.Host.init(parent) catch {
            const f = toc_comp.Host.lastFailure();
            log.warn("viewer toc slide compositor unavailable at {s} hr=0x{x:0>8}; stepping it", .{ f.stage, f.hr });
            return false;
        };
    }
    const host = &self.comp.?;
    const w = self.slide_w;
    const h = self.slide_h;
    const pic = self.snapshotCard(w, h) orelse return false;
    defer self.alloc.free(pic);
    const plan = toc.slidePlan(t, want, self.slide_x, w);
    host.setPicture(pic, w, h) catch return self.compFailed();
    host.play(self.slide_y, plan) catch return self.compFailed();
    // The visual is the card now (and the commit has reached DWM): the
    // window waits at its resting place, hidden, for the hand-back.
    _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
    self.moveToSlide();
    const was_running = self.comp_slide;
    self.comp_slide = true;
    self.comp_t0 = t;
    self.comp_want = want;
    self.comp_start_ms = std.time.milliTimestamp();
    self.comp_plan = plan;
    self.comp_geom = geom;
    self.comp_slides +|= 1;
    const ms = slideMs(plan);
    _ = w32.SetTimer(self.hwnd, SLIDE_END_TIMER_ID, ms, null);
    log.info("viewer toc slide on compositor pane={s} from={d:.3} to={d:.0} ms={d} x={d:.0}->{d:.0} retarget={}", .{
        self.pane.paneId(), t, want, ms, plan.at(0), plan.end_x, was_running,
    });
    debugStall();
    return true;
}

pub fn compFailed(self: *ViewerTOCPanel) bool {
    const f = toc_comp.Host.lastFailure();
    log.warn("viewer toc slide could not go on the compositor at {s} hr=0x{x:0>8}; stepping it", .{ f.stage, f.hr });
    // Built again from nothing on the next slide.
    self.releaseComp();
    self.comp_slide = false;
    return false;
}

pub fn slideMs(plan: toc.SlidePlan) u32 {
    return @intFromFloat(@ceil(plan.span_s * 1000.0));
}

/// `GHOZTTY_DEBUG_TOC_SLIDE_STALL_MS=<n>` (debug builds, T2764): block this
/// thread for n ms the moment a slide starts - the oracle's stand-in for a
/// busy UI thread. A compositor slide moves through it; a stepped one waits.
pub fn debugStall() void {
    if (comptime builtin.mode != .Debug) return;
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_DEBUG_TOC_SLIDE_STALL_MS") catch return;
    defer std.heap.page_allocator.free(raw);
    const ms = std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return;
    if (ms == 0) return;
    log.info("viewer toc slide debug stall ms={d}", .{ms});
    std.Thread.sleep(@as(u64, @min(ms, 5000)) * std.time.ns_per_ms);
}

/// The end-of-slide tick. A timer that came in early waits out the rest; the
/// compositor already holds the card's final place.
pub fn compSlideTick(self: *ViewerTOCPanel) void {
    if (!self.comp_slide) {
        _ = w32.KillTimer(self.hwnd, SLIDE_END_TIMER_ID);
        return;
    }
    const ms = slideMs(self.comp_plan);
    const el = std.time.milliTimestamp() - self.comp_start_ms;
    if (el < ms) {
        _ = w32.SetTimer(self.hwnd, SLIDE_END_TIMER_ID, @intCast(@as(i64, ms) - el), null);
        return;
    }
    self.finishCompSlide();
}

/// The slide reached its end: a card that came in is shown at its resting
/// place FIRST (and painted), and the visual over it taken down after, so the
/// hand-back is the same pixels throughout; a card that left stays hidden.
pub fn finishCompSlide(self: *ViewerTOCPanel) void {
    _ = w32.KillTimer(self.hwnd, SLIDE_END_TIMER_ID);
    if (!self.comp_slide) return;
    self.comp_slide = false;
    self.slide = self.comp_want;
    if (self.comp_want == 1) {
        self.moveToSlide();
        self.showAbove();
        _ = w32.UpdateWindow(self.hwnd);
    }
    // The window is the card again: the host goes with the visual (T3040).
    self.releaseComp();
    log.info("viewer toc slide done pane={s} to={d:.0} ms={d} compositor=true ui_steps=0", .{
        self.pane.paneId(), self.comp_want, std.time.milliTimestamp() - self.comp_start_ms,
    });
}

/// Take a compositor slide down where it has got to, leaving `slide` there
/// and the window hidden - for a snap, a hide, or a fall back to stepping.
pub fn cancelCompSlide(self: *ViewerTOCPanel) void {
    // A host built for a slide that was never declared (no card picture to
    // put on it) goes too: one exists only while a slide does (T3040).
    if (!self.comp_slide) return self.releaseComp();
    self.slide = self.currentT();
    _ = w32.KillTimer(self.hwnd, SLIDE_END_TIMER_ID);
    self.comp_slide = false;
    self.releaseComp();
}

/// Take the visual down and let go of the DirectComposition device, target
/// and surface, and this host's reference on the process's D3D11 device
/// (T3040). The next slide builds a host again; a re-declaration mid-slide
/// keeps the one it has.
pub fn releaseComp(self: *ViewerTOCPanel) void {
    if (self.comp) |*host| host.deinit();
    self.comp = null;
}

/// Whether a compositor host is held right now, and whether its D3D11
/// device is the process's shared one (the pane's own test, T3040).
pub fn compHost(self: *const ViewerTOCPanel) ?struct { shared: bool } {
    const host = self.comp orelse return null;
    return .{ .shared = host.shared };
}

/// The card as its window paints it, `w` x `h`, premultiplied, with the
/// window region's rounded corners clear: the picture the visual carries for
/// a slide. The filter field is a child window, so it is printed in on top
/// at its own place. Caller frees.
pub fn snapshotCard(self: *ViewerTOCPanel, w: i32, h: i32) ?[]u32 {
    if (w <= 0 or h <= 0) return null;
    const n: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
    const pic = self.alloc.alloc(u32, n) catch return null;
    errdefer self.alloc.free(pic);
    const mask = self.alloc.alloc(u32, n) catch {
        self.alloc.free(pic);
        return null;
    };
    defer self.alloc.free(mask);
    if (!self.paintToPixels(pic, w, h, false) or !self.paintToPixels(mask, w, h, true)) {
        self.alloc.free(pic);
        return null;
    }
    toc_comp.premultiplyByMask(pic, mask);
    return pic;
}

/// Paint into a top-down 32-bit DIB and copy its rows to `out`: the card
/// (with its filter field), or with `mask` the window region white on black.
pub fn paintToPixels(self: *ViewerTOCPanel, out: []u32, w: i32, h: i32, mask: bool) bool {
    const mem = w32.CreateCompatibleDC(null) orelse return false;
    defer _ = w32.DeleteDC(mem);
    const bmi = w32.BITMAPINFO{ .bmiHeader = .{ .biWidth = w, .biHeight = -h } };
    var bits: ?*anyopaque = null;
    const bmp = w32.CreateDIBSection(mem, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return false;
    defer _ = w32.DeleteObject(@ptrCast(bmp));
    const raw = bits orelse return false;
    const old = w32.SelectObject(mem, @ptrCast(bmp));
    defer _ = w32.SelectObject(mem, old);
    const dib: [*]u32 = @ptrCast(@alignCast(raw));
    @memset(dib[0..out.len], 0);
    if (mask) {
        const r = self.px(banner_card.RADIUS);
        const rgn = w32.CreateRoundRectRgn(0, 0, w + 1, h + 1, 2 * r, 2 * r) orelse return false;
        defer _ = w32.DeleteObject(rgn);
        const brush = w32.CreateSolidBrush(0x00FFFFFF) orelse return false;
        defer _ = w32.DeleteObject(@ptrCast(brush));
        _ = w32.FillRgn(mem, rgn, @ptrCast(brush));
    } else {
        self.paint(mem, w, h);
        if (self.filter_edit) |edit| {
            if (self.showsFiles() and w32.IsWindowVisible(edit) != 0) {
                const b = self.filterBoxes();
                _ = w32.SetViewportOrgEx(mem, b.edit.left, b.edit.top, null);
                _ = w32.SendMessageW(edit, w32.WM_PRINT, @intFromPtr(mem), w32.PRF_CLIENT | w32.PRF_NONCLIENT | w32.PRF_ERASEBKGND);
                _ = w32.SetViewportOrgEx(mem, 0, 0, null);
            }
        }
    }
    _ = w32.GdiFlush();
    @memcpy(out, dib[0..out.len]);
    return true;
}

/// Where the window sits right now: off the pane's left edge only while a
/// slide is actually running, and at its resting origin the rest of the time.
///
/// A PARKED card is hidden, and a hidden window still has a rect — leaving it
/// out beyond the pane's left edge would make this the one piece of viewer
/// chrome whose bounds escape the pane it belongs to, which
/// `test/win32/viewer-narrow-pane.ps1` checks on every painted window. A
/// slide on the compositor moves the visual, never the window, so the window
/// stays at rest through it.
pub fn windowX(self: *const ViewerTOCPanel) i32 {
    if (!self.slide_timer) return self.slide_x;
    return toc.slideX(self.slide, self.slide_x, self.slide_w);
}

/// Put the window where `windowX` says, without touching its size, z-order or
/// visibility.
pub fn moveToSlide(self: *ViewerTOCPanel) void {
    _ = w32.SetWindowPos(
        self.hwnd,
        null,
        self.windowX(),
        self.slide_y,
        0,
        0,
        w32.SWP_NOSIZE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
    );
}

pub fn startSlide(self: *ViewerTOCPanel) void {
    self.slide_last_ms = std.time.milliTimestamp();
    if (self.slide_timer) return;
    self.slide_steps = 0;
    if (FrameClock.arm(self.hwnd, SLIDE_TIMER_ID, SLIDE_TICK_MS)) {
        self.slide_timer = true;
        return;
    }
    // No timer to be had: land on the final state rather than freeze the card
    // halfway across the pane.
    log.warn("viewer TOC slide timer unavailable; snapping to final state", .{});
    self.slide = self.slide_want;
    self.settleSlide();
}

pub fn stopSlide(self: *ViewerTOCPanel) void {
    if (!self.slide_timer) return;
    FrameClock.disarm(self.hwnd, SLIDE_TIMER_ID);
    self.slide_timer = false;
}

/// One animation frame. Returns having either advanced the card or settled it.
pub fn tickSlide(self: *ViewerTOCPanel) void {
    const now = std.time.milliTimestamp();
    const dt: f32 = @floatFromInt(now - self.slide_last_ms);
    self.slide_last_ms = now;
    self.slide = toc.slideStep(self.slide, self.slide_want, dt);
    self.slide_steps +|= 1;
    self.moveToSlide();
    if (self.slide == self.slide_want) self.settleSlide();
}

/// The card reached the end of its travel: stop the timer, and hide the
/// window if that end was the parked one.
pub fn settleSlide(self: *ViewerTOCPanel) void {
    const ran = self.slide_timer;
    self.stopSlide();
    // Back to the resting rect, which for a card that just parked means the
    // hidden window is inside its pane again.
    self.moveToSlide();
    if (self.slide_want == 0) _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
    if (ran) log.info("viewer toc slide done pane={s} to={d:.0} compositor=false ui_steps={d}", .{
        self.pane.paneId(), self.slide_want, self.slide_steps,
    });
}

/// Whether the card is mid-slide — the state the pane's own tests wait out.
pub fn sliding(self: *const ViewerTOCPanel) bool {
    return self.slide_timer or self.comp_slide;
}

/// Whether the slide in flight is the compositor's (T2764).
pub fn slidingOnCompositor(self: *const ViewerTOCPanel) bool {
    return self.comp_slide;
}

pub fn hide(self: *ViewerTOCPanel) void {
    if (self.filter_edit) |edit| _ = w32.ShowWindow(edit, w32.SW_HIDE);
    self.layout = .{ .which = .hidden };
    self.last_mode = .hidden;
    self.stopSlide();
    self.cancelCompSlide();
    self.slide = 0;
    self.slide_want = 0;
    _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
}
