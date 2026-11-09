//! `GHOZTTY_PANE_MOVE_TRACE=1` (T2845): name the pane whose move stalls a
//! fold glide's pane batch, instead of inferring it by elimination.
//!
//! A live layout pass normally moves every pane in one `DeferWindowPos`
//! batch, and the 20-48 ms stall lands in that batch's `EndDeferWindowPos`
//! with no way to say which window it was. Under this knob the pass moves
//! each pane in a batch of its own (`Window.tracedMove`), times it, takes the
//! pane's own WM_SIZE work back out (`Window.batch_cost`), and reads what the
//! pane's renderer thread was doing at that moment from
//! `renderer/present_stamps.zig`: a `Present`, a `ResizeBuffers` or a band
//! commit in flight on that very window, or on some other pane's.
//!
//! What it prints: one `pane move slow` line per move whose OS time is over
//! `slow_us`, and the running contrast the attribution rests on - how often a
//! move found its own renderer busy among the slow moves and among the fast
//! ones. A stamp that names the mechanism shows up as a busy share near 1 on
//! the slow side and near the base rate on the fast side.
const std = @import("std");
const present_stamps = @import("../../renderer/present_stamps.zig");

const log = std.log.scoped(.win32);

/// A move whose OS time is over this is reported (8 ms: one 120 Hz period).
pub const slow_us: i64 = 8000;

/// QPC ticks per microsecond on Windows 10+ (10 MHz).
const ticks_per_us: i64 = 10;

pub fn on() bool {
    return present_stamps.on();
}

/// One move's measurements, in QPC ticks.
pub const Move = struct {
    begin: i64,
    end: i64,
    /// The pane's own WM_SIZE handling inside the move.
    own: i64,
    /// The pane's renderer clock just before the move, null if never stamped
    /// (a viewer, or a pane on SwapBuffers).
    before: ?present_stamps.Snapshot,
    /// The same, just after: a call that began during the move shows here.
    after: ?present_stamps.Snapshot,
    /// Other windows whose renderer was mid-call when the move began.
    others_busy: u32,
};

pub const Verdict = struct {
    os_us: i64,
    slow: bool,
    /// The pane's renderer was mid-call when the move began.
    busy_at_begin: bool,
    /// A call of the pane's renderer overlapped the move at all: busy at the
    /// begin, or a call that began during it.
    overlapped: bool,
    /// Which call overlapped, the first found in present/resize/commit order.
    kind: ?present_stamps.Kind,
};

fn overlaps(span_before: present_stamps.Span, span_after: present_stamps.Span, begin: i64, end: i64) bool {
    if (span_before.inFlight()) return true;
    // Begun during the move (whatever its end).
    return span_after.begin > begin and span_after.begin < end;
}

pub fn judge(m: Move) Verdict {
    const os = @max(0, (m.end - m.begin) - m.own);
    const os_us = @divTrunc(os, ticks_per_us);
    var v: Verdict = .{ .os_us = os_us, .slow = os_us > slow_us, .busy_at_begin = false, .overlapped = false, .kind = null };
    const b = m.before orelse return v;
    const a = m.after orelse b;
    v.busy_at_begin = b.busy();
    const pairs = [_]struct { present_stamps.Kind, present_stamps.Span, present_stamps.Span }{
        .{ .present, b.present, a.present },
        .{ .resize, b.resize, a.resize },
        .{ .commit, b.commit, a.commit },
    };
    for (pairs) |p| if (overlaps(p[1], p[2], m.begin, m.end)) {
        v.overlapped = true;
        v.kind = p[0];
        break;
    };
    return v;
}

/// The running contrast. UI thread only.
pub const Stats = struct {
    moves: u32 = 0,
    slow: u32 = 0,
    slow_overlapped: u32 = 0,
    fast_overlapped: u32 = 0,
    slow_others_busy: u32 = 0,
    max_os_us: i64 = 0,

    pub fn add(self: *Stats, v: Verdict, others_busy: u32) void {
        self.moves +|= 1;
        self.max_os_us = @max(self.max_os_us, v.os_us);
        if (v.slow) {
            self.slow +|= 1;
            if (v.overlapped) self.slow_overlapped +|= 1;
            if (others_busy > 0) self.slow_others_busy +|= 1;
        } else if (v.overlapped) self.fast_overlapped +|= 1;
    }
};

pub var stats: Stats = .{};

/// Count the windows other than `self_key` whose renderer is mid-call.
pub fn othersBusy(self_key: usize) u32 {
    var n: u32 = 0;
    for (&present_stamps.table.slots) |*s| {
        const k = s.key.load(.acquire);
        if (k == 0 or k == self_key) continue;
        const other = present_stamps.table.read(k) orelse continue;
        if (other.busy()) n += 1;
    }
    return n;
}

/// Judge one move, keep the contrast, and report it when slow.
pub fn record(hwnd: usize, m: Move) void {
    const v = judge(m);
    stats.add(v, m.others_busy);
    if (!v.slow) return;
    const b = m.before orelse present_stamps.Snapshot{};
    const since_present_us = if (b.present.end > 0) @divTrunc(m.begin - b.present.end, ticks_per_us) else -1;
    log.info(
        "pane move slow hwnd={x} os_us={d} own_us={d} stamped={} busy_at_begin={} overlapped={} kind={s} since_present_us={d} others_busy={d} presents={d} | moves={d} slow={d} slow_overlapped={d} fast_overlapped={d} slow_others_busy={d} max_os_us={d}",
        .{
            hwnd,                                   v.os_us,
            @divTrunc(m.own, ticks_per_us),         m.before != null,
            v.busy_at_begin,                        v.overlapped,
            if (v.kind) |k| @tagName(k) else "none", since_present_us,
            m.others_busy,                          b.presents,
            stats.moves,                            stats.slow,
            stats.slow_overlapped,                  stats.fast_overlapped,
            stats.slow_others_busy,                 stats.max_os_us,
        },
    );
}

/// The contrast so far, once per glide end.
pub fn summary() void {
    if (stats.moves == 0) return;
    log.info("pane move trace moves={d} slow={d} slow_overlapped={d} fast_overlapped={d} slow_others_busy={d} max_os_us={d}", .{
        stats.moves, stats.slow, stats.slow_overlapped, stats.fast_overlapped, stats.slow_others_busy, stats.max_os_us,
    });
    stats = .{};
}

const testing = std.testing;

fn snap(present: present_stamps.Span) present_stamps.Snapshot {
    return .{ .present = present };
}

test "the pane's own WM_SIZE is taken out of the move's time" {
    const v = judge(.{ .begin = 0, .end = 100_000, .own = 30_000, .before = null, .after = null, .others_busy = 0 });
    try testing.expectEqual(@as(i64, 7000), v.os_us);
    try testing.expect(!v.slow);
    try testing.expect(!v.overlapped);
}

test "a present in flight at the move's start is an overlap" {
    const busy = snap(.{ .begin = 50, .end = 10 });
    const v = judge(.{ .begin = 100, .end = 300_000, .own = 0, .before = busy, .after = busy, .others_busy = 0 });
    try testing.expect(v.slow);
    try testing.expect(v.busy_at_begin);
    try testing.expect(v.overlapped);
    try testing.expectEqual(present_stamps.Kind.present, v.kind.?);
}

test "a present that began during the move is an overlap, one that ended before is not" {
    const done = snap(.{ .begin = 10, .end = 20 });
    const during = snap(.{ .begin = 200, .end = 20 });
    const v = judge(.{ .begin = 100, .end = 300, .own = 0, .before = done, .after = during, .others_busy = 0 });
    try testing.expect(!v.busy_at_begin);
    try testing.expect(v.overlapped);
    const w = judge(.{ .begin = 100, .end = 300, .own = 0, .before = done, .after = done, .others_busy = 0 });
    try testing.expect(!w.overlapped);
}

test "a resize in flight is named as a resize" {
    const s: present_stamps.Snapshot = .{ .present = .{ .begin = 1, .end = 2 }, .resize = .{ .begin = 5, .end = 1 } };
    const v = judge(.{ .begin = 10, .end = 20, .own = 0, .before = s, .after = s, .others_busy = 0 });
    try testing.expectEqual(present_stamps.Kind.resize, v.kind.?);
}

test "stats keep the slow and fast overlap counts apart" {
    var st: Stats = .{};
    st.add(.{ .os_us = 20_000, .slow = true, .busy_at_begin = true, .overlapped = true, .kind = .present }, 2);
    st.add(.{ .os_us = 100, .slow = false, .busy_at_begin = true, .overlapped = true, .kind = .present }, 0);
    st.add(.{ .os_us = 100, .slow = false, .busy_at_begin = false, .overlapped = false, .kind = null }, 0);
    try testing.expectEqual(@as(u32, 3), st.moves);
    try testing.expectEqual(@as(u32, 1), st.slow);
    try testing.expectEqual(@as(u32, 1), st.slow_overlapped);
    try testing.expectEqual(@as(u32, 1), st.fast_overlapped);
    try testing.expectEqual(@as(u32, 1), st.slow_others_busy);
    try testing.expectEqual(@as(i64, 20_000), st.max_os_us);
}
