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

/// Whether a pane in `mode` has text to search (Mac's `canFind`). A picture
/// does not, and the honest answer to Ctrl+F there is to DECLINE the chord -
/// it falls through to the app's bindings and no card appears - rather than
/// open a card that can only ever say "No results". Ctrl+G is declined there
/// for the same reason. Every other mode searches: markdown, code, a local
/// page, a website, a diff.
pub fn canFind(mode: content.Mode) bool {
    return mode != .image;
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
// App keybindings from a viewer pane (T3430)
// -------------------------------------------------------------------------
//
// A chord the pane does not claim (`classify` returned null) may still be an
// app keybinding: Ctrl+Shift+O splits, Alt+2 picks a tab, a user's own
// `keybind = ctrl+k=new_window`. A terminal pane performs those through its
// core surface's key callback; a viewer pane has no core surface, so before
// this only the handful of actions GTK mirrors as GtkApplication
// accelerators answered from one. The rule is win32's (T1803, Mac
// `ViewerKeyFallback`): **a chord the pane does not claim reaches Ghoztty's
// bindings exactly as it would from a focused terminal, minus the bindings
// that need a terminal** (`Binding.Action.requires`).

pub const Route = accel.Route;

/// The keysyms `offersToApp` asks the shared text tables about, beyond the
/// chord keys `vkForKeyval` knows (gdk/gdkkeysyms.h).
pub const edit_keyval = struct {
    pub const Tab: u32 = 0xff09;
    pub const ISO_Left_Tab: u32 = 0xfe20;
    pub const BackSpace: u32 = 0xff08;
    pub const Delete: u32 = 0xffff;
    pub const Insert: u32 = 0xff63;
    pub const Home: u32 = 0xff50;
    pub const Left: u32 = 0xff51;
    pub const Up: u32 = 0xff52;
    pub const Right: u32 = 0xff53;
    pub const Down: u32 = 0xff54;
    pub const End: u32 = 0xff57;
    pub const KP_Home: u32 = 0xff95;
    pub const KP_Left: u32 = 0xff96;
    pub const KP_Up: u32 = 0xff97;
    pub const KP_Right: u32 = 0xff98;
    pub const KP_Down: u32 = 0xff99;
    pub const KP_End: u32 = 0xff9c;
    pub const KP_Delete: u32 = 0xff9f;
};

/// `vkForKeyval`, widened to the keys the shared text tables
/// (`viewer_accel.pageOwns` / `fieldOffers`) are written in: digits, Tab,
/// the arrows, Home/End, Backspace/Delete/Insert. Null for anything else.
pub fn textVkForKeyval(kv: u32) ?u16 {
    if (kv >= '0' and kv <= '9') return @intCast(kv);
    return switch (kv) {
        edit_keyval.Tab, edit_keyval.ISO_Left_Tab => 0x09,
        edit_keyval.BackSpace => 0x08,
        edit_keyval.Delete, edit_keyval.KP_Delete => 0x2E,
        edit_keyval.Insert => 0x2D,
        edit_keyval.Home, edit_keyval.KP_Home => 0x24,
        edit_keyval.End, edit_keyval.KP_End => 0x23,
        edit_keyval.Left, edit_keyval.KP_Left => 0x25,
        edit_keyval.Up, edit_keyval.KP_Up => 0x26,
        edit_keyval.Right, edit_keyval.KP_Right => 0x27,
        edit_keyval.Down, edit_keyval.KP_Down => 0x28,
        else => vkForKeyval(kv),
    };
}

/// Whether an unclaimed key press in a viewer pane may be offered to the
/// app's keybind table at all (T3430). The capture-phase controller sees a
/// key BEFORE the page or the focused field does - WebView2's accelerator
/// event has the same shape - so their first claim is spelled out, as on
/// win32:
///
/// - **A field of ours has the caret** (the address, the find query, the
///   diff filter): typing stays typing. Only a chord with Ctrl, Alt or Super
///   is offered, minus the field's own editing chords (`fieldOffers`: copy,
///   paste, undo, word movement and selection, zoom). Mac's menu key
///   equivalents fire from a focused text field; this is that.
/// - **The page has it**: everything except the page's own editing and
///   text-navigation chords (`pageOwns`: Ctrl+C/V/X/A/Z/Y, Ctrl+arrows ...).
pub fn offersToApp(kv: u32, state: u32, focus: FieldFocus) bool {
    const mods = modsFromGdk(state);
    const vk = textVkForKeyval(kv);
    if (focus.address or focus.find or focus.diff_filter) {
        if (!mods.ctrl and !mods.alt and !mods.super) return false;
        return if (vk) |v| accel.fieldOffers(v, mods) else true;
    }
    if (vk) |v| if (accel.pageOwns(v, mods)) return false;
    return true;
}

/// The key event the binding table is asked about for a key press in a
/// viewer pane: the press of `key` (the physical key, as the terminal path
/// resolves it) whose unshifted codepoint is `unshifted`. No UTF-8: nothing
/// is ever encoded from here, and `Binding.Set.getEvent` matches on the
/// physical key, then on the unshifted codepoint - how `ctrl+shift+o`-style
/// defaults are stored. Null for a bare modifier or an unknown key with no
/// codepoint, which no binding can name.
pub fn keyEventFor(key: input.Key, unshifted: u21, mods: input.Mods) ?input.KeyEvent {
    if (key.modifier()) return null;
    if (key == .unidentified and unshifted == 0) return null;
    return .{
        .action = .press,
        .key = key,
        .mods = mods,
        .consumed_mods = .{},
        .utf8 = "",
        .unshifted_codepoint = unshifted,
    };
}

/// Whether the GTK frontend acts on a focused viewer pane ITSELF for this
/// action (`Application.performViewerBinding`), the way a terminal pane's
/// core surface would have: the split, close and zoom act on the viewer, the
/// tab and window ones on the viewer's own window. Win32's `nativeTag`, cut
/// to what GTK implements - an action GTK does not perform for a terminal
/// either (hero mode, the sidebar, stash) is not offered from a viewer.
/// App-scoped actions are not here: the core performs them with no surface.
pub fn nativeTag(tag: std.meta.Tag(input.Binding.Action)) bool {
    return switch (tag) {
        .new_tab,
        .close_tab,
        .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        .move_tab,
        .close_window,
        .toggle_fullscreen,
        .toggle_maximize,
        .toggle_tab_overview,
        .toggle_window_decorations,
        .toggle_command_palette,
        .prompt_tab_title,
        .prompt_window_title,
        .equalize_splits,
        .new_split,
        .goto_split,
        .swap_split,
        .resize_split,
        .toggle_split_zoom,
        .close_surface,
        => true,
        else => false,
    };
}

pub fn native(action: input.Binding.Action) bool {
    return nativeTag(std.meta.activeTag(action));
}

/// Where a bound chord from a focused viewer pane goes (T3430) - win32's
/// `viewer_accel.route` with GTK's native set:
///
/// - `.pass`: not ours. Anything a terminal is needed for (`text:`, copy and
///   paste, font size, scrolling, search) - performed through another
///   terminal it would type into a shell the user is not looking at.
/// - `.native`: performed on the viewer by `performViewerBinding`.
/// - `.core`: `App.performBindingForNonTerminal` - app actions with no
///   surface, window actions through a terminal in the same window
///   (`has_host_surface`); a viewer-only window has none.
pub fn route(leaf: *const input.Binding.Set.GenericLeaf, has_host_surface: bool) Route {
    const actions = leaf.actionsSlice();
    if (actions.len == 0) return .pass;
    if (leaf.flags.global or leaf.flags.all) return .core;

    var requires: input.Binding.Action.Requires = .app;
    for (actions) |action| {
        const r = action.requires();
        if (@intFromEnum(r) > @intFromEnum(requires)) requires = r;
    }
    if (requires == .terminal) return .pass;

    if (actions.len == 1 and native(actions[0])) return .native;

    return switch (requires) {
        .app => .core,
        .window => if (has_host_surface) .core else .pass,
        // Through a terminal it would act on THAT terminal's pane.
        .pane, .terminal => .pass,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn leafOf(action: input.Binding.Action) input.Binding.Set.GenericLeaf {
    return .{ .flags = .{}, .actions = .{ .single = .{action} } };
}

test "T3430: typing in a field of ours stays typing" {
    const addr: FieldFocus = .{ .address = true };
    // Plain and shifted keys never leave the field.
    try testing.expect(!offersToApp('d', 0, addr));
    try testing.expect(!offersToApp('D', shift, addr));
    try testing.expect(!offersToApp(edit_keyval.Left, shift, addr));
    try testing.expect(!offersToApp(edit_keyval.Delete, 0, .{ .find = true }));
    // The field's own editing chords stay too.
    try testing.expect(!offersToApp('c', ctrl, addr));
    try testing.expect(!offersToApp('v', ctrl, addr));
    try testing.expect(!offersToApp('z', ctrl, addr));
    try testing.expect(!offersToApp('Z', ctrl | shift, addr));
    try testing.expect(!offersToApp(edit_keyval.Left, ctrl | shift, addr));
    try testing.expect(!offersToApp(edit_keyval.BackSpace, ctrl, addr));
    try testing.expect(!offersToApp(edit_keyval.BackSpace, alt, addr));
    try testing.expect(!offersToApp('=', ctrl, addr));
    // App chords leave it.
    try testing.expect(offersToApp('O', ctrl | shift, addr));
    try testing.expect(offersToApp('T', ctrl | shift, .{ .diff_filter = true }));
    try testing.expect(offersToApp('2', alt, .{ .find = true }));
    try testing.expect(offersToApp(edit_keyval.Tab, ctrl, addr));
}

test "T3430: the page keeps its own editing chords, the rest is offered" {
    const none: FieldFocus = .{};
    for ([_]u32{ 'c', 'v', 'x', 'a', 'z', 'y' }) |kv| {
        try testing.expect(!offersToApp(kv, ctrl, none));
    }
    try testing.expect(!offersToApp('Z', ctrl | shift, none));
    try testing.expect(!offersToApp(edit_keyval.Left, ctrl, none));
    try testing.expect(!offersToApp(edit_keyval.Home, ctrl, none));
    // Copy is Ctrl+Shift+C on Linux, and a terminal binding: offered here,
    // and then `route` passes it, so the page keeps it after all.
    try testing.expect(offersToApp('C', ctrl | shift, none));
    try testing.expect(offersToApp('O', ctrl | shift, none));
    // Ctrl+Shift+arrows: Windows binds them to tabs; offered from the page.
    try testing.expect(offersToApp(edit_keyval.Left, ctrl | shift, none));
    // A key the text tables do not name (Page Up) is offered.
    try testing.expect(offersToApp(0xff55, ctrl, none));
}

test "T3430: the keys the text tables read map onto their virtual keys" {
    try testing.expectEqual(@as(?u16, 0x31), textVkForKeyval('1'));
    try testing.expectEqual(@as(?u16, 0x25), textVkForKeyval(edit_keyval.Left));
    try testing.expectEqual(@as(?u16, 0x25), textVkForKeyval(edit_keyval.KP_Left));
    try testing.expectEqual(@as(?u16, 0x09), textVkForKeyval(edit_keyval.ISO_Left_Tab));
    try testing.expectEqual(@as(?u16, 0x2E), textVkForKeyval(edit_keyval.Delete));
    try testing.expectEqual(@as(?u16, 0x52), textVkForKeyval('r'));
    try testing.expectEqual(@as(?u16, null), textVkForKeyval(0xffbe)); // F1
}

test "T3430: a key event for the binding table carries no text" {
    const ev = keyEventFor(.key_o, 'o', .{ .ctrl = true, .shift = true }).?;
    try testing.expectEqual(input.Key.key_o, ev.key);
    try testing.expectEqual(@as(u21, 'o'), ev.unshifted_codepoint);
    try testing.expectEqual(@as(usize, 0), ev.utf8.len);
    try testing.expectEqual(input.Action.press, ev.action);
    try testing.expect(keyEventFor(.shift_left, 0, .{}) == null);
    try testing.expect(keyEventFor(.unidentified, 0, .{ .ctrl = true }) == null);
    try testing.expect(keyEventFor(.unidentified, 'x', .{ .ctrl = true }) != null);
}

test "T3430: no terminal action is ever routed out of a viewer" {
    const terminal_actions = [_]input.Binding.Action{
        .{ .text = "x" },
        .{ .copy_to_clipboard = .mixed },
        .{ .paste_from_clipboard = {} },
        .{ .increase_font_size = 1 },
        .{ .scroll_page_up = {} },
        .{ .start_search = {} },
        .{ .clear_screen = {} },
    };
    for (terminal_actions) |a| {
        const leaf = leafOf(a);
        try testing.expectEqual(Route.pass, route(&leaf, true));
        try testing.expectEqual(Route.pass, route(&leaf, false));
    }
}

test "T3430: pane and window actions act on the viewer itself" {
    const natives = [_]input.Binding.Action{
        .{ .new_split = .right },
        .{ .goto_split = .previous },
        .{ .toggle_split_zoom = {} },
        .{ .close_surface = {} },
        .{ .new_tab = {} },
        .{ .goto_tab = 2 },
        .{ .close_tab = .this },
        .{ .toggle_command_palette = {} },
    };
    for (natives) |a| {
        const leaf = leafOf(a);
        // With or without a terminal anywhere in the window: a viewer-only
        // window still splits, closes and opens the palette.
        try testing.expectEqual(Route.native, route(&leaf, false));
        try testing.expectEqual(Route.native, route(&leaf, true));
    }
}

test "T3430: app actions go to the core, window actions need a host" {
    const quit = leafOf(.{ .quit = {} });
    try testing.expectEqual(Route.core, route(&quit, false));
    const nw = leafOf(.{ .new_window = {} });
    try testing.expectEqual(Route.core, route(&nw, false));
    // A window action GTK has no viewer handler for goes through a terminal
    // in the window, and passes in a viewer-only one.
    const wf = leafOf(.{ .toggle_window_float_on_top = {} });
    try testing.expectEqual(Route.core, route(&wf, true));
    try testing.expectEqual(Route.pass, route(&wf, false));
    // A pane action with no viewer handler never goes through a terminal.
    const stash = leafOf(.{ .stash_pane = {} });
    try testing.expectEqual(Route.pass, route(&stash, true));
}

test "T3430: every native action needs no terminal" {
    inline for (@typeInfo(input.Binding.Action).@"union".fields) |f| {
        const tag = @field(std.meta.Tag(input.Binding.Action), f.name);
        if (nativeTag(tag)) {
            const a = @unionInit(input.Binding.Action, f.name, undefined);
            try testing.expect(a.requires() != .terminal);
        }
    }
}

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

test "T3414: every mode but a picture has text to find" {
    inline for (.{ .markdown, .code, .html, .web, .diff }) |m| try testing.expect(canFind(m));
    try testing.expect(!canFind(.image));
}

test "T3414: the find card's keys follow the shared precedence" {
    // Return steps only from the find field; Shift+Return goes back.
    try testing.expectEqual(KeyAction{ .field = .find_next }, classify(keyval.Return, 0, .{ .find = true, .find_open = true }).?);
    try testing.expectEqual(KeyAction{ .field = .find_next }, classify(keyval.KP_Enter, 0, .{ .find = true, .find_open = true }).?);
    try testing.expect(classify(keyval.Return, 0, .{ .find_open = true }) == null);
    // Escape closes find from the field AND from the page.
    try testing.expectEqual(KeyAction{ .field = .close_find }, classify(keyval.Escape, 0, .{ .find = true, .find_open = true }).?);
    // F3 / Shift+F3 are the Windows (and GTK browser) spelling of Ctrl+G.
    try testing.expectEqual(KeyAction{ .pane = .find_next }, classify(keyval.F3, 0, .{}).?);
    try testing.expectEqual(KeyAction{ .pane = .find_previous }, classify(keyval.F3, shift, .{}).?);
    // Zoom is not claimed while the caret is in the find field.
    try testing.expect(classify('=', ctrl, .{ .find = true, .find_open = true }) == null);
}

test "T3412: zoom steps are the Mac's" {
    try testing.expectApproxEqAbs(@as(f64, 1.1), steppedZoom(1.0, .zoom_in), 1e-9);
    try testing.expectEqual(@as(f64, 3.0), steppedZoom(3.0, .zoom_in));
    try testing.expectEqual(@as(f64, 1.0), steppedZoom(2.2, .reset));
}
