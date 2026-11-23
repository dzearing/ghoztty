//! The GTK viewer's link plane, the pure half (T3415, Linux L9f).
//!
//! Where a link the page navigates to goes, where a popup goes, and what the
//! right-click menu on a link offers - every one of those is already decided,
//! and tested in every lane, by the win32 port: `viewer_content.classifyLink`
//! (markdown/code links out, the live-page same-site rule), `viewer_popup`
//! (popups to the browser unless Ctrl-clicked), `banner_link` (the modifier
//! scheme and the menu's rows). This module decides none of it again. It maps
//! what WebKitGTK reports onto those functions, so the three platforms cannot
//! drift on where a click lands.
//!
//! Two translations are GTK's own:
//!
//! - **The origins.** WebView2 has no custom schemes, so win32 serves the
//!   template from `https://ghoztty-viewer/` and a rendered page from
//!   `https://ghoztty-page/`. WebKitGTK has them, and the Linux viewer uses the
//!   Mac's `ghoztty-viewer://page/` and `ghoztty-page://page/` instead
//!   (`viewer_scheme.zig`). `canonical` rewrites ours into win32's spelling
//!   before a URI meets the shared rules, so a relative doc link is still
//!   `.relative`, a rendered page still has a "site" to leave, and nothing in
//!   the shared code has to know a third spelling exists.
//! - **Which navigation is a click.** WebView2 reports a navigation KIND and
//!   `IsUserInitiated`; WebKit reports the Mac's own `navigationType`, so this
//!   is the Mac's rule verbatim: only `.linkActivated` (`LINK_CLICKED`) is ever
//!   routed, and a redirect is the page answering the click, not a second
//!   click. The pane's own loads (`load_uri`: `--view`, the address bar,
//!   Home, a reload) are `OTHER`/`RELOAD`, so unlike win32 there is no
//!   "this navigation is mine" counter to keep.
//!
//! No GTK or WebKit imports, so the none lane runs these tests on every seat.
const std = @import("std");

const scheme = @import("viewer_scheme.zig");
const content = @import("../win32/viewer_content.zig");
const popup = @import("../win32/viewer_popup.zig");
const banner_link = @import("../win32/banner_link.zig");
const url_scheme = @import("../ipc/url_scheme.zig");

pub const Action = banner_link.Action;
pub const Kind = banner_link.Kind;
pub const MenuTarget = content.MenuTarget;

// -------------------------------------------------------------------------
// The origins, in win32's spelling
// -------------------------------------------------------------------------

/// Longest URI `canonical` rewrites; a longer one is passed through as
/// written, which the shared rules then read as "not ours".
pub const max_uri = 8192;

/// `uri` with our two custom-scheme origins rewritten to win32's synthetic
/// hosts - `ghoztty-viewer://page/x.md?q` -> `https://ghoztty-viewer/x.md?q`,
/// `ghoztty-page://page/a.html` -> `https://ghoztty-page/a.html` - and every
/// other URI returned unchanged. Written into `buf` when rewritten.
pub fn canonical(buf: []u8, uri: []const u8) []const u8 {
    const pairs = .{
        .{ scheme.template_origin, "https://" ++ content.virtual_host },
        .{ scheme.page_origin, "https://" ++ content.page_virtual_host },
    };
    inline for (pairs) |p| {
        const ours = p[0];
        const theirs = p[1];
        if (uri.len >= ours.len and std.ascii.eqlIgnoreCase(uri[0..ours.len], ours) and
            (uri.len == ours.len or uri[ours.len] == '/' or uri[ours.len] == '?' or uri[ours.len] == '#'))
        {
            const rest = uri[ours.len..];
            if (theirs.len + rest.len > buf.len) return uri;
            @memcpy(buf[0..theirs.len], theirs);
            @memcpy(buf[theirs.len..][0..rest.len], rest);
            return buf[0 .. theirs.len + rest.len];
        }
    }
    return uri;
}

// -------------------------------------------------------------------------
// Navigations
// -------------------------------------------------------------------------

/// `WebKitNavigationType` (webkit/WebKitNavigationAction.h).
pub const NavType = enum(c_int) {
    link_clicked = 0,
    form_submitted = 1,
    back_forward = 2,
    reload = 3,
    form_resubmitted = 4,
    other = 5,
    _,
};

/// `GdkModifierType` bits a link click reads (gdk/gdkenums.h). Linux takes
/// the Windows modifier, Ctrl, for the Mac's Cmd (the port's standing rule).
pub const gdk_shift_mask: u32 = 1 << 0;
pub const gdk_control_mask: u32 = 1 << 2;

pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,

    pub fn fromGdk(state: u32) Mods {
        return .{
            .ctrl = state & gdk_control_mask != 0,
            .shift = state & gdk_shift_mask != 0,
        };
    }
};

/// What a top-level navigation in a viewer pane does. The Viewer acts on it:
/// `allow` lets WebKit carry on, everything else ignores the navigation (the
/// pane stays where it is) and then does what the case names.
pub const Decision = enum {
    /// Follow it in the pane.
    allow,
    /// A markdown/code pane's http(s) link: the default browser.
    browser,
    /// A relative link in the rendered document: resolve it beside the
    /// viewed file (`requestPath` + `navCandidate`/`rootedCandidate`).
    relative,
    /// An explicit `file://` link: the file it names (`content.filePath`).
    file_url,
    /// Cancel it and do nothing (Mac's nil file URL: `mailto:`, `about:`...).
    drop,
    /// A `ghoztty://` link: raise what it names, in process (T695).
    command,
    /// A click out of a live page's own site: the banner's modifier scheme
    /// (`livePageAction`) - plain to the browser, Ctrl a side pane,
    /// Ctrl+Shift a window of its own (T825/T926).
    live_link,
};

/// Decide a navigation. `mode` is the pane's, `page` the URI it has committed
/// (WebKit's `uri` before this navigation commits; null before the first),
/// `uri` the target, `nav_type` and `is_redirect` WebKit's own answers.
pub fn decide(
    mode: content.Mode,
    page: ?[]const u8,
    uri: []const u8,
    nav_type: NavType,
    is_redirect: bool,
) Decision {
    var ubuf: [max_uri]u8 = undefined;
    var pbuf: [max_uri]u8 = undefined;
    const u = canonical(&ubuf, uri);
    const p: ?[]const u8 = if (page) |pg| canonical(&pbuf, pg) else null;
    const class = content.classifyLink(mode, p, u);

    // A `ghoztty://` link is answered for every navigation, in every mode:
    // WebKit cannot load the scheme, and handing it to the desktop would
    // reach whichever BUILD registered it (win32's T695 reasoning).
    if (class == .ghoztty_command) return .command;

    // Only a click is routed (Mac `.linkActivated`). Back/Forward, reloads,
    // the pane's own loads and a page's form posts and script navigations
    // are all followed in place - `syncCommitted` reads where they landed.
    const clicked = nav_type == .link_clicked and !is_redirect;

    if (mode.isLivePage()) {
        return if (class == .browser and clicked) .live_link else .allow;
    }
    if (!clicked) return .allow;
    return switch (class) {
        .allow => .allow,
        .browser => .browser,
        .relative => .relative,
        .file_url => .file_url,
        .drop => .drop,
        .ghoztty_command => unreachable, // answered above
    };
}

/// What a click out of a live page does with `mods` held (T926):
/// `content.livePageLinkAction`, which is `banner_link.clickAction` on the
/// link's kind.
pub fn livePageAction(uri: []const u8, mods: Mods) Action {
    return content.livePageLinkAction(uri, mods.ctrl, mods.shift);
}

/// The path a relative link in the rendered document asks for, decoded into
/// `buf` (`ghoztty-viewer://page/docs/a%20b.md` -> `docs/a b.md`), or null
/// when `uri` is not under the template origin.
pub fn relativePath(buf: []u8, uri: []const u8) ?[]const u8 {
    return scheme.requestPath(buf, .template, uri);
}

/// The path a link inside a rendered `.html` page asks for, decoded into
/// `buf`, or null when `uri` is not under the page origin.
pub fn pagePath(buf: []u8, uri: []const u8) ?[]const u8 {
    return scheme.requestPath(buf, .page, uri);
}

// -------------------------------------------------------------------------
// Popups (`target="_blank"`, `window.open()`)
// -------------------------------------------------------------------------

/// Where a popup goes.
pub const PopupRoute = enum {
    /// The default browser (`viewer_popup.destination`'s `.default_browser`).
    browser,
    /// A `ghoztty://` link: raise what it names; no window opens.
    command,
    /// A Ctrl-click out of a live page is a link click, not a popup: it takes
    /// the banner's modifier scheme (`viewer_popup.modifiedLivePageLink`).
    live_link,
    /// Keep it in Ghoztty as its own viewer window: a Ctrl-click, a bare
    /// `window.open()`, or a scheme the browser cannot be handed.
    ghoztty_window,
};

/// Decide a popup. `uri` is the request's (null for a bare `window.open()`),
/// `user_gesture` WebKit's `is_user_gesture` - the Mac's modifier lives ON
/// the navigation action, so the Ctrl hatch is a click's by construction;
/// it is paired with the gesture anyway, so the rule is the shared one.
pub fn decidePopup(
    mode: content.Mode,
    page: ?[]const u8,
    uri: ?[]const u8,
    mods: Mods,
    user_gesture: bool,
) PopupRoute {
    if (uri) |u| if (mode.isLivePage()) {
        const cross_site = if (page) |pg| decide(mode, pg, u, .link_clicked, false) == .live_link else false;
        if (popup.modifiedLivePageLink(true, cross_site, mods.ctrl, user_gesture)) return .live_link;
    };
    return switch (popup.destination(uri, mods.ctrl, user_gesture)) {
        .default_browser => .browser,
        .ghoztty_command => .command,
        .ghoztty_window => .ghoztty_window,
    };
}

/// An adopted popup's window size, in GTK's logical pixels (T3447).
pub const PopupSize = popup.Size;

/// The size an adopted popup's page asked for (`window.open(u, n,
/// "width=W,height=H")`), from WebKit's window-properties geometry, or null
/// when it asked for none (WebKit leaves a dimension it was not given at 0).
/// win32's `requestedSize` and its clamp, at scale 1: the geometry is CSS
/// pixels and a GTK window is sized in logical pixels, which are the same
/// unit - the compositor does the scaling Windows makes the app do by hand.
pub fn popupSize(width: c_int, height: c_int) ?PopupSize {
    if (width <= 0 or height <= 0) return null;
    return popup.requestedSize(true, @intCast(width), @intCast(height), 1.0);
}

test "popupSize: what the page asked for, clamped like win32's, or nothing" {
    try testing.expectEqual(PopupSize{ .w = 500, .h = 400 }, popupSize(500, 400).?);
    // A dimension the page did not give is 0: no size, the ordinary default.
    try testing.expect(popupSize(0, 400) == null);
    try testing.expect(popupSize(500, 0) == null);
    try testing.expect(popupSize(-1, -1) == null);
    // Too small to use is raised to the floor; absurd is held to the cap.
    try testing.expectEqual(PopupSize{ .w = popup.min_dim, .h = popup.min_dim }, popupSize(20, 20).?);
    try testing.expectEqual(popup.max_dim, popupSize(std.math.maxInt(c_int), 300).?.w);
}

// -------------------------------------------------------------------------
// The link menu
// -------------------------------------------------------------------------

/// What a right-clicked `href` names (`viewer_content.linkMenuTarget`, on the
/// canonical spelling): a relative doc link or a link inside a rendered page
/// is a FILE, which is what the menu acts on.
pub fn menuTarget(href: []const u8) MenuTarget {
    var buf: [max_uri]u8 = undefined;
    return content.linkMenuTarget(canonical(&buf, href));
}

pub const max_items = banner_link.MAX_ITEMS;

/// One row of the menu: banner_link's id, with the Linux title.
pub const Item = union(enum) {
    separator,
    cmd: struct { id: banner_link.Id, title: [:0]const u8, action_name: [:0]const u8 },
};

/// The menu for a link of `kind` - banner_link's rows, order and ids (the
/// left-click default first), so the viewer and the banner menus cannot
/// fork. Only the titles are this platform's.
pub fn menu(kind: Kind, buf: *[max_items]Item) []const Item {
    var rows: [banner_link.MAX_ITEMS]banner_link.Item = undefined;
    const built = banner_link.build(kind, &rows);
    for (built, 0..) |row, i| buf[i] = switch (row) {
        .separator => .separator,
        .cmd => |c| .{ .cmd = .{ .id = c.id, .title = title(c.id, kind), .action_name = actionName(c.id) } },
    };
    return buf[0..built.len];
}

/// The Linux wording. The reveal row is the nav bar's own button's
/// ("Open Containing Folder", GTK's `open_containing_folder`): Finder and
/// File Explorer have no single Linux counterpart, and the file manager is
/// whatever the desktop's FileManager1 is.
pub fn title(id: banner_link.Id, kind: Kind) [:0]const u8 {
    return switch (id) {
        .open_browser => "Open in Default Browser",
        .reveal => "Open Containing Folder",
        .side_pane => "Open in Side Pane",
        .new_window => "Open in New Window",
        .open_default_app => "Open with Default App",
        .copy => if (kind == .file) "Copy Path" else "Copy Link",
        .focus => "Focus in Ghoztty",
    };
}

/// The `GAction` name a row activates (in the menu's own action group).
pub fn actionName(id: banner_link.Id) [:0]const u8 {
    return switch (id) {
        inline else => |t| @tagName(t),
    };
}

/// The id behind an action name, or null for a name the menu never made.
pub fn idFromActionName(name: []const u8) ?banner_link.Id {
    inline for (@typeInfo(banner_link.Id).@"enum".fields) |f| {
        if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

pub fn actionFor(id: banner_link.Id) Action {
    return banner_link.action(id);
}

pub fn isCommand(uri: []const u8) bool {
    return url_scheme.handles(uri);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "canonical: our origins take win32's spelling, everything else is untouched" {
    var buf: [max_uri]u8 = undefined;
    try testing.expectEqualStrings("https://ghoztty-viewer/docs/a.md", canonical(&buf, "ghoztty-viewer://page/docs/a.md"));
    try testing.expectEqualStrings("https://ghoztty-viewer/viewer.html?file=%2Fx.md", canonical(&buf, "ghoztty-viewer://page/viewer.html?file=%2Fx.md"));
    try testing.expectEqualStrings("https://ghoztty-page/two.html#top", canonical(&buf, "ghoztty-page://page/two.html#top"));
    try testing.expectEqualStrings("https://ghoztty-page", canonical(&buf, "ghoztty-page://page"));
    // Another authority on our scheme, a lookalike, and the web are not ours.
    try testing.expectEqualStrings("ghoztty-page://pages/x", canonical(&buf, "ghoztty-page://pages/x"));
    try testing.expectEqualStrings("https://example.com/", canonical(&buf, "https://example.com/"));
    try testing.expectEqualStrings("file:///tmp/a.md", canonical(&buf, "file:///tmp/a.md"));
    // Too long to rewrite: passed through, which the rules read as not ours.
    var small: [8]u8 = undefined;
    try testing.expectEqualStrings("ghoztty-viewer://page/x.md", canonical(&small, "ghoztty-viewer://page/x.md"));
}

test "decide: a markdown pane's links leave or open beside it, only on a click" {
    const page = "ghoztty-viewer://page/viewer.html?file=%2Fdocs%2FREADME.md";
    try testing.expectEqual(Decision.browser, decide(.markdown, page, "https://example.com/x", .link_clicked, false));
    try testing.expectEqual(Decision.relative, decide(.markdown, page, "ghoztty-viewer://page/other.md", .link_clicked, false));
    try testing.expectEqual(Decision.file_url, decide(.code, page, "file:///etc/hosts", .link_clicked, false));
    try testing.expectEqual(Decision.drop, decide(.markdown, page, "mailto:a@b.c", .link_clicked, false));
    // The template itself, and every navigation that is not a click, stays.
    try testing.expectEqual(Decision.allow, decide(.markdown, page, "ghoztty-viewer://page/viewer.html?file=%2Fy.md", .link_clicked, false));
    try testing.expectEqual(Decision.allow, decide(.markdown, page, "ghoztty-viewer://page/viewer.html?file=%2Fy.md", .back_forward, false));
    try testing.expectEqual(Decision.allow, decide(.markdown, page, "https://example.com/", .other, false));
    try testing.expectEqual(Decision.allow, decide(.markdown, page, "https://example.com/", .reload, false));
    try testing.expectEqual(Decision.allow, decide(.markdown, page, "https://example.com/", .link_clicked, true));
    try testing.expectEqual(Decision.allow, decide(.markdown, page, "https://example.com/", .form_submitted, false));
}

test "decide: a ghoztty link is a command for every navigation, in every mode" {
    for ([_]content.Mode{ .markdown, .html, .web }) |m| {
        try testing.expectEqual(Decision.command, decide(m, null, "ghoztty://focus/dev", .other, false));
        try testing.expectEqual(Decision.command, decide(m, "https://a.test/", "ghoztty-debug://focus/x", .link_clicked, false));
    }
}

test "decide: a live page follows its own site and routes a click off it" {
    const site = "https://a.test:3000/app";
    try testing.expectEqual(Decision.allow, decide(.web, site, "https://a.test:3000/other", .link_clicked, false));
    // http -> https on one host is the same site (the scheme is excluded).
    try testing.expectEqual(Decision.allow, decide(.web, "http://a.test/", "https://a.test/x", .link_clicked, false));
    try testing.expectEqual(Decision.live_link, decide(.web, site, "https://a.test:5173/", .link_clicked, false));
    try testing.expectEqual(Decision.live_link, decide(.web, site, "https://sub.a.test:3000/", .link_clicked, false));
    try testing.expectEqual(Decision.live_link, decide(.web, site, "file:///tmp/x.html", .link_clicked, false));
    // The page's own redirects, posts and script loads stay with the page.
    try testing.expectEqual(Decision.allow, decide(.web, site, "https://b.test/", .link_clicked, true));
    try testing.expectEqual(Decision.allow, decide(.web, site, "https://b.test/", .other, false));
    try testing.expectEqual(Decision.allow, decide(.web, site, "https://b.test/", .form_submitted, false));
    // Before the first commit there is no site to leave.
    try testing.expectEqual(Decision.allow, decide(.web, null, "https://b.test/", .link_clicked, false));
    // Other schemes are page machinery.
    try testing.expectEqual(Decision.allow, decide(.web, site, "javascript:void(0)", .link_clicked, false));
}

test "decide: a rendered page's site is its own folder, under our page origin" {
    const page = "ghoztty-page://page/index.html";
    try testing.expectEqual(Decision.allow, decide(.html, page, "ghoztty-page://page/sub/two.html", .link_clicked, false));
    try testing.expectEqual(Decision.live_link, decide(.html, page, "https://example.com/", .link_clicked, false));
    try testing.expectEqual(Decision.live_link, decide(.html, page, "file:///etc/hosts", .link_clicked, false));
}

test "livePageAction: the banner's modifier scheme" {
    try testing.expectEqual(Action.open_with_system, livePageAction("https://b.test/", .{}));
    try testing.expectEqual(Action.open_in_side_pane, livePageAction("https://b.test/", .{ .ctrl = true }));
    try testing.expectEqual(Action.open_in_new_window, livePageAction("https://b.test/", .{ .ctrl = true, .shift = true }));
    try testing.expectEqual(Action.reveal_in_explorer, livePageAction("file:///tmp/x", .{}));
    try testing.expectEqual(Action.open_with_system, livePageAction("file:///tmp/x", .{ .ctrl = true, .shift = true }));
}

test "Mods.fromGdk reads Ctrl and Shift" {
    try testing.expectEqual(Mods{}, Mods.fromGdk(0));
    try testing.expectEqual(Mods{ .ctrl = true }, Mods.fromGdk(gdk_control_mask));
    try testing.expectEqual(Mods{ .ctrl = true, .shift = true }, Mods.fromGdk(gdk_control_mask | gdk_shift_mask | (1 << 3)));
}

test "relativePath / pagePath decode under their own origin only" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("docs/a b.md", relativePath(&buf, "ghoztty-viewer://page/docs/a%20b.md").?);
    try testing.expect(relativePath(&buf, "ghoztty-page://page/x.html") == null);
    try testing.expectEqualStrings("sub/two.html", pagePath(&buf, "ghoztty-page://page/sub/two.html#x").?);
    try testing.expect(pagePath(&buf, "https://ghoztty-page/x.html") == null);
}

test "decidePopup: the browser unless Ctrl-clicked, a bare open stays" {
    const site = "https://a.test/";
    try testing.expectEqual(PopupRoute.browser, decidePopup(.web, site, "https://a.test/pop", .{}, true));
    try testing.expectEqual(PopupRoute.browser, decidePopup(.web, site, "https://b.test/", .{}, false));
    // Ctrl-click: same site keeps the popup here, off site is a link click.
    try testing.expectEqual(PopupRoute.ghoztty_window, decidePopup(.web, site, "https://a.test/pop", .{ .ctrl = true }, true));
    try testing.expectEqual(PopupRoute.live_link, decidePopup(.web, site, "https://b.test/", .{ .ctrl = true }, true));
    // Ctrl with no gesture is somebody's typing, not this click.
    try testing.expectEqual(PopupRoute.browser, decidePopup(.web, site, "https://a.test/pop", .{ .ctrl = true }, false));
    try testing.expectEqual(PopupRoute.ghoztty_window, decidePopup(.web, site, null, .{}, false));
    try testing.expectEqual(PopupRoute.ghoztty_window, decidePopup(.web, site, "about:blank", .{}, false));
    try testing.expectEqual(PopupRoute.ghoztty_window, decidePopup(.web, site, "mailto:a@b.c", .{}, true));
    try testing.expectEqual(PopupRoute.command, decidePopup(.web, site, "ghoztty://focus/dev", .{ .ctrl = true }, true));
    // A rendered page's popup to the web leaves the same way.
    try testing.expectEqual(PopupRoute.browser, decidePopup(.html, "ghoztty-page://page/i.html", "https://b.test/", .{}, true));
}

test "menuTarget: our origins are files, the web is the web" {
    try testing.expectEqual(MenuTarget.viewer_relative, menuTarget("ghoztty-viewer://page/other.md"));
    try testing.expectEqual(MenuTarget.page_relative, menuTarget("ghoztty-page://page/two.html"));
    try testing.expectEqual(MenuTarget.web, menuTarget("https://example.com/"));
    try testing.expectEqual(MenuTarget.file_url, menuTarget("file:///tmp/x.md"));
    try testing.expectEqual(MenuTarget.command, menuTarget("ghoztty://focus/dev"));
    try testing.expectEqual(MenuTarget.none, menuTarget("mailto:a@b.c"));
}

test "menu: banner_link's rows and order, Linux titles" {
    var buf: [max_items]Item = undefined;
    const web = menu(.web, &buf);
    try testing.expectEqual(banner_link.Id.open_browser, web[0].cmd.id);
    try testing.expectEqualStrings("Open in Default Browser", web[0].cmd.title);
    try testing.expectEqualStrings("Copy Link", web[web.len - 1].cmd.title);

    const file = menu(.file, &buf);
    try testing.expectEqual(banner_link.Id.reveal, file[0].cmd.id);
    try testing.expectEqualStrings("Open Containing Folder", file[0].cmd.title);
    try testing.expectEqualStrings("Copy Path", file[file.len - 1].cmd.title);
    var saw_app = false;
    for (file) |it| if (it == .cmd and it.cmd.id == .open_default_app) {
        saw_app = true;
    };
    try testing.expect(saw_app);

    const cmd = menu(.command, &buf);
    try testing.expectEqual(@as(usize, 3), cmd.len);
    try testing.expectEqual(banner_link.Id.focus, cmd[0].cmd.id);
}

test "actionName round-trips through idFromActionName" {
    inline for (@typeInfo(banner_link.Id).@"enum".fields) |f| {
        const id: banner_link.Id = @enumFromInt(f.value);
        try testing.expectEqual(id, idFromActionName(actionName(id)).?);
    }
    try testing.expect(idFromActionName("nope") == null);
}
