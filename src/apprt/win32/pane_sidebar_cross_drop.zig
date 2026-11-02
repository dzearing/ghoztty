//! A window dragged into or out of a project group in the all-windows list
//! (T2338; Mac 379a352ef, `PaneSidebarCrossDrop`).
//!
//! A window drag does not move among its siblings only (T2337's group drag
//! still does): it reads the whole list as one run of rows - each group's
//! header, then its windows (every window folded to its row while one is
//! dragged), the lone windows ahead of them all (T2421) - and every row
//! slides on its own,
//! a group's header apart from its windows. Where it is let go says where it
//! lands:
//!
//! - right under a header, between two of a group's windows, or anywhere
//!   past a group's end (its last window, or a folded group's header): it is
//!   in that group (T2526, Mac 0100ae3db);
//! - up among the lone windows, which lead the list - or above the first
//!   group when there are none: the top level.
//!
//! The slot just past a group's end was once split at its middle, the lower
//! half landing after the group at the top level - which, the lone windows
//! leading the list, was a jump up among them that nobody dragged to, and a
//! group's last window, grabbed, started in that lower half and wanted out
//! at once.
//!
//! Dropped in another group it is renamed `<project>: <name>`; dropped out of
//! one, just `<name>` (`pane_sidebar_rename.groupTitle`).
//!
//! A renamed group keeping its place is a rename rule, not a drop:
//! `pane_sidebar_window_order.renamingProject` (T2405).
//!
//! Pure, so its tests run in every lane.

const std = @import("std");
const window_order = @import("pane_sidebar_window_order.zig");

const Span = window_order.Span;

pub const max_rows: usize = window_order.max_keys;

/// One row of the list, as laid out before any slide.
pub const Row = struct {
    /// The group it is in, or that it heads; null for a lone window.
    project: ?[]const u8,
    header: bool,
    span: Span,

    fn mid2(self: Row) i32 {
        return self.span.top + self.span.bottom;
    }
};

pub const Destination = union(enum) {
    /// Into `project`'s windows at `index` (among them, without it).
    group: struct { project: []const u8, index: usize },
    /// At this index of the top level (groups and lone windows, without it).
    top_level: usize,

    pub fn eql(a: Destination, b: Destination) bool {
        return switch (a) {
            .group => |g| switch (b) {
                .group => |h| g.index == h.index and std.mem.eql(u8, g.project, h.project),
                .top_level => false,
            },
            .top_level => |i| switch (b) {
                .group => false,
                .top_level => |j| i == j,
            },
        };
    }

    /// The group it lands in, or null at the top level.
    pub fn project(self: Destination) ?[]const u8 {
        return switch (self) {
            .group => |g| g.project,
            .top_level => null,
        };
    }
};

fn sameProject(a: ?[]const u8, b: ?[]const u8) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.mem.eql(u8, x, y);
}

/// Where it lands at `slot` of `rows` - the list without it, closed up where
/// it left (Mac `destination(rows:slot:)`): after any of a group's rows, in
/// that group; otherwise the top level.
pub fn destination(rows: []const Row, slot_in: usize) Destination {
    const slot = @min(slot_in, rows.len);
    const before = rows[0..slot];
    var top_count: usize = 0;
    for (before) |r| {
        if (r.header or r.project == null) top_count += 1;
    }
    const top_level: Destination = .{ .top_level = top_count };
    if (before.len == 0) return top_level;
    const project = before[before.len - 1].project orelse return top_level;
    var in_group: usize = 0;
    for (before) |r| {
        if (!r.header and sameProject(r.project, project)) in_group += 1;
    }
    return .{ .group = .{ .project = project, .index = in_group } };
}

/// A window drag's place for its top at `top`: the slot among the others -
/// `rows` without `source`, those after it closed up by `pitch` - its middle
/// has passed, and where that slot lands (Mac `relayoutRows`).
pub const Resolved = struct { slot: usize, dest: Destination };

pub fn resolve(rows: []const Row, source: usize, pitch: i32, top: i32) Resolved {
    if (source >= rows.len) return .{ .slot = 0, .dest = .{ .top_level = 0 } };
    var others: [max_rows]Row = undefined;
    var n: usize = 0;
    for (rows, 0..) |r, i| {
        if (i == source) continue;
        if (n == others.len) break;
        var o = r;
        if (i > source) {
            o.span.top -= pitch;
            o.span.bottom -= pitch;
        }
        others[n] = o;
        n += 1;
    }
    const h = rows[source].span.height();
    const middle2 = 2 * top + h;
    var slot: usize = 0;
    for (others[0..n]) |o| {
        if (o.mid2() < middle2) slot += 1;
    }
    // Held at the list's top edge it goes first, at its bottom edge last -
    // where `window_order.clamp` stops it. Read by the middle alone, a
    // window row taller than a project header (a pill against the header's
    // band) could never pass the first header's middle, or the last's.
    if (top <= rows[0].span.top) slot = 0;
    if (top + h >= rows[rows.len - 1].span.bottom) slot = n;
    return banded(destination(others[0..n], slot), slot, others[0..n]);
}

/// `dest` at `slot` of `rows` (the list without it), kept out of the groups'
/// band (T2421, Mac `PaneSidebarCrossDrop.banded`): a window let go at the
/// top level below a group lands at the end of the lone windows, which lead
/// the list - the slot there too, so the others open the gap where it will
/// land. Joining a group, or among the lone windows, it is as is.
pub fn banded(dest: Destination, slot: usize, rows: []const Row) Resolved {
    const index = switch (dest) {
        .top_level => |i| i,
        .group => return .{ .slot = slot, .dest = dest },
    };
    var lones: usize = 0;
    for (rows) |r| {
        if (r.project == null) lones += 1;
    }
    if (index <= lones) return .{ .slot = slot, .dest = dest };
    return .{ .slot = lones, .dest = .{ .top_level = lones } };
}

// ---------------------------------------------------------------------------
// Tests (Mac `PaneSidebarCrossDropTests`)

const testing = std.testing;
const rename_rules = @import("pane_sidebar_rename.zig");

/// lone `a`, then `[p]` with `p1` and `p2`, lone `b`, then folded `[q]`:
/// every row 32 high, the list without the dragged window.
const sample = blk: {
    const items = [_]struct { ?[]const u8, bool }{
        .{ null, false },
        .{ "p", true },
        .{ "p", false },
        .{ "p", false },
        .{ null, false },
        .{ "q", true },
    };
    var out: [items.len]Row = undefined;
    for (items, 0..) |it, i| {
        const y: i32 = @intCast(i * 32);
        out[i] = .{ .project = it[0], .header = it[1], .span = .{ .top = y, .bottom = y + 32 } };
    }
    break :blk out;
};

fn expectDest(want: Destination, got: Destination) !void {
    if (!want.eql(got)) {
        std.debug.print("want {any}, got {any}\n", .{ want, got });
        return error.TestExpectedEqual;
    }
}

test "T2338: under a header or between its windows it joins the group" {
    try expectDest(.{ .top_level = 0 }, destination(&sample, 0));
    try expectDest(.{ .group = .{ .project = "p", .index = 0 } }, destination(&sample, 2));
    try expectDest(.{ .group = .{ .project = "p", .index = 1 } }, destination(&sample, 3));
    // Between two lone items: the top level.
    try expectDest(.{ .top_level = 1 }, destination(&sample, 1));
}

test "T2526: past a group's last window it is still in the group" {
    // After p2, before b: p's end - the slot is no longer split in half.
    try expectDest(.{ .group = .{ .project = "p", .index = 2 } }, destination(&sample, 4));
    // Past a folded group's header, at the end of the list: the same.
    try expectDest(.{ .group = .{ .project = "q", .index = 0 } }, destination(&sample, 6));
}

test "T2526: past a group's end it stays in that group" {
    // Mac `pastAGroupsEndItStaysInThatGroup`. The report: a group's last
    // window, grabbed, wanted out of its group at once, and one dragged over
    // another group's end opened a gap among the ungrouped windows on top.
    // Lone a, b, then [p] with p1 (p2 dragged), then [q] with q1.
    const items = [_]struct { ?[]const u8, bool }{
        .{ null, false }, .{ null, false },
        .{ "p", true },   .{ "p", false },
        .{ "q", true },   .{ "q", false },
    };
    var rows: [items.len]Row = undefined;
    for (items, 0..) |it, i| {
        const y: i32 = @intCast(i * 32);
        rows[i] = .{ .project = it[0], .header = it[1], .span = .{ .top = y, .bottom = y + 32 } };
    }
    // p2 where it was grabbed: its top at p1's bottom.
    const grabbed = destination(&rows, 4);
    try expectDest(.{ .group = .{ .project = "p", .index = 1 } }, grabbed);
    const kept = banded(grabbed, 4, &rows);
    try testing.expectEqual(@as(usize, 4), kept.slot);
    try expectDest(.{ .group = .{ .project = "p", .index = 1 } }, kept.dest);
    // Past the list's end: q's end.
    try expectDest(.{ .group = .{ .project = "q", .index = 1 } }, destination(&rows, 6));
    // Up among the ungrouped windows: out of the group.
    try expectDest(.{ .top_level = 2 }, destination(&rows, 2));
    try expectDest(.{ .top_level = 0 }, destination(&rows, 0));
}

test "T2338: its name says which group it is in" {
    var b: [64]u8 = undefined;
    const d: Destination = .{ .group = .{ .project = "ghoztty", .index = 0 } };
    try testing.expectEqualStrings("ghoztty: main", rename_rules.groupTitle(&b, d.project() orelse "", "main"));
    const t: Destination = .{ .top_level = 3 };
    try testing.expectEqualStrings("main", rename_rules.groupTitle(&b, t.project() orelse "", "main"));
}

test "T2338: resolve closes the list up where the window left and reads its middle" {
    // A lone window (0..32) dragged from the front of `sample`, every row of
    // which sits 32 lower. Without it the others close up to `sample`'s
    // places: a 0..32, [p] 32..64, p1 64..96, p2 96..128, b, [q].
    var rows: [7]Row = undefined;
    rows[0] = .{ .project = null, .header = false, .span = .{ .top = 0, .bottom = 32 } };
    for (sample, 0..) |r, i| {
        var o = r;
        o.span.top += 32;
        o.span.bottom += 32;
        rows[i + 1] = o;
    }
    // Its middle at 56: past a's (16) and [p]'s (48), short of p1's (80) -
    // right under p's header, so it joins p first.
    const r = resolve(&rows, 0, 32, 40);
    try testing.expectEqual(@as(usize, 2), r.slot);
    try expectDest(.{ .group = .{ .project = "p", .index = 0 } }, r.dest);
    // Its middle at 88: between p1 and p2 - p at 1.
    try expectDest(.{ .group = .{ .project = "p", .index = 1 } }, resolve(&rows, 0, 32, 72).dest);
    // Held at the very top: the top level's front.
    const front = resolve(&rows, 0, 32, 0);
    try testing.expectEqual(@as(usize, 0), front.slot);
    try expectDest(.{ .top_level = 0 }, front.dest);
    // At the end (top 192, below [q]'s middle): past the folded group's
    // header, so in q (T2526), and the gap opens at the list's end.
    const end = resolve(&rows, 0, 32, 192);
    try testing.expectEqual(@as(usize, 6), end.slot);
    try expectDest(.{ .group = .{ .project = "q", .index = 0 } }, end.dest);
}

test "T2421: below a group it lands at the end of the ungrouped windows" {
    // Mac `belowAGroupItLandsAtTheEndOfTheUngroupedWindows`: lone a, b, then
    // [p] with p1.
    const rows = [_]Row{
        .{ .project = null, .header = false, .span = .{ .top = 0, .bottom = 32 } },
        .{ .project = null, .header = false, .span = .{ .top = 32, .bottom = 64 } },
        .{ .project = "p", .header = true, .span = .{ .top = 64, .bottom = 96 } },
        .{ .project = "p", .header = false, .span = .{ .top = 96, .bottom = 128 } },
    };
    const below = banded(.{ .top_level = 3 }, 4, &rows);
    try testing.expectEqual(@as(usize, 2), below.slot);
    try expectDest(.{ .top_level = 2 }, below.dest);
    // Among them: as is.
    const among = banded(.{ .top_level = 1 }, 1, &rows);
    try testing.expectEqual(@as(usize, 1), among.slot);
    try expectDest(.{ .top_level = 1 }, among.dest);
    // Joining: as is.
    const joining = banded(.{ .group = .{ .project = "p", .index = 1 } }, 4, &rows);
    try testing.expectEqual(@as(usize, 4), joining.slot);
    try expectDest(.{ .group = .{ .project = "p", .index = 1 } }, joining.dest);
}

test "T2526: a group's last window, grabbed, stays in its group" {
    // Lone b, then [p] p1 p2. p2 (96..128) dragged, the last row. Anywhere
    // past p1 it stays at p's end - the slot after p1 was once split at p1's
    // middle, and the lower half, where a grab starts, wanted out at once.
    // Out of p is up among the lone windows: its middle above [p]'s.
    const rows = [_]Row{
        .{ .project = null, .header = false, .span = .{ .top = 0, .bottom = 32 } },
        .{ .project = "p", .header = true, .span = .{ .top = 32, .bottom = 64 } },
        .{ .project = "p", .header = false, .span = .{ .top = 64, .bottom = 96 } },
        .{ .project = "p", .header = false, .span = .{ .top = 96, .bottom = 128 } },
    };
    try expectDest(.{ .group = .{ .project = "p", .index = 0 } }, resolve(&rows, 3, 32, 40).dest);
    try expectDest(.{ .group = .{ .project = "p", .index = 1 } }, resolve(&rows, 3, 32, 70).dest);
    const grabbed = resolve(&rows, 3, 32, 96);
    try testing.expectEqual(@as(usize, 3), grabbed.slot);
    try expectDest(.{ .group = .{ .project = "p", .index = 1 } }, grabbed.dest);
    try expectDest(.{ .group = .{ .project = "p", .index = 1 } }, resolve(&rows, 3, 32, 90).dest);
    const out = resolve(&rows, 3, 32, 8);
    try testing.expectEqual(@as(usize, 1), out.slot);
    try expectDest(.{ .top_level = 1 }, out.dest);
}

test "T2338: a window taller than a header still reaches either end of the list" {
    // [p] 0..32 (a header's band), lone b 40..80, then lone w 88..128 (a
    // window's pill, taller): w held at the top edge goes first, though its
    // middle (20) is below [p]'s (16).
    const rows = [_]Row{
        .{ .project = "p", .header = true, .span = .{ .top = 0, .bottom = 32 } },
        .{ .project = null, .header = false, .span = .{ .top = 40, .bottom = 80 } },
        .{ .project = null, .header = false, .span = .{ .top = 88, .bottom = 128 } },
    };
    const first = resolve(&rows, 2, 48, 0);
    try testing.expectEqual(@as(usize, 0), first.slot);
    try expectDest(.{ .top_level = 0 }, first.dest);
    // And [p] held at the bottom edge (top 96: 96 + 32 reaches 128) goes last.
    const last = resolve(&rows, 0, 40, 96);
    try testing.expectEqual(@as(usize, 2), last.slot);
    try expectDest(.{ .top_level = 2 }, last.dest);
}

