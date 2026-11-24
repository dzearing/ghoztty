//! `ghoztty.com`, the console twin of `ghoztty.exe`, made ON THE BOX (T2071).
//!
//! The twin is the same image with one WORD changed: the PE optional header's
//! Subsystem field says console (3) instead of GUI (2). That one word is what
//! makes PowerShell and cmd wait for a CLI verb and wire its redirection
//! (T245, `src/cli/com_shim.zig`), and PATHEXT prefers `.COM` over `.EXE`, so
//! it is what a bare `ghoztty` on the PATH actually runs (T1052).
//!
//! Until T2071 the MSI carried the twin as a second full copy: ~20 MB of the
//! download for one word, because no cabinet compressor has a window anywhere
//! near 35 MB to notice the two files are identical. The installer now carries
//! `ghoztty.exe` once, and its custom-action DLL (`install_ca.zig`) calls
//! `derive` after InstallFiles and `remove` before RemoveFiles. The build-time
//! host tool (`src/build/patch_subsystem_main.zig`) makes the zig-out copy with
//! the SAME `makeConsoleTwin`, so the two can never disagree about the edit.
//!
//! Two halves, deliberately in one file:
//!
//!   * The PE edit is pure and runs anywhere - the build host is Linux in CI.
//!   * `derive` / `remove` are Win32 file operations, referenced only from the
//!     DLL and the Windows tests, so they are never analysed for another OS.
//!
//! Imports nothing but `std`: the DLL must stay tiny and dependency-free.
//!
//! ## Why the signature is stripped
//!
//! Authenticode hashes the Subsystem field. Flipping it in a SIGNED exe leaves
//! a certificate on the twin that no longer matches its bytes, and a file with
//! a broken signature reads worse to SmartScreen and Defender than a file with
//! none. Releases are unsigned today (T1203 has no certificate yet), so this is
//! a no-op now; it keeps the day a certificate lands from quietly shipping a
//! twin that looks tampered with. A signed twin needs the twin signed at build
//! time, which is exactly the duplicate this file exists to remove - that
//! trade is T2071's follow-up to make when signing is real.

const std = @import("std");

pub const source_name = "ghoztty.exe";
pub const twin_name = "ghoztty.com";
/// Written first, then moved over the twin, so a failure mid-write never
/// leaves a truncated `ghoztty.com` where the PATH will find it.
pub const new_name = "ghoztty.com.new";
/// Where an in-use twin is renamed to when it cannot be replaced in place.
/// A running image can be renamed but not overwritten or deleted.
pub const aside_name = "ghoztty.com.old";

pub const subsystem_gui: u16 = 2;
pub const subsystem_console: u16 = 3;

pub const PeError = error{
    NotAPeFile,
    TruncatedPeFile,
    UnknownOptionalHeader,
    UnexpectedSubsystem,
};

const Layout = struct {
    /// File offset of the optional header's Subsystem WORD.
    subsystem: usize,
    /// File offset of the Security (certificate table) data directory entry,
    /// or null when the header has no room for one.
    security_dir: ?usize,
};

/// Offset 68 of the optional header holds Subsystem in BOTH PE32 and PE32+
/// (their layouts diverge only after it - the invariant editbin /SUBSYSTEM
/// relies on). The data directories start at 96 (PE32) or 112 (PE32+), and
/// the Security directory is entry 4 of them.
fn layout(bytes: []const u8) PeError!Layout {
    if (bytes.len < 0x40 or bytes[0] != 'M' or bytes[1] != 'Z') return error.NotAPeFile;
    const pe: usize = std.mem.readInt(u32, bytes[0x3C..][0..4], .little);
    // PE signature (4) + COFF header (20) + the optional header through the
    // Subsystem field (70).
    if (pe > bytes.len or bytes.len - pe < 4 + 20 + 70) return error.TruncatedPeFile;
    if (!std.mem.eql(u8, bytes[pe..][0..4], "PE\x00\x00")) return error.NotAPeFile;
    const opt_size: usize = std.mem.readInt(u16, bytes[pe + 4 + 16 ..][0..2], .little);
    const opt = pe + 4 + 20;
    const dirs: usize = switch (std.mem.readInt(u16, bytes[opt..][0..2], .little)) {
        0x10b => 96,
        0x20b => 112,
        else => return error.UnknownOptionalHeader,
    };
    var security: ?usize = null;
    const entry = dirs + 4 * 8;
    if (opt_size >= entry + 8 and bytes.len >= opt + entry + 8) {
        const count = std.mem.readInt(u32, bytes[opt + dirs - 4 ..][0..4], .little);
        if (count > 4) security = opt + entry;
    }
    return .{ .subsystem = opt + 68, .security_dir = security };
}

/// The image's Subsystem value.
pub fn subsystem(bytes: []const u8) PeError!u16 {
    const l = try layout(bytes);
    return std.mem.readInt(u16, bytes[l.subsystem..][0..2], .little);
}

/// Set Subsystem to `value`. Refuses an image whose current value is not GUI
/// or console: offset 68 holding anything else means this is not the file we
/// think it is, and writing into it would corrupt it.
pub fn setSubsystem(bytes: []u8, value: u16) PeError!void {
    const l = try layout(bytes);
    const old = std.mem.readInt(u16, bytes[l.subsystem..][0..2], .little);
    if (old != subsystem_gui and old != subsystem_console) return error.UnexpectedSubsystem;
    std.mem.writeInt(u16, bytes[l.subsystem..][0..2], value, .little);
}

/// Remove the Authenticode certificate table. Returns the image's new length:
/// shorter when the table was the tail of the file (where signing tools put
/// it, padded to 8 bytes), unchanged otherwise. Either way the directory entry
/// is zeroed, so nothing reads the image as signed.
pub fn stripSignature(bytes: []u8) PeError!usize {
    const l = try layout(bytes);
    const at = l.security_dir orelse return bytes.len;
    const offset: usize = std.mem.readInt(u32, bytes[at..][0..4], .little);
    const size: usize = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
    if (offset == 0 and size == 0) return bytes.len;
    @memset(bytes[at..][0..8], 0);
    if (offset == 0 or offset > bytes.len or size > bytes.len - offset) return bytes.len;
    // Only ever cut a tail: anything after the table but its alignment padding
    // is data we do not understand, and is left exactly where it was.
    if (bytes.len - (offset + size) >= 8) return bytes.len;
    return offset;
}

/// The whole edit: console subsystem, no certificate. Returns the length of
/// the twin (a prefix of `bytes`).
pub fn makeConsoleTwin(bytes: []u8) PeError!usize {
    try setSubsystem(bytes, subsystem_console);
    return stripSignature(bytes);
}

// ---------------------------------------------------------------------
// Win32 half: the files on disk.
// ---------------------------------------------------------------------

const W = std.os.windows;
const HANDLE = W.HANDLE;
const DWORD = W.DWORD;
const BOOL = W.BOOL;

const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const FILE_SHARE_READ: DWORD = 0x1;
const FILE_SHARE_DELETE: DWORD = 0x4;
const OPEN_EXISTING: DWORD = 3;
const CREATE_ALWAYS: DWORD = 2;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
const MOVEFILE_REPLACE_EXISTING: DWORD = 0x1;
const MOVEFILE_WRITE_THROUGH: DWORD = 0x8;
const ERROR_FILE_NOT_FOUND: DWORD = 2;
const ERROR_PATH_NOT_FOUND: DWORD = 3;
const invalid_handle: HANDLE = @ptrFromInt(std.math.maxInt(usize));

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nToRead: DWORD, lpRead: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nToWrite: DWORD, lpWritten: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: ?[*:0]const u16, flags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteFileW(path: [*:0]const u16) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

/// What `derive` did. Every value is something msiexec's log should say in
/// words, so the DLL maps each to a sentence.
pub const Derived = enum {
    /// The twin was written (or replaced in place).
    derived,
    /// The old twin was in use, so it was renamed to `aside_name` and the new
    /// one written in its place. The aside copy is removed with the product.
    derived_aside,
    /// No `ghoztty.exe` in the directory - nothing to derive from.
    missing_source,
    /// `ghoztty.exe` is there but could not be read.
    read_failed,
    /// `ghoztty.exe` is not a GUI/console PE image.
    not_a_pe,
    /// The new twin could not be written.
    write_failed,
    /// It was written, but could not be put in place of the old one.
    replace_failed,
};

/// Room for INSTALLDIR plus the longest name above.
pub const path_capacity = W.PATH_MAX_WIDE + 32;

/// `dir` + `name` as a NUL-terminated wide path in `buf`, adding the
/// separator only when `dir` does not already end in one (MSI directory
/// properties do). Null when it does not fit.
pub fn joinPath(buf: []u16, dir: []const u16, comptime name: []const u8) ?[:0]u16 {
    const wide = comptime std.unicode.utf8ToUtf16LeStringLiteral(name);
    var n = dir.len;
    const sep = n == 0 or (dir[n - 1] != '\\' and dir[n - 1] != '/');
    const total = n + @intFromBool(sep) + wide.len;
    if (total + 1 > buf.len) return null;
    @memcpy(buf[0..n], dir);
    if (sep) {
        buf[n] = '\\';
        n += 1;
    }
    @memcpy(buf[n..][0..wide.len], wide);
    buf[total] = 0;
    return buf[0..total :0];
}

const ReadError = error{ Missing, Failed, OutOfMemory };

fn readAll(alloc: std.mem.Allocator, path: [*:0]const u16) ReadError![]u8 {
    const h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == invalid_handle) {
        const err = GetLastError();
        return if (err == ERROR_FILE_NOT_FOUND or err == ERROR_PATH_NOT_FOUND) error.Missing else error.Failed;
    }
    defer _ = CloseHandle(h);
    var size: i64 = 0;
    if (GetFileSizeEx(h, &size) == 0 or size < 0 or size > 512 * 1024 * 1024) return error.Failed;
    const bytes = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(bytes);
    var done: usize = 0;
    while (done < bytes.len) {
        const want: DWORD = @intCast(@min(bytes.len - done, 1 << 30));
        var got: DWORD = 0;
        if (ReadFile(h, bytes[done..].ptr, want, &got, null) == 0 or got == 0) return error.Failed;
        done += got;
    }
    return bytes;
}

fn writeAll(path: [*:0]const u16, bytes: []const u8) bool {
    const h = CreateFileW(path, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == invalid_handle) return false;
    defer _ = CloseHandle(h);
    var done: usize = 0;
    while (done < bytes.len) {
        const want: DWORD = @intCast(@min(bytes.len - done, 1 << 30));
        var wrote: DWORD = 0;
        if (WriteFile(h, bytes[done..].ptr, want, &wrote, null) == 0 or wrote == 0) return false;
        done += wrote;
    }
    return true;
}

/// Make `<dir>\ghoztty.com` from `<dir>\ghoztty.exe`, replacing any twin
/// already there - a stale one from an older install, or a current one on
/// repair. Never leaves a half-written `ghoztty.com` behind.
pub fn derive(alloc: std.mem.Allocator, dir: []const u16) Derived {
    var src_buf: [path_capacity]u16 = undefined;
    var twin_buf: [path_capacity]u16 = undefined;
    var new_buf: [path_capacity]u16 = undefined;
    var aside_buf: [path_capacity]u16 = undefined;
    const src = joinPath(&src_buf, dir, source_name) orelse return .missing_source;
    const twin = joinPath(&twin_buf, dir, twin_name) orelse return .write_failed;
    const new = joinPath(&new_buf, dir, new_name) orelse return .write_failed;
    const aside = joinPath(&aside_buf, dir, aside_name) orelse return .write_failed;

    const bytes = readAll(alloc, src) catch |err| return switch (err) {
        error.Missing => .missing_source,
        error.Failed, error.OutOfMemory => .read_failed,
    };
    defer alloc.free(bytes);
    const len = makeConsoleTwin(bytes) catch return .not_a_pe;

    if (!writeAll(new, bytes[0..len])) {
        _ = DeleteFileW(new);
        return .write_failed;
    }
    if (MoveFileExW(new, twin, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0) {
        return .derived;
    }
    // The old twin is held (a CLI verb still running from it). A mapped image
    // can be renamed even though it cannot be replaced, so move it aside and
    // put the new one where the PATH looks.
    _ = DeleteFileW(aside);
    if (MoveFileExW(twin, aside, MOVEFILE_REPLACE_EXISTING) != 0 and
        MoveFileExW(new, twin, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0)
    {
        // Gone now if it was only held briefly; otherwise `remove` takes it.
        _ = DeleteFileW(aside);
        return .derived_aside;
    }
    _ = DeleteFileW(new);
    return .replace_failed;
}

/// What `remove` did.
pub const Removed = struct {
    /// How many of the twin and its leftovers were there and are now gone.
    deleted: u8 = 0,
    /// How many were there and could not be deleted (still in use).
    stuck: u8 = 0,
};

/// Delete `<dir>\ghoztty.com` and anything `derive` can leave beside it, so the
/// uninstall's RemoveFolder finds an empty directory. An absent file is fine.
pub fn remove(dir: []const u16) Removed {
    var result: Removed = .{};
    var buf: [path_capacity]u16 = undefined;
    inline for (.{ twin_name, new_name, aside_name }) |name| {
        if (joinPath(&buf, dir, name)) |path| {
            if (DeleteFileW(path) != 0) {
                result.deleted += 1;
            } else {
                const err = GetLastError();
                if (err != ERROR_FILE_NOT_FOUND and err != ERROR_PATH_NOT_FOUND) result.stuck += 1;
            }
        }
    }
    return result;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

/// A minimal PE header: MZ, e_lfanew, signature, COFF header, an optional
/// header of the given magic with `ndirs` data directories, and `tail` bytes
/// of body after it.
fn fakePe(alloc: std.mem.Allocator, magic: u16, sub: u16, ndirs: u32, tail: usize) ![]u8 {
    const pe: usize = 0x80;
    const dirs: usize = if (magic == 0x20b) 112 else 96;
    const opt_size = dirs + ndirs * 8;
    const len = pe + 24 + opt_size + tail;
    const bytes = try alloc.alloc(u8, len);
    @memset(bytes, 0);
    bytes[0] = 'M';
    bytes[1] = 'Z';
    std.mem.writeInt(u32, bytes[0x3C..][0..4], @intCast(pe), .little);
    @memcpy(bytes[pe..][0..4], "PE\x00\x00");
    std.mem.writeInt(u16, bytes[pe + 20 ..][0..2], @intCast(opt_size), .little);
    const opt = pe + 24;
    std.mem.writeInt(u16, bytes[opt..][0..2], magic, .little);
    std.mem.writeInt(u16, bytes[opt + 68 ..][0..2], sub, .little);
    std.mem.writeInt(u32, bytes[opt + dirs - 4 ..][0..4], ndirs, .little);
    return bytes;
}

fn securityEntry(bytes: []u8) usize {
    return (layout(bytes) catch unreachable).security_dir.?;
}

test "the twin is the GUI image with only the subsystem changed (PE32+ and PE32)" {
    for ([_]u16{ 0x20b, 0x10b }) |magic| {
        const img = try fakePe(testing.allocator, magic, subsystem_gui, 16, 256);
        defer testing.allocator.free(img);
        const before = try testing.allocator.dupe(u8, img);
        defer testing.allocator.free(before);

        const len = try makeConsoleTwin(img);
        try testing.expectEqual(img.len, len);
        try testing.expectEqual(subsystem_console, try subsystem(img));
        // Exactly the one WORD differs.
        var diffs: usize = 0;
        for (img, before) |a, b| diffs += @intFromBool(a != b);
        try testing.expectEqual(@as(usize, 1), diffs);
    }
}

test "deriving twice is the same twin (repair over a current one)" {
    const img = try fakePe(testing.allocator, 0x20b, subsystem_gui, 16, 64);
    defer testing.allocator.free(img);
    const len1 = try makeConsoleTwin(img);
    const once = try testing.allocator.dupe(u8, img[0..len1]);
    defer testing.allocator.free(once);
    const len2 = try makeConsoleTwin(img);
    try testing.expectEqualSlices(u8, once, img[0..len2]);
}

test "a signed image loses its certificate table, not just the flag" {
    const img = try fakePe(testing.allocator, 0x20b, subsystem_gui, 16, 512);
    defer testing.allocator.free(img);
    // A certificate table as signing tools write it: the tail of the file.
    const at = securityEntry(img);
    const cert_off: u32 = @intCast(img.len - 200);
    std.mem.writeInt(u32, img[at..][0..4], cert_off, .little);
    std.mem.writeInt(u32, img[at + 4 ..][0..4], 200, .little);

    const len = try makeConsoleTwin(img);
    try testing.expectEqual(@as(usize, cert_off), len);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, img[at..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, img[at + 4 ..][0..4], .little));
}

test "a certificate followed by alignment padding is still cut at the table" {
    const img = try fakePe(testing.allocator, 0x20b, subsystem_gui, 16, 512);
    defer testing.allocator.free(img);
    const at = securityEntry(img);
    const cert_off: u32 = @intCast(img.len - 205);
    std.mem.writeInt(u32, img[at..][0..4], cert_off, .little);
    std.mem.writeInt(u32, img[at + 4 ..][0..4], 200, .little);
    try testing.expectEqual(@as(usize, cert_off), try stripSignature(img));
}

test "a certificate table that is not the tail keeps the bytes after it" {
    const img = try fakePe(testing.allocator, 0x20b, subsystem_gui, 16, 512);
    defer testing.allocator.free(img);
    const at = securityEntry(img);
    std.mem.writeInt(u32, img[at..][0..4], @intCast(img.len - 300), .little);
    std.mem.writeInt(u32, img[at + 4 ..][0..4], 100, .little);
    try testing.expectEqual(img.len, try stripSignature(img));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, img[at + 4 ..][0..4], .little));
}

test "a certificate entry pointing past the file is cleared, never followed" {
    const img = try fakePe(testing.allocator, 0x20b, subsystem_gui, 16, 64);
    defer testing.allocator.free(img);
    const at = securityEntry(img);
    std.mem.writeInt(u32, img[at..][0..4], 0x7FFF_0000, .little);
    std.mem.writeInt(u32, img[at + 4 ..][0..4], 0x1000, .little);
    try testing.expectEqual(img.len, try stripSignature(img));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, img[at..][0..4], .little));
}

test "an image with too few data directories has nothing to strip" {
    const img = try fakePe(testing.allocator, 0x20b, subsystem_gui, 4, 64);
    defer testing.allocator.free(img);
    try testing.expect((try layout(img)).security_dir == null);
    try testing.expectEqual(img.len, try makeConsoleTwin(img));
    try testing.expectEqual(subsystem_console, try subsystem(img));
}

test "anything that is not a GUI/console PE is refused, untouched" {
    // Not MZ.
    var junk = [_]u8{0} ** 512;
    try testing.expectError(error.NotAPeFile, makeConsoleTwin(&junk));
    // Truncated right after the DOS header.
    var short = [_]u8{0} ** 0x48;
    short[0] = 'M';
    short[1] = 'Z';
    std.mem.writeInt(u32, short[0x3C..][0..4], 0x40, .little);
    try testing.expectError(error.TruncatedPeFile, makeConsoleTwin(&short));
    // e_lfanew past the end.
    std.mem.writeInt(u32, short[0x3C..][0..4], 0xFFFF_FFF0, .little);
    try testing.expectError(error.TruncatedPeFile, makeConsoleTwin(&short));
    // A native-subsystem image (a driver): offset 68 is not ours to edit.
    const drv = try fakePe(testing.allocator, 0x20b, 1, 16, 64);
    defer testing.allocator.free(drv);
    const before = try testing.allocator.dupe(u8, drv);
    defer testing.allocator.free(before);
    try testing.expectError(error.UnexpectedSubsystem, makeConsoleTwin(drv));
    try testing.expectEqualSlices(u8, before, drv);
    // An unknown optional-header magic (ROM image).
    const rom = try fakePe(testing.allocator, 0x107, subsystem_gui, 16, 64);
    defer testing.allocator.free(rom);
    try testing.expectError(error.UnknownOptionalHeader, makeConsoleTwin(rom));
}

test "joinPath: MSI directories end in a separator, others do not" {
    var buf: [64]u16 = undefined;
    const with = joinPath(&buf, std.unicode.utf8ToUtf16LeStringLiteral("C:\\x\\"), twin_name).?;
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("C:\\x\\ghoztty.com"), with);
    const without = joinPath(&buf, std.unicode.utf8ToUtf16LeStringLiteral("C:\\x"), twin_name).?;
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("C:\\x\\ghoztty.com"), without);
    var tiny: [8]u16 = undefined;
    try testing.expect(joinPath(&tiny, std.unicode.utf8ToUtf16LeStringLiteral("C:\\x"), twin_name) == null);
}

// The Win32 half, against a real directory.

fn tmpDirWide(tmp: *testing.TmpDir, buf: []u16) ![]const u16 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath(".", &path_buf);
    const n = try std.unicode.utf8ToUtf16Le(buf, path);
    return buf[0..n];
}

fn writeFixture(tmp: *testing.TmpDir, name: []const u8, bytes: []const u8) !void {
    try tmp.dir.writeFile(.{ .sub_path = name, .data = bytes });
}

fn fileSubsystem(tmp: *testing.TmpDir, name: []const u8) !u16 {
    const bytes = try tmp.dir.readFileAlloc(testing.allocator, name, 1 << 20);
    defer testing.allocator.free(bytes);
    return subsystem(bytes);
}

fn exists(tmp: *testing.TmpDir, name: []const u8) bool {
    tmp.dir.access(name, .{}) catch return false;
    return true;
}

test "derive: writes ghoztty.com beside ghoztty.exe, and remove takes it away" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var wbuf: [path_capacity]u16 = undefined;
    const dir = try tmpDirWide(&tmp, &wbuf);

    const img = try fakePe(testing.allocator, 0x20b, subsystem_gui, 16, 4096);
    defer testing.allocator.free(img);
    try writeFixture(&tmp, source_name, img);

    try testing.expectEqual(Derived.derived, derive(testing.allocator, dir));
    try testing.expectEqual(subsystem_console, try fileSubsystem(&tmp, twin_name));
    // The source is never edited.
    try testing.expectEqual(subsystem_gui, try fileSubsystem(&tmp, source_name));
    try testing.expect(!exists(&tmp, new_name));

    const r = remove(dir);
    try testing.expectEqual(@as(u8, 1), r.deleted);
    try testing.expectEqual(@as(u8, 0), r.stuck);
    try testing.expect(!exists(&tmp, twin_name));
    try testing.expect(exists(&tmp, source_name));
}

test "derive: an older twin (the upgrade / repair case) is replaced" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var wbuf: [path_capacity]u16 = undefined;
    const dir = try tmpDirWide(&tmp, &wbuf);

    const img = try fakePe(testing.allocator, 0x20b, subsystem_gui, 16, 4096);
    defer testing.allocator.free(img);
    try writeFixture(&tmp, source_name, img);
    try writeFixture(&tmp, twin_name, "last release's twin");

    try testing.expectEqual(Derived.derived, derive(testing.allocator, dir));
    const twin = try tmp.dir.readFileAlloc(testing.allocator, twin_name, 1 << 20);
    defer testing.allocator.free(twin);
    try testing.expectEqual(img.len, twin.len);
    try testing.expectEqual(subsystem_console, try subsystem(twin));
}

test "derive: a twin held open is moved aside and replaced, and remove cleans both" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var wbuf: [path_capacity]u16 = undefined;
    const dir = try tmpDirWide(&tmp, &wbuf);

    const img = try fakePe(testing.allocator, 0x20b, subsystem_gui, 16, 4096);
    defer testing.allocator.free(img);
    try writeFixture(&tmp, source_name, img);
    try writeFixture(&tmp, twin_name, "held");

    // Hold the old twin the way a running image does: it can be renamed
    // (share-delete) but not overwritten (no share-write).
    var path_buf: [path_capacity]u16 = undefined;
    const twin_path = joinPath(&path_buf, dir, twin_name).?;
    const held = CreateFileW(twin_path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    try testing.expect(held != invalid_handle);
    var closed = false;
    defer if (!closed) {
        _ = CloseHandle(held);
    };

    const got = derive(testing.allocator, dir);
    try testing.expect(got == .derived or got == .derived_aside);
    try testing.expectEqual(subsystem_console, try fileSubsystem(&tmp, twin_name));

    _ = CloseHandle(held);
    closed = true;
    _ = remove(dir);
    try testing.expect(!exists(&tmp, twin_name));
    try testing.expect(!exists(&tmp, aside_name));
    try testing.expect(!exists(&tmp, new_name));
}

test "derive: no exe, or a broken one, writes no twin at all" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var wbuf: [path_capacity]u16 = undefined;
    const dir = try tmpDirWide(&tmp, &wbuf);

    try testing.expectEqual(Derived.missing_source, derive(testing.allocator, dir));
    try testing.expect(!exists(&tmp, twin_name));

    try writeFixture(&tmp, source_name, "not a PE image at all, just text");
    try testing.expectEqual(Derived.not_a_pe, derive(testing.allocator, dir));
    try testing.expect(!exists(&tmp, twin_name));
    try testing.expect(!exists(&tmp, new_name));

    // And remove over an empty directory is quiet.
    const r = remove(dir);
    try testing.expectEqual(@as(u8, 0), r.deleted);
    try testing.expectEqual(@as(u8, 0), r.stuck);
}
