//! The GTK feedback composer's pure half (T3544, Linux L9j-2; Mac
//! `ViewerFeedbackToolbar`, win32 `ViewerFeedbackWeb` + D43).
//!
//! The composer's page is the shared `src/viewer/composer.js`, written
//! against WebView2's `window.chrome.webview` (`postMessage` up,
//! `addEventListener("message")` down). WebKitGTK's channel is a different
//! spelling of the same two directions - `webkit.messageHandlers.<name>
//! .postMessage` up and `evaluate_javascript` down - so rather than fork the
//! page, a document-start user script (`shim_js`) gives it the object it
//! already looks for. Nothing in `composer.js` changes for Linux.
//!
//! The shim also owns the two chords the page does not: **Ctrl+Enter** sends
//! and **Escape** closes (win32 catches both as WebView2 accelerators; Mac in
//! its `NSTextView` delegate). Plain Enter is left to the engine, which in a
//! `plaintext-only` box inserts the newline the reference asks for. Both
//! arrive here as host-only messages (`{t:"send"}`, `{t:"close"}`) that
//! `hostVerb` recognises BEFORE the shared parser sees them - the shared
//! parser drops an unknown `t`, and must keep doing so for every other page.
//!
//! The rest is the report context the send fills in: the `kind` a reader
//! branches on, the viewport string, and the footer's two lines. No GTK
//! imports, so the whole file asserts in the none lane.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The script message handler the shim posts to. One per composer view (each
/// web view has its own content manager), so it cannot collide with the
/// page view's `viewerTOC`.
pub const handler_name = "ghozttyComposer";

/// The JS function the host calls to deliver a message DOWN to the page.
pub const deliver_fn = "__ghozttyComposerDeliver";

/// `window.chrome.webview` for a WebKitGTK page, plus the send/close chords.
/// Injected at document start, so it exists before `composer.js` reads it.
pub const shim_js =
    \\(function () {
    \\  "use strict";
    \\  var h = window.webkit && window.webkit.messageHandlers &&
    \\    window.webkit.messageHandlers.
++ handler_name ++
    \\;
    \\  if (!h) return;
    \\  var listeners = [];
    \\  window.chrome = window.chrome || {};
    \\  window.chrome.webview = {
    \\    postMessage: function (m) { h.postMessage(m); },
    \\    addEventListener: function (type, fn) {
    \\      if (type === "message" && typeof fn === "function") listeners.push(fn);
    \\    }
    \\  };
    \\  window.
++ deliver_fn ++
    \\ = function (m) {
    \\    for (var i = 0; i < listeners.length; i++) listeners[i]({ data: m });
    \\  };
    \\  window.addEventListener("keydown", function (e) {
    \\    if (e.isComposing) return;
    \\    if (e.key === "Enter" && e.ctrlKey && !e.altKey && !e.metaKey) {
    \\      e.preventDefault();
    \\      e.stopPropagation();
    \\      h.postMessage({ t: "send" });
    \\    } else if (e.key === "Escape" && !e.ctrlKey && !e.altKey && !e.metaKey && !e.shiftKey) {
    \\      e.preventDefault();
    \\      e.stopPropagation();
    \\      h.postMessage({ t: "close" });
    \\    } else if ((e.key === "S" || e.key === "s") && e.ctrlKey && e.shiftKey && !e.altKey && !e.metaKey) {
    \\      e.preventDefault();
    \\      e.stopPropagation();
    \\      h.postMessage({ t: "shot" });
    \\    }
    \\  }, true);
    \\})();
;

/// The host-only messages the shim posts. `shot` is Ctrl+Shift+S, the
/// keyboard's `+` (T3546; the Mac's Shift+Cmd+S).
pub const HostVerb = enum { send, close, shot };

/// `{t:"send"}` / `{t:"close"}` from the shim, or null for anything else -
/// which then goes to the shared `viewer_feedback_page.parse`.
pub fn hostVerb(alloc: Allocator, json_text: []const u8) ?HostVerb {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const t = switch (obj.get("t") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (std.mem.eql(u8, t, "send")) return .send;
    if (std.mem.eql(u8, t, "close")) return .close;
    if (std.mem.eql(u8, t, "shot")) return .shot;
    return null;
}

/// The script that delivers one JSON message down: `__deliver(<json>)`. The
/// message is already JSON, which is also a JS expression, so it goes in as
/// is. Caller frees.
pub fn deliverScript(alloc: Allocator, json: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "window." ++ deliver_fn ++ " && window." ++ deliver_fn ++ "({s});", .{json});
}

/// What the viewer is showing, as the report's `source.kind`.
pub const Kind = enum {
    file,
    web,
    image,

    pub fn text(self: Kind) []const u8 {
        return @tagName(self);
    }
};

/// The report's kind for a pane at `location`. An image pane is `image`
/// (no selection, no quotes - the reference's promise to a reader); anything
/// file-backed is `file`; the rest is `web`.
pub fn kindFor(location: []const u8, is_image: bool) Kind {
    if (is_image) return .image;
    return if (filePath(location) != null) .file else .web;
}

/// The absolute file path behind `location`, when it is file-backed: a bare
/// absolute path, or a `file://` URL (percent-decoding is not attempted - a
/// path that needs it is reported as its URL, never as a wrong path).
pub fn filePath(location: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, location, "/")) return location;
    const prefix = "file://";
    if (std.ascii.startsWithIgnoreCase(location, prefix)) {
        const rest = location[prefix.len..];
        if (std.mem.indexOfScalar(u8, rest, '%') != null) return null;
        if (std.mem.startsWith(u8, rest, "/")) return rest;
    }
    return null;
}

/// `source.viewport`, `"<w>x<h>"` in logical pixels; null for a pane that
/// has not been laid out.
pub fn viewportText(buf: []u8, width: i32, height: i32) ?[]const u8 {
    if (width <= 0 or height <= 0) return null;
    return std.fmt.bufPrint(buf, "{d}x{d}", .{ width, height }) catch null;
}

/// The confirmation the composer's footer shows after a send, as the Mac
/// words it: where the report went, relative to the worktree.
pub fn filedText(buf: []u8, stem: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "Filed temp/feedback/new/{s}", .{stem}) catch "Filed";
}

/// The footer's idle line (T3553, Mac's `stagingLink`): the draft's own
/// folder, `<worktree name>/temp/feedback/.staging/<stem>`, shown as a link
/// that opens it - so the user can drop a log or a recording in, and the send
/// publishes the folder whole. Null when it does not fit `buf`.
pub fn stagingLinkText(buf: []u8, worktree_name: []const u8, stem: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ worktree_name, staging_relative_path, stem }) catch null;
}

/// The staging area, relative to the worktree (win32's
/// `viewer_feedback_report.staging_relative_path`; a test holds them equal).
pub const staging_relative_path = "temp/feedback/.staging";

/// The link's tooltip, as the Mac words it (Finder -> the file manager).
pub const staging_tooltip = "Open this draft's folder - drop files here to include them in the report";

/// The key hints at the footer's trailing edge (the Mac's "send / shot /
/// close" hints, in the chords this build uses).
pub const footer_hints = "Ctrl+Enter send \u{00b7} Ctrl+Shift+S shot \u{00b7} Esc close";

/// A report is worth sending when its text is more than whitespace (images
/// are a later card on Linux, so text is the whole report today).
pub fn hasContent(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len != 0;
}

/// The composer's text box height for `lines` wrapped lines: one line up to
/// six, the Mac's pill, plus the page's own padding.
pub fn boxHeight(lines: u32, line_px: f32, pad_px: f32) i32 {
    const n: f32 = @floatFromInt(std.math.clamp(lines, 1, 6));
    return @intFromFloat(@ceil(n * line_px + pad_px));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the shim posts to the handler it registers, and defines the deliver hook" {
    try testing.expect(std.mem.indexOf(u8, shim_js, "messageHandlers.ghozttyComposer;") != null);
    try testing.expect(std.mem.indexOf(u8, shim_js, "window.__ghozttyComposerDeliver = function") != null);
    // composer.js reads `window.chrome.webview` - the shim must define that
    // exact path, with both halves the page uses.
    try testing.expect(std.mem.indexOf(u8, shim_js, "window.chrome.webview = {") != null);
    try testing.expect(std.mem.indexOf(u8, shim_js, "postMessage: function") != null);
    try testing.expect(std.mem.indexOf(u8, shim_js, "addEventListener: function") != null);
    // Enter alone is the engine's newline; only Ctrl+Enter is taken.
    try testing.expect(std.mem.indexOf(u8, shim_js, "e.key === \"Enter\" && e.ctrlKey") != null);
    // Ctrl+Shift+S is the screenshot chord (T3546).
    try testing.expect(std.mem.indexOf(u8, shim_js, "e.ctrlKey && e.shiftKey") != null);
    try testing.expect(std.mem.indexOf(u8, shim_js, "{ t: \"shot\" }") != null);
}

test "the shared composer page still reads the object the shim defines" {
    const page = @import("../win32/viewer_feedback_page.zig");
    try testing.expect(std.mem.indexOf(u8, page.js, "window.chrome && window.chrome.webview") != null);
    try testing.expect(std.mem.indexOf(u8, page.js, "host.addEventListener(\"message\"") != null);
    try testing.expect(std.mem.indexOf(u8, page.js, "var m = e.data;") != null);
}

test "hostVerb: send and close, and nothing else" {
    try testing.expectEqual(HostVerb.send, hostVerb(testing.allocator, "{\"t\":\"send\"}").?);
    try testing.expectEqual(HostVerb.close, hostVerb(testing.allocator, "{\"t\":\"close\"}").?);
    try testing.expectEqual(HostVerb.shot, hostVerb(testing.allocator, "{\"t\":\"shot\"}").?);
    try testing.expect(hostVerb(testing.allocator, "{\"t\":\"ready\"}") == null);
    try testing.expect(hostVerb(testing.allocator, "{\"t\":5}") == null);
    try testing.expect(hostVerb(testing.allocator, "[\"send\"]") == null);
    try testing.expect(hostVerb(testing.allocator, "not json") == null);
}

test "deliverScript wraps the JSON in the guarded hook call" {
    const s = try deliverScript(testing.allocator, "{\"t\":\"focus\"}");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(
        "window.__ghozttyComposerDeliver && window.__ghozttyComposerDeliver({\"t\":\"focus\"});",
        s,
    );
}

test "kindFor: image, file and web" {
    try testing.expectEqual(Kind.image, kindFor("/tmp/a.png", true));
    try testing.expectEqual(Kind.file, kindFor("/repo/docs/a.md", false));
    try testing.expectEqual(Kind.file, kindFor("file:///repo/a.md", false));
    try testing.expectEqual(Kind.web, kindFor("http://127.0.0.1:3000/", false));
    try testing.expectEqual(Kind.web, kindFor("https://example.com/", false));
    try testing.expectEqualStrings("image", Kind.image.text());
}

test "filePath: bare paths and plain file URLs only" {
    try testing.expectEqualStrings("/a/b.md", filePath("/a/b.md").?);
    try testing.expectEqualStrings("/a/b.md", filePath("file:///a/b.md").?);
    try testing.expect(filePath("file:///a%20b.md") == null);
    try testing.expect(filePath("http://x/") == null);
    try testing.expect(filePath("relative.md") == null);
}

test "viewportText" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("820x540", viewportText(&buf, 820, 540).?);
    try testing.expect(viewportText(&buf, 0, 540) == null);
}

test "footer lines" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Filed temp/feedback/new/abc", filedText(&buf, "abc"));
    try testing.expectEqualStrings(
        "repo/temp/feedback/.staging/20260809T004912Z-a3f9c2",
        stagingLinkText(&buf, "repo", "20260809T004912Z-a3f9c2").?,
    );
    var tiny: [8]u8 = undefined;
    try testing.expect(stagingLinkText(&tiny, "repo", "x") == null);
}

test "the staging path agrees with the report module's" {
    const report = @import("../win32/viewer_feedback_report.zig");
    try testing.expectEqualStrings(report.staging_relative_path, staging_relative_path);
}

test "hasContent ignores whitespace" {
    try testing.expect(!hasContent(" \n\t "));
    try testing.expect(hasContent(" x "));
}

test "boxHeight clamps to one..six lines" {
    try testing.expectEqual(@as(i32, 26), boxHeight(0, 18, 8));
    try testing.expectEqual(@as(i32, 26), boxHeight(1, 18, 8));
    try testing.expectEqual(@as(i32, 116), boxHeight(6, 18, 8));
    try testing.expectEqual(@as(i32, 116), boxHeight(60, 18, 8));
}
