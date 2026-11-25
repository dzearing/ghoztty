const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config.zig");

/// See build_config.ExeEntrypoint for why we do this.
const entrypoint = switch (build_config.exe_entrypoint) {
    .ghostty => @import("main_ghostty.zig"),
    .helpgen => @import("helpgen.zig"),
    .mdgen_ghostty_1 => @import("build/mdgen/main_ghostty_1.zig"),
    .mdgen_ghostty_5 => @import("build/mdgen/main_ghostty_5.zig"),
    .webgen_config => @import("build/webgen/main_config.zig"),
    .webgen_actions => @import("build/webgen/main_actions.zig"),
    .webgen_commands => @import("build/webgen/main_commands.zig"),
};

/// The main entrypoint for the program.
pub const main = entrypoint.main;

/// Standard options such as logger overrides.
pub const std_options: std.Options = if (@hasDecl(entrypoint, "std_options"))
    entrypoint.std_options
else
    .{};

/// The panic handler (T2244). On Windows a panic is raised as an exception
/// so the crash filter writes a report (`crash/windows.zig`); a shipping
/// build would otherwise `ExitProcess(3)` with nothing written. Elsewhere,
/// and for the build-time generator entrypoints, it is Zig's default.
pub const panic = if (builtin.os.tag == .windows and build_config.exe_entrypoint == .ghostty)
    std.debug.FullPanic(@import("crash/main.zig").windows.panic)
else
    std.debug.FullPanic(std.debug.defaultPanic);

test {
    _ = entrypoint;
}
