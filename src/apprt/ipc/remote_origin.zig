//! What a `ghoztty +verb` run inside a REMOTE pane may do to the app the user
//! is looking at (T2217; docs/design/remote-viewer-tunnel.md, decisions 2 and
//! 4). A remote pane's IPC is forwarded to the local app by the session agent
//! (`app_request`/`app_response`, `capability.app_ipc` in
//! `remote/protocol.zig`), and this file is the one statement of the trust
//! boundary every frontend enforces on such a request:
//!
//!   **A remote machine is trusted to show you things, not to reach into your
//!   machine.**
//!
//! The rule lives here, beside the shared dispatcher (`server.zig`), and is
//! written as an EXHAUSTIVE switch over `server.Verb`, so a verb added to the
//! IPC surface does not compile until somebody decides what a remote session
//! may do with it. The Mac server is Swift and cannot share this file; its
//! policy (T2218) byte-matches the table and the sentences below.
//!
//! Three things a frontend must do with a request whose origin is remote, and
//! none of them may be taken from the request itself (the request is written
//! by a process on the other machine, so every field in it is the remote's
//! claim):
//!
//! 1. **The origin comes from the transport.** It is the machine whose agent
//!    delivered the `app_request` frame, never a field in the JSON.
//! 2. **The caller pane is the session's pane.** `Request.caller_pane` and any
//!    `--caller-pane=` argument are REPLACED by the local pane bound to the
//!    frame's session (`forcedCallerPane`), so a remote cannot start its name
//!    lookups in a local window by naming a local pane id.
//! 3. **A target outside the origin reads as not found** (`targetInScope`).
//!    Saying "that pane exists but is not yours" would let a remote enumerate
//!    the user's local pane names one guess at a time.
const std = @import("std");
const server = @import("server.zig");
const Verb = server.Verb;

/// Where a forwarded request came from: the machine key of the connection
/// (the same key a remote window's panes carry), set by the transport.
pub const Origin = struct {
    machine_key: []const u8,
};

/// What a remote origin may do with one verb.
pub const Scope = enum {
    /// Answers about the app, not about any pane (`+version`).
    unscoped,
    /// Acts on a named pane or window: allowed only when the target is in
    /// the origin's scope (`targetInScope`); anything else is not found.
    own_target,
    /// `+list`: answered, with only the origin's panes in it.
    own_list,
    /// `+split` / `+new-window`: a TERMINAL it creates is a pane on the
    /// origin machine (its per-host default shell), never a local shell; a
    /// `--view` creates a viewer, which belongs to the origin too. A `+split`
    /// anchor is an `own_target`.
    creates_remote,
    /// Never from a remote origin, whatever the arguments.
    refused,
};

/// The policy table. Exhaustive on purpose: no `else`.
pub fn scope(verb: Verb) Scope {
    return switch (verb) {
        .version => .unscoped,

        .list => .own_list,

        .split, .new_window => .creates_remote,

        .close,
        .rename,
        .send_keys,
        .read,
        .set_state,
        .set_banner,
        .rearrange,
        .reload,
        .focus,
        .stash,
        .restore,
        => .own_target,

        // Dialling a machine is done with the LOCAL user's credentials and
        // trust (ssh keys, relay sign-in): a remote session asking the app to
        // open a connection to a third machine is reaching into this one.
        .new_remote_window,
        // A launch that lost the endpoint race hands its window over on the
        // local machine only; from a remote it is a request to quit the app.
        .handoff_quit,
        => .refused,
    };
}

/// True when a target that belongs to `target_machine` may be acted on by a
/// request from `origin`. `null` is a LOCAL pane or window (no machine), which
/// is never in a remote origin's scope. Machine keys compare exactly.
pub fn targetInScope(origin: Origin, target_machine: ?[]const u8) bool {
    const m = target_machine orelse return false;
    return std.mem.eql(u8, m, origin.machine_key);
}

/// The caller pane a forwarded request is served as: always the local pane
/// bound to the frame's session, whatever the request claimed. `null` when no
/// local pane is bound to that session (it was closed while the request was
/// in flight), and then the request is answered with `unboundSessionMessage`.
pub fn forcedCallerPane(bound_pane: ?[]const u8, claimed: ?[]const u8) ?[]const u8 {
    _ = claimed; // the remote's claim; deliberately unused
    return bound_pane;
}

/// The reply sentence for a `.refused` verb. Shared wording, so every
/// frontend (and the Mac's, which copies it) says the same thing.
pub fn refusedMessage(comptime verb: Verb) []const u8 {
    return comptime "+" ++ verb.action() ++ " is not available from a remote session: " ++
        "a remote machine can show you things in this window, not act on this machine";
}

/// The reply when the session that sent the request has no local pane any
/// more (closed, or detached, while the request was in flight).
pub const unbound_session_message =
    "this remote session is no longer shown in a window here, so the request has nowhere to go";

/// Runtime form of `refusedMessage`, for a frontend that switches on a
/// runtime `Verb`.
pub fn refusedMessageFor(verb: Verb) []const u8 {
    return switch (verb) {
        inline else => |v| refusedMessage(v),
    };
}

const testing = std.testing;

test "T2217 every verb has a remote scope, and the dangerous ones are refused" {
    // The table is exhaustive, so this loop is the behavioral half: each verb
    // lands in exactly the class the design names.
    for (std.enums.values(Verb)) |v| {
        const s = scope(v);
        switch (v) {
            .version => try testing.expectEqual(Scope.unscoped, s),
            .list => try testing.expectEqual(Scope.own_list, s),
            .split, .new_window => try testing.expectEqual(Scope.creates_remote, s),
            .new_remote_window, .handoff_quit => try testing.expectEqual(Scope.refused, s),
            else => try testing.expectEqual(Scope.own_target, s),
        }
    }
    // The verbs decision 4 names explicitly as origin-scoped.
    for ([_]Verb{ .send_keys, .read, .close, .set_banner, .set_state }) |v|
        try testing.expectEqual(Scope.own_target, scope(v));
}

test "T2217 a local target is never in a remote origin's scope" {
    const o: Origin = .{ .machine_key = "ssh:winbox" };
    try testing.expect(targetInScope(o, "ssh:winbox"));
    // A local pane carries no machine.
    try testing.expect(!targetInScope(o, null));
    // Another remote machine is not this one, and keys compare exactly.
    try testing.expect(!targetInScope(o, "ssh:otherbox"));
    try testing.expect(!targetInScope(o, "ssh:WINBOX"));
    try testing.expect(!targetInScope(o, "ssh:winbox2"));
    try testing.expect(!targetInScope(o, ""));
}

test "T2217 the caller pane is the session's pane, never the remote's claim" {
    try testing.expectEqualStrings("bound-pane", forcedCallerPane("bound-pane", "local-shell-pane").?);
    try testing.expectEqualStrings("bound-pane", forcedCallerPane("bound-pane", null).?);
    // No bound pane: nothing to serve it as, even if the remote named one.
    try testing.expect(forcedCallerPane(null, "local-shell-pane") == null);
}

test "T2217 refused verbs say why in the shared sentence" {
    const m = refusedMessageFor(.new_remote_window);
    try testing.expect(std.mem.startsWith(u8, m, "+new-remote-window is not available from a remote session"));
    try testing.expectEqualStrings(refusedMessage(.handoff_quit), refusedMessageFor(.handoff_quit));
}
