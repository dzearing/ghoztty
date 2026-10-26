//! Random sequences of what a user does to a window of stacked rows - drag a
//! divider or a stack grip, focus, split, close, close and undo, swap, stash,
//! bring a stashed pane back, resize - checking after every step the rules a
//! strip lives by (T2129, a port of Mac's `PaneStackFuzzTests`, 2811a3043):
//!
//! - the focused pane is on show;
//! - focusing a pane on show changes no row;
//! - focusing a strip brings out only panes of its own collapsed rows;
//! - adding or removing a pane never brings a strip out, except where the
//!   rules say so (the only pane on show closed; a row that stopped being the
//!   row the user collapsed);
//! - an undone close puts the row back as it was, and a drag let go where it
//!   began leaves every row as it found it;
//! - every resizer lives in a gutter, and nothing on show is under the
//!   minimum when there is room.
//!
//! Mac drives `PaneStackState` and `PaneLayout` the way its controller does.
//! This drives the win32 modules the way `Window.zig` does, through the same
//! pure pieces it calls: the real `SplitTree` (split, remove, swap, goto),
//! `pane_stash` (mark, normalize, the visible clone), `close_undo.Anchor`, the
//! row drag of `stack_drag`, `pane_stack_grid` and the state's `noteRows` /
//! `noteFocus` / `noteStacks` at every layout, in that order. Where the two
//! controllers differ, this follows the win32 one: a close hands the caret to
//! the closed pane's neighbour, an undo focuses the pane it brings back unless
//! it comes back as a strip, and a swap - with a pane on show or a strip
//! (T2142) - trades the two in the state before the tree changes. A divider drag
//! that does not squeeze its row moves no ratio here: the window would, and a
//! ratio decides nothing about which panes are strips.
//!
//! Both styles (the elevated gap and the flat gutter), at 100%, 125% and 150%.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const layout = @import("pane_stack_layout.zig");
const stack_state = @import("pane_stack_state.zig");
const grid_mod = @import("pane_stack_grid.zig");
const pane_stash = @import("pane_stash.zig");
const close_undo = @import("close_undo.zig");
const stack_drag = @import("stack_drag.zig");

const Id = layout.Id;
const Rows = stack_state.Rows;
const PaneStackState = stack_state.PaneStackState;

/// A pane: its own reference, so the stash mark is the same memory in every
/// tree that holds it (the `pane_stash` test view's arrangement).
const View = struct {
    id: Id,
    stash_seq: u64 = 0,

    pub fn ref(self: *View, alloc: Allocator) Allocator.Error!*View {
        _ = alloc;
        return self;
    }
    pub fn unref(self: *View, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};
const Tree = SplitTree(View);
const Anchor = close_undo.Anchor(View);

fn viewId(view: *View) Id {
    return view.id;
}

const seeds = 1000;
const steps = 50;
/// Mac's cap on panes on screen.
const most_panes = 9;
/// Every pane a run can make: the first ones, then one per step at most.
const pool = 8 + steps;
const widths = [_]f64{ 700, 900, 1100, 1300, 1600, 2000 };
const scales = [_]f64{ 1, 1.25, 1.5 };

const Fail = error{TestUnexpectedResult} || Allocator.Error;

/// The window's side of the fuzz: a tab's tree, the stack state, a size.
const Fuzz = struct {
    gpa: Allocator,
    /// The run's log and anything else that lives as long as it.
    arena: std.heap.ArenaAllocator,
    views: [pool]View = undefined,
    made: usize = 0,
    tree: Tree,
    state: PaneStackState,
    focused: *View,
    width: f64 = 1600,
    height: f64 = 2400,
    scale: f64 = 1,
    /// The elevated style's gap, or null for the flat style's gutter.
    gap: ?f64 = 10,
    log: std.ArrayListUnmanaged([]const u8) = .empty,
    seed: u64 = 0,
    /// Keep the log and print it on a failure: a failing seed is run again
    /// with this on, since every run of a seed is the same run.
    verbose: bool = false,
    step: usize = 0,

    /// A row of `panes`, equal, the first one focused. In place: the trees
    /// point into `views`.
    fn init(self: *Fuzz, gpa: Allocator, panes: usize) Fail!void {
        self.* = .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .tree = .empty,
            .state = PaneStackState.init(gpa),
            .focused = undefined,
        };
        const first = self.newView();
        self.tree = try Tree.init(gpa, first);
        var last = first;
        for (1..panes) |_| {
            const v = self.newView();
            var single = try Tree.init(gpa, v);
            defer single.deinit();
            self.replaceTree(try self.tree.split(gpa, self.handleOf(last).?, .right, 0.5, &single));
            last = v;
        }
        self.replaceTree(try self.tree.equalize(gpa));
        self.focused = first;
        try self.relayout();
    }

    fn deinit(self: *Fuzz) void {
        self.tree.deinit();
        self.state.deinit();
        self.arena.deinit();
    }

    fn newView(self: *Fuzz) *View {
        self.views[self.made] = .{ .id = self.made + 1 };
        self.made += 1;
        return &self.views[self.made - 1];
    }

    fn viewById(self: *Fuzz, id: Id) ?*View {
        if (id == 0 or id > self.made) return null;
        return &self.views[id - 1];
    }

    fn replaceTree(self: *Fuzz, new: Tree) void {
        var old = self.tree;
        self.tree = new;
        old.deinit();
    }

    fn handleOf(self: *const Fuzz, view: *View) ?Tree.Node.Handle {
        var it = self.tree.iterator();
        while (it.next()) |e| if (e.view == view) return e.handle;
        return null;
    }

    /// The panes on screen (or stashed), in tree order.
    fn paneList(self: *const Fuzz, a: Allocator, stashed: bool) Allocator.Error![]*View {
        var out: std.ArrayListUnmanaged(*View) = .empty;
        var it = self.tree.iterator();
        while (it.next()) |e| if (pane_stash.isStashed(e.view) == stashed) try out.append(a, e.view);
        return out.items;
    }

    fn rowsNow(self: *const Fuzz, a: Allocator) Allocator.Error!Rows {
        var out: std.ArrayListUnmanaged([]const []const Id) = .empty;
        try grid_mod.appendRows(a, &out, self.tree, viewId);
        return out.items;
    }

    /// `Window.gotoVisible`: the neighbour over the panes on screen.
    fn gotoVisible(self: *Fuzz, pane: *View, target: Tree.Goto) Allocator.Error!?*View {
        if (pane_stash.stashedCount(self.tree) == 0) {
            const from = self.handleOf(pane) orelse return null;
            const dest = (try self.tree.goto(self.gpa, from, target)) orelse return null;
            return switch (self.tree.nodes[dest.idx()]) {
                .leaf => |v| v,
                .split => null,
            };
        }
        var vis = try pane_stash.visibleClone(self.tree, self.gpa);
        defer vis.deinit();
        var from: ?Tree.Node.Handle = null;
        var it = vis.iterator();
        while (it.next()) |e| if (e.view == pane) {
            from = e.handle;
        };
        const dest = (try vis.goto(self.gpa, from orelse return null, target)) orelse return null;
        return switch (vis.nodes[dest.idx()]) {
            .leaf => |v| v,
            .split => null,
        };
    }

    /// Lay out as the window does (`stackGridOf`, then `layoutSplits`): the
    /// tree change noted, the focus noted, the grid computed, its stacks noted.
    fn layoutGrid(self: *Fuzz) Allocator.Error!grid_mod.Grid {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        try self.state.noteRows(try self.rowsNow(arena.allocator()));
        if (self.state.recency.first() != self.focused.id) self.state.noteFocus(self.focused.id);
        var built = try grid_mod.buildWith(self.gpa, self.tree, viewId, .visible);
        defer built.deinit(self.gpa);
        var grid = try grid_mod.computeBuilt(
            self.gpa,
            built,
            .{ .right = @intFromFloat(@round(self.width * self.scale)), .bottom = @intFromFloat(@round(self.height * self.scale)) },
            @floatCast(self.scale),
            grid_mod.metrics(self.gap),
            self.state.provider(),
        );
        errdefer grid.deinit();
        try self.state.noteStacks(grid.result.stacks.items);
        return grid;
    }

    fn relayout(self: *Fuzz) Allocator.Error!void {
        var grid = try self.layoutGrid();
        grid.deinit();
    }

    /// The panes minimized by a collapse: tucked in a window big enough that
    /// no row stacks for want of room (those follow focus, by design). Notes
    /// nothing, so it changes no state. Sorted.
    fn tucked(self: *Fuzz, a: Allocator) Allocator.Error![]Id {
        var p = self.state.provider();
        p.shares = null;
        p.shown = null;
        var built = try grid_mod.buildWith(self.gpa, self.tree, viewId, .visible);
        defer built.deinit(self.gpa);
        var grid = try grid_mod.computeBuilt(self.gpa, built, .{ .right = 100_000, .bottom = 100_000 }, 1, grid_mod.metrics(self.gap), p);
        defer grid.deinit();
        return tuckedOf(a, &grid.result);
    }

    /// The panes tucked on screen, at the window's real size: for want of
    /// room as well as by a collapse. Lays out, as the window would.
    fn onScreen(self: *Fuzz, a: Allocator) Allocator.Error![]Id {
        var grid = try self.layoutGrid();
        defer grid.deinit();
        return tuckedOf(a, &grid.result);
    }

    fn focus(self: *Fuzz, view: *View) Allocator.Error!void {
        self.focused = view;
        try self.relayout();
    }

    /// Every collapsed row as `key=start+count`, sorted: what "changed a row"
    /// compares.
    fn pins(self: *const Fuzz, a: Allocator) Allocator.Error![]const u8 {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = self.state.rows.iterator();
        while (it.next()) |kv| {
            const p = kv.value_ptr.pin orelse continue;
            try lines.append(a, try std.fmt.allocPrint(a, "{any}={d}+{d}", .{ kv.key_ptr.*, p.start, p.count }));
        }
        std.mem.sort([]const u8, lines.items, {}, lessString);
        return std.mem.join(a, "; ", lines.items);
    }

    /// The window as one line: its rows, the run of a collapsed row in
    /// brackets; the strips; the focus.
    fn summary(self: *Fuzz, a: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const w = out.writer(a);
        for (try self.rowsNow(a), 0..) |row, r| {
            if (r > 0) try w.writeAll(" ; ");
            const p = self.state.pin(try stack_state.keyOf(a, row));
            for (row, 0..) |item, i| {
                if (i > 0) try w.writeAll(" ");
                const in_run = if (p) |pin| i >= pin.start and i < pin.start + pin.count else false;
                if (in_run) try w.writeAll("[");
                for (item, 0..) |id, j| try w.print("{s}{d}", .{ if (j > 0) "," else "", id });
                if (in_run) try w.writeAll("]");
            }
        }
        try w.print("  strips: {any}  stashed: {d}  focus: {d}  w={d}", .{ try self.tucked(a), pane_stash.stashedCount(self.tree), self.focused.id, self.width });
        return out.items;
    }

    fn note(self: *Fuzz, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        if (!self.verbose) return;
        const a = self.arena.allocator();
        const line = try std.fmt.allocPrint(a, fmt, args);
        try self.log.append(a, try std.fmt.allocPrint(a, "{s}  =>  {s}", .{ line, try self.summary(a) }));
    }

    fn fail(self: *Fuzz, comptime fmt: []const u8, args: anytype) Fail {
        if (!self.verbose) return error.TestUnexpectedResult;
        std.debug.print("pane stack fuzz: seed {d} step {d}: " ++ fmt ++ "\n", .{ self.seed, self.step } ++ args);
        for (self.log.items) |line| std.debug.print("  {s}\n", .{line});
        const now = self.summary(self.arena.allocator()) catch "?";
        std.debug.print("  now: {s}\n", .{now});
        return error.TestUnexpectedResult;
    }

    // -- the operations, as the window does them ------------------------------

    /// `closeSplitPane`: the caret goes to the closed pane's neighbour over
    /// the panes on screen, or to the pane on show nearest it when that is a
    /// strip of a row left collapsed.
    fn close(self: *Fuzz, pane: *View) Allocator.Error!void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const handle = self.handleOf(pane).?;
        var next: ?*View = blk: {
            const n = (try self.gotoVisible(pane, .next)) orelse (try self.gotoVisible(pane, .previous));
            break :blk if (n == pane) null else n;
        };
        const before = try self.rowsNow(a);
        self.replaceTree(try self.tree.remove(self.gpa, handle));
        if (pane_stash.normalize(&self.tree)) |restored| {
            if (next == null) next = restored;
        }
        if (next) |candidate| {
            const id = try self.state.paneOnShow(candidate.id, before, try self.rowsNow(a));
            next = self.viewById(id) orelse candidate;
        }
        self.focused = next.?;
        try self.relayout();
    }

    /// `stashPane`: the caret moves only when the stashed pane had it, by the
    /// close's rule.
    fn stash(self: *Fuzz, pane: *View) Allocator.Error!void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var next: ?*View = if (self.focused == pane) blk: {
            const n = (try self.gotoVisible(pane, .previous)) orelse (try self.gotoVisible(pane, .next));
            break :blk if (n == pane) null else n;
        } else null;
        const before = if (next != null) try self.rowsNow(a) else null;
        pane_stash.mark(pane);
        _ = pane_stash.normalize(&self.tree);
        if (next) |candidate| if (before) |b| {
            const id = try self.state.paneOnShow(candidate.id, b, try self.rowsNow(a));
            next = self.viewById(id) orelse candidate;
        };
        if (next) |n| self.focused = n;
        try self.relayout();
    }

    /// `restorePane`: back in the slot it left; with `focus_it` it takes the
    /// caret too.
    fn unstash(self: *Fuzz, pane: *View, focus_it: bool) Allocator.Error!void {
        pane_stash.unmark(pane);
        try self.relayout();
        if (focus_it) try self.focus(pane);
    }

    fn split(self: *Fuzz, pane: *View, direction: Tree.Split.Direction) Allocator.Error!*View {
        const added = self.newView();
        var single = try Tree.init(self.gpa, added);
        defer single.deinit();
        self.replaceTree(try self.tree.split(self.gpa, self.handleOf(pane).?, direction, 0.5, &single));
        self.focused = added;
        try self.relayout();
        return added;
    }

    /// A close, then its undo, as `CloseUndo` does them: the stack state saved
    /// before the close (`stackSaved`), the pane split back in at its anchor,
    /// the rows of its tab put back (`restoreStackRows`), and the caret on the
    /// pane unless it came back as a strip.
    fn closeAndUndo(self: *Fuzz, pane: *View) Allocator.Error!void {
        try self.relayout();
        var saved = try self.state.saved();
        defer saved.deinit(self.gpa);
        var anchor = (try Anchor.capture(self.gpa, &self.tree, self.handleOf(pane).?)).?;
        defer anchor.deinit(self.gpa);
        try self.close(pane);

        const place = (try anchor.locate(self.gpa, &self.tree)) orelse
            Anchor.Placement{ .at = self.handleOf(self.focused).?, .exact = false };
        self.replaceTree(try anchor.restore(self.gpa, &self.tree, place.at, pane));
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        try self.state.noteRows(try self.rowsNow(a));
        var scope: std.ArrayListUnmanaged(Id) = .empty;
        var it = self.tree.iterator();
        while (it.next()) |e| try scope.append(a, e.view.id);
        const rows = try self.rowsNow(a);
        try self.state.restoreScoped(&saved, scope.items, rows);
        if (!try self.state.isMinimized(pane.id, rows)) self.focused = pane;
        try self.relayout();
    }

    /// A drag on a divider or a stack grip (`beginDividerRowDrag` /
    /// `startGripDrag`), through `deltas` from where it was pressed, the caret
    /// moving off a pane that folds away (`rowDragStepped`) and the window
    /// laid out after each step.
    fn drag(self: *Fuzz, target: DragTarget, deltas: []const f64) Allocator.Error!void {
        var rd = try stack_drag.RowDrag.begin(self.gpa, &self.state, target.row, target.boundary, target.offset);
        defer rd.deinit(&self.state);
        for (deltas) |delta| {
            const step = try rd.moved(&self.state, target.press + delta);
            if (step.restacked) if (rd.focusAfterRestack(&self.state, self.focused.id)) |id| {
                if (self.viewById(id)) |v| self.focused = v;
            };
            try self.relayout();
        }
    }
};

/// What a drag was pressed on, copied out of the layout it came from: the
/// gutter before item `boundary` of `row`, `offset` measuring the gesture's
/// positions from the row's start and `press` the gesture's position at the
/// press (a divider's centre in its split; a grip's moves run from 0).
const DragTarget = struct {
    kind: enum { divider, grip },
    row: layout.Row,
    boundary: usize,
    offset: f64,
    press: f64,
};

fn tuckedOf(a: Allocator, result: *const layout.Result) Allocator.Error![]Id {
    var out: std.ArrayListUnmanaged(Id) = .empty;
    var it = result.leaves.iterator();
    while (it.next()) |kv| if (kv.value_ptr.is_tucked) try out.append(a, kv.key_ptr.*);
    std.mem.sort(Id, out.items, {}, std.sort.asc(Id));
    return out.items;
}

fn lessString(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn has(ids: []const Id, id: Id) bool {
    return std.mem.indexOfScalar(Id, ids, id) != null;
}

/// `a` minus `b` minus `also`.
fn minus(a: Allocator, x: []const Id, y: []const Id, also: ?Id) Allocator.Error![]Id {
    var out: std.ArrayListUnmanaged(Id) = .empty;
    for (x) |id| if (!has(y, id) and id != also) try out.append(a, id);
    return out.items;
}

fn rowHas(row: []const []const Id, id: Id) bool {
    for (row) |item| if (has(item, id)) return true;
    return false;
}

fn keysEql(a: []const Id, b: []const Id) bool {
    return std.mem.eql(Id, a, b);
}

/// The collapsed rows as they were, by key: what a removal's excuses read.
const PinnedRow = struct { row: []const []const Id, key: []const Id, pin: layout.Pin };

fn pinnedRows(a: Allocator, f: *const Fuzz, rows: Rows) Allocator.Error![]PinnedRow {
    var out: std.ArrayListUnmanaged(PinnedRow) = .empty;
    for (rows) |row| {
        const key = try stack_state.keyOf(a, row);
        if (f.state.pin(key)) |p| try out.append(a, .{ .row = row, .key = key, .pin = p });
    }
    return out.items;
}

/// The strips a removal of `pane` brought out that the rules do not excuse
/// (Mac's close case): a row that lost its only pane on show brings out its
/// neighbour, a row that stopped being a row (or is not the same row any
/// more) lays out afresh, and a column that emptied into its row may bring
/// strips out where keeping them would minimize the focused pane.
fn unexcused(a: Allocator, f: *Fuzz, before: []const Id, pane: Id, rows_before: Rows, pinned: []const PinnedRow) Allocator.Error![]Id {
    const out = try minus(a, before, try f.tucked(a), pane);
    const rows_after = try f.rowsNow(a);
    var keys_before: std.ArrayListUnmanaged([]const Id) = .empty;
    for (rows_before) |row| try keys_before.append(a, try stack_state.keyOf(a, row));
    var keys_after: std.ArrayListUnmanaged([]const Id) = .empty;
    for (rows_after) |row| try keys_after.append(a, try stack_state.keyOf(a, row));

    var stray: std.ArrayListUnmanaged(Id) = .empty;
    outer: for (out) |id| {
        for (rows_after, keys_after.items) |row, key| {
            const known = for (keys_before.items) |k| {
                if (keysEql(k, key)) break true;
            } else false;
            if (!known and rowHas(row, f.focused.id) and rowHas(row, id)) continue :outer;
        }
        for (pinned) |pr| {
            if (!has(pr.key, id) or !has(pr.key, pane)) continue;
            var only = true;
            for (pr.pin.start..pr.pin.start + pr.pin.count) |i| {
                if (!has(pr.row[i], pane)) only = false;
            }
            const rest = try minus(a, pr.key, &.{}, pane);
            const survived = for (keys_after.items) |k| {
                if (keysEql(k, rest)) break true;
            } else false;
            if (only or !survived) continue :outer;
        }
        try stray.append(a, id);
    }
    return stray.items;
}

/// Whether an item of `row` holds panes of two different items of a collapsed
/// row `id` was a strip of.
fn mergesItems(row: []const []const Id, pinned: []const PinnedRow, id: Id) bool {
    for (pinned) |pr| {
        if (!has(pr.key, id)) continue;
        for (row) |item| {
            var home: ?usize = null;
            for (item) |pane| {
                const at = for (pr.row, 0..) |old, i| {
                    if (has(old, pane)) break i;
                } else continue;
                if (home) |h| if (h != at) return true;
                home = at;
            }
        }
    }
    return false;
}

fn pick(rng: *std.Random.SplitMix64, n: usize) usize {
    return @intCast(rng.next() % n);
}

fn runSeed(gpa: Allocator, seed: u64, verbose: bool) Fail!void {
    var rng = std.Random.SplitMix64.init(seed *% 7919 +% 17);
    var f: Fuzz = undefined;
    try f.init(gpa, 3 + pick(&rng, 4));
    defer f.deinit();
    f.seed = seed;
    f.verbose = verbose;
    if (seed % 2 == 1) f.gap = null;
    f.scale = scales[(seed / 2) % scales.len];
    try f.note("start", .{});

    for (0..steps) |step| {
        f.step = step;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const before = try f.tucked(a);
        const pins_before = try f.pins(a);
        const rows_before = try f.rowsNow(a);
        const pinned_before = try pinnedRows(a, &f, rows_before);
        const shown = try f.paneList(a, false);
        const op = rng.next() % 11;
        switch (op) {
            0, 1 => {
                // Drag a divider or a stack grip, 1-3 moves, sometimes let go
                // back where it was pressed.
                var grid = try f.layoutGrid();
                defer grid.deinit();
                const r = &grid.result;
                const n = r.dividers.items.len + r.stack_handles.items.len;
                if (n == 0) continue;
                const i = pick(&rng, n);
                const target: DragTarget = if (i < r.dividers.items.len) blk: {
                    const d = r.dividers.items[i];
                    break :blk .{
                        .kind = .divider,
                        .row = d.row,
                        .boundary = d.index,
                        .offset = d.node_frame.start(d.direction) - d.row.start,
                        .press = d.position,
                    };
                } else blk: {
                    const h = r.stack_handles.items[i - r.dividers.items.len];
                    break :blk .{
                        .kind = .grip,
                        .row = h.row,
                        .boundary = stack_drag.gripBoundary(h),
                        .offset = h.frame.start(h.direction) + h.position - h.row.start,
                        .press = 0,
                    };
                };
                const reaches = [_]f64{ 60, 200, 400, 700, 1000, 1400 };
                var deltas: [4]f64 = undefined;
                const moves = 1 + pick(&rng, 3);
                for (deltas[0..moves]) |*d| {
                    const sign: f64 = if (rng.next() % 2 == 0) -1 else 1;
                    d.* = sign * reaches[pick(&rng, reaches.len)] * f.scale;
                }
                const back = rng.next() % 3 == 0;
                var all = deltas[0..moves];
                if (back) {
                    deltas[moves] = 0;
                    all = deltas[0 .. moves + 1];
                }
                // The drag's row, copied: the layout it came from is freed
                // before the drag ends, as in the window.
                try f.drag(target, all);
                try f.note("drag {s} {d} by {any}", .{ @tagName(target.kind), i, all });
                if (back) {
                    const pins_after = try f.pins(a);
                    if (!std.mem.eql(u8, pins_before, pins_after))
                        return f.fail("a drag let go where it began changed a row: {s} -> {s}", .{ pins_before, pins_after });
                }
            },
            2 => {
                // Focus anything: a pane on show, or a strip.
                const pane = shown[pick(&rng, shown.len)];
                const was_tucked = has(before, pane.id);
                const on_screen = try f.onScreen(a);
                try f.focus(pane);
                try f.note("focus {s} {d}", .{ if (was_tucked) "strip" else "shown", pane.id });
                if (!has(on_screen, pane.id)) {
                    const after = try f.onScreen(a);
                    if (!std.mem.eql(Id, after, on_screen))
                        return f.fail("focusing a pane on show changed the strips: {any} -> {any}", .{ on_screen, after });
                }
                if (!was_tucked) {
                    const pins_after = try f.pins(a);
                    if (!std.mem.eql(u8, pins_before, pins_after))
                        return f.fail("focusing a pane on show changed a row: {s} -> {s}", .{ pins_before, pins_after });
                } else {
                    // Only panes of collapsed rows it is in come out.
                    for (try minus(a, before, try f.tucked(a), null)) |id| {
                        const own = for (pinned_before) |pr| {
                            if (has(pr.key, pane.id) and has(pr.key, id)) break true;
                        } else false;
                        if (!own) return f.fail("focusing strip {d} brought out {d} of another row", .{ pane.id, id });
                    }
                }
            },
            3, 4 => {
                // Close a pane on screen, or stash it.
                if (shown.len <= 2) continue;
                const pane = if (rng.next() % 2 == 0) f.focused else shown[pick(&rng, shown.len)];
                const stashing = op == 4;
                const was = if (pane == f.focused) "focused " else "";
                const kind = if (has(before, pane.id)) "strip" else "shown";
                if (stashing) try f.stash(pane) else try f.close(pane);
                try f.note("{s} {s}{d} ({s})", .{ if (stashing) "stash" else "close", was, pane.id, kind });
                const stray = try unexcused(a, &f, before, pane.id, rows_before, pinned_before);
                if (stray.len > 0) return f.fail("a {s} brought strips out: {any}", .{ if (stashing) "stash" else "close", stray });
            },
            5 => {
                // Split a pane on show, focusing the new pane.
                if (shown.len >= most_panes) continue;
                var candidates: std.ArrayListUnmanaged(*View) = .empty;
                for (shown) |v| if (!has(before, v.id)) try candidates.append(a, v);
                if (candidates.items.len == 0) continue;
                const pane = candidates.items[pick(&rng, candidates.items.len)];
                const directions = [_]Tree.Split.Direction{ .right, .right, .down, .left };
                const direction = directions[pick(&rng, directions.len)];
                const added = try f.split(pane, direction);
                try f.note("split {d} {s} -> {d}", .{ pane.id, @tagName(direction), added.id });
                const out = try minus(a, before, try f.tucked(a), null);
                if (out.len > 0) return f.fail("a split brought strips out: {any}", .{out});
            },
            6 => {
                // Close, then undo it: the row comes back as it was.
                if (shown.len <= 2) continue;
                const pane = if (rng.next() % 2 == 0) f.focused else shown[pick(&rng, shown.len)];
                try f.closeAndUndo(pane);
                try f.note("close+undo {d}", .{pane.id});
                const after = try f.tucked(a);
                if (!std.mem.eql(Id, after, before))
                    return f.fail("undoing the close of {d} did not bring the row back: {any} -> {any}", .{ pane.id, before, after });
            },
            7 => {
                // Swap two panes of one row, on show or strips (a rearrange
                // drop on the center of a pane, or of a strip - T2142). The
                // state trades them first, as `Window.noteStackSwap` does
                // before the swapped tree is installed.
                var choices: std.ArrayListUnmanaged([2]Id) = .empty;
                for (rows_before) |row| for (row, 0..) |x, i| for (row[i + 1 ..]) |y| {
                    if (x.len != 1 or y.len != 1) continue;
                    try choices.append(a, .{ x[0], y[0] });
                };
                if (choices.items.len == 0) continue;
                const pair = choices.items[pick(&rng, choices.items.len)];
                const first = rng.next() % 2;
                const dragged = f.viewById(pair[first]).?;
                const other = f.viewById(pair[1 - first]).?;
                const swapped = try f.tree.swap(gpa, f.handleOf(dragged).?, f.handleOf(other).?);
                try f.state.swap(pair[first], pair[1 - first]);
                f.replaceTree(swapped);
                // The pane dragged takes focus where it lands on show; dropped
                // into a strip's place it stays a strip, and the pane that
                // came out of the strip takes focus instead.
                const minimized = try f.tucked(a);
                if (!has(minimized, dragged.id)) {
                    try f.focus(dragged);
                } else if (!has(minimized, other.id)) {
                    try f.focus(other);
                } else try f.relayout();
                try f.note("swap {d} {d}", .{ dragged.id, other.id });
                const after = try f.tucked(a);
                if (after.len != before.len)
                    return f.fail("a swap changed how many panes are strips: {any} -> {any}", .{ before, after });
            },
            8 => {
                // Bring a stashed pane back, focused or not.
                const stashed = try f.paneList(a, true);
                if (stashed.len == 0 or shown.len >= most_panes) continue;
                const pane = stashed[pick(&rng, stashed.len)];
                const focus_it = rng.next() % 2 == 0;
                try f.unstash(pane, focus_it);
                try f.note("unstash {d}{s}", .{ pane.id, if (focus_it) " focused" else "" });
                const rows_after = try f.rowsNow(a);
                const out = try minus(a, before, try f.tucked(a), null);
                for (out) |id| {
                    // Unfocused, nothing comes out; focused, only panes of the
                    // rows it came back into. Either way a row whose items now
                    // hold pieces of two of its old items is not the row the
                    // user collapsed, and lays out afresh
                    // (`PaneStackState.originOf`, Mac's rule too).
                    const own = focus_it and for (rows_after) |row| {
                        if (rowHas(row, pane.id) and rowHas(row, id)) break true;
                    } else false;
                    const merged = for (rows_after) |row| {
                        if (rowHas(row, id) and mergesItems(row, pinned_before, id)) break true;
                    } else false;
                    if (!own and !merged) return f.fail("bringing back {d} brought strip {d} out", .{ pane.id, id });
                }
            },
            else => {
                f.width = widths[pick(&rng, widths.len)];
                try f.relayout();
                try f.note("resize to {d}", .{f.width});
            },
        }
        try checkWindow(&f);
    }
}

/// The rules every step leaves standing.
fn checkWindow(f: *Fuzz) Fail!void {
    if (pane_stash.isStashed(f.focused)) return f.fail("the focused pane {d} is stashed", .{f.focused.id});
    if (f.handleOf(f.focused) == null) return f.fail("the focused pane {d} is not in the tree", .{f.focused.id});
    var grid = try f.layoutGrid();
    defer grid.deinit();
    const r = &grid.result;
    const leaf = r.leaves.get(f.focused.id) orelse return f.fail("the focused pane {d} was not laid out", .{f.focused.id});
    if (leaf.is_tucked) return f.fail("the focused pane {d} is a strip", .{f.focused.id});

    // Every resizer lives in a gutter: on no pane on show, and on no strip.
    var it = r.leaves.iterator();
    while (it.next()) |kv| {
        const l = kv.value_ptr.*;
        const shown = if (l.is_tucked) (l.tab orelse continue) else l.frame;
        for (r.dividers.items) |d| try checkGutter(f, d.gutter, shown, kv.key_ptr.*);
        for (r.stack_handles.items) |h| try checkGutter(f, h.gutter, shown, kv.key_ptr.*);
        // Nothing on show is under its minimum width (there is always room
        // for at least one card: 700 DIP).
        if (!l.is_tucked and l.frame.w < 299 * f.scale)
            return f.fail("{d} is {d} wide", .{ kv.key_ptr.*, l.frame.w });
    }
}

fn checkGutter(f: *Fuzz, gutter: layout.Rect, rect: layout.Rect, id: Id) Fail!void {
    if (!(gutter.w > 0 and gutter.h > 0)) return f.fail("an empty gutter {any}", .{gutter});
    const overlap = layout.Rect.intersect(gutter, rect) orelse return;
    if (overlap.w >= 0.01 and overlap.h >= 0.01)
        return f.fail("a grip {any} overlaps {d} at {any}", .{ gutter, id, rect });
}

test "pane_stack_fuzz: random sequences keep strips minimized and the focus on show" {
    for (0..seeds) |seed| runSeed(testing.allocator, seed, false) catch |err| {
        // The same run again, telling what it did this time.
        runSeed(testing.allocator, seed, true) catch {};
        return err;
    };
}
