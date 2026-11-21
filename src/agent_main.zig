//! Root source for the `ghoztty-agent` executable (WP2). It lives under `src/`
//! (not `src/remote/agent/`) so the agent module is rooted at `src/`, letting
//! `src/remote/agent/pty_child.zig` reach `src/pty.zig` and `src/CommandCore.zig`
//! via relative imports while the GUI-free `protocol` module stays a named import.
//! The actual entry point + transport live in `remote/agent/main.zig`.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("remote/agent/main.zig");
const agent_log = @import("remote/agent/agent_log.zig");

pub const main = agent.main;

/// T1721: the agent and its pty holders write `agent.log` in the agent's state
/// dir (the Mac LaunchAgent's file, translated) as well as stderr. The level is
/// `info` in every release mode, the app's floor: Zig's ReleaseFast default is
/// `err`, which compiled every durability WARNING out of the shipped agent -
/// on macOS too, whose launchd redirect had nothing to capture.
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = agent_log.logFn,
};

test {
    @import("std").testing.refAllDecls(agent);
    _ = agent_log;
}
