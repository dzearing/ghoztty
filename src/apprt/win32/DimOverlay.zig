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
    /// Where this popup's top-left sits inside the owner (T2227): 0,0 unless
    /// part of the owner is outside its window and the wash covers only the
    /// part in view. The owner's card shape is shifted by it (`applyRegion`).
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    /// On a glass pane the wash is the desk under the pane rather than the
    /// fill colour (T2086): the slice last cropped, `wash_w` x `wash_h`,
    /// top-down, and the key it was cropped for. Null with a solid wash.
    wash: ?[]u32 = null,
    wash_w: i32 = 0,
    wash_h: i32 = 0,
    wash_key: u64 = 0,

    /// Where a glass pane's desk wash comes from (T2086): the window's
    /// rendered desk and where its top-left sits in `parent`'s client area.
    pub const DeskWash = struct {
        parent: w32.HWND,
        left: i32,
        top: i32,
        pixels: []const u32,
        w: i32,
        h: i32,
        gen: u32,
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
        if (self.wash) |px| self.alloc.free(px);
        self.alloc.destroy(self);
    }

    /// Bring the desk wash up to date for an overlay at `placement` (screen
    /// coordinates), or drop it with a null `desk`. Returns whether the
    /// pixels changed. A crop is a row copy per row and only happens when
    /// the pane moved, resized, or the desk was re-rendered.
    fn syncWash(self: *DimOverlay, desk: ?DeskWash, placement: dim_math.Placement) bool {
        const d = desk orelse {
            if (self.wash == null) return false;
            self.alloc.free(self.wash.?);
            self.wash = null;
            self.wash_key = 0;
            return true;
        };
        var pt: w32.POINT = .{ .x = placement.left, .y = placement.top };
        _ = w32.ScreenToClient(d.parent, &pt);
        const ox = pt.x - d.left;
        const oy = pt.y - d.top;
        const words = [_]u64{
            @bitCast(@as(i64, ox)),               @bitCast(@as(i64, oy)),
            @bitCast(@as(i64, placement.width)),  @bitCast(@as(i64, placement.height)),
            @bitCast(@as(i64, d.w)),              @bitCast(@as(i64, d.h)),
            d.gen,
        };
        const key = std.hash.Wyhash.hash(0x2086, std.mem.sliceAsBytes(&words)) | 1;
        if (key == self.wash_key and self.wash != null) return false;
        const n: usize = @intCast(placement.width * placement.height);
        if (self.wash == null or self.wash.?.len != n) {
            if (self.wash) |px| self.alloc.free(px);
            self.wash = self.alloc.alloc(u32, n) catch {
                self.wash = null;
                self.wash_key = 0;
                return true;
            };
        }
        dim_math.cropWash(
            self.wash.?,
            @intCast(placement.width),
            @intCast(placement.height),
            d.pixels,
            @intCast(d.w),
            @intCast(d.h),
            ox,
            oy,
        );
        self.wash_w = placement.width;
        self.wash_h = placement.height;
        self.wash_key = key;
        return true;
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
    ///
    /// `desk`, on a glass pane, makes the wash the desk under the pane in
    /// place of `color` (T2086): Mac fades a glass terminal whole, so the
    /// desk is what reads through it.
    pub fn show(self: *DimOverlay, color: u32, alpha: u8, desk: ?DeskWash, batch: ?*?w32.HDWP) bool {
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
        switch (pane_clip.ownerClip(self.owner)) {
            .whole => {},
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
        if (ox != self.origin_x or oy != self.origin_y) {
            self.origin_x = ox;
            self.origin_y = oy;
            self.applyRegion();
        }

        const placement: dim_math.Placement = .{
            .left = rect.left,
            .top = rect.top,
            .width = @max(rect.right - rect.left, 1),
            .height = @max(rect.bottom - rect.top, 1),
        };

        // A glass pane's wash is the desk under it (T2086), re-cropped when
        // the pane moves or the desk is re-rendered.
        const wash_changed = self.syncWash(desk, placement);
        if (wash_changed) _ = w32.InvalidateRect(self.hwnd, null, 0);

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
            .color_changed = color_changed or wash_changed,
        })) return false;

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
            _ = w32.SetWindowPos(
                self.hwnd,
                null,
                placement.left,
                placement.top,
                placement.width,
                placement.height,
                flags,
            );
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

    /// The wash's window region: the owner's card shape (`region_key`,
    /// T1831), in this popup's coordinates - shifted by `origin_x/_y` when
    /// the popup covers only the part of the owner in view (T2227).
    fn applyRegion(self: *DimOverlay) void {
        if (self.region_key == 0) {
            _ = w32.SetWindowRgn(self.hwnd, null, 1);
            return;
        }
        const rgn = w32.CreateRectRgn(0, 0, 0, 0) orelse return;
        if (w32.GetWindowRgn(self.owner, rgn) == 0) {
            _ = w32.DeleteObject(rgn);
            self.region_key = 0;
            return;
        }
        if (self.origin_x != 0 or self.origin_y != 0) _ = w32.OffsetRgn(rgn, -self.origin_x, -self.origin_y);
        if (w32.SetWindowRgn(self.hwnd, rgn, 1) == 0) {
            _ = w32.DeleteObject(rgn);
            self.region_key = 0;
        }
    }

    pub fn hide(self: *DimOverlay) void {
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.shown = false;
    }

    /// The dim wash, into whichever DC this overlay is handed — the paint
    /// cycle's own, or a caller's under WM_PRINTCLIENT (T940).
    fn paintInto(self: *const DimOverlay, hwnd: w32.HWND, hdc: w32.HDC) void {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &rect) == 0) return;
        // A glass pane's wash: the desk under the pane (T2086).
        if (self.wash) |px| {
            const bmi: w32.BITMAPINFO = .{ .bmiHeader = .{
                .biWidth = self.wash_w,
                .biHeight = -self.wash_h, // top-down
            } };
            if (w32.StretchDIBits(
                hdc,
                0,
                0,
                self.wash_w,
                self.wash_h,
                0,
                0,
                self.wash_w,
                self.wash_h,
                px.ptr,
                &bmi,
                w32.DIB_RGB_COLORS,
                w32.SRCCOPY,
            ) != 0) return;
        }
        const brush = self.brush orelse return;
        _ = w32.FillRect(hdc, &rect, brush);
    }
};

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
