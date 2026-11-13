//! The strip's face over a card gliding into or out of its strip (T2288,
//! Mac a81db68f9): the strip's band and name, laid over what of the card is
//! drawn at the card's `collapse` constant alpha, so the content fades out
//! as the title fades in. Pure logic (how far in, the alpha, the pixels) is
//! `strip_face.zig`.
//!
//! The `DimOverlay` shape: a WS_EX_LAYERED popup owned by the pane's child
//! HWND, so DWM composites it above OpenGL and WebView2 content alike, and
//! WS_EX_TRANSPARENT so it never takes the pointer. Uniform alpha, committed
//! with UpdateLayeredWindow (T2485 D7) from the frame the window drew into
//! its DIB (`begin`/`commit`). That DIB lives for the whole glide (T2461): a
//! fold paints a frame on every tick, and a fresh full-card bitmap each time
//! was a fresh 16 MB to fault in at 4K. It also answers WM_PRINT, so a pixel
//! probe can still photograph the face, where DefWindowProc would read an
//! UpdateLayeredWindow face back black.

const std = @import("std");
const w32 = @import("win32.zig");
const chrome_fanout = @import("chrome_fanout.zig");
const chrome_comp = @import("chrome_comp.zig");
const comp_tree = @import("../../renderer/comp_tree.zig");
const strip_face = @import("strip_face.zig");

const log = std.log.scoped(.win32_strip_face);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyStripFace");

/// Stamp each popup `commit`'s phases into `commit_stamps` (T2732). Set by the
/// window when its stack trace is on; a QPC read per phase otherwise skipped.
pub var stamp_commits: bool = false;

fn stamp() i64 {
    var t: i64 = 0;
    _ = w32.QueryPerformanceCounter(&t);
    return t;
}

pub const StripFace = struct {
    alloc: std.mem.Allocator,
    /// The pane child HWND this face covers (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,

    shown: bool = false,
    /// Up carrying its card's frame (T2457), not blended over a live pane:
    /// only then does the live pane under it go (T2822 - a face declared
    /// live from a fold's first frame is shown before its frame lands).
    carrying: bool = false,
    /// The constant alpha last committed.
    alpha: u8 = 0,

    /// The glide's DIB: a memory DC over a top-down 32-bit bitmap of
    /// `cap_w` x `cap_h`, kept from the first frame until `hide`.
    mem_dc: ?w32.HDC = null,
    bitmap: ?*anyopaque = null,
    old_bmp: ?*anyopaque = null,
    bits: ?[*]u32 = null,
    cap_w: i32 = 0,
    cap_h: i32 = 0,

    /// The frame being painted (`begin` to `commit`), at the DIB's top-left.
    w: i32 = 0,
    h: i32 = 0,
    painting: bool = false,

    /// QPC stamps of the last popup `commit` (T2732), taken only while
    /// `stamp_commits` is set (the window's `GHOZTTY_STACK_TRACE`): entry,
    /// after `SetWindowRgn`, after `UpdateLayeredWindow`, and the end (show +
    /// z heal). Zero when off.
    commit_stamps: [4]i64 = .{ 0, 0, 0, 0 },

    /// The size of the frame on screen, which WM_PRINT paints from the DIB.
    px_w: i32 = 0,
    px_h: i32 = 0,

    /// In the composition pane tree (T2777) the face is a picture in the
    /// window's own tree instead of this popup: `comp` is that visual, and
    /// `comp_host` the window's host slot it was put up on. `on_visual` says
    /// the frame on show is the visual's; the popup is hidden then.
    comp: chrome_comp.FaceVis = .{},
    comp_host: ?*?chrome_comp.Host = null,
    on_visual: bool = false,
    /// The fold handed to the compositor whole (T2778), while it runs; null
    /// on a face stepped from frames.
    decl: ?strip_face.FaceDecl = null,
    /// A strip that stays a strip and moves, declared as this face (T2825):
    /// the part of its tab it covers at both ends of the glide, which the
    /// desk goes on painting while the face carries the rest. Null on any
    /// other face.
    still: ?w32.RECT = null,

    pub fn create(alloc: std.mem.Allocator, owner: w32.HWND, hinstance: w32.HINSTANCE) !*StripFace {
        try registerClassOnce(hinstance);
        const self = try alloc.create(StripFace);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .owner = owner, .hwnd = undefined };
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
            1, // placeholder - commit() places it
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *StripFace) void {
        self.dropVisual();
        self.releaseDib();
        _ = w32.DestroyWindow(self.hwnd);
        self.alloc.destroy(self);
    }

    /// A `w` x `h` frame to paint the face into: the memory DC over the
    /// glide's DIB, and its pixels from the DIB's top-left. `cap_w` x `cap_h`
    /// is the largest the face can get this glide (the pane it covers), so the
    /// DIB is made once, at that size, and every narrower frame after reuses
    /// it (T2461). Null when GDI said no; the face is then left as it was.
    pub fn begin(self: *StripFace, w: i32, h: i32, cap_w: i32, cap_h: i32) ?struct { dc: w32.HDC, frame: strip_face.Frame } {
        self.painting = false;
        if (w <= 0 or h <= 0) return null;
        if (self.mem_dc == null or w > self.cap_w or h > self.cap_h) {
            if (!self.makeDib(@max(w, cap_w, self.cap_w), @max(h, cap_h, self.cap_h))) return null;
        }
        self.w = w;
        self.h = h;
        self.painting = true;
        const stride: usize = @intCast(self.cap_w);
        return .{ .dc = self.mem_dc.?, .frame = .{
            .pixels = self.bits.?[0 .. stride * @as(usize, @intCast(h))],
            .stride = stride,
            .w = @intCast(w),
            .h = @intCast(h),
        } };
    }

    fn makeDib(self: *StripFace, w: i32, h: i32) bool {
        self.releaseDib();
        const screen_dc = w32.GetDC(null) orelse return false;
        defer _ = w32.ReleaseDC(null, screen_dc);
        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return false;
        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{ .bmiHeader = .{ .biWidth = w, .biHeight = -h } };
        const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = w32.DeleteDC(mem_dc);
            return false;
        };
        const old = w32.SelectObject(mem_dc, bitmap) orelse {
            _ = w32.DeleteObject(bitmap);
            _ = w32.DeleteDC(mem_dc);
            return false;
        };
        self.mem_dc = mem_dc;
        self.bitmap = bitmap;
        self.old_bmp = old;
        self.bits = @ptrCast(@alignCast(bits.?));
        self.cap_w = w;
        self.cap_h = h;
        log.debug("strip face dib {d}x{d}", .{ w, h });
        return true;
    }

    /// Put the frame `begin` handed out on screen at `left`/`top` (screen
    /// pixels), blended at `alpha`, cut to `region` (in the face's own
    /// coordinates; null for none - the system owns it once set).
    pub fn commit(self: *StripFace, left: i32, top: i32, alpha: u8, region: ?*anyopaque) void {
        if (!self.painting or self.mem_dc == null) {
            if (region) |r| _ = w32.DeleteObject(r);
            return;
        }
        self.painting = false;
        const stamping = stamp_commits;
        if (stamping) self.commit_stamps[0] = stamp();
        _ = w32.GdiFlush();
        self.px_w = self.w;
        self.px_h = self.h;
        chrome_fanout.noteMove(.dim);
        if (w32.SetWindowRgn(self.hwnd, region, 0) == 0) if (region) |r| {
            _ = w32.DeleteObject(r);
        };
        if (stamping) self.commit_stamps[1] = stamp();
        // Pixels, place and alpha in one UpdateLayeredWindow, which DWM takes
        // whole at its next composition (T2485 D7). Painting the redirection
        // surface through WM_PAINT after a SetLayeredWindowAttributes reached
        // the screen 1-3 frames after the pane under it was hidden, so a
        // fold's first frames showed neither. The source alpha is not read
        // (AlphaFormat 0): the face is uniform, as the dim wash is.
        const dst_pt = w32.POINT{ .x = left, .y = top };
        const dst_size = w32.SIZE{ .cx = self.w, .cy = self.h };
        const src_pt = w32.POINT{ .x = 0, .y = 0 };
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = alpha, .AlphaFormat = 0 };
        if (w32.UpdateLayeredWindow(self.hwnd, null, &dst_pt, &dst_size, self.mem_dc, &src_pt, 0, &blend, w32.ULW_ALPHA) == 0)
            log.warn("strip face UpdateLayeredWindow failed err={d}", .{w32.GetLastError()});
        if (stamping) self.commit_stamps[2] = stamp();
        defer {
            if (stamping) self.commit_stamps[3] = stamp();
        }
        self.alpha = alpha;
        if (!self.shown)
            _ = w32.SetWindowPos(self.hwnd, null, 0, 0, 0, 0, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_SHOWWINDOW);
        const was_shown = self.shown;
        if (!was_shown) {
            self.shown = true;
            log.info("strip face shown alpha={d} rect={d},{d},{d}x{d}", .{ alpha, left, top, self.px_w, self.px_h });
        }
        w32.healOverlayZOrderAfterMove(self.hwnd, self.owner, was_shown and !self.on_visual);
        // Back on the popup from the visual (the host went away mid-glide):
        // the visual goes once the popup carries the frame.
        if (self.on_visual) {
            self.on_visual = false;
            self.dropVisual();
            log.info("strip face moved to its popup", .{});
        }
    }

    /// Put the frame `begin` handed out up as a picture in the window's
    /// composition tree (T2777) at (`x`, `y`) in the window's client area,
    /// at `alpha`, cut to `clip` (the face's own pixels), on the host in
    /// `host_slot`. False when the host cannot take it; nothing changed
    /// then, so the caller commits the popup instead.
    pub fn commitVisual(self: *StripFace, host_slot: *?chrome_comp.Host, x: i32, y: i32, alpha: u8, clip: comp_tree.Clip) bool {
        if (!self.painting or self.mem_dc == null) return false;
        const host = if (host_slot.*) |*h| h else return false;
        if (!host.faceAvailable()) return false;
        _ = w32.GdiFlush();
        const n: usize = @as(usize, @intCast(self.cap_w)) * @as(usize, @intCast(self.cap_h));
        host.faceShow(&self.comp, self.bits.?[0..n], self.w, self.h, self.cap_w, self.cap_h, x, y, clip, @as(f32, @floatFromInt(alpha)) / 255.0) catch |err| {
            const f = chrome_comp.Host.lastFailure();
            log.warn("strip face visual failed ({}) at {s}: hr=0x{x:0>8}; the face goes back to its popup", .{ err, f.stage, chrome_comp.hex(f.hr) });
            chrome_comp.Host.releaseFace(&self.comp);
            return false;
        };
        self.comp_host = host_slot;
        // Stepped again: a declared fold is replaced (`faceShow`).
        self.decl = null;
        self.painting = false;
        self.px_w = self.w;
        self.px_h = self.h;
        self.alpha = alpha;
        // Off the popup, after the visual carries the frame.
        if (self.shown and !self.on_visual) {
            _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
            log.info("strip face moved to its visual", .{});
        }
        const was_shown = self.shown;
        self.shown = true;
        self.on_visual = true;
        // The acceptance oracle (stack-fold-slide.ps1 / pane-stack-unfold.ps1
        // tree arms): a face shown in the window's tree, never the popup.
        if (!was_shown) log.info("strip face visual shown alpha={d} rect={d},{d},{d}x{d}", .{ alpha, x, y, self.w, self.h });
        return true;
    }

    /// Hand the face's whole fold to the compositor (T2778): `g`'s pictures
    /// go up under the face's visual in the window's tree on the host in
    /// `host_slot`, and its card clip, places and strength run on the
    /// compositor's clock until the glide drops the face or declares it
    /// again. `decl` is what was declared, for a retarget to start from
    /// where the compositor has got to. False when the host cannot take it;
    /// the face is then off the tree and the caller steps it on frames.
    pub fn declareVisual(self: *StripFace, host_slot: *?chrome_comp.Host, g: chrome_comp.FaceGlide, decl: strip_face.FaceDecl, opening: bool) bool {
        self.painting = false;
        const host = if (host_slot.*) |*h| h else return false;
        if (!host.faceAvailable()) return false;
        host.faceDeclare(&self.comp, g) catch |err| {
            const f = chrome_comp.Host.lastFailure();
            log.warn("strip face declare failed ({}) at {s}: hr=0x{x:0>8}; the face goes back to frames", .{ err, f.stage, chrome_comp.hex(f.hr) });
            host.faceDrop(&self.comp);
            self.decl = null;
            self.still = null;
            if (self.on_visual) {
                self.on_visual = false;
                self.shown = false;
            }
            return false;
        };
        self.comp_host = host_slot;
        self.decl = decl;
        self.alpha = 255;
        if (self.shown and !self.on_visual) {
            _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
            log.info("strip face moved to its visual", .{});
        }
        const was_shown = self.shown;
        self.shown = true;
        self.on_visual = true;
        // The acceptance oracle (stack-fold-slide.ps1 / pane-stack-unfold.ps1
        // tree arms read the first line; comp-glide-hold-onscreen.ps1's stall
        // arm reads the second).
        if (!was_shown) log.info("strip face visual shown alpha=255 rect={d},{d},{d}x{d}", .{
            @as(i32, @intFromFloat(g.from.clip.left)),
            @as(i32, @intFromFloat(g.from.clip.top)),
            @as(i32, @intFromFloat(g.from.clip.right - g.from.clip.left)),
            @as(i32, @intFromFloat(g.from.clip.bottom - g.from.clip.top)),
        });
        // `opening`/`content`: an unfold (T2779), and whether its frame has
        // landed - comp-glide-hold-onscreen.ps1's unfold arm reads both;
        // `live`: a face blended over its live pane (T2822, the live arm).
        log.debug("strip face glide declared clip_left={d:.1}->{d:.1} clip_right={d:.1}->{d:.1} content_x={d:.1}->{d:.1} opacity={d:.3}->{d:.3} enter_ms={d:.0} knee_ms={d:.0} span_ms={d:.0} opening={} content={} live={}", .{
            g.from.clip.left,
            g.to.clip.left,
            g.from.clip.right,
            g.to.clip.right,
            g.from.content_x,
            g.to.content_x,
            g.from.opacity,
            g.to.opacity,
            if (g.fade_enter_s) |e| e * 1000 else 0,
            if (g.fade_leave_s) |k| k * 1000 else g.span_s * 1000,
            g.span_s * 1000,
            opening,
            g.content.w > 0,
            g.live,
        });
        return true;
    }

    /// Take the face's visual off the window's tree, if it has one.
    fn dropVisual(self: *StripFace) void {
        self.decl = null;
        self.still = null;
        if (!self.comp.live()) return;
        if (self.comp_host) |slot_ptr| if (slot_ptr.*) |*h| {
            h.faceDrop(&self.comp);
            return;
        };
        chrome_comp.Host.releaseFace(&self.comp);
    }
    /// The uniform name every pane popup answers (T2012).
    pub fn hide(self: *StripFace) void {
        self.carrying = false;
        // The glide is over: the DIB goes with it, so a 4K card's 30 MB is
        // not held between glides.
        self.releaseDib();
        self.still = null;
        if (!self.shown) return;
        if (self.on_visual) {
            self.on_visual = false;
            self.dropVisual();
            self.shown = false;
            log.info("strip face visual hidden", .{});
            return;
        }
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        self.shown = false;
        log.info("strip face hidden", .{});
    }

    /// The frame on screen, into a DC (WM_PAINT, WM_PRINT), straight from
    /// the DIB: nothing paints it between one commit and the next `begin`,
    /// and the paint between them runs on this thread without pumping.
    fn printInto(self: *const StripFace, hdc: w32.HDC) void {
        if (self.px_w <= 0 or self.px_h <= 0) return;
        const src = self.mem_dc orelse return;
        _ = w32.BitBlt(hdc, 0, 0, self.px_w, self.px_h, src, 0, 0, w32.SRCCOPY);
    }

    fn releaseDib(self: *StripFace) void {
        self.painting = false;
        self.px_w = 0;
        self.px_h = 0;
        const mem_dc = self.mem_dc orelse return;
        if (self.old_bmp) |o| _ = w32.SelectObject(mem_dc, o);
        if (self.bitmap) |b| _ = w32.DeleteObject(b);
        _ = w32.DeleteDC(mem_dc);
        self.mem_dc = null;
        self.bitmap = null;
        self.old_bmp = null;
        self.bits = null;
        self.cap_w = 0;
        self.cap_h = 0;
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = faceWndProc,
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

fn faceWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*StripFace = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_ERASEBKGND => return 1, // every pixel is painted below
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            if (self_opt) |self| self.printInto(hdc);
            return 0;
        },
        // The face into a caller's DC, so a pixel probe can photograph it
        // synchronously (T835/T940). PrintWindow sends WM_PRINT, whose
        // default would ask for the erase and the client in turn; answered
        // here whole, since this window has no frame and no erase of its own.
        // Once `commit` has made it an UpdateLayeredWindow window, though,
        // the system answers PrintWindow from the layered surface and this
        // is never reached (T2836: a receipt here logged 0 times in 9
        // stack-fold-slide runs); under box load that answer can be the
        // caller's untouched bitmap, which the probe retakes.
        w32.WM_PRINT => {
            if (wparam == 0) return 0;
            if (self_opt) |self| self.printInto(@ptrFromInt(wparam));
            return 0;
        },
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            if (self_opt) |self| self.printInto(@ptrFromInt(wparam));
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
