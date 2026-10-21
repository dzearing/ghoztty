//! A drag on a divider or a stack grip that can collapse its row (T2124): a
//! port of Mac's `BaseTerminalController.RowDrag` and the drag arms around it
//! (`splitDidResize`, `splitDidDragStack`, `squeezeRow`, 2811a3043).
//!
//! The gesture, as the user feels it: drag a divider (or the grip between two
//! cards of a stack) well past a pane's minimum and the outermost pane on that
//! side folds into a strip instead of being crushed. Keep going and the next
//! one folds too (`pane_stack_layout.chain`), and the next. Drag back and they
//! come out again, last folded first, until the row is exactly as the drag
//! found it. A grip at the edge of a narrowed run drags the other way: pulled
//! outward it brings the nearest strip back on show.
//!
//! Every step is measured against the row AS THE DRAG FOUND IT, never against
//! the previous step's result: the state is put back to the snapshot taken at
//! the press (`origin`) and the change re-applied whole. That is what makes a
//! drag reversible however far it went.
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
const Side = layout.Side;
const Restack = layout.Restack;
const Squeeze = layout.Squeeze;
const PaneStackState = stack_state.PaneStackState;

pub const RowDrag = struct {
    gpa: Allocator,
    /// Owns `row` and `key`.
    arena: std.heap.ArenaAllocator,
    /// The row as the drag found it.
    row: Row,
    key: []const Id,
    /// The row's collapse and slot sizes at the press: every step starts here.
    origin: stack_state.Snapshot,
    /// The row index of the first item after the grip.
    boundary: usize,
    /// Added to a position the gesture reports to measure it from the row's
    /// start.
    offset: f64,
    /// How far past a minimum the pointer must go before a pane folds away
    /// (`Metrics.restack_distance`, in the row's units).
    past: f64,
    /// A widening drag's change, from a grip at the run's edge.
    change: ?Restack = null,
    /// What a squeezing drag has tucked away so far.
    squeeze: ?Squeeze = null,
    /// Where a divider drag grabbed the divider, from the start of its split.
    /// A side ALREADY under its minimum there (a window too narrow for it, so
    /// it is laid out stacked) folds only once the drag pushes `past` beyond
    /// the press, and is back where it was at the press: measured from the
    /// minimum alone, as Mac does, the first pixel of movement folded that
    /// whole side, and it could not come back during the drag.
    press: ?f64 = null,

    /// Begin a drag on the grip before item `boundary` of `row` (copied: the
    /// layout result it came from is freed long before the drag ends).
    pub fn begin(gpa: Allocator, state: *PaneStackState, row: Row, boundary: usize, offset: f64, past: f64) Allocator.Error!RowDrag {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const items = try a.alloc([]const Id, row.items.len);
        for (row.items, 0..) |it, i| items[i] = try a.dupe(Id, it);
        var copy = row;
        copy.items = items;
        copy.sizes = try a.dupe(f64, row.sizes);
        copy.minimums = try a.dupe(f64, row.minimums);
        const key = try copy.key(a);
        const origin = try state.snapshot(key);
        state.is_gesturing = true;
        return .{
            .gpa = gpa,
            .arena = arena,
            .row = copy,
            .key = key,
            .origin = origin,
            .boundary = boundary,
            .offset = offset,
            .past = past,
        };
    }

    pub fn deinit(self: *RowDrag, state: *PaneStackState) void {
        state.is_gesturing = false;
        self.origin.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// A divider drag moved: `position` is the divider's centre from the start
    /// of the split it belongs to, `dimension` that split's extent, and the
    /// two minimums the least each side of it can be. Well past a side's
    /// minimum the row collapses instead of the divider moving; back where
    /// that side fits, it comes back. Returns whether the row is squeezed: the
    /// window then leaves the split ratios as the drag found them.
    pub fn dividerMoved(self: *RowDrag, state: *PaneStackState, position: f64, dimension: f64, leading_min: f64, trailing_min: f64) Allocator.Error!Step {
        var leading = leading_min;
        var trailing = dimension - trailing_min;
        if (self.press) |p| {
            leading = @min(leading, p);
            trailing = @max(trailing, p);
        }
        const collapsing: ?Side = if (position < leading - self.past)
            .leading
        else if (position > trailing + self.past)
            .trailing
        else
            null;
        return self.squeezeAt(state, position, collapsing, position >= leading and position <= trailing);
    }

    /// A grip on a stack moved `delta` from where the press was, `minimum`
    /// being the least a pane may be along the row.
    pub fn gripMoved(self: *RowDrag, state: *PaneStackState, kind: layout.StackHandle.Kind, delta: f64, minimum: f64) Allocator.Error!Step {
        switch (kind) {
            .expand => |side| {
                const outward = if (side == .trailing) delta else -delta;
                return self.setChange(state, if (outward > self.past) .{ .expand = side } else null);
            },
            .between => |slot| {
                // `delta` runs from where the drag began, so it applies to the
                // sizes the row had then: added to each step's result it would
                // compound and the edge would run ahead of the hand.
                const sizes = self.row.sizes;
                if (slot + 1 >= sizes.len) return .{};
                // Resizing two slots never changes their sum.
                const pair = sizes[slot] + sizes[slot + 1];
                const leading = sizes[slot] + delta;
                // Squeezing a card next to the grip well past its minimum
                // tucks the outermost card on that side away, then the next,
                // and the next, as the pointer goes on.
                const collapsing: ?Side = if (pair - leading < minimum - self.past)
                    .trailing
                else if (leading < minimum - self.past)
                    .leading
                else
                    null;
                const step = try self.squeezeAt(state, delta, collapsing, leading >= minimum and pair - leading >= minimum);
                if (step.squeezed) return step;
                if (pair < 2 * minimum) return step;
                const resized = try self.gpa.dupe(f64, sizes);
                defer self.gpa.free(resized);
                resized[slot] = @min(@max(leading, minimum), pair - minimum);
                resized[slot + 1] = pair - resized[slot];
                var total: f64 = 0;
                for (resized) |s| total += s;
                if (total > 0) for (resized) |*s| {
                    s.* /= total;
                };
                try state.resize(self.row, resized);
                return step;
            },
        }
    }

    /// One step of a drag that can squeeze its row, with the pointer at
    /// `position` (the gesture's own measure). `collapsing`: the side whose
    /// first item the drag has just squeezed well past its minimum, null if
    /// not; `back`: the drag is back where that item fits again.
    fn squeezeAt(self: *RowDrag, state: *PaneStackState, position: f64, collapsing: ?Side, back: bool) Allocator.Error!Step {
        const x = self.offset + position;
        const next: ?Squeeze = if (self.squeeze) |current|
            // The first item comes back by the drag's own measure; the ones
            // after it by the chain's.
            (if (current.count == 1 and back) null else layout.chain(self.row, self.boundary, x, current, self.past))
        else if (collapsing) |side|
            layout.chain(self.row, self.boundary, x, .{ .side = side, .count = 1 }, self.past)
        else
            null;
        var step: Step = .{};
        if (!squeezeEql(next, self.squeeze)) {
            try state.restoreSnapshot(self.key, self.origin);
            self.squeeze = next;
            if (next) |s| {
                try state.restack(self.row, .{ .collapse = s.side }, s.count);
                step.restacked = true;
            } else step.restored = true;
        }
        const s = next orelse return step;
        const shares = try layout.squeezedShares(self.gpa, self.row, self.boundary, s, x);
        defer self.gpa.free(shares);
        try state.resize(self.row, shares);
        step.squeezed = true;
        return step;
    }

    /// Put the row in the state `change` makes of it as the drag found it
    /// (null: as the drag found it): a grip at the run's edge.
    fn setChange(self: *RowDrag, state: *PaneStackState, change: ?Restack) Allocator.Error!Step {
        if (restackEql(self.change, change)) return .{};
        try state.restoreSnapshot(self.key, self.origin);
        self.change = change;
        const c = change orelse return .{ .restored = true };
        try state.restack(self.row, c, 1);
        return .{ .restacked = true };
    }

    /// The pane the caret should move to after a restack, when the focused
    /// pane `focused` has just folded away: the nearest item still on show,
    /// and within it (a nested column, say) the pane last focused there. Null
    /// when the focus can stay where it is. Mac `splitDidRestack`.
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

/// What one step of a drag did.
pub const Step = struct {
    /// The row is squeezed: the grip follows the pointer through the run, and
    /// a divider drag must leave the split ratios as it found them.
    squeezed: bool = false,
    /// A pane folded away or came back this step: the caret may need to move
    /// (`RowDrag.focusAfterRestack`).
    restacked: bool = false,
    /// The row went back to how the drag found it this step.
    restored: bool = false,
};

fn squeezeEql(a: ?Squeeze, b: ?Squeeze) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.side == b.?.side and a.?.count == b.?.count;
}

fn restackEql(a: ?Restack, b: ?Restack) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

// ---------------------------------------------------------------------------
// Tests. A row of three panes across 1000 units: 10 gaps, 36 peeks, 300
// minimums - the elevated style's numbers at 100%.

const past_default: f64 = layout.Metrics.restack_distance;

const items_3 = [_][]const Id{ &.{1}, &.{2}, &.{3} };
const key_3 = [_]Id{ 1, 2, 3 };

fn rowOf3() Row {
    const third = (1000.0 - 20.0) / 3.0;
    return .{
        .items = &items_3,
        .run = .{ .lo = 0, .hi = 2 },
        .sizes = &.{ third, third, third },
        .start = 0,
        .extent = 1000,
        .minimums = &.{ 300, 300, 300 },
        .gap = 10,
        .peek = 36,
    };
}

test "divider: dragged well past the trailing panes' minimum folds the last one, and back restores it" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    // The divider after the first pane, in a split spanning the whole row.
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 1, 0, past_default);
    defer drag.deinit(&state);
    try testing.expect(state.is_gesturing);

    // Inside the trailing side's room (1000 - 600 = 400): an ordinary resize.
    var step = try drag.dividerMoved(&state, 420, 1000, 300, 600);
    try testing.expect(!step.squeezed);
    try testing.expect(state.pin(&key_3) == null);

    // Past it by more than the restack distance: the third pane folds.
    step = try drag.dividerMoved(&state, 460, 1000, 300, 600);
    try testing.expect(step.squeezed and step.restacked);
    try testing.expect(layout.Pin.eql(.{ .start = 0, .count = 2 }, state.pin(&key_3)));

    // Back where the trailing side fits: the row is as the drag found it.
    step = try drag.dividerMoved(&state, 380, 1000, 300, 600);
    try testing.expect(!step.squeezed and step.restored);
    try testing.expect(state.pin(&key_3) == null);
}

test "divider: a drag that goes on chains into the next pane, and coming back unfolds them last first" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 1, 0, past_default);
    defer drag.deinit(&state);

    _ = try drag.dividerMoved(&state, 460, 1000, 300, 600);
    try testing.expect(layout.Pin.eql(.{ .start = 0, .count = 2 }, state.pin(&key_3)));

    // Far enough that the second pane cannot keep its minimum either.
    const step = try drag.dividerMoved(&state, 900, 1000, 300, 600);
    try testing.expect(step.squeezed and step.restacked);
    try testing.expect(layout.Pin.eql(.{ .start = 0, .count = 1 }, state.pin(&key_3)));

    // Back to where the second pane fits again: only the third stays folded.
    _ = try drag.dividerMoved(&state, 600, 1000, 300, 600);
    try testing.expect(layout.Pin.eql(.{ .start = 0, .count = 2 }, state.pin(&key_3)));

    // And all the way back: nothing folded.
    _ = try drag.dividerMoved(&state, 350, 1000, 300, 600);
    try testing.expect(state.pin(&key_3) == null);
}

test "divider: a side already under its minimum at the press folds only once pushed past the press" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 1, 0, past_default);
    defer drag.deinit(&state);
    // The trailing side needs 600 of a 1000 split but was grabbed at 500:
    // already 100 under its minimum.
    drag.press = 500;

    // A nudge further in: no fold (measured from the minimum alone, 520 is
    // 120 past it and would fold).
    var step = try drag.dividerMoved(&state, 520, 1000, 300, 600);
    try testing.expect(!step.squeezed);
    try testing.expect(state.pin(&key_3) == null);

    // Pushed past the press by more than the distance: it folds.
    step = try drag.dividerMoved(&state, 560, 1000, 300, 600);
    try testing.expect(step.squeezed);
    try testing.expect(layout.Pin.eql(.{ .start = 0, .count = 2 }, state.pin(&key_3)));

    // Back at the press: unfolded, as the drag found it.
    step = try drag.dividerMoved(&state, 500, 1000, 300, 600);
    try testing.expect(step.restored);
    try testing.expect(state.pin(&key_3) == null);
}

test "divider: past the leading minimum folds the first pane" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    // The divider after the second pane, in a split spanning the whole row.
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 2, 0, past_default);
    defer drag.deinit(&state);
    const step = try drag.dividerMoved(&state, 540, 1000, 600, 300);
    try testing.expect(step.squeezed);
    try testing.expect(layout.Pin.eql(.{ .start = 1, .count = 2 }, state.pin(&key_3)));
}

test "divider: a squeezed row keeps the sizes that put the grip under the pointer" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 1, 0, past_default);
    defer drag.deinit(&state);
    _ = try drag.dividerMoved(&state, 460, 1000, 300, 600);
    const shares = state.sharesFor(&key_3) orelse return error.TestExpectedShares;
    try testing.expectEqual(@as(usize, 2), shares.len);
    var sum: f64 = 0;
    for (shares) |s| sum += s;
    try testing.expectApproxEqAbs(@as(f64, 1), sum, 1e-9);
}

test "divider: the drag starts from the collapse the row already had, and returns to it" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    try state.restack(rowOf3(), .{ .collapse = .leading }, 1);
    const before = state.pin(&key_3);
    try testing.expect(before != null);
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 1, 0, past_default);
    defer drag.deinit(&state);
    _ = try drag.dividerMoved(&state, 460, 1000, 300, 600);
    _ = try drag.dividerMoved(&state, 380, 1000, 300, 600);
    try testing.expect(layout.Pin.eql(before, state.pin(&key_3)));
}

test "grip between cards: resizes the pair, then folds past a minimum and back" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    // A stack showing two of three cards, the grip between them.
    const row: Row = .{
        .items = &items_3,
        .run = .{ .lo = 1, .hi = 2 },
        .sizes = &.{ 400, 400 },
        .start = 0,
        .extent = 856,
        .minimums = &.{ 300, 300, 300 },
        .gap = 10,
        .peek = 36,
    };
    var drag = try RowDrag.begin(testing.allocator, &state, row, 2, 46 + 405, past_default);
    defer drag.deinit(&state);

    var step = try drag.gripMoved(&state, .{ .between = 0 }, 50, 300);
    try testing.expect(!step.squeezed);
    const shares = state.sharesFor(&key_3) orelse return error.TestExpectedShares;
    try testing.expectApproxEqAbs(@as(f64, 450.0 / 800.0), shares[0], 1e-9);

    // The trailing card well under its minimum: it folds.
    step = try drag.gripMoved(&state, .{ .between = 0 }, 160, 300);
    try testing.expect(step.squeezed and step.restacked);
    try testing.expect(layout.Pin.eql(.{ .start = 1, .count = 1 }, state.pin(&key_3)));

    // Back where both fit: the row as the drag found it.
    step = try drag.gripMoved(&state, .{ .between = 0 }, 0, 300);
    try testing.expect(!step.squeezed and step.restored);
    try testing.expect(state.pin(&key_3) == null);
}

test "grip at the run's edge: pulled outward past the distance brings a strip back, and in again puts it away" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    var row = rowOf3();
    try state.restack(row, .{ .collapse = .trailing }, 1);
    row.run = .{ .lo = 0, .hi = 1 };
    row.sizes = &.{ 450, 450 };
    var drag = try RowDrag.begin(testing.allocator, &state, row, 0, 0, past_default);
    defer drag.deinit(&state);

    var step = try drag.gripMoved(&state, .{ .expand = .trailing }, 20, 300);
    try testing.expect(!step.restacked);
    try testing.expect(state.pin(&key_3) != null);

    step = try drag.gripMoved(&state, .{ .expand = .trailing }, 60, 300);
    try testing.expect(step.restacked);
    try testing.expect(state.pin(&key_3) == null);

    step = try drag.gripMoved(&state, .{ .expand = .trailing }, 10, 300);
    try testing.expect(step.restored);
    try testing.expect(layout.Pin.eql(.{ .start = 0, .count = 2 }, state.pin(&key_3)));
}

test "focus: the caret leaves a pane that folded, for the nearest one on show" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    state.noteFocus(3);
    var drag = try RowDrag.begin(testing.allocator, &state, rowOf3(), 1, 0, past_default);
    defer drag.deinit(&state);
    _ = try drag.dividerMoved(&state, 460, 1000, 300, 600);
    try testing.expectEqual(@as(?Id, 2), drag.focusAfterRestack(&state, 3));
    // A pane still on show keeps it.
    try testing.expectEqual(@as(?Id, null), drag.focusAfterRestack(&state, 1));
}
