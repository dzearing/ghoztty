//! Implementation of the XDG Base Directory specification
//! (https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const homedir = @import("homedir.zig");
const env_os = @import("env.zig");
const log = std.log.scoped(.xdg);

pub const Options = struct {
    /// Subdirectories to join to the base. This avoids extra allocations
    /// when building up the directory. This is commonly the application.
    subdir: ?[]const u8 = null,

    /// The home directory for the user. If this is not set, we will attempt
    /// to look it up which is an expensive process. By setting this, you can
    /// avoid lookups.
    home: ?[]const u8 = null,
};

/// Get the XDG user config directory. The returned value is allocated.
pub fn config(alloc: Allocator, opts: Options) ![]u8 {
    return try dir(alloc, opts, .{
        .env = "XDG_CONFIG_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".config",
    });
}

/// Get the XDG cache directory. The returned value is allocated.
pub fn cache(alloc: Allocator, opts: Options) ![]u8 {
    return try dir(alloc, opts, .{
        .env = "XDG_CACHE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".cache",
    });
}

/// Get the XDG state directory. The returned value is allocated.
pub fn state(alloc: Allocator, opts: Options) ![]u8 {
    return try dir(alloc, opts, .{
        .env = "XDG_STATE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".local/state",
    });
}

const InternalOptions = struct {
    env: []const u8,
    windows_env: []const u8,
    default_subdir: []const u8,
};

/// Unified helper to get XDG directories that follow a common pattern.
fn dir(
    alloc: Allocator,
    opts: Options,
    internal_opts: InternalOptions,
) ![]u8 {
    // If we have a cached home dir, use that.
    if (opts.home) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    // First check the env var. On Windows we have to allocate so this tracks
    // both whether we have the env var and whether we own it.
    // on Windows we treat `LOCALAPPDATA` as a fallback for `XDG_CONFIG_HOME`
    const xdg_ = try env_os.getenvNotEmpty(alloc, internal_opts.env);
    defer if (xdg_) |env| env.deinit(alloc);
    const win_ = switch (builtin.os.tag) {
        else => null,
        .windows => try env_os.getenvNotEmpty(alloc, internal_opts.windows_env),
    };
    defer if (win_) |env| env.deinit(alloc);

    const xdg_value: ?[]const u8 = if (xdg_) |env| env.value else null;
    const win_value: ?[]const u8 = if (win_) |env| env.value else null;
    if (xdg_value) |v| if (!std.fs.path.isAbsolute(v)) log.warn(
        "ignoring {s}={s}: the XDG spec requires an absolute path",
        .{ internal_opts.env, v },
    );

    if (pickBase(xdg_value, win_value)) |base| {
        // If we have a subdir, then we use the env as-is to avoid a copy.
        if (opts.subdir) |subdir| {
            return try std.fs.path.join(alloc, &[_][]const u8{
                base,
                subdir,
            });
        }

        return try alloc.dupe(u8, base);
    }

    // Get our home dir
    var buf: [1024]u8 = undefined;
    if (try homedir.home(&buf)) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    return error.NoHomeDir;
}

/// Choose the base directory from the XDG variable and (Windows only) its
/// `LOCALAPPDATA` fallback, or null to fall back to the home directory.
///
/// The XDG spec says a relative value is invalid and must be ignored, and
/// every consumer (Config.loadFile asserts it) needs an absolute path: a
/// relative `XDG_CONFIG_HOME` used to kill the app at launch (T3745). So a
/// relative value is skipped, exactly as an unset or empty one is.
fn pickBase(xdg: ?[]const u8, fallback: ?[]const u8) ?[]const u8 {
    if (xdg) |v| if (v.len > 0 and std.fs.path.isAbsolute(v)) return v;
    if (fallback) |v| if (v.len > 0 and std.fs.path.isAbsolute(v)) return v;
    return null;
}

test "pickBase: an absolute XDG value wins (T3745)" {
    const abs = if (builtin.os.tag == .windows) "C:\\xdg" else "/xdg";
    const fb = if (builtin.os.tag == .windows) "C:\\local" else "/local";
    try std.testing.expectEqualStrings(abs, pickBase(abs, fb).?);
    try std.testing.expectEqualStrings(abs, pickBase(abs, null).?);
}

test "pickBase: a relative or empty XDG value is ignored, never returned (T3745)" {
    const fb = if (builtin.os.tag == .windows) "C:\\local" else "/local";
    inline for (.{ "relative", "relative/dir", ".", "", "not-a-dir\\x" }) |bad| {
        try std.testing.expectEqualStrings(fb, pickBase(bad, fb).?);
        try std.testing.expect(pickBase(bad, null) == null);
    }
    // A relative fallback is no better than a relative XDG value.
    try std.testing.expect(pickBase("relative", "also-relative") == null);
    try std.testing.expect(pickBase(null, null) == null);
}

/// Parses the xdg-terminal-exec specification. This expects argv[0] to
/// be "xdg-terminal-exec".
pub fn parseTerminalExec(argv: []const [*:0]const u8) ?[]const [*:0]const u8 {
    if (!std.mem.eql(
        u8,
        std.fs.path.basename(std.mem.sliceTo(argv[0], 0)),
        "xdg-terminal-exec",
    )) return null;

    // We expect at least one argument
    if (argv.len < 2) return &.{};

    // If the first argument is "-e" we skip it.
    const start: usize = if (std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "-e")) 2 else 1;
    return argv[start..];
}

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        const value = try config(alloc, .{});
        defer alloc.free(value);
        try testing.expect(value.len > 0);
    }
}

test "cache directory paths" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const mock_home = if (builtin.os.tag == .windows) "C:\\Users\\test" else "/Users/test";

    // Test when XDG_CACHE_HOME is not set
    {
        // Test base path
        {
            const cache_path = try cache(alloc, .{ .home = mock_home });
            defer alloc.free(cache_path);
            const expected = try std.fs.path.join(alloc, &.{ mock_home, ".cache" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }

        // Test with subdir
        {
            const cache_path = try cache(alloc, .{
                .home = mock_home,
                .subdir = "ghostty",
            });
            defer alloc.free(cache_path);
            const expected = try std.fs.path.join(alloc, &.{ mock_home, ".cache", "ghostty" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }
    }
}

test "fallback when xdg env empty" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    const saved_home = home: {
        const home = std.posix.getenv("HOME") orelse break :home null;
        break :home try alloc.dupeZ(u8, home);
    };
    defer env: {
        const home = saved_home orelse {
            _ = env_os.unsetenv("HOME");
            break :env;
        };
        _ = env_os.setenv("HOME", home);
        std.testing.allocator.free(home);
    }
    const temp_home = "/tmp/ghostty-test-home";
    _ = env_os.setenv("HOME", temp_home);

    const DirCase = struct {
        name: [:0]const u8,
        func: fn (Allocator, Options) anyerror![]u8,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };

    inline for (cases) |case| {
        // Save and restore each environment variable
        const saved_env = blk: {
            const value = std.posix.getenv(case.name) orelse break :blk null;
            break :blk try alloc.dupeZ(u8, value);
        };
        defer env: {
            const value = saved_env orelse {
                _ = env_os.unsetenv(case.name);
                break :env;
            };
            _ = env_os.setenv(case.name, value);
            alloc.free(value);
        }

        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        _ = env_os.setenv(case.name, "");
        const actual = try case.func(alloc, .{});
        defer alloc.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "fallback when xdg env empty and subdir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const env = @import("env.zig");
    const alloc = std.testing.allocator;

    const saved_home = home: {
        const home = std.posix.getenv("HOME") orelse break :home null;
        break :home try alloc.dupeZ(u8, home);
    };
    defer env: {
        const home = saved_home orelse {
            _ = env.unsetenv("HOME");
            break :env;
        };
        _ = env.setenv("HOME", home);
        std.testing.allocator.free(home);
    }

    const temp_home = "/tmp/ghostty-test-home";
    _ = env.setenv("HOME", temp_home);

    const DirCase = struct {
        name: [:0]const u8,
        func: fn (Allocator, Options) anyerror![]u8,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };

    inline for (cases) |case| {
        // Save and restore each environment variable
        const saved_env = blk: {
            const value = std.posix.getenv(case.name) orelse break :blk null;
            break :blk try alloc.dupeZ(u8, value);
        };
        defer env: {
            const value = saved_env orelse {
                _ = env.unsetenv(case.name);
                break :env;
            };
            _ = env.setenv(case.name, value);
            alloc.free(value);
        }

        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
            "ghostty",
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        _ = env.setenv(case.name, "");
        const actual = try case.func(alloc, .{ .subdir = "ghostty" });
        defer alloc.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "fallback when xdg env relative (T3745)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    const saved_home = home: {
        const home = std.posix.getenv("HOME") orelse break :home null;
        break :home try alloc.dupeZ(u8, home);
    };
    defer env: {
        const home = saved_home orelse {
            _ = env_os.unsetenv("HOME");
            break :env;
        };
        _ = env_os.setenv("HOME", home);
        alloc.free(home);
    }
    const temp_home = "/tmp/ghostty-test-home";
    _ = env_os.setenv("HOME", temp_home);

    const saved_xdg = blk: {
        const value = std.posix.getenv("XDG_CONFIG_HOME") orelse break :blk null;
        break :blk try alloc.dupeZ(u8, value);
    };
    defer env: {
        const value = saved_xdg orelse {
            _ = env_os.unsetenv("XDG_CONFIG_HOME");
            break :env;
        };
        _ = env_os.setenv("XDG_CONFIG_HOME", value);
        alloc.free(value);
    }

    _ = env_os.setenv("XDG_CONFIG_HOME", "relative/config");
    const actual = try config(alloc, .{ .subdir = "ghostty" });
    defer alloc.free(actual);
    try std.testing.expectEqualStrings("/tmp/ghostty-test-home/.config/ghostty", actual);
    try std.testing.expect(std.fs.path.isAbsolute(actual));
}

test parseTerminalExec {
    const testing = std.testing;

    {
        const actual = parseTerminalExec(&.{ "a", "b", "c" });
        try testing.expect(actual == null);
    }
    {
        const actual = parseTerminalExec(&.{"xdg-terminal-exec"}).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{});
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "a", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "b", "c" });
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "-e", "a", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "b", "c" });
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "a", "-e", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "-e", "b", "c" });
    }
}
