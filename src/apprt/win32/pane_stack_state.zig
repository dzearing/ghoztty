//! What decides which panes of a stacked row are on show (T2100): the
//! window's pane focus history, and the rows the user collapsed. A port of
//! Mac's `PaneStackState.swift` (86b7e3410, d26e51183, 2811a3043), pure and
//! with no OS imports, so its unit tests run in every app-runtime lane (the
//! hero_math.zig pattern). It is the `Provider` the window hands
//! `pane_stack_layout.compute`.
//!
//! Bringing a tucked pane forward is not an operation of its own: it is
//! FOCUSING the pane, however that happens (a click on its strip,
//! `goto_split`, the pane sidebar, `ghoztty://focus/…`), and the row slides to
//! show it. A row the user is not working in keeps showing the panes they last
//! looked at there, because those are still the most recent of its panes.
//!
//! Ephemeral: a relaunch starts from the focused pane, like the window does,
//! with every row side by side again where it fits.
//!
//! Not here yet: `rowsDidChange` and `paneOnShow` — carrying a collapse over a
//! tree change (a close, a split, a drop) — are T2083.
//!
//! Mac keeps four dictionaries keyed by a row's pane SET (pins, shares,
//! pinned items, capacity). Here they are one map from the row's key — its
//! panes' ids, sorted (`pane_stack_layout.Row.key`) — to an `Entry` with one
//! optional field per dictionary; an entry with every field empty is dropped.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const layout = @import("pane_stack_layout.zig");

const Id = layout.Id;
const Pin = layout.Pin;
const Range = layout.Range;
const Restack = layout.Restack;
const Row = layout.Row;
const Stack = layout.Stack;

/// What is remembered about one row, by its key.
const Entry = struct {
    /// The user collapsed it: which items are on show.
    pin: ?Pin = null,
    /// How the user sized the slots of its run, as shares of it. Ignored when
    /// the run has a different number of slots (the window grew or shrank
    /// past a card).
    shares: ?[]f64 = null,
    /// A pinned row's items in order, so a focus change knows which way to
    /// slide it. Kept by the layout, which is what knows the order.
    items: ?[][]Id = null,
    /// How many of a pinned row's items fit on show at once, as last laid out.
    capacity: ?usize = null,

    fn isEmpty(e: Entry) bool {
        return e.pin == null and e.shares == null and e.items == null and e.capacity == null;
    }
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: []const Id) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key));
    }
    pub fn eql(_: KeyContext, a: []const Id, b: []const Id) bool {
        return std.mem.eql(Id, a, b);
    }
};

const Map = std.HashMapUnmanaged([]const Id, Entry, KeyContext, std.hash_map.default_max_load_percentage);

/// How many panes the focus history remembers: far more than a window holds.
pub const capacity = 64;

/// Pane ids, most recently focused first, at most `capacity` of them.
pub const Recency = struct {
    buf: [capacity]Id = undefined,
    len: usize = 0,

    pub fn items(r: *const Recency) []const Id {
        return r.buf[0..r.len];
    }

    pub fn first(r: *const Recency) ?Id {
        return if (r.len > 0) r.buf[0] else null;
    }

    /// `id` to the front, once (Mac's `PaneStackState.noting`).
    pub fn note(r: *Recency, id: Id) void {
        const at = std.mem.indexOfScalar(Id, r.items(), id) orelse @min(r.len, capacity - 1);
        // Everything before where `id` was (or the oldest that falls off)
        // moves back one.
        std.mem.copyBackwards(Id, r.buf[1 .. at + 1], r.buf[0..at]);
        r.buf[0] = id;
        if (at == r.len) r.len += 1;
    }
};

/// One row's collapse and slot sizes, as a drag found them: every step of
/// the drag is replayed from this, so dragging back undoes what dragging
/// forward did. Owned; `deinit` it.
pub const Snapshot = struct {
    pin: ?Pin = null,
    shares: ?[]f64 = null,
    items: ?[][]Id = null,

    pub fn deinit(s: *Snapshot, gpa: Allocator) void {
        if (s.shares) |v| gpa.free(v);
        if (s.items) |v| freeItems(gpa, v);
        s.* = undefined;
    }
};

/// Every row's collapse, slot sizes and order: what an undo puts back along
/// with the tree it was taken with. Owned; `deinit` it.
pub const Saved = struct {
    map: Map = .empty,

    pub fn deinit(s: *Saved, gpa: Allocator) void {
        freeMap(gpa, &s.map);
        s.* = undefined;
    }
};

pub const PaneStackState = struct {
    gpa: Allocator,
    recency: Recency = .{},
    rows: Map = .empty,
    /// The stacked rows as last laid out on screen: where a strip being
    /// dragged lives. Owned copies.
    stacks: []Stack = &.{},
    /// A drag on a divider or stack grip is under way. Cards move faster
    /// while one is: the hand is already moving, and the layout should keep
    /// up.
    is_gesturing: bool = false,

    pub fn init(gpa: Allocator) PaneStackState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *PaneStackState) void {
        freeMap(self.gpa, &self.rows);
        freeStacks(self.gpa, self.stacks);
        self.* = undefined;
    }

    // -- focus ------------------------------------------------------------

    pub fn noteFocus(self: *PaneStackState, id: Id) void {
        self.bringOnShow(id);
        if (self.recency.first() != id) self.recency.note(id);
    }

    /// 0 for the focused pane, 1 for the one before it, …; null if never
    /// focused.
    pub fn rank(self: *const PaneStackState, id: Id) ?u32 {
        const i = std.mem.indexOfScalar(Id, self.recency.items(), id) orelse return null;
        return @intCast(i);
    }

    /// A pane minimized in a collapsed row comes back: the run grows to take
    /// it in, sharing the space out evenly, and only when that won't fit does
    /// a pane on the far edge minimize to make room. A pane already in the
    /// run stays put, even when the window is too small to show all of it:
    /// the layout shows the part around the focus.
    fn bringOnShow(self: *PaneStackState, id: Id) void {
        var it = self.rows.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const e = kv.value_ptr;
            const items = e.items orelse continue;
            if (std.mem.indexOfScalar(Id, key, id) == null) continue;
            const p = e.pin orelse continue;
            const index = itemIndex(items, id) orelse continue;
            if (index >= p.start and index < p.start + p.count) continue;
            const restored = p.restoring(index, e.capacity orelse p.count, items.len);
            if (restored == null or restored.?.count != p.count) self.clearShares(e);
            e.pin = restored;
            if (restored == null) self.clearItems(e);
        }
        self.prune();
    }

    // -- collapse ---------------------------------------------------------

    /// The collapse of the row whose sorted pane ids are `key`.
    pub fn pin(self: *const PaneStackState, key: []const Id) ?Pin {
        const e = self.rows.get(key) orelse return null;
        return e.pin;
    }

    /// The run slots' shares as the user sized them, by the row's key.
    pub fn sharesFor(self: *const PaneStackState, key: []const Id) ?[]const f64 {
        const e = self.rows.get(key) orelse return null;
        return e.shares;
    }

    /// Collapse or widen a row (a divider or stack grip dragged), as many
    /// times over as `times` (a drag that goes on squeezing).
    pub fn restack(self: *PaneStackState, row: Row, change: Restack, times: usize) Allocator.Error!void {
        const gpa = self.gpa;
        const key = try row.key(gpa);
        defer gpa.free(key);

        // Rows nest (a column is one item of the row beside it), and each
        // keeps its own collapse. A row that only partly overlaps this one is
        // one its panes have left: that pin is stale.
        var it = self.rows.iterator();
        while (it.next()) |kv| {
            const other = kv.key_ptr.*;
            if (kv.value_ptr.pin == null) continue;
            if (!intersects(other, key) or isSubset(other, key) or isSubset(key, other)) continue;
            kv.value_ptr.pin = null;
            self.clearItems(kv.value_ptr);
        }

        var run = row.run;
        var sizes: ?[]f64 = try gpa.dupe(f64, row.sizes);
        defer if (sizes) |s| gpa.free(s);
        var p: ?Pin = null;
        for (0..@max(1, times)) |_| {
            p = Pin.restacking(run, row.items.len, change);
            const next = p orelse break;
            run = .{ .lo = next.start, .hi = next.start + next.count - 1 };
            // The panes still on show keep the sizes they had; a pane coming
            // back gets an average slot.
            if (sizes) |s| {
                const restacked = try restackShares(gpa, s, change);
                gpa.free(s);
                sizes = restacked;
            }
        }

        const e = try self.entry(key);
        e.pin = p;
        self.clearItems(e);
        self.clearShares(e);
        if (p != null) {
            e.items = try dupeItems(gpa, row.items);
            e.shares = sizes;
            sizes = null;
        }
        self.prune();
    }

    /// What `change` makes of a run's slot sizes: the panes still on show
    /// keep theirs, a pane coming back gets an average slot, all normalised
    /// to shares. Null for no sizes. Caller frees.
    pub fn restackShares(gpa: Allocator, sizes: []const f64, change: Restack) Allocator.Error!?[]f64 {
        if (sizes.len == 0) return null;
        var list: std.ArrayListUnmanaged(f64) = .empty;
        errdefer list.deinit(gpa);
        try list.appendSlice(gpa, sizes);
        var total: f64 = 0;
        for (sizes) |s| total += s;
        const average = total / @as(f64, @floatFromInt(sizes.len));
        switch (change) {
            .collapse => |side| if (list.items.len > 1) switch (side) {
                .leading => _ = list.orderedRemove(0),
                .trailing => _ = list.pop(),
            },
            .expand => |side| switch (side) {
                .leading => try list.insert(gpa, 0, average),
                .trailing => try list.append(gpa, average),
            },
        }
        var sum: f64 = 0;
        for (list.items) |s| sum += s;
        if (!(sum > 0)) {
            list.deinit(gpa);
            return null;
        }
        for (list.items) |*s| s.* /= sum;
        return try list.toOwnedSlice(gpa);
    }

    /// Set how a stacked row's run is divided (a grip between cards dragged).
    pub fn resize(self: *PaneStackState, row: Row, shares: []const f64) Allocator.Error!void {
        const key = try row.key(self.gpa);
        defer self.gpa.free(key);
        const copy = try self.gpa.dupe(f64, shares);
        errdefer self.gpa.free(copy);
        const e = try self.entry(key);
        self.clearShares(e);
        e.shares = copy;
    }

    pub fn snapshot(self: *const PaneStackState, key: []const Id) Allocator.Error!Snapshot {
        const e = self.rows.get(key) orelse return .{};
        var s: Snapshot = .{ .pin = e.pin };
        errdefer s.deinit(self.gpa);
        if (e.shares) |v| s.shares = try self.gpa.dupe(f64, v);
        if (e.items) |v| s.items = try dupeItems(self.gpa, v);
        return s;
    }

    /// Put back one row's collapse, slot sizes and order from a snapshot
    /// (which stays the caller's).
    pub fn restoreSnapshot(self: *PaneStackState, key: []const Id, s: Snapshot) Allocator.Error!void {
        const shares = if (s.shares) |v| try self.gpa.dupe(f64, v) else null;
        errdefer if (shares) |v| self.gpa.free(v);
        const items = if (s.items) |v| try dupeItems(self.gpa, v) else null;
        errdefer if (items) |v| freeItems(self.gpa, v);
        const e = try self.entry(key);
        e.pin = s.pin;
        self.clearShares(e);
        self.clearItems(e);
        e.shares = shares;
        e.items = items;
        self.prune();
    }

    pub fn saved(self: *const PaneStackState) Allocator.Error!Saved {
        return .{ .map = try cloneMap(self.gpa, &self.rows) };
    }

    /// Put back every row as `s` had it (which stays the caller's).
    pub fn restore(self: *PaneStackState, s: *const Saved) Allocator.Error!void {
        const copy = try cloneMap(self.gpa, &s.map);
        freeMap(self.gpa, &self.rows);
        self.rows = copy;
    }

    // -- what the layout saw ------------------------------------------------

    /// The grid's stacked rows, as it lays them out.
    pub fn noteStacks(self: *PaneStackState, stacks: []const Stack) Allocator.Error!void {
        const copy = try self.gpa.alloc(Stack, stacks.len);
        var done: usize = 0;
        errdefer {
            for (copy[0..done]) |st| freeItems(self.gpa, st.items);
            self.gpa.free(copy);
        }
        for (stacks, 0..) |st, i| {
            copy[i] = st;
            copy[i].items = try dupeItems(self.gpa, st.items);
            done += 1;
        }
        freeStacks(self.gpa, self.stacks);
        self.stacks = copy;
        for (self.stacks) |st| try self.noteItems(st.items, st.fits);
    }

    /// The run a stacked row of exactly these items showed when last laid
    /// out: it sticks (`pane_stack_layout.stickyRun`).
    pub fn shownRun(self: *const PaneStackState, items: []const []const Id) ?Range {
        for (self.stacks) |st| if (itemsEql(st.items, items)) return st.run;
        return null;
    }

    /// The stacked row `id` is minimized in — the innermost, when its card is
    /// in more than one — as last laid out. Valid until the next
    /// `noteStacks`.
    pub fn stackMinimizing(self: *const PaneStackState, id: Id) ?Stack {
        var best: ?Stack = null;
        var best_n: usize = std.math.maxInt(usize);
        for (self.stacks) |st| {
            const index = itemIndex(st.items, id) orelse continue;
            if (st.run.contains(index)) continue;
            const n = paneCount(st.items);
            if (n < best_n) {
                best = st;
                best_n = n;
            }
        }
        return best;
    }

    /// The layout's current order of a pinned row's items, and how many of
    /// them fit on show.
    pub fn noteItems(self: *PaneStackState, items: []const []const Id, fits: usize) Allocator.Error!void {
        const key = try keyOf(self.gpa, items);
        defer self.gpa.free(key);
        const e = self.rows.getPtr(key) orelse return;
        if (e.pin == null) return;
        if (e.items == null or !itemsEql(e.items.?, items)) {
            const copy = try dupeItems(self.gpa, items);
            self.clearItems(e);
            e.items = copy;
        }
        e.capacity = fits;
    }

    /// Whether `id` is minimized in a collapsed row of `rows_in` (the window's
    /// rows, as `pane_stack_layout.rows` lists them).
    pub fn isMinimized(self: *const PaneStackState, id: Id, rows_in: []const []const []const Id) Allocator.Error!bool {
        for (rows_in) |row| {
            const key = try keyOf(self.gpa, row);
            defer self.gpa.free(key);
            const p = self.pin(key) orelse continue;
            const index = itemIndex(row, id) orelse continue;
            if (index < p.start or index >= p.start + p.count) return true;
        }
        return false;
    }

    /// Two panes traded places (a rearrange swap): a collapsed row keeps its
    /// shape with the other pane in it, wherever that came from. As on Mac, a
    /// row's collapse, order and sizes move with the panes; how many fit
    /// stays where it was until the next layout notes it again.
    pub fn swap(self: *PaneStackState, a: Id, b: Id) Allocator.Error!void {
        const gpa = self.gpa;
        var next: Map = .empty;
        errdefer freeMap(gpa, &next);
        var it = self.rows.iterator();
        while (it.next()) |kv| {
            const old = kv.value_ptr.*;
            if (old.pin != null or old.shares != null) {
                const rekeyed = try gpa.dupe(Id, kv.key_ptr.*);
                defer gpa.free(rekeyed);
                for (rekeyed) |*id| id.* = traded(id.*, a, b);
                std.mem.sort(Id, rekeyed, {}, std.sort.asc(Id));
                const e = try entryIn(gpa, &next, rekeyed);
                if (old.pin) |p| {
                    e.pin = p;
                    if (old.items) |items| {
                        const copy = try dupeItems(gpa, items);
                        for (copy) |item| for (item) |*id| {
                            id.* = traded(id.*, a, b);
                        };
                        e.items = copy;
                    }
                }
                if (old.shares) |s| e.shares = try gpa.dupe(f64, s);
            }
            if (old.capacity) |c| (try entryIn(gpa, &next, kv.key_ptr.*)).capacity = c;
        }
        freeMap(gpa, &self.rows);
        self.rows = next;
    }

    // -- the layout's view ------------------------------------------------

    /// The hooks `pane_stack_layout.compute` reads this state through.
    pub fn provider(self: *const PaneStackState) layout.Provider {
        return .{ .ctx = self, .rank = providerRank, .pin = providerPin, .shares = providerShares, .shown = providerShown };
    }

    fn providerRank(ctx: ?*const anyopaque, id: Id) ?u32 {
        const self: *const PaneStackState = @ptrCast(@alignCast(ctx.?));
        return self.rank(id);
    }
    fn providerPin(ctx: ?*const anyopaque, key: []const Id) ?Pin {
        const self: *const PaneStackState = @ptrCast(@alignCast(ctx.?));
        return self.pin(key);
    }
    fn providerShares(ctx: ?*const anyopaque, key: []const Id) ?[]const f64 {
        const self: *const PaneStackState = @ptrCast(@alignCast(ctx.?));
        return self.sharesFor(key);
    }
    fn providerShown(ctx: ?*const anyopaque, items: []const []const Id) ?Range {
        const self: *const PaneStackState = @ptrCast(@alignCast(ctx.?));
        return self.shownRun(items);
    }

    // -- bookkeeping ------------------------------------------------------

    fn entry(self: *PaneStackState, key: []const Id) Allocator.Error!*Entry {
        return entryIn(self.gpa, &self.rows, key);
    }

    fn clearShares(self: *PaneStackState, e: *Entry) void {
        if (e.shares) |v| self.gpa.free(v);
        e.shares = null;
    }

    fn clearItems(self: *PaneStackState, e: *Entry) void {
        if (e.items) |v| freeItems(self.gpa, v);
        e.items = null;
    }

    /// Drop entries that remember nothing.
    fn prune(self: *PaneStackState) void {
        while (true) {
            var it = self.rows.iterator();
            const empty = while (it.next()) |kv| {
                if (kv.value_ptr.isEmpty()) break kv.key_ptr.*;
            } else return;
            _ = self.rows.remove(empty);
            self.gpa.free(empty);
        }
    }
};

/// A row's key: its panes' ids, sorted. Caller frees.
pub fn keyOf(gpa: Allocator, items: []const []const Id) Allocator.Error![]Id {
    return (Row{ .items = items, .run = .{ .lo = 0, .hi = 0 } }).key(gpa);
}

fn entryIn(gpa: Allocator, map: *Map, key: []const Id) Allocator.Error!*Entry {
    if (map.getPtr(key)) |e| return e;
    const owned = try gpa.dupe(Id, key);
    errdefer gpa.free(owned);
    const gop = try map.getOrPut(gpa, owned);
    gop.value_ptr.* = .{};
    return gop.value_ptr;
}

fn traded(id: Id, a: Id, b: Id) Id {
    return if (id == a) b else if (id == b) a else id;
}

fn itemIndex(items: []const []const Id, id: Id) ?usize {
    for (items, 0..) |item, i| if (std.mem.indexOfScalar(Id, item, id) != null) return i;
    return null;
}

fn paneCount(items: []const []const Id) usize {
    var n: usize = 0;
    for (items) |item| n += item.len;
    return n;
}

fn itemsEql(a: []const []const Id, b: []const []const Id) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(Id, x, y)) return false;
    return true;
}

/// Sorted, duplicate-free id lists.
fn intersects(a: []const Id, b: []const Id) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] == b[j]) return true;
        if (a[i] < b[j]) i += 1 else j += 1;
    }
    return false;
}

fn isSubset(a: []const Id, b: []const Id) bool {
    var j: usize = 0;
    for (a) |x| {
        while (j < b.len and b[j] < x) j += 1;
        if (j == b.len or b[j] != x) return false;
        j += 1;
    }
    return true;
}

fn dupeItems(gpa: Allocator, items: []const []const Id) Allocator.Error![][]Id {
    const out = try gpa.alloc([]Id, items.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |item| gpa.free(item);
        gpa.free(out);
    }
    for (items, 0..) |item, i| {
        out[i] = try gpa.dupe(Id, item);
        done += 1;
    }
    return out;
}

fn freeItems(gpa: Allocator, items: []const []const Id) void {
    for (items) |item| gpa.free(item);
    gpa.free(items);
}

fn freeStacks(gpa: Allocator, stacks: []Stack) void {
    for (stacks) |st| freeItems(gpa, st.items);
    gpa.free(stacks);
}

fn freeEntry(gpa: Allocator, e: Entry) void {
    if (e.shares) |v| gpa.free(v);
    if (e.items) |v| freeItems(gpa, v);
}

fn freeMap(gpa: Allocator, map: *Map) void {
    var it = map.iterator();
    while (it.next()) |kv| {
        freeEntry(gpa, kv.value_ptr.*);
        gpa.free(kv.key_ptr.*);
    }
    map.deinit(gpa);
}

fn cloneMap(gpa: Allocator, map: *const Map) Allocator.Error!Map {
    var out: Map = .empty;
    errdefer freeMap(gpa, &out);
    var it = map.iterator();
    while (it.next()) |kv| {
        const e = try entryIn(gpa, &out, kv.key_ptr.*);
        const src = kv.value_ptr.*;
        e.pin = src.pin;
        e.capacity = src.capacity;
        if (src.shares) |v| e.shares = try gpa.dupe(f64, v);
        if (src.items) |v| e.items = try dupeItems(gpa, v);
    }
    return out;
}

// -- tests: Mac's PaneStackStateTests (the cases without rowsDidChange,
// which are T2083's) and the PaneLayoutTests cases that exercise this type.

fn singles(comptime n: usize, ids: *const [n]Id) [n][]const Id {
    var out: [n][]const Id = undefined;
    for (&out, 0..) |*o, i| o.* = ids[i .. i + 1];
    return out;
}

fn expectPin(state: *const PaneStackState, key: []const Id, want: ?Pin) !void {
    const got = state.pin(key);
    if (!Pin.eql(got, want)) {
        std.debug.print("pin for {any}: got {any}, want {any}\n", .{ key, got, want });
        return error.TestExpectedEqual;
    }
}

test "pane_stack_state: focus history puts the newest first, once" {
    var r: Recency = .{};
    r.note(1);
    r.note(2);
    try testing.expectEqualSlices(Id, &.{ 2, 1 }, r.items());
    r.note(1);
    try testing.expectEqualSlices(Id, &.{ 1, 2 }, r.items());
    var empty: Recency = .{};
    empty.note(1);
    try testing.expectEqualSlices(Id, &.{1}, empty.items());
}

test "pane_stack_state: focus history keeps the newest 64" {
    var r: Recency = .{};
    for (0..100) |i| r.note(@intCast(i));
    try testing.expectEqual(@as(usize, capacity), r.len);
    try testing.expectEqual(@as(Id, 99), r.items()[0]);
    try testing.expectEqual(@as(Id, 36), r.items()[capacity - 1]);
    // An old one noted again comes to the front without growing the list.
    r.note(50);
    try testing.expectEqual(@as(usize, capacity), r.len);
    try testing.expectEqual(@as(Id, 50), r.items()[0]);
    try testing.expectEqual(@as(Id, 99), r.items()[1]);
}

test "pane_stack_state: rank is the place in the focus history" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    state.noteFocus(7);
    state.noteFocus(8);
    try testing.expectEqual(@as(?u32, 0), state.rank(8));
    try testing.expectEqual(@as(?u32, 1), state.rank(7));
    try testing.expectEqual(@as(?u32, null), state.rank(9));
}

test "pane_stack_state: a collapse keeps the sizes of the panes still on show" {
    const third: f64 = 1.0 / 3.0;
    const collapsed = (try PaneStackState.restackShares(testing.allocator, &.{ 300, 600, 300 }, .{ .collapse = .trailing })).?;
    defer testing.allocator.free(collapsed);
    try testing.expectEqual(@as(usize, 2), collapsed.len);
    try testing.expectApproxEqAbs(third, collapsed[0], 1e-12);
    try testing.expectApproxEqAbs(2 * third, collapsed[1], 1e-12);
    const expanded = (try PaneStackState.restackShares(testing.allocator, &.{ 400, 400 }, .{ .expand = .leading })).?;
    defer testing.allocator.free(expanded);
    try testing.expectEqual(@as(usize, 3), expanded.len);
    for (expanded) |s| try testing.expectApproxEqAbs(third, s, 1e-12);
    try testing.expect(try PaneStackState.restackShares(testing.allocator, &.{}, .{ .collapse = .leading }) == null);
}

test "pane_stack_state: collapsing a row leaves the rows nested in it alone" {
    // A | (B over C): the column is one item of the row.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const a: Id = 1;
    const b: Id = 2;
    const c: Id = 3;
    try state.restack(.{ .items = &.{ &.{b}, &.{c} }, .run = .{ .lo = 0, .hi = 1 } }, .{ .collapse = .trailing }, 1);
    try state.restack(.{ .items = &.{ &.{a}, &.{ b, c } }, .run = .{ .lo = 0, .hi = 1 } }, .{ .collapse = .trailing }, 1);
    try expectPin(&state, &.{ b, c }, .{ .start = 0, .count = 1 });
    try expectPin(&state, &.{ a, b, c }, .{ .start = 0, .count = 1 });
}

test "pane_stack_state: a row only partly overlapping a restacked one loses its stale pin" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    // 1 | 2 | 3 collapsed; then 3 has left it for a row 3 | 4 that collapses.
    try state.restack(.{ .items = &.{ &.{1}, &.{2}, &.{3} }, .run = .{ .lo = 0, .hi = 2 } }, .{ .collapse = .trailing }, 1);
    try state.restack(.{ .items = &.{ &.{3}, &.{4} }, .run = .{ .lo = 0, .hi = 1 } }, .{ .collapse = .trailing }, 1);
    try expectPin(&state, &.{ 1, 2, 3 }, null);
    try expectPin(&state, &.{ 3, 4 }, .{ .start = 0, .count = 1 });
}

test "pane_stack_state: a swap keeps the row collapsed" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const a: Id = 1;
    const b: Id = 2;
    const c: Id = 3;
    const elsewhere: Id = 9;
    try state.restack(.{ .items = &.{ &.{a}, &.{b}, &.{c} }, .run = .{ .lo = 0, .hi = 2 } }, .{ .collapse = .trailing }, 1);
    try expectPin(&state, &.{ a, b, c }, .{ .start = 0, .count = 2 });

    // c (tucked) swapped with a pane from another row: that pane is now in
    // this row's place, and the row is still collapsed.
    try state.swap(c, elsewhere);
    try expectPin(&state, &.{ a, b, elsewhere }, .{ .start = 0, .count = 2 });
    try expectPin(&state, &.{ a, b, c }, null);
    // Its order followed the swap, so focusing the pane that came in finds it.
    const items = state.rows.get(&.{ a, b, elsewhere }).?.items.?;
    try testing.expectEqualSlices(Id, &.{elsewhere}, items[2]);
}

test "pane_stack_state: a drag that goes on squeezing collapses once per step" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4 };
    const items = singles(4, &ids);
    try state.restack(.{ .items = &items, .run = .{ .lo = 0, .hi = 3 }, .sizes = &.{ 1, 1, 1, 1 } }, .{ .collapse = .trailing }, 2);
    try expectPin(&state, &ids, .{ .start = 0, .count = 2 });
    const shares = state.sharesFor(&ids).?;
    try testing.expectEqual(@as(usize, 2), shares.len);
    try testing.expectApproxEqAbs(@as(f64, 0.5), shares[0], 1e-12);
    // Widened all the way, the row is side by side again and forgets its sizes.
    try state.restack(.{ .items = &items, .run = .{ .lo = 0, .hi = 1 }, .sizes = &.{ 1, 1 } }, .{ .expand = .trailing }, 2);
    try expectPin(&state, &ids, null);
    try testing.expect(state.sharesFor(&ids) == null);
    try testing.expectEqual(@as(u32, 0), state.rows.count());
}

/// a b [c] d e, collapsed by hand to c alone on show.
fn collapsedToOne(state: *PaneStackState, items: []const []const Id) !void {
    try state.restack(.{ .items = items, .run = .{ .lo = 1, .hi = 3 }, .sizes = &.{ 1, 1, 1 } }, .{ .collapse = .leading }, 1);
    try state.restack(.{ .items = items, .run = .{ .lo = 2, .hi = 3 }, .sizes = &.{ 1, 1 } }, .{ .collapse = .trailing }, 1);
}

test "pane_stack_state: collapsed to one by hand" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5 };
    const items = singles(5, &ids);
    try collapsedToOne(&state, &items);
    try expectPin(&state, &ids, .{ .start = 2, .count = 1 });
    try testing.expect(try state.isMinimized(1, &.{&items}));
    try testing.expect(!try state.isMinimized(3, &.{&items}));
    try testing.expect(!try state.isMinimized(42, &.{&items}));
}

test "pane_stack_state: focusing a minimized pane with no room slides the run to it" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4 };
    const items = singles(4, &ids);
    try state.restack(.{ .items = &items, .run = .{ .lo = 0, .hi = 2 } }, .{ .collapse = .trailing }, 1);
    try state.noteItems(&items, 2);
    state.noteFocus(ids[3]);
    // b minimizes on the far edge.
    try expectPin(&state, &ids, .{ .start = 2, .count = 2 });
}

test "pane_stack_state: focusing a minimized pane with room restores the split" {
    // Two panes, one minimized: clicking it brings the split back.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2 };
    const items = singles(2, &ids);
    try state.restack(.{ .items = &items, .run = .{ .lo = 0, .hi = 1 }, .sizes = &.{ 600, 600 } }, .{ .collapse = .trailing }, 1);
    try expectPin(&state, &ids, .{ .start = 0, .count = 1 });
    try state.noteItems(&items, 2);
    state.noteFocus(ids[1]);
    try expectPin(&state, &ids, null);
    try testing.expect(state.sharesFor(&ids) == null);
}

test "pane_stack_state: focusing a pane already in the run changes nothing" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4 };
    const items = singles(4, &ids);
    try state.restack(.{ .items = &items, .run = .{ .lo = 0, .hi = 3 }, .sizes = &.{ 1, 1, 1, 1 } }, .{ .collapse = .trailing }, 2);
    try state.noteItems(&items, 4);
    state.noteFocus(ids[1]);
    try expectPin(&state, &ids, .{ .start = 0, .count = 2 });
    try testing.expect(state.sharesFor(&ids) != null);
}

test "pane_stack_state: a focus before any layout uses the run as its room" {
    // No capacity noted yet: the run's own size is the room, so the run
    // slides rather than grows.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3 };
    const items = singles(3, &ids);
    try state.restack(.{ .items = &items, .run = .{ .lo = 0, .hi = 2 }, .sizes = &.{ 1, 1, 1 } }, .{ .collapse = .trailing }, 1);
    state.noteFocus(3);
    try expectPin(&state, &ids, .{ .start = 1, .count = 2 });
    // Same number of slots: the sizes are kept.
    try testing.expect(state.sharesFor(&ids) != null);
}

test "pane_stack_state: a snapshot replays a drag from where it started" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3 };
    const items = singles(3, &ids);
    var snap = try state.snapshot(&ids);
    defer snap.deinit(testing.allocator);
    try state.restack(.{ .items = &items, .run = .{ .lo = 0, .hi = 2 }, .sizes = &.{ 1, 1, 1 } }, .{ .collapse = .trailing }, 1);
    try expectPin(&state, &ids, .{ .start = 0, .count = 2 });
    try state.restoreSnapshot(&ids, snap);
    try expectPin(&state, &ids, null);
    try testing.expectEqual(@as(u32, 0), state.rows.count());

    // And a snapshot of a collapsed row brings the collapse back.
    try state.restack(.{ .items = &items, .run = .{ .lo = 0, .hi = 2 }, .sizes = &.{ 1, 1, 1 } }, .{ .collapse = .leading }, 1);
    var collapsed = try state.snapshot(&ids);
    defer collapsed.deinit(testing.allocator);
    state.noteFocus(1);
    try expectPin(&state, &ids, .{ .start = 0, .count = 2 });
    try state.restoreSnapshot(&ids, collapsed);
    try expectPin(&state, &ids, .{ .start = 1, .count = 2 });
}

test "pane_stack_state: saved puts every row back, and can be restored twice" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3 };
    const items = singles(3, &ids);
    try state.restack(.{ .items = &items, .run = .{ .lo = 0, .hi = 2 }, .sizes = &.{ 1, 2, 1 } }, .{ .collapse = .trailing }, 1);
    try state.noteItems(&items, 3);
    var s = try state.saved();
    defer s.deinit(testing.allocator);
    for (0..2) |_| {
        state.noteFocus(3);
        try expectPin(&state, &ids, null);
        try state.restore(&s);
        try expectPin(&state, &ids, .{ .start = 0, .count = 2 });
        try testing.expectEqual(@as(?usize, 3), state.rows.get(&ids).?.capacity);
    }
}

test "pane_stack_state: resize sets the run's shares" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const items = [_][]const Id{ &.{2}, &.{1} };
    try state.resize(.{ .items = &items, .run = .{ .lo = 0, .hi = 1 } }, &.{ 0.3, 0.7 });
    try testing.expectEqualSlices(f64, &.{ 0.3, 0.7 }, state.sharesFor(&.{ 1, 2 }).?);
    try state.resize(.{ .items = &items, .run = .{ .lo = 0, .hi = 1 } }, &.{ 0.6, 0.4 });
    try testing.expectEqualSlices(f64, &.{ 0.6, 0.4 }, state.sharesFor(&.{ 1, 2 }).?);
}

test "pane_stack_state: the stacks as laid out answer the shown run and the minimizing stack" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    // An outer row 1 | (2 3 4) with the column item minimized, and inside it
    // 2 | 3 | 4 showing only 2.
    const outer = [_][]const Id{ &.{1}, &.{ 2, 3, 4 } };
    const inner = [_][]const Id{ &.{2}, &.{3}, &.{4} };
    {
        // The layout's own arrays go away after noteStacks.
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const stacks = try a.alloc(Stack, 2);
        stacks[0] = .{ .frame = .{}, .direction = .horizontal, .items = try dupeItems(a, &outer), .run = .{ .lo = 0, .hi = 0 }, .fits = 1 };
        stacks[1] = .{ .frame = .{}, .direction = .horizontal, .items = try dupeItems(a, &inner), .run = .{ .lo = 0, .hi = 0 }, .fits = 1 };
        try state.noteStacks(stacks);
    }
    try testing.expectEqual(@as(?Range, .{ .lo = 0, .hi = 0 }), state.shownRun(&inner));
    try testing.expectEqual(@as(?Range, null), state.shownRun(&.{ &.{2}, &.{3} }));
    // 3 is minimized in both: the innermost wins.
    try testing.expectEqual(@as(usize, 3), state.stackMinimizing(3).?.items.len);
    // 2 is on show in the inner stack but minimized in the outer.
    try testing.expectEqual(@as(usize, 2), state.stackMinimizing(2).?.items.len);
    try testing.expect(state.stackMinimizing(1) == null);
    // A second layout replaces the first.
    try state.noteStacks(&.{});
    try testing.expectEqual(@as(?Range, null), state.shownRun(&inner));
}

test "pane_stack_state: noteItems keeps a pinned row's order and room, and ignores the rest" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3 };
    try state.noteItems(&singles(3, &ids), 2);
    try testing.expectEqual(@as(u32, 0), state.rows.count());
    try state.restack(.{ .items = &singles(3, &ids), .run = .{ .lo = 0, .hi = 2 } }, .{ .collapse = .trailing }, 1);
    const reordered = [_][]const Id{ &.{3}, &.{1}, &.{2} };
    try state.noteItems(&reordered, 2);
    const e = state.rows.get(&ids).?;
    try testing.expectEqual(@as(?usize, 2), e.capacity);
    try testing.expect(itemsEql(e.items.?, &reordered));
}

test "pane_stack_state: is the provider the layout reads" {
    // 1 | 2 | 3 | 4 in 1400 DIP: fits side by side until the user collapses
    // the row; then focusing a strip brings it on show.
    const N = layout.Node;
    const nodes = [_]N{
        .{ .leaf = 1 }, .{ .leaf = 2 }, .{ .leaf = 3 }, .{ .leaf = 4 },
        .{ .split = .{ .direction = .horizontal, .ratio = 0.5, .left = 2, .right = 3 } },
        .{ .split = .{ .direction = .horizontal, .ratio = 1.0 / 3.0, .left = 1, .right = 4 } },
        .{ .split = .{ .direction = .horizontal, .ratio = 0.25, .left = 0, .right = 5 } },
    };
    const metrics: layout.Metrics = .{ .gap = 10, .peek = 36, .minimum_width = 300, .minimum_height = 200 };
    const rect: layout.Rect = .{ .w = 1400, .h = 600 };
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    state.noteFocus(1);

    var r0 = try layout.compute(testing.allocator, &nodes, 6, rect, metrics, state.provider());
    defer r0.deinit();
    try testing.expectEqual(@as(usize, 0), r0.stacks.items.len);
    try testing.expect(r0.dividers.items.len > 0);
    try testing.expectEqual(@as(usize, 4), r0.dividers.items[0].row.items.len);

    // The user drags the last divider past 4's minimum, twice over.
    try state.restack(r0.dividers.items[0].row, .{ .collapse = .trailing }, 2);
    var r1 = try layout.compute(testing.allocator, &nodes, 6, rect, metrics, state.provider());
    defer r1.deinit();
    try state.noteStacks(r1.stacks.items);
    try testing.expectEqual(@as(usize, 1), r1.stacks.items.len);
    try testing.expectEqual(Range{ .lo = 0, .hi = 1 }, r1.stacks.items[0].run);
    try testing.expect(r1.leaf(4).?.is_tucked);
    try testing.expect(r1.leaf(3).?.is_tucked);

    // Focusing the far strip brings it on show; the room is all four.
    state.noteFocus(4);
    var r2 = try layout.compute(testing.allocator, &nodes, 6, rect, metrics, state.provider());
    defer r2.deinit();
    try testing.expect(!r2.leaf(4).?.is_tucked);
    try testing.expectEqual(@as(usize, 0), r2.stacks.items.len);
}
