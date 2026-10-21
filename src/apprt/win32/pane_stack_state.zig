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
//! A collapse is carried over every tree change (a close, a stash, a split, a
//! drop, a move) by `rowsDidChange` (T2083, Mac 3090ac2aa, d26e51183 and
//! 2811a3043's hardening of it). Mac calls it from the controller's tree
//! setter; the win32 window has a dozen places that replace a tab's tree, so
//! it hands `noteRows` every tab's rows as it lays out instead, and the change
//! is whatever differs from the rows it saw last.
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

/// Every row of a window, outermost first, as its items' leaf ids
/// (`pane_stack_layout.rows`, over each tab).
pub const Rows = []const []const []const Id;

/// A collapse `rowsDidChange` carries over (Mac's `Carried`): the row it
/// became, by key and items, its pin and slot shares, and how many fit on
/// show as the row it came from last knew. Allocated in the caller's arena.
const Carried = struct {
    key: []const Id,
    items: []const []const Id,
    pin: ?Pin,
    shares: ?[]const f64,
    capacity: ?usize,
};

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
    /// The rows `noteRows` saw last, and the arena they live in.
    seen: ?std.heap.ArenaAllocator = null,
    seen_rows: Rows = &.{},

    pub fn init(gpa: Allocator) PaneStackState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *PaneStackState) void {
        freeMap(self.gpa, &self.rows);
        freeStacks(self.gpa, self.stacks);
        if (self.seen) |*a| a.deinit();
        self.* = undefined;
    }

    // -- focus ------------------------------------------------------------

    pub fn noteFocus(self: *PaneStackState, id: Id) void {
        self.bringOnShow(id, null);
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
    /// the layout shows the part around the focus. Only the rows `only` names,
    /// when it is given.
    fn bringOnShow(self: *PaneStackState, id: Id, only: ?[]const Carried) void {
        var it = self.rows.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const e = kv.value_ptr;
            const items = e.items orelse continue;
            if (std.mem.indexOfScalar(Id, key, id) == null) continue;
            if (only) |carried| if (findCarried(carried, key) == null) continue;
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

    // -- tree changes -------------------------------------------------------

    /// The window's rows as they are now. When they differ from the ones seen
    /// last, the tree changed in between: `rowsDidChange` carries the
    /// collapses over. The first rows seen are only noted.
    pub fn noteRows(self: *PaneStackState, now: Rows) Allocator.Error!void {
        if (self.seen != null and rowsEql(self.seen_rows, now)) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const copy = try dupeRows(arena.allocator(), now);
        if (self.seen) |*old| {
            try self.rowsDidChange(self.seen_rows, now);
            old.deinit();
        }
        self.seen = arena;
        self.seen_rows = copy;
    }

    /// The window's rows changed, from `old` to `new`. Adding or removing a
    /// pane never brings a collapsed row's minimized panes back out. A row
    /// that panes left - closed, stashed, moved out of it - stays collapsed
    /// without them (`Pin.removing`): the panes still on show take the space.
    /// A row that panes joined - a split, a drop, a restore - stays collapsed
    /// with them (`Pin.adding`): one that lands beside the panes on show is on
    /// show too, and one among the minimized ones is minimized with them until
    /// it is focused. A column that emptied down to a row of its own merges
    /// into the row around it, each of its pieces keeping the column's place
    /// (`origin`); a row nested in it that was collapsed too keeps what it
    /// minimized (`intersecting`).
    ///
    /// A row that is not on screen any more has no collapse: what it became
    /// carries it. Undo brings the old one back exactly, from a `Saved` taken
    /// with the tree, not from a collapse kept under the old row's panes,
    /// which a later change could make stale and bring back over panes the
    /// user has had on show since.
    pub fn rowsDidChange(self: *PaneStackState, old: Rows, new: Rows) Allocator.Error!void {
        const gpa = self.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const carried = try self.carriedRows(a, old, new);
        for (carried) |c| {
            // Copied before the entry is looked up: an insert moves entries.
            const shares = if (c.shares) |v| try gpa.dupe(f64, v) else null;
            errdefer if (shares) |v| gpa.free(v);
            const items = if (c.pin != null) try dupeItems(gpa, c.items) else null;
            errdefer if (items) |v| freeItems(gpa, v);
            const e = try self.entry(c.key);
            e.pin = c.pin;
            self.clearShares(e);
            e.shares = shares;
            self.clearItems(e);
            e.items = items;
            e.capacity = if (c.pin != null) c.capacity else null;
        }

        // Rows off screen keep nothing. The rows of every tab are on screen
        // here: one state serves the whole window.
        const new_keys = try keysOf(a, new);
        var gone: std.ArrayListUnmanaged([]const Id) = .empty;
        var it = self.rows.iterator();
        while (it.next()) |kv| {
            if (!containsKey(new_keys, kv.key_ptr.*)) try gone.append(a, kv.key_ptr.*);
        }
        for (gone.items) |key| {
            const kv = self.rows.fetchRemove(key).?;
            freeEntry(gpa, kv.value);
            gpa.free(kv.key);
        }

        // The focus can land before the tree change is seen (a pane focused
        // as it joins a row): it comes on show as it would have after.
        if (self.recency.first()) |focused| self.bringOnShow(focused, carried);
        self.prune();
    }

    /// Where the caret goes when the rows change from `old` to `new` (a
    /// close): `candidate`, unless that is minimized in a row left collapsed,
    /// in which case the pane on show there nearest it, last focused first.
    /// Focusing a minimized pane would bring it back out.
    pub fn paneOnShow(self: *const PaneStackState, candidate: Id, old: Rows, new: Rows) Allocator.Error!Id {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const carried = try self.carriedRows(a, old, new);
        var id = candidate;
        for (new) |row| {
            const key = try keyOf(a, row);
            const p = (if (findCarried(carried, key)) |i| carried[i].pin else self.pin(key)) orelse continue;
            const index = itemIndex(row, id) orelse continue;
            const target = std.math.clamp(index, p.start, p.start + p.count - 1);
            if (target == index) continue;
            var best: ?Id = null;
            var best_rank: u32 = std.math.maxInt(u32);
            for (row[target]) |pane| {
                const r = self.rank(pane) orelse std.math.maxInt(u32);
                if (best == null or r < best_rank) {
                    best = pane;
                    best_rank = r;
                }
            }
            id = best orelse id;
        }
        return id;
    }

    /// The collapses `rowsDidChange` carries over: for each collapsed row of
    /// `old`, the row of `new` it became - the same items with some gone,
    /// some joined, or in a new order.
    fn carriedRows(self: *const PaneStackState, a: Allocator, old: Rows, new: Rows) Allocator.Error![]Carried {
        const new_keys = try keysOf(a, new);
        var result: std.ArrayListUnmanaged(Carried) = .empty;
        for (old) |items| {
            const key = try keyOf(a, items);
            const e = self.rows.get(key) orelse continue;
            const p = e.pin orelse continue;
            for (new, new_keys) |row, row_key| {
                const origin = (try self.originOf(a, row, row_key, items, key, e.items, new_keys)) orelse continue;
                const carried = p.carrying(origin);
                const sizes = try carriedShares(a, p, carried, origin, e.shares);
                if (findCarried(result.items, row_key)) |i| {
                    // A row carried into twice: a collapsed row, and a
                    // collapsed row nested in one of its items whose column
                    // emptied into it. What either minimized stays
                    // minimized: the run is what both show.
                    const earlier = &result.items[i];
                    const both = intersecting(earlier.pin, carried, row.len);
                    if (!Pin.eql(both, earlier.pin)) earlier.shares = null;
                    earlier.pin = both;
                } else {
                    try result.append(a, .{ .key = row_key, .items = row, .pin = carried, .shares = sizes, .capacity = e.capacity });
                }
                break;
            }
        }
        return result.items;
    }

    /// Each of `row`'s items' index in `items`, a collapsed row before the
    /// change, or null for an item that joined it - when `row` is what became
    /// of `items`: its panes a strict subset or superset of theirs, every new
    /// item made of the panes of ONE old item, in order, from at least two of
    /// them (all of it from one is a row across that item), or the same items
    /// reordered. Null when it is some other row. A row that already has a
    /// collapse of its own keeps that one.
    ///
    /// An old item may become several new ones: a column that a close
    /// emptied down to a row of its own merges into the row around it, and
    /// each of its pieces keeps the item's place - on show if it was, a strip
    /// if it was minimized.
    ///
    /// A reorder is measured from `order`, the order the collapse was last
    /// laid out in, not from `items`: a swap (`swap`) trades the two panes
    /// there before the tree changes, because the panes on show are the
    /// slots, not the panes. A pane moved within the row is followed.
    fn originOf(
        self: *const PaneStackState,
        a: Allocator,
        row: []const []const Id,
        row_key: []const Id,
        items: []const []const Id,
        key: []const Id,
        order: ?[][]Id,
        new_keys: []const []const Id,
    ) Allocator.Error!?[]?usize {
        if (std.mem.eql(Id, row_key, key)) {
            // Reordered: the same items, in another order.
            const o = order orelse return null;
            const before = try sortedItems(a, o);
            const after = try sortedItems(a, row);
            if (before.len != after.len or itemsEql(before, after)) return null;
            const out = try a.alloc(?usize, after.len);
            for (after, out) |item, *slot| slot.* = indexOfItem(before, item) orelse return null;
            for (before) |item| if (indexOfItem(after, item) == null) return null;
            return out;
        }
        // The row itself is still there: it is not what this one became.
        if (containsKey(new_keys, key)) return null;
        // A row that already has a collapse of its own keeps it.
        if (self.pin(row_key) != null) return null;
        const shrank = row_key.len < key.len and isSubset(row_key, key);
        const grew = key.len < row_key.len and isSubset(key, row_key);
        if (!shrank and !grew) return null;
        const out = try a.alloc(?usize, row.len);
        for (row, out) |item, *slot| {
            var home: ?usize = null;
            for (item) |id| {
                if (std.mem.indexOfScalar(Id, key, id) == null) continue;
                const at = itemIndex(items, id) orelse continue;
                // Panes of two old items in one new item: not what the row
                // became.
                if (home) |was| if (was != at) return null;
                home = at;
            }
            slot.* = home;
        }
        // All of it from one old item is a row across that item (a column in
        // it), not this row: the row itself is gone, down to one item.
        var prev: ?usize = null;
        var distinct: usize = 0;
        for (out) |o| {
            const v = o orelse continue;
            if (prev) |p| if (v < p) return null;
            if (prev != v) distinct += 1;
            prev = v;
        }
        if (distinct < 2) return null;
        return out;
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

/// The shares a carried run keeps: the slots on show keep their sizes when
/// they are the same slots; a slot that joined the run shares it out evenly
/// (null), and a slot that became several (a column merged into the row)
/// shares its size out among them.
fn carriedShares(a: Allocator, p: Pin, carried: ?Pin, origin: []const ?usize, old_in: ?[]const f64) Allocator.Error!?[]f64 {
    const c = carried orelse return null;
    const old = old_in orelse return null;
    if (old.len != p.count) return null;
    const slots = try a.alloc(usize, c.count);
    var n: usize = 0;
    for (c.start..c.start + c.count) |i| {
        const o = origin[i] orelse continue;
        if (o < p.start or o - p.start >= old.len) continue;
        slots[n] = o - p.start;
        n += 1;
    }
    if (n != c.count) return null;
    const sizes = try a.alloc(f64, n);
    var total: f64 = 0;
    for (slots, sizes) |slot, *size| {
        const shared = std.mem.count(usize, slots, &.{slot});
        size.* = old[slot] / @as(f64, @floatFromInt(shared));
        total += size.*;
    }
    if (sizes.len < 2 or !(total > 0)) return null;
    for (sizes) |*size| size.* /= total;
    return sizes;
}

/// The run two pins of a row of `n` both show; null is the whole row. When
/// they share nothing, the first.
fn intersecting(a: ?Pin, b: ?Pin, n: usize) ?Pin {
    const lo = @max(if (a) |p| p.start else 0, if (b) |p| p.start else 0);
    const hi = @min(if (a) |p| p.start + p.count else n, if (b) |p| p.start + p.count else n);
    if (lo >= hi) return a;
    if (hi - lo >= n) return null;
    return .{ .start = lo, .count = hi - lo };
}

fn findCarried(carried: []const Carried, key: []const Id) ?usize {
    for (carried, 0..) |c, i| if (std.mem.eql(Id, c.key, key)) return i;
    return null;
}

fn keysOf(a: Allocator, rows_in: Rows) Allocator.Error![]const []const Id {
    const out = try a.alloc([]const Id, rows_in.len);
    for (rows_in, out) |row, *key| key.* = try keyOf(a, row);
    return out;
}

fn containsKey(keys: []const []const Id, key: []const Id) bool {
    for (keys) |k| if (std.mem.eql(Id, k, key)) return true;
    return false;
}

/// Each item's ids sorted: the items as sets, in order.
fn sortedItems(a: Allocator, items: []const []const Id) Allocator.Error![]const []const Id {
    const out = try a.alloc([]const Id, items.len);
    for (items, out) |item, *o| {
        const copy = try a.dupe(Id, item);
        std.mem.sort(Id, copy, {}, std.sort.asc(Id));
        o.* = copy;
    }
    return out;
}

fn indexOfItem(items: []const []const Id, item: []const Id) ?usize {
    for (items, 0..) |x, i| if (std.mem.eql(Id, x, item)) return i;
    return null;
}

fn rowsEql(a: Rows, b: Rows) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!itemsEql(x, y)) return false;
    return true;
}

fn dupeRows(a: Allocator, rows_in: Rows) Allocator.Error!Rows {
    const out = try a.alloc([]const []const Id, rows_in.len);
    for (rows_in, out) |row, *o| {
        const items = try a.alloc([]const Id, row.len);
        for (row, items) |item, *it| it.* = try a.dupe(Id, item);
        o.* = items;
    }
    return out;
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

// -- tests: carrying a collapse over a tree change (T2083): Mac's
// PaneStackStateTests cases for `rowsDidChange` / `paneOnShow` as 2811a3043
// left them.

fn expectShares(state: *const PaneStackState, key: []const Id, want: ?[]const f64) !void {
    const got = state.sharesFor(key);
    if (want == null or got == null) {
        if (want == null and got == null) return;
        std.debug.print("shares for {any}: got {any}, want {any}\n", .{ key, got, want });
        return error.TestExpectedEqual;
    }
    try testing.expectEqual(want.?.len, got.?.len);
    for (want.?, got.?) |w, g| try testing.expectApproxEqAbs(w, g, 1e-9);
}

test "pane_stack_state: closing a pane on show keeps the row collapsed" {
    // a b [c d] e f: c closes, and d alone is on show between the strips.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5, 6 };
    const before = singles(6, &ids);
    try state.restack(.{ .items = &before, .run = .{ .lo = 1, .hi = 4 }, .sizes = &.{ 1, 1, 1, 1 } }, .{ .collapse = .leading }, 1);
    try state.restack(.{ .items = &before, .run = .{ .lo = 2, .hi = 4 }, .sizes = &.{ 1, 1, 1 } }, .{ .collapse = .trailing }, 1);
    try expectPin(&state, &ids, .{ .start = 2, .count = 2 });

    const after = [_][]const Id{ &.{1}, &.{2}, &.{4}, &.{5}, &.{6} };
    var saved_state = try state.saved();
    defer saved_state.deinit(testing.allocator);
    try state.rowsDidChange(&.{&before}, &.{&after});
    try expectPin(&state, &.{ 1, 2, 4, 5, 6 }, .{ .start = 2, .count = 1 });
    try expectShares(&state, &.{ 1, 2, 4, 5, 6 }, null); // one slot needs no shares
    try expectPin(&state, &ids, null); // a row not on screen has no collapse
    // Undoing the close brings back the row as it was (the window restores
    // what it saved with the tree).
    try state.rowsDidChange(&.{&after}, &.{&before});
    try state.restore(&saved_state);
    try expectPin(&state, &ids, .{ .start = 2, .count = 2 });
}

test "pane_stack_state: closing a minimized pane keeps the run and the sizes of its panes" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5 };
    const before = singles(5, &ids);
    try state.restack(.{ .items = &before, .run = .{ .lo = 1, .hi = 4 }, .sizes = &.{ 1, 1, 2, 2 } }, .{ .collapse = .trailing }, 1);
    try expectPin(&state, &ids, .{ .start = 1, .count = 3 });
    const sizes = try testing.allocator.dupe(f64, state.sharesFor(&ids).?);
    defer testing.allocator.free(sizes);
    try state.rowsDidChange(&.{&before}, &.{before[1..]});
    try expectPin(&state, &.{ 2, 3, 4, 5 }, .{ .start = 0, .count = 3 });
    try expectShares(&state, &.{ 2, 3, 4, 5 }, sizes);
}

test "pane_stack_state: closing a pane on show keeps the others' sizes" {
    // a [b c d] e, sized 1:1:2; c closes.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5 };
    const before = singles(5, &ids);
    try state.restack(.{ .items = &before, .run = .{ .lo = 0, .hi = 3 }, .sizes = &.{ 1, 1, 1, 2 } }, .{ .collapse = .leading }, 1);
    const after = [_][]const Id{ &.{1}, &.{2}, &.{4}, &.{5} };
    try state.rowsDidChange(&.{&before}, &.{&after});
    try expectPin(&state, &.{ 1, 2, 4, 5 }, .{ .start = 1, .count = 2 });
    try expectShares(&state, &.{ 1, 2, 4, 5 }, &.{ 1.0 / 3.0, 2.0 / 3.0 });
}

test "pane_stack_state: a pane leaving a column inside a row keeps both collapsed" {
    // a | (b / c / d) | e, the row and the column each collapsed; c closes.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const a: Id = 1;
    const b: Id = 2;
    const c: Id = 3;
    const d: Id = 4;
    const e: Id = 5;
    try state.restack(.{ .items = &.{ &.{b}, &.{c}, &.{d} }, .run = .{ .lo = 0, .hi = 2 } }, .{ .collapse = .trailing }, 1);
    try state.restack(.{ .items = &.{ &.{a}, &.{ b, c, d }, &.{e} }, .run = .{ .lo = 0, .hi = 2 } }, .{ .collapse = .trailing }, 1);
    try state.rowsDidChange(
        &.{ &.{ &.{a}, &.{ b, c, d }, &.{e} }, &.{ &.{b}, &.{c}, &.{d} } },
        &.{ &.{ &.{a}, &.{ b, d }, &.{e} }, &.{ &.{b}, &.{d} } },
    );
    try expectPin(&state, &.{ a, b, d, e }, .{ .start = 0, .count = 2 }); // the row keeps its run
    try expectPin(&state, &.{ b, d }, .{ .start = 0, .count = 1 }); // the column keeps its strip
}

test "pane_stack_state: a column emptied into its row keeps its place" {
    // a | (b / (c | d)), the column minimized: b closes, and c | d joins the
    // outer row. Both pieces were minimized, and stay strips.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    try state.restack(.{ .items = &.{ &.{1}, &.{ 2, 3, 4 } }, .run = .{ .lo = 0, .hi = 1 } }, .{ .collapse = .trailing }, 1);
    try state.rowsDidChange(
        &.{ &.{ &.{1}, &.{ 2, 3, 4 } }, &.{ &.{2}, &.{ 3, 4 } }, &.{ &.{3}, &.{4} } },
        &.{&.{ &.{1}, &.{3}, &.{4} }},
    );
    try expectPin(&state, &.{ 1, 3, 4 }, .{ .start = 0, .count = 1 });
}

test "pane_stack_state: a column on show emptied into its row is on show, its strips kept" {
    // x | (e / (g | h)) | c | d with x and the column on show, c and d
    // strips: e closes. g and h join the row on show; c, d stay strips.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const x: Id = 1;
    const e: Id = 2;
    const g: Id = 3;
    const h: Id = 4;
    const c: Id = 5;
    const d: Id = 6;
    const before = [_][]const Id{ &.{x}, &.{ e, g, h }, &.{c}, &.{d} };
    try state.restack(.{ .items = &before, .run = .{ .lo = 0, .hi = 3 }, .sizes = &.{ 1, 1, 1, 1 } }, .{ .collapse = .trailing }, 1);
    try state.restack(.{ .items = &before, .run = .{ .lo = 0, .hi = 2 }, .sizes = &.{ 1, 1, 1 } }, .{ .collapse = .trailing }, 1);
    try expectPin(&state, &.{ 1, 2, 3, 4, 5, 6 }, .{ .start = 0, .count = 2 });
    try state.rowsDidChange(
        &.{ &before, &.{ &.{e}, &.{ g, h } }, &.{ &.{g}, &.{h} } },
        &.{&.{ &.{x}, &.{g}, &.{h}, &.{c}, &.{d} }},
    );
    try expectPin(&state, &.{ x, g, h, c, d }, .{ .start = 0, .count = 3 });
    // x keeps its half; the column's half is shared out between its pieces.
    try expectShares(&state, &.{ x, g, h, c, d }, &.{ 0.5, 0.25, 0.25 });
}

test "pane_stack_state: a collapsed row merging into a collapsed row keeps both strips" {
    // a | b | ((h | f) / e) | d: a, b and the column on show, d a strip;
    // inside the column, h | f with f a strip. e closes, and h | f joins the
    // outer row: a b h on show, f and d strips. Undone, both rows come back.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const a: Id = 1;
    const b: Id = 2;
    const h: Id = 3;
    const f: Id = 4;
    const e: Id = 5;
    const d: Id = 6;
    const outer = [_][]const Id{ &.{a}, &.{b}, &.{ h, f, e }, &.{d} };
    const column = [_][]const Id{ &.{ h, f }, &.{e} };
    const inner = [_][]const Id{ &.{h}, &.{f} };
    try state.restack(.{ .items = &inner, .run = .{ .lo = 0, .hi = 1 }, .sizes = &.{ 1, 1 } }, .{ .collapse = .trailing }, 1);
    try state.restack(.{ .items = &outer, .run = .{ .lo = 0, .hi = 3 }, .sizes = &.{ 1, 1, 1, 1 } }, .{ .collapse = .trailing }, 1);
    const before = [_][]const []const Id{ &outer, &column, &inner };
    const after = [_][]const []const Id{&.{ &.{a}, &.{b}, &.{h}, &.{f}, &.{d} }};
    var saved_state = try state.saved();
    defer saved_state.deinit(testing.allocator);
    try state.rowsDidChange(&before, &after);
    try expectPin(&state, &.{ a, b, h, f, d }, .{ .start = 0, .count = 3 });
    try state.rowsDidChange(&after, &before);
    try state.restore(&saved_state);
    try expectPin(&state, &.{ 1, 2, 3, 4, 5, 6 }, .{ .start = 0, .count = 3 });
    try expectPin(&state, &.{ h, f }, .{ .start = 0, .count = 1 });
}

test "pane_stack_state: pieces of two items in one are not guessed at" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    try state.restack(.{ .items = &.{ &.{1}, &.{2}, &.{3}, &.{4} }, .run = .{ .lo = 0, .hi = 3 } }, .{ .collapse = .trailing }, 1);
    try state.rowsDidChange(
        &.{&.{ &.{1}, &.{2}, &.{3}, &.{4} }},
        &.{ &.{ &.{1}, &.{ 2, 3 } }, &.{ &.{2}, &.{3} } },
    );
    try expectPin(&state, &.{ 1, 2, 3 }, null);
}

test "pane_stack_state: a collapse undone by focus does not come back with the row" {
    // a [b] [c] collapsed; b splits down (a | (b/d) | c, the collapse carried
    // over). Focusing a brings the row back side by side. Closing d gives back
    // the row's old panes, whose old collapse must not minimize a.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const row = [_][]const Id{ &.{1}, &.{2}, &.{3} };
    try state.restack(.{ .items = &row, .run = .{ .lo = 0, .hi = 2 }, .sizes = &.{ 1, 1, 1 } }, .{ .collapse = .leading }, 1);
    const split = [_][]const Id{ &.{1}, &.{ 2, 4 }, &.{3} };
    const column = [_][]const Id{ &.{2}, &.{4} };
    try state.rowsDidChange(&.{&row}, &.{ &split, &column });
    try state.noteItems(&split, 3);
    try expectPin(&state, &.{ 1, 2, 3, 4 }, .{ .start = 1, .count = 2 });
    state.noteFocus(1);
    try expectPin(&state, &.{ 1, 2, 3, 4 }, null);
    try state.rowsDidChange(&.{ &split, &column }, &.{&row});
    try expectPin(&state, &.{ 1, 2, 3 }, null); // a stale collapse came back
    try expectPin(&state, &.{ 1, 2, 3, 4 }, null);
}

test "pane_stack_state: splitting a pane on show along the row keeps the strips" {
    // a b [c] d e; c splits right: a b [c x] d e.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5 };
    const before = singles(5, &ids);
    try collapsedToOne(&state, &before);
    const after = [_][]const Id{ &.{1}, &.{2}, &.{3}, &.{9}, &.{4}, &.{5} };
    try state.rowsDidChange(&.{&before}, &.{&after});
    try expectPin(&state, &.{ 1, 2, 3, 4, 5, 9 }, .{ .start = 2, .count = 2 });
    try expectShares(&state, &.{ 1, 2, 3, 4, 5, 9 }, null); // the run gained a slot
}

test "pane_stack_state: splitting a pane on show across the row keeps the row" {
    // c splits down: a b [c/x] d e - same items, one of them a column now.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5 };
    const before = singles(5, &ids);
    try state.restack(.{ .items = &before, .run = .{ .lo = 1, .hi = 4 }, .sizes = &.{ 1, 1, 1, 2 } }, .{ .collapse = .leading }, 1);
    const sizes = try testing.allocator.dupe(f64, state.sharesFor(&ids).?);
    defer testing.allocator.free(sizes);
    const after = [_][]const Id{ &.{1}, &.{2}, &.{ 3, 9 }, &.{4}, &.{5} };
    try state.rowsDidChange(&.{&before}, &.{ &after, &.{ &.{3}, &.{9} } });
    try expectPin(&state, &.{ 1, 2, 3, 4, 5, 9 }, .{ .start = 2, .count = 3 });
    try expectShares(&state, &.{ 1, 2, 3, 4, 5, 9 }, sizes); // the same slots keep their sizes
    try expectPin(&state, &.{ 3, 9 }, null); // the new column is side by side
}

test "pane_stack_state: a pane added at the far end of the run is on show" {
    // x lands between b and c: a b [x c] d e.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5 };
    const before = singles(5, &ids);
    try collapsedToOne(&state, &before);
    const after = [_][]const Id{ &.{1}, &.{2}, &.{9}, &.{3}, &.{4}, &.{5} };
    try state.rowsDidChange(&.{&before}, &.{&after});
    try expectPin(&state, &.{ 1, 2, 3, 4, 5, 9 }, .{ .start = 2, .count = 2 });
}

test "pane_stack_state: a pane added among the strips is a strip until it is focused" {
    // x lands between a and b: a x b [c] d e.
    for ([_]bool{ false, true }) |focus_first| {
        var state = PaneStackState.init(testing.allocator);
        defer state.deinit();
        const ids = [_]Id{ 1, 2, 3, 4, 5 };
        const before = singles(5, &ids);
        try collapsedToOne(&state, &before);
        // Room for three on show.
        try state.noteItems(&before, 3);
        state.noteFocus(3);
        const after = [_][]const Id{ &.{1}, &.{9}, &.{2}, &.{3}, &.{4}, &.{5} };
        const key = [_]Id{ 1, 2, 3, 4, 5, 9 };
        if (focus_first) {
            // The focus lands before the tree change is seen.
            state.noteFocus(9);
            try state.rowsDidChange(&.{&before}, &.{&after});
        } else {
            try state.rowsDidChange(&.{&before}, &.{&after});
            try expectPin(&state, &key, .{ .start = 3, .count = 1 }); // a strip, unfocused
            state.noteFocus(9);
        }
        // Focused, it comes out like any strip: the run grows to it.
        try expectPin(&state, &key, .{ .start = 1, .count = 3 });
    }
}

test "pane_stack_state: a focus landing before or after the split gives the same row" {
    var pins: [2]?Pin = undefined;
    for ([_]bool{ false, true }, 0..) |focus_first, i| {
        var state = PaneStackState.init(testing.allocator);
        defer state.deinit();
        const ids = [_]Id{ 1, 2, 3, 4, 5 };
        const before = singles(5, &ids);
        try collapsedToOne(&state, &before);
        state.noteFocus(3);
        const after = [_][]const Id{ &.{1}, &.{2}, &.{3}, &.{9}, &.{4}, &.{5} };
        if (focus_first) state.noteFocus(9);
        try state.rowsDidChange(&.{&before}, &.{&after});
        // The window has room for one card on show.
        try state.noteItems(&after, 1);
        if (!focus_first) state.noteFocus(9);
        pins[i] = state.pin(&.{ 1, 2, 3, 4, 5, 9 });
    }
    try testing.expect(Pin.eql(pins[0], pins[1]));
    try testing.expect(Pin.eql(pins[0], .{ .start = 2, .count = 2 }));
}

test "pane_stack_state: undoing a close brings back the row as it was" {
    // a b [c] d e: a closes and the row carries on as b [c] d e. Undone, the
    // row it was comes back from what was saved with the tree.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5 };
    const before = singles(5, &ids);
    try collapsedToOne(&state, &before);
    var saved_state = try state.saved();
    defer saved_state.deinit(testing.allocator);
    try state.rowsDidChange(&.{&before}, &.{before[1..]});
    try expectPin(&state, &.{ 2, 3, 4, 5 }, .{ .start = 1, .count = 1 });
    try state.rowsDidChange(&.{before[1..]}, &.{&before});
    try state.restore(&saved_state);
    try expectPin(&state, &ids, .{ .start = 2, .count = 1 });
}

test "pane_stack_state: a pane moved within the row keeps the same panes on show" {
    // a b [c] d e: a dropped beside e - b [c] d e a, still c on show.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5 };
    const before = singles(5, &ids);
    try collapsedToOne(&state, &before);
    const after = [_][]const Id{ &.{2}, &.{3}, &.{4}, &.{5}, &.{1} };
    try state.rowsDidChange(&.{&before}, &.{&after});
    try expectPin(&state, &ids, .{ .start = 1, .count = 1 });
}

test "pane_stack_state: a swap within the row swaps what is on show" {
    // a b [c] d e: e dropped on c trades places with it, and is on show.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5 };
    const before = singles(5, &ids);
    try collapsedToOne(&state, &before);
    try state.swap(3, 5);
    const after = [_][]const Id{ &.{1}, &.{2}, &.{5}, &.{4}, &.{3} };
    try state.rowsDidChange(&.{&before}, &.{&after});
    try expectPin(&state, &ids, .{ .start = 2, .count = 1 });
}

test "pane_stack_state: a row gaining a new column is not guessed at" {
    // a | (b / c) collapsed; a splits down. The new column a / x is not a row
    // anyone collapsed.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    try state.restack(.{ .items = &.{ &.{1}, &.{ 2, 3 } }, .run = .{ .lo = 0, .hi = 1 } }, .{ .collapse = .trailing }, 1);
    try state.rowsDidChange(
        &.{ &.{ &.{1}, &.{ 2, 3 } }, &.{ &.{2}, &.{3} } },
        &.{ &.{ &.{ 1, 4 }, &.{ 2, 3 } }, &.{ &.{1}, &.{4} }, &.{ &.{2}, &.{3} } },
    );
    try expectPin(&state, &.{ 1, 2, 3, 4 }, .{ .start = 0, .count = 1 });
    try expectPin(&state, &.{ 1, 4 }, null);
}

test "pane_stack_state: after a close the caret goes to a pane still on show" {
    // a b [c] d e: c closes. The caret's next pane, d, is a strip now -
    // focusing it would bring it out - so it goes to b, which the close
    // brought on show. A candidate already on show is kept.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5 };
    const before = singles(5, &ids);
    try collapsedToOne(&state, &before);
    const after = [_][]const Id{ &.{1}, &.{2}, &.{4}, &.{5} };
    try testing.expectEqual(@as(Id, 2), try state.paneOnShow(4, &.{&before}, &.{&after}));
    try testing.expectEqual(@as(Id, 2), try state.paneOnShow(2, &.{&before}, &.{&after}));
}

test "pane_stack_state: the caret goes to the pane of a column on show focused last" {
    // a [(b / c)] d: d is a strip, so the caret goes into the column on show,
    // to c, the one of it focused more recently.
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const row = [_][]const Id{ &.{1}, &.{ 2, 3 }, &.{4} };
    try state.restack(.{ .items = &row, .run = .{ .lo = 0, .hi = 2 } }, .{ .collapse = .leading }, 1);
    try state.restack(.{ .items = &row, .run = .{ .lo = 1, .hi = 2 } }, .{ .collapse = .trailing }, 1);
    try expectPin(&state, &.{ 1, 2, 3, 4 }, .{ .start = 1, .count = 1 });
    state.noteFocus(3);
    state.noteFocus(2);
    try testing.expectEqual(@as(Id, 2), try state.paneOnShow(4, &.{&row}, &.{&row}));
    state.noteFocus(3);
    try testing.expectEqual(@as(Id, 3), try state.paneOnShow(4, &.{&row}, &.{&row}));
    try expectPin(&state, &.{ 1, 2, 3, 4 }, .{ .start = 1, .count = 1 });
}

test "pane_stack_state: noteRows carries a collapse over what changed since it last looked" {
    var state = PaneStackState.init(testing.allocator);
    defer state.deinit();
    const ids = [_]Id{ 1, 2, 3, 4, 5 };
    const before = singles(5, &ids);
    // The first rows are only noted.
    try state.noteRows(&.{&before});
    try collapsedToOne(&state, &before);
    try state.noteRows(&.{&before});
    try expectPin(&state, &ids, .{ .start = 2, .count = 1 });
    const after = [_][]const Id{ &.{2}, &.{3}, &.{4}, &.{5} };
    try state.noteRows(&.{&after});
    try expectPin(&state, &.{ 2, 3, 4, 5 }, .{ .start = 1, .count = 1 });
    try expectPin(&state, &ids, null);
    // Seen already: nothing moves.
    try state.noteRows(&.{&after});
    try expectPin(&state, &.{ 2, 3, 4, 5 }, .{ .start = 1, .count = 1 });
}
