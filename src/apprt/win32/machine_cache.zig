//! The machine chooser's WARM DEVICE CACHE (T711) — the win32 twin of Mac's
//! persisted machine registry (`66012e2ee`).
//!
//! ## Why a cache at all
//! The chooser used to learn the account's machines by asking the relay when
//! the dialog opened, on the GUI thread. That is one authenticated HTTPS round
//! trip — often preceded by an OAuth refresh — between ctrl+shift+n and a list
//! with anything in it, every single time. Mac solved it by remembering the
//! last answer and showing it INSTANTLY, with each remembered row marked
//! "checking" until the live answer confirms it. This is that store.
//!
//! ## What is remembered, and what deliberately is not
//! Identity only: device id, display name, hostname. Never a token, and never
//! `online` — reachability is a fact about RIGHT NOW, and a remembered dot
//! would be a confident lie about a machine that went offline overnight. A
//! seeded row therefore has no presence at all until the fetch answers, which
//! is exactly what `chooser_rows.Status.checking` draws.
//!
//! ## Account scoping is the safety property
//! The blob carries the account it was fetched for, and `load` hands back
//! nothing when that does not match the account signed in now. Sign-out, a
//! credential-less refresh and a 401 all `clear()` it outright, so a cached
//! device list can never outlive the authorization that produced it — the same
//! contract Mac's `clearRelayMachines()` carries.
//!
//! Format and account matching are pure and unit-tested here; the file IO is
//! the `chooser_session_sort` pattern (LOCALAPPDATA, its own debug-build file
//! so a dev instance never writes the release app's cache).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.win32);

/// One remembered machine. `hostname` is optional because the relay's own
/// device record makes it optional.
pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    hostname: ?[]const u8 = null,
};

/// The on-disk blob: the account the list belongs to, plus the machines.
pub const Snapshot = struct {
    account: []const u8 = "",
    devices: []const Entry = &.{},
};

pub const Parsed = std.json.Parsed(Snapshot);

/// Hard cap on what is read back, so a corrupt or hostile file cannot make the
/// chooser allocate without bound on the GUI thread.
pub const max_bytes: usize = 256 * 1024;

/// Cap on remembered machines. The chooser renders at most
/// `MachineChooser.MAX_DEVICES`; remembering more would seed rows that can
/// never be drawn.
pub const max_entries: usize = 128;

/// Whether a cache written for `cached` may be shown to `current`.
///
/// Pure, and the whole of the account-scoping rule: emails are matched
/// case-insensitively (the relay and the OAuth provider disagree about case
/// more often than users do), and the empty account — a credential that came
/// from `GHOSTTY_RELAY_TOKEN` rather than a signed-in Google account — is its
/// own bucket rather than a wildcard. A wildcard is how one account's machine
/// names would appear under another's sign-in.
pub fn accountMatches(cached: []const u8, current: []const u8) bool {
    return std.ascii.eqlIgnoreCase(cached, current);
}

/// The blob for `account` + `entries`, as bytes. Caller frees.
pub fn serialize(alloc: Allocator, account: []const u8, entries: []const Entry) ?[]u8 {
    const capped = if (entries.len > max_entries) entries[0..max_entries] else entries;
    return std.json.Stringify.valueAlloc(
        alloc,
        Snapshot{ .account = account, .devices = capped },
        .{},
    ) catch null;
}

/// Parse a blob. Null on anything unreadable — a cache is an optimization, so
/// every failure here is "no cache", never an error the user hears about.
pub fn parse(alloc: Allocator, bytes: []const u8) ?Parsed {
    return std.json.parseFromSlice(Snapshot, alloc, bytes, .{
        .ignore_unknown_fields = true,
        // The strings must be COPIES: `bytes` is the file buffer and is freed
        // the moment `load` returns, and a device name pointing into it would
        // be drawn from freed memory on the first repaint.
        .allocate = .alloc_always,
    }) catch null;
}

/// Where the cache lives, or null when LOCALAPPDATA is unset.
pub fn cachePath(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    const name = if (builtin.mode == .Debug)
        "machines-debug.json"
    else
        "machines.json";
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

/// The remembered machines for `account`, or null when there are none, the
/// file is unreadable, or it belongs to a DIFFERENT account. The caller owns
/// the returned `Parsed` and must `deinit` it.
pub fn load(alloc: Allocator, account: []const u8) ?Parsed {
    const path = cachePath(alloc) orelse return null;
    defer alloc.free(path);
    const f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    const bytes = f.readToEndAlloc(alloc, max_bytes) catch return null;
    defer alloc.free(bytes);
    const parsed = parse(alloc, bytes) orelse return null;
    if (!accountMatches(parsed.value.account, account)) {
        // Not this account's list. Drop it rather than keeping it around: the
        // signed-in account changed, and the old one's machines are no longer
        // ours to show.
        parsed.deinit();
        return null;
    }
    return parsed;
}

/// Remember `entries` as `account`'s machine list. Silent on failure — a cache
/// that could not be written costs a slow first open, nothing else.
pub fn save(alloc: Allocator, account: []const u8, entries: []const Entry) void {
    const path = cachePath(alloc) orelse return;
    defer alloc.free(path);
    const json = serialize(alloc, account, entries) orelse return;
    defer alloc.free(json);
    if (std.fs.path.dirname(path)) |dir| std.fs.makeDirAbsolute(dir) catch {};
    const f = std.fs.createFileAbsolute(path, .{}) catch return;
    defer f.close();
    f.writeAll(json) catch {};
}

/// The name a relay window gives the machine `device` (T1418), from a directory
/// listing or the remembered one: the account's friendly name, else the
/// machine's own hostname, else null — and null is the caller's cue to fall
/// back to the device id, which is Mac's order (`AppDelegate`'s
/// `fallbackName ?? reportedHostname ?? device`). A blank name counts as none,
/// so a pill can never be named by an empty string.
///
/// Pure; borrows `entries`.
pub fn nameFor(entries: []const Entry, device: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (!std.mem.eql(u8, e.id, device)) continue;
        if (e.name.len > 0) return e.name;
        if (e.hostname) |h| if (h.len > 0) return h;
        return null;
    }
    return null;
}

/// `nameFor` against the REMEMBERED list for `account`, duped onto `alloc`.
/// Null when there is no cache for this account or it does not know `device`.
/// This is how a window that never saw a directory — restored at startup, or
/// opened by `+new-remote-window --device=…` — is named before any listing
/// lands.
pub fn loadName(alloc: Allocator, account: []const u8, device: []const u8) ?[]u8 {
    const cached = load(alloc, account) orelse return null;
    defer cached.deinit();
    const name = nameFor(cached.value.devices, device) orelse return null;
    return alloc.dupe(u8, name) catch null;
}

/// Forget everything. Called on sign-out and on any 401 — see the account
/// scoping note at the top of the file.
pub fn clear(alloc: Allocator) void {
    const path = cachePath(alloc) orelse return;
    defer alloc.free(path);
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("machine cache: clear failed err={}", .{err}),
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "serialize/parse: a machine list round-trips" {
    const entries = [_]Entry{
        .{ .id = "d1", .name = "Winbox", .hostname = "winbox.local" },
        .{ .id = "d2", .name = "Laptop" },
    };
    const bytes = serialize(testing.allocator, "a@b.com", &entries).?;
    defer testing.allocator.free(bytes);

    const parsed = parse(testing.allocator, bytes).?;
    defer parsed.deinit();
    try testing.expectEqualStrings("a@b.com", parsed.value.account);
    try testing.expectEqual(@as(usize, 2), parsed.value.devices.len);
    try testing.expectEqualStrings("d1", parsed.value.devices[0].id);
    try testing.expectEqualStrings("winbox.local", parsed.value.devices[0].hostname.?);
    try testing.expect(parsed.value.devices[1].hostname == null);
}

test "serialize: presence is NEVER remembered" {
    const entries = [_]Entry{.{ .id = "d1", .name = "Winbox" }};
    const bytes = serialize(testing.allocator, "a@b.com", &entries).?;
    defer testing.allocator.free(bytes);
    // A remembered dot would be a confident lie about a machine that went
    // offline overnight, so the word must not be in the blob at all.
    try testing.expect(std.mem.indexOf(u8, bytes, "online") == null);
}

test "serialize: the entry cap bounds what a seed can cost" {
    var many: [max_entries + 5]Entry = undefined;
    for (&many) |*e| e.* = .{ .id = "x", .name = "y" };
    const bytes = serialize(testing.allocator, "", &many).?;
    defer testing.allocator.free(bytes);
    const parsed = parse(testing.allocator, bytes).?;
    defer parsed.deinit();
    try testing.expectEqual(max_entries, parsed.value.devices.len);
}

test "parse: garbage is 'no cache', never an error" {
    try testing.expect(parse(testing.allocator, "not json at all") == null);
    try testing.expect(parse(testing.allocator, "") == null);
}

test "parse: an unknown field the relay adds later does not void the cache" {
    const parsed = parse(
        testing.allocator,
        \\{"account":"a@b.com","devices":[{"id":"d1","name":"N","kind":"server"}],"v":2}
    ).?;
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.devices.len);
}

test "nameFor: friendly name, then hostname, then null for the device id (T1418)" {
    const entries = [_]Entry{
        .{ .id = "d1", .name = "MaximusHome", .hostname = "maximus" },
        .{ .id = "d2", .name = "", .hostname = "laptop.local" },
        .{ .id = "d3", .name = "" },
        .{ .id = "d4", .name = "", .hostname = "" },
    };
    try testing.expectEqualStrings("MaximusHome", nameFor(&entries, "d1").?);
    try testing.expectEqualStrings("laptop.local", nameFor(&entries, "d2").?);
    // Blank everywhere is "no name", never an empty pill.
    try testing.expect(nameFor(&entries, "d3") == null);
    try testing.expect(nameFor(&entries, "d4") == null);
    // A machine the listing never mentioned.
    try testing.expect(nameFor(&entries, "nope") == null);
    try testing.expect(nameFor(&.{}, "d1") == null);
}

test "accountMatches: case folds, and the token bucket is not a wildcard" {
    try testing.expect(accountMatches("A@B.com", "a@b.com"));
    try testing.expect(accountMatches("", ""));
    try testing.expect(!accountMatches("a@b.com", "c@d.com"));
    // The env-token bucket must not show up under a signed-in account, and a
    // signed-in account's machines must not show up for a bare token.
    try testing.expect(!accountMatches("", "a@b.com"));
    try testing.expect(!accountMatches("a@b.com", ""));
}
