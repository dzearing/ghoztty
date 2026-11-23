const ConfirmDialog = @import("ConfirmDialog.zig");

const std = @import("std");
const App = @import("App.zig");
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
const confirm_dialog_window = @import("confirm_dialog_window.zig");

const max_checks = ConfirmDialog.max_checks;
const max_links = ConfirmDialog.max_links;
const max_rows = ConfirmDialog.max_rows;
const row_col_gap_dip = ConfirmDialog.row_col_gap_dip;
const row_gap_dip = ConfirmDialog.row_gap_dip;
const rows_gap_dip = ConfirmDialog.rows_gap_dip;
const testing = ConfirmDialog.testing;

/// Dialog layout in physical pixels, computed from the owner window's DPI
/// scale and the measured text extent. Pure — unit tested below.
pub const Layout = struct {
    client_w: i32,
    client_h: i32,
    icon: w32.RECT,
    text: w32.RECT,
    /// The optional text field, spanning the text column (empty rect when the
    /// dialog has no input).
    input: w32.RECT,
    /// The optional release-notes accessory (empty rect when the dialog has
    /// none). Sits directly under the message, because it is evidence FOR the
    /// message rather than a second question.
    notes: w32.RECT,
    /// The optional checkbox rows (only the first `n_checks` passed to
    /// `layoutFor` are meaningful; the rest stay empty).
    checks: [max_checks]w32.RECT,
    /// The optional secondary note under the check rows (empty rect when the
    /// dialog has none).
    note: w32.RECT,
    /// The optional link row (empty rect when the dialog has none). Below the
    /// fine print and above the buttons: links are where a reader goes NEXT,
    /// so they sit between what the dialog says and how it is dismissed.
    links: w32.RECT,
    ok: w32.RECT,
    cancel: w32.RECT,
    /// The optional third button (empty rect when the dialog has none).
    alt: w32.RECT,
    font_h: i32,
};

/// `btn_w` is the physical-pixel button width — at least the standard
/// 88 DIP, wider when a caption needs the room (see buttonWidth).
/// `has_input` adds a single-line field row under the message (T176);
/// `n_checks` adds that many checkbox rows between the message and the
/// field/buttons (T870); `note_h` (measured caption-text height, 0 for
/// none) adds the secondary note band under the checks (T600).
/// `notes_h` (0 for none) adds the fixed release-notes band under the message
/// (T625). `links_w`/`links_h` (both 0 for none) add the hyperlink row under
/// the fine print (T714) — measured by the caller, because the row must fit on
/// ONE line: a wrapped link row would report a height the layout never
/// reserved, and the dialog widens to hold it instead.
pub fn layoutFor(
    scale: f32,
    text_w: i32,
    text_h: i32,
    has_icon: bool,
    notes_h: i32,
    n_checks: usize,
    note_h: i32,
    links_w: i32,
    links_h: i32,
    has_input: bool,
    has_cancel: bool,
    has_alt: bool,
    btn_w: i32,
) Layout {
    const margin = px(16, scale);
    const icon_px = px(32, scale);
    const icon_gap = px(12, scale);
    const btn_h = px(28, scale);
    const btn_gap_h = px(8, scale);
    const btn_gap_v = px(18, scale);
    const input_h = px(26, scale);
    const input_gap = px(12, scale);
    const check_h = px(20, scale);
    const check_gap = px(12, scale);
    const check_row_gap = px(4, scale);
    const note_gap = px(12, scale);
    const notes_gap = px(12, scale);
    const links_gap = px(12, scale);

    const icon_span: i32 = if (has_icon) icon_px + icon_gap else 0;
    // `alt` only ever accompanies a Cancel: it is a second AFFIRMATIVE, and a
    // dialog offering two ways to say yes and no way to say no is not a choice.
    const with_alt = has_alt and has_cancel;
    const n_btns: i32 = (if (has_cancel) @as(i32, 2) else 1) + @intFromBool(with_alt);
    const btns_w = n_btns * btn_w + (n_btns - 1) * btn_gap_h;

    var client_w = margin + icon_span + text_w + margin;
    // Never narrower than the button row (or a sane floor). A prompt gets a
    // wider floor: a field the width of a two-word message is unusable.
    client_w = @max(client_w, margin + btns_w + margin);
    // A notes accessory gets the widest floor of the three: release notes are
    // prose in bulleted blocks, and prose wrapped to a two-word message's
    // width is a column of single words.
    client_w = @max(client_w, px(if (notes_h > 0) 460 else if (has_input) 380 else 280, scale));
    // The link row never wraps: it is a row of destinations, and a "GitHub"
    // that breaks across two lines is a defect, not a smaller dialog.
    if (links_h > 0) client_w = @max(client_w, margin + icon_span + links_w + margin);

    const content_h = @max(text_h, if (has_icon) icon_px else 0);
    const nc: i32 = @intCast(@min(n_checks, max_checks));
    const checks_span: i32 = if (nc > 0)
        check_gap + nc * check_h + (nc - 1) * check_row_gap
    else
        0;
    const note_span: i32 = if (note_h > 0) note_gap + note_h else 0;
    const links_span: i32 = if (links_h > 0) links_gap + links_h else 0;
    const input_span: i32 = if (has_input) input_gap + input_h else 0;
    const notes_span: i32 = if (notes_h > 0) notes_gap + notes_h else 0;
    const client_h = margin + content_h + notes_span + checks_span + note_span +
        links_span + input_span + btn_gap_v + btn_h + margin;

    // Vertically center the shorter of icon/text within the content band.
    const icon_top = margin + @divTrunc(content_h - icon_px, 2);
    const text_top = margin + @divTrunc(content_h - text_h, 2);

    var checks: [max_checks]w32.RECT = @splat(.{ .left = 0, .top = 0, .right = 0, .bottom = 0 });
    var i: i32 = 0;
    while (i < nc) : (i += 1) {
        const top = margin + content_h + notes_span + check_gap + i * (check_h + check_row_gap);
        checks[@intCast(i)] = .{
            .left = margin + icon_span,
            .top = top,
            .right = client_w - margin,
            .bottom = top + check_h,
        };
    }

    const notes_top = margin + content_h + notes_gap;
    const note_top = margin + content_h + notes_span + checks_span + note_gap;
    const links_top = margin + content_h + notes_span + checks_span + note_span + links_gap;
    const input_top = margin + content_h + notes_span + checks_span + note_span +
        links_span + input_gap;
    const btn_top = margin + content_h + notes_span + checks_span + note_span +
        links_span + input_span + btn_gap_v;
    const right_left = client_w - margin - btn_w;
    const left_left = right_left - btn_gap_h - btn_w;
    const far_left = left_left - btn_gap_h - btn_w;
    // With two buttons OK sits left of Cancel; alone, OK takes the right slot.
    // A third button takes the slot LEFT of OK, so the row reads
    // [alt] [ok] [cancel] with the dismissive answer last (T1390) — OK does not
    // move, which is why a two-button caller's layout is byte-identical.
    const ok_left = if (has_cancel) left_left else right_left;
    const alt_left = far_left;

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .icon = if (has_icon) .{
            .left = margin,
            .top = icon_top,
            .right = margin + icon_px,
            .bottom = icon_top + icon_px,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .text = .{
            .left = margin + icon_span,
            .top = text_top,
            .right = margin + icon_span + text_w,
            .bottom = text_top + text_h,
        },
        .input = if (has_input) .{
            .left = margin + icon_span,
            .top = input_top,
            // The field spans to the trailing margin, not to the message's
            // measured width — it is an entry box, not a caption.
            .right = client_w - margin,
            .bottom = input_top + input_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .notes = if (notes_h > 0) .{
            // The accessory spans the full text column to the trailing margin,
            // like the check rows and the fine print: it is a region, not a
            // paragraph aligned with the message.
            .left = margin + icon_span,
            .top = notes_top,
            .right = client_w - margin,
            .bottom = notes_top + notes_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .checks = checks,
        .note = if (note_h > 0) .{
            .left = margin + icon_span,
            .top = note_top,
            // Fine print spans the text column to the trailing margin, like
            // the check rows above it.
            .right = client_w - margin,
            .bottom = note_top + note_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .links = if (links_h > 0) .{
            .left = margin + icon_span,
            .top = links_top,
            .right = client_w - margin,
            .bottom = links_top + links_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .ok = .{ .left = ok_left, .top = btn_top, .right = ok_left + btn_w, .bottom = btn_top + btn_h },
        .alt = if (with_alt) .{
            .left = alt_left,
            .top = btn_top,
            .right = alt_left + btn_w,
            .bottom = btn_top + btn_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .cancel = if (has_cancel) .{
            .left = right_left,
            .top = btn_top,
            .right = right_left + btn_w,
            .bottom = btn_top + btn_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .font_h = type_ramp.body(scale).height,
    };
}

pub fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Wrap one label in the SysLink anchor markup (`<a>Docs</a>`) inside a
/// caller buffer. Pure — unit tested below.
///
/// Returns null rather than something approximate when the label carries a
/// markup character the control would reinterpret, or when the buffer is too
/// small. That link is then simply not shown: a dialog missing a link still
/// says what it says, while a label whose `&` silently ate the next character
/// is a defect nobody would think to look for.
pub fn linkAnchor(label: []const u16, out: []u16) ?[:0]const u16 {
    const open = "<a>";
    const close = "</a>";
    for (label) |c| if (c == '<' or c == '>' or c == '&') return null;
    if (open.len + label.len + close.len >= out.len) return null;
    var n: usize = 0;
    for (open) |c| {
        out[n] = c;
        n += 1;
    }
    for (label) |c| {
        out[n] = c;
        n += 1;
    }
    for (close) |c| {
        out[n] = c;
        n += 1;
    }
    out[n] = 0;
    return out[0..n :0];
}

/// Pack the link row left to right inside `band`, one rect per measured label
/// width with `gap` between neighbours. Pure — unit tested below.
///
/// The row is laid out from the band's LEFT edge, aligned with the message
/// above it, and never wraps: `layoutFor` has already widened the dialog to
/// hold the whole row (`links_w`), so a rect that ran past the band would mean
/// the two disagreed about the measurement.
pub fn packLinks(
    band: w32.RECT,
    widths: []const i32,
    gap: i32,
    out: *[max_links]w32.RECT,
) []w32.RECT {
    const n = @min(widths.len, max_links);
    var x = band.left;
    for (widths[0..n], 0..) |w, i| {
        out[i] = .{ .left = x, .top = band.top, .right = x + w, .bottom = band.bottom };
        x += w + gap;
    }
    return out[0..n];
}

/// Total width of a link row with these label widths — what `layoutFor` is
/// given as `links_w`, and the same arithmetic `packLinks` walks.
pub fn linkRowWidth(widths: []const i32, gap: i32) i32 {
    const n = @min(widths.len, max_links);
    if (n == 0) return 0;
    var total: i32 = 0;
    for (widths[0..n]) |w| total += w;
    return total + gap * @as(i32, @intCast(n - 1));
}

/// The labelled-row block's extent (T1556): both columns plus the gap between
/// them, and every row plus the gaps between them. Pure - unit tested below.
/// Zero by zero for no rows, so a dialog without rows is byte-identical.
pub fn rowsExtent(label_w: i32, value_w: i32, row_h: i32, n: usize, col_gap: i32, row_gap: i32) struct { w: i32, h: i32 } {
    const nr: i32 = @intCast(@min(n, max_rows));
    if (nr == 0) return .{ .w = 0, .h = 0 };
    return .{ .w = label_w + col_gap + value_w, .h = nr * row_h + (nr - 1) * row_gap };
}

/// Row `i`'s two cells, the block's top-left corner at (`left`, `top`). The
/// label cell is the label column's full width (its text is drawn
/// right-aligned inside it, so every label ends at the same x) and the value
/// cell starts one gap after it, so every value starts at the same x. Pure -
/// unit tested below.
pub fn rowRects(left: i32, top: i32, label_w: i32, value_w: i32, row_h: i32, col_gap: i32, row_gap: i32, i: usize) struct { label: w32.RECT, value: w32.RECT } {
    const y = top + @as(i32, @intCast(i)) * (row_h + row_gap);
    const vx = left + label_w + col_gap;
    return .{
        .label = .{ .left = left, .top = y, .right = left + label_w, .bottom = y + row_h },
        .value = .{ .left = vx, .top = y, .right = vx + value_w, .bottom = y + row_h },
    };
}

/// Gap between two links in the row, in DIPs. Wide enough that "Docs" and
/// "GitHub" read as two destinations rather than one phrase.
pub const link_gap_dip: f32 = 16;

/// Button width for the given widest caption extent (physical pixels):
/// the standard 88-DIP button, widened with 12 DIP of padding per side
/// when the caption needs the room.
pub fn buttonWidth(scale: f32, max_label_w: i32) i32 {
    return @max(px(88, scale), max_label_w + px(24, scale));
}
test "layoutFor: controls nest inside the client area at 1.0 scale" {
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    try testing.expect(l.client_w > 0 and l.client_h > 0);
    for ([_]w32.RECT{ l.icon, l.text, l.ok, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
    }
}

test "layoutFor: buttons right-aligned, OK left of Cancel, no overlap" {
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    try testing.expect(l.ok.right < l.cancel.left);
    try testing.expectEqual(l.ok.top, l.cancel.top);
    try testing.expectEqual(l.cancel.right, l.client_w - 16);
}

test "layoutFor: ok-only puts OK in the rightmost slot, no cancel rect" {
    const l = layoutFor(1.0, 300, 40, false, 0, 0, 0, 0, 0, false, false, false, 88);
    try testing.expectEqual(l.ok.right, l.client_w - 16);
    try testing.expectEqual(@as(i32, 0), l.cancel.right - l.cancel.left);
    try testing.expectEqual(@as(i32, 0), l.icon.right - l.icon.left);
}

test "layoutFor: text starts right of the icon with a gap" {
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    try testing.expect(l.text.left >= l.icon.right + 12);
    // Without an icon the text hugs the margin.
    const l2 = layoutFor(1.0, 300, 40, false, 0, 0, 0, 0, 0, false, true, false, 88);
    try testing.expectEqual(@as(i32, 16), l2.text.left);
}

test "layoutFor: short text is vertically centered against the icon" {
    const l = layoutFor(1.0, 300, 16, true, 0, 0, 0, 0, 0, false, true, false, 88);
    // Icon (32px) taller than text (16px): text drops to center.
    try testing.expect(l.text.top > l.icon.top);
    try testing.expectEqual(l.icon.top, 16);
    // Text (60px) taller than icon: icon centers instead.
    const l2 = layoutFor(1.0, 300, 60, true, 0, 0, 0, 0, 0, false, true, false, 88);
    try testing.expect(l2.icon.top > l2.text.top);
}

test "layoutFor: narrow text still fits the button row" {
    const l = layoutFor(1.0, 40, 20, false, 0, 0, 0, 0, 0, false, true, false, 88);
    // Two 88px buttons + 8px gap + 2*16 margins = 216, floored at 280.
    try testing.expect(l.client_w >= 280);
    try testing.expect(l.ok.left >= 16);
}

test "layoutFor: scales with DPI" {
    const l1 = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    const l2 = layoutFor(2.0, 600, 80, true, 0, 0, 0, 0, 0, false, true, false, 176);
    try testing.expectEqual(l1.client_w * 2, l2.client_w);
    try testing.expectEqual(l1.client_h * 2, l2.client_h);
    try testing.expectEqual(l1.ok.left * 2, l2.ok.left);
    try testing.expectEqual(l1.font_h * 2, l2.font_h);
}

test "buttonWidth: standard until the caption outgrows it, then padded" {
    // "OK"/"Cancel"-sized captions keep the 88-DIP standard width.
    try testing.expectEqual(@as(i32, 88), buttonWidth(1.0, 40));
    try testing.expectEqual(@as(i32, 176), buttonWidth(2.0, 80));
    // A wide caption ("Open Config") gets 12 DIP padding per side.
    try testing.expectEqual(@as(i32, 124), buttonWidth(1.0, 100));
}

test "layoutFor: a third button sits LEFT of OK, Cancel stays last" {
    // The remote-close confirmation's row (T1390): [Disconnect] [Close]
    // [Cancel], right-aligned, with the dismissive answer in the trailing slot
    // this dialog has always put it in.
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, true, 88);
    try testing.expect(l.alt.right <= l.ok.left);
    try testing.expect(l.ok.right <= l.cancel.left);
    // All three share the row and the width.
    try testing.expectEqual(l.ok.top, l.alt.top);
    try testing.expectEqual(l.ok.bottom, l.alt.bottom);
    try testing.expectEqual(l.ok.right - l.ok.left, l.alt.right - l.alt.left);
}

test "layoutFor: a third button does not move OK or Cancel" {
    // A two-button caller's layout must be byte-identical, so adding the
    // button cannot regress every other confirmation in the app.
    const two = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    const three = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, true, 88);
    try testing.expectEqual(two.ok.left, three.ok.left);
    try testing.expectEqual(two.cancel.left, three.cancel.left);
    try testing.expectEqual(two.client_h, three.client_h);
}

test "layoutFor: a narrow dialog widens to fit three buttons" {
    // Three 88px buttons + two 8px gaps + 2*16 margins = 312 > the 280 floor.
    const l = layoutFor(1.0, 40, 20, false, 0, 0, 0, 0, 0, false, true, true, 88);
    try testing.expect(l.alt.left >= 16);
    try testing.expectEqual(@as(i32, 312), l.client_w);
}

test "layoutFor: a third button without a Cancel is ignored" {
    // Two ways to say yes and no way to say no is not a choice, so the third
    // button is only ever offered alongside a Cancel.
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, false, true, 88);
    try testing.expectEqual(@as(i32, 0), l.alt.right - l.alt.left);
}

test "layoutFor: wide buttons widen the row and never overlap" {
    const l = layoutFor(1.0, 40, 20, false, 0, 0, 0, 0, 0, false, true, false, 124);
    try testing.expectEqual(@as(i32, 124), l.ok.right - l.ok.left);
    try testing.expectEqual(@as(i32, 124), l.cancel.right - l.cancel.left);
    try testing.expect(l.ok.right < l.cancel.left);
    try testing.expect(l.ok.left >= 16);
    // Client floor still respected: 2*124 + 8 + 2*16 = 288 > 280.
    try testing.expectEqual(@as(i32, 288), l.client_w);
}

// --- Prompt field (T176) -----------------------------------------------

test "layoutFor: no input means no input rect and no extra height" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    try testing.expectEqual(@as(i32, 0), plain.input.right - plain.input.left);
    try testing.expectEqual(@as(i32, 0), plain.input.bottom - plain.input.top);
}

test "layoutFor: the field sits between the message and the buttons" {
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, true, true, false, 88);
    try testing.expect(l.input.top >= l.text.bottom);
    try testing.expect(l.input.top >= l.icon.bottom - 1);
    try testing.expect(l.ok.top >= l.input.bottom);
    try testing.expect(l.cancel.top >= l.input.bottom);
    // Aligned with the message column, running to the trailing margin.
    try testing.expectEqual(l.text.left, l.input.left);
    try testing.expectEqual(l.client_w - 16, l.input.right);
    // And it nests, like everything else.
    for ([_]w32.RECT{ l.icon, l.text, l.input, l.ok, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
    }
}

test "layoutFor: the field's row is what makes a prompt taller" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    const with = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, true, true, false, 88);
    // 12 gap + 26 field.
    try testing.expectEqual(plain.client_h + 38, with.client_h);
    // The message band above it does not move.
    try testing.expectEqual(plain.text.top, with.text.top);
    try testing.expectEqual(plain.icon.top, with.icon.top);
}

test "layoutFor: a prompt is never too narrow to type in" {
    // A two-word message would otherwise leave a 280-wide dialog whose field
    // is barely wider than the button row.
    const l = layoutFor(1.0, 40, 20, false, 0, 0, 0, 0, 0, true, true, false, 88);
    try testing.expect(l.client_w >= 380);
    try testing.expect(l.input.right - l.input.left >= 340);
}

test "layoutFor: the field scales with DPI like everything else" {
    const a = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, true, true, false, 88);
    const b = layoutFor(2.0, 600, 80, true, 0, 0, 0, 0, 0, true, true, false, 176);
    try testing.expectEqual(a.client_h * 2, b.client_h);
    try testing.expectEqual(a.input.top * 2, b.input.top);
    try testing.expectEqual((a.input.bottom - a.input.top) * 2, b.input.bottom - b.input.top);
}

// --- Checkbox rows (T870) ----------------------------------------------

test "layoutFor: no checks means no check rects and no extra height" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    for (plain.checks) |r| {
        try testing.expectEqual(@as(i32, 0), r.right - r.left);
        try testing.expectEqual(@as(i32, 0), r.bottom - r.top);
    }
}

test "layoutFor: check rows sit between the message and the buttons" {
    const l = layoutFor(1.0, 300, 40, true, 0, 2, 0, 0, 0, false, true, false, 88);
    try testing.expect(l.checks[0].top >= l.text.bottom);
    try testing.expect(l.checks[1].top >= l.checks[0].bottom);
    try testing.expect(l.ok.top >= l.checks[1].bottom);
    // Aligned with the message column, running to the trailing margin.
    try testing.expectEqual(l.text.left, l.checks[0].left);
    try testing.expectEqual(l.client_w - 16, l.checks[0].right);
    // Unused rows stay empty.
    try testing.expectEqual(@as(i32, 0), l.checks[2].right - l.checks[2].left);
    // And everything nests.
    for ([_]w32.RECT{ l.icon, l.text, l.checks[0], l.checks[1], l.ok, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
    }
}

test "layoutFor: each check row adds its height, the block adds one gap" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    const one = layoutFor(1.0, 300, 40, true, 0, 1, 0, 0, 0, false, true, false, 88);
    const two = layoutFor(1.0, 300, 40, true, 0, 2, 0, 0, 0, false, true, false, 88);
    // 12 gap + 20 row.
    try testing.expectEqual(plain.client_h + 32, one.client_h);
    // +4 row gap + 20 row.
    try testing.expectEqual(one.client_h + 24, two.client_h);
    // The message band above does not move.
    try testing.expectEqual(plain.text.top, two.text.top);
}

test "layoutFor: checks stack above the input field when both are present" {
    const l = layoutFor(1.0, 300, 40, true, 0, 2, 0, 0, 0, true, true, false, 88);
    try testing.expect(l.input.top >= l.checks[1].bottom);
    try testing.expect(l.ok.top >= l.input.bottom);
}

test "layoutFor: check rows scale with DPI" {
    const a = layoutFor(1.0, 300, 40, true, 0, 2, 0, 0, 0, false, true, false, 88);
    const b = layoutFor(2.0, 600, 80, true, 0, 2, 0, 0, 0, false, true, false, 176);
    try testing.expectEqual(a.client_h * 2, b.client_h);
    try testing.expectEqual(a.checks[0].top * 2, b.checks[0].top);
    try testing.expectEqual((a.checks[1].bottom - a.checks[1].top) * 2, b.checks[1].bottom - b.checks[1].top);
}

// --- Secondary note (T600) ---------------------------------------------

test "layoutFor: no note means no note rect and no extra height" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    try testing.expectEqual(@as(i32, 0), plain.note.right - plain.note.left);
    try testing.expectEqual(@as(i32, 0), plain.note.bottom - plain.note.top);
}

test "layoutFor: the note sits between the checks and the buttons" {
    const l = layoutFor(1.0, 300, 40, true, 0, 2, 32, 0, 0, false, true, false, 88);
    try testing.expect(l.note.top >= l.checks[1].bottom);
    try testing.expect(l.ok.top >= l.note.bottom);
    // Aligned with the message column, running to the trailing margin like
    // the check rows.
    try testing.expectEqual(l.text.left, l.note.left);
    try testing.expectEqual(l.client_w - 16, l.note.right);
    // And it nests.
    try testing.expect(l.note.bottom <= l.client_h);
}

test "layoutFor: the note band is what makes a disclosing dialog taller" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 2, 0, 0, 0, false, true, false, 88);
    const with = layoutFor(1.0, 300, 40, true, 0, 2, 32, 0, 0, false, true, false, 88);
    // 12 gap + the measured 32.
    try testing.expectEqual(plain.client_h + 44, with.client_h);
    // Nothing above it moves.
    try testing.expectEqual(plain.text.top, with.text.top);
    try testing.expectEqual(plain.checks[1].top, with.checks[1].top);
}

test "layoutFor: the note stacks above the input field when both are present" {
    const l = layoutFor(1.0, 300, 40, true, 0, 1, 28, 0, 0, true, true, false, 88);
    try testing.expect(l.note.top >= l.checks[0].bottom);
    try testing.expect(l.input.top >= l.note.bottom);
    try testing.expect(l.ok.top >= l.input.bottom);
}

test "layoutFor: the note scales with DPI" {
    const a = layoutFor(1.0, 300, 40, true, 0, 2, 30, 0, 0, false, true, false, 88);
    const b = layoutFor(2.0, 600, 80, true, 0, 2, 60, 0, 0, false, true, false, 176);
    try testing.expectEqual(a.client_h * 2, b.client_h);
    try testing.expectEqual(a.note.top * 2, b.note.top);
    try testing.expectEqual((a.note.bottom - a.note.top) * 2, b.note.bottom - b.note.top);
}

test "layoutFor: no notes means no notes rect and a byte-identical layout (T625)" {
    // The accessory is opt-in, and every dialog that never asks for one must
    // lay out exactly as it did before the band existed.
    const plain = layoutFor(1.0, 300, 40, true, 0, 2, 32, 0, 0, true, true, false, 88);
    try testing.expectEqual(@as(i32, 0), plain.notes.right - plain.notes.left);
    try testing.expectEqual(@as(i32, 0), plain.notes.bottom - plain.notes.top);
    try testing.expectEqual(@as(i32, 0), plain.notes.top);
}

test "layoutFor: the notes band sits between the message and the buttons (T625)" {
    const h = whats_new_layout.accessoryHeight(1.0);
    const l = layoutFor(1.0, 300, 40, true, h, 0, 0, 0, 0, false, true, false, 88);
    try testing.expect(l.notes.top >= l.text.bottom);
    try testing.expect(l.ok.top >= l.notes.bottom);
    // It spans the text column to the trailing margin, like the check rows
    // and the fine print — it is a region, not a paragraph.
    try testing.expectEqual(l.text.left, l.notes.left);
    try testing.expectEqual(l.client_w - 16, l.notes.right);
    try testing.expectEqual(h, l.notes.bottom - l.notes.top);
    try testing.expect(l.notes.bottom <= l.client_h);
}

test "layoutFor: the notes band is what makes the update dialog taller (T625)" {
    const h = whats_new_layout.accessoryHeight(1.0);
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    const with = layoutFor(1.0, 300, 40, true, h, 0, 0, 0, 0, false, true, false, 88);
    // 12 gap + the fixed band.
    try testing.expectEqual(plain.client_h + 12 + h, with.client_h);
    // Nothing above it moves.
    try testing.expectEqual(plain.text.top, with.text.top);
    try testing.expectEqual(plain.icon.top, with.icon.top);
}

test "layoutFor: the notes band pushes the checks, note and field down (T625)" {
    const h = whats_new_layout.accessoryHeight(1.0);
    const l = layoutFor(1.0, 300, 40, true, h, 2, 28, 0, 0, true, true, false, 88);
    try testing.expect(l.checks[0].top >= l.notes.bottom);
    try testing.expect(l.note.top >= l.checks[1].bottom);
    try testing.expect(l.input.top >= l.note.bottom);
    try testing.expect(l.ok.top >= l.input.bottom);
}

test "layoutFor: notes get a width floor wide enough for prose (T625)" {
    const h = whats_new_layout.accessoryHeight(1.0);
    // A two-word message would otherwise leave the notes a column of single
    // words: the accessory takes the widest of the three floors.
    const l = layoutFor(1.0, 60, 20, true, h, 0, 0, 0, 0, false, true, false, 88);
    try testing.expectEqual(@as(i32, 460), l.client_w);
    // 460 client, less the margins and the warning icon's column: prose
    // width, not a two-word gutter.
    try testing.expectEqual(@as(i32, 384), l.notes.right - l.notes.left);
}

test "layoutFor: the notes band scales with DPI (T625)" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const h = whats_new_layout.accessoryHeight(scale);
        const l = layoutFor(scale, @intFromFloat(300 * scale), @intFromFloat(40 * scale), true, h, 0, 0, 0, 0, false, true, false, @intFromFloat(88 * scale));
        // The band is the DPI-scaled height, seated below the message and
        // clear of the buttons at every scale the app runs at.
        try testing.expectEqual(h, l.notes.bottom - l.notes.top);
        try testing.expect(l.notes.top >= l.text.bottom);
        try testing.expect(l.ok.top >= l.notes.bottom);
        try testing.expect(l.notes.bottom <= l.client_h);
        try testing.expect(l.notes.right <= l.client_w);
        // And the whole dialog grew by the band plus its gap, never by less.
        const plain = layoutFor(scale, @intFromFloat(300 * scale), @intFromFloat(40 * scale), true, 0, 0, 0, 0, 0, false, true, false, @intFromFloat(88 * scale));
        // And the dialog grew by exactly the band plus the gap above it —
        // the message is the taller half of the content band here, so that
        // gap is readable straight off the two rects.
        try testing.expectEqual(
            plain.client_h + (l.notes.top - l.text.bottom) + h,
            l.client_h,
        );
    }
}

test "layoutFor: a check count beyond capacity is clamped, not overflowed" {
    const l = layoutFor(1.0, 300, 40, true, 0, max_checks + 3, 0, 0, 0, false, true, false, 88);
    const capped = layoutFor(1.0, 300, 40, true, 0, max_checks, 0, 0, 0, false, true, false, 88);
    try testing.expectEqual(capped.client_h, l.client_h);
}

test "layoutFor: the font comes from the ramp (T313)" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layoutFor(scale, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
        try testing.expectEqual(type_ramp.body(scale).height, l.font_h);
        // A confirm's message is body text, never a subtitle and never a
        // caption — one role, so it reads at the same size as the chooser it
        // is often opened over.
        try testing.expect(l.font_h > type_ramp.caption(scale).height);
        try testing.expect(l.font_h < type_ramp.subtitle(scale).height);
    }
    try testing.expectEqual(@as(i32, 14), layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88).font_h);
}

// ---------------------------------------------------------------------
// The link row (T714)
// ---------------------------------------------------------------------

pub fn wstr(comptime s: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

test "linkAnchor: wraps a label in the SysLink markup" {
    var buf: [64]u16 = undefined;
    const m = linkAnchor(wstr("Docs"), &buf).?;
    try testing.expectEqualSlices(u16, wstr("<a>Docs</a>"), m);
    // Null-terminated: it is handed straight to CreateWindowExW.
    try testing.expectEqual(@as(u16, 0), m.ptr[m.len]);
}

test "linkAnchor: refuses a label the control would reinterpret" {
    var buf: [64]u16 = undefined;
    // A `&`, `<` or `>` in a label would be swallowed or reopen the markup.
    // No link beats a mangled one.
    try testing.expect(linkAnchor(wstr("Docs & FAQ"), &buf) == null);
    try testing.expect(linkAnchor(wstr("a<b"), &buf) == null);
    try testing.expect(linkAnchor(wstr("a>b"), &buf) == null);
}

test "linkAnchor: refuses a buffer that cannot hold the markup" {
    var small: [8]u16 = undefined;
    try testing.expect(linkAnchor(wstr("Release notes"), &small) == null);
}

test "linkRowWidth: labels plus the gaps between them" {
    try testing.expectEqual(@as(i32, 0), linkRowWidth(&.{}, 16));
    try testing.expectEqual(@as(i32, 40), linkRowWidth(&.{40}, 16));
    try testing.expectEqual(@as(i32, 96), linkRowWidth(&.{ 40, 40 }, 16));
    try testing.expectEqual(@as(i32, 152), linkRowWidth(&.{ 40, 40, 40 }, 16));
}

test "packLinks: left to right from the band, gapped, never overlapping" {
    const band: w32.RECT = .{ .left = 16, .top = 100, .right = 300, .bottom = 118 };
    var out: [max_links]w32.RECT = undefined;
    const rects = packLinks(band, &.{ 60, 40, 30 }, 16, &out);
    try testing.expectEqual(@as(usize, 3), rects.len);
    try testing.expectEqual(@as(i32, 16), rects[0].left);
    try testing.expectEqual(@as(i32, 76), rects[0].right);
    try testing.expectEqual(@as(i32, 92), rects[1].left);
    try testing.expectEqual(@as(i32, 132), rects[1].right);
    try testing.expectEqual(@as(i32, 148), rects[2].left);
    for (rects) |r| {
        try testing.expectEqual(band.top, r.top);
        try testing.expectEqual(band.bottom, r.bottom);
    }
}

test "packLinks: the row fits the width layoutFor was given" {
    // The two halves of the same arithmetic must agree, or the dialog reserves
    // a band the row runs out of.
    const widths = [_]i32{ 84, 48, 36, 52 };
    const row_w = linkRowWidth(&widths, 16);
    const band: w32.RECT = .{ .left = 16, .top = 0, .right = 16 + row_w, .bottom = 18 };
    var out: [max_links]w32.RECT = undefined;
    const rects = packLinks(band, &widths, 16, &out);
    try testing.expectEqual(band.right, rects[rects.len - 1].right);
}

test "packLinks: caps at max_links" {
    const band: w32.RECT = .{ .left = 0, .top = 0, .right = 500, .bottom = 18 };
    var out: [max_links]w32.RECT = undefined;
    const rects = packLinks(band, &.{ 10, 10, 10, 10, 10, 10 }, 8, &out);
    try testing.expectEqual(@as(usize, max_links), rects.len);
}

test "layoutFor: no links is byte-identical to before the row existed" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    try testing.expectEqual(@as(i32, 0), plain.links.right - plain.links.left);
    try testing.expectEqual(@as(i32, 0), plain.links.bottom - plain.links.top);
}

test "layoutFor: the link row sits between the message and the buttons" {
    const l = layoutFor(1.0, 300, 40, true, 0, 0, 0, 180, 18, false, true, false, 88);
    try testing.expect(l.links.top > l.text.bottom);
    try testing.expect(l.links.bottom < l.ok.top);
    try testing.expectEqual(@as(i32, 18), l.links.bottom - l.links.top);
    // Aligned with the message column, not with the icon.
    try testing.expectEqual(l.text.left, l.links.left);
    try testing.expect(l.links.bottom <= l.client_h);
}

test "layoutFor: the link row grows the dialog rather than wrapping" {
    const plain = layoutFor(1.0, 300, 40, true, 0, 0, 0, 0, 0, false, true, false, 88);
    const with = layoutFor(1.0, 300, 40, true, 0, 0, 0, 180, 18, false, true, false, 88);
    try testing.expect(with.client_h > plain.client_h);
    try testing.expectEqual(plain.client_h + 12 + 18, with.client_h);
    // A row wider than the message widens the dialog: a "GitHub" broken over
    // two lines is a defect, not a narrower dialog.
    const wide = layoutFor(1.0, 100, 20, false, 0, 0, 0, 600, 18, false, true, false, 88);
    try testing.expect(wide.client_w >= 16 + 600 + 16);
    try testing.expect(wide.links.right - wide.links.left >= 600);
}

test "layoutFor: links coexist with every other accessory" {
    const l = layoutFor(1.0, 300, 40, true, 120, 2, 28, 180, 18, true, true, false, 88);
    // Reading order down the dialog: message, notes, checks, fine print,
    // links, field, buttons — each strictly below the one before it.
    try testing.expect(l.notes.bottom <= l.checks[0].top);
    try testing.expect(l.checks[1].bottom <= l.note.top);
    try testing.expect(l.note.bottom <= l.links.top);
    try testing.expect(l.links.bottom <= l.input.top);
    try testing.expect(l.input.bottom <= l.ok.top);
    try testing.expect(l.ok.bottom <= l.client_h);
}

test "layoutFor: the link band scales with DPI" {
    const a = layoutFor(1.0, 300, 40, true, 0, 0, 0, 180, 18, false, true, false, 88);
    const b = layoutFor(2.0, 600, 80, true, 0, 0, 0, 360, 36, false, true, false, 176);
    try testing.expectEqual(a.links.top * 2, b.links.top);
    try testing.expectEqual((a.links.bottom - a.links.top) * 2, b.links.bottom - b.links.top);
}

test "rowsExtent: no rows is nothing at all (T1556)" {
    const e = rowsExtent(80, 300, 20, 0, 8, 4);
    try testing.expectEqual(@as(i32, 0), e.w);
    try testing.expectEqual(@as(i32, 0), e.h);
}

test "rowsExtent: both columns plus a gap; rows plus the gaps between them (T1556)" {
    const e = rowsExtent(80, 300, 20, 3, 8, 4);
    try testing.expectEqual(@as(i32, 388), e.w);
    try testing.expectEqual(@as(i32, 3 * 20 + 2 * 4), e.h);
}

test "rowsExtent: a row count beyond capacity is clamped (T1556)" {
    const e = rowsExtent(10, 10, 10, max_rows + 5, 0, 0);
    try testing.expectEqual(@as(i32, max_rows * 10), e.h);
}

test "rowRects: every label ends and every value starts at one x (T1556)" {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const r = rowRects(16, 40, 80, 300, 20, 8, 4, i);
        try testing.expectEqual(@as(i32, 96), r.label.right);
        try testing.expectEqual(@as(i32, 104), r.value.left);
        try testing.expectEqual(@as(i32, 404), r.value.right);
        try testing.expectEqual(r.label.top, r.value.top);
        try testing.expectEqual(r.label.bottom, r.value.bottom);
    }
}

test "rowRects: rows stack without overlap and fill the extent exactly (T1556)" {
    const n: usize = 5;
    const e = rowsExtent(80, 300, 20, n, 8, 4);
    var prev_bottom: i32 = 40;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = rowRects(16, 40, 80, 300, 20, 8, 4, i);
        try testing.expect(r.label.top >= prev_bottom);
        prev_bottom = r.label.bottom;
        try testing.expect(r.value.right - 16 <= e.w);
    }
    try testing.expectEqual(@as(i32, 40) + e.h, prev_bottom);
}

test "rows grow the message band layoutFor is given, and stay inside it (T1556)" {
    const scale: f32 = 1.5;
    const msg_w: i32 = 200;
    const msg_h: i32 = 40;
    const cg = px(row_col_gap_dip, scale);
    const rg = px(row_gap_dip, scale);
    const e = rowsExtent(90, 420, 24, 8, cg, rg);
    const span = px(rows_gap_dip, scale) + e.h;
    const l = layoutFor(scale, @max(msg_w, e.w), msg_h + span, true, 0, 0, 0, 0, 0, false, false, false, 132);
    const last = rowRects(l.text.left, l.text.top + msg_h + px(rows_gap_dip, scale), 90, 420, 24, cg, rg, 7);
    try testing.expect(last.value.right <= l.text.right);
    try testing.expect(last.value.bottom <= l.text.bottom);
    try testing.expect(l.ok.top >= last.value.bottom);
    try testing.expect(l.client_w >= l.text.left + e.w);
}
