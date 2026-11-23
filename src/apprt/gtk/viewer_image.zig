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
//!   (`keptZoom`): the Mac's `reloadFromDisk`, which win32 does not do yet.
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

/// What a reload remembers of the picture it is replacing.
pub const Previous = struct {
    natural_w: f64,
    natural_h: f64,
    zoom: f64,
    fitting: bool,
};

/// The zoom a freshly decoded picture opens at after a RELOAD, or null for
/// best-fit (the Mac's `reloadFromDisk`).
///
/// Zoom - and scroll, which the page holds on to when this answers non-null -
/// survive a reload of the SAME pixel size: the analogue of the scroll every
/// other file mode keeps across a save. A re-export at different dimensions
/// re-fits, because the old magnification describes a picture that no longer
/// exists. A picture that was fitted stays fitted, which is a re-fit anyway.
pub fn keptZoom(prev: ?Previous, geom: Geometry) ?f64 {
    const p = prev orelse return null;
    if (p.fitting) return null;
    if (@abs(p.natural_w - geom.natural_w) >= shared.epsilon) return null;
    if (@abs(p.natural_h - geom.natural_h) >= shared.epsilon) return null;
    return geom.clamp(p.zoom);
}

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
/// reload that may keep the zoom); a fit answer drops it. win32 passes three
/// arguments and the page reads the missing fourth as false. Caller owns the
/// result.
pub fn setImageCall(
    alloc: Allocator,
    src: []const u8,
    name: []const u8,
    vector: bool,
    keep: bool,
) Allocator.Error![:0]u8 {
    const three = try content.setImageCall(alloc, src, name, vector);
    defer alloc.free(three);
    return std.fmt.allocPrintSentinel(
        alloc,
        "{s}, {s})",
        .{ three[0 .. three.len - 1], if (keep) "true" else "false" },
        0,
    );
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

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

test "keptZoom: a same-size reload keeps a chosen zoom, anything else re-fits" {
    const geom: Geometry = .{ .natural_w = 4000, .natural_h = 3000, .viewport_w = 800, .viewport_h = 600 };
    // The user had stepped to 125%: same pixels, same zoom.
    try testing.expectEqual(@as(?f64, 1.25), keptZoom(.{ .natural_w = 4000, .natural_h = 3000, .zoom = 1.25, .fitting = false }, geom));
    // A fitted picture re-fits (null = fit), whatever its size.
    try testing.expectEqual(@as(?f64, null), keptZoom(.{ .natural_w = 4000, .natural_h = 3000, .zoom = 0.2, .fitting = true }, geom));
    // A re-export at another size: the old zoom describes a picture that no
    // longer exists.
    try testing.expectEqual(@as(?f64, null), keptZoom(.{ .natural_w = 4000, .natural_h = 2000, .zoom = 1.25, .fitting = false }, geom));
    try testing.expectEqual(@as(?f64, null), keptZoom(.{ .natural_w = 3999, .natural_h = 3000, .zoom = 1.25, .fitting = false }, geom));
    // No previous picture (a fresh open): fit.
    try testing.expectEqual(@as(?f64, null), keptZoom(null, geom));
    // A kept zoom is still clamped to what the pane allows.
    try testing.expectEqual(@as(?f64, 32), keptZoom(.{ .natural_w = 4000, .natural_h = 3000, .zoom = 500, .fitting = false }, geom));
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
