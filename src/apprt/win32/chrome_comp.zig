//! The window CHROME's composition host (T2508, T2360 step 4a): a
//! DirectComposition target on the top-level window, with a Direct2D device
//! context over the same D3D11 device, ready for the chrome painters to move
//! onto.
//!
//! A DComp target's visual tree composes ABOVE the window's own redirected
//! GDI pixels - `topmost=FALSE` only puts it BELOW the window's child windows
//! (the panes) - so any visual hung here hides every GDI chrome painter under
//! it. Two visuals hang from a container root. The desk (T2509): `PaneDesk`'s
//! composed buffer, uploaded rectangle by rectangle as it changes, clipped to
//! the content area below the caption. The window carries it on an opaque
//! window; the GDI painters that draw OVER the desk - rearrange headers, a
//! hero tab's carousel and slide - paint an `Overlay` instead, which goes up
//! as the desk's child visual (T2544). Above it, while
//! the desk is up, the caption band (T2543): the caption and tab bar painted
//! by their own GDI painters into a persistent `Mirror` and uploaded by the
//! paint's dirty rect. A window paint batches both into one commit
//! (`beginBatch`/`flush`), so the band and the desk change in the same frame.
//! T2545/T2541 move the remaining painters over.
//!
//! Why DirectComposition and not Windows.UI.Composition, same call as the pane
//! presenter (`renderer/gl_comp_present.zig`): a DComp device commits
//! explicitly from the thread that owns it, and the shape of the chrome's
//! later painters (paint, upload, commit) wants exactly that.
//!
//! Opt-in while it is proven (`GHOZTTY_COMP_CHROME=1`, read per window). Any
//! failure leaves the window on its GDI chrome, which is the same picture,
//! and says which step failed in the log. Device loss (a driver reset, a GPU
//! removed, a remote-session switch) is noticed on the next paint and the
//! whole chain is rebuilt from scratch.
//!
//! Two debug-only seams (Debug/ReleaseSafe, never a release build), both for
//! test\win32\comp-chrome.ps1 and scripts\comp-chrome-onscreen.ps1:
//!   - `GHOZTTY_COMP_CHROME_FORCE_LOSS=1`: the first device check reports the
//!     device lost, so the rebuild can be watched happening.
//!   - `GHOZTTY_COMP_CHROME_TEST_FILL=1`: hang one magenta visual the size of
//!     the client area on the target, drawn through the Direct2D context. On
//!     screen it must cover the GDI chrome and sit under the panes - the
//!     ordering every later step relies on.
//!   - `GHOZTTY_COMP_CHROME_CAPTION_FREEZE=1` (scripts\comp-desk-onscreen.ps1
//!     -NegativeControl): the caption visual takes its whole uploads and drops
//!     every dirty-rect one, so a frozen band is something the oracle sees.
//!   - `GHOZTTY_COMP_CHROME_OVERLAY_FREEZE=1`: the same for the overlay
//!     (T2544), so a header that stops updating is something it sees.
//!   - `GHOZTTY_COMP_CHROME_FLAT_FREEZE=1`: the flat style's desk (T2545,
//!     `FlatDesk`) sends only whole pictures, so a divider that moved and
//!     stayed drawn where it was is something scripts\comp-flat-onscreen.ps1
//!     sees.
//!
//! Every slot below was checked against the 10.0.26100.0 SDK headers
//! (d3d11.h, dxgi.h, dcomp.h, d2d1.h, d2d1_1.h).
const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const comp_tree = @import("../../renderer/comp_tree.zig");
const comp_overlay = @import("../../renderer/comp_overlay.zig");

const log = std.log.scoped(.comp_chrome);

const GUID = std.os.windows.GUID;
const HRESULT = std.os.windows.HRESULT;
const HWND = std.os.windows.HWND;
pub const Obj = *anyopaque;

pub const Error = error{ Unavailable, ComFailed };

/// The environment knob that opts a window's chrome into this host.
pub const env_knob = "GHOZTTY_COMP_CHROME";

/// Whether the knob's value asks for the host. "1"/"true"/"on".
pub fn knobOn(value: ?[]const u8) bool {
    const v = std.mem.trim(u8, value orelse return false, " \t\r\n");
    return std.mem.eql(u8, v, "1") or
        std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "on");
}

fn envOn(comptime name: []const u8) bool {
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(raw);
    return knobOn(raw);
}

pub fn enabled() bool {
    if (comptime builtin.os.tag != .windows) return false;
    return envOn(env_knob);
}

/// The knob that creates the window WITHOUT a redirection surface (T2548,
/// T2360 step 4e, `WS_EX_NOREDIRECTIONBITMAP`). With one, DWM resizes the
/// window's GDI surface and shows the new frame at the first compose,
/// whatever the visual tree holds, so the whole client trails the frame by
/// a compose (T2546's film). Without one, the client is exactly the visual
/// tree - and every pixel still drawn with GDI, a GDI child window's
/// included, is not on screen at all. So it is opt-in on its own.
pub const noredir_knob = "GHOZTTY_COMP_NOREDIR";

/// Whether a window may drop its redirection surface: asked for, with the
/// chrome on this host (else the caption and desk have nowhere to be) and the
/// panes presenting through composition (`GHOZTTY_COMP_PRESENT`; an OpenGL
/// child window draws into the surface this removes), on an opaque window
/// (a translucent one blends against that surface).
pub fn noredirWanted(asked: bool, chrome: bool, present: bool, opaque_window: bool) bool {
    return asked and chrome and present and opaque_window;
}

pub fn noredirAsked() bool {
    if (comptime builtin.os.tag != .windows) return false;
    return envOn(noredir_knob);
}

fn seamBuild() bool {
    return builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
}

/// A debug knob a test arm sets (a seam build only, read when asked): the
/// on-screen oracles' negative controls.
pub fn debugKnob(comptime name: []const u8) bool {
    return seamBuild() and envOn(name);
}

fn guid(comptime s: []const u8) GUID {
    return GUID.parse("{" ++ s ++ "}");
}

const IID_IDXGIDevice = guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
const IID_IDXGISurface = guid("cafcb56c-6ac3-4889-bf47-9e23bbd260ec");
const IID_IDCompositionDevice = guid("c37ea93a-e7aa-450d-b16f-9746cb0407f3");
const IID_ID2D1Factory1 = guid("bb12d362-daee-4b9a-aa1d-14ba401cfa1f");

const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D_DRIVER_TYPE_WARP: u32 = 5;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_SDK_VERSION: u32 = 7;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const DXGI_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
const D2D1_FACTORY_TYPE_SINGLE_THREADED: u32 = 0;
const D2D1_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
const D2D1_BITMAP_OPTIONS_TARGET: u32 = 0x1;
const D2D1_BITMAP_OPTIONS_CANNOT_DRAW: u32 = 0x2;
const D2D1_ANTIALIAS_MODE_ALIASED: u32 = 1;

const DCOMPOSITION_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR: u32 = 0;
const DCOMPOSITION_BORDER_MODE_HARD: u32 = 1;
/// How far the backstop's one pixel is stretched: past any client area.
const backstop_scale: f32 = 32768;

const D2D1_COLOR_F = extern struct { r: f32, g: f32, b: f32, a: f32 };
const D2D_MATRIX_3X2_F = extern struct { m11: f32, m12: f32, m21: f32, m22: f32, dx: f32, dy: f32 };
const D2D1_RECT_F = extern struct { left: f32, top: f32, right: f32, bottom: f32 };
const D2D1_BITMAP_PROPERTIES1 = extern struct {
    format: u32,
    alpha_mode: u32,
    dpi_x: f32,
    dpi_y: f32,
    options: u32,
    color_context: ?Obj,
};

// Vtable slots (IUnknown 0-2 everywhere; ID2D1Resource::GetFactory is 3).
const slot_d3d11_device_get_removed_reason = 39;
const slot_d2d_factory1_create_device = 17;
const slot_d2d_device_create_context = 4;
const slot_d2d_rt_push_clip = 45;
const slot_d2d_rt_pop_clip = 46;
const slot_d2d_rt_clear = 47;
const slot_d2d_rt_begin_draw = 48;
const slot_d2d_rt_end_draw = 49;
const slot_d2d_dc_bitmap_from_dxgi = 62;
const slot_d2d_dc_set_target = 74;
const slot_dcomp_device_commit = 3;
const slot_dcomp_device_create_target = 6;
const slot_dcomp_device_create_visual = 7;
const slot_dcomp_device_create_surface = 8;
const slot_dcomp_device_create_surface_from_handle = 10;
const slot_dcomp_device_create_rectangle_clip = 24;
const slot_dcomp_device_check_state = 26;
const slot_dcomp_surface_begin_draw = 3;
const slot_dcomp_surface_end_draw = 4;
const slot_dcomp_target_set_root = 3;
// IDCompositionVisual: each overloaded setter's object form comes first,
// its value form second (SetTransform(transform) 7 / (matrix) 8, as
// `renderer/comp_overlay.zig` uses).
const slot_dcomp_visual_set_offset_x = 4;
const slot_dcomp_visual_set_offset_y = 6;
const slot_dcomp_visual_set_transform_matrix = 8;
const slot_dcomp_visual_set_interpolation = 11;
const slot_dcomp_visual_set_border_mode = 12;
const slot_dcomp_visual_set_clip = 13;
const slot_dcomp_visual_set_clip_rect = 14;
const slot_dcomp_visual_set_content = 15;
const slot_dcomp_visual_add_visual = 16;
const slot_dcomp_visual_remove_visual = 17;
// IDCompositionRectangleClip, same overload rule: SetLeft(float) 4, SetTop 6,
// SetRight 8, SetBottom 10, then the eight corner radii from 12, X before Y,
// top-left, top-right, bottom-left, bottom-right.
const slot_dcomp_rect_clip_set_left = 4;
const slot_dcomp_rect_clip_set_top = 6;
const slot_dcomp_rect_clip_set_right = 8;
const slot_dcomp_rect_clip_set_bottom = 10;
const slot_dcomp_rect_clip_first_radius = 12;
// The focus glow's fade (T2574), the same slots `renderer/comp_overlay.zig`
// fades its layers with: IDCompositionDevice CreateEffectGroup 23,
// CreateAnimation 25; IDCompositionVisual SetEffect 10; IDCompositionEffectGroup
// SetOpacity(animation) 3 / (float) 4; IDCompositionAnimation AddCubic 5, End 8.
const slot_dcomp_device_create_effect_group = 23;
const slot_dcomp_device_create_animation = 25;
const slot_dcomp_visual_set_effect = 10;
const slot_dcomp_effect_set_opacity_anim = 3;
const slot_dcomp_effect_set_opacity_float = 4;
const slot_dcomp_anim_add_cubic = 5;
const slot_dcomp_anim_end = 8;
// ID3D11DeviceContext (ID3D11DeviceChild 3-6, CopyResource 47).
const slot_d3d11_context_update_subresource = 48;

const IID_ID3D11Texture2D = guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
/// The desk is opaque: its buffer's alpha byte is coverage for a
/// translucent window's blend (`PaneDesk`), not transparency.
const DXGI_ALPHA_MODE_IGNORE: u32 = 3;

const D3D11_BOX = extern struct { left: u32, top: u32, front: u32, right: u32, bottom: u32, back: u32 };

/// A rectangle of the desk's buffer, in its own pixels.
pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

/// The part of a `w` x `h` band (client origin) that a paint clipped to
/// `clip` reached, or null when it reached none of it.
pub fn bandDirty(clip: Rect, w: i32, h: i32) ?Rect {
    const r: Rect = .{
        .left = std.math.clamp(clip.left, 0, w),
        .top = std.math.clamp(clip.top, 0, h),
        .right = std.math.clamp(clip.right, 0, w),
        .bottom = std.math.clamp(clip.bottom, 0, h),
    };
    if (r.right <= r.left or r.bottom <= r.top) return null;
    return r;
}

/// The caption band's persistent mirror (T2543): a top-down 32bpp DIB the
/// width of the client area and the chrome's height, selected into a memory
/// DC whose origin is the client's. The caption and tab bar painters draw
/// into it exactly as they would into the window, and the band goes to the
/// compositor (or, off it, to the window) from these pixels.
pub const Mirror = struct {
    dc: ?w32.HDC = null,
    bmp: ?w32.HANDLE = null,
    old: ?*anyopaque = null,
    px: []u32 = &.{},
    w: i32 = 0,
    h: i32 = 0,

    /// The mirror's DC at `w` x `h`, rebuilt (and so fresh) on a new size.
    /// Null when GDI refused, and the caller paints the window instead.
    pub fn ensure(self: *Mirror, ref: w32.HDC, w: i32, h: i32) ?w32.HDC {
        if (w <= 0 or h <= 0) return null;
        if (self.dc != null and w == self.w and h == self.h) return self.dc;
        self.deinit();
        const dc = w32.CreateCompatibleDC(ref) orelse return null;
        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{
            .bmiHeader = .{
                .biWidth = w,
                .biHeight = -h, // top-down
                .biPlanes = 1,
                .biBitCount = 32,
                .biCompression = w32.BI_RGB,
            },
        };
        const bmp = w32.CreateDIBSection(dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = w32.DeleteDC(dc);
            return null;
        };
        const p = bits orelse {
            _ = w32.DeleteObject(bmp);
            _ = w32.DeleteDC(dc);
            return null;
        };
        self.* = .{
            .dc = dc,
            .bmp = bmp,
            .old = w32.SelectObject(dc, bmp),
            .px = @as([*]u32, @ptrCast(@alignCast(p)))[0..@intCast(w * h)],
            .w = w,
            .h = h,
        };
        return dc;
    }

    pub fn deinit(self: *Mirror) void {
        if (self.dc) |dc| {
            if (self.old) |o| _ = w32.SelectObject(dc, o);
            if (self.bmp) |b| _ = w32.DeleteObject(b);
            _ = w32.DeleteDC(dc);
        }
        self.* = .{};
    }
};

/// The smallest rectangle holding both, either of which may be absent.
pub fn unite(a: ?Rect, b: ?Rect) ?Rect {
    const x = a orelse return b;
    const y = b orelse return x;
    return .{
        .left = @min(x.left, y.left),
        .top = @min(x.top, y.top),
        .right = @max(x.right, y.right),
        .bottom = @max(x.bottom, y.bottom),
    };
}

/// What the GDI painters that draw OVER the desk left there (T2544): the
/// rearrange headers, a hero tab's carousel and its selection slide. On the
/// GDI path they paint the window after the desk's blit; with the desk on the
/// compositor they paint a scratch copy of what is on screen, and every pixel
/// they left different from the desk becomes an opaque pixel of an overlay
/// visual above it. Erase semantics are GDI's: a rectangle the desk uploads
/// clears the overlay there, exactly as the desk's blit would have covered
/// whatever the painters had drawn, and the painters then draw it again.
///
/// Buffers are the desk's own size and pixels. `desk` mirrors what the desk
/// visual holds, so a painter that blends (ClearType, the glass band's shade)
/// blends against the real desk; `px` is the overlay, premultiplied, each
/// pixel either 0 or opaque.
pub const Overlay = struct {
    desk: std.ArrayListUnmanaged(u32) = .empty,
    px: std.ArrayListUnmanaged(u32) = .empty,
    w: i32 = 0,
    h: i32 = 0,
    /// What changed in `px` since it last went up, in its own pixels.
    dirty: ?Rect = null,

    const alloc = std.heap.page_allocator;

    pub fn deinit(self: *Overlay) void {
        self.desk.deinit(alloc);
        self.px.deinit(alloc);
        self.* = .{};
    }

    /// The desk left the compositor: the next upload starts the copy over.
    pub fn reset(self: *Overlay) void {
        self.w = 0;
        self.h = 0;
        self.dirty = null;
    }

    /// Nothing paints over the desk any more: the overlay is empty.
    pub fn clear(self: *Overlay) void {
        @memset(self.px.items, 0);
        self.dirty = null;
    }

    /// The desk visual took `rects` of `src` (null: all of it). The copy
    /// follows, and with `clears` the overlay clears there - except inside
    /// `keep`, the regions the desk's own blit is clipped away from (a hero
    /// tab's carousel, a running slide). A new size starts both over.
    pub fn deskUploaded(self: *Overlay, src: []const u32, w: i32, h: i32, rects: ?[]const Rect, clears: bool, keep: []const Rect) error{OutOfMemory}!void {
        var whole = rects == null;
        if (w != self.w or h != self.h) {
            const n: usize = @intCast(w * h);
            try self.desk.resize(alloc, n);
            try self.px.resize(alloc, n);
            @memset(self.px.items, 0);
            self.w = w;
            self.h = h;
            self.dirty = null;
            whole = true;
        }
        const all = [_]Rect{.{ .left = 0, .top = 0, .right = w, .bottom = h }};
        for (if (whole) all[0..] else rects.?) |raw| {
            const r = bandDirty(raw, w, h) orelse continue;
            self.copyDesk(src, r);
            if (clears) self.erase(r, keep);
        }
    }

    fn copyDesk(self: *Overlay, src: []const u32, r: Rect) void {
        const cw: usize = @intCast(self.w);
        var y = r.top;
        while (y < r.bottom) : (y += 1) {
            const a = @as(usize, @intCast(y)) * cw + @as(usize, @intCast(r.left));
            const b = a + @as(usize, @intCast(r.right - r.left));
            @memcpy(self.desk.items[a..b], src[a..b]);
        }
    }

    /// Clear `r` of the overlay, outside `keep`.
    pub fn erase(self: *Overlay, raw: Rect, keep: []const Rect) void {
        const r = bandDirty(raw, self.w, self.h) orelse return;
        const cw: usize = @intCast(self.w);
        var y = r.top;
        while (y < r.bottom) : (y += 1) {
            var x = r.left;
            while (x < r.right) : (x += 1) {
                for (keep) |k| {
                    if (x >= k.left and x < k.right and y >= k.top and y < k.bottom) break;
                } else self.px.items[@as(usize, @intCast(y)) * cw + @as(usize, @intCast(x))] = 0;
            }
        }
        self.dirty = unite(self.dirty, r);
    }

    /// What is on screen over `r`, into `out` (a buffer the overlay's size):
    /// the overlay where it is painted, the desk elsewhere.
    pub fn prefill(self: *const Overlay, out: []u32, r: Rect) void {
        const cw: usize = @intCast(self.w);
        var y = r.top;
        while (y < r.bottom) : (y += 1) {
            const a = @as(usize, @intCast(y)) * cw + @as(usize, @intCast(r.left));
            const b = a + @as(usize, @intCast(r.right - r.left));
            for (out[a..b], self.px.items[a..b], self.desk.items[a..b]) |*o, p, d| o.* = if (p >> 24 != 0) p else d;
        }
    }

    /// The painters' result over `r` (`painted`, a buffer the overlay's size,
    /// prefilled by `prefill`), into the overlay: every pixel that differs
    /// from the desk is opaque, every other one clear - the desk under it is
    /// the same colour. GDI leaves the alpha byte alone or zero, so only the
    /// colour is compared.
    pub fn merge(self: *Overlay, painted: []const u32, r: Rect) void {
        const cw: usize = @intCast(self.w);
        var y = r.top;
        while (y < r.bottom) : (y += 1) {
            const a = @as(usize, @intCast(y)) * cw + @as(usize, @intCast(r.left));
            const b = a + @as(usize, @intCast(r.right - r.left));
            for (self.px.items[a..b], painted[a..b], self.desk.items[a..b]) |*o, s, d| {
                o.* = if ((s ^ d) & 0x00FF_FFFF == 0) 0 else s | 0xFF00_0000;
            }
        }
        self.dirty = unite(self.dirty, r);
    }

    pub fn takeDirty(self: *Overlay) ?Rect {
        defer self.dirty = null;
        return self.dirty;
    }
};

/// The flat pane style's bottom layer (T2545). The flat style has no
/// `PaneDesk` to compose a buffer: what the window owns between the panes is
/// GDI - the gutters' background, the divider lines, the gutter bar, the
/// strips of tucked panes and their names. With the desk visual carrying it,
/// those painters draw into `mirror`, a persistent DIB the desk area's size
/// holding exactly what the window's own pixels would, and what they changed
/// goes up to the desk visual. `shadow` is what the visual holds, so a pass
/// that repainted a whole band uploads only the rows it actually changed.
pub const FlatDesk = struct {
    mirror: Mirror = .{},
    shadow: std.ArrayListUnmanaged(u32) = .empty,
    x: i32 = 0,
    y: i32 = 0,
    /// The mirror holds the whole picture: painted whole since it was made,
    /// and every flat painter has drawn into it since.
    valid: bool = false,

    const alloc = std.heap.page_allocator;

    pub fn deinit(self: *FlatDesk) void {
        self.mirror.deinit();
        self.shadow.deinit(alloc);
        self.* = .{};
    }

    /// The mirror's DC for an area at `(x, y)` (client pixels), `w` x `h`.
    /// A new size or place makes the picture invalid: the caller paints it
    /// whole. Null when GDI refused.
    pub fn ensure(self: *FlatDesk, ref: w32.HDC, x: i32, y: i32, w: i32, h: i32) ?w32.HDC {
        if (w != self.mirror.w or h != self.mirror.h or x != self.x or y != self.y) self.valid = false;
        const dc = self.mirror.ensure(ref, w, h) orelse return null;
        self.shadow.resize(alloc, self.mirror.px.len) catch return null;
        self.x = x;
        self.y = y;
        return dc;
    }

    /// The visual took the whole mirror.
    pub fn synced(self: *FlatDesk) void {
        @memcpy(self.shadow.items, self.mirror.px);
    }

    /// What differs from the visual inside `raw` (the mirror's pixels), as at
    /// most `out.len` rectangles, which the shadow then takes: the caller
    /// uploads them.
    pub fn changed(self: *FlatDesk, raw: Rect, out: []Rect) []Rect {
        const rs = diffRects(self.mirror.px, self.shadow.items, self.mirror.w, self.mirror.h, raw, out);
        for (rs) |r| copyRect(self.shadow.items, self.mirror.px, self.mirror.w, r);
        return rs;
    }
};

/// Where `cur` differs from `prev` (both `w` x `h`) inside `raw`, as row
/// bands: consecutive rows that differ over the same span are one rectangle,
/// so a moved divider line is one tall strip and a gutter bar a box. Colour
/// only - GDI writes the alpha byte as it likes. When the rows need more
/// rectangles than `out` holds, the last one grows to take the rest.
pub fn diffRects(cur: []const u32, prev: []const u32, w: i32, h: i32, raw: Rect, out: []Rect) []Rect {
    const r = bandDirty(raw, w, h) orelse return out[0..0];
    if (out.len == 0) return out[0..0];
    const cw: usize = @intCast(w);
    var n: usize = 0;
    var open = false;
    var y = r.top;
    while (y < r.bottom) : (y += 1) {
        const row = @as(usize, @intCast(y)) * cw;
        var lo: i32 = r.right;
        var hi: i32 = r.left;
        var x = r.left;
        while (x < r.right) : (x += 1) {
            const i = row + @as(usize, @intCast(x));
            if ((cur[i] ^ prev[i]) & 0x00FF_FFFF != 0) {
                lo = @min(lo, x);
                hi = x + 1;
            }
        }
        if (hi <= lo) {
            open = false;
            continue;
        }
        if (open and out[n - 1].left == lo and out[n - 1].right == hi) {
            out[n - 1].bottom = y + 1;
        } else if (n == out.len) {
            out[n - 1] = unite(out[n - 1], .{ .left = lo, .top = y, .right = hi, .bottom = y + 1 }).?;
        } else {
            out[n] = .{ .left = lo, .top = y, .right = hi, .bottom = y + 1 };
            n += 1;
        }
        open = true;
    }
    return out[0..n];
}

fn copyRect(dst: []u32, src: []const u32, w: i32, r: Rect) void {
    const cw: usize = @intCast(w);
    var y = r.top;
    while (y < r.bottom) : (y += 1) {
        const a = @as(usize, @intCast(y)) * cw + @as(usize, @intCast(r.left));
        const b = a + @as(usize, @intCast(r.right - r.left));
        @memcpy(dst[a..b], src[a..b]);
    }
}

fn slot(comptime F: type, obj: Obj, index: usize) F {
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(vtbl.*[index]);
}

/// The step in progress and the HRESULT it failed with, for the log line.
var stage: []const u8 = "";
var last_hr: HRESULT = 0;

fn check(hr: HRESULT) Error!void {
    if (hr < 0) {
        last_hr = hr;
        return error.ComFailed;
    }
}

fn query(obj: Obj, iid: *const GUID) Error!Obj {
    const F = *const fn (Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT;
    var out: ?Obj = null;
    try check(slot(F, obj, 0)(obj, iid, &out));
    return out orelse error.ComFailed;
}

fn release(obj: Obj) void {
    const F = *const fn (Obj) callconv(.winapi) u32;
    _ = slot(F, obj, 2)(obj);
}

// The composition thread's writes (T2770). DirectComposition objects are
// free-threaded; these touch no Host state and none of the diagnostics
// (`stage`, `last_hr`) the window thread's own calls write, so the thread
// can call them under the drag's device lock without a Host at all.

/// Take a reference for another thread to hold.
pub fn addRefObj(obj: Obj) void {
    const F = *const fn (Obj) callconv(.winapi) u32;
    _ = slot(F, obj, 1)(obj);
}

pub fn releaseObj(obj: Obj) void {
    release(obj);
}

/// A pane visual at `pose`: its offset, and its clip - through the rounded
/// clip object `rounded` when the clip has corners (the window thread made
/// it and set its radii; null leaves a rounded clip as it was), else the
/// visual's own clip rect. The shadow riding with it, if any, follows at its
/// delta. False on the first failed call (a lost device): the caller stops.
pub fn writePose(vis: Obj, rounded: ?Obj, pose: comp_tree.Pose, shadow: ?Obj, sdx: f32, sdy: f32) bool {
    const Set = *const fn (Obj, f32) callconv(.winapi) HRESULT;
    if (shadow) |s| {
        if (slot(Set, s, slot_dcomp_visual_set_offset_x)(s, pose.x + sdx) < 0) return false;
        if (slot(Set, s, slot_dcomp_visual_set_offset_y)(s, pose.y + sdy) < 0) return false;
    }
    if (slot(Set, vis, slot_dcomp_visual_set_offset_x)(vis, pose.x) < 0) return false;
    if (slot(Set, vis, slot_dcomp_visual_set_offset_y)(vis, pose.y) < 0) return false;
    const c = pose.clip;
    if (c.rounded()) {
        const rc = rounded orelse return true;
        if (slot(Set, rc, slot_dcomp_rect_clip_set_left)(rc, c.left) < 0) return false;
        if (slot(Set, rc, slot_dcomp_rect_clip_set_top)(rc, c.top) < 0) return false;
        if (slot(Set, rc, slot_dcomp_rect_clip_set_right)(rc, c.right) < 0) return false;
        if (slot(Set, rc, slot_dcomp_rect_clip_set_bottom)(rc, c.bottom) < 0) return false;
        return true;
    }
    const r: D2D1_RECT_F = .{ .left = c.left, .top = c.top, .right = c.right, .bottom = c.bottom };
    return slot(*const fn (Obj, *const D2D1_RECT_F) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_clip_rect)(vis, &r) >= 0;
}

/// `IDCompositionDevice::Commit`, its HRESULT.
pub fn commitDevice(dcomp: Obj) HRESULT {
    return slot(*const fn (Obj) callconv(.winapi) HRESULT, dcomp, slot_dcomp_device_commit)(dcomp);
}

/// `DCOMPOSITION_ERROR_SURFACE_BEING_RENDERED`: a Commit made while some
/// surface of the device is between BeginDraw and EndDraw. Transient - the
/// device is fine and the next Commit goes up.
pub const dcomp_surface_being_rendered: HRESULT = @bitCast(@as(u32, 0x88980801));

/// An HRESULT the way the SDK prints it, for the log.
pub fn hex(hr: HRESULT) u32 {
    return @bitCast(hr);
}

extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;

const D3D11CreateDeviceFn = *const fn (?Obj, u32, ?*anyopaque, u32, ?*const u32, u32, u32, *?Obj, ?*u32, *?Obj) callconv(.winapi) HRESULT;
const DCompCreateDeviceFn = *const fn (?Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT;
const D2D1CreateFactoryFn = *const fn (u32, *const GUID, ?*const anyopaque, *?Obj) callconv(.winapi) HRESULT;

const Entry = struct {
    d3d11_create: D3D11CreateDeviceFn,
    dcomp_create: DCompCreateDeviceFn,
    d2d_create: D2D1CreateFactoryFn,

    fn load() Error!Entry {
        const d3d11 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse return error.Unavailable;
        const dcomp = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll")) orelse return error.Unavailable;
        const d2d1 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d2d1.dll")) orelse return error.Unavailable;
        return .{
            .d3d11_create = @ptrCast(GetProcAddress(d3d11, "D3D11CreateDevice") orelse return error.Unavailable),
            .dcomp_create = @ptrCast(GetProcAddress(dcomp, "DCompositionCreateDevice") orelse return error.Unavailable),
            .d2d_create = @ptrCast(GetProcAddress(d2d1, "D2D1CreateFactory") orelse return error.Unavailable),
        };
    }
};

/// Why `lostReason` said the device is gone.
pub const Loss = enum {
    d3d_removed,
    dcomp_invalid,
    simulated,

    pub fn label(self: Loss) []const u8 {
        return switch (self) {
            .d3d_removed => "d3d11 device removed",
            .dcomp_invalid => "dcomp device invalid",
            .simulated => "simulated (debug test hook)",
        };
    }
};

/// One of the focus glow's layers (T2574): a child of the desk visual, its
/// own premultiplied surface, and the effect group its opacity fades on.
pub const GlowVis = struct {
    visual: ?Obj = null,
    effect: ?Obj = null,
    surface: ?Obj = null,
    w: i32 = 0,
    h: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
};

/// One pane card's drop shadow on the compositor (T2741): a child of the
/// desk's shadow layer (under the glow and the overlay, over the desk's
/// own pixels), its own premultiplied surface (`shadow_layer.render`), and
/// the effect group whose opacity is the card's shadow share. The pane's
/// `Surface` owns it; `panePlace` and `paneGlide` move it with the pane.
pub const ShadowVis = struct {
    visual: ?Obj = null,
    effect: ?Obj = null,
    surface: ?Obj = null,
    w: i32 = 0,
    h: i32 = 0,
    /// The desk it hangs under (`Host.desk_gen`): a desk taken down and put
    /// back up again is a new tree, and this one is no longer in it.
    desk_gen: u32 = 0,
    opacity: f32 = -1,
    /// Where it was last placed, in the desk's pixels (NaN: unknown, as
    /// after a glide).
    x: f32 = std.math.nan(f32),
    y: f32 = std.math.nan(f32),

    pub fn live(self: *const ShadowVis) bool {
        return self.visual != null;
    }
};

/// A folding card's face as a picture in the window's pane layer (T2777):
/// the strip's band and name with the pane's carried frame over it, the
/// same pixels the face popup (`StripFace`) shows, placed and faded from the
/// window's thread. A child of the layer's face container, which stays over
/// every pane visual, so the face covers the card it stands for. The face
/// owns it; `faceShow` makes it on first use and `faceDrop` ends it.
pub const FaceVis = struct {
    visual: ?Obj = null,
    effect: ?Obj = null,
    surface: ?Obj = null,
    /// The rounded clip object, once a card shape needs one.
    clip: ?Obj = null,
    /// The surface's size: the largest frame this glide has needed.
    sw: i32 = 0,
    sh: i32 = 0,
    /// The host it was made on (`Host.rebuilds`): a rebuilt host's tree no
    /// longer holds it.
    epoch: u32 = 0,
    opacity: f32 = -1,
    /// A declared glide (T2778): the face is three pictures under `visual`
    /// - the band, the strip's name over it, the carried frame over both at
    /// its own strength - whose clip, places and strength the compositor
    /// runs. `visual` holds no picture of its own then.
    band: FaceLayer = .{},
    name: FaceLayer = .{},
    content: FaceLayer = .{},
    content_effect: ?Obj = null,
    declared: bool = false,

    pub fn live(self: *const FaceVis) bool {
        return self.visual != null;
    }
};

/// One picture of a declared face (`FaceVis.declared`, T2778).
pub const FaceLayer = struct {
    visual: ?Obj = null,
    surface: ?Obj = null,
    sw: i32 = 0,
    sh: i32 = 0,

    fn release_(self: *FaceLayer) void {
        if (self.surface) |o| release(o);
        if (self.visual) |o| release(o);
        self.* = .{};
    }
};

/// A picture handed to `Host.faceDeclare`: `w` x `h` of a buffer whose rows
/// are `stride` pixels apart, premultiplied, top-down.
pub const FacePic = struct {
    px: []const u32,
    stride: i32,
    w: i32,
    h: i32,
};

/// A strip card's face, declared whole (T2778; an opening card's since
/// T2779): its band at (`band_x`, `band_y`) and never moved, the name and the
/// carried frame placed, the card clip, and the frame's strength from `from`
/// to `to` along `curve` (`span_s` long; `comp_overlay.fitFollower`). The
/// strength line runs only between `fade_enter_s` (null: from the start) and
/// `fade_leave_s` (null: to the end), held at its ends clamped to 0..1
/// outside them. `content` empty (w 0): no frame yet, the band and name alone.
pub const FaceGlide = struct {
    band: FacePic,
    band_x: i32,
    band_y: i32,
    name: ?FacePic,
    content: FacePic,
    from: comp_tree.FacePose,
    to: comp_tree.FacePose,
    curve: []const comp_overlay.Cubic,
    span_s: f64,
    fade_enter_s: ?f64 = null,
    fade_leave_s: ?f64 = null,
};

/// A pane card's shadow riding with its pane visual (T2741): its offset is
/// the pane visual's plus `dx`, `dy` - the desk's origin already taken out -
/// set or glided in the same commit as the pane's.
pub const ShadowRide = struct {
    sv: *ShadowVis,
    dx: f32,
    dy: f32,
};

/// One `IDCompositionAnimation::AddCubic` segment, in 0..1 opacity units:
/// from `begin_s` on, c0 + c1 s + c2 s^2 + c3 s^3 with `s` the seconds since.
pub const Cubic = comp_overlay.Cubic;

/// One top-level window's chrome host. Created, used and destroyed on the
/// window's own thread.
pub const Host = struct {
    hwnd: HWND,
    device: Obj, // ID3D11Device
    context: Obj, // ID3D11DeviceContext
    d2d_factory: Obj, // ID2D1Factory1
    d2d_device: Obj, // ID2D1Device
    d2d: Obj, // ID2D1DeviceContext
    dcomp: Obj, // IDCompositionDevice
    target: Obj, // IDCompositionTarget, topmost=FALSE
    warp: bool,
    /// HRESULTs of the two steps the oracle names.
    target_hr: HRESULT = 0,
    d2d_hr: HRESULT = 0,

    /// The debug test fill (`GHOZTTY_COMP_CHROME_TEST_FILL`), or null.
    fill_visual: ?Obj = null,
    fill_surface: ?Obj = null,

    /// A window with no redirection surface (T2548): the target's root is
    /// `base_visual`, whose bottom child is the backstop - one pixel of the
    /// window's background stretched past any client size - so a strip no
    /// visual has reached yet (a grow, the first paint) is the background
    /// rather than whatever is behind the window. The chrome's root hangs
    /// above it. `backstop_rgb` is 0xRRGGBB, kept for a rebuild.
    backstop_rgb: ?u32 = null,
    base_visual: ?Obj = null,
    backstop_visual: ?Obj = null,
    backstop_surface: ?Obj = null,

    /// The desk (T2509): `PaneDesk`'s composed buffer as the bottom visual,
    /// placed at the content area and clipped to below the caption. Null
    /// while the desk is on GDI.
    desk_visual: ?Obj = null,
    desk_surface: ?Obj = null,
    desk_w: i32 = 0,
    desk_h: i32 = 0,
    desk_x: i32 = 0,
    desk_y: i32 = 0,
    desk_clip: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    /// The desk's pixels carry their own alpha (T2541): a translucent
    /// window's, premultiplied over window pixels cleared under it.
    desk_premul: bool = false,
    /// Uploads since the window last read them: whole buffers, rectangles,
    /// and the pixels the rectangles covered.
    desk_full: u32 = 0,
    desk_partial: u32 = 0,
    desk_partial_px: u64 = 0,
    /// A step of the desk visual failed on this host; its desk stays GDI
    /// until the host is rebuilt.
    desk_failed: bool = false,

    /// The target's root while the desk is up: a container whose children
    /// are the desk and, above it, the caption band.
    root_visual: ?Obj = null,
    /// The caption band (T2543): the caption and tab bar's `Mirror`, at the
    /// client origin above the desk. Lives only while the desk does.
    cap_visual: ?Obj = null,
    cap_surface: ?Obj = null,
    cap_w: i32 = 0,
    cap_h: i32 = 0,
    /// Band uploads since the window last read them: whole, and rectangles.
    cap_full: u32 = 0,
    cap_partial: u32 = 0,
    /// A step of the caption visual failed on this host; the band stays GDI
    /// (over the desk visual's clip) until the host is rebuilt.
    cap_failed: bool = false,
    /// `GHOZTTY_COMP_CHROME_CAPTION_FREEZE`: drop dirty-rect band uploads.
    cap_freeze: bool = false,

    /// What the painters over the desk drew (T2544), as a child of the desk
    /// visual - so it has the desk's offset and clip - and the desk's size.
    /// Lives only while the desk does.
    ovl_visual: ?Obj = null,
    ovl_surface: ?Obj = null,
    ovl_w: i32 = 0,
    ovl_h: i32 = 0,
    /// Overlay uploads since the window last read them: whole, rectangles.
    ovl_full: u32 = 0,
    ovl_partial: u32 = 0,

    /// The focus glow's layers (T2574): the lit card's and, mid-move, the
    /// one it is leaving, each a premultiplied picture under the overlay that
    /// the compositor fades by its own opacity. Live only with the desk.
    glows: [2]GlowVis = .{ .{}, .{} },
    /// Glow uploads since the window last read them.
    glow_uploads: u32 = 0,
    /// A step of a glow layer failed on this host; the glow stays in the
    /// desk until the host is rebuilt.
    glow_failed: bool = false,
    /// The card shadows' layer (T2741): the desk's bottom child, made with
    /// the desk, holding one `ShadowVis` per card whose shadow left the desk
    /// compose. `desk_gen` counts desks put up, so a shadow can tell it hangs
    /// under one that is gone.
    shadow_root: ?Obj = null,
    desk_gen: u32 = 0,
    /// Shadow uploads since the window last read them.
    shadow_uploads: u32 = 0,
    /// A step of a shadow visual failed on this host; the shadows stay in the
    /// desk compose until the host is rebuilt.
    shadow_failed: bool = false,
    /// A hero selection slide the compositor runs (T2573): a container at
    /// the hero rect, clipped to it, over the overlay, holding the outgoing
    /// and incoming panes' pictures whose offsets glide on DWM's clock. Live
    /// only with the desk, and only while a slide runs.
    hero_box: ?Obj = null,
    hero_pics: [2]?Obj = .{ null, null },
    hero_surfs: [2]?Obj = .{ null, null },
    /// Slides declared since the host was built, for the log and the oracle.
    hero_slides: u32 = 0,
    /// A step of the overlay failed on this host; a window that needs one
    /// keeps its desk on GDI until the host is rebuilt.
    ovl_failed: bool = false,
    /// `GHOZTTY_COMP_CHROME_OVERLAY_FREEZE`: drop dirty-rect overlay uploads.
    ovl_freeze: bool = false,
    /// `GHOZTTY_COMP_CHROME_FLAT_FREEZE`: the flat desk drops its dirty-rect
    /// uploads (T2545; the window reads it, the host only carries it).
    flat_freeze: bool = false,

    /// Set across a window paint: uploads leave the commit to `flush`, so
    /// the desk and the caption band reach the screen in the same frame.
    defer_commit: bool = false,
    commit_pending: bool = false,

    /// The pane layer (T2553): a second target, topmost=TRUE so it composes
    /// over the pane child windows, whose root holds one visual per pane
    /// presenting into a composition surface handle. Made on first adopt.
    pane_target: ?Obj = null,
    pane_root: ?Obj = null,
    /// Pane visuals adopted since the host was built, for the log.
    pane_adopts: u32 = 0,
    /// The folding cards' faces (T2777): a container in the pane layer, over
    /// every pane visual (a pane adopted later goes in below it), made the
    /// first time a face goes up.
    face_root: ?Obj = null,
    /// A step of a face visual failed on this host; faces stay on their
    /// popups until the host is rebuilt.
    face_failed: bool = false,
    /// Face frames uploaded since the host was built, for the log.
    face_uploads: u32 = 0,

    /// How many times this window's host was rebuilt after a device loss.
    rebuilds: u32 = 0,
    /// `GHOZTTY_COMP_CHROME_FORCE_LOSS`: report the device lost once.
    force_loss: bool = false,

    /// Build the host for `hwnd`. Never attaches a visual unless the debug
    /// test fill asks for one.
    pub fn init(hwnd: HWND) Error!Host {
        if (comptime builtin.os.tag != .windows) return error.Unavailable;
        last_hr = 0;

        stage = "load-libraries";
        const entry = try Entry.load();

        stage = "d3d11-device";
        var device: ?Obj = null;
        var context: ?Obj = null;
        var warp = false;
        if (entry.d3d11_create(null, D3D_DRIVER_TYPE_HARDWARE, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context) < 0) {
            warp = true;
            try check(entry.d3d11_create(null, D3D_DRIVER_TYPE_WARP, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context));
        }
        const dev = device orelse return error.ComFailed;
        errdefer release(dev);
        const ctx = context orelse return error.ComFailed;
        errdefer release(ctx);

        stage = "dxgi-device";
        const dxgi_device = try query(dev, &IID_IDXGIDevice);
        defer release(dxgi_device);

        stage = "d2d-factory";
        var factory: ?Obj = null;
        try check(entry.d2d_create(D2D1_FACTORY_TYPE_SINGLE_THREADED, &IID_ID2D1Factory1, null, &factory));
        const fac = factory orelse return error.ComFailed;
        errdefer release(fac);

        stage = "d2d-device";
        var d2d_device: ?Obj = null;
        const d2d_hr = slot(*const fn (Obj, Obj, *?Obj) callconv(.winapi) HRESULT, fac, slot_d2d_factory1_create_device)(fac, dxgi_device, &d2d_device);
        try check(d2d_hr);
        const d2d_dev = d2d_device orelse return error.ComFailed;
        errdefer release(d2d_dev);

        stage = "d2d-context";
        var d2d_ctx: ?Obj = null;
        try check(slot(*const fn (Obj, u32, *?Obj) callconv(.winapi) HRESULT, d2d_dev, slot_d2d_device_create_context)(d2d_dev, 0, &d2d_ctx));
        const d2d = d2d_ctx orelse return error.ComFailed;
        errdefer release(d2d);

        stage = "dcomp-device";
        var dcomp: ?Obj = null;
        try check(entry.dcomp_create(dxgi_device, &IID_IDCompositionDevice, &dcomp));
        const dc = dcomp orelse return error.ComFailed;
        errdefer release(dc);

        stage = "dcomp-target";
        var target: ?Obj = null;
        // topmost=FALSE: under the pane child windows, over this window's
        // own GDI pixels (the reason nothing is attached yet).
        const target_hr = slot(*const fn (Obj, HWND, i32, *?Obj) callconv(.winapi) HRESULT, dc, slot_dcomp_device_create_target)(dc, hwnd, 0, &target);
        try check(target_hr);
        const tg = target orelse return error.ComFailed;
        errdefer release(tg);

        var self: Host = .{
            .hwnd = hwnd,
            .device = dev,
            .context = ctx,
            .d2d_factory = fac,
            .d2d_device = d2d_dev,
            .d2d = d2d,
            .dcomp = dc,
            .target = tg,
            .warp = warp,
            .target_hr = target_hr,
            .d2d_hr = d2d_hr,
            .force_loss = seamBuild() and envOn("GHOZTTY_COMP_CHROME_FORCE_LOSS"),
            .cap_freeze = seamBuild() and envOn("GHOZTTY_COMP_CHROME_CAPTION_FREEZE"),
            .ovl_freeze = seamBuild() and envOn("GHOZTTY_COMP_CHROME_OVERLAY_FREEZE"),
            .flat_freeze = seamBuild() and envOn("GHOZTTY_COMP_CHROME_FLAT_FREEZE"),
        };
        if (seamBuild() and envOn("GHOZTTY_COMP_CHROME_TEST_FILL")) {
            // The fill is a test seam: failing it costs the probe, not the host.
            self.attachTestFill() catch log.warn(
                "chrome composition test fill failed at {s}: hr=0x{x:0>8}",
                .{ stage, hex(last_hr) },
            );
        }
        stage = "";
        return self;
    }

    /// The failing step and HRESULT of the last `init` error, for the log.
    pub fn lastFailure() struct { stage: []const u8, hr: HRESULT } {
        return .{ .stage = stage, .hr = last_hr };
    }

    pub fn adapter(self: *const Host) []const u8 {
        return if (self.warp) "warp" else "hardware";
    }

    /// One magenta visual over the whole client area, drawn with Direct2D
    /// into a composition surface - so the probe also proves the D2D context
    /// can target what the compositor shows.
    fn attachTestFill(self: *Host) Error!void {
        var rc: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &rc) == 0) return error.ComFailed;
        const w: u32 = @intCast(@max(rc.right - rc.left, 1));
        const h: u32 = @intCast(@max(rc.bottom - rc.top, 1));

        stage = "fill-surface";
        var surface: ?Obj = null;
        try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, w, h, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &surface));
        const surf = surface orelse return error.ComFailed;
        errdefer release(surf);

        stage = "fill-draw";
        try self.clearSurface(surf, w, h, .{ .r = 1, .g = 0, .b = 1, .a = 1 });

        stage = "fill-visual";
        var visual: ?Obj = null;
        try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_visual)(self.dcomp, &visual));
        const vis = visual orelse return error.ComFailed;
        errdefer release(vis);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, surf));
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, vis));
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp));
        self.fill_surface = surf;
        self.fill_visual = vis;
        log.info("chrome composition test fill attached: {d}x{d}", .{ w, h });
    }

    /// The backstop (T2548): `base_visual` as the target's root, holding one
    /// pixel of `rgb` (0xRRGGBB) scaled past any client area - hard edges and
    /// nearest sampling, so the stretch is one flat colour to the corner.
    fn attachBackstop(self: *Host, rgb: u32) Error!void {
        stage = "backstop-surface";
        var surface: ?Obj = null;
        try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, 1, 1, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &surface));
        const surf = surface orelse return error.ComFailed;
        errdefer release(surf);
        try self.clearSurface(surf, 1, 1, rgbColor(rgb));

        stage = "backstop-visual";
        const vis = try self.newVisual();
        errdefer release(vis);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, surf));
        try check(slot(*const fn (Obj, u32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_interpolation)(vis, DCOMPOSITION_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR));
        try check(slot(*const fn (Obj, u32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_border_mode)(vis, DCOMPOSITION_BORDER_MODE_HARD));
        const scale: D2D_MATRIX_3X2_F = .{ .m11 = backstop_scale, .m12 = 0, .m21 = 0, .m22 = backstop_scale, .dx = 0, .dy = 0 };
        try check(slot(*const fn (Obj, *const D2D_MATRIX_3X2_F) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_transform_matrix)(vis, &scale));

        stage = "backstop-base";
        const base = try self.newVisual();
        errdefer release(base);
        try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, base, slot_dcomp_visual_add_visual)(base, vis, 0, null));
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, base));
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp));
        self.backstop_surface = surf;
        self.backstop_visual = vis;
        self.base_visual = base;
        self.backstop_rgb = rgb;
        log.info("chrome backstop attached: rgb=0x{x:0>6} (no redirection surface)", .{rgb});
    }

    /// Clear `w` x `h` of a fresh composition surface to `color` with
    /// Direct2D.
    fn clearSurface(self: *Host, surf: Obj, w: u32, h: u32, color: D2D1_COLOR_F) Error!void {
        var dxgi_surface: ?Obj = null;
        var offset: w32.POINT = .{ .x = 0, .y = 0 };
        try check(slot(*const fn (Obj, ?*const w32.RECT, *const GUID, *?Obj, *w32.POINT) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_begin_draw)(surf, null, &IID_IDXGISurface, &dxgi_surface, &offset));
        const ds = dxgi_surface orelse return error.ComFailed;
        {
            defer release(ds);
            const props: D2D1_BITMAP_PROPERTIES1 = .{
                .format = DXGI_FORMAT_B8G8R8A8_UNORM,
                .alpha_mode = D2D1_ALPHA_MODE_PREMULTIPLIED,
                .dpi_x = 96,
                .dpi_y = 96,
                .options = D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                .color_context = null,
            };
            var bitmap: ?Obj = null;
            const bhr = slot(*const fn (Obj, Obj, *const D2D1_BITMAP_PROPERTIES1, *?Obj) callconv(.winapi) HRESULT, self.d2d, slot_d2d_dc_bitmap_from_dxgi)(self.d2d, ds, &props, &bitmap);
            if (bhr < 0 or bitmap == null) {
                _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_end_draw)(surf);
                try check(if (bhr < 0) bhr else -1);
            }
            const bmp = bitmap.?;
            defer release(bmp);
            slot(*const fn (Obj, ?Obj) callconv(.winapi) void, self.d2d, slot_d2d_dc_set_target)(self.d2d, bmp);
            slot(*const fn (Obj) callconv(.winapi) void, self.d2d, slot_d2d_rt_begin_draw)(self.d2d);
            // The surface may live in an atlas: draw only inside our update
            // rect, which starts at `offset`.
            const clip: D2D1_RECT_F = .{
                .left = @floatFromInt(offset.x),
                .top = @floatFromInt(offset.y),
                .right = @floatFromInt(offset.x + @as(i32, @intCast(w))),
                .bottom = @floatFromInt(offset.y + @as(i32, @intCast(h))),
            };
            slot(*const fn (Obj, *const D2D1_RECT_F, u32) callconv(.winapi) void, self.d2d, slot_d2d_rt_push_clip)(self.d2d, &clip, D2D1_ANTIALIAS_MODE_ALIASED);
            slot(*const fn (Obj, *const D2D1_COLOR_F) callconv(.winapi) void, self.d2d, slot_d2d_rt_clear)(self.d2d, &color);
            slot(*const fn (Obj) callconv(.winapi) void, self.d2d, slot_d2d_rt_pop_clip)(self.d2d);
            const ehr = slot(*const fn (Obj, ?*u64, ?*u64) callconv(.winapi) HRESULT, self.d2d, slot_d2d_rt_end_draw)(self.d2d, null, null);
            slot(*const fn (Obj, ?Obj) callconv(.winapi) void, self.d2d, slot_d2d_dc_set_target)(self.d2d, null);
            const shr = slot(*const fn (Obj) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_end_draw)(surf);
            try check(ehr);
            try check(shr);
        }
    }

    /// Whether the desk can be carried here. Not under the debug test fill,
    /// whose probe measures the fill over the desk's margins.
    pub fn deskAvailable(self: *const Host) bool {
        return self.fill_visual == null and !self.desk_failed;
    }

    pub fn deskLive(self: *const Host) bool {
        return self.desk_visual != null;
    }

    /// Put the desk visual at `(x, y)` in the client area, showing only
    /// `clip` (client pixels). Building it the first time; the next
    /// `deskUpload` commits.
    pub fn deskPlace(self: *Host, x: i32, y: i32, clip: Rect) Error!void {
        if (self.desk_visual == null) {
            stage = "desk-visual";
            const root = try self.ensureRoot();
            const vis = try self.newVisual();
            errdefer release(vis);
            // The desk is the bottom child: below the caption band if one is
            // already there, named explicitly rather than leaning on what a
            // null reference means.
            try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, root, slot_dcomp_visual_add_visual)(root, vis, 0, self.cap_visual));
            self.desk_visual = vis;
            self.desk_gen +%= 1;
            // Placed below whatever it was before.
            self.desk_x = std.math.minInt(i32);
            log.info("chrome desk visual attached", .{});
            // The card shadows' layer is the desk's first child, so every
            // child added on top later (the glow, the overlay, a hero slide)
            // lies over it (T2741). Failing it costs only the shadows.
            self.makeShadowRoot(vis) catch {
                self.shadow_failed = true;
                log.warn("chrome shadow layer failed at {s}: hr=0x{x:0>8}; card shadows stay in the desk", .{ stage, hex(last_hr) });
            };
        }
        const vis = self.desk_visual.?;
        if (x != self.desk_x or y != self.desk_y) {
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_x)(vis, @floatFromInt(x)));
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_y)(vis, @floatFromInt(y)));
            self.desk_x = x;
            self.desk_y = y;
            self.desk_clip = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        }
        if (!std.meta.eql(clip, self.desk_clip)) {
            // In the visual's own space, which starts at its offset.
            const r: D2D1_RECT_F = .{
                .left = @floatFromInt(clip.left - x),
                .top = @floatFromInt(clip.top - y),
                .right = @floatFromInt(clip.right - x),
                .bottom = @floatFromInt(clip.bottom - y),
            };
            try check(slot(*const fn (Obj, *const D2D1_RECT_F) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_clip_rect)(vis, &r));
            self.desk_clip = clip;
        }
    }

    /// Whether the next desk uploads are premultiplied (T2541) - a translucent
    /// window's - or opaque, whose alpha byte is GDI's zero and ignored. A
    /// change takes a new surface, so the next upload sends the whole buffer.
    pub fn deskPremultiplied(self: *Host, premul: bool) void {
        if (premul == self.desk_premul) return;
        self.desk_premul = premul;
        log.info("chrome desk visual alpha: {s}", .{if (premul) "premultiplied (translucent window)" else "opaque"});
        if (self.desk_surface) |old| release(old);
        self.desk_surface = null;
    }

    /// The desk's composed buffer, `w` x `h` BGRA rows, into the visual:
    /// only `rects` of it when the surface already holds the rest (null:
    /// all of it), then one commit. A new size, or a surface lost with the
    /// device, takes the whole buffer whatever `rects` says.
    pub fn deskUpload(self: *Host, px: []const u32, w: i32, h: i32, rects: ?[]const Rect) Error!void {
        const vis = self.desk_visual orelse return error.Unavailable;
        if (w <= 0 or h <= 0 or px.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return error.ComFailed;
        var whole = rects == null;
        var t0 = std.time.Timer.start() catch null;
        var create_ns: u64 = 0;
        defer if (whole and t0 != null and uploadTraceOn()) {
            const total = t0.?.read();
            log.info("desk upload trace create_us={d} rest_us={d} ({d}x{d})", .{ create_ns / 1000, (total - create_ns) / 1000, w, h });
        };
        if (self.desk_surface == null or w != self.desk_w or h != self.desk_h) {
            defer create_ns = if (t0) |*t| t.read() else 0;
            stage = "desk-surface";
            if (self.desk_surface) |old| release(old);
            self.desk_surface = null;
            var surface: ?Obj = null;
            try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, @intCast(w), @intCast(h), DXGI_FORMAT_B8G8R8A8_UNORM, if (self.desk_premul) DXGI_ALPHA_MODE_PREMULTIPLIED else DXGI_ALPHA_MODE_IGNORE, &surface));
            const surf = surface orelse return error.ComFailed;
            errdefer release(surf);
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, surf));
            self.desk_surface = surf;
            self.desk_w = w;
            self.desk_h = h;
            whole = true;
        }
        stage = "desk-upload";
        if (whole) {
            try self.deskDraw(px, w, .{ .left = 0, .top = 0, .right = w, .bottom = h });
            self.desk_full +|= 1;
        } else for (rects.?) |r| {
            const c: Rect = .{
                .left = std.math.clamp(r.left, 0, w),
                .top = std.math.clamp(r.top, 0, h),
                .right = std.math.clamp(r.right, 0, w),
                .bottom = std.math.clamp(r.bottom, 0, h),
            };
            if (c.right <= c.left or c.bottom <= c.top) continue;
            try self.deskDraw(px, w, c);
            self.desk_partial +|= 1;
            self.desk_partial_px +|= @intCast(@as(i64, c.right - c.left) * (c.bottom - c.top));
        }
        try self.commit();
    }

    var upload_trace_state: ?bool = null;

    /// `GHOZTTY_RESIZE_TRACE`: what a whole desk upload costs (T2577).
    fn uploadTraceOn() bool {
        if (upload_trace_state) |v| return v;
        const v = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_RESIZE_TRACE");
        upload_trace_state = v;
        return v;
    }

    fn deskDraw(self: *Host, px: []const u32, w: i32, r: Rect) Error!void {
        try self.drawRect(self.desk_surface.?, px, w, r);
    }

    /// Commit now, or at `flush` when a paint is batching its uploads.
    fn commit(self: *Host) Error!void {
        if (self.defer_commit) {
            self.commit_pending = true;
            return;
        }
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp));
    }

    /// Start batching a paint's uploads into one commit.
    pub fn beginBatch(self: *Host) void {
        self.defer_commit = true;
    }

    /// End the batch: everything the paint uploaded goes up in one commit.
    pub fn flush(self: *Host) Error!void {
        self.defer_commit = false;
        if (!self.commit_pending) return;
        self.commit_pending = false;
        try self.commit();
    }

    fn newVisual(self: *Host) Error!Obj {
        var visual: ?Obj = null;
        try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_visual)(self.dcomp, &visual));
        return visual orelse error.ComFailed;
    }

    /// The container the desk and the caption band hang from, made the
    /// target's root the first time.
    fn ensureRoot(self: *Host) Error!Obj {
        if (self.root_visual) |r| return r;
        const root = try self.newVisual();
        errdefer release(root);
        if (self.base_visual) |base| {
            // Over the backstop, named explicitly (T2548).
            try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, base, slot_dcomp_visual_add_visual)(base, root, 1, self.backstop_visual));
        } else try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, root));
        self.root_visual = root;
        return root;
    }

    pub fn capLive(self: *const Host) bool {
        return self.cap_visual != null;
    }

    /// The caption band's mirror, `w` x `h` client pixels from the client
    /// origin, into the visual above the desk: only `dirty` when the surface
    /// already holds the rest (null: all of it). A new size, or a band that
    /// was not up, takes the whole mirror. Only while the desk is up.
    pub fn capUpload(self: *Host, px: []const u32, w: i32, h: i32, dirty: ?Rect) Error!void {
        const desk = self.desk_visual orelse return error.Unavailable;
        if (w <= 0 or h <= 0 or px.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return error.ComFailed;
        var whole = dirty == null;
        if (self.cap_visual == null) {
            stage = "caption-visual";
            const vis = try self.newVisual();
            errdefer release(vis);
            try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, self.root_visual.?, slot_dcomp_visual_add_visual)(self.root_visual.?, vis, 1, desk));
            self.cap_visual = vis;
            log.info("chrome caption visual attached: {d}x{d}", .{ w, h });
            whole = true;
        }
        if (self.cap_surface == null or w != self.cap_w or h != self.cap_h) {
            stage = "caption-surface";
            if (self.cap_surface) |old| release(old);
            self.cap_surface = null;
            var surface: ?Obj = null;
            // Opaque, like the desk: GDI leaves the alpha byte at zero, and
            // on an opaque window every pixel of the band is painted.
            try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, @intCast(w), @intCast(h), DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_IGNORE, &surface));
            const surf = surface orelse return error.ComFailed;
            errdefer release(surf);
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.cap_visual.?, slot_dcomp_visual_set_content)(self.cap_visual.?, surf));
            self.cap_surface = surf;
            self.cap_w = w;
            self.cap_h = h;
            whole = true;
        }
        stage = "caption-upload";
        if (!whole and self.cap_freeze) return;
        const r = if (whole) Rect{ .left = 0, .top = 0, .right = w, .bottom = h } else bandDirty(dirty.?, w, h) orelse return;
        try self.drawRect(self.cap_surface.?, px, w, r);
        if (whole) self.cap_full +|= 1 else self.cap_partial +|= 1;
        try self.commit();
    }

    /// Take the caption band off the compositor; the desk stays.
    pub fn capHide(self: *Host) void {
        const vis = self.cap_visual orelse return;
        if (self.root_visual) |root| _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, root, slot_dcomp_visual_remove_visual)(root, vis);
        self.commit() catch {};
        self.releaseCap();
        log.info("chrome caption visual detached", .{});
    }

    fn releaseCap(self: *Host) void {
        if (self.cap_surface) |s| release(s);
        if (self.cap_visual) |v| release(v);
        self.cap_surface = null;
        self.cap_visual = null;
        self.cap_w = 0;
        self.cap_h = 0;
    }

    pub fn ovlLive(self: *const Host) bool {
        return self.ovl_visual != null;
    }

    /// The overlay's `w` x `h` premultiplied pixels (`Overlay.px`) into the
    /// visual over the desk: only `dirty` when the surface already holds the
    /// rest (null: all of it). A new size, or an overlay that was not up,
    /// takes all of it. Only while the desk is up.
    pub fn ovlUpload(self: *Host, px: []const u32, w: i32, h: i32, dirty: ?Rect) Error!void {
        const desk = self.desk_visual orelse return error.Unavailable;
        if (w <= 0 or h <= 0 or px.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return error.ComFailed;
        var whole = dirty == null;
        if (self.ovl_visual == null) {
            stage = "overlay-visual";
            const vis = try self.newVisual();
            errdefer release(vis);
            // The desk's top child: drawn over its content and every layer
            // on it, inside its clip. `insertAbove` FALSE with no reference
            // is the TOP of the z-order; TRUE with none is the bottom, which
            // put it under the card shadows' layer (T2793).
            try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, desk, slot_dcomp_visual_add_visual)(desk, vis, 0, null));
            self.ovl_visual = vis;
            log.info("chrome overlay visual attached: {d}x{d}", .{ w, h });
            whole = true;
        }
        if (self.ovl_surface == null or w != self.ovl_w or h != self.ovl_h) {
            stage = "overlay-surface";
            if (self.ovl_surface) |old| release(old);
            self.ovl_surface = null;
            var surface: ?Obj = null;
            try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, @intCast(w), @intCast(h), DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &surface));
            const surf = surface orelse return error.ComFailed;
            errdefer release(surf);
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.ovl_visual.?, slot_dcomp_visual_set_content)(self.ovl_visual.?, surf));
            self.ovl_surface = surf;
            self.ovl_w = w;
            self.ovl_h = h;
            whole = true;
        }
        stage = "overlay-upload";
        if (!whole and self.ovl_freeze) return;
        const r = if (whole) Rect{ .left = 0, .top = 0, .right = w, .bottom = h } else bandDirty(dirty.?, w, h) orelse return;
        try self.drawRect(self.ovl_surface.?, px, w, r);
        if (whole) self.ovl_full +|= 1 else self.ovl_partial +|= 1;
        try self.commit();
    }

    /// Take the overlay off the compositor; the desk stays.
    pub fn ovlHide(self: *Host) void {
        const vis = self.ovl_visual orelse return;
        if (self.desk_visual) |desk| _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, desk, slot_dcomp_visual_remove_visual)(desk, vis);
        self.commit() catch {};
        self.releaseOvl();
        log.info("chrome overlay visual detached", .{});
    }

    fn releaseOvl(self: *Host) void {
        if (self.ovl_surface) |s| release(s);
        if (self.ovl_visual) |v| release(v);
        self.ovl_surface = null;
        self.ovl_visual = null;
        self.ovl_w = 0;
        self.ovl_h = 0;
    }

    /// Whether the focus glow can go up as its own layers (T2574): the desk
    /// is on the compositor and no glow step has failed here.
    pub fn glowAvailable(self: *const Host) bool {
        return self.desk_visual != null and !self.glow_failed;
    }

    /// Glow layer `i`'s `w` x `h` premultiplied pixels, at `(x, y)` in the
    /// desk's own pixels, under the overlay. Built the first time, at
    /// opacity 0; `glowFade` shows it. Commits.
    pub fn glowUpload(self: *Host, i: usize, px: []const u32, x: i32, y: i32, w: i32, h: i32) Error!void {
        const desk = self.desk_visual orelse return error.Unavailable;
        if (w <= 0 or h <= 0 or px.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return error.ComFailed;
        const g = &self.glows[i];
        if (g.visual == null) {
            stage = "glow-visual";
            const vis = try self.newVisual();
            errdefer release(vis);
            var e: ?Obj = null;
            try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_effect_group)(self.dcomp, &e));
            const effect = e orelse return error.ComFailed;
            errdefer release(effect);
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, effect, slot_dcomp_effect_set_opacity_float)(effect, 0));
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_effect)(vis, effect));
            // Over the desk's content and the card layers (a card riding
            // whole carries its resting rim, which the lit one goes over,
            // T2793), under what the painters over it drew: below the
            // overlay when it is up, else on top - `insertAbove` FALSE with
            // no reference (an overlay that comes later goes on top of it).
            if (self.ovl_visual) |ovl| {
                try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, desk, slot_dcomp_visual_add_visual)(desk, vis, 0, ovl));
            } else try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, desk, slot_dcomp_visual_add_visual)(desk, vis, 0, null));
            g.visual = vis;
            g.effect = effect;
            g.x = std.math.minInt(i32);
        }
        const vis = g.visual.?;
        if (g.surface == null or w != g.w or h != g.h) {
            stage = "glow-surface";
            if (g.surface) |old| release(old);
            g.surface = null;
            var surface: ?Obj = null;
            try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, @intCast(w), @intCast(h), DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &surface));
            const surf = surface orelse return error.ComFailed;
            errdefer release(surf);
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, surf));
            g.surface = surf;
            g.w = w;
            g.h = h;
        }
        if (x != g.x or y != g.y) {
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_x)(vis, @floatFromInt(x)));
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_y)(vis, @floatFromInt(y)));
            g.x = x;
            g.y = y;
        }
        stage = "glow-upload";
        try self.drawRect(g.surface.?, px, w, .{ .left = 0, .top = 0, .right = w, .bottom = h });
        self.glow_uploads +|= 1;
        stage = "";
        try self.commit();
    }

    /// Fade glow layer `i` from `from` to `to` (0..1) along `curve` over
    /// `duration_s`, declared in one commit and run by DWM; no step of it
    /// waits on this thread. A null curve sets `to` at once.
    pub fn glowFade(self: *Host, i: usize, from: f32, to: f32, curve: ?[]const Cubic, duration_s: f64) Error!void {
        const e = self.glows[i].effect orelse return error.Unavailable;
        stage = "glow-fade";
        defer stage = "";
        const segs = curve orelse {
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, e, slot_dcomp_effect_set_opacity_float)(e, to));
            return self.commit();
        };
        var made: ?Obj = null;
        try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_animation)(self.dcomp, &made));
        const anim = made orelse return error.ComFailed;
        // The effect keeps its own snapshot of the function once it is set.
        defer release(anim);
        const add = slot(*const fn (Obj, f64, f32, f32, f32, f32) callconv(.winapi) HRESULT, anim, slot_dcomp_anim_add_cubic);
        const span: f64 = to - from;
        for (segs) |c| try check(add(anim, c.begin_s, @floatCast(from + span * c.c0), @floatCast(span * c.c1), @floatCast(span * c.c2), @floatCast(span * c.c3)));
        try check(slot(*const fn (Obj, f64, f32) callconv(.winapi) HRESULT, anim, slot_dcomp_anim_end)(anim, duration_s, to));
        try check(slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, e, slot_dcomp_effect_set_opacity_anim)(e, anim));
        try self.commit();
    }

    /// Take glow layer `i` off the compositor.
    pub fn glowHide(self: *Host, i: usize) void {
        const g = &self.glows[i];
        const vis = g.visual orelse return;
        if (self.desk_visual) |desk| _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, desk, slot_dcomp_visual_remove_visual)(desk, vis);
        self.commit() catch {};
        releaseGlow(g);
    }

    fn releaseGlow(g: *GlowVis) void {
        if (g.surface) |s| release(s);
        if (g.effect) |e| release(e);
        if (g.visual) |v| release(v);
        g.* = .{};
    }

    /// A hero selection slide, declared whole (T2573): `pics` are the
    /// outgoing and incoming panes' `w` x `h` premultiplied pictures, shown
    /// in `hero` (client pixels) and clipped to it; picture i's top goes
    /// from `ys[i][0]` to `ys[i][1]` (relative to the hero's top) along
    /// `curve` (0..1 of the way) over `span_s`, on the compositor's clock -
    /// so the slide moves on while the window's thread is busy. A slide
    /// already up is replaced. Commits.
    pub fn heroSlide(self: *Host, pics: [2][]const u32, w: i32, h: i32, hero: Rect, ys: [2][2]f32, curve: []const Cubic, span_s: f64) Error!void {
        const desk = self.desk_visual orelse return error.Unavailable;
        if (w <= 0 or h <= 0) return error.ComFailed;
        for (pics) |px| if (px.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return error.ComFailed;
        self.releaseHeroSlide(desk);
        errdefer self.releaseHeroSlide(desk);
        stage = "hero-slide";
        defer stage = "";
        const box = try self.newVisual();
        self.hero_box = box;
        const SetF = *const fn (Obj, f32) callconv(.winapi) HRESULT;
        // In the desk's own space, which starts at its offset.
        try check(slot(SetF, box, slot_dcomp_visual_set_offset_x)(box, @floatFromInt(hero.left - self.desk_x)));
        try check(slot(SetF, box, slot_dcomp_visual_set_offset_y)(box, @floatFromInt(hero.top - self.desk_y)));
        const r: D2D1_RECT_F = .{ .left = 0, .top = 0, .right = @floatFromInt(w), .bottom = @floatFromInt(h) };
        try check(slot(*const fn (Obj, *const D2D1_RECT_F) callconv(.winapi) HRESULT, box, slot_dcomp_visual_set_clip_rect)(box, &r));
        for (pics, 0..) |px, i| {
            const vis = try self.newVisual();
            self.hero_pics[i] = vis;
            var surface: ?Obj = null;
            try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, @intCast(w), @intCast(h), DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &surface));
            const surf = surface orelse return error.ComFailed;
            self.hero_surfs[i] = surf;
            try self.drawRect(surf, px, w, .{ .left = 0, .top = 0, .right = w, .bottom = h });
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, surf));
            const anim = try self.followAnimation(ys[i][0], ys[i][1], curve, span_s);
            defer release(anim);
            try check(slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_y - 1)(vis, anim));
            try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, box, slot_dcomp_visual_add_visual)(box, vis, 1, null));
        }
        // Over everything the desk holds, the overlay included.
        try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, desk, slot_dcomp_visual_add_visual)(desk, box, 1, null));
        self.hero_slides +|= 1;
        try self.commit();
    }

    /// Whether a declared hero slide is up.
    pub fn heroSlideLive(self: *const Host) bool {
        return self.hero_box != null;
    }

    /// Take a declared hero slide off the compositor. Commits.
    pub fn heroSlideHide(self: *Host) void {
        const desk = self.desk_visual orelse return;
        if (self.hero_box == null) return;
        self.releaseHeroSlide(desk);
        self.commit() catch {};
    }

    fn releaseHeroSlide(self: *Host, desk: ?Obj) void {
        if (self.hero_box) |box| {
            if (desk) |d| _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, d, slot_dcomp_visual_remove_visual)(d, box);
            release(box);
        }
        self.hero_box = null;
        for (&self.hero_pics, &self.hero_surfs) |*v, *s| {
            if (v.*) |o| release(o);
            if (s.*) |o| release(o);
            v.* = null;
            s.* = null;
        }
    }

    /// One rectangle of a `w`-wide buffer into `surf`. A surface may live in
    /// an atlas, so the rows land at the offset `BeginDraw` hands back.
    fn drawRect(self: *Host, surf: Obj, px: []const u32, w: i32, r: Rect) Error!void {
        const update: w32.RECT = .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
        var tex: ?Obj = null;
        var at: w32.POINT = .{ .x = 0, .y = 0 };
        try check(slot(*const fn (Obj, ?*const w32.RECT, *const GUID, *?Obj, *w32.POINT) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_begin_draw)(surf, &update, &IID_ID3D11Texture2D, &tex, &at));
        const t = tex orelse {
            _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_end_draw)(surf);
            return error.ComFailed;
        };
        const box: D3D11_BOX = .{
            .left = @intCast(@max(at.x, 0)),
            .top = @intCast(@max(at.y, 0)),
            .front = 0,
            .right = @intCast(@max(at.x, 0) + (r.right - r.left)),
            .bottom = @intCast(@max(at.y, 0) + (r.bottom - r.top)),
            .back = 1,
        };
        const first = @as(usize, @intCast(r.top)) * @as(usize, @intCast(w)) + @as(usize, @intCast(r.left));
        slot(*const fn (Obj, Obj, u32, *const D3D11_BOX, *const anyopaque, u32, u32) callconv(.winapi) void, self.context, slot_d3d11_context_update_subresource)(self.context, t, 0, &box, px[first..].ptr, @intCast(w * 4), 0);
        release(t);
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, surf, slot_dcomp_surface_end_draw)(surf));
    }

    fn makeShadowRoot(self: *Host, desk: Obj) Error!void {
        stage = "shadow-root";
        const root = try self.newVisual();
        errdefer release(root);
        try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, desk, slot_dcomp_visual_add_visual)(desk, root, 1, null));
        self.shadow_root = root;
        stage = "";
    }

    /// Whether card shadows can go up as their own visuals (T2741): the
    /// desk is on the compositor with its shadow layer, and no shadow step
    /// has failed here.
    pub fn shadowAvailable(self: *const Host) bool {
        return self.desk_visual != null and self.shadow_root != null and !self.shadow_failed;
    }

    /// Put `px` (`w` x `h`, premultiplied) up as `sv`'s picture: the visual
    /// made (or remade under a new desk) the first time, at opacity 0 until
    /// `shadowShow`, the surface remade for a new size. Commits.
    pub fn shadowUpload(self: *Host, sv: *ShadowVis, px: []const u32, w: i32, h: i32) Error!void {
        return self.uploadShadow(sv, px, w, h, false);
    }

    /// `shadowUpload` for a stack strip's blade layer (T2796): a new visual
    /// goes on TOP of the shadow root, where a card's goes to the bottom. On
    /// the desk the strips are laid after every card, so a blade shadow
    /// lands on a card beside it - and on a card riding whole (T2793), whose
    /// layer is that card, only from above it.
    pub fn bladeUpload(self: *Host, sv: *ShadowVis, px: []const u32, w: i32, h: i32) Error!void {
        return self.uploadShadow(sv, px, w, h, true);
    }

    fn uploadShadow(self: *Host, sv: *ShadowVis, px: []const u32, w: i32, h: i32, top: bool) Error!void {
        const root = self.shadow_root orelse return error.Unavailable;
        if (w <= 0 or h <= 0 or px.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return error.ComFailed;
        errdefer self.shadow_failed = true;
        if (sv.visual != null and sv.desk_gen != self.desk_gen) releaseShadow(sv);
        if (sv.visual == null) {
            stage = "shadow-visual";
            const vis = try self.newVisual();
            errdefer release(vis);
            var e: ?Obj = null;
            try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_effect_group)(self.dcomp, &e));
            const effect = e orelse return error.ComFailed;
            errdefer release(effect);
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, effect, slot_dcomp_effect_set_opacity_float)(effect, 0));
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_effect)(vis, effect));
            // `insertAbove` TRUE with no reference is the bottom of the
            // z-order, FALSE the top.
            try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, root, slot_dcomp_visual_add_visual)(root, vis, if (top) 0 else 1, null));
            sv.* = .{ .visual = vis, .effect = effect, .desk_gen = self.desk_gen, .opacity = 0 };
        }
        if (sv.surface == null or w != sv.w or h != sv.h) {
            stage = "shadow-surface";
            if (sv.surface) |old| release(old);
            sv.surface = null;
            var surface: ?Obj = null;
            try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, @intCast(w), @intCast(h), DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &surface));
            const surf = surface orelse return error.ComFailed;
            errdefer release(surf);
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, sv.visual.?, slot_dcomp_visual_set_content)(sv.visual.?, surf));
            sv.surface = surf;
            sv.w = w;
            sv.h = h;
        }
        stage = "shadow-upload";
        try self.drawRect(sv.surface.?, px, w, .{ .left = 0, .top = 0, .right = w, .bottom = h });
        self.shadow_uploads +|= 1;
        stage = "";
        try self.commit();
    }

    /// `sv` at its card's share (`opacity`, 0..1) and, unless a glide
    /// carries it, at `at` in the desk's pixels. Commits.
    pub fn shadowShow(self: *Host, sv: *ShadowVis, opacity: f32, at: ?[2]f32) Error!void {
        if (!self.shadowCurrent(sv)) return error.Unavailable;
        errdefer self.shadow_failed = true;
        stage = "shadow-show";
        defer stage = "";
        if (opacity != sv.opacity) {
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, sv.effect.?, slot_dcomp_effect_set_opacity_float)(sv.effect.?, opacity));
            sv.opacity = opacity;
        }
        if (at) |p| try shadowSetOffset(sv, p[0], p[1]);
        try self.commit();
    }

    /// Whether `sv` hangs under this host's current desk.
    pub fn shadowCurrent(self: *const Host, sv: *const ShadowVis) bool {
        return sv.visual != null and sv.desk_gen == self.desk_gen and self.shadow_root != null;
    }

    fn shadowSetOffset(sv: *ShadowVis, x: f32, y: f32) Error!void {
        if (x == sv.x and y == sv.y) return;
        const vis = sv.visual.?;
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_x)(vis, x));
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_y)(vis, y));
        sv.x = x;
        sv.y = y;
    }

    /// Take `sv` off the compositor and drop its references. Commits.
    pub fn shadowDrop(self: *Host, sv: *ShadowVis) void {
        const vis = sv.visual orelse return;
        if (self.shadowCurrent(sv)) {
            _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, self.shadow_root.?, slot_dcomp_visual_remove_visual)(self.shadow_root.?, vis);
            self.commit() catch {};
        }
        releaseShadow(sv);
    }

    /// Drop `sv`'s references without touching a tree: its host or desk is
    /// gone.
    pub fn releaseShadow(sv: *ShadowVis) void {
        if (sv.surface) |o| release(o);
        if (sv.effect) |o| release(o);
        if (sv.visual) |o| release(o);
        sv.* = .{};
    }

    /// The shadow riding with a pane placed at `(x, y)`, set in the same
    /// commit (`panePlace`).
    fn rideAt(self: *Host, ride: ?ShadowRide, x: f32, y: f32) Error!void {
        const r = ride orelse return;
        if (!self.shadowCurrent(r.sv)) return;
        stage = "shadow-ride";
        try shadowSetOffset(r.sv, x + r.dx, y + r.dy);
    }

    /// The shadow riding with a pane's glide (`paneGlide`): the same curve,
    /// offset by the ride's delta, so it moves with the card exactly.
    fn rideGlide(self: *Host, ride: ?ShadowRide, from: comp_tree.Pose, to: comp_tree.Pose, curve: []const Cubic, span_s: f64) Error!void {
        const r = ride orelse return;
        if (!self.shadowCurrent(r.sv)) return;
        stage = "shadow-glide";
        const vis = r.sv.visual.?;
        const SetAnim = *const fn (Obj, Obj) callconv(.winapi) HRESULT;
        const offsets = [2]struct { usize, f32, f32 }{
            .{ slot_dcomp_visual_set_offset_x - 1, from.x + r.dx, to.x + r.dx },
            .{ slot_dcomp_visual_set_offset_y - 1, from.y + r.dy, to.y + r.dy },
        };
        for (offsets) |o| {
            const anim = try self.followAnimation(o[1], o[2], curve, span_s);
            defer release(anim);
            try check(slot(SetAnim, vis, o[0])(vis, anim));
        }
        // Wherever the animation leaves it, the next static set must go out.
        r.sv.x = std.math.nan(f32);
        r.sv.y = std.math.nan(f32);
    }

    /// Wrap a pane renderer's composition surface handle in a visual of the
    /// pane layer, on top of the panes adopted before it. The caller owns
    /// the returned visual's reference and hands it back to `paneDrop`.
    /// Nothing is on screen until `panePlace` commits.
    pub fn paneAdopt(self: *Host, handle: *anyopaque) Error!Obj {
        const root = try self.ensurePaneRoot();
        stage = "pane-surface";
        var surface: ?Obj = null;
        try check(slot(*const fn (Obj, *anyopaque, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface_from_handle)(self.dcomp, handle, &surface));
        const surf = surface orelse return error.ComFailed;
        defer release(surf);
        stage = "pane-visual";
        const vis = try self.newVisual();
        errdefer release(vis);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, surf));
        // Start clipped to nothing, so the visual cannot flash at the origin
        // before its first placement.
        const none: D2D1_RECT_F = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        try check(slot(*const fn (Obj, *const D2D1_RECT_F) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_clip_rect)(vis, &none));
        // On top of the panes, under the faces (T2777): a face covers the
        // card it stands for whichever pane was adopted last.
        if (self.face_root) |faces| {
            try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, root, slot_dcomp_visual_add_visual)(root, vis, 0, faces));
        } else try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, root, slot_dcomp_visual_add_visual)(root, vis, 1, null));
        stage = "";
        self.pane_adopts +|= 1;
        log.info("pane visual adopted into the window tree (adopts={d})", .{self.pane_adopts});
        return vis;
    }

    /// Put a pane's visual at `(x, y)` in the client area, clipped to `c`
    /// (`comp_tree.clip`: its own pixels, the banner band above its origin
    /// included, cut to the pane's card shape), and commit. A rounded clip
    /// goes through a rectangle clip object kept in `rounded`, which the
    /// caller owns and hands to `releaseRef` with the visual; a plain one is
    /// the visual's own clip rect.
    pub fn panePlace(self: *Host, vis: Obj, x: i32, y: i32, c: comp_tree.Clip, rounded: *?Obj, ride: ?ShadowRide) Error!void {
        try self.rideAt(ride, @floatFromInt(x), @floatFromInt(y));
        stage = "pane-place";
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_x)(vis, @floatFromInt(x)));
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_y)(vis, @floatFromInt(y)));
        if (c.rounded()) {
            const rc = try self.paneClipObject(vis, c, rounded);
            const Set = *const fn (Obj, f32) callconv(.winapi) HRESULT;
            try check(slot(Set, rc, slot_dcomp_rect_clip_set_left)(rc, c.left));
            try check(slot(Set, rc, slot_dcomp_rect_clip_set_top)(rc, c.top));
            try check(slot(Set, rc, slot_dcomp_rect_clip_set_right)(rc, c.right));
            try check(slot(Set, rc, slot_dcomp_rect_clip_set_bottom)(rc, c.bottom));
        } else {
            const r: D2D1_RECT_F = .{ .left = c.left, .top = c.top, .right = c.right, .bottom = c.bottom };
            try check(slot(*const fn (Obj, *const D2D1_RECT_F) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_clip_rect)(vis, &r));
        }
        stage = "";
        try self.commit();
    }

    /// The pane's rectangle clip object (made once, kept in `rounded`), with
    /// `c`'s corner radii, set as `vis`'s clip. Its edges are the caller's.
    fn paneClipObject(self: *Host, vis: Obj, c: comp_tree.Clip, rounded: *?Obj) Error!Obj {
        stage = "pane-clip";
        if (rounded.* == null) {
            var made: ?Obj = null;
            try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_rectangle_clip)(self.dcomp, &made));
            rounded.* = made orelse return error.ComFailed;
        }
        const rc = rounded.*.?;
        const Set = *const fn (Obj, f32) callconv(.winapi) HRESULT;
        // TL x/y, TR x/y, BL x/y, BR x/y.
        const radii = [8]f32{ c.top_radius, c.top_radius, c.top_radius, c.top_radius, c.bottom_radius, c.bottom_radius, c.bottom_radius, c.bottom_radius };
        for (radii, 0..) |r, i| try check(slot(Set, rc, slot_dcomp_rect_clip_first_radius + 2 * i)(rc, r));
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_clip)(vis, rc));
        return rc;
    }

    /// A pane visual's whole stack glide, declared (T2572): its offset and
    /// clip go from `from` to `to` along `curve` (0..1 of the way, `span_s`
    /// long), on the compositor's clock, so the glide keeps moving while the
    /// window's thread is busy. A later `panePlace` or `paneGlide` replaces it.
    /// A clip that does not change is set, not animated.
    pub fn paneGlide(self: *Host, vis: Obj, from: comp_tree.Pose, to: comp_tree.Pose, curve: []const Cubic, span_s: f64, rounded: *?Obj, ride: ?ShadowRide) Error!void {
        defer stage = "";
        try self.rideGlide(ride, from, to, curve, span_s);
        stage = "pane-glide";
        const SetAnim = *const fn (Obj, Obj) callconv(.winapi) HRESULT;
        const offsets = [2]struct { usize, f32, f32 }{
            .{ slot_dcomp_visual_set_offset_x - 1, from.x, to.x },
            .{ slot_dcomp_visual_set_offset_y - 1, from.y, to.y },
        };
        for (offsets) |o| {
            const anim = try self.followAnimation(o[1], o[2], curve, span_s);
            defer release(anim);
            try check(slot(SetAnim, vis, o[0])(vis, anim));
        }
        if (std.meta.eql(from.clip, to.clip)) {
            // Its edges as `panePlace` sets them, without moving the offset.
            const c = to.clip;
            if (c.rounded()) {
                const rc = try self.paneClipObject(vis, c, rounded);
                const Set = *const fn (Obj, f32) callconv(.winapi) HRESULT;
                inline for (.{ slot_dcomp_rect_clip_set_left, slot_dcomp_rect_clip_set_top, slot_dcomp_rect_clip_set_right, slot_dcomp_rect_clip_set_bottom }, .{ "left", "top", "right", "bottom" }) |s, f| {
                    try check(slot(Set, rc, s)(rc, @field(c, f)));
                }
            } else {
                const r: D2D1_RECT_F = .{ .left = c.left, .top = c.top, .right = c.right, .bottom = c.bottom };
                try check(slot(*const fn (Obj, *const D2D1_RECT_F) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_clip_rect)(vis, &r));
            }
        } else {
            // A moving clip needs the clip object, whose edges take animations.
            const rc = try self.paneClipObject(vis, to.clip, rounded);
            inline for (.{ slot_dcomp_rect_clip_set_left, slot_dcomp_rect_clip_set_top, slot_dcomp_rect_clip_set_right, slot_dcomp_rect_clip_set_bottom }, .{ "left", "top", "right", "bottom" }) |s, f| {
                const anim = try self.followAnimation(@field(from.clip, f), @field(to.clip, f), curve, span_s);
                defer release(anim);
                try check(slot(SetAnim, rc, s - 1)(rc, anim));
            }
        }
        try self.commit();
    }

    /// An `IDCompositionAnimation` from `from` to `to` along `curve` (0..1
    /// of the way), holding `to` from `span_s` on. The caller releases it
    /// once it is set: the property keeps its own snapshot.
    fn followAnimation(self: *Host, from: f32, to: f32, curve: []const Cubic, span_s: f64) Error!Obj {
        return self.followAnimationHeld(from, to, curve, span_s, null, null);
    }

    /// A value held flat at `value` before (an enter) or from (a leave)
    /// `at_s` (`followAnimationHeld`).
    const Hold = struct { at_s: f64, value: f32 };

    /// `followAnimation`, held flat outside the stretch its straight line
    /// runs (T2778, T2779): at `enter.value` until `enter.at_s` - an unfold's
    /// fade rising in part-way - and at `leave.value` from `leave.at_s` on - a
    /// fold's fade reaching 0 before the card lands. The pieces the two
    /// times fall in are cut there (`comp_overlay.tailOf` re-expands the
    /// entering one about its time).
    fn followAnimationHeld(self: *Host, from: f32, to: f32, curve: []const Cubic, span_s: f64, enter: ?Hold, leave: ?Hold) Error!Obj {
        var made: ?Obj = null;
        try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_animation)(self.dcomp, &made));
        const anim = made orelse return error.ComFailed;
        errdefer release(anim);
        const add = slot(*const fn (Obj, f64, f32, f32, f32, f32) callconv(.winapi) HRESULT, anim, slot_dcomp_anim_add_cubic);
        const span: f64 = to - from;
        // A value that does not move still takes the same span, as one flat
        // piece.
        if (span == 0) try check(add(anim, 0, to, 0, 0, 0)) else {
            var pieces: []const Cubic = curve;
            var shift: f64 = 0;
            var tail: [2 * comp_overlay.follower_segments]Cubic = undefined;
            if (enter) |e| if (e.at_s > 0) {
                if (curve.len > tail.len) return error.ComFailed;
                try check(add(anim, 0, e.value, 0, 0, 0));
                // Never comes in: held the whole way.
                if (e.at_s >= span_s) {
                    try check(slot(*const fn (Obj, f64, f32) callconv(.winapi) HRESULT, anim, slot_dcomp_anim_end)(anim, span_s, e.value));
                    return anim;
                }
                pieces = comp_overlay.tailOf(curve, e.at_s, &tail);
                shift = e.at_s;
            };
            for (pieces) |c| {
                const begin = c.begin_s + shift;
                if (leave) |k| if (begin >= k.at_s) break;
                try check(add(anim, begin, @floatCast(from + span * c.c0), @floatCast(span * c.c1), @floatCast(span * c.c2), @floatCast(span * c.c3)));
            }
            if (leave) |k| if (k.at_s < span_s) try check(add(anim, @max(k.at_s, 0), k.value, 0, 0, 0));
        }
        try check(slot(*const fn (Obj, f64, f32) callconv(.winapi) HRESULT, anim, slot_dcomp_anim_end)(anim, span_s, if (leave) |k| k.value else to));
        return anim;
    }

    /// Drop a reference `panePlace` handed out (its rounded clip).
    pub fn releaseRef(obj: Obj) void {
        release(obj);
    }

    /// Take a pane's visual out of the layer and drop the caller's reference.
    pub fn paneDrop(self: *Host, vis: Obj) void {
        if (self.pane_root) |root| _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, root, slot_dcomp_visual_remove_visual)(root, vis);
        release(vis);
        self.commit() catch {};
    }

    /// Whether a folding card's face can be a picture in the pane layer
    /// (T2777): the layer exists - a pane has been adopted into the window's
    /// tree - and no face step has failed here.
    pub fn faceAvailable(self: *const Host) bool {
        return self.pane_root != null and !self.face_failed;
    }

    /// Whether `fv` hangs in this host's tree.
    pub fn faceCurrent(self: *const Host, fv: *const FaceVis) bool {
        return fv.visual != null and fv.epoch == self.rebuilds and self.face_root != null;
    }

    /// Put a face frame up as `fv`'s picture (T2777): `px` is the face's
    /// whole `cap_w` x `cap_h` DIB (the largest frame this glide can need),
    /// whose top-left `w` x `h` is this frame, shown at (`x`, `y`) in the
    /// client area, cut to `c` (its own pixels), at `opacity` (0..1). The
    /// surface is made at the DIB's size, so every narrower frame of the
    /// glide reuses it; a surface's first draw must cover all of it, so
    /// that one uploads the whole DIB. Commits, or leaves it to the batch.
    pub fn faceShow(self: *Host, fv: *FaceVis, px: []const u32, w: i32, h: i32, cap_w: i32, cap_h: i32, x: i32, y: i32, c: comp_tree.Clip, opacity: f32) Error!void {
        if (!self.faceAvailable()) return error.Unavailable;
        if (w <= 0 or h <= 0 or w > cap_w or h > cap_h) return error.ComFailed;
        if (px.len < @as(usize, @intCast(cap_w)) * @as(usize, @intCast(cap_h))) return error.ComFailed;
        errdefer self.face_failed = true;
        // Off a declared glide, back to one picture stepped from frames.
        if (fv.declared) self.faceUndeclare(fv);
        const vis = try self.ensureFaceVisual(fv);
        var whole = false;
        if (fv.surface == null or cap_w != fv.sw or cap_h != fv.sh) {
            stage = "face-surface";
            const sw = cap_w;
            const sh = cap_h;
            whole = true;
            if (fv.surface) |old| release(old);
            fv.surface = null;
            var surface: ?Obj = null;
            try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, @intCast(sw), @intCast(sh), DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &surface));
            const surf = surface orelse return error.ComFailed;
            errdefer release(surf);
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, surf));
            fv.surface = surf;
            fv.sw = sw;
            fv.sh = sh;
        }
        stage = "face-upload";
        try self.drawRect(fv.surface.?, px, cap_w, .{ .left = 0, .top = 0, .right = if (whole) cap_w else w, .bottom = if (whole) cap_h else h });
        stage = "face-place";
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_x)(vis, @floatFromInt(x)));
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_y)(vis, @floatFromInt(y)));
        // Never past this frame: the surface beyond it holds an older one.
        var cut = c;
        cut.left = @max(cut.left, 0);
        cut.top = @max(cut.top, 0);
        cut.right = @min(cut.right, @as(f32, @floatFromInt(w)));
        cut.bottom = @min(cut.bottom, @as(f32, @floatFromInt(h)));
        if (cut.rounded()) {
            const rc = try self.paneClipObject(vis, cut, &fv.clip);
            const Set = *const fn (Obj, f32) callconv(.winapi) HRESULT;
            inline for (.{ slot_dcomp_rect_clip_set_left, slot_dcomp_rect_clip_set_top, slot_dcomp_rect_clip_set_right, slot_dcomp_rect_clip_set_bottom }, .{ "left", "top", "right", "bottom" }) |s, f| {
                try check(slot(Set, rc, s)(rc, @field(cut, f)));
            }
        } else {
            const r: D2D1_RECT_F = .{ .left = cut.left, .top = cut.top, .right = cut.right, .bottom = cut.bottom };
            try check(slot(*const fn (Obj, *const D2D1_RECT_F) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_clip_rect)(vis, &r));
        }
        const o = std.math.clamp(opacity, 0, 1);
        if (o != fv.opacity) {
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, fv.effect.?, slot_dcomp_effect_set_opacity_float)(fv.effect.?, o));
            fv.opacity = o;
        }
        self.face_uploads +|= 1;
        stage = "";
        try self.commit();
    }

    /// Take `fv` off the compositor and drop its references. Commits, or
    /// leaves it to the batch.
    pub fn faceDrop(self: *Host, fv: *FaceVis) void {
        const vis = fv.visual orelse return;
        if (self.faceCurrent(fv)) {
            _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, self.face_root.?, slot_dcomp_visual_remove_visual)(self.face_root.?, vis);
            self.commit() catch {};
        }
        releaseFace(fv);
    }

    /// `fv`'s container in the face layer, made (with its opacity effect) on
    /// first use, or remade under a rebuilt host.
    fn ensureFaceVisual(self: *Host, fv: *FaceVis) Error!Obj {
        if (fv.visual != null and !self.faceCurrent(fv)) releaseFace(fv);
        if (fv.visual) |v| return v;
        const faces = try self.ensureFaceRoot();
        stage = "face-visual";
        const vis = try self.newVisual();
        errdefer release(vis);
        var e: ?Obj = null;
        try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_effect_group)(self.dcomp, &e));
        const effect = e orelse return error.ComFailed;
        errdefer release(effect);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_effect)(vis, effect));
        try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, faces, slot_dcomp_visual_add_visual)(faces, vis, 1, null));
        fv.* = .{ .visual = vis, .effect = effect, .epoch = self.rebuilds };
        return vis;
    }

    /// Take a declared face's three pictures off its container (T2778); the
    /// container's own picture is remade by the next `faceShow`.
    fn faceUndeclare(_: *Host, fv: *FaceVis) void {
        const vis = fv.visual orelse return;
        for ([_]*FaceLayer{ &fv.band, &fv.name, &fv.content }) |l| {
            if (l.visual) |kid| _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_remove_visual)(vis, kid);
            l.release_();
        }
        if (fv.content_effect) |o| release(o);
        fv.content_effect = null;
        fv.declared = false;
        // The animated clip goes with its object; `faceShow` sets a fresh one.
        if (fv.clip) |o| release(o);
        fv.clip = null;
        _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_clip)(vis, null);
    }

    /// One of a declared face's pictures: made under `parent` above `below`
    /// (null: as its first child) the first time, its surface remade for a
    /// new size, and all of `pic` uploaded - a new surface's first draw must
    /// cover it whole, and a declare is once a glide, not once a frame.
    fn faceLayer(self: *Host, l: *FaceLayer, parent: Obj, below: ?Obj, pic: FacePic) Error!Obj {
        if (l.visual == null) {
            const v = try self.newVisual();
            errdefer release(v);
            try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, parent, slot_dcomp_visual_add_visual)(parent, v, 1, below));
            l.visual = v;
        }
        const v = l.visual.?;
        if (pic.w <= 0 or pic.h <= 0) {
            _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, v, slot_dcomp_visual_set_content)(v, null);
            return v;
        }
        if (pic.px.len < @as(usize, @intCast(pic.stride)) * @as(usize, @intCast(pic.h - 1)) + @as(usize, @intCast(pic.w))) return error.ComFailed;
        if (l.surface == null or l.sw != pic.w or l.sh != pic.h) {
            if (l.surface) |old| release(old);
            l.surface = null;
            var surface: ?Obj = null;
            try check(slot(*const fn (Obj, u32, u32, u32, u32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_surface)(self.dcomp, @intCast(pic.w), @intCast(pic.h), DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &surface));
            l.surface = surface orelse return error.ComFailed;
            l.sw = pic.w;
            l.sh = pic.h;
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, v, slot_dcomp_visual_set_content)(v, l.surface.?));
        }
        try self.drawRect(l.surface.?, pic.px, pic.stride, .{ .left = 0, .top = 0, .right = pic.w, .bottom = pic.h });
        return v;
    }

    /// Hand a folding card's whole face to the compositor (T2778): the band,
    /// the name and the carried frame as three pictures under the face's
    /// container, the container cut to the card, and the card's edges, the
    /// frame's place, the name's place and the frame's strength all set
    /// running from `g.from` to `g.to` on the glide's follower - so the face
    /// keeps folding while the window's thread is busy. A later `faceShow`
    /// or `faceDeclare` replaces it. Commits, or leaves it to the batch.
    pub fn faceDeclare(self: *Host, fv: *FaceVis, g: FaceGlide) Error!void {
        if (!self.faceAvailable()) return error.Unavailable;
        errdefer self.face_failed = true;
        const vis = try self.ensureFaceVisual(fv);
        stage = "face-declare";
        defer stage = "";
        // The container is no picture now, at the client's origin, opaque:
        // its kids carry the face, and the clip is in client pixels.
        if (!fv.declared) {
            _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_content)(vis, null);
            if (fv.surface) |o| release(o);
            fv.surface = null;
            fv.sw = 0;
            fv.sh = 0;
        }
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_x)(vis, 0));
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, vis, slot_dcomp_visual_set_offset_y)(vis, 0));
        if (fv.opacity != 1) {
            try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, fv.effect.?, slot_dcomp_effect_set_opacity_float)(fv.effect.?, 1));
            fv.opacity = 1;
        }
        const band = try self.faceLayer(&fv.band, vis, null, g.band);
        const name = try self.faceLayer(&fv.name, vis, band, g.name orelse .{ .px = &.{}, .stride = 0, .w = 0, .h = 0 });
        const content = try self.faceLayer(&fv.content, vis, name, g.content);
        if (fv.content_effect == null) {
            var e: ?Obj = null;
            try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_effect_group)(self.dcomp, &e));
            fv.content_effect = e orelse return error.ComFailed;
            try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, content, slot_dcomp_visual_set_effect)(content, fv.content_effect.?));
        }
        fv.declared = true;
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, band, slot_dcomp_visual_set_offset_x)(band, @floatFromInt(g.band_x)));
        try check(slot(*const fn (Obj, f32) callconv(.winapi) HRESULT, band, slot_dcomp_visual_set_offset_y)(band, @floatFromInt(g.band_y)));
        const SetAnim = *const fn (Obj, Obj) callconv(.winapi) HRESULT;
        const moves = [4]struct { Obj, usize, f32, f32 }{
            .{ content, slot_dcomp_visual_set_offset_x - 1, g.from.content_x, g.to.content_x },
            .{ content, slot_dcomp_visual_set_offset_y - 1, g.from.content_y, g.to.content_y },
            .{ name, slot_dcomp_visual_set_offset_x - 1, g.from.name_x, g.to.name_x },
            .{ name, slot_dcomp_visual_set_offset_y - 1, g.from.name_y, g.to.name_y },
        };
        for (moves) |m| {
            const anim = try self.followAnimation(m[2], m[3], g.curve, g.span_s);
            defer release(anim);
            try check(slot(SetAnim, m[0], m[1])(m[0], anim));
        }
        // The card: the clip object, whose edges take animations.
        const rc = try self.paneClipObject(vis, g.to.clip, &fv.clip);
        inline for (.{ slot_dcomp_rect_clip_set_left, slot_dcomp_rect_clip_set_top, slot_dcomp_rect_clip_set_right, slot_dcomp_rect_clip_set_bottom }, .{ "left", "top", "right", "bottom" }) |s, f| {
            const anim = try self.followAnimation(@field(g.from.clip, f), @field(g.to.clip, f), g.curve, g.span_s);
            defer release(anim);
            try check(slot(SetAnim, rc, s - 1)(rc, anim));
        }
        const fade = try self.followAnimationHeld(
            g.from.opacity,
            g.to.opacity,
            g.curve,
            g.span_s,
            if (g.fade_enter_s) |e| .{ .at_s = e, .value = std.math.clamp(g.from.opacity, 0, 1) } else null,
            if (g.fade_leave_s) |k| .{ .at_s = k, .value = std.math.clamp(g.to.opacity, 0, 1) } else null,
        );
        defer release(fade);
        try check(slot(SetAnim, fv.content_effect.?, slot_dcomp_effect_set_opacity_anim)(fv.content_effect.?, fade));
        self.face_uploads +|= 1;
        try self.commit();
    }

    /// Drop `fv`'s references without touching a tree: its host is gone.
    pub fn releaseFace(fv: *FaceVis) void {
        for ([_]*FaceLayer{ &fv.band, &fv.name, &fv.content }) |l| l.release_();
        if (fv.content_effect) |o| release(o);
        if (fv.clip) |o| release(o);
        if (fv.surface) |o| release(o);
        if (fv.effect) |o| release(o);
        if (fv.visual) |o| release(o);
        fv.* = .{};
    }

    fn ensureFaceRoot(self: *Host) Error!Obj {
        if (self.face_root) |r| return r;
        const root = try self.ensurePaneRoot();
        stage = "face-root";
        const faces = try self.newVisual();
        errdefer release(faces);
        // Over every pane visual already in the layer.
        try check(slot(*const fn (Obj, Obj, i32, ?Obj) callconv(.winapi) HRESULT, root, slot_dcomp_visual_add_visual)(root, faces, 1, null));
        self.face_root = faces;
        return faces;
    }

    fn ensurePaneRoot(self: *Host) Error!Obj {
        if (self.pane_root) |r| return r;
        if (self.pane_target == null) {
            stage = "pane-target";
            var target: ?Obj = null;
            // topmost=TRUE: over the pane child windows, whose own pixels
            // are then never seen - they stay for input only.
            try check(slot(*const fn (Obj, HWND, i32, *?Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_create_target)(self.dcomp, self.hwnd, 1, &target));
            self.pane_target = target orelse return error.ComFailed;
        }
        stage = "pane-root";
        const root = try self.newVisual();
        errdefer release(root);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.pane_target.?, slot_dcomp_target_set_root)(self.pane_target.?, root));
        self.pane_root = root;
        return root;
    }

    /// Take the desk off the compositor: the window's own pixels show again
    /// in the same commit.
    /// The caption band goes with it: it lives only above the desk.
    pub fn deskHide(self: *Host) void {
        if (self.desk_visual == null) return;
        const had_cap = self.cap_visual != null;
        const had_ovl = self.ovl_visual != null;
        // Without a redirection surface the backstop stays: it is all the
        // window has under the panes now (T2548).
        if (self.base_visual) |base| {
            if (self.root_visual) |root| _ = slot(*const fn (Obj, Obj) callconv(.winapi) HRESULT, base, slot_dcomp_visual_remove_visual)(base, root);
        } else _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, null);
        _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp);
        self.commit_pending = false;
        self.releaseDesk();
        if (had_cap) log.info("chrome caption visual detached", .{});
        if (had_ovl) log.info("chrome overlay visual detached", .{});
        log.info("chrome desk visual detached", .{});
    }

    fn releaseDesk(self: *Host) void {
        if (self.shadow_root) |r| release(r);
        self.shadow_root = null;
        self.releaseCap();
        self.releaseOvl();
        for (&self.glows) |*g| releaseGlow(g);
        self.releaseHeroSlide(null);
        if (self.root_visual) |r| release(r);
        self.root_visual = null;
        if (self.desk_surface) |s| release(s);
        if (self.desk_visual) |v| release(v);
        self.desk_surface = null;
        self.desk_visual = null;
        self.desk_w = 0;
        self.desk_h = 0;
    }

    /// Whether the device under this host is gone, and why. Cheap: two
    /// vtable calls, so it runs on every paint.
    pub fn lostReason(self: *Host) ?Loss {
        if (self.force_loss) {
            self.force_loss = false;
            return .simulated;
        }
        const removed = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.device, slot_d3d11_device_get_removed_reason)(self.device);
        if (removed < 0) return .d3d_removed;
        var valid: i32 = 1;
        const hr = slot(*const fn (Obj, *i32) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_check_state)(self.dcomp, &valid);
        if (hr < 0 or valid == 0) return .dcomp_invalid;
        return null;
    }

    pub fn deinit(self: *Host) void {
        // Detach before the target goes, so the window falls back to its own
        // pixels in the same commit.
        _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, null);
        _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp);
        if (self.pane_target) |pt| {
            _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, pt, slot_dcomp_target_set_root)(pt, null);
            _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp);
        }
        if (self.face_root) |r| release(r);
        if (self.pane_root) |r| release(r);
        if (self.pane_target) |t| release(t);
        if (self.fill_visual) |v| release(v);
        if (self.fill_surface) |s| release(s);
        self.releaseDesk();
        if (self.backstop_visual) |v| release(v);
        if (self.backstop_surface) |s| release(s);
        if (self.base_visual) |v| release(v);
        release(self.target);
        release(self.dcomp);
        release(self.d2d);
        release(self.d2d_device);
        release(self.d2d_factory);
        release(self.context);
        release(self.device);
        self.* = undefined;
    }
};

/// Build a host for `hwnd` when the knob asks for one, logging the outcome
/// either way. Null means the window's chrome stays GDI. `backstop`
/// (0xRRGGBB) is for a window with no redirection surface (T2548): a host
/// that cannot put it up is no host, since that window would show whatever
/// is behind it wherever no visual reaches.
pub fn create(hwnd: HWND, rebuilds: u32, backstop: ?u32) ?Host {
    var host = Host.init(hwnd) catch {
        const f = Host.lastFailure();
        log.warn("chrome composition host unavailable at {s}: hr=0x{x:0>8}; chrome stays GDI", .{ f.stage, hex(f.hr) });
        return null;
    };
    if (backstop) |rgb| host.attachBackstop(rgb) catch {
        log.warn("chrome backstop failed at {s}: hr=0x{x:0>8}; no host", .{ stage, hex(last_hr) });
        host.deinit();
        return null;
    };
    host.rebuilds = rebuilds;
    // The loss seam fires on the first build only; a rebuilt host that read
    // it again would be lost again on every paint.
    if (rebuilds > 0) host.force_loss = false;
    log.info("chrome composition host ready: target_hr=0x{x:0>8} d2d_hr=0x{x:0>8} adapter={s} rebuilds={d}", .{
        hex(host.target_hr), hex(host.d2d_hr), host.adapter(), rebuilds,
    });
    return host;
}

/// Check `slot_host` for device loss and rebuild it in place when the device
/// went away. Called from the window's paint.
pub fn poll(slot_host: *?Host) void {
    if (slot_host.* == null) return;
    const h = &slot_host.*.?;
    const reason = h.lostReason() orelse return;
    const hwnd = h.hwnd;
    const next = h.rebuilds + 1;
    const backstop = h.backstop_rgb;
    log.warn("chrome composition device lost ({s}); rebuilding", .{reason.label()});
    h.deinit();
    slot_host.* = create(hwnd, next, backstop);
}

/// The backstop's colour: 0xRRGGBB, opaque.
fn rgbColor(rgb: u32) D2D1_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt((rgb >> 16) & 0xff)) / 255.0,
        .g = @as(f32, @floatFromInt((rgb >> 8) & 0xff)) / 255.0,
        .b = @as(f32, @floatFromInt(rgb & 0xff)) / 255.0,
        .a = 1,
    };
}

test "T2548: the window drops its redirection surface only with every piece that replaces it" {
    try std.testing.expect(noredirWanted(true, true, true, true));
    // Not asked: the default stays the redirected window.
    try std.testing.expect(!noredirWanted(false, true, true, true));
    // No chrome host: the caption and desk would be GDI, drawn into nothing.
    try std.testing.expect(!noredirWanted(true, false, true, true));
    // Panes on OpenGL child windows draw into the surface this removes.
    try std.testing.expect(!noredirWanted(true, true, false, true));
    // A translucent window blends against it.
    try std.testing.expect(!noredirWanted(true, true, true, false));
}

test "T2548: the backstop is the window background, opaque" {
    const c = rgbColor(0xff8000);
    try std.testing.expectEqual(@as(f32, 1), c.r);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), c.g, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), c.b);
    try std.testing.expectEqual(@as(f32, 1), c.a);
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(D2D_MATRIX_3X2_F));
}

test "knobOn accepts 1/true/on and nothing else" {
    try std.testing.expect(knobOn("1"));
    try std.testing.expect(knobOn(" On\r\n"));
    try std.testing.expect(knobOn("TRUE"));
    try std.testing.expect(!knobOn(null));
    try std.testing.expect(!knobOn(""));
    try std.testing.expect(!knobOn("0"));
    try std.testing.expect(!knobOn("off"));
}

test "D2D structs match the SDK layout" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(D2D1_BITMAP_PROPERTIES1));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(D2D1_COLOR_F));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(D2D1_RECT_F));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(D3D11_BOX));
}

test "T2543: a paint's clip reaches the caption band only where they overlap" {
    // A caption hover: the band's own rect, wider than any client.
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 800, .bottom = 40 }, bandDirty(.{ .left = 0, .top = 0, .right = 10000, .bottom = 40 }, 800, 40).?);
    // A paint straddling the band's bottom edge keeps only the band's part.
    try std.testing.expectEqual(Rect{ .left = 100, .top = 30, .right = 300, .bottom = 40 }, bandDirty(.{ .left = 100, .top = 30, .right = 300, .bottom = 400 }, 800, 40).?);
    // A desk-only paint below the band reaches none of it.
    try std.testing.expect(bandDirty(.{ .left = 0, .top = 40, .right = 800, .bottom = 600 }, 800, 40) == null);
    try std.testing.expect(bandDirty(.{ .left = 0, .top = 0, .right = 0, .bottom = 40 }, 800, 40) == null);
}

test "T2544: the overlay keeps what the painters drew over the desk, and a desk upload erases it" {
    var o: Overlay = .{};
    defer o.deinit();
    const desk_a: u32 = 0x00102030;
    const desk_b: u32 = 0x00405060;
    var src = [_]u32{desk_a} ** 16; // 4x4
    try o.deskUploaded(&src, 4, 4, null, true, &.{});
    try std.testing.expectEqual(@as(usize, 16), o.px.items.len);

    // A header painted over row 0: GDI writes alpha 0. One of its pixels
    // happens to be the desk's colour, which shows the same either way.
    var scratch = [_]u32{0xDEADBEEF} ** 16;
    const whole: Rect = .{ .left = 0, .top = 0, .right = 4, .bottom = 4 };
    o.prefill(&scratch, whole);
    try std.testing.expectEqual(desk_a, scratch[5]);
    scratch[0] = 0x00AABBCC;
    scratch[1] = 0x00AABBCC;
    scratch[2] = desk_a;
    o.merge(&scratch, whole);
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), o.px.items[0]);
    try std.testing.expectEqual(@as(u32, 0), o.px.items[2]);
    try std.testing.expectEqual(@as(u32, 0), o.px.items[5]);
    try std.testing.expectEqual(whole, o.takeDirty().?);
    try std.testing.expect(o.takeDirty() == null);

    // A pass that paints nothing keeps what was there: the prefill is the
    // screen, overlay included.
    o.prefill(&scratch, whole);
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), scratch[0]);
    o.merge(&scratch, whole);
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), o.px.items[1]);
    _ = o.takeDirty();

    // The desk uploads pixel 0's column (x 0, rows 0-1): the copy follows, the
    // overlay clears there and only there, and that is what goes up next.
    src[0] = desk_b;
    try o.deskUploaded(&src, 4, 4, &.{.{ .left = 0, .top = 0, .right = 1, .bottom = 2 }}, true, &.{});
    try std.testing.expectEqual(desk_b, o.desk.items[0]);
    try std.testing.expectEqual(@as(u32, 0), o.px.items[0]);
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), o.px.items[1]);
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 1, .bottom = 2 }, o.takeDirty().?);

    // A light frame's upload (no erase) moves the copy and leaves the overlay.
    src[1] = desk_b;
    try o.deskUploaded(&src, 4, 4, &.{.{ .left = 1, .top = 0, .right = 2, .bottom = 1 }}, false, &.{});
    try std.testing.expectEqual(desk_b, o.desk.items[1]);
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), o.px.items[1]);
    try std.testing.expect(o.takeDirty() == null);
}

test "T2544: an erase leaves the regions the desk's blit is clipped away from" {
    var o: Overlay = .{};
    defer o.deinit();
    var src = [_]u32{0} ** 16;
    try o.deskUploaded(&src, 4, 4, null, true, &.{});
    @memset(o.px.items, 0xFF112233);
    // A carousel in the right half: a whole-desk upload clears only the left.
    const keep = [_]Rect{.{ .left = 2, .top = 0, .right = 4, .bottom = 4 }};
    try o.deskUploaded(&src, 4, 4, null, true, &keep);
    try std.testing.expectEqual(@as(u32, 0), o.px.items[0]);
    try std.testing.expectEqual(@as(u32, 0), o.px.items[13]);
    try std.testing.expectEqual(@as(u32, 0xFF112233), o.px.items[2]);
    try std.testing.expectEqual(@as(u32, 0xFF112233), o.px.items[15]);
    // A new size starts the overlay over, clear.
    var big = [_]u32{0} ** 20;
    try o.deskUploaded(&big, 5, 4, null, true, &keep);
    for (o.px.items) |p| try std.testing.expectEqual(@as(u32, 0), p);
}

test "T2544: unite is the bounding box, either side optional" {
    const a: Rect = .{ .left = 0, .top = 5, .right = 10, .bottom = 6 };
    const b: Rect = .{ .left = 4, .top = 0, .right = 8, .bottom = 9 };
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 10, .bottom = 9 }, unite(a, b).?);
    try std.testing.expectEqual(a, unite(a, null).?);
    try std.testing.expectEqual(b, unite(null, b).?);
    try std.testing.expect(unite(null, null) == null);
}

test "T2545: the flat desk uploads only the rows that changed, as row bands" {
    var cur = [_]u32{0} ** 48; // 8x6
    var prev = [_]u32{0} ** 48;
    var out: [8]Rect = undefined;
    const whole: Rect = .{ .left = 0, .top = 0, .right = 8, .bottom = 6 };
    // Nothing changed: nothing to send.
    try std.testing.expectEqual(@as(usize, 0), diffRects(&cur, &prev, 8, 6, whole, &out).len);
    // Only the alpha byte changed (GDI's choice): nothing to send either.
    cur[9] = 0xFF00_0000;
    try std.testing.expectEqual(@as(usize, 0), diffRects(&cur, &prev, 8, 6, whole, &out).len);
    // A divider line at x 3, every row: one tall strip.
    for (0..6) |y| cur[y * 8 + 3] = 0x00808080;
    var rs = diffRects(&cur, &prev, 8, 6, whole, &out);
    try std.testing.expectEqual(@as(usize, 1), rs.len);
    try std.testing.expectEqual(Rect{ .left = 3, .top = 0, .right = 4, .bottom = 6 }, rs[0]);
    // A horizontal gutter across rows 2-3 as well: three bands.
    for (2..4) |y| for (0..8) |x| {
        cur[y * 8 + x] = 0x00202020;
    };
    rs = diffRects(&cur, &prev, 8, 6, whole, &out);
    try std.testing.expectEqual(@as(usize, 3), rs.len);
    try std.testing.expectEqual(Rect{ .left = 3, .top = 0, .right = 4, .bottom = 2 }, rs[0]);
    try std.testing.expectEqual(Rect{ .left = 0, .top = 2, .right = 8, .bottom = 4 }, rs[1]);
    try std.testing.expectEqual(Rect{ .left = 3, .top = 4, .right = 4, .bottom = 6 }, rs[2]);
    // Only inside the region asked about.
    rs = diffRects(&cur, &prev, 8, 6, .{ .left = 4, .top = 0, .right = 8, .bottom = 6 }, &out);
    try std.testing.expectEqual(@as(usize, 1), rs.len);
    try std.testing.expectEqual(Rect{ .left = 4, .top = 2, .right = 8, .bottom = 4 }, rs[0]);
    // Out of rectangles: the last one takes the rest.
    rs = diffRects(&cur, &prev, 8, 6, whole, out[0..2]);
    try std.testing.expectEqual(@as(usize, 2), rs.len);
    try std.testing.expectEqual(Rect{ .left = 0, .top = 2, .right = 8, .bottom = 6 }, rs[1]);
}

test "T2545: what the flat desk sent is what its shadow holds" {
    var f: FlatDesk = .{};
    defer f.deinit();
    // No DC off the box's GDI here: drive the buffers the way `ensure` sizes them.
    var px = [_]u32{0} ** 16;
    f.mirror.px = &px;
    f.mirror.w = 4;
    f.mirror.h = 4;
    try f.shadow.resize(FlatDesk.alloc, 16);
    @memset(f.shadow.items, 0);
    px[5] = 0x00112233;
    var out: [4]Rect = undefined;
    const rs = f.changed(.{ .left = 0, .top = 0, .right = 4, .bottom = 4 }, &out);
    try std.testing.expectEqual(@as(usize, 1), rs.len);
    try std.testing.expectEqual(Rect{ .left = 1, .top = 1, .right = 2, .bottom = 2 }, rs[0]);
    try std.testing.expectEqual(@as(u32, 0x00112233), f.shadow.items[5]);
    // Sent once: the same pass again has nothing to send.
    try std.testing.expectEqual(@as(usize, 0), f.changed(.{ .left = 0, .top = 0, .right = 4, .bottom = 4 }, &out).len);
    f.mirror = .{}; // not ours to free
}

test "loss labels name the cause" {
    try std.testing.expectEqualStrings("simulated (debug test hook)", Loss.simulated.label());
    try std.testing.expect(std.mem.indexOf(u8, Loss.d3d_removed.label(), "removed") != null);
}
