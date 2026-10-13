//! Undo for closing a pane or a tab (T1825, Mac's `undo-timeout`).
//!
//! On Mac a close registers an undo with the window's `ExpiringUndoManager`:
//! for `undo-timeout` the closed surface stays alive (its shell still running,
//! its agent session still bound), and Cmd+Z puts it back. Windows does the
//! same thing the same way - a closed pane is PARKED rather than freed: taken
//! out of the layout and hidden, but still holding its reference, so nothing
//! underneath it notices. When the undo expires the pane is torn down exactly
//! as an immediate close would have done it, which is the moment its agent
//! session is ended.
//!
//! This file is the part of that which needs no desktop:
//!
//!   * `Stack` - the expiring LIFO the parked closes (and the redos that undo
//!     them) live on. Each entry carries its own deadline, as Mac's does: a
//!     later close never extends an earlier one.
//!   * `Anchor` / `restore` - where in the split tree a closed pane goes back.
//!     A binary split tree loses the closed leaf's PARENT when the leaf is
//!     removed (the sibling subtree takes its place), so the anchor remembers
//!     the sibling by the set of leaves it held and the parent's layout and
//!     ratio. Restoring re-splits that same subtree, which reproduces the
//!     layout exactly when nothing else changed - and still lands next to the
//!     right neighbour when something did.
//!
//! Pure over any `SplitTree(V)`; the tests below run in every lane.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

/// Milliseconds of `undo-timeout`, or null when undo is off. Mac documents a
/// zero timeout as "effectively disables undo", so a close with it is the
/// immediate close it always was.
pub fn timeoutMs(ns: u64) ?u64 {
    const ms = ns / std.time.ns_per_ms;
    return if (ms == 0) null else ms;
}

/// The longest single `SetTimer` interval Windows accepts
/// (`USER_TIMER_MAXIMUM`, ~24.8 days). A longer deadline is reached by
/// re-arming, so a "years" timeout is honoured rather than clamped.
pub const max_timer_ms: u64 = 0x7FFFFFFF;

/// How long to arm the expiry timer for, given the soonest deadline: at least
/// 1 ms (a deadline already passed fires straight away) and never past what
/// `SetTimer` takes.
pub fn timerDelay(deadline: u64, now: u64) u32 {
    const left = if (deadline > now) deadline - now else 1;
    return @intCast(@min(@max(left, 1), max_timer_ms));
}

/// An expiring LIFO of `P`. `owner` scopes an entry to the window it belongs
/// to (Mac keeps an undo manager per window), so Ctrl+Shift+Z in one window
/// never resurrects a pane in another.
pub fn Stack(comptime P: type) type {
    return struct {
        const Self = @This();

        pub const Item = struct {
            payload: P,
            owner: usize,
            deadline: u64,
            /// Non-zero ties entries made by ONE user action (Close Other
            /// Tabs closes several), so one undo brings them all back - Mac's
            /// `beginUndoGrouping`. Zero is a lone entry.
            group: u64 = 0,
        };

        /// Oldest first; the top of the stack is the end.
        items: std.ArrayListUnmanaged(Item) = .empty,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.items.deinit(alloc);
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        pub fn push(self: *Self, alloc: Allocator, item: Item) Allocator.Error!void {
            try self.items.append(alloc, item);
        }

        /// The most recent entry owned by `owner`, removed.
        pub fn popFor(self: *Self, owner: usize) ?Item {
            var i = self.items.items.len;
            while (i > 0) {
                i -= 1;
                if (self.items.items[i].owner == owner) return self.items.orderedRemove(i);
            }
            return null;
        }

        /// The most recent entry owned by `owner` OR by `shared`, removed.
        /// A closed window (T1874) belongs to no window any more, so its
        /// entry is owned by the shared key and every window's undo reaches
        /// it - in recency order with that window's own closes, the way
        /// Mac's one app-wide undo manager would order them.
        pub fn popForEither(self: *Self, owner: usize, shared: usize) ?Item {
            var i = self.items.items.len;
            while (i > 0) {
                i -= 1;
                const o = self.items.items[i].owner;
                if (o == owner or o == shared) return self.items.orderedRemove(i);
            }
            return null;
        }

        /// The most recent entry owned by `owner`, removed only when it
        /// belongs to `group` - how the rest of a group is collected after
        /// its first member was popped. A zero group never continues.
        pub fn popGroupFor(self: *Self, owner: usize, group: u64) ?Item {
            if (group == 0) return null;
            var i = self.items.items.len;
            while (i > 0) {
                i -= 1;
                const it = self.items.items[i];
                if (it.owner != owner) continue;
                return if (it.group == group) self.items.orderedRemove(i) else null;
            }
            return null;
        }

        /// The owner of the most recent entry, whoever it belongs to - what
        /// an undo with no window to scope it (the app target) acts on.
        pub fn topOwner(self: *const Self) ?usize {
            const n = self.items.items.len;
            return if (n == 0) null else self.items.items[n - 1].owner;
        }

        /// Whether `owner` has anything to undo (or redo).
        pub fn hasFor(self: *const Self, owner: usize) bool {
            for (self.items.items) |it| if (it.owner == owner) return true;
            return false;
        }

        /// The OLDEST entry whose deadline has passed, removed. Call until it
        /// answers null: expiry walks the stack bottom up, the order the
        /// entries were made in.
        pub fn takeExpired(self: *Self, now: u64) ?Item {
            for (self.items.items, 0..) |it, i| {
                if (it.deadline <= now) return self.items.orderedRemove(i);
            }
            return null;
        }

        /// Any entry owned by `owner`, removed - for draining a window that
        /// is going away. Oldest first.
        pub fn takeOwnedBy(self: *Self, owner: usize) ?Item {
            for (self.items.items, 0..) |it, i| {
                if (it.owner == owner) return self.items.orderedRemove(i);
            }
            return null;
        }

        /// Any entry at all, removed, oldest first - for app teardown.
        pub fn takeAny(self: *Self) ?Item {
            if (self.items.items.len == 0) return null;
            return self.items.orderedRemove(0);
        }

        /// The first entry `pred` accepts, removed.
        pub fn takeMatching(
            self: *Self,
            ctx: anytype,
            comptime pred: fn (@TypeOf(ctx), *const P) bool,
        ) ?Item {
            for (self.items.items, 0..) |*it, i| {
                if (pred(ctx, &it.payload)) return self.items.orderedRemove(i);
            }
            return null;
        }

        /// The soonest deadline on the stack, or null when it is empty.
        pub fn nextDeadline(self: *const Self) ?u64 {
            var best: ?u64 = null;
            for (self.items.items) |it| {
                if (best == null or it.deadline < best.?) best = it.deadline;
            }
            return best;
        }
    };
}

/// Where a closed leaf sat, in terms that survive the removal. See the file
/// header for why it names the SIBLING rather than the leaf's own slot.
pub fn Anchor(comptime V: type) type {
    return struct {
        const Self = @This();
        const VTree = SplitTree(V);

        /// The leaves of the subtree that took the closed leaf's place. Held
        /// by identity only - never dereferenced, never reffed - so a sibling
        /// that is itself closed later simply stops matching.
        sibling: []*const V,
        layout: VTree.Split.Layout,
        ratio: f16,
        /// Whether the closed leaf was the split's left (or top) child.
        was_left: bool,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.sibling);
            self.* = undefined;
        }

        /// Capture the anchor of leaf `at` in `tree`, BEFORE it is removed.
        /// Null when `at` is the root: a tab's only pane has no neighbour, and
        /// closing it is closing the tab.
        pub fn capture(alloc: Allocator, tree: *const VTree, at: VTree.Node.Handle) Allocator.Error!?Self {
            const parent = parentOf(tree, at) orelse return null;
            const split = tree.nodes[parent.idx()].split;
            const was_left = split.left == at;
            const sib = if (was_left) split.right else split.left;

            var leaves: std.ArrayListUnmanaged(*const V) = .empty;
            errdefer leaves.deinit(alloc);
            try collectLeaves(alloc, tree, sib, &leaves);
            return .{
                .sibling = try leaves.toOwnedSlice(alloc),
                .layout = split.layout,
                .ratio = split.ratio,
                .was_left = was_left,
            };
        }

        /// The direction to split the anchor in so the restored leaf lands on
        /// the side it was closed from.
        pub fn direction(self: *const Self) VTree.Split.Direction {
            return switch (self.layout) {
                .horizontal => if (self.was_left) .left else .right,
                .vertical => if (self.was_left) .up else .down,
            };
        }

        /// The node in `tree` the restored leaf should be split against:
        /// the subtree holding exactly the recorded sibling leaves when the
        /// layout is unchanged, else any leaf that is still one of them.
        /// Null when every one of them is gone.
        pub fn locate(self: *const Self, alloc: Allocator, tree: *const VTree) Allocator.Error!?Placement {
            if (tree.isEmpty() or self.sibling.len == 0) return null;

            var leaves: std.ArrayListUnmanaged(*const V) = .empty;
            defer leaves.deinit(alloc);
            var first_member: ?VTree.Node.Handle = null;
            for (tree.nodes, 0..) |node, i| {
                const h: VTree.Node.Handle = @enumFromInt(i);
                leaves.clearRetainingCapacity();
                try collectLeaves(alloc, tree, h, &leaves);
                if (sameSet(leaves.items, self.sibling)) return .{ .at = h, .exact = true };
                if (first_member == null) switch (node) {
                    .leaf => |v| if (contains(self.sibling, v)) {
                        first_member = h;
                    },
                    .split => {},
                };
            }
            return if (first_member) |h| .{ .at = h, .exact = false } else null;
        }

        pub const Placement = struct {
            at: VTree.Node.Handle,
            /// True when the recorded sibling subtree is intact, i.e. the
            /// restore reproduces the layout from before the close.
            exact: bool,
        };

        /// `tree` with `view` split back in at `at` on the recorded side.
        /// The caller owns the result; `tree` is untouched.
        pub fn restore(
            self: *const Self,
            alloc: Allocator,
            tree: *const VTree,
            at: VTree.Node.Handle,
            view: *V,
        ) Allocator.Error!VTree {
            var single = try VTree.init(alloc, view);
            defer single.deinit();
            return try tree.split(alloc, at, self.direction(), self.ratio, &single);
        }
    };
}

fn parentOf(tree: anytype, at: anytype) ?@TypeOf(at) {
    for (tree.nodes, 0..) |node, i| switch (node) {
        .split => |s| if (s.left == at or s.right == at) return @enumFromInt(i),
        .leaf => {},
    };
    return null;
}

fn collectLeaves(alloc: Allocator, tree: anytype, at: anytype, out: anytype) Allocator.Error!void {
    switch (tree.nodes[at.idx()]) {
        .leaf => |v| try out.append(alloc, v),
        .split => |s| {
            try collectLeaves(alloc, tree, s.left, out);
            try collectLeaves(alloc, tree, s.right, out);
        },
    }
}

fn contains(set: anytype, v: anytype) bool {
    for (set) |x| if (x == v) return true;
    return false;
}

fn sameSet(a: anytype, b: anytype) bool {
    if (a.len != b.len) return false;
    for (a) |x| if (!contains(b, x)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const TestView = struct {
    label: []const u8,

    pub fn ref(self: *TestView, alloc: Allocator) Allocator.Error!*TestView {
        _ = alloc;
        return self;
    }
    pub fn unref(self: *TestView, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
    pub fn splitTreeLabel(self: *const TestView) []const u8 {
        return self.label;
    }
};
const Tree = SplitTree(TestView);
const TAnchor = Anchor(TestView);

fn handleOf(tree: *const Tree, v: *const TestView) Tree.Node.Handle {
    for (tree.nodes, 0..) |node, i| switch (node) {
        .leaf => |x| if (x == v) return @enumFromInt(i),
        .split => {},
    };
    unreachable;
}

/// A | (B / C) with a 0.3 root ratio, so a restore that loses the ratio shows.
fn threePane(alloc: Allocator, a: *TestView, b: *TestView, c: *TestView) !Tree {
    var ta = try Tree.init(alloc, a);
    defer ta.deinit();
    var tb = try Tree.init(alloc, b);
    defer tb.deinit();
    var tc = try Tree.init(alloc, c);
    defer tc.deinit();
    var bc = try tb.split(alloc, .root, .down, 0.5, &tc);
    defer bc.deinit();
    return try ta.split(alloc, .root, .right, 0.3, &bc);
}

fn diagram(alloc: Allocator, tree: *const Tree) ![]u8 {
    return std.fmt.allocPrint(alloc, "{f}", .{tree.*});
}

test "close_undo: a zero timeout disables undo; milliseconds otherwise" {
    try testing.expectEqual(@as(?u64, null), timeoutMs(0));
    try testing.expectEqual(@as(?u64, null), timeoutMs(999_999)); // under a millisecond
    try testing.expectEqual(@as(?u64, 5000), timeoutMs(5 * std.time.ns_per_s));
}

test "close_undo: the timer delay is at least 1 ms and never past SetTimer's limit" {
    try testing.expectEqual(@as(u32, 1), timerDelay(100, 100));
    try testing.expectEqual(@as(u32, 1), timerDelay(100, 500)); // already passed
    try testing.expectEqual(@as(u32, 250), timerDelay(350, 100));
    try testing.expectEqual(@as(u32, max_timer_ms), timerDelay(std.math.maxInt(u64), 0));
}

test "close_undo: undo is per window and last-in first-out" {
    const alloc = testing.allocator;
    var s: Stack(u8) = .{};
    defer s.deinit(alloc);
    try s.push(alloc, .{ .payload = 'a', .owner = 1, .deadline = 10 });
    try s.push(alloc, .{ .payload = 'b', .owner = 2, .deadline = 20 });
    try s.push(alloc, .{ .payload = 'c', .owner = 1, .deadline = 30 });

    try testing.expect(s.hasFor(2));
    try testing.expect(!s.hasFor(3));
    try testing.expectEqual(@as(u8, 'c'), s.popFor(1).?.payload);
    try testing.expectEqual(@as(u8, 'a'), s.popFor(1).?.payload);
    try testing.expectEqual(@as(?Stack(u8).Item, null), s.popFor(1));
    try testing.expectEqual(@as(u8, 'b'), s.popFor(2).?.payload);
}

test "close_undo: a shared entry is reached from any window, in recency order" {
    const alloc = testing.allocator;
    var s: Stack(u8) = .{};
    defer s.deinit(alloc);
    const shared: usize = 0;
    try s.push(alloc, .{ .payload = 'a', .owner = 1, .deadline = 10 });
    try s.push(alloc, .{ .payload = 'w', .owner = shared, .deadline = 20 }); // a closed window
    try s.push(alloc, .{ .payload = 'b', .owner = 2, .deadline = 30 });

    // Window 1's newest is the closed window, not its own older close.
    try testing.expectEqual(@as(u8, 'w'), s.popForEither(1, shared).?.payload);
    try testing.expectEqual(@as(u8, 'a'), s.popForEither(1, shared).?.payload);
    try testing.expectEqual(@as(?Stack(u8).Item, null), s.popForEither(1, shared));
    // Window 2's own close was never touched.
    try testing.expectEqual(@as(u8, 'b'), s.popForEither(2, shared).?.payload);
}

test "close_undo: a group comes back as one, and only its own members" {
    const alloc = testing.allocator;
    var s: Stack(u8) = .{};
    defer s.deinit(alloc);
    try s.push(alloc, .{ .payload = 'x', .owner = 1, .deadline = 10, .group = 7 });
    try s.push(alloc, .{ .payload = 'a', .owner = 1, .deadline = 10, .group = 9 });
    try s.push(alloc, .{ .payload = 'o', .owner = 2, .deadline = 10, .group = 9 }); // another window
    try s.push(alloc, .{ .payload = 'b', .owner = 1, .deadline = 10, .group = 9 });

    try testing.expectEqual(@as(?usize, 1), s.topOwner());
    const first = s.popFor(1).?;
    try testing.expectEqual(@as(u8, 'b'), first.payload);
    try testing.expectEqual(@as(u8, 'a'), s.popGroupFor(1, first.group).?.payload);
    // The next entry of window 1 is a different action: the group stops.
    try testing.expectEqual(@as(?Stack(u8).Item, null), s.popGroupFor(1, first.group));
    try testing.expectEqual(@as(?Stack(u8).Item, null), s.popGroupFor(1, 0));
    try testing.expectEqual(@as(usize, 2), s.len());
    try testing.expectEqual(@as(?usize, 2), s.topOwner());
}

test "close_undo: each entry expires on its own deadline, oldest first" {
    const alloc = testing.allocator;
    var s: Stack(u8) = .{};
    defer s.deinit(alloc);
    try s.push(alloc, .{ .payload = 'a', .owner = 1, .deadline = 10 });
    try s.push(alloc, .{ .payload = 'b', .owner = 1, .deadline = 20 });
    try s.push(alloc, .{ .payload = 'c', .owner = 1, .deadline = 30 });

    try testing.expectEqual(@as(?u64, 10), s.nextDeadline());
    try testing.expectEqual(@as(?Stack(u8).Item, null), s.takeExpired(9));
    // A later close never extended an earlier one.
    try testing.expectEqual(@as(u8, 'a'), s.takeExpired(25).?.payload);
    try testing.expectEqual(@as(u8, 'b'), s.takeExpired(25).?.payload);
    try testing.expectEqual(@as(?Stack(u8).Item, null), s.takeExpired(25));
    try testing.expectEqual(@as(?u64, 30), s.nextDeadline());
    try testing.expectEqual(@as(usize, 1), s.len());
}

test "close_undo: a closing window drains only its own entries" {
    const alloc = testing.allocator;
    var s: Stack(u8) = .{};
    defer s.deinit(alloc);
    try s.push(alloc, .{ .payload = 'a', .owner = 1, .deadline = 10 });
    try s.push(alloc, .{ .payload = 'b', .owner = 2, .deadline = 20 });
    try s.push(alloc, .{ .payload = 'c', .owner = 1, .deadline = 30 });

    try testing.expectEqual(@as(u8, 'a'), s.takeOwnedBy(1).?.payload);
    try testing.expectEqual(@as(u8, 'c'), s.takeOwnedBy(1).?.payload);
    try testing.expectEqual(@as(?Stack(u8).Item, null), s.takeOwnedBy(1));
    try testing.expectEqual(@as(usize, 1), s.len());
    try testing.expectEqual(@as(u8, 'b'), s.takeAny().?.payload);
    try testing.expectEqual(@as(?Stack(u8).Item, null), s.takeAny());
}

test "close_undo: takeMatching removes the entry a predicate names" {
    const alloc = testing.allocator;
    var s: Stack(u8) = .{};
    defer s.deinit(alloc);
    try s.push(alloc, .{ .payload = 'a', .owner = 1, .deadline = 10 });
    try s.push(alloc, .{ .payload = 'b', .owner = 1, .deadline = 20 });
    const pred = struct {
        fn f(want: u8, p: *const u8) bool {
            return p.* == want;
        }
    }.f;
    try testing.expectEqual(@as(u8, 'b'), s.takeMatching(@as(u8, 'b'), pred).?.payload);
    try testing.expectEqual(@as(?Stack(u8).Item, null), s.takeMatching(@as(u8, 'z'), pred));
    try testing.expectEqual(@as(usize, 1), s.len());
}

test "close_undo: a tab's only pane has no anchor" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var t = try Tree.init(alloc, &a);
    defer t.deinit();
    try testing.expectEqual(@as(?TAnchor, null), try TAnchor.capture(alloc, &t, .root));
}

test "close_undo: closing a leaf beside a subtree and undoing reproduces the layout" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var before = try threePane(alloc, &a, &b, &c);
    defer before.deinit();
    const want = try diagram(alloc, &before);
    defer alloc.free(want);

    // Close A, the LEFT child of the root, whose sibling is the B/C subtree.
    var anchor = (try TAnchor.capture(alloc, &before, handleOf(&before, &a))).?;
    defer anchor.deinit(alloc);
    try testing.expect(anchor.was_left);
    try testing.expectEqual(Tree.Split.Direction.left, anchor.direction());
    try testing.expectEqual(@as(usize, 2), anchor.sibling.len);

    var after = try before.remove(alloc, handleOf(&before, &a));
    defer after.deinit();

    const place = (try anchor.locate(alloc, &after)).?;
    try testing.expect(place.exact);
    var restored = try anchor.restore(alloc, &after, place.at, &a);
    defer restored.deinit();
    const got = try diagram(alloc, &restored);
    defer alloc.free(got);
    try testing.expectEqualStrings(want, got);
    try testing.expectEqual(@as(f16, 0.3), restored.nodes[0].split.ratio);
}

test "close_undo: closing a leaf inside a subtree restores it on the same side" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var before = try threePane(alloc, &a, &b, &c);
    defer before.deinit();
    const want = try diagram(alloc, &before);
    defer alloc.free(want);

    // Close C, the bottom of B/C: its sibling is the single leaf B.
    var anchor = (try TAnchor.capture(alloc, &before, handleOf(&before, &c))).?;
    defer anchor.deinit(alloc);
    try testing.expect(!anchor.was_left);
    try testing.expectEqual(Tree.Split.Direction.down, anchor.direction());

    var after = try before.remove(alloc, handleOf(&before, &c));
    defer after.deinit();
    const place = (try anchor.locate(alloc, &after)).?;
    try testing.expect(place.exact);
    var restored = try anchor.restore(alloc, &after, place.at, &c);
    defer restored.deinit();
    const got = try diagram(alloc, &restored);
    defer alloc.free(got);
    try testing.expectEqualStrings(want, got);
}

test "close_undo: a changed sibling still gets the pane back next to a survivor" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var before = try threePane(alloc, &a, &b, &c);
    defer before.deinit();

    var anchor = (try TAnchor.capture(alloc, &before, handleOf(&before, &a))).?;
    defer anchor.deinit(alloc);
    var after = try before.remove(alloc, handleOf(&before, &a));
    defer after.deinit();
    // Then C closes for real: the recorded {B, C} subtree no longer exists.
    var later = try after.remove(alloc, handleOf(&after, &c));
    defer later.deinit();

    const place = (try anchor.locate(alloc, &later)).?;
    try testing.expect(!place.exact);
    try testing.expectEqual(handleOf(&later, &b), place.at);
    var restored = try anchor.restore(alloc, &later, place.at, &a);
    defer restored.deinit();
    // A is back on B's left, at the recorded ratio.
    try testing.expectEqual(Tree.Split.Layout.horizontal, restored.nodes[0].split.layout);
    try testing.expectEqual(@as(f16, 0.3), restored.nodes[0].split.ratio);
    const left = restored.nodes[restored.nodes[0].split.left.idx()];
    try testing.expect(left.leaf == &a);
}

test "close_undo: no anchor survives when every neighbour is gone" {
    const alloc = testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var x: TestView = .{ .label = "X" };
    var ta = try Tree.init(alloc, &a);
    defer ta.deinit();
    var tb = try Tree.init(alloc, &b);
    defer tb.deinit();
    var ab = try ta.split(alloc, .root, .right, 0.5, &tb);
    defer ab.deinit();

    var anchor = (try TAnchor.capture(alloc, &ab, handleOf(&ab, &a))).?;
    defer anchor.deinit(alloc);
    var unrelated = try Tree.init(alloc, &x);
    defer unrelated.deinit();
    try testing.expectEqual(@as(?TAnchor.Placement, null), try anchor.locate(alloc, &unrelated));
}
