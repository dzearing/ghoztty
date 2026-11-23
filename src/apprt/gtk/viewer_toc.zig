//! The GTK table-of-contents card's pure half (T3418, Linux L9i): what the
//! card shows for a pane of a given width, and what the reader's gestures do
//! to it. The numbers are win32's `viewer_toc_layout.zig` (each cites its Mac
//! twin there); this file only strings them into the one decision the native
//! half needs per layout pass, so that decision asserts in the none lane.
//!
//! docs/reference/viewer-panes.md, "Table of contents":
//! - two or more headings, markdown only, or no card at all;
//! - a pane of 720 px or more: the card sits in a left gutter that the page
//!   reserves (`setGutter`), and its right edge drags the shared width;
//! - a narrower pane: the card is an overlay the nav bar's contents button
//!   slides in and out, closed whenever the pane enters that layout and
//!   dismissed by a row click (it is a menu there);
//! - the open state is ephemeral: nothing here is persisted but the width.
//!
//! No GTK imports, like `viewer_chrome.zig`.

const std = @import("std");
const toc_layout = @import("../win32/viewer_toc_layout.zig");

pub const Mode = toc_layout.Mode;

/// What survives between layout passes: the layout last applied and whether
/// the compact overlay is open. Ephemeral by design.
pub const State = struct {
    mode: Mode = .hidden,
    open: bool = false,
};

/// One layout pass's answer.
pub const Presentation = struct {
    state: State,
    /// The card is on screen (always in the gutter; only while open in the
    /// compact layout).
    card: bool,
    /// The card's width in GTK logical px (== Mac points == CSS px).
    card_w: f32,
    /// The left padding the page reserves (`window.__viewer.setGutter`); 0
    /// unless the card sits in the gutter.
    gutter_css: f32,
    /// The nav bar's contents button is shown (compact layout only).
    button: bool,
    /// The card's right edge drags (gutter only: an overlay floats over the
    /// document like a menu, with no gutter for a resize to redistribute).
    handle: bool,
};

/// Decide the presentation. `items` is the heading count the page reported,
/// `pref_w` the shared width preference, `markdown` whether the pane shows a
/// markdown document (a website posting headings gets no card).
pub fn present(prev: State, pane_w: f32, items: usize, pref_w: f32, markdown: bool) Presentation {
    const wanted: Mode = if (markdown) toc_layout.mode(pane_w, items) else .hidden;
    switch (wanted) {
        .hidden => return .{
            .state = .{},
            .card = false,
            .card_w = 0,
            .gutter_css = 0,
            .button = false,
            .handle = false,
        },
        .gutter => {
            const w = toc_layout.clampWidth(pref_w, pane_w);
            return .{
                .state = .{ .mode = .gutter, .open = false },
                .card = true,
                .card_w = w,
                .gutter_css = toc_layout.gutterCssWidth(w),
                .button = false,
                .handle = true,
            };
        },
        .compact => {
            // Entering the compact layout closes the overlay: it opens only
            // from its button.
            const open = prev.mode == .compact and prev.open;
            return .{
                .state = .{ .mode = .compact, .open = open },
                .card = open,
                .card_w = toc_layout.compactCardWidth(pref_w, pane_w),
                .gutter_css = 0,
                .button = true,
                .handle = false,
            };
        },
    }
}

/// The contents button: slide the overlay in or out. Only the compact
/// layout has the button.
pub fn toggle(s: State) State {
    if (s.mode != .compact) return s;
    return .{ .mode = .compact, .open = !s.open };
}

/// A row was clicked. The overlay is a menu in the narrow layout, so using
/// it dismisses it; the gutter card stays.
pub fn afterRowClick(s: State) State {
    if (s.mode == .compact and s.open) return .{ .mode = .compact, .open = false };
    return s;
}

/// A drag of the card's right edge, `dx` px from where it started: the new
/// width, clamped to the range and to what the pane can spare.
pub fn dragWidth(start_w: f32, dx: f64, pane_w: f32) f32 {
    return toc_layout.clampWidth(start_w + @as(f32, @floatCast(dx)), pane_w);
}

/// Each heading's indent depth, relative to the document's shallowest level
/// (a file whose headings start at `##` is not indented a step for nothing),
/// capped at `toc_layout.max_depth`. `out.len` must be `levels.len`.
pub fn depths(levels: []const u8, out: []u8) void {
    std.debug.assert(out.len == levels.len);
    const top = toc_layout.topLevel(levels) orelse return;
    for (levels, out) |l, *d| d.* = toc_layout.depthOf(l, top);
}

/// A row's leading indent in px: the label inset plus one step per depth.
/// Mac: `SidePanelRow` (`labelInset`, `indentStep`).
pub fn rowIndent(depth: u8) c_int {
    return @intFromFloat(toc_layout.text_inset_dip + toc_layout.indent_step_dip * @as(f32, @floatFromInt(depth)));
}

/// The tallest the card's scrolled rows may be: the page area less a margin
/// above and below and the header, never under the card's useful minimum.
pub fn maxRowsHeight(page_h: f32, header_h: f32) c_int {
    const avail = page_h - 2 * toc_layout.margin_dip - header_h;
    return @intFromFloat(@max(toc_layout.card_min_h_dip, avail));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "fewer than two headings, or not markdown, is no card at all" {
    for ([_]usize{ 0, 1 }) |n| {
        const p = present(.{}, 1000, n, 240, true);
        try testing.expectEqual(Mode.hidden, p.state.mode);
        try testing.expect(!p.card and !p.button and !p.handle);
        try testing.expectEqual(@as(f32, 0), p.gutter_css);
    }
    const web = present(.{ .mode = .gutter }, 1000, 9, 240, false);
    try testing.expectEqual(Mode.hidden, web.state.mode);
    try testing.expect(!web.card);
    try testing.expectEqual(@as(f32, 0), web.gutter_css);
}

test "a wide pane gets the gutter, the page reserves margin + card, and the edge drags" {
    const p = present(.{}, 1000, 5, 240, true);
    try testing.expectEqual(Mode.gutter, p.state.mode);
    try testing.expect(p.card and p.handle and !p.button);
    try testing.expectEqual(@as(f32, 240), p.card_w);
    try testing.expectEqual(toc_layout.margin_dip + 240, p.gutter_css);
    // 720 is the threshold itself, inclusive (Mac's `>=`).
    try testing.expectEqual(Mode.gutter, present(.{}, 720, 2, 240, true).state.mode);
    try testing.expectEqual(Mode.compact, present(.{}, 719, 2, 240, true).state.mode);
}

test "a gutter card never takes more than the pane can spare" {
    const p = present(.{}, 800, 3, 460, true);
    // clampWidth: pane - 720/2 = 440 caps the 460 preference.
    try testing.expectEqual(@as(f32, 440), p.card_w);
    try testing.expectEqual(toc_layout.margin_dip + 440, p.gutter_css);
}

test "a narrow pane is an overlay: closed on entry, opened by the button, nothing reserved" {
    var s = present(.{ .mode = .gutter }, 600, 4, 240, true).state;
    const closed = present(s, 600, 4, 240, true);
    try testing.expectEqual(Mode.compact, closed.state.mode);
    try testing.expect(closed.button and !closed.card and !closed.handle);
    try testing.expectEqual(@as(f32, 0), closed.gutter_css);

    s = toggle(closed.state);
    const open = present(s, 600, 4, 240, true);
    try testing.expect(open.card and open.state.open);
    try testing.expectEqual(@as(f32, 0), open.gutter_css);

    // Still open on the next pass at a compact width (a divider drag).
    try testing.expect(present(open.state, 500, 4, 240, true).card);
    // Widening to the gutter and back closes it: entry closes it.
    const wide = present(open.state, 900, 4, 240, true);
    try testing.expect(!wide.state.open);
    try testing.expect(!present(wide.state, 600, 4, 240, true).card);
}

test "a row click dismisses the overlay but not the gutter card" {
    try testing.expectEqual(State{ .mode = .compact, .open = false }, afterRowClick(.{ .mode = .compact, .open = true }));
    try testing.expectEqual(State{ .mode = .gutter }, afterRowClick(.{ .mode = .gutter }));
    // The button does nothing outside the compact layout.
    try testing.expectEqual(State{ .mode = .gutter }, toggle(.{ .mode = .gutter }));
}

test "the compact card shrinks to a narrow pane instead of hanging off it" {
    const p = present(.{ .mode = .compact, .open = true }, 100, 3, 240, true);
    try testing.expect(p.card_w <= 100 - 2 * toc_layout.margin_dip);
    try testing.expect(p.card_w >= 1);
}

test "dragging the edge clamps to the range and to the pane" {
    try testing.expectEqual(@as(f32, 300), dragWidth(240, 60, 1200));
    try testing.expectEqual(toc_layout.card_min_dip, dragWidth(240, -500, 1200));
    try testing.expectEqual(toc_layout.card_max_dip, dragWidth(240, 900, 2000));
    try testing.expectEqual(@as(f32, 440), dragWidth(240, 900, 800));
}

test "depths are relative to the shallowest heading and capped" {
    var out: [5]u8 = undefined;
    depths(&.{ 2, 3, 4, 6, 2 }, &out);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 0 }, &out);
    var one: [2]u8 = undefined;
    depths(&.{ 1, 1 }, &one);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, &one);
    try testing.expect(rowIndent(1) > rowIndent(0));
}

test "the rows' height cap leaves the margins and never collapses" {
    try testing.expectEqual(@as(c_int, 600 - 24 - 30), maxRowsHeight(600, 30));
    try testing.expectEqual(@as(c_int, 80), maxRowsHeight(50, 30));
}
