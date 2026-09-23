//! Build-time host tool: rewrite a test binary's PDB in place so a panic in
//! it prints a stack trace (T919; the why is in `pdb_msf_fix.zig`).
//!
//! Usage: pdb-msf-fix <file.pdb>
//!
//! Runs between the link and the test run. A clean PDB is not written at
//! all; a missing one (a stripped build) is not an error.

const std = @import("std");
const pdb_msf_fix = @import("pdb_msf_fix.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len != 2) {
        std.log.err("usage: pdb-msf-fix <file.pdb>", .{});
        return error.BadUsage;
    }
    const path = args[1];

    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 2 * 1024 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    var pdb: std.ArrayList(u8) = .fromOwnedSlice(bytes);
    const moved = try pdb_msf_fix.fix(alloc, &pdb);
    if (moved == 0) return;

    // Silent on success: a Run step's stderr is echoed into every lane log.
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = pdb.items });
}
