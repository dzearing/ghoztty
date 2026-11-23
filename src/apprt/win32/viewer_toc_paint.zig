//! Painting for the viewer pane's table-of-contents card (T1784, split from
//! ViewerTOCPanel.zig): the glass-card backdrop, the resize handle bar, the
//! filter field, and each heading / file-tree row with its selection pill.
const ViewerTOCPanel = @import("ViewerTOCPanel.zig");

const std = @import("std");
const w32 = @import("win32.zig");
const chrome_theme = @import("chrome_theme.zig");
const system_colors = @import("system_colors.zig");
const banner_card = @import("banner_card.zig");
const toc = @import("viewer_toc_layout.zig");
/// What a selected row looks like on this platform (T828/T1008) — the card's
/// rows speak the same selection language as the chooser's since T930.
const list_selection = @import("list_selection.zig");
const icon_button = @import("icon_button.zig");
const icon_paint = @import("icon_button_paint.zig");
const log = std.log.scoped(.viewer_toc);
const gutter_bar = @import("gutter_bar.zig");
const gutter_bar_dc = @import("gutter_bar_dc.zig");

const Row = ViewerTOCPanel.Row;
const measureText = ViewerTOCPanel.measureText;

// -------------------------------------------------------------------------
// Painting
// -------------------------------------------------------------------------

/// Build the glass-card backdrop DIB for a band of `w` x `h` (the card plus a
/// margin on every side), composited over the document background.
pub fn ensureCardSurface(self: *ViewerTOCPanel, hdc: w32.HDC, w: i32, h: i32) void {
    const stale = self.card_dc == null or self.card_w != w or self.card_h != h or
        !std.meta.eql(self.card_bg, self.doc_bg) or self.card_scale != self.scale;
    if (!stale) return;
    self.releaseCardSurface();

    var bmi = std.mem.zeroes(w32.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;

    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
    var bits: ?*anyopaque = null;
    const bmp = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
        _ = w32.DeleteDC(mem_dc);
        return;
    };
    const raw = bits orelse {
        _ = w32.DeleteObject(bmp);
        _ = w32.DeleteDC(mem_dc);
        return;
    };
    _ = w32.SelectObject(mem_dc, bmp);

    const pixels = @as([*]u32, @ptrCast(@alignCast(raw)));
    const count: usize = @intCast(w * h);
    banner_card.render(
        pixels[0..count],
        banner_card.Metrics.init(w, h, self.scale),
        self.doc_bg,
    );

    self.card_dc = mem_dc;
    self.card_bmp = bmp;
    self.card_w = w;
    self.card_h = h;
    self.card_bg = self.doc_bg;
    self.card_scale = self.scale;
}

pub fn releaseCardSurface(self: *ViewerTOCPanel) void {
    if (self.card_dc) |dc| _ = w32.DeleteDC(dc);
    if (self.card_bmp) |b| _ = w32.DeleteObject(b);
    self.card_dc = null;
    self.card_bmp = null;
    self.card_w = 0;
    self.card_h = 0;
    self.card_scale = 0;
}

pub fn fillRoundRect(hdc: w32.HDC, r: w32.RECT, radius: i32, color: u32) void {
    const rgn = w32.CreateRoundRectRgn(
        r.left,
        r.top,
        r.right + 1,
        r.bottom + 1,
        2 * radius,
        2 * radius,
    ) orelse return;
    defer _ = w32.DeleteObject(rgn);
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));
    _ = w32.FillRgn(hdc, rgn, @ptrCast(brush));
}

pub fn paint(self: *ViewerTOCPanel, hdc: w32.HDC, width: i32, height: i32) void {
    self.paintCard(hdc, width, height);
    self.paintHandleBar(hdc, width, height);
}

/// The resize handle's accent bar (T2265; Mac 5e4f30144 gave
/// `SidePanelResizeHandle` the split dividers' `GutterBar`): down the middle
/// of the handle, which straddles the card's edge in the gutter beside it -
/// half strength while hovered, full while dragged, never after.
pub fn paintHandleBar(self: *ViewerTOCPanel, hdc: w32.HDC, width: i32, height: i32) void {
    const l = self.layout;
    const strength = if (l.which == .gutter and l.handle.width() > 0) gutter_bar.single(self.handle_hover, self.drag != null) else null;
    if (!std.meta.eql(strength, self.handle_bar_logged)) {
        self.handle_bar_logged = strength;
        log.debug("viewer tree pane={s} handle bar {s}", .{ self.pane.paneId(), if (strength) |v| @tagName(v) else "none" });
    }
    const st = strength orelse return;
    const h = l.handle;
    const core = gutter_bar.barIn(.{ .left = h.left, .top = h.top, .right = h.right, .bottom = h.bottom }, .across_x, self.scale);
    const color = chrome_theme.accentOn(self.doc_bg, system_colors.accentCached());
    gutter_bar_dc.paintOn(hdc, core, .{ .left = 0, .top = 0, .right = width, .bottom = height }, color, self.scale, st);
}

/// Set (or clear) the hover on the resize handle, repainting on a change.
pub fn setHandleHover(self: *ViewerTOCPanel, hwnd: w32.HWND, on: bool) void {
    if (self.handle_hover == on) return;
    self.handle_hover = on;
    // Debug-build oracle: a posted move's hover is gone within a frame on a
    // background desktop, often before a paint.
    log.debug("viewer tree pane={s} handle hover={}", .{ self.pane.paneId(), on });
    _ = w32.InvalidateRect(hwnd, null, 0);
}

/// Ask again whether the pointer is on the handle, from where it is: a drag's
/// end leaves it on the handle or off it, and the bar follows the pointer, not
/// the drag (Mac 5e4f30144). No readable cursor reads as "off it".
pub fn recheckHandleHover(self: *ViewerTOCPanel, hwnd: w32.HWND) void {
    var pt: w32.POINT = undefined;
    const on = w32.GetCursorPos_(&pt) != 0 and w32.WindowFromPoint(pt) == hwnd and
        w32.ScreenToClient(hwnd, &pt) != 0 and self.onHandle(pt.x, pt.y);
    self.handle_hover = on;
    _ = w32.InvalidateRect(hwnd, null, 0);
}

pub fn paintCard(self: *ViewerTOCPanel, hdc: w32.HDC, width: i32, height: i32) void {
    const l = self.layout;
    if (l.which == .hidden) return;
    self.ensureFonts();

    const margin = self.px(toc.margin_dip);
    const band_w = l.card.width() + 2 * margin;
    const band_h = l.card.height() + 2 * margin;
    self.ensureCardSurface(hdc, band_w, band_h);

    // Backdrop: the glass card over the document background. In gutter mode
    // the window is the whole strip — the band blits at the card's origin
    // minus a margin, and everything below is plain page background. In
    // compact mode the window IS the card, so the band's center crop lands at
    // the origin.
    const doc_ref = w32.RGB(self.doc_bg.r, self.doc_bg.g, self.doc_bg.b);
    if (w32.CreateSolidBrush(doc_ref)) |brush| {
        defer _ = w32.DeleteObject(@ptrCast(brush));
        var full = w32.RECT{ .left = 0, .top = 0, .right = width, .bottom = height };
        _ = w32.FillRect(hdc, &full, brush);
    }
    if (self.card_dc) |mem| {
        switch (l.which) {
            .gutter => _ = w32.BitBlt(
                hdc,
                l.card.left - margin,
                l.card.top - margin,
                band_w,
                band_h,
                mem,
                0,
                0,
                w32.SRCCOPY,
            ),
            .compact => _ = w32.BitBlt(
                hdc,
                0,
                0,
                l.card.width(),
                l.card.height(),
                mem,
                margin,
                margin,
                w32.SRCCOPY,
            ),
            .hidden => unreachable,
        }
    } else {
        // No DIB: a flat card fill still yields a readable list.
        const fill_ref = w32.RGB(self.card_fill.r, self.card_fill.g, self.card_fill.b);
        if (w32.CreateSolidBrush(fill_ref)) |brush| {
            defer _ = w32.DeleteObject(@ptrCast(brush));
            var r = w32.RECT{
                .left = l.card.left,
                .top = l.card.top,
                .right = l.card.right,
                .bottom = l.card.bottom,
            };
            _ = w32.FillRect(hdc, &r, brush);
        }
    }

    // Everything from here on stays inside the card's rounded shape.
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    const radius = self.px(banner_card.RADIUS);
    if (w32.CreateRoundRectRgn(
        l.card.left,
        l.card.top,
        l.card.right + 1,
        l.card.bottom + 1,
        2 * radius,
        2 * radius,
    )) |rgn| {
        defer _ = w32.DeleteObject(rgn);
        _ = w32.SelectClipRgn(hdc, rgn);
    }

    const header_h = self.headerH();
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    // Rows, clipped to the list viewport so they scroll UNDER the header.
    {
        const inner_saved = w32.SaveDC(hdc);
        defer _ = w32.RestoreDC(hdc, inner_saved);
        const list_top = l.card.top + header_h;
        // Clipped to the CARD, not to the list: a row scrolling up leaves the
        // viewport by passing under the translucent header rather than by
        // being cut off at its edge (T543), which is what there is to see
        // through it.
        _ = w32.IntersectClipRect(hdc, l.card.left, l.card.top, l.card.right, l.card.bottom);

        const fill_inset = self.px(toc.fill_inset_dip);
        const origin_y = list_top + fill_inset - self.scroll;
        // Floored against the card before it is spent, exactly as the
        // chooser's rows take it (T305); `list_selection` floors it again
        // against the fill it actually lands on.
        const accent = chrome_theme.accentOn(self.card_fill, system_colors.accentCached());
        const row_radius = self.px(toc.row_corner_dip);
        const emphasized = self.isEmphasized();

        if (self.row_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        for (self.rows.items, 0..) |row, i| {
            const top = origin_y + row.y;
            if (top + row.h < l.card.top) continue;
            if (top > l.card.bottom) break;

            // A section header is a label, not a target: it never fills, so
            // it can never look like something a click would do anything to.
            const is_active = row.interactive() and self.active == @as(i32, @intCast(i));
            const is_hover = row.interactive() and self.hover == @as(i32, @intCast(i));
            const fill_rect = w32.RECT{
                .left = l.card.left + fill_inset,
                .top = top,
                .right = l.card.right - fill_inset,
                .bottom = top + row.h,
            };

            // Windows 11's list selection (T930, the T828 vocabulary): a
            // quiet NEUTRAL fill plus a small accent bar at the leading edge,
            // never the solid accent pill Mac's sidebar paints. Mac's
            // key-window rule survives as the two weights: the ACTIVE window
            // gets the heavier fill and the accent bar, every other window
            // the lighter fill and a neutral bar — so the selection never
            // disappears with its emphasis, and is never carried by color
            // alone. No focus rim: the card takes no keyboard focus, so there
            // is no caret row to mark.
            const sel = list_selection.rowPaint(self.card_fill, accent, .{
                .selected = is_active,
                .focused = emphasized,
                .hovered = is_hover,
                .focus_visible = false,
            });
            if (sel.fill) |f| fillRoundRect(hdc, fill_rect, row_radius, w32.RGB(f.r, f.g, f.b));
            if (sel.indicator) |c| {
                const bar = toc.selectionIndicator(row.h, self.scale);
                const bar_rect = w32.RECT{
                    .left = fill_rect.left + bar.left,
                    .top = top + bar.top,
                    .right = fill_rect.left + bar.left + bar.width,
                    .bottom = top + bar.top + bar.height,
                };
                fillRoundRect(hdc, bar_rect, bar.radius, w32.RGB(c.r, c.g, c.b));
            }
            // The selected row's label steps up from the secondary ink the
            // rest of the list reads in.
            const color = if (is_active) self.text_ref else self.secondary_ref;

            if (row.kind != .heading) {
                self.paintTreeRow(hdc, row, top, color);
                continue;
            }

            const text_left = l.card.left + toc.rowTextLeft(row.depth, self.scale);
            const text_w = toc.rowTextWidth(l.card.width(), row.depth, self.scale);
            var tr = w32.RECT{
                .left = text_left,
                .top = top + self.px(toc.row_v_pad_dip),
                .right = text_left + text_w,
                .bottom = top + row.h - self.px(toc.row_v_pad_dip),
            };
            _ = w32.SetTextColor(hdc, color);
            _ = w32.DrawTextW(
                hdc,
                row.text16.ptr,
                @intCast(row.text16.len),
                &tr,
                w32.DT_WORDBREAK | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );
        }

        // Overflow scroller: a thin overlay thumb, because a list you can
        // scroll with no scroller is a list that looks complete when it
        // isn't.
        const max_s = self.maxScroll();
        if (max_s > 0) {
            const view_h = self.viewportHeight();
            const track_top = list_top + fill_inset;
            const thumb_h = @max(
                @divTrunc(view_h * view_h, self.list_h),
                self.px(24),
            );
            const range = view_h - thumb_h;
            const thumb_top = track_top +
                @divTrunc(range * self.scroll, max_s);
            const tw = self.px(3);
            const tr = w32.RECT{
                .left = l.card.right - self.px(3) - tw,
                .top = thumb_top,
                .right = l.card.right - self.px(3),
                .bottom = thumb_top + thumb_h,
            };
            fillRoundRect(hdc, tr, @divTrunc(tw, 2), self.secondary_ref);
        }
    }

    // The pinned header, over the rows, with the "CONTENTS" caption at the
    // label inset (a sidebar header lines up with the row text, not the fill).
    //
    // Translucent (T543): Mac's `SidePanelHeader` sits on `glassBackdrop()`,
    // so a row scrolling beneath it stays a recognizable shape. GDI has no
    // live blur, and the approximation is to composite the card's OWN backdrop
    // back over the band at just under opaque — the rows read through as a
    // ghost, and the band keeps the card's specular top edge, which the
    // opaque fill this replaces used to paint out.
    {
        var hr = w32.RECT{
            .left = l.card.left,
            .top = l.card.top,
            .right = l.card.right,
            .bottom = l.card.top + header_h,
        };
        var composited = false;
        if (self.card_dc) |mem| {
            const blend = w32.BLENDFUNCTION{
                .SourceConstantAlpha = toc.header_alpha,
                // The backdrop DIB is 0x00RRGGBB — its alpha byte is not a
                // channel, so blend with the constant alpha alone.
                .AlphaFormat = 0,
            };
            composited = w32.AlphaBlend(
                hdc,
                hr.left,
                hr.top,
                hr.right - hr.left,
                header_h,
                mem,
                // The band DIB holds the card inset by one margin, so the
                // card's own origin sits at (margin, margin) in it — the same
                // mapping the backdrop blit above uses.
                margin,
                margin,
                hr.right - hr.left,
                header_h,
                blend,
            ) != 0;
        }
        if (!composited) {
            // No DIB (or a blend the driver refused): an opaque band still
            // reads as a pinned header.
            const fill_ref = w32.RGB(self.card_fill.r, self.card_fill.g, self.card_fill.b);
            if (w32.CreateSolidBrush(fill_ref)) |brush| {
                defer _ = w32.DeleteObject(@ptrCast(brush));
                _ = w32.FillRect(hdc, &hr, brush);
            }
        }
        if (self.header_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        _ = w32.SetTextColor(hdc, self.secondary_ref);
        // The card names what it is listing. One card, two subjects: a
        // document's sections, or a diff's changed files.
        var contents = std.unicode.utf8ToUtf16LeStringLiteral("CONTENTS").*;
        var files = std.unicode.utf8ToUtf16LeStringLiteral("FILES").*;
        const caption: []u16 = if (self.showsFiles()) &files else &contents;
        // The CAPTION band only: with the filter pinned under it, centring on
        // the whole header would drop the caption into the field.
        var cr = w32.RECT{
            .left = l.card.left + self.px(toc.label_inset_dip),
            .top = l.card.top,
            .right = l.card.right - self.px(toc.label_inset_dip),
            .bottom = l.card.top + toc.headerHeight(self.caption_line_h, self.scale),
        };
        _ = w32.DrawTextW(
            hdc,
            caption.ptr,
            @intCast(caption.len),
            &cr,
            w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_NOPREFIX,
        );
        // …and, for a diff, how many there are, right-aligned in the same
        // band. The page's own summary line carries the +/- totals, so the
        // header does not repeat them.
        if (self.showsFiles()) {
            var buf: [48]u8 = undefined;
            const n = self.fileRowCount();
            const tree = self.pane.diffTree();
            // A filtered card says how much of the diff it is showing: "3 of
            // 120 files" keeps the size of the change in view while the list
            // is narrowed (Mac's `diffSummaryText`, "3/120").
            const text = if (tree != null and tree.?.filtered)
                std.fmt.bufPrint(&buf, "{d} of {d} {s}", .{
                    n,
                    tree.?.total_files,
                    if (tree.?.total_files == 1) "file" else "files",
                }) catch ""
            else
                std.fmt.bufPrint(
                    &buf,
                    "{d} {s}",
                    .{ n, if (n == 1) "file" else "files" },
                ) catch "";
            if (text.len > 0) {
                var text16: [48]u16 = undefined;
                const len = std.unicode.utf8ToUtf16Le(&text16, text) catch 0;
                if (len > 0) {
                    _ = w32.DrawTextW(
                        hdc,
                        &text16,
                        @intCast(len),
                        &cr,
                        w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_RIGHT | w32.DT_NOPREFIX,
                    );
                }
            }
            if (self.filter_edit != null) self.paintFilter(hdc);
        }
    }
}

/// The filter's well, its magnifier, and — while there is text to clear — the
/// clear button (T1336). The EDIT paints its own text over the well; with
/// WS_CLIPCHILDREN on the card this never draws across it.
pub fn paintFilter(self: *ViewerTOCPanel, hdc: w32.HDC) void {
    const b = self.filterBoxes();
    fillRoundRect(
        hdc,
        .{ .left = b.well.left, .top = b.well.top, .right = b.well.right, .bottom = b.well.bottom },
        self.px(toc.row_corner_dip),
        w32.RGB(self.field_rgb.r, self.field_rgb.g, self.field_rgb.b),
    );

    const m = icon_button.Metrics.init(self.scale);
    // A label for the field, not a button: no fill, no hover.
    icon_paint.glyph(hdc, m, iconRect(b.glyph), .search, self.secondary_ref);

    if (!self.filterHasText()) return;
    const clear = iconRect(b.clear);
    if (self.clear_hover or self.clear_pressed) {
        const state: icon_button.State = if (self.clear_pressed) .pressed else .hover;
        const d = icon_button.fillDelta(state, self.dark);
        fillRoundRect(
            hdc,
            .{ .left = b.clear.left, .top = b.clear.top, .right = b.clear.right, .bottom = b.clear.bottom },
            self.px(4),
            w32.RGB(
                icon_button.shadeChannel(self.field_rgb.r, d),
                icon_button.shadeChannel(self.field_rgb.g, d),
                icon_button.shadeChannel(self.field_rgb.b, d),
            ),
        );
    }
    icon_paint.glyph(
        hdc,
        m,
        icon_button.glyphTarget(m, clear, .close),
        .close,
        if (self.clear_hover) self.text_ref else self.secondary_ref,
    );
}

pub fn iconRect(r: toc.Rect) icon_button.Rect {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

/// Whether a client point is on the clear button — only while it is showing.
pub fn onClear(self: *const ViewerTOCPanel, x: i32, y: i32) bool {
    if (!self.showsFiles() or self.layout.which == .hidden) return false;
    if (!self.filterHasText()) return false;
    return self.filterBoxes().clear.containsPoint(x, y);
}

/// Whether a client point is in the filter's well (the field and its glyph).
pub fn onFilter(self: *const ViewerTOCPanel, x: i32, y: i32) bool {
    if (self.filter_edit == null or !self.showsFiles() or self.layout.which == .hidden) return false;
    return self.filterBoxes().well.containsPoint(x, y);
}

/// One diff-tree row: `[status] name -- +12 -3` for a file, `[chevron] path`
/// for a folder, and a plain caption for a section header.
///
/// `ink` is the label color the row loop already resolved (selection, hover
/// and unemphasized states are its business, not this function's). The row
/// always sits on a neutral wash since T930, so the badge and the counts keep
/// their own tones in every state.
pub fn paintTreeRow(
    self: *ViewerTOCPanel,
    hdc: w32.HDC,
    row: Row,
    top: i32,
    ink: u32,
) void {
    const l = self.layout;
    const boxes = toc.treeRowBoxes(
        l.card.width(),
        row.depth,
        self.scale,
        row.badge_w,
        row.counts_w,
    );
    const text_top = top + self.px(toc.row_v_pad_dip);
    const text_bottom = top + row.h - self.px(toc.row_v_pad_dip);

    // A section header is the card's own caption voice, one indent in.
    if (row.kind == .section) {
        var sr = w32.RECT{
            .left = l.card.left + toc.rowTextLeft(row.depth, self.scale),
            .top = text_top,
            .right = l.card.right - self.px(toc.label_inset_dip),
            .bottom = text_bottom,
        };
        _ = w32.SetTextColor(hdc, self.secondary_ref);
        _ = w32.DrawTextW(
            hdc,
            row.text16.ptr,
            @intCast(row.text16.len),
            &sr,
            w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
        );
        return;
    }

    // The leading box: a status chip for a file, a disclosure chevron for a
    // folder. The chip is a capsule (the design system's named exception for a
    // mark that reports a state), tinted with its own ink so the badge beside
    // a file and the lines inside it agree about what green means.
    if (row.badge16.len > 0) {
        const badge_top = top + @divTrunc(row.h - self.line_h, 2);
        const badge = w32.RECT{
            .left = l.card.left + boxes.badge_left,
            .top = badge_top,
            .right = l.card.left + boxes.badge_right,
            .bottom = badge_top + self.line_h,
        };
        var badge_ink = ink;
        if (row.kind == .file) {
            const fill = chrome_theme.toneFill(self.card_fill, row.tone);
            fillRoundRect(
                hdc,
                badge,
                @divTrunc(self.line_h, 2),
                w32.RGB(fill.r, fill.g, fill.b),
            );
            const tint = chrome_theme.toneInk(self.card_fill, row.tone);
            badge_ink = w32.RGB(tint.r, tint.g, tint.b);
        } else {
            badge_ink = self.secondary_ref;
        }
        var br = badge;
        _ = w32.SetTextColor(hdc, badge_ink);
        _ = w32.DrawTextW(
            hdc,
            row.badge16.ptr,
            @intCast(row.badge16.len),
            &br,
            w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_CENTER | w32.DT_NOPREFIX,
        );
    }

    // The name. Ellipsized through the MIDDLE rather than at the end, which is
    // the readable half of Mac's head truncation: a card this narrow truncates
    // a lot of names, and `Viewer...` identifies nothing while
    // `Viewer...Leaf.zig` keeps both the distinguishing tail and the
    // extension. A folder row's title is a joined path, which is exactly what
    // the flag is for.
    // A filter hit's folder rides on a second line (T1336), so the name takes
    // the first line instead of the row's middle.
    const two_line = row.detail16.len > 0;
    var nr = w32.RECT{
        .left = l.card.left + boxes.name_left,
        .top = text_top,
        .right = l.card.left + boxes.name_right,
        .bottom = if (two_line) text_top + self.line_h else text_bottom,
    };
    const name_ink = if (row.kind == .folder) self.secondary_ref else ink;
    _ = w32.SetTextColor(hdc, name_ink);
    _ = w32.DrawTextW(
        hdc,
        row.text16.ptr,
        @intCast(row.text16.len),
        &nr,
        w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_PATH_ELLIPSIS | w32.DT_NOPREFIX,
    );
    if (two_line) {
        // Secondary ink, path-ellipsized: the folder that tells two
        // same-named hits apart is usually its TAIL.
        var dr = w32.RECT{
            .left = nr.left,
            .top = nr.bottom,
            .right = nr.right,
            .bottom = text_bottom,
        };
        _ = w32.SetTextColor(hdc, self.secondary_ref);
        _ = w32.DrawTextW(
            hdc,
            row.detail16.ptr,
            @intCast(row.detail16.len),
            &dr,
            w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_PATH_ELLIPSIS | w32.DT_NOPREFIX,
        );
    }

    if (row.counts_w == 0) return;

    // The counts, right-aligned against the card's own text inset.
    var x = l.card.left + boxes.counts_left;
    const added = chrome_theme.toneInk(self.card_fill, .good);
    const removed = chrome_theme.toneInk(self.card_fill, .danger);
    if (row.adds16.len > 0) {
        const w = measureText(hdc, row.adds16);
        var r = w32.RECT{ .left = x, .top = text_top, .right = x + w, .bottom = text_bottom };
        const c: u32 = if (row.binary)
            self.secondary_ref
        else
            w32.RGB(added.r, added.g, added.b);
        _ = w32.SetTextColor(hdc, c);
        _ = w32.DrawTextW(
            hdc,
            row.adds16.ptr,
            @intCast(row.adds16.len),
            &r,
            w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_NOPREFIX,
        );
        x += w + self.px(toc.row_gap_dip);
    }
    if (row.dels16.len > 0) {
        const w = measureText(hdc, row.dels16);
        var r = w32.RECT{ .left = x, .top = text_top, .right = x + w, .bottom = text_bottom };
        _ = w32.SetTextColor(hdc, w32.RGB(removed.r, removed.g, removed.b));
        _ = w32.DrawTextW(
            hdc,
            row.dels16.ptr,
            @intCast(row.dels16.len),
            &r,
            w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_NOPREFIX,
        );
    }
}

/// True when this card's top-level window is the ACTIVE window — the Windows
/// reading of Mac's "key window", which decides whether the selected row
/// carries the heavier fill and the accent indicator or the lighter fill and
/// a neutral one (T930).
///
/// `w32.windowIsActive` rather than a bare `GetForegroundWindow` comparison
/// (T215): the latter is null for every window on a background desktop, so
/// the pill painted unemphasized there forever — including under the pixel
/// probes that are supposed to prove it does not.
pub fn isEmphasized(self: *const ViewerTOCPanel) bool {
    return w32.windowIsActive(w32.GetAncestor(self.hwnd, w32.GA_ROOT));
}

/// The top-level window gained or lost activation, which flips
/// `isEmphasized` - but `isEmphasized` is only read at paint time, and a
/// child HWND never receives `WM_ACTIVATE`, so without this the selected row
/// kept the old weight until something unrelated repainted the card (T1407).
/// Measured with the paint probe: activation moved both ways and the card
/// painted zero times; every pixel test passed anyway because the capture
/// itself is a paint.
pub fn onActivationChanged(self: *ViewerTOCPanel) void {
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}
