//! A drag on any gutter of a row - a divider, a grip between two cards on
//! show, a grip where the run meets its strips (T2124, T2263): a port of
//! Mac's `BaseTerminalController.RowDrag` and `dragRow` (a81db68f9).
//!
//! The gesture, as the user feels it: the row is a function of where its
//! gutter is (`pane_stack_layout.dragged`). Drag a gutter one way and the two
//! panes beside it resize; past the near pane's minimum the next one gives
//! way, and once there is no room for them all at their minimums the
//! outermost pane on that side folds into a strip, then the next. The panes
//! on the other side grow and their strips stay strips. A strip pulled out by
//! its gutter comes out alone, the other side tucking away to make room. Drag
//! back and the row is exactly as the drag found it.
//!
//! Every step is measured against the row AS THE DRAG FOUND IT, never against
//! the previous step's result, which is what makes a drag reversible however
//! far it went.
//!
//! Pure and free of OS imports, so its tests run in every app-runtime lane.
//! The window turns pointer pixels into the positions below; every length here
//! is in the row's own units (the grid lays out in pixels, so pixels).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const layout = @import("pane_stack_layout.zig");
const stack_state = @import("pane_stack_state.zig");

const Id = layout.Id;
const Row = layout.Row;
const Range = layout.Range;
const RowRatio = layout.RowRatio;
const PaneStackState = stack_state.PaneStackState;

pub const RowDrag = struct {
    gpa: Allocator,
    /// Owns `row`, `key`, `sizes`, `shares` and `ratios`.
    arena: std.heap.ArenaAllocator,
    /// The row as the drag found it.
    row: Row,
    key: []const Id,
    /// The row index of the first item after the gutter.
    boundary: usize,
    /// Added to a position the gesture reports to measure it from the row's
    /// start.
    offset: f64,
    /// Each item's size when the drag began; null for a strip.
    sizes: []const ?f64,
    /// The run the last step left on show.
    run: Range,
    /// The row's shares, one per item, when the last step left all of it on
    /// show: what the window sizes the tree's splits of the row by.
    shares: []f64,
    /// The row's splits with the ratios the drag found them at
    /// (`noteRatios`): what the tree goes back to while part of the row is
    /// folded away. Empty until the window notes them.
    ratios: []const RowRatio = &.{},
    /// The axis the row runs along: what the window finds its splits by.
    direction: layout.Direction = .horizontal,
    /// Every row's collapse and slot shares at the press: what a gutter back
    /// where the drag found it puts back, exactly - a row stacked for want
    /// of room, say, stays unpinned rather than pinned at the run it had, and
    /// a stale pin a step cleared (`PaneStackState.show`) comes back too.
    origin: stack_state.Saved,

    /// Begin a drag on the gutter before item `boundary` of `row` (copied: the
    /// layout result it came from is freed long before the drag ends).
    pub fn begin(gpa: Allocator, state: *PaneStackState, row: Row, boundary: usize, offset: f64) Allocator.Error!RowDrag {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const items = try a.alloc([]const Id, row.items.len);
        for (row.items, 0..) |it, i| items[i] = try a.dupe(Id, it);
        var copy = row;
        copy.items = items;
        copy.sizes = try a.dupe(f64, row.sizes);
        copy.minimums = try a.dupe(f64, row.minimums);
        const sizes = try a.alloc(?f64, row.items.len);
        @memset(sizes, null);
        for (0..row.run.count()) |k| {
            const i = row.run.lo + k;
            if (i < sizes.len and k < row.sizes.len) sizes[i] = row.sizes[k];
        }
        const key = try copy.key(a);
        const shares = try a.alloc(f64, row.items.len);
        var origin = try state.saved();
        errdefer origin.deinit(gpa);
        state.is_gesturing = true;
        return .{
            .gpa = gpa,
            .arena = arena,
            .row = copy,
            .key = key,
            .boundary = boundary,
            .offset = offset,
            .sizes = sizes,
            .run = row.run,
            .shares = shares,
            .origin = origin,
        };
    }

    pub fn deinit(self: *RowDrag, state: *PaneStackState) void {
        state.is_gesturing = false;
        self.origin.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Keep the row's splits at the ratios the drag found them
    /// (`layout.settingRow` with no shares).
    pub fn noteRatios(self: *RowDrag, ratios: []const RowRatio) Allocator.Error!void {
        self.ratios = try self.arena.allocator().dupe(RowRatio, ratios);
    }

    /// One step: the gutter at `position` (the gesture's own measure). The
    /// row as the gutter's position makes it.
    pub fn moved(self: *RowDrag, state: *PaneStackState, position: f64) Allocator.Error!Step {
        const d = try layout.dragged(self.gpa, self.row, self.boundary, self.offset + position, self.sizes);
        defer self.gpa.free(d.sizes);
        if (self.isOrigin(d)) {
            try state.restore(&self.origin);
        } else try state.show(self.row, d.run, d.sizes);
        const restacked = d.run.lo != self.run.lo or d.run.hi != self.run.hi;
        self.run = d.run;
        const all = d.run.count() == self.row.items.len and d.sizes.len == self.shares.len;
        if (all) {
            var total: f64 = 0;
            for (d.sizes) |s| total += s;
            for (self.shares, d.sizes) |*sh, s| sh.* = s / @max(total, 1);
        }
        return .{ .all_shown = all, .restacked = restacked };
    }

    /// Whether `d` is the row as the drag found it.
    fn isOrigin(self: *const RowDrag, d: layout.Dragged) bool {
        if (d.run.lo != self.row.run.lo or d.run.hi != self.row.run.hi) return false;
        if (d.sizes.len != self.row.sizes.len) return false;
        for (d.sizes, self.row.sizes) |x, y| if (@abs(x - y) > 1e-6) return false;
        return true;
    }

    /// The pane the caret should move to after a restack, when the focused
    /// pane `focused` has just folded away: the nearest item still on show,
    /// and within it (a nested column, say) the pane last focused there. Null
    /// when the focus can stay where it is. Mac `keepFocusOnShow`.
    pub fn focusAfterRestack(self: *const RowDrag, state: *const PaneStackState, focused: Id) ?Id {
        const p = state.pin(self.key) orelse return null;
        const index = for (self.row.items, 0..) |item, i| {
            if (std.mem.indexOfScalar(Id, item, focused) != null) break i;
        } else return null;
        if (p.count == 0) return null;
        const target = std.math.clamp(index, p.start, p.start + p.count - 1);
        if (target == index) return null;
        var best: ?Id = null;
        var best_rank: u32 = std.math.maxInt(u32);
        for (self.row.items[target]) |id| {
            const r = state.rank(id) orelse std.math.maxInt(u32);
            if (best == null or r < best_rank) {
                best = id;
                best_rank = r;
            }
        }
        return best;
    }
};

/// The row index of the first item after a grip's gutter: between two cards,
/// the second; at the run's edge, the first item past it on that side. Mac
/// `splitDidDragStack`.
pub fn gripBoundary(h: layout.StackHandle) usize {
    return switch (h.kind) {
        .between => |slot| h.row.run.lo + slot + 1,
        .expand => |side| switch (side) {
            .leading => h.row.run.lo,
            .trailing => h.row.run.hi + 1,
        },
    };
}

/// What one step of a drag did.
pub const Step = struct {
    /// All of the row is on show: the tree's ratios size it, by
    /// `RowDrag.shares`. Otherwise the tree stays as the drag found it
    /// (`RowDrag.ratios`) and the collapse's shares size the run.
    all_shown: bool = false,
    /// What is on show changed this step: the caret may need to move
    /// (`RowDrag.focusAfterRestack`).
    restacked: bool = false,
};

// ---------------------------------------------------------------------------
// Tests. A row of three panes across 1220 units: 10 gaps, 36 peeks, 300
// minimums, three 400 panes - Mac's PaneLayoutTests numbers.

const items_3 = [_][]const Id{ &.{1}, &.{2}, &.{3} };
const key_3 = [_]Id{ 1, 2, 3 };

fn rowOf3() Row {
    return .{
        .items = &items_3,
        .run = .{ .lo = 0, .hi = 2 },
        .sizes = &.{ 400, 400, 400 },
        .start = 0,
        .extent = 1220,
        .minimums = &.{ 300, 300, 300 },
        .gap = 10,
        .peek = 36,
    };
}

test "divider: a nudge resizes the two panes beside it, through the tree" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    // The divider after the first pane, at 405, in a split spanning the row.
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 1, 0);
    defer drag.deinit(&state);
    try testing.expect(state.is_gesturing);

    const step = try drag.moved(&state, 455);
    try testing.expect(step.all_shown and !step.restacked);
    try testing.expect(state.pin(&key_3) == null);
    try testing.expectApproxEqAbs(@as(f64, 450.0 / 1200.0), drag.shares[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 350.0 / 1200.0), drag.shares[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 400.0 / 1200.0), drag.shares[2], 1e-9);
}

test "divider: dragged on, the far pane folds as soon as the side cannot hold both, then the next" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 1, 0);
    defer drag.deinit(&state);

    // b at its minimum, c giving way: still all on show.
    var step = try drag.moved(&state, 600);
    try testing.expect(step.all_shown);
    // No room for b and c at their minimums: c folds.
    step = try drag.moved(&state, 700);
    try testing.expect(!step.all_shown and step.restacked);
    try testing.expect(layout.Pin.eql(.{ .start = 0, .count = 2 }, state.pin(&key_3)));
    // At the edge, b too.
    step = try drag.moved(&state, 1210);
    try testing.expect(step.restacked);
    try testing.expect(layout.Pin.eql(.{ .start = 0, .count = 1 }, state.pin(&key_3)));
}

test "divider: back where the drag began, the row is exactly as it was, in one move" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 1, 0);
    defer drag.deinit(&state);
    _ = try drag.moved(&state, 1210);
    try testing.expect(state.pin(&key_3) != null);

    // One move back, as a fast mouse delivers it (T2129).
    var step = try drag.moved(&state, 405);
    try testing.expect(step.all_shown and step.restacked);
    try testing.expect(state.pin(&key_3) == null);
    try testing.expect(state.sharesFor(&key_3) == null);
    for (drag.shares) |s| try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), s, 1e-9);
    // And a further move at the same spot changes nothing.
    step = try drag.moved(&state, 405);
    try testing.expect(!step.restacked);
}

test "divider: past the leading minimum folds the first pane" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    // The divider after the second pane, dragged toward the start.
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 2, 0);
    defer drag.deinit(&state);
    const step = try drag.moved(&state, 500);
    try testing.expect(!step.all_shown);
    try testing.expect(layout.Pin.eql(.{ .start = 1, .count = 2 }, state.pin(&key_3)));
}

test "divider: a folded row's shares put the gutter under the pointer" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 1, 0);
    defer drag.deinit(&state);
    _ = try drag.moved(&state, 700);
    const shares = state.sharesFor(&key_3) orelse return error.TestExpectedShares;
    try testing.expectEqual(@as(usize, 2), shares.len);
    // a gets 695 of the 695 + 469 the run holds.
    try testing.expectApproxEqAbs(@as(f64, 695.0 / (695.0 + 469.0)), shares[0], 1e-9);
}

test "grip between cards: resizes the pair, folds on its far side, and never brings strips out" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    // a | b on show, c a strip, across 1164 (a and b 554 each).
    var row = rowOf3();
    row.run = .{ .lo = 0, .hi = 1 };
    row.sizes = &.{ 554, 554 };
    row.extent = 1164;
    try state.show(row, row.run, row.sizes);
    // The grip between a and b sits at 559.
    var drag = try RowDrag.begin(testing.allocator, &state, row, 1, 559);
    defer drag.deinit(&state);

    var step = try drag.moved(&state, -100);
    try testing.expect(!step.all_shown and !step.restacked);
    var shares = state.sharesFor(&key_3) orelse return error.TestExpectedShares;
    try testing.expectApproxEqAbs(@as(f64, 454.0 / 1108.0), shares[0], 1e-9);

    // Dragged toward the start, a folds; c stays a strip however far.
    step = try drag.moved(&state, -559);
    try testing.expect(step.restacked);
    try testing.expect(layout.Pin.eql(.{ .start = 1, .count = 1 }, state.pin(&key_3)));

    // Back: as the drag found it.
    step = try drag.moved(&state, 0);
    try testing.expect(layout.Pin.eql(.{ .start = 0, .count = 2 }, state.pin(&key_3)));
    shares = state.sharesFor(&key_3) orelse return error.TestExpectedShares;
    try testing.expectApproxEqAbs(@as(f64, 0.5), shares[0], 1e-9);
}

test "grip at the run's edge: pulled out brings the strip out alone, the other side giving way" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    // a | b on show, c a strip at the end: the grip at the run's trailing
    // edge (boundary 2, at 1164 - 46 + 5).
    var row = rowOf3();
    row.run = .{ .lo = 0, .hi = 1 };
    row.sizes = &.{ 554, 554 };
    row.extent = 1164;
    try state.show(row, row.run, row.sizes);
    const at = 1164.0 - 46.0 + 5.0;
    var drag = try RowDrag.begin(testing.allocator, &state, row, 2, at);
    defer drag.deinit(&state);

    // Pulled in to where c fits at its minimum (859): c comes out, a and b
    // give way.
    var step = try drag.moved(&state, 859 - at);
    try testing.expect(step.all_shown and step.restacked);
    try testing.expect(state.pin(&key_3) == null);

    // Back to the edge: c a strip again, the row as it was.
    step = try drag.moved(&state, 0);
    try testing.expect(step.restacked);
    try testing.expect(layout.Pin.eql(.{ .start = 0, .count = 2 }, state.pin(&key_3)));
}

test "a row stacked for want of room, let go where it was pressed, stays unpinned" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    // a | b on show and c a strip because the window is narrow, collapsed by
    // nobody: no pin.
    var row = rowOf3();
    row.run = .{ .lo = 0, .hi = 1 };
    row.sizes = &.{ 554, 554 };
    row.extent = 1164;
    var drag = try RowDrag.begin(testing.allocator, &state, row, 1, 559);
    defer drag.deinit(&state);
    _ = try drag.moved(&state, -400);
    try testing.expect(state.pin(&key_3) != null);
    _ = try drag.moved(&state, 0);
    try testing.expect(state.pin(&key_3) == null);
    try testing.expect(state.sharesFor(&key_3) == null);
}

test "focus: the caret leaves a pane that folded, for the nearest one on show" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    state.noteFocus(3);
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 1, 0);
    defer drag.deinit(&state);
    _ = try drag.moved(&state, 700);
    try testing.expectEqual(@as(?Id, 2), drag.focusAfterRestack(&state, 3));
    // A pane still on show keeps it.
    try testing.expectEqual(@as(?Id, null), drag.focusAfterRestack(&state, 1));
}
