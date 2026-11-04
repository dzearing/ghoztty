//! Painting for Appearance's live preview (T2683; Mac `SettingsPreview`,
//! 9287de0ff). What it shows is `settings_preview.zig`'s; this file reads the
//! window's effective values into it and draws the card: the backdrop (the
//! window gradient in the elevated pane style, else the panel), the terminal
//! in the theme's background at the configured opacity, four lines in the
//! configured font, the cursor, and the corner caption.
//!
//! Like the window's other sections it both measures and paints (`draw`
//! false only measures), so layout and paint cannot drift.
const std = @import("std");

const SettingsWindow = @import("SettingsWindow.zig");
const layout = @import("settings_window_layout.zig");
const notes_render = @import("whats_new_notes.zig");
const panel_theme = @import("panel_theme.zig");
const preview = @import("settings_preview.zig");
const system_colors = @import("system_colors.zig");
const theme_catalog = @import("theme_catalog.zig");
const w32 = @import("win32.zig");

const Rect = layout.Rect;
const dip = layout.dip;
const Rgb = theme_catalog.Rgb;

/// The blink timer (the toast's is 1).
pub const blink_timer_id: usize = 2;

/// The monospaced face drawn when the configured one is not installed (Mac
/// `.system(design: .monospaced)`; Consolas ships with every Windows).
const fallback_face = "Consolas";
/// Where a character the terminal face lacks is drawn from (the prompt's
/// U+276F under Consolas) - GDI's TextOutW does not fall back on its own.
const symbol_face = "Segoe UI Symbol";

fn px(w: *const SettingsWindow, v: f64) i32 {
    return @intFromFloat(@round(v * w.scale));
}

fn colorref(c: Rgb) u32 {
    return w32.RGB(c.r, c.g, c.b);
}

fn fromPanel(c: panel_theme.Rgb) Rgb {
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

/// The preview's inputs from the window's effective values. A slider being
/// dragged previews its unwritten value (Mac: "slider drags preview here
/// before they're written"). Lists are allocated in `arena`.
pub fn inputs(w: *SettingsWindow, arena: std.mem.Allocator) preview.Inputs {
    const cat = w.themeCatalog();
    const dark = !system_colors.usesLightTheme();
    const r = w.reader() orelse return preview.resolve(.{}, cat, dark);
    const raw: preview.Raw = .{
        .theme = r.value("theme"),
        .background = r.value("background"),
        .foreground = r.value("foreground"),
        .palette = r.values(arena, "palette") catch &.{},
        .cursor_color = r.value("cursor-color"),
        .font_family = r.values(arena, "font-family") catch &.{},
        .font_size = r.value("font-size"),
        .font_feature = r.values(arena, "font-feature") catch &.{},
        .background_opacity = r.value("background-opacity"),
        .window_padding_x = r.value("window-padding-x"),
        .window_padding_y = r.value("window-padding-y"),
        .pane_style = r.value("macos-pane-style"),
        .cursor_style = r.value("cursor-style"),
        .cursor_style_blink = r.value("cursor-style-blink"),
        .cursor_opacity = r.value("cursor-opacity"),
    };
    var in = preview.resolve(raw, cat, dark);
    if (w.slide_key) |k| if (w.slide_preview) |v| {
        if (std.mem.eql(u8, k, "background-opacity")) in.opacity = std.math.clamp(v, 0, 1);
        if (std.mem.eql(u8, k, "cursor-opacity")) in.cursor_opacity = std.math.clamp(v, 0, 1);
    };
    return in;
}

/// Mac's window gradient at `f` (0 top-left .. 1 bottom-right): (0.36,0.55,
/// 0.84) to (0.25,0.71,0.69), the same bands the pane-style card paints.
fn gradientAt(f: f64) Rgb {
    const a = [3]f64{ 92, 140, 214 };
    const b = [3]f64{ 64, 181, 176 };
    const k = std.math.clamp(f, 0, 1);
    const mix = struct {
        fn c(x: f64, y: f64, t: f64) u8 {
            return @intFromFloat(@round(std.math.clamp(x + (y - x) * t, 0, 255)));
        }
    }.c;
    return .{ .r = mix(a[0], b[0], k), .g = mix(a[1], b[1], k), .b = mix(a[2], b[2], k) };
}

/// The backdrop's color at column `x` of `card`.
fn backdropAt(card: Rect, x: i32, elevated: bool, panel_bg: Rgb) Rgb {
    if (!elevated) return panel_bg;
    const span: f64 = @floatFromInt(@max(1, card.w + card.h));
    return gradientAt(@as(f64, @floatFromInt(x - card.x + @divTrunc(card.h, 2))) / span);
}

fn fill(hdc: w32.HDC, r: Rect, c: Rgb) void {
    notes_render.fillRect(hdc, r, colorref(c));
}

/// Narrow the clip to a rounded rect (inside whatever clip is in force).
fn clipRound(hdc: w32.HDC, r: Rect, radius: i32) void {
    const rgn = if (radius > 0)
        w32.CreateRoundRectRgn(r.x, r.y, r.x + r.w + 1, r.y + r.h + 1, radius * 2, radius * 2)
    else
        w32.CreateRectRgn(r.x, r.y, r.x + r.w, r.y + r.h);
    if (rgn) |g| {
        _ = w32.ExtSelectClipRgn(hdc, g, w32.RGN_AND);
        _ = w32.DeleteObject(g);
    }
}

/// The terminal font: the configured family when it is installed, else the
/// fallback. Writes the face GDI actually selected into `face`.
fn makeFont(hdc: w32.HDC, family: ?[]const u8, height: i32, face: *[64]u8, face_len: *usize) ?*anyopaque {
    const want = family orelse preview.default_family;
    var wbuf: [64:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wbuf[0..63], want) catch 0;
    wbuf[n] = 0;
    if (create(&wbuf, height)) |font| {
        if (selectedFaceIs(hdc, font, want, face, face_len)) return font;
        _ = w32.DeleteObject(font);
    }
    const fb = std.unicode.utf8ToUtf16LeStringLiteral(fallback_face);
    const font = create(fb, height) orelse return null;
    _ = selectedFaceIs(hdc, font, fallback_face, face, face_len);
    return font;
}

fn create(name: [*:0]const u16, height: i32) ?*anyopaque {
    // FIXED_PITCH | FF_MODERN, so a substitution stays monospaced.
    return w32.CreateFontW(-height, 0, 0, 0, w32.FW_NORMAL, 0, 0, 0, 1, 0, 0, 5, 0x01 | 0x30, name);
}

/// GDI substitutes silently for a family it lacks; the face it picked
/// answers whether the configured one is installed.
fn selectedFaceIs(hdc: w32.HDC, font: *anyopaque, want: []const u8, face: *[64]u8, face_len: *usize) bool {
    const prev = w32.SelectObject(hdc, font);
    defer _ = w32.SelectObject(hdc, prev);
    var got: [64]u16 = undefined;
    const len = w32.GetTextFaceW(hdc, got.len, &got);
    const used: usize = if (len > 0) @intCast(len - 1) else 0;
    const utf8_len = std.unicode.utf16LeToUtf8(face, got[0..@min(used, 32)]) catch 0;
    face_len.* = utf8_len;
    return std.ascii.eqlIgnoreCase(face[0..utf8_len], want);
}

/// True when the selected font has a glyph for every character of `text`.
fn hasGlyphs(hdc: w32.HDC, text: []const u16) bool {
    var ids: [128]u16 = undefined;
    const n = @min(text.len, ids.len);
    if (w32.GetGlyphIndicesW(hdc, text.ptr, @intCast(n), &ids, w32.GGI_MARK_NONEXISTING_GLYPHS) == 0xFFFFFFFF) return true;
    for (ids[0..n]) |id| if (id == 0xFFFF) return false;
    return true;
}

/// Draw `text` at x,y in the selected font - or in `symbols` when the font
/// lacks one of its characters; returns its width. `y` is the line's text
/// top; a symbol run sits on the same baseline.
fn run(hdc: w32.HDC, x: i32, y: i32, text: []const u8, color: Rgb, symbols: ?*anyopaque) i32 {
    var wbuf: [128]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 0;
    if (n == 0) return 0;
    var dy: i32 = 0;
    var prev: ?*anyopaque = null;
    if (symbols) |sf| if (!hasGlyphs(hdc, wbuf[0..n])) {
        var tm_main: w32.TEXTMETRICW = undefined;
        _ = w32.GetTextMetricsW(hdc, &tm_main);
        prev = w32.SelectObject(hdc, sf);
        var tm_sym: w32.TEXTMETRICW = undefined;
        _ = w32.GetTextMetricsW(hdc, &tm_sym);
        dy = tm_main.tmAscent - tm_sym.tmAscent;
    };
    defer if (prev) |p| {
        _ = w32.SelectObject(hdc, p);
    };
    var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(n), &size);
    _ = w32.SetTextColor(hdc, colorref(color));
    _ = w32.TextOutW(hdc, x, y + dy, &wbuf, @intCast(n));
    return size.cx;
}

/// Appearance's preview card. Returns its height.
pub fn paint(w: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, y: i32, draw: bool) i32 {
    const f = w.frame();
    const pad_y = layout.px(dip.row_pad_y, w.scale);
    const g = layout.px(dip.gap, w.scale);
    const card_h = px(w, preview.height_dip);
    const total = pad_y + card_h + pad_y + g;
    if (!draw) return total;

    var arena_state = std.heap.ArenaAllocator.init(w.gpa);
    defer arena_state.deinit();
    const in = inputs(w, arena_state.allocator());

    const cols = layout.rowColumns(w.scale, f.list, f.scrollbar.w, y + pad_y, card_h, dip.field_w);
    const card: Rect = .{ .x = cols.left, .y = y + pad_y, .w = cols.right - cols.left, .h = card_h };
    w.preview_rect = card;

    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    clipRound(hdc, card, px(w, preview.card_radius_dip));

    // The backdrop, in columns so the elevated gradient runs diagonally.
    const panel_bg = fromPanel(p.bg);
    const step: i32 = @max(1, w.hair());
    {
        var x = card.x;
        while (x < card.x + card.w) : (x += step) {
            fill(hdc, .{ .x = x, .y = card.y, .w = step, .h = card.h }, backdropAt(card, x, in.elevated, panel_bg));
        }
    }

    // The terminal: inset and raised in the elevated style.
    const inset = if (in.elevated) px(w, preview.elevated_inset_dip) else 0;
    const term: Rect = .{ .x = card.x + inset, .y = card.y + inset, .w = card.w - 2 * inset, .h = card.h - 2 * inset };
    const term_radius = if (in.elevated) px(w, preview.terminal_radius_dip) else 0;
    if (in.elevated) paintShadow(w, hdc, term, term_radius);
    {
        const inner = w32.SaveDC(hdc);
        defer _ = w32.RestoreDC(hdc, inner);
        clipRound(hdc, term, term_radius);
        var x = term.x;
        while (x < term.x + term.w) : (x += step) {
            const under = backdropAt(card, x, in.elevated, panel_bg);
            fill(hdc, .{ .x = x, .y = term.y, .w = step, .h = term.h }, preview.blend(in.background, under, in.opacity));
        }
        paintLines(w, hdc, term, &in, backdropAt(card, term.x + @divTrunc(term.w, 2), in.elevated, panel_bg));
    }
    paintCaption(w, hdc, card, &in, backdropAt(card, card.x + card.w, in.elevated, panel_bg));
    w.preview_painted_blink = in.blink;
    return total;
}

/// Mac's `.shadow(color: .black.opacity(0.28), radius: 12, y: 6)`: nested
/// rounded layers of translucent black, each darkening the backdrop already
/// painted, so the shadow is densest under the terminal and fades out over
/// its 12 DIP radius.
fn paintShadow(w: *SettingsWindow, hdc: w32.HDC, term: Rect, radius: i32) void {
    const src = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(src);
    const bmp = w32.CreateCompatibleBitmap(hdc, 1, 1) orelse return;
    defer _ = w32.DeleteObject(bmp);
    const old = w32.SelectObject(src, bmp);
    defer _ = w32.SelectObject(src, old);
    notes_render.fillRect(src, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, w32.RGB(0, 0, 0));

    const layers = 6;
    const dy = px(w, 6);
    const reach = px(w, 12);
    // Layers compound: each adds `a`, so the core reaches about 0.28.
    const a: f64 = 1.0 - std.math.pow(f64, 1.0 - 0.28, 1.0 / @as(f64, layers));
    var i: i32 = layers;
    while (i >= 1) : (i -= 1) {
        const grow = @divTrunc(reach * i, layers) - @divTrunc(reach, 2);
        const r: Rect = .{ .x = term.x - grow, .y = term.y + dy - grow, .w = term.w + 2 * grow, .h = term.h + 2 * grow };
        const saved = w32.SaveDC(hdc);
        defer _ = w32.RestoreDC(hdc, saved);
        clipRound(hdc, r, @max(0, radius + grow));
        _ = w32.AlphaBlend(hdc, r.x, r.y, r.w, r.h, src, 0, 0, 1, 1, .{
            .SourceConstantAlpha = @intFromFloat(@round(a * 255)),
            .AlphaFormat = 0,
        });
    }
}

fn paintLines(w: *SettingsWindow, hdc: w32.HDC, term: Rect, in: *const preview.Inputs, under: Rgb) void {
    const ts = in.textSize();
    const font_px = @max(1, px(w, ts));
    const font = makeFont(hdc, in.family, font_px, &w.preview_face, &w.preview_face_len) orelse return;
    defer _ = w32.DeleteObject(font);
    const symbols = create(std.unicode.utf8ToUtf16LeStringLiteral(symbol_face), font_px);
    defer if (symbols) |sf| {
        _ = w32.DeleteObject(sf);
    };
    const prev = w32.SelectObject(hdc, font);
    defer _ = w32.SelectObject(hdc, prev);
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    var tm_size: w32.SIZE = .{ .cx = 0, .cy = 0 };
    const probe = std.unicode.utf8ToUtf16LeStringLiteral("M");
    _ = w32.GetTextExtentPoint32W(hdc, probe, 1, &tm_size);
    const box = preview.cursorBox(in.cursor_style, ts);
    const line_h = @max(tm_size.cy, px(w, box.line_h));
    const gap = px(w, 1);

    const x0 = term.x + px(w, in.pad_x + preview.text_pad_x_dip);
    var cy = term.y + px(w, in.pad_y + preview.text_pad_y_dip);
    var cursor_x: i32 = x0;
    for (preview.sample, 0..) |spans, li| {
        var x = x0;
        const ty = cy + (line_h - tm_size.cy);
        for (spans) |s| {
            const color = if (s.ansi) |a| in.ansi(a) else in.foreground;
            x += run(hdc, x, ty, s.text, color, symbols);
        }
        if (li == preview.sample.len - 1) cursor_x = x;
        if (li < preview.sample.len - 1) cy += line_h + gap;
    }

    // The cursor on the prompt line's baseline box.
    if (!in.blink or w.preview_cursor_on) {
        const cw = @max(1, px(w, box.w));
        const ch = @max(1, px(w, box.h));
        const r: Rect = .{ .x = cursor_x, .y = cy + line_h - ch, .w = cw, .h = ch };
        const bg = preview.blend(in.background, under, in.opacity);
        const color = preview.blend(in.cursor, bg, in.cursor_opacity);
        if (box.hollow) {
            const t = @max(1, px(w, 1.5));
            fill(hdc, .{ .x = r.x, .y = r.y, .w = r.w, .h = t }, color);
            fill(hdc, .{ .x = r.x, .y = r.y + r.h - t, .w = r.w, .h = t }, color);
            fill(hdc, .{ .x = r.x, .y = r.y, .w = t, .h = r.h }, color);
            fill(hdc, .{ .x = r.x + r.w - t, .y = r.y, .w = t, .h = r.h }, color);
        } else fill(hdc, r, color);
        w.preview_cursor_rect = r;
    } else w.preview_cursor_rect = null;
}

/// The corner caption (Mac: caption2 on a 35% black capsule, 85% white).
fn paintCaption(w: *SettingsWindow, hdc: w32.HDC, card: Rect, in: *const preview.Inputs, backdrop: Rgb) void {
    var buf: [160]u8 = undefined;
    const text = preview.caption(&buf, in);
    const ch = w.text.lineHeight(.caption);
    const tw = w.text.measure(hdc, text, .{}, .caption).cx;
    const pad_x = px(w, 6);
    const pad_y = px(w, 2);
    const inset = px(w, if (in.elevated) preview.caption_inset_elevated_dip else preview.caption_inset_dip);
    const pill: Rect = .{
        .x = card.x + card.w - inset - tw - 2 * pad_x,
        .y = card.y + card.h - inset - ch - 2 * pad_y,
        .w = tw + 2 * pad_x,
        .h = ch + 2 * pad_y,
    };
    // Under the pill: the terminal (the elevated pill sits on it too).
    const under = preview.blend(in.background, backdrop, in.opacity);
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    const fill_c = preview.blend(black, under, 0.35);
    SettingsWindow.roundRect(hdc, pill, px(w, 5), colorref(fill_c), null, 1);
    _ = w.text.drawText(hdc, pill.x + pad_x, pill.y + pad_y, text, .{}, .caption, colorref(preview.blend(white, fill_c, 0.85)), true);
    w.preview_caption_len = @min(text.len, w.preview_caption.len);
    @memcpy(w.preview_caption[0..w.preview_caption_len], text[0..w.preview_caption_len]);
}

/// The blink timer's tick: flip the cursor and repaint the card. Stops
/// itself once the preview is no longer painted or no longer blinks.
pub fn tick(w: *SettingsWindow) void {
    if (w.preview_rect == null or !w.preview_painted_blink) {
        stopBlink(w);
        w.preview_cursor_on = true;
        return;
    }
    w.preview_cursor_on = !w.preview_cursor_on;
    const r = w.preview_rect.?;
    var rc: w32.RECT = .{ .left = r.x, .top = r.y, .right = r.x + r.w, .bottom = r.y + r.h };
    _ = w32.InvalidateRect(w.hwnd, &rc, 0);
}

/// After a paint: run the blink timer while a blinking preview is showing.
pub fn afterPaint(w: *SettingsWindow) void {
    const want = w.preview_rect != null and w.preview_painted_blink;
    if (want and !w.preview_blinking) {
        if (w32.SetTimer(w.hwnd, blink_timer_id, preview.blink_ms, null) != 0) w.preview_blinking = true;
    } else if (!want) {
        stopBlink(w);
        w.preview_cursor_on = true;
    }
}

fn stopBlink(w: *SettingsWindow) void {
    if (!w.preview_blinking) return;
    _ = w32.KillTimer(w.hwnd, blink_timer_id);
    w.preview_blinking = false;
}
