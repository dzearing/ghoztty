//! When a downloaded update installs itself (T1934).
//!
//! Before this, the only way a staged package ever reached msiexec was a click
//! on the "Install and Restart" dialog behind a balloon, and an automatic check
//! raises that balloon once per version per day. A terminal that stays open for
//! weeks therefore downloaded every release and installed none of them: on
//! 2026-10-14 the user's app was still 1.36.12 from September with 1.39.7
//! staged beside it.
//!
//! With session persistence on, an install costs the user nothing — the agent
//! holds every shell, Restart Manager closes the app, and the applier reopens
//! it re-attached — so the click was guarding against a loss that does not
//! happen. What it still has to guard against is the INTERRUPTION: the window
//! closing for a few seconds while somebody is typing in it, or msiexec's
//! progress bar appearing over a fullscreen game. So the decision here is about
//! timing, never about consent:
//!
//!   * at LAUNCH, before any window or shell exists, a staged package installs
//!     at once — nothing is open to interrupt, with persistence on or off;
//!   * while running, it installs once the user has been away from the input
//!     devices for `idle_threshold_ms` and nothing fullscreen is in front;
//!   * once the offer is `overdue_ms` old, a shorter idle is enough — a user
//!     who never leaves the keyboard for five minutes must still update;
//!   * never while something fullscreen is in front, overdue or not: msiexec
//!     shows a progress window, and an installer popping over a game is the
//!     exact interruption the user has already objected to (2026-09-27). A box
//!     that is always fullscreen still updates at its next launch;
//!   * with persistence OFF, a running app never installs silently: that would
//!     close the user's shells. It keeps asking instead (the daily re-offer,
//!     `update_check.decideNotify`), and installs at the next launch.
//!
//! An attempt is recorded per version and not repeated inside
//! `retry_backoff_ms`, so a package msiexec rejects cannot turn every launch
//! into an install-and-relaunch loop.
//!
//! Pure: every fact is passed in. No OS imports.

const std = @import("std");

/// How long the user must have been away from keyboard and mouse before a
/// running app closes itself to install.
pub const idle_threshold_ms: u64 = 5 * std.time.ms_per_min;

/// How long an offer may stay outstanding before a shorter idle is enough.
/// A day is this project's publishing cadence.
pub const overdue_ms: i64 = 24 * std.time.ms_per_hour;

/// The idle that is still required once an offer is overdue: long enough that
/// the window never closes under a keystroke in flight.
pub const overdue_idle_ms: u64 = 60 * std.time.ms_per_s;

/// How long a failed (or interrupted) attempt at one version holds off the
/// next automatic attempt at the SAME version.
pub const retry_backoff_ms: i64 = 24 * std.time.ms_per_hour;

/// How often a running app asks the question.
pub const tick_ms: u32 = 60 * std.time.ms_per_s;

pub const Moment = enum {
    /// App start, before any window or shell has been created.
    launch,
    /// The periodic check in a running app.
    tick,
};

pub const Facts = struct {
    moment: Moment,
    /// `auto-update = download` (the default) AND this exe is one that updates
    /// itself at all (the installed product, or a test that opted in).
    enabled: bool,
    /// A verified package is on disk for the pending offer.
    staged: bool,
    /// `session-persistence`: shells live in the agent and survive the app.
    persistence: bool,
    /// This launch was asked to run something (`-e`, `initial-command`); an
    /// install would relaunch without it and swallow the request.
    launch_command: bool = false,
    /// A download is in flight, the update dialog is open, or the app is
    /// already quitting.
    busy: bool = false,
    /// Milliseconds since the last keyboard/mouse input anywhere in the session.
    idle_ms: u64 = 0,
    /// Something fullscreen (a game, a presentation, a video) is in front.
    fullscreen: bool = false,
    /// How long this version has been on offer.
    offered_for_ms: i64 = 0,
    /// An automatic attempt at this same version was made within
    /// `retry_backoff_ms`.
    attempted_recently: bool = false,
};

pub const Reason = enum {
    disabled,
    nothing_staged,
    retry_backoff,
    busy,
    launch_command,
    persistence_off,
    user_active,
    fullscreen,
    // The apply reasons.
    launch,
    idle,
    overdue,
};

pub const Verdict = struct {
    apply: bool,
    reason: Reason,

    fn wait(r: Reason) Verdict {
        return .{ .apply = false, .reason = r };
    }
    fn go(r: Reason) Verdict {
        return .{ .apply = true, .reason = r };
    }
};

pub fn decide(f: Facts) Verdict {
    if (!f.enabled) return .wait(.disabled);
    if (!f.staged) return .wait(.nothing_staged);
    if (f.attempted_recently) return .wait(.retry_backoff);
    if (f.busy) return .wait(.busy);

    switch (f.moment) {
        .launch => {
            if (f.launch_command) return .wait(.launch_command);
            // Nothing is open yet, so there is nothing to interrupt and no
            // shell to lose, whatever persistence says.
            return .go(.launch);
        },
        .tick => {
            if (!f.persistence) return .wait(.persistence_off);
            if (f.fullscreen) return .wait(.fullscreen);
            if (f.idle_ms >= idle_threshold_ms) return .go(.idle);
            if (f.offered_for_ms >= overdue_ms and f.idle_ms >= overdue_idle_ms) return .go(.overdue);
            return .wait(.user_active);
        },
    }
}

// =============================================================================
// The attempt record: "<version>\n<ms>\n"
// =============================================================================

pub const Attempt = struct {
    version: []const u8,
    at_ms: i64,
};

pub fn serializeAttempt(buf: []u8, a: Attempt) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}\n{d}\n", .{ a.version, a.at_ms }) catch null;
}

pub fn parseAttempt(text: []const u8) ?Attempt {
    var it = std.mem.splitScalar(u8, text, '\n');
    const version = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    if (version.len == 0) return null;
    const ms_text = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    const at_ms = std.fmt.parseInt(i64, ms_text, 10) catch return null;
    return .{ .version = version, .at_ms = at_ms };
}

/// Whether `rec` holds off an automatic attempt at `version` at `now_ms`. A
/// clock that went backwards keeps the hold rather than releasing it early.
pub fn attemptedRecently(rec: ?Attempt, version: []const u8, now_ms: i64) bool {
    const a = rec orelse return false;
    if (!std.mem.eql(u8, a.version, version)) return false;
    return now_ms -| a.at_ms < retry_backoff_ms;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn tick(over: Facts) Facts {
    var f = over;
    f.moment = .tick;
    return f;
}

const base: Facts = .{ .moment = .tick, .enabled = true, .staged = true, .persistence = true };

test "decide: an idle user with persistence on gets the update without a click" {
    var f = base;
    f.idle_ms = idle_threshold_ms;
    try testing.expectEqual(Verdict{ .apply = true, .reason = .idle }, decide(f));
}

test "decide: never while the user is typing" {
    var f = base;
    f.idle_ms = idle_threshold_ms - 1;
    try testing.expectEqual(Verdict{ .apply = false, .reason = .user_active }, decide(f));
    // Overdue relaxes the idle needed, but never to zero.
    f.offered_for_ms = overdue_ms;
    f.idle_ms = overdue_idle_ms - 1;
    try testing.expectEqual(Verdict{ .apply = false, .reason = .user_active }, decide(f));
}

test "decide: fullscreen holds the install back, overdue or not" {
    var f = base;
    f.idle_ms = idle_threshold_ms * 3;
    f.fullscreen = true;
    try testing.expectEqual(Verdict{ .apply = false, .reason = .fullscreen }, decide(f));
    // An installer window over a game is the interruption this exists to
    // avoid; a week-old offer does not make it acceptable.
    f.offered_for_ms = overdue_ms * 7;
    try testing.expectEqual(Verdict{ .apply = false, .reason = .fullscreen }, decide(f));
    // The launch install is the way out for a box that is always fullscreen.
    f.moment = .launch;
    try testing.expectEqual(Verdict{ .apply = true, .reason = .launch }, decide(f));
}

test "decide: overdue installs after a short idle even with nothing fullscreen" {
    var f = base;
    f.offered_for_ms = overdue_ms + 1;
    f.idle_ms = overdue_idle_ms;
    try testing.expectEqual(Verdict{ .apply = true, .reason = .overdue }, decide(f));
}

test "decide: persistence off never installs silently in a running app" {
    var f = base;
    f.persistence = false;
    f.idle_ms = idle_threshold_ms * 100;
    f.offered_for_ms = overdue_ms * 30;
    try testing.expectEqual(Verdict{ .apply = false, .reason = .persistence_off }, decide(f));
}

test "decide: launch installs before any shell exists, persistence on or off" {
    var f = base;
    f.moment = .launch;
    try testing.expectEqual(Verdict{ .apply = true, .reason = .launch }, decide(f));
    f.persistence = false;
    try testing.expectEqual(Verdict{ .apply = true, .reason = .launch }, decide(f));
    // Not even the user typing matters: no window of ours is up to type in.
    f.idle_ms = 0;
    f.fullscreen = true;
    try testing.expectEqual(Verdict{ .apply = true, .reason = .launch }, decide(f));
}

test "decide: a launch that was asked to run something is not swallowed" {
    var f = base;
    f.moment = .launch;
    f.launch_command = true;
    try testing.expectEqual(Verdict{ .apply = false, .reason = .launch_command }, decide(f));
}

test "decide: the switches that hold everything" {
    var f = base;
    f.moment = .launch;
    f.idle_ms = idle_threshold_ms;
    f.enabled = false;
    try testing.expectEqual(Reason.disabled, decide(f).reason);
    try testing.expect(!decide(f).apply);
    f.enabled = true;
    f.staged = false;
    try testing.expectEqual(Reason.nothing_staged, decide(f).reason);
    f.staged = true;
    f.attempted_recently = true;
    try testing.expectEqual(Reason.retry_backoff, decide(f).reason);
    try testing.expect(!decide(tick(f)).apply);
    f.attempted_recently = false;
    f.busy = true;
    try testing.expectEqual(Reason.busy, decide(f).reason);
    try testing.expect(!decide(tick(f)).apply);
}

test "attempt record round-trips and backs off per version" {
    var buf: [128]u8 = undefined;
    const text = serializeAttempt(&buf, .{ .version = "1.39.7", .at_ms = 1_000 }).?;
    const rec = parseAttempt(text).?;
    try testing.expectEqualStrings("1.39.7", rec.version);
    try testing.expectEqual(@as(i64, 1_000), rec.at_ms);

    try testing.expect(attemptedRecently(rec, "1.39.7", 1_000 + retry_backoff_ms - 1));
    try testing.expect(!attemptedRecently(rec, "1.39.7", 1_000 + retry_backoff_ms));
    // A newer version is a new attempt, at once.
    try testing.expect(!attemptedRecently(rec, "1.39.8", 1_001));
    // A clock that went backwards keeps the hold.
    try testing.expect(attemptedRecently(rec, "1.39.7", 0));
    try testing.expect(!attemptedRecently(null, "1.39.7", 0));
}

test "parseAttempt: malformed records are no record" {
    try testing.expect(parseAttempt("") == null);
    try testing.expect(parseAttempt("1.39.7") == null);
    try testing.expect(parseAttempt("1.39.7\nsoon\n") == null);
    try testing.expect(parseAttempt("\n5\n") == null);
    const crlf = parseAttempt("1.39.7\r\n42\r\n").?;
    try testing.expectEqualStrings("1.39.7", crlf.version);
    try testing.expectEqual(@as(i64, 42), crlf.at_ms);
}
