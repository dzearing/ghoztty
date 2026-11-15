//! A pool of fixed-size, aligned buffers where every buffer is its own
//! allocation from the child allocator.
//!
//! This exists for Windows (T3003). `std.heap.MemoryPool` carves its items
//! out of an `ArenaAllocator`, which grows each new chunk to 1.5x the
//! previous one. On macOS and Linux the page allocator maps lazily, so an
//! untouched tail of a chunk costs nothing. On Windows the Zig page
//! allocator is `VirtualAlloc(MEM_COMMIT | MEM_RESERVE)`, so every chunk is
//! committed whole the moment it exists: a terminal page pool preheated
//! with 4 standard pages commits ~2.1 MB where one page (~0.4 MB) holds the
//! viewport, and a pane grown to its scrollback limit carries megabytes of
//! commit nothing ever touched.
//!
//! Here each item is exactly one child allocation, so what is committed is
//! exactly what was asked for. The API mirrors the subset of
//! `std.heap.MemoryPoolAligned` that `PageList` uses (`item_size`,
//! `initPreheated`, `create`, `destroy`, `reset`, `deinit`) plus an explicit
//! `child_allocator`, so the two pools are interchangeable at comptime.
//!
//! Unlike the std pool, this one never writes into a free item: the free
//! list is a side array, so an item handed back zeroed comes out of
//! `create` still zeroed. `reset` zeroes every item it retains, because
//! those were live pages a moment ago.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub fn ExactPool(comptime size: usize, comptime alignment: Alignment) type {
    return struct {
        const Pool = @This();

        pub const item_size = size;
        pub const Item = [size]u8;
        pub const ItemPtr = *align(alignment.toByteUnits()) Item;
        pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

        /// Where the items themselves come from (the page allocator).
        child_allocator: Allocator,

        /// Where the bookkeeping arrays come from. Separate from the child
        /// so the page allocator only ever sees whole items.
        meta_allocator: Allocator,

        /// Every item this pool owns, live or free.
        all: std.ArrayListUnmanaged(ItemPtr) = .empty,

        /// Items available for `create`. Its capacity is kept at least
        /// `all.items.len`, so `destroy` can push without allocating and
        /// therefore cannot fail.
        free: std.ArrayListUnmanaged(ItemPtr) = .empty,

        pub fn init(child: Allocator, meta: Allocator) Pool {
            return .{ .child_allocator = child, .meta_allocator = meta };
        }

        pub fn initPreheated(
            child: Allocator,
            meta: Allocator,
            initial_size: usize,
        ) Allocator.Error!Pool {
            var pool = init(child, meta);
            errdefer pool.deinit();
            try pool.preheat(initial_size);
            return pool;
        }

        pub fn deinit(pool: *Pool) void {
            for (pool.all.items) |item| pool.child_allocator.free(item);
            pool.all.deinit(pool.meta_allocator);
            pool.free.deinit(pool.meta_allocator);
            pool.* = undefined;
        }

        pub fn preheat(pool: *Pool, n: usize) Allocator.Error!void {
            for (0..n) |_| {
                const item = try pool.allocNew();
                pool.free.appendAssumeCapacity(item);
            }
        }

        pub fn create(pool: *Pool) Allocator.Error!ItemPtr {
            if (pool.free.pop()) |item| return item;
            return try pool.allocNew();
        }

        pub fn destroy(pool: *Pool, ptr: ItemPtr) void {
            pool.free.appendAssumeCapacity(ptr);
        }

        /// Bytes this pool holds from the child allocator, live and free.
        pub fn committedBytes(pool: *const Pool) usize {
            return pool.all.items.len * item_size;
        }

        /// Give memory back. Every outstanding item is invalidated, as
        /// with the std pool. Retained items are zeroed and become free.
        /// Returns true (the bookkeeping cannot fail to shrink).
        pub fn reset(pool: *Pool, mode: ResetMode) bool {
            const keep: usize = switch (mode) {
                .free_all => 0,
                .retain_capacity => pool.all.items.len,
                .retain_with_limit => |limit| @min(
                    pool.all.items.len,
                    limit / item_size,
                ),
            };

            for (pool.all.items[keep..]) |item| pool.child_allocator.free(item);
            pool.all.shrinkRetainingCapacity(keep);

            pool.free.clearRetainingCapacity();
            for (pool.all.items) |item| {
                @memset(item, 0);
                pool.free.appendAssumeCapacity(item);
            }
            return true;
        }

        /// One new item, recorded in `all`, with `free` sized so the
        /// matching `destroy` cannot fail. Not put on the free list.
        fn allocNew(pool: *Pool) Allocator.Error!ItemPtr {
            try pool.all.ensureUnusedCapacity(pool.meta_allocator, 1);
            try pool.free.ensureTotalCapacity(
                pool.meta_allocator,
                pool.all.items.len + 1,
            );
            const buf = try pool.child_allocator.alignedAlloc(
                u8,
                alignment,
                item_size,
            );
            const item: ItemPtr = buf[0..item_size];
            pool.all.appendAssumeCapacity(item);
            return item;
        }
    };
}

const testing = std.testing;
const TestPool = ExactPool(3 * std.heap.page_size_min, .fromByteUnits(std.heap.page_size_min));

test "ExactPool commits exactly what is preheated" {
    var pool = try TestPool.initPreheated(testing.allocator, testing.allocator, 1);
    defer pool.deinit();
    try testing.expectEqual(TestPool.item_size, pool.committedBytes());

    // The preheated item is handed out first; only the second allocates.
    _ = try pool.create();
    try testing.expectEqual(TestPool.item_size, pool.committedBytes());
    _ = try pool.create();
    try testing.expectEqual(2 * TestPool.item_size, pool.committedBytes());
}

test "ExactPool grows one item at a time" {
    var pool = TestPool.init(testing.allocator, testing.allocator);
    defer pool.deinit();
    for (1..20) |n| {
        _ = try pool.create();
        // The arena-backed std pool is ahead of this by up to half again.
        try testing.expectEqual(n * TestPool.item_size, pool.committedBytes());
    }
}

test "ExactPool reuses destroyed items and never writes into them" {
    var pool = TestPool.init(testing.allocator, testing.allocator);
    defer pool.deinit();
    const a = try pool.create();
    @memset(a, 0);
    pool.destroy(a);
    const b = try pool.create();
    try testing.expectEqual(a, b);
    try testing.expectEqual(TestPool.item_size, pool.committedBytes());
    for (b) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "ExactPool alignment" {
    var pool = TestPool.init(testing.allocator, testing.allocator);
    defer pool.deinit();
    const a = try pool.create();
    try testing.expect(@intFromPtr(a) % std.heap.page_size_min == 0);
}

test "ExactPool reset retain_with_limit keeps the limit and zeroes it" {
    var pool = TestPool.init(testing.allocator, testing.allocator);
    defer pool.deinit();
    for (0..5) |_| {
        const p = try pool.create();
        @memset(p, 0xAB);
    }
    _ = pool.reset(.{ .retain_with_limit = 2 * TestPool.item_size });
    try testing.expectEqual(2 * TestPool.item_size, pool.committedBytes());

    // Both retained items come back zeroed and without new allocation.
    for (0..2) |_| {
        const p = try pool.create();
        for (p) |byte| try testing.expectEqual(@as(u8, 0), byte);
    }
    try testing.expectEqual(2 * TestPool.item_size, pool.committedBytes());
}

test "ExactPool reset free_all and retain_capacity" {
    var pool = TestPool.init(testing.allocator, testing.allocator);
    defer pool.deinit();
    for (0..3) |_| _ = try pool.create();
    _ = pool.reset(.retain_capacity);
    try testing.expectEqual(3 * TestPool.item_size, pool.committedBytes());
    _ = pool.reset(.free_all);
    try testing.expectEqual(@as(usize, 0), pool.committedBytes());
    _ = try pool.create();
    try testing.expectEqual(TestPool.item_size, pool.committedBytes());
}

test "ExactPool create failure leaves the pool consistent" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var pool = TestPool.init(failing.allocator(), testing.allocator);
    defer pool.deinit();
    _ = try pool.create();
    try testing.expectError(error.OutOfMemory, pool.create());
    try testing.expectEqual(TestPool.item_size, pool.committedBytes());
}
