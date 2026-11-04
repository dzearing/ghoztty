//! The words and decisions of Settings > Advanced's Config file section and
//! the change toast (T2676; Mac `ConfigFileSection` in
//! `SettingsCustomSections.swift` and `SettingsToast` in `SettingsView.swift`,
//! 9287de0ff). Pure, so the none-runtime lane tests every string the window
//! paints; `settings_advanced_view.zig` draws them.
const std = @import("std");
const Allocator = std.mem.Allocator;

const SettingsSources = @import("SettingsSources.zig");

/// How long the toast stays up untouched (Mac's `Task.sleep(6s)`).
pub const toast_ms: u32 = 6000;

/// The timed-out toast's exit (T2684). Mac dismisses it with `withAnimation {
/// model.dismissLastChange() }` over `.transition(.move(edge: .bottom)
/// .combined(with: .opacity))`, so it slides down off the bottom of the form
/// while it fades. That is the ONLY animated path on Mac: a write raises the
/// toast, and the x and Undo take it away, outside any `withAnimation`, so
/// SwiftUI shows and removes it instantly there - and so does Windows.
/// SwiftUI's default animation is an ease-in-out of this length.
pub const toast_leave_ms: u32 = 350;

/// One frame of the leaving toast.
pub const ToastLeave = struct {
    /// How far it has slid down, in px (0 = where it rests).
    drop: i32,
    /// Its opacity, 255 = fully shown.
    alpha: u8,
    /// The exit is over: the toast is gone.
    done: bool,
};

/// The leaving toast `elapsed_ms` into its exit, for a slide of `travel` px
/// (its height plus the gap under it, so `.move(edge: .bottom)` carries it
/// clear of the form's bottom edge).
pub fn toastLeave(elapsed_ms: u64, travel: i32) ToastLeave {
    if (elapsed_ms >= toast_leave_ms) return .{ .drop = travel, .alpha = 0, .done = true };
    const t = easeInOut(@as(f64, @floatFromInt(elapsed_ms)) / @as(f64, @floatFromInt(toast_leave_ms)));
    return .{
        .drop = @intFromFloat(@round(t * @as(f64, @floatFromInt(travel)))),
        .alpha = @intFromFloat(@round((1 - t) * 255)),
        .done = false,
    };
}

/// SwiftUI's `.easeInOut`: the cubic Bezier (0.42, 0) (0.58, 1), solved for
/// x by bisection (monotonic, so it always converges).
fn easeInOut(x: f64) f64 {
    const c = std.math.clamp(x, 0, 1);
    var lo: f64 = 0;
    var hi: f64 = 1;
    var s: f64 = c;
    for (0..32) |_| {
        s = (lo + hi) / 2;
        if (bezier(s, 0.42, 0.58) < c) lo = s else hi = s;
    }
    return bezier(s, 0, 1);
}

fn bezier(s: f64, p1: f64, p2: f64) f64 {
    const u = 1 - s;
    return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s;
}

/// The backups row's caption.
pub fn backupsNote(backed_up_this_session: bool) []const u8 {
    return if (backed_up_this_session)
        "Saved a copy before this session\u{2019}s first change."
    else
        "A copy is saved before the first change in each session (the newest 10 are kept).";
}

/// The toast's secondary text after the change message.
pub fn toastDetail(backed_up: bool) []const u8 {
    return if (backed_up) "applied live \u{00B7} backed up first" else "applied live";
}

/// What a file other than the user's own is to it, in the list under the
/// config file: an include loads after it (its keys win), any other default
/// file loads before it (the user's keys win).
pub const SourceKind = enum {
    included,
    also_loaded,

    pub fn tag(self: SourceKind) []const u8 {
        return switch (self) {
            .included => "included",
            .also_loaded => "also loaded",
        };
    }

    pub fn note(self: SourceKind) []const u8 {
        return switch (self) {
            .included => "Loaded after your config through config-file, so the keys it sets win. Settings shows those keys read-only.",
            .also_loaded => "Loaded before your config; your settings override it.",
        };
    }
};

pub fn sourceKind(s: *const SettingsSources.Source) SourceKind {
    return if (s.included) .included else .also_loaded;
}

/// The files Ghostty loads besides the user's own, in load order (Mac filters
/// out the file Settings writes and the target it links to). Caller frees the
/// slice; the entries point into `sources`.
pub fn otherSources(alloc: Allocator, sources: *const SettingsSources, main_path: []const u8, target_path: []const u8) Allocator.Error![]const *const SettingsSources.Source {
    var out: std.ArrayListUnmanaged(*const SettingsSources.Source) = .empty;
    errdefer out.deinit(alloc);
    for (sources.sources.items, 0..) |*s, i| {
        if (sources.main_index != null and sources.main_index.? == i) continue;
        if (samePath(s.path, main_path) or samePath(s.path, target_path)) continue;
        try out.append(alloc, s);
    }
    return out.toOwnedSlice(alloc);
}

/// Windows paths compare without case and with either separator.
pub fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '/') '\\' else std.ascii.toLower(x);
        const ny = if (y == '/') '\\' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// `config.ghostty.20261031-131409` -> `Oct 31, 2026 at 1:14 PM` (Mac
/// `backupLabel`: the stamp after the last dot, its first 15 characters, so a
/// same-second `-2` de-dup suffix still reads as its time). A name that does
/// not carry a stamp is shown as itself.
pub fn backupLabel(buf: []u8, path: []const u8) []const u8 {
    const name = std.fs.path.basenameWindows(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    const stamp = name[dot + 1 ..];
    if (stamp.len < 15 or stamp[8] != '-') return name;
    const num = struct {
        fn f(s: []const u8) ?u32 {
            return std.fmt.parseInt(u32, s, 10) catch null;
        }
    }.f;
    const year = num(stamp[0..4]) orelse return name;
    const month = num(stamp[4..6]) orelse return name;
    const day = num(stamp[6..8]) orelse return name;
    const hour = num(stamp[9..11]) orelse return name;
    const minute = num(stamp[11..13]) orelse return name;
    _ = num(stamp[13..15]) orelse return name;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59) return name;
    const h12 = if (hour % 12 == 0) 12 else hour % 12;
    const ampm = if (hour < 12) "AM" else "PM";
    return std.fmt.bufPrint(buf, "{s} {d}, {d} at {d}:{d:0>2} {s}", .{ months[month - 1], day, year, h12, minute, ampm }) catch name;
}

/// The Restore confirmation's body (Mac's, with Explorer for Finder).
pub fn restorePrompt(buf: []u8, label: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "Your config file will be replaced with the copy from {s}. The current file is backed up first.", .{label}) catch
        "Your config file will be replaced with the backup. The current file is backed up first.";
}

pub const restore_title = "Restore this backup?";

/// How many lines of the "Current file" disclosure are drawn before the
/// rest is summarised (Mac caps the view at 220pt and scrolls).
pub const current_file_lines = 14;

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "settings_advanced: backup labels read as a date" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Oct 31, 2026 at 1:14 PM", backupLabel(&buf, "C:\\b\\config.ghostty.20261031-131409"));
    try testing.expectEqualStrings("Jan 2, 2026 at 12:05 AM", backupLabel(&buf, "config-debug.ghostty.20260102-000507"));
    try testing.expectEqualStrings("Jul 4, 2026 at 12:00 PM", backupLabel(&buf, "config.ghostty.20260704-120000-2"));
    // Not a stamp: the name itself.
    try testing.expectEqualStrings("config.ghostty.bak", backupLabel(&buf, "D:\\x\\config.ghostty.bak"));
    try testing.expectEqualStrings("config", backupLabel(&buf, "config"));
    try testing.expectEqualStrings("c.20261331-131409", backupLabel(&buf, "c.20261331-131409"));
}

test "settings_advanced: Mac's captions" {
    try testing.expectEqualStrings("applied live \u{00B7} backed up first", toastDetail(true));
    try testing.expectEqualStrings("applied live", toastDetail(false));
    try testing.expect(std.mem.startsWith(u8, backupsNote(false), "A copy is saved before the first change"));
    try testing.expect(std.mem.startsWith(u8, backupsNote(true), "Saved a copy"));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "Your config file will be replaced with the copy from Oct 31, 2026 at 1:14 PM. The current file is backed up first.",
        restorePrompt(&buf, "Oct 31, 2026 at 1:14 PM"),
    );
    try testing.expectEqualStrings("included", SourceKind.included.tag());
    try testing.expectEqualStrings("also loaded", SourceKind.also_loaded.tag());
}

test "settings_advanced: the timed-out toast slides down and fades (T2684)" {
    // At rest at the start, fully shown.
    const start = toastLeave(0, 100);
    try testing.expectEqual(@as(i32, 0), start.drop);
    try testing.expectEqual(@as(u8, 255), start.alpha);
    try testing.expect(!start.done);
    // Halfway through an ease-in-out is halfway down and half faded.
    const mid = toastLeave(toast_leave_ms / 2, 100);
    try testing.expect(mid.drop >= 49 and mid.drop <= 51);
    try testing.expect(mid.alpha >= 126 and mid.alpha <= 129);
    // Eased: slow off the mark, so a quarter in it has gone less than a quarter.
    try testing.expect(toastLeave(toast_leave_ms / 4, 100).drop < 25);
    // Every step moves down and fades - never back.
    var prev = start;
    var ms: u64 = 0;
    while (ms <= toast_leave_ms) : (ms += 16) {
        const f = toastLeave(ms, 100);
        try testing.expect(f.drop >= prev.drop);
        try testing.expect(f.alpha <= prev.alpha);
        prev = f;
    }
    // And it lands fully gone, clear of the bottom edge.
    const end = toastLeave(toast_leave_ms, 100);
    try testing.expect(end.done);
    try testing.expectEqual(@as(i32, 100), end.drop);
    try testing.expectEqual(@as(u8, 0), end.alpha);
    try testing.expect(toastLeave(toast_leave_ms * 10, 100).done);
}

test "settings_advanced: paths compare the Windows way" {
    try testing.expect(samePath("C:\\Users\\Me\\config", "c:/users/me/CONFIG"));
    try testing.expect(!samePath("C:\\a", "C:\\b"));
    try testing.expect(!samePath("C:\\a", "C:\\ab"));
}

test "settings_advanced: other sources skip the user's own file, in load order" {
    const ConfigFileText = @import("ConfigFileText.zig");
    var sources: SettingsSources = .{ .gpa = testing.allocator };
    defer sources.deinit();
    const add = struct {
        fn f(s: *SettingsSources, path: []const u8, included: bool) !void {
            const p = try testing.allocator.dupe(u8, path);
            errdefer testing.allocator.free(p);
            var t = try ConfigFileText.init(testing.allocator, "");
            errdefer t.deinit();
            try s.sources.append(testing.allocator, .{ .path = p, .text = t, .included = included });
        }
    }.f;
    try add(&sources, "C:\\x\\ghostty\\config", false);
    try add(&sources, "C:\\x\\ghostty\\config-debug.ghostty", false);
    try add(&sources, "C:\\x\\ghostty\\later.ghostty", true);
    sources.main_index = 1;
    const others = try otherSources(testing.allocator, &sources, "C:/x/ghostty/config-debug.ghostty", "C:\\x\\ghostty\\config-debug.ghostty");
    defer testing.allocator.free(others);
    try testing.expectEqual(@as(usize, 2), others.len);
    try testing.expectEqualStrings("C:\\x\\ghostty\\config", others[0].path);
    try testing.expectEqual(SourceKind.also_loaded, sourceKind(others[0]));
    try testing.expectEqual(SourceKind.included, sourceKind(others[1]));
}
