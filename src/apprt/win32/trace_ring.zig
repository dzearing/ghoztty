//! A fixed ring of formatted trace lines, kept in memory and written out in
//! one burst later (T2485 D17). Pure, so the none lane can hold the rule.
//!
//! The stack trace (`GHOZTTY_STACK_TRACE`) logs every card a layout pass
//! places, and on the real desktop those writes cost ~7 ms a tick: a 53 fps
//! glide read as 39 fps with it on, and the A2 black column it was meant to
//! explain only showed with it off (T2485 D16). Formatting a line into a slot
//! here costs microseconds, so `GHOZTTY_STACK_TRACE=ring` keeps the same lines
//! at the product's own speed and writes them out once the drag is over.
//!
//! When the ring is full the oldest line goes; `dropped` says how many did.
const std = @import("std");

pub fn Ring(comptime slots: usize, comptime line_len: usize) type {
    return struct {
        const Self = @This();

        lines: [slots][line_len]u8 = @splat(@splat(0)),
        lens: [slots]u16 = @splat(0),
        /// The slot the next line goes into.
        head: usize = 0,
        count: usize = 0,
        dropped: u64 = 0,

        /// Format one line into the next slot. A line too long for a slot is
        /// kept cut short, ending in `~`, rather than dropped.
        pub fn add(self: *Self, comptime fmt: []const u8, args: anytype) void {
            const buf = &self.lines[self.head];
            const n: usize = if (std.fmt.bufPrint(buf, fmt, args)) |s| s.len else |_| blk: {
                buf[line_len - 1] = '~';
                break :blk line_len;
            };
            self.lens[self.head] = @intCast(n);
            self.head = (self.head + 1) % slots;
            if (self.count == slots) self.dropped += 1 else self.count += 1;
        }

        /// The lines held, oldest first.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .ring = self, .i = 0 };
        }

        pub const Iterator = struct {
            ring: *const Self,
            i: usize,

            pub fn next(it: *Iterator) ?[]const u8 {
                if (it.i >= it.ring.count) return null;
                const start = (it.ring.head + slots - it.ring.count) % slots;
                const slot = (start + it.i) % slots;
                it.i += 1;
                return it.ring.lines[slot][0..it.ring.lens[slot]];
            }
        };

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.count = 0;
            self.dropped = 0;
        }
    };
}

/// Which way `GHOZTTY_STACK_TRACE` sends its lines: unset or empty is off,
/// `ring` keeps them in memory until the drag ends, anything else logs each
/// line as it happens (the D9 behaviour).
pub const Mode = enum { off, log, ring };

pub fn modeOf(value: ?[]const u8) Mode {
    const v = std.mem.trim(u8, value orelse return .off, " \t\r\n");
    if (v.len == 0) return .off;
    if (std.ascii.eqlIgnoreCase(v, "ring")) return .ring;
    return .log;
}

const testing = std.testing;

test "a ring hands its lines back oldest first, and drops the oldest when full" {
    var r: Ring(3, 32) = .{};
    r.add("a={d}", .{1});
    r.add("b={d}", .{2});
    var it = r.iterator();
    try testing.expectEqualStrings("a=1", it.next().?);
    try testing.expectEqualStrings("b=2", it.next().?);
    try testing.expect(it.next() == null);

    r.add("c", .{});
    r.add("d", .{});
    try testing.expectEqual(@as(u64, 1), r.dropped);
    it = r.iterator();
    try testing.expectEqualStrings("b=2", it.next().?);
    try testing.expectEqualStrings("c", it.next().?);
    try testing.expectEqualStrings("d", it.next().?);
    try testing.expect(it.next() == null);

    r.clear();
    it = r.iterator();
    try testing.expect(it.next() == null);
}

test "a line longer than its slot is kept cut short, marked with ~" {
    var r: Ring(2, 8) = .{};
    r.add("{s}", .{"0123456789"});
    var it = r.iterator();
    const line = it.next().?;
    try testing.expectEqual(@as(usize, 8), line.len);
    try testing.expectEqual(@as(u8, '~'), line[7]);
}

test "GHOZTTY_STACK_TRACE=ring keeps the lines; any other value logs them" {
    try testing.expectEqual(Mode.off, modeOf(null));
    try testing.expectEqual(Mode.off, modeOf(" "));
    try testing.expectEqual(Mode.ring, modeOf("RING\r\n"));
    try testing.expectEqual(Mode.log, modeOf("1"));
}
