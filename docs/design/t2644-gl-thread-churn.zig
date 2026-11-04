// T2644 repro: does create window + GL context + render on a thread + full
// teardown, repeated, grow private bytes in nvoglv64 on its own?
// Usage: glchurn.exe <iterations> <mode>
//   mode 0: context made current + cleared + swapped on the UI thread
//   mode 1: same, but the render happens on a fresh thread each iteration (ghostty's shape)
//   mode 2: mode 1, plus a texture + buffer + fence created and deleted on the thread
//   mode 3: mode 1, but the render thread deletes its own context before it exits
//   mode 4: one long-lived render thread serves every iteration (a thread pool)
//   mode 5: fresh thread creates, renders and deletes; the UI thread never touches the context
// A third argument is a FLAGS bitmask (T2644 step 2, growing the repro toward the pane):
//   1 = robust context exactly as gl_robust.createContext (plain probe -> wglCreateContextAttribsARB, probe deleted)
//   2 = the GL window is a CHILD of one long-lived top-level (panes are children)
//   4 = the render creates shaders/program/VAO/VBO/texture/FBO/fence and does NOT delete them
//   8 = wglSwapIntervalEXT(1) on the render thread
//  16 = GL_DEBUG_OUTPUT + glDebugMessageCallback, on the UI thread at init and on the render thread (OpenGL.prepareContext)
//  64 = a FRESH top-level per iteration with the GL window as its child; both destroyed (the app's window shape)
//  32 = a linked program + VAO drawn (glDrawArraysInstanced) every frame
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

const Job = struct { dc: HDC, ctx: HGLRC, mode: u32, flags: u32 = 0, deleted: bool = false };

fn dbgCb(_: u32, _: u32, _: u32, _: u32, _: i32, _: [*c]const u8, _: ?*const anyopaque) callconv(.winapi) void {}

extern "opengl32" fn glEnable(u32) callconv(.winapi) void;

fn debugOutput() void {
    glEnable(0x92E0); // GL_DEBUG_OUTPUT
    const cb = getProc(*const fn (*const fn (u32, u32, u32, u32, i32, [*c]const u8, ?*const anyopaque) callconv(.winapi) void, ?*const anyopaque) callconv(.winapi) void, "glDebugMessageCallback");
    cb(dbgCb, null);
    glEnable(0x8DB9); // GL_FRAMEBUFFER_SRGB
}

fn drawProgram() void {
    const createShader = getProc(*const fn (u32) callconv(.winapi) u32, "glCreateShader");
    const shaderSource = getProc(*const fn (u32, i32, *const [*:0]const u8, ?*const i32) callconv(.winapi) void, "glShaderSource");
    const compile = getProc(*const fn (u32) callconv(.winapi) void, "glCompileShader");
    const createProgram = getProc(*const fn () callconv(.winapi) u32, "glCreateProgram");
    const attach = getProc(*const fn (u32, u32) callconv(.winapi) void, "glAttachShader");
    const link = getProc(*const fn (u32) callconv(.winapi) void, "glLinkProgram");
    const use = getProc(*const fn (u32) callconv(.winapi) void, "glUseProgram");
    const genVAO = getProc(*const fn (i32, *u32) callconv(.winapi) void, "glGenVertexArrays");
    const bindVAO = getProc(*const fn (u32) callconv(.winapi) void, "glBindVertexArray");
    const draw = getProc(*const fn (u32, i32, i32, i32) callconv(.winapi) void, "glDrawArraysInstanced");
    const vs_src: [*:0]const u8 = "#version 430 core\nlayout(location=0) out vec2 uv;\nvoid main(){vec2 p=vec2(float(gl_VertexID&1),float(gl_VertexID>>1));uv=p+float(gl_InstanceID)*0.001;gl_Position=vec4(p*2.0-1.0,0.0,1.0);}";
    const fs_src: [*:0]const u8 = "#version 430 core\nlayout(location=0) in vec2 uv;\nlayout(location=0) out vec4 c;\nvoid main(){c=vec4(pow(uv,vec2(2.2)),0.5,1.0);}";
    const vs = createShader(0x8B31);
    shaderSource(vs, 1, &vs_src, null);
    compile(vs);
    const fs = createShader(0x8B30);
    shaderSource(fs, 1, &fs_src, null);
    compile(fs);
    const prog = createProgram();
    attach(prog, vs);
    attach(prog, fs);
    link(prog);
    var vao: u32 = 0;
    genVAO(1, &vao);
    bindVAO(vao);
    use(prog);
    draw(0x0005, 0, 4, 200); // TRIANGLE_STRIP, 200 instances
}

fn getProc(comptime T: type, name: [*:0]const u8) T {
    return @ptrCast(wglGetProcAddress(name) orelse @panic("proc"));
}

// flags & 4: the pane renderer's object set, created and left for wglDeleteContext.
fn leaveObjects() void {
    const GenFn = *const fn (i32, *u32) callconv(.winapi) void;
    const BindFn = *const fn (u32, u32) callconv(.winapi) void;
    const genBuffers = getProc(GenFn, "glGenBuffers");
    const bindBuffer = getProc(BindFn, "glBindBuffer");
    const bufferData = getProc(*const fn (u32, isize, ?*const anyopaque, u32) callconv(.winapi) void, "glBufferData");
    const genVAO = getProc(GenFn, "glGenVertexArrays");
    const bindVAO = getProc(*const fn (u32) callconv(.winapi) void, "glBindVertexArray");
    const genFBO = getProc(GenFn, "glGenFramebuffers");
    const bindFBO = getProc(BindFn, "glBindFramebuffer");
    const createShader = getProc(*const fn (u32) callconv(.winapi) u32, "glCreateShader");
    const shaderSource = getProc(*const fn (u32, i32, *const [*:0]const u8, ?*const i32) callconv(.winapi) void, "glShaderSource");
    const compile = getProc(*const fn (u32) callconv(.winapi) void, "glCompileShader");
    const createProgram = getProc(*const fn () callconv(.winapi) u32, "glCreateProgram");
    const attach = getProc(*const fn (u32, u32) callconv(.winapi) void, "glAttachShader");
    const link = getProc(*const fn (u32) callconv(.winapi) void, "glLinkProgram");
    const fenceSync = getProc(*const fn (u32, u32) callconv(.winapi) ?*anyopaque, "glFenceSync");
    var k: u32 = 0;
    while (k < 4) : (k += 1) {
        var b: u32 = 0;
        genBuffers(1, &b);
        bindBuffer(0x8892, b);
        bufferData(0x8892, 256 * 1024, null, 0x88E8);
        var tex: u32 = 0;
        glGenTextures(1, &tex);
        glBindTexture(0x0DE1, tex);
        glTexImage2D(0x0DE1, 0, 0x8058, 1024, 1024, 0, 0x1908, 0x1401, null);
    }
    var vao: u32 = 0;
    genVAO(1, &vao);
    bindVAO(vao);
    var fbo: u32 = 0;
    genFBO(1, &fbo);
    bindFBO(0x8D40, fbo);
    bindFBO(0x8D40, 0);
    const vs_src: [*:0]const u8 = "#version 330 core\nvoid main(){gl_Position=vec4(0.0);}";
    const fs_src: [*:0]const u8 = "#version 330 core\nout vec4 c;void main(){c=vec4(1.0);}";
    k = 0;
    while (k < 3) : (k += 1) {
        const vs = createShader(0x8B31);
        shaderSource(vs, 1, &vs_src, null);
        compile(vs);
        const fs = createShader(0x8B30);
        shaderSource(fs, 1, &fs_src, null);
        compile(fs);
        const prog = createProgram();
        attach(prog, vs);
        attach(prog, fs);
        link(prog);
    }
    _ = fenceSync(0x9117, 0);
}

fn createRobust(dc: HDC) HGLRC {
    const plain = wglCreateContext(dc) orelse @panic("ctx");
    if (wglMakeCurrent(dc, plain) == 0) @panic("probe-current");
    const create = getProc(*const fn (HDC, ?HGLRC, [*]const i32) callconv(.winapi) ?HGLRC, "wglCreateContextAttribsARB");
    const attribs = [_]i32{ 0x2094, 0x0004, 0x8256, 0x8252, 0 };
    const ctx = create(dc, null, &attribs) orelse @panic("robust");
    _ = wglMakeCurrent(null, null);
    _ = wglDeleteContext(plain);
    return ctx;
}

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
    if (j.flags & 8 != 0) _ = getProc(*const fn (i32) callconv(.winapi) i32, "wglSwapIntervalEXT")(1);
    if (j.flags & 4 != 0) leaveObjects();
    if (j.flags & 16 != 0) debugOutput();
    var f: u32 = 0;
    while (f < 3) : (f += 1) {
        glClearColor(0.1, 0.2, 0.3, 1.0);
        glClear(0x4000);
        if (j.flags & 32 != 0) drawProgram();
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
    const flags = std.fmt.parseInt(u32, args.next() orelse "0", 10) catch 0;
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

    const top: ?HWND = if (flags & 2 != 0) CreateWindowExW(0, cls, cls, 0x10000000 | 0x00CF0000 | 0x02000000, 40, 40, 900, 700, null, null, inst, null) orelse @panic("top") else null;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const iter_top: ?HWND = if (flags & 64 != 0) CreateWindowExW(0, cls, cls, 0x10000000 | 0x00CF0000 | 0x02000000, 40, 40, 900, 700, null, null, inst, null) orelse @panic("itop") else null;
        const parent = iter_top orelse top;
        const style: u32 = if (parent != null) 0x40000000 | 0x10000000 | 0x04000000 | 0x02000000 else 0x10000000 | 0x00CF0000;
        const hwnd = CreateWindowExW(0, cls, cls, style, 0, 0, 800, 600, parent, null, inst, null) orelse @panic("window");
        const dc = GetDC(hwnd) orelse @panic("dc");
        const pfd: PIXELFORMATDESCRIPTOR = .{};
        const pf = ChoosePixelFormat(dc, &pfd);
        if (SetPixelFormat(dc, pf, &pfd) == 0) @panic("pf");
        var job: Job = .{ .dc = dc, .ctx = undefined, .mode = if (mode >= 3) 1 else mode, .flags = flags };
        if (mode != 5) {
            job.ctx = if (flags & 1 != 0) createRobust(dc) else wglCreateContext(dc) orelse @panic("ctx");
            // ghostty shape: current on the UI thread at init, released before the render thread.
            if (wglMakeCurrent(dc, job.ctx) == 0) @panic("ui-current");
            if (flags & 16 != 0) debugOutput();
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
        if (iter_top) |t| _ = DestroyWindow(t);
        pump();
        if (i == 4 or (i + 1) % 10 == 0) std.debug.print("iter {d}: private {d:.1} MB\n", .{ i + 1, privMb() });
    }
}
