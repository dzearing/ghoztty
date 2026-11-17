//! Pure logic for the file watcher's re-render (T3037, audit finding PA-V05).
//! No OS imports, so its unit tests run in every app-runtime lane.
//!
//! A viewer pane re-renders its file every time the watcher reports a save -
//! a whole read, a whole escape into a script, and a whole parse in the page.
//! Two of those renders buy nothing:
//!
//! - **Hidden.** A pane in a minimized or covered window, or a tab nobody is
//!   looking at, renders for nobody. A writer that keeps saving (a log, a
//!   generated report) made that cost unbounded. So a save that lands while
//!   the pane is hidden is remembered, and the pane renders ONCE when it is
//!   shown - the same shape as the `git-status:` poll's `hidden_poll.Gate`.
//! - **Unchanged.** A save that left the file's size and modification time
//!   exactly where the last render saw them (a touch that restored the time,
//!   an editor that rewrote identical bytes with the time preserved, a
//!   notification for metadata alone) cannot have changed what is on screen.
//!
//! The stamp is a heuristic by design: two different writes inside one
//! timestamp tick with the same length would read as one. NTFS keeps time in
//! 100 ns units, so that takes a writer faster than the debounce can see
//! anyway, and `+reload` never consults the stamp.

const std = @import("std");

/// What the last render saw of the file.
pub const Stamp = struct {
    size: u64,
    mtime: i128,

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.size == b.size and a.mtime == b.mtime;
    }
};

pub const Verdict = enum {
    /// Render now.
    render,
    /// The pane is hidden: nothing rendered, one render owed for the show.
    owed,
    /// The file is where the last render saw it: nothing to do.
    unchanged,
};

pub const Gate = struct {
    /// A save landed while hidden: the pane owes one render on show.
    owed: bool = false,
    /// What the pane last rendered. Null means unknown, and unknown renders.
    last: ?Stamp = null,

    /// The debounced save fired. `now` is the file as it stands, or null when
    /// it could not be read - which renders, so the page's error card says so.
    pub fn save(self: *Gate, shown: bool, now: ?Stamp) Verdict {
        if (!shown) {
            self.owed = true;
            return .owed;
        }
        self.owed = false;
        return self.judge(now);
    }

    /// The pane was shown. True means a save landed while it was hidden and
    /// the caller should ask `save(true, ...)` now; the debt is paid either way.
    pub fn reveal(self: *Gate) bool {
        const was = self.owed;
        self.owed = false;
        return was;
    }

    /// The pane rendered the file by some other road (its first load, a
    /// `+reload`): that is what is on screen now.
    pub fn note(self: *Gate, now: ?Stamp) void {
        self.last = now;
    }

    /// The pane is somewhere else now: neither a debt nor a stamp from the old
    /// file may decide anything about the new one.
    pub fn reset(self: *Gate) void {
        self.* = .{};
    }

    fn judge(self: *Gate, now: ?Stamp) Verdict {
        const s = now orelse {
            self.last = null;
            return .render;
        };
        if (self.last) |l| {
            if (l.eql(s)) return .unchanged;
        }
        self.last = s;
        return .render;
    }
};

const testing = std.testing;

const s_a: Stamp = .{ .size = 10, .mtime = 100 };
const s_b: Stamp = .{ .size = 10, .mtime = 200 };
const s_c: Stamp = .{ .size = 11, .mtime = 100 };

test "reload_gate: a shown save with an unknown baseline renders" {
    var g: Gate = .{};
    try testing.expectEqual(Verdict.render, g.save(true, s_a));
}

test "reload_gate: a save that left size and time alone does not render" {
    var g: Gate = .{};
    g.note(s_a);
    try testing.expectEqual(Verdict.unchanged, g.save(true, s_a));
    try testing.expectEqual(Verdict.unchanged, g.save(true, s_a));
}

test "reload_gate: a new time or a new size renders, and becomes the baseline" {
    var g: Gate = .{};
    g.note(s_a);
    try testing.expectEqual(Verdict.render, g.save(true, s_b));
    try testing.expectEqual(Verdict.unchanged, g.save(true, s_b));
    try testing.expectEqual(Verdict.render, g.save(true, s_c));
}

test "reload_gate: an unreadable file renders every time (the error card)" {
    var g: Gate = .{};
    g.note(s_a);
    try testing.expectEqual(Verdict.render, g.save(true, null));
    try testing.expectEqual(Verdict.render, g.save(true, null));
    // And the file coming back renders too: the card must be replaced.
    try testing.expectEqual(Verdict.render, g.save(true, s_a));
}

test "reload_gate: hidden saves render nothing and are owed once" {
    var g: Gate = .{};
    g.note(s_a);
    try testing.expectEqual(Verdict.owed, g.save(false, s_b));
    try testing.expectEqual(Verdict.owed, g.save(false, s_c));
    try testing.expectEqual(Verdict.owed, g.save(false, s_b));
    // The baseline is untouched while hidden: the show compares against what
    // is actually on screen.
    try testing.expectEqual(s_a, g.last.?);
    try testing.expect(g.reveal());
    try testing.expect(!g.reveal());
    try testing.expectEqual(Verdict.render, g.save(true, s_b));
}

test "reload_gate: a hidden debt for a file that ended where it started renders nothing" {
    var g: Gate = .{};
    g.note(s_a);
    try testing.expectEqual(Verdict.owed, g.save(false, s_a));
    try testing.expect(g.reveal());
    try testing.expectEqual(Verdict.unchanged, g.save(true, s_a));
}

test "reload_gate: a reveal with nothing owed asks nothing" {
    var g: Gate = .{};
    try testing.expect(!g.reveal());
}

test "reload_gate: a shown save pays a debt the reveal never collected" {
    var g: Gate = .{};
    _ = g.save(false, s_a);
    _ = g.save(true, s_b);
    try testing.expect(!g.reveal());
}

test "reload_gate: reset drops the debt and the baseline" {
    var g: Gate = .{};
    g.note(s_a);
    _ = g.save(false, s_b);
    g.reset();
    try testing.expect(!g.reveal());
    try testing.expectEqual(Verdict.render, g.save(true, s_a));
}
