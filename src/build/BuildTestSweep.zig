//! T736 — the sweep that makes `build_test.zig` enforced rather than remembered.
//!
//! The main test binary roots at `src/main.zig` and reaches none of
//! `src/build/`, so a `test` block written next to a build helper runs in no
//! step at all. `build_test.zig` is the aggregator that fixes that — but only
//! for the files somebody remembered to add to it. Orphaned assertions are
//! worse than no assertions: they read as coverage in review and cannot fail.
//! `wasm_patch_growable_table.zig` sat orphaned for a month exactly that way,
//! and `TestFilterGuard.zig` was wired in correctly only because that turn
//! happened to think of it.
//!
//! So this sweep answers the question instead of trusting the habit: walk
//! `src/build/`, find every file carrying a top-level `test` block, and check
//! it is reachable from `build_test.zig` through sibling `@import`s. Anything
//! that is not is reported by name, and `build.zig` hangs a failing step off
//! `test_step` for it — the lane goes red on the orphan, not on some later day
//! when the untested code breaks.
//!
//! **The escape hatch names itself.** A helper whose tests genuinely cannot run
//! under the aggregator's module root (it needs a non-baseline target, or it
//! imports outside `src/build/`) declares so in its own doc comment:
//!
//!     //! build-test-exempt: needs a wasm target, run by <step>
//!
//! which satisfies the sweep and leaves the reason where the next reader is.
//! "Named with a reason" is the outcome the card asked for; silence is not.
//!
//! Everything here is std-only and the parsing half is pure, so it is asserted
//! by the aggregator it polices.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The aggregator every file under `src/build/` must be reachable from.
pub const aggregator = "build_test.zig";

/// The marker a file uses to declare itself deliberately outside the
/// aggregator. Everything after it on the line is the reason.
pub const exempt_marker = "build-test-exempt:";

/// A file that carries `test` blocks no step imports.
pub const Orphan = struct {
    /// Path relative to `src/build/`, with `/` separators.
    path: []const u8,
};

/// True when `src` has a top-level `test` block — `test "name" {` or a bare
/// `test {`. Top-level means column zero: a `test` nested inside a struct is
/// indented, and a `test` inside a string or comment is not at the margin.
pub fn hasTopLevelTest(src: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "test")) continue;
        const rest = line["test".len..];
        if (rest.len == 0) continue;
        switch (rest[0]) {
            ' ', '\t', '{', '"' => return true,
            else => {},
        }
    }
    return false;
}

/// The reason a file gives for being outside the aggregator, or null if it
/// gives none. Trailing whitespace (including a CR) is trimmed.
pub fn exemptReason(src: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, src, exempt_marker) orelse return null;
    const after = src[at + exempt_marker.len ..];
    const end = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
    const reason = std.mem.trim(u8, after[0..end], " \t\r");
    return if (reason.len == 0) null else reason;
}

/// Collect the `.zig` paths `src` imports, ignoring anything that leaves the
/// directory tree we are sweeping (`../…`) and anything that is not a path
/// (`std`, `builtin`, `build_options`). Results borrow from `src`.
pub fn collectImports(
    alloc: Allocator,
    src: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const needle = "@import(\"";
    var rest = src;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        const start = at + needle.len;
        rest = rest[start..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const path = rest[0..end];
        rest = rest[end..];
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        if (std.mem.startsWith(u8, path, "..")) continue;
        try out.append(alloc, path);
    }
}

/// Resolve `import` as written inside `from` (a path relative to the sweep
/// root) into a path relative to that same root. Caller owns the result.
pub fn resolveImport(
    alloc: Allocator,
    from: []const u8,
    import: []const u8,
) ![]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, from, '/') orelse
        return alloc.dupe(u8, import);
    return std.mem.concat(alloc, u8, &.{ from[0 .. slash + 1], import });
}

/// Walk `dir` (the `src/build/` tree) and return every file that carries a
/// top-level `test` block, is not reachable from `build_test.zig`, and does not
/// declare itself exempt. Caller owns the result and its paths.
pub fn sweep(alloc: Allocator, dir: std.fs.Dir) ![]Orphan {
    // Read every .zig file under the tree once, keyed by its relative path.
    var sources: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const rel = try normalizeSeparators(alloc, entry.path);
        const src = try dir.readFileAlloc(alloc, entry.path, 4 * 1024 * 1024);
        try sources.put(alloc, rel, src);
    }

    // Everything reachable from the aggregator through sibling imports is
    // covered; so is the aggregator itself.
    var covered: std.StringArrayHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    if (sources.get(aggregator) != null) {
        try covered.put(alloc, aggregator, {});
        try queue.append(alloc, aggregator);
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const path = queue.items[head];
        const src = sources.get(path) orelse continue;
        var imports: std.ArrayList([]const u8) = .empty;
        defer imports.deinit(alloc);
        try collectImports(alloc, src, &imports);
        for (imports.items) |import| {
            const resolved = try resolveImport(alloc, path, import);
            if (sources.get(resolved) == null) continue;
            if (covered.contains(resolved)) continue;
            try covered.put(alloc, resolved, {});
            try queue.append(alloc, resolved);
        }
    }

    var orphans: std.ArrayList(Orphan) = .empty;
    for (sources.keys(), sources.values()) |path, src| {
        if (covered.contains(path)) continue;
        if (!hasTopLevelTest(src)) continue;
        if (exemptReason(src) != null) continue;
        try orphans.append(alloc, .{ .path = path });
    }
    std.mem.sort(Orphan, orphans.items, {}, struct {
        fn lessThan(_: void, a: Orphan, b: Orphan) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    return orphans.toOwnedSlice(alloc);
}

/// The message `build.zig` fails the test step with. Written for whoever hits
/// it: what is wrong, and both ways out of it.
pub fn failureMessage(alloc: Allocator, orphans: []const Orphan) ![]const u8 {
    var msg: std.ArrayList(u8) = .empty;
    const w = msg.writer(alloc);
    try w.print(
        "src/build/: {d} file(s) carry `test` blocks that no build step runs.\n" ++
            "Orphaned assertions read as coverage in review and cannot fail.\n",
        .{orphans.len},
    );
    for (orphans) |orphan| try w.print("  {s}\n", .{orphan.path});
    try w.print(
        "Fix: add `_ = @import(\"<path>\");` to src/build/{s},\n" ++
            "or, if its tests genuinely cannot run there, say why in its doc\n" ++
            "comment: `//! {s} <reason>`.\n",
        .{ aggregator, exempt_marker },
    );
    return msg.toOwnedSlice(alloc);
}

fn normalizeSeparators(alloc: Allocator, path: []const u8) ![]const u8 {
    const out = try alloc.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

test "hasTopLevelTest finds a named block" {
    try std.testing.expect(hasTopLevelTest("const a = 1;\ntest \"x\" {\n}\n"));
}

test "hasTopLevelTest finds a bare block" {
    try std.testing.expect(hasTopLevelTest("test {\n    _ = @import(\"a.zig\");\n}\n"));
}

test "hasTopLevelTest ignores indented and word-prefixed matches" {
    try std.testing.expect(!hasTopLevelTest("    test \"nested\" {}\n"));
    try std.testing.expect(!hasTopLevelTest("testing.expect(x);\n"));
    try std.testing.expect(!hasTopLevelTest("const tested = 1;\n"));
}

test "exemptReason reads the marker and nothing else" {
    try std.testing.expectEqualStrings(
        "needs a wasm target",
        exemptReason("//! build-test-exempt: needs a wasm target\nconst x = 1;\n").?,
    );
    try std.testing.expect(exemptReason("//! ordinary doc comment\n") == null);
    try std.testing.expect(exemptReason("//! build-test-exempt:   \n") == null);
}

test "collectImports keeps sibling zig paths only" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(alloc);
    try collectImports(alloc,
        \\const std = @import("std");
        \\const a = @import("drive_check.zig");
        \\const b = @import("framegen/gen.zig");
        \\const c = @import("../os/path.zig");
        \\const d = @import("build_options");
    , &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("drive_check.zig", out.items[0]);
    try std.testing.expectEqualStrings("framegen/gen.zig", out.items[1]);
}

test "resolveImport is relative to the importing file" {
    const alloc = std.testing.allocator;
    const top = try resolveImport(alloc, "build_test.zig", "drive_check.zig");
    defer alloc.free(top);
    try std.testing.expectEqualStrings("drive_check.zig", top);

    const nested = try resolveImport(alloc, "framegen/main.zig", "gen.zig");
    defer alloc.free(nested);
    try std.testing.expectEqualStrings("framegen/gen.zig", nested);
}

test "failureMessage names each orphan and both remedies" {
    const alloc = std.testing.allocator;
    const msg = try failureMessage(alloc, &.{.{ .path = "orphan.zig" }});
    defer alloc.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "orphan.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, aggregator) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, exempt_marker) != null);
}

test "sweep reports an orphan, and nothing once it is wired in" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = aggregator,
        .data = "test {\n    _ = @import(\"wired.zig\");\n}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "wired.zig",
        .data = "test \"wired\" {}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "orphan.zig",
        .data = "test \"orphan\" {}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "no_tests.zig",
        .data = "const x = 1;\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "excused.zig",
        .data = "//! build-test-exempt: needs a wasm target\ntest \"excused\" {}\n",
    });

    {
        const orphans = try sweep(arena.allocator(), tmp.dir);
        try std.testing.expectEqual(@as(usize, 1), orphans.len);
        try std.testing.expectEqualStrings("orphan.zig", orphans[0].path);
    }

    try tmp.dir.writeFile(.{
        .sub_path = aggregator,
        .data = "test {\n    _ = @import(\"wired.zig\");\n    _ = @import(\"orphan.zig\");\n}\n",
    });
    {
        const orphans = try sweep(arena.allocator(), tmp.dir);
        try std.testing.expectEqual(@as(usize, 0), orphans.len);
    }
}

test "sweep follows imports transitively and into subdirectories" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makeDir("nested");
    try tmp.dir.writeFile(.{
        .sub_path = aggregator,
        .data = "test {\n    _ = @import(\"nested/mid.zig\");\n}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "nested/mid.zig",
        .data = "const leaf = @import(\"leaf.zig\");\ntest \"mid\" {}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "nested/leaf.zig",
        .data = "test \"leaf\" {}\n",
    });

    const orphans = try sweep(arena.allocator(), tmp.dir);
    try std.testing.expectEqual(@as(usize, 0), orphans.len);
}
