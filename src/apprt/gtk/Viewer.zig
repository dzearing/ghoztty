//! A viewer: one WebKitGTK web view showing a markdown or code file through
//! the bundled template, a local `.html` file as a page, or a website
//! (T3410, Linux L9a - the foundation the viewer-pane cards build on), under
//! the navigation bar every viewer mode gets (T3412, L9c).
//!
//! The Mac's `ViewerView` translated to WebKitGTK, which is the same engine:
//!
//! - **Template modes** (markdown, code) load `ghoztty-viewer://page/viewer.html`
//!   and, once it has finished loading, push the file's bytes in through
//!   `window.__viewer.setMarkdown` / `setCode` - the same page calls win32
//!   builds (`viewer_document.zig`), in UTF-8 because that is what
//!   `webkit_web_view_evaluate_javascript` takes. The template URL carries the
//!   file as `?file=` (`viewer_chrome.templateUrlFor`), so WebKit's own
//!   back/forward list knows which file each entry showed.
//! - **A `.html` file** loads as a page from `ghoztty-page://page/<rel>`, whose
//!   grant is the file's own directory (`viewer_scheme.zig`), pinned when the
//!   pane navigates to the file - a link into `docs/` must not move it.
//! - **A website** is navigated to directly.
//! - **An image** (T3416) is the template too: its `image.js` draws the
//!   picture from `ghoztty-viewer://page/__image?v=<revision>`, and the zoom
//!   rules are win32's shared geometry - `ViewerImage.zig` carries them.
//! - Diffs are their own card (T3417); until it lands a diff pane shows the
//!   template's error card naming it.
//!
//! **The nav bar** (T3412; `docs/reference/viewer-panes.md`, Navigation
//! chrome): back / forward / reload / home, a reveal-in-file-manager button
//! while a local file is shown, and an editable address. It is a row of the
//! viewer's own vertical box, so it reserves its height from the first frame
//! and the page is laid out below it, never under it. History is WebKit's,
//! across the file <-> web boundary: where the pane IS is read back from every
//! committed URI (`syncCommitted`), never assumed from what was asked for.
//!
//! **Pane keys** (Linux modifier = Ctrl, as on Windows): a capture-phase key
//! controller on the viewer's box sees a chord before the page does, and asks
//! `viewer_chrome.classify` - the shared win32 tables - what it means. Ctrl+R
//! reloads, Ctrl+L / Alt+D focus the address with it selected, Ctrl +/-/0
//! zoom the page, Escape in the address reverts it. GTK has no "beep on an
//! unhandled key" (AppKit's `NSBeep`), so the Mac's no-beep rule is already
//! this platform's behavior.
//!
//! **Find in page** (T3414): Ctrl+F opens a card floating at the page's
//! top-trailing corner (an overlay, so it never reflows the text), with a
//! live "3/17" count; Enter / Shift+Enter, the chevrons, Ctrl+G /
//! Ctrl+Shift+G and F3 / Shift+F3 step, wrapping; Escape closes it and keeps
//! the query. The search is the shared `find.js`, injected as a user script
//! into every document so it reaches websites too. A picture declines the
//! chords.
//!
//! A viewer PANE is a `Surface` that hosts one of these in place of its
//! terminal (T3411), so it splits, resizes, focuses, zooms and closes through
//! the split tree's own code.
//!
//! **Links** (T3415): a click in a markdown/code pane sends http(s) to the
//! default browser, a relative `.md`/`.html` (or image, or diff) link to a
//! viewer split beside the pane, and any other file to its default app; a
//! live page (a website, a rendered `.html`) follows its own site in place
//! and a click off it takes the banner's modifier scheme (plain: the
//! browser; Ctrl: a side pane; Ctrl+Shift: a window of its own). Popups go to
//! the browser unless Ctrl-clicked. Right-clicking a link anywhere - the
//! template, a rendered page, a website, an iframe - gives Ghoztty's link
//! menu (the shared `links.js` decides whether the click is one of ours).
//! Every decision is the shared one, through `viewer_links.zig`.
//!
//! **Reloads** (T3413): a file pane watches its file (`viewer_watch.zig`) and
//! re-renders on a save, keeping the scroll; `+reload` and Ctrl+R are the
//! explicit "these bytes are stale" reload, which bypasses caches; a web
//! process that dies under the pane is restarted at most 3 times a minute,
//! then the pane says the page keeps crashing. Each decision is win32's
//! (`viewer_reload.zig` names them).
//!
//! The scheme handlers are registered on WebKit's default context once per
//! process; a request finds its viewer through the web view it came from
//! (`g_object_get_data`), so any number of viewers share them.
const Viewer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const internal_os = @import("../../os/main.zig");

const wk = @import("webkit.zig");
const scheme = @import("viewer_scheme.zig");
const chrome = @import("viewer_chrome.zig");
const content = @import("../win32/viewer_content.zig");
const document = @import("../win32/viewer_document.zig");
const nav = @import("../win32/viewer_nav.zig");
const view_arg = @import("../../cli/view_arg.zig");
const reload_gate = @import("../win32/reload_gate.zig");
const reload_policy = @import("viewer_reload.zig");
const Watch = @import("viewer_watch.zig");
const vfind = @import("../win32/viewer_find.zig");
const bridge = @import("../win32/viewer_bridge.zig");
const links = @import("viewer_links.zig");
const banner_link = @import("../win32/banner_link.zig");
const ViewerImage = @import("ViewerImage.zig");
const image_rules = @import("viewer_image.zig");
const ViewerDiff = @import("ViewerDiff.zig");
const ViewerTOC = @import("ViewerTOC.zig");
const ViewerFeedback = @import("ViewerFeedback.zig");
const quoting = @import("viewer_quote.zig");

const log = std.log.scoped(.gtk_viewer);

/// The `g_object_set_data` key a web view carries its viewer under.
const data_key = "ghoztty-viewer";

alloc: Allocator,
view: *wk.WebView,
/// The viewer's own vertical box: the nav bar, then the web view. This is
/// the widget a container holds.
box: *wk.GtkWidget,
bar: Bar,
mode: content.Mode,
/// What the viewer was opened on, as given: Home goes back here.
location: [:0]u8,
/// Where the viewer is NOW: the file it shows, else the page's URI. Read
/// back from every committed load, so a link or a history walk moves it.
current: [:0]u8,
/// The file behind a file mode; null for a website.
file_path: ?[]u8 = null,
/// The directory the pane was opened FROM (`--working-directory`): the
/// repository a diff spec reads, the worktree fallback for a page with no
/// directory of its own. Kept here so the session layout records it (T3420).
origin_dir: ?[]u8 = null,
/// The pane's stable ghoztty id, borrowed from the surface that hosts this
/// viewer (which outlives it): a feedback report names it (T3544).
pane_id: ?[]const u8 = null,
/// The read grant both schemes resolve against.
assets_dir: ?[]u8 = null,
base_dir: ?[]u8 = null,
/// The template committed and still needs its document pushed in.
needs_render: bool = false,
/// A load has FINISHED in a live web process: there is a page to render
/// into. False from a load's start, and from the moment its process dies -
/// a render into a dead page goes nowhere (the Mac's `pageLoaded` defect).
page_live: bool = false,

/// The file pane's watcher (T3413) and what the last render saw of the file
/// (win32's T3037 gate: an unchanged save renders nothing, a save while the
/// pane is unmapped is owed until it maps).
watch: Watch = .{},
file_gate: reload_gate.Gate = .{},
/// Restarts spent on a dying web process (Mac: 3 in 60 s).
restarts: reload_policy.Budget = .{},
/// How many times a dead web process was reloaded; the tests read it.
process_reloads: u32 = 0,
/// The crash card is going up, or is up: its load is not the pane's
/// document, so it neither moves the pane nor gets a document pushed in.
crash_card: enum { none, pending, shown } = .none,

/// Called each time content is on screen: a template mode's page call has
/// run, or a page/website finished loading. `ok` is false when the load
/// failed. The test hooks hang off it.
on_rendered: ?*const fn (*Viewer, ok: bool, detail: []const u8) void = null,
user_data: ?*anyopaque = null,
/// How many renders have finished; the first one is the test dump's.
render_count: u32 = 0,

/// Told when the location changes (a navigation, a link, Back), so the pane
/// can retitle itself. `owner` is the pane; the pane clears both before it
/// goes away.
on_location_changed: ?*const fn (*Viewer) void = null,
owner: ?*anyopaque = null,

/// The find card (T3414), floating over the page's top-trailing corner.
find: FindCard,
/// The card is showing.
find_open: bool = false,
/// What the user typed. Outlives the card being closed, so Ctrl+G resumes
/// the last search and Ctrl+F comes back to it selected (Mac's `findQuery`).
find_query: [vfind.max_query]u8 = undefined,
find_query_len: usize = 0,
/// The page's last answer for `find_query` (`find.js` -> `post`).
find_result: vfind.Result = .none,
/// The view's content manager and the `script-message-received` handler on
/// it, disconnected when the viewer goes so a late message finds nobody.
ucm: ?*wk.UserContentManager = null,
message_handler: c_ulong = 0,

/// Where a routed link opens when it stays in Ghoztty (T3415): the pane that
/// owns this viewer supplies them, since only it knows its split tree and
/// app. A viewer with none (the debug test window) logs and opens nothing.
on_open_split: ?*const fn (*Viewer, location: []const u8) void = null,
on_open_window: ?*const fn (*Viewer, location: []const u8) void = null,
on_focus_link: ?*const fn (*Viewer, url: []const u8) void = null,
/// The pointer's last position over the page, in the web view's own
/// coordinates: where the link menu pops up (Mac: at the pointer).
pointer_x: f64 = 0,
pointer_y: f64 = 0,
/// What the open (or last) link menu acts on: already resolved to a path
/// for a file link, so the menu acts on what the link IS (win32's
/// `armLinkMenu`). Owned.
menu_target: ?[:0]u8 = null,
menu_kind: links.Kind = .web,
/// The `file://`-link hook's message handler (`installFileLinkHook`).
file_link_handler_id: c_ulong = 0,

/// An image pane's state: its zoom, what the page measured, which decoder
/// serves the picture (T3416, `ViewerImage.zig`).
image: ViewerImage = .{},
/// A diff pane's state: its git worker, the changed-files panel, the
/// layout and the filter (T3417, `ViewerDiff.zig`).
diff: ViewerDiff = .{},
/// A markdown pane's table of contents (T3418).
toc: ViewerTOC = .{},
/// The feedback button and the worktree it would file to (T3419).
feedback: ViewerFeedback = .{},

/// The find card's widgets. All owned by `box` (through the overlay).
const FindCard = struct {
    /// The card itself: the row, then the honesty note under it.
    card: *wk.GtkWidget,
    entry: *wk.GtkWidget,
    count: *wk.GtkWidget,
    previous: *wk.GtkWidget,
    next: *wk.GtkWidget,
    close: *wk.GtkWidget,
    /// What the page is NOT searching (`find.js` -> `scopeNote`): a second
    /// line, shown only while the page has something to disclose.
    note: *wk.GtkWidget,
};

/// The nav bar's widgets. All owned by `box`.
const Bar = struct {
    row: *wk.GtkWidget,
    back: *wk.GtkWidget,
    forward: *wk.GtkWidget,
    reload: *wk.GtkWidget,
    home: *wk.GtkWidget,
    reveal: *wk.GtkWidget,
    address: *wk.GtkWidget,
};

/// Make a viewer for `location` and start loading it. The returned viewer is
/// owned by its web view: it is freed when the widget is destroyed.
pub fn create(alloc: Allocator, location: []const u8) !*Viewer {
    registerSchemes();

    const self = try alloc.create(Viewer);
    errdefer alloc.destroy(self);
    const loc = try alloc.dupeZ(u8, location);
    errdefer alloc.free(loc);
    const cur = try alloc.dupeZ(u8, location);
    errdefer alloc.free(cur);

    const w = wk.webkit_web_view_new();
    const box = wk.gtk_box_new(wk.orientation_vertical, 0);
    self.* = .{
        .alloc = alloc,
        .view = wk.asWebView(w),
        .box = box,
        .bar = buildBar(),
        .find = buildFindCard(),
        .mode = content.modeFor(location),
        .location = loc,
        .current = cur,
    };
    self.assets_dir = findAssetsDir(alloc);

    wk.gtk_widget_set_hexpand(w, 1);
    wk.gtk_widget_set_vexpand(w, 1);
    // The page sits in an overlay so the find card FLOATS over it rather than
    // adding a band: a band would reflow the very text about to be searched.
    // The overlay hangs off the page's top, below the bar, so the card moves
    // with the content and never covers the address.
    const overlay = wk.gtk_overlay_new();
    wk.gtk_widget_set_hexpand(overlay, 1);
    wk.gtk_widget_set_vexpand(overlay, 1);
    wk.gtk_overlay_set_child(overlay, w);
    // The contents card (T3418) floats over the page's top-left, under the
    // find card; its button is the bar's first item.
    self.toc.buildUi(self, overlay, self.bar.row);
    wk.gtk_overlay_add_overlay(overlay, self.find.card);
    wk.gtk_box_append(box, self.bar.row);
    // The feedback composer's band sits right under the bar, hidden until
    // the feedback button opens it (T3544).
    wk.gtk_box_append(box, self.feedback.buildComposerUi(self));
    // A diff pane's changed-files panel sits beside the page (T3417); it is
    // hidden in every other mode, so the paned is the page alone there.
    wk.gtk_box_append(box, self.diff.buildUi(self, overlay, self.bar.row));
    // The feedback button takes the bar's trailing slot, after the address
    // and any diff controls (the Mac's order). Hidden until a worktree is
    // found (T3419).
    self.feedback.buildUi(self, self.bar.row);
    self.installFindScript();
    self.installLinks();

    // DEBUG-ONLY test seam: with `GHOZTTY_TEST_VIEWER_DUMP` set, every
    // viewer - a pane's too (T3411) - writes its probe result there once it
    // has rendered. Headless Weston has no pixels to read back; the page is.
    if (comptime build_config.is_debug) {
        if (std.posix.getenv("GHOZTTY_TEST_VIEWER_DUMP") != null) self.on_rendered = &onTestRendered;
    }

    wk.g_object_set_data(w, data_key, self);
    _ = wk.g_signal_connect_data(w, "load-changed", @ptrCast(&onLoadChanged), self, null, 0);
    _ = wk.g_signal_connect_data(w, "load-failed", @ptrCast(&onLoadFailed), self, null, 0);
    _ = wk.g_signal_connect_data(w, "destroy", @ptrCast(&onDestroy), self, null, 0);
    _ = wk.g_signal_connect_data(w, "web-process-terminated", @ptrCast(&onWebProcessTerminated), self, null, 0);
    // A save that landed while the pane was unmapped renders when it maps.
    _ = wk.g_signal_connect_data(box, "map", @ptrCast(&onMapped), self, null, 0);

    _ = wk.g_signal_connect_data(self.bar.back, "clicked", @ptrCast(&onBackClicked), self, null, 0);
    _ = wk.g_signal_connect_data(self.bar.forward, "clicked", @ptrCast(&onForwardClicked), self, null, 0);
    _ = wk.g_signal_connect_data(self.bar.reload, "clicked", @ptrCast(&onReloadClicked), self, null, 0);
    _ = wk.g_signal_connect_data(self.bar.home, "clicked", @ptrCast(&onHomeClicked), self, null, 0);
    _ = wk.g_signal_connect_data(self.bar.reveal, "clicked", @ptrCast(&onRevealClicked), self, null, 0);
    _ = wk.g_signal_connect_data(self.bar.address, "activate", @ptrCast(&onAddressActivate), self, null, 0);
    _ = wk.g_signal_connect_data(self.find.entry, "changed", @ptrCast(&onFindChanged), self, null, 0);
    _ = wk.g_signal_connect_data(self.find.previous, "clicked", @ptrCast(&onFindPreviousClicked), self, null, 0);
    _ = wk.g_signal_connect_data(self.find.next, "clicked", @ptrCast(&onFindNextClicked), self, null, 0);
    _ = wk.g_signal_connect_data(self.find.close, "clicked", @ptrCast(&onFindCloseClicked), self, null, 0);

    // The pane's chords, before the page or a field sees them.
    const keys = wk.gtk_event_controller_key_new();
    wk.gtk_event_controller_set_propagation_phase(keys, wk.phase_capture);
    _ = wk.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKeyPressed), self, null, 0);
    wk.gtk_widget_add_controller(box, keys);

    self.navigate(location);
    return self;
}

/// The viewer as a GTK widget - the nav bar and the page - for whatever
/// container holds it.
pub fn widget(self: *const Viewer) *wk.GtkWidget {
    return self.box;
}

/// Give keyboard focus to the page (Mac's `focusContent`): what focusing the
/// pane means, and where a submitted address or an Escape hands focus back.
pub fn focusContent(self: *const Viewer) void {
    _ = wk.gtk_widget_grab_focus(wk.asWidget(self.view));
}

/// What `+list` reports as the pane's `url` (T3411): where the pane is NOW -
/// the page a website is on, else the file it shows.
pub fn currentLocation(self: *const Viewer) []const u8 {
    return self.current;
}

/// Where the pane was OPENED - the Home button's target (T3420). The
/// session layout records it beside `currentLocation`, because a restore
/// navigates to where the pane IS and would otherwise re-home it there.
pub fn homeLocation(self: *const Viewer) []const u8 {
    return self.location;
}

/// The directory the pane was opened from, or null (T3420).
pub fn originDirectory(self: *const Viewer) ?[]const u8 {
    return self.origin_dir;
}

/// Restore-only (T3420): make `home` what Home goes back to, without
/// navigating - the pane stays where the restore put it.
pub fn setHomeLocation(self: *Viewer, home: []const u8) void {
    if (home.len == 0 or std.mem.eql(u8, home, self.location)) return;
    const z = self.alloc.dupeZ(u8, home) catch return;
    self.alloc.free(self.location);
    self.location = z;
}

/// The pane's title: the file's name, a website's host, a diff's subject
/// (win32's `initialTitle`, the Mac's `mode.title`). Borrowed from the viewer.
pub fn paneTitle(self: *const Viewer) []const u8 {
    return content.initialTitle(self.mode, self.current, self.file_path);
}

fn deinit(self: *Viewer) void {
    if (comptime build_config.is_debug) {
        if (steps.viewer == self) steps.viewer = null;
    }
    self.watch.stop();
    self.diff.deinit();
    self.toc.deinit();
    self.feedback.deinit();
    if (self.ucm) |m| {
        if (self.message_handler != 0) wk.g_signal_handler_disconnect(m, self.message_handler);
        wk.webkit_user_content_manager_unregister_script_message_handler(m, bridge.handler_name, null);
        if (self.file_link_handler_id != 0) {
            wk.g_signal_handler_disconnect(m, self.file_link_handler_id);
            wk.webkit_user_content_manager_unregister_script_message_handler(m, file_link_handler, null);
        }
        // The ref `installFindScript` took: the web view may already have
        // dropped its own by the time its `destroy` reaches us.
        wk.g_object_unref(m);
    }
    const alloc = self.alloc;
    alloc.free(self.location);
    alloc.free(self.current);
    if (self.menu_target) |t| alloc.free(t);
    if (self.file_path) |p| alloc.free(p);
    if (self.assets_dir) |p| alloc.free(p);
    if (self.base_dir) |p| alloc.free(p);
    if (self.origin_dir) |p| alloc.free(p);
    alloc.destroy(self);
}

/// `<resources>/viewer`, the bundled template the build installs beside the
/// app (`share/ghostty/viewer`). Resolved once per viewer, not per request.
fn findAssetsDir(alloc: Allocator) ?[]u8 {
    var dirs = internal_os.resourcesDir(alloc) catch return null;
    defer dirs.deinit(alloc);
    const dir = dirs.app() orelse {
        log.warn("no bundled viewer assets found; file viewers will not render", .{});
        return null;
    };
    return std.fs.path.join(alloc, &.{ dir, "viewer" }) catch null;
}

// -------------------------------------------------------------------------
// Navigation
// -------------------------------------------------------------------------

/// Point the pane at `target` - a path, a URL, a diff spec - and load it.
/// The state set here is what the scheme handler needs before the load
/// commits; `syncCommitted` re-reads it from the committed URI either way.
pub fn navigate(self: *Viewer, target: []const u8) void {
    const mode = content.modeFor(target);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path: ?[]const u8 = if (mode.isFile()) content.filePath(&path_buf, target) else null;

    self.setCurrent(path orelse target);
    self.mode = mode;
    self.setFile(path);
    // The grant: a template's relative images and a page's own directory.
    // A page's root is pinned here and nowhere else (win32's T601 note).
    if (path) |p| self.setBaseDir(std.fs.path.dirname(p));

    switch (mode) {
        .web => wk.webkit_web_view_load_uri(self.view, self.current.ptr),
        .html => {
            const p = path orelse return self.fail("Cannot read file", target);
            const root = self.base_dir orelse return self.fail("Cannot read file", p);
            const url = scheme.pageUrl(self.alloc, root, p) catch null;
            const u = url orelse return self.fail("Cannot read file", p);
            defer self.alloc.free(u);
            wk.webkit_web_view_load_uri(self.view, u.ptr);
        },
        .markdown, .code, .image => {
            const p = path orelse {
                wk.webkit_web_view_load_uri(self.view, scheme.template_url);
                return;
            };
            const url = chrome.templateUrlFor(self.alloc, p) catch return self.fail("Cannot read file", p);
            defer self.alloc.free(url);
            wk.webkit_web_view_load_uri(self.view, url.ptr);
        },
        .diff => wk.webkit_web_view_load_uri(self.view, scheme.template_url),
    }
    self.syncChrome();
    self.syncWatch();
}

/// Read where the pane IS from a committed URI: a typed address, a link and
/// a history walk all arrive here, and only here do they move the pane.
fn syncCommitted(self: *Viewer) void {
    const uri_z = wk.webkit_web_view_get_uri(self.view) orelse return;
    const uri = std.mem.span(uri_z);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    switch (chrome.classifyCommitted(&buf, uri)) {
        .template_file => |file| {
            self.mode = content.modeFor(file);
            self.setCurrent(file);
            self.setFile(file);
            self.setBaseDir(std.fs.path.dirname(file));
            self.needs_render = true;
        },
        // The bare template (a diff, or a file that never resolved): keep
        // what the pane was told, render that.
        .template_bare => self.needs_render = true,
        .page => |rel| {
            self.mode = .html;
            const root = self.base_dir orelse "";
            const full = std.fs.path.join(self.alloc, &.{ root, rel }) catch return;
            defer self.alloc.free(full);
            self.setCurrent(full);
            self.setFile(full);
        },
        .web => {
            self.mode = .web;
            self.setCurrent(uri);
            self.setFile(null);
        },
    }
    self.syncChrome();
    self.syncWatch();
    // Which worktree the pane's content belongs to now: a link, Back or a
    // typed address can move it to another repo or out of every repo.
    self.feedback.refresh(self);
    if (self.on_location_changed) |cb| cb(self);
}

// -------------------------------------------------------------------------
// Live reload (T3413)
// -------------------------------------------------------------------------

/// Watch the file the pane shows now, and only that one: a link, Back or a
/// typed address moves the watch with the pane, and a website watches
/// nothing. Leaving a file drops a save it still owed (win32's T400/T3037).
fn syncWatch(self: *Viewer) void {
    const path: ?[]const u8 = if (self.mode.isFile()) self.file_path else null;
    if (self.watch.watching()) |w| {
        if (path) |p| if (std.mem.eql(u8, w, p)) return;
    } else if (path == null) return;

    self.watch.stop();
    self.file_gate.reset();
    const p = path orelse return;
    self.file_gate.note(fileStamp(p));
    self.watch.start(self.alloc, p, &onFileSaved, self);
}

fn fileStamp(path: []const u8) ?reload_gate.Stamp {
    const st = std.fs.cwd().statFile(path) catch return null;
    return .{ .size = st.size, .mtime = st.mtime };
}

fn onFileSaved(ctx: *anyopaque) void {
    const self: *Viewer = @ptrCast(@alignCast(ctx));
    self.fileSaved();
}

/// The watcher's debounced save landed, through the T3037 gate.
fn fileSaved(self: *Viewer) void {
    const path = self.file_path orelse return;
    const shown = wk.gtk_widget_get_mapped(self.box) != 0;
    // An unmapped pane does not even stat: a writer saving ten times a
    // second must cost a hidden pane nothing but this branch.
    const now = if (shown) fileStamp(path) else null;
    switch (self.file_gate.save(shown, now)) {
        .owed => log.debug("viewer: {s} saved while hidden; render owed", .{path}),
        .unchanged => log.debug("viewer: {s} saved unchanged; nothing to render", .{path}),
        .render => {
            log.info("viewer: {s} changed on disk; reloading", .{path});
            self.reloadContent(.file_changed);
        },
    }
}

fn onMapped(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    if (self.file_gate.reveal()) self.fileSaved();
}

// -------------------------------------------------------------------------
// A dead web process (T3413; Mac `webViewWebContentProcessDidTerminate`)
// -------------------------------------------------------------------------

fn onWebProcessTerminated(_: *wk.WebView, reason: reload_policy.TerminationReason, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.page_live = false;
    const action = self.restarts.decide(reload_policy.kindFor(reason), std.time.milliTimestamp());
    log.warn("viewer: web process terminated reason={d} -> {s}", .{ @intFromEnum(reason), @tagName(action) });
    switch (action) {
        // `reload` rather than `navigate`: it reloads the document the pane
        // is ON (a website the user went to, not the one it opened with), and
        // a template's commit re-renders its file exactly as the button does.
        .reload => {
            self.process_reloads +|= 1;
            wk.webkit_web_view_reload(self.view);
        },
        .capped, .browser_gone => self.showCrashCard(),
        .ignore => {},
    }
}

/// The page used up its restarts: say so instead of staying blank. The card
/// is its own small page (the template is a page too, and pages are what
/// keep dying), shown in place of the current one without a history entry;
/// a `+reload` or Ctrl+R afterwards is the user asking to try again.
fn showCrashCard(self: *Viewer) void {
    const uri = wk.webkit_web_view_get_uri(self.view) orelse self.current.ptr;
    self.crash_card = .pending;
    wk.webkit_web_view_load_alternate_html(self.view, reload_policy.keeps_crashing_html, uri, null);
}

fn setCurrent(self: *Viewer, value: []const u8) void {
    if (std.mem.eql(u8, self.current, value)) return;
    const copy = self.alloc.dupeZ(u8, value) catch return;
    self.alloc.free(self.current);
    self.current = copy;
}

fn setFile(self: *Viewer, value: ?[]const u8) void {
    if (self.file_path) |old| {
        if (value) |v| if (std.mem.eql(u8, old, v)) return;
        self.alloc.free(old);
        self.file_path = null;
    }
    const v = value orelse return;
    self.file_path = self.alloc.dupe(u8, v) catch null;
}

fn setBaseDir(self: *Viewer, value: ?[]const u8) void {
    const v = value orelse return;
    if (self.base_dir) |old| {
        if (std.mem.eql(u8, old, v)) return;
        self.alloc.free(old);
        self.base_dir = null;
    }
    self.base_dir = self.alloc.dupe(u8, v) catch null;
}

pub fn goBack(self: *Viewer) void {
    wk.webkit_web_view_go_back(self.view);
}

pub fn goForward(self: *Viewer) void {
    wk.webkit_web_view_go_forward(self.view);
}

/// Home: the location the pane was opened with.
pub fn goHome(self: *Viewer) void {
    self.navigate(self.location);
}

/// Reload in place: `+reload` and Ctrl+R (`.chrome`, Mac's Cmd+R), and a save
/// of the viewed file (`.file_changed`). win32's `reloadPlan` decides: a
/// template mode re-reads its file and pushes it into the page it already
/// has, so the scroll survives; a saved `.html` page reloads in place, which
/// WebKit restores the scroll across; an explicit reload of a page or a
/// website re-fetches bypassing caches (an edited sibling stylesheet); and
/// with no live page - mid-load, or its process died - the load runs again.
pub fn reloadContent(self: *Viewer, reason: content.ReloadReason) void {
    // An explicit reload re-reads the file as it stands: that is what is on
    // screen next, so a later save is judged against it, and a save it
    // already covered owes nothing more.
    if (reason == .chrome) {
        if (self.file_path) |p| self.file_gate.note(fileStamp(p));
        self.watch.cancelPending();
    }
    const live = self.page_live and !self.needs_render and self.crash_card == .none;
    const plan = content.reloadPlan(self.mode, live, reason);
    log.debug("viewer: reload reason={s} plan={s}", .{ @tagName(reason), @tagName(plan) });
    switch (plan) {
        // An image re-decodes, keeping the zoom across a same-size save.
        .rerender => if (self.mode == .image) self.image.reload(self) else self.renderTemplate(),
        .reload_in_place => wk.webkit_web_view_reload(self.view),
        .refetch => wk.webkit_web_view_reload_bypass_cache(self.view),
        // Behind a crash card, load where the pane IS again (the card's own
        // reload would only reload the card).
        .full_load => if (self.crash_card == .none and wk.webkit_web_view_get_uri(self.view) != null)
            wk.webkit_web_view_reload_bypass_cache(self.view)
        else
            self.navigate(self.current),
    }
}

/// The bar's reload button: a plain browser reload (Mac's `reloadPage`). A
/// template mode reloads the template, whose commit re-renders the file.
fn reloadFromChrome(self: *Viewer) void {
    // Behind the crash card a plain reload would reload the card.
    if (self.crash_card != .none) return self.reloadContent(.chrome);
    wk.webkit_web_view_reload(self.view);
}

/// Submit from the address field (Mac's `navigate(to:)`): trim, classify,
/// complete omnibox-style, expand `~` - then hand focus to the page, as a
/// browser omnibox does.
fn navigateFromAddress(self: *Viewer) void {
    const text = std.mem.span(wk.gtk_editable_get_text(self.bar.address));
    var resolve_buf: [nav.max_address]u8 = undefined;
    const resolved = nav.resolveInput(&resolve_buf, text) orelse return;

    var tilde_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target: []const u8 = expand: {
        const rem = view_arg.tildeRemainder(resolved) orelse break :expand resolved;
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const home = (internal_os.home(&home_buf) catch null) orelse break :expand resolved;
        const rel = std.mem.trimLeft(u8, rem, "/");
        break :expand std.fmt.bufPrint(&tilde_buf, "{s}{s}{s}", .{
            home,
            if (rel.len > 0) "/" else "",
            rel,
        }) catch resolved;
    };
    log.info("viewer: address navigates to {s}", .{target});
    self.focusContent();
    self.navigate(target);
}

/// Ctrl+L / Alt+D: the caret in the address with the whole address selected.
pub fn focusAddress(self: *Viewer) void {
    _ = wk.gtk_widget_grab_focus(self.bar.address);
    wk.gtk_editable_select_region(self.bar.address, 0, -1);
}

/// Escape while editing the address: the edit is thrown away, the real
/// location goes back in the field, and the page gets focus (Mac's
/// `cancelAddressEditing`).
fn cancelAddressEdit(self: *Viewer) void {
    self.focusContent();
    self.syncAddress(true);
}

fn zoom(self: *Viewer, action: chrome.ZoomAction) void {
    const level = chrome.steppedZoom(wk.webkit_web_view_get_zoom_level(self.view), action);
    wk.webkit_web_view_set_zoom_level(self.view, level);
}

// -------------------------------------------------------------------------
// The nav bar
// -------------------------------------------------------------------------

fn buildBar() Bar {
    const row = wk.gtk_box_new(wk.orientation_horizontal, 2);
    wk.gtk_widget_add_css_class(row, "toolbar");
    const bar: Bar = .{
        .row = row,
        .back = barButton("go-previous-symbolic", "Back"),
        .forward = barButton("go-next-symbolic", "Forward"),
        .reload = barButton("view-refresh-symbolic", "Reload"),
        .home = barButton("go-home-symbolic", "Home"),
        .reveal = barButton("folder-open-symbolic", "Open Containing Folder"),
        .address = wk.gtk_entry_new(),
    };
    wk.gtk_entry_set_placeholder_text(bar.address, "Enter URL");
    wk.gtk_widget_set_hexpand(bar.address, 1);
    wk.gtk_widget_set_margin_start(bar.address, 4);
    inline for (.{ "back", "forward", "reload", "home", "reveal", "address" }) |f| {
        wk.gtk_box_append(row, @field(bar, f));
    }
    return bar;
}

fn barButton(icon: [*:0]const u8, tip: [*:0]const u8) *wk.GtkWidget {
    const b = wk.gtk_button_new_from_icon_name(icon);
    wk.gtk_widget_set_tooltip_text(b, tip);
    wk.gtk_widget_add_css_class(b, "flat");
    // Clicking Back must not take the caret out of the page.
    wk.gtk_widget_set_focus_on_click(b, 0);
    return b;
}

/// Mirror where the pane is onto the bar.
fn syncChrome(self: *Viewer) void {
    wk.gtk_widget_set_sensitive(self.bar.back, wk.webkit_web_view_can_go_back(self.view));
    wk.gtk_widget_set_sensitive(self.bar.forward, wk.webkit_web_view_can_go_forward(self.view));
    wk.gtk_widget_set_visible(self.bar.reveal, @intFromBool(chrome.showsReveal(self.mode) and self.file_path != null));
    self.syncAddress(false);
    self.diff.syncMode(self);
    self.toc.syncMode(self);
}

/// Which repository a diff spec applies to: the pane's `--working-directory`
/// (T3417). Called by the pane right after `create`, before the template has
/// loaded, so the first listing already has it.
pub fn setOriginDirectory(self: *Viewer, dir: ?[]const u8) void {
    if (self.origin_dir) |d| self.alloc.free(d);
    self.origin_dir = null;
    if (dir) |d| if (d.len > 0) {
        self.origin_dir = self.alloc.dupe(u8, d) catch null;
    };
    self.diff.setOriginDirectory(dir);
    self.feedback.setOriginDirectory(dir);
    // The first answer, from the location the pane was opened on: the button
    // can show before the first load commits (the commit re-asks, and finds
    // this question in flight or cached).
    self.feedback.refresh(self);
}

/// Put the pane's location in the address field - unless someone is typing
/// there and `force` is off, because a page finishing a load must not throw
/// away a half-typed address.
fn syncAddress(self: *Viewer, force: bool) void {
    if (!force and self.addressHasFocus()) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const text = nav.addressText(&buf, self.current);
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{text}) catch return;
    wk.gtk_editable_set_text(self.bar.address, z.ptr);
}

pub fn focusWidget(self: *const Viewer) ?*wk.GtkWidget {
    const root = wk.gtk_widget_get_root(self.box) orelse return null;
    return wk.gtk_root_get_focus(root);
}

fn addressHasFocus(self: *const Viewer) bool {
    const f = self.focusWidget() orelse return false;
    return f == self.bar.address or wk.gtk_widget_is_ancestor(f, self.bar.address) != 0;
}

fn onBackClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.goBack();
}

fn onForwardClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.goForward();
}

fn onReloadClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.reloadFromChrome();
}

fn onHomeClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.goHome();
}

fn onRevealClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.reveal();
}

fn onAddressActivate(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.navigateFromAddress();
}

/// Show the pane's file in the file manager with it selected (Mac's Reveal
/// in Finder; GTK's `open_containing_folder`, which asks the desktop's
/// `org.freedesktop.FileManager1`). A file deleted under the pane opens the
/// nearest folder that still exists instead of a dead click - the Mac's
/// answer too.
pub fn reveal(self: *Viewer) void {
    self.revealPath(self.file_path orelse return);
}

/// Reveal `path` - the bar's button, and the link menu's Open Containing
/// Folder row (one road for both, as `banner_link.revealTarget` is on win32).
pub fn revealPath(self: *Viewer, path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = revealTarget(&buf, path) orelse return;
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{target.path}) catch return;
    const file = wk.g_file_new_for_path(z.ptr);
    defer wk.g_object_unref(file);
    const launcher = wk.gtk_file_launcher_new(file);
    const parent = wk.gtk_widget_get_root(self.box);
    switch (target.kind) {
        .file => {
            log.info("viewer: reveal file={s}", .{target.path});
            wk.gtk_file_launcher_open_containing_folder(launcher, parent, null, &onRevealDone, null);
        },
        .folder => {
            log.info("viewer: reveal folder={s} (the file is gone)", .{target.path});
            wk.gtk_file_launcher_launch(launcher, parent, null, &onRevealFolderDone, null);
        },
    }
}

const RevealTarget = struct {
    kind: enum { file, folder },
    path: []const u8,
};

/// The file itself when it exists, else its nearest existing ancestor.
fn revealTarget(buf: []u8, path: []const u8) ?RevealTarget {
    if (std.fs.accessAbsolute(path, .{})) |_| {
        if (path.len > buf.len) return null;
        @memcpy(buf[0..path.len], path);
        return .{ .kind = .file, .path = buf[0..path.len] };
    } else |_| {}
    var dir = std.fs.path.dirname(path);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        std.fs.accessAbsolute(d, .{}) catch continue;
        if (d.len > buf.len) return null;
        @memcpy(buf[0..d.len], d);
        return .{ .kind = .folder, .path = buf[0..d.len] };
    }
    return null;
}

fn onRevealDone(source: ?*wk.GObject, result: *wk.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const launcher: *wk.GtkFileLauncher = @ptrCast(source orelse return);
    defer wk.g_object_unref(launcher);
    var err: ?*wk.GError = null;
    if (wk.gtk_file_launcher_open_containing_folder_finish(launcher, result, &err) == 0) {
        if (err) |e| {
            defer wk.g_error_free(e);
            log.warn("viewer: reveal failed: {s}", .{std.mem.span(e.message orelse "?")});
        }
    }
}

fn onRevealFolderDone(source: ?*wk.GObject, result: *wk.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const launcher: *wk.GtkFileLauncher = @ptrCast(source orelse return);
    defer wk.g_object_unref(launcher);
    var err: ?*wk.GError = null;
    if (wk.gtk_file_launcher_launch_finish(launcher, result, &err) == 0) {
        if (err) |e| {
            defer wk.g_error_free(e);
            log.warn("viewer: reveal failed: {s}", .{std.mem.span(e.message orelse "?")});
        }
    }
}

// -------------------------------------------------------------------------
// Links (T3415; Mac `decidePolicyFor` + `handleFileModeLink`, the popup
// delegate and `BannerLinkOpener`; win32 `viewer_pane_links.zig`)
// -------------------------------------------------------------------------

/// Hook the link plane onto a new viewer: the navigation policy, the popup
/// request, the pointer (for the menu), and the shared `links.js` - a user
/// script in EVERY frame (it needs no coordinates, so an iframe's link gets
/// the menu too; Mac does the same), added before the first navigation.
fn installLinks(self: *Viewer) void {
    const w = wk.asWidget(self.view);
    _ = wk.g_signal_connect_data(w, "decide-policy", @ptrCast(&onDecidePolicy), self, null, 0);
    _ = wk.g_signal_connect_data(w, "create", @ptrCast(&onCreate), self, null, 0);
    const motion = wk.gtk_event_controller_motion_new();
    _ = wk.g_signal_connect_data(motion, "motion", @ptrCast(&onPointerMotion), self, null, 0);
    wk.gtk_widget_add_controller(w, motion);

    if (self.ucm) |m| {
        const script = wk.webkit_user_script_new(bridge.links_js, wk.inject_all_frames, wk.inject_at_document_end, null, null);
        wk.webkit_user_content_manager_add_script(m, script);
        wk.webkit_user_script_unref(script);
        self.installFileLinkHook(m);
    }

    // DEBUG-ONLY: a headless test has no user gesture to give, and WebKit's
    // popup blocker would swallow a scripted `window.open()` before the
    // popup rule ever ran. Only WebKit's gate is lifted; the rule under test
    // is still ours.
    if (comptime build_config.is_debug) {
        if (std.posix.getenv("GHOZTTY_TEST_VIEWER_LINKS") != null)
            wk.webkit_settings_set_javascript_can_open_windows_automatically(wk.webkit_web_view_get_settings(self.view), 1);
    }
}

fn onPointerMotion(_: *wk.GtkEventController, x: f64, y: f64, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.pointer_x = x;
    self.pointer_y = y;
}

/// `decide-policy`: a navigation is about to start. Only a NAVIGATION is ours
/// to route here; a new-window request goes on to `create`, which decides
/// popups, and a response is WebKit's.
fn onDecidePolicy(view: *wk.WebView, decision: *wk.PolicyDecision, kind: c_int, ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return 0));
    if (kind != wk.policy_navigation_action) return 0;
    const action = wk.webkit_navigation_policy_decision_get_navigation_action(decision) orelse return 0;
    const req = wk.webkit_navigation_action_get_request(action) orelse return 0;
    const uri = std.mem.span(wk.webkit_uri_request_get_uri(req) orelse return 0);
    // The document the navigation is LEAVING: the view's URI still names the
    // committed page until this load starts.
    const page: ?[]const u8 = if (wk.webkit_web_view_get_uri(view)) |p| std.mem.span(p) else null;
    const nav_type: links.NavType = @enumFromInt(wk.webkit_navigation_action_get_navigation_type(action));
    const d = links.decide(self.mode, page, uri, nav_type, wk.webkit_navigation_action_is_redirect(action) != 0);
    if (d == .allow) return 0;

    wk.webkit_policy_decision_ignore(decision);
    const mods = navMods(action);
    log.info("viewer: link {s} -> {s} ctrl={} shift={}", .{ uri, @tagName(d), mods.ctrl, mods.shift });
    self.routeDecision(d, uri, mods);
    return 1;
}

/// The modifiers held for a navigation. WebKit reports them only for a
/// TRUSTED event (a page cannot fake a Ctrl-click into a side pane), and a
/// seatless Weston can make none, so a debug build's steps runner can stand
/// in for the keyboard (`mods <ctrl|ctrl+shift|none>`) - the same seam
/// shape as `key`, which calls the handler a real press would.
fn navMods(action: *wk.NavigationAction) links.Mods {
    return withTestMods(links.Mods.fromGdk(wk.webkit_navigation_action_get_modifiers(action)));
}

fn withTestMods(real: links.Mods) links.Mods {
    if (comptime build_config.is_debug) {
        if (steps.mods_override) |m| return .{ .ctrl = real.ctrl or m.ctrl, .shift = real.shift or m.shift };
    }
    return real;
}

/// Carry out a link decision the navigation policy (or the file-link hook)
/// made.
fn routeDecision(self: *Viewer, d: links.Decision, uri: []const u8, mods: links.Mods) void {
    switch (d) {
        .allow => unreachable,
        .command => self.focusLink(uri),
        .browser => self.openExternal(uri),
        .relative => self.openRelativeLink(uri),
        .file_url => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (content.filePath(&buf, uri)) |path| self.dispatchFileLink(path);
        },
        // Mac's nil file URL: cancelled, and nothing else happens.
        .drop => {},
        .live_link => self.routeLivePageLink(uri, mods),
    }
}

/// `file://` links, which WebKit refuses to navigate to from any page that
/// is not itself a `file:` page ("Not allowed to load local resource") -
/// before the navigation policy is ever asked, so `decide-policy` never sees
/// the click and the link would be dead. Mac's pages ARE `file:` pages; ours
/// are served from custom schemes, and a website is never one. So this hook
/// takes the click at the page instead: a TRUSTED left click on a `file:`
/// link in the top frame of a non-`file:` page, posted with its modifiers,
/// then routed by the same `links.decide` the policy uses. Untrusted (script
/// made) clicks are ignored, so a page cannot fake a click into launching a
/// local file's app; a debug test run allows them (`__ghozttyTestClicks`).
const file_link_handler = "ghozttyFileLink";
const file_link_js =
    \\(function () {
    \\  "use strict";
    \\  if (window.__ghozttyFileLinks) return;
    \\  window.__ghozttyFileLinks = true;
    \\  document.addEventListener("click", function (event) {
    \\    if (event.defaultPrevented || event.button !== 0) return;
    \\    if (!event.isTrusted && !window.__ghozttyTestClicks) return;
    \\    if (location.protocol === "file:") return;
    \\    const t = event.target;
    \\    const a = t && t.closest ? t.closest("a[href]") : null;
    \\    if (!a) return;
    \\    let url;
    \\    try { url = new URL(a.href); } catch (e) { return; }
    \\    if (url.protocol !== "file:") return;
    \\    const h = window.webkit && window.webkit.messageHandlers &&
    \\      window.webkit.messageHandlers.ghozttyFileLink;
    \\    if (!h) return;
    \\    event.preventDefault();
    \\    h.postMessage(JSON.stringify({ href: a.href, ctrl: event.ctrlKey, shift: event.shiftKey }));
    \\  }, false);
    \\})();
;

fn installFileLinkHook(self: *Viewer, m: *wk.UserContentManager) void {
    const test_js: [:0]const u8 = "window.__ghozttyTestClicks = true;\n" ++ file_link_js;
    const js: [:0]const u8 = if (build_config.is_debug and std.posix.getenv("GHOZTTY_TEST_VIEWER_LINKS") != null)
        test_js
    else
        file_link_js;
    const script = wk.webkit_user_script_new(js, wk.inject_top_frame, wk.inject_at_document_end, null, null);
    wk.webkit_user_content_manager_add_script(m, script);
    wk.webkit_user_script_unref(script);
    if (wk.webkit_user_content_manager_register_script_message_handler(m, file_link_handler, null) == 0) {
        log.warn("viewer: could not register the {s} handler; file:// links in pages stay dead", .{file_link_handler});
        return;
    }
    self.file_link_handler_id = wk.g_signal_connect_data(
        m,
        "script-message-received::" ++ file_link_handler,
        @ptrCast(&onFileLinkMessage),
        self,
        null,
        0,
    );
}

fn onFileLinkMessage(_: *wk.UserContentManager, value: *wk.JSCValue, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    const s = wk.jsc_value_to_string(value) orelse return;
    defer wk.g_free(s);
    const Msg = struct { href: []const u8, ctrl: bool = false, shift: bool = false };
    const parsed = std.json.parseFromSlice(Msg, self.alloc, std.mem.span(s), .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const href = parsed.value.href;
    const page: ?[]const u8 = if (wk.webkit_web_view_get_uri(self.view)) |p| std.mem.span(p) else null;
    const d = links.decide(self.mode, page, href, .link_clicked, false);
    const mods = withTestMods(.{ .ctrl = parsed.value.ctrl, .shift = parsed.value.shift });
    log.info("viewer: file link {s} -> {s} ctrl={} shift={}", .{ href, @tagName(d), mods.ctrl, mods.shift });
    if (d == .allow) return;
    self.routeDecision(d, href, mods);
}

/// `create`: the page asked for a new window (`target="_blank"`,
/// `window.open()`). Nothing is ever adopted here yet (T3447), so the answer
/// is always "no web view" - which a script sees as `window.open()`
/// returning null - and the link goes where the shared popup rule says.
fn onCreate(view: *wk.WebView, action: *wk.NavigationAction, ud: ?*anyopaque) callconv(.c) ?*wk.GtkWidget {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return null));
    const uri: ?[]const u8 = blk: {
        const req = wk.webkit_navigation_action_get_request(action) orelse break :blk null;
        const u = std.mem.span(wk.webkit_uri_request_get_uri(req) orelse break :blk null);
        break :blk if (u.len == 0) null else u;
    };
    const page: ?[]const u8 = if (wk.webkit_web_view_get_uri(view)) |p| std.mem.span(p) else null;
    const mods = navMods(action);
    const gesture = wk.webkit_navigation_action_is_user_gesture(action) != 0;
    const route = links.decidePopup(self.mode, page, uri, mods, gesture);
    log.info("viewer: popup {s} -> {s} ctrl={} gesture={}", .{ uri orelse "(none)", @tagName(route), mods.ctrl, gesture });
    switch (route) {
        .browser => if (uri) |u| self.openExternal(u),
        .command => if (uri) |u| self.focusLink(u),
        .live_link => if (uri) |u| self.routeLivePageLink(u, mods),
        .ghoztty_window => {
            // A Ctrl-clicked popup to a real place opens a viewer window
            // there; without adoption (T3447) the page loses its opener.
            const u = uri orelse {
                log.info("viewer: a popup with no URL is not adopted on Linux yet (T3447)", .{});
                return null;
            };
            if (std.ascii.startsWithIgnoreCase(u, "http://") or std.ascii.startsWithIgnoreCase(u, "https://")) {
                self.openWindow(u);
            } else log.info("viewer: a popup to {s} is not adopted on Linux yet (T3447)", .{u});
        },
    }
    return null;
}

/// A click off a live page's site, through the banner's modifier scheme
/// (T926). A `file://` link is acted on as its path.
fn routeLivePageLink(self: *Viewer, uri: []const u8, mods: links.Mods) void {
    const act = links.livePageAction(uri, mods);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = if (std.ascii.startsWithIgnoreCase(uri, "file://"))
        content.filePath(&buf, uri) orelse return self.openExternal(uri)
    else
        uri;
    self.performLinkAction(act, target);
}

/// A clicked RELATIVE link: beside the viewed file first, then rooted - and
/// only an existing file opens (Mac's `resolveForNavigation`).
fn openRelativeLink(self: *Viewer, uri: []const u8) void {
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = links.relativePath(&rel_buf, uri) orelse return;
    const base = self.base_dir orelse return;
    const path = takeIfFile(self.alloc, content.navCandidate(self.alloc, base, rel) catch null) orelse
        takeIfFile(self.alloc, content.rootedCandidate(self.alloc, base, rel) catch null) orelse {
        // Mac returns silently; the log line is so "I clicked and nothing
        // happened" leaves a trace.
        log.info("viewer: link names no existing file: {s}", .{rel});
        return;
    };
    defer self.alloc.free(path);
    self.dispatchFileLink(path);
}

fn takeIfFile(alloc: Allocator, candidate: ?[]u8) ?[]u8 {
    const path = candidate orelse return null;
    const st = std.fs.cwd().statFile(path) catch {
        alloc.free(path);
        return null;
    };
    if (st.kind != .file) {
        alloc.free(path);
        return null;
    }
    return path;
}

/// A routed FILE: a document Ghoztty renders opens as a viewer split beside
/// this pane, anything else in its default app (`content.fileLinkAction`).
fn dispatchFileLink(self: *Viewer, path: []const u8) void {
    switch (content.fileLinkAction(path)) {
        .viewer_split => self.openSplit(path),
        .default_app => self.openWithApp(path),
    }
}

/// One link action on an already-resolved target - the click scheme's and
/// the menu's, verb for verb (win32's `performLinkMenuAction`).
fn performLinkAction(self: *Viewer, act: links.Action, target: []const u8) void {
    switch (act) {
        .open_with_system => if (banner_link.kindOf(target) == .file)
            self.openWithApp(target)
        else
            self.openExternal(target),
        .reveal_in_explorer => {
            _ = linkSink("reveal", target);
            self.revealPath(target);
        },
        .open_in_side_pane => self.openSplit(target),
        .open_in_new_window => self.openWindow(target),
        .copy => self.copyText(target),
        .focus_target => self.focusLink(target),
    }
}

fn openSplit(self: *Viewer, location: []const u8) void {
    _ = linkSink("split", location);
    const cb = self.on_open_split orelse return log.info("viewer: no pane to split for {s}", .{location});
    cb(self, location);
}

fn openWindow(self: *Viewer, location: []const u8) void {
    _ = linkSink("window", location);
    const cb = self.on_open_window orelse return log.info("viewer: no app to open a window for {s}", .{location});
    cb(self, location);
}

/// A `ghoztty://` link: raise what it names, in THIS app (T695) - never the
/// desktop's handler, which is whichever build registered the scheme.
fn focusLink(self: *Viewer, url: []const u8) void {
    _ = linkSink("focus", url);
    const cb = self.on_focus_link orelse return log.info("viewer: no app to focus {s}", .{url});
    cb(self, url);
}

fn copyText(self: *Viewer, text: []const u8) void {
    _ = linkSink("copy", text);
    const z = self.alloc.dupeZ(u8, text) catch return;
    defer self.alloc.free(z);
    wk.gdk_clipboard_set_text(wk.gtk_widget_get_clipboard(self.box), z.ptr);
}

/// The default browser (GTK's URI launcher: the OpenURI portal, else the
/// desktop's handler).
fn openExternal(self: *Viewer, uri: []const u8) void {
    if (leavesApp("browser", uri)) return;
    const z = self.alloc.dupeZ(u8, uri) catch return;
    defer self.alloc.free(z);
    log.info("viewer: open in browser {s}", .{uri});
    const launcher = wk.gtk_uri_launcher_new(z.ptr);
    wk.gtk_uri_launcher_launch(launcher, wk.gtk_widget_get_root(self.box), null, &onUriLaunched, null);
}

/// The file's default app (GTK's file launcher).
fn openWithApp(self: *Viewer, path: []const u8) void {
    if (leavesApp("app", path)) return;
    const z = self.alloc.dupeZ(u8, path) catch return;
    defer self.alloc.free(z);
    log.info("viewer: open with default app {s}", .{path});
    const file = wk.g_file_new_for_path(z.ptr);
    defer wk.g_object_unref(file);
    const launcher = wk.gtk_file_launcher_new(file);
    wk.gtk_file_launcher_launch(launcher, wk.gtk_widget_get_root(self.box), null, &onRevealFolderDone, null);
}

fn onUriLaunched(source: ?*wk.GObject, result: *wk.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const launcher: *wk.GtkUriLauncher = @ptrCast(source orelse return);
    defer wk.g_object_unref(launcher);
    var err: ?*wk.GError = null;
    if (wk.gtk_uri_launcher_launch_finish(launcher, result, &err) == 0) {
        if (err) |e| {
            defer wk.g_error_free(e);
            log.warn("viewer: opening the link failed: {s}", .{std.mem.span(e.message orelse "?")});
        }
    }
}

/// DEBUG-ONLY test seam (T3415): with `GHOZTTY_TEST_VIEWER_LINKS=<file>` set,
/// every routed link is appended there as `<verb> <target>` (`browser`,
/// `app`, `split`, `window`, `focus`, `copy`, `reveal`, `menu`). True when it
/// was recorded. Compiled out of a release.
fn linkSink(verb: []const u8, target: []const u8) bool {
    if (comptime !build_config.is_debug) return false;
    const path = std.posix.getenv("GHOZTTY_TEST_VIEWER_LINKS") orelse return false;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return false;
    defer f.close();
    f.seekFromEnd(0) catch return false;
    f.writeAll(verb) catch return false;
    f.writeAll(" ") catch return false;
    f.writeAll(target) catch return false;
    f.writeAll("\n") catch return false;
    return true;
}

/// Whether a hand-off that LEAVES the app (the browser, a default app) must
/// not run: recorded instead under the test seam, and refused outright in a
/// debug test run with no seam - inside WSL `xdg-open` can reach the
/// Windows browser, so a headless test that escaped would put a window on
/// the user's desktop (win32's T594 rule, same shape).
fn leavesApp(verb: []const u8, target: []const u8) bool {
    if (comptime !build_config.is_debug) return false;
    if (linkSink(verb, target)) return true;
    if (std.posix.getenv("GHOZTTY_TEST_VIEWER_DUMP") != null) {
        log.err("viewer: a test run refused to hand {s} to the desktop ({s})", .{ target, verb });
        return true;
    }
    return false;
}

// ---- The link menu ---------------------------------------------------------

/// A right-click landed on a link `links.js` recognised, and it has already
/// suppressed WebKit's menu - so a menu is owed. The href is resolved to
/// what the menu acts on FIRST (win32's `armLinkMenu`): a relative doc link
/// or a link in a rendered page is the FILE it names, since the URL means
/// nothing outside this process.
fn armLinkMenu(self: *Viewer, href: []const u8) void {
    var kind: links.Kind = .web;
    const target: [:0]u8 = switch (links.menuTarget(href)) {
        // Filtered by the script before it posts; a page posting to the
        // bridge by hand gets nothing.
        .none => return,
        .command => blk: {
            kind = .command;
            break :blk self.alloc.dupeZ(u8, href) catch return;
        },
        .web => self.alloc.dupeZ(u8, href) catch return,
        .file_url => blk: {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            kind = .file;
            break :blk self.alloc.dupeZ(u8, content.filePath(&buf, href) orelse return) catch return;
        },
        .viewer_relative => blk: {
            kind = .file;
            break :blk self.resolveViewerRelative(href) orelse return;
        },
        .page_relative => blk: {
            kind = .file;
            break :blk self.resolvePageRelative(href) orelse return;
        },
    };
    if (self.menu_target) |old| self.alloc.free(old);
    self.menu_target = target;
    self.menu_kind = kind;
    self.showLinkMenu();
}

/// A relative doc link, resolved the way a CLICK resolves it - except that
/// with nothing there the unchecked candidate is the answer, so Copy Path
/// still names the file a broken link meant.
fn resolveViewerRelative(self: *Viewer, href: []const u8) ?[:0]u8 {
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = links.relativePath(&rel_buf, href) orelse return null;
    const base = self.base_dir orelse return null;
    const found = takeIfFile(self.alloc, content.navCandidate(self.alloc, base, rel) catch null) orelse
        takeIfFile(self.alloc, content.rootedCandidate(self.alloc, base, rel) catch null) orelse
        (content.navCandidate(self.alloc, base, rel) catch null) orelse return null;
    defer self.alloc.free(found);
    return self.alloc.dupeZ(u8, found) catch null;
}

/// A link inside a rendered `.html` page, under that page's own grant - the
/// same root and containment refusal that serve its subresources.
fn resolvePageRelative(self: *Viewer, href: []const u8) ?[:0]u8 {
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = links.pagePath(&rel_buf, href) orelse return null;
    const root = self.base_dir orelse return null;
    const p = (content.candidateUnder(self.alloc, root, rel) catch null) orelse return null;
    defer self.alloc.free(p);
    return self.alloc.dupeZ(u8, p) catch null;
}

/// Pop the menu at the pointer. Its rows, order and ids are `banner_link`'s
/// (the same menu a banner link shows); separators become GMenu sections.
fn showLinkMenu(self: *Viewer) void {
    const target = self.menu_target orelse return;
    var buf: [links.max_items]links.Item = undefined;
    const items = links.menu(self.menu_kind, &buf);

    // The test seam: a headless Weston has no seat, so a grabbing popup
    // cannot be shown there. What the menu WOULD offer is recorded, and the
    // steps runner's `menu-pick` runs a row's action.
    if (comptime build_config.is_debug) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        // `<kind> <target> rows=a|b,c|d`: `|` is a separator, `,` joins a
        // group.
        line.print(self.alloc, "{s} {s} rows=", .{ @tagName(self.menu_kind), target }) catch return;
        var comma = false;
        for (items) |it| switch (it) {
            .separator => {
                line.append(self.alloc, '|') catch return;
                comma = false;
            },
            .cmd => |c| {
                if (comma) line.append(self.alloc, ',') catch return;
                line.appendSlice(self.alloc, c.action_name) catch return;
                comma = true;
            },
        };
        if (linkSink("menu", line.items)) return;
    }

    const group = wk.g_simple_action_group_new();
    defer wk.g_object_unref(group);
    const root_menu = wk.g_menu_new();
    defer wk.g_object_unref(root_menu);
    var section = wk.g_menu_new();
    var section_items: usize = 0;
    for (items) |it| switch (it) {
        .separator => {
            if (section_items > 0) wk.g_menu_append_section(root_menu, null, section);
            wk.g_object_unref(section);
            section = wk.g_menu_new();
            section_items = 0;
        },
        .cmd => |c| {
            const action = wk.g_simple_action_new(c.action_name.ptr, null);
            _ = wk.g_signal_connect_data(action, "activate", @ptrCast(&onMenuAction), self, null, 0);
            wk.g_action_map_add_action(group, action);
            wk.g_object_unref(action);
            var detailed: [64]u8 = undefined;
            const d = std.fmt.bufPrintZ(&detailed, "vlink.{s}", .{c.action_name}) catch continue;
            wk.g_menu_append(section, c.title.ptr, d.ptr);
            section_items += 1;
        },
    };
    if (section_items > 0) wk.g_menu_append_section(root_menu, null, section);
    wk.g_object_unref(section);

    const w = wk.asWidget(self.view);
    wk.gtk_widget_insert_action_group(w, "vlink", group);
    const pop = wk.gtk_popover_menu_new_from_model(root_menu);
    wk.gtk_widget_set_parent(pop, w);
    wk.gtk_popover_set_has_arrow(pop, 0);
    const rect: wk.GdkRectangle = .{
        .x = @intFromFloat(@max(0, self.pointer_x)),
        .y = @intFromFloat(@max(0, self.pointer_y)),
        .width = 1,
        .height = 1,
    };
    wk.gtk_popover_set_pointing_to(pop, &rect);
    // One popover per right-click: unparented once it closes, after GTK has
    // finished with the activation that closed it.
    _ = wk.g_signal_connect_data(pop, "closed", @ptrCast(&onMenuClosed), null, null, 0);
    wk.gtk_popover_popup(pop);
}

fn onMenuAction(action: *wk.GSimpleAction, _: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    const id = links.idFromActionName(std.mem.span(wk.g_action_get_name(action))) orelse return;
    self.pickLinkMenuRow(id);
}

/// Run a menu row's action on the armed target.
fn pickLinkMenuRow(self: *Viewer, id: banner_link.Id) void {
    const target = self.menu_target orelse return;
    log.info("viewer: link menu {s} on {s}", .{ links.actionName(id), target });
    self.performLinkAction(links.actionFor(id), target);
}

fn onMenuClosed(pop: *wk.GtkWidget, _: ?*anyopaque) callconv(.c) void {
    _ = wk.g_idle_add(&unparentMenu, pop);
}

fn unparentMenu(data: ?*anyopaque) callconv(.c) c_int {
    const pop: *wk.GtkWidget = @ptrCast(data orelse return 0);
    wk.gtk_widget_unparent(pop);
    return 0;
}

// -------------------------------------------------------------------------
// Pane keys
// -------------------------------------------------------------------------

fn onKeyPressed(
    _: *wk.GtkEventController,
    keyval: c_uint,
    _: c_uint,
    state: c_uint,
    ud: ?*anyopaque,
) callconv(.c) c_int {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return 0));
    return @intFromBool(self.handleKey(keyval, state));
}

/// One key press in the pane. True when the pane claimed it; false leaves it
/// to the page or the focused field, and from there to the app's bindings.
pub fn handleKey(self: *Viewer, keyval: u32, state: u32) bool {
    const action = chrome.classify(keyval, state, .{
        .address = self.addressHasFocus(),
        .find = self.findHasFocus(),
        .diff_filter = self.diff.filterHasFocus(self),
        .find_open = self.find_open,
    }) orelse return false;
    switch (action) {
        .pane => |c| switch (c) {
            .reload => self.reloadContent(.chrome),
            .focus_address => self.focusAddress(),
            // A chord this pane cannot answer (a picture has no text; Ctrl+G
            // with no search yet) falls through, as an unclaimed one does.
            .find => if (!self.openFind()) return false,
            .find_next => if (!self.stepFindFromKeyboard(1)) return false,
            .find_previous => if (!self.stepFindFromKeyboard(-1)) return false,
        },
        // An image pane zooms the PICTURE (Ctrl+0 = 100%), not the page.
        .zoom => |z| if (self.mode == .image) self.image.zoomChord(self, z) else self.zoom(z),
        .field => |f| switch (f) {
            .revert_address => self.cancelAddressEdit(),
            .close_find => self.closeFind(),
            .find_next => self.stepFind(1),
            .find_previous => self.stepFind(-1),
            // The whole file list back, the caret to the diff (T3417).
            .clear_diff_filter => self.diff.clearFilter(self),
        },
    }
    log.debug("viewer: key {x} state {x} -> {s}", .{ keyval, state, @tagName(action) });
    return true;
}

// -------------------------------------------------------------------------
// Find in page (T3414)
// -------------------------------------------------------------------------
//
// The search is the shared `src/viewer/find.js` - the index, the matching,
// the Custom Highlight painting, the live re-scan, the 5000 cap and the
// honesty note are all its, for every platform at once. This side is the
// card, the chords, and the bridge the count comes back up. Every decision is
// the Mac's (`ViewerView` "Find in page") by way of win32's pure
// `viewer_find.zig`: how the count reads, which field Escape/Return belong
// to, the exact JavaScript pushed into the page.

/// Inject `find.js` into every document this view loads - the template AND a
/// website, which is why it cannot live in `viewer.js` - and listen on the
/// `viewerTOC` handler it posts to. Mac: a `WKUserScript` at document end,
/// main frame only (a subframe copy would be a second search with its own
/// count; `find.js` says "frames not searched" instead). Must run before the
/// first navigation: a script added mid-load does not reach that page.
fn installFindScript(self: *Viewer) void {
    const m = wk.webkit_web_view_get_user_content_manager(self.view);
    _ = wk.g_object_ref(m);
    self.ucm = m;
    const script = wk.webkit_user_script_new(bridge.find_js, wk.inject_top_frame, wk.inject_at_document_end, null, null);
    wk.webkit_user_content_manager_add_script(m, script);
    wk.webkit_user_script_unref(script);
    // The Quote/Copy selection toolbar (T3545): the shared `selection.js`,
    // in every page like `find.js` and for the same reason, main frame only
    // (win32's rule: it positions itself in viewport coordinates a subframe
    // does not share). It posts `quote`/`copy` on the same handler.
    const sel = wk.webkit_user_script_new(quoting.selection_script, wk.inject_top_frame, wk.inject_at_document_end, null, null);
    wk.webkit_user_content_manager_add_script(m, sel);
    wk.webkit_user_script_unref(sel);
    if (wk.webkit_user_content_manager_register_script_message_handler(m, bridge.handler_name, null) == 0) {
        // The page still searches and paints; only the count goes quiet.
        log.warn("viewer: could not register the {s} message handler; find shows no count", .{bridge.handler_name});
        return;
    }
    self.message_handler = wk.g_signal_connect_data(
        m,
        "script-message-received::" ++ bridge.handler_name,
        @ptrCast(&onScriptMessage),
        self,
        null,
        0,
    );
}

/// A message from the page. The template's `viewer.js` posts on the same
/// handler: `find`, the link menu, an image or diff report, and the heading
/// index and scroll spy (T3418) are acted on here, and
/// anything a website posts that does not parse is ignored (`bridge.parse`).
fn onScriptMessage(_: *wk.UserContentManager, value: *wk.JSCValue, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    const json = wk.jsc_value_to_json(value, 0) orelse return;
    defer wk.g_free(json);
    const text = std.mem.span(json);
    const parsed = bridge.parse(self.alloc, text) orelse {
        // The toolbar's Copy (T3545): GTK owns the clipboard natively.
        if (quoting.copyText(self.alloc, text)) |t| {
            defer self.alloc.free(t);
            self.copyText(t);
            log.info("viewer: copied the page selection bytes={d}", .{t.len});
        }
        return;
    };
    defer parsed.deinit();
    switch (parsed.message) {
        // The toolbar's Quote (T3545): into the feedback composer.
        .quote => |q| self.feedback.acceptQuote(self, q),
        .find => |f| self.applyFindMessage(f),
        // `links.js` (T3415) suppressed WebKit's menu over a link of ours.
        .link_menu => |href| self.armLinkMenu(href),
        // `image.js` (T3416): a measurement or a gesture to answer.
        .image => |m| self.image.onMessage(self, m),
        // `diff.js` ran out of changes: roll into the adjacent file (T3417).
        .diff_nav_overflow => |forward| self.diff.navOverflow(self, forward),
        // `viewer.js` (T3418): the heading index, and the scroll spy.
        .headings => |h| self.toc.setHeadings(self, h),
        .active => |id| self.toc.setActive(id),
        else => {},
    }
}

fn buildFindCard() FindCard {
    const card = wk.gtk_box_new(wk.orientation_vertical, 2);
    wk.gtk_widget_add_css_class(card, "card");
    wk.gtk_widget_set_halign(card, wk.align_end);
    wk.gtk_widget_set_valign(card, wk.align_start);
    // win32's `margin_dip`: off the page's top and trailing edges.
    wk.gtk_widget_set_margin_top(card, 8);
    wk.gtk_widget_set_margin_end(card, 8);

    const row = wk.gtk_box_new(wk.orientation_horizontal, 4);
    wk.gtk_widget_set_margin_start(row, 8);
    wk.gtk_widget_set_margin_end(row, 4);
    wk.gtk_widget_set_margin_top(row, 6);
    wk.gtk_widget_set_margin_bottom(row, 6);

    const f: FindCard = .{
        .card = card,
        .entry = wk.gtk_entry_new(),
        .count = wk.gtk_label_new(""),
        .previous = barButton("go-up-symbolic", "Previous Match (Shift+Enter)"),
        .next = barButton("go-down-symbolic", "Next Match (Enter)"),
        .close = barButton("window-close-symbolic", "Close (Escape)"),
        .note = wk.gtk_label_new(""),
    };
    wk.gtk_entry_set_placeholder_text(f.entry, "Find");
    wk.gtk_editable_set_width_chars(f.entry, 18);
    wk.gtk_widget_add_css_class(f.count, "dim-label");
    wk.gtk_widget_add_css_class(f.count, "numeric");
    wk.gtk_widget_set_visible(f.count, 0);
    inline for (.{ "entry", "count", "previous", "next", "close" }) |name| {
        wk.gtk_box_append(row, @field(f, name));
    }
    wk.gtk_widget_add_css_class(f.note, "dim-label");
    wk.gtk_widget_add_css_class(f.note, "caption");
    wk.gtk_label_set_xalign(f.note, 0);
    wk.gtk_widget_set_margin_start(f.note, 10);
    wk.gtk_widget_set_margin_end(f.note, 8);
    wk.gtk_widget_set_margin_bottom(f.note, 6);
    wk.gtk_widget_set_visible(f.note, 0);
    wk.gtk_box_append(card, row);
    wk.gtk_box_append(card, f.note);
    wk.gtk_widget_set_visible(card, 0);
    return f;
}

fn findQuery(self: *const Viewer) []const u8 {
    return self.find_query[0..self.find_query_len];
}

fn findHasFocus(self: *const Viewer) bool {
    if (!self.find_open) return false;
    const f = self.focusWidget() orelse return false;
    return f == self.find.entry or wk.gtk_widget_is_ancestor(f, self.find.entry) != 0;
}

/// Ctrl+F: open the card and put the caret in it with whatever query is
/// already there selected, so the next keystroke replaces it (the browser
/// rule, and the one `focusAddress` follows). Re-running the search on open
/// is what makes Ctrl+F, Escape, Ctrl+F come back to the same highlights.
/// False for a pane with nothing to search (a picture), so the chord falls
/// through rather than being swallowed.
pub fn openFind(self: *Viewer) bool {
    if (!chrome.canFind(self.mode)) return false;
    if (!self.find_open) {
        self.find_open = true;
        self.find_result = .none;
        self.syncFindCount();
        self.setFindNote(null);
        wk.gtk_widget_set_visible(self.find.card, 1);
    }
    _ = wk.gtk_widget_grab_focus(self.find.entry);
    wk.gtk_editable_select_region(self.find.entry, 0, -1);
    if (self.find_query_len > 0) self.pushFindQuery();
    // The acceptance script's oracle: there are no pixels in the harness.
    log.info("viewer: find state=open query={s}", .{self.findQuery()});
    return true;
}

/// Escape: close the card, clear the page's highlights, keep the query.
/// The page is cleared unconditionally, ahead of the open check - the
/// highlights are the PAGE's state, and close must never leave them painted
/// on a pane with no card to remove them with.
pub fn closeFind(self: *Viewer) void {
    self.runQuiet(vfind.clear_call);
    self.find_result = .none;
    if (!self.find_open) return;
    const had_focus = if (self.focusWidget()) |f| f == self.box or wk.gtk_widget_is_ancestor(f, self.box) != 0 else false;
    self.find_open = false;
    wk.gtk_widget_set_visible(self.find.card, 0);
    // A closed card counts nothing: `openFind` re-syncs both on the way back.
    wk.gtk_widget_set_visible(self.find.count, 0);
    self.setFindNote(null);
    log.info("viewer: find state=closed query={s}", .{self.findQuery()});
    // Focus back to the page, so the pane is usable again.
    if (had_focus) self.focusContent();
}

/// Step to the next (+1) or previous (-1) match, wrapping.
pub fn stepFind(self: *Viewer, delta: i32) void {
    if (self.find_query_len == 0) return;
    self.runQuiet(if (delta < 0) vfind.step_previous_call else vfind.step_next_call);
}

/// Ctrl+G / F3 and their shifted twins: step the last search, re-opening the
/// card if it was closed. False when there is nothing to step, so the chord
/// falls through to the app's bindings instead of being eaten.
pub fn stepFindFromKeyboard(self: *Viewer, delta: i32) bool {
    if (!chrome.canFind(self.mode) or self.find_query_len == 0) return false;
    if (!self.find_open and !self.openFind()) return false;
    self.stepFind(delta);
    return true;
}

/// The user typed in the card. Pushed straight through, no debounce: the page
/// caches its text index between keystrokes and rebuilds it only when the DOM
/// moves (Mac's `setFindQuery`).
fn findQueryChanged(self: *Viewer) void {
    const text = vfind.truncateUtf8(std.mem.span(wk.gtk_editable_get_text(self.find.entry)), vfind.max_query);
    if (std.mem.eql(u8, text, self.findQuery())) return;
    @memcpy(self.find_query[0..text.len], text);
    self.find_query_len = text.len;
    // An emptied field takes the count with it before the page answers.
    if (text.len == 0) self.find_result = .none;
    self.syncFindCount();
    self.pushFindQuery();
}

fn pushFindQuery(self: *Viewer) void {
    var buf: [vfind.search_call_cap]u8 = undefined;
    self.runQuiet(vfind.searchCall(&buf, self.findQuery()));
}

/// `find.js` reported a count. A report for a query the user has already
/// typed past is stale - the push for the current one is on its way.
fn applyFindMessage(self: *Viewer, msg: bridge.Find) void {
    if (!std.mem.eql(u8, msg.query, self.findQuery())) return;
    if (!self.find_open) return;
    self.find_result = .{ .total = msg.total, .index = msg.index, .truncated = msg.truncated };
    self.syncFindCount();
    self.setFindNote(msg.note);
    log.info("viewer: find state=count query={s} total={d} index={d} truncated={} note={s}", .{
        msg.query,
        msg.total,
        msg.index,
        msg.truncated,
        msg.note orelse "-",
    });
}

/// After a load: the script was re-injected into the new document with no
/// state, so an open card would be counting a page that is gone. A pane that
/// navigated to something it cannot search closes the card instead.
fn refreshFindAfterLoad(self: *Viewer) void {
    if (!self.find_open) return;
    if (!chrome.canFind(self.mode)) return self.closeFind();
    if (self.find_query_len == 0) return;
    self.find_result = .none;
    self.syncFindCount();
    self.pushFindQuery();
}

/// The count as a browser reads it: "3/17", "12/5000+", "No results", or
/// nothing at all while the field is empty.
fn syncFindCount(self: *Viewer) void {
    var buf: [vfind.Result.label_cap]u8 = undefined;
    const label = self.find_result.label(&buf, self.find_query_len > 0) orelse {
        wk.gtk_widget_set_visible(self.find.count, 0);
        wk.gtk_label_set_text(self.find.count, "");
        return;
    };
    var zbuf: [vfind.Result.label_cap + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{label}) catch return;
    wk.gtk_label_set_text(self.find.count, z.ptr);
    wk.gtk_widget_set_visible(self.find.count, 1);
}

/// The honesty note's own line under the row, shown only with something in it.
fn setFindNote(self: *Viewer, note: ?[]const u8) void {
    const text = note orelse {
        wk.gtk_widget_set_visible(self.find.note, 0);
        wk.gtk_label_set_text(self.find.note, "");
        return;
    };
    var zbuf: [257]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{vfind.truncateUtf8(text, 256)}) catch return;
    wk.gtk_label_set_text(self.find.note, z.ptr);
    wk.gtk_widget_set_visible(self.find.note, 1);
}

/// Evaluate a page call whose result nobody reads: find's calls must never
/// count as a render the way `evaluate`'s do.
pub fn runQuiet(self: *Viewer, js: []const u8) void {
    wk.webkit_web_view_evaluate_javascript(self.view, js.ptr, @intCast(js.len), null, null, null, null, null);
}

fn onFindChanged(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.findQueryChanged();
}

fn onFindPreviousClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.stepFind(-1);
}

fn onFindNextClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.stepFind(1);
}

fn onFindCloseClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    self.closeFind();
}

// -------------------------------------------------------------------------
// Rendering
// -------------------------------------------------------------------------

/// The template finished loading: put the document on it.
fn renderTemplate(self: *Viewer) void {
    self.needs_render = false;
    switch (self.mode) {
        .markdown, .code => {
            const path = self.file_path orelse return self.showError(content.error_unreadable, self.current);
            const out = document.readUtf8(self.alloc, self.mode, path);
            defer out.deinit(self.alloc);
            switch (out) {
                .script => |js| self.evaluate(js),
                .failure => |title| self.showError(title, path),
                .none => self.finishRender(true, ""),
            }
        },
        .image => self.image.start(self),
        .diff => self.diff.start(self),
        .web, .html => self.finishRender(true, ""),
    }
}

pub fn showError(self: *Viewer, title: []const u8, detail: []const u8) void {
    const js = content.setErrorCall(self.alloc, title, detail) catch return self.finishRender(false, title);
    defer self.alloc.free(js);
    self.evaluate(js);
}

/// A failure before anything could load: there is no page to put a card on.
fn fail(self: *Viewer, title: []const u8, detail: []const u8) void {
    log.warn("viewer: {s}: {s}", .{ title, detail });
    self.syncChrome();
    self.finishRender(false, title);
}

/// A page call that counts as a render (the test hooks wait on it).
pub fn evaluateRender(self: *Viewer, js: []const u8) void {
    self.evaluate(js);
}

fn evaluate(self: *Viewer, js: []const u8) void {
    wk.webkit_web_view_evaluate_javascript(
        self.view,
        js.ptr,
        @intCast(js.len),
        null,
        null,
        null,
        &onRenderEvaluated,
        self,
    );
}

fn onRenderEvaluated(source: ?*wk.GObject, result: *wk.GAsyncResult, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    var err: ?*wk.GError = null;
    const value = wk.webkit_web_view_evaluate_javascript_finish(@ptrCast(source orelse return), result, &err);
    if (value) |v| wk.g_object_unref(v);
    if (err) |e| {
        defer wk.g_error_free(e);
        const msg = std.mem.span(e.message orelse "script failed");
        log.warn("viewer: page call failed: {s}", .{msg});
        return self.finishRender(false, msg);
    }
    self.finishRender(true, "");
}

pub fn finishRender(self: *Viewer, ok: bool, detail: []const u8) void {
    self.render_count += 1;
    if (self.on_rendered) |cb| cb(self, ok, detail);
    if (comptime build_config.is_debug) steps.onRendered(self, ok);
}

fn onLoadChanged(view: *wk.WebView, event: wk.LoadEvent, ud: ?*anyopaque) callconv(.c) void {
    _ = view;
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    // The crash card (T3413) is not the pane's document: it neither moves
    // the pane nor takes a render, and the load after it is the pane again.
    switch (self.crash_card) {
        .none => {},
        .pending, .shown => {
            if (event == .started and self.crash_card == .shown) {
                self.crash_card = .none;
            } else {
                if (event == .started) self.crash_card = .shown;
                if (event == .finished) {
                    self.crash_card = .shown;
                    self.page_live = true;
                    self.syncChrome();
                    self.finishRender(false, reload_policy.keeps_crashing_title);
                }
                return;
            }
        },
    }
    switch (event) {
        .started => {
            self.page_live = false;
            self.toc.pageGone();
        },
        .committed => self.syncCommitted(),
        .finished => {
            self.page_live = true;
            self.syncChrome();
            // Ahead of the template's render: the page's own observer picks
            // the rendered document up 200 ms later, so the count follows it.
            self.refreshFindAfterLoad();
            if (self.mode.usesTemplate()) {
                if (self.needs_render) self.renderTemplate();
            } else self.finishRender(true, "");
        },
        else => {},
    }
}

fn onLoadFailed(
    view: *wk.WebView,
    event: wk.LoadEvent,
    failing_uri: [*:0]const u8,
    err: *wk.GError,
    ud: ?*anyopaque,
) callconv(.c) c_int {
    _ = view;
    _ = event;
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return 0));
    const msg = std.mem.span(err.message orelse "load failed");
    log.warn("viewer: load failed uri={s} err={s}", .{ failing_uri, msg });
    self.finishRender(false, msg);
    // Let WebKit show its own error page.
    return 0;
}

fn onDestroy(view: *wk.WebView, ud: ?*anyopaque) callconv(.c) void {
    const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
    wk.g_object_set_data(view, data_key, null);
    self.deinit();
}

// -------------------------------------------------------------------------
// The scheme handlers
// -------------------------------------------------------------------------

var schemes_registered: bool = false;

/// Register both schemes on WebKit's default context, once per process.
/// Registering one twice is a GLib critical, and every viewer shares them.
fn registerSchemes() void {
    if (schemes_registered) return;
    schemes_registered = true;
    prepareWebProcessEnv();
    const ctx = wk.webkit_web_context_get_default();
    wk.webkit_web_context_register_uri_scheme(ctx, scheme.template_scheme, &onSchemeRequest, null, null);
    wk.webkit_web_context_register_uri_scheme(ctx, scheme.page_scheme, &onSchemeRequest, null, null);
    // Local: a website in another pane cannot load (and so cannot probe for)
    // anything these schemes serve. Secure: the pages are secure contexts, as
    // the Mac's custom-scheme pages are.
    const sm = wk.webkit_web_context_get_security_manager(ctx);
    inline for (.{ scheme.template_scheme, scheme.page_scheme }) |s| {
        wk.webkit_security_manager_register_uri_scheme_as_local(sm, s);
        wk.webkit_security_manager_register_uri_scheme_as_secure(sm, s);
    }
}

/// Keep WSLg's GPU driver choice away from WebKit's web processes.
///
/// `GALLIUM_DRIVER=d3d12` is how Mesa reaches the GPU under WSLg (T3350): the
/// driver talks to `/dev/dxg` and loads from `/usr/lib/wsl/lib`. WebKit runs
/// its web processes inside a bubblewrap sandbox that exposes neither, so a
/// web process that inherits the override cannot create its EGL display and
/// aborts (`Could not create surfaceless EGL display: EGL_NOT_INITIALIZED`)
/// before a page ever loads - measured 2026-11-22, and it renders the moment
/// the variable is unset, with the sandbox left on. Disabling the sandbox
/// would also work and is not an option.
///
/// The app's own renderer still wants the GPU, so GDK's GL is brought up
/// FIRST (`gdk_display_prepare_gl` is a no-op once it is up): Mesa reads the
/// override when the display's EGL is initialized, and every later context
/// reuses that display. Only then is the variable removed, before the first
/// web view can spawn a web process - which is also T3350's own rule that the
/// override must not leak into what the app spawns. Only the d3d12 value is
/// touched; any other override is the user's and is left alone.
fn prepareWebProcessEnv() void {
    const value = std.posix.getenv("GALLIUM_DRIVER") orelse return;
    if (!std.mem.eql(u8, value, "d3d12")) return;
    if (wk.gdk_display_get_default()) |display| {
        var err: ?*wk.GError = null;
        if (wk.gdk_display_prepare_gl(display, &err) == 0) {
            if (err) |e| {
                log.warn("viewer: GDK GL not available before the web process starts: {s}", .{std.mem.span(e.message orelse "?")});
                wk.g_error_free(e);
            }
        }
    }
    _ = internal_os.unsetenv("GALLIUM_DRIVER");
    log.info("viewer: GALLIUM_DRIVER=d3d12 kept from WebKit's sandboxed web processes (the app's GL already chose its driver)", .{});
}

/// The viewer a web view carries, or null once it has gone.
pub fn fromWebView(view: *wk.WebView) ?*Viewer {
    return @ptrCast(@alignCast(wk.g_object_get_data(view, data_key) orelse return null));
}

fn onSchemeRequest(req: *wk.URISchemeRequest, _: ?*anyopaque) callconv(.c) void {
    const uri = std.mem.span(wk.webkit_uri_scheme_request_get_uri(req));
    const view = wk.webkit_uri_scheme_request_get_web_view(req);
    const self: *Viewer = @ptrCast(@alignCast(wk.g_object_get_data(view, data_key) orelse
        return finishNotFound(req, "no viewer owns this web view")));
    self.serve(req, uri) catch |err| {
        log.warn("viewer: serving {s} failed err={}", .{ uri, err });
        finishNotFound(req, "cannot read");
    };
}

fn serve(self: *Viewer, req: *wk.URISchemeRequest, uri: []const u8) !void {
    const origin = scheme.originOf(uri) orelse return finishNotFound(req, "not a viewer URI");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = scheme.requestPath(&buf, origin, uri) orelse return finishNotFound(req, "empty path");

    // An image pane's picture (T3416): the viewed file, by its route - never
    // a file of that name beside it, and nothing at all for another mode.
    if (origin == .template and image_rules.isResource(rel)) {
        if (self.mode == .image) if (self.file_path) |p| return self.image.serve(req, p);
        return finishNotFound(req, "not an image pane");
    }

    var cands = try scheme.candidates(self.alloc, origin, .{
        .assets_dir = self.assets_dir,
        .base_dir = self.base_dir,
    }, rel);
    defer cands.deinit(self.alloc);

    for (cands.slice()) |path| {
        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();
        const stat = file.stat() catch continue;
        if (stat.kind != .file) continue;
        const bytes = file.readToEndAlloc(std.heap.c_allocator, content.max_file_bytes) catch continue;
        // The stream owns the bytes and frees them with libc's `free`, which is
        // what `c_allocator` allocated them with.
        const stream = wk.g_memory_input_stream_new_from_data(bytes.ptr, @intCast(bytes.len), @ptrCast(&std.c.free));
        defer wk.g_object_unref(stream);
        var mime_buf: [128]u8 = undefined;
        const mime = std.fmt.bufPrintZ(&mime_buf, "{s}", .{scheme.mimeType(path)}) catch "application/octet-stream";
        wk.webkit_uri_scheme_request_finish(req, stream, @intCast(bytes.len), mime.ptr);
        return;
    }
    log.debug("viewer: no file for {s}", .{uri});
    finishNotFound(req, "not found");
}

pub fn finishNotFound(req: *wk.URISchemeRequest, why: [*:0]const u8) void {
    const err = wk.g_error_new_literal(wk.g_io_error_quark(), wk.io_error_not_found, why);
    defer wk.g_error_free(err);
    wk.webkit_uri_scheme_request_finish_error(req, err);
}

// -------------------------------------------------------------------------
// The debug test window (headless acceptance, test/linux/viewer-webkit.sh)
// -------------------------------------------------------------------------

/// In a debug build, `GHOZTTY_TEST_VIEWER=<location>` opens a plain window
/// holding one viewer at startup, and once it has rendered evaluates
/// `GHOZTTY_TEST_VIEWER_PROBE` (a JS expression; default the page's text) and
/// writes `OK <result>` or `FAIL <why>` to `GHOZTTY_TEST_VIEWER_DUMP`.
///
/// It predates viewer panes (T3411) and stays because the foundation is worth
/// proving on its own: that WebKit links, the schemes serve, and the page
/// renders the document, with no split tree in the way. The same shape as
/// `GHOZTTY_TEST_ASK_TO_CLOSE`: compiled out of a release.
pub fn openTestWindowFromEnv() void {
    if (comptime !build_config.is_debug) return;
    const location = std.posix.getenv("GHOZTTY_TEST_VIEWER") orelse return;
    const viewer = create(std.heap.c_allocator, location) catch |err| {
        log.warn("viewer test window: create failed err={}", .{err});
        writeDump("FAIL create");
        return;
    };
    viewer.on_rendered = &onTestRendered;
    const win = wk.gtk_window_new();
    wk.gtk_window_set_title(win, "ghoztty viewer test");
    wk.gtk_window_set_default_size(win, 800, 600);
    wk.gtk_window_set_child(win, viewer.widget());
    wk.gtk_window_present(win);
    log.info("viewer test window: opened mode={s} location={s}", .{ @tagName(viewer.mode), location });
}

/// The first render writes the dump; later renders (a navigation, Back) are
/// the steps runner's business.
fn onTestRendered(self: *Viewer, ok: bool, detail: []const u8) void {
    if (self.render_count != 1) return;
    log.info("viewer test window: rendered ok={} detail={s}", .{ ok, detail });
    if (!ok) {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "FAIL {s}", .{detail}) catch "FAIL";
        writeDump(line);
        appendDumpAll(self, line);
        return;
    }
    const probe = std.posix.getenv("GHOZTTY_TEST_VIEWER_PROBE") orelse "document.body.innerText";
    wk.webkit_web_view_evaluate_javascript(self.view, probe.ptr, @intCast(probe.len), null, null, null, &onTestProbed, self);
}

fn onTestProbed(source: ?*wk.GObject, result: *wk.GAsyncResult, ud: ?*anyopaque) callconv(.c) void {
    const line = probeLine(source, result) orelse return;
    defer std.heap.c_allocator.free(line);
    writeDump(line);
    // The first render's dump is down: the steps, if any, start now.
    if (comptime build_config.is_debug) {
        const self: *Viewer = @ptrCast(@alignCast(ud orelse return));
        appendDumpAll(self, line);
        steps.start(self);
    }
}

/// DEBUG-ONLY (T3420): `GHOZTTY_TEST_VIEWER_DUMP` holds the LAST viewer's
/// first render, which is all a one-viewer test needs. A test that opens
/// several at once - a session restore - also sets
/// `GHOZTTY_TEST_VIEWER_DUMP_ALL`, and every viewer's first render is
/// appended there as `<current location>\t<OK value | FAIL why>`.
fn appendDumpAll(self: *const Viewer, text: []const u8) void {
    if (comptime !build_config.is_debug) return;
    const path = std.posix.getenv("GHOZTTY_TEST_VIEWER_DUMP_ALL") orelse return;
    const f = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch |err| {
        log.warn("viewer test window: cannot append {s} err={}", .{ path, err });
        return;
    };
    defer f.close();
    f.seekFromEnd(0) catch return;
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\t{s}\n", .{ self.current, text }) catch return;
    // One write of the whole line: two viewers never interleave inside one.
    f.writeAll(line) catch {};
}

/// `OK <value>` / `FAIL <why>` for an evaluated probe. Caller frees.
fn probeLine(source: ?*wk.GObject, result: *wk.GAsyncResult) ?[]u8 {
    const alloc = std.heap.c_allocator;
    var err: ?*wk.GError = null;
    const value = wk.webkit_web_view_evaluate_javascript_finish(@ptrCast(source orelse return null), result, &err);
    if (err) |e| {
        defer wk.g_error_free(e);
        return std.fmt.allocPrint(alloc, "FAIL probe: {s}", .{std.mem.span(e.message orelse "?")}) catch null;
    }
    const v = value orelse return alloc.dupe(u8, "FAIL probe: no value") catch null;
    defer wk.g_object_unref(v);
    const s = wk.jsc_value_to_string(v) orelse return alloc.dupe(u8, "FAIL probe: not a string") catch null;
    defer wk.g_free(s);
    return std.fmt.allocPrint(alloc, "OK {s}", .{std.mem.span(s)}) catch null;
}

fn writeDump(text: []const u8) void {
    const path = std.posix.getenv("GHOZTTY_TEST_VIEWER_DUMP") orelse return;
    const f = std.fs.createFileAbsolute(path, .{}) catch |err| {
        log.warn("viewer test window: cannot write {s} err={}", .{ path, err });
        return;
    };
    defer f.close();
    f.writeAll(text) catch {};
    f.writeAll("\n") catch {};
}

// -------------------------------------------------------------------------
// The debug steps runner (headless acceptance, test/linux/viewer-nav.sh)
// -------------------------------------------------------------------------

/// DEBUG-ONLY: drive the nav bar and the pane keys from a script, because a
/// headless Weston has no seat to type into and Wayland has no input
/// injection. With `GHOZTTY_TEST_VIEWER_STEPS=<file>` set, the first viewer
/// to write its test dump then runs the file's lines in order and appends one
/// result line per step to `GHOZTTY_TEST_VIEWER_STEPS_OUT`:
///
///   key <accel>     the pane's key handler, as a GTK accelerator string
///                   (`<Control>l`): `key <accel> handled=<bool>`
///   type <text>     replace the address field's text, as typing would
///   activate        press Return in the address field (its `activate`)
///   find <text>     replace the find field's text, as typing would
///   click <button>  back|forward|reload|home|reveal|find-previous|find-next|
///                   find-close - emits the button's own `clicked`, as a
///                   pointer click does
///   wait            until the next render finishes (10 s): `wait ok=<bool>`
///   image           an image pane's zoom state (T3416): `image rev= loads=
///                   route= zoom= fitting= fit= natural=WxH viewport=WxH`
///   diff            a diff pane's state (T3417): `diff files= file= style=
///                   rows= selected= panel= listings= patches= unchanged=
///                   git= width= busy= header= filter=`
///   rows            the changed-files panel: `rows <kind>:<title>|...`
///   filter <text>   replace the panel's filter text, as typing would
///   filter-submit   Return in the filter (opens the top hit)
///   filter-focus    put the caret in the filter
///   row <id>        click the panel row with that id (a file's path)
///   click diff-prev|diff-next|diff-layout   the bar's diff controls
///   click feedback  the feedback button (T3419)
///   feedback        after any worktree resolution in flight lands (10 s):
///                   `feedback button= worktree= tip= pending= resolves=
///                   clicks=`
///   state          `state mode= current= address= back= forward= reveal=
///                   zoom= focus=address|find|content|other sel=<start>-<end>
///                   reloads=<dead-process reloads> card=none|pending|shown
///                   find=open|closed findq=<query> findsel=<start>-<end>
///                   count=<label>|- note=<note>|- barh=<bar height>`
///   probe <js>      evaluate in the page: `probe OK <value>`
///   terminate       kill the page's web process through WebKit's API, as a
///                   crash would: `terminate`
///   mods <m>        `ctrl`, `ctrl+shift` or `none`: the modifiers the next
///                   link clicks carry (WebKit reports none for a script-made
///                   click, and Weston has no seat to make a real one)
///   menu-pick <row> run a row of the last link menu (`open_browser`,
///                   `reveal`, `side_pane`, `new_window`, `open_default_app`,
///                   `copy`, `focus`) on its target: `menu-pick <row>`
///   mark <text>     `mark <text>`, a sync point for the driving script
///   sleep <ms>
///
/// The key handler is the same function the capture-phase controller calls,
/// so only GDK's delivery of the press is not exercised.
const steps = if (build_config.is_debug) struct {
    var viewer: ?*Viewer = null;
    var started = false;
    var lines: std.ArrayList([]const u8) = .empty;
    var bytes: []u8 = &.{};
    var index: usize = 0;
    var waiting = false;
    var wait_gen: u32 = 0;
    /// `mods <...>`: held "keys" for link clicks; null = none.
    var mods_override: ?links.Mods = null;

    fn start(v: *Viewer) void {
        if (started) return;
        const path = std.posix.getenv("GHOZTTY_TEST_VIEWER_STEPS") orelse return;
        started = true;
        const alloc = std.heap.c_allocator;
        bytes = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch |err| {
            log.warn("viewer steps: cannot read {s} err={}", .{ path, err });
            return;
        };
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            lines.append(alloc, line) catch return;
        }
        viewer = v;
        log.info("viewer steps: {d} step(s) from {s}", .{ lines.items.len, path });
        schedule();
    }

    fn schedule() void {
        _ = wk.g_idle_add(&runNext, null);
    }

    fn out(comptime fmt: []const u8, args: anytype) void {
        const path = std.posix.getenv("GHOZTTY_TEST_VIEWER_STEPS_OUT") orelse return;
        const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
        defer f.close();
        f.seekFromEnd(0) catch return;
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        f.writeAll(s) catch {};
    }

    fn runNext(_: ?*anyopaque) callconv(.c) c_int {
        const v = viewer orelse return 0;
        if (index >= lines.items.len) {
            out("done", .{});
            return 0;
        }
        const line = lines.items[index];
        index += 1;
        const sp = std.mem.indexOfScalar(u8, line, ' ');
        const verb = if (sp) |i| line[0..i] else line;
        const arg = if (sp) |i| line[i + 1 ..] else "";

        if (std.mem.eql(u8, verb, "key")) {
            var zbuf: [128]u8 = undefined;
            const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{arg}) catch "";
            var kv: c_uint = 0;
            var mods: c_uint = 0;
            if (wk.gtk_accelerator_parse(z.ptr, &kv, &mods) == 0) {
                out("key {s} PARSE-FAILED", .{arg});
            } else {
                out("key {s} handled={}", .{ arg, v.handleKey(kv, mods) });
            }
        } else if (std.mem.eql(u8, verb, "type")) {
            var zbuf: [2048]u8 = undefined;
            const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{arg}) catch "";
            wk.gtk_editable_set_text(v.bar.address, z.ptr);
            out("type {s}", .{arg});
        } else if (std.mem.eql(u8, verb, "find")) {
            // Replace the find field's text, as typing would: its `changed`
            // runs the search. An empty argument empties the field.
            var zbuf: [2048]u8 = undefined;
            const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{arg}) catch "";
            wk.gtk_editable_set_text(v.find.entry, z.ptr);
            out("find {s}", .{arg});
        } else if (std.mem.eql(u8, verb, "activate")) {
            // What Return in the field does: GtkText re-emits it as the
            // entry's own `activate` (`gtk_widget_activate` does not).
            wk.g_signal_emit_by_name(v.bar.address, "activate");
            out("activate", .{});
        } else if (std.mem.eql(u8, verb, "click")) {
            const named = .{
                .{ "back", v.bar.back },
                .{ "forward", v.bar.forward },
                .{ "reload", v.bar.reload },
                .{ "home", v.bar.home },
                .{ "reveal", v.bar.reveal },
                .{ "find-previous", v.find.previous },
                .{ "find-next", v.find.next },
                .{ "find-close", v.find.close },
                .{ "diff-prev", if (v.diff.ui) |u| u.prev else null },
                .{ "diff-next", if (v.diff.ui) |u| u.next else null },
                .{ "diff-layout", if (v.diff.ui) |u| u.layout else null },
                .{ "contents", v.toc.buttonWidget() },
                .{ "feedback", v.feedback.buttonWidget() },
                .{ "feedback-send", v.feedback.sendButtonWidget() },
            };
            var b: ?*wk.GtkWidget = null;
            inline for (named) |n| {
                if (std.mem.eql(u8, arg, n[0])) b = n[1];
            }
            if (b) |w| {
                const sens = wk.gtk_widget_get_sensitive(w) != 0;
                const vis = wk.gtk_widget_get_visible(w) != 0;
                // A real click cannot reach an insensitive or hidden button.
                // `clicked` itself, as a pointer click emits it: a button's
                // keyboard `activate` delays it by 250 ms.
                if (sens and vis) wk.g_signal_emit_by_name(w, "clicked");
                out("click {s} sensitive={} visible={}", .{ arg, sens, vis });
            } else out("click {s} NO-SUCH-BUTTON", .{arg});
        } else if (std.mem.eql(u8, verb, "wait")) {
            waiting = true;
            wait_gen +%= 1;
            const gen = wait_gen;
            _ = wk.g_timeout_add(10_000, &waitTimeout, @ptrFromInt(@as(usize, gen) + 1));
            return 0;
        } else if (std.mem.eql(u8, verb, "state")) {
            writeState(v);
        } else if (std.mem.eql(u8, verb, "feedback")) {
            // The feedback button (T3419), once any worktree resolution in
            // flight has landed (10 s): `feedback button= worktree= tip=
            // pending= resolves= clicks=`.
            feedback_polls = 0;
            _ = wk.g_timeout_add(50, &feedbackPoll, null);
            return 0;
        } else if (std.mem.eql(u8, verb, "composer")) {
            // The feedback composer (T3544), once its page is up and no send
            // is out (10 s): `composer open= view= ready= lines= sending=
            // sends= filed= status=... text=...`.
            composer_polls = 0;
            _ = wk.g_timeout_add(50, &composerPoll, null);
            return 0;
        } else if (std.mem.eql(u8, verb, "composer-type")) {
            // Type into the composer as the keyboard would - the engine's
            // own insertText, so the page's `input` snapshot carries it up.
            // `\n` in the argument is a newline (plain Enter's).
            const ok = composerEval(v, "(function(){{var c=document.getElementById('c');c.focus();" ++
                "document.execCommand('insertText',false,{s});return 'typed'}})()", arg, true);
            out("composer-type {s} ok={}", .{ arg, ok });
        } else if (std.mem.eql(u8, verb, "composer-key")) {
            // A keydown in the composer page: `ctrl+Enter` or `Escape`. The
            // shim's chords run on keydown, which is what this fires.
            const ctrl = std.mem.startsWith(u8, arg, "ctrl+");
            const key = if (ctrl) arg["ctrl+".len..] else arg;
            var jbuf: [256]u8 = undefined;
            const js = std.fmt.bufPrint(&jbuf, "(function(){{document.getElementById('c').dispatchEvent(new KeyboardEvent('keydown'," ++
                "{{key:'{s}',ctrlKey:{},bubbles:true,cancelable:true}}));return 'k'}})()", .{ key, ctrl }) catch "";
            const ok = composerEval(v, "{s}", js, false);
            out("composer-key {s} ok={}", .{ arg, ok });
        } else if (std.mem.eql(u8, verb, "composer-probe")) {
            // Evaluate in the COMPOSER's page; prints `probe ...` like probe.
            const w = v.feedback.view orelse {
                out("probe FAIL no composer view", .{});
                schedule();
                return 0;
            };
            wk.webkit_web_view_evaluate_javascript(wk.asWebView(w), arg.ptr, @intCast(arg.len), null, null, null, &onProbed, null);
            return 0;
        } else if (std.mem.eql(u8, verb, "image")) {
            // An image pane's zoom state (T3416): `image rev= loads= route=
            // zoom= fitting= fit= natural=WxH viewport=WxH`.
            var buf: [512]u8 = undefined;
            out("image {s}", .{v.image.describe(&buf)});
        } else if (std.mem.eql(u8, verb, "diff")) {
            // A diff pane's state (T3417), `ViewerDiff.describe`.
            var buf: [2048]u8 = undefined;
            out("diff {s}", .{v.diff.describe(&buf)});
        } else if (std.mem.eql(u8, verb, "toc")) {
            // The contents card's state (T3418), `ViewerTOC.describe`.
            var buf: [1024]u8 = undefined;
            out("toc {s}", .{v.toc.describe(&buf)});
        } else if (std.mem.eql(u8, verb, "toc-rows")) {
            var buf: [3500]u8 = undefined;
            out("toc-rows {s}", .{v.toc.describeRows(&buf)});
        } else if (std.mem.eql(u8, verb, "toc-row")) {
            // Click the contents row for heading id `arg`.
            out("toc-row {s} found={}", .{ arg, v.toc.clickRowById(v, arg) });
        } else if (std.mem.eql(u8, verb, "toc-drag")) {
            // Drag the card's right edge `arg` px, as the gesture would:
            // begin, then end at that offset.
            const dx = std.fmt.parseFloat(f64, arg) catch 0;
            v.toc.beginDrag();
            v.toc.endDrag(v, dx);
            out("toc-drag {s}", .{arg});
        } else if (std.mem.eql(u8, verb, "resize")) {
            // Resize the pane's window to `WxH`, as dragging its edge would.
            var it = std.mem.splitScalar(u8, arg, 'x');
            const rw = std.fmt.parseInt(c_int, it.next() orelse "", 10) catch 0;
            const rh = std.fmt.parseInt(c_int, it.next() orelse "", 10) catch 0;
            const root = wk.gtk_widget_get_root(v.box);
            const ok = root != null and rw > 0 and rh > 0;
            if (ok) wk.gtk_window_set_default_size(root.?, rw, rh);
            out("resize {s} ok={}", .{ arg, ok });
        } else if (std.mem.eql(u8, verb, "rows")) {
            var buf: [3500]u8 = undefined;
            out("rows {s}", .{v.diff.describeRows(&buf)});
        } else if (std.mem.eql(u8, verb, "filter")) {
            // Replace the filter field's text, as typing would; its
            // `search-changed` narrows the tree.
            if (v.diff.filterWidget()) |fw| {
                var zbuf: [1024]u8 = undefined;
                const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{arg}) catch "";
                wk.gtk_editable_set_text(fw, z.ptr);
            }
            out("filter {s}", .{arg});
        } else if (std.mem.eql(u8, verb, "filter-submit")) {
            // Return in the filter: the entry's own `activate`.
            if (v.diff.filterWidget()) |fw| wk.g_signal_emit_by_name(fw, "activate");
            out("filter-submit", .{});
        } else if (std.mem.eql(u8, verb, "filter-focus")) {
            const ok = if (v.diff.filterWidget()) |fw| wk.gtk_widget_grab_focus(fw) != 0 else false;
            out("filter-focus ok={}", .{ok});
        } else if (std.mem.eql(u8, verb, "row")) {
            // Click the panel row whose id is `arg` (a file's path, a folder
            // key `<origin>:<path>`).
            out("row {s} found={}", .{ arg, v.diff.activateRowById(v, arg) });
        } else if (std.mem.eql(u8, verb, "terminate")) {
            out("terminate", .{});
            wk.webkit_web_view_terminate_web_process(v.view);
        } else if (std.mem.eql(u8, verb, "mods")) {
            // Stand in for the keyboard during the next link clicks (T3415):
            // WebKit reports no modifiers for a script-made click.
            mods_override = if (std.mem.eql(u8, arg, "ctrl"))
                links.Mods{ .ctrl = true }
            else if (std.mem.eql(u8, arg, "ctrl+shift"))
                links.Mods{ .ctrl = true, .shift = true }
            else
                null;
            out("mods {s}", .{arg});
        } else if (std.mem.eql(u8, verb, "menu-pick")) {
            // Choose a row of the last link menu (T3415), as a click on it
            // would: the menu itself cannot pop up on a seatless Weston.
            if (links.idFromActionName(arg)) |id| {
                v.pickLinkMenuRow(id);
                out("menu-pick {s}", .{arg});
            } else out("menu-pick {s} NO-SUCH-ROW", .{arg});
        } else if (std.mem.eql(u8, verb, "mark")) {
            // A sync point for the driving script (it edits a fixture, reads
            // +list, ...) while a following `sleep` holds the steps.
            out("mark {s}", .{arg});
        } else if (std.mem.eql(u8, verb, "probe")) {
            wk.webkit_web_view_evaluate_javascript(v.view, arg.ptr, @intCast(arg.len), null, null, null, &onProbed, null);
            return 0;
        } else if (std.mem.eql(u8, verb, "sleep")) {
            const ms = std.fmt.parseInt(c_uint, arg, 10) catch 100;
            _ = wk.g_timeout_add(ms, &afterSleep, null);
            return 0;
        } else {
            out("{s} UNKNOWN-STEP", .{verb});
        }
        schedule();
        return 0;
    }

    fn writeState(v: *Viewer) void {
        var start_i: c_int = 0;
        var end_i: c_int = 0;
        _ = wk.gtk_editable_get_selection_bounds(v.bar.address, &start_i, &end_i);
        const focus: []const u8 = if (v.addressHasFocus())
            "address"
        else if (v.findHasFocus())
            "find"
        else if (v.focusWidget()) |f|
            (if (f == wk.asWidget(v.view) or wk.gtk_widget_is_ancestor(f, wk.asWidget(v.view)) != 0) "content" else "other")
        else
            "none";
        var fs: c_int = 0;
        var fe: c_int = 0;
        _ = wk.gtk_editable_get_selection_bounds(v.find.entry, &fs, &fe);
        const count_text = std.mem.span(wk.gtk_label_get_text(v.find.count));
        const note_text = std.mem.span(wk.gtk_label_get_text(v.find.note));
        // barh stays LAST: viewer-nav.sh reads it as the line's tail.
        out("state mode={s} current={s} address={s} back={} forward={} reveal={} zoom={d:.3} focus={s} sel={d}-{d} reloads={d} card={s} find={s} findq={s} findsel={d}-{d} count={s} note={s} barh={d}", .{
            @tagName(v.mode),
            v.current,
            std.mem.span(wk.gtk_editable_get_text(v.bar.address)),
            wk.gtk_widget_get_sensitive(v.bar.back) != 0,
            wk.gtk_widget_get_sensitive(v.bar.forward) != 0,
            wk.gtk_widget_get_visible(v.bar.reveal) != 0,
            wk.webkit_web_view_get_zoom_level(v.view),
            focus,
            start_i,
            end_i,
            v.process_reloads,
            @tagName(v.crash_card),
            if (v.find_open) "open" else "closed",
            v.findQuery(),
            fs,
            fe,
            if (wk.gtk_widget_get_visible(v.find.count) != 0 and count_text.len > 0) count_text else "-",
            if (wk.gtk_widget_get_visible(v.find.note) != 0 and note_text.len > 0) note_text else "-",
            wk.gtk_widget_get_height(v.bar.row),
        });
    }

    fn onRendered(v: *Viewer, ok: bool) void {
        if (!waiting or viewer != v) return;
        waiting = false;
        out("wait ok={}", .{ok});
        schedule();
    }

    fn waitTimeout(data: ?*anyopaque) callconv(.c) c_int {
        const gen: u32 = @intCast(@intFromPtr(data) - 1);
        if (waiting and gen == wait_gen) {
            waiting = false;
            out("wait TIMEOUT", .{});
            schedule();
        }
        return 0;
    }

    fn afterSleep(_: ?*anyopaque) callconv(.c) c_int {
        schedule();
        return 0;
    }

    var feedback_polls: u32 = 0;
    var composer_polls: u32 = 0;

    fn composerPoll(_: ?*anyopaque) callconv(.c) c_int {
        const v = viewer orelse return 0;
        composer_polls += 1;
        const f = &v.feedback;
        const settling = f.sending or (f.open and !f.ready);
        if (settling and composer_polls < 200) return 1;
        var buf: [4096]u8 = undefined;
        out("composer {s}", .{f.describeComposer(&buf)});
        schedule();
        return 0;
    }

    /// Run `fmt` (one `{s}`) in the composer's page. With `json_arg` the
    /// argument goes in as a JS string literal, `\n` read as a newline.
    fn composerEval(v: *Viewer, comptime fmt: []const u8, arg: []const u8, json_arg: bool) bool {
        const w = v.feedback.view orelse return false;
        const a = std.heap.c_allocator;
        var owned: ?[]u8 = null;
        defer if (owned) |o| a.free(o);
        var text = arg;
        if (json_arg) {
            const unescaped = std.mem.replaceOwned(u8, a, arg, "\\n", "\n") catch return false;
            defer a.free(unescaped);
            owned = std.json.Stringify.valueAlloc(a, unescaped, .{}) catch return false;
            text = owned.?;
        }
        const js = std.fmt.allocPrint(a, fmt, .{text}) catch return false;
        defer a.free(js);
        wk.webkit_web_view_evaluate_javascript(wk.asWebView(w), js.ptr, @intCast(js.len), null, null, null, null, null);
        return true;
    }

    fn feedbackPoll(_: ?*anyopaque) callconv(.c) c_int {
        const v = viewer orelse return 0;
        feedback_polls += 1;
        if (v.feedback.pending and feedback_polls < 200) return 1;
        var buf: [2 * std.fs.max_path_bytes + 128]u8 = undefined;
        out("feedback {s}", .{v.feedback.describe(&buf)});
        schedule();
        return 0;
    }

    fn onProbed(source: ?*wk.GObject, result: *wk.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
        if (probeLine(source, result)) |line| {
            defer std.heap.c_allocator.free(line);
            out("probe {s}", .{line});
        } else out("probe FAIL", .{});
        schedule();
    }
} else struct {
    var viewer: ?*Viewer = null;
    var mods_override: ?links.Mods = null;
    fn start(_: *Viewer) void {}
    fn onRendered(_: *Viewer, _: bool) void {}
};
