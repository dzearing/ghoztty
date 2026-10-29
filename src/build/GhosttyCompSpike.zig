//! The `ghoztty-comp-spike` executable (T2360 step 1): a standalone Windows
//! .exe that measures a sidebar-blade glide driven by today's hand-stepped
//! child HWNDs against the same glide declared to Windows.UI.Composition.
//! Built on demand with `zig build comp-spike`; not part of the install graph.
//!
//! Its root module (`src/comp_spike_main.zig`) reaches only `std`,
//! `apprt/win32/win32.zig` and `apprt/win32/winrt_comp.zig`, so it needs none
//! of the shared deps.

const CompSpike = @This();

const std = @import("std");
const Config = @import("Config.zig");

exe: *std.Build.Step.Compile,
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config) !CompSpike {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "ghoztty-comp-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/comp_spike_main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
        }),
        .use_llvm = true,
    });
    exe.subsystem = .Windows;
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
    return .{ .exe = exe, .install_step = b.addInstallArtifact(exe, .{}) };
}
