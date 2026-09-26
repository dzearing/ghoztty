//! What a window says when it had to open WITHOUT session persistence (T1693).
//!
//! THE DEFECT. With `session-persistence` on, every local window asks
//! `LocalAgent.sharedConnection` for the agent that keeps its shells alive
//! across a restart. When that resolve FAILS - the agent would not launch, or
//! launched and never answered inside the 2s deadline - the window opens as a
//! plain local shell, and so does every window opened in the 15s cooldown after
//! it. Nothing said so. The window looked exactly like a persisted one and was
//! simply gone after the next quit, crash or upgrade: the one moment the user
//! was relying on it. Only a MISSING agent binary was ever reported (T1177, a
//! startup dialog), and T976's late-agent adoption rescues the RESTORE, not a
//! window that already opened on a local shell - a running shell cannot be
//! moved into the agent after the fact.
//!
//! THE FIX. Such a window carries a banner on its first terminal pane saying it
//! will not survive a restart, and why. A banner rather than a dialog because
//! it is a fact about THAT window, it can happen at any moment (not only at
//! startup), and it has to stay visible for as long as it is true - which is
//! the window's whole life.
//!
//! WHICH CAUSES. `spawn_failed` and `unresponsive` are the silent arms this
//! exists for. `agent_binary_missing` is already told once, app-wide, by the
//! T1177 startup dialog - a half-installed app has no persistence for ANY
//! window, and repeating it on each one would be noise over a notice the user
//! has already had. `protocol_skew` belongs to the mandatory-update path
//! (T125). No cause at all (a wedged link, T764, where `sharedConnection`
//! declines a connection that is still healing) is not a failed start and gets
//! no notice here.
//!
//! OWNERSHIP BY TEXT. The notice is a fixed literal nothing else writes - the
//! same rule as T723's agent-unreachable notice - so `isNotice` can tell ours
//! from a banner the user or a script set, and the layout capture leaves ours
//! out: it describes this run's window, and a restored window that got the
//! agent must not come back claiming it did not.
//!
//! Pure on purpose, so the decision is unit-tested in every lane; the mechanism
//! lives in `App.createEmptyWindow` (records it) and `Window.addTab` (shows it).

const std = @import("std");

/// Why the shared local-agent resolve gave up. Mirrors `LocalAgent.Failure`
/// tag for tag; the app converts by name so this file needs nothing win32.
pub const Cause = enum {
    agent_binary_missing,
    spawn_failed,
    unresponsive,
    protocol_skew,
};

pub const unresponsive_notice =
    "**Not persisted** — Ghoztty's session agent did not respond, so this " ++
    "window will not survive quitting or restarting Ghoztty. " ++
    "Windows opened once it answers are kept as usual.";

pub const spawn_failed_notice =
    "**Not persisted** — Ghoztty's session agent could not be started, so this " ++
    "window will not survive quitting or restarting Ghoztty. " ++
    "Windows opened once it starts are kept as usual.";

/// The banner a window that opened without the agent should carry, or null
/// when it should carry none. `cause` is null when the last resolve did not
/// fail (the agent is simply not in play for this window).
pub fn bannerFor(cause: ?Cause) ?[]const u8 {
    return switch (cause orelse return null) {
        .unresponsive => unresponsive_notice,
        .spawn_failed => spawn_failed_notice,
        .agent_binary_missing, .protocol_skew => null,
    };
}

/// Convert a `LocalAgent.Failure` (or any enum with the same tag names) by
/// name. Null for a tag this module does not know, which then shows nothing
/// rather than the wrong sentence.
pub fn causeFromTag(tag: []const u8) ?Cause {
    return std.meta.stringToEnum(Cause, tag);
}

/// Whether a banner is this module's notice (and therefore safe for the app to
/// leave out of the saved layout). An exact match only: anything else is a
/// banner somebody else set, which is never ours to touch.
pub fn isNotice(text: []const u8) bool {
    return std.mem.eql(u8, text, unresponsive_notice) or
        std.mem.eql(u8, text, spawn_failed_notice);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "the two silent failure arms get a notice" {
    try testing.expectEqualStrings(unresponsive_notice, bannerFor(.unresponsive).?);
    try testing.expectEqualStrings(spawn_failed_notice, bannerFor(.spawn_failed).?);
}

test "a missing binary is left to the startup dialog, skew to the update path" {
    try testing.expect(bannerFor(.agent_binary_missing) == null);
    try testing.expect(bannerFor(.protocol_skew) == null);
}

test "no failure means no notice" {
    try testing.expect(bannerFor(null) == null);
}

test "each notice says the window will not survive a restart, and why" {
    for ([_][]const u8{ unresponsive_notice, spawn_failed_notice }) |n| {
        try testing.expect(std.mem.indexOf(u8, n, "Not persisted") != null);
        try testing.expect(std.mem.indexOf(u8, n, "will not survive") != null);
        try testing.expect(std.mem.indexOf(u8, n, "session agent") != null);
    }
    try testing.expect(std.mem.indexOf(u8, unresponsive_notice, "did not respond") != null);
    try testing.expect(std.mem.indexOf(u8, spawn_failed_notice, "could not be started") != null);
}

test "causeFromTag converts LocalAgent.Failure names and refuses others" {
    try testing.expectEqual(Cause.unresponsive, causeFromTag("unresponsive").?);
    try testing.expectEqual(Cause.spawn_failed, causeFromTag("spawn_failed").?);
    try testing.expectEqual(Cause.agent_binary_missing, causeFromTag("agent_binary_missing").?);
    try testing.expect(causeFromTag("wedged") == null);
}

test "isNotice owns exactly its own literals" {
    try testing.expect(isNotice(unresponsive_notice));
    try testing.expect(isNotice(spawn_failed_notice));
    try testing.expect(!isNotice(""));
    try testing.expect(!isNotice("**Not persisted**"));
    try testing.expect(!isNotice("my own banner"));
}
