//! The OS half of the T3393 guard: ask Windows Installer where the product a
//! staged package would act on is installed. The decision is
//! `update_target.zig`; this file only reads.
//!
//! Two reads, both read-only:
//!
//!  1. The PACKAGE: its `UpgradeCode` (Property table) and the ComponentId of
//!     the component whose key file is the running exe's name in INSTALLDIR.
//!     Read from the package rather than compiled in, so a throwaway test
//!     identity (`scripts\msi-test-identity.ps1`, which moves both) is judged
//!     by its own product, exactly like the release.
//!  2. The REGISTRATION: every product carrying that UpgradeCode
//!     (`MsiEnumRelatedProductsW`), and where each one's exe component is
//!     (`MsiGetComponentPathW`) - the path msiexec itself resolves.
//!
//! msi.dll is loaded at run time from System32, as `ArpOrphanSweep.zig` does,
//! rather than linked: the app never needed it before this, and a load
//! failure is a refusal with a reason rather than a missing-import crash.
const std = @import("std");
const w32 = @import("win32.zig");
const update_target = @import("update_target.zig");

const log = std.log.scoped(.win32_update_target);

const MSIHANDLE = u32;
const ERROR_SUCCESS: u32 = 0;
const ERROR_NO_MORE_ITEMS: u32 = 259;
const ERROR_MORE_DATA: u32 = 234;
/// `MSIDBOPEN_READONLY`, which the API spells as a pointer-typed 0.
const MSIDBOPEN_READONLY: ?[*:0]const u16 = null;
const INSTALLSTATE_INVALIDARG: i32 = -2;
const INSTALLSTATE_UNKNOWN: i32 = -1;

const Api = struct {
    open_database: *const fn ([*:0]const u16, ?[*:0]const u16, *MSIHANDLE) callconv(.winapi) u32,
    open_view: *const fn (MSIHANDLE, [*:0]const u16, *MSIHANDLE) callconv(.winapi) u32,
    view_execute: *const fn (MSIHANDLE, MSIHANDLE) callconv(.winapi) u32,
    view_fetch: *const fn (MSIHANDLE, *MSIHANDLE) callconv(.winapi) u32,
    record_get_string: *const fn (MSIHANDLE, u32, ?[*]u16, *u32) callconv(.winapi) u32,
    close_handle: *const fn (MSIHANDLE) callconv(.winapi) u32,
    enum_related: *const fn ([*:0]const u16, u32, u32, [*]u16) callconv(.winapi) u32,
    component_path: *const fn ([*:0]const u16, [*:0]const u16, ?[*]u16, *u32) callconv(.winapi) i32,

    fn load() ?Api {
        const msi = w32.LoadLibraryExW(
            std.unicode.utf8ToUtf16LeStringLiteral("msi.dll"),
            null,
            w32.LOAD_LIBRARY_SEARCH_SYSTEM32,
        ) orelse return null;
        return .{
            .open_database = @ptrCast(w32.GetProcAddress(msi, "MsiOpenDatabaseW") orelse return null),
            .open_view = @ptrCast(w32.GetProcAddress(msi, "MsiDatabaseOpenViewW") orelse return null),
            .view_execute = @ptrCast(w32.GetProcAddress(msi, "MsiViewExecute") orelse return null),
            .view_fetch = @ptrCast(w32.GetProcAddress(msi, "MsiViewFetch") orelse return null),
            .record_get_string = @ptrCast(w32.GetProcAddress(msi, "MsiRecordGetStringW") orelse return null),
            .close_handle = @ptrCast(w32.GetProcAddress(msi, "MsiCloseHandle") orelse return null),
            .enum_related = @ptrCast(w32.GetProcAddress(msi, "MsiEnumRelatedProductsW") orelse return null),
            .component_path = @ptrCast(w32.GetProcAddress(msi, "MsiGetComponentPathW") orelse return null),
        };
    }
};

/// The verdict for applying `msi_path` from the exe at `exe_path`.
/// Never errors: every failure is a refusing verdict.
pub fn check(arena: std.mem.Allocator, msi_path: []const u8, exe_path: []const u8) update_target.Verdict {
    const exe_dir = std.fs.path.dirnameWindows(exe_path) orelse return .lookup_failed;
    const exe_name = std.fs.path.basenameWindows(exe_path);
    const api = Api.load() orelse {
        log.warn("update target: msi.dll could not be loaded", .{});
        return .lookup_failed;
    };

    const ident = readPackage(arena, api, msi_path, exe_name) orelse return .package_unreadable;
    log.info("update target: package UpgradeCode {s}, {s} component {s}", .{ ident.upgrade_code, exe_name, ident.component_id });

    const code_w = std.unicode.utf8ToUtf16LeAllocZ(arena, ident.upgrade_code) catch return .lookup_failed;
    const comp_w = std.unicode.utf8ToUtf16LeAllocZ(arena, ident.component_id) catch return .lookup_failed;

    var registered: std.ArrayListUnmanaged(?[]const u8) = .empty;
    var index: u32 = 0;
    while (index < 64) : (index += 1) {
        var product_w: [39]u16 = undefined;
        const rc = api.enum_related(code_w, 0, index, &product_w);
        if (rc == ERROR_NO_MORE_ITEMS) break;
        if (rc != ERROR_SUCCESS) {
            log.warn("update target: MsiEnumRelatedProducts failed rc={d}", .{rc});
            return .lookup_failed;
        }
        product_w[38] = 0;
        const path = componentPath(arena, api, product_w[0..38 :0], comp_w);
        log.info("update target: related product {f} has {s} at {s}", .{
            std.unicode.fmtUtf16Le(product_w[0..38]), exe_name, path orelse "(unresolved)",
        });
        registered.append(arena, path) catch return .lookup_failed;
    }
    return update_target.decide(exe_dir, registered.items);
}

const PackageIdentity = struct { upgrade_code: []const u8, component_id: []const u8 };

fn readPackage(arena: std.mem.Allocator, api: Api, msi_path: []const u8, exe_name: []const u8) ?PackageIdentity {
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(arena, msi_path) catch return null;
    var db: MSIHANDLE = 0;
    const rc = api.open_database(path_w, MSIDBOPEN_READONLY, &db);
    if (rc != ERROR_SUCCESS) {
        log.warn("update target: {s} is not an installer database (MsiOpenDatabase rc={d})", .{ msi_path, rc });
        return null;
    }
    defer _ = api.close_handle(db);

    const upgrade_code = blk: {
        var rows = Rows.open(arena, api, db, "SELECT `Value` FROM `Property` WHERE `Property`='UpgradeCode'") orelse return null;
        defer rows.close();
        const row = rows.next() orelse break :blk null;
        break :blk rows.field(row, 1);
    } orelse {
        log.warn("update target: the package has no UpgradeCode", .{});
        return null;
    };

    // The component whose key file is the exe, among the files in INSTALLDIR.
    const component = blk: {
        var rows = Rows.open(arena, api, db, "SELECT `Component_`, `FileName` FROM `File`") orelse return null;
        defer rows.close();
        while (rows.next()) |row| {
            const name = rows.field(row, 2) orelse continue;
            if (!update_target.msiFileNameIs(name, exe_name)) continue;
            const comp = rows.field(row, 1) orelse continue;
            if (keyedInInstallDir(arena, api, db, comp)) |id| break :blk id;
        }
        break :blk null;
    } orelse {
        log.warn("update target: the package installs no {s} into INSTALLDIR", .{exe_name});
        return null;
    };
    return .{ .upgrade_code = upgrade_code, .component_id = component };
}

/// The ComponentId of `component` when it lives in INSTALLDIR.
fn keyedInInstallDir(arena: std.mem.Allocator, api: Api, db: MSIHANDLE, component: []const u8) ?[]const u8 {
    var rows = Rows.open(arena, api, db, "SELECT `Component`, `ComponentId`, `Directory_` FROM `Component`") orelse return null;
    defer rows.close();
    while (rows.next()) |row| {
        const key = rows.field(row, 1) orelse continue;
        if (!std.mem.eql(u8, key, component)) continue;
        const dir = rows.field(row, 3) orelse return null;
        if (!std.mem.eql(u8, dir, "INSTALLDIR")) return null;
        return rows.field(row, 2);
    }
    return null;
}

/// A view over one query; each fetched record is closed by the next `next`.
const Rows = struct {
    arena: std.mem.Allocator,
    api: Api,
    view: MSIHANDLE,
    record: MSIHANDLE = 0,

    fn open(arena: std.mem.Allocator, api: Api, db: MSIHANDLE, comptime query: []const u8) ?Rows {
        var view: MSIHANDLE = 0;
        if (api.open_view(db, std.unicode.utf8ToUtf16LeStringLiteral(query), &view) != ERROR_SUCCESS) return null;
        if (api.view_execute(view, 0) != ERROR_SUCCESS) {
            _ = api.close_handle(view);
            return null;
        }
        return .{ .arena = arena, .api = api, .view = view };
    }

    fn next(self: *Rows) ?MSIHANDLE {
        if (self.record != 0) _ = self.api.close_handle(self.record);
        self.record = 0;
        var rec: MSIHANDLE = 0;
        if (self.api.view_fetch(self.view, &rec) != ERROR_SUCCESS) return null;
        self.record = rec;
        return rec;
    }

    fn field(self: *Rows, rec: MSIHANDLE, index: u32) ?[]const u8 {
        var len: u32 = 0;
        var empty: [1]u16 = undefined;
        const first = self.api.record_get_string(rec, index, &empty, &len);
        if (first != ERROR_SUCCESS and first != ERROR_MORE_DATA) return null;
        const buf = self.arena.alloc(u16, len + 1) catch return null;
        var got: u32 = len + 1;
        if (self.api.record_get_string(rec, index, buf.ptr, &got) != ERROR_SUCCESS) return null;
        return std.unicode.utf16LeToUtf8Alloc(self.arena, buf[0..got]) catch null;
    }

    fn close(self: *Rows) void {
        if (self.record != 0) _ = self.api.close_handle(self.record);
        _ = self.api.close_handle(self.view);
    }
};

/// Where `product` has the exe component, or null when Windows Installer
/// cannot say (the product is registered without it, or the query failed).
fn componentPath(arena: std.mem.Allocator, api: Api, product: [:0]const u16, component: [:0]const u16) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u16 = undefined;
    var len: u32 = buf.len;
    const state = api.component_path(product.ptr, component.ptr, &buf, &len);
    if (state == INSTALLSTATE_UNKNOWN or state == INSTALLSTATE_INVALIDARG) return null;
    if (len == 0 or len >= buf.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(arena, buf[0..len]) catch null;
}
