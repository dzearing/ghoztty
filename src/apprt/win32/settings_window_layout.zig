//! Geometry for the Settings window (T2675), the pure half.
//!
//! Mac's Settings window (`SettingsView.swift`) is 860x640, min 720x480: a
//! sidebar of pages with a Search field over it and "Settings are saved to
//! ... / Open Config File..." along its foot, then the page's form. This is
//! the same frame in DIPs, every value on the design system's 4 DIP scale
//! (docs/design/win32-design-system.md), asserted at 1.0, 1.25, 1.5 and 2.0
//! below.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.

const std = @import("std");
const wn = @import("whats_new_layout.zig");

pub const Rect = wn.Rect;
pub const clampScroll = wn.clampScroll;

/// Every length in DIPs, on the 4 DIP scale (2/4/8/12/16/24...).
pub const dip = struct {
    pub const default_w = 860;
    pub const default_h = 640;
    pub const min_w = 720;
    pub const min_h = 480;
    /// Mac: min 200, ideal 215, max 260.
    pub const sidebar_w = 216;
    pub const margin = 16;
    pub const gap = 8;
    pub const tight = 4;
    pub const search_h = 28;
    pub const search_top = 12;
    pub const page_row_h = 28;
    pub const page_icon = 20;
    /// "Settings are saved to" / the path / "Open Config File...".
    pub const sidebar_footer_h = 76;
    /// The page title band over the form.
    pub const title_h = 48;
    /// All Settings' All / Changed segmented control.
    pub const filter_h = 28;
    pub const filter_band_h = 44;
    pub const filter_pad_x = 12;
    /// Mac's `CommitTextField(width: 220)`.
    pub const field_w = 220;
    pub const field_h = 24;
    /// The value list of a repeatable key, Mac's `.frame(maxWidth: 360)`.
    pub const list_w = 360;
    pub const add_w = 120;
    /// Pane style's preview cards (Mac `PaneStyleSection`: 108x66, radius 8;
    /// the height rounds to the 4 DIP scale).
    pub const card_w = 108;
    pub const card_h = 68;
    pub const card_gap = 16;
    pub const card_radius = 8;
    pub const chip_h = 20;
    pub const chip_pad_x = 8;
    pub const row_pad_y = 8;
    pub const line_gap = 4;
    pub const dot = 8;
    pub const icon_hit = 20;
    pub const header_h = 36;
    pub const scrollbar_w = 8;
    pub const radius = 4;
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
    /// The hairline between the sidebar and the form.
    rule: Rect,
    search: Rect,
    /// The first page row's top; rows stack downward from here.
    pages_top: i32,
    sidebar_footer: Rect,
    title: Rect,
    /// The band holding All Settings' filter control (zero height when the
    /// page has none, or a search is showing).
    filter: Rect,
    /// The scrolling form, edge to edge in the main column.
    list: Rect,
    scrollbar: Rect,
};

pub fn frameFor(scale: f32, w: i32, h: i32, with_filter: bool) Frame {
    const sw = px(dip.sidebar_w, scale);
    const m = px(dip.margin, scale);
    const g = px(dip.gap, scale);
    const hair = @max(1, px(1, scale));
    const search_top = px(dip.search_top, scale);
    const search_h = px(dip.search_h, scale);
    const footer_h = px(dip.sidebar_footer_h, scale);
    const main_x = sw + hair;
    const main_w = @max(0, w - main_x);
    const title_h = px(dip.title_h, scale);
    const filter_h: i32 = if (with_filter) px(dip.filter_band_h, scale) else 0;
    const list_y = title_h + filter_h;
    const list_h = @max(0, h - list_y);
    const sb_w = px(dip.scrollbar_w, scale);
    const tight = px(dip.tight, scale);
    return .{
        .sidebar = .{ .x = 0, .y = 0, .w = sw, .h = h },
        .rule = .{ .x = sw, .y = 0, .w = hair, .h = h },
        .search = .{ .x = g, .y = search_top, .w = @max(0, sw - 2 * g), .h = search_h },
        .pages_top = search_top + search_h + g,
        .sidebar_footer = .{ .x = m, .y = @max(0, h - footer_h), .w = @max(0, sw - 2 * m), .h = footer_h },
        .title = .{ .x = main_x + m, .y = 0, .w = @max(0, main_w - 2 * m), .h = title_h },
        .filter = .{ .x = main_x + m, .y = title_h, .w = @max(0, main_w - 2 * m), .h = filter_h },
        .list = .{ .x = main_x, .y = list_y, .w = main_w, .h = list_h },
        .scrollbar = .{ .x = main_x + main_w - tight - sb_w, .y = list_y + tight, .w = sb_w, .h = @max(0, list_h - 2 * tight) },
    };
}

/// A page row in the sidebar.
pub fn pageRow(scale: f32, f: Frame, slot: usize) Rect {
    const g = px(dip.gap, scale);
    const row_h = px(dip.page_row_h, scale);
    return .{
        .x = g,
        .y = f.pages_top + @as(i32, @intCast(slot)) * row_h,
        .w = f.sidebar.w - 2 * g,
        .h = row_h,
    };
}

/// A row's content columns inside the list: the label column on the left,
/// the control column (a field or the value list) on the right.
pub const RowColumns = struct {
    left: i32,
    right: i32,
    control: Rect,
};

/// `control_w` is `field_w` for a plain key, `list_w` for a repeatable one;
/// a narrow window gives the label at least half the row.
pub fn rowColumns(scale: f32, list: Rect, scrollbar_w: i32, y: i32, line_h: i32, control_w_dip: i32) RowColumns {
    const m = px(dip.margin, scale);
    const left = list.x + m;
    const right = list.x + list.w - scrollbar_w - 2 * px(dip.tight, scale) - m;
    const room = @max(0, right - left);
    const cw = @min(px(control_w_dip, scale), @divTrunc(room, 2));
    const fh = px(dip.field_h, scale);
    const band = @max(line_h, fh);
    return .{
        .left = left,
        .right = right,
        .control = .{ .x = right - cw, .y = y + @divTrunc(band - fh, 2), .w = cw, .h = fh },
    };
}

/// The scroll thumb, or null when everything fits.
pub fn thumb(scale: f32, track: Rect, content_h: i32, scroll: i32) ?Rect {
    return wn.thumb(track, content_h, scroll, px(dip.field_h, scale));
}

const testing = std.testing;

fn onScale(v: i32) bool {
    return @mod(v, 4) == 0 or v == 2;
}

test "settings layout: every DIP value is on the 4 DIP scale" {
    inline for (@typeInfo(dip).@"struct".decls) |decl| {
        const v: i32 = @field(dip, decl.name);
        try testing.expect(onScale(v));
    }
}

test "settings layout: the frame tiles the client at every scale" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |s| {
        const sz = defaultSize(s);
        for ([_]bool{ false, true }) |with_filter| {
            const f = frameFor(s, sz.w, sz.h, with_filter);
            // Sidebar + rule + form span the width.
            try testing.expectEqual(sz.w, f.sidebar.w + f.rule.w + f.list.w);
            // Title, filter band and list stack to the bottom.
            try testing.expectEqual(sz.h, f.title.h + f.filter.h + f.list.h);
            try testing.expectEqual(f.title.h + f.filter.h, f.list.y);
            // The search sits inside the sidebar, above the first page row.
            try testing.expect(f.search.x + f.search.w <= f.sidebar.w);
            try testing.expect(f.search.y + f.search.h < f.pages_top);
            // The footer is at the sidebar's foot, below the page rows.
            try testing.expectEqual(sz.h, f.sidebar_footer.y + f.sidebar_footer.h);
            try testing.expect(pageRow(s, f, 0).y + pageRow(s, f, 0).h <= f.sidebar_footer.y);
            // The scrollbar is inside the list.
            try testing.expect(f.scrollbar.x + f.scrollbar.w <= f.list.x + f.list.w);
            try testing.expect(f.scrollbar.y >= f.list.y);
        }
        const nf = frameFor(s, sz.w, sz.h, false);
        try testing.expectEqual(@as(i32, 0), nf.filter.h);
    }
}

test "settings layout: the minimum size still fits the frame" {
    for ([_]f32{ 1.0, 1.5, 2.0 }) |s| {
        const sz = minSize(s);
        const f = frameFor(s, sz.w, sz.h, true);
        try testing.expect(f.list.w > f.sidebar.w);
        try testing.expect(f.list.h > 0);
    }
}

test "settings layout: the control column sits at the row's trailing edge" {
    const s: f32 = 1.5;
    const sz = defaultSize(s);
    const f = frameFor(s, sz.w, sz.h, true);
    const c = rowColumns(s, f.list, f.scrollbar.w, 100, px(20, s), dip.field_w);
    try testing.expectEqual(c.right, c.control.x + c.control.w);
    try testing.expectEqual(px(dip.field_w, s), c.control.w);
    try testing.expect(c.control.x > c.left);
    // A field taller than the text line is the band; the field starts at y.
    try testing.expectEqual(@as(i32, 100), c.control.y);

    // In a narrow list the control gives the label at least half the room.
    const narrow: Rect = .{ .x = 0, .y = 0, .w = px(300, s), .h = 100 };
    const n = rowColumns(s, narrow, f.scrollbar.w, 0, px(20, s), dip.list_w);
    try testing.expect(n.control.w <= @divTrunc(n.right - n.left, 2));
}

test "settings layout: thumb only when the content overflows" {
    const s: f32 = 1.0;
    const track: Rect = .{ .x = 0, .y = 0, .w = 8, .h = 400 };
    try testing.expect(thumb(s, track, 300, 0) == null);
    try testing.expect(thumb(s, track, 1200, 0) != null);
}
