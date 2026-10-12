//! The pane sidebar's pure rules on Windows (T1828; Mac 597a193cc,
//! `PaneSidebarState.swift` / `PaneSidebarText`, `docs/design/pane-sidebar.md`).
//!
//! The sidebar is a per-window column, left of the split grid, that lists
//! every pane of the active tab: the panes in the grid (focused one selected)
//! and then the stashed ones (T1827). Pinned, it is a flat panel; unpinned,
//! it collapses to a raised card holding one tile per pane — the mini rail.
//! Hidden outright, it takes no space at all.
//!
//! Everything here is arithmetic and string rules — modes, column widths,
//! the rail tile monogram, the row text, and the geometry the window paints
//! and hit-tests — so it is asserted at 1.0 / 1.25 / 1.5 / 2.0 without a
//! window, in every lane. The HWND that paints it is `PaneSidebar.zig`.
//!
//! Numbers. The ROWS reuse the viewer side panel's (`viewer_toc_layout`):
//! Mac's design says the pane sidebar is "the same card, not a lookalike" of
//! the table of contents, so its fill inset, text inset, vertical padding and
//! corner are imported, not restated. The rail card is Mac's 44 DIP inside the
//! design system's `lg` card margin (12, which IS `GlassCard.outerMargin`), and
//! a tile is the standard 28 DIP icon-button square, so the rail's column is
//! Mac's 68 exactly.

const std = @import("std");
const toc = @import("viewer_toc_layout.zig");

// ---------------------------------------------------------------------------
// Modes and the column

pub const Mode = enum {
    /// Hidden outright (`toggle_pane_sidebar`): no column, not a target.
    hidden,
    /// Pinned: the flat panel at the preferred width.
    expanded,
    /// Unpinned, or a window too narrow for the panel: the mini rail.
    mini,
};

/// Below this window width the full panel would crowd the grid and the rail
/// does not (Mac's `narrowWindowWidth`, the viewer side panel's breakpoint).
pub const narrow_window_dip: f32 = toc.gutter_min_dip;

pub const default_width_dip: f32 = 240;
pub const min_width_dip: f32 = 180;
pub const max_width_dip: f32 = 380;

/// The rail's card, and the margin around it (design system `lg`).
pub const rail_card_dip: f32 = 44;
pub const rail_margin_dip: f32 = 12;

/// A rail tile: the standard icon-button square, so a tile and the pin above
/// it are the same control size (design system §2.1).
pub const tile_dip: f32 = 28;
/// Between tiles (`sm`), and between the pin and the first tile (`md`).
pub const tile_gap_dip: f32 = 4;
pub const rail_group_gap_dip: f32 = 8;

/// The standard icon button the header's pin is drawn as.
pub const button_dip: f32 = 28;
/// The compact button a row's hover action is drawn as (dense list rows).
pub const row_button_dip: f32 = 20;
/// The design system's default inset (`sm`).
pub const sm_dip: f32 = 4;

pub fn mode(pinned: bool, hidden: bool, window_w_dip: f32) Mode {
    if (hidden) return .hidden;
    if (pinned and window_w_dip >= narrow_window_dip) return .expanded;
    return .mini;
}

pub fn railColumnDip() f32 {
    return rail_margin_dip + rail_card_dip + rail_margin_dip;
}

/// The width of the sidebar's COLUMN — what the grid is laid out beside.
pub fn columnDip(m: Mode, panel_w_dip: f32) f32 {
    return switch (m) {
        .hidden => 0,
        .expanded => clampWidth(panel_w_dip),
        .mini => railColumnDip(),
    };
}

pub fn columnPx(m: Mode, panel_w_dip: f32, scale: f32) i32 {
    return px(columnDip(m, panel_w_dip), scale);
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

/// A rail tile's label (Mac `PaneSidebarText.monogram`). Every terminal shares
/// one icon, so a tile needs text that tells panes apart: the part of the
/// title after a dash (`claude — relay` → `RE`, `claude — pane sidebar` →
/// `PS`), else a path's last component (`~/git/ghoztty` → `gho`), else the
/// command's first word with its path and extension gone (`pwsh`, `zsh`), up
/// to three characters. Windows adds the drive-letter and UNC path shapes a
/// shell titles itself with here (`C:\Program Files\PowerShell\7\pwsh.exe` →
/// `pws`). Written into `buf` as UTF-8.
pub fn monogram(title_raw: []const u8, buf: *[16]u8) []const u8 {
    const title = std.mem.trim(u8, title_raw, " \t");

    // `<command> — <what>`: the part that tells two panes apart.
    if (dashTail(title)) |tail| {
        var words: [2][]const u8 = undefined;
        var n: usize = 0;
        var it = WordIter{ .s = tail };
        while (it.next()) |w| {
            if (n < 2) words[n] = w;
            n += 1;
        }
        if (n >= 2) {
            var len: usize = 0;
            len += upperFirst(words[0], buf[len..]);
            len += upperFirst(words[1], buf[len..]);
            return buf[0..len];
        }
        if (n == 1) return upperPrefix(words[0], 2, buf);
    }

    // A path - what a shell titles itself by default: its last component,
    // and home is "~" itself (a mark, not a bullet).
    if (isPath(title)) {
        const last = lastComponent(title);
        if (last.len == 0 or std.mem.eql(u8, last, "~")) {
            buf[0] = if (std.mem.eql(u8, title, "/")) '/' else '~';
            return buf[0..1];
        }
        const m = lowerAlnumPrefix(stripExe(last), 3, buf);
        if (m.len > 0) return m;
    }

    // A command: its first word, minus any path ("/bin/zsh" -> "zsh").
    const first = blk: {
        const sp = std.mem.indexOfScalar(u8, title, ' ') orelse title.len;
        break :blk title[0..sp];
    };
    const m = lowerAlnumPrefix(stripExe(lastComponent(first)), 3, buf);
    if (m.len > 0) return m;

    // No letters at all: show what there is rather than nothing.
    var len: usize = 0;
    var cps: usize = 0;
    var view = std.unicode.Utf8View.init(title) catch return bullet(buf);
    var cit = view.iterator();
    while (cit.nextCodepointSlice()) |cp| {
        if (cp.len == 1 and std.ascii.isWhitespace(cp[0])) continue;
        if (len + cp.len > buf.len) break;
        @memcpy(buf[len..][0..cp.len], cp);
        len += cp.len;
        cps += 1;
        if (cps == 2) break;
    }
    if (len == 0) return bullet(buf);
    return buf[0..len];
}

/// The name a row shows (Mac `PaneSidebarText.title`). A terminal that never
/// set a title carries the ghost placeholder, which names nothing and gives a
/// rail tile no letters — so it falls back to the working directory's name,
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

/// The first line of a pane banner as plain text (Mac
/// `PaneSidebarText.bannerLine`): the banner markdown subset stripped to its
/// words. Table and rule lines are skipped - they are layout, not a summary.
/// Written into `buf`; null when nothing is left.
pub fn bannerLine(banner: ?[]const u8, buf: []u8) ?[]const u8 {
    const text = banner orelse return null;
    var lines = LineIter{ .s = text };
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '|') continue;
        if (isThematicBreak(line)) continue;
        const plain = stripInlineMarkdown(line, buf);
        if (plain.len == 0) return null;
        return plain;
    }
    return null;
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

fn bullet(buf: *[16]u8) []const u8 {
    const b = "\u{2022}";
    @memcpy(buf[0..b.len], b);
    return buf[0..b.len];
}

/// The text after " — " (em dash) or " - ", trimmed; null when neither.
fn dashTail(title: []const u8) ?[]const u8 {
    const seps = [_][]const u8{ " \u{2014} ", " - " };
    for (seps) |sep| {
        if (std.mem.indexOf(u8, title, sep)) |i| {
            return std.mem.trim(u8, title[i + sep.len ..], " \t");
        }
    }
    return null;
}

fn isPath(t: []const u8) bool {
    if (std.mem.eql(u8, t, "~")) return true;
    if (std.mem.startsWith(u8, t, "~/") or std.mem.startsWith(u8, t, "~\\")) return true;
    if (std.mem.startsWith(u8, t, "/") or std.mem.startsWith(u8, t, "\\\\")) return true;
    // `C:\...` / `C:/...`
    return t.len >= 3 and std.ascii.isAlphabetic(t[0]) and t[1] == ':' and
        (t[2] == '\\' or t[2] == '/');
}

fn lastComponent(p: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, p, "/\\");
    if (trimmed.len == 0) return p[0..@min(p.len, 1)];
    const i = std.mem.lastIndexOfAny(u8, trimmed, "/\\") orelse return trimmed;
    return trimmed[i + 1 ..];
}

/// `pwsh.exe` -> `pwsh`: Windows titles a shell by its executable.
fn stripExe(name: []const u8) []const u8 {
    if (name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".exe"))
        return name[0 .. name.len - 4];
    return name;
}

/// Whether a codepoint counts as a letter or digit. ASCII is classified;
/// anything beyond it is taken as a letter (a CJK or accented title still
/// gets a monogram rather than a bullet).
fn isWordCp(cp: []const u8) bool {
    if (cp.len == 1) return std.ascii.isAlphanumeric(cp[0]);
    return true;
}

const WordIter = struct {
    s: []const u8,
    i: usize = 0,

    fn next(self: *WordIter) ?[]const u8 {
        // Skip separators.
        while (self.i < self.s.len) {
            const n = std.unicode.utf8ByteSequenceLength(self.s[self.i]) catch 1;
            const end = @min(self.i + n, self.s.len);
            if (isWordCp(self.s[self.i..end])) break;
            self.i = end;
        }
        if (self.i >= self.s.len) return null;
        const start = self.i;
        while (self.i < self.s.len) {
            const n = std.unicode.utf8ByteSequenceLength(self.s[self.i]) catch 1;
            const end = @min(self.i + n, self.s.len);
            if (!isWordCp(self.s[self.i..end])) break;
            self.i = end;
        }
        return self.s[start..self.i];
    }
};

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

/// The first codepoint of `word`, uppercased when ASCII. Returns bytes written.
fn upperFirst(word: []const u8, out: []u8) usize {
    if (word.len == 0) return 0;
    const n = @min(std.unicode.utf8ByteSequenceLength(word[0]) catch 1, word.len);
    if (n > out.len) return 0;
    @memcpy(out[0..n], word[0..n]);
    if (n == 1) out[0] = std.ascii.toUpper(out[0]);
    return n;
}

/// The first `max` codepoints of `word`, ASCII uppercased.
fn upperPrefix(word: []const u8, max: usize, buf: *[16]u8) []const u8 {
    var len: usize = 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i < word.len and count < max) {
        const n = @min(std.unicode.utf8ByteSequenceLength(word[i]) catch 1, word.len - i);
        if (len + n > buf.len) break;
        @memcpy(buf[len..][0..n], word[i..][0..n]);
        if (n == 1) buf[len] = std.ascii.toUpper(buf[len]);
        len += n;
        i += n;
        count += 1;
    }
    return buf[0..len];
}

/// The first `max` letters/digits of `s`, ASCII lowercased, skipping anything
/// else ("ghoztty-wt" -> "gho").
fn lowerAlnumPrefix(s: []const u8, max: usize, buf: *[16]u8) []const u8 {
    var len: usize = 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len and count < max) {
        const n = @min(std.unicode.utf8ByteSequenceLength(s[i]) catch 1, s.len - i);
        const cp = s[i..][0..n];
        i += n;
        if (!isWordCp(cp)) continue;
        if (len + n > buf.len) break;
        @memcpy(buf[len..][0..n], cp);
        if (n == 1) buf[len] = std.ascii.toLower(buf[len]);
        len += n;
        count += 1;
    }
    return buf[0..len];
}

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
};

pub const max_items: usize = 64;

/// The measured text metrics the expanded panel lays out against: one line of
/// the row title, one of the subtitle/caption.
pub const TextMetrics = struct {
    title_h: i32,
    caption_h: i32,
};

pub const Layout = struct {
    mode: Mode = .hidden,
    /// The unpinned card opened to full width over the grid (T1842): `mode`
    /// stays `.mini` - the column is still the rail's - but the rows are laid
    /// out as the panel's, inside `card`.
    open: bool = false,
    width: i32 = 0,
    height: i32 = 0,
    /// The raised card (mini only): the rail's, or the open card.
    card: Rect = .{},
    /// The pin button's painted square.
    pin: Rect = .{},
    /// The header band (expanded) holding the "PANES" caption.
    header: Rect = .{},
    /// Where the "PANES" caption starts (expanded).
    caption_x: i32 = 0,
    /// The STASHED caption band, when anything is stashed (expanded), and the
    /// hairline between the sections (both modes).
    stashed_caption: ?Rect = null,
    section_rule: ?Rect = null,
    /// One rect per item: an expanded row's fill, or a rail tile's square.
    items: [max_items]Rect = undefined,
    count: usize = 0,
    /// The grid/stashed boundary for the rail and the panel.
    first_stashed: usize = 0,
    /// The empty "Drop to stash" slot a drag with nothing stashed shows
    /// (T1844, `addDropSlot`): a row below the grid rows, or a tile on the
    /// rail.
    drop_slot: ?Rect = null,

    pub fn item(self: *const Layout, i: usize) Rect {
        return self.items[i];
    }

    /// An expanded row's hover button (stash / restore): the compact square
    /// at the row's trailing edge, `sm` inside its fill.
    pub fn rowButton(self: *const Layout, i: usize, scale: f32) Rect {
        const r = self.items[i];
        const b = px(row_button_dip, scale);
        const inset = px(sm_dip, scale);
        const top = r.top + @divTrunc(r.height() - b, 2);
        return .{ .left = r.right - inset - b, .top = top, .right = r.right - inset, .bottom = top + b };
    }
};

/// The expanded row's height: Mac's `SidePanelRow` padding around one or two
/// lines (title, then the subtitle in the caption size).
pub fn rowHeight(two_line: bool, tm: TextMetrics, scale: f32) i32 {
    const lines = tm.title_h + if (two_line) tm.caption_h else 0;
    return lines + 2 * px(toc.row_v_pad_dip, scale);
}

/// Lay the sidebar out in a `w` x `h` client area.
pub fn layout(m: Mode, w: i32, h: i32, items: []const Item, tm: TextMetrics, scale: f32) Layout {
    var l: Layout = .{ .mode = m, .width = w, .height = h };
    const n = @min(items.len, max_items);
    l.count = n;
    l.first_stashed = n;
    for (items[0..n], 0..) |it, i| {
        if (it.section == .stashed) {
            l.first_stashed = i;
            break;
        }
    }
    switch (m) {
        .hidden => l.count = 0,
        .expanded => layoutRows(&l, .{ .right = w, .bottom = h }, items[0..n], tm, scale),
        .mini => layoutMini(&l, scale),
    }
    return l;
}

/// The window the open card is drawn in: the rail's margin, the panel's
/// width, and the margin again (Mac's host frame, `insets.leading +
/// state.width + insets.trailing`). Only the column and the card itself are
/// ever painted or hit; the trailing margin belongs to the grid underneath.
pub fn openWidthPx(panel_w_dip: f32, scale: f32) i32 {
    const margin = px(rail_margin_dip, scale);
    return margin + px(clampWidth(panel_w_dip), scale) + margin;
}

/// Lay out the unpinned card opened over the grid (T1842) in a `w` x `h`
/// window (`w` from `openWidthPx`): the raised card at the rail's margins,
/// as wide as the panel, holding the panel's header and rows.
pub fn layoutOpen(w: i32, h: i32, items: []const Item, tm: TextMetrics, scale: f32) Layout {
    var l: Layout = .{ .mode = .mini, .open = true, .width = w, .height = h };
    const n = @min(items.len, max_items);
    l.count = n;
    l.first_stashed = n;
    for (items[0..n], 0..) |it, i| {
        if (it.section == .stashed) {
            l.first_stashed = i;
            break;
        }
    }
    const margin = px(rail_margin_dip, scale);
    l.card = .{ .left = margin, .top = margin, .right = @max(w - margin, margin), .bottom = @max(h - margin, margin) };
    layoutRows(&l, l.card, items[0..n], tm, scale);
    return l;
}

/// The panel's header and rows inside `area`: the pinned panel's whole
/// window, or the open card.
fn layoutRows(l: *Layout, area: Rect, items: []const Item, tm: TextMetrics, scale: f32) void {
    const sm = px(sm_dip, scale);
    const btn = px(button_dip, scale);
    // The header band holds the caption at the TOC's header padding and the
    // pin with `sm` clear above and below it, whichever is taller - the band
    // is sized to its control, never the reverse (design system §0).
    const header_h = @max(toc.headerHeight(tm.caption_h, scale), btn + 2 * sm);
    l.header = .{ .left = area.left, .top = area.top, .right = area.right, .bottom = area.top + header_h };
    l.caption_x = area.left + px(toc.label_inset_dip, scale);
    const pin_top = area.top + @divTrunc(header_h - btn, 2);
    l.pin = .{ .left = area.right - sm - btn, .top = pin_top, .right = area.right - sm, .bottom = pin_top + btn };

    const fill = px(toc.fill_inset_dip, scale);
    const gap = @max(px(1, scale), 1);
    var y = l.header.bottom;
    for (items, 0..) |it, i| {
        if (i == l.first_stashed) {
            // A hairline, then the STASHED caption at the header's padding.
            const rule_y = y + sm;
            l.section_rule = .{ .left = area.left + fill, .top = rule_y, .right = area.right - fill, .bottom = rule_y + @max(px(1, scale), 1) };
            const cap_h = toc.headerHeight(tm.caption_h, scale);
            l.stashed_caption = .{ .left = area.left, .top = rule_y + sm, .right = area.right, .bottom = rule_y + sm + cap_h };
            y = rule_y + sm + cap_h;
        } else if (i != 0) {
            y += gap;
        }
        const rh = rowHeight(it.two_line, tm, scale);
        l.items[i] = .{ .left = area.left + fill, .top = y, .right = area.right - fill, .bottom = y + rh };
        y += rh;
    }
}

fn layoutMini(l: *Layout, scale: f32) void {
    const margin = px(rail_margin_dip, scale);
    const card_w = px(rail_card_dip, scale);
    l.card = .{ .left = margin, .top = margin, .right = margin + card_w, .bottom = @max(l.height - margin, margin + card_w) };
    const tile = px(tile_dip, scale);
    // Centered in the card from ONE rounded inset, so the tile's left and
    // right clearances cannot round apart.
    const inset = @divTrunc(card_w - tile, 2);
    const x = l.card.left + inset;
    l.pin = .{ .left = x, .top = l.card.top + inset, .right = x + tile, .bottom = l.card.top + inset + tile };
    const gap = px(tile_gap_dip, scale);
    var y = l.pin.bottom + px(rail_group_gap_dip, scale);
    for (0..l.count) |i| {
        if (i == l.first_stashed and i != 0) {
            // The hairline sits in the middle of an `md` gap.
            const group = px(rail_group_gap_dip, scale);
            const rule_y = y - gap + @divTrunc(group, 2);
            l.section_rule = .{ .left = x, .top = rule_y, .right = x + tile, .bottom = rule_y + @max(px(1, scale), 1) };
            y += group - gap;
        }
        l.items[i] = .{ .left = x, .top = y, .right = x + tile, .bottom = y + tile };
        y += tile + gap;
    }
}

/// Add the empty "Drop to stash - it keeps running" slot below the grid
/// rows (T1844, Mac's empty stash target): shown only during a pane drag
/// with nothing stashed, so the target is visible. Behind the same section
/// rule a stash would have; a one-line row in the panel and the open card, a
/// tile on the rail. A no-op when something is stashed or nothing is shown.
pub fn addDropSlot(l: *Layout, tm: TextMetrics, scale: f32) void {
    if (l.mode == .hidden) return;
    if (l.first_stashed != l.count) return;
    const sm = px(sm_dip, scale);
    const hair = @max(px(1, scale), 1);
    const rows = l.mode == .expanded or l.open;
    if (rows) {
        const area: Rect = if (l.open) l.card else .{ .right = l.width, .bottom = l.height };
        const fill = px(toc.fill_inset_dip, scale);
        const below = if (l.count > 0) l.items[l.count - 1].bottom else l.header.bottom;
        const rule_y = below + sm;
        l.section_rule = .{ .left = area.left + fill, .top = rule_y, .right = area.right - fill, .bottom = rule_y + hair };
        const top = rule_y + hair + sm;
        l.drop_slot = .{ .left = area.left + fill, .top = top, .right = area.right - fill, .bottom = top + rowHeight(false, tm, scale) };
        return;
    }
    const tile = px(tile_dip, scale);
    const group = px(rail_group_gap_dip, scale);
    const x = l.pin.left;
    // The same spacing a stashed group gets: `md` below the last tile, the
    // hairline in the middle of it.
    const below = if (l.count > 0) l.items[l.count - 1].bottom else l.pin.bottom;
    const rule_y = below + @divTrunc(group, 2);
    l.section_rule = .{ .left = x, .top = rule_y, .right = x + tile, .bottom = rule_y + hair };
    const top = below + group;
    l.drop_slot = .{ .left = x, .top = top, .right = x + tile, .bottom = top + tile };
}

pub const Hit = union(enum) {
    none,
    pin,
    /// An item's body (row or tile).
    item: usize,
    /// An expanded row's hover button.
    item_button: usize,
};

pub fn hitTest(l: *const Layout, x: i32, y: i32, scale: f32) Hit {
    if (l.mode == .hidden) return .none;
    if (l.pin.contains(x, y)) return .pin;
    const rows = l.mode == .expanded or l.open;
    for (0..l.count) |i| {
        const r = l.items[i];
        // Rows span to the panel's (or the open card's) edges for hit
        // purposes - the fill inset is paint, and a click in it still means
        // that row.
        const hit_r: Rect = if (l.mode == .expanded)
            .{ .left = 0, .top = r.top, .right = l.width, .bottom = r.bottom }
        else if (l.open)
            .{ .left = l.card.left, .top = r.top, .right = l.card.right, .bottom = r.bottom }
        else
            r;
        if (!hit_r.contains(x, y)) continue;
        if (rows and l.rowButton(i, scale).contains(x, y)) return .{ .item_button = i };
        return .{ .item = i };
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "pane_sidebar: mode follows pin, hidden and the narrow-window fallback" {
    try testing.expectEqual(Mode.hidden, mode(true, true, 1200));
    try testing.expectEqual(Mode.hidden, mode(false, true, 1200));
    try testing.expectEqual(Mode.expanded, mode(true, false, 720));
    try testing.expectEqual(Mode.mini, mode(true, false, 719));
    try testing.expectEqual(Mode.mini, mode(false, false, 1200));
}

test "pane_sidebar: the rail column is Mac's 68, and the panel width is clamped" {
    try testing.expectEqual(@as(f32, 68), railColumnDip());
    try testing.expectEqual(@as(f32, 0), columnDip(.hidden, 240));
    try testing.expectEqual(@as(f32, 68), columnDip(.mini, 240));
    try testing.expectEqual(@as(f32, 240), columnDip(.expanded, 240));
    try testing.expectEqual(@as(f32, 180), columnDip(.expanded, 50));
    try testing.expectEqual(@as(f32, 380), columnDip(.expanded, 900));
    try testing.expectEqual(@as(i32, 85), columnPx(.mini, 240, 1.25));
}

fn expectMono(want: []const u8, title: []const u8) !void {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings(want, monogram(title, &buf));
}

test "pane_sidebar: monogram rules (Mac's cases, plus Windows paths)" {
    try expectMono("RE", "claude \u{2014} relay");
    try expectMono("PS", "claude \u{2014} pane-sidebar");
    try expectMono("PS", "claude - pane sidebar");
    try expectMono("zsh", "zsh");
    try expectMono("npm", "npm run dev");
    try expectMono("zsh", "/bin/zsh");
    try expectMono("gho", "~/git/ghoztty");
    try expectMono("~", "~");
    try expectMono("~", "~/");
    try expectMono("/", "/");
    try expectMono("pws", "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
    try expectMono("cmd", "C:\\WINDOWS\\system32\\cmd.exe");
    try expectMono("gho", "D:\\git\\ghoztty");
    try expectMono("\u{2022}", "   ");
    try expectMono("??", "???");
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
};

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
        // Left and right clearances inside the card are equal.
        const left = l.items[0].left - l.card.left;
        const right = l.card.right - l.items[0].right;
        try testing.expect(@abs(left - right) <= 1);
        // The pin is the same square as a tile, on the same column.
        try testing.expectEqual(l.items[0].width(), l.pin.width());
        try testing.expectEqual(l.items[0].left, l.pin.left);
        // Nothing touches: >= sm between consecutive tiles and pin/first tile.
        const sm = px(sm_dip, s);
        try testing.expect(l.items[0].top - l.pin.bottom >= sm);
        try testing.expect(l.items[1].top - l.items[0].bottom >= sm);
        // The section hairline sits strictly between the groups.
        const rule = l.section_rule.?;
        try testing.expect(rule.top >= l.items[1].bottom and rule.bottom <= l.items[2].top);
        // The card keeps the rail margin from the column's edges.
        try testing.expectEqual(px(rail_margin_dip, s), l.card.left);
        try testing.expectEqual(w - px(rail_margin_dip, s), l.card.right);
    }
}

test "pane_sidebar: expanded rows stack under the header, with the STASHED caption between sections" {
    const items = [_]Item{ .{ .section = .grid, .two_line = true }, .{ .section = .grid }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        const w = px(240, s);
        const l = layout(.expanded, w, px(600, s), &items, tm, s);
        // The pin keeps sm clear of the header band on every side it touches.
        const sm = px(sm_dip, s);
        try testing.expect(l.pin.top >= sm and l.header.bottom - l.pin.bottom >= sm);
        try testing.expectEqual(w - sm, l.pin.right);
        // Rows are below the header, in order, without overlap.
        try testing.expect(l.items[0].top >= l.header.bottom);
        try testing.expect(l.items[1].top >= l.items[0].bottom);
        try testing.expect(l.items[0].height() > l.items[1].height());
        const cap = l.stashed_caption.?;
        try testing.expect(cap.top >= l.items[1].bottom and l.items[2].top >= cap.bottom);
        // The hover button sits inside its row, sm from the trailing edge.
        const b = l.rowButton(0, s);
        try testing.expectEqual(l.items[0].right - sm, b.right);
        try testing.expect(b.top >= l.items[0].top and b.bottom <= l.items[0].bottom);
    }
}

test "pane_sidebar: hit testing finds the pin, rows, row buttons and nothing" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    const s: f32 = 1.0;
    const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
    const l = layout(.expanded, 240, 600, &items, tm, s);
    try testing.expectEqual(Hit.pin, hitTest(&l, l.pin.centerX(), l.pin.centerY(), s));
    try testing.expectEqual(Hit{ .item = 0 }, hitTest(&l, 2, l.items[0].centerY(), s));
    const b = l.rowButton(1, s);
    try testing.expectEqual(Hit{ .item_button = 1 }, hitTest(&l, b.centerX(), b.centerY(), s));
    try testing.expectEqual(Hit.none, hitTest(&l, 100, 590, s));

    const rail = layout(.mini, 68, 600, &items, tm, s);
    try testing.expectEqual(Hit{ .item = 1 }, hitTest(&rail, rail.items[1].centerX(), rail.items[1].centerY(), s));
    try testing.expectEqual(Hit.pin, hitTest(&rail, rail.pin.centerX(), rail.pin.centerY(), s));

    const hidden = layout(.hidden, 0, 600, &items, tm, s);
    try testing.expectEqual(Hit.none, hitTest(&hidden, 0, 0, s));
}

test "pane_sidebar: the open card floats at the rail's margins, as wide as the panel, with the panel's rows" {
    const items = [_]Item{ .{ .section = .grid, .two_line = true }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        const w = openWidthPx(240, s);
        const h = px(600, s);
        const l = layout(.mini, columnPx(.mini, 240, s), h, &items, tm, s);
        const o = layoutOpen(w, h, &items, tm, s);
        try testing.expect(o.open and o.mode == .mini);
        // Same margins as the rail's card: it grows rightward from where the
        // rail's card already stands, never moving its top-left.
        try testing.expectEqual(l.card.left, o.card.left);
        try testing.expectEqual(l.card.top, o.card.top);
        try testing.expectEqual(l.card.bottom, o.card.bottom);
        // As wide as the panel, with the margin left over on the right.
        try testing.expectEqual(px(240, s), o.card.width());
        try testing.expectEqual(w - px(rail_margin_dip, s), o.card.right);
        // Everything sits inside the card: header, pin, rows, row buttons.
        try testing.expect(o.header.left == o.card.left and o.header.top == o.card.top);
        try testing.expect(o.pin.right <= o.card.right and o.pin.top >= o.card.top);
        try testing.expect(o.caption_x > o.card.left);
        for (0..o.count) |i| {
            try testing.expect(o.items[i].left > o.card.left and o.items[i].right < o.card.right);
            try testing.expect(o.items[i].top >= o.header.bottom);
            const b = o.rowButton(i, s);
            try testing.expect(b.right <= o.items[i].right);
        }
        try testing.expect(o.stashed_caption != null);
        // Clamped like the panel.
        try testing.expectEqual(openWidthPx(380, s), openWidthPx(900, s));
    }
}

test "pane_sidebar: hit testing the open card finds rows across the card, buttons and the pin, and nothing past it" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    const s: f32 = 1.0;
    const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
    const o = layoutOpen(openWidthPx(240, s), 600, &items, tm, s);
    try testing.expectEqual(Hit.pin, hitTest(&o, o.pin.centerX(), o.pin.centerY(), s));
    try testing.expectEqual(Hit{ .item = 0 }, hitTest(&o, o.card.left + 1, o.items[0].centerY(), s));
    const b = o.rowButton(1, s);
    try testing.expectEqual(Hit{ .item_button = 1 }, hitTest(&o, b.centerX(), b.centerY(), s));
    // The trailing margin is the grid's, not the card's.
    try testing.expectEqual(Hit.none, hitTest(&o, o.card.right + 2, o.items[0].centerY(), s));
}

test "pane_sidebar: a drag with nothing stashed shows the drop slot below the grid (T1844)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .grid, .two_line = true } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        // The panel: a one-line row behind a rule, under the last row.
        var l = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        addDropSlot(&l, tm, s);
        const slot = l.drop_slot.?;
        const rule = l.section_rule.?;
        try testing.expect(rule.top >= l.items[1].bottom and slot.top >= rule.bottom);
        try testing.expectEqual(rowHeight(false, tm, s), slot.height());
        try testing.expectEqual(l.items[1].left, slot.left);
        try testing.expectEqual(l.items[1].right, slot.right);
        // The rail: a tile on the tiles' column, spaced like a stashed group.
        var m = layout(.mini, columnPx(.mini, 240, s), px(600, s), &items, tm, s);
        addDropSlot(&m, tm, s);
        const tile = m.drop_slot.?;
        try testing.expectEqual(m.items[0].left, tile.left);
        try testing.expectEqual(m.items[0].width(), tile.width());
        try testing.expectEqual(m.items[1].bottom + px(rail_group_gap_dip, s), tile.top);
        try testing.expect(m.section_rule.?.top > m.items[1].bottom and m.section_rule.?.bottom <= tile.top);
        // The open card: inside the card.
        var o = layoutOpen(openWidthPx(240, s), px(600, s), &items, tm, s);
        addDropSlot(&o, tm, s);
        try testing.expect(o.drop_slot.?.left >= o.card.left and o.drop_slot.?.right <= o.card.right);
    }
}

test "pane_sidebar: no drop slot once something is stashed, or while hidden (T1844)" {
    const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
    const stashed = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    var l = layout(.expanded, 240, 600, &stashed, tm, 1.0);
    addDropSlot(&l, tm, 1.0);
    try testing.expectEqual(@as(?Rect, null), l.drop_slot);
    const grid = [_]Item{.{ .section = .grid }};
    var h = layout(.hidden, 240, 600, &grid, tm, 1.0);
    addDropSlot(&h, tm, 1.0);
    try testing.expectEqual(@as(?Rect, null), h.drop_slot);
}
