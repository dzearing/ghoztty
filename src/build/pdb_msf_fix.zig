//! Make an LLD-written PDB readable by Zig's own stack-trace reader (T919).
//!
//! A PDB is an MSF container: fixed-size blocks, a stream directory that
//! lists which blocks hold each stream, and a Free Block Map whose home is
//! blocks 1 and 2 of every `block_size`-block interval. LLD only reserves
//! the FPM blocks the file actually needs (one pair covers 32768 blocks, so
//! 128 MB at 4 KiB) and is free to put stream data in the positions of the
//! later, unneeded pairs. That is valid MSF — dbghelp and cdb read it — but
//! `std.debug.Pdb` (zig 0.15.2, `Msf.init`) rejects any stream block whose
//! index is `1` or `2` modulo the block size with `error.InvalidBlockIndex`,
//! and a panicking test then prints
//!
//!     Unable to dump stack trace: InvalidBlockIndex
//!
//! instead of the frames. Measured 2026-09-23 over the lane cache: 24 of 256
//! `ghostty-test.pdb` and 31 of 110 `ghoztty-agent-test.pdb` builds carried
//! such blocks, always at 7*4096+1 / +2 — the test PDBs are 110-130 MB.
//!
//! The fix leaves the reader alone and moves the data: every stream block at
//! one of those positions is copied to a fresh block appended to the file,
//! the directory entry is repointed, the new blocks are marked used in the
//! Free Block Map, and the vacated slot is refilled the way LLD fills the
//! slots it reserves. The map bookkeeping is not optional: Microsoft's reader
//! refuses a PDB whose map disagrees with the directory in either direction
//! ("file system or network error reading pdb", and cdb falls back to export
//! symbols) — measured 2026-09-23 against the Store WinDbg's cdbX64. Nothing
//! else moves. Idempotent: a clean file is untouched.

const std = @import("std");

pub const Error = error{
    NotAPdb,
    UnsupportedBlockSize,
    TruncatedPdb,
    InvalidStreamDirectory,
    /// Marking the new blocks used would need a Free Block Map slot the file
    /// does not have. Rare (the file must sit within a few blocks of a
    /// multiple of bs*8); the PDB is left exactly as it was.
    FpmWouldGrow,
} || std.mem.Allocator.Error;

const magic = "Microsoft C/C++ MSF 7.00\r\n\x1aDS\x00\x00\x00";

/// Superblock field offsets (llvm.org/docs/PDB/MsfFile.html).
const off_block_size = 32;
const off_free_block_map_block = 36;
const off_num_blocks = 40;
const off_num_directory_bytes = 44;
const off_block_map_addr = 52;

/// The positions `std.debug.Pdb` refuses for stream data: the superblock,
/// and the two FPM slots of every interval.
pub fn isReservedForZig(block: u32, block_size: u32) bool {
    const n = block % block_size;
    return block == 0 or n == 1 or n == 2;
}

/// Relocate every stream block Zig's reader would reject. `pdb` holds the
/// whole file and grows by the appended blocks. Returns how many blocks
/// moved; zero means the file was already readable and is unchanged.
pub fn fix(alloc: std.mem.Allocator, pdb: *std.ArrayList(u8)) Error!usize {
    const bytes = pdb.items;
    if (bytes.len < 56 or !std.mem.eql(u8, bytes[0..magic.len], magic))
        return error.NotAPdb;
    const bs = readU32(bytes, off_block_size);
    switch (bs) {
        512, 1024, 2048, 4096 => {},
        else => return error.UnsupportedBlockSize,
    }
    const num_blocks = readU32(bytes, off_num_blocks);
    if (@as(u64, num_blocks) * bs != bytes.len) return error.TruncatedPdb;

    // Gather the directory, which is itself spread over blocks listed at
    // the block-map address.
    const dir_len = readU32(bytes, off_num_directory_bytes);
    const dir_block_count = std.math.divCeil(u32, dir_len, bs) catch unreachable;
    const map_off = @as(u64, readU32(bytes, off_block_map_addr)) * bs;
    if (map_off + @as(u64, dir_block_count) * 4 > bytes.len) return error.InvalidStreamDirectory;
    const dir_blocks = try alloc.alloc(u32, dir_block_count);
    defer alloc.free(dir_blocks);
    for (dir_blocks, 0..) |*b, i| {
        b.* = readU32(bytes, map_off + i * 4);
        if (@as(u64, b.*) * bs + bs > bytes.len) return error.InvalidStreamDirectory;
    }
    const dir = try alloc.alloc(u8, dir_len);
    defer alloc.free(dir);
    for (dir_blocks, 0..) |b, i| {
        const start = i * bs;
        const n = @min(bs, dir_len - start);
        @memcpy(dir[start..][0..n], bytes[@as(usize, b) * bs ..][0..n]);
    }

    // Find the directory entries naming a rejected block.
    if (dir_len < 4) return error.InvalidStreamDirectory;
    const stream_count = readU32(dir, 0);
    var pos: u64 = 4 + @as(u64, stream_count) * 4;
    if (pos > dir_len) return error.InvalidStreamDirectory;
    var rejected: std.ArrayList(u64) = .empty;
    defer rejected.deinit(alloc);
    for (0..stream_count) |s| {
        const size = readU32(dir, 4 + s * 4);
        const blocks = if (size == 0xFFFFFFFF) 0 else std.math.divCeil(u32, size, bs) catch unreachable;
        for (0..blocks) |_| {
            if (pos + 4 > dir_len) return error.InvalidStreamDirectory;
            const old = readU32(dir, pos);
            if (@as(u64, old) * bs + bs > bytes.len) return error.InvalidStreamDirectory;
            if (isReservedForZig(old, bs)) {
                // The superblock and the first interval's two FPM slots are
                // live in every file; a stream naming one is corrupt, not
                // something to repair.
                if (old < bs) return error.InvalidStreamDirectory;
                try rejected.append(alloc, pos);
            }
            pos += 4;
        }
    }
    if (rejected.items.len == 0) return 0;

    // Where the copies will go: the end of the file, stepping over the slots
    // zig would reject there too.
    var next = num_blocks;
    for (rejected.items) |_| {
        while (isReservedForZig(next, bs)) next += 1;
        next += 1;
    }

    // Microsoft's reader (dbghelp, cdb) refuses a stream block the Free Block
    // Map calls free, so the appended blocks must be marked used. The map is
    // the concatenation of the active FPM slot of each interval, one bit per
    // block; if the new blocks would need a slot the file does not have yet
    // (the file crossing bs*8 blocks), that slot may already hold stream
    // data, so refuse rather than hand cdb a PDB it cannot read.
    const fpm = readU32(bytes, off_free_block_map_block);
    if (fpm != 1 and fpm != 2) return error.NotAPdb;
    const bits_per_slot = bs * 8;
    if (std.math.divCeil(u32, next, bits_per_slot) catch unreachable >
        std.math.divCeil(u32, num_blocks, bits_per_slot) catch unreachable)
        return error.FpmWouldGrow;

    try pdb.resize(alloc, @as(usize, next) * bs);
    // Padding over a reserved slot is filled like one; the copies overwrite
    // the rest.
    @memset(pdb.items[bytes.len..], 0xFF);
    var new = num_blocks;
    for (rejected.items) |entry| {
        while (isReservedForZig(new, bs)) new += 1;
        const old = readU32(dir, entry);
        @memcpy(
            pdb.items[@as(usize, new) * bs ..][0..bs],
            pdb.items[@as(usize, old) * bs ..][0..bs],
        );
        writeU32(dir, entry, new);
        new += 1;
        // The vacated slot goes back to what LLD writes into the slots it
        // does reserve: all ones, still marked used. Microsoft's reader
        // insists the map describe the file exactly — a used block nothing
        // references is refused unless it sits in an FPM slot, and a free
        // block something references is refused always — so the old block
        // must stay used, and it is only allowed to because it is a slot.
        @memset(pdb.items[@as(usize, old) * bs ..][0..bs], 0xFF);
    }
    for (num_blocks..next) |b| {
        const slot = fpm + (b / bits_per_slot) * bs;
        const byte = @as(usize, slot) * bs + (b % bits_per_slot) / 8;
        pdb.items[byte] &= ~(@as(u8, 1) << @intCast(b % 8));
    }

    // Scatter the directory back over its own blocks and grow the count.
    for (dir_blocks, 0..) |b, i| {
        const start = i * bs;
        const n = @min(bs, dir_len - start);
        @memcpy(pdb.items[@as(usize, b) * bs ..][0..n], dir[start..][0..n]);
    }
    writeU32(pdb.items, off_num_blocks, next);
    return rejected.items.len;
}

/// True when `block` is marked free in the active Free Block Map.
pub fn isFree(pdb: []const u8, block: u32) bool {
    const bs = readU32(pdb, off_block_size);
    const fpm = readU32(pdb, off_free_block_map_block);
    const slot = fpm + (block / (bs * 8)) * bs;
    const byte = pdb[@as(usize, slot) * bs + (block % (bs * 8)) / 8];
    return (byte >> @intCast(block % 8)) & 1 == 1;
}

fn readU32(bytes: []const u8, off: u64) u32 {
    return std.mem.readInt(u32, bytes[@intCast(off)..][0..4], .little);
}

fn writeU32(bytes: []u8, off: u64, v: u32) void {
    std.mem.writeInt(u32, bytes[@intCast(off)..][0..4], v, .little);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const test_bs = 512;

/// Build a minimal MSF: superblock at 0, FPM at 1-2, directory block map at
/// block 3, directory at block 4, then the given streams (each a list of
/// block indices; each block is stamped with its stream number so a copy
/// can be told from a lost block).
fn buildPdb(alloc: std.mem.Allocator, num_blocks: u32, streams: []const []const u32) !std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    try list.resize(alloc, @as(usize, num_blocks) * test_bs);
    @memset(list.items, 0);
    const b = list.items;
    @memcpy(b[0..magic.len], magic);
    writeU32(b, off_block_size, test_bs);
    writeU32(b, off_free_block_map_block, 1);
    writeU32(b, off_num_blocks, num_blocks);
    // FPM at block 1 (plus block 513, 1025, ... for a file past 4096
    // blocks): every existing block used, everything past the end free.
    var slot: u32 = 1;
    while (slot < num_blocks) : (slot += test_bs) @memset(b[@as(usize, slot) * test_bs ..][0..test_bs], 0xFF);
    for (0..num_blocks) |blk| {
        const s = 1 + (blk / (test_bs * 8)) * test_bs;
        b[s * test_bs + (blk % (test_bs * 8)) / 8] &= ~(@as(u8, 1) << @intCast(blk % 8));
    }
    writeU32(b, off_block_map_addr, 3);
    writeU32(b, 3 * test_bs, 4);
    var pos: usize = 4 * test_bs;
    writeU32(b, pos, @intCast(streams.len));
    pos += 4;
    for (streams) |s| {
        writeU32(b, pos, @intCast(s.len * test_bs));
        pos += 4;
    }
    for (streams, 0..) |s, si| for (s) |blk| {
        writeU32(b, pos, blk);
        pos += 4;
        @memset(b[@as(usize, blk) * test_bs ..][0..test_bs], @intCast(0xA0 + si));
    };
    writeU32(b, off_num_directory_bytes, @intCast(pos - 4 * test_bs));
    return list;
}

fn streamBlock(pdb: []const u8, stream: usize, index: usize, stream_count: usize) u32 {
    var pos: usize = 4 * test_bs + 4 + stream_count * 4;
    var s: usize = 0;
    while (s < stream) : (s += 1) pos += 4 * (readU32(pdb, 4 * test_bs + 4 + s * 4) / test_bs);
    return readU32(pdb, pos + index * 4);
}

test "pdb_msf_fix: a clean PDB is left byte-for-byte alone" {
    const alloc = testing.allocator;
    var pdb = try buildPdb(alloc, 20, &.{ &.{ 5, 6 }, &.{7} });
    defer pdb.deinit(alloc);
    const before = try alloc.dupe(u8, pdb.items);
    defer alloc.free(before);
    try testing.expectEqual(@as(usize, 0), try fix(alloc, &pdb));
    try testing.expectEqualSlices(u8, before, pdb.items);
}

test "pdb_msf_fix: stream blocks in a later FPM slot move to the end, data intact" {
    const alloc = testing.allocator;
    // 1100 blocks spans three 512-block intervals; 513/514 and 1025 are the
    // positions LLD uses and zig rejects.
    var pdb = try buildPdb(alloc, 1100, &.{ &.{ 5, 513 }, &.{ 514, 1025, 600 } });
    defer pdb.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), try fix(alloc, &pdb));

    const b = pdb.items;
    const n = readU32(b, off_num_blocks);
    try testing.expectEqual(@as(usize, n) * test_bs, b.len);
    try testing.expectEqual(@as(u32, 5), streamBlock(b, 0, 0, 2));
    try testing.expectEqual(@as(u32, 600), streamBlock(b, 1, 2, 2));
    for ([_][2]usize{ .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 } }) |sb| {
        const blk = streamBlock(b, sb[0], sb[1], 2);
        try testing.expect(blk >= 1100);
        try testing.expect(!isReservedForZig(blk, test_bs));
        try testing.expectEqual(@as(u8, @intCast(0xA0 + sb[0])), b[@as(usize, blk) * test_bs + 7]);
    }
    // The vacated slots look like LLD's reserved ones again.
    for ([_]usize{ 513, 514, 1025 }) |blk| {
        try testing.expectEqual(@as(u8, 0xFF), b[blk * test_bs]);
        try testing.expect(!isFree(b, @intCast(blk)));
    }
    // Running it again finds nothing: the fix is idempotent.
    try testing.expectEqual(@as(usize, 0), try fix(alloc, &pdb));
}

test "pdb_msf_fix: appended blocks skip the reserved slots of the next interval" {
    const alloc = testing.allocator;
    // The file ends right before 1025, the first reserved slot of interval 2.
    var pdb = try buildPdb(alloc, 1025, &.{&.{ 513, 514 }});
    defer pdb.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), try fix(alloc, &pdb));
    try testing.expectEqual(@as(u32, 1027), streamBlock(pdb.items, 0, 0, 1));
    try testing.expectEqual(@as(u32, 1028), streamBlock(pdb.items, 0, 1, 1));
    try testing.expectEqual(@as(u32, 1029), readU32(pdb.items, off_num_blocks));
}

test "pdb_msf_fix: every appended block is marked used in the Free Block Map" {
    const alloc = testing.allocator;
    var pdb = try buildPdb(alloc, 1025, &.{&.{ 513, 514 }});
    defer pdb.deinit(alloc);
    try testing.expect(isFree(pdb.items, 1025));
    _ = try fix(alloc, &pdb);
    // 1025/1026 are the padding over reserved slots, 1027/1028 the copies.
    for (0..1029) |blk| try testing.expect(!isFree(pdb.items, @intCast(blk)));
    try testing.expect(isFree(pdb.items, 1029));
}

test "pdb_msf_fix: a fix that would need a new Free Block Map slot is refused untouched" {
    const alloc = testing.allocator;
    // One 512-byte FPM slot covers 4096 blocks; relocating two blocks from
    // a 4095-block file lands past 4096.
    var pdb = try buildPdb(alloc, 4095, &.{&.{ 513, 514 }});
    defer pdb.deinit(alloc);
    const before = try alloc.dupe(u8, pdb.items);
    defer alloc.free(before);
    try testing.expectError(error.FpmWouldGrow, fix(alloc, &pdb));
    try testing.expectEqualSlices(u8, before, pdb.items);
}

test "pdb_msf_fix: a stream naming a live FPM slot is corrupt, not repaired" {
    const alloc = testing.allocator;
    var pdb = try buildPdb(alloc, 20, &.{&.{ 5, 1 }});
    defer pdb.deinit(alloc);
    try testing.expectError(error.InvalidStreamDirectory, fix(alloc, &pdb));
}

test "pdb_msf_fix: not a PDB is refused, not rewritten" {
    const alloc = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    try list.appendSlice(alloc, "MZ" ++ "\x00" ** 100);
    try testing.expectError(error.NotAPdb, fix(alloc, &list));
}
