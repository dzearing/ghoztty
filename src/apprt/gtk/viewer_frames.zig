//! Which frame a GTK viewer page's message came from (T3554, Linux; win32
//! `ViewerPane.onFrameMessage` + `viewer_bridge.subframe_js`, T928).
//!
//! WebKitGTK's `script-message-received` carries the posted value and nothing
//! else: no frame. A handler registered in the page's own (default) script
//! world is visible to EVERY frame as `window.webkit.messageHandlers.<name>`,
//! so an ad iframe on a website could post a `quote` (open the composer and
//! file a passage into the report), the table of contents' `headings`/`active`,
//! a `find` count, or a `ghozttyFileLink` that launches a local file's app -
//! all acted on exactly as the top frame's. win32 bounds this natively: a
//! subframe's message arrives on the frame's own event and only `linkMenu` is
//! taken from it.
//!
//! The GTK translation keeps the shared page scripts untouched and moves the
//! NATIVE handlers out of the page's reach:
//!
//! - The real handlers (`top_handler`, `subframe_handler`) are registered in
//!   a private script world (`world`). Page scripts run in the default world
//!   and cannot see them, in any frame.
//! - `shim_js`, a default-world user script in every frame at document start
//!   (before any page script), defines `window.webkit.messageHandlers` with
//!   the two names the shared scripts post on (`viewerTOC`, `ghozttyFileLink`).
//!   Its `postMessage` serialises the value and fires `event_name` on the
//!   frame's own document, carrying `"<name>\n<json>"`.
//! - `relay_js`, a private-world user script in every frame at document
//!   start, listens for that event on ITS frame's document and forwards the
//!   string on `top_handler` when its frame is the top one and on
//!   `subframe_handler` otherwise. `window.top` is unforgeable and is read in
//!   the private world, which a page cannot reach.
//!
//! A cross-origin iframe cannot fire an event on the top document, so the only
//! road from a subframe ends at `subframe_handler`, which takes `linkMenu` and
//! nothing else (`subframeAccepts`). A same-origin iframe can reach the top
//! document - and could already drive the top page's own toolbar - which is
//! the browser's own trust boundary, and win32's too.
//!
//! No GTK imports: every function asserts in the none lane.
const std = @import("std");
const Allocator = std.mem.Allocator;

const bridge = @import("../win32/viewer_bridge.zig");

/// The private script world the native handlers live in.
pub const world = "ghoztty";
/// The top frame's relay posts here.
pub const top_handler = "ghozttyTop";
/// Every other frame's relay posts here.
pub const subframe_handler = "ghozttySubframe";
/// The DOM event the shim fires and the relay hears.
pub const event_name = "__ghozttyBridge";

/// The default-world handler names the shared page scripts post on, and so
/// what the shim offers. Anything else a page names is undefined, as before.
pub const file_link_name = "ghozttyFileLink";

/// Which page-side handler a relayed message was posted on.
pub const Route = enum { toc, file_link };

/// The default-world shim: every frame, document start. The DOM primitives
/// are captured before any page script runs, so a page cannot reroute its own
/// later posts through a patched `dispatchEvent` - only its own frame's, which
/// is a frame it already owns.
pub const shim_js =
    \\(function () {
    \\  "use strict";
    \\  if (window.__ghozttyBridgeShim) return;
    \\  var doc = document;
    \\  var CE = window.CustomEvent;
    \\  var fire = EventTarget.prototype.dispatchEvent;
    \\  var stringify = JSON.stringify;
    \\  function handler(name) {
    \\    return Object.freeze({ postMessage: function (value) {
    \\      var json;
    \\      try { json = stringify(value); } catch (e) { return; }
    \\      if (typeof json !== "string") return;
    \\      fire.call(doc, new CE("
++ event_name ++
    \\", { detail: name + "\n" + json }));
    \\    } });
    \\  }
    \\  var ns = Object.freeze({ messageHandlers: Object.freeze({
    \\    viewerTOC: handler("
++ bridge.handler_name ++
    \\"),
    \\    ghozttyFileLink: handler("
++ file_link_name ++
    \\")
    \\  }) });
    \\  try { Object.defineProperty(window, "webkit", { value: ns, configurable: false, writable: false }); } catch (e) {}
    \\  window.__ghozttyBridgeShim = true;
    \\})();
    \\
;

/// The private-world relay: every frame, document start.
pub const relay_js =
    \\(function () {
    \\  "use strict";
    \\  var mh = window.webkit && window.webkit.messageHandlers;
    \\  var h = mh && (window.top === window ? mh.
++ top_handler ++
    \\ : mh.
++ subframe_handler ++
    \\);
    \\  if (!h) return;
    \\  document.addEventListener("
++ event_name ++
    \\", function (e) {
    \\    var d = e.detail;
    \\    if (typeof d === "string") h.postMessage(d);
    \\  }, true);
    \\})();
    \\
;

pub const Relayed = struct {
    route: Route,
    /// The posted value as JSON text (a slice of the input).
    json: []const u8,
};

/// Split a relayed `"<name>\n<json>"` string. Null for a name the shim does
/// not offer, or a string with no separator - which only a page firing the
/// event itself can produce.
pub fn split(text: []const u8) ?Relayed {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return null;
    const name = text[0..nl];
    const json = text[nl + 1 ..];
    if (json.len == 0) return null;
    const route: Route = if (std.mem.eql(u8, name, bridge.handler_name))
        .toc
    else if (std.mem.eql(u8, name, file_link_name))
        .file_link
    else
        return null;
    return .{ .route = route, .json = json };
}

/// `file_link_js` posts `JSON.stringify({...})` - a string - and the shim
/// serialises it again, so the route's JSON is a string literal. Its contents,
/// owned by the caller; null for anything that is not a JSON string.
pub fn fileLinkText(alloc: Allocator, json: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice([]const u8, alloc, json, .{}) catch return null;
    defer parsed.deinit();
    return alloc.dupe(u8, parsed.value) catch null;
}

/// What a subframe may post: the link menu, and only the link menu (win32's
/// `onFrameMessage`). The link menu needs no coordinates, which is why
/// `links.js` runs in every frame; everything else is the top page's.
pub fn subframeAccepts(message: bridge.Message) bool {
    return switch (message) {
        .link_menu => true,
        else => false,
    };
}

const testing = std.testing;

test "split: a viewerTOC post routes to the bridge with its JSON intact" {
    const r = split("viewerTOC\n{\"type\":\"linkMenu\",\"href\":\"a\\nb\"}").?;
    try testing.expectEqual(Route.toc, r.route);
    try testing.expectEqualStrings("{\"type\":\"linkMenu\",\"href\":\"a\\nb\"}", r.json);
}

test "split: a file link post routes to the file-link hook" {
    const r = split("ghozttyFileLink\n\"{}\"").?;
    try testing.expectEqual(Route.file_link, r.route);
}

test "split: an unknown name, no separator or no payload is dropped" {
    try testing.expect(split("ghozttyTop\n{}") == null);
    try testing.expect(split("viewerTOC") == null);
    try testing.expect(split("viewerTOC\n") == null);
    try testing.expect(split("") == null);
}

test "fileLinkText: unwraps the string the shim serialised again" {
    const alloc = testing.allocator;
    const t = fileLinkText(alloc, "\"{\\\"href\\\":\\\"file:///x\\\",\\\"ctrl\\\":true}\"").?;
    defer alloc.free(t);
    try testing.expectEqualStrings("{\"href\":\"file:///x\",\"ctrl\":true}", t);
    try testing.expect(fileLinkText(alloc, "{\"href\":\"x\"}") == null);
}

test "subframeAccepts: the link menu and nothing else" {
    const alloc = testing.allocator;
    const cases = [_]struct { json: []const u8, ok: bool }{
        .{ .json = "{\"type\":\"linkMenu\",\"href\":\"https://x.test/\"}", .ok = true },
        .{ .json = "{\"type\":\"quote\",\"text\":\"passage\"}", .ok = false },
        .{ .json = "{\"type\":\"headings\",\"items\":[]}", .ok = false },
        .{ .json = "{\"type\":\"active\",\"id\":\"h\"}", .ok = false },
        .{ .json = "{\"type\":\"find\",\"query\":\"q\",\"total\":3}", .ok = false },
        .{ .json = "{\"type\":\"diffNavOverflow\",\"direction\":1}", .ok = false },
    };
    for (cases) |c| {
        const p = bridge.parse(alloc, c.json) orelse return error.TestUnexpectedResult;
        defer p.deinit();
        try testing.expectEqual(c.ok, subframeAccepts(p.message));
    }
}

test "the shim offers exactly the shared scripts' names and fires the relay's event" {
    try testing.expect(std.mem.indexOf(u8, shim_js, "viewerTOC: handler(\"viewerTOC\")") != null);
    try testing.expect(std.mem.indexOf(u8, shim_js, "ghozttyFileLink: handler(\"ghozttyFileLink\")") != null);
    try testing.expect(std.mem.indexOf(u8, shim_js, "new CE(\"__ghozttyBridge\"") != null);
    // The native names never appear in the page's world.
    try testing.expect(std.mem.indexOf(u8, shim_js, top_handler) == null);
    try testing.expect(std.mem.indexOf(u8, shim_js, subframe_handler) == null);
}

test "the relay picks its handler by the frame it runs in" {
    try testing.expect(std.mem.indexOf(u8, relay_js, "window.top === window ? mh.ghozttyTop : mh.ghozttySubframe") != null);
    try testing.expect(std.mem.indexOf(u8, relay_js, "addEventListener(\"__ghozttyBridge\"") != null);
}
