//! Build-time host tool: copy a PE executable, flipping the optional
//! header's Subsystem field. This is how `ghoztty.com` — the console-
//! subsystem twin of `ghoztty.exe` that makes PowerShell wait for (and wire
//! redirection to) CLI verbs — is produced without a second multi-minute
//! link of the whole app (T245; see `src/cli/com_shim.zig` for the design).
//!
//! Usage: patch-subsystem <input.exe> <console|gui> <output>
//!
//! The edit itself lives in `src/apprt/win32/console_twin.zig`, shared with
//! the installer's custom action that derives the twin at install time
//! (T2071). The optional-header CheckSum is left untouched: the loader only
//! verifies it for drivers and protected processes, never for ordinary
//! executables.

const std = @import("std");
// The same edit the installer makes on the user's box (T2071), so the build's
// ghoztty.com and an installed one can never disagree about what a twin is.
const twin = @import("console_twin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len != 4) {
        std.log.err("usage: patch-subsystem <input.exe> <console|gui> <output>", .{});
        return error.BadUsage;
    }
    const input = args[1];
    const console = std.mem.eql(u8, args[2], "console");
    if (!console and !std.mem.eql(u8, args[2], "gui")) {
        std.log.err("unknown subsystem '{s}' (want console|gui)", .{args[2]});
        return error.BadUsage;
    }
    const output = args[3];

    const bytes = try std.fs.cwd().readFileAlloc(alloc, input, 256 * 1024 * 1024);
    const len = if (console)
        try twin.makeConsoleTwin(bytes)
    else blk: {
        try twin.setSubsystem(bytes, twin.subsystem_gui);
        break :blk bytes.len;
    };

    try std.fs.cwd().writeFile(.{ .sub_path = output, .data = bytes[0..len] });
}
