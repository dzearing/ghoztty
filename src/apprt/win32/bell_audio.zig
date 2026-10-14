//! Plays `bell-audio-path` at `bell-audio-volume` when a bell rings with the
//! `audio` feature on (T1890; Mac `AppDelegate.ghosttyBellDidRing` plays it
//! through `NSSound`).
//!
//! Through MCI's `mpegvideo` device, which is DirectShow underneath: every
//! format Windows has a codec for, asynchronous `play`, and a per-device
//! volume. `PlaySoundW` would be one call, but it plays wav alone and at the
//! system volume, so `bell-audio-volume` would silently mean nothing.
//!
//! winmm is resolved at run time from System32, the gl_loader pattern
//! (T1251): a bell sound is opt-in, so the app does not take a load-time
//! dependency on a DLL most sessions never call, and a `winmm.dll` beside the
//! exe cannot stand in for the real one.
//!
//! GUI thread only - MCI devices belong to the thread that opened them, and
//! `ring_bell` is always handled there. The device is opened once per path and
//! kept, so a ring after the first is a `play from 0` rather than a re-open.

const std = @import("std");
const w32 = @import("win32.zig");
const bell_math = @import("bell_math.zig");

const log = std.log.scoped(.win32_bell);

const MciSendStringW = *const fn (
    command: [*:0]const u16,
    return_string: ?[*]u16,
    return_len: u32,
    callback: ?w32.HWND,
) callconv(.winapi) u32;

var resolved: bool = false;
var mci_send: ?MciSendStringW = null;

/// The path the device is open on, owned; null when nothing is open.
var open_path: ?[]u8 = null;
/// A path that failed to open, so a bell that rings every second does not
/// log (and re-try DirectShow) every second. Cleared when the path changes.
var failed_path: ?[]u8 = null;

fn resolve() ?MciSendStringW {
    if (!resolved) {
        resolved = true;
        const lib = w32.LoadLibraryExW(
            std.unicode.utf8ToUtf16LeStringLiteral("winmm.dll"),
            null,
            w32.LOAD_LIBRARY_SEARCH_SYSTEM32,
        ) orelse {
            log.warn("bell audio: winmm.dll did not load; no bell sound", .{});
            return null;
        };
        mci_send = @ptrCast(w32.GetProcAddress(lib, "mciSendStringW"));
    }
    return mci_send;
}

fn send(f: MciSendStringW, command: [:0]const u8) u32 {
    var wbuf: [1100]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], command) catch return 1;
    wbuf[n] = 0;
    return f(@ptrCast(&wbuf), null, 0, null);
}

/// Play `path` at `volume`. Never fails the caller: a sound that cannot play
/// is logged once per path and the bell's other features carry on.
pub fn play(alloc: std.mem.Allocator, path: []const u8, volume: f64) void {
    const f = resolve() orelse return;
    var buf: [1024]u8 = undefined;

    const same_open = if (open_path) |p| std.mem.eql(u8, p, path) else false;
    if (!same_open) {
        if (failed_path) |p| {
            if (std.mem.eql(u8, p, path)) return;
            alloc.free(p);
            failed_path = null;
        }
        close(alloc);
        const cmd = bell_math.openCommand(&buf, path) catch {
            log.warn("bell audio: cannot play bell-audio-path '{s}'", .{path});
            failed_path = alloc.dupe(u8, path) catch null;
            return;
        };
        const rc = send(f, cmd);
        if (rc != 0) {
            log.warn("bell audio: could not open '{s}' (mci error {d})", .{ path, rc });
            failed_path = alloc.dupe(u8, path) catch null;
            return;
        }
        open_path = alloc.dupe(u8, path) catch {
            _ = send(f, bell_math.close_command);
            return;
        };
    }

    // Set on every ring: a config reload can move the volume without moving
    // the path, and the call is cheap next to the sound itself.
    if (bell_math.volumeCommand(&buf, volume)) |cmd| _ = send(f, cmd) else |_| {}
    const rc = send(f, bell_math.play_command);
    if (rc != 0) {
        log.warn("bell audio: play failed (mci error {d})", .{rc});
        return;
    }
    // The acceptance oracle (bell-features.ps1): a sound cannot be heard by a
    // script, so the app states what it played and at what MCI volume.
    log.info("bell audio played path={s} volume={d}", .{ path, bell_math.mciVolume(volume) });
}

/// Close the device, if open. Safe to call when nothing was ever played.
pub fn close(alloc: std.mem.Allocator) void {
    const p = open_path orelse return;
    if (mci_send) |f| _ = send(f, bell_math.close_command);
    alloc.free(p);
    open_path = null;
}

/// App teardown: close the device and drop the remembered failure.
pub fn deinit(alloc: std.mem.Allocator) void {
    close(alloc);
    if (failed_path) |p| alloc.free(p);
    failed_path = null;
}
