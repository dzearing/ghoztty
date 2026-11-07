//! The tint a pane takes while its sidebar row or tile is under the pointer
//! (T2278): Mac's `PaneSidebarHoverTint`, a 10% wash and a 2 DIP 45% rim in
//! the pane's own hue, faded in quickly and back out a touch slower.
//!
//! The `BellBorder` shape (T1919): a WS_EX_LAYERED popup owned by the pane's
//! child HWND, so DWM composites it above OpenGL and WebView2 content alike,
//! WS_EX_TRANSPARENT so it never takes the pointer (Mac's
//! `.allowsHitTesting(false)`), and per-pixel alpha through
//! UpdateLayeredWindow. The fade is the blend's `SourceConstantAlpha`, stepped
//! by a timer on this popup's own HWND, so a fade step never re-renders. Pure
//! logic (hue, pixels, curve) is `pane_hue.zig`.
//!
//! When the pane presents through a composition swap chain (T2466) the tint
//! is a child visual of the pane's visual instead (T2762, comp_overlay.zig):
//! the same pixels, pane-local, so a pane that moves takes it along with no
//! window move, and the whole easeOut fade is declared to the compositor once
//! and run by DWM at the display's refresh however busy this thread is. The
//! popup's timer then fires once, at the fade's end, for the bookkeeping. A
//! pane whose window spans a banner band (T2568) keeps the popup, as the dim
//! wash does: the tint covers the band, and the pane's visual starts below
//! it. So does a viewer pane, which has no composition tree to join.

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const FrameClock = @import("FrameClock.zig");
const pane_clip = @import("pane_clip.zig");
const pane_hue = @import("pane_hue.zig");
const color_math = @import("color_math.zig");
const chrome_fanout = @import("chrome_fanout.zig");
const comp_overlay = @import("../../renderer/comp_overlay.zig");

const log = std.log.scoped(.win32_hover_tint);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyHoverTint");

const FADE_TIMER_ID: usize = 1;
const FADE_TICK_MS: u32 = 16;

pub const HoverTint = struct {
    alloc: std.mem.Allocator,
    /// The pane child HWND this tint covers (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,

    /// The tint is up (it may be mid fade-out at any alpha), as the popup or
    /// - when `on_visual` - as the pane's child visual.
    shown: bool = false,
    on_visual: bool = false,
    /// The pane renderer's composition tree (T2762), or null for a pane that
    /// never has one (a viewer); the tint's layer on it.
    slot: ?*comp_overlay.Slot,
    layer: comp_overlay.Layer = .{},
    /// The px of the owner's window a banner band takes (`Surface.grid_band`,
    /// T2568); a band keeps the popup. Null: no band ever.
    grid_band: ?*const std.atomic.Value(u32) = null,
    /// What was last rendered: where (screen pixels), in what, in what shape.
    placed: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    color: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    rim_px: i32 = 0,
    shape: pane_hue.Shape = .{},
    /// The tint's opacity, and the fade under way.
    alpha: u8 = 0,
    fade_from: u8 = 0,
    fade_to: u8 = 0,
    fade_t0_ms: i64 = 0,
    /// A fade is under way (its timer is armed), and whether the compositor
    /// runs it (declared once) rather than this thread stepping it.
    fading: bool = false,
    fade_on_compositor: bool = false,
    /// UI-thread steps the current fade took: 0 when the compositor ran it.
    fade_steps: u32 = 0,
    /// See `DimOverlay.matchOwnerRegion` (T1831).
    region_key: u64 = 0,
    /// Render scratch, grown to the largest pane seen.
    px: []u32 = &.{},

    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        hinstance: w32.HINSTANCE,
        slot: ?*comp_overlay.Slot,
    ) !*HoverTint {
        try registerClassOnce(hinstance);
        const self = try alloc.create(HoverTint);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .owner = owner, .hwnd = undefined, .slot = slot };
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_TRANSPARENT |
            w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW;
        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP,
            0,
            0,
            1,
            1, // placeholder - update() glues it to the owner
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *HoverTint) void {
        FrameClock.disarm(self.hwnd, FADE_TIMER_ID);
        self.layer.deinit();
        _ = w32.DestroyWindow(self.hwnd);
        if (self.px.len > 0) self.alloc.free(self.px);
        self.alloc.destroy(self);
    }

    /// Bring the tint in line with `want` (this pane's sidebar row or tile is
    /// hovered), in `c`, following `shape`. Idempotent, so it rides every
    /// layout pass and keeps the tint glued to the pane through a resize, a
    /// divider drag and a move.
    pub fn update(self: *HoverTint, want: bool, c: color_math.Rgb, shape: pane_hue.Shape, scale: f32) void {
        const visual = self.wantVisual();
        if (visual != self.on_visual) {
            // The pane gained or lost its composition tree (or a banner
            // band): the tint leaves the old path at once and goes up afresh
            // on the new one. (A retracted tree already took the visual.)
            self.hideNow();
            self.on_visual = visual;
            self.placed = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            log.info("hover tint path visual={} pane={d}", .{ visual, @intFromPtr(self.owner) });
        }
        // A pane on a background tab, stashed, behind a zoom or mid-slide has
        // nothing to tint: gone at once, no fade.
        if (!pane_clip.ownerWhollyInView(self.owner)) {
            self.hideNow();
            return;
        }
        if (!want) {
            if (self.shown) self.startFade(0);
            return;
        }
        if (visual) return self.updateVisual(c, shape, scale);

        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(self.owner, &rect) == 0) return;
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        if (w <= 0 or h <= 0) {
            self.hideNow();
            return;
        }
        const rim_px = pane_hue.rimPx(scale);
        const restyled = w != self.placed.right - self.placed.left or
            h != self.placed.bottom - self.placed.top or rim_px != self.rim_px or
            !c.eql(self.color) or !std.meta.eql(shape, self.shape);
        const moved = !std.meta.eql(rect, self.placed);
        const was_shown = self.shown;

        if (!was_shown or restyled) {
            if (!self.render(rect, c, rim_px, shape)) return;
        } else if (moved) {
            chrome_fanout.noteMove(.dim);
            _ = w32.SetWindowPos(self.hwnd, null, rect.left, rect.top, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_NOSIZE);
        }
        self.placed = rect;
        self.color = c;
        self.rim_px = rim_px;
        self.shape = shape;

        if (!was_shown) {
            _ = w32.ShowWindow(self.hwnd, w32.SW_SHOWNOACTIVATE);
            self.shown = true;
            log.info("hover tint shown rgb={d},{d},{d} radius={d} rect={d},{d},{d}x{d}", .{ c.r, c.g, c.b, shape.radius, rect.left, rect.top, w, h });
        }
        if (self.fade_to != 255) self.startFade(255);
        w32.healOverlayZOrderAfterMove(self.hwnd, self.owner, was_shown);
    }

    /// The pane's composition tree, unless the pane's window spans a banner
    /// band, which the tint covers and the pane's visual does not.
    fn wantVisual(self: *HoverTint) bool {
        const s = self.slot orelse return false;
        if (self.gridBand() != 0) return false;
        return self.layer.sync(s);
    }

    fn gridBand(self: *const HoverTint) u32 {
        const b = self.grid_band orelse return 0;
        return b.load(.acquire);
    }

    /// The visual path: the tint is pane-local at (0,0), clipped by the pane
    /// window itself (its rounded card included), so a move is nothing to it
    /// - only a new size, colour or shape re-renders it.
    fn updateVisual(self: *HoverTint, c: color_math.Rgb, shape: pane_hue.Shape, scale: f32) void {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.owner, &rect) == 0) return;
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        if (w <= 0 or h <= 0) {
            self.hideNow();
            return;
        }
        const rim_px = pane_hue.rimPx(scale);
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        if (!self.layer.hasPixels() or uw != self.layer.width or uh != self.layer.height or
            rim_px != self.rim_px or !c.eql(self.color) or !std.meta.eql(shape, self.shape))
        {
            const n: usize = @as(usize, uw) * uh;
            if (!self.ensurePx(n)) return;
            pane_hue.renderTint(self.px[0..n], w, h, c, rim_px, shape);
            if (!self.layer.setPixels(self.px[0..n], uw, uh)) {
                log.warn("hover tint visual upload failed {d}x{d}", .{ w, h });
                return;
            }
        }
        self.color = c;
        self.rim_px = rim_px;
        self.shape = shape;
        // A rebuilt tree (the renderer remade its chain) is a fresh layer
        // under a tint that is still up: attach it again, from where the
        // fade has got to, and declare a fade in flight again from there.
        if (!self.shown or !self.layer.attached) {
            self.alpha = self.currentAlpha();
            self.layer.setOpacity(self.alpha);
            self.layer.setVisible(true);
            self.shown = true;
            log.info("hover tint shown as visual rgb={d},{d},{d} radius={d} size={d}x{d} pane={d}", .{ c.r, c.g, c.b, shape.radius, w, h, @intFromPtr(self.owner) });
            if (self.fading and self.fade_on_compositor) self.redeclareFade();
        }
        if (self.fade_to != 255) self.startFade(255);
    }

    fn ensurePx(self: *HoverTint, n: usize) bool {
        if (self.px.len >= n) return true;
        if (self.px.len > 0) self.alloc.free(self.px);
        self.px = self.alloc.alloc(u32, n) catch {
            self.px = &.{};
            return false;
        };
        return true;
    }

    /// Clip the tint to the owner's window region - an elevated pane is a
    /// rounded card (T1831). Same contract as `DimOverlay.matchOwnerRegion`.
    /// The popup's alone: the visual is clipped by the pane window itself.
    pub fn matchOwnerRegion(self: *HoverTint, key: u64) void {
        if (key == self.region_key) return;
        self.region_key = key;
        if (key == 0) {
            _ = w32.SetWindowRgn(self.hwnd, null, 1);
            return;
        }
        const rgn = w32.CreateRectRgn(0, 0, 0, 0) orelse return;
        if (w32.GetWindowRgn(self.owner, rgn) == 0 or w32.SetWindowRgn(self.hwnd, rgn, 1) == 0) {
            _ = w32.DeleteObject(rgn);
            self.region_key = 0;
        }
    }

    /// The uniform name every pane popup answers (T2012).
    pub fn hide(self: *HoverTint) void {
        self.hideNow();
    }

    /// Off screen now, with no fade.
    pub fn hideNow(self: *HoverTint) void {
        FrameClock.disarm(self.hwnd, FADE_TIMER_ID);
        self.alpha = 0;
        self.fade_from = 0;
        self.fade_to = 0;
        self.fading = false;
        self.fade_on_compositor = false;
        if (!self.shown) return;
        if (self.on_visual) self.layer.setVisible(false) else _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.shown = false;
        log.info("hover tint hidden visual={}", .{self.on_visual});
    }

    fn startFade(self: *HoverTint, to: u8) void {
        if (self.fade_to == to) return;
        // A compositor fade's value lives in DWM; this side knows it from the
        // clock. A stepped fade's `alpha` is already the value on screen.
        if (self.fade_on_compositor) self.alpha = self.currentAlpha();
        self.fade_from = self.alpha;
        self.fade_to = to;
        self.fade_t0_ms = std.time.milliTimestamp();
        self.fade_steps = 0;
        self.fading = true;
        FrameClock.disarm(self.hwnd, FADE_TIMER_ID);
        self.fade_on_compositor = self.on_visual and self.layer.attached and self.declareFade();
        if (self.fade_on_compositor) {
            const ms = pane_hue.fadeMs(self.fade_from, to);
            log.info("hover tint fade on compositor from={d} to={d} ms={d}", .{ self.fade_from, to, ms });
            _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, @intCast(ms), null);
        } else {
            _ = FrameClock.arm(self.hwnd, FADE_TIMER_ID, FADE_TICK_MS);
        }
        debugStall();
    }

    /// Declare `fade_from` -> `fade_to` to the compositor as one easeOut
    /// animation. False: the layer could not take it, so the caller steps it.
    fn declareFade(self: *HoverTint) bool {
        // `GHOZTTY_DEBUG_HOVER_TINT_FADE_STEPPED=1` (debug builds): step the
        // visual's fade on this thread instead - the oracle's A/B arm, the
        // same visual driven the old way.
        if (comptime builtin.mode == .Debug) {
            if (std.process.hasNonEmptyEnvVarConstant("GHOZTTY_DEBUG_HOVER_TINT_FADE_STEPPED")) return false;
        }
        var segs: [comp_overlay.ease_segments]comp_overlay.Cubic = undefined;
        const dur_s = @as(f64, @floatFromInt(pane_hue.fadeMs(self.fade_from, self.fade_to))) / 1000.0;
        comp_overlay.fitCurve(pane_hue.easeOut, dur_s, &segs);
        if (self.layer.animateOpacity(self.fade_from, self.fade_to, &segs, dur_s)) return true;
        log.warn("hover tint fade could not go on the compositor; stepping it", .{});
        return false;
    }

    /// The renderer rebuilt the tree mid-fade: carry on from the value the
    /// fade had reached, over a fresh full curve (what a retarget does too).
    fn redeclareFade(self: *HoverTint) void {
        const to = self.fade_to;
        self.fade_to = self.alpha;
        self.fade_on_compositor = false;
        self.startFade(to);
    }

    /// Where the fade is now: read off its curve by the clock.
    fn currentAlpha(self: *const HoverTint) u8 {
        if (!self.fading) return self.alpha;
        return pane_hue.fadeAlpha(self.fade_from, self.fade_to, std.time.milliTimestamp() - self.fade_t0_ms);
    }

    /// `GHOZTTY_DEBUG_HOVER_TINT_FADE_STALL_MS=<n>` (debug builds, T2762):
    /// block this thread for n ms the moment a fade starts - the oracle's
    /// stand-in for a busy UI thread. A compositor fade moves through it; a
    /// stepped one freezes.
    fn debugStall() void {
        if (comptime builtin.mode != .Debug) return;
        const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_DEBUG_HOVER_TINT_FADE_STALL_MS") catch return;
        defer std.heap.page_allocator.free(raw);
        const ms = std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return;
        if (ms == 0) return;
        log.info("hover tint debug stall ms={d}", .{ms});
        std.Thread.sleep(@as(u64, @min(ms, 5000)) * std.time.ns_per_ms);
    }

    fn fadeTick(self: *HoverTint) void {
        const elapsed = std.time.milliTimestamp() - self.fade_t0_ms;
        if (self.fade_on_compositor) {
            // The one end-of-fade tick. A timer that came in early waits out
            // the rest; the compositor already holds the final value.
            const ms = pane_hue.fadeMs(self.fade_from, self.fade_to);
            if (elapsed < ms) {
                _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, @intCast(ms - elapsed), null);
                return;
            }
            self.alpha = self.fade_to;
        } else {
            self.fade_steps += 1;
            const a = pane_hue.fadeAlpha(self.fade_from, self.fade_to, elapsed);
            self.setAlpha(a);
            if (a != self.fade_to) return;
        }
        FrameClock.disarm(self.hwnd, FADE_TIMER_ID);
        self.fading = false;
        log.info("hover tint fade done alpha={d} ms={d} compositor={} ui_steps={d}", .{ self.alpha, elapsed, self.fade_on_compositor, self.fade_steps });
        if (self.alpha == 0) self.hideNow();
    }

    /// Change only the blend: no source DC, so the tint is not re-rendered.
    fn setAlpha(self: *HoverTint, a: u8) void {
        if (a == self.alpha) return;
        self.alpha = a;
        if (self.on_visual) return self.layer.setOpacity(a);
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = a };
        _ = w32.UpdateLayeredWindow(self.hwnd, null, null, null, null, null, 0, &blend, w32.ULW_ALPHA);
    }

    fn render(self: *HoverTint, rect: w32.RECT, c: color_math.Rgb, rim_px: i32, shape: pane_hue.Shape) bool {
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        const n: usize = @intCast(w * h);
        if (!self.ensurePx(n)) return false;
        pane_hue.renderTint(self.px[0..n], w, h, c, rim_px, shape);

        const screen_dc = w32.GetDC(null) orelse return false;
        defer _ = w32.ReleaseDC(null, screen_dc);
        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return false;
        defer _ = w32.DeleteDC(mem_dc);
        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{ .bmiHeader = .{ .biWidth = w, .biHeight = -h } };
        const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return false;
        defer _ = w32.DeleteObject(bitmap);
        const old_bmp = w32.SelectObject(mem_dc, bitmap) orelse return false;
        defer _ = w32.SelectObject(mem_dc, old_bmp);
        const dst: [*]u32 = @ptrCast(@alignCast(bits.?));
        @memcpy(dst[0..n], self.px[0..n]);

        chrome_fanout.noteMove(.dim);
        const dst_pt = w32.POINT{ .x = rect.left, .y = rect.top };
        const dst_size = w32.SIZE{ .cx = w, .cy = h };
        const src_pt = w32.POINT{ .x = 0, .y = 0 };
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = self.alpha };
        return w32.UpdateLayeredWindow(self.hwnd, screen_dc, &dst_pt, &dst_size, mem_dc, &src_pt, 0, &blend, w32.ULW_ALPHA) != 0;
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = tintWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn tintWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*HoverTint = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_TIMER => {
            if (wparam == FADE_TIMER_ID) self.fadeTick();
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
