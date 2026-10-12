//! Stashing: taking a pane out of the LAYOUT while keeping it in the TREE
//! (T1827, Mac 87afbf6ff / 597a193cc / c6826b79a).
//!
//! A stashed pane keeps running and stays a leaf of its tab's `SplitTree`, so
//! everything that walks the tree keeps seeing it — IPC targeting, `+list`,
//! close confirmation, session close intent, the session manifest. Only
//! spatial work skips it: the grid layout, divider paint and hit-testing,
//! directional focus, hero mode. A split whose one side is entirely stashed
//! COLLAPSES into its visible side, and keeps its direction and ratio, so a
//! restored pane comes back to exactly the slot it left.
//!
//! Where the state lives differs from Mac on purpose. Mac's tree is a value,
//! so its ordered `stashed` id list rides inside it and undo carries it for
//! free. The win32 tab trees are parallel arrays on `Window` that shift on
//! every tab insert, close and move, and a per-tab list beside them would be
//! one more array for each of those sites to forget. So the stash is a field
//! on the pane itself (`PaneView.stash_seq`): zero means on screen, non-zero
//! means stashed, and the larger the number the more recently it was stashed
//! — the top of the stash. It follows the pane wherever the pane goes, holds
//! no pointer that could dangle, and the order falls out of the numbers.
//!
//! Invariants (the same three Mac's `SplitTree+Stash.swift` states):
//! 1. While a tree is non-empty, at least one pane is visible. Stashing the
//!    last visible pane is refused; a mutation that would leave only stashed
//!    panes restores the top of the stash (`normalize`).
//! 2. Only leaves of a tree are stashed in it — by construction here, since
//!    the mark is on the leaf.
//! 3. A zoom whose every leaf is stashed is cleared (`normalize`).
//!
//! Pure over any `SplitTree(V)` whose `V` has a `stash_seq: u64` field, so it
//! is unit-tested in every lane without a window.

const std = @import("std");

/// Monotonic stash clock. Main (UI) thread only, like every tree mutation.
var next_seq: u64 = 1;

/// Why a stash was refused.
pub const StashError = error{
    /// The view is not a leaf of this tree.
    NotInTree,
    /// Stashing it would leave nothing on screen.
    LastVisiblePane,
};

pub fn isStashed(view: anytype) bool {
    return view.stash_seq != 0;
}

/// Mark `view` stashed, on top of the stash. Re-stashing a stashed pane moves
/// it to the top (Mac's `stashing(_:at: 0)`). Does not check the invariants —
/// `checkStash` does, before the caller commits to a focus move.
pub fn mark(view: anytype) void {
    view.stash_seq = next_seq;
    next_seq += 1;
}

/// The most stashed leaves `markAt` will reorder; past it the pane goes on
/// top, which is still a stash, just not at the gap it was dropped on.
pub const max_reorder: usize = 128;

/// Mark `view` stashed at `index` in the stash, 0 being the top (T1844, Mac
/// `stashing(_:at:)`): a drop between two stashed rows lands between them.
/// An index past the end appends at the bottom. Re-stashing a stashed pane
/// moves it to `index` among the OTHERS - the gap it was dropped on, counted
/// without itself. The order is all a stash has, so the others are renumbered
/// bottom-first with fresh numbers; their relative order is unchanged. Like
/// `mark`, does not check the invariants.
pub fn markAt(tree: anytype, view: anytype, index: usize) void {
    const View = @TypeOf(view.*);
    var others: [max_reorder]*View = undefined;
    var n: usize = 0;
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (entry.view == view or !isStashed(entry.view)) continue;
        if (n == others.len) return mark(view);
        others[n] = entry.view;
        n += 1;
    }
    // Top first: the larger number is nearer the top.
    std.mem.sort(*View, others[0..n], {}, struct {
        fn topFirst(_: void, a: *View, b: *View) bool {
            return a.stash_seq > b.stash_seq;
        }
    }.topFirst);
    const at = @min(index, n);
    // Bottom-first, so the top ends up the most recent.
    var i: usize = n + 1;
    while (i > 0) {
        i -= 1;
        const v: *View = if (i == at) view else if (i < at) others[i] else others[i - 1];
        mark(v);
    }
}

/// Put `view` back in the layout. A no-op on a pane that is not stashed.
pub fn unmark(view: anytype) void {
    view.stash_seq = 0;
}

/// Whether `view` is a leaf of `tree`.
pub fn contains(tree: anytype, view: anytype) bool {
    var it = tree.iterator();
    while (it.next()) |entry| if (entry.view == view) return true;
    return false;
}

/// Refuse a stash that would break invariant 1. Stashing an already stashed
/// pane is always allowed (it only reorders).
pub fn checkStash(tree: anytype, view: anytype) StashError!void {
    if (!contains(tree, view)) return error.NotInTree;
    if (isStashed(view)) return;
    if (visibleLeafCount(tree) <= 1) return error.LastVisiblePane;
}

/// How many leaves of `tree` are stashed.
pub fn stashedCount(tree: anytype) usize {
    var n: usize = 0;
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (isStashed(entry.view)) n += 1;
    }
    return n;
}

/// How many leaves of `tree` are on screen (zoom aside).
pub fn visibleLeafCount(tree: anytype) usize {
    var n: usize = 0;
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (!isStashed(entry.view)) n += 1;
    }
    return n;
}

/// Whether more than one pane is on screen — the stash-aware "is this tab
/// split", for every question about what the user can SEE (dim overlays,
/// divider paint, hero mode).
pub fn isVisiblySplit(tree: anytype) bool {
    return visibleLeafCount(tree) > 1;
}

/// The top of the stash: the most recently stashed leaf, or null.
pub fn topStashed(tree: anytype) ?*@TypeOf(tree).View {
    var best: ?*@TypeOf(tree).View = null;
    var best_seq: u64 = 0;
    var it = tree.iterator();
    while (it.next()) |entry| {
        const seq = entry.view.stash_seq;
        if (seq > best_seq) {
            best_seq = seq;
            best = entry.view;
        }
    }
    return best;
}

/// Where `view` sits in the stash: 0 is the top. Null when it is not stashed.
/// This is the number the session manifest persists (Mac's `stashIndex`).
pub fn stashIndex(tree: anytype, view: anytype) ?usize {
    if (!isStashed(view)) return null;
    var above: usize = 0;
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.stash_seq > view.stash_seq) above += 1;
    }
    return above;
}

/// The manifest's spelling of `stashIndex` (T1838): what capture writes for
/// one leaf. Null for a pane on screen, and for an index past `u32` (a tree
/// cannot hold that many leaves; recording nothing beats truncating).
pub fn recordedIndex(tree: anytype, view: anytype) ?u32 {
    const i = stashIndex(tree, view) orelse return null;
    return std.math.cast(u32, i);
}

/// One leaf a restore found stashed in the manifest, and where in the stash
/// it sat (0 = top).
pub fn Recorded(comptime View: type) type {
    return struct { view: *View, index: u32 };
}

/// Re-stash a freshly restored tree the way the manifest recorded it (T1838,
/// Mac `withStash(stashedIDs(...))`). Marks bottom-first so the recorded top
/// ends up the most recent, which is all the order a stash has; the absolute
/// numbers do not survive and do not need to. Entries naming a view that is
/// not a leaf of `tree` are ignored. Then `normalize`, so a manifest whose
/// stash would hide every pane — hand-edited, or written mid-close — still
/// restores with one on screen. Returns what `normalize` had to restore.
/// Reorders `recorded` in place.
pub fn applyRecorded(
    tree: anytype,
    recorded: []Recorded(@TypeOf(tree.*).View),
) ?*@TypeOf(tree.*).View {
    const Entry = Recorded(@TypeOf(tree.*).View);
    std.mem.sort(Entry, recorded, {}, struct {
        fn deeperFirst(_: void, a: Entry, b: Entry) bool {
            return a.index > b.index;
        }
    }.deeperFirst);
    for (recorded) |entry| {
        if (contains(tree.*, entry.view)) mark(entry.view);
    }
    return normalize(tree);
}

/// Whether the subtree under `handle` holds at least one visible leaf. A split
/// with one invisible side collapses into the other in every geometry walk.
pub fn subtreeVisible(tree: anytype, handle: anytype) bool {
    if (handle.idx() >= tree.nodes.len) return false;
    return switch (tree.nodes[handle.idx()]) {
        .leaf => |view| !isStashed(view),
        .split => |s| subtreeVisible(tree, s.left) or subtreeVisible(tree, s.right),
    };
}

/// Re-establish invariants 1 and 3 after any change to the tree or the stash.
/// Returns the pane it had to restore, if any — the caller's cue that the
/// layout changed under it. Idempotent and cheap with nothing stashed.
pub fn normalize(tree: anytype) ?*@TypeOf(tree.*).View {
    if (tree.isEmpty()) return null;
    var restored: ?*@TypeOf(tree.*).View = null;
    if (visibleLeafCount(tree.*) == 0) {
        if (topStashed(tree.*)) |top| {
            unmark(top);
            restored = top;
        }
    }
    if (tree.zoomed) |z| {
        if (!subtreeVisible(tree.*, z)) tree.zoom(null);
    }
    return restored;
}

/// Whether the split at `handle` shows BOTH sides — the stash-aware "this
/// split has a divider on screen". False for a leaf.
pub fn splitShowing(tree: anytype, handle: anytype) bool {
    if (handle.idx() >= tree.nodes.len) return false;
    return switch (tree.nodes[handle.idx()]) {
        .leaf => false,
        .split => |s| subtreeVisible(tree, s.left) and subtreeVisible(tree, s.right),
    };
}

/// The nearest ancestor of `from` on `layout`'s axis whose divider is ON
/// SCREEN: `SplitTree.nearestSplit` with collapsed splits stepped over. A
/// keyboard resize that moved a collapsed split would change nothing the user
/// can see and quietly move the slot a stashed pane comes back to.
pub fn nearestShowingSplit(tree: anytype, layout: anytype, from: anytype) ?@TypeOf(from) {
    var at = tree.nearestSplit(layout, from) orelse return null;
    while (!splitShowing(tree, at)) {
        at = tree.nearestSplit(layout, at) orelse return null;
    }
    return at;
}

/// A new tree holding only the visible leaves, splits with a stashed side
/// collapsed — Mac's `visibleTree`, as a real tree the shared spatial code
/// (directional focus, `equalize`) can run on. Map a result back to the full
/// tree by VIEW, never by handle: the two trees number their nodes
/// differently. The caller owns it and must `deinit` it.
pub fn visibleClone(tree: anytype, gpa: std.mem.Allocator) std.mem.Allocator.Error!@TypeOf(tree) {
    var cur = try tree.clone(gpa);
    errdefer cur.deinit();
    while (true) {
        var victim: ?@TypeOf(tree).Node.Handle = null;
        var it = cur.iterator();
        while (it.next()) |entry| {
            if (isStashed(entry.view)) {
                victim = entry.handle;
                break;
            }
        }
        // `.root` would empty the tree; invariant 1 says it cannot happen,
        // and stopping keeps a broken invariant from becoming an empty tab.
        const h = victim orelse break;
        if (h == .root) break;
        const next = try cur.remove(gpa, h);
        cur.deinit();
        cur = next;
    }
    return cur;
}

/// Copy every visible split's ratio from `visible` (a `visibleClone` of
/// `full`, after a ratio-only change such as `equalize`) back onto the full
/// tree's split it came from, IN PLACE. Collapsed splits keep their ratios,
/// which is what returns a restored pane to the size it left at. Mac's
/// `liftingLayout(from:)`.
pub fn liftRatios(full: anytype, visible: anytype) void {
    if (full.isEmpty() or visible.isEmpty()) return;
    const fr: @TypeOf(full.*).Node.Handle = .root;
    const vr: @TypeOf(visible).Node.Handle = .root;
    liftNode(full, fr, visible, vr);
}

fn liftNode(full: anytype, fh: anytype, visible: anytype, vh: anytype) void {
    if (fh.idx() >= full.nodes.len or vh.idx() >= visible.nodes.len) return;
    switch (full.nodes[fh.idx()]) {
        .leaf => {},
        .split => |s| {
            const lv = subtreeVisible(full.*, s.left);
            const rv = subtreeVisible(full.*, s.right);
            if (lv and rv) {
                const vs = switch (visible.nodes[vh.idx()]) {
                    .split => |x| x,
                    .leaf => return,
                };
                full.resizeInPlace(fh, vs.ratio);
                liftNode(full, s.left, visible, vs.left);
                liftNode(full, s.right, visible, vs.right);
            } else if (lv) {
                liftNode(full, s.left, visible, vh);
            } else if (rv) {
                liftNode(full, s.right, visible, vh);
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Tests

const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

/// A view that is its own reference, so a pane's `stash_seq` is the same
/// memory in every tree that holds it (the split_tree test view copies on
/// `ref`, which would make the mark invisible to the tree).
const TestView = struct {
    label: []const u8,
    stash_seq: u64 = 0,

    pub fn ref(self: *TestView, alloc: std.mem.Allocator) std.mem.Allocator.Error!*TestView {
        _ = alloc;
        return self;
    }
    pub fn unref(self: *TestView, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
    pub fn splitTreeLabel(self: *const TestView) []const u8 {
        return self.label;
    }
};
const Tree = SplitTree(TestView);

/// A | (B / C): root split horizontal, its right side split vertical.
fn threePane(alloc: std.mem.Allocator, a: *TestView, b: *TestView, c: *TestView) !Tree {
    var ta = try Tree.init(alloc, a);
    defer ta.deinit();
    var tb = try Tree.init(alloc, b);
    defer tb.deinit();
    var tc = try Tree.init(alloc, c);
    defer tc.deinit();
    var bc = try tb.split(alloc, .root, .down, 0.5, &tc);
    defer bc.deinit();
    return try ta.split(alloc, .root, .right, 0.5, &bc);
}

test "pane_stash: stash and restore change only the mark, never the tree" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();
    const nodes_before = tree.nodes.len;

    try checkStash(tree, &b);
    mark(&b);
    try std.testing.expect(isStashed(&b));
    try std.testing.expectEqual(@as(usize, 2), visibleLeafCount(tree));
    try std.testing.expectEqual(@as(usize, 1), stashedCount(tree));
    try std.testing.expect(contains(tree, &b));
    try std.testing.expectEqual(nodes_before, tree.nodes.len);

    unmark(&b);
    try std.testing.expectEqual(@as(usize, 3), visibleLeafCount(tree));
}

test "pane_stash: the last visible pane cannot be stashed" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();

    mark(&a);
    mark(&b);
    try std.testing.expectError(error.LastVisiblePane, checkStash(tree, &c));
    // Re-stashing a stashed pane is always allowed: it only reorders.
    try checkStash(tree, &a);

    var single = try Tree.init(alloc, &c);
    defer single.deinit();
    unmark(&c);
    try std.testing.expectError(error.LastVisiblePane, checkStash(single, &c));
}

test "pane_stash: a pane outside the tree is refused" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var stranger: TestView = .{ .label = "X" };
    var tree = try Tree.init(alloc, &a);
    defer tree.deinit();
    try std.testing.expectError(error.NotInTree, checkStash(tree, &stranger));
}

test "pane_stash: the top of the stash is the most recent, and indexes follow" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();

    try std.testing.expect(topStashed(tree) == null);
    mark(&a);
    mark(&c);
    try std.testing.expect(topStashed(tree).? == &c);
    try std.testing.expectEqual(@as(?usize, 0), stashIndex(tree, &c));
    try std.testing.expectEqual(@as(?usize, 1), stashIndex(tree, &a));
    try std.testing.expectEqual(@as(?usize, null), stashIndex(tree, &b));

    // Re-stashing moves it back to the top.
    mark(&a);
    try std.testing.expect(topStashed(tree).? == &a);
    try std.testing.expectEqual(@as(?usize, 1), stashIndex(tree, &c));
}

test "pane_stash: a split with one stashed side collapses; visibility is per subtree" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();

    const root = tree.nodes[0].split;
    try std.testing.expect(subtreeVisible(tree, root.left));
    try std.testing.expect(subtreeVisible(tree, root.right));
    mark(&b);
    try std.testing.expect(subtreeVisible(tree, root.right));
    mark(&c);
    try std.testing.expect(!subtreeVisible(tree, root.right));
    try std.testing.expect(subtreeVisible(tree, root.left));
    try std.testing.expect(!isVisiblySplit(tree));
}

test "pane_stash: normalize restores the top when nothing would be on screen" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();

    try std.testing.expect(normalize(&tree) == null);
    // Simulate a close of the last visible pane leaving only stashed ones.
    mark(&b);
    mark(&c);
    mark(&a);
    try std.testing.expect(normalize(&tree).? == &a);
    try std.testing.expect(!isStashed(&a));
    try std.testing.expect(isStashed(&b) and isStashed(&c));
    try std.testing.expect(normalize(&tree) == null);
}

test "pane_stash: normalize clears a zoom whose every leaf is stashed" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();

    // Zoom the B/C split, then stash both of its leaves.
    tree.zoom(tree.nodes[0].split.right);
    mark(&b);
    mark(&c);
    _ = normalize(&tree);
    try std.testing.expect(tree.zoomed == null);

    // A zoom with a visible leaf survives.
    unmark(&b);
    tree.zoom(tree.nodes[0].split.right);
    _ = normalize(&tree);
    try std.testing.expect(tree.zoomed != null);
}

test "pane_stash: only splits with both sides on screen are showing" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();
    const root: Tree.Node.Handle = .root;
    const bc = tree.nodes[0].split.right;

    try std.testing.expect(splitShowing(tree, root) and splitShowing(tree, bc));
    mark(&b);
    try std.testing.expect(splitShowing(tree, root));
    try std.testing.expect(!splitShowing(tree, bc));

    // From C, the nearest vertical split is the collapsed B/C one: there is
    // no visible vertical divider at all, so there is nothing to resize.
    var c_handle: ?Tree.Node.Handle = null;
    var it = tree.iterator();
    while (it.next()) |e| if (e.view == &c) {
        c_handle = e.handle;
    };
    try std.testing.expect(tree.nearestSplit(.vertical, c_handle.?) != null);
    try std.testing.expect(nearestShowingSplit(tree, .vertical, c_handle.?) == null);
    // The horizontal root divider is still on screen and is found.
    try std.testing.expect(nearestShowingSplit(tree, .horizontal, c_handle.?).? == root);
}

test "pane_stash: the visible clone is the on-screen arrangement" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();

    mark(&b);
    var vis = try visibleClone(tree, alloc);
    defer vis.deinit();
    // A | C: one split, two leaves, B nowhere.
    try std.testing.expectEqual(@as(usize, 3), vis.nodes.len);
    try std.testing.expect(!contains(vis, &b));
    try std.testing.expect(contains(vis, &a) and contains(vis, &c));
    // The full tree is untouched.
    try std.testing.expectEqual(@as(usize, 5), tree.nodes.len);
}

test "pane_stash: a recorded stash round-trips its order, top preserved" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();

    // Capture side: stash B then C, so C is the top (index 0).
    mark(&b);
    mark(&c);
    try std.testing.expectEqual(@as(?u32, 1), recordedIndex(tree, &b));
    try std.testing.expectEqual(@as(?u32, 0), recordedIndex(tree, &c));
    try std.testing.expectEqual(@as(?u32, null), recordedIndex(tree, &a));

    // Restore side: fresh panes (nothing marked), recorded in tree order —
    // the order a restore walk meets them, which is NOT stash order.
    unmark(&b);
    unmark(&c);
    var rec = [_]Recorded(TestView){
        .{ .view = &b, .index = 1 },
        .{ .view = &c, .index = 0 },
    };
    try std.testing.expect(applyRecorded(&tree, &rec) == null);
    try std.testing.expect(!isStashed(&a));
    try std.testing.expect(topStashed(tree).? == &c);
    try std.testing.expectEqual(@as(?u32, 1), recordedIndex(tree, &b));
    try std.testing.expectEqual(@as(?u32, 0), recordedIndex(tree, &c));
}

test "pane_stash: a recorded stash that would hide every pane leaves the top visible" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();

    var rec = [_]Recorded(TestView){
        .{ .view = &a, .index = 2 },
        .{ .view = &b, .index = 0 },
        .{ .view = &c, .index = 1 },
    };
    try std.testing.expect(applyRecorded(&tree, &rec).? == &b);
    try std.testing.expectEqual(@as(usize, 1), visibleLeafCount(tree));
    try std.testing.expect(!isStashed(&b));
    // C was next under the top, so it is the new top.
    try std.testing.expect(topStashed(tree).? == &c);
}

test "pane_stash: a recorded entry for a view outside the tree is ignored" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var stranger: TestView = .{ .label = "X" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();

    var rec = [_]Recorded(TestView){
        .{ .view = &stranger, .index = 0 },
        .{ .view = &a, .index = 1 },
    };
    try std.testing.expect(applyRecorded(&tree, &rec) == null);
    try std.testing.expect(!isStashed(&stranger));
    try std.testing.expect(isStashed(&a));
    try std.testing.expectEqual(@as(usize, 1), stashedCount(tree));
}

test "pane_stash: equalize on the visible tree lifts back, collapsed splits keep their ratio" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();
    const bc = tree.nodes[0].split.right;
    tree.resizeInPlace(.root, 0.2);
    tree.resizeInPlace(bc, 0.7);

    mark(&b);
    var vis = try visibleClone(tree, alloc);
    defer vis.deinit();
    var eq = try vis.equalize(alloc);
    defer eq.deinit();
    liftRatios(&tree, eq);

    // A | C on screen: equal halves, not the 1:2 the full tree's leaf count
    // would have given. The collapsed B/C split kept the 0.7 B left at.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), @as(f32, tree.nodes[0].split.ratio), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), @as(f32, tree.nodes[bc.idx()].split.ratio), 0.01);
}

test "pane_stash: markAt stashes at a gap and keeps the others' order (T1844)" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();

    mark(&b);
    mark(&c); // stash, top first: C, B
    markAt(tree, &a, 1); // between them: C, A, B
    try std.testing.expectEqual(@as(?usize, 0), stashIndex(tree, &c));
    try std.testing.expectEqual(@as(?usize, 1), stashIndex(tree, &a));
    try std.testing.expectEqual(@as(?usize, 2), stashIndex(tree, &b));

    // An index past the end appends at the bottom.
    unmark(&a);
    markAt(tree, &a, 99);
    try std.testing.expectEqual(@as(?usize, 2), stashIndex(tree, &a));
    try std.testing.expectEqual(@as(?usize, 0), stashIndex(tree, &c));

    // Index 0 is the top, the same as a plain stash.
    markAt(tree, &a, 0);
    try std.testing.expectEqual(@as(?usize, 0), stashIndex(tree, &a));
    try std.testing.expectEqual(@as(?usize, 1), stashIndex(tree, &c));
    try std.testing.expectEqual(@as(?usize, 2), stashIndex(tree, &b));
}

test "pane_stash: markAt on a stashed pane reorders it among the others (T1844)" {
    const alloc = std.testing.allocator;
    var a: TestView = .{ .label = "A" };
    var b: TestView = .{ .label = "B" };
    var c: TestView = .{ .label = "C" };
    var tree = try threePane(alloc, &a, &b, &c);
    defer tree.deinit();

    mark(&a);
    mark(&b); // B, A
    markAt(tree, &b, 1); // dragged below A: A, B
    try std.testing.expectEqual(@as(?usize, 0), stashIndex(tree, &a));
    try std.testing.expectEqual(@as(?usize, 1), stashIndex(tree, &b));
    try std.testing.expect(!isStashed(&c));
    // Dropped back where it already is: nothing moves.
    markAt(tree, &b, 1);
    try std.testing.expectEqual(@as(?usize, 1), stashIndex(tree, &b));
}
