//! Non-destructive local-agent upgrade for the GTK app (T3600, Linux L8f) -
//! the port of win32's `refreshLocalAgentIfStale` / `handleAgentProtocolSkew`
//! (T147, T125, T1056) and the Mac's `refreshLocalAgentIfStale`.
//!
//! The agent outlives the app on purpose, so after an update the RUNNING
//! agent can be an older build than the one now on disk. Two cases:
//!
//!  - **An older build** (the HELLO stamp vs `ghoztty-agent --version`). With
//!    no live session it is restarted at once, silently, and every pane that
//!    rode it is rebuilt in place on the fresh agent (the `AgentRecovery`
//!    path). With live sessions it is left strictly alone (T1056): the agent
//!    already agreed the wire contract, so ending sessions buys nothing. The
//!    check runs again when the last window closes.
//!  - **A protocol skew** (the handshake failed against a live agent). Agent
//!    older: the mandatory-update dialog asks before restarting it, because
//!    its sessions cannot be reached to save them. App older: the user is
//!    told the app is out of date, and nothing is touched.
//!
//! The leave-alone case is not invisible (T3691, win32's T1068): while an
//! update waits, `app.install-agent-update` is enabled, which shows the main
//! menu's "Background Update Ready…" row and the palette's "Install Background
//! Process Update…" entry. Choosing either re-checks, then asks (Later is the
//! default) before restarting the agent and rebuilding the panes in place.
//! Log lines: `agent update affordance: shown|cleared`, `agent update offer: ...`.
//!
//! Every DECISION is win32's pure `agent_upgrade.zig`; `agent_upgrade_rules`
//! maps it onto this app. Log lines (the acceptance reads them):
//! `agent upgrade check: <reason> ...`, `local agent refreshed ...`,
//! `agent upgrade: showing mandatory protocol-skew confirmation`,
//! `agent upgrade: the user chose ...`, `agent upgrade: app-older notice`.
//!
//! GTK main thread only.

const std = @import("std");
const builtin = @import("builtin");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const agent_upgrade = @import("../win32/agent_upgrade.zig");
const protocol = @import("../../remote/protocol.zig");
const rules = @import("agent_upgrade_rules.zig");
const AgentRecovery = @import("AgentRecovery.zig");
const Application = @import("class/application.zig").Application;

const log = std.log.scoped(.gtk_agent_upgrade);

/// How long the session probe may take.
const roster_timeout_ns: u64 = 2 * std.time.ns_per_s;

var started = false;
var idle_pending = false;
var pending_reason: []const u8 = "launch";
var attempts: usize = 0;
/// The user said Later to the skew dialog: not asked again this run.
var declined = false;
var dialog_up = false;
/// The app-older notice is sent once per run.
var app_older_told = false;
/// A newer agent build is installed and waiting (T3691; win32's
/// `agent_update_pending`, T1068): the last settling check found a stale agent
/// it left alone for live sessions. Drives `app.install-agent-update`'s
/// enabled state, which shows the main-menu row and the palette entry.
var pending: ?agent_upgrade.Pending = null;
var install_dialog_up = false;

/// The waiting update, or null. Read by the palette when it opens.
pub fn pendingUpdate(app: *Application) ?agent_upgrade.Pending {
    const cfg = app.getConfig();
    defer cfg.unref();
    if (!cfg.get().@"session-persistence") return null;
    return pending;
}

/// Show or retire the row. Logged on a CHANGE only (win32's wording), so the
/// line marks the moment it appeared or went away.
fn setPending(app: *Application, p: ?agent_upgrade.Pending) void {
    if (pending == p) return;
    pending = p;
    if (p) |v| {
        log.info("agent update affordance: shown ({s}); a newer background process is waiting", .{@tagName(v)});
    } else {
        log.info("agent update affordance: cleared", .{});
    }
    syncAction(app);
}

/// Match `app.install-agent-update`'s enabled state to the waiting update.
/// Called once at startup (disabled) and on every change.
pub fn syncAction(app: *Application) void {
    const action = app.as(gio.ActionMap).lookupAction(rules.install_action) orelse return;
    const simple = gobject.ext.cast(gio.SimpleAction, action) orelse return;
    simple.setEnabled(@intFromBool(pending != null));
}

/// The row or the palette entry was chosen (win32's `offerAgentUpdate`). The
/// check runs again first - the row reflects the LAST check, and the sessions
/// may all have closed since, in which case the re-check refreshes silently
/// and no dialog is needed. Otherwise ask, Later the default; on Restart Now
/// the agent is restarted and every pane rebuilt in place.
pub fn offerUpdate(app: *Application) void {
    if (install_dialog_up) return;
    check(app, "menu: background update");
    const p = pendingUpdate(app) orelse {
        log.info("agent update offer: nothing waiting any more (the re-check settled it)", .{});
        return;
    };
    const la = &app.rt().local_agent;
    const live: ?usize = if (sessionMix(la)) |m| m.live else null;
    log.info("agent update offer: asking (pending={s} live={?d})", .{ @tagName(p), live });

    var text_buf: [1024]u8 = undefined;
    const text = rules.installNowTextInPlace(&text_buf, p, live);
    if (text.len == 0) return;
    var text_z: [1100]u8 = undefined;
    const detail = std.fmt.bufPrintZ(&text_z, "{s}", .{text}) catch return;

    var labels: [rules.install_buttons.len + 1]?[*:0]const u8 = undefined;
    inline for (rules.install_buttons, 0..) |l, i| labels[i] = l.ptr;
    labels[rules.install_buttons.len] = null;

    const dialog = gobject.ext.newInstance(gtk.AlertDialog, .{});
    defer dialog.unref();
    dialog.setMessage(agent_upgrade.install_now_title);
    dialog.setDetail(detail.ptr);
    dialog.setModal(1);
    dialog.setButtons(@ptrCast(&labels));
    dialog.setDefaultButton(@intCast(rules.skew_default_index));
    dialog.setCancelButton(@intCast(rules.skew_cancel_index));

    const parent = app.as(gtk.Application).getActiveWindow();
    const cancellable = gio.Cancellable.new();
    defer cancellable.unref();
    install_dialog_up = true;
    dialog.choose(parent, cancellable, installDialogDone, null);
    dialogSeam(
        &install_scripted,
        "GHOZTTY_TEST_AGENT_UPDATE_DIALOG",
        "GHOZTTY_TEST_AGENT_UPDATE_ANSWER",
        agent_upgrade.install_now_title,
        &rules.install_buttons,
        text,
        cancellable,
    );
}

var install_scripted: ?rules.Answer = null;

fn installDialogDone(source: ?*gobject.Object, result: *gio.AsyncResult, _: ?*anyopaque) callconv(.c) void {
    install_dialog_up = false;
    const dialog: *gtk.AlertDialog = @ptrCast(@alignCast(source orelse return));
    var err: ?*glib.Error = null;
    const index = dialog.chooseFinish(result, &err);
    var chosen: ?usize = null;
    if (err) |e| e.free() else if (index >= 0) chosen = @intCast(index);
    const answer = if (install_scripted) |s| s else rules.answerFor(chosen);
    install_scripted = null;
    const app = Application.default();
    switch (answer) {
        .later => log.info("agent update offer: user chose Later; the update keeps waiting", .{}),
        .restart => {
            log.warn("agent update offer: user chose to install now, restarting the background process", .{});
            const la = &app.rt().local_agent;
            _ = la.restartForUpgrade();
            AgentRecovery.recover(app, "agent update (installed now)");
            if (la.hasSharedConnection()) {
                setPending(app, null);
                log.info("local agent restarted onto the bundled build at the user's request", .{});
            } else log.warn("agent update offer: no agent came up after the restart", .{});
        },
    }
}

/// Hook the launch check onto the local agent's first resolve. Idempotent.
pub fn start(app: *Application) void {
    if (started) return;
    started = true;
    app.rt().local_agent.on_resolved = onResolved;
    // A resolve that already happened (the restore dialed before this) is
    // checked now.
    const la = &app.rt().local_agent;
    if (la.hasSharedConnection() or la.protocolSkew() != null) schedule("launch");
}

/// The last window closed: a quiet moment, where a stale agent may have
/// nothing live left (win32 re-runs its check at the same moment).
pub fn lastWindowClosed() void {
    if (!started) return;
    // A beat later, not on idle: the closed panes' sessions are ended by
    // their teardown, and the roster must be read after it.
    _ = glib.timeoutAdd(last_window_delay_ms, lastWindowTimer, null);
}

const last_window_delay_ms: c_uint = 500;

fn lastWindowTimer(_: ?*anyopaque) callconv(.c) c_int {
    check(Application.default(), "last window closed");
    return 0;
}

/// `LocalAgent.on_resolved`: never check from inside a pane build.
fn onResolved() void {
    schedule("launch");
}

fn schedule(reason: []const u8) void {
    pending_reason = reason;
    if (idle_pending) return;
    idle_pending = true;
    _ = glib.idleAdd(checkIdle, null);
}

fn checkIdle(_: ?*anyopaque) callconv(.c) c_int {
    idle_pending = false;
    check(Application.default(), pending_reason);
    return 0;
}

/// The whole check (win32's `refreshLocalAgentIfStale`).
pub fn check(app: *Application, reason: []const u8) void {
    if (app.isQuitting()) return;
    const cfg = app.getConfig();
    defer cfg.unref();
    if (!cfg.get().@"session-persistence") return;
    const la = &app.rt().local_agent;

    // A skew is checked first: it is the one stale state with no connection
    // left to judge (win32's T125 ordering).
    if (la.protocolSkew()) |skew| return handleSkew(app, skew, reason);

    if (!la.hasSharedConnection()) {
        log.debug("agent upgrade check: no shared agent connection, nothing to judge [{s}]", .{reason});
        return;
    }
    if (attempts >= rules.max_attempts) {
        log.info("agent upgrade check: attempt ceiling reached ({d}/{d}), not retrying this run [{s}]", .{ attempts, rules.max_attempts, reason });
        return;
    }

    const bundled = la.bundledVersion();
    const running = la.runningVersion();
    // Liveness is asked of the AGENT, never of this app's window list; an
    // unknown answer is never grounds for a restart.
    var mix = sessionMix(la) orelse {
        log.info("agent upgrade check skipped: agent session liveness unknown [{s}]", .{reason});
        return;
    };
    // A pane whose OPEN is still in flight is live too: only ever RAISE the
    // count from this app's own panes, never lower it.
    mix.live = @max(mix.live, AgentRecovery.panesOn(app, la.shared.?.conn));
    const decision = agent_upgrade.evaluate(running, bundled, mix.live, .{
        .capable = mix.handoff_capable,
        .legacy_live = mix.legacy,
    });
    log.info("agent upgrade check: {s} (running {s}, bundled {s}, {d} live session(s)) [{s}]", .{
        decision.reason.description(),
        agent_upgrade.stampForLog(running),
        agent_upgrade.stampForLog(bundled),
        mix.live,
        reason,
    });
    setPending(app, rules.nextPending(pending, decision.reason));

    switch (rules.planFor(decision, false)) {
        .nothing => {},
        .refuse => log.err("agent upgrade check: a stale BUILD asked to end {d} live session(s) ({s}); refusing", .{ mix.live, @tagName(decision.reason) }),
        .refresh => {
            attempts += 1;
            _ = la.restartForUpgrade();
            // Through the recovery path, not a bare re-dial: "no LIVE
            // sessions" still allows panes full of tombstones, and those are
            // re-ATTACHed onto the new agent rather than left on a retired
            // connection. With no windows it is exactly a re-dial.
            AgentRecovery.recover(app, "agent upgrade");
            log.info("local agent refreshed to bundled build {s} (idle, no live sessions affected)", .{bundled orelse "?"});
        },
        // Skew-only arms; `planFor(_, false)` never returns them.
        .ask_restart, .notify_app_older => log.err("agent upgrade check: a build-gap decision mapped to a skew arm ({s}); ignoring", .{@tagName(decision.reason)}),
    }
}

const Mix = struct { live: usize, legacy: usize, handoff_capable: bool };

fn sessionMix(la: anytype) ?Mix {
    const d = la.shared orelse return null;
    const conn = d.conn;
    var roster = conn.requestSessions(roster_timeout_ns) catch |err| {
        log.warn("agent upgrade check: session probe failed err={} (treating as unknown)", .{err});
        return null;
    };
    defer roster.deinit();
    var live: usize = 0;
    var legacy: usize = 0;
    for (roster.sessions) |s| {
        if (!s.alive) continue;
        live += 1;
        if (!s.holder_backed) legacy += 1;
    }
    return .{ .live = live, .legacy = legacy, .handoff_capable = conn.peerHandsOffItself() };
}

/// The mandatory-update path (win32's `handleAgentProtocolSkew`).
fn handleSkew(app: *Application, skew: anytype, reason: []const u8) void {
    const decision = agent_upgrade.evaluateSkew(skew.peer_proto_version, protocol.proto_version);
    log.info("agent upgrade check: {s} (agent protocol {?d}, this app {d}) [{s}]", .{
        decision.reason.description(), skew.peer_proto_version, protocol.proto_version, reason,
    });
    switch (rules.planFor(decision, true)) {
        .nothing => return,
        .refuse => {
            log.err("agent upgrade check: a protocol skew asked for a non-consensual restart ({s}); refusing", .{@tagName(decision.action)});
            return;
        },
        .notify_app_older => return notifyAppOlder(app, skew.peer_proto_version),
        // Build-gap-only arm; a skew is never restarted without consent.
        .refresh => {
            log.err("agent upgrade check: a protocol skew mapped to a silent refresh; refusing", .{});
            return;
        },
        .ask_restart => {},
    }
    if (declined) {
        log.info("local agent still protocol-skewed, but the user deferred this run [{s}]", .{reason});
        return;
    }
    if (dialog_up) return;
    if (attempts >= rules.max_attempts) {
        log.info("agent upgrade check: attempt ceiling reached ({d}/{d}), not retrying this run [{s}]", .{ attempts, rules.max_attempts, reason });
        return;
    }
    askRestart(app, skew.peer_proto_version);
}

fn askRestart(app: *Application, peer: ?u16) void {
    var text_buf: [1024]u8 = undefined;
    const text = agent_upgrade.formatSkewConfirmText(&text_buf, peer, protocol.proto_version) catch return;
    var text_z: [1100]u8 = undefined;
    const detail = std.fmt.bufPrintZ(&text_z, "{s}", .{text}) catch return;

    var labels: [rules.skew_buttons.len + 1]?[*:0]const u8 = undefined;
    inline for (rules.skew_buttons, 0..) |l, i| labels[i] = l.ptr;
    labels[rules.skew_buttons.len] = null;

    const dialog = gobject.ext.newInstance(gtk.AlertDialog, .{});
    defer dialog.unref(); // `choose`'s task keeps its own reference
    dialog.setMessage(agent_upgrade.skew_confirm_title);
    dialog.setDetail(detail.ptr);
    dialog.setModal(1);
    dialog.setButtons(@ptrCast(&labels));
    dialog.setDefaultButton(@intCast(rules.skew_default_index));
    dialog.setCancelButton(@intCast(rules.skew_cancel_index));

    const parent = app.as(gtk.Application).getActiveWindow();
    const cancellable = gio.Cancellable.new();
    defer cancellable.unref();
    dialog_up = true;
    log.info("agent upgrade: showing mandatory protocol-skew confirmation; waiting for the user", .{});
    dialog.choose(parent, cancellable, dialogDone, null);
    dialogSeam(
        &scripted,
        "GHOZTTY_TEST_AGENT_SKEW_DIALOG",
        "GHOZTTY_TEST_AGENT_SKEW_ANSWER",
        agent_upgrade.skew_confirm_title,
        &rules.skew_buttons,
        text,
        cancellable,
    );
}

/// Debug-only: a headless run cannot click. Record that the dialog is up
/// (title, buttons, text on one line) to the file `$<file_env>`, then end it
/// through its cancellable and answer for the user from `$<answer_env>`
/// (`restart`, else Later) through `answer_out`, set before the cancel since
/// the dialog's callback reads it.
var scripted: ?rules.Answer = null;

fn dialogSeam(
    answer_out: *?rules.Answer,
    comptime file_env: []const u8,
    comptime answer_env: []const u8,
    title: []const u8,
    buttons: []const [:0]const u8,
    text: []const u8,
    cancellable: *gio.Cancellable,
) void {
    if (comptime builtin.mode != .Debug) return;
    const path = std.posix.getenv(file_env) orelse return;
    if (std.fs.cwd().createFile(path, .{ .truncate = false })) |file| {
        defer file.close();
        file.seekFromEnd(0) catch {};
        var buf: [2048]u8 = undefined;
        var w = file.writer(&buf);
        const out = &w.interface;
        out.print("shown {s}|", .{title}) catch {};
        for (buttons, 0..) |l, i| out.print("{s}{s}", .{ if (i == 0) "" else ",", l }) catch {};
        out.writeAll("|") catch {};
        for (text) |c| out.writeByte(if (c == '\n') ' ' else c) catch {};
        out.writeAll("\n") catch {};
        out.flush() catch {};
    } else |_| {}
    answer_out.* = rules.scriptedAnswer(std.posix.getenv(answer_env));
    cancellable.cancel();
}

fn dialogDone(source: ?*gobject.Object, result: *gio.AsyncResult, _: ?*anyopaque) callconv(.c) void {
    dialog_up = false;
    const dialog: *gtk.AlertDialog = @ptrCast(@alignCast(source orelse return));
    var err: ?*glib.Error = null;
    const index = dialog.chooseFinish(result, &err);
    var chosen: ?usize = null;
    if (err) |e| e.free() else if (index >= 0) chosen = @intCast(index);
    const answer = if (scripted) |s| s else rules.answerFor(chosen);
    scripted = null;
    const app = Application.default();
    switch (answer) {
        .later => {
            declined = true;
            log.info("agent upgrade: the user chose Later; new panes run without session persistence this run", .{});
        },
        .restart => {
            log.warn("agent upgrade: the user chose to restart the background process across the protocol skew", .{});
            attempts += 1;
            _ = app.rt().local_agent.restartForUpgrade();
            AgentRecovery.recover(app, "agent upgrade (protocol skew)");
            if (app.rt().local_agent.hasSharedConnection())
                log.info("local agent restarted onto the bundled build after the protocol skew", .{})
            else
                log.warn("agent upgrade: no agent came up after the skew restart", .{});
        },
    }
}

/// The other direction (win32's T626): the APP is the out-of-date side. Never
/// acts; says so once, so persistence going quiet is not invisible.
fn notifyAppOlder(app: *Application, peer: ?u16) void {
    if (app_older_told) return;
    app_older_told = true;
    log.warn("agent upgrade: app-older notice (agent protocol {?d}, this app {d}); sessions are not being kept", .{ peer, protocol.proto_version });
    const n = gio.Notification.new(agent_upgrade.app_older_notice_title);
    defer n.unref();
    // Linux's own body: win32's promises a click-to-update this toast has no
    // updater behind (T3691).
    n.setBody(rules.app_older_body_linux);
    app.as(gio.Application).sendNotification("ghoztty-agent-app-older", n);
}
