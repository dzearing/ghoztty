//! The value logic behind the Settings window's curated controls (T2681) -
//! the win32 port of the pure halves of Mac `SettingsRowView.swift`'s
//! `SliderControl`, `NumberControl`, `MegabytesControl`, `ColorControl`,
//! `FlagsControl`, `ShellControl` and `FolderControl`.
//!
//! Everything here turns a control gesture into the value TEXT the config
//! parser accepts, or a value into what the control shows. Drawing and the
//! dialogs live in `SettingsWindow.zig`; the write itself always goes through
//! `SettingsModel`, which validates it with Ghostty's own parser.
const std = @import("std");

// ---------------------------------------------------------------------
// Slider (Mac `SliderControl`)
// ---------------------------------------------------------------------

/// `value` clamped to [min, max] and snapped to the nearest `step` from
/// `min` (SwiftUI's `Slider(in:step:)`).
pub fn snap(value: f64, min: f64, max: f64, step: f64) f64 {
    const v = std.math.clamp(value, min, max);
    if (step <= 0) return v;
    const n = @round((v - min) / step);
    return std.math.clamp(min + n * step, min, max);
}

/// Where `value` sits on the track, 0..1.
pub fn fraction(value: f64, min: f64, max: f64) f64 {
    if (max <= min) return 0;
    return std.math.clamp((value - min) / (max - min), 0, 1);
}

/// The snapped value at track position `frac` (0..1).
pub fn valueAt(frac: f64, min: f64, max: f64, step: f64) f64 {
    return snap(min + std.math.clamp(frac, 0, 1) * (max - min), min, max, step);
}

/// Mac `SliderControl.format`: three decimals, trailing zeros and point
/// trimmed (`0.7`, `0.15`, `1`). This is the text that is written.
pub fn formatValue(buf: []u8, value: f64) []const u8 {
    const text = std.fmt.bufPrint(buf, "{d:.3}", .{value}) catch return "";
    return trimZeros(text);
}

/// The slider's readout: `70%`, or with `inverted` (Dim unfocused panes,
/// where the key is the opacity a pane KEEPS) `30%`; a non-percent slider
/// shows its value.
pub fn sliderLabel(buf: []u8, value: f64, percent: bool, inverted: bool) []const u8 {
    if (!percent) return formatValue(buf, value);
    const shown = if (inverted) 1 - value else value;
    const pct: i64 = @intFromFloat(@round(shown * 100));
    return std.fmt.bufPrint(buf, "{d}%", .{pct}) catch "";
}

/// The slider's current value from its key's text, else `min` (Mac reads
/// `Double(value) ?? range.lowerBound`).
pub fn parseOr(text: []const u8, fallback: f64) f64 {
    return std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t")) catch fallback;
}

// ---------------------------------------------------------------------
// Stepper (Mac `NumberControl`)
// ---------------------------------------------------------------------

/// Mac `NumberControl.format`: a whole number without a point, else the
/// number as written (`13`, `13.5`).
pub fn formatNumber(buf: []u8, value: f64) []const u8 {
    if (value == @round(value) and @abs(value) < 1e15) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(value))}) catch "";
    }
    const text = std.fmt.bufPrint(buf, "{d:.6}", .{value}) catch return "";
    return trimZeros(text);
}

/// One click of the stepper's arrow: `dir` +1 or -1, clamped.
pub fn stepBy(current: f64, dir: i32, min: f64, max: f64, step: f64) f64 {
    return std.math.clamp(current + @as(f64, @floatFromInt(dir)) * step, min, max);
}

/// A typed number inside [min, max], or null (Mac shows "Enter a number
/// from MIN to MAX" and writes nothing).
pub fn parseInRange(text: []const u8, min: f64, max: f64) ?f64 {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t")) catch return null;
    if (std.math.isNan(v) or v < min or v > max) return null;
    return v;
}

/// Mac's inline problem for an out-of-range stepper entry.
pub fn rangeProblem(buf: []u8, min: f64, max: f64) []const u8 {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "Enter a number from {s} to {s}", .{ formatNumber(&a, min), formatNumber(&b, max) }) catch "Enter a number in range";
}

// ---------------------------------------------------------------------
// Megabytes (Mac `MegabytesControl`)
// ---------------------------------------------------------------------

pub const megabyte: f64 = 1_000_000;

/// The MB a byte count reads as (`10000000` -> `10`, `2500000` -> `2.5`);
/// two decimals at most, as Mac's `NumberControlFormat.trim`.
pub fn bytesAsMegabytes(buf: []u8, bytes_text: []const u8) []const u8 {
    const bytes = parseOr(bytes_text, 0);
    const text = std.fmt.bufPrint(buf, "{d:.2}", .{bytes / megabyte}) catch return "";
    return trimZeros(text);
}

/// Typed megabytes as the byte count to write, or null when it is not a
/// number in 0..max (Mac: "Enter a size in megabytes, 0 to MAX").
pub fn megabytesToBytes(text: []const u8, max: f64) ?u64 {
    const mb = parseInRange(text, 0, max) orelse return null;
    return @intFromFloat(@round(mb * megabyte));
}

pub fn megabytesProblem(buf: []u8, max: f64) []const u8 {
    return std.fmt.bufPrint(buf, "Enter a size in megabytes, 0 to {d}", .{@as(i64, @intFromFloat(max))}) catch "Enter a size in megabytes";
}

/// Mac's unit caption beside the field.
pub const megabytes_unit = "MB per pane";

// ---------------------------------------------------------------------
// Color (Mac `ColorControl`)
// ---------------------------------------------------------------------

/// `#rrggbb` / `rrggbb` as 0xRRGGBB, or null (unset, a named color, or the
/// `cell-foreground` / `cell-background` words - Mac's `NSColor(hex:)`).
pub fn parseHex(text: []const u8) ?u32 {
    var t = std.mem.trim(u8, text, " \t");
    if (t.len > 0 and t[0] == '#') t = t[1..];
    if (t.len != 6) return null;
    return std.fmt.parseInt(u32, t, 16) catch null;
}

/// 0xRRGGBB as the `#rrggbb` that is written (Mac `hexString`).
pub fn formatHex(buf: *[7]u8, rgb: u32) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>6}", .{rgb & 0xFFFFFF}) catch unreachable;
}

/// COLORREF (0x00BBGGRR, what ChooseColorW speaks) <-> 0xRRGGBB.
pub fn toColorref(rgb: u32) u32 {
    return ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);
}
pub const fromColorref = toColorref;

// ---------------------------------------------------------------------
// Flags (Mac `FlagsControl`)
// ---------------------------------------------------------------------

/// Whether `flag` is on in a packed-flags value (`cursor,no-sudo,title`);
/// null when the value does not name it.
pub fn flagState(value: []const u8, flag: []const u8) ?bool {
    var result: ?bool = null;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;
        if (std.mem.startsWith(u8, part, "no-")) {
            if (std.mem.eql(u8, part[3..], flag)) result = false;
        } else if (std.mem.eql(u8, part, flag)) result = true;
    }
    return result;
}

/// The value with `flag` set to `on` and EVERY schema flag written
/// explicitly, in schema order (Mac writes `options.map { (on ? "" : "no-")
/// + $0 }.joined(",")`). A flag the value does not name is written off, as
/// Mac's `set[flag] ?? false`.
pub fn composeFlags(alloc: std.mem.Allocator, options: []const []const u8, value: []const u8, flag: []const u8, on: bool) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (options, 0..) |o, i| {
        if (i > 0) try out.append(alloc, ',');
        const state = if (std.mem.eql(u8, o, flag)) on else (flagState(value, o) orelse false);
        if (!state) try out.appendSlice(alloc, "no-");
        try out.appendSlice(alloc, o);
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------
// Shell (Mac `ShellControl`)
// ---------------------------------------------------------------------

/// The Windows shells offered when found (Mac lists zsh, bash, fish, nu):
/// the program name a `command` line takes, and how the menu shows it.
pub const CommonShell = struct { program: []const u8, label: []const u8 };
pub const common_shells = [_]CommonShell{
    .{ .program = "pwsh.exe", .label = "PowerShell 7 (pwsh.exe)" },
    .{ .program = "powershell.exe", .label = "Windows PowerShell (powershell.exe)" },
    .{ .program = "cmd.exe", .label = "Command Prompt (cmd.exe)" },
    .{ .program = "wsl.exe", .label = "WSL (wsl.exe)" },
};

/// The "unset" entry: what runs when the key is not in the file. On Windows
/// `command` falls back to cmd.exe (Config.finalize) and `command-shell`
/// to the `--shell` flag, then cmd.exe (IpcHandlers).
pub fn shellDefaultLabel(scripted: bool) []const u8 {
    return if (scripted) "The --shell flag, else cmd.exe" else "Default shell (cmd.exe)";
}

pub const other_shell_label = "Other\u{2026}";

/// The program word of a command line: the first word, or a leading
/// "quoted path".
pub fn programOf(command: []const u8) []const u8 {
    const t = std.mem.trim(u8, command, " \t");
    if (t.len == 0) return t;
    if (t[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, t, 1, '"') orelse t.len;
        return t[1..end];
    }
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    return t[0..end];
}

/// Mac `ShellControl.problem`, for Windows: null when the command's program
/// exists - an absolute path, or a name found on `path_env` (`;`-separated)
/// as written or with one of `pathext` (`.EXE;.CMD;...`). `exists` answers
/// "is this a file".
pub fn shellProblem(
    buf: []u8,
    command: []const u8,
    path_env: []const u8,
    pathext: []const u8,
    ctx: anytype,
    comptime exists: fn (@TypeOf(ctx), []const u8) bool,
) ?[]const u8 {
    const program = programOf(command);
    if (program.len == 0) return "Enter a shell.";
    if (isAbsolute(program)) {
        if (exists(ctx, program) or hasExtMatch(program, pathext, ctx, exists)) return null;
        return std.fmt.bufPrint(buf, "{s} isn't an executable file.", .{program}) catch "That isn't an executable file.";
    }
    if (std.mem.indexOfAny(u8, program, "\\/") == null) {
        var dirs = std.mem.splitScalar(u8, path_env, ';');
        var join: [std.fs.max_path_bytes]u8 = undefined;
        while (dirs.next()) |raw| {
            const dir = std.mem.trim(u8, std.mem.trim(u8, raw, " "), "\"");
            if (dir.len == 0) continue;
            const sep: []const u8 = if (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/') "" else "\\";
            const full = std.fmt.bufPrint(&join, "{s}{s}{s}", .{ dir, sep, program }) catch continue;
            if (exists(ctx, full) or hasExtMatch(full, pathext, ctx, exists)) return null;
        }
    }
    return std.fmt.bufPrint(buf, "{s} isn't on your PATH.", .{program}) catch "That isn't on your PATH.";
}

fn hasExtMatch(base: []const u8, pathext: []const u8, ctx: anytype, comptime exists: fn (@TypeOf(ctx), []const u8) bool) bool {
    // A name that already carries an extension is only tried as written.
    if (std.mem.lastIndexOfScalar(u8, std.fs.path.basenameWindows(base), '.') != null) return false;
    var exts = std.mem.splitScalar(u8, pathext, ';');
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (exts.next()) |e| {
        if (e.len == 0) continue;
        const full = std.fmt.bufPrint(&buf, "{s}{s}", .{ base, e }) catch continue;
        if (exists(ctx, full)) return true;
    }
    return false;
}

fn isAbsolute(p: []const u8) bool {
    if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) return true;
    return std.mem.startsWith(u8, p, "\\\\");
}

// ---------------------------------------------------------------------
// Folder (Mac `FolderControl`)
// ---------------------------------------------------------------------

pub const folder_home_label = "Home folder";
pub const folder_inherit_label = "Where Ghoztty was launched";
pub const folder_choose_label = "Choose Folder\u{2026}";

/// What the folder popup shows for the key's file value ("" when unset):
/// unset and `home` read as the home folder, `inherit` as where Ghoztty was
/// launched, anything else as the path with the profile folder as `~`.
pub fn folderLabel(buf: []u8, value: []const u8, home: []const u8) []const u8 {
    const v = std.mem.trim(u8, value, " \t\"");
    if (v.len == 0 or std.mem.eql(u8, v, "home")) return folder_home_label;
    if (std.mem.eql(u8, v, "inherit")) return folder_inherit_label;
    if (home.len > 0 and v.len >= home.len and std.ascii.eqlIgnoreCase(v[0..home.len], home) and
        (v.len == home.len or v[home.len] == '\\' or v[home.len] == '/'))
    {
        return std.fmt.bufPrint(buf, "~{s}", .{v[home.len..]}) catch v;
    }
    return v;
}

// ---------------------------------------------------------------------

fn trimZeros(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
    var t = text;
    while (t.len > 0 and t[t.len - 1] == '0') t = t[0 .. t.len - 1];
    if (t.len > 0 and t[t.len - 1] == '.') t = t[0 .. t.len - 1];
    if (std.mem.eql(u8, t, "-0")) return "0";
    return t;
}

const testing = std.testing;

test "settings_controls: slider snaps, formats and reads inverted" {
    try testing.expectApproxEqAbs(@as(f64, 0.7), snap(0.71, 0.15, 1, 0.05), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.15), snap(-3, 0.15, 1, 0.05), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), snap(4, 0.15, 1, 0.05), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), fraction(0.575, 0.15, 1), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.35), valueAt(0.5, 0.1, 0.6, 0.05), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.6), valueAt(2, 0.1, 0.6, 0.05), 1e-9);
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("0.7", formatValue(&b, 0.7000000001));
    try testing.expectEqualStrings("0.15", formatValue(&b, 0.15));
    try testing.expectEqualStrings("1", formatValue(&b, 1));
    try testing.expectEqualStrings("0", formatValue(&b, 0));
    // Dim unfocused panes: the key keeps 0.7 of the pane, Mac reads 30%.
    try testing.expectEqualStrings("30%", sliderLabel(&b, 0.7, true, true));
    try testing.expectEqualStrings("70%", sliderLabel(&b, 0.7, true, false));
    try testing.expectEqualStrings("0.25", sliderLabel(&b, 0.25, false, false));
    try testing.expectApproxEqAbs(@as(f64, 0.15), parseOr("nope", 0.15), 1e-9);
}

test "settings_controls: stepper formats, steps and range-checks" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("13", formatNumber(&b, 13));
    try testing.expectEqualStrings("13.5", formatNumber(&b, 13.5));
    try testing.expectApproxEqAbs(@as(f64, 125), stepBy(120, 1, 120, 800, 5), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 120), stepBy(120, -1, 120, 800, 5), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 800), stepBy(798, 1, 120, 800, 5), 1e-9);
    try testing.expectEqual(@as(?f64, 300), parseInRange(" 300 ", 120, 800));
    try testing.expectEqual(@as(?f64, null), parseInRange("80", 120, 800));
    try testing.expectEqual(@as(?f64, null), parseInRange("abc", 120, 800));
    try testing.expectEqualStrings("Enter a number from 120 to 800", rangeProblem(&b, 120, 800));
}

test "settings_controls: megabytes read and write as bytes" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("10", bytesAsMegabytes(&b, "10000000"));
    try testing.expectEqualStrings("2.5", bytesAsMegabytes(&b, "2500000"));
    try testing.expectEqualStrings("0", bytesAsMegabytes(&b, ""));
    try testing.expectEqual(@as(?u64, 25_000_000), megabytesToBytes("25", 4096));
    try testing.expectEqual(@as(?u64, 1_500_000), megabytesToBytes("1.5", 4096));
    try testing.expectEqual(@as(?u64, null), megabytesToBytes("5000", 4096));
    try testing.expectEqual(@as(?u64, null), megabytesToBytes("-1", 4096));
    try testing.expectEqualStrings("Enter a size in megabytes, 0 to 4096", megabytesProblem(&b, 4096));
}

test "settings_controls: colors round-trip through hex and COLORREF" {
    try testing.expectEqual(@as(?u32, 0x1a2b3c), parseHex("#1A2B3C"));
    try testing.expectEqual(@as(?u32, 0x1a2b3c), parseHex("1a2b3c"));
    try testing.expectEqual(@as(?u32, null), parseHex(""));
    try testing.expectEqual(@as(?u32, null), parseHex("red"));
    try testing.expectEqual(@as(?u32, null), parseHex("cell-foreground"));
    var b: [7]u8 = undefined;
    try testing.expectEqualStrings("#0a0b0c", formatHex(&b, 0x0a0b0c));
    try testing.expectEqual(@as(u32, 0x3c2b1a), toColorref(0x1a2b3c));
    try testing.expectEqual(@as(u32, 0x1a2b3c), fromColorref(toColorref(0x1a2b3c)));
}

test "settings_controls: flags read and compose every flag explicitly" {
    try testing.expectEqual(@as(?bool, true), flagState("cursor,no-sudo,title", "cursor"));
    try testing.expectEqual(@as(?bool, false), flagState("cursor, no-sudo ,title", "sudo"));
    try testing.expectEqual(@as(?bool, null), flagState("cursor", "title"));
    // A later mention wins, as the parser applies them in order.
    try testing.expectEqual(@as(?bool, false), flagState("cursor,no-cursor", "cursor"));
    const opts = [_][]const u8{ "cursor", "sudo", "title" };
    const out = try composeFlags(testing.allocator, &opts, "cursor,no-sudo,title", "sudo", true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("cursor,sudo,title", out);
    const off = try composeFlags(testing.allocator, &opts, "cursor", "cursor", false);
    defer testing.allocator.free(off);
    try testing.expectEqualStrings("no-cursor,no-sudo,no-title", off);
}

const FakeFs = struct {
    files: []const []const u8,
    fn exists(self: FakeFs, p: []const u8) bool {
        for (self.files) |f| if (std.ascii.eqlIgnoreCase(f, p)) return true;
        return false;
    }
};

test "settings_controls: shell check finds absolute paths and PATH programs" {
    const fs: FakeFs = .{ .files = &.{ "C:\\Windows\\System32\\cmd.exe", "C:\\Tools\\pwsh.exe" } };
    const path = "C:\\Windows\\System32;\"C:\\Tools\\\";";
    var b: [256]u8 = undefined;
    try testing.expect(shellProblem(&b, "cmd.exe /K", path, ".EXE;.CMD", fs, FakeFs.exists) == null);
    try testing.expect(shellProblem(&b, "pwsh -NoLogo", path, ".EXE;.CMD", fs, FakeFs.exists) == null);
    try testing.expect(shellProblem(&b, "\"C:\\Tools\\pwsh.exe\" -NoLogo", path, ".EXE", fs, FakeFs.exists) == null);
    try testing.expectEqualStrings("Enter a shell.", shellProblem(&b, "  ", path, ".EXE", fs, FakeFs.exists).?);
    try testing.expectEqualStrings("fish isn't on your PATH.", shellProblem(&b, "fish -l", path, ".EXE", fs, FakeFs.exists).?);
    try testing.expectEqualStrings("D:\\nope.exe isn't an executable file.", shellProblem(&b, "D:\\nope.exe", path, ".EXE", fs, FakeFs.exists).?);
    try testing.expectEqualStrings("pwsh.exe", programOf("pwsh.exe -NoLogo"));
    try testing.expectEqualStrings("C:\\a b\\x.exe", programOf("\"C:\\a b\\x.exe\" -y"));
    try testing.expectEqualStrings("Default shell (cmd.exe)", shellDefaultLabel(false));
}

test "settings_controls: folder labels" {
    var b: [256]u8 = undefined;
    const home = "C:\\Users\\me";
    try testing.expectEqualStrings(folder_home_label, folderLabel(&b, "", home));
    try testing.expectEqualStrings(folder_home_label, folderLabel(&b, "home", home));
    try testing.expectEqualStrings(folder_inherit_label, folderLabel(&b, "inherit", home));
    try testing.expectEqualStrings("~\\src", folderLabel(&b, "c:\\users\\me\\src", home));
    try testing.expectEqualStrings("C:\\Users\\meow", folderLabel(&b, "C:\\Users\\meow", home));
    try testing.expectEqualStrings("D:\\work", folderLabel(&b, "D:\\work", home));
}
