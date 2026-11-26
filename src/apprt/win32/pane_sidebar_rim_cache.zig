//! The rail tiles' resting rims, kept between paints (T2333).
//!
//! A rail tile's glassy rim (T2309, `pane_sidebar_motion.tileRim`) is a pure
//! function of the tile's size, corner radius, hairline width, theme and
//! hover - none of which a scroll step, a hover elsewhere or a busy pane's
//! motion frame changes. Before this, every paint ran `Overlay.pixel` over
//! every tile it drew, so a rail of forty tiles recomputed forty identical
//! bitmaps per scroll step. The paint now asks this cache first and only a
//! tile whose busy sheen is showing (which moves every frame) is computed per
//! paint.
//!
//! Generic over the value so the eviction rules are unit-tested here with
//! plain integers; `PaneSidebar` stores its premultiplied DIBs in it and
//! destroys whatever `put` hands back.
const std = @import("std");
const motion = @import("pane_sidebar_motion.zig");

/// Everything a resting tile's rim bitmap depends on. Two tiles with equal
/// keys draw byte-identical overlays.
pub const Key = struct {
    w: i32,
    h: i32,
    radius: i32,
    /// The hairline's width in pixels, by its bits (it is `rim_dip * scale`).
    rim_w_bits: u64,
    dark: bool,
    rim: motion.TileRim,

    pub fn init(w: i32, h: i32, radius: i32, rim_w: f64, dark: bool, rim: motion.TileRim) Key {
        return .{ .w = w, .h = h, .radius = radius, .rim_w_bits = @bitCast(rim_w), .dark = dark, .rim = rim };
    }

    pub fn eql(a: Key, b: Key) bool {
        return a.w == b.w and a.h == b.h and a.radius == b.radius and
            a.rim_w_bits == b.rim_w_bits and a.dark == b.dark and
            a.rim.top == b.rim.top and a.rim.bottom == b.rim.bottom;
    }
};

/// Whether a paint may take the overlay from the cache: a tile's rim with no
/// busy layer showing. A busy tile's sheen moves with the clock, so it is
/// computed every paint as before; a full row has no rim and draws nothing.
pub fn cacheable(busy: f64, tile_rim: ?motion.TileRim) bool {
    return busy <= 0 and tile_rim != null;
}

/// How many distinct rims a rail shows at once: two themes are never on
/// screen together, so in practice this is {resting, hovered} x the one or
/// two tile sizes (pane tiles, window tiles) - with room for a DPI change
/// mid-session before the old scale's entries age out.
pub const default_cap = 8;

pub fn Cache(comptime V: type, comptime cap: usize) type {
    return struct {
        const Self = @This();
        pub const Slot = struct { key: Key, value: V };

        slots: [cap]Slot = undefined,
        len: usize = 0,
        /// The slot the next insert into a full cache replaces: oldest first.
        next: usize = 0,
        hits: u64 = 0,
        misses: u64 = 0,

        /// The value cached for `key`, counting the hit or the miss.
        pub fn get(self: *Self, key: Key) ?V {
            for (self.slots[0..self.len]) |s| if (s.key.eql(key)) {
                self.hits += 1;
                return s.value;
            };
            self.misses += 1;
            return null;
        }

        /// Cache `value` for `key` (not already cached). Returns the value it
        /// evicted to make room, which the caller frees.
        pub fn put(self: *Self, key: Key, value: V) ?V {
            if (self.len < cap) {
                self.slots[self.len] = .{ .key = key, .value = value };
                self.len += 1;
                return null;
            }
            const old = self.slots[self.next].value;
            self.slots[self.next] = .{ .key = key, .value = value };
            self.next = (self.next + 1) % cap;
            return old;
        }

        /// Every value held, for the caller to free; the cache is empty after.
        pub fn drain(self: *Self) []const Slot {
            const all = self.slots[0..self.len];
            self.len = 0;
            self.next = 0;
            return all;
        }
    };
}

const testing = std.testing;

fn keyOf(w: i32, dark: bool, hovered: bool) Key {
    return Key.init(w, 30, 6, 0.5, dark, motion.tileRim(dark, hovered));
}

test "rim cache: a repeat paint of the same tile is a hit" {
    var c: Cache(u32, 4) = .{};
    try testing.expectEqual(@as(?u32, null), c.get(keyOf(30, true, false)));
    try testing.expectEqual(@as(?u32, null), c.put(keyOf(30, true, false), 7));
    try testing.expectEqual(@as(?u32, 7), c.get(keyOf(30, true, false)));
    try testing.expectEqual(@as(?u32, 7), c.get(keyOf(30, true, false)));
    try testing.expectEqual(@as(u64, 2), c.hits);
    try testing.expectEqual(@as(u64, 1), c.misses);
}

test "rim cache: hover, theme, size and scale each key a different bitmap" {
    var c: Cache(u32, 8) = .{};
    _ = c.put(keyOf(30, true, false), 1);
    try testing.expectEqual(@as(?u32, null), c.get(keyOf(30, true, true)));
    try testing.expectEqual(@as(?u32, null), c.get(keyOf(30, false, false)));
    try testing.expectEqual(@as(?u32, null), c.get(keyOf(31, true, false)));
    try testing.expectEqual(@as(?u32, null), c.get(Key.init(30, 30, 6, 0.75, true, motion.tileRim(true, false))));
    try testing.expectEqual(@as(?u32, null), c.get(Key.init(30, 30, 9, 0.5, true, motion.tileRim(true, false))));
    try testing.expectEqual(@as(?u32, 1), c.get(keyOf(30, true, false)));
}

test "rim cache: a full cache evicts its oldest entry and hands it back" {
    var c: Cache(u32, 2) = .{};
    try testing.expectEqual(@as(?u32, null), c.put(keyOf(10, true, false), 10));
    try testing.expectEqual(@as(?u32, null), c.put(keyOf(20, true, false), 20));
    try testing.expectEqual(@as(?u32, 10), c.put(keyOf(30, true, false), 30));
    try testing.expectEqual(@as(?u32, null), c.get(keyOf(10, true, false)));
    try testing.expectEqual(@as(?u32, 20), c.get(keyOf(20, true, false)));
    try testing.expectEqual(@as(?u32, 20), c.put(keyOf(40, true, false), 40));
    try testing.expectEqual(@as(?u32, 30), c.get(keyOf(30, true, false)));
    try testing.expectEqual(@as(?u32, 40), c.get(keyOf(40, true, false)));
}

test "rim cache: drain hands back everything and empties it" {
    var c: Cache(u32, 2) = .{};
    _ = c.put(keyOf(10, true, false), 10);
    _ = c.put(keyOf(20, true, false), 20);
    _ = c.put(keyOf(30, true, false), 30);
    var sum: u32 = 0;
    for (c.drain()) |s| sum += s.value;
    try testing.expectEqual(@as(u32, 50), sum);
    try testing.expectEqual(@as(?u32, null), c.get(keyOf(20, true, false)));
    try testing.expectEqual(@as(?u32, null), c.put(keyOf(50, true, false), 50));
}

test "rim cache: only a resting tile is cacheable" {
    try testing.expect(cacheable(0, motion.tileRim(true, false)));
    try testing.expect(!cacheable(0.4, motion.tileRim(true, false)));
    try testing.expect(!cacheable(0, null));
}

test "rim cache: a resting tile's overlay does not move with the clock" {
    // The premise of the cache: with no busy layer the overlay is a pure
    // function of the key, so the bitmap cached at one paint is the one any
    // later paint would have computed.
    const k = keyOf(24, true, true);
    var a = motion.Overlay.init(24, 30, 6, 0.5, true);
    a.busyAt(0, 1_000);
    a.tile_rim = k.rim;
    var b = motion.Overlay.init(24, 30, 6, 0.5, true);
    b.busyAt(0, 987_654);
    b.tile_rim = k.rim;
    try testing.expect(cacheable(a.busy, a.tile_rim));
    for (0..30) |y| for (0..24) |x| {
        try testing.expectEqual(a.pixel(x, y), b.pixel(x, y));
    };
}
