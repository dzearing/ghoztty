const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const build_config = @import("../build_config.zig");

const log = std.log.scoped(.config);

/// Default path for the XDG home configuration file. Returned value
/// must be freed by the caller.
pub fn defaultXdgPath(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        .{ .subdir = "ghostty/config.ghostty" },
    );
}

/// Ghostty <1.3.0 default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn legacyDefaultXdgPath(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        .{ .subdir = "ghostty/config" },
    );
}

/// Preferred default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn preferredXdgPath(alloc: Allocator) ![]const u8 {
    // If the XDG path exists, use that.
    const xdg_path = try defaultXdgPath(alloc);
    if (open(xdg_path)) |f| {
        f.close();
        return xdg_path;
    } else |_| {}

    // Try the legacy path
    errdefer alloc.free(xdg_path);
    const legacy_xdg_path = try legacyDefaultXdgPath(alloc);
    if (open(legacy_xdg_path)) |f| {
        f.close();
        alloc.free(xdg_path);
        return legacy_xdg_path;
    } else |_| {}

    // Legacy path and XDG path both don't exist. Return the
    // new one.
    alloc.free(legacy_xdg_path);
    return xdg_path;
}

/// The Windows development build's own configuration file, beside the
/// shared XDG file: `<LOCALAPPDATA>\ghostty\config-debug.ghostty`. It is
/// the Windows counterpart of the macOS `<bundle_id>.debug` folder (see
/// `build_config.config_bundle_id`), named the way the other per-build
/// Windows files are (`pane_sidebar-debug`, the `-debug` pipe). The dev
/// build loads it after the shared file and writes only to it, so testing
/// never rewrites the installed release's config. Returned value must be
/// freed by the caller.
pub fn devXdgPath(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        .{ .subdir = "ghostty/config-debug.ghostty" },
    );
}

/// True when this build keeps its own config file apart from the shared
/// XDG one (a Windows development build). macOS does the same through
/// its Application Support folder instead.
pub const uses_dev_xdg_path = builtin.os.tag == .windows and build_config.is_dev_build;

/// Default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn defaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.configDir(alloc, "config.ghostty");
}

/// Ghostty <1.3.0 default path for the macOS Application Support
/// configuration file. Returned value must be freed by the caller.
pub fn legacyDefaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.configDir(alloc, "config");
}

/// Preferred default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn preferredAppSupportPath(alloc: Allocator) ![]const u8 {
    // If the app support path exists, use that.
    const app_support_path = try defaultAppSupportPath(alloc);
    if (open(app_support_path)) |f| {
        f.close();
        return app_support_path;
    } else |_| {}

    // Try the legacy path
    errdefer alloc.free(app_support_path);
    const legacy_app_support_path = try legacyDefaultAppSupportPath(alloc);
    if (open(legacy_app_support_path)) |f| {
        f.close();
        alloc.free(app_support_path);
        return legacy_app_support_path;
    } else |_| {}

    // Legacy path and app support path both don't exist. Return the
    // new one.
    alloc.free(legacy_app_support_path);
    return app_support_path;
}

/// Returns the path to the preferred default configuration file.
/// This is the file where users should place their configuration.
///
/// This doesn't create or populate the file with any default
/// contents; downstream callers must handle this.
///
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            // A development build writes only its own Application Support
            // file, never the XDG file it shares with the release app.
            if (comptime build_config.is_dev_build) return try preferredAppSupportPath(alloc);

            // macOS prefers the Application Support directory
            // if it exists.
            const app_support_path = try preferredAppSupportPath(alloc);
            const app_support_file = open(app_support_path) catch {
                // Try the XDG path if it exists
                const xdg_path = try preferredXdgPath(alloc);
                const xdg_file = open(xdg_path) catch {
                    // If neither file exists, use app support
                    alloc.free(xdg_path);
                    return app_support_path;
                };
                xdg_file.close();
                alloc.free(app_support_path);
                return xdg_path;
            };
            app_support_file.close();
            return app_support_path;
        },

        // All other platforms use XDG only. A Windows development build
        // writes only its own file, never the one the release shares.
        else => {
            if (comptime uses_dev_xdg_path) return try devXdgPath(alloc);
            return try preferredXdgPath(alloc);
        },
    }
}

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given path and returns the file handle
/// if it exists and is non-empty. This also constrains the possible
/// errors to a smaller set that we can explicitly handle.
pub fn open(path: []const u8) OpenFileError!std.fs.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.fs.openFileAbsolute(
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close();

    const stat = file.stat() catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }

    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}

test "a development build keeps its config apart from the release app's" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    // Tests build in Debug, so this is the dev-build path.
    try testing.expect(build_config.is_dev_build);
    const app_support = try defaultAppSupportPath(alloc);
    defer alloc.free(app_support);
    try testing.expect(std.mem.endsWith(u8, app_support, "/" ++ build_config.bundle_id ++ ".debug/config.ghostty"));

    const preferred = try preferredDefaultFilePath(alloc);
    defer alloc.free(preferred);
    try testing.expect(std.mem.indexOf(u8, preferred, build_config.bundle_id ++ ".debug/") != null);
}

test "a Windows development build writes its own config file, never the shared one" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    // Tests build in Debug, so this is the dev-build path.
    try testing.expect(build_config.is_dev_build);
    try testing.expect(uses_dev_xdg_path);

    const dev = try devXdgPath(alloc);
    defer alloc.free(dev);
    const shared = try defaultXdgPath(alloc);
    defer alloc.free(shared);

    // The dev file sits in the same folder as the shared one.
    const dev_name = "config-debug.ghostty";
    const shared_name = "config.ghostty";
    try testing.expect(std.mem.endsWith(u8, dev, dev_name));
    try testing.expect(std.mem.endsWith(u8, shared, shared_name));
    try testing.expectEqualStrings(
        shared[0 .. shared.len - shared_name.len],
        dev[0 .. dev.len - dev_name.len],
    );

    // The preferred (written) path is the dev file whether or not the
    // shared file exists, so it can never resolve to the release's.
    const preferred = try preferredDefaultFilePath(alloc);
    defer alloc.free(preferred);
    try testing.expectEqualStrings(dev, preferred);
    try testing.expect(!std.mem.eql(u8, shared, preferred));
    const legacy = try legacyDefaultXdgPath(alloc);
    defer alloc.free(legacy);
    try testing.expect(!std.mem.eql(u8, legacy, preferred));
}
