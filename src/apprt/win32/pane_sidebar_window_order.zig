//! The all-windows list's own order (T2337; Mac b07b7fa0b / c4dbe30be /
//! 9a1f14230 / 97afdaf5a: `PaneSidebarWindowGrouping.sections(_:order:)`,
//! `PaneSidebarItemReorder`, `PaneSidebarSharedState.windowOrder`).
//!
//! In the expanded all-windows list a window row drags up and down among its
//! siblings - its project's windows, or the top level for a window on its own
//! - and a project header among the top level. That reorders the LIST only:
//! no window and no pane moves on screen.
//!
//! The order is one list of keys every window shares, `project:<name>` and
//! `window:<id>` (a tab's stable identity, restored with it, so a relaunch
//! keeps its place). It is read over the name order
//! (`pane_sidebar_outline.outlineOrder`) every time rather than kept in step
//! with it, by `pane_sidebar_order`'s rules:
//!
//! - The top level (groups and lone windows) and each group's windows each
//!   follow the order.
//! - Whatever it has never seen - a new window, a new group - goes after its
//!   name-order neighbour it has seen, else before the next, else at the end,
//!   so a new `ghoztty: wt-3` lands right after `wt-2` wherever that was
//!   dragged.
//! - A closed window simply is not listed; its key leaves the stored order on
//!   the next move (`pane_sidebar_order.moving` prunes keys outside
//!   `allKeys`), never on close - at quit every window closes.
//!
//! Then the drag's geometry (Mac `PaneSidebarItemReorder`): items are not one
//! height, so the index is read by the dragged item's leading edge against
//! its siblings' middles.
//!
//! And the file the order persists in (Mac UserDefaults
//! `PaneSidebarWindowOrder`): one key per line under `%LOCALAPPDATA%\ghoztty`.
//!
//! Pure apart from that file's two calls, so its tests run in every lane.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const outline = @import("pane_sidebar_outline.zig");
const sidebar_order = @import("pane_sidebar_order.zig");

const keys_by = sidebar_order.by_bytes;

pub const max_keys: usize = sidebar_order.max_ids;

// ---------------------------------------------------------------------------
// Keys

/// Room for `project:` and a project name (at most
/// `outline.max_project_chars` code points, each at most 4 bytes), or
/// `window:` and a tab id.
pub const key_cap: usize = 8 + 4 * outline.max_project_chars;

pub const Key = struct {
    buf: [key_cap]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Key) []const u8 {
        return self.buf[0..self.len];
    }

    fn of(prefix: []const u8, name: []const u8) Key {
        var k: Key = .{};
        const n = @min(name.len, key_cap - prefix.len);
        @memcpy(k.buf[0..prefix.len], prefix);
        @memcpy(k.buf[prefix.len..][0..n], name[0..n]);
        k.len = prefix.len + n;
        return k;
    }
};

pub const project_prefix = "project:";
pub const window_prefix = "window:";

/// A project group's key (Mac `key(project:)`).
pub fn projectKey(name: []const u8) Key {
    return Key.of(project_prefix, name);
}

/// A window's key (Mac `key(window:)`): its tab's stable id.
pub fn windowKey(id: []const u8) Key {
    return Key.of(window_prefix, id);
}

pub fn isProject(key: []const u8) bool {
    return std.mem.startsWith(u8, key, project_prefix);
}

// ---------------------------------------------------------------------------
// The outline in the user's order

/// One top-level item of the outline: a project group or a lone window,
/// `start..start + len` of the name-ordered windows.
const Section = struct { start: usize, len: usize };

fn sections(placed: []const outline.Placed, out: []Section) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < placed.len and n < out.len) {
        const len = if (placed[i].project != null) outline.projectSize(placed, i) else 1;
        out[n] = .{ .start = i, .len = len };
        n += 1;
        i += len;
    }
    return n;
}

/// The key of `s`, into `buf` for a project.
fn sectionKey(placed: []const outline.Placed, window_keys: []const []const u8, s: Section, buf: *Key) []const u8 {
    const p = placed[s.start];
    if (p.project) |name| {
        buf.* = projectKey(name);
        return buf.slice();
    }
    return window_keys[p.index];
}

/// `placed` - the name order, `pane_sidebar_outline.outlineOrder` - in the
/// user's `order` (Mac `sections(_:order:)`): the top level and each group's
/// windows each arranged by it. `window_keys` is each window's key, indexed
/// like the titles `placed` was computed from (`Placed.index`). A project's
/// windows stay contiguous. `out` must hold `placed.len`; returns how many.
pub fn arrange(
    placed: []const outline.Placed,
    window_keys: []const []const u8,
    order: []const []const u8,
    out: []outline.Placed,
) usize {
    const n = @min(placed.len, out.len, max_keys);
    if (order.len == 0) {
        @memcpy(out[0..n], placed[0..n]);
        return n;
    }
    var secs: [max_keys]Section = undefined;
    const ns = sections(placed[0..n], &secs);
    var key_bufs: [max_keys]Key = undefined;
    var sec_keys: [max_keys][]const u8 = undefined;
    for (secs[0..ns], 0..) |s, i| sec_keys[i] = sectionKey(placed, window_keys, s, &key_bufs[i]);
    var sec_order: [max_keys]usize = undefined;
    const na = keys_by.arrange(sec_keys[0..ns], order, &sec_order);

    var w: usize = 0;
    for (sec_order[0..na]) |si| {
        const s = secs[si];
        if (s.len == 1) {
            out[w] = placed[s.start];
            w += 1;
            continue;
        }
        var members: [max_keys][]const u8 = undefined;
        for (0..s.len) |k| members[k] = window_keys[placed[s.start + k].index];
        var member_order: [max_keys]usize = undefined;
        const nm = keys_by.arrange(members[0..s.len], order, &member_order);
        for (member_order[0..nm]) |k| {
            out[w] = placed[s.start + k];
            w += 1;
        }
    }
    return w;
}

/// Every key the list has now - each group and each window (Mac `keys`):
/// `moving`'s `existing`, so a key outside it (a closed window) is pruned.
/// Project keys go into `bufs`. Returns how many were written to `out`.
pub fn allKeys(
    placed: []const outline.Placed,
    window_keys: []const []const u8,
    bufs: []Key,
    out: [][]const u8,
) usize {
    var n: usize = 0;
    var nb: usize = 0;
    for (placed, 0..) |p, i| {
        if (outline.opensProject(placed, i) and nb < bufs.len and n < out.len) {
            bufs[nb] = projectKey(p.project.?);
            out[n] = bufs[nb].slice();
            n += 1;
            nb += 1;
        }
        if (n == out.len) break;
        out[n] = window_keys[p.index];
        n += 1;
    }
    return n;
}

/// The order after putting `key` at `index` of `siblings` - the list it was
/// dragged in, without it (Mac `placeInAllWindowsList`). The keys written
/// to `out` borrow the inputs' memory.
pub fn moving(
    key: []const u8,
    index: usize,
    siblings_without: []const []const u8,
    order: []const []const u8,
    existing: []const []const u8,
    out: [][]const u8,
) usize {
    // `pane_sidebar_order.moving` takes the list WITH the item and the index
    // of the list without it.
    var visible: [max_keys][]const u8 = undefined;
    const n = @min(siblings_without.len, max_keys - 1);
    @memcpy(visible[0..n], siblings_without[0..n]);
    visible[n] = key;
    return keys_by.move(key, index, visible[0 .. n + 1], order, existing, out);
}

// ---------------------------------------------------------------------------
// The drag's geometry (Mac `PaneSidebarItemReorder`), in pixels, y down

/// An item's laid-out extent: a group's is its header and its windows.
pub const Span = struct {
    top: i32,
    bottom: i32,

    pub fn height(self: Span) i32 {
        return self.bottom - self.top;
    }

    /// Twice the middle, so an odd height compares exactly.
    fn mid2(self: Span) i32 {
        return self.top + self.bottom;
    }
};

/// The index, among the siblings without the dragged one, it would land at
/// with its top at `top`: above every sibling before it whose middle its top
/// has passed, below every one after it whose middle its bottom has passed.
/// The leading edge, not the middle: a tall item held at the top of the list
/// still goes above a short first one.
pub fn target(top: i32, dragged: usize, frames: []const Span) usize {
    if (dragged >= frames.len) return 0;
    const bottom = top + frames[dragged].height();
    var n: usize = 0;
    for (frames[0..dragged]) |f| {
        if (f.mid2() <= 2 * top) n += 1;
    }
    for (frames[dragged + 1 ..]) |f| {
        if (f.mid2() < 2 * bottom) n += 1;
    }
    return n;
}

/// How far each sibling slides to make room: the dragged item's height and
/// the gap that follows it (or, last, the one before it), so the list closes
/// up exactly where it left.
pub fn pitch(dragged: usize, frames: []const Span) i32 {
    if (dragged >= frames.len) return 0;
    const f = frames[dragged];
    if (dragged + 1 < frames.len) return frames[dragged + 1].top - f.top;
    if (dragged > 0) return f.bottom - frames[dragged - 1].bottom;
    return f.height();
}

/// Where the dragged item's top will be laid out once it is moved to
/// `to` (an index without it): down, it ends where the last sibling it
/// passed ended; up, it starts where the first one it passed started.
pub fn landingTop(dragged: usize, to: usize, frames: []const Span) i32 {
    if (dragged >= frames.len) return 0;
    const f = frames[dragged];
    if (to > dragged and to < frames.len) return f.top + (frames[to].bottom - f.bottom);
    if (to < dragged) return frames[to].top;
    return f.top;
}

/// Keeps the dragged item's top inside its siblings' span: dragged past the
/// first or last, it stops there rather than leaving the list. It may also
/// stay as low as `grabbed`, where it was picked up: a group drag folds the
/// list up from under it, and the held header stays under the pointer rather
/// than jumping to the shortened list's end.
pub fn clamp(top: i32, dragged: usize, frames: []const Span, grabbed: ?i32) i32 {
    if (dragged >= frames.len or frames.len == 0) return top;
    const first = frames[0];
    const last = frames[frames.len - 1];
    var lowest = last.bottom - frames[dragged].height();
    if (grabbed) |g| lowest = @max(lowest, g);
    return @min(@max(top, first.top), @max(first.top, lowest));
}

// ---------------------------------------------------------------------------
// The file

/// The stored order, one key per line. A line that is empty or not a key is
/// skipped, so a hand edit or a future key kind costs only itself. Duplicates
/// are harmless (`arranged` counts a key once). Returns how many keys were
/// written to `out`, as slices of `text`.
pub fn parse(text: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| {
        if (n == out.len) break;
        if (!std.mem.startsWith(u8, line, project_prefix) and !std.mem.startsWith(u8, line, window_prefix)) continue;
        if (line.len > key_cap) continue;
        out[n] = line;
        n += 1;
    }
    return n;
}

pub fn format(w: anytype, keys: []const []const u8) !void {
    for (keys) |k| {
        if (std.mem.indexOfAny(u8, k, "\r\n") != null) continue;
        try w.writeAll(k);
        try w.writeByte('\n');
    }
}

/// `%LOCALAPPDATA%\ghoztty\pane_sidebar_order[-debug]` (the
/// `pane_sidebar_prefs` pattern: a debug build never changes the order the
/// user's release app shows).
fn path(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    const name = if (builtin.mode == .Debug) "pane_sidebar_order-debug" else "pane_sidebar_order";
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

/// The stored file's text (caller frees), or null when there is none.
pub fn load(alloc: Allocator) ?[]u8 {
    const p = path(alloc) orelse return null;
    defer alloc.free(p);
    return std.fs.cwd().readFileAlloc(alloc, p, 1 << 20) catch null;
}

/// Store `keys`. Best-effort: an order is never worth an error.
pub fn save(alloc: Allocator, keys: []const []const u8) void {
    const p = path(alloc) orelse return;
    defer alloc.free(p);
    std.fs.cwd().makePath(std.fs.path.dirname(p) orelse return) catch return;
    const f = std.fs.cwd().createFile(p, .{ .truncate = true }) catch return;
    defer f.close();
    var size: usize = 0;
    for (keys) |k| size += k.len + 1;
    const text = alloc.alloc(u8, size) catch return;
    defer alloc.free(text);
    var fbs = std.io.fixedBufferStream(text);
    format(fbs.writer(), keys) catch return;
    f.writeAll(fbs.getWritten()) catch {};
}

// ---------------------------------------------------------------------------
// Tests (Mac `PaneSidebarWindowOrderTests`, `PaneSidebarItemReorderTests`)

const testing = std.testing;

/// Titles and ids in, the arranged outline as `project/label` or `label`.
fn expectArranged(want: []const []const u8, titles: []const []const u8, order: []const []const u8) !void {
    var placed: [16]outline.Placed = undefined;
    const n = outline.outlineOrder(titles, &placed);
    var keys_buf: [16]Key = undefined;
    var keys: [16][]const u8 = undefined;
    for (titles, 0..) |_, i| {
        var id: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&id, "w{d}", .{i}) catch unreachable;
        keys_buf[i] = windowKey(s);
        keys[i] = keys_buf[i].slice();
    }
    var out: [16]outline.Placed = undefined;
    const m = arrange(placed[0..n], keys[0..titles.len], order, &out);
    try testing.expectEqual(want.len, m);
    for (want, 0..) |wnt, i| {
        var b: [64]u8 = undefined;
        const got = if (out[i].project) |p|
            std.fmt.bufPrint(&b, "{s}/{s}", .{ p, out[i].label }) catch unreachable
        else
            out[i].label;
        try testing.expectEqualStrings(wnt, got);
    }
}

test "T2337: with no order the list is the name order" {
    try expectArranged(&.{ "alpha", "p/a", "p/b", "zeta" }, &.{ "zeta", "p: b", "alpha", "p: a" }, &.{});
}

test "T2337: the order moves groups and lone windows at the top level" {
    // Titles: 0 zeta, 1 p: b, 2 alpha, 3 p: a.
    try expectArranged(&.{ "zeta", "p/a", "p/b", "alpha" }, &.{ "zeta", "p: b", "alpha", "p: a" }, &.{ "window:w0", "project:p", "window:w2" });
}

test "T2337: a group's windows follow the order, and stay together" {
    try expectArranged(&.{ "alpha", "p/b", "p/a", "zeta" }, &.{ "zeta", "p: b", "alpha", "p: a" }, &.{ "window:w1", "window:w3" });
}

test "T2337: a new window lands after its name-order neighbour" {
    // wt-2 was dragged to the front; a new wt-3 follows it there, ahead of
    // wt-1, rather than going to the end.
    try expectArranged(
        &.{ "g/wt-2", "g/wt-3", "g/wt-1" },
        &.{ "g: wt-1", "g: wt-2", "g: wt-3" },
        &.{ "window:w1", "window:w0" },
    );
}

test "T2337: a new group lands after its name-order neighbour too" {
    // b was dragged ahead of a; new group "ab" sorts between a and b by name,
    // so it follows a, which the order put last.
    try expectArranged(
        &.{ "b", "a", "ab/x" },
        &.{ "a", "b", "ab: x" },
        &.{ "window:w1", "window:w0" },
    );
}

test "T2337: projects differing only in case are two keys" {
    try testing.expect(!std.mem.eql(u8, projectKey("Proj").slice(), projectKey("proj").slice()));
    try expectArranged(&.{ "proj/a", "Proj/b" }, &.{ "Proj: b", "proj: a" }, &.{ "project:proj", "project:Proj" });
}

test "T2337: every key - each group and each window" {
    var placed: [8]outline.Placed = undefined;
    const titles = [_][]const u8{ "solo", "p: a", "p: b" };
    const n = outline.outlineOrder(&titles, &placed);
    const wk = [_][]const u8{ "window:s", "window:a", "window:b" };
    var bufs: [4]Key = undefined;
    var out: [8][]const u8 = undefined;
    const m = allKeys(placed[0..n], &wk, &bufs, &out);
    try testing.expectEqual(@as(usize, 4), m);
    try testing.expectEqualStrings("project:p", out[0]);
    try testing.expectEqualStrings("window:a", out[1]);
    try testing.expectEqualStrings("window:b", out[2]);
    try testing.expectEqualStrings("window:s", out[3]);
}

test "T2337: moving puts the key among its siblings and prunes closed windows" {
    var out: [8][]const u8 = undefined;
    // A group dragged to the front of [solo, other].
    const n = moving("project:p", 0, &.{ "window:solo", "window:other" }, &.{}, &.{ "window:solo", "window:other", "project:p", "window:a" }, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("project:p", out[0]);
    try testing.expectEqualStrings("window:solo", out[1]);
    try testing.expectEqualStrings("window:other", out[2]);
    // A window's key the list no longer has is dropped on the next move;
    // a group's windows keep their place after the item they followed.
    const m = moving(
        "window:other",
        0,
        &.{ "project:p", "window:solo" },
        &.{ "project:p", "window:b", "window:a", "window:gone", "window:solo", "window:other" },
        &.{ "project:p", "window:a", "window:b", "window:solo", "window:other" },
        &out,
    );
    try testing.expectEqual(@as(usize, 5), m);
    const want = [_][]const u8{ "window:other", "project:p", "window:b", "window:a", "window:solo" };
    for (want, 0..) |w, i| try testing.expectEqualStrings(w, out[i]);
}

test "T2337: dragged while a search hides a sibling, the hidden one keeps its place" {
    // The list shows a and c (b is hidden by the search); a dragged below c.
    // b stays right after the item it followed rather than moving with a.
    var out: [8][]const u8 = undefined;
    const n = moving(
        "window:a",
        1,
        &.{"window:c"},
        &.{ "window:a", "window:b", "window:c" },
        &.{ "window:a", "window:b", "window:c" },
        &out,
    );
    const want = [_][]const u8{ "window:b", "window:c", "window:a" };
    try testing.expectEqual(want.len, n);
    for (want, 0..) |w, i| try testing.expectEqualStrings(w, out[i]);
}

fn spans(comptime hs: []const i32) [hs.len]Span {
    var out: [hs.len]Span = undefined;
    var y: i32 = 0;
    for (hs, 0..) |h, i| {
        out[i] = .{ .top = y, .bottom = y + h };
        y += h + 4;
    }
    return out;
}

test "T2337: the index is read by the leading edge against the siblings' middles" {
    // Heights 30, 30, 30 at 0, 34, 68 (gaps of 4).
    const f = spans(&.{ 30, 30, 30 });
    try testing.expectEqual(@as(usize, 0), target(0, 0, &f));
    // Its bottom past the middle of the next (34..64, mid 49): one down.
    try testing.expectEqual(@as(usize, 0), target(18, 0, &f));
    try testing.expectEqual(@as(usize, 1), target(20, 0, &f));
    try testing.expectEqual(@as(usize, 2), target(60, 0, &f));
    // The last one moved up: its top past the middle of the one above.
    try testing.expectEqual(@as(usize, 2), target(68, 2, &f));
    try testing.expectEqual(@as(usize, 2), target(49, 2, &f)); // at the middle: passed
    try testing.expectEqual(@as(usize, 1), target(48, 2, &f));
    try testing.expectEqual(@as(usize, 0), target(14, 2, &f));
}

test "T2337: a tall item held at the top still goes above a short first one" {
    const f = spans(&.{ 20, 20, 120 });
    try testing.expectEqual(@as(usize, 0), target(0, 2, &f));
}

test "T2337: the pitch is the item and the gap after it, or before it when last" {
    const f = spans(&.{ 30, 50, 30 });
    try testing.expectEqual(@as(i32, 34), pitch(0, &f));
    try testing.expectEqual(@as(i32, 54), pitch(1, &f));
    try testing.expectEqual(@as(i32, 34), pitch(2, &f));
    const one = spans(&.{30});
    try testing.expectEqual(@as(i32, 30), pitch(0, &one));
}

test "T2337: where it lands" {
    const f = spans(&.{ 30, 50, 30 }); // 0-30, 34-84, 88-118
    // Down past the 50: ends where that one ended.
    try testing.expectEqual(@as(i32, 54), landingTop(0, 1, &f));
    // Up to the front: starts where the first started.
    try testing.expectEqual(@as(i32, 0), landingTop(2, 0, &f));
    try testing.expectEqual(@as(i32, 34), landingTop(1, 1, &f));
}

test "T2337: the item is kept in its list, or as low as where it was grabbed" {
    const f = spans(&.{ 30, 30, 30 }); // last bottom 98
    try testing.expectEqual(@as(i32, 0), clamp(-50, 1, &f, null));
    try testing.expectEqual(@as(i32, 68), clamp(500, 1, &f, null));
    try testing.expectEqual(@as(i32, 40), clamp(40, 1, &f, null));
    // A group drag folded the list up under a header grabbed at 200.
    try testing.expectEqual(@as(i32, 200), clamp(500, 1, &f, 200));
    try testing.expectEqual(@as(i32, 150), clamp(150, 1, &f, 200));
}

test "T2337: the file round-trips, and skips what is not a key" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try format(fbs.writer(), &.{ "project:ghoztty", "window:1D0A0B0C-0000-4000-8000-000000000001", "bad\nkey" });
    var out: [8][]const u8 = undefined;
    const n = parse(fbs.getWritten(), &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("project:ghoztty", out[0]);
    try testing.expectEqualStrings("window:1D0A0B0C-0000-4000-8000-000000000001", out[1]);
    // CRLF, blank lines and junk.
    const m = parse("\r\nproject:a\r\njunk\r\n\r\nwindow:x\r\n", &out);
    try testing.expectEqual(@as(usize, 2), m);
    try testing.expectEqualStrings("project:a", out[0]);
    try testing.expectEqualStrings("window:x", out[1]);
}
