//! The About box's links, and the one place this fork's URLs live (T714).
//!
//! Mac's About panel is a column of rows plus two buttons, and every
//! destination on it derives from a single `githubURL` constant so the GitHub
//! button, the commit row and the release-notes row cannot drift apart
//! (`macos/Sources/Features/About/AboutView.swift`). The win32 About box had
//! no links at all: a block of provenance text with no way from the app to the
//! release it is running, and a Help item still pointing at upstream
//! ghostty.org. This module is the Windows half of that constant, plus the
//! decisions about WHICH links a given build earns.
//!
//! Two of the four links are conditional, for the same reason they are on Mac:
//!
//!   - A **release** link only exists when the version string is a bare
//!     `X.Y.Z`. A tip build's version carries its branch and commit
//!     (`1.4.0-users-dzearing-windows-amd64-+8bf37b334`) and there is no
//!     release page for it, so a link would be a 404 dressed up as an answer.
//!   - A **commit** link only exists when the build stamped one. `unknown` is
//!     what `provenance.commit` says when it did not.
//!
//! The release URL is where the platforms legitimately differ: Mac's releases
//! are tagged `vX.Y.Z` and ours are tagged `win-vX.Y.Z` (see
//! `update_check.zig`), so the same row points at the tag that actually
//! carries these bytes.
//!
//! Pure: no OS imports, so it compiles and is tested in every app-runtime
//! lane.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The one place this fork lives. Every link below derives from it.
pub const repo_url = "https://github.com/dzearing/ghoztty";

/// The fork's docs site — what Help opens, and what the Docs link opens.
/// Mac pointed both here in 6ea66423f; win32's `commands.help_url` was still
/// upstream's `ghostty.org/docs` until this task.
pub const docs_url = "https://dzearing.github.io/ghoztty/";

/// The releases index — the fallback destination when no specific version is
/// known (the update balloon's click target).
pub const releases_url = repo_url ++ "/releases";

/// Release page for a specific WINDOWS build: the version text (e.g. "1.4.1")
/// is appended to form `.../releases/tag/win-v1.4.1`.
pub const release_tag_url_prefix = repo_url ++ "/releases/tag/win-v";

/// Commit page: the sha is appended. `commits/<sha>` rather than
/// `commit/<sha>`, matching Mac's About row — GitHub resolves both, and the
/// two About boxes should not disagree about the shape of their own URL.
pub const commits_url_prefix = repo_url ++ "/commits/";

/// A link the About box shows: what it says, and where it goes.
pub const Link = struct {
    label: []const u8,
    url: []const u8,
};

/// The most links the About box can carry (release, commit, docs, repo).
pub const max_links = 4;

/// True when `v` is exactly `X.Y.Z` — the shape that has a release page.
/// Mac's `VersionConfig` asks the same question with `^\d+\.\d+\.\d+$`.
pub fn isReleaseVersion(v: []const u8) bool {
    var parts = std.mem.splitScalar(u8, v, '.');
    var n: usize = 0;
    while (parts.next()) |part| {
        n += 1;
        if (n > 3) return false;
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return n == 3;
}

/// True when `c` looks like a git object name: 7–40 lowercase hex digits.
/// `provenance.commit` is "unknown" when the build stamped none, and a link
/// to `commits/unknown` is worse than no link.
pub fn isCommitish(c: []const u8) bool {
    if (c.len < 7 or c.len > 40) return false;
    for (c) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

/// The release page for `version`, or null when this build has none.
pub fn releaseUrl(alloc: Allocator, version: []const u8) Allocator.Error!?[]const u8 {
    if (!isReleaseVersion(version)) return null;
    return try std.fmt.allocPrint(alloc, "{s}{s}", .{ release_tag_url_prefix, version });
}

/// The commit page for `commit`, or null when this build stamped none.
pub fn commitUrl(alloc: Allocator, commit: []const u8) Allocator.Error!?[]const u8 {
    if (!isCommitish(commit)) return null;
    return try std.fmt.allocPrint(alloc, "{s}{s}", .{ commits_url_prefix, commit });
}

/// The links this build's About box shows, written into `out` and returned as
/// a slice of it. Ordered the way Mac's About reads top to bottom: the version
/// row, then the commit row, then the two buttons.
pub fn build(
    alloc: Allocator,
    version: []const u8,
    commit: []const u8,
    out: *[max_links]Link,
) Allocator.Error![]Link {
    var n: usize = 0;
    if (try releaseUrl(alloc, version)) |url| {
        out[n] = .{ .label = "Release notes", .url = url };
        n += 1;
    }
    if (try commitUrl(alloc, commit)) |url| {
        out[n] = .{ .label = "Commit", .url = url };
        n += 1;
    }
    out[n] = .{ .label = "Docs", .url = docs_url };
    n += 1;
    out[n] = .{ .label = "GitHub", .url = repo_url };
    n += 1;
    return out[0..n];
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "isReleaseVersion: bare semver only" {
    try testing.expect(isReleaseVersion("1.4.1"));
    try testing.expect(isReleaseVersion("0.0.0"));
    try testing.expect(isReleaseVersion("10.20.30"));

    // A tip build carries its branch and commit; there is no release for it.
    try testing.expect(!isReleaseVersion("1.4.0-users-dzearing-windows-amd64-+8bf37b334"));
    try testing.expect(!isReleaseVersion("1.4"));
    try testing.expect(!isReleaseVersion("1.4.1.2"));
    try testing.expect(!isReleaseVersion("v1.4.1"));
    try testing.expect(!isReleaseVersion("1..1"));
    try testing.expect(!isReleaseVersion(""));
}

test "isCommitish: 7-40 hex digits" {
    try testing.expect(isCommitish("8bf37b334"));
    try testing.expect(isCommitish("abcdef1"));
    try testing.expect(isCommitish("1234567890abcdef1234567890abcdef12345678"));

    try testing.expect(!isCommitish("unknown"));
    try testing.expect(!isCommitish("abcdef"));
    try testing.expect(!isCommitish("1234567890abcdef1234567890abcdef123456789"));
    try testing.expect(!isCommitish(""));
}

test "releaseUrl: the WINDOWS tag, not the Mac one" {
    const url = (try releaseUrl(testing.allocator, "1.4.1")).?;
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://github.com/dzearing/ghoztty/releases/tag/win-v1.4.1",
        url,
    );
    try testing.expect((try releaseUrl(testing.allocator, "1.4.0-tip-+abc1234")) == null);
}

test "commitUrl: the fork's history, never upstream's" {
    const url = (try commitUrl(testing.allocator, "8bf37b334")).?;
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://github.com/dzearing/ghoztty/commits/8bf37b334",
        url,
    );
    try testing.expect((try commitUrl(testing.allocator, "unknown")) == null);
}

test "build: a release build earns all four links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [max_links]Link = undefined;
    const links = try build(arena.allocator(), "1.4.1", "8bf37b334", &buf);
    try testing.expectEqual(@as(usize, 4), links.len);
    try testing.expectEqualStrings("Release notes", links[0].label);
    try testing.expectEqualStrings(
        "https://github.com/dzearing/ghoztty/releases/tag/win-v1.4.1",
        links[0].url,
    );
    try testing.expectEqualStrings("Commit", links[1].label);
    try testing.expectEqualStrings("Docs", links[2].label);
    try testing.expectEqualStrings(docs_url, links[2].url);
    try testing.expectEqualStrings("GitHub", links[3].label);
    try testing.expectEqualStrings(repo_url, links[3].url);
}

test "build: a tip build drops the release link, keeps the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [max_links]Link = undefined;
    const links = try build(
        arena.allocator(),
        "1.4.0-users-dzearing-windows-amd64-+8bf37b334",
        "8bf37b334",
        &buf,
    );
    try testing.expectEqual(@as(usize, 3), links.len);
    try testing.expectEqualStrings("Commit", links[0].label);
    try testing.expectEqualStrings("Docs", links[1].label);
    try testing.expectEqualStrings("GitHub", links[2].label);
}

test "build: an unstamped build still reaches the docs and the repo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [max_links]Link = undefined;
    const links = try build(arena.allocator(), "tip", "unknown", &buf);
    try testing.expectEqual(@as(usize, 2), links.len);
    try testing.expectEqualStrings("Docs", links[0].label);
    try testing.expectEqualStrings("GitHub", links[1].label);
}

test "every link points at the fork, never upstream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [max_links]Link = undefined;
    const links = try build(arena.allocator(), "1.4.1", "8bf37b334", &buf);
    for (links) |link| {
        try testing.expect(std.mem.indexOf(u8, link.url, "ghostty.org") == null);
        try testing.expect(std.mem.indexOf(u8, link.url, "ghostty-org") == null);
        try testing.expect(std.mem.startsWith(u8, link.url, "https://"));
    }
}
