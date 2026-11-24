//! The text a terminal pane receives for a list of files: what a drop onto
//! the pane types, and what a paste of a clipboard holding only files pastes
//! (T3581).
//!
//! Mac pastes a copied file as its path (`getOpinionatedStringContents`:
//! every file URL, shell-escaped, joined by a space). The Windows shape of a
//! copied file is `CF_HDROP` - what Explorer's ctrl+C writes, and what an
//! image pane's ctrl+C writes beside its picture (T1909) - and before T3581 a
//! paste of one pasted nothing, because the paste read `CF_UNICODETEXT`
//! alone.
//!
//! One rule for both routes, so a dragged file and a pasted one arrive
//! identically: paths are joined by a single space, and a path holding
//! whitespace is wrapped in double quotes. Double quotes are the one quoting
//! cmd, PowerShell and a Windows program's own argv parser all read as "one
//! argument", and a Windows path cannot itself contain `"`.
//!
//! Pure: no OS imports, so the tests run in every app-runtime lane.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Append `path` to `buf` as one argument: a space first unless `buf` is
/// empty, then the path, quoted when it holds a space or a tab. An empty
/// path is skipped, so a list with a hole in it never grows a double space.
pub fn append(alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), path: []const u8) Allocator.Error!void {
    if (path.len == 0) return;
    if (buf.items.len > 0) try buf.append(alloc, ' ');
    const needs_quote = std.mem.indexOfAny(u8, path, " \t") != null;
    if (needs_quote) try buf.append(alloc, '"');
    try buf.appendSlice(alloc, path);
    if (needs_quote) try buf.append(alloc, '"');
}

/// Every path in `paths`, joined by `append`'s rule. Caller frees.
pub fn join(alloc: Allocator, paths: []const []const u8) Allocator.Error![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (paths) |p| try append(alloc, &buf, p);
    return buf.toOwnedSlice(alloc);
}

/// Whether a paste should type the clipboard's files rather than hand the
/// key to the program. Text on the clipboard always wins (that is the paste
/// today, and an app that writes both meant its text); with no text and no
/// files there is nothing to paste.
pub fn pasteFiles(has_text: bool, file_count: usize) bool {
    return !has_text and file_count > 0;
}

const testing = std.testing;

test "one plain path pastes as itself" {
    const out = try join(testing.allocator, &.{"C:\\Users\\me\\notes.txt"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("C:\\Users\\me\\notes.txt", out);
}

test "a path with a space is quoted, a plain one beside it is not" {
    const out = try join(testing.allocator, &.{ "C:\\My Files\\a b.png", "D:\\x.txt" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"C:\\My Files\\a b.png\" D:\\x.txt", out);
}

test "a tab also needs quotes" {
    const out = try join(testing.allocator, &.{"C:\\a\tb"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"C:\\a\tb\"", out);
}

test "an empty path leaves no double space" {
    const out = try join(testing.allocator, &.{ "C:\\a", "", "C:\\b" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("C:\\a C:\\b", out);
}

test "no paths join to nothing" {
    const out = try join(testing.allocator, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "a non-ASCII path passes through byte for byte" {
    const out = try join(testing.allocator, &.{"C:\\Fotos\\M\u{00FC}nchen \u{1F600}.jpg"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"C:\\Fotos\\M\u{00FC}nchen \u{1F600}.jpg\"", out);
}

test "text on the clipboard wins over files" {
    try testing.expect(!pasteFiles(true, 2));
    try testing.expect(pasteFiles(false, 1));
    try testing.expect(!pasteFiles(false, 0));
    try testing.expect(!pasteFiles(true, 0));
}
