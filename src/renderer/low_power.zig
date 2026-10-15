//! Low-power rendering (T1951).
//!
//! On a machine with no GPU - a Windows 365 Cloud PC, a VM, anything whose
//! OpenGL is Mesa on WARP or llvmpipe - every frame is rasterized on the CPU,
//! so the cost of the app is presents per second times pixels. GitHub #13
//! measured it: 16 panes in 11 windows at DPI 192 kept 32 WARP workers busy
//! and the app at 12-16 cores, and turning the visual effects off moved it by
//! nothing. Over Remote Desktop the same frames are also encoded and sent.
//!
//! So while the renderer is software OR the session is remote, each pane's
//! presents are capped: the focused pane up to `focused_ms` apart (about 30
//! fps, which is still a full typing rate), every other visible pane up to
//! `unfocused_ms` apart (4 fps), and an unfocused pane loses the 500 ms
//! safety present (T1935) - nothing it shows is worth a frame nobody asked
//! for. A frame that something FORCES (resize, focus, config, a repaint the
//! window manager asked for) is never held back. Hidden panes are not drawn
//! at all, in every mode; that is the apprt's job (`occlusionCallback`).
//!
//! Two inputs, set from different places: the renderer reports `software`
//! after it reads `GL_RENDERER`/`GL_VENDOR`; the apprt reports `remote` from
//! the session. The decision is app-wide and read lock-free by every renderer
//! thread.

const std = @import("std");

const log = std.log.scoped(.low_power);

/// The focused pane's minimum spacing between presents (~30 fps).
pub const focused_ms: u64 = 33;
/// Every other visible pane's minimum spacing (4 fps).
pub const unfocused_ms: u64 = 250;

var remote: std.atomic.Value(bool) = .init(false);
var software: std.atomic.Value(bool) = .init(false);

pub fn active() bool {
    return remote.load(.monotonic) or software.load(.monotonic);
}

pub fn isSoftware() bool {
    return software.load(.monotonic);
}

pub fn isRemote() bool {
    return remote.load(.monotonic);
}

/// The apprt's answer to "is this session remote?".
pub fn setRemote(v: bool) void {
    if (remote.swap(v, .monotonic) == v) return;
    log.info("low-power rendering {s}: remote session {s}", .{
        if (active()) "on" else "off",
        if (v) "started" else "ended",
    });
}

/// The renderer's answer to "is this OpenGL rasterized on the CPU?", with the
/// strings it decided from so the log line explains itself.
pub fn setSoftware(v: bool, renderer: []const u8, vendor: []const u8) void {
    if (software.swap(v, .monotonic) == v) return;
    log.info("low-power rendering {s}: renderer=\"{s}\" vendor=\"{s}\" is {s}", .{
        if (active()) "on" else "off",
        renderer,
        vendor,
        if (v) "software" else "hardware",
    });
}

/// Does this `GL_RENDERER` / `GL_VENDOR` pair rasterize on the CPU? Mesa's
/// d3d12 driver reports the D3D adapter in the renderer string ("D3D12
/// (Microsoft Basic Render Driver)" on WARP); llvmpipe and softpipe are
/// Mesa's own CPU rasterizers; "GDI Generic" is Windows' built-in OpenGL 1.1.
pub fn isSoftwareRenderer(renderer: []const u8, vendor: []const u8) bool {
    const needles = [_][]const u8{
        "basic render driver",
        "warp",
        "llvmpipe",
        "softpipe",
        "swrast",
        "gdi generic",
    };
    for (needles) |n| {
        if (std.ascii.indexOfIgnoreCase(renderer, n) != null) return true;
        if (std.ascii.indexOfIgnoreCase(vendor, n) != null) return true;
    }
    return false;
}

/// How long a renderer woken by new output should wait before building and
/// presenting a frame, or null to do it now. `since_last_ns` is the time since
/// this pane last built a frame (null: never, or no clock).
pub fn deferMs(on: bool, focused: bool, forced: bool, since_last_ns: ?u64) ?u64 {
    if (!on or forced) return null;
    const since = since_last_ns orelse return null;
    const cap_ns = (if (focused) focused_ms else unfocused_ms) * std.time.ns_per_ms;
    if (since >= cap_ns) return null;
    return @max((cap_ns - since) / std.time.ns_per_ms, 1);
}

/// Whether the 500 ms "present anyway" bound applies to this pane. In
/// low-power mode an unfocused pane presents only what changed or was forced.
pub fn safetyBound(on: bool, focused: bool) bool {
    return !on or focused;
}

const testing = std.testing;

test "low_power: software renderers are recognised, hardware ones are not" {
    try testing.expect(isSoftwareRenderer("D3D12 (Microsoft Basic Render Driver)", "Microsoft Corporation"));
    try testing.expect(isSoftwareRenderer("llvmpipe (LLVM 17.0.6, 256 bits)", "Mesa"));
    try testing.expect(isSoftwareRenderer("softpipe", "Mesa"));
    try testing.expect(isSoftwareRenderer("GDI Generic", "Microsoft Corporation"));
    try testing.expect(isSoftwareRenderer("Microsoft WARP", ""));
    try testing.expect(!isSoftwareRenderer("NVIDIA GeForce RTX 4090/PCIe/SSE2", "NVIDIA Corporation"));
    try testing.expect(!isSoftwareRenderer("D3D12 (NVIDIA GeForce RTX 4090)", "Microsoft Corporation"));
    try testing.expect(!isSoftwareRenderer("AMD Radeon(TM) Graphics", "ATI Technologies Inc."));
    try testing.expect(!isSoftwareRenderer("Intel(R) UHD Graphics 630", "Intel"));
}

test "low_power: off means render now, always" {
    try testing.expectEqual(@as(?u64, null), deferMs(false, false, false, 0));
    try testing.expectEqual(@as(?u64, null), deferMs(false, true, false, 1));
}

test "low_power: a forced frame or a first frame is never held back" {
    try testing.expectEqual(@as(?u64, null), deferMs(true, false, true, 0));
    try testing.expectEqual(@as(?u64, null), deferMs(true, false, false, null));
}

test "low_power: the focused pane is capped near 30 fps, the rest at 4" {
    const ms = std.time.ns_per_ms;
    try testing.expectEqual(@as(?u64, 23), deferMs(true, true, false, 10 * ms));
    try testing.expectEqual(@as(?u64, null), deferMs(true, true, false, 33 * ms));
    try testing.expectEqual(@as(?u64, 240), deferMs(true, false, false, 10 * ms));
    try testing.expectEqual(@as(?u64, null), deferMs(true, false, false, 250 * ms));
    // Never a zero-length timer.
    try testing.expectEqual(@as(?u64, 1), deferMs(true, true, false, 33 * ms - 1));
}

test "low_power: the safety present is dropped only for unfocused panes" {
    try testing.expect(safetyBound(false, false));
    try testing.expect(safetyBound(true, true));
    try testing.expect(!safetyBound(true, false));
}

test "low_power: active is either input" {
    defer {
        remote.store(false, .monotonic);
        software.store(false, .monotonic);
    }
    try testing.expect(!active());
    setRemote(true);
    try testing.expect(active());
    setRemote(false);
    setSoftware(true, "llvmpipe", "Mesa");
    try testing.expect(active());
}
