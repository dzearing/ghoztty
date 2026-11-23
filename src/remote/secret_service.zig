//! The Linux secret store: libsecret (the freedesktop Secret Service), loaded
//! at run time (T3341).
//!
//! This is the Linux row of the translation table in
//! `docs/design/linux-port.md`: Keychain on macOS, DPAPI on Windows, the
//! Secret Service on Linux. `relay_account` keeps the signed-in relay session
//! here when a keyring daemon answers, and falls back to a mode-0600 file when
//! none does - which is the WSL default, because WSL runs no keyring daemon.
//!
//! ## Why it is loaded, not linked
//! `libsecret-1.so.0` is looked up with `dlopen` on first use instead of being
//! a link dependency of the shared core. The account store is compiled into
//! the GUI, the none-lane test binary and the agent alike, and a hard link
//! would make every one of them refuse to START on a machine without
//! libsecret, to save a credential most of them never touch. A missing library
//! is the same answer as a missing daemon: no keyring, use the file.
//!
//! ## What is stored
//! One generic password under the schema `com.dzearing.ghoztty.relay-account`
//! (the Mac's Keychain service name, so a person looking in Seahorse and in
//! Keychain Access finds the same name), keyed by a single string attribute
//! `store` whose value is the account store path. Keying by the path keeps the
//! T1859 split - a debug build's `account-debug.dat` and a release build's
//! `account.dat` are different items - and keeps a test's
//! `GHOSTTY_ACCOUNT_STORE` override away from the person's real item.
//!
//! Only the non-variadic `v` entry points are bound (`secret_password_storev_sync`
//! and friends), which take the attributes as a `GHashTable`; that is why
//! four glib symbols are loaded alongside.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.secret_service);

/// The schema name, shared with the Mac's Keychain service name.
pub const schema_name = "com.dzearing.ghoztty.relay-account";
/// The one attribute that keys an item.
pub const key_attribute = "store";

/// Whether this build can talk to the Secret Service at all. Linux only, and
/// only when libc is linked (`dlopen` needs the real dynamic loader).
pub const supported = builtin.os.tag == .linux and builtin.link_libc;

// ---------------------------------------------------------------------------
// The C ABI (libsecret 0.21 / glib 2.x). Layouts follow secret-schema.h.
// ---------------------------------------------------------------------------

const SchemaAttribute = extern struct {
    name: ?[*:0]const u8,
    /// SECRET_SCHEMA_ATTRIBUTE_STRING = 0.
    type: c_int,
};

const Schema = extern struct {
    name: [*:0]const u8,
    /// SECRET_SCHEMA_NONE = 0.
    flags: c_int,
    attributes: [32]SchemaAttribute,
    reserved: c_int = 0,
    reserved1: ?*anyopaque = null,
    reserved2: ?*anyopaque = null,
    reserved3: ?*anyopaque = null,
    reserved4: ?*anyopaque = null,
    reserved5: ?*anyopaque = null,
    reserved6: ?*anyopaque = null,
    reserved7: ?*anyopaque = null,
};

const GError = extern struct {
    domain: u32,
    code: c_int,
    message: ?[*:0]const u8,
};

const GHashFunc = *const fn (?*const anyopaque) callconv(.c) c_uint;
const GEqualFunc = *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;

const Api = struct {
    secret: std.DynLib,
    glib: std.DynLib,

    storev: *const fn (*const Schema, *anyopaque, ?[*:0]const u8, [*:0]const u8, [*:0]const u8, ?*anyopaque, *?*GError) callconv(.c) c_int,
    lookupv: *const fn (*const Schema, *anyopaque, ?*anyopaque, *?*GError) callconv(.c) ?[*:0]u8,
    clearv: *const fn (*const Schema, *anyopaque, ?*anyopaque, *?*GError) callconv(.c) c_int,
    password_free: *const fn (?[*:0]u8) callconv(.c) void,

    hash_table_new: *const fn (GHashFunc, GEqualFunc) callconv(.c) ?*anyopaque,
    hash_table_insert: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    hash_table_unref: *const fn (*anyopaque) callconv(.c) void,
    str_hash: GHashFunc,
    str_equal: GEqualFunc,
    error_free: *const fn (*GError) callconv(.c) void,
};

const schema: Schema = blk: {
    var s: Schema = .{
        .name = schema_name,
        .flags = 0,
        .attributes = [_]SchemaAttribute{.{ .name = null, .type = 0 }} ** 32,
    };
    s.attributes[0] = .{ .name = key_attribute, .type = 0 };
    break :blk s;
};

var api_once = std.once(loadApi);
var api: ?Api = null;

fn loadApi() void {
    if (comptime !supported) return;
    api = openApi() catch |err| {
        log.info("secret service: libsecret unavailable ({}); the account uses the private file", .{err});
        return;
    };
}

fn openApi() !Api {
    var secret = try std.DynLib.open("libsecret-1.so.0");
    errdefer secret.close();
    var glib = try std.DynLib.open("libglib-2.0.so.0");
    errdefer glib.close();

    var a: Api = undefined;
    a.secret = secret;
    a.glib = glib;
    a.storev = secret.lookup(@TypeOf(a.storev), "secret_password_storev_sync") orelse return error.SymbolMissing;
    a.lookupv = secret.lookup(@TypeOf(a.lookupv), "secret_password_lookupv_sync") orelse return error.SymbolMissing;
    a.clearv = secret.lookup(@TypeOf(a.clearv), "secret_password_clearv_sync") orelse return error.SymbolMissing;
    a.password_free = secret.lookup(@TypeOf(a.password_free), "secret_password_free") orelse return error.SymbolMissing;
    a.hash_table_new = glib.lookup(@TypeOf(a.hash_table_new), "g_hash_table_new") orelse return error.SymbolMissing;
    a.hash_table_insert = glib.lookup(@TypeOf(a.hash_table_insert), "g_hash_table_insert") orelse return error.SymbolMissing;
    a.hash_table_unref = glib.lookup(@TypeOf(a.hash_table_unref), "g_hash_table_unref") orelse return error.SymbolMissing;
    a.str_hash = glib.lookup(GHashFunc, "g_str_hash") orelse return error.SymbolMissing;
    a.str_equal = glib.lookup(GEqualFunc, "g_str_equal") orelse return error.SymbolMissing;
    a.error_free = glib.lookup(@TypeOf(a.error_free), "g_error_free") orelse return error.SymbolMissing;
    return a;
}

/// The loaded library, or null when this build or machine has none.
fn get() ?*const Api {
    if (comptime !supported) return null;
    api_once.call();
    if (api) |*a| return a;
    return null;
}

/// Whether libsecret could be loaded. Says nothing about a running daemon:
/// only a call can tell that, and a failed call is the fallback signal.
pub fn libraryLoaded() bool {
    return get() != null;
}

pub const Error = error{
    /// No libsecret on this machine, or not a Linux build.
    Unavailable,
    /// libsecret answered with a GError: usually "no Secret Service on the
    /// bus" (the WSL default), sometimes a locked or refused keyring.
    ServiceFailed,
    OutOfMemory,
};

/// Build the `{store: key}` attribute table. Caller unrefs.
fn attributes(a: *const Api, key_z: [*:0]const u8) Error!*anyopaque {
    const table = a.hash_table_new(a.str_hash, a.str_equal) orelse return Error.OutOfMemory;
    _ = a.hash_table_insert(table, @constCast(@ptrCast(key_attribute.ptr)), @constCast(@ptrCast(key_z)));
    return table;
}

fn consumeError(a: *const Api, err: ?*GError, what: []const u8) void {
    const e = err orelse return;
    defer a.error_free(e);
    const msg = if (e.message) |m| std.mem.span(m) else "(no message)";
    log.info("secret service: {s} failed: {s}", .{ what, msg });
}

/// Store `secret` under `key`, replacing any item already there.
pub fn store(alloc: Allocator, key: []const u8, label: []const u8, secret: []const u8) Error!void {
    const a = get() orelse return Error.Unavailable;
    const key_z = try alloc.dupeZ(u8, key);
    defer alloc.free(key_z);
    const label_z = try alloc.dupeZ(u8, label);
    defer alloc.free(label_z);
    const secret_z = try alloc.dupeZ(u8, secret);
    defer {
        std.crypto.secureZero(u8, secret_z);
        alloc.free(secret_z);
    }

    const table = try attributes(a, key_z);
    defer a.hash_table_unref(table);
    var gerr: ?*GError = null;
    // collection null = the default collection ("login" on GNOME).
    const ok = a.storev(&schema, table, null, label_z, secret_z, null, &gerr);
    if (ok == 0 or gerr != null) {
        consumeError(a, gerr, "store");
        return Error.ServiceFailed;
    }
}

/// The secret stored under `key`, owned by the caller, or null when there is
/// no such item. `Error.ServiceFailed` when no Secret Service answered.
pub fn lookup(alloc: Allocator, key: []const u8) Error!?[]u8 {
    const a = get() orelse return Error.Unavailable;
    const key_z = try alloc.dupeZ(u8, key);
    defer alloc.free(key_z);

    const table = try attributes(a, key_z);
    defer a.hash_table_unref(table);
    var gerr: ?*GError = null;
    const got = a.lookupv(&schema, table, null, &gerr);
    if (gerr != null) {
        if (got) |g| a.password_free(g);
        consumeError(a, gerr, "lookup");
        return Error.ServiceFailed;
    }
    const g = got orelse return null;
    defer a.password_free(g); // zeroes the buffer
    return try alloc.dupe(u8, std.mem.span(g));
}

/// Delete the item under `key`. A missing item is success.
pub fn clear(alloc: Allocator, key: []const u8) Error!void {
    const a = get() orelse return Error.Unavailable;
    const key_z = try alloc.dupeZ(u8, key);
    defer alloc.free(key_z);

    const table = try attributes(a, key_z);
    defer a.hash_table_unref(table);
    var gerr: ?*GError = null;
    _ = a.clearv(&schema, table, null, &gerr);
    if (gerr != null) {
        consumeError(a, gerr, "clear");
        return Error.ServiceFailed;
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "secret service: the schema keys items by one string attribute" {
    try testing.expectEqualStrings(schema_name, std.mem.span(schema.name));
    try testing.expectEqualStrings(key_attribute, std.mem.span(schema.attributes[0].name.?));
    try testing.expectEqual(@as(c_int, 0), schema.attributes[0].type);
    // The attribute list is NULL-terminated.
    try testing.expect(schema.attributes[1].name == null);
}

test "secret service: the schema struct matches secret-schema.h on LP64" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    // name(8) + flags(4, padded to 8) + 32 * {ptr 8, int 4 -> 16} + reserved
    // int(4, padded to 8) + 7 pointers.
    try testing.expectEqual(@as(usize, 8 + 8 + 32 * 16 + 8 + 7 * 8), @sizeOf(Schema));
}

test "secret service: off Linux every call says Unavailable" {
    if (comptime supported) return error.SkipZigTest;
    try testing.expectError(Error.Unavailable, lookup(testing.allocator, "k"));
    try testing.expectError(Error.Unavailable, store(testing.allocator, "k", "l", "s"));
    try testing.expectError(Error.Unavailable, clear(testing.allocator, "k"));
}
