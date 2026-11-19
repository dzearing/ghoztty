//! Off-UI-thread document read for markdown and code panes (T3224).
//!
//! **Why a worker.** `renderFileContent` used to read the whole document (up
//! to 32 MB), validate it and escape it into a script on the GUI thread - the
//! message loop every terminal pane in the window draws on. On a slow or
//! network path that froze every terminal in the process for as long as the
//! read took. Now the read and the script build (`viewer_document.read`) run on
//! a pooled worker (`worker_pool`), and the completion post hands the finished
//! script to the web view. The shape is `ViewerImageDecode`'s.
//!
//! **Why a generation.** A render can be asked for again while one is still
//! reading - a save landing mid-read, a `+reload`, a navigation to another
//! document. Each request carries the pane's render generation; the pane
//! applies a completion only when its generation is still the newest, so an
//! old read can never paint over a newer one, and a read of the document the
//! pane has since LEFT never reaches the page that replaced it.
//!
//! One worker at a time. A request arriving while one is in flight waits in
//! `queued`; a newer one replaces it, since only the newest render matters.
const Read = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const content = @import("viewer_content.zig");
const viewer_document = @import("viewer_document.zig");
const worker_pool = @import("worker_pool.zig");

const log = std.log.scoped(.viewer);

/// One read. The requester fills the inputs, the worker fills `outcome`, and
/// the GUI thread reads it only after `join` - no field is ever touched by two
/// threads at once.
pub const Job = struct {
    alloc: Allocator,
    /// The document. Owned.
    path: []u8,
    mode: content.Mode,
    /// The pane's render generation when this was asked for.
    generation: u64,

    outcome: viewer_document.Outcome = .none,
    /// The file's size, for the T3037 render log line.
    bytes: usize = 0,
    /// How long the read and build took on the worker, for the log line.
    read_ms: u64 = 0,

    pub fn run(self: *Job) void {
        const started = std.time.milliTimestamp();
        defer self.read_ms = @intCast(@max(0, std.time.milliTimestamp() - started));
        self.outcome = viewer_document.read(self.alloc, self.mode, self.path, &self.bytes);
    }

    pub fn finish(self: *Job) void {
        const alloc = self.alloc;
        self.outcome.deinit(alloc);
        alloc.free(self.path);
        alloc.destroy(self);
    }
};

alloc: Allocator,

/// Where a completion is posted. Null until the pane has a host window; a
/// render asked for before then is read inline by the caller.
hwnd: ?w32.HWND = null,
message: u32 = 0,

thread: ?worker_pool.Thread = null,
job: ?*Job = null,
queued: ?*Job = null,

pub fn init(alloc: Allocator) Read {
    return .{ .alloc = alloc };
}

pub fn attach(self: *Read, hwnd: w32.HWND, message: u32) void {
    self.hwnd = hwnd;
    self.message = message;
}

/// Make a job without starting it. Null when memory runs out.
pub fn makeJob(alloc: Allocator, path: []const u8, mode: content.Mode, generation: u64) ?*Job {
    const job = alloc.create(Job) catch return null;
    const owned = alloc.dupe(u8, path) catch {
        alloc.destroy(job);
        return null;
    };
    job.* = .{ .alloc = alloc, .path = owned, .mode = mode, .generation = generation };
    return job;
}

/// Read `path` off the GUI thread. False means nothing was started - no window
/// to post to, no memory, no thread - and the caller reads inline instead.
pub fn request(self: *Read, path: []const u8, mode: content.Mode, generation: u64) bool {
    if (self.hwnd == null) return false;
    const job = makeJob(self.alloc, path, mode, generation) orelse return false;
    if (self.thread != null) {
        if (self.queued) |old| old.finish();
        self.queued = job;
        return true;
    }
    if (!self.start(job)) {
        job.finish();
        return false;
    }
    return true;
}

/// Whether a read is out or waiting. Tests and the log read it.
pub fn busy(self: *const Read) bool {
    return self.thread != null or self.queued != null;
}

fn start(self: *Read, job: *Job) bool {
    self.job = job;
    self.thread = worker_pool.spawn(work, .{ self, job }) catch {
        self.job = null;
        return false;
    };
    return true;
}

fn work(self: *Read, job: *Job) void {
    job.run();
    if (self.hwnd) |h| {
        if (w32.PostMessageW(h, self.message, 0, 0) == 0) {
            log.warn("document read: completion could not be posted", .{});
        }
    }
}

/// The completion post landed on the GUI thread: the finished job, for the
/// pane to apply and then `finish`. Starts the queued read, if any.
pub fn complete(self: *Read) ?*Job {
    // A post can arrive for a read already collected (a `deinit` raced it, or
    // a queued read started and finished between posts): nothing to do.
    const t = self.thread orelse return null;
    t.join();
    self.thread = null;
    const done = self.job;
    self.job = null;
    if (self.queued) |next| {
        self.queued = null;
        if (!self.start(next)) next.finish();
    }
    return done;
}

/// Join any worker and drop every read. Safe from any state. The join is not
/// optional - the worker writes into a job this frees - and bounds a pane close
/// by one read at worst.
pub fn deinit(self: *Read) void {
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    if (self.job) |j| j.finish();
    if (self.queued) |j| j.finish();
    self.job = null;
    self.queued = null;
}

// -------------------------------------------------------------------------
// Tests (win32 lane: they run real pooled workers)
// -------------------------------------------------------------------------

const testing = std.testing;

/// A window handle nothing owns: the completion post fails (and says so), and
/// the test collects the job with `complete` the way the post would have.
fn fakeHwnd() w32.HWND {
    return @ptrFromInt(0x10);
}

test "without a window nothing is started and the caller reads inline" {
    var r = Read.init(testing.allocator);
    defer r.deinit();
    try testing.expect(!r.request("C:\\a.md", .markdown, 1));
    try testing.expect(!r.busy());
}

test "a read runs on the worker and comes back with its generation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "doc.md", .data = "# Worker" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "doc.md");
    defer testing.allocator.free(path);

    var r = Read.init(testing.allocator);
    defer r.deinit();
    r.attach(fakeHwnd(), 0);
    try testing.expect(r.request(path, .markdown, 7));
    const job = r.complete() orelse return error.TestExpectedJob;
    defer job.finish();
    try testing.expectEqual(@as(u64, 7), job.generation);
    try testing.expectEqual(@as(usize, 8), job.bytes);
    try testing.expect(job.outcome == .script);
    try testing.expect(!r.busy());
}

test "a newer request replaces the one waiting behind a read in flight" {
    var r = Read.init(testing.allocator);
    defer r.deinit();
    r.attach(fakeHwnd(), 0);
    try testing.expect(r.request("Z:\\missing\\one.md", .markdown, 1));
    try testing.expect(r.request("Z:\\missing\\two.md", .markdown, 2));
    try testing.expect(r.request("Z:\\missing\\three.md", .markdown, 3));
    // The first was already out; the second was dropped for the third.
    const first = r.complete() orelse return error.TestExpectedJob;
    defer first.finish();
    try testing.expectEqual(@as(u64, 1), first.generation);
    const last = r.complete() orelse return error.TestExpectedJob;
    defer last.finish();
    try testing.expectEqual(@as(u64, 3), last.generation);
    try testing.expectEqualStrings(content.error_unreadable, last.outcome.failure);
    try testing.expect(r.complete() == null);
}

test "deinit with a read out and one waiting frees both" {
    var r = Read.init(testing.allocator);
    r.attach(fakeHwnd(), 0);
    try testing.expect(r.request("Z:\\missing\\one.md", .markdown, 1));
    try testing.expect(r.request("Z:\\missing\\two.md", .code, 2));
    r.deinit(); // testing.allocator reports any leak
    try testing.expect(!r.busy());
}
