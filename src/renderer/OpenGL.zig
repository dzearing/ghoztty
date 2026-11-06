//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const gl = @import("opengl");
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const gl_report = @import("gl_report.zig");
const low_power = @import("low_power.zig");
const gl_loader = @import("gl_loader.zig");
const gl_robust = @import("gl_robust.zig");
const gl_comp_present = @import("gl_comp_present.zig");
const comp_overlay = @import("comp_overlay.zig");
const build_config = @import("../build_config.zig");
const resize_paint = @import("../apprt/win32/resize_paint.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// Because OpenGL's frame completion is always
/// sync, we have no need for multi-buffering.
pub const swap_chain_count = 1;

const log = std.log.scoped(.opengl);

/// Win32 window declarations used alongside the GL context. The GL and WGL
/// entry points themselves are NOT here any more: they are resolved at run time
/// out of whichever implementation `gl_loader` chose, so that a machine whose
/// display driver cannot meet the version floor has a second one to try
/// (T1251). Binding them statically would also mean an `opengl32.dll` sitting
/// beside the exe was loaded for every launch, which is the hijack that made
/// the fallback unsafe to ship.
const wgl = if (apprt.runtime == apprt.win32) struct {
    extern "user32" fn WindowFromDC(hdc: ?*anyopaque) callconv(.c) ?std.os.windows.HWND;
    const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
    extern "user32" fn GetClientRect(
        hwnd: std.os.windows.HWND,
        rect: *RECT,
    ) callconv(.c) i32;
    extern "kernel32" fn WaitForSingleObject(h: std.os.windows.HANDLE, ms: u32) callconv(.c) u32;
} else struct {};

/// We require at least OpenGL 4.3. Defined in `gl_report` rather than here so
/// the startup dialog can format the SAME numbers into the sentence it shows a
/// user whose display cannot meet them (T1224) - a floor that lives in two
/// places is a floor that eventually disagrees with the message about it.
pub const MIN_VERSION_MAJOR = gl_report.min_version_major;
pub const MIN_VERSION_MINOR = gl_report.min_version_minor;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The surface this renderer draws, kept only so the once-a-second frame
/// telemetry can name its pane (T1147). Deliberately NOT threadlocal state:
/// the first cut of this hung the pane id off `threadEnter`'s thread and
/// every sample logged `pane=-`, because the thread that enters the context
/// is not reliably the thread `drawFrameEnd` runs on. `drawFrameEnd` has
/// `self`, so `self` is where the answer belongs.
rt_surface: *apprt.Surface,

/// The most recently presented target, in case we need to present it again.
last_target: ?Target = null,

/// The client size the frame in progress is being drawn for, packed by
/// `resize_paint.packSize` (T2418): measured by `surfaceSize` at the start of
/// the frame and held against the window again in `drawFrameEnd`, which drops
/// the swap when the layout resized the pane in between. Win32 only; renderer
/// thread only.
drawn_client: u64 = 0,

/// The client size the previous frame was drawn for (T2485 D22), so a frame
/// can tell it is the first at a new size. Win32 only; renderer thread only.
resize_prev_client: u64 = 0,

/// Set by `surfaceSize` on the first frame at a new client size, read by
/// `drawFrameEnd` (T2485 D22 `GHOZTTY_RESIZE_FIX=twice`).
resize_first_frame: bool = false,

/// A frame's swap was dropped because the back buffer had not taken the
/// whole blit (T2485 D22 `verify`), so the next frame checks again even if
/// its size did not change. Renderer thread only.
resize_verify_pending: bool = false,

/// The 2x1 plain-RGBA framebuffer the D22 corner check copies into
/// (`probeFbo`). Owned by the GL context, like `snap_fbo`.
probe_fbo: ?gl.Framebuffer = null,
probe_rbo: ?gl.Renderbuffer = null,

/// The frame lab's planted magenta frame (T2383, `apprt/win32/lab_plant.zig`):
/// set by the renderer for one frame, consumed by the next `present`, which
/// clears the window to magenta instead of blitting the target. Renderer
/// thread only, like the rest of this struct.
lab_erase_next: bool = false,

/// Lazily-created FBO + renderbuffer used to downscale the last target
/// for hero-mode thumbnails (T59a, win32 only). Sized snap_w x snap_h.
/// Owned by the GL context (freed with it; renderer-thread only).
snap_fbo: ?gl.Framebuffer = null,
snap_rbo: ?gl.Renderbuffer = null,
snap_w: u32 = 0,
snap_h: u32 = 0,

/// Lost-device state (T1690, win32 only). Renderer-thread only, like every
/// other GL-touching field here.
device: DeviceState = .{},

/// The composition swap chain this pane presents through instead of
/// `SwapBuffers` (T2466, `gl_comp_present.zig`), when `GHOZTTY_COMP_PRESENT`
/// opted it in and the chain could be built. Null means the WGL path. Heap
/// allocated so the `*const` `threadExit` can still tear it down.
comp: ?*gl_comp_present.Presenter = null,

/// Whether this context has decided between the two paths yet. A failure
/// leaves it set with `comp` null: the pane stays on WGL until its context is
/// rebuilt.
comp_tried: bool = false,

/// The window presenter path (T2610 step 3c, T2615): when the surface has a
/// `present_link`, `present` blits the target into one of the link's two
/// slot textures through this FBO, and `drawFrameEnd` fences and publishes
/// it instead of swapping. Renderer thread only.
pres_fbo: ?gl.Framebuffer = null,
/// Each slot texture's storage, grown in `Target.grow_bucket` steps like the
/// target's, so a window-edge drag does not reallocate on every step.
pres_cap: [2][2]u32 = .{ .{ 0, 0 }, .{ 0, 0 } },
/// The slot `present` drew into, owed a publish by `drawFrameEnd`.
pres_slot: ?u1 = null,
pres_w: u32 = 0,
pres_h: u32 = 0,
pres_frame_id: u64 = 0,
/// A frame has been published: the presenter holds it, so a repeat of the
/// last target (`presentLastTarget`) has nothing to add.
pres_has_frame: bool = false,
/// The presenter generation this context was in when it was lost (T2616):
/// a rebuild waits until the presenter's is past it, so the new context
/// joins the presenter's NEW group rather than the dead one.
pres_lost_gen: u32 = 0,

const DeviceState = struct {
    /// The context stopped answering: a driver reset or swap. Every GPU
    /// resource the renderer owns is dead with it.
    lost: bool = false,

    /// Rebuild attempts made since the loss, for the backoff schedule.
    attempts: u32 = 0,

    /// Earliest moment (`std.time.milliTimestamp`) the next attempt may run,
    /// or null for "now".
    next_attempt_ms: ?i64 = null,

    /// Frames presented, for the debug-only simulation hook.
    frames: u64 = 0,

    /// The debug-only simulation has already fired for this renderer.
    simulated: bool = false,

    /// Rebuild attempts still to fail on purpose (debug-only simulation).
    sim_failures_left: u32 = 0,

    /// Successful rebuilds, for the log line a harness reads.
    rebuilds: u32 = 0,
};

/// NOTE: This is an error{}!OpenGL instead of just OpenGL for parity with
///       Metal, since it needs to be fallible so does this, even though it
///       can't actually fail.
pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!OpenGL {
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .rt_surface = opts.rt_surface,
    };
}

pub fn deinit(self: *OpenGL) void {
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".calling_convention;

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// The NUL-terminated string a GL context returns for `name`, or "" when the
/// context is too primitive to answer. Borrowed from GL memory, so callers copy
/// it (`gl_report.Str`) rather than hold it.
fn glString(name: gl.c.GLenum) []const u8 {
    const get = gl.glad.context.GetString orelse return "";
    const ptr = get(name) orelse return "";
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(ptr)), 0);
}

/// Debug-only seam that makes a context REPORT an older version than it has, so
/// the too-old path can be exercised on a developer box (T1224). The failure it
/// stands in for - a Remote Desktop session, where the display driver offers
/// OpenGL 1.1 - cannot be produced any other way from outside the process, and
/// a startup refusal nobody has ever watched fire is a refusal nobody knows the
/// wording of. Format: `GHOZTTY_GL_FORCE_VERSION=1.1`. Never compiled into a
/// release build: an environment variable must not be able to stop a user's
/// terminal from opening.
fn forcedVersion() ?struct { major: u32, minor: u32 } {
    if (comptime !build_config.is_debug) return null;

    // Only ever applied to the SYSTEM implementation. The state being
    // simulated is "this machine's display driver is too old", and a seam that
    // also aged the fallback would make the fallback path untestable - the
    // retry would land on a context that reports 1.1 as well and the app would
    // refuse exactly as if nothing had been tried (T1251).
    if (comptime apprt.runtime == apprt.win32) {
        if (gl_loader.activeKind() != .system) return null;
    }

    const raw = std.process.getEnvVarOwned(
        std.heap.page_allocator,
        "GHOZTTY_GL_FORCE_VERSION",
    ) catch return null;
    defer std.heap.page_allocator.free(raw);
    if (raw.len == 0 or raw.len > 32) return null;

    var it = std.mem.splitScalar(u8, raw, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch return null;
    log.warn("GL version forced to {d}.{d} (debug test hook)", .{ major, minor });
    return .{ .major = major, .minor = minor };
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = try gl.glad.load(getProcAddress);
    var major: u32 = @intCast(gl.glad.versionMajor(@intCast(version)));
    var minor: u32 = @intCast(gl.glad.versionMinor(@intCast(version)));
    errdefer gl.glad.unload();

    // Capture WHO is providing this context, not just which version. Over
    // Remote Desktop the answer is "GDI Generic / Microsoft Corporation", and
    // that pair is the difference between a bug report that explains itself
    // and one that says only `OpenGLOutdated` (T1224).
    var report: gl_report.Report = .{
        .vendor = gl_report.Str.of(glString(gl.c.GL_VENDOR)),
        .renderer = gl_report.Str.of(glString(gl.c.GL_RENDERER)),
    };
    if (forcedVersion()) |forced| {
        major = forced.major;
        minor = forced.minor;
    }
    report.major = major;
    report.minor = minor;
    gl_report.record(report);

    // A renderer that rasterizes on the CPU turns on low-power rendering for
    // the whole app (T1951): every present there is CPU time.
    low_power.setSoftware(
        low_power.isSoftwareRenderer(report.renderer.slice(), report.vendor.slice()),
        report.renderer.slice(),
        report.vendor.slice(),
    );

    log.info("loaded OpenGL {}.{} renderer=\"{s}\" vendor=\"{s}\" impl={s}", .{
        major,
        minor,
        report.renderer.slice(),
        report.vendor.slice(),
        if (comptime apprt.runtime == apprt.win32)
            gl_loader.activeKind().label()
        else
            "system",
    });

    // Need to check version before trying to enable it
    if (report.belowFloor()) {
        log.warn(
            "OpenGL version is too old. Ghoztty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Enable debug output for the context.
    try gl.enable(gl.c.GL_DEBUG_OUTPUT);

    // Register our debug message callback with the OpenGL context.
    gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
}

/// This is called early right after surface creation.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        // GTK uses global OpenGL context so we load from null.
        apprt.gtk,
        => try prepareContext(null),

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },

        apprt.win32 => {
            // For Win32/WGL, make the context current on the main thread.
            // It stays current through Renderer.init() and finalizeSurfaceInit()
            // so OpenGL resources (shaders, textures, buffers) can be created.
            // It will be released in finalizeSurfaceInit (displayRealized)
            // right before the renderer thread is spawned.
            const hdc = surface.hdc orelse return error.InvalidSurface;
            const hglrc = surface.hglrc orelse return error.InvalidSurface;

            if (gl_loader.active().makeCurrent(hdc, hglrc) == 0)
                return error.WGLMakeCurrentFailed;

            // Load GL functions through the implementation `gl_loader`
            // chose. Passing null here would send GLAD to its own built-in
            // loader, which does its own `LoadLibraryA("opengl32.dll")` and
            // would undo the runtime selection entirely (T1251).
            // Explicitly typed so glad's loader dispatch matches on the type
            // rather than falling through to its `@ptrCast` branch.
            const loader: gl_loader.GladLoadFn = gl_loader.gladLoad;
            try prepareContext(loader);

            // NOTE: We intentionally do NOT release the context here.
            // Renderer.init() needs a current GL context to create resources.
            // The context is released in finalizeSurfaceInit/displayRealized.
        },
    }

    // These are very noisy so this is commented, but easy to uncomment
    // whenever we need to check the OpenGL extension list
    // if (builtin.mode == .Debug) {
    //     var ext_iter = try gl.ext.iterator();
    //     while (try ext_iter.next()) |ext| {
    //         log.debug("OpenGL extension available name={s}", .{ext});
    //     }
    // }
}

/// This is called just prior to spinning up the renderer
/// thread for final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;

    // On Win32, release the WGL context from the main thread so the
    // renderer thread can make it current in threadEnter. The context
    // was kept current since surfaceInit to allow Renderer.init() to
    // create GL resources.
    if (comptime apprt.runtime == apprt.win32) {
        _ = gl_loader.active().makeCurrent(null, null);
    }
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // GTK doesn't support threaded OpenGL operations as far as I can
            // tell, so we use the renderer thread to setup all the state
            // but then do the actual draws and texture syncs and all that
            // on the main thread. As such, we don't do anything here.
        },

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },

        apprt.win32 => {
            // Make the WGL context current on the renderer thread.
            const hdc = surface.hdc orelse return error.InvalidSurface;
            const hglrc = surface.hglrc orelse return error.InvalidSurface;

            if (gl_loader.active().makeCurrent(hdc, hglrc) == 0)
                return error.WGLMakeCurrentFailed;

            // Reload GL functions on this thread since OpenGL is
            // thread-local state. Same loader as the main thread used, so a
            // pane never ends up half on one implementation and half on the
            // other.
            // Explicitly typed so glad's loader dispatch matches on the type
            // rather than falling through to its `@ptrCast` branch.
            const loader: gl_loader.GladLoadFn = gl_loader.gladLoad;
            try prepareContext(loader);

            // The OS thread is pooled (T2644, `os/reusable_thread.zig`): it
            // may have rendered another pane before this one, so per-thread
            // state starts over here rather than at thread creation.
            reset_status_resolved = false;
            reset_status_fn = null;
            perf.reset();
        },
    }
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const OpenGL) void {
    // Used only by the win32 branch; see drawFrameEnd for the `&` idiom.
    _ = &self;
    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // We don't need to do any unloading for GTK because we may
            // be sharing the global bindings with other windows.
        },

        apprt.embedded => {
            // TODO: see threadEnter
        },

        apprt.win32 => {
            // The presenter's GL names and interop device belong to this
            // context, so they go while it is still current.
            if (self.comp) |p| {
                compRetract(self);
                p.deinit();
                self.alloc.destroy(p);
            }
            // T2615: off the presenter first, then the slot textures and
            // fences go while this context is current.
            if (self.rt_surface.present_link) |l| presRetire(self, l);
            // Release the WGL context from the renderer thread.
            _ = gl_loader.active().makeCurrent(null, null);
        },
    }
}

pub fn displayRealized(self: *const OpenGL) void {
    _ = self;

    switch (apprt.runtime) {
        apprt.gtk => prepareContext(null) catch |err| {
            log.warn(
                "Error preparing GL context in displayRealized, err={}",
                .{err},
            );
        },

        apprt.win32 => {
            // Release the WGL context from the main thread so the
            // renderer thread can make it current in threadEnter.
            // The context was kept current since surfaceInit to allow
            // Renderer.init() to create GL resources.
            _ = gl_loader.active().makeCurrent(null, null);
        },

        else => @compileError("only GTK should be calling displayRealized"),
    }
}

/// Actions taken before doing anything in `drawFrame`.
///
/// On Win32, stamps the frame's start on the resize trace (T2577).
pub fn drawFrameStart(self: *OpenGL) void {
    self.traceStage("draw-begin");
}

/// A stage of this frame on the Win32 resize trace (T2577); nothing elsewhere.
pub fn traceStage(self: *const OpenGL, comptime what: []const u8) void {
    if (comptime apprt.runtime != apprt.win32) {
        _ = &self;
        return;
    }
    self.rt_surface.traceStage(what);
}

const ResizeFix = enum { off, rebind, twice, verify };
var resize_fix_state: ?ResizeFix = null;

/// `GHOZTTY_RESIZE_FIX` (T2485 D22): `rebind` by default (run67: black
/// frames 9 -> 0 against run65 off, no cost to the glide); `off` for an A/B,
/// `twice` for the alternative that presents the frame again (black 0 too, but
/// gaps 4 -> 20, run66). `verify` is a diagnostic: the rebind plus a read-back
/// of the back buffer's far corner before each first swap at a new size,
/// retried and then dropped when stale, with a `stack trace verify` line. It
/// showed the near-full window's black strips are NOT a stale back buffer
/// (20261101-004809: 153 of 153 first swaps landed whole). Read once.
fn resizeFix() ResizeFix {
    if (resize_fix_state) |v| return v;
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_RESIZE_FIX") catch null;
    defer if (raw) |r| std.heap.page_allocator.free(r);
    const v = parseResizeFix(raw);
    resize_fix_state = v;
    return v;
}

fn parseResizeFix(raw: ?[]const u8) ResizeFix {
    const r = raw orelse return .rebind;
    return std.meta.stringToEnum(ResizeFix, std.mem.trim(u8, r, " \t\r\n")) orelse .rebind;
}

/// How many times `landBackBuffer` re-makes the context current and blits
/// again before it gives up on a frame.
const verify_retries: u8 = 3;

/// Has the back buffer taken the whole blit? Its colour against the target's
/// at the same pixel; alpha is left out, since the window's default
/// framebuffer may have none. A back buffer still at the old size reads
/// nothing there (black, or whatever is outside the drawable).
fn cornerLanded(target_px: [4]u8, back_px: [4]u8) bool {
    return std.mem.eql(u8, target_px[0..3], back_px[0..3]);
}

/// Blit `target` until the back buffer's far corner holds it (T2485 D22),
/// re-making the context current before each retry. Returns the attempt that
/// landed (0 = the blit `present` already made), or `verify_retries + 1` when
/// none did. Renderer thread, Win32 swap path only.
fn landBackBuffer(self: *OpenGL, hdc: anytype, target: Target) u8 {
    if (target.width == 0 or target.height == 0) return 0;
    const x: gl.c.GLint = @intCast(target.width - 1);
    const y: gl.c.GLint = @intCast(target.height - 1);
    const probe = self.probeFbo() orelse return 0;
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        const px = probeCorner(probe, target.framebuffer.id, x, y);
        if (cornerLanded(px[0], px[1])) return attempt;
        if (attempt == verify_retries) return attempt + 1;
        const api = gl_loader.active();
        _ = api.makeCurrent(hdc, api.getCurrentContext());
        self.present(target) catch return verify_retries + 1;
    }
}

/// The 2x1 plain-RGBA framebuffer the corner check copies into, made on
/// first use. Null when it cannot be made: the check then passes, as before
/// it existed.
fn probeFbo(self: *OpenGL) ?gl.Framebuffer {
    if (self.probe_fbo) |f| return f;
    const rbo = gl.Renderbuffer.create() catch return null;
    const fbo = gl.Framebuffer.create() catch return null;
    {
        const rb = rbo.bind() catch return null;
        defer rb.unbind();
        rb.storage(.rgba, 2, 1) catch return null;
    }
    {
        const fb = fbo.bind(.framebuffer) catch return null;
        defer fb.unbind();
        fb.renderbuffer(.color0, rbo) catch return null;
    }
    self.probe_rbo = rbo;
    self.probe_fbo = fbo;
    return fbo;
}

/// Pixel (x, y) of the target and of the window's back buffer, copied raw
/// into the probe's two pixels and read from there. Both go through the same
/// blit with sRGB conversion off, the way `present` copies, so an sRGB target
/// and a linear back buffer read as equal when they hold the same bytes.
fn probeCorner(probe: gl.Framebuffer, target_fbo: gl.c.GLuint, x: gl.c.GLint, y: gl.c.GLint) [2][4]u8 {
    const ctx = &gl.glad.context;
    var px: [2][4]u8 = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } };
    gl.disable(gl.c.GL_FRAMEBUFFER_SRGB) catch return px;
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch {};
    ctx.BindFramebuffer.?(gl.c.GL_DRAW_FRAMEBUFFER, probe.id);
    ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, target_fbo);
    ctx.ReadBuffer.?(gl.c.GL_COLOR_ATTACHMENT0);
    ctx.BlitFramebuffer.?(x, y, x + 1, y + 1, 0, 0, 1, 1, gl.c.GL_COLOR_BUFFER_BIT, gl.c.GL_NEAREST);
    ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, 0);
    ctx.ReadBuffer.?(gl.c.GL_BACK);
    ctx.BlitFramebuffer.?(x, y, x + 1, y + 1, 1, 0, 2, 1, gl.c.GL_COLOR_BUFFER_BIT, gl.c.GL_NEAREST);
    ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, probe.id);
    ctx.ReadBuffer.?(gl.c.GL_COLOR_ATTACHMENT0);
    ctx.PixelStorei.?(gl.c.GL_PACK_ALIGNMENT, 1);
    ctx.ReadPixels.?(0, 0, 2, 1, gl.c.GL_RGBA, gl.c.GL_UNSIGNED_BYTE, &px);
    ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, 0);
    ctx.BindFramebuffer.?(gl.c.GL_DRAW_FRAMEBUFFER, 0);
    return px;
}

test "the D22 verify reads a back buffer as landed only when its colour is the target's" {
    try std.testing.expect(cornerLanded(.{ 30, 30, 36, 255 }, .{ 30, 30, 36, 0 }));
    try std.testing.expect(!cornerLanded(.{ 30, 30, 36, 255 }, .{ 0, 0, 0, 255 }));
    try std.testing.expect(!cornerLanded(.{ 30, 30, 36, 255 }, .{ 30, 30, 37, 255 }));
    try std.testing.expectEqual(ResizeFix.rebind, parseResizeFix(null));
    try std.testing.expectEqual(ResizeFix.rebind, parseResizeFix("bogus"));
    try std.testing.expectEqual(ResizeFix.verify, parseResizeFix("verify"));
    try std.testing.expectEqual(ResizeFix.off, parseResizeFix("off\r\n"));
    try std.testing.expectEqual(ResizeFix.twice, parseResizeFix("twice"));
}

/// Actions taken after `drawFrame` is done.
///
/// On Win32 with double-buffered WGL, swap the front/back buffers
/// so the rendered frame appears on screen.
pub fn drawFrameEnd(self: *OpenGL) void {
    if (comptime apprt.runtime != apprt.win32) {
        // `_ = &self` rather than `_ = self`: on win32 `self` IS used below,
        // and a plain discard of a parameter that the function also uses is a
        // "pointless discard" compile error.
        _ = &self;
        return;
    }

    const hdc = gl_loader.active().getCurrentDC();
    // T2615: on the window presenter path there is no swap. The frame goes
    // to the presenter, which composes every pane and swaps once; a frame the
    // layout outran is not dropped either, because the presenter crops or
    // fills it to the pane's rectangle as it stands at compose time.
    if (self.rt_surface.present_link) |l| {
        self.presPublish(l);
        if (hdc != null) self.checkDevice();
        perf.frame(self.rt_surface, 0);
        return;
    }
    var swap_ns: u64 = 0;
    // T2418 experiment (`resize_paint.presentRetireOn`): the size check, the
    // swap and the GPU's retirement of it, all before the layout may move us.
    const retire = resize_paint.presentRetireOn();
    if (retire) resize_paint.present_gate.lockShared();
    defer if (retire) resize_paint.present_gate.unlockShared();
    // T2418: a frame the layout outran is dropped, not swapped. Its pixels are
    // for the size the pane had when the frame began, and the swap would put
    // them at the place the pane has now: the divider drag's doubled first
    // column, and a blit over the gutter the window has just painted. The
    // resize that changed the size already asked for the next frame, and the
    // layout's frame wait keeps waiting, since this one reports its old size.
    if (hdc != null and self.frameOutlivedItsWindow(hdc.?)) {
        // The composition path still owes the interop unlock (T2466).
        if (self.comp) |p| p.end(false) catch |err| self.compFail(err);
        log.debug("frame dropped: the window was resized while it was drawn", .{});
        self.rt_surface.tracePresent(self.drawn_client, false);
        return;
    }
    if (hdc != null) {
        // T1458: time the present itself, not just the gap between presents.
        // `max_gap_ms` below cannot tell "idle, nothing to draw" from "the
        // present blocked", and on a streamed/virtual display the present is
        // the leading suspect: the frame renders on one adapter and has to
        // reach a virtual display owned by another driver. `perf.now()` is a
        // no-op when telemetry is off, so this costs one branch per frame.
        // T2485 D22 `verify` (opt-in diagnostic): did the back buffer take
        // the whole blit of a first frame at a new size? Read the far corner
        // back; still stale after the retries, the swap is dropped, so the
        // strip keeps the background `fillUncoveredStrips` laid there, and the
        // next frame checks again.
        if (self.comp == null and resizeFix() == .verify and
            (self.resize_first_frame or self.resize_verify_pending))
        {
            if (self.last_target) |t| {
                const tries = self.landBackBuffer(hdc.?, t);
                self.rt_surface.traceVerify(self.drawn_client, tries, tries <= verify_retries);
                if (tries > verify_retries) {
                    self.resize_verify_pending = true;
                    self.rt_surface.tracePresent(self.drawn_client, false);
                    return;
                }
            }
            self.resize_verify_pending = false;
        }
        // T2666: a frame the window is gathering into one burst waits here
        // for its release (bounded), drawn and ready.
        self.rt_surface.holdSwap(self.drawn_client);
        const swap_start = perf.now();
        self.traceStage("swap-begin");
        if (self.comp) |p| {
            p.end(true) catch |err| self.compFail(err);
        } else {
            _ = gl_loader.active().swapBuffers(hdc);
        }
        if (retire) gl.finish();
        self.rt_surface.tracePresent(self.drawn_client, true);
        // T2485 D22 experiment: present the first frame at a new size twice,
        // so the second swap lands in a back buffer the driver has resized.
        if (self.resize_first_frame and resizeFix() == .twice and self.comp == null) {
            self.resize_first_frame = false;
            if (self.last_target) |t| {
                self.present(t) catch {};
                _ = gl_loader.active().swapBuffers(hdc);
                self.rt_surface.tracePresent(self.drawn_client, true);
            }
        }
        if (swap_start) |start| {
            if (perf.now()) |end| swap_ns = end.since(start);
        }

        // T1690: once per presented frame, ask whether the device is still
        // there. Only where this thread has the context current — the reset
        // status belongs to the context, not to the process.
        self.checkDevice();
    }
    perf.frame(self.rt_surface, swap_ns);
}

// -------------------------------------------------------------------------
// Lost-device recovery (T1690). See `gl_robust.zig` for the why; this is the
// renderer-thread half that notices a loss and builds a new context. The GPU
// resources the generic renderer owns are rebuilt by
// `GenericRenderer.recoverLostContext`, which drives these.
// -------------------------------------------------------------------------

/// `glGetGraphicsResetStatus`, resolved once per thread and again after every
/// rebuild. Per thread for the same reason the glad context is: a GL entry
/// point is only meaningful where the context it came from is current.
threadlocal var reset_status_fn: ?*const fn () callconv(.winapi) u32 = null;
threadlocal var reset_status_resolved: bool = false;

fn resetStatusFn() ?*const fn () callconv(.winapi) u32 {
    if (comptime apprt.runtime != apprt.win32) return null;
    if (!reset_status_resolved) {
        reset_status_resolved = true;
        const api = gl_loader.active();
        const p = api.proc("glGetGraphicsResetStatus") orelse
            api.proc("glGetGraphicsResetStatusARB");
        reset_status_fn = if (p) |f| @ptrCast(f) else null;
    }
    return reset_status_fn;
}

/// Debug-only seams that let an acceptance script drive the recovery path on
/// a box whose driver nobody is going to reset on purpose (T1690), the same
/// pattern and the same rule as `GHOZTTY_GL_FORCE_VERSION`: never compiled into
/// a release build.
///
/// - `GHOZTTY_GL_SIMULATE_RESET_AFTER=<n>`: after the n-th presented frame,
///   report the context as lost. The rebuild that follows is entirely real —
///   the live context is deleted and a new one created — so what it proves is
///   that the renderer draws again from a brand-new context.
/// - `GHOZTTY_GL_SIMULATE_REBUILD_FAILURES=<k>`: after a simulated loss, the
///   first k rebuild attempts OF EACH PANE fail, which is the shape of a driver
///   swap that leaves the machine without usable OpenGL for a while. Per pane
///   rather than per process so the outcome is deterministic however many
///   panes are open.
const sim = struct {
    var loaded: bool = false;
    var reset_after: ?u64 = null;
    var rebuild_failures: u32 = 0;
    var lock: std.Thread.Mutex = .{};

    fn load() void {
        if (comptime !build_config.is_debug) return;
        lock.lock();
        defer lock.unlock();
        if (loaded) return;
        loaded = true;
        reset_after = envInt("GHOZTTY_GL_SIMULATE_RESET_AFTER");
        if (envInt("GHOZTTY_GL_SIMULATE_REBUILD_FAILURES")) |k|
            rebuild_failures = @intCast(@min(k, 1000));
    }

    fn envInt(name: []const u8) ?u64 {
        const raw = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return null;
        defer std.heap.page_allocator.free(raw);
        return std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null;
    }
};

fn checkDevice(self: *OpenGL) void {
    if (comptime apprt.runtime != apprt.win32) return;
    if (self.device.lost) return;
    self.device.frames +%= 1;

    // T2616: the window presenter rebuilt its context after a loss it, or
    // another pane, saw first. This context is in the group it left, so it
    // goes too, without reporting: the presenter already knows.
    if (self.rt_surface.present_link) |l| if (l.stale()) {
        self.markLost("the window presenter rebuilt its context", false);
        return;
    };

    if (comptime build_config.is_debug) {
        sim.load();
        if (!self.device.simulated) if (sim.reset_after) |n| {
            if (self.device.frames >= n) {
                self.device.simulated = true;
                self.markLost("simulated (debug test hook)", true);
                self.device.sim_failures_left = sim.rebuild_failures;
                return;
            }
        };
    }

    const get = resetStatusFn() orelse return;
    const status = gl_robust.ResetStatus.fromGl(get());
    if (status.lost()) self.markLost(@tagName(status), true);
}

/// `report`: on the window presenter path, tell the presenter, which owns
/// the share group and rebuilds first (T2616). False when the loss IS the
/// presenter's rebuild.
fn markLost(self: *OpenGL, why: []const u8, report: bool) void {
    self.device.lost = true;
    self.device.attempts = 0;
    self.device.next_attempt_ms = null;

    // Everything below names objects in the dead context. They are dropped,
    // never deleted: once a new context exists those names can belong to ITS
    // objects, and deleting them would destroy live resources.
    self.last_target = null;
    self.snap_fbo = null;
    self.snap_rbo = null;
    self.probe_fbo = null;
    self.probe_rbo = null;
    self.snap_w = 0;
    self.snap_h = 0;
    if (self.comp) |p| {
        compRetract(self);
        p.abandon();
        self.alloc.destroy(p);
        self.comp = null;
    }
    // The rebuilt context gets to choose its path again.
    self.comp_tried = false;

    // The window presenter path (T2616): the FBO, the slot sizes and the
    // owed publish all name the dead group's objects. The link's own slot
    // textures and fences are dropped by `rejoin`, once rebuilt.
    self.pres_fbo = null;
    self.pres_cap = .{ .{ 0, 0 }, .{ 0, 0 } };
    self.pres_slot = null;
    self.pres_has_frame = false;
    if (self.rt_surface.present_link) |l| {
        self.pres_lost_gen = l.gen;
        if (report) l.reportLost();
    }

    log.warn("graphics device lost ({s}); rebuilding this pane's renderer", .{why});
}

/// The new context came up but the renderer could not rebuild its resources
/// in it (shader compile, buffer allocation). Treat it as still lost and try
/// the whole rebuild again on the backoff.
pub fn markRebuildIncomplete(self: *OpenGL) void {
    self.device.lost = true;
    self.device.next_attempt_ms = std.time.milliTimestamp() +
        gl_robust.retryDelayMs(self.device.attempts);
}

/// Whether the context was lost and has not been rebuilt yet.
pub fn contextLost(self: *const OpenGL) bool {
    return self.device.lost;
}

/// Milliseconds until the next rebuild attempt may run: 0 when one is due now,
/// null when nothing is lost.
pub fn rebuildDelayMs(self: *const OpenGL) ?u64 {
    if (!self.device.lost) return null;
    const next = self.device.next_attempt_ms orelse return 0;
    const now = std.time.milliTimestamp();
    if (now >= next) return 0;
    return @intCast(next - now);
}

/// Replace the dead context with a new one on the same window and make it
/// current on this (the renderer) thread. The caller has already released
/// every GPU resource it held in the old one, while the old one was still
/// current. On failure the next attempt is scheduled on the backoff and the
/// error returned; the caller tries again when `rebuildDelayMs` says so.
pub fn rebuildContext(self: *OpenGL) !void {
    if (comptime apprt.runtime != apprt.win32) return error.Unsupported;

    // T2616: on the window presenter path the new context joins the
    // presenter's group, and the presenter rebuilds its own first. Until it
    // has, a context made now would join the dead group: come back shortly,
    // without spending an attempt, since nothing has failed.
    const link = self.rt_surface.present_link;
    if (link) |l| if (!l.presenterPast(self.pres_lost_gen)) {
        self.device.next_attempt_ms = std.time.milliTimestamp() + pres_rebuild_poll_ms;
        return error.WaitingForWindowPresenter;
    };

    const attempt = self.device.attempts;
    self.device.attempts +|= 1;
    errdefer |err| {
        const delay = gl_robust.retryDelayMs(self.device.attempts);
        self.device.next_attempt_ms = std.time.milliTimestamp() + delay;
        if (gl_robust.shouldLogAttempt(attempt)) log.warn(
            "graphics device rebuild attempt {d} failed: {}; next try in {d}ms",
            .{ attempt + 1, err, delay },
        );
    }

    if (comptime build_config.is_debug) {
        if (self.device.sim_failures_left > 0) {
            self.device.sim_failures_left -= 1;
            return error.SimulatedRebuildFailure;
        }
    }

    const surface = self.rt_surface;
    const hdc = surface.hdc orelse return error.InvalidSurface;
    const api = gl_loader.active();

    _ = api.makeCurrent(null, null);
    if (surface.hglrc) |old| {
        _ = api.deleteContext(@ptrCast(old));
        surface.hglrc = null;
    }

    // On the presenter path, through the presenter's share handshake (its
    // thread lets go of its context for the moment), into its new group; the
    // link then drops everything it named in the old one. A detached link
    // means the window is going: any context will do for the rest of it.
    const created = created: {
        if (link) |l| if (l.attached()) {
            const shared = l.sharedContext(@ptrCast(hdc)) orelse
                return error.GLContextCreateFailed;
            l.rejoin(shared.gen);
            break :created shared.created;
        };
        break :created gl_robust.createContext(@ptrCast(hdc)) orelse
            return error.GLContextCreateFailed;
    };
    surface.hglrc = @ptrCast(created.hglrc);

    if (api.makeCurrent(@ptrCast(hdc), created.hglrc) == 0)
        return error.WGLMakeCurrentFailed;
    reset_status_resolved = false;

    // Same loader as threadEnter, and the same version floor: a driver swap
    // that leaves the machine on the basic display adapter answers with GDI's
    // OpenGL 1.1, which fails here and is retried until the new driver is in.
    const loader: gl_loader.GladLoadFn = gl_loader.gladLoad;
    try prepareContext(loader);

    self.device.lost = false;
    self.device.next_attempt_ms = null;
    self.device.rebuilds += 1;
    log.warn(
        "graphics device rebuilt after {d} attempt(s) robust={} rebuilds={d}",
        .{ attempt + 1, created.robust, self.device.rebuilds },
    );
    if (link) |l| log.info("pane renderer rejoined the window presenter generation={d}", .{l.gen});
}

/// How often a lost pane asks whether the window presenter has rebuilt yet
/// (T2616). The presenter rebuilds as soon as it hears of the loss, so this
/// is normally one or two polls.
const pres_rebuild_poll_ms: i64 = 50;

/// Win32 frame-pacing telemetry (T40/T48): when GHOZTTY_PERF is set in
/// the environment, log frames-per-second, the longest inter-frame gap, and
/// (T1458) the cost of the present itself - `swap_max_ms` and `swap_avg_us` -
/// once per second. The gap and the swap answer different questions and only
/// the pair is diagnostic: a large `max_gap_ms` with a small `swap_avg_us` is
/// a renderer that had nothing to draw, while a `swap_avg_us` that dominates
/// the frame budget is a present that is blocking, which is what a virtual /
/// streamed display is expected to look like. Costs
/// one branch per frame when disabled. Renderer-thread only (each
/// surface has its own renderer thread; state is threadlocal so panes
/// don't interleave).
///
/// Every sample names its pane (T1147). Without that the log was a bag of
/// anonymous per-window numbers, and a grader could only reason about the
/// POPULATION: the soak's `median fps` assertion read a bimodal mix of idle
/// panes at 1 fps and loaded panes at the 60 cap, and answered a question
/// about how many panes happened to be idle. `pane=<uuid>` lets a harness
/// group by pane and grade the panes it actually loaded, and lets a reader
/// confirm from the log itself - rather than infer - that the fps=1
/// population is the idle pane.
const perf = struct {
    threadlocal var enabled: ?bool = null;
    threadlocal var window_start: ?std.time.Instant = null;
    threadlocal var last_frame: ?std.time.Instant = null;
    threadlocal var frames: u32 = 0;
    threadlocal var max_gap_ns: u64 = 0;
    threadlocal var swap_total_ns: u64 = 0;
    threadlocal var swap_max_ns: u64 = 0;

    /// A pooled renderer thread starts each pane with a fresh window (T2644).
    fn reset() void {
        window_start = null;
        last_frame = null;
        frames = 0;
        max_gap_ns = 0;
        swap_total_ns = 0;
        swap_max_ns = 0;
    }

    fn isOn() bool {
        return enabled orelse on: {
            const on = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PERF");
            enabled = on;
            break :on on;
        };
    }

    /// A clock that only ticks when telemetry is on, so the caller can bracket
    /// a call site without paying for a timestamp on every frame in a normal
    /// build.
    fn now() ?std.time.Instant {
        if (!isOn()) return null;
        return std.time.Instant.now() catch null;
    }

    fn frame(surface: *apprt.Surface, swap_ns: u64) void {
        if (!isOn()) return;

        const tick = std.time.Instant.now() catch return;
        if (last_frame) |last| {
            const gap = tick.since(last);
            if (gap > max_gap_ns) max_gap_ns = gap;
        }
        last_frame = tick;
        frames += 1;
        swap_total_ns += swap_ns;
        if (swap_ns > swap_max_ns) swap_max_ns = swap_ns;

        const start = window_start orelse {
            window_start = tick;
            return;
        };
        const elapsed = tick.since(start);
        if (elapsed >= std.time.ns_per_s) {
            const fps = @as(u64, frames) * std.time.ns_per_s / @max(elapsed, 1);
            log.info(
                "perf pane={s} fps={d} max_gap_ms={d} swap_max_ms={d} swap_avg_us={d}",
                .{
                    surface.paneId(),
                    fps,
                    max_gap_ns / std.time.ns_per_ms,
                    swap_max_ns / std.time.ns_per_ms,
                    swap_total_ns / @max(frames, 1) / std.time.ns_per_us,
                },
            );
            window_start = tick;
            frames = 0;
            max_gap_ns = 0;
            swap_total_ns = 0;
            swap_max_ns = 0;
        }
    }
};

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Get the current size of the runtime surface.
/// Has the window this frame was drawn for changed size since `surfaceSize`
/// measured it (T2418)? Read just before the swap, from the renderer thread;
/// `GetClientRect` answers for a window on another thread without a message.
fn frameOutlivedItsWindow(self: *const OpenGL, hdc: anytype) bool {
    if (comptime apprt.runtime != apprt.win32) return false;
    const hwnd = self.paneWindow(hdc) orelse return false;
    var rect: wgl.RECT = undefined;
    if (wgl.GetClientRect(hwnd, &rect) == 0) return false;
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    if (w <= 0 or h <= 0) return false;
    return resize_paint.frameOutlivedItsWindow(
        self.drawn_client,
        resize_paint.packSize(@intCast(w), self.gridHeight(@intCast(h))),
    );
}

/// The window whose client the grid fills. The window the current DC belongs
/// to on the per-pane path; on the window presenter path the context is
/// current on a hidden helper (T2615), so it is the surface's own pane window.
fn paneWindow(self: *const OpenGL, hdc: anytype) ?std.os.windows.HWND {
    if (comptime apprt.runtime != apprt.win32) return null;
    if (self.rt_surface.present_link != null) {
        const h = self.rt_surface.hwnd orelse return null;
        return @ptrCast(h);
    }
    return wgl.WindowFromDC(hdc);
}

/// The part of a client area `client_h` px tall that the grid draws into:
/// all of it, less the banner band a window on the composition path spans
/// (T2566). The band is the window's top, so the GL viewport - whose origin
/// is the bottom-left - lands the grid below it on either present path.
fn gridHeight(self: *const OpenGL, client_h: u32) u32 {
    if (comptime apprt.runtime != apprt.win32) return client_h;
    return resize_paint.gridHeight(client_h, self.rt_surface.gridBand());
}

pub fn surfaceSize(self: *OpenGL) !struct { width: u32, height: u32 } {
    if (comptime apprt.runtime == apprt.win32) self.drawn_client = 0;

    // On Win32, query the actual window client rect instead of
    // GL_VIEWPORT. GL_VIEWPORT is only updated when we call
    // glViewport explicitly (no framework does it for us), creating
    // a chicken-and-egg problem during resize. The Win32 Surface
    // caches the client dimensions from WM_SIZE.
    if (comptime apprt.runtime == apprt.win32) {
        // Use the thread-local WGL DC to find our HWND, then query
        // the actual window client rect for the current size.
        const hdc = gl_loader.active().getCurrentDC() orelse return error.NoCurrentContext;
        const hwnd = self.paneWindow(hdc) orelse return error.NoWindow;
        var rect: wgl.RECT = undefined;
        if (wgl.GetClientRect(hwnd, &rect) != 0) {
            const w: u32 = @intCast(rect.right - rect.left);
            const client_h: u32 = @intCast(rect.bottom - rect.top);
            const h = if (client_h > 0) self.gridHeight(client_h) else 0;
            if (w > 0 and h > 0) {
                // Update glViewport to match
                gl.glad.context.Viewport.?(0, 0, @intCast(w), @intCast(h));
                self.drawn_client = resize_paint.packSize(w, h);
                self.resize_first_frame = self.resize_prev_client != 0 and
                    self.resize_prev_client != self.drawn_client;
                self.resize_prev_client = self.drawn_client;
                // T2485 D22: the first swap after a resize can land
                // in a back buffer still at the old size - the old width's
                // picture with black beyond it, for one frame. Re-making the
                // context current asks the driver to revalidate the drawable.
                // Not on the composition path, which never presents through
                // that drawable, and where the rebind was a third of a resize
                // step's first frame (T2577).
                if (self.resize_first_frame and self.comp == null and
                    (resizeFix() == .rebind or resizeFix() == .verify))
                {
                    const api = gl_loader.active();
                    _ = api.makeCurrent(hdc, api.getCurrentContext());
                }
                return .{ .width = w, .height = h };
            }
        }
    }

    var viewport: [4]gl.c.GLint = undefined;
    gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    return .{
        .width = @intCast(viewport[2]),
        .height = @intCast(viewport[3]),
    };
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    return Target.init(.{
        .internal_format = if (self.blending.isLinear()) .srgba else .rgba,
        .width = width,
        .height = height,
        // Win32 keeps the target across a window-edge drag's sizes (T2577).
        .grow_only = apprt.runtime == apprt.win32,
    });
}

/// Present the provided target.
pub fn present(self: *OpenGL, target: Target) !void {
    // In order to present a target we blit it to the default framebuffer.

    // We disable GL_FRAMEBUFFER_SRGB while doing this blit, otherwise the
    // values may be linearized as they're copied, but even though the draw
    // framebuffer has a linear internal format, the values in it should be
    // sRGB, not linear!
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
    };

    // Update the viewport to match the target dimensions. On Win32
    // there's no framework (like GTK's GLArea) that automatically
    // updates glViewport when the window resizes.
    gl.glad.context.Viewport.?(0, 0, @intCast(target.width), @intCast(target.height));

    // On the window presenter path (T2615) the frame goes into a slot
    // texture the presenter composes from.
    if (comptime apprt.runtime == apprt.win32) {
        if (self.rt_surface.present_link) |l| return self.presToSlot(l, target);
    }

    // On the composition path (T2466) the frame goes into the swap chain's
    // shared texture instead of the window's default framebuffer.
    self.traceStage("comp-begin");
    const comp_fbo: ?gl.Framebuffer = if (comptime apprt.runtime == apprt.win32)
        self.compBegin(target.width, target.height)
    else
        null;
    self.traceStage("comp-begun");
    const comp_bind = if (comp_fbo) |f| try f.bind(.draw) else null;
    defer if (comp_bind) |b| b.unbind();

    // The lab's planted one-frame background flash (T2383). The whole window,
    // not just the target's extent: `glClear` ignores the viewport. The target
    // is still recorded below, so a `presentLastTarget` shows the real frame.
    if (self.lab_erase_next) {
        self.lab_erase_next = false;
        const m = @import("../apprt/win32/lab_plant.zig").magenta;
        gl.clearColor(m[0], m[1], m[2], 1.0);
        gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
        self.last_target = target;
        return;
    }

    // Bind the target for reading.
    const fbobind = try target.framebuffer.bind(.read);
    defer fbobind.unbind();

    // Blit. A D3D texture's origin is its top-left, so the composition path
    // writes the rows bottom-up (T2466).
    const w: u32 = @intCast(target.width);
    const h: u32 = @intCast(target.height);
    const b: gl_comp_present.Blit = if (comp_fbo != null)
        gl_comp_present.flipBlit(w, h)
    else
        .{ .src = .{ 0, 0, @intCast(w), @intCast(h) }, .dst = .{ 0, 0, @intCast(w), @intCast(h) } };
    gl.glad.context.BlitFramebuffer.?(
        b.src[0],
        b.src[1],
        b.src[2],
        b.src[3],
        b.dst[0],
        b.dst[1],
        b.dst[2],
        b.dst[3],
        gl.c.GL_COLOR_BUFFER_BIT,
        gl.c.GL_NEAREST,
    );

    // T2515: a premultiplied chain under a window toggled opaque shows its
    // frame solid, the way the WGL pane's window stops honouring alpha then:
    // only the alpha channel is cleared, to 1.
    if (comptime apprt.runtime == apprt.win32) if (self.comp) |p| if (comp_fbo != null and
        gl_comp_present.forceOpaqueAlpha(p.premultiplied, self.rt_surface.windowTranslucent()))
    {
        const ctx = gl.glad.context;
        ctx.ColorMask.?(gl.c.GL_FALSE, gl.c.GL_FALSE, gl.c.GL_FALSE, gl.c.GL_TRUE);
        ctx.ClearColor.?(0, 0, 0, 1);
        ctx.Clear.?(gl.c.GL_COLOR_BUFFER_BIT);
        ctx.ColorMask.?(gl.c.GL_TRUE, gl.c.GL_TRUE, gl.c.GL_TRUE, gl.c.GL_TRUE);
    };

    // Keep track of this target in case we need to repeat it.
    self.last_target = target;
}

/// Decide this context's present path on its first frame, and on the
/// composition path lock the shared texture for this frame (T2466). Null
/// means: blit into the window's default framebuffer, as before.
fn compBegin(self: *OpenGL, width: usize, height: usize) ?gl.Framebuffer {
    if (!self.comp_tried) {
        self.comp_tried = true;
        if (gl_comp_present.enabled()) self.compInit(width, height);
    }
    // T2515: a chain's alpha mode is fixed when it is made, so an opaque one
    // under a window that has since turned translucent is made again.
    if (self.comp) |old| if (gl_comp_present.needsAlphaRebuild(old.premultiplied, self.rt_surface.windowTranslucent())) {
        compRetract(self);
        old.deinit();
        self.alloc.destroy(old);
        self.comp = null;
        log.info("composition swap chain rebuilt: the window turned translucent", .{});
        self.compInit(width, height);
    };
    const p = self.comp orelse return null;
    // The swap chain holds the grid; its visual sits below the banner band
    // the window spans (T2566).
    p.setBand(self.rt_surface.gridBand()) catch |err| {
        self.compFail(err);
        return null;
    };
    // The window could not carry the pane's visual (T2553): fall back to
    // SwapBuffers, the same as any other composition failure.
    if (p.surface_handle != null and self.rt_surface.comp_tree_slot.refused.load(.acquire)) {
        self.compFail(error.TreeRefused);
        return null;
    }
    return p.begin(@intCast(width), @intCast(height)) catch |err| {
        self.compFail(err);
        return null;
    };
}

fn compInit(self: *OpenGL, width: usize, height: usize) void {
    const hwnd = self.rt_surface.hwnd orelse return;
    const p = self.alloc.create(gl_comp_present.Presenter) catch return;
    // T2553: into the window's tree only when the window says it can host
    // the visual; a handle nobody adopts is a pane that never shows.
    const in_tree = gl_comp_present.treeEnabled() and
        self.rt_surface.comp_tree_slot.host_ready.load(.acquire);
    // T2515: composed by alpha in a translucent window, as the WGL pane is.
    const premultiplied = self.rt_surface.windowTranslucent();
    p.* = gl_comp_present.Presenter.init(hwnd, @intCast(width), @intCast(height), in_tree, premultiplied) catch |err| {
        self.alloc.destroy(p);
        const f = gl_comp_present.Presenter.lastFailure();
        log.warn(
            "composition present unavailable ({}) at {s} hr=0x{x}; this pane presents with SwapBuffers",
            .{ err, f.stage, @as(u32, @bitCast(f.hr)) },
        );
        return;
    };
    self.comp = p;
    log.info("pane presents through a composition swap chain warp={} tree={} premultiplied={}", .{ p.warp, in_tree, premultiplied });
    if (p.surface_handle) |h| {
        self.rt_surface.comp_tree_slot.publish(h);
        comp_overlay.notify(hwnd);
        log.info("pane surface handle published to the window tree", .{});
    }
    // Hand the tree to the window thread for its overlay visuals (T2467).
    if (p.overlayTree()) |tree| {
        self.rt_surface.comp_overlay_slot.publish(tree, comp_overlay.RefOps.com);
        comp_overlay.notify(hwnd);
        log.info("pane overlay tree published", .{});
    }
}

/// Take the presenter's tree back from the window thread before it goes; the
/// window thread re-syncs its overlays (to popups) on the posted message.
fn compRetract(self: *const OpenGL) void {
    // Both trees, and both before the presenter goes: once the tree slot's
    // retract returns, no window-thread adopt is using the surface handle.
    const tree = self.rt_surface.comp_tree_slot.retract();
    const overlay = self.rt_surface.comp_overlay_slot.retract(comp_overlay.RefOps.com);
    if (!tree and !overlay) return;
    if (self.rt_surface.hwnd) |hwnd| comp_overlay.notify(hwnd);
}

/// A frame on the composition path failed: drop to SwapBuffers for the life
/// of this context, and take the visual off the window so its own content
/// shows again.
fn compFail(self: *OpenGL, err: anyerror) void {
    const p = self.comp orelse return;
    const f = gl_comp_present.Presenter.lastFailure();
    log.warn(
        "composition present failed ({}) at {s} hr=0x{x}; falling back to SwapBuffers",
        .{ err, f.stage, @as(u32, @bitCast(f.hr)) },
    );
    compRetract(self);
    p.deinit();
    self.alloc.destroy(p);
    self.comp = null;
}

/// May the renderer free this pane's targets now that it is hidden (T2474)?
/// Only on Win32, and only when the WINDOW is hidden (minimized, cloaked,
/// covered, parked by a close-undo): a pane that is merely behind another tab
/// keeps its target, because hero mode's carousel reads it. Never while the
/// device is lost - the targets are dead with it and the rebuild owns them.
pub fn releaseHiddenTargetsNow(self: *const OpenGL) bool {
    if (comptime apprt.runtime != apprt.win32) return false;
    if (self.device.lost) return false;
    return self.rt_surface.windowHidden();
}

/// The renderer freed the targets (`releaseHiddenTargets`): the one recorded
/// here is gone, so nothing may present or capture it again. The next frame
/// draws in full and records a new one.
pub fn hiddenTargetsReleased(self: *OpenGL) void {
    self.last_target = null;
    // The deletes sit in the command stream until something submits it, and
    // a hidden pane draws nothing that would: without this the driver keeps
    // the storage until the window is shown again.
    gl.finish();
}

/// Present the last presented target again.
pub fn presentLastTarget(self: *OpenGL) !void {
    // The window presenter keeps holding the last frame it took, so a repeat
    // would be a copy of what it already has (T2615). A planted lab frame
    // still goes through.
    if (comptime apprt.runtime == apprt.win32) {
        if (self.rt_surface.present_link != null and self.pres_has_frame and !self.lab_erase_next) return;
    }
    if (self.last_target) |target| try self.present(target);
}

// -------------------------------------------------------------------------
// The window presenter path (T2610 step 3c, T2615). The presenter half, and
// the why, are `apprt/win32/WindowPresenter.zig`; the slot rules are
// `gl_window_presenter.SlotPair`.
// -------------------------------------------------------------------------

/// How long `presAcquire` waits, per try, for the presenter to take the
/// frame already published. Two tries, a little over two vblanks at 60 Hz:
/// the presenter takes a visible pane's frame at its next compose, and a
/// pane it is not composing (hidden behind a tab, folded in a stack) must
/// not hold its renderer up for longer than that.
const pres_wait_ms: u32 = 20;

/// The slot this frame may be drawn into, after the GPU is past every
/// compose that read it. Null drops the frame: the presenter has not taken
/// the last one (a pane it is not composing) or is gone (the window is being
/// destroyed).
fn presAcquire(self: *OpenGL, l: anytype) ?u1 {
    _ = self;
    // The presenter has left this context's group (T2616) and will not take
    // from this link until it rejoins: do not wait for it. `checkDevice` at
    // the end of this frame starts the rebuild.
    if (l.stale()) return null;
    var tries: u8 = 0;
    while (true) {
        if (l.slots.acquire()) |slot| {
            const rel = l.takeRelease(slot);
            if (rel != 0) {
                const sync: gl.c.GLsync = @ptrFromInt(rel);
                gl.glad.context.WaitSync.?(sync, 0, gl.c.GL_TIMEOUT_IGNORED);
                gl.glad.context.DeleteSync.?(sync);
            }
            return slot;
        }
        if (!l.attached() or tries == 2) return null;
        _ = wgl.WaitForSingleObject(@ptrCast(l.signal), pres_wait_ms);
        tries += 1;
    }
}

fn presToSlot(self: *OpenGL, l: anytype, target: Target) !void {
    self.last_target = target;
    const slot = self.presAcquire(l) orelse {
        // A planted lab frame waits for the next frame that has a slot.
        log.debug("window presenter has not taken the last frame; this one is dropped", .{});
        return;
    };
    const w: u32 = @intCast(target.width);
    const h: u32 = @intCast(target.height);
    const c = &gl.glad.context;

    // The slot texture, created on first use and grown like the target.
    if (l.tex[slot] == 0) {
        var name: gl.c.GLuint = 0;
        c.GenTextures.?(1, &name);
        l.tex[slot] = name;
        self.pres_cap[slot] = .{ 0, 0 };
    }
    if (self.pres_cap[slot][0] < w or self.pres_cap[slot][1] < h) {
        const cw: u32 = @intCast(Target.capacityFor(w, true));
        const ch: u32 = @intCast(Target.capacityFor(h, true));
        c.BindTexture.?(gl.c.GL_TEXTURE_2D, l.tex[slot]);
        c.TexParameteri.?(gl.c.GL_TEXTURE_2D, gl.c.GL_TEXTURE_MIN_FILTER, gl.c.GL_NEAREST);
        c.TexParameteri.?(gl.c.GL_TEXTURE_2D, gl.c.GL_TEXTURE_MAG_FILTER, gl.c.GL_NEAREST);
        c.TexImage2D.?(gl.c.GL_TEXTURE_2D, 0, gl.c.GL_RGBA8, @intCast(cw), @intCast(ch), 0, gl.c.GL_RGBA, gl.c.GL_UNSIGNED_BYTE, null);
        c.BindTexture.?(gl.c.GL_TEXTURE_2D, 0);
        self.pres_cap[slot] = .{ cw, ch };
    }

    if (self.pres_fbo == null) self.pres_fbo = try gl.Framebuffer.create();
    const draw = try self.pres_fbo.?.bind(.draw);
    defer draw.unbind();
    c.FramebufferTexture2D.?(gl.c.GL_DRAW_FRAMEBUFFER, gl.c.GL_COLOR_ATTACHMENT0, gl.c.GL_TEXTURE_2D, l.tex[slot], 0);

    if (self.lab_erase_next) {
        // The lab's planted one-frame flash (T2383), into the slot.
        self.lab_erase_next = false;
        const m = @import("../apprt/win32/lab_plant.zig").magenta;
        gl.clearColor(m[0], m[1], m[2], 1.0);
        gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
    } else {
        const read = try target.framebuffer.bind(.read);
        defer read.unbind();
        c.BlitFramebuffer.?(0, 0, @intCast(w), @intCast(h), 0, 0, @intCast(w), @intCast(h), gl.c.GL_COLOR_BUFFER_BIT, gl.c.GL_NEAREST);
    }
    self.pres_slot = slot;
    self.pres_w = w;
    self.pres_h = h;
}

/// The swap site's replacement: fence the slot `present` drew, flush so the
/// presenter's context can see the fence, publish, and ask for a compose.
fn presPublish(self: *OpenGL, l: anytype) void {
    const slot = self.pres_slot orelse {
        self.rt_surface.tracePresent(self.drawn_client, false);
        return;
    };
    self.pres_slot = null;
    const c = &gl.glad.context;
    const fence = c.FenceSync.?(gl.c.GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    c.Flush.?();
    self.pres_frame_id += 1;
    const replaced = l.slots.publish(slot, .{
        .fence = @intFromPtr(fence),
        .frame_id = self.pres_frame_id,
        .width = self.pres_w,
        .height = self.pres_h,
    });
    if (replaced) |old| if (old != 0) c.DeleteSync.?(@ptrFromInt(old));
    self.pres_has_frame = true;
    // The renderer is running: from here a presenter rebuild may wake it.
    l.armed.store(true, .release);
    _ = l.notify();
    self.rt_surface.tracePresent(self.drawn_client, true);
    if (self.pres_frame_id == 1) log.info("pane renderer published its first frame to the window presenter", .{});
}

/// Renderer thread, as it exits, with the context current: take the pane off
/// the presenter, then delete what only this side can.
fn presRetire(self: *const OpenGL, l: anytype) void {
    const left = l.unlink();
    const c = &gl.glad.context;
    for (left.fences) |f| if (f != 0) c.DeleteSync.?(@ptrFromInt(f));
    if (self.pres_fbo) |f| f.destroy();
    for (left.tex) |t| if (t != 0) {
        var name: gl.c.GLuint = t;
        c.DeleteTextures.?(1, &name);
    };
}

/// Capture the last presented render target, downscaled to (w, h), as
/// bottom-up BGRA pixels into `out` (len must be w*h*4). Renderer thread,
/// win32 hero-mode thumbnails (T59a). Reads from the OFFSCREEN target
/// texture — not the window back buffer — so it stays valid for panes
/// whose HWND is hidden (no DWM redirection / pixel-ownership involved).
pub fn captureThumb(self: *OpenGL, w: u32, h: u32, exact: bool, out: []u8) !void {
    const target = self.last_target orelse return error.NoFrameYet;
    // An exact capture (T2458) is the frame drawn at that size, never one
    // from before a resize scaled to it.
    if (exact and (target.width != w or target.height != h)) return error.NotThatSize;
    if (out.len != @as(usize, w) * @as(usize, h) * 4) return error.BadBufferSize;

    if (self.snap_fbo == null) self.snap_fbo = try gl.Framebuffer.create();
    if (self.snap_rbo == null) self.snap_rbo = try gl.Renderbuffer.create();
    if (self.snap_w != w or self.snap_h != h) {
        {
            const rb = try self.snap_rbo.?.bind();
            defer rb.unbind();
            try rb.storage(.rgba, @intCast(w), @intCast(h));
        }
        {
            const fb = try self.snap_fbo.?.bind(.framebuffer);
            defer fb.unbind();
            try fb.renderbuffer(.color0, self.snap_rbo.?);
        }
        self.snap_w = w;
        self.snap_h = h;
    }

    // Copy raw values: without this the blit would linearize/encode sRGB
    // (same reasoning as present()).
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
    };

    {
        const draw = try self.snap_fbo.?.bind(.draw);
        defer draw.unbind();
        const read = try target.framebuffer.bind(.read);
        defer read.unbind();
        gl.glad.context.BlitFramebuffer.?(
            0,
            0,
            @intCast(target.width),
            @intCast(target.height),
            0,
            0,
            @intCast(w),
            @intCast(h),
            gl.c.GL_COLOR_BUFFER_BIT,
            gl.c.GL_LINEAR,
        );
    }

    {
        const read = try self.snap_fbo.?.bind(.read);
        defer read.unbind();
        gl.glad.context.ReadBuffer.?(gl.c.GL_COLOR_ATTACHMENT0);
        gl.glad.context.PixelStorei.?(gl.c.GL_PACK_ALIGNMENT, 4);
        gl.glad.context.ReadPixels.?(
            0,
            0,
            @intCast(w),
            @intCast(h),
            gl.c.GL_BGRA,
            gl.c.GL_UNSIGNED_BYTE,
            out.ptr,
        );
    }
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2D",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2D",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .Rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}
