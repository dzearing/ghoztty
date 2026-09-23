//! Wiring for the `pdb-msf-fix` host tool (T919): every Windows test binary's
//! PDB is rewritten between the link and the test run, so that a panicking
//! test prints its frames instead of
//! `Unable to dump stack trace: InvalidBlockIndex`. The format detail and the
//! measured hit rate are in `pdb_msf_fix.zig`.
//!
//! One tool for the whole build, one run per test binary. A binary with no
//! PDB (a non-Windows target, or a stripped build) is left alone, so a call
//! site never has to ask which platform it is on.

const PdbMsfFix = @This();

const std = @import("std");

tool: *std.Build.Step.Compile,

pub fn create(b: *std.Build) *PdbMsfFix {
    const self = b.allocator.create(PdbMsfFix) catch @panic("OOM");
    self.* = .{
        .tool = b.addExecutable(.{
            .name = "pdb-msf-fix",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/build/pdb_msf_fix_main.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        }),
    };
    return self;
}

/// Make `run` (a run of `compile`) wait for `compile`'s PDB to be fixed.
pub fn attach(
    self: *PdbMsfFix,
    compile: *std.Build.Step.Compile,
    run: *std.Build.Step.Run,
) void {
    if (compile.rootModuleTarget().os.tag != .windows) return;
    if (compile.root_module.strip == true) return;
    const b = compile.step.owner;
    const fix = b.addRunArtifact(self.tool);
    fix.setName(b.fmt("pdb-msf-fix {s}", .{compile.name}));
    fix.addFileArg(compile.getEmittedPdb());
    // It edits its input in place and produces no output of its own, so the
    // build cache has nothing to key a skip on: run it every time. A clean
    // PDB is read and not written, which costs well under a second.
    fix.has_side_effects = true;
    run.step.dependOn(&fix.step);
}
