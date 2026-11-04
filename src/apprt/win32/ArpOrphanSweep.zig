//! Remove the dead "Ghoztty" rows earlier in-app updates left in Settings >
//! Apps (T2679). Runs once per launch of the master instance, on a background
//! thread, beside the PATH self-heal (`PathInstaller.zig`).
//!
//! Which rows are dead, and why each test is there, is `arp_orphan.zig`. This
//! file only reads the keys, asks Windows Installer the one question the pure
//! module cannot (is this product registered?), and deletes what passes.
//!
//! ## Why the app and not the installer
//!
//! The rows sit on every box that took in-app updates from 1.43.4 to 1.52.10,
//! and every such box runs the app after its next update (the updater relaunches
//! it). A custom action in the package would run only during an install, inside
//! the transaction that is itself writing an Uninstall key, and would need to
//! tell "the key this install is writing" from "a key an old install left"; the
//! app runs outside any install and can simply refuse while one is running.
//!
//! ## Never during an install
//!
//! An install writes its listed key (WriteRegistryValues) before it registers
//! the product (RegisterProduct), so for a moment a correct key names an
//! unknown product. While Windows Installer's `Global\_MSIExecute` mutex
//! exists, nothing is swept; the next launch tries again.
//!
//! `GHOZTTY_ARP_SWEEP=0|off` disables it. `force` runs it from a Debug build
//! for the identity named by `GHOZTTY_ARP_SWEEP_NAME` only (test seam for
//! `test\win32\arp-sweep.ps1`); a Debug build never touches the release rows.

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const arp_orphan = @import("arp_orphan.zig");

const log = std.log.scoped(.win32_arp_sweep);

const uninstall_subkey = std.unicode.utf8ToUtf16LeStringLiteral(
    "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
);

const ERROR_NO_MORE_ITEMS: u32 = 259;
const KEY_ENUMERATE_SUB_KEYS: u32 = 0x0008;
/// `INSTALLSTATE_UNKNOWN`: Windows Installer has never heard of the product.
const INSTALLSTATE_UNKNOWN: i32 = -1;

extern "advapi32" fn RegEnumKeyExW(
    hKey: w32.HKEY,
    dwIndex: u32,
    lpName: [*]u16,
    lpcchName: *u32,
    lpReserved: ?*u32,
    lpClass: ?[*]u16,
    lpcchClass: ?*u32,
    lpftLastWriteTime: ?*anyopaque,
) callconv(.winapi) u32;
extern "advapi32" fn RegDeleteKeyW(hKey: w32.HKEY, lpSubKey: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn OpenMutexW(dwDesiredAccess: u32, bInheritHandle: i32, lpName: [*:0]const u16) callconv(.winapi) ?*anyopaque;

const MsiQueryProductStateWFn = *const fn ([*:0]const u16) callconv(.winapi) i32;

pub fn sweepAsync() void {
    const thread = std.Thread.spawn(.{}, run, .{}) catch |err| {
        log.warn("ARP sweep: thread spawn failed: {}", .{err});
        return;
    };
    thread.detach();
}

fn run() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const env = std.process.getEnvVarOwned(arena, "GHOZTTY_ARP_SWEEP") catch null;
    const m = arp_orphan.mode(env, builtin.mode == .Debug);
    const name = std.process.getEnvVarOwned(arena, "GHOZTTY_ARP_SWEEP_NAME") catch null;
    const id = arp_orphan.identityFor(m, name) orelse return;

    const removed = sweep(arena, id) catch |err| {
        log.warn("ARP sweep failed: {}", .{err});
        return;
    };
    if (removed > 0) log.info("ARP sweep: removed {d} dead '{s}' row(s) from Apps & Features", .{ removed, id.display_name });
}

/// Remove every dead row for `id`; the number removed.
fn sweep(arena: std.mem.Allocator, id: arp_orphan.Identity) !usize {
    if (installRunning()) {
        log.info("ARP sweep: an install is running, leaving the rows for the next launch", .{});
        return 0;
    }

    const msi = w32.LoadLibraryExW(
        std.unicode.utf8ToUtf16LeStringLiteral("msi.dll"),
        null,
        w32.LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) orelse return error.MsiUnavailable;
    const query: MsiQueryProductStateWFn = @ptrCast(w32.GetProcAddress(msi, "MsiQueryProductStateW") orelse
        return error.MsiUnavailable);

    var key: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(
        w32.HKEY_CURRENT_USER,
        uninstall_subkey,
        0,
        w32.KEY_READ | KEY_ENUMERATE_SUB_KEYS,
        &key,
    ) != w32.ERROR_SUCCESS) return 0; // no Uninstall key: nothing listed
    defer _ = w32.RegCloseKey(key);

    // Collect first: deleting while enumerating shifts the indices.
    var dead: std.ArrayListUnmanaged([:0]const u16) = .empty;
    var index: u32 = 0;
    while (true) : (index += 1) {
        var buf: [256]u16 = undefined;
        var len: u32 = buf.len;
        const rc = RegEnumKeyExW(key, index, &buf, &len, null, null, null, null);
        if (rc == ERROR_NO_MORE_ITEMS) break;
        if (rc != w32.ERROR_SUCCESS) continue;
        const name_w = try arena.dupeZ(u16, buf[0..len]);
        const entry = readEntry(arena, key, name_w) orelse continue;
        const product = arp_orphan.candidate(entry, id) orelse continue;
        const product_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, product);
        // Test 5: only a product Windows Installer has never heard of.
        if (query(product_w) != INSTALLSTATE_UNKNOWN) continue;
        try dead.append(arena, name_w);
    }

    var removed: usize = 0;
    for (dead.items) |name_w| {
        if (installRunning()) break; // one started while we were reading
        if (RegDeleteKeyW(key, name_w) == w32.ERROR_SUCCESS) {
            removed += 1;
        } else {
            log.warn("ARP sweep: could not remove a dead row", .{});
        }
    }
    return removed;
}

fn installRunning() bool {
    const h = OpenMutexW(w32.SYNCHRONIZE, 0, std.unicode.utf8ToUtf16LeStringLiteral("Global\\_MSIExecute")) orelse
        return false;
    _ = w32.CloseHandle(h);
    return true;
}

fn readEntry(arena: std.mem.Allocator, parent: w32.HKEY, name_w: [:0]const u16) ?arp_orphan.Entry {
    var sub: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(parent, name_w, 0, w32.KEY_QUERY_VALUE, &sub) != w32.ERROR_SUCCESS) return null;
    defer _ = w32.RegCloseKey(sub);
    return .{
        .key_name = std.unicode.utf16LeToUtf8Alloc(arena, name_w) catch return null,
        .display_name = readString(arena, sub, std.unicode.utf8ToUtf16LeStringLiteral("DisplayName")),
        .publisher = readString(arena, sub, std.unicode.utf8ToUtf16LeStringLiteral("Publisher")),
        .uninstall_string = readString(arena, sub, std.unicode.utf8ToUtf16LeStringLiteral("UninstallString")),
        .windows_installer = readDword(sub, std.unicode.utf8ToUtf16LeStringLiteral("WindowsInstaller")) == 1,
    };
}

fn readString(arena: std.mem.Allocator, key: w32.HKEY, name: [*:0]const u16) ?[]const u8 {
    var vtype: u32 = 0;
    var size: u32 = 0;
    if (w32.RegQueryValueExW(key, name, null, &vtype, null, &size) != w32.ERROR_SUCCESS) return null;
    if (vtype != w32.REG_SZ and vtype != w32.REG_EXPAND_SZ) return null;
    if (size < 2) return "";
    const buf = arena.alloc(u16, (size + 1) / 2) catch return null;
    var got: u32 = @intCast(buf.len * 2);
    if (w32.RegQueryValueExW(key, name, null, &vtype, @ptrCast(buf.ptr), &got) != w32.ERROR_SUCCESS) return null;
    var wide: []const u16 = buf[0 .. got / 2];
    while (wide.len > 0 and wide[wide.len - 1] == 0) wide = wide[0 .. wide.len - 1];
    return std.unicode.utf16LeToUtf8Alloc(arena, wide) catch null;
}

fn readDword(key: w32.HKEY, name: [*:0]const u16) ?u32 {
    var vtype: u32 = 0;
    var value: u32 = 0;
    var size: u32 = @sizeOf(u32);
    if (w32.RegQueryValueExW(key, name, null, &vtype, @ptrCast(&value), &size) != w32.ERROR_SUCCESS) return null;
    if (vtype != w32.REG_DWORD) return null;
    return value;
}
