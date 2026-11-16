//! The dial behind one `+new-remote-window` request, carried OFF the GUI
//! thread (T3022).
//!
//! The verb used to dial the remote agent inside its GUI-thread handler: DNS,
//! then a TCP connect with no bound of its own (about 21 s on Windows against a
//! black-holed address), then up to 10 s of HELLO. For all of that every window
//! was frozen and every other IPC verb sat queued behind it.
//!
//! The verb is now three hops, and only the outer two touch the GUI thread:
//!
//!   1. GUI thread — the handler validates the flags and resolves the relay
//!      token exactly as before (every refusal it can make, it still makes
//!      before any dial), then hands the listener a `Job` instead of a reply.
//!   2. A worker thread — dials (`dial` below is supplied by the caller) and
//!      records the outcome. The listener that owns the client's connection
//!      waits for it; the GUI thread keeps pumping.
//!   3. GUI thread — the listener posts the job back, and the window is opened
//!      through the one shared open tail, or the failure is answered in the
//!      same words it always was.
//!
//! The reply therefore still goes out only once the window exists, so a script
//! that runs `+list` after the verb sees the window, as before.
//!
//! ## Lifetime
//!
//! Two parties hold a job — the listener and the dial worker — and each drops
//! its reference with `release`; the last one frees it, including a transport
//! nobody adopted. That is what lets the listener give up on a dial during
//! quit (it must not hold the app's shutdown for the connect timeout) without
//! the worker writing into freed memory when its dial finally returns.
//!
//! Generic over the transport so the none lane can test the lifetime with a
//! fake one; the win32 build instantiates it with `Window.RemoteDialed`. No OS
//! imports.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const dial_failure = @import("dial_failure.zig");

/// Which machine to dial. Strings are owned by the job.
pub const Target = union(enum) {
    tcp: struct { host: []const u8, port: u16 },
    relay: struct { base: []const u8, device: []const u8, token: []const u8 },
};

/// The window options the open tail needs. Strings owned by the job; null is
/// absent.
pub const Options = struct {
    working_directory: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    command: ?[]const u8 = null,
    name: ?[]const u8 = null,
    title: ?[]const u8 = null,
    activate: bool = false,
};

pub const Outcome = enum {
    /// The dial has not come back yet.
    pending,
    connected,
    /// Did not answer (or a rejected bearer: the token was resolved before the
    /// dial, so the CLI has only the one sentence for both, as before).
    unreachable_machine,
    /// Answered, and disagrees about the protocol.
    incompatible,
};

pub fn outcomeFor(err: anyerror) Outcome {
    return switch (dial_failure.classify(err)) {
        .incompatible => .incompatible,
        .unreachable_machine, .unauthorized => .unreachable_machine,
    };
}

pub fn Job(comptime Transport: type) type {
    return struct {
        const Self = @This();

        alloc: Allocator,
        target: Target,
        options: Options,

        /// The listener's and the worker's references.
        refs: std.atomic.Value(u8) = .{ .raw = 2 },
        /// Set by the worker once `outcome`/`transport` are final.
        done: std.Thread.ResetEvent = .{},
        outcome: Outcome = .pending,
        /// The connection, until the GUI thread adopts it (sets it null).
        /// Freed with the job when nobody did.
        transport: ?Transport = null,

        /// Copy every borrowed string, so the job outlives the request that
        /// built it. On allocation failure nothing is leaked.
        pub fn create(alloc: Allocator, target: Target, options: Options) Allocator.Error!*Self {
            var arena: std.ArrayList([]const u8) = .empty;
            defer arena.deinit(alloc);
            errdefer for (arena.items) |s| alloc.free(s);

            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            const owned_target: Target = switch (target) {
                .tcp => |t| .{ .tcp = .{
                    .host = try dupeTracked(alloc, &arena, t.host),
                    .port = t.port,
                } },
                .relay => |r| .{ .relay = .{
                    .base = try dupeTracked(alloc, &arena, r.base),
                    .device = try dupeTracked(alloc, &arena, r.device),
                    .token = try dupeTracked(alloc, &arena, r.token),
                } },
            };
            const owned_options: Options = .{
                .working_directory = try dupeOptTracked(alloc, &arena, options.working_directory),
                .shell = try dupeOptTracked(alloc, &arena, options.shell),
                .command = try dupeOptTracked(alloc, &arena, options.command),
                .name = try dupeOptTracked(alloc, &arena, options.name),
                .title = try dupeOptTracked(alloc, &arena, options.title),
                .activate = options.activate,
            };
            self.* = .{ .alloc = alloc, .target = owned_target, .options = owned_options };
            return self;
        }

        /// Worker side: record the dial's result and wake the listener.
        /// Exactly once per job.
        pub fn finish(self: *Self, result: anyerror!Transport) void {
            if (result) |t| {
                self.transport = t;
                self.outcome = .connected;
            } else |err| {
                self.outcome = outcomeFor(err);
            }
            self.done.set();
        }

        /// GUI side: take the connection. The caller owns it from here on.
        pub fn adopt(self: *Self) ?Transport {
            const t = self.transport;
            self.transport = null;
            return t;
        }

        /// Drop one reference; the last one frees the job and any transport
        /// still in it.
        pub fn release(self: *Self) void {
            if (self.refs.fetchSub(1, .acq_rel) != 1) return;
            const alloc = self.alloc;
            if (self.transport) |t| t.deinitDestroy(alloc);
            switch (self.target) {
                .tcp => |t| alloc.free(t.host),
                .relay => |r| {
                    alloc.free(r.base);
                    alloc.free(r.device);
                    alloc.free(r.token);
                },
            }
            inline for (.{ "working_directory", "shell", "command", "name", "title" }) |f| {
                if (@field(self.options, f)) |s| alloc.free(s);
            }
            alloc.destroy(self);
        }
    };
}

fn dupeTracked(alloc: Allocator, list: *std.ArrayList([]const u8), s: []const u8) Allocator.Error![]const u8 {
    try list.ensureUnusedCapacity(alloc, 1);
    const d = try alloc.dupe(u8, s);
    list.appendAssumeCapacity(d);
    return d;
}

fn dupeOptTracked(alloc: Allocator, list: *std.ArrayList([]const u8), s: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (s) |v| try dupeTracked(alloc, list, v) else null;
}

/// The CLI's sentence for a dial that did not connect — byte for byte the ones
/// the GUI-thread handler answered with before T3022 (the acceptance scripts
/// and the Mac server match on them). `buf` must hold the endpoint plus ~80
/// bytes; the result is a slice of it.
pub fn failureMessage(buf: []u8, target: Target, outcome: Outcome) error{NoSpaceLeft}![]const u8 {
    return switch (target) {
        .tcp => |t| switch (outcome) {
            .incompatible => std.fmt.bufPrint(buf, "incompatible Ghoztty version on {s}:{d}: update one side", .{ t.host, t.port }),
            else => std.fmt.bufPrint(buf, "failed to reach {s}:{d}: the agent is not running or not reachable", .{ t.host, t.port }),
        },
        .relay => |r| switch (outcome) {
            .incompatible => std.fmt.bufPrint(buf, "incompatible Ghoztty version on {s} (via relay {s}): update one side", .{ r.device, r.base }),
            else => std.fmt.bufPrint(buf, "failed to reach {s} via relay {s}: the agent is not running or not reachable", .{ r.device, r.base }),
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

const FakeTransport = struct {
    freed: *usize,
    pub fn deinitDestroy(self: FakeTransport, alloc: Allocator) void {
        _ = alloc;
        self.freed.* += 1;
    }
};

test "a job copies its strings, so the request that built it can go away" {
    var host_buf = "example.test".*;
    var name_buf = "remote-a".*;
    const J = Job(FakeTransport);
    const job = try J.create(testing.allocator, .{ .tcp = .{ .host = &host_buf, .port = 7777 } }, .{ .name = &name_buf, .activate = true });
    @memset(&host_buf, 'x');
    @memset(&name_buf, 'x');
    try testing.expectEqualStrings("example.test", job.target.tcp.host);
    try testing.expectEqualStrings("remote-a", job.options.name.?);
    try testing.expect(job.options.activate);
    try testing.expect(job.options.shell == null);
    job.release();
    job.release();
}

test "the last release frees an unadopted transport, and only the last" {
    var freed: usize = 0;
    const J = Job(FakeTransport);
    const job = try J.create(testing.allocator, .{ .relay = .{ .base = "https://r", .device = "dev", .token = "tok" } }, .{});
    job.finish(FakeTransport{ .freed = &freed });
    try testing.expectEqual(Outcome.connected, job.outcome);
    try testing.expect(job.done.isSet());
    // The listener walks away (quit) while the transport is still in the job.
    job.release();
    try testing.expectEqual(@as(usize, 0), freed);
    // The worker's release is the last: the connection nobody adopted is closed.
    job.release();
    try testing.expectEqual(@as(usize, 1), freed);
}

test "an adopted transport is not freed by the job" {
    var freed: usize = 0;
    const J = Job(FakeTransport);
    const job = try J.create(testing.allocator, .{ .tcp = .{ .host = "h", .port = 1 } }, .{});
    job.finish(FakeTransport{ .freed = &freed });
    const t = job.adopt();
    try testing.expect(t != null);
    try testing.expect(job.adopt() == null);
    job.release();
    job.release();
    try testing.expectEqual(@as(usize, 0), freed);
}

test "a failed dial records the outcome the CLI answers with" {
    const J = Job(FakeTransport);
    const job = try J.create(testing.allocator, .{ .tcp = .{ .host = "h", .port = 1 } }, .{});
    defer {
        job.release();
        job.release();
    }
    job.finish(error.ProtocolIncompatible);
    try testing.expectEqual(Outcome.incompatible, job.outcome);
    try testing.expect(job.transport == null);

    try testing.expectEqual(Outcome.unreachable_machine, outcomeFor(error.ConnectionTimedOut));
    try testing.expectEqual(Outcome.unreachable_machine, outcomeFor(error.HandshakeTimeout));
    // A rejected bearer has no sentence of its own on the CLI.
    try testing.expectEqual(Outcome.unreachable_machine, outcomeFor(error.WebSocketUnauthorized));
}

test "create leaks nothing when an allocation fails part way" {
    // Every allocation index in turn, through the relay shape (the most strings).
    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const J = Job(FakeTransport);
        if (J.create(failing.allocator(), .{ .relay = .{ .base = "b", .device = "d", .token = "t" } }, .{
            .working_directory = "w",
            .shell = "s",
            .command = "c",
            .name = "n",
            .title = "t",
        })) |job| {
            job.release();
            job.release();
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
}

test "failure messages are byte-identical to the pre-T3022 handler's" {
    var buf: [512]u8 = undefined;
    const tcp: Target = .{ .tcp = .{ .host = "10.255.255.1", .port = 7777 } };
    try testing.expectEqualStrings(
        "failed to reach 10.255.255.1:7777: the agent is not running or not reachable",
        try failureMessage(&buf, tcp, .unreachable_machine),
    );
    try testing.expectEqualStrings(
        "incompatible Ghoztty version on 10.255.255.1:7777: update one side",
        try failureMessage(&buf, tcp, .incompatible),
    );
    const relay: Target = .{ .relay = .{ .base = "https://relay.test", .device = "box", .token = "t" } };
    try testing.expectEqualStrings(
        "failed to reach box via relay https://relay.test: the agent is not running or not reachable",
        try failureMessage(&buf, relay, .unreachable_machine),
    );
    try testing.expectEqualStrings(
        "incompatible Ghoztty version on box (via relay https://relay.test): update one side",
        try failureMessage(&buf, relay, .incompatible),
    );
}
