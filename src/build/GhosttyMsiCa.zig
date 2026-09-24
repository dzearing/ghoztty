//! `ghoztty-msi-ca.dll` - the Ghoztty installer's in-process custom actions
//! (T1730; `src/apprt/win32/install_ca.zig`). Windows targets only.
//!
//! It is installed into `zig-out/bin` beside the exe so `build-msi.sh` finds it
//! where it finds everything else, but it is NOT part of the installed product:
//! the package carries it in its Binary table, and no delivery manifest lists
//! it. Pure Win32 with no shared deps, like the agent's custom-action DLL, so
//! msiexec loads it instantly.

const MsiCa = @This();

const std = @import("std");
const Config = @import("Config.zig");

install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config) MsiCa {
    const dll = b.addLibrary(.{
        .name = "ghoztty-msi-ca",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apprt/win32/install_ca.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
        }),
        .use_llvm = true,
    });
    return .{ .install_step = b.addInstallArtifact(dll, .{}) };
}

pub fn install(self: *const MsiCa) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
