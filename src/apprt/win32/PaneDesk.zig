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
//!   * `comp` - a copy of the desk with the cards painted on. A divider drag
//!     moves cards every frame, but only the ones beside the divider: a paint
//!     composes again just the rectangle the moved cards, strips and bar
//!     reach, where they were and where they are (T2454), and the whole
//!     buffer only when the size, the desk or the style changed.
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
const pane_stack_strip = @import("pane_stack_strip.zig");
const blade_shadow = @import("blade_shadow.zig");
const gutter_bar = @import("gutter_bar.zig");

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

/// A hovered or dragged gutter's accent bar (T2253), its core in
/// content-area pixels.
pub const Bar = struct {
    core: gutter_bar.Rect,
    color: color_math.Rgb,
    strength: gutter_bar.Strength,
};

/// More busy panes than this in one tab are drawn without a light; a grid
/// that big has no room for one to read anyway.
pub const MAX_LIGHTS: usize = 16;

/// The caller's hook for laying the strips' names into a paint (T2485).
pub const Names = struct {
    ctx: *anyopaque,
    /// Where the names may draw, in content-area pixels; nothing outside
    /// them is touched.
    rects: []const busy_light.Rect,
    /// Draws the names into `hdc` in window client coordinates.
    draw: *const fn (ctx: *anyopaque, hdc: w32.HDC) void,
};

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
/// What `comp` was last composed from (T2448), so a paint asked for the same
/// picture blits it instead of composing it again. The window composes on
/// every layout pass AND on the `WM_PAINT` that pass's invalidation queues,
/// so under a glide every frame used to compose the same desk twice - each
/// a full-window software pass, 28 ms of a 62 ms glide frame in a debug
/// build.
memo: Memo = .{},
/// Paints served from the memo / composed, since the window last read them.
memo_hits: u32 = 0,
memo_misses: u32 = 0,
/// Of the misses, those that composed only the rectangle that changed (T2454).
memo_partial: u32 = 0,
/// Time spent composing and blitting, since the window last read them
/// (T2454): what a glide frame's desk costs, split where it can be cut.
compose_ns: u64 = 0,
blit_ns: u64 = 0,
/// What the partial composes covered, in thousandths of the buffer, summed.
partial_permille: u64 = 0,
/// `composePartial`'s buffers, kept between paints: the rectangle being
/// composed, and the desk under it for a glass strip's band.
scratch: std.ArrayListUnmanaged(u32) = .empty,
scratch_desk: std.ArrayListUnmanaged(u32) = .empty,
/// Set by the window around a paint whose caller repaints only what moved
/// (a layout pass's or an animation's `GetDC` paint, T2454): a partial
/// compose then blits only what it composed, and the lights. Never set for
/// `WM_PAINT`, whose update region can reach anywhere.
blit_changed_only: bool = false,
/// What else such a paint blits (content-area pixels): the window's invalid
/// box at the time, which the caller validates afterwards.
also_blit: ?busy_light.Rect = null,
/// What the last paint put on the window when it was not the whole content
/// area (content-area pixels).
last_blit: ?Memo.Rects = null,
/// The tucked strips' names, laid into `comp` for the blit and lifted off it
/// after (T2485), so a band and its name reach the window in the same
/// `BitBlt`. Drawn after it, as their own GDI pass, the window could be
/// composited in between - and was, for frames at a time, while the panes
/// reflowed under a resting drag: every blade showed its band with no name.
/// Set by the caller around one `paint`; opaque windows only.
names: ?Names = null,
/// Whether the last `paint` laid `names` (the caller then draws none).
names_laid: bool = false,
names_saved: std.ArrayListUnmanaged(u32) = .empty,
/// The card style's shadow patch, built once for every compose of the style
/// rather than once a rectangle (T2454).
prepared: ?pane_elevation.Prepared = null,

/// Everything a compose reads besides the desk bitmap itself, held by value
/// and compared field by field: a byte compare of these structs would read
/// their padding, which is not the same twice.
const Memo = struct {
    const MAX_CARDS = 64;
    const MAX_STRIPS = 64;
    valid: bool = false,
    w: i32 = 0,
    h: i32 = 0,
    desk_gen: u32 = 0,
    cards: [MAX_CARDS]pane_elevation.Card = undefined,
    cards_len: usize = 0,
    strips: [MAX_STRIPS]pane_stack_strip.Band = undefined,
    strips_len: usize = 0,
    fill: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    is_light: bool = false,
    scale: f32 = 0,
    glass: bool = false,
    glows: [2]pane_elevation.Glow = undefined,
    glows_len: usize = 0,
    bar: ?Bar = null,
    lights: [MAX_LIGHTS]LightGeometry = undefined,
    lights_len: usize = 0,

    /// What a light's ring is built from; its colour and head are applied
    /// over the composed pixels every paint, so they are not part of it.
    const LightGeometry = struct { key: usize, card: pane_elevation.Card, shape: busy_light.Shape };

    fn matches(
        m: *const Memo,
        w: i32,
        h: i32,
        desk_gen: u32,
        cards: []const pane_elevation.Card,
        strips: []const pane_stack_strip.Band,
        style: pane_elevation.CardStyle,
        bar: ?Bar,
        lights: []const Light,
    ) bool {
        if (!m.valid or m.w != w or m.h != h or m.desk_gen != desk_gen) return false;
        if (m.cards_len != cards.len or m.strips_len != strips.len) return false;
        if (m.glows_len != style.glows.len or m.lights_len != @min(lights.len, MAX_LIGHTS)) return false;
        if (!std.meta.eql(m.fill, style.fill) or m.is_light != style.is_light or
            m.scale != style.scale or m.glass != style.glass) return false;
        if (!std.meta.eql(m.bar, bar)) return false;
        for (cards, m.cards[0..m.cards_len]) |a, b| if (!std.meta.eql(a, b)) return false;
        for (strips, m.strips[0..m.strips_len]) |a, b| if (!std.meta.eql(a, b)) return false;
        for (style.glows, m.glows[0..m.glows_len]) |a, b| if (!std.meta.eql(a, b)) return false;
        for (lights[0..m.lights_len], m.lights[0..m.lights_len]) |a, b| {
            if (a.key != b.key or !std.meta.eql(a.card, b.card) or !std.meta.eql(a.shape, b.shape)) return false;
        }
        return true;
    }

    /// What a compose for these inputs has to redo over the one remembered
    /// (T2454): `.full` when anything the whole picture depends on changed
    /// (the size, the desk, the style, how many cards or strips there are) or
    /// the change covers most of it anyway; otherwise the rectangles - clipped
    /// to the buffer, possibly none - holding every pixel a moved card, strip,
    /// glow or bar changed. Lights are not composed and so are not part of it.
    const Partial = union(enum) { full, rects: Rects };

    fn dirty(
        m: *const Memo,
        w: i32,
        h: i32,
        desk_gen: u32,
        cards: []const pane_elevation.Card,
        strips: []const pane_stack_strip.Band,
        style: pane_elevation.CardStyle,
        bar: ?Bar,
    ) Partial {
        if (!m.valid or m.w != w or m.h != h or m.desk_gen != desk_gen) return .full;
        if (m.cards_len != cards.len or m.strips_len != strips.len) return .full;
        if (!std.meta.eql(m.fill, style.fill) or m.is_light != style.is_light or
            m.scale != style.scale or m.glass != style.glass) return .full;
        var out: Rects = .{ .w = w, .h = h };
        const reach = reachPx(style.scale);
        const ri = pane_elevation.radiusPx(style.scale);
        const inner = pane_elevation.edgeInnerPx(style.scale);
        const old = m.cards[0..m.cards_len];
        for (cards, old) |a, b| if (!std.meta.eql(a, b)) out.addCard(b, a, ri, inner, reach);
        for (strips, m.strips[0..m.strips_len]) |a, b| if (!std.meta.eql(a, b)) out.addStrip(b, a, ri, inner, reach);
        const glows_same = m.glows_len == style.glows.len and for (style.glows, m.glows[0..m.glows_len]) |a, b| {
            if (!std.meta.eql(a, b)) break false;
        } else true;
        if (!glows_same) {
            for (style.glows) |g| if (g.card < cards.len) {
                const c = cards[g.card];
                out.addAround(c.left, c.top, c.right, c.bottom, reach);
            };
            for (m.glows[0..m.glows_len]) |g| if (g.card < old.len) {
                const c = old[g.card];
                out.addAround(c.left, c.top, c.right, c.bottom, reach);
            };
        }
        if (!std.meta.eql(m.bar, bar)) {
            if (bar) |b| out.addAround(b.core.left, b.core.top, b.core.right, b.core.bottom, reach);
            if (m.bar) |b| out.addAround(b.core.left, b.core.top, b.core.right, b.core.bottom, reach);
        }
        // Past three quarters of the window, the scratch's two copies cost
        // more than composing in place saves.
        if (out.area() * 4 > @as(i64, w) * h * 3) return .full;
        return .{ .rects = out };
    }

    /// A few rectangles of a `w` x `h` buffer. They may overlap - each is
    /// composed whole, so a pixel two of them share is laid twice, the same
    /// both times - and two are merged only where their union costs little
    /// more than the pair.
    pub const Rects = struct {
        const MAX = 24;
        w: i32,
        h: i32,
        items: [MAX]busy_light.Rect = undefined,
        len: usize = 0,

        pub fn slice(self: *const Rects) []const busy_light.Rect {
            return self.items[0..self.len];
        }

        fn area(self: *const Rects) i64 {
            var a: i64 = 0;
            for (self.slice()) |r| a += areaOf(r);
            return a;
        }

        fn areaOf(r: busy_light.Rect) i64 {
            return @as(i64, r.right - r.left) * (r.bottom - r.top);
        }

        fn add(self: *Rects, l: i32, t: i32, rt: i32, bt: i32) void {
            var r: busy_light.Rect = .{
                .left = std.math.clamp(l, 0, self.w),
                .top = std.math.clamp(t, 0, self.h),
                .right = std.math.clamp(rt, 0, self.w),
                .bottom = std.math.clamp(bt, 0, self.h),
            };
            if (r.right <= r.left or r.bottom <= r.top) return;
            var i: usize = 0;
            while (i < self.len) {
                const o = self.items[i];
                const u = unite(o, r);
                if (areaOf(u) * 4 <= (areaOf(o) + areaOf(r)) * 5) {
                    r = u;
                    self.len -= 1;
                    self.items[i] = self.items[self.len];
                    i = 0;
                } else i += 1;
            }
            if (self.len == MAX) {
                for (self.slice()) |o| r = unite(o, r);
                self.len = 0;
            }
            self.items[self.len] = r;
            self.len += 1;
        }

        fn addAround(self: *Rects, l: i32, t: i32, rt: i32, bt: i32, reach: i32) void {
            if (rt <= l or bt <= t) return;
            self.add(l - reach, t - reach, rt + reach, bt + reach);
        }

        /// What card `a` becoming `b` changed. Everything a compose lays for
        /// a card is a function of the distance to its nearest edge, and of
        /// nothing else once the card is big enough to keep its whole corner
        /// radius and its shadow's corner patch: then an edge that moved
        /// changes only a band from `inner` inside it to `reach` outside it,
        /// where it was and where it is - and a shadow strength that changed,
        /// only such a band round all four, since the shadow lies outside the
        /// card or under its fill. Anything else - a smaller card, a colour, a
        /// head band, a sheet - is the whole card, both places.
        fn addCard(self: *Rects, a: pane_elevation.Card, b: pane_elevation.Card, ri: i32, inner: i32, reach: i32) void {
            var same = a;
            same.left = b.left;
            same.top = b.top;
            same.right = b.right;
            same.bottom = b.bottom;
            same.shadow = b.shadow;
            const ok = std.meta.eql(same, b) and big(a.left, a.top, a.right, a.bottom, ri, reach) and
                big(b.left, b.top, b.right, b.bottom, ri, reach);
            if (!ok) {
                self.addAround(a.left, a.top, a.right, a.bottom, reach);
                self.addAround(b.left, b.top, b.right, b.bottom, reach);
                return;
            }
            self.addEdges(.{ a.left, a.top, a.right, a.bottom }, .{ b.left, b.top, b.right, b.bottom }, a.shadow != b.shadow, inner, reach);
        }

        /// What strip `a` becoming `b` changed. A card gliding into its strip
        /// (`band` false) lays only its blade shadow, outside its rect, so it
        /// is `addCard`'s case with the collapse for the shadow strength: the
        /// glide narrows the rect and deepens the shadow every frame. A strip
        /// at rest that changed is the whole strip, both places.
        fn addStrip(self: *Rects, a: pane_stack_strip.Band, b: pane_stack_strip.Band, ri: i32, inner: i32, reach: i32) void {
            const ta = a.tab;
            const tb = b.tab;
            const ok = !a.band and !b.band and a.axis == b.axis and
                big(ta.left, ta.top, ta.right, ta.bottom, ri, reach) and big(tb.left, tb.top, tb.right, tb.bottom, ri, reach);
            if (!ok) {
                self.addAround(ta.left, ta.top, ta.right, ta.bottom, reach);
                self.addAround(tb.left, tb.top, tb.right, tb.bottom, reach);
                return;
            }
            self.addEdges(.{ ta.left, ta.top, ta.right, ta.bottom }, .{ tb.left, tb.top, tb.right, tb.bottom }, a.collapse != b.collapse or a.leads != b.leads, inner, reach);
        }

        /// Big enough that its corners and its shadow's corner patch are the
        /// full-size ones, and its ends never meet (`addCard`).
        fn big(l: i32, t: i32, rt: i32, bt: i32, ri: i32, reach: i32) bool {
            const min_side = 2 * (ri + reach + 2);
            return rt - l >= min_side and bt - t >= min_side;
        }

        /// The bands round the edges of `a` (left, top, right, bottom) that
        /// moved to `b`'s, or round all four when `all`: each from `inner`
        /// inside the edge (`pane_elevation.edgeInnerPx`) to `reach` outside
        /// it, either place.
        fn addEdges(self: *Rects, a: [4]i32, b: [4]i32, all: bool, inner: i32, reach: i32) void {
            const l = @min(a[0], b[0]) - reach;
            const t = @min(a[1], b[1]) - reach;
            const rt = @max(a[2], b[2]) + reach;
            const bt = @max(a[3], b[3]) + reach;
            if (all or a[0] != b[0]) self.add(l, t, @max(a[0], b[0]) + inner, bt);
            if (all or a[2] != b[2]) self.add(@min(a[2], b[2]) - inner, t, rt, bt);
            if (all or a[1] != b[1]) self.add(l, t, rt, @max(a[1], b[1]) + inner);
            if (all or a[3] != b[3]) self.add(l, @min(a[3], b[3]) - inner, rt, bt);
        }

        fn unite(a: busy_light.Rect, b: busy_light.Rect) busy_light.Rect {
            return .{
                .left = @min(a.left, b.left),
                .top = @min(a.top, b.top),
                .right = @max(a.right, b.right),
                .bottom = @max(a.bottom, b.bottom),
            };
        }
    };

    /// Remember a compose's inputs; one that does not fit leaves the memo
    /// invalid, so an oversized grid composes every time as it always did.
    fn store(
        m: *Memo,
        w: i32,
        h: i32,
        desk_gen: u32,
        cards: []const pane_elevation.Card,
        strips: []const pane_stack_strip.Band,
        style: pane_elevation.CardStyle,
        bar: ?Bar,
        lights: []const Light,
    ) void {
        m.valid = false;
        if (cards.len > MAX_CARDS or strips.len > MAX_STRIPS or style.glows.len > m.glows.len) return;
        m.w = w;
        m.h = h;
        m.desk_gen = desk_gen;
        @memcpy(m.cards[0..cards.len], cards);
        m.cards_len = cards.len;
        @memcpy(m.strips[0..strips.len], strips);
        m.strips_len = strips.len;
        m.fill = style.fill;
        m.is_light = style.is_light;
        m.scale = style.scale;
        m.glass = style.glass;
        @memcpy(m.glows[0..style.glows.len], style.glows);
        m.glows_len = style.glows.len;
        m.bar = bar;
        const nl = @min(lights.len, MAX_LIGHTS);
        for (lights[0..nl], 0..) |l, i| m.lights[i] = .{ .key = l.key, .card = l.card, .shape = l.shape };
        m.lights_len = nl;
        m.valid = true;
    }
};

/// The gradient alone, as the pane sidebar paints under itself (T1850): the
/// desk runs under the sidebar's column, and the sidebar is a child window
/// the window's own blit never reaches.
pub const Backdrop = struct {
    dc: w32.HDC,
    pixels: []const u32,
    w: i32,
    h: i32,
    gen: u32,

    /// The same desk from row `rows` down: the content area's slice when
    /// the desk also runs up under a glass title bar (T1886). `dc` is the
    /// whole desk's and is not moved.
    pub fn below(self: Backdrop, rows: i32) ?Backdrop {
        if (rows <= 0) return self;
        if (rows >= self.h) return null;
        var out = self;
        out.pixels = self.pixels[@as(usize, @intCast(rows * self.w))..];
        out.h = self.h - rows;
        return out;
    }
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
    self.scratch.deinit(light_alloc);
    self.scratch_desk.deinit(light_alloc);
    self.names_saved.deinit(light_alloc);
    if (self.prepared) |*p| p.deinit();
    if (self.desk) |d| d.destroy();
    if (self.comp) |c| c.destroy();
    if (self.out) |o| o.destroy();
    // Keep counting across a reset, so no later desk reuses a generation a
    // sidebar cache may still hold.
    self.* = .{ .desk_gen = self.desk_gen +% 1 };
}

/// Paint the desk and `cards` (in content-area pixels, i.e. relative to
/// `origin_x`/`origin_y`) into `hdc` over a `w` x `h` content area.
var resize_trace_state: ?bool = null;

fn resizeTraceOn() bool {
    if (resize_trace_state) |v| return v;
    const v = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_RESIZE_TRACE");
    resize_trace_state = v;
    return v;
}

fn qpcFreq() i64 {
    var f: i64 = 0;
    _ = w32.QueryPerformanceFrequency(&f);
    return @max(f, 1);
}

pub fn paint(
    self: *PaneDesk,
    hdc: w32.HDC,
    origin_x: i32,
    origin_y: i32,
    w: i32,
    h: i32,
    cards: []const pane_elevation.Card,
    /// The strips of the panes tucked into a stack (T2121), bottom first:
    /// laid on the desk with their leading corners rounded like a card's,
    /// each after its blade shadow (T2307) - and a card gliding into or out
    /// of its strip as its shadow alone, at its place in that order.
    strips: []const pane_stack_strip.Band,
    style: pane_elevation.CardStyle,
    variant: ?desk_palette.Variant,
    lights: []const Light,
    head: f32,
    /// The one gutter bar on show, if any (T2253): over the desk and the
    /// strips, under the lights.
    bar: ?Bar,
    /// `background-opacity` as a byte when the window is translucent, null
    /// when it is opaque (T1852).
    opacity: ?u8,
) void {
    self.names_laid = false;
    if (w <= 0 or h <= 0) return;
    var tq0: i64 = 0;
    _ = w32.QueryPerformanceCounter(&tq0);
    const desk = self.ensureDesk(w, h, style.is_light, variant) orelse return;
    var tq1: i64 = 0;
    _ = w32.QueryPerformanceCounter(&tq1);
    const fresh = self.comp == null or self.comp.?.w != w or self.comp.?.h != h;
    const comp = self.ensureComp(w, h) orelse return;
    var tq2: i64 = 0;
    _ = w32.QueryPerformanceCounter(&tq2);
    // A new size is a whole new desk (T2516): what each part of that costs, on
    // every window-resize step, under `GHOZTTY_RESIZE_TRACE`.
    defer if (fresh and resizeTraceOn()) {
        var tq3: i64 = 0;
        _ = w32.QueryPerformanceCounter(&tq3);
        const f = qpcFreq();
        log.info("desk trace desk_us={d} comp_us={d} rest_us={d}", .{
            @divTrunc((tq1 - tq0) * 1_000_000, f),
            @divTrunc((tq2 - tq1) * 1_000_000, f),
            @divTrunc((tq3 - tq2) * 1_000_000, f),
        });
    };
    // The same picture as last time (T2448): the lights' rings are re-drawn
    // over their cached bases at this paint's head, and the composed pixels
    // under them are already right.
    if (!fresh and self.memo.matches(w, h, self.desk_gen, cards, strips, style, bar, lights)) {
        self.memo_hits +|= 1;
        for (self.lights[0..self.light_n], lights[0..self.light_n]) |*c, l| {
            c.color = l.color;
            busy_light.apply(comp.pixels(), c.px.items, c.shape, c.color, head);
        }
        self.last_blit = null;
        const laid = self.layNames(comp, origin_x, origin_y, opacity);
        defer if (laid) self.liftNames(comp);
        return self.timedBlit(hdc, origin_x, origin_y, w, h, comp, desk, opacity);
    }
    self.memo_misses +|= 1;
    var timer = std.time.Timer.start() catch null;
    // Only the cards, strips or bar that moved (T2454): what lies outside
    // their reach is the picture `comp` already holds, so the desk is copied
    // and the cards laid again over just that rectangle. A divider glide moves
    // the two cards beside it, not the whole row.
    const partial = if (!fresh) self.memo.dirty(w, h, self.desk_gen, cards, strips, style, bar) else .full;
    const prep = self.preparedFor(style);
    const done = switch (partial) {
        .full => false,
        .rects => |r| self.composePartial(comp, desk, r.slice(), cards, strips, style, bar, prep),
    };
    if (done) self.partial_permille +|= @intCast(@divFloor(partial.rects.area() * 1000, @as(i64, w) * h));
    if (done) self.memo_partial +|= 1 else compose(comp.pixels(), desk.pixels(), @intCast(w), @intCast(h), cards, strips, style, bar, prep);
    // What changed on the window, for a paint that blits only that: the
    // rectangles composed, and every light's ring before and after - one
    // going out was just lifted off `comp`, and every ring moves anyway.
    var shown: ?Memo.Rects = if (done and self.blit_changed_only) partial.rects else null;
    if (shown) |*sh| self.addLightStrips(sh, comp);
    self.syncLights(comp, lights, style.scale);
    for (self.lights[0..self.light_n]) |*c| busy_light.apply(comp.pixels(), c.px.items, c.shape, c.color, head);
    self.memo.store(w, h, self.desk_gen, cards, strips, style, bar, lights);
    if (timer) |*t| self.compose_ns +|= t.read();
    self.last_blit = null;
    const laid = self.layNames(comp, origin_x, origin_y, opacity);
    defer if (laid) self.liftNames(comp);
    if (shown) |*sh| {
        self.addLightStrips(sh, comp);
        if (self.also_blit) |r| sh.add(r.left, r.top, r.right, r.bottom);
        // Every name goes out with this paint: the window draws none itself.
        if (laid) for (self.names.?.rects) |r| sh.add(r.left, r.top, r.right, r.bottom);
        if (sh.area() * 4 <= @as(i64, w) * h * 3) {
            var timer2 = std.time.Timer.start() catch null;
            for (sh.slice()) |r| self.blitRect(hdc, origin_x, origin_y, comp, desk, opacity, r);
            if (timer2) |*t| self.blit_ns +|= t.read();
            self.last_blit = sh.*;
            return;
        }
    }
    self.timedBlit(hdc, origin_x, origin_y, w, h, comp, desk, opacity);
}

/// The strips every cached light's ring lies in, built for `comp`'s size.
fn addLightStrips(self: *const PaneDesk, rects: *Memo.Rects, comp: Dib) void {
    for (self.lights[0..self.light_n]) |*c| {
        if (c.w != comp.w or c.h != comp.h) continue;
        for (busy_light.strips(c.card, c.shape, c.scale, comp.w, comp.h)) |r| rects.add(r.left, r.top, r.right, r.bottom);
    }
}

/// One rectangle of `comp` onto the window, through `out` on a translucent
/// one (T2454).
fn blitRect(self: *PaneDesk, hdc: w32.HDC, origin_x: i32, origin_y: i32, comp: Dib, desk: Dib, opacity: ?u8, r: busy_light.Rect) void {
    if (r.right <= r.left or r.bottom <= r.top) return;
    const src = if (opacity) |o| src: {
        const out = self.ensureOut(comp.w, comp.h) orelse return;
        const cw: usize = @intCast(comp.w);
        var y = r.top;
        while (y < r.bottom) : (y += 1) {
            const a: usize = @as(usize, @intCast(y)) * cw + @as(usize, @intCast(r.left));
            const b: usize = a + @as(usize, @intCast(r.right - r.left));
            desk_palette.translucentSpan(out.pixels()[a..b], comp.pixels()[a..b], desk.pixels()[a..b], o);
        }
        break :src out.dc;
    } else comp.dc;
    _ = w32.BitBlt(hdc, origin_x + r.left, origin_y + r.top, r.right - r.left, r.bottom - r.top, src, r.left, r.top, w32.SRCCOPY);
}

fn timedBlit(self: *PaneDesk, hdc: w32.HDC, origin_x: i32, origin_y: i32, w: i32, h: i32, comp: Dib, desk: Dib, opacity: ?u8) void {
    var timer = std.time.Timer.start() catch null;
    self.blit(hdc, origin_x, origin_y, w, h, comp, desk, opacity);
    if (timer) |*t| self.blit_ns +|= t.read();
}

/// Lay `names` into `comp` for the blit (T2485), keeping what was under
/// them for `liftNames`. False - and the caller's own pass draws them - on a
/// translucent window, or when there is nothing to lay.
fn layNames(self: *PaneDesk, comp: Dib, origin_x: i32, origin_y: i32, opacity: ?u8) bool {
    const n = self.names orelse return false;
    if (opacity != null or n.rects.len == 0) return false;
    self.names_saved.clearRetainingCapacity();
    saveUnder(comp.pixels(), comp.w, comp.h, n.rects, &self.names_saved) catch return false;
    const rgn = w32.CreateRectRgn(0, 0, 0, 0) orelse return false;
    defer _ = w32.DeleteObject(rgn);
    for (n.rects) |r| {
        const c = clipTo(r, comp.w, comp.h) orelse continue;
        const one = w32.CreateRectRgn(c.left, c.top, c.right, c.bottom) orelse continue;
        _ = w32.CombineRgn(rgn, rgn, one, w32.RGN_OR);
        _ = w32.DeleteObject(one);
    }
    const saved = w32.SaveDC(comp.dc);
    _ = w32.SelectClipRgn(comp.dc, rgn);
    _ = w32.SetViewportOrgEx(comp.dc, -origin_x, -origin_y, null);
    n.draw(n.ctx, comp.dc);
    _ = w32.RestoreDC(comp.dc, saved);
    // The text is in the pixels before anything reads them.
    _ = w32.GdiFlush();
    self.names_laid = true;
    return true;
}

/// Put back what `layNames` drew over, once the blit has read it: `comp` is
/// the cached picture, and the names are not part of it.
fn liftNames(self: *PaneDesk, comp: Dib) void {
    _ = w32.GdiFlush();
    const n = self.names orelse return;
    restoreUnder(comp.pixels(), comp.w, comp.h, n.rects, self.names_saved.items);
}

/// Lay the composed desk under the panes (T2485 A2): `rects` in the desk's
/// own pixels, through a DC that does not clip them away. A layered pane is
/// composed over the window, so nothing here shows while it stands there;
/// what it holds is what the strip a moving pane leaves shows until the next
/// paint reaches it - the desk, rather than pixels nothing ever painted.
pub fn blitUnder(self: *PaneDesk, hdc: w32.HDC, origin_x: i32, origin_y: i32, rects: []const busy_light.Rect) void {
    const comp = self.comp orelse return;
    var timer = std.time.Timer.start() catch null;
    for (rects) |r| {
        const c = clipTo(r, comp.w, comp.h) orelse continue;
        _ = w32.BitBlt(hdc, origin_x + c.left, origin_y + c.top, c.right - c.left, c.bottom - c.top, comp.dc, c.left, c.top, w32.SRCCOPY);
    }
    if (timer) |*t| self.blit_ns +|= t.read();
}

fn clipTo(r: busy_light.Rect, w: i32, h: i32) ?busy_light.Rect {
    const c: busy_light.Rect = .{
        .left = std.math.clamp(r.left, 0, w),
        .top = std.math.clamp(r.top, 0, h),
        .right = std.math.clamp(r.right, 0, w),
        .bottom = std.math.clamp(r.bottom, 0, h),
    };
    if (c.right <= c.left or c.bottom <= c.top) return null;
    return c;
}

/// Append the pixels of `buf` (`w` x `h`) under each of `rects`, in order.
fn saveUnder(buf: []const u32, w: i32, h: i32, rects: []const busy_light.Rect, out: *std.ArrayListUnmanaged(u32)) !void {
    const stride: usize = @intCast(w);
    for (rects) |r| {
        const c = clipTo(r, w, h) orelse continue;
        const rw: usize = @intCast(c.right - c.left);
        var y: usize = @intCast(c.top);
        while (y < c.bottom) : (y += 1) {
            const a = y * stride + @as(usize, @intCast(c.left));
            try out.appendSlice(light_alloc, buf[a..][0..rw]);
        }
    }
}

/// Undo `saveUnder` over the same `rects`, last first, so where two overlap
/// the pixels from before either was drawn are the ones that stay.
fn restoreUnder(buf: []u32, w: i32, h: i32, rects: []const busy_light.Rect, saved: []const u32) void {
    const stride: usize = @intCast(w);
    var end: usize = saved.len;
    var i: usize = rects.len;
    while (i > 0) {
        i -= 1;
        const c = clipTo(rects[i], w, h) orelse continue;
        const rw: usize = @intCast(c.right - c.left);
        const rh: usize = @intCast(c.bottom - c.top);
        if (end < rw * rh) return;
        var at = end - rw * rh;
        end = at;
        var y: usize = @intCast(c.top);
        while (y < c.bottom) : (y += 1) {
            const a = y * stride + @as(usize, @intCast(c.left));
            @memcpy(buf[a..][0..rw], saved[at..][0..rw]);
            at += rw;
        }
    }
}

test "a name laid for the blit is lifted off the cached picture, overlaps and edges included" {
    const w: i32 = 8;
    const h: i32 = 6;
    var buf: [48]u32 = undefined;
    for (&buf, 0..) |*p, i| p.* = @intCast(i);
    const orig = buf;
    // Two overlapping strips and one hanging off the right and bottom edges.
    const rects = [_]busy_light.Rect{
        .{ .left = 1, .top = 0, .right = 3, .bottom = 6 },
        .{ .left = 2, .top = 1, .right = 5, .bottom = 4 },
        .{ .left = 6, .top = 4, .right = 12, .bottom = 9 },
    };
    var saved: std.ArrayListUnmanaged(u32) = .empty;
    defer saved.deinit(light_alloc);
    try saveUnder(&buf, w, h, &rects, &saved);
    try std.testing.expectEqual(@as(usize, 12 + 9 + 4), saved.items.len);
    // "Draw" over every rect.
    for (rects) |r| {
        const c = clipTo(r, w, h).?;
        var y = c.top;
        while (y < c.bottom) : (y += 1) {
            var x = c.left;
            while (x < c.right) : (x += 1) buf[@intCast(y * w + x)] = 0xFFFF_FFFF;
        }
    }
    restoreUnder(&buf, w, h, &rects, saved.items);
    try std.testing.expectEqualSlices(u32, &orig, &buf);
}

test "a name rect wholly outside the picture saves nothing and restores nothing" {
    var buf = [_]u32{ 1, 2, 3, 4 };
    const rects = [_]busy_light.Rect{.{ .left = 5, .top = 0, .right = 9, .bottom = 2 }};
    var saved: std.ArrayListUnmanaged(u32) = .empty;
    defer saved.deinit(light_alloc);
    try saveUnder(&buf, 2, 2, &rects, &saved);
    try std.testing.expectEqual(@as(usize, 0), saved.items.len);
    restoreUnder(&buf, 2, 2, &rects, saved.items);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4 }, &buf);
}

/// Lay `cards`, `strips` and `bar` over `buf`, which holds the desk `desk`
/// (both `w` x `h`). Everything is positioned by its own geometry alone, so a
/// window of the buffer composes the same pixels when that geometry is moved
/// into it (`composePartial`).
fn compose(
    buf: []u32,
    desk: []const u32,
    w: usize,
    h: usize,
    cards: []const pane_elevation.Card,
    strips: []const pane_stack_strip.Band,
    style: pane_elevation.CardStyle,
    bar: ?Bar,
    prep: ?*const pane_elevation.Prepared,
) void {
    @memcpy(buf[0 .. w * h], desk[0 .. w * h]);
    composeOver(buf, desk, w, h, cards, strips, style, bar, prep);
}

/// `compose` over a buffer that already holds the desk.
fn composeOver(
    buf: []u32,
    desk: []const u32,
    w: usize,
    h: usize,
    cards: []const pane_elevation.Card,
    strips: []const pane_stack_strip.Band,
    style: pane_elevation.CardStyle,
    bar: ?Bar,
    prep: ?*const pane_elevation.Prepared,
) void {
    pane_elevation.paintCardsWith(buf, w, h, cards, style, prep);
    const radius = pane_elevation.radiusPx(style.scale);
    for (strips) |s| {
        // Each blade's shadow lands on the blade behind it, which is already
        // down (T2307): leaning away from the run, fading out inside its
        // rounded ends (T2410).
        blade_shadow.paint(buf, w, h, s.tab, s.axis, s.leads, s.collapse, style.is_light, style.scale, radius);
        if (!s.band) continue;
        // On glass the band is the tucked card's sheet, so the desk reads
        // through it (T2160, T2505), edged with the card's rim.
        if (s.glass) |g|
            pane_stack_strip.paintGlassBand(buf, desk, w, h, s.tab, s.axis, g, radius, pane_stack_strip.Rim.glass(style.is_light, style.scale))
        else
            pane_stack_strip.paintBand(buf, w, h, s.tab, s.axis, s.rgb, radius);
    }
    if (bar) |b| gutter_bar.paint(buf, w, h, b.core, b.color, style.scale, b.strength);
}

/// How far past its own rect anything a compose lays for a card, a strip or
/// the bar can reach: what a repaint of one that moved has to cover.
fn reachPx(scale: f32) i32 {
    return @max(
        @max(pane_elevation.shadowReachPx(scale), pane_elevation.glowReachPx(scale)),
        @max(blade_shadow.reachPx(scale), gutter_bar.glowReach(scale)),
    ) + 2;
}

/// The shadow patch for `style`, built when the style changes (T2454); null
/// when it cannot be, and the painters then build their own.
fn preparedFor(self: *PaneDesk, style: pane_elevation.CardStyle) ?*const pane_elevation.Prepared {
    if (self.prepared) |*p| {
        if (p.fits(style)) return p;
        p.deinit();
        self.prepared = null;
    }
    self.prepared = pane_elevation.prepare(style);
    return &self.prepared.?;
}

/// Compose `comp` again over `rects` alone (T2454), each in a scratch buffer
/// its size with every card, strip and the bar moved into it, then copied in.
/// The lights' rings are lifted off `comp` first, so it is the light-free
/// picture the rings are rebased from afterwards. False when the scratch
/// cannot be had; the caller then composes the whole buffer.
fn composePartial(
    self: *PaneDesk,
    comp: Dib,
    desk: Dib,
    rects: []const busy_light.Rect,
    cards: []const pane_elevation.Card,
    strips: []const pane_stack_strip.Band,
    style: pane_elevation.CardStyle,
    bar: ?Bar,
    prep: ?*const pane_elevation.Prepared,
) bool {
    if (cards.len > Memo.MAX_CARDS or strips.len > Memo.MAX_STRIPS) return false;
    const glass_band = for (strips) |s| {
        if (s.band and s.glass != null) break true;
    } else false;
    return composeRects(
        &self.scratch,
        if (glass_band) &self.scratch_desk else null,
        comp.pixels(),
        desk.pixels(),
        @intCast(comp.w),
        rects,
        cards,
        strips,
        style,
        bar,
        self.lights[0..self.light_n],
        comp.w,
        comp.h,
        prep,
    );
}

/// `composePartial` over plain buffers, so a test can hold it to a whole
/// compose pixel for pixel. `lights` are the ring caches built for a
/// `lw` x `lh` buffer; any other size's are not on `comp`.
fn composeRects(
    scratch: *std.ArrayListUnmanaged(u32),
    scratch_desk: ?*std.ArrayListUnmanaged(u32),
    comp: []u32,
    desk: []const u32,
    stride: usize,
    rects: []const busy_light.Rect,
    cards: []const pane_elevation.Card,
    strips: []const pane_stack_strip.Band,
    style: pane_elevation.CardStyle,
    bar: ?Bar,
    lights: []const LightCache,
    lw: i32,
    lh: i32,
    prep: ?*const pane_elevation.Prepared,
) bool {
    var most: usize = 0;
    for (rects) |r| most = @max(most, @as(usize, @intCast(r.right - r.left)) * @as(usize, @intCast(r.bottom - r.top)));
    scratch.resize(light_alloc, most) catch return false;
    if (scratch_desk) |d| d.resize(light_alloc, most) catch return false;
    for (lights) |*c| if (c.w == lw and c.h == lh) busy_light.restore(comp, c.px.items);
    for (rects) |r| composeRect(scratch.items, if (scratch_desk) |d| d.items else null, comp, desk, stride, r, cards, strips, style, bar, prep);
    return true;
}

/// One of `composeRects`' rectangles, through `scratch` (and `sd`, the desk
/// under it, for a glass band), each at least its size.
fn composeRect(
    scratch_buf: []u32,
    sd_buf: ?[]u32,
    comp: []u32,
    desk: []const u32,
    stride: usize,
    r: busy_light.Rect,
    cards: []const pane_elevation.Card,
    strips: []const pane_stack_strip.Band,
    style: pane_elevation.CardStyle,
    bar: ?Bar,
    prep: ?*const pane_elevation.Prepared,
) void {
    const rw: usize = @intCast(r.right - r.left);
    const rh: usize = @intCast(r.bottom - r.top);
    if (rw == 0 or rh == 0) return;
    const sbuf = scratch_buf[0 .. rw * rh];
    const sd: ?[]u32 = if (sd_buf) |d| d[0 .. rw * rh] else null;

    const x0: usize = @intCast(r.left);
    const y0: usize = @intCast(r.top);
    // The desk under `r`, as the scratch's own (only the glass bands read it
    // apart from the copy).
    const sub_desk: []const u32 = sd orelse sbuf;
    for (0..rh) |y| {
        const src = desk[(y0 + y) * stride + x0 ..][0..rw];
        @memcpy(sbuf[y * rw ..][0..rw], src);
        if (sd) |d| @memcpy(d[y * rw ..][0..rw], src);
    }
    var tc: [Memo.MAX_CARDS]pane_elevation.Card = undefined;
    for (cards, 0..) |c, i| {
        tc[i] = c;
        tc[i].left -= r.left;
        tc[i].right -= r.left;
        tc[i].top -= r.top;
        tc[i].bottom -= r.top;
        tc[i].head_bottom -= r.top;
    }
    var ts: [Memo.MAX_STRIPS]pane_stack_strip.Band = undefined;
    for (strips, 0..) |s, i| {
        ts[i] = s;
        ts[i].tab = .{ .left = s.tab.left - r.left, .top = s.tab.top - r.top, .right = s.tab.right - r.left, .bottom = s.tab.bottom - r.top };
    }
    const tb: ?Bar = if (bar) |b| blk: {
        var m = b;
        m.core = .{ .left = b.core.left - r.left, .top = b.core.top - r.top, .right = b.core.right - r.left, .bottom = b.core.bottom - r.top };
        break :blk m;
    } else null;
    composeOver(sbuf, sub_desk, rw, rh, tc[0..cards.len], ts[0..strips.len], style, tb, prep);
    for (0..rh) |y| @memcpy(comp[(y0 + y) * stride + x0 ..][0..rw], sbuf[y * rw ..][0..rw]);
}

/// `comp` onto the window - through `out` on a translucent one (T1852).
fn blit(self: *PaneDesk, hdc: w32.HDC, origin_x: i32, origin_y: i32, w: i32, h: i32, comp: Dib, desk: Dib, opacity: ?u8) void {
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

test "T2448: the desk memo matches the same inputs and nothing else" {
    const testing = std.testing;
    var m: Memo = .{};
    var cards = [_]pane_elevation.Card{
        .{ .left = 0, .top = 0, .right = 100, .bottom = 80 },
        .{ .left = 110, .top = 0, .right = 200, .bottom = 80, .shadow = 0.5 },
    };
    const glows = [_]pane_elevation.Glow{.{ .card = 0, .level = 1 }};
    const style: pane_elevation.CardStyle = .{ .fill = .{ .r = 1, .g = 2, .b = 3 }, .is_light = false, .scale = 1, .glows = &glows };
    const strips = [_]pane_stack_strip.Band{};
    const lights = [_]Light{};

    try testing.expect(!m.matches(300, 100, 1, &cards, &strips, style, null, &lights));
    m.store(300, 100, 1, &cards, &strips, style, null, &lights);
    try testing.expect(m.matches(300, 100, 1, &cards, &strips, style, null, &lights));

    // A card one pixel over, a new desk, another size, a lit bar, a glow
    // mid-fade: each is a different picture.
    var moved = cards;
    moved[1].left += 1;
    try testing.expect(!m.matches(300, 100, 1, &moved, &strips, style, null, &lights));
    try testing.expect(!m.matches(300, 100, 2, &cards, &strips, style, null, &lights));
    try testing.expect(!m.matches(301, 100, 1, &cards, &strips, style, null, &lights));
    const bar: Bar = .{ .core = .{ .left = 100, .top = 0, .right = 110, .bottom = 80 }, .color = .{ .r = 9, .g = 9, .b = 9 }, .strength = .drag };
    try testing.expect(!m.matches(300, 100, 1, &cards, &strips, style, bar, &lights));
    var fading = style;
    const half = [_]pane_elevation.Glow{.{ .card = 0, .level = 0.5 }};
    fading.glows = &half;
    try testing.expect(!m.matches(300, 100, 1, &cards, &strips, fading, null, &lights));

    // A grid too big to remember is composed every time.
    var many: [Memo.MAX_CARDS + 1]pane_elevation.Card = undefined;
    for (&many) |*c| c.* = cards[0];
    m.store(300, 100, 1, &many, &strips, style, null, &lights);
    try testing.expect(!m.matches(300, 100, 1, &many, &strips, style, null, &lights));
}

test "T2454: composing only the rectangle that changed paints exactly what a whole compose does" {
    const testing = std.testing;
    const w = 960;
    const h = 460;
    const desk = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(desk);
    // A desk with detail everywhere, so a misplaced copy cannot hide.
    for (0..h) |y| for (0..w) |x| {
        desk[y * w + x] = @as(u32, @intCast(x % 256)) << 16 | @as(u32, @intCast(y % 256)) << 8 | @as(u32, @intCast((x * 3 + y) % 256));
    };
    const full = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(full);
    const comp = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(comp);
    var scratch: std.ArrayListUnmanaged(u32) = .empty;
    defer scratch.deinit(light_alloc);
    var scratch_desk: std.ArrayListUnmanaged(u32) = .empty;
    defer scratch_desk.deinit(light_alloc);

    const page: color_math.Rgb = .{ .r = 240, .g = 240, .b = 236 };
    const head: color_math.Rgb = .{ .r = 50, .g = 54, .b = 60 };
    const base_cards = [_]pane_elevation.Card{
        // Two big cards either side of the dragged divider, a head band on
        // each (glass on the first)...
        .{ .left = 10, .top = 10, .right = 330, .bottom = 450, .head = head, .head_bottom = 40, .head_glass = true },
        .{ .left = 345, .top = 10, .right = 665, .bottom = 450, .fill = page, .head = head, .head_bottom = 34 },
        // ...a big faded sheet and a strength-faded shadow stacked beside
        // them, and a card too small for its edges alone.
        .{ .left = 680, .top = 10, .right = 870, .bottom = 225, .sheet = .{ .fade = 0.3 } },
        .{ .left = 680, .top = 240, .right = 870, .bottom = 450, .shadow = 0.4 },
        .{ .left = 300, .top = 380, .right = 316, .bottom = 420 },
    };
    const base_strips = [_]pane_stack_strip.Band{
        .{ .tab = .{ .left = 880, .top = 10, .right = 900, .bottom = 450 }, .axis = .horizontal, .rgb = .{ .r = 60, .g = 60, .b = 70 }, .leads = false },
        .{ .tab = .{ .left = 902, .top = 10, .right = 920, .bottom = 450 }, .axis = .horizontal, .rgb = .{ .r = 60, .g = 60, .b = 70 }, .leads = false, .glass = .{ .bg = .{ .r = 20, .g = 20, .b = 24 }, .sheet = .{} } },
        // The fourth card gliding into its strip: only its blade shadow.
        .{ .tab = .{ .left = 680, .top = 240, .right = 870, .bottom = 450 }, .axis = .horizontal, .rgb = .{ .r = 60, .g = 60, .b = 70 }, .leads = false, .collapse = 0.5, .band = false },
    };
    const base_bar: Bar = .{ .core = .{ .left = 333, .top = 200, .right = 341, .bottom = 260 }, .color = .{ .r = 90, .g = 140, .b = 250 }, .strength = .drag };
    const glow0 = [_]pane_elevation.Glow{.{ .card = 1, .level = 1 }};
    const glow1 = [_]pane_elevation.Glow{ .{ .card = 2, .level = 0.6 }, .{ .card = 1, .level = 0.4 } };

    const Case = struct {
        name: []const u8,
        dx: i32 = 0,
        dy: i32 = 0,
        slide: i32 = 0,
        small: i32 = 0,
        glow_moves: bool = false,
        bar_moves: bool = false,
        strip_moves: bool = false,
        /// The fourth card a frame further into its strip.
        glides: bool = false,
        /// A page recoloured and a shadow strength mid-glide: the whole card.
        recolor: bool = false,
        /// Whether only edge bands should be redone, not whole cards.
        bands: bool = false,
    };
    const cases = [_]Case{
        .{ .name = "divider dragged", .dx = 9, .bar_moves = true, .bands = true },
        .{ .name = "divider dragged back", .dx = -23, .bands = true },
        .{ .name = "stacked divider dragged", .dy = 14, .bands = true },
        .{ .name = "card slid whole", .slide = 17, .bands = true },
        .{ .name = "small card grows", .small = 6 },
        .{ .name = "page and shadow restyled", .recolor = true },
        .{ .name = "focus fading over", .glow_moves = true },
        .{ .name = "a strip gliding", .strip_moves = true },
        .{ .name = "a card gliding into its strip", .glides = true, .bands = true },
        .{ .name = "card off the left edge", .dx = -340 },
    };
    var partials: usize = 0;
    for ([_]bool{ false, true }) |glass| for ([_]f32{ 1, 1.5 }) |scale| for (cases) |cs| {
        const style0: pane_elevation.CardStyle = .{ .fill = .{ .r = 24, .g = 26, .b = 30 }, .is_light = false, .scale = scale, .glass = glass, .glows = &glow0 };
        var style1 = style0;
        if (cs.glow_moves) style1.glows = &glow1;
        var cards1 = base_cards;
        if (cs.dx > -100) {
            cards1[0].right += cs.dx;
            cards1[1].left += cs.dx;
        } else {
            cards1[0].left += cs.dx;
            cards1[0].right += cs.dx;
        }
        cards1[2].bottom += cs.dy;
        cards1[3].top += cs.dy;
        cards1[2].left += cs.slide;
        cards1[2].right += cs.slide;
        cards1[4].right += cs.small;
        if (cs.glides) {
            cards1[3].right -= 15;
            cards1[3].shadow = 0.5;
        }
        if (cs.recolor) {
            cards1[1].fill = .{ .r = 250, .g = 250, .b = 250 };
            cards1[3].shadow = 0.7;
        }
        var strips1 = base_strips;
        if (cs.strip_moves) {
            strips1[0].collapse = 0.5;
            strips1[0].band = false;
            strips1[1].tab.left -= 4;
        }
        if (cs.glides) {
            strips1[2].tab.right -= 15;
            strips1[2].collapse = 0.6;
        }
        var bar1 = base_bar;
        if (cs.bar_moves) {
            bar1.core.left += cs.dx;
            bar1.core.right += cs.dx;
        }

        // The picture before, as the memo remembers it...
        var m: Memo = .{};
        compose(comp, desk, w, h, &base_cards, &base_strips, style0, base_bar, null);
        m.store(w, h, 1, &base_cards, &base_strips, style0, base_bar, &.{});
        // ...the picture after, composed whole...
        compose(full, desk, w, h, &cards1, &strips1, style1, bar1, null);
        // ...and only over what changed.
        const p = m.dirty(w, h, 1, &cards1, &strips1, style1, bar1);
        switch (p) {
            .full => compose(comp, desk, w, h, &cards1, &strips1, style1, bar1, null),
            .rects => |r| {
                partials += 1;
                // Edge bands alone: a quarter of the window at most, where
                // the two whole cards they edge would be most of it.
                if (cs.bands) try testing.expect(r.area() * 4 < @as(i64, w) * h);
                // Through a prepared patch, as the window composes: the same
                // pixels as the whole compose that built its own.
                var prep = pane_elevation.prepare(style1);
                defer prep.deinit();
                try testing.expect(composeRects(&scratch, &scratch_desk, comp, desk, w, r.slice(), &cards1, &strips1, style1, bar1, &.{}, w, h, &prep));
            },
        }
        for (full, comp, 0..) |a, b, i| if (a != b) {
            std.debug.print("{s} glass={} scale={d}: first difference at ({d},{d}): {x} vs {x}\n", .{ cs.name, glass, scale, i % w, i / w, a, b });
            return error.TestExpectedEqual;
        };
    };
    // Every case is one a glide makes, and each of them took the partial path.
    try testing.expectEqual(@as(usize, 2 * 2 * cases.len), partials);

    // What the whole picture depends on is never patched.
    var m: Memo = .{};
    const style: pane_elevation.CardStyle = .{ .fill = .{ .r = 24, .g = 26, .b = 30 }, .is_light = false, .scale = 1 };
    m.store(w, h, 1, &base_cards, &base_strips, style, null, &.{});
    try testing.expect(m.dirty(w, h, 2, &base_cards, &base_strips, style, null) == .full);
    try testing.expect(m.dirty(w, h, 1, base_cards[0..3], &base_strips, style, null) == .full);
    var lit = style;
    lit.is_light = true;
    try testing.expect(m.dirty(w, h, 1, &base_cards, &base_strips, lit, null) == .full);
    // Nothing composed changed (a light moved, say): no rectangle at all.
    const same = m.dirty(w, h, 1, &base_cards, &base_strips, style, null);
    try testing.expect(same == .rects and same.rects.len == 0);
}

test "T2454: a partial compose lifts the lights off first, so their rings rebase onto the bare picture" {
    const testing = std.testing;
    const w = 200;
    const h = 120;
    var desk: [w * h]u32 = undefined;
    for (&desk, 0..) |*p, i| p.* = @intCast((i * 2654435761) & 0x00FF_FFFF);
    var comp: [w * h]u32 = undefined;
    var full: [w * h]u32 = undefined;
    var scratch: std.ArrayListUnmanaged(u32) = .empty;
    defer scratch.deinit(light_alloc);
    const style: pane_elevation.CardStyle = .{ .fill = .{ .r = 24, .g = 26, .b = 30 }, .is_light = false, .scale = 1 };
    const cards0 = [_]pane_elevation.Card{
        .{ .left = 10, .top = 10, .right = 90, .bottom = 110 },
        .{ .left = 100, .top = 10, .right = 190, .bottom = 110 },
    };
    compose(&comp, &desk, w, h, &cards0, &.{}, style, null, null);
    // The second card is busy: its ring is built, based and drawn on.
    var lights = [_]LightCache{.{ .card = cards0[1], .shape = .ring, .scale = 1, .w = w, .h = h }};
    defer lights[0].px.deinit(light_alloc);
    try busy_light.build(light_alloc, &lights[0].px, w, h, cards0[1], .ring, 1);
    busy_light.rebase(&comp, lights[0].px.items);
    busy_light.apply(&comp, lights[0].px.items, .ring, .{ .r = 255, .g = 160, .b = 0 }, 0.3);

    // The first card narrows; its rectangle reaches into the ring.
    var cards1 = cards0;
    cards1[0].right -= 6;
    var m: Memo = .{};
    m.store(w, h, 1, &cards0, &.{}, style, null, &.{});
    const r = m.dirty(w, h, 1, &cards1, &.{}, style, null).rects;
    try testing.expect(r.len > 0 and r.items[0].right > cards0[1].left);
    try testing.expect(composeRects(&scratch, null, &comp, &desk, w, r.slice(), &cards1, &.{}, style, null, &lights, w, h, null));
    compose(&full, &desk, w, h, &cards1, &.{}, style, null, null);
    try testing.expectEqualSlices(u32, &full, &comp);
}

// T2454: a glide frame's compose, whole against partial, at the window the
// task measured. Skipped unless GHOZTTY_BENCH is set; run it under ReleaseFast:
//   GHOZTTY_BENCH=1 zig test src/apprt/win32/PaneDesk.zig -OReleaseFast --test-filter "T2454: bench"
test "T2454: bench - a divider-drag frame's compose, whole and partial" {
    const testing = std.testing;
    if (!(std.process.hasEnvVar(testing.allocator, "GHOZTTY_BENCH") catch false)) return error.SkipZigTest;
    const w: usize = 3800;
    const h: usize = 2050;
    const scale: f32 = 1.25;
    const desk = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(desk);
    @memset(desk, 0x00284060);
    const comp = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(comp);
    var scratch: std.ArrayListUnmanaged(u32) = .empty;
    defer scratch.deinit(light_alloc);
    const m_px = pane_elevation.marginPx(.elevated, scale);
    const g_px = pane_elevation.gapPx(.elevated, scale).?;
    const cw = @divFloor(@as(i32, @intCast(w)) - 2 * m_px - 4 * g_px, 5);
    var cards: [5]pane_elevation.Card = undefined;
    for (&cards, 0..) |*c, i| {
        const l = m_px + @as(i32, @intCast(i)) * (cw + g_px);
        c.* = .{ .left = l, .top = m_px, .right = l + cw, .bottom = @as(i32, @intCast(h)) - m_px };
    }
    cards[1].fill = .{ .r = 240, .g = 240, .b = 236 };
    cards[1].head = .{ .r = 50, .g = 54, .b = 60 };
    cards[1].head_bottom = m_px + 40;
    // The fourth card gliding into its strip: its blade shadow, cast from
    // the card's own rect (T2307), changes with every frame of the glide.
    const glide = [_]pane_stack_strip.Band{.{ .tab = .{ .left = cards[3].left, .top = cards[3].top, .right = cards[3].right, .bottom = cards[3].bottom }, .axis = .horizontal, .rgb = .{ .r = 60, .g = 60, .b = 70 }, .leads = false, .collapse = 0.5, .band = false }};
    for ([_]bool{ false, true }) |glass| for ([_]bool{ false, true }) |gliding| {
        const style: pane_elevation.CardStyle = .{ .fill = .{ .r = 29, .g = 31, .b = 33 }, .is_light = false, .scale = scale, .glass = glass };
        const strips0: []const pane_stack_strip.Band = if (gliding) &glide else &.{};
        var glide1 = glide;
        glide1[0].collapse = 0.55;
        const strips1: []const pane_stack_strip.Band = if (gliding) &glide1 else &.{};
        var prep = pane_elevation.prepare(style);
        defer prep.deinit();
        var moved = cards;
        moved[0].right += 12;
        moved[1].left += 12;
        var whole: u64 = std.math.maxInt(u64);
        var part: u64 = std.math.maxInt(u64);
        var area: i64 = 0;
        var n: usize = 0;
        for (0..20) |_| {
            var timer = try std.time.Timer.start();
            compose(comp, desk, w, h, &moved, strips1, style, null, null);
            whole = @min(whole, timer.read());
            compose(comp, desk, w, h, &cards, strips0, style, null, null);
            var m: Memo = .{};
            m.store(@intCast(w), @intCast(h), 1, &cards, strips0, style, null, &.{});
            timer.reset();
            const r = m.dirty(@intCast(w), @intCast(h), 1, &moved, strips1, style, null).rects;
            try testing.expect(composeRects(&scratch, null, comp, desk, w, r.slice(), &moved, strips1, style, null, &.{}, @intCast(w), @intCast(h), &prep));
            part = @min(part, timer.read());
            area = r.area();
            n = r.len;
        }
        std.debug.print("{d}x{d} @{d}x glass={} gliding={}, first divider +12px: whole {d:.2} ms, partial {d:.2} ms ({d}% of the window, {d} rects)\n", .{
            w,
            h,
            scale,
            glass,
            gliding,
            @as(f64, @floatFromInt(whole)) / 1e6,
            @as(f64, @floatFromInt(part)) / 1e6,
            @divFloor(area * 100, @as(i64, @intCast(w * h))),
            n,
        });
    };
}
