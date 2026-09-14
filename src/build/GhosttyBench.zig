//! GhosttyBench generates all the Ghostty benchmark helper binaries.
const GhosttyBench = @This();

const std = @import("std");
const InstallUnlock = @import("InstallUnlock.zig");
const SharedDeps = @import("SharedDeps.zig");

steps: []*std.Build.Step.Compile,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyBench {
    var steps: std.ArrayList(*std.Build.Step.Compile) = .empty;
    errdefer steps.deinit(b.allocator);

    // Our synthetic data generator
    {
        const exe = b.addExecutable(.{
            .name = "ghostty-gen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_gen.zig"),
                .target = deps.config.target,
                // We always want our datagen to be fast because it
                // takes awhile to run.
                .optimize = .ReleaseFast,
            }),
        });
        exe.linkLibC();
        _ = try deps.add(exe);
        try steps.append(b.allocator, exe);
    }

    // Our benchmarking application.
    {
        const exe = b.addExecutable(.{
            .name = "ghostty-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_bench.zig"),
                .target = deps.config.target,
                // We always want our benchmarks to be in release mode.
                .optimize = .ReleaseFast,
            }),
        });
        exe.linkLibC();
        _ = try deps.add(exe);
        try steps.append(b.allocator, exe);
    }

    return .{ .steps = steps.items };
}

pub fn install(self: *const GhosttyBench, unlock: *InstallUnlock) void {
    const b = self.steps[0].step.owner;
    for (self.steps) |step| {
        // T722: guarded like every other installed exe — a bench run left
        // holding its own image must not fail the next `zig build`.
        const install_step = b.addInstallArtifact(step, .{});
        b.getInstallStep().dependOn(&install_step.step);
        unlock.guardArtifact(install_step);
    }
}
