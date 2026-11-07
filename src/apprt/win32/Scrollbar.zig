//! Vendored from InsipidPoint/ghostty-windows (MIT, same license as upstream
//! Ghostty) and adapted for the Ghoztty fork (branding, fork apprt actions).
//! Themed scrollbar for the Win32 apprt. See
//! docs/superpowers/specs/2026-04-29-win32-themed-scrollbar-design.md
//!
//! When the pane presents through a composition swap chain (T2466) the strip
//! is a child visual of the pane's visual instead of the layered popup
//! (T2492, comp_overlay.zig): the same premultiplied pixels, at the pane's
//! right edge, so a move, a fold or a divider drag is nothing to it and only a
//! resize re-places it. The popup stays alive, hidden, as the fade/idle timer
//! host and as the fallback. Its mouse input then arrives on the pane window,
//! which offers it here first (`routeMouse`) and answers it the way the
//! popup's own pixels answered Windows: the opaque track in always-visible
//! mode, only the visible thumb in overlay mode (`stripHit`).

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const FrameClock = @import("FrameClock.zig");
const pane_clip = @import("pane_clip.zig");
const terminal = @import("../../terminal/main.zig");
const Surface = @import("Surface.zig");
const chrome_fanout = @import("chrome_fanout.zig");
const comp_overlay = @import("../../renderer/comp_overlay.zig");
const banner_layout = @import("banner_layout.zig");
const testing = std.testing;

const log = std.log.scoped(.win32_scrollbar);

const SCROLLBAR_WIDTH_BASE: i32 = 14;
const SCROLLBAR_WIDTH_OVERLAY_COLLAPSED: i32 = 8;
const THUMB_MIN_HEIGHT_BASE: i32 = 20;

const FADE_TIMER_ID: usize = 1;
const IDLE_TIMER_ID: usize = 2;
const FADE_INTERVAL_MS: u32 = 16; // ~60Hz
const FADE_STEP: u8 = 32;
/// A whole 0 -> 255 fade on the compositor (T2761): the stepped path's
/// eight 32-steps at 16 ms, as one linear ramp.
const FADE_FULL_MS: u32 = 128;
const IDLE_DELAY_MS: u32 = 1000;

const ALPHA_IDLE: u8 = 80;
const ALPHA_HOVER: u8 = 140;
const ALPHA_DRAG: u8 = 200;

/// Computed thumb rectangle within the track.
pub const ThumbRect = struct { y: i32, h: i32 };

/// Where the scrollbar popup sits on screen (T1345).
pub const Placement = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn eql(a: Placement, b: Placement) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
};

/// Compute thumb_y and thumb_h given scrollback state and track height.
/// Enforces a 20-px minimum (DPI-scaled by caller via min_h).
pub fn thumbRect(
    total: usize,
    offset: usize,
    len: usize,
    track_h: i32,
    min_h: i32,
) ThumbRect {
    if (total == 0 or len >= total) {
        return .{ .y = 0, .h = track_h };
    }
    const total_f: f32 = @floatFromInt(total);
    const offset_f: f32 = @floatFromInt(offset);
    const len_f: f32 = @floatFromInt(len);
    const track_f: f32 = @floatFromInt(track_h);

    const computed_h_f = (len_f / total_f) * track_f;
    const computed_h: i32 = @intFromFloat(@round(computed_h_f));
    const h = @min(track_h, @max(min_h, computed_h));

    const computed_y_f = (offset_f / total_f) * track_f;
    var y: i32 = @intFromFloat(@round(computed_y_f));
    // Clamp so the thumb never extends past the track.
    if (y + h > track_h) y = track_h - h;
    if (y < 0) y = 0;

    return .{ .y = y, .h = h };
}

/// Compute new scroll offset from a thumb position during a drag.
/// Returns null if there's nothing to scroll (track_range <= 0 or total <= len).
pub fn dragOffset(
    mouse_y: i32,
    drag_anchor: i32,
    track_h: i32,
    thumb_h: i32,
    total: usize,
    len: usize,
) ?usize {
    if (total <= len) return null;
    const track_range = track_h - thumb_h;
    if (track_range <= 0) return null;

    const new_thumb_y = std.math.clamp(mouse_y - drag_anchor, 0, track_range);
    const range_f: f32 = @floatFromInt(track_range);
    const thumb_y_f: f32 = @floatFromInt(new_thumb_y);
    const max_off_f: f32 = @floatFromInt(total - len);

    return @intFromFloat(@round(thumb_y_f / range_f * max_off_f));
}

/// Effective alpha = base_alpha * fade / 255, saturating at 255.
pub fn effectiveAlpha(base_alpha: u8, fade: u8) u8 {
    const product: u16 = @as(u16, base_alpha) * @as(u16, fade) / 255;
    return @intCast(@min(product, 255));
}

/// How long a compositor fade from `from` to `to` runs (T2761): the full
/// ramp's rate, so a fade retargeted halfway takes half as long. At least 1.
pub fn fadeDurationMs(from: u8, to: u8) u32 {
    const dist: u32 = if (to > from) to - from else from - to;
    return @max(1, (dist * FADE_FULL_MS + 254) / 255);
}

/// Where a compositor fade is `elapsed_ms` after it began: the linear ramp
/// DirectComposition was handed, read back on this side by the clock.
pub fn fadeAt(from: u8, to: u8, elapsed_ms: i64) u8 {
    const dur: i64 = fadeDurationMs(from, to);
    if (elapsed_ms >= dur) return to;
    if (elapsed_ms <= 0) return from;
    const f: i64 = from;
    const v = f + @divTrunc((@as(i64, to) - f) * elapsed_ms, dur);
    return @intCast(std.math.clamp(v, 0, 255));
}

/// Pane mouse input the strip is offered on the visual path (T2492).
pub const MouseEvent = enum { move, down, up, leave };

/// Whether a pane-client point is the strip's on the visual path (T2492):
/// the answer the popup's own pixels gave Windows, where a fully transparent
/// pixel lets the mouse through. Always-visible paints the whole track
/// opaque; overlay mode paints only the thumb, and only while it is `lit`
/// (not faded out, where the popup was also WS_EX_TRANSPARENT).
pub fn stripHit(mode: Mode, lit: bool, strip: Placement, thumb: ThumbRect, x: i32, y: i32) bool {
    if (x < strip.x or x >= strip.x + strip.w) return false;
    if (y < strip.y or y >= strip.y + strip.h) return false;
    return switch (mode) {
        .always_visible => true,
        .overlay => lit and y - strip.y >= thumb.y and y - strip.y < thumb.y + thumb.h,
    };
}

pub const Mode = enum { overlay, always_visible };

/// Parse the registry DynamicScrollbars value into a Mode.
/// `value == null` means the value didn't exist.
pub fn parseMode(value: ?u32) Mode {
    if (value) |v| {
        return if (v == 0) .always_visible else .overlay;
    }
    return .overlay;
}

/// Read the raw DynamicScrollbars DWORD from
/// HKCU\Control Panel\Accessibility. Returns null on any error or absence.
pub fn readDynamicScrollbars() ?u32 {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Control Panel\\Accessibility");
    const valname = std.unicode.utf8ToUtf16LeStringLiteral("DynamicScrollbars");

    var hkey: w32.HKEY = undefined;
    const open_ret = w32.RegOpenKeyExW(
        w32.HKEY_CURRENT_USER,
        subkey,
        0,
        w32.KEY_READ,
        &hkey,
    );
    if (open_ret != w32.ERROR_SUCCESS) return null;
    defer _ = w32.RegCloseKey(hkey);

    var kind: u32 = 0;
    var val: u32 = 0;
    var cb: u32 = @sizeOf(u32);
    const query_ret = w32.RegQueryValueExW(
        hkey,
        valname,
        null,
        &kind,
        @ptrCast(&val),
        &cb,
    );
    if (query_ret != w32.ERROR_SUCCESS) return null;
    if (kind != w32.REG_DWORD) return null;
    return val;
}

/// Read the current mode from the registry.
pub fn readMode() Mode {
    return parseMode(readDynamicScrollbars());
}

// ---------------------------------------------------------------------------
// Scrollbar window class + struct
// ---------------------------------------------------------------------------

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyScrollbar");

/// Test-only message: SendMessage(hwnd, WM_GHOSTTY_SCROLLBAR_QUERY, 0, 0)
/// returns the current visibility state as an LRESULT.
/// 0=hidden, 1=fading_in, 2=shown, 3=fading_out.
pub const WM_GHOSTTY_SCROLLBAR_QUERY: u32 = w32.WM_USER + 1;

pub const Visibility = enum(isize) {
    hidden = 0,
    fading_in = 1,
    shown = 2,
    fading_out = 3,
};

pub const Scrollbar = struct {
    alloc: std.mem.Allocator,
    surface: *Surface,
    owner: w32.HWND,
    hwnd: w32.HWND,

    /// Latest scroll state from the core. Initially zero.
    state: terminal.Scrollbar = .zero,
    /// True until the first update() call — used to suppress fade-in on startup.
    first_update: bool = true,

    /// Current mode; re-read on WM_SETTINGCHANGE.
    mode: Mode = .overlay,

    /// Cached theme colors. Updated via setTheme.
    bg: terminal.color.RGB = .{ .r = 0, .g = 0, .b = 0 },
    fg: terminal.color.RGB = .{ .r = 255, .g = 255, .b = 255 },

    /// DPI scale (1.0 at 96 DPI).
    scale: f32 = 1.0,

    /// Visibility state (overlay mode only).
    visibility: Visibility = .hidden,
    /// Fade alpha [0..255]. Multiplied into base_alpha at paint time on the
    /// popup path; the layer's opacity on the visual path (T2761), where
    /// during a compositor fade it is where the fade started (`fadeNow`).
    fade: u8 = 0,
    /// The fade in flight (T2761): its ends, start and whether DWM runs it.
    fade_from: u8 = 0,
    fade_to: u8 = 0,
    fade_t0_ms: i64 = 0,
    fade_on_compositor: bool = false,
    /// UI-thread steps the fade in flight took (the oracle's count).
    fade_steps: u32 = 0,

    /// Hover tracking.
    hover: bool = false,
    /// Drag tracking.
    dragging: bool = false,
    drag_anchor: i32 = 0,

    /// The popup has been placed on screen at least once (T1345). Until it
    /// has, a reposition is a hidden→shown transition and still owes the
    /// z-order heal that `SWP_SHOWWINDOW` makes necessary.
    shown: bool = false,
    /// What the layered surface currently holds. `repaint` compares against
    /// this and hands the compositor a new bitmap only when the pixels would
    /// actually differ (T1345) — a vertical-divider drag moves this popup
    /// without changing a single pixel of it, and blitting anyway was one of
    /// the fan-out costs the drag measurement was looking for.
    painted: ?chrome_fanout.Signature = null,
    /// Where the popup was last placed, in screen coordinates. Only meaningful
    /// while `shown`.
    placed: Placement = .{},

    /// The pane renderer's composition tree (T2492).
    slot: ?*comp_overlay.Slot,
    layer: comp_overlay.Layer = .{},
    /// The strip is the pane's child visual rather than the popup.
    on_visual: bool = false,
    /// The strip's place in the pane's client area on the visual path.
    local: Placement = .{},
    /// The visual path's pixel rows, reused between uploads.
    pixels: std.ArrayListUnmanaged(u32) = .empty,

    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        surface: *Surface,
        slot: ?*comp_overlay.Slot,
    ) !*Scrollbar {
        try registerClassOnce(surface.app.hinstance);

        const self = try alloc.create(Scrollbar);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .surface = surface,
            .owner = owner,
            .hwnd = undefined,
            .slot = slot,
        };

        // WS_EX_LAYERED — DWM-composited above OpenGL.
        // WS_EX_NOACTIVATE — clicking us does not steal focus from the terminal.
        // WS_EX_TOOLWINDOW — keep us out of the taskbar / Alt-Tab list.
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW;
        // WS_POPUP — owned popup, follows the surface in z-order.
        const style: u32 = w32.WS_POPUP;

        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            style,
            0,
            0,
            1,
            1, // placeholder rect — repositionAndResize() sets the real one
            owner, // owner (popup, not parent)
            null,
            surface.app.hinstance,
            null,
        ) orelse return error.Win32Error;
        errdefer _ = w32.DestroyWindow(hwnd);

        // Stash self pointer in GWLP_USERDATA so the WndProc can find us.
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        self.hwnd = hwnd;

        // Read the OS mode before the first repositionAndResize so that
        // the correct width is used from the very first layout pass.
        self.mode = readMode();

        // Position and size the popup against the owner's current client
        // area. Without this, the popup stays at the (0,0,1,1) placeholder
        // until the first WM_SIZE fires on the owner — making the scrollbar
        // invisible until the user resizes the window.
        _ = self.repositionAndResize();

        return self;
    }

    pub fn destroy(self: *Scrollbar) void {
        self.layer.deinit();
        self.pixels.deinit(self.alloc);
        _ = w32.DestroyWindow(self.hwnd);
        self.alloc.destroy(self);
    }

    /// Update the cached scroll state and repaint if anything changed.
    pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void {
        const was_first = self.first_update;
        const changed =
            self.state.total != state.total or
            self.state.offset != state.offset or
            self.state.len != state.len;
        self.state = state;
        self.first_update = false;

        if (was_first) {
            self.cancelFade();
            switch (self.mode) {
                .overlay => {
                    // Initial state — silent. Start hidden + transparent.
                    // The popup is already painted with .zero placeholder (alpha=0 = invisible).
                    self.visibility = .hidden;
                    self.fade = 0;
                    self.setTransparent();
                    self.repaint(); // Re-paint with new alpha=0 + transparent style.
                },
                .always_visible => {
                    // Always-visible: show immediately at full opacity.
                    self.visibility = .shown;
                    self.fade = 255;
                    self.clearTransparent();
                    self.repaint();
                },
            }
            return;
        }

        if (changed) {
            switch (self.mode) {
                .overlay => {
                    if (self.visibility == .hidden or self.visibility == .fading_out) {
                        self.startFadeIn();
                    }
                    self.restartIdleTimer();
                },
                .always_visible => {
                    // No fade logic — always shown at full opacity.
                },
            }
            self.repaint();
        }
    }

    /// Reposition and resize the popup to stay glued to the surface.
    /// Returns the new scrollbar width.
    pub fn repositionAndResize(self: *Scrollbar) i32 {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.owner, &rect) == 0) return 0;

        // The strip runs down the grid, below the banner band a spanning
        // window carries (T2568).
        const band = self.surface.gridBand();
        const top = banner_layout.gridTop(rect.top, rect.bottom, band);
        const client_h = rect.bottom - top;
        const width = self.currentWidth();

        // The visual path (T2492): pane-local, so only the size matters. The
        // pane's visual already sits below the band, so it is in grid rows.
        if (self.syncPath()) {
            const local: @TypeOf(self.local) = .{ .x = rect.right - width, .y = banner_layout.gridY(top, band), .w = width, .h = client_h };
            // comp-present.ps1 section J's oracle: where the strip sits in
            // the pane, against the knob-off popup.
            if (!std.meta.eql(local, self.local)) log.debug("scrollbar visual at={d},{d} size={d}x{d} band={d}", .{ local.x, local.y, local.w, local.h, band });
            self.local = local;
            self.repaint();
            return switch (self.mode) {
                .always_visible => width,
                .overlay => 0,
            };
        }

        // Convert top-right corner of client area to screen coords.
        var top_right = w32.POINT{ .x = rect.right - width, .y = top };
        _ = w32.ClientToScreen(self.owner, &top_right);

        // T1345: a moved pane sends its surface BOTH `WM_MOVE` and `WM_SIZE`,
        // and both of them landed here — so a splitter drag repositioned every
        // scrollbar twice per mouse move (measured: 15 moves at 8 panes, where
        // 8 is the honest number), paying two `SetWindowPos` calls, two z-order
        // walks and two layered blits for one placement. Whichever of the two
        // messages arrives second sees the same final geometry as the first, so
        // it is answered from the cache. `dim_math.needsReposition` is the same
        // argument on the dim wash (T1295).
        const placement: Placement = .{
            .x = top_right.x,
            .y = top_right.y,
            .w = width,
            .h = client_h,
        };
        // A hidden owner keeps its scrollbar hidden (T2012), the rule the
        // banner's `updatePosition` already follows. A pane parked for undo
        // is still moved and sized, and `SWP_SHOWWINDOW` below would put its
        // scrollbar back over the neighbour that took its place. It is still
        // PLACED, hidden, so the owner's WM_SHOWWINDOW brings it back where
        // the pane now is rather than where it last was. The same holds while
        // part of the pane lies outside its window (T2227): a folding card
        // slides out past the edge, the window clips the pane and nothing
        // clips this popup.
        if (!pane_clip.ownerWhollyInView(self.owner)) {
            if (!Placement.eql(self.placed, placement) or self.shown) {
                _ = w32.SetWindowPos(
                    self.hwnd,
                    null,
                    placement.x,
                    placement.y,
                    placement.w,
                    placement.h,
                    w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_HIDEWINDOW,
                );
                self.shown = false;
                self.placed = placement;
            }
        } else if (chrome_fanout.moveNeeded(self.shown, Placement.eql(self.placed, placement))) {
            const was_shown = self.shown;
            chrome_fanout.noteMove(.scrollbar);
            const clock = chrome_fanout.startMoveClock();
            _ = w32.SetWindowPos(
                self.hwnd,
                null,
                placement.x,
                placement.y,
                placement.w,
                placement.h,
                w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW,
            );
            chrome_fanout.stopMoveClock(clock);
            self.shown = true;
            self.placed = placement;
            // Every reposition re-checks the z-order instead of leaving it to
            // whatever last touched it (T142) — except inside a live layout
            // pass, where an already-shown popup cannot have moved in the
            // z-order and the walk is the fan-out's biggest per-pane cost
            // (T1345).
            w32.healOverlayZOrderAfterMove(self.hwnd, self.owner, was_shown);
        }

        // Always asked, never unconditional: the pixels can change with the
        // scroll state while the popup has not moved at all, and `repaint`
        // decides for itself whether the compositor already holds this bitmap.
        self.repaint();

        // Return the width that the caller should subtract from the grid area.
        // Always-visible steals a column of grid space; overlay floats on top.
        return switch (self.mode) {
            .always_visible => width,
            .overlay => 0,
        };
    }

    /// Show or hide the popup when the owner surface is shown/hidden.
    pub fn setOwnerVisible(self: *Scrollbar, visible: bool) void {
        if (self.on_visual) {
            // Inside the pane, which clips and hides it with itself; this
            // keeps the layer's on/off honest for a pane that leaves the
            // layout (T2012) and comes back.
            if (visible) self.repaint() else if (self.layer.attached) {
                self.layer.setVisible(false);
                log.info("scrollbar hidden visual=true", .{});
            }
            return;
        }
        // Not over a pane that is partly outside its window (T2227): an
        // unfolding card is shown at its tucked place, past the edge. Its
        // clip, not its visibility - this runs on WM_SHOWWINDOW, before the
        // owner reads visible. The move that brings it in view re-shows it.
        const show = visible and pane_clip.ownerClip(self.owner) == .whole;
        _ = w32.ShowWindow(self.hwnd, if (show) w32.SW_SHOWNOACTIVATE else w32.SW_HIDE);
        // A hidden popup owes the z-order heal again when it comes back:
        // `SWP_SHOWWINDOW` lifts it above unrelated windows, which is the
        // T142 case the heal exists for (T1345).
        if (!show) self.shown = false;
    }

    /// Off screen now - the same as the owner being hidden. The uniform name
    /// `Surface.hideOverlays` calls on every pane popup (T2012).
    pub fn hide(self: *Scrollbar) void {
        self.setOwnerVisible(false);
    }

    /// Update cached theme colors and repaint if they changed.
    pub fn setTheme(self: *Scrollbar, bg: terminal.color.RGB, fg: terminal.color.RGB) void {
        if (std.meta.eql(self.bg, bg) and std.meta.eql(self.fg, fg)) return;
        self.bg = bg;
        self.fg = fg;
        self.repaint();
    }

    fn dpiScaled(self: *const Scrollbar, base: i32) i32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(base)) * self.scale));
    }

    fn currentWidth(self: *const Scrollbar) i32 {
        return switch (self.mode) {
            .always_visible => self.dpiScaled(SCROLLBAR_WIDTH_BASE),
            .overlay => if (self.hover or self.dragging)
                self.dpiScaled(SCROLLBAR_WIDTH_BASE)
            else
                self.dpiScaled(SCROLLBAR_WIDTH_OVERLAY_COLLAPSED),
        };
    }

    /// What this scrollbar's layered surface WOULD hold if it were painted
    /// right now (T1345). Two equal signatures mean the blit would hand the
    /// compositor the bitmap it is already showing.
    fn signature(self: *const Scrollbar, w: i32, h: i32) chrome_fanout.Signature {
        const r = thumbRect(
            self.state.total,
            self.state.offset,
            self.state.len,
            h,
            self.dpiScaled(THUMB_MIN_HEIGHT_BASE),
        );
        return .{
            .width = w,
            .height = h,
            .fill = switch (self.mode) {
                .always_visible => packBGRA(self.bg, 255),
                .overlay => 0,
            },
            .accent = packBGRA(self.fg, self.thumbAlpha()),
            .accent_y = r.y,
            .accent_h = r.h,
        };
    }

    fn repaint(self: *Scrollbar) void {
        if (self.on_visual) return self.repaintVisual();
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &client) == 0) return;
        const w = client.right - client.left;
        const h = client.bottom - client.top;
        if (w <= 0 or h <= 0) return;

        // A splitter drag repositions this popup on every mouse move, and
        // every reposition used to re-blit it — a whole BGRA bitmap handed to
        // the compositor per pane per frame of drag, even when the bitmap was
        // identical to the one already on screen (dragging a VERTICAL divider
        // changes the scrollbar's x, not one of its pixels). T1345: blit only
        // when the pixels or the size would actually differ. Size is the
        // load-bearing half — a popup that was resized keeps its old layered
        // surface until something hands over a new one, and leaving that stale
        // is the stretched-content defect T1343 was told not to reintroduce.
        const sig = self.signature(w, h);
        if (!chrome_fanout.blitNeeded(self.painted, sig)) {
            chrome_fanout.noteBlitSkipped();
            return;
        }

        // Allocate a temp BGRA buffer, fill it, blit via UpdateLayeredWindow.
        const screen_dc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, screen_dc);

        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);

        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{
            .bmiHeader = .{
                .biWidth = w,
                // Negative for top-down DIB so row 0 is the top row.
                .biHeight = -h,
            },
        };

        const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
        defer _ = w32.DeleteObject(bitmap);

        const old = w32.SelectObject(mem_dc, bitmap);
        defer _ = w32.SelectObject(mem_dc, old.?);

        self.drawBitmap(@ptrCast(@alignCast(bits.?)), w, h);

        var window_rect: w32.RECT = undefined;
        _ = w32.GetWindowRect(self.hwnd, &window_rect);
        const dst_pt = w32.POINT{ .x = window_rect.left, .y = window_rect.top };
        const dst_size = w32.SIZE{ .cx = w, .cy = h };
        const src_pt = w32.POINT{ .x = 0, .y = 0 };
        const blend = w32.BLENDFUNCTION{
            .SourceConstantAlpha = 255, // per-pixel alpha only
        };

        chrome_fanout.noteBlit();
        _ = w32.UpdateLayeredWindow(
            self.hwnd,
            screen_dc,
            &dst_pt,
            &dst_size,
            mem_dc,
            &src_pt,
            0,
            &blend,
            w32.ULW_ALPHA,
        );
        self.painted = sig;
    }

    /// The visual path's half of `repaint` (T2492): the same signature check
    /// and the same pixels, handed to the pane's composition layer instead of
    /// UpdateLayeredWindow. A rebuilt tree (`hasPixels` false) or a detached
    /// layer always re-uploads.
    fn repaintVisual(self: *Scrollbar) void {
        const w = self.local.w;
        const h = self.local.h;
        if (w <= 0 or h <= 0) return;
        const sig = self.signature(w, h);
        const rebuilt = !self.layer.hasPixels();
        const fresh = rebuilt or !self.layer.attached;
        // The fade is the layer's opacity here (T2761), not the pixels', so
        // the pixels hold still through it. A compositor fade in flight owns
        // the opacity; a static set would cut it short.
        if (!self.compositorFading()) self.layer.setOpacity(self.fade);
        if (!fresh and !chrome_fanout.blitNeeded(self.painted, sig)) {
            chrome_fanout.noteBlitSkipped();
            _ = self.layer.setOffset(self.local.x, self.local.y);
            return;
        }
        const n: usize = @intCast(w * h);
        self.pixels.resize(self.alloc, n) catch return;
        self.drawBitmap(self.pixels.items.ptr, w, h);
        chrome_fanout.noteBlit();
        _ = self.layer.setOffset(self.local.x, self.local.y);
        if (!self.layer.setPixels(self.pixels.items, @intCast(w), @intCast(h))) {
            log.warn("scrollbar visual upload failed", .{});
            return;
        }
        self.painted = sig;
        // A rebuilt tree (the renderer remade its chain) lost the declared
        // fade with the old visual: carry on from where it had got to.
        if (rebuilt and self.compositorFading()) self.redeclareFade();
        if (!self.layer.attached) {
            self.layer.setVisible(true);
            log.info("scrollbar shown as visual w={d} h={d}", .{ w, h });
        }
    }

    /// Bring the strip onto the pane's composition tree, or back to the
    /// popup when there is none (T2492). True: the visual path.
    fn syncPath(self: *Scrollbar) bool {
        const want = if (self.slot) |s| self.layer.sync(s) else false;
        if (want != self.on_visual) {
            // Leaving either path ends a drag and a hover on it.
            if (self.dragging) _ = w32.ReleaseCapture();
            if (want) {
                // Off the popup at once; it stays alive for its timers.
                _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
                self.shown = false;
            } else {
                // A retracted tree already took the visual with it.
                self.layer.setVisible(false);
            }
            self.dragging = false;
            self.hover = false;
            // A compositor fade does not cross paths: the popup steps the
            // rest of it from where it had got to (T2761).
            if (self.compositorFading()) {
                self.fade = self.fadeNow();
                self.fade_on_compositor = false;
                _ = FrameClock.arm(self.hwnd, FADE_TIMER_ID, FADE_INTERVAL_MS);
            }
            self.on_visual = want;
            self.painted = null;
            log.info("scrollbar path visual={}", .{want});
        }
        return want;
    }

    /// The pane's composition tree was published or retracted (T2492):
    /// take the strip onto it, or back to the popup, and place it.
    pub fn onTreeChanged(self: *Scrollbar) void {
        _ = self.repositionAndResize();
    }

    /// The window the strip's mouse input arrives on: the popup's own, or
    /// the pane's on the visual path.
    fn inputHwnd(self: *const Scrollbar) w32.HWND {
        return if (self.on_visual) self.owner else self.hwnd;
    }

    /// Whether a point in the pane's client area is the strip's on the
    /// visual path (T2492).
    pub fn hitVisual(self: *const Scrollbar, x: i32, y: i32) bool {
        return self.hitGrid(x, banner_layout.gridY(y, self.surface.gridBand()));
    }

    /// `hitVisual` for a point already in the visual's (grid) rows.
    fn hitGrid(self: *const Scrollbar, x: i32, y: i32) bool {
        if (!self.on_visual or !self.layer.attached) return false;
        const r = thumbRect(self.state.total, self.state.offset, self.state.len, self.local.h, self.dpiScaled(THUMB_MIN_HEIGHT_BASE));
        const lit = self.visibility != .hidden and self.shownAlpha() > 0;
        return stripHit(self.mode, lit, self.local, r, x, y);
    }

    /// Mouse input on the pane window, offered to the strip first on the
    /// visual path (T2492). `x`/`y` are pane client coordinates. True: it was
    /// the strip's, and the terminal must not see it. A drag keeps every move
    /// and the release wherever the cursor has gone, as its capture does.
    pub fn routeMouse(self: *Scrollbar, ev: MouseEvent, x: i32, y: i32) bool {
        if (!self.on_visual) return false;
        // Pane client rows to the visual's, which start below the band.
        const gy = banner_layout.gridY(y, self.surface.gridBand());
        const ly = gy - self.local.y;
        if (self.dragging) {
            switch (ev) {
                .move => self.onMouseMove(x, ly),
                .up => self.onLeftUp(),
                .down, .leave => {},
            }
            return ev != .leave;
        }
        switch (ev) {
            .move => {
                if (self.hitVisual(x, y)) {
                    self.onMouseMove(x, ly);
                    return true;
                }
                if (self.hover) self.onMouseLeave();
                return false;
            },
            .down => {
                if (!self.hitVisual(x, y)) return false;
                self.onLeftDown(ly);
                return true;
            },
            .up => return false,
            .leave => {
                if (self.hover) self.onMouseLeave();
                return false;
            },
        }
    }

    fn drawBitmap(self: *Scrollbar, pixels: [*]u32, w: i32, h: i32) void {
        // Premultiplied BGRA. Layout per pixel: 0xAARRGGBB.
        // Overlay mode: track is fully transparent; only the thumb is painted.
        // Always-visible mode: track is filled with the opaque background color.

        const track_fill: u32 = switch (self.mode) {
            .always_visible => packBGRA(self.bg, 255),
            .overlay => 0,
        };

        const total = w * h;
        var i: i32 = 0;
        while (i < total) : (i += 1) {
            pixels[@intCast(i)] = track_fill;
        }

        const min_h = self.dpiScaled(THUMB_MIN_HEIGHT_BASE);
        const r = thumbRect(self.state.total, self.state.offset, self.state.len, h, min_h);

        const thumb_alpha = self.thumbAlpha();
        const thumb_color = packBGRA(self.fg, thumb_alpha);

        var y: i32 = r.y;
        while (y < r.y + r.h and y < h) : (y += 1) {
            var x: i32 = 0;
            while (x < w) : (x += 1) {
                pixels[@intCast(y * w + x)] = thumb_color;
            }
        }
    }

    /// The thumb's alpha in the pixels. On the visual path the fade is the
    /// layer's opacity instead (T2761), so the pixels carry the base alone.
    fn thumbAlpha(self: *const Scrollbar) u8 {
        const base = self.baseAlpha();
        return switch (self.mode) {
            .always_visible => base,
            .overlay => if (self.on_visual) base else effectiveAlpha(base, self.fade),
        };
    }

    /// The thumb's alpha as it is on screen right now, whichever path.
    fn shownAlpha(self: *const Scrollbar) u8 {
        const base = self.baseAlpha();
        return switch (self.mode) {
            .always_visible => base,
            .overlay => effectiveAlpha(base, self.fadeNow()),
        };
    }

    fn baseAlpha(self: *const Scrollbar) u8 {
        return if (self.dragging) ALPHA_DRAG else if (self.hover) ALPHA_HOVER else ALPHA_IDLE;
    }

    fn ensureLeaveTracking(self: *Scrollbar) void {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.inputHwnd(),
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
    }

    fn trackHeight(self: *const Scrollbar) i32 {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &rect) == 0) return 0;
        return rect.bottom - rect.top;
    }

    fn currentThumbRect(self: *const Scrollbar) ThumbRect {
        return thumbRect(
            self.state.total,
            self.state.offset,
            self.state.len,
            self.trackHeight(),
            self.dpiScaled(THUMB_MIN_HEIGHT_BASE),
        );
    }

    fn onMouseMove(self: *Scrollbar, x: i32, y: i32) void {
        _ = x;
        if (self.visibility == .hidden or self.visibility == .fading_out) {
            self.startFadeIn();
        }
        self.ensureLeaveTracking();

        if (self.dragging) {
            if (dragOffset(
                y,
                self.drag_anchor,
                self.trackHeight(),
                self.currentThumbRect().h,
                self.state.total,
                self.state.len,
            )) |off| {
                self.state.offset = off;
                self.surface.scrollToOffset(off);
                self.repaint();
            }
            return;
        }

        if (!self.hover) {
            self.hover = true;
            self.repaint();
        }
    }

    fn onMouseLeave(self: *Scrollbar) void {
        if (self.hover) {
            self.hover = false;
            self.repaint();
        }
        if (!self.dragging) self.restartIdleTimer();
    }

    fn onLeftDown(self: *Scrollbar, y: i32) void {
        const r = self.currentThumbRect();
        if (y >= r.y and y < r.y + r.h) {
            // Drag.
            _ = w32.SetCapture(self.inputHwnd());
            log.info("scrollbar drag start visual={}", .{self.on_visual});
            self.drag_anchor = y - r.y;
            self.dragging = true;
        } else {
            // Page click.
            const total = self.state.total;
            const len = self.state.len;
            if (total <= len) return;
            const max = total - len;
            const new_off = if (y < r.y)
                (if (self.state.offset > len) self.state.offset - len else 0)
            else
                @min(self.state.offset + len, max);
            self.state.offset = new_off;
            self.surface.scrollToOffset(new_off);
            self.repaint();
        }
    }

    fn onLeftUp(self: *Scrollbar) void {
        if (self.dragging) {
            _ = w32.ReleaseCapture();
            self.dragging = false;
            log.info("scrollbar drag end visual={} offset={d}", .{ self.on_visual, self.state.offset });
            self.repaint();
        }
    }

    /// Called on WM_SETTINGCHANGE. Returns true if a mode change
    /// requires the terminal grid to be re-flowed.
    pub fn onSettingsChange(self: *Scrollbar) bool {
        const new_mode = readMode();
        if (new_mode == self.mode) return false;

        self.mode = new_mode;

        // Apply the initial state for the new mode.
        self.cancelFade();
        switch (new_mode) {
            .overlay => {
                self.visibility = .hidden;
                self.fade = 0;
                self.setTransparent();
                self.repaint();
            },
            .always_visible => {
                self.visibility = .shown;
                self.fade = 255;
                self.clearTransparent();
                self.repaint();
            },
        }

        // Mode changed — caller must reflow the grid (trigger WM_SIZE).
        return true;
    }

    /// Update the DPI scale factor.
    pub fn onDpiChanged(self: *Scrollbar, dpi: u32) void {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    fn startFadeIn(self: *Scrollbar) void {
        self.clearTransparent();
        self.startFade(255);
    }

    fn startFadeOut(self: *Scrollbar) void {
        self.startFade(0);
    }

    /// Fade toward `to` from wherever the fade is now. On the visual path the
    /// whole ramp is declared to DirectComposition at once and DWM runs it at
    /// the display's refresh, with one timer for its end (T2761); otherwise,
    /// or when the layer cannot take it, it is stepped on the frame clock.
    fn startFade(self: *Scrollbar, to: u8) void {
        self.visibility = if (to == 255) .fading_in else .fading_out;
        const now = self.fadeNow();
        self.fade = now;
        self.fade_from = now;
        self.fade_to = to;
        self.fade_t0_ms = std.time.milliTimestamp();
        self.fade_steps = 0;
        self.fade_on_compositor = false;
        FrameClock.disarm(self.hwnd, FADE_TIMER_ID);
        // Pixels and placement first: a strip going up for the first time
        // is attached at the fade's current value, then the ramp declared.
        self.repaint();
        if (self.on_visual and self.layer.attached and self.declareFade()) {
            self.fade_on_compositor = true;
            const ms = fadeDurationMs(self.fade_from, to);
            log.info("scrollbar fade on compositor from={d} to={d} ms={d}", .{ self.fade_from, to, ms });
            _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, ms, null);
        } else {
            _ = FrameClock.arm(self.hwnd, FADE_TIMER_ID, FADE_INTERVAL_MS);
        }
        debugStall();
    }

    /// Declare `fade_from` -> `fade_to` as one linear opacity ramp. False:
    /// nothing was declared and the caller steps the fade.
    fn declareFade(self: *Scrollbar) bool {
        // `GHOZTTY_DEBUG_SCROLLBAR_FADE_STEPPED=1` (debug builds): step the
        // visual's fade on this thread instead - the oracle's A/B arm.
        if (comptime builtin.mode == .Debug) {
            if (std.process.hasNonEmptyEnvVarConstant("GHOZTTY_DEBUG_SCROLLBAR_FADE_STEPPED")) return false;
        }
        const dur_s = @as(f64, @floatFromInt(fadeDurationMs(self.fade_from, self.fade_to))) / 1000.0;
        // A straight line is one cubic, exactly: 0 -> 1 over the duration.
        const ramp = [_]comp_overlay.Cubic{.{ .begin_s = 0, .c0 = 0, .c1 = 1 / dur_s, .c2 = 0, .c3 = 0 }};
        if (self.layer.animateOpacity(self.fade_from, self.fade_to, &ramp, dur_s)) return true;
        log.warn("scrollbar fade could not go on the compositor; stepping it", .{});
        return false;
    }

    /// The tree was rebuilt mid-fade: the new layer starts from the value
    /// the fade had reached and runs the rest of it.
    fn redeclareFade(self: *Scrollbar) void {
        const now = self.fadeNow();
        self.fade = now;
        self.fade_from = now;
        self.fade_t0_ms = std.time.milliTimestamp();
        self.layer.setOpacity(now);
        if (self.declareFade()) {
            _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, fadeDurationMs(now, self.fade_to), null);
            return;
        }
        self.fade_on_compositor = false;
        _ = FrameClock.arm(self.hwnd, FADE_TIMER_ID, FADE_INTERVAL_MS);
    }

    fn compositorFading(self: *const Scrollbar) bool {
        return self.fade_on_compositor and
            (self.visibility == .fading_in or self.visibility == .fading_out);
    }

    /// The fade's value on screen now. A compositor fade's lives in DWM, so
    /// this side reads it off the ramp by the clock; a stepped one's is
    /// already `fade`.
    fn fadeNow(self: *const Scrollbar) u8 {
        if (!self.compositorFading()) return self.fade;
        return fadeAt(self.fade_from, self.fade_to, std.time.milliTimestamp() - self.fade_t0_ms);
    }

    /// Drop any fade in flight; the caller sets `fade` and `visibility`.
    fn cancelFade(self: *Scrollbar) void {
        FrameClock.disarm(self.hwnd, FADE_TIMER_ID);
        self.fade_on_compositor = false;
    }

    /// `GHOZTTY_DEBUG_SCROLLBAR_FADE_STALL_MS=<n>` (debug builds, T2761):
    /// block this thread for n ms the moment a fade starts - the oracle's
    /// stand-in for a busy UI thread. A compositor fade moves through it; a
    /// stepped one freezes.
    fn debugStall() void {
        if (comptime builtin.mode != .Debug) return;
        const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_DEBUG_SCROLLBAR_FADE_STALL_MS") catch return;
        defer std.heap.page_allocator.free(raw);
        const ms = std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return;
        if (ms == 0) return;
        log.info("scrollbar debug stall ms={d}", .{ms});
        std.Thread.sleep(@as(u64, @min(ms, 5000)) * std.time.ns_per_ms);
    }

    fn restartIdleTimer(self: *Scrollbar) void {
        _ = w32.SetTimer(self.hwnd, IDLE_TIMER_ID, IDLE_DELAY_MS, null);
    }

    fn onFadeTick(self: *Scrollbar) void {
        if (self.visibility != .fading_in and self.visibility != .fading_out) {
            self.cancelFade();
            return;
        }
        const elapsed = std.time.milliTimestamp() - self.fade_t0_ms;
        if (self.fade_on_compositor) {
            // The one end-of-fade tick. Early: wait out the rest; the
            // compositor already holds the final value.
            const ms = fadeDurationMs(self.fade_from, self.fade_to);
            if (elapsed < ms) {
                _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, @intCast(@as(i64, ms) - elapsed), null);
                return;
            }
            self.fade = self.fade_to;
        } else {
            self.fade_steps += 1;
            self.fade = if (self.visibility == .fading_in)
                @intCast(@min(@as(u16, self.fade) + FADE_STEP, 255))
            else if (self.fade > FADE_STEP) self.fade - FADE_STEP else 0;
        }
        const done = (self.visibility == .fading_in and self.fade == 255) or
            (self.visibility == .fading_out and self.fade == 0);
        if (done) {
            FrameClock.disarm(self.hwnd, FADE_TIMER_ID);
            log.info("scrollbar fade done fade={d} ms={d} compositor={} ui_steps={d}", .{ self.fade, elapsed, self.fade_on_compositor, self.fade_steps });
            self.fade_on_compositor = false;
            self.visibility = if (self.fade == 255) .shown else .hidden;
            if (self.fade == 0) self.setTransparent();
        }
        self.repaint();
    }

    fn onIdleTick(self: *Scrollbar) void {
        _ = w32.KillTimer(self.hwnd, IDLE_TIMER_ID);
        if (self.dragging or self.hover) return;
        self.startFadeOut();
    }

    fn setTransparent(self: *Scrollbar) void {
        const cur = w32.GetWindowLongW(self.hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(self.hwnd, w32.GWL_EXSTYLE, cur | w32.WS_EX_TRANSPARENT);
    }

    fn clearTransparent(self: *Scrollbar) void {
        const cur = w32.GetWindowLongW(self.hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(self.hwnd, w32.GWL_EXSTYLE, cur & ~w32.WS_EX_TRANSPARENT);
    }
};

/// Pack RGB + alpha into premultiplied BGRA (UpdateLayeredWindow expects
/// premultiplied per-pixel alpha).
fn packBGRA(c: terminal.color.RGB, a: u8) u32 {
    // Premultiply: each channel *= a / 255.
    const af: f32 = @as(f32, @floatFromInt(a)) / 255.0;
    const r: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.r)) * af));
    const g: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.g)) * af));
    const b: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.b)) * af));
    return (@as(u32, a) << 24) | (r << 16) | (g << 8) | b;
}

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = scrollbarWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // we paint via UpdateLayeredWindow
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn scrollbarWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*Scrollbar = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_TIMER => {
            switch (wparam) {
                FADE_TIMER_ID => self.onFadeTick(),
                IDLE_TIMER_ID => self.onIdleTick(),
                else => {},
            }
            return 0;
        },

        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
            self.onMouseMove(x, y);
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            self.onMouseLeave();
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
            self.onLeftDown(y);
            return 0;
        },

        w32.WM_LBUTTONUP => {
            self.onLeftUp();
            return 0;
        },

        WM_GHOSTTY_SCROLLBAR_QUERY => return @intFromEnum(self.visibility),

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "thumbRect: thumb at top when offset is 0" {
    const r = thumbRect(1000, 0, 50, 400, 20);
    try testing.expectEqual(@as(i32, 0), r.y);
    try testing.expectEqual(@as(i32, 20), r.h); // 50/1000 * 400 = 20
}

test "thumbRect: thumb at bottom when offset = total - len" {
    const r = thumbRect(1000, 950, 50, 400, 20);
    // (950/1000) * 400 = 380; thumb_h = 20; bottom = 400. OK.
    try testing.expectEqual(@as(i32, 380), r.y);
    try testing.expectEqual(@as(i32, 20), r.h);
}

test "thumbRect: enforces minimum height" {
    // len/total = 1/10000, computed_h = 0; floor of min is 20.
    const r = thumbRect(10000, 0, 1, 400, 20);
    try testing.expectEqual(@as(i32, 20), r.h);
}

test "thumbRect: total == 0 returns full track" {
    const r = thumbRect(0, 0, 0, 400, 20);
    try testing.expectEqual(@as(i32, 0), r.y);
    try testing.expectEqual(@as(i32, 400), r.h);
}

test "dragOffset: top of track" {
    const off = dragOffset(0, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 0), off);
}

test "dragOffset: bottom of track" {
    // mouse_y = 380 (track_range = 400 - 20 = 380); should land at total - len = 950.
    const off = dragOffset(380, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 950), off);
}

test "dragOffset: middle of track" {
    const off = dragOffset(190, 0, 400, 20, 1000, 50).?;
    // 190/380 * 950 ≈ 475
    try testing.expectEqual(@as(usize, 475), off);
}

test "dragOffset: clamped above" {
    const off = dragOffset(-100, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 0), off);
}

test "dragOffset: clamped below" {
    const off = dragOffset(99999, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 950), off);
}

test "dragOffset: returns null when total <= len" {
    try testing.expectEqual(@as(?usize, null), dragOffset(50, 0, 400, 20, 50, 100));
    try testing.expectEqual(@as(?usize, null), dragOffset(50, 0, 400, 20, 50, 50));
}

test "dragOffset: returns null when thumb fills track" {
    // thumb_h == track_h → track_range == 0
    try testing.expectEqual(@as(?usize, null), dragOffset(0, 0, 400, 400, 1000, 50));
}

test "fadeDurationMs: the full ramp is the stepped path's 128 ms, a part of it its share" {
    try testing.expectEqual(@as(u32, 128), fadeDurationMs(0, 255));
    try testing.expectEqual(@as(u32, 128), fadeDurationMs(255, 0));
    try testing.expectEqual(@as(u32, 65), fadeDurationMs(0, 128));
    try testing.expectEqual(@as(u32, 1), fadeDurationMs(77, 77));
}

test "fadeAt: linear between its ends, clamped outside them" {
    try testing.expectEqual(@as(u8, 0), fadeAt(0, 255, -5));
    try testing.expectEqual(@as(u8, 0), fadeAt(0, 255, 0));
    try testing.expectEqual(@as(u8, 127), fadeAt(0, 255, 64));
    try testing.expectEqual(@as(u8, 255), fadeAt(0, 255, 128));
    try testing.expectEqual(@as(u8, 255), fadeAt(0, 255, 9999));
    try testing.expectEqual(@as(u8, 128), fadeAt(255, 0, 64));
    try testing.expectEqual(@as(u8, 0), fadeAt(255, 0, 128));
    // A retarget from halfway runs the rest at the same rate.
    try testing.expectEqual(@as(u8, 255), fadeAt(128, 255, fadeDurationMs(128, 255)));
    try testing.expectEqual(@as(u32, 64), fadeDurationMs(128, 255));
}

test "effectiveAlpha: full fade" {
    try testing.expectEqual(@as(u8, 80), effectiveAlpha(80, 255));
}

test "effectiveAlpha: half fade" {
    try testing.expectEqual(@as(u8, 40), effectiveAlpha(80, 128));
}

test "effectiveAlpha: zero fade" {
    try testing.expectEqual(@as(u8, 0), effectiveAlpha(80, 0));
}

test "parseMode: missing value defaults to overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(null));
}

test "parseMode: 1 is overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(1));
}

test "parseMode: 0 is always_visible" {
    try testing.expectEqual(Mode.always_visible, parseMode(0));
}

test "thumbRect: clamps when min_h exceeds track_h" {
    // Tiny track + normal min_h: h should not exceed track_h.
    const r = thumbRect(1000, 0, 50, 10, 20);
    try testing.expect(r.h <= 10);
    try testing.expect(r.y + r.h <= 10);
}

test "thumbRect: clamps when offset would push thumb past bottom" {
    // offset=999 → naive y = round(999/1000 * 400) = 400; with h=20 the
    // thumb would extend to 420. Clamp must pull y back to track_h - h = 380.
    const r = thumbRect(1000, 999, 50, 400, 20);
    try testing.expectEqual(@as(i32, 380), r.y);
    try testing.expectEqual(@as(i32, 20), r.h);
    try testing.expect(r.y + r.h <= 400);
}

test "dragOffset: applies drag_anchor" {
    // drag_anchor=100 should be equivalent to mouse_y shifted by -100.
    const a = dragOffset(190, 100, 400, 20, 1000, 50).?;
    const b = dragOffset(90, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(b, a);
}

test "dragOffset: rounds half to nearest" {
    // mouse_y=191, drag_anchor=0 → 191/380 * 950 = 477.5 → 478 (round-half-to-even rounds .5 up here).
    const off = dragOffset(191, 0, 400, 20, 1000, 50).?;
    try testing.expect(off == 477 or off == 478);
}

test "parseMode: non-{0,1} value treated as overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(2));
    try testing.expectEqual(Mode.overlay, parseMode(99));
}

test "stripHit: outside the strip is never the scrollbar's" {
    const strip: Placement = .{ .x = 492, .y = 0, .w = 8, .h = 300 };
    const thumb: ThumbRect = .{ .y = 0, .h = 300 };
    try testing.expect(!stripHit(.always_visible, true, strip, thumb, 491, 10));
    try testing.expect(!stripHit(.always_visible, true, strip, thumb, 500, 10));
    try testing.expect(!stripHit(.always_visible, true, strip, thumb, 495, 300));
    try testing.expect(stripHit(.always_visible, true, strip, thumb, 492, 0));
    try testing.expect(stripHit(.always_visible, true, strip, thumb, 499, 299));
}

test "stripHit: always-visible takes the whole track, overlay only the lit thumb" {
    const strip: Placement = .{ .x = 100, .y = 0, .w = 14, .h = 200 };
    const thumb: ThumbRect = .{ .y = 150, .h = 50 };
    // The track above the thumb: opaque in always-visible, see-through in overlay.
    try testing.expect(stripHit(.always_visible, false, strip, thumb, 105, 20));
    try testing.expect(!stripHit(.overlay, true, strip, thumb, 105, 20));
    // The thumb: the overlay's only opaque pixels, while lit.
    try testing.expect(stripHit(.overlay, true, strip, thumb, 105, 150));
    try testing.expect(stripHit(.overlay, true, strip, thumb, 105, 199));
    // Faded out: transparent, so the terminal gets it.
    try testing.expect(!stripHit(.overlay, false, strip, thumb, 105, 160));
}
