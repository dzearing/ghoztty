//! Which coding agents the integration offer should name right now (T2604).
//! Pure, so the none lane holds the rule.
//!
//! T870 kept ONE answer for the offer (`claude_setup`), so the first prompt
//! spent it for every agent, including ones installed later: a user who set
//! up Copilot on day one and installed Claude Code on day two was never asked
//! about Claude, and had no way to find the setup in the palette either. The
//! answer is now kept PER AGENT (`agent_offer_<agent>`), and an agent is
//! offered once, the first time it is detected without an answer.
//!
//! The old single answer is honoured once, when the per-agent files first
//! appear (`migrated` false): "declined" stands for the agents detected at that
//! moment, because Not Now was the user's answer for them; an agent detected
//! later was never asked and is offered. "accepted" decides nothing: an agent
//! whose integration is installed is recorded accepted and never offered (that
//! rule holds whatever the old answer was), and one that is not installed was
//! either unticked or not there yet, which cannot be told apart - it is asked
//! once more rather than never.
const std = @import("std");

/// The answer on file for one agent. Same vocabulary as `claude_setup.State`.
pub const Answer = enum { unanswered, accepted, declined };

/// What the launch (or a later re-check) should do for each agent.
pub fn Decision(comptime Agent: type) type {
    return struct {
        /// Name these agents in the prompt.
        offer: std.EnumSet(Agent) = .initEmpty(),
        /// Record these as accepted without asking: already set up.
        record_accepted: std.EnumSet(Agent) = .initEmpty(),
        /// Record these as declined without asking: the pre-T2604 Not Now.
        record_declined: std.EnumSet(Agent) = .initEmpty(),
    };
}

/// `answers` is indexed by the agent's declaration order.
pub fn decide(
    comptime Agent: type,
    detected: std.EnumSet(Agent),
    integrated: std.EnumSet(Agent),
    answers: [std.meta.tags(Agent).len]Answer,
    legacy: Answer,
    migrated: bool,
) Decision(Agent) {
    var out: Decision(Agent) = .{};
    inline for (std.meta.tags(Agent), 0..) |agent, i| {
        if (answers[i] == .unanswered) {
            if (integrated.contains(agent)) {
                out.record_accepted.insert(agent);
            } else if (detected.contains(agent)) {
                if (!migrated and legacy == .declined)
                    out.record_declined.insert(agent)
                else
                    out.offer.insert(agent);
            }
        }
    }
    return out;
}

/// The legacy answer an older build should read after this one has written
/// per-agent answers, so a downgrade never re-asks everything: answered once
/// anything was.
pub fn legacyAfter(prior: Answer, any_accepted: bool) Answer {
    if (any_accepted) return .accepted;
    if (prior != .unanswered) return prior;
    return .declined;
}

/// The state-file name for one agent's answer.
pub fn stateName(comptime Agent: type, comptime agent: Agent) []const u8 {
    return "agent_offer_" ++ @tagName(agent);
}

/// Minimum spacing between re-checks prompted by a new terminal pane
/// (`AgentIntegration.recheckSoon`): the probe walks PATH and a few install
/// folders, so a burst of splits must not run it once each.
pub const recheck_interval_ms: i64 = 60 * std.time.ms_per_s;

/// Whether a re-check may run now, given when the last one ran (0 = never).
pub fn recheckDue(now_ms: i64, last_ms: i64) bool {
    if (last_ms == 0) return true;
    return now_ms - last_ms >= recheck_interval_ms;
}

const TestAgent = enum { claude, copilot };
const Set = std.EnumSet(TestAgent);

fn setOf(agents: []const TestAgent) Set {
    var s = Set.initEmpty();
    for (agents) |a| s.insert(a);
    return s;
}

test "the user's report: Copilot set up first, Claude installed later is offered" {
    // Day one ran the old build: Copilot only, accepted. Day two, Claude is
    // installed and this build launches.
    const d = decide(TestAgent, setOf(&.{ .claude, .copilot }), setOf(&.{.copilot}), .{ .unanswered, .unanswered }, .accepted, false);
    try std.testing.expect(d.offer.eql(setOf(&.{.claude})));
    try std.testing.expect(d.record_accepted.eql(setOf(&.{.copilot})));
    try std.testing.expectEqual(@as(usize, 0), d.record_declined.count());
}

test "an agent installed after a per-agent answer is offered once, the rest stay quiet" {
    const d = decide(TestAgent, setOf(&.{ .claude, .copilot }), setOf(&.{}), .{ .unanswered, .declined }, .accepted, true);
    try std.testing.expect(d.offer.eql(setOf(&.{.claude})));
    // Answered: never again, whatever the probe says.
    const again = decide(TestAgent, setOf(&.{ .claude, .copilot }), setOf(&.{}), .{ .declined, .declined }, .accepted, true);
    try std.testing.expectEqual(@as(usize, 0), again.offer.count());
}

test "an undetected agent is never offered and never burned" {
    const d = decide(TestAgent, setOf(&.{.copilot}), setOf(&.{}), .{ .unanswered, .unanswered }, .unanswered, false);
    try std.testing.expect(d.offer.eql(setOf(&.{.copilot})));
    try std.testing.expect(!d.record_declined.contains(.claude));
    try std.testing.expect(!d.record_accepted.contains(.claude));
}

test "the old Not Now stands for the agents present when it is folded in, not for later ones" {
    const first = decide(TestAgent, setOf(&.{.copilot}), setOf(&.{}), .{ .unanswered, .unanswered }, .declined, false);
    try std.testing.expectEqual(@as(usize, 0), first.offer.count());
    try std.testing.expect(first.record_declined.eql(setOf(&.{.copilot})));
    // Next launch, migrated, Claude now present: asked.
    const later = decide(TestAgent, setOf(&.{ .claude, .copilot }), setOf(&.{}), .{ .unanswered, .declined }, .declined, true);
    try std.testing.expect(later.offer.eql(setOf(&.{.claude})));
}

test "an agent already set up is recorded accepted and never offered" {
    const d = decide(TestAgent, setOf(&.{.claude}), setOf(&.{.claude}), .{ .unanswered, .unanswered }, .declined, false);
    try std.testing.expectEqual(@as(usize, 0), d.offer.count());
    try std.testing.expect(d.record_accepted.eql(setOf(&.{.claude})));
    try std.testing.expect(!d.record_declined.contains(.claude));
}

test "the legacy answer an older build reads is answered once anything is" {
    try std.testing.expectEqual(Answer.accepted, legacyAfter(.unanswered, true));
    try std.testing.expectEqual(Answer.accepted, legacyAfter(.declined, true));
    try std.testing.expectEqual(Answer.declined, legacyAfter(.unanswered, false));
    try std.testing.expectEqual(Answer.accepted, legacyAfter(.accepted, false));
}

test "state names are per agent" {
    try std.testing.expectEqualStrings("agent_offer_claude", stateName(TestAgent, .claude));
    try std.testing.expectEqualStrings("agent_offer_copilot", stateName(TestAgent, .copilot));
}

test "re-checks are spaced" {
    try std.testing.expect(recheckDue(5, 0));
    try std.testing.expect(!recheckDue(1000 + recheck_interval_ms - 1, 1000));
    try std.testing.expect(recheckDue(1000 + recheck_interval_ms, 1000));
}
