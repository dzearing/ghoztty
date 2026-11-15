const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");

const mtl = @import("api.zig");
const Metal = @import("../Metal.zig");

const log = std.log.scoped(.metal);

/// Options for initializing a buffer.
pub const Options = struct {
    /// MTLDevice
    device: objc.Object,
    resource_options: mtl.MTLResourceOptions,
};

/// Metal data storage for a certain set of equal types. This is usually
/// used for vertex buffers, etc. This helpful wrapper makes it easy to
/// prealloc, shrink, grow, sync, buffers with Metal.
/// The byte length to allocate for a buffer that must hold `req_bytes`
/// and has outgrown its storage: double what is required, so a buffer
/// that grows a little at a time is not reallocated on every frame.
///
/// `req_bytes` is already a byte count. It must not be scaled by the
/// element size again: doing so made every cell buffer `@sizeOf(T)`
/// times too large (32x for text cells), three times over per surface.
pub fn grownByteLen(req_bytes: usize) usize {
    return req_bytes * 2;
}

test grownByteLen {
    const testing = std.testing;
    const shaderpkg = @import("shaders.zig");

    // A full 4K pane of glyphs asks for under a megabyte of text cells
    // and must be given about two, not sixty.
    const cells: usize = 30_000;
    const req = cells * @sizeOf(shaderpkg.CellText);
    try testing.expectEqual(req * 2, grownByteLen(req));
    try testing.expect(grownByteLen(req) < 2 * 1024 * 1024);
}

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The options this buffer was initialized with.
        opts: Options,

        /// The underlying MTLBuffer object.
        buffer: objc.Object,

        /// The allocated length of the buffer.
        /// Note that this is the number
        /// of `T`s not the size in bytes.
        len: usize,

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) !Self {
            const buffer = opts.device.msgSend(
                objc.Object,
                objc.sel("newBufferWithLength:options:"),
                .{
                    @as(c_ulong, @intCast(len * @sizeOf(T))),
                    opts.resource_options,
                },
            );

            return .{ .buffer = buffer, .opts = opts, .len = len };
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            const buffer = opts.device.msgSend(
                objc.Object,
                objc.sel("newBufferWithBytes:length:options:"),
                .{
                    @as(*const anyopaque, @ptrCast(data.ptr)),
                    @as(c_ulong, @intCast(data.len * @sizeOf(T))),
                    opts.resource_options,
                },
            );

            return .{ .buffer = buffer, .opts = opts, .len = data.len };
        }

        pub fn deinit(self: *const Self) void {
            self.buffer.msgSend(void, objc.sel("release"), .{});
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        ///
        /// If the amount of data is smaller than the buffer length, the
        /// remaining data in the buffer is left untouched.
        pub fn sync(self: *Self, data: []const T) !void {
            // If we need more bytes than our buffer has, we need to reallocate.
            const req_bytes = data.len * @sizeOf(T);
            const avail_bytes = self.buffer.getProperty(c_ulong, "length");
            if (req_bytes > avail_bytes) {
                // Deallocate previous buffer
                self.buffer.msgSend(void, objc.sel("release"), .{});

                // Allocate a new buffer with enough to hold double what we require.
                self.buffer = self.opts.device.msgSend(
                    objc.Object,
                    objc.sel("newBufferWithLength:options:"),
                    .{
                        @as(c_ulong, @intCast(grownByteLen(req_bytes))),
                        self.opts.resource_options,
                    },
                );
            }

            // We can fit within the buffer so we can just replace bytes.
            const dst = dst: {
                const ptr = self.buffer.msgSend(?[*]u8, objc.sel("contents"), .{}) orelse {
                    log.warn("buffer contents ptr is null", .{});
                    return error.MetalFailed;
                };

                break :dst ptr[0..req_bytes];
            };

            const src = src: {
                const ptr = @as([*]const u8, @ptrCast(data.ptr));
                break :src ptr[0..req_bytes];
            };

            @memcpy(dst, src);

            // If we're using the managed resource storage mode, then
            // we need to signal Metal to synchronize the buffer data.
            //
            // Ref: https://developer.apple.com/documentation/metal/synchronizing-a-managed-resource-in-macos?language=objc
            if (self.opts.resource_options.storage_mode == .managed) {
                self.buffer.msgSend(
                    void,
                    "didModifyRange:",
                    .{macos.foundation.Range.init(0, req_bytes)},
                );
            }
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }

            // If we need more bytes than our buffer has, we need to reallocate.
            const req_bytes = total_len * @sizeOf(T);
            const avail_bytes = self.buffer.getProperty(c_ulong, "length");
            if (req_bytes > avail_bytes) {
                // Deallocate previous buffer
                self.buffer.msgSend(void, objc.sel("release"), .{});

                // Allocate a new buffer with enough to hold double what we require.
                self.buffer = self.opts.device.msgSend(
                    objc.Object,
                    objc.sel("newBufferWithLength:options:"),
                    .{
                        @as(c_ulong, @intCast(grownByteLen(req_bytes))),
                        self.opts.resource_options,
                    },
                );
            }

            // We can fit within the buffer so we can just replace bytes.
            const dst = dst: {
                const ptr = self.buffer.msgSend(?[*]u8, objc.sel("contents"), .{}) orelse {
                    log.warn("buffer contents ptr is null", .{});
                    return error.MetalFailed;
                };

                break :dst ptr[0..req_bytes];
            };

            var i: usize = 0;

            for (lists) |list| {
                const ptr = @as([*]const u8, @ptrCast(list.items.ptr));
                @memcpy(dst[i..][0 .. list.items.len * @sizeOf(T)], ptr);
                i += list.items.len * @sizeOf(T);
            }

            // If we're using the managed resource storage mode, then
            // we need to signal Metal to synchronize the buffer data.
            //
            // Ref: https://developer.apple.com/documentation/metal/synchronizing-a-managed-resource-in-macos?language=objc
            if (self.opts.resource_options.storage_mode == .managed) {
                self.buffer.msgSend(
                    void,
                    "didModifyRange:",
                    .{macos.foundation.Range.init(0, req_bytes)},
                );
            }

            return total_len;
        }
    };
}
