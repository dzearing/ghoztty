//! Off-UI-thread answers for a viewer's resource requests (T3245): every file
//! the bundled template or a rendered `.html` page asks for - a markdown
//! file's pictures, a page's stylesheets, scripts, fonts and media.
//!
//! **Why a worker.** `WebResourceRequested` arrives on the GUI thread, the
//! message loop every terminal pane in the window draws on. Answering a request
//! means up to three `stat` probes (the 3-tier resolution) and then a read of
//! the file, and on a slow or network path each of those can take as long as
//! the path likes - inline, a markdown file with twenty pictures on a share
//! froze typing in every terminal for the whole of it. So the request is
//! parked on its deferral, the probes and the read run on a pooled worker
//! (`worker_pool`), and the response is built from the completion post: the
//! shape `ViewerImageDecode` and `ViewerDocumentRead` already have.
//!
//! **Why a queue, not "newest wins".** Those two keep one job and let a newer
//! one replace an older one waiting, because only the latest decode or render
//! matters. Every resource request matters - each `<img>` owes its own answer -
//! so requests wait in FIFO order and one worker drains them. One worker is
//! enough: the point is that the GUI thread never waits, not that twenty
//! pictures on a share arrive in parallel.
//!
//! **Threads.** The worker touches only the filesystem and the HGLOBAL it
//! reads into. Every COM call - the deferral, the response, the stream - is
//! made on the GUI thread, in `request`, the completion, and `finish`.
const Serve = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const com = @import("com.zig");
const iface = @import("webview2_iface.zig");
const content = @import("viewer_content.zig");
const byte_range = @import("viewer_range.zig");
const slow_path = @import("viewer_slow_path.zig");
const worker_pool = @import("worker_pool.zig");

const log = std.log.scoped(.viewer);

/// Which host asked: the bundled template (3-tier resolution, whole files) or
/// a rendered page (its own root only, byte ranges, `no-store`).
pub const Kind = enum { template, page };

/// What the worker found. The pane turns each into a response and a log line.
pub const Result = enum {
    /// No candidate is a file.
    not_found,
    /// A file, but it could not be opened, stat'ed or read (or, for the
    /// template, is past the whole-file ceiling).
    unreadable,
    /// A page resource asked for whole that is past the ceiling.
    too_large,
    /// The `Range` asked for starts past the end.
    unsatisfiable,
    /// The file shrank under the read: the planned body cannot be sent.
    changed,
    /// `body` holds the answer.
    served,
};

/// The template tier has three candidates (bundled assets, the viewed file's
/// directory, a rooted reference); a page has one.
pub const max_candidates = 3;

/// One request. The GUI thread fills the inputs, the worker fills the
/// outputs, and the GUI thread reads them only after the worker has handed the
/// job back under the mutex - no field is touched by two threads at once.
pub const Job = struct {
    alloc: Allocator,
    kind: Kind,
    /// The path the page asked for, for the MIME type and the log. Owned.
    rel: []u8,
    /// A page request's `Range` header. Owned.
    range: ?[]u8 = null,
    /// Paths to try, in order; the first that is a FILE is served. Owned.
    candidates: [max_candidates]?[]u8 = .{null} ** max_candidates,
    count: usize = 0,
    /// The simulated slow disk (Debug builds only, `viewer_slow_path`).
    slow: slow_path.Config = .{},

    /// The parked request: one reference and the deferral that owes it an
    /// answer, both released in `finish`. Null for a job run inline, whose
    /// caller answers through the args it was handed.
    args: ?*iface.ICoreWebView2WebResourceRequestedEventArgs = null,
    deferral: ?*iface.ICoreWebView2Deferral = null,
    /// The queue link, guarded by `Serve.mutex`.
    next: ?*Job = null,

    result: Result = .not_found,
    /// Index into `candidates` of the file that was found.
    resolved: ?usize = null,
    size: u64 = 0,
    plan: byte_range.Plan = .whole,
    /// The body, in a moveable HGLOBAL of `len` bytes; null for an empty one.
    /// Ownership passes to the stream in `takeStream`.
    body: ?*anyopaque = null,
    len: usize = 0,
    /// How long the probes and the read took, for the log line.
    serve_ms: u64 = 0,

    /// Take `candidate` (owned) as the next path to try. A null is a candidate
    /// the resolver refused, and is simply not tried.
    pub fn addCandidate(self: *Job, candidate: ?[]u8) void {
        const path = candidate orelse return;
        if (self.count == max_candidates) {
            self.alloc.free(path);
            return;
        }
        self.candidates[self.count] = path;
        self.count += 1;
    }

    /// The file that was found, once `run` has.
    pub fn resolvedPath(self: *const Job) ?[]const u8 {
        const i = self.resolved orelse return null;
        return self.candidates[i];
    }

    pub fn parked(self: *const Job) bool {
        return self.deferral != null;
    }

    /// The probes and the read. Blocking: runs on the worker, or inline when
    /// the request could not be parked.
    pub fn run(self: *Job) void {
        const started = std.time.milliTimestamp();
        defer self.serve_ms = @intCast(@max(0, std.time.milliTimestamp() - started));
        self.slow.pause();
        const i = firstFile(self.candidates[0..self.count]) orelse {
            self.result = .not_found;
            return;
        };
        self.resolved = i;
        self.result = self.read(self.candidates[i].?);
    }

    fn read(self: *Job, path: []const u8) Result {
        const file = std.fs.cwd().openFile(path, .{}) catch return .unreadable;
        defer file.close();
        const size = (file.stat() catch return .unreadable).size;
        self.size = size;
        switch (self.kind) {
            .template => {
                if (size > content.max_file_bytes) return .unreadable;
                self.readInto(file, 0, size) catch return .unreadable;
                return .served;
            },
            .page => {
                self.plan = byte_range.plan(self.range, size, byte_range.max_chunk);
                switch (self.plan) {
                    .unsatisfiable => return .unsatisfiable,
                    .partial => |span| {
                        self.readInto(file, span.start, span.len()) catch return .changed;
                        return .served;
                    },
                    .whole => {
                        if (size > content.max_file_bytes) return .too_large;
                        self.readInto(file, 0, size) catch return .too_large;
                        return .served;
                    },
                }
            },
        }
    }

    /// Bytes `offset .. offset+len` of `file`, straight into a fresh HGLOBAL
    /// (one copy, as T3044's `fileStream` holds it). The handle was opened by
    /// `std.fs`, which shares read, write and delete, so an editor saving the
    /// file mid-read is never refused.
    fn readInto(self: *Job, file: std.fs.File, offset: u64, len: u64) error{ Memory, Read, Changed }!void {
        if (len > std.math.maxInt(usize)) return error.Memory;
        if (len == 0) return;
        const want: usize = @intCast(len);
        const mem = w32.GlobalAlloc(w32.GMEM_MOVEABLE, want) orelse return error.Memory;
        errdefer _ = w32.GlobalFree(mem);
        {
            const dst = w32.GlobalLock(mem) orelse return error.Memory;
            defer _ = w32.GlobalUnlock(mem);
            const got = file.preadAll(dst[0..want], offset) catch return error.Read;
            if (got != want) return error.Changed;
        }
        self.body = mem;
        self.len = want;
    }

    /// The body as a rewound stream the response can carry; it owns the
    /// HGLOBAL from here. GUI thread. Null when no stream could be made.
    pub fn takeStream(self: *Job) ?*iface.IStream {
        var ptr: ?*anyopaque = null;
        if (com.failed(w32.CreateStreamOnHGlobal(self.body, 1, &ptr))) return null;
        const stream: *iface.IStream = @ptrCast(@alignCast(ptr orelse return null));
        self.body = null;
        if (!stream.setSize(self.len) or !stream.rewind()) {
            stream.release();
            return null;
        }
        return stream;
    }

    /// Complete the deferral (whatever is set on `args` is the answer; none
    /// fails the request) and free everything. GUI thread.
    pub fn finish(self: *Job) void {
        if (self.deferral) |d| {
            if (!d.complete()) log.warn("resource serve: deferral Complete failed; {s} may never arrive", .{self.rel});
            d.release();
        }
        if (self.args) |a| a.release();
        if (self.body) |b| _ = w32.GlobalFree(b);
        const alloc = self.alloc;
        for (self.candidates[0..self.count]) |c| if (c) |p| alloc.free(p);
        if (self.range) |r| alloc.free(r);
        alloc.free(self.rel);
        alloc.destroy(self);
    }
};

/// Index of the first candidate that is a FILE. A directory is not a
/// resource, and answering with one would be a read error dressed as a hit.
pub fn firstFile(candidates: []const ?[]u8) ?usize {
    for (candidates, 0..) |c, i| {
        const path = c orelse continue;
        const stat = std.fs.cwd().statFile(path) catch continue;
        if (stat.kind == .file) return i;
    }
    return null;
}

/// A job for `rel`, with no candidates yet. Null when memory runs out.
pub fn makeJob(alloc: Allocator, kind: Kind, rel: []const u8, range: ?[]const u8) ?*Job {
    const job = alloc.create(Job) catch return null;
    const rel_owned = alloc.dupe(u8, rel) catch {
        alloc.destroy(job);
        return null;
    };
    const range_owned: ?[]u8 = if (range) |r| alloc.dupe(u8, r) catch {
        alloc.free(rel_owned);
        alloc.destroy(job);
        return null;
    } else null;
    job.* = .{ .alloc = alloc, .kind = kind, .rel = rel_owned, .range = range_owned };
    return job;
}

alloc: Allocator,

/// Where a completion is posted. Null until the pane has a host window; a
/// request made before then is answered inline.
hwnd: ?w32.HWND = null,
message: u32 = 0,
slow: slow_path.Config = .{},

/// Guards everything below it except `thread`, which only the GUI thread
/// touches.
mutex: std.Thread.Mutex = .{},
pending_head: ?*Job = null,
pending_tail: ?*Job = null,
done_head: ?*Job = null,
done_tail: ?*Job = null,
/// A worker is draining `pending`. Cleared by the worker, under the mutex, on
/// its way out - so a request that finds it false owns starting the next one.
running: bool = false,
closing: bool = false,

thread: ?worker_pool.Thread = null,

pub fn init(alloc: Allocator) Serve {
    return .{ .alloc = alloc, .slow = slow_path.fromEnv() };
}

pub fn attach(self: *Serve, hwnd: w32.HWND, message: u32) void {
    self.hwnd = hwnd;
    self.message = message;
}

/// Park `args` on its deferral and answer `job` off the GUI thread. False
/// means nothing was parked - no window yet, the runtime refused the deferral,
/// or the slow-path seam forces inline - and the caller still owns `job`, to
/// run inline and answer through `args`.
pub fn request(self: *Serve, job: *Job, args: *iface.ICoreWebView2WebResourceRequestedEventArgs) bool {
    if (self.hwnd == null or self.slow.force_inline) return false;
    const deferral = args.getDeferral() orelse return false;
    args.addRef();
    job.args = args;
    job.deferral = deferral;

    self.mutex.lock();
    push(&self.pending_head, &self.pending_tail, job);
    const start = !self.running;
    if (start) self.running = true;
    self.mutex.unlock();

    if (start) {
        // A worker that found the queue empty has already returned (it clears
        // `running` as its last act), so this join does not wait on a read.
        if (self.thread) |t| t.join();
        self.thread = null;
        self.thread = worker_pool.spawn(work, .{self}) catch null;
        if (self.thread == null) {
            // No thread: answer everything queued from here instead, through
            // the same completion, so every parked request still gets one.
            log.warn("resource serve: worker could not start; answering inline", .{});
            self.drainInline();
        }
    }
    return true;
}

/// Run every queued job on this thread and post the completion. The
/// no-thread fallback; GUI thread.
fn drainInline(self: *Serve) void {
    while (true) {
        self.mutex.lock();
        const job = pop(&self.pending_head, &self.pending_tail) orelse {
            self.running = false;
            self.mutex.unlock();
            break;
        };
        self.mutex.unlock();
        job.slow = self.slow;
        job.run();
        self.mutex.lock();
        push(&self.done_head, &self.done_tail, job);
        self.mutex.unlock();
    }
    self.post();
}

fn work(self: *Serve) void {
    while (true) {
        self.mutex.lock();
        const job = if (self.closing) null else pop(&self.pending_head, &self.pending_tail);
        if (job == null) {
            self.running = false;
            self.mutex.unlock();
            return;
        }
        self.mutex.unlock();
        job.?.slow = self.slow;
        job.?.run();
        self.mutex.lock();
        push(&self.done_head, &self.done_tail, job.?);
        const closing = self.closing;
        self.mutex.unlock();
        if (!closing) self.post();
    }
}

fn post(self: *Serve) void {
    const h = self.hwnd orelse return;
    if (w32.PostMessageW(h, self.message, 0, 0) == 0) {
        log.warn("resource serve: completion could not be posted", .{});
    }
}

/// One finished job, for the pane to answer and then `finish`; null when none
/// is waiting. GUI thread, from the completion post - which may find several,
/// or none (an earlier post already collected them).
pub fn takeDone(self: *Serve) ?*Job {
    self.mutex.lock();
    defer self.mutex.unlock();
    return pop(&self.done_head, &self.done_tail);
}

/// Whether anything is queued, being read, or waiting to be answered. Tests
/// read it.
pub fn busy(self: *Serve) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.running or self.pending_head != null or self.done_head != null;
}

/// Answer every parked request with nothing and join the worker. Safe from any
/// state. The join bounds a pane close by one read at worst - the one in
/// flight; everything still queued is dropped without being read.
pub fn deinit(self: *Serve) void {
    self.mutex.lock();
    self.closing = true;
    var pending = self.pending_head;
    self.pending_head = null;
    self.pending_tail = null;
    self.mutex.unlock();
    while (pending) |j| {
        pending = j.next;
        j.finish();
    }
    if (self.thread) |t| t.join();
    self.thread = null;
    while (self.takeDone()) |j| j.finish();
}

fn push(head: *?*Job, tail: *?*Job, job: *Job) void {
    job.next = null;
    if (tail.*) |t| t.next = job else head.* = job;
    tail.* = job;
}

fn pop(head: *?*Job, tail: *?*Job) ?*Job {
    const job = head.* orelse return null;
    head.* = job.next;
    if (head.* == null) tail.* = null;
    job.next = null;
    return job;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn testDir(alloc: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return tmp.dir.realpathAlloc(alloc, ".");
}

fn bodyBytes(job: *Job) []const u8 {
    const mem = job.body orelse return "";
    const p = w32.GlobalLock(mem) orelse return "";
    _ = w32.GlobalUnlock(mem);
    return p[0..job.len];
}

test "ViewerResourceServe: the first candidate that is a FILE is served whole" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("pic.png"); // a directory named like the file: not a hit
    try tmp.dir.makeDir("b");
    try tmp.dir.writeFile(.{ .sub_path = "b/pic.png", .data = "PNGDATA" });
    const root = try testDir(alloc, &tmp);
    defer alloc.free(root);

    const job = makeJob(alloc, .template, "pic.png", null).?;
    defer job.finish();
    job.addCandidate(try std.fs.path.join(alloc, &.{ root, "missing.png" }));
    job.addCandidate(null); // a refused candidate is not tried
    job.addCandidate(try std.fs.path.join(alloc, &.{ root, "pic.png" }));
    job.addCandidate(try std.fs.path.join(alloc, &.{ root, "b", "pic.png" }));
    // A fourth is dropped, not leaked (the leak checker is the assertion).
    job.addCandidate(try std.fs.path.join(alloc, &.{ root, "extra.png" }));
    try testing.expectEqual(@as(usize, 3), job.count);
    job.run();
    try testing.expectEqual(Result.served, job.result);
    try testing.expectEqual(@as(?usize, 2), job.resolved);
    try testing.expectEqualStrings("PNGDATA", bodyBytes(job));
}

test "ViewerResourceServe: nothing found is not_found, and an empty file is served empty" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "empty.css", .data = "" });
    const root = try testDir(alloc, &tmp);
    defer alloc.free(root);

    const miss = makeJob(alloc, .template, "nope.png", null).?;
    defer miss.finish();
    miss.addCandidate(try std.fs.path.join(alloc, &.{ root, "nope.png" }));
    miss.run();
    try testing.expectEqual(Result.not_found, miss.result);
    try testing.expect(miss.resolvedPath() == null);

    const empty = makeJob(alloc, .template, "empty.css", null).?;
    defer empty.finish();
    empty.addCandidate(try std.fs.path.join(alloc, &.{ root, "empty.css" }));
    empty.run();
    try testing.expectEqual(Result.served, empty.result);
    try testing.expectEqual(@as(usize, 0), empty.len);
    const stream = empty.takeStream() orelse return error.TestNoStream;
    stream.release();
}

test "ViewerResourceServe: a page range is read as a slice, and past the end is unsatisfiable" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "clip.wav", .data = "0123456789" });
    const root = try testDir(alloc, &tmp);
    defer alloc.free(root);

    const part = makeJob(alloc, .page, "clip.wav", "bytes=2-5").?;
    defer part.finish();
    part.addCandidate(try std.fs.path.join(alloc, &.{ root, "clip.wav" }));
    part.run();
    try testing.expectEqual(Result.served, part.result);
    try testing.expect(part.plan == .partial);
    try testing.expectEqualStrings("2345", bodyBytes(part));
    try testing.expectEqual(@as(u64, 10), part.size);

    const past = makeJob(alloc, .page, "clip.wav", "bytes=50-").?;
    defer past.finish();
    past.addCandidate(try std.fs.path.join(alloc, &.{ root, "clip.wav" }));
    past.run();
    try testing.expectEqual(Result.unsatisfiable, past.result);
    try testing.expect(past.body == null);

    const whole = makeJob(alloc, .page, "clip.wav", null).?;
    defer whole.finish();
    whole.addCandidate(try std.fs.path.join(alloc, &.{ root, "clip.wav" }));
    whole.run();
    try testing.expectEqual(Result.served, whole.result);
    try testing.expect(whole.plan == .whole);
    try testing.expectEqualStrings("0123456789", bodyBytes(whole));
}

test "ViewerResourceServe: the worker drains every queued job in order" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "A" });
    const root = try testDir(alloc, &tmp);
    defer alloc.free(root);

    // No window and no deferral here, so drive the queue the way `request`
    // does once it has parked: push, then start the worker.
    var s = Serve.init(alloc);
    s.slow = .{ .delay_ms = 5 };
    var jobs: [4]*Job = undefined;
    for (&jobs) |*j| {
        j.* = makeJob(alloc, .template, "a.txt", null).?;
        j.*.addCandidate(try std.fs.path.join(alloc, &.{ root, "a.txt" }));
        push(&s.pending_head, &s.pending_tail, j.*);
    }
    s.running = true;
    s.thread = try worker_pool.spawn(work, .{&s});
    s.thread.?.join();
    s.thread = null;
    var n: usize = 0;
    while (s.takeDone()) |j| {
        try testing.expectEqual(jobs[n], j);
        try testing.expectEqual(Result.served, j.result);
        try testing.expect(j.serve_ms >= 5);
        j.finish();
        n += 1;
    }
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expect(!s.busy());
    s.deinit();
}

test "ViewerResourceServe: deinit drops what is queued and joins what is out" {
    const alloc = testing.allocator;
    var s = Serve.init(alloc);
    s.slow = .{ .delay_ms = 20 };
    for (0..3) |_| {
        const j = makeJob(alloc, .template, "x", null).?;
        push(&s.pending_head, &s.pending_tail, j);
    }
    s.running = true;
    s.thread = try worker_pool.spawn(work, .{&s});
    // The leak checker is the assertion: every job is finished exactly once.
    s.deinit();
    try testing.expect(s.thread == null);
    try testing.expect(s.pending_head == null and s.done_head == null);
}
