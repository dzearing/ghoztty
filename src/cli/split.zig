const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const lib = @import("../lib/main.zig");

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// All of the arguments after `+split`. They will be sent to Ghostty
    /// for processing.
    _arguments: std.ArrayList([:0]const u8) = .empty,

    /// Enable arg parsing diagnostics so that we don't get an error if
    /// there is a "normal" config setting on the cli.
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// Manual parse hook, collect all of the arguments after `+split`.
    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        var e_seen: bool = std.mem.eql(u8, arg, "-e");

        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);

        while (iter.next()) |param| {
            if (e_seen) {
                try self._arguments.append(alloc, try alloc.dupeZ(u8, param));
                continue;
            }
            if (std.mem.eql(u8, param, "-e")) {
                e_seen = true;
                try self._arguments.append(alloc, try alloc.dupeZ(u8, param));
                continue;
            }
            if (try self.checkArg(alloc, param)) |a| try self._arguments.append(alloc, a);
        }

        return false;
    }

    fn checkArg(self: *Options, alloc: Allocator, arg: []const u8) (error{InvalidValue} || Allocator.Error)!?[:0]const u8 {
        _ = self;
        return try alloc.dupeZ(u8, arg);
    }

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Create a new split pane in a running Ghostty window.
///
/// If `--target` is specified, the split will be added to the window
/// with that name. If not specified, the split is added to the most
/// recently focused window.
///
/// This command is idempotent: if `--name` is specified and a pane with
/// that name already exists, the existing pane is focused instead of
/// creating a new split.
///
/// Flags:
///
///   * `--target=<name>`: The target window name to add the split to.
///     The target must have been created with `+new-window --target=<name>`.
///
///   * `--name=<name>`: Register this split pane with a name for later
///     targeting. If a pane with this name already exists, it will be
///     focused instead of creating a new split.
///
///   * `--direction=right|down|left|up`: The direction to split. Defaults
///     to `right` if not specified.
///
///   * `--command=<command>`: The command to run in the split pane.
///
///   * `-e`: Any arguments after this will be interpreted as a command to
///     execute in the split pane.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
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

    if (apprt.App.performIpc(
        alloc,
        .detect,
        .split,
        .{
            .arguments = if (opts._arguments.items.len == 0) null else opts._arguments.items,
        },
    ) catch |err| switch (err) {
        error.IPCFailed => return 1,
        else => {
            try stderr.print("Sending the IPC failed: {}", .{err});
            return 1;
        },
    }) return 0;

    try stderr.print("+split is not supported on this platform.\n", .{});
    return 1;
}
