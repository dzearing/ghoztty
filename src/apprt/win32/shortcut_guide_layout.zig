//! Geometry for the keyboard shortcut guide window (T2591), the pure half.
//!
//! Mac's guide (`ShortcutGuideView.swift`) is a 880x640 window, min 640x420:
//! categories in a 220-wide sidebar on the left, a search field over a
//! scrolling list on the right, counts and two actions along the bottom.
//! This is the same frame in DIPs, with every value on the design system's
//! 4 DIP scale (docs/design/win32-design-system.md) and asserted at 1.0,
//! 1.25, 1.5 and 2.0 below.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.

const std = @import("std");
const wn = @import("whats_new_layout.zig");

pub const Rect = wn.Rect;
pub const clampScroll = wn.clampScroll;

/// Every length in DIPs. Values are on the 4 DIP scale (2/4/8/12/16/24...).
pub const dip = struct {
    pub const default_w = 880;
    pub const default_h = 640;
    pub const min_w = 640;
    pub const min_h = 420;
    pub const sidebar_w = 220;
    pub const margin = 16;
    pub const gap = 8;
    pub const tight = 4;
    pub const search_h = 32;
    pub const search_top = 12;
    pub const footer_h = 44;
    pub const cat_row_h = 28;
    pub const cat_label_h = 24;
    pub const check = 16;
    pub const row_pad_y = 8;
    pub const row_pad_x = 12;
    pub const header_h = 36;
    pub const cap_h = 24;
    pub const cap_pad_x = 8;
    pub const badge_h = 16;
    pub const badge_pad_x = 4;
    pub const button_h = 28;
    pub const button_pad_x = 12;
    pub const scrollbar_w = 8;
    pub const radius_button = 4;
    pub const wheel_step = 48;
};

pub fn px(v: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * scale));
}

pub const Size = struct { w: i32, h: i32 };

pub fn defaultSize(scale: f32) Size {
    return .{ .w = px(dip.default_w, scale), .h = px(dip.default_h, scale) };
}

pub fn minSize(scale: f32) Size {
    return .{ .w = px(dip.min_w, scale), .h = px(dip.min_h, scale) };
}

/// The window's regions for a client of `w` x `h` device pixels.
pub const Frame = struct {
    sidebar: Rect,
    /// The hairline between the sidebar and the list.
    rule: Rect,
    search: Rect,
    /// The scrolling list, edge to edge in the main column.
    list: Rect,
    /// The hairline over the footer.
    footer_rule: Rect,
    footer: Rect,
    scrollbar: Rect,
    /// The "Show unbound actions" checkbox square, and the row it sits in
    /// (the whole row is the hit target).
    check: Rect,
    check_row: Rect,
    /// The first category row's top; rows stack downward from here.
    cats_top: i32,
};

pub fn frameFor(scale: f32, w: i32, h: i32) Frame {
    const sw = px(dip.sidebar_w, scale);
    const m = px(dip.margin, scale);
    const hair = @max(1, px(1, scale));
    const footer_h = px(dip.footer_h, scale);
    const search_top = px(dip.search_top, scale);
    const search_h = px(dip.search_h, scale);
    const main_x = sw + hair;
    const main_w = @max(0, w - main_x);
    const list_y = search_top + search_h + search_top;
    const list_h = @max(0, h - footer_h - hair - list_y);
    const sb_w = px(dip.scrollbar_w, scale);
    const tight = px(dip.tight, scale);
    const check = px(dip.check, scale);
    const row_h = px(dip.cat_row_h, scale);
    const check_row: Rect = .{ .x = px(dip.gap, scale), .y = h - m - row_h, .w = sw - 2 * px(dip.gap, scale), .h = row_h };
    return .{
        .sidebar = .{ .x = 0, .y = 0, .w = sw, .h = h },
        .rule = .{ .x = sw, .y = 0, .w = hair, .h = h },
        .search = .{ .x = main_x + m, .y = search_top, .w = @max(0, main_w - 2 * m), .h = search_h },
        .list = .{ .x = main_x, .y = list_y, .w = main_w, .h = list_h },
        .footer_rule = .{ .x = main_x, .y = h - footer_h - hair, .w = main_w, .h = hair },
        .footer = .{ .x = main_x, .y = h - footer_h, .w = main_w, .h = footer_h },
        .scrollbar = .{ .x = main_x + main_w - tight - sb_w, .y = list_y + tight, .w = sb_w, .h = @max(0, list_h - 2 * tight) },
        .check = .{ .x = check_row.x + px(dip.gap, scale), .y = check_row.y + @divTrunc(row_h - check, 2), .w = check, .h = check },
        .check_row = check_row,
        .cats_top = search_top,
    };
}

/// A category row's rect in the sidebar, by its visual slot.
pub fn categoryRow(scale: f32, f: Frame, slot: usize, label_before: bool) Rect {
    const g = px(dip.gap, scale);
    const row_h = px(dip.cat_row_h, scale);
    const label = if (label_before) px(dip.cat_label_h, scale) else 0;
    return .{
        .x = g,
        .y = f.cats_top + label + @as(i32, @intCast(slot)) * row_h,
        .w = f.sidebar.w - 2 * g,
        .h = row_h,
    };
}

/// The scroll thumb, or null when everything fits.
pub fn thumb(scale: f32, track: Rect, content_h: i32, scroll: i32) ?Rect {
    return wn.thumb(track, content_h, scroll, px(dip.cap_h, scale));
}

const testing = std.testing;

fn onScale(v: i32) bool {
    return @mod(v, 4) == 0 or v == 2;
}

test "every DIP value is on the 4 DIP scale" {
    inline for (@typeInfo(dip).@"struct".decls) |decl| {
        const v: i32 = @field(dip, decl.name);
        try testing.expect(onScale(v));
    }
}

test "the frame tiles the window at every scale, nothing touching" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| {
        const sz = defaultSize(s);
        const f = frameFor(s, sz.w, sz.h);
        const gap = px(dip.tight, s);
        // The search field sits inside the main column with a margin.
        try testing.expect(f.search.x >= f.rule.x + f.rule.w + gap);
        try testing.expect(f.search.x + f.search.w <= sz.w - gap);
        // The list starts below the search with a gap, ends above the footer.
        try testing.expect(f.list.y >= f.search.y + f.search.h + gap);
        try testing.expect(f.list.y + f.list.h <= f.footer_rule.y);
        try testing.expect(f.footer.y + f.footer.h == sz.h);
        // The scrollbar is inside the list with a gap to its edges.
        try testing.expect(f.scrollbar.x + f.scrollbar.w <= f.list.x + f.list.w - gap + 1);
        // The checkbox sits inside its row and the sidebar.
        try testing.expect(f.check.x >= f.check_row.x + gap);
        try testing.expect(f.check.y >= f.check_row.y);
        try testing.expect(f.check_row.y + f.check_row.h <= sz.h - gap);
        // Eleven category rows plus "All" and the label fit above the toggle
        // at the minimum height.
        const min = minSize(s);
        const fm = frameFor(s, min.w, min.h);
        const last = categoryRow(s, fm, 11, true);
        try testing.expect(last.y + last.h + gap <= fm.check_row.y);
    }
}

test "a smaller-than-minimum client never yields negative sizes" {
    const f = frameFor(1.0, 10, 10);
    try testing.expect(f.list.w >= 0 and f.list.h >= 0);
    try testing.expect(f.search.w >= 0);
}
