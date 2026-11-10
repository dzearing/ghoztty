//! "Ghoztty closed unexpectedly" (T2862) - the pure half of the notice a
//! launch gives when the run before it crashed.
//!
//! Since T2839 a shipping build asks Windows to relaunch it after a crash, and
//! session restore re-attaches what the agent kept, so the windows come back
//! by themselves. That fixed the outage and left a gap: the windows vanished
//! and reappeared with no word about why. On macOS the system says it - its
//! "quit unexpectedly" prompt - so a Mac user always knows. This is the
//! Windows-native counterpart: a balloon from the relaunched app, on the same
//! tray surface as the update-reopened notice (T1208), that names the crash
//! and opens the crash reports when clicked. A balloon rather than a dialog,
//! because the crash already happened and there is nothing to decide.
//!
//! Nothing here needs a marker file. Whether to speak is read from the exit
//! ledger (`os/exit_ledger.zig`, `crashBeforeLaunch`): the first launch after a
//! crash finds it as the newest event, and every later launch finds its own
//! `start` past it. The file IO and the balloon are in `exit_reason.zig` and
//! `App.zig`; what is decided here is asserted by the unit lanes.

const std = @import("std");

pub const title = "Ghoztty closed unexpectedly";

pub const Notice = struct {
    title: []const u8,
    body: []const u8,
};

/// How long ago the crash was, in words. `crash_ms` null (an unreadable
/// stamp) or a crash stamped in the future (a clock that moved) says
/// "earlier" rather than inventing a number.
pub fn describeAge(buf: []u8, crash_ms: ?i64, now_ms: i64) []const u8 {
    const then = crash_ms orelse return "earlier";
    const age = now_ms - then;
    if (age < 0) return "earlier";
    const min: i64 = 60_000;
    const hour: i64 = 60 * min;
    const day: i64 = 24 * hour;
    if (age < 2 * min) return "a moment ago";
    if (age < hour) return std.fmt.bufPrint(buf, "{d} minutes ago", .{@divFloor(age, min)}) catch "earlier";
    if (age < 2 * hour) return "an hour ago";
    if (age < 2 * day) return std.fmt.bufPrint(buf, "{d} hours ago", .{@divFloor(age, hour)}) catch "earlier";
    return std.fmt.bufPrint(buf, "{d} days ago", .{@divFloor(age, day)}) catch "earlier";
}

/// The sentence, sized for a balloon's 255-character body.
pub fn notice(buf: []u8, crash_ms: ?i64, now_ms: i64) Notice {
    var age_buf: [32]u8 = undefined;
    const ago = describeAge(&age_buf, crash_ms, now_ms);
    const body = std.fmt.bufPrint(
        buf,
        "It crashed {s} and was reopened. Click to see the crash report.",
        .{ago},
    ) catch "It crashed and was reopened. Click to see the crash report.";
    return .{ .title = title, .body = body };
}

test "describeAge words a crash's age the way a person would" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;
    const now: i64 = 10 * 24 * 3_600_000;
    try testing.expectEqualStrings("a moment ago", describeAge(&buf, now - 30_000, now));
    try testing.expectEqualStrings("5 minutes ago", describeAge(&buf, now - 5 * 60_000, now));
    try testing.expectEqualStrings("an hour ago", describeAge(&buf, now - 90 * 60_000, now));
    try testing.expectEqualStrings("7 hours ago", describeAge(&buf, now - 7 * 3_600_000, now));
    try testing.expectEqualStrings("3 days ago", describeAge(&buf, now - 3 * 24 * 3_600_000, now));
}

test "describeAge never invents a number it cannot know" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("earlier", describeAge(&buf, null, 1000));
    // A crash stamped after now: the clock moved, so say nothing precise.
    try testing.expectEqualStrings("earlier", describeAge(&buf, 5000, 1000));
}

test "notice names the crash, the relaunch and what a click does" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const n = notice(&buf, 0, 30_000);
    try testing.expectEqualStrings(title, n.title);
    try testing.expectEqualStrings(
        "It crashed a moment ago and was reopened. Click to see the crash report.",
        n.body,
    );
    // A balloon body is capped at 255 UTF-16 units (szInfo is 256 with NUL).
    try testing.expect(n.body.len < 256);
}
