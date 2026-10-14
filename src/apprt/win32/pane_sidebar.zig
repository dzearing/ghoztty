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
const pane_elevation = @import("pane_elevation.zig");
const type_ramp = @import("type_ramp.zig");

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
/// Trash mode's x disc on a rail tile (Mac's 13 pt kill button).
pub const tile_kill_dip: f32 = 13;
/// The design system's default inset (`sm`).
pub const sm_dip: f32 = 4;

pub fn mode(pinned: bool, hidden: bool, window_w_dip: f32) Mode {
    if (hidden) return .hidden;
    if (pinned and window_w_dip >= narrow_window_dip) return .expanded;
    return .mini;
}

/// The space around the raised rail card, and around the open card that
/// grows from it (Mac `PaneSidebarState.RailInsets`, 557e4f978).
pub const RailInsets = struct {
    leading: f32,
    vertical: f32,
    trailing: f32,

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
    return switch (m) {
        .hidden => 0,
        .expanded => clampWidth(panel_w_dip),
        .mini => railColumnDipFor(elevated),
    };
}

pub fn columnPx(m: Mode, panel_w_dip: f32, scale: f32) i32 {
    return columnPxFor(m, panel_w_dip, scale, false);
}

pub fn columnPxFor(m: Mode, panel_w_dip: f32, scale: f32, elevated: bool) i32 {
    return switch (m) {
        // Summed from the rounded parts, so the column is exactly the
        // card's pixels plus its insets' at every scale.
        .mini => blk: {
            const in = railInsets(elevated);
            break :blk in.leadingPx(scale) + px(rail_card_dip, scale) + in.trailingPx(scale);
        },
        else => px(columnDipFor(m, panel_w_dip, elevated), scale),
    };
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

/// The question chip (T1889, Mac `PaneSidebarQuestionBadge` in a row or a
/// window header): the word "question" in an accent capsule. A STATUS CHIP
/// by design system §3.1's named exception, so it is the chooser's chip
/// exactly - one caption line plus `sm` tall (Mac's 15 pt), `sm` of padding
/// either side of the word (Mac's 6 pt, onto the scale), radius half its
/// height. The rail's corner keeps its small "?" disc, as Mac's does.
pub const question_label = "question";
pub const question_chip_pad_dip: f32 = sm_dip;

pub fn questionChipHeight(scale: f32) i32 {
    return px(type_ramp.caption_dip, scale) + px(sm_dip, scale);
}

/// The chip for a label `text_w` pixels wide, ending at `right` and centred
/// on `center_y`. Never narrower than it is tall, so it is always a capsule.
pub fn questionChip(right: i32, center_y: i32, text_w: i32, scale: f32) Rect {
    const h = questionChipHeight(scale);
    const w = @max(@max(text_w, 0) + 2 * px(question_chip_pad_dip, scale), h);
    const top = center_y - @divTrunc(h, 2);
    return .{ .left = right - w, .top = top, .right = right, .bottom = top + h };
}

/// The breathing ring around a chip (Mac: a 3 pt stroke padded 1.5 pt out):
/// the chip grown by `ring` on every side, so its radius - half ITS height -
/// keeps it the chip's shape rather than a disc's.
pub fn questionRing(chip: Rect, ring: i32) Rect {
    return .{ .left = chip.left - ring, .top = chip.top - ring, .right = chip.right + ring, .bottom = chip.bottom + ring };
}

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
};

pub const max_items: usize = 64;

/// One line of the all-windows outline the panel lays out
/// (`pane_sidebar_outline.buildLines` makes them).
pub const LineKind = enum { project, window, pane, rule, stashed_caption };
pub const Line = struct {
    kind: LineKind,
    /// A pane line's item; a head's (or stashed caption's) window group.
    index: usize = 0,
    /// Outline level: a project head and a lone window are 0, a window in a
    /// project 1, a window's panes one deeper than the window.
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
    /// Where the name starts.
    label_x: i32,
};

/// A STASHED caption inside a window group.
pub const Caption = struct {
    rect: Rect,
    x: i32,
    /// The window group whose stash it captions.
    index: usize,
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
    /// The all-windows toggle, left of the trash button (panel and open
    /// card; Mac drops its header buttons from the rail).
    scope: Rect = .{},
    /// The trash-mode toggle, between the all-windows toggle and the pin -
    /// Mac's header order (T1845).
    trash: Rect = .{},
    /// The all-windows search field under the header (T1877; outline in the
    /// panel and the open card only - empty otherwise), and its clear
    /// button at the trailing edge.
    search: Rect = .{},
    search_clear: Rect = .{},
    /// The field holds a query, so its clear button is a hit target. Set by
    /// the caller, as `quick_kill` is.
    search_text: bool = false,
    /// "No matching panes": the outline has no line to show (a search with
    /// no hit - an unfiltered outline always lists this window).
    no_match: ?Rect = null,
    /// Trash mode is on (T1845): a rail tile's corner x is a hit target. Set
    /// by the caller - the layout itself does not depend on it.
    quick_kill: bool = false,
    /// Laid out as the all-windows outline (T1829).
    outline: bool = false,
    /// THIS window's stashed items are `first_stashed..stash_end` - the rows
    /// a drop into the stash positions itself among.
    stash_end: usize = 0,
    /// Each item's content indent (outline level), in pixels.
    indent: [max_items]i32 = [_]i32{0} ** max_items,
    heads: [max_heads]Head = undefined,
    head_count: usize = 0,
    /// The outline's hairlines and STASHED captions (the single-window
    /// layout uses `section_rule` / `stashed_caption`).
    rules: [max_marks]Rect = undefined,
    rule_count: usize = 0,
    captions: [max_marks]Caption = undefined,
    caption_count: usize = 0,
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
    /// The scrolled region (T1878, `pane_sidebar_scroll.apply`): the rows
    /// below the header and search field, or the rail's tiles below its pin.
    /// Empty until a scroll pass ran, which leaves hit-testing unclipped.
    viewport: Rect = .{},
    /// How far the content is scrolled up, already clamped to `0..max_scroll`.
    scroll: i32 = 0,
    max_scroll: i32 = 0,
    /// The project head pinned to the viewport's top (Mac's sticky section
    /// header), an index into `heads`.
    sticky: ?usize = null,

    pub fn item(self: *const Layout, i: usize) Rect {
        return self.items[i];
    }

    /// Whether item `i` has a place on screen: a pane in a folded group of
    /// the outline has none in the panel (the rail still shows it).
    pub fn shown(self: *const Layout, i: usize) bool {
        return self.items[i].width() > 0;
    }

    fn addRule(self: *Layout, r: Rect) void {
        if (self.rule_count == max_marks) return;
        self.rules[self.rule_count] = r;
        self.rule_count += 1;
    }

    /// An expanded row's hover button (stash / restore): the compact square
    /// at the row's trailing edge, `sm` inside its fill.
    /// Trash mode's x on a rail tile (T1845): a small disc on the tile's
    /// top-left corner, overhanging it the way the question badge overhangs
    /// the top-right one - so the two never cover each other.
    pub fn tileKill(self: *const Layout, i: usize, scale: f32) Rect {
        const r = self.items[i];
        const d = px(tile_kill_dip, scale);
        const over = px(2, scale);
        return .{ .left = r.left - over, .top = r.top - over, .right = r.left - over + d, .bottom = r.top - over + d };
    }

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
    findStash(&l, items[0..n]);
    switch (m) {
        .hidden => l.count = 0,
        .expanded => if (lines) |ls| {
            const area: Rect = .{ .right = w, .bottom = h };
            layoutHeader(&l, area, tm, scale);
            layoutSearch(&l, area, tm, scale);
            layoutLines(&l, area, items[0..n], ls, tm, scale);
        } else layoutRows(&l, .{ .right = w, .bottom = h }, items[0..n], tm, scale),
        .mini => layoutMini(&l, items[0..n], scale, insets),
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

/// The window the open card is drawn in: the rail's margin, the panel's
/// width, and the margin again (Mac's host frame, `insets.leading +
/// state.width + insets.trailing`). Only the column and the card itself are
/// ever painted or hit; the trailing margin belongs to the grid underneath.
pub fn openWidthPx(panel_w_dip: f32, scale: f32) i32 {
    return openWidthPxIn(panel_w_dip, scale, railInsets(false));
}

pub fn openWidthPxIn(panel_w_dip: f32, scale: f32, insets: RailInsets) i32 {
    return insets.leadingPx(scale) + px(clampWidth(panel_w_dip), scale) + insets.trailingPx(scale);
}

/// How much room the open card leaves trailing for its drop shadow to fall
/// on the grid (T1865): the banner card's 8 DIP blur. The flat style's rail
/// margin (12 DIP) already covers it; the elevated style's rail has no
/// trailing inset at all, so without this its card's shadow stopped dead at
/// the window's right edge.
pub const open_shadow_room_dip: f32 = 8;

/// The open card's insets: the rail's, with at least `open_shadow_room_dip`
/// trailing. Pass these to `openWidthPxIn`, `openCardRect` and
/// `layoutOpenIn` for the open card.
pub fn openInsets(insets: RailInsets) RailInsets {
    var o = insets;
    o.trailing = @max(o.trailing, open_shadow_room_dip);
    return o;
}

/// The open card's rect in its `w` x `h` window.
pub fn openCardRect(w: i32, h: i32, scale: f32, insets: RailInsets) Rect {
    const lead = insets.leadingPx(scale);
    const v = insets.verticalPx(scale);
    return .{ .left = lead, .top = v, .right = @max(w - insets.trailingPx(scale), lead), .bottom = @max(h - v, v) };
}

/// Lay out the unpinned card opened over the grid (T1842) in a `w` x `h`
/// window (`w` from `openWidthPx`): the raised card at the rail's margins,
/// as wide as the panel, holding the panel's header and rows.
pub fn layoutOpen(w: i32, h: i32, items: []const Item, tm: TextMetrics, scale: f32) Layout {
    return layoutOpenWith(w, h, items, null, tm, scale);
}

pub fn layoutOpenWith(w: i32, h: i32, items: []const Item, lines: ?[]const Line, tm: TextMetrics, scale: f32) Layout {
    return layoutOpenIn(w, h, items, lines, tm, scale, railInsets(false));
}

pub fn layoutOpenIn(w: i32, h: i32, items: []const Item, lines: ?[]const Line, tm: TextMetrics, scale: f32, insets: RailInsets) Layout {
    var l: Layout = .{ .mode = .mini, .open = true, .width = w, .height = h };
    const n = @min(items.len, max_items);
    l.count = n;
    l.outline = lines != null;
    findStash(&l, items[0..n]);
    l.card = openCardRect(w, h, scale, insets);
    if (lines) |ls| {
        layoutHeader(&l, l.card, tm, scale);
        layoutSearch(&l, l.card, tm, scale);
        layoutLines(&l, l.card, items[0..n], ls, tm, scale);
    } else layoutRows(&l, l.card, items[0..n], tm, scale);
    return l;
}

/// The header band: the caption at the TOC's header padding, the pin with
/// `sm` clear above and below it - whichever is taller, since the band is
/// sized to its control, never the reverse (design system §0) - and the
/// all-windows toggle beside the pin.
fn layoutHeader(l: *Layout, area: Rect, tm: TextMetrics, scale: f32) void {
    const sm = px(sm_dip, scale);
    const btn = px(button_dip, scale);
    const header_h = @max(toc.headerHeight(tm.caption_h, scale), btn + 2 * sm);
    l.header = .{ .left = area.left, .top = area.top, .right = area.right, .bottom = area.top + header_h };
    l.caption_x = area.left + px(toc.label_inset_dip, scale);
    const pin_top = area.top + @divTrunc(header_h - btn, 2);
    l.pin = .{ .left = area.right - sm - btn, .top = pin_top, .right = area.right - sm, .bottom = pin_top + btn };
    // Mac's header buttons sit 2 pt apart.
    const gap = px(2, scale);
    l.trash = .{ .left = l.pin.left - gap - btn, .top = pin_top, .right = l.pin.left - gap, .bottom = pin_top + btn };
    l.scope = .{ .left = l.trash.left - gap - btn, .top = pin_top, .right = l.trash.left - gap, .bottom = pin_top + btn };
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

/// The panel's header and rows inside `area`: the pinned panel's whole
/// window, or the open card.
fn layoutRows(l: *Layout, area: Rect, items: []const Item, tm: TextMetrics, scale: f32) void {
    const sm = px(sm_dip, scale);
    layoutHeader(l, area, tm, scale);

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

/// The all-windows outline's lines inside `area`, below the header (T1829;
/// Mac `PaneSidebarWindowHeader` / `PaneSidebarProjectHeader` / the outline
/// rows). A window head is a one-line row; a project head is the caption-size
/// label with Mac's 10 DIP above (4 for the very first line) and 5 below. A
/// pane row's FILL spans the panel, as a row's does; only its content is
/// indented, by one chevron and its gap per level. Items no line names - the
/// panes of a folded group - get an empty rect.
fn layoutLines(l: *Layout, area: Rect, items: []const Item, lines: []const Line, tm: TextMetrics, scale: f32) void {
    const sm = px(sm_dip, scale);
    const fill = px(toc.fill_inset_dip, scale);
    const label = px(toc.label_inset_dip, scale);
    const hair = @max(px(1, scale), 1);
    const step = px(outline_step_dip, scale);
    const chev = px(chevron_dip, scale);
    const chev_gap = px(chevron_gap_dip, scale);
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
        const depth: i32 = ln.depth;
        switch (ln.kind) {
            .project, .window => {
                const is_project = ln.kind == .project;
                const top_pad = if (is_project) px(if (prev == null) 4 else 10, scale) else 0;
                const text_h = if (is_project) tm.caption_h else tm.title_h;
                const h = if (is_project) top_pad + tm.caption_h + px(5, scale) else rowHeight(false, tm, scale);
                if (!is_project and prev == .pane) y += hair;
                const text_top = if (is_project) y + top_pad else y + @divTrunc(h - text_h, 2);
                const cx = area.left + label + depth * step;
                const cy = text_top + @divTrunc(text_h - chev, 2);
                if (l.head_count < max_heads) {
                    l.heads[l.head_count] = .{
                        .kind = if (is_project) .project else .window,
                        .index = ln.index,
                        .depth = ln.depth,
                        .rect = .{ .left = area.left + fill, .top = y, .right = area.right - fill, .bottom = y + h },
                        .chevron = .{ .left = cx, .top = cy, .right = cx + chev, .bottom = cy + chev },
                        .label_x = cx + chev + chev_gap,
                    };
                    l.head_count += 1;
                }
                y += h;
            },
            .pane => {
                if (prev == .pane) y += hair;
                if (ln.index >= l.count) continue;
                const rh = rowHeight(items[ln.index].two_line, tm, scale);
                l.items[ln.index] = .{ .left = area.left + fill, .top = y, .right = area.right - fill, .bottom = y + rh };
                l.indent[ln.index] = depth * step;
                y += rh;
            },
            .rule => {
                // Mac's divider: 8 above (here `sm` on both sides, as the
                // single roster's section rule), inset to the label column.
                const rule_y = y + sm;
                l.addRule(.{ .left = area.left + label + depth * step, .top = rule_y, .right = area.right - label, .bottom = rule_y + hair });
                y = rule_y + hair + sm;
            },
            .stashed_caption => {
                const cap_h = toc.headerHeight(tm.caption_h, scale);
                if (l.caption_count < max_marks) {
                    l.captions[l.caption_count] = .{
                        .rect = .{ .left = area.left, .top = y, .right = area.right, .bottom = y + cap_h },
                        .x = area.left + label + depth * step,
                        .index = ln.index,
                    };
                    l.caption_count += 1;
                }
                y += cap_h;
            },
        }
        prev = ln.kind;
    }
}

fn layoutMini(l: *Layout, items: []const Item, scale: f32, insets: RailInsets) void {
    const lead = insets.leadingPx(scale);
    const v = insets.verticalPx(scale);
    const card_w = px(rail_card_dip, scale);
    l.card = .{ .left = lead, .top = v, .right = lead + card_w, .bottom = @max(l.height - v, v + card_w) };
    const tile = px(tile_dip, scale);
    // Centered in the card from ONE rounded inset, so the tile's left and
    // right clearances cannot round apart.
    const inset = @divTrunc(card_w - tile, 2);
    const x = l.card.left + inset;
    l.pin = .{ .left = x, .top = l.card.top + inset, .right = x + tile, .bottom = l.card.top + inset + tile };
    const gap = px(tile_gap_dip, scale);
    var y = l.pin.bottom + px(rail_group_gap_dip, scale);
    for (0..l.count) |i| {
        // A hairline between this window's grid and its stash; in the
        // outline, also between one window's tiles and the next's (Mac: "in
        // the mini rail, windows are separated by a hairline").
        const breaks = if (l.outline)
            i != 0 and (items[i].group != items[i - 1].group or
                (items[i].section == .stashed and items[i - 1].section != .stashed))
        else
            i == l.first_stashed and i != 0;
        if (breaks) {
            // The hairline sits in the middle of an `md` gap.
            const group = px(rail_group_gap_dip, scale);
            const rule_y = y - gap + @divTrunc(group, 2);
            const rule: Rect = .{ .left = x, .top = rule_y, .right = x + tile, .bottom = rule_y + @max(px(1, scale), 1) };
            if (l.outline) l.addRule(rule) else l.section_rule = rule;
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
    // The outline places no empty slot: its own group sits among others, and
    // the whole sidebar is the stash target either way.
    if (l.outline) return;
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
    /// The all-windows toggle.
    scope,
    /// The trash-mode toggle (T1845).
    trash,
    /// The all-windows search field, and its clear button (T1877).
    search,
    search_clear,
    /// An outline header's body (an index into the layout's heads).
    head: usize,
    /// An outline header's chevron column: fold, never raise.
    head_fold: usize,
};

pub fn hitTest(l: *const Layout, x: i32, y: i32, scale: f32) Hit {
    if (l.mode == .hidden) return .none;
    if (l.pin.contains(x, y)) return .pin;
    const rows = l.mode == .expanded or l.open;
    if (rows and l.scope.contains(x, y)) return .scope;
    if (rows and l.trash.contains(x, y)) return .trash;
    if (rows and l.search.contains(x, y)) {
        return if (l.search_text and l.search_clear.contains(x, y)) .search_clear else .search;
    }
    // Below the controls everything scrolls (T1878): what the scroll moved
    // out of the viewport is out of reach, whatever its rect says.
    if (l.viewport.height() > 0 and !l.viewport.contains(x, y)) return .none;
    // Trash mode's corner x on a tile wins over the tile it sits on.
    if (!rows and l.quick_kill) for (0..l.count) |i| {
        if (l.tileKill(i, scale).contains(x, y)) return .{ .item_button = i };
    };
    for (l.heads[0..l.head_count], 0..) |hd, k| {
        const hit_r = rowHitRect(l, hd.rect);
        if (!hit_r.contains(x, y)) continue;
        return if (x < hd.label_x) .{ .head_fold = k } else .{ .head = k };
    }
    for (0..l.count) |i| {
        if (!l.shown(i)) continue;
        const hit_r = rowHitRect(l, l.items[i]);
        if (!hit_r.contains(x, y)) continue;
        if (rows and l.rowButton(i, scale).contains(x, y)) return .{ .item_button = i };
        return .{ .item = i };
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Edge drag (T1846; Mac `PaneSidebarChrome.resizeHandle`)

/// The resize handle's grab band (Mac `SidePanelResizeHandle.grabWidth`).
pub const grab_dip: f32 = 7;
/// A rail pulled out past this pins (Mac `expandThreshold`). A pinned panel
/// dragged narrow just stops at `min_width_dip`: it never unpins itself
/// under a drag, which read as the panel jumping away mid-resize.
pub const expand_threshold_dip: f32 = 120;

/// Whether (`x`, `y`) is on the edge that drags. The pinned panel's band
/// sits inside its trailing edge (the column, and so this window, ends
/// there); a card's - the rail's, or the open one's - straddles the card's
/// trailing edge, as Mac's handle does.
pub fn onEdge(l: *const Layout, x: i32, y: i32, scale: f32) bool {
    const g = @max(px(grab_dip, scale), 1);
    return switch (l.mode) {
        .hidden => false,
        .expanded => x >= l.width - g and x < l.width and y >= 0 and y < l.height and !onButton(l, x, y, scale),
        .mini => blk: {
            // A card flush with the window's trailing edge (the elevated
            // rail, T1850) keeps the whole band inside: half of it would
            // otherwise fall past the window, where nothing receives it.
            const left = @min(l.card.right - @divTrunc(g, 2), l.width - g);
            break :blk x >= left and x < left + g and y >= l.card.top and y < l.card.bottom;
        },
    };
}

/// The pin and the row buttons sit `sm` from the panel's edge, inside the
/// band: a press on one of them is that button's, never a resize.
fn onButton(l: *const Layout, x: i32, y: i32, scale: f32) bool {
    if (l.pin.contains(x, y)) return true;
    for (0..l.count) |i| {
        if (l.shown(i) and l.rowButton(i, scale).contains(x, y)) return true;
    }
    return false;
}

/// What an edge drag measures from (Mac `currentWidth`): the rail's card,
/// or the panel - pinned, or opened over the grid.
pub fn edgeStartDip(m: Mode, open: bool, panel_w_dip: f32) f32 {
    return if (m == .mini and !open) rail_card_dip else clampWidth(panel_w_dip);
}

pub const EdgeDrag = union(enum) {
    /// The rail was pulled out far enough: pin it open.
    pin,
    /// The panel's new preferred width, already clamped.
    width: f32,
};

/// An edge drag `dx_dip` from where it started at `start_dip`. The rail only
/// pins (null until it is pulled past the threshold); a panel, pinned or
/// open, takes the clamped width and stops at the bounds.
pub fn edgeDrag(m: Mode, open: bool, start_dip: f32, dx_dip: f32) ?EdgeDrag {
    const proposed = start_dip + dx_dip;
    return switch (m) {
        .hidden => null,
        .mini => if (open)
            .{ .width = clampWidth(proposed) }
        else if (proposed > expand_threshold_dip) .pin else null,
        .expanded => .{ .width = clampWidth(proposed) },
    };
}

/// Rows span to the panel's (or the open card's) edges for hit purposes -
/// the fill inset is paint, and a click in it still means that row. A rail
/// tile is just its square.
fn rowHitRect(l: *const Layout, r: Rect) Rect {
    if (l.mode == .expanded) return .{ .left = 0, .top = r.top, .right = l.width, .bottom = r.bottom };
    if (l.open) return .{ .left = l.card.left, .top = r.top, .right = l.card.right, .bottom = r.bottom };
    return r;
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

test "T1850: the elevated rail takes the panes' margin leading, top and bottom, and none trailing" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
    const ins = railInsets(true);
    // Mac: 10 + 44 + 0.
    try testing.expectEqual(@as(f32, 54), railColumnDipFor(true));
    try testing.expectEqual(@as(f32, 68), railColumnDipFor(false));
    try testing.expectEqual(@as(f32, 240), columnDipFor(.expanded, 240, true));
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
        // The whole edge band is inside the window, so all of it grabs.
        const g = px(grab_dip, s);
        try testing.expect(onEdge(&l, w - 1, l.card.centerY(), s));
        try testing.expect(onEdge(&l, w - g, l.card.centerY(), s));
        try testing.expect(!onEdge(&l, w - g - 1, l.card.centerY(), s));

        // The open card grows from the same spot and keeps none trailing.
        const ow = openWidthPxIn(240, s, ins);
        try testing.expectEqual(margin + px(240, s), ow);
        const o = layoutOpenIn(ow, h, &items, null, tm, s, ins);
        try testing.expectEqual(l.card.left, o.card.left);
        try testing.expectEqual(l.card.top, o.card.top);
        try testing.expectEqual(l.card.bottom, o.card.bottom);
        try testing.expectEqual(ow, o.card.right);

        // T1865: the open card's own insets leave its shadow room to fall on
        // the grid, and the card itself stays the panel's width.
        const oi = openInsets(ins);
        const sw = openWidthPxIn(240, s, oi);
        try testing.expectEqual(margin + px(240, s) + px(open_shadow_room_dip, s), sw);
        const so = layoutOpenIn(sw, h, &items, null, tm, s, oi);
        try testing.expectEqual(o.card, so.card);
    }
    // Flat is the pre-T1850 geometry exactly, and its 12 DIP margin already
    // holds the shadow, so `openInsets` leaves it alone.
    for (scales) |s| {
        try testing.expectEqual(px(68, s), columnPx(.mini, 240, s));
        try testing.expectEqual(2 * px(rail_margin_dip, s) + px(240, s), openWidthPx(240, s));
        try testing.expectEqual(openWidthPx(240, s), openWidthPxIn(240, s, openInsets(railInsets(false))));
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

// ---------------------------------------------------------------------------
// The all-windows outline (T1829)

fn outlineFixture(s: f32) struct { items: [5]Item, lines: [11]Line, tm: TextMetrics } {
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
            .{ .kind = .rule, .depth = 1 },
            .{ .kind = .stashed_caption, .index = 0, .depth = 1 },
            .{ .kind = .pane, .index = 2, .depth = 1 },
            .{ .kind = .rule },
            .{ .kind = .window, .index = 1 },
            .{ .kind = .pane, .index = 3, .depth = 1 },
            .{ .kind = .pane, .index = 4, .depth = 1 },
            // A trailing line past the items is ignored, not a crash.
            .{ .kind = .pane, .index = 9, .depth = 1 },
        },
        .tm = .{ .title_h = px(19, s), .caption_h = px(16, s) },
    };
}

test "pane_sidebar: the outline stacks heads, indented rows, rules and captions in order" {
    for (scales) |s| {
        const f = outlineFixture(s);
        const w = px(240, s);
        const l = layoutWith(.expanded, w, px(900, s), &f.items, &f.lines, f.tm, s);
        try testing.expect(l.outline);
        try testing.expectEqual(@as(usize, 2), l.head_count);
        try testing.expectEqual(@as(usize, 2), l.rule_count);
        try testing.expectEqual(@as(usize, 1), l.caption_count);
        // Everything below the header, top to bottom.
        try testing.expect(l.heads[0].rect.top >= l.header.bottom);
        try testing.expect(l.items[0].top >= l.heads[0].rect.bottom);
        try testing.expect(l.items[1].top > l.items[0].bottom);
        try testing.expect(l.captions[0].rect.top > l.items[1].bottom);
        try testing.expect(l.items[2].top >= l.captions[0].rect.bottom);
        try testing.expect(l.rules[1].top > l.items[2].bottom);
        try testing.expect(l.heads[1].rect.top > l.rules[1].bottom);
        try testing.expect(l.items[3].top >= l.heads[1].rect.bottom);
        // A two-line row is taller.
        try testing.expect(l.items[1].height() > l.items[0].height());
        // Fills span the panel; only the content is indented, one step.
        try testing.expectEqual(l.items[0].left, l.heads[0].rect.left);
        try testing.expectEqual(px(outline_step_dip, s), l.indent[0]);
        // The chevron sits on the label column; the name right after it.
        try testing.expectEqual(px(toc.label_inset_dip, s), l.heads[0].chevron.left);
        try testing.expect(l.heads[0].label_x > l.heads[0].chevron.right);
        // The pane icons line up under the window's name.
        try testing.expectEqual(l.heads[0].label_x, l.items[0].left + px(toc.text_inset_dip, s) + l.indent[0]);
        // Only this window's stash is a drop target.
        try testing.expectEqual(@as(usize, 2), l.first_stashed);
        try testing.expectEqual(@as(usize, 3), l.stash_end);
        // The all-windows toggle sits left of the pin, inside the header.
        try testing.expect(l.scope.right <= l.pin.left);
        try testing.expect(l.scope.top >= l.header.top and l.scope.bottom <= l.header.bottom);
    }
}

test "pane_sidebar: a folded group's panes get no row and no hit" {
    const s: f32 = 1.0;
    const f = outlineFixture(s);
    // Fold the other window: its pane lines go.
    const lines = f.lines[0..8];
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
    try testing.expectEqual(Hit{ .head = 1 }, hitTest(&l, 200, l.heads[1].rect.centerY(), s));
    try testing.expectEqual(Hit{ .item = 3 }, hitTest(&l, 60, l.items[3].centerY(), s));
    try testing.expectEqual(@as(Hit, .scope), hitTest(&l, l.scope.centerX(), l.scope.centerY(), s));
    try testing.expectEqual(@as(Hit, .pin), hitTest(&l, l.pin.centerX(), l.pin.centerY(), s));
}

test "pane_sidebar: the all-windows search field sits under the header, the outline under it (T1877)" {
    for (scales) |s| {
        const f = outlineFixture(s);
        const sm = px(sm_dip, s);
        var l = layoutWith(.expanded, px(240, s), px(900, s), &f.items, &f.lines, f.tm, s);
        // Under the header, inset like a row's fill, at least the standard
        // control height, the clear button inside it with sm to spare.
        try testing.expectEqual(l.header.bottom, l.search.top);
        try testing.expectEqual(px(toc.fill_inset_dip, s), l.search.left);
        try testing.expectEqual(px(240, s) - px(toc.fill_inset_dip, s), l.search.right);
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
        // The open card carries it too, inside the card.
        const o = layoutOpenWith(openWidthPx(240, s), px(900, s), &f.items, &f.lines, f.tm, s);
        try testing.expect(o.search.left >= o.card.left and o.search.right <= o.card.right);
        try testing.expectEqual(o.header.bottom, o.search.top);
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
        try testing.expectEqual(px(toc.label_inset_dip, s), r.left);
        try testing.expectEqual(@as(usize, 0), l.head_count);
        for (0..l.count) |i| try testing.expect(!l.shown(i));
    }
}

test "pane_sidebar: the open card lays the outline out inside the card" {
    const s: f32 = 1.5;
    const f = outlineFixture(s);
    const w = openWidthPx(240, s);
    const l = layoutOpenWith(w, px(900, s), &f.items, &f.lines, f.tm, s);
    try testing.expect(l.open and l.outline);
    try testing.expectEqual(@as(usize, 2), l.head_count);
    try testing.expect(l.heads[0].rect.left >= l.card.left and l.heads[0].rect.right <= l.card.right);
    try testing.expect(l.items[4].bottom <= l.card.bottom);
}

test "pane_sidebar: the outline's rail draws a hairline between windows and before a stash" {
    for (scales) |s| {
        const f = outlineFixture(s);
        const l = layoutWith(.mini, px(68, s), px(900, s), &f.items, &f.lines, f.tm, s);
        // Every pane is a tile, folded or not.
        for (0..5) |i| try testing.expect(l.shown(i));
        // Two breaks: grid -> stash in this window, then window -> window.
        try testing.expectEqual(@as(usize, 2), l.rule_count);
        try testing.expect(l.section_rule == null);
        try testing.expect(l.rules[0].top > l.items[1].bottom and l.rules[0].bottom <= l.items[2].top);
        try testing.expect(l.rules[1].top > l.items[2].bottom and l.rules[1].bottom <= l.items[3].top);
        // No header buttons on the rail beyond the pin.
        try testing.expectEqual(@as(i32, 0), l.scope.width());
        try testing.expectEqual(@as(usize, 0), l.head_count);
    }
}

test "pane_sidebar: the outline never adds the empty drop slot" {
    const s: f32 = 1.0;
    var f = outlineFixture(s);
    f.items[2].section = .grid; // nothing stashed here
    var l = layoutWith(.expanded, 240, 900, &f.items, f.lines[0..3], f.tm, s);
    addDropSlot(&l, f.tm, s);
    try testing.expect(l.drop_slot == null);
}

test "pane_sidebar: the header reads all-windows, trash, pin - Mac's order - and each is its own hit (T1845)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
        const l = layout(.expanded, px(240, s), px(600, s), &items, tm, s);
        try testing.expect(l.scope.right <= l.trash.left);
        try testing.expect(l.trash.right <= l.pin.left);
        try testing.expect(l.trash.width() > 0);
        try testing.expect(l.trash.top >= l.header.top and l.trash.bottom <= l.header.bottom);
        try testing.expectEqual(@as(Hit, .trash), hitTest(&l, l.trash.centerX(), l.trash.centerY(), s));
        try testing.expectEqual(@as(Hit, .scope), hitTest(&l, l.scope.centerX(), l.scope.centerY(), s));
        try testing.expectEqual(@as(Hit, .pin), hitTest(&l, l.pin.centerX(), l.pin.centerY(), s));
    }
}

test "pane_sidebar: on the rail, a tile's corner x is a target only in trash mode (T1845)" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .stashed } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = 19, .caption_h = 16 };
        var l = layout(.mini, columnPx(.mini, 240, s), px(600, s), &items, tm, s);
        // The rail has no header buttons, so no trash toggle either.
        try testing.expectEqual(@as(i32, 0), l.trash.width());
        const k = l.tileKill(1, s);
        const kx = k.centerX();
        const ky = k.centerY();
        // Inside the tile's own square, so a plain click there is the tile.
        try testing.expect(l.items[1].contains(kx, ky));
        try testing.expectEqual(Hit{ .item = 1 }, hitTest(&l, kx, ky, s));
        l.quick_kill = true;
        try testing.expectEqual(Hit{ .item_button = 1 }, hitTest(&l, kx, ky, s));
        // The rest of the tile is still the tile.
        try testing.expectEqual(Hit{ .item = 1 }, hitTest(&l, l.items[1].right - 2, l.items[1].bottom - 2, s));
    }
}

test "pane_sidebar: the edge band sits inside the pinned panel's edge and straddles a card's" {
    const items = [_]Item{ .{ .section = .grid }, .{ .section = .grid } };
    for (scales) |s| {
        const tm: TextMetrics = .{ .title_h = px(19, s), .caption_h = px(16, s) };
        const g = px(grab_dip, s);
        const w = px(240, s);
        const h = px(600, s);
        const e = layout(.expanded, w, h, &items, tm, s);
        try testing.expect(onEdge(&e, w - 1, px(300, s), s));
        try testing.expect(onEdge(&e, w - g, px(300, s), s));
        try testing.expect(!onEdge(&e, w - g - 1, px(300, s), s));
        // The panel's last pixel is the edge, not its row...
        try testing.expect(onEdge(&e, w - 1, e.items[0].centerY(), s));
        // ...but the pin and a row's button keep their own pixels.
        try testing.expect(!onEdge(&e, e.pin.right - 1, e.pin.centerY(), s));
        try testing.expect(onEdge(&e, w - 1, e.pin.centerY(), s));
        const b = e.rowButton(0, s);
        try testing.expect(!onEdge(&e, b.right - 1, b.centerY(), s));

        const r = layout(.mini, px(railColumnDip(), s), h, &items, tm, s);
        const y = r.card.centerY();
        try testing.expect(onEdge(&r, r.card.right, y, s));
        try testing.expect(onEdge(&r, r.card.right - 1, y, s));
        try testing.expect(onEdge(&r, r.card.right + 1, y, s));
        try testing.expect(!onEdge(&r, r.card.centerX(), y, s));
        // Only along the card: the margin above it is the grid's.
        try testing.expect(!onEdge(&r, r.card.right, r.card.top - 1, s));

        const o = layoutOpen(openWidthPx(240, s), h, &items, tm, s);
        try testing.expect(onEdge(&o, o.card.right - 1, o.card.centerY(), s));
        try testing.expect(!onEdge(&o, o.card.left + 1, o.card.centerY(), s));

        const hidden: Layout = .{ .mode = .hidden, .width = w, .height = h };
        try testing.expect(!onEdge(&hidden, w - 1, 10, s));
    }
}

test "pane_sidebar: dragging the rail out past 120 pins; a panel only resizes, clamped, and never unpins" {
    // The rail measures from its card (Mac `railCardWidth`).
    try testing.expectEqual(rail_card_dip, edgeStartDip(.mini, false, 300));
    try testing.expectEqual(@as(f32, 300), edgeStartDip(.mini, true, 300));
    try testing.expectEqual(@as(f32, 300), edgeStartDip(.expanded, false, 300));
    try testing.expectEqual(max_width_dip, edgeStartDip(.expanded, false, 900));

    // Rail: nothing until it passes the threshold, then pin.
    try testing.expectEqual(@as(?EdgeDrag, null), edgeDrag(.mini, false, rail_card_dip, 40));
    try testing.expectEqual(@as(?EdgeDrag, null), edgeDrag(.mini, false, rail_card_dip, expand_threshold_dip - rail_card_dip));
    try testing.expectEqual(@as(?EdgeDrag, .pin), edgeDrag(.mini, false, rail_card_dip, expand_threshold_dip - rail_card_dip + 1));
    // Pushing the rail in does nothing either.
    try testing.expectEqual(@as(?EdgeDrag, null), edgeDrag(.mini, false, rail_card_dip, -30));

    // Pinned panel: follows the pointer between the bounds and stops there.
    try testing.expectEqual(@as(?EdgeDrag, .{ .width = 300 }), edgeDrag(.expanded, false, 240, 60));
    try testing.expectEqual(@as(?EdgeDrag, .{ .width = max_width_dip }), edgeDrag(.expanded, false, 240, 500));
    // Far below the old 140 collapse threshold: still pinned, at the minimum.
    try testing.expectEqual(@as(?EdgeDrag, .{ .width = min_width_dip }), edgeDrag(.expanded, false, 240, -200));
    // A rail pinned mid-drag keeps measuring from the rail's card, so the
    // panel's edge then follows the pointer from the minimum up.
    try testing.expectEqual(@as(?EdgeDrag, .{ .width = min_width_dip }), edgeDrag(.expanded, false, rail_card_dip, 100));
    try testing.expectEqual(@as(?EdgeDrag, .{ .width = 260 }), edgeDrag(.expanded, false, rail_card_dip, 216));

    // The card opened over the grid resizes the same preference.
    try testing.expectEqual(@as(?EdgeDrag, .{ .width = 280 }), edgeDrag(.mini, true, 240, 40));
    try testing.expectEqual(@as(?EdgeDrag, null), edgeDrag(.hidden, false, 240, 40));
}

test "T1889: the question chip is the status chip - caption line plus sm tall, sm padding, ending at its right edge" {
    for (scales) |s| {
        const text_w = px(46, s);
        const c = questionChip(200, 50, text_w, s);
        try testing.expectEqual(px(12, s) + px(4, s), c.height());
        try testing.expectEqual(questionChipHeight(s), c.height());
        try testing.expectEqual(@as(i32, 200), c.right);
        try testing.expectEqual(text_w + 2 * px(4, s), c.width());
        // Centred on the line it sits beside (within the odd pixel).
        try testing.expect(@abs(c.centerY() - 50) <= 1);
        // A word, so a capsule wider than tall - not the rail's disc.
        try testing.expect(c.width() > c.height());
    }
}

test "T1889: a chip never gets narrower than it is tall" {
    for (scales) |s| {
        const c = questionChip(100, 20, 0, s);
        try testing.expectEqual(c.height(), c.width());
        const neg = questionChip(100, 20, -10, s);
        try testing.expectEqual(neg.height(), neg.width());
    }
}

test "T1889: the breathing ring follows the capsule, grown evenly on every side" {
    const c = questionChip(200, 50, 46, 1.0);
    const r = questionRing(c, 2);
    try testing.expectEqual(c.width() + 4, r.width());
    try testing.expectEqual(c.height() + 4, r.height());
    try testing.expectEqual(c.centerX(), r.centerX());
    try testing.expectEqual(c.centerY(), r.centerY());
    // Still wider than tall: a capsule's ring, not a disc's.
    try testing.expect(r.width() > r.height());
}
