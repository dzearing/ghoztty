// T2644 repro: does create window + GL context + render on a thread + full
// teardown, repeated, grow private bytes in nvoglv64 on its own?
// Usage: glchurn.exe <iterations> <mode>
//   mode 0: context made current + cleared + swapped on the UI thread
//   mode 1: same, but the render happens on a fresh thread each iteration (ghostty's shape)
//   mode 2: mode 1, plus a texture + buffer + fence created and deleted on the thread
//   mode 3: mode 1, but the render thread deletes its own context before it exits
//   mode 4: one long-lived render thread serves every iteration (a thread pool)
//   mode 5: fresh thread creates, renders and deletes; the UI thread never touches the context
// Modes 1-4 also make the context current on the UI thread once at init (ghostty's shape).
// 2026-11-03, 800 iterations: mode 1 109 -> 244 MB (unbounded); mode 4 95.9 MB flat.
// Modes 3 and 5 grow like mode 1 - only NOT exiting the thread avoids it.
const std = @import("std");
const w = std.os.windows;

const HWND = w.HWND;
const HDC = *opaque {};
const HGLRC = *opaque {};

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: u32 = 0x4 | 0x20 | 0x1, // DRAW_TO_WINDOW | SUPPORT_OPENGL | DOUBLEBUFFER
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
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: u32 = 0,
    dwVisibleMask: u32 = 0,
    dwDamageMask: u32 = 0,
};

const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0x20, // CS_OWNDC
    lpfnWndProc: *const fn (HWND, u32, usize, isize) callconv(.winapi) isize,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?w.HINSTANCE,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};

const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: usize, lParam: isize, time: u32, pt_x: i32, pt_y: i32, lPrivate: u32 };

const PROCESS_MEMORY_COUNTERS_EX = extern struct {
    cb: u32 = @sizeOf(PROCESS_MEMORY_COUNTERS_EX),
    PageFaultCount: u32 = 0,
    PeakWorkingSetSize: usize = 0,
    WorkingSetSize: usize = 0,
    QuotaPeakPagedPoolUsage: usize = 0,
    QuotaPagedPoolUsage: usize = 0,
    QuotaPeakNonPagedPoolUsage: usize = 0,
    QuotaNonPagedPoolUsage: usize = 0,
    PagefileUsage: usize = 0,
    PeakPagefileUsage: usize = 0,
    PrivateUsage: usize = 0,
};

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?w.HINSTANCE, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) i32;
extern "user32" fn DefWindowProcW(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) i32;
extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) isize;
extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
extern "gdi32" fn SetPixelFormat(HDC, i32, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
extern "gdi32" fn SwapBuffers(HDC) callconv(.winapi) i32;
extern "opengl32" fn wglCreateContext(HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.winapi) i32;
extern "opengl32" fn wglMakeCurrent(?HDC, ?HGLRC) callconv(.winapi) i32;
extern "opengl32" fn wglGetProcAddress([*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "opengl32" fn glClearColor(f32, f32, f32, f32) callconv(.winapi) void;
extern "opengl32" fn glClear(u32) callconv(.winapi) void;
extern "opengl32" fn glFinish() callconv(.winapi) void;
extern "opengl32" fn glGenTextures(i32, *u32) callconv(.winapi) void;
extern "opengl32" fn glDeleteTextures(i32, *const u32) callconv(.winapi) void;
extern "opengl32" fn glBindTexture(u32, u32) callconv(.winapi) void;
extern "opengl32" fn glTexImage2D(u32, i32, i32, i32, i32, i32, u32, u32, ?*const anyopaque) callconv(.winapi) void;
extern "psapi" fn GetProcessMemoryInfo(w.HANDLE, *PROCESS_MEMORY_COUNTERS_EX, u32) callconv(.winapi) i32;

fn wndProc(h: HWND, m: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    return DefWindowProcW(h, m, wp, lp);
}

fn privMb() f64 {
    var c: PROCESS_MEMORY_COUNTERS_EX = .{};
    _ = GetProcessMemoryInfo(w.GetCurrentProcess(), &c, @sizeOf(PROCESS_MEMORY_COUNTERS_EX));
    return @as(f64, @floatFromInt(c.PrivateUsage)) / (1024.0 * 1024.0);
}

fn pump() void {
    var msg: MSG = undefined;
    while (PeekMessageW(&msg, null, 0, 0, 1) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

const Job = struct { dc: HDC, ctx: HGLRC, mode: u32, deleted: bool = false };

// mode 3: fresh thread renders, then deletes its own context before it exits.
fn renderAndDelete(j: *Job) void {
    render(j);
    if (wglDeleteContext(j.ctx) == 0) @panic("delete-on-thread");
    j.deleted = true;
}

// mode 5: fresh thread creates, renders, deletes - context never touches the UI thread.
fn createRenderDelete(j: *Job) void {
    j.ctx = wglCreateContext(j.dc) orelse @panic("ctx-thread");
    render(j);
    if (wglDeleteContext(j.ctx) == 0) @panic("delete-on-thread");
    j.deleted = true;
}

// mode 4: one long-lived worker serves every iteration.
const Pool = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    job: ?*Job = null,
    done: bool = false,
    quit: bool = false,
    fn run(p: *Pool) void {
        while (true) {
            p.mutex.lock();
            while (p.job == null and !p.quit) p.cond.wait(&p.mutex);
            if (p.quit) {
                p.mutex.unlock();
                return;
            }
            const j = p.job.?;
            p.mutex.unlock();
            render(j);
            p.mutex.lock();
            p.job = null;
            p.done = true;
            p.cond.broadcast();
            p.mutex.unlock();
        }
    }
    fn submit(p: *Pool, j: *Job) void {
        p.mutex.lock();
        p.job = j;
        p.done = false;
        p.cond.broadcast();
        while (!p.done) p.cond.wait(&p.mutex);
        p.mutex.unlock();
    }
};

fn render(j: *const Job) void {
    if (wglMakeCurrent(j.dc, j.ctx) == 0) @panic("makeCurrent");
    var f: u32 = 0;
    while (f < 3) : (f += 1) {
        glClearColor(0.1, 0.2, 0.3, 1.0);
        glClear(0x4000);
        if (j.mode == 2) {
            var tex: u32 = 0;
            glGenTextures(1, &tex);
            glBindTexture(0x0DE1, tex);
            glTexImage2D(0x0DE1, 0, 0x8058, 512, 512, 0, 0x1908, 0x1401, null);
            glDeleteTextures(1, &tex);
        }
        _ = SwapBuffers(j.dc);
    }
    glFinish();
    _ = wglMakeCurrent(null, null);
}

pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    _ = args.next();
    const n = std.fmt.parseInt(u32, args.next() orelse "60", 10) catch 60;
    const mode = std.fmt.parseInt(u32, args.next() orelse "1", 10) catch 1;
    const inst: w.HINSTANCE = @ptrCast(w.kernel32.GetModuleHandleW(null).?);
    const cls = std.unicode.utf8ToUtf16LeStringLiteral("glchurn");
    _ = RegisterClassExW(&.{ .lpfnWndProc = wndProc, .hInstance = inst, .lpszClassName = cls });

    var pool: Pool = .{};
    var pool_t: ?std.Thread = null;
    if (mode == 4) pool_t = try std.Thread.spawn(.{}, Pool.run, .{&pool});
    defer if (pool_t) |t| {
        pool.mutex.lock();
        pool.quit = true;
        pool.cond.broadcast();
        pool.mutex.unlock();
        t.join();
    };

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const hwnd = CreateWindowExW(0, cls, cls, 0x10000000 | 0x00CF0000, 40, 40, 800, 600, null, null, inst, null) orelse @panic("window");
        const dc = GetDC(hwnd) orelse @panic("dc");
        const pfd: PIXELFORMATDESCRIPTOR = .{};
        const pf = ChoosePixelFormat(dc, &pfd);
        if (SetPixelFormat(dc, pf, &pfd) == 0) @panic("pf");
        var job: Job = .{ .dc = dc, .ctx = undefined, .mode = if (mode >= 3) 1 else mode };
        if (mode != 5) {
            job.ctx = wglCreateContext(dc) orelse @panic("ctx");
            // ghostty shape: current on the UI thread at init, released before the render thread.
            if (wglMakeCurrent(dc, job.ctx) == 0) @panic("ui-current");
            glClear(0x4000);
            _ = wglMakeCurrent(null, null);
        }
        switch (mode) {
            0 => render(&job),
            3 => (try std.Thread.spawn(.{}, renderAndDelete, .{&job})).join(),
            4 => pool.submit(&job),
            5 => (try std.Thread.spawn(.{}, createRenderDelete, .{&job})).join(),
            else => (try std.Thread.spawn(.{}, render, .{&job})).join(),
        }
        pump();
        if (!job.deleted and wglDeleteContext(job.ctx) == 0) @panic("delete");
        _ = ReleaseDC(hwnd, dc);
        _ = DestroyWindow(hwnd);
        pump();
        if (i == 4 or (i + 1) % 10 == 0) std.debug.print("iter {d}: private {d:.1} MB\n", .{ i + 1, privMb() });
    }
}
