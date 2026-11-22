//! The GTK viewer's two WebKit custom schemes, as pure path arithmetic
//! (T3410, Linux L9a).
//!
//! The Mac serves its viewer template over a WebKit custom scheme,
//! `ghoztty-viewer://page/viewer.html` (`ViewerSchemeHandler`), and WebKitGTK
//! is the same engine with the same facility
//! (`webkit_web_context_register_uri_scheme`), so the Linux viewer uses the
//! Mac's scheme and URL shape rather than win32's synthetic `https://` hosts,
//! which exist only because WebView2 has no custom schemes.
//!
//! Two origins, two grants - win32's split (T601), translated:
//!
//! - `ghoztty-viewer://page/<rel>` is the bundled template. A request resolves
//!   against the bundled assets first (`viewer.html`, `vendor/...`), then the
//!   viewed file's directory (a markdown document's relative images), then as
//!   an absolute path the document wrote itself - the Mac's three tiers, in its
//!   order. The first two refuse `..` escapes; the third is unguarded by design
//!   (`viewer_content.zig`'s header says why).
//! - `ghoztty-page://page/<rel>` is a directly rendered `.html` FILE and
//!   nothing else: its own directory, recursively, which is exactly the grant
//!   the Mac's `loadFileURL(_:allowingReadAccessTo:)` gives. It never reaches
//!   the bundled assets, so a page asking for `vendor/markdown-it.min.js` is
//!   not handed ours.
//!
//! Everything here is pure - no GTK, no WebKit, no filesystem - so it runs in
//! the none lane on every seat. `Viewer.zig` is the half that asks WebKit and
//! the disk.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const content = @import("../win32/viewer_content.zig");
const view_arg = @import("../../cli/view_arg.zig");

/// The template scheme. Same name as the Mac's `ViewerSchemeHandler.scheme`,
/// which the template's own link guard already lists (`links.js`).
pub const template_scheme = "ghoztty-viewer";

/// The rendered-page scheme (win32's `ghoztty-page` host, as a scheme).
pub const page_scheme = "ghoztty-page";

/// Both origins carry the Mac's `page` authority; WebKit hands the handler
/// the full URI and the path after it is the request.
pub const template_origin = template_scheme ++ "://page";
pub const page_origin = page_scheme ++ "://page";

/// Where a template-mode viewer navigates. The file's bytes arrive afterwards
/// through `window.__viewer`.
pub const template_url = template_origin ++ "/viewer.html";

pub const Origin = enum { template, page };

/// Which of our origins `uri` belongs to, or null when it is neither.
pub fn originOf(uri: []const u8) ?Origin {
    if (startsWithOrigin(uri, template_origin)) return .template;
    if (startsWithOrigin(uri, page_origin)) return .page;
    return null;
}

fn startsWithOrigin(uri: []const u8, origin: []const u8) bool {
    if (uri.len < origin.len) return false;
    if (!std.ascii.eqlIgnoreCase(uri[0..origin.len], origin)) return false;
    return uri.len == origin.len or uri[origin.len] == '/';
}

/// The decoded relative path a request names, written into `buf`.
/// `ghoztty-viewer://page/vendor/x.js?v=1` -> `vendor/x.js`. Null for a URI
/// that is not under `origin`, or names nothing.
pub fn requestPath(buf: []u8, origin: Origin, uri: []const u8) ?[]const u8 {
    return content.pathUnderOrigin(buf, switch (origin) {
        .template => template_origin,
        .page => page_origin,
    }, uri);
}

/// What a request may read: the bundled assets directory and the viewed
/// file's directory. Either may be missing (no assets found, a website pane).
pub const Grant = struct {
    assets_dir: ?[]const u8 = null,
    base_dir: ?[]const u8 = null,
};

/// The paths a request may resolve to, in the order they are tried. Each is
/// owned by the list; `deinit` frees them.
pub const Candidates = struct {
    buf: [3][]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Candidates) []const []u8 {
        return self.buf[0..self.len];
    }

    pub fn deinit(self: *Candidates, alloc: Allocator) void {
        for (self.buf[0..self.len]) |p| alloc.free(p);
        self.len = 0;
    }

    fn add(self: *Candidates, p: ?[]u8) void {
        const v = p orelse return;
        self.buf[self.len] = v;
        self.len += 1;
    }
};

/// The candidate files for `rel` under `origin`'s grant, in tier order. The
/// caller serves the first one that exists as a regular file.
pub fn candidates(
    alloc: Allocator,
    origin: Origin,
    grant: Grant,
    rel: []const u8,
) Allocator.Error!Candidates {
    var out: Candidates = .{};
    errdefer out.deinit(alloc);
    switch (origin) {
        .template => {
            if (grant.assets_dir) |d| out.add(try content.candidateUnder(alloc, d, rel));
            if (grant.base_dir) |d| {
                out.add(try content.candidateUnder(alloc, d, rel));
                out.add(try content.rootedCandidate(alloc, d, rel));
            }
        },
        // A rendered page's own directory and nothing else.
        .page => if (grant.base_dir) |d| out.add(try content.candidateUnder(alloc, d, rel)),
    }
    return out;
}

/// The `ghoztty-page://` URL that loads the `.html` file at `path`, whose
/// grant is `root` (its directory). Null when `path` is not under `root`.
pub fn pageUrl(alloc: Allocator, root: []const u8, path: []const u8) Allocator.Error!?[:0]u8 {
    return content.pageUrlForOrigin(alloc, page_origin, root, path);
}

/// The content type a served file goes out with - win32's table, which is
/// the Mac's plus what a real page brings with it (T750).
pub fn mimeType(path: []const u8) []const u8 {
    return content.mimeType(content.extension(path));
}

/// The location a `--view=` pane opens, as the app takes it from IPC (T3411).
///
/// The CLI already resolves a relative path against `--working-directory`
/// (else its own cwd) before it sends (`cli/view_arg.zig`), so this is the
/// server's half for a caller that spoke the socket directly: a value that
/// still reads as a relative PATH is joined onto `working_directory`, and
/// everything that names its own location passes through untouched - a URL,
/// `about:blank` (the blank browser pane), a `git-diff:`/`git-status:` spec
/// (a revspec, never a path), and an absolute path. With no working
/// directory a relative path stays as given: the app's own cwd is not the
/// caller's, and guessing it would open the wrong file.
///
/// Linux paths are POSIX, so the join is POSIX on every seat (this runs in
/// the Windows none lane too). Caller owns the result.
pub fn resolveLocation(
    alloc: Allocator,
    location: []const u8,
    working_directory: ?[]const u8,
) Allocator.Error![:0]u8 {
    const loc = std.mem.trim(u8, location, " \t\r\n");
    const relative = loc.len > 0 and
        loc[0] != '/' and
        std.mem.indexOf(u8, loc, "://") == null and
        !std.mem.startsWith(u8, loc, "about:") and
        !view_arg.isDiffView(loc);
    const wd = working_directory orelse "";
    if (!relative or wd.len == 0 or wd[0] != '/') return try alloc.dupeZ(u8, loc);
    const joined = try std.fs.path.resolvePosix(alloc, &.{ wd, loc });
    defer alloc.free(joined);
    return try alloc.dupeZ(u8, joined);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "resolveLocation: a relative path joins the working directory" {
    const a = testing.allocator;
    const r = try resolveLocation(a, "docs/README.md", "/home/u/repo");
    defer a.free(r);
    try testing.expectEqualStrings("/home/u/repo/docs/README.md", r);
    const up = try resolveLocation(a, "../x.md", "/home/u/repo");
    defer a.free(up);
    try testing.expectEqualStrings("/home/u/x.md", up);
}

test "resolveLocation: what names its own location passes through" {
    const a = testing.allocator;
    for ([_][]const u8{
        "/abs/file.md",
        "https://example.com/a?b",
        "about:blank",
        "git-diff:main...HEAD",
        "git-status:",
        "git-status",
    }) |loc| {
        const r = try resolveLocation(a, loc, "/home/u/repo");
        defer a.free(r);
        try testing.expectEqualStrings(loc, r);
    }
    // A file that merely starts like a diff scheme is still a path.
    const f = try resolveLocation(a, "git-diff-notes.md", "/w");
    defer a.free(f);
    try testing.expectEqualStrings("/w/git-diff-notes.md", f);
}

test "resolveLocation: no usable working directory leaves a relative path alone" {
    const a = testing.allocator;
    const none = try resolveLocation(a, "a.md", null);
    defer a.free(none);
    try testing.expectEqualStrings("a.md", none);
    const empty = try resolveLocation(a, "a.md", "");
    defer a.free(empty);
    try testing.expectEqualStrings("a.md", empty);
    const rel = try resolveLocation(a, "a.md", "not/absolute");
    defer a.free(rel);
    try testing.expectEqualStrings("a.md", rel);
}

/// The candidate paths come from win32's `viewer_content` helpers, which join
/// with the HOST separator: `/` on Linux, `\` when this file's tests run in a
/// Windows none lane. The expectations are written POSIX-style; compare with
/// the separator normalised so the same assertion holds on every seat.
fn expectPath(expected: []const u8, found: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (found.len > buf.len) return error.TestExpectedEqual;
    const norm = buf[0..found.len];
    for (found, 0..) |ch, i| norm[i] = if (ch == '\\') '/' else ch;
    try testing.expectEqualStrings(expected, norm);
}

test "originOf: only our two origins, and only at an origin boundary" {
    try testing.expectEqual(Origin.template, originOf("ghoztty-viewer://page/viewer.html").?);
    try testing.expectEqual(Origin.template, originOf("GHOZTTY-VIEWER://page/x").?);
    try testing.expectEqual(Origin.page, originOf("ghoztty-page://page/index.html").?);
    try testing.expect(originOf("ghoztty-viewer://pages/x") == null);
    try testing.expect(originOf("https://ghoztty-viewer/viewer.html") == null);
    try testing.expect(originOf("ghoztty-page://page.evil/x") == null);
    try testing.expect(originOf("about:blank") == null);
}

test "requestPath: decodes, drops the query, refuses the other origin" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("vendor/x.js", requestPath(&buf, .template, "ghoztty-viewer://page/vendor/x.js?v=1").?);
    try testing.expectEqualStrings("my pic.png", requestPath(&buf, .template, "ghoztty-viewer://page/my%20pic.png").?);
    try testing.expectEqualStrings("sub/app.css", requestPath(&buf, .page, "ghoztty-page://page/sub/app.css").?);
    try testing.expect(requestPath(&buf, .page, "ghoztty-viewer://page/viewer.html") == null);
    try testing.expect(requestPath(&buf, .template, "ghoztty-viewer://page/") == null);
    try testing.expect(requestPath(&buf, .template, "ghoztty-viewer://page") == null);
}

test "candidates: template tiers are assets, then the file's directory, then absolute" {
    // POSIX paths, which `std.fs.path.resolve` spells differently on a Windows
    // host; the GTK viewer only ever runs on POSIX.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var c = try candidates(alloc, .template, .{ .assets_dir = "/share/viewer", .base_dir = "/home/u/docs" }, "img/a.png");
    defer c.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), c.len);
    try expectPath("/share/viewer/img/a.png", c.slice()[0]);
    try expectPath("/home/u/docs/img/a.png", c.slice()[1]);
    try expectPath("/img/a.png", c.slice()[2]);
}

test "candidates: a .. escape is refused by both guarded tiers" {
    const alloc = testing.allocator;
    var c = try candidates(alloc, .template, .{ .assets_dir = "/share/viewer", .base_dir = "/home/u/docs" }, "../../secrets.txt");
    defer c.deinit(alloc);
    for (c.slice()) |p| {
        try testing.expect(!std.mem.startsWith(u8, p, "/share/viewer/"));
        try testing.expect(!std.mem.startsWith(u8, p, "/home/u/docs/"));
    }
}

test "candidates: a rendered page reaches its own directory only" {
    // POSIX paths, which `std.fs.path.resolve` spells differently on a Windows
    // host; the GTK viewer only ever runs on POSIX.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var ok = try candidates(alloc, .page, .{ .assets_dir = "/share/viewer", .base_dir = "/home/u/site" }, "css/app.css");
    defer ok.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), ok.len);
    try expectPath("/home/u/site/css/app.css", ok.slice()[0]);

    // Never the bundled assets, and never out of its directory.
    var esc = try candidates(alloc, .page, .{ .assets_dir = "/share/viewer", .base_dir = "/home/u/site" }, "../secrets.txt");
    defer esc.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), esc.len);
    var abs = try candidates(alloc, .page, .{ .base_dir = "/home/u/site" }, "/etc/passwd");
    defer abs.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), abs.len);
}

test "candidates: no grant, no candidates" {
    const alloc = testing.allocator;
    var c = try candidates(alloc, .template, .{}, "viewer.html");
    defer c.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), c.len);
}

test "pageUrl: round-trips through requestPath" {
    const alloc = testing.allocator;
    const url = (try pageUrl(alloc, "/home/u/my site", "/home/u/my site/sub/index page.html")).?;
    defer alloc.free(url);
    try testing.expectEqualStrings("ghoztty-page://page/sub/index%20page.html", url);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("sub/index page.html", requestPath(&buf, .page, url).?);
    try testing.expect((try pageUrl(alloc, "/home/u/site", "/elsewhere/x.html")) == null);
}

test "mimeType: the template's own files go out typed" {
    try testing.expectEqualStrings("text/html", mimeType("viewer.html"));
    try testing.expectEqualStrings("text/javascript", mimeType("vendor/markdown-it.min.js"));
    try testing.expectEqualStrings("text/css", mimeType("viewer.css"));
    try testing.expectEqualStrings("application/octet-stream", mimeType("blob"));
}
