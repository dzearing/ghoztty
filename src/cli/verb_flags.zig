//! Flag allowlists for the FORWARDING verbs — the ones whose
//! `parseManuallyHook` collects the whole command line and hands it to the
//! running instance over IPC (`+close`, `+split`, `+new-window`, ...).
//!
//! Why the check lives here and not in the server: the server parses these
//! arguments with `apprt.ipc.args.parseVerbArgs`, which ignores an argument
//! it does not recognize ON PURPOSE. That tolerance is the app↔CLI
//! compatibility contract — a Ghoztty that has been running for a week must
//! not hard-fail on a flag a newer CLI learned this morning (`--cwd-implicit`
//! and `--keys-resolved=` both rely on it). So the server cannot be the one to
//! complain, and before T852 nobody was: a mistyped `--targt=dev` reached the
//! server, was dropped, and the verb did something ELSE at exit 0.
//!
//! "Hard error on an unknown flag is the CLI's rule, not the server's". The
//! CLI knows exactly which flags each verb has, so it is the honest place to
//! say so — the same call `+send-keys` made in T489.
//!
//! The allowlists below are the flags the SERVER HANDLERS actually read, not
//! the flags the doc comments happen to list: a spelling that works today
//! keeps working, including the aliases the shared parser maps
//! (`--split=`/`--direction=`, `--split-percent=`/`--percent=`), plus the
//! handful the CLI consumes itself (`--class=`) or inserts
//! (`--cwd-implicit`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");

/// One verb's accepted flags.
pub const Spec = struct {
    /// The verb as a user types it, `+split`. Used in the error message.
    verb: []const u8,

    /// Every flag the verb accepts, WITHOUT the leading `--`. An entry that
    /// ends in `=` carries a value (`target=`: only `--target=<value>` is
    /// right); an entry without one is a switch (`no-activate`: only the bare
    /// spelling is right). T950: the server binds nothing else — `--target
    /// dev` reaches it as a valueless `--target` plus a stray word, and both
    /// are dropped at exit 0 — so the shape is part of the check, not just
    /// the name.
    flags: []const []const u8,
};

/// The most flags any one verb has. `report` strips the `=` off each entry
/// into a stack buffer of this size to look for a near spelling.
const max_flags = 32;

/// What is wrong with one `--flag` argument.
pub const Problem = struct {
    kind: Kind,

    /// The flag name as typed, without `--` or anything after an `=`.
    name: []const u8,

    pub const Kind = enum {
        /// Not a flag of this verb at all.
        unknown,
        /// A value flag written without `=`: `--target dev`.
        value_required,
        /// A switch given a value: `--no-activate=true`.
        value_not_allowed,
    };
};

/// The entry's flag name, without the trailing `=` a value flag carries.
fn entryName(entry: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, entry, "=")) entry[0 .. entry.len - 1] else entry;
}

/// Whether the entry for `name` in `spec` carries a value; null when `spec`
/// has no such flag.
pub fn takesValue(spec: Spec, name: []const u8) ?bool {
    for (spec.flags) |entry| {
        if (std.mem.eql(u8, entryName(entry), name)) return std.mem.endsWith(u8, entry, "=");
    }
    return null;
}

/// What is wrong with `arg` as a flag of this verb; null when the argument is
/// fine to forward.
///
/// Only `--` arguments are checked. A single-dash argument is not a typo of
/// anything here — `-e` starts a command tail, and `+set-banner` text may
/// legitimately begin with a dash — so it passes through as content.
pub fn checkFlag(spec: Spec, arg: []const u8) ?Problem {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    if (arg.len == 2) return null;

    const body = arg[2..];
    const eq = std.mem.indexOfScalar(u8, body, '=');
    const name = if (eq) |i| body[0..i] else body;
    const wants_value = takesValue(spec, name) orelse
        return .{ .kind = .unknown, .name = name };

    if (wants_value and eq == null) return .{ .kind = .value_required, .name = name };
    if (!wants_value and eq != null) return .{ .kind = .value_not_allowed, .name = name };
    return null;
}

/// Per-verb flag state, embedded in a forwarding verb's `Options` as
/// `_flags`. Two jobs: remember the first flag that was not understood (so
/// `runArgs`, which has a writer, can report it) and honor a bare `--`.
pub const Checker = struct {
    spec: Spec,

    /// The first argument that looked like a flag and was not a right one.
    /// Recorded rather than thrown, because the parse hook has nothing to
    /// explain itself with. Its `name` is owned by the parse allocator.
    problem: ?Problem = null,

    /// For a `value_required` problem: the argument right after the flag,
    /// when it is not itself a flag — almost always the value the caller
    /// meant (`--target dev`), so the message can show the exact fix.
    stray_value: ?[]const u8 = null,

    /// The previous argument was the `value_required` flag, so this one may
    /// be its stray value.
    awaiting_value: bool = false,

    /// Set by a bare `--`: nothing after it is a flag.
    flags_done: bool = false,

    /// `--help` past the first position, which `args.parse` only checks for
    /// at the front. Without this it would be reported as an unknown flag,
    /// which is a worse answer than the help it asked for. `-h` is NOT
    /// checked: a single dash is content on these verbs (`+set-banner` text).
    help_requested: bool = false,

    /// Classify one argument. Returns true when it should be FORWARDED to the
    /// server, false when the CLI consumed it.
    ///
    /// What is consumed: a bare `--`, which stops flag parsing, and a late
    /// `--help`. Neither must travel — `+set-banner` treats every non-flag
    /// argument as banner text, so a forwarded `--` would render as two
    /// literal dashes.
    pub fn accept(self: *Checker, alloc: Allocator, arg: []const u8) Allocator.Error!bool {
        if (self.awaiting_value) {
            self.awaiting_value = false;
            if (!std.mem.startsWith(u8, arg, "--")) self.stray_value = try alloc.dupe(u8, arg);
        }

        if (self.flags_done) return true;

        if (std.mem.eql(u8, arg, "--")) {
            self.flags_done = true;
            return false;
        }

        if (std.mem.eql(u8, arg, "--help")) {
            self.help_requested = true;
            return false;
        }

        if (self.problem == null) {
            if (checkFlag(self.spec, arg)) |found| {
                self.problem = .{ .kind = found.kind, .name = try alloc.dupe(u8, found.name) };
                self.awaiting_value = found.kind == .value_required;
            }
        }

        return true;
    }

    /// Free what `accept` allocated. Only tests need this: the verbs parse
    /// into an arena.
    pub fn deinit(self: *Checker, alloc: Allocator) void {
        if (self.problem) |p| alloc.free(p.name);
        if (self.stray_value) |v| alloc.free(v);
        self.* = undefined;
    }

    /// Report the first wrong flag, if there was one. Returns true when the
    /// verb must exit non-zero without doing its work.
    ///
    /// The message shape is T489's, so a mistake reads the same whichever
    /// verb it landed on: the verb, the flag by name, what to write instead,
    /// and a `--help` pointer.
    pub fn report(self: *const Checker, writer: *std.Io.Writer) std.Io.Writer.Error!bool {
        const problem = self.problem orelse return false;
        const verb = self.spec.verb;
        const name = problem.name;

        switch (problem.kind) {
            .unknown => {
                try writer.print("{s}: unknown flag --{s}", .{ verb, name });
                var names_buf: [max_flags][]const u8 = undefined;
                const count = @min(self.spec.flags.len, max_flags);
                for (self.spec.flags[0..count], 0..) |entry, i| names_buf[i] = entryName(entry);
                if (args.nearestName(names_buf[0..count], name)) |suggestion| {
                    try writer.print(" (did you mean --{s}?)", .{suggestion});
                }
                try writer.writeAll("\n");
            },
            .value_required => {
                try writer.print("{s}: --{s} needs a value; write it as --{s}=", .{ verb, name, name });
                if (self.stray_value) |value| {
                    try writer.print("{s}\n", .{value});
                } else {
                    try writer.writeAll("<value>\n");
                }
            },
            .value_not_allowed => try writer.print(
                "{s}: --{s} takes no value; write it as --{s}\n",
                .{ verb, name, name },
            ),
        }
        try writer.print("run 'ghoztty {s} --help' for usage\n", .{verb});
        return true;
    }
};

// -- The allowlists --------------------------------------------------------
//
// Each list is "what a server handler reads for this verb", taken from the
// win32 handlers (`apprt/win32/IpcHandlers.zig`) and the macOS ones
// (`macos/Sources/Features/IPC/IPCServer.swift`) together — the CLI is shared,
// so a flag EITHER server honors has to survive the check.

pub const close: Spec = .{
    .verb = "+close",
    .flags = &.{"target="},
};

pub const rename: Spec = .{
    .verb = "+rename",
    .flags = &.{ "target=", "title=" },
};

pub const rearrange: Spec = .{
    .verb = "+rearrange",
    .flags = &.{ "target=", "layout=" },
};

pub const read: Spec = .{
    .verb = "+read",
    .flags = &.{ "name=", "lines=" },
};

pub const set_banner: Spec = .{
    .verb = "+set-banner",
    .flags = &.{ "target=", "clear" },
};

pub const set_state: Spec = .{
    .verb = "+set-state",
    .flags = &.{ "target=", "state=" },
};

/// `--config` (T893) takes no value: it is the whole-app "re-read your
/// configuration" form of the verb, and it is the only one that does not
/// name a target.
pub const reload: Spec = .{
    .verb = "+reload",
    .flags = &.{ "target=", "config" },
};

/// `--split=`/`--direction=` and `--split-percent=`/`--percent=` are aliases
/// in the shared parser, and the skill's own examples use the `--split-*`
/// spellings on `+split`, so both survive.
pub const split: Spec = .{
    .verb = "+split",
    .flags = &.{
        "target=",
        "name=",
        "pane=",
        "direction=",
        "split=",
        "percent=",
        "split-percent=",
        "from-focused",
        "view=",
        "command=",
        "split-command=",
        "shell=",
        "env=",
        "color=",
        "working-directory=",
    },
};

/// `--class=` is consumed by the CLI itself (it picks WHICH instance to talk
/// to) and `--cwd-implicit` is inserted by the CLI, so both belong here even
/// though no handler field is named for them.
pub const new_window: Spec = .{
    .verb = "+new-window",
    .flags = &.{
        "class=",
        "target=",
        "name=",
        "title=",
        "command=",
        "view=",
        "working-directory=",
        "shell=",
        "env=",
        "color=",
        "split-color=",
        "split=",
        "direction=",
        "split-command=",
        "split-percent=",
        "percent=",
        "no-activate",
        "from-focused",
        "cwd-implicit",
    },
};

pub const new_remote_window: Spec = .{
    .verb = "+new-remote-window",
    .flags = &.{
        "host=",
        "port=",
        "relay=",
        "device=",
        "token=",
        "name=",
        "title=",
        "working-directory=",
        "shell=",
        "command=",
        "no-activate",
    },
};

// -- Tests -----------------------------------------------------------------

const testing = std.testing;

test "checkFlag: an accepted flag in its own shape passes" {
    try testing.expect(checkFlag(split, "--target=dev") == null);
    try testing.expect(checkFlag(split, "--from-focused") == null);
    try testing.expect(checkFlag(close, "--target=dev") == null);

    // An `=` inside the value is still the value (`--env=A=1`).
    try testing.expect(checkFlag(new_window, "--env=A=1") == null);
}

test "checkFlag: a misspelling is named without its value" {
    const p = checkFlag(split, "--targt=dev").?;
    try testing.expectEqual(Problem.Kind.unknown, p.kind);
    try testing.expectEqualStrings("targt", p.name);
    try testing.expectEqualStrings("bogus-flag", checkFlag(close, "--bogus-flag=1").?.name);
}

test "checkFlag: another verb's flag is still unknown here" {
    // The whole point of per-verb lists: `--layout=` is real, just not on
    // `+close`, and forwarding it there did nothing at exit 0.
    try testing.expectEqualStrings("layout", checkFlag(close, "--layout={}").?.name);
    try testing.expectEqualStrings("state", checkFlag(reload, "--state=busy").?.name);

    // T893: `--config` is real on `+reload` and takes no value, so the
    // valueless spelling has to pass the same check `--target=` does.
    try testing.expect(checkFlag(reload, "--config") == null);
}

test "checkFlag: a value flag written without its value is value_required" {
    // T950: `--target dev` used to match the entry `target` and forward a
    // valueless `--target` the server never binds.
    const p = checkFlag(close, "--target").?;
    try testing.expectEqual(Problem.Kind.value_required, p.kind);
    try testing.expectEqualStrings("target", p.name);

    try testing.expectEqual(Problem.Kind.value_required, checkFlag(read, "--lines").?.kind);
    try testing.expectEqual(Problem.Kind.value_required, checkFlag(rename, "--title").?.kind);
    try testing.expectEqual(Problem.Kind.value_required, checkFlag(new_remote_window, "--host").?.kind);
}

test "checkFlag: a switch given a value is value_not_allowed" {
    const p = checkFlag(set_banner, "--clear=1").?;
    try testing.expectEqual(Problem.Kind.value_not_allowed, p.kind);
    try testing.expectEqualStrings("clear", p.name);

    try testing.expectEqual(Problem.Kind.value_not_allowed, checkFlag(new_window, "--no-activate=true").?.kind);
    try testing.expectEqual(Problem.Kind.value_not_allowed, checkFlag(reload, "--config=").?.kind);
}

test "checkFlag: single-dash arguments and a bare -- are not flags" {
    // `-e` starts a command tail; `-la` is content. Neither is a typo of a
    // long flag, so neither is checked.
    try testing.expect(checkFlag(split, "-e") == null);
    try testing.expect(checkFlag(set_banner, "-la") == null);
    try testing.expect(checkFlag(set_banner, "--") == null);
    try testing.expect(checkFlag(set_banner, "ready to merge") == null);
}

test "Checker: records the FIRST problem and keeps forwarding" {
    var checker: Checker = .{ .spec = split };
    const alloc = testing.allocator;
    defer checker.deinit(alloc);

    try testing.expect(try checker.accept(alloc, "--target=dev"));
    try testing.expect(try checker.accept(alloc, "--dirction=right"));
    try testing.expect(try checker.accept(alloc, "--also-bogus=1"));
    try testing.expect(try checker.accept(alloc, "--name"));

    try testing.expectEqual(Problem.Kind.unknown, checker.problem.?.kind);
    try testing.expectEqualStrings("dirction", checker.problem.?.name);
    try testing.expect(checker.stray_value == null);
}

test "Checker: a late --help asks for help rather than being a typo" {
    var checker: Checker = .{ .spec = split };
    const alloc = testing.allocator;

    // `args.parse` only looks for --help at the front; anywhere else it lands
    // here, and "unknown flag --help" would be a worse answer than the help.
    try testing.expect(try checker.accept(alloc, "--target=x"));
    try testing.expect(!try checker.accept(alloc, "--help"));

    try testing.expect(checker.help_requested);
    try testing.expect(checker.problem == null);
}

test "Checker: a bare -- is consumed and stops flag checking" {
    var checker: Checker = .{ .spec = set_banner };
    const alloc = testing.allocator;

    // A banner line that starts with dashes is TEXT, and the escape hatch is
    // the same one `+send-keys` has. The `--` itself must not be forwarded:
    // the server would render it as banner text.
    try testing.expect(try checker.accept(alloc, "--target=dev"));
    try testing.expect(!try checker.accept(alloc, "--"));
    try testing.expect(try checker.accept(alloc, "--- build failed ---"));
    try testing.expect(try checker.accept(alloc, "--target"));

    try testing.expect(checker.problem == null);
    try testing.expect(checker.flags_done);
}

test "Checker: the word after a valueless flag is remembered as its value" {
    var checker: Checker = .{ .spec = close };
    const alloc = testing.allocator;
    defer checker.deinit(alloc);

    try testing.expect(try checker.accept(alloc, "--target"));
    try testing.expect(try checker.accept(alloc, "dev"));

    try testing.expectEqual(Problem.Kind.value_required, checker.problem.?.kind);
    try testing.expectEqualStrings("dev", checker.stray_value.?);
}

test "Checker: a flag after a valueless flag is not taken as its value" {
    var checker: Checker = .{ .spec = split };
    const alloc = testing.allocator;
    defer checker.deinit(alloc);

    try testing.expect(try checker.accept(alloc, "--name"));
    try testing.expect(try checker.accept(alloc, "--target=dev"));

    try testing.expectEqual(Problem.Kind.value_required, checker.problem.?.kind);
    try testing.expect(checker.stray_value == null);
}

fn reportText(checker: *const Checker, buf: []u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(buf);
    try testing.expect(try checker.report(&out));
    return out.buffered();
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "Checker.report: names the verb, the flag, and the nearest spelling" {
    var checker: Checker = .{ .spec = split };
    const alloc = testing.allocator;
    defer checker.deinit(alloc);
    try testing.expect(try checker.accept(alloc, "--dirction=right"));

    var buf: [256]u8 = undefined;
    const text = try reportText(&checker, &buf);
    try testing.expect(contains(text, "+split: unknown flag --dirction"));
    // The suggestion is the bare name, never the `direction=` entry.
    try testing.expect(contains(text, "did you mean --direction?"));
    try testing.expect(contains(text, "run 'ghoztty +split --help' for usage"));
}

test "Checker.report: a distant typo gets no suggestion, and a clean parse says nothing" {
    var checker: Checker = .{ .spec = close };
    const alloc = testing.allocator;
    defer checker.deinit(alloc);
    try testing.expect(try checker.accept(alloc, "--bogus-flag=1"));

    var buf: [256]u8 = undefined;
    try testing.expect(!contains(try reportText(&checker, &buf), "did you mean"));

    var clean: Checker = .{ .spec = close };
    try testing.expect(try clean.accept(alloc, "--target=dev"));
    var clean_buf: [64]u8 = undefined;
    var clean_out: std.Io.Writer = .fixed(&clean_buf);
    try testing.expect(!try clean.report(&clean_out));
    try testing.expectEqual(@as(usize, 0), clean_out.buffered().len);
}

test "Checker.report: a valueless flag shows the = form, with the stray word" {
    const alloc = testing.allocator;
    var buf: [256]u8 = undefined;

    var with_word: Checker = .{ .spec = close };
    defer with_word.deinit(alloc);
    _ = try with_word.accept(alloc, "--target");
    _ = try with_word.accept(alloc, "dev");
    try testing.expect(contains(
        try reportText(&with_word, &buf),
        "+close: --target needs a value; write it as --target=dev",
    ));

    var bare: Checker = .{ .spec = close };
    defer bare.deinit(alloc);
    _ = try bare.accept(alloc, "--target");
    try testing.expect(contains(try reportText(&bare, &buf), "write it as --target=<value>"));
}

test "Checker.report: a switch given a value shows the bare form" {
    var checker: Checker = .{ .spec = new_window };
    const alloc = testing.allocator;
    defer checker.deinit(alloc);
    _ = try checker.accept(alloc, "--no-activate=true");

    var buf: [256]u8 = undefined;
    try testing.expect(contains(
        try reportText(&checker, &buf),
        "+new-window: --no-activate takes no value; write it as --no-activate",
    ));
}

const all_specs = [_]Spec{
    close,     rename, rearrange, read,       set_banner,
    set_state, reload, split,     new_window, new_remote_window,
};

// Every flag a verb accepts must be spelled the way it is written on the
// command line: no leading dashes, a name before any `=`, and at most the
// one trailing `=` that marks a value flag. A stray one would make the flag
// it names unmatchable, which is the silent drop this file exists to remove
// — wearing the mask of a fix.
test "specs: flag entries are well formed and fit the suggestion buffer" {
    for (all_specs) |spec| {
        try testing.expect(std.mem.startsWith(u8, spec.verb, "+"));
        try testing.expect(spec.flags.len <= max_flags);
        for (spec.flags) |entry| {
            const name = entryName(entry);
            try testing.expect(name.len > 0);
            try testing.expect(name[0] != '-');
            try testing.expect(std.mem.indexOfScalar(u8, name, '=') == null);
        }
    }
}

// The switches are exactly the arguments the servers match WHOLE
// (`parseVerbArgs`' `std.mem.eql` arms, and IPCServer.swift's `arg ==`
// ones). Anything else the server reads by prefix, `--name=`, so a switch
// entry for it would pass the bare spelling the server then drops.
test "specs: the switches are exactly the server's whole-argument flags" {
    const switches = [_][]const u8{ "no-activate", "from-focused", "cwd-implicit", "config", "clear" };
    for (all_specs) |spec| {
        for (spec.flags) |entry| {
            const is_switch = !std.mem.endsWith(u8, entry, "=");
            var listed = false;
            for (switches) |s| {
                if (std.mem.eql(u8, s, entry)) listed = true;
            }
            try testing.expectEqual(is_switch, listed);
        }
    }
}

// Every flag in every allowlist is accepted in its own shape and rejected in
// the other one — the positive and negative controls for T950, per flag.
test "specs: every entry passes in its own shape and fails in the other" {
    for (all_specs) |spec| {
        for (spec.flags) |entry| {
            var right_buf: [64]u8 = undefined;
            var wrong_buf: [64]u8 = undefined;
            const name = entryName(entry);
            if (std.mem.endsWith(u8, entry, "=")) {
                const right = try std.fmt.bufPrint(&right_buf, "--{s}=v", .{name});
                const wrong = try std.fmt.bufPrint(&wrong_buf, "--{s}", .{name});
                try testing.expect(checkFlag(spec, right) == null);
                try testing.expectEqual(Problem.Kind.value_required, checkFlag(spec, wrong).?.kind);
            } else {
                const right = try std.fmt.bufPrint(&right_buf, "--{s}", .{name});
                const wrong = try std.fmt.bufPrint(&wrong_buf, "--{s}=1", .{name});
                try testing.expect(checkFlag(spec, right) == null);
                try testing.expectEqual(Problem.Kind.value_not_allowed, checkFlag(spec, wrong).?.kind);
            }
        }
    }
}
