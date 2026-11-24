//! The GTK session-layout manifest's pure half (T3551): where the file
//! lives, the first leaf of a split tree, the window size a capture records
//! and a restore replays (T3549), and what a viewer leaf restores (T3420).
//!
//! It is split out of `SessionLayout.zig` because that file imports GTK
//! classes, so no test lane could compile its tests: the none lane cannot take
//! GTK, and `zig build test -Dapp-runtime=gtk` never referenced the file. This
//! one is std-only, like `viewer_scheme.zig`, so every lane runs it
//! (`apprt/unit_tests.zig`). `SessionLayout.zig` maps the plain results onto
//! its GTK types (`WindowSize`, `Surface.Restore`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const schema = @import("../win32/session_layout.zig");
const agent_paths = @import("../../remote/local_agent_paths.zig");
const agent_lineage = @import("../../remote/agent_lineage.zig");

/// `<root>/ghoztty/session-layout[-debug][-<lineage>].json`, under the same
/// config root as the local agent's state dir (`$XDG_CONFIG_HOME`, else
/// `~/.config`).
pub fn layoutPathFrom(
    alloc: Allocator,
    is_debug: bool,
    instance: ?[]const u8,
    xdg_config_home: ?[]const u8,
    home: []const u8,
) ![]u8 {
    const root = try agent_paths.configRoot(alloc, true, xdg_config_home, home);
    defer alloc.free(root);
    const stem = if (is_debug) "session-layout-debug" else "session-layout";
    var stem_buf: [64]u8 = undefined;
    const full = try agent_lineage.appendSuffix(&stem_buf, stem, instance);
    return std.fmt.allocPrint(alloc, "{s}/ghoztty/{s}.json", .{ root, full });
}

/// The first (left-most) leaf under `nodes[idx]`, or null for an index out
/// of range, a node that is neither, or a cycle (`depth` bounds the walk).
pub fn firstLeaf(nodes: []const schema.Node, idx: usize, depth: usize) ?schema.Leaf {
    if (idx >= nodes.len or depth > nodes.len) return null;
    if (nodes[idx].leaf) |lf| return lf;
    const sp = nodes[idx].split orelse return null;
    return firstLeaf(nodes, sp.left, depth + 1);
}

/// Window sizes outside this range are not a size anybody had: a corrupt or
/// hand-edited manifest. Under the minimum GTK's own size request wins
/// anyway; over the maximum is no monitor.
pub const min_window_px: i32 = 100;
pub const max_window_px: i32 = 16384;

/// A window size in logical pixels (the GTK side's `WindowSize`).
pub const Size = struct { w: i32, h: i32 };

/// The frame a window of `w` x `h` logical pixels records (T3549), or null
/// when it has no size to record. Wayland gives no position: x/y are 0.
pub fn frameFromSize(w: c_int, h: c_int) ?schema.Frame {
    if (w <= 0 or h <= 0) return null;
    return .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) };
}

/// The size a restored window opens at (T3549): the recorded frame's, or
/// null (the ordinary default) for none or an impossible one.
pub fn restoreSize(frame: ?schema.Frame) ?Size {
    const f = frame orelse return null;
    if (f.w < min_window_px or f.h < min_window_px) return null;
    if (f.w > max_window_px or f.h > max_window_px) return null;
    return .{ .w = f.w, .h = f.h };
}

/// What a viewer leaf restores (T3420; win32's `restoreViewerOpen`): the
/// recorded pane id (scripts address it by id), the recorded Home (the
/// restore navigates to where the pane IS, which would otherwise re-home it)
/// and the origin directory, which arrives as the pane's working directory -
/// the repository a diff spec re-runs in. Never a session.
pub const ViewerRestore = struct {
    pane_id: ?[]const u8 = null,
    working_directory: ?[]const u8 = null,
    viewer_home: ?[]const u8 = null,
};

pub fn viewerRestore(leaf: schema.Leaf) ViewerRestore {
    return .{
        .pane_id = leaf.pane_id,
        .working_directory = leaf.viewer_origin_directory,
        .viewer_home = leaf.viewer_home_location,
    };
}

/// The banner a terminal leaf records (T3560; win32's T422 leaf `banner`):
/// the pane's raw markdown SOURCE, so a restore re-runs the parser the
/// user's `+set-banner` did. No banner, or a cleared one, records none -
/// which leaves the restored pane's slot free for the session-interrupted
/// notice.
pub fn bannerToRecord(text: ?[]const u8) ?[]const u8 {
    const t = text orelse return null;
    return if (t.len > 0) t else null;
}

/// The banner a restored leaf puts back (T3560): a terminal leaf's recorded
/// source, never a viewer's (a viewer has no banner; `+set-banner` refuses
/// one) and never an empty one. Non-null also tells the pane's backend its
/// banner slot is taken (`pane_banner_restored`).
pub fn bannerToRestore(leaf: schema.Leaf) ?[]const u8 {
    if (leaf.isViewer()) return null;
    return bannerToRecord(leaf.banner);
}

test "bannerToRecord keeps the source and records none for no banner" {
    const src = "## T3560\n- [x] **restore** the `banner`";
    try std.testing.expectEqualStrings(src, bannerToRecord(src).?);
    try std.testing.expect(bannerToRecord(null) == null);
    try std.testing.expect(bannerToRecord("") == null);
}

test "bannerToRestore: a terminal leaf's banner comes back, a viewer's and an empty one never" {
    try std.testing.expectEqualStrings("goal", bannerToRestore(.{ .session_id = "s", .banner = "goal" }).?);
    try std.testing.expect(bannerToRestore(.{ .session_id = "s" }) == null);
    try std.testing.expect(bannerToRestore(.{ .banner = "" }) == null);
    try std.testing.expect(bannerToRestore(.{ .kind = schema.kind_viewer, .banner = "stray" }) == null);
    // The round trip through the on-disk schema keeps the source byte for byte.
    const a = std.testing.allocator;
    const src = "**T3560** _restore_\n| job | state |\n|---|---:|\n| lint | `ok` |";
    const nodes = [_]schema.Node{.{ .leaf = .{ .session_id = "0123456789abcdef0123456789abcdef", .banner = bannerToRecord(src) } }};
    const tabs = [_]schema.Tab{.{ .nodes = &nodes }};
    const wins = [_]schema.Window{.{ .id = "w", .tabs = &tabs }};
    const body = try schema.serialize(a, .{ .windows = &wins });
    defer a.free(body);
    var parsed = try schema.parse(a, body);
    defer parsed.deinit();
    const leaf = parsed.value.windows[0].tabs[0].nodes[0].leaf.?;
    try std.testing.expectEqualStrings(src, bannerToRestore(leaf).?);
}

test "frameFromSize records a size and refuses none" {
    const f = frameFromSize(1024, 640).?;
    try std.testing.expectEqual(@as(i32, 1024), f.w);
    try std.testing.expectEqual(@as(i32, 640), f.h);
    try std.testing.expectEqual(@as(i32, 0), f.x);
    try std.testing.expect(frameFromSize(0, 640) == null);
    try std.testing.expect(frameFromSize(800, -1) == null);
}

test "restoreSize replays a recorded frame and drops an impossible one" {
    const s = restoreSize(.{ .x = 5, .y = 9, .w = 900, .h = 500 }).?;
    try std.testing.expectEqual(@as(i32, 900), s.w);
    try std.testing.expectEqual(@as(i32, 500), s.h);
    try std.testing.expect(restoreSize(null) == null);
    try std.testing.expect(restoreSize(.{ .x = 0, .y = 0, .w = 20, .h = 500 }) == null);
    try std.testing.expect(restoreSize(.{ .x = 0, .y = 0, .w = 900, .h = 99999 }) == null);
    // The round trip: what a capture records is what a restore replays.
    const back = restoreSize(frameFromSize(1280, 720)).?;
    try std.testing.expectEqual(@as(i32, 1280), back.w);
    try std.testing.expectEqual(@as(i32, 720), back.h);
}

test "viewerRestore keeps a viewer's id, Home and origin directory; never a session" {
    const r = viewerRestore(.{
        .kind = schema.kind_viewer,
        .session_id = "stray",
        .pane_id = "p-1",
        .working_directory = "/terminal/only",
        .viewer_location = "https://example.com/",
        .viewer_home_location = "/repo/README.md",
        .viewer_origin_directory = "/repo",
    });
    try std.testing.expectEqualStrings("p-1", r.pane_id.?);
    try std.testing.expectEqualStrings("/repo", r.working_directory.?);
    try std.testing.expectEqualStrings("/repo/README.md", r.viewer_home.?);
    const bare = viewerRestore(.{ .kind = schema.kind_viewer });
    try std.testing.expect(bare.viewer_home == null and bare.working_directory == null);
}

test "layoutPathFrom: debug, release and a lineage, under XDG_CONFIG_HOME" {
    const a = std.testing.allocator;
    const d = try layoutPathFrom(a, true, null, "/x/cfg", "/home/u");
    defer a.free(d);
    try std.testing.expectEqualStrings("/x/cfg/ghoztty/session-layout-debug.json", d);
    const r = try layoutPathFrom(a, false, null, null, "/home/u");
    defer a.free(r);
    try std.testing.expectEqualStrings("/home/u/.config/ghoztty/session-layout.json", r);
    const l = try layoutPathFrom(a, true, "t1", "", "/home/u");
    defer a.free(l);
    try std.testing.expect(std.mem.startsWith(u8, l, "/home/u/.config/ghoztty/session-layout-debug"));
    try std.testing.expect(std.mem.indexOf(u8, l, "t1") != null);
}

test "firstLeaf walks left through splits and refuses a cycle" {
    const nodes = [_]schema.Node{
        .{ .split = .{ .layout = "horizontal", .ratio = 0.5, .left = 1, .right = 2 } },
        .{ .leaf = .{ .session_id = "a" } },
        .{ .leaf = .{ .session_id = "b" } },
    };
    try std.testing.expectEqualStrings("a", firstLeaf(&nodes, 0, 0).?.session_id.?);
    try std.testing.expectEqualStrings("b", firstLeaf(&nodes, 2, 0).?.session_id.?);
    const cyc = [_]schema.Node{.{ .split = .{ .layout = "horizontal", .ratio = 0.5, .left = 0, .right = 0 } }};
    try std.testing.expect(firstLeaf(&cyc, 0, 0) == null);
    try std.testing.expect(firstLeaf(&nodes, 9, 0) == null);
}
