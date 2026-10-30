//! How often a terminal title change reaches the app thread (T2428).
//!
//! cmd.exe titles its console with every command it runs, and ConPTY hands
//! each line over as its own read, so a `for /L ... do @echo` loop sets a new
//! title per output line: ~13,000 a second, every one a set_title message and
//! a GUI-thread wakeup queued ahead of the user's mouse input. Nobody can read
//! a title that changes faster than the screen does, so the newest one is held
//! and sent at most once per `interval_ns`: the first change in a burst goes at
//! once, the rest wait for the interval, and a timer sends the last one when
//! the output stops - so the title always ends on the one the program set
//! last.
//!
//! Pure bookkeeping on injected clocks; the stream handler holds the title
//! and the termio thread owns the timer.

const std = @import("std");

/// One frame at 60 Hz: as fast as a title can visibly change.
pub const interval_ns: u64 = 16 * std.time.ns_per_ms;

pub const Pace = struct {
    /// When a title was last sent, if one has been.
    last_sent_ns: ?u64 = null,

    /// The trailing-send timer is armed and will call `due`.
    timer_armed: bool = false,

    pub const Verdict = union(enum) {
        /// Send the held title now.
        send,
        /// Hold it, and arm the timer to fire in this many ns.
        arm: u64,
        /// Hold it; the armed timer will send it.
        hold,
    };

    /// A chunk of output has been parsed and left a title held.
    pub fn held(self: *Pace, now_ns: u64) Verdict {
        if (self.timer_armed) return .hold;
        if (self.last_sent_ns) |last| {
            const since = now_ns -| last;
            if (since < interval_ns) {
                self.timer_armed = true;
                return .{ .arm = interval_ns - since };
            }
        }
        self.last_sent_ns = now_ns;
        return .send;
    }

    /// The held title went out some other way (ahead of another surface
    /// message, which has to keep its order behind it).
    pub fn sent(self: *Pace, now_ns: u64) void {
        self.last_sent_ns = now_ns;
    }

    /// The trailing timer fired. Whatever is held is sent now.
    pub fn due(self: *Pace, now_ns: u64) void {
        self.timer_armed = false;
        self.last_sent_ns = now_ns;
    }
};

const ms = std.time.ns_per_ms;

test "the first title in a burst is sent at once" {
    var p: Pace = .{};
    try std.testing.expectEqual(Pace.Verdict.send, p.held(1000 * ms));
}

test "a title inside the interval waits for the timer, and one timer covers the burst" {
    var p: Pace = .{};
    _ = p.held(1000 * ms);
    try std.testing.expectEqual(Pace.Verdict{ .arm = 12 * ms }, p.held(1004 * ms));
    try std.testing.expectEqual(Pace.Verdict.hold, p.held(1005 * ms));
    try std.testing.expectEqual(Pace.Verdict.hold, p.held(1030 * ms));
    p.due(1016 * ms);
    // Right after the timer's send, the next change waits again.
    try std.testing.expectEqual(Pace.Verdict{ .arm = 15 * ms }, p.held(1017 * ms));
}

test "a title after a quiet interval is sent at once" {
    var p: Pace = .{};
    _ = p.held(1000 * ms);
    try std.testing.expectEqual(Pace.Verdict.send, p.held(1016 * ms));
    try std.testing.expectEqual(Pace.Verdict.send, p.held(5000 * ms));
}

test "a flood sends about one title per interval" {
    var p: Pace = .{};
    var sends: u32 = 0;
    var timer_at: ?u64 = null;
    // 13 titles a millisecond for one second, the way the cmd loop sets them.
    var t: u64 = 0;
    while (t < 1000 * ms) : (t += ms / 13) {
        if (timer_at) |at| if (t >= at) {
            p.due(t);
            sends += 1;
            timer_at = null;
        };
        switch (p.held(t)) {
            .send => sends += 1,
            .arm => |ns| timer_at = t + ns,
            .hold => {},
        }
    }
    try std.testing.expect(sends >= 55 and sends <= 70);
}

test "a send ahead of another message restarts the interval" {
    var p: Pace = .{};
    p.sent(1000 * ms);
    try std.testing.expectEqual(Pace.Verdict{ .arm = 10 * ms }, p.held(1006 * ms));
}
