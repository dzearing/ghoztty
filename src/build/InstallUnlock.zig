//! Wiring for the `install-unlock` host tool (T192) — the guard that lets
//! `zig build` install over an artifact a RUNNING process is holding open.
//!
//! On Windows an executable's image file stays open for the life of the
//! process, and `ghoztty-agent.exe` outliving the app is deliberate (session
//! persistence). So a plain dev-loop `zig build` on a box where an earlier
//! test run left a repo-lineage agent alive failed with AccessDenied — after
//! `ghoztty.exe` had already installed, which is the part that misleads: exit
//! 1 over a binary that really did change.
//!
//! A tool run is inserted ahead of each install step it guards. It moves a
//! locked destination aside (`<name>.old-<n>`) so the install's atomic rename
//! lands on an empty path; see `install_unlock_main.zig` for why renaming
//! rather than killing. It never fails the build.
//!
//! T722: there is exactly ONE of these for the whole build (one tool, one
//! `enabled` answer), and every install
//! step that puts an executable or a loadable module into the install prefix
//! routes through it — the app, its `.com` twin and fallback GL, the agent and
//! its CA dll, the auxiliary harnesses built by name (`remote-test-client`,
//! `wp4-e2e`, `remote-backend-e2e`, `conpty-smoke`), the installed test exe,
//! the bench tools and the libghostty dll. T192 guarded some artifacts and not
//! others, which is the exact shape of the bug it was fixing, so the default
//! for anything added later is "guarded" rather than "remembered".
//!
//! Only a Windows HOST can hold an install destination open, so on any other
//! host every guard call is a no-op and the tool is never built.

const InstallUnlock = @This();

const std = @import("std");

/// The host tool, built once and run once per guarded destination.
tool: *std.Build.Step.Compile,

/// False on a non-Windows host, where no install destination can be held
/// open. Every `guard*` call then does nothing, so a call site never has to
/// ask which platform it is on — which is what lets the single instance be
/// threaded through build.zig unconditionally.
enabled: bool,

pub fn create(b: *std.Build) *InstallUnlock {
    const self = b.allocator.create(InstallUnlock) catch @panic("OOM");

    const tool = b.addExecutable(.{
        .name = "install-unlock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/install_unlock_main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    self.* = .{
        .tool = tool,
        .enabled = b.graph.host.result.os.tag == .windows,
    };
    return self;
}

/// Guard one destination path, and make `step` wait for the sweep.
///
/// Each guarded pair gets its OWN run of the tool, rather than all of them
/// sharing one. A shared run would take every guarded artifact's SOURCE as an
/// input, and a run's dependents wait for all of it — so wiring the on-demand
/// harnesses (`zig build wp4-e2e` and friends) into a single run made a plain
/// `zig build` compile every one of them, including the ones that do not
/// build for this target at all. The guard must never decide what gets built.
pub fn guardFile(
    self: *InstallUnlock,
    src: std.Build.LazyPath,
    dest: []const u8,
    step: *std.Build.Step,
) void {
    if (!self.enabled) return;

    const b = self.tool.step.owner;
    const run = b.addRunArtifact(self.tool);
    // Its entire job is a side effect on the install prefix, which is not an
    // input the run cache can see. Caching it would skip exactly the run that
    // matters — the second build against a still-running process.
    run.has_side_effects = true;
    run.addFileArg(src);
    run.addArg(dest);
    step.dependOn(&run.step);
}

/// Guard an install-artifact's main output (the exe or dll itself). The
/// side outputs (pdb, implib) are left alone: a running process holds its
/// image file open, not its debug info.
pub fn guardArtifact(
    self: *InstallUnlock,
    install: *std.Build.Step.InstallArtifact,
) void {
    const b = self.tool.step.owner;
    const dir = install.dest_dir orelse return;
    const bin = install.emitted_bin orelse return;
    self.guardFile(
        bin,
        b.getInstallPath(dir, install.dest_sub_path),
        &install.step,
    );
}

/// Guard a plain installed file (e.g. the `ghoztty.com` twin).
pub fn guardInstallFile(
    self: *InstallUnlock,
    install: *std.Build.Step.InstallFile,
) void {
    const b = self.tool.step.owner;
    self.guardFile(
        install.source,
        b.getInstallPath(install.dir, install.dest_rel_path),
        &install.step,
    );
}
