//! The image pane's scratch folders (T3241): where a large picture is staged
//! for the browser process to read from disk, one folder per pane under
//! `%TEMP%\ghoztty-viewer-images`.
//!
//! **Ownership is a lock, not a timestamp.** A pane that closes removes its
//! own folder, but a killed or crashed app does not, and each staged picture
//! is tens of megabytes. So every folder holds an `.owner` file its pane keeps
//! open WITHOUT `FILE_SHARE_DELETE`: while that process lives, deleting the
//! file fails with a sharing violation, and the moment it dies the kernel
//! closes the handle. The sweep a new folder runs therefore needs no clock and
//! no process list - it deletes `.owner` first, and only a folder whose owner
//! could be deleted is abandoned and removed. A live pane of ANY Ghoztty
//! process on the box, this build or another, is never touched.

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");

const log = std.log.scoped(.viewer);

/// The parent of every pane's folder, under `%TEMP%`.
pub const parent_name = "ghoztty-viewer-images";
const owner_name = ".owner";

/// A pane's claimed folder: the path and the open owner lock.
pub const Claim = struct {
    /// Owned.
    dir: []u8,
    owner: w32.HANDLE,

    /// Close the lock and remove the folder with everything in it.
    pub fn release(self: *Claim, alloc: Allocator) void {
        _ = w32.CloseHandle(self.owner);
        std.fs.cwd().deleteTree(self.dir) catch |err| {
            log.warn("viewer image scratch not removed: {s}: {s}", .{ self.dir, @errorName(err) });
        };
        alloc.free(self.dir);
        self.* = undefined;
    }
};

/// Make `<parent>\<name>` and lock it as this process's. Null when either
/// fails; the caller then serves every picture through the request.
pub fn claim(alloc: Allocator, parent: []const u8, name: []const u8) ?Claim {
    const dir = std.fs.path.join(alloc, &.{ parent, name }) catch return null;
    std.fs.cwd().makePath(dir) catch |err| {
        log.warn("viewer image scratch cannot be made: {s}: {s}", .{ dir, @errorName(err) });
        alloc.free(dir);
        return null;
    };
    const owner = lockOwner(alloc, dir) orelse {
        std.fs.cwd().deleteTree(dir) catch {};
        alloc.free(dir);
        return null;
    };
    return .{ .dir = dir, .owner = owner };
}

fn lockOwner(alloc: Allocator, dir: []const u8) ?w32.HANDLE {
    const path = std.fs.path.join(alloc, &.{ dir, owner_name }) catch return null;
    defer alloc.free(path);
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(alloc, path) catch return null;
    defer alloc.free(wide);
    // Readable and writable by anyone, deletable by no one while it is open.
    const h = w32.CreateFileW(
        wide,
        w32.FILE_APPEND_DATA | w32.SYNCHRONIZE,
        w32.FILE_SHARE_READ | w32.FILE_SHARE_WRITE,
        null,
        w32.OPEN_ALWAYS,
        w32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == w32.INVALID_HANDLE_VALUE) {
        log.warn("viewer image scratch owner cannot be locked: {s}", .{path});
        return null;
    }
    return h;
}

/// Remove every folder under `parent` but `keep` whose owner is gone. Returns
/// how many were removed. A folder with no `.owner` at all is left alone: it
/// is either one being claimed this instant by another pane, or not ours.
pub fn sweep(alloc: Allocator, parent: []const u8, keep: []const u8) usize {
    var dir = std.fs.cwd().openDir(parent, .{ .iterate = true }) catch return 0;
    defer dir.close();
    // Collected first: deleting while iterating a directory skips entries.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.ascii.eqlIgnoreCase(entry.name, keep)) continue;
        const n = alloc.dupe(u8, entry.name) catch continue;
        names.append(alloc, n) catch {
            alloc.free(n);
            continue;
        };
    }
    var removed: usize = 0;
    for (names.items) |name| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const owner = std.fmt.bufPrint(&buf, "{s}\\{s}", .{ name, owner_name }) catch continue;
        // The lock IS the question: a live owner's handle refuses the delete.
        dir.deleteFile(owner) catch continue;
        dir.deleteTree(name) catch |err| {
            log.warn("viewer image scratch: abandoned {s} not removed: {s}", .{ name, @errorName(err) });
            continue;
        };
        removed += 1;
    }
    if (removed > 0) log.info("viewer image scratch: removed {d} abandoned folder(s)", .{removed});
    return removed;
}

/// `%TEMP%\ghoztty-viewer-images`. Caller owns it.
pub fn defaultParent(alloc: Allocator) ?[]u8 {
    const tmp = std.process.getEnvVarOwned(alloc, "TEMP") catch return null;
    defer alloc.free(tmp);
    return std.fs.path.join(alloc, &.{ tmp, parent_name }) catch null;
}

const testing = std.testing;

fn tmpParent(tmp: *std.testing.TmpDir, alloc: Allocator) ![]u8 {
    return tmp.dir.realpathAlloc(alloc, ".");
}

test "claim makes the folder and release removes it with its pictures (T3241)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try tmpParent(&tmp, alloc);
    defer alloc.free(parent);

    var c = claim(alloc, parent, "PANE-A") orelse return error.TestUnexpectedResult;
    try tmp.dir.writeFile(.{ .sub_path = "PANE-A\\1.bmp", .data = "pixels" });
    try tmp.dir.access("PANE-A\\.owner", .{});
    c.release(alloc);
    try testing.expectError(error.FileNotFound, tmp.dir.access("PANE-A", .{}));
}

test "sweep removes a folder whose owner is gone and never a live one (T3241)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try tmpParent(&tmp, alloc);
    defer alloc.free(parent);

    // Live: claimed, lock held - a pane of some running process.
    var live = claim(alloc, parent, "LIVE") orelse return error.TestUnexpectedResult;
    defer live.release(alloc);
    try tmp.dir.writeFile(.{ .sub_path = "LIVE\\3.png", .data = "picture" });
    // Ours: the sweeping pane's own folder, also held.
    var mine = claim(alloc, parent, "MINE") orelse return error.TestUnexpectedResult;
    defer mine.release(alloc);
    // Dead: claimed and its handle closed without a release - exactly what a
    // killed process leaves behind once the kernel closes its handles.
    {
        const dead = claim(alloc, parent, "DEAD") orelse return error.TestUnexpectedResult;
        _ = w32.CloseHandle(dead.owner);
        alloc.free(dead.dir);
    }
    try tmp.dir.writeFile(.{ .sub_path = "DEAD\\7.bmp", .data = "stale pixels" });
    // Unowned: no `.owner` at all. Not provably abandoned, so kept.
    try tmp.dir.makePath("STRANGER");
    try tmp.dir.writeFile(.{ .sub_path = "STRANGER\\x.txt", .data = "?" });

    try testing.expectEqual(@as(usize, 1), sweep(alloc, parent, "MINE"));
    try testing.expectError(error.FileNotFound, tmp.dir.access("DEAD", .{}));
    try tmp.dir.access("LIVE\\3.png", .{});
    try tmp.dir.access("LIVE\\.owner", .{});
    try tmp.dir.access("MINE\\.owner", .{});
    try tmp.dir.access("STRANGER\\x.txt", .{});
    // A second sweep finds nothing more to do.
    try testing.expectEqual(@as(usize, 0), sweep(alloc, parent, "MINE"));
}

test "sweep of a parent that does not exist removes nothing (T3241)" {
    try testing.expectEqual(@as(usize, 0), sweep(testing.allocator, "C:\\ghoztty-no-such-scratch-parent-t3241", "X"));
}
