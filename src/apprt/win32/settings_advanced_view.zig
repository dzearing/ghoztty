//! Painting for Settings > Advanced's Config file section and the change
//! toast (T2676; Mac `ConfigFileSection` and `SettingsToast`, 9287de0ff).
//! Split from `SettingsWindow.zig` so the window file does not keep growing;
//! the words are `settings_advanced.zig`'s.
//!
//! Every function here both measures and paints (`draw` false only
//! measures), the way the window's rows do, so layout and paint cannot drift.
const std = @import("std");

const SettingsWindow = @import("SettingsWindow.zig");
const SettingsModel = @import("SettingsModel.zig");
const adv = @import("settings_advanced.zig");
const layout = @import("settings_window_layout.zig");
const notes_render = @import("whats_new_notes.zig");
const panel_theme = @import("panel_theme.zig");
const w32 = @import("win32.zig");

const Rect = layout.Rect;
const dip = layout.dip;
const cr = notes_render.cr;
const fillRect = notes_render.fillRect;
const Hit = SettingsWindow.Hit;

/// The toast's widest (Mac `.frame(maxWidth: 620)`).
const toast_max_w = 620;
const toast_pad_x = 14;
const toast_pad_y = 9;
const toast_radius = 10;
const pill_pad_x = 5;

fn px(w: *const SettingsWindow, v: i32) i32 {
    return layout.px(v, w.scale);
}

/// A small capsule label ("loaded", "included"). Returns its width.
fn pill(w: *SettingsWindow, hdc: w32.HDC, x: i32, top: i32, band: i32, label: []const u8, fill: u32, color: u32, draw: bool) i32 {
    const ch = w.text.lineHeight(.caption);
    const pad = px(w, pill_pad_x);
    const tw = w.text.measure(hdc, label, .{}, .caption).cx;
    const r: Rect = .{ .x = x, .y = top + @divTrunc(band - ch, 2), .w = tw + 2 * pad, .h = ch };
    if (draw) {
        SettingsWindow.roundRect(hdc, r, @divTrunc(r.h, 2), fill, null, 1);
        _ = w.text.drawText(hdc, r.x + pad, r.y, label, .{}, .caption, color, true);
    }
    return r.w;
}

/// A push button whose RIGHT edge is `right`. Returns its width.
fn button(w: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, right: i32, top: i32, band: i32, label: []const u8, kind: Hit.Kind, index: usize, draw: bool) i32 {
    const fh = px(w, dip.field_h);
    const pad = px(w, dip.filter_pad_x);
    const tw = w.text.measure(hdc, label, .{}, .caption).cx;
    const bw = tw + 2 * pad;
    const r: Rect = .{ .x = right - bw, .y = top + @divTrunc(band - fh, 2), .w = bw, .h = fh };
    if (draw) {
        SettingsWindow.roundRect(hdc, r, px(w, dip.radius), cr(p.field), cr(p.boundary), w.hair());
        const ch = w.text.lineHeight(.caption);
        _ = w.text.drawText(hdc, r.x + pad, r.y + @divTrunc(fh - ch, 2), label, .{}, .caption, cr(p.text), true);
        w.hit(.{ .rect = r, .kind = kind, .index = index });
    }
    return bw;
}

/// Advanced > Config file: the file Settings writes (with Open in Editor and
/// Show in Explorer), any problem with it, every other file Ghostty loads
/// with Open, Backups with Restore..., and the Current file disclosure.
/// `y` is the section's top in client coordinates; returns its height.
pub fn paintConfigFile(w: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, y: i32, draw: bool) i32 {
    const f = w.frame();
    const g = px(w, dip.gap);
    const t = px(w, dip.tight);
    const pad_y = px(w, dip.row_pad_y);
    const lh = w.text.lineHeight(.body);
    const ch = w.text.lineHeight(.caption);
    const cols = layout.rowColumns(w.scale, f.list, f.scrollbar.w, y + pad_y, lh, dip.field_w);
    const width = cols.right - cols.left;
    const band = @max(lh, px(w, dip.field_h));
    var cy = y + pad_y;

    // The file Settings writes.
    {
        var bx = cols.right;
        bx -= button(w, hdc, p, bx, cy, band, "Show in Explorer", .reveal_file, 0, draw) + g;
        bx -= button(w, hdc, p, bx, cy, band, "Open in Editor", .open_editor, 0, draw) + g;
        const name = std.fs.path.basenameWindows(w.main_path);
        const nw = if (draw) w.text.drawText(hdc, cols.left, cy + @divTrunc(band - lh, 2), name, .{}, .body, cr(p.text), true) else w.text.measure(hdc, name, .{}, .body).cx;
        _ = pill(w, hdc, cols.left + nw + g, cy, band, "loaded", cr(p.select), cr(p.accent), draw);
        cy += band + t;
        if (draw) w.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = width, .h = ch }, w.display_path, .{ .code = true }, .caption, cr(p.secondary), true);
        cy += ch;
        if (w.target_display) |target| {
            cy += t;
            var buf: [600]u8 = undefined;
            const note = std.fmt.bufPrint(&buf, "A link to {s} \u{2014} Settings writes through it.", .{target}) catch "A link \u{2014} Settings writes through it.";
            if (draw) w.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = width, .h = ch }, note, .{}, .caption, cr(p.secondary), false);
            cy += ch;
        }
    }

    // Mac's red notice: unreadable file, refused undo, failed restore.
    if (w.model.file_error) |err| {
        cy += g;
        var buf: [600]u8 = undefined;
        const note = std.fmt.bufPrint(&buf, "\u{26A0} {s}", .{err}) catch err;
        cy += w.text.drawWrapped(hdc, cols.left, cy, width, note, .{}, .caption, cr(p.bad), draw);
    }

    // Every other file Ghostty loads, in load order.
    for (w.otherSources(), 0..) |src, i| {
        cy += g;
        const kind = adv.sourceKind(src);
        const right = cols.right - button(w, hdc, p, cols.right, cy, band, "Open", .open_source, i, draw) - g;
        const name = src.name();
        const nw = w.text.measure(hdc, name, .{}, .body).cx;
        if (draw) w.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy + @divTrunc(band - lh, 2), .w = @max(0, @min(nw, right - cols.left)), .h = lh }, name, .{}, .body, cr(p.text), false);
        _ = pill(w, hdc, cols.left + @min(nw, right - cols.left) + g, cy, band, kind.tag(), cr(p.well), cr(p.secondary), draw);
        cy += band + t;
        cy += w.text.drawWrapped(hdc, cols.left, cy, width, kind.note(), .{}, .caption, cr(p.secondary), draw);
    }

    // Backups.
    {
        cy += g;
        _ = button(w, hdc, p, cols.right, cy, band, "Restore\u{2026}", .restore_menu, 0, draw);
        if (draw) _ = w.text.drawText(hdc, cols.left, cy + @divTrunc(band - lh, 2), "Backups", .{}, .body, cr(p.text), true);
        cy += band + t;
        cy += w.text.drawWrapped(hdc, cols.left, cy, width, adv.backupsNote(w.store.backup_path != null), .{}, .caption, cr(p.secondary), draw);
    }

    // The Current file disclosure.
    {
        cy += g;
        const label = if (w.show_file) "\u{25BE} Current file" else "\u{25B8} Current file";
        const lw = if (draw) w.text.drawText(hdc, cols.left, cy, label, .{}, .body, cr(p.accent), true) else 0;
        if (draw) w.hit(.{ .rect = .{ .x = cols.left, .y = cy, .w = lw, .h = lh }, .kind = .show_file });
        cy += lh;
        if (w.show_file) {
            cy += t;
            const inner = g;
            const body_h = currentFileText(w, hdc, p, cols.left + inner, cy + inner, width - 2 * inner, false);
            const well: Rect = .{ .x = cols.left, .y = cy, .w = width, .h = body_h + 2 * inner };
            if (draw) {
                SettingsWindow.roundRect(hdc, well, px(w, dip.radius), cr(p.well), null, 1);
                _ = currentFileText(w, hdc, p, cols.left + inner, cy + inner, width - 2 * inner, true);
            }
            cy += well.h;
        }
    }

    cy += pad_y + g;
    if (draw) fillRect(hdc, .{ .x = cols.left, .y = cy - w.hair(), .w = width, .h = w.hair() }, cr(p.divider));
    return cy - y;
}

/// The user's file as text, its first `current_file_lines` lines, in the
/// code face. Returns the height.
fn currentFileText(w: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, x: i32, top: i32, width: i32, draw: bool) i32 {
    const ch = w.text.lineHeight(.caption);
    var y = top;
    const lines = w.file.lines.items;
    const total = lines.len;
    const shown = @min(total, adv.current_file_lines);
    for (lines[0..shown]) |line| {
        if (draw) w.text.drawEllipsized(hdc, .{ .x = x, .y = y, .w = width, .h = ch }, if (line.text.len == 0) " " else line.text, .{ .code = true }, .caption, cr(p.text), false);
        y += ch;
    }
    var buf: [96]u8 = undefined;
    const tail: ?[]const u8 = if (total == 0)
        "(empty)"
    else if (total > shown)
        std.fmt.bufPrint(&buf, "\u{2026} {d} more lines \u{2014} Open in Editor to see them all.", .{total - shown}) catch "\u{2026}"
    else
        null;
    if (tail) |s| {
        if (draw) _ = w.text.drawText(hdc, x, y, s, .{}, .caption, cr(p.secondary), true);
        y += ch;
    }
    return y - top;
}

/// "Saved <change> · applied live · Show Change · Undo · x" over the foot of
/// the form, after every write (Mac `SettingsToast`). Painted last, so its
/// hits sit above the rows under it.
pub fn paintToast(w: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, f: layout.Frame) void {
    const change = w.model.last_change orelse return;
    const view = f.list;
    const m = px(w, dip.margin);
    const t = px(w, dip.tight);
    const pad_y = px(w, toast_pad_y);
    const lh = w.text.lineHeight(.strong);
    const ch = w.text.lineHeight(.caption);
    const tw = @min(px(w, toast_max_w), view.w - 2 * m - f.scrollbar.w);
    if (tw <= 0) return;

    var h = pad_y * 2 + lh;
    if (w.toast_expanded) h += t + @as(i32, @intCast(change.removed.len + change.added.len)) * ch;
    if (w.toast_refused) h += t + ch;
    const r: Rect = .{ .x = view.x + @divTrunc(view.w - f.scrollbar.w - tw, 2), .y = view.y + view.h - m - h, .w = tw, .h = h };
    const shadow = px(w, 3);

    const elapsed = w.toastLeaveElapsed() orelse return paintCard(w, hdc, p, r, change, true);
    // Leaving (T2684): slid `drop` px toward the form's bottom edge and faded
    // to `alpha`. Mac's `.move(edge: .bottom)` carries it clear of that edge,
    // so the slide is its height, its shadow and the gap under it.
    const frame = adv.toastLeave(elapsed, h + shadow + m);
    w.toast_trace.add(frame.drop, frame.alpha);
    if (frame.done or frame.alpha == 0) return;
    // Clip to the form: the slide passes under its bottom edge.
    const bottom = view.y + view.h;
    const box: Rect = .{ .x = r.x, .y = r.y + frame.drop, .w = r.w, .h = @min(r.h + shadow, bottom - (r.y + frame.drop)) };
    if (box.h <= 0) return;
    // The card, painted over a copy of what is under it, then laid back
    // down at the frame's opacity. No hits: a leaving toast is not a target,
    // as a SwiftUI view in its removal transition is not.
    const mem = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(mem);
    const bmp = w32.CreateCompatibleBitmap(hdc, box.w, box.h) orelse return;
    defer _ = w32.DeleteObject(bmp);
    const old = w32.SelectObject(mem, bmp);
    defer _ = w32.SelectObject(mem, old);
    _ = w32.BitBlt(mem, 0, 0, box.w, box.h, hdc, box.x, box.y, w32.SRCCOPY);
    _ = w32.SetBkMode(mem, w32.TRANSPARENT);
    _ = w32.SetViewportOrgEx(mem, -box.x, -box.y, null);
    paintCard(w, mem, p, .{ .x = r.x, .y = r.y + frame.drop, .w = r.w, .h = r.h }, change, false);
    _ = w32.SetViewportOrgEx(mem, 0, 0, null);
    _ = w32.AlphaBlend(hdc, box.x, box.y, box.w, box.h, mem, 0, 0, box.w, box.h, .{ .SourceConstantAlpha = frame.alpha, .AlphaFormat = 0 });
}

/// The toast's card at `r`: shadow, card, the change line and its links, and
/// the expanded diff / refused note. `hits` is false for a leaving toast.
fn paintCard(w: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, r: Rect, change: SettingsModel.LastChange, hits: bool) void {
    const g = px(w, dip.gap);
    const t = px(w, dip.tight);
    const pad_x = px(w, toast_pad_x);
    const pad_y = px(w, toast_pad_y);
    const lh = w.text.lineHeight(.strong);
    const ch = w.text.lineHeight(.caption);
    // A soft drop shadow, then the card.
    SettingsWindow.roundRect(hdc, .{ .x = r.x, .y = r.y + px(w, 3), .w = r.w, .h = r.h }, px(w, toast_radius), cr(p.divider), null, 1);
    SettingsWindow.roundRect(hdc, r, px(w, toast_radius), cr(p.card), cr(p.card_border), w.hair());
    if (hits) w.hit(.{ .rect = r, .kind = .toast_body });

    const top = r.y + pad_y;
    var x = r.x + pad_x;
    const right_edge = r.x + r.w - pad_x;
    // Right to left: dismiss, Undo, Show/Hide Change.
    var rx = right_edge;
    const close_glyph = "\u{2715}";
    const cw = w.text.measure(hdc, close_glyph, .{}, .caption).cx;
    rx -= cw;
    _ = w.text.drawText(hdc, rx, top + @divTrunc(lh - ch, 2), close_glyph, .{}, .caption, cr(p.secondary), true);
    if (hits) w.hit(.{ .rect = .{ .x = rx - t, .y = top, .w = cw + 2 * t, .h = lh }, .kind = .toast_dismiss });
    const links = [_]struct { label: []const u8, kind: Hit.Kind }{
        .{ .label = "Undo", .kind = .toast_undo },
        .{ .label = if (w.toast_expanded) "Hide Change" else "Show Change", .kind = .toast_show },
    };
    for (links) |l| {
        const lw = w.text.measure(hdc, l.label, .{}, .body).cx;
        rx -= g + lw + g;
        _ = w.text.drawText(hdc, rx, top + @divTrunc(lh - w.text.lineHeight(.body), 2), l.label, .{}, .body, cr(p.accent), true);
        if (hits) w.hit(.{ .rect = .{ .x = rx, .y = top, .w = lw, .h = lh }, .kind = l.kind });
    }

    const tick = "\u{2714}";
    x += w.text.drawText(hdc, x, top, tick, .{}, .strong, cr(p.good), true) + g;
    const room = @max(0, rx - g - x);
    const mw = @min(w.text.measure(hdc, change.message, .{ .bold = true }, .strong).cx, room);
    w.text.drawEllipsized(hdc, .{ .x = x, .y = top, .w = mw, .h = lh }, change.message, .{ .bold = true }, .strong, cr(p.text), false);
    x += mw + g;
    if (rx - g - x > 0) w.text.drawEllipsized(hdc, .{ .x = x, .y = top + @divTrunc(lh - ch, 2), .w = rx - g - x, .h = ch }, adv.toastDetail(change.backed_up_to != null), .{}, .caption, cr(p.secondary), false);

    var ly = top + lh;
    const inner_w = right_edge - (r.x + pad_x);
    if (w.toast_expanded) {
        ly += t;
        var buf: [600]u8 = undefined;
        for (change.removed) |line| {
            const s = std.fmt.bufPrint(&buf, "\u{2212} {s}", .{line}) catch line;
            w.text.drawEllipsized(hdc, .{ .x = r.x + pad_x, .y = ly, .w = inner_w, .h = ch }, s, .{ .code = true }, .caption, cr(p.bad), false);
            ly += ch;
        }
        for (change.added) |line| {
            const s = std.fmt.bufPrint(&buf, "+ {s}", .{line}) catch line;
            w.text.drawEllipsized(hdc, .{ .x = r.x + pad_x, .y = ly, .w = inner_w, .h = ch }, s, .{ .code = true }, .caption, cr(p.good), false);
            ly += ch;
        }
    }
    if (w.toast_refused) {
        ly += t;
        w.text.drawEllipsized(hdc, .{ .x = r.x + pad_x, .y = ly, .w = inner_w, .h = ch }, SettingsModel.changed_since_message, .{}, .caption, cr(p.bad), false);
    }
}
