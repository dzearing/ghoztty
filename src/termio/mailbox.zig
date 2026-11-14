const std = @import("std");
const Allocator = std.mem.Allocator;
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;

const log = std.log.scoped(.io_writer);

/// A queue used for storing messages that is periodically drained.
/// Typically used by a multi-threaded application. The capacity is
/// hardcoded to a value that empirically has made sense for Ghostty usage
/// but I'm open to changing it with good arguments.
const Queue = BlockingQueue(termio.Message, 64);

/// Where the thread that DRAINS the mailbox puts messages it sends to
/// itself once the queue is full.
///
/// A remote backend parses output on the IO thread, and the parse sends
/// messages to that same thread's mailbox: a reply to every query (DA1,
/// DECRQM, a color report), a timer for every synchronized-output start.
/// Nothing drains the queue until the parse returns, so a burst of them
/// filled it, and every one past the 64th cost `send` a 50 ms wait for a
/// drain that could not happen and was then dropped — a pane frozen for
/// seconds, its replies lost and its input unread, for a kilobyte of
/// queries.
///
/// The consumer cannot wait on itself, so it does not: its overflow goes
/// here, unbounded but for what one parse slice can produce, and is handled
/// after the queue on the next drain. Only the consumer thread touches the
/// list, so it needs no lock.
const Overflow = struct {
    alloc: Allocator,

    /// The thread that drains the mailbox (`claim`), 0 until it starts.
    consumer: std.atomic.Value(usize) = .init(0),

    /// Messages in send order; `head` is the next to hand out.
    list: std.ArrayList(termio.Message) = .empty,
    head: usize = 0,

    fn threadId() usize {
        // Thread ids are never 0 on the platforms we run on, and 0 is "no
        // consumer yet"; fold the id so a wider type still fits.
        const id: u64 = @intCast(std.Thread.getCurrentId());
        return @truncate(id | (@as(u64, 1) << 63));
    }

    fn isConsumer(self: *const Overflow) bool {
        return self.consumer.load(.monotonic) == threadId();
    }

    fn pending(self: *const Overflow) bool {
        return self.head < self.list.items.len;
    }

    fn push(self: *Overflow, msg: termio.Message) Allocator.Error!void {
        try self.list.append(self.alloc, msg);
    }

    fn pop(self: *Overflow) ?termio.Message {
        if (!self.pending()) return null;
        const msg = self.list.items[self.head];
        self.head += 1;
        if (self.head == self.list.items.len) {
            self.list.clearRetainingCapacity();
            self.head = 0;
        }
        return msg;
    }
};

/// The location to where write-related messages are sent.
pub const Mailbox = union(enum) {
    // /// Write messages to an unbounded list backed by an allocator.
    // /// This is useful for single-threaded applications where you're not
    // /// afraid of running out of memory. You should be careful that you're
    // /// processing this in a timely manner though since some heavy workloads
    // /// will produce a LOT of messages.
    // ///
    // /// At the time of authoring this, the primary use case for this is
    // /// testing more than anything, but it probably will have a use case
    // /// in libghostty eventually.
    // unbounded: std.ArrayList(termio.Message),

    /// Write messages to a SPSC queue for multi-threaded applications.
    spsc: struct {
        queue: *Queue,
        wakeup: xev.Async,

        /// See `Overflow`. Heap-allocated so every copy of this mailbox
        /// reaches the same one.
        overflow: *Overflow,
    },

    /// Init the SPSC writer.
    pub fn initSPSC(alloc: Allocator) !Mailbox {
        var queue = try Queue.create(alloc);
        errdefer queue.destroy(alloc);

        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();

        const overflow = try alloc.create(Overflow);
        errdefer alloc.destroy(overflow);
        overflow.* = .{ .alloc = alloc };

        return .{ .spsc = .{ .queue = queue, .wakeup = wakeup, .overflow = overflow } };
    }

    /// Called by the thread that drains this mailbox, as it starts: from
    /// here on, what that thread sends to itself can never block or be
    /// dropped for want of room (`Overflow`).
    pub fn claim(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.overflow.consumer.store(Overflow.threadId(), .monotonic),
        }
    }

    /// The next message to handle: the queue first, then whatever the
    /// consumer sent itself while the queue was full. Consumer thread only.
    pub fn next(self: *Mailbox) ?termio.Message {
        switch (self.*) {
            .spsc => |*v| {
                if (v.queue.pop()) |msg| return msg;
                return v.overflow.pop();
            },
        }
    }

    pub fn deinit(self: *Mailbox, alloc: Allocator) void {
        switch (self.*) {
            .spsc => |*v| {
                v.queue.destroy(alloc);
                v.wakeup.deinit();
                v.overflow.list.deinit(alloc);
                alloc.destroy(v.overflow);
            },
        }
    }

    /// Close the mailbox: all future (and currently blocked) sends drop
    /// their message instead of waiting for space. Called at surface
    /// teardown BEFORE joining the IO thread, because after the IO thread
    /// is asked to stop nobody will ever drain this queue again — a
    /// producer parked in `send`'s slow path would otherwise deadlock the
    /// joining (GUI) thread forever.
    pub fn close(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.queue.close(),
        }
    }

    /// Sends the given message without notifying there are messages.
    ///
    /// If the optional mutex is given, it must already be LOCKED. If the
    /// send would block, we'll unlock this mutex, resend the message, and
    /// lock it again. This handles an edge case where queues are full.
    /// This may not apply to all writer types.
    pub fn send(
        self: *Mailbox,
        msg: termio.Message,
        mutex: ?*std.Thread.Mutex,
    ) void {
        switch (self.*) {
            .spsc => |*mb| send: {
                // The thread that drains this mailbox, sending to itself:
                // it never waits (there is nobody else to make room) and
                // never drops. Once it has overflowed, everything it sends
                // follows the same way until that is drained, to keep its
                // messages in order.
                const consumer = mb.overflow.isConsumer();
                if (consumer and mb.overflow.pending()) {
                    self.sendOverflow(msg);
                    return;
                }

                // Try to write to the queue with an instant timeout. This is the
                // fast path because we can queue without a lock.
                if (mb.queue.push(msg, .{ .instant = {} }) > 0) break :send;

                if (consumer) {
                    self.sendOverflow(msg);
                    return;
                }

                // If we enter this conditional, the queue is full. We wake up
                // the writer thread so that it can process messages to clear up
                // space. However, the writer thread may require the renderer
                // lock so we need to unlock.
                mb.wakeup.notify() catch |err| {
                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    return;
                };

                // Unlock the renderer state so the writer thread can acquire it.
                // Then try to queue our message before continuing. This is a very
                // slow path because we are having a lot of contention for data.
                // But this only gets triggered in certain pathological cases.
                //
                // Note that writes themselves don't require a lock, but there
                // are other messages in the writer queue (resize, focus) that
                // could acquire the lock. This is why we have to release our lock
                // here.
                if (mutex) |m| m.unlock();
                defer if (mutex) |m| m.lock();

                // Bounded timed retries, NEVER a forever wait. Two callers
                // can reach this with a full queue and no hope of a drain:
                // (1) the IO thread itself, when stream processing generates
                // replies (remote backends parse output ON the IO thread, so
                // producer == consumer and waiting can never succeed), and
                // (2) any producer during teardown, after the IO thread has
                // stopped draining. A forever wait wedges that thread — and
                // wedges the GUI thread when Surface.deinit later joins it.
                // Dropping a message after ~50ms of a full queue is strictly
                // better than deadlocking the app; it's also loud so we can
                // find pathological floods.
                var attempts: usize = 0;
                while (attempts < 5) : (attempts += 1) {
                    if (mb.queue.push(msg, .{ .ns = 10 * std.time.ns_per_ms }) > 0) return;
                    if (mb.queue.isClosed()) return;
                }
                log.warn("termio mailbox full for 50ms, dropping message={s}", .{@tagName(msg)});
            },
        }
    }

    /// Put a message the consumer sent itself on its overflow list, and
    /// make sure it wakes to handle it.
    fn sendOverflow(self: *Mailbox, msg: termio.Message) void {
        switch (self.*) {
            .spsc => |*mb| {
                mb.overflow.push(msg) catch {
                    log.warn("termio mailbox overflow out of memory, dropping message={s}", .{@tagName(msg)});
                    return;
                };
                mb.wakeup.notify() catch |err|
                    log.warn("failed to wake up writer err={}", .{err});
            },
        }
    }

    /// True when the queue is at least half full, or the consumer has
    /// overflowed it (consumer thread only for that part). The remote backend parses
    /// output ON the IO thread that also drains this mailbox, so replies the
    /// parse generates (DA1, DECRQM, kitty `CSI ? u`, color reports, the
    /// synchronized-output timer …) can only be delivered once it returns to its
    /// loop; if it keeps parsing past a full queue, `send` waits 50 ms per message
    /// and then DROPS it — measured at ~3,600 drops (~3 min of a frozen pane) for
    /// one replay of a 2 MB Claude Code ring. Checking this between small slices
    /// lets that drain yield first.
    pub fn underPressure(self: *Mailbox) bool {
        return switch (self.*) {
            .spsc => |*v| v.queue.count() * 2 >= Queue.max_len or
                (v.overflow.isConsumer() and v.overflow.pending()),
        };
    }

    pub fn notify(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.wakeup.notify() catch |err| {
                log.warn("failed to notify writer, data will be dropped err={}", .{err});
            },
        }
    }
};

test "the consumer sending to its own full mailbox neither waits nor drops" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var mailbox = try Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);
    mailbox.claim();

    // Far more than the queue holds, from the thread that drains it: a
    // burst of queries in one slice of output. Tagged so order is visible.
    const total = Queue.max_len * 8;
    var timer = try std.time.Timer.start();
    for (0..total) |i| {
        mailbox.send(.{ .inspector = i % 3 == 0 }, null);
    }
    // Every message past the queue used to cost 50 ms and then be dropped.
    try testing.expect(timer.read() < 40 * std.time.ns_per_ms);
    try testing.expect(mailbox.underPressure());

    // All of them come back, in the order they were sent.
    var seen: usize = 0;
    while (mailbox.next()) |msg| : (seen += 1) {
        try testing.expectEqual(seen % 3 == 0, msg.inspector);
    }
    try testing.expectEqual(@as(usize, total), seen);
    try testing.expect(!mailbox.underPressure());

    // And with the overflow drained, sends go to the queue again.
    mailbox.send(.{ .inspector = true }, null);
    try testing.expectEqual(@as(Queue.Size, 1), mailbox.spsc.queue.count());
    _ = mailbox.next();
}

test "another thread sending to a full mailbox still gives up rather than block forever" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var mailbox = try Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);
    // No claim: this thread is a producer, not the consumer.
    for (0..Queue.max_len + 1) |_| mailbox.send(.{ .inspector = true }, null);
    var seen: usize = 0;
    while (mailbox.next()) |_| seen += 1;
    try testing.expectEqual(@as(usize, Queue.max_len), seen);
}

