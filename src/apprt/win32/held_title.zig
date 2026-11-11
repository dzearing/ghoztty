//! Pure logic for holding a hidden window's title (T2912, port of Mac
//! 68a8344f0 `BaseTerminalController.pendingWindowTitle`). No OS imports, so
//! its unit tests run in every app-runtime lane.
//!
//! Setting a top-level window's text is a caption repaint plus the
//! accessibility and taskbar notifications that follow it, and an agent that
//! spins a glyph in its title asks for that ten times a second in every
//! window. Nobody can see a covered or minimized window's caption, so its
//! title is HELD: it lands the moment the window shows, or after
//! `interval_ms` at most, so the taskbar, Alt-Tab and screen readers are never
//! far behind. A window's first title always lands. Readers that bypass the
//! screen (`+list`, copy-title) read `current` and see the held title at once.
//!
//! The tab labels follow the same rule: the strip is part of the hidden
//! window, so its repaint is owed (`tab_bar_owed`) and paid on landing, while
//! the label text itself (`Window.tab_titles`) stays current for `+list`.

const std = @import("std");

/// How long a title waits while nobody can see the window. Mac's
/// `hiddenWindowTitleInterval`.
pub const interval_ms: u32 = 5000;

/// Capacity, in UTF-16 units, of a composed window title (bell prefix + 256
/// units of title + activity suffix + debug marker), with room for the NUL.
pub const capacity: usize = 288;

pub const Decision = enum {
    /// Set the window text now.
    apply,
    /// Keep it in `Held` until the window shows or the interval runs out.
    hold,
};

/// Whether a freshly composed title lands now. `hidden` is "nobody can see
/// this window" (covered, cloaked, minimized, session locked);
/// `landed_once` is whether any title has been set on it yet.
pub fn decide(hidden: bool, landed_once: bool) Decision {
    if (!landed_once) return .apply;
    return if (hidden) .hold else .apply;
}

pub const Held = struct {
    buf: [capacity]u16 = undefined,
    len: usize = 0,
    /// A title is waiting to land.
    pending: bool = false,
    /// The interval timer is running (armed by the first hold, so a title
    /// that changes every 100ms still lands every `interval_ms`, rather than
    /// being pushed back forever by each change).
    armed: bool = false,
    /// A tab label changed while hidden; the strip repaints when it lands.
    tab_bar_owed: bool = false,

    /// Hold `title`, replacing any earlier held one. Returns true when the
    /// caller must arm the interval timer (the first hold since the last
    /// landing).
    pub fn hold(self: *Held, title: []const u16) bool {
        const n = @min(title.len, capacity - 1);
        @memcpy(self.buf[0..n], title[0..n]);
        self.buf[n] = 0;
        self.len = n;
        self.pending = true;
        if (self.armed) return false;
        self.armed = true;
        return true;
    }

    /// A tab label changed while the window was hidden.
    pub fn oweTabBar(self: *Held) bool {
        const first = !self.armed;
        self.tab_bar_owed = true;
        if (first) self.armed = true;
        return first;
    }

    pub const Landing = struct {
        /// The NUL-terminated title to set, or null when none was held.
        title: ?[:0]const u16,
        /// The tab strip must repaint.
        tab_bar: bool,
        /// The caller must kill the interval timer.
        disarm: bool,
    };

    /// Everything owed, cleared. The returned title slice points into
    /// `self` and is valid until the next `hold`.
    pub fn take(self: *Held) Landing {
        const out: Landing = .{
            .title = if (self.pending) self.buf[0..self.len :0] else null,
            .tab_bar = self.tab_bar_owed,
            .disarm = self.armed,
        };
        self.pending = false;
        self.tab_bar_owed = false;
        self.armed = false;
        return out;
    }

    /// The window's title as of now: the held one if any, else `shown` (what
    /// the window text says).
    pub fn current(self: *const Held, shown: []const u16) []const u16 {
        return if (self.pending) self.buf[0..self.len] else shown;
    }
};

const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "decide: a window's first title always lands" {
    try std.testing.expectEqual(Decision.apply, decide(true, false));
    try std.testing.expectEqual(Decision.apply, decide(false, false));
}

test "decide: a hidden window holds, a seen one applies" {
    try std.testing.expectEqual(Decision.hold, decide(true, true));
    try std.testing.expectEqual(Decision.apply, decide(false, true));
}

test "hold: only the first hold arms the timer, the newest title wins" {
    var h: Held = .{};
    try std.testing.expect(h.hold(L("a")));
    try std.testing.expect(!h.hold(L("b")));
    try std.testing.expect(!h.hold(L("c")));
    try std.testing.expectEqualSlices(u16, L("c"), h.current(L("shown")));
}

test "current: no held title reads the shown one" {
    var h: Held = .{};
    try std.testing.expectEqualSlices(u16, L("shown"), h.current(L("shown")));
}

test "take: lands the newest title once, disarms, and clears" {
    var h: Held = .{};
    _ = h.hold(L("one"));
    _ = h.hold(L("two"));
    const got = h.take();
    try std.testing.expectEqualSlices(u16, L("two"), got.title.?);
    try std.testing.expectEqual(@as(u16, 0), got.title.?.ptr[got.title.?.len]);
    try std.testing.expect(got.disarm);
    try std.testing.expect(!got.tab_bar);
    const again = h.take();
    try std.testing.expect(again.title == null);
    try std.testing.expect(!again.disarm);
    // The next hold arms again: a window still hidden lands every interval.
    try std.testing.expect(h.hold(L("three")));
}

test "oweTabBar: arms once, shares the timer with a held title" {
    var h: Held = .{};
    try std.testing.expect(h.oweTabBar());
    try std.testing.expect(!h.hold(L("t")));
    try std.testing.expect(!h.oweTabBar());
    const got = h.take();
    try std.testing.expect(got.tab_bar);
    try std.testing.expect(got.title != null);
}

test "take: a seen window's direct title pays what was owed first" {
    // The apply path takes before it sets: the held title is dropped (the
    // new one replaces it) and the owed strip repaint is paid.
    var h: Held = .{};
    _ = h.hold(L("old"));
    _ = h.oweTabBar();
    const got = h.take();
    try std.testing.expect(got.disarm and got.tab_bar);
    try std.testing.expectEqualSlices(u16, L("now"), h.current(L("now")));
}

test "hold: an over-long title is truncated, never overflows" {
    var h: Held = .{};
    var long: [capacity + 40]u16 = undefined;
    @memset(&long, 'x');
    _ = h.hold(&long);
    try std.testing.expectEqual(capacity - 1, h.current(&.{}).len);
}
