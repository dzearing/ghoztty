//! Surviving a lost graphics device (T1690).
//!
//! THE DEFECT this exists for: on 2026-09-20 Windows Update replaced the
//! NVIDIA display driver under a running Ghoztty. The renderer logged three
//! "software processing fallback" warnings and the whole process vanished,
//! every window with it, with no exception anybody could catch. A context made
//! by plain `wglCreateContext` has no contract at all for a device reset: what
//! happens next is whatever that driver does, and a driver swap is the case
//! drivers handle worst.
//!
//! THE FIX has two halves:
//!
//! 1. Ask for a ROBUST context (`WGL_ARB_create_context_robustness`, with
//!    `WGL_LOSE_CONTEXT_ON_RESET_ARB`). That turns a device reset from
//!    undefined behaviour into a reported state: GL calls on the dead context
//!    become harmless no-ops and `glGetGraphicsResetStatus` stops answering
//!    `GL_NO_ERROR`. A driver that does not offer the extension still gets a
//!    plain context, exactly as before.
//! 2. Check that status once per presented frame, and when it trips, throw the
//!    context away and build a new one on the same window, then rebuild every
//!    GPU resource the renderer owns. The terminal, its scrollback and its
//!    shell are CPU-side and never noticed.
//!
//! A new driver can take a while to arrive, so the rebuild is retried on a
//! backoff until it produces a context the renderer can use again.
//!
//! THE POLICY IS SEPARATE FROM THE SYSCALLS, the same way as `gl_loader`:
//! the attribute list, the extension-string match, the reset-status mapping and
//! the retry schedule are pure and tested in both lanes, including the
//! `-Dapp-runtime=none` lane that never touches a Windows API.

const std = @import("std");
const builtin = @import("builtin");
const gl_loader = @import("gl_loader.zig");

const log = std.log.scoped(.gl_robust);

// WGL_ARB_create_context / WGL_ARB_create_context_robustness.
pub const WGL_CONTEXT_FLAGS_ARB: i32 = 0x2094;
pub const WGL_CONTEXT_ROBUST_ACCESS_BIT_ARB: i32 = 0x0004;
pub const WGL_CONTEXT_RESET_NOTIFICATION_STRATEGY_ARB: i32 = 0x8256;
pub const WGL_LOSE_CONTEXT_ON_RESET_ARB: i32 = 0x8252;

// GL_KHR_robustness / GL 4.5 reset status values.
pub const GL_NO_ERROR: u32 = 0;
pub const GL_GUILTY_CONTEXT_RESET: u32 = 0x8253;
pub const GL_INNOCENT_CONTEXT_RESET: u32 = 0x8254;
pub const GL_UNKNOWN_CONTEXT_RESET: u32 = 0x8255;

pub const robustness_extension = "WGL_ARB_create_context_robustness";

/// The attributes a robust context is requested with. No version and no
/// profile on purpose: `wglCreateContextAttribsARB` with neither returns the
/// same newest compatibility context a plain `wglCreateContext` does, so the
/// only thing this request changes is what happens when the device goes away.
pub const robust_attribs = [_]i32{
    WGL_CONTEXT_FLAGS_ARB,                       WGL_CONTEXT_ROBUST_ACCESS_BIT_ARB,
    WGL_CONTEXT_RESET_NOTIFICATION_STRATEGY_ARB, WGL_LOSE_CONTEXT_ON_RESET_ARB,
    0,
};

/// Whether a space-separated extension string names `name` as a whole token.
/// A substring match is wrong: `WGL_ARB_create_context_robustness` contains
/// `WGL_ARB_create_context`, and the reverse question must not be answered yes.
pub fn hasExtension(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, name)) return true;
    }
    return false;
}

/// What `glGetGraphicsResetStatus` said, reduced to what the renderer acts on.
pub const ResetStatus = enum {
    none,
    guilty,
    innocent,
    unknown,

    pub fn fromGl(v: u32) ResetStatus {
        return switch (v) {
            GL_NO_ERROR => .none,
            GL_GUILTY_CONTEXT_RESET => .guilty,
            GL_INNOCENT_CONTEXT_RESET => .innocent,
            // Anything else non-zero is still "the context is gone": a status
            // this code does not recognise is not a reason to keep drawing
            // into a device that stopped answering.
            else => .unknown,
        };
    }

    pub fn lost(self: ResetStatus) bool {
        return self != .none;
    }
};

/// How long to wait before rebuild attempt number `attempt` (0-based). The
/// first try is immediate — an ordinary reset (a TDR, Win+Ctrl+Shift+B) is
/// over by the time it is reported — and the rest back off to a five second
/// ceiling that is kept for as long as it takes: a driver being REPLACED can
/// leave the machine on the basic display adapter for a minute or more, and
/// giving up would leave a blank window over a live shell.
pub fn retryDelayMs(attempt: u32) u32 {
    const schedule = [_]u32{ 0, 250, 1000, 2000 };
    if (attempt < schedule.len) return schedule[attempt];
    return 5000;
}

/// Whether a failed attempt is worth a log line. The first few are, then one
/// in twelve (about a minute apart at the ceiling), so an outage that lasts
/// an hour leaves a readable log rather than seven hundred identical lines.
pub fn shouldLogAttempt(attempt: u32) bool {
    return attempt < 4 or attempt % 12 == 0;
}

// -------------------------------------------------------------------------
// The Windows half.
// -------------------------------------------------------------------------

const HDC = gl_loader.HDC;
const HGLRC = gl_loader.HGLRC;

const CreateContextAttribsFn = *const fn (HDC, HGLRC, [*]const i32) callconv(.winapi) HGLRC;
const GetExtensionsStringFn = *const fn (HDC) callconv(.winapi) ?[*:0]const u8;

pub const Created = struct {
    hglrc: HGLRC,
    robust: bool,
};

/// Create a context on `hdc`, robust when the driver offers it and plain when
/// it does not. Leaves NO context current on the calling thread — the callers
/// (surface creation on the UI thread, a rebuild on the renderer thread) each
/// make the result current themselves.
///
/// Asking for a robust context needs a context to already exist, because
/// `wglCreateContextAttribsARB` is itself reachable only through
/// `wglGetProcAddress` with some context current. So a plain one is made
/// first; if the robust request succeeds the plain one is deleted, and if it
/// does not the plain one IS the answer.
pub fn createContext(hdc: HDC) ?Created {
    if (comptime builtin.os.tag != .windows) return null;

    const api = gl_loader.active();
    const plain = api.createContext(hdc) orelse return null;

    if (api.makeCurrent(hdc, plain) == 0) {
        // Cannot probe; the plain context is still perfectly usable.
        return .{ .hglrc = plain, .robust = false };
    }

    const robust = robust: {
        const ext_proc = api.proc("wglGetExtensionsStringARB") orelse break :robust null;
        const get_ext: GetExtensionsStringFn = @ptrCast(ext_proc);
        const exts = get_ext(hdc) orelse break :robust null;
        if (!hasExtension(std.mem.sliceTo(exts, 0), robustness_extension)) break :robust null;

        const create_proc = api.proc("wglCreateContextAttribsARB") orelse break :robust null;
        const create: CreateContextAttribsFn = @ptrCast(create_proc);
        break :robust create(hdc, null, &robust_attribs);
    };

    _ = api.makeCurrent(null, null);

    if (robust) |ctx| {
        _ = api.deleteContext(plain);
        return .{ .hglrc = ctx, .robust = true };
    }
    return .{ .hglrc = plain, .robust = false };
}

// -------------------------------------------------------------------------
// Tests. The syscall half is covered by `test\win32\gl-device-lost.ps1`,
// which drives a real rebuild through the debug-only simulation hooks.
// -------------------------------------------------------------------------

test "robust_attribs: flags and reset strategy, zero terminated, no version" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 5), robust_attribs.len);
    try testing.expectEqual(@as(i32, 0), robust_attribs[robust_attribs.len - 1]);
    try testing.expectEqual(WGL_CONTEXT_FLAGS_ARB, robust_attribs[0]);
    try testing.expectEqual(WGL_CONTEXT_ROBUST_ACCESS_BIT_ARB, robust_attribs[1]);
    try testing.expectEqual(WGL_CONTEXT_RESET_NOTIFICATION_STRATEGY_ARB, robust_attribs[2]);
    try testing.expectEqual(WGL_LOSE_CONTEXT_ON_RESET_ARB, robust_attribs[3]);
}

test "hasExtension: whole tokens only" {
    const testing = std.testing;
    const list = "WGL_ARB_pixel_format WGL_ARB_create_context WGL_ARB_create_context_robustness";
    try testing.expect(hasExtension(list, robustness_extension));
    try testing.expect(hasExtension(list, "WGL_ARB_create_context"));
    try testing.expect(!hasExtension("WGL_ARB_create_context", robustness_extension));
    try testing.expect(!hasExtension("WGL_ARB_create_context_robustness_v2", robustness_extension));
    try testing.expect(!hasExtension("", robustness_extension));
    try testing.expect(hasExtension("  " ++ robustness_extension ++ "\n", robustness_extension));
}

test "ResetStatus: only GL_NO_ERROR means the context is alive" {
    const testing = std.testing;
    try testing.expect(!ResetStatus.fromGl(GL_NO_ERROR).lost());
    try testing.expectEqual(ResetStatus.guilty, ResetStatus.fromGl(GL_GUILTY_CONTEXT_RESET));
    try testing.expectEqual(ResetStatus.innocent, ResetStatus.fromGl(GL_INNOCENT_CONTEXT_RESET));
    try testing.expectEqual(ResetStatus.unknown, ResetStatus.fromGl(GL_UNKNOWN_CONTEXT_RESET));
    try testing.expect(ResetStatus.fromGl(GL_UNKNOWN_CONTEXT_RESET).lost());
    try testing.expect(ResetStatus.fromGl(0x1234).lost());
}

test "retryDelayMs: immediate first, then backs off to a ceiling it keeps" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0), retryDelayMs(0));
    try testing.expectEqual(@as(u32, 250), retryDelayMs(1));
    try testing.expectEqual(@as(u32, 1000), retryDelayMs(2));
    try testing.expectEqual(@as(u32, 2000), retryDelayMs(3));
    try testing.expectEqual(@as(u32, 5000), retryDelayMs(4));
    try testing.expectEqual(@as(u32, 5000), retryDelayMs(10_000));
    var prev: u32 = 0;
    for (0..40) |i| {
        const d = retryDelayMs(@intCast(i));
        try testing.expect(d >= prev);
        prev = d;
    }
}

test "shouldLogAttempt: early attempts, then sparse" {
    const testing = std.testing;
    for (0..4) |i| try testing.expect(shouldLogAttempt(@intCast(i)));
    try testing.expect(!shouldLogAttempt(5));
    try testing.expect(shouldLogAttempt(12));
    try testing.expect(!shouldLogAttempt(13));
    try testing.expect(shouldLogAttempt(24));
}
