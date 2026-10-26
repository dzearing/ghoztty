//! The pane sidebar's own list order (T2302; Mac e77422577,
//! `PaneSidebarOrder` in `PaneSidebarState.swift`, `docs/design/pane-sidebar.md`
//! "Reordering").
//!
//! The sidebar lists a window's grid panes in an order of its OWN: dragging a
//! row up or down changes the list and never the grid. The order is a list of
//! stable pane ids (`$GHOZTTY_PANE_ID`), and it is read against the tree every
//! time rather than kept in step with it:
//!
//! - Until the first reorder the order is empty, which means the tree's order.
//! - A pane the order has never seen - a new split, a pane from another
//!   window - goes after its nearest tree neighbour the order knows (so a split
//!   appears beside the pane it came from), else before the next, else at the
//!   end.
//! - A pane not on show (stashed, or in another tab) keeps its place in the
//!   order, so restoring it brings it back to the same spot.
//! - Closed panes are pruned on the next move, and so never persisted.
//!
//! One order per WINDOW, as Mac's: a Mac window is a Windows tab, and pane ids
//! are unique across tabs, so one list covers every tab of a Windows window -
//! each tab's roster reads only its own panes out of it.
//!
//! Pure: ids in, indices or ids out, into caller buffers. No allocation.

const std = @import("std");
const pane_id = @import("pane_id.zig");

/// The most ids an order holds - every pane of every tab of one window.
pub const max_ids: usize = 256;

fn indexOf(ids: []const []const u8, id: []const u8) ?usize {
    for (ids, 0..) |x, i| if (pane_id.eql(x, id)) return i;
    return null;
}

/// `visible` - the grid's panes, in tree order - in the sidebar's order, as
/// indices into `visible` written to `out`. Returns how many (every visible
/// pane, up to `out.len`). Mac `PaneSidebarOrder.arranged`.
pub fn arranged(visible: []const []const u8, order: []const []const u8, out: []usize) usize {
    const n = @min(visible.len, out.len, max_ids);
    if (order.len == 0) {
        for (0..n) |i| out[i] = i;
        return n;
    }
    var known: [max_ids]bool = [_]bool{false} ** max_ids;
    var len: usize = 0;
    // The order's ids that are on show, in the order's sequence.
    for (order) |id| {
        const vi = indexOf(visible[0..n], id) orelse continue;
        if (known[vi]) continue;
        known[vi] = true;
        out[len] = vi;
        len += 1;
    }
    // Then each pane the order does not know, beside its tree neighbour.
    for (0..n) |vi| {
        if (known[vi]) continue;
        const at: usize = blk: {
            var before = vi;
            while (before > 0) {
                before -= 1;
                if (known[before]) break :blk posOf(out[0..len], before) + 1;
            }
            for (vi + 1..n) |after| {
                if (known[after]) break :blk posOf(out[0..len], after);
            }
            break :blk len;
        };
        std.mem.copyBackwards(usize, out[at + 1 .. len + 1], out[at..len]);
        out[at] = vi;
        len += 1;
        known[vi] = true;
    }
    return len;
}

fn posOf(list: []const usize, v: usize) usize {
    for (list, 0..) |x, i| if (x == v) return i;
    unreachable;
}

/// The order after moving `id` to `to` of the arranged list, which `id` must
/// be in (`visible`). Ids the order knows that are not on show (stashed panes,
/// other tabs' panes) keep their place after whatever preceded them; ids in
/// neither `visible` nor `existing` are dropped. The ids written to `out`
/// borrow the inputs' memory. Mac `PaneSidebarOrder.moving`.
pub fn moving(
    id: []const u8,
    to: usize,
    visible: []const []const u8,
    order: []const []const u8,
    existing: []const []const u8,
    out: [][]const u8,
) usize {
    // The arranged list without `id`, then `id` put back at `to`.
    var idx: [max_ids]usize = undefined;
    const n = arranged(visible, order, &idx);
    var list: [max_ids][]const u8 = undefined;
    var len: usize = 0;
    for (idx[0..n]) |vi| {
        if (pane_id.eql(visible[vi], id)) continue;
        list[len] = visible[vi];
        len += 1;
    }
    const at = @min(to, len);
    std.mem.copyBackwards([]const u8, list[at + 1 .. len + 1], list[at..len]);
    list[at] = id;
    len += 1;

    // Each pane not on show follows the on-show id it followed in the order
    // (null: none - it led the order). Not after the moved pane: the others
    // stay where they were.
    var followers: [max_ids][]const u8 = undefined;
    var follows: [max_ids]?usize = undefined;
    var nf: usize = 0;
    var previous: ?usize = null;
    for (order, 0..) |entry, oi| {
        if (indexOf(order[0..oi], entry) != null) continue;
        if (indexOf(list[0..len], entry)) |li| {
            if (!pane_id.eql(entry, id)) previous = li;
        } else if (indexOf(existing, entry) != null and nf < max_ids) {
            followers[nf] = entry;
            follows[nf] = previous;
            nf += 1;
        }
    }

    var w: usize = 0;
    for (0..nf) |f| if (follows[f] == null and w < out.len) {
        out[w] = followers[f];
        w += 1;
    };
    for (list[0..len], 0..) |entry, li| {
        if (w < out.len) {
            out[w] = entry;
            w += 1;
        }
        for (0..nf) |f| if (follows[f] == li and w < out.len) {
            out[w] = followers[f];
            w += 1;
        };
    }
    return w;
}

/// Where row `index` of a section is drawn while a drag is over the sidebar,
/// in rows (multiply by the row height): the dragged row's gap closes where it
/// left and opens where it would land, every other row sliding by one.
/// `source` is the dragged row's index in this section (null when it comes
/// from elsewhere); `target` the index it would land at, of the section
/// without it (null when it would land elsewhere). Mac
/// `PaneSidebarOrder.shift`.
pub fn shift(index: usize, source: ?usize, target: ?usize) i32 {
    if (source) |s| if (index == s) return 0;
    const after = if (source) |s| index > s else false;
    const without = if (after) index - 1 else index;
    const opens = if (target) |t| without >= t else false;
    return @as(i32, @intFromBool(opens)) - @as(i32, @intFromBool(after));
}

// ---------------------------------------------------------------------------
// Tests (Mac `PaneSidebarOrderTests`)

const testing = std.testing;

fn expectArranged(want: []const []const u8, visible: []const []const u8, order: []const []const u8) !void {
    var out: [16]usize = undefined;
    const n = arranged(visible, order, &out);
    try testing.expectEqual(want.len, n);
    for (want, 0..) |w, i| try testing.expectEqualStrings(w, visible[out[i]]);
}

fn expectMoving(
    want: []const []const u8,
    id: []const u8,
    to: usize,
    visible: []const []const u8,
    order: []const []const u8,
    existing: []const []const u8,
) !void {
    var out: [16][]const u8 = undefined;
    const n = moving(id, to, visible, order, existing, &out);
    try testing.expectEqual(want.len, n);
    for (want, 0..) |w, i| try testing.expectEqualStrings(w, out[i]);
}

test "pane_sidebar_order: an empty order is the tree's order" {
    try expectArranged(&.{ "a", "b", "c" }, &.{ "a", "b", "c" }, &.{});
}

test "pane_sidebar_order: the order wins over the tree for the panes it knows" {
    try expectArranged(&.{ "c", "a", "b" }, &.{ "a", "b", "c" }, &.{ "c", "a", "b" });
}

test "pane_sidebar_order: a new pane goes after its nearest known tree neighbour" {
    // The tree split b into b | n: n lands right after b, wherever b is.
    try expectArranged(&.{ "c", "b", "n", "a" }, &.{ "a", "b", "n", "c" }, &.{ "c", "b", "a" });
}

test "pane_sidebar_order: a new pane with nothing known before it goes before the next" {
    try expectArranged(&.{ "c", "n", "a" }, &.{ "n", "a", "c" }, &.{ "c", "a" });
}

test "pane_sidebar_order: with nothing known at all, new panes keep the tree's order" {
    try expectArranged(&.{ "x", "y" }, &.{ "x", "y" }, &.{ "gone", "other-tab" });
}

test "pane_sidebar_order: ids not on show are skipped, and a duplicate counts once" {
    try expectArranged(&.{ "b", "a" }, &.{ "a", "b" }, &.{ "s", "b", "b", "a" });
}

test "pane_sidebar_order: moving puts the pane at the index of the list without it" {
    try expectMoving(&.{ "b", "c", "a" }, "a", 2, &.{ "a", "b", "c" }, &.{}, &.{ "a", "b", "c" });
    try expectMoving(&.{ "c", "a", "b" }, "c", 0, &.{ "a", "b", "c" }, &.{}, &.{ "a", "b", "c" });
    // Past the end clamps to the end.
    try expectMoving(&.{ "b", "c", "a" }, "a", 99, &.{ "a", "b", "c" }, &.{}, &.{ "a", "b", "c" });
}

test "pane_sidebar_order: a stashed pane keeps its place after the pane it followed" {
    // s (stashed) followed b; moving a to the end leaves s right after b.
    try expectMoving(
        &.{ "b", "s", "c", "a" },
        "a",
        2,
        &.{ "a", "b", "c" },
        &.{ "a", "b", "s", "c" },
        &.{ "a", "b", "c", "s" },
    );
}

test "pane_sidebar_order: a stashed pane that led the order still leads it" {
    try expectMoving(&.{ "s", "b", "a" }, "a", 1, &.{ "a", "b" }, &.{ "s", "a", "b" }, &.{ "a", "b", "s" });
}

test "pane_sidebar_order: a pane that followed the moved one stays put, not dragged along" {
    // s followed a, which led the order; a moves to the end and s stays at
    // the front (Mac: "Not after the moved pane: the others stay where they
    // were").
    try expectMoving(&.{ "s", "b", "a" }, "a", 1, &.{ "a", "b" }, &.{ "a", "s", "b" }, &.{ "a", "b", "s" });
}

test "pane_sidebar_order: closed panes are pruned on a move" {
    try expectMoving(&.{ "b", "a" }, "a", 1, &.{ "a", "b" }, &.{ "a", "gone", "b" }, &.{ "a", "b" });
}

test "pane_sidebar_order: pane ids compare as pane ids, not bytes" {
    const lower = "1d0a0b0c-0000-4000-8000-000000000001";
    const upper = "1D0A0B0C-0000-4000-8000-000000000001";
    try expectArranged(&.{ "z", lower }, &.{ lower, "z" }, &.{ "z", upper });
}

test "pane_sidebar_order: shift opens the gap where the row would land and closes its own" {
    // Dragging row 0 to land at 2 (of the list without it): rows 1 and 2
    // close its gap, row 3 stays.
    try testing.expectEqual(@as(i32, 0), shift(0, 0, 2));
    try testing.expectEqual(@as(i32, -1), shift(1, 0, 2));
    try testing.expectEqual(@as(i32, -1), shift(2, 0, 2));
    try testing.expectEqual(@as(i32, 0), shift(3, 0, 2));
    // From elsewhere (another section): rows at or past the target open.
    try testing.expectEqual(@as(i32, 0), shift(0, null, 1));
    try testing.expectEqual(@as(i32, 1), shift(1, null, 1));
    // Leaving for elsewhere: rows past the source close the gap.
    try testing.expectEqual(@as(i32, 0), shift(0, 1, null));
    try testing.expectEqual(@as(i32, -1), shift(2, 1, null));
    // Neither: nothing moves.
    try testing.expectEqual(@as(i32, 0), shift(3, null, null));
}
