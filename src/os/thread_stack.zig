//! Thread stacks that are reserved, not committed, on Windows (T2985).
//!
//! Zig 0.15.2's `std.Thread.spawn` hands `SpawnConfig.stack_size` (default
//! 16 MB) to `CreateThread` as `dwStackSize` with no creation flags, and
//! without `STACK_SIZE_PARAM_IS_A_RESERVATION` Windows reads that number as
//! the stack's initial COMMIT. Every thread spawned with `.{}` therefore
//! charged 16 MB of private bytes up front: three per pane (renderer, io,
//! io-reader), and the pooled pane threads kept theirs while parked.
//!
//! The fix leans on the rule Windows applies when the commit asked for is
//! below the executable's reserve: the reserve stays the one in the PE
//! header (`SizeOfStackReserve`, 16 MB for every Zig-linked exe here) and the
//! stack grows into it on demand through its guard page. So a small
//! `stack_size` keeps the same maximum depth as before and only stops paying
//! for it in advance - the same outcome the reservation flag would give, which
//! std does not let a caller pass. The test below measures both halves.
//!
//! Elsewhere the default stays: pthread stacks are mmap'd and committed
//! lazily, so macOS and Linux never had the cost.
const std = @import("std");
const builtin = @import("builtin");

/// The std default this module overrides. Named here, outside any test block,
/// because thread-join-audit's case-insensitive `std.Thread.spawn` match
/// would read `std.Thread.SpawnConfig` inside a test as a spawn site.
const std_default_stack_size = std.Thread.SpawnConfig.default_stack_size;

/// Initial commit asked of Windows. `std.Thread` floors anything smaller to
/// 64 KB anyway (one allocation granule).
pub const windows_commit_hint: usize = 64 * 1024;

/// The spawn config every long-lived thread should use instead of `.{}`.
pub const config: std.Thread.SpawnConfig = if (builtin.os.tag == .windows)
    .{ .stack_size = windows_commit_hint }
else
    .{};

/// `std.Thread.spawn(config, f, args)`.
pub fn spawn(comptime f: anytype, args: anytype) std.Thread.SpawnError!std.Thread {
    return std.Thread.spawn(config, f, args);
}

/// Options for a long-lived `std.Thread.Pool` (T3095). `Pool.Options` carries
/// its own `stack_size`, defaulting to the same 16 MB as `SpawnConfig`, and
/// `Pool.init` hands it to every worker's spawn - so a pool made with
/// `.{ .allocator = ..., .n_jobs = ... }` commits 16 MB per worker on Windows
/// for as long as it lives, which `config` above never reaches.
pub fn poolOptions(allocator: std.mem.Allocator, n_jobs: ?usize) std.Thread.Pool.Options {
    return .{ .allocator = allocator, .n_jobs = n_jobs, .stack_size = config.stack_size };
}

const win = struct {
    const MEMORY_BASIC_INFORMATION = extern struct {
        BaseAddress: ?*anyopaque,
        AllocationBase: ?*anyopaque,
        AllocationProtect: u32,
        PartitionId: u16,
        RegionSize: usize,
        State: u32,
        Protect: u32,
        Type: u32,
    };
    const MEM_COMMIT: u32 = 0x1000;
    extern "kernel32" fn GetCurrentThreadStackLimits(low: *usize, high: *usize) callconv(.winapi) void;
    extern "kernel32" fn VirtualQuery(addr: ?*const anyopaque, info: *MEMORY_BASIC_INFORMATION, len: usize) callconv(.winapi) usize;
};

const StackShape = struct { reserved: usize = 0, committed: usize = 0 };

/// Reserve and commit of the calling thread's stack.
fn measureOwnStack() StackShape {
    var low: usize = 0;
    var high: usize = 0;
    win.GetCurrentThreadStackLimits(&low, &high);
    var shape: StackShape = .{ .reserved = high - low };
    var addr = low;
    while (addr < high) {
        var mbi: win.MEMORY_BASIC_INFORMATION = undefined;
        if (win.VirtualQuery(@ptrFromInt(addr), &mbi, @sizeOf(win.MEMORY_BASIC_INFORMATION)) == 0) break;
        const end = @min(@intFromPtr(mbi.BaseAddress) + mbi.RegionSize, high);
        if (mbi.State == win.MEM_COMMIT) shape.committed += end - addr;
        addr = end;
    }
    return shape;
}

fn measureSpawned(cfg: std.Thread.SpawnConfig) !StackShape {
    var shape: StackShape = .{};
    const t = try std.Thread.spawn(cfg, struct {
        fn run(out: *StackShape) void {
            out.* = measureOwnStack();
        }
    }.run, .{&shape});
    t.join();
    return shape;
}

test "windows: config commits a small stack but keeps the 16 MB reserve" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const mb = 1024 * 1024;

    // Positive control: the std default really does commit ~16 MB, so the
    // measurement can see the cost this module exists to remove.
    const old = try measureSpawned(.{});
    try std.testing.expect(old.committed >= 15 * mb);

    const new = try measureSpawned(config);
    // Depth is unchanged: the reserve is still the PE header's 16 MB.
    try std.testing.expect(new.reserved >= 16 * mb);
    // And almost none of it is paid for up front.
    try std.testing.expect(new.committed <= mb);
}

test "windows: a deep frame still grows into the reserve" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Deep = struct {
        // ~4 MB of stack across 64 frames of 64 KB, far past the commit hint.
        fn recurse(depth: u32) u32 {
            var buf: [64 * 1024]u8 = undefined;
            buf[0] = @truncate(depth);
            std.mem.doNotOptimizeAway(&buf);
            if (depth == 0) return buf[0];
            return recurse(depth - 1) +% buf[0];
        }
        fn run(out: *StackShape) void {
            _ = recurse(64);
            out.* = measureOwnStack();
        }
    };
    var shape: StackShape = .{};
    const t = try spawn(Deep.run, .{&shape});
    t.join();
    try std.testing.expect(shape.committed >= 4 * 1024 * 1024);
}

/// Stack shape of one worker of a pool made with `opts`, measured on that
/// worker while the pool is alive.
fn measurePoolWorker(opts: std.Thread.Pool.Options) !StackShape {
    var pool: std.Thread.Pool = undefined;
    try pool.init(opts);
    defer pool.deinit();
    var shape: StackShape = .{};
    var wg: std.Thread.WaitGroup = .{};
    pool.spawnWg(&wg, struct {
        fn run(out: *StackShape) void {
            out.* = measureOwnStack();
        }
    }.run, .{&shape});
    wg.wait();
    return shape;
}

test "windows: poolOptions gives pool workers the small commit too (T3095)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const mb = 1024 * 1024;
    const alloc = std.testing.allocator;

    // Positive control: a pool made with std's options commits ~16 MB per
    // worker - the cost sheet_workers' pool carried for the life of the app.
    const old = try measurePoolWorker(.{ .allocator = alloc, .n_jobs = 1 });
    try std.testing.expect(old.committed >= 15 * mb);

    const new = try measurePoolWorker(poolOptions(alloc, 1));
    try std.testing.expect(new.reserved >= 16 * mb);
    try std.testing.expect(new.committed <= mb);
}

test "poolOptions carries config's stack size and the caller's job count" {
    const opts = poolOptions(std.testing.allocator, 3);
    try std.testing.expectEqual(config.stack_size, opts.stack_size);
    try std.testing.expectEqual(@as(?usize, 3), opts.n_jobs);
}

test "config is the std default off Windows" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expectEqual(std_default_stack_size, config.stack_size);
}
