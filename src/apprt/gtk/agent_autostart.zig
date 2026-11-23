//! The Linux login entry that brings `ghoztty-agent` back after a reboot or a
//! crash without the app (T3398, Linux L8c) - the pure half.
//!
//! Every seat has one, written by the app once persistence has engaged:
//!
//! | Seat    | Entry                                                         |
//! |---------|---------------------------------------------------------------|
//! | macOS   | a per-user LaunchAgent                                        |
//! | Windows | `HKCU\...\Run\GhozttyAgent[-debug]` (`win32/LocalAgent.zig`)  |
//! | Linux   | a `systemd --user` unit when the user's systemd runs, else an |
//! |         | XDG autostart `.desktop` entry                                |
//!
//! Both Linux entries run the agent with EXACTLY the argv and the environment
//! `LocalAgent.spawnDetached` gives it, so the agent a login starts and the
//! agent the app spawns on demand are the same process with the same state
//! dir, lock and socket - whichever comes first serves, and the other finds it.
//!
//! **Why two.** A user systemd is the right supervisor: it restarts a crashed
//! agent (`Restart=on-failure`) and starts it at login with no desktop
//! session. It is not always there: WSL only boots systemd with
//! `[boot] systemd=true` in `/etc/wsl.conf`, which is the user's file and is
//! never edited here, and some distros run without it. Then the XDG autostart
//! entry is the login hook every desktop session honours (no crash restart:
//! the app's on-demand spawn covers that, as it always has).
//!
//! **Which one** is decided by whether the user's systemd instance is reachable
//! RIGHT NOW: its private socket, `$XDG_RUNTIME_DIR/systemd/private`. Whichever
//! is written, the other backend's file of the same name is removed, so a box
//! that turns systemd on (or off) never starts two agents at login.
//!
//! **Names.** `ghoztty-agent[-debug][-<lineage>]`, the Windows value name's
//! shape: a debug build and a test lineage never overwrite the release entry.
//!
//! **Gates** (the Windows Run key's, same `GHOZTTY_AGENT_AUTOSTART`
//! vocabulary): a debug build writes only under `force` or `gate`; a binary
//! inside a source checkout writes nothing unless `force`; `0`/`off` writes
//! nothing at all. `gateAllows` is the one answer.
//!
//! No GTK imports: the none lane tests all of this (`src/apprt/unit_tests.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const agent_lineage = @import("../../remote/agent_lineage.zig");

/// What `GHOZTTY_AGENT_AUTOSTART` asks for. The Windows spelling, verbatim.
pub const Mode = enum { default, off, force, gate };

pub fn parseMode(v: ?[]const u8) Mode {
    const s = v orelse return .default;
    if (std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(s, "force")) return .force;
    if (std.ascii.eqlIgnoreCase(s, "gate")) return .gate;
    // Anything else is the ordinary launch: an unrecognised value must never
    // turn autostart off by accident.
    return .default;
}

/// Why a launch writes nothing, or `.write` when it may.
pub const Gate = enum {
    write,
    /// `GHOZTTY_AGENT_AUTOSTART=off`.
    disabled,
    /// A debug build without `force`/`gate`: its entry would name a dev agent.
    debug_build,
    /// The agent binary sits inside a source checkout (`build.zig` above it):
    /// a login entry would start the agent that owns the user's sessions out
    /// of a directory every rebuild replaces (Windows T1146).
    source_checkout,
};

pub fn gateAllows(mode: Mode, is_debug: bool, in_source_checkout: bool) Gate {
    if (mode == .off) return .disabled;
    if (mode == .force) return .write;
    if (is_debug and mode != .gate) return .debug_build;
    if (in_source_checkout) return .source_checkout;
    return .write;
}

pub const Backend = enum { systemd, xdg };

/// `systemd` when the user's systemd instance answers on its private socket,
/// else `xdg`.
pub fn chooseBackend(user_systemd_reachable: bool) Backend {
    return if (user_systemd_reachable) .systemd else .xdg;
}

/// `<runtime dir>/systemd/private`: the socket a running `systemd --user`
/// binds. The runtime dir is `$XDG_RUNTIME_DIR`, else `/run/user/<uid>`.
pub fn userSystemdSocket(alloc: Allocator, xdg_runtime_dir: ?[]const u8, uid: u32) Allocator.Error![]u8 {
    if (xdg_runtime_dir) |r| {
        if (r.len > 0 and r[0] == '/') return std.fmt.allocPrint(alloc, "{s}/systemd/private", .{r});
    }
    return std.fmt.allocPrint(alloc, "/run/user/{d}/systemd/private", .{uid});
}

/// Longest base name: `ghoztty-agent-debug-` + a maximal lineage.
pub const max_base_len = "ghoztty-agent-debug-".len + agent_lineage.max_len;

/// `ghoztty-agent[-debug][-<lineage>]` into `buf` (>= `max_base_len`).
pub fn baseName(buf: []u8, is_debug: bool, lineage: ?[]const u8) error{NameTooLong}![]const u8 {
    const base = if (is_debug) "ghoztty-agent-debug" else "ghoztty-agent";
    return agent_lineage.appendSuffix(buf, base, lineage);
}

/// Where each backend's file lives under the config root
/// (`$XDG_CONFIG_HOME`, else `~/.config`).
pub const Paths = struct {
    /// `<root>/systemd/user/<base>.service`
    unit: []const u8,
    /// `<root>/systemd/user/default.target.wants/<base>.service`, a symlink to
    /// `unit` - exactly what `systemctl --user enable` makes.
    wants_link: []const u8,
    /// `<root>/autostart/<base>.desktop`
    desktop: []const u8,

    pub fn deinit(self: Paths, alloc: Allocator) void {
        alloc.free(self.unit);
        alloc.free(self.wants_link);
        alloc.free(self.desktop);
    }
};

pub fn pathsFor(alloc: Allocator, config_root: []const u8, base: []const u8) Allocator.Error!Paths {
    const unit = try std.fmt.allocPrint(alloc, "{s}/systemd/user/{s}.service", .{ config_root, base });
    errdefer alloc.free(unit);
    const wants = try std.fmt.allocPrint(alloc, "{s}/systemd/user/default.target.wants/{s}.service", .{ config_root, base });
    errdefer alloc.free(wants);
    const desktop = try std.fmt.allocPrint(alloc, "{s}/autostart/{s}.desktop", .{ config_root, base });
    return .{ .unit = unit, .wants_link = wants, .desktop = desktop };
}

/// One environment variable the agent is started with.
pub const EnvVar = struct { name: []const u8, value: []const u8 };

/// Everything the entry runs: the agent and its argv after argv[0], plus the
/// environment overrides `LocalAgent.spawnDetached` puts on top of the app's.
pub const Spec = struct {
    agent: []const u8,
    args: []const []const u8,
    env: []const EnvVar,
    /// Where stdout and stderr go (the systemd unit; a desktop session owns
    /// the autostart entry's output).
    log_path: []const u8,
};

pub const RenderError = Allocator.Error || error{UnrepresentableArgument};

/// The `systemd --user` unit.
pub fn renderUnit(alloc: Allocator, spec: Spec) RenderError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    renderUnitTo(w, spec) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        error.UnrepresentableArgument => error.UnrepresentableArgument,
    };
    return out.toOwnedSlice();
}

fn renderUnitTo(w: *std.Io.Writer, spec: Spec) (std.Io.Writer.Error || error{UnrepresentableArgument})!void {
    try w.writeAll(
        \\# Written by Ghoztty: keeps your terminal sessions running across
        \\# app restarts and brings them back at login. Ghoztty rewrites this
        \\# file whenever it starts; edit a drop-in instead.
        \\[Unit]
        \\Description=Ghoztty session agent
        \\Documentation=https://github.com/dzearing/ghoztty
        \\
        \\[Service]
        \\Type=simple
        \\
    );
    try w.writeAll("ExecStart=");
    try writeSystemdArg(w, spec.agent, .exec);
    for (spec.args) |a| {
        try w.writeByte(' ');
        try writeSystemdArg(w, a, .exec);
    }
    try w.writeByte('\n');
    for (spec.env) |e| {
        try checkName(e.name);
        try w.writeAll("Environment=\"");
        try w.writeAll(e.name);
        try w.writeByte('=');
        try writeSystemdQuotedBody(w, e.value, .environment);
        try w.writeAll("\"\n");
    }
    // `~` is systemd's spelling of the user's home: the cwd spawnDetached gives
    // the agent, which a session opened without a directory inherits.
    try w.writeAll("WorkingDirectory=~\n");
    try w.writeAll("StandardOutput=append:");
    try writeSystemdPath(w, spec.log_path);
    try w.writeAll("\nStandardError=append:");
    try writeSystemdPath(w, spec.log_path);
    try w.writeByte('\n');
    // A crash comes back; a second agent that lost the single-instance lock
    // to the one the app already spawned (exit 183, `single_instance`) does
    // not spin against it.
    try w.writeAll(
        \\Restart=on-failure
        \\RestartSec=2
        \\RestartPreventExitStatus=183
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    );
}

/// The XDG autostart entry. A desktop `Exec` cannot set the environment, so
/// it runs the agent through `/usr/bin/env`.
pub fn renderDesktop(alloc: Allocator, spec: Spec) RenderError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    renderDesktopTo(w, spec) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        error.UnrepresentableArgument => error.UnrepresentableArgument,
    };
    return out.toOwnedSlice();
}

fn renderDesktopTo(w: *std.Io.Writer, spec: Spec) (std.Io.Writer.Error || error{UnrepresentableArgument})!void {
    try w.writeAll(
        \\# Written by Ghoztty: keeps your terminal sessions running across
        \\# app restarts and brings them back at login.
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Ghoztty session agent
        \\Comment=Keeps Ghoztty terminal sessions running
        \\Exec=/usr/bin/env
    );
    for (spec.env) |e| {
        try checkName(e.name);
        try w.writeByte(' ');
        var buf: [4096]u8 = undefined;
        const kv = std.fmt.bufPrint(&buf, "{s}={s}", .{ e.name, e.value }) catch
            return error.UnrepresentableArgument;
        try writeDesktopArg(w, kv);
    }
    try w.writeByte(' ');
    try writeDesktopArg(w, spec.agent);
    for (spec.args) |a| {
        try w.writeByte(' ');
        try writeDesktopArg(w, a);
    }
    try w.writeAll(
        \\
        \\Terminal=false
        \\NoDisplay=true
        \\X-GNOME-Autostart-enabled=true
        \\
    );
}

fn checkName(name: []const u8) error{UnrepresentableArgument}!void {
    if (name.len == 0) return error.UnrepresentableArgument;
    for (name) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_' => {},
        else => return error.UnrepresentableArgument,
    };
}

/// A line break or a NUL cannot be carried by either file format.
fn checkValue(s: []const u8) error{UnrepresentableArgument}!void {
    for (s) |c| if (c == '\n' or c == '\r' or c == 0) return error.UnrepresentableArgument;
}

const SystemdContext = enum { exec, environment };

/// One `ExecStart=` word, always double-quoted (systemd.service "Command
/// lines"): C escapes for `\` and `"`, `%%` for a literal `%` (specifiers),
/// and in a command line `$$` for a literal `$` (variable expansion).
fn writeSystemdArg(w: *std.Io.Writer, arg: []const u8, ctx: SystemdContext) (std.Io.Writer.Error || error{UnrepresentableArgument})!void {
    try w.writeByte('"');
    try writeSystemdQuotedBody(w, arg, ctx);
    try w.writeByte('"');
}

fn writeSystemdQuotedBody(w: *std.Io.Writer, s: []const u8, ctx: SystemdContext) (std.Io.Writer.Error || error{UnrepresentableArgument})!void {
    try checkValue(s);
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '%' => try w.writeAll("%%"),
        '$' => if (ctx == .exec) try w.writeAll("$$") else try w.writeByte('$'),
        else => try w.writeByte(c),
    };
}

/// A path setting (`append:<path>`) takes no quotes; only specifiers expand.
fn writeSystemdPath(w: *std.Io.Writer, s: []const u8) (std.Io.Writer.Error || error{UnrepresentableArgument})!void {
    try checkValue(s);
    for (s) |c| if (c == '%') try w.writeAll("%%") else try w.writeByte(c);
}

/// One desktop-entry `Exec` argument (Desktop Entry Specification, "The Exec
/// key"): always quoted; inside the quotes `"`, `` ` ``, `$` and `\` take a
/// backslash; `%` is the field-code escape `%%`. The value is ALSO a desktop
/// "string", whose own escape rule turns every `\` into `\\` first - so a
/// literal backslash in an argument is four in the file, as the spec says.
fn writeDesktopArg(w: *std.Io.Writer, arg: []const u8) (std.Io.Writer.Error || error{UnrepresentableArgument})!void {
    try checkValue(arg);
    try w.writeByte('"');
    for (arg) |c| switch (c) {
        '\\' => try w.writeAll("\\\\\\\\"),
        '"', '`', '$' => {
            try w.writeAll("\\\\");
            try w.writeByte(c);
        },
        '%' => try w.writeAll("%%"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "parseMode: the Windows vocabulary, anything else is the ordinary launch" {
    try testing.expectEqual(Mode.default, parseMode(null));
    try testing.expectEqual(Mode.off, parseMode("0"));
    try testing.expectEqual(Mode.off, parseMode("OFF"));
    try testing.expectEqual(Mode.force, parseMode("force"));
    try testing.expectEqual(Mode.gate, parseMode("Gate"));
    try testing.expectEqual(Mode.default, parseMode("1"));
    try testing.expectEqual(Mode.default, parseMode(""));
}

test "gateAllows: off wins, force skips both gates, gate skips only the build-mode one" {
    // A release install writes.
    try testing.expectEqual(Gate.write, gateAllows(.default, false, false));
    // A release build in a checkout (a staging build) does not.
    try testing.expectEqual(Gate.source_checkout, gateAllows(.default, false, true));
    // A debug build never does on its own...
    try testing.expectEqual(Gate.debug_build, gateAllows(.default, true, false));
    // ...`gate` lifts that, and the location gate still refuses a checkout...
    try testing.expectEqual(Gate.source_checkout, gateAllows(.gate, true, true));
    try testing.expectEqual(Gate.write, gateAllows(.gate, true, false));
    // ...and `force` writes from anywhere.
    try testing.expectEqual(Gate.write, gateAllows(.force, true, true));
    try testing.expectEqual(Gate.disabled, gateAllows(.off, false, false));
}

test "chooseBackend and the user systemd socket path" {
    try testing.expectEqual(Backend.systemd, chooseBackend(true));
    try testing.expectEqual(Backend.xdg, chooseBackend(false));
    const a = testing.allocator;
    const p1 = try userSystemdSocket(a, "/run/user/1000", 1000);
    defer a.free(p1);
    try testing.expectEqualStrings("/run/user/1000/systemd/private", p1);
    // Unset or relative (invalid per XDG): the standard location for the uid.
    const p2 = try userSystemdSocket(a, null, 42);
    defer a.free(p2);
    try testing.expectEqualStrings("/run/user/42/systemd/private", p2);
    const p3 = try userSystemdSocket(a, "relative", 7);
    defer a.free(p3);
    try testing.expectEqualStrings("/run/user/7/systemd/private", p3);
}

test "baseName: release, debug and a lineage never share a name" {
    var b: [max_base_len]u8 = undefined;
    try testing.expectEqualStrings("ghoztty-agent", try baseName(&b, false, null));
    try testing.expectEqualStrings("ghoztty-agent-debug", try baseName(&b, true, null));
    try testing.expectEqualStrings("ghoztty-agent-debug-t1", try baseName(&b, true, "t1"));
}

test "pathsFor: the unit, its enable link and the autostart entry" {
    const a = testing.allocator;
    const p = try pathsFor(a, "/home/u/.config", "ghoztty-agent");
    defer p.deinit(a);
    try testing.expectEqualStrings("/home/u/.config/systemd/user/ghoztty-agent.service", p.unit);
    try testing.expectEqualStrings("/home/u/.config/systemd/user/default.target.wants/ghoztty-agent.service", p.wants_link);
    try testing.expectEqualStrings("/home/u/.config/autostart/ghoztty-agent.desktop", p.desktop);
}

const test_spec: Spec = .{
    .agent = "/opt/ghoztty/bin/ghoztty-agent",
    .args = &.{ "--listen-unix=/home/u/.config/ghoztty/local-agent/agent.sock", "--port-file=/home/u/.config/ghoztty/local-agent/port.json" },
    .env = &.{
        .{ .name = "GHOSTTY_AGENT_LOCK", .value = "/home/u/.config/ghoztty/local-agent/agent.lock" },
        .{ .name = "GHOSTTY_AGENT_NO_SELFUPDATE", .value = "1" },
    },
    .log_path = "/home/u/.config/ghoztty/local-agent/agent.log",
};

test "renderUnit: the spawn's argv and env, restart on a crash but not on a lost lock" {
    const a = testing.allocator;
    const u = try renderUnit(a, test_spec);
    defer a.free(u);
    try testing.expect(std.mem.indexOf(u8, u,
        "\nExecStart=\"/opt/ghoztty/bin/ghoztty-agent\" \"--listen-unix=/home/u/.config/ghoztty/local-agent/agent.sock\" \"--port-file=/home/u/.config/ghoztty/local-agent/port.json\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, u, "\nEnvironment=\"GHOSTTY_AGENT_LOCK=/home/u/.config/ghoztty/local-agent/agent.lock\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, u, "\nEnvironment=\"GHOSTTY_AGENT_NO_SELFUPDATE=1\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, u, "\nStandardOutput=append:/home/u/.config/ghoztty/local-agent/agent.log\n") != null);
    try testing.expect(std.mem.indexOf(u8, u, "\nRestart=on-failure\n") != null);
    try testing.expect(std.mem.indexOf(u8, u, "\nRestartPreventExitStatus=183\n") != null);
    try testing.expect(std.mem.indexOf(u8, u, "\nWantedBy=default.target\n") != null);
    try testing.expect(std.mem.indexOf(u8, u, "\nWorkingDirectory=~\n") != null);
}

test "renderUnit: quoting survives spaces, quotes, backslashes, % and $" {
    const a = testing.allocator;
    const spec: Spec = .{
        .agent = "/home/a b/ghoztty-agent",
        .args = &.{"--x=50%\"q\"\\$HOME"},
        .env = &.{.{ .name = "V", .value = "%h $HOME \"x\"" }},
        .log_path = "/tmp/100%.log",
    };
    const u = try renderUnit(a, spec);
    defer a.free(u);
    try testing.expect(std.mem.indexOf(u8, u, "ExecStart=\"/home/a b/ghoztty-agent\" \"--x=50%%\\\"q\\\"\\\\$$HOME\"\n") != null);
    // Environment= does no `$` expansion, only specifiers.
    try testing.expect(std.mem.indexOf(u8, u, "Environment=\"V=%%h $HOME \\\"x\\\"\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, u, "StandardOutput=append:/tmp/100%%.log\n") != null);
}

test "render: a line break or a bad variable name is refused, never written" {
    const a = testing.allocator;
    var spec = test_spec;
    spec.args = &.{"--x=a\nExecStartPre=/bin/evil"};
    try testing.expectError(error.UnrepresentableArgument, renderUnit(a, spec));
    try testing.expectError(error.UnrepresentableArgument, renderDesktop(a, spec));
    spec = test_spec;
    spec.env = &.{.{ .name = "A=B", .value = "x" }};
    try testing.expectError(error.UnrepresentableArgument, renderUnit(a, spec));
    try testing.expectError(error.UnrepresentableArgument, renderDesktop(a, spec));
}

test "renderDesktop: env through /usr/bin/env, every argument quoted, hidden" {
    const a = testing.allocator;
    const d = try renderDesktop(a, test_spec);
    defer a.free(d);
    try testing.expect(std.mem.indexOf(u8, d,
        "\nExec=/usr/bin/env \"GHOSTTY_AGENT_LOCK=/home/u/.config/ghoztty/local-agent/agent.lock\" \"GHOSTTY_AGENT_NO_SELFUPDATE=1\" \"/opt/ghoztty/bin/ghoztty-agent\" \"--listen-unix=/home/u/.config/ghoztty/local-agent/agent.sock\" \"--port-file=/home/u/.config/ghoztty/local-agent/port.json\"\n") != null);
    try testing.expect(std.mem.startsWith(u8, d, "# Written by Ghoztty"));
    try testing.expect(std.mem.indexOf(u8, d, "\n[Desktop Entry]\nType=Application\n") != null);
    try testing.expect(std.mem.indexOf(u8, d, "\nNoDisplay=true\n") != null);
}

test "renderDesktop: the spec's escapes - four backslashes for one, %% for %" {
    const a = testing.allocator;
    const spec: Spec = .{
        .agent = "/a b/agent",
        .args = &.{"x\\y\"z`$%"},
        .env = &.{},
        .log_path = "/l",
    };
    const d = try renderDesktop(a, spec);
    defer a.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "Exec=/usr/bin/env \"/a b/agent\" \"x\\\\\\\\y\\\\\"z\\\\`\\\\$%%\"\n") != null);
}
