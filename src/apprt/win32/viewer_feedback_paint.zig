//! The feedback composer's painting plane (split out of `ViewerFeedbackBar.zig`
//! by T1781): the band's background or glass, the pill, the image carousel and
//! its cues, the action buttons, and the footer.

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

const Thumb = ViewerFeedbackBar.Thumb;
const hints = ViewerFeedbackBar.hints;

// -------------------------------------------------------------------------
// Painting
// -------------------------------------------------------------------------

pub fn buttonGlyph(b: layout_mod.Button) icon_button.Glyph {
    return switch (b) {
        .snapshot => .add,
        .send => .send,
    };
}

/// The send button is dead while there is nothing to send (Mac disables it on
/// `model.isEmpty`); the snapshot button never is.
pub fn buttonEnabled(self: *const ViewerFeedbackBar, b: layout_mod.Button) bool {
    return switch (b) {
        .snapshot => true,
        .send => self.pane.feedbackText().len > 0,
    };
}

pub fn paint(self: *ViewerFeedbackBar, hdc: w32.HDC, width: i32, height: i32) void {
    if (!self.paintGlass(hdc, width, height)) {
        const bar_ref = w32.RGB(self.bar_rgb.r, self.bar_rgb.g, self.bar_rgb.b);
        if (w32.CreateSolidBrush(bar_ref)) |brush| {
            defer _ = w32.DeleteObject(@ptrCast(brush));
            var r = w32.RECT{ .left = 0, .top = 0, .right = width, .bottom = height };
            _ = w32.FillRect(hdc, &r, brush);
        }
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

/// On a glass pane the band is the nav bar's material over the sheet rather
/// than a solid band (T1926): on Mac `ChromeBarBackground` is shared by the nav
/// bar and this composer, so the two read as one stack of chrome over the
/// desk. The band sits `top` below the host's top-left, so its slice of the
/// desk is offset by that much. False off glass or when no buffer could be
/// made: the caller fills `bar_rgb`.
pub fn paintGlass(self: *const ViewerFeedbackBar, hdc: w32.HDC, width: i32, height: i32) bool {
    const g = self.pane.glass orelse return false;
    if (width <= 0 or height <= 0) return true;
    const dib = Dib32.create(hdc, width, height) orelse return false;
    defer dib.destroy();
    self.glassBand(dib.pixels, 0, 0, width, height, g);
    _ = w32.BitBlt(hdc, 0, 0, width, height, dib.dc, 0, 0, w32.SRCCOPY);
    return true;
}

/// The band's material at the `w` x `h` block whose top-left is (`x`, `y`) in
/// this window - the pixels `paintGlass` lays at those coordinates.
pub fn glassBand(self: *const ViewerFeedbackBar, out: []u32, x: i32, y: i32, w: i32, h: i32, g: pane_elevation.GlassBackdrop) void {
    pane_elevation.glassHeadRegion(out, @intCast(w), @intCast(h), g.rect[0] + x, g.rect[1] + self.top + y, g.full_w, g.full_h, g.palette, self.pane.bg, self.bar_rgb, g.sheet);
}

/// The overflow cue's opacity at column `col` of a `w`-wide cue: opaque at the
/// strip's outer edge, clear at the inner one (T668).
pub fn cueAlpha(side: layout_mod.Side, col: usize, w: usize) u32 {
    const from_outer: usize = if (side == .start) col else w - 1 - col;
    return @intCast(255 - @min(255, (from_outer * 255) / w));
}

/// `rgb` (`0x??RRGGBB`) premultiplied by `a`, with `a` in the alpha byte - the
/// source `AlphaBlend` wants under `AC_SRC_ALPHA`.
pub fn premultiplied(rgb: u32, a: u32) u32 {
    const r = (((rgb >> 16) & 0xFF) * a) / 255;
    const g = (((rgb >> 8) & 0xFF) * a) / 255;
    const b = ((rgb & 0xFF) * a) / 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

/// The thumbnail strip: one tile per live chip, clipped to the viewport, with
/// the caret's own chip ringed.
pub fn paintCarousel(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
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
pub fn paintTileFocus(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
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
pub fn paintCue(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout, side: layout_mod.Side) void {
    const cue = l.cueRect(side, self.carousel_scroll);
    if (cue.isEmpty()) return;
    const w = cue.width();
    const h = cue.height();
    if (w <= 0 or h <= 0) return;

    // A premultiplied DIB of the band's own background at full alpha on the
    // OUTSIDE edge, transparent on the inside, so the tiles dissolve into the
    // chrome instead of being chopped by it. Solid, that is one row stretched
    // down the strip; on glass (T1926) the band is a material that varies
    // with the desk under it, so the cue is the material at its own pixels.
    const glass = self.pane.glass;
    const src_h: i32 = if (glass != null) h else 1;
    if (Dib32.create(hdc, w, src_h)) |dib| {
        defer dib.destroy();
        const wu: usize = @intCast(w);
        if (glass) |spec| {
            self.glassBand(dib.pixels, cue.left, cue.top, w, h, spec);
        } else {
            const solid = (@as(u32, self.bar_rgb.r) << 16) | (@as(u32, self.bar_rgb.g) << 8) | self.bar_rgb.b;
            @memset(dib.pixels, solid);
        }
        for (dib.pixels, 0..) |*p, i| p.* = premultiplied(p.*, cueAlpha(side, i % wu, wu));
        _ = w32.AlphaBlend(
            hdc,
            cue.left,
            cue.top,
            w,
            h,
            dib.dc,
            0,
            0,
            w,
            src_h,
            w32.BLENDFUNCTION{ .SourceConstantAlpha = 255 },
        );
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

pub fn paintTileFrame(
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
pub fn blitThumb(hdc: w32.HDC, tile: layout_mod.Rect, t: Thumb, dib: w32.HANDLE) void {
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

pub fn paintPill(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
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

pub fn paintButtons(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
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
pub fn paintFooter(self: *ViewerFeedbackBar, hdc: w32.HDC, l: layout_mod.Layout) void {
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
pub fn paintLinkUnderline(
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
pub fn hitLink(self: *const ViewerFeedbackBar, x: i32, y: i32) bool {
    const r = self.link_rect;
    if (r.right <= r.left) return false;
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

pub fn drawUtf8(hdc: w32.HDC, x: i32, y: i32, text: []const u8) void {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return;
    if (n == 0) return;
    _ = w32.TextOutW(hdc, x, y, &buf, @intCast(n));
}

/// The drawn height of a run, which is where a link's underline goes. Measured
/// rather than assumed: the caption font's line box changes with the DPI, and
/// an underline placed at a constant offset would cut through the descenders at
/// one scale and float away from the text at another.
pub fn textHeight(hdc: w32.HDC, text: []const u8) i32 {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return 0;
    if (n == 0) return 0;
    var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = w32.GetTextExtentPoint32W(hdc, &buf, @intCast(n), &size);
    return size.cy;
}

pub fn textWidth(hdc: w32.HDC, text: []const u8) i32 {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return 0;
    if (n == 0) return 0;
    var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = w32.GetTextExtentPoint32W(hdc, &buf, @intCast(n), &size);
    return size.cx;
}

// T1926: the cue's fade is the same ramp whatever it fades to - the solid band
// or the glass material - opaque on the strip's outer edge and clear inside.
test "viewer feedback cue: fade runs opaque outside to clear inside" {
    try std.testing.expectEqual(@as(u32, 255), cueAlpha(.start, 0, 10));
    try std.testing.expectEqual(@as(u32, 255), cueAlpha(.end, 9, 10));
    try std.testing.expect(cueAlpha(.start, 9, 10) < 64);
    try std.testing.expect(cueAlpha(.end, 0, 10) < 64);
    try std.testing.expect(cueAlpha(.start, 3, 10) > cueAlpha(.start, 4, 10));
}

test "viewer feedback cue: premultiplied source for AlphaBlend" {
    try std.testing.expectEqual(@as(u32, 0xFF336699), premultiplied(0x00336699, 255));
    // The coverage byte a glass region carries is not a colour channel.
    try std.testing.expectEqual(@as(u32, 0xFF336699), premultiplied(0xAB336699, 255));
    try std.testing.expectEqual(@as(u32, 0x00000000), premultiplied(0x00FFFFFF, 0));
    try std.testing.expectEqual(@as(u32, 0x80808080), premultiplied(0x00FFFFFF, 0x80));
}
