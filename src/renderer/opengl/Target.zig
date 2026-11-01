//! Represents a render target.
//!
//! In this case, an OpenGL renderbuffer-backed framebuffer.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const log = std.log.scoped(.opengl);

/// Options for initializing a Target
pub const Options = struct {
    /// Desired width
    width: usize,
    /// Desired height
    height: usize,

    /// Internal format for the renderbuffer.
    internal_format: gl.Texture.InternalFormat,

    /// Allocate in `grow_bucket` steps and let `resizeInPlace` take any size
    /// that fits (Win32, T2577): a window-edge drag changes the size on every
    /// step, and a new renderbuffer and framebuffer per step was most of the
    /// first frame at each size. The frame is drawn and read in the bottom-left
    /// `width` x `height`, which the viewport and every blit already bound.
    grow_only: bool = false,
};

/// See `Options.grow_only`.
pub const grow_bucket: usize = 256;

/// The storage `init` gives a `need` px side.
pub fn capacityFor(need: usize, grow_only: bool) usize {
    if (!grow_only) return need;
    return (std.math.divCeil(usize, @max(need, 1), grow_bucket) catch unreachable) * grow_bucket;
}

/// The underlying `gl.Framebuffer` instance.
framebuffer: gl.Framebuffer,

/// The underlying `gl.Renderbuffer` instance.
renderbuffer: gl.Renderbuffer,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

/// The renderbuffer's own size, at least `width` x `height`.
alloc_width: usize = 0,
alloc_height: usize = 0,
grow_only: bool = false,

pub fn init(opts: Options) !Self {
    const aw = capacityFor(opts.width, opts.grow_only);
    const ah = capacityFor(opts.height, opts.grow_only);
    const rbo = try gl.Renderbuffer.create();
    const bound_rbo = try rbo.bind();
    defer bound_rbo.unbind();
    try bound_rbo.storage(
        opts.internal_format,
        @intCast(aw),
        @intCast(ah),
    );

    const fbo = try gl.Framebuffer.create();
    const bound_fbo = try fbo.bind(.framebuffer);
    defer bound_fbo.unbind();
    try bound_fbo.renderbuffer(.color0, rbo);

    return .{
        .framebuffer = fbo,
        .renderbuffer = rbo,
        .width = opts.width,
        .height = opts.height,
        .alloc_width = aw,
        .alloc_height = ah,
        .grow_only = opts.grow_only,
    };
}

/// Take a new size without new storage, when the target is `grow_only` and
/// the size fits what it has. False: the caller makes a new target.
pub fn resizeInPlace(self: *Self, width: usize, height: usize) bool {
    if (!self.grow_only or width > self.alloc_width or height > self.alloc_height) return false;
    self.width = width;
    self.height = height;
    return true;
}

test "a grow-only target takes any size that fits and rounds its storage up" {
    try std.testing.expectEqual(@as(usize, 512), capacityFor(469, true));
    try std.testing.expectEqual(@as(usize, 256), capacityFor(256, true));
    try std.testing.expectEqual(@as(usize, 469), capacityFor(469, false));
    var t: Self = .{ .framebuffer = undefined, .renderbuffer = undefined, .width = 469, .height = 723, .alloc_width = 512, .alloc_height = 768, .grow_only = true };
    try std.testing.expect(t.resizeInPlace(451, 723));
    try std.testing.expectEqual(@as(usize, 451), t.width);
    try std.testing.expect(t.resizeInPlace(512, 768));
    try std.testing.expect(!t.resizeInPlace(513, 700));
    t.grow_only = false;
    try std.testing.expect(!t.resizeInPlace(400, 400));
}

pub fn deinit(self: *Self) void {
    self.framebuffer.destroy();
    self.renderbuffer.destroy();
}
