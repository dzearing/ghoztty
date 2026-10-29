//! A window dragged into or out of a project group in the all-windows list
//! (T2338; Mac 379a352ef, `PaneSidebarCrossDrop`).
//!
//! A window drag does not move among its siblings only (T2337's group drag
//! still does): it reads the whole list as one run of rows - each group's
//! header, then its windows (every window folded to its row while one is
//! dragged), and the lone windows between - and every row slides on its own,
//! a group's header apart from its windows. Where it is let go says where it
//! lands:
//!
//! - right under a header, or between two of a group's windows: it joins
//!   that group;
//! - just past a group's last window (or a folded group's header): the upper
//!   half of that slot joins the group's end, the lower half lands after the
//!   group, at the top level;
//! - anywhere else: the top level.
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
/// it left - with its top at `top` (Mac `destination(rows:slot:top:)`).
pub fn destination(rows: []const Row, slot_in: usize, top: i32) Destination {
    const slot = @min(slot_in, rows.len);
    const before = rows[0..slot];
    var top_count: usize = 0;
    for (before) |r| {
        if (r.header or r.project == null) top_count += 1;
    }
    const top_level: Destination = .{ .top_level = top_count };
    if (before.len == 0) return top_level;
    const prev = before[before.len - 1];
    const project = prev.project orelse return top_level;
    var in_group: usize = 0;
    for (before) |r| {
        if (!r.header and sameProject(r.project, project)) in_group += 1;
    }
    const join: Destination = .{ .group = .{ .project = project, .index = in_group } };
    if (slot < rows.len) {
        const next = rows[slot];
        if (!next.header and sameProject(next.project, project)) return join;
    }
    // The slot runs from that last row's top to its bottom (and the list's
    // end clamps it there): split at its middle.
    return if (2 * top < prev.mid2()) join else top_level;
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
    return .{ .slot = slot, .dest = destination(others[0..n], slot, top) };
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
    try expectDest(.{ .top_level = 0 }, destination(&sample, 0, 0));
    try expectDest(.{ .group = .{ .project = "p", .index = 0 } }, destination(&sample, 2, 64));
    try expectDest(.{ .group = .{ .project = "p", .index = 1 } }, destination(&sample, 3, 96));
    // Between two lone items: the top level.
    try expectDest(.{ .top_level = 1 }, destination(&sample, 1, 32));
}

test "T2338: past a group's last window the slot is split in half" {
    // After p2 (96..128), before b (128): the upper half joins p's end, the
    // lower half lands after the group, at the top level.
    try expectDest(.{ .group = .{ .project = "p", .index = 2 } }, destination(&sample, 4, 100));
    try expectDest(.{ .top_level = 2 }, destination(&sample, 4, 120));
    // Past a folded group's header, at the end of the list: the same.
    try expectDest(.{ .group = .{ .project = "q", .index = 0 } }, destination(&sample, 6, 165));
    try expectDest(.{ .top_level = 4 }, destination(&sample, 6, 190));
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
    // At the end (top 192, below [q]'s middle): after the folded group.
    const end = resolve(&rows, 0, 32, 192);
    try testing.expectEqual(@as(usize, 6), end.slot);
    try expectDest(.{ .top_level = 4 }, end.dest);
}

test "T2338: a group's last window joins its group only in the upper half of the slot" {
    // [p] p1 p2, then lone b. p2 (64..96) dragged; without it b closes up
    // to 64..96. The slot after p1 holds tops 32..64 (its middle past p1's
    // 48, short of b's 80): above 48 it stays in p, below it it lands after
    // the group, before b. Past b's middle it lands after b.
    const rows = [_]Row{
        .{ .project = "p", .header = true, .span = .{ .top = 0, .bottom = 32 } },
        .{ .project = "p", .header = false, .span = .{ .top = 32, .bottom = 64 } },
        .{ .project = "p", .header = false, .span = .{ .top = 64, .bottom = 96 } },
        .{ .project = null, .header = false, .span = .{ .top = 96, .bottom = 128 } },
    };
    try expectDest(.{ .group = .{ .project = "p", .index = 1 } }, resolve(&rows, 2, 32, 40).dest);
    try expectDest(.{ .top_level = 1 }, resolve(&rows, 2, 32, 60).dest);
    try expectDest(.{ .top_level = 2 }, resolve(&rows, 2, 32, 84).dest);
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

