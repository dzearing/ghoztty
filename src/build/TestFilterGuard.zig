//! T631 — the filtered-lane honesty guard.
//!
//! `zig build test -Dtest-filter=<pattern>` compiles the pattern into the test
//! binaries: a NAMED test whose fully-qualified name does not contain the
//! pattern is left out of the binary entirely. So a pattern that matches
//! nothing produces a run that executes no named test and exits 0 — and the
//! build says nothing at all, which is byte for byte what "matched one test
//! and it passed" looks like. Measured while validating T188: a build whose
//! `gui_pump` test carried a deliberately broken assertion came back green
//! under `-Dtest-filter=pump`, and only the unfiltered six-minute lane said
//! otherwise.
//!
//! That matters here because the standing house rule is that a new test must be
//! PROVEN to run, and the cheap way to prove it — break it, run the filter — is
//! exactly the shape the silent exit 0 defeats. A shortcut that can only ever
//! say "fine" is not a shortcut, it is a way to certify code nobody executed.
//!
//! So a top-level test step under which NO test matched the filters fails,
//! naming them. Three things this had to get right:
//!
//!   * **The count of tests that ran is not the signal.** An UNNAMED `test {}`
//!     block — the `_ = @import(…)` aggregators this repo is built out of — is
//!     compiled in regardless of any filter. `zig build test -Dapp-runtime=win32
//!     -Dtest-filter=zzz_nonexistent` therefore reports "83/83 tests passed"
//!     while running not one thing the caller asked for. The signal is instead
//!     the test METADATA the runner reports: the binary's test names, checked
//!     against the filters the same way the compiler checked them — a filter is
//!     a substring of the fully-qualified name.
//!   * **The verdict is per top-level step, not per binary.** `zig build test`
//!     runs several test binaries (the main one, the build helpers) and a real
//!     filter routinely matches in one and not the others; failing per binary
//!     would fail every honest filtered run.
//!   * **A CACHED run reports no metadata** because it did not run, which says
//!     nothing about what the filter matched. `Collector.add` takes the caching
//!     off the runs it guards whenever filters are present (a filtered lane is
//!     a diagnostic run; skipping it is never what the caller wanted), and the
//!     verdict still treats a metadata-less run as "cannot tell" rather than as
//!     evidence of nothing — a guard that guesses is worse than no guard.
//!
//! The unfiltered lane is untouched: no filters, no guard step, no change to
//! run caching.
//!
//! **What a filtered run does NOT prove** (T733). The guard reports what the
//! binary CONTAINS, which is the only honest signal available here — it is not
//! a model of zig's own matching, and measured on 0.15.2 the two disagree. The
//! compile-time filter does not behave as a plain substring of the name the
//! runner prints: `-Dtest-filter=translate_policy` compiles all nine tests of
//! `src/apprt/win32/translate_policy.zig` in, while `VK_PACKET`, `T64:`,
//! `win32.translate_policy` and even the whole printed name
//! `apprt.win32.translate_policy.test.T64: VK_PACKET is translated even on a
//! terminal surface` each compile in NONE of them. That is exactly the shape
//! T733 recorded on 2026-08-11 — a `-Dtest-filter=T64` run that exited 0 in
//! silence over a deliberately broken predicate the unfiltered lane caught at
//! once. `-Dtest-filter=VK_PACKET` over that same broken tree fails here today
//! instead of lying, which is the whole point: the caller does not have to know
//! zig's rule, only to be told when they missed it. Filter by a module or file
//! segment, and dump the binary's real test names with
//! `GHOZTTY_TEST_FILTER_DUMP=1` when a filter surprises you.
//!
//! The limit to hold on to: this guard answers "did anything match", not "did
//! what you MEANT match". `-Dtest-filter=T64` is green today because
//! `apprt.win32.viewer_bridge.test.T641: …` matches it — a different test
//! entirely from the four the caller had in mind. Nothing can close that gap
//! from here; the dump is how you check.

const TestFilterGuard = @This();

const std = @import("std");
const Step = std.Build.Step;

/// The most test binaries one top-level step is expected to carry. Sized well
/// above today's largest (`test` has two) so `add` never has to grow; it
/// asserts rather than silently dropping a run, because a dropped run is a
/// guard that quietly weakens.
pub const max_runs = 16;

step: Step,

/// The label used in the diagnostic — the top-level step's name (`test`,
/// `test-agent`, …), which is what the caller typed.
label: []const u8,

/// The `-Dtest-filter` values this build was invoked with. Non-empty; the
/// guard is not created otherwise.
filters: []const []const u8,

/// The test runs this verdict covers.
runs: []const *Step.Run,

/// What one guarded run reported once the build has executed it.
pub const Observation = struct {
    /// The run reported no test metadata — a cache hit, or a run that never
    /// got as far as announcing its tests. Its zero says nothing.
    unknown: bool = false,
    /// Tests in that binary whose name matched at least one filter.
    matched: u32 = 0,
};

pub const Verdict = enum {
    /// At least one test somewhere under this step matched the filters.
    ok,
    /// Nothing matched, but no run could answer — so the question is not
    /// answered, and the build is not failed over it.
    indeterminate,
    /// At least one run answered, and across all of them zero tests matched.
    /// This is the failure the guard exists for.
    matched_nothing,
};

/// True when zig's own compile-time filter would have kept `name`: a filter is
/// a plain substring of the fully-qualified test name (`<module>.test.<name>`).
pub fn nameMatches(name: []const u8, filters: []const []const u8) bool {
    for (filters) |f| {
        if (std.mem.indexOf(u8, name, f) != null) return true;
    }
    return false;
}

/// The pure decision. Kept separate from the step so the rule is asserted in
/// the unit lane on every seat, including ones that never run a filtered build.
pub fn verdict(observations: []const Observation) Verdict {
    var any_answered = false;
    for (observations) |o| {
        if (o.matched > 0) return .ok;
        if (!o.unknown) any_answered = true;
    }
    return if (any_answered) .matched_nothing else .indeterminate;
}

/// Gathers the test runs of one top-level step, then attaches the guard.
///
/// Usage is add-as-you-wire, attach-once at the end:
///
/// ```zig
/// var guard: TestFilterGuard.Collector = .init(b, "test", test_filters);
/// guard.add(test_run);
/// guard.attach(test_step);
/// ```
pub const Collector = struct {
    b: *std.Build,
    label: []const u8,
    filters: []const []const u8,
    buf: [max_runs]*Step.Run = undefined,
    len: usize = 0,

    pub fn init(
        b: *std.Build,
        label: []const u8,
        filters: []const []const u8,
    ) Collector {
        return .{ .b = b, .label = label, .filters = filters };
    }

    /// Register one test run under this step. A no-op when the build carries
    /// no filters, so the unfiltered lane keeps its caching untouched.
    pub fn add(self: *Collector, run: *Step.Run) void {
        if (self.filters.len == 0) return;
        std.debug.assert(self.len < max_runs);

        // A cache hit reports no test metadata, and would be indistinguishable
        // from a filter that matched nothing. Under a filter the run is the
        // whole point of the invocation, so take the caching off it rather
        // than teach the verdict to shrug.
        run.has_side_effects = true;

        self.buf[self.len] = run;
        self.len += 1;
    }

    /// Create the guard step and make `step` depend on it. Does nothing when
    /// the build carries no filters or nothing was registered.
    pub fn attach(self: *Collector, step: *Step) void {
        if (self.filters.len == 0 or self.len == 0) return;

        const b = self.b;
        const guard = b.allocator.create(TestFilterGuard) catch @panic("OOM");
        const runs = b.allocator.dupe(*Step.Run, self.buf[0..self.len]) catch @panic("OOM");

        guard.* = .{
            .step = Step.init(.{
                .id = .custom,
                .name = b.fmt("test-filter guard ({s})", .{self.label}),
                .owner = b,
                .makeFn = make,
            }),
            .label = self.label,
            .filters = self.filters,
            .runs = runs,
        };

        for (runs) |run| guard.step.dependOn(&run.step);
        step.dependOn(&guard.step);
    }
};

/// `GHOZTTY_TEST_FILTER_DUMP=1` prints every test name the guarded binaries
/// actually contain, one per line, before the verdict (T733).
///
/// This is the tool that answers the only question a matched-nothing failure
/// leaves open — *what would have matched?* — and it is here rather than in a
/// script because the names live in the run's test metadata and nowhere on
/// disk. It was worth building: it is what established that under
/// `-Dtest-filter=VK_PACKET` the win32 binary contains ZERO named tests, even
/// though `apprt.win32.translate_policy.test.T64: VK_PACKET is translated even
/// on a terminal surface` is a test the unfiltered lane runs and prints under
/// exactly that name. Read `docs/claude/testing.md` before concluding anything
/// from a filter you wrote out of a failure message.
fn dumpNames() bool {
    return std.process.hasEnvVarConstant("GHOZTTY_TEST_FILTER_DUMP");
}

fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
    _ = options;
    const self: *TestFilterGuard = @fieldParentPtr("step", step);
    const b = step.owner;
    const dump_names = dumpNames();

    var observations: [max_runs]Observation = undefined;
    for (self.runs, 0..) |run, i| {
        const meta = run.cached_test_metadata orelse {
            observations[i] = .{ .unknown = true };
            continue;
        };
        var matched: u32 = 0;
        for (0..meta.names.len) |n| {
            if (dump_names) {
                std.debug.print("test-filter: {s}\n", .{meta.testName(@intCast(n))});
            }
            if (nameMatches(meta.testName(@intCast(n)), self.filters)) matched += 1;
        }
        observations[i] = .{ .matched = matched };
    }

    switch (verdict(observations[0..self.runs.len])) {
        .ok, .indeterminate => return,
        .matched_nothing => {},
    }

    var joined: std.ArrayList(u8) = .empty;
    for (self.filters, 0..) |f, i| {
        if (i > 0) try joined.appendSlice(b.allocator, ", ");
        try joined.appendSlice(b.allocator, f);
    }

    return step.fail(
        \\-Dtest-filter matched no tests, so `zig build {s}` proved nothing.
        \\  filters: {s}
        \\  {d} test binar{s} ran, and not one named test in them matched.
        \\A filtered run that matches nothing still exits 0 — the unnamed
        \\`test {{}}` aggregators are compiled in whatever the filter says — so
        \\it is indistinguishable from "matched and passed".
        \\The name a failure PRINTS is not reliably the string the compiler
        \\filtered on (T733): filter by the module or file segment
        \\(`-Dtest-filter=translate_policy`) rather than by the words of the
        \\test's own title. `GHOZTTY_TEST_FILTER_DUMP=1` lists the test names
        \\the binaries really contain. Or drop the filter and run the lane.
    , .{
        self.label,
        joined.items,
        self.runs.len,
        if (self.runs.len == 1) "y" else "ies",
    });
}

test "nameMatches: a filter is a substring of the qualified name" {
    const testing = std.testing;
    try testing.expect(nameMatches(
        "apprt.win32.gui_pump.test.pump runs the hook",
        &.{"pump"},
    ));
    try testing.expect(!nameMatches(
        "apprt.win32.gui_pump.test.pump runs the hook",
        &.{"zzz_nonexistent"},
    ));
    // Any one of several filters is enough, the way zig's own filter works.
    try testing.expect(nameMatches(
        "terminal.screen.test.resize",
        &.{ "zzz", "resize" },
    ));
    try testing.expect(!nameMatches("terminal.screen.test.resize", &.{}));
}

test "verdict: a run with a match is ok" {
    const testing = std.testing;
    try testing.expectEqual(Verdict.ok, verdict(&.{.{ .matched = 3 }}));
}

test "verdict: one binary matching is enough for a multi-binary step" {
    const testing = std.testing;
    // `zig build test` runs the main binary plus the build helpers; a real
    // filter routinely matches in exactly one of them.
    try testing.expectEqual(Verdict.ok, verdict(&.{
        .{ .matched = 0 },
        .{ .matched = 7 },
    }));
}

test "verdict: every binary answered and nothing matched" {
    const testing = std.testing;
    try testing.expectEqual(Verdict.matched_nothing, verdict(&.{
        .{ .matched = 0 },
        .{ .matched = 0 },
    }));
}

test "verdict: a run that could not answer is not evidence of nothing" {
    const testing = std.testing;
    try testing.expectEqual(Verdict.indeterminate, verdict(&.{
        .{ .unknown = true },
    }));
    try testing.expectEqual(Verdict.indeterminate, verdict(&.{}));
    // …but one binary that DID answer still decides for the step.
    try testing.expectEqual(Verdict.matched_nothing, verdict(&.{
        .{ .unknown = true },
        .{ .matched = 0 },
    }));
}
