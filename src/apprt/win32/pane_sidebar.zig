//! The pane sidebar's pure rules on Windows (T1828; Mac 597a193cc,
//! `PaneSidebarState.swift` / `PaneSidebarText`, `docs/design/pane-sidebar.md`).
//!
//! The sidebar is a per-window column, left of the split grid, that lists
//! every pane of the active tab: the panes in the grid (focused one selected)
//! and then the stashed ones (T1827). Expanded, it is a flat panel;
//! collapsed, it is a raised card holding one tile per pane — the mini rail,
//! each tile its row with the text taken away.
//! One button switches the two (T2289, Mac e77422577): the header's first
//! item, centred on the rail's column in both modes so it never moves. There
//! is no pin and no hover-open. Hidden outright, it takes no space at all.
//!
//! Everything here is arithmetic and string rules — modes, column widths,
//! the row text, and the geometry the window paints
//! and hit-tests — so it is asserted at 1.0 / 1.25 / 1.5 / 2.0 without a
//! window, in every lane. The HWND that paints it is `PaneSidebar.zig`.
//!
//! Numbers. The ROWS reuse the viewer side panel's (`viewer_toc_layout`):
//! Mac's design says the pane sidebar is "the same card, not a lookalike" of
//! the table of contents, so its fill inset, text inset, vertical padding and
//! corner are imported, not restated. A rail tile is a row without its text
//! (T2279, Mac 75dc046e3): the same pill, the same icon at the same place, so
//! the rail card is that pill and its insets (52 DIP) inside the design
//! system's `lg` card margin (12, which IS `GlassCard.outerMargin`) - the
//! rail's column is Mac's 76 exactly.

const std = @import("std");
const toc = @import("viewer_toc_layout.zig");
const pane_elevation = @import("pane_elevation.zig");
const order_mod = @import("pane_sidebar_order.zig");

// ---------------------------------------------------------------------------
// Modes and the column

pub const Mode = enum {
    /// Hidden outright (`toggle_pane_sidebar`): no column, not a target.
    hidden,
    /// Expanded: the rail's raised card at the panel's width (T2290).
    expanded,
    /// Collapsed, or a window too narrow for the panel: the mini rail.
    mini,
};

/// Below this window width the full panel would crowd the grid and the rail
/// does not (Mac's `narrowWindowWidth`, the viewer side panel's breakpoint).
pub const narrow_window_dip: f32 = toc.gutter_min_dip;

pub const default_width_dip: f32 = 240;
pub const min_width_dip: f32 = 180;
pub const max_width_dip: f32 = 380;

/// A row's icon box (Mac `PaneSidebarRow.iconWidth`).
pub const icon_dip: f32 = 16;

/// The rail's card (T2279, Mac 75dc046e3 `railCardWidth`): exactly a row's
/// pill around its icon - the pill `fill_inset` in from each side, the icon
/// `text_inset` into the pill - so a tile is its row without the text and
/// collapsing or expanding the sidebar moves no icon. 52 DIP.
pub const rail_card_dip: f32 = 2 * (toc.fill_inset_dip + toc.text_inset_dip) + icon_dip;
/// The margin around the card (design system `lg`).
pub const rail_margin_dip: f32 = 12;

/// Every pane row's height, a full row or a rail tile (T2279, Mac
/// `PaneSidebarRow.height`): one number, so a pane's icon sits at the same
/// height in both modes - and a window header's (T2340, Mac c4dbe30be), so
/// every item of the list is one height. Its pill is `row_gap_dip` short of
/// it, centred, so no two pills - or a pill and anything next to it - ever
/// touch (T2311, Mac 157b08c48).
pub const row_dip: f32 = 32;
/// The clear space between two pane pills, rail tiles or window headers
/// (Mac `PaneSidebarRow.gap`): half of it above each, half below.
pub const row_gap_dip: f32 = 4;
/// Clear space above and below a project header's band, outside the band
/// (Mac `PaneSidebarOutline.headerGap`), so a pinned header is still just its
/// band and never touches a row's hover or the tray's well.
pub const header_gap_dip: f32 = 6;
/// A project header's band (T2340, Mac c4dbe30be
/// `PaneSidebarProjectHeader.height`): a little under a row's, its caption
/// centred in it.
pub const project_header_dip: f32 = 32;
/// Between this window's grid and its stash on the rail (`md`), the hairline
/// in the middle of it.
pub const rail_group_gap_dip: f32 = 8;

/// The standard icon button the header's buttons are drawn as.
pub const button_dip: f32 = 28;
/// The compact button a row's hover action is drawn as (dense list rows).
pub const row_button_dip: f32 = 20;
/// Between a row's two hover buttons (Mac `trailingButtonSpacing`).
pub const row_button_gap_dip: f32 = 4;
/// The design system's default inset (`sm`).
pub const sm_dip: f32 = 4;

pub fn mode(expanded: bool, hidden: bool, window_w_dip: f32) Mode {
    if (hidden) return .hidden;
    if (expanded and canExpand(window_w_dip)) return .expanded;
    return .mini;
}

/// Whether the toggle can expand (Mac `canExpand`): not in a window too
/// narrow for the panel, where the rail is forced and its button is off.
pub fn canExpand(window_w_dip: f32) bool {
    return window_w_dip >= narrow_window_dip;
}

/// The space around the raised rail card (Mac `PaneSidebarState.RailInsets`,
/// 557e4f978).
pub const RailInsets = struct {
    leading: f32,
    vertical: f32,
    trailing: f32,
    /// How far, in pixels, the column reaches up beside the window's tab
    /// strip (T1900; Mac `PaneSidebarState.tabRowHeight`): the card and the
    /// panel run up through it, but their content starts below it - the
    /// strip's row belongs to the caption, so nothing there takes a click.
    /// 0 when the column starts under the chrome.
    reach_px: i32 = 0,

    /// In pixels: one rounding per edge, shared by the layout and the
    /// card's material so the two cannot land a pixel apart.
    pub fn leadingPx(self: RailInsets, scale: f32) i32 {
        return px(self.leading, scale);
    }
    pub fn verticalPx(self: RailInsets, scale: f32) i32 {
        return px(self.vertical, scale);
    }
    pub fn trailingPx(self: RailInsets, scale: f32) i32 {
        return px(self.trailing, scale);
    }
};

/// Flat: the card margin on every side. Elevated (T1850): the SAME margin
/// the panes keep from the window's edge, and none trailing - the grid's own
/// margin is already the gap there, and adding the card's on top of it left
/// the rail further from the panes than from the window edge, with its ends
/// out of line with theirs.
pub fn railInsets(elevated: bool) RailInsets {
    return if (elevated)
        .{ .leading = pane_elevation.MARGIN_DIP, .vertical = pane_elevation.MARGIN_DIP, .trailing = 0 }
    else
        .{ .leading = rail_margin_dip, .vertical = rail_margin_dip, .trailing = rail_margin_dip };
}

pub fn railColumnDip() f32 {
    return railColumnDipFor(false);
}

/// The rail's column: its insets and the card.
pub fn railColumnDipFor(elevated: bool) f32 {
    const in = railInsets(elevated);
    return in.leading + rail_card_dip + in.trailing;
}

/// The width of the sidebar's COLUMN — what the grid is laid out beside.
pub fn columnDip(m: Mode, panel_w_dip: f32) f32 {
    return columnDipFor(m, panel_w_dip, false);
}

pub fn columnDipFor(m: Mode, panel_w_dip: f32, elevated: bool) f32 {
    if (m == .hidden) return 0;
    const in = railInsets(elevated);
    return in.leading + cardDip(m, panel_w_dip) + in.trailing;
}

/// The sidebar's card (T2290, Mac 0a547522d `cardWidth`): ONE raised card in
/// both modes, in the same insets with the same top and height - the rail's
/// width collapsed, the panel's expanded. Its width.
pub fn cardDip(m: Mode, panel_w_dip: f32) f32 {
    return switch (m) {
        .hidden => 0,
        .expanded => clampWidth(panel_w_dip),
        .mini => rail_card_dip,
    };
}

pub fn columnPx(m: Mode, panel_w_dip: f32, scale: f32) i32 {
    return columnPxFor(m, panel_w_dip, scale, false);
}

pub fn columnPxFor(m: Mode, panel_w_dip: f32, scale: f32, elevated: bool) i32 {
    if (m == .hidden) return 0;
    // Summed from the rounded parts, so the column is exactly the card's
    // pixels plus its insets' at every scale.
    const in = railInsets(elevated);
    return in.leadingPx(scale) + px(cardDip(m, panel_w_dip), scale) + in.trailingPx(scale);
}

pub fn clampWidth(w: f32) f32 {
    return @min(max_width_dip, @max(min_width_dip, w));
}

pub fn px(dip: f32, scale: f32) i32 {
    return toc.px(dip, scale);
}

// ---------------------------------------------------------------------------
// Row text

/// The title a terminal has before anything sets one (Ghostty's ghost).
pub const placeholder_title = "\u{1F47B}";

/// The name a row shows (Mac `PaneSidebarText.title`). A terminal that never
/// set a title carries the ghost placeholder, which names nothing - so it
/// falls back to the working directory's name,
/// then to the pane kind.
pub fn displayTitle(raw: ?[]const u8, pwd: ?[]const u8, kind: []const u8) []const u8 {
    if (raw) |r| {
        const t = std.mem.trim(u8, r, " \t");
        if (t.len > 0 and !std.mem.eql(u8, t, placeholder_title)) return t;
    }
    if (pwd) |p| {
        const name = lastComponent(std.mem.trimRight(u8, p, "/\\"));
        if (name.len > 0 and !std.mem.eql(u8, name, "/")) return name;
    }
    return kind;
}

/// What a pane is called wherever it is named in one line - a sidebar row, a
/// rail tile, a stacked pane's strip (Mac `PaneSidebarText.label`, T2085): the
/// name the user gave it (`user_titled`: Change Pane Title, or the sidebar's
/// pencil - T2339, Mac a13bf6f43), else its banner's title when the banner has
/// one, else `displayTitle`. The banner title beats the terminal's because
/// somebody chose it: an agent's banner hook sets it to the task, while the
/// agent itself retitles the pane (OSC 0/2) with whatever it is doing. A
/// banner title is written into `buf`.
pub fn paneLabel(raw: ?[]const u8, pwd: ?[]const u8, kind: []const u8, banner: ?[]const u8, user_titled: bool, buf: []u8) []const u8 {
    if (user_titled) if (raw) |r| {
        const t = std.mem.trim(u8, r, " \t");
        if (t.len > 0) return t;
    };
    return bannerTitle(banner, buf) orelse displayTitle(raw, pwd, kind);
}

/// The title a pane banner gives itself, as plain text, or null when it has
/// none (Mac `PaneSidebarText.bannerTitle`). Only a line that IS a title
/// counts, never just the first line of whatever the banner says:
/// - a heading on the banner's first line (`## Fix strip labels`) - what the
///   banner hook writes above its table;
/// - a one-line banner that opens with a bold run standing on its own
///   (`**Fix strip labels**`, or followed by ` · ...`) - the hook's OSC
///   fallback. A bold label (`**Goal:** ...`) is not a title, and neither is a
///   bold run followed by more prose (`**PR #12** — 3 files`).
/// Written into `buf`.
pub fn bannerTitle(banner: ?[]const u8, buf: []u8) ?[]const u8 {
    const text = banner orelse return null;
    var lines = LineIter{ .s = text };
    var first: ?[]const u8 = null;
    var more = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (first != null) {
            more = true;
            break;
        }
        first = line;
    }
    const line = first orelse return null;
    if (headingText(line)) |heading| {
        const plain = stripInlineMarkdown(heading, buf);
        return if (plain.len == 0) null else plain;
    }
    if (more or !std.mem.startsWith(u8, line, "**")) return null;
    const rest = line[2..];
    const close = std.mem.indexOf(u8, rest, "**") orelse return null;
    const after = std.mem.trim(u8, rest[close + 2 ..], " \t");
    if (after.len > 0 and !std.mem.startsWith(u8, after, "\u{00B7}")) return null;
    const plain = stripInlineMarkdown(rest[0..close], buf);
    if (plain.len == 0 or plain[plain.len - 1] == ':') return null;
    return plain;
}

/// An ATX heading's text (`## Title` -> `Title`): 1-6 `#` and a space, as the
/// banner renders one. `line` is already trimmed.
fn headingText(line: []const u8) ?[]const u8 {
    var hashes: usize = 0;
    while (hashes < line.len and line[hashes] == '#') hashes += 1;
    if (hashes < 1 or hashes > 6) return null;
    if (hashes >= line.len or line[hashes] != ' ') return null;
    const text = std.mem.trim(u8, line[hashes..], " \t");
    return if (text.len == 0) null else text;
}

/// The first line of a pane banner as plain text (Mac
/// `PaneSidebarText.bannerLine`): the banner markdown subset stripped to its
/// words, and a heading to its text. Table and rule lines are skipped - they
/// are layout, not a summary. Written into `buf`; null when nothing is left.
pub fn bannerLine(banner: ?[]const u8, buf: []u8) ?[]const u8 {
    const text = banner orelse return null;
    var lines = LineIter{ .s = text };
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '|') continue;
        if (isThematicBreak(line)) continue;
        const plain = stripInlineMarkdown(headingText(line) orelse line, buf);
        if (plain.len == 0) return null;
        return plain;
    }
    return null;
}

/// A terminal row's subtitle from its banner (Mac `PaneSidebarText.subtitle`):
/// the banner's first line when it is not the banner's title - a titled banner
/// already names the row (`paneLabel`), so the working directory takes the line.
pub fn bannerSubtitle(banner: ?[]const u8, buf: []u8) ?[]const u8 {
    if (bannerTitle(banner, buf) != null) return null;
    return bannerLine(banner, buf);
}

/// `subtitle`, unless it only repeats `title` - then null (Mac `distinct`).
pub fn distinct(subtitle: ?[]const u8, title: []const u8) ?[]const u8 {
    const s = subtitle orelse return null;
    const a = std.mem.trim(u8, s, " \t");
    if (a.len == 0) return null;
    if (std.mem.eql(u8, a, std.mem.trim(u8, title, " \t"))) return null;
    return s;
}

/// Whether two spellings name the same directory: case-insensitive, either
/// separator, trailing separators ignored (a Windows shell titles itself
/// `C:\Users\Ann` while its reported cwd may end in a slash).
pub fn samePath(a_in: []const u8, b_in: []const u8) bool {
    const a = std.mem.trimRight(u8, std.mem.trim(u8, a_in, " \t"), "/\\");
    const b = std.mem.trimRight(u8, std.mem.trim(u8, b_in, " \t"), "/\\");
    if (a.len != b.len or a.len == 0) return false;
    for (a, b) |x, y| {
        const xs = if (x == '/') '\\' else std.ascii.toLower(x);
        const ys = if (y == '/') '\\' else std.ascii.toLower(y);
        if (xs != ys) return false;
    }
    return true;
}

/// A working directory as a row shows it: the user's profile directory reads
/// as `~` (Mac's `abbreviatedPath`; on Windows the home is `%USERPROFILE%`,
/// compared case-insensitively because the file system is).
pub fn abbreviatePath(path: []const u8, home: ?[]const u8, buf: []u8) []const u8 {
    const h = std.mem.trimRight(u8, home orelse return path, "/\\");
    if (h.len == 0 or path.len < h.len) return path;
    if (!std.ascii.eqlIgnoreCase(path[0..h.len], h)) return path;
    const rest = path[h.len..];
    if (rest.len > 0 and rest[0] != '\\' and rest[0] != '/') return path;
    if (1 + rest.len > buf.len) return path;
    buf[0] = '~';
    @memcpy(buf[1..][0..rest.len], rest);
    return buf[0 .. 1 + rest.len];
}

fn lastComponent(p: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, p, "/\\");
    if (trimmed.len == 0) return p[0..@min(p.len, 1)];
    const i = std.mem.lastIndexOfAny(u8, trimmed, "/\\") orelse return trimmed;
    return trimmed[i + 1 ..];
}

const LineIter = struct {
    s: []const u8,
    i: usize = 0,

    /// Lines split on a real newline or the two-character `\n` escape the
    /// banner CLI accepts.
    fn next(self: *LineIter) ?[]const u8 {
        if (self.i >= self.s.len) return null;
        const start = self.i;
        while (self.i < self.s.len) : (self.i += 1) {
            if (self.s[self.i] == '\n') {
                const line = self.s[start..self.i];
                self.i += 1;
                return line;
            }
            if (self.s[self.i] == '\\' and self.i + 1 < self.s.len and self.s[self.i + 1] == 'n') {
                const line = self.s[start..self.i];
                self.i += 2;
                return line;
            }
        }
        return self.s[start..];
    }
};

fn isThematicBreak(line: []const u8) bool {
    var first: u8 = 0;
    var count: usize = 0;
    for (line) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        if (first == 0) {
            if (c != '-' and c != '*' and c != '_') return false;
            first = c;
        } else if (c != first) return false;
        count += 1;
    }
    return count >= 3;
}

/// The banner's inline markdown stripped to words: list/checkbox markers,
/// `[text](url)` -> text, `\` escapes, `*` and backticks, and `_` only at word
/// edges (so snake_case survives).
fn stripInlineMarkdown(line_in: []const u8, buf: []u8) []const u8 {
    var line = line_in;
    const markers = [_][]const u8{ "- [x] ", "- [X] ", "- [ ] ", "[x] ", "[X] ", "[ ] ", "- ", "* " };
    for (markers) |m| {
        if (std.mem.startsWith(u8, line, m)) {
            line = line[m.len..];
            break;
        }
    }

    var len: usize = 0;
    var i: usize = 0;
    var escaped = false;
    while (i < line.len and len < buf.len) {
        const c = line[i];
        if (escaped) {
            buf[len] = c;
            len += 1;
            escaped = false;
            i += 1;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            i += 1;
            continue;
        }
        // [text](url) -> text
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, ']')) |close| {
                if (close + 1 < line.len and line[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, line, close + 2, ')')) |paren| {
                        const text = line[i + 1 .. close];
                        const n = @min(text.len, buf.len - len);
                        @memcpy(buf[len..][0..n], text[0..n]);
                        len += n;
                        i = paren + 1;
                        continue;
                    }
                }
            }
        }
        if (c == '*' or c == '`') {
            i += 1;
            continue;
        }
        if (c == '_') {
            const prev_word = len > 0 and std.ascii.isAlphanumeric(buf[len - 1]);
            const next_word = i + 1 < line.len and std.ascii.isAlphanumeric(line[i + 1]);
            if (!(prev_word and next_word)) {
                i += 1;
                continue;
            }
        }
        buf[len] = c;
        len += 1;
        i += 1;
    }
    return std.mem.trim(u8, buf[0..len], " \t");
}

// ---------------------------------------------------------------------------
// The roster

pub const Section = enum { grid, stashed };

/// The roster's order (Mac's sections): grid panes in reading order - the
/// tree's SCREEN order (`leafIterator`, T560), not its storage order, which
/// puts a `down` split's new pane above the one it split off - then stashed panes,
/// top of the stash first. `out` receives the views; returns how many.
/// Generic over any `SplitTree(V)` whose `V` carries `stash_seq`.
pub fn roster(tree: anytype, out: []*@TypeOf(tree).View) usize {
    var n: usize = 0;
    var it = tree.leafIterator();
    while (it.next()) |entry| {
        if (entry.view.stash_seq != 0) continue;
        if (n == out.len) return n;
        out[n] = entry.view;
        n += 1;
    }
    const grid = n;
    it = tree.leafIterator();
    while (it.next()) |entry| {
        if (entry.view.stash_seq == 0) continue;
        if (n == out.len) break;
        // Insertion into the stashed tail, most recent first.
        var at = n;
        while (at > grid and out[at - 1].stash_seq < entry.view.stash_seq) : (at -= 1) {
            out[at] = out[at - 1];
        }
        out[at] = entry.view;
        n += 1;
    }
    return n;
}

/// The roster with its grid section in the sidebar's own order (T2302, Mac
/// `PaneSidebarOrder.arranged`): `order` is the window's list of pane ids,
/// empty until the first reorder (the tree's order). The stash keeps its own
/// order. Generic as `roster` is; `V` also carries `paneId()`.
pub fn rosterOrdered(tree: anytype, order: []const []const u8, out: []*@TypeOf(tree).View) usize {
    const n = roster(tree, out);
    if (order.len == 0) return n;
    var grid: usize = 0;
    while (grid < n and out[grid].stash_seq == 0) grid += 1;
    if (grid > order_mod.max_ids) return n;
    var ids: [order_mod.max_ids][]const u8 = undefined;
    for (out[0..grid], 0..) |v, i| ids[i] = v.paneId();
    var idx: [order_mod.max_ids]usize = undefined;
    const got = order_mod.arranged(ids[0..grid], order, &idx);
    var views: [order_mod.max_ids]*@TypeOf(tree).View = undefined;
    for (idx[0..got], 0..) |vi, i| views[i] = out[vi];
    @memcpy(out[0..got], views[0..got]);
    return n;
}

// ---------------------------------------------------------------------------
// Geometry. Every rect is in the sidebar window's own client coordinates.

pub const Rect = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }
    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }
    pub fn centerX(self: Rect) i32 {
        return self.left + @divTrunc(self.width(), 2);
    }
    pub fn centerY(self: Rect) i32 {
        return self.top + @divTrunc(self.height(), 2);
    }
};

/// What the layout needs to know about each item: its section, and whether
/// the expanded row carries a subtitle line.
pub const Item = struct {
    section: Section,
    two_line: bool = false,
    /// The all-windows outline (T1829): which window group the pane is in -
    /// the rail draws a hairline where it changes - and whether that group is
    /// THIS window's, whose stash alone is a drop target here.
    group: u16 = 0,
    own: bool = true,
    /// The row offers the rename pencil (T2339): a terminal's - a viewer is
    /// named by its page (`pane_sidebar_rename.offersPencil`).
    renamable: bool = false,
};

pub const max_items: usize = 64;

/// One line of the all-windows outline the panel lays out
/// (`pane_sidebar_outline.buildLines` makes them).
pub const LineKind = enum { project, window, pane };
pub const Line = struct {
    kind: LineKind,
    /// A pane line's item; a head's window group.
    index: usize = 0,
    /// Outline level: a project head and a lone window are 0, a window in a
    /// project 1, a window's panes one deeper than the window. It says which
    /// section a line is in; the layout indents only a pane, one step under
    /// its window - a grouped window lines up with the rest (T2340, Mac
    /// c4dbe30be).
    depth: u8 = 0,
};

pub const HeadKind = enum { project, window };

/// A project or window header row of the outline.
pub const Head = struct {
    kind: HeadKind,
    /// The window group it heads (a project: its first window's).
    index: usize,
    depth: u8,
    /// The row's fill (hit across the panel's width, as a row is).
    rect: Rect,
    /// The disclosure chevron's box.
    chevron: Rect,
    /// A window head's icon (T2340, Mac 28f6cde09 `macwindow`): in a pane
    /// row's icon column, so the window's panes - one chevron in - put
    /// theirs right under it. Empty on a project head.
    icon: Rect = .{},
    /// Where the name starts.
    label_x: i32,
};

pub const max_heads: usize = 48;
pub const max_marks: usize = 64;

/// The outline's geometry (Mac `PaneSidebarOutline`): a header's chevron
/// sits where a row's label starts, and each level indents by one chevron
/// and its gap, so a window's pane icons line up under the window's name.
pub const chevron_dip: f32 = 12;
pub const chevron_gap_dip: f32 = 5;
pub const outline_step_dip: f32 = chevron_dip + chevron_gap_dip;

/// The measured text metrics the expanded panel lays out against: one line of
/// the row title, one of the subtitle/caption.
pub const TextMetrics = struct {
    title_h: i32,
    caption_h: i32,
};

pub const Layout = struct {
    mode: Mode = .hidden,
    width: i32 = 0,
    height: i32 = 0,
    /// The raised card, in both modes (T2290): the rail's, or the expanded
    /// list's at the panel's width - the same insets, top and height.
    card: Rect = .{},
    /// The collapse/expand button's painted square (T2289): the header's
    /// first item, on the same spot in both modes (`toggleRect`).
    toggle: Rect = .{},
    /// The all-windows toggle, at the header's trailing edge (panel only;
    /// Mac drops its header buttons from the rail). The trash-mode button
    /// that sat after it went with trash mode (T2280, Mac dc2bbab6b).
    scope: Rect = .{},
    /// The new-window + (T2323, Mac 44aa923f0): left of the all-windows
    /// toggle, the panel's header only - the rail's header is its toggle alone.
    add: Rect = .{},
    /// The all-windows search field under the header (T1877; outline in the
    /// panel only - empty otherwise), and its clear button at the trailing
    /// edge.
    search: Rect = .{},
    search_clear: Rect = .{},
    /// The field holds a query, so its clear button is a hit target. Set by
    /// the caller - the layout itself does not depend on it.
    search_text: bool = false,
    /// "No matching panes": the outline has no line to show (a search with
    /// no hit - an unfiltered outline always lists this window).
    no_match: ?Rect = null,

    /// Laid out as the all-windows outline (T1829).
    outline: bool = false,
    /// THIS window's stashed items are `first_stashed..stash_end` - the rows
    /// a drop into the stash positions itself among.
    stash_end: usize = 0,
    /// Each item's content indent (outline level), in pixels.
    indent: [max_items]i32 = [_]i32{0} ** max_items,
    /// Each item is THIS window's (`Item.own`): only those rows offer the
    /// hover stash button; every row has its x (T2298,
    /// `pane_sidebar_menu.rowOffersStash`).
    own: [max_items]bool = [_]bool{true} ** max_items,
    /// Each item offers the rename pencil (`Item.renamable`, T2339).
    renamable: [max_items]bool = [_]bool{false} ** max_items,
    heads: [max_heads]Head = undefined,
    head_count: usize = 0,
    /// The outline's hairlines (the single-window layout uses
    /// `section_rule`). Empty since T2425 (Mac 6bd2962eb): the rail has no
    /// divider between windows, and a window's stash has none, nor a caption
    /// (T2313, Mac 47b39b1cb). Kept so the log's `rules=` proves it stays 0.
    rules: [max_marks]Rect = undefined,
    rule_count: usize = 0,
    /// The header band (expanded) holding the "PANES" caption.
    header: Rect = .{},
    /// Where the "PANES" caption starts (expanded).
    caption_x: i32 = 0,
    /// The STASHED caption band over the stashed rows (expanded; never over
    /// the empty tray's well, whose own text says what it is - T2313, Mac
    /// 82b9c5501) - and the hairline between the sections (both modes).
    stashed_caption: ?Rect = null,
    section_rule: ?Rect = null,
    /// One rect per item: an expanded row's fill, or a rail tile's square.
    items: [max_items]Rect = undefined,
    count: usize = 0,
    /// The grid/stashed boundary for the rail and the panel.
    first_stashed: usize = 0,
    /// The empty tray's dashed well, while nothing is stashed (T1844, T2276,
    /// `addEmptyTray`): a row below the grid rows, or a tile on the rail.
    drop_slot: ?Rect = null,
    /// The scrolled region (T1878, `pane_sidebar_scroll.apply`): the rows
    /// below the header and search field, or the rail's tiles below its
    /// toggle.
    /// Empty until a scroll pass ran, which leaves hit-testing unclipped.
    viewport: Rect = .{},
    /// How far the content is scrolled up, already clamped to `0..max_scroll`.
    scroll: i32 = 0,
    max_scroll: i32 = 0,
    /// The project head pinned to the viewport's top (Mac's sticky section
    /// header), an index into `heads`.
    sticky: ?usize = null,
    /// The rail's stand-in for this window's header (T2324, Mac e94a9737e
    /// `PaneSidebarRailAddSlot`): the window's + alone, centred in a slot the
    /// header's exact height. Single roster on the rail only - empty otherwise.
    rail_add: Rect = .{},
    /// This window's header is folded (single roster, panel): its panes and
    /// its tray have no place, so `addEmptyTray` lays out no well.
    own_folded: bool = false,

    pub fn item(self: *const Layout, i: usize) Rect {
        return self.items[i];
    }

    /// Whether item `i` has a place on screen: a pane in a folded group of
    /// the outline has none in the panel (the rail still shows it).
    pub fn shown(self: *const Layout, i: usize) bool {
        return self.items[i].width() > 0;
    }

    /// An expanded row's hover x (T2280, Mac dc2bbab6b): the compact square
    /// at the row's trailing edge, `sm` inside its fill. Every row has one,
    /// another window's too (T2298, Mac 345be6b02).
    pub fn rowClose(self: *const Layout, i: usize, scale: f32) Rect {
        const r = self.items[i];
        const b = px(row_button_dip, scale);
        const top = r.top + @divTrunc(r.height() - b, 2);
        return trailingSquare(r, top, scale);
    }

    /// An outline header's hover x (T2298, Mac 345be6b02 / 7e4646bb5): where
    /// the count is, in the same column as the rows' x, level with the
    /// chevron. A window's closes that window; a project's every window in it.
    pub fn headClose(self: *const Layout, k: usize, scale: f32) Rect {
        if (k >= self.head_count) return .{};
        return headCloseRect(self.heads[k], scale);
    }

    /// An outline header's hover + (T2323, Mac 44aa923f0): the same square,
    /// `row_button_gap_dip` before its x. A window's splits that window's
    /// focused pane; a project's opens a new window in the group.
    pub fn headAdd(self: *const Layout, k: usize, scale: f32) Rect {
        if (k >= self.head_count) return .{};
        return headAddRect(self.heads[k], scale);
    }

    /// The row-button square at `fill`'s trailing edge, `sm` inside it.
    fn trailingSquare(fill: Rect, top: i32, scale: f32) Rect {
        const b = px(row_button_dip, scale);
        const inset = px(sm_dip, scale);
        return .{ .left = fill.right - inset - b, .top = top, .right = fill.right - inset, .bottom = top + b };
    }

    /// An expanded row's hover stash / restore button: the same square,
    /// `row_button_gap_dip` before the x (Mac's minus/restore, then the x).
    /// This window's rows only: another window's offers the x alone.
    pub fn rowButton(self: *const Layout, i: usize, scale: f32) Rect {
        if (!self.own[i]) return .{};
        return squareBefore(self.rowClose(i, scale), scale);
    }

    /// An expanded row's hover pencil (T2339, Mac a13bf6f43): first among
    /// its buttons - the same square, `row_button_gap_dip` before the stash
    /// button, or before the x on another window's row. A terminal's row
    /// only (`Item.renamable`).
    pub fn rowRename(self: *const Layout, i: usize, scale: f32) Rect {
        if (!self.renamable[i]) return .{};
        return squareBefore(if (self.own[i]) self.rowButton(i, scale) else self.rowClose(i, scale), scale);
    }

    /// An outline header's hover pencil (T2339, Mac 379a352ef / a13bf6f43):
    /// first among its buttons, `row_button_gap_dip` before its +. A
    /// window's renames that window; a project's, the group.
    pub fn headRename(self: *const Layout, k: usize, scale: f32) Rect {
        if (k >= self.head_count) return .{};
        return headRenameRect(self.heads[k], scale);
    }
};

/// The row-button square one button and `row_button_gap_dip` before `b`.
fn squareBefore(b: Rect, scale: f32) Rect {
    const shift = b.width() + px(row_button_gap_dip, scale);
    return .{ .left = b.left - shift, .top = b.top, .right = b.right - shift, .bottom = b.bottom };
}

/// Header `hd`'s hover x (`Layout.headClose`).
pub fn headCloseRect(hd: Head, scale: f32) Rect {
    const b = px(row_button_dip, scale);
    return Layout.trailingSquare(hd.rect, hd.chevron.top + @divTrunc(hd.chevron.height() - b, 2), scale);
}

/// Header `hd`'s hover + (`Layout.headAdd`): its x's square, one button and
/// `row_button_gap_dip` toward the name.
pub fn headAddRect(hd: Head, scale: f32) Rect {
    return squareBefore(headCloseRect(hd, scale), scale);
}

/// Header `hd`'s hover pencil (`Layout.headRename`): one button and
/// `row_button_gap_dip` before its +.
pub fn headRenameRect(hd: Head, scale: f32) Rect {
    return squareBefore(headAddRect(hd, scale), scale);
}

/// A header at `fill`, its chevron's box at `cx` level with a line of
/// `text_h` from `text_top`. A window head's icon follows the chevron in a
/// pane row's icon column and spacing (T2340, Mac 28f6cde09), its name in a
/// pane title's column; a project head's name follows the chevron.
fn placeHead(kind: HeadKind, index: usize, depth: u8, fill: Rect, cx: i32, text_top: i32, text_h: i32, scale: f32) Head {
    const chev = px(chevron_dip, scale);
    const cy = text_top + @divTrunc(text_h - chev, 2);
    const after = cx + chev + px(chevron_gap_dip, scale);
    var hd: Head = .{
        .kind = kind,
        .index = index,
        .depth = depth,
        .rect = fill,
        .chevron = .{ .left = cx, .top = cy, .right = cx + chev, .bottom = cy + chev },
        .label_x = after,
    };
    if (kind == .window) {
        hd.icon = .{ .left = after, .top = text_top, .right = after + px(icon_dip, scale), .bottom = text_top + text_h };
        hd.label_x = hd.icon.right + px(icon_text_gap_dip, scale);
    }
    return hd;
}

/// Between a row's icon and its text (a pane row's and a window head's).
pub const icon_text_gap_dip: f32 = 8;

/// The expanded row's height: Mac's `SidePanelRow` padding around one or two
/// lines (title, then the subtitle in the caption size).
pub fn rowHeight(two_line: bool, tm: TextMetrics, scale: f32) i32 {
    const lines = tm.title_h + if (two_line) tm.caption_h else 0;
    return lines + 2 * px(toc.row_v_pad_dip, scale);
}

/// A pane row's pill - a full row's or a rail tile's, one height for both
/// (T2279, Mac `PaneSidebarRow.height` less the gap between rows), so
/// a pane's icon sits at the same height expanded or collapsed. Never short
/// of the two lines a full row can hold, should the system's text run large.
pub fn pillHeight(tm: TextMetrics, scale: f32) i32 {
    // A line's height already carries its leading, so two lines touching
    // the pill's edges still read as padded.
    const min = tm.title_h + tm.caption_h;
    return @max(px(row_dip, scale) - rowGap(scale), min);
}

/// A project header's band (`project_header_dip`), never short of its
/// caption with `sm` above and below, should the system's text run large.
pub fn projectHeadHeight(tm: TextMetrics, scale: f32) i32 {
    return @max(px(project_header_dip, scale), tm.caption_h + 2 * px(sm_dip, scale));
}

/// The clear space between two pane pills (and two tiles, and a pill and a
/// window header): twice `rowHalfGap`, so it splits evenly round each pill.
pub fn rowGap(scale: f32) i32 {
    return 2 * rowHalfGap(scale);
}

/// The space above and below each pill inside its row (Mac's
/// `.padding(.vertical, gap / 2)`).
pub fn rowHalfGap(scale: f32) i32 {
    return @max(px(row_gap_dip / 2, scale), 1);
}

/// Lay the sidebar out in a `w` x `h` client area.
pub fn layout(m: Mode, w: i32, h: i32, items: []const Item, tm: TextMetrics, scale: f32) Layout {
    return layoutWith(m, w, h, items, null, tm, scale);
}

/// `layout`, or - given the outline's `lines` (T1829) - the all-windows
/// outline: the panel lays out the lines, the rail every item with a hairline
/// between window groups.
pub fn layoutWith(m: Mode, w: i32, h: i32, items: []const Item, lines: ?[]const Line, tm: TextMetrics, scale: f32) Layout {
    return layoutIn(m, w, h, items, lines, tm, scale, railInsets(false));
}

/// `layoutWith` with the rail card at `insets` (the window's pane style).
pub fn layoutIn(m: Mode, w: i32, h: i32, items: []const Item, lines: ?[]const Line, tm: TextMetrics, scale: f32, insets: RailInsets) Layout {
    var l: Layout = .{ .mode = m, .width = w, .height = h };
    const n = @min(items.len, max_items);
    l.count = n;
    l.outline = lines != null;
    for (items[0..n], 0..) |it, i| {
        l.own[i] = it.own;
        l.renamable[i] = it.renamable;
    }
    findStash(&l, items[0..n]);
    switch (m) {
        .hidden => l.count = 0,
        .expanded => {
            layoutCard(&l, w - insets.leadingPx(scale) - insets.trailingPx(scale), insets, scale);
            // The card runs up beside the tab strip (T1900); its content
            // starts below it.
            const c = l.card;
            const area: Rect = .{ .left = c.left, .top = @min(c.top + insets.reach_px, c.bottom), .right = c.right, .bottom = c.bottom };
            layoutHeader(&l, area, tm, scale, insets);
            if (lines) |ls| {
                layoutSearch(&l, area, tm, scale);
                layoutLines(&l, area, ls, tm, scale);
            } else layoutRows(&l, area, items[0..n], tm, scale);
        },
        .mini => layoutMini(&l, tm, scale, insets),
    }
    return l;
}

/// THIS window's stashed items: the single roster's stashed tail, or the
/// outline's own group's (contiguous: a group lists its grid, then its stash).
fn findStash(l: *Layout, items: []const Item) void {
    const n = items.len;
    l.first_stashed = n;
    l.stash_end = n;
    for (items, 0..) |it, i| {
        if (it.section == .stashed and it.own) {
            l.first_stashed = i;
            break;
        }
    }
    if (!l.outline) return;
    var e = l.first_stashed;
    while (e < n and items[e].own and items[e].section == .stashed) e += 1;
    l.stash_end = e;
}

/// The collapse/expand button (T2289, Mac dc2bbab6b `toggleLeading`): the
/// rail's first item - the standard icon-button square, centred in the
/// rail's card, `inset` below where the card's content starts - and the panel
/// header's first item at exactly the same pixels, so toggling never moves it
/// under the pointer. Laid out from the column's own insets in either mode,
/// since the column starts at the window's edge whichever it is.
pub fn toggleRect(scale: f32, insets: RailInsets) Rect {
    const btn = px(button_dip, scale);
    const inset = toggleClear(scale);
    const x = insets.leadingPx(scale) + inset;
    // The card runs up beside the tab strip (T1900); its content starts
    // below it.
    const y = insets.verticalPx(scale) + insets.reach_px + inset;
    return .{ .left = x, .top = y, .right = x + btn, .bottom = y + btn };
}

/// The toggle's clearance from the card's edges: centred in the card from
/// ONE rounded inset, so the left and right clearances cannot round apart.
fn toggleClear(scale: f32) i32 {
    return @divTrunc(px(rail_card_dip, scale) - px(button_dip, scale), 2);
}

/// The header band round the toggle, in BOTH modes (T2279): it holds the
/// toggle with the same clearance above and below it that it keeps from the
/// rail card's edges, and is never shorter than the caption's own header
/// height (design system §0: the band is sized to its control, never the
/// reverse). The first row starts at its bottom expanded and collapsed alike,
/// so a pane's icon is at the same height in both.
fn headerBand(l: *Layout, area: Rect, tm: TextMetrics, scale: f32) void {
    const clear = toggleClear(scale);
    const top = @max(area.top, l.toggle.top - clear);
    const bottom = @max(l.toggle.bottom + clear, top + toc.headerHeight(tm.caption_h, scale));
    l.header = .{ .left = area.left, .top = top, .right = area.right, .bottom = bottom };
}

/// The header band: the toggle first (`toggleRect`), the caption after it,
/// then the new-window + and the all-windows button at the trailing edge,
/// all on the toggle's row (`headerBand`).
fn layoutHeader(l: *Layout, area: Rect, tm: TextMetrics, scale: f32, insets: RailInsets) void {
    const sm = px(sm_dip, scale);
    const btn = px(button_dip, scale);
    l.toggle = toggleRect(scale, insets);
    headerBand(l, area, tm, scale);
    // Mac's header buttons sit 2 pt apart, and the caption is padded 4 more
    // past the toggle.
    const gap = px(2, scale);
    l.caption_x = l.toggle.right + gap + sm;
    const bt = l.toggle.top + @divTrunc(l.toggle.height() - btn, 2);
    l.scope = .{ .left = area.right - sm - btn, .top = bt, .right = area.right - sm, .bottom = bt + btn };
    l.add = .{ .left = l.scope.left - gap - btn, .top = bt, .right = l.scope.left - gap, .bottom = bt + btn };
}

/// The all-windows search field, under the header (T1877; Mac's capsule
/// under the header, inset like a row's fill, with room below it). A field of
/// the design system's input shape: one body line with `sm` above and below,
/// never shorter than the standard 28 DIP control, so it sits on the same
/// frame as the header's buttons. The clear button is the compact 20 DIP
/// square, `sm` in from the field's trailing edge.
fn layoutSearch(l: *Layout, area: Rect, tm: TextMetrics, scale: f32) void {
    const sm = px(sm_dip, scale);
    const fill = px(toc.fill_inset_dip, scale);
    const h = @max(tm.title_h + 2 * sm, px(button_dip, scale));
    const top = l.header.bottom;
    l.search = .{ .left = area.left + fill, .top = top, .right = area.right - fill, .bottom = top + h };
    const b = px(row_button_dip, scale);
    const bt = top + @divTrunc(h - b, 2);
    l.search_clear = .{ .left = l.search.right - sm - b, .top = bt, .right = l.search.right - sm, .bottom = bt + b };
}

/// Where the outline's lines start: below the search field when there is
/// one, else below the header.
fn bodyTop(l: *const Layout, scale: f32) i32 {
    if (l.search.width() > 0) return l.search.bottom + px(sm_dip, scale);
    return l.header.bottom;
}

/// The panel's rows inside `area`, below the header `layoutHeader` placed.
fn layoutRows(l: *Layout, area: Rect, items: []const Item, tm: TextMetrics, scale: f32) void {
    const sm = px(sm_dip, scale);
    const fill = px(toc.fill_inset_dip, scale);
    const half = rowHalfGap(scale);
    const rh = pillHeight(tm, scale);
    // `y` is the bottom of the last row: its pill and the half gap below it.
    var y = l.header.bottom;
    for (items, 0..) |_, i| {
        if (i == l.first_stashed) {
            // A hairline, then the STASHED caption at the header's padding.
            const rule_y = y + sm;
            l.section_rule = .{ .left = area.left + fill, .top = rule_y, .right = area.right - fill, .bottom = rule_y + @max(px(1, scale), 1) };
            const cap_h = toc.headerHeight(tm.caption_h, scale);
            l.stashed_caption = .{ .left = area.left, .top = rule_y + sm, .right = area.right, .bottom = rule_y + sm + cap_h };
            y = rule_y + sm + cap_h;
        }
        l.items[i] = .{ .left = area.left + fill, .top = y + half, .right = area.right - fill, .bottom = y + half + rh };
        y += rh + 2 * half;
    }
}

/// The all-windows outline's lines inside `area`, below the header (T1829;
/// Mac `PaneSidebarWindowHeader` / `PaneSidebarProjectHeader` / the outline
/// outline rows). A window head is a pane pill's height, its fill a half gap
/// clear of its neighbours as a pill is (T2311, T2340: every item one
/// height); a project head is the caption-size label centred in its
/// `project_header_dip` band (T2340), `header_gap_dip` clear outside it
/// above and below. A
/// pane row's FILL spans the panel, as a row's does; only its content is
/// indented, by one chevron and its gap per level. Items no line names - the
/// panes of a folded group - get an empty rect.
fn layoutLines(l: *Layout, area: Rect, lines: []const Line, tm: TextMetrics, scale: f32) void {
    const fill = px(toc.fill_inset_dip, scale);
    const label = px(toc.label_inset_dip, scale);
    const step = px(outline_step_dip, scale);
    const half = rowHalfGap(scale);
    const head_gap = px(header_gap_dip, scale);
    for (0..l.count) |i| {
        l.items[i] = .{};
        l.indent[i] = 0;
    }
    var y = bodyTop(l, scale);
    if (lines.len == 0) {
        // Mac's note: on the label inset, a row's padding around one line.
        l.no_match = .{ .left = area.left + label, .top = y, .right = area.right - label, .bottom = y + rowHeight(false, tm, scale) };
        return;
    }
    var prev: ?LineKind = null;
    for (lines) |ln| {
        // Clear space below a project's band, before its first window (none
        // when the project is folded: its next line is the next project).
        if (prev == .project and ln.kind != .project) y += head_gap;
        switch (ln.kind) {
            .project, .window => {
                const is_project = ln.kind == .project;
                // ...and above it, after whatever ends the list above.
                if (is_project and prev != null) y += head_gap;
                const text_h = if (is_project) tm.caption_h else tm.title_h;
                const h = if (is_project) projectHeadHeight(tm, scale) else pillHeight(tm, scale);
                if (!is_project) y += half;
                const text_top = y + @divTrunc(h - text_h, 2);
                // Not indented by its level (T2340): every head's chevron
                // in one column, grouped or not.
                const cx = area.left + label;
                if (l.head_count < max_heads) {
                    const fill_r: Rect = .{ .left = area.left + fill, .top = y, .right = area.right - fill, .bottom = y + h };
                    l.heads[l.head_count] = placeHead(if (is_project) .project else .window, ln.index, ln.depth, fill_r, cx, text_top, text_h, scale);
                    l.head_count += 1;
                }
                y += h;
                if (!is_project) y += half;
            },
            .pane => {
                if (ln.index >= l.count) continue;
                const rh = pillHeight(tm, scale);
                l.items[ln.index] = .{ .left = area.left + fill, .top = y + half, .right = area.right - fill, .bottom = y + half + rh };
                // One step under its window, whatever the window's level.
                l.indent[ln.index] = step;
                y += rh + 2 * half;
            },
        }
        prev = ln.kind;
    }
}

/// The card at `card_w` pixels wide, inside `insets` of the column (T2290):
/// the same rect in both modes but its width, so the rail and the expanded
/// list share their leading edge, top and bottom.
fn layoutCard(l: *Layout, card_w: i32, insets: RailInsets, scale: f32) void {
    const lead = insets.leadingPx(scale);
    const v = insets.verticalPx(scale);
    const min_h = px(rail_card_dip, scale);
    l.card = .{ .left = lead, .top = v, .right = lead + @max(card_w, 0), .bottom = @max(l.height - v, v + insets.reach_px + min_h) };
}

/// The rail (T2279, Mac 75dc046e3): the toggle, then one tile per pane, each
/// the row it is in the expanded list without its text - the same pill
/// (`fill_inset` in from the card), the same height, from the same top - so
/// toggling the sidebar moves no icon.
fn layoutMini(l: *Layout, tm: TextMetrics, scale: f32, insets: RailInsets) void {
    layoutCard(l, px(rail_card_dip, scale), insets, scale);
    l.toggle = toggleRect(scale, insets);
    const c = l.card;
    headerBand(l, .{ .left = c.left, .top = @min(c.top + insets.reach_px, c.bottom), .right = c.right, .bottom = c.bottom }, tm, scale);
    const fill = px(toc.fill_inset_dip, scale);
    const left = c.left + fill;
    const right = c.right - fill;
    const tile = pillHeight(tm, scale);
    const gap = rowGap(scale);
    // The first tile a half gap below the header, as the first row is.
    var y = l.header.bottom + rowHalfGap(scale);
    if (l.outline) {
        // All windows' rail opens with a + of its own above every window
        // (T2407, Mac 6bd2962eb `listContent`): the panel header's, a new
        // window, since this list is windows - in a slot a window header's
        // exact extent, as this window's rail + is (`addThisWindowHeads`).
        const extent = tile + 2 * rowHalfGap(scale);
        const b = px(row_button_dip, scale);
        const x = c.left + @divTrunc(c.width() - b, 2);
        const by = l.header.bottom + @divTrunc(extent - b, 2);
        l.rail_add = .{ .left = x, .top = by, .right = x + b, .bottom = by + b };
        y += extent;
    }
    for (0..l.count) |i| {
        // A hairline between this window's grid and its stash. In the
        // outline a window is its tiles alone (T2425, Mac 6bd2962eb): no
        // divider between one window's tiles and the next's, and a window's
        // stash just follows its grid (T2313, Mac 47b39b1cb).
        if (!l.outline and i == l.first_stashed and i != 0) {
            // The hairline sits in the middle of an `md` gap.
            const group = px(rail_group_gap_dip, scale);
            const rule_y = y - gap + @divTrunc(group, 2);
            l.section_rule = .{ .left = left, .top = rule_y, .right = right, .bottom = rule_y + @max(px(1, scale), 1) };
            y += group - gap;
        }
        l.items[i] = .{ .left = left, .top = y, .right = right, .bottom = y + tile };
        y += tile + gap;
    }
}

/// This window's header (T2324, Mac e94a9737e): the single roster is held by
/// it exactly as a window is in all windows - chevron, name, and on hover +
/// and x - with its panes and its tray one outline level in under it. On the
/// rail the header is its + alone (`rail_add`), in a slot the header's exact
/// height, so collapsing or expanding still moves no icon. `folded`: the
/// chevron folded the panes away - the panel only; the rail always shows its
/// tiles, as Mac's does. A no-op for the all-windows outline, whose heads
/// are its own. A lone window's `addThisWindowHeads`.
pub fn addThisWindowHead(l: *Layout, folded: bool, tm: TextMetrics, scale: f32) void {
    addThisWindowHeads(l, folded, null, tm, scale);
}

/// `addThisWindowHead` for a window that may be in a project group (T2350,
/// Mac 32bc9a6b5): `group` is null for a lone window, else whether its group
/// is folded. A `<project>: <name>` window's own list puts the group's header
/// above its own - laid out as the all-windows outline lays a project head
/// over its first window, `header_gap_dip` between them - and a folded group
/// shows that header alone: the window's header and its panes go with the
/// fold, as they do in all windows. The panel only; the rail is unchanged,
/// as Mac's is. Called on a fresh layout, before `addEmptyTray`.
pub fn addThisWindowHeads(l: *Layout, folded: bool, group: ?bool, tm: TextMetrics, scale: f32) void {
    if (l.mode == .hidden or l.outline) return;
    const half = rowHalfGap(scale);
    // A pane pill's height, so every item is one (T2340, Mac c4dbe30be).
    const head_h = pillHeight(tm, scale);
    // The header's whole extent in the list, its gaps included (Mac
    // `PaneSidebarWindowHeader.height`): what everything under it moves by.
    var extent = head_h + 2 * half;
    var top = l.header.bottom;
    const c = l.card;
    l.head_count = 0;
    if (l.mode == .expanded) if (group) |group_folded| {
        const fill = px(toc.fill_inset_dip, scale);
        const ph = projectHeadHeight(tm, scale);
        const text_top = top + @divTrunc(ph - tm.caption_h, 2);
        const cx = c.left + px(toc.label_inset_dip, scale);
        l.heads[0] = placeHead(.project, 0, 0, .{ .left = c.left + fill, .top = top, .right = c.right - fill, .bottom = top + ph }, cx, text_top, tm.caption_h, scale);
        l.head_count = 1;
        if (group_folded) {
            // Nothing of the window is left to show.
            for (0..l.count) |i| l.items[i] = .{};
            l.section_rule = null;
            l.stashed_caption = null;
            l.own_folded = true;
            return;
        }
        const below = ph + px(header_gap_dip, scale);
        top += below;
        extent += below;
    };
    if (l.mode == .mini) {
        const b = px(row_button_dip, scale);
        const x = c.left + @divTrunc(c.width() - b, 2);
        const y = top + @divTrunc(extent - b, 2);
        l.rail_add = .{ .left = x, .top = y, .right = x + b, .bottom = y + b };
        shiftBody(l, extent, 0);
        return;
    }
    // Laid out as `layoutLines` lays out a window head at depth 0.
    const fill = px(toc.fill_inset_dip, scale);
    const y = top + half;
    const text_top = y + @divTrunc(head_h - tm.title_h, 2);
    const cx = c.left + px(toc.label_inset_dip, scale);
    l.heads[l.head_count] = placeHead(.window, 0, @intFromBool(group != null), .{ .left = c.left + fill, .top = y, .right = c.right - fill, .bottom = y + head_h }, cx, text_top, tm.title_h, scale);
    l.head_count += 1;
    if (folded) {
        // Its panes and its tray go with the fold.
        for (0..l.count) |i| l.items[i] = .{};
        l.section_rule = null;
        l.stashed_caption = null;
        l.own_folded = true;
        return;
    }
    shiftBody(l, extent, px(outline_step_dip, scale));
}

/// Whether a window header says "This Window" (Mac `showsThisWindowTag`,
/// e94a9737e): this window's, and only among other windows - heading the
/// single roster, it is the only window there is.
pub fn showsThisWindowTag(own: bool, all_windows: bool) bool {
    return own and all_windows;
}

/// Whether a header is drawn selected (T2340, Mac c4dbe30be
/// `PaneSidebarWindowHeader.isSelected`): this window's, folded - its
/// selected pane is inside the fold, so the header carries the selection in
/// its place. A project's never is.
pub fn headSelected(kind: HeadKind, own: bool, folded: bool) bool {
    return kind == .window and own and folded;
}

/// Move the single roster's rows and its tray's hairline and caption down by
/// `dy`, the rows' content in by `indent` (one outline level, under a
/// header). The hairline stays as wide as a row's fill (T2339, Mac
/// a13bf6f43 `PaneSidebarDivider`).
fn shiftBody(l: *Layout, dy: i32, indent: i32) void {
    for (0..l.count) |i| {
        if (!l.shown(i)) continue;
        shiftDown(&l.items[i], dy);
        l.indent[i] += indent;
    }
    if (l.section_rule) |*r| shiftDown(r, dy);
    if (l.stashed_caption) |*r| shiftDown(r, dy);
}

/// Add the empty tray below the grid rows (T1844, T2276; Mac 543489bca's
/// `PaneSidebarEmptyStashSlot`): with nothing stashed, the tray is still
/// there - it is a drop target - behind the same section rule a stash would
/// have, but with no STASHED caption (T2313, Mac 82b9c5501): the well's own
/// text says what it is. The slot is a one-line row on the panel, a tile on
/// the rail. Always laid out, drag or not: at rest it says what it is for,
/// during a drag where to let go. A no-op when something is stashed or
/// nothing is shown; the outline's well is `addDragWell`'s.
pub fn addEmptyTray(l: *Layout, tm: TextMetrics, scale: f32) void {
    if (l.mode == .hidden) return;
    if (l.outline or l.own_folded) return;
    if (l.first_stashed != l.count) return;
    const sm = px(sm_dip, scale);
    const hair = @max(px(1, scale), 1);
    if (l.mode == .expanded) {
        const area = l.card;
        const fill = px(toc.fill_inset_dip, scale);
        // The last row ends a half gap below its pill.
        const below = (if (l.count > 0) l.items[l.count - 1].bottom else l.header.bottom) + rowHalfGap(scale);
        const rule_y = below + sm;
        // As wide as a row's fill, whatever the rows' level (T2339, Mac
        // a13bf6f43 `PaneSidebarDivider`).
        l.section_rule = .{ .left = area.left + fill, .top = rule_y, .right = area.right - fill, .bottom = rule_y + hair };
        // Inset like the stashed row it stands in for, with as much clear
        // space under the rule as over it - the last row's half gap and `sm`
        // (T2339, Mac a13bf6f43 `PaneSidebarDivider.bottom`).
        const top = rule_y + hair + sm + rowHalfGap(scale);
        l.drop_slot = .{ .left = area.left + fill, .top = top, .right = area.right - fill, .bottom = top + rowHeight(false, tm, scale) };
        return;
    }
    const tile = pillHeight(tm, scale);
    const group = px(rail_group_gap_dip, scale);
    const fill = px(toc.fill_inset_dip, scale);
    const left = l.card.left + fill;
    const right = l.card.right - fill;
    // The same spacing a stashed group gets: `md` below the last tile, the
    // hairline in the middle of it.
    const below = if (l.count > 0) l.items[l.count - 1].bottom else l.header.bottom;
    const rule_y = below + @divTrunc(group, 2);
    l.section_rule = .{ .left = left, .top = rule_y, .right = right, .bottom = rule_y + hair };
    const top = below + group;
    l.drop_slot = .{ .left = left, .top = top, .right = right, .bottom = top + tile };
}

/// The empty tray's well in the all-windows outline (T2313, Mac b7de64ce8):
/// there only while a pane is dragged - the list is every window's panes and
/// nothing else - and only in THIS window's group while it stashes nothing,
/// right under its last pane, with everything below opening to make room. A
/// row on the panel (none while the group is folded: there is no pane to
/// follow), a tile on the rail. The caller asks only during a drag.
pub fn addDragWell(l: *Layout, tm: TextMetrics, scale: f32) void {
    if (l.mode == .hidden or !l.outline) return;
    var last: ?usize = null;
    for (0..l.count) |i| {
        if (!l.own[i]) continue;
        // Something of this window's is stashed: its rows are the target.
        if (i >= l.first_stashed) return;
        last = i;
    }
    const k = last orelse return;
    if (!l.shown(k)) return;
    const above = l.items[k];
    // A one-line row as the single roster's well is; a tile on the rail.
    const slot_h = if (l.mode == .expanded) rowHeight(false, tm, scale) else pillHeight(tm, scale);
    const grow = slot_h + rowGap(scale);
    // Everything laid out below the last pane moves down by the well and
    // its gap; nothing above it moves.
    for (0..l.count) |i| {
        // A folded pane's empty rect stays empty (`shown` reads width).
        if (l.shown(i) and l.items[i].top > above.bottom) shiftDown(&l.items[i], grow);
    }
    for (l.heads[0..l.head_count]) |*hd| {
        if (hd.rect.top <= above.bottom) continue;
        shiftDown(&hd.rect, grow);
        shiftDown(&hd.chevron, grow);
    }
    for (l.rules[0..l.rule_count]) |*r| {
        if (r.top > above.bottom) shiftDown(r, grow);
    }
    // One pill gap below the last pane, as the next pill would sit.
    const top = above.bottom + rowGap(scale);
    l.drop_slot = .{ .left = above.left, .top = top, .right = above.right, .bottom = top + slot_h };
}

fn shiftDown(r: *Rect, dy: i32) void {
    r.top += dy;
    r.bottom += dy;
}

pub const Hit = union(enum) {
    none,
    /// The collapse/expand button (T2289).
    toggle,
    /// An item's body (row or tile).
    item: usize,
    /// An expanded row's hover stash / restore button.
    item_button: usize,
    /// An expanded row's hover x (T2280).
    item_close: usize,
    /// An expanded row's hover pencil (T2339).
    item_rename: usize,
    /// The all-windows toggle.
    scope,
    /// The header's new-window + (T2323).
    add,
    /// The all-windows search field, and its clear button (T1877).
    search,
    search_clear,
    /// An outline header's body (an index into the layout's heads).
    head: usize,
    /// An outline header's chevron column: fold, never raise.
    head_fold: usize,
    /// An outline header's hover x (T2298).
    head_close: usize,
    /// An outline header's hover + (T2323).
    head_add: usize,
    /// An outline header's hover pencil (T2339).
    head_rename: usize,
    /// The rail's + in this window's header slot (T2324).
    rail_add,
};

/// The hover once it is asked again from where the pointer really is (T2341,
/// Mac 8faf92148 `HoverTrackingView.pointerLocation`). A window brought
/// forward over this one - a row clicked through to its window - sends no
/// leave, so the hover is re-read as the windows change places. `under` is
/// whether the topmost window at the pointer IS the column: another window in
/// front there, or no readable cursor, reads as off it. `there` is what the
/// pointer is over when it is. A held item, edge or thumb keeps every hover as
/// it is (T2337, Mac `isHeld`).
pub fn resyncedHover(current: Hit, held: bool, under: bool, there: Hit) Hit {
    if (held) return current;
    return if (under) there else .none;
}

pub fn hitTest(l: *const Layout, x: i32, y: i32, scale: f32) Hit {
    if (l.mode == .hidden) return .none;
    if (l.toggle.contains(x, y)) return .toggle;
    const rows = l.mode == .expanded;
    if (rows and l.scope.contains(x, y)) return .scope;
    if (rows and l.add.contains(x, y)) return .add;

    if (rows and l.search.contains(x, y)) {
        return if (l.search_text and l.search_clear.contains(x, y)) .search_clear else .search;
    }
    // Below the controls everything scrolls (T1878): what the scroll moved
    // out of the viewport is out of reach, whatever its rect says.
    if (l.viewport.height() > 0 and !l.viewport.contains(x, y)) return .none;
    if (l.rail_add.contains(x, y)) return .rail_add;

    for (l.heads[0..l.head_count], 0..) |hd, k| {
        const hit_r = rowHitRect(l, hd.rect);
        if (!hit_r.contains(x, y)) continue;
        if (rows and l.headClose(k, scale).contains(x, y)) return .{ .head_close = k };
        if (rows and l.headAdd(k, scale).contains(x, y)) return .{ .head_add = k };
        if (rows and l.headRename(k, scale).contains(x, y)) return .{ .head_rename = k };
        return if (x < hd.label_x) .{ .head_fold = k } else .{ .head = k };
    }
    for (0..l.count) |i| {
        if (!l.shown(i)) continue;
        const hit_r = rowHitRect(l, l.items[i]);
        if (!hit_r.contains(x, y)) continue;
        if (rows and l.rowClose(i, scale).contains(x, y)) return .{ .item_close = i };
        if (rows and l.rowButton(i, scale).contains(x, y)) return .{ .item_button = i };
        if (rows and l.rowRename(i, scale).contains(x, y)) return .{ .item_rename = i };
        return .{ .item = i };
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Edge drag (T1846; Mac `PaneSidebarChrome.resizeHandle`)

/// The resize handle's grab band (Mac `SidePanelResizeHandle.grabWidth`).
pub const grab_dip: f32 = 7;
/// An expanded panel's edge pushed in short of this tucks it back into the
/// rail; between this and `min_width_dip` it stops at its minimum (T2299,
/// Mac 543489bca `expandThreshold`).
pub const expand_threshold_dip: f32 = 120;

/// Whether (`x`, `y`) is on the edge that drags, in the flat style. Like
/// every resizer it is never over a pane (T2125, Mac 2811a3043
/// `resizeHandleOffset`), and never over the card (T2290/T2299, Mac
/// 543489bca `edgeGrip`): in both modes the band is the card's own trailing
/// margin - the gutter between the card and the panes - so a press on a
/// rail tile is always the tile's.
pub fn onEdge(l: *const Layout, x: i32, y: i32, scale: f32) bool {
    return onEdgeIn(l, x, y, scale, false);
}

/// `onEdge` in either pane style. Elevated, the grip is not in the sidebar
/// at all (T2265, Mac a81db68f9 `pinnedEdgeGrip`; the rail's since T2299):
/// it is the whole gutter between the card and the panes - the grid's
/// margin, which is the window's (`pinnedGripInGutter`) - so nothing in this
/// window drags.
pub fn onEdgeIn(l: *const Layout, x: i32, y: i32, scale: f32, elevated: bool) bool {
    const band = edgeBand(l, scale, elevated) orelse return false;
    if (!band.contains(x, y)) return false;
    return !onButton(l, x, y, scale);
}

/// The band in this window that drags the edge - where its accent bar shows
/// (T2265, Mac `SidePanelResizeHandle.gutterBar`) - or null when it has none.
/// The same in both modes (Mac `edgeGrip`): the rail's card and the panel's
/// end at the same inset.
pub fn edgeBand(l: *const Layout, scale: f32, elevated: bool) ?Rect {
    const g = @max(px(grab_dip, scale), 1);
    if (l.mode == .hidden or pinnedGripInGutter(elevated)) return null;
    return .{ .left = l.card.right, .top = l.card.top, .right = @max(l.width, l.card.right + g), .bottom = l.card.bottom };
}

/// Whether the sidebar's grip is the gutter beside it rather than a band
/// inside its column (Mac `PaneSidebarState.edgeGrip`), in either mode:
/// elevated, the grid's margin lies between the card and the panes and every
/// resizer lives in a gutter; flat, the grid starts right at the column's
/// edge and the card's own trailing margin is the gutter.
pub fn pinnedGripInGutter(elevated: bool) bool {
    return elevated;
}

/// The header's and the rows' buttons sit `sm` from the panel's edge, inside
/// the band: a press on one of them is that button's, never a resize.
fn onButton(l: *const Layout, x: i32, y: i32, scale: f32) bool {
    if (l.toggle.contains(x, y) or l.scope.contains(x, y) or l.add.contains(x, y)) return true;
    for (0..l.count) |i| {
        if (l.shown(i) and (l.rowClose(i, scale).contains(x, y) or l.rowButton(i, scale).contains(x, y) or
            l.rowRename(i, scale).contains(x, y))) return true;
    }
    for (0..l.head_count) |k| {
        if (l.headClose(k, scale).contains(x, y) or l.headAdd(k, scale).contains(x, y) or
            l.headRename(k, scale).contains(x, y)) return true;
    }
    return false;
}

/// What an edge drag measures from (Mac `currentWidth`): the rail's card,
/// or the expanded panel.
pub fn edgeStartDip(m: Mode, panel_w_dip: f32) f32 {
    return if (m == .mini) rail_card_dip else clampWidth(panel_w_dip);
}

/// What an edge drag makes of the sidebar (Mac `edgeDrag`'s pair).
pub const EdgeDrag = struct {
    expanded: bool,
    /// The panel's new preferred width, already clamped; null leaves it.
    width: ?f32 = null,
};

/// An edge drag `dx_dip` from where it started at `start_dip`, with the
/// sidebar in mode `m` NOW (T2299, Mac 543489bca `edgeDrag`): past the
/// panel's minimum, expanded at that width (clamped); short of
/// `expand_threshold_dip`, the rail; between the two, what it already is -
/// expanded at its minimum, or still the rail. So the rail comes out by its
/// gutter once the panel would fit, and the panel tucks back into the rail
/// when pushed well under its minimum, both within one drag and both ways,
/// with a band between where neither flickers. Null when hidden.
pub fn edgeDrag(m: Mode, start_dip: f32, dx_dip: f32) ?EdgeDrag {
    if (m == .hidden) return null;
    const proposed = start_dip + dx_dip;
    if (proposed >= min_width_dip) return .{ .expanded = true, .width = clampWidth(proposed) };
    if (proposed < expand_threshold_dip) return .{ .expanded = false };
    return if (m == .expanded) .{ .expanded = true, .width = min_width_dip } else .{ .expanded = false };
}

/// How far past the panes it has tucked into strips a gutter of a row
/// spanning the grid is pushed before the expanded panel tucks into its rail
/// (T2277, Mac 075d787d1 `dividerTuckGive`): what the panel would give before
/// reaching its minimum, as a pane gives down to its own - kept between a
/// nudge and a deliberate push.
pub fn dividerTuckGiveDip(panel_w_dip: f32) f32 {
    return @min(@max(clampWidth(panel_w_dip) - min_width_dip, 24), 80);
}

/// Dragged back, the panel comes back out this far past where it tucked, so
/// the edge never flickers at one point (Mac `dividerTuckHysteresis`).
pub const divider_tuck_hysteresis_dip: f32 = 24;

/// Rows span to the card's edges for hit purposes - the fill inset is
/// paint, and a click in it still means that row; the margin round the card
/// is nobody's (Mac `PaneSidebarHostView`: clicks land only on the drawn
/// card). A rail tile is just its square.
fn rowHitRect(l: *const Layout, r: Rect) Rect {
    if (l.mode == .expanded) return .{ .left = l.card.left, .top = r.top, .right = l.card.right, .bottom = r.bottom };
    return r;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const scroll = @import("pane_sidebar_scroll.zig");
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "pane_sidebar: mode follows pin, hidden and the narrow-window fallback" {
    try testing.expectEqual(Mode.hidden, mode(true, true, 1200));
    try testing.expectEqual(Mode.hidden, mode(false, true, 1200));
    try testing.expectEqual(Mode.expanded, mode(true, false, 720));
    try testing.expectEqual(Mode.mini, mode(true, false, 719));
    try testing.expectEqual(Mode.mini, mode(false, false, 1200));
}

test "pane_sidebar: the rail column is Mac's 76 (T2279: a row's pill and its insets), and the panel width is clamped" {
    try testing.expectEqual(@as(f32, 76), railColumnDip());
    try testing.expectEqual(@as(f32, 0), columnDip(.hidden, 240));
    try testing.expectEqual(@as(f32, 76), columnDip(.mini, 240));
    // Expanded is the card at the panel's width in the rail's own insets
    // (T2290, Mac 0a547522d `columnWidth`): 12 + 240 + 12.
    try testing.expectEqual(@as(f32, 264), columnDip(.expanded, 240));
    try testing.expectEqual(@as(f32, 204), columnDip(.expanded, 50));
    try testing.expectEqual(@as(f32, 404), columnDip(.expanded, 900));
    try testing.expectEqual(@as(f32, 240), cardDip(.expanded, 240));
    try testing.expectEqual(rail_card_dip, cardDip(.mini, 240));
    // The rail card is a row's pill around its icon: 8 + 10 + 16 + 10 + 8.
    try testing.expectEqual(@as(f32, 52), rail_card_dip);
    try testing.expectEqual(@as(i32, 95), columnPx(.mini, 240, 1.25));
    try testing.expectEqual(@as(i32, 330), columnPx(.expanded, 240, 1.25));
}

test "pane_sidebar: displayTitle falls back from the ghost to the directory, then the kind" {
    try testing.expectEqualStrings("zsh", displayTitle("zsh", "/tmp", "Terminal"));
    try testing.expectEqualStrings("ghoztty", displayTitle(placeholder_title, "D:\\git\\ghoztty", "Terminal"));
    try testing.expectEqualStrings("ghoztty", displayTitle(null, "D:\\git\\ghoztty\\", "Terminal"));
    try testing.expectEqualStrings("Terminal", displayTitle("  ", null, "Terminal"));
}

test "pane_sidebar: bannerLine strips markdown and skips layout lines" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Building the sidebar", bannerLine("**Building** the `sidebar`", &buf).?);
    try testing.expectEqualStrings("see docs here", bannerLine("| a | b |\n---\nsee [docs](https://x) here", &buf).?);
    try testing.expectEqualStrings("done", bannerLine("- [x] done\\nnext", &buf).?);
    try testing.expectEqualStrings("snake_case stays", bannerLine("_snake_case stays_", &buf).?);
    try testing.expect(bannerLine(null, &buf) == null);
    try testing.expect(bannerLine("\n  \n", &buf) == null);
    // A heading line is its text (T2085).
    try testing.expectEqualStrings("Fix strip labels", bannerLine("## Fix strip labels\n|  |  |\n|---|---|", &buf).?);
}

// Banner title (T2085, Mac PaneSidebarTextTests).

/// What the banner hook writes on its CLI path, verbatim.
const hook_banner = "## Strip label from banner title\n|  |  |\n|---|---|\n" ++
    "| **Goal** | Minimized pane strips show the banner title |\n| **Status** | Reading code \u{00B7} Working |";

fn expectTitle(want: ?[]const u8, banner: ?[]const u8) !void {
    var buf: [256]u8 = undefined;
    const got = bannerTitle(banner, &buf);
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(w, got.?);
    } else if (got) |g| {
        std.debug.print("expected no title for {?s}, got \"{s}\"\n", .{ banner, g });
        return error.TestUnexpectedResult;
    }
}

test "pane_sidebar: the hook's heading is the banner title" {
    try expectTitle("Strip label from banner title", hook_banner);
    try expectTitle("Fix strip labels", "## Fix strip labels\n|  |  |\n|---|---|\n| **Status** | Working |");
}

test "pane_sidebar: the hook's OSC line gives its bold title" {
    try expectTitle("Fix strip labels", "**Fix strip labels** \u{00B7} **Goal:** Label strips \u{00B7} **Status:** Working");
    try expectTitle("Fix strip labels", "**Fix strip labels**");
}

test "pane_sidebar: a banner without a title has none" {
    // The hook with no title set: just its table, or its OSC labels.
    try expectTitle(null, "|  |  |\n|---|---|\n| **Prompt** | do the thing |\n| **Status** | Idle |");
    try expectTitle(null, "**Prompt:** do the thing \u{00B7} **Status:** Idle");
    // Prose, even prose that opens in bold, names no title.
    try expectTitle(null, "Deploying to staging");
    try expectTitle(null, "**PR #123** \u{2014} _3 files_, +120/\u{2212}45");
    try expectTitle(null, "**PR** [#12](https://example.com/12)");
    // A bold line heads a multi-line banner only as a label.
    try expectTitle(null, "**Last result**\n- [x] Fixed it");
    // A heading counts only on the first line.
    try expectTitle(null, "Status: ok\n## Later");
    try expectTitle(null, null);
    try expectTitle(null, "  \n ");
    // A bold label standing alone is still a label.
    try expectTitle(null, "**Goal:**");
}

test "pane_sidebar: a banner heading needs its space and text" {
    try expectTitle(null, "##Title");
    try expectTitle(null, "## ");
    try expectTitle(null, "####### Seven");
    try expectTitle("One", "# One");
    try expectTitle("Six", "###### Six");
}

test "pane_sidebar: the banner title is plain text" {
    try expectTitle("Fix the strip label now", "## **Fix** the `strip` [label](https://example.com) _now_");
    try expectTitle("Ship v2", "**Ship `v2`** \u{00B7} **Status:** ok");
    try expectTitle("Escaped * star", "## Escaped \\* star");
    try expectTitle("Keep some_tool", "## Keep some_tool");
}

test "pane_sidebar: a literal backslash-n is a line break for the banner title" {
    try expectTitle("Title", "## Title\\n| a | b |");
    // ...and so splits a bold run's banner into two lines, which is no title.
    try expectTitle(null, "**Title**\\nmore");
}

test "pane_sidebar: the banner title names the pane" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Strip label from banner title", paneLabel("\u{2733} Claude Code", "C:\\tmp", "Terminal", hook_banner, false, &buf));
}

test "T2339: a name the user gave the pane outranks its banner title (Mac a13bf6f43 label(userTitle:))" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("build box", paneLabel("build box", "C:\\tmp", "Terminal", hook_banner, true, &buf));
    // Not user-set: the banner's title still names it.
    try testing.expectEqualStrings("Strip label from banner title", paneLabel("build box", "C:\\tmp", "Terminal", hook_banner, false, &buf));
    // A blank user title names nothing: the usual order takes over.
    try testing.expectEqualStrings("Strip label from banner title", paneLabel("  ", "C:\\tmp", "Terminal", hook_banner, true, &buf));
    try testing.expectEqualStrings("proj", paneLabel(null, "C:\\tmp\\proj", "Terminal", null, true, &buf));
}

test "pane_sidebar: without a banner title the pane title names it" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("\u{2733} Claude Code", paneLabel("\u{2733} Claude Code", "C:\\tmp", "Terminal", null, false, &buf));
    try testing.expectEqualStrings("\u{2733} Claude Code", paneLabel("\u{2733} Claude Code", "C:\\tmp", "Terminal", "|  |  |\n|---|---|\n| **Status** | Idle |", false, &buf));
    try testing.expectEqualStrings("proj", paneLabel(placeholder_title, "C:\\tmp\\proj", "Terminal", "Just prose", false, &buf));
}

test "pane_sidebar: a titled banner leaves the subtitle to the directory" {
    var buf: [256]u8 = undefined;
    // The title already names the row; repeating it as the subtitle says
    // nothing - the caller falls through to the working directory.
    try testing.expect(bannerSubtitle(hook_banner, &buf) == null);
    // An untitled banner's first line is still the subtitle.
    try testing.expectEqualStrings("Relay cutover", bannerSubtitle("**Relay** cutover", &buf).?);
    try testing.expect(bannerSubtitle(null, &buf) == null);
}

test "pane_sidebar: distinct drops a subtitle that repeats the title" {
    try testing.expect(distinct("zsh", "zsh ") == null);
    try testing.expectEqualStrings("~/git", distinct("~/git", "zsh").?);
    try testing.expect(distinct(null, "zsh") == null);
}

test "pane_sidebar: samePath ignores case, separator style and a trailing slash" {
    try testing.expect(samePath("C:\\Users\\Ann", "c:/users/ann/"));
    try testing.expect(!samePath("C:\\Users\\Ann", "C:\\Users\\Annie"));
    try testing.expect(!samePath("", ""));
}

test "pane_sidebar: abbreviatePath folds the profile directory to ~" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("~\\git\\x", abbreviatePath("C:\\Users\\Ann\\git\\x", "C:\\Users\\Ann", &buf));
    try testing.expectEqualStrings("~", abbreviatePath("c:\\users\\ann", "C:\\Users\\Ann\\", &buf));
    try testing.expectEqualStrings("C:\\Users\\Annie", abbreviatePath("C:\\Users\\Annie", "C:\\Users\\Ann", &buf));
    try testing.expectEqualStrings("D:\\x", abbreviatePath("D:\\x", null, &buf));
}

const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

const TestView = struct {
    label: []const u8,
    stash_seq: u64 = 0,

    pub fn ref(self: *TestView, alloc: std.mem.Allocator) std.mem.Allocator.Error!*TestView {
        _ = alloc;
        return self;
    }
    pub fn unref(self: *TestView, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
    pub fn splitTreeLabel(self: *const TestView) []const u8 {
        return self.label;
    }
    pub fn paneId(self: *const TestView) []const u8 {
        return self.label;
    }
};

test "pane_sidebar: the ordered roster draws the grid in the sidebar's order and leaves the stash alone" {
    const Tree = SplitTree(TestView);
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var d: TestView = .{ .label = "D" };
    var ta = try Tree.init(alloc, &a);
    defer ta.deinit();
    var tb = try Tree.init(alloc, &b);
    defer tb.deinit();
    var tc = try Tree.init(alloc, &c);
    defer tc.deinit();
    var td = try Tree.init(alloc, &d);
    defer td.deinit();
    var cd = try tc.split(alloc, .root, .right, 0.5, &td);
    defer cd.deinit();
    var bcd = try tb.split(alloc, .root, .right, 0.5, &cd);
    defer bcd.deinit();
    var tree = try ta.split(alloc, .root, .right, 0.5, &bcd);
    defer tree.deinit();

    // A | B | C | D with D stashed; the order puts C first and knows D's
    // place, which the stash section does not follow.
    d.stash_seq = 3;
    var out: [8]*TestView = undefined;
    const n = rosterOrdered(tree, &.{ "C", "D", "A", "B" }, &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("C", out[0].label);
    try testing.expectEqualStrings("A", out[1].label);
    try testing.expectEqualStrings("B", out[2].label);
    try testing.expectEqualStrings("D", out[3].label);

    // An empty order is the plain roster.
    const m = rosterOrdered(tree, &.{}, &out);
    try testing.expectEqual(@as(usize, 4), m);
    try testing.expectEqualStrings("A", out[0].label);
}

test "pane_sidebar: roster lists grid panes in tree order, then the stash newest first" {
    const Tree = SplitTree(TestView);
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var d: TestView = .{ .label = "D" };
    var ta = try Tree.init(alloc, &a);
    defer ta.deinit();
    var tb = try Tree.init(alloc, &b);
    defer tb.deinit();
    var tc = try Tree.init(alloc, &c);
    defer tc.deinit();
    var td = try Tree.init(alloc, &d);
    defer td.deinit();
    var cd = try tc.split(alloc, .root, .down, 0.5, &td);
    defer cd.deinit();
    var bcd = try tb.split(alloc, .root, .right, 0.5, &cd);
    defer bcd.deinit();
    var tree = try ta.split(alloc, .root, .right, 0.5, &bcd);
    defer tree.deinit();

    // A | B | (C / D); stash D, then B: the stash reads B (newest) then D.
    d.stash_seq = 5;
    b.stash_seq = 9;
    var out: [8]*TestView = undefined;
    const n = roster(tree, &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("A", out[0].label);
    try testing.expectEqualStrings("C", out[1].label);
    try testing.expectEqualStrings("B", out[2].label);
    try testing.expectEqualStrings("D", out[3].label);

    // A full buffer stops cleanly rather than overrunning.
    var small: [2]*TestView = undefined;
    try testing.expectEqual(@as(usize, 2), roster(tree, &small));
}

test "pane_sidebar: rail tiles are centered in the card from one inset, at every scale" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .grid }, .{ .section = .stashed } };
    for (scales) |s| {
        const w = columnPx(.mini, 240, s);
        const l = layout(.mini, w, px(600, s), &items, .{ .title_h = 19, .caption_h = 16 }, s);
        try testing.expectEqual(@as(usize, 3), l.count);
        try testing.expectEqual(@as(usize, 2), l.first_stashed);
        // Left and right clearances inside the card are equal: a row's fill
        // inset (T2279).
        const left = l.items[0].left - l.card.left;
        const right = l.card.right - l.items[0].right;
        try testing.expect(@abs(left - right) <= 1);
        try testing.expectEqual(px(toc.fill_inset_dip, s), left);
        // The toggle is centred on the same column.
        try testing.expect(@abs(l.items[0].centerX() - l.toggle.centerX()) <= 1);
        // Nothing touches: sm under the toggle, the rows' hairline between
        // consecutive tiles.
        const sm = px(sm_dip, s);
        try testing.expect(l.items[0].top - l.toggle.bottom >= sm);
        try testing.expect(l.items[1].top - l.items[0].bottom >= rowGap(s));
        // The section hairline sits strictly between the groups.
        const rule = l.section_rule.?;
        try testing.expect(rule.top >= l.items[1].bottom and rule.bottom <= l.items[2].top);
        // The card keeps the rail margin from the column's edges.
        try testing.expectEqual(px(rail_margin_dip, s), l.card.left);
        try testing.expectEqual(w - px(rail_margin_dip, s), l.card.right);
    }
}

test "T1850: the elevated rail takes the panes' margin leading, top and bottom, and none trailing" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
    const ins = railInsets(true);
    // Mac: 10 + 52 + 0 (T2279).
    try testing.expectEqual(@as(f32, 62), railColumnDipFor(true));
    try testing.expectEqual(@as(f32, 76), railColumnDipFor(false));
    // Mac: 10 + 240 + 0 - the card in the rail's insets (T2290).
    try testing.expectEqual(@as(f32, 250), columnDipFor(.expanded, 240, true));
    for (scales) |s| {
        const w = columnPxFor(.mini, 240, s, true);
        const h = px(600, s);
        const margin = px(pane_elevation.MARGIN_DIP, s);
        const l = layoutIn(.mini, w, h, &items, null, tm, s, ins);
        // The window edge to the card is the margin the grid keeps from it.
        try testing.expectEqual(margin, l.card.left);
        try testing.expectEqual(margin, l.card.top);
        try testing.expectEqual(h - margin, l.card.bottom);
        // Flush with the column's trailing edge: the grid's own margin is
        // the gap between the rail and the panes, so the two gutters match.
        try testing.expectEqual(w, l.card.right);
        try testing.expectEqual(px(rail_card_dip, s), l.card.width());
        // Tiles stay centered in the card.
        try testing.expect(@abs((l.items[0].left - l.card.left) - (l.card.right - l.items[0].right)) <= 1);
        // Nothing in the card grabs: the grip is the window's gutter beyond
        // it (T2299, Mac 543489bca `edgeGrip`).
        try testing.expect(edgeBand(&l, s, true) == null);
        try testing.expect(!onEdgeIn(&l, w - 1, l.card.centerY(), s, true));

        // The panel's toggle is the rail's, in this style too (T2289).
        const e = layoutIn(.expanded, px(240, s), h, &items, null, tm, s, ins);
        try testing.expectEqual(l.toggle, e.toggle);
    }
    // Flat: the card margin either side of the 52 DIP card.
    for (scales) |s| {
        try testing.expectEqual(px(76, s), columnPx(.mini, 240, s));
    }
}

test "T2289: the toggle is the rail's first item and the panel header's first item, on the same pixels" {
    const items = [_]Item{ .{ .section = .grid, .two_line = true }, .{ .section = .grid }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        const h = px(600, s);
        for ([_]bool{ false, true }) |elev| {
            for ([_]i32{ 0, px(36, s) }) |reach| {
                var ins = railInsets(elev);
                ins.reach_px = reach;
                const rail = layoutIn(.mini, columnPxFor(.mini, 240, s, elev), h, &items, null, tm, s, ins);
                const panel = layoutIn(.expanded, px(240, s), h, &items, null, tm, s, ins);
                // Toggling never moves it under the pointer.
                try testing.expectEqual(rail.toggle, panel.toggle);
                try testing.expectEqual(toggleRect(s, ins), rail.toggle);
                // Centred on the rail card, the standard icon button.
                try testing.expect(@abs((rail.toggle.left - rail.card.left) - (rail.card.right - rail.toggle.right)) <= 1);
                try testing.expectEqual(px(button_dip, s), rail.toggle.width());
                // First: above every tile, and left of everything in the
                // header - the caption starts past it, the other buttons sit
                // at the trailing edge on its row.
                try testing.expect(rail.toggle.bottom < rail.items[0].top);
                try testing.expect(panel.caption_x > panel.toggle.right);
                try testing.expect(panel.scope.left > panel.caption_x);
                try testing.expectEqual(panel.toggle.centerY(), panel.scope.centerY());
                // Inside the header band, which the rows start under.
                try testing.expect(panel.toggle.top >= panel.header.top and panel.toggle.bottom <= panel.header.bottom);
                try testing.expect(panel.items[0].top >= panel.header.bottom);
                // Below the tab strip it reaches up beside (T1900).
                try testing.expect(panel.toggle.top >= reach);
            }
        }
    }
}

test "T2290: expanded is the rail's card, wider - same leading edge, top and bottom, in the same insets" {
    const items = [_]Item{ .{ .section = .grid, .two_line = true }, .{ .section = .grid }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        const h = px(600, s);
        for ([_]bool{ false, true }) |elev| {
            for ([_]i32{ 0, px(36, s) }) |reach| {
                var ins = railInsets(elev);
                ins.reach_px = reach;
                const rail = layoutIn(.mini, columnPxFor(.mini, 240, s, elev), h, &items, null, tm, s, ins);
                const w = columnPxFor(.expanded, 240, s, elev);
                var panel = layoutIn(.expanded, w, h, &items, null, tm, s, ins);
                // One card: only its width differs.
                try testing.expectEqual(rail.card.left, panel.card.left);
                try testing.expectEqual(rail.card.top, panel.card.top);
                try testing.expectEqual(rail.card.bottom, panel.card.bottom);
                try testing.expectEqual(px(240, s), panel.card.width());
                // The column is the card plus the rail's own insets.
                try testing.expectEqual(w - ins.trailingPx(s), panel.card.right);
                // Everything the list lays out sits inside the card.
                try testing.expect(panel.header.left >= panel.card.left and panel.header.right <= panel.card.right);
                try testing.expect(panel.scope.right <= panel.card.right);
                for (0..panel.count) |i| {
                    try testing.expect(panel.items[i].left >= panel.card.left and panel.items[i].right <= panel.card.right);
                }
                // So does the empty tray, and the scrolled region.
                const no_stash = [_]Item{ .{ .section = .grid }, .{ .section = .grid } };
                var tray = layoutIn(.expanded, w, h, &no_stash, null, tm, s, ins);
                addEmptyTray(&tray, tm, s);
                const slot = tray.drop_slot.?;
                try testing.expect(slot.left >= tray.card.left and slot.right <= tray.card.right);
                const vp = scroll.viewportOf(&panel, s);
                try testing.expect(vp.left >= panel.card.left and vp.right <= panel.card.right and vp.bottom <= panel.card.bottom);
                panel.viewport = vp;
            }
        }
    }
}

test "T2279: a rail tile is its row without the text - same pill, same height, same place - so toggling moves no icon" {
    const items = [_]Item{ .{ .section = .grid, .two_line = true }, .{ .section = .grid }, .{ .section = .grid } };
    for (scales) |s| {
        for ([_]TextMetrics{ .{ .title_h = px(19, s), .caption_h = px(16, s) }, .{ .title_h = px(16, s), .caption_h = px(14, s) } }) |tm| {
            const h = px(600, s);
            for ([_]bool{ false, true }) |elev| {
                for ([_]i32{ 0, px(36, s) }) |reach| {
                    var ins = railInsets(elev);
                    ins.reach_px = reach;
                    const rail = layoutIn(.mini, columnPxFor(.mini, 240, s, elev), h, &items, null, tm, s, ins);
                    const panel = layoutIn(.expanded, columnPxFor(.expanded, 240, s, elev), h, &items, null, tm, s, ins);
                    for (0..items.len) |i| {
                        const t = rail.items[i];
                        const r = panel.items[i];
                        // The same pill: from the same leading edge, the
                        // same top and the same height - so its icon,
                        // `text_inset` into it and centred on it, is on the
                        // same pixels in both modes.
                        try testing.expectEqual(r.left, t.left);
                        try testing.expectEqual(r.top, t.top);
                        try testing.expectEqual(r.height(), t.height());
                        // Mac's one row height, whatever the row holds.
                        try testing.expectEqual(pillHeight(tm, s), t.height());
                        // The tile is the icon with a row's text inset either
                        // side of it: the rail card is exactly that pill.
                        const icon = px(icon_dip, s);
                        const inset = px(toc.text_inset_dip, s);
                        try testing.expect(@abs(t.width() - (icon + 2 * inset)) <= 1);
                    }
                    // Rows a hairline apart in both.
                    try testing.expectEqual(rail.items[0].bottom + rowGap(s), rail.items[1].top);
                    try testing.expectEqual(panel.items[0].bottom + rowGap(s), panel.items[1].top);
                    // And they scroll from the same line.
                    try testing.expectEqual(scroll.viewportOf(&panel, s).top, scroll.viewportOf(&rail, s).top);
                }
            }
        }
        // At Mac's sizes the row is Mac's 32 (a 28 pill and its 4 gap,
        // T2340, Mac c4dbe30be).
        try testing.expectEqual(px(row_dip, s), pillHeight(.{ .title_h = px(14, s), .caption_h = px(12, s) }, s) + rowGap(s));
    }
}

test "T2289: a window too narrow for the panel cannot expand, and its rail stands in" {
    try testing.expect(canExpand(narrow_window_dip));
    try testing.expect(!canExpand(narrow_window_dip - 1));
    try testing.expectEqual(Mode.mini, mode(true, false, narrow_window_dip - 1));
    try testing.expectEqual(Mode.expanded, mode(true, false, narrow_window_dip));
}

test "pane_sidebar: expanded rows stack under the header, with the STASHED caption between sections" {
    const items = [_]Item{ .{ .section = .grid, .two_line = true }, .{ .section = .grid }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        const w = px(240, s);
        const l = layout(.expanded, w, px(600, s), &items, tm, s);
        // The header's buttons keep sm clear of the band, and the last one
        // sits sm in from the trailing edge.
        const sm = px(sm_dip, s);
        try testing.expect(l.toggle.top - l.header.top >= sm and l.header.bottom - l.toggle.bottom >= sm);
        try testing.expectEqual(l.card.right - sm, l.scope.right);
        // Rows are below the header, in order, without overlap.
        try testing.expect(l.items[0].top >= l.header.bottom);
        try testing.expect(l.items[1].top >= l.items[0].bottom);
        // Every pane row is one height, one line or two (T2279, Mac
        // `PaneSidebarRow.height`).
        try testing.expectEqual(l.items[0].height(), l.items[1].height());
        try testing.expectEqual(pillHeight(tm, s), l.items[0].height());
        const cap = l.stashed_caption.?;
        try testing.expect(cap.top >= l.items[1].bottom and l.items[2].top >= cap.bottom);
        // The hover x sits inside its row, sm from the trailing edge, and
        // the stash button 4 DIP before it (T2280).
        const x = l.rowClose(0, s);
        try testing.expectEqual(l.items[0].right - sm, x.right);
        try testing.expect(x.top >= l.items[0].top and x.bottom <= l.items[0].bottom);
        const b = l.rowButton(0, s);
        try testing.expectEqual(x.left - px(row_button_gap_dip, s), b.right);
        try testing.expectEqual(x.width(), b.width());
        try testing.expectEqual(x.top, b.top);
    }
}

test "pane_sidebar: hit testing finds the toggle, rows, row buttons and nothing" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    const s: f32 = 1.0;
    const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
    const l = layout(.expanded, 240, 600, &items, tm, s);
    try testing.expectEqual(Hit.toggle, hitTest(&l, l.toggle.centerX(), l.toggle.centerY(), s));
    // A row is hit across the card; the margin round the card is nobody's.
    try testing.expectEqual(Hit{ .item = 0 }, hitTest(&l, l.card.left + 2, l.items[0].centerY(), s));
    try testing.expectEqual(Hit.none, hitTest(&l, l.card.left - 2, l.items[0].centerY(), s));
    try testing.expectEqual(Hit.none, hitTest(&l, l.card.right + 2, l.items[0].centerY(), s));
    const b = l.rowButton(1, s);
    try testing.expectEqual(Hit{ .item_button = 1 }, hitTest(&l, b.centerX(), b.centerY(), s));
    const x = l.rowClose(1, s);
    try testing.expectEqual(Hit{ .item_close = 1 }, hitTest(&l, x.centerX(), x.centerY(), s));
    try testing.expectEqual(Hit.none, hitTest(&l, 100, 590, s));

    const rail = layout(.mini, columnPx(.mini, 240, s), 600, &items, tm, s);
    try testing.expectEqual(Hit{ .item = 1 }, hitTest(&rail, rail.items[1].centerX(), rail.items[1].centerY(), s));
    try testing.expectEqual(Hit.toggle, hitTest(&rail, rail.toggle.centerX(), rail.toggle.centerY(), s));

    const hidden = layout(.hidden, 0, 600, &items, tm, s);
    try testing.expectEqual(Hit.none, hitTest(&hidden, 0, 0, s));
}

test "pane_sidebar: this window's header holds the single roster, its panes one level in (T2324)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .grid, .two_line = true }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        const bare = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        var l = bare;
        addThisWindowHead(&l, false, tm, s);
        try testing.expectEqual(@as(usize, 1), l.head_count);
        const hd = l.heads[0];
        try testing.expectEqual(HeadKind.window, hd.kind);
        // Straight under the header band, a half gap clear, a pane pill's
        // height (T2340: every item one height).
        try testing.expectEqual(l.header.bottom + rowHalfGap(s), hd.rect.top);
        try testing.expectEqual(pillHeight(tm, s), hd.rect.height());
        try testing.expectEqual(l.items[0].height(), hd.rect.height());
        // Everything under it moves down by its whole extent, and the rows
        // in by one outline level; the tray's hairline keeps a row's fill
        // width (T2339, Mac a13bf6f43) and the caption just moves down.
        const extent = pillHeight(tm, s) + rowGap(s);
        for (0..items.len) |i| {
            try testing.expectEqual(bare.items[i].top + extent, l.items[i].top);
            try testing.expectEqual(bare.items[i].left, l.items[i].left);
            try testing.expectEqual(px(outline_step_dip, s), l.indent[i]);
        }
        try testing.expectEqual(bare.section_rule.?.top + extent, l.section_rule.?.top);
        try testing.expectEqual(bare.section_rule.?.left, l.section_rule.?.left);
        try testing.expectEqual(bare.stashed_caption.?.top + extent, l.stashed_caption.?.top);
        // The first row sits under the header as a pill under a pill.
        try testing.expectEqual(hd.rect.bottom + rowGap(s), l.items[0].top);
        // Its hover + and x hit, and the chevron folds.
        const a = l.headAdd(0, s);
        try testing.expectEqual(Hit{ .head_add = 0 }, hitTest(&l, a.centerX(), a.centerY(), s));
        const x = l.headClose(0, s);
        try testing.expectEqual(Hit{ .head_close = 0 }, hitTest(&l, x.centerX(), x.centerY(), s));
        try testing.expectEqual(Hit{ .head_fold = 0 }, hitTest(&l, hd.chevron.centerX(), hd.chevron.centerY(), s));
        try testing.expectEqual(Hit{ .head = 0 }, hitTest(&l, hd.label_x + px(4, s), hd.rect.centerY(), s));
        try testing.expectEqual(Rect{}, l.rail_add);
        // Its window icon sits in its panes' icon column (T2340, Mac
        // 28f6cde09), its name in their titles' column.
        const pane_icon = l.items[0].left + px(toc.text_inset_dip, s) + l.indent[0];
        try testing.expectEqual(pane_icon, hd.icon.left);
        try testing.expectEqual(px(icon_dip, s), hd.icon.width());
        try testing.expectEqual(hd.icon.right + px(icon_text_gap_dip, s), hd.label_x);
    }
}

test "pane_sidebar: on the rail this window's header is its + alone, so toggling moves no icon (T2324)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .grid }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        var panel = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        addThisWindowHead(&panel, false, tm, s);
        var rail = layout(.mini, columnPx(.mini, 240, s), px(600, s), &items, tm, s);
        const bare_rule = rail.section_rule.?;
        addThisWindowHead(&rail, false, tm, s);
        try testing.expectEqual(@as(usize, 0), rail.head_count);
        // Every grid tile at its row's height: the slot is the header's
        // exact extent (Mac `PaneSidebarWindowHeader.height`). (A stashed
        // row sits under the panel's STASHED caption, which the rail has no
        // room for - so it never matched its tile, header or not.)
        for (0..items.len) |i| {
            if (items[i].section == .grid) try testing.expectEqual(panel.items[i].top, rail.items[i].top);
            try testing.expectEqual(@as(i32, 0), rail.indent[i]);
        }
        try testing.expectEqual(bare_rule.left, rail.section_rule.?.left);
        // The + is the compact item button, centred in the card and in the
        // header's band - level with the header's own +.
        const b = rail.rail_add;
        try testing.expectEqual(px(row_button_dip, s), b.width());
        try testing.expectEqual(px(row_button_dip, s), b.height());
        try testing.expect(@abs(b.centerX() - rail.card.centerX()) <= 1);
        try testing.expect(@abs(b.centerY() - panel.heads[0].rect.centerY()) <= 1);
        try testing.expectEqual(Hit.rail_add, hitTest(&rail, b.centerX(), b.centerY(), s));
        try testing.expectEqual(Hit{ .item = 0 }, hitTest(&rail, rail.items[0].centerX(), rail.items[0].centerY(), s));
    }
}

test "pane_sidebar: folding this window's header puts away its panes and its tray (T2324)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .grid } };
    const s: f32 = 1.5;
    const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
    var l = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
    addThisWindowHead(&l, true, tm, s);
    addEmptyTray(&l, tm, s);
    try testing.expectEqual(@as(usize, 1), l.head_count);
    for (0..items.len) |i| try testing.expect(!l.shown(i));
    try testing.expectEqual(@as(?Rect, null), l.section_rule);
    try testing.expectEqual(@as(?Rect, null), l.drop_slot);
    // Unfolded, the empty tray's hairline is as wide as a row's fill, not in
    // at the rows' level (T2339, Mac a13bf6f43).
    var open = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
    addThisWindowHead(&open, false, tm, s);
    addEmptyTray(&open, tm, s);
    try testing.expect(open.drop_slot != null);
    try testing.expectEqual(open.card.left + px(toc.fill_inset_dip, s), open.section_rule.?.left);
    try testing.expectEqual(open.items[0].left, open.section_rule.?.left);
    try testing.expectEqual(open.items[0].right, open.section_rule.?.right);
    // The rail never folds: its tiles stay.
    var rail = layout(.mini, columnPx(.mini, 240, s), px(600, s), &items, tm, s);
    addThisWindowHead(&rail, true, tm, s);
    for (0..items.len) |i| try testing.expect(rail.shown(i));
}

test "T2350: a grouped window's own list puts its group's header above its own, as all windows does (Mac 32bc9a6b5)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .grid } };
    const lines = [_]Line{
        .{ .kind = .project, .index = 0 },
        .{ .kind = .window, .index = 0, .depth = 1 },
        .{ .kind = .pane, .index = 0, .depth = 2 },
        .{ .kind = .pane, .index = 1, .depth = 2 },
    };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        var lone = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        addThisWindowHead(&lone, false, tm, s);
        var l = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        addThisWindowHeads(&l, false, false, tm, s);
        try testing.expectEqual(@as(usize, 2), l.head_count);
        const ph = l.heads[0];
        const wh = l.heads[1];
        try testing.expectEqual(HeadKind.project, ph.kind);
        try testing.expectEqual(HeadKind.window, wh.kind);
        // Both head group 0, this window: the project's buttons act on the
        // group it is in.
        try testing.expectEqual(@as(usize, 0), ph.index);
        try testing.expectEqual(@as(usize, 0), wh.index);
        // The group's header straight under the header band, a project
        // band's height; the window's header under it as in all windows.
        try testing.expectEqual(l.header.bottom, ph.rect.top);
        try testing.expectEqual(projectHeadHeight(tm, s), ph.rect.height());
        const outl = layoutWith(.expanded, px(240, s), px(900, s), &items, &lines, tm, s);
        try testing.expectEqual(outl.heads[1].rect.top - outl.heads[0].rect.top, wh.rect.top - ph.rect.top);
        try testing.expectEqual(outl.items[0].top - outl.heads[1].rect.top, l.items[0].top - wh.rect.top);
        try testing.expectEqual(outl.indent[0], l.indent[0]);
        // Every chevron in one column, and the window's header and rows
        // exactly a lone window's, moved down by the group's band and gap.
        try testing.expectEqual(wh.chevron.left, ph.chevron.left);
        const below = projectHeadHeight(tm, s) + px(header_gap_dip, s);
        try testing.expectEqual(lone.heads[0].rect.top + below, wh.rect.top);
        try testing.expectEqual(lone.heads[0].label_x, wh.label_x);
        for (0..items.len) |i| try testing.expectEqual(lone.items[i].top + below, l.items[i].top);
        // The group's chevron folds it, its buttons are its own, and the
        // window's header keeps its.
        try testing.expectEqual(Hit{ .head_fold = 0 }, hitTest(&l, ph.chevron.centerX(), ph.chevron.centerY(), s));
        const pa = l.headAdd(0, s);
        try testing.expectEqual(Hit{ .head_add = 0 }, hitTest(&l, pa.centerX(), pa.centerY(), s));
        const px_ = l.headClose(0, s);
        try testing.expectEqual(Hit{ .head_close = 0 }, hitTest(&l, px_.centerX(), px_.centerY(), s));
        const pr = l.headRename(0, s);
        try testing.expectEqual(Hit{ .head_rename = 0 }, hitTest(&l, pr.centerX(), pr.centerY(), s));
        try testing.expectEqual(Hit{ .head_fold = 1 }, hitTest(&l, wh.chevron.centerX(), wh.chevron.centerY(), s));
        const wa = l.headAdd(1, s);
        try testing.expectEqual(Hit{ .head_add = 1 }, hitTest(&l, wa.centerX(), wa.centerY(), s));
    }
}

test "T2350: a folded group shows its header alone in the window's own list; a lone window and the rail are unchanged (Mac 32bc9a6b5)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        var l = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        addThisWindowHeads(&l, false, true, tm, s);
        addEmptyTray(&l, tm, s);
        try testing.expectEqual(@as(usize, 1), l.head_count);
        try testing.expectEqual(HeadKind.project, l.heads[0].kind);
        for (0..items.len) |i| try testing.expect(!l.shown(i));
        try testing.expectEqual(@as(?Rect, null), l.section_rule);
        try testing.expectEqual(@as(?Rect, null), l.stashed_caption);
        try testing.expectEqual(@as(?Rect, null), l.drop_slot);
        // Folding the window inside an open group still keeps both headers.
        var wf = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        addThisWindowHeads(&wf, true, false, tm, s);
        try testing.expectEqual(@as(usize, 2), wf.head_count);
        for (0..items.len) |i| try testing.expect(!wf.shown(i));
        // No group: exactly `addThisWindowHead`.
        var a = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        addThisWindowHead(&a, false, tm, s);
        var b = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        addThisWindowHeads(&b, false, null, tm, s);
        try testing.expectEqual(a.head_count, b.head_count);
        try testing.expectEqual(a.heads[0], b.heads[0]);
        for (0..items.len) |i| try testing.expectEqual(a.items[i], b.items[i]);
        // The rail has no group header, folded or not: its + and tiles stay.
        var ra = layout(.mini, columnPx(.mini, 240, s), px(600, s), &items, tm, s);
        addThisWindowHead(&ra, false, tm, s);
        var rb = layout(.mini, columnPx(.mini, 240, s), px(600, s), &items, tm, s);
        addThisWindowHeads(&rb, false, true, tm, s);
        try testing.expectEqual(@as(usize, 0), rb.head_count);
        try testing.expectEqual(ra.rail_add, rb.rail_add);
        for (0..items.len) |i| try testing.expectEqual(ra.items[i], rb.items[i]);
    }
}

test "pane_sidebar: \"This Window\" is said only among other windows (T2324)" {
    try testing.expect(showsThisWindowTag(true, true));
    try testing.expect(!showsThisWindowTag(true, false));
    try testing.expect(!showsThisWindowTag(false, true));
    try testing.expect(!showsThisWindowTag(false, false));
}

test "T2340: a grouped window is not indented - its chevron, icon and panes line up with a lone window's (Mac c4dbe30be)" {
    const items = [_]Item{ .{ .section = .grid, .group = 0 }, .{ .section = .grid, .group = 1 } };
    const lines = [_]Line{
        .{ .kind = .window, .index = 0 },
        .{ .kind = .pane, .index = 0, .depth = 1 },
        .{ .kind = .project, .index = 1 },
        .{ .kind = .window, .index = 1, .depth = 1 },
        .{ .kind = .pane, .index = 1, .depth = 2 },
    };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        const l = layoutWith(.expanded, px(240, s), px(900, s), &items, &lines, tm, s);
        try testing.expectEqual(@as(usize, 3), l.head_count);
        const lone = l.heads[0];
        const grouped = l.heads[2];
        try testing.expectEqual(@as(u8, 1), grouped.depth);
        try testing.expectEqual(lone.chevron.left, grouped.chevron.left);
        try testing.expectEqual(lone.icon.left, grouped.icon.left);
        try testing.expectEqual(lone.label_x, grouped.label_x);
        try testing.expectEqual(l.indent[0], l.indent[1]);
        try testing.expectEqual(px(outline_step_dip, s), l.indent[1]);
        // The project's own chevron is in that column too.
        try testing.expectEqual(lone.chevron.left, l.heads[1].chevron.left);
    }
}

test "T2340: this window's header takes the selection only while folded; another's and a project's never (Mac c4dbe30be)" {
    try testing.expect(headSelected(.window, true, true));
    try testing.expect(!headSelected(.window, true, false));
    try testing.expect(!headSelected(.window, false, true));
    try testing.expect(!headSelected(.project, true, true));
}

test "pane_sidebar: the all-windows outline keeps its own heads (T2324)" {
    const items = [_]Item{.{ .section = .grid }};
    const lines = [_]Line{ .{ .kind = .window, .index = 0 }, .{ .kind = .pane, .index = 0, .depth = 1 } };
    const s: f32 = 1.0;
    const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
    var l = layoutWith(.expanded, 240, 600, &items, &lines, tm, s);
    const before = l;
    addThisWindowHead(&l, false, tm, s);
    try testing.expectEqual(before.head_count, l.head_count);
    try testing.expectEqual(before.items[0], l.items[0]);
    // The outline rail's + is its own new-window one (T2407), and this
    // window's head leaves it and the tiles where they were.
    var rail = layoutWith(.mini, columnPx(.mini, 240, s), 600, &items, &lines, tm, s);
    const rail_before = rail;
    addThisWindowHead(&rail, false, tm, s);
    try testing.expectEqual(rail_before.rail_add, rail.rail_add);
    try testing.expectEqual(rail_before.items[0], rail.items[0]);
}

test "pane_sidebar: with nothing stashed the empty tray sits below the grid, uncaptioned (T1844, T2276, T2313)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .grid, .two_line = true } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        // The panel: a rule, then a one-line well `sm` under it - and no
        // STASHED caption: the well's own text says what it is (Mac
        // 82b9c5501).
        var l = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        addEmptyTray(&l, tm, s);
        const slot = l.drop_slot.?;
        const rule = l.section_rule.?;
        try testing.expectEqual(@as(?Rect, null), l.stashed_caption);
        try testing.expect(rule.top >= l.items[1].bottom);
        // As much clear space under the rule as over it (T2339, Mac
        // a13bf6f43): the last pill's half gap and `sm`, both sides.
        try testing.expectEqual(rule.bottom + px(sm_dip, s) + rowHalfGap(s), slot.top);
        try testing.expectEqual(rule.top - l.items[1].bottom, slot.top - rule.bottom);
        // The rule sits where a tray with rows puts it; only the caption
        // that tray has is missing.
        const one = [_]Item{ .{ .section = .grid }, .{ .section = .grid, .two_line = true }, .{ .section = .stashed } };
        const with = layout(.expanded, px(240, s), px(600, s), &one, tm, s);
        try testing.expectEqual(with.section_rule.?, rule);
        try testing.expect(with.stashed_caption != null);
        try testing.expect(with.items[2].top > slot.top);
        try testing.expectEqual(rowHeight(false, tm, s), slot.height());
        try testing.expectEqual(l.items[1].left, slot.left);
        try testing.expectEqual(l.items[1].right, slot.right);
        // The rail: a tile on the tiles' column, spaced like a stashed group.
        var m = layout(.mini, columnPx(.mini, 240, s), px(600, s), &items, tm, s);
        addEmptyTray(&m, tm, s);
        const tile = m.drop_slot.?;
        try testing.expectEqual(m.items[0].left, tile.left);
        try testing.expectEqual(m.items[0].width(), tile.width());
        try testing.expectEqual(m.items[1].bottom + px(rail_group_gap_dip, s), tile.top);
        try testing.expect(m.section_rule.?.top > m.items[1].bottom and m.section_rule.?.bottom <= tile.top);
    }
}

test "pane_sidebar: no empty tray once something is stashed, or while hidden (T1844, T2276)" {
    const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
    const stashed = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    var l = layout(.expanded, 240, 600, &stashed, tm, 1.0);
    const cap = l.stashed_caption.?;
    addEmptyTray(&l, tm, 1.0);
    try testing.expectEqual(@as(?Rect, null), l.drop_slot);
    // The tray's own caption is left where its rows put it.
    try testing.expectEqual(cap, l.stashed_caption.?);
    const grid = [_]Item{.{ .section = .grid }};
    var h = layout(.hidden, 240, 600, &grid, tm, 1.0);
    addEmptyTray(&h, tm, 1.0);
    try testing.expectEqual(@as(?Rect, null), h.drop_slot);
    try testing.expectEqual(@as(?Rect, null), h.stashed_caption);
}

test "pane_sidebar: an empty roster still lays out the tray under the header (T2276)" {
    const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
    var l = layout(.expanded, 240, 600, &[_]Item{}, tm, 1.0);
    addEmptyTray(&l, tm, 1.0);
    try testing.expect(l.section_rule.?.top >= l.header.bottom);
    try testing.expect(l.drop_slot.?.top >= l.section_rule.?.bottom);
    try testing.expectEqual(@as(?Rect, null), l.stashed_caption);
}

// ---------------------------------------------------------------------------
// The all-windows outline (T1829)

fn outlineFixture(s: f32) struct { items: [5]Item, lines: [8]Line, tm: TextMetrics } {
    // Two lone windows: this one (2 grid + 1 stashed) and another (2 grid).
    return .{
        .items = .{
            .{ .section = .grid, .group = 0 },
            .{ .section = .grid, .group = 0, .two_line = true },
            .{ .section = .stashed, .group = 0 },
            .{ .section = .grid, .group = 1, .own = false },
            .{ .section = .grid, .group = 1, .own = false },
        },
        .lines = .{
            .{ .kind = .window, .index = 0 },
            .{ .kind = .pane, .index = 0, .depth = 1 },
            .{ .kind = .pane, .index = 1, .depth = 1 },
            .{ .kind = .pane, .index = 2, .depth = 1 },
            .{ .kind = .window, .index = 1 },
            .{ .kind = .pane, .index = 3, .depth = 1 },
            .{ .kind = .pane, .index = 4, .depth = 1 },
            // A trailing line past the items is ignored, not a crash.
            .{ .kind = .pane, .index = 9, .depth = 1 },
        },
        .tm = .{ .title_h = px(19, s), .caption_h = px(16, s) },
    };
}

test "pane_sidebar: the outline stacks heads and indented rows in order, no hairline between windows; a stash just follows its grid (T2313, T2340)" {
    for (scales) |s| {
        const f = outlineFixture(s);
        const w = px(240, s);
        const l = layoutWith(.expanded, w, px(900, s), &f.items, &f.lines, f.tm, s);
        try testing.expect(l.outline);
        try testing.expectEqual(@as(usize, 2), l.head_count);
        // No hairline between the windows (T2340, Mac c4dbe30be), none
        // before a stash (Mac 47b39b1cb), and no caption either.
        try testing.expectEqual(@as(usize, 0), l.rule_count);
        try testing.expectEqual(@as(?Rect, null), l.stashed_caption);
        try testing.expect(l.section_rule == null);
        // Everything below the header, top to bottom.
        try testing.expect(l.heads[0].rect.top >= l.header.bottom);
        try testing.expect(l.items[0].top >= l.heads[0].rect.bottom);
        try testing.expect(l.items[1].top > l.items[0].bottom);
        // The stashed row is spaced exactly as the next grid row would be.
        try testing.expectEqual(l.items[1].top - l.items[0].top, l.items[2].top - l.items[1].top);
        // The next window's header a pill gap under the last row.
        try testing.expectEqual(l.items[2].bottom + rowGap(s), l.heads[1].rect.top);
        // Every item one height: a window header is a pane pill (T2340).
        for (l.heads[0..l.head_count]) |hd| try testing.expectEqual(l.items[0].height(), hd.rect.height());
        try testing.expect(l.items[3].top >= l.heads[1].rect.bottom);
        // Every pane row is one height, one line or two (T2279).
        try testing.expectEqual(l.items[1].height(), l.items[0].height());
        // Fills span the panel; only the content is indented, one step.
        try testing.expectEqual(l.items[0].left, l.heads[0].rect.left);
        try testing.expectEqual(px(outline_step_dip, s), l.indent[0]);
        // The chevron sits on the label column; the window's icon after it,
        // and the name after that (T2340, Mac 28f6cde09).
        try testing.expectEqual(l.card.left + px(toc.label_inset_dip, s), l.heads[0].chevron.left);
        try testing.expect(l.heads[0].icon.left > l.heads[0].chevron.right);
        try testing.expect(l.heads[0].label_x > l.heads[0].icon.right);
        // The pane icons line up under the window's icon.
        try testing.expectEqual(l.heads[0].icon.left, l.items[0].left + px(toc.text_inset_dip, s) + l.indent[0]);
        // Only this window's stash is a drop target.
        try testing.expectEqual(@as(usize, 2), l.first_stashed);
        try testing.expectEqual(@as(usize, 3), l.stash_end);
        // The all-windows toggle sits inside the header.
        try testing.expect(l.scope.top >= l.header.top and l.scope.bottom <= l.header.bottom);
    }
}

test "pane_sidebar: a folded group's panes get no row and no hit" {
    const s: f32 = 1.0;
    const f = outlineFixture(s);
    // Fold the other window: its pane lines go.
    const lines = f.lines[0..5];
    const l = layoutWith(.expanded, 240, 900, &f.items, lines, f.tm, s);
    try testing.expect(l.shown(0));
    try testing.expect(!l.shown(3));
    try testing.expect(!l.shown(4));
    // Nothing below the last head hits a hidden pane.
    const y = l.heads[1].rect.bottom + 4;
    try testing.expect(hitTest(&l, 100, y, s) == .none);
}

test "pane_sidebar: hit testing the outline finds heads, chevrons, rows and the scope toggle" {
    const s: f32 = 1.0;
    const f = outlineFixture(s);
    const l = layoutWith(.expanded, 240, 900, &f.items, &f.lines, f.tm, s);
    const h0 = l.heads[0];
    try testing.expectEqual(Hit{ .head_fold = 0 }, hitTest(&l, h0.chevron.centerX(), h0.rect.centerY(), s));
    try testing.expectEqual(Hit{ .head = 0 }, hitTest(&l, h0.label_x + 10, h0.rect.centerY(), s));
    // Clear of the x (T2298), which sits where the count was.
    try testing.expectEqual(Hit{ .head = 1 }, hitTest(&l, l.heads[1].label_x + 10, l.heads[1].rect.centerY(), s));
    try testing.expectEqual(Hit{ .item = 3 }, hitTest(&l, 60, l.items[3].centerY(), s));
    try testing.expectEqual(@as(Hit, .scope), hitTest(&l, l.scope.centerX(), l.scope.centerY(), s));
    try testing.expectEqual(@as(Hit, .toggle), hitTest(&l, l.toggle.centerX(), l.toggle.centerY(), s));
}

test "pane_sidebar: the all-windows search field sits under the header, the outline under it (T1877)" {
    for (scales) |s| {
        const f = outlineFixture(s);
        const sm = px(sm_dip, s);
        var l = layoutWith(.expanded, px(240, s), px(900, s), &f.items, &f.lines, f.tm, s);
        // Under the header, inset like a row's fill, at least the standard
        // control height, the clear button inside it with sm to spare.
        try testing.expectEqual(l.header.bottom, l.search.top);
        try testing.expectEqual(l.card.left + px(toc.fill_inset_dip, s), l.search.left);
        try testing.expectEqual(l.card.right - px(toc.fill_inset_dip, s), l.search.right);
        try testing.expect(l.search.height() >= px(button_dip, s));
        try testing.expect(l.search.height() >= f.tm.title_h + 2 * sm);
        try testing.expectEqual(px(row_button_dip, s), l.search_clear.width());
        try testing.expectEqual(l.search.right - sm, l.search_clear.right);
        try testing.expect(l.search_clear.top - l.search.top >= @divTrunc(sm, 2));
        try testing.expect(l.search.bottom - l.search_clear.bottom >= @divTrunc(sm, 2));
        // Nothing touches it: the first head is `sm` below the field.
        try testing.expect(l.heads[0].rect.top >= l.search.bottom + sm);
        try testing.expect(l.no_match == null);
        // Hits: the field, and its clear button only while there is text.
        const cx = l.search_clear.centerX();
        const cy = l.search_clear.centerY();
        try testing.expectEqual(@as(Hit, .search), hitTest(&l, l.search.left + px(30, s), l.search.centerY(), s));
        try testing.expectEqual(@as(Hit, .search), hitTest(&l, cx, cy, s));
        l.search_text = true;
        try testing.expectEqual(@as(Hit, .search_clear), hitTest(&l, cx, cy, s));
    }
}

test "pane_sidebar: no field outside the outline, and none on the rail (T1877)" {
    const s: f32 = 1.0;
    const f = outlineFixture(s);
    const rail = layoutWith(.mini, px(68, s), px(900, s), &f.items, &f.lines, f.tm, s);
    try testing.expectEqual(@as(i32, 0), rail.search.width());
    try testing.expect(hitTest(&rail, 30, 30, s) != .search);
    const one = layout(.expanded, 240, 900, &f.items, f.tm, s);
    try testing.expectEqual(@as(i32, 0), one.search.width());
}

test "pane_sidebar: an outline with no lines says No matching panes under the field (T1877)" {
    for (scales) |s| {
        const f = outlineFixture(s);
        const l = layoutWith(.expanded, px(240, s), px(900, s), &f.items, &.{}, f.tm, s);
        const r = l.no_match.?;
        try testing.expect(r.top >= l.search.bottom + px(sm_dip, s));
        try testing.expectEqual(l.card.left + px(toc.label_inset_dip, s), r.left);
        try testing.expectEqual(@as(usize, 0), l.head_count);
        for (0..l.count) |i| try testing.expect(!l.shown(i));
    }
}

test "pane_sidebar: the outline's rail draws no divider between windows, nor before a stash (T2313, T2425)" {
    for (scales) |s| {
        const f = outlineFixture(s);
        const l = layoutWith(.mini, px(68, s), px(900, s), &f.items, &f.lines, f.tm, s);
        // Every pane is a tile, folded or not.
        for (0..5) |i| try testing.expect(l.shown(i));
        // A window is its tiles alone (Mac 6bd2962eb): one window's tiles
        // follow the last one's at the tiles' own spacing, and the stashed
        // tile follows its grid the same way (Mac 47b39b1cb).
        try testing.expectEqual(@as(usize, 0), l.rule_count);
        try testing.expect(l.section_rule == null);
        for (1..5) |i| try testing.expectEqual(l.items[i - 1].bottom + rowGap(s), l.items[i].top);
        // No header buttons on the rail beyond the toggle.
        try testing.expectEqual(@as(i32, 0), l.scope.width());
        try testing.expectEqual(@as(usize, 0), l.head_count);
    }
}

test "T2407: all windows' rail opens with a + above every window, in a window header's slot (Mac 6bd2962eb)" {
    for (scales) |s| {
        const f = outlineFixture(s);
        const l = layoutWith(.mini, px(68, s), px(900, s), &f.items, &f.lines, f.tm, s);
        const b = l.rail_add;
        try testing.expectEqual(px(row_button_dip, s), b.width());
        try testing.expectEqual(px(row_button_dip, s), b.height());
        try testing.expect(@abs(b.centerX() - l.card.centerX()) <= 1);
        // Below the header, above the first window's first tile.
        try testing.expect(b.top >= l.header.bottom);
        try testing.expect(b.bottom <= l.items[0].top);
        try testing.expectEqual(Hit.rail_add, hitTest(&l, b.centerX(), b.centerY(), s));
        // The slot is exactly this window's rail + slot: the tiles start
        // where a lone window's do under its header's +.
        var own = layout(.mini, px(68, s), px(900, s), f.items[0..2], f.tm, s);
        addThisWindowHead(&own, false, f.tm, s);
        try testing.expectEqual(own.rail_add, b);
        try testing.expectEqual(own.items[0].top, l.items[0].top);
        // The panel's header + is the new-window one there; no rail slot.
        const panel = layoutWith(.expanded, px(240, s), px(900, s), &f.items, &f.lines, f.tm, s);
        try testing.expectEqual(Rect{}, panel.rail_add);
    }
}

test "pane_sidebar: at rest the outline has no empty well (T2313, Mac b7de64ce8)" {
    const s: f32 = 1.0;
    var f = outlineFixture(s);
    f.items[2].section = .grid; // nothing stashed here
    var l = layoutWith(.expanded, 240, 900, &f.items, f.lines[0..3], f.tm, s);
    addEmptyTray(&l, f.tm, s);
    try testing.expect(l.drop_slot == null);
}

test "pane_sidebar: during a drag the outline's well opens under this window's last pane, both modes (T2313, Mac b7de64ce8)" {
    for (scales) |s| {
        var f = outlineFixture(s);
        f.items[2].section = .grid; // this window stashes nothing
        for ([_]Mode{ .expanded, .mini }) |m| {
            const w = if (m == .expanded) px(240, s) else px(68, s);
            const before = layoutWith(m, w, px(900, s), &f.items, &f.lines, f.tm, s);
            var l = before;
            addDragWell(&l, f.tm, s);
            const slot = l.drop_slot.?;
            // Right under this window's last pane, one pill gap clear, on its
            // column; a row on the panel, a tile on the rail.
            try testing.expectEqual(l.items[2].bottom + rowGap(s), slot.top);
            try testing.expectEqual(l.items[2].left, slot.left);
            try testing.expectEqual(l.items[2].right, slot.right);
            const h = if (m == .expanded) rowHeight(false, f.tm, s) else pillHeight(f.tm, s);
            try testing.expectEqual(h, slot.height());
            // Nothing above it moved; everything below it moved by the
            // well and one gap, so nothing touches.
            const grow = h + rowGap(s);
            for (0..3) |i| try testing.expectEqual(before.items[i], l.items[i]);
            for (3..5) |i| try testing.expectEqual(before.items[i].top + grow, l.items[i].top);
            if (m == .expanded) {
                try testing.expectEqual(before.heads[0], l.heads[0]);
                try testing.expectEqual(before.heads[1].rect.top + grow, l.heads[1].rect.top);
                try testing.expectEqual(before.heads[1].chevron.top + grow, l.heads[1].chevron.top);
                try testing.expect(vGap(slot, l.heads[1].rect) >= rowGap(s));
            }
        }
    }
}

test "pane_sidebar: no outline well while this window stashes, while its group is folded, or outside the outline (T2313)" {
    const s: f32 = 1.0;
    // The fixture's own window has a stashed pane: its rows are the target.
    const f = outlineFixture(s);
    var l = layoutWith(.expanded, 240, 900, &f.items, &f.lines, f.tm, s);
    addDragWell(&l, f.tm, s);
    try testing.expect(l.drop_slot == null);
    // Folded on the panel: no pane to follow (the rail still shows them).
    var g = outlineFixture(s);
    g.items[2].section = .grid;
    const folded = [_]Line{ .{ .kind = .window, .index = 0 }, .{ .kind = .window, .index = 1 } };
    var p = layoutWith(.expanded, 240, 900, &g.items, &folded, g.tm, s);
    addDragWell(&p, g.tm, s);
    try testing.expect(p.drop_slot == null);
    var r = layoutWith(.mini, 68, 900, &g.items, &folded, g.tm, s);
    addDragWell(&r, g.tm, s);
    try testing.expect(r.drop_slot != null);
    // The single roster's well is `addEmptyTray`'s, drag or not.
    var one = layout(.expanded, 240, 900, &g.items, g.tm, s);
    addDragWell(&one, g.tm, s);
    try testing.expect(one.drop_slot == null);
}

test "pane_sidebar: the header reads toggle, then all-windows at the trailing edge - Mac's order, no trash button - and each is its own hit (T2280, T2289)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
        const l = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        try testing.expect(l.toggle.right <= l.scope.left);
        try testing.expectEqual(l.card.right - px(sm_dip, s), l.scope.right);
        try testing.expect(l.scope.top >= l.header.top and l.scope.bottom <= l.header.bottom);
        try testing.expectEqual(@as(Hit, .scope), hitTest(&l, l.scope.centerX(), l.scope.centerY(), s));
        try testing.expectEqual(@as(Hit, .toggle), hitTest(&l, l.toggle.centerX(), l.toggle.centerY(), s));
    }
}

test "T2298: another window's row offers the x alone, in this window's column (Mac 345be6b02); a tile has none at all" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .grid, .group = 1, .own = false } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
        const l = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        try testing.expectEqual(@as(i32, 0), l.rowButton(1, s).width());
        const x1 = l.rowClose(1, s);
        try testing.expectEqual(px(row_button_dip, s), x1.width());
        try testing.expectEqual(Hit{ .item_close = 1 }, hitTest(&l, x1.centerX(), x1.centerY(), s));
        // The x lines up with this window's; where its stash button is,
        // another window's row is all row.
        const own_x = l.rowClose(0, s);
        const own_b = l.rowButton(0, s);
        try testing.expectEqual(own_x.left, x1.left);
        const y1 = l.items[1].centerY();
        try testing.expectEqual(Hit{ .item = 1 }, hitTest(&l, own_b.centerX(), y1, s));

        // The rail: every point of a tile is the tile (no corner x).
        const rail = layout(.mini, columnPx(.mini, 240, s), px(600, s), &items, tm, s);
        const t = rail.items[0];
        try testing.expectEqual(Hit{ .item = 0 }, hitTest(&rail, t.left + 1, t.top + 1, s));
        try testing.expectEqual(Hit{ .item = 0 }, hitTest(&rail, t.right - 2, t.bottom - 2, s));
    }
}

test "pane_sidebar: the edge band is the card's trailing margin in both modes (T2290, T2299)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .grid } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        const g = px(grab_dip, s);
        const w = columnPx(.expanded, 240, s);
        const h = px(600, s);
        const e = layout(.expanded, w, h, &items, tm, s);
        // The gutter between the card and the panes, never over the card
        // (T2290, Mac 0a547522d `edgeGrip`): the column's last pixel and the
        // first past the card drag; the card's last pixel is its row's.
        try testing.expect(onEdge(&e, w - 1, px(300, s), s));
        try testing.expect(onEdge(&e, e.card.right, px(300, s), s));
        try testing.expect(!onEdge(&e, e.card.right - 1, px(300, s), s));
        try testing.expect(!onEdge(&e, e.card.right - 1, e.items[0].centerY(), s));
        try testing.expect(w - e.card.right >= g);
        // Only along the card: the margin above it is not a grip.
        try testing.expect(!onEdge(&e, w - 1, e.card.top - 1, s));
        // The buttons keep their own pixels.
        try testing.expect(!onEdge(&e, e.scope.right - 1, e.scope.centerY(), s));
        const b = e.rowClose(0, s);
        try testing.expect(!onEdge(&e, b.right - 1, b.centerY(), s));

        // The rail: its gutter, never its tiles (T2299, Mac 543489bca
        // `edgeGrip`) - the card's last pixel is a tile's.
        const rw = px(railColumnDip(), s);
        const r = layout(.mini, rw, h, &items, tm, s);
        const y = r.card.centerY();
        try testing.expect(onEdge(&r, r.card.right, y, s));
        try testing.expect(onEdge(&r, rw - 1, y, s));
        try testing.expect(!onEdge(&r, r.card.right - 1, y, s));
        try testing.expect(!onEdge(&r, r.card.centerX(), y, s));
        try testing.expect(rw - r.card.right >= g);
        const t = r.items[0];
        try testing.expect(!onEdge(&r, t.right - 1, t.centerY(), s));
        // Only along the card: the margin above it is the grid's.
        try testing.expect(!onEdge(&r, rw - 1, r.card.top - 1, s));

        const hidden: Layout = .{ .mode = .hidden, .width = w, .height = h };
        try testing.expect(!onEdge(&hidden, w - 1, 10, s));
    }
}

test "pane_sidebar: the pinned grip is the gutter when elevated, the card's own margin when flat (T2265, T2290)" {
    const s: f32 = 1.5;
    const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    const w = columnPx(.expanded, 220, s);
    const e = layout(.expanded, w, px(600, s), &items, tm, s);
    // Flat: the card's trailing margin, along the card (T2290).
    const band = edgeBand(&e, s, false).?;
    try testing.expectEqual(Rect{ .left = e.card.right, .top = e.card.top, .right = w, .bottom = e.card.bottom }, band);
    try testing.expect(onEdgeIn(&e, w - 1, px(300, s), s, false));
    // Elevated: nothing in the panel drags - the window's gutter does.
    try testing.expect(edgeBand(&e, s, true) == null);
    try testing.expect(!onEdgeIn(&e, w - 1, px(300, s), s, true));
    try testing.expect(pinnedGripInGutter(true) and !pinnedGripInGutter(false));
    // The rail the same way (T2299, Mac 543489bca `edgeGrip`): flat, its
    // card's trailing margin; elevated, the window's gutter.
    const rw = columnPx(.mini, 240, s);
    const r = layout(.mini, rw, px(600, s), &items, tm, s);
    try testing.expectEqual(Rect{ .left = r.card.right, .top = r.card.top, .right = rw, .bottom = r.card.bottom }, edgeBand(&r, s, false).?);
    try testing.expect(edgeBand(&r, s, true) == null);
    try testing.expect(!onEdgeIn(&r, r.card.right - 1, r.card.centerY(), s, true));
}

test "pane_sidebar: T2277 a divider tucks the panel after the give it has above its minimum, between a nudge and a push" {
    // At its minimum the panel still gives a nudge's worth...
    try testing.expectEqual(@as(f32, 24), dividerTuckGiveDip(min_width_dip));
    // ...a little wider, what it has above the minimum...
    try testing.expectEqual(@as(f32, 50), dividerTuckGiveDip(min_width_dip + 50));
    // ...and never more than a deliberate push.
    try testing.expectEqual(@as(f32, 80), dividerTuckGiveDip(max_width_dip));
    try testing.expect(divider_tuck_hysteresis_dip > 0);
}

test "pane_sidebar: T2299 an edge drag pulls the rail out once the panel fits and tucks the panel in well under its minimum" {
    // The rail measures from its card (Mac `railCardWidth`).
    try testing.expectEqual(rail_card_dip, edgeStartDip(.mini, 300));
    try testing.expectEqual(@as(f32, 300), edgeStartDip(.expanded, 300));
    try testing.expectEqual(max_width_dip, edgeStartDip(.expanded, 900));

    const rail: EdgeDrag = .{ .expanded = false };
    // Rail (Mac 543489bca's own cases): short of the panel, still the rail -
    // past the threshold too, until the panel would fit...
    try testing.expectEqual(@as(?EdgeDrag, rail), edgeDrag(.mini, 0, 100));
    try testing.expectEqual(@as(?EdgeDrag, rail), edgeDrag(.mini, 0, 150));
    try testing.expectEqual(@as(?EdgeDrag, rail), edgeDrag(.mini, rail_card_dip, min_width_dip - rail_card_dip - 1));
    // ...then out, at the width the pointer asks for.
    try testing.expectEqual(@as(?EdgeDrag, EdgeDrag{ .expanded = true, .width = min_width_dip }), edgeDrag(.mini, rail_card_dip, min_width_dip - rail_card_dip));
    try testing.expectEqual(@as(?EdgeDrag, EdgeDrag{ .expanded = true, .width = 200 }), edgeDrag(.mini, 0, 200));
    try testing.expectEqual(@as(?EdgeDrag, rail), edgeDrag(.mini, rail_card_dip, -30));

    // Expanded panel: follows the pointer between the bounds...
    try testing.expectEqual(@as(?EdgeDrag, EdgeDrag{ .expanded = true, .width = 300 }), edgeDrag(.expanded, 240, 60));
    try testing.expectEqual(@as(?EdgeDrag, EdgeDrag{ .expanded = true, .width = max_width_dip }), edgeDrag(.expanded, 0, 9000));
    // ...stops at its minimum in the band above the threshold...
    try testing.expectEqual(@as(?EdgeDrag, EdgeDrag{ .expanded = true, .width = min_width_dip }), edgeDrag(.expanded, 0, 150));
    try testing.expectEqual(@as(?EdgeDrag, EdgeDrag{ .expanded = true, .width = min_width_dip }), edgeDrag(.expanded, 240, expand_threshold_dip - 240));
    // ...and tucks back into the rail short of it.
    try testing.expectEqual(@as(?EdgeDrag, rail), edgeDrag(.expanded, 0, 100));
    try testing.expectEqual(@as(?EdgeDrag, rail), edgeDrag(.expanded, 240, -200));
    // Both ways in one drag: a rail pulled out keeps measuring from the
    // rail's card, so pushing back in tucks it, and out again expands it.
    try testing.expectEqual(@as(?EdgeDrag, EdgeDrag{ .expanded = true, .width = rail_card_dip + 216 }), edgeDrag(.expanded, rail_card_dip, 216));
    try testing.expectEqual(@as(?EdgeDrag, rail), edgeDrag(.expanded, rail_card_dip, 40));

    // The thresholds sit between the rail and the narrowest panel.
    try testing.expect(rail_card_dip < expand_threshold_dip and expand_threshold_dip < min_width_dip);
    try testing.expectEqual(@as(?EdgeDrag, null), edgeDrag(.hidden, 240, 40));
}

test "T1900: beside the tab strip the column reaches up, its content where it was" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
    for (scales) |s| {
        const reach = px(40, s);
        var up = railInsets(true);
        up.reach_px = reach;
        const h = px(600, s);
        // The rail: the column is `reach` taller, the card runs the whole of
        // it at the same margin, and every tile keeps its place beside the grid.
        const w = columnPxFor(.mini, 240, s, true);
        const a = layoutIn(.mini, w, h, &items, null, tm, s, railInsets(true));
        const b = layoutIn(.mini, w, h + reach, &items, null, tm, s, up);
        try testing.expectEqual(a.card.top, b.card.top);
        try testing.expectEqual(a.card.bottom + reach, b.card.bottom);
        try testing.expectEqual(a.toggle.top + reach, b.toggle.top);
        for (0..items.len) |i| try testing.expectEqual(a.items[i].top + reach, b.items[i].top);
        // The panel: its header starts below the strip's row.
        const pw = columnPxFor(.expanded, 240, s, true);
        const c = layoutIn(.expanded, pw, h, &items, null, tm, s, railInsets(true));
        const d = layoutIn(.expanded, pw, h + reach, &items, null, tm, s, up);
        try testing.expectEqual(c.header.top + reach, d.header.top);
        try testing.expectEqual(c.items[0].top + reach, d.items[0].top);
        try testing.expectEqual(b.toggle, d.toggle);
    }
}

test "T2298: a window's and a project's header x sit in the rows' x column, level with the chevron, and are their own hit (Mac 7e4646bb5)" {
    // A project holding both windows, so a project head is laid out too.
    const lines = [_]Line{
        .{ .kind = .project, .index = 0 },
        .{ .kind = .window, .index = 0, .depth = 1 },
        .{ .kind = .pane, .index = 0, .depth = 2 },
        .{ .kind = .pane, .index = 1, .depth = 2 },
        .{ .kind = .window, .index = 1, .depth = 1 },
        .{ .kind = .pane, .index = 3, .depth = 2 },
    };
    for (scales) |s| {
        const f = outlineFixture(s);
        const l = layoutWith(.expanded, px(240, s), px(900, s), &f.items, &lines, f.tm, s);
        try testing.expectEqual(@as(usize, 3), l.head_count);
        try testing.expectEqual(HeadKind.project, l.heads[0].kind);
        const row_x = l.rowClose(0, s);
        for (0..l.head_count) |k| {
            const hx = l.headClose(k, s);
            const hd = l.heads[k];
            try testing.expectEqual(px(row_button_dip, s), hx.width());
            try testing.expectEqual(row_x.left, hx.left);
            try testing.expect(@abs(hx.centerY() - hd.chevron.centerY()) <= 1);
            try testing.expectEqual(Hit{ .head_close = k }, hitTest(&l, hx.centerX(), hx.centerY(), s));
            // Beside it the header is still the header.
            try testing.expectEqual(Hit{ .head = k }, hitTest(&l, hx.left - 2, hx.centerY(), s));
            // A press on it is the button's, never an edge drag.
            try testing.expect(onButton(&l, hx.centerX(), hx.centerY(), s));
        }
        try testing.expectEqual(Rect{}, l.headClose(l.head_count, s));
    }
}

test "T2323: a header's hover + sits one button and a gap before its x, level with it, and is its own hit - never the header's or an edge drag (Mac 44aa923f0)" {
    const lines = [_]Line{
        .{ .kind = .project, .index = 0 },
        .{ .kind = .window, .index = 0, .depth = 1 },
        .{ .kind = .pane, .index = 0, .depth = 2 },
        .{ .kind = .window, .index = 1, .depth = 1 },
        .{ .kind = .pane, .index = 3, .depth = 2 },
    };
    for (scales) |s| {
        const f = outlineFixture(s);
        const l = layoutWith(.expanded, px(240, s), px(900, s), &f.items, &lines, f.tm, s);
        try testing.expectEqual(@as(usize, 3), l.head_count);
        for (0..l.head_count) |k| {
            const hx = l.headClose(k, s);
            const ha = l.headAdd(k, s);
            try testing.expectEqual(hx.width(), ha.width());
            try testing.expectEqual(hx.top, ha.top);
            try testing.expectEqual(hx.left - px(row_button_gap_dip, s), ha.right);
            // In the same column as a this-window row's stash button.
            try testing.expectEqual(l.rowButton(0, s).left, ha.left);
            try testing.expectEqual(Hit{ .head_add = k }, hitTest(&l, ha.centerX(), ha.centerY(), s));
            try testing.expectEqual(Hit{ .head_close = k }, hitTest(&l, hx.centerX(), hx.centerY(), s));
            try testing.expectEqual(Hit{ .head = k }, hitTest(&l, ha.left - 2, ha.centerY(), s));
            try testing.expect(onButton(&l, ha.centerX(), ha.centerY(), s));
        }
        try testing.expectEqual(Rect{}, l.headAdd(l.head_count, s));
    }
}

test "T2339: the pencil leads every header's buttons and a terminal row's - pencil, +, x on a header; pencil, stash, x on this window's row; pencil, x on another's; none on a viewer (Mac a13bf6f43)" {
    for (scales) |s| {
        var f = outlineFixture(s);
        // Item 0: this window's terminal. Item 3: another window's terminal.
        // Item 1: this window's viewer (no pencil).
        f.items[0].renamable = true;
        f.items[3].renamable = true;
        const l = layoutWith(.expanded, px(240, s), px(900, s), &f.items, &f.lines, f.tm, s);
        const gap = px(row_button_gap_dip, s);
        for (0..l.head_count) |k| {
            const ha = l.headAdd(k, s);
            const hr = l.headRename(k, s);
            try testing.expectEqual(ha.width(), hr.width());
            try testing.expectEqual(ha.top, hr.top);
            try testing.expectEqual(ha.left - gap, hr.right);
            try testing.expect(hr.left > l.heads[k].label_x);
            try testing.expectEqual(Hit{ .head_rename = k }, hitTest(&l, hr.centerX(), hr.centerY(), s));
            try testing.expectEqual(Hit{ .head = k }, hitTest(&l, hr.left - 2, hr.centerY(), s));
            try testing.expect(onButton(&l, hr.centerX(), hr.centerY(), s));
        }
        try testing.expectEqual(Rect{}, l.headRename(l.head_count, s));

        // This window's terminal: pencil, stash, x.
        const own_r = l.rowRename(0, s);
        try testing.expectEqual(l.rowButton(0, s).left - gap, own_r.right);
        try testing.expectEqual(l.rowButton(0, s).top, own_r.top);
        try testing.expectEqual(Hit{ .item_rename = 0 }, hitTest(&l, own_r.centerX(), own_r.centerY(), s));
        try testing.expect(onButton(&l, own_r.centerX(), own_r.centerY(), s));
        // Another window's terminal: pencil, x - no stash between.
        const other_r = l.rowRename(3, s);
        try testing.expectEqual(l.rowClose(3, s).left - gap, other_r.right);
        try testing.expectEqual(Hit{ .item_rename = 3 }, hitTest(&l, other_r.centerX(), other_r.centerY(), s));
        // The pencil sits where a header's does: one column for the eye.
        try testing.expectEqual(l.headRename(0, s).left, own_r.left);
        // A viewer has none: the press is the row's.
        try testing.expectEqual(Rect{}, l.rowRename(1, s));
        const v = l.items[1];
        try testing.expectEqual(Hit{ .item = 1 }, hitTest(&l, own_r.centerX(), v.centerY(), s));

        // The rail has no pencils: its tiles are the item.
        const m = layoutWith(.mini, px(68, s), px(900, s), &f.items, &f.lines, f.tm, s);
        const t = m.items[0];
        try testing.expectEqual(Hit{ .item = 0 }, hitTest(&m, t.centerX(), t.centerY(), s));
    }
}

test "T2323: the panel header reads toggle, caption, +, all-windows - the + 2 DIP left of the toggle-sized all-windows button, its own hit; the rail has none (Mac 44aa923f0)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
        const l = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        try testing.expectEqual(l.scope.width(), l.add.width());
        try testing.expectEqual(l.scope.top, l.add.top);
        try testing.expectEqual(l.scope.left - px(2, s), l.add.right);
        try testing.expect(l.add.left > l.caption_x);
        try testing.expectEqual(@as(Hit, .add), hitTest(&l, l.add.centerX(), l.add.centerY(), s));
        try testing.expectEqual(@as(Hit, .scope), hitTest(&l, l.scope.centerX(), l.scope.centerY(), s));
        try testing.expect(onButton(&l, l.add.centerX(), l.add.centerY(), s));
        const m = layout(.mini, px(68, s), px(600, s), &items, tm, s);
        try testing.expectEqual(@as(i32, 0), m.add.width());
        try testing.expect(hitTest(&m, m.add.centerX(), m.add.centerY(), s) != .add);
    }
}

/// The clear space between two vertically stacked rects (negative: they
/// overlap).
fn vGap(a: Rect, b: Rect) i32 {
    return if (a.top <= b.top) b.top - a.bottom else a.top - b.bottom;
}

test "T2311: no two sidebar items touch - pills, tiles, window headers and the tray's well keep Mac's 4 DIP gap in both modes (Mac 157b08c48)" {
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(16, s), .caption_h = px(14, s) };
        const gap = rowGap(s);
        // Mac's sizes: a 32 row, its pill 28, 4 between two pills (T2340).
        const mac: TextMetrics = .{ .title_h = px(14, s), .caption_h = px(12, s) };
        try testing.expectEqual(px(row_dip, s), pillHeight(mac, s) + gap);
        try testing.expect(gap >= px(row_gap_dip, s) - 1);
        // The single roster, with a stash and with the empty tray, both modes.
        const stashed = [_]Item{ .{ .section = .grid }, .{ .section = .grid, .two_line = true }, .{ .section = .grid }, .{ .section = .stashed }, .{ .section = .stashed } };
        const grid = [_]Item{ .{ .section = .grid }, .{ .section = .grid }, .{ .section = .grid } };
        for ([_]Mode{ .expanded, .mini }) |m| {
            for ([_][]const Item{ &stashed, &grid }) |its| {
                var l = layout(m, columnPx(m, 240, s), px(900, s), its, tm, s);
                addEmptyTray(&l, tm, s);
                var rects: [max_items + 1]Rect = undefined;
                var n: usize = 0;
                for (0..l.count) |i| {
                    rects[n] = l.items[i];
                    n += 1;
                }
                if (l.drop_slot) |d| {
                    rects[n] = d;
                    n += 1;
                }
                for (0..n) |a| for (a + 1..n) |b| try testing.expect(vGap(rects[a], rects[b]) >= gap);
                // The first pill starts a half gap below the header, as
                // Mac's row pads its pill.
                try testing.expectEqual(l.header.bottom + rowHalfGap(s), l.items[0].top);
            }
        }
        // The outline: window headers and pills never touch, and a project
        // header's band keeps 6 DIP clear above and below it.
        const f = outlineFixture(s);
        const l = layoutWith(.expanded, px(240, s), px(900, s), &f.items, &f.lines, tm, s);
        var rects: [max_items + max_heads]Rect = undefined;
        var n: usize = 0;
        for (0..l.count) |i| {
            if (!l.shown(i)) continue;
            rects[n] = l.items[i];
            n += 1;
        }
        for (l.heads[0..l.head_count]) |hd| {
            if (hd.kind != .window) continue;
            rects[n] = hd.rect;
            n += 1;
        }
        for (0..n) |a| for (a + 1..n) |b| try testing.expect(vGap(rects[a], rects[b]) >= gap);
        const head_gap = px(header_gap_dip, s);
        for (l.heads[0..l.head_count]) |hd| {
            if (hd.kind != .project) continue;
            for (rects[0..n]) |r| try testing.expect(vGap(hd.rect, r) >= head_gap);
        }
    }
}

test "T2311: a project header's band has 6 DIP clear above and below, and is Mac's 32 DIP with its caption centred (T2340)" {
    const s: f32 = 1.0;
    const tm: TextMetrics = .{ .title_h = 16, .caption_h = 14 };
    const items = [_]Item{ .{ .section = .grid, .group = 0 }, .{ .section = .grid, .group = 1 } };
    const lines = [_]Line{
        .{ .kind = .project, .index = 0 },
        .{ .kind = .window, .index = 0, .depth = 1 },
        .{ .kind = .pane, .index = 0, .depth = 2 },
        .{ .kind = .project, .index = 1 },
        .{ .kind = .window, .index = 1, .depth = 1 },
        .{ .kind = .pane, .index = 1, .depth = 2 },
    };
    const l = layoutWith(.expanded, 240, 900, &items, &lines, tm, s);
    try testing.expectEqual(@as(usize, 4), l.head_count);
    const p0 = l.heads[0];
    const w0 = l.heads[1];
    const p1 = l.heads[2];
    try testing.expectEqual(@as(i32, 32), p0.rect.height());
    try testing.expectEqual(@as(i32, 32), p1.rect.height());
    // The caption's line centred in the band, the chevron on it.
    try testing.expectEqual(p0.rect.top + (32 - 14) / 2 + (14 - 12) / 2, p0.chevron.top);
    try testing.expectEqual(Rect{}, p0.icon);
    // Below a band: the gap, then the window row's half gap.
    try testing.expectEqual(p0.rect.bottom + 6 + 2, w0.rect.top);
    // Above a band: the last pill's half gap, then the gap.
    try testing.expectEqual(l.items[0].bottom + 2 + 6, p1.rect.top);
    // A folded project (no lines under it) adds no gap below.
    const folded = [_]Line{ .{ .kind = .project, .index = 0 }, .{ .kind = .project, .index = 1 } };
    const fl = layoutWith(.expanded, 240, 900, &items, &folded, tm, s);
    try testing.expectEqual(fl.heads[0].rect.bottom + 6, fl.heads[1].rect.top);
}


test "pane_sidebar: T2341 a resync drops a hover the pointer is no longer over, and keeps a held one" {
    // Covered by another window (or no readable cursor): no row is hovered,
    // whatever was lit before the windows changed places.
    try testing.expectEqual(Hit.none, resyncedHover(.{ .item = 2 }, false, false, .{ .item = 2 }));
    try testing.expectEqual(Hit.none, resyncedHover(.{ .head_close = 0 }, false, false, .none));
    // Still the column's under the pointer: the hover is what is there now.
    try testing.expectEqual(Hit{ .item = 1 }, resyncedHover(.{ .item = 2 }, false, true, .{ .item = 1 }));
    try testing.expectEqual(Hit{ .item = 2 }, resyncedHover(.none, false, true, .{ .item = 2 }));
    // An item held mid-drag keeps every hover as it is (T2337).
    try testing.expectEqual(Hit{ .head = 1 }, resyncedHover(.{ .head = 1 }, true, false, .none));
    try testing.expectEqual(Hit.none, resyncedHover(.none, true, true, .{ .item = 0 }));
}
