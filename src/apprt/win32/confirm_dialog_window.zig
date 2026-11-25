const ConfirmDialog = @import("ConfirmDialog.zig");

const std = @import("std");
const App = @import("dialog_app.zig").App; // the real App, or the app-less stub (T2197)
const w32 = @import("win32.zig");
const type_ramp = @import("type_ramp.zig");
const utf16_text = @import("utf16_text.zig");
const brush_cache = @import("brush_cache.zig");
const panel_theme = @import("panel_theme.zig");
const system_colors = @import("system_colors.zig");
const release_notes = @import("release_notes.zig");
const whats_new_layout = @import("whats_new_layout.zig");
const WhatsNewNotesView = @import("WhatsNewNotesView.zig");
const open_dialogs = @import("open_dialogs.zig");

const CLASS_NAME = ConfirmDialog.CLASS_NAME;
const ID_ALT = ConfirmDialog.ID_ALT;
const ID_LINK_BASE = ConfirmDialog.ID_LINK_BASE;
const Options = ConfirmDialog.Options;
const Result = ConfirmDialog.Result;
const TIMEOUT_TIMER_ID = ConfirmDialog.TIMEOUT_TIMER_ID;
const buttonWidth = ConfirmDialog.buttonWidth;
const dismissFromRegistry = ConfirmDialog.dismissFromRegistry;
const fallbackText = ConfirmDialog.fallbackText;
const layoutFor = ConfirmDialog.layoutFor;
const linkAnchor = ConfirmDialog.linkAnchor;
const linkRowWidth = ConfirmDialog.linkRowWidth;
const link_gap_dip = ConfirmDialog.link_gap_dip;
const log = ConfirmDialog.log;
const max_checks = ConfirmDialog.max_checks;
const max_links = ConfirmDialog.max_links;
const max_row_value_dip = ConfirmDialog.max_row_value_dip;
const max_rows = ConfirmDialog.max_rows;
const packLinks = ConfirmDialog.packLinks;
const px = ConfirmDialog.px;
const registerClass = ConfirmDialog.registerClass;
const rowRects = ConfirmDialog.rowRects;
const row_col_gap_dip = ConfirmDialog.row_col_gap_dip;
const row_gap_dip = ConfirmDialog.row_gap_dip;
const rowsExtent = ConfirmDialog.rowsExtent;
const rows_gap_dip = ConfirmDialog.rows_gap_dip;

/// Where `prompt` collects the field's text. Separate from `Result` so `show`
/// can pass null and stay allocation-free.
pub const Output = struct {
    buf: []u8,
    len: usize = 0,
};

pub fn run(
    app: ?*App,
    hinstance: ?w32.HINSTANCE,
    owner: ?w32.HWND,
    scale: f32,
    refocus: ?w32.HWND,
    opts: Options,
    out: ?*Output,
) Result {
    registerClass(hinstance) orelse return fallback(owner, opts);

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;
    const has_icon = opts.icon != .none;
    const has_cancel = opts.style == .ok_cancel;
    // A third button is only offered alongside a Cancel (see `layoutFor`).
    const has_alt = opts.alt_label != null and has_cancel;
    const has_input = opts.input != null;
    const has_note = opts.note != null;
    const n_checks: usize = @min(opts.checks.len, max_checks);
    // The accessory needs a theme and an allocator, both of which come from
    // the app; the app-less paths (startup failure, the standalone updater)
    // never carry notes, and asking for them there is a caller bug, not a
    // reason to fail the dialog.
    const notes_h: i32 = if (opts.notes != null and app != null)
        whats_new_layout.accessoryHeight(scale)
    else
        0;
    // Opening a URL goes through `App.openUrl`, so the app-less paths get no
    // link row rather than a row of dead text.
    const n_links: usize = if (app != null) @min(opts.links.len, max_links) else 0;
    const link_gap = px(link_gap_dip, scale);

    // DPI-scaled dialog font, needed up front to measure the text. It is the
    // ramp's body — the same source `layoutFor` reports as `font_h`, so the
    // font the message is MEASURED in cannot differ from the one it is drawn
    // in (T313).
    const font = w32.CreateFontW(
        -type_ramp.body(scale).height,
        0,
        0,
        0,
        type_ramp.weight_normal,
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
    defer if (font) |f| {
        _ = w32.DeleteObject(f);
    };

    // The note renders (and is measured) in the caption ramp role — fine
    // print, one step below the message's body text (T600).
    const note_font: ?*anyopaque = if (has_note) w32.CreateFontW(
        -type_ramp.caption(scale).height,
        0,
        0,
        0,
        type_ramp.weight_normal,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face),
    ) else null;
    defer if (note_font) |f| {
        _ = w32.DeleteObject(f);
    };

    // Measure the text: wrap at a max width; DrawText shrinks the rect to
    // the widest actual line (or grows it for an unbreakable run, e.g. the
    // About box's executable path — then the dialog widens to fit).
    var text_rect: w32.RECT = .{
        .left = 0,
        .top = 0,
        .right = px(420, scale),
        .bottom = 0,
    };
    var label_w: i32 = 0;
    var note_h: i32 = 0;
    var links_w: i32 = 0;
    var links_h: i32 = 0;
    var link_widths: [max_links]i32 = @splat(0);
    // The labelled rows (T1556): one width per column, one height per row.
    const n_rows: usize = @min(opts.rows.len, max_rows);
    var row_label_w: i32 = 0;
    var row_value_w: i32 = 0;
    var row_h: i32 = 0;
    {
        const hdc = w32.GetDC(null) orelse return fallback(owner, opts);
        defer _ = w32.ReleaseDC(null, hdc);
        const prev = if (font) |f| w32.SelectObject(hdc, f) else null;
        defer if (prev) |p| {
            _ = w32.SelectObject(hdc, p);
        };
        _ = w32.DrawTextW(
            hdc,
            opts.text.ptr,
            @intCast(opts.text.len),
            &text_rect,
            w32.DT_CALCRECT | w32.DT_WORDBREAK | w32.DT_NOPREFIX,
        );

        // Widest button caption, so custom labels never truncate. All three
        // buttons share one width, so the third one has to be measured too —
        // "Disconnect" is wider than either of the stock captions (T1390).
        var labels: [3][:0]const u16 = undefined;
        var n_labels: usize = 1;
        labels[0] = opts.ok_label;
        if (has_cancel) {
            labels[n_labels] = opts.cancel_label;
            n_labels += 1;
        }
        if (has_alt) {
            labels[n_labels] = opts.alt_label.?;
            n_labels += 1;
        }
        for (labels[0..n_labels]) |label| {
            var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = w32.DrawTextW(
                hdc,
                label.ptr,
                @intCast(label.len),
                &r,
                w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
            label_w = @max(label_w, r.right - r.left);
        }

        // A checkbox row must fit its label plus the box glyph, so a long
        // agent name widens the dialog like a long message would.
        for (opts.checks[0..n_checks]) |check| {
            var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = w32.DrawTextW(
                hdc,
                check.label.ptr,
                @intCast(check.label.len),
                &r,
                w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
            text_rect.right = @max(text_rect.right, text_rect.left + (r.right - r.left) + px(24, scale));
        }

        // The note is measured in its own (caption) font. Its widest line
        // widens the dialog like the message's would; its height feeds the
        // layout's note band. The layout rect can only end up wider than
        // measured here, which re-wraps to FEWER lines, never a clipped one.
        if (opts.note) |note_text| {
            const prev_note = if (note_font) |f| w32.SelectObject(hdc, f) else null;
            defer if (prev_note) |p| {
                _ = w32.SelectObject(hdc, p);
            };
            var r: w32.RECT = .{ .left = 0, .top = 0, .right = px(420, scale), .bottom = 0 };
            _ = w32.DrawTextW(
                hdc,
                note_text.ptr,
                @intCast(note_text.len),
                &r,
                w32.DT_CALCRECT | w32.DT_WORDBREAK | w32.DT_NOPREFIX,
            );
            text_rect.right = @max(text_rect.right, text_rect.left + (r.right - r.left));
            note_h = r.bottom - r.top;
        }

        // Each link is measured as the LABEL it renders as — the `<a>` runs
        // are markup, not glyphs, so measuring the markup would reserve a slot
        // half again too wide. A few pixels of slack per link: SysLink insets
        // its text slightly and a hairline of clipping on "GitHub" would be
        // the kind of defect that only shows up at one DPI.
        for (opts.links[0..n_links], 0..) |link, i| {
            var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = w32.DrawTextW(
                hdc,
                link.label.ptr,
                @intCast(link.label.len),
                &r,
                w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
            link_widths[i] = (r.right - r.left) + px(4, scale);
            links_h = @max(links_h, r.bottom - r.top);
        }
        if (n_links > 0) links_w = linkRowWidth(link_widths[0..n_links], link_gap);

        // Each column is as wide as its widest cell, so every label ends and
        // every value starts at one x. A value past the cap (a long install
        // path) scrolls inside its cell instead of pushing the dialog wider
        // than a screen. A few pixels of slack per value: the edit control
        // draws its caret one pixel past the last glyph.
        for (opts.rows[0..n_rows]) |row| {
            var lr: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = w32.DrawTextW(hdc, row.label.ptr, @intCast(row.label.len), &lr, w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
            var vr: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = w32.DrawTextW(hdc, row.value.ptr, @intCast(row.value.len), &vr, w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
            row_label_w = @max(row_label_w, lr.right - lr.left);
            row_value_w = @max(row_value_w, (vr.right - vr.left) + px(4, scale));
            row_h = @max(row_h, @max(lr.bottom - lr.top, vr.bottom - vr.top));
        }
        row_value_w = @min(row_value_w, px(max_row_value_dip, scale));
    }
    // The rows ride in the message's band: the message, a gap, then the
    // block, laid out as one content block so the icon centers against all
    // of it and nothing in `layoutFor` has to know rows exist.
    const msg_h = text_rect.bottom - text_rect.top;
    const row_col_gap = px(row_col_gap_dip, scale);
    const row_gap = px(row_gap_dip, scale);
    const rows_ext = rowsExtent(row_label_w, row_value_w, row_h, n_rows, row_col_gap, row_gap);
    const rows_span: i32 = if (rows_ext.h > 0) px(rows_gap_dip, scale) + rows_ext.h else 0;
    const l = layoutFor(
        scale,
        @max(text_rect.right - text_rect.left, rows_ext.w),
        msg_h + rows_span,
        has_icon,
        notes_h,
        n_checks,
        note_h,
        links_w,
        links_h,
        has_input,
        has_cancel,
        has_alt,
        buttonWidth(scale, label_w),
    );

    // Outer size from the desired client size, centered on the owner (or
    // the primary screen when there is no owner window).
    var frame: w32.RECT = .{ .left = 0, .top = 0, .right = l.client_w, .bottom = l.client_h };
    _ = w32.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const outer_w = frame.right - frame.left;
    const outer_h = frame.bottom - frame.top;
    var center: w32.RECT = .{
        .left = 0,
        .top = 0,
        .right = w32.GetSystemMetrics(0), // SM_CXSCREEN
        .bottom = w32.GetSystemMetrics(1), // SM_CYSCREEN
    };
    if (owner) |o| _ = w32.GetWindowRect(o, &center);
    const x = center.left + @divTrunc((center.right - center.left) - outer_w, 2);
    const y = center.top + @divTrunc((center.bottom - center.top) - outer_h, 2);

    // The dialog lives entirely on this stack frame — show() does not
    // return until the nested loop finishes, so no allocation is needed.
    var self: ConfirmDialog = .{
        .app = app,
        .hwnd = undefined,
        .static = null,
        .ok_btn = undefined,
        .cancel_btn = null,
        .icon_handle = switch (opts.icon) {
            .none => null,
            .warning => w32.LoadIconW(null, w32.IDI_WARNING),
            .info => w32.LoadIconW(null, w32.IDI_INFORMATION),
        },
        .icon_rect = l.icon,
        // A prompt's Enter must commit what was typed, so a field forces the
        // Enter default onto OK regardless of the caller's MB_DEFBUTTON2
        // preference (which exists to protect destructive confirmations).
        // A third button that claims the Enter default takes it from BOTH the
        // other two, so the two flags can never disagree about who is default.
        .default_cancel = has_cancel and opts.default_cancel and !has_input and
            !(has_alt and opts.default_alt),
        .default_alt = has_alt and opts.default_alt and !has_input,
    };

    const hwnd = w32.CreateWindowExW(
        ex_style,
        CLASS_NAME,
        opts.title,
        style,
        x,
        y,
        outer_w,
        outer_h,
        owner,
        null,
        hinstance,
        null,
    ) orelse return fallback(owner, opts);
    self.hwnd = hwnd;

    // The caption follows the same surface the body does (T563).
    system_colors.applyPanelChrome(hwnd, self.pal());

    // Message text.
    self.static = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        opts.text.ptr,
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_NOPREFIX,
        l.text.left,
        l.text.top,
        l.text.right - l.text.left,
        // The message alone; the rows take the rest of the band.
        msg_h,
        hwnd,
        null,
        hinstance,
        null,
    );

    // Optional labelled rows (T1556). A failed create drops that cell, never
    // the dialog: the facts are still worth showing in the cells that made it.
    for (opts.rows[0..n_rows], 0..) |row, i| {
        const rr = rowRects(
            l.text.left,
            l.text.top + msg_h + px(rows_gap_dip, scale),
            row_label_w,
            row_value_w,
            row_h,
            row_col_gap,
            row_gap,
            i,
        );
        self.row_labels[i] = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            row.label.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_NOPREFIX | w32.SS_RIGHT,
            rr.label.left,
            rr.label.top,
            rr.label.right - rr.label.left,
            rr.label.bottom - rr.label.top,
            hwnd,
            null,
            hinstance,
            null,
        );
        // A read-only EDIT, not a STATIC: Mac's rows are selectable, and a
        // commit sha or an install path is exactly what someone copies out of
        // an About box. No border and no margins, so its text sits where the
        // measurement put it. Not a Tab stop - the rows are facts, not
        // controls, and the focus cycle stays links + buttons.
        self.row_values[i] = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
            row.value.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_READONLY | w32.ES_AUTOHSCROLL,
            rr.value.left,
            rr.value.top,
            rr.value.right - rr.value.left,
            rr.value.bottom - rr.value.top,
            hwnd,
            null,
            hinstance,
            null,
        );
    }
    self.n_rows = n_rows;

    // Optional checkbox rows (Mac's accessory checkboxes, T870).
    // BS_AUTOCHECKBOX toggles itself on click and Space, so no WM_COMMAND
    // handling is needed; the state is read back after the modal loop.
    for (opts.checks[0..n_checks], 0..) |check, i| {
        const r = l.checks[i];
        const btn = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
            check.label.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.BS_AUTOCHECKBOX,
            r.left,
            r.top,
            r.right - r.left,
            r.bottom - r.top,
            hwnd,
            @ptrFromInt(100 + i),
            hinstance,
            null,
        ) orelse continue;
        system_colors.applyControlTheme(btn, self.pal());
        _ = w32.SendMessageW(btn, w32.BM_SETCHECK, if (check.checked) w32.BST_CHECKED else 0, 0);
        // Indexed like opts.checks (a failed create leaves a null hole), so
        // the readback below can never write one row's state into another.
        self.check_btns[i] = btn;
    }
    self.n_checks = n_checks;

    // Optional secondary note (Mac's wrapping caption label, T600).
    if (opts.note) |note_text| {
        self.note_static = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            note_text.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_NOPREFIX,
            l.note.left,
            l.note.top,
            l.note.right - l.note.left,
            l.note.bottom - l.note.top,
            hwnd,
            null,
            hinstance,
            null,
        );
    }

    // Optional link row (T714). The SysLink class is not registered until
    // something asks for it, and a create against an unregistered class fails
    // silently — so the ICC bit is claimed here rather than at startup, beside
    // the only control in this app that needs it.
    if (n_links > 0) {
        const icc = w32.INITCOMMONCONTROLSEX{
            .dwSize = @sizeOf(w32.INITCOMMONCONTROLSEX),
            .dwICC = w32.ICC_LINK_CLASS,
        };
        _ = w32.InitCommonControlsEx(&icc);
        var rects: [max_links]w32.RECT = undefined;
        const slots = packLinks(l.links, link_widths[0..n_links], link_gap, &rects);
        self.links = opts.links[0..n_links];
        for (opts.links[0..n_links], slots, 0..) |link, r, i| {
            var markup_buf: [128]u16 = undefined;
            const markup = linkAnchor(link.label, &markup_buf) orelse {
                log.warn("confirm dialog: link {d} has a label the control cannot carry", .{i});
                continue;
            };
            // A failed create is NOT fatal: the dialog still says what it
            // says, which is what it did before it had links at all.
            self.link_ctls[i] = w32.CreateWindowExW(
                0,
                w32.WC_LINK,
                markup.ptr,
                w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.WS_TABSTOP,
                r.left,
                r.top,
                r.right - r.left,
                r.bottom - r.top,
                hwnd,
                @ptrFromInt(@as(usize, ID_LINK_BASE) + i),
                hinstance,
                null,
            ) orelse {
                log.warn("confirm dialog: link {d} could not be created", .{i});
                continue;
            };
        }
    }

    // Optional release-notes accessory (T625). A failed create is not fatal:
    // the confirmation still asks its question, which is the part that must
    // never be lost.
    if (notes_h > 0) {
        if (opts.notes) |n| {
            self.notes_view = WhatsNewNotesView.create(
                app.?.core_app.alloc,
                app,
                hinstance,
                hwnd,
                l.notes,
                scale,
                n.split,
            );
            if (self.notes_view == null) {
                log.warn("confirm dialog: the release-notes accessory could not be created", .{});
            }
        }
    }

    // Optional text field (Mac's accessoryView).
    if (opts.input) |initial| {
        self.edit = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
            initial.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
            l.input.left,
            l.input.top,
            l.input.right - l.input.left,
            l.input.bottom - l.input.top,
            hwnd,
            null,
            hinstance,
            null,
        );
        if (self.edit) |e| {
            system_colors.applyControlTheme(e, self.pal());
        }
    }

    self.ok_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        opts.ok_label.ptr,
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE |
            (if (self.default_cancel or self.default_alt) 0 else w32.BS_DEFPUSHBUTTON),
        l.ok.left,
        l.ok.top,
        l.ok.right - l.ok.left,
        l.ok.bottom - l.ok.top,
        hwnd,
        @ptrFromInt(@as(usize, @intCast(w32.IDOK))),
        hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        return fallback(owner, opts);
    };
    system_colors.applyControlTheme(self.ok_btn, self.pal());

    if (has_cancel) {
        const cancel_btn = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
            opts.cancel_label.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE |
                (if (self.default_cancel) w32.BS_DEFPUSHBUTTON else 0),
            l.cancel.left,
            l.cancel.top,
            l.cancel.right - l.cancel.left,
            l.cancel.bottom - l.cancel.top,
            hwnd,
            @ptrFromInt(@as(usize, @intCast(w32.IDCANCEL))),
            hinstance,
            null,
        ) orelse {
            _ = w32.DestroyWindow(hwnd);
            return fallback(owner, opts);
        };
        system_colors.applyControlTheme(cancel_btn, self.pal());
        self.cancel_btn = cancel_btn;
    }

    // The optional third button (T1390). A failed create is NOT fatal the way
    // a missing OK is: the dialog still answers Close/Cancel, which is exactly
    // what it did before this button existed.
    if (has_alt) {
        if (w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
            opts.alt_label.?.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE |
                (if (self.default_alt) w32.BS_DEFPUSHBUTTON else 0),
            l.alt.left,
            l.alt.top,
            l.alt.right - l.alt.left,
            l.alt.bottom - l.alt.top,
            hwnd,
            @ptrFromInt(@as(usize, ID_ALT)),
            hinstance,
            null,
        )) |alt_btn| {
            system_colors.applyControlTheme(alt_btn, self.pal());
            self.alt_btn = alt_btn;
        } else {
            // Nothing can answer `.alt` any more, so the Enter default must go
            // back to a button that exists — the same one a caller who never
            // asked for a third button would have got.
            self.default_alt = false;
            self.default_cancel = has_cancel and opts.default_cancel and !has_input;
        }
    }

    if (note_font) |f| {
        if (self.note_static) |s| _ = w32.SendMessageW(s, w32.WM_SETFONT, @intFromPtr(f), 1);
    }
    if (font) |f| {
        if (self.static) |s| _ = w32.SendMessageW(s, w32.WM_SETFONT, @intFromPtr(f), 1);
        for (self.row_labels[0..self.n_rows], self.row_values[0..self.n_rows]) |ml, mv| {
            if (ml) |h| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
            if (mv) |h| {
                _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
                // After the font: EM_SETMARGINS is measured in the font it has.
                _ = w32.SendMessageW(h, w32.EM_SETMARGINS, w32.EC_LEFTMARGIN | w32.EC_RIGHTMARGIN, 0);
            }
        }
        for (self.link_ctls[0..self.links.len]) |maybe| if (maybe) |lc| {
            _ = w32.SendMessageW(lc, w32.WM_SETFONT, @intFromPtr(f), 1);
        };
        if (self.edit) |e| _ = w32.SendMessageW(e, w32.WM_SETFONT, @intFromPtr(f), 1);
        for (self.check_btns[0..self.n_checks]) |maybe| if (maybe) |b| {
            _ = w32.SendMessageW(b, w32.WM_SETFONT, @intFromPtr(f), 1);
        };
        _ = w32.SendMessageW(self.ok_btn, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.cancel_btn) |c| _ = w32.SendMessageW(c, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.alt_btn) |a| _ = w32.SendMessageW(a, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(&self)));

    // Input-modal to the owner until the dialog closes.
    if (owner) |o| _ = w32.EnableWindow(o, 0);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    if (opts.timeout_ms) |ms| _ = w32.SetTimer(hwnd, TIMEOUT_TIMER_ID, ms, null);
    if (self.edit) |e| {
        // The field takes focus with its seed text selected, so typing
        // replaces the old name (RenameDialog's behavior).
        _ = w32.SetFocus(e);
        _ = w32.SendMessageW(e, 0x00B1, 0, -1); // EM_SETSEL(0, -1)
    } else {
        _ = w32.SetFocus(self.defaultButton());
    }

    var registered: open_dialogs.Node = .{
        .owner = if (owner) |o| @intFromPtr(o) else 0,
        .ctx = &self,
        .dismiss = dismissFromRegistry,
    };
    ConfirmDialog.open_stack.push(&registered);
    self.runModal();
    ConfirmDialog.open_stack.remove(&registered);

    // Read the field and checkbox states BEFORE the window is destroyed.
    if (out) |o| if (self.edit) |e| {
        if (self.result == .ok) o.len = readEdit(e, o.buf);
    };
    if (self.result == .ok) {
        for (opts.checks[0..self.n_checks], 0..) |*check, i| {
            if (self.check_btns[i]) |b| {
                check.checked =
                    w32.SendMessageW(b, w32.BM_GETCHECK, 0, 0) == @as(isize, @intCast(w32.BST_CHECKED));
            }
        }
    }

    // Teardown. The accessory goes first: it is a child of this window, and
    // its own destroy path clears the back-pointer its WndProc reads.
    if (self.notes_view) |v| {
        v.destroy();
        self.notes_view = null;
    }
    // The owner MUST be re-enabled before the dialog is destroyed, otherwise
    // Windows may activate another app's window.
    if (owner) |o| _ = w32.EnableWindow(o, 1);
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(hwnd);
    if (owner) |o| _ = w32.SetForegroundWindow(o);
    if (refocus) |h| App.deferSetFocus(h); // T48

    return self.result;
}

/// Copy the edit control's text into `buf` as UTF-8, returning its length
/// (0 when it does not fit — a truncated device name is worse than none).
///
/// T990: `std.unicode.utf16LeToUtf8` never checked `buf`, so "does not fit"
/// was a panic rather than the 0 this comment promised. `toUtf8AllOrNothing`
/// is that promise, kept.
pub fn readEdit(edit: w32.HWND, buf: []u8) usize {
    var wbuf: [512]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, wbuf.len));
    return utf16_text.toUtf8AllOrNothing(buf, wbuf[0..wlen]);
}

/// Last-resort fallback when dialog construction fails: the old (light)
/// MessageBoxW, so a prompt is never silently skipped.
pub fn fallback(owner: ?w32.HWND, opts: Options) Result {
    // A three-answer confirmation has no OK/Cancel shape, so the system box
    // borrows Yes/No/Cancel: Yes is the third button, No is OK. MessageBoxW
    // cannot be relabeled, so the captions are lost — acceptable only because
    // this path is reached when the dialog CLASS failed to register, i.e. a
    // degraded box beats no box. Answering it can never be worse than the
    // dismissive default, which Cancel still is.
    const alt = if (opts.style == .ok_cancel) opts.alt_label else null;
    var flags: u32 = if (alt != null) w32.MB_YESNOCANCEL else switch (opts.style) {
        .ok_only => w32.MB_OK,
        .ok_cancel => w32.MB_OKCANCEL,
    };
    flags |= switch (opts.icon) {
        .none => 0,
        .warning => w32.MB_ICONWARNING,
        .info => w32.MB_ICONINFORMATION,
    };
    if (alt != null) {
        // Yes(1) is the third button, No(2) is OK, Cancel(3) is Cancel — so an
        // alt-default box needs no override and the other two name their slot.
        if (!opts.default_alt) flags |= if (opts.default_cancel) w32.MB_DEFBUTTON3 else w32.MB_DEFBUTTON2;
    } else if (opts.style == .ok_cancel and opts.default_cancel) {
        flags |= w32.MB_DEFBUTTON2;
    }
    var buf: [2048]u16 = undefined;
    const text_ptr: [*:0]const u16 = if (fallbackText(&buf, opts.text, opts.rows, opts.note)) |t| t.ptr else opts.text.ptr;
    const r = w32.MessageBoxW(owner, text_ptr, opts.title, flags);
    if (alt != null) {
        if (r == w32.IDYES) return .alt;
        return if (r == w32.IDNO) .ok else .cancel;
    }
    return if (opts.style == .ok_only or r == w32.IDOK) .ok else .cancel;
}
