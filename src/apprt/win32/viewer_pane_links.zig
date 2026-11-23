//! A viewer pane's link plane (T3436, split out of `ViewerPane.zig` by T1775):
//! where a link the page navigates to actually goes, and the context menu a
//! right-click on a link opens.
//!
//! - **Link routing** - `onNavigationStarting` sees every top-level navigation
//!   and decides, the way Mac's `decidePolicyFor` + `handleFileModeLink` do,
//!   whether it stays in the pane, opens a viewer split, focuses an existing
//!   pane, or leaves for the shell (browser, app, Explorer).
//! - **The link context menu** - `armLinkMenu` / `showLinkMenu` /
//!   `performLinkMenuAction`, the second half of Mac's 18acc4f6f.
//!
//! The functions take `self: *ViewerPane` and are aliased back into
//! `ViewerPane.zig` under its "Split modules" banner, so every `self.f(x)` call
//! site reads as it did before the split. `ViewerPane.link_sink` is the shared
//! test seam that records a routed link instead of opening anything.

const ViewerPane = @import("ViewerPane.zig");

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const com = @import("com.zig");
const iface = @import("webview2_iface.zig");
const frame_iface = @import("webview2_frame_iface.zig");
const webview2 = @import("webview2.zig");
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const type_ramp = @import("type_ramp.zig");
const error_card = @import("viewer_error_card.zig");
const bridge = @import("viewer_bridge.zig");
const content = @import("viewer_content.zig");
const byte_range = @import("viewer_range.zig");
const viewer_watcher = @import("viewer_watcher.zig");
const viewer_accel = @import("viewer_accel.zig");
const window_chord = @import("window_chord.zig");
const viewer_popup = @import("viewer_popup.zig");
const inputpkg = @import("../../input.zig");
const viewer_nav = @import("viewer_nav.zig");
const nav_layout = @import("viewer_nav_layout.zig");
const resize_paint = @import("resize_paint.zig");
const toc_layout = @import("viewer_toc_layout.zig");
const viewer_prefs = @import("viewer_prefs.zig");
const gdiplus_decode = @import("gdiplus_decode.zig");
const view_arg = @import("../../cli/view_arg.zig");
const ViewerNavBar = @import("ViewerNavBar.zig");
const ViewerFeedbackBar = @import("ViewerFeedbackBar.zig");
const ViewerFindBar = @import("ViewerFindBar.zig");
const viewer_find = @import("viewer_find.zig");
const feedback_doc = @import("viewer_feedback_doc.zig");
const feedback_report = @import("viewer_feedback_report.zig");
const feedback_images_mod = @import("viewer_feedback_images.zig");
const ViewerFeedbackSend = @import("ViewerFeedbackSend.zig");
const viewer_worktree = @import("viewer_worktree.zig");
const git_run = @import("git_run.zig");
const ViewerWorktreeProbe = @import("ViewerWorktreeProbe.zig");
const ViewerDiffProbe = @import("ViewerDiffProbe.zig");
const ViewerImageDecode = @import("ViewerImageDecode.zig");
const ViewerDocumentRead = @import("ViewerDocumentRead.zig");
const ViewerResourceServe = @import("ViewerResourceServe.zig");
const viewer_document = @import("viewer_document.zig");
const viewer_scratch = @import("viewer_scratch.zig");
const viewer_diff = @import("viewer_diff.zig");
const hidden_poll = @import("hidden_poll.zig");
const reload_gate = @import("reload_gate.zig");
const viewer_suspend = @import("viewer_suspend.zig");
const viewer_process = @import("viewer_process.zig");
const viewer_image = @import("viewer_image.zig");
const build_config = @import("../../build_config.zig");
const ViewerTOCPanel = @import("ViewerTOCPanel.zig");
const file_tree = @import("viewer_file_tree.zig");
const internal_os = @import("../../os/main.zig");
const pane_id_mod = @import("../ipc/pane_id.zig");
const banner_link = @import("banner_link.zig");
const clipboard_open = @import("clipboard_open.zig");
const image_copy = @import("image_copy.zig");
const image_clipboard = @import("image_clipboard.zig");
const utf16_text = @import("utf16_text.zig");
const DimOverlay = @import("DimOverlay.zig").DimOverlay;
const PaneView = @import("PaneView.zig");
const Window = @import("Window.zig");
const hero_snap_schedule = @import("hero_snap_schedule.zig");
const viewer_glass = @import("viewer_glass.zig");
const pane_elevation = @import("pane_elevation.zig");
const sheet_workers = @import("sheet_workers.zig");
const Dib32 = @import("dib32.zig");
const gl_comp_present = @import("../../renderer/gl_comp_present.zig");
const socket_rw = @import("../../remote/socket_rw.zig");

const Allocator = ViewerPane.Allocator;
const LinkMods = ViewerPane.LinkMods;
const Pending = ViewerPane.Pending;
const WM_APP_VIEWER_LINK_MENU = ViewerPane.WM_APP_VIEWER_LINK_MENU;
const clipboardWriteText = ViewerPane.clipboardWriteText;
const heldLinkMods = ViewerPane.heldLinkMods;
const log = ViewerPane.log;
const releasePendingToken = ViewerPane.releasePendingToken;

// -------------------------------------------------------------------------
// Link routing (T392, design row 5; Mac `decidePolicyFor` + `handleFileModeLink`)
// -------------------------------------------------------------------------

/// `ICoreWebView2NavigationStartingEventHandler`: a top-level navigation is
/// about to happen, and file mode gets to say no.
pub const NavigationStartingHandler = com.CallbackOwning(
    iface.IID_NavigationStartingHandler,
    onNavigationStarting,
    releasePendingToken,
);
pub fn onNavigationStarting(
    p: *Pending,
    sender: ?*iface.ICoreWebView2,
    args: ?*iface.ICoreWebView2NavigationStartingEventArgs,
) com.HRESULT {
    const a = args orelse return com.S_OK;
    const self = p.pane orelse return com.S_OK;

    const raw = a.uriRaw() orelse return com.S_OK;
    // The runtime allocated it on the COM heap; we free it on ours.
    defer w32.CoTaskMemFree(@ptrCast(raw));
    const uri = std.unicode.utf16LeToUtf8Alloc(p.alloc, std.mem.span(raw)) catch return com.S_OK;
    defer p.alloc.free(uri);

    // The document the navigation is LEAVING, which is what tells a hop inside
    // a live page's own site from one out of it (T825). `Source` still names
    // the committed page here: `SourceChanged` fires after this event, not
    // before, so what is read is the page the user is looking at rather than
    // the one being asked for. Null before the pane's first commit, and on the
    // allocation failure — either way the cross-site test declines and the
    // navigation is left alone.
    const page = sourceUtf8(p.alloc, sender);
    defer if (page) |b| p.alloc.free(b);

    // Consumed here, ahead of every branch, so a navigation the pane issued in
    // a mode that ignores it cannot leave the claim standing for the next one
    // (T825). `self_nav` is the answer WebView2 has no field for: this
    // navigation is the pane's own, not something the user clicked.
    const self_nav = self.self_nav_pending > 0;
    self.self_nav_pending -|= 1;

    const class = content.classifyLink(self.mode, page, uri);

    // A `ghoztty://` link is answered in EVERY mode and for every navigation
    // kind, which is why the URI is read before the two gates below (T695).
    // WebView2 cannot load the scheme at all, so letting a website pane's
    // navigation through would be a dead click rather than a passthrough.
    if (class == .ghoztty_command) {
        _ = a.setCancel(true);
        self.focusLinkTarget(uri);
        return com.S_OK;
    }

    // Websites — and rendered `.html` files, which are pages (T601) — navigate
    // freely within the pane, and so do the pane's own reloads and history
    // walks (`syncCommitted` reconciles those after the fact).
    //
    // The one navigation that does NOT stay is a click the user made that
    // leaves the page's own site (T825): this web view's cookie store is
    // nobody else's, so that page would render logged-out here with no way
    // back to the browser. `classifyLink` decided whether the target is off the
    // site; `routesAsLivePageLink` decides whether this was a click at all, so
    // the page's own redirects, scripts and form posts are untouched.
    if (self.mode.isLivePage()) {
        if (class == .browser and content.routesAsLivePageLink(
            navKind(a),
            a.isUserInitiated() and !self_nav,
            a.isRedirected(),
        )) {
            _ = a.setCancel(true);
            // Through the banner's modifier scheme (T926): the gate above has
            // already established a user's click, which is what makes the
            // keyboard read below mean something.
            self.routeLivePageLink(p.alloc, uri, heldLinkMods());
        }
        return com.S_OK;
    }
    if (!content.routesAsLink(navKind(a))) return com.S_OK;

    switch (class) {
        .ghoztty_command => unreachable, // answered above, in every mode
        .allow => {},
        .browser => {
            _ = a.setCancel(true);
            self.openExternal(p.alloc, uri);
        },
        .relative => {
            _ = a.setCancel(true);
            self.openRelativeLink(p.alloc, uri);
        },
        .file_url => {
            _ = a.setCancel(true);
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (content.filePath(&buf, uri)) |path| {
                self.dispatchFileLink(p.alloc, path);
            }
        },
        // Mac's nil-fileURL return: cancelled, and nothing else happens.
        .drop => _ = a.setCancel(true),
    }
    return com.S_OK;
}

/// The document `web` has committed, as UTF-8 the caller frees — or null
/// before the first commit, without a sender, or on an allocation failure.
pub fn sourceUtf8(alloc: Allocator, sender: ?*iface.ICoreWebView2) ?[]u8 {
    const web = sender orelse return null;
    const src = web.sourceRaw() orelse return null;
    defer w32.CoTaskMemFree(@ptrCast(src));
    return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(src)) catch null;
}

/// Send a click that leaves a live page where the banner's modifier scheme
/// says (T926) — `content.livePageLinkAction`, carried out by the same verbs
/// the link menu uses. A file link is acted on as its path; one whose path
/// cannot be decoded goes to the shell as written, which is what every such
/// link did before this.
pub fn routeLivePageLink(self: *ViewerPane, alloc: Allocator, uri: []const u8, mods: LinkMods) void {
    const act = content.livePageLinkAction(uri, mods.ctrl, mods.shift);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = if (std.ascii.startsWithIgnoreCase(uri, "file://"))
        content.filePath(&buf, uri) orelse return self.openExternal(alloc, uri)
    else
        uri;
    self.performLinkMenuAction(alloc, act, target);
}

/// The navigation kind, or null on a runtime whose args predate
/// `ICoreWebView2NavigationStartingEventArgs3`.
pub fn navKind(a: *iface.ICoreWebView2NavigationStartingEventArgs) ?content.NavKind {
    const a3 = a.queryArgs3() orelse return null;
    defer a3.release();
    return switch (a3.navigationKind() orelse return null) {
        .reload => .reload,
        .back_or_forward => .back_or_forward,
        .new_document => .new_document,
        // A kind this build does not know is a kind the policy has no claim
        // about — but it is also not one of the two the pane issues about
        // itself, so it routes the way an unknown runtime does.
        _ => null,
    };
}

/// A clicked RELATIVE link (`https://ghoztty-viewer/<rel>`): resolve it next
/// to the viewed file, and only an existing file opens — Mac's
/// `resolveForNavigation`, existence checks included.
pub fn openRelativeLink(self: *ViewerPane, alloc: Allocator, uri: []const u8) void {
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = content.requestPath(&rel_buf, uri) orelse return;
    const fp = self.file_path orelse return;
    const base = content.baseDirectory(fp) orelse return;

    const first = self.takeIfFile(alloc, content.navCandidate(alloc, base, rel) catch null);
    const path = first orelse
        self.takeIfFile(alloc, content.rootedCandidate(alloc, base, rel) catch null) orelse {
        // Mac returns silently here; the log line is our one addition,
        // because "I clicked and nothing happened" should leave a trace.
        log.info("viewer link names no existing file: {s}", .{rel});
        return;
    };
    defer alloc.free(path);
    self.dispatchFileLink(alloc, path);
}

/// Open a routed FILE target: markdown as a viewer split next to this pane,
/// anything else with its default app (Mac `handleFileModeLink`'s switch).
pub fn dispatchFileLink(self: *ViewerPane, alloc: Allocator, path: []const u8) void {
    switch (content.fileLinkAction(path)) {
        .viewer_split => {
            if (ViewerPane.link_sink) |s| return s.append("split", path);
            self.openLinkedViewerSplit(path);
        },
        .default_app => {
            if (ViewerPane.link_sink) |s| return s.append("app", path);
            self.shellOpen(alloc, path);
        },
    }
}

/// Open another viewer as a split to the RIGHT of this pane (Mac
/// `openViewerSplit`), through the trampoline `Window.createViewerPane`
/// installed. A pane that is not in a tree — a bare unit-test pane — has
/// neither a leaf nor a trampoline, and does nothing.
///
/// The origin travels with the link: a pane opened from a link in this one
/// inherits this one's origin, so a chain of doc links keeps the same
/// provenance (Mac passes `originDirectory` for the same reason).
pub fn openLinkedViewerSplit(self: *ViewerPane, location: []const u8) void {
    const pv = self.pane_view orelse return;
    const open = self.open_link_split orelse return;
    open(pv, location, self.origin_directory);
}

/// A `ghoztty://` link clicked in this pane's page: raise what it names, in
/// process (T695). Never leaves the app and never navigates — the pane keeps
/// showing what it was showing.
pub fn focusLinkTarget(self: *ViewerPane, url: []const u8) void {
    if (ViewerPane.link_sink) |s| return s.append("focus", url);
    const pv = self.pane_view orelse return;
    const window = pv.parentWindow();
    _ = window.app.handleUrlSchemeLink(window.hwnd, self.scale, url);
}

/// Hand `target` (a URL or a file path) to the shell — the default browser
/// for the one, the default app for the other. The same call answers both
/// because that is what `ShellExecuteW(open)` is.
pub fn openExternal(self: *ViewerPane, alloc: Allocator, url: []const u8) void {
    if (ViewerPane.link_sink) |s| return s.append("browser", url);
    self.shellOpen(alloc, url);
}

pub fn shellOpen(self: *ViewerPane, alloc: Allocator, target: []const u8) void {
    _ = self;
    // A test binary must never reach the shell (T594): `ShellExecuteW(open)`
    // launches the user's default browser in the INTERACTIVE session no matter
    // which desktop the test runs on, so a handoff that escapes a green lane
    // is a real Edge window left on the user's screen. Recorded when the test
    // installed a sink; loud otherwise — never executed.
    if (builtin.is_test) {
        if (ViewerPane.link_sink) |s| return s.append("shell", target);
        log.err("test build refused to shell-open: {s}", .{target});
        return;
    }
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, target) catch return;
    defer alloc.free(wide);
    _ = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        wide,
        null,
        null,
        w32.SW_SHOW,
    );
}

// -------------------------------------------------------------------------
// The link context menu (T826; the second half of Mac's 18acc4f6f)
// -------------------------------------------------------------------------

/// A right-click landed on a link the shared `links.js` recognised, and it has
/// already suppressed the page's own menu — so from here a menu is OWED, and
/// every path below either shows one or is a case the script would not have
/// sent.
///
/// The href is resolved to what the menu will act on FIRST, while the pane is
/// still the one the click happened in, and the menu itself is posted a message
/// hop later (`WM_APP_VIEWER_LINK_MENU`) because it is modal.
pub fn armLinkMenu(self: *ViewerPane, alloc: Allocator, href: []const u8) void {
    var kind: banner_link.Kind = .web;
    var target: ?[]u8 = null;
    switch (content.linkMenuTarget(href)) {
        // Nothing this menu has actions for. The shared script filters these
        // schemes out before it ever posts, so reaching here means a page used
        // the bridge directly — it gets no menu and nothing else.
        .none => return,
        .command => {
            kind = .command;
            target = alloc.dupe(u8, href) catch return;
        },
        .web => target = alloc.dupe(u8, href) catch return,
        .file_url => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = content.filePath(&buf, href) orelse return;
            kind = .file;
            target = alloc.dupe(u8, path) catch return;
        },
        // Both synthetic hosts name a FILE, and the menu acts on the file: the
        // URL itself exists only inside this process, so copying it or handing
        // it to the browser would be handing over something dead.
        .viewer_relative => {
            kind = .file;
            target = self.resolveViewerRelative(alloc, href) orelse return;
        },
        .page_relative => {
            kind = .file;
            target = self.resolvePageRelative(alloc, href) orelse return;
        },
    }

    const resolved = target orelse return;
    if (self.link_menu_target) |old| alloc.free(old);
    self.link_menu_target = resolved;
    self.link_menu_kind = kind;

    const hwnd = self.hwnd orelse return;
    _ = w32.PostMessageW(hwnd, WM_APP_VIEWER_LINK_MENU, 0, 0);
}

/// A relative link in the rendered document (`https://ghoztty-viewer/<rel>`),
/// resolved against the viewed file exactly the way a CLICK on it resolves —
/// next to the file first, then rooted at it (`openRelativeLink`).
///
/// The difference from the click is what happens when nothing exists there: a
/// click reveals nothing and logs, while the menu still has to open, so the
/// unchecked candidate is the answer. Copy Path then names the file the link
/// meant, which is the useful thing to hand someone when a doc link is broken.
pub fn resolveViewerRelative(self: *ViewerPane, alloc: Allocator, href: []const u8) ?[]u8 {
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = content.requestPath(&rel_buf, href) orelse return null;
    const fp = self.file_path orelse return null;
    const base = content.baseDirectory(fp) orelse return null;

    if (self.takeIfFile(alloc, content.navCandidate(alloc, base, rel) catch null)) |p| return p;
    if (self.takeIfFile(alloc, content.rootedCandidate(alloc, base, rel) catch null)) |p| return p;
    return content.navCandidate(alloc, base, rel) catch null;
}

/// A link inside a rendered `.html` page (`https://ghoztty-page/<rel>`),
/// resolved against the page host's own read grant — the same root, and the
/// same containment refusal, that serves the page's subresources (T601).
pub fn resolvePageRelative(self: *ViewerPane, alloc: Allocator, href: []const u8) ?[]u8 {
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = content.pageRequestPath(&rel_buf, href) orelse return null;
    const root = self.html_root orelse return null;
    return content.candidateUnder(alloc, root, rel) catch null;
}

/// Pop the menu the right-click earned and run what the user picks (T826).
///
/// Runs from the message loop, not from the web view's callback. The rows, the
/// order and the ids are `banner_link`'s — the same ones a banner link shows —
/// so the two surfaces cannot drift apart, which is the whole reason Mac
/// re-anchored `BannerLinkOpener` on a protocol instead of forking a menu.
pub fn showLinkMenu(self: *ViewerPane, alloc: Allocator) void {
    const target = self.link_menu_target orelse return;
    self.link_menu_target = null;
    defer alloc.free(target);

    const kind = self.link_menu_kind;
    // The test seam the routed-click path already uses: a lane must never pop a
    // modal menu (nothing would dismiss it) or reach the shell, so what the menu
    // WOULD have offered is recorded and the action left to the unit tests of
    // `banner_link`.
    if (ViewerPane.link_sink) |s| {
        var name_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&name_buf, "menu-{s}", .{@tagName(kind)}) catch "menu";
        return s.append(label, target);
    }

    const hwnd = self.hwnd orelse return;
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);
    var buf: [banner_link.MAX_ITEMS]banner_link.Item = undefined;
    for (banner_link.build(kind, &buf)) |item| switch (item) {
        .separator => _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null),
        .cmd => |c| _ = w32.AppendMenuW(menu, w32.MF_STRING, @intFromEnum(c.id), c.title.ptr),
    };

    // At the POINTER rather than at a position the page reported: the shared
    // script sends only the href, and the cursor has not moved between the
    // right-click and this message hop. It is also the coordinate space an
    // iframe would not have shared.
    var pt: w32.POINT = undefined;
    if (w32.GetCursorPos_(&pt) == 0) return;

    // The MSDN pair for a tracked menu whose owner is not foreground, the same
    // one `BannerOverlay.openLinkMenu` uses: foreground the top-level window
    // first so an outside click dismisses the menu, and post it a message after
    // so the menu's own loop exits cleanly.
    const top: ?w32.HWND = if (self.pane_view) |pv| pv.parentWindow().hwnd else null;
    if (top) |t| _ = w32.SetForegroundWindow(t);
    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        hwnd,
        null,
    );
    if (top) |t| _ = w32.PostMessageW(t, w32.WM_NULL, 0, 0);

    const id = std.meta.intToEnum(
        banner_link.Id,
        @as(usize, @intCast(cmd)),
    ) catch return; // 0 = dismissed without choosing
    self.performLinkMenuAction(alloc, banner_link.action(id), target);
}

/// Run one menu action against an already-resolved target. The banner's
/// `performLinkAction` verb for verb, on the viewer's own plumbing.
pub fn performLinkMenuAction(
    self: *ViewerPane,
    alloc: Allocator,
    act: banner_link.Action,
    target: []const u8,
) void {
    switch (act) {
        .open_with_system => self.openExternal(alloc, target),
        // `explorer /select,<path>` opens the containing folder with the file
        // selected — the Windows analog of Mac's Reveal in Finder, and never
        // an app launch for whatever claims the extension. A path that no
        // longer exists opens its nearest surviving folder instead (T1802).
        .reveal_in_explorer => self.revealInExplorer(alloc, target),
        .open_in_side_pane => {
            if (ViewerPane.link_sink) |s| return s.append("split", target);
            self.openLinkedViewerSplit(target);
        },
        .open_in_new_window => {
            if (ViewerPane.link_sink) |s| return s.append("window", target);
            const pv = self.pane_view orelse return self.openExternal(alloc, target);
            _ = pv.parentWindow().app.createWindow(.{ .viewer_open = .{
                .location = target,
                .origin_directory = self.origin_directory,
            } }) catch |err| {
                log.warn("viewer link menu: new window failed err={s}", .{@errorName(err)});
            };
        },
        // The plain path for a file, the URL as written for anything web —
        // Mac's `pasteboardString(for:)` rule, which `armLinkMenu`'s resolution
        // has already applied: a `file://` string is useless in a shell or
        // another editor, and a synthetic-host URL is useless anywhere.
        .copy => {
            if (ViewerPane.link_sink) |s| return s.append("copy", target);
            clipboardWriteText(alloc, target);
        },
        .focus_target => self.focusLinkTarget(target),
    }
}

pub fn shellExecuteArgs(
    self: *ViewerPane,
    alloc: Allocator,
    exe: []const u8,
    args: []const u8,
) void {
    _ = self;
    if (builtin.is_test) {
        log.err("test build refused to shell-execute: {s} {s}", .{ exe, args });
        return;
    }
    const wexe = std.unicode.utf8ToUtf16LeAllocZ(alloc, exe) catch return;
    defer alloc.free(wexe);
    const wargs = std.unicode.utf8ToUtf16LeAllocZ(alloc, args) catch return;
    defer alloc.free(wargs);
    _ = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        wexe,
        wargs,
        null,
        w32.SW_SHOW,
    );
}

/// Register the routing handler on a freshly adopted controller. Registered
/// for EVERY pane, web mode included, for the reason the title handler is: a
/// web pane becomes a file pane the moment the user types a path, and a
/// subscription installed only for the starting mode would be dead by then.
/// Non-fatal like every subscription — a pane without it follows file-mode
/// links in place, which is degraded, not broken.
pub fn subscribeNavigationStarting(self: *ViewerPane) void {
    std.debug.assert(self.navigation_starting_handler == null);
    const c = self.controller orelse return;
    const p = self.pending orelse return;
    const web = c.coreWebView() orelse return;
    defer web.release();

    const handler = NavigationStartingHandler.create(p.alloc, p) catch return;
    p.refs += 1;
    if (!web.addNavigationStarting(@ptrCast(handler))) {
        log.warn("add_NavigationStarting failed; file-mode links navigate in place", .{});
        handler.release(); // takes the borrowed token reference with it
        return;
    }
    self.navigation_starting_handler = handler;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "T1802: a reveal selects the file, or opens the folder it was in" {
    // Through the link sink, never the shell: what Explorer WOULD be asked for.
    const alloc = testing.allocator;
    var sink: ViewerPane.LinkSink = .{ .alloc = alloc };
    defer sink.deinit();
    ViewerPane.link_sink = &sink;
    defer ViewerPane.link_sink = null;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "here.md", .data = "x" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    const here = try std.fs.path.join(alloc, &.{ root, "here.md" });
    defer alloc.free(here);
    const gone = try std.fs.path.join(alloc, &.{ root, "gone", "deeper", "x.md" });
    defer alloc.free(gone);

    var pane: ViewerPane = .{};
    pane.revealInExplorer(alloc, here);
    // The link menu's item takes the same road, deleted file included.
    pane.performLinkMenuAction(alloc, .reveal_in_explorer, gone);

    try testing.expectEqual(@as(usize, 2), sink.entries.items.len);
    const want_sel = try std.fmt.allocPrint(alloc, "reveal:{s}", .{here});
    defer alloc.free(want_sel);
    try testing.expectEqualStrings(want_sel, sink.entries.items[0]);
    const want_dir = try std.fmt.allocPrint(alloc, "reveal-folder:{s}", .{root});
    defer alloc.free(want_dir);
    try testing.expectEqualStrings(want_dir, sink.entries.items[1]);
}
