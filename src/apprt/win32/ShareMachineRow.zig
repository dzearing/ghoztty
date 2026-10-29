//! The "Share this machine" toggle of the win32 machine chooser (T547).
//!
//! The one-installer consolidation (docs/design/one-installer-agent-
//! consolidation.md, decision 2) puts serving in the machine chooser: the
//! account row gains a per-machine toggle that decides whether the LOCAL
//! agent raises its relay uplink and lets the user's other devices open
//! terminals here. The state is the agent's own `sharing.json` (written with
//! the exact code the agent reads it with — `src/remote/agent/sharing.zig`),
//! and the agent reconciles that file every few seconds (T546), so flipping
//! the toggle needs no poke, no Run-key rewrite and no new CLI verb (the T141
//! rule: account affordances are GUI on both platforms).
//!
//! This module owns the ASYNC half, on `RelayAccountRow`'s exact pattern: the
//! first flip on a machine with no device credential runs browser enrollment
//! (`enroll.run`), which blocks for as long as the user takes to finish the
//! relay's consent page — minutes, so it must not run on the GUI thread. The
//! worker posts `WM_APP_SHARE_MACHINE` to the app's message-only window and
//! the outcome routes to whatever chooser is open, or to nobody: sharing.json
//! is the state, not the dialog. Flips that need no browser (credential
//! already present, or turning sharing off) are one small atomic file write
//! and happen synchronously.
//!
//! `MachineChooser` owns the checkbox HWND and the redraw; everything here is
//! either pure (unit-tested labels and sentences) or off-thread.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const MachineChooser = @import("MachineChooser.zig");
const enroll = @import("../../remote/agent/enroll.zig");
const sharing = @import("../../remote/agent/sharing.zig");
const owner_veto = @import("../../remote/agent/owner_veto.zig");
const pending_revoke = @import("../../remote/relay_revoke_pending.zig");
const relay_revoke = @import("../../remote/relay_revoke.zig");
const relay_signin = @import("../../remote/relay_signin.zig");
const w32 = @import("win32.zig");
const utf16_text = @import("utf16_text.zig");

const log = std.log.scoped(.win32);

/// Posted by the enrollment thread to `App.msg_hwnd`. wparam = *Result
/// (ownership transfers to the GUI thread, which frees it in `onResult`).
/// WM_APP+1..+33 are taken (see App.zig's ledger comment).
pub const WM_APP_SHARE_MACHINE: u32 = w32.WM_APP + 34;

/// The outcome of an async flip, allocated on the app allocator by the worker
/// thread and freed by `onResult` on the GUI thread. Every message is a static
/// sentence, so only the struct itself is owned.
pub const Result = struct {
    /// Which flip finished: an enable re-words its success on the GUI thread,
    /// a leave's sentence is final.
    kind: Busy = .enrolling,
    ok: bool,
    /// A short user-facing sentence for the chooser's footer hint.
    message: []const u8,
};

/// What the async half is doing, if anything. Only one flow at a time, in
/// either direction: a tick while the untick's de-enroll is in flight would
/// write the flag over a credential about to be deleted. The guard lives with
/// the work, not the widget: the chooser can be closed and reopened while a
/// flow is still pending, and the reopened one must show the pending state
/// rather than start a second flow.
pub const Busy = enum(u8) {
    idle,
    /// Browser enrollment ahead of a tick: the user's intent is ON.
    enrolling,
    /// Removing this machine from the account after an untick (T2296): the
    /// user's intent is OFF, and sharing.json already says so.
    leaving,
};

var busy: std.atomic.Value(Busy) = .init(.idle);

pub fn isRunning() bool {
    return busy.load(.acquire) != .idle;
}

/// True while a tick's enrollment is pending — the only flow during which the
/// box should read as checked ahead of the file.
pub fn isEnrolling() bool {
    return busy.load(.acquire) == .enrolling;
}

fn claim(kind: Busy) bool {
    return busy.cmpxchgStrong(.idle, kind, .acq_rel, .acquire) == null;
}

fn release() void {
    busy.store(.idle, .release);
}

/// Whether this machine is shared, as the agent will act on it (T1965): the
/// user's explicit on/off when there is one, else "enrolled" — an enrolled
/// machine nobody configured serves (D22 default-on), so the box is ticked.
/// Same `sharing.decide` the agent's reconciler runs, so the checkbox can
/// never show a state the agent is not in.
/// A credential the app found belongs to another account (T2049) counts as
/// none: the agent parks on it, so the box must read unticked.
pub fn isEnabled(alloc: Allocator, config_path: []const u8) bool {
    const has_credential = if (enroll.loadDeviceToken(alloc)) |tok| blk: {
        alloc.free(tok);
        break :blk !owner_veto.isVetoed(alloc);
    } else false;
    return sharing.effectiveEnabled(sharing.loadChoice(alloc, config_path), has_credential);
}

/// What an untick did on the GUI thread. `off`: sharing.json says off and there
/// is no credential to remove. `leaving`: sharing.json says off and the
/// de-enroll is running; the outcome arrives as `WM_APP_SHARE_MACHINE`.
/// `failed`: not even the flag could be written, so nothing changed.
pub const DisableOutcome = enum { off, leaving, failed };

/// Turn sharing OFF, which takes this machine OFF THE ACCOUNT (D100, T2296):
/// the user chose that unticking leaves no "offline" entry on their other
/// devices, the way leaving is signing out on a Mac — which has no
/// enrolled-but-dark state since main 6dfb31232.
///
/// Two halves, in this order. The flag write is synchronous and comes first,
/// so the uplink parks within the reconciler's next poll even when the relay
/// cannot be reached. The de-enroll is network-bound, so it runs on a detached
/// thread; a relay that does not answer arms the same pending revocation a
/// forced sign-out does (T1424), which finishes itself when the network is
/// back. Re-ticking afterwards walks the browser enrollment again — the cost
/// D100 accepted.
pub fn disable(app: *App, relay_base: []const u8, config_path: []const u8) DisableOutcome {
    const alloc = app.core_app.alloc;
    sharing.save(alloc, config_path, .{ .enabled = false }) catch |err| {
        log.warn("share machine: disable write failed err={}", .{err});
        return .failed;
    };

    const has_credential = if (enroll.loadDeviceToken(alloc)) |tok| blk: {
        alloc.free(tok);
        break :blk true;
    } else false;
    if (!has_credential) return .off;

    if (!claim(.leaving)) return .off;
    const job = Job.create(app, relay_base, config_path) orelse {
        release();
        // The flag is written; only the removal did not start. Arm it so it
        // still happens rather than leaving the machine listed.
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        _ = armLeave(arena_state.allocator(), relay_base);
        return .off;
    };
    const thread = std.Thread.spawn(.{}, leaveWorker, .{job}) catch |err| {
        log.warn("share machine: leave thread spawn failed err={}", .{err});
        job.deinit();
        release();
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        _ = armLeave(arena_state.allocator(), relay_base);
        return .off;
    };
    thread.detach();
    return .leaving;
}

/// What removing this machine from the account came to. Pure classification
/// for `leaveMessage`; the worker produces it.
pub const LeaveOutcome = enum {
    /// The relay deleted the device (or no longer knew it) and the local
    /// credential is gone. Nothing lists this machine any more.
    removed,
    /// The relay did not answer. Sharing is off, the credential is kept as the
    /// retry's own record, and the retry finishes it later.
    deferred,
    /// There is no relay this machine's credential could be revoked at.
    stuck,
    /// No credential by the time the worker looked: nothing to remove.
    nothing,
};

/// The sentence for a finished untick. Says what the user's OTHER devices now
/// see, because that is what D100 decided about.
pub fn leaveMessage(outcome: LeaveOutcome) []const u8 {
    return switch (outcome) {
        .removed => removed_hint,
        .deferred => leave_deferred_hint,
        .stuck => leave_stuck_hint,
        .nothing => disabled_hint,
    };
}

fn leaveWorker(job: *Job) void {
    const app = job.app;
    defer job.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const outcome = leave(arena_state.allocator(), job.relay_base, job.config_path);
    log.info("share machine: leave {s}", .{@tagName(outcome)});
    release();
    post(app, .{ .kind = .leaving, .ok = outcome == .removed, .message = leaveMessage(outcome) });
}

/// The untick's network half: de-enroll with the device's own credential, at
/// relay.env's base (falling back to the chooser's), exactly the call sign-out
/// makes (`relay_signin.revokeThisMachine`).
///
/// No whoami first, unlike sign-out. Sign-out revokes only the SIGNING-OUT
/// account's enrollment because the user is leaving an account; an untick is
/// the user at this machine saying it should not be reachable, and a box
/// ticked on another account's enrollment never reads ticked (T2099), so the
/// credential being revoked is the one the box was showing.
fn leave(alloc: Allocator, relay_base: []const u8, config_path: []const u8) LeaveOutcome {
    const env_path = enroll.relayEnvPath(alloc) catch return .stuck;
    var env = enroll.loadRelayEnv(alloc, env_path) catch return armLeave(alloc, relay_base);
    defer env.deinit(alloc);
    const token = env.device_token orelse return .nothing;
    if (token.len == 0) return .nothing;

    const raw_base = relay_revoke.revocationBase(env.relay_base orelse "", relay_base) orelse
        return .stuck;
    const base = relay_revoke.normalizeBase(alloc, raw_base) catch return .stuck;

    _ = enroll.deEnrollStatus(alloc, base, token) catch |err| {
        log.warn("share machine: de-enroll failed err={}; arming the retry", .{err});
        return armLeave(alloc, relay_base);
    };

    // A revocation for this credential that was still armed is moot now.
    clearPendingFor(alloc, token);
    // Back to "follows enrollment": with no credential that is parked and
    // unticked, and the next enrollment (a tick) serves. An explicit off left
    // behind would be the one way to recreate an enrolled-but-dark machine.
    std.fs.cwd().deleteFile(config_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("share machine: could not clear the sharing flag err={}", .{err}),
    };
    return .removed;
}

/// Arm the T1424 retry for the credential in relay.env, marked as an untick's
/// so a later tick may cancel it. Returns the outcome the user is told.
fn armLeave(alloc: Allocator, relay_base: []const u8) LeaveOutcome {
    const env_path = enroll.relayEnvPath(alloc) catch return .stuck;
    var env = enroll.loadRelayEnv(alloc, env_path) catch return .stuck;
    defer env.deinit(alloc);
    const token = env.device_token orelse return .nothing;
    if (token.len == 0) return .nothing;
    const raw_base = relay_revoke.revocationBase(env.relay_base orelse "", relay_base) orelse
        return .stuck;
    const base = relay_revoke.normalizeBase(alloc, raw_base) catch return .stuck;
    pending_revoke.arm(alloc, .{
        .relay_base = base,
        .device_token = token,
        .account_email = relay_signin.signedInEmail(alloc) orelse "",
        .armed_at = std.time.timestamp(),
        .origin = pending_revoke.origin_untick,
    }) catch |err| {
        log.warn("share machine: could not arm the pending removal err={}", .{err});
        return .stuck;
    };
    pending_revoke.retryAsync(alloc);
    return .deferred;
}

/// Clear an armed revocation only when it names `token`: one for an older
/// enrollment is still owed.
fn clearPendingFor(alloc: Allocator, token: []const u8) void {
    var rec = pending_revoke.load(alloc) orelse return;
    defer rec.deinit();
    if (std.mem.eql(u8, rec.value().device_token, token)) pending_revoke.clear(alloc);
}

/// A tick on a machine whose untick is still waiting for the relay: the user
/// changed their mind, so the machine stays on the account and the retry must
/// not remove it later (T2296). A sign-out's revocation is never cancelled
/// here (`pending_revoke.tickCancels`).
fn cancelPendingLeave(alloc: Allocator) void {
    const tok = enroll.loadDeviceToken(alloc) orelse return;
    defer alloc.free(tok);
    var rec = pending_revoke.load(alloc) orelse return;
    defer rec.deinit();
    if (pending_revoke.tickCancels(rec.value(), tok)) {
        log.info("share machine: ticked again before the relay answered; keeping this machine on the account", .{});
        pending_revoke.clear(alloc);
    }
}

/// What a flip to ON did. `enabled` finished synchronously (a credential was
/// already on disk); `enrolling` started the browser flow and the caller
/// shows the pending state until `WM_APP_SHARE_MACHINE` lands; `busy` means a
/// flow is already pending; `failed` could not even start; `not_ours` refused
/// because the credential belongs to another account (T2099).
pub const StartOutcome = enum { enabled, enrolling, busy, failed, not_ours };

/// What a flip to ON should do, given relay.env's credential. Pure (T2099).
pub const EnablePlan = enum {
    /// A credential this app may serve: persist `enabled = true`.
    write_flag,
    /// No credential: browser enrollment first.
    enroll,
    /// The credential belongs to another account (the T2049 veto holds). The
    /// agent parks on it whatever sharing.json says, so writing the flag would
    /// be a box that springs back. Mac's rule is that a guest does not serve
    /// another account's enrollment, and it has no affordance that takes one
    /// over, so neither does this: refuse, and say whose it is.
    refuse_not_ours,
};

pub fn enablePlan(has_credential: bool, vetoed: bool) EnablePlan {
    if (!has_credential) return .enroll;
    return if (vetoed) .refuse_not_ours else .write_flag;
}

/// Turn sharing ON. With a device credential already in relay.env this is
/// the same synchronous write `disable` does; without one it starts browser
/// enrollment on a detached thread (`relay_base` is the chooser's resolved
/// base). Safe to call from the GUI thread.
pub fn enableAsync(
    app: *App,
    relay_base: []const u8,
    config_path: []const u8,
) StartOutcome {
    const alloc = app.core_app.alloc;

    const has_credential = if (enroll.loadDeviceToken(alloc)) |tok| blk: {
        alloc.free(tok);
        break :blk true;
    } else false;
    const vetoed = has_credential and owner_veto.isVetoed(alloc);

    switch (enablePlan(has_credential, vetoed)) {
        .refuse_not_ours => {
            log.info("share machine: enable refused; the credential belongs to another account", .{});
            return .not_ours;
        },
        // Credential already present: no browser, just persist the flag. The
        // token's presence is the same test the agent's reconciler applies.
        .write_flag => {
            cancelPendingLeave(alloc);
            sharing.save(alloc, config_path, .{ .enabled = true }) catch |err| {
                log.warn("share machine: enable write failed err={}", .{err});
                return .failed;
            };
            return .enabled;
        },
        .enroll => {},
    }

    if (!claim(.enrolling)) {
        log.info("share machine: a sharing flow is already running; ignoring", .{});
        return .busy;
    }

    const job = Job.create(app, relay_base, config_path) orelse {
        release();
        return .failed;
    };

    const thread = std.Thread.spawn(.{}, worker, .{job}) catch |err| {
        job.deinit();
        release();
        log.warn("share machine: thread spawn failed err={}", .{err});
        return .failed;
    };
    thread.detach();
    return .enrolling;
}

/// The worker's arguments — owned copies, because the chooser (and its arena,
/// where `relay_base` lives) can be destroyed while the browser flow runs.
const Job = struct {
    app: *App,
    relay_base: []u8,
    config_path: []u8,

    fn create(app: *App, relay_base: []const u8, config_path: []const u8) ?*Job {
        const alloc = app.core_app.alloc;
        const job = alloc.create(Job) catch return null;
        const base = alloc.dupe(u8, relay_base) catch {
            alloc.destroy(job);
            return null;
        };
        const cfg = alloc.dupe(u8, config_path) catch {
            alloc.free(base);
            alloc.destroy(job);
            return null;
        };
        job.* = .{ .app = app, .relay_base = base, .config_path = cfg };
        return job;
    }

    fn deinit(self: *Job) void {
        const alloc = self.app.core_app.alloc;
        alloc.free(self.relay_base);
        alloc.free(self.config_path);
        alloc.destroy(self);
    }
};

fn worker(job: *Job) void {
    const app = job.app;
    defer job.deinit();

    // The flow's own scratch memory: page-backed so it never touches the GUI
    // thread's allocator from off-thread.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const outcome: Result = blk: {
        var host_buf: [256]u8 = undefined;
        const name = hostName(&host_buf) orelse "unknown-host";
        if (enroll.run(arena, job.relay_base, name, .{})) {
            // Enrollment persisted relay.env; now persist the flag the agent
            // reconciles on. A write failure here must NOT read as enabled.
            if (sharing.save(arena, job.config_path, .{ .enabled = true })) {
                break :blk .{ .ok = true, .message = enabled_hint };
            } else |err| {
                log.warn("share machine: post-enroll enable write failed err={}", .{err});
                break :blk .{ .ok = false, .message = save_failed_hint };
            }
        } else |err| {
            log.warn("share machine: enrollment failed err={}", .{err});
            break :blk .{ .ok = false, .message = errorMessage(err) };
        }
    };

    // Free the guard BEFORE the GUI thread hears about it, so the refresh the
    // result triggers already sees the box idle and enabled.
    release();
    post(app, outcome);
}

/// Hand a finished flow's outcome to the GUI thread.
fn post(app: *App, outcome: Result) void {
    const alloc = app.core_app.alloc;
    const res = alloc.create(Result) catch return;
    res.* = outcome;

    const hwnd = app.msg_hwnd orelse {
        alloc.destroy(res);
        return;
    };
    if (w32.PostMessageW(hwnd, WM_APP_SHARE_MACHINE, @intFromPtr(res), 0) == 0) {
        alloc.destroy(res);
    }
}

/// GUI thread (App's message-only WndProc): apply an enrollment outcome. Owns
/// `res`. A closed chooser is not an error — sharing.json already changed, and
/// the next chooser open reads it.
pub fn onResult(app: *App, res: *Result) void {
    defer app.core_app.alloc.destroy(res);
    log.info("share machine: {s} {s}", .{ @tagName(res.kind), if (res.ok) "ok" else "failed" });
    if (openChooser(app)) |chooser| chooser.onShareResult(res);
}

/// The first open machine chooser across all windows, if any (the same
/// routing `RelayAccountRow.onResult` uses).
fn openChooser(app: *App) ?*MachineChooser {
    for (app.windows.items) |win| {
        if (win.machine_chooser) |chooser| return chooser;
    }
    return null;
}

/// This machine's name for the relay's device list: the DNS hostname
/// (preserves case, matches what the agent advertises in its HELLO) rather
/// than %COMPUTERNAME%'s uppercased NetBIOS name.
fn hostName(out: []u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        var wbuf: [256]u16 = undefined;
        var size: u32 = wbuf.len;
        // 1 == ComputerNameDnsHostname
        if (kernel32.GetComputerNameExW(1, &wbuf, &size) == 0) return null;
        // All or nothing (T990): half a host name is a different machine, and
        // the plain `std.unicode.utf16LeToUtf8` this used to call panicked on
        // a short `out` rather than erroring — the `catch` could not see it.
        const n = utf16_text.toUtf8AllOrNothing(out, wbuf[0..size]);
        return if (n == 0) null else out[0..n];
    } else {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const name = std.posix.gethostname(&buf) catch return null;
        if (name.len == 0 or name.len > out.len) return null;
        @memcpy(out[0..name.len], name);
        return out[0..name.len];
    }
}

const kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetComputerNameExW(
        NameType: c_int,
        lpBuffer: [*]u16,
        nSize: *u32,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

// ---------------------------------------------------------------------
// Pure presentation (unit-tested; the chooser renders these verbatim)
// ---------------------------------------------------------------------

/// The checkbox caption. Constant across states — a checkbox that renames
/// itself reads as a different setting; the STATE is the check mark and the
/// footer hint carries the news.
pub const label = "Share this machine";

/// Footer hints for the flips that finish synchronously, and for the pending
/// browser flow. The chooser shows these verbatim in its status strip.
pub const enabled_hint =
    "Sharing is on — your other devices can open terminals on this machine.";
pub const disabled_hint = "Sharing is off.";
/// An untick that removed this machine from the account (D100).
pub const removed_hint =
    "Sharing is off — this machine was removed from your account, so your other devices no longer list it. Tick the box to add it again.";
/// Shown while the removal is in flight.
pub const leaving_hint = "Removing this machine from your account…";
/// The relay could not be reached: sharing is off now, the removal is owed.
pub const leave_deferred_hint =
    "Sharing is off. This machine will be removed from your account as soon as the relay can be reached.";
pub const leave_stuck_hint =
    "Sharing is off, but this machine couldn't be removed from your account. Signing out removes it.";
pub const pending_hint =
    "Finish adding this machine in your browser — sharing turns on once it's approved.";
pub const save_failed_hint =
    "Couldn't save the sharing setting. Check that the agent's data folder is writable.";

/// Why the box would not tick (T2099): this machine was added to the relay by
/// another account. Names that account when the record says who it is, and
/// what would let the user share it. Pure; writes into `buf` and falls back to
/// the nameless sentence when the name does not fit.
pub fn notOursHint(buf: []u8, owner_email: []const u8) []const u8 {
    if (owner_email.len > 0) {
        if (std.fmt.bufPrint(
            buf,
            "This machine is shared from {s}'s account, so it can't be shared from yours. Sign in as {s} to change its sharing.",
            .{ owner_email, owner_email },
        )) |s| return s else |_| {}
    }
    return not_ours_hint;
}

pub const not_ours_hint =
    "This machine is shared from another account, so it can't be shared from yours. Sign in with that account to change its sharing.";

/// The same "sharing is on" news, for a machine whose background terminal
/// process is an OLDER build than the one this app ships beside — one that
/// predates the `sharing.json` reconciler (T546) and so will never act on the
/// flag the toggle just wrote.
///
/// This is the ordinary state, not an error: the app and the agent have separate
/// lifetimes by design, and a stale agent hands itself over to the newer build
/// once its sessions allow it. What must not happen is the checkbox reading ON
/// over a machine that is serving nothing, with no hint of why (T889).
pub const enabled_pending_agent_hint =
    "Sharing is on — this machine starts serving once its background terminal process finishes the update that's already waiting.";

/// What the RUNNING agent can be known to do about `sharing.json`.
pub const Reconciler = enum {
    /// The connected agent advertised the reconciler: flipping the file is
    /// enough, and sharing is live within seconds.
    ready,
    /// The connected agent predates the reconciler. Sharing is persisted and
    /// will start when that agent is replaced by the build beside this app.
    pending_update,
    /// Nobody to ask — no warm agent connection (persistence off, or the agent
    /// has not come up). Say nothing extra rather than guess.
    unknown,
};

/// Classify what `LocalAgent.reconcilesSharing` answered. Null — no agent to
/// judge — is `unknown`, never `pending_update`: a warning invented from a
/// missing answer is worse than the plain sentence.
pub fn reconciler(reconciles: ?bool) Reconciler {
    const r = reconciles orelse return .unknown;
    return if (r) .ready else .pending_update;
}

/// The footer sentence for a flip that has just persisted `enabled = true`.
/// Only a KNOWN-old agent changes it: `unknown` reads exactly as `ready`, so a
/// box with persistence off sees the sentence it always saw.
pub fn enabledHint(state: Reconciler) []const u8 {
    return switch (state) {
        .pending_update => enabled_pending_agent_hint,
        .ready, .unknown => enabled_hint,
    };
}

/// A user-facing sentence for a failed enrollment. Mirrors the tone of
/// `relay_signin.errorMessage`: what happened and what to do, no error codes.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EnrollDenied => "The browser request was declined. Flip the switch again to retry.",
        error.EnrollExpired => "The browser link expired before it was approved. Flip the switch again to retry.",
        error.EnrollUnavailable => "This relay has no sign-in configured, so machines can't be added to it.",
        error.EnrollRefused, error.EnrollRejected => "The relay refused to add this machine. Try again, or check the relay's account settings.",
        else => "Couldn't reach the relay to add this machine. Check your connection and flip the switch again.",
    };
}

/// Whether the checkbox should read as CHECKED for a given (persisted,
/// pending) pair. While enrollment runs the user's intent is ON, so the box
/// stays checked and disabled rather than snapping back and re-checking
/// itself minutes later.
pub fn boxChecked(persisted: bool, pending: bool) bool {
    return persisted or pending;
}

const testing = std.testing;

test "boxChecked: pending keeps the user's intent visible" {
    try testing.expect(boxChecked(true, false));
    try testing.expect(boxChecked(false, true));
    try testing.expect(boxChecked(true, true));
    try testing.expect(!boxChecked(false, false));
}

test "errorMessage: every enrollment failure has a plain sentence" {
    // Each named failure mode gets its own remedy, and anything else still
    // produces a sentence rather than an error name.
    for ([_]anyerror{
        error.EnrollDenied,
        error.EnrollExpired,
        error.EnrollUnavailable,
        error.EnrollRefused,
        error.EnrollRejected,
        error.ConnectionRefused,
    }) |err| {
        const msg = errorMessage(err);
        try testing.expect(msg.len > 0);
        try testing.expect(std.mem.indexOf(u8, msg, "error.") == null);
    }
    // Denied and expired both say how to recover: flip again.
    try testing.expect(std.mem.indexOf(u8, errorMessage(error.EnrollDenied), "again") != null);
    try testing.expect(std.mem.indexOf(u8, errorMessage(error.EnrollExpired), "again") != null);
}

test "reconciler: only a known-old agent is pending; no answer is not a warning" {
    try testing.expectEqual(Reconciler.ready, reconciler(true));
    try testing.expectEqual(Reconciler.pending_update, reconciler(false));
    try testing.expectEqual(Reconciler.unknown, reconciler(null));
}

test "enabledHint: a stale agent is the only state that changes the sentence" {
    try testing.expectEqualStrings(enabled_hint, enabledHint(.ready));
    try testing.expectEqualStrings(enabled_hint, enabledHint(.unknown));
    try testing.expectEqualStrings(enabled_pending_agent_hint, enabledHint(.pending_update));
}

test "enabled_pending_agent_hint: says sharing is on AND why nothing is served yet" {
    // The user's intent is honored (the box stays checked), so the sentence must
    // not read as a failure - and it must name the wait, or the checkbox lies.
    try testing.expect(std.mem.indexOf(u8, enabled_pending_agent_hint, "Sharing is on") != null);
    try testing.expect(std.mem.indexOf(u8, enabled_pending_agent_hint, "update") != null);
    // No mechanism in front of the user: no task ids, no capability strings.
    try testing.expect(std.mem.indexOf(u8, enabled_pending_agent_hint, "T546") == null);
    try testing.expect(std.mem.indexOf(u8, enabled_pending_agent_hint, "sharing.json") == null);
    // It is a DIFFERENT sentence, or the negative control could never fail.
    try testing.expect(!std.mem.eql(u8, enabled_pending_agent_hint, enabled_hint));
}

test "enablePlan: another account's credential is refused, never written (T2099)" {
    try testing.expectEqual(EnablePlan.write_flag, enablePlan(true, false));
    try testing.expectEqual(EnablePlan.refuse_not_ours, enablePlan(true, true));
    try testing.expectEqual(EnablePlan.enroll, enablePlan(false, false));
    // A veto with no credential names nothing: enrollment as usual.
    try testing.expectEqual(EnablePlan.enroll, enablePlan(false, true));
}

test "notOursHint: names the owning account and the way out" {
    var buf: [512]u8 = undefined;
    const s = notOursHint(&buf, "a@example.com");
    try testing.expect(std.mem.indexOf(u8, s, "a@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Sign in") != null);
    try testing.expect(std.mem.indexOf(u8, s, "owner-mismatch") == null);
    // No name, or no room for it: the nameless sentence, still with the remedy.
    try testing.expectEqualStrings(not_ours_hint, notOursHint(&buf, ""));
    var tiny: [16]u8 = undefined;
    try testing.expectEqualStrings(not_ours_hint, notOursHint(&tiny, "a@example.com"));
    try testing.expect(std.mem.indexOf(u8, not_ours_hint, "another account") != null);
}

test "leaveMessage: an untick says what the other devices now see (D100, T2296)" {
    // Removed: the machine is off the account, and the way back is a tick.
    const removed = leaveMessage(.removed);
    try testing.expect(std.mem.indexOf(u8, removed, "removed from your account") != null);
    try testing.expect(std.mem.indexOf(u8, removed, "other devices") != null);
    // Deferred is honest that the removal has not happened YET.
    const deferred = leaveMessage(.deferred);
    try testing.expect(std.mem.indexOf(u8, deferred, "as soon as") != null);
    try testing.expect(!std.mem.eql(u8, removed, deferred));
    // Stuck names the way out.
    try testing.expect(std.mem.indexOf(u8, leaveMessage(.stuck), "Signing out") != null);
    // Every outcome says sharing is off; none leaks mechanism.
    for ([_]LeaveOutcome{ .removed, .deferred, .stuck, .nothing }) |o| {
        const m = leaveMessage(o);
        try testing.expect(std.mem.startsWith(u8, m, "Sharing is off"));
        for ([_][]const u8{ "relay.env", "credential", "de-enroll", "token" }) |word| {
            try testing.expect(std.mem.indexOf(u8, m, word) == null);
        }
    }
    // The old sentence promised the machine stayed enrolled; it must not.
    try testing.expect(std.mem.indexOf(u8, disabled_hint, "keeps") == null);
}

test "Busy: only an enrollment reads as a pending tick" {
    try testing.expect(!isRunning());
    try testing.expect(claim(.leaving));
    try testing.expect(isRunning());
    try testing.expect(!isEnrolling());
    // One flow at a time, in either direction.
    try testing.expect(!claim(.enrolling));
    release();
    try testing.expect(claim(.enrolling));
    try testing.expect(isEnrolling());
    release();
    try testing.expect(!isRunning());
}

test "hints: the toggle's sentences say what changed for the user" {
    try testing.expect(std.mem.indexOf(u8, enabled_hint, "other devices") != null);
    try testing.expect(std.mem.indexOf(u8, disabled_hint, "off") != null);
    try testing.expect(std.mem.indexOf(u8, pending_hint, "browser") != null);
    try testing.expectEqualStrings("Share this machine", label);
}
