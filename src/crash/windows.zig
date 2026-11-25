//! Windows crash capture (T1355): the Windows-native counterpart of the
//! Sentry native handler the macOS build runs.
//!
//! Sentry's native SDK does not build for this target, so until this module
//! a Ghoztty that died on Windows left nothing a user could send: the window
//! was gone and no file anywhere said why. The concept travels even though
//! the mechanism cannot. An unhandled-exception filter writes two files into
//! the same crash directory the Mac build uses (`crash.defaultDir`, which
//! `ghoztty +crash-report` already lists):
//!
//!   <stamp>-<pid>.txt  the exception code, faulting address and module,
//!                      thread, build - readable without any tooling
//!   <stamp>-<pid>.dmp  a minidump (`MiniDumpWriteDump`, dbghelp.dll) that a
//!                      debugger opens with every thread's stack
//!
//! Rules the crash path keeps:
//!
//! - Nothing allocates after `init`. The directory path is resolved once,
//!   into a static UTF-16 buffer, and the crash path only appends a
//!   timestamp and a pid to it.
//! - dbghelp.dll is loaded at crash time, not at startup: loading it costs
//!   about 1.3 ms, and `init` runs in every process including each CLI verb.
//!   Loading a library takes the loader lock, so a crash on a thread that
//!   already holds it (a fault inside DllMain) skips the dump and the module
//!   lookup and still writes the text report.
//! - The work runs on a fresh helper thread, so a stack overflow - which
//!   leaves the faulting thread a few pages of stack - still gets a report.
//!   The crashing thread waits for it, bounded, so a wedged dbghelp cannot
//!   keep a dead process alive forever.
//! - The filter returns `EXCEPTION_CONTINUE_SEARCH`: this makes a death
//!   legible, it does not make it survivable. Windows error reporting, any
//!   debugger and any LocalDumps rule see exactly what they saw before, and
//!   the process still exits with the exception code.
//!
//! Panics (T2244). A Zig panic raises no exception of its own: the default
//! handler prints and calls `abort`, which in a shipping build is
//! `ExitProcess(3)` - no filter runs and the report folder stays empty. So
//! the root's panic handler (`src/main.zig`) calls `panic` below, which
//! prints the message and stack the way the default does and then raises
//! `windows_report.code_panic` carrying the message. That reaches this filter
//! and the exit ledger's exactly like a fault, so a panic on the GUI,
//! renderer or IO thread gets a report naming the message and the thread.
//!
//! What it does not catch: in Debug and ReleaseSafe builds Zig's own
//! vectored handler turns an access violation into a panic before any
//! unhandled-exception filter runs - which, since T2244, is reported as a
//! panic. Shipping builds are ReleaseFast and have no such handler, so every
//! fault reaches this filter as itself. `test\win32\crash-report.ps1`
//! crashes the app on purpose through the stock `crash:main`, `crash:render`
//! and `crash:io` binding actions.

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const dir = @import("dir.zig");
const report = @import("windows_report.zig");
const sentry = @import("sentry.zig");

const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.crash);

const HANDLE = windows.HANDLE;
const HMODULE = windows.HMODULE;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const EXCEPTION_POINTERS = windows.EXCEPTION_POINTERS;

pub const TOP_LEVEL_EXCEPTION_FILTER = *const fn (
    ?*EXCEPTION_POINTERS,
) callconv(.winapi) i32;

const EXCEPTION_CONTINUE_SEARCH: i32 = 0;
const EXCEPTION_NONCONTINUABLE: DWORD = 0x1;

/// How long the crashing thread waits for the report thread. A minidump of a
/// large process writes in well under a second; this is the bound on a
/// dbghelp that never returns, not an expected duration.
const report_timeout_ms: DWORD = 30_000;

/// The report thread's stack. MiniDumpWriteDump walks every thread's stack
/// and needs room of its own; the default would do, but naming it keeps the
/// helper independent of the linker's default reserve.
const report_stack_bytes: usize = 512 * 1024;

/// `<crash dir>\` as UTF-16, NUL-free; `crash_dir_len` code units are valid.
var crash_dir_w: [512]u16 = undefined;
var crash_dir_len: usize = 0;
/// Length of the parent (`...\ghostty`) within `crash_dir_w`, so the crash
/// path can create both levels with CreateDirectoryW and no allocation.
var parent_len: usize = 0;

var installed: bool = false;
var prev_filter: ?TOP_LEVEL_EXCEPTION_FILTER = null;

/// Set by the first crashing thread; a second thread faulting while the
/// first is still reporting goes straight on to the previous filter.
var reporting = std.atomic.Value(bool).init(false);

/// Handed to the report thread. Only written by the thread that won
/// `reporting`, before it starts the helper.
var crash_info: ?*EXCEPTION_POINTERS = null;
var crash_thread: DWORD = 0;
/// The crashing thread's kind (`crash.sentry.thread_state`, a threadlocal,
/// so read on the crashing thread before the helper starts).
var crash_thread_kind: ?[]const u8 = null;

/// The thread `init` ran on - the GUI thread in the app - so a crash there
/// is named `main` even when no surface callback set `thread_state`.
var main_thread: DWORD = 0;

/// Per-thread panic depth: a panic raised while this thread is already
/// inside `panic` (a fault in the stack dump, say) goes straight to the
/// default handler instead of round again.
threadlocal var panic_depth: u8 = 0;

/// Resolve the crash directory and install the filter. Cheap enough for
/// every process: one environment read, one path join and one syscall.
pub fn init(gpa: Allocator) !void {
    if (installed) return;

    const d = try dir.defaultDir(gpa);
    defer gpa.free(d.path);

    // Room for `\` + a 32-unit file name + NUL must remain after the dir.
    const n = std.unicode.calcUtf16LeLen(d.path) catch return error.InvalidCrashDir;
    if (n + 40 > crash_dir_w.len) return error.CrashDirTooLong;
    crash_dir_len = std.unicode.utf8ToUtf16Le(&crash_dir_w, d.path) catch
        return error.InvalidCrashDir;
    if (std.fs.path.dirname(d.path)) |parent| {
        parent_len = std.unicode.calcUtf16LeLen(parent) catch 0;
    }

    main_thread = GetCurrentThreadId();
    prev_filter = SetUnhandledExceptionFilter(onUnhandled);
    installed = true;
    log.debug("crash reports go to {s}", .{d.path});
}

/// Deliberately leaves the filter installed. By the time global state is torn
/// down the app's exit ledger (`apprt/win32/exit_reason.zig`) has installed
/// its own filter on top of this one, so restoring ours would unhook that one
/// too, and a crash during teardown is still a crash worth a report.
pub fn deinit() void {}

/// The panic handler's Windows half (T2244); see the module header. Prints
/// what `std.debug.defaultPanic` prints, then raises `code_panic` so the
/// unhandled-exception filters write the report and the ledger line. Falls
/// back to the default handler when there is no filter to reach (`init`
/// never ran, as in a CLI verb that skipped it) or on a nested panic.
pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (!installed or panic_depth != 0) std.debug.defaultPanic(msg, first_trace_addr);
    panic_depth = 1;

    {
        const stderr = std.debug.lockStderrWriter(&.{});
        defer std.debug.unlockStderrWriter();
        stderr.print("thread {d} panic: {s}\n", .{ GetCurrentThreadId(), msg }) catch {};
    }
    std.debug.dumpCurrentStackTrace(first_trace_addr orelse @returnAddress());

    const params = [report.panic_param_count]usize{
        @intFromPtr(msg.ptr),
        msg.len,
        first_trace_addr orelse @returnAddress(),
    };
    RaiseException(report.code_panic, EXCEPTION_NONCONTINUABLE, params.len, &params);

    // Unreachable unless something swallowed the exception; still die.
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn threadKind() ?[]const u8 {
    if (sentry.thread_state) |ts| return @tagName(ts.type);
    if (GetCurrentThreadId() == main_thread) return "main";
    return null;
}

fn onUnhandled(info: ?*EXCEPTION_POINTERS) callconv(.winapi) i32 {
    if (reporting.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        crash_info = info;
        crash_thread = GetCurrentThreadId();
        crash_thread_kind = threadKind();

        if (holdsLoaderLock()) {
            // A new thread's DLL_THREAD_ATTACH would wait on the lock this
            // thread holds, so write the text report right here instead.
            writeReport(false);
        } else if (CreateThread(null, report_stack_bytes, reportThread, null, 0, null)) |h| {
            _ = WaitForSingleObject(h, report_timeout_ms);
            _ = CloseHandle(h);
        } else {
            writeReport(true);
        }
    }

    if (prev_filter) |f| return f(info);
    return EXCEPTION_CONTINUE_SEARCH;
}

fn reportThread(_: windows.LPVOID) callconv(.winapi) DWORD {
    writeReport(true);
    return 0;
}

/// Does the current thread own the process loader lock? Read straight from
/// the PEB: the lock's `OwningThread` holds the owner's thread id.
fn holdsLoaderLock() bool {
    const owner = @intFromPtr(windows.peb().LoaderLock.OwningThread);
    return owner == GetCurrentThreadId();
}

fn writeReport(loader_ok: bool) void {
    if (crash_dir_len == 0) return;

    var st: SYSTEMTIME = undefined;
    GetSystemTime(&st);
    var time_buf: [32]u8 = undefined;
    const time = std.fmt.bufPrint(
        &time_buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{ st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds },
    ) catch "";

    const pid = windows.GetCurrentProcessId();
    var base_buf: [40]u8 = undefined;
    const base = report.baseName(&base_buf, st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, pid);
    if (base.len == 0) return;

    ensureDir();

    var fields: report.Fields = .{
        .build = build_config.version_string,
        .mode = @tagName(builtin.mode),
        .time = time,
        .pid = pid,
        .thread = crash_thread,
        .thread_kind = crash_thread_kind,
        .code = 0,
        .address = 0,
        .dump = .{ .skipped = "no exception record" },
    };

    const info = crash_info;
    if (info) |p| {
        const rec: *const windows.EXCEPTION_RECORD = p.ExceptionRecord;
        fields.code = rec.ExceptionCode;
        const params = rec.ExceptionInformation[0..@min(rec.NumberParameters, rec.ExceptionInformation.len)];
        fields.address = report.crashAddress(rec.ExceptionCode, params, @intFromPtr(rec.ExceptionAddress));
        if (rec.ExceptionCode == report.code_access_violation and rec.NumberParameters >= 2) {
            fields.access = report.Access.fromInformation(
                rec.ExceptionInformation[0],
                rec.ExceptionInformation[1],
            );
        }
        if (rec.ExceptionCode == report.code_panic and rec.NumberParameters >= report.panic_param_count) {
            // `panic` put these here from a live slice on the crashing
            // thread's stack, which is parked in RaiseException until the
            // filter returns.
            const ptr = rec.ExceptionInformation[report.panic_param_msg_ptr];
            const len = rec.ExceptionInformation[report.panic_param_msg_len];
            if (ptr != 0) fields.message = @as([*]const u8, @ptrFromInt(ptr))[0..len];
        }
    }

    var module_buf: [1024]u8 = undefined;
    if (loader_ok and fields.address != 0) {
        if (moduleOf(fields.address, &module_buf)) |m| {
            fields.module = m.path;
            fields.module_base = m.base;
        }
    }

    var dump_name_buf: [48]u8 = undefined;
    if (!loader_ok) {
        fields.dump = .{ .skipped = "loader lock held by the crashing thread" };
    } else if (info) |p| {
        if (std.fmt.bufPrint(&dump_name_buf, "{s}.dmp", .{base})) |dump_name| {
            fields.dump = if (writeDump(dump_name, p)) |why|
                .{ .skipped = why }
            else
                .{ .written = dump_name };
        } else |_| {}
    }

    var text_buf: [4096]u8 = undefined;
    const text = report.format(&text_buf, fields);
    var name_buf: [48]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}.txt", .{base}) catch return;
    writeFile(name, text);
}

/// Create `...\ghostty` and `...\ghostty\crash`; both may already exist.
fn ensureDir() void {
    var path: [crash_dir_w.len]u16 = undefined;
    if (parent_len > 0 and parent_len < crash_dir_len) {
        @memcpy(path[0..parent_len], crash_dir_w[0..parent_len]);
        path[parent_len] = 0;
        _ = CreateDirectoryW(@ptrCast(&path), null);
    }
    @memcpy(path[0..crash_dir_len], crash_dir_w[0..crash_dir_len]);
    path[crash_dir_len] = 0;
    _ = CreateDirectoryW(@ptrCast(&path), null);
}

/// `<crash dir>\<name>` as a NUL-terminated UTF-16 path in `out`.
fn filePath(out: *[crash_dir_w.len]u16, name: []const u8) ?[*:0]const u16 {
    if (crash_dir_len + 1 + name.len + 1 > out.len) return null;
    @memcpy(out[0..crash_dir_len], crash_dir_w[0..crash_dir_len]);
    var i = crash_dir_len;
    out[i] = '\\';
    i += 1;
    // File names here are ASCII by construction (baseName + an extension).
    for (name) |c| {
        out[i] = c;
        i += 1;
    }
    out[i] = 0;
    return @ptrCast(out);
}

fn createFile(name: []const u8) ?HANDLE {
    var path: [crash_dir_w.len]u16 = undefined;
    const p = filePath(&path, name) orelse return null;
    const h = CreateFileW(
        p,
        windows.GENERIC_WRITE,
        windows.FILE_SHARE_READ,
        null,
        windows.CREATE_ALWAYS,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == windows.INVALID_HANDLE_VALUE) return null;
    return h;
}

fn writeFile(name: []const u8, bytes: []const u8) void {
    const h = createFile(name) orelse return;
    defer _ = CloseHandle(h);
    var wrote: DWORD = 0;
    _ = WriteFile(h, bytes.ptr, @intCast(bytes.len), &wrote, null);
}

/// Write the minidump. Returns null on success, or why there is none.
fn writeDump(name: []const u8, info: *EXCEPTION_POINTERS) ?[]const u8 {
    const lib = LoadLibraryExW(
        std.unicode.utf8ToUtf16LeStringLiteral("dbghelp.dll"),
        null,
        LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) orelse return "dbghelp.dll did not load";
    const proc = GetProcAddress(lib, "MiniDumpWriteDump") orelse
        return "dbghelp.dll has no MiniDumpWriteDump";
    const write_dump: MiniDumpWriteDumpFn = @ptrCast(proc);

    const h = createFile(name) orelse return "could not create the dump file";
    defer _ = CloseHandle(h);

    var exc: MINIDUMP_EXCEPTION_INFORMATION = .{
        .ThreadId = crash_thread,
        .ExceptionPointers = info,
        .ClientPointers = 0,
    };
    const ok = write_dump(
        GetCurrentProcess(),
        windows.GetCurrentProcessId(),
        h,
        dump_type,
        &exc,
        null,
        null,
    );
    if (ok == 0) return "MiniDumpWriteDump failed";
    return null;
}

const Module = struct { path: []const u8, base: usize };

fn moduleOf(address: usize, buf: []u8) ?Module {
    var hmod: ?HMODULE = null;
    if (GetModuleHandleExW(
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrFromInt(address),
        &hmod,
    ) == 0) return null;
    const m = hmod orelse return null;

    var wide: [512]u16 = undefined;
    const n = GetModuleFileNameW(m, &wide, wide.len);
    if (n == 0 or n >= wide.len) return null;
    const len = std.unicode.utf16LeToUtf8(buf, wide[0..n]) catch return null;
    return .{ .path = buf[0..len], .base = @intFromPtr(m) };
}

// Thread info and unloaded modules make the dump answer "which thread, and
// what had just been unloaded"; indirectly referenced memory gives each
// stack's pointers their targets. Full memory is deliberately not taken: a
// terminal with a large scrollback would write a dump the size of its heap.
const dump_type: DWORD = 0x00000020 | // MiniDumpWithUnloadedModules
    0x00000040 | // MiniDumpWithIndirectlyReferencedMemory
    0x00001000; // MiniDumpWithThreadInfo

// ---------------------------------------------------------------------
// Win32 declarations std does not carry (or carries with an asserting
// wrapper that has no place on a crash path).
// ---------------------------------------------------------------------

const LOAD_LIBRARY_SEARCH_SYSTEM32: DWORD = 0x00000800;
const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: DWORD = 0x00000002;
const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: DWORD = 0x00000004;

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

/// dbghelp.h declares the MINIDUMP structures under `#pragma pack(4)`, so
/// on x64 the pointer sits at offset 4 and the struct is 16 bytes.
const MINIDUMP_EXCEPTION_INFORMATION = extern struct {
    ThreadId: DWORD,
    ExceptionPointers: *EXCEPTION_POINTERS align(4),
    ClientPointers: BOOL,
};

comptime {
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(MINIDUMP_EXCEPTION_INFORMATION) == 16);
}

const MiniDumpWriteDumpFn = *const fn (
    hProcess: HANDLE,
    ProcessId: DWORD,
    hFile: HANDLE,
    DumpType: DWORD,
    ExceptionParam: ?*MINIDUMP_EXCEPTION_INFORMATION,
    UserStreamParam: ?*anyopaque,
    CallbackParam: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn SetUnhandledExceptionFilter(
    lpTopLevelExceptionFilter: ?TOP_LEVEL_EXCEPTION_FILTER,
) callconv(.winapi) ?TOP_LEVEL_EXCEPTION_FILTER;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn RaiseException(
    dwExceptionCode: DWORD,
    dwExceptionFlags: DWORD,
    nNumberOfArguments: DWORD,
    lpArguments: [*]const usize,
) callconv(.winapi) void;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn GetSystemTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
extern "kernel32" fn CreateDirectoryW(
    lpPathName: [*:0]const u16,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreateThread(
    lpThreadAttributes: ?*anyopaque,
    dwStackSize: usize,
    lpStartAddress: *const fn (windows.LPVOID) callconv(.winapi) DWORD,
    lpParameter: ?windows.LPVOID,
    dwCreationFlags: DWORD,
    lpThreadId: ?*DWORD,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn LoadLibraryExW(
    lpLibFileName: [*:0]const u16,
    hFile: ?HANDLE,
    dwFlags: DWORD,
) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleHandleExW(
    dwFlags: DWORD,
    lpModuleName: ?*const anyopaque,
    phModule: *?HMODULE,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleFileNameW(
    hModule: ?HMODULE,
    lpFilename: [*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;
