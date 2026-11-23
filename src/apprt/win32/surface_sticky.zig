//! Per-pane config values a pane was OPENED with, which no app-wide config
//! push may take away (T1957).
//!
//! An app-wide push (`core.App.updateConfig`: a low-power switch, a hard or
//! soft reload) re-derives every pane from the APP config. A value that only
//! one pane carries - today `wait-after-command`, which `+new-remote-window
//! --command` sets on its own pane - is not in the app config, so the push
//! cleared it, and the window then closed under the user the moment its
//! command ended. The pane records what it was opened with here, and the push
//! lays it back on top of the app config for that pane.
//!
//! Spawn-time overrides (command, working directory, env) are NOT here: they
//! are read once, when the child starts, so a later re-derive cannot change
//! anything they did.

const Config = @import("../../config.zig").Config;

pub const Sticky = struct {
    /// The pane holds its window open when its command ends.
    wait_after_command: bool = false,

    /// Does this pane carry anything an app-wide push would take away?
    pub fn any(self: Sticky) bool {
        return self.wait_after_command;
    }

    /// Lay the pane's own values over a config derived from the app's.
    pub fn apply(self: Sticky, config: *Config) void {
        if (self.wait_after_command) config.@"wait-after-command" = true;
    }
};

const std = @import("std");
const testing = std.testing;

test "an empty sticky set carries nothing and changes nothing" {
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    const s: Sticky = .{};
    try testing.expect(!s.any());
    const before = cfg.@"wait-after-command";
    s.apply(&cfg);
    try testing.expectEqual(before, cfg.@"wait-after-command");
}

test "wait-after-command survives a push of a config that does not set it" {
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    try testing.expect(!cfg.@"wait-after-command");
    const s: Sticky = .{ .wait_after_command = true };
    try testing.expect(s.any());
    s.apply(&cfg);
    try testing.expect(cfg.@"wait-after-command");
}

test "a config that already sets wait-after-command is left as it is" {
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    cfg.@"wait-after-command" = true;
    const s: Sticky = .{};
    s.apply(&cfg);
    try testing.expect(cfg.@"wait-after-command");
}
