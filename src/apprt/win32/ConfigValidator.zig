//! Checks config lines with Ghostty's own parser before the Settings window
//! writes them, so an invalid value is reported on its row and never lands
//! in the file (T2664; the win32 port of Mac `ConfigValidator` in
//! `ConfigSchema.swift`, 92103f39d).
//!
//! Mac writes the lines to a temp file and loads it into a scratch default
//! config through `ghostty_config_load_file`, then reads the diagnostics.
//! Here the same parser runs in memory: the lines feed `cli.args.LineIterator`
//! — the iterator `Config.loadFile` itself reads a file through — into
//! `Config.loadIter` on a scratch `Config.default`. Same parser, same
//! diagnostics, with no temp file to create or clean up. Like Mac's, the
//! scratch load stops at parsing: it never follows `config-file` includes or
//! finalizes, so a value is judged on its own line.
//!
//! A diagnostic's `message` is what the row shows: Mac's `clean` strips the
//! `<path>:<line>:<key>:` prefix from the formatted diagnostic to reach the
//! same text, e.g. `invalid value "abc"`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("../../config.zig").Config;
const cli = @import("../../cli.zig");

/// Ghostty's diagnostics for `lines` (e.g. `"font-size = abc"`), in order.
/// An empty result means every line parses. Caller frees each message and
/// the slice (`freeProblems`).
pub fn problems(alloc: Allocator, lines: []const []const u8) Allocator.Error![][]u8 {
    const joined = try joinLines(alloc, lines);
    defer alloc.free(joined);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var reader: std.Io.Reader = .fixed(joined);
    var iter: cli.args.LineIterator = .{ .r = &reader, .filepath = "settings" };
    cfg.loadIter(alloc, &iter) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A parse that cannot continue at all still means "not saved".
        else => return single(alloc, @errorName(err)),
    };

    const diags = cfg._diagnostics.items();
    var out: std.ArrayListUnmanaged([]u8) = try .initCapacity(alloc, diags.len);
    errdefer {
        for (out.items) |m| alloc.free(m);
        out.deinit(alloc);
    }
    for (diags) |d| out.appendAssumeCapacity(try alloc.dupe(u8, d.message));
    return out.toOwnedSlice(alloc);
}

/// The first problem with `lines`, or null if Ghostty accepts them all.
/// Caller frees the result.
pub fn firstProblem(alloc: Allocator, lines: []const []const u8) Allocator.Error!?[]u8 {
    const all = try problems(alloc, lines);
    defer alloc.free(all);
    if (all.len == 0) return null;
    for (all[1..]) |m| alloc.free(m);
    return all[0];
}

pub fn freeProblems(alloc: Allocator, list: [][]u8) void {
    for (list) |m| alloc.free(m);
    alloc.free(list);
}

fn joinLines(alloc: Allocator, lines: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (lines) |line| {
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

fn single(alloc: Allocator, msg: []const u8) Allocator.Error![][]u8 {
    const list = try alloc.alloc([]u8, 1);
    errdefer alloc.free(list);
    list[0] = try alloc.dupe(u8, msg);
    return list;
}

// Tests: a port of Mac `validatorUsesGhosttysParser`, plus the shapes the
// Settings rows feed it.

const testing = std.testing;

fn expectProblem(lines: []const []const u8, expected: ?[]const u8) !void {
    const got = try firstProblem(testing.allocator, lines);
    defer if (got) |g| testing.allocator.free(g);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(e, got.?);
    } else {
        if (got) |g| std.debug.print("unexpected problem: {s}\n", .{g});
        try testing.expect(got == null);
    }
}

test "ConfigValidator: uses Ghostty's own parser" {
    try expectProblem(&.{"font-size = 14"}, null);
    try expectProblem(&.{"font-size = abc"}, "invalid value \"abc\"");
    const got = (try firstProblem(testing.allocator, &.{"cursor-style = wiggle"})).?;
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "invalid value \"wiggle\""));
}

test "ConfigValidator: every line is checked, and each problem is reported in order" {
    const list = try problems(testing.allocator, &.{ "font-size = 12", "font-size = huge", "cursor-style = wiggle" });
    defer freeProblems(testing.allocator, list);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("invalid value \"huge\"", list[0]);
    try testing.expect(std.mem.startsWith(u8, list[1], "invalid value \"wiggle\""));
}

test "ConfigValidator: repeatable and keyed values" {
    try expectProblem(&.{ "font-feature = -calt", "font-feature = ss01" }, null);
    try expectProblem(&.{"shell-integration-features = cursor,no-sudo,title"}, null);
    try expectProblem(&.{"keybind = ctrl+k=new_tab"}, null);
    const got = (try firstProblem(testing.allocator, &.{"keybind = ctrl+j=not_an_action"})).?;
    testing.allocator.free(got);
}

test "ConfigValidator: an unknown key is a problem, not a silent pass" {
    const got = (try firstProblem(testing.allocator, &.{"no-such-key = 1"})).?;
    testing.allocator.free(got);
}

test "ConfigValidator: a quoted value Settings renders is read as Ghostty reads it" {
    try expectProblem(&.{"font-family = \" Iosevka \""}, null);
    try expectProblem(&.{"window-title-font-family = \"\""}, null);
}

test "ConfigValidator: no lines, no problems" {
    try expectProblem(&.{}, null);
}
