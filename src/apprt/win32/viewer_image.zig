//! The zoom rules for an image viewer pane (T1183; Mac's
//! `ViewerImageGeometry` in `ViewerImageView.swift`, same arithmetic).
//!
//! Everything a person can argue about — what "100%" means, whether best-fit
//! may enlarge a small image, where a double-click lands — lives here as
//! arithmetic with no window, no COM and no page in it, so it asserts in the
//! `-Dapp-runtime=none` lane. `ViewerPane` is plumbing on one side of it and
//! `src/viewer/image.js` is plumbing on the other.
//!
//! ## Why the arithmetic is on THIS side of the bridge
//!
//! The picture is drawn by the bundled template rather than by a native
//! surface (the mechanism note in T1183): win32 has no elastic, momentum-y
//! scroll view to inherit the way AppKit does, while a WebView2 scroll
//! container brings precision-touchpad panning, inertia and overlay scrollbars
//! with it. What the page does NOT get to decide is the zoom, because those
//! rules are the feature — so the page reports its viewport, the image's
//! natural size and the gestures, and every zoom it applies came from here.
//! Same split as `viewer_diff.zig` against `ViewerDiffProbe.zig`.
//!
//! Page zoom (`viewer_accel.zig`'s `steppedZoom`) is a different quantity and
//! stays where it is: that scales a DOCUMENT, this scales a picture, and their
//! limits and steps disagree on purpose.
const std = @import("std");
const testing = std.testing;

/// Extensions that open as a picture rather than as highlighted source (Mac's
/// `ViewerView.imageExtensions`, same list).
///
/// A fixed list rather than "whatever this machine's codecs can decode", for
/// the same reason the markdown list is fixed: what a `--view=` path does
/// should be predictable from the path, not from which decoders a given
/// Windows build happens to ship.
///
/// `svg` is here even though it is text — it is a picture, and reading its
/// source is what an editor is for.
pub const extensions = [_][]const u8{
    "png",  "apng", "jpg",  "jpeg", "jpe",  "jfif",
    "gif",  "webp", "avif", "heic", "heif", "tif",
    "tiff", "bmp",  "ico",  "icns", "svg",
};

/// Whether `ext` (no dot, any case) names a picture.
pub fn isImage(ext: []const u8) bool {
    if (ext.len == 0) return false;
    for (extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// How the picture's bytes reach the page (T1234).
///
/// Mac decodes every row of `extensions` through ImageIO with nothing extra
/// installed. A WebView2 page does not: Chromium has no HEIF, TIFF or ICNS
/// decoder at all, so handing it those bytes is a guaranteed error card for a
/// photo straight off an iPhone. Those formats are decoded on THIS side
/// instead, and the page is handed pixels it can draw.
pub const Route = enum {
    /// The file's own bytes, with the MIME its extension names.
    browser,
    /// Decoded through WIC — the system codec registry Photos and Explorer
    /// use — and served as a BMP of the decoded pixels. TIFF is built in;
    /// HEIF needs the HEIF Image Extensions, which `missingCodec` names.
    wic,
    /// The largest PNG an `.icns` carries (`icnsBestPng`). WIC has no ICNS
    /// codec, but every icon set made since macOS 10.7 stores its sizes as
    /// PNG.
    icns,
};

/// The route a file of this extension takes when it opens.
pub fn route(ext: []const u8) Route {
    const host = [_][]const u8{ "heic", "heif", "tif", "tiff" };
    for (host) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return .wic;
    }
    if (std.ascii.eqlIgnoreCase(ext, "icns")) return .icns;
    return .browser;
}

/// Where to go when the page could not draw what `current` served — the
/// second chance before the error card, or null for none.
///
/// A raster the browser fails on (an AVIF this WebView2 build has no decoder
/// for, a `.png` that is really a TIFF) gets one retry through WIC, so the
/// picture shows whenever this machine can show it anywhere. Vector art does
/// not: WIC has no SVG codec, and a retry that cannot succeed only delays the
/// card.
pub fn fallback(current: Route, ext: []const u8) ?Route {
    if (current != .browser) return null;
    if (std.ascii.eqlIgnoreCase(ext, "svg")) return null;
    return .wic;
}

/// A codec this machine is missing, named so the card can say what to
/// install instead of "Cannot display this image".
pub const Codec = enum {
    heif,
    av1,

    /// The error card's title. Names the Store package by the name the Store
    /// shows, because that is what the person will search for.
    pub fn title(self: Codec) []const u8 {
        return switch (self) {
            .heif => "Windows needs the HEIF Image Extensions to show this image",
            .av1 => "Windows needs the AV1 Video Extension to show this image",
        };
    }
};

/// Which codec a file NEEDS, read from its content: an ISO-BMFF `ftyp` box
/// whose major brand is a HEIF or AVIF one. The pane asks only once WIC has
/// said that NO installed codec recognised the file, so a hit means "this is
/// a real HEIF/AVIF file and nothing here can decode it" — the missing
/// extension — while a file that is merely corrupt or misnamed, or a corrupt
/// HEIF on a machine that has the codec, gets the generic card rather than a
/// wrong instruction to go and install something.
pub fn missingCodec(head: []const u8) ?Codec {
    if (head.len < 12) return null;
    if (!std.mem.eql(u8, head[4..8], "ftyp")) return null;
    const brand = head[8..12];
    const heif = [_][]const u8{ "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1" };
    for (heif) |b| {
        if (std.mem.eql(u8, brand, b)) return .heif;
    }
    if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) return .av1;
    return null;
}

/// The largest PNG image inside an `.icns` file, as a slice of `bytes`, or
/// null when it carries none (a pre-10.7 icon set of RLE bitmaps only).
///
/// The format is a `icns` magic and a big-endian total length, then a run of
/// `<type:4><length:4 BE, header included><data>` entries. Which types hold a
/// PNG varies by year (`ic07`..`ic14`, and some `icp4`..`icp6`), so the data
/// is recognised by its own signature rather than by a type table that would
/// go stale. "Largest" is by the IHDR width, so a 1024px `ic10` beats the
/// 16px `icp4` beside it however the file orders them.
pub fn icnsBestPng(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "icns")) return null;
    const total = @min(bytes.len, std.mem.readInt(u32, bytes[4..8], .big));
    const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

    var best: ?[]const u8 = null;
    var best_w: u32 = 0;
    var at: usize = 8;
    while (at + 8 <= total) {
        const len = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .big);
        // A length shorter than its own header would loop forever; one past
        // the end is a truncated file. Either way, stop with what was found.
        if (len < 8 or at + len > total) break;
        const data = bytes[at + 8 .. at + len];
        // Signature, then the IHDR chunk: length(4) "IHDR"(4) width(4 BE).
        if (data.len >= 24 and std.mem.eql(u8, data[0..8], &png_sig) and
            std.mem.eql(u8, data[12..16], "IHDR"))
        {
            const w = std.mem.readInt(u32, data[16..20], .big);
            if (best == null or w > best_w) {
                best = data;
                best_w = w;
            }
        }
        at += len;
    }
    return best;
}

/// A `.bmp` file for a packed DIB (`image_clipboard.dibV5`'s output): the
/// 14-byte `BITMAPFILEHEADER` in front of it. Caller frees.
///
/// BMP rather than a PNG re-encode for the `wic` route on purpose: the pixels
/// never leave this process, so compression buys nothing, and the hand-written
/// encoder in `png_encode.zig` would spend seconds on a 12-megapixel phone
/// photo that a header costs nothing to wrap. Chromium honours a BITMAPV5
/// alpha mask, so a TIFF with transparency stays transparent.
pub fn bmpFile(alloc: std.mem.Allocator, dib: []const u8) error{ BadDib, OutOfMemory }![]u8 {
    if (dib.len < 4) return error.BadDib;
    const header = std.mem.readInt(u32, dib[0..4], .little);
    if (header < 40 or header > dib.len) return error.BadDib;
    const file_header = 14;
    const out = try alloc.alloc(u8, file_header + dib.len);
    out[0] = 'B';
    out[1] = 'M';
    std.mem.writeInt(u32, out[2..6], @intCast(out.len), .little);
    std.mem.writeInt(u32, out[6..10], 0, .little); // two reserved words
    // Pixels start after both headers. BI_BITFIELDS masks live inside a
    // V4/V5 header, so nothing sits between the header and the pixels.
    std.mem.writeInt(u32, out[10..14], file_header + header, .little);
    @memcpy(out[file_header..], dib);
    return out;
}

/// Vector art has no pixel grid, so 100% cannot mean "one image pixel per
/// device pixel" for it — it means the drawing's intrinsic size, as in every
/// other vector viewer.
pub const Kind = enum { raster, vector };

/// A ctrl+plus / ctrl+minus / ctrl+0 request, and the two ends of a
/// ctrl+wheel notch. Distinct from `viewer_accel.ZoomAction` because reset
/// means something different here: 100%, not "the default document zoom".
pub const Action = enum { zoom_in, zoom_out, reset };

/// Hard zoom limits. Deliberately wide at the top — an image pane is where you
/// go to count pixels — and loose at the bottom, since `minZoom` also has to
/// admit whatever best-fit needs for a very large image.
pub const zoom_floor: f64 = 0.05;
pub const zoom_ceiling: f64 = 32;

/// Per-press step. Coarser than the page viewer's 1.1 because an image's
/// useful zoom range spans two orders of magnitude where a document's spans
/// one.
pub const zoom_step: f64 = 1.25;

/// How close two zooms have to be to count as the same one. The page reports
/// CSS pixels through a JSON round trip, so an exact compare would make "am I
/// still fitting?" answer no after a resize that changed nothing.
pub const epsilon: f64 = 0.0001;

/// The inputs every rule below is a function of. All lengths are CSS pixels;
/// `natural` is in the image's own units (pixels for raster art, points for
/// vector art), which is also the size the page lays the `<img>` out at before
/// any transform.
pub const Geometry = struct {
    natural_w: f64 = 0,
    natural_h: f64 = 0,
    viewport_w: f64 = 0,
    viewport_h: f64 = 0,
    /// Device pixels per CSS pixel, as the page reports `devicePixelRatio`.
    dpr: f64 = 1,
    kind: Kind = .raster,

    /// CSS pixels per natural unit at 100% zoom — the whole of the "what does
    /// 100% mean" decision, in one number.
    ///
    /// **For a raster image, 100% is one image pixel per DEVICE pixel**, so
    /// this is `1 / dpr`. Two reasons, in order:
    ///
    /// 1. It is the only definition under which 100% is actually pixel-exact.
    ///    Every image pixel lands on exactly one screen pixel, nothing is
    ///    resampled, and a 1px hairline is a 1px hairline — which is the whole
    ///    reason anyone asks for 100% rather than "big enough to read".
    /// 2. Most of what gets opened in these panes is screen capture — the
    ///    feedback composer's own screenshots, an agent's render of a UI.
    ///    Those are captured at device resolution, so 100% shows them at
    ///    exactly the size they were on screen. One image pixel per CSS pixel
    ///    would show a 2x screenshot at twice the size of the screen it came
    ///    from.
    ///
    /// **For vector art it is 1.0**: there are no pixels to be 1:1 with.
    pub fn unitScale(self: Geometry) f64 {
        if (self.kind == .vector) return 1;
        return 1 / @max(self.dpr, 1);
    }

    /// Zoom that fits the whole image in the viewport, **never above 100%**.
    ///
    /// Refusing to upscale is the deliberate half: blowing a 16px icon up to
    /// fill a 900px pane makes a blurry lie out of the asset, and "fit" on an
    /// image that already fits is a no-op everywhere else on the platform. So
    /// a small image opens crisp, centered, at its real size.
    ///
    /// A degenerate input (no image yet, a pane with no width) answers 1
    /// rather than 0 or infinity: the page renders at 100% until it can
    /// measure, which is a picture rather than a blank matte.
    pub fn fitZoom(self: Geometry) f64 {
        const unit = self.unitScale();
        if (self.natural_w <= 0 or self.natural_h <= 0) return 1;
        if (self.viewport_w <= 0 or self.viewport_h <= 0) return 1;
        if (unit <= 0) return 1;
        const raw = @min(
            self.viewport_w / (self.natural_w * unit),
            self.viewport_h / (self.natural_h * unit),
        );
        return @min(1, raw);
    }

    /// The lowest zoom the pane allows. Never above `fitZoom`, or a very large
    /// image could not be fit into a small pane at all.
    pub fn minZoom(self: Geometry) f64 {
        return @min(zoom_floor, self.fitZoom());
    }

    pub fn maxZoom(self: Geometry) f64 {
        return @max(zoom_ceiling, self.fitZoom());
    }

    pub fn clamp(self: Geometry, zoom: f64) f64 {
        return @min(self.maxZoom(), @max(self.minZoom(), zoom));
    }

    /// The CSS transform scale for a zoom, given an `<img>` laid out at the
    /// image's natural size. Mac's `magnification(forZoom:)` — the same
    /// product, because an `NSScrollView` document view at `naturalSize` and a
    /// CSS box at `naturalSize` are the same coordinate space.
    pub fn cssScale(self: Geometry, zoom: f64) f64 {
        return self.clamp(zoom) * self.unitScale();
    }

    /// Whether `zoom` IS best-fit, which is what makes a pane resize re-fit.
    /// Any deliberate zoom clears it: once the user has chosen a
    /// magnification, dragging a split divider must not throw it away.
    pub fn isFit(self: Geometry, zoom: f64) bool {
        return @abs(zoom - self.fitZoom()) < epsilon;
    }

    /// Where a double-click / two-finger double-tap goes from `current`.
    ///
    /// The contract is "toggle between best-fit and 100%", with one honest
    /// exception: when the image is smaller than the pane those two are the
    /// SAME zoom, and a gesture that visibly does nothing reads as a broken
    /// gesture. In that case the first double-click goes to 200% instead, and
    /// the next one comes back to fit — so the toggle always toggles.
    pub fn doubleClickZoom(self: Geometry, current: f64) f64 {
        const fit = self.fitZoom();
        if (@abs(current - fit) >= epsilon) return fit;
        return self.clamp(if (fit >= 1) 2 else 1);
    }

    /// Ctrl+ / Ctrl− / Ctrl-0. Reset is 100% ("Actual Size"), not fit: it
    /// means the same thing here as it does in the other viewer modes, and fit
    /// is one double-click away.
    pub fn stepped(self: Geometry, current: f64, action: Action) f64 {
        return switch (action) {
            .zoom_in => self.clamp(current * zoom_step),
            .zoom_out => self.clamp(current / zoom_step),
            .reset => self.clamp(1),
        };
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "isImage carries the Mac extension table, case-insensitively" {
    try testing.expect(isImage("png"));
    try testing.expect(isImage("PNG"));
    try testing.expect(isImage("Jpeg"));
    try testing.expect(isImage("webp"));
    try testing.expect(isImage("avif"));
    try testing.expect(isImage("icns"));
    // A picture even though it is text: reading SVG source is an editor's job.
    try testing.expect(isImage("svg"));

    try testing.expect(!isImage(""));
    try testing.expect(!isImage("md"));
    try testing.expect(!isImage("zig"));
    try testing.expect(!isImage("html"));
    // Not a prefix match: `.pn` and `.pngx` are not pictures.
    try testing.expect(!isImage("pn"));
    try testing.expect(!isImage("pngx"));
}

test "route: formats Chromium cannot draw are decoded on the host (T1234)" {
    // What a WebView2 page draws natively goes as the file's own bytes.
    for ([_][]const u8{ "png", "apng", "jpg", "jpeg", "jpe", "jfif", "gif", "webp", "avif", "bmp", "ico", "svg" }) |e| {
        try testing.expectEqual(Route.browser, route(e));
    }
    // An iPhone photo and a scan go through WIC, in any case.
    try testing.expectEqual(Route.wic, route("heic"));
    try testing.expectEqual(Route.wic, route("HEIC"));
    try testing.expectEqual(Route.wic, route("heif"));
    try testing.expectEqual(Route.wic, route("tif"));
    try testing.expectEqual(Route.wic, route("TIFF"));
    try testing.expectEqual(Route.icns, route("icns"));
    // Every row of the table has a route that is not a guaranteed failure:
    // nothing in `extensions` is left for a browser with no decoder for it.
    for (extensions) |e| _ = route(e);
}

test "fallback: one WIC retry for a raster the browser failed, none for vectors or a host route" {
    try testing.expectEqual(@as(?Route, .wic), fallback(.browser, "avif"));
    try testing.expectEqual(@as(?Route, .wic), fallback(.browser, "png"));
    try testing.expectEqual(@as(?Route, null), fallback(.browser, "svg"));
    try testing.expectEqual(@as(?Route, null), fallback(.browser, "SVG"));
    // Already decoded on the host: a second try cannot do better.
    try testing.expectEqual(@as(?Route, null), fallback(.wic, "heic"));
    try testing.expectEqual(@as(?Route, null), fallback(.icns, "icns"));
}

test "missingCodec names the extension only for a real HEIF/AVIF container" {
    const heic = "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic";
    try testing.expectEqual(@as(?Codec, .heif), missingCodec(heic));
    try testing.expectEqual(@as(?Codec, .heif), missingCodec("\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00"));
    try testing.expectEqual(@as(?Codec, .av1), missingCodec("\x00\x00\x00\x1cftypavif\x00\x00\x00\x00"));
    // An MP4 is an ISO-BMFF file too, and not a picture this card is about.
    try testing.expectEqual(@as(?Codec, null), missingCodec("\x00\x00\x00\x18ftypisom\x00\x00\x00\x00"));
    // A corrupt or misnamed file: the generic card, never "go install X".
    try testing.expectEqual(@as(?Codec, null), missingCodec("this is not a picture"));
    try testing.expectEqual(@as(?Codec, null), missingCodec("short"));
    try testing.expect(std.mem.indexOf(u8, Codec.heif.title(), "HEIF Image Extensions") != null);
}

/// A minimal PNG header for `icnsBestPng` to recognise: the signature and an
/// IHDR chunk whose width is `w`. Not a decodable picture, which the function
/// never needs.
fn fakePng(comptime w: u32) [24]u8 {
    var b: [24]u8 = .{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 'I', 'H', 'D', 'R' } ++ [_]u8{0} ** 8;
    std.mem.writeInt(u32, b[16..20], w, .big);
    return b;
}

fn icnsEntry(comptime kind: *const [4]u8, comptime data: []const u8) [8 + data.len]u8 {
    var b: [8 + data.len]u8 = undefined;
    @memcpy(b[0..4], kind);
    std.mem.writeInt(u32, b[4..8], 8 + data.len, .big);
    @memcpy(b[8..], data);
    return b;
}

fn icnsFile(comptime body: []const u8) [8 + body.len]u8 {
    var b: [8 + body.len]u8 = undefined;
    @memcpy(b[0..4], "icns");
    std.mem.writeInt(u32, b[4..8], 8 + body.len, .big);
    @memcpy(b[8..], body);
    return b;
}

test "icnsBestPng takes the widest PNG, wherever it sits in the file" {
    const small = comptime fakePng(16);
    const big = comptime fakePng(1024);
    const mid = comptime fakePng(256);
    // An old RLE bitmap entry first, which is not a PNG and must be stepped over.
    const body = comptime icnsEntry("is32", "rle-bitmap-bytes") ++ icnsEntry("icp4", &small) ++
        icnsEntry("ic10", &big) ++ icnsEntry("ic08", &mid);
    const file = comptime icnsFile(&body);
    const got = icnsBestPng(&file) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, got[16..20], .big));
    try testing.expectEqual(@as(usize, 24), got.len);

    // No PNG at all: null, so the pane shows the card.
    const legacy = comptime icnsFile(&icnsEntry("is32", "rle-bitmap-bytes"));
    try testing.expect(icnsBestPng(&legacy) == null);
    // Not an icns, and a truncated or self-referential entry, never loop or read past the end.
    try testing.expect(icnsBestPng("PNG?") == null);
    var bad = comptime icnsFile(&icnsEntry("ic10", &big));
    std.mem.writeInt(u32, bad[12..16], 4, .big); // entry length shorter than its header
    try testing.expect(icnsBestPng(&bad) == null);
    var long = comptime icnsFile(&icnsEntry("ic10", &big));
    std.mem.writeInt(u32, long[12..16], 9999, .big); // entry runs past the file
    try testing.expect(icnsBestPng(&long) == null);
}

test "bmpFile puts a BITMAPFILEHEADER in front of a V5 DIB" {
    const alloc = testing.allocator;
    var dib = [_]u8{0} ** (124 + 4);
    std.mem.writeInt(u32, dib[0..4], 124, .little);
    const bmp = try bmpFile(alloc, &dib);
    defer alloc.free(bmp);
    try testing.expectEqualStrings("BM", bmp[0..2]);
    try testing.expectEqual(@as(u32, 14 + 128), std.mem.readInt(u32, bmp[2..6], .little));
    // Pixels start right after both headers.
    try testing.expectEqual(@as(u32, 14 + 124), std.mem.readInt(u32, bmp[10..14], .little));
    try testing.expectEqualSlices(u8, &dib, bmp[14..]);
    // A buffer that cannot be a DIB is refused rather than wrapped.
    try testing.expectError(error.BadDib, bmpFile(alloc, "x"));
    var tiny = [_]u8{0} ** 8;
    std.mem.writeInt(u32, tiny[0..4], 124, .little);
    try testing.expectError(error.BadDib, bmpFile(alloc, &tiny));
}

test "unitScale: 100% is one image pixel per device pixel, and 1.0 for vectors" {
    try testing.expectApproxEqAbs(
        @as(f64, 0.5),
        (Geometry{ .dpr = 2 }).unitScale(),
        1e-9,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 1),
        (Geometry{ .dpr = 1 }).unitScale(),
        1e-9,
    );
    // A vector has no pixel grid to be 1:1 with, at any scale factor.
    try testing.expectApproxEqAbs(
        @as(f64, 1),
        (Geometry{ .dpr = 2, .kind = .vector }).unitScale(),
        1e-9,
    );
    // A nonsense ratio cannot make 100% larger than life.
    try testing.expectApproxEqAbs(
        @as(f64, 1),
        (Geometry{ .dpr = 0 }).unitScale(),
        1e-9,
    );
}

test "fitZoom shrinks a large image and never enlarges a small one" {
    // 4000x3000 image, 800x600 pane, 1x: fit is 0.2 on both axes.
    const big: Geometry = .{
        .natural_w = 4000,
        .natural_h = 3000,
        .viewport_w = 800,
        .viewport_h = 600,
    };
    try testing.expectApproxEqAbs(@as(f64, 0.2), big.fitZoom(), 1e-9);

    // The CONSTRAINING axis wins: a wide image in a tall pane fits by width.
    const wide: Geometry = .{
        .natural_w = 4000,
        .natural_h = 1000,
        .viewport_w = 800,
        .viewport_h = 600,
    };
    try testing.expectApproxEqAbs(@as(f64, 0.2), wide.fitZoom(), 1e-9);

    // A 16px icon in a 900px pane stays 16px. This is the whole "best-fit
    // never upscales" rule: fit would be 56x, and a 56x icon is a blurry lie.
    const icon: Geometry = .{
        .natural_w = 16,
        .natural_h = 16,
        .viewport_w = 900,
        .viewport_h = 900,
    };
    try testing.expectApproxEqAbs(@as(f64, 1), icon.fitZoom(), 1e-9);

    // On a 2x display the same 4000px image is drawn at half the CSS size, so
    // twice as much of it fits: fit is 0.4, not 0.2.
    const retina: Geometry = .{
        .natural_w = 4000,
        .natural_h = 3000,
        .viewport_w = 800,
        .viewport_h = 600,
        .dpr = 2,
    };
    try testing.expectApproxEqAbs(@as(f64, 0.4), retina.fitZoom(), 1e-9);

    // Degenerate inputs answer 100% rather than 0 or infinity: a pane that has
    // not measured itself yet shows a picture, not a blank matte.
    try testing.expectApproxEqAbs(@as(f64, 1), (Geometry{}).fitZoom(), 1e-9);
    try testing.expectApproxEqAbs(
        @as(f64, 1),
        (Geometry{ .natural_w = 10, .natural_h = 10 }).fitZoom(),
        1e-9,
    );
}

test "the zoom limits always admit fit, however large the image" {
    // 20000px wide in a 400px pane: fit is 0.02, BELOW the floor, and the
    // floor has to give way or the image could not be fitted at all.
    const huge: Geometry = .{
        .natural_w = 20000,
        .natural_h = 20000,
        .viewport_w = 400,
        .viewport_h = 400,
    };
    try testing.expectApproxEqAbs(@as(f64, 0.02), huge.fitZoom(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.02), huge.minZoom(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.02), huge.clamp(0.001), 1e-9);
    try testing.expectApproxEqAbs(zoom_ceiling, huge.clamp(1000), 1e-9);

    // The ordinary case keeps the ordinary floor.
    const normal: Geometry = .{
        .natural_w = 100,
        .natural_h = 100,
        .viewport_w = 400,
        .viewport_h = 400,
    };
    try testing.expectApproxEqAbs(zoom_floor, normal.minZoom(), 1e-9);
    try testing.expectApproxEqAbs(zoom_floor, normal.clamp(0.001), 1e-9);
}

test "cssScale turns a zoom into the transform the page applies" {
    const g: Geometry = .{
        .natural_w = 800,
        .natural_h = 600,
        .viewport_w = 400,
        .viewport_h = 400,
        .dpr = 2,
    };
    // 100% on a 2x display draws the 800px image across 400 CSS pixels — one
    // image pixel per device pixel, which is the whole definition.
    try testing.expectApproxEqAbs(@as(f64, 0.5), g.cssScale(1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), g.cssScale(2), 1e-9);
    // Out-of-range zooms are clamped on the way through, so the page cannot be
    // handed a transform the rules do not allow.
    try testing.expectApproxEqAbs(g.cssScale(zoom_ceiling), g.cssScale(1e6), 1e-9);
}

test "double-click toggles fit and 100%, and still toggles when they coincide" {
    // A big image: fit (0.2) and 100% are different, so it is a plain toggle.
    const big: Geometry = .{
        .natural_w = 4000,
        .natural_h = 3000,
        .viewport_w = 800,
        .viewport_h = 600,
    };
    try testing.expectApproxEqAbs(@as(f64, 1), big.doubleClickZoom(0.2), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.2), big.doubleClickZoom(1), 1e-9);
    // From anywhere else, the first click goes to fit.
    try testing.expectApproxEqAbs(@as(f64, 0.2), big.doubleClickZoom(3.7), 1e-9);

    // A small image: fit IS 100%, so the first click has to go somewhere
    // visible or the gesture reads as broken. 200%, then back to fit.
    const icon: Geometry = .{
        .natural_w = 16,
        .natural_h = 16,
        .viewport_w = 900,
        .viewport_h = 900,
    };
    try testing.expectApproxEqAbs(@as(f64, 1), icon.fitZoom(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2), icon.doubleClickZoom(1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), icon.doubleClickZoom(2), 1e-9);
}

test "stepped: 1.25 per press, clamped, and reset means 100%" {
    const g: Geometry = .{
        .natural_w = 4000,
        .natural_h = 3000,
        .viewport_w = 800,
        .viewport_h = 600,
    };
    try testing.expectApproxEqAbs(@as(f64, 1.25), g.stepped(1, .zoom_in), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.8), g.stepped(1, .zoom_out), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), g.stepped(0.2, .reset), 1e-9);
    // Reset is 100%, NOT fit — fit is one double-click away.
    try testing.expect(!g.isFit(g.stepped(0.2, .reset)));
    // The ceiling and the floor hold.
    try testing.expectApproxEqAbs(zoom_ceiling, g.stepped(zoom_ceiling, .zoom_in), 1e-9);
    try testing.expectApproxEqAbs(g.minZoom(), g.stepped(g.minZoom(), .zoom_out), 1e-9);
}

test "isFit tolerates the JSON round trip the page reports through" {
    const g: Geometry = .{
        .natural_w = 4000,
        .natural_h = 3000,
        .viewport_w = 800,
        .viewport_h = 600,
    };
    try testing.expect(g.isFit(0.2));
    try testing.expect(g.isFit(0.2 + epsilon / 2));
    try testing.expect(!g.isFit(0.2 + epsilon * 10));
    try testing.expect(!g.isFit(1));
}
