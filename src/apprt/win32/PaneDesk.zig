//! The HWND half of the elevated pane style (T1831): the window-owned
//! pixels around and between the pane cards - the gradient desk (the
//! "ocean", or the window's own variant - T1832), every card's
//! shadow, its antialiased corners and its rim - painted into the window's DC
//! in one `BitBlt`. The math is `pane_elevation.zig`; this owns the bitmaps.
//!
//! Two cached 32bpp DIB sections, both the size of the content area:
//!
//!   * `desk` - the gradient alone. Rendered at a quarter of the size and
//!     stretched (`HALFTONE`): the gradient has no detail to lose, and it is
//!     only redone when the size, the light/dark flavour or the window's
//!     variant changes.
//!   * `comp` - a copy of the desk with the cards painted on, rebuilt on
//!     every paint, because a divider drag moves the cards every frame.
//!
//! The window paints with `WS_CLIPCHILDREN`, so the blit only reaches the
//! pixels no pane child covers: the gutters, the margin, and the rounded
//! corners each child's window region gives back.
//!
//! On a translucent window (`background-opacity` below 1, T1852) a third,
//! `out`, holds what is actually blitted: `comp` premultiplied with the desk
//! at that opacity and every card, shadow and light at its own strength -
//! `comp` keeps each pixel's coverage in its alpha byte for exactly this
//! (`desk_palette.translucentPixel`). The blit then carries its own alpha,
//! which is why the window hands it a DC its marker pass does not resolve.
//!
//! A pane's progress light (T1899) is painted onto `comp` as well, from ring
//! caches kept here: a full paint rebuilds or rebases them and draws the
//! light, and an animation frame (`paintLightFrame`) redraws only the ring
//! pixels and blits only the four strips they lie in.

const PaneDesk = @This();

const std = @import("std");
const w32 = @import("win32.zig");
const pane_elevation = @import("pane_elevation.zig");
const desk_palette = @import("desk_palette.zig");
const busy_light = @import("busy_light.zig");
const color_math = @import("color_math.zig");

const log = std.log.scoped(.pane_desk);

/// The desk is rendered at 1/DESK_DOWNSCALE of the window and stretched.
const DESK_DOWNSCALE: usize = 4;

const Dib = struct {
    dc: w32.HDC,
    bmp: w32.HANDLE,
    old: ?*anyopaque,
    bits: [*]u32,
    w: i32,
    h: i32,

    fn create(w: i32, h: i32) ?Dib {
        const dc = w32.CreateCompatibleDC(null) orelse return null;
        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{ .bmiHeader = .{
            .biWidth = w,
            .biHeight = -h, // top-down
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = w32.BI_RGB,
        } };
        const bmp = w32.CreateDIBSection(dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = w32.DeleteDC(dc);
            return null;
        };
        const p = bits orelse {
            _ = w32.DeleteObject(bmp);
            _ = w32.DeleteDC(dc);
            return null;
        };
        return .{
            .dc = dc,
            .bmp = bmp,
            .old = w32.SelectObject(dc, bmp),
            .bits = @ptrCast(@alignCast(p)),
            .w = w,
            .h = h,
        };
    }

    fn destroy(self: Dib) void {
        _ = w32.SelectObject(self.dc, self.old);
        _ = w32.DeleteObject(self.bmp);
        _ = w32.DeleteDC(self.dc);
    }

    fn pixels(self: Dib) []u32 {
        return self.bits[0..@intCast(self.w * self.h)];
    }
};

/// One pane's progress light, as the window hands it over (T1899). `key`
/// identifies the pane across paints (its address; compared, never
/// dereferenced); `card` is in content-area pixels.
pub const Light = struct {
    key: usize,
    card: pane_elevation.Card,
    shape: busy_light.Shape,
    color: color_math.Rgb,
};

/// More busy panes than this in one tab are drawn without a light; a grid
/// that big has no room for one to read anyway.
pub const MAX_LIGHTS: usize = 16;

/// A light's ring, cached for the geometry it was built for.
const LightCache = struct {
    key: usize = 0,
    card: pane_elevation.Card = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    shape: busy_light.Shape = .ring,
    color: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    scale: f32 = 0,
    /// The buffer size the ring's indices are for; 0 = not built.
    w: i32 = 0,
    h: i32 = 0,
    px: std.ArrayListUnmanaged(busy_light.RingPx) = .empty,

    fn sameGeometry(self: *const LightCache, l: Light, scale: f32, w: i32, h: i32) bool {
        return self.w == w and self.h == h and self.scale == scale and
            std.meta.eql(self.card, l.card) and std.meta.eql(self.shape, l.shape);
    }
};

const light_alloc = std.heap.page_allocator;

lights: [MAX_LIGHTS]LightCache = [_]LightCache{.{}} ** MAX_LIGHTS,
light_n: usize = 0,

desk: ?Dib = null,
desk_light: bool = false,
desk_variant: ?desk_palette.Variant = null,
/// Bumped whenever `desk` is re-rendered, so a cache built from it (the
/// pane sidebar's, T1850) can tell it is stale without comparing pixels.
desk_gen: u32 = 0,
comp: ?Dib = null,
/// `comp` as a translucent window shows it (T1852); only ever created there.
out: ?Dib = null,

/// The gradient alone, as the pane sidebar paints under itself (T1850): the
/// desk runs under the sidebar's column, and the sidebar is a child window
/// the window's own blit never reaches.
pub const Backdrop = struct {
    dc: w32.HDC,
    pixels: []const u32,
    w: i32,
    h: i32,
    gen: u32,
};

/// The desk for a `w` x `h` content area, rendering it if it is not cached.
/// The same bitmap the window's paint uses, so the two cannot disagree.
pub fn backdrop(self: *PaneDesk, w: i32, h: i32, is_light: bool, variant: ?desk_palette.Variant) ?Backdrop {
    if (w <= 0 or h <= 0) return null;
    const d = self.ensureDesk(w, h, is_light, variant) orelse return null;
    return .{ .dc = d.dc, .pixels = d.pixels(), .w = d.w, .h = d.h, .gen = self.desk_gen };
}

pub fn deinit(self: *PaneDesk) void {
    for (&self.lights) |*c| c.px.deinit(light_alloc);
    if (self.desk) |d| d.destroy();
    if (self.comp) |c| c.destroy();
    if (self.out) |o| o.destroy();
    // Keep counting across a reset, so no later desk reuses a generation a
    // sidebar cache may still hold.
    self.* = .{ .desk_gen = self.desk_gen +% 1 };
}

/// Paint the desk and `cards` (in content-area pixels, i.e. relative to
/// `origin_x`/`origin_y`) into `hdc` over a `w` x `h` content area.
pub fn paint(
    self: *PaneDesk,
    hdc: w32.HDC,
    origin_x: i32,
    origin_y: i32,
    w: i32,
    h: i32,
    cards: []const pane_elevation.Card,
    style: pane_elevation.CardStyle,
    variant: ?desk_palette.Variant,
    lights: []const Light,
    head: f32,
    /// `background-opacity` as a byte when the window is translucent, null
    /// when it is opaque (T1852).
    opacity: ?u8,
) void {
    if (w <= 0 or h <= 0) return;
    const desk = self.ensureDesk(w, h, style.is_light, variant) orelse return;
    const comp = self.ensureComp(w, h) orelse return;
    @memcpy(comp.pixels(), desk.pixels());
    pane_elevation.paintCards(comp.pixels(), @intCast(w), @intCast(h), cards, style);
    self.syncLights(comp, lights, style.scale);
    for (self.lights[0..self.light_n]) |*c| busy_light.apply(comp.pixels(), c.px.items, c.shape, c.color, head);
    if (opacity) |o| {
        const out = self.ensureOut(w, h) orelse return;
        desk_palette.translucentSpan(out.pixels(), comp.pixels(), desk.pixels(), o);
        _ = w32.BitBlt(hdc, origin_x, origin_y, w, h, out.dc, 0, 0, w32.SRCCOPY);
        return;
    }
    _ = w32.BitBlt(hdc, origin_x, origin_y, w, h, comp.dc, 0, 0, w32.SRCCOPY);
}

/// Match the ring caches to `lights` - keeping the ring of a pane whose
/// card has not moved, rebuilding the rest - and re-read the light-free
/// pixels under every ring from `comp`, which was just repainted without
/// them.
fn syncLights(self: *PaneDesk, comp: Dib, lights: []const Light, scale: f32) void {
    const n = @min(lights.len, MAX_LIGHTS);
    var next: [MAX_LIGHTS]LightCache = [_]LightCache{.{}} ** MAX_LIGHTS;
    var claimed = [_]bool{false} ** MAX_LIGHTS;
    var placed = [_]bool{false} ** MAX_LIGHTS;
    // A pane that already had a light keeps its own cache...
    for (lights[0..n], 0..) |l, i| {
        for (self.lights[0..self.light_n], 0..) |c, j| {
            if (claimed[j] or c.key != l.key) continue;
            next[i] = c;
            claimed[j] = true;
            placed[i] = true;
            break;
        }
    }
    // ...a new one reuses a retired cache's buffer, invalidated...
    var spare: usize = 0;
    for (0..n) |i| {
        if (placed[i]) continue;
        while (spare < self.light_n and claimed[spare]) spare += 1;
        if (spare < self.light_n) {
            next[i] = self.lights[spare];
            claimed[spare] = true;
        }
        next[i].w = 0;
    }
    // ...and what nobody took is freed.
    for (self.lights[0..self.light_n], 0..) |*c, j| {
        if (!claimed[j]) c.px.deinit(light_alloc);
    }
    for (lights[0..n], 0..) |l, i| {
        const c = &next[i];
        c.key = l.key;
        c.color = l.color;
        if (!c.sameGeometry(l, scale, comp.w, comp.h)) {
            c.card = l.card;
            c.shape = l.shape;
            c.scale = scale;
            c.w = comp.w;
            c.h = comp.h;
            busy_light.build(light_alloc, &c.px, comp.w, comp.h, l.card, l.shape, scale) catch {
                log.warn("busy light ring build failed", .{});
                c.px.clearRetainingCapacity();
                c.w = 0;
            };
        }
        busy_light.rebase(comp.pixels(), c.px.items);
    }
    self.lights = next;
    self.light_n = n;
}

/// One animation frame of every light (T1899): redraw the ring pixels over
/// their bases in `comp` and blit just the strips they lie in. The window's
/// `WS_CLIPCHILDREN` DC keeps the blit off the panes. A no-op until a full
/// paint has built the caches for the current size.
pub fn paintLightFrame(self: *PaneDesk, hdc: w32.HDC, origin_x: i32, origin_y: i32, head: f32, opacity: ?u8) void {
    const comp = self.comp orelse return;
    // Translucent (T1852): each strip is re-premultiplied into `out` first,
    // from the desk the last full paint used.
    const tr: ?struct { out: Dib, desk: Dib, o: u8 } = if (opacity) |o| blk: {
        const out = self.out orelse return;
        const desk = self.desk orelse return;
        if (out.w != comp.w or out.h != comp.h or desk.w != comp.w or desk.h != comp.h) return;
        break :blk .{ .out = out, .desk = desk, .o = o };
    } else null;
    for (self.lights[0..self.light_n]) |*c| {
        if (c.w != comp.w or c.h != comp.h) continue;
        busy_light.apply(comp.pixels(), c.px.items, c.shape, c.color, head);
        for (busy_light.strips(c.card, c.shape, c.scale, comp.w, comp.h)) |r| {
            if (r.right <= r.left or r.bottom <= r.top) continue;
            const src = if (tr) |t| src: {
                const cw: usize = @intCast(comp.w);
                var y = r.top;
                while (y < r.bottom) : (y += 1) {
                    const a: usize = @as(usize, @intCast(y)) * cw + @as(usize, @intCast(r.left));
                    const b: usize = a + @as(usize, @intCast(r.right - r.left));
                    desk_palette.translucentSpan(t.out.pixels()[a..b], comp.pixels()[a..b], t.desk.pixels()[a..b], t.o);
                }
                break :src t.out.dc;
            } else comp.dc;
            _ = w32.BitBlt(hdc, origin_x + r.left, origin_y + r.top, r.right - r.left, r.bottom - r.top, src, r.left, r.top, w32.SRCCOPY);
        }
    }
}

/// How many lights the last full paint drew.
pub fn lightCount(self: *const PaneDesk) usize {
    return self.light_n;
}

/// The smallest content-area rectangle holding every light's strips, or
/// null with no light: what a frame's clip is narrowed to.
pub fn lightBounds(self: *const PaneDesk) ?busy_light.Rect {
    const comp = self.comp orelse return null;
    var out: ?busy_light.Rect = null;
    for (self.lights[0..self.light_n]) |*c| {
        for (busy_light.strips(c.card, c.shape, c.scale, comp.w, comp.h)) |r| {
            if (r.right <= r.left or r.bottom <= r.top) continue;
            out = if (out) |o| .{
                .left = @min(o.left, r.left),
                .top = @min(o.top, r.top),
                .right = @max(o.right, r.right),
                .bottom = @max(o.bottom, r.bottom),
            } else r;
        }
    }
    return out;
}

fn ensureComp(self: *PaneDesk, w: i32, h: i32) ?Dib {
    if (self.comp) |c| {
        if (c.w == w and c.h == h) return c;
        c.destroy();
        self.comp = null;
    }
    self.comp = Dib.create(w, h);
    return self.comp;
}

fn ensureOut(self: *PaneDesk, w: i32, h: i32) ?Dib {
    if (self.out) |o| {
        if (o.w == w and o.h == h) return o;
        o.destroy();
        self.out = null;
    }
    self.out = Dib.create(w, h);
    return self.out;
}

fn ensureDesk(self: *PaneDesk, w: i32, h: i32, is_light: bool, variant: ?desk_palette.Variant) ?Dib {
    if (self.desk) |d| {
        if (d.w == w and d.h == h and self.desk_light == is_light and
            std.meta.eql(self.desk_variant, variant)) return d;
        d.destroy();
        self.desk = null;
    }
    const full = Dib.create(w, h) orelse return null;

    const sw: usize = @max(@as(usize, @intCast(w)) / DESK_DOWNSCALE, 1) + 1;
    const sh: usize = @max(@as(usize, @intCast(h)) / DESK_DOWNSCALE, 1) + 1;
    const small = std.heap.page_allocator.alloc(u32, sw * sh) catch {
        full.destroy();
        return null;
    };
    defer std.heap.page_allocator.free(small);
    desk_palette.renderDesk(
        small,
        sw,
        sh,
        @floatFromInt(w),
        @floatFromInt(h),
        desk_palette.Palette.forWindow(variant, is_light),
    );
    const bmi = w32.BITMAPINFO{ .bmiHeader = .{
        .biWidth = @intCast(sw),
        .biHeight = -@as(i32, @intCast(sh)),
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = w32.BI_RGB,
    } };
    _ = w32.SetStretchBltMode(full.dc, w32.HALFTONE);
    _ = w32.SetBrushOrgEx(full.dc, 0, 0, null);
    if (w32.StretchDIBits(
        full.dc,
        0,
        0,
        w,
        h,
        0,
        0,
        @intCast(sw),
        @intCast(sh),
        small.ptr,
        &bmi,
        w32.DIB_RGB_COLORS,
        w32.SRCCOPY,
    ) == 0) log.warn("desk stretch failed {d}x{d}", .{ w, h });
    // GDI may leave the alpha byte of a stretched pixel non-zero; the paint
    // is `SRCCOPY` into an opaque window, but a per-pixel-alpha window would
    // read it, so keep the buffer's contract (0x00RRGGBB) exact.
    for (full.pixels()) |*p| p.* &= 0x00FF_FFFF;
    self.desk_gen +%= 1;
    self.desk = full;
    self.desk_light = is_light;
    self.desk_variant = variant;
    return full;
}
