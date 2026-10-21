//! "The relay no longer knows this machine" — what the sharing uplink does
//! when its credential is answered 401 (T2050, the Windows half of main
//! 6dfb31232).
//!
//! ## Why this exists
//!
//! Removing a machine from the account on ANOTHER device revokes its device
//! token at the relay; the machine itself is told nothing. On a Mac the relay
//! LaunchAgent runs `--exit-on-revoke`, so two consecutive 401s on the control
//! dial stop it, and `RelayHostAgent` deletes relay.env: the machine is off
//! the relay and its "Share this machine" box reads unticked.
//!
//! On Windows the uplink rides the SESSION agent (`main.zig` `SharingUplink`),
//! and exiting would take the user's live panes with it, so `--exit-on-revoke`
//! is never passed there. Before this module the uplink therefore redialed the
//! dead credential on backoff forever, and the chooser's checkbox — which
//! decides on credential PRESENCE (`ShareMachineRow`, `sharing.decide`) —
//! went on reading the machine as shared.
//!
//! So the same streak (`revoked_after_rejections`) ends here instead: drop
//! relay.env and park the link. Dropping the file is what makes every other
//! reader agree — the reconciler sees no credential and keeps the link parked,
//! the checkbox unticks, a restart does not redial — and a re-enroll writes a
//! fresh relay.env that the reconciler and the creds watcher already bring
//! back up.
//!
//! ## Why the drop names the rejected token
//!
//! The streak is about ONE token: the one the relay refused. If relay.env
//! carries a different token by the time the streak completes, the machine
//! was re-enrolled while the old token was still being dialed, and deleting
//! that file would sign the user's fresh enrollment out. That case is
//! `.superseded`: keep the file, keep the link up, and let the creds watcher
//! adopt the new token on its next tick.

const std = @import("std");
const Allocator = std.mem.Allocator;
const enroll = @import("enroll.zig");

pub const Outcome = enum {
    /// relay.env still held the rejected token and was deleted.
    dropped,
    /// relay.env was already gone (a sign-out raced the streak).
    already_gone,
    /// relay.env now holds a DIFFERENT token — a re-enroll landed while the
    /// old one was being dialed. Nothing is deleted.
    superseded,
};

/// What to do with relay.env given its current token (null = no file / no
/// token line) and the token the relay just rejected. Pure; tested below.
pub fn decide(current: ?[]const u8, rejected: []const u8) Outcome {
    const cur = current orelse return .already_gone;
    return if (std.mem.eql(u8, cur, rejected)) .dropped else .superseded;
}

/// Whether the uplink should park for this outcome. A superseded credential
/// is about to be adopted by the creds watcher, so parking would only delay
/// the fresh enrollment coming up.
pub fn parks(outcome: Outcome) bool {
    return outcome != .superseded;
}

/// Apply `decide` to the real relay.env: delete it (and its staging debris)
/// only while it still carries `rejected`.
pub fn dropIfStill(alloc: Allocator, rejected: []const u8) Outcome {
    const current = enroll.loadDeviceToken(alloc);
    defer if (current) |c| alloc.free(c);
    const outcome = decide(current, rejected);
    if (outcome == .dropped) enroll.clearLocalCredential(alloc);
    return outcome;
}

const testing = std.testing;

test "decide: the rejected token still in relay.env is dropped" {
    try testing.expectEqual(Outcome.dropped, decide("tok-a", "tok-a"));
    try testing.expect(parks(.dropped));
}

test "decide: a re-enroll's fresh token is never deleted" {
    try testing.expectEqual(Outcome.superseded, decide("tok-new", "tok-old"));
    try testing.expect(!parks(.superseded));
}

test "decide: a credential already gone still parks" {
    try testing.expectEqual(Outcome.already_gone, decide(null, "tok-a"));
    try testing.expect(parks(.already_gone));
}
