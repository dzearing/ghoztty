//! The client-side signed-in relay account on Windows (T21a store + T93
//! brokered model — the Zig analog of
//! `macos/Sources/Features/Remote/RelayAccount.swift`, which uses the macOS
//! Keychain).
//!
//! ## What it stores
//! A single account blob at `%LOCALAPPDATA%\ghoztty\account.dat`:
//! `{session_token, expiry, email, relay_base, picture?}` — the opaque relay
//! **session token** minted by the relay's brokered `/oauth/exchange` (T93).
//! No Google token or OAuth client credential ever touches this store; the
//! confidential client secret and the Google refresh token live only on the
//! relay. `relay_base` records which relay minted the session so renew and
//! sign-out dial the same one.
//!
//! ## At rest
//! The blob is DPAPI-encrypted per-user (`CryptProtectData`) on Windows, so it
//! is unreadable by other users and unusable if copied to another machine.
//! The write is atomic (tmp + rename, like `enroll.saveRelayEnv`) and the file
//! gets an owner-only DACL (`win_acl`). Off Windows DPAPI is unavailable, so
//! the `protect` seam is an identity passthrough.
//!
//! On **Linux** (T3341) the account lives in the Secret Service (libsecret,
//! `secret_service.zig`) when a keyring daemon answers - the Keychain/DPAPI
//! row of the translation table - keyed by the store path, so the T1859
//! debug/release split holds there too. When no keyring answers, which is the
//! WSL default, it falls back to the path itself: a mode-0600 file under
//! `$XDG_DATA_HOME/ghoztty/`. `location` says which one holds the current
//! sign-in, so the chooser's account row can tell the person. A save that
//! reaches the keyring deletes any fallback file, so a keyring that appears
//! later absorbs the credential on the next renewal instead of leaving a copy
//! on disk. On macOS this Zig store is unused (the Swift app owns the
//! Keychain); that branch exists so the module compiles and its tests run.
//!
//! ## The token-resolution seam
//! `resolveSessionToken` returns the stored session token while it has >60s of
//! life left, else renews it at the stored relay (`/oauth/renew` rotates the
//! token; the rotation is persisted). This is the account tier the win32 GUI
//! consults after an explicit `--token` and before the `GHOSTTY_RELAY_TOKEN`
//! env fallback.
//!
//! ## Legacy stores
//! A pre-T93 account.dat held `{client_id, client_secret?, refresh_token,
//! email}` (the direct-Google flow). The brokered relay no longer accepts raw
//! Google ID tokens as client bearers, so a legacy credential cannot mint
//! anything useful — `load` surfaces it as `Error.Legacy` and the user signs
//! in once more (from the machine chooser's account row — T141 deleted the
//! `+relay-login` CLI verb), which overwrites the store in the new shape.

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const Allocator = std.mem.Allocator;
const relay_session = @import("relay_session.zig");
const win_acl = @import("win_acl.zig");
const atomic_write = @import("agent/atomic_write.zig");
const secret_service = @import("secret_service.zig");

const log = std.log.scoped(.relay_account);

/// Seconds of remaining session-token life below which `resolveSessionToken`
/// renews instead of returning the cached token, so relay calls never race the
/// expiry (Mac `RelayAccount` uses the same 60s leeway).
pub const refresh_leeway_s: i64 = 60;

/// The persisted account. Slices are owned when returned from `load` (freed by
/// `deinit`); borrowed when passed to `save`.
pub const Account = struct {
    /// The opaque relay session token (the Bearer for every relay call).
    session_token: []const u8,
    /// Absolute token expiry, unix seconds (the relay's `expiry`).
    expiry: i64,
    email: []const u8,
    /// The relay base URL the session was minted at (renew/signout target).
    relay_base: []const u8,
    picture: ?[]const u8 = null,

    /// Free an owned account (as returned by `load`).
    pub fn deinit(self: *Account, alloc: Allocator) void {
        alloc.free(self.session_token);
        alloc.free(self.email);
        alloc.free(self.relay_base);
        if (self.picture) |p| alloc.free(p);
        self.* = undefined;
    }

    /// Whether the stored token still has more than the refresh leeway of
    /// life left at `now_unix`. Pure (now passed in for testability).
    pub fn isFresh(self: Account, now_unix: i64) bool {
        return self.expiry - now_unix > refresh_leeway_s;
    }
};

pub const Error = error{
    /// No account.dat (the user is signed out).
    SignedOut,
    /// The file exists but couldn't be decrypted or parsed.
    Corrupt,
    /// A pre-T93 direct-Google store (refresh token, no session token). The
    /// only remedy is one fresh sign-in (see the file header).
    Legacy,
};

/// The store's file name for a build lineage (T1859). A debug build gets its
/// own, the same split as the IPC pipe, the local agent's state dir and the
/// viewer prefs: those are all derived from the build mode so a dev or test
/// run never drives the user's terminal, and the account was the one piece of
/// the user's live state left out. Without it any debug run that did not set
/// `GHOSTTY_ACCOUNT_STORE` read the signed-in user's relay credential, dialed
/// with it, and could RENEW it (`/oauth/renew` rotates the token and the
/// rotation is written back) underneath the installed app. A debug build now
/// starts signed out; signing in from it writes only its own file.
pub fn storeFileName(debug: bool) []const u8 {
    return if (debug) "account-debug.dat" else "account.dat";
}

/// Resolve the account store path:
///   1. `GHOSTTY_ACCOUNT_STORE` (explicit full-path override; tests use this),
///   2. Windows: `%LOCALAPPDATA%\ghoztty\<storeFileName>`,
///   3. Linux: `$XDG_DATA_HOME/ghoztty/<storeFileName>`, falling back to
///      `$HOME/.local/share/ghoztty/<storeFileName>` - the 0600 fallback file,
///      and the key of the Secret Service item when a keyring holds it (T3341),
///   4. else `$XDG_CONFIG_HOME/ghoztty/<storeFileName>`, falling back to
///      `$HOME/.config/ghoztty/<storeFileName>` (macOS test builds only).
/// `<storeFileName>` is `account.dat` for a release build and
/// `account-debug.dat` for a debug one. Owned by the caller.
pub fn accountPath(alloc: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_ACCOUNT_STORE")) |p| {
        if (p.len > 0) return p;
        alloc.free(p);
    } else |_| {}

    const name = storeFileName(build_config.is_debug);
    if (builtin.os.tag == .windows) {
        const local = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
        defer alloc.free(local);
        return std.fs.path.join(alloc, &.{ local, "ghoztty", name });
    } else if (builtin.os.tag == .linux) {
        if (std.process.getEnvVarOwned(alloc, "XDG_DATA_HOME")) |xdg| {
            defer alloc.free(xdg);
            if (xdg.len > 0) return std.fs.path.join(alloc, &.{ xdg, "ghoztty", name });
        } else |_| {}
        const home = try std.process.getEnvVarOwned(alloc, "HOME");
        defer alloc.free(home);
        return std.fs.path.join(alloc, &.{ home, ".local", "share", "ghoztty", name });
    } else {
        if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |xdg| {
            defer alloc.free(xdg);
            if (xdg.len > 0) return std.fs.path.join(alloc, &.{ xdg, "ghoztty", name });
        } else |_| {}
        const home = try std.process.getEnvVarOwned(alloc, "HOME");
        defer alloc.free(home);
        return std.fs.path.join(alloc, &.{ home, ".config", "ghoztty", name });
    }
}

/// The JSON shape persisted inside the (encrypted) blob. Every field optional
/// at parse time so one struct probes both the current and the legacy shape
/// (`refresh_token` present + `session_token` absent ⇒ pre-T93 store).
const Stored = struct {
    session_token: ?[]const u8 = null,
    expiry: ?i64 = null,
    email: ?[]const u8 = null,
    relay_base: ?[]const u8 = null,
    picture: ?[]const u8 = null,
    // Legacy (pre-T93) marker — never written anymore.
    refresh_token: ?[]const u8 = null,
};

/// Where a credential can live besides the file at the store path: the Linux
/// Secret Service (T3341). A seam so the tests drive a fake one and never the
/// person's real keyring.
pub const Keyring = struct {
    storeFn: *const fn (Allocator, []const u8, []const u8, []const u8) secret_service.Error!void,
    lookupFn: *const fn (Allocator, []const u8) secret_service.Error!?[]u8,
    clearFn: *const fn (Allocator, []const u8) secret_service.Error!void,
};

/// The machine's keyring, or null when the account must use the file: not
/// Linux, libsecret missing, or `GHOSTTY_ACCOUNT_KEYRING=off`. A test binary
/// never touches the real keyring unless `GHOZTTY_TEST_SECRET_SERVICE=1` asks
/// for it (`test/linux/secret-store.sh` sets that inside a private session
/// bus that runs its own keyring daemon).
pub fn systemKeyring() ?Keyring {
    if (comptime !secret_service.supported) return null;
    if (envEquals("GHOSTTY_ACCOUNT_KEYRING", "off")) return null;
    if (builtin.is_test and
        !envEquals("GHOZTTY_TEST_SECRET_SERVICE", "1") and
        !envEquals("GHOZTTY_TEST_SECRET_SERVICE", "absent")) return null;
    if (!secret_service.libraryLoaded()) return null;
    return .{
        .storeFn = secret_service.store,
        .lookupFn = secret_service.lookup,
        .clearFn = secret_service.clear,
    };
}

fn envEquals(name: []const u8, want: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return false;
    const v = std.posix.getenv(name) orelse return false;
    return std.mem.eql(u8, v, want);
}

/// Where the current sign-in is kept, for the account row to say so.
pub const Location = enum {
    /// The Secret Service (a keyring daemon answered).
    keyring,
    /// The private file at the store path (DPAPI-wrapped on Windows; on Linux
    /// the 0600 fallback used when no keyring runs).
    file,
    /// Signed out.
    none,
};

/// Which store holds the account at `path` right now.
pub fn location(alloc: Allocator, path: []const u8) Location {
    return locationIn(alloc, systemKeyring(), path);
}

pub fn locationIn(alloc: Allocator, keyring: ?Keyring, path: []const u8) Location {
    if (keyring) |kr| {
        if (kr.lookupFn(alloc, path)) |got| {
            if (got) |g| {
                std.crypto.secureZero(u8, g);
                alloc.free(g);
                return .keyring;
            }
        } else |_| {}
    }
    std.fs.cwd().access(path, .{}) catch return .none;
    return .file;
}

/// Encrypt + write `account` at `path` atomically, then tighten its DACL.
/// Parent directories are created. On POSIX the temp file is mode 0600.
/// On Linux with a keyring running the account goes to the keyring instead,
/// and any file at `path` is removed (T3341).
pub fn save(alloc: Allocator, path: []const u8, account: Account) !void {
    return saveIn(alloc, systemKeyring(), path, account);
}

pub fn saveIn(alloc: Allocator, keyring: ?Keyring, path: []const u8, account: Account) !void {
    const json = try std.json.Stringify.valueAlloc(alloc, .{
        .session_token = account.session_token,
        .expiry = account.expiry,
        .email = account.email,
        .relay_base = account.relay_base,
        .picture = account.picture,
    }, .{});
    defer {
        std.crypto.secureZero(u8, json);
        alloc.free(json);
    }

    if (keyring) |kr| keyring: {
        const label = std.fmt.allocPrint(alloc, "Ghoztty relay account ({s})", .{account.email}) catch break :keyring;
        defer alloc.free(label);
        kr.storeFn(alloc, path, label, json) catch |err| {
            log.info("account: keyring store failed ({}); using the private file", .{err});
            break :keyring;
        };
        // The keyring holds it now: a fallback copy on disk would be a second
        // credential nobody needs.
        std.fs.cwd().deleteFile(path) catch {};
        atomic_write.cleanStaging(path);
        return;
    }

    const blob = try protect(alloc, json);
    defer alloc.free(blob);

    // Staging sibling + rename via the shared recipe (`atomic_write`,
    // T183/T500); `.secret` stages the file 0600 on POSIX. A crashed earlier
    // save's staging debris is a (DPAPI-wrapped) credential — sweep it; safe
    // because account.dat has a single writer (the sign-in flow).
    try atomic_write.writeChunks(alloc, path, &.{blob}, .{ .secret = true });
    atomic_write.cleanStaging(path);

    // Owner-only, non-inherited DACL now that it holds a credential (no-op off
    // Windows; POSIX already got 0600). Best-effort.
    win_acl.harden(alloc, path);
}

/// Read + decrypt + parse the account at `path`. Returns an owned `Account`
/// (caller `deinit`s). `error.SignedOut` when the file is absent;
/// `error.Legacy` for a pre-T93 refresh-token store.
pub fn load(alloc: Allocator, path: []const u8) !Account {
    return loadIn(alloc, systemKeyring(), path);
}

pub fn loadIn(alloc: Allocator, keyring: ?Keyring, path: []const u8) !Account {
    if (keyring) |kr| {
        if (kr.lookupFn(alloc, path)) |got| {
            if (got) |json| {
                defer {
                    std.crypto.secureZero(u8, json);
                    alloc.free(json);
                }
                return parseStored(alloc, json);
            }
        } else |_| {}
    }

    const blob = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return Error.SignedOut,
        else => return err,
    };
    defer alloc.free(blob);

    const json = unprotect(alloc, blob) catch return Error.Corrupt;
    defer alloc.free(json);
    return parseStored(alloc, json);
}

fn parseStored(alloc: Allocator, json: []const u8) !Account {
    const parsed = std.json.parseFromSlice(
        Stored,
        alloc,
        json,
        .{ .ignore_unknown_fields = true },
    ) catch return Error.Corrupt;
    defer parsed.deinit();

    const token = parsed.value.session_token orelse {
        // No session token: a pre-T93 store if it carries the old credential,
        // otherwise plain corruption.
        return if (parsed.value.refresh_token != null) Error.Legacy else Error.Corrupt;
    };

    // Copy out of the parsed arena into caller-owned slices.
    var acct: Account = .{
        .session_token = try alloc.dupe(u8, token),
        .expiry = parsed.value.expiry orelse 0,
        .email = try alloc.dupe(u8, parsed.value.email orelse ""),
        .relay_base = try alloc.dupe(u8, parsed.value.relay_base orelse ""),
        .picture = null,
    };
    errdefer acct.deinit(alloc);
    if (parsed.value.picture) |p| acct.picture = try alloc.dupe(u8, p);
    return acct;
}

/// Delete account.dat (sign out), and any staging sibling a crashed save left
/// behind — that debris is a credential too. A missing file is success.
pub fn delete(path: []const u8) void {
    deleteIn(std.heap.page_allocator, systemKeyring(), path);
}

pub fn deleteIn(alloc: Allocator, keyring: ?Keyring, path: []const u8) void {
    if (keyring) |kr| kr.clearFn(alloc, path) catch |err| {
        log.warn("account: clearing the keyring item failed: {}", .{err});
    };
    std.fs.cwd().deleteFile(path) catch {};
    atomic_write.cleanStaging(path);
}

/// Whether a signed-in account exists (cheap: file presence, no decrypt; on
/// Linux with a keyring, one Secret Service lookup first).
pub fn isSignedIn(alloc: Allocator, path: []const u8) bool {
    return location(alloc, path) != .none;
}

/// Resolve a live relay bearer from the stored account: the cached session
/// token while it has >60s of life left, else a renewed (rotated) one from the
/// stored relay's `/oauth/renew` — the rotation is persisted before returning
/// (the old token is dead server-side the moment renew succeeds). This is the
/// GUI's account tier. Returns an owned token (caller frees).
/// `error.SignedOut` / `error.Legacy` when no usable account is stored;
/// `error.Unauthorized` when the relay refused the renewal (sign in again).
pub fn resolveSessionToken(alloc: Allocator, path: []const u8) ![]u8 {
    const keyring = systemKeyring();
    var account = try loadIn(alloc, keyring, path);
    defer account.deinit(alloc);

    if (account.isFresh(std.time.timestamp())) {
        return alloc.dupe(u8, account.session_token);
    }

    var renewed = try relay_session.renew(alloc, account.relay_base, account.session_token);
    defer renewed.deinit();

    const owned = try alloc.dupe(u8, renewed.value.session_token);
    errdefer alloc.free(owned);

    // Persist the rotation. A failed re-save is logged but does not fail this
    // resolution — the minted token is valid for this call; only the NEXT
    // resolve would find a stale store (and land in Unauthorized → re-login).
    saveIn(alloc, keyring, path, .{
        .session_token = renewed.value.session_token,
        .expiry = renewed.value.expiry,
        .email = renewed.value.email,
        .relay_base = account.relay_base,
        .picture = renewed.value.picture,
    }) catch |err| {
        log.warn("account: persisting rotated session token failed: {}", .{err});
    };
    return owned;
}

// =============================================================================
// DPAPI seam (per-user encryption at rest)
// =============================================================================

/// Encrypt `plaintext` for the current user. Windows: DPAPI. Elsewhere:
/// identity passthrough (compile/off-box only — see the file header).
fn protect(alloc: Allocator, plaintext: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) return dpapi.protect(alloc, plaintext);
    return alloc.dupe(u8, plaintext);
}

/// Inverse of `protect`.
fn unprotect(alloc: Allocator, blob: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) return dpapi.unprotect(alloc, blob);
    return alloc.dupe(u8, blob);
}

const dpapi = struct {
    const W = std.os.windows;
    const DWORD = W.DWORD;
    const BOOL = W.BOOL;

    const DATA_BLOB = extern struct {
        cbData: DWORD,
        pbData: ?[*]u8,
    };

    // CRYPTPROTECT_UI_FORBIDDEN — never prompt (we run headless in the CLI/GUI).
    const CRYPTPROTECT_UI_FORBIDDEN: DWORD = 0x1;

    extern "crypt32" fn CryptProtectData(
        pDataIn: *DATA_BLOB,
        szDataDescr: ?[*:0]const u16,
        pOptionalEntropy: ?*DATA_BLOB,
        pvReserved: ?*anyopaque,
        pPromptStruct: ?*anyopaque,
        dwFlags: DWORD,
        pDataOut: *DATA_BLOB,
    ) callconv(.winapi) BOOL;

    extern "crypt32" fn CryptUnprotectData(
        pDataIn: *DATA_BLOB,
        ppszDataDescr: ?*?[*:0]u16,
        pOptionalEntropy: ?*DATA_BLOB,
        pvReserved: ?*anyopaque,
        pPromptStruct: ?*anyopaque,
        dwFlags: DWORD,
        pDataOut: *DATA_BLOB,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

    fn protect(alloc: Allocator, plaintext: []const u8) ![]u8 {
        var in: DATA_BLOB = .{ .cbData = @intCast(plaintext.len), .pbData = @constCast(plaintext.ptr) };
        var out: DATA_BLOB = .{ .cbData = 0, .pbData = null };
        if (CryptProtectData(&in, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &out) == 0) {
            return error.DpapiFailed;
        }
        defer _ = LocalFree(out.pbData);
        const ptr = out.pbData orelse return error.DpapiFailed;
        return alloc.dupe(u8, ptr[0..out.cbData]);
    }

    fn unprotect(alloc: Allocator, blob: []const u8) ![]u8 {
        var in: DATA_BLOB = .{ .cbData = @intCast(blob.len), .pbData = @constCast(blob.ptr) };
        var out: DATA_BLOB = .{ .cbData = 0, .pbData = null };
        if (CryptUnprotectData(&in, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &out) == 0) {
            return error.DpapiFailed;
        }
        defer _ = LocalFree(out.pbData);
        const ptr = out.pbData orelse return error.DpapiFailed;
        return alloc.dupe(u8, ptr[0..out.cbData]);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn tmpAccountPath(alloc: Allocator, tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    return std.fs.path.join(alloc, &.{ dir_path, name });
}

test "account store: save then load round-trips (with and without picture)" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account.dat");
    defer alloc.free(path);

    // With a picture.
    try save(alloc, path, .{
        .session_token = "sess-123",
        .expiry = 1893456000,
        .email = "user@example.com",
        .relay_base = "https://relay.example.com",
        .picture = "https://x/y.png",
    });
    {
        var got = try load(alloc, path);
        defer got.deinit(alloc);
        try testing.expectEqualStrings("sess-123", got.session_token);
        try testing.expectEqual(@as(i64, 1893456000), got.expiry);
        try testing.expectEqualStrings("user@example.com", got.email);
        try testing.expectEqualStrings("https://relay.example.com", got.relay_base);
        try testing.expectEqualStrings("https://x/y.png", got.picture.?);
    }

    // Overwrite without a picture: round-trips as null.
    try save(alloc, path, .{
        .session_token = "sess-456",
        .expiry = 1,
        .email = "user@example.com",
        .relay_base = "https://relay.example.com",
        .picture = null,
    });
    {
        var got = try load(alloc, path);
        defer got.deinit(alloc);
        try testing.expect(got.picture == null);
        try testing.expectEqualStrings("sess-456", got.session_token);
    }

    // A crashed pre-save's staging debris is a credential: save sweeps it, and
    // no staging leftover of ANY name survives — the directory holds exactly
    // the published file (T500).
    try tmp.dir.writeFile(.{ .sub_path = "account.dat.tmp", .data = "debris" });
    try save(alloc, path, .{ .session_token = "s", .expiry = 0, .email = "e", .relay_base = "b" });
    {
        const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
        defer alloc.free(dir_path);
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var count: usize = 0;
        while (try it.next()) |entry| {
            count += 1;
            try testing.expectEqualStrings("account.dat", entry.name);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "account store: load on a missing file is SignedOut" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "nope.dat");
    defer alloc.free(path);

    try testing.expect(!isSignedIn(alloc, path));
    try testing.expectError(Error.SignedOut, load(alloc, path));
}

test "account store: a pre-T93 refresh-token store is Legacy" {
    // Off-Windows the DPAPI seam is identity, so a raw legacy JSON file IS a
    // valid legacy blob; on Windows this test writes through `protect` the
    // same way the old code did — either way `load` must classify, not parse.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account.dat");
    defer alloc.free(path);

    const legacy_json =
        \\{"client_id":"cid","client_secret":"sec","refresh_token":"rt","email":"e@x.com"}
    ;
    const blob = try protect(alloc, legacy_json);
    defer alloc.free(blob);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = blob });

    try testing.expect(isSignedIn(alloc, path)); // file presence only
    try testing.expectError(Error.Legacy, load(alloc, path));
}

test "account store: garbage without either token shape is Corrupt" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account.dat");
    defer alloc.free(path);

    const blob = try protect(alloc, "{\"email\":\"only\"}");
    defer alloc.free(blob);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = blob });
    try testing.expectError(Error.Corrupt, load(alloc, path));
}

test "account store: delete removes the file (idempotent)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account.dat");
    defer alloc.free(path);

    try save(alloc, path, .{
        .session_token = "s",
        .expiry = 0,
        .email = "e",
        .relay_base = "b",
    });
    try testing.expect(isSignedIn(alloc, path));
    // Sign-out must also drop a crashed save's staging debris — it holds the
    // credential too (unique-name form, T500).
    try tmp.dir.writeFile(.{ .sub_path = "account.dat.00112233aabbccdd.tmp", .data = "debris" });
    delete(path);
    try testing.expect(!isSignedIn(alloc, path));
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile("account.dat.00112233aabbccdd.tmp"),
    );
    delete(path); // idempotent: no error on a second delete
}

test "T1859: a debug build's account store is not the release one" {
    try testing.expectEqualStrings("account.dat", storeFileName(false));
    try testing.expectEqualStrings("account-debug.dat", storeFileName(true));
    try testing.expect(!std.mem.eql(u8, storeFileName(false), storeFileName(true)));
}

test "T1859: accountPath picks the store for this build's lineage" {
    const alloc = testing.allocator;
    // An explicit override wins by design; this test is about the default.
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_ACCOUNT_STORE")) |p| {
        alloc.free(p);
        return error.SkipZigTest;
    } else |_| {}

    const path = try accountPath(alloc);
    defer alloc.free(path);
    try testing.expectEqualStrings(storeFileName(build_config.is_debug), std.fs.path.basename(path));
    // Test lanes build in Debug: the path a dev or test run resolves must
    // never be the signed-in user's file.
    if (build_config.is_debug) {
        try testing.expect(!std.mem.eql(u8, "account.dat", std.fs.path.basename(path)));
    }
}

/// An in-memory keyring for the routing tests: one item, and a switch that
/// makes every call fail the way a missing Secret Service does.
const FakeKeyring = struct {
    var key: ?[]u8 = null;
    var secret: ?[]u8 = null;
    var down: bool = false;

    fn reset() void {
        if (key) |k| testing.allocator.free(k);
        if (secret) |s| testing.allocator.free(s);
        key = null;
        secret = null;
        down = false;
    }

    fn storeFn(_: Allocator, k: []const u8, _: []const u8, s: []const u8) secret_service.Error!void {
        if (down) return secret_service.Error.ServiceFailed;
        if (key) |old| testing.allocator.free(old);
        if (secret) |old| testing.allocator.free(old);
        key = try testing.allocator.dupe(u8, k);
        secret = try testing.allocator.dupe(u8, s);
    }

    fn lookupFn(alloc: Allocator, k: []const u8) secret_service.Error!?[]u8 {
        if (down) return secret_service.Error.ServiceFailed;
        const have = key orelse return null;
        if (!std.mem.eql(u8, have, k)) return null;
        return try alloc.dupe(u8, secret.?);
    }

    fn clearFn(_: Allocator, k: []const u8) secret_service.Error!void {
        if (down) return secret_service.Error.ServiceFailed;
        const have = key orelse return;
        if (!std.mem.eql(u8, have, k)) return;
        reset();
    }

    const keyring: Keyring = .{ .storeFn = storeFn, .lookupFn = lookupFn, .clearFn = clearFn };
};

const sample_account: Account = .{
    .session_token = "sess-kr",
    .expiry = 1893456000,
    .email = "user@example.com",
    .relay_base = "https://relay.example.com",
};

test "T3341: with a keyring the account goes there and no file is written" {
    const alloc = testing.allocator;
    FakeKeyring.reset();
    defer FakeKeyring.reset();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account-debug.dat");
    defer alloc.free(path);

    try saveIn(alloc, FakeKeyring.keyring, path, sample_account);
    try testing.expectEqualStrings(path, FakeKeyring.key.?);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile("account-debug.dat"));
    try testing.expectEqual(Location.keyring, locationIn(alloc, FakeKeyring.keyring, path));

    var got = try loadIn(alloc, FakeKeyring.keyring, path);
    defer got.deinit(alloc);
    try testing.expectEqualStrings("sess-kr", got.session_token);
    try testing.expectEqualStrings("user@example.com", got.email);

    deleteIn(alloc, FakeKeyring.keyring, path);
    try testing.expect(FakeKeyring.key == null);
    try testing.expectEqual(Location.none, locationIn(alloc, FakeKeyring.keyring, path));
}

test "T3341: no Secret Service answering falls back to the 0600 file" {
    const alloc = testing.allocator;
    FakeKeyring.reset();
    defer FakeKeyring.reset();
    FakeKeyring.down = true;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account-debug.dat");
    defer alloc.free(path);

    try saveIn(alloc, FakeKeyring.keyring, path, sample_account);
    const st = try tmp.dir.statFile("account-debug.dat");
    if (builtin.os.tag != .windows) {
        try testing.expectEqual(@as(std.fs.File.Mode, 0o600), st.mode & 0o777);
    }
    try testing.expectEqual(Location.file, locationIn(alloc, FakeKeyring.keyring, path));

    var got = try loadIn(alloc, FakeKeyring.keyring, path);
    defer got.deinit(alloc);
    try testing.expectEqualStrings("sess-kr", got.session_token);

    deleteIn(alloc, FakeKeyring.keyring, path);
    try testing.expectEqual(Location.none, locationIn(alloc, FakeKeyring.keyring, path));
}

test "T3341: a keyring that appears later absorbs the fallback file on the next save" {
    const alloc = testing.allocator;
    FakeKeyring.reset();
    defer FakeKeyring.reset();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account-debug.dat");
    defer alloc.free(path);

    // Signed in while no keyring ran: the file holds it.
    FakeKeyring.down = true;
    try saveIn(alloc, FakeKeyring.keyring, path, sample_account);
    try testing.expectEqual(Location.file, locationIn(alloc, FakeKeyring.keyring, path));

    // A keyring starts. The file still answers until the next save (a renewal
    // rotates the token and saves), which moves it and removes the file.
    FakeKeyring.down = false;
    {
        var got = try loadIn(alloc, FakeKeyring.keyring, path);
        defer got.deinit(alloc);
        try testing.expectEqualStrings("sess-kr", got.session_token);
    }
    var rotated = sample_account;
    rotated.session_token = "sess-rotated";
    try saveIn(alloc, FakeKeyring.keyring, path, rotated);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile("account-debug.dat"));
    try testing.expectEqual(Location.keyring, locationIn(alloc, FakeKeyring.keyring, path));
    var got = try loadIn(alloc, FakeKeyring.keyring, path);
    defer got.deinit(alloc);
    try testing.expectEqualStrings("sess-rotated", got.session_token);
}

test "T3341: keyring items are keyed by store path, so debug never reads release" {
    const alloc = testing.allocator;
    FakeKeyring.reset();
    defer FakeKeyring.reset();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const release = try tmpAccountPath(alloc, &tmp, storeFileName(false));
    defer alloc.free(release);
    const debug = try tmpAccountPath(alloc, &tmp, storeFileName(true));
    defer alloc.free(debug);

    try saveIn(alloc, FakeKeyring.keyring, release, sample_account);
    try testing.expectEqual(Location.none, locationIn(alloc, FakeKeyring.keyring, debug));
    try testing.expectError(Error.SignedOut, loadIn(alloc, FakeKeyring.keyring, debug));
}

test "T3341: a unit-test binary never reaches the person's real keyring by default" {
    if (std.process.getEnvVarOwned(testing.allocator, "GHOZTTY_TEST_SECRET_SERVICE")) |v| {
        testing.allocator.free(v);
        return error.SkipZigTest;
    } else |_| {}
    try testing.expect(systemKeyring() == null);
}

test "T3341: Linux keeps the fallback file under XDG_DATA_HOME" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = testing.allocator;
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_ACCOUNT_STORE")) |p| {
        alloc.free(p);
        return error.SkipZigTest;
    } else |_| {}
    const path = try accountPath(alloc);
    defer alloc.free(path);
    const want_tail = try std.fs.path.join(alloc, &.{ "ghoztty", storeFileName(build_config.is_debug) });
    defer alloc.free(want_tail);
    try testing.expect(std.mem.endsWith(u8, path, want_tail));
    if (std.posix.getenv("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) try testing.expect(std.mem.startsWith(u8, path, xdg));
    } else {
        try testing.expect(std.mem.indexOf(u8, path, "/.local/share/") != null);
    }
}

test "T3341: with libsecret loaded but no daemon the real store falls back to the file" {
    // Opt-in (`test/linux/secret-store.sh`, inside a private session bus with
    // NO keyring daemon - the WSL default, reproduced on purpose).
    const want = std.process.getEnvVarOwned(testing.allocator, "GHOZTTY_TEST_SECRET_SERVICE") catch
        return error.SkipZigTest;
    defer testing.allocator.free(want);
    if (!std.mem.eql(u8, want, "absent")) return error.SkipZigTest;

    const alloc = testing.allocator;
    const kr = systemKeyring() orelse return error.TestExpectedLibsecret;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account-debug.dat");
    defer alloc.free(path);

    try saveIn(alloc, kr, path, sample_account);
    const st = try tmp.dir.statFile("account-debug.dat");
    try testing.expectEqual(@as(std.fs.File.Mode, 0o600), st.mode & 0o777);
    try testing.expectEqual(Location.file, locationIn(alloc, kr, path));
    {
        var got = try loadIn(alloc, kr, path);
        defer got.deinit(alloc);
        try testing.expectEqualStrings("sess-kr", got.session_token);
    }
    deleteIn(alloc, kr, path);
    try testing.expectEqual(Location.none, locationIn(alloc, kr, path));
    markRan("ABSENT libsecret loaded, no daemon answered, the account went to a 0600 file and was deleted");
}

/// Append one line to `$GHOZTTY_TEST_SECRET_SERVICE_MARK`, so the acceptance
/// script can tell an opt-in test that RAN and passed from one that skipped
/// (the build runner reports both as a green step).
fn markRan(line: []const u8) void {
    if (comptime builtin.os.tag == .windows) return;
    const p =std.posix.getenv("GHOZTTY_TEST_SECRET_SERVICE_MARK") orelse return;
    const f = std.fs.cwd().createFile(p, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch return;
    f.writeAll(line) catch return;
    f.writeAll("\n") catch return;
}

test "T3341: the real Secret Service round-trips (test/linux/secret-store.sh)" {
    // Opt-in: only inside a private session bus with its own keyring daemon,
    // never against the person's keyring.
    const want = std.process.getEnvVarOwned(testing.allocator, "GHOZTTY_TEST_SECRET_SERVICE") catch
        return error.SkipZigTest;
    defer testing.allocator.free(want);
    if (!std.mem.eql(u8, want, "1")) return error.SkipZigTest;

    const alloc = testing.allocator;
    const kr = systemKeyring() orelse return error.TestExpectedKeyring;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpAccountPath(alloc, &tmp, "account-debug.dat");
    defer alloc.free(path);

    try saveIn(alloc, kr, path, sample_account);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile("account-debug.dat"));
    try testing.expectEqual(Location.keyring, locationIn(alloc, kr, path));
    {
        var got = try loadIn(alloc, kr, path);
        defer got.deinit(alloc);
        try testing.expectEqualStrings("sess-kr", got.session_token);
        try testing.expectEqualStrings("https://relay.example.com", got.relay_base);
    }
    markRan("ROUNDTRIP stored in the keyring, no file written, found and read back");

    deleteIn(alloc, kr, path);
    try testing.expectEqual(Location.none, locationIn(alloc, kr, path));
    markRan("CLEAR the keyring item is gone after sign-out");
}

test "isFresh honors the 60s leeway" {
    const acct: Account = .{
        .session_token = "s",
        .expiry = 1000,
        .email = "e",
        .relay_base = "b",
    };
    try testing.expect(acct.isFresh(900)); // 100s left
    try testing.expect(!acct.isFresh(950)); // 50s left — within leeway
    try testing.expect(!acct.isFresh(2000)); // expired
}

test {
    testing.refAllDecls(@This());
}
