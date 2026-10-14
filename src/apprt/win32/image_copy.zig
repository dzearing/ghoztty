//! Ctrl+C in an image viewer pane copies the PICTURE (T1872) — Mac's
//! `ViewerImageSurface.copy` (main 1d513083a), the Windows half.
//!
//! An image pane is a WebView2 page drawing an `<img>`, and with nothing
//! selected the page's own copy puts nothing on the clipboard — the same
//! silent no-op Mac had before it gave the surface a `copy:` handler. The
//! pane claims the chord (`ViewerPane.claimsChord`) and this module does the
//! copy natively, from the FILE rather than from the page: the browser has no
//! raw-pixel export that is not a canvas round trip through base64, and the
//! file is the thing the user is looking at anyway.
//!
//! ## Why WIC and not the GDI+ decoder next door
//!
//! `gdiplus_decode.zig` decodes CAPTURES, which are always PNG. A viewer pane
//! opens every format in `viewer_image.extensions`, and GDI+ has no WebP, AVIF
//! or HEIF codec. WIC is the system's codec registry — the same decoders
//! Photos and Explorer's thumbnails use — so whatever this machine can show in
//! Explorer, ctrl+C can copy.
//!
//! What it cannot decode is SVG (WIC has no vector codec). A vector pane's
//! ctrl+C answers `false` and logs why rather than putting a blank bitmap on
//! the clipboard.
//!
//! ## Orientation
//!
//! WIC hands back the pixels as STORED. A phone stores a portrait photo in
//! sensor order and records the turn in the EXIF Orientation tag, which the
//! pane's browser applies, so the copy reads that tag and turns the pixels
//! the same way (T1910) - otherwise the user pastes the photo sideways.
//!
//! ## Thread
//!
//! Called on the UI thread, which already has COM initialised (STA) — every
//! WebView2 on it needs that — so nothing here calls `CoInitializeEx`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const com = @import("com.zig");
const clipboard_open = @import("clipboard_open.zig");
const clipboard_image = @import("clipboard_image.zig");
const png_encode = @import("png_encode.zig");
const image_clipboard = @import("image_clipboard.zig");

const log = std.log.scoped(.viewer);

/// What a successful copy put on the clipboard — the acceptance script's
/// oracle is the log line built from this.
pub const Result = struct {
    width: u32,
    height: u32,
    png: image_clipboard.PngPlan,
    png_bytes: usize,
};

/// The file is read whole for the verbatim-PNG case; past this it is not a
/// picture anybody copies through a clipboard.
const max_file_bytes: usize = 256 * 1024 * 1024;

/// Decode `path` and put it on the clipboard. Null on any failure, which the
/// log line names; the clipboard is left untouched unless the write happens.
pub fn copyFile(alloc: Allocator, path: []const u8) ?Result {
    const decoded = decode(alloc, path) orelse return null;
    defer alloc.free(decoded.bgra);

    const dib = image_clipboard.dibV5(alloc, decoded.bgra, decoded.width, decoded.height) catch |err| {
        log.warn("image copy: cannot pack {s}: {}", .{ path, err });
        return null;
    };
    defer alloc.free(dib);

    // The "PNG" format's bytes, per `pngPlan`.
    const file_bytes: ?[]u8 = std.fs.cwd().readFileAlloc(alloc, path, max_file_bytes) catch null;
    defer if (file_bytes) |b| alloc.free(b);
    // A PNG that carries an orientation is not the picture the pane shows,
    // so it is never published verbatim.
    const plan = image_clipboard.pngPlan(
        decoded.orientation == .normal and
            if (file_bytes) |b| image_clipboard.isPng(b) else false,
        image_clipboard.isOpaque(decoded.bgra),
    );
    var encoded: ?[]u8 = null;
    defer if (encoded) |e| alloc.free(e);
    const png: ?[]const u8 = switch (plan) {
        .verbatim => file_bytes.?,
        .none => null,
        .encode => blk: {
            const rgba = image_clipboard.bgraToRgba(alloc, decoded.bgra) catch break :blk null;
            defer alloc.free(rgba);
            encoded = png_encode.encode(alloc, .{
                .data = rgba,
                .width = decoded.width,
                .height = decoded.height,
                .channels = .rgba,
            }) catch break :blk null;
            break :blk encoded;
        },
    };

    if (!publish(dib, png)) {
        log.warn("image copy: the clipboard could not be opened for {s}", .{path});
        return null;
    }
    return .{
        .width = decoded.width,
        .height = decoded.height,
        .png = if (png == null) .none else plan,
        .png_bytes = if (png) |p| p.len else 0,
    };
}

/// Put the DIB (and the PNG, when there is one) on the clipboard in one
/// open/empty/set sequence. PNG first: a reader that enumerates formats in
/// order and knows "PNG" takes the lossless, alpha-carrying one.
fn publish(dib: []const u8, png: ?[]const u8) bool {
    const dib_mem = globalCopy(dib) orelse return false;
    var dib_owned = false;
    defer if (!dib_owned) {
        _ = w32.GlobalFree(dib_mem);
    };
    var png_mem: ?*anyopaque = null;
    var png_owned = false;
    if (png) |p| png_mem = globalCopy(p);
    defer if (!png_owned) {
        if (png_mem) |m| _ = w32.GlobalFree(m);
    };

    if (!clipboard_open.open(null)) return false;
    defer _ = w32.CloseClipboard();
    _ = w32.EmptyClipboard();
    // SetClipboardData owns the HGLOBAL on success, and only then.
    if (png_mem) |m| {
        const fmt = clipboard_image.pngFormat();
        if (fmt != 0 and w32.SetClipboardData(fmt, m) != null) png_owned = true;
    }
    if (w32.SetClipboardData(w32.CF_DIBV5, dib_mem) == null) return false;
    dib_owned = true;
    return true;
}

fn globalCopy(bytes: []const u8) ?*anyopaque {
    const mem = w32.GlobalAlloc(w32.GMEM_MOVEABLE, bytes.len) orelse return null;
    const dst = w32.GlobalLock(mem) orelse {
        _ = w32.GlobalFree(mem);
        return null;
    };
    @memcpy(dst[0..bytes.len], bytes);
    _ = w32.GlobalUnlock(mem);
    return mem;
}

// --------------------------------------------------------------------- WIC

const Decoded = struct {
    bgra: []u8,
    width: u32,
    height: u32,
    /// What was applied to reach `bgra` from the stored pixels.
    orientation: image_clipboard.Orientation = .normal,
};

/// Decode the first frame of `path` to top-down straight-alpha BGRA, turned
/// upright per its EXIF orientation.
fn decode(alloc: Allocator, path: []const u8) ?Decoded {
    const wpath = std.unicode.wtf8ToWtf16LeAllocZ(alloc, path) catch return null;
    defer alloc.free(wpath);

    var factory_ptr: ?*anyopaque = null;
    const created = w32.CoCreateInstance(
        &CLSID_WICImagingFactory,
        null,
        w32.CLSCTX_INPROC_SERVER,
        &IID_IWICImagingFactory,
        &factory_ptr,
    );
    if (com.failed(created)) {
        log.warn("image copy: WIC factory unavailable hr=0x{x}", .{@as(u32, @bitCast(created))});
        return null;
    }
    const factory: *IWICImagingFactory = @ptrCast(@alignCast(factory_ptr.?));
    defer _ = factory.vtable.Release(factory);

    var decoder: ?*IWICBitmapDecoder = null;
    const opened = factory.vtable.CreateDecoderFromFilename(
        factory,
        wpath.ptr,
        null,
        GENERIC_READ,
        WICDecodeMetadataCacheOnDemand,
        &decoder,
    );
    if (com.failed(opened) or decoder == null) {
        // SVG lands here (no vector codec), as does a format this machine has
        // no codec for (HEIF without the store extension).
        log.warn("image copy: no decoder for {s} hr=0x{x}", .{ path, @as(u32, @bitCast(opened)) });
        return null;
    }
    defer _ = decoder.?.vtable.Release(decoder.?);

    var frame: ?*IWICBitmapFrameDecode = null;
    if (com.failed(decoder.?.vtable.GetFrame(decoder.?, 0, &frame)) or frame == null) {
        log.warn("image copy: {s} has no first frame", .{path});
        return null;
    }
    defer _ = frame.?.vtable.Release(frame.?);

    var converter: ?*IWICFormatConverter = null;
    if (com.failed(factory.vtable.CreateFormatConverter(factory, &converter)) or converter == null) return null;
    defer _ = converter.?.vtable.Release(converter.?);
    const orientation = readOrientation(frame.?);
    const init = converter.?.vtable.Initialize(
        converter.?,
        @ptrCast(frame.?),
        &GUID_WICPixelFormat32bppBGRA,
        WICBitmapDitherTypeNone,
        null,
        0.0,
        WICBitmapPaletteTypeCustom,
    );
    if (com.failed(init)) {
        log.warn("image copy: cannot convert {s} to BGRA hr=0x{x}", .{ path, @as(u32, @bitCast(init)) });
        return null;
    }

    var width: u32 = 0;
    var height: u32 = 0;
    if (com.failed(converter.?.vtable.GetSize(converter.?, &width, &height))) return null;
    if (!image_clipboard.sizeOk(width, height)) {
        log.warn("image copy: {s} is {d}x{d}, past the copy ceiling", .{ path, width, height });
        return null;
    }

    const stride: u32 = width * 4;
    const total: usize = @as(usize, stride) * @as(usize, height);
    const bgra = alloc.alloc(u8, total) catch return null;
    const copied = converter.?.vtable.CopyPixels(converter.?, null, stride, @intCast(total), bgra.ptr);
    if (com.failed(copied)) {
        log.warn("image copy: decoding {s} failed hr=0x{x}", .{ path, @as(u32, @bitCast(copied)) });
        alloc.free(bgra);
        return null;
    }
    if (orientation == .normal) return .{ .bgra = bgra, .width = width, .height = height };
    defer alloc.free(bgra);
    const turned = image_clipboard.orient(alloc, bgra, width, height, orientation) catch return null;
    return .{ .bgra = turned.bgra, .width = turned.width, .height = turned.height, .orientation = orientation };
}

/// The frame's EXIF Orientation, `.normal` when it has none or the metadata
/// cannot be read - a picture without the tag is shown as stored, by the
/// browser and here alike.
fn readOrientation(frame: *IWICBitmapFrameDecode) image_clipboard.Orientation {
    var reader: ?*IWICMetadataQueryReader = null;
    if (com.failed(frame.vtable.GetMetadataQueryReader(frame, &reader)) or reader == null) return .normal;
    defer _ = reader.?.vtable.Release(reader.?);
    // The photo policy name resolves per container (a JPEG's APP1 IFD, a
    // TIFF's own IFD); the raw JPEG path is the fallback for a codec that
    // does not map the policy.
    const queries = [_][*:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("System.Photo.Orientation"),
        std.unicode.utf8ToUtf16LeStringLiteral("/app1/ifd/{ushort=274}"),
    };
    for (queries) |q| {
        var v: PROPVARIANT = .{};
        if (com.failed(reader.?.vtable.GetMetadataByName(reader.?, q, &v))) continue;
        defer _ = PropVariantClear(&v);
        if (v.vt == VT_UI2) return image_clipboard.Orientation.fromTag(@truncate(v.data[0]));
    }
    return .normal;
}

const GUID = w32.GUID;
const HRESULT = w32.HRESULT;

const GENERIC_READ: u32 = 0x80000000;
const VT_UI2: u16 = 18;

/// `PROPVARIANT`: a type tag, three reserved words, then a 16-byte union on
/// 64-bit Windows. Only `VT_UI2` is read, from the low bytes of the union.
const PROPVARIANT = extern struct {
    vt: u16 = 0,
    reserved: [3]u16 = .{ 0, 0, 0 },
    data: [2]u64 = .{ 0, 0 },
};
extern "ole32" fn PropVariantClear(pv: *PROPVARIANT) callconv(.winapi) HRESULT;
const WICDecodeMetadataCacheOnDemand: u32 = 0;
const WICBitmapDitherTypeNone: u32 = 0;
const WICBitmapPaletteTypeCustom: u32 = 0;

// {CACAF262-9370-4615-A13B-9F5539DA4C0A}
const CLSID_WICImagingFactory: GUID = .{
    .Data1 = 0xCACAF262,
    .Data2 = 0x9370,
    .Data3 = 0x4615,
    .Data4 = .{ 0xA1, 0x3B, 0x9F, 0x55, 0x39, 0xDA, 0x4C, 0x0A },
};
// {EC5EC8A9-C395-4314-9C77-54D7A935FF70}
const IID_IWICImagingFactory: GUID = .{
    .Data1 = 0xEC5EC8A9,
    .Data2 = 0xC395,
    .Data3 = 0x4314,
    .Data4 = .{ 0x9C, 0x77, 0x54, 0xD7, 0xA9, 0x35, 0xFF, 0x70 },
};
// {6FDDC324-4E03-4BFE-B185-3D77768DC90F}
const GUID_WICPixelFormat32bppBGRA: GUID = .{
    .Data1 = 0x6FDDC324,
    .Data2 = 0x4E03,
    .Data3 = 0x4BFE,
    .Data4 = .{ 0xB1, 0x85, 0x3D, 0x77, 0x76, 0x8D, 0xC9, 0x0F },
};

/// A vtable slot this module never calls, kept so the ones after it land at
/// the right offset.
const Unused = *const anyopaque;

/// Only the methods called here are typed; the rest hold their slot.
const IWICImagingFactory = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*IWICImagingFactory) callconv(.winapi) u32,
        CreateDecoderFromFilename: *const fn (
            *IWICImagingFactory,
            [*:0]const u16,
            ?*const GUID,
            u32,
            u32,
            *?*IWICBitmapDecoder,
        ) callconv(.winapi) HRESULT,
        CreateDecoderFromStream: Unused,
        CreateDecoderFromFileHandle: Unused,
        CreateComponentInfo: Unused,
        CreateDecoder: Unused,
        CreateEncoder: Unused,
        CreatePalette: Unused,
        CreateFormatConverter: *const fn (*IWICImagingFactory, *?*IWICFormatConverter) callconv(.winapi) HRESULT,
    },
};

const IWICBitmapDecoder = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*IWICBitmapDecoder) callconv(.winapi) u32,
        QueryCapability: Unused,
        Initialize: Unused,
        GetContainerFormat: Unused,
        GetDecoderInfo: Unused,
        CopyPalette: Unused,
        GetMetadataQueryReader: Unused,
        GetPreview: Unused,
        GetColorContexts: Unused,
        GetThumbnail: Unused,
        GetFrameCount: Unused,
        /// An `IWICBitmapFrameDecode` is also an `IWICBitmapSource`, which is
        /// how it is handed to the format converter.
        GetFrame: *const fn (*IWICBitmapDecoder, u32, *?*IWICBitmapFrameDecode) callconv(.winapi) HRESULT,
    },
};

const IWICBitmapSource = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*IWICBitmapSource) callconv(.winapi) u32,
    },
};

const IWICBitmapFrameDecode = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*IWICBitmapFrameDecode) callconv(.winapi) u32,
        // IWICBitmapSource
        GetSize: Unused,
        GetPixelFormat: Unused,
        GetResolution: Unused,
        CopyPalette: Unused,
        CopyPixels: Unused,
        // IWICBitmapFrameDecode
        GetMetadataQueryReader: *const fn (*IWICBitmapFrameDecode, *?*IWICMetadataQueryReader) callconv(.winapi) HRESULT,
    },
};

const IWICMetadataQueryReader = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*IWICMetadataQueryReader) callconv(.winapi) u32,
        GetContainerFormat: Unused,
        GetLocation: Unused,
        GetMetadataByName: *const fn (*IWICMetadataQueryReader, [*:0]const u16, *PROPVARIANT) callconv(.winapi) HRESULT,
    },
};

const IWICFormatConverter = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*IWICFormatConverter) callconv(.winapi) u32,
        // IWICBitmapSource
        GetSize: *const fn (*IWICFormatConverter, *u32, *u32) callconv(.winapi) HRESULT,
        GetPixelFormat: Unused,
        GetResolution: Unused,
        CopyPalette: Unused,
        CopyPixels: *const fn (*IWICFormatConverter, ?*const anyopaque, u32, u32, [*]u8) callconv(.winapi) HRESULT,
        // IWICFormatConverter
        Initialize: *const fn (
            *IWICFormatConverter,
            *IWICBitmapSource,
            *const GUID,
            u32,
            ?*anyopaque,
            f64,
            u32,
        ) callconv(.winapi) HRESULT,
    },
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "copyFile decodes a real PNG through WIC and reports its size" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    // COM on this test thread; S_FALSE (already initialised) is fine too.
    _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);

    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // 3x2, with one see-through pixel so the alpha path is the one exercised.
    var rgba = [_]u8{0xFF} ** (3 * 2 * 4);
    rgba[3] = 0x40;
    const png = try png_encode.encode(alloc, .{ .data = &rgba, .width = 3, .height = 2, .channels = .rgba });
    defer alloc.free(png);
    try tmp.dir.writeFile(.{ .sub_path = "pic.png", .data = png });
    const path = try tmp.dir.realpathAlloc(alloc, "pic.png");
    defer alloc.free(path);

    const decoded = decode(alloc, path) orelse return error.TestUnexpectedResult;
    defer alloc.free(decoded.bgra);
    try testing.expectEqual(@as(u32, 3), decoded.width);
    try testing.expectEqual(@as(u32, 2), decoded.height);
    // Straight alpha survived the decode: the first pixel is still 0x40.
    try testing.expectEqual(@as(u8, 0x40), decoded.bgra[3]);
    try testing.expect(!image_clipboard.isOpaque(decoded.bgra));
}

test "decode refuses a file that is not a picture" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "x.png", .data = "this is not a picture" });
    const path = try tmp.dir.realpathAlloc(alloc, "x.png");
    defer alloc.free(path);
    try testing.expect(decode(alloc, path) == null);
}

/// `jpeg` with an EXIF APP1 segment carrying Orientation = `tag` spliced in
/// right after its SOI marker. Caller frees.
fn withExifOrientation(alloc: Allocator, jpeg: []const u8, tag: u8) ![]u8 {
    const app1 = [_]u8{
        0xFF, 0xE1, 0x00, 0x22, // APP1, length 34 (counts itself)
        'E', 'x', 'i', 'f', 0, 0,
        'I', 'I', 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // little-endian TIFF, IFD0 at 8
        0x01, 0x00, // one entry
        0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, tag, 0x00, 0x00, 0x00, // 274, SHORT, 1, tag
        0x00, 0x00, 0x00, 0x00, // no next IFD
    };
    return std.mem.concat(alloc, u8, &.{ jpeg[0..2], &app1, jpeg[2..] });
}

/// Whether the BGRA pixel at (x, y) is clearly red (true) rather than blue.
fn isRed(d: Decoded, x: u32, y: u32) bool {
    const i = (@as(usize, y) * d.width + x) * 4;
    return d.bgra[i + 2] > 150 and d.bgra[i] < 100;
}

test "decode turns a phone photo upright from its EXIF orientation (T1910)" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Stored 32x16: the left half red, the right half blue.
    const base = @embedFile("testdata/half-red-half-blue.jpg");

    // No tag: as stored.
    try tmp.dir.writeFile(.{ .sub_path = "plain.jpg", .data = base });
    const plain_path = try tmp.dir.realpathAlloc(alloc, "plain.jpg");
    defer alloc.free(plain_path);
    const plain = decode(alloc, plain_path) orelse return error.TestUnexpectedResult;
    defer alloc.free(plain.bgra);
    try testing.expectEqual(image_clipboard.Orientation.normal, plain.orientation);
    try testing.expectEqual(@as(u32, 32), plain.width);
    try testing.expect(isRed(plain, 0, 0));
    try testing.expect(!isRed(plain, 31, 0));

    // 6, the portrait phone shot: a quarter turn clockwise, 16x32, the stored
    // left (red) half now on top.
    const six = try withExifOrientation(alloc, base, 6);
    defer alloc.free(six);
    try tmp.dir.writeFile(.{ .sub_path = "six.jpg", .data = six });
    const six_path = try tmp.dir.realpathAlloc(alloc, "six.jpg");
    defer alloc.free(six_path);
    const r6 = decode(alloc, six_path) orelse return error.TestUnexpectedResult;
    defer alloc.free(r6.bgra);
    try testing.expectEqual(image_clipboard.Orientation.rotate_90, r6.orientation);
    try testing.expectEqual(@as(u32, 16), r6.width);
    try testing.expectEqual(@as(u32, 32), r6.height);
    try testing.expect(isRed(r6, 0, 0));
    try testing.expect(isRed(r6, 15, 0));
    try testing.expect(!isRed(r6, 0, 31));

    // 8, the other way: blue on top.
    const eight = try withExifOrientation(alloc, base, 8);
    defer alloc.free(eight);
    try tmp.dir.writeFile(.{ .sub_path = "eight.jpg", .data = eight });
    const eight_path = try tmp.dir.realpathAlloc(alloc, "eight.jpg");
    defer alloc.free(eight_path);
    const r8 = decode(alloc, eight_path) orelse return error.TestUnexpectedResult;
    defer alloc.free(r8.bgra);
    try testing.expectEqual(@as(u32, 16), r8.width);
    try testing.expect(!isRed(r8, 0, 0));
    try testing.expect(isRed(r8, 0, 31));
}
