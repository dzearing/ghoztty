//! The text half of the Windows crash report (T1355): the file names and
//! the report body, as pure functions over caller-owned buffers.
//!
//! `windows.zig` calls these from inside an unhandled-exception filter,
//! where allocating or taking a lock is how a diagnostic becomes a second
//! crash, so nothing here allocates: every function writes into a slice it
//! was handed and returns the part it used. They live apart from the Win32
//! half so their tests run in the `none` lane on every platform.

const std = @import("std");

/// Everything the report says, gathered by the filter before formatting.
pub const Fields = struct {
    build: []const u8,
    mode: []const u8,
    /// ISO-8601 UTC, e.g. `2026-10-24T23:45:12.123Z`.
    time: []const u8,
    pid: u32,
    thread: u32,
    /// Which of Ghoztty's threads crashed (`main`, `renderer`, `io`), when
    /// the crashing thread said (T2244). Null for a thread nobody named.
    thread_kind: ?[]const u8 = null,
    code: u32,
    /// The panic message, for a `code_panic` report (T2244). Written on one
    /// line: CR/LF and other control bytes become spaces, and it is capped
    /// at `message_max` bytes so a huge message cannot push the rest of the
    /// report out of the fixed buffer.
    message: ?[]const u8 = null,
    address: usize,
    /// Full path of the module the faulting address is in, when it could be
    /// resolved. Null when the lookup was skipped (loader lock held) or
    /// failed (the address is not inside any loaded image).
    module: ?[]const u8 = null,
    module_base: usize = 0,
    /// Only for an access violation: what the faulting instruction tried.
    access: ?Access = null,
    dump: Dump,
};

pub const Access = struct {
    op: Op,
    target: usize,

    pub const Op = enum { read, write, execute, unknown };

    /// The first two `ExceptionInformation` slots of an access violation:
    /// 0 = read, 1 = write, 8 = DEP execute, then the inaccessible address.
    pub fn fromInformation(kind: usize, target: usize) Access {
        return .{
            .op = switch (kind) {
                0 => .read,
                1 => .write,
                8 => .execute,
                else => .unknown,
            },
            .target = target,
        };
    }
};

pub const Dump = union(enum) {
    /// The minidump's file name, beside the report.
    written: []const u8,
    /// Why no dump exists, as a short stable phrase.
    skipped: []const u8,
};

pub const code_access_violation: u32 = 0xC0000005;

/// The code a Zig panic is raised with on Windows (T2244), so a panic reaches
/// the same unhandled-exception filter - and the exit ledger - as a fault.
/// Bit 29 (the customer bit) is set, as Windows requires of an application's
/// own codes; the low three bytes spell `GZP`. A panic otherwise ends in
/// `ExitProcess(3)` in a shipping build and no filter ever runs.
pub const code_panic: u32 = 0xE0475A50;

/// `ExceptionInformation` slots of a `code_panic` exception.
pub const panic_param_msg_ptr = 0;
pub const panic_param_msg_len = 1;
/// The address the panic was raised from (Zig's `first_trace_addr`, else the
/// handler's return address), which the report names instead of the
/// RaiseException frame inside kernelbase.dll.
pub const panic_param_address = 2;
pub const panic_param_count = 3;

/// Longest panic message the report carries.
pub const message_max = 512;

/// The address a report (and the exit ledger) names for an exception: the
/// panic site for a `code_panic`, which `RaiseException` would otherwise
/// misreport as a frame in kernelbase.dll, else the exception's own address.
/// One function so the two filters cannot disagree about where it died.
pub fn crashAddress(code: u32, params: []const usize, exception_address: usize) usize {
    if (code == code_panic and params.len >= panic_param_count) {
        const at = params[panic_param_address];
        if (at != 0) return at;
    }
    return exception_address;
}

/// A name for the exception codes a terminal is plausibly going to die of.
/// Unknown codes get no name; the hex code is always printed regardless.
pub fn codeName(code: u32) ?[]const u8 {
    return switch (code) {
        0xC0000005 => "access violation",
        0xC00000FD => "stack overflow",
        0x80000003 => "breakpoint",
        0xC000001D => "illegal instruction",
        0xC0000094 => "integer divide by zero",
        0xC0000409 => "stack buffer overrun",
        0xC0000374 => "heap corruption",
        0xC0000096 => "privileged instruction",
        0x80000002 => "datatype misalignment",
        0xE06D7363 => "C++ exception",
        code_panic => "Ghoztty panic",
        else => null,
    };
}

/// The stem both files share, `20261024T234512Z-1234`: sortable, unique per
/// process, and free of the characters a Windows file name cannot hold.
pub fn baseName(
    buf: []u8,
    year: u16,
    month: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    pid: u32,
) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z-{d}",
        .{ year, month, day, hour, minute, second, pid },
    ) catch buf[0..0];
}

/// The report body. One `key=value` per line under a title, so a person can
/// read it and a script can grep it. Returns an empty slice only if `buf` is
/// too small for even the fixed fields.
pub fn format(buf: []u8, f: Fields) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    write(&w, f) catch {};
    return w.buffered();
}

fn write(w: *std.Io.Writer, f: Fields) std.Io.Writer.Error!void {
    try w.writeAll("Ghoztty crash report\r\n");
    try w.print("build={s}\r\nmode={s}\r\ntime={s}\r\n", .{ f.build, f.mode, f.time });
    try w.print("pid={d}\r\nthread={d}\r\n", .{ f.pid, f.thread });
    if (f.thread_kind) |k| try w.print("thread_kind={s}\r\n", .{k});
    try w.print("code=0x{X:0>8}", .{f.code});
    if (codeName(f.code)) |name| try w.print(" ({s})", .{name});
    try w.writeAll("\r\n");
    if (f.message) |m| {
        try w.writeAll("message=");
        const shown = m[0..@min(m.len, message_max)];
        for (shown) |c| try w.writeByte(if (c < 0x20 or c == 0x7F) ' ' else c);
        if (m.len > shown.len) try w.writeAll("...");
        try w.writeAll("\r\n");
    }
    try w.print("address=0x{X}\r\n", .{f.address});
    if (f.module) |m| {
        try w.print("module={s}+0x{X}\r\n", .{ m, f.address -% f.module_base });
    } else {
        try w.writeAll("module=unknown\r\n");
    }
    if (f.access) |a| try w.print("access={s} 0x{X}\r\n", .{ @tagName(a.op), a.target });
    switch (f.dump) {
        .written => |name| try w.print("dump={s}\r\n", .{name}),
        .skipped => |why| try w.print("dump=none ({s})\r\n", .{why}),
    }
}

test "baseName is sortable and pid-qualified" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "20260905T010203Z-4242",
        baseName(&buf, 2026, 9, 5, 1, 2, 3, 4242),
    );
}

test "baseName on a buffer too small is empty, not a crash" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), baseName(&buf, 2026, 9, 5, 1, 2, 3, 4242).len);
}

test "format names the code, the address, the module offset and the dump" {
    var buf: [1024]u8 = undefined;
    const text = format(&buf, .{
        .build = "1.37.2",
        .mode = "ReleaseFast",
        .time = "2026-10-24T23:45:12.123Z",
        .pid = 1234,
        .thread = 5678,
        .code = code_access_violation,
        .address = 0x7FF612341234,
        .module = "C:\\Ghoztty\\ghoztty.exe",
        .module_base = 0x7FF612340000,
        .access = Access.fromInformation(1, 0),
        .dump = .{ .written = "20261024T234512Z-1234.dmp" },
    });
    try std.testing.expectEqualStrings(
        "Ghoztty crash report\r\n" ++
            "build=1.37.2\r\nmode=ReleaseFast\r\ntime=2026-10-24T23:45:12.123Z\r\n" ++
            "pid=1234\r\nthread=5678\r\n" ++
            "code=0xC0000005 (access violation)\r\n" ++
            "address=0x7FF612341234\r\n" ++
            "module=C:\\Ghoztty\\ghoztty.exe+0x1234\r\n" ++
            "access=write 0x0\r\n" ++
            "dump=20261024T234512Z-1234.dmp\r\n",
        text,
    );
}

test "format with an unknown code, no module and a skipped dump" {
    var buf: [1024]u8 = undefined;
    const text = format(&buf, .{
        .build = "1.37.2",
        .mode = "Debug",
        .time = "t",
        .pid = 1,
        .thread = 2,
        .code = 0xE0001234,
        .address = 0x10,
        .dump = .{ .skipped = "loader lock held" },
    });
    try std.testing.expect(std.mem.indexOf(u8, text, "code=0xE0001234\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "module=unknown\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "access=") == null);
    try std.testing.expect(std.mem.endsWith(u8, text, "dump=none (loader lock held)\r\n"));
}

test "format into a short buffer truncates rather than failing" {
    var buf: [24]u8 = undefined;
    const text = format(&buf, .{
        .build = "b",
        .mode = "m",
        .time = "t",
        .pid = 1,
        .thread = 2,
        .code = 0,
        .address = 0,
        .dump = .{ .skipped = "x" },
    });
    try std.testing.expect(text.len <= buf.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "Ghoztty crash report"));
}

test "a panic report names the thread kind and carries the message on one line" {
    var buf: [1024]u8 = undefined;
    const text = format(&buf, .{
        .build = "1.37.2",
        .mode = "ReleaseFast",
        .time = "t",
        .pid = 7,
        .thread = 9,
        .thread_kind = "renderer",
        .code = code_panic,
        .message = "index out of bounds\r\nsecond line",
        .address = 0x1000,
        .dump = .{ .written = "x.dmp" },
    });
    try std.testing.expect(std.mem.indexOf(u8, text, "thread=9\r\nthread_kind=renderer\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "code=0xE0475A50 (Ghoztty panic)\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "message=index out of bounds  second line\r\naddress=") != null);
}

test "crashAddress names the panic site for a panic and the fault address otherwise" {
    const params = [_]usize{ 0x10, 4, 0x7FF600001234 };
    try std.testing.expectEqual(@as(usize, 0x7FF600001234), crashAddress(code_panic, &params, 0x7FFB0000AAAA));
    // A panic record missing its parameters falls back rather than reading past them.
    try std.testing.expectEqual(@as(usize, 0x7FFB0000AAAA), crashAddress(code_panic, params[0..2], 0x7FFB0000AAAA));
    // A zero panic site falls back too.
    const zero = [_]usize{ 0x10, 4, 0 };
    try std.testing.expectEqual(@as(usize, 0x7FFB0000AAAA), crashAddress(code_panic, &zero, 0x7FFB0000AAAA));
    // Any other code is its own address, whatever its parameters say.
    try std.testing.expectEqual(@as(usize, 0x500), crashAddress(code_access_violation, &params, 0x500));
}

test "a fault report has no thread_kind or message lines" {
    var buf: [1024]u8 = undefined;
    const text = format(&buf, .{
        .build = "b",
        .mode = "m",
        .time = "t",
        .pid = 1,
        .thread = 2,
        .code = code_access_violation,
        .address = 0,
        .dump = .{ .skipped = "x" },
    });
    try std.testing.expect(std.mem.indexOf(u8, text, "thread_kind=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "message=") == null);
}

test "a long panic message is capped and marked" {
    var buf: [2048]u8 = undefined;
    const long = "x" ** (message_max + 100);
    const text = format(&buf, .{
        .build = "b",
        .mode = "m",
        .time = "t",
        .pid = 1,
        .thread = 2,
        .code = code_panic,
        .message = long,
        .address = 0,
        .dump = .{ .skipped = "x" },
    });
    try std.testing.expect(std.mem.indexOf(u8, text, "message=" ++ ("x" ** message_max) ++ "...\r\n") != null);
}

test "access violation kinds" {
    try std.testing.expectEqual(Access.Op.read, Access.fromInformation(0, 0).op);
    try std.testing.expectEqual(Access.Op.write, Access.fromInformation(1, 0).op);
    try std.testing.expectEqual(Access.Op.execute, Access.fromInformation(8, 0).op);
    try std.testing.expectEqual(Access.Op.unknown, Access.fromInformation(3, 0).op);
}
