//! The live sections of the Settings window (T2680): what Sessions & Agent
//! says about the session agent, and what Updates says about this build.
//!
//! Pure, so the wording is tested in the `none` lane. `SettingsWindow` takes
//! the snapshot (`Agent`) and paints the lines this module writes.
//!
//! The agent is read WITHOUT spawning it (Mac `AgentStatusModel.refresh`):
//! the info file's pid and a liveness check, then the build the SHARED
//! connection already shook hands with. Opening the page never dials, never
//! starts an agent, and never runs `ghoztty-agent --version` - the bundled
//! build is shown only once something else has already probed it.
const std = @import("std");
const agent_upgrade = @import("agent_upgrade.zig");

/// The agent as the Sessions & Agent page sees it.
pub const Agent = struct {
    /// A live process holds the agent's info file.
    running: bool = false,
    pid: i64 = 0,
    /// The build the connected agent advertised (null with no connection).
    running_build: ?[]const u8 = null,
    /// The build this app ships (null until something probed it).
    bundled_build: ?[]const u8 = null,
    /// The agent's pipe, from its info file (empty when unknown).
    pipe: []const u8 = "",

    pub fn isStale(self: Agent) bool {
        const r = self.running_build orelse return false;
        const b = self.bundled_build orelse return false;
        return agent_upgrade.isStale(r, b);
    }
};

/// The Status line (Mac: "Running" / "Not running - it starts with the
/// first terminal"). Windows names the pid where Mac names a session count;
/// the count needs a request to the agent the page does not make.
pub fn statusLine(buf: []u8, a: Agent) []const u8 {
    if (!a.running) return "Not running \u{2014} it starts with the first terminal";
    if (a.pid > 0) return std.fmt.bufPrint(buf, "Running \u{00B7} pid {d}", .{a.pid}) catch "Running";
    return "Running";
}

/// The Running build line, or null when no connection has reported one.
pub fn runningBuildLine(buf: []u8, a: Agent) ?[]const u8 {
    const b = a.running_build orelse return null;
    const suffix = if (a.isStale()) " \u{2014} updates itself when no sessions need it" else "";
    return std.fmt.bufPrint(buf, "{s}{s}", .{ b, suffix }) catch b;
}

/// "5 minutes ago" for `secs` seconds in the past (Mac's `.relative(.named)`).
pub fn relative(buf: []u8, secs: i64) []const u8 {
    const s = @max(secs, 0);
    if (s < 60) return "just now";
    const Unit = struct { n: i64, one: []const u8, many: []const u8 };
    const u: Unit = if (s < 3600)
        .{ .n = @divTrunc(s, 60), .one = "minute", .many = "minutes" }
    else if (s < 86400)
        .{ .n = @divTrunc(s, 3600), .one = "hour", .many = "hours" }
    else
        .{ .n = @divTrunc(s, 86400), .one = "day", .many = "days" };
    if (u.n == 1 and u.one[0] == 'd') return "yesterday";
    return std.fmt.bufPrint(buf, "{d} {s} ago", .{ u.n, if (u.n == 1) u.one else u.many }) catch "";
}

/// The Updates caption under "Ghoztty <version>" (Mac `VersionSection`):
/// "Build X. Last checked 5 minutes ago." - each half only when known.
pub fn versionCaption(buf: []u8, build: []const u8, last_check_ms: ?i64, now_ms: i64) []const u8 {
    var rel_buf: [48]u8 = undefined;
    const rel: ?[]const u8 = if (last_check_ms) |t| relative(&rel_buf, @divTrunc(now_ms - t, 1000)) else null;
    var w: std.Io.Writer = .fixed(buf);
    if (build.len > 0) w.print("Build {s}.", .{build}) catch {};
    if (rel) |r| w.print("{s}Last checked {s}.", .{ if (build.len > 0) " " else "", r }) catch {};
    if (w.end == 0) w.writeAll("Not checked for updates since the app started.") catch {};
    return w.buffered();
}

/// The two Pane style cards, in Mac's order, with their labels.
pub const PaneStyle = struct { value: []const u8, label: []const u8 };
pub const pane_styles = [_]PaneStyle{
    .{ .value = "elevated", .label = "Elevated" },
    .{ .value = "flat", .label = "Flat" },
};
pub const pane_style_caption = "Elevated: raised cards on a gradient. Flat: classic edge-to-edge panes.";

/// Remote Machines (T2686, Mac `RemoteMachinesSection`): the account line,
/// then one row per enrolled machine with its presence dot and the host
/// defaults new sessions on it start with. The rows are seeded from the
/// remembered directory (no network on the GUI thread) and read `checking`
/// until the background fetch answers.
pub const Account = enum { signed_in, signed_out, unconfigured };

pub const Presence = enum {
    checking,
    online,
    offline,

    pub fn word(self: Presence) []const u8 {
        return switch (self) {
            .checking => "checking\u{2026}",
            .online => "online",
            .offline => "offline",
        };
    }
};

pub const Machine = struct {
    /// The relay device id (the host-defaults key).
    id: []const u8,
    name: []const u8,
    presence: Presence = .checking,
    working_directory: ?[]const u8 = null,
    shell: ?[]const u8 = null,
};

/// The label over the account caption (Mac: "Signed in as <email>" /
/// "Not signed in"). A bare-token credential has no email: "your account".
pub fn accountTitle(buf: []u8, account: Account, email: ?[]const u8) []const u8 {
    return switch (account) {
        .signed_in => std.fmt.bufPrint(buf, "Signed in as {s}", .{email orelse "your account"}) catch "Signed in",
        .signed_out, .unconfigured => "Not signed in",
    };
}

/// The caption under it. Mac names its shortcut; Windows names its own.
pub fn accountCaption(account: Account) []const u8 {
    return switch (account) {
        .signed_in => "Machines enrolled in your account appear below.",
        .signed_out => "Sign in from New Remote Window (Ctrl+Shift+N) to reach your other machines.",
        .unconfigured => "Remote machines aren\u{2019}t set up in this build of Ghoztty.",
    };
}

/// A machine's caption: "online · folder: ~/src · shell: zsh", each default
/// reading "remote default" when the host has none.
pub fn machineCaption(buf: []u8, m: Machine) []const u8 {
    return std.fmt.bufPrint(buf, "{s} \u{00B7} folder: {s} \u{00B7} shell: {s}", .{
        m.presence.word(),
        m.working_directory orelse "remote default",
        m.shell orelse "remote default",
    }) catch m.presence.word();
}

const testing = std.testing;

test "settings_live: remote machines account lines" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Signed in as a@b.c", accountTitle(&buf, .signed_in, "a@b.c"));
    try testing.expectEqualStrings("Signed in as your account", accountTitle(&buf, .signed_in, null));
    try testing.expectEqualStrings("Not signed in", accountTitle(&buf, .signed_out, "stale@x"));
    try testing.expectEqualStrings("Not signed in", accountTitle(&buf, .unconfigured, null));
    try testing.expect(std.mem.indexOf(u8, accountCaption(.signed_out), "Ctrl+Shift+N") != null);
    try testing.expectEqualStrings("Machines enrolled in your account appear below.", accountCaption(.signed_in));
}

test "settings_live: machine caption names presence and both defaults" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "checking\u{2026} \u{00B7} folder: remote default \u{00B7} shell: remote default",
        machineCaption(&buf, .{ .id = "d", .name = "Box" }),
    );
    try testing.expectEqualStrings(
        "online \u{00B7} folder: ~/src \u{00B7} shell: zsh",
        machineCaption(&buf, .{ .id = "d", .name = "Box", .presence = .online, .working_directory = "~/src", .shell = "zsh" }),
    );
    try testing.expectEqualStrings(
        "offline \u{00B7} folder: remote default \u{00B7} shell: fish",
        machineCaption(&buf, .{ .id = "d", .name = "Box", .presence = .offline, .shell = "fish" }),
    );
}

test "settings_live: status line never claims a dead agent" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Not running \u{2014} it starts with the first terminal", statusLine(&buf, .{ .pid = 42 }));
    try testing.expectEqualStrings("Running \u{00B7} pid 42", statusLine(&buf, .{ .running = true, .pid = 42 }));
    try testing.expectEqualStrings("Running", statusLine(&buf, .{ .running = true }));
}

test "settings_live: running build names staleness only when both builds are known" {
    var buf: [128]u8 = undefined;
    try testing.expect(runningBuildLine(&buf, .{ .running = true }) == null);
    try testing.expectEqualStrings("20260731-aaa", runningBuildLine(&buf, .{ .running_build = "20260731-aaa" }).?);
    const stale = runningBuildLine(&buf, .{ .running_build = "20260719-574fe0805", .bundled_build = "20260730-e69d41755" }).?;
    try testing.expect(std.mem.endsWith(u8, stale, "updates itself when no sessions need it"));
    const current = runningBuildLine(&buf, .{ .running_build = "20260730-e69d41755", .bundled_build = "20260730-e69d41755" }).?;
    try testing.expectEqualStrings("20260730-e69d41755", current);
}

test "settings_live: relative time" {
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("just now", relative(&buf, 5));
    try testing.expectEqualStrings("just now", relative(&buf, -3));
    try testing.expectEqualStrings("1 minute ago", relative(&buf, 61));
    try testing.expectEqualStrings("5 minutes ago", relative(&buf, 300));
    try testing.expectEqualStrings("2 hours ago", relative(&buf, 7200));
    try testing.expectEqualStrings("yesterday", relative(&buf, 90000));
    try testing.expectEqualStrings("3 days ago", relative(&buf, 3 * 86400));
}

test "settings_live: version caption" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Build abc123. Last checked 5 minutes ago.", versionCaption(&buf, "abc123", 0, 300_000));
    try testing.expectEqualStrings("Build abc123.", versionCaption(&buf, "abc123", null, 300_000));
    try testing.expectEqualStrings("Last checked just now.", versionCaption(&buf, "", 1000, 2000));
    try testing.expectEqualStrings("Not checked for updates since the app started.", versionCaption(&buf, "", null, 0));
}

test "settings_live: pane style cards are Mac's two, in order" {
    try testing.expectEqual(@as(usize, 2), pane_styles.len);
    try testing.expectEqualStrings("elevated", pane_styles[0].value);
    try testing.expectEqualStrings("flat", pane_styles[1].value);
}
