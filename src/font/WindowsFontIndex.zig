//! A process-wide index of the font files in the Windows Fonts folders,
//! for the `freetype_windows` discovery backend (T3011).
//!
//! Before this, every discovery query walked the system and per-user
//! Fonts folders and opened each `.ttf`/`.otf`/`.ttc` with FreeType until
//! one matched. A codepoint no installed font covers matched nothing, so it
//! opened every face on the box: about 45 ms per first-seen missing
//! codepoint, paid while the shared grid holds its exclusive lock, so every
//! pane on that grid stalled with it. Printing a few hundred distinct
//! uncovered codepoints cost seconds.
//!
//! The index opens each face once, records its family names and the exact
//! set of codepoints its unicode cmap maps (as sorted inclusive ranges), and
//! answers family and codepoint queries from memory. Discovery then opens
//! only the faces the index names, and re-checks each against the real face,
//! so the index can only make a query faster, never answer it differently.
//!
//! It is rebuilt when either folder's last-write time moves, which is what
//! installing or removing a font does (the folder gains or loses an entry).
//! That check is a directory stat per query, and queries only happen on a
//! grid cache miss. `prewarm` starts the first build on a background thread
//! when discovery is first created, so the first missing glyph does not pay
//! for it either.
const WindowsFontIndex = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const freetype = @import("freetype");
const font = @import("main.zig");
const Face = font.Face;
const Library = font.Library;

const log = std.log.scoped(.font_index);

/// One inclusive codepoint range a face's unicode cmap covers.
pub const Range = struct { lo: u32, hi: u32 };

/// One face (a file plus a face index into it) the index knows about.
pub const Entry = struct {
    path: [:0]const u8,
    face_index: i32,
    /// FreeType's family_name, or "" when the face has none.
    family: []const u8,
    /// The SFNT name table's font family entry, or "" when absent.
    sfnt_family: []const u8,
    /// Sorted, non-overlapping, non-adjacent inclusive ranges.
    ranges: []const Range,

    pub fn covers(self: *const Entry, cp: u32) bool {
        return rangesContain(self.ranges, cp);
    }

    pub fn familyMatches(self: *const Entry, family: []const u8) bool {
        return (self.family.len > 0 and std.ascii.eqlIgnoreCase(self.family, family)) or
            (self.sfnt_family.len > 0 and std.ascii.eqlIgnoreCase(self.sfnt_family, family));
    }
};

/// A face discovery should open: the caller owns `path`.
pub const Candidate = struct {
    path: [:0]const u8,
    face_index: i32,

    pub fn deinit(self: Candidate, alloc: Allocator) void {
        alloc.free(self.path);
    }
};

/// The last-write time of every indexed folder, in folder order; 0 for a
/// folder that does not exist (so creating it later reads as a change).
const Stamp = struct {
    mtimes: [max_dirs]i128 = @splat(0),

    fn eql(a: Stamp, b: Stamp) bool {
        return std.mem.eql(i128, &a.mtimes, &b.mtimes);
    }
};

const max_dirs = 4;

const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    stamp: Stamp,

    fn destroy(self: *Snapshot) void {
        var arena = self.arena;
        arena.deinit();
    }
};

/// The folders to index, in the order discovery has always walked them.
dirs: []const []const u8,
/// Backs snapshots and their contents. Must be thread-safe: a prewarm
/// thread builds with it.
alloc: Allocator,
mutex: std.Thread.Mutex = .{},
snapshot: ?*Snapshot = null,
/// How many times a snapshot has been built (tests read this).
builds: u32 = 0,

pub fn init(alloc: Allocator, dirs: []const []const u8) WindowsFontIndex {
    std.debug.assert(dirs.len <= max_dirs);
    return .{ .alloc = alloc, .dirs = dirs };
}

pub fn deinit(self: *WindowsFontIndex) void {
    if (self.snapshot) |s| {
        s.destroy();
        self.alloc.destroy(s);
    }
    self.* = undefined;
}

/// The faces matching `family` (when non-null) whose cmap maps `codepoint`
/// (when non-zero), in folder-walk order. The caller owns the slice and
/// each candidate's path.
pub fn candidates(
    self: *WindowsFontIndex,
    alloc: Allocator,
    family: ?[]const u8,
    codepoint: u32,
) Allocator.Error![]Candidate {
    self.mutex.lock();
    defer self.mutex.unlock();
    const snap = try self.currentLocked();

    var list: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (list.items) |c| c.deinit(alloc);
        list.deinit(alloc);
    }
    for (snap.entries) |*e| {
        if (family) |f| if (!e.familyMatches(f)) continue;
        if (codepoint != 0 and !e.covers(codepoint)) continue;
        const path = try alloc.dupeZ(u8, e.path);
        errdefer alloc.free(path);
        try list.append(alloc, .{ .path = path, .face_index = e.face_index });
    }
    return try list.toOwnedSlice(alloc);
}

/// Build the index now if it is missing or stale. Used by `prewarm`.
pub fn refresh(self: *WindowsFontIndex) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    _ = self.currentLocked() catch |err| {
        log.warn("font index build failed err={}", .{err});
    };
}

fn currentLocked(self: *WindowsFontIndex) Allocator.Error!*Snapshot {
    const stamp = self.readStamp();
    if (self.snapshot) |s| {
        if (s.stamp.eql(stamp)) return s;
    }

    const fresh = try self.build(stamp);
    if (self.snapshot) |old| {
        old.destroy();
        self.alloc.destroy(old);
    }
    self.snapshot = fresh;
    self.builds += 1;
    return fresh;
}

fn readStamp(self: *const WindowsFontIndex) Stamp {
    var stamp: Stamp = .{};
    for (self.dirs, 0..) |path, i| {
        var dir = std.fs.openDirAbsolute(path, .{}) catch continue;
        defer dir.close();
        const st = dir.stat() catch continue;
        stamp.mtimes[i] = st.mtime;
    }
    return stamp;
}

fn build(self: *WindowsFontIndex, stamp: Stamp) Allocator.Error!*Snapshot {
    var timer = std.time.Timer.start() catch null;

    const snap = try self.alloc.create(Snapshot);
    errdefer self.alloc.destroy(snap);
    snap.* = .{
        .arena = .init(self.alloc),
        .entries = &.{},
        .stamp = stamp,
    };
    errdefer snap.arena.deinit();
    const arena = snap.arena.allocator();

    // A private FreeType library: this may run on the prewarm thread while
    // the grid's own library is in use.
    var lib = Library.init(self.alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("font index: freetype init failed err={}", .{err});
            return snap;
        },
    };
    defer lib.deinit();

    var entries: std.ArrayList(Entry) = .empty;
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(self.alloc);

    for (self.dirs) |dir_path| {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!isFontFile(entry.name)) continue;

            const path = try std.fmt.allocPrintSentinel(
                arena,
                "{s}\\{s}",
                .{ dir_path, entry.name },
                0,
            );
            const max_faces: i32 = if (std.ascii.endsWithIgnoreCase(entry.name, ".ttc")) 16 else 1;

            // Same probe discovery always made: stop at the first face
            // that will not open (past the end of a collection, or a face
            // with no unicode cmap).
            var face_index: i32 = 0;
            while (face_index < max_faces) : (face_index += 1) {
                var face = Face.initFile(lib, path, face_index, .{
                    .size = .{ .points = 12 },
                }) catch break;
                defer face.deinit();

                ranges.clearRetainingCapacity();
                try collectRanges(self.alloc, face.face.handle, &ranges);

                var name_buf: [256]u8 = undefined;
                const sfnt = face.name(&name_buf) catch "";
                const ft_family: []const u8 = if (face.face.handle.*.family_name) |f|
                    std.mem.span(@as([*:0]const u8, f))
                else
                    "";

                try entries.append(arena, .{
                    .path = path,
                    .face_index = face_index,
                    .family = try arena.dupe(u8, ft_family),
                    .sfnt_family = try arena.dupe(u8, sfnt),
                    .ranges = try arena.dupe(Range, ranges.items),
                });
            }
        }
    }

    snap.entries = entries.items;
    if (timer) |*t| log.info("font index built faces={} ms={}", .{
        entries.items.len,
        t.read() / std.time.ns_per_ms,
    });
    return snap;
}

/// Walk the face's selected (unicode) charmap in ascending order, folding
/// consecutive codepoints into ranges. This is the same table
/// `Face.glyphIndex` reads, so `covers` agrees with it exactly.
fn collectRanges(
    alloc: Allocator,
    handle: freetype.c.FT_Face,
    out: *std.ArrayList(Range),
) Allocator.Error!void {
    var gindex: freetype.c.FT_UInt = 0;
    var cp = freetype.c.FT_Get_First_Char(handle, &gindex);
    while (gindex != 0) {
        try appendCodepoint(alloc, out, @intCast(cp));
        cp = freetype.c.FT_Get_Next_Char(handle, cp, &gindex);
    }
}

/// Add `cp` to a sorted range list, extending the last range when it is
/// adjacent. Codepoints must arrive in ascending order.
fn appendCodepoint(alloc: Allocator, out: *std.ArrayList(Range), cp: u32) Allocator.Error!void {
    if (out.items.len > 0) {
        const last = &out.items[out.items.len - 1];
        if (cp <= last.hi) return; // duplicate (a broken cmap); already covered
        if (cp == last.hi + 1) {
            last.hi = cp;
            return;
        }
    }
    try out.append(alloc, .{ .lo = cp, .hi = cp });
}

fn rangesContain(ranges: []const Range, cp: u32) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

pub fn isFontFile(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".ttf") or
        std.ascii.endsWithIgnoreCase(name, ".ttc") or
        std.ascii.endsWithIgnoreCase(name, ".otf");
}

// ---------------------------------------------------------------------------
// The process-wide index over the real Windows Fonts folders.

var global_once = std.once(globalInit);
var global: ?WindowsFontIndex = null;
var global_dirs: [2][]const u8 = undefined;
var prewarm_started = std.atomic.Value(bool).init(false);

fn globalInit() void {
    const alloc = std.heap.smp_allocator;
    var n: usize = 0;
    if (std.process.getEnvVarOwned(alloc, "SYSTEMROOT")) |root| {
        defer alloc.free(root);
        if (std.fmt.allocPrint(alloc, "{s}\\Fonts", .{root})) |p| {
            global_dirs[n] = p;
            n += 1;
        } else |_| {}
    } else |_| {}
    if (std.process.getEnvVarOwned(alloc, "LOCALAPPDATA")) |local| {
        defer alloc.free(local);
        if (std.fmt.allocPrint(alloc, "{s}\\Microsoft\\Windows\\Fonts", .{local})) |p| {
            global_dirs[n] = p;
            n += 1;
        } else |_| {}
    } else |_| {}
    global = .init(alloc, global_dirs[0..n]);
}

/// The index over the system and per-user Fonts folders. Lives for the
/// process.
pub fn shared() *WindowsFontIndex {
    global_once.call();
    return &global.?;
}

/// Start building the shared index on a background thread, once per
/// process. Queries made before it finishes wait for it rather than
/// building a second copy.
pub fn prewarm() void {
    if (prewarm_started.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, prewarmMain, .{}) catch |err| {
        log.warn("font index prewarm thread failed err={}", .{err});
        return;
    };
    thread.setName("font-index") catch {};
    thread.detach();
}

fn prewarmMain() void {
    shared().refresh();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "ranges fold ascending codepoints and answer membership" {
    const alloc = testing.allocator;
    var list: std.ArrayList(Range) = .empty;
    defer list.deinit(alloc);
    for ([_]u32{ 0x20, 0x21, 0x22, 0x22, 0x41, 0x4E00, 0x4E01 }) |cp|
        try appendCodepoint(alloc, &list, cp);

    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqual(Range{ .lo = 0x20, .hi = 0x22 }, list.items[0]);
    try testing.expectEqual(Range{ .lo = 0x41, .hi = 0x41 }, list.items[1]);
    try testing.expectEqual(Range{ .lo = 0x4E00, .hi = 0x4E01 }, list.items[2]);

    for ([_]u32{ 0x20, 0x21, 0x22, 0x41, 0x4E00, 0x4E01 }) |cp|
        try testing.expect(rangesContain(list.items, cp));
    for ([_]u32{ 0, 0x1F, 0x23, 0x40, 0x42, 0x4DFF, 0x4E02, 0x10FFFD }) |cp|
        try testing.expect(!rangesContain(list.items, cp));
    try testing.expect(!rangesContain(&.{}, 0x41));
}

fn writeFont(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    var f = try dir.createFile(name, .{});
    defer f.close();
    try f.writeAll(bytes);
}

test "index answers family and codepoint queries and sees a newly installed font" {
    if (font.options.backend != .freetype_windows) return error.SkipZigTest;
    const embedded = @import("embedded.zig");
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    try writeFont(tmp.dir, "mono.ttf", embedded.regular);
    try writeFont(tmp.dir, "notes.txt", "not a font");

    const dirs = [_][]const u8{dir_path};
    var index: WindowsFontIndex = .init(alloc, &dirs);
    defer index.deinit();

    {
        const got = try index.candidates(alloc, "JetBrains Mono", 0);
        defer {
            for (got) |c| c.deinit(alloc);
            alloc.free(got);
        }
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expect(std.mem.endsWith(u8, got[0].path, "mono.ttf"));
        try testing.expectEqual(@as(i32, 0), got[0].face_index);
    }
    {
        // A codepoint the font maps, and one no font maps.
        const hit = try index.candidates(alloc, null, 'A');
        defer {
            for (hit) |c| c.deinit(alloc);
            alloc.free(hit);
        }
        try testing.expectEqual(@as(usize, 1), hit.len);
        const miss = try index.candidates(alloc, null, 0x10FFFD);
        defer alloc.free(miss);
        try testing.expectEqual(@as(usize, 0), miss.len);
        const wrong_family = try index.candidates(alloc, "No Such Family", 'A');
        defer alloc.free(wrong_family);
        try testing.expectEqual(@as(usize, 0), wrong_family.len);
    }
    // Queries against an unchanged folder reuse the one build.
    try testing.expectEqual(@as(u32, 1), index.builds);

    // U+F120 (Font Awesome's terminal icon) is in the nerd symbols font
    // and not in JetBrains Mono (which does carry the powerline arrows, so
    // those would not prove anything). Pin that before relying on it.
    const nerd_only: u32 = 0xF120;
    {
        const none_yet = try index.candidates(alloc, null, nerd_only);
        defer alloc.free(none_yet);
        try testing.expectEqual(@as(usize, 0), none_yet.len);
    }

    // Installing a font changes the folder, and the next query sees it.
    // NTFS stamps the folder at 100ns resolution, but a coarser filesystem
    // could land both writes in one tick; wait it out rather than flake.
    const before = index.readStamp();
    var tries: usize = 0;
    while (true) : (tries += 1) {
        try writeFont(tmp.dir, if (tries == 0) "symbols.ttf" else "symbols2.ttf", embedded.symbols_nerd_font);
        if (!index.readStamp().eql(before) or tries > 20) break;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    {
        const got = try index.candidates(alloc, null, nerd_only);
        defer {
            for (got) |c| c.deinit(alloc);
            alloc.free(got);
        }
        try testing.expect(got.len >= 1);
        try testing.expect(std.mem.indexOf(u8, got[0].path, "symbols") != null);
    }
    try testing.expectEqual(@as(u32, 2), index.builds);
}

test "index agrees with opening every face, on the real Fonts folders" {
    if (font.options.backend != .freetype_windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    const index = shared();

    var lib = try Library.init(alloc);
    defer lib.deinit();

    // For each probe codepoint, every candidate the index names must really
    // map it (no false positives); exactness in the other direction is
    // `collectRanges` reading the same cmap `glyphIndex` does.
    for ([_]u32{ 'A', 0x4E00, 0x0E01, 0x2603, 0x10FFFD }) |cp| {
        const got = try index.candidates(alloc, null, cp);
        defer {
            for (got) |c| c.deinit(alloc);
            alloc.free(got);
        }
        if (cp == 'A') try testing.expect(got.len > 0);
        if (cp == 0x10FFFD) try testing.expectEqual(@as(usize, 0), got.len);
        for (got[0..@min(got.len, 8)]) |c| {
            var face = try Face.initFile(lib, c.path, c.face_index, .{ .size = .{ .points = 12 } });
            defer face.deinit();
            try testing.expect(face.glyphIndex(cp) != null);
        }
    }
}
