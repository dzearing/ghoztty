//! The GTK viewer pane's navigation chrome, the pure half (T3412, Linux L9c).
//!
//! The Mac's `ViewerView` nav bar and pane-scoped keys, translated for the
//! GTK frontend. What a typed address MEANS, what the field shows, which
//! chord is the pane's, and what Escape/Return mean are already decided -
//! pure, and tested in every lane - by the win32 port (`viewer_nav.zig`,
//! `viewer_accel.zig`, `viewer_find.zig`). This module does not decide any of
//! it again: it maps a GDK key event onto those tables, so the three
//! platforms cannot drift on which chord does what. Linux uses the Windows
//! modifier (Ctrl), the same way every GTK browser does.
//!
//! The one thing that is GTK's own is how history survives the file <-> web
//! boundary. A template mode (markdown, code) loads the bundled
//! `ghoztty-viewer://page/viewer.html` and pushes the file in by script, so
//! two history entries for two different files would otherwise be the same
//! URL. The file therefore rides along as a query (`?file=<path>`): every
//! entry in WebKit's own back/forward list names the file it showed, Back
//! re-renders exactly that file, and the scheme handler already ignores the
//! query when it serves the template (`content.pathUnderOrigin`).
//!
//! No GTK or WebKit imports, so the none lane runs these tests on every seat.
const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../input.zig");
const scheme = @import("viewer_scheme.zig");
const content = @import("../win32/viewer_content.zig");
const accel = @import("../win32/viewer_accel.zig");
const find = @import("../win32/viewer_find.zig");

pub const PaneChord = accel.PaneChord;
pub const ZoomAction = accel.ZoomAction;
pub const FieldKeyAction = find.FieldKeyAction;
pub const FieldFocus = find.Focus;
pub const steppedZoom = accel.steppedZoom;

// -------------------------------------------------------------------------
// The template URL carries its file
// -------------------------------------------------------------------------

const file_param = "?file=";

/// The template URL a template-mode pane loads to show `file`:
/// `ghoztty-viewer://page/viewer.html?file=%2Fhome%2Fu%2FREADME.md`.
/// Every byte outside the unreserved set is escaped, so a path holding `#`,
/// `&` or `?` survives the round trip. Caller owns the result.
pub fn templateUrlFor(alloc: Allocator, file: []const u8) Allocator.Error![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, scheme.template_url);
    try out.appendSlice(alloc, file_param);
    for (file) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(alloc, c);
        } else {
            var hex: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&hex, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(alloc, &hex);
        }
    }
    return try out.toOwnedSliceSentinel(alloc, 0);
}

/// The file a committed template URL shows, decoded into `buf`, or null when
/// `uri` is not the template page or names no file (the bare template URL).
pub fn fileFromTemplateUrl(buf: []u8, uri: []const u8) ?[]const u8 {
    if (uri.len < scheme.template_url.len) return null;
    if (!std.ascii.eqlIgnoreCase(uri[0..scheme.template_url.len], scheme.template_url)) return null;
    const rest = uri[scheme.template_url.len..];
    if (!std.mem.startsWith(u8, rest, file_param)) return null;
    var value = rest[file_param.len..];
    if (std.mem.indexOfAny(u8, value, "&#")) |i| value = value[0..i];
    if (value.len == 0) return null;
    return content.percentDecode(buf, value);
}

/// Where a committed web view URI puts the pane, as far as the chrome cares.
pub const Committed = union(enum) {
    /// The template page showing this file (decoded, borrowed from the buffer
    /// handed to `classifyCommitted`).
    template_file: []const u8,
    /// Our template with no file: nothing to re-render, keep what we have.
    template_bare,
    /// A rendered `.html` page under the pinned grant; the relative path.
    page: []const u8,
    /// Anywhere else: the web (or `about:blank`).
    web,
};

pub fn classifyCommitted(buf: []u8, uri: []const u8) Committed {
    switch (scheme.originOf(uri) orelse return .web) {
        .template => return if (fileFromTemplateUrl(buf, uri)) |f| .{ .template_file = f } else .template_bare,
        .page => return if (scheme.requestPath(buf, .page, uri)) |rel| .{ .page = rel } else .web,
    }
}

/// Whether the reveal-in-file-manager button belongs on the bar: only while
/// the pane IS showing a local file (Mac: markdown, code, an HTML page, an
/// image). A website or a diff has nothing single to reveal, so no button
/// rather than a dead one.
pub fn showsReveal(mode: content.Mode) bool {
    return mode.isFile();
}

// -------------------------------------------------------------------------
// Keys: a GDK event onto the shared tables
// -------------------------------------------------------------------------

/// `GdkModifierType` bits this module reads (gdk/gdkenums.h).
pub const gdk_shift_mask: u32 = 1 << 0;
pub const gdk_control_mask: u32 = 1 << 2;
pub const gdk_alt_mask: u32 = 1 << 3;
pub const gdk_super_mask: u32 = 1 << 26;
pub const gdk_meta_mask: u32 = 1 << 28;

pub fn modsFromGdk(state: u32) input.Mods {
    return .{
        .shift = state & gdk_shift_mask != 0,
        .ctrl = state & gdk_control_mask != 0,
        .alt = state & gdk_alt_mask != 0,
        .super = state & (gdk_super_mask | gdk_meta_mask) != 0,
    };
}

/// The GDK keysyms the viewer's chords use (gdk/gdkkeysyms.h).
pub const keyval = struct {
    pub const Return: u32 = 0xff0d;
    pub const KP_Enter: u32 = 0xff8d;
    pub const Escape: u32 = 0xff1b;
    pub const F3: u32 = 0xffc0;
    pub const KP_Add: u32 = 0xffab;
    pub const KP_Subtract: u32 = 0xffad;
    pub const KP_0: u32 = 0xffb0;
    pub const KP_Insert: u32 = 0xff9e;
    pub const equal: u32 = '=';
    pub const plus: u32 = '+';
    pub const minus: u32 = '-';
    pub const underscore: u32 = '_';
};

/// The Win32 virtual key the shared tables are written in, for the keysyms a
/// viewer chord can be. Letters fold case (GDK reports `R` for ctrl+shift+r),
/// `=`/`+` are the one OEM key, as are `-`/`_`. Null for any other key, which
/// is then nobody's chord here.
pub fn vkForKeyval(kv: u32) ?u16 {
    if (kv >= 'a' and kv <= 'z') return @intCast(kv - 'a' + 'A');
    if (kv >= 'A' and kv <= 'Z') return @intCast(kv);
    return switch (kv) {
        '0' => 0x30,
        keyval.equal, keyval.plus => 0xBB, // VK_OEM_PLUS
        keyval.minus, keyval.underscore => 0xBD, // VK_OEM_MINUS
        keyval.KP_Add => 0x6B,
        keyval.KP_Subtract => 0x6D,
        keyval.KP_0, keyval.KP_Insert => 0x60,
        keyval.Return, keyval.KP_Enter => 0x0D,
        keyval.Escape => 0x1B,
        keyval.F3 => 0x72,
        else => null,
    };
}

/// What a key press in a viewer pane means to the pane itself.
pub const KeyAction = union(enum) {
    pane: PaneChord,
    zoom: ZoomAction,
    field: FieldKeyAction,
};

/// Classify a key press inside a viewer pane: a pane chord (Ctrl+R/L/F/G,
/// Alt+D, F3), a zoom (Ctrl +/-/0), or Escape/Return for whichever field has
/// the caret. Null means the pane does not claim it: the page or the focused
/// field keeps it, and an app keybinding may answer it.
///
/// Zoom is the CONTENT's (Mac scopes it to the page), so it is not claimed
/// while the address field has the caret - win32's `fieldOffers` rule.
pub fn classify(kv: u32, state: u32, focus: FieldFocus) ?KeyAction {
    const vk = vkForKeyval(kv) orelse return null;
    const mods = modsFromGdk(state);
    if (find.fieldKeyAction(vk, .{
        .ctrl = mods.ctrl,
        .shift = mods.shift,
        .alt = mods.alt,
        .super = mods.super,
    }, focus)) |a| return .{ .field = a };
    if (accel.paneChord(vk, mods)) |c| return .{ .pane = c };
    if (!focus.address and !focus.find) {
        if (accel.zoomAction(vk, mods)) |z| return .{ .zoom = z };
    }
    return null;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "T3412: a template URL round-trips its file, odd bytes included" {
    const alloc = testing.allocator;
    const paths = [_][]const u8{
        "/home/u/README.md",
        "/tmp/a b/#notes?.md",
        "/tmp/x&y=z/caf\xc3\xa9.md",
    };
    for (paths) |p| {
        const url = try templateUrlFor(alloc, p);
        defer alloc.free(url);
        try testing.expect(std.mem.startsWith(u8, url, scheme.template_url ++ "?file="));
        // The query never leaks into what the scheme handler serves.
        var rbuf: [256]u8 = undefined;
        try testing.expectEqualStrings("viewer.html", scheme.requestPath(&rbuf, .template, url).?);
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings(p, fileFromTemplateUrl(&buf, url).?);
    }
}

test "T3412: only the template page with a file names a file" {
    var buf: [256]u8 = undefined;
    try testing.expect(fileFromTemplateUrl(&buf, scheme.template_url) == null);
    try testing.expect(fileFromTemplateUrl(&buf, scheme.template_url ++ "?file=") == null);
    try testing.expect(fileFromTemplateUrl(&buf, "https://example.com/viewer.html?file=%2Fx") == null);
    try testing.expect(fileFromTemplateUrl(&buf, "ghoztty-viewer://page/vendor/x.js?file=%2Fx") == null);
    try testing.expectEqualStrings("/x", fileFromTemplateUrl(&buf, scheme.template_url ++ "?file=%2Fx#top").?);
}

test "T3412: a committed URI says where the pane is" {
    var buf: [256]u8 = undefined;
    switch (classifyCommitted(&buf, scheme.template_url ++ "?file=%2Fa%2Fb.md")) {
        .template_file => |f| try testing.expectEqualStrings("/a/b.md", f),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(classifyCommitted(&buf, scheme.template_url) == .template_bare);
    switch (classifyCommitted(&buf, "ghoztty-page://page/docs/index%20a.html")) {
        .page => |rel| try testing.expectEqualStrings("docs/index a.html", rel),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(classifyCommitted(&buf, "https://example.com/") == .web);
    try testing.expect(classifyCommitted(&buf, "about:blank") == .web);
}

test "T3412: the reveal button is for local files only" {
    try testing.expect(showsReveal(.markdown));
    try testing.expect(showsReveal(.code));
    try testing.expect(showsReveal(.html));
    try testing.expect(showsReveal(.image));
    try testing.expect(!showsReveal(.web));
    try testing.expect(!showsReveal(.diff));
}

test "T3412: GDK keysyms map onto the shared virtual keys" {
    try testing.expectEqual(@as(?u16, 0x52), vkForKeyval('r'));
    try testing.expectEqual(@as(?u16, 0x52), vkForKeyval('R'));
    try testing.expectEqual(@as(?u16, 0xBB), vkForKeyval('='));
    try testing.expectEqual(@as(?u16, 0xBB), vkForKeyval('+'));
    try testing.expectEqual(@as(?u16, 0x0D), vkForKeyval(keyval.KP_Enter));
    try testing.expectEqual(@as(?u16, null), vkForKeyval(0xff51)); // Left
    try testing.expectEqual(@as(?u16, null), vkForKeyval('1'));
}

const ctrl = gdk_control_mask;
const shift = gdk_shift_mask;
const alt = gdk_alt_mask;

test "T3412: the pane's own chords use Ctrl, exactly" {
    const none: FieldFocus = .{};
    try testing.expectEqual(KeyAction{ .pane = .reload }, classify('r', ctrl, none).?);
    try testing.expectEqual(KeyAction{ .pane = .focus_address }, classify('l', ctrl, none).?);
    try testing.expectEqual(KeyAction{ .pane = .focus_address }, classify('d', alt, none).?);
    try testing.expectEqual(KeyAction{ .pane = .find }, classify('f', ctrl, none).?);
    try testing.expectEqual(KeyAction{ .pane = .find_next }, classify('g', ctrl, none).?);
    try testing.expectEqual(KeyAction{ .pane = .find_previous }, classify('G', ctrl | shift, none).?);
    // Ctrl+Shift+R is "reload bypassing cache" in browsers and Ctrl+D is
    // split right: neither is the pane's.
    try testing.expect(classify('R', ctrl | shift, none) == null);
    try testing.expect(classify('d', ctrl, none) == null);
    // Super never participates; plain letters are typing.
    try testing.expect(classify('r', ctrl | gdk_super_mask, none) == null);
    try testing.expect(classify('r', 0, none) == null);
}

test "T3412: zoom is the content's, never the address field's" {
    const none: FieldFocus = .{};
    try testing.expectEqual(KeyAction{ .zoom = .zoom_in }, classify('=', ctrl, none).?);
    try testing.expectEqual(KeyAction{ .zoom = .zoom_in }, classify('+', ctrl | shift, none).?);
    try testing.expectEqual(KeyAction{ .zoom = .zoom_out }, classify('-', ctrl, none).?);
    try testing.expectEqual(KeyAction{ .zoom = .reset }, classify('0', ctrl, none).?);
    try testing.expectEqual(KeyAction{ .zoom = .zoom_in }, classify(keyval.KP_Add, ctrl, none).?);
    try testing.expect(classify('=', ctrl, .{ .address = true }) == null);
    try testing.expect(classify('-', ctrl | alt, none) == null);
}

test "T3412: Escape and Return follow the shared field precedence" {
    try testing.expectEqual(KeyAction{ .field = .revert_address }, classify(keyval.Escape, 0, .{ .address = true, .find_open = true }).?);
    try testing.expectEqual(KeyAction{ .field = .close_find }, classify(keyval.Escape, 0, .{ .find_open = true }).?);
    try testing.expect(classify(keyval.Escape, 0, .{}) == null);
    // Return in the address bar is the entry's own activate, not the pane's.
    try testing.expect(classify(keyval.Return, 0, .{ .address = true }) == null);
    try testing.expectEqual(KeyAction{ .field = .find_previous }, classify(keyval.Return, shift, .{ .find = true, .find_open = true }).?);
}

test "T3412: zoom steps are the Mac's" {
    try testing.expectApproxEqAbs(@as(f64, 1.1), steppedZoom(1.0, .zoom_in), 1e-9);
    try testing.expectEqual(@as(f64, 3.0), steppedZoom(3.0, .zoom_in));
    try testing.expectEqual(@as(f64, 1.0), steppedZoom(2.2, .reset));
}
