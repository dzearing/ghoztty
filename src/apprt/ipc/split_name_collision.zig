//! What `+split --name=<name>` does when something already holds that name
//! (T2184; the Mac's `SplitNameCollision.swift`, main c2057a810).
//!
//! The name is the idempotency key: re-running the same launch must not
//! duplicate the pane, so a matching request REUSES it. It used to reuse on
//! the name alone - silently, from any window, whatever was asked for - so a
//! caller asking for `--view=b.html` beside itself got exit 0 and nothing,
//! while a pane of the same name in another window went on showing `a.html`.
//! Now:
//!
//!   * A request the existing pane already satisfies is reused, and the reply
//!     says so and names the window - which may not be the caller's: pane
//!     names are one namespace across every window (they are `--target`s), so
//!     a second pane cannot take the name without orphaning the first.
//!   * A request it does NOT satisfy - another `--view`, or a terminal where a
//!     viewer stands (or the reverse), or a WINDOW of that name - fails,
//!     naming the pane, its window, and what it shows. Retargeting the pane
//!     instead would hijack whatever else put it there, often another agent.
//!
//! The wording is the Mac's, character for character, so a script reading the
//! line gets the same answer from either platform. Pure, so both the policy
//! and the wording are tested without windows.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// What currently holds the name, and where.
pub const Existing = struct {
    kind: Kind,
    /// The IPC name of the window holding it (the window itself, for
    /// `.window`).
    window_name: []const u8,
    /// Whether that window is the one the split would have anchored in.
    in_anchor_window: bool,

    pub const Kind = union(enum) {
        terminal,
        /// `location` is what it shows now, `home_location` what it was
        /// opened with (null when it has none).
        viewer: struct { location: []const u8, home_location: ?[]const u8 = null },
        /// A WINDOW of that name: `--target`s and pane names are one
        /// namespace, so a pane cannot take it.
        window,
    };
};

pub const Outcome = union(enum) {
    /// The existing pane is the answer; no split is created. The line the
    /// CLI prints to stdout.
    reuse: []u8,
    /// The request conflicts with the existing pane; the command fails with
    /// this text.
    conflict: []u8,
};

/// Decide what a `+split --name=<name>` (asking for `requested_view`, or a
/// terminal when null) does about `existing`. The returned text is allocated
/// from `alloc`.
pub fn decide(
    alloc: Allocator,
    name: []const u8,
    existing: Existing,
    requested_view: ?[]const u8,
) Allocator.Error!Outcome {
    var window_buf: [512]u8 = undefined;
    const window = (if (existing.in_anchor_window)
        std.fmt.bufPrint(&window_buf, "this window ('{s}')", .{existing.window_name})
    else
        std.fmt.bufPrint(&window_buf, "window '{s}', not the window this split was for", .{existing.window_name})) catch
        existing.window_name;

    const close_hint = "Use another --name, or close it first: ghoztty +close --target=";

    switch (existing.kind) {
        .window => return .{ .conflict = try std.fmt.allocPrint(
            alloc,
            "'{s}' is already the name of a window, so no pane can take it. Use another --name.",
            .{name},
        ) },
        .terminal => if (requested_view) |view| {
            return .{ .conflict = try std.fmt.allocPrint(
                alloc,
                "pane '{s}' already exists in {s} as a terminal pane, so it cannot show {s}. " ++ close_hint ++ "{s}",
                .{ name, window, view, name },
            ) };
        } else {
            return .{ .reuse = try std.fmt.allocPrint(
                alloc,
                "pane '{s}' already exists in {s}; reused it, no split created",
                .{ name, window },
            ) };
        },
        .viewer => |v| if (requested_view) |view| {
            if (sameLocation(view, v.location) or
                (v.home_location != null and sameLocation(view, v.home_location.?)))
            {
                return .{ .reuse = try std.fmt.allocPrint(
                    alloc,
                    "pane '{s}' already exists in {s}, showing {s}; reused it, no split created",
                    .{ name, window, view },
                ) };
            }
            return .{ .conflict = try std.fmt.allocPrint(
                alloc,
                "pane '{s}' already exists in {s}, showing {s}, not {s}. " ++ close_hint ++ "{s}",
                .{ name, window, v.location, view, name },
            ) };
        } else {
            return .{ .conflict = try std.fmt.allocPrint(
                alloc,
                "pane '{s}' already exists in {s} as a viewer pane showing {s}, not a terminal. " ++ close_hint ++ "{s}",
                .{ name, window, v.location, name },
            ) };
        },
    }
}

/// Whether two viewer locations name the same thing. The Mac's spelling
/// rules - a `file://` URL is its path, and trailing slashes do not count -
/// plus the Windows ones: a local path compares case-insensitively with `/`
/// and `\` interchangeable, because the filesystem it names does, and a viewer
/// that navigated reports its file as `file:///D:/a%20b.md`.
pub fn sameLocation(a: []const u8, b: []const u8) bool {
    var buf_a: [4096]u8 = undefined;
    var buf_b: [4096]u8 = undefined;
    const na = normalized(&buf_a, a);
    const nb = normalized(&buf_b, b);
    if (isLocalPath(na) and isLocalPath(nb)) {
        if (na.len != nb.len) return false;
        for (na, nb) |ca, cb| {
            if (foldPathChar(ca) != foldPathChar(cb)) return false;
        }
        return true;
    }
    return std.mem.eql(u8, na, nb);
}

/// `location` with a `file://` URL reduced to its (percent-decoded) path and
/// trailing slashes dropped. Falls back to the input when it does not fit.
fn normalized(buf: []u8, location: []const u8) []const u8 {
    var value = location;
    if (fileUrlPath(buf, location)) |path| value = path;
    while (value.len > 1 and (value[value.len - 1] == '/' or value[value.len - 1] == '\\'))
        value = value[0 .. value.len - 1];
    return value;
}

/// The path a `file:` URL names, decoded into `buf`: `file:///D:/x` is
/// `D:/x`, `file://server/share/x` is `//server/share/x`, and on the Mac
/// `file:///Users/x` is `/Users/x`. Null for anything else.
fn fileUrlPath(buf: []u8, location: []const u8) ?[]const u8 {
    const scheme = "file://";
    if (location.len < scheme.len or !std.ascii.eqlIgnoreCase(location[0..scheme.len], scheme)) return null;
    var rest = location[scheme.len..];
    var len: usize = 0;
    if (std.mem.startsWith(u8, rest, "/")) {
        // `file:///D:/x`: the drive path follows the third slash.
        if (rest.len >= 3 and std.ascii.isAlphabetic(rest[1]) and rest[2] == ':') rest = rest[1..];
    } else {
        // `file://server/share`: a UNC path.
        if (buf.len < 2) return null;
        buf[0] = '/';
        buf[1] = '/';
        len = 2;
    }
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (len >= buf.len) return null;
        var c = rest[i];
        if (c == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |byte| {
                c = byte;
                i += 2;
            } else |_| {}
        }
        buf[len] = c;
        len += 1;
    }
    return buf[0..len];
}

/// A drive-letter or UNC path - the spellings whose filesystem ignores case.
fn isLocalPath(s: []const u8) bool {
    if (s.len >= 2 and std.ascii.isAlphabetic(s[0]) and s[1] == ':') return true;
    return s.len >= 2 and (s[0] == '\\' or s[0] == '/') and (s[1] == '\\' or s[1] == '/');
}

fn foldPathChar(c: u8) u8 {
    return if (c == '\\') '/' else std.ascii.toLower(c);
}

const testing = std.testing;

fn expectReuse(outcome: Outcome, want: []const u8) !void {
    switch (outcome) {
        .reuse => |m| try testing.expectEqualStrings(want, m),
        .conflict => |e| {
            std.debug.print("expected reuse, got conflict: {s}\n", .{e});
            return error.TestExpectedEqual;
        },
    }
}

fn expectConflict(outcome: Outcome, want: []const u8) !void {
    switch (outcome) {
        .conflict => |e| try testing.expectEqualStrings(want, e),
        .reuse => |m| {
            std.debug.print("expected conflict, got reuse: {s}\n", .{m});
            return error.TestExpectedEqual;
        },
    }
}

// The cases below are the Mac's `SplitNameCollisionTests`, wording included.

test "a terminal asked for again is reused, naming this window" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectReuse(try decide(arena.allocator(), "build", .{
        .kind = .terminal,
        .window_name = "window-1",
        .in_anchor_window = true,
    }, null), "pane 'build' already exists in this window ('window-1'); reused it, no split created");
}

test "a terminal in another window is reused and says which window" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectReuse(try decide(arena.allocator(), "build", .{
        .kind = .terminal,
        .window_name = "window-2",
        .in_anchor_window = false,
    }, null), "pane 'build' already exists in window 'window-2', not the window this split was for; reused it, no split created");
}

test "a viewer showing the requested view is reused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectReuse(try decide(arena.allocator(), "doc", .{
        .kind = .{ .viewer = .{ .location = "D:\\a\\b.md", .home_location = "D:\\a\\b.md" } },
        .window_name = "window-1",
        .in_anchor_window = true,
    }, "D:\\a\\b.md"), "pane 'doc' already exists in this window ('window-1'), showing D:\\a\\b.md; reused it, no split created");
}

test "a viewer that navigated away still matches the view it was opened with" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outcome = try decide(arena.allocator(), "site", .{
        .kind = .{ .viewer = .{ .location = "https://x.com/page2", .home_location = "https://x.com" } },
        .window_name = "window-1",
        .in_anchor_window = true,
    }, "https://x.com/");
    try testing.expect(outcome == .reuse);
}

test "a viewer showing another view is a conflict naming both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectConflict(try decide(arena.allocator(), "doc", .{
        .kind = .{ .viewer = .{ .location = "D:\\a\\a.html", .home_location = "D:\\a\\a.html" } },
        .window_name = "window-2",
        .in_anchor_window = false,
    }, "D:\\a\\b.html"), "pane 'doc' already exists in window 'window-2', not the window this split was for, showing D:\\a\\a.html, not D:\\a\\b.html. Use another --name, or close it first: ghoztty +close --target=doc");
}

test "a terminal asked for where a viewer stands is a conflict" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectConflict(try decide(arena.allocator(), "doc", .{
        .kind = .{ .viewer = .{ .location = "D:\\a\\a.md" } },
        .window_name = "window-1",
        .in_anchor_window = true,
    }, null), "pane 'doc' already exists in this window ('window-1') as a viewer pane showing D:\\a\\a.md, not a terminal. Use another --name, or close it first: ghoztty +close --target=doc");
}

test "a view asked for where a terminal stands is a conflict" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectConflict(try decide(arena.allocator(), "build", .{
        .kind = .terminal,
        .window_name = "window-1",
        .in_anchor_window = true,
    }, "D:\\a\\a.md"), "pane 'build' already exists in this window ('window-1') as a terminal pane, so it cannot show D:\\a\\a.md. Use another --name, or close it first: ghoztty +close --target=build");
}

test "a window's name is never taken by a pane" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_]?[]const u8{ null, "D:\\a\\a.md" }) |view| {
        try expectConflict(try decide(arena.allocator(), "main", .{
            .kind = .window,
            .window_name = "main",
            .in_anchor_window = true,
        }, view), "'main' is already the name of a window, so no pane can take it. Use another --name.");
    }
}

test "sameLocation: the Mac's spellings - trailing slash and file URL" {
    try testing.expect(sameLocation("https://x.com", "https://x.com/"));
    try testing.expect(sameLocation("/Users/a/dir/", "/Users/a/dir"));
    try testing.expect(sameLocation("file:///Users/a/b.md", "/Users/a/b.md"));
    // A URL is compared exactly otherwise: its path is case-sensitive.
    try testing.expect(!sameLocation("https://x.com/A", "https://x.com/a"));
    try testing.expect(!sameLocation("/Users/a/B.md", "/Users/a/b.md"));
}

test "sameLocation: a Windows path ignores case and slash direction" {
    try testing.expect(sameLocation("D:\\git\\README.md", "d:/GIT/readme.md"));
    try testing.expect(sameLocation("file:///D:/git/a%20b.md", "D:\\git\\a b.md"));
    try testing.expect(sameLocation("file://server/share/x.md", "\\\\server\\share\\x.md"));
    try testing.expect(sameLocation("D:\\git\\", "D:\\git"));
    try testing.expect(!sameLocation("D:\\git\\a.md", "D:\\git\\b.md"));
    try testing.expect(!sameLocation("D:\\git\\a.md", "git-status:D:\\git"));
}
