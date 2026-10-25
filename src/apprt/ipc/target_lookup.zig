//! Which open window or pane a `--target`/`--name` means (T2250; the Mac's
//! `TargetLookup.swift`, main 71da9a680).
//!
//! Pane names belong to the window they were created in. They used to be one
//! namespace across every window, and that was the main way agents reported a
//! side pane that never opened: session A's `+split --name=draft` and session
//! B's same command, in another window, collided - B got exit 0 and "reused"
//! A's pane, in A's window, and a later `+close --target=draft` from B closed
//! it. Now two windows can each hold a pane called `draft`, and a name is
//! looked up in the CALLER's window first (the request's `caller_pane`, the
//! CLI's `$GHOZTTY_PANE_ID`).
//!
//! The order, for one name:
//!
//!   1. A pane of that name in the caller's window.
//!   2. A window of that name. Window names stay global and unique.
//!   3. A pane of that name in any other window - but only if exactly one
//!      window has one. Two or more is AMBIGUOUS, and the command fails
//!      naming the windows rather than pick one: picking would be acting on
//!      some other agent's pane at random.
//!
//! A caller with no pane (a plain shell, a `ghoztty://focus/` link) starts at
//! step 2. Pane ids never get here: an id names exactly one pane.
//!
//! Pure, so the policy and the wording are tested without windows.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Candidate = struct {
    kind: Kind,
    /// The name of the window the candidate is (`.window`) or is in.
    window_name: []const u8,
    /// Whether that window is the caller's.
    in_caller_window: bool = false,

    pub const Kind = enum { window, pane };
};

pub const Pick = union(enum) {
    /// `candidates[index]` is what the name means.
    found: usize,
    /// Panes in several windows hold the name and none is the caller's.
    /// Their window names, sorted; allocated from the `pick` allocator.
    ambiguous: []const []const u8,
    not_found,
};

pub fn pick(alloc: Allocator, candidates: []const Candidate) Allocator.Error!Pick {
    for (candidates, 0..) |c, i| {
        if (c.kind == .pane and c.in_caller_window) return .{ .found = i };
    }
    for (candidates, 0..) |c, i| {
        if (c.kind == .window) return .{ .found = i };
    }
    var panes: usize = 0;
    var only: usize = 0;
    for (candidates, 0..) |c, i| {
        if (c.kind != .pane) continue;
        panes += 1;
        only = i;
    }
    switch (panes) {
        0 => return .not_found,
        1 => return .{ .found = only },
        else => {},
    }
    const windows = try alloc.alloc([]const u8, panes);
    var n: usize = 0;
    for (candidates) |c| {
        if (c.kind != .pane) continue;
        windows[n] = c.window_name;
        n += 1;
    }
    std.mem.sort([]const u8, windows, {}, lessThan);
    return .{ .ambiguous = windows };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// What a command says when its name is ambiguous. The Mac's wording,
/// character for character.
pub fn ambiguityError(alloc: Allocator, name: []const u8, windows: []const []const u8) Allocator.Error![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(alloc);
    for (windows, 0..) |w, i| {
        if (i > 0) try list.appendSlice(alloc, ", ");
        try list.append(alloc, '\'');
        try list.appendSlice(alloc, w);
        try list.append(alloc, '\'');
    }
    return std.fmt.allocPrint(
        alloc,
        "'{s}' names a pane in {d} windows ({s}), so it is ambiguous here. " ++
            "Run the command from a pane in the window you mean, or target the pane by its id " ++
            "(`id` in `ghoztty +list --json`).",
        .{ name, windows.len, list.items },
    );
}

// The cases below are the Mac's `TargetLookupTests`.

const testing = std.testing;

fn pane(in_window: []const u8, mine: bool) Candidate {
    return .{ .kind = .pane, .window_name = in_window, .in_caller_window = mine };
}

fn window(name: []const u8) Candidate {
    return .{ .kind = .window, .window_name = name };
}

fn expectFound(want: usize, candidates: []const Candidate) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(Pick{ .found = want }, try pick(arena.allocator(), candidates));
}

test "target_lookup: two windows each hold the name; the caller's own pane wins" {
    try expectFound(1, &.{ pane("a", false), pane("b", true) });
}

test "target_lookup: a window of that name comes before panes elsewhere" {
    try expectFound(1, &.{ pane("a", false), window("draft") });
    try expectFound(1, &.{ window("draft"), pane("b", true) });
}

test "target_lookup: a pane only one other window holds is found" {
    // "This window first", not "this window only": an orchestrator typing
    // into a worker still reaches it.
    try expectFound(0, &.{pane("a", false)});
}

test "target_lookup: panes in several other windows are ambiguous, named and sorted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try pick(arena.allocator(), &.{ pane("b", false), pane("a", false) });
    try testing.expectEqual(@as(usize, 2), got.ambiguous.len);
    try testing.expectEqualStrings("a", got.ambiguous[0]);
    try testing.expectEqualStrings("b", got.ambiguous[1]);

    const msg = try ambiguityError(arena.allocator(), "draft", got.ambiguous);
    try testing.expectEqualStrings(
        "'draft' names a pane in 2 windows ('a', 'b'), so it is ambiguous here. " ++
            "Run the command from a pane in the window you mean, or target the pane by its id " ++
            "(`id` in `ghoztty +list --json`).",
        msg,
    );
}

test "target_lookup: nothing is not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(Pick.not_found, try pick(arena.allocator(), &.{}));
}
