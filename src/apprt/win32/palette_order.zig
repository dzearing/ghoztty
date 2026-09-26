//! Command-palette ordering and the recent-command history (T891) — the
//! OS-free half, so the none lane can assert it (the `palette_jump.zig`
//! pattern). The runtime glue — reading the store, painting the section
//! headers, recording an execution — lives in `Surface.zig` and `App.zig`.
//!
//! Two behaviours the Mac palette has had and the win32 one did not:
//!
//! - **Alphabetical order.** Mac's `commandSections` sorts every option with
//!   a case-insensitive compare over titles whose `:` has been replaced by a
//!   TAB, so a prefixed family ("Viewer: …") groups ahead of a plain title
//!   that shares the prefix. The win32 palette showed registry order, which
//!   is the order the commands were *written in* — fine for the first
//!   twenty, unreadable at eighty.
//! - **A "Recent" section.** Mac's `PaletteHistory` stamps each command's
//!   use and the ten most recent surface at the top, in recency order, with
//!   the rest under "All Commands". Recency is what makes a palette feel
//!   learned rather than merely searchable.
//!
//! The history is a bounded, allocation-free value: a fixed number of
//! fixed-length keys, held newest-first so `recent` is a prefix and eviction
//! is the tail. It is a UI convenience, so every failure — a truncated file,
//! a key that is too long, a store that will not parse — degrades to "no
//! recents" rather than to an error anybody sees.

const std = @import("std");

/// How many recent commands surface at the top (Mac: `limit: 10`).
pub const max_recent: usize = 10;

/// Longest key stored. A key is a registry id (`new_tab`) or a
/// `user:<title>` — a longer one is simply not remembered, which costs that
/// one command its recency and nothing else.
pub const max_key_len: usize = 96;

/// How many commands the history remembers at all. Past this the oldest is
/// evicted: three times `max_recent` is enough that a command used a while
/// ago is still there when it comes back around, and small enough that the
/// whole thing is a cheap value type.
pub const capacity: usize = 32;

/// The prefix for a user's own `command-palette-entry` command, so a config
/// title can never collide with a registry id.
pub const user_key_prefix = "user:";

/// The section headers, in the words Mac uses.
pub const recent_header = "Recent";
pub const all_header = "All Commands";

// ---------------------------------------------------------------------------
// Title order
// ---------------------------------------------------------------------------

/// One byte of a title, normalized for comparison: `:` becomes a TAB (so
/// `Viewer: Open File` sorts before `Viewers`, which is Mac's
/// `replacingOccurrences(of: ":", with: "\t")`), everything else is
/// case-folded. ASCII-only folding is deliberate — command titles are
/// ASCII apart from the odd `…`, and a locale-aware fold would make the
/// order depend on the machine's language.
fn norm(c: u8) u8 {
    return if (c == ':') '\t' else std.ascii.toLower(c);
}

/// Mac's `localizedCaseInsensitiveCompare` over the normalized titles.
pub fn titleOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |ca, cb| {
        const na = norm(ca);
        const nb = norm(cb);
        if (na != nb) return if (na < nb) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

/// `std.mem.sort` predicate over titles.
pub fn titleLessThan(_: void, a: []const u8, b: []const u8) bool {
    return titleOrder(a, b) == .lt;
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

/// One stamp as it lives on disk. Mac keeps a `[String: TimeInterval]`
/// dictionary in `~/.config/ghostty/palette-history.json`; this is the same
/// information as an explicit array, which parses into a typed struct
/// without an allocator-owned map and orders itself.
pub const Stamp = struct {
    id: []const u8,
    /// Unix seconds. Seconds rather than Mac's fractional interval because
    /// the only thing ever asked of it is "which was later".
    used: i64,
};

/// The store's whole contents.
pub const File = struct {
    commands: []const Stamp = &.{},
};

const Entry = struct {
    buf: [max_key_len]u8 = undefined,
    len: u8 = 0,
    used: i64 = 0,

    fn key(self: *const Entry) []const u8 {
        return self.buf[0..self.len];
    }
};

/// The recent-command history: keys newest-first.
pub const History = struct {
    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    len: usize = 0,

    /// Whether anything has changed since the last `clearDirty` — what tells
    /// the caller a write to disk is owed.
    dirty: bool = false,

    /// Record `key` as used at `now` (unix seconds), moving it to the front.
    /// An over-long or empty key is ignored rather than truncated: a
    /// truncated key would collide with another command's.
    pub fn record(self: *History, key: []const u8, now: i64) void {
        if (key.len == 0 or key.len > max_key_len) return;

        // Where the entry is today, or the slot it will occupy.
        var at: usize = self.len;
        for (self.entries[0..self.len], 0..) |*e, i| {
            if (std.mem.eql(u8, e.key(), key)) {
                at = i;
                break;
            }
        }
        if (at == self.len) {
            if (self.len < capacity) {
                self.len += 1;
            } else {
                // Full: the oldest entry is the one that goes.
                at = capacity - 1;
            }
        }

        var i = at;
        while (i > 0) : (i -= 1) self.entries[i] = self.entries[i - 1];

        var e: Entry = .{ .len = @intCast(key.len), .used = now };
        @memcpy(e.buf[0..key.len], key);
        self.entries[0] = e;
        self.dirty = true;
    }

    /// How many entries surface as "Recent".
    pub fn recentCount(self: *const History) usize {
        return @min(self.len, max_recent);
    }

    /// The `i`th most recently used key (`i < recentCount()`).
    pub fn recentKey(self: *const History, i: usize) []const u8 {
        return self.entries[i].key();
    }

    pub fn clearDirty(self: *History) void {
        self.dirty = false;
    }

    /// Load a parsed store. Entries are taken newest-first, so a file whose
    /// order was lost (hand-edited, or written by an older build) still
    /// yields the right recency.
    pub fn fromFile(file: File) History {
        var stamps: [capacity]Stamp = undefined;
        var n: usize = 0;
        for (file.commands) |s| {
            if (s.id.len == 0 or s.id.len > max_key_len) continue;
            // A duplicate id in the file keeps the later stamp.
            const dup: ?usize = for (stamps[0..n], 0..) |p, i| {
                if (std.mem.eql(u8, p.id, s.id)) break i;
            } else null;
            if (dup) |i| {
                if (s.used > stamps[i].used) stamps[i] = s;
                continue;
            }
            if (n == capacity) continue;
            stamps[n] = s;
            n += 1;
        }
        std.mem.sort(Stamp, stamps[0..n], {}, struct {
            fn lt(_: void, a: Stamp, b: Stamp) bool {
                return a.used > b.used;
            }
        }.lt);

        var h: History = .{};
        for (stamps[0..n]) |s| {
            var e: Entry = .{ .len = @intCast(s.id.len), .used = s.used };
            @memcpy(e.buf[0..s.id.len], s.id);
            h.entries[h.len] = e;
            h.len += 1;
        }
        return h;
    }

    /// The store to write, newest-first, into caller-owned storage.
    pub fn toStamps(self: *const History, out: *[capacity]Stamp) []const Stamp {
        for (self.entries[0..self.len], 0..) |*e, i| {
            out[i] = .{ .id = e.key(), .used = e.used };
        }
        return out[0..self.len];
    }
};

// ---------------------------------------------------------------------------
// Arrangement
// ---------------------------------------------------------------------------

/// One candidate row, as the palette knows it.
pub const Item = struct {
    /// What the row displays, which is also what it sorts by.
    title: []const u8,
    /// The history key, or null for a row with no stable identity — a
    /// "Focus: <pane>" jump entry, whose pane is gone by tomorrow. Mac's
    /// jump options carry no `commandIdentifier` for the same reason.
    key: ?[]const u8 = null,
    /// `key` is a user command's bare TITLE, and its history key is
    /// `user_key_prefix ++ key` (T1752). Matching the composed key in place
    /// means the palette never has to build one per row: it used to, into a
    /// fixed stack buffer per user entry, and that buffer is what capped the
    /// palette at 64 config commands.
    user: bool = false,

    /// Whether this row's history key is `want`.
    pub fn keyIs(self: Item, want: []const u8) bool {
        const key = self.key orelse return false;
        if (!self.user) return std.mem.eql(u8, key, want);
        return std.mem.startsWith(u8, want, user_key_prefix) and
            std.mem.eql(u8, want[user_key_prefix.len..], key);
    }
};

/// Order `items` the way the palette shows them, writing indices into `out`
/// (`out.len >= items.len`) and returning how many of them are RECENT — the
/// front of `out`, in recency order. The remainder is sorted by title.
///
/// Mac assembles the same two groups (`commandSections`) and, when a query
/// is present, flattens them in exactly this order.
pub fn arrange(items: []const Item, history: *const History, out: []u16) usize {
    std.debug.assert(out.len >= items.len);
    for (items, 0..) |_, i| out[i] = @intCast(i);
    const n = items.len;

    std.mem.sort(u16, out[0..n], items, struct {
        fn lt(ctx: []const Item, a: u16, b: u16) bool {
            return titleOrder(ctx[a].title, ctx[b].title) == .lt;
        }
    }.lt);

    // Pull the recents to the front, in recency order, leaving the rest in
    // title order behind them.
    var placed: usize = 0;
    for (0..history.recentCount()) |r| {
        const want = history.recentKey(r);
        const found: ?usize = for (out[placed..n], placed..) |idx, j| {
            if (items[idx].keyIs(want)) break j;
        } else null;
        const j = found orelse continue;
        const moved = out[j];
        var k = j;
        while (k > placed) : (k -= 1) out[k] = out[k - 1];
        out[placed] = moved;
        placed += 1;
    }
    return placed;
}

/// How many rows the list is scrolled by (T1671): the list stays at the top
/// until the selection would fall off the bottom, then scrolls just enough to
/// keep it on the last visible row. The ONE derivation of the scroll —
/// `paintPaletteInto` draws with it and the popup's click hit-test maps a Y
/// back through it, so a click can never pick a different row than the one
/// painted under the pointer.
pub fn scrollOffset(selected: u16, max_visible: i32) i32 {
    if (max_visible <= 0) return 0;
    const sel: i32 = selected;
    return if (sel >= max_visible) sel - max_visible + 1 else 0;
}

/// The row the palette selects when its list is rebuilt (T1754). `pinned` is
/// how many rows the pinned section (the update rows) put at the very top,
/// `headers` whether a "Recent" header follows them, `count` the total rows.
///
/// Typing selects the first match wherever it is — Mac's
/// `onChange(of: query)` sets `selectedIndex = 0`, pinned rows included, so
/// "upd" + Enter updates. An EMPTY query starts on the first ordinary command
/// instead: Mac selects nothing at all there, and Windows has always opened
/// on the top command, so the habit "open the palette, Enter repeats the last
/// thing" survives an offer appearing above it rather than turning into an
/// update dialog. The pinned rows are one Up away. With nothing but pinned
/// rows the first of them is selected.
pub fn firstSelection(pinned: u16, headers: bool, filtering: bool, count: u16) u16 {
    if (filtering) return 0;
    const first = pinned + @intFromBool(headers);
    return if (first < count) first else 0;
}

/// Rows the list area can show at `client_height`, never negative.
pub fn maxVisible(client_height: i32, list_top: i32, item_height: i32) i32 {
    if (item_height <= 0) return 0;
    return @max(0, @divTrunc(client_height - list_top, item_height));
}

/// The ABSOLUTE row (an index into the filtered list) painted under client
/// `y`, or null when `y` is above the list, below the last visible row, or
/// past the end of the list.
pub fn rowAtY(
    y: i32,
    list_top: i32,
    item_height: i32,
    max_visible: i32,
    selected: u16,
    count: u16,
) ?u16 {
    if (item_height <= 0 or y < list_top) return null;
    const visual = @divTrunc(y - list_top, item_height);
    if (visual >= max_visible) return null;
    const row = visual + scrollOffset(selected, max_visible);
    if (row >= count) return null;
    return @intCast(row);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "scrollOffset: unscrolled until the selection passes the last visible row" {
    try testing.expectEqual(@as(i32, 0), scrollOffset(0, 5));
    try testing.expectEqual(@as(i32, 0), scrollOffset(4, 5));
    try testing.expectEqual(@as(i32, 1), scrollOffset(5, 5));
    try testing.expectEqual(@as(i32, 15), scrollOffset(19, 5));
    try testing.expectEqual(@as(i32, 0), scrollOffset(19, 0));
}

test "rowAtY: an unscrolled list maps the visual row straight through" {
    // list_top 50, rows 20 tall, 5 visible, 30 rows, selection on row 1.
    try testing.expectEqual(@as(?u16, 0), rowAtY(50, 50, 20, 5, 1, 30));
    try testing.expectEqual(@as(?u16, 2), rowAtY(95, 50, 20, 5, 1, 30));
    try testing.expectEqual(@as(?u16, null), rowAtY(49, 50, 20, 5, 1, 30));
}

test "rowAtY: a scrolled list adds the scroll offset (T1671)" {
    // Selection on row 12 of 30 with 5 visible: rows 8..12 are painted, so
    // the top visible slot is row 8 and the bottom one is the selection.
    try testing.expectEqual(@as(?u16, 8), rowAtY(50, 50, 20, 5, 12, 30));
    try testing.expectEqual(@as(?u16, 12), rowAtY(50 + 4 * 20, 50, 20, 5, 12, 30));
    // Below the last visible row is nothing, even though row 13 exists.
    try testing.expectEqual(@as(?u16, null), rowAtY(50 + 5 * 20, 50, 20, 5, 12, 30));
}

test "rowAtY: a slot past the end of a short list is nothing" {
    try testing.expectEqual(@as(?u16, null), rowAtY(50 + 3 * 20, 50, 20, 5, 0, 3));
    try testing.expectEqual(@as(?u16, null), rowAtY(60, 50, 0, 5, 0, 3));
}

test "firstSelection: an empty query starts below the pinned rows (T1754)" {
    // No offer, no recents: the top row, as before T1754.
    try testing.expectEqual(@as(u16, 0), firstSelection(0, false, false, 40));
    // No offer, recents: skip the "Recent" header.
    try testing.expectEqual(@as(u16, 1), firstSelection(0, true, false, 40));
    // Offer (two pinned rows), no recents: the first ordinary command.
    try testing.expectEqual(@as(u16, 2), firstSelection(2, false, false, 40));
    // Offer and recents: past both pinned rows and the header.
    try testing.expectEqual(@as(u16, 3), firstSelection(2, true, false, 40));
}

test "firstSelection: typing selects the first match, pinned or not (T1754)" {
    try testing.expectEqual(@as(u16, 0), firstSelection(2, false, true, 5));
    try testing.expectEqual(@as(u16, 0), firstSelection(0, false, true, 5));
}

test "firstSelection: a list of nothing but pinned rows selects the first" {
    try testing.expectEqual(@as(u16, 0), firstSelection(2, false, false, 2));
    try testing.expectEqual(@as(u16, 0), firstSelection(0, false, false, 0));
}

test "maxVisible: never negative" {
    try testing.expectEqual(@as(i32, 5), maxVisible(150, 50, 20));
    try testing.expectEqual(@as(i32, 0), maxVisible(30, 50, 20));
    try testing.expectEqual(@as(i32, 0), maxVisible(150, 50, 0));
}

test "titleOrder: case-insensitive" {
    try testing.expectEqual(std.math.Order.lt, titleOrder("about ghoztty", "New Tab"));
    try testing.expectEqual(std.math.Order.gt, titleOrder("Quit", "new tab"));
    try testing.expectEqual(std.math.Order.eq, titleOrder("New Tab", "new tab"));
}

test "titleOrder: a colon groups the family ahead of a longer plain title" {
    // Mac normalizes ':' to TAB, which sorts below every printable byte, so
    // "Viewer: …" comes before "Viewers" rather than after it.
    try testing.expectEqual(std.math.Order.lt, titleOrder("Viewer: Open File", "Viewers"));
    try testing.expectEqual(std.math.Order.lt, titleOrder("Viewer: Open URL", "Viewer Settings"));
}

test "titleOrder: a prefix sorts before the longer title" {
    try testing.expectEqual(std.math.Order.lt, titleOrder("New Tab", "New Tab Here"));
}

test "record: most recent first, and a repeat moves to the front" {
    var h: History = .{};
    h.record("new_tab", 100);
    h.record("quit", 200);
    h.record("new_tab", 300);
    try testing.expectEqual(@as(usize, 2), h.recentCount());
    try testing.expectEqualStrings("new_tab", h.recentKey(0));
    try testing.expectEqualStrings("quit", h.recentKey(1));
}

test "record: recents are capped at ten, history at capacity" {
    var h: History = .{};
    var buf: [8]u8 = undefined;
    for (0..capacity + 5) |i| {
        const key = std.fmt.bufPrint(&buf, "cmd{d}", .{i}) catch unreachable;
        h.record(key, @intCast(i));
    }
    try testing.expectEqual(capacity, h.len);
    try testing.expectEqual(max_recent, h.recentCount());
    // The newest is at the front; the oldest fell off the tail.
    try testing.expectEqualStrings("cmd36", h.recentKey(0));
    for (h.entries[0..h.len]) |e| {
        try testing.expect(!std.mem.eql(u8, e.key(), "cmd0"));
    }
}

test "record: an over-long or empty key is not remembered" {
    var h: History = .{};
    h.record("", 1);
    h.record("x" ** (max_key_len + 1), 2);
    try testing.expectEqual(@as(usize, 0), h.recentCount());
    try testing.expect(!h.dirty);
}

test "fromFile: orders by timestamp regardless of file order" {
    const h = History.fromFile(.{ .commands = &.{
        .{ .id = "old", .used = 10 },
        .{ .id = "newest", .used = 30 },
        .{ .id = "middle", .used = 20 },
    } });
    try testing.expectEqualStrings("newest", h.recentKey(0));
    try testing.expectEqualStrings("middle", h.recentKey(1));
    try testing.expectEqualStrings("old", h.recentKey(2));
    try testing.expect(!h.dirty);
}

test "fromFile: junk degrades to fewer recents, never to an error" {
    const h = History.fromFile(.{ .commands = &.{
        .{ .id = "", .used = 10 },
        .{ .id = "x" ** (max_key_len + 1), .used = 20 },
        .{ .id = "new_tab", .used = 30 },
        // A duplicate keeps the later stamp and appears once.
        .{ .id = "new_tab", .used = 5 },
    } });
    try testing.expectEqual(@as(usize, 1), h.recentCount());
    try testing.expectEqualStrings("new_tab", h.recentKey(0));
}

test "toStamps round-trips through fromFile" {
    var h: History = .{};
    h.record("a", 1);
    h.record("b", 2);
    var buf: [capacity]Stamp = undefined;
    const stamps = h.toStamps(&buf);
    try testing.expectEqual(@as(usize, 2), stamps.len);
    const back = History.fromFile(.{ .commands = stamps });
    try testing.expectEqualStrings("b", back.recentKey(0));
    try testing.expectEqualStrings("a", back.recentKey(1));
}

test "arrange: no history is pure title order" {
    const items = [_]Item{
        .{ .title = "New Window", .key = "new_window" },
        .{ .title = "About Ghoztty", .key = "about" },
        .{ .title = "Quit", .key = "quit" },
    };
    var out: [3]u16 = undefined;
    const h: History = .{};
    try testing.expectEqual(@as(usize, 0), arrange(&items, &h, &out));
    try testing.expectEqualStrings("About Ghoztty", items[out[0]].title);
    try testing.expectEqualStrings("New Window", items[out[1]].title);
    try testing.expectEqualStrings("Quit", items[out[2]].title);
}

test "arrange: recents lead in recency order, the rest stays alphabetical" {
    const items = [_]Item{
        .{ .title = "About Ghoztty", .key = "about" },
        .{ .title = "New Tab", .key = "new_tab" },
        .{ .title = "New Window", .key = "new_window" },
        .{ .title = "Quit", .key = "quit" },
    };
    var h: History = .{};
    h.record("new_window", 1);
    h.record("quit", 2);

    var out: [4]u16 = undefined;
    try testing.expectEqual(@as(usize, 2), arrange(&items, &h, &out));
    try testing.expectEqualStrings("Quit", items[out[0]].title);
    try testing.expectEqualStrings("New Window", items[out[1]].title);
    try testing.expectEqualStrings("About Ghoztty", items[out[2]].title);
    try testing.expectEqualStrings("New Tab", items[out[3]].title);
}

test "arrange: a remembered command that is not on screen is skipped" {
    // The history outlives a config change that removed a user command, and
    // it holds keys for commands this filter did not match.
    const items = [_]Item{
        .{ .title = "New Tab", .key = "new_tab" },
        .{ .title = "Quit", .key = "quit" },
    };
    var h: History = .{};
    h.record("gone", 1);
    h.record("quit", 2);

    var out: [2]u16 = undefined;
    try testing.expectEqual(@as(usize, 1), arrange(&items, &h, &out));
    try testing.expectEqualStrings("Quit", items[out[0]].title);
    try testing.expectEqualStrings("New Tab", items[out[1]].title);
}

test "arrange: a keyless row never enters Recent" {
    // "Focus: <pane>" jump entries are transient, so they sort by title and
    // nothing more — even when a stale key happens to match a title.
    const items = [_]Item{
        .{ .title = "Focus: pwsh", .key = null },
        .{ .title = "About Ghoztty", .key = "about" },
    };
    var h: History = .{};
    h.record("Focus: pwsh", 1);
    var out: [2]u16 = undefined;
    try testing.expectEqual(@as(usize, 0), arrange(&items, &h, &out));
    try testing.expectEqualStrings("About Ghoztty", items[out[0]].title);
    try testing.expectEqualStrings("Focus: pwsh", items[out[1]].title);
}

test "arrange: a user row matches its prefixed key without composing it (T1752)" {
    const items = [_]Item{
        .{ .title = "About Ghoztty", .key = "about" },
        .{ .title = "Deploy", .key = "Deploy", .user = true },
        // A built-in whose id happens to equal the user title must NOT take
        // the user command's recency, and vice versa.
        .{ .title = "deploy builtin", .key = "Deploy" },
    };
    var h: History = .{};
    h.record("user:Deploy", 1);
    var out: [3]u16 = undefined;
    try testing.expectEqual(@as(usize, 1), arrange(&items, &h, &out));
    try testing.expectEqualStrings("Deploy", items[out[0]].title);
    try testing.expect(items[out[0]].user);

    // The bare title is not the user key.
    var h2: History = .{};
    h2.record("Deploy", 1);
    try testing.expectEqual(@as(usize, 1), arrange(&items, &h2, &out));
    try testing.expect(!items[out[0]].user);
}

test "arrange: an empty palette is a no-op" {
    const items = [_]Item{};
    var out: [1]u16 = undefined;
    const h: History = .{};
    try testing.expectEqual(@as(usize, 0), arrange(&items, &h, &out));
}
