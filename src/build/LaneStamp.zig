//! T952 — every lane's test binary says which lane built it.
//!
//! `-Dapp-runtime=none` and `-Dapp-runtime=win32` both link `ghostty-test.exe`,
//! into different `.zig-cache\o\<hash>\` directories, and nothing on disk says
//! which is which. The crash tooling (`scripts\lib\CrashCatch.ps1`) used to
//! answer that by reading a hand-kept table of test names out of each candidate
//! (T855). That works and is covered, but it is an inference: renaming one of
//! the named tests makes every candidate fail to verify.
//!
//! The build already KNOWS the answer, so it writes it down. Between the link
//! and the test run, this step writes `<exe>.lane` beside the binary:
//!
//!     ghoztty-lane-stamp 1
//!     lane=win32
//!     exe=ghostty-test.exe
//!     optimize=Debug
//!     filters=
//!     size=101234567
//!     mtime_ns=1790000000000000000
//!
//! `size` and `mtime_ns` bind the stamp to the exact bytes it describes, so a
//! stamp that no longer matches its binary is a loud contradiction for the
//! reader rather than a fact it believes. `filters` is `|`-joined, empty for the
//! full lane build.
//!
//! The step runs every time the lane runs (it has no inputs a cache could key
//! a skip on, and costs one stat and one small write), so a binary the lane
//! ran always carries a current stamp — including one that then crashed.

const LaneStamp = @This();

const std = @import("std");
const Step = std.Build.Step;

pub const magic = "ghoztty-lane-stamp 1";
pub const suffix = ".lane";

step: Step,
compile: *Step.Compile,
lane: []const u8,
filters: []const []const u8,

/// Make `run` (a run of `compile`) wait for `compile`'s lane stamp.
pub fn attach(
    compile: *Step.Compile,
    run: *Step.Run,
    lane: []const u8,
    filters: []const []const u8,
) void {
    const b = compile.step.owner;
    const self = b.allocator.create(LaneStamp) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = b.fmt("lane-stamp {s} ({s})", .{ compile.name, lane }),
            .owner = b,
            .makeFn = make,
        }),
        .compile = compile,
        .lane = lane,
        .filters = filters,
    };
    // Resolves the emitted-bin lazy path, which also makes this step depend on
    // the link.
    compile.getEmittedBin().addStepDependencies(&self.step);
    run.step.dependOn(&self.step);
}

pub const Fields = struct {
    lane: []const u8,
    exe: []const u8,
    optimize: []const u8,
    filters: []const []const u8,
    size: u64,
    mtime_ns: i128,
};

/// The stamp's exact text. Pure, so the format is pinned by a unit test that
/// the PowerShell reader's own fixtures are written against.
pub fn format(w: *std.Io.Writer, f: Fields) std.Io.Writer.Error!void {
    try w.print("{s}\n", .{magic});
    try w.print("lane={s}\n", .{f.lane});
    try w.print("exe={s}\n", .{f.exe});
    try w.print("optimize={s}\n", .{f.optimize});
    try w.writeAll("filters=");
    for (f.filters, 0..) |filter, i| {
        if (i > 0) try w.writeByte('|');
        try w.writeAll(filter);
    }
    try w.writeByte('\n');
    try w.print("size={d}\n", .{f.size});
    try w.print("mtime_ns={d}\n", .{f.mtime_ns});
}

fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
    _ = options;
    const self: *LaneStamp = @fieldParentPtr("step", step);
    const b = step.owner;

    const exe_path = self.compile.getEmittedBin().getPath2(b, step);
    const stat = std.fs.cwd().statFile(exe_path) catch |err|
        return step.fail("lane stamp: cannot stat '{s}': {s}", .{ exe_path, @errorName(err) });

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    format(&w, .{
        .lane = self.lane,
        .exe = std.fs.path.basename(exe_path),
        .optimize = @tagName(self.compile.root_module.optimize orelse .Debug),
        .filters = self.filters,
        .size = stat.size,
        .mtime_ns = stat.mtime,
    }) catch return step.fail("lane stamp: the stamp for '{s}' does not fit in {d} bytes", .{ exe_path, buf.len });

    const stamp_path = b.fmt("{s}{s}", .{ exe_path, suffix });
    std.fs.cwd().writeFile(.{ .sub_path = stamp_path, .data = w.buffered() }) catch |err|
        return step.fail("lane stamp: cannot write '{s}': {s}", .{ stamp_path, @errorName(err) });
}

test "the stamp text is the format the crash tooling reads" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format(&w, .{
        .lane = "win32",
        .exe = "ghostty-test.exe",
        .optimize = "Debug",
        .filters = &.{},
        .size = 42,
        .mtime_ns = 1790000000123456700,
    });
    try std.testing.expectEqualStrings(
        \\ghoztty-lane-stamp 1
        \\lane=win32
        \\exe=ghostty-test.exe
        \\optimize=Debug
        \\filters=
        \\size=42
        \\mtime_ns=1790000000123456700
        \\
    , w.buffered());
}

test "filters are pipe-joined so a filtered build says what it left in" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format(&w, .{
        .lane = "none",
        .exe = "ghostty-test.exe",
        .optimize = "ReleaseSafe",
        .filters = &.{ "Screen", "PageList" },
        .size = 1,
        .mtime_ns = 0,
    });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\nfilters=Screen|PageList\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\noptimize=ReleaseSafe\n") != null);
}
