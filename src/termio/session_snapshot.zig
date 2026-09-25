//! WP-D3 session snapshot serialization (T109, T1626).
//!
//! A session-persistence pane is restored by painting a structured VT repaint
//! of the screen it had when the manifest was last written, and then letting the
//! agent's gap-fill replay CONTINUE that screen from the recorded byte offset
//! (`Surface.sessionSnapshot`, `Remote.restore_snapshot`). The gap-fill is the
//! raw child stream: it writes at wherever the cursor is. So the one thing the
//! repaint must get exactly right, beyond the cells, is where it leaves the
//! cursor — a repaint that restores every cell and parks the cursor one row up
//! and fifty columns over makes the first line of the gap-fill land on top of
//! the last restored line.
//!
//! That is what `TerminalFormatter` with `Extra.all` did, twice over (found by
//! arm F of `test\win32\session-resume-offset.ps1`, where the first line printed
//! after the capture came back glued onto the end of the line before it):
//!
//!   - It writes the cursor position (CUP) with the SCREEN extras, and only
//!     then the TERMINAL extras — and two of those move the cursor. DECSTBM
//!     homes it, and the tab-stop restore walks it across the row with CHA+HTS,
//!     so every snapshot of a pane with default tab stops left the cursor on the
//!     last tab stop (column 57 on an 80-column-ish pane) instead of where it
//!     was.
//!   - It always drops trailing blank rows, but CUP is viewport-relative. A pane
//!     whose cursor sits on a blank row below the output (every shell that has
//!     just printed a newline) comes back with its viewport shifted by those
//!     rows, so the CUP lands that many rows too high.
//!
//! The fix lives here, not in the upstream formatter: it runs the formatter in
//! two passes (content, then the cursor-moving extras), puts the trimmed blank
//! rows back between them so the restored viewport lines up with the source's,
//! and writes the cursor position LAST, origin-mode aware.

const std = @import("std");
const testing = std.testing;
const terminal = @import("../terminal/main.zig");

const Terminal = terminal.Terminal;
const TerminalFormatter = terminal.formatter.TerminalFormatter;

/// Serialize `t`'s active screen — the last `max_rows` rows of it, viewport
/// plus scrollback — as a VT repaint that, replayed into a blank terminal of the
/// same size, reproduces the cells, the terminal state, AND the cursor position.
///
/// `input_modes` is the formatter flag of the same name: false for anything
/// persisted to disk (see `Surface.sessionSnapshotLocked`).
pub fn write(
    writer: *std.Io.Writer,
    t: *const Terminal,
    max_rows: usize,
    input_modes: bool,
) !void {
    const screen = t.screens.active;
    const br = screen.pages.getBottomRight(.screen) orelse return;
    const total = screen.pages.total_rows;
    const tl = if (total <= max_rows)
        screen.pages.getTopLeft(.screen)
    else
        screen.pages.pin(.{ .screen = .{
            .x = 0,
            .y = @intCast(total - max_rows),
        } }) orelse screen.pages.getTopLeft(.screen);

    const opts: terminal.formatter.Options = .{
        .emit = .vt,
        .unwrap = false,
        .trim = true,
    };

    // Pass 1: palette, modes, and the cells. No extra that moves the cursor.
    var content: TerminalFormatter = .init(t, opts);
    content.content = .{ .selection = terminal.Selection.init(tl, br, false) };
    content.extra = .none;
    content.extra.palette = true;
    content.extra.modes = true;
    content.extra.input_modes = input_modes;
    try content.format(writer);

    // The blank rows the formatter trimmed off the bottom. Written back so the
    // last row of the repaint IS the source's bottom row: the selection always
    // spans at least a viewport (it runs to the bottom of the active area), so
    // the replayed viewport is then exactly the source viewport, and a
    // viewport-relative CUP means the same cell in both. Nothing to put back
    // when the whole selection is blank: nothing was written, so there is
    // nothing to shift.
    const trailing = trailingBlankRows(t, tl, br);
    if (trailing.rows > 0 and !trailing.all_blank) {
        // Plain rows: a line feed at the bottom scrolls in a row filled with
        // the CURRENT background, so drop whatever style the cells left open.
        try writer.writeAll("\x1b[0m");
        for (0..trailing.rows) |_| try writer.writeAll("\r\n");
    }

    // Pass 2: every remaining extra, cursor excluded — several of these move it.
    var state: TerminalFormatter = .init(t, opts);
    state.content = .none;
    state.extra = .all;
    state.extra.palette = false;
    state.extra.modes = false;
    state.extra.input_modes = input_modes;
    state.extra.screen.cursor = false;
    try state.format(writer);

    // Last: the cursor. CUP is relative to the scrolling region when origin
    // mode is on, and pass 1 restored that mode, so address it the same way.
    const cursor = screen.cursor;
    var y: usize = cursor.y;
    var x: usize = cursor.x;
    if (t.modes.get(.origin)) {
        y -|= t.scrolling_region.top;
        x -|= t.scrolling_region.left;
    }
    try writer.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
}

const Trailing = struct { rows: usize, all_blank: bool };

/// How many rows at the bottom of `[tl, br]` hold no text — the rows the
/// formatter will not write.
fn trailingBlankRows(t: *const Terminal, tl: terminal.Pin, br: terminal.Pin) Trailing {
    var it = br.rowIterator(.left_up, tl);
    var rows: usize = 0;
    while (it.next()) |pin| {
        if (terminal.page.Cell.hasTextAny(pin.cells(.all))) return .{ .rows = rows, .all_blank = false };
        rows += 1;
    }
    _ = t;
    return .{ .rows = rows, .all_blank = true };
}

// ---- tests -----------------------------------------------------------------

fn replay(alloc: std.mem.Allocator, src: *const Terminal, max_rows: usize) !Terminal {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    try write(&builder.writer, src, max_rows, false);

    var t2 = try Terminal.init(alloc, .{ .cols = src.cols, .rows = src.rows });
    errdefer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(builder.writer.buffered());
    return t2;
}

fn expectSameCursor(a: *const Terminal, b: *const Terminal) !void {
    try testing.expectEqual(a.screens.active.cursor.x, b.screens.active.cursor.x);
    try testing.expectEqual(a.screens.active.cursor.y, b.screens.active.cursor.y);
}

fn viewportText(alloc: std.mem.Allocator, t: *Terminal) ![]const u8 {
    return t.plainString(alloc);
}

test "session snapshot: cursor on the blank row below scrolled output comes back there" {
    // The T1626 shape: a shell that has printed a screenful and a newline, so
    // the cursor sits at column 0 of a blank bottom row.
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 80, .rows = 10 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    for (1..40) |i| {
        var buf: [16]u8 = undefined;
        s.nextSlice(try std.fmt.bufPrint(&buf, "F-{d}\r\n", .{i}));
    }
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.y);

    var t2 = try replay(alloc, &t, 600);
    defer t2.deinit(alloc);
    try expectSameCursor(&t, &t2);

    // And the next byte of the stream lands where it did in the source.
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice("F-40\r\n");
    s.nextSlice("F-40\r\n");
    const a = try viewportText(alloc, &t);
    defer alloc.free(a);
    const b = try viewportText(alloc, &t2);
    defer alloc.free(b);
    try testing.expectEqualStrings(a, b);
}

test "session snapshot: default tab stops do not drag the cursor to the last stop" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 80, .rows = 10 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld");

    var t2 = try replay(alloc, &t, 600);
    defer t2.deinit(alloc);
    try expectSameCursor(&t, &t2);
    // The tab stops themselves still round-trip.
    try testing.expect(t2.tabstops.get(8));
    try testing.expect(t2.tabstops.get(72));
}

test "session snapshot: a scrolling region is restored without homing the cursor" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 40, .rows = 12 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("top\r\nmid\r\n\x1b[3;10r\x1b[7;5Hhere");

    var t2 = try replay(alloc, &t, 600);
    defer t2.deinit(alloc);
    try expectSameCursor(&t, &t2);
    try testing.expectEqual(t.scrolling_region.top, t2.scrolling_region.top);
    try testing.expectEqual(t.scrolling_region.bottom, t2.scrolling_region.bottom);
}

test "session snapshot: origin mode addresses the cursor inside the region" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 40, .rows = 12 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("x\x1b[4;10r\x1b[?6h\x1b[2;3Hin");

    var t2 = try replay(alloc, &t, 600);
    defer t2.deinit(alloc);
    try expectSameCursor(&t, &t2);
}

test "session snapshot: a short screen with the cursor mid-row is unchanged" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("C:\\Users\\David>dir");

    var t2 = try replay(alloc, &t, 600);
    defer t2.deinit(alloc);
    try expectSameCursor(&t, &t2);
}

test "session snapshot: a blank screen writes no rows and keeps the cursor" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[5;7H");

    var t2 = try replay(alloc, &t, 600);
    defer t2.deinit(alloc);
    try expectSameCursor(&t, &t2);
}

test "session snapshot: the max_rows bound still lines the viewport up" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 40, .rows = 8 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    for (1..200) |i| {
        var buf: [16]u8 = undefined;
        s.nextSlice(try std.fmt.bufPrint(&buf, "L{d}\r\n", .{i}));
    }
    s.nextSlice("\r\n\r\nprompt>");

    var t2 = try replay(alloc, &t, 30);
    defer t2.deinit(alloc);
    try expectSameCursor(&t, &t2);
}
