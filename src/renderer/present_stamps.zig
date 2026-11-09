//! Per-window clock of a composition pane's renderer-thread work (T2845).
//!
//! A fold glide's slowest frame is one `EndDeferWindowPos` of 20-48 ms that
//! the window thread spends inside the OS, and the suspect is a pane window
//! whose composition target still has a present, a buffer resize or a commit
//! in flight on the renderer thread when the batch moves it. To name the pane
//! (a stamp, not an elimination) the window thread has to see, at the moment
//! it moves a window, what that window's renderer was doing. This table is
//! that view: the renderer thread stamps the start and end of each
//! `Present`, `ResizeBuffers` and band commit against the pane's window, and
//! the window thread reads the stamps back by window handle.
//!
//! It is written only while `GHOZTTY_PANE_MOVE_TRACE` is set (`on()`), so the
//! default path pays one cached bool per present. Lock-free: every field is an
//! atomic, a slot is claimed by compare-and-swap on its window handle, and a
//! reader that races a writer sees one stamp's begin without its end, which
//! reads as "in flight" - the very thing being looked for, and harmless for a
//! trace.
const std = @import("std");
const builtin = @import("builtin");

/// Which renderer-thread call a stamp is for.
pub const Kind = enum(u2) { present, resize, commit };

/// One call's clock: QPC ticks at its start and end. `end < begin` means the
/// call is still running.
pub const Span = struct {
    begin: i64 = 0,
    end: i64 = 0,

    pub fn inFlight(self: Span) bool {
        return self.begin != 0 and self.end < self.begin;
    }
};

/// What a reader gets for one window: the latest span of each kind.
pub const Snapshot = struct {
    present: Span = .{},
    resize: Span = .{},
    commit: Span = .{},
    presents: u64 = 0,

    /// Whether anything on the window's renderer was mid-call at `now`.
    pub fn busy(self: Snapshot) bool {
        return self.present.inFlight() or self.resize.inFlight() or self.commit.inFlight();
    }
};

const AtomicSpan = struct {
    begin: std.atomic.Value(i64) = .init(0),
    end: std.atomic.Value(i64) = .init(0),

    fn load(self: *const AtomicSpan) Span {
        // End first: a begin stamped after it reads as in flight, never as a
        // finished call with a stale end.
        const e = self.end.load(.acquire);
        const b = self.begin.load(.acquire);
        return .{ .begin = b, .end = e };
    }
};

const Slot = struct {
    key: std.atomic.Value(usize) = .init(0),
    spans: [3]AtomicSpan = .{ .{}, .{}, .{} },
    presents: std.atomic.Value(u64) = .init(0),
};

/// A fixed table of `n` window slots. Generic so a test can use a small one.
pub fn Table(comptime n: usize) type {
    return struct {
        const Self = @This();
        slots: [n]Slot = [_]Slot{.{}} ** n,

        fn find(self: *Self, key: usize, claim: bool) ?*Slot {
            if (key == 0) return null;
            const start = std.hash.Wyhash.hash(0, std.mem.asBytes(&key)) % n;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const s = &self.slots[(start + i) % n];
                const k = s.key.load(.acquire);
                if (k == key) return s;
                if (k == 0) {
                    if (!claim) return null;
                    if (s.key.cmpxchgStrong(0, key, .acq_rel, .acquire)) |other| {
                        if (other == key) return s;
                        continue;
                    }
                    return s;
                }
            }
            return null;
        }

        pub fn begin(self: *Self, key: usize, kind: Kind, qpc: i64) void {
            const s = self.find(key, true) orelse return;
            s.spans[@intFromEnum(kind)].begin.store(qpc, .release);
        }

        pub fn end(self: *Self, key: usize, kind: Kind, qpc: i64) void {
            const s = self.find(key, true) orelse return;
            s.spans[@intFromEnum(kind)].end.store(qpc, .release);
            if (kind == .present) _ = s.presents.fetchAdd(1, .monotonic);
        }

        pub fn read(self: *Self, key: usize) ?Snapshot {
            const s = self.find(key, false) orelse return null;
            return .{
                .present = s.spans[0].load(),
                .resize = s.spans[1].load(),
                .commit = s.spans[2].load(),
                .presents = s.presents.load(.monotonic),
            };
        }

        /// Give a window's slot back (pane closed). Its handle may be reused.
        pub fn forget(self: *Self, key: usize) void {
            const s = self.find(key, false) orelse return;
            for (&s.spans) |*sp| {
                sp.begin.store(0, .release);
                sp.end.store(0, .release);
            }
            s.presents.store(0, .monotonic);
            // The slot stays claimed by this handle: freeing it would break
            // the probe chain of any key placed past it. 64 slots outlive any
            // probe run's pane count.
        }
    };
}

/// The process-wide table. 64 windows is far beyond any glide probe.
pub var table: Table(64) = .{};

var trace_on: ?bool = null;

/// `GHOZTTY_PANE_MOVE_TRACE=1`: stamp and report. Read once.
pub fn on() bool {
    if (trace_on) |v| return v;
    const v = if (comptime builtin.os.tag != .windows) false else std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PANE_MOVE_TRACE");
    trace_on = v;
    return v;
}

pub fn now() i64 {
    if (comptime builtin.os.tag != .windows) return 0;
    return @intCast(std.os.windows.QueryPerformanceCounter());
}

/// Stamp the start of `kind` for `hwnd` when tracing. Returns whether it did,
/// so the matching `stampEnd` can be skipped without re-reading the knob.
pub fn stampBegin(hwnd: ?*anyopaque, kind: Kind) bool {
    if (!on()) return false;
    table.begin(@intFromPtr(hwnd), kind, now());
    return true;
}

pub fn stampEnd(hwnd: ?*anyopaque, kind: Kind) void {
    table.end(@intFromPtr(hwnd), kind, now());
}

test "a span is in flight between begin and end" {
    var t: Table(4) = .{};
    try std.testing.expect(t.read(0x10) == null);
    t.begin(0x10, .present, 100);
    var s = t.read(0x10).?;
    try std.testing.expect(s.present.inFlight());
    try std.testing.expect(s.busy());
    t.end(0x10, .present, 150);
    s = t.read(0x10).?;
    try std.testing.expect(!s.present.inFlight());
    try std.testing.expect(!s.busy());
    try std.testing.expectEqual(@as(u64, 1), s.presents);
    try std.testing.expectEqual(@as(i64, 150), s.present.end);
}

test "kinds are independent and keys do not collide" {
    var t: Table(4) = .{};
    t.begin(0x10, .resize, 5);
    t.begin(0x20, .commit, 7);
    t.end(0x20, .commit, 9);
    const a = t.read(0x10).?;
    const b = t.read(0x20).?;
    try std.testing.expect(a.resize.inFlight());
    try std.testing.expect(!a.commit.inFlight());
    try std.testing.expect(!b.busy());
    try std.testing.expectEqual(@as(i64, 9), b.commit.end);
}

test "a full table drops new windows rather than overwriting" {
    var t: Table(2) = .{};
    t.begin(1, .present, 1);
    t.begin(2, .present, 2);
    t.begin(3, .present, 3);
    try std.testing.expect(t.read(3) == null);
    try std.testing.expectEqual(@as(i64, 1), t.read(1).?.present.begin);
    try std.testing.expectEqual(@as(i64, 2), t.read(2).?.present.begin);
}

test "forget clears a window's clock and keeps later keys reachable" {
    var t: Table(2) = .{};
    t.begin(1, .present, 1);
    t.end(1, .present, 2);
    t.begin(2, .resize, 3);
    t.forget(1);
    const s = t.read(1).?;
    try std.testing.expectEqual(@as(u64, 0), s.presents);
    try std.testing.expect(!s.busy());
    try std.testing.expect(t.read(2).?.resize.inFlight());
}

test "a null handle is never stamped" {
    var t: Table(2) = .{};
    t.begin(0, .present, 1);
    try std.testing.expect(t.read(0) == null);
}
