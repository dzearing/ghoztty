//! The two user-invoked restarts (T1804): "Restart Ghoztty" and "Restart
//! Ghoztty and Background Sessions", offered from the command palette and the
//! File menu.
//!
//! ## Why two commands, not one with a checkbox
//!
//! They cost the user very different things, and a palette row should say
//! what it costs before it is chosen:
//!
//! - **Restart Ghoztty** relaunches the app only. With session persistence on,
//!   the background agent owns every pane's process, so quitting detaches
//!   them and the relaunched app re-attaches them through the ordinary launch
//!   restore — the same path an update takes. Nothing is lost, so nothing is
//!   asked; the relaunched app says it restarted (`update_reopen.Reason.restart`).
//!   With persistence OFF the shells are the app's own children and die with
//!   it, so that case asks first.
//! - **Restart Ghoztty and Background Sessions** also restarts the agent, which
//!   ends every live session it holds. That is the mandatory-update dialog's
//!   cost, so it borrows that dialog's rules: name how many sessions end, put
//!   Enter on the safe button (`ConfirmDialog.default_cancel`), and point at the
//!   cheaper command. With nothing live there is nothing to lose and it does
//!   not ask — the same rule the idle agent refresh follows (`agent_upgrade`).
//!
//! Mechanism lives in `App.restartApp`; everything that decides what the user
//! is asked, and in which words, is here so every lane asserts it. No OS
//! imports.

const std = @import("std");

/// Which restart the user picked.
pub const Kind = enum {
    /// Relaunch the app; the agent and its sessions are left running.
    app,
    /// Restart the agent too, ending every session it holds.
    app_and_agent,
};

/// What to ask before restarting.
pub const Prompt = enum {
    /// Nothing will be lost: go straight to the restart.
    none,
    /// Session persistence is off, so the app's own shells close with it.
    shells_close,
    /// The background sessions end. Carries the live count when it is known.
    sessions_end,
};

/// Decide what to ask.
///
/// `live_sessions` is the AGENT's own count of live sessions (`agentSessionMix`),
/// or null when it could not be asked. Unknown is treated as "something may be
/// lost", never as zero: "we could not count what this destroys" is not grounds
/// for destroying it unasked.
pub fn prompt(kind: Kind, persistence: bool, live_sessions: ?usize) Prompt {
    return switch (kind) {
        .app => if (persistence) .none else .shells_close,
        .app_and_agent => if (live_sessions) |n|
            (if (n == 0) (if (persistence) .none else .shells_close) else .sessions_end)
        else
            .sessions_end,
    };
}

pub const shells_close_title = "Restart Ghoztty?";
pub const sessions_end_title = "Restart Ghoztty and its background sessions?";

/// Button labels. The destructive one names the act; Cancel stays Cancel so
/// the safe answer reads the same in every Ghoztty prompt.
pub const ok_label = "Restart";
pub const cancel_label = "Cancel";

pub const shells_close_text =
    "Session persistence is off, so restarting Ghoztty closes every open " ++
    "terminal and ends the programs running in them.\n\n" ++
    "Your windows open again empty.";

/// The body for `.sessions_end`. Wording follows Mac's mandatory-update alert
/// (`LocalAgentManager.makeUpgradeAlert`): say what keeps the sessions alive,
/// say how many end, say they cannot be carried across — and then say what to
/// do instead, because the user who only wanted a fresh app has a lossless
/// command one row up.
pub fn sessionsEndText(buf: []u8, live_sessions: ?usize) []const u8 {
    const lead = "Ghoztty keeps your terminal sessions running in a background process. " ++
        "Restarting that process closes ";
    const tail = " and ends the programs running in them. They can\u{2019}t be carried across.\n\n" ++
        "To restart Ghoztty without losing anything, use Restart Ghoztty instead.";
    if (live_sessions) |n| {
        return std.fmt.bufPrint(buf, lead ++ "your {d} open terminal session{s}" ++ tail, .{
            n,
            if (n == 1) "" else "s",
        }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, lead ++ "every open terminal session" ++ tail, .{}) catch buf[0..0];
}

/// What `App.restartApp` did (T3294). Anything but `quitting` means NOTHING
/// happened: no session ended, no window closed, no relaunch is waiting.
pub const Outcome = enum {
    /// The relaunch is armed and the app is quitting for it.
    quitting,
    /// The relaunch could not be set up.
    not_armed,
    /// "Restart Ghoztty and Background Sessions" could not stop the background
    /// process, because this app was started from inside one of its sessions
    /// and stopping it would close this app too (T771). Restarting anyway
    /// would bring back every session the user just agreed to end, with no
    /// word why, so the restart does not happen and the user is told.
    agent_unstoppable,
};

pub const failed_title = "Restart Ghoztty";

/// The body of the notice for an `Outcome` that is not `quitting`; empty for
/// `quitting`, which has nothing to explain.
pub fn failedText(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .quitting => "",
        .not_armed => "Ghoztty could not restart itself.\n\n" ++
            "Nothing was closed. Quit and reopen Ghoztty instead.",
        .agent_unstoppable => "Ghoztty could not restart its background sessions, " ++
            "so nothing was restarted. Your sessions are still running.\n\n" ++
            "This Ghoztty was started from inside one of those sessions, so " ++
            "stopping them would close it too. Quit it, open Ghoztty again the " ++
            "usual way, then try again.",
    };
}

/// The marker reason the closing process leaves for the relaunched one
/// (`update_reopen`), so the relaunched app's notice can say truthfully what
/// came back: only a plain restart WITH persistence kept the sessions running.
/// Without persistence the shells died with the app, which is the same news
/// to the user as an agent restart — fresh sessions.
pub fn reopenReason(kind: Kind, persistence: bool) @import("update_reopen.zig").Reason {
    return if (kind == .app and persistence) .restart else .restart_sessions;
}

/// What the agent restart does with one session in the agent's roster before
/// it stops the agent (T3295).
///
/// Stopping the agent is NOT what ends a session any more. Since T905/T909 each
/// session's shell lives in its own holder process, which outlives the agent on
/// purpose - and the next agent re-adopts it, so the shell, its scrollback and
/// its pid all come back. That is right for an update and wrong here: the user
/// just confirmed a dialog that said these sessions end. So each one is ended
/// through the agent first, the way the chooser's Kill ends one.
pub const SessionFate = enum {
    /// Ask the agent to end it.
    end,
    /// Nothing to end: already a dead record (a tombstone).
    not_live,
    /// Left running: this app process is inside that session's job (it was
    /// started from that pane), so ending the session would end the app halfway
    /// through its own restart - with the agent not yet stopped.
    hosts_this_app,
};

/// `shares_our_job` is whether the session's shell is a member of the job this
/// app runs in (`job_object.ownJobContains`). Unknown ends the session: the
/// cost of being wrong is the app dying early, which the relaunch guard is
/// already armed to recover from, while keeping a session the user was told
/// would end is the very defect this exists to fix.
pub fn sessionFate(alive: bool, shares_our_job: ?bool) SessionFate {
    if (!alive) return .not_live;
    if (shares_our_job orelse false) return .hosts_this_app;
    return .end;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "prompt: Restart Ghoztty asks only when persistence is off" {
    // Persistence on: the agent keeps every session through the relaunch, so
    // there is nothing to ask whatever the session count.
    try testing.expectEqual(Prompt.none, prompt(.app, true, null));
    try testing.expectEqual(Prompt.none, prompt(.app, true, 12));
    // Persistence off: the shells are the app's own children.
    try testing.expectEqual(Prompt.shells_close, prompt(.app, false, null));
    try testing.expectEqual(Prompt.shells_close, prompt(.app, false, 0));
}

test "prompt: restarting the background sessions asks whenever anything may be lost" {
    try testing.expectEqual(Prompt.sessions_end, prompt(.app_and_agent, true, 3));
    try testing.expectEqual(Prompt.sessions_end, prompt(.app_and_agent, true, 1));
    // Unknown is never zero.
    try testing.expectEqual(Prompt.sessions_end, prompt(.app_and_agent, true, null));
    try testing.expectEqual(Prompt.sessions_end, prompt(.app_and_agent, false, null));
    // Nothing live: nothing to lose from the agent, so only the app's own
    // shells (persistence off) are worth a question.
    try testing.expectEqual(Prompt.none, prompt(.app_and_agent, true, 0));
    try testing.expectEqual(Prompt.shells_close, prompt(.app_and_agent, false, 0));
}

test "sessionsEndText names the count and points at the lossless command" {
    var buf: [512]u8 = undefined;
    const three = sessionsEndText(&buf, 3);
    try testing.expect(std.mem.indexOf(u8, three, "your 3 open terminal sessions") != null);
    try testing.expect(std.mem.indexOf(u8, three, "use Restart Ghoztty instead") != null);

    const one = sessionsEndText(&buf, 1);
    try testing.expect(std.mem.indexOf(u8, one, "your 1 open terminal session ") != null);

    const unknown = sessionsEndText(&buf, null);
    try testing.expect(std.mem.indexOf(u8, unknown, "every open terminal session") != null);
    try testing.expect(std.mem.indexOf(u8, unknown, "{") == null);
}

test "sessionsEndText never truncates silently into a misleading sentence" {
    var tiny: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), sessionsEndText(&tiny, 3).len);
}

test "failedText explains every outcome that did nothing, and only those" {
    try testing.expectEqual(@as(usize, 0), failedText(.quitting).len);
    try testing.expect(std.mem.indexOf(u8, failedText(.not_armed), "Nothing was closed") != null);
    // T3294: the refused agent stop says nothing happened, that the sessions
    // live on, why, and what to do instead.
    const t = failedText(.agent_unstoppable);
    try testing.expect(std.mem.indexOf(u8, t, "nothing was restarted") != null);
    try testing.expect(std.mem.indexOf(u8, t, "Your sessions are still running") != null);
    try testing.expect(std.mem.indexOf(u8, t, "started from inside one of those sessions") != null);
    try testing.expect(std.mem.indexOf(u8, t, "try again") != null);
}

test "sessionFate: the agent restart ends every live session except the one hosting this app" {
    try testing.expectEqual(SessionFate.end, sessionFate(true, false));
    // Unknown membership is not grounds for keeping a session the user was told ends.
    try testing.expectEqual(SessionFate.end, sessionFate(true, null));
    try testing.expectEqual(SessionFate.hosts_this_app, sessionFate(true, true));
    // A tombstone has nothing running to end, whatever its job.
    try testing.expectEqual(SessionFate.not_live, sessionFate(false, null));
    try testing.expectEqual(SessionFate.not_live, sessionFate(false, true));
}

test "only a persistent plain restart claims the sessions kept running" {
    try testing.expectEqual(@as(@TypeOf(reopenReason(.app, true)), .restart), reopenReason(.app, true));
    try testing.expectEqual(@as(@TypeOf(reopenReason(.app, true)), .restart_sessions), reopenReason(.app, false));
    try testing.expectEqual(@as(@TypeOf(reopenReason(.app, true)), .restart_sessions), reopenReason(.app_and_agent, true));
    try testing.expectEqual(@as(@TypeOf(reopenReason(.app, true)), .restart_sessions), reopenReason(.app_and_agent, false));
}
