//! T2599 standalone driver repro: does a top-level that has had a SECOND plain
//! WGL child strand a top-level-sized GPU allocation on every show/restore,
//! with no Ghoztty code involved? And does one GL child with several contexts
//! (the "one presenter per top-level" architecture) avoid it?
//!
//! Driven by the harness with SendMessage(WM_APP, cmd, arg) to the top-level
//! (class T2599Repro), so every step is synchronous and the harness samples
//! the process's GPU counters between steps.
//!   1 add a plain GL child (arg: 0 = SwapBuffers it, 1 = context but never swap)
//!   2 destroy the newest child
//!   3 hide top-level      4 show top-level
//!   5 minimize            6 restore
//!   7 present every child again
//!   8 add a GDI (non-GL) child
//!   9 add another CONTEXT on child 0 and present through it (shared presenter)
//!  10 destroy the top-level (process exits)
//!  11 hide the newest child (a parked pane)
//!  12 show / 13 restore WITHOUT presenting   14 present child 0 only
const std = @import("std");
const W = std.os.windows;

const HWND = W.HWND;
const HDC = *opaque {};
const HGLRC = *opaque {};
const LRESULT = isize;
const WPARAM = usize;
const LPARAM = isize;

const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?W.HINSTANCE = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: WPARAM, lParam: LPARAM, time: u32, pt: [2]i32, priv: u32 };
const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: u32,
    iPixelType: u8 = 0,
    cColorBits: u8 = 32,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 8,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 8,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: u32 = 0,
    dwVisibleMask: u32 = 0,
    dwDamageMask: u32 = 0,
};
const PAINTSTRUCT = extern struct { hdc: HDC, fErase: i32, rc: [4]i32, fRestore: i32, fIncUpdate: i32, rgb: [32]u8 };

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?W.HINSTANCE, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) i32;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) i32;
extern "user32" fn GetDC(HWND) callconv(.winapi) ?HDC;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) i32;
extern "user32" fn GetClientRect(HWND, *[4]i32) callconv(.winapi) i32;
extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
extern "gdi32" fn SetPixelFormat(HDC, i32, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
extern "gdi32" fn SwapBuffers(HDC) callconv(.winapi) i32;
extern "gdi32" fn GetStockObject(i32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn PatBlt(HDC, i32, i32, i32, i32, u32) callconv(.winapi) i32;
extern "opengl32" fn wglCreateContext(HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglMakeCurrent(?HDC, ?HGLRC) callconv(.winapi) i32;
extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.winapi) i32;
extern "opengl32" fn glClearColor(f32, f32, f32, f32) callconv(.winapi) void;
extern "opengl32" fn glClear(u32) callconv(.winapi) void;
extern "opengl32" fn glViewport(i32, i32, i32, i32) callconv(.winapi) void;
extern "opengl32" fn glScissor(i32, i32, i32, i32) callconv(.winapi) void;
extern "opengl32" fn glEnable(u32) callconv(.winapi) void;
extern "opengl32" fn glDisable(u32) callconv(.winapi) void;
extern "opengl32" fn glFinish() callconv(.winapi) void;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?W.HINSTANCE;

const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_CLIPCHILDREN: u32 = 0x02000000;
const WS_CLIPSIBLINGS: u32 = 0x04000000;
const CS_OWNDC: u32 = 0x20;
const WM_APP: u32 = 0x8000;
const WM_DESTROY: u32 = 0x0002;
const WM_PAINT: u32 = 0x000F;
const WM_ERASEBKGND: u32 = 0x0014;
const PFD_DRAW_TO_WINDOW: u32 = 4;
const PFD_SUPPORT_OPENGL: u32 = 0x20;
const PFD_DOUBLEBUFFER: u32 = 1;
const GL_COLOR_BUFFER_BIT: u32 = 0x4000;
const GL_SCISSOR_TEST: u32 = 0x0C11;

const Child = struct {
    hwnd: HWND,
    dc: HDC,
    ctxs: [4]?HGLRC = .{ null, null, null, null },
    n_ctx: usize = 0,
    swap: bool,
    gl: bool,
};

var children: [16]Child = undefined;
var n_children: usize = 0;
var top: HWND = undefined;
var hinst: W.HINSTANCE = undefined;
var frame: u32 = 0;

const top_w: i32 = 1000;
const top_h: i32 = 700;

fn L(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

fn presentChild(c: *Child) void {
    if (!c.gl or c.n_ctx == 0) return;
    var rc: [4]i32 = undefined;
    _ = GetClientRect(c.hwnd, &rc);
    const w = rc[2];
    const h = rc[3];
    frame +%= 1;
    const t: f32 = @as(f32, @floatFromInt(frame % 8)) / 8.0;
    // every context draws a vertical band (the shared-presenter shape)
    var i: usize = 0;
    while (i < c.n_ctx) : (i += 1) {
        _ = wglMakeCurrent(c.dc, c.ctxs[i].?);
        glViewport(0, 0, w, h);
        glEnable(GL_SCISSOR_TEST);
        const band = @divTrunc(w, @as(i32, @intCast(c.n_ctx)));
        glScissor(band * @as(i32, @intCast(i)), 0, band, h);
        glClearColor(0.1 + 0.2 * @as(f32, @floatFromInt(i)), t, 0.3, 1.0);
        glClear(GL_COLOR_BUFFER_BIT);
        glDisable(GL_SCISSOR_TEST);
        glFinish();
    }
    if (c.swap) _ = SwapBuffers(c.dc);
    _ = wglMakeCurrent(null, null);
}

fn addChild(gl: bool, swap: bool) void {
    const idx = n_children;
    // fixed slots: 4 columns of 250 px, so nothing overlaps
    const x: i32 = @as(i32, @intCast(idx % 4)) * 250;
    const h = CreateWindowExW(0, if (gl) L("T2599ReproGL") else L("T2599ReproGDI"), L(""), WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, x, 0, 250, top_h - 40, top, null, hinst, null) orelse return;
    const dc = GetDC(h).?;
    children[idx] = .{ .hwnd = h, .dc = dc, .swap = swap, .gl = gl };
    if (gl) {
        const pfd = PIXELFORMATDESCRIPTOR{ .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER };
        const pf = ChoosePixelFormat(dc, &pfd);
        _ = SetPixelFormat(dc, pf, &pfd);
        children[idx].ctxs[0] = wglCreateContext(dc);
        children[idx].n_ctx = 1;
    }
    n_children += 1;
    presentChild(&children[idx]);
}

fn addContext() void {
    if (n_children == 0) return;
    const c = &children[0];
    if (!c.gl or c.n_ctx >= 4) return;
    c.ctxs[c.n_ctx] = wglCreateContext(c.dc);
    c.n_ctx += 1;
    presentChild(c);
}

fn destroyNewest() void {
    if (n_children == 0) return;
    n_children -= 1;
    const c = &children[n_children];
    _ = wglMakeCurrent(null, null);
    var i: usize = 0;
    while (i < c.n_ctx) : (i += 1) _ = wglDeleteContext(c.ctxs[i].?);
    _ = DestroyWindow(c.hwnd);
}

fn presentAll() void {
    var i: usize = 0;
    while (i < n_children) : (i += 1) presentChild(&children[i]);
}

fn topProc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_APP => {
            switch (wp) {
                1 => addChild(true, lp == 0),
                2 => destroyNewest(),
                3 => _ = ShowWindow(top, 0),
                4 => {
                    _ = ShowWindow(top, 5);
                    presentAll();
                },
                5 => _ = ShowWindow(top, 6),
                6 => {
                    _ = ShowWindow(top, 9);
                    presentAll();
                },
                7 => presentAll(),
                8 => addChild(false, false),
                9 => addContext(),
                11 => if (n_children > 0) {
                    _ = ShowWindow(children[n_children - 1].hwnd, 0);
                },
                12 => _ = ShowWindow(top, 5),
                13 => _ = ShowWindow(top, 9),
                14 => if (n_children > 0) presentChild(&children[0]),
                10 => {
                    while (n_children > 0) destroyNewest();
                    _ = DestroyWindow(top);
                },
                else => return 0,
            }
            return @intCast(n_children);
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(h, msg, wp, lp),
    }
}

fn glProc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_ERASEBKGND => return 1,
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            _ = BeginPaint(h, &ps);
            _ = EndPaint(h, &ps);
            var i: usize = 0;
            while (i < n_children) : (i += 1) {
                if (children[i].hwnd == h) presentChild(&children[i]);
            }
            return 0;
        },
        else => return DefWindowProcW(h, msg, wp, lp),
    }
}

fn gdiProc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            const dc = BeginPaint(h, &ps).?;
            _ = PatBlt(dc, 0, 0, 250, top_h, 0x00FF0062); // WHITENESS
            _ = EndPaint(h, &ps);
            return 0;
        },
        else => return DefWindowProcW(h, msg, wp, lp),
    }
}

pub fn main() !void {
    hinst = GetModuleHandleW(null).?;
    const brush = GetStockObject(4); // BLACK_BRUSH
    _ = RegisterClassExW(&.{ .lpfnWndProc = topProc, .hInstance = hinst, .lpszClassName = L("T2599Repro"), .hbrBackground = brush });
    _ = RegisterClassExW(&.{ .style = CS_OWNDC, .lpfnWndProc = glProc, .hInstance = hinst, .lpszClassName = L("T2599ReproGL") });
    _ = RegisterClassExW(&.{ .lpfnWndProc = gdiProc, .hInstance = hinst, .lpszClassName = L("T2599ReproGDI") });
    top = CreateWindowExW(0, L("T2599Repro"), L("T2599 repro"), WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, 60, 60, top_w, top_h, null, null, hinst, null).?;
    _ = ShowWindow(top, 5);
    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}
