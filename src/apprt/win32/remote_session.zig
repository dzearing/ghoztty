//! Is this a Remote Desktop session? (T1951)
//!
//! Over Remote Desktop every pixel the app changes is drawn in software and
//! sent over the wire, so while the session is remote the app loads its config
//! through `config.remote_effects.apply` (glass, blur, blink and the unfocused
//! dim off, unless the user set them by name) and stops in-window motion (the
//! focus glow's move, the sidebar shimmer, the banner and hero animations).
//!
//! One logon moves between the console and Remote Desktop without the app
//! restarting, so the answer is re-read on `WM_WTSSESSION_CHANGE`, which the
//! app's message window registers for (`register`). The check is the one
//! `DimOverlay` already makes: `GetSystemMetrics(SM_REMOTESESSION)`.
//!
//! Test seam: `GHOZTTY_TEST_REMOTE_SESSION_FILE` names a file whose first byte
//! answers instead (`1` remote, anything else console). It is re-read on every
//! check, so a script flips the session by rewriting the file and posting
//! `WM_WTSSESSION_CHANGE` to a top-level window, which forwards it to the app.

const std = @import("std");
const w32 = @import("win32.zig");

const log = std.log.scoped(.remote_session);

pub const WM_WTSSESSION_CHANGE: u32 = 0x02B1;
const NOTIFY_FOR_THIS_SESSION: u32 = 0;

extern "wtsapi32" fn WTSRegisterSessionNotification(hwnd: w32.HWND, flags: u32) callconv(.winapi) i32;
extern "wtsapi32" fn WTSUnRegisterSessionNotification(hwnd: w32.HWND) callconv(.winapi) i32;

const seam_env = "GHOZTTY_TEST_REMOTE_SESSION_FILE";

/// Whether the effects are off right now. Read by `App.clientAreaAnimationsEnabled`,
/// which is a free function the chrome calls from anywhere on the GUI thread,
/// so it lives here rather than on the App.
var effects_reduced: bool = false;

/// Is the session remote right now?
pub fn isRemote() bool {
    if (seamAnswer()) |answer| return answer;
    return w32.GetSystemMetrics(w32.SM_REMOTESESSION) != 0;
}

fn seamAnswer() ?bool {
    var path_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&path_buf);
    const path = std.process.getEnvVarOwned(fba.allocator(), seam_env) catch return null;
    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    var byte: [1]u8 = undefined;
    const n = file.read(&byte) catch return false;
    return n == 1 and byte[0] == '1';
}

/// Record the state the config was last loaded under.
pub fn setReduced(on: bool) void {
    effects_reduced = on;
}

pub fn reduced() bool {
    return effects_reduced;
}

/// Ask Windows to tell `hwnd` when this session connects or disconnects,
/// locally or remotely. Failure is logged and otherwise ignored: the startup
/// answer still stands, the app just will not notice a later switch.
pub fn register(hwnd: w32.HWND) void {
    if (WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION) == 0) {
        log.warn("WTSRegisterSessionNotification failed err={}", .{w32.GetLastError()});
    }
}

pub fn unregister(hwnd: w32.HWND) void {
    _ = WTSUnRegisterSessionNotification(hwnd);
}

/// The notice shown when a live switch changes the effects.
pub fn noticeText(reduced_now: bool, remote: bool) struct { title: []const u8, body: []const u8 } {
    if (!reduced_now) return .{
        .title = "Back on this PC",
        .body = "Visual effects are back on.",
    };
    return if (remote) .{
        .title = "Remote Desktop",
        .body = "Visual effects are off and background panes redraw less often, to keep typing fast. They come back when you return to this PC.",
    } else .{
        .title = "No graphics card",
        .body = "This PC draws in software, so visual effects are off and background panes redraw less often, to keep typing fast.",
    };
}

// `WM_WTSSESSION_CHANGE` codes (wparam).
const WTS_CONSOLE_CONNECT = 0x1;
const WTS_CONSOLE_DISCONNECT = 0x2;
const WTS_REMOTE_CONNECT = 0x3;
const WTS_REMOTE_DISCONNECT = 0x4;
const WTS_SESSION_LOCK = 0x7;
const WTS_SESSION_UNLOCK = 0x8;

/// Whether nobody can see this session after the event `code`: true for a
/// lock or a disconnect, false for an unlock or a connect, null for an event
/// that does not change it (logon, remote control, ...).
pub fn sessionHiddenAfter(code: usize) ?bool {
    return switch (code) {
        WTS_CONSOLE_DISCONNECT, WTS_REMOTE_DISCONNECT, WTS_SESSION_LOCK => true,
        WTS_CONSOLE_CONNECT, WTS_REMOTE_CONNECT, WTS_SESSION_UNLOCK => false,
        else => null,
    };
}

pub fn eventName(code: usize) []const u8 {
    return switch (code) {
        WTS_CONSOLE_CONNECT => "console connect",
        WTS_CONSOLE_DISCONNECT => "console disconnect",
        WTS_REMOTE_CONNECT => "remote connect",
        WTS_REMOTE_DISCONNECT => "remote disconnect",
        WTS_SESSION_LOCK => "lock",
        WTS_SESSION_UNLOCK => "unlock",
        else => "change",
    };
}

test "remote_session: lock and disconnect hide the session, unlock and connect show it" {
    const testing = std.testing;
    try testing.expectEqual(@as(?bool, true), sessionHiddenAfter(WTS_SESSION_LOCK));
    try testing.expectEqual(@as(?bool, true), sessionHiddenAfter(WTS_REMOTE_DISCONNECT));
    try testing.expectEqual(@as(?bool, true), sessionHiddenAfter(WTS_CONSOLE_DISCONNECT));
    try testing.expectEqual(@as(?bool, false), sessionHiddenAfter(WTS_SESSION_UNLOCK));
    try testing.expectEqual(@as(?bool, false), sessionHiddenAfter(WTS_REMOTE_CONNECT));
    try testing.expectEqual(@as(?bool, false), sessionHiddenAfter(WTS_CONSOLE_CONNECT));
    try testing.expectEqual(@as(?bool, null), sessionHiddenAfter(5));
}
