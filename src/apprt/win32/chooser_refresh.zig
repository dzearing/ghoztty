//! The machine chooser's REFRESH POLICY (T711) — when the device list is
//! re-asked for, and what the user is told while it is being asked.
//!
//! The win32 twin of the quiet-refresh rules Mac's `refreshFromRelay(quiet:)`
//! and the chooser's 5s poll task carry (`27e639ae6`). Pure, so the parts most
//! worth checking — "a blip must not flash an error at somebody who is reading
//! a list that still works" — run in the none-runtime lane rather than needing
//! a relay, a network fault and a stopwatch.

const std = @import("std");

/// How often an OPEN chooser re-asks the directory. Mac's interval; slow
/// enough that a chooser left open all afternoon is not a load generator, fast
/// enough that a machine coming online is noticed while you are looking at it.
pub const poll_ms: u32 = 5_000;

/// How many CONSECUTIVE quiet failures it takes before the footer says so.
///
/// The whole point of the number being greater than one: the list on screen is
/// still the last thing the relay actually said, and a single dropped tick
/// makes it no less true. Flashing "couldn't reach the relay" at somebody
/// mid-click — and then clearing it a second later — is noise about a
/// condition that did not affect them.
pub const miss_threshold: u8 = 3;

/// What a poll tick should do.
pub const Tick = enum {
    /// No credential: there is no directory to ask for. Mac's ticks skip
    /// entirely while signed out, and so do ours — a poll must never be what
    /// starts an OAuth flow.
    skip_signed_out,
    /// A fetch is already in flight. Ticking again would pile requests up
    /// behind a slow network, which is the one condition polling must not make
    /// worse.
    skip_inflight,
    fetch,
};

pub fn tick(signed_in: bool, inflight: bool) Tick {
    if (!signed_in) return .skip_signed_out;
    if (inflight) return .skip_inflight;
    return .fetch;
}

/// The quiet-failure counter behind the footer hint.
pub const Misses = struct {
    count: u8 = 0,

    /// Record a failed refresh. Returns true when the user should now be told
    /// — which is on the `miss_threshold`th consecutive miss and on every one
    /// after it, so a relay that stays down keeps saying so.
    pub fn failed(self: *Misses) bool {
        if (self.count < std.math.maxInt(u8)) self.count += 1;
        return self.count >= miss_threshold;
    }

    /// Record a successful refresh: the streak is over and any error the
    /// footer was showing is stale.
    pub fn succeeded(self: *Misses) void {
        self.count = 0;
    }
};

/// Whether a refresh's outcome is worth REDRAWING for.
///
/// A steady-state poll answers "the same three machines, all still online"
/// every five seconds. Publishing that would rebuild the listbox, drop the
/// hover, and repaint the dialog twelve times a minute for no reason — Mac's
/// `apply()` has the same guard for the same reason. Identity, order, names,
/// hostnames and presence are all compared, because every one of them is drawn.
pub fn changed(old: []const Fingerprint, new: []const Fingerprint) bool {
    if (old.len != new.len) return true;
    for (old, new) |a, b| if (!a.eql(b)) return true;
    return false;
}

/// What a row DRAWS, reduced to the comparison `changed` makes.
pub const Fingerprint = struct {
    id: []const u8,
    name: []const u8,
    hostname: []const u8 = "",
    online: bool,

    pub fn eql(a: Fingerprint, b: Fingerprint) bool {
        return a.online == b.online and
            std.mem.eql(u8, a.id, b.id) and
            std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.hostname, b.hostname);
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "tick: a poll never runs signed out, and never piles up" {
    try testing.expectEqual(Tick.skip_signed_out, tick(false, false));
    try testing.expectEqual(Tick.skip_signed_out, tick(false, true));
    try testing.expectEqual(Tick.skip_inflight, tick(true, true));
    try testing.expectEqual(Tick.fetch, tick(true, false));
}

test "Misses: a blip stays quiet, a sustained outage speaks" {
    var m: Misses = .{};
    try testing.expect(!m.failed());
    try testing.expect(!m.failed());
    try testing.expect(m.failed()); // third consecutive
    try testing.expect(m.failed()); // and it keeps saying so
}

test "Misses: one success ends the streak" {
    var m: Misses = .{};
    _ = m.failed();
    _ = m.failed();
    m.succeeded();
    try testing.expect(!m.failed());
    try testing.expect(!m.failed());
    try testing.expect(m.failed());
}

test "changed: a steady-state poll publishes nothing" {
    const a = [_]Fingerprint{
        .{ .id = "d1", .name = "Winbox", .hostname = "winbox.local", .online = true },
        .{ .id = "d2", .name = "Laptop", .online = false },
    };
    const b = a;
    try testing.expect(!changed(&a, &b));
}

test "changed: every drawn field is compared" {
    const base = [_]Fingerprint{.{ .id = "d1", .name = "Winbox", .hostname = "h", .online = true }};
    const renamed = [_]Fingerprint{.{ .id = "d1", .name = "Studio", .hostname = "h", .online = true }};
    const rehosted = [_]Fingerprint{.{ .id = "d1", .name = "Winbox", .hostname = "h2", .online = true }};
    const offline = [_]Fingerprint{.{ .id = "d1", .name = "Winbox", .hostname = "h", .online = false }};
    const replaced = [_]Fingerprint{.{ .id = "d9", .name = "Winbox", .hostname = "h", .online = true }};
    try testing.expect(changed(&base, &renamed));
    try testing.expect(changed(&base, &rehosted));
    try testing.expect(changed(&base, &offline));
    try testing.expect(changed(&base, &replaced));
    try testing.expect(changed(&base, &.{}));
}

test "changed: ORDER is part of the answer" {
    const a = [_]Fingerprint{
        .{ .id = "d1", .name = "A", .online = true },
        .{ .id = "d2", .name = "B", .online = true },
    };
    const b = [_]Fingerprint{
        .{ .id = "d2", .name = "B", .online = true },
        .{ .id = "d1", .name = "A", .online = true },
    };
    // The relay's order is the display order (no client-side sort), so a
    // reordered directory IS a changed list.
    try testing.expect(changed(&a, &b));
}
