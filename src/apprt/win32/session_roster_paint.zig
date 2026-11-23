//! The session roster's painting plane (split out of `SessionRoster.zig` by
//! T1783): the column header, each session card with its action button, CPU
//! meter and kill control, and the GDI text helpers they draw with.

const SessionRoster = @import("SessionRoster.zig");

const std = @import("std");
const builtin = @import("builtin");
const App = @import("App.zig");
const Window = @import("Window.zig");
const chooser_cpu = @import("chooser_cpu.zig");
const chooser_layout = @import("chooser_layout.zig");
const chooser_session_sort = @import("chooser_session_sort.zig");
const chooser_sessions = @import("chooser_sessions.zig");
const chrome_theme = @import("chrome_theme.zig");
const icon_button = @import("icon_button.zig");
const layout_blobs = @import("layout_blobs.zig");
const LocalAgent = @import("LocalAgent.zig");
const machine_pool = @import("machine_pool.zig");
const MachineConnectionPool = @import("MachineConnectionPool.zig");
const session_layout = @import("session_layout.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const remote_connection = @import("../../remote/connection.zig");
const w32 = @import("win32.zig");
const input_plane = @import("session_roster_input.zig");
const rows_plane = @import("session_roster_rows.zig");

const VisibleRow = SessionRoster.VisibleRow;

// ---------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------

/// What the roster needs from the chooser to draw itself: the region, the
/// surface it composites on, and the two fonts it uses. Passed rather than
/// imported so this file never reaches back into the dialog.
pub const PaintCtx = struct {
    hdc: w32.HDC,
    region: chooser_layout.Rect,
    /// The column-header line above the region (T602), from
    /// `Layout.session_header`. Drawn only when there are rows — headers over
    /// "No active sessions" are furniture.
    header: chooser_layout.Rect,
    scale: f32,
    bg: chooser_sessions.Rgb,
    /// The user's accent, already floored against `bg` by the caller — the same
    /// value the machine list's selected pill is painted with, so the keyboard
    /// cursor reads as the same selection (T320).
    accent: chooser_sessions.Rgb,
    /// Body semibold — the session's name.
    label_font: ?*anyopaque,
    /// Caption — the sublines and the badges.
    caption_font: ?*anyopaque,
};

pub fn rgb(c: chooser_sessions.Rgb) u32 {
    return w32.RGB(c.r, c.g, c.b);
}

pub fn rect(r: chooser_layout.Rect) w32.RECT {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

/// Total height of the roster's cards at `scale`, for the scroll clamp.
pub fn contentHeight(rows: []const VisibleRow, scale: f32) i32 {
    const m = chooser_sessions.metrics(scale);
    var h: i32 = 0;
    for (rows, 0..) |row, i| {
        if (i > 0) h += m.row_gap;
        h += chooser_sessions.rowHeight(m, chooser_sessions.sublineCount(row.session));
    }
    return h;
}

/// Paint the region. Loading / failed / empty are single centered lines; a
/// loaded roster is a stack of cards clipped to the region and offset by the
/// scroll.
pub fn paint(self: *const SessionRoster, ctx: PaintCtx, rows: []const VisibleRow) void {
    const hdc = ctx.hdc;
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    if (self.target == .none) return;

    if (self.state != .loaded or rows.len == 0) {
        const text = chooser_sessions.stateText(self.state) orelse chooser_sessions.empty_text;
        var r = rect(ctx.region);
        const old = if (ctx.caption_font) |f| w32.SelectObject(hdc, f) else null;
        _ = w32.SetTextColor(hdc, rgb(chrome_theme.textSecondaryOn(ctx.bg)));
        var wbuf: [128]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return;
        _ = w32.DrawTextW(
            hdc,
            &wbuf,
            @intCast(wlen),
            &r,
            w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
        if (old) |o| _ = w32.SelectObject(hdc, o);
        return;
    }

    // The clickable column headers (T602), OUTSIDE the clipped scroll region
    // so they stay put while the rows move under them.
    self.paintHeader(ctx);

    const m = chooser_sessions.metrics(ctx.scale);
    // Clip to the region so a card that runs past the bottom is cut, not drawn
    // over the footer.
    _ = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, -1);
    _ = w32.IntersectClipRect(
        hdc,
        ctx.region.left,
        ctx.region.top,
        ctx.region.right,
        ctx.region.bottom,
    );

    const cursor = self.cursorId();
    var y = ctx.region.top - self.scroll;
    for (rows, 0..) |row, i| {
        const subs = chooser_sessions.sublineCount(row.session);
        const l = self.layoutRow(m, ctx.region.left, y, ctx.region.width(), subs);
        y = l.card.bottom + m.row_gap;
        // Fully above or below the region: nothing to draw.
        if (l.card.bottom <= ctx.region.top or l.card.top >= ctx.region.bottom) continue;
        const cursored = if (cursor) |id| std.mem.eql(u8, row.session.id, id) else false;
        self.paintRow(ctx, m, l, row, @intCast(i), cursored);
    }
}

/// The column zones the header's labels sit over — the row's OWN column
/// widths, lifted onto the header line, so the headers ride the strip the CPU
/// meters were deliberately aligned into rather than introducing a second,
/// competing grid. Shared by the paint and the click hit-test, so the label
/// the user reads and the zone that answers the click cannot drift.
pub const HeaderZones = struct {
    /// Null when the machine's agent cannot serve the CPU stream — no meter
    /// column, no CPU header, and nothing to sort that would not read 0%.
    cpu: ?chooser_layout.Rect,
    name: chooser_layout.Rect,
};

pub fn headerZones(
    self: *const SessionRoster,
    header: chooser_layout.Rect,
    scale: f32,
) HeaderZones {
    const m = chooser_sessions.metrics(scale);
    const l = self.layoutRow(m, header.left, header.top, header.width(), 0);
    return .{
        .cpu = if (self.cpu_column) .{
            .left = l.cpu.left,
            .top = header.top,
            .right = l.cpu.right,
            .bottom = header.bottom,
        } else null,
        .name = .{
            .left = l.title.left,
            .top = header.top,
            .right = l.title.right,
            .bottom = header.bottom,
        },
    };
}

/// The sortable column under a client point in the header line, or null. Only
/// answers while there are rows on screen — the same condition the paint draws
/// the headers under, so a click can never land on furniture.
pub fn headerKeyAt(
    self: *const SessionRoster,
    rows: []const VisibleRow,
    header: chooser_layout.Rect,
    scale: f32,
    x: i32,
    y: i32,
) ?chooser_session_sort.Key {
    if (self.state != .loaded or rows.len == 0) return null;
    if (y < header.top or y >= header.bottom) return null;
    const zones = self.headerZones(header, scale);
    if (zones.cpu) |z| {
        if (z.left <= x and x < z.right) return .cpu;
    }
    if (zones.name.left <= x and x < zones.name.right) return .name;
    return null;
}

/// The header line: CPU and Name over their columns, a chevron on the ACTIVE
/// column naming its direction — drawn, not implied, so the sort is never
/// signalled by row order alone (§2.4).
pub fn paintHeader(self: *const SessionRoster, ctx: PaintCtx) void {
    const hdc = ctx.hdc;
    const zones = self.headerZones(ctx.header, ctx.scale);
    const m = chooser_sessions.metrics(ctx.scale);

    const old = if (ctx.caption_font) |f| w32.SelectObject(hdc, f) else null;
    defer if (old) |o| {
        _ = w32.SelectObject(hdc, o);
    };

    const entries = [_]struct { key: chooser_session_sort.Key, zone: ?chooser_layout.Rect }{
        .{ .key = .cpu, .zone = zones.cpu },
        .{ .key = .name, .zone = zones.name },
    };
    for (entries) |e| {
        const zone = e.zone orelse continue;
        const active = self.sort.key == e.key;
        const ink = if (active)
            chrome_theme.textOn(ctx.bg)
        else
            chrome_theme.textSecondaryOn(ctx.bg);
        _ = w32.SetTextColor(hdc, rgb(ink));
        const title = e.key.columnTitle();
        var r = rect(zone);
        drawText(hdc, title, &r);
        if (!active) continue;

        // The chevron marks the active column, tight after its measured label
        // (a width from text metrics is measured, never re-derived).
        const label_w = @min(measure(hdc, title), zone.width());
        const cw = @divTrunc(m.dot_d * 3, 4);
        const ch = @divTrunc(cw, 2);
        const cx = @min(zone.left + label_w + m.badge_gap, zone.right - cw);
        const cy = zone.top + @divTrunc(zone.height() - ch, 2);
        drawChevron(hdc, cx, cy, cw, ch, self.sort.ascending, ink);
    }
}

/// A filled triangle pointing up (ascending) or down — quads via `Polygon`,
/// never `LineTo` pen strokes (§4.2).
pub fn drawChevron(
    hdc: w32.HDC,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    ascending: bool,
    ink: chooser_sessions.Rgb,
) void {
    const brush = w32.CreateSolidBrush(rgb(ink)) orelse return;
    defer _ = w32.DeleteObject(brush);
    const old_brush = w32.SelectObject(hdc, brush);
    const old_pen = w32.SelectObject(hdc, w32.GetStockObject(w32.NULL_PEN));
    // `Polygon` excludes the pen-less boundary, so the far edges are grown by
    // one pixel to land the intended coverage.
    var pts = if (ascending) [3]w32.POINT{
        .{ .x = x, .y = y + h + 1 },
        .{ .x = x + w + 1, .y = y + h + 1 },
        .{ .x = x + @divTrunc(w, 2), .y = y },
    } else [3]w32.POINT{
        .{ .x = x, .y = y },
        .{ .x = x + w + 1, .y = y },
        .{ .x = x + @divTrunc(w, 2), .y = y + h + 1 },
    };
    _ = w32.Polygon(hdc, &pts, 3);
    _ = w32.SelectObject(hdc, old_pen);
    _ = w32.SelectObject(hdc, old_brush);
}

pub fn paintRow(
    self: *const SessionRoster,
    ctx: PaintCtx,
    m: chooser_sessions.Metrics,
    l: chooser_sessions.RowLayout,
    row: VisibleRow,
    index: i32,
    cursored: bool,
) void {
    const hdc = ctx.hdc;
    const hovered = self.hover_kill == index;
    // Everything on the card composites against the card's OWN surface, so a
    // cursored card's text and badges are floored against the accent wash they
    // actually sit on rather than against the plain card (the T206 rule).
    const card_bg = if (cursored)
        chooser_sessions.cursorFill(ctx.bg)
    else
        chooser_sessions.cardFill(ctx.bg);

    // The card, plus the cursor's accent indicator bar — the mark is never fill
    // alone, so the cursor survives a low-contrast accent and a color-blind
    // reading (§2.4). The bar replaced a full-perimeter accent stroke in T828:
    // one accent mark per surface, the same one the machine list draws.
    fillRound(hdc, l.card, m.radius, card_bg);
    if (cursored) {
        fillRound(
            hdc,
            chooser_sessions.cursorIndicatorRect(l.card, m),
            m.indicator_radius,
            chooser_sessions.cursorIndicator(card_bg, ctx.accent),
        );
    }

    // Liveness: filled dot when alive, hollow ring for a tombstone — shape as
    // well as color, so the state survives a color-blind reading (§2.4).
    const dot_ink = chooser_sessions.dotInk(card_bg, row.session.alive);
    drawDot(hdc, l.dot, dot_ink, row.session.alive);

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    // The CPU meter, in the column the row already reserved for it (T462). Only
    // a row with a READING draws one: a dead session has no process tree to roll
    // up, and drawing 0% for it would be indistinguishable from an idle live one.
    if (l.cpu.width() > 0) {
        if (row.cpu) |pct| drawCpuMeter(hdc, ctx, l.cpu, pct, card_bg);
    }

    // The label, then the badge run packed after its MEASURED width (a width
    // that comes from text metrics is measured, never re-derived).
    var lbuf: [chooser_sessions.max_live_title]u8 = undefined;
    const text = chooser_sessions.label(&lbuf, row.session, row.live, row.persisted_title);

    const old_label = if (ctx.label_font) |f| w32.SelectObject(hdc, f) else null;
    _ = w32.SetTextColor(hdc, rgb(chrome_theme.textOn(card_bg)));

    // Room for 2 (T1364): liveness and openness. The third slot was T466's
    // `can relaunch`, which went out with the dead rows that wore it.
    var badge_buf: [2]chooser_sessions.Badge = undefined;
    var exit_buf: [32]u8 = undefined;
    const run = chooser_sessions.badges(&badge_buf, &exit_buf, row.session, row.open_locally, row.orphan);

    // Reserve the badges' width so a long name ellipsizes instead of pushing
    // them out of the card.
    var badges_w: i32 = 0;
    if (run.len > 0) {
        const old_caption = if (ctx.caption_font) |f| w32.SelectObject(hdc, f) else null;
        for (run) |b| badges_w += measure(hdc, b.text) + m.badge_pad_x * 2 + m.badge_gap;
        if (old_caption) |o| _ = w32.SelectObject(hdc, o);
    }

    var title_rect = rect(l.title);
    title_rect.right = @max(title_rect.right - badges_w, title_rect.left);
    const title_w = @min(measure(hdc, text), title_rect.right - title_rect.left);
    drawText(hdc, text, &title_rect);
    if (old_label) |o| _ = w32.SelectObject(hdc, o);

    if (run.len > 0) {
        const old_caption = if (ctx.caption_font) |f| w32.SelectObject(hdc, f) else null;
        var bx = l.title.left + title_w + m.badge_gap;
        for (run) |b| {
            const w = measure(hdc, b.text);
            const box = chooser_sessions.badgeBox(m, bx, l.title, w);
            if (box.right > l.title.right) break;
            fillRound(hdc, box, m.badge_radius, chooser_sessions.badgeFill(card_bg, b.tone));
            var br = rect(box);
            _ = w32.SetTextColor(hdc, rgb(chooser_sessions.badgeInk(card_bg, b.tone)));
            drawTextCentered(hdc, b.text, &br);
            bx = box.right + m.badge_gap;
        }
        if (old_caption) |o| _ = w32.SelectObject(hdc, o);
    }

    // Sublines: cwd first (head-truncated, like Mac — the tail of a path is
    // what identifies it), then the command — what is running now, else what
    // the session was opened with (T1359).
    const old_sub = if (ctx.caption_font) |f| w32.SelectObject(hdc, f) else null;
    _ = w32.SetTextColor(hdc, rgb(chrome_theme.textSecondaryOn(card_bg)));
    var line = l.cwd;
    if (row.session.cwd) |cwd| {
        if (cwd.len > 0) {
            var r = rect(line);
            drawTextPathEllipsis(hdc, cwd, &r);
            line = l.argv;
        }
    }
    if (chooser_sessions.command(row.session)) |cmd| {
        var r = rect(line);
        drawText(hdc, cmd, &r);
    }
    if (old_sub) |o| _ = w32.SelectObject(hdc, o);

    // Show / Resume (T1746), then Kill: Mac's trailing pair, in Mac's order.
    if (chooser_sessions.actionLabel(row.session, row.open_locally)) |verb| {
        if (l.action.width() > 0) drawAction(hdc, ctx, m, l.action, verb, self.hover_action == index, card_bg);
    }

    // Kill: the app's one icon button, lit on hover like every other.
    drawKill(hdc, ctx, m, l.kill, hovered, card_bg);
}

/// The row's Show / Resume button (T1746). A labeled button has to read as a
/// button at REST, where an icon button may sit bare: a word with no face is
/// indistinguishable from the text around it. So its rest face is the §2.2
/// hover shade of the card and its hover is the pressed shade - the same two
/// deltas every control uses, one step firmer each, never a different hue.
pub fn drawAction(
    hdc: w32.HDC,
    ctx: PaintCtx,
    m: chooser_sessions.Metrics,
    box: chooser_layout.Rect,
    verb: []const u8,
    hovered: bool,
    card_bg: chooser_sessions.Rgb,
) void {
    const dark = chrome_theme.textOn(card_bg).r > 0x80;
    const delta = icon_button.fillDelta(if (hovered) .pressed else .hover, dark);
    const face: chooser_sessions.Rgb = .{
        .r = icon_button.shadeChannel(card_bg.r, delta),
        .g = icon_button.shadeChannel(card_bg.g, delta),
        .b = icon_button.shadeChannel(card_bg.b, delta),
    };
    fillRound(hdc, box, m.action_radius, face);

    const old = if (ctx.caption_font) |f| w32.SelectObject(hdc, f) else null;
    defer if (old) |o| {
        _ = w32.SelectObject(hdc, o);
    };
    _ = w32.SetTextColor(hdc, rgb(chrome_theme.textOn(face)));
    var r = rect(box);
    drawTextCentered(hdc, verb, &r);
}

/// One session's CPU meter: a track, its filled prefix, and the number after it
/// (T462). Every number here comes from `chooser_cpu`, which is asserted at
/// 1.0/1.25/1.5/2.0 in the none lane — this function only turns rects into GDI
/// calls.
pub fn drawCpuMeter(
    hdc: w32.HDC,
    ctx: PaintCtx,
    col: chooser_layout.Rect,
    cpu_pct: f32,
    card_bg: chooser_sessions.Rgb,
) void {
    const m = chooser_cpu.metrics(ctx.scale);
    const l = chooser_cpu.meterLayout(m, .{
        .left = col.left,
        .top = col.top,
        .right = col.right,
        .bottom = col.bottom,
    }, cpu_pct);
    const ink = chooser_cpu.meterInk(card_bg, cpu_pct);

    fillRound(hdc, cpuRect(l.track), m.bar_radius, chooser_cpu.trackFill(card_bg));
    // A zero-width fill is not painted: `RoundRect` on an empty rect still
    // stamps a pixel, which would make 0% and 1% look the same.
    if (l.fill.width() > 0) fillRound(hdc, cpuRect(l.fill), m.bar_radius, ink);

    const old = if (ctx.caption_font) |f| w32.SelectObject(hdc, f) else null;
    _ = w32.SetTextColor(hdc, rgb(ink));
    var buf: [16]u8 = undefined;
    var r = rect(cpuRect(l.value));
    // Left-aligned and single-line, and NOT ellipsized: the slot is sized for
    // three digits, and a four-digit reading (ten fully busy cores in one
    // session) runs into its own slack rather than being cut to "16…".
    drawWith(hdc, chooser_cpu.formatPct(&buf, cpu_pct), &r, w32.DT_LEFT | w32.DT_SINGLELINE |
        w32.DT_VCENTER | w32.DT_NOPREFIX | w32.DT_NOCLIP);
    if (old) |o| _ = w32.SelectObject(hdc, o);
}

pub fn cpuRect(r: chooser_cpu.Rect) chooser_layout.Rect {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

pub fn drawKill(
    hdc: w32.HDC,
    ctx: PaintCtx,
    m: chooser_sessions.Metrics,
    box: chooser_layout.Rect,
    hovered: bool,
    card_bg: chooser_sessions.Rgb,
) void {
    _ = m;
    const im: icon_button.Metrics = .init(ctx.scale);
    if (hovered) {
        const dark = chrome_theme.textOn(card_bg).r > 0x80;
        const delta = icon_button.fillDelta(.hover, dark);
        const fill: chooser_sessions.Rgb = .{
            .r = icon_button.shadeChannel(card_bg.r, delta),
            .g = icon_button.shadeChannel(card_bg.g, delta),
            .b = icon_button.shadeChannel(card_bg.b, delta),
        };
        fillRound(hdc, .{
            .left = box.left + im.inset,
            .top = box.top + im.inset,
            .right = box.right - im.inset,
            .bottom = box.bottom - im.inset,
        }, im.corner_r, fill);
    }

    // A filled-quad "x" from the shared glyph module — never `LineTo` pen
    // strokes (§4.2: they drop the endpoint and bias wide pens to one side).
    var quads: [icon_button.max_quads]icon_button.Quad = undefined;
    const target = icon_button.glyphTarget(im, .{
        .left = box.left,
        .top = box.top,
        .right = box.right,
        .bottom = box.bottom,
    }, .close);
    const shapes = icon_button.glyphQuads(im, target, .close, &quads);
    const ink = if (hovered)
        chrome_theme.textOn(card_bg)
    else
        chrome_theme.textSecondaryOn(card_bg);
    const brush = w32.CreateSolidBrush(rgb(ink)) orelse return;
    defer _ = w32.DeleteObject(brush);
    const old = w32.SelectObject(hdc, brush);
    const pen = w32.GetStockObject(w32.NULL_PEN);
    const old_pen = w32.SelectObject(hdc, pen);
    for (shapes) |q| {
        var pts: [4]w32.POINT = undefined;
        // GDI's `Polygon` excludes the pen-less boundary, so each quad is
        // grown by one pixel on its far edges to land the same coverage the
        // pure module computed.
        for (q.pts, 0..) |p, i| pts[i] = .{ .x = p.x, .y = p.y };
        _ = w32.Polygon(hdc, &pts, 4);
    }
    _ = w32.SelectObject(hdc, old_pen);
    _ = w32.SelectObject(hdc, old);
}

pub fn fillRound(hdc: w32.HDC, r: chooser_layout.Rect, radius: i32, color: chooser_sessions.Rgb) void {
    const brush = w32.CreateSolidBrush(rgb(color)) orelse return;
    defer _ = w32.DeleteObject(brush);
    const pen = w32.CreatePen(w32.PS_SOLID, 1, rgb(color)) orelse return;
    defer _ = w32.DeleteObject(pen);
    const ob = w32.SelectObject(hdc, brush);
    const op = w32.SelectObject(hdc, pen);
    _ = w32.RoundRect(hdc, r.left, r.top, r.right, r.bottom, radius * 2, radius * 2);
    _ = w32.SelectObject(hdc, ob);
    _ = w32.SelectObject(hdc, op);
}


pub fn drawDot(hdc: w32.HDC, r: chooser_layout.Rect, color: chooser_sessions.Rgb, filled: bool) void {
    const pen = w32.CreatePen(w32.PS_SOLID, 1, rgb(color)) orelse return;
    defer _ = w32.DeleteObject(pen);
    const brush = if (filled) w32.CreateSolidBrush(rgb(color)) else null;
    defer if (brush) |b| {
        _ = w32.DeleteObject(b);
    };
    const op = w32.SelectObject(hdc, pen);
    const ob = w32.SelectObject(hdc, brush orelse w32.GetStockObject(w32.NULL_BRUSH));
    _ = w32.Ellipse(hdc, r.left, r.top, r.right, r.bottom);
    _ = w32.SelectObject(hdc, op);
    _ = w32.SelectObject(hdc, ob);
}

pub fn measure(hdc: w32.HDC, text: []const u8) i32 {
    var wbuf: [256]u16 = undefined;
    if (text.len > wbuf.len) return 0;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 0;
    var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
    if (w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size) == 0) return 0;
    return size.cx;
}

pub fn drawText(hdc: w32.HDC, text: []const u8, r: *w32.RECT) void {
    drawWith(hdc, text, r, w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_VCENTER |
        w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX);
}

/// A path ellipsizes in the MIDDLE: its tail is what identifies it, so
/// `DT_END_ELLIPSIS` would cut off the only part worth reading.
pub fn drawTextPathEllipsis(hdc: w32.HDC, text: []const u8, r: *w32.RECT) void {
    drawWith(hdc, text, r, w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_VCENTER |
        w32.DT_PATH_ELLIPSIS | w32.DT_NOPREFIX);
}

pub fn drawTextCentered(hdc: w32.HDC, text: []const u8, r: *w32.RECT) void {
    drawWith(hdc, text, r, w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_NOPREFIX);
}

pub fn drawWith(hdc: w32.HDC, text: []const u8, r: *w32.RECT, flags: u32) void {
    var wbuf: [512]u16 = undefined;
    const clipped = if (text.len > wbuf.len) text[0..wbuf.len] else text;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, clipped) catch return;
    _ = w32.DrawTextW(hdc, &wbuf, @intCast(wlen), r, flags);
}
