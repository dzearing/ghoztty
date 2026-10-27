//! The pane sidebar's state every window shares (T2336; Mac b07b7fa0b /
//! 9a1f14230, `PaneSidebarSharedState.shared`).
//!
//! On Mac the sidebar is now ONE sidebar seen from every window: the
//! all-windows toggle, its search, the window and group folds and the
//! all-windows list's scroll position - with the expanded, hidden and width
//! preferences (`pane_sidebar_prefs`, held in `PaneSidebar.remembered`) - are
//! app-wide, so clicking through windows shows the same sidebar. Per window
//! stay only the order of its own panes (`Window.pane_sidebar_order`), its
//! identity in the list (a tab's key) and how it is drawn.
//!
//! Only the window in use redraws as a change happens. Every other window
//! keeps drawing its own copy and catches up when it is next activated
//! (Mac `PaneSidebarState.isLive` / `catchUp`): `gen` counts shared changes,
//! each sidebar remembers the one it last took (`needsCatchUp`), so a search
//! typed or a fold flipped in one window never repaints every window per
//! keystroke.
//!
//! Folds are ABSOLUTE, keyed by a window group's (a tab's) stable key, not
//! relative to the window looking: `unfolded` lists the groups whose panes
//! show in the all-windows list - turning the scope on opens the window it
//! was turned on from and leaves every other folded - and `folded_this` the
//! groups folded in their own "this window" list, which starts open. Turning
//! the scope off forgets the search and the window folds; project folds
//! outlive it (Mac `setShowsAllWindows`).
//!
//! The all-windows list's own ORDER (T2337, Mac `windowOrder`) is shared too:
//! one list of `project:<name>` / `window:<id>` keys
//! (`pane_sidebar_window_order`), changed by a drag in any window's list and
//! read by every one.
//!
//! Scroll (Mac `PaneSidebarScrollSync`): the all-windows list only, the
//! last list scrolled wins, the rail and the panel each keep their own (their
//! layouts differ), and a list takes the position up when its window is
//! activated or when it appears - never while it is being scrolled. A "this
//! window" list is each window's own content and is not synced.
//!
//! Pure, so its tests run in every app-runtime lane.

const std = @import("std");
const Allocator = std.mem.Allocator;
const search_field = @import("pane_sidebar_search.zig");

pub const KeySet = std.AutoHashMapUnmanaged(u64, void);

/// The two layouts a list scrolls in (Mac keeps one position per layout).
pub const Surface = enum(u1) {
    rail,
    panel,

    pub fn of(expanded: bool) Surface {
        return if (expanded) .panel else .rail;
    }
};

pub const Shared = struct {
    /// Bumped by every shared change (`changed`); a sidebar that last took
    /// an older one catches up when its window is next activated.
    gen: u64 = 0,
    all_windows: bool = false,
    /// The all-windows search: its text and caret.
    search: search_field.Field = .{},
    /// All-windows list: the groups whose panes show (every other is folded
    /// to its header).
    unfolded: KeySet = .{},
    /// "This window" list: the groups folded to their header.
    folded_this: KeySet = .{},
    /// Folded project groups, by project.
    folded_projects: KeySet = .{},
    /// Where the all-windows list was last scrolled, per layout; null until
    /// one has been.
    scroll: [2]?i32 = .{ null, null },
    /// The all-windows list's order (T2337): owned keys, empty until the
    /// first drag (the name order).
    window_order: std.ArrayListUnmanaged([]u8) = .{},

    pub fn deinit(self: *Shared, alloc: Allocator) void {
        self.unfolded.deinit(alloc);
        self.folded_this.deinit(alloc);
        self.folded_projects.deinit(alloc);
        self.freeOrder(alloc);
        self.window_order.deinit(alloc);
        self.* = .{};
    }

    fn freeOrder(self: *Shared, alloc: Allocator) void {
        for (self.window_order.items) |k| alloc.free(k);
        self.window_order.clearRetainingCapacity();
    }

    /// The order as keys, borrowed until the next `setWindowOrder`.
    pub fn windowOrder(self: *const Shared, out: [][]const u8) []const []const u8 {
        const n = @min(out.len, self.window_order.items.len);
        for (self.window_order.items[0..n], 0..) |k, i| out[i] = k;
        return out[0..n];
    }

    /// Replace the order with copies of `keys` (which may borrow the old
    /// one). True when it changed - a shared change every list catches up on.
    pub fn setWindowOrder(self: *Shared, alloc: Allocator, keys: []const []const u8) bool {
        if (keys.len == self.window_order.items.len) {
            for (keys, self.window_order.items) |a, b| {
                if (!std.mem.eql(u8, a, b)) break;
            } else return false;
        }
        var next: std.ArrayListUnmanaged([]u8) = .{};
        next.ensureTotalCapacity(alloc, keys.len) catch return false;
        for (keys) |k| {
            const d = alloc.dupe(u8, k) catch {
                for (next.items) |x| alloc.free(x);
                next.deinit(alloc);
                return false;
            };
            next.appendAssumeCapacity(d);
        }
        self.freeOrder(alloc);
        self.window_order.deinit(alloc);
        self.window_order = next;
        self.changed();
        return true;
    }

    /// Fold every project in `projects` (a group drag folds every group,
    /// T2337), answering the set as it was so the drop can put it back.
    pub fn foldProjects(self: *Shared, alloc: Allocator, projects: []const u64) KeySet {
        var before: KeySet = .{};
        copySet(alloc, &before, &self.folded_projects);
        for (projects) |p| self.folded_projects.put(alloc, p, {}) catch {};
        self.changed();
        return before;
    }

    /// Fold every window of the all-windows list to its row (a window drag,
    /// T2337), answering which were open.
    pub fn foldWindows(self: *Shared, alloc: Allocator) KeySet {
        var before: KeySet = .{};
        copySet(alloc, &before, &self.unfolded);
        self.unfolded.clearRetainingCapacity();
        self.changed();
        return before;
    }

    /// Put back a fold set a drag took (`foldProjects` / `foldWindows`),
    /// consuming `before`.
    pub fn restoreFolds(self: *Shared, alloc: Allocator, which: enum { projects, windows }, before: *KeySet) void {
        const set = switch (which) {
            .projects => &self.folded_projects,
            .windows => &self.unfolded,
        };
        set.deinit(alloc);
        set.* = before.*;
        before.* = .{};
        self.changed();
    }

    pub fn changed(self: *Shared) void {
        self.gen +%= 1;
    }

    /// The all-windows toggle, from the window whose group is `from_key`.
    /// On opens that window and folds every other; off forgets the search,
    /// the window folds and the list's scroll (each look starts from the
    /// default). True when anything changed.
    pub fn setAllWindows(self: *Shared, alloc: Allocator, on: bool, from_key: u64) bool {
        if (on == self.all_windows) return false;
        self.unfolded.clearRetainingCapacity();
        if (on) {
            self.unfolded.put(alloc, from_key, {}) catch {};
        } else {
            _ = self.search.clear();
            self.scroll = .{ null, null };
        }
        self.all_windows = on;
        self.changed();
        return true;
    }

    /// Whether group `key` shows only its header now. A search unfolds
    /// everything: a hit inside a fold would read as no hit.
    pub fn groupFolded(self: *const Shared, all_windows: bool, key: u64, searching: bool) bool {
        return folded(all_windows, &self.unfolded, &self.folded_this, key, searching);
    }

    /// Flip group `key`'s fold in the list `all_windows` names.
    pub fn toggleGroup(self: *Shared, alloc: Allocator, all_windows: bool, key: u64) void {
        flip(alloc, if (all_windows) &self.unfolded else &self.folded_this, key);
        self.changed();
    }

    pub fn toggleProject(self: *Shared, alloc: Allocator, key: u64) void {
        flip(alloc, &self.folded_projects, key);
        self.changed();
    }

    /// The search's text or caret changed (`search` was edited in place).
    pub fn searchEdited(self: *Shared) void {
        self.changed();
    }

    /// An all-windows list was scrolled to `y` in `surface`: the last list
    /// scrolled wins. Not a `changed`: the position is taken up when a list
    /// is activated or appears, which ask `scrollFor` themselves.
    pub fn recordScroll(self: *Shared, surface: Surface, y: i32) void {
        self.scroll[@intFromEnum(surface)] = y;
    }

    pub fn scrollFor(self: *const Shared, surface: Surface) ?i32 {
        return self.scroll[@intFromEnum(surface)];
    }
};

/// The fold rule, over a sidebar's drawn copy of the two window fold sets.
pub fn folded(all_windows: bool, unfolded: *const KeySet, folded_this: *const KeySet, key: u64, searching: bool) bool {
    if (searching) return false;
    return if (all_windows) !unfolded.contains(key) else folded_this.contains(key);
}

fn flip(alloc: Allocator, set: *KeySet, key: u64) void {
    if (!set.remove(key)) set.put(alloc, key, {}) catch {};
}

/// Whether a sidebar that last took shared change `seen` is behind.
pub fn needsCatchUp(seen: u64, shared: *const Shared) bool {
    return seen != shared.gen;
}

/// Copy `from` into `to`, reusing `to`'s storage. A sidebar's drawn copy of
/// a shared fold set.
pub fn copySet(alloc: Allocator, to: *KeySet, from: *const KeySet) void {
    to.clearRetainingCapacity();
    var it = from.keyIterator();
    while (it.next()) |k| to.put(alloc, k.*, {}) catch return;
}

/// The expanded and hidden flags a window should draw once it is caught up:
/// always the shared ones (Mac: a background window takes a collapse/expand
/// or hide/show, and resizes its grid for it, when it is next key). The
/// narrow-window rail is NOT decided here - that is the window's width
/// (`pane_sidebar.mode`), per window.
pub const Flags = struct { expanded: bool, hidden: bool };

pub fn flagsBehind(window: Flags, shared: Flags) bool {
    return window.expanded != shared.expanded or window.hidden != shared.hidden;
}

const testing = std.testing;

test "T2337: the window order is copied in, unchanged is no change, and it survives its source" {
    var s: Shared = .{};
    defer s.deinit(testing.allocator);
    const gen0 = s.gen;
    var a = "project:p".*;
    try testing.expect(s.setWindowOrder(testing.allocator, &.{ &a, "window:x" }));
    try testing.expect(needsCatchUp(gen0, &s));
    a[0] = 'X'; // the caller's buffer, not the stored key
    var buf: [4][]const u8 = undefined;
    const got = s.windowOrder(&buf);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("project:p", got[0]);
    const gen1 = s.gen;
    try testing.expect(!s.setWindowOrder(testing.allocator, &.{ "project:p", "window:x" }));
    try testing.expectEqual(gen1, s.gen);
    // Fed its own borrowed keys, reordered.
    const view = s.windowOrder(&buf);
    try testing.expect(s.setWindowOrder(testing.allocator, &.{ view[1], view[0] }));
    try testing.expectEqualStrings("window:x", s.windowOrder(&buf)[0]);
}

test "T2337: a drag's folds come back as they were" {
    var s: Shared = .{};
    defer s.deinit(testing.allocator);
    s.toggleProject(testing.allocator, 1);
    var before = s.foldProjects(testing.allocator, &.{ 1, 2, 3 });
    try testing.expectEqual(@as(u32, 3), s.folded_projects.count());
    s.restoreFolds(testing.allocator, .projects, &before);
    try testing.expectEqual(@as(u32, 1), s.folded_projects.count());
    try testing.expect(s.folded_projects.contains(1));

    _ = s.setAllWindows(testing.allocator, true, 7);
    s.toggleGroup(testing.allocator, true, 8);
    var open = s.foldWindows(testing.allocator);
    try testing.expectEqual(@as(u32, 0), s.unfolded.count());
    s.restoreFolds(testing.allocator, .windows, &open);
    try testing.expect(s.unfolded.contains(7) and s.unfolded.contains(8));
}

test "T2336: the scope opens the window it was turned on from and folds every other" {
    var s: Shared = .{};
    defer s.deinit(testing.allocator);
    try testing.expect(s.setAllWindows(testing.allocator, true, 7));
    try testing.expect(!s.groupFolded(true, 7, false));
    try testing.expect(s.groupFolded(true, 8, false));
    // Absolute: every window's list folds alike, whichever window looks.
    s.toggleGroup(testing.allocator, true, 8);
    try testing.expect(!s.groupFolded(true, 8, false));
    s.toggleGroup(testing.allocator, true, 7);
    try testing.expect(s.groupFolded(true, 7, false));
    // A search opens everything.
    try testing.expect(!s.groupFolded(true, 7, true));
    // Turning it on again is no change.
    try testing.expect(!s.setAllWindows(testing.allocator, true, 9));
}

test "T2336: turning the scope off forgets the search, window folds and scroll; project folds stay" {
    var s: Shared = .{};
    defer s.deinit(testing.allocator);
    _ = s.setAllWindows(testing.allocator, true, 1);
    _ = s.search.insert(&.{ 'z', 's' });
    s.toggleGroup(testing.allocator, true, 2);
    s.toggleProject(testing.allocator, 50);
    s.recordScroll(.panel, 120);
    try testing.expect(s.setAllWindows(testing.allocator, false, 1));
    try testing.expect(s.search.isEmpty());
    try testing.expectEqual(@as(?i32, null), s.scrollFor(.panel));
    try testing.expect(s.folded_projects.contains(50));
    // Back on from another window: that one opens, the earlier flip is gone.
    _ = s.setAllWindows(testing.allocator, true, 3);
    try testing.expect(s.groupFolded(true, 2, false));
    try testing.expect(!s.groupFolded(true, 3, false));
}

test "T2336: the this-window list starts open and keeps its folds apart from the overview's" {
    var s: Shared = .{};
    defer s.deinit(testing.allocator);
    try testing.expect(!s.groupFolded(false, 4, false));
    s.toggleGroup(testing.allocator, false, 4);
    try testing.expect(s.groupFolded(false, 4, false));
    // The overview's folds are their own: 4 folded here says nothing there.
    _ = s.setAllWindows(testing.allocator, true, 4);
    try testing.expect(!s.groupFolded(true, 4, false));
    // ...and leaving the scope does not forget a this-window fold.
    _ = s.setAllWindows(testing.allocator, false, 4);
    try testing.expect(s.groupFolded(false, 4, false));
}

test "T2336: every shared change is one a background sidebar catches up on" {
    var s: Shared = .{};
    defer s.deinit(testing.allocator);
    const seen = s.gen;
    try testing.expect(!needsCatchUp(seen, &s));
    _ = s.setAllWindows(testing.allocator, true, 1);
    try testing.expect(needsCatchUp(seen, &s));
    for ([_]*const fn (*Shared) void{
        struct {
            fn f(x: *Shared) void {
                x.toggleGroup(testing.allocator, true, 2);
            }
        }.f,
        struct {
            fn f(x: *Shared) void {
                x.toggleProject(testing.allocator, 3);
            }
        }.f,
        struct {
            fn f(x: *Shared) void {
                _ = x.search.insert(&.{'q'});
                x.searchEdited();
            }
        }.f,
    }) |change| {
        const before = s.gen;
        change(&s);
        try testing.expect(needsCatchUp(before, &s));
    }
    // A scroll is taken up on activation, not pushed: it is no change.
    const before = s.gen;
    s.recordScroll(.rail, 40);
    try testing.expect(!needsCatchUp(before, &s));
}

test "T2336: the last list scrolled wins, and the rail and the panel keep their own" {
    var s: Shared = .{};
    try testing.expectEqual(@as(?i32, null), s.scrollFor(.rail));
    s.recordScroll(.panel, 80);
    s.recordScroll(.panel, 160);
    s.recordScroll(.rail, 24);
    try testing.expectEqual(@as(?i32, 160), s.scrollFor(.panel));
    try testing.expectEqual(@as(?i32, 24), s.scrollFor(.rail));
    try testing.expectEqual(Surface.panel, Surface.of(true));
    try testing.expectEqual(Surface.rail, Surface.of(false));
}

test "T2336: a window whose flags differ from the shared ones is behind" {
    try testing.expect(!flagsBehind(.{ .expanded = true, .hidden = false }, .{ .expanded = true, .hidden = false }));
    try testing.expect(flagsBehind(.{ .expanded = false, .hidden = false }, .{ .expanded = true, .hidden = false }));
    try testing.expect(flagsBehind(.{ .expanded = true, .hidden = false }, .{ .expanded = true, .hidden = true }));
}

test "T2336: a drawn copy of a fold set is the shared set, reusing its storage" {
    var from: KeySet = .{};
    defer from.deinit(testing.allocator);
    var to: KeySet = .{};
    defer to.deinit(testing.allocator);
    try to.put(testing.allocator, 99, {});
    try from.put(testing.allocator, 1, {});
    try from.put(testing.allocator, 2, {});
    copySet(testing.allocator, &to, &from);
    try testing.expectEqual(@as(u32, 2), to.count());
    try testing.expect(to.contains(1) and to.contains(2) and !to.contains(99));
}
