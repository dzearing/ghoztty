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

// -----------------------------------------------------------------------------
// The waiting-update row (T3691; win32's T1068)
// -----------------------------------------------------------------------------

/// The GAction behind the main menu's "Background Update Ready…" row and the
/// palette's "Install Background Process Update…" entry. Enabled only while an
/// update waits; the menu row is `hidden-when: action-disabled`.
pub const install_action = "install-agent-update";
pub const install_action_detailed = "app." ++ install_action;

/// What the row shows after a check that `settlesPending`: the waiting update,
/// or null (row hidden). A check that does not settle it leaves `current`.
pub fn nextPending(current: ?agent_upgrade.Pending, reason: agent_upgrade.Reason) ?agent_upgrade.Pending {
    if (!agent_upgrade.settlesPending(reason)) return current;
    return agent_upgrade.pendingFor(reason);
}

/// The opt-in dialog's body on Linux. win32's `installNowText` leads the same
/// way (waiting is free) but then says the APP restarts: on Windows the row's
/// OK relaunches Ghoztty with its agent. The GTK app restarts only the agent
/// and rebuilds every pane in place (the AgentRecovery path the skew Restart
/// uses), so its windows stay - and the text says what actually happens.
pub fn installNowTextInPlace(buf: []u8, pending: agent_upgrade.Pending, live_sessions: ?usize) []const u8 {
    const lead = "A newer version of Ghoztty\u{2019}s background terminal process is installed. ";
    const when = switch (pending) {
        .when_idle => "It takes over on its own once all your terminal sessions have closed",
        .draining => "It takes over on its own as your older terminal sessions close",
    };
    const mid = ", so nothing you have open is interrupted.\n\n" ++
        "Installing it now restarts the background process and ends ";
    const tail = " and the programs running in them. Your windows stay open, and each pane starts again.";
    if (live_sessions) |n| {
        return std.fmt.bufPrint(buf, "{s}{s}{s}your {d} open terminal session{s}{s}", .{
            lead, when, mid, n, if (n == 1) "" else "s", tail,
        }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{s}{s}{s}every open terminal session{s}", .{ lead, when, mid, tail }) catch buf[0..0];
}

/// The install dialog's buttons: the skew dialog's, Later first and default.
pub const install_buttons = skew_buttons;

/// The app-older notice's body on Linux. win32's ends "Click to update
/// Ghoztty", which its toast acts on; Linux has no updater for a click to
/// start, so the body names the step the user takes instead and the
/// notification carries no click promise.
pub const app_older_body_linux =
    "The background process holding your terminal sessions is newer than " ++
    "this copy, so sessions are not being kept.\nInstall the latest Ghoztty to keep them.";

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

test "nextPending: a deferred stale agent puts the row up; a settling check takes it down (T3691)" {
    const live = agent_upgrade.evaluate("1.0.0+aaa", "1.0.1+bbb", 2, .{});
    try testing.expectEqual(agent_upgrade.Pending.when_idle, nextPending(null, live.reason).?);
    const current = agent_upgrade.evaluate("1.0.1+bbb", "1.0.1+bbb", 2, .{});
    try testing.expectEqual(@as(?agent_upgrade.Pending, null), nextPending(.when_idle, current.reason));
    const idle = agent_upgrade.evaluate("1.0.0+aaa", "1.0.1+bbb", 0, .{});
    try testing.expectEqual(@as(?agent_upgrade.Pending, null), nextPending(.when_idle, idle.reason));
}

test "nextPending: an unknown bundled build or a skew never clears the row (negative control)" {
    const unknown = agent_upgrade.evaluate("1.0.0+aaa", null, 2, .{});
    try testing.expectEqual(agent_upgrade.Pending.when_idle, nextPending(.when_idle, unknown.reason).?);
    const skew = agent_upgrade.evaluateSkew(4, 5);
    try testing.expectEqual(agent_upgrade.Pending.when_idle, nextPending(.when_idle, skew.reason).?);
    try testing.expectEqual(@as(?agent_upgrade.Pending, null), nextPending(null, skew.reason));
}

test "installNowTextInPlace: waiting is free first, then what ends, and the windows stay (T3691)" {
    var buf: [1024]u8 = undefined;
    const one = installNowTextInPlace(&buf, .when_idle, 1);
    try testing.expect(std.mem.indexOf(u8, one, "your 1 open terminal session and") != null);
    const free = std.mem.indexOf(u8, one, "nothing you have open is interrupted").?;
    const cost = std.mem.indexOf(u8, one, "ends your").?;
    try testing.expect(free < cost);
    try testing.expect(std.mem.indexOf(u8, one, "Your windows stay open") != null);
    // Not win32's promise: the GTK app is never relaunched for this.
    try testing.expect(std.mem.indexOf(u8, one, "restarts Ghoztty") == null);

    const many = installNowTextInPlace(&buf, .draining, 3);
    try testing.expect(std.mem.indexOf(u8, many, "your 3 open terminal sessions and") != null);
    try testing.expect(std.mem.indexOf(u8, many, "as your older terminal sessions close") != null);
    const unknown = installNowTextInPlace(&buf, .when_idle, null);
    try testing.expect(std.mem.indexOf(u8, unknown, "every open terminal session") != null);
}

test "install dialog: Later is the default; the labels are win32's" {
    try testing.expectEqualStrings(agent_upgrade.install_now_cancel, install_buttons[skew_default_index]);
    try testing.expectEqualStrings(agent_upgrade.install_now_ok, install_buttons[1]);
    try testing.expectEqualStrings("app.install-agent-update", install_action_detailed);
}

test "app_older_body_linux: no click promise, the step the user can take" {
    try testing.expect(std.mem.indexOf(u8, app_older_body_linux, "Click") == null);
    try testing.expect(std.mem.indexOf(u8, app_older_body_linux, "Install the latest Ghoztty") != null);
    try testing.expect(std.mem.indexOf(u8, app_older_body_linux, "protocol") == null);
    try testing.expect(app_older_body_linux.len < 256);
}

test "scriptedAnswer: only an explicit restart restarts" {
    try testing.expectEqual(Answer.restart, scriptedAnswer("restart"));
    try testing.expectEqual(Answer.restart, scriptedAnswer(" restart\n"));
    try testing.expectEqual(Answer.later, scriptedAnswer(null));
    try testing.expectEqual(Answer.later, scriptedAnswer(""));
    try testing.expectEqual(Answer.later, scriptedAnswer("yes"));
}
