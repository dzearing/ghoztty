//! Is the window you are looking at running the build that is on disk? (T1205)
//!
//! Windows cannot replace a running image, so every open Ghoztty keeps the
//! executable it was launched with for as long as it lives. An upgrade
//! replaces the FILE; the running PROCESS carries on being the old build.
//! That is normal, expected, and — until this module — completely invisible:
//! on 2026-08-31 the user installed 1.35.0, opened About to check it had
//! worked, and read `1.4.0-…` (the process) next to today's date (the file).
//! Two different builds in one box, and no surface anywhere said so.
//!
//! The comparison is deliberately between two RUNTIME facts rather than two
//! version strings:
//!
//! - **When this process started** (`GetProcessTimes`), and
//! - **when the file it was launched from was last written** (its mtime).
//!
//! A file written after we started is, by definition, not the image we are
//! running — whoever wrote it (msiexec, the upgrade script, a `zig build`)
//! and whatever version it claims. Reading the version out of the on-disk PE
//! instead would answer a weaker question: an equal version string does not
//! mean an equal build (this branch ships many builds per version), and a
//! version resource is stamped by the packaging pipeline rather than by the
//! thing that replaced the file.
//!
//! **The mtime is the trigger, not the verdict** (T1365). A Repair, or a
//! reinstall of the version already installed, rewrites the SAME bytes with a
//! fresh mtime, and the mtime alone then told every open window a newer build
//! was installed when nothing had changed. So a stale-looking file is
//! confirmed before anyone is told: the PE header's link stamp
//! (`IMAGE_FILE_HEADER.TimeDateStamp`) of the file on disk is compared with
//! the one in this process's own mapped image. Equal stamps mean the file was
//! rewritten with the build we are already running. The stamp is per LINK —
//! the link time in a Debug build, a hash of the output in a release one — so
//! it does not reintroduce the per-release weakness of a version string. An
//! unreadable or zero stamp falls back to the mtime verdict alone, which is
//! the T1205 behaviour.
//!
//! No OS calls live here, so the logic is asserted in every lane; the
//! timestamps and the two headers are collected in `provenance.zig`.

const std = @import("std");

/// Windows FILETIME ticks are 100ns; the epoch is 1601-01-01 UTC. This is the
/// number of those ticks between 1601-01-01 and 1970-01-01.
pub const filetime_unix_epoch_ticks: u64 = 116_444_736_000_000_000;

/// Slack absorbed before a newer file counts as a newer build.
///
/// The two clocks are the same clock, so this is not for drift — it is for
/// the ordinary case where an installer finishes writing the exe and starts
/// it in the same breath, and the file's mtime lands a hair after the
/// process's creation time. Two seconds is far under the gap that matters (a
/// window running since yesterday) and far over that race.
pub const tolerance_ns: i128 = 2 * std.time.ns_per_s;

/// Convert a Windows FILETIME (as a u64 of 100ns ticks since 1601) to
/// nanoseconds since the Unix epoch, which is what `std.fs.File.Stat.mtime`
/// speaks and therefore the one unit this module compares in.
pub fn filetimeToUnixNs(ticks: u64) i128 {
    const rel: i128 = @as(i128, ticks) - @as(i128, filetime_unix_epoch_ticks);
    return rel * 100;
}

/// True when the executable on disk was written after this process started —
/// i.e. a newer build is installed and this window is not running it.
///
/// Unknown inputs (either timestamp zero or negative, which is how the
/// collectors report "could not tell") are never stale: an unanswerable
/// question must not produce a notification telling the user to restart.
pub fn isStale(on_disk_ns: i128, started_ns: i128) bool {
    if (on_disk_ns <= 0 or started_ns <= 0) return false;
    return on_disk_ns > started_ns + tolerance_ns;
}

/// How many leading bytes of an image `linkStamp` needs to be handed. The
/// headers always fit in the first page, and that page is always mapped.
pub const header_probe_len: usize = 4096;

/// The link stamp (`IMAGE_FILE_HEADER.TimeDateStamp`) of the PE image whose
/// leading bytes are `header`, or null when `header` is not a PE image, is too
/// short to hold one, or carries a zero stamp (a linker that writes none —
/// zero would make every such build "the same build").
pub fn linkStamp(header: []const u8) ?u32 {
    if (header.len < 0x40) return null;
    if (header[0] != 'M' or header[1] != 'Z') return null;
    const pe = std.mem.readInt(u32, header[0x3c..][0..4], .little);
    // "PE\0\0", then Machine (2), NumberOfSections (2), TimeDateStamp (4).
    if (pe > header.len or header.len - pe < 12) return null;
    if (!std.mem.eql(u8, header[pe..][0..4], "PE\x00\x00")) return null;
    const stamp = std.mem.readInt(u32, header[pe + 8 ..][0..4], .little);
    return if (stamp == 0) null else stamp;
}

/// True when a newer BUILD is installed: the file is newer than the process
/// (`isStale`) and, when both link stamps are known, they differ. Same stamp
/// means a Repair or same-version reinstall rewrote the bytes we are running.
pub fn isNewerBuild(on_disk_ns: i128, started_ns: i128, disk_stamp: ?u32, running_stamp: ?u32) bool {
    if (!isStale(on_disk_ns, started_ns)) return false;
    const d = disk_stamp orelse return true;
    const r = running_stamp orelse return true;
    return d != r;
}

/// A minimal PE header for the tests: "MZ", e_lfanew at 0x3c, "PE\0\0",
/// and the stamp at e_lfanew + 8.
fn testHeader(stamp: u32) [0x100]u8 {
    var h = [_]u8{0} ** 0x100;
    h[0] = 'M';
    h[1] = 'Z';
    std.mem.writeInt(u32, h[0x3c..][0..4], 0x80, .little);
    @memcpy(h[0x80..][0..4], "PE\x00\x00");
    std.mem.writeInt(u32, h[0x88..][0..4], stamp, .little);
    return h;
}

test "linkStamp: reads TimeDateStamp from a PE header" {
    const testing = std.testing;
    const h = testHeader(0xc26de48d);
    try testing.expectEqual(@as(?u32, 0xc26de48d), linkStamp(&h));
}

test "linkStamp: not a PE image, truncated, or zero is unknown" {
    const testing = std.testing;
    var h = testHeader(0x1679f469);
    // Truncated before the stamp.
    try testing.expectEqual(@as(?u32, null), linkStamp(h[0..0x8a]));
    // Too short to hold e_lfanew at all.
    try testing.expectEqual(@as(?u32, null), linkStamp(h[0..0x20]));
    // e_lfanew pointing past the buffer.
    std.mem.writeInt(u32, h[0x3c..][0..4], 0xffff_fff0, .little);
    try testing.expectEqual(@as(?u32, null), linkStamp(&h));
    // No MZ.
    var nomz = testHeader(0x1679f469);
    nomz[0] = 0;
    try testing.expectEqual(@as(?u32, null), linkStamp(&nomz));
    // No PE signature.
    var nope = testHeader(0x1679f469);
    nope[0x81] = 'X';
    try testing.expectEqual(@as(?u32, null), linkStamp(&nope));
    // A zero stamp says nothing about which build it is.
    const zero = testHeader(0);
    try testing.expectEqual(@as(?u32, null), linkStamp(&zero));
}

test "isNewerBuild: a repair rewrites the build we are running and says nothing" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    const later = start + 60 * std.time.ns_per_s;
    // Same bytes, fresh mtime: the T1365 repair.
    try testing.expect(!isNewerBuild(later, start, 0xc26de48d, 0xc26de48d));
}

test "isNewerBuild: a genuine upgrade still counts" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    const later = start + 60 * std.time.ns_per_s;
    try testing.expect(isNewerBuild(later, start, 0x1679f469, 0xc26de48d));
}

test "isNewerBuild: an unknown stamp falls back to the mtime verdict" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    const later = start + 60 * std.time.ns_per_s;
    try testing.expect(isNewerBuild(later, start, null, 0xc26de48d));
    try testing.expect(isNewerBuild(later, start, 0xc26de48d, null));
    try testing.expect(!isNewerBuild(start, start, null, null));
}

test "isNewerBuild: different stamps on an older file are not news" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    // The mtime stays the trigger: a file written before we started is the
    // one we launched from, whatever its header says.
    try testing.expect(!isNewerBuild(start - std.time.ns_per_s, start, 0x1, 0x2));
}

test "isStale: a file written after we started is a newer build" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    // Replaced a minute later — the upgrade case.
    try testing.expect(isStale(start + 60 * std.time.ns_per_s, start));
}

test "isStale: the file we launched from is not stale" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    // Written before we started, which is every normal launch.
    try testing.expect(!isStale(start - 5 * std.time.ns_per_s, start));
    // Written in the same breath as the launch: inside the tolerance.
    try testing.expect(!isStale(start + std.time.ns_per_s, start));
    try testing.expect(!isStale(start, start));
}

test "isStale: the tolerance is exclusive at its edge" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    try testing.expect(!isStale(start + tolerance_ns, start));
    try testing.expect(isStale(start + tolerance_ns + 1, start));
}

test "isStale: an unknown timestamp never nags" {
    const testing = std.testing;
    const start: i128 = 1_784_280_700 * std.time.ns_per_s;
    try testing.expect(!isStale(0, start));
    try testing.expect(!isStale(start + 60 * std.time.ns_per_s, 0));
    try testing.expect(!isStale(-1, -1));
}

test "filetimeToUnixNs: the epoch constant lands on 1970" {
    const testing = std.testing;
    try testing.expectEqual(@as(i128, 0), filetimeToUnixNs(filetime_unix_epoch_ticks));
}

test "filetimeToUnixNs: a known instant round-trips to seconds" {
    const testing = std.testing;
    // 2026-07-17 09:31:40 UTC == 1784280700 unix seconds.
    const ticks = filetime_unix_epoch_ticks + 1_784_280_700 * 10_000_000;
    const ns = filetimeToUnixNs(ticks);
    try testing.expectEqual(@as(i128, 1_784_280_700), @divFloor(ns, std.time.ns_per_s));
}

test "filetimeToUnixNs: a pre-1970 FILETIME is negative, not enormous" {
    const testing = std.testing;
    // One second before the Unix epoch. An unsigned subtraction here would
    // wrap to ~5.8e11 seconds in the future and make every window "stale".
    const ns = filetimeToUnixNs(filetime_unix_epoch_ticks - 10_000_000);
    try testing.expectEqual(@as(i128, -1 * std.time.ns_per_s), ns);
}
