//! The GTK image viewer pane's pure half (T3416, Linux L9g).
//!
//! An image pane on Linux is win32's shape, not the Mac's: the picture is
//! drawn by the bundled template's `image.js` inside the web view, and every
//! zoom rule anyone can argue about - what 100% means, best-fit never
//! upscaling, the double-click toggle, the 1.25x step and the clamp - is
//! win32's pure `viewer_image.Geometry` (the Mac's `ViewerImageGeometry`
//! arithmetic). The Mac draws on an `NSScrollView` because AppKit hands it
//! centroid-anchored pinch and elastic edges for free; GTK has no such
//! scroller to inherit either, while WebKit's own scroll container brings
//! kinetic touchpad scrolling and overlay scrollbars - the same trade win32
//! made with WebView2 (T1183). It also keeps the nav bar, history, the
//! address, `+list`'s url and the error card working with no new machinery.
//!
//! What this file adds on top of the shared rules is only what differs on
//! this platform:
//!
//! - **Where the bytes come from.** The page asks for
//!   `ghoztty-viewer://page/__image?v=<revision>` (the Mac's custom scheme,
//!   win32's sentinel name), and the scheme handler answers from the viewed
//!   file. A revision per load means a live reload is a new URL, so WebKit's
//!   memory cache can never hand back the picture from before the save.
//! - **Which decoder.** WebKitGTK draws PNG, JPEG, GIF, WebP, AVIF, BMP, ICO
//!   and SVG itself. TIFF and HEIF it does not, so - win32's `route`, read with
//!   GTK's decoder in WIC's place - those are decoded on the host through
//!   `GdkTexture` (GTK's own loaders, then gdk-pixbuf's) and served as PNG; a
//!   raster WebKit fails on gets one host retry (`fallback`); an `.icns` is
//!   its largest embedded PNG (`icnsBestPng`).
//! - **The missing-codec card** says what to install on a Linux desktop.
//! - **A reload keeps the zoom** when the picture's pixel size is unchanged
//!   (`keptZoom`, shared with win32 since T3532): the Mac's `reloadFromDisk`.
//!
//! No GTK, no WebKit, no filesystem: it runs in the none lane on every seat.
//! `ViewerImage.zig` is the half that talks to WebKit, GDK and the disk.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const shared = @import("../win32/viewer_image.zig");
const content = @import("../win32/viewer_content.zig");
const scheme = @import("viewer_scheme.zig");

pub const Geometry = shared.Geometry;
pub const Route = shared.Route;
pub const Codec = shared.Codec;
pub const Action = shared.Action;

/// The request path the page loads its picture from. A file the viewed
/// document's folder happens to hold under this name is shadowed, exactly as
/// on win32 (`viewer_content.image_resource_path`).
pub const resource = "__image";

/// Whether a template request names the picture rather than a file.
pub fn isResource(rel: []const u8) bool {
    return std.mem.eql(u8, rel, resource);
}

/// `ghoztty-viewer://page/__image?v=<revision>`. Caller owns the result.
pub fn url(alloc: Allocator, revision: u64) Allocator.Error![:0]u8 {
    return std.fmt.allocPrintSentinel(alloc, scheme.template_origin ++ "/" ++ resource ++ "?v={d}", .{revision}, 0);
}

/// Which decoder a file of this extension goes to first. win32's table read
/// on this platform: `.browser` is WebKit, `.wic` is the host decoder
/// (`GdkTexture`), `.icns` the largest embedded PNG.
pub fn route(ext: []const u8) Route {
    return shared.route(ext);
}

/// The second chance after WebKit could not draw what it was served: one host
/// decode for a raster, nothing for vector art or an already-host route.
pub fn fallback(current: Route, ext: []const u8) ?Route {
    return shared.fallback(current, ext);
}

/// Vector art has no pixel grid, so its 100% is its intrinsic size.
pub fn isVector(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, "svg");
}

/// The error card's title when the host decoder failed on a file that IS a
/// HEIF or AVIF container: name the gdk-pixbuf loader to install, by the name
/// a package manager shows (Debian/Ubuntu and Fedora both ship them under
/// these names). A file that is merely corrupt gets the generic card -
/// `shared.missingCodec` only answers for a real container.
pub fn codecTitle(codec: Codec) []const u8 {
    return switch (codec) {
        .heif => "Linux needs a HEIF image loader (heif-gdk-pixbuf) to show this image",
        .av1 => "Linux needs an AVIF image loader (libavif-gdk-pixbuf) to show this image",
    };
}

/// What a reload remembers of the picture it is replacing, and the zoom a
/// same-size reload keeps: win32's rules (T3532), one copy for both ports.
pub const Previous = shared.Previous;
pub const keptZoom = shared.keptZoom;

/// `window.__viewer.imageZoom("<action>")`: a keyboard chord routed through
/// the page, so it re-measures its viewport on the way past (win32's
/// `imageZoomChord`). Static strings: there is nothing to escape.
pub fn zoomCall(action: Action) [:0]const u8 {
    return switch (action) {
        .zoom_in => "window.__viewer.imageZoom(\"zoom_in\")",
        .zoom_out => "window.__viewer.imageZoom(\"zoom_out\")",
        .reset => "window.__viewer.imageZoom(\"reset\")",
    };
}

/// `window.__viewer.setImage(url, name, vector, keep)`. `keep` asks the page
/// to hold its scroll offset for the transform that answers this load (a
/// reload that may keep the zoom); a fit answer drops it. win32's call, with
/// the sentinel the web view wants. Caller owns the result.
pub fn setImageCall(
    alloc: Allocator,
    src: []const u8,
    name: []const u8,
    vector: bool,
    keep: bool,
) Allocator.Error![:0]u8 {
    const js = try content.setImageCall(alloc, src, name, vector, keep);
    defer alloc.free(js);
    return alloc.dupeZ(u8, js);
}

// -------------------------------------------------------------------------
// Ctrl+C: the picture and its file on the clipboard (T3534)
// -------------------------------------------------------------------------
//
// The Mac's `ViewerImageSurface.copy` puts the picture and the file's URL on
// the pasteboard, as Preview does with nothing selected; win32 puts a DIB, a
// PNG and a CF_HDROP (T1872, T1909). On Linux the picture is a `GdkTexture`
// (GDK serializes it as image/png and every other format it has a saver for)
// and the file is offered twice, as the two shapes Linux readers look for:
// `text/uri-list` (RFC 2483, what a browser, an editor or a terminal drop
// reads) and `x-special/gnome-copied-files` (what Nautilus, Nemo and Caja
// read on Paste, so a paste into a file manager copies the file - the
// Explorer paste T1909 exists for).

/// The two file-list MIME types, in the order they are offered.
pub const mime_uri_list = "text/uri-list";
pub const mime_gnome_copied = "x-special/gnome-copied-files";

/// The `text/uri-list` payload for one file: the URI and a CRLF, as RFC 2483
/// spells every line. `uri` is already a `file://` URI (GLib escapes it).
/// Caller owns the result.
pub fn uriList(alloc: Allocator, uri: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\r\n", .{uri});
}

/// The `x-special/gnome-copied-files` payload: the verb, then one URI per
/// line. `copy` (never `cut`): Ctrl+C at a picture must not move the user's
/// file when they paste. Caller owns the result.
pub fn gnomeCopiedFiles(alloc: Allocator, uri: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "copy\n{s}", .{uri});
}

/// Whether the host decoder can hand the copy a picture at all. A vector has
/// no pixel size of its own and GDK has no SVG loader without librsvg's
/// gdk-pixbuf module, so an SVG is tried and may fail; every raster the pane
/// shows is decodable by the route that showed it.
pub fn copyDecodes(r: Route) enum { file, icns } {
    return switch (r) {
        .icns => .icns,
        .browser, .wic => .file,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "T3534: the file goes on as a uri-list line and a gnome copy, never a cut" {
    const uri = "file:///home/u/My%20Pictures/a.png";
    const list = try uriList(testing.allocator, uri);
    defer testing.allocator.free(list);
    try testing.expectEqualStrings("file:///home/u/My%20Pictures/a.png\r\n", list);
    const gnome = try gnomeCopiedFiles(testing.allocator, uri);
    defer testing.allocator.free(gnome);
    try testing.expectEqualStrings("copy\nfile:///home/u/My%20Pictures/a.png", gnome);
    try testing.expect(!std.mem.startsWith(u8, gnome, "cut"));
}

test "T3534: an icon set copies its embedded PNG, everything else its file" {
    try testing.expectEqual(.icns, copyDecodes(.icns));
    try testing.expectEqual(.file, copyDecodes(.browser));
    try testing.expectEqual(.file, copyDecodes(.wic));
}

test "url: the template origin's sentinel, one revision per load" {
    const alloc = testing.allocator;
    const a = try url(alloc, 1);
    defer alloc.free(a);
    try testing.expectEqualStrings("ghoztty-viewer://page/__image?v=1", a);
    const b = try url(alloc, 42);
    defer alloc.free(b);
    try testing.expectEqualStrings("ghoztty-viewer://page/__image?v=42", b);

    // The scheme handler sees the sentinel with the query dropped, so it is
    // recognised whatever the revision.
    var buf: [64]u8 = undefined;
    const rel = scheme.requestPath(&buf, .template, b) orelse return error.NoPath;
    try testing.expect(isResource(rel));
    try testing.expect(!isResource("image.png"));
    try testing.expect(!isResource("vendor/__image"));
}

test "route: WebKit first, the host decoder for TIFF and HEIF, icns by its PNG" {
    for ([_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico", "svg" }) |e| {
        try testing.expectEqual(Route.browser, route(e));
    }
    for ([_][]const u8{ "tif", "TIFF", "heic", "heif" }) |e| {
        try testing.expectEqual(Route.wic, route(e));
    }
    try testing.expectEqual(Route.icns, route("icns"));
    // A raster WebKit failed on gets one host decode; vector art and a host
    // route get none.
    try testing.expectEqual(@as(?Route, .wic), fallback(.browser, "png"));
    try testing.expectEqual(@as(?Route, null), fallback(.browser, "svg"));
    try testing.expectEqual(@as(?Route, null), fallback(.wic, "tiff"));
    try testing.expect(isVector("SVG"));
    try testing.expect(!isVector("png"));
}

test "codecTitle names the loader package, never a Windows Store package" {
    try testing.expect(std.mem.indexOf(u8, codecTitle(.heif), "heif-gdk-pixbuf") != null);
    try testing.expect(std.mem.indexOf(u8, codecTitle(.av1), "libavif-gdk-pixbuf") != null);
    try testing.expect(std.mem.indexOf(u8, codecTitle(.heif), "Windows") == null);
}

test "zoomCall: one call per chord, reset is 100%" {
    try testing.expectEqualStrings("window.__viewer.imageZoom(\"zoom_in\")", zoomCall(.zoom_in));
    try testing.expectEqualStrings("window.__viewer.imageZoom(\"zoom_out\")", zoomCall(.zoom_out));
    try testing.expectEqualStrings("window.__viewer.imageZoom(\"reset\")", zoomCall(.reset));
}

test "setImageCall: win32's call with the keep flag as a fourth argument" {
    const alloc = testing.allocator;
    const js = try setImageCall(alloc, "ghoztty-viewer://page/__image?v=3", "shot \"1\".png", false, true);
    defer alloc.free(js);
    try testing.expectEqualStrings(
        "window.__viewer.setImage(\"ghoztty-viewer://page/__image?v=3\", \"shot \\\"1\\\".png\", false, true)",
        js,
    );
    const fresh = try setImageCall(alloc, "u", "logo.svg", true, false);
    defer alloc.free(fresh);
    try testing.expectEqualStrings("window.__viewer.setImage(\"u\", \"logo.svg\", true, false)", fresh);
}
