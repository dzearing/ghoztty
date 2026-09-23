//! Which IPC requests wait out an in-flight local-agent resolve (T1688).
//!
//! THE DEFECT. `LocalAgent.findOrSpawn` pumps IPC while it waits for the agent
//! (T188), so a `+new-window` issued in the first second of a launch is served
//! one frame deep INSIDE the resolve that is finding the agent for the launch
//! window. `sharedConnection` cannot hand it the connection it is still
//! resolving, and re-entering would spawn a second agent, so it truthfully
//! answers "none" — and the window opens as a plain local shell. It looks
//! exactly like every other window, `+list --json` reports `session_id: null`
//! for its pane forever, and it is simply gone after the next restart: the one
//! moment the user was relying on it. `test\win32\restore-session-dup.ps1` hit
//! it about two runs in five.
//!
//! THE FIX. The request that would become that window is not served from
//! inside the resolve at all. The nested pump puts it back on the queue, and it
//! is served the moment the resolve returns — by then the shared connection is
//! warm (or the resolve genuinely failed, and the window opens without the
//! agent for the same reason every window would). The caller waits at most the
//! resolve's own bounded deadline, which it was already exposed to: before
//! T188 every request waited that long.
//!
//! WHY ONLY `new-window`. It is the one verb that asks `sharedConnection` for
//! a connection. `+split` and a new tab inherit `Window.local_agent_conn` from
//! the window they land in and never resolve; `+new-remote-window` dials
//! another machine and has no use for the local agent. Everything else is a
//! query or an edit of an existing pane, and deferring those would undo what
//! T188 bought: a startup that answers `+list` while the agent is still coming
//! up. So the set is exactly the resolving verb, and a verb added later that
//! resolves too belongs in `resolving_actions`.
//!
//! Pure on purpose, so the decision is unit-tested in every lane; the
//! mechanism (the re-post) lives in `App.pumpIpc`.

const std = @import("std");

/// IPC actions whose handler resolves the shared local-agent connection.
pub const resolving_actions = [_][]const u8{"new-window"};

/// Whether a request marshalled to the GUI thread during a nested pump must be
/// put back on the queue rather than served now.
///
/// `resolving` is `LocalAgent.resolving`; `persistence` is the
/// `session-persistence` config. With persistence off nothing resolves, so
/// nothing is worth waiting for.
pub fn shouldDefer(request_json: []const u8, resolving: bool, persistence: bool) bool {
    if (!resolving or !persistence) return false;
    const action = requestAction(request_json) orelse return false;
    for (resolving_actions) |a| {
        if (std.mem.eql(u8, action, a)) return true;
    }
    return false;
}

/// The `action` of a request body without a full JSON parse, or null when it
/// cannot be found.
///
/// A null answer means "serve it now", which is the pre-T1688 behaviour, so a
/// body this cannot read degrades to the old race rather than to a request
/// that is never served. Tolerates whitespace around the colon, because the
/// wire is JSON and not one serializer's spelling of it.
pub fn requestAction(body: []const u8) ?[]const u8 {
    const key = "\"action\"";
    const start = std.mem.indexOf(u8, body, key) orelse return null;
    var i = start + key.len;
    while (i < body.len and std.ascii.isWhitespace(body[i])) i += 1;
    if (i >= body.len or body[i] != ':') return null;
    i += 1;
    while (i < body.len and std.ascii.isWhitespace(body[i])) i += 1;
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const rest = body[i..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "requestAction reads the compact wire shape" {
    try testing.expectEqualStrings(
        "new-window",
        requestAction("{\"action\":\"new-window\",\"arguments\":[]}").?,
    );
}

test "requestAction tolerates whitespace around the colon" {
    try testing.expectEqualStrings(
        "list",
        requestAction("{ \"action\" :  \"list\" }").?,
    );
}

test "requestAction answers null for a body it cannot read" {
    try testing.expect(requestAction("") == null);
    try testing.expect(requestAction("{\"verb\":\"new-window\"}") == null);
    try testing.expect(requestAction("{\"action\":42}") == null);
    try testing.expect(requestAction("{\"action\":\"new-win") == null);
}

test "new-window waits out a resolve when persistence is on" {
    const body = "{\"action\":\"new-window\",\"arguments\":[\"--name=a\"]}";
    try testing.expect(shouldDefer(body, true, true));
}

test "nothing waits when no resolve is in flight" {
    const body = "{\"action\":\"new-window\"}";
    try testing.expect(!shouldDefer(body, false, true));
}

test "nothing waits with persistence off" {
    const body = "{\"action\":\"new-window\"}";
    try testing.expect(!shouldDefer(body, true, false));
}

test "queries and pane edits are still answered during a resolve (T188)" {
    const verbs = [_][]const u8{
        "list",      "read",   "send-keys",         "set-state", "set-banner",
        "rename",    "close",  "rearrange",         "focus",     "version",
        "reload",    "split",  "new-remote-window",
    };
    for (verbs) |v| {
        var buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"action\":\"{s}\"}}", .{v});
        try testing.expect(!shouldDefer(body, true, true));
    }
}

test "an unreadable body is served, never parked" {
    try testing.expect(!shouldDefer("not json", true, true));
}
