//! Agent-side **ring disk snapshots** — the scrollback half of the reboot floor
//! (§5.4, T13). `session_meta.zig` records WHICH sessions exist (so they can be
//! relaunched); this module records the recent OUTPUT of each session (so the
//! relaunched pane can replay its pre-restart scrollback instead of coming back
//! blank).
//!
//! A child process cannot outlive its agent, so on a reboot / crash / `kill -9`
//! the live pty and its in-RAM output ring are gone (POSIX). But the agent can
//! periodically flush each dirty session's ring to disk; after it restarts and
//! materializes the session (T12b), it preloads the snapshot into the fresh
//! ring, appends a "session restarted" divider, and replays the whole thing to
//! the reattaching viewer on `RELAUNCH` (server.zig). Best-effort by design: a
//! kernel panic loses ≤ the snapshot interval of tail output.
//!
//! ## On-disk format (`<rings_dir>/<session-id-hex>.ring`)
//!
//!   magic       : 4 bytes  "GRS2" (was "GRS1" — still read, see below)
//!   base_offset : u64 LE   absolute stream offset of the first retained byte
//!   cols        : u16 LE   pty width the retained bytes were produced at (GRS2)
//!   rows        : u16 LE   pty height at snapshot time (GRS2)
//!   byte_len    : u64 LE   number of ring bytes that follow
//!   bytes       : byte_len raw child-output bytes (VT-encoded, replayed as DATA)
//!
//! `cols`/`rows` (GRS2) record the CAPTURE WIDTH so the reattaching viewer can
//! replay the raw byte stream at the width it was drawn at and then reflow to the
//! live pane width — a raw stream full of in-place prompt redraws (`\r` + erase)
//! only lands cleanly at its original width; replayed narrower it smears (each
//! redraw wraps and the erase can't reclaim the row already pushed to
//! scrollback). A legacy **GRS1** file has no width; it loads with cols=rows=0
//! ("unknown") and the viewer falls back to live-width replay (today's behavior).
//!
//! `base_offset` is recorded for fidelity (it documents where in the raw stream
//! the snapshot sat), though the reboot loader renumbers the reloaded ring to
//! base 0 — a freshly-restored viewer applies DATA from offset 0 with no resync
//! watermark (connection.zig `prepareRelaunchPane`), so a non-zero base would
//! just manufacture a phantom gap.
//!
//! ## Append journal (`<rings_dir>/<session-id-hex>.ringlog`, T997)
//!
//! Rewriting the whole ring on every pass made the disk write proportional to
//! the RING, not to what arrived: a quiet pane that printed one prompt in 30
//! seconds rewrote its full 2 MB, and a busy one under the volume trigger wrote
//! `ring / threshold` (4x at the defaults, 32x at a 16 MB ring) of what it
//! printed. So the `.ring` file above is now the BASE, and the passes between
//! two rewrites of it append only their new bytes to a journal beside it:
//!
//!   magic       : 4 bytes  "GRJ1"
//!   base_end    : u64 LE   stream offset one past the base's last byte
//!   base_crc    : u32 LE   CRC-32 of the base's ring bytes
//!   records...  : start u64, len u32, cols u16, rows u16, crc u32, then `len`
//!                 bytes; `crc` covers the first 16 header bytes and the payload
//!
//! The header BINDS the journal to one exact base: a journal left beside some
//! other base (an older agent that knows nothing of journals rewrote the
//! `.ring` after a rollback; a crash between the base publish and the journal
//! reset) fails the check and is ignored, so it can never splice foreign bytes
//! onto a snapshot. The `.ring` layout itself is unchanged, which is what lets
//! an older agent still read it — it just misses the journal's tail.
//!
//! `load` replays records in order while each one is intact and continues the
//! stream: a record that starts before the current end has its already-covered
//! prefix dropped (a repeat is harmless), and the first torn, corrupt or gapped
//! record ends the replay — everything before it is still good. The writer
//! (`session.zig snapshotRings`) folds the journal back into a fresh base once it
//! holds about a ring's worth, so steady state writes at most twice what the
//! pane printed and the pair on disk never exceeds two rings.
//!
//! ## Layering / crash safety
//!
//! Depends only on `std` + `atomic_write` (like `session_meta`), so it
//! unit-tests standalone and `session.zig` imports it without a cycle.
//! `writeAtomic` delegates to `atomic_write.writeChunks` — safe under
//! concurrent writers to the same path (T183): a future agent start never
//! observes a torn snapshot.

const std = @import("std");
const Allocator = std.mem.Allocator;
const atomic_write = @import("atomic_write.zig");

/// Current magic (written by `writeAtomic`). GRS2 adds cols/rows after
/// base_offset. `load` also accepts the legacy `magic_v1` ("GRS1", no width);
/// any OTHER magic is treated as absent (best-effort).
pub const magic = "GRS2";
/// Legacy width-less snapshot magic; still loaded (cols=rows=0 → unknown).
pub const magic_v1 = "GRS1";

/// GRS2 header: magic(4) + base_offset(8) + cols(2) + rows(2) + byte_len(8).
pub const header_len: usize = magic.len + 8 + 2 + 2 + 8;
/// GRS1 header: magic(4) + base_offset(8) + byte_len(8).
pub const header_len_v1: usize = magic_v1.len + 8 + 8;

/// A hard ceiling on a snapshot file we will read back. The ring is capped at
/// `persistent-scrollback-bytes` (default 16 MB, §5.2); allow generous slack so
/// a legitimately large ring loads while a corrupt length is rejected.
pub const max_file_bytes: usize = 64 * 1024 * 1024;

/// A parsed snapshot. `bytes` is owned by `alloc`; free via `free`. `cols`/`rows`
/// are the capture geometry (0 = unknown, e.g. a legacy GRS1 file).
pub const Loaded = struct {
    base_offset: u64,
    cols: u16 = 0,
    rows: u16 = 0,
    bytes: []u8,

    pub fn free(self: Loaded, alloc: Allocator) void {
        alloc.free(self.bytes);
    }
};

/// Build the `<dir>/<id_str>.ring` path. Caller frees.
pub fn pathFor(alloc: Allocator, dir: []const u8, id_str: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}.ring", .{ dir, id_str });
}

/// Atomically write a ring snapshot (header + `bytes`) to `path`, creating
/// parent dirs as needed. A concurrent/subsequent reader sees only a complete
/// file, and concurrent writers to the same path are safe — see `atomic_write`
/// (T183). The header and the (potentially large) ring bytes go down as two
/// chunks rather than being concatenated into one buffer.
pub fn writeAtomic(
    alloc: Allocator,
    path: []const u8,
    base_offset: u64,
    cols: u16,
    rows: u16,
    bytes: []const u8,
) !void {
    var header: [header_len]u8 = undefined;
    @memcpy(header[0..magic.len], magic);
    std.mem.writeInt(u64, header[magic.len..][0..8], base_offset, .little);
    std.mem.writeInt(u16, header[magic.len + 8 ..][0..2], cols, .little);
    std.mem.writeInt(u16, header[magic.len + 10 ..][0..2], rows, .little);
    std.mem.writeInt(u64, header[magic.len + 12 ..][0..8], @intCast(bytes.len), .little);
    try atomic_write.writeChunks(alloc, path, &.{ &header, bytes }, .{});
}

/// Journal magic (T997). See the module doc for the layout.
pub const journal_magic = "GRJ1";
/// Journal header: magic(4) + base_end(8) + base_crc(4).
pub const journal_header_len: usize = journal_magic.len + 8 + 4;
/// Record header: start(8) + len(4) + cols(2) + rows(2) + crc(4).
pub const record_header_len: usize = 8 + 4 + 2 + 2 + 4;

/// The journal that extends the base at `base_path` (`<id>.ring` → `<id>.ringlog`).
/// Caller frees.
pub fn journalPathFor(alloc: Allocator, base_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}log", .{base_path});
}

/// The CRC-32 a journal header records for the base it extends.
pub fn baseCrc(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

/// Start an EMPTY journal bound to the base that was just published (whose ring
/// bytes end at stream offset `base_end` and hash to `base_crc`). Atomic, like
/// the base, so a crash leaves either the previous journal — which then fails
/// the binding check against the new base and is ignored — or this one. Returns
/// the journal's length, which is where the first record goes.
pub fn resetJournal(alloc: Allocator, journal_path: []const u8, base_end: u64, base_crc: u32) !u64 {
    var header: [journal_header_len]u8 = undefined;
    @memcpy(header[0..journal_magic.len], journal_magic);
    std.mem.writeInt(u64, header[journal_magic.len..][0..8], base_end, .little);
    std.mem.writeInt(u32, header[journal_magic.len + 8 ..][0..4], base_crc, .little);
    try atomic_write.writeChunks(alloc, journal_path, &.{&header}, .{});
    return journal_header_len;
}

/// Append one record — `bytes`, which begin at stream offset `start` and were
/// drawn at `cols`x`rows` — at file offset `at_len`, the journal length the
/// caller last saw, and cut the file there so a torn tail from a failed earlier
/// write can never sit between two good records. Synced before returning,
/// because the caller then tells the holder it may forget these bytes. Returns
/// the new length. The journal must already exist (`resetJournal`); a missing
/// one is `error.FileNotFound`, and the caller answers any error by rewriting
/// the base instead.
pub fn appendRecord(
    journal_path: []const u8,
    at_len: u64,
    start: u64,
    cols: u16,
    rows: u16,
    bytes: []const u8,
) !u64 {
    if (bytes.len > std.math.maxInt(u32)) return error.RecordTooLarge;
    var hdr: [record_header_len]u8 = undefined;
    std.mem.writeInt(u64, hdr[0..8], start, .little);
    std.mem.writeInt(u32, hdr[8..12], @intCast(bytes.len), .little);
    std.mem.writeInt(u16, hdr[12..14], cols, .little);
    std.mem.writeInt(u16, hdr[14..16], rows, .little);
    var crc = std.hash.Crc32.init();
    crc.update(hdr[0..16]);
    crc.update(bytes);
    std.mem.writeInt(u32, hdr[16..20], crc.final(), .little);

    var file = try std.fs.cwd().openFile(journal_path, .{ .mode = .read_write });
    defer file.close();
    try file.pwriteAll(&hdr, at_len);
    try file.pwriteAll(bytes, at_len + record_header_len);
    const new_len = at_len + record_header_len + bytes.len;
    try file.setEndPos(new_len);
    try file.sync();
    return new_len;
}

/// Load + parse the snapshot at `path`, extended by its journal (T997) when one
/// is present and bound to it. Returns null when the file is ABSENT (a
/// session with no snapshot yet — normal, non-error) or when it is corrupt /
/// mis-magic / mis-sized (best-effort: a bad snapshot must never stop a session
/// from relaunching — the pane just comes back without pre-restart scrollback).
/// Caller `free`s a non-null result.
pub fn load(alloc: Allocator, path: []const u8) !?Loaded {
    var base = (try loadBase(alloc, path)) orelse return null;
    errdefer base.free(alloc);
    const jpath = try journalPathFor(alloc, path);
    defer alloc.free(jpath);
    try extendFromJournal(alloc, jpath, &base);
    return base;
}

/// Replay the journal at `journal_path` onto `base` in place (T997). Best-effort
/// like the rest of the loader: an absent, unbound or damaged journal leaves the
/// base as it was, and a damaged record ends the replay at the last good one.
fn extendFromJournal(alloc: Allocator, journal_path: []const u8, base: *Loaded) !void {
    const raw = std.fs.cwd().readFileAlloc(alloc, journal_path, max_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return, // absent, unreadable or oversized: the base stands alone
    };
    defer alloc.free(raw);

    if (raw.len < journal_header_len) return;
    if (!std.mem.eql(u8, raw[0..journal_magic.len], journal_magic)) return;
    const bound_end = std.mem.readInt(u64, raw[journal_magic.len..][0..8], .little);
    const bound_crc = std.mem.readInt(u32, raw[journal_magic.len + 8 ..][0..4], .little);
    var end = base.base_offset +% base.bytes.len;
    if (bound_end != end or bound_crc != baseCrc(base.bytes)) return; // someone else's base

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var cols = base.cols;
    var rows = base.rows;
    var pos: usize = journal_header_len;
    while (raw.len - pos >= record_header_len) {
        const hdr = raw[pos..][0..record_header_len];
        const start = std.mem.readInt(u64, hdr[0..8], .little);
        const len: usize = std.mem.readInt(u32, hdr[8..12], .little);
        if (raw.len - pos - record_header_len < len) break; // torn tail
        const payload = raw[pos + record_header_len ..][0..len];
        var crc = std.hash.Crc32.init();
        crc.update(hdr[0..16]);
        crc.update(payload);
        if (crc.final() != std.mem.readInt(u32, hdr[16..20], .little)) break; // corrupt
        if (start > end) break; // a gap: the bytes in between are gone
        const covered = end - start;
        if (covered < len) {
            if (out.items.len == 0) try out.appendSlice(alloc, base.bytes);
            try out.appendSlice(alloc, payload[@intCast(covered)..]);
            end = start + len;
        }
        const rc = std.mem.readInt(u16, hdr[12..14], .little);
        const rr = std.mem.readInt(u16, hdr[14..16], .little);
        if (rc != 0) {
            cols = rc;
            rows = rr;
        }
        pos += record_header_len + len;
    }
    if (out.items.len == 0) return; // nothing new beyond the base
    const merged = try out.toOwnedSlice(alloc);
    alloc.free(base.bytes);
    base.bytes = merged;
    base.cols = cols;
    base.rows = rows;
}

/// The `.ring` file alone — the pre-T997 loader, unchanged.
fn loadBase(alloc: Allocator, path: []const u8) !?Loaded {
    const raw = std.fs.cwd().readFileAlloc(alloc, path, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(raw);

    if (raw.len < magic.len) return null; // too short to even hold a magic

    // GRS2: base_offset + cols + rows + byte_len.
    if (std.mem.eql(u8, raw[0..magic.len], magic)) {
        if (raw.len < header_len) return null; // truncated header → treat as absent
        const base_offset = std.mem.readInt(u64, raw[magic.len..][0..8], .little);
        const cols = std.mem.readInt(u16, raw[magic.len + 8 ..][0..2], .little);
        const rows = std.mem.readInt(u16, raw[magic.len + 10 ..][0..2], .little);
        const byte_len = std.mem.readInt(u64, raw[magic.len + 12 ..][0..8], .little);
        if (byte_len != raw.len - header_len) return null; // length mismatch → corrupt
        const bytes = try alloc.dupe(u8, raw[header_len..]);
        return .{ .base_offset = base_offset, .cols = cols, .rows = rows, .bytes = bytes };
    }

    // Legacy GRS1: base_offset + byte_len, no width (cols=rows=0 → unknown). A
    // new agent must still read a snapshot an OLDER agent wrote (upgrade skew).
    if (std.mem.eql(u8, raw[0..magic_v1.len], magic_v1)) {
        if (raw.len < header_len_v1) return null;
        const base_offset = std.mem.readInt(u64, raw[magic_v1.len..][0..8], .little);
        const byte_len = std.mem.readInt(u64, raw[magic_v1.len + 8 ..][0..8], .little);
        if (byte_len != raw.len - header_len_v1) return null;
        const bytes = try alloc.dupe(u8, raw[header_len_v1..]);
        return .{ .base_offset = base_offset, .bytes = bytes };
    }

    return null; // unknown magic → treat as absent
}

/// Best-effort delete of a session's snapshot file and its journal (on CLOSE /
/// reap). Missing files are not an error.
pub fn delete(alloc: Allocator, dir: []const u8, id_str: []const u8) void {
    const path = pathFor(alloc, dir, id_str) catch return;
    defer alloc.free(path);
    std.fs.cwd().deleteFile(path) catch {};
    const jpath = journalPathFor(alloc, path) catch return;
    defer alloc.free(jpath);
    std.fs.cwd().deleteFile(jpath) catch {};
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "writeAtomic + load round-trip; no .tmp leftover; missing loads null" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    // Nested "rings" subdir exercises makePath.
    const rings_dir = try std.fs.path.join(alloc, &.{ dir_path, "rings" });
    defer alloc.free(rings_dir);
    const id = "0123456789abcdef0123456789abcdef";
    const path = try pathFor(alloc, rings_dir, id);
    defer alloc.free(path);

    // Absent → null.
    try testing.expect((try load(alloc, path)) == null);

    const payload = "PANE=3 PID=42\r\ntick-3-0\r\ntick-3-1\r\n";
    try writeAtomic(alloc, path, 1000, 120, 40, payload);

    // No staging file of any name left behind — the dir holds exactly the ring.
    {
        var dir = try std.fs.cwd().openDir(rings_dir, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var count: usize = 0;
        while (try it.next()) |entry| {
            count += 1;
            try testing.expect(std.mem.endsWith(u8, entry.name, ".ring"));
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    var loaded = (try load(alloc, path)).?;
    defer loaded.free(alloc);
    try testing.expectEqual(@as(u64, 1000), loaded.base_offset);
    try testing.expectEqual(@as(u16, 120), loaded.cols);
    try testing.expectEqual(@as(u16, 40), loaded.rows);
    try testing.expectEqualStrings(payload, loaded.bytes);

    // Delete removes it (load → null again).
    delete(alloc, rings_dir, id);
    try testing.expect((try load(alloc, path)) == null);
}

test "empty ring round-trips (base only, zero bytes)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try pathFor(alloc, dir_path, "ffffffffffffffffffffffffffffffff");
    defer alloc.free(path);

    try writeAtomic(alloc, path, 0, 80, 24, "");
    var loaded = (try load(alloc, path)).?;
    defer loaded.free(alloc);
    try testing.expectEqual(@as(u64, 0), loaded.base_offset);
    try testing.expectEqual(@as(u16, 80), loaded.cols);
    try testing.expectEqual(@as(usize, 0), loaded.bytes.len);
}

test "legacy GRS1 (no width) still loads with cols=rows=0" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try pathFor(alloc, dir_path, "1111111111111111111111111111111f");
    defer alloc.free(path);

    // Hand-assemble a GRS1 file: magic + base_offset + byte_len + bytes.
    const payload = "old-agent-scrollback\r\n";
    var buf: [header_len_v1 + payload.len]u8 = undefined;
    @memcpy(buf[0..magic_v1.len], magic_v1);
    std.mem.writeInt(u64, buf[magic_v1.len..][0..8], 500, .little);
    std.mem.writeInt(u64, buf[magic_v1.len + 8 ..][0..8], payload.len, .little);
    @memcpy(buf[header_len_v1..], payload);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = &buf });

    var loaded = (try load(alloc, path)).?;
    defer loaded.free(alloc);
    try testing.expectEqual(@as(u64, 500), loaded.base_offset);
    try testing.expectEqual(@as(u16, 0), loaded.cols); // unknown
    try testing.expectEqual(@as(u16, 0), loaded.rows);
    try testing.expectEqualStrings(payload, loaded.bytes);
}

test "corrupt files load as null (wrong magic, short header, length mismatch)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    // Wrong magic.
    {
        const p = try pathFor(alloc, dir_path, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        defer alloc.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "XXXX\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" });
        try testing.expect((try load(alloc, p)) == null);
    }
    // Short header (< header_len).
    {
        const p = try pathFor(alloc, dir_path, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        defer alloc.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "GRS1" });
        try testing.expect((try load(alloc, p)) == null);
    }
    // Length mismatch: byte_len claims 99 but only a few bytes follow (GRS2).
    {
        const p = try pathFor(alloc, dir_path, "cccccccccccccccccccccccccccccccc");
        defer alloc.free(p);
        var buf: [header_len + 3]u8 = undefined;
        @memcpy(buf[0..magic.len], magic);
        std.mem.writeInt(u64, buf[magic.len..][0..8], 0, .little); // base_offset
        std.mem.writeInt(u16, buf[magic.len + 8 ..][0..2], 80, .little); // cols
        std.mem.writeInt(u16, buf[magic.len + 10 ..][0..2], 24, .little); // rows
        std.mem.writeInt(u64, buf[magic.len + 12 ..][0..8], 99, .little); // byte_len (lie)
        buf[header_len] = 'a';
        buf[header_len + 1] = 'b';
        buf[header_len + 2] = 'c';
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = &buf });
        try testing.expect((try load(alloc, p)) == null);
    }
}

// -----------------------------------------------------------------------------
// Journal (T997)
// -----------------------------------------------------------------------------

/// Test helper: a base + fresh journal under a tmp dir. Caller frees both paths.
fn testPair(alloc: Allocator, dir_path: []const u8, id: []const u8, base_offset: u64, bytes: []const u8) !struct { base: []u8, journal: []u8, len: u64 } {
    const base = try pathFor(alloc, dir_path, id);
    errdefer alloc.free(base);
    const journal = try journalPathFor(alloc, base);
    errdefer alloc.free(journal);
    try writeAtomic(alloc, base, base_offset, 80, 24, bytes);
    const len = try resetJournal(alloc, journal, base_offset + bytes.len, baseCrc(bytes));
    return .{ .base = base, .journal = journal, .len = len };
}

test "journal records extend the base on load, and the newest geometry wins (T997)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const p = try testPair(alloc, dir_path, "0000000000000000000000000000000a", 100, "base-");
    defer alloc.free(p.base);
    defer alloc.free(p.journal);

    // An empty journal changes nothing.
    {
        var l = (try load(alloc, p.base)).?;
        defer l.free(alloc);
        try testing.expectEqualStrings("base-", l.bytes);
        try testing.expectEqual(@as(u16, 80), l.cols);
    }

    var len = try appendRecord(p.journal, p.len, 105, 80, 24, "one-");
    len = try appendRecord(p.journal, len, 109, 132, 50, "two");
    try testing.expectEqual(p.len + 2 * record_header_len + 7, len);

    var l = (try load(alloc, p.base)).?;
    defer l.free(alloc);
    try testing.expectEqualStrings("base-one-two", l.bytes);
    try testing.expectEqual(@as(u64, 100), l.base_offset);
    try testing.expectEqual(@as(u16, 132), l.cols);
    try testing.expectEqual(@as(u16, 50), l.rows);

    // The base file itself was never rewritten by the appends.
    var b = (try loadBase(alloc, p.base)).?;
    defer b.free(alloc);
    try testing.expectEqualStrings("base-", b.bytes);

    // delete takes the journal with it.
    delete(alloc, dir_path, "0000000000000000000000000000000a");
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(p.journal, .{}));
}

test "a torn or corrupt record ends the replay at the last good one (T997)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const p = try testPair(alloc, dir_path, "0000000000000000000000000000000b", 0, "AB");
    defer alloc.free(p.base);
    defer alloc.free(p.journal);

    const l1 = try appendRecord(p.journal, p.len, 2, 80, 24, "CD");
    const l2 = try appendRecord(p.journal, l1, 4, 80, 24, "EFGH");

    // Torn: the second record's payload is cut short.
    {
        var f = try std.fs.cwd().openFile(p.journal, .{ .mode = .read_write });
        defer f.close();
        try f.setEndPos(l2 - 1);
    }
    {
        var l = (try load(alloc, p.base)).?;
        defer l.free(alloc);
        try testing.expectEqualStrings("ABCD", l.bytes);
    }

    // Corrupt: the full record is back but one payload byte is flipped.
    _ = try appendRecord(p.journal, l1, 4, 80, 24, "EFGH");
    {
        var f = try std.fs.cwd().openFile(p.journal, .{ .mode = .read_write });
        defer f.close();
        try f.pwriteAll("X", l1 + record_header_len);
    }
    {
        var l = (try load(alloc, p.base)).?;
        defer l.free(alloc);
        try testing.expectEqualStrings("ABCD", l.bytes);
    }

    // Appending at a tracked offset cuts whatever was past it, so a later good
    // record is never stranded behind a torn one.
    const l3 = try appendRecord(p.journal, l1, 4, 80, 24, "ef");
    {
        var l = (try load(alloc, p.base)).?;
        defer l.free(alloc);
        try testing.expectEqualStrings("ABCDef", l.bytes);
    }
    try testing.expectEqual(l1 + record_header_len + 2, l3);
}

test "overlapping records drop their covered prefix; a gap stops the replay (T997)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const p = try testPair(alloc, dir_path, "0000000000000000000000000000000c", 10, "abc");
    defer alloc.free(p.base);
    defer alloc.free(p.journal);

    var len = try appendRecord(p.journal, p.len, 13, 80, 24, "de"); // 13..15
    len = try appendRecord(p.journal, len, 12, 80, 24, "cdef"); // repeats c,d,e; adds f
    len = try appendRecord(p.journal, len, 14, 80, 24, "e"); // wholly covered
    len = try appendRecord(p.journal, len, 20, 80, 24, "zz"); // gap at 16..20
    len = try appendRecord(p.journal, len, 16, 80, 24, "g"); // after the gap: ignored

    var l = (try load(alloc, p.base)).?;
    defer l.free(alloc);
    try testing.expectEqualStrings("abcdef", l.bytes);
}

test "a journal bound to a different base is ignored (T997)" {
    // The rollback shape: an older agent, which knows nothing of journals,
    // rewrites the base; the journal beside it now describes bytes that are not
    // in front of it and must not be spliced on.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const p = try testPair(alloc, dir_path, "0000000000000000000000000000000d", 0, "xyz");
    defer alloc.free(p.base);
    defer alloc.free(p.journal);
    _ = try appendRecord(p.journal, p.len, 3, 80, 24, "TAIL");

    // Same length, different bytes: the end offset still matches, the CRC does not.
    try writeAtomic(alloc, p.base, 0, 80, 24, "XYZ");
    {
        var l = (try load(alloc, p.base)).?;
        defer l.free(alloc);
        try testing.expectEqualStrings("XYZ", l.bytes);
    }
    // Different end offset.
    try writeAtomic(alloc, p.base, 5, 80, 24, "xyz");
    {
        var l = (try load(alloc, p.base)).?;
        defer l.free(alloc);
        try testing.expectEqualStrings("xyz", l.bytes);
    }
    // A journal with a foreign magic is ignored too.
    try std.fs.cwd().writeFile(.{ .sub_path = p.journal, .data = "NOPE\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" });
    {
        var l = (try load(alloc, p.base)).?;
        defer l.free(alloc);
        try testing.expectEqualStrings("xyz", l.bytes);
    }
}

test "appending to a missing journal fails rather than creating one (T997)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const j = try std.fs.path.join(alloc, &.{ dir_path, "absent.ringlog" });
    defer alloc.free(j);
    try testing.expectError(error.FileNotFound, appendRecord(j, journal_header_len, 0, 80, 24, "x"));
}
