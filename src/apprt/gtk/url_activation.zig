//! The pure half of the GTK `ghoztty://` front door (T3343, Linux L14).
//!
//! The grammar, the one-verb threat model and the failure wording are shared
//! (`apprt/ipc/url_scheme.zig`); this file holds only the two decisions the
//! Linux half adds on top, kept free of GTK so the none lane tests them on
//! every seat:
//!
//! - **Which argument is the link** when the desktop launches the registered
//!   `Exec=ghoztty ... %u` line (`urlArg`). Same rule as win32's
//!   `url_scheme.urlArg`: the scan stops at `-e` and at a bare `--`, because
//!   everything after it is the child's argv - `ghoztty -e echo
//!   ghoztty://focus/x` prints a string, it does not focus a window.
//! - **What a `focus` reply means** for the dialog (`replyOutcome`): the
//!   in-app path (`GApplication::open`, a D-Bus `Open` from the desktop)
//!   holds the verb's JSON reply, and an ambiguous pane name gets its own
//!   sentence rather than "nothing has that name".
//!
//! Exit codes are win32's, so a script reads the same answer on both seats.
const std = @import("std");

const grammar = @import("../ipc/url_scheme.zig");

/// The activation process's exit codes (win32 `url_scheme.exit_*`).
pub const exit_focused: u8 = 0;
pub const exit_not_found: u8 = 1;
pub const exit_unsupported: u8 = 2;

/// A target longer than this is not a name anyone registered (win32's bound).
pub const max_target = 512;

/// The `ghoztty://` link on a command line, or null when there is none. Skips
/// `argv[0]`; stops at `-e` and `--` (see the module doc).
pub fn urlArg(args: []const []const u8) ?[]const u8 {
    if (args.len < 2) return null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--")) return null;
        if (grammar.handles(arg)) return arg;
    }
    return null;
}

pub const Outcome = enum { focused, not_found, ambiguous };

/// Read a `focus` verb reply (`{"success":true}` or
/// `{"success":false,"error":"..."}`). Anything unreadable is a miss: the
/// link did not focus anything, and saying so is the honest answer.
pub fn replyOutcome(reply: []const u8) Outcome {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const parsed = std.json.parseFromSliceLeaky(struct {
        success: bool = false,
        @"error": ?[]const u8 = null,
    }, fba.allocator(), reply, .{ .ignore_unknown_fields = true }) catch return .not_found;
    if (parsed.success) return .focused;
    const msg = parsed.@"error" orelse return .not_found;
    return if (std.mem.indexOf(u8, msg, "ambiguous") != null) .ambiguous else .not_found;
}

/// The failure to show for an outcome, or null when the link worked.
pub fn failureFor(outcome: Outcome, target: []const u8) ?grammar.Failure {
    return switch (outcome) {
        .focused => null,
        .not_found => .{ .target_not_found = target },
        .ambiguous => .{ .ambiguous_target = target },
    };
}

const testing = std.testing;

test "urlArg finds the link the desktop passes through %u" {
    try testing.expectEqualStrings(
        "ghoztty://focus/dev",
        urlArg(&.{ "ghoztty", "--gtk-single-instance=true", "ghoztty://focus/dev" }).?,
    );
    try testing.expectEqualStrings(
        "ghoztty-debug://focus/dev",
        urlArg(&.{ "ghoztty", "ghoztty-debug://focus/dev" }).?,
    );
    // Case-insensitive scheme, like the grammar.
    try testing.expect(urlArg(&.{ "ghoztty", "GHOZTTY://focus/x" }) != null);
}

test "urlArg never takes the child's argv after -e or --" {
    try testing.expect(urlArg(&.{ "ghoztty", "-e", "echo", "ghoztty://focus/x" }) == null);
    try testing.expect(urlArg(&.{ "ghoztty", "--", "ghoztty://focus/x" }) == null);
    try testing.expect(urlArg(&.{"ghoztty"}) == null);
    try testing.expect(urlArg(&.{}) == null);
    try testing.expect(urlArg(&.{ "ghoztty", "https://example.com", "--title=x" }) == null);
    // argv[0] itself is never the link.
    try testing.expect(urlArg(&.{"ghoztty://focus/x"}) == null);
}

test "replyOutcome reads the focus verb's replies" {
    try testing.expectEqual(Outcome.focused, replyOutcome("{\"success\":true}"));
    try testing.expectEqual(
        Outcome.not_found,
        replyOutcome("{\"success\":false,\"error\":\"target 'nope' not found in registry\"}"),
    );
    try testing.expectEqual(
        Outcome.ambiguous,
        replyOutcome("{\"success\":false,\"error\":\"'amb' is ambiguous\"}"),
    );
    try testing.expectEqual(Outcome.not_found, replyOutcome("not json"));
    try testing.expectEqual(Outcome.not_found, replyOutcome("{\"success\":false}"));
    try testing.expectEqual(Outcome.focused, replyOutcome("{\"success\":true,\"warning\":\"x\"}"));
}

test "failureFor maps an outcome onto the shared wording" {
    try testing.expect(failureFor(.focused, "x") == null);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "Can't focus \"dev\"",
        failureFor(.not_found, "dev").?.title(&buf),
    );
    try testing.expect(failureFor(.ambiguous, "dev").? == .ambiguous_target);
}
