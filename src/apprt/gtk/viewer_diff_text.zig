//! The pure half of the GTK diff pane (T3417): the words and classes the
//! changed-files panel draws, and the UTF-8 repair a patch needs before it
//! can be handed to WebKit. No GTK, so it asserts in the none lane on every
//! seat; `ViewerDiff.zig` is the half that touches widgets.
const std = @import("std");
const Allocator = std.mem.Allocator;
const diff = @import("../win32/viewer_diff.zig");

/// The panel header: how many files the diff changed, or - while a filter is
/// narrowing it - how many of them match (`3 of 120 files`, so the size of
/// the diff is never lost behind the filter).
pub fn header(buf: []u8, shown: usize, total: usize, filtered: bool) [:0]const u8 {
    if (filtered) return std.fmt.bufPrintZ(buf, "{d} of {d} files", .{ shown, total }) catch "";
    return std.fmt.bufPrintZ(buf, "{d} {s} changed", .{ total, if (total == 1) "file" else "files" }) catch "";
}

/// The libadwaita style class a status letter is tinted with: green for an
/// addition, red for a deletion, the accent for an edit - git's own colors.
pub fn statusClass(s: diff.Status) [:0]const u8 {
    return switch (s) {
        .added => "success",
        .deleted => "error",
        .modified, .renamed, .copied, .type_changed => "accent",
        .unmerged => "warning",
        .unknown => "dim-label",
    };
}

/// The count column of a file row: `+N -M` (a real minus sign), or `bin`.
pub fn counts(buf: []u8, additions: u32, deletions: u32, binary: bool) [:0]const u8 {
    if (binary) return "bin";
    return std.fmt.bufPrintZ(buf, "+{d} \u{2212}{d}", .{ additions, deletions }) catch "";
}

/// `bytes` with every invalid UTF-8 sequence replaced by U+FFFD. Caller owns.
///
/// WebKitGTK takes a script as UTF-8, and a patch of a Latin-1 file is not:
/// a stray byte would make the whole `setDiffFile` call fail to parse and the
/// pane would show nothing. Win32 refuses the same input outright when it
/// widens to UTF-16; here the bad bytes become visible replacement marks and
/// the rest of the file renders.
pub fn sanitizeUtf8(alloc: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        if (std.unicode.utf8ByteSequenceLength(bytes[i])) |n| {
            if (i + n <= bytes.len) {
                if (std.unicode.utf8Decode(bytes[i..][0..n])) |_| {
                    try out.appendSlice(alloc, bytes[i..][0..n]);
                    i += n;
                    continue;
                } else |_| {}
            }
        } else |_| {}
        try out.appendSlice(alloc, "\u{fffd}");
        i += 1;
    }
    return try out.toOwnedSlice(alloc);
}

const testing = std.testing;

test "T3417: the header counts the diff, and keeps its size behind a filter" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1 file changed", header(&buf, 1, 1, false));
    try testing.expectEqualStrings("12 files changed", header(&buf, 12, 12, false));
    try testing.expectEqualStrings("3 of 120 files", header(&buf, 3, 120, true));
    try testing.expectEqualStrings("0 of 5 files", header(&buf, 0, 5, true));
}

test "T3417: a row's count column and its status tint" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("+3 \u{2212}0", counts(&buf, 3, 0, false));
    try testing.expectEqualStrings("bin", counts(&buf, 3, 0, true));
    try testing.expectEqualStrings("success", statusClass(.added));
    try testing.expectEqualStrings("error", statusClass(.deleted));
    try testing.expectEqualStrings("accent", statusClass(.renamed));
}

test "T3417: sanitizeUtf8 keeps valid text and replaces stray bytes" {
    const a = testing.allocator;
    const ok = try sanitizeUtf8(a, "caf\u{e9} \u{1f600}");
    defer a.free(ok);
    try testing.expectEqualStrings("caf\u{e9} \u{1f600}", ok);
    const latin1 = try sanitizeUtf8(a, "caf\xe9!");
    defer a.free(latin1);
    try testing.expectEqualStrings("caf\u{fffd}!", latin1);
    const cut = try sanitizeUtf8(a, "x\xe2\x82");
    defer a.free(cut);
    try testing.expectEqualStrings("x\u{fffd}\u{fffd}", cut);
}
