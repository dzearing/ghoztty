//! Which HKCU registry key the autostart ("Run") entries are read from and
//! written to - the real `Software\Microsoft\Windows\CurrentVersion\Run`, or a
//! private scratch key that a test run names.
//!
//! ## Why (T2917)
//! The acceptance suite exercises the agent's autostart for real: it launches a
//! build that writes `HKCU\...\Run\GhozttyAgent-<instance>`, pointed at a copy
//! of `ghoztty-agent.exe` sitting under `%TEMP%`, and then executes that command
//! the way sign-in would. To Microsoft Defender that is the textbook shape of
//! malware persistence - an unsigned exe in a temp folder registering itself as
//! a startup program - and its behaviour model says so:
//! `Behavior:Win32/Persistence.A!ml` (ThreatID 2147737394), first on sandbox
//! copies (2026-11-05), then on 2026-11-11 on the build output itself. Defender
//! then blocks that binary's HASH everywhere, so `zig build` failed with
//! `AntivirusInterference` installing `zig-out\bin\ghoztty-agent.exe` and every
//! agent-backed harness went red for a box reason.
//!
//! The test never needed the real key. What it proves is that the right value
//! is written and that the command in it brings the agent back; both hold just
//! as well in a key Defender does not watch. So `GHOZTTY_RUN_KEY=<token>` moves
//! every Run read and write - the app's autostart (`LocalAgent.writeAutostart`)
//! and the agent's adopt bookkeeping (`adopt.zig`) - to
//! `HKCU\Software\Ghoztty-test\Run-<token>`. `test\win32\lib\Isolation.ps1`
//! sets it for every isolated run and tears the key down afterwards.
//!
//! Unset - the only production value - is the real key, byte for byte. The
//! token is composed into a fixed parent rather than taken as a path, so the
//! variable can never aim a write at any other key.

const std = @import("std");

pub const env_var = "GHOZTTY_RUN_KEY";

/// The real autostart key. Production always uses this.
pub const real_subkey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";

/// Parent of every redirected key. A test teardown removes `<this>\Run-<token>`.
pub const test_parent = "Software\\Ghoztty-test";

/// Longest token honoured. Over-long values are REJECTED (real key) rather than
/// truncated, the same rule as `agent_lineage`.
pub const max_token_len: usize = 40;

/// Longest subkey this module can produce (the real key or a redirected one).
pub const max_subkey_len: usize = test_parent.len + "\\Run-".len + max_token_len;

/// The subkey for a raw `GHOZTTY_RUN_KEY` value, written into `buf` (at least
/// `max_subkey_len` bytes). Null or unusable input - empty, whitespace, longer
/// than `max_token_len` - yields the real key. The token is whitelisted
/// (ASCII alphanumerics, `-`, `.`, `_`; anything else becomes `_`), so it can
/// never smuggle a `\` and climb out of `test_parent`.
pub fn subkeyFor(buf: []u8, raw: ?[]const u8) []const u8 {
    const value = raw orelse return real_subkey;
    const token = std.mem.trim(u8, value, " \t\r\n");
    if (token.len == 0 or token.len > max_token_len) return real_subkey;
    const prefix = test_parent ++ "\\Run-";
    if (buf.len < prefix.len + token.len) return real_subkey;
    @memcpy(buf[0..prefix.len], prefix);
    for (token, 0..) |c, i| {
        buf[prefix.len + i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_' => c,
            else => '_',
        };
    }
    return buf[0 .. prefix.len + token.len];
}

/// `subkeyFor` of this process's environment. `buf` as above.
pub fn subkeyFromEnv(buf: []u8) []const u8 {
    var raw_buf: [max_token_len + 8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&raw_buf);
    const raw = std.process.getEnvVarOwned(fba.allocator(), env_var) catch return real_subkey;
    return subkeyFor(buf, raw);
}

/// `subkeyFromEnv` as a NUL-terminated UTF-16 string allocated from `alloc`,
/// ready for `RegOpenKeyExW`.
pub fn subkeyFromEnvW(alloc: std.mem.Allocator) ![:0]u16 {
    var buf: [max_subkey_len]u8 = undefined;
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, subkeyFromEnv(&buf));
}

test "run_key: unset is the real Run key" {
    var buf: [max_subkey_len]u8 = undefined;
    try std.testing.expectEqualStrings(real_subkey, subkeyFor(&buf, null));
}

test "run_key: empty, whitespace and over-long fall back to the real key" {
    var buf: [max_subkey_len]u8 = undefined;
    try std.testing.expectEqualStrings(real_subkey, subkeyFor(&buf, ""));
    try std.testing.expectEqualStrings(real_subkey, subkeyFor(&buf, "  \t"));
    const long = "a" ** (max_token_len + 1);
    try std.testing.expectEqualStrings(real_subkey, subkeyFor(&buf, long));
}

test "run_key: a token is composed under the test parent" {
    var buf: [max_subkey_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Software\\Ghoztty-test\\Run-auto-1234",
        subkeyFor(&buf, " auto-1234\r\n"),
    );
    const max = "b" ** max_token_len;
    try std.testing.expectEqualStrings(test_parent ++ "\\Run-" ++ max, subkeyFor(&buf, max));
}

test "run_key: a separator cannot climb out of the test parent" {
    var buf: [max_subkey_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Software\\Ghoztty-test\\Run-.._.._Microsoft_Run",
        subkeyFor(&buf, "..\\..\\Microsoft\\Run"),
    );
}

test "run_key: a buffer too small for the token falls back to the real key" {
    var small: [8]u8 = undefined;
    try std.testing.expectEqualStrings(real_subkey, subkeyFor(&small, "tok"));
}
