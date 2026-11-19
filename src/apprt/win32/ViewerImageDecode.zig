//! Off-UI-thread decode for the image viewer's `wic` route (T3043): a HEIC,
//! HEIF, AVIF or TIFF that Chromium cannot draw, decoded through WIC and
//! served to the page as a `.bmp`.
//!
//! **Why a worker.** The resource request arrives on the GUI thread, which is
//! the message loop every terminal pane in the window draws on. A 12-megapixel
//! phone photo takes a few hundred milliseconds to decode, and a larger TIFF
//! longer; inline, that was a frozen window for the whole of it. So the request
//! is parked on a WebView2 deferral, the decode runs on a pooled worker
//! (`worker_pool`), and the answer is built from the completion post — the
//! shape `ViewerWorktreeProbe` already uses for `git`.
//!
//! **Why one buffer.** The worker decodes straight into the HGLOBAL that becomes
//! the response stream, after the two `.bmp` headers
//! (`viewer_image.bmpHeaders`, top-down so WIC's row order is the file's). The
//! route used to read the whole source file, then hold the decoded pixels, a
//! bottom-up DIB of them, the `.bmp` wrapping the DIB and the stream's copy of
//! that — four or five copies of the picture at once, ~195 MB at 12 MP. Now it
//! is one, plus one scratch copy for a photo whose EXIF says to turn it.
//!
//! **Why a file, for anything large (T3241).** Every byte of a body answered
//! through `WebResourceRequested` costs about ten times its size inside the
//! runtime's in-process hand-off (a 48 MB picture: +459 MB of private bytes and
//! a ~110 ms GUI stall, T3223), whoever produced it. So a STAGED job has no
//! parked request at all: the worker writes the `.bmp` (or copies a large
//! picture the browser draws itself) into the pane's scratch folder, which the
//! browser process serves from disk through a folder mapping, and the pane
//! points the page at it when the completion lands.
//!
//! One worker at a time. A request arriving while one is in flight waits in
//! `queued` (the newest replaces any older one waiting, which is answered with
//! nothing: it belongs to a page load that has already been superseded).
const Decode = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const com = @import("com.zig");
const iface = @import("webview2_iface.zig");
const image_copy = @import("image_copy.zig");
const viewer_image = @import("viewer_image.zig");
const worker_pool = @import("worker_pool.zig");

const log = std.log.scoped(.viewer);

/// One parked request and, once the worker is done, its answer. The requester
/// fills the inputs, the worker fills the outputs, and the GUI thread reads
/// them only after `join` — so no field is ever touched by two threads at once.
pub const Job = struct {
    alloc: Allocator,
    /// The picture to decode. Owned.
    path: []u8,
    /// The pane's image revision when the request arrived, for the log line.
    revision: u64,
    /// The parked request: one reference, and the deferral that owes it an
    /// answer. Both are released in `finish`, which also completes the
    /// deferral — exactly once, whatever happened in between.
    args: ?*iface.ICoreWebView2WebResourceRequestedEventArgs,
    deferral: ?*iface.ICoreWebView2Deferral,

    /// The whole `.bmp`, headers and pixels, in a moveable HGLOBAL sized for
    /// `len` (the heap may round it up). Ownership passes to the response
    /// stream on success; `finish` frees one that was never handed over.
    body: ?*anyopaque = null,
    len: usize = 0,
    /// Why the decode came back empty, and the file's first bytes when no codec
    /// took it — enough for `viewer_image.missingCodec` to name the extension
    /// to install. Read from disk only on that failure, never on success.
    why: image_copy.Failure = .other,
    sniff: [32]u8 = undefined,
    sniff_len: usize = 0,
    /// For the log line: how long the decode took on the worker.
    decode_ms: u64 = 0,

    /// A staged job (T3241): what to put at `spill`. Null for a parked
    /// request, whose answer is the body above.
    stage: ?viewer_image.Stage = null,
    /// Where a staged job writes the picture. Owned.
    spill: ?[]u8 = null,
    /// The picture is complete at `spill`, `len` bytes. False when the decode
    /// or the write failed, which leaves no file behind.
    spilled: bool = false,

    /// Answer the page (whatever is already set on `args` is the answer; none
    /// means the request falls through and fails) and free everything.
    pub fn finish(self: *Job) void {
        if (self.deferral) |d| {
            if (!d.complete()) log.warn("image decode: deferral Complete failed; the picture may never arrive", .{});
            d.release();
        }
        if (self.args) |a| a.release();
        if (self.body) |b| _ = w32.GlobalFree(b);
        const alloc = self.alloc;
        if (self.spill) |p| alloc.free(p);
        alloc.free(self.path);
        alloc.destroy(self);
    }

    /// The decode itself. Blocking — runs on the worker, or inline when there
    /// is no window to post a completion to. Needs COM on the calling thread.
    pub fn run(self: *Job) void {
        const started = std.time.milliTimestamp();
        defer self.decode_ms = @intCast(@max(0, std.time.milliTimestamp() - started));
        if (self.stage == .copy) return self.copy();
        var src = image_copy.open(self.alloc, self.path, &self.why) orelse {
            if (self.why == .no_codec) self.readSniff();
            return;
        };
        defer src.deinit();

        var headers: [viewer_image.bmp_headers_len]u8 = undefined;
        const total = viewer_image.bmpHeaders(&headers, src.width(), src.height()) catch return;
        const mem = w32.GlobalAlloc(w32.GMEM_MOVEABLE, total) orelse {
            log.warn("image decode: no memory for a {d}-byte picture", .{total});
            return;
        };
        const ok = fill: {
            const dst = w32.GlobalLock(mem) orelse break :fill false;
            defer _ = w32.GlobalUnlock(mem);
            @memcpy(dst[0..headers.len], &headers);
            if (!src.copyInto(self.alloc, dst[headers.len..total])) break :fill false;
            if (self.spill) |p| self.spilled = writeFile(p, dst[0..total]);
            break :fill true;
        };
        if (!ok) {
            _ = w32.GlobalFree(mem);
            return;
        }
        self.len = total;
        // A staged decode is done with its buffer the moment the file is
        // written, so the pane holds nothing past it. One whose write failed
        // drops it too: the pane falls back to a parked request, which decodes
        // again - the failure is rare, and a second way to answer from memory
        // is not worth keeping for it.
        if (self.stage != null) {
            _ = w32.GlobalFree(mem);
            return;
        }
        self.body = mem;
    }

    /// The `copy` stage: the picture as it is, into the scratch folder.
    /// `copyFile` writes a temporary name and renames it, so the page can
    /// never load a half-written file.
    fn copy(self: *Job) void {
        const dst = self.spill orelse return;
        const cwd = std.fs.cwd();
        cwd.copyFile(self.path, cwd, dst, .{}) catch |err| {
            log.warn("image stage: cannot copy {s}: {s}", .{ self.path, @errorName(err) });
            return;
        };
        const size = (cwd.statFile(dst) catch {
            cwd.deleteFile(dst) catch {};
            return;
        }).size;
        self.len = @intCast(size);
        self.spilled = true;
    }

    /// Write a decoded `.bmp` to `path` through a temporary name and a
    /// rename, so a failure - or a page that asks early - never meets a torn
    /// picture.
    fn writeFile(path: []const u8, bytes: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = std.fmt.bufPrint(&buf, "{s}.part", .{path}) catch return false;
        const cwd = std.fs.cwd();
        const file = cwd.createFile(tmp, .{}) catch |err| {
            log.warn("image stage: cannot write {s}: {s}", .{ tmp, @errorName(err) });
            return false;
        };
        const wrote = if (file.writeAll(bytes)) true else |err| fail: {
            log.warn("image stage: cannot write {s}: {s}", .{ tmp, @errorName(err) });
            break :fail false;
        };
        file.close();
        if (wrote) {
            if (cwd.rename(tmp, path)) return true else |err| {
                log.warn("image stage: cannot rename {s}: {s}", .{ tmp, @errorName(err) });
            }
        }
        cwd.deleteFile(tmp) catch {};
        return false;
    }

    fn readSniff(self: *Job) void {
        const file = std.fs.cwd().openFile(self.path, .{}) catch return;
        defer file.close();
        self.sniff_len = file.readAll(&self.sniff) catch 0;
    }

    /// Hand the body to a stream the response can carry. The stream owns the
    /// HGLOBAL from here (`fDeleteOnRelease`); null leaves it with the job.
    pub fn takeStream(self: *Job) ?*iface.IStream {
        const mem = self.body orelse return null;
        var ptr: ?*anyopaque = null;
        if (com.failed(w32.CreateStreamOnHGlobal(mem, 1, &ptr))) return null;
        const stream: *iface.IStream = @ptrCast(@alignCast(ptr orelse return null));
        self.body = null;
        if (!stream.setSize(self.len) or !stream.rewind()) {
            stream.release();
            return null;
        }
        return stream;
    }
};

alloc: Allocator,

/// Where a completion is posted. Null until the pane has a host window; a
/// request made before then is decoded inline by the caller.
hwnd: ?w32.HWND = null,
message: u32 = 0,

thread: ?worker_pool.Thread = null,
job: ?*Job = null,
queued: ?*Job = null,

pub fn init(alloc: Allocator) Decode {
    return .{ .alloc = alloc };
}

pub fn attach(self: *Decode, hwnd: w32.HWND, message: u32) void {
    self.hwnd = hwnd;
    self.message = message;
}

/// Stage `path` into `spill` off the GUI thread (T3241): no request is parked,
/// and the pane points the page at the file when the completion lands. False
/// when there is no window to post that completion to, or no memory or thread
/// for the job; the caller then serves the picture through a request.
pub fn stageJob(
    self: *Decode,
    path: []const u8,
    revision: u64,
    how: viewer_image.Stage,
    spill: []const u8,
) bool {
    if (self.hwnd == null) return false;
    const alloc = self.alloc;
    const job = alloc.create(Job) catch return false;
    const owned = alloc.dupe(u8, path) catch {
        alloc.destroy(job);
        return false;
    };
    const spill_owned = alloc.dupe(u8, spill) catch {
        alloc.free(owned);
        alloc.destroy(job);
        return false;
    };
    job.* = .{
        .alloc = alloc,
        .path = owned,
        .revision = revision,
        .args = null,
        .deferral = null,
        .stage = how,
        .spill = spill_owned,
    };
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

/// Make a job for `path`, parking `args` on a deferral when `park` is set.
/// Null when the deferral is refused or memory runs out; the caller then
/// answers synchronously.
pub fn makeJob(
    alloc: Allocator,
    path: []const u8,
    revision: u64,
    args: *iface.ICoreWebView2WebResourceRequestedEventArgs,
    park: bool,
) ?*Job {
    const job = alloc.create(Job) catch return null;
    const owned = alloc.dupe(u8, path) catch {
        alloc.destroy(job);
        return null;
    };
    var deferral: ?*iface.ICoreWebView2Deferral = null;
    if (park) {
        deferral = args.getDeferral() orelse {
            alloc.free(owned);
            alloc.destroy(job);
            return null;
        };
        args.addRef();
    }
    job.* = .{
        .alloc = alloc,
        .path = owned,
        .revision = revision,
        .args = if (park) args else null,
        .deferral = deferral,
    };
    return job;
}

/// Park `args` and decode `path` off the GUI thread. False means nothing was
/// parked — no window yet, or the runtime refused the deferral — and the
/// caller answers synchronously instead.
pub fn request(
    self: *Decode,
    path: []const u8,
    revision: u64,
    args: *iface.ICoreWebView2WebResourceRequestedEventArgs,
) bool {
    if (self.hwnd == null) return false;
    const job = makeJob(self.alloc, path, revision, args, true) orelse return false;
    if (self.thread != null) {
        if (self.queued) |old| old.finish();
        self.queued = job;
        return true;
    }
    if (!self.start(job)) {
        // Parked already, so it is answered with nothing rather than handed
        // back: a refused spawn is the "cannot allocate a thread" state, where
        // the inline decode would only be one more allocation to fail.
        log.warn("image decode: worker could not start; {s} not served", .{path});
        job.finish();
    }
    return true;
}

fn start(self: *Decode, job: *Job) bool {
    self.job = job;
    self.thread = worker_pool.spawn(work, .{ self, job }) catch {
        self.job = null;
        return false;
    };
    return true;
}

fn work(self: *Decode, job: *Job) void {
    // WIC is free-threaded; the worker joins the process MTA for the decode
    // and leaves it again, so a parked pool thread carries no apartment.
    const hr = w32.CoInitializeEx(null, w32.COINIT_MULTITHREADED);
    defer if (!com.failed(hr)) w32.CoUninitialize();
    job.run();
    if (self.hwnd) |h| {
        if (w32.PostMessageW(h, self.message, 0, 0) == 0) {
            log.warn("image decode: completion could not be posted", .{});
        }
    }
}

/// The completion post landed on the GUI thread: the finished job, for the
/// pane to answer and then `finish`. Starts the queued request, if any.
pub fn complete(self: *Decode) ?*Job {
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    const done = self.job;
    self.job = null;
    if (self.queued) |next| {
        self.queued = null;
        if (!self.start(next)) next.finish();
    }
    return done;
}

/// Join any worker and answer every parked request with nothing. Safe from
/// any state. The join is not optional — the worker writes into a job this
/// frees — and bounds a pane close by one decode at worst.
pub fn deinit(self: *Decode) void {
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    if (self.job) |j| j.finish();
    if (self.queued) |j| j.finish();
    self.job = null;
    self.queued = null;
}
