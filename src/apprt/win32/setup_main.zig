//! `Ghoztty-Setup.exe` - the installer's front door (T2197, split from T1247).
//!
//! A double-clicked MSI belongs to Windows Installer: when another installation
//! holds the installer, the transaction is refused before any custom action of
//! ours runs, and on 2026-08-31 all the user saw was a window that said
//! "configuring" and vanished. This exe runs BEFORE Windows Installer is asked,
//! so it can speak:
//!
//!   1. it writes the package it carries (embedded at build time from
//!      `-Dsetup-msi=<path>`) to `%LOCALAPPDATA%\ghoztty\setup\`, where it stays
//!      as the install's source for a later repair;
//!   2. it runs it through `MsiInstallProductW` at the same UI level a
//!      double-click gets, with an external UI handler that answers Windows
//!      Installer's own "Error 1500. Another installation is in progress" box
//!      so it never appears (`setup_result.swallowError`);
//!   3. it maps the result (`setup_result.outcomeFor`): an install is silent -
//!      the package's own LaunchApp action opens Ghoztty - a cancel is silent,
//!      and everything else is said in Ghoztty's dark dialog
//!      (`ConfirmDialog.showStandalone`), which stays until it is read.
//!
//! The exit code is Windows Installer's, so a script can tell the outcomes
//! apart. msi.dll is resolved at run time, like the custom-action DLLs: it keeps
//! the build identical under the gnu and msvc ABIs.
//!
//! DEBUG-ONLY seams (compiled out of every release, same shape as the
//! updater's `GHOZTTY_UPDATE_MSI_CODE`):
//!   GHOZTTY_SETUP_MSI_CODE        - skip Windows Installer, use this code. A
//!                                   held `_MSIExecute` mutex does NOT collide
//!                                   (measured in T1206), so a real 1618 cannot
//!                                   be produced on demand.
//!   GHOZTTY_SETUP_MSI_PATH        - install this package instead of the one
//!                                   embedded (acceptance hands it a fake one).
//!   GHOZTTY_SETUP_REPORT_TIMEOUT_MS - dismiss the dialog after this long.

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const setup_result = @import("setup_result.zig");
const update_apply = @import("update_apply.zig");
const payload = @import("setup_payload");

// The root (`src/setup_main.zig`) declares `ghoztty_dialog_app_less`: the
// dialogs this exe shows have no `App` behind them (`dialog_app.zig`).

const log = std.log.scoped(.setup);

const W = std.os.windows;
const UINT = c_uint;
const DWORD = W.DWORD;
const MSIHANDLE = c_ulong;

const INSTALLUILEVEL_FULL: c_int = 5;
const INSTALLMESSAGE_ERROR: UINT = 0x01000000;
const INSTALLMESSAGE_TYPEMASK: UINT = 0xFF000000;
const INSTALLLOGMODE_ERROR: DWORD = 1 << 1;
/// FATALEXIT ERROR WARNING USER INFO RESOLVESOURCE OUTOFDISKSPACE ACTIONSTART
/// ACTIONDATA COMMONDATA PROPERTYDUMP VERBOSE - what `msiexec /l*v` writes.
const log_mode_verbose: DWORD = 0x1FDF;
const IDOK: c_int = 1;

const ExternalUiRecordHandler = *const fn (?*anyopaque, UINT, MSIHANDLE) callconv(.winapi) c_int;

const Msi = struct {
    setInternalUI: *const fn (c_int, ?*W.HWND) callconv(.winapi) c_int,
    setExternalUIRecord: *const fn (?ExternalUiRecordHandler, DWORD, ?*anyopaque, ?*?ExternalUiRecordHandler) callconv(.winapi) UINT,
    enableLog: *const fn (DWORD, ?[*:0]const u16, DWORD) callconv(.winapi) UINT,
    installProduct: *const fn ([*:0]const u16, ?[*:0]const u16) callconv(.winapi) UINT,
    recordGetInteger: *const fn (MSIHANDLE, UINT) callconv(.winapi) c_int,

    fn load() ?Msi {
        const mod = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("msi.dll")) orelse return null;
        return .{
            .setInternalUI = @ptrCast(GetProcAddress(mod, "MsiSetInternalUI") orelse return null),
            .setExternalUIRecord = @ptrCast(GetProcAddress(mod, "MsiSetExternalUIRecord") orelse return null),
            .enableLog = @ptrCast(GetProcAddress(mod, "MsiEnableLogW") orelse return null),
            .installProduct = @ptrCast(GetProcAddress(mod, "MsiInstallProductW") orelse return null),
            .recordGetInteger = @ptrCast(GetProcAddress(mod, "MsiRecordGetInteger") orelse return null),
        };
    }
};

extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?W.HMODULE;
extern "kernel32" fn GetProcAddress(hModule: W.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn ExitProcess(uExitCode: UINT) callconv(.winapi) noreturn;

/// The loaded msi.dll, for the UI handler (which gets no context it can use
/// for this - the context pointer carries the swallow count).
var msi_api: ?Msi = null;

/// How many collision boxes the handler answered. Logged, and asserted on by
/// the acceptance script.
var swallowed: u32 = 0;

fn uiHandler(ctx: ?*anyopaque, message_type: UINT, record: MSIHANDLE) callconv(.winapi) c_int {
    _ = ctx;
    if (message_type & INSTALLMESSAGE_TYPEMASK != INSTALLMESSAGE_ERROR) return 0;
    const api = msi_api orelse return 0;
    if (record == 0) return 0;
    const n = api.recordGetInteger(record, 1);
    if (n <= 0) return 0;
    if (!setup_result.swallowError(@intCast(n))) return 0;
    swallowed += 1;
    // IDOK: "handled". The box is OK-only, so this is the answer a person
    // would have given it; Windows Installer then fails the transaction with
    // 1618, which is what we report.
    return IDOK;
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const code = run(arena);
    log.info("exit {d}", .{code});
    ExitProcess(code);
}

fn run(arena: std.mem.Allocator) u32 {
    const dir = setupDir(arena) catch |err| {
        log.err("no setup directory: {s}", .{@errorName(err)});
        reportNotStarted("Windows would not let the installer create its working folder in your profile.");
        return update_apply.install_failure;
    };
    const pid = W.GetCurrentProcessId();
    const log_path = std.fmt.allocPrint(arena, "{s}\\install-{d}.log", .{ dir, pid }) catch return update_apply.install_failure;

    const code: u32 = if (forcedCode(arena)) |c| blk: {
        log.warn("GHOZTTY_SETUP_MSI_CODE={d}; Windows Installer not run", .{c});
        break :blk c;
    } else blk: {
        const pkg = packagePath(arena, dir, pid) catch |err| {
            log.err("no package to install: {s}", .{@errorName(err)});
            // An `if`, not a switch: in a build with no package the error set
            // is comptime-known to be NoPayload alone, and an else prong is
            // then a compile error.
            reportNotStarted(if (err == error.NoPayload)
                "This installer does not carry a Ghoztty package."
            else
                "The installer could not unpack its Ghoztty package into your profile.");
            return update_apply.install_failure;
        };
        break :blk install(arena, pkg, log_path);
    };

    log.info("windows installer answered {d} (collision boxes answered: {d})", .{ code, swallowed });
    switch (setup_result.outcomeFor(code)) {
        .installed => {
            log.info("installed", .{});
            pruneOtherPackages(dir, pid);
        },
        .cancelled => log.info("cancelled; nothing to say", .{}),
        .report => {
            var buf: [update_apply.max_failure_message]u8 = undefined;
            report(setup_result.describe(&buf, code, log_path));
        },
    }
    return code;
}

/// `%LOCALAPPDATA%\ghoztty\setup` (`setup-debug` for a Debug build, so a dev
/// run never shares a folder with the user's real installs).
fn setupDir(arena: std.mem.Allocator) ![]const u8 {
    const base = try std.process.getEnvVarOwned(arena, "LOCALAPPDATA");
    const leaf = if (builtin.mode == .Debug) "setup-debug" else "setup";
    const dir = try std.fmt.allocPrint(arena, "{s}\\ghoztty\\{s}", .{ base, leaf });
    try std.fs.cwd().makePath(dir);
    return dir;
}

/// Where the package to install is: the seam's path in a Debug build, else the
/// embedded package written out under a name no concurrent setup run shares
/// (two double-clicks must not write the same file one of them is reading).
fn packagePath(arena: std.mem.Allocator, dir: []const u8, pid: DWORD) ![]const u8 {
    if (comptime builtin.mode == .Debug) {
        if (std.process.getEnvVarOwned(arena, "GHOZTTY_SETUP_MSI_PATH")) |p| {
            log.warn("GHOZTTY_SETUP_MSI_PATH={s}; the embedded package is not used", .{p});
            return p;
        } else |_| {}
    }
    if (payload.msi.len == 0) return error.NoPayload;
    const path = try std.fmt.allocPrint(arena, "{s}\\Ghoztty-{d}.msi", .{ dir, pid });
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = payload.msi });
    return path;
}

/// After a good install only this run's package is the product's source;
/// earlier runs' copies (failed or superseded) are dead weight.
fn pruneOtherPackages(dir: []const u8, pid: DWORD) void {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return;
    defer d.close();
    var keep_buf: [32]u8 = undefined;
    const keep = std.fmt.bufPrint(&keep_buf, "Ghoztty-{d}.msi", .{pid}) catch return;
    var it = d.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.startsWith(u8, e.name, "Ghoztty-") or !std.mem.endsWith(u8, e.name, ".msi")) continue;
        if (std.mem.eql(u8, e.name, keep)) continue;
        d.deleteFile(e.name) catch {};
    }
}

fn install(arena: std.mem.Allocator, pkg: []const u8, log_path: []const u8) u32 {
    msi_api = Msi.load() orelse {
        log.err("msi.dll could not be loaded", .{});
        return update_apply.install_service_failure;
    };
    const api = msi_api.?;
    const pkg_w = std.unicode.utf8ToUtf16LeAllocZ(arena, pkg) catch return update_apply.install_failure;
    const log_w = std.unicode.utf8ToUtf16LeAllocZ(arena, log_path) catch return update_apply.install_failure;

    // The UI a double-click gets, so nothing about the install itself changes -
    // only who answers the collision box.
    _ = api.setInternalUI(INSTALLUILEVEL_FULL, null);
    _ = api.setExternalUIRecord(uiHandler, INSTALLLOGMODE_ERROR, null, null);
    const log_rc = api.enableLog(log_mode_verbose, log_w.ptr, 0);
    if (log_rc != 0) log.warn("MsiEnableLogW returned {d}; the install runs unlogged", .{log_rc});

    log.info("installing {s} (log {s})", .{ pkg, log_path });
    return api.installProduct(pkg_w.ptr, null);
}

fn reportNotStarted(what: []const u8) void {
    var buf: [update_apply.max_failure_message]u8 = undefined;
    report(setup_result.describeNotStarted(&buf, what));
}

/// Our dialog, owner-less, on the primary monitor, until it is read.
fn report(text: []const u8) void {
    log.err("{s}", .{text});
    var wbuf: [update_apply.max_failure_message * 2]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], text) catch return;
    wbuf[n] = 0;
    var seam_buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&seam_buf);
    _ = ConfirmDialog.showStandalone(null, ConfirmDialog.standaloneScale(), .{
        .title = std.unicode.utf8ToUtf16LeStringLiteral(setup_result.failure_title),
        .text = wbuf[0..n :0],
        .style = .ok_only,
        .icon = .warning,
        .timeout_ms = forcedTimeout(fba.allocator()),
    });
}

fn forcedCode(arena: std.mem.Allocator) ?u32 {
    if (comptime builtin.mode != .Debug) return null;
    const raw = std.process.getEnvVarOwned(arena, "GHOZTTY_SETUP_MSI_CODE") catch return null;
    return std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null;
}

fn forcedTimeout(arena: std.mem.Allocator) ?u32 {
    if (comptime builtin.mode != .Debug) return null;
    const raw = std.process.getEnvVarOwned(arena, "GHOZTTY_SETUP_REPORT_TIMEOUT_MS") catch return null;
    return std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null;
}
