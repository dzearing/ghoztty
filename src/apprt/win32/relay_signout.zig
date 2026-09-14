//! What signing out does to the windows the account paid for, and what signing
//! back in gives back (T713, the Windows half of Mac's `ed8482d25`).
//!
//! ## The defect this closes
//!
//! Sign-out revoked the session at the relay and deleted the local store — and
//! then left every window that had been dialed on that account sitting open,
//! still attached to another machine, still rendering that machine's shells.
//! Nothing new could be dialed (every win32 dial path already refuses a
//! tokenless relay open), but "sign out" that leaves the authenticated surfaces
//! on screen is not the thing the words promise. It is the same shape on both
//! seats, and Mac fixed it by closing those windows and replaying them on the
//! next sign-in.
//!
//! ## The three rules
//!
//!   - **Only ACCOUNT-backed windows close.** A window dialed straight at
//!     `host:port` is not an account resource — nobody signed in to open it and
//!     signing out does not take it away. `isAccountBacked` is that whole rule
//!     and it is stated over the machine union, so it is checkable without a
//!     window.
//!   - **Closing DETACHES, never terminates.** The sessions keep running on the
//!     machine that hosts them, exactly as T1390's Disconnect does — which is
//!     what makes the restore below possible and what keeps a sign-out from
//!     killing somebody's build. The mechanism is T1390's `DetachPin`, pinned
//!     on every pane before the close marks them.
//!   - **What was closed is REMEMBERED by session, not by window.** A restore
//!     rebuilds from the far agent's own layout store (`RestoreAllRelay`), and
//!     the honest filter over those layouts is "the windows holding the sessions
//!     we just let go of" — never "every window that machine has ever held",
//!     which would hand the user back windows they had closed themselves.
//!
//! ## What is pure here
//!
//! The rule and the store. `Store` is plain owned strings with no window, app
//! or socket in it, so the dedupe, the union and the consume are unit-tested in
//! the win32 lane without a desktop — the same split `session_disconnect.zig`
//! draws for the same reason.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

/// Whether this window's machine is one the ACCOUNT opened, i.e. whether
/// signing out takes it away.
///
/// A relay window rode the account's bearer to get there; a direct-TCP window
/// was reached with nothing but a host and a port, and a local window was never
/// dialed at all. Null (no machine) is a local window.
pub fn isAccountBacked(machine: ?Window.RemoteMachine) bool {
    const m = machine orelse return false;
    return switch (m) {
        .relay => true,
        .tcp => false,
    };
}

/// Pin DETACH on every pane of `window`, whatever the Disconnect offer would
/// have said about them (T713's second rule).
///
/// The offer's own rule is narrower on purpose — it covers only panes a
/// CONFIRMATION was shown for, and a user who turned `confirm-close-surface`
/// off asked not to be asked. Sign-out asks nobody, so that clause has nothing
/// to gate: the windows are being taken away by the app, and ending somebody's
/// remote build because they had close confirmations switched off would be the
/// app punishing a preference. Viewers have no session and pin to nothing.
///
/// It lives here rather than on `Window` deliberately: it reads the same two
/// fields `Window.pinDisconnect` does and adds no state, and a method on
/// `Window.zig` would put nine unrelated acceptance harnesses due over a
/// six-line loop (the T712 lesson — the stamp keys on file content).
pub fn pinDetachAll(window: *Window) void {
    for (window.tab_trees[0..window.tab_count]) |*tree| {
        var it = tree.iterator();
        while (it.next()) |entry| entry.view.pinDetach();
    }
}

/// One machine whose windows a sign-out closed, and the sessions those windows
/// were holding when it did. All strings owned by the store.
pub const Entry = struct {
    base: []u8,
    device: []u8,
    /// The agent session ids the closed windows had attached. Empty is
    /// possible — a window whose panes had not finished attaching — and it is
    /// NOT the same as "restore everything": an entry with no sessions has
    /// nothing identifiable to bring back and is dropped by the restore.
    sessions: [][]u8,

    fn deinit(self: Entry, alloc: Allocator) void {
        alloc.free(self.base);
        alloc.free(self.device);
        for (self.sessions) |s| alloc.free(s);
        if (self.sessions.len > 0) alloc.free(self.sessions);
    }
};

/// What a sign-out suspended, waiting for the sign-in that replays it.
///
/// In memory only, and deliberately so: the sessions it names live on the FAR
/// agent, which is where they survive a crash or a quit. Persisting this would
/// promise a restore across app restarts that the far machine's own layout
/// store already serves better (that is what "Restore All" is).
pub const Store = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Store, alloc: Allocator) void {
        self.clear(alloc);
        self.entries.deinit(alloc);
    }

    pub fn clear(self: *Store, alloc: Allocator) void {
        for (self.entries.items) |e| e.deinit(alloc);
        self.entries.clearRetainingCapacity();
    }

    pub fn isEmpty(self: *const Store) bool {
        return self.entries.items.len == 0;
    }

    /// Remember `sessions` as suspended on `base`/`device`. A machine already
    /// in the store gains the new ids rather than a second row — two windows on
    /// one machine are one restore — and an id already recorded is not
    /// duplicated. Every string is copied.
    pub fn add(
        self: *Store,
        alloc: Allocator,
        base: []const u8,
        device: []const u8,
        sessions: []const []const u8,
    ) Allocator.Error!void {
        if (self.find(base, device)) |e| return unionInto(alloc, e, sessions);

        var ids: std.ArrayList([]u8) = .empty;
        errdefer {
            for (ids.items) |s| alloc.free(s);
            ids.deinit(alloc);
        }
        for (sessions) |s| {
            if (s.len == 0) continue;
            try ids.append(alloc, try alloc.dupe(u8, s));
        }

        const base_copy = try alloc.dupe(u8, base);
        errdefer alloc.free(base_copy);
        const device_copy = try alloc.dupe(u8, device);
        errdefer alloc.free(device_copy);
        try self.entries.append(alloc, .{
            .base = base_copy,
            .device = device_copy,
            .sessions = try ids.toOwnedSlice(alloc),
        });
    }

    fn find(self: *Store, base: []const u8, device: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.base, base) and std.mem.eql(u8, e.device, device)) return e;
        }
        return null;
    }

    fn unionInto(alloc: Allocator, e: *Entry, sessions: []const []const u8) Allocator.Error!void {
        var ids: std.ArrayList([]u8) = .empty;
        try ids.appendSlice(alloc, e.sessions);
        errdefer ids.deinit(alloc);
        for (sessions) |s| {
            if (s.len == 0) continue;
            var seen = false;
            for (ids.items) |have| {
                if (std.mem.eql(u8, have, s)) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            try ids.append(alloc, try alloc.dupe(u8, s));
        }
        if (e.sessions.len > 0) alloc.free(e.sessions);
        e.sessions = try ids.toOwnedSlice(alloc);
    }

    /// Hand the whole suspended set to the caller and empty the store. The
    /// caller owns every entry and frees it with `freeEntries`.
    ///
    /// Consuming is the point: a restore that has been ATTEMPTED must not be
    /// attempted again on the next sign-in, because by then the user has had
    /// every chance to close those windows deliberately and bringing them back
    /// a second time would be the app arguing with them.
    pub fn take(self: *Store, alloc: Allocator) Allocator.Error![]Entry {
        const out = try self.entries.toOwnedSlice(alloc);
        self.entries = .empty;
        return out;
    }

    pub fn freeEntries(alloc: Allocator, entries: []Entry) void {
        for (entries) |e| e.deinit(alloc);
        if (entries.len > 0) alloc.free(entries);
    }
};

/// Whether a layout window pulled from the far agent is one of the ones a
/// sign-out took away — i.e. whether a sign-in restore should rebuild it.
///
/// `leaf_sessions` is every session id the layout window's leaves name, and
/// `suspended` the ids that machine's entry recorded. One match is enough: a
/// window is restored as a unit, exactly as the double-attach guard treats it.
///
/// An EMPTY suspended set matches nothing. That is the load-bearing half —
/// "we remember no sessions" must never degrade into "restore everything this
/// machine has ever held".
pub fn restoresWindow(leaf_sessions: []const []const u8, suspended: []const []const u8) bool {
    if (suspended.len == 0) return false;
    for (leaf_sessions) |sid| {
        if (sid.len == 0) continue;
        for (suspended) |want| {
            if (std.mem.eql(u8, sid, want)) return true;
        }
    }
    return false;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "isAccountBacked: only a relay window is the account's" {
    try testing.expect(isAccountBacked(.{
        .relay = .{ .base = "https://relay", .device = "dev-abc" },
    }));
    // Dialed with a host and a port and no credential — signing out of an
    // account nobody used to open it must not take it away.
    try testing.expect(!isAccountBacked(.{ .tcp = .{ .host = "box", .port = 47913 } }));
    // A local window was never dialed at all.
    try testing.expect(!isAccountBacked(null));
}

test "Store.add: one row per machine, sessions unioned" {
    const alloc = testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);

    try testing.expect(store.isEmpty());
    try store.add(alloc, "https://relay", "dev-a", &.{ "s1", "s2" });
    try store.add(alloc, "https://relay", "dev-a", &.{ "s2", "s3" });
    try testing.expectEqual(@as(usize, 1), store.entries.items.len);
    try testing.expectEqual(@as(usize, 3), store.entries.items[0].sessions.len);

    // A different device on the same relay is a different machine.
    try store.add(alloc, "https://relay", "dev-b", &.{"s9"});
    try testing.expectEqual(@as(usize, 2), store.entries.items.len);
    try testing.expect(!store.isEmpty());
}

test "Store.add: an empty session id is not recorded" {
    const alloc = testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);

    try store.add(alloc, "https://relay", "dev-a", &.{ "", "s1", "" });
    try testing.expectEqual(@as(usize, 1), store.entries.items[0].sessions.len);
    try testing.expectEqualStrings("s1", store.entries.items[0].sessions[0]);
}

test "Store.take: consumes, so one sign-out is replayed once" {
    const alloc = testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);

    try store.add(alloc, "https://relay", "dev-a", &.{"s1"});
    const taken = try store.take(alloc);
    defer Store.freeEntries(alloc, taken);
    try testing.expectEqual(@as(usize, 1), taken.len);
    try testing.expectEqualStrings("dev-a", taken[0].device);
    // And the store is empty, so the NEXT sign-in restores nothing.
    try testing.expect(store.isEmpty());
}

test "restoresWindow: a window is restored when it holds a suspended session" {
    try testing.expect(restoresWindow(&.{ "x", "s2" }, &.{ "s1", "s2" }));
    try testing.expect(!restoresWindow(&.{ "x", "y" }, &.{ "s1", "s2" }));
}

test "restoresWindow: remembering nothing restores nothing (T713)" {
    // The rule that keeps a sign-out from turning into "Restore All": an entry
    // with no recorded sessions hands back no windows at all.
    try testing.expect(!restoresWindow(&.{ "s1", "s2" }, &.{}));
    // And an empty leaf id never matches an empty want.
    try testing.expect(!restoresWindow(&.{""}, &.{""}));
}
