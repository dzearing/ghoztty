//! T922: bringing the dead session's last screen back on the `restore` path.
//!
//! When the local agent restarts (a reboot, or the mandatory agent upgrade) the
//! default `restore` policy refuses to put the recorded command back on a CPU
//! and opens a BRAND-NEW session instead (T230, `session_notice`). Until D78
//! that also meant the pane came back EMPTY: the app's own persisted screen
//! snapshot (WP-D3, `Remote.restore_snapshot`) was deliberately not painted for
//! this path, on the argument that a fresh shell showing an old screen is a lie
//! about what the pane is. The Mac keeps the dead session's scrollback, and the
//! user settled the divergence in favour of the Mac (D78, 2026-08-18):
//!
//! > you can read the error, the build output or the last thing your agent said
//! > before the reboot took it
//!
//! So the restored screen is painted ABOVE the notice, and the notice's own fold
//! (`session_notice.foldIntoScrollback`) carries both into the scrollback before
//! the fresh shell's first repaint can erase them.
//!
//! What lives here is the part that can be asserted in the `none` lane instead
//! of only being observable by rebooting a box — whether there is anything worth
//! painting, what has to follow the paint, and what a snapshot taken inside a
//! full-screen program turns into (T1819). The caller (`Remote.threadEnter`)
//! owns the terminal reads and the writes. Same split as `restore_park.zig`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");

/// Leave the alternate screen, in the three spellings a snapshot can have
/// entered it with.
///
/// The snapshot is a structured repaint that reproduces the DIFFERING MODES it
/// recorded, alt-screen included (`Surface.sessionSnapshot`, `extra = .all`).
/// A snapshot taken inside a TUI is turned into plain history before it is
/// painted (`altHistory`), so the pane should never land on the alternate
/// screen here; this is the backstop for one that does anyway. Left there, the
/// fresh shell would run inside the alt screen: no scrollback to scroll, and
/// the notice folded above a viewport nobody can reach.
///
/// Emitted ONLY when the terminal actually ended up on the alternate screen —
/// `switchScreenMode` restores the saved cursor / erases the display even when
/// the mode is already off, which on the overwhelmingly common primary-screen
/// snapshot would throw away the very rows this exists to keep. That is the
/// same trap `Remote.replay_mode_reset` documents and avoids by omission; here
/// the mode is READ first, so it can be spelled explicitly.
pub const alt_screen_exit =
    "\x1b[?1049l" ++ // xterm alt screen with cursor save/restore
    "\x1b[?1047l" ++ // alt screen, no cursor save
    "\x1b[?47l"; // the original DECSET alt screen

/// The persisted screen bytes to paint above the session-interrupted notice, or
/// null when this pane has nothing to bring back.
///
/// Null cases, all of them "restore the pre-D78 way" rather than errors — a
/// snapshot is a fidelity win layered on a restore that has to work without it:
///
///   - no snapshot at all: a hard crash before the first manifest write, a
///     legacy manifest, or a snapshot dropped for being over the layout file's
///     budget (`App.captureLeafSnapshot`).
///   - an EMPTY snapshot: a pane that had produced nothing worth capturing.
///   - `attach_offset == 0`: the offset is what says the snapshot reflects a
///     real stream position. `Surface.sessionSnapshot` refuses to record one at
///     offset 0 for the same reason, and the live-attach paint is gated on it
///     identically — so a pane the two paths disagree about cannot exist.
pub fn historyToPaint(snapshot: ?[]const u8, attach_offset: u64) ?[]const u8 {
    const snap = snapshot orelse return null;
    if (snap.len == 0) return null;
    if (attach_offset == 0) return null;
    return snap;
}

/// The scratch terminal `altHistory` decodes a snapshot into. Tall and wide
/// enough that a full-screen frame painted with absolute cursor motion lands
/// where its program put it: an alternate screen has no scrollback, so a frame
/// painted into anything SHORTER than the pane it was drawn in loses its top
/// rows off the top — which is exactly what painting it into the restored pane
/// did, because a restored pane is still at its placeholder size when this
/// runs (T1819: the status line came back and the frame's first line did not).
/// Unwrapped output makes extra width harmless, so err wide.
const scratch_cols: u16 = 512;
const scratch_rows: u16 = 300;
const scratch_scrollback_bytes: usize = 8 * 1024 * 1024;

/// What a snapshot taken INSIDE a full-screen program becomes on the restore
/// path, or null when the snapshot does not end on the alternate screen (the
/// common case, which is painted as it is).
///
/// The program that drew the frame is dead, so the frame is history to read,
/// not a screen to resume: the primary screen's rows (what was printed before
/// the program started), then the program's last frame, both as CONTENT ONLY —
/// text, colors and hyperlinks, soft wraps left unwrapped so the pane reflows
/// them, and no modes, cursor addressing or scrolling region. That is the
/// Mac's reboot history for the same pane (`grid_snapshot.historyOf`, main
/// 7e78aacf4), and the pane stays on the PRIMARY screen throughout, so the
/// fresh shell has its scrollback and nothing has to be left.
///
/// Caller owns the returned bytes.
pub fn altHistory(gpa: Allocator, snapshot: []const u8, cols: u16, rows: u16) !?[]u8 {
    var t: terminal.Terminal = try .init(gpa, .{
        .cols = @max(cols, scratch_cols),
        .rows = @max(rows, scratch_rows),
        .max_scrollback = scratch_scrollback_bytes,
    });
    defer t.deinit(gpa);
    {
        var s: terminal.TerminalStream = .initAlloc(gpa, .init(&t));
        defer s.deinit();
        s.nextSlice(snapshot);
    }
    if (t.screens.active_key != .alternate) return null;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    const opts: terminal.formatter.Options = .{ .emit = .vt, .unwrap = true, .trim = true };

    if (t.screens.get(.primary)) |primary| {
        var sf = terminal.formatter.ScreenFormatter.init(primary, opts);
        sf.extra = .none;
        try sf.format(w);
    }
    if (t.screens.get(.alternate)) |alt| {
        var frame: std.Io.Writer.Allocating = .init(gpa);
        defer frame.deinit();
        var sf = terminal.formatter.ScreenFormatter.init(alt, opts);
        sf.extra = .none;
        try sf.format(&frame.writer);
        if (frame.written().len > 0) {
            // Close whatever style the primary rows ended in, and start the
            // frame on a fresh line below them.
            if (out.written().len > 0) try w.writeAll("\x1b[0m\r\n");
            try w.writeAll(frame.written());
        }
    }
    if (out.written().len > 0) try w.writeAll("\x1b[0m");
    return try out.toOwnedSlice();
}

/// The LIVE terminal's alternate-screen frame as content-only history, or null
/// when `t` is on the primary screen or the frame is blank.
///
/// The in-place sibling of `altHistory` (T1793): a pane whose session's host
/// died is still showing the dead program's last frame, and leaving the alternate
/// screen to give the fresh shell the primary one discards it. Formatted the same
/// way, so the caller can leave the alternate screen and print this onto the
/// primary, where the notice fold carries it into the scrollback. The primary
/// screen's rows are NOT included: unlike a snapshot, they are still there.
///
/// Caller holds the terminal's lock and owns the returned bytes.
pub fn liveAltFrame(gpa: Allocator, t: *terminal.Terminal) !?[]u8 {
    if (t.screens.active_key != .alternate) return null;
    const alt = t.screens.get(.alternate) orelse return null;
    var frame: std.Io.Writer.Allocating = .init(gpa);
    defer frame.deinit();
    var sf = terminal.formatter.ScreenFormatter.init(alt, .{ .emit = .vt, .unwrap = true, .trim = true });
    sf.extra = .none;
    try sf.format(&frame.writer);
    if (frame.written().len == 0) return null;
    try frame.writer.writeAll("\x1b[0m");
    return try frame.toOwnedSlice();
}

test "liveAltFrame: a full-screen program's frame comes back as text; the primary screen gives null" {
    const gpa = testing.allocator;
    var t: terminal.Terminal = try .init(gpa, .{ .cols = 40, .rows = 6, .max_scrollback = 4096 });
    defer t.deinit(gpa);

    feedAll(&t, "before the program\r\n");
    try testing.expect((try liveAltFrame(gpa, &t)) == null);

    feedAll(&t, "\x1b[?1049h\x1b[H\x1b[2Jthe last thing it said");
    const frame = (try liveAltFrame(gpa, &t)).?;
    defer gpa.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "the last thing it said") != null);
    // Content only: nothing that would move the cursor or erase on the way back.
    try testing.expect(std.mem.indexOf(u8, frame, "\x1b[2J") == null);
    try testing.expect(std.mem.indexOf(u8, frame, "\x1b[?1049") == null);

    // A blank alternate screen has nothing worth keeping.
    feedAll(&t, "\x1b[2J");
    try testing.expect((try liveAltFrame(gpa, &t)) == null);
}

test "historyToPaint: a real snapshot at a real offset is painted" {
    const snap = "\x1b[H hello";
    try testing.expectEqualStrings(snap, historyToPaint(snap, 4096).?);
}

test "historyToPaint: no snapshot means nothing to bring back" {
    try testing.expect(historyToPaint(null, 4096) == null);
}

test "historyToPaint: an empty snapshot is not painted" {
    try testing.expect(historyToPaint("", 4096) == null);
}

test "historyToPaint: a snapshot at offset 0 is not painted" {
    try testing.expect(historyToPaint("\x1b[H hello", 0) == null);
}

test "alt_screen_exit leaves every alt-screen spelling" {
    try testing.expect(std.mem.indexOf(u8, alt_screen_exit, "\x1b[?1049l") != null);
    try testing.expect(std.mem.indexOf(u8, alt_screen_exit, "\x1b[?1047l") != null);
    try testing.expect(std.mem.indexOf(u8, alt_screen_exit, "\x1b[?47l") != null);
}

test "alt_screen_exit does not home the cursor or erase the display" {
    // The whole point of gating it on the live mode is that it may not touch the
    // primary screen's rows. Anything that homes (CUP) or erases (ED) here would
    // do exactly that on the way back.
    try testing.expect(std.mem.indexOf(u8, alt_screen_exit, "H") == null);
    try testing.expect(std.mem.indexOf(u8, alt_screen_exit, "J") == null);
}

/// Replay `bytes` into `t` the way the restore path does.
fn feedAll(t: *terminal.Terminal, bytes: []const u8) void {
    var s: terminal.TerminalStream = .initAlloc(testing.allocator, .init(t));
    defer s.deinit();
    s.nextSlice(bytes);
}

/// A full-screen app's stream at `rows` rows: a primary line, the alt screen,
/// an overdrawn first frame, then the last frame — a top line and a bottom
/// status line placed with absolute cursor motion.
fn tuiStream(buf: []u8, rows: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "BEFORE-TUI $ claude\r\n" ++
        "\x1b[?1049h\x1b[H\x1b[2JFRAME-1 overdrawn" ++
        "\x1b[H\x1b[2J\x1b[1;1HFINAL last frame\x1b[{d};1H\x1b[31mstatus line\x1b[{d};3H", .{ rows, rows - 1 });
}

test "altHistory: a primary-screen snapshot is left alone" {
    try testing.expect(try altHistory(testing.allocator, "hello\r\nworld", 80, 24) == null);
}

test "altHistory: a TUI's primary line and last frame, as plain rows in order" {
    var buf: [256]u8 = undefined;
    const snap = try tuiStream(&buf, 30);
    const hist = (try altHistory(testing.allocator, snap, 80, 30)).?;
    defer testing.allocator.free(hist);

    // Content only: no mode sets, no cursor addressing, so painting it cannot
    // put the restored pane on the alternate screen or move rows around.
    try testing.expect(std.mem.indexOf(u8, hist, "\x1b[?") == null);
    try testing.expect(std.mem.indexOf(u8, hist, "H") == null);
    try testing.expect(std.mem.endsWith(u8, hist, "\x1b[0m"));

    const before = std.mem.indexOf(u8, hist, "BEFORE-TUI").?;
    const final = std.mem.indexOf(u8, hist, "FINAL last frame").?;
    const status = std.mem.indexOf(u8, hist, "status line").?;
    try testing.expect(before < final and final < status);
    // Only the LAST frame is history.
    try testing.expect(std.mem.indexOf(u8, hist, "FRAME-1") == null);
}

test "altHistory: the whole frame survives painting into a pane SMALLER than the one it was drawn in" {
    // The T1819 failure shape: a 30-row frame restored into a pane still at its
    // 17-row placeholder. Painting the snapshot there scrolled the frame's top
    // line off an alternate screen that has no scrollback to keep it.
    var buf: [256]u8 = undefined;
    const snap = try tuiStream(&buf, 30);

    var small: terminal.Terminal = try .init(testing.allocator, .{ .cols = 49, .rows = 17 });
    defer small.deinit(testing.allocator);

    const hist = (try altHistory(testing.allocator, snap, small.cols, small.rows)).?;
    defer testing.allocator.free(hist);
    feedAll(&small, hist);
    try testing.expect(small.screens.active_key == .primary);

    const all = try small.screens.active.dumpStringAlloc(testing.allocator, .{ .screen = .{} });
    defer testing.allocator.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "BEFORE-TUI") != null);
    try testing.expect(std.mem.indexOf(u8, all, "FINAL last frame") != null);
    try testing.expect(std.mem.indexOf(u8, all, "status line") != null);
}

test "altHistory: a TUI over a blank primary starts with its frame" {
    const hist = (try altHistory(testing.allocator, "\x1b[?1049h\x1b[HONLY-FRAME", 80, 24)).?;
    defer testing.allocator.free(hist);
    try testing.expect(std.mem.startsWith(u8, hist, "ONLY-FRAME"));
}
