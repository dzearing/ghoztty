//! The pure half of the GTK local-agent upgrade (T3600, Linux L8f): what the
//! app does with win32's `agent_upgrade` decision, the gate that a pid is
//! really the agent before it is signalled, and the skew dialog's buttons.
//! No GTK imports, so every test lane runs it. The DECISIONS themselves are
//! win32's pure `agent_upgrade.zig` (shared, not copied); this only maps them
//! onto what the GTK app can do.

const std = @import("std");
const agent_upgrade = @import("../win32/agent_upgrade.zig");

/// What the GTK app does about one decision.
pub const Plan = enum {
    /// Log it and leave the agent alone.
    nothing,
    /// Stop the agent and rebuild its panes in place on the bundled build,
    /// asking nobody: nothing live can be lost (`stale_idle`).
    refresh,
    /// Ask first (the mandatory-update dialog): an agent-older protocol skew,
    /// where the app cannot reach the sessions to save them.
    ask_restart,
    /// Tell the user the APP is out of date (`skew_app_older`); never act.
    notify_app_older,
    /// A policy edit asked for something this path must never do (a silent
    /// restart across a skew, or a consent restart for a mere build gap).
    /// Refused with a log line rather than `unreachable`.
    refuse,
};

/// `skew` says which check produced `d`: `evaluateSkew` (true) or the
/// build-stamp `evaluate` (false). The two paths have different legal arms,
/// and the illegal ones are refused here, once, for both.
pub fn planFor(d: agent_upgrade.Decision, skew: bool) Plan {
    if (skew) return switch (d.action) {
        .confirm_first => .ask_restart,
        .none => if (d.reason == .skew_app_older) .notify_app_older else .nothing,
        // A skew has no idle arm: "no live sessions" is not knowable across
        // one, and an unknown count is never grounds for a silent restart.
        .refresh_now, .handoff_now => .refuse,
    };
    return switch (d.action) {
        .refresh_now => .refresh,
        // The Linux agent does not replace itself (no handoff): standing down
        // would wait forever, so it is treated as deferred - nothing.
        .none, .handoff_now => .nothing,
        // T1056: a build-stamp gap never asks to end a live session.
        .confirm_first => .refuse,
    };
}

/// Whether `/proc/<pid>/exe` (`exe`) is the agent, before any signal is sent
/// to a pid read out of a file (win32's T421 gate). The kernel appends
/// " (deleted)" when the binary was replaced on disk - which is exactly the
/// stale agent this path exists for - so that suffix is not a refusal.
/// `expected` is the binary this app would launch (`GHOSTTY_LOCAL_AGENT_BIN`
/// or the sibling); a relocated agent matches it by path.
pub fn isAgentExe(exe_raw: []const u8, expected: ?[]const u8) bool {
    const exe = std.mem.trimRight(u8, stripDeleted(exe_raw), " ");
    if (exe.len == 0) return false;
    if (expected) |e| if (std.mem.eql(u8, exe, e)) return true;
    return std.mem.eql(u8, std.fs.path.basenamePosix(exe), "ghoztty-agent");
}

fn stripDeleted(s: []const u8) []const u8 {
    const suffix = " (deleted)";
    return if (std.mem.endsWith(u8, s, suffix)) s[0 .. s.len - suffix.len] else s;
}

/// The skew dialog's buttons, in order. Later is first, the default, and the
/// cancel: Enter or Escape must never end sessions (win32's default_cancel).
pub const skew_buttons = [_][:0]const u8{ agent_upgrade.install_now_cancel, agent_upgrade.install_now_ok };
pub const skew_default_index: usize = 0;
pub const skew_cancel_index: usize = 0;
const restart_index: usize = 1;

pub const Answer = enum { restart, later };

/// The dialog's answer from the chosen button, or null (dismissed) = Later.
pub fn answerFor(index: ?usize) Answer {
    return if (index == restart_index) .restart else .later;
}

/// The debug-only scripted answer (`GHOZTTY_TEST_AGENT_SKEW_ANSWER`): a
/// headless run cannot click, so the test seam answers for it. Anything but
/// "restart" is Later - the safe direction.
pub fn scriptedAnswer(v: ?[]const u8) Answer {
    const s = v orelse return .later;
    return if (std.mem.eql(u8, std.mem.trim(u8, s, " \t\r\n"), "restart")) .restart else .later;
}

/// At most this many restarts per run: one that does not cure the staleness
/// (another install's agent still holding the guard) must not loop.
pub const max_attempts: usize = 2;

const testing = std.testing;

test "planFor: a stale idle agent refreshes; a live one is left alone (T3600)" {
    try testing.expectEqual(Plan.refresh, planFor(agent_upgrade.evaluate("1.0.0+aaa", "1.0.1+bbb", 0, .{}), false));
    try testing.expectEqual(Plan.nothing, planFor(agent_upgrade.evaluate("1.0.0+aaa", "1.0.1+bbb", 3, .{}), false));
    try testing.expectEqual(Plan.nothing, planFor(agent_upgrade.evaluate("1.0.1+bbb", "1.0.1+bbb", 0, .{}), false));
    try testing.expectEqual(Plan.nothing, planFor(agent_upgrade.evaluate("1.0.0+aaa", null, 0, .{}), false));
}

test "planFor: never a destructive restart of a live agent for a build gap, at any count" {
    var live: usize = 1;
    while (live < 50) : (live += 1) {
        const p = planFor(agent_upgrade.evaluate("0.0.1+old", "9.9.9+new", live, .{ .capable = true }), false);
        try testing.expect(p != .refresh and p != .ask_restart);
    }
}

test "planFor: a skew asks only when the agent is the older side (T3600)" {
    const local: u16 = 5;
    try testing.expectEqual(Plan.ask_restart, planFor(agent_upgrade.evaluateSkew(4, local), true));
    try testing.expectEqual(Plan.notify_app_older, planFor(agent_upgrade.evaluateSkew(6, local), true));
    try testing.expectEqual(Plan.nothing, planFor(agent_upgrade.evaluateSkew(null, local), true));
}

test "planFor: illegal arms are refused, never acted on" {
    try testing.expectEqual(Plan.refuse, planFor(.{ .action = .refresh_now, .reason = .stale_idle }, true));
    try testing.expectEqual(Plan.refuse, planFor(.{ .action = .handoff_now, .reason = .stale_handoff }, true));
    try testing.expectEqual(Plan.refuse, planFor(.{ .action = .confirm_first, .reason = .skew_agent_older }, false));
}

test "isAgentExe: the agent, a replaced-on-disk agent, and a relocated one" {
    try testing.expect(isAgentExe("/opt/ghoztty/bin/ghoztty-agent", null));
    try testing.expect(isAgentExe("/opt/ghoztty/bin/ghoztty-agent (deleted)", null));
    try testing.expect(isAgentExe("/tmp/x/my-agent", "/tmp/x/my-agent"));
    try testing.expect(isAgentExe("/tmp/x/my-agent (deleted)", "/tmp/x/my-agent"));
}

test "isAgentExe: anything else is refused (negative control)" {
    try testing.expect(!isAgentExe("/usr/bin/bash", null));
    try testing.expect(!isAgentExe("/opt/ghoztty/bin/ghoztty", null));
    try testing.expect(!isAgentExe("/opt/ghoztty/bin/ghoztty-agent-helper", null));
    try testing.expect(!isAgentExe("", null));
    try testing.expect(!isAgentExe(" (deleted)", null));
    try testing.expect(!isAgentExe("/usr/bin/bash", "/tmp/x/my-agent"));
}

test "skew dialog: Later is the default and the cancel; only the Restart button restarts" {
    try testing.expectEqualStrings("Later", skew_buttons[skew_default_index]);
    try testing.expectEqual(skew_default_index, skew_cancel_index);
    try testing.expectEqual(Answer.later, answerFor(null));
    try testing.expectEqual(Answer.later, answerFor(0));
    try testing.expectEqual(Answer.restart, answerFor(1));
    try testing.expectEqual(Answer.later, answerFor(7));
}

test "scriptedAnswer: only an explicit restart restarts" {
    try testing.expectEqual(Answer.restart, scriptedAnswer("restart"));
    try testing.expectEqual(Answer.restart, scriptedAnswer(" restart\n"));
    try testing.expectEqual(Answer.later, scriptedAnswer(null));
    try testing.expectEqual(Answer.later, scriptedAnswer(""));
    try testing.expectEqual(Answer.later, scriptedAnswer("yes"));
}
