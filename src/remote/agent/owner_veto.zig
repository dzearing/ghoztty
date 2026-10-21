//! "This machine belongs to another account" — the veto the APP hands the
//! AGENT (T2049, the Windows half of main 6dfb31232's owner != signed-in rule).
//!
//! ## Why this exists
//!
//! An enrolled Mac hosts only while relay.env's credential belongs to the
//! account signed in to the app (`MachineHostingVerdict.decide`): signed in as
//! somebody else, the app is a guest on that machine and it is not its
//! enrollment to serve, so the relay agent stops. On Windows the uplink rides
//! the session agent (`main.zig` `SharingUplink`), which never learns who is
//! signed in — so it hosted on the credential alone, and a machine enrolled by
//! account A stayed reachable from all of A's devices while B used it.
//!
//! The agent cannot answer the question itself: it holds the credential but
//! not the account. The app holds the account and can ask the relay who the
//! credential belongs to (`/v1/agent/whoami`), so the app decides
//! (`relay_hosting.zig`) and writes the answer here, beside relay.env, in the
//! shape `pending-revoke.json` already uses. The agent reads it on every
//! reconcile tick and parks the uplink while it holds.
//!
//! ## Why the record names the credential
//!
//! The veto is about ONE credential: "the device token in relay.env belongs to
//! somebody else". A later enrollment as the signed-in account writes a new
//! token, and a veto still sitting there from the old one must not keep the
//! user's own machine dark until the app next launches. So the record carries
//! a fingerprint of the token it was decided against, and it holds only while
//! relay.env still carries that token — a re-enroll makes a stale veto inert
//! by construction, with no ordering between the two writers to get wrong.
//!
//! The fingerprint is a truncated SHA-256 of a random bearer, which identifies
//! the token without being usable as one; the file carries no secret.
//!
//! ## The failure directions
//!
//! An unreadable or mismatched record is NO veto. The veto exists to stop a
//! guest from serving another account's machine, and the app rewrites it at
//! every launch and sign-in; reading garbage as "park" would instead let a
//! corrupt file take the owner's own machine off the relay with nothing left
//! to clear it. "The relay could not be reached" and "nobody is signed in"
//! never write or clear it at all (`relay_hosting.vetoAction`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const enroll = @import("enroll.zig");
const atomic_write = @import("atomic_write.zig");

/// File name, beside relay.env (so `GHOSTTY_RELAY_ENV` carries it into a
/// test's sandbox together with the credential it describes).
pub const file_name = "owner-mismatch.json";

/// Hex length of a token fingerprint (8 bytes of SHA-256).
pub const fingerprint_len = 16;

/// The record. Additive evolution only: new fields get defaults, unknown
/// fields are ignored on read.
pub const Record = struct {
    version: u32 = 1,
    /// `fingerprint` of the device token this veto was decided against.
    token_fp: []const u8 = "",
    /// Who the relay says the credential belongs to.
    owner_email: []const u8 = "",
    /// Who was signed in to the app when it decided.
    account_email: []const u8 = "",
    /// Unix seconds, for logs and support questions.
    decided_at: i64 = 0,
};

/// The fingerprint of `token`: lowercase hex of the first 8 bytes of its
/// SHA-256. Pure.
pub fn fingerprint(token: []const u8) [fingerprint_len]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return std.fmt.bytesToHex(digest[0 .. fingerprint_len / 2].*, .lower);
}

/// Whether a record with fingerprint `token_fp` vetoes serving `token`. Pure:
/// an empty fingerprint or an empty token names nothing and vetoes nothing.
pub fn holds(token_fp: []const u8, token: []const u8) bool {
    if (token_fp.len != fingerprint_len or token.len == 0) return false;
    const fp = fingerprint(token);
    return std.ascii.eqlIgnoreCase(token_fp, &fp);
}

/// Where the record lives. Owned by the caller.
pub fn path(alloc: Allocator) ![]u8 {
    const env_path = try enroll.relayEnvPath(alloc);
    defer alloc.free(env_path);
    const dir = std.fs.path.dirname(env_path) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, file_name });
}

/// Write the veto for `token` at `p`, atomically.
pub fn writeAt(
    alloc: Allocator,
    p: []const u8,
    token: []const u8,
    owner_email: []const u8,
    account_email: []const u8,
    now: i64,
) !void {
    const fp = fingerprint(token);
    const rec: Record = .{
        .token_fp = &fp,
        .owner_email = owner_email,
        .account_email = account_email,
        .decided_at = now,
    };
    const json = try std.json.Stringify.valueAlloc(alloc, rec, .{});
    defer alloc.free(json);
    try atomic_write.writeChunks(alloc, p, &.{json}, .{});
    atomic_write.cleanStaging(p);
}

/// Delete the veto at `p`. A missing one is success.
pub fn clearAt(p: []const u8) void {
    std.fs.cwd().deleteFile(p) catch {};
    atomic_write.cleanStaging(p);
}

/// Whether a file exists at `p` at all (the app's "nothing to clear" check).
pub fn existsAt(p: []const u8) bool {
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

/// Whether the veto at `p` holds for `token`. Absent, unreadable, or decided
/// against a different token: no veto.
pub fn holdsAt(alloc: Allocator, p: []const u8, token: []const u8) bool {
    const content = std.fs.cwd().readFileAlloc(alloc, p, 64 * 1024) catch return false;
    defer alloc.free(content);
    const parsed = std.json.parseFromSlice(Record, alloc, content, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();
    return holds(parsed.value.token_fp, token);
}

/// The agent's question: is the credential in relay.env right now one the app
/// said belongs to another account?
pub fn isVetoed(alloc: Allocator) bool {
    const token = enroll.loadDeviceToken(alloc) orelse return false;
    defer alloc.free(token);
    const p = path(alloc) catch return false;
    defer alloc.free(p);
    return holdsAt(alloc, p, token);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "fingerprint: stable, 16 lowercase hex chars, differs per token" {
    const a = fingerprint("token-a");
    const b = fingerprint("token-b");
    try testing.expectEqual(@as(usize, fingerprint_len), a.len);
    try testing.expectEqualSlices(u8, &a, &fingerprint("token-a"));
    try testing.expect(!std.mem.eql(u8, &a, &b));
    for (a) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
}

test "fingerprint: matches SHA-256 prefix (the harness computes it in PowerShell)" {
    // SHA-256("abc") = ba7816bf8f01cfea...
    try testing.expectEqualStrings("ba7816bf8f01cfea", &fingerprint("abc"));
}

test "holds: only for the token it was decided against" {
    const fp = fingerprint("tok-1");
    try testing.expect(holds(&fp, "tok-1"));
    try testing.expect(!holds(&fp, "tok-2"));
    try testing.expect(holds("BA7816BF8F01CFEA", "abc"));
}

test "holds: empty or malformed fingerprints and empty tokens veto nothing" {
    try testing.expect(!holds("", "tok"));
    try testing.expect(!holds("abc", "tok"));
    const fp = fingerprint("");
    try testing.expect(!holds(&fp, ""));
}

test "writeAt/holdsAt/clearAt round trip, and a re-enroll makes it inert" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const p = try std.fs.path.join(testing.allocator, &.{ dir, file_name });
    defer testing.allocator.free(p);

    try testing.expect(!holdsAt(testing.allocator, p, "old-token"));
    try writeAt(testing.allocator, p, "old-token", "a@example.com", "b@example.com", 7);
    try testing.expect(existsAt(p));
    try testing.expect(holdsAt(testing.allocator, p, "old-token"));
    // The signed-in account re-enrolled: relay.env holds a new token.
    try testing.expect(!holdsAt(testing.allocator, p, "new-token"));

    // The record never carries the token itself.
    const content = try std.fs.cwd().readFileAlloc(testing.allocator, p, 4096);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "old-token") == null);

    clearAt(p);
    try testing.expect(!existsAt(p));
    try testing.expect(!holdsAt(testing.allocator, p, "old-token"));
    clearAt(p); // idempotent
}

test "holdsAt: a corrupt record is no veto" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = file_name, .data = "{not json" });
    const p = try tmp.dir.realpathAlloc(testing.allocator, file_name);
    defer testing.allocator.free(p);
    try testing.expect(!holdsAt(testing.allocator, p, "tok"));
}
