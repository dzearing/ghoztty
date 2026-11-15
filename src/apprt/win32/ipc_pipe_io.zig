//! Per-connection pipe I/O for the win32 IPC server (T3105, Mac 1956f5f55).
//!
//! Every read and write the server does on a client's pipe instance is
//! bounded by `io_timeout_ms`, the same 5 s the Mac server puts on its
//! sockets. Before this the server's pipes were synchronous: a client that
//! connected and sent nothing parked its listener in an uninterruptible
//! `ReadFile` for the life of the app. Four of them (one per instance) and
//! every later `ghoztty +verb`, status hook and banner hook in every pane
//! answered "No running Ghoztty instance found."; one of them and quit hung,
//! because shutdown waits for every listener to come home.
//!
//! So the instances are created `FILE_FLAG_OVERLAPPED`, accept with an
//! overlapped `ConnectNamedPipe`, and read/write through `ipc_client.Conn`'s
//! bounded overlapped path (the one the CLIENT already uses since T755).
//! `cancel` aborts whatever a listener is waiting on, which is how shutdown
//! no longer waits behind a slow client at all.
//!
//! The one call that cannot be bounded is `FlushFileBuffers`: it blocks until
//! the client has read everything, so a client that sends a request and then
//! never reads the answer held the instance forever the same way. `finish`
//! replaces it with a bounded wait for the client to close its end — which is
//! what every client does straight after reading its framed response, and
//! what guarantees the response was read before `DisconnectNamedPipe`
//! discards anything still buffered.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const ipc_client = @import("../../os/main.zig").ipc_client;

/// Bound on any single read or write the server does on a client, and on the
/// wait for the client to hang up after its response. Mac: 5 s SO_RCVTIMEO /
/// SO_SNDTIMEO on each accepted socket.
pub const io_timeout_ms: u32 = 5000;

const FILE_FLAG_FIRST_PIPE_INSTANCE: windows.DWORD = 0x00080000;
const PIPE_REJECT_REMOTE_CLIENTS: windows.DWORD = 0x00000008;

extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DisconnectNamedPipe(
    hNamedPipe: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

/// Create one server instance of `path_w`. `first` carries
/// FILE_FLAG_FIRST_PIPE_INSTANCE (the single-instance lock). Returns
/// INVALID_HANDLE_VALUE on failure; the caller reads GetLastError.
pub fn createInstance(
    path_w: [*:0]const u16,
    first: bool,
    max_instances: windows.DWORD,
    sa: ?*windows.SECURITY_ATTRIBUTES,
) windows.HANDLE {
    return windows.kernel32.CreateNamedPipeW(
        path_w,
        windows.PIPE_ACCESS_DUPLEX | windows.FILE_FLAG_OVERLAPPED |
            (if (first) FILE_FLAG_FIRST_PIPE_INSTANCE else 0),
        windows.PIPE_TYPE_BYTE | windows.PIPE_READMODE_BYTE |
            windows.PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        max_instances,
        64 * 1024,
        64 * 1024,
        0,
        sa,
    );
}

pub const Accept = union(enum) {
    connected,
    /// The wait was cancelled (`cancel`), normally by shutdown.
    cancelled,
    failed: windows.Win32Error,
};

/// Wait, unbounded, for a client to connect to `pipe`. Unbounded on purpose:
/// an idle server waiting for its next client is not a stall. `cancel` (or a
/// connecting client) ends the wait.
pub fn accept(pipe: windows.HANDLE) Accept {
    const event = windows.kernel32.CreateEventExW(
        null,
        null,
        windows.CREATE_EVENT_MANUAL_RESET,
        windows.EVENT_ALL_ACCESS,
    ) orelse return .{ .failed = windows.GetLastError() };
    defer windows.CloseHandle(event);

    var ov: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
    ov.hEvent = event;
    if (ConnectNamedPipe(pipe, &ov) != 0) return .connected;
    switch (windows.GetLastError()) {
        // A client got in between CreateNamedPipe/Disconnect and here.
        .PIPE_CONNECTED => return .connected,
        .IO_PENDING => {},
        else => |err| return .{ .failed = err },
    }
    _ = windows.kernel32.WaitForSingleObject(event, windows.INFINITE);
    var transferred: windows.DWORD = 0;
    if (windows.kernel32.GetOverlappedResult(pipe, &ov, &transferred, 0) != 0) return .connected;
    return switch (windows.GetLastError()) {
        .OPERATION_ABORTED => .cancelled,
        .PIPE_CONNECTED => .connected,
        else => |err| .{ .failed = err },
    };
}

/// The connection the server reads the request from and writes the response
/// to: overlapped, so every operation is bounded by `io_timeout_ms`.
pub fn conn(pipe: windows.HANDLE) ipc_client.Conn {
    return .{ .handle = pipe, .owned = true, .timeout_ms = io_timeout_ms };
}

/// End a served connection. With `answered`, first wait (bounded) for the
/// client to close its end, so the response it is reading is not discarded by
/// the disconnect. Then disconnect, readying the instance for the next client.
pub fn finish(pipe: windows.HANDLE, answered: bool) void {
    if (answered) awaitHangup(pipe, io_timeout_ms);
    _ = DisconnectNamedPipe(pipe);
}

/// Wait up to `budget_ms` for the client to hang up. Bytes it sends meanwhile
/// are discarded (the protocol is one request per connection).
fn awaitHangup(pipe: windows.HANDLE, budget_ms: u32) void {
    const c = conn(pipe);
    var timer = std.time.Timer.start() catch return;
    var scratch: [64]u8 = undefined;
    while (true) {
        const spent: u64 = timer.read() / std.time.ns_per_ms;
        if (spent >= budget_ms) return;
        var done: usize = 0;
        c.readFullWithin(&scratch, &done, @intCast(budget_ms - spent)) catch return;
    }
}

/// Abort whatever I/O any thread is waiting on for `pipe` — an accept, a
/// request read, a response write or the hang-up wait. Shutdown's lever.
pub fn cancel(pipe: windows.HANDLE) void {
    _ = windows.kernel32.CancelIoEx(pipe, null);
}

// --- tests: a real pipe, a real silent client --------------------------------

const TestPipe = struct {
    name: [:0]u16,
    server: windows.HANDLE,

    fn init(alloc: std.mem.Allocator) !TestPipe {
        var buf: [96]u8 = undefined;
        const name8 = try std.fmt.bufPrint(&buf, "\\\\.\\pipe\\ghoztty-pipeio-test-{d}-{d}", .{
            windows.GetCurrentProcessId(),
            std.crypto.random.int(u32),
        });
        const name = try std.unicode.utf8ToUtf16LeAllocZ(alloc, name8);
        errdefer alloc.free(name);
        const server = createInstance(name.ptr, true, 1, null);
        if (server == windows.INVALID_HANDLE_VALUE) return error.CreatePipeFailed;
        return .{ .name = name, .server = server };
    }

    fn deinit(self: *TestPipe, alloc: std.mem.Allocator) void {
        windows.CloseHandle(self.server);
        alloc.free(self.name);
    }

    fn dial(self: *TestPipe) !windows.HANDLE {
        const h = windows.kernel32.CreateFileW(
            self.name.ptr,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0,
            null,
            windows.OPEN_EXISTING,
            0,
            null,
        );
        if (h == windows.INVALID_HANDLE_VALUE) return error.DialFailed;
        return h;
    }
};

fn elapsedMs(timer: *std.time.Timer) u64 {
    return timer.read() / std.time.ns_per_ms;
}

test "a client that connects and sends nothing cannot hold a read past the bound" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var p = try TestPipe.init(alloc);
    defer p.deinit(alloc);
    const client = try p.dial();
    defer windows.CloseHandle(client);
    try std.testing.expect(accept(p.server) == .connected);

    var c = conn(p.server);
    c.timeout_ms = 200;
    var len_bytes: [4]u8 = undefined;
    var timer = try std.time.Timer.start();
    try std.testing.expectError(error.Timeout, c.readFull(&len_bytes));
    try std.testing.expect(elapsedMs(&timer) < 3000);
}

test "a request is read in full and its response reaches a client that reads it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var p = try TestPipe.init(alloc);
    defer p.deinit(alloc);
    const client = try p.dial();
    defer windows.CloseHandle(client);
    try std.testing.expect(accept(p.server) == .connected);

    _ = try windows.WriteFile(client, "ping", null);
    var req: [4]u8 = undefined;
    try conn(p.server).readFull(&req);
    try std.testing.expectEqualStrings("ping", &req);

    try conn(p.server).writeAll("pong");
    var resp: [4]u8 = undefined;
    var got: usize = 0;
    while (got < resp.len) got += try windows.ReadFile(client, resp[got..], null);
    try std.testing.expectEqualStrings("pong", &resp);
}

test "the hang-up wait ends as soon as the client closes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var p = try TestPipe.init(alloc);
    defer p.deinit(alloc);
    const client = try p.dial();
    try std.testing.expect(accept(p.server) == .connected);
    windows.CloseHandle(client);

    var timer = try std.time.Timer.start();
    finish(p.server, true);
    try std.testing.expect(elapsedMs(&timer) < 1000);
}

test "the hang-up wait is bounded when the client never closes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var p = try TestPipe.init(alloc);
    defer p.deinit(alloc);
    const client = try p.dial();
    defer windows.CloseHandle(client);
    try std.testing.expect(accept(p.server) == .connected);

    var timer = try std.time.Timer.start();
    awaitHangup(p.server, 200);
    try std.testing.expect(elapsedMs(&timer) < 3000);
}

test "cancel ends a pending accept and a pending read promptly" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var p = try TestPipe.init(alloc);
    defer p.deinit(alloc);

    const Canceller = struct {
        fn run(pipe: windows.HANDLE) void {
            std.Thread.sleep(150 * std.time.ns_per_ms);
            cancel(pipe);
        }
    };

    // Accept with nobody dialing: only the cancel can end it.
    {
        var timer = try std.time.Timer.start();
        const t = try std.Thread.spawn(.{}, Canceller.run, .{p.server});
        const got = accept(p.server);
        t.join();
        try std.testing.expect(got == .cancelled);
        try std.testing.expect(elapsedMs(&timer) < 3000);
    }

    // A read under the full 5 s bound, cut short by the cancel.
    const client = try p.dial();
    defer windows.CloseHandle(client);
    try std.testing.expect(accept(p.server) == .connected);
    {
        var buf: [4]u8 = undefined;
        var timer = try std.time.Timer.start();
        const t = try std.Thread.spawn(.{}, Canceller.run, .{p.server});
        const got = conn(p.server).readFull(&buf);
        t.join();
        try std.testing.expectError(error.Timeout, got);
        try std.testing.expect(elapsedMs(&timer) < io_timeout_ms / 2);
    }
}
