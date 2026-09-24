//! The pure half of the installer's Repair / Cancel custom action (T1730).
//!
//! `install_ca.zig` is the DLL msiexec loads; this file is everything in it that
//! can be decided without a process, so the lane checks it. It imports nothing
//! but `std` because the DLL must stay tiny and dependency-free.
//!
//! ## Why a DLL at all
//!
//! T1291 asked the question through an EXE custom action (type 50) and had the
//! exe exit 1602 on Cancel, on the premise that 1602 is the one exit code
//! Windows Installer reads as "the user said no". It is not. For an EXE action
//! authored `Return="check"`, EVERY non-zero exit is a failure: msiexec logs
//! `returned actual error code 1602`, then raises error 1722 ("There is a
//! problem with this Windows Installer package. A program run as part of the
//! setup did not finish as expected"), and the install ends at 1603. T1302's
//! walk against a real msiexec is what caught it.
//!
//! The user-exit mapping belongs to actions whose RETURN VALUE is an action
//! status - DLL and script actions. So the DLL runs the same
//! `ghoztty.exe --install-maintenance`, waits for it, and returns
//! `ERROR_INSTALL_USEREXIT` itself when the exe said Cancel. The exe's contract
//! (Repair 0, Cancel 1602, `install_maintenance.zig`) is unchanged, which also
//! keeps the old EXE-action packages' behaviour reproducible.

const std = @import("std");

/// `ERROR_SUCCESS`: let the pre-armed repair proceed.
pub const status_proceed: u32 = 0;

/// `ERROR_INSTALL_USEREXIT`. Returned from a DLL action this ends the
/// transaction as a user exit - quietly, msiexec exit 1602 - which is what the
/// same number returned as an EXE's exit code does NOT do.
pub const status_user_exit: u32 = 1602;

/// The exe's own Cancel code (`install_maintenance.user_exit_code`).
pub const exe_cancel_code: u32 = 1602;

/// What msiexec is told, given what the exe did.
///
/// `null` means the exe never ran or its exit code could not be read. That
/// PROCEEDS with the repair rather than failing or cancelling: the person
/// double-clicked the installer for the version they have, a pre-armed
/// REINSTALL is exactly what fixes an install whose exe cannot start, and a
/// failure here would put back the 1722 error box this task removes.
///
/// Any exit other than Cancel's also proceeds, for the same reason: only an
/// explicit Cancel may stop the installer.
pub fn status(exe_exit: ?u32) u32 {
    const code = exe_exit orelse return status_proceed;
    return if (code == exe_cancel_code) status_user_exit else status_proceed;
}

/// Build the command line msiexec's old EXE action ran:
/// `"<INSTALLDIR>ghoztty.exe" --install-maintenance --installed-version=<v>`.
///
/// `install_dir` is `[INSTALLDIR]` as Windows Installer resolves it (with a
/// trailing backslash, though one is added when missing). An empty `version`
/// drops the flag, and the exe then names its own build. The exe path is
/// quoted because `%LOCALAPPDATA%` can contain spaces; the version is not,
/// since it is a dotted number from the package's own Property table.
///
/// Returns the NUL-terminated UTF-16 command line in `buf`, or null when it
/// does not fit or the version would need quoting.
pub fn commandLine(buf: []u16, install_dir: []const u16, version: []const u16) ?[:0]u16 {
    for (version) |c| if (c == ' ' or c == '"' or c == '\t') return null;

    var i: usize = 0;
    const put = struct {
        fn f(b: []u16, at: *usize, s: []const u16) bool {
            if (at.* + s.len >= b.len) return false;
            @memcpy(b[at.* .. at.* + s.len], s);
            at.* += s.len;
            return true;
        }
    }.f;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    if (install_dir.len == 0) return null;
    if (!put(buf, &i, L("\""))) return null;
    if (!put(buf, &i, install_dir)) return null;
    const last = install_dir[install_dir.len - 1];
    if (last != '\\' and last != '/') {
        if (!put(buf, &i, L("\\"))) return null;
    }
    if (!put(buf, &i, L("ghoztty.exe\" --install-maintenance"))) return null;
    if (version.len > 0) {
        if (!put(buf, &i, L(" --installed-version="))) return null;
        if (!put(buf, &i, version)) return null;
    }
    if (i >= buf.len) return null;
    buf[i] = 0;
    return buf[0..i :0];
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;
const W16 = std.unicode.utf8ToUtf16LeStringLiteral;

test "status: only the exe's Cancel stops the installer, and quietly" {
    try testing.expectEqual(status_user_exit, status(1602));
    try testing.expectEqual(@as(u32, 1602), status_user_exit);
    try testing.expectEqual(status_proceed, status(0));
}

test "status: an exe that could not run or answered oddly proceeds with the repair" {
    try testing.expectEqual(status_proceed, status(null));
    try testing.expectEqual(status_proceed, status(1));
    try testing.expectEqual(status_proceed, status(1603));
    try testing.expectEqual(status_proceed, status(0xC0000005));
}

test "commandLine: the exact line the EXE action used to run" {
    var buf: [256]u16 = undefined;
    const got = commandLine(&buf, W16("C:\\Users\\A B\\AppData\\Local\\Programs\\Ghoztty\\"), W16("1.36.36")) orelse
        return error.NoLine;
    try testing.expectEqualSlices(u16, W16(
        "\"C:\\Users\\A B\\AppData\\Local\\Programs\\Ghoztty\\ghoztty.exe\" --install-maintenance --installed-version=1.36.36",
    ), got);
}

test "commandLine: adds the separator INSTALLDIR normally carries" {
    var buf: [256]u16 = undefined;
    const got = commandLine(&buf, W16("D:\\G"), W16("")) orelse return error.NoLine;
    try testing.expectEqualSlices(u16, W16("\"D:\\G\\ghoztty.exe\" --install-maintenance"), got);
}

test "commandLine: refuses rather than truncating or mis-quoting" {
    var small: [20]u16 = undefined;
    try testing.expect(commandLine(&small, W16("C:\\Programs\\Ghoztty\\"), W16("1.0.0")) == null);
    var buf: [256]u16 = undefined;
    try testing.expect(commandLine(&buf, W16(""), W16("1.0.0")) == null);
    try testing.expect(commandLine(&buf, W16("C:\\G\\"), W16("1.0 \"x")) == null);
}
