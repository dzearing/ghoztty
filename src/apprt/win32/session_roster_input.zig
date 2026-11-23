//! The session roster's input plane (split out of `SessionRoster.zig` by
//! T1783): hit testing a click against a card, its button, its kill control
//! and its CPU meter, plus the keyboard cursor and the scroll offset.

const SessionRoster = @import("SessionRoster.zig");

const std = @import("std");
const builtin = @import("builtin");
const App = @import("App.zig");
const Window = @import("Window.zig");
const chooser_cpu = @import("chooser_cpu.zig");
const chooser_layout = @import("chooser_layout.zig");
const chooser_session_sort = @import("chooser_session_sort.zig");
const chooser_sessions = @import("chooser_sessions.zig");
const chrome_theme = @import("chrome_theme.zig");
const icon_button = @import("icon_button.zig");
const layout_blobs = @import("layout_blobs.zig");
const LocalAgent = @import("LocalAgent.zig");
const machine_pool = @import("machine_pool.zig");
const MachineConnectionPool = @import("MachineConnectionPool.zig");
const session_layout = @import("session_layout.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const remote_connection = @import("../../remote/connection.zig");
const w32 = @import("win32.zig");

const VisibleRow = SessionRoster.VisibleRow;
const contentHeight = SessionRoster.contentHeight;
const max_id_len = SessionRoster.max_id_len;
const testRows = SessionRoster.testRows;
const testing = SessionRoster.testing;

// ---------------------------------------------------------------------
// Hit testing (GUI thread)
// ---------------------------------------------------------------------

/// One card's layout as this roster draws it: the machine's CPU column and the
/// row's Show / Resume button (T1746) both placed. Every paint and every hit
/// test goes through here, so what is drawn and what answers the click cannot
/// disagree about where the button is.
pub fn layoutRow(
    self: *const SessionRoster,
    m: chooser_sessions.Metrics,
    x: i32,
    y: i32,
    w: i32,
    sublines: i32,
) chooser_sessions.RowLayout {
    const bare = chooser_sessions.rowLayout(m, x, y, w, sublines, self.cpu_column);
    return chooser_sessions.withAction(bare, m, self.action_text_w);
}

/// The visible row whose Show / Resume button contains the client point, or
/// null (T1746). A row with no verb (an exited session) has no button, so its
/// slot answers nothing — the click falls through to the card.
pub fn actionAt(
    self: *const SessionRoster,
    rows: []const VisibleRow,
    region: chooser_layout.Rect,
    scale: f32,
    x: i32,
    y: i32,
) ?usize {
    if (x < region.left or x >= region.right) return null;
    if (y < region.top or y >= region.bottom) return null;

    const m = chooser_sessions.metrics(scale);
    var cy = region.top - self.scroll;
    for (rows, 0..) |row, i| {
        const subs = chooser_sessions.sublineCount(row.session);
        const l = self.layoutRow(m, region.left, cy, region.width(), subs);
        cy = l.card.bottom + m.row_gap;
        if (chooser_sessions.actionLabel(row.session, row.open_locally) == null) continue;
        if (l.action.width() <= 0) continue;
        if (l.action.left <= x and x < l.action.right and
            l.action.top <= y and y < l.action.bottom) return i;
    }
    return null;
}

/// The visible row whose Kill button contains the client point, or null. Gaps
/// are measured to painted edges but CLICKS land on the hit box (§1.2), which
/// is why this tests `kill_hit` and the painter draws `kill`.
pub fn killAt(
    self: *const SessionRoster,
    rows: []const VisibleRow,
    region: chooser_layout.Rect,
    scale: f32,
    x: i32,
    y: i32,
) ?usize {
    if (x < region.left or x >= region.right) return null;
    if (y < region.top or y >= region.bottom) return null;

    const m = chooser_sessions.metrics(scale);
    var cy = region.top - self.scroll;
    for (rows, 0..) |row, i| {
        const subs = chooser_sessions.sublineCount(row.session);
        const l = self.layoutRow(m, region.left, cy, region.width(), subs);
        cy = l.card.bottom + m.row_gap;
        if (l.kill_hit.left <= x and x < l.kill_hit.right and
            l.kill_hit.top <= y and y < l.kill_hit.bottom) return i;
    }
    return null;
}

/// The visible row whose CARD contains the client point, or null. The Kill
/// button sits inside a card, so callers test `killAt` first — one point can
/// answer both, and Kill is the more specific of the two.
pub fn rowAt(
    self: *const SessionRoster,
    rows: []const VisibleRow,
    region: chooser_layout.Rect,
    scale: f32,
    x: i32,
    y: i32,
) ?usize {
    if (x < region.left or x >= region.right) return null;
    if (y < region.top or y >= region.bottom) return null;

    const m = chooser_sessions.metrics(scale);
    var cy = region.top - self.scroll;
    for (rows, 0..) |row, i| {
        const subs = chooser_sessions.sublineCount(row.session);
        const l = self.layoutRow(m, region.left, cy, region.width(), subs);
        cy = l.card.bottom + m.row_gap;
        if (l.card.left <= x and x < l.card.right and
            l.card.top <= y and y < l.card.bottom) return i;
    }
    return null;
}

/// The visible row whose CPU METER contains the client point, or null (T812).
/// The meter is the smallest thing on a card, so its hover is tested with the
/// column rect the layout reserved rather than the pieces inside it: the gap
/// between the bar and its number is part of the meter to anyone pointing at
/// it, and a hover that dies in that gap reads as a flickering tooltip.
///
/// A row with no reading answers null even though the column is reserved —
/// nothing is painted there, and a tooltip explaining a meter that is not on
/// screen is worse than no tooltip (the T181 rule: an empty thing is an answer).
pub fn cpuAt(
    self: *const SessionRoster,
    rows: []const VisibleRow,
    region: chooser_layout.Rect,
    scale: f32,
    x: i32,
    y: i32,
) ?usize {
    if (!self.cpu_column) return null;
    if (x < region.left or x >= region.right) return null;
    if (y < region.top or y >= region.bottom) return null;

    const m = chooser_sessions.metrics(scale);
    var cy = region.top - self.scroll;
    for (rows, 0..) |row, i| {
        const subs = chooser_sessions.sublineCount(row.session);
        const l = self.layoutRow(m, region.left, cy, region.width(), subs);
        cy = l.card.bottom + m.row_gap;
        if (row.cpu == null) continue;
        if (l.cpu.width() <= 0) continue;
        if (l.cpu.left <= x and x < l.cpu.right and
            l.cpu.top <= y and y < l.cpu.bottom) return i;
    }
    return null;
}

/// Whether the keyboard sub-cursor is IN the roster at all — the test the
/// keyboard routing branches on (Return resumes the cursored row, Up/Down walk
/// the sessions rather than the machine list).
pub fn hasCursor(self: *const SessionRoster) bool {
    return self.cursor_id_len > 0;
}

/// The anchored session id, or null.
pub fn cursorId(self: *const SessionRoster) ?[]const u8 {
    if (self.cursor_id_len == 0) return null;
    return self.cursor_id[0..self.cursor_id_len];
}

/// Anchor the cursor to `id` (a click, or keyboard entry). An id too long for
/// the buffer clears instead — better no highlight than a truncated anchor
/// that can never match its row again.
pub fn setCursor(self: *SessionRoster, id: []const u8) void {
    if (id.len == 0 or id.len > max_id_len) {
        self.cursor_id_len = 0;
        return;
    }
    @memcpy(self.cursor_id[0..id.len], id);
    self.cursor_id_len = id.len;
}

pub fn clearCursor(self: *SessionRoster) void {
    self.cursor_id_len = 0;
}

/// The keyboard cursor as an index INTO `rows` (the DISPLAYED, sorted list),
/// or null when it points nowhere — no anchor, or the anchored session is no
/// longer in the roster (it exited, or was killed, while the cursor sat on
/// it). Resolved HERE, at the point of use, rather than kept in sync with
/// every change: the list re-sorts and shrinks underneath the anchor, and the
/// id follows the row the user is looking at through both.
pub fn cursorIndex(self: *const SessionRoster, rows: []const VisibleRow) ?usize {
    const id = self.cursorId() orelse return null;
    for (rows, 0..) |r, i| {
        if (std.mem.eql(u8, r.session.id, id)) return i;
    }
    return null;
}

/// Right arrow: step the cursor INTO the displayed roster (Mac's
/// `enterSessions`). A roster with nothing rendered has nowhere to step; an
/// anchor that still resolves stays where it is rather than jumping home, and
/// a stale one re-enters at the first row.
pub fn enterCursor(self: *SessionRoster, rows: []const VisibleRow) void {
    if (rows.len == 0) return;
    if (self.cursorIndex(rows) != null) return;
    self.setCursor(rows[0].session.id);
}

/// Up/Down inside the roster: re-anchor to the row `delta` steps away in the
/// DISPLAYED order. Stepping above the first row — or from an anchor whose
/// session is gone — hands navigation back to the machine list; past the last
/// row clamps (a wrap would send the user to the top of a long roster they
/// were walking down).
pub fn moveCursor(self: *SessionRoster, rows: []const VisibleRow, delta: i32) void {
    const next = chooser_session_sort.steppedCursor(self.cursorIndex(rows), delta, rows.len);
    if (next) |i| self.setCursor(rows[i].session.id) else self.clearCursor();
}

/// Scroll the cursor's card fully into the region. Returns true when the offset
/// moved. Keyboard navigation that walks off the bottom of a long roster has to
/// bring the row with it, or the highlight is somewhere the user cannot see.
pub fn scrollToCursor(
    self: *SessionRoster,
    rows: []const VisibleRow,
    region: chooser_layout.Rect,
    scale: f32,
) bool {
    const idx = self.cursorIndex(rows) orelse return false;
    const m = chooser_sessions.metrics(scale);

    // The card's top/bottom in CONTENT space (scroll-independent).
    var top: i32 = 0;
    var height: i32 = 0;
    for (rows, 0..) |row, i| {
        const h = chooser_sessions.rowHeight(m, chooser_sessions.sublineCount(row.session));
        if (i == idx) {
            height = h;
            break;
        }
        top += h + m.row_gap;
    }

    const before = self.scroll;
    if (top < self.scroll) {
        self.scroll = top;
    } else if (top + height > self.scroll + region.height()) {
        self.scroll = top + height - region.height();
    }
    self.scroll = chooser_sessions.clampScroll(
        self.scroll,
        contentHeight(rows, scale),
        region.height(),
    );
    return self.scroll != before;
}

/// Re-clamp the offset against the rows as they are NOW. Called after an adopt
/// (T333), which keeps the offset the user scrolled to but can replace the rows
/// with a shorter set — and an offset past the end of the new content would
/// paint the region empty. Returns true when the offset moved.
pub fn clampScrollTo(
    self: *SessionRoster,
    rows: []const VisibleRow,
    region: chooser_layout.Rect,
    scale: f32,
) bool {
    return self.scrollBy(0, rows, region, scale);
}

/// Apply a wheel notch. Returns true when the offset actually changed, so the
/// caller only repaints when there is something new to see.
pub fn scrollBy(
    self: *SessionRoster,
    delta: i32,
    rows: []const VisibleRow,
    region: chooser_layout.Rect,
    scale: f32,
) bool {
    const before = self.scroll;
    self.scroll = chooser_sessions.clampScroll(
        self.scroll + delta,
        contentHeight(rows, scale),
        region.height(),
    );
    return self.scroll != before;
}

test "the cursor anchor survives a re-sort, and a gone anchor leaves the list" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();

    var rows = [_]VisibleRow{
        .{ .session = .{ .id = "1", .alive = true, .title = "alpha" } },
        .{ .session = .{ .id = "2", .alive = true, .title = "beta" } },
    };

    // Enter at the first DISPLAYED row, then flip the sort: the anchor's id
    // follows its row to the new index instead of re-pointing at whatever slid
    // into slot 0.
    roster.enterCursor(&rows);
    try testing.expectEqualStrings("1", roster.cursorId().?);
    roster.sort = .{ .key = .name, .ascending = false };
    roster.sortRows(&rows);
    try testing.expectEqualStrings("2", rows[0].session.id);
    try testing.expectEqual(@as(?usize, 1), roster.cursorIndex(&rows));

    // Walking is in DISPLAYED order: up from the second row is the first.
    roster.moveCursor(&rows, -1);
    try testing.expectEqualStrings("2", roster.cursorId().?);
    // Above the first row hands navigation back to the machine list.
    roster.moveCursor(&rows, -1);
    try testing.expect(!roster.hasCursor());

    // A stale anchor (its session was killed) resolves nowhere; stepping from
    // it leaves the list rather than adopting a stranger's row.
    roster.setCursor("gone");
    try testing.expectEqual(@as(?usize, null), roster.cursorIndex(&rows));
    roster.moveCursor(&rows, 1);
    try testing.expect(!roster.hasCursor());
    // And entry with a stale anchor re-enters at the first row.
    roster.setCursor("gone");
    roster.enterCursor(&rows);
    try testing.expectEqualStrings("2", roster.cursorId().?);
}

test "cpuAt answers the meter column, and only where a meter is painted (T812)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.cpu_column = true;

    var buf: [3]VisibleRow = undefined;
    const rows = testRows(&buf);
    buf[0].cpu = 12;
    buf[1].cpu = null; // this agent frame did not name row 1
    buf[2].cpu = 250;

    const scale: f32 = 1.0;
    const m = chooser_sessions.metrics(scale);
    const region: chooser_layout.Rect = .{
        .left = 0,
        .top = 0,
        .right = 400,
        .bottom = chooser_sessions.rowHeight(m, 0) * 3 + m.row_gap * 3,
    };
    const l0 = chooser_sessions.rowLayout(m, region.left, region.top, region.width(), 0, true);

    // The middle of row 0's meter.
    const mid_x = l0.cpu.left + @divTrunc(l0.cpu.width(), 2);
    const mid_y = l0.cpu.top + @divTrunc(l0.cpu.height(), 2);
    try testing.expectEqual(@as(?usize, 0), roster.cpuAt(rows, region, scale, mid_x, mid_y));

    // The gap between the bar and its number is part of the meter to anyone
    // pointing at it: a hover that died there would read as a flickering tip.
    const cm = chooser_cpu.metrics(scale);
    const gap_x = l0.cpu.left + cm.bar_w + @divTrunc(cm.gap, 2);
    try testing.expectEqual(@as(?usize, 0), roster.cpuAt(rows, region, scale, gap_x, mid_y));

    // The title beside it is not the meter.
    try testing.expectEqual(
        @as(?usize, null),
        roster.cpuAt(rows, region, scale, l0.title.left + 4, mid_y),
    );

    // Row 1 reserves the column - every row of a supported machine does - but
    // has no reading, so there is nothing on screen to explain.
    const row1_y = mid_y + chooser_sessions.rowHeight(m, 0) + m.row_gap;
    try testing.expectEqual(@as(?usize, null), roster.cpuAt(rows, region, scale, mid_x, row1_y));

    // Row 2 has one, and the walk found it past the row that did not.
    const row2_y = row1_y + chooser_sessions.rowHeight(m, 0) + m.row_gap;
    try testing.expectEqual(@as(?usize, 2), roster.cpuAt(rows, region, scale, mid_x, row2_y));
}

test "cpuAt is silent for a machine whose agent cannot serve the stream (T812)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.cpu_column = false;

    var buf: [2]VisibleRow = undefined;
    const rows = testRows(&buf);
    // A stale reading left over from the previous machine must not resurrect a
    // tooltip for a column that is not reserved at all.
    buf[0].cpu = 40;

    const scale: f32 = 1.0;
    const m = chooser_sessions.metrics(scale);
    const region: chooser_layout.Rect = .{
        .left = 0,
        .top = 0,
        .right = 400,
        .bottom = chooser_sessions.rowHeight(m, 0) * 2,
    };
    const l0 = chooser_sessions.rowLayout(m, region.left, region.top, region.width(), 0, false);
    try testing.expectEqual(@as(usize, 0), @as(usize, @intCast(l0.cpu.width())));
    try testing.expectEqual(
        @as(?usize, null),
        roster.cpuAt(rows, region, scale, l0.cpu.left, l0.cpu.top + 2),
    );
}

test "cpuAt follows the scroll offset the roster is parked at (T812)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.cpu_column = true;

    var buf: [4]VisibleRow = undefined;
    const rows = testRows(&buf);
    for (&buf) |*r| r.cpu = 10;

    const scale: f32 = 1.0;
    const m = chooser_sessions.metrics(scale);
    const row_h = chooser_sessions.rowHeight(m, 0);
    const region: chooser_layout.Rect = .{
        .left = 0,
        .top = 0,
        .right = 400,
        .bottom = row_h * 2,
    };
    const l0 = chooser_sessions.rowLayout(m, region.left, region.top, region.width(), 0, true);
    const mid_x = l0.cpu.left + @divTrunc(l0.cpu.width(), 2);
    const mid_y = l0.cpu.top + @divTrunc(l0.cpu.height(), 2);

    try testing.expectEqual(@as(?usize, 0), roster.cpuAt(rows, region, scale, mid_x, mid_y));
    // Scrolled by exactly one row, the same point is row 1's meter - the hit
    // test reads the offset the painter does, not a frozen origin.
    roster.scroll = row_h + m.row_gap;
    try testing.expectEqual(@as(?usize, 1), roster.cpuAt(rows, region, scale, mid_x, mid_y));
}

test "clampScrollTo pulls a parked offset back into a roster that shrank" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();

    var buf: [8]VisibleRow = undefined;
    const rows = testRows(&buf);
    const scale: f32 = 1.0;
    const row_h = chooser_sessions.rowHeight(chooser_sessions.metrics(scale), 0);
    const region: chooser_layout.Rect = .{
        .left = 0,
        .top = 0,
        .right = 400,
        .bottom = row_h * 2,
    };

    // Parked at the very bottom of eight rows: already legal, so nothing moves.
    roster.scroll = contentHeight(rows, scale) - region.height();
    const parked = roster.scroll;
    try testing.expect(parked > 0);
    try testing.expect(!roster.clampScrollTo(rows, region, scale));
    try testing.expectEqual(parked, roster.scroll);

    // The refetch came back with three: the same offset is now past the end,
    // and an unclamped one would paint the region empty.
    try testing.expect(roster.clampScrollTo(rows[0..3], region, scale));
    try testing.expectEqual(
        chooser_sessions.clampScroll(parked, contentHeight(rows[0..3], scale), region.height()),
        roster.scroll,
    );
    try testing.expect(roster.scroll < parked);
}
