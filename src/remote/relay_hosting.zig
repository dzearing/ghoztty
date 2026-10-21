//! Whether THIS machine's enrollment is the signed-in account's to serve
//! (T2049 — the Windows half of main 6dfb31232's `MachineHostingVerdict`).
//!
//! The Mac app runs its own relay agent and applies the whole verdict itself:
//! host on a live same-account credential, stop on a pending revocation or an
//! absent/dead credential, change nothing when the relay cannot be reached.
//! On Windows the uplink rides the session agent, which already handles every
//! branch but one: it parks on a pending revocation (`revoke_watch.zig`) and
//! on a missing credential (`sharing.decide`), but it never learns who is
//! signed in, so it served a credential that belongs to ANOTHER account. The
//! app knows the account and can ask the relay who the credential belongs to,
//! so the app decides that one branch here and hands the agent the answer as
//! `owner-mismatch.json` (`agent/owner_veto.zig`).
//!
//! Run at launch (signed in) and at sign-in — the two moments the Mac
//! reconciles besides network-came-back, which on Windows is covered by the
//! next launch (the veto is sticky across relay outages by design: an
//! unreachable relay changes nothing).

const std = @import("std");
const Allocator = std.mem.Allocator;
const enroll = @import("agent/enroll.zig");
const owner_veto = @import("agent/owner_veto.zig");
const relay_account = @import("relay_account.zig");
const relay_revoke = @import("relay_revoke.zig");
const pending_revoke = @import("relay_revoke_pending.zig");

const log = std.log.scoped(.relay_hosting);

/// The credential as the relay describes it (Mac's `CredentialState`, minus
/// `unprobed`: Windows never skips the probe, because a pending revocation
/// leaves the veto alone rather than deciding it).
pub const CredentialState = enum {
    /// relay.env carries no device token.
    absent,
    /// The relay says the bearer is no longer a device (401).
    dead,
    /// The relay confirms it, and it belongs to the signed-in account.
    alive_ours,
    /// The relay confirms it, and it belongs to somebody else.
    alive_foreign,
    /// No usable answer.
    unknown,
};

/// What to do with the veto file.
pub const VetoAction = enum {
    /// The credential is another account's: the machine must not serve it.
    write,
    /// Nothing for a veto to say: remove any that is there.
    clear,
    /// Not enough evidence either way: touch nothing.
    leave,
};

/// The rule, pure — Mac's `MachineHostingVerdict.decide` restricted to the
/// branch only the app can answer. `account_email` is the signed-in account,
/// or null when signed out.
pub fn vetoAction(
    pending_revocation: bool,
    account_email: ?[]const u8,
    state: CredentialState,
) VetoAction {
    // Mac: a pending revocation outranks everything and stops the host. Here
    // the agent's revocation watcher already parks for it; the veto is left
    // as it is so the two never race over the same tick.
    if (pending_revocation) return .leave;
    // Mac: a live credential with no account is `.unchanged` — a failed
    // account read or a hand-run `--enroll` is no evidence the machine should
    // go dark, and nothing can be compared without an account.
    const account = account_email orelse return .leave;
    if (account.len == 0) return .leave;
    return switch (state) {
        .alive_foreign => .write,
        // Mac `.host`; and for absent/dead there is no credential the veto
        // could name (the agent parks on those by itself).
        .alive_ours, .absent, .dead => .clear,
        // Mac `.unchanged`: never stop a working host because the network
        // blinked, never start one on a credential nobody vouched for.
        .unknown => .leave,
    };
}

/// Account comparison, ASCII case-insensitive (the relay echoes the identity
/// provider's spelling; see `relay_suspend.sameAccount`).
pub fn sameAccount(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Probe relay.env's credential, decide, and apply — for an account in hand.
/// Network-bound; call off the GUI thread.
pub fn reconcileFor(alloc: Allocator, account_email: []const u8) VetoAction {
    const veto_path = owner_veto.path(alloc) catch return .leave;
    defer alloc.free(veto_path);

    const env_path = enroll.relayEnvPath(alloc) catch return .leave;
    defer alloc.free(env_path);

    // Read the token ONCE and decide against exactly it: a restore or a
    // re-enroll rewriting relay.env meanwhile leaves a veto that names the
    // old token, which the agent ignores.
    // A missing relay.env reads as an empty one (no token): `.absent` below.
    var env = enroll.loadRelayEnv(alloc, env_path) catch return .leave;
    defer env.deinit(alloc);
    const token = env.device_token orelse "";
    const pending = pending_revoke.isArmed(alloc);
    if (token.len == 0) return apply(alloc, veto_path, vetoAction(pending, account_email, .absent), "", "", account_email);
    // A pending revocation decides without asking the relay anything.
    if (pending) return .leave;

    const raw_base = env.relay_base orelse return .leave;
    const base = relay_revoke.normalizeBase(alloc, raw_base) catch return .leave;
    defer alloc.free(base);

    switch (enroll.whoamiAnswer(alloc, base, token)) {
        .dead => return apply(alloc, veto_path, vetoAction(false, account_email, .dead), token, "", account_email),
        .unknown => return .leave,
        .ok => |w| {
            var who = w;
            defer who.deinit(alloc);
            if (who.email.len == 0) return .leave;
            const state: CredentialState = if (sameAccount(who.email, account_email)) .alive_ours else .alive_foreign;
            return apply(alloc, veto_path, vetoAction(false, account_email, state), token, who.email, account_email);
        },
    }
}

fn apply(
    alloc: Allocator,
    veto_path: []const u8,
    action: VetoAction,
    token: []const u8,
    owner_email: []const u8,
    account_email: []const u8,
) VetoAction {
    switch (action) {
        .leave => {},
        .clear => if (owner_veto.existsAt(veto_path)) {
            owner_veto.clearAt(veto_path);
            log.info("this machine's credential is the signed-in account's again; cleared the other-account veto", .{});
        },
        .write => {
            owner_veto.writeAt(alloc, veto_path, token, owner_email, account_email, std.time.timestamp()) catch |err| {
                log.warn("could not write the other-account veto err={}", .{err});
                return .leave;
            };
            log.info("this machine is enrolled to another account; told the agent not to serve it", .{});
        },
    }
    return action;
}

/// One reconcile at a time.
var running: std.atomic.Value(bool) = .init(false);

/// The launch entry point: when signed in, reconcile on a detached thread.
/// Signed out it spawns nothing ("nobody signed in = leave as is").
pub fn reconcileAsync(alloc: Allocator) void {
    const p = relay_account.accountPath(alloc) catch return;
    defer alloc.free(p);
    if (!relay_account.isSignedIn(alloc, p)) return;
    // Not enrolled and no veto to clear: nothing to ask the relay.
    if (enroll.loadDeviceToken(alloc)) |tok| {
        alloc.free(tok);
    } else {
        const vp = owner_veto.path(alloc) catch return;
        defer alloc.free(vp);
        if (!owner_veto.existsAt(vp)) return;
    }
    if (running.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, reconcileThread, .{}) catch |err| {
        running.store(false, .release);
        log.warn("could not start the hosting reconcile err={}", .{err});
        return;
    };
    thread.detach();
}

fn reconcileThread() void {
    defer running.store(false, .release);
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const p = relay_account.accountPath(alloc) catch return;
    var account = relay_account.load(alloc, p) catch return;
    defer account.deinit(alloc);
    if (account.email.len == 0) return;
    _ = reconcileFor(alloc, account.email);
}

// -----------------------------------------------------------------------------
// Tests (pure — the `none` lane)
// -----------------------------------------------------------------------------

const testing = std.testing;

test "vetoAction: another account's live credential is vetoed" {
    try testing.expectEqual(VetoAction.write, vetoAction(false, "b@example.com", .alive_foreign));
}

test "vetoAction: the signed-in account's own credential clears any veto" {
    try testing.expectEqual(VetoAction.clear, vetoAction(false, "a@example.com", .alive_ours));
}

test "vetoAction: an unreachable relay changes nothing" {
    try testing.expectEqual(VetoAction.leave, vetoAction(false, "a@example.com", .unknown));
}

test "vetoAction: nobody signed in leaves it as is, whatever the credential" {
    for ([_]CredentialState{ .absent, .dead, .alive_ours, .alive_foreign, .unknown }) |s| {
        try testing.expectEqual(VetoAction.leave, vetoAction(false, null, s));
        try testing.expectEqual(VetoAction.leave, vetoAction(false, "", s));
    }
}

test "vetoAction: a pending revocation leaves the veto to the revocation watcher" {
    for ([_]CredentialState{ .absent, .dead, .alive_ours, .alive_foreign, .unknown }) |s| {
        try testing.expectEqual(VetoAction.leave, vetoAction(true, "a@example.com", s));
    }
}

test "vetoAction: no credential or a dead one leaves nothing to veto" {
    try testing.expectEqual(VetoAction.clear, vetoAction(false, "a@example.com", .absent));
    try testing.expectEqual(VetoAction.clear, vetoAction(false, "a@example.com", .dead));
}

test "sameAccount: case-insensitive, empty never matches" {
    try testing.expect(sameAccount("A@Example.com", "a@example.COM"));
    try testing.expect(!sameAccount("a@example.com", "b@example.com"));
    try testing.expect(!sameAccount("", ""));
}
