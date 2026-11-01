const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

// The bundled skill documents. They live with the win32 apprt because the
// Windows app embeds them in the exe, but the files are byte-identical to the
// Mac bundle's `macos/Resources/Ghoztty/` and the module has no OS imports, so
// the verb reads the same bytes on both platforms (T2605).
const GhosttyAssets = @import("../apprt/win32/GhosttyAssets.zig");
const runtime_agent = @import("../apprt/win32/runtime_agent.zig");

// `+agent-setup` (T2605): how an agent running inside Ghoztty finds the
// Ghoztty skill without the web. Before it, a Claude Code session installed
// after the app had no local way to learn the skill existed, searched, and
// found only the archived `ghoztty-claude-plugin` repository and its stale
// CLI docs. Every pane carries `GHOZTTY_AGENT_SETUP` naming this verb, and
// `ghoztty --help` lists it, so the trail starts wherever the agent looks.

pub const RuntimeAgent = runtime_agent.RuntimeAgent;

/// The skill this verb is about.
const skill_name = "ghoztty";

/// The name of the pane environment variable that points here.
pub const pane_env = "GHOZTTY_AGENT_SETUP";
/// Its value: the command that prints the pointer below.
pub const pane_env_value = "ghoztty +agent-setup";

pub const Options = struct {
    _arena: ?ArenaAllocator = null,

    _arguments: std.ArrayList([:0]const u8) = .empty,

    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        try self._arguments.append(alloc, try alloc.dupeZ(u8, arg));
        while (iter.next()) |param| {
            if (std.mem.eql(u8, param, "--help") or std.mem.eql(u8, param, "-h")) return true;
            try self._arguments.append(alloc, try alloc.dupeZ(u8, param));
        }

        return false;
    }

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// A parsed `+agent-setup` invocation.
pub const Request = union(enum) {
    /// No flags: print where the skill is and how to read or install it.
    pointer,
    /// `--skill[=<file>]`: print one file of the bundled skill (`SKILL.md`
    /// when no file is named).
    skill: []const u8,
    /// `--install=<agent>`: install the integration for one agent.
    install: RuntimeAgent,
    invalid: []const u8,
};

/// Pure, so the grammar is unit-tested in every lane. Slices alias the input.
pub fn parseRequest(arguments: []const []const u8) Request {
    if (arguments.len == 0) return .pointer;
    if (arguments.len > 1) return .{ .invalid = "pass one of --skill[=<file>] or --install=<agent>" };

    const arg = arguments[0];
    if (std.mem.eql(u8, arg, "--skill")) return .{ .skill = "SKILL.md" };
    if (std.mem.startsWith(u8, arg, "--skill=")) {
        const file = arg["--skill=".len..];
        if (file.len == 0) return .{ .invalid = "--skill= needs a file name (or pass --skill alone)" };
        return .{ .skill = file };
    }
    if (std.mem.startsWith(u8, arg, "--install=")) {
        const name = arg["--install=".len..];
        const agent = std.meta.stringToEnum(RuntimeAgent, name) orelse
            return .{ .invalid = "--install= takes claude or copilot" };
        return .{ .install = agent };
    }
    if (std.mem.eql(u8, arg, "--install")) return .{ .invalid = "--install= takes claude or copilot" };
    return .{ .invalid = "unknown argument (expected --skill[=<file>] or --install=<agent>)" };
}

/// The skill file named `name`, as this platform's app installs it. NTFS is
/// case-insensitive, so the lookup is too.
fn findSkillFile(name: []const u8) ?GhosttyAssets.SkillFile {
    const files = GhosttyAssets.skillFiles(skill_name) catch unreachable;
    for (files) |file| {
        if (std.ascii.eqlIgnoreCase(file.path, name)) return file;
    }
    return null;
}

/// The text of one skill file in this platform's wording: Windows rewrites
/// the Mac-only phrases (T1327) exactly as its installer does; the Mac app
/// installs the bundled bytes as they are. Caller owns the result.
pub fn skillText(alloc: Allocator, name: []const u8) (Allocator.Error || error{UnknownFile})![]u8 {
    const file = findSkillFile(name) orelse return error.UnknownFile;
    if (comptime builtin.os.tag == .windows)
        return GhosttyAssets.installedSkillFile(alloc, skill_name, file);
    return alloc.dupe(u8, file.contents);
}

/// The pointer README: what Ghoztty offers an agent, where the skill is,
/// and the exact commands that read or install it.
pub fn writePointer(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(
        \\Ghoztty agent setup
        \\
        \\You are running inside Ghoztty, a terminal that coding agents drive
        \\from the command line: open windows and split panes, read and type
        \\into other panes, show files, diffs and websites in viewer panes, and
        \\post a status banner above a pane. Every verb is `ghoztty +<verb>`;
        \\`ghoztty --help` lists them.
        \\
        \\The Ghoztty skill ships INSIDE this app and describes the CLI of this
        \\exact build. Use it from here. Do not install it from GitHub: the old
        \\dzearing/ghoztty-claude-plugin repository is archived and documents an
        \\older CLI.
        \\
        \\Read it now (nothing is installed):
        \\  ghoztty +agent-setup --skill            the skill (SKILL.md)
        \\  ghoztty +agent-setup --skill=<file>     one of its reference files:
        \\
    );
    const files = GhosttyAssets.skillFiles(skill_name) catch unreachable;
    for (files[1..]) |file| try writer.print("      {s}\n", .{file.path});
    try writer.writeAll(
        \\
        \\Install it for your agent (the skill plus the status hooks; the same
        \\thing the app's "Set Up Agent Integrations..." command does):
        \\  ghoztty +agent-setup --install=claude   Claude Code
        \\  ghoztty +agent-setup --install=copilot  Copilot CLI
        \\
        \\Start a new agent session after installing so it loads the skill.
        \\
    );
}

/// Install the integration for `agent` and print the outcome. Returns the
/// process exit code: 0 when the integration is in place afterwards.
fn install(alloc: Allocator, agent: RuntimeAgent, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    if (comptime builtin.os.tag != .windows) {
        // The Mac app's installer is Swift (`AgentIntegrationService`), so
        // this half is the Mac seat's to wire (T2612).
        try stderr.writeAll(
            "error: --install is not wired in this build yet; use Set Up Agent Integrations... in the app\n",
        );
        return 1;
    }

    const agent_home = @import("../apprt/win32/agent_home.zig");
    const service = @import("../apprt/win32/agent_integration_service.zig");

    const home = agent_home.open(alloc) orelse {
        try stderr.writeAll("error: the home directory could not be opened\n");
        return 1;
    };
    var home_dir = home.dir;
    defer home_dir.close();

    const outcome = try service.install(alloc, agent, home_dir, home.path, agent_home.probe(alloc));
    const label = try outcome.labelAlloc(alloc);
    switch (outcome) {
        .installed, .upgraded, .up_to_date => {
            try stdout.print("{s}: {s}\n", .{ agent.displayName(), label });
            try stdout.writeAll("Start a new agent session so it loads the Ghoztty skill.\n");
            return 0;
        },
        .plugin_present => {
            try stdout.print(
                "{s}: {s} - an external ghoztty plugin owns the hooks; run Set Up Agent Integrations... in the app to replace it\n",
                .{ agent.displayName(), label },
            );
            return 1;
        },
        .not_found => {
            try stderr.print("error: {s} is not installed on this machine ({s} was not found)\n", .{
                agent.displayName(), agent.binaryName(),
            });
            return 1;
        },
        else => {
            try stderr.print("error: {s}: {s}\n", .{ agent.displayName(), label });
            return 1;
        },
    }
}

/// Tell an agent running inside Ghoztty where the Ghoztty skill is, and
/// read or install it for them, with no network.
///
/// The skill is bundled with the app and describes the CLI of this exact
/// build. Every pane's environment carries `GHOZTTY_AGENT_SETUP`, whose
/// value is this command, so an agent that inspects its environment finds
/// it.
///
/// With no flags, prints a short README: what Ghoztty lets an agent do,
/// and the commands below.
///
/// Flags:
///
///   * `--skill`: Print the skill's `SKILL.md`.
///   * `--skill=<file>`: Print one of the skill's reference files (the
///     README lists them).
///   * `--install=<agent>`: Install the skill and the status hooks for
///     `claude` (Claude Code) or `copilot` (Copilot CLI), the same
///     integration the app's "Set Up Agent Integrations" command installs.
///     Exits non-zero when the integration is not in place afterwards.
///
/// Needs no running app: nothing here goes over IPC.
///
/// Available since: 1.3.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const arguments: []const []const u8 = @ptrCast(opts._arguments.items);
    switch (parseRequest(arguments)) {
        .pointer => {
            try writePointer(stdout);
            return 0;
        },
        .skill => |name| {
            const text = skillText(alloc, name) catch |err| switch (err) {
                error.UnknownFile => {
                    try stderr.print("error: the skill has no file named '{s}'; run ghoztty +agent-setup for the list\n", .{name});
                    return 1;
                },
                else => return err,
            };
            try stdout.writeAll(text);
            return 0;
        },
        .install => |agent| return install(alloc, agent, stdout, stderr),
        .invalid => |msg| {
            try stderr.print("error: {s}\n", .{msg});
            return 1;
        },
    }
}

test "agent-setup: no arguments asks for the pointer" {
    try std.testing.expect(parseRequest(&.{}) == .pointer);
}

test "agent-setup: --skill names SKILL.md, --skill=<file> names that file" {
    try std.testing.expectEqualStrings("SKILL.md", parseRequest(&.{"--skill"}).skill);
    try std.testing.expectEqualStrings("layout.md", parseRequest(&.{"--skill=layout.md"}).skill);
    try std.testing.expect(parseRequest(&.{"--skill="}) == .invalid);
}

test "agent-setup: --install takes exactly the agents the app integrates" {
    try std.testing.expectEqual(RuntimeAgent.claude, parseRequest(&.{"--install=claude"}).install);
    try std.testing.expectEqual(RuntimeAgent.copilot, parseRequest(&.{"--install=copilot"}).install);
    try std.testing.expect(parseRequest(&.{"--install=codex"}) == .invalid);
    try std.testing.expect(parseRequest(&.{"--install"}) == .invalid);
}

test "agent-setup: unknown and combined arguments are refused" {
    try std.testing.expect(parseRequest(&.{"--bogus"}) == .invalid);
    try std.testing.expect(parseRequest(&.{ "--skill", "--install=claude" }) == .invalid);
}

test "agent-setup: the pointer lists every reference file and both install commands" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try writePointer(&buf.writer);
    const text = buf.written();

    const files = try GhosttyAssets.skillFiles(skill_name);
    try std.testing.expect(files.len > 1);
    for (files[1..]) |file| try std.testing.expect(std.mem.indexOf(u8, text, file.path) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--install=claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--install=copilot") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "archived") != null);
}

test "agent-setup: --skill prints the skill in the wording this platform installs" {
    const alloc = std.testing.allocator;
    const text = try skillText(alloc, "SKILL.md");
    defer alloc.free(text);
    const files = try GhosttyAssets.skillFiles(skill_name);
    const expected = if (comptime builtin.os.tag == .windows)
        try GhosttyAssets.installedSkillFile(alloc, skill_name, files[0])
    else
        try alloc.dupe(u8, files[0].contents);
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, text);

    // Case-insensitive, like the filesystem the installer writes to.
    const upper = try skillText(alloc, "skill.md");
    defer alloc.free(upper);
    try std.testing.expectEqualStrings(expected, upper);

    try std.testing.expectError(error.UnknownFile, skillText(alloc, "nope.md"));
}
