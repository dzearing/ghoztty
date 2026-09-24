//! Tell somebody who already has this exact build that they already have it,
//! instead of vanishing (T1291).
//!
//! ## The defect, in the user's words (2026-09-03)
//!
//! > "I also tried installing the msi with a version already installed and it
//! > just silently quit. […] there should be some message to ask what to do
//! > (reinstall, cancel) that's a standard dialog to let you know you're
//! > already good, not just silently fail."
//!
//! ## Why it vanished
//!
//! Running an MSI whose ProductCode is already installed puts Windows
//! Installer into MAINTENANCE mode. In maintenance mode the engine hands the
//! whole question — repair? change? remove? — to the package's authored UI,
//! and this package has no authored UI at all: no `<UI>`, no `Dialog` table,
//! no `InstallUISequence` dialogs. There is nothing to show, no feature state
//! changes, and msiexec exits 0 without a word. Every part of that is working
//! as designed, which is why nothing anywhere logged a problem.
//!
//! ## The shape of the fix
//!
//! Not an authored MSI wizard. This product has deliberately never had one —
//! a double-clicked install is a progress bar and then a terminal — and
//! bolting a WixUI dialog set on for the one maintenance case would introduce
//! a second, differently-styled installer UI for the rarest path. Instead the
//! package asks THE APP, through the type-51/type-50 custom-action pair it
//! already uses for `--install-prepare` and for launch-on-finish: msiexec runs
//! `[INSTALLDIR]ghoztty.exe --install-maintenance`, and the app puts up the
//! same dark `ConfirmDialog` every other Ghoztty prompt uses, relabelled
//! Repair / Cancel.
//!
//! The answer travels back as the process EXIT CODE:
//!
//! - **Repair** exits 0. The package has already pre-armed `REINSTALL=ALL`
//!   before `CostFinalize` (which is where feature states are decided, and
//!   therefore too early to have asked the question yet), so a success here
//!   simply lets the repair it already planned proceed.
//! - **Cancel** exits `user_exit_code` (1602, `ERROR_INSTALL_USEREXIT`).
//!
//! ## Why msiexec does not run this exe directly any more (T1730)
//!
//! T1291 ran this exe as an EXE custom action (type 50, `Return="check"`) on
//! the premise that 1602 is the one exit code Windows Installer reads as "the
//! user said no". It is not: for an EXE action EVERY non-zero exit is a
//! failure, so Cancel raised error 1722 ("A program run as part of the setup
//! did not finish as expected") and the install ended at 1603 - T1302's walk
//! against a real msiexec caught it. The user-exit mapping exists only for
//! actions whose RETURN VALUE is an action status. So the package now runs
//! `MaintenancePromptCA` in `ghoztty-msi-ca.dll` (`install_ca.zig`), which
//! starts this exe, waits, and returns `ERROR_INSTALL_USEREXIT` itself when the
//! exit code is 1602. This file's contract is unchanged; only its caller moved.
//!
//! ## Deliberately NOT here
//!
//! - **The silent path.** The package gates this pair on `UILevel > 3`, so the
//!   in-app updater's `/qb-!` install (UILevel 3) never runs it and never sees
//!   a dialog. A prompt that can appear during an unattended update is a hang.
//! - **Uninstall and upgrade.** `REMOVE`, `UPGRADINGPRODUCTCODE` and
//!   `OLDERVERSIONFOUND` all exclude this; the only case it covers is "the
//!   same package, already installed".
//! - **Any decision about WHAT to repair.** The repair is `REINSTALL=ALL` with
//!   the standard file-overwrite mode; this module's whole job is the question
//!   and the answer.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const build_config = @import("../../build_config.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");

const log = std.log.scoped(.win32_install_maintenance);

/// The argv flag that turns a `ghoztty.exe` start into the maintenance prompt.
///
/// An argument rather than an environment variable, and spelled like plumbing
/// rather than as a `+verb`, for exactly the reasons `install_prepare.flag`
/// gives next door: the caller is msiexec, which controls its child's command
/// line and not its environment, and the `+action` enum is the cross-platform
/// CLI surface that must not grow a Windows-installer-only member.
pub const flag = "--install-maintenance";

/// Optional `--installed-version=<text>`: what to call the installed build in
/// the message. The package passes `[ARPDISPLAYVERSION]`, so the number in the
/// dialog is the one Apps & Features shows (T1205) rather than the internal
/// `yy.m.dNN` the installer sequences on. Absent — a hand-run invocation — the
/// running exe's own version string is used, which for the installed exe is
/// the same build.
pub const version_flag = "--installed-version=";

/// Optional `--answer=repair|cancel`: skip the dialog and answer as if the
/// button had been pressed.
///
/// This is the acceptance seam, and it is here for the same reason
/// `install_prepare.dir_flag` is: the behaviour worth measuring is the CONTRACT
/// WITH THE PACKAGE — that Repair exits 0 and Cancel exits 1602 — and that
/// contract cannot be measured by a script that has to click a button on a
/// background desktop where synthetic input does not reach. The dialog itself
/// is the part a human sees; the exit codes are what the package's custom
/// action (`install_ca.zig`) turns into "repair" or a quiet user exit.
pub const answer_flag = "--answer=";

/// What the person chose.
pub const Answer = enum {
    repair,
    cancel,

    pub fn parse(text: []const u8) ?Answer {
        if (std.mem.eql(u8, text, "repair")) return .repair;
        if (std.mem.eql(u8, text, "cancel")) return .cancel;
        return null;
    }
};

/// `ERROR_INSTALL_USEREXIT`: what Cancel exits with. The package's DLL action
/// (`install_ca.zig`) reads it and ends the install as a quiet user exit; the
/// number itself means nothing to msiexec as an exit code (see the header).
pub const user_exit_code: u32 = 1602;

/// The exit code msiexec must see for a given answer.
pub fn exitCode(answer: Answer) u32 {
    return switch (answer) {
        .repair => 0,
        .cancel => user_exit_code,
    };
}

/// What a command line asked for, or null when it did not ask for this at all.
pub const Request = struct {
    /// How to name the installed build in the message, or null for "ask the
    /// running exe".
    version: ?[]const u8 = null,
    /// A pre-supplied answer (the acceptance seam), or null to ask.
    answer: ?Answer = null,
};

/// Parse a command line. Pure, so the lane checks it: like its neighbour in
/// `install_prepare.zig`, this function decides whether an ordinary
/// `ghoztty.exe` start is quietly turned into something that is not a terminal,
/// and being wrong in either direction is a bad day — a missed flag leaves the
/// installer silent again, and a false positive means a double-clicked Ghoztty
/// opens a dialog about repairing itself.
///
/// `args` is the FULL argv including argv[0], the way the process sees it.
pub fn parse(args: []const []const u8) ?Request {
    var found = false;
    var req: Request = .{};
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, flag)) {
            found = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, version_flag)) {
            const value = arg[version_flag.len..];
            if (value.len > 0) req.version = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, answer_flag)) {
            req.answer = Answer.parse(arg[answer_flag.len..]);
            continue;
        }
    }
    if (!found) return null;
    return req;
}

/// The longest message this builds, so the caller's buffers are sized from one
/// number rather than from four guesses.
pub const max_message = 512;

/// The dialog's title.
pub const title = "Ghoztty is already installed";

/// The body text. Says the reassuring thing FIRST — the user's own words for
/// what they wanted were "let you know you're already good" — and only then
/// offers the repair, because for almost everyone who lands here the correct
/// action is to close the installer and carry on.
pub fn message(buf: []u8, version: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "Ghoztty {s} is already installed, so there is nothing to update.\n\n" ++
            "Choose Repair to reinstall this version's files if something is " ++
            "not working, or Cancel to leave the installation as it is.",
        .{version},
    ) catch "Ghoztty is already installed, so there is nothing to update.";
}

/// Was this process started as an installer maintenance prompt? If so, ask and
/// hand `main` an exit code — a prompt never becomes a terminal.
///
/// Returns null when this is an ordinary start, and 0 for Repair. The CANCEL
/// path does not return at all: 1602 does not fit the `u8` `main` exits with,
/// and the whole point of the number is that msiexec sees it, so this leaves
/// the process itself. See `user_exit_code`.
pub fn runFromArgs(alloc: Allocator) ?u8 {
    if (comptime builtin.os.tag != .windows) return null;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = std.process.argsAlloc(arena) catch return null;
    const req = parse(args) orelse return null;

    const answer = req.answer orelse ask(req.version orelse build_config.version_string);
    log.warn("install maintenance: answer={s}", .{@tagName(answer)});

    const code = exitCode(answer);
    if (code == 0) return 0;
    exitProcess(code);
}

/// Put the question on screen and wait for it.
///
/// `showStandalone` rather than `show`: this process has no `App`, no window
/// and no message loop — it is the installed exe run by msiexec — which is the
/// state that entry point exists for (`update_install.zig` and
/// `startup_error.zig` are both in the same position). The relabelled OK/Cancel
/// pair is the established way to change what the buttons SAY without changing
/// what they MEAN; the T69 config-errors dialog does the same thing.
fn ask(version: []const u8) Answer {
    if (comptime builtin.os.tag != .windows) return .cancel;

    var text_buf: [max_message]u8 = undefined;
    const text = message(&text_buf, version);

    var wbuf: [max_message * 2]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], text) catch {
        // A message that cannot be encoded is not a reason to fall back to the
        // silence this module exists to remove, but it is a reason not to
        // repair something nobody asked about.
        log.err("install maintenance: message could not be encoded; cancelling", .{});
        return .cancel;
    };
    wbuf[n] = 0;

    const result = ConfirmDialog.showStandalone(null, 1.0, .{
        .title = std.unicode.utf8ToUtf16LeStringLiteral(title),
        .text = wbuf[0..n :0],
        .style = .ok_cancel,
        .icon = .info,
        // Enter lands on Cancel. Repair is harmless, but "you are already good"
        // is the answer nearly everyone who reaches this dialog wants, and a
        // reflexive Enter should not start rewriting files.
        .default_cancel = true,
        .ok_label = std.unicode.utf8ToUtf16LeStringLiteral("Repair"),
        .cancel_label = std.unicode.utf8ToUtf16LeStringLiteral("Cancel"),
    });

    return switch (result) {
        .ok => .repair,
        // `.alt` is the optional third button (T1390), which this dialog does
        // not offer - so it cannot arrive, and if it ever did, the dismissive
        // answer is the safe reading of an answer we did not ask for.
        .cancel, .alt => .cancel,
    };
}

/// Leave the process with a code wider than `main`'s `u8`. Never returns.
fn exitProcess(code: u32) noreturn {
    if (comptime builtin.os.tag == .windows) {
        std.os.windows.kernel32.ExitProcess(code);
    }
    std.process.exit(1);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test {
    _ = @import("maintenance_ca.zig");
}

test "the DLL action reads the exit code this file writes" {
    const ca = @import("maintenance_ca.zig");
    try testing.expectEqual(ca.exe_cancel_code, exitCode(.cancel));
    try testing.expectEqual(ca.status_user_exit, ca.status(exitCode(.cancel)));
    try testing.expectEqual(ca.status_proceed, ca.status(exitCode(.repair)));
}

test "parse: recognises the flag anywhere in argv" {
    const req = parse(&.{ "ghoztty.exe", flag }) orelse return error.NotParsed;
    try testing.expect(req.version == null);
    try testing.expect(req.answer == null);
}

test "parse: an ordinary start is never a maintenance prompt" {
    try testing.expect(parse(&.{"ghoztty.exe"}) == null);
    try testing.expect(parse(&.{ "ghoztty.exe", "+list" }) == null);
    // argv[0] is skipped: an exe that happens to be NAMED like the flag must
    // not turn every launch into a dialog.
    try testing.expect(parse(&.{flag}) == null);
    // A near miss is a miss.
    try testing.expect(parse(&.{ "ghoztty.exe", "--install-maintenance-x" }) == null);
    try testing.expect(parse(&.{ "ghoztty.exe", "--install-prepare" }) == null);
}

test "parse: reads the version to display" {
    const req = parse(&.{ "ghoztty.exe", flag, version_flag ++ "1.36.0" }) orelse
        return error.NotParsed;
    try testing.expectEqualStrings("1.36.0", req.version.?);
    // An empty value (an MSI property that resolved to nothing) falls back
    // rather than printing "Ghoztty  is already installed".
    const empty = parse(&.{ "ghoztty.exe", flag, version_flag }) orelse
        return error.NotParsed;
    try testing.expect(empty.version == null);
}

test "parse: reads the acceptance answer" {
    const repair = parse(&.{ "ghoztty.exe", flag, answer_flag ++ "repair" }) orelse
        return error.NotParsed;
    try testing.expectEqual(Answer.repair, repair.answer.?);
    const cancel = parse(&.{ "ghoztty.exe", flag, answer_flag ++ "cancel" }) orelse
        return error.NotParsed;
    try testing.expectEqual(Answer.cancel, cancel.answer.?);
    // An unrecognised answer asks rather than guessing.
    const bogus = parse(&.{ "ghoztty.exe", flag, answer_flag ++ "yes" }) orelse
        return error.NotParsed;
    try testing.expect(bogus.answer == null);
}

test "exitCode: the contract with msiexec" {
    // These two numbers ARE the feature. `install_ca.zig` proceeds with the
    // repair on anything but 1602 and ends the install as a quiet user exit on
    // 1602, so a Cancel that exited anything else would repair instead.
    try testing.expectEqual(@as(u32, 0), exitCode(.repair));
    try testing.expectEqual(@as(u32, 1602), exitCode(.cancel));
    try testing.expectEqual(@as(u32, 1602), user_exit_code);
}

test "message: names the version and both choices" {
    var buf: [max_message]u8 = undefined;
    const text = message(&buf, "1.36.0");
    try testing.expect(std.mem.indexOf(u8, text, "1.36.0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "already installed") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Repair") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Cancel") != null);
    // The buffer is sized from `max_message`, so the longest plausible version
    // string must still fit rather than silently falling back.
    const long = message(&buf, "26.9.301+0123456789abcdef");
    try testing.expect(std.mem.indexOf(u8, long, "26.9.301+0123456789abcdef") != null);
}
