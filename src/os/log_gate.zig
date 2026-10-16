//! Which lines a process writes into the shared Windows log sink
//! (`%LOCALAPPDATA%\ghoztty\ghoztty.log`).
//!
//! The sink is shared by the GUI app, the agent and every one-shot
//! `ghoztty +…` CLI invocation, and the CLI is called constantly: agents read
//! panes, the banner hook posts status, scripts list windows. Until T1998 every
//! one of those calls wrote the GUI's whole startup banner (version, build
//! mode, runtime, font backend, harfbuzz, renderer, libxev backend, locale)
//! plus an `executing CLI action=` line - nine info lines per call, which on
//! this box was ~75% of the file (3363 CLI runs in a day, ~30k lines). Under
//! the 4 MiB bound of T410 that is what pushed the lines a crash investigation
//! needs out of both generations within hours.
//!
//! So a CLI process writes only what is worth reading afterwards: warnings and
//! errors. Nothing a CLI call did is lost by this - the app it talks to logs
//! `IPC: received action '<verb>'` on its side, and that is the line that
//! places a call in the app's own timeline. A CLI call that becomes the master
//! process (no instance running) is the GUI app from then on, and logs like
//! one; see `main_ghostty.zig`.
//!
//! `GHOZTTY_CLI_LOG=info` puts a CLI process's info lines back, for diagnosing
//! the CLI itself.

const std = @import("std");

/// Whether a line at `level` goes into the shared file sink.
///
/// `cli_action` is true while the process is executing a `+verb`;
/// `cli_info_opt_in` is `GHOZTTY_CLI_LOG=info`. Debug lines never reach the
/// file: they are compiled out of release builds anyway, and the sink itself
/// exists only in release builds.
pub fn fileSinkAccepts(
    level: std.log.Level,
    cli_action: bool,
    cli_info_opt_in: bool,
) bool {
    return switch (level) {
        .debug => false,
        .info => !cli_action or cli_info_opt_in,
        .warn, .err => true,
    };
}

/// Parse the `GHOZTTY_CLI_LOG` value. Only `info` (any case) opts in; anything
/// else, including an empty value, leaves the CLI at warnings and errors.
pub fn cliInfoOptIn(value: ?[]const u8) bool {
    const v = value orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), "info");
}

test "fileSinkAccepts: the GUI app keeps its info lines" {
    try std.testing.expect(fileSinkAccepts(.info, false, false));
    try std.testing.expect(fileSinkAccepts(.warn, false, false));
    try std.testing.expect(fileSinkAccepts(.err, false, false));
}

test "fileSinkAccepts: a CLI action drops info but keeps warnings and errors" {
    try std.testing.expect(!fileSinkAccepts(.info, true, false));
    try std.testing.expect(fileSinkAccepts(.warn, true, false));
    try std.testing.expect(fileSinkAccepts(.err, true, false));
}

test "fileSinkAccepts: GHOZTTY_CLI_LOG=info puts a CLI's info lines back" {
    try std.testing.expect(fileSinkAccepts(.info, true, true));
}

test "fileSinkAccepts: debug never reaches the file" {
    try std.testing.expect(!fileSinkAccepts(.debug, false, false));
    try std.testing.expect(!fileSinkAccepts(.debug, true, true));
}

test "cliInfoOptIn: only info opts in" {
    try std.testing.expect(cliInfoOptIn("info"));
    try std.testing.expect(cliInfoOptIn("INFO"));
    try std.testing.expect(cliInfoOptIn(" info "));
    try std.testing.expect(!cliInfoOptIn(null));
    try std.testing.expect(!cliInfoOptIn(""));
    try std.testing.expect(!cliInfoOptIn("1"));
    try std.testing.expect(!cliInfoOptIn("debug"));
}
