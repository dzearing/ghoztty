//! What `Ghoztty-Setup.exe` does with Windows Installer's answer (T2197).
//!
//! Pure: no OS imports, so every test lane runs it. The setup exe
//! (`setup_main.zig`) runs the embedded package through `MsiInstallProductW`
//! and hands the result code here; this file decides whether anything is said
//! and, when it is, says it.
//!
//! Why the front door exists at all (the T1247 design): a double-clicked MSI is
//! Windows Installer's own UI, and a collision with another installation
//! (Error 1500 / exit 1618) is refused at transaction START, before any custom
//! action of ours could run. On 2026-08-31 that looked like a window that said
//! "configuring" and vanished. Only something that runs before msiexec can
//! speak, so the setup exe does - in the same dark Ghoztty dialog, and with the
//! same causes, the in-app updater already reports (`update_apply.zig`, T1206),
//! re-worded for someone who is installing rather than updating.

const std = @import("std");
const update_apply = @import("update_apply.zig");

/// The dialog title. A constant so the acceptance script asserts on the same
/// string the exe shows.
pub const failure_title = "Ghoztty could not be installed";

/// The Windows Installer error the external UI handler swallows: "Another
/// installation is in progress". It is the dialog the 2026-08-31 walk saw
/// flash past, and the one the setup exe words for itself instead.
pub const msi_error_install_in_progress: u32 = 1500;

pub const success_reboot_required: u32 = 3010; // ERROR_SUCCESS_REBOOT_REQUIRED
pub const success_reboot_initiated: u32 = 1641; // ERROR_SUCCESS_REBOOT_INITIATED

/// What the setup exe does once Windows Installer has answered.
pub const Outcome = enum {
    /// Installed. Nothing is said: the package's own LaunchApp action opens
    /// Ghoztty, which is the success message.
    installed,
    /// The person cancelled. They know; saying so again would be noise.
    cancelled,
    /// Anything else: say what happened, in our dialog, and keep it up.
    report,
};

pub fn outcomeFor(code: u32) Outcome {
    return switch (code) {
        0, success_reboot_required, success_reboot_initiated => .installed,
        update_apply.install_user_exit => .cancelled,
        else => .report,
    };
}

/// What went wrong, for someone installing. The collision is the case this
/// exists for; the rest name the cause the updater names, re-worded so nothing
/// says "update" to a person who has never had Ghoztty.
pub fn cause(code: u32) []const u8 {
    return switch (code) {
        update_apply.install_already_running =>
            "Another installation is already running on this PC, so Windows would " ++
            "not let Ghoztty's installer start.",
        update_apply.install_service_failure =>
            "The Windows Installer service could not be started.",
        update_apply.install_package_open_failed, update_apply.install_package_invalid =>
            "The installer package could not be opened - this download looks " ++
            "damaged or incomplete.",
        update_apply.install_package_rejected =>
            "Windows refused the installer package because of a policy on this PC.",
        update_apply.install_product_version =>
            "A different version of Ghoztty is already installed, and Windows would " ++
            "not install this one over it.",
        update_apply.install_failure =>
            "Windows Installer stopped with a fatal error part way through.",
        else =>
            "Windows Installer stopped without finishing.",
    };
}

/// What to do about it - always something the reader can act on now.
pub fn remedy(code: u32) []const u8 {
    return switch (code) {
        update_apply.install_already_running =>
            "Wait for the other installation to finish - look for a setup or " ++
            "Windows Installer window, or a Windows Update in progress - then run " ++
            "this installer again.",
        update_apply.install_service_failure =>
            "Restart Windows, then run this installer again.",
        update_apply.install_package_open_failed, update_apply.install_package_invalid =>
            "Download the installer again from the Ghoztty releases page, then run " ++
            "the new copy.",
        update_apply.install_package_rejected =>
            "Ask whoever manages this PC about its software installation policy.",
        update_apply.install_product_version =>
            "Uninstall Ghoztty from Windows Settings, then run this installer again.",
        else =>
            "Run this installer again. If it keeps failing, the log below says " ++
            "what Windows Installer was doing when it stopped.",
    };
}

/// The whole dialog body. The numeric code comes last: it is the part a bug
/// report is matched on and the part that means nothing to the reader.
pub fn describe(buf: []u8, code: u32, log_path: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "Ghoztty was not installed.\n\n{s}\n\n{s}\n\nDetails are in {s} " ++
            "(Windows Installer code {d}).",
        .{ cause(code), remedy(code), log_path, code },
    ) catch buf[0..0];
}

/// The setup exe's own failure before Windows Installer was ever asked: no
/// package inside it (a dev build made without `-Dsetup-msi`), or no place to
/// put it. `what` is one sentence naming which.
pub fn describeNotStarted(buf: []u8, what: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "Ghoztty was not installed.\n\n{s}\n\nDownload the installer again from " ++
            "the Ghoztty releases page, then run the new copy.",
        .{what},
    ) catch buf[0..0];
}

/// Should the external UI handler swallow this INSTALLMESSAGE_ERROR record?
/// Only the collision: every other error box Windows Installer raises during a
/// running install (files in use, retry/cancel) is a question the person has to
/// answer, and answering it on their behalf would change what the install does.
pub fn swallowError(msi_error: u32) bool {
    return msi_error == msi_error_install_in_progress;
}

const testing = std.testing;

test "outcomeFor: success and its reboot variants are quiet installs" {
    try testing.expectEqual(Outcome.installed, outcomeFor(0));
    try testing.expectEqual(Outcome.installed, outcomeFor(3010));
    try testing.expectEqual(Outcome.installed, outcomeFor(1641));
}

test "outcomeFor: a cancel says nothing, everything else is reported" {
    try testing.expectEqual(Outcome.cancelled, outcomeFor(1602));
    try testing.expectEqual(Outcome.report, outcomeFor(1618));
    try testing.expectEqual(Outcome.report, outcomeFor(1603));
    try testing.expectEqual(Outcome.report, outcomeFor(1620));
    try testing.expectEqual(Outcome.report, outcomeFor(12345));
}

test "describe: the collision names the other installation, the wait, and the code" {
    var buf: [update_apply.max_failure_message]u8 = undefined;
    const text = describe(&buf, 1618, "C:\\t\\install.log");
    try testing.expect(std.mem.startsWith(u8, text, "Ghoztty was not installed."));
    try testing.expect(std.mem.indexOf(u8, text, "Another installation is already running") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Wait for the other installation to finish") != null);
    try testing.expect(std.mem.indexOf(u8, text, "C:\\t\\install.log") != null);
    try testing.expect(std.mem.indexOf(u8, text, "code 1618") != null);
}

test "describe: nothing a first-time installer reads talks about updating" {
    var buf: [update_apply.max_failure_message]u8 = undefined;
    for ([_]u32{ 1601, 1603, 1618, 1619, 1620, 1625, 1638, 9999 }) |code| {
        const text = describe(&buf, code, "C:\\l.log");
        try testing.expect(text.len > 0);
        // "Windows Update" may be named (it holds the installer too); the
        // updater's own wording may not.
        try testing.expect(std.ascii.indexOfIgnoreCase(text, "updating") == null);
        try testing.expect(std.ascii.indexOfIgnoreCase(text, "check for updates") == null);
        try testing.expect(std.ascii.indexOfIgnoreCase(text, "Ghoztty's update") == null);
        try testing.expect(std.ascii.indexOfIgnoreCase(text, "menu") == null);
    }
}

test "describe: a damaged download is told to download again, not to retry the same file" {
    var buf: [update_apply.max_failure_message]u8 = undefined;
    const text = describe(&buf, 1620, "C:\\l.log");
    try testing.expect(std.mem.indexOf(u8, text, "damaged") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Download the installer again") != null);
}

test "describe: the longest body fits the dialog's message buffer" {
    var buf: [update_apply.max_failure_message]u8 = undefined;
    const long_log = "C:\\Users\\someone-with-a-long-name\\AppData\\Local\\Temp\\ghoztty-setup-4294967295\\install.log";
    for ([_]u32{ 1601, 1603, 1618, 1620, 1625, 1638, 1 }) |code| {
        try testing.expect(describe(&buf, code, long_log).len > 0);
    }
}

test "describeNotStarted: names what is missing and where to get a good copy" {
    var buf: [update_apply.max_failure_message]u8 = undefined;
    const text = describeNotStarted(&buf, "This installer does not carry a Ghoztty package.");
    try testing.expect(std.mem.indexOf(u8, text, "does not carry") != null);
    try testing.expect(std.mem.indexOf(u8, text, "releases page") != null);
}

test "swallowError: only the collision is answered on the person's behalf" {
    try testing.expect(swallowError(1500));
    try testing.expect(!swallowError(1306)); // file in use: their question to answer
    try testing.expect(!swallowError(1603));
    try testing.expect(!swallowError(0));
}
