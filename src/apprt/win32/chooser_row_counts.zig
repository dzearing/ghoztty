//! The machine chooser's per-machine session COUNTS (T1745) - what each row of
//! the machine list says in its count capsule.
//!
//! Mac draws a small capsule after every machine's name holding that machine's
//! active-session count (`MachineChooserView.countBadge(for:)`), fed from a
//! roster it caches PER MACHINE: it refreshes only the local one and the
//! selected remote, so a machine you browsed earlier keeps its last-loaded
//! count and one you never browsed shows nothing. Windows holds exactly one
//! roster (the selected row's, `SessionRoster`), so the per-machine half lives
//! here: every roster adoption records its count under the machine it was
//! fetched from, and every row reads its own entry back at paint time.
//!
//! The rules that make it Mac's badge rather than a number:
//!
//! - A machine is keyed by WHAT IT IS, not by where its row happens to sit: the
//!   local agent, or a relay device by its id. A refiltered list reorders rows;
//!   it must not move a count onto another machine.
//! - The id is COPIED. The device list the roster borrows from is replaced on
//!   every directory refresh, and a count that outlived its key's storage would
//!   read freed memory on the next paint.
//! - Recorded only once the roster has LOADED; cleared when a fetch for that
//!   machine fails (Mac hides the capsule on failure), left alone while one is
//!   in flight (the last loaded count stands, as Mac's cached roster does).
//! - A zero count is stored (it is a real answer) but never DRAWN - see
//!   `shown`, the one place "is there a capsule" is decided.
//!
//! Pure, so it runs in the `none` lane.

const std = @import("std");
const chooser_sessions = @import("chooser_sessions.zig");

/// The longest device id the cache holds. Relay device ids are UUID-shaped
/// (36 bytes); 128 leaves room for any format change without making every entry
/// large. A longer id is not an error - its machine simply shows no capsule.
pub const max_id_len: usize = 128;

/// How many machines' counts are held at once. The chooser caps its list at
/// `MachineChooser.MAX_DEVICES` (128) devices plus Local, so this matches it:
/// a count can never be evicted by the list it belongs to.
pub const capacity: usize = 129;

/// Which machine a count belongs to. The device id is BORROWED here; the cache
/// copies it on `set`.
pub const Key = union(enum) {
    local,
    device: []const u8,

    pub fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .local => b == .local,
            .device => |ai| switch (b) {
                .device => |bi| std.mem.eql(u8, ai, bi),
                .local => false,
            },
        };
    }

    /// The oracle's spelling of the key: `local`, or the device id.
    pub fn name(self: Key) []const u8 {
        return switch (self) {
            .local => "local",
            .device => |id| id,
        };
    }
};

/// The key for a roster target, or null when the roster is pointed at nothing.
pub fn keyFor(target: chooser_sessions.Target) ?Key {
    return switch (target) {
        .none => null,
        .local => .local,
        .remote => |id| .{ .device = id },
    };
}

/// The number a row's capsule shows, or null when it shows no capsule: never
/// loaded (or cleared by a failure), or loaded at zero. Mac's
/// `n > 0` guard, in the one place both the painter and the hit test ask.
pub fn shown(count: ?usize) ?usize {
    const n = count orelse return null;
    if (n == 0) return null;
    return n;
}

/// The capsule's text: the bare number, like Mac's `Text("\(n)")`.
pub fn text(buf: []u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch buf[0..0];
}

const Entry = struct {
    local: bool,
    id: [max_id_len]u8,
    id_len: usize,
    count: usize,

    fn matches(self: *const Entry, key: Key) bool {
        return switch (key) {
            .local => self.local,
            .device => |id| !self.local and std.mem.eql(u8, self.id[0..self.id_len], id),
        };
    }
};

/// What a `set` or `clear` did, so the caller logs and repaints only on a real
/// change.
pub const Change = enum { unchanged, changed };

pub const Cache = struct {
    entries: [capacity]Entry = undefined,
    len: usize = 0,

    fn find(self: *const Cache, key: Key) ?usize {
        for (self.entries[0..self.len], 0..) |*e, i| {
            if (e.matches(key)) return i;
        }
        return null;
    }

    /// The last loaded count for `key`, or null when it has none.
    pub fn get(self: *const Cache, key: Key) ?usize {
        const i = self.find(key) orelse return null;
        return self.entries[i].count;
    }

    /// Record `count` for `key`. A device id too long to hold records nothing
    /// (its row shows no capsule, which is the honest answer for a machine the
    /// cache cannot name). A full cache drops its OLDEST entry, which can only
    /// happen to a machine no longer in the list.
    pub fn set(self: *Cache, key: Key, count: usize) Change {
        if (self.find(key)) |i| {
            if (self.entries[i].count == count) return .unchanged;
            self.entries[i].count = count;
            return .changed;
        }
        var e: Entry = .{ .local = key == .local, .id = undefined, .id_len = 0, .count = count };
        switch (key) {
            .local => {},
            .device => |id| {
                if (id.len > max_id_len) return .unchanged;
                @memcpy(e.id[0..id.len], id);
                e.id_len = id.len;
            },
        }
        if (self.len == capacity) self.removeAt(0);
        self.entries[self.len] = e;
        self.len += 1;
        return .changed;
    }

    /// Forget `key`'s count (its fetch failed). `.unchanged` when it had none.
    pub fn clear(self: *Cache, key: Key) Change {
        const i = self.find(key) orelse return .unchanged;
        self.removeAt(i);
        return .changed;
    }

    fn removeAt(self: *Cache, i: usize) void {
        var j = i;
        while (j + 1 < self.len) : (j += 1) self.entries[j] = self.entries[j + 1];
        self.len -= 1;
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "Cache: a machine never loaded has no count" {
    var c: Cache = .{};
    try testing.expect(c.get(.local) == null);
    try testing.expect(c.get(.{ .device = "dev-a" }) == null);
}

test "Cache: set then get, per machine, and local is not a device" {
    var c: Cache = .{};
    try testing.expectEqual(Change.changed, c.set(.local, 3));
    try testing.expectEqual(Change.changed, c.set(.{ .device = "dev-a" }, 1));
    try testing.expectEqual(@as(?usize, 3), c.get(.local));
    try testing.expectEqual(@as(?usize, 1), c.get(.{ .device = "dev-a" }));
    try testing.expect(c.get(.{ .device = "dev-b" }) == null);
    // A device literally named "local" is still a device.
    try testing.expect(c.get(.{ .device = "local" }) == null);
}

test "Cache: re-setting the same count is unchanged, a new one is a change" {
    var c: Cache = .{};
    _ = c.set(.local, 2);
    try testing.expectEqual(Change.unchanged, c.set(.local, 2));
    try testing.expectEqual(Change.changed, c.set(.local, 3));
    try testing.expectEqual(@as(?usize, 3), c.get(.local));
    try testing.expectEqual(@as(usize, 1), c.len);
}

test "Cache: the device id is COPIED, so the caller's buffer can go away" {
    var c: Cache = .{};
    var id_buf = "dev-a".*;
    _ = c.set(.{ .device = &id_buf }, 4);
    // The directory refresh that replaced the device list reused the memory.
    id_buf = "XXXXX".*;
    try testing.expectEqual(@as(?usize, 4), c.get(.{ .device = "dev-a" }));
    try testing.expect(c.get(.{ .device = "XXXXX" }) == null);
}

test "Cache: clear forgets one machine and leaves the rest" {
    var c: Cache = .{};
    _ = c.set(.local, 2);
    _ = c.set(.{ .device = "dev-a" }, 5);
    _ = c.set(.{ .device = "dev-b" }, 6);
    try testing.expectEqual(Change.changed, c.clear(.{ .device = "dev-a" }));
    try testing.expect(c.get(.{ .device = "dev-a" }) == null);
    try testing.expectEqual(@as(?usize, 2), c.get(.local));
    try testing.expectEqual(@as(?usize, 6), c.get(.{ .device = "dev-b" }));
    // Clearing what is not there says so, so nothing logs a phantom clear.
    try testing.expectEqual(Change.unchanged, c.clear(.{ .device = "dev-a" }));
}

test "Cache: an id too long to hold records nothing" {
    var c: Cache = .{};
    const long = "x" ** (max_id_len + 1);
    try testing.expectEqual(Change.unchanged, c.set(.{ .device = long }, 2));
    try testing.expect(c.get(.{ .device = long }) == null);
    // Exactly the cap is fine.
    const edge = "y" ** max_id_len;
    try testing.expectEqual(Change.changed, c.set(.{ .device = edge }, 2));
    try testing.expectEqual(@as(?usize, 2), c.get(.{ .device = edge }));
}

test "Cache: a full cache drops its oldest entry, never the newest" {
    var c: Cache = .{};
    var bufs: [capacity + 1][8]u8 = undefined;
    for (0..capacity + 1) |i| {
        const id = std.fmt.bufPrint(&bufs[i], "d{d}", .{i}) catch unreachable;
        _ = c.set(.{ .device = id }, i + 1);
    }
    try testing.expectEqual(capacity, c.len);
    try testing.expect(c.get(.{ .device = "d0" }) == null);
    try testing.expectEqual(@as(?usize, 2), c.get(.{ .device = "d1" }));
    const last = std.fmt.bufPrint(&bufs[capacity], "d{d}", .{capacity}) catch unreachable;
    try testing.expectEqual(@as(?usize, capacity + 1), c.get(.{ .device = last }));
}

test "keyFor: the roster's target names the machine, none names nothing" {
    try testing.expect(keyFor(.none) == null);
    try testing.expect(keyFor(.local).?.eql(.local));
    try testing.expect(keyFor(.{ .remote = "dev-a" }).?.eql(.{ .device = "dev-a" }));
    try testing.expect(!keyFor(.{ .remote = "dev-a" }).?.eql(.local));
    try testing.expect(!keyFor(.{ .remote = "dev-a" }).?.eql(.{ .device = "dev-b" }));
}

test "Key.name is the oracle's spelling" {
    try testing.expectEqualStrings("local", (Key{ .local = {} }).name());
    try testing.expectEqualStrings("dev-a", (Key{ .device = "dev-a" }).name());
}

test "shown: hidden before a load, after a failure, and at zero (Mac's n > 0)" {
    try testing.expect(shown(null) == null);
    try testing.expect(shown(0) == null);
    try testing.expectEqual(@as(?usize, 1), shown(1));
    try testing.expectEqual(@as(?usize, 12), shown(12));

    // The composition end to end: load, fail, reload at zero, reload at two.
    var c: Cache = .{};
    try testing.expect(shown(c.get(.local)) == null); // loading
    _ = c.set(.local, 3);
    try testing.expectEqual(@as(?usize, 3), shown(c.get(.local))); // loaded
    _ = c.clear(.local);
    try testing.expect(shown(c.get(.local)) == null); // failed
    _ = c.set(.local, 0);
    try testing.expect(shown(c.get(.local)) == null); // loaded, empty
    _ = c.set(.local, 2);
    try testing.expectEqual(@as(?usize, 2), shown(c.get(.local)));
}

test "the count capsule is the session badges' chip, at every scale (§3.1)" {
    // One status-chip shape in the dialog: a row's count capsule and a session
    // card's badge are the same height, padding and radius, or the two halves
    // of the chooser speak two chip dialects side by side.
    const chooser_rows = @import("chooser_rows.zig");
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const rm = chooser_rows.rowMetrics(scale);
        const sm = chooser_sessions.metrics(scale);
        try testing.expectEqual(sm.badge_h, rm.count_h);
        try testing.expectEqual(sm.badge_pad_x, rm.count_pad_x);
        try testing.expectEqual(sm.badge_radius, chooser_rows.countBadge(rm, 400, 20).?.radius);
    }
}

test "text is the bare number" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("1", text(&buf, 1));
    try testing.expectEqualStrings("128", text(&buf, 128));
    var tiny: [1]u8 = undefined;
    try testing.expectEqualStrings("", text(&tiny, 42));
}
