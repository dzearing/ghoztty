//! Unfocused-split dim overlay (T74). Implements the Mac/GTK
//! `unfocused-split-opacity` / `unfocused-split-fill` behavior: unfocused
//! panes of a split get a uniform semi-transparent rectangle over them so
//! the focused pane stands out.
//!
//! Like Scrollbar.zig, each overlay is a WS_EX_LAYERED popup owned by its
//! surface HWND — DWM composites it above the surface's OpenGL content,
//! which a plain child window cannot reliably do. WS_EX_TRANSPARENT makes
//! it click-through: a click on a dimmed pane lands on the pane itself,
//! which focuses it (and Window.updateDimOverlays then hides the overlay).
//! Uniform dimming needs no per-pixel alpha, so this uses the simpler
//! SetLayeredWindowAttributes(LWA_ALPHA) + solid-brush paint instead of
//! the scrollbar's UpdateLayeredWindow DIB path. Pure decision/alpha
//! logic is in dim_math.zig (unit tested in every lane).

const std = @import("std");
const w32 = @import("win32.zig");
const dim_math = @import("dim_math.zig");
const chrome_fanout = @import("chrome_fanout.zig");
const pane_clip = @import("pane_clip.zig");
const FrameClock = @import("FrameClock.zig");
const lab_plant = @import("lab_plant.zig");

const log = std.log.scoped(.win32_dim_overlay);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyDimOverlay");

pub const DimOverlay = struct {
    alloc: std.mem.Allocator,
    /// The surface HWND this overlay covers (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,

    /// Cached fill brush + its COLORREF, recreated when the config color
    /// changes. The WndProc paints with it.
    brush: ?w32.HBRUSH = null,
    color: u32 = 0,
    /// Last alpha applied via SetLayeredWindowAttributes. 0 = never
    /// applied (show() never runs with alpha 0 — shouldDim requires > 0),
    /// so the first show() always sets the layered attributes.
    alpha: u8 = 0,
    /// The overlay is on screen at `placement` (T1295). `hide()` clears it,
    /// so the show after a hide always repositions.
    shown: bool = false,
    /// The placement last handed to SetWindowPos. Only meaningful while
    /// `shown`.
    placement: dim_math.Placement = .{ .left = 0, .top = 0, .width = 0, .height = 0 },
    /// The owner's region this wash was last clipped to (T1831); see
    /// `matchOwnerRegion`.
    region_key: u64 = 0,
    /// The banner band above the owner the wash also covers (T2308);
    /// `setBand` feeds it before every `show`.
    band: Band = .{},
    /// The shape the window region was last cut for; `applyRegion` runs when
    /// it changes.
    shape: Shape = .{},

    /// The frame lab's planted overlay lag (T2383, `lab_plant.zig`): how many
    /// times this wash has moved, the frame-clock ticks left before a held
    /// wash catches up (0 = not held), and the colour and alpha the latest
    /// `show` asked for, which the catch-up re-applies.
    lab_moves: u32 = 0,
    lab_hold: u8 = 0,
    lab_color: u32 = 0,
    lab_alpha: u8 = 0,

    /// The frame-clock subscription that releases a held wash. Its own
    /// window's id space, so it cannot collide with `msg_timer`'s.
    const LAB_HOLD_TIMER_ID: usize = 1;

    /// A pane's banner strip sits in a band the layout reserves ABOVE the
    /// terminal's window (T101). Mac's unfocused-split dim is the last layer
    /// of the whole pane - terminal, frozen terminal and banner alike
    /// (`SurfaceView`'s ZStack) - so the wash grows upward over that band.
    pub const Band = struct {
        /// The band's height, px. 0 = no banner.
        height: i32 = 0,
        /// The banner strip's top-corner diameter (`BannerOverlay.card_corner`):
        /// the band's top corners are the elevated card's, and the wash takes
        /// the same cut (T1851). 0 = square.
        corner: i32 = 0,
    };

    /// What the window region is cut from: where this popup's top-left sits
    /// inside the owner - (0, -band) over a banner (T2308), or the part in
    /// view of a pane partly outside its window (T2227) - plus the band's
    /// own shape.
    pub const Shape = struct {
        origin_x: i32 = 0,
        origin_y: i32 = 0,
        band: i32 = 0,
        corner: i32 = 0,
        /// The popup's width, kept only while the band has a rounded cut,
        /// whose right corner moves with it.
        width: i32 = 0,
    };
    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        hinstance: w32.HINSTANCE,
    ) !*DimOverlay {
        try registerClassOnce(hinstance);

        const self = try alloc.create(DimOverlay);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .owner = owner,
            .hwnd = undefined,
        };

        // WS_EX_LAYERED — DWM-composited above OpenGL, uniform alpha.
        // WS_EX_TRANSPARENT — click-through to the pane underneath.
        // WS_EX_NOACTIVATE — never steals focus.
        // WS_EX_TOOLWINDOW — out of the taskbar / Alt-Tab list.
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
            1, // placeholder rect — show() glues to the owner
            owner, // owner (popup, not parent)
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;

        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *DimOverlay) void {
        _ = w32.DestroyWindow(self.hwnd);
        if (self.brush) |b| _ = w32.DeleteObject(@ptrCast(b));
        self.alloc.destroy(self);
    }

    /// Show the overlay glued over the owner surface at the given fill
    /// color (COLORREF) and alpha. Idempotent — also serves as the
    /// reposition call when the window moves or the layout changes.
    ///
    /// Returns whether it actually touched the window, which is the unit
    /// test's only handle on "did this re-blend?" (T1295).
    /// `batch` is the layout pass's `BeginDeferWindowPos` handle, when there
    /// is one (T1345). Every unfocused pane's wash moves on the same layout
    /// pass, and one `SetWindowPos` per popup is one window-manager
    /// transaction and one composite per popup; deferring them means the whole
    /// set lands in a single transaction, the way the PANES themselves have
    /// been placed since T1031. A null batch (a focus change, a config
    /// reload, a window move) places directly, exactly as before.
    ///
    /// A failed `DeferWindowPos` invalidates the batch handle, so the caller's
    /// handle is nulled and this — and every later popup in the pass — drops
    /// to a direct `SetWindowPos`. Same contract as `Window.placePane`.
    pub fn show(self: *DimOverlay, color: u32, alpha: u8, batch: ?*?w32.HDWP) bool {
        // A wash the lab is holding back stays exactly where it is until its
        // release tick, which re-shows it with the latest request (T2383).
        self.lab_color = color;
        self.lab_alpha = alpha;
        if (self.lab_hold != 0) return false;

        const color_changed = self.brush == null or color != self.color;
        if (color_changed) {
            if (self.brush) |b| _ = w32.DeleteObject(@ptrCast(b));
            self.brush = w32.CreateSolidBrush(color);
            self.color = color;
            _ = w32.InvalidateRect(self.hwnd, null, 1);
        }
        const alpha_changed = alpha != self.alpha;
        if (alpha_changed) {
            _ = w32.SetLayeredWindowAttributes(self.hwnd, 0, alpha, w32.LWA_ALPHA);
            self.alpha = alpha;
        }

        // GetWindowRect on the (child) surface HWND is already in screen
        // coordinates, which is what a popup's SetWindowPos takes.
        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(self.owner, &rect) == 0) return false;

        // The window clips the pane and nothing clips this popup (T2227): a
        // folding card slides out past the window's edge, and its wash -
        // painted in the background colour - went with it, over the desktop.
        // So the wash covers only the part of the pane in view, and none of
        // a pane that is wholly outside.
        var ox: i32 = 0;
        var oy: i32 = 0;
        var band: Band = .{};
        switch (pane_clip.ownerClip(self.owner)) {
            // Over a banner the wash starts at the top of its band (T2308).
            // A pane partly out of view hides its banner (T2227), so only a
            // whole one carries the band.
            .whole => if (!T2308_NEUTERED and self.band.height > 0) {
                band = self.band;
                oy = -band.height;
                rect.top -= band.height;
            },
            .none => {
                if (self.shown) self.hide();
                return false;
            },
            .part => |p| {
                ox = p.left;
                oy = p.top;
                rect = .{
                    .left = rect.left + p.left,
                    .top = rect.top + p.top,
                    .right = rect.left + p.right,
                    .bottom = rect.top + p.bottom,
                };
            },
        }
        const shape: Shape = .{
            .origin_x = ox,
            .origin_y = oy,
            .band = band.height,
            .corner = band.corner,
            .width = if (band.corner > 0) rect.right - rect.left else 0,
        };
        if (!std.meta.eql(shape, self.shape)) {
            self.shape = shape;
            self.applyRegion();
        }

        const placement: dim_math.Placement = .{
            .left = rect.left,
            .top = rect.top,
            .width = @max(rect.right - rect.left, 1),
            .height = @max(rect.bottom - rect.top, 1),
        };

        // T1295: a caller that changed nothing gets nothing. show() rides
        // every layout, focus, move, activate and config event, and it used
        // to SetWindowPos(SWP_SHOWWINDOW) unconditionally — free on a
        // composited desktop, another wash of fill over the same pixels in a
        // Remote Desktop session, where the layered blend is not reliably
        // idempotent. See dim_math.needsReposition for the full argument.
        if (!dim_math.needsReposition(.{
            .shown = self.shown,
            .placement_changed = !dim_math.Placement.eql(self.placement, placement),
            .alpha_changed = alpha_changed,
            .color_changed = color_changed,
        })) return false;

        // The lab's planted overlay lag (T2383): on the armed move, leave the
        // wash where it was while its pane goes on, for at least one whole
        // display refresh. Only a real MOVE of a wash already on screen
        // counts; showing, recolouring and re-alpha'ing are not lag.
        if (self.shown and !dim_math.Placement.eql(self.placement, placement)) {
            if (lab_plant.plan().overlay != 0) {
                self.lab_moves +|= 1;
                if (lab_plant.plan().fires(.overlay, self.lab_moves)) {
                    lab_plant.noteFired(.overlay, self.lab_moves);
                    self.lab_hold = lab_plant.overlay_hold_ticks;
                    _ = FrameClock.arm(self.hwnd, LAB_HOLD_TIMER_ID, 16);
                    return false;
                }
            }
        }

        // And when a re-blend IS unavoidable, start it from clean pixels
        // rather than from the last blend's output: drop the overlay, make
        // the owner (and, for a viewer pane, WebView2's own child windows)
        // repaint underneath, then put it back. Remote sessions only — on a
        // composited desktop this buys nothing and costs a repaint.
        if (self.shown and w32.GetSystemMetrics(w32.SM_REMOTESESSION) != 0) {
            _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
            _ = w32.RedrawWindow(
                self.owner,
                null,
                null,
                w32.RDW_INVALIDATE | w32.RDW_ERASE | w32.RDW_ALLCHILDREN | w32.RDW_UPDATENOW,
            );
        }

        const was_shown = self.shown;
        chrome_fanout.noteMove(.dim);
        const flags: u32 = w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW;
        placed: {
            // A popup coming back from hidden is placed DIRECTLY: the heal
            // below has to run against the window's real, final z-order, and
            // `SWP_SHOWWINDOW` arriving later out of the batch would undo it.
            if (was_shown) if (batch) |b| if (b.*) |h| {
                if (w32.DeferWindowPos(
                    h,
                    self.hwnd,
                    null,
                    placement.left,
                    placement.top,
                    placement.width,
                    placement.height,
                    flags,
                )) |next| {
                    b.* = next;
                    break :placed;
                }
                b.* = null;
            };
            // A batched wash's cost lands in the batch's `EndDeferWindowPos`,
            // which `Window.updateDimOverlays` clocks; this is the direct one.
            const clock = chrome_fanout.startMoveClock();
            _ = w32.SetWindowPos(
                self.hwnd,
                null,
                placement.left,
                placement.top,
                placement.width,
                placement.height,
                flags,
            );
            chrome_fanout.stopMoveClock(clock);
        }
        // Every reposition re-checks the z-order instead of leaving it to
        // whatever last touched it (T142) — except inside a live layout pass,
        // where an already-shown popup cannot have moved in the z-order and
        // the walk is the fan-out's biggest per-pane cost (T1345).
        w32.healOverlayZOrderAfterMove(self.hwnd, self.owner, was_shown);
        self.placement = placement;
        self.shown = true;
        return true;
    }

    /// Clip the wash to the owner pane's window region (T1831): an elevated
    /// pane is a rounded card, and a rectangular wash over it would paint
    /// square dim corners onto the desk. `key` is the owner's
    /// `PaneView.card_region_key` - the region is only re-copied when it
    /// changed, 0 meaning "the owner has none".
    pub fn matchOwnerRegion(self: *DimOverlay, key: u64) void {
        if (key == self.region_key) return;
        self.region_key = key;
        self.applyRegion();
    }

    /// The banner band above the owner this wash also covers (T2308), or
    /// none. Read by the next `show`, which moves and re-cuts the wash when
    /// it changed.
    pub fn setBand(self: *DimOverlay, band: Band) void {
        self.band = band;
    }

    /// Stack the wash over `card` - the pane's banner strip (T2308). Mac's
    /// dim is the last layer of the pane, and two popups with one owner sit
    /// in whatever order last moved them (T2261 measured the dim UNDER the
    /// card), so the order is read and, when wrong, the wash is put directly
    /// above the card. Returns whether it moved.
    pub fn seatOver(self: *DimOverlay, card: w32.HWND) bool {
        if (T2308_NEUTERED or !self.shown) return false;
        if (w32.IsWindowVisible_(card) == 0) return false;
        if (w32.isBelowInBand(self.owner, self.hwnd, card)) return false;
        // Directly beneath whatever is directly above the card (null: the
        // card is the top window, and so is the wash now).
        _ = w32.SetWindowPos(
            self.hwnd,
            w32.GetWindow(card, w32.GW_HWNDPREV),
            0,
            0,
            0,
            0,
            w32.SWP_NOACTIVATE | w32.SWP_NOMOVE | w32.SWP_NOSIZE,
        );
        return true;
    }

    /// The wash's window region: the owner's card shape (`region_key`,
    /// T1831) in this popup's coordinates - shifted by the origin when the
    /// popup covers only the part of the owner in view (T2227), or reaches
    /// up over its banner (T2308) - plus that banner band, cut with the
    /// strip's own top corners.
    fn applyRegion(self: *DimOverlay) void {
        const s = self.shape;
        const rounded_band = s.band > 0 and s.corner > 0;
        if (self.region_key == 0 and !rounded_band) {
            _ = w32.SetWindowRgn(self.hwnd, null, 1);
            return;
        }
        const rgn = w32.CreateRectRgn(0, 0, 0, 0) orelse return;
        var cut = false;
        if (self.region_key != 0) {
            if (w32.GetWindowRgn(self.owner, rgn) != 0) {
                cut = true;
                if (s.origin_x != 0 or s.origin_y != 0) _ = w32.OffsetRgn(rgn, -s.origin_x, -s.origin_y);
            } else self.region_key = 0;
        }
        if (s.band > 0 and (cut or rounded_band)) {
            // The owner uncut is its whole rect below the band (the window
            // clips the open bottom).
            if (!cut) _ = w32.SetRectRgn(rgn, 0, s.band, std.math.maxInt(i16), std.math.maxInt(i16));
            if (bandRegion(s)) |b| {
                _ = w32.CombineRgn(rgn, rgn, b, w32.RGN_OR);
                _ = w32.DeleteObject(b);
            }
            cut = true;
        }
        if (!cut) {
            _ = w32.DeleteObject(rgn);
            _ = w32.SetWindowRgn(self.hwnd, null, 1);
            return;
        }
        if (w32.SetWindowRgn(self.hwnd, rgn, 1) == 0) {
            _ = w32.DeleteObject(rgn);
            self.region_key = 0;
        }
    }

    pub fn hide(self: *DimOverlay) void {
        if (self.lab_hold != 0) {
            self.lab_hold = 0;
            FrameClock.disarm(self.hwnd, LAB_HOLD_TIMER_ID);
        }
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.shown = false;
    }

    /// One frame-clock tick of a held wash (T2383): on the last one, catch up
    /// to wherever the pane is now.
    fn onLabHoldTick(self: *DimOverlay) void {
        if (self.lab_hold == 0) {
            FrameClock.disarm(self.hwnd, LAB_HOLD_TIMER_ID);
            return;
        }
        self.lab_hold -= 1;
        if (self.lab_hold != 0) return;
        FrameClock.disarm(self.hwnd, LAB_HOLD_TIMER_ID);
        _ = self.show(self.lab_color, self.lab_alpha, null);
    }

    /// The dim wash, into whichever DC this overlay is handed — the paint
    /// cycle's own, or a caller's under WM_PRINTCLIENT (T940).
    fn paintInto(self: *const DimOverlay, hwnd: w32.HWND, hdc: w32.HDC) void {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &rect) == 0) return;
        const brush = self.brush orelse return;
        _ = w32.FillRect(hdc, &rect, brush);
    }
};

/// The band rows of the wash's region (T2308): the banner strip's shape -
/// the rounded rect `BannerOverlay.applyCardCorner` cuts, which runs a whole
/// corner past the band so only its top corners fall inside - kept to the
/// band. A square band is a plain rect.
fn bandRegion(s: DimOverlay.Shape) ?*anyopaque {
    const right = if (s.width > 0) s.width else std.math.maxInt(i16);
    const full = w32.CreateRectRgn(0, 0, right, s.band) orelse return null;
    if (s.corner <= 0) return full;
    const round = w32.CreateRoundRectRgn(0, 0, s.width + 1, s.band + s.corner + 1, s.corner, s.corner) orelse return full;
    defer _ = w32.DeleteObject(round);
    _ = w32.CombineRgn(full, full, round, w32.RGN_AND);
    return full;
}

/// Negative control for T2308 (`pane-banner.ps1` section 7c). Flipping it
/// gives the wash back the terminal's rect alone and leaves its stacking to
/// chance, as before T2308: an unfocused pane's banner stays undimmed.
pub const T2308_NEUTERED = false;

test "DimOverlay: the T2308 negative control ships clear" {
    try std.testing.expect(!T2308_NEUTERED);
}

test "DimOverlay: the lab's planted lag holds the armed move through two ticks, then catches up (T2383)" {
    const testing = std.testing;
    const hinstance = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyDimLabTest");
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &w32.DefWindowProcW,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class,
        .hIconSm = null,
    };
    _ = w32.RegisterClassExW(&wc);
    defer _ = w32.UnregisterClassW(class, hinstance);
    const title = std.unicode.utf8ToUtf16LeStringLiteral("dim lab test");
    const top = w32.CreateWindowExW(0, class, title, w32.WS_POPUP, 0, 0, 600, 400, null, null, hinstance, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(top);
    const owner = w32.CreateWindowExW(0, class, title, w32.WS_CHILD | w32.WS_VISIBLE_STYLE, 20, 100, 300, 200, top, null, hinstance, null) orelse return error.Win32Error;

    lab_plant.setPlanForTest(.{ .overlay = 2 });
    defer lab_plant.setPlanForTest(.{});

    const d = try DimOverlay.create(testing.allocator, owner, hinstance);
    defer d.destroy();
    const color = w32.RGB(16, 16, 20);

    // Showing is not a move; the first move is event 1 and is not armed.
    try testing.expect(d.show(color, 77, null));
    _ = w32.SetWindowPos(owner, null, 30, 100, 300, 200, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    try testing.expect(d.show(color, 77, null));
    const before = d.placement;

    // Move 2 is armed: the wash stays put, and so does every show until the
    // release, however many moves the pane makes meanwhile.
    _ = w32.SetWindowPos(owner, null, 40, 100, 280, 200, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    try testing.expect(!d.show(color, 77, null));
    try testing.expect(dim_math.Placement.eql(before, d.placement));
    _ = w32.SetWindowPos(owner, null, 50, 100, 260, 200, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    try testing.expect(!d.show(color, 77, null));
    try testing.expect(dim_math.Placement.eql(before, d.placement));

    // The first tick may share the refresh the hold began in: still held.
    d.onLabHoldTick();
    try testing.expect(dim_math.Placement.eql(before, d.placement));
    // The second catches up to where the pane is NOW.
    d.onLabHoldTick();
    var orect: w32.RECT = undefined;
    try testing.expect(w32.GetWindowRect(owner, &orect) != 0);
    try testing.expectEqual(orect.left, d.placement.left);
    try testing.expectEqual(orect.right - orect.left, d.placement.width);
    try testing.expectEqual(@as(u8, 0), d.lab_hold);

    // Fired once: the next move goes straight through.
    _ = w32.SetWindowPos(owner, null, 60, 100, 240, 200, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    try testing.expect(d.show(color, 77, null));
}

test "DimOverlay: the wash covers the banner band and stacks over the strip (T2308)" {
    const testing = std.testing;
    const hinstance = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyDimBandTest");
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &w32.DefWindowProcW,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class,
        .hIconSm = null,
    };
    _ = w32.RegisterClassExW(&wc);
    defer _ = w32.UnregisterClassW(class, hinstance);
    const title = std.unicode.utf8ToUtf16LeStringLiteral("dim band test");
    const top = w32.CreateWindowExW(0, class, title, w32.WS_POPUP, 0, 0, 600, 400, null, null, hinstance, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(top);
    // The terminal's window, pushed down by a 60px banner band.
    const owner = w32.CreateWindowExW(0, class, title, w32.WS_CHILD | w32.WS_VISIBLE_STYLE, 20, 100, 300, 200, top, null, hinstance, null) orelse return error.Win32Error;
    // The banner strip: a popup with the same owner, in the band.
    const strip = w32.CreateWindowExW(w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE, class, title, w32.WS_POPUP, 0, 0, 1, 1, owner, null, hinstance, null) orelse return error.Win32Error;

    const d = try DimOverlay.create(testing.allocator, owner, hinstance);
    defer d.destroy();

    var orect: w32.RECT = undefined;
    try testing.expect(w32.GetWindowRect(owner, &orect) != 0);

    // No banner: the wash is the terminal's rect.
    _ = d.show(w32.RGB(16, 16, 20), 77, null);
    try testing.expectEqual(orect.top, d.placement.top);
    try testing.expectEqual(orect.bottom - orect.top, d.placement.height);

    // A banner: the wash starts at the top of its band.
    d.setBand(.{ .height = 60 });
    try testing.expect(d.show(w32.RGB(16, 16, 20), 77, null));
    try testing.expectEqual(orect.top - 60, d.placement.top);
    try testing.expectEqual(orect.bottom - orect.top + 60, d.placement.height);
    try testing.expectEqual(orect.left, d.placement.left);

    // A rounded band cuts the wash's top corners: the corner pixel is out,
    // the middle of the band and the terminal's corner are in.
    d.setBand(.{ .height = 60, .corner = 16 });
    _ = d.show(w32.RGB(16, 16, 20), 77, null);
    const rgn = w32.CreateRectRgn(0, 0, 0, 0) orelse return error.Win32Error;
    defer _ = w32.DeleteObject(rgn);
    try testing.expect(w32.GetWindowRgn(d.hwnd, rgn) != 0);
    try testing.expect(w32.PtInRegion(rgn, 0, 0) == 0);
    try testing.expect(w32.PtInRegion(rgn, 150, 30) != 0);
    try testing.expect(w32.PtInRegion(rgn, 0, 60) != 0);
    try testing.expect(w32.PtInRegion(rgn, 299, 259) != 0);

    // The banner gone: back to the terminal's rect, uncut.
    d.setBand(.{});
    try testing.expect(d.show(w32.RGB(16, 16, 20), 77, null));
    try testing.expectEqual(orect.top, d.placement.top);
    try testing.expect(w32.GetWindowRgn(d.hwnd, rgn) == 0);

    // Stacking: a strip lifted over the wash gets the wash put back on top.
    _ = w32.SetWindowPos(strip, null, orect.left, orect.top - 60, 300, 60, w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW);
    defer _ = w32.ShowWindow(strip, w32.SW_HIDE);
    _ = w32.SetWindowPos(strip, null, 0, 0, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
    try testing.expect(w32.isBelowInBand(owner, strip, d.hwnd));
    try testing.expect(d.seatOver(strip));
    try testing.expect(w32.isBelowInBand(owner, d.hwnd, strip));
    // ...and in order already, nothing moves.
    try testing.expect(!d.seatOver(strip));
    // A hidden wash never re-stacks.
    d.hide();
    try testing.expect(!d.seatOver(strip));
}

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = dimWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // painted in WM_ERASEBKGND with the cached brush
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn dimWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*DimOverlay = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_TIMER => {
            if (wparam == DimOverlay.LAB_HOLD_TIMER_ID) self.onLabHoldTick();
            return 0;
        },

        w32.WM_ERASEBKGND => {
            if (wparam == 0) return 0;
            self.paintInto(hwnd, @ptrFromInt(wparam));
            return 1;
        },

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            self.paintInto(hwnd, hdc);
            return 0;
        },
        // The same wash into a caller's DC, so a pixel probe can photograph the
        // dimmed pane synchronously rather than through DWM's asynchronous copy
        // of the composited surface (T835/T940). This one is layered, which is
        // the case that tears worst: the async copy is the whole point of
        // PW_RENDERFULLCONTENT for a layered window.
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            self.paintInto(hwnd, @ptrFromInt(wparam));
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
