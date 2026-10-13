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
    const plan = image_clipboard.pngPlan(
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

const Decoded = struct { bgra: []u8, width: u32, height: u32 };

/// Decode the first frame of `path` to top-down straight-alpha BGRA.
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

    var frame: ?*IWICBitmapSource = null;
    if (com.failed(decoder.?.vtable.GetFrame(decoder.?, 0, &frame)) or frame == null) {
        log.warn("image copy: {s} has no first frame", .{path});
        return null;
    }
    defer _ = frame.?.vtable.Release(frame.?);

    var converter: ?*IWICFormatConverter = null;
    if (com.failed(factory.vtable.CreateFormatConverter(factory, &converter)) or converter == null) return null;
    defer _ = converter.?.vtable.Release(converter.?);
    const init = converter.?.vtable.Initialize(
        converter.?,
        frame.?,
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
    return .{ .bgra = bgra, .width = width, .height = height };
}

const GUID = w32.GUID;
const HRESULT = w32.HRESULT;

const GENERIC_READ: u32 = 0x80000000;
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
        /// Returns an `IWICBitmapFrameDecode`, which IS an
        /// `IWICBitmapSource` for every slot used here.
        GetFrame: *const fn (*IWICBitmapDecoder, u32, *?*IWICBitmapSource) callconv(.winapi) HRESULT,
    },
};

const IWICBitmapSource = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*IWICBitmapSource) callconv(.winapi) u32,
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
