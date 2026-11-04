//! A `std.Thread` stand-in whose OS thread outlives the work it was spawned
//! for (T2644).
//!
//! Why this exists: every pane runs its renderer on a thread of its own, and
//! closing the pane joined that thread and let it exit. On the NVIDIA OpenGL
//! driver (`nvoglv64.dll`) a thread that has made a context current keeps
//! about 0.2 MB of driver state that is NOT released when the thread exits,
//! even though the context itself was deleted and `wglDeleteContext`
//! succeeded. Measured with `docs/design/t2644-gl-thread-churn.zig`, 800
//! window+context+render-thread cycles:
//!
//! - render on a fresh thread each cycle (the old shape): 109 -> 244 MB,
//!   unbounded, whichever thread deletes the context;
//! - render on ONE long-lived thread that serves every cycle: 95.9 MB flat.
//!
//! So the renderer's OS thread is parked on close instead of exiting, and the
//! next pane's renderer runs on it. The driver's per-thread state is reused
//! rather than stranded, and the leak is bounded by the most panes ever open
//! at once instead of by the number ever closed.
//!
//! Semantics match the `std.Thread` subset the core surface uses: `spawn`
//! runs `f(args...)` on a pooled thread, `join` waits for that call to return
//! (not for the OS thread to exit - it does not), `setName` is a no-op because
//! a pool names its threads once, when it creates them. Thread-local state the
//! previous job left behind survives into the next one, so a job that keeps
//! any must reset it on entry (the OpenGL renderer does, in `threadEnter`).
const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.reusable_thread);

/// Whether per-pane threads are pooled on this target. Only Windows needs it
/// (the driver behaviour above is a Windows GL driver's); everywhere else a
/// pane thread is the plain `std.Thread` it always was.
pub const pooled = builtin.os.tag == .windows;

/// The handle type of a per-pane thread: `Handle` when pooled, else
/// `std.Thread`. Both offer `join` and `setName`.
pub const PaneThread = if (pooled) Handle else std.Thread;

/// Spawn a per-pane thread: on `pool` when pooled, else a fresh `std.Thread`.
pub fn spawnPane(pool: *Pool, comptime f: anytype, args: anytype) std.Thread.SpawnError!PaneThread {
    if (comptime pooled) return pool.spawn(f, args);
    return std.Thread.spawn(.{}, f, args);
}

/// Memory for jobs and workers. Not the app's allocator on purpose: the pool
/// is process-lifetime and outlives every allocator a leak check runs over.
const alloc = std.heap.page_allocator;

pub const Pool = struct {
    /// Applied to every OS thread this pool creates.
    name: ?[]const u8 = null,
    /// Parked threads kept beyond this many exit instead. Bounds the idle
    /// footprint after a burst; the exit costs what the old shape cost.
    max_idle: u32 = 16,
    spawn_config: std.Thread.SpawnConfig = .{},

    mutex: std.Thread.Mutex = .{},
    idle: ?*Worker = null,
    idle_count: u32 = 0,
    /// OS threads ever created by this pool (tests read it).
    created: u32 = 0,
    quitting: bool = false,

    /// Run `f(args...)` on a parked thread, or a new one when none is idle.
    pub fn spawn(self: *Pool, comptime f: anytype, args: anytype) std.Thread.SpawnError!Handle {
        const Args = @TypeOf(args);
        const Closure = struct {
            job: Job,
            args: Args,

            fn run(j: *Job) void {
                const c: *@This() = @alignCast(@fieldParentPtr("job", j));
                const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
                switch (@typeInfo(R)) {
                    .error_union => @call(.auto, f, c.args) catch |err|
                        log.warn("pooled thread job failed err={}", .{err}),
                    else => _ = @call(.auto, f, c.args),
                }
            }

            fn free(j: *Job) void {
                const c: *@This() = @alignCast(@fieldParentPtr("job", j));
                alloc.destroy(c);
            }
        };

        const c = alloc.create(Closure) catch return error.OutOfMemory;
        c.* = .{ .job = .{ .run = Closure.run, .free = Closure.free }, .args = args };
        errdefer alloc.destroy(c);

        self.mutex.lock();
        const parked = self.idle;
        if (parked) |wk| {
            self.idle = wk.next;
            self.idle_count -= 1;
        }
        self.mutex.unlock();

        if (parked) |wk| {
            wk.next = null;
            wk.job = &c.job;
            wk.wake.set();
            return .{ .job = &c.job };
        }

        const wk = alloc.create(Worker) catch return error.OutOfMemory;
        errdefer alloc.destroy(wk);
        wk.* = .{ .pool = self, .job = &c.job };
        wk.wake.set();
        const t = try std.Thread.spawn(self.spawn_config, Worker.main, .{wk});
        if (self.name) |n| t.setName(n) catch {};
        t.detach();
        self.mutex.lock();
        self.created += 1;
        self.mutex.unlock();
        return .{ .job = &c.job };
    }

    /// Wake every parked thread and let it exit. For tests: a process-wide
    /// pool is never shut down, its parked threads end with the process.
    pub fn shutdown(self: *Pool) void {
        self.mutex.lock();
        self.quitting = true;
        var it = self.idle;
        self.idle = null;
        self.idle_count = 0;
        self.mutex.unlock();
        while (it) |wk| {
            it = wk.next;
            wk.job = null;
            wk.wake.set();
        }
    }

    /// The worker asks to be parked. False means exit (over the cap, or the
    /// pool is shutting down).
    fn park(self: *Pool, wk: *Worker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.quitting or self.idle_count >= self.max_idle) return false;
        wk.next = self.idle;
        self.idle = wk;
        self.idle_count += 1;
        return true;
    }

    pub fn idleCount(self: *Pool) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.idle_count;
    }
};

const Job = struct {
    run: *const fn (*Job) void,
    free: *const fn (*Job) void,
    done: std.Thread.ResetEvent = .{},
};

const Worker = struct {
    pool: *Pool,
    job: ?*Job,
    next: ?*Worker = null,
    wake: std.Thread.ResetEvent = .{},

    fn main(self: *Worker) void {
        while (true) {
            self.wake.wait();
            self.wake.reset();
            // Null only from `shutdown`; the pool may be gone, touch nothing.
            const job = self.job orelse break;
            self.job = null;
            job.run(job);
            // Park BEFORE reporting done, so a joiner that spawns again at
            // once finds this thread idle instead of creating a new one. A
            // spawn that lands between the two sets `wake`, which the next
            // `wait` sees.
            const parked = self.pool.park(self);
            job.done.set();
            if (!parked) break;
        }
        alloc.destroy(self);
    }
};

pub const Handle = struct {
    job: *Job,

    /// Wait for the spawned call to return. The OS thread lives on, parked.
    pub fn join(self: Handle) void {
        self.job.done.wait();
        self.job.free(self.job);
    }

    /// True once the spawned call has returned; waits at most `timeout_ns`.
    /// The pooled stand-in for waiting on a `std.Thread`'s OS handle, which
    /// never signals here because the OS thread does not exit.
    pub fn timedWait(self: Handle, timeout_ns: u64) bool {
        self.job.done.timedWait(timeout_ns) catch return false;
        return true;
    }

    /// Pooled threads are named by their pool when created.
    pub fn setName(self: Handle, name: []const u8) std.Thread.SetNameError!void {
        _ = self;
        _ = name;
    }
};

test "spawn runs the call and join waits for it" {
    var pool: Pool = .{};
    defer pool.shutdown();
    var hits: u32 = 0;
    const S = struct {
        fn bump(p: *u32, by: u32) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            p.* += by;
        }
    };
    const h = try pool.spawn(S.bump, .{ &hits, 7 });
    h.join();
    try std.testing.expectEqual(@as(u32, 7), hits);
}

test "a joined thread is reused by the next spawn (T2644)" {
    var pool: Pool = .{};
    defer pool.shutdown();
    const S = struct {
        fn record(out: *std.Thread.Id) void {
            out.* = std.Thread.getCurrentId();
        }
    };
    var ids: [20]std.Thread.Id = undefined;
    for (&ids) |*id| (try pool.spawn(S.record, .{id})).join();
    for (ids[1..]) |id| try std.testing.expectEqual(ids[0], id);
    try std.testing.expectEqual(@as(u32, 1), pool.created);
    try std.testing.expectEqual(@as(u32, 1), pool.idleCount());
}

test "concurrent spawns get distinct threads, then all park" {
    var pool: Pool = .{};
    defer pool.shutdown();
    const S = struct {
        fn wait(gate: *std.Thread.ResetEvent, out: *std.Thread.Id) void {
            out.* = std.Thread.getCurrentId();
            gate.wait();
        }
    };
    var gate: std.Thread.ResetEvent = .{};
    var ids: [4]std.Thread.Id = undefined;
    var hs: [4]Handle = undefined;
    for (&hs, &ids) |*h, *id| h.* = try pool.spawn(S.wait, .{ &gate, id });
    gate.set();
    for (hs) |h| h.join();
    for (ids, 0..) |a, i| for (ids[i + 1 ..]) |b| try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(u32, 4), pool.created);
    try std.testing.expectEqual(@as(u32, 4), pool.idleCount());
}

test "timedWait reports a running job, then a finished one" {
    var pool: Pool = .{};
    defer pool.shutdown();
    const S = struct {
        fn wait(gate: *std.Thread.ResetEvent) void {
            gate.wait();
        }
    };
    var gate: std.Thread.ResetEvent = .{};
    const h = try pool.spawn(S.wait, .{&gate});
    try std.testing.expect(!h.timedWait(10 * std.time.ns_per_ms));
    gate.set();
    try std.testing.expect(h.timedWait(5 * std.time.ns_per_s));
    h.join();
}

test "threads past max_idle exit rather than park" {
    var pool: Pool = .{ .max_idle = 2 };
    defer pool.shutdown();
    const S = struct {
        fn wait(gate: *std.Thread.ResetEvent) void {
            gate.wait();
        }
    };
    var gate: std.Thread.ResetEvent = .{};
    var hs: [5]Handle = undefined;
    for (&hs) |*h| h.* = try pool.spawn(S.wait, .{&gate});
    gate.set();
    for (hs) |h| h.join();
    try std.testing.expectEqual(@as(u32, 2), pool.idleCount());
}

test "an error-returning job is logged, not lost, and the thread parks" {
    var pool: Pool = .{};
    defer pool.shutdown();
    const S = struct {
        fn fail() error{Nope}!void {
            return error.Nope;
        }
    };
    (try pool.spawn(S.fail, .{})).join();
    try std.testing.expectEqual(@as(u32, 1), pool.idleCount());
}
