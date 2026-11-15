//! Changed-byte tracking for GPU buffer uploads (T2972).
//!
//! The OpenGL renderer used to re-upload every cell buffer on every frame:
//! the whole background-cell array and then one `glBufferSubData` per row
//! list of foreground cells, even when a single row (or nothing) changed.
//! `Shadow` keeps a CPU copy of exactly the bytes the GPU buffer holds, so a
//! sync can compute the one byte range that differs and upload only that.
//! The buffer layout is untouched - rows stay concatenated in list order -
//! so instance ordering (cursor-first / cursor-last lists) is preserved by
//! construction, which a fixed-slot-per-row scheme would have had to rebuild.
//!
//! Pure: no GL here, so the range logic is unit-tested in the `none` lane.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A byte range `[start, end)` of a buffer that must be uploaded.
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
};

/// CPU mirror of a GPU buffer's contents.
pub const Shadow = struct {
    /// Backing storage; its length is the GPU buffer's capacity in bytes.
    bytes: []u8 = &.{},

    /// How many leading bytes of `bytes` are known to equal the GPU buffer.
    /// Everything at or past this offset is treated as unknown (dirty).
    valid: usize = 0,

    /// Pending dirty range accumulated by `write` since the last `take`.
    dirty: ?Range = null,

    pub fn deinit(self: *Shadow, alloc: Allocator) void {
        if (self.bytes.len > 0) alloc.free(self.bytes);
        self.* = .{};
    }

    /// The GPU buffer was reallocated to `capacity` bytes, so its contents
    /// are undefined: nothing is known to match any more.
    pub fn reset(self: *Shadow, alloc: Allocator, capacity: usize) Allocator.Error!void {
        if (self.bytes.len != capacity) {
            const next = try alloc.alloc(u8, capacity);
            if (self.bytes.len > 0) alloc.free(self.bytes);
            self.bytes = next;
        }
        self.valid = 0;
        self.dirty = null;
    }

    /// Stage `data` at byte `offset` (which must lie within capacity),
    /// widening the pending dirty range by whatever actually differs from
    /// what the GPU already holds.
    pub fn write(self: *Shadow, offset: usize, data: []const u8) void {
        if (data.len == 0) return;
        const end = offset + data.len;
        std.debug.assert(end <= self.bytes.len);
        const dst = self.bytes[offset..end];

        // Bytes past `valid` are unknown and therefore always dirty.
        const known_end = @min(end, @max(self.valid, offset));
        const known = known_end - offset;

        var first: ?usize = null;
        var last: usize = 0;
        if (known > 0) {
            if (firstDiff(dst[0..known], data[0..known])) |i| {
                first = i;
                last = lastDiffEnd(dst[i..known], data[i..known]) + i;
            }
        }
        if (known < data.len) {
            if (first == null) first = known;
            last = data.len;
        }

        if (first) |f| {
            @memcpy(dst[f..last], data[f..last]);
            self.widen(.{ .start = offset + f, .end = offset + last });
        }
    }

    /// Block size for the comparisons below. `std.mem.eql` compares a block
    /// with wide loads; a byte loop over a whole unchanged screen (hundreds
    /// of KB, every frame, every pane) cost more than the upload it saved.
    const block = 512;

    /// Index of the first byte where `a` and `b` (equal length) differ.
    fn firstDiff(a: []const u8, b: []const u8) ?usize {
        var off: usize = 0;
        while (off < a.len) : (off += block) {
            const end = @min(off + block, a.len);
            if (!std.mem.eql(u8, a[off..end], b[off..end])) {
                return off + std.mem.indexOfDiff(u8, a[off..end], b[off..end]).?;
            }
        }
        return null;
    }

    /// One past the last byte where `a` and `b` differ; the caller knows
    /// byte 0 differs, so the answer is at least 1.
    fn lastDiffEnd(a: []const u8, b: []const u8) usize {
        var end: usize = a.len;
        while (end > 0) {
            const start = end -| block;
            if (!std.mem.eql(u8, a[start..end], b[start..end])) {
                var j = end;
                while (j > start and a[j - 1] == b[j - 1]) j -= 1;
                return j;
            }
            end = start;
        }
        return 0;
    }

    fn widen(self: *Shadow, r: Range) void {
        if (self.dirty) |d| {
            self.dirty = .{ .start = @min(d.start, r.start), .end = @max(d.end, r.end) };
        } else {
            self.dirty = r;
        }
    }

    /// Return the range to upload (its bytes are `bytes[r.start..r.end]`)
    /// and mark it as matching the GPU. The caller must upload it.
    pub fn take(self: *Shadow) ?Range {
        const r = self.dirty orelse return null;
        self.dirty = null;
        // The upload covers [r.start, r.end); the GPU now matches up to the
        // furthest point that is contiguous with what was already valid.
        if (r.start <= self.valid) self.valid = @max(self.valid, r.end);
        return r;
    }
};

const testing = std.testing;

test "first write uploads everything" {
    var s: Shadow = .{};
    defer s.deinit(testing.allocator);
    try s.reset(testing.allocator, 16);
    s.write(0, "abcdefgh");
    const r = s.take().?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 8), r.end);
    try testing.expectEqualStrings("abcdefgh", s.bytes[r.start..r.end]);
    try testing.expectEqual(@as(usize, 8), s.valid);
}

test "identical write uploads nothing" {
    var s: Shadow = .{};
    defer s.deinit(testing.allocator);
    try s.reset(testing.allocator, 16);
    s.write(0, "abcdefgh");
    _ = s.take();
    s.write(0, "abcdefgh");
    try testing.expectEqual(@as(?Range, null), s.take());
}

test "one changed byte uploads one byte" {
    var s: Shadow = .{};
    defer s.deinit(testing.allocator);
    try s.reset(testing.allocator, 16);
    s.write(0, "abcdefgh");
    _ = s.take();
    s.write(0, "abcXefgh");
    const r = s.take().?;
    try testing.expectEqual(@as(usize, 3), r.start);
    try testing.expectEqual(@as(usize, 4), r.end);
    try testing.expectEqualStrings("abcXefgh", s.bytes[0..8]);
}

test "changes in two lists merge into one covering range" {
    var s: Shadow = .{};
    defer s.deinit(testing.allocator);
    try s.reset(testing.allocator, 32);
    // Two row lists written back to back, as syncFromArrayLists does.
    s.write(0, "aaaa");
    s.write(4, "bbbb");
    s.write(8, "cccc");
    _ = s.take();
    s.write(0, "aXaa");
    s.write(4, "bbbb");
    s.write(8, "cccY");
    const r = s.take().?;
    try testing.expectEqual(@as(usize, 1), r.start);
    try testing.expectEqual(@as(usize, 12), r.end);
    try testing.expectEqualStrings("aXaabbbbcccY", s.bytes[0..12]);
}

test "a row that grows shifts later rows and they upload" {
    var s: Shadow = .{};
    defer s.deinit(testing.allocator);
    try s.reset(testing.allocator, 32);
    s.write(0, "aa");
    s.write(2, "bb");
    _ = s.take();
    // Row 0 grew by one item; row 1 now starts at 3.
    s.write(0, "aaa");
    s.write(3, "bb");
    const r = s.take().?;
    try testing.expectEqual(@as(usize, 2), r.start);
    try testing.expectEqual(@as(usize, 5), r.end);
    try testing.expectEqualStrings("aaabb", s.bytes[0..5]);
    try testing.expectEqual(@as(usize, 5), s.valid);
}

test "bytes past valid are always dirty even if they happen to match" {
    var s: Shadow = .{};
    defer s.deinit(testing.allocator);
    try s.reset(testing.allocator, 8);
    @memset(s.bytes, 'z');
    // Shadow storage already holds 'z' but the GPU contents are undefined.
    s.write(0, "zzzz");
    const r = s.take().?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 4), r.end);
}

test "reset after reallocation forgets everything" {
    var s: Shadow = .{};
    defer s.deinit(testing.allocator);
    try s.reset(testing.allocator, 8);
    s.write(0, "abcd");
    _ = s.take();
    try s.reset(testing.allocator, 16);
    s.write(0, "abcd");
    const r = s.take().?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 4), r.end);
}

test "diffs straddling block boundaries are found exactly" {
    var s: Shadow = .{};
    defer s.deinit(testing.allocator);
    const n = Shadow.block * 3 + 17;
    try s.reset(testing.allocator, n);
    const a = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(a);
    @memset(a, 'a');
    s.write(0, a);
    _ = s.take();
    try testing.expectEqual(@as(?Range, null), blk: {
        s.write(0, a);
        break :blk s.take();
    });
    a[Shadow.block - 1] = 'X';
    a[Shadow.block * 2] = 'Y';
    s.write(0, a);
    const r = s.take().?;
    try testing.expectEqual(@as(usize, Shadow.block - 1), r.start);
    try testing.expectEqual(@as(usize, Shadow.block * 2 + 1), r.end);
    try testing.expectEqualSlices(u8, a, s.bytes[0..n]);
}

test "shrinking contents leaves the tail valid and uploads only the change" {
    var s: Shadow = .{};
    defer s.deinit(testing.allocator);
    try s.reset(testing.allocator, 16);
    s.write(0, "abcdefgh");
    _ = s.take();
    s.write(0, "abcd");
    try testing.expectEqual(@as(?Range, null), s.take());
    try testing.expectEqual(@as(usize, 8), s.valid);
}
