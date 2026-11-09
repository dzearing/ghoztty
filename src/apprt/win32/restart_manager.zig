//! Restart Manager participation (T1204).
//!
//! Installing over a running Ghoztty is not an edge case: it is what an
//! upgrade IS, and it is what T1178's in-app updater does by definition. The
//! Windows mechanism for it is the Restart Manager — the installer asks every
//! process holding a file it needs to replace to close, replaces the files,
//! and then starts back up the ones that asked to be restarted. When an app
//! plays along, an upgrade over a live window is a blink; when it does not,
//! Windows Installer is left with a locked file and only bad options: fail the
//! transaction, or schedule the replacement for the next reboot and tell the
//! user to restart their PC. The user met the second one on 2026-08-31.
//!
//! Two halves make an app a participant, and this module is the first:
//!
//!  1. **Ask to be restarted.** `RegisterApplicationRestart` records a command
//!     line the Restart Manager relaunches after it shuts us down. Without it
//!     the installer may still close us — it just never brings us back, so an
//!     "update" ends with the user's terminal gone.
//!  2. **Actually exit when asked.** RM closes a GUI app by sending
//!     `WM_QUERYENDSESSION`/`WM_ENDSESSION` with `ENDSESSION_CLOSEAPP`, then
//!     WAITS for the process to end. An app that answers "yes, I can close"
//!     and then keeps running is worse than one that refuses: RM waits out its
//!     timeout and the install falls back to files-in-use anyway. That half
//!     lives in `Window.zig`'s message handler, which calls
//!     `isCloseAppRequest` below to tell an RM close from a real logoff.
//!
//! Sessions are safe across this by construction: the agent owns the PTYs and
//! an RM close sends no CLOSE for them, exactly like the logoff path (T89e), so
//! the restarted process re-attaches what was there.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.restart_manager);

/// `lParam` bit Windows sets when the session end is a Restart Manager close
/// of THIS application rather than a machine logoff or shutdown.
pub const ENDSESSION_CLOSEAPP: usize = 0x00000001;

/// Do not relaunch us after a crash. Set for Debug builds and test sandboxes
/// only (see `restartFlags`): a shipping build WANTS the crash relaunch.
pub const RESTART_NO_CRASH: u32 = 1;
/// Do not relaunch us after a hang. A hang is answered by the user in the
/// "not responding" dialog, and a relaunch there is out of this module's
/// scope.
pub const RESTART_NO_HANG: u32 = 2;
/// Do not relaunch us after a reboot. Session restore already rebuilds the
/// windows on the next real launch, and a reboot-relaunch would race it.
pub const RESTART_NO_REBOOT: u32 = 8;

/// The flags Ghoztty registers with (T2839).
///
/// **An update** is the case this module was written for (T1204):
/// `RESTART_NO_PATCH` (4) is NEVER in the set, because that flag means "do not
/// restart me when I was terminated for a system update".
///
/// **A crash** is the second case, for shipping builds only. On 2026-11-08 the
/// installed release died inside the graphics driver's own thread, with no
/// Ghoztty code on it, and every window went with it. The sessions were alive
/// in the agent the whole time; nothing brought the windows back to them. On
/// macOS the system answers a crash with its "quit unexpectedly - Reopen"
/// prompt; Windows' counterpart is this registration, under which Windows
/// Error Reporting relaunches the app once the crash is reported. Our own
/// crash filter (`crash/windows.zig`) has already written its dump and
/// returned by then, so nothing races it, and Windows only relaunches a
/// process that ran at least 60 seconds, which is the crash-loop guard. The
/// relaunch is a plain launch, so session restore re-attaches what the agent
/// kept.
///
/// A Debug build and a test sandbox (`sandboxed`) keep `RESTART_NO_CRASH`:
/// acceptance scripts crash the app on purpose (`crash:main`), and a relaunch
/// from Windows lands on the user's own desktop, not the test desktop.
pub fn restartFlags(mode: std.builtin.OptimizeMode, sandboxed: bool) u32 {
    const base = RESTART_NO_HANG | RESTART_NO_REBOOT;
    if (mode == .Debug or sandboxed) return base | RESTART_NO_CRASH;
    return base;
}

/// The environment variables that put a process in a test sandbox: a private
/// IPC endpoint (`os/ipc_client.zig`) or a private agent lineage
/// (`remote/agent_lineage.zig`). Neither is ever set for a user's launch.
pub const sandbox_env_vars = [_][]const u8{ "GHOZTTY_PIPE_SUFFIX", "GHOZTTY_AGENT_INSTANCE" };

fn isSandboxed() bool {
    inline for (sandbox_env_vars) |name| {
        if (std.process.hasEnvVarConstant(name)) return true;
    }
    return false;
}

extern "kernel32" fn RegisterApplicationRestart(
    pwzCommandline: ?[*:0]const u16,
    dwFlags: u32,
) callconv(.winapi) i32;

/// Register this process for relaunch after an update and, in a shipping
/// build, after a crash (`restartFlags`).
///
/// The command line is null, which means "restart me with no arguments" — the
/// executable name is supplied by Windows and must not be repeated here. No
/// arguments is the correct restart for a terminal: a plain launch restores the
/// session layout, where replaying whatever argv this process happened to carry
/// (a `-e` launch command, a URL activation) would re-run it.
///
/// Best effort by design. A failure here costs the polish of being reopened;
/// it must never cost the launch, so it is logged and swallowed.
pub fn register() void {
    if (builtin.os.tag != .windows) return;

    const flags = restartFlags(builtin.mode, isSandboxed());
    const hr = RegisterApplicationRestart(null, flags);
    if (hr == 0) {
        log.info("registered for restart (flags=0x{x}, after crash={})", .{ flags, flags & RESTART_NO_CRASH == 0 });
    } else {
        log.warn("RegisterApplicationRestart failed hr=0x{x}; an installer can close us but will not reopen us", .{@as(u32, @bitCast(hr))});
    }
}

/// True when a `WM_QUERYENDSESSION`/`WM_ENDSESSION` is the Restart Manager
/// asking THIS app to close so its files can be replaced, rather than the
/// machine logging off or shutting down.
///
/// Both cases end this process and both keep the agent's sessions, so the
/// handling barely differs — but only the RM case has somebody waiting on our
/// exit, which is why the caller cares.
pub fn isCloseAppRequest(lparam: usize) bool {
    return (lparam & ENDSESSION_CLOSEAPP) != 0;
}

test "restart flags never exclude an update restart, in any build" {
    const testing = std.testing;

    // The bit that would defeat the update case. RESTART_NO_PATCH == 4 means
    // "do not restart me after a system update".
    const RESTART_NO_PATCH: u32 = 4;
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe, .ReleaseFast, .ReleaseSmall }) |mode| {
        for ([_]bool{ false, true }) |sandboxed| {
            const flags = restartFlags(mode, sandboxed);
            try testing.expect(flags & RESTART_NO_PATCH == 0);
            try testing.expect(flags & RESTART_NO_HANG != 0);
            try testing.expect(flags & RESTART_NO_REBOOT != 0);
        }
    }
}

test "a shipping build is relaunched after a crash (T2839)" {
    const testing = std.testing;

    // 10 = RESTART_NO_HANG | RESTART_NO_REBOOT: a crash relaunch is allowed.
    try testing.expectEqual(@as(u32, 10), restartFlags(.ReleaseFast, false));
    try testing.expectEqual(@as(u32, 10), restartFlags(.ReleaseSafe, false));
    try testing.expectEqual(@as(u32, 10), restartFlags(.ReleaseSmall, false));
}

test "a debug build or a test sandbox is never relaunched after a crash" {
    const testing = std.testing;

    // 11 adds RESTART_NO_CRASH. A test that crashes the app on purpose must
    // not get a window back on the user's desktop.
    try testing.expectEqual(@as(u32, 11), restartFlags(.Debug, false));
    try testing.expectEqual(@as(u32, 11), restartFlags(.Debug, true));
    try testing.expectEqual(@as(u32, 11), restartFlags(.ReleaseFast, true));
}

test "an RM close is told apart from a logoff" {
    const testing = std.testing;

    // What RM sends: ENDSESSION_CLOSEAPP, alone or beside other bits.
    try testing.expect(isCloseAppRequest(ENDSESSION_CLOSEAPP));
    try testing.expect(isCloseAppRequest(ENDSESSION_CLOSEAPP | 0x80000000));

    // What a logoff sends: ENDSESSION_LOGOFF (0x80000000), or zero for a
    // shutdown. Neither has anybody waiting on our exit.
    try testing.expect(!isCloseAppRequest(0x80000000));
    try testing.expect(!isCloseAppRequest(0));
}
