//! `ghoztty-msi-ca.dll`: the Ghoztty installer's in-process custom actions
//! (T1730). Packaged into the MSI's Binary table by
//! `dist/windows-installer/build-msi.sh`, never installed as a file.
//!
//! One export today, `MaintenancePromptCA`, which asks "Repair or Cancel?" when
//! the package is run for the version already installed. It runs the installed
//! `ghoztty.exe --install-maintenance` (the dialog lives in the app, so it is
//! the same dark Ghoztty prompt as every other one), waits for it, and turns
//! the exe's answer into an ACTION STATUS - the only channel through which
//! Windows Installer accepts "the user cancelled" quietly. Why an EXE action
//! could not do this is spelled out in `maintenance_ca.zig`.
//!
//! msi.dll is resolved at run time rather than linked: this DLL is only ever
//! loaded by msiexec's custom-action server, which has msi.dll mapped already,
//! and not linking it keeps the build identical under the gnu and msvc ABIs.
//! Same rules as the agent's `msi_ca.zig`: pure Win32, no shared deps, tiny.

const std = @import("std");
const logic = @import("maintenance_ca.zig");

const W = std.os.windows;
const UINT = c_uint;
const DWORD = W.DWORD;
const BOOL = W.BOOL;
const HANDLE = W.HANDLE;
const MSIHANDLE = c_ulong;

const INFINITE: DWORD = 0xFFFFFFFF;
const WAIT_OBJECT_0: DWORD = 0;
const ERROR_MORE_DATA: UINT = 234;
const INSTALLMESSAGE_INFO: c_int = 0x04000000;

extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?W.HMODULE;
extern "kernel32" fn GetProcAddress(hModule: W.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *W.STARTUPINFOW,
    lpProcessInformation: *W.PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

const MsiGetPropertyWFn = *const fn (MSIHANDLE, [*:0]const u16, [*]u16, *DWORD) callconv(.winapi) UINT;
const MsiCreateRecordFn = *const fn (UINT) callconv(.winapi) MSIHANDLE;
const MsiRecordSetStringWFn = *const fn (MSIHANDLE, UINT, [*:0]const u16) callconv(.winapi) UINT;
const MsiProcessMessageFn = *const fn (MSIHANDLE, c_int, MSIHANDLE) callconv(.winapi) c_int;
const MsiCloseHandleFn = *const fn (MSIHANDLE) callconv(.winapi) UINT;

const Msi = struct {
    getProperty: MsiGetPropertyWFn,
    createRecord: ?MsiCreateRecordFn,
    recordSetString: ?MsiRecordSetStringWFn,
    processMessage: ?MsiProcessMessageFn,
    closeHandle: ?MsiCloseHandleFn,

    fn load() ?Msi {
        const mod = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("msi.dll")) orelse return null;
        const gp = GetProcAddress(mod, "MsiGetPropertyW") orelse return null;
        return .{
            .getProperty = @ptrCast(gp),
            .createRecord = @ptrCast(GetProcAddress(mod, "MsiCreateRecord")),
            .recordSetString = @ptrCast(GetProcAddress(mod, "MsiRecordSetStringW")),
            .processMessage = @ptrCast(GetProcAddress(mod, "MsiProcessMessage")),
            .closeHandle = @ptrCast(GetProcAddress(mod, "MsiCloseHandle")),
        };
    }

    /// Read a property into `buf`, or null (unset, too long, or an error).
    fn property(self: Msi, h: MSIHANDLE, comptime name: []const u8, buf: []u16) ?[]const u16 {
        var n: DWORD = @intCast(buf.len);
        const rc = self.getProperty(h, std.unicode.utf8ToUtf16LeStringLiteral(name), buf.ptr, &n);
        if (rc != 0 or n >= buf.len) return null;
        return buf[0..n];
    }

    /// One line into msiexec's verbose log, best-effort: the harness reads it,
    /// and the next person debugging an installer reads it before the code.
    fn logLine(self: Msi, h: MSIHANDLE, text: [:0]const u16) void {
        const create = self.createRecord orelse return;
        const set = self.recordSetString orelse return;
        const process = self.processMessage orelse return;
        const rec = create(1);
        if (rec == 0) return;
        _ = set(rec, 0, text.ptr);
        _ = process(h, INSTALLMESSAGE_INFO, rec);
        if (self.closeHandle) |close| _ = close(rec);
    }
};

/// Run the command line and wait for it. Null when it could not be started or
/// its exit code could not be read.
fn runAndWait(cmd: [:0]u16) ?u32 {
    var si: W.STARTUPINFOW = std.mem.zeroes(W.STARTUPINFOW);
    si.cb = @sizeOf(W.STARTUPINFOW);
    var pi: W.PROCESS_INFORMATION = undefined;
    if (CreateProcessW(null, cmd.ptr, null, null, 0, 0, null, null, &si, &pi) == 0) return null;
    defer _ = CloseHandle(pi.hProcess);
    _ = CloseHandle(pi.hThread);
    // No timeout: this IS the question, and a person may take as long as they
    // like to answer it. The EXE action it replaces waited the same way.
    if (WaitForSingleObject(pi.hProcess, INFINITE) != WAIT_OBJECT_0) return null;
    var code: DWORD = 0;
    if (GetExitCodeProcess(pi.hProcess, &code) == 0) return null;
    return code;
}

/// Repair / Cancel for a package run over its own installed version.
export fn MaintenancePromptCA(hInstall: MSIHANDLE) callconv(.winapi) UINT {
    const msi = Msi.load() orelse return logic.status(null);

    var dir_buf: [W.PATH_MAX_WIDE]u16 = undefined;
    var ver_buf: [64]u16 = undefined;
    const dir = msi.property(hInstall, "INSTALLDIR", &dir_buf) orelse {
        msi.logLine(hInstall, std.unicode.utf8ToUtf16LeStringLiteral(
            "MaintenancePromptCA: INSTALLDIR unreadable; proceeding with the repair",
        ));
        return logic.status(null);
    };
    const ver = msi.property(hInstall, "ARPDISPLAYVERSION", &ver_buf) orelse &[_]u16{};

    var cmd_buf: [W.PATH_MAX_WIDE + 128]u16 = undefined;
    const cmd = logic.commandLine(&cmd_buf, dir, ver) orelse {
        msi.logLine(hInstall, std.unicode.utf8ToUtf16LeStringLiteral(
            "MaintenancePromptCA: command line did not fit; proceeding with the repair",
        ));
        return logic.status(null);
    };

    const exit = runAndWait(cmd);
    const result = logic.status(exit);
    msi.logLine(hInstall, if (exit == null)
        std.unicode.utf8ToUtf16LeStringLiteral("MaintenancePromptCA: ghoztty.exe did not run; proceeding with the repair")
    else if (result == logic.status_user_exit)
        std.unicode.utf8ToUtf16LeStringLiteral("MaintenancePromptCA: answer=cancel; ending as a user exit")
    else
        std.unicode.utf8ToUtf16LeStringLiteral("MaintenancePromptCA: answer=repair; proceeding"));
    return result;
}
