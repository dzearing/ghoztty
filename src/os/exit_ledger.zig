//! The exit ledger's TEXT FORMAT (T1686) - pure, so it is tested everywhere.
//!
//! The ledger itself is a Windows thing (`apprt/win32/exit_reason.zig` owns
//! the file handle, the crash filter and the process-liveness check), but the
//! part that decides what a line SAYS and what a file MEANS is plain text
//! handling with no operating system in it. It lives here so its unit tests
//! run in the `none` lane on every platform rather than only in the win32
//! lane on this box - the same reason `os/log_stamp.zig` is not inside the
//! apprt either.
//!
//! One line per event, plain ASCII, append-only:
//!
//! ```
//! 2026-09-20T17:04:15.455Z pid=25964 event=start build=1.36.12 mode=ReleaseFast
//! 2026-09-20T17:29:51.725Z pid=25964 event=crash code=0xC0000005 addr=0x7ffb1234abcd
//! 2026-09-20T17:40:02.001Z pid=31276 event=unrecorded-exit prev_pid=25964 prev_start=2026-09-20T17:04:15.455Z
//! ```
//!
//! Text rather than JSON because the crash path writes from an exception
//! filter, where allocating or re-entering the allocator is how a diagnostic
//! becomes a second crash. Every function below composes into a caller's
//! buffer and allocates nothing.

const std = @import("std");

/// What happened. The wire spelling is the enum name with `_` as `-`, so a
/// human greps the file for the word they would say out loud.
pub const Event = enum {
    /// A GUI app process started and is now responsible for closing its entry.
    start,
    /// It ended deliberately, and `detail` names why.
    exit,
    /// An unhandled exception reached our filter; `detail` carries the code.
    crash,
    /// A LATER run found a `start` with no terminal record and no live
    /// process behind it. The only witness the outside-kill case can have.
    @"unrecorded-exit",
};

/// One ledger line, with every field borrowed from the text it was parsed
/// from - nothing here owns memory, so an audit over a whole file allocates
/// exactly once (for the file).
pub const Record = struct {
    ts: []const u8,
    pid: u32,
    event: Event,
    /// Everything after the event token, verbatim: `reason=user-quit`,
    /// `code=0xC0000005 addr=…`. Empty when the event carries no detail.
    detail: []const u8,
};

/// Longest line this module ever composes. A timestamp, a pid, an event name
/// and a detail tail; the crash path's stack buffer is sized from it.
pub const max_line = 256;

/// Render `r` into `buf` as one ledger line, newline included.
///
/// Truncating rather than failing is deliberate: a diagnostic that refuses to
/// write because the detail was long is worse than a short one, and the crash
/// path has nowhere to report a failure to anyway.
pub fn formatLine(buf: []u8, r: Record) []const u8 {
    const head = std.fmt.bufPrint(buf, "{s} pid={d} event={s}", .{
        r.ts,
        r.pid,
        @tagName(r.event),
    }) catch return buf[0..0];
    var n = head.len;
    if (r.detail.len > 0 and n + 1 < buf.len) {
        buf[n] = ' ';
        n += 1;
        const room = @min(r.detail.len, buf.len - n - 1);
        @memcpy(buf[n..][0..room], r.detail[0..room]);
        n += room;
    }
    if (n < buf.len) {
        buf[n] = '\n';
        n += 1;
    }
    return buf[0..n];
}

/// Parse one ledger line, or null if it is not one.
///
/// Unknown event names return null rather than erroring: a newer build may
/// write an event this one has never heard of into the same shared file, and
/// an older build reading it must skip the line, not refuse the ledger.
pub fn parseLine(line: []const u8) ?Record {
    const clean = std.mem.trim(u8, line, " \t\r\n");
    if (clean.len == 0) return null;

    var it = std.mem.tokenizeScalar(u8, clean, ' ');
    const ts = it.next() orelse return null;
    const pid_tok = it.next() orelse return null;
    const event_tok = it.next() orelse return null;

    if (!std.mem.startsWith(u8, pid_tok, "pid=")) return null;
    if (!std.mem.startsWith(u8, event_tok, "event=")) return null;

    const pid = std.fmt.parseInt(u32, pid_tok["pid=".len..], 10) catch return null;
    const event = std.meta.stringToEnum(Event, event_tok["event=".len..]) orelse return null;

    const rest = it.rest();
    return .{
        .ts = ts,
        .pid = pid,
        .event = event,
        .detail = std.mem.trim(u8, rest, " \t\r\n"),
    };
}

/// A `start` nobody ever closed out.
pub const Dangling = struct {
    pid: u32,
    ts: []const u8,
};

/// Remove every entry for `pid` from `open`, returning the new length.
fn forget(open: []Dangling, pid: u32) usize {
    var n = open.len;
    var i: usize = 0;
    while (i < n) {
        if (open[i].pid == pid) {
            std.mem.copyForwards(Dangling, open[i .. n - 1], open[i + 1 .. n]);
            n -= 1;
            continue;
        }
        i += 1;
    }
    return n;
}

/// The pid an `unrecorded-exit` detail is speaking for (`prev_pid=25964 …`).
fn prevPid(detail: []const u8) ?u32 {
    var it = std.mem.tokenizeScalar(u8, detail, ' ');
    while (it.next()) |tok| {
        if (!std.mem.startsWith(u8, tok, "prev_pid=")) continue;
        return std.fmt.parseInt(u32, tok["prev_pid=".len..], 10) catch return null;
    }
    return null;
}

/// Every `start` in `text` with no later terminal record for the same pid,
/// written into `out` newest-last; returns the slice actually filled.
///
/// `self_pid` is skipped, because the caller's own `start` is by definition
/// still open. A pid that appears twice (Windows reuses them freely over
/// weeks) keeps only its LATEST start - an old closed run must not resurrect
/// as dangling because a much later process happened to get the same number.
///
/// Liveness is NOT decided here: this is pure so it can be tested without a
/// process table, and the caller filters the survivors against one.
pub fn danglingStarts(text: []const u8, self_pid: u32, out: []Dangling) []Dangling {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const r = parseLine(line) orelse continue;

        // An `unrecorded-exit` is a LATER run speaking for an earlier one, so
        // the pid it closes is the one named in its detail, not its own. It
        // has to close that entry or the report is permanent: the run it
        // names is dead, its `start` stays open forever, and every launch
        // from then on re-announces the same vanished process. Measured on
        // the first run of this module - three consecutive launches all
        // accused the same pid.
        if (r.event == .@"unrecorded-exit") {
            if (prevPid(r.detail)) |dead| n = forget(out[0..n], dead);
            continue;
        }

        if (r.pid == self_pid) continue;

        // Drop any earlier entry for this pid, whatever this record is: a
        // second `start` supersedes the first, and a terminal record closes
        // whatever was open.
        n = forget(out[0..n], r.pid);

        if (r.event != .start) continue;
        if (n == out.len) {
            // Full: forget the oldest rather than the newest. A ledger with
            // more open runs than the caller's buffer is already pathological
            // and the recent ones are the ones worth naming.
            if (out.len == 0) continue;
            std.mem.copyForwards(Dangling, out[0 .. out.len - 1], out[1..]);
            n -= 1;
        }
        out[n] = .{ .pid = r.pid, .ts = r.ts };
        n += 1;
    }
    return out[0..n];
}

/// Keep only the last `keep` lines of `text`, returning the slice to rewrite.
///
/// The ledger is append-only and shared, so nothing trims it as it goes; a
/// launch does it, where there is an allocator and no hurry. Returns `text`
/// unchanged when it is already short enough, so the common path writes
/// nothing.
pub fn trimmed(text: []const u8, keep: usize) []const u8 {
    if (keep == 0) return text[text.len..];
    var count: usize = 0;
    var i = text.len;
    while (i > 0) {
        i -= 1;
        if (text[i] != '\n') continue;
        // A trailing newline ends the last line rather than starting a new one.
        if (i + 1 == text.len) continue;
        count += 1;
        if (count == keep) return text[i + 1 ..];
    }
    return text;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "formatLine round-trips through parseLine" {
    const testing = std.testing;
    var buf: [max_line]u8 = undefined;
    const line = formatLine(&buf, .{
        .ts = "2026-09-20T17:29:51.725Z",
        .pid = 25964,
        .event = .crash,
        .detail = "code=0xC0000005 addr=0x7FFB1234",
    });
    try testing.expectEqualStrings(
        "2026-09-20T17:29:51.725Z pid=25964 event=crash code=0xC0000005 addr=0x7FFB1234\n",
        line,
    );

    const r = parseLine(line).?;
    try testing.expectEqualStrings("2026-09-20T17:29:51.725Z", r.ts);
    try testing.expectEqual(@as(u32, 25964), r.pid);
    try testing.expectEqual(Event.crash, r.event);
    try testing.expectEqualStrings("code=0xC0000005 addr=0x7FFB1234", r.detail);
}

test "formatLine with no detail still ends in a newline" {
    const testing = std.testing;
    var buf: [max_line]u8 = undefined;
    const line = formatLine(&buf, .{
        .ts = "2026-09-20T17:29:51.725Z",
        .pid = 7,
        .event = .start,
        .detail = "",
    });
    try testing.expectEqualStrings("2026-09-20T17:29:51.725Z pid=7 event=start\n", line);
    try testing.expectEqual(Event.start, parseLine(line).?.event);
}

test "parseLine rejects junk and unknown events" {
    const testing = std.testing;
    try testing.expect(parseLine("") == null);
    try testing.expect(parseLine("   \n") == null);
    try testing.expect(parseLine("hello world") == null);
    try testing.expect(parseLine("ts pid=abc event=start") == null);
    // An event a NEWER build wrote into the shared file: skipped, not fatal.
    try testing.expect(parseLine("ts pid=1 event=teleported") == null);
}

test "danglingStarts reports an unclosed run and forgets a closed one" {
    const testing = std.testing;
    const text =
        \\2026-09-20T10:00:00.000Z pid=100 event=start build=x mode=ReleaseFast
        \\2026-09-20T10:05:00.000Z pid=100 event=exit reason=user-quit
        \\2026-09-20T11:00:00.000Z pid=200 event=start build=x mode=ReleaseFast
        \\
    ;
    var slots: [8]Dangling = undefined;
    const open = danglingStarts(text, 999, &slots);
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqual(@as(u32, 200), open[0].pid);
    try testing.expectEqualStrings("2026-09-20T11:00:00.000Z", open[0].ts);
}

test "danglingStarts treats a crash as a closed run" {
    const testing = std.testing;
    const text =
        \\2026-09-20T11:00:00.000Z pid=200 event=start build=x mode=ReleaseFast
        \\2026-09-20T11:01:00.000Z pid=200 event=crash code=0xC0000005 addr=0x1
        \\
    ;
    var slots: [8]Dangling = undefined;
    try testing.expectEqual(@as(usize, 0), danglingStarts(text, 999, &slots).len);
}

test "danglingStarts: a run already reported is not reported again" {
    const testing = std.testing;
    // pid 200 was killed; pid 300 spoke for it. pid 400 launching later must
    // stay quiet - otherwise every launch from now until the ledger is
    // trimmed re-announces the same vanished process.
    const text =
        \\2026-09-20T11:00:00.000Z pid=200 event=start build=x mode=ReleaseFast
        \\2026-09-20T11:05:00.000Z pid=300 event=start build=x mode=ReleaseFast
        \\2026-09-20T11:05:00.000Z pid=300 event=unrecorded-exit prev_pid=200 prev_start=2026-09-20T11:00:00.000Z
        \\2026-09-20T11:06:00.000Z pid=300 event=exit reason=user-quit
        \\
    ;
    var slots: [8]Dangling = undefined;
    try testing.expectEqual(@as(usize, 0), danglingStarts(text, 400, &slots).len);
}

test "danglingStarts: an unrecorded-exit does not close its OWN entry" {
    const testing = std.testing;
    // pid 300 reported pid 200 and then vanished itself. Its own start is
    // still open and the next launch must say so.
    const text =
        \\2026-09-20T11:00:00.000Z pid=200 event=start build=x mode=ReleaseFast
        \\2026-09-20T11:05:00.000Z pid=300 event=start build=x mode=ReleaseFast
        \\2026-09-20T11:05:00.000Z pid=300 event=unrecorded-exit prev_pid=200 prev_start=2026-09-20T11:00:00.000Z
        \\
    ;
    var slots: [8]Dangling = undefined;
    const open = danglingStarts(text, 400, &slots);
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqual(@as(u32, 300), open[0].pid);
}

test "danglingStarts skips our own pid" {
    const testing = std.testing;
    const text = "2026-09-20T11:00:00.000Z pid=200 event=start build=x mode=Debug\n";
    var slots: [8]Dangling = undefined;
    try testing.expectEqual(@as(usize, 0), danglingStarts(text, 200, &slots).len);
}

test "danglingStarts: a reused pid keeps only its latest run" {
    const testing = std.testing;
    // pid 100 ran and quit cleanly in June; Windows handed the same number
    // out again in September and THAT run never closed. Only the September
    // one is open, and the June exit must not close it.
    const text =
        \\2026-06-01T10:00:00.000Z pid=100 event=start build=x mode=ReleaseFast
        \\2026-06-01T10:05:00.000Z pid=100 event=exit reason=user-quit
        \\2026-09-20T11:00:00.000Z pid=100 event=start build=x mode=ReleaseFast
        \\
    ;
    var slots: [8]Dangling = undefined;
    const open = danglingStarts(text, 999, &slots);
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqualStrings("2026-09-20T11:00:00.000Z", open[0].ts);
}

test "danglingStarts keeps the newest when it runs out of slots" {
    const testing = std.testing;
    const text =
        \\t pid=1 event=start
        \\t pid=2 event=start
        \\t pid=3 event=start
        \\
    ;
    var slots: [2]Dangling = undefined;
    const open = danglingStarts(text, 999, &slots);
    try testing.expectEqual(@as(usize, 2), open.len);
    try testing.expectEqual(@as(u32, 2), open[0].pid);
    try testing.expectEqual(@as(u32, 3), open[1].pid);
}

test "trimmed keeps the last N lines and leaves a short file alone" {
    const testing = std.testing;
    const text = "a\nb\nc\nd\n";
    try testing.expectEqualStrings("c\nd\n", trimmed(text, 2));
    try testing.expectEqualStrings(text, trimmed(text, 4));
    try testing.expectEqualStrings(text, trimmed(text, 99));
    try testing.expectEqualStrings("", trimmed(text, 0));
}

test "trimmed handles a file with no trailing newline" {
    const testing = std.testing;
    try testing.expectEqualStrings("c\nd", trimmed("a\nb\nc\nd", 2));
}
