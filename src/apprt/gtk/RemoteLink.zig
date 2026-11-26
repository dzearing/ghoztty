//! Cross-machine windows on Linux (T3597, Linux L8d-3): the connection a
//! `+new-remote-window` window's panes ride, and the machine it reaches, so
//! a split of one of them and `+new-window --from-focused` land on the SAME
//! machine. Win32's `Window.RemoteDialed` / `Window.RemoteMachine` and the
//! Mac's `Machine`, translated to the GTK object model.
//!
//! The difference from win32 is ownership. A win32 window owns its dial; a
//! GTK pane can leave its window (a drag, `+rearrange`), so here the PANES
//! hold the link: every pane riding it takes a reference, and when the last
//! one is finalized - after its core surface sent the agent its CLOSE or
//! DETACH - the connection is shut down off the GTK thread (win32's T229
//! rule; `LocalAgent.retire` is the same shape). The link itself is never
//! freed before the app exits: core surfaces borrow `*Connection` with no
//! refcount of their own, exactly the reason `LocalAgent` keeps its retired
//! connections.
//!
//! GTK main thread only, except `shutdownRetired`, which runs on its own
//! thread over a link nothing can reach any more.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tcp_dial = @import("../../remote/tcp_dial.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const connection = @import("../../remote/connection.zig");
const host_defaults = @import("../win32/host_defaults.zig");
const policy = @import("../win32/remote_reconnect.zig");
const List = @import("../ipc/list.zig").List;

const log = std.log.scoped(.gtk_remote);

const alloc = std.heap.c_allocator;

/// The two transports a remote window can ride: a direct TCP dial to the
/// agent or a rendezvous-relay WebSocket. Both own their connection; this
/// union only dispatches teardown (win32 `Window.RemoteDialed`).
pub const Dialed = union(enum) {
    tcp: *tcp_dial.Dialed,
    relay: *relay_dial.Dialed,

    /// Tear down the transport and free the heap-owned Dialed. The dial
    /// job (`ipc_remote_dial.Job`) calls this on a dial nobody adopted.
    pub fn deinitDestroy(self: Dialed, a: Allocator) void {
        switch (self) {
            inline else => |d| {
                d.deinit();
                a.destroy(d);
            },
        }
    }

    pub fn conn(self: Dialed) *connection.Connection {
        return switch (self) {
            inline else => |d| d.conn,
        };
    }
};

/// How a remote window's agent was reached, so "New Window" from it can dial
/// the same machine again (win32 `Window.RemoteMachine`, T68). Owned by the
/// link once `adopt` copied it.
pub const Machine = union(enum) {
    tcp: struct { host: []const u8, port: u16 },
    relay: struct {
        base: []const u8,
        device: []const u8,
        token: []const u8,
        /// The caller's `--name`, which wins over the device id as the
        /// machine's name (T1736). Null: the device id.
        name: ?[]const u8 = null,
    },

    /// The machine's name as `+list` reports it (`machine`, T1557): the host
    /// for a direct dial, else the pinned name, else the device id.
    pub fn displayName(self: Machine) []const u8 {
        return switch (self) {
            .tcp => |t| t.host,
            .relay => |r| r.name orelse r.device,
        };
    }

    /// This machine's key in the per-host defaults store (T3669, win32
    /// `RemoteMachine.hostDefaultsKey`, Mac `Machine.settingsKey`): the
    /// relay DEVICE ID (stable across renames), else `host:port`. The same
    /// key Settings > Remote Machines' Host Settings... writes. Borrows.
    pub fn hostDefaultsKey(self: Machine) host_defaults.Key {
        return switch (self) {
            .tcp => |t| .{ .tcp = .{ .host = t.host, .port = t.port } },
            .relay => |r| .{ .relay = r.device },
        };
    }

    /// The machine's stored per-host defaults (T3669). A missing store, row
    /// or usable key leaves both empty, i.e. "the remote's own default".
    pub fn hostDefaults(self: Machine) host_defaults.Resolved {
        var r: host_defaults.Resolved = .{};
        host_defaults.lookup(alloc, self.hostDefaultsKey(), &r);
        return r;
    }

    /// The machine's stored default SHELL alone, as an owned copy on the C
    /// allocator (free with `freeOwned`), or null. What a new tab or split
    /// on the machine takes (T3669): a fresh session on the same machine gets
    /// the per-host shell but NOT the per-host cwd, which would pull it away
    /// from where its parent is (win32 `buildRemoteInherit`, Mac
    /// `BaseTerminalController.newSplit`).
    pub fn hostDefaultShell(self: Machine) ?[]u8 {
        const r = self.hostDefaults();
        const s = r.shell() orelse return null;
        return alloc.dupe(u8, s) catch null;
    }

    fn dupe(self: Machine, a: Allocator) Allocator.Error!Machine {
        switch (self) {
            .tcp => |t| return .{ .tcp = .{ .host = try a.dupe(u8, t.host), .port = t.port } },
            .relay => |r| {
                const base = try a.dupe(u8, r.base);
                errdefer a.free(base);
                const device = try a.dupe(u8, r.device);
                errdefer a.free(device);
                const token = try a.dupe(u8, r.token);
                errdefer a.free(token);
                const name: ?[]const u8 = if (r.name) |n| try a.dupe(u8, n) else null;
                return .{ .relay = .{ .base = base, .device = device, .token = token, .name = name } };
            },
        }
    }
};

/// Free a string `Machine.hostDefaultShell` returned.
pub fn freeOwned(s: []u8) void {
    alloc.free(s);
}

/// The reconnect ladder's live state for one link (T3675, win32
/// `RemoteReconnect.State`). It lives on the LINK, not the window: GTK panes
/// hold the link and can span windows, so one dial has one ladder, and every
/// window showing a pane on it paints the same pill. Driven by
/// `RemoteReconnect.zig`; the decisions are win32's pure `remote_reconnect`.
pub const Reconnect = struct {
    /// What the pill paints and `+list` reports.
    ladder: policy.WindowState = .connected,
    breaker: policy.Breaker = .{},
    /// Cancellation: bumped by everything that invalidates an in-flight dial.
    gen: policy.Generation = .{},
    /// The 1-based fast-ladder attempt being paced or run.
    attempt: u32 = 0,
    /// The ladder now running was started by a click (T611: only then may
    /// "the sessions are gone" be answered with fresh shells).
    manual: bool = false,
    /// Wall-clock ms the next dial is due (0: none scheduled).
    due_ms: i64 = 0,
    /// A worker is dialing right now.
    inflight: bool = false,
    /// The link-state observer is installed on the current transport.
    observed: bool = false,
    /// Transports this link replaced. Shut down, never freed: the panes
    /// they carried borrowed their connection (the module doc's rule).
    replaced: std.ArrayList(Dialed) = .empty,
};

/// One dialed machine and the panes riding it.
pub const Link = struct {
    dialed: Dialed,
    machine: Machine,
    /// Panes holding this link. Starts at 0: the window's first pane takes
    /// the first reference when it is built.
    refs: u32 = 0,
    /// Shut down: the last pane let go. Nothing new may ride it.
    retired: bool = false,
    /// The reconnect ladder (T3675).
    reconnect: Reconnect = .{},

    pub fn conn(self: *const Link) *connection.Connection {
        return self.dialed.conn();
    }

    /// The `+list` connection object for this link (T3675, win32 T609): the
    /// ladder's state, with its attempt, self-healable flag and reason.
    pub fn listConnection(self: *const Link) List.Connection {
        if (self.retired) return .{ .state = "disconnected", .self_healable = false };
        return self.reconnect.ladder.listConnection();
    }

    pub fn ref(self: *Link) void {
        std.debug.assert(!self.retired);
        self.refs += 1;
    }

    /// Drop a pane's reference; the last one shuts the connection down.
    pub fn unref(self: *Link) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs == 0) self.retire();
    }

    /// Shut the connection down off the GTK thread (`shutdown` joins the
    /// connection's threads, and a peer that does not let go promptly would
    /// wedge the app). Idempotent. The memory stays: see the module doc.
    pub fn retire(self: *Link) void {
        if (self.retired) return;
        self.retired = true;
        // The ladder ends with the link: a dial in flight lands stale, and
        // the dying transport's transitions are noise. `clearStateHandler`
        // returns once any running handler has finished.
        _ = self.reconnect.gen.bump();
        self.reconnect.due_ms = 0;
        self.conn().clearStateHandler();
        self.reconnect.observed = false;
        log.info("remote link to {s}: no pane rides it any more; closing it", .{self.machine.displayName()});
        shutdownAsync(self.conn());
    }

    /// Ride `fresh` from now on (T3675's swap): the current transport is
    /// kept, shut down off the GTK thread, and never freed - every pane that
    /// rode it borrowed its connection. The caller moves the panes FIRST
    /// (re-ATTACH before retire, win32's `SwapGuard`).
    pub fn replaceTransport(self: *Link, fresh: Dialed) void {
        const old = self.dialed;
        old.conn().clearStateHandler();
        self.reconnect.observed = false;
        self.reconnect.replaced.append(alloc, old) catch
            log.warn("remote link: a replaced transport could not be tracked; leaking it", .{});
        self.dialed = fresh;
        shutdownAsync(old.conn());
    }
};

/// Shut a connection down on its own thread (`shutdown` joins the
/// connection's threads; a peer that does not let go would wedge the app).
fn shutdownAsync(c: *connection.Connection) void {
    const t = std.Thread.spawn(.{}, shutdownRetired, .{c}) catch |err| {
        log.warn("remote link: async teardown unavailable ({}), shutting down inline", .{err});
        c.shutdown();
        return;
    };
    t.detach();
}

fn shutdownRetired(c: *connection.Connection) void {
    c.shutdown();
}

/// Every link this run dialed, retired ones included (check `retired`): the
/// reconnect driver's pass.
pub fn allLinks() []const *Link {
    return links.items;
}

/// Every link this run dialed, retired or not. Never freed (module doc).
var links: std.ArrayList(*Link) = .empty;

/// Take ownership of a completed dial and the machine it reached (the
/// machine's strings are copied). On allocation failure the dial is torn
/// down, so the caller never owns it past this call.
pub fn adopt(dialed: Dialed, machine: Machine) Allocator.Error!*Link {
    errdefer dialed.deinitDestroy(alloc);
    try links.ensureUnusedCapacity(alloc, 1);
    const link = try alloc.create(Link);
    errdefer alloc.destroy(link);
    link.* = .{ .dialed = dialed, .machine = try machine.dupe(alloc) };
    links.appendAssumeCapacity(link);
    return link;
}

/// What the NEXT `Surface.new` adopts as a remote pane: the link and the
/// REMOTE-native values its OPEN carries. Set by the remote window open right
/// before it builds the window (the `pending_restore` handoff shape), so the
/// window / tab / split paths need no remote parameter. Strings are borrowed
/// for that one call; the surface copies them. GTK main thread only; the
/// surface clears it.
pub const Open = struct {
    link: *Link,
    /// cwd ON THE REMOTE MACHINE, or null for the agent's default.
    working_directory: ?[]const u8 = null,
    /// Shell ON THE REMOTE MACHINE, or null for the agent's default.
    shell: ?[]const u8 = null,
    /// Command to run instead of an interactive shell, or null.
    command: ?[]const u8 = null,
    /// The far agent's session to ATTACH instead of OPENing a new one: a
    /// relay window brought back at launch (T3671, `RelayWindows.zig`).
    session_id: ?[]const u8 = null,
};
pub var pending_open: ?Open = null;

/// Dial `machine` again, on the calling thread (`+new-window --from-focused`
/// re-dials the focused remote window's machine, win32's
/// `openRemoteWindowFrom`). The caller owns the result.
pub fn dial(machine: Machine) !Dialed {
    switch (machine) {
        .tcp => |t| {
            const d = try alloc.create(tcp_dial.Dialed);
            errdefer alloc.destroy(d);
            d.* = try tcp_dial.dial(alloc, t.host, t.port, .raw);
            return .{ .tcp = d };
        },
        .relay => |r| {
            const d = try alloc.create(relay_dial.Dialed);
            errdefer alloc.destroy(d);
            d.* = try relay_dial.dial(alloc, r.base, r.device, r.token, .raw);
            return .{ .relay = d };
        },
    }
}

test "displayName: the host for a direct dial, the pinned name, else the device" {
    const testing = std.testing;
    try testing.expectEqualStrings("10.0.0.5", (Machine{ .tcp = .{ .host = "10.0.0.5", .port = 7777 } }).displayName());
    try testing.expectEqualStrings("box", (Machine{ .relay = .{ .base = "b", .device = "dev-1", .token = "t", .name = "box" } }).displayName());
    try testing.expectEqualStrings("dev-1", (Machine{ .relay = .{ .base = "b", .device = "dev-1", .token = "t" } }).displayName());
}

test "Reconnect: a new link reads connected; the ladder's state is what +list reports" {
    const testing = std.testing;
    var r: Reconnect = .{};
    try testing.expectEqualStrings("connected", r.ladder.listConnection().state);
    r.ladder = .{ .reconnecting = .{ .attempt = 2 } };
    const c = r.ladder.listConnection();
    try testing.expectEqualStrings("reconnecting", c.state);
    try testing.expectEqual(@as(?i64, 2), c.attempt);
    r.ladder = policy.exhausted_state;
    try testing.expectEqual(@as(?bool, true), r.ladder.listConnection().self_healable);
}

test "Machine.dupe copies every string and leaks nothing on failure" {
    const testing = std.testing;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        const a = failing.allocator();
        const m: Machine = .{ .relay = .{ .base = "b", .device = "d", .token = "t", .name = "n" } };
        if (m.dupe(a)) |copy| {
            try testing.expectEqualStrings("n", copy.relay.name.?);
            a.free(copy.relay.base);
            a.free(copy.relay.device);
            a.free(copy.relay.token);
            a.free(copy.relay.name.?);
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
}
