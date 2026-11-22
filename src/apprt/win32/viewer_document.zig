//! A viewer pane's document read, as one blocking call that runs anywhere
//! (T3224): read the file, drop a UTF-8 BOM, refuse what is not text, and
//! build the `window.__viewer` call that hands it to the page.
//!
//! **Why it is its own function.** The read used to sit inline in
//! `ViewerPane.renderFileContent`, on the GUI thread, which is the message loop
//! every terminal in the window draws on. Up to `max_file_bytes` (32 MB) read,
//! validated and escaped there is a visible stall on a local disk and an
//! unbounded one on a slow or network path. Here it is one call with no pane
//! state, so `ViewerDocumentRead` runs it on a pooled worker and the pane only
//! hands the finished script to the web view; and the none lane checks every
//! outcome without a browser.
//!
//! The rules are Mac's `renderFileContent`, unchanged from the inline version:
//! the same three error titles, the same BOM drop, the same validation.
const std = @import("std");
const Allocator = std.mem.Allocator;

const content = @import("viewer_content.zig");

/// What the read came to: the script to execute, or the title of the error
/// card the page shows instead. Every failure is a card - a viewer that shows
/// nothing and says nothing reads as one still loading.
pub const Outcome = union(enum) {
    /// The page call, already UTF-16 for `ExecuteScript` (T389). Caller owns.
    script: [:0]u16,
    /// One of `content`'s error titles. Static text, never freed.
    failure: []const u8,
    /// The mode has no document to read (a website, an html page, a diff, an
    /// image); nothing is to be done.
    none,

    pub fn deinit(self: Outcome, alloc: Allocator) void {
        switch (self) {
            .script => |s| alloc.free(s),
            .failure, .none => {},
        }
    }
};

/// The whole read, for `path` viewed as `mode`. `bytes_read` reports the
/// file's size for the T3037 render log line, 0 when it was never read.
pub fn read(alloc: Allocator, mode: content.Mode, path: []const u8, bytes_read: *usize) Outcome {
    bytes_read.* = 0;
    switch (mode) {
        .markdown, .code => {},
        .web, .html, .diff, .image => return .none,
    }
    // The file's bytes and the script built from them are deliberately NOT
    // alive at the same time as the call that consumes the script (T389): the
    // bytes are freed on the way out, so the peak is the file plus its widened
    // literal.
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, content.max_file_bytes) catch |err| {
        return .{ .failure = switch (err) {
            error.FileTooBig => content.error_too_large,
            else => content.error_unreadable,
        } };
    };
    defer alloc.free(bytes);
    bytes_read.* = bytes.len;
    return build(alloc, mode, path, bytes);
}

/// Bytes already in hand to their outcome. Split from `read` so the rules are
/// checkable on literals.
pub fn build(alloc: Allocator, mode: content.Mode, path: []const u8, bytes: []const u8) Outcome {
    const text = documentText(bytes) orelse return .{ .failure = content.error_not_text };

    const js = switch (mode) {
        .markdown => content.setMarkdownCallUtf16(alloc, text),
        .code => content.setCodeCallUtf16(alloc, text, content.highlightLanguage(content.extension(path))),
        .web, .html, .diff, .image => return .none,
    } catch return .{ .failure = content.error_unreadable };
    return .{ .script = js };
}

/// The text a document's bytes render as, or null when they are not text.
/// Borrowed from `bytes`. Shared by both script builds, so the UTF-16 and
/// UTF-8 paths cannot disagree about what counts as a text file.
pub fn documentText(bytes: []const u8) ?[]const u8 {
    // A UTF-8 BOM is invisible to the reader and NOT to the renderer: left in
    // place it is a stray glyph ahead of the first heading, and Windows
    // editors write one routinely.
    var text = bytes;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];

    // Mac's `String(data:encoding:.utf8)` returning nil is exactly this check;
    // a binary file opened by mistake gets a card, not mojibake.
    if (!std.unicode.utf8ValidateSlice(text)) return null;
    return text;
}

/// `build`'s outcome as a UTF-8 script, for a web view that evaluates UTF-8
/// (WebKitGTK, T3410). Same rules, same cards.
pub const Utf8Outcome = union(enum) {
    /// The page call. Caller owns.
    script: []u8,
    failure: []const u8,
    none,

    pub fn deinit(self: Utf8Outcome, alloc: Allocator) void {
        switch (self) {
            .script => |s| alloc.free(s),
            .failure, .none => {},
        }
    }
};

/// `build`, writing UTF-8 (T3410).
pub fn buildUtf8(alloc: Allocator, mode: content.Mode, path: []const u8, bytes: []const u8) Utf8Outcome {
    switch (mode) {
        .markdown, .code => {},
        .web, .html, .diff, .image => return .none,
    }
    const text = documentText(bytes) orelse return .{ .failure = content.error_not_text };
    const js = switch (mode) {
        .markdown => content.setMarkdownCall(alloc, text),
        .code => content.setCodeCall(alloc, text, content.highlightLanguage(content.extension(path))),
        .web, .html, .diff, .image => unreachable,
    } catch return .{ .failure = content.error_unreadable };
    return .{ .script = js };
}

/// `read`, writing UTF-8 (T3410): the file is read under the same ceiling and
/// every failure is the same card.
pub fn readUtf8(alloc: Allocator, mode: content.Mode, path: []const u8) Utf8Outcome {
    switch (mode) {
        .markdown, .code => {},
        .web, .html, .diff, .image => return .none,
    }
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, content.max_file_bytes) catch |err| {
        return .{ .failure = switch (err) {
            error.FileTooBig => content.error_too_large,
            else => content.error_unreadable,
        } };
    };
    defer alloc.free(bytes);
    return buildUtf8(alloc, mode, path, bytes);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn expectScriptContains(o: Outcome, needle: []const u8) !void {
    const s = switch (o) {
        .script => |s| s,
        else => return error.TestExpectedScript,
    };
    const narrow = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, s);
    defer testing.allocator.free(narrow);
    if (std.mem.indexOf(u8, narrow, needle) == null) {
        std.debug.print("script {s} lacks {s}\n", .{ narrow, needle });
        return error.TestExpectedNeedle;
    }
}

test "a markdown document becomes a setMarkdown call" {
    const o = build(testing.allocator, .markdown, "C:\\a.md", "# Hi");
    defer o.deinit(testing.allocator);
    try expectScriptContains(o, "setMarkdown(\"# Hi\")");
}

test "buildUtf8: the same call as the UTF-16 build, in UTF-8 (T3410)" {
    const alloc = testing.allocator;
    const md = buildUtf8(alloc, .markdown, "/a.md", "\xEF\xBB\xBF# Hi \"q\"\n");
    defer md.deinit(alloc);
    try testing.expectEqualStrings("window.__viewer.setMarkdown(\"# Hi \\\"q\\\"\\n\")", md.script);

    const code = buildUtf8(alloc, .code, "/x/a.py", "x = 1");
    defer code.deinit(alloc);
    try testing.expectEqualStrings("window.__viewer.setCode(\"x = 1\", \"python\")", code.script);

    const bin = buildUtf8(alloc, .markdown, "/a.md", "\xFF\xFEbinary");
    try testing.expectEqualStrings(content.error_not_text, bin.failure);

    for ([_]content.Mode{ .web, .html, .diff, .image }) |m| {
        try testing.expect(buildUtf8(alloc, m, "/a.md", "# Hi") == .none);
        try testing.expect(readUtf8(alloc, m, "/definitely/missing.md") == .none);
    }
    const missing = readUtf8(alloc, .markdown, "/no/such/dir/missing.md");
    try testing.expectEqualStrings(content.error_unreadable, missing.failure);
}

test "a code file carries the language its extension names" {
    const o = build(testing.allocator, .code, "C:\\a.py", "x = 1");
    defer o.deinit(testing.allocator);
    try expectScriptContains(o, "setCode(");
    try expectScriptContains(o, "\"python\"");
}

test "a UTF-8 BOM is dropped before the page sees it" {
    const o = build(testing.allocator, .markdown, "C:\\a.md", "\xEF\xBB\xBF# Hi");
    defer o.deinit(testing.allocator);
    try expectScriptContains(o, "setMarkdown(\"# Hi\")");
}

test "bytes that are not UTF-8 are the not-a-text-file card" {
    const o = build(testing.allocator, .markdown, "C:\\a.md", "\xFF\xFEbinary");
    defer o.deinit(testing.allocator);
    try testing.expectEqualStrings(content.error_not_text, o.failure);
}

test "modes with no document to read do nothing, and read nothing" {
    for ([_]content.Mode{ .web, .html, .diff, .image }) |m| {
        var n: usize = 99;
        const o = read(testing.allocator, m, "C:\\definitely\\missing.md", &n);
        try testing.expect(o == .none);
        try testing.expectEqual(@as(usize, 0), n);
    }
}

test "a file that is not there is the cannot-read card" {
    var n: usize = 99;
    const o = read(testing.allocator, .markdown, "Z:\\no\\such\\dir\\missing.md", &n);
    defer o.deinit(testing.allocator);
    try testing.expectEqualStrings(content.error_unreadable, o.failure);
    try testing.expectEqual(@as(usize, 0), n);
}

test "a file on disk is read, sized, and built" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "doc.md", .data = "\xEF\xBB\xBF# On disk" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "doc.md");
    defer testing.allocator.free(path);

    var n: usize = 0;
    const o = read(testing.allocator, .markdown, path, &n);
    defer o.deinit(testing.allocator);
    try expectScriptContains(o, "# On disk");
    try testing.expectEqual(@as(usize, 12), n);
}

test "a file past the cap is the too-large card" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile("big.md", .{});
        defer f.close();
        // Sparse past the cap: no 32 MB write, just a length.
        try f.setEndPos(content.max_file_bytes + 1);
    }
    const path = try tmp.dir.realpathAlloc(testing.allocator, "big.md");
    defer testing.allocator.free(path);

    var n: usize = 0;
    const o = read(testing.allocator, .markdown, path, &n);
    defer o.deinit(testing.allocator);
    try testing.expectEqualStrings(content.error_too_large, o.failure);
}

test "an allocation failure while building leaks nothing and says unreadable" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const o = build(failing.allocator(), .markdown, "C:\\a.md", "# Hi");
    try testing.expectEqualStrings(content.error_unreadable, o.failure);
}
