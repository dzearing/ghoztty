//! Keep a ConPTY child's clear-and-redraw on screen as ONE frame (T1763).
//!
//! ## The bug this exists to stop, measured
//!
//! An app that redraws its whole screen — Claude Code answering a resize is the
//! case that matters — wraps the redraw in DEC mode 2026 (synchronized output):
//! `CSI ? 2026 h`, erase the display, write the new frame, `CSI ? 2026 l`. A
//! terminal that honours the bracket shows the old frame until the new one is
//! complete, so the erase is never seen.
//!
//! ConPTY does not deliver that bracket intact. conhost parses the app's VT into
//! its own buffer and re-emits it, and on this box (Windows 11 26200, in-box
//! conhost, every `CreatePseudoConsole` flag tried) one app frame comes out as
//! TWO separate writes on the pipe:
//!
//! ```
//! 2543.7ms n=24   ESC[?2026h ESC[2J ESC[3J ESC[?2026l
//! 2543.7ms n=263  ESC[?25l ESC[H RESIZED row 1 ... (conhost's own paint)
//! ```
//!
//! The erase is passed through inside a bracket that closes at once; the content
//! arrives afterwards, outside it, as conhost's diff paint. Each write is a
//! separate read for us, and the renderer is free to present a frame between
//! two reads — which is the empty screen. That is the "clears and then
//! repaints" flicker the user reported on every resize of a Claude Code pane.
//!
//! ## The hold
//!
//! When a bracket from a ConPTY child closes having ERASED THE DISPLAY, the
//! content it was meant to carry has not arrived yet. So instead of ending
//! synchronized output there, keep it on until conhost's paint has started
//! (text is printed after the close) and the stream has then gone quiet for
//! `idle_ns`, bounded by `cap_ns` from the close.
//!
//! Silence alone is not the signal. The first version released after `idle_ns`
//! of quiet from the close, and on a live window resize the acceptance run
//! logged most frames shown with ZERO rows of text: under a resize conhost's
//! paint can trail its passthrough by more than the idle window, so "nothing
//! for 12ms" meant "not painted yet", not "painted". Waiting for printed text
//! is what distinguishes the two.
//!
//! Only an erasing bracket is held. A bracket with no erase has nothing blank to
//! hide, so it releases exactly as before and ordinary sync-wrapped updates (a
//! keystroke echo, a spinner) pay no latency at all.
//!
//! ## Why it is the CHILD's pty that decides
//!
//! Same reasoning as `history_guard`: this is conhost's behaviour, so it follows
//! the pane's child, not the host OS. A POSIX child's bracket arrives whole and
//! must not be delayed; a Mac window attached to a Windows agent owns a ConPTY
//! child and needs the hold just as much as a local Windows pane does.

const std = @import("std");
const builtin = @import("builtin");
const history_guard = @import("history_guard.zig");
const protocol = @import("../remote/protocol.zig");
const terminal = @import("../terminal/main.zig");

const log = std.log.scoped(.conpty_sync);

/// Once the paint has started, output must have been quiet this long before a
/// held frame is released. A large paint spans several pipe reads back to back,
/// so a few milliseconds of silence after text arrived means it is complete.
pub const idle_ns: u64 = 12 * std.time.ns_per_ms;

/// The longest a held frame is kept back after its bracket closed, however busy
/// the stream stays. A child that streams continuously after a clear must still
/// be seen, and this is short enough to read as one frame of lag, not a hang.
pub const cap_ns: u64 = 150 * std.time.ns_per_ms;

/// Whether a pane whose child runs on `flavor` needs the hold. Shares
/// `history_guard`'s fallback for an unreported flavour (the local one), so the
/// two ConPTY accommodations can never disagree about the same pane.
pub fn enabledFor(flavor: ?protocol.PtyFlavor) bool {
    if (optedOut()) return false;
    return history_guard.enabledFor(flavor);
}

/// `GHOZTTY_CONPTY_SYNC_HOLD=0` turns the hold off. It exists so the
/// acceptance script can show the blank frame the hold removes (its negative
/// control), and as a way out if a program is ever found that the hold hurts.
fn optedOut() bool {
    const cached = struct {
        var value: ?bool = null;
    };
    if (cached.value) |v| return v;
    const v = if (std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_CONPTY_SYNC_HOLD")) |val| blk: {
        defer std.heap.page_allocator.free(val);
        break :blk std.mem.eql(u8, val, "0");
    } else |_| false;
    cached.value = v;
    return v;
}

/// The rows of the active area that hold any text. The oracle for the
/// flicker: an erasing bracket's frame shown with this at zero is the blank
/// frame the user saw.
pub fn textRows(t: *const terminal.Terminal) usize {
    var it = t.screens.active.pages.rowIterator(.right_down, .{ .active = .{} }, null);
    var n: usize = 0;
    while (it.next()) |pin| {
        if (terminal.page.Cell.hasTextAny(pin.cells(.all))) n += 1;
    }
    return n;
}

/// Debug builds only: say what an erasing ConPTY bracket's frame held at the
/// moment it became showable. `how` is `close` (shown at the bracket's end,
/// the unheld path), `idle` or `cap`. `test/win32/conpty-sync-hold.ps1` reads
/// this line.
pub fn logShown(t: *const terminal.Terminal, how: []const u8, held_ms: u64) void {
    if (comptime builtin.mode != .Debug) return;
    log.info("conpty sync shown how={s} text_rows={d} held_ms={d}", .{ how, textRows(t), held_ms });
}

pub const Verdict = union(enum) {
    /// Show the frame: end synchronized output now.
    release,
    /// Keep holding; ask again after this many nanoseconds.
    wait_ns: u64,
};

/// Decide a held frame from how long ago the bracket closed, how long ago
/// output last arrived, and whether any text has been printed since the close
/// (conhost's paint has begun).
pub fn verdict(since_close_ns: u64, since_output_ns: u64, painted: bool) Verdict {
    if (since_close_ns >= cap_ns) return .release;
    const to_cap = cap_ns - since_close_ns;
    // Nothing painted yet: keep waiting, checking back at the idle cadence.
    if (!painted) return .{ .wait_ns = @min(idle_ns, to_cap) };
    if (since_output_ns >= idle_ns) return .release;
    return .{ .wait_ns = @min(idle_ns - since_output_ns, to_cap) };
}

/// Per-pane hold state. Lives in the stream handler and is only touched with
/// the renderer mutex held, like the terminal modes it shadows.
pub const State = struct {
    /// The open bracket has erased the display.
    erased: bool = false,
    /// A closed bracket is being held open (synchronized output kept on).
    holding: bool = false,
    closed_at: ?std.time.Instant = null,
    last_output: ?std.time.Instant = null,
    /// Whether the most recent `end` closed a bracket that had erased.
    last_end_erased: bool = false,
    /// Text has been printed since the held bracket closed.
    painted: bool = false,

    /// `CSI ? 2026 h`. A new bracket supersedes any hold: synchronized output
    /// is on again under the app's own control.
    pub fn begin(self: *State) void {
        self.erased = false;
        self.holding = false;
        self.painted = false;
    }

    /// An erase-display op. Only one inside an open bracket counts.
    pub fn erase(self: *State, sync_on: bool) void {
        if (sync_on) self.erased = true;
    }

    /// `CSI ? 2026 l`. Returns true when the caller must keep synchronized
    /// output ON and start polling (`poll`) instead of ending it.
    pub fn end(self: *State, enabled: bool, now: std.time.Instant) bool {
        self.last_end_erased = self.erased;
        const hold = enabled and self.erased;
        self.erased = false;
        self.holding = hold;
        self.painted = false;
        if (hold) {
            self.closed_at = now;
            self.last_output = now;
        }
        return hold;
    }

    /// Output arrived. Cheap when not holding.
    pub fn output(self: *State, now: std.time.Instant) void {
        if (self.holding) self.last_output = now;
    }

    /// A character was printed. Called on the print hot path, so it is one
    /// branch when not holding.
    pub inline fn printed(self: *State) void {
        if (self.holding) self.painted = true;
    }

    /// Stop holding without a verdict: a resize or the safety timer already
    /// ended synchronized output.
    pub fn cancel(self: *State) void {
        self.erased = false;
        self.holding = false;
        self.painted = false;
    }

    /// Null when nothing is held. On `.release` the hold is over and the caller
    /// ends synchronized output.
    pub fn poll(self: *State, now: std.time.Instant) ?Verdict {
        if (!self.holding) return null;
        const v = verdict(self.sinceClose(now), self.sinceOutput(now), self.painted);
        if (v == .release) self.holding = false;
        return v;
    }

    pub fn sinceClose(self: *const State, now: std.time.Instant) u64 {
        return now.since(self.closed_at orelse now);
    }

    pub fn sinceOutput(self: *const State, now: std.time.Instant) u64 {
        return now.since(self.last_output orelse now);
    }
};

test "verdict: waits while output is recent and the cap is far" {
    const v = verdict(1 * std.time.ns_per_ms, 0, true);
    try std.testing.expectEqual(Verdict{ .wait_ns = idle_ns }, v);
}

test "verdict: releases once the paint has gone idle" {
    try std.testing.expectEqual(Verdict.release, verdict(20 * std.time.ns_per_ms, idle_ns, true));
}

test "verdict: silence before the paint is NOT a release" {
    // The measured failure of the first version: quiet since the close, but
    // conhost has not painted yet, so releasing would show the blank frame.
    const v = verdict(40 * std.time.ns_per_ms, 40 * std.time.ns_per_ms, false);
    try std.testing.expectEqual(Verdict{ .wait_ns = idle_ns }, v);
}

test "verdict: the cap wins over a stream that never goes quiet or never paints" {
    try std.testing.expectEqual(Verdict.release, verdict(cap_ns, 0, true));
    try std.testing.expectEqual(Verdict.release, verdict(cap_ns, cap_ns, false));
    // Just under the cap, the wait is clipped to what is left of it.
    const v = verdict(cap_ns - std.time.ns_per_ms, 0, true);
    try std.testing.expectEqual(Verdict{ .wait_ns = std.time.ns_per_ms }, v);
}

test "State: a bracket that erased is held; one that did not is not" {
    const now = try std.time.Instant.now();
    var s: State = .{};

    s.begin();
    try std.testing.expect(!s.end(true, now));
    try std.testing.expect(!s.holding);

    s.begin();
    s.erase(true);
    try std.testing.expect(s.end(true, now));
    try std.testing.expect(s.holding);
}

test "State: a non-ConPTY pane is never held" {
    const now = try std.time.Instant.now();
    var s: State = .{};
    s.begin();
    s.erase(true);
    try std.testing.expect(!s.end(false, now));
    try std.testing.expect(!s.holding);
}

test "State: an erase outside a bracket does not arm the next close" {
    const now = try std.time.Instant.now();
    var s: State = .{};
    s.erase(false);
    s.begin();
    try std.testing.expect(!s.end(true, now));
}

test "State: a new bracket or a cancel ends the hold" {
    const now = try std.time.Instant.now();
    var s: State = .{};
    s.begin();
    s.erase(true);
    try std.testing.expect(s.end(true, now));
    s.begin();
    try std.testing.expect(!s.holding);
    try std.testing.expectEqual(@as(?Verdict, null), s.poll(now));

    s.erase(true);
    try std.testing.expect(s.end(true, now));
    s.cancel();
    try std.testing.expectEqual(@as(?Verdict, null), s.poll(now));
}

test "State: poll holds, then releases once when output stops" {
    const t0 = try std.time.Instant.now();
    var s: State = .{};
    s.begin();
    s.erase(true);
    try std.testing.expect(s.end(true, t0));
    // Immediately after the close: keep holding.
    const first = s.poll(t0).?;
    try std.testing.expect(first == .wait_ns);
    // The paint arrives.
    s.printed();
    try std.testing.expect(s.painted);

    // Wait out the idle window for real, then the hold releases exactly once.
    std.Thread.sleep(idle_ns + 2 * std.time.ns_per_ms);
    const later = try std.time.Instant.now();
    try std.testing.expectEqual(Verdict.release, s.poll(later).?);
    try std.testing.expect(!s.holding);
    try std.testing.expectEqual(@as(?Verdict, null), s.poll(later));
}

test "State: without a paint the hold lasts to the cap, not the idle window" {
    const t0 = try std.time.Instant.now();
    var s: State = .{};
    s.begin();
    s.erase(true);
    try std.testing.expect(s.end(true, t0));
    std.Thread.sleep(idle_ns + 2 * std.time.ns_per_ms);
    const later = try std.time.Instant.now();
    try std.testing.expect(s.poll(later).? == .wait_ns);
    try std.testing.expect(s.holding);
}

test "State: printing outside a hold paints nothing" {
    var s: State = .{};
    s.printed();
    try std.testing.expect(!s.painted);
}

test "enabledFor follows the child's pty, not the host" {
    try std.testing.expect(enabledFor(.conpty));
    try std.testing.expect(!enabledFor(.posix));
}
