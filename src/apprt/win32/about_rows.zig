//! The About box's labelled rows (T1556).
//!
//! Mac's About panel (`macos/Sources/Features/About/AboutView.swift`) lays its
//! facts out as LABELLED rows - Version, Build, Commit - and names a tip build
//! "Tip Release" rather than printing the raw build id. The win32 box printed
//! the same facts as one preformatted block, which read as a diagnostic dump.
//! This module decides what the rows are; `ConfirmDialog` draws them.
//!
//! The Windows box keeps provenance Mac does not show (Mode, Runtime, PID,
//! Started, Executable): it is also the answer to "which of my several
//! installs is this window running" (T52/T1205). That is a deliberate
//! difference in CONTENT, not in layout - the extra facts are rows too.
//!
//! Pure: no OS imports, so it compiles and is tested in every app-runtime
//! lane.

const std = @import("std");
const about_links = @import("about_links.zig");

/// One labelled row: what the value is, and the value.
pub const Row = struct {
    label: []const u8,
    value: []const u8,
};

/// Version, Build, Commit, Mode, Runtime, PID, Started, Executable.
pub const max_rows = 8;

/// What a tip build says in its Version row - Mac's exact words.
pub const tip_release = "Tip Release";

/// How the Version row reads a version string. Mirrors Mac's `VersionConfig`:
/// a bare `X.Y.Z` is a release; a build id is a tip; anything else is shown
/// as it is.
pub const VersionKind = enum { release, tip, other };

pub fn versionKind(v: []const u8) VersionKind {
    if (about_links.isReleaseVersion(v)) return .release;
    // Mac's tip shape: the version IS a commit.
    if (about_links.isCommitish(v)) return .tip;
    // Ours: an `X.Y.Z` core carrying a pre-release or build suffix
    // (`1.4.0-users-dzearing-windows-amd64-+8bf37b334`) - a build from a
    // branch, which has no release of its own.
    const cut = std.mem.indexOfAny(u8, v, "-+") orelse return .other;
    if (cut + 1 >= v.len) return .other;
    if (!about_links.isReleaseVersion(v[0..cut])) return .other;
    return .tip;
}

/// The Version row's text: the release number, "Tip Release", or the string
/// as given.
pub fn versionText(v: []const u8) []const u8 {
    return switch (versionKind(v)) {
        .release, .other => v,
        .tip => tip_release,
    };
}

/// What `build` is handed: the facts, already formatted. Everything here is
/// about THIS process (T1205).
pub const Facts = struct {
    version: []const u8,
    commit: []const u8,
    mode: []const u8,
    runtime: []const u8,
    pid: []const u8,
    started: []const u8,
    exe: []const u8,
};

/// The rows, top to bottom, written into `out` and returned as a slice of it.
///
/// The Build row carries the raw build id, and only when the Version row did
/// not already say it: "Tip Release" alone would lose the one string that
/// tells two tip builds apart. A row whose value is empty is left out, the way
/// Mac drops a row it has nothing for.
pub fn build(f: Facts, out: *[max_rows]Row) []Row {
    var n: usize = 0;
    const add = struct {
        fn add(o: *[max_rows]Row, i: *usize, label: []const u8, value: []const u8) void {
            if (value.len == 0) return;
            o[i.*] = .{ .label = label, .value = value };
            i.* += 1;
        }
    }.add;
    const shown = versionText(f.version);
    add(out, &n, "Version", shown);
    if (!std.mem.eql(u8, shown, f.version)) add(out, &n, "Build", f.version);
    add(out, &n, "Commit", f.commit);
    add(out, &n, "Mode", f.mode);
    add(out, &n, "Runtime", f.runtime);
    add(out, &n, "PID", f.pid);
    add(out, &n, "Started", f.started);
    add(out, &n, "Executable", f.exe);
    return out[0..n];
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

const tip_id = "1.4.0-users-dzearing-windows-amd64-+8bf37b334";

fn facts(version: []const u8) Facts {
    return .{
        .version = version,
        .commit = "8bf37b334",
        .mode = "Debug",
        .runtime = "win32",
        .pid = "1234",
        .started = "2026-11-20 14:00:00 UTC",
        .exe = "D:\\git\\ghoztty\\zig-out\\bin\\ghoztty.exe",
    };
}

test "versionKind: release, tip and other, like Mac's VersionConfig" {
    try testing.expectEqual(VersionKind.release, versionKind("1.4.1"));
    try testing.expectEqual(VersionKind.tip, versionKind(tip_id));
    try testing.expectEqual(VersionKind.tip, versionKind("1.4.0+8bf37b334"));
    try testing.expectEqual(VersionKind.tip, versionKind("8bf37b334"));
    try testing.expectEqual(VersionKind.other, versionKind("tip"));
    try testing.expectEqual(VersionKind.other, versionKind("1.4-x"));
    try testing.expectEqual(VersionKind.other, versionKind("1.4.0-"));
    try testing.expectEqual(VersionKind.other, versionKind(""));
}

test "versionText: a tip build says so in words" {
    try testing.expectEqualStrings("Tip Release", versionText(tip_id));
    try testing.expectEqualStrings("1.4.1", versionText("1.4.1"));
    try testing.expectEqualStrings("tip", versionText("tip"));
}

test "build: a tip build reads Tip Release and keeps its build id as Build" {
    var buf: [max_rows]Row = undefined;
    const rows = build(facts(tip_id), &buf);
    try testing.expectEqual(@as(usize, 8), rows.len);
    try testing.expectEqualStrings("Version", rows[0].label);
    try testing.expectEqualStrings("Tip Release", rows[0].value);
    try testing.expectEqualStrings("Build", rows[1].label);
    try testing.expectEqualStrings(tip_id, rows[1].value);
    try testing.expectEqualStrings("Commit", rows[2].label);
    try testing.expectEqualStrings("8bf37b334", rows[2].value);
}

test "build: a release build has no Build row - the version already says it" {
    var buf: [max_rows]Row = undefined;
    const rows = build(facts("1.4.1"), &buf);
    try testing.expectEqual(@as(usize, 7), rows.len);
    try testing.expectEqualStrings("1.4.1", rows[0].value);
    for (rows) |r| try testing.expect(!std.mem.eql(u8, r.label, "Build"));
}

test "build: the Windows provenance keeps its place, in order" {
    var buf: [max_rows]Row = undefined;
    const rows = build(facts("1.4.1"), &buf);
    const want = [_][]const u8{ "Version", "Commit", "Mode", "Runtime", "PID", "Started", "Executable" };
    for (want, rows) |w, r| try testing.expectEqualStrings(w, r.label);
    try testing.expectEqualStrings("D:\\git\\ghoztty\\zig-out\\bin\\ghoztty.exe", rows[6].value);
}

test "build: an empty fact is dropped, not shown blank" {
    var buf: [max_rows]Row = undefined;
    var f = facts("1.4.1");
    f.started = "";
    const rows = build(f, &buf);
    try testing.expectEqual(@as(usize, 6), rows.len);
    for (rows) |r| try testing.expect(r.value.len > 0);
}
