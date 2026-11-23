//! An image viewer pane's WebKit/GDK half (T3416, Linux L9g). The rules are
//! pure and live in `viewer_image.zig` (and win32's `viewer_image.Geometry`
//! under it); this file carries them between the page and the disk.
//!
//! - **The picture is drawn by the page.** A pane in image mode is the
//!   bundled template, like markdown; `setImage` points the template's
//!   `image.js` at `ghoztty-viewer://page/__image?v=<revision>`, and the
//!   scheme handler answers that from the viewed file (`serve`).
//! - **The zoom is decided here.** The page reports what it measured and what
//!   the user did (`loaded`, `viewport`, `toggle`, `zoom_in`/`zoom_out`/
//!   `reset`, `failed`) on the `viewerTOC` handler; `onMessage` answers with
//!   `setImageTransform` from the shared geometry. Ctrl +/-/0 go through the
//!   page too (`zoomChord`), so it re-measures its viewport on the way past.
//! - **Formats WebKit cannot draw** (TIFF, HEIF; any raster it fails on) are
//!   decoded on a worker thread by GDK and served as PNG; an `.icns` serves
//!   its largest embedded PNG. A file nothing here can decode gets the
//!   template's error card, naming the gdk-pixbuf loader to install when the
//!   file is a real HEIF/AVIF container.
//! - **A reload re-decodes** (a save, `+reload`, Ctrl+R) and keeps the zoom and
//!   the scroll when the pixel size is unchanged - the Mac's `reloadFromDisk`.
//!
//! The acceptance oracle is the log: there are no pixels in the headless
//! harness, so the pane states every decision it made (`viewer image ...`),
//! and the debug steps runner's `image` step reads the same state back.
const ViewerImage = @This();

const std = @import("std");

const Viewer = @import("Viewer.zig");
const wk = @import("webkit.zig");
const rules = @import("viewer_image.zig");
const chrome = @import("viewer_chrome.zig");
const content = @import("../win32/viewer_content.zig");
const shared = @import("../win32/viewer_image.zig");
const bridge = @import("../win32/viewer_bridge.zig");

const log = std.log.scoped(.gtk_viewer);

/// Bumped by every load, so a reload is a new URL WebKit's cache has never
/// seen, and a late decode for a picture the pane moved past is recognised.
revision: u64 = 0,
/// The decoder the current revision is served by.
route: rules.Route = .browser,
/// The zoom in effect (1 = 100%), and whether it IS best-fit - which is what
/// makes a pane resize re-fit rather than keep the user's zoom.
zoom: f64 = 1,
fitting: bool = true,
/// What the page last reported.
geometry: rules.Geometry = .{},
/// The error card's title when the decoder said more than "cannot display"
/// (a missing codec). Static strings only.
failure: ?[]const u8 = null,
/// The picture a reload is replacing, until the new one has decoded.
previous: ?rules.Previous = null,
/// How many pictures this pane has had on screen (decoded and fitted); the
/// steps runner reads it.
loads: u32 = 0,

/// A fresh picture: the pane opened on it, navigated to it, or went Back to
/// it. Opens at best-fit.
pub fn start(self: *ViewerImage, v: *Viewer) void {
    const path = v.file_path orelse return v.showError(content.error_unreadable, v.current);
    self.previous = null;
    self.route = rules.route(content.extension(path));
    self.load(v, path);
}

/// The same file again (a save, `+reload`, Ctrl+R): re-decode it, keeping the
/// zoom and the scroll if it comes back at the same pixel size.
pub fn reload(self: *ViewerImage, v: *Viewer) void {
    const path = v.file_path orelse return v.showError(content.error_unreadable, v.current);
    self.previous = if (self.geometry.natural_w > 0 and self.geometry.natural_h > 0) .{
        .natural_w = self.geometry.natural_w,
        .natural_h = self.geometry.natural_h,
        .zoom = self.zoom,
        .fitting = self.fitting,
    } else null;
    // WebKit first again: an edit may have turned an undecodable file into
    // one it can draw.
    self.route = rules.route(content.extension(path));
    self.load(v, path);
}

/// Hand the page a new revision of the picture under the current route.
fn load(self: *ViewerImage, v: *Viewer, path: []const u8) void {
    const alloc = v.alloc;
    self.revision +%= 1;
    self.zoom = 1;
    self.fitting = true;
    // The viewport and scale the page measured stay: a gesture before the
    // new picture decodes still needs them. Only the picture is unknown.
    self.geometry.natural_w = 0;
    self.geometry.natural_h = 0;
    self.failure = null;
    const keep = if (self.previous) |p| !p.fitting else false;
    const src = rules.url(alloc, self.revision) catch return;
    defer alloc.free(src);
    const ext = content.extension(path);
    const js = rules.setImageCall(alloc, src, std.fs.path.basename(path), rules.isVector(ext), keep) catch return;
    defer alloc.free(js);
    log.info("viewer image load rev={d} route={s} keep={} path={s}", .{ self.revision, @tagName(self.route), keep, path });
    v.runQuiet(js);
}

/// Act on one `image` message from the page (win32's `applyImageMessage`).
pub fn onMessage(self: *ViewerImage, v: *Viewer, msg: bridge.Image) void {
    // The bridge is open to any page: a picture message from a pane that is
    // not showing one has nothing to answer.
    if (v.mode != .image) return;

    if (msg.event == .failed) {
        const path = v.file_path orelse "";
        if (rules.fallback(self.route, content.extension(path))) |next| {
            log.info("viewer image retry rev={d} route={s}", .{ self.revision, @tagName(next) });
            self.route = next;
            return self.load(v, path);
        }
        self.previous = null;
        log.info("viewer image failed rev={d} route={s} card={s}", .{ self.revision, @tagName(self.route), self.failure orelse content.error_not_image });
        return v.showError(self.failure orelse content.error_not_image, path);
    }

    // The page always sends what it knows; a zero natural size is a gesture
    // message, not a picture that shrank to nothing.
    var geom = self.geometry;
    if (msg.natural_w > 0 and msg.natural_h > 0) {
        geom.natural_w = msg.natural_w;
        geom.natural_h = msg.natural_h;
        geom.kind = if (msg.vector) .vector else .raster;
    }
    if (msg.viewport_w > 0 and msg.viewport_h > 0) {
        geom.viewport_w = msg.viewport_w;
        geom.viewport_h = msg.viewport_h;
    }
    if (msg.dpr > 0) geom.dpr = msg.dpr;
    self.geometry = geom;

    const zoom = switch (msg.event) {
        // A fresh picture opens at best-fit; a reload of the same pixel size
        // keeps the zoom the user had chosen.
        .loaded => keep: {
            const kept = rules.keptZoom(self.previous, geom);
            self.previous = null;
            break :keep kept orelse geom.fitZoom();
        },
        // A resize re-fits a fitted picture and keeps a chosen zoom - still
        // re-derived, because a scale change moves what 100% means.
        .viewport => if (self.fitting) geom.fitZoom() else geom.clamp(self.zoom),
        .toggle => geom.doubleClickZoom(self.zoom),
        .zoom_in => geom.stepped(self.zoom, .zoom_in),
        .zoom_out => geom.stepped(self.zoom, .zoom_out),
        .reset => geom.stepped(self.zoom, .reset),
        .failed => unreachable,
    };
    self.zoom = zoom;
    self.fitting = geom.isFit(zoom);
    self.pushTransform(v);

    log.info(
        "viewer image rev={d} event={s} natural={d}x{d} viewport={d}x{d} dpr={d} kind={s} zoom={d:.4} fit={d:.4} fitting={} scale={d:.4}",
        .{
            self.revision,
            @tagName(msg.event),
            geom.natural_w,
            geom.natural_h,
            geom.viewport_w,
            geom.viewport_h,
            geom.dpr,
            @tagName(geom.kind),
            zoom,
            geom.fitZoom(),
            self.fitting,
            geom.cssScale(zoom),
        },
    );
    // A decoded, fitted picture is the image pane's "rendered": the test
    // seam's dump and `wait` key off it, as a document's push does.
    if (msg.event == .loaded) {
        self.loads +|= 1;
        v.finishRender(true, "");
    }
}

fn pushTransform(self: *ViewerImage, v: *Viewer) void {
    const js = content.setImageTransformCall(v.alloc, self.geometry.cssScale(self.zoom), self.fitting) catch return;
    defer v.alloc.free(js);
    v.runQuiet(js);
}

/// Ctrl +/-/0 in an image pane: the picture's zoom, not the page's (reset is
/// 100%, "Actual Size"). Routed back through the page, so there is exactly
/// one path from a request to a scale.
pub fn zoomChord(_: *ViewerImage, v: *Viewer, action: chrome.ZoomAction) void {
    v.runQuiet(rules.zoomCall(switch (action) {
        .zoom_in => .zoom_in,
        .zoom_out => .zoom_out,
        .reset => .reset,
    }));
}

/// A one-line summary for the debug steps runner's `image` step.
pub fn describe(self: *const ViewerImage, buf: []u8) []const u8 {
    const g = self.geometry;
    return std.fmt.bufPrint(buf, "rev={d} loads={d} route={s} zoom={d:.4} fitting={} fit={d:.4} natural={d}x{d} viewport={d}x{d}", .{
        self.revision,
        self.loads,
        @tagName(self.route),
        self.zoom,
        self.fitting,
        g.fitZoom(),
        g.natural_w,
        g.natural_h,
        g.viewport_w,
        g.viewport_h,
    }) catch "image ?";
}

// -------------------------------------------------------------------------
// Serving the picture
// -------------------------------------------------------------------------

/// Answer the page's request for the picture at `path`, by the current route.
pub fn serve(self: *ViewerImage, req: *wk.URISchemeRequest, path: []const u8) void {
    switch (self.route) {
        .browser => serveFile(req, path, self.revision),
        .icns => serveIcns(req, path, self.revision),
        .wic => decodeOnWorker(req, path, self.revision),
    }
}

/// The file's own bytes, streamed off disk with the MIME its extension names.
fn serveFile(req: *wk.URISchemeRequest, path: []const u8, revision: u64) void {
    const st = std.fs.cwd().statFile(path) catch return Viewer.finishNotFound(req, "cannot read");
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return Viewer.finishNotFound(req, "path too long");
    const file = wk.g_file_new_for_path(z.ptr);
    defer wk.g_object_unref(file);
    var err: ?*wk.GError = null;
    const stream = wk.g_file_read(file, null, &err) orelse {
        if (err) |e| wk.g_error_free(e);
        return Viewer.finishNotFound(req, "cannot read");
    };
    defer wk.g_object_unref(stream);
    var mbuf: [128]u8 = undefined;
    const mime = std.fmt.bufPrintZ(&mbuf, "{s}", .{content.mimeType(content.extension(path))}) catch "application/octet-stream";
    wk.webkit_uri_scheme_request_finish(req, stream, @intCast(st.size), mime.ptr);
    log.info("viewer image served rev={d} bytes={d} mime={s} route=browser", .{ revision, st.size, mime });
}

/// An icon set's largest embedded PNG. WebKit has no ICNS decoder and neither
/// has GDK, but every icon set made since macOS 10.7 stores its sizes as PNG.
fn serveIcns(req: *wk.URISchemeRequest, path: []const u8, revision: u64) void {
    const alloc = std.heap.c_allocator;
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, content.max_file_bytes) catch
        return Viewer.finishNotFound(req, "cannot read");
    defer alloc.free(bytes);
    const png = shared.icnsBestPng(bytes) orelse return Viewer.finishNotFound(req, "no PNG in this icon set");
    // The stream frees its copy with libc's `free`, which is what
    // `c_allocator` allocates with.
    const copy = alloc.dupe(u8, png) catch return Viewer.finishNotFound(req, "out of memory");
    const stream = wk.g_memory_input_stream_new_from_data(copy.ptr, @intCast(copy.len), @ptrCast(&std.c.free));
    defer wk.g_object_unref(stream);
    wk.webkit_uri_scheme_request_finish(req, stream, @intCast(copy.len), "image/png");
    log.info("viewer image served rev={d} bytes={d} mime=image/png route=icns", .{ revision, copy.len });
}

/// One host decode, off the main thread: a 12-megapixel TIFF must not freeze
/// every pane while it decodes.
const Job = struct {
    req: *wk.URISchemeRequest,
    path: [:0]u8,
    revision: u64,
    bytes: ?*wk.GBytes = null,
    codec: ?shared.Codec = null,
    decode_ms: i64 = 0,
};

fn decodeOnWorker(req: *wk.URISchemeRequest, path: []const u8, revision: u64) void {
    const alloc = std.heap.c_allocator;
    const job = alloc.create(Job) catch return Viewer.finishNotFound(req, "out of memory");
    const p = alloc.dupeZ(u8, path) catch {
        alloc.destroy(job);
        return Viewer.finishNotFound(req, "out of memory");
    };
    // The request outlives this call: it is finished from the main loop once
    // the worker is done.
    _ = wk.g_object_ref(req);
    job.* = .{ .req = req, .path = p, .revision = revision };
    const t = std.Thread.spawn(.{}, decodeJob, .{job}) catch {
        log.warn("viewer image: no worker thread; decoding {s} here", .{path});
        decodeJob(job);
        return;
    };
    t.detach();
}

fn decodeJob(job: *Job) void {
    const t0 = std.time.milliTimestamp();
    var err: ?*wk.GError = null;
    if (wk.gdk_texture_new_from_filename(job.path.ptr, &err)) |tex| {
        job.bytes = wk.gdk_texture_save_to_png_bytes(tex);
        wk.g_object_unref(tex);
    } else {
        if (err) |e| {
            log.info("viewer image: GDK cannot decode {s}: {s}", .{ job.path, std.mem.span(e.message orelse "?") });
            wk.g_error_free(e);
        }
        // Name the codec only for a real HEIF/AVIF container: a corrupt or
        // misnamed file gets the generic card, never "go install X".
        var head: [32]u8 = undefined;
        const n = readHead(job.path, &head);
        job.codec = shared.missingCodec(head[0..n]);
    }
    job.decode_ms = std.time.milliTimestamp() - t0;
    // GLib's idle queue is thread-safe: the request is finished on the main
    // loop, which is the only thread WebKit may be called from.
    _ = wk.g_idle_add(&finishJob, job);
}

fn readHead(path: []const u8, buf: []u8) usize {
    const f = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer f.close();
    return f.readAll(buf) catch 0;
}

fn finishJob(data: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(data orelse return 0));
    const alloc = std.heap.c_allocator;
    defer {
        wk.g_object_unref(job.req);
        alloc.free(job.path);
        alloc.destroy(job);
    }
    if (job.bytes) |b| {
        defer wk.g_bytes_unref(b);
        const stream = wk.g_memory_input_stream_new_from_bytes(b);
        defer wk.g_object_unref(stream);
        const size = wk.g_bytes_get_size(b);
        wk.webkit_uri_scheme_request_finish(job.req, stream, @intCast(size), "image/png");
        log.info("viewer image served rev={d} bytes={d} mime=image/png route=wic decode_ms={d}", .{ job.revision, size, job.decode_ms });
        return 0;
    }
    // The card the page's `failed` will put up: titled with the loader to
    // install when that is what is missing. Only for the revision the pane
    // is still on - a superseded decode says nothing.
    if (Viewer.fromWebView(wk.webkit_uri_scheme_request_get_web_view(job.req))) |v| {
        if (v.mode == .image and v.image.revision == job.revision) {
            if (job.codec) |c| v.image.failure = rules.codecTitle(c);
        }
    }
    log.info("viewer image decode failed rev={d} codec={s} decode_ms={d}", .{ job.revision, if (job.codec) |c| @tagName(c) else "-", job.decode_ms });
    Viewer.finishNotFound(job.req, "cannot decode this image");
    return 0;
}
