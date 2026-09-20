//! The PERSISTENT update affordance (T1673): the mark on the menu button that
//! says an update is waiting, the row that installs it, and the durable record
//! that lets both survive a restart.
//!
//! ## The defect this exists for
//!
//! The user's box ran 1.36.12 while win-v1.36.30 was published — eighteen
//! releases and fourteen days behind — with two verified packages already
//! staged on disk. Every part of the updater worked except the last one: the
//! offer was a BALLOON, and a balloon is missable by construction. Away from
//! the desk, notifications quiet, a full-screen app — the offer is gone, and
//! nothing anywhere in the window said an update was waiting.
//!
//! T1563 bounded the silence at a day (`update_check.offer_expiry_ms`), which
//! is the right answer for how often to INTERRUPT somebody. It is not an
//! answer to "where do I look for the thing I missed". That question needs an
//! affordance that is simply THERE, and this module is its model.
//!
//! ## Three parts, and why each one
//!
//! 1. **A dot on the menu button.** The button already exists in every window
//!    (the tab strip's `≡`, or the caption's `…` on a merged-chrome window),
//!    and it is where every other app-level command lives — so the mark costs
//!    no pixels and points at the place the action actually is. Chrome,
//!    Edge and VS Code all badge the same control for the same reason.
//! 2. **An escalating hue.** `good` while the offer is fresh, `warn` after two
//!    days, `danger` after a week. Escalation is the half of the report the
//!    balloon could never do: a user who ignores one balloon and a user who is
//!    fourteen days behind are the same user to a notification, and they are
//!    not the same user to somebody deciding whether to stop and install.
//! 3. **A durable record.** The offer used to live only in the process that
//!    made it, so a restart forgot both the offer and its age — and the age is
//!    what the escalation measures. Worse, a build that came up with a staged
//!    package already on disk said nothing until the next hourly check
//!    happened to succeed. The record is written when an offer is made and
//!    read at startup, so the affordance is up before any network call and the
//!    ladder measures from the FIRST time the user was told, not from this
//!    process's launch.
//!
//! ## Color is never the only signal
//!
//! WCAG 1.4.1: the hue escalates, but it is not what carries the meaning. The
//! menu row that appears alongside it is words — "Install Update 1.36.30" —
//! and it appears at the top of the popup in all three states. The dot is the
//! thing that catches your eye; the row is the thing that tells you what it
//! means.
//!
//! No OS imports, so every number below is asserted at 1.0 / 1.25 / 1.5 / 2.0
//! in every app-runtime lane (the `readonly_badge` / `remote_pill` pattern).
//! The painting half is `paintUpdateDot` in `Window.zig`; the record's file
//! I/O and the offer plumbing are in `App.zig`.

const std = @import("std");
const chrome_theme = @import("chrome_theme.zig");
const color_math = @import("color_math.zig");
const icon_button = @import("icon_button.zig");
const update_check = @import("update_check.zig");

const Rgb = color_math.Rgb;
const Rect = icon_button.Rect;

// =============================================================================
// The escalation ladder
// =============================================================================

/// How loudly the affordance is speaking. Measured from the FIRST offer of a
/// version, never from the last — re-offering the same update every day must
/// not reset the clock that says how far behind the user is.
pub const Urgency = enum {
    /// Offered recently. A quiet, positive mark: there is something here, and
    /// nothing is wrong.
    available,
    /// Two days have passed with the offer outstanding.
    stale,
    /// A week. At this point the user is running a build with a week of
    /// published fixes missing from it, which is the state T1673 was filed
    /// from — except there it was fourteen days and nothing said so at all.
    overdue,
};

/// The offer goes amber after this long. Two days rather than one because the
/// project publishes daily: a single day behind is the NORMAL state of a
/// terminal that has been open overnight, and marking the normal state amber
/// would teach the user that amber means nothing.
pub const stale_after_ms: i64 = 2 * 24 * 60 * 60 * 1000;

/// And red after this long. A week is the point at which "I'll do it later"
/// has demonstrably stopped being true.
pub const overdue_after_ms: i64 = 7 * 24 * 60 * 60 * 1000;

/// How long the offer at `first_offered_ms` has been outstanding, as a rung on
/// the ladder.
///
/// A `now` that went backwards (a system clock change, a resume from
/// hibernation onto a bad RTC) saturates to zero rather than wrapping into a
/// huge age: a red dot from arithmetic would be the same lie as no dot at all,
/// pointing the other way.
pub fn urgencyFor(first_offered_ms: i64, now_ms: i64) Urgency {
    const age = now_ms -| first_offered_ms;
    if (age >= overdue_after_ms) return .overdue;
    if (age >= stale_after_ms) return .stale;
    return .available;
}

/// The chrome tone each rung paints in. Reusing `chrome_theme.Tone` rather
/// than naming three colors here is what keeps the dot the same green, amber
/// and red the connection pill and the chooser badges already mean — and it is
/// what gets the 3:1 contrast floor for free on every theme.
pub fn tone(u: Urgency) chrome_theme.Tone {
    return switch (u) {
        .available => .good,
        .stale => .warn,
        .overdue => .danger,
    };
}

/// The dot's ink on a chrome band of `bar`, floored to the chrome target.
pub fn dotColor(bar: Rgb, u: Urgency) Rgb {
    return chrome_theme.toneInk(bar, tone(u));
}

// =============================================================================
// Geometry
// =============================================================================

/// Dot diameter, unscaled px. The same 8 DIP the connection pill's status dot
/// uses — on the 4 DIP scale, and big enough that its hue is judgeable at a
/// glance instead of being a stray pixel.
pub const dot_dip: f32 = 8.0;

/// A ring of the band color around the dot, so the mark reads as a badge ON
/// the button rather than as a smudge in the glyph it overlaps. Every badged
/// menu button in Windows' own shell does this.
pub const ring_dip: f32 = 1.0;

/// How far the dot's box is inset from the painted square's top-right corner.
/// Zero would hang the badge on the corner itself, where the button's rounded
/// fill (radius 4 DIP) cuts it; one step in puts the whole dot inside the
/// lit rect at every scale.
pub const inset_dip: f32 = 1.0;

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

pub const Metrics = struct {
    /// Dot diameter in physical px, floored at 2 so it is never a single
    /// pixel that reads as a rendering artifact.
    dot: i32,
    /// Ring thickness, floored at one physical pixel.
    ring: i32,
    /// Inset from the target square's top-right corner.
    inset: i32,

    pub fn init(scale: f32) Metrics {
        return .{
            .dot = @max(px(dot_dip, scale), 2),
            .ring = @max(px(ring_dip, scale), 1),
            .inset = @max(px(inset_dip, scale), 1),
        };
    }
};

/// The dot's square, in the same coordinates as `target` — which is the box
/// `icon_button.targetBox` painted, NOT the hit box. Anchored to the top-right
/// corner because that is where every badge a Windows user has seen lives, and
/// because the menu glyph's three bars are centered: a top-right badge covers
/// the least of the mark it sits on.
///
/// A target too small to hold the dot yields an empty rect rather than a
/// clipped one; the caller draws nothing and the menu row still says it.
pub fn dotRect(target: Rect, scale: f32) Rect {
    const m = Metrics.init(scale);
    const need = m.dot + 2 * m.ring + m.inset;
    if (target.width() < need or target.height() < need) return .{};
    const right = target.right - m.inset;
    const top = target.top + m.inset;
    return .{
        .left = right - m.dot,
        .top = top,
        .right = right,
        .bottom = top + m.dot,
    };
}

// =============================================================================
// Wording
// =============================================================================

/// The longest label `menuLabel` can produce, so callers can size a stack
/// buffer without guessing. "Download Update " plus a generous version.
pub const label_cap: usize = 64;

/// The menu row's text for a pending offer.
///
/// Two verbs, because they promise different things and the difference is
/// what the user is deciding about: a staged package installs on the spot,
/// and one that still has to be fetched is a download they will wait through.
/// The balloon already makes exactly this distinction (`showUpdateNotification`),
/// so the row and the balloon cannot say different things about the same offer.
pub fn menuLabel(buf: []u8, version: []const u8, staged: bool) []const u8 {
    const verb = if (staged) "Install" else "Download";
    return std.fmt.bufPrint(buf, "{s} Update {s}", .{ verb, version }) catch
        // A version long enough to overflow 64 bytes is not a version; say the
        // true thing that always fits rather than showing nothing.
        if (staged) "Install Update" else "Download Update";
}

// =============================================================================
// The durable record
// =============================================================================

/// What is written to disk so an offer — and its age — survives a restart.
///
/// Deliberately not JSON: three fields, written by one function, read by one
/// function, on a path that must never be able to throw away a real offer
/// because a parser was strict about a trailing byte. Unknown lines are
/// ignored, so a future field cannot make an old build forget the update.
pub const Record = struct {
    /// The offered release's version text ("1.36.30").
    version: []const u8,
    /// When the user was FIRST told about this version, on
    /// `std.time.milliTimestamp`'s clock. The escalation ladder measures from
    /// here.
    first_offered_ms: i64,
    /// A verified package already on disk, when the pre-download got one.
    staged_msi: ?[]const u8 = null,
};

const key_version = "version=";
const key_first = "first_offered_ms=";
const key_staged = "staged=";

/// Write `rec` in the on-disk form. Returns the slice of `buf` written, or
/// null when `buf` is too small (the caller then writes nothing rather than a
/// truncated record that would parse as a different offer).
pub fn serialize(buf: []u8, rec: Record) ?[]const u8 {
    var w = std.io.fixedBufferStream(buf);
    const out = w.writer();
    out.print("{s}{s}\n", .{ key_version, rec.version }) catch return null;
    out.print("{s}{d}\n", .{ key_first, rec.first_offered_ms }) catch return null;
    if (rec.staged_msi) |p| out.print("{s}{s}\n", .{ key_staged, p }) catch return null;
    return w.getWritten();
}

fn value(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    return std.mem.trim(u8, line[key.len..], " \t\r");
}

/// Read a record back. The returned slices point INTO `text`.
///
/// Null for anything that is not a complete offer — a missing version, a
/// timestamp that is not a number, an empty file. Failing closed here means
/// the worst a corrupt record can do is cost the affordance until the next
/// check, which is exactly the state the app was in before this existed.
pub fn parse(text: []const u8) ?Record {
    var version: ?[]const u8 = null;
    var first: ?i64 = null;
    var staged: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (value(line, key_version)) |v| {
            if (v.len > 0) version = v;
        } else if (value(line, key_first)) |v| {
            first = std.fmt.parseInt(i64, v, 10) catch return null;
        } else if (value(line, key_staged)) |v| {
            if (v.len > 0) staged = v;
        }
        // Anything else: a field a newer build writes. Ignored on purpose.
    }

    return .{
        .version = version orelse return null,
        .first_offered_ms = first orelse return null,
        .staged_msi = staged,
    };
}

/// The record to store now that `version` has been offered, given whatever was
/// stored before.
///
/// The one rule that matters: **the same version keeps its original
/// `first_offered_ms`**. Re-offering daily is what T1563 made the app do, and
/// if each re-offer reset the clock the ladder could never leave its first
/// rung — the dot would be green forever on a user who is a month behind,
/// which is the defect with a new coat of paint. A DIFFERENT version is
/// genuinely new news and starts its own clock.
///
/// `staged_msi` is taken from the new offer either way: a package that has
/// since been fetched (or has gone away) is current information about the same
/// version.
pub fn advance(
    existing: ?Record,
    version: []const u8,
    staged_msi: ?[]const u8,
    now_ms: i64,
) Record {
    const first = if (existing) |old|
        if (std.mem.eql(u8, old.version, version)) old.first_offered_ms else now_ms
    else
        now_ms;
    return .{
        .version = version,
        .first_offered_ms = first,
        .staged_msi = staged_msi,
    };
}

/// Whether a stored record still describes an update this build has not taken.
///
/// This is the check that retires the affordance, and it is deliberately the
/// SAME comparison the update check itself makes (`update_check.isNewer`): the
/// dot goes away because the running build caught up, which is the only honest
/// reason for it to go away. A record left behind by an install that succeeded
/// therefore cleans itself up on the next launch with no extra bookkeeping —
/// and one for a version the user actually is behind on survives being ignored
/// for as long as it takes.
pub fn isPending(rec: Record, current: std.SemanticVersion) bool {
    return update_check.isNewer(current, rec.version);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "urgencyFor: the ladder's rungs, and their exact edges" {
    const t0: i64 = 1_700_000_000_000;
    try testing.expectEqual(Urgency.available, urgencyFor(t0, t0));
    try testing.expectEqual(Urgency.available, urgencyFor(t0, t0 + stale_after_ms - 1));
    try testing.expectEqual(Urgency.stale, urgencyFor(t0, t0 + stale_after_ms));
    try testing.expectEqual(Urgency.stale, urgencyFor(t0, t0 + overdue_after_ms - 1));
    try testing.expectEqual(Urgency.overdue, urgencyFor(t0, t0 + overdue_after_ms));
    // T1673's own state: fourteen days behind.
    try testing.expectEqual(Urgency.overdue, urgencyFor(t0, t0 + 14 * 24 * 60 * 60 * 1000));
}

test "urgencyFor: a clock that went backwards reads as fresh, not as red" {
    const t0: i64 = 1_700_000_000_000;
    try testing.expectEqual(Urgency.available, urgencyFor(t0, t0 - 5_000));
    try testing.expectEqual(Urgency.available, urgencyFor(t0, 0));
}

test "tone: three rungs, three distinct chrome tones" {
    try testing.expectEqual(chrome_theme.Tone.good, tone(.available));
    try testing.expectEqual(chrome_theme.Tone.warn, tone(.stale));
    try testing.expectEqual(chrome_theme.Tone.danger, tone(.overdue));
}

test "dotColor: every rung clears the chrome contrast floor on a sweep of bands" {
    const bands = [_]Rgb{
        .{ .r = 0x1E, .g = 0x1E, .b = 0x1E },
        .{ .r = 0x00, .g = 0x00, .b = 0x00 },
        .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
        .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 },
        .{ .r = 0x2E, .g = 0x30, .b = 0x40 },
        .{ .r = 0x00, .g = 0x40, .b = 0x00 },
        .{ .r = 0xFF, .g = 0xB0, .b = 0x00 },
        .{ .r = 0x68, .g = 0x00, .b = 0x81 },
    };
    for (bands) |bar| {
        for ([_]Urgency{ .available, .stale, .overdue }) |u| {
            const c = dotColor(bar, u);
            const r = color_math.wcagContrastRatio(
                color_math.wcagLuminance(c),
                color_math.wcagLuminance(bar),
            );
            try testing.expect(r >= chrome_theme.ui_contrast_target);
        }
    }
}

test "dotRect: inside the painted square at every scale, anchored top-right" {
    for (scales) |s| {
        const ib = icon_button.Metrics.init(s);
        const box: Rect = .{ .left = 100, .top = 40, .right = 100 + ib.target, .bottom = 40 + ib.target };
        const target = icon_button.targetBox(ib, box);
        const dot = dotRect(target, s);
        const m = Metrics.init(s);

        // A real, square dot of the metric size.
        try testing.expectEqual(m.dot, dot.width());
        try testing.expectEqual(m.dot, dot.height());
        // Wholly inside the lit square — a badge the button's rounded fill
        // clips is the defect `inset_dip` exists to prevent.
        try testing.expect(dot.left >= target.left);
        try testing.expect(dot.top >= target.top);
        try testing.expect(dot.right <= target.right);
        try testing.expect(dot.bottom <= target.bottom);
        // Top-right, not centered: it must not sit on the middle bar of the
        // ≡ glyph.
        try testing.expect(dot.left > @divTrunc(target.left + target.right, 2));
        try testing.expect(dot.bottom < @divTrunc(target.top + target.bottom, 2) + m.dot);
    }
}

test "dotRect: a square too small for the badge yields nothing, not a smear" {
    for (scales) |s| {
        const tiny: Rect = .{ .left = 0, .top = 0, .right = 4, .bottom = 4 };
        try testing.expect(dotRect(tiny, s).isEmpty());
        try testing.expect(dotRect(.{}, s).isEmpty());
    }
}

test "Metrics: never degenerate, and monotonic in scale" {
    var prev: i32 = 0;
    for (scales) |s| {
        const m = Metrics.init(s);
        try testing.expect(m.dot >= 2);
        try testing.expect(m.ring >= 1);
        try testing.expect(m.inset >= 1);
        try testing.expect(m.dot >= prev);
        prev = m.dot;
    }
}

test "menuLabel: the verb says whether a download is still coming" {
    var buf: [label_cap]u8 = undefined;
    try testing.expectEqualStrings("Install Update 1.36.30", menuLabel(&buf, "1.36.30", true));
    try testing.expectEqualStrings("Download Update 1.36.30", menuLabel(&buf, "1.36.30", false));
}

test "menuLabel: an absurd version degrades to the true short sentence" {
    var buf: [label_cap]u8 = undefined;
    const long = "1." ++ ("9" ** 200) ++ ".0";
    try testing.expectEqualStrings("Install Update", menuLabel(&buf, long, true));
    try testing.expectEqualStrings("Download Update", menuLabel(&buf, long, false));
}

test "record: round-trips, with and without a staged package" {
    var buf: [512]u8 = undefined;
    const rec: Record = .{
        .version = "1.36.30",
        .first_offered_ms = 1_757_000_000_000,
        .staged_msi = "C:\\Users\\a\\AppData\\Local\\ghoztty\\updates\\Ghoztty-1.36.30-x64.msi",
    };
    const back = parse(serialize(&buf, rec).?).?;
    try testing.expectEqualStrings(rec.version, back.version);
    try testing.expectEqual(rec.first_offered_ms, back.first_offered_ms);
    try testing.expectEqualStrings(rec.staged_msi.?, back.staged_msi.?);

    const bare: Record = .{ .version = "1.37.0", .first_offered_ms = 42 };
    const bare_back = parse(serialize(&buf, bare).?).?;
    try testing.expectEqualStrings("1.37.0", bare_back.version);
    try testing.expectEqual(@as(i64, 42), bare_back.first_offered_ms);
    try testing.expect(bare_back.staged_msi == null);
}

test "record: a buffer too small writes nothing rather than half an offer" {
    var tiny: [8]u8 = undefined;
    try testing.expect(serialize(&tiny, .{ .version = "1.36.30", .first_offered_ms = 1 }) == null);
}

test "parse: fails closed on anything that is not a complete offer" {
    try testing.expect(parse("") == null);
    try testing.expect(parse("\n\n  \n") == null);
    try testing.expect(parse("version=1.36.30\n") == null); // no timestamp
    try testing.expect(parse("first_offered_ms=5\n") == null); // no version
    try testing.expect(parse("version=\nfirst_offered_ms=5\n") == null); // empty version
    try testing.expect(parse("version=1.0.0\nfirst_offered_ms=banana\n") == null);
}

test "parse: tolerant of CRLF, blank lines and fields it has never heard of" {
    const text = "version=1.36.30\r\n\r\nchannel=stable\r\nfirst_offered_ms=7\r\n";
    const rec = parse(text).?;
    try testing.expectEqualStrings("1.36.30", rec.version);
    try testing.expectEqual(@as(i64, 7), rec.first_offered_ms);
}

test "advance: re-offering the same version keeps the original clock" {
    const t0: i64 = 1_700_000_000_000;
    const first = advance(null, "1.36.30", null, t0);
    try testing.expectEqual(t0, first.first_offered_ms);

    // Three days of daily re-offers must NOT walk the dot back to green.
    var rec = first;
    var day: i64 = 1;
    while (day <= 3) : (day += 1) {
        rec = advance(rec, "1.36.30", "C:\\pkg.msi", t0 + day * 24 * 60 * 60 * 1000);
        try testing.expectEqual(t0, rec.first_offered_ms);
    }
    try testing.expectEqual(Urgency.overdue, urgencyFor(rec.first_offered_ms, t0 + overdue_after_ms));
    // ...and the staged path IS refreshed, because that part really changed.
    try testing.expectEqualStrings("C:\\pkg.msi", rec.staged_msi.?);
}

test "advance: a newer version is new news and starts its own clock" {
    const t0: i64 = 1_700_000_000_000;
    const old: Record = .{ .version = "1.36.30", .first_offered_ms = t0 };
    const new = advance(old, "1.37.0", null, t0 + overdue_after_ms);
    try testing.expectEqual(t0 + overdue_after_ms, new.first_offered_ms);
    try testing.expectEqual(Urgency.available, urgencyFor(new.first_offered_ms, t0 + overdue_after_ms));
}

test "isPending: the affordance retires exactly when the build catches up" {
    const rec: Record = .{ .version = "1.36.30", .first_offered_ms = 1 };
    try testing.expect(isPending(rec, try std.SemanticVersion.parse("1.36.12")));
    // An install that landed: same version, so nothing is pending any more.
    try testing.expect(!isPending(rec, try std.SemanticVersion.parse("1.36.30")));
    // ...including via the release exe's stamped build metadata.
    try testing.expect(!isPending(rec, try std.SemanticVersion.parse("1.36.30+abc1234")));
    try testing.expect(!isPending(rec, try std.SemanticVersion.parse("1.37.0")));
    // A record naming garbage never keeps a dot alive forever.
    try testing.expect(!isPending(
        .{ .version = "banana", .first_offered_ms = 1 },
        try std.SemanticVersion.parse("1.36.12"),
    ));
}
