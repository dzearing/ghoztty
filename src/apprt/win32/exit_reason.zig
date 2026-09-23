//! The durable exit ledger (T1686) - why the terminal is not there any more.
//!
//! On 2026-09-20 every Ghoztty window on the box disappeared at once. The
//! sessions survived (the agents hold those), but the app was simply gone:
//! no dialog, no Application Error record in the Windows event log, and
//! nothing in `ghoztty.log` after the last routine line. The cause was found
//! only because the renderer happened to log three OpenGL warnings in the
//! second before it died and the *System* event log happened to show Windows
//! Update disabling `nvlddmkm` at that same second - a coincidence of two
//! unrelated logs, which is not a diagnostic path anyone can rely on twice.
//!
//! The rule this module enforces: **the app never just stops.** Every launch
//! opens the ledger, every deliberate exit closes it with a named reason, and
//! an unhandled exception writes its code and address on the way out. A
//! launch that finds the previous run's entry still open records that too, so
//! the ONE case nothing inside the process can witness - killed from outside,
//! or taken down with a driver - still leaves a mark, written by the next run.
//!
//! Shape: `%LOCALAPPDATA%\ghoztty\exit-log[-debug].txt`, one line per event,
//! plain ASCII, append-only:
//!
//! ```
//! 2026-09-20T17:04:15.455Z pid=25964 event=start build=1.36.12 mode=ReleaseFast
//! 2026-09-20T17:29:51.725Z pid=25964 event=crash code=0xC0000005 addr=0x7ffb1234abcd
//! 2026-09-20T17:40:02.001Z pid=31276 event=unrecorded-exit prev_pid=25964 prev_start=2026-09-20T17:04:15.455Z
//! ```
//!
//! Why a text ledger and not JSON: the crash path must write from an
//! exception filter, where allocating, taking a lock or re-entering the
//! allocator is how a diagnostic turns into a second crash. A line composed
//! into a stack buffer and pushed through `WriteFile` on a handle that was
//! opened at startup does none of those things. The handle is opened
//! `FILE_APPEND_DATA` without `FILE_WRITE_DATA` for the same reason
//! `main_ghostty.zig` opens the log sink that way: several Ghoztty processes
//! share this file, and an append is the only write Windows guarantees will
//! not land on top of another writer's bytes.
//!
//! The line format, the parse and the dangling-run audit are pure and live
//! in `os/exit_ledger.zig`, where their unit tests run in the `none` lane on
//! every platform. What is left here is the part that needs Windows: the
//! append handle, the exception filter, the process-liveness check and the
//! trim. That half is exercised by `test\win32\exit-reason.ps1`.

const std = @import("std");
const builtin = @import("builtin");

const build_config = @import("../../build_config.zig");
const ledger = @import("../../os/exit_ledger.zig");
const w32 = @import("win32.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.win32_exit);

/// Re-exported so call sites and tests name one type (see `os/exit_ledger.zig`).
pub const Event = ledger.Event;
pub const Record = ledger.Record;
pub const Dangling = ledger.Dangling;

// ---------------------------------------------------------------------
// Windows side
// ---------------------------------------------------------------------

/// Largest ledger we leave behind. Well under a megabyte: this file is read
/// on every launch and is meant to be skimmed by a person.
const max_bytes: usize = 128 * 1024;

/// How many lines survive a trim. Roughly a month of ordinary use.
const keep_lines: usize = 400;

/// The append handle, opened by `install` and never closed - the crash filter
/// runs when the process is already past saving and must not depend on
/// anything an unwind might have taken down.
var handle: ?w32.HANDLE = null;

/// Cached so the crash filter composes its line without touching the
/// allocator or the environment.
var self_pid: u32 = 0;

var prev_filter: ?w32.TOP_LEVEL_EXCEPTION_FILTER = null;

/// `%LOCALAPPDATA%\ghoztty\exit-log[-debug].txt`. Same debug-build split as
/// every other store under that directory, so a dev build's crashes never
/// muddy the ledger the installed app is keeping. Caller frees.
pub fn ledgerPath(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    const name = if (comptime build_config.is_debug)
        "exit-log-debug.txt"
    else
        "exit-log.txt";
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

/// Now, as `2026-09-20T17:29:51.725Z`, into `buf` (24 bytes are enough).
///
/// Composed from `GetSystemTime` rather than a std time formatter because the
/// crash path calls it: one syscall filling a struct, no allocation and no
/// locale.
fn stampNow(buf: []u8) []const u8 {
    if (comptime builtin.os.tag != .windows) return buf[0..0];
    var st: w32.SYSTEMTIME = undefined;
    w32.GetSystemTime(&st);
    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{ st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds },
    ) catch buf[0..0];
}

/// Append one record. Silent on every failure by design - a ledger that
/// cannot be written must never be the reason a shutdown path stops.
fn append(event: Event, detail: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;
    const h = handle orelse return;
    var ts_buf: [32]u8 = undefined;
    var line_buf: [ledger.max_line]u8 = undefined;
    const line = ledger.formatLine(&line_buf, .{
        .ts = stampNow(&ts_buf),
        .pid = self_pid,
        .event = event,
        .detail = detail,
    });
    if (line.len == 0) return;
    var wrote: u32 = 0;
    _ = w32.WriteFile(h, line.ptr, @intCast(line.len), &wrote, null);
}

/// The unhandled-exception filter. Writes the code and the faulting address,
/// then hands the exception on so WER, a debugger and any LocalDumps rule
/// still see exactly what they would have seen.
///
/// Returning `EXCEPTION_CONTINUE_SEARCH` rather than swallowing the crash is
/// the whole point: this module makes a death *legible*, it does not make it
/// survivable, and a filter that pretended otherwise would hide the dump the
/// next investigation wants.
fn onUnhandled(info: ?*w32.EXCEPTION_POINTERS) callconv(.winapi) i32 {
    var detail_buf: [128]u8 = undefined;
    const detail: []const u8 = blk: {
        const p = info orelse break :blk "code=unknown";
        const rec = p.ExceptionRecord orelse break :blk "code=unknown";
        break :blk std.fmt.bufPrint(&detail_buf, "code=0x{X:0>8} addr=0x{X}", .{
            rec.ExceptionCode,
            @intFromPtr(rec.ExceptionAddress),
        }) catch "code=unknown";
    };
    append(.crash, detail);
    return w32.EXCEPTION_CONTINUE_SEARCH;
}

/// Open the ledger, record this launch, install the crash filter, and report
/// any previous run that never closed its entry.
///
/// Call once, as early in the GUI app's life as there is an allocator: the
/// window this covers starts at the first instruction that can fault.
pub fn install(alloc: Allocator) void {
    if (comptime builtin.os.tag != .windows) return;
    if (handle != null) return;

    const path = ledgerPath(alloc) orelse return;
    defer alloc.free(path);

    // Trim BEFORE opening for append: rewriting the file under our own open
    // append handle is the one ordering that could lose this launch's line.
    trimLedger(alloc, path);

    // The audit reads what previous runs left, so it also has to happen
    // before we add our own `start` - otherwise the newest entry in the file
    // is always ours and nothing looks dangling.
    const report = auditPrevious(alloc, path);

    if (std.fs.path.dirname(path)) |dir| std.fs.makeDirAbsolute(dir) catch {};
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return;
    defer alloc.free(path_w);

    const h = w32.CreateFileW(
        path_w.ptr,
        w32.FILE_APPEND_DATA | w32.SYNCHRONIZE,
        w32.FILE_SHARE_READ | w32.FILE_SHARE_WRITE | w32.FILE_SHARE_DELETE,
        null,
        w32.OPEN_ALWAYS,
        w32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == w32.INVALID_HANDLE_VALUE) return;
    handle = h;
    self_pid = w32.GetCurrentProcessId();

    var detail_buf: [160]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "build={s} mode={s}", .{
        build_config.version_string,
        @tagName(builtin.mode),
    }) catch "";
    append(.start, detail);

    // Anything the audit found is written by US, now that the handle is open,
    // so the ledger itself carries the verdict rather than only this run's
    // log. `report` was composed before the handle existed for exactly this.
    if (report) |r| {
        var buf: [128]u8 = undefined;
        const d = std.fmt.bufPrint(&buf, "prev_pid={d} prev_start={s}", .{
            r.pid,
            r.ts_buf[0..r.ts_len],
        }) catch "";
        append(.@"unrecorded-exit", d);
        log.warn(
            "previous run (pid {d}, started {s}) ended without recording a reason - " ++
                "killed from outside, or taken down with something it depended on",
            .{ r.pid, r.ts_buf[0..r.ts_len] },
        );
    }

    prev_filter = w32.SetUnhandledExceptionFilter(onUnhandled);
}

/// Close this run's entry with a named reason.
///
/// `reason` is a short stable tag (`user-quit`, `startup-failed`, `relaunch`)
/// - a word someone reading the ledger months later can match against the
/// code that wrote it.
pub fn recordExit(reason: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;
    var buf: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, "reason={s}", .{reason}) catch "reason=unknown";
    append(.exit, detail);
}

/// A dangling start, with its timestamp copied out of the file buffer so the
/// caller can free that buffer before writing the record.
const PrevReport = struct {
    pid: u32,
    ts_buf: [32]u8,
    ts_len: usize,
};

fn auditPrevious(alloc: Allocator, path: []const u8) ?PrevReport {
    const f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    const text = f.readToEndAlloc(alloc, max_bytes * 2) catch return null;
    defer alloc.free(text);

    var slots: [16]ledger.Dangling = undefined;
    const open = ledger.danglingStarts(text, w32.GetCurrentProcessId(), &slots);

    // Newest first: the most recent unexplained run is the one worth naming,
    // and an older one is almost always the same story already told.
    var i = open.len;
    while (i > 0) {
        i -= 1;
        if (processAlive(open[i].pid)) continue;
        var out: PrevReport = .{ .pid = open[i].pid, .ts_buf = undefined, .ts_len = 0 };
        const n = @min(open[i].ts.len, out.ts_buf.len);
        @memcpy(out.ts_buf[0..n], open[i].ts[0..n]);
        out.ts_len = n;
        return out;
    }
    return null;
}

/// Is `pid` still running?
///
/// A live pid is a SECOND APP INSTANCE, not a mystery: its start is open
/// because it has not finished yet. Without this check every launch alongside
/// a running Ghoztty would accuse it of having vanished.
fn processAlive(pid: u32) bool {
    if (comptime builtin.os.tag != .windows) return false;
    const h = w32.OpenProcess(w32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
    if (h == null) return false;
    defer _ = w32.CloseHandle(h.?);
    var code: u32 = 0;
    if (w32.GetExitCodeProcess(h.?, &code) == 0) return true;
    return code == w32.STILL_ACTIVE;
}

fn trimLedger(alloc: Allocator, path: []const u8) void {
    const stat = std.fs.cwd().statFile(path) catch return;
    if (stat.size <= max_bytes) return;

    const f = std.fs.openFileAbsolute(path, .{}) catch return;
    const text = f.readToEndAlloc(alloc, max_bytes * 8) catch {
        f.close();
        return;
    };
    f.close();
    defer alloc.free(text);

    const keep = ledger.trimmed(text, keep_lines);
    const out = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
    defer out.close();
    out.writeAll(keep) catch {};
}

