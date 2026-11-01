//! Where an agent integration installs, and how its runtimes are detected:
//! `GHOZTTY_AGENT_HOME` (the sandbox override for tests), else the user's
//! profile. Split out of `AgentIntegration.zig` (T2605) so the
//! `+agent-setup` CLI verb resolves the SAME home and probe as the Agent
//! Integrations dialog and the first-run offer — a sandboxed harness then
//! governs every entry point, and the two can never disagree about where a
//! skill went.
//!
//! Plain `std.process` + `std.fs`, no OS imports, so it compiles in every
//! lane.
const std = @import("std");
const RuntimeIntegration = @import("RuntimeIntegration.zig");

const log = std.log.scoped(.agent_home);

pub const RuntimeProbe = RuntimeIntegration.RuntimeProbe;

pub const override_env = "GHOZTTY_AGENT_HOME";

/// `path` is arena-owned; the caller closes `dir`.
pub const AgentHome = struct {
    dir: std.fs.Dir,
    path: []const u8,
};

fn overridePath(arena: std.mem.Allocator) ?[]const u8 {
    const value = std.process.getEnvVarOwned(arena, override_env) catch return null;
    return if (value.len > 0) value else null;
}

pub fn homePath(arena: std.mem.Allocator) ?[]const u8 {
    if (overridePath(arena)) |path| return path;
    return std.process.getEnvVarOwned(arena, "USERPROFILE") catch null;
}

pub fn open(arena: std.mem.Allocator) ?AgentHome {
    const path = homePath(arena) orelse return null;
    const dir = std.fs.cwd().openDir(path, .{}) catch |err| {
        log.warn("agent setup: home open failed ({s}): {}", .{ path, err });
        return null;
    };
    return .{ .dir = dir, .path = path };
}

/// The runtime probe: the process environment normally; ONLY the sandbox
/// home when `GHOZTTY_AGENT_HOME` is set, so a test's detection cannot be
/// polluted by whatever the box really has installed.
pub fn probe(arena: std.mem.Allocator) RuntimeProbe {
    if (overridePath(arena)) |path| return .{ .env = .{ .home = path } };
    return .binary;
}
