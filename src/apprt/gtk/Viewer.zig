//! A viewer: one WebKitGTK web view showing a markdown or code file through
//! the bundled template, a local `.html` file as a page, or a website
//! (T3410, Linux L9a - the foundation the viewer-pane cards build on).
//!
//! The Mac's `ViewerView` translated to WebKitGTK, which is the same engine:
//!
//! - **Template modes** (markdown, code) load `ghoztty-viewer://page/viewer.html`
//!   and, once it has finished loading, push the file's bytes in through
//!   `window.__viewer.setMarkdown` / `setCode` - the same page calls win32
//!   builds (`viewer_document.zig`), in UTF-8 because that is what
//!   `webkit_web_view_evaluate_javascript` takes.
//! - **A `.html` file** loads as a page from `ghoztty-page://page/<rel>`, whose
//!   grant is the file's own directory (`viewer_scheme.zig`).
//! - **A website** is navigated to directly.
//! - Images and diffs are their own cards (T3416, T3417); until they land a
//!   pane in those modes shows the template's error card naming the card.
//!
//! A viewer PANE is a `Surface` that hosts one of these in place of its
//! terminal (T3411), so it splits, resizes, focuses, zooms and closes through
//! the split tree's own code. What this file does NOT do yet, by design:
//! chrome and keys (T3412), reload (T3413), find (T3414), link routing
//! (T3415). It is a widget and a lifecycle, nothing else.
//!
//! The scheme handlers are registered on WebKit's default context once per
//! process; a request finds its viewer through the web view it came from
//! (`g_object_get_data`), so any number of viewers share them.
const Viewer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const internal_os = @import("../../os/main.zig");

const wk = @import("webkit.zig");
const scheme = @import("viewer_scheme.zig");
const content = @import("../win32/viewer_content.zig");
const document = @import("../win32/viewer_document.zig");

const log = std.log.scoped(.gtk_viewer);

/// The `g_object_set_data` key a web view carries its viewer under.
const data_key = "ghoztty-viewer";

alloc: Allocator,
view: *wk.WebView,
mode: content.Mode,
/// What the viewer was opened on, as given.
location: [:0]u8,
/// The file behind a file mode; null for a website.
file_path: ?[]u8 = null,
/// The read grant both schemes resolve against.
assets_dir: ?[]u8 = null,
base_dir: ?[]u8 = null,

/// Called once the content is on screen: a template mode's page call has
/// run, or a page/website finished loading. `ok` is false when the load
/// failed. Test hook and future chrome both hang off it.
on_rendered: ?*const fn (*Viewer, ok: bool, detail: []const u8) void = null,
user_data: ?*anyopaque = null,
rendered: bool = false,

/// Make a viewer for `location` and start loading it. The returned viewer is
/// owned by its web view: it is freed when the widget is destroyed.
pub fn create(alloc: Allocator, location: []const u8) !*Viewer {
    registerSchemes();

    const self = try alloc.create(Viewer);
    errdefer alloc.destroy(self);
    const loc = try alloc.dupeZ(u8, location);
    errdefer alloc.free(loc);

    const w = wk.webkit_web_view_new();
    self.* = .{
        .alloc = alloc,
        .view = wk.asWebView(w),
        .mode = content.modeFor(location),
        .location = loc,
    };

    if (self.mode.isFile()) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (content.filePath(&buf, location)) |p| {
            self.file_path = alloc.dupe(u8, p) catch null;
            if (std.fs.path.dirname(p)) |d| self.base_dir = alloc.dupe(u8, d) catch null;
        }
    }
    self.assets_dir = findAssetsDir(alloc);

    // DEBUG-ONLY test seam: with `GHOZTTY_TEST_VIEWER_DUMP` set, every
    // viewer - a pane's too (T3411) - writes its probe result there once it
    // has rendered. Headless Weston has no pixels to read back; the page is.
    if (comptime build_config.is_debug) {
        if (std.posix.getenv("GHOZTTY_TEST_VIEWER_DUMP") != null) self.on_rendered = &onTestRendered;
    }

    wk.g_object_set_data(w, data_key, self);
    _ = wk.g_signal_connect_data(w, "load-changed", @ptrCast(&onLoadChanged), self, null, 0);
    _ = wk.g_signal_connect_data(w, "load-failed", @ptrCast(&onLoadFailed), self, null, 0);
    _ = wk.g_signal_connect_data(w, "destroy", @ptrCast(&onDestroy), self, null, 0);

    self.load();
    return self;
}

/// The web view as a GTK widget, for whatever container holds it.
pub fn widget(self: *const Viewer) *wk.GtkWidget {
    return wk.asWidget(self.view);
}

/// What `+list` reports as the pane's `url` (T3411): the page a website pane
/// is on NOW (it may have navigated), else the file it shows, else the
/// location it was opened with.
pub fn currentLocation(self: *const Viewer) []const u8 {
    if (self.mode == .web) if (wk.webkit_web_view_get_uri(self.view)) |u| {
        const s = std.mem.span(u);
        if (s.len > 0) return s;
    };
    return self.file_path orelse self.location;
}

/// The pane's title: the file's name, a website's host, a diff's subject
/// (win32's `initialTitle`, the Mac's `mode.title`). Borrowed from the viewer.
pub fn paneTitle(self: *const Viewer) []const u8 {
    return content.initialTitle(self.mode, self.location, self.file_path);
}

fn deinit(self: *Viewer) void {
    const alloc = self.alloc;
    alloc.free(self.location);
    if (self.file_path) |p| alloc.free(p);
    if (self.assets_dir) |p| alloc.free(p);
    if (self.base_dir) |p| alloc.free(p);
    alloc.destroy(self);
}

/// `<resources>/viewer`, the bundled template the build installs beside the
/// app (`share/ghostty/viewer`). Resolved once per viewer, not per request.
fn findAssetsDir(alloc: Allocator) ?[]u8 {
    var dirs = internal_os.resourcesDir(alloc) catch return null;
    defer dirs.deinit(alloc);
    const dir = dirs.app() orelse {
        log.warn("no bundled viewer assets found; file viewers will not render", .{});
        return null;
    };
    return std.fs.path.join(alloc, &.{ dir, "viewer" }) catch null;
}

fn load(self: *Viewer) void {
    switch (self.mode) {
        .web => wk.webkit_web_view_load_uri(self.view, self.location.ptr),
        .html => {
            const path = self.file_path orelse return self.fail("Cannot read file", self.location);
            const root = self.base_dir orelse return self.fail("Cannot read file", path);
            const url = scheme.pageUrl(self.alloc, root, path) catch null;
            const u = url orelse return self.fail("Cannot read file", path);
            defer self.alloc.free(u);
            wk.webkit_web_view_load_uri(self.view, u.ptr);
        },
        .markdown, .code, .image, .diff => wk.webkit_web_view_load_uri(self.view, scheme.template_url),
    }
}

/// The template finished loading: put the document on it.
fn renderTemplate(self: *Viewer) void {
    switch (self.mode) {
        .markdown, .code => {
            const path = self.file_path orelse return self.showError(content.error_unreadable, self.location);
            const out = document.readUtf8(self.alloc, self.mode, path);
            defer out.deinit(self.alloc);
            switch (out) {
                .script => |js| self.evaluate(js),
                .failure => |title| self.showError(title, path),
                .none => self.finishRender(true, ""),
            }
        },
        .image => self.showError("Image viewer panes are not on Linux yet (T3416)", self.location),
        .diff => self.showError("Diff viewer panes are not on Linux yet (T3417)", self.location),
        .web, .html => unreachable,
    }
}

fn showError(self: *Viewer, title: []const u8, detail: []const u8) void {
    const js = content.setErrorCall(self.alloc, title, detail) catch return self.finishRender(false, title);
    defer self.alloc.free(js);
    self.evaluate(js);
}

/// A failure before anything could load: there is no page to put a card on.
fn fail(self: *Viewer, title: []const u8, detail: []const u8) void {
    log.warn("viewer: {s}: {s}", .{ title, detail });
    self.finishRender(false, title);
}

fn evaluate(self: *Viewer, js: []const u8) void {
    wk.webkit_web_view_evaluate_javascript(
        self.view,
        js.ptr,
        @intCast(js.len),
        null,
        null,
        null,
        &onRenderEvaluated,
        self,
    );
}

fn onRenderEvaluated(source: ?*wk.GObject, result: *wk.GAsyncResult, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    var err: ?*wk.GError = null;
    const value = wk.webkit_web_view_evaluate_javascript_finish(@ptrCast(source orelse return), result, &err);
    if (value) |v| wk.g_object_unref(v);
    if (err) |e| {
        defer wk.g_error_free(e);
        const msg = std.mem.span(e.message orelse "script failed");
        log.warn("viewer: page call failed: {s}", .{msg});
        return self.finishRender(false, msg);
    }
    self.finishRender(true, "");
}

fn finishRender(self: *Viewer, ok: bool, detail: []const u8) void {
    if (self.rendered) return;
    self.rendered = true;
    if (self.on_rendered) |cb| cb(self, ok, detail);
}

fn onLoadChanged(view: *wk.WebView, event: wk.LoadEvent, ud: ?*anyopaque) callconv(.c) void {
    _ = view;
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    if (event != .finished) return;
    if (self.mode.usesTemplate()) {
        // Only the template's own load; a later navigation (a link, T3415)
        // is not a fresh render.
        if (!self.rendered) self.renderTemplate();
    } else self.finishRender(true, "");
}

fn onLoadFailed(
    view: *wk.WebView,
    event: wk.LoadEvent,
    failing_uri: [*:0]const u8,
    err: *wk.GError,
    ud: ?*anyopaque,
) callconv(.c) c_int {
    _ = view;
    _ = event;
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return 0));
    const msg = std.mem.span(err.message orelse "load failed");
    log.warn("viewer: load failed uri={s} err={s}", .{ failing_uri, msg });
    self.finishRender(false, msg);
    // Let WebKit show its own error page.
    return 0;
}

fn onDestroy(view: *wk.WebView, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    wk.g_object_set_data(view, data_key, null);
    self.deinit();
}

// -------------------------------------------------------------------------
// The scheme handlers
// -------------------------------------------------------------------------

var schemes_registered: bool = false;

/// Register both schemes on WebKit's default context, once per process.
/// Registering one twice is a GLib critical, and every viewer shares them.
fn registerSchemes() void {
    if (schemes_registered) return;
    schemes_registered = true;
    prepareWebProcessEnv();
    const ctx = wk.webkit_web_context_get_default();
    wk.webkit_web_context_register_uri_scheme(ctx, scheme.template_scheme, &onSchemeRequest, null, null);
    wk.webkit_web_context_register_uri_scheme(ctx, scheme.page_scheme, &onSchemeRequest, null, null);
    // Local: a website in another pane cannot load (and so cannot probe for)
    // anything these schemes serve. Secure: the pages are secure contexts, as
    // the Mac's custom-scheme pages are.
    const sm = wk.webkit_web_context_get_security_manager(ctx);
    inline for (.{ scheme.template_scheme, scheme.page_scheme }) |s| {
        wk.webkit_security_manager_register_uri_scheme_as_local(sm, s);
        wk.webkit_security_manager_register_uri_scheme_as_secure(sm, s);
    }
}

/// Keep WSLg's GPU driver choice away from WebKit's web processes.
///
/// `GALLIUM_DRIVER=d3d12` is how Mesa reaches the GPU under WSLg (T3350): the
/// driver talks to `/dev/dxg` and loads from `/usr/lib/wsl/lib`. WebKit runs
/// its web processes inside a bubblewrap sandbox that exposes neither, so a
/// web process that inherits the override cannot create its EGL display and
/// aborts (`Could not create surfaceless EGL display: EGL_NOT_INITIALIZED`)
/// before a page ever loads - measured 2026-11-22, and it renders the moment
/// the variable is unset, with the sandbox left on. Disabling the sandbox
/// would also work and is not an option.
///
/// The app's own renderer still wants the GPU, so GDK's GL is brought up
/// FIRST (`gdk_display_prepare_gl` is a no-op once it is up): Mesa reads the
/// override when the display's EGL is initialized, and every later context
/// reuses that display. Only then is the variable removed, before the first
/// web view can spawn a web process - which is also T3350's own rule that the
/// override must not leak into what the app spawns. Only the d3d12 value is
/// touched; any other override is the user's and is left alone.
fn prepareWebProcessEnv() void {
    const value = std.posix.getenv("GALLIUM_DRIVER") orelse return;
    if (!std.mem.eql(u8, value, "d3d12")) return;
    if (wk.gdk_display_get_default()) |display| {
        var err: ?*wk.GError = null;
        if (wk.gdk_display_prepare_gl(display, &err) == 0) {
            if (err) |e| {
                log.warn("viewer: GDK GL not available before the web process starts: {s}", .{std.mem.span(e.message orelse "?")});
                wk.g_error_free(e);
            }
        }
    }
    _ = internal_os.unsetenv("GALLIUM_DRIVER");
    log.info("viewer: GALLIUM_DRIVER=d3d12 kept from WebKit's sandboxed web processes (the app's GL already chose its driver)", .{});
}

fn onSchemeRequest(req: *wk.URISchemeRequest, _: ?*anyopaque) callconv(.c) void {
    const uri = std.mem.span(wk.webkit_uri_scheme_request_get_uri(req));
    const view = wk.webkit_uri_scheme_request_get_web_view(req);
    const self: *Viewer = @ptrCast(@alignCast(wk.g_object_get_data(view, data_key) orelse
        return finishNotFound(req, "no viewer owns this web view")));
    self.serve(req, uri) catch |err| {
        log.warn("viewer: serving {s} failed err={}", .{ uri, err });
        finishNotFound(req, "cannot read");
    };
}

fn serve(self: *Viewer, req: *wk.URISchemeRequest, uri: []const u8) !void {
    const origin = scheme.originOf(uri) orelse return finishNotFound(req, "not a viewer URI");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = scheme.requestPath(&buf, origin, uri) orelse return finishNotFound(req, "empty path");

    var cands = try scheme.candidates(self.alloc, origin, .{
        .assets_dir = self.assets_dir,
        .base_dir = self.base_dir,
    }, rel);
    defer cands.deinit(self.alloc);

    for (cands.slice()) |path| {
        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();
        const stat = file.stat() catch continue;
        if (stat.kind != .file) continue;
        const bytes = file.readToEndAlloc(std.heap.c_allocator, content.max_file_bytes) catch continue;
        // The stream owns the bytes and frees them with libc's `free`, which is
        // what `c_allocator` allocated them with.
        const stream = wk.g_memory_input_stream_new_from_data(bytes.ptr, @intCast(bytes.len), @ptrCast(&std.c.free));
        defer wk.g_object_unref(stream);
        var mime_buf: [128]u8 = undefined;
        const mime = std.fmt.bufPrintZ(&mime_buf, "{s}", .{scheme.mimeType(path)}) catch "application/octet-stream";
        wk.webkit_uri_scheme_request_finish(req, stream, @intCast(bytes.len), mime.ptr);
        return;
    }
    log.debug("viewer: no file for {s}", .{uri});
    finishNotFound(req, "not found");
}

fn finishNotFound(req: *wk.URISchemeRequest, why: [*:0]const u8) void {
    const err = wk.g_error_new_literal(wk.g_io_error_quark(), wk.io_error_not_found, why);
    defer wk.g_error_free(err);
    wk.webkit_uri_scheme_request_finish_error(req, err);
}

// -------------------------------------------------------------------------
// The debug test window (headless acceptance, test/linux/viewer-webkit.sh)
// -------------------------------------------------------------------------

/// In a debug build, `GHOZTTY_TEST_VIEWER=<location>` opens a plain window
/// holding one viewer at startup, and once it has rendered evaluates
/// `GHOZTTY_TEST_VIEWER_PROBE` (a JS expression; default the page's text) and
/// writes `OK <result>` or `FAIL <why>` to `GHOZTTY_TEST_VIEWER_DUMP`.
///
/// It predates viewer panes (T3411) and stays because the foundation is worth
/// proving on its own: that WebKit links, the schemes serve, and the page
/// renders the document, with no split tree in the way. The same shape as
/// `GHOZTTY_TEST_ASK_TO_CLOSE`: compiled out of a release.
pub fn openTestWindowFromEnv() void {
    if (comptime !build_config.is_debug) return;
    const location = std.posix.getenv("GHOZTTY_TEST_VIEWER") orelse return;
    const viewer = create(std.heap.c_allocator, location) catch |err| {
        log.warn("viewer test window: create failed err={}", .{err});
        writeDump("FAIL create");
        return;
    };
    viewer.on_rendered = &onTestRendered;
    const win = wk.gtk_window_new();
    wk.gtk_window_set_title(win, "ghoztty viewer test");
    wk.gtk_window_set_default_size(win, 800, 600);
    wk.gtk_window_set_child(win, viewer.widget());
    wk.gtk_window_present(win);
    log.info("viewer test window: opened mode={s} location={s}", .{ @tagName(viewer.mode), location });
}

fn onTestRendered(self: *Viewer, ok: bool, detail: []const u8) void {
    log.info("viewer test window: rendered ok={} detail={s}", .{ ok, detail });
    if (!ok) {
        var buf: [512]u8 = undefined;
        writeDump(std.fmt.bufPrint(&buf, "FAIL {s}", .{detail}) catch "FAIL");
        return;
    }
    const probe = std.posix.getenv("GHOZTTY_TEST_VIEWER_PROBE") orelse "document.body.innerText";
    wk.webkit_web_view_evaluate_javascript(self.view, probe.ptr, @intCast(probe.len), null, null, null, &onTestProbed, self);
}

fn onTestProbed(source: ?*wk.GObject, result: *wk.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    var err: ?*wk.GError = null;
    const value = wk.webkit_web_view_evaluate_javascript_finish(@ptrCast(source orelse return), result, &err);
    if (err) |e| {
        defer wk.g_error_free(e);
        var buf: [512]u8 = undefined;
        writeDump(std.fmt.bufPrint(&buf, "FAIL probe: {s}", .{std.mem.span(e.message orelse "?")}) catch "FAIL probe");
        return;
    }
    const v = value orelse return writeDump("FAIL probe: no value");
    defer wk.g_object_unref(v);
    const s = wk.jsc_value_to_string(v) orelse return writeDump("FAIL probe: not a string");
    defer wk.g_free(s);
    const alloc = std.heap.c_allocator;
    const line = std.fmt.allocPrint(alloc, "OK {s}", .{std.mem.span(s)}) catch return writeDump("FAIL oom");
    defer alloc.free(line);
    writeDump(line);
}

fn writeDump(text: []const u8) void {
    const path = std.posix.getenv("GHOZTTY_TEST_VIEWER_DUMP") orelse return;
    const f = std.fs.createFileAbsolute(path, .{}) catch |err| {
        log.warn("viewer test window: cannot write {s} err={}", .{ path, err });
        return;
    };
    defer f.close();
    f.writeAll(text) catch {};
    f.writeAll("\n") catch {};
}
