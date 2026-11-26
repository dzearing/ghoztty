//! What an AppImage launch must not hand to a pane's shell (T3658, Linux L14c).
//!
//! The AppImage's `AppRun` (`scripts/linux/appimage/AppRun`) points GTK, GIO,
//! gdk-pixbuf, GStreamer and WebKit at the libraries and modules bundled in
//! its read-only mount: `GIO_MODULE_DIR`, `GST_PLUGIN_SYSTEM_PATH_1_0`, a
//! prepended `XDG_DATA_DIRS`, and so on. The app needs them for as long as it
//! runs - WebKit's network process, spawned for every viewer, reads
//! `GIO_MODULE_DIR` to find its TLS module - so they cannot be dropped from
//! the app's own environment. A shell must not inherit them: a GTK program
//! run from a pane would load the AppImage's modules into the host's GLib,
//! and every path stops existing when the AppImage is unmounted.
//!
//! So `AppRun` records what it changed, and this undoes exactly that for a
//! child's environment, the way `filterSnapPaths` does for a snap:
//!
//! - `GHOZTTY_APPIMAGE_ORIG_<NAME>=<value>`: `<NAME>` held `<value>` before
//!   `AppRun` changed it (an empty value is kept as empty).
//! - `GHOZTTY_APPIMAGE_UNSET=<NAME>:<NAME>...`: names that were not set at
//!   all. It is always exported by `AppRun`, empty when there are none, and
//!   it is the marker that this process came from our `AppRun`.
//!
//! The AppImage runtime's own launch variables (`APPDIR`, `APPIMAGE`,
//! `ARGV0`, `OWD`) describe this launch, not the shell's, and go too. Nothing
//! happens without the marker, so a hand-set `APPIMAGE` is left alone.
//!
//! No GTK imports, so the none lane tests it on every seat.
const std = @import("std");

pub const marker = "GHOZTTY_APPIMAGE_UNSET";
pub const orig_prefix = "GHOZTTY_APPIMAGE_ORIG_";

/// The AppImage runtime's launch variables (type2-runtime and
/// `--appimage-extract-and-run` both set them).
pub const launch_vars = [_][]const u8{ "APPDIR", "APPIMAGE", "ARGV0", "OWD" };

/// Whether `env` came from our `AppRun`.
pub fn fromAppRun(env: *const std.process.EnvMap) bool {
    return env.get(marker) != null;
}

/// Undo `AppRun`'s changes in `env` (a child's copy of this process's
/// environment). A no-op unless `fromAppRun(env)`.
pub fn restore(gpa: std.mem.Allocator, env: *std.process.EnvMap) !void {
    const unset_list = env.get(marker) orelse return;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Collect first: the map must not change under its own iterator.
    var originals: std.ArrayList(struct { name: []const u8, value: []const u8, key: []const u8 }) = .empty;
    var it = env.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, orig_prefix)) continue;
        const name = key[orig_prefix.len..];
        if (name.len == 0) continue;
        try originals.append(arena, .{
            .name = try arena.dupe(u8, name),
            .value = try arena.dupe(u8, entry.value_ptr.*),
            .key = try arena.dupe(u8, key),
        });
    }
    const unset_names = try arena.dupe(u8, unset_list);

    for (originals.items) |o| {
        env.remove(o.key);
        try env.put(o.name, o.value);
    }
    var names = std.mem.splitScalar(u8, unset_names, ':');
    while (names.next()) |name| {
        if (name.len == 0) continue;
        // A name listed as unset AND carrying an original is malformed;
        // the original is the safer of the two to keep.
        if (hasName(originals.items, name)) continue;
        env.remove(name);
    }
    for (launch_vars) |name| env.remove(name);
    env.remove(marker);
}

fn hasName(items: anytype, name: []const u8) bool {
    for (items) |o| if (std.mem.eql(u8, o.name, name)) return true;
    return false;
}

const testing = std.testing;

fn testEnv(pairs: []const [2][]const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(testing.allocator);
    errdefer env.deinit();
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

test "appimage_env: no marker, nothing changes (a hand-set APPIMAGE stays)" {
    var env = try testEnv(&.{
        .{ "APPIMAGE", "/home/u/x.AppImage" },
        .{ "GIO_MODULE_DIR", "/opt/gio" },
        .{ "GHOZTTY_APPIMAGE_ORIG_GIO_MODULE_DIR", "/elsewhere" },
    });
    defer env.deinit();
    try testing.expect(!fromAppRun(&env));
    try restore(testing.allocator, &env);
    try testing.expectEqualStrings("/home/u/x.AppImage", env.get("APPIMAGE").?);
    try testing.expectEqualStrings("/opt/gio", env.get("GIO_MODULE_DIR").?);
    try testing.expectEqual(@as(u32, 3), env.count());
}

test "appimage_env: unset names go, originals come back, launch vars and markers go" {
    var env = try testEnv(&.{
        .{ "APPDIR", "/tmp/.mount_ghozttAbC123" },
        .{ "APPIMAGE", "/home/u/Ghoztty.AppImage" },
        .{ "ARGV0", "./Ghoztty.AppImage" },
        .{ "OWD", "/home/u/src" },
        .{ "GIO_MODULE_DIR", "/tmp/.mount_ghozttAbC123/usr/lib/gio/modules" },
        .{ "GST_REGISTRY_1_0", "/home/u/.cache/ghoztty/appimage-gstreamer-registry.bin" },
        .{ "XDG_DATA_DIRS", "/tmp/.mount_ghozttAbC123/usr/share:/usr/local/share:/usr/share" },
        .{ "GHOZTTY_APPIMAGE_ORIG_XDG_DATA_DIRS", "/usr/local/share:/usr/share" },
        .{ "GHOZTTY_APPIMAGE_UNSET", "GIO_MODULE_DIR:GST_REGISTRY_1_0" },
        .{ "HOME", "/home/u" },
        .{ "PATH", "/usr/bin:/bin" },
    });
    defer env.deinit();
    try testing.expect(fromAppRun(&env));
    try restore(testing.allocator, &env);

    try testing.expectEqualStrings("/usr/local/share:/usr/share", env.get("XDG_DATA_DIRS").?);
    try testing.expectEqualStrings("/home/u", env.get("HOME").?);
    try testing.expectEqualStrings("/usr/bin:/bin", env.get("PATH").?);
    for ([_][]const u8{
        "APPDIR",                              "APPIMAGE",       "ARGV0", "OWD",
        "GIO_MODULE_DIR",                      "GST_REGISTRY_1_0", marker,
        "GHOZTTY_APPIMAGE_ORIG_XDG_DATA_DIRS",
    }) |gone| {
        if (env.get(gone)) |v| {
            std.debug.print("{s} survived as '{s}'\n", .{ gone, v });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(@as(u32, 3), env.count());
}

test "appimage_env: an empty original is restored as empty, not removed" {
    var env = try testEnv(&.{
        .{ "GIO_MODULE_DIR", "/tmp/.mount_x/usr/lib/gio/modules" },
        .{ "GHOZTTY_APPIMAGE_ORIG_GIO_MODULE_DIR", "" },
        .{ "GHOZTTY_APPIMAGE_UNSET", "" },
    });
    defer env.deinit();
    try restore(testing.allocator, &env);
    try testing.expectEqualStrings("", env.get("GIO_MODULE_DIR").?);
    try testing.expectEqual(@as(u32, 1), env.count());
}

test "appimage_env: a user's own variable AppRun never touched is kept, whatever it holds" {
    var env = try testEnv(&.{
        .{ "LD_LIBRARY_PATH", "/opt/mine/lib" },
        .{ "GHOZTTY_APPIMAGE_UNSET", "GIO_MODULE_DIR" },
    });
    defer env.deinit();
    try restore(testing.allocator, &env);
    try testing.expectEqualStrings("/opt/mine/lib", env.get("LD_LIBRARY_PATH").?);
    try testing.expect(env.get("GIO_MODULE_DIR") == null);
}

test "appimage_env: a name both listed unset and carrying an original keeps the original" {
    var env = try testEnv(&.{
        .{ "GST_PLUGIN_SYSTEM_PATH_1_0", "/tmp/.mount_x/usr/lib/gstreamer-1.0" },
        .{ "GHOZTTY_APPIMAGE_ORIG_GST_PLUGIN_SYSTEM_PATH_1_0", "/usr/lib/x86_64-linux-gnu/gstreamer-1.0" },
        .{ "GHOZTTY_APPIMAGE_UNSET", "::GST_PLUGIN_SYSTEM_PATH_1_0:" },
    });
    defer env.deinit();
    try restore(testing.allocator, &env);
    try testing.expectEqualStrings("/usr/lib/x86_64-linux-gnu/gstreamer-1.0", env.get("GST_PLUGIN_SYSTEM_PATH_1_0").?);
    try testing.expectEqual(@as(u32, 1), env.count());
}
