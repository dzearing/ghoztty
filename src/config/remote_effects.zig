//! The visual effects a remote session turns off (T1951).
//!
//! Over Remote Desktop (and, for the Mac seat, Screen Sharing) every pixel
//! Ghoztty changes is drawn in software and sent over the wire. The glass
//! panes, the blur, the blinking cursor and the dimmed unfocused panes are the
//! most expensive pixels there and the least needed, so while the session is
//! remote the apprt loads its config through `apply`, which swaps the DEFAULTS
//! of those keys for the cheap values.
//!
//! A key the user set explicitly is left alone: someone who writes
//! `macos-pane-glass = true` wants glass over Remote Desktop too. "Set" is read
//! from the config's own replay steps, so it means "the file or the command
//! line named this key", not "the value happens to differ from the default" -
//! an explicit `macos-pane-glass = true` equals the default and still counts.
//!
//! The overrides are recorded as replay steps as well as written to the
//! fields, so a `changeConditionalState` rebuild (a light/dark flip replays the
//! steps from scratch) keeps them instead of quietly restoring the effects.
//! Going back to the console is a fresh `Config.load` with `remote = false`,
//! which never had them.
//!
//! Pure: no OS calls. The apprt decides whether the session is remote.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");

pub const Override = struct {
    /// The config key, as written in the file.
    key: []const u8,
    /// The cheap value, as a replay argument.
    arg: []const u8,
};

/// What a remote session turns off. Order is the order they are logged in.
pub const overrides = [_]Override{
    .{ .key = "macos-pane-style", .arg = "--macos-pane-style=flat" },
    .{ .key = "macos-pane-glass", .arg = "--macos-pane-glass=false" },
    .{ .key = "background-blur", .arg = "--background-blur=false" },
    .{ .key = "cursor-style-blink", .arg = "--cursor-style-blink=false" },
    .{ .key = "unfocused-split-opacity", .arg = "--unfocused-split-opacity=1" },
};

/// Which overrides `apply` actually made, by index into `overrides`.
pub const Applied = std.StaticBitSet(overrides.len);

/// Did the file or the command line name `key`? The LAST mention decides, and
/// an empty value (`key =`) is the documented reset to the default, so it does
/// not count as set. Arguments after `-e` are the command, not config.
pub fn keyWasSet(config: *const Config, key: []const u8) bool {
    var set = false;
    for (config._replay_steps.items) |step| {
        const arg: []const u8 = switch (step) {
            .arg => |a| a,
            .conditional_arg => |c| c.arg,
            .@"-e" => break,
            else => continue,
        };
        if (argValue(arg, key)) |value| set = value.len > 0;
    }
    return set;
}

/// The value `arg` gives `key`, or null when it names some other key. A bare
/// `--key` (a boolean switched on) reads as the value "true".
fn argValue(arg: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const rest = arg[2..];
    if (!std.mem.startsWith(u8, rest, key)) return null;
    const tail = rest[key.len..];
    if (tail.len == 0) return "true";
    if (tail[0] != '=') return null;
    return tail[1..];
}

/// Should the override at `index` replace what the config holds?
pub fn shouldOverride(config: *const Config, index: usize) bool {
    const o = overrides[index];
    if (keyWasSet(config, o.key)) return false;
    // Glass only exists in the elevated style, so a user who asked for glass
    // by name keeps the style it needs as well.
    if (std.mem.eql(u8, o.key, "macos-pane-style") and
        keyWasSet(config, "macos-pane-glass") and
        config.@"macos-pane-glass") return false;
    return true;
}

/// Swap the remote-session defaults into `config` when `remote` is set.
/// Returns which overrides were made (empty on the console). The config must
/// not be finalized again afterwards with expectations about these keys; the
/// values written are all already in range.
pub fn apply(alloc_gpa: Allocator, config: *Config, remote: bool) !Applied {
    var applied: Applied = .initEmpty();
    if (!remote) return applied;

    var args: [overrides.len][]const u8 = undefined;
    var n: usize = 0;
    for (0..overrides.len) |i| {
        if (!shouldOverride(config, i)) continue;
        args[n] = overrides[i].arg;
        n += 1;
        applied.set(i);
    }
    if (n == 0) return applied;

    const start = config._replay_steps.items.len;
    var it: SliceIterator = .{ .args = args[0..n] };
    try config.loadIter(alloc_gpa, &it);

    // loadIter appended the steps; a replay reads everything after `-e` as
    // the command, so move them ahead of it.
    const steps = config._replay_steps.items;
    for (steps[0..start], 0..) |step, i| if (step == .@"-e") {
        std.mem.rotate(@TypeOf(step), steps[i..], start - i);
        break;
    };
    return applied;
}

const SliceIterator = struct {
    args: []const []const u8,
    i: usize = 0,

    pub fn next(self: *SliceIterator) ?[]const u8 {
        if (self.i >= self.args.len) return null;
        defer self.i += 1;
        return self.args[self.i];
    }
};

/// Writes the keys `applied` names, comma separated, for the log line.
pub fn formatApplied(applied: Applied, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var first = true;
    for (0..overrides.len) |i| if (applied.isSet(i)) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll(overrides[i].key);
        first = false;
    };
    if (first) try writer.writeAll("none");
}

const testing = std.testing;

fn testConfig(args: []const []const u8) !Config {
    var cfg = try Config.default(testing.allocator);
    errdefer cfg.deinit();
    var it: SliceIterator = .{ .args = args };
    try cfg.loadIter(testing.allocator, &it);
    try cfg.finalize();
    return cfg;
}

test "remote_effects: the console keeps every effect" {
    var cfg = try testConfig(&.{});
    defer cfg.deinit();
    const applied = try apply(testing.allocator, &cfg, false);
    try testing.expectEqual(@as(usize, 0), applied.count());
    try testing.expectEqual(Config.MacPaneStyle.elevated, cfg.@"macos-pane-style");
    try testing.expect(cfg.@"macos-pane-glass");
    try testing.expect(cfg.@"cursor-style-blink" == null);
    try testing.expectApproxEqAbs(@as(f64, 0.7), cfg.@"unfocused-split-opacity", 1e-9);
}

test "remote_effects: a remote session turns the defaults off" {
    var cfg = try testConfig(&.{});
    defer cfg.deinit();
    const applied = try apply(testing.allocator, &cfg, true);
    try testing.expectEqual(overrides.len, applied.count());
    try testing.expectEqual(Config.MacPaneStyle.flat, cfg.@"macos-pane-style");
    try testing.expect(!cfg.@"macos-pane-glass");
    try testing.expect(!cfg.@"background-blur".enabled());
    try testing.expectEqual(@as(?bool, false), cfg.@"cursor-style-blink");
    try testing.expectApproxEqAbs(@as(f64, 1), cfg.@"unfocused-split-opacity", 1e-9);
}

test "remote_effects: a value the user set wins, even when it equals the default" {
    var cfg = try testConfig(&.{
        "--macos-pane-glass=true",
        "--unfocused-split-opacity=0.5",
        "--cursor-style-blink",
    });
    defer cfg.deinit();
    const applied = try apply(testing.allocator, &cfg, true);
    // Glass asked for by name keeps glass AND the elevated style it needs.
    try testing.expect(cfg.@"macos-pane-glass");
    try testing.expectEqual(Config.MacPaneStyle.elevated, cfg.@"macos-pane-style");
    try testing.expectApproxEqAbs(@as(f64, 0.5), cfg.@"unfocused-split-opacity", 1e-9);
    try testing.expectEqual(@as(?bool, true), cfg.@"cursor-style-blink");
    // Only blur was left to swap.
    try testing.expectEqual(@as(usize, 1), applied.count());
    try testing.expect(applied.isSet(2));
}

test "remote_effects: glass explicitly OFF still lets the style go flat" {
    var cfg = try testConfig(&.{"--macos-pane-glass=false"});
    defer cfg.deinit();
    _ = try apply(testing.allocator, &cfg, true);
    try testing.expectEqual(Config.MacPaneStyle.flat, cfg.@"macos-pane-style");
}

test "remote_effects: an empty value is a reset, not a setting" {
    var cfg = try testConfig(&.{ "--macos-pane-style=elevated", "--macos-pane-style=" });
    defer cfg.deinit();
    try testing.expect(!keyWasSet(&cfg, "macos-pane-style"));
    // A key that merely shares a prefix is a different key.
    try testing.expect(!keyWasSet(&cfg, "macos-pane"));
    _ = try apply(testing.allocator, &cfg, true);
    try testing.expectEqual(Config.MacPaneStyle.flat, cfg.@"macos-pane-style");
}

test "remote_effects: a light/dark rebuild keeps the remote values" {
    var cfg = try testConfig(&.{"--theme=light:foo,dark:bar"});
    defer cfg.deinit();
    _ = try apply(testing.allocator, &cfg, true);
    var rebuilt = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
    defer rebuilt.deinit();
    try testing.expectEqual(Config.MacPaneStyle.flat, rebuilt.@"macos-pane-style");
    try testing.expectApproxEqAbs(@as(f64, 1), rebuilt.@"unfocused-split-opacity", 1e-9);
}

test "remote_effects: the overrides land ahead of -e, never in the command" {
    var cfg = try testConfig(&.{ "-e", "nvim", "foo" });
    defer cfg.deinit();
    _ = try apply(testing.allocator, &cfg, true);
    var e_at: ?usize = null;
    for (cfg._replay_steps.items, 0..) |step, i| switch (step) {
        .@"-e" => e_at = i,
        .arg => |a| if (std.mem.startsWith(u8, a, "--macos-pane-style")) {
            try testing.expect(e_at == null);
        },
        else => {},
    };
    try testing.expect(e_at != null);
    // The command after -e is exactly what the user typed.
    const tail = cfg._replay_steps.items[e_at.? + 1 ..];
    try testing.expectEqual(@as(usize, 2), tail.len);
    try testing.expectEqualStrings("nvim", tail[0].arg);
}

test "remote_effects: a second apply is a no-op" {
    var cfg = try testConfig(&.{});
    defer cfg.deinit();
    _ = try apply(testing.allocator, &cfg, true);
    const again = try apply(testing.allocator, &cfg, true);
    try testing.expectEqual(@as(usize, 0), again.count());
}

test "remote_effects: formatApplied names the keys" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var a: Applied = .initEmpty();
    try formatApplied(a, &w);
    try testing.expectEqualStrings("none", w.buffered());
    w.end = 0;
    a.set(0);
    a.set(4);
    try formatApplied(a, &w);
    try testing.expectEqualStrings("macos-pane-style,unfocused-split-opacity", w.buffered());
}
