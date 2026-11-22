//! Where the POSIX local `ghoztty-agent` keeps its state, spelled ONCE for
//! every reader on macOS and Linux (T3337).
//!
//! The directory is `<config>/ghoztty/local-agent[-debug][-<instance>]/`, and
//! everything in it is named the way the Mac's `LocalAgentManager.Paths` names
//! it: `agent.sock` (the 0600 AF_UNIX socket), `port.json` (the info file the
//! agent writes after it binds), `sessions.json` (the reboot-floor roster),
//! `agent.lock`, `agent.heartbeat` and `agent.log`.
//!
//! `<config>` is `~/.config` on macOS, byte for byte what the Swift side
//! derives. On Linux it is `$XDG_CONFIG_HOME` when that is set to an absolute
//! path, else `~/.config` - the XDG rule every other Linux program follows, and
//! the knob that lets a test harness give an app (and the agent it spawns) a
//! private state dir without touching the user's home.
//!
//! Readers: the GTK app's `LocalAgent` (find-or-spawn) and `+sessions` (which
//! reads the info file with the app closed). Windows keeps its own derivation
//! (`%LOCALAPPDATA%\ghoztty\...`, T89a decision 2) and never calls this.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const agent_lineage = @import("agent_lineage.zig");

/// The lineage directory name: `local-agent[-debug][-<instance>]`.
pub fn dirName(buf: []u8, is_debug: bool, instance: ?[]const u8) error{NameTooLong}![]const u8 {
    const base = if (is_debug) "local-agent-debug" else "local-agent";
    return agent_lineage.appendSuffix(buf, base, instance);
}

/// The config root the state dir hangs off. Pure: the caller supplies the
/// environment, so both platforms' rules are testable anywhere.
///
/// Linux honors an ABSOLUTE `$XDG_CONFIG_HOME` (the XDG spec says a relative
/// one is invalid and must be ignored); macOS never consults it, because the
/// Swift side does not.
pub fn configRoot(
    alloc: Allocator,
    is_linux: bool,
    xdg_config_home: ?[]const u8,
    home: []const u8,
) Allocator.Error![]u8 {
    if (is_linux) {
        if (xdg_config_home) |x| {
            if (x.len > 0 and x[0] == '/') return alloc.dupe(u8, x);
        }
    }
    return std.fmt.allocPrint(alloc, "{s}/.config", .{home});
}

/// `<config root>/ghoztty/<dirName>`.
pub fn stateDirFrom(
    alloc: Allocator,
    is_linux: bool,
    is_debug: bool,
    instance: ?[]const u8,
    xdg_config_home: ?[]const u8,
    home: []const u8,
) (Allocator.Error || error{NameTooLong})![]u8 {
    const root = try configRoot(alloc, is_linux, xdg_config_home, home);
    defer alloc.free(root);
    var name_buf: [64]u8 = undefined;
    const name = try dirName(&name_buf, is_debug, instance);
    return std.fmt.allocPrint(alloc, "{s}/ghoztty/{s}", .{ root, name });
}

/// The state dir for THIS process: this build's lineage, the
/// `GHOZTTY_AGENT_INSTANCE` suffix, `$XDG_CONFIG_HOME` (Linux) and `$HOME`.
/// POSIX only.
pub fn stateDir(alloc: Allocator, is_debug: bool) ![]u8 {
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (try @import("../os/homedir.zig").home(&home_buf)) orelse return error.NoHome;
    var sfx_buf: [agent_lineage.max_len]u8 = undefined;
    const instance = agent_lineage.fromEnv(&sfx_buf);
    const xdg = std.posix.getenv("XDG_CONFIG_HOME");
    return stateDirFrom(alloc, builtin.os.tag == .linux, is_debug, instance, xdg, home);
}

/// A file inside the state dir. Caller owns the result.
pub fn join(alloc: Allocator, dir: []const u8, comptime file: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/" ++ file, .{dir});
}

pub const socket_file = "agent.sock";
pub const port_file = "port.json";
pub const sessions_file = "sessions.json";
pub const lock_file = "agent.lock";
pub const heartbeat_file = "agent.heartbeat";
pub const log_file = "agent.log";

const testing = std.testing;

test "stateDirFrom: macOS is ~/.config and ignores XDG_CONFIG_HOME (the Swift derivation)" {
    const alloc = testing.allocator;
    const d = try stateDirFrom(alloc, false, true, null, "/x/cfg", "/Users/u");
    defer alloc.free(d);
    try testing.expectEqualStrings("/Users/u/.config/ghoztty/local-agent-debug", d);
}

test "stateDirFrom: Linux honors an absolute XDG_CONFIG_HOME" {
    const alloc = testing.allocator;
    const d = try stateDirFrom(alloc, true, true, null, "/tmp/hl/config", "/root");
    defer alloc.free(d);
    try testing.expectEqualStrings("/tmp/hl/config/ghoztty/local-agent-debug", d);
}

test "stateDirFrom: Linux ignores an empty or relative XDG_CONFIG_HOME" {
    const alloc = testing.allocator;
    const a = try stateDirFrom(alloc, true, false, null, "", "/home/u");
    defer alloc.free(a);
    try testing.expectEqualStrings("/home/u/.config/ghoztty/local-agent", a);
    const b = try stateDirFrom(alloc, true, false, null, "rel/cfg", "/home/u");
    defer alloc.free(b);
    try testing.expectEqualStrings("/home/u/.config/ghoztty/local-agent", b);
}

test "stateDirFrom: the instance suffix names its own lineage" {
    const alloc = testing.allocator;
    const d = try stateDirFrom(alloc, true, true, "hl42", null, "/root");
    defer alloc.free(d);
    try testing.expectEqualStrings("/root/.config/ghoztty/local-agent-debug-hl42", d);
}
