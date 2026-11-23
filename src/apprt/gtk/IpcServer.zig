//! The GTK app's IPC server (T3335, Linux L6): the Unix socket every
//! `ghoztty +<verb>` dials, at the same derivation the CLI resolves
//! (`ipc_client.endpointPath` - `$XDG_RUNTIME_DIR` first on Linux, then
//! `$TMPDIR`, then `/tmp`; `ghostty-debug-<uid>.sock` for a debug build), so
//! the two cannot drift.
//!
//! Transport only. The request shape, routing and reply wording are shared
//! with win32 in `apprt/ipc/server.zig`; the verb handlers are
//! `IpcHandlers.zig`. Framing is the shared one, both directions: a 4-byte
//! big-endian length, then that many bytes of JSON. One request per
//! connection, as the client sends it.
//!
//! Threading: one accept thread does all socket I/O. Each request is handed to
//! the GTK main thread (`glib.idleAdd`), because the handlers walk GTK
//! widgets, and the thread waits for the reply. A request still queued when
//! the server stops is abandoned safely (the job is reference-counted).
//!
//! Safety: the socket is chmod 0600 BEFORE `listen`, so no other user can ever
//! connect (a connect to a bound socket that is not listening is refused). A
//! socket file already at the path is replaced only when it is a socket WE
//! own that nothing answers on: a live instance keeps its socket (this one
//! then serves nothing and says so), and anything else is left alone.
//!
//! Recovery (T3365): a CLI whose connect is refused while the socket file
//! exists drops `<socket>.reset` and retries (`ipc_client.connectWithReset`,
//! the Mac server's protocol). The accept thread watches the socket's
//! directory with inotify (a 500 ms stat poll where inotify is unavailable)
//! and, on the sentinel, runs the same stale check as startup and rebinds; the
//! sentinel is removed once the path answers again and kept when it cannot be
//! made to, exactly as the Mac server does.
const IpcServer = @This();

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.gtk_ipc);

/// The largest request body we read. A CLI request is a few hundred bytes;
/// `+send-keys --keys-file` is the big one, and 16 MiB is far past it.
pub const max_request_len: u32 = 16 * 1024 * 1024;

/// How long a connected client may take to send its request.
const read_timeout_s = 5;

/// Serves one request on the GTK main thread and returns the reply JSON
/// (allocated with `std.heap.c_allocator`), or null for "no reply".
pub const Handler = *const fn (ctx: *anyopaque, request: []const u8) ?[]u8;

alloc: Allocator,
path: [:0]u8,
/// `<path>.reset`: the CLI's rebind request (T3365).
sentinel: [:0]u8,
/// Watches the socket's directory for the sentinel; null where inotify is
/// unavailable, and the accept loop then polls the sentinel on a timeout.
watch_fd: ?posix.fd_t,
listen_fd: posix.fd_t,
wake_r: posix.fd_t,
wake_w: posix.fd_t,
thread: std.Thread,
handler: Handler,
handler_ctx: *anyopaque,
stopping: std.atomic.Value(bool) = .init(false),

pub const StartError = error{
    /// Another live instance already answers on our path.
    AlreadyServed,
    /// Something that is not our stale socket sits at the path.
    PathOccupied,
    NameTooLong,
};

/// Bind `path` (owned by the caller only for the duration; it is copied) and
/// start serving. Returns the running server; `stop` tears it down.
pub fn start(
    alloc: Allocator,
    path: []const u8,
    handler: Handler,
    handler_ctx: *anyopaque,
) !*IpcServer {
    const path_z = try alloc.dupeZ(u8, path);
    errdefer alloc.free(path_z);
    const sentinel_z = try std.fmt.allocPrintSentinel(alloc, "{s}.reset", .{path_z}, 0);
    errdefer alloc.free(sentinel_z);

    try clearStale(path_z);

    const fd = try bindListen(path_z);
    errdefer {
        posix.close(fd);
        posix.unlink(path_z) catch {};
    }

    const pipe = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    errdefer {
        posix.close(pipe[0]);
        posix.close(pipe[1]);
    }

    const watch_fd = watchDir(path_z);
    errdefer if (watch_fd) |w| posix.close(w);

    const self = try alloc.create(IpcServer);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .path = path_z,
        .sentinel = sentinel_z,
        .watch_fd = watch_fd,
        .listen_fd = fd,
        .wake_r = pipe[0],
        .wake_w = pipe[1],
        .thread = undefined,
        .handler = handler,
        .handler_ctx = handler_ctx,
    };
    self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    self.thread.setName("gtk-ipc") catch {};
    log.info("IPC: listening on {s}", .{path_z});
    return self;
}

/// Stop serving: wake and join the accept thread, close the socket, remove
/// the file. Safe to call from the main thread while a request is queued.
pub fn stop(self: *IpcServer) void {
    self.stopping.store(true, .release);
    _ = posix.write(self.wake_w, "x") catch {};
    self.thread.join();
    posix.close(self.listen_fd);
    posix.close(self.wake_r);
    posix.close(self.wake_w);
    if (self.watch_fd) |w| posix.close(w);
    posix.unlink(self.path) catch {};
    const alloc = self.alloc;
    alloc.free(self.sentinel);
    alloc.free(self.path);
    alloc.destroy(self);
}

/// A listening socket at `path`, mode 0600. The caller has already cleared
/// the path; on error nothing is left bound.
fn bindListen(path: [:0]const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    errdefer posix.unlink(path) catch {};

    // 0600 before listen: until `listen`, every connect is refused, so there
    // is no window in which another user could reach the socket.
    try posix.fchmodat(posix.AT.FDCWD, path, 0o600, 0);
    try posix.listen(fd, 16);
    return fd;
}

/// An inotify fd watching the directory that holds `path`, or null (not
/// Linux, or inotify refused), in which case the accept loop polls instead.
fn watchDir(path: [:0]const u8) ?posix.fd_t {
    if (comptime builtin.os.tag != .linux) return null;
    const IN = std.os.linux.IN;
    const dir = std.fs.path.dirname(path) orelse ".";
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (dir.len >= dir_buf.len) return null;
    @memcpy(dir_buf[0..dir.len], dir);
    dir_buf[dir.len] = 0;
    const dir_z: [:0]const u8 = dir_buf[0..dir.len :0];

    const fd = posix.inotify_init1(IN.CLOEXEC | IN.NONBLOCK) catch |err| {
        log.warn("IPC: inotify unavailable err={}; polling for the reset sentinel", .{err});
        return null;
    };
    // CLOSE_WRITE as well as CREATE: the CLI truncates a sentinel that is
    // already there, which is no create.
    _ = posix.inotify_add_watchZ(fd, dir_z, IN.CREATE | IN.CLOSE_WRITE | IN.MOVED_TO | IN.ATTRIB) catch |err| {
        log.warn("IPC: cannot watch {s} err={}; polling for the reset sentinel", .{ dir_z, err });
        posix.close(fd);
        return null;
    };
    return fd;
}

/// How often the accept loop looks for the sentinel when it has no watch.
const sentinel_poll_ms = 500;

/// Throw away queued directory events; the sentinel's presence is checked
/// directly, so which file an event named does not matter.
fn drainWatch(fd: posix.fd_t) void {
    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch return;
        if (n == 0) return;
    }
}

fn sentinelPresent(self: *const IpcServer) bool {
    posix.accessZ(self.sentinel, posix.F_OK) catch return false;
    return true;
}

/// The CLI asked for a rebind (T3365). Same rules as startup: replace only a
/// stale socket of ours, never a live instance's or a stranger's file. The
/// old listener stays in place until a new one is bound, so a failed rebind
/// loses nothing.
fn handleSentinel(self: *IpcServer) void {
    if (!self.sentinelPresent()) return;
    log.info("IPC: reset sentinel found, rebinding {s}", .{self.path});

    clearStale(self.path) catch |err| switch (err) {
        // The path answers - ours, or an instance that took it over. Either
        // way the CLI's retry will connect, which is all it asked for.
        error.AlreadyServed => {
            posix.unlinkZ(self.sentinel) catch {};
            log.info("IPC: {s} already answers; sentinel removed", .{self.path});
            return;
        },
        else => {
            log.err("IPC: rebind refused err={}; sentinel retained", .{err});
            return;
        },
    };

    const fd = bindListen(self.path) catch |err| {
        log.err("IPC: rebind failed err={}; sentinel retained", .{err});
        return;
    };
    posix.close(self.listen_fd);
    self.listen_fd = fd;
    posix.unlinkZ(self.sentinel) catch {};
    log.info("IPC: socket rebound on {s}; sentinel removed", .{self.path});
}

/// Remove a stale socket left at `path` by an instance that died, and refuse
/// to touch anything else (T3335).
fn clearStale(path: [:0]const u8) StartError!void {
    const st = posix.fstatat(posix.AT.FDCWD, path, posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return error.PathOccupied,
    };
    if (!posix.S.ISSOCK(st.mode) or st.uid != std.c.getuid()) return error.PathOccupied;

    // A socket of ours: is anybody home?
    const probe = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch
        return error.PathOccupied;
    defer posix.close(probe);
    var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    if (posix.connect(probe, @ptrCast(&addr), @sizeOf(posix.sockaddr.un))) |_| {
        return error.AlreadyServed;
    } else |_| {}
    posix.unlink(path) catch return error.PathOccupied;
}

fn acceptLoop(self: *IpcServer) void {
    // A sentinel left from before this server bound is answered at once.
    self.handleSentinel();
    while (!self.stopping.load(.acquire)) {
        // An fd of -1 is ignored by poll, which is the no-watch case.
        var fds = [_]posix.pollfd{
            .{ .fd = self.listen_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_r, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.watch_fd orelse -1, .events = posix.POLL.IN, .revents = 0 },
        };
        const timeout: i32 = if (self.watch_fd == null) sentinel_poll_ms else -1;
        const ready = posix.poll(&fds, timeout) catch |err| {
            log.warn("IPC: poll failed err={}", .{err});
            return;
        };
        if (fds[1].revents != 0 or self.stopping.load(.acquire)) return;
        if (fds[2].revents != 0) {
            drainWatch(fds[2].fd);
            self.handleSentinel();
            // The listener may have been replaced; poll the new one.
            continue;
        }
        if (ready == 0) {
            self.handleSentinel();
            continue;
        }
        if (fds[0].revents & posix.POLL.IN == 0) continue;

        const conn = posix.accept(self.listen_fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
            log.warn("IPC: accept failed err={}", .{err});
            continue;
        };
        defer posix.close(conn);
        self.serveOne(conn) catch |err| {
            log.warn("IPC: request failed err={}", .{err});
        };
    }
}

fn serveOne(self: *IpcServer, conn: posix.fd_t) !void {
    const tv: posix.timeval = .{ .sec = read_timeout_s, .usec = 0 };
    posix.setsockopt(conn, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};

    var len_buf: [4]u8 = undefined;
    try readFull(conn, &len_buf);
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len == 0 or len > max_request_len) return error.BadRequestLength;

    const c_alloc = std.heap.c_allocator;
    const body = try c_alloc.alloc(u8, len);
    // Ownership of `body` moves into the job below.
    readFull(conn, body) catch |err| {
        c_alloc.free(body);
        return err;
    };

    const reply = self.onMainThread(body) orelse return;
    defer c_alloc.free(reply);

    var out_len: [4]u8 = undefined;
    std.mem.writeInt(u32, &out_len, @intCast(reply.len), .big);
    try writeAll(conn, &out_len);
    try writeAll(conn, reply);
}

/// A request handed to the main thread. Two references: the accept thread
/// and the idle callback; whichever lets go last frees it.
const Job = struct {
    server: *IpcServer,
    request: []u8,
    reply: ?[]u8 = null,
    done: std.Thread.ResetEvent = .{},
    abandoned: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u8) = .init(2),

    fn release(job: *Job) void {
        if (job.refs.fetchSub(1, .acq_rel) != 1) return;
        const c_alloc = std.heap.c_allocator;
        c_alloc.free(job.request);
        if (job.reply) |r| c_alloc.free(r);
        c_alloc.destroy(job);
    }
};

/// Run the handler on the GTK main thread and wait for its reply. Takes
/// ownership of `request`. Null when the server stopped first.
fn onMainThread(self: *IpcServer, request: []u8) ?[]u8 {
    const c_alloc = std.heap.c_allocator;
    const job = c_alloc.create(Job) catch {
        c_alloc.free(request);
        return null;
    };
    job.* = .{ .server = self, .request = request };
    _ = glib.idleAdd(runJob, job);

    while (true) {
        job.done.timedWait(100 * std.time.ns_per_ms) catch {
            if (self.stopping.load(.acquire)) {
                job.abandoned.store(true, .release);
                job.release();
                return null;
            }
            continue;
        };
        break;
    }
    const reply = job.reply;
    job.reply = null;
    job.release();
    return reply;
}

fn runJob(ud: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(ud orelse return 0));
    if (!job.abandoned.load(.acquire)) {
        job.reply = job.server.handler(job.server.handler_ctx, job.request);
    }
    job.done.set();
    job.release();
    return 0; // G_SOURCE_REMOVE
}

fn readFull(fd: posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(fd, buf[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) off += try posix.write(fd, bytes[off..]);
}

// The endpoint this app binds is the same `ipc_client.endpointPath` the CLI
// dials; that function's own tests pin the derivation.
comptime {
    _ = internal_os.ipc_client.endpointPath;
}
