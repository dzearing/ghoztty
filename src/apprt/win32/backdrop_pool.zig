//! A recycling allocator for the glass backdrop slices a window hands its
//! terminals (T2946).
//!
//! A glide re-lays every moved pane on every tick, and each one is sent a new
//! slice of the desk (`Surface.setPaneBackdrop`): a fresh buffer of up to a
//! megabyte or so at 4K, which the renderer thread frees once it has copied it.
//! Fresh memory is page faults: at ~1.6 us a page the widest pane's slice cost
//! ~0.45 ms of the UI thread's frame, and a fold's tick sends several. This
//! allocator keeps a few freed buffers and hands them back out, so a slice
//! after the first lands in memory that is already mapped.
//!
//! Thread-safe (the UI thread allocates, the renderer threads free) and
//! process-lifetime, so a buffer freed after its surface is gone still has a
//! pool to go back to. Buffers are never zeroed: every slice writer fills
//! every byte it was given.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// The pool's state; one per process (`allocator()`), and one per test.
pub const Pool = struct {
    const max_free = 6;
    const max_live = 32;
    /// A spare buffer this big or bigger is not kept (a 4K slice is ~1.3 MB).
    const max_keep: usize = 8 << 20;

    const Block = struct { ptr: [*]u8, cap: usize };

    backing: Allocator = std.heap.page_allocator,
    mutex: std.Thread.Mutex = .{},
    free_list: [max_free]Block = undefined,
    free_len: usize = 0,
    live: [max_live]Block = undefined,
    live_len: usize = 0,
    /// Allocations served from a kept buffer, and from the backing allocator.
    reused: usize = 0,
    fresh: usize = 0,

    pub fn allocator(self: *Pool) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = Allocator.noResize,
        .remap = Allocator.noRemap,
        .free = free,
    };

    /// What a request of `n` bytes is given: a quarter more, so a slice that
    /// grows a little on the next tick still fits the buffer it is given back.
    fn capFor(n: usize) usize {
        return std.mem.alignForward(usize, n + n / 4, std.heap.page_size_min);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Pool = @ptrCast(@alignCast(ctx));
        if (alignment.toByteUnits() > std.heap.page_size_min) return self.backing.rawAlloc(len, alignment, ret_addr);
        self.mutex.lock();
        defer self.mutex.unlock();
        // The smallest kept buffer that holds it, and is not more than twice
        // its size: a narrow pane's slice does not tie up the widest one's.
        var best: ?usize = null;
        for (self.free_list[0..self.free_len], 0..) |b, i| {
            if (b.cap < len or b.cap > 2 * len + std.heap.page_size_min) continue;
            if (best == null or b.cap < self.free_list[best.?].cap) best = i;
        }
        const block: Block = if (best) |i| blk: {
            const b = self.free_list[i];
            self.free_len -= 1;
            self.free_list[i] = self.free_list[self.free_len];
            self.reused += 1;
            break :blk b;
        } else blk: {
            if (self.live_len == max_live) {
                // Untracked, at its exact size: `free` hands it straight back.
                self.fresh += 1;
                return self.backing.rawAlloc(len, alignment, ret_addr);
            }
            const cap = capFor(len);
            const p = self.backing.rawAlloc(cap, alignment, ret_addr) orelse return null;
            self.fresh += 1;
            break :blk .{ .ptr = p, .cap = cap };
        };
        if (self.live_len == max_live) {
            // A kept buffer, but nowhere to note its size: give it up.
            self.backing.rawFree(block.ptr[0..block.cap], alignment, ret_addr);
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }
        self.live[self.live_len] = block;
        self.live_len += 1;
        return block.ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *Pool = @ptrCast(@alignCast(ctx));
        if (alignment.toByteUnits() > std.heap.page_size_min) return self.backing.rawFree(memory, alignment, ret_addr);
        self.mutex.lock();
        defer self.mutex.unlock();
        const i = for (self.live[0..self.live_len], 0..) |b, i| {
            if (b.ptr == memory.ptr) break i;
        } else return self.backing.rawFree(memory, alignment, ret_addr);
        const block = self.live[i];
        self.live_len -= 1;
        self.live[i] = self.live[self.live_len];
        if (self.free_len < max_free and block.cap <= max_keep) {
            self.free_list[self.free_len] = block;
            self.free_len += 1;
            return;
        }
        // Full: the smallest kept buffer makes way for a bigger one.
        var smallest: usize = 0;
        for (self.free_list[0..self.free_len], 0..) |b, k| {
            if (b.cap < self.free_list[smallest].cap) smallest = k;
        }
        if (self.free_len > 0 and block.cap <= max_keep and self.free_list[smallest].cap < block.cap) {
            const out = self.free_list[smallest];
            self.free_list[smallest] = block;
            self.backing.rawFree(out.ptr[0..out.cap], alignment, ret_addr);
            return;
        }
        self.backing.rawFree(block.ptr[0..block.cap], alignment, ret_addr);
    }

    /// Give every kept buffer back (tests; the process pool lives forever).
    pub fn deinit(self: *Pool) void {
        for (self.free_list[0..self.free_len]) |b| self.backing.rawFree(b.ptr[0..b.cap], .@"1", @returnAddress());
        self.free_len = 0;
    }
};

var global: Pool = .{};

/// The process's pool, as an allocator.
pub fn allocator() Allocator {
    return global.allocator();
}

const testing = std.testing;

test "T2946: a freed slice's buffer is handed out again, for the same or a slightly bigger slice" {
    var pool: Pool = .{ .backing = testing.allocator };
    defer pool.deinit();
    const a = pool.allocator();
    const one = try a.alloc(u8, 100_000);
    @memset(one, 7);
    const p = one.ptr;
    a.free(one);
    const two = try a.alloc(u8, 110_000);
    try testing.expectEqual(p, two.ptr);
    try testing.expectEqual(@as(usize, 1), pool.reused);
    a.free(two);
    // A much smaller slice does not take the big buffer.
    const small = try a.alloc(u8, 4_000);
    try testing.expect(small.ptr != p);
    a.free(small);
}

test "T2946: two live slices never share a buffer, and the pool keeps a bounded few" {
    var pool: Pool = .{ .backing = testing.allocator };
    defer pool.deinit();
    const a = pool.allocator();
    var bufs: [10][]u8 = undefined;
    for (&bufs, 0..) |*b, i| {
        b.* = try a.alloc(u8, 50_000 + i);
        @memset(b.*, @intCast(i));
    }
    for (bufs, 0..) |b, i| {
        for (bufs[i + 1 ..]) |o| try testing.expect(b.ptr != o.ptr);
        try testing.expect(std.mem.allEqual(u8, b, @intCast(i)));
    }
    for (bufs) |b| a.free(b);
    try testing.expect(pool.free_len <= Pool.max_free);
    try testing.expectEqual(@as(usize, 0), pool.live_len);
}

test "T2946: past the live table an allocation is untracked and still freed" {
    var pool: Pool = .{ .backing = testing.allocator };
    defer pool.deinit();
    const a = pool.allocator();
    var bufs: [Pool.max_live + 3][]u8 = undefined;
    for (&bufs) |*b| b.* = try a.alloc(u8, 1000);
    for (bufs) |b| a.free(b);
    try testing.expectEqual(@as(usize, 0), pool.live_len);
}
