const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const OpenGL = @import("../OpenGL.zig");
const upload_diff = @import("../upload_diff.zig");

/// Shadow copies live as long as their GL buffer and are only resized when
/// the buffer itself doubles, so a plain page-backed allocator is enough
/// and needs no allocator threaded through every `Buffer.init` call site.
const shadow_alloc = std.heap.page_allocator;

const log = std.log.scoped(.opengl);

/// Options for initializing a buffer.
pub const Options = struct {
    target: gl.Buffer.Target = .array,
    usage: gl.Buffer.Usage = .dynamic_draw,
};

/// OpenGL data storage for a certain set of equal types. This is usually
/// used for vertex buffers, etc. This helpful wrapper makes it easy to
/// prealloc, shrink, grow, sync, buffers with OpenGL.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Underlying `gl.Buffer` instance.
        buffer: gl.Buffer,

        /// Options this buffer was allocated with.
        opts: Options,

        /// Current allocated length of the data store.
        /// Note this is the number of `T`s, not the size in bytes.
        len: usize,

        /// CPU mirror of the data store, so a sync uploads only the bytes
        /// that changed (T2972). Allocated on the first sync; buffers that
        /// are only ever `initFill`ed never pay for it.
        shadow: upload_diff.Shadow = .{},

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) !Self {
            const buffer = try gl.Buffer.create();
            errdefer buffer.destroy();

            const binding = try buffer.bind(opts.target);
            defer binding.unbind();

            try binding.setDataNullManual(len * @sizeOf(T), opts.usage);

            return .{
                .buffer = buffer,
                .opts = opts,
                .len = len,
            };
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            const buffer = try gl.Buffer.create();
            errdefer buffer.destroy();

            const binding = try buffer.bind(opts.target);
            defer binding.unbind();

            try binding.setData(data, opts.usage);

            return .{
                .buffer = buffer,
                .opts = opts,
                .len = data.len * @sizeOf(T),
            };
        }

        pub fn deinit(self: Self) void {
            var shadow = self.shadow;
            shadow.deinit(shadow_alloc);
            self.buffer.destroy();
        }

        /// Make sure the shadow mirrors a data store of `self.len` items,
        /// forgetting what it knew if the store was just reallocated.
        fn prepareShadow(self: *Self, reallocated: bool) !void {
            const capacity = self.len * @sizeOf(T);
            if (reallocated or self.shadow.bytes.len != capacity) {
                try self.shadow.reset(shadow_alloc, capacity);
            }
        }

        /// Upload whatever the shadow says changed, as ONE glBufferSubData.
        fn flushShadow(self: *Self, binding: gl.Buffer.Binding) !void {
            const r = self.shadow.take() orelse return;
            binding.setSubData(r.start, self.shadow.bytes[r.start..r.end]) catch |err| {
                // The GPU may hold anything now; next sync uploads it all.
                self.shadow.valid = 0;
                return err;
            };
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        ///
        /// If the amount of data is smaller than the buffer length, the
        /// remaining data in the buffer is left untouched.
        pub fn sync(self: *Self, data: []const T) !void {
            const binding = try self.buffer.bind(self.opts.target);
            defer binding.unbind();

            // If we need more space than our buffer has, we need to reallocate.
            var reallocated = false;
            if (data.len > self.len) {
                // Reallocate the buffer to hold double what we require.
                self.len = data.len * 2;
                try binding.setDataNullManual(
                    self.len * @sizeOf(T),
                    self.opts.usage,
                );
                reallocated = true;
            }

            // We can fit within the buffer, so upload only the bytes that
            // differ from what it already holds (T2972).
            try self.prepareShadow(reallocated);
            self.shadow.write(0, std.mem.sliceAsBytes(data));
            try self.flushShadow(binding);
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            const binding = try self.buffer.bind(self.opts.target);
            defer binding.unbind();

            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }

            // If we need more space than our buffer has, we need to reallocate.
            var reallocated = false;
            if (total_len > self.len) {
                // Reallocate the buffer to hold double what we require.
                self.len = total_len * 2;
                try binding.setDataNullManual(
                    self.len * @sizeOf(T),
                    self.opts.usage,
                );
                reallocated = true;
            }

            // We can fit within the buffer. Lay the lists out back to back in
            // the shadow exactly as before (row order is instance order, which
            // keeps the cursor-first/last lists where the shader expects
            // them), then upload the one range that changed instead of one
            // glBufferSubData per list (T2972).
            try self.prepareShadow(reallocated);
            var i: usize = 0;
            for (lists) |list| {
                const bytes = std.mem.sliceAsBytes(list.items);
                self.shadow.write(i, bytes);
                i += bytes.len;
            }
            try self.flushShadow(binding);

            return total_len;
        }
    };
}
