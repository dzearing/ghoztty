//! Tunnelled web viewers, the agent's half (T2221;
//! docs/design/remote-viewer-tunnel.md decision 3, resolved by D103:
//! "everything loads from the other machine").
//!
//! A page shown in a viewer for a remote session is rendered by the LOCAL
//! app, but every request it makes is made HERE, on the agent's machine - so
//! `http://localhost:3000` is this box's dev server, not the viewer's. The
//! app intercepts each request and sends `WEB_REQUEST`; this module checks
//! it, performs it on a worker thread, and answers `WEB_RESPONSE` on the
//! request channel. A body bigger than one piece is held here and pulled with
//! `WEB_READ`, the `VIEWER_FETCH` shape, then released with `WEB_CLOSE`.
//!
//! The policy, all of it checked before a socket is opened:
//! - only absolute `http:` / `https:` URLs with a host; never `file:` - a page
//!   reads this machine's files through `viewer_grants.zig`, never here;
//! - no `CONNECT` or `TRACE`;
//! - header names are RFC 7230 tokens and values carry no CR, LF or NUL (the
//!   std client asserts on CR/LF, so a bad header must be refused, not
//!   passed);
//! - the hop-by-hop headers are dropped and recomputed (`Host`, `Connection`,
//!   `Content-Length`, ...), and `Accept-Encoding` is pinned to `identity` so
//!   the body handed back is the bytes the page asked for;
//! - a redirect is answered as itself and never followed, so the page's own
//!   engine follows it and that request comes back through here too;
//! - bounded: a request body of at most `max_web_request_body_bytes`, a
//!   response of at most `max_web_response_bytes`, `max_web_in_flight`
//!   requests at once, `max_web_held_bytes` held, and every socket read or
//!   write gives up after `web_idle_timeout_ms` of silence.
//!
//! Lifetime: a worker can outlive the connection that started it (a server
//! that answers slowly). Workers therefore never hold the `Server`; they
//! share a reference-counted `Shared`, and once the connection closes it
//! their answers are dropped rather than sent.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("../protocol.zig");
const thread_stack = @import("../../os/thread_stack.zig");

const Allocator = std.mem.Allocator;
const E = protocol.WebError;
const http = std.http;

/// Hands one encoded control frame to the connection's writer. Takes
/// ownership of `payload` on every path.
pub const DeliverFn = *const fn (ctx: *anyopaque, ftype: protocol.FrameType, channel: u128, payload: []u8) void;

/// What one connection's tunnel shares with its in-flight workers.
const Shared = struct {
    alloc: Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    mutex: std.Thread.Mutex = .{},
    idle: std.Thread.Condition = .{},
    /// Cleared by `Tunnel.deinit`; nothing is delivered after that.
    open: bool = true,
    ctx: *anyopaque,
    deliver: DeliverFn,
    in_flight: usize = 0,
    bodies: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    held_bytes: u64 = 0,
    next_body: u64 = 1,

    fn ref(self: *Shared) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn unref(self: *Shared) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        var it = self.bodies.valueIterator();
        while (it.next()) |b| self.alloc.free(b.*);
        self.bodies.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Encode and send, unless the connection has gone. Caller does NOT
    /// hold `mutex`.
    fn send(self: *Shared, ftype: protocol.FrameType, channel: u128, value: anytype) void {
        const payload = protocol.encodeJson(self.alloc, value) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.open) {
            self.alloc.free(payload);
            return;
        }
        self.deliver(self.ctx, ftype, channel, payload);
    }
};

/// One connection's web tunnel. Driven from the control reader thread.
pub const Tunnel = struct {
    shared: *Shared,

    pub fn init(alloc: Allocator, ctx: *anyopaque, deliver: DeliverFn) Allocator.Error!Tunnel {
        const s = try alloc.create(Shared);
        s.* = .{ .alloc = alloc, .ctx = ctx, .deliver = deliver };
        return .{ .shared = s };
    }

    /// Stop delivering, wait up to `wait_ms` for running requests to finish,
    /// and drop this connection's reference. A worker still blocked on a
    /// silent server after that finishes on its own (within the idle
    /// timeout) and frees what is left.
    pub fn deinit(self: *Tunnel, wait_ms: u64) void {
        const s = self.shared;
        s.mutex.lock();
        s.open = false;
        const deadline = std.time.nanoTimestamp() + @as(i128, wait_ms) * std.time.ns_per_ms;
        while (s.in_flight > 0) {
            const now = std.time.nanoTimestamp();
            if (now >= deadline) break;
            s.idle.timedWait(&s.mutex, @intCast(deadline - now)) catch {};
        }
        s.mutex.unlock();
        s.unref();
        self.* = undefined;
    }

    /// `WEB_REQUEST`: refuse it here, or start a worker that answers it.
    pub fn request(self: *Tunnel, channel: u128, payload: []const u8) void {
        const s = self.shared;
        var parsed = protocol.parseJson(protocol.WebRequest, s.alloc, payload) catch {
            s.send(.web_response, channel, refusal(E.bad_request));
            return;
        };
        defer parsed.deinit();

        const job = Job.prepare(s.alloc, parsed.value) catch |err| {
            s.send(.web_response, channel, refusal(switch (err) {
                error.OutOfMemory => E.busy,
                error.Refused => E.bad_request,
            }));
            return;
        };
        switch (job) {
            .refused => |why| {
                s.send(.web_response, channel, refusal(why));
                return;
            },
            .ready => |j| {
                j.channel = channel;
                j.shared = s;
                s.mutex.lock();
                if (s.in_flight >= protocol.max_web_in_flight) {
                    s.mutex.unlock();
                    j.destroy();
                    s.send(.web_response, channel, refusal(E.busy));
                    return;
                }
                s.in_flight += 1;
                s.mutex.unlock();
                s.ref();
                const t = std.Thread.spawn(thread_stack.config, workerMain, .{j}) catch {
                    j.finish();
                    s.send(.web_response, channel, refusal(E.busy));
                    return;
                };
                t.detach();
            },
        }
    }

    /// `WEB_READ`: one piece of a held body, answered `WEB_DATA`.
    pub fn read(self: *Tunnel, channel: u128, payload: []const u8) void {
        const s = self.shared;
        var parsed = protocol.parseJson(protocol.WebRead, s.alloc, payload) catch {
            s.send(.web_data, channel, protocol.WebData{ .ok = false, .@"error" = E.bad_request });
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;

        // Encode under the lock: `close` runs on this same thread, so only
        // `deinit` could free the body, and it takes the lock too.
        s.mutex.lock();
        const body = s.bodies.get(req.body) orelse {
            s.mutex.unlock();
            s.send(.web_data, channel, protocol.WebData{ .ok = false, .@"error" = E.no_body });
            return;
        };
        const start: usize = @intCast(@min(req.offset, body.len));
        const want: usize = @min(req.max_len, protocol.max_viewer_chunk_bytes);
        const piece = body[start..@min(body.len, start + want)];
        const b64 = encodeB64(s.alloc, piece) catch {
            s.mutex.unlock();
            s.send(.web_data, channel, protocol.WebData{ .ok = false, .@"error" = E.busy });
            return;
        };
        const size = body.len;
        s.mutex.unlock();
        defer s.alloc.free(b64);
        s.send(.web_data, channel, protocol.WebData{
            .ok = true,
            .size = size,
            .offset = start,
            .data = b64,
            .eof = start + piece.len >= size,
        });
    }

    /// `WEB_CLOSE`: release a held body. Unknown ids are a no-op.
    pub fn close(self: *Tunnel, payload: []const u8) void {
        const s = self.shared;
        var parsed = protocol.parseJson(protocol.WebClose, s.alloc, payload) catch return;
        defer parsed.deinit();
        s.mutex.lock();
        defer s.mutex.unlock();
        if (s.bodies.fetchRemove(parsed.value.body)) |kv| {
            s.held_bytes -= kv.value.len;
            s.alloc.free(kv.value);
        }
    }

    /// Bodies held right now (tests).
    pub fn heldCount(self: *Tunnel) usize {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();
        return self.shared.bodies.count();
    }
};

fn refusal(why: []const u8) protocol.WebResponse {
    return .{ .ok = false, .@"error" = why };
}

fn encodeB64(alloc: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

// --- Policy (pure) -------------------------------------------------------------

/// The method, if the tunnel will make it. `CONNECT` would turn the agent into
/// a raw TCP relay and `TRACE` echoes the request back; neither has a use in
/// a page.
pub fn parseMethod(name: []const u8) ?http.Method {
    const m = std.meta.stringToEnum(http.Method, name) orelse return null;
    return switch (m) {
        .CONNECT, .TRACE => null,
        else => m,
    };
}

/// True for an absolute `http:` / `https:` URL with a host.
pub fn urlAllowed(uri: std.Uri) bool {
    const scheme_ok = std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!scheme_ok) return false;
    const host = uri.host orelse return false;
    return switch (host) {
        .raw, .percent_encoded => |h| h.len > 0,
    };
}

/// RFC 7230 `token`.
pub fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => {},
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

/// No CR, LF or NUL: anything else a page sends is passed through.
pub fn validHeaderValue(value: []const u8) bool {
    for (value) |c| if (c == '\r' or c == '\n' or c == 0) return false;
    return true;
}

/// Request headers that describe the hop rather than the request. Dropped;
/// the client computes its own (`Host` from the URL, the length from the
/// body, `Accept-Encoding: identity`).
pub fn isHopRequestHeader(name: []const u8) bool {
    const drop = [_][]const u8{
        "host",              "connection",          "content-length",
        "transfer-encoding", "keep-alive",          "upgrade",
        "te",                "trailer",             "proxy-connection",
        "proxy-authorization", "accept-encoding",   "expect",
    };
    for (drop) |d| if (std.ascii.eqlIgnoreCase(name, d)) return true;
    return false;
}

/// Response headers that describe the hop. Dropped: the body handed back is
/// already de-chunked and its length is `WEB_RESPONSE.size`.
pub fn isHopResponseHeader(name: []const u8) bool {
    const drop = [_][]const u8{
        "connection", "keep-alive", "transfer-encoding", "te",
        "trailer",    "upgrade",    "proxy-connection",  "content-length",
    };
    for (drop) |d| if (std.ascii.eqlIgnoreCase(name, d)) return true;
    return false;
}

/// The wire reason for a failed request.
pub fn classify(err: anyerror) []const u8 {
    const n = @errorName(err);
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    if (err == error.StreamTooLong) return E.too_large;
    if (has(n, "UnknownHost") or has(n, "NameServer") or has(n, "LacksNetworkAddresses")) return E.unknown_host;
    if (has(n, "ConnectionRefused")) return E.connection_refused;
    if (has(n, "Timeout") or has(n, "TimedOut") or has(n, "WouldBlock")) return E.timed_out;
    if (has(n, "Tls") or has(n, "Certificate")) return E.tls_failed;
    if (has(n, "Http") or has(n, "ContentLength") or has(n, "Chunk")) return E.bad_response;
    return E.network_failed;
}

// --- One request ---------------------------------------------------------------

const Job = struct {
    alloc: Allocator,
    shared: *Shared = undefined,
    channel: u128 = 0,
    method: http.Method,
    url: []u8,
    body: ?[]u8,
    extra: []http.Header,
    user_agent: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    /// Every string the headers point at.
    strings: std.ArrayListUnmanaged([]u8) = .empty,

    const Prepared = union(enum) { ready: *Job, refused: []const u8 };

    /// Check `req` and copy what the worker needs out of the parse arena.
    fn prepare(alloc: Allocator, req: protocol.WebRequest) error{ OutOfMemory, Refused }!Prepared {
        const method = parseMethod(req.method) orelse return .{ .refused = E.bad_method };
        const uri = std.Uri.parse(req.url) catch return .{ .refused = E.bad_url };
        if (!urlAllowed(uri)) return .{ .refused = E.bad_url };
        if (req.headers.len > protocol.max_web_headers) return .{ .refused = E.request_too_large };
        for (req.headers) |h| {
            if (!validHeaderName(h.name) or !validHeaderValue(h.value)) return .{ .refused = E.bad_request };
        }

        var body: ?[]u8 = null;
        if (req.body) |b64| {
            const dec = std.base64.standard.Decoder;
            const n = dec.calcSizeForSlice(b64) catch return .{ .refused = E.bad_request };
            if (n > protocol.max_web_request_body_bytes) return .{ .refused = E.request_too_large };
            const buf = try alloc.alloc(u8, n);
            dec.decode(buf, b64) catch {
                alloc.free(buf);
                return .{ .refused = E.bad_request };
            };
            body = buf;
        }
        errdefer if (body) |b| alloc.free(b);

        const j = try alloc.create(Job);
        errdefer alloc.destroy(j);
        j.* = .{
            .alloc = alloc,
            .method = method,
            .url = try alloc.dupe(u8, req.url),
            .body = body,
            .extra = &.{},
        };
        errdefer alloc.free(j.url);

        var extra: std.ArrayListUnmanaged(http.Header) = .empty;
        errdefer extra.deinit(alloc);
        for (req.headers) |h| {
            if (isHopRequestHeader(h.name)) continue;
            const value = try j.keep(h.value);
            // The client writes these four itself; passing them as extras too
            // would send each twice.
            if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
                j.user_agent = value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                j.content_type = value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                j.authorization = value;
            } else {
                try extra.append(alloc, .{ .name = try j.keep(h.name), .value = value });
            }
        }
        j.extra = try extra.toOwnedSlice(alloc);
        return .{ .ready = j };
    }

    fn keep(self: *Job, s: []const u8) Allocator.Error![]const u8 {
        const d = try self.alloc.dupe(u8, s);
        errdefer self.alloc.free(d);
        try self.strings.append(self.alloc, d);
        return d;
    }

    fn destroy(self: *Job) void {
        const alloc = self.alloc;
        for (self.strings.items) |s| alloc.free(s);
        self.strings.deinit(alloc);
        alloc.free(self.extra);
        if (self.body) |b| alloc.free(b);
        alloc.free(self.url);
        alloc.destroy(self);
    }

    /// Release the in-flight slot and this job's reference.
    fn finish(self: *Job) void {
        const s = self.shared;
        self.destroy();
        s.mutex.lock();
        s.in_flight -= 1;
        s.idle.broadcast();
        s.mutex.unlock();
        s.unref();
    }
};

const Outcome = struct {
    status: u16,
    reason: []u8,
    headers: []protocol.WebHeader,
    body: []u8,

    fn deinit(self: *Outcome, alloc: Allocator) void {
        for (self.headers) |h| {
            alloc.free(h.name);
            alloc.free(h.value);
        }
        alloc.free(self.headers);
        alloc.free(self.reason);
        alloc.free(self.body);
    }
};

fn workerMain(job: *Job) void {
    defer job.finish();
    const s = job.shared;
    const alloc = s.alloc;
    var out = perform(alloc, job) catch |err| {
        s.send(.web_response, job.channel, refusal(classify(err)));
        return;
    };
    defer out.deinit(alloc);

    const first_len = @min(out.body.len, protocol.max_viewer_chunk_bytes);
    const eof = first_len == out.body.len;
    var body_id: ?u64 = null;
    if (!eof) {
        s.mutex.lock();
        if (s.held_bytes + out.body.len > protocol.max_web_held_bytes) {
            s.mutex.unlock();
            s.send(.web_response, job.channel, refusal(E.busy));
            return;
        }
        const id = s.next_body;
        s.bodies.put(alloc, id, out.body) catch {
            s.mutex.unlock();
            s.send(.web_response, job.channel, refusal(E.busy));
            return;
        };
        s.next_body += 1;
        s.held_bytes += out.body.len;
        s.mutex.unlock();
        body_id = id;
    }
    const first = out.body[0..first_len];
    // Ownership of the body moved to the table: `out.deinit` must not free it.
    const size = out.body.len;
    if (!eof) out.body = &.{};

    const b64 = encodeB64(alloc, first) catch {
        s.send(.web_response, job.channel, refusal(E.busy));
        return;
    };
    defer alloc.free(b64);
    s.send(.web_response, job.channel, protocol.WebResponse{
        .ok = true,
        .status = out.status,
        .reason = out.reason,
        .headers = out.headers,
        .size = size,
        .data = b64,
        .eof = eof,
        .body = body_id,
    });
}

fn override(v: ?[]const u8) http.Client.Request.Headers.Value {
    return if (v) |s| .{ .override = s } else .default;
}

fn perform(alloc: Allocator, job: *Job) !Outcome {
    var client: http.Client = .{ .allocator = alloc };
    defer client.deinit();

    const uri = try std.Uri.parse(job.url);
    var req = try client.request(job.method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
            .user_agent = override(job.user_agent),
            .content_type = override(job.content_type),
            .authorization = override(job.authorization),
        },
        .extra_headers = job.extra,
    });
    defer req.deinit();
    setIdleTimeout(req.connection.?.stream_reader.getStream().handle);

    if (job.method.requestHasBody()) {
        var empty: [0]u8 = .{};
        try req.sendBodyComplete(job.body orelse &empty);
    } else {
        try req.sendBodiless();
    }

    var resp = req.receiveHead(&.{}) catch |err| return readError(&req, err);

    var headers: std.ArrayListUnmanaged(protocol.WebHeader) = .empty;
    errdefer {
        for (headers.items) |h| {
            alloc.free(h.name);
            alloc.free(h.value);
        }
        headers.deinit(alloc);
    }
    var it = resp.head.iterateHeaders();
    while (it.next()) |h| {
        if (isHopResponseHeader(h.name)) continue;
        const name = try alloc.dupe(u8, h.name);
        errdefer alloc.free(name);
        const value = try alloc.dupe(u8, h.value);
        errdefer alloc.free(value);
        try headers.append(alloc, .{ .name = name, .value = value });
    }
    const reason = try alloc.dupe(u8, resp.head.reason);
    errdefer alloc.free(reason);
    const status: u16 = @intFromEnum(resp.head.status);

    // `reader` invalidates the head's strings, which are all copied above.
    var transfer: [64]u8 = undefined;
    const rd = resp.reader(&transfer);
    const body = rd.allocRemaining(alloc, .limited(protocol.max_web_response_bytes + 1)) catch |err| switch (err) {
        error.ReadFailed => return resp.bodyErr() orelse readError(&req, err),
        else => |e| return e,
    };
    if (body.len > protocol.max_web_response_bytes) {
        alloc.free(body);
        return error.StreamTooLong;
    }
    return .{
        .status = status,
        .reason = reason,
        .headers = try headers.toOwnedSlice(alloc),
        .body = body,
    };
}

/// A `ReadFailed` names nothing; the connection knows what actually failed.
fn readError(req: *http.Client.Request, err: anyerror) anyerror {
    if (err != error.ReadFailed) return err;
    const c = req.connection orelse return err;
    return c.getReadError() orelse err;
}

/// Bound every later socket read and write by `web_idle_timeout_ms`, so a
/// silent server costs a worker that long and no longer. Best effort: a
/// refusal here leaves the OS default.
fn setIdleTimeout(handle: std.net.Stream.Handle) void {
    const ms = protocol.web_idle_timeout_ms;
    if (builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        // Not in zig's ws2_32 bindings.
        const SOL_SOCKET: i32 = 0xffff;
        const SO_SNDTIMEO: i32 = 0x1005;
        const SO_RCVTIMEO: i32 = 0x1006;
        const v: u32 = ms;
        _ = ws2.setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, std.mem.asBytes(&v), @sizeOf(u32));
        _ = ws2.setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, std.mem.asBytes(&v), @sizeOf(u32));
    } else {
        const posix = std.posix;
        const tv: posix.timeval = .{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
        posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        posix.setsockopt(handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}

// --- Tests -----------------------------------------------------------------------

const testing = std.testing;

test "T2221 parseMethod refuses CONNECT, TRACE and non-methods" {
    try testing.expectEqual(http.Method.GET, parseMethod("GET").?);
    try testing.expectEqual(http.Method.POST, parseMethod("POST").?);
    try testing.expectEqual(http.Method.OPTIONS, parseMethod("OPTIONS").?);
    try testing.expect(parseMethod("CONNECT") == null);
    try testing.expect(parseMethod("TRACE") == null);
    try testing.expect(parseMethod("get") == null);
    try testing.expect(parseMethod("") == null);
}

test "T2221 urlAllowed takes absolute http(s) with a host and nothing else" {
    const ok = [_][]const u8{ "http://localhost:3000/", "https://example.com/a?b=c", "HTTP://127.0.0.1" };
    for (ok) |u| try testing.expect(urlAllowed(try std.Uri.parse(u)));
    const bad = [_][]const u8{ "file:///etc/passwd", "ftp://x/", "ghoztty://focus", "javascript:alert(1)", "http:///nohost" };
    for (bad) |u| {
        const uri = std.Uri.parse(u) catch continue;
        try testing.expect(!urlAllowed(uri));
    }
}

test "T2221 header checks: tokens only; no CR, LF or NUL in a value; hop headers dropped" {
    try testing.expect(validHeaderName("X-Requested-With"));
    try testing.expect(!validHeaderName(""));
    try testing.expect(!validHeaderName("Bad Name"));
    try testing.expect(!validHeaderName("a:b"));
    try testing.expect(validHeaderValue("text/html; charset=utf-8"));
    try testing.expect(!validHeaderValue("x\r\nInjected: 1"));
    try testing.expect(!validHeaderValue("x\x00"));
    try testing.expect(isHopRequestHeader("Host"));
    try testing.expect(isHopRequestHeader("ACCEPT-ENCODING"));
    try testing.expect(!isHopRequestHeader("Cookie"));
    try testing.expect(isHopResponseHeader("Transfer-Encoding"));
    try testing.expect(!isHopResponseHeader("Content-Type"));
}

test "T2221 classify names the failure the user can act on" {
    try testing.expectEqualStrings(E.connection_refused, classify(error.ConnectionRefused));
    try testing.expectEqualStrings(E.unknown_host, classify(error.UnknownHostName));
    try testing.expectEqualStrings(E.timed_out, classify(error.WouldBlock));
    try testing.expectEqualStrings(E.tls_failed, classify(error.TlsInitializationFailed));
    try testing.expectEqualStrings(E.bad_response, classify(error.HttpHeadersInvalid));
    try testing.expectEqualStrings(E.too_large, classify(error.StreamTooLong));
    try testing.expectEqualStrings(E.network_failed, classify(error.Unexpected));
}

test "T2221 Job.prepare refuses before any socket opens, and sorts the standard headers out" {
    const alloc = testing.allocator;
    const cases = [_]struct { req: protocol.WebRequest, why: []const u8 }{
        .{ .req = .{ .method = "CONNECT", .url = "http://x/" }, .why = E.bad_method },
        .{ .req = .{ .method = "GET", .url = "file:///c:/x" }, .why = E.bad_url },
        .{ .req = .{ .method = "GET", .url = "not a url" }, .why = E.bad_url },
        .{ .req = .{ .method = "GET", .url = "http://x/", .headers = &.{.{ .name = "X", .value = "a\r\nb" }} }, .why = E.bad_request },
        .{ .req = .{ .method = "POST", .url = "http://x/", .body = "!!!" }, .why = E.bad_request },
    };
    for (cases) |c| {
        const p = try Job.prepare(alloc, c.req);
        try testing.expectEqualStrings(c.why, p.refused);
    }

    const hs = [_]protocol.WebHeader{
        .{ .name = "Host", .value = "evil" },
        .{ .name = "User-Agent", .value = "page/1" },
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "Cookie", .value = "a=1" },
        .{ .name = "Accept-Encoding", .value = "br" },
    };
    const p = try Job.prepare(alloc, .{ .method = "POST", .url = "http://localhost:3000/f", .headers = &hs, .body = "aGk=" });
    const j = p.ready;
    defer j.destroy();
    try testing.expectEqualStrings("page/1", j.user_agent.?);
    try testing.expectEqualStrings("text/plain", j.content_type.?);
    try testing.expectEqual(@as(usize, 1), j.extra.len);
    try testing.expectEqualStrings("Cookie", j.extra[0].name);
    try testing.expectEqualStrings("hi", j.body.?);
}
