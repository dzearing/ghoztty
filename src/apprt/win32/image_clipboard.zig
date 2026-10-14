//! What an image viewer pane puts on the clipboard for ctrl+C (T1872) — the
//! pure half. Mac's image pane answers Cmd-C by writing the picture itself
//! (`ViewerImageSurface.copy`, main 1d513083a); this is the Windows shape of the
//! same write. `image_copy.zig` decodes the file and owns the clipboard; every
//! decision about WHICH bytes go there lives here, with no OS imports, so it
//! asserts in the `-Dapp-runtime=none` lane.
//!
//! ## The two formats, and why each
//!
//! - **`CF_DIBV5`** is the format every Windows reader understands — Paint,
//!   Office, Teams, every Chromium-based app — and the system synthesises
//!   `CF_DIB` and `CF_BITMAP` from it for the older ones. It is written
//!   BOTTOM-UP with `BI_BITFIELDS` masks inside the V5 header and straight
//!   (not premultiplied) alpha: a top-down DIB is legal and still misread by
//!   enough readers that the conservative orientation is worth the row flip.
//! - **`"PNG"`**, the registered format browsers and modern editors look for
//!   first, carries alpha with no ambiguity at all. It is written when it adds
//!   something (`pngPlan`): verbatim when the file already IS a PNG — the
//!   reader then gets the user's own file, byte for byte — and freshly encoded
//!   only when a non-PNG picture is genuinely see-through, which is the one
//!   case a DIB's alpha byte cannot be trusted to survive. An opaque JPEG gets
//!   the DIB alone: re-encoding a 12-megapixel photo on the UI thread buys a
//!   reader nothing the DIB did not already give it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// `sizeof(BITMAPV5HEADER)`. The masks and colour space live INSIDE it, so
/// nothing follows the header but the pixels.
pub const v5_header_size: usize = 124;

/// Beyond this the copy is refused rather than attempted: 64 megapixels is
/// over twice a 6K display, and a 256 MB clipboard block is a memory incident
/// in every application that pastes it. Same ceiling `clipboard_image.zig`
/// applies on the way in.
pub const max_pixels: usize = 64 * 1024 * 1024;

const BI_BITFIELDS: u32 = 3;
/// `LCS_sRGB` — the bytes are 'sRGB' read as a little-endian u32.
const LCS_sRGB: u32 = 0x73524742;
/// `LCS_GM_IMAGES` — perceptual rendering intent, what a photo wants.
const LCS_GM_IMAGES: u32 = 4;

pub const Error = error{
    /// A zero dimension, a size past `max_pixels`, or a buffer that is not
    /// exactly `width * height * 4` bytes.
    BadPixels,
} || Allocator.Error;

/// Whether a picture of this size may be copied at all.
pub fn sizeOk(width: u32, height: u32) bool {
    if (width == 0 or height == 0) return false;
    const px = @as(u64, width) * @as(u64, height);
    return px <= max_pixels;
}

/// A packed `CF_DIBV5` block for `bgra`, which is TOP-DOWN 32-bit BGRA with
/// straight alpha (WIC's `GUID_WICPixelFormat32bppBGRA`). Caller frees.
pub fn dibV5(alloc: Allocator, bgra: []const u8, width: u32, height: u32) Error![]u8 {
    if (!sizeOk(width, height)) return error.BadPixels;
    const row: usize = @as(usize, width) * 4;
    const image: usize = row * @as(usize, height);
    if (bgra.len != image) return error.BadPixels;

    const out = try alloc.alloc(u8, v5_header_size + image);
    errdefer alloc.free(out);
    @memset(out[0..v5_header_size], 0);
    const h = out[0..v5_header_size];
    std.mem.writeInt(u32, h[0..4], @intCast(v5_header_size), .little);
    std.mem.writeInt(i32, h[4..8], @intCast(width), .little);
    // Positive height: bottom-up, the orientation no reader gets wrong.
    std.mem.writeInt(i32, h[8..12], @intCast(height), .little);
    std.mem.writeInt(u16, h[12..14], 1, .little); // planes
    std.mem.writeInt(u16, h[14..16], 32, .little); // bit count
    std.mem.writeInt(u32, h[16..20], BI_BITFIELDS, .little);
    std.mem.writeInt(u32, h[20..24], @intCast(image), .little);
    std.mem.writeInt(u32, h[40..44], 0x00FF0000, .little); // red
    std.mem.writeInt(u32, h[44..48], 0x0000FF00, .little); // green
    std.mem.writeInt(u32, h[48..52], 0x000000FF, .little); // blue
    std.mem.writeInt(u32, h[52..56], 0xFF000000, .little); // alpha
    std.mem.writeInt(u32, h[56..60], LCS_sRGB, .little);
    std.mem.writeInt(u32, h[108..112], LCS_GM_IMAGES, .little);

    // Flip: source row 0 (the top) is the LAST row of a bottom-up DIB.
    const px = out[v5_header_size..];
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src = bgra[y * row ..][0..row];
        const dst = px[(@as(usize, height) - 1 - y) * row ..][0..row];
        @memcpy(dst, src);
    }
    return out;
}

/// Whether every pixel is fully opaque.
pub fn isOpaque(bgra: []const u8) bool {
    var i: usize = 3;
    while (i < bgra.len) : (i += 4) {
        if (bgra[i] != 0xFF) return false;
    }
    return true;
}

/// Whether `bytes` start with the PNG signature. The file's CONTENT decides,
/// not its extension: a `.png` that is really a JPEG must not be published to
/// the clipboard under a format name that promises a PNG.
pub fn isPng(bytes: []const u8) bool {
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    return bytes.len >= sig.len and std.mem.eql(u8, bytes[0..sig.len], &sig);
}

/// Where the `"PNG"` clipboard format's bytes come from, if anywhere.
pub const PngPlan = enum {
    /// The file is a PNG: publish it unchanged.
    verbatim,
    /// A see-through picture in another format: encode one.
    encode,
    /// Opaque and not a PNG: the DIB says everything.
    none,
};

pub fn pngPlan(file_is_png: bool, is_opaque: bool) PngPlan {
    if (file_is_png) return .verbatim;
    return if (is_opaque) .none else .encode;
}

/// The EXIF Orientation tag (274): how the STORED pixels must be turned to
/// show the picture upright (T1910). A phone writes its photos in sensor
/// order and records the turn here instead of rotating them; the pane's
/// browser applies it (`image-orientation: from-image`, Chromium's default),
/// so the copy must apply it too or the user pastes the photo sideways.
pub const Orientation = enum(u16) {
    normal = 1,
    flip_horizontal = 2,
    rotate_180 = 3,
    flip_vertical = 4,
    /// Mirrored across the top-left to bottom-right diagonal.
    transpose = 5,
    /// Turned a quarter clockwise to display — the usual portrait phone shot.
    rotate_90 = 6,
    /// Mirrored across the other diagonal.
    transverse = 7,
    rotate_270 = 8,

    /// A tag value outside 1-8 is a malformed file; show it as stored, which
    /// is also what the browser does.
    pub fn fromTag(tag: u16) Orientation {
        return std.meta.intToEnum(Orientation, tag) catch .normal;
    }

    /// Whether width and height trade places.
    pub fn swapsAxes(self: Orientation) bool {
        return @intFromEnum(self) >= 5;
    }
};

/// `bgra` (top-down, `width` x `height`) turned upright per `o`. Returns the
/// new buffer and its dimensions; `.normal` still copies, so the caller owns
/// one buffer either way. Caller frees `.bgra`.
pub fn orient(
    alloc: Allocator,
    bgra: []const u8,
    width: u32,
    height: u32,
    o: Orientation,
) Error!Oriented {
    const w: usize = width;
    const h: usize = height;
    if (bgra.len != w * h * 4) return error.BadPixels;
    const out = try alloc.alloc(u8, bgra.len);
    errdefer alloc.free(out);
    const ow: usize = if (o.swapsAxes()) h else w;
    for (0..h) |y| {
        for (0..w) |x| {
            // Where the stored pixel (x, y) lands in the upright picture.
            const dx: usize, const dy: usize = switch (o) {
                .normal => .{ x, y },
                .flip_horizontal => .{ w - 1 - x, y },
                .rotate_180 => .{ w - 1 - x, h - 1 - y },
                .flip_vertical => .{ x, h - 1 - y },
                .transpose => .{ y, x },
                .rotate_90 => .{ h - 1 - y, x },
                .transverse => .{ h - 1 - y, w - 1 - x },
                .rotate_270 => .{ y, w - 1 - x },
            };
            const src = (y * w + x) * 4;
            const dst = (dy * ow + dx) * 4;
            @memcpy(out[dst..][0..4], bgra[src..][0..4]);
        }
    }
    return .{
        .bgra = out,
        .width = if (o.swapsAxes()) height else width,
        .height = if (o.swapsAxes()) width else height,
    };
}

pub const Oriented = struct { bgra: []u8, width: u32, height: u32 };

/// BGRA → RGBA, the channel order `png_encode` takes. Caller frees.
pub fn bgraToRgba(alloc: Allocator, bgra: []const u8) Allocator.Error![]u8 {
    const out = try alloc.alloc(u8, bgra.len);
    var i: usize = 0;
    while (i + 3 < bgra.len) : (i += 4) {
        out[i + 0] = bgra[i + 2];
        out[i + 1] = bgra[i + 1];
        out[i + 2] = bgra[i + 0];
        out[i + 3] = bgra[i + 3];
    }
    return out;
}

// ------------------------------------------------------------------- tests

const dib_packed = @import("dib_packed.zig");

test "dibV5 is a 124-byte V5 header the clipboard reader parses back" {
    const alloc = testing.allocator;
    // 2x2, top-down: row 0 = red, green; row 1 = blue, half-transparent white.
    const px = [_]u8{
        0x00, 0x00, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF,
        0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x80,
    };
    const blob = try dibV5(alloc, &px, 2, 2);
    defer alloc.free(blob);
    try testing.expectEqual(v5_header_size + px.len, blob.len);

    // The same parser the paste path uses agrees on every layout fact.
    const info = try dib_packed.parse(blob);
    try testing.expectEqual(@as(i32, 2), info.width);
    try testing.expectEqual(@as(i32, 2), info.height);
    try testing.expectEqual(@as(u16, 32), info.bit_count);
    try testing.expectEqual(dib_packed.BI_BITFIELDS, info.compression);
    try testing.expectEqual(v5_header_size, info.bits_offset);
    try testing.expect(!info.top_down);

    try testing.expectEqual(@as(u32, 0xFF000000), std.mem.readInt(u32, blob[52..56], .little));
    try testing.expectEqual(LCS_sRGB, std.mem.readInt(u32, blob[56..60], .little));
}

test "dibV5 stores the rows bottom-up" {
    const alloc = testing.allocator;
    const px = [_]u8{
        1, 1, 1, 1, // top row
        2, 2, 2, 2, // bottom row
    };
    const blob = try dibV5(alloc, &px, 1, 2);
    defer alloc.free(blob);
    // The first stored row is the picture's BOTTOM row.
    try testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2, 1, 1, 1, 1 }, blob[v5_header_size..]);
}

test "dibV5 refuses a buffer that does not match its dimensions" {
    const alloc = testing.allocator;
    const px = [_]u8{0} ** 12;
    try testing.expectError(error.BadPixels, dibV5(alloc, &px, 2, 2));
    try testing.expectError(error.BadPixels, dibV5(alloc, &px, 0, 3));
}

test "sizeOk bounds the copy at max_pixels" {
    try testing.expect(sizeOk(8192, 8192));
    try testing.expect(!sizeOk(8193, 8192));
    try testing.expect(!sizeOk(0, 10));
    // No u32 overflow on the multiply.
    try testing.expect(!sizeOk(std.math.maxInt(u32), std.math.maxInt(u32)));
}

test "pngPlan: a PNG goes verbatim, a see-through picture is encoded, an opaque one is not" {
    try testing.expectEqual(PngPlan.verbatim, pngPlan(true, true));
    try testing.expectEqual(PngPlan.verbatim, pngPlan(true, false));
    try testing.expectEqual(PngPlan.encode, pngPlan(false, false));
    try testing.expectEqual(PngPlan.none, pngPlan(false, true));
}

test "isPng reads the signature, not the name" {
    try testing.expect(isPng(&[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0 }));
    try testing.expect(!isPng(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 })); // a JPEG
    try testing.expect(!isPng(""));
}

test "isOpaque looks at every alpha byte" {
    try testing.expect(isOpaque(&[_]u8{ 1, 2, 3, 0xFF, 4, 5, 6, 0xFF }));
    try testing.expect(!isOpaque(&[_]u8{ 1, 2, 3, 0xFF, 4, 5, 6, 0xFE }));
}

test "bgraToRgba swaps red and blue and keeps alpha" {
    const alloc = testing.allocator;
    const out = try bgraToRgba(alloc, &[_]u8{ 10, 20, 30, 40 });
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, &.{ 30, 20, 10, 40 }, out);
}

/// A 3x2 picture whose pixels are numbered 0..5 in reading order (the number
/// sits in the blue byte), turned per `o` and read back as numbers.
fn orientedIds(o: Orientation) ![6]u8 {
    const alloc = testing.allocator;
    var px: [6 * 4]u8 = undefined;
    for (0..6) |i| px[i * 4 ..][0..4].* = .{ @intCast(i), 0, 0, 0xFF };
    const r = try orient(alloc, &px, 3, 2, o);
    defer alloc.free(r.bgra);
    try testing.expectEqual(@as(u32, if (o.swapsAxes()) 2 else 3), r.width);
    try testing.expectEqual(@as(u32, if (o.swapsAxes()) 3 else 2), r.height);
    var ids: [6]u8 = undefined;
    for (0..6) |i| ids[i] = r.bgra[i * 4];
    return ids;
}

// Stored (3 wide, 2 tall):   0 1 2
//                            3 4 5
test "orient: every EXIF orientation turns the stored pixels upright" {
    try testing.expectEqual([6]u8{ 0, 1, 2, 3, 4, 5 }, try orientedIds(.normal));
    try testing.expectEqual([6]u8{ 2, 1, 0, 5, 4, 3 }, try orientedIds(.flip_horizontal));
    try testing.expectEqual([6]u8{ 5, 4, 3, 2, 1, 0 }, try orientedIds(.rotate_180));
    try testing.expectEqual([6]u8{ 3, 4, 5, 0, 1, 2 }, try orientedIds(.flip_vertical));
    // Upright is 2 wide, 3 tall from here on.
    try testing.expectEqual([6]u8{ 0, 3, 1, 4, 2, 5 }, try orientedIds(.transpose));
    // A quarter turn clockwise: the stored left column becomes the top row,
    // read from the bottom up.
    try testing.expectEqual([6]u8{ 3, 0, 4, 1, 5, 2 }, try orientedIds(.rotate_90));
    try testing.expectEqual([6]u8{ 5, 2, 4, 1, 3, 0 }, try orientedIds(.transverse));
    try testing.expectEqual([6]u8{ 2, 5, 1, 4, 0, 3 }, try orientedIds(.rotate_270));
}

test "orient: a tag outside 1-8 shows the picture as stored" {
    try testing.expectEqual(Orientation.normal, Orientation.fromTag(0));
    try testing.expectEqual(Orientation.normal, Orientation.fromTag(9));
    try testing.expectEqual(Orientation.rotate_90, Orientation.fromTag(6));
}

test "orient refuses a buffer that does not match its dimensions" {
    const px = [_]u8{0} ** 8;
    try testing.expectError(error.BadPixels, orient(testing.allocator, &px, 3, 2, .rotate_90));
}
