//! The NAME of the agent's kill-on-close PTY job object (T902).
//!
//! ## Why a name at all
//! The agent assigns every ConPTY shell to one process-global, kill-on-close
//! job (`agent/pty_child.zig`) and holds its handle for life, so every app
//! launched from inside a pane inherits that membership — and dies with the
//! agent unless it escapes at startup (`apprt/win32/job_escape.zig`). Deciding
//! whether to escape used to be a HEURISTIC: the NULL-handle flags query plus
//! `$GHOZTTY_PANE_ID` lineage. Both clues can miss. With nested jobs the flags
//! query answers only the FIRST job this process joined, so a kill-on-close job
//! sitting behind a limitless compat job reads as `0x0` — measured on this box
//! while building T675's harness, where a real pane chain answered `0x0` from
//! inside the agent's `0x2000` job.
//!
//! `IsProcessInJob(self, <the agent's job>)` answers the question exactly, and
//! there is no public API to enumerate the jobs you are in — so the handle has
//! to come from the agent. A NAME is how you get one without a wire protocol:
//! the agent creates the job named, the app opens it by name with
//! `JOB_OBJECT_QUERY` and asks. Nothing is advertised in `port.json`, so there
//! is no compatibility surface to version and no stale file that could answer
//! the question WRONG (the failure mode a handle advertised in a file has, and
//! the reason that option was not taken).
//!
//! ## The identity in the name
//! Exactly the one the single-instance guard already uses: the build's lineage
//! (`local` / `local-debug`) plus the `GHOZTTY_AGENT_INSTANCE` suffix (T167).
//! That is load-bearing rather than tidy. `CreateJobObjectW` with a name that
//! already exists OPENS the existing job, so two agents naming the same job
//! would MERGE their kill domains — a harness agent could take the dev agent's
//! panes down with it, which is worse than the blind spot this closes. The
//! guard makes one agent per lineage-key an invariant, so sharing a name
//! requires sharing a key, which the guard already forbids; `pty_child.zig`
//! additionally refuses to adopt an existing name and falls back to an
//! anonymous job, so the merge cannot happen even if that invariant breaks.
//!
//! ## `Local\` is the right namespace, not a weaker one
//! Unlike the agent's guard mutex — which must see across logon sessions to
//! know another daemon is up, and so prefers `Global\` — this name only has to
//! be openable by an app in the SAME logon session as the agent that created
//! it, which is the only session whose panes that agent hosts. `Local\` is
//! per-logon-session, so two users' agents cannot collide by construction and
//! no privilege is needed to create it. A name is a NAMING device, never a
//! security boundary: the owner-only default DACL is what keeps others out,
//! and anything in the session that could open this job could already
//! `TerminateProcess` our panes directly.

const std = @import("std");

/// `Local\` = the per-logon-session object namespace. See the module doc.
pub const prefix = "Local\\GhozttyAgentPtyJob";

/// Longest name this composes: prefix + `-local-debug` + `-` + a suffix capped
/// at `agent_lineage.max_len` (24). Callers size their buffer with this so a
/// legal name can never fail to compose.
pub const max_len: usize = prefix.len + "-local-debug".len + 1 + 24;

/// Compose the agent PTY job's name into `buf`.
///
/// `is_debug` is the caller's OWN build mode — the app and the agent it talks
/// to are the same lineage by construction (they derive the pipe name from the
/// same fact), so each side can answer it locally without asking the other.
/// `suffix` is `agent_lineage.fromEnv`: null in every production run, which
/// yields `Local\GhozttyAgentPtyJob-local[-debug]`.
///
/// Sanitized defensively even though `agent_lineage.sanitize` has already
/// whitelisted the suffix: a `\` past the namespace prefix would name an object
/// in a DIFFERENT directory, which is the one way a name here could go
/// somewhere its author did not mean.
pub fn compose(buf: []u8, is_debug: bool, suffix: ?[]const u8) error{NameTooLong}![]const u8 {
    const lineage = if (is_debug) "-local-debug" else "-local";
    const sfx = suffix orelse "";
    const sfx_len = if (sfx.len == 0) 0 else sfx.len + 1; // "-<suffix>"
    const total = prefix.len + lineage.len + sfx_len;
    if (total > buf.len) return error.NameTooLong;

    @memcpy(buf[0..prefix.len], prefix);
    var i = prefix.len;
    @memcpy(buf[i..][0..lineage.len], lineage);
    i += lineage.len;
    if (sfx.len != 0) {
        buf[i] = '-';
        i += 1;
        for (sfx) |c| {
            buf[i] = if (c == '\\' or c == '/' or c < 0x20) '_' else c;
            i += 1;
        }
    }
    return buf[0..total];
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "compose: the production names, both lineages" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings(
        "Local\\GhozttyAgentPtyJob-local",
        try compose(&buf, false, null),
    );
    try testing.expectEqualStrings(
        "Local\\GhozttyAgentPtyJob-local-debug",
        try compose(&buf, true, null),
    );
    // An empty suffix is the same thing as no suffix — never a trailing dash,
    // which would be a THIRD name for the production lineage.
    try testing.expectEqualStrings(
        "Local\\GhozttyAgentPtyJob-local",
        try compose(&buf, false, ""),
    );
}

test "compose: a sandbox lineage names its own job" {
    var buf: [max_len]u8 = undefined;
    // The whole point: a harness agent under GHOZTTY_AGENT_INSTANCE=sbx1 must
    // not be able to name — and therefore OPEN, and therefore merge with — the
    // dev agent's job.
    const sandbox = try compose(&buf, true, "sbx1");
    try testing.expectEqualStrings("Local\\GhozttyAgentPtyJob-local-debug-sbx1", sandbox);

    var other: [max_len]u8 = undefined;
    const dev = try compose(&other, true, null);
    try testing.expect(!std.mem.eql(u8, sandbox, dev));

    // And two different sandboxes differ from each other.
    var third: [max_len]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, sandbox, try compose(&third, true, "sbx2")));
}

test "compose: debug and release never name the same job" {
    var a: [max_len]u8 = undefined;
    var b: [max_len]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, try compose(&a, true, null), try compose(&b, false, null)));
    try testing.expect(!std.mem.eql(u8, try compose(&a, true, "x"), try compose(&b, false, "x")));
}

test "compose: a separator can never escape the namespace directory" {
    var buf: [max_len]u8 = undefined;
    // `agent_lineage.sanitize` already refuses these, but this composer is the
    // last thing between a suffix and the object manager, and a name that
    // climbed out of `Local\` would be a job in somebody else's directory.
    const name = try compose(&buf, false, "a\\b/c");
    try testing.expectEqualStrings("Local\\GhozttyAgentPtyJob-local-a_b_c", name);
    // Exactly one backslash: the namespace separator we wrote ourselves.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, name, "\\"));
}

test "compose: max_len admits the longest legal name" {
    const longest = "a" ** 24; // agent_lineage.max_len
    var buf: [max_len]u8 = undefined;
    const name = try compose(&buf, true, longest);
    try testing.expectEqual(max_len, name.len);
    // ...and a buffer one byte short is an error, never a truncated name: two
    // sandboxes whose names differ only past the cut would share a job.
    var small: [max_len - 1]u8 = undefined;
    try testing.expectError(error.NameTooLong, compose(&small, true, longest));
}
