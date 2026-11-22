//! The frontend-independent half of an IPC server (T3334): the request shape,
//! the action → verb routing table, the JSON reply builders, and the dispatcher
//! that ties them together. A frontend (win32 today, GTK next - T3335) supplies
//! only the per-verb handlers, through a comptime interface, so:
//!
//! - every frontend parses the same request, answers the same `malformed
//!   JSON` / `unknown action: <x>` errors, and routes the same action strings;
//! - a frontend that does not serve a verb does not COMPILE. Platform symmetry
//!   is a standing rule here (CLAUDE.md): a verb missing on one frontend is the
//!   defect, so the compiler names it instead of a user hitting
//!   `unknown action` on one platform only.
//!
//! The Mac server is Swift (macos/Sources/Features/IPC/IPCServer.swift) and
//! cannot share this file; its strings are what these byte-match.
//!
//! ## The frontend interface
//!
//! `dispatch(F, ctx, alloc, json)` needs, on `F`:
//!
//! - `pub const Context: type` - whatever a handler needs (win32: the app and
//!   the reply allocator). Passed through untouched.
//! - `pub const log_scope: @EnumLiteral()` - the scope of the one
//!   `IPC: received action '<verb>'` line. win32 keeps `.win32_ipc`, which
//!   postmortems and `log_gate.zig` key on.
//! - `pub const CallerScope: type`, `fn enterCallerScope(ctx, caller_pane)
//!   CallerScope` and `fn leaveCallerScope(ctx, CallerScope) void` - pane names
//!   belong to their window (T2250), so a request's lookups start in the
//!   caller's window; the scope is restored on the way out, so a request served
//!   inside another's nested wait hands the outer one its scope back.
//! - one handler per `Verb`, named by `Verb.handlerName`, each
//!   `fn (ctx: Context, request: Request) Allocator.Error!?[]u8`. A null reply
//!   means "answered later" (a deferred reply the transport completes).
//! - optionally `fn handleSeam(ctx, request) Allocator.Error!SeamReply` for
//!   DEBUG-ONLY test seams (`capture-pane`, `frame-pacing`, ...). They are not
//!   CLI verbs and are not required of every frontend; a release build
//!   compiles them out and the action falls through to `unknown action`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ipc_handoff = @import("../../os/ipc_handoff.zig");

/// One request off the wire. Unknown fields are ignored, so an older server
/// reads a newer CLI's request and a newer server reads an older one.
pub const Request = struct {
    action: []const u8,
    arguments: ?[]const []const u8 = null,
    /// Set only by a LAUNCH that lost the race for the IPC endpoint and handed
    /// its window to us (T1022). Absent for every CLI verb, and absent from a
    /// launch built before this existed — both of which mean "say nothing",
    /// which is what the app did before.
    handoff: ?ipc_handoff.Identity = null,
    /// The pane the command was run from (`$GHOZTTY_PANE_ID`), which every CLI
    /// command sends (T2250; main 71da9a680) so a NAME is looked up in the
    /// caller's own window first. Absent from an older CLI and from a caller
    /// with no pane, both of which search every window.
    caller_pane: ?[]const u8 = null,
};

/// Every action a frontend must serve. Adding one here is a compile error on
/// every frontend until each serves it - on purpose.
pub const Verb = enum {
    new_window,
    list,
    close,
    split,
    rename,
    send_keys,
    read,
    set_state,
    rearrange,
    new_remote_window,
    version,
    handoff_quit,
    set_banner,
    reload,
    focus,
    stash,
    restore,

    /// The wire string the CLI sends.
    pub fn action(self: Verb) []const u8 {
        return switch (self) {
            .new_window => "new-window",
            .list => "list",
            .close => "close",
            .split => "split",
            .rename => "rename",
            .send_keys => "send-keys",
            .read => "read",
            .set_state => "set-state",
            .rearrange => "rearrange",
            .new_remote_window => "new-remote-window",
            .version => "version",
            .handoff_quit => ipc_handoff.quit_action,
            .set_banner => "set-banner",
            .reload => "reload",
            .focus => "focus",
            .stash => "stash",
            .restore => "restore",
        };
    }

    /// The frontend decl that serves this verb.
    pub fn handlerName(comptime self: Verb) []const u8 {
        return switch (self) {
            .new_window => "handleNewWindow",
            .list => "handleList",
            .close => "handleClose",
            .split => "handleSplit",
            .rename => "handleRename",
            .send_keys => "handleSendKeys",
            .read => "handleRead",
            .set_state => "handleSetState",
            .rearrange => "handleRearrange",
            .new_remote_window => "handleNewRemoteWindow",
            .version => "handleVersion",
            .handoff_quit => "handleHandoffQuit",
            .set_banner => "handleSetBanner",
            .reload => "handleReload",
            .focus => "handleFocus",
            .stash => "handleStash",
            .restore => "handleRestore",
        };
    }

    /// The verb an action string names, or null for anything else (a debug
    /// seam, or a genuinely unknown action). Exact, case-sensitive match.
    pub fn fromAction(s: []const u8) ?Verb {
        inline for (comptime std.enums.values(Verb)) |v| {
            if (std.mem.eql(u8, s, v.action())) return v;
        }
        return null;
    }
};

/// What an optional `handleSeam` answers: not one of its actions, or the reply
/// (null = deferred, same as a verb handler).
pub const SeamReply = union(enum) {
    unhandled,
    reply: ?[]u8,
};

/// Fail at compile time, naming the missing piece, when `F` does not implement
/// the interface above.
pub fn checkFrontend(comptime F: type) void {
    comptime {
        for (.{ "Context", "CallerScope", "log_scope", "enterCallerScope", "leaveCallerScope" }) |name| {
            if (!@hasDecl(F, name)) @compileError("IPC frontend " ++ @typeName(F) ++
                " is missing `" ++ name ++ "` (see apprt/ipc/server.zig)");
        }
        for (std.enums.values(Verb)) |v| {
            if (!@hasDecl(F, v.handlerName())) @compileError("IPC frontend " ++ @typeName(F) ++
                " does not serve `" ++ v.action() ++ "` (needs `" ++ v.handlerName() ++
                "`): every frontend serves every verb (platform symmetry)");
        }
    }
}

/// Parse one request and route it to `F`'s handler. Returns the reply JSON
/// allocated with `alloc` (the transport frees it), or null for a reply the
/// handler deferred. Request strings are freed when this returns, so a handler
/// that defers must copy what it keeps.
pub fn dispatch(
    comptime F: type,
    ctx: F.Context,
    alloc: Allocator,
    request_json: []const u8,
) Allocator.Error!?[]u8 {
    comptime checkFrontend(F);

    const parsed = std.json.parseFromSlice(
        Request,
        alloc,
        request_json,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return try errorResponse(alloc, "malformed JSON", .{});
    };
    defer parsed.deinit();
    const request = parsed.value;

    std.log.scoped(F.log_scope).info("IPC: received action '{s}'", .{request.action});

    const scope = F.enterCallerScope(ctx, request.caller_pane);
    defer F.leaveCallerScope(ctx, scope);

    if (Verb.fromAction(request.action)) |verb| switch (verb) {
        inline else => |v| return try @field(F, v.handlerName())(ctx, request),
    };

    if (@hasDecl(F, "handleSeam")) {
        switch (try F.handleSeam(ctx, request)) {
            .unhandled => {},
            .reply => |r| return r,
        }
    }

    return try errorResponse(alloc, "unknown action: {s}", .{request.action});
}

// ---------------------------------------------------------------------------
// Reply builders. Every reply is `{"success": <bool>, ...}`; the CLI parses
// with ignore_unknown_fields, so each extra field is additive.

/// `{"success":false,"error":<fmt>}`.
pub fn errorResponse(
    alloc: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error![]u8 {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(msg);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(false) catch break :write;
        jws.objectField("error") catch break :write;
        jws.write(msg) catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

/// T135: `+new-window`'s success reply carries an `outcome` ("created" or
/// "focused") and, when the idempotent focus dropped caller flags, a `note`
/// the CLI prints to stderr. Both fields are additive: an older CLI parses
/// with ignore_unknown_fields and sees the same `success` it always did.
pub fn successResponse(
    alloc: Allocator,
    outcome: []const u8,
    note: ?[]const u8,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("outcome") catch break :write;
        jws.write(outcome) catch break :write;
        if (note) |n| {
            jws.objectField("note") catch break :write;
            jws.write(n) catch break :write;
        }
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

/// `{"success":true,"message":<msg>}`: a success the CLI reports on stdout
/// (T2184; the Mac's `IPCResponse.message`).
pub fn messageResponse(alloc: Allocator, message: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("message") catch break :write;
        jws.write(message) catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Small pure helpers every frontend's handlers use.

/// Empty ⇒ null, so blank flag values are treated as absent.
pub fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len > 0) s else null;
}

/// Join a `-e arg...` argv into a single command line for a remote/agent shell,
/// which runs ONE command string rather than an argv (the agent applies its own
/// shell's convention). Space-separated; the values never contain embedded
/// quotes in practice. Null ⇒ no `-e` argv was given. Allocated in `arena`.
pub fn joinArgv(arena: Allocator, argv: []const []const u8) Allocator.Error!?[]const u8 {
    if (argv.len == 0) return null;
    var joined: std.ArrayList(u8) = .empty;
    for (argv, 0..) |a, i| {
        if (i > 0) try joined.append(arena, ' ');
        try joined.appendSlice(arena, a);
    }
    return joined.items;
}

/// How the idempotent-hit note names what happened to the existing surface
/// (T1797): it is raised only on request now, so "focused it" would describe a
/// raise that did not happen.
pub fn foundVerb(focus: bool) []const u8 {
    return if (focus) "focused" else "kept";
}

// ---------------------------------------------------------------------------
// Tests (none lane): a fake frontend that records what it was asked.

const testing = std.testing;

const Fake = struct {
    const Self = @This();

    called: ?Verb = null,
    seam_calls: usize = 0,
    scope: ?[]const u8 = null,
    scope_seen_by_handler: ?[]const u8 = null,
    arg0: ?[]const u8 = null,
    alloc: Allocator,

    pub const Context = *Self;
    pub const CallerScope = ?[]const u8;
    pub const log_scope = .ipc_server_test;

    pub fn enterCallerScope(ctx: *Self, caller_pane: ?[]const u8) ?[]const u8 {
        const outer = ctx.scope;
        ctx.scope = caller_pane;
        return outer;
    }
    pub fn leaveCallerScope(ctx: *Self, outer: ?[]const u8) void {
        ctx.scope = outer;
    }

    fn record(ctx: *Self, comptime v: Verb, request: Request) Allocator.Error!?[]u8 {
        ctx.called = v;
        ctx.scope_seen_by_handler = ctx.scope;
        if (request.arguments) |a| {
            if (a.len > 0) ctx.arg0 = try ctx.alloc.dupe(u8, a[0]);
        }
        return try messageResponse(ctx.alloc, v.action());
    }

    pub fn handleNewWindow(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.new_window, r); }
    pub fn handleList(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.list, r); }
    pub fn handleClose(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.close, r); }
    pub fn handleSplit(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.split, r); }
    pub fn handleRename(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.rename, r); }
    pub fn handleSendKeys(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.send_keys, r); }
    pub fn handleRead(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.read, r); }
    pub fn handleSetState(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.set_state, r); }
    pub fn handleRearrange(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.rearrange, r); }
    pub fn handleNewRemoteWindow(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.new_remote_window, r); }
    pub fn handleVersion(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.version, r); }
    pub fn handleHandoffQuit(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.handoff_quit, r); }
    pub fn handleSetBanner(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.set_banner, r); }
    pub fn handleReload(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.reload, r); }
    pub fn handleFocus(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.focus, r); }
    pub fn handleStash(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.stash, r); }
    pub fn handleRestore(c: *Self, r: Request) Allocator.Error!?[]u8 { return c.record(.restore, r); }

    pub fn handleSeam(c: *Self, r: Request) Allocator.Error!SeamReply {
        if (!std.mem.eql(u8, r.action, "capture-pane")) return .unhandled;
        c.seam_calls += 1;
        return .{ .reply = null };
    }
};

/// The same frontend minus the optional seam hook.
const FakeNoSeam = struct {
    pub const Context = *Fake;
    pub const CallerScope = ?[]const u8;
    pub const log_scope = .ipc_server_test;
    pub const enterCallerScope = Fake.enterCallerScope;
    pub const leaveCallerScope = Fake.leaveCallerScope;
    pub const handleNewWindow = Fake.handleNewWindow;
    pub const handleList = Fake.handleList;
    pub const handleClose = Fake.handleClose;
    pub const handleSplit = Fake.handleSplit;
    pub const handleRename = Fake.handleRename;
    pub const handleSendKeys = Fake.handleSendKeys;
    pub const handleRead = Fake.handleRead;
    pub const handleSetState = Fake.handleSetState;
    pub const handleRearrange = Fake.handleRearrange;
    pub const handleNewRemoteWindow = Fake.handleNewRemoteWindow;
    pub const handleVersion = Fake.handleVersion;
    pub const handleHandoffQuit = Fake.handleHandoffQuit;
    pub const handleSetBanner = Fake.handleSetBanner;
    pub const handleReload = Fake.handleReload;
    pub const handleFocus = Fake.handleFocus;
    pub const handleStash = Fake.handleStash;
    pub const handleRestore = Fake.handleRestore;
};

fn expectJson(alloc: Allocator, reply: ?[]u8, expected: []const u8) !void {
    const r = reply orelse return error.TestExpectedReply;
    defer alloc.free(r);
    try testing.expectEqualStrings(expected, r);
}

test "every verb's action string routes to its own handler" {
    const alloc = testing.allocator;
    inline for (comptime std.enums.values(Verb)) |v| {
        var fake: Fake = .{ .alloc = alloc };
        const json = try std.fmt.allocPrint(alloc, "{{\"action\":\"{s}\"}}", .{v.action()});
        defer alloc.free(json);
        const reply = try dispatch(Fake, &fake, alloc, json);
        try testing.expectEqual(@as(?Verb, v), fake.called);
        const expected = try std.fmt.allocPrint(alloc, "{{\"success\":true,\"message\":\"{s}\"}}", .{v.action()});
        defer alloc.free(expected);
        try expectJson(alloc, reply, expected);
    }
}

test "the action table is the one the CLI and the Mac server use" {
    // Pinned literally so a rename on one side is a failing test, not a silent
    // `unknown action` on one platform.
    const expected = [_][]const u8{
        "new-window", "list",      "close",   "split",             "rename",
        "send-keys",  "read",      "set-state", "rearrange",       "new-remote-window",
        "version",    "handoff-quit", "set-banner", "reload",      "focus",
        "stash",      "restore",
    };
    const values = comptime std.enums.values(Verb);
    try testing.expectEqual(expected.len, values.len);
    for (values, expected) |v, e| try testing.expectEqualStrings(e, v.action());
}

test "fromAction is exact" {
    try testing.expectEqual(@as(?Verb, .send_keys), Verb.fromAction("send-keys"));
    try testing.expectEqual(@as(?Verb, null), Verb.fromAction("Send-Keys"));
    try testing.expectEqual(@as(?Verb, null), Verb.fromAction("send-keys "));
    try testing.expectEqual(@as(?Verb, null), Verb.fromAction(""));
}

test "malformed JSON is answered, not dropped" {
    const alloc = testing.allocator;
    var fake: Fake = .{ .alloc = alloc };
    try expectJson(alloc, try dispatch(Fake, &fake, alloc, "{not json"),
        "{\"success\":false,\"error\":\"malformed JSON\"}");
    try expectJson(alloc, try dispatch(Fake, &fake, alloc, "{\"arguments\":[]}"),
        "{\"success\":false,\"error\":\"malformed JSON\"}");
    try testing.expectEqual(@as(?Verb, null), fake.called);
}

test "an unknown action names itself" {
    const alloc = testing.allocator;
    var fake: Fake = .{ .alloc = alloc };
    try expectJson(alloc, try dispatch(Fake, &fake, alloc, "{\"action\":\"frobnicate\"}"),
        "{\"success\":false,\"error\":\"unknown action: frobnicate\"}");
    try testing.expectEqual(@as(?Verb, null), fake.called);
    try testing.expectEqual(@as(usize, 0), fake.seam_calls);
}

test "a debug seam is reached only for its own action, and may defer" {
    const alloc = testing.allocator;
    var fake: Fake = .{ .alloc = alloc };
    try testing.expectEqual(@as(?[]u8, null), try dispatch(Fake, &fake, alloc, "{\"action\":\"capture-pane\"}"));
    try testing.expectEqual(@as(usize, 1), fake.seam_calls);
    try testing.expectEqual(@as(?Verb, null), fake.called);

    // A frontend without the hook answers the same action as unknown, which
    // is what a release build (seams compiled out) has always said.
    var bare: Fake = .{ .alloc = alloc };
    try expectJson(alloc, try dispatch(FakeNoSeam, &bare, alloc, "{\"action\":\"capture-pane\"}"),
        "{\"success\":false,\"error\":\"unknown action: capture-pane\"}");
}

test "the caller's pane scopes the handler and is restored afterwards" {
    const alloc = testing.allocator;
    var fake: Fake = .{ .alloc = alloc, .scope = "outer" };
    try expectJson(alloc, try dispatch(Fake, &fake, alloc,
        \\{"action":"split","arguments":["--name=x"],"caller_pane":"p-7"}
    ), "{\"success\":true,\"message\":\"split\"}");
    try testing.expectEqualStrings("p-7", fake.scope_seen_by_handler.?);
    try testing.expectEqualStrings("outer", fake.scope.?);
    defer alloc.free(fake.arg0.?);
    try testing.expectEqualStrings("--name=x", fake.arg0.?);

    // No caller pane: the handler sees no scope; the outer one still returns.
    var fake2: Fake = .{ .alloc = alloc, .scope = "outer" };
    try expectJson(alloc, try dispatch(Fake, &fake2, alloc, "{\"action\":\"list\"}"),
        "{\"success\":true,\"message\":\"list\"}");
    try testing.expectEqual(@as(?[]const u8, null), fake2.scope_seen_by_handler);
    try testing.expectEqualStrings("outer", fake2.scope.?);
}

test "unknown request fields are ignored (old/new CLI compatibility)" {
    const alloc = testing.allocator;
    var fake: Fake = .{ .alloc = alloc };
    try expectJson(alloc, try dispatch(Fake, &fake, alloc,
        \\{"action":"read","from_the_future":{"x":1}}
    ), "{\"success\":true,\"message\":\"read\"}");
    try testing.expectEqual(@as(?Verb, .read), fake.called);
}

test "reply builders" {
    const alloc = testing.allocator;
    try expectJson(alloc, try successResponse(alloc, "created", null),
        "{\"success\":true,\"outcome\":\"created\"}");
    try expectJson(alloc, try successResponse(alloc, "focused", "dropped --cwd"),
        "{\"success\":true,\"outcome\":\"focused\",\"note\":\"dropped --cwd\"}");
    try expectJson(alloc, try errorResponse(alloc, "pane '{s}' not found", .{"a\"b"}),
        "{\"success\":false,\"error\":\"pane 'a\\\"b' not found\"}");
    try expectJson(alloc, try messageResponse(alloc, "closed 2 panes"),
        "{\"success\":true,\"message\":\"closed 2 panes\"}");
}

test "nonEmpty, joinArgv, foundVerb" {
    try testing.expectEqual(@as(?[]const u8, null), nonEmpty(null));
    try testing.expectEqual(@as(?[]const u8, null), nonEmpty(""));
    try testing.expectEqualStrings("x", nonEmpty("x").?);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(?[]const u8, null), try joinArgv(arena, &.{}));
    try testing.expectEqualStrings("vim a.txt", (try joinArgv(arena, &.{ "vim", "a.txt" })).?);

    try testing.expectEqualStrings("focused", foundVerb(true));
    try testing.expectEqualStrings("kept", foundVerb(false));
}
