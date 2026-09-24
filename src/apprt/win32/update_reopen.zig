//! "Your terminal was closed and reopened for an update" (T1208) — the pure
//! half.
//!
//! An upgrade over a running Ghoztty closes it and opens it again by itself:
//! the Restart Manager does that for an installer run by hand (T1204), and the
//! in-app updater does it on purpose (T1178). Both work, and until this module
//! both were SILENT — the windows vanished for a second or two and came back
//! with no word about why, which reads like a crash rather than an update.
//!
//! The Windows Installer's own answer, the Files In Use dialog, lives in the
//! package's UI tables, which the wixl-built MSI does not carry; and it only
//! ever covers the installer run by hand, never the in-app updater. So the
//! notice is said from our side instead, AFTER the fact, on the tray surface
//! every other update message already uses:
//!
//!  1. On the way out, the process that is about to be closed for an update
//!     leaves a one-line MARKER — why it is going (`installer` / `updater`),
//!     when, and the version it was running.
//!  2. The next launch consumes the marker (always deletes it) and decides
//!     here whether there is something true to say.
//!
//! A balloon, not a dialog, because there is nothing to consent to: the close
//! already happened, and a modal on an unattended or silent install would
//! block a machine nobody is sitting at. The decisions — what the marker
//! means, when it is too old to be about this launch, what the sentence says —
//! are all here so every lane asserts them; the file IO and the balloon live
//! in `App.zig` / `Window.zig`.

const std = @import("std");

/// Why the previous process went away.
pub const Reason = enum {
    /// The Restart Manager closed us so an installer could replace our files
    /// (a `WM_ENDSESSION` carrying `ENDSESSION_CLOSEAPP`).
    installer,
    /// The in-app updater armed its applier and quit to let it install.
    updater,

    pub fn text(self: Reason) []const u8 {
        return @tagName(self);
    }

    fn parse(s: []const u8) ?Reason {
        inline for (@typeInfo(Reason).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// The marker's format tag. A marker from a future build that changed the
/// shape reads as "no marker" rather than as a guess.
const format_tag = "v1";

/// A marker older than this is not about THIS launch. The close-and-reopen is
/// seconds apart when it works; a quarter of an hour covers a slow install and
/// a user who reopens by hand after a relaunch that did not happen, and stops
/// a marker stranded by a failed install from announcing an update days later.
pub const max_age_ms: i64 = 15 * std.time.ms_per_min;

/// Clock slack in the other direction: a marker stamped slightly in the future
/// is a clock adjustment, one stamped far in the future is nonsense.
const max_skew_ms: i64 = std.time.ms_per_min;

pub const Marker = struct {
    reason: Reason,
    /// Wall-clock milliseconds when the old process wrote the marker.
    at_ms: i64,
    /// The version the closed process was running.
    from_version: []const u8,
};

/// Format a marker line into `buf`. Returns an empty slice when it does not
/// fit or the version would corrupt the line; the caller then writes nothing,
/// which costs the notice and nothing else.
pub fn format(buf: []u8, m: Marker) []const u8 {
    if (m.from_version.len == 0) return buf[0..0];
    if (std.mem.indexOfAny(u8, m.from_version, " \t\r\n") != null) return buf[0..0];
    return std.fmt.bufPrint(buf, format_tag ++ " {s} {d} {s}\n", .{
        m.reason.text(),
        m.at_ms,
        m.from_version,
    }) catch buf[0..0];
}

/// Parse a marker file's bytes. Null for anything that is not exactly one v1
/// line: a truncated write, another build's format, stray text.
pub fn parse(bytes: []const u8) ?Marker {
    var text = bytes;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    text = std.mem.trim(u8, text, " \t\r\n");
    if (text.len == 0) return null;
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return null;

    var it = std.mem.tokenizeScalar(u8, text, ' ');
    const tag = it.next() orelse return null;
    if (!std.mem.eql(u8, tag, format_tag)) return null;
    const reason = Reason.parse(it.next() orelse return null) orelse return null;
    const at_ms = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const from = it.next() orelse return null;
    if (it.next() != null) return null;
    return .{ .reason = reason, .at_ms = at_ms, .from_version = from };
}

/// The marker's filename, `-debug` suffixed on a debug build so a dev build
/// never consumes (or leaves) the installed release's marker.
pub fn fileName(is_debug: bool) []const u8 {
    return if (is_debug) "update-reopen-debug" else "update-reopen";
}

/// What the tray balloon says. Title and body fit `NOTIFYICONDATAW`'s
/// 64/256-unit fields with room to spare for any real version string.
pub const Notice = struct {
    title: []const u8,
    body: []const u8,
    /// Whether a click should open What's New — only when the version moved,
    /// since that is the only case with news to show.
    offer_whats_new: bool,
};

pub const title = "Ghoztty Was Updated";
pub const title_reopened = "Ghoztty Was Reopened";

/// Decide what (if anything) this launch says, given the marker it found.
///
/// - No marker, or a stale / future-dated one: nothing. The close is not
///   about this launch, and a false "you were just updated" is worse than
///   silence.
/// - The version moved: the update landed. Say it closed and reopened, name
///   both versions, and offer What's New.
/// - The in-app updater's marker and NO version change: the install failed
///   and relaunched the old build. The applier already says that in a modal
///   with the cause and the log (T1206), so a second, cheerier message here
///   would contradict it: nothing.
/// - An installer closed us and the version did not move (a repair, a
///   reinstall of the same build): still true that the terminal was closed and
///   reopened, which is the part the user saw, so say that.
pub fn decide(buf: []u8, marker: ?Marker, current_version: []const u8, now_ms: i64) ?Notice {
    const m = marker orelse return null;
    const age = now_ms - m.at_ms;
    if (age > max_age_ms or age < -max_skew_ms) return null;

    const moved = !std.mem.eql(u8, m.from_version, current_version);
    if (moved) {
        const body = std.fmt.bufPrint(
            buf,
            "Your terminal was closed and reopened to install version {s} (you had {s}).\nClick to see what's new.",
            .{ current_version, m.from_version },
        ) catch return null;
        return .{ .title = title, .body = body, .offer_whats_new = true };
    }

    return switch (m.reason) {
        .updater => null,
        .installer => .{
            .title = title_reopened,
            .body = std.fmt.bufPrint(
                buf,
                "An installer closed your terminal and reopened it.\nYou are still on version {s}.",
                .{current_version},
            ) catch return null,
            .offer_whats_new = false,
        },
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "format and parse round-trip" {
    var buf: [128]u8 = undefined;
    const line = format(&buf, .{ .reason = .installer, .at_ms = 1_700_000_000_123, .from_version = "1.37.2" });
    try testing.expectEqualStrings("v1 installer 1700000000123 1.37.2\n", line);
    const m = parse(line).?;
    try testing.expectEqual(Reason.installer, m.reason);
    try testing.expectEqual(@as(i64, 1_700_000_000_123), m.at_ms);
    try testing.expectEqualStrings("1.37.2", m.from_version);

    const u = parse(format(&buf, .{ .reason = .updater, .at_ms = 5, .from_version = "1.37.2+abc" })).?;
    try testing.expectEqual(Reason.updater, u.reason);
    try testing.expectEqualStrings("1.37.2+abc", u.from_version);
}

test "format refuses a version that would corrupt the line" {
    var buf: [128]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), format(&buf, .{ .reason = .installer, .at_ms = 1, .from_version = "" }).len);
    try testing.expectEqual(@as(usize, 0), format(&buf, .{ .reason = .installer, .at_ms = 1, .from_version = "1.0 x" }).len);
    try testing.expectEqual(@as(usize, 0), format(&buf, .{ .reason = .installer, .at_ms = 1, .from_version = "1.0\n" }).len);
    var tiny: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), format(&tiny, .{ .reason = .installer, .at_ms = 1, .from_version = "1.37.2" }).len);
}

test "parse: anything but one v1 line is no marker" {
    try testing.expect(parse("") == null);
    try testing.expect(parse("\r\n") == null);
    try testing.expect(parse("v2 installer 1 1.0") == null);
    try testing.expect(parse("v1 reboot 1 1.0") == null);
    try testing.expect(parse("v1 installer x 1.0") == null);
    try testing.expect(parse("v1 installer 1") == null);
    try testing.expect(parse("v1 installer 1 1.0 extra") == null);
    try testing.expect(parse("v1 installer 1 1.0\nv1 updater 2 1.0") == null);
    // A BOM and trailing whitespace are tolerated.
    try testing.expect(parse("\xEF\xBB\xBFv1 updater 7 1.0\r\n") != null);
}

test "fileName: the debug build has its own marker" {
    try testing.expectEqualStrings("update-reopen", fileName(false));
    try testing.expectEqualStrings("update-reopen-debug", fileName(true));
}

test "decide: no marker says nothing" {
    var buf: [256]u8 = undefined;
    try testing.expect(decide(&buf, null, "1.37.3", 1000) == null);
}

test "decide: an update that landed names both versions and offers What's New" {
    var buf: [256]u8 = undefined;
    for ([_]Reason{ .installer, .updater }) |r| {
        const n = decide(&buf, .{ .reason = r, .at_ms = 1000, .from_version = "1.37.2" }, "1.37.3", 1000 + 5_000).?;
        try testing.expectEqualStrings(title, n.title);
        try testing.expect(n.offer_whats_new);
        try testing.expect(std.mem.indexOf(u8, n.body, "closed and reopened") != null);
        try testing.expect(std.mem.indexOf(u8, n.body, "1.37.3") != null);
        try testing.expect(std.mem.indexOf(u8, n.body, "1.37.2") != null);
    }
}

test "decide: a failed in-app update stays quiet (the applier's modal owns that)" {
    var buf: [256]u8 = undefined;
    try testing.expect(decide(&buf, .{ .reason = .updater, .at_ms = 1000, .from_version = "1.37.2" }, "1.37.2", 2000) == null);
}

test "decide: an installer close with no version change still says it reopened" {
    var buf: [256]u8 = undefined;
    const n = decide(&buf, .{ .reason = .installer, .at_ms = 1000, .from_version = "1.37.2" }, "1.37.2", 2000).?;
    try testing.expectEqualStrings(title_reopened, n.title);
    try testing.expect(!n.offer_whats_new);
    try testing.expect(std.mem.indexOf(u8, n.body, "1.37.2") != null);
}

test "decide: a stale or future-dated marker is not about this launch" {
    var buf: [256]u8 = undefined;
    const m: Marker = .{ .reason = .installer, .at_ms = 0, .from_version = "1.37.2" };
    try testing.expect(decide(&buf, m, "1.37.3", max_age_ms) != null);
    try testing.expect(decide(&buf, m, "1.37.3", max_age_ms + 1) == null);
    try testing.expect(decide(&buf, m, "1.37.3", -max_skew_ms) != null);
    try testing.expect(decide(&buf, m, "1.37.3", -max_skew_ms - 1) == null);
}

test "decide: the notice fits the tray balloon's fields" {
    var buf: [256]u8 = undefined;
    const long = "1.37.2+0123456789ab";
    const n = decide(&buf, .{ .reason = .installer, .at_ms = 0, .from_version = long }, "1.37.3+0123456789ab", 1).?;
    // NOTIFYICONDATAW: szInfoTitle is 64 units, szInfo 256, both NUL-terminated.
    try testing.expect(n.title.len < 64);
    try testing.expect(n.body.len < 256);
}
