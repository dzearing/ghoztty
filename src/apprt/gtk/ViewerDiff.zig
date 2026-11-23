//! A git diff viewer pane's GTK half (T3417, Linux L9h):
//! `--view=git-status:` / `--view=git-diff:<revspec>`
//! (docs/reference/viewer-image-and-diff.md, "Git diff panes").
//!
//! Almost nothing here decides anything. The spec, the argv, git's output and
//! the page calls are win32's pure `viewer_diff.zig`; the file tree, its
//! filter and the next-file walk are `viewer_file_tree.zig`; the worker that
//! runs git off the UI thread (with the deadline, the cancel and the
//! working-tree fingerprint) is win32's `ViewerDiffProbe.zig`, which runs on
//! POSIX since this task; and the renderer is the template's shared
//! `diff.js`. What lives here is the Linux translation of win32's
//! `ViewerPane` diff code and its `ViewerTOCPanel` file card:
//!
//! - **The changed-files panel** is a native GTK column at the pane's leading
//!   edge, in a `GtkPaned` so its edge drags (the width is the shared
//!   `viewer_prefs` width, the Mac's `ViewerTOCCardWidth`): a header counting
//!   the files, a filter field pinned under it, and the tree as a
//!   `GtkListBox` - sections (staged / unstaged / untracked), folders that
//!   fold, files with git's status letter and `+N -M`.
//! - **The filter** narrows on every keystroke; Return opens the top hit;
//!   Escape puts the whole list back and hands the caret to the diff.
//! - **The nav bar** gains previous / next change and the unified <->
//!   side-by-side toggle while a diff is showing. The layout is the persisted
//!   preference every diff pane shares.
//! - **Live**: a `git-status:` pane re-asks git every 2 s while it is mapped,
//!   and redraws only when the file list moved.
//!
//! Completions come back on a worker thread. They reach the UI loop through
//! `g_idle_add` and a ref-counted `Link`, which the pane cuts when it goes:
//! an idle that lands after the pane has closed finds nobody and does
//! nothing.
//!
//! The acceptance oracle is the log (`viewer diff ...`, `viewer tree ...`, the
//! lines win32's suite reads) and the steps runner's `diff` / `rows` steps.
const ViewerDiff = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Viewer = @import("Viewer.zig");
const wk = @import("webkit.zig");
const content = @import("../win32/viewer_content.zig");
const diff = @import("../win32/viewer_diff.zig");
const file_tree = @import("../win32/viewer_file_tree.zig");
const prefs = @import("../win32/viewer_prefs.zig");
const toc_layout = @import("../win32/viewer_toc_layout.zig");
const Probe = @import("../win32/ViewerDiffProbe.zig");
const panel_text = @import("viewer_diff_text.zig");

const log = std.log.scoped(.gtk_viewer);

/// How often a `git-status:` pane re-checks the working tree (Mac: 2 s).
pub const poll_ms: c_uint = 2000;

/// The pane's git worker. Created the first time the pane shows a diff.
probe: ?Probe = null,
/// The worker's way back to this pane (see `Link`).
link: ?*Link = null,
/// The directory the pane was opened from (`--working-directory`, else the
/// caller's cwd): which repository a spec applies to. Owned.
origin_dir: ?[]u8 = null,
/// The file whose patch the page shows (or was asked for). Owned.
file: ?[]u8 = null,
/// Where to enter the next patch that arrives for `pending_path`: `first` /
/// `last` when next/previous change rolled into it (the probe does not carry
/// it back with the patch).
pending_scroll: ?[]const u8 = null,
pending_path: ?[]u8 = null,
/// The layout this pane renders in; seeded from the preference once.
style: ?diff.Style = null,
/// A listing has been pushed to the current page.
pushed: bool = false,
/// The side panel's rows, rebuilt from every listing and every filter edit.
tree: ?file_tree.Tree = null,
/// Folder keys the reader clicked shut. Owned.
collapsed: std.ArrayList([]u8) = .empty,
/// The filter field's text, as last applied.
filter: std.ArrayList(u8) = .empty,
/// The working-tree poll's timer, 0 when none runs.
poll_id: c_uint = 0,
/// Counters the steps runner reports.
listings: u32 = 0,
patches: u32 = 0,
/// The widgets: the panel and the nav bar's three controls. Built by the
/// viewer at create time, so a pane that never shows a diff keeps them
/// hidden.
ui: ?Ui = null,
/// Re-entrancy guard: filling the list box selects a row, and that must not
/// read as the reader clicking it.
filling: bool = false,

pub const Ui = struct {
    /// The `GtkPaned` holding the panel and the page.
    paned: *wk.GtkWidget,
    panel: *wk.GtkWidget,
    header: *wk.GtkWidget,
    filter: *wk.GtkWidget,
    list: *wk.GtkWidget,
    prev: *wk.GtkWidget,
    next: *wk.GtkWidget,
    layout: *wk.GtkWidget,
};

/// What a worker completion needs to find its pane: the viewer pointer, which
/// only the UI thread reads or clears, behind a count every queued idle holds.
const Link = struct {
    refs: std.atomic.Value(u32) = .init(1),
    viewer: ?*Viewer,

    fn ref(self: *Link) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn unref(self: *Link) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.c_allocator.destroy(self);
    }
};

// -------------------------------------------------------------------------
// Widgets
// -------------------------------------------------------------------------

/// Build the panel around `page` (the overlay holding the web view) and the
/// bar's diff controls, appended to `bar_row`. Returns the paned, which takes
/// the page's place in the viewer's box.
pub fn buildUi(self: *ViewerDiff, v: *Viewer, page: *wk.GtkWidget, bar_row: *wk.GtkWidget) *wk.GtkWidget {
    const paned = wk.gtk_paned_new(wk.orientation_horizontal);
    wk.gtk_widget_set_hexpand(paned, 1);
    wk.gtk_widget_set_vexpand(paned, 1);

    const panel = wk.gtk_box_new(wk.orientation_vertical, 4);
    wk.gtk_widget_add_css_class(panel, "viewer-diff-panel");
    wk.gtk_widget_set_size_request(panel, @intFromFloat(toc_layout.card_min_dip), -1);
    const header = wk.gtk_label_new("");
    wk.gtk_label_set_xalign(header, 0);
    wk.gtk_label_set_ellipsize(header, wk.ellipsize_middle);
    wk.gtk_widget_add_css_class(header, "heading");
    wk.gtk_widget_set_margin_start(header, 10);
    wk.gtk_widget_set_margin_end(header, 10);
    wk.gtk_widget_set_margin_top(header, 8);
    const filter = wk.gtk_search_entry_new();
    wk.gtk_search_entry_set_placeholder_text(filter, "Filter files");
    // Every keystroke applies (Mac's `setDiffFilter`): the tree is rebuilt
    // from a listing already in memory, so there is nothing to debounce.
    wk.gtk_search_entry_set_search_delay(filter, 0);
    wk.gtk_widget_set_margin_start(filter, 6);
    wk.gtk_widget_set_margin_end(filter, 6);
    const list = wk.gtk_list_box_new();
    wk.gtk_widget_add_css_class(list, "navigation-sidebar");
    const scroller = wk.gtk_scrolled_window_new();
    wk.gtk_scrolled_window_set_policy(scroller, wk.policy_never, wk.policy_automatic);
    wk.gtk_scrolled_window_set_child(scroller, list);
    wk.gtk_widget_set_vexpand(scroller, 1);
    wk.gtk_box_append(panel, header);
    wk.gtk_box_append(panel, filter);
    wk.gtk_box_append(panel, scroller);
    wk.gtk_widget_set_visible(panel, 0);

    wk.gtk_paned_set_start_child(paned, panel);
    wk.gtk_paned_set_end_child(paned, page);
    wk.gtk_paned_set_resize_start_child(paned, 0);
    wk.gtk_paned_set_shrink_start_child(paned, 0);
    wk.gtk_paned_set_shrink_end_child(paned, 0);
    wk.gtk_paned_set_position(paned, @intFromFloat(prefs.loadWidth(std.heap.c_allocator)));

    const prev = barButton("go-up-symbolic", "Previous Change");
    const next = barButton("go-down-symbolic", "Next Change");
    const layout = barButton("view-dual-symbolic", "Side by Side");
    inline for (.{ prev, next, layout }) |b| {
        wk.gtk_widget_set_visible(b, 0);
        wk.gtk_box_append(bar_row, b);
    }

    self.ui = .{
        .paned = paned,
        .panel = panel,
        .header = header,
        .filter = filter,
        .list = list,
        .prev = prev,
        .next = next,
        .layout = layout,
    };
    _ = wk.g_signal_connect_data(filter, "search-changed", @ptrCast(&onFilterChanged), v, null, 0);
    _ = wk.g_signal_connect_data(filter, "activate", @ptrCast(&onFilterActivate), v, null, 0);
    _ = wk.g_signal_connect_data(filter, "stop-search", @ptrCast(&onFilterStop), v, null, 0);
    _ = wk.g_signal_connect_data(list, "row-activated", @ptrCast(&onRowActivated), v, null, 0);
    _ = wk.g_signal_connect_data(prev, "clicked", @ptrCast(&onPrevClicked), v, null, 0);
    _ = wk.g_signal_connect_data(next, "clicked", @ptrCast(&onNextClicked), v, null, 0);
    _ = wk.g_signal_connect_data(layout, "clicked", @ptrCast(&onLayoutClicked), v, null, 0);
    return paned;
}

fn barButton(icon: [*:0]const u8, tip: [*:0]const u8) *wk.GtkWidget {
    const b = wk.gtk_button_new_from_icon_name(icon);
    wk.gtk_widget_set_tooltip_text(b, tip);
    wk.gtk_widget_add_css_class(b, "flat");
    wk.gtk_widget_set_focus_on_click(b, 0);
    return b;
}

// -------------------------------------------------------------------------
// Lifetime
// -------------------------------------------------------------------------

/// Which repository the pane's specs apply to (the pane's
/// `--working-directory`). Set before the first listing is asked for.
pub fn setOriginDirectory(self: *ViewerDiff, dir: ?[]const u8) void {
    const alloc = std.heap.c_allocator;
    if (self.origin_dir) |d| alloc.free(d);
    self.origin_dir = null;
    const d = dir orelse return;
    if (d.len == 0) return;
    self.origin_dir = alloc.dupe(u8, d) catch null;
}

pub fn deinit(self: *ViewerDiff) void {
    const alloc = std.heap.c_allocator;
    self.stopPoll();
    // Joins the worker (cancelling the git in flight first) - after this no
    // completion can be queued, and the link cut below answers any already
    // queued with "nobody".
    if (self.probe) |*p| p.deinit();
    self.probe = null;
    if (self.link) |l| {
        l.viewer = null;
        l.unref();
    }
    self.link = null;
    if (self.ui) |ui| saveWidth(ui);
    self.clearTree();
    self.collapsed.deinit(alloc);
    self.filter.deinit(alloc);
    if (self.origin_dir) |d| alloc.free(d);
    if (self.file) |f| alloc.free(f);
    if (self.pending_path) |p| alloc.free(p);
}

fn saveWidth(ui: Ui) void {
    if (wk.gtk_widget_get_visible(ui.panel) == 0) return;
    const pos: f32 = @floatFromInt(wk.gtk_paned_get_position(ui.paned));
    const alloc = std.heap.c_allocator;
    if (@abs(pos - prefs.loadWidth(alloc)) < 1) return;
    prefs.saveWidth(alloc, pos);
}

/// Mirror the pane's mode onto the diff chrome: the panel and the bar's
/// controls show only while a diff is on screen, and the poll runs only for
/// a working tree. Leaving a diff drops its tree and its filter.
pub fn syncMode(self: *ViewerDiff, v: *Viewer) void {
    const ui = self.ui orelse return;
    const on = v.mode == .diff;
    if (!on and wk.gtk_widget_get_visible(ui.panel) != 0) saveWidth(ui);
    wk.gtk_widget_set_visible(ui.panel, @intFromBool(on));
    inline for (.{ ui.prev, ui.next, ui.layout }) |b| wk.gtk_widget_set_visible(b, @intFromBool(on));
    self.syncLayoutButton();
    if (!on) {
        self.stopPoll();
        if (self.tree != null or self.filter.items.len > 0) {
            self.clearTree();
            self.filter.clearRetainingCapacity();
            wk.gtk_editable_set_text(ui.filter, "");
            self.fillList();
        }
        self.pushed = false;
        return;
    }
    self.syncPoll(v);
}

/// The template for a diff finished loading: ask git for the file list. The
/// page's calls follow from the completion.
pub fn start(self: *ViewerDiff, v: *Viewer) void {
    const probe = self.ensureProbe(v) orelse return v.showError("Cannot run git", "out of memory");
    self.pushed = false;
    probe.requestListing(v.current, self.origin_dir);
    self.syncPoll(v);
}

fn ensureProbe(self: *ViewerDiff, v: *Viewer) ?*Probe {
    if (self.probe) |*p| return p;
    const link = std.heap.c_allocator.create(Link) catch return null;
    link.* = .{ .viewer = v };
    self.link = link;
    self.probe = Probe.init(std.heap.c_allocator);
    self.probe.?.attachNotify(.{ .ctx = link, .func = &onWorkerDone });
    return &self.probe.?;
}

/// ON THE WORKER THREAD: hand the completion to the UI loop.
fn onWorkerDone(ctx: *anyopaque) void {
    const link: *Link = @ptrCast(@alignCast(ctx));
    link.ref();
    _ = wk.g_idle_add(&onIdleComplete, link);
}

fn onIdleComplete(data: ?*anyopaque) callconv(.c) c_int {
    const link: *Link = @ptrCast(@alignCast(data orelse return 0));
    defer link.unref();
    const v = link.viewer orelse return 0;
    v.diff.completed(v);
    return 0;
}

// -------------------------------------------------------------------------
// The working-tree poll
// -------------------------------------------------------------------------

fn syncPoll(self: *ViewerDiff, v: *Viewer) void {
    const spec = diff.parse(v.current) orelse return self.stopPoll();
    if (v.mode != .diff or !spec.tracksWorkingTree()) return self.stopPoll();
    if (self.poll_id != 0) return;
    self.poll_id = wk.g_timeout_add(poll_ms, &onPollTick, v);
}

fn stopPoll(self: *ViewerDiff) void {
    if (self.poll_id == 0) return;
    _ = wk.g_source_remove(self.poll_id);
    self.poll_id = 0;
}

fn onPollTick(data: ?*anyopaque) callconv(.c) c_int {
    const v: *Viewer = @ptrCast(@alignCast(data orelse return 0));
    const self = &v.diff;
    if (v.mode != .diff) {
        self.poll_id = 0;
        return 0;
    }
    // Nobody can see it (stashed, in a hidden tab, minimized): skip the turn
    // rather than spawn git for nothing (Mac's `isOnShow`). A tick that lands
    // while git is still out is dropped by the probe itself.
    if (wk.gtk_widget_get_mapped(v.box) == 0 or !v.page_live) return 1;
    const probe = if (self.probe) |*p| p else return 1;
    probe.pollListing(v.current, self.origin_dir);
    return 1;
}

// -------------------------------------------------------------------------
// Completions
// -------------------------------------------------------------------------

/// The worker landed (UI thread). The ONLY place its answer is read.
fn completed(self: *ViewerDiff, v: *Viewer) void {
    const probe = if (self.probe) |*p| p else return;
    const alloc = std.heap.c_allocator;
    const before = probe.snapshot(alloc);
    defer Probe.freeSnapshot(alloc, before);

    switch (probe.complete()) {
        .none => return,
        .listing => if (v.mode == .diff and (probe.listingDiffers(before) or !self.pushed)) {
            self.pushed = true;
            self.applyListing(v);
        },
        .patch => if (v.mode == .diff) self.applyPatch(v),
        .unchanged => log.debug("viewer diff poll unchanged={d} git={d}", .{ probe.unchanged_polls, probe.git_processes }),
    }
    probe.drainDeferred(v.current, self.origin_dir);
}

fn diffStyle(self: *ViewerDiff) diff.Style {
    if (self.style) |s| return s;
    const s = prefs.loadDiffStyle(std.heap.c_allocator);
    self.style = s;
    return s;
}

/// A listing arrived: push the header, open a file, rebuild the panel.
fn applyListing(self: *ViewerDiff, v: *Viewer) void {
    const probe = if (self.probe) |*p| p else return;
    const spec = diff.parse(v.current) orelse return;
    const resolved = probe.resolvedSpec(v.current) orelse spec;
    const alloc = std.heap.c_allocator;
    self.listings += 1;

    var additions: u64 = 0;
    var deletions: u64 = 0;
    for (probe.files.items) |f| {
        additions += f.additions;
        deletions += f.deletions;
    }
    const files = probe.files.items.len;

    var subtitle_buf: [512]u8 = undefined;
    var message_buf: [512]u8 = undefined;
    var detail_buf: [1024]u8 = undefined;
    var listing: diff.Listing = .{
        .title = resolved.title(),
        .subtitle = diff.subtitle(&subtitle_buf, resolved, probe.repo),
        .file_count = files,
        .additions = additions,
        .deletions = deletions,
        .style = self.diffStyle(),
    };
    if (probe.failure) |*f| {
        const view = f.view();
        listing.message = view.title();
        listing.detail = view.detail(&detail_buf);
    } else if (files == 0) {
        listing.message = diff.emptyMessage(&message_buf, resolved);
    }

    // `style=` before `status=`: the status has spaces in it and a reader
    // takes the rest of the line (win32's T463 line, field for field).
    log.info("viewer diff spec={s} repo={s} files={d} +{d} -{d} style={s} status={s}", .{
        v.current,
        probe.repo orelse "<none>",
        files,
        additions,
        deletions,
        listing.style.wire(),
        listing.message orelse "ok",
    });

    const js = diff.setDiffListingCall(alloc, listing) catch return;
    defer alloc.free(js);
    v.evaluateRender(js);

    if (files == 0) {
        if (self.file) |f| alloc.free(f);
        self.file = null;
        self.rebuildTree();
        return;
    }
    self.openFile(v, self.reselect(), null);
    self.rebuildTree();
}

/// The same file after a refresh when it is still in the diff (a poll must
/// not yank the reader elsewhere), else the first.
fn reselect(self: *const ViewerDiff) usize {
    const probe = if (self.probe) |*p| p else return 0;
    const want = self.file orelse return 0;
    for (probe.files.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.path, want)) return i;
    }
    return 0;
}

/// Ask for one file's patch, remembering which file that is.
fn openFile(self: *ViewerDiff, v: *Viewer, index: usize, scroll_to: ?[]const u8) void {
    const probe = if (self.probe) |*p| p else return;
    if (index >= probe.files.items.len) return;
    const alloc = std.heap.c_allocator;
    const entry = probe.files.items[index];
    if (self.file) |f| alloc.free(f);
    self.file = alloc.dupe(u8, entry.path) catch null;
    if (self.pending_path) |p| alloc.free(p);
    self.pending_path = alloc.dupe(u8, entry.path) catch null;
    self.pending_scroll = scroll_to;
    self.syncSelection();
    // A binary file never gets a patch: say so at once.
    if (entry.binary) return self.pushFile(v, entry, null, scroll_to);
    probe.requestPatch(v.current, index, scroll_to);
}

fn applyPatch(self: *ViewerDiff, v: *Viewer) void {
    const probe = if (self.probe) |*p| p else return;
    const path = probe.patch_path orelse return;
    defer probe.releasePatchBytes();
    // The scroll the request carried, for the file it was asked for.
    var scroll: ?[]const u8 = null;
    if (self.pending_path) |p| if (std.mem.eql(u8, p, path)) {
        scroll = self.pending_scroll;
    };
    for (probe.files.items) |entry| {
        if (!std.mem.eql(u8, entry.path, path)) continue;
        self.pushFile(v, entry, probe.patch, scroll);
        return;
    }
}

fn pushFile(self: *ViewerDiff, v: *Viewer, entry: Probe.Entry, patch: ?[]const u8, scroll_to: ?[]const u8) void {
    const alloc = std.heap.c_allocator;
    self.patches += 1;
    log.info("viewer diff file={s} status={s} patch={d} scroll={s}", .{
        entry.path,
        entry.status.letter(),
        (patch orelse "").len,
        scroll_to orelse "-",
    });
    // WebKit takes the script as UTF-8; a Latin-1 file's patch is not, so its
    // stray bytes become U+FFFD rather than a script that fails to parse.
    const raw = patch orelse "";
    const body: []const u8 = if (std.unicode.utf8ValidateSlice(raw)) raw else sanitized: {
        break :sanitized panel_text.sanitizeUtf8(alloc, raw) catch return;
    };
    defer if (body.ptr != raw.ptr) alloc.free(body);
    const js = diff.setDiffFileCall(alloc, .{
        .path = entry.path,
        .old_path = entry.old_path,
        .status = entry.status,
        .origin = entry.origin,
        .additions = entry.additions,
        .deletions = entry.deletions,
        .binary = entry.binary,
        .language = content.highlightLanguage(content.extension(entry.path)) orelse "",
        .patch = body,
        .scroll_to = scroll_to,
    }) catch return;
    defer alloc.free(js);
    v.evaluateRender(js);
}

// -------------------------------------------------------------------------
// The nav bar's controls
// -------------------------------------------------------------------------

fn syncLayoutButton(self: *ViewerDiff) void {
    const ui = self.ui orelse return;
    // The button names what a press switches TO.
    const split = (self.style orelse diff.Style.unified) == .split;
    wk.gtk_button_set_icon_name(ui.layout, if (split) "view-continuous-symbolic" else "view-dual-symbolic");
    wk.gtk_widget_set_tooltip_text(ui.layout, if (split) "Unified" else "Side by Side");
}

/// Flip between unified and side by side, remember it for every diff pane,
/// and tell the page.
pub fn toggleStyle(self: *ViewerDiff, v: *Viewer) void {
    if (v.mode != .diff) return;
    const alloc = std.heap.c_allocator;
    const next = self.diffStyle().next();
    self.style = next;
    prefs.saveDiffStyle(alloc, next);
    log.info("viewer diff style={s}", .{next.wire()});
    self.syncLayoutButton();
    if (!v.page_live) return;
    const js = diff.setDiffStyleCall(alloc, next) catch return;
    defer alloc.free(js);
    v.runQuiet(js);
}

/// Next / previous change. In the open file it is a page-side hunk jump; past
/// the last one the page answers `diffNavOverflow` (`navOverflow`).
pub fn nav(self: *ViewerDiff, v: *Viewer, forward: bool) void {
    if (v.mode != .diff) return;
    if (self.file == null) return self.openFile(v, 0, if (forward) "first" else "last");
    if (!v.page_live) return;
    const alloc = std.heap.c_allocator;
    const js = diff.diffNavCall(alloc, forward) catch return;
    defer alloc.free(js);
    v.runQuiet(js);
}

/// The page ran out of changes going `forward`: open the adjacent file the
/// panel shows, entered at the end the reader arrives from. Off the end of
/// the diff is a no-op, not a wrap.
pub fn navOverflow(self: *ViewerDiff, v: *Viewer, forward: bool) void {
    if (v.mode != .diff) return;
    const probe = if (self.probe) |*p| p else return;
    const current = self.file orelse return;
    const scroll_to: []const u8 = if (forward) "first" else "last";
    log.info("viewer diff overflow forward={}", .{forward});
    if (self.tree) |tree| {
        const at = file_tree.adjacentFile(tree.rows, current, forward) orelse return;
        return self.openFile(v, at, scroll_to);
    }
    for (probe.files.items, 0..) |f, i| {
        if (!std.mem.eql(u8, f.path, current)) continue;
        if (forward and i + 1 < probe.files.items.len) self.openFile(v, i + 1, scroll_to);
        if (!forward and i > 0) self.openFile(v, i - 1, scroll_to);
        return;
    }
}

fn onPrevClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    v.diff.nav(v, false);
}

fn onNextClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    v.diff.nav(v, true);
}

fn onLayoutClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    v.diff.toggleStyle(v);
}

// -------------------------------------------------------------------------
// The changed-files panel
// -------------------------------------------------------------------------

fn clearTree(self: *ViewerDiff) void {
    const alloc = std.heap.c_allocator;
    if (self.tree) |*t| t.deinit();
    self.tree = null;
    for (self.collapsed.items) |k| alloc.free(k);
    self.collapsed.clearRetainingCapacity();
}

/// Rebuild the rows from the probe's listing, the shut folders and the
/// filter, and refill the list. The collapsed set survives: a poll that adds
/// a file must not re-open every folder the reader shut.
fn rebuildTree(self: *ViewerDiff) void {
    const probe = if (self.probe) |*p| p else return;
    const alloc = std.heap.c_allocator;
    if (self.tree) |*t| t.deinit();
    self.tree = null;

    const views = alloc.alloc(diff.File, probe.files.items.len) catch return;
    defer alloc.free(views);
    for (probe.files.items, 0..) |*e, i| views[i] = e.view();
    const keys = alloc.alloc([]const u8, self.collapsed.items.len) catch return;
    defer alloc.free(keys);
    for (self.collapsed.items, 0..) |k, i| keys[i] = k;
    self.tree = file_tree.buildFiltered(alloc, views, keys, self.filter.items) catch null;
    self.fillList();

    var files: usize = 0;
    var folders: usize = 0;
    var sections: usize = 0;
    var rows: usize = 0;
    var filtered = false;
    if (self.tree) |*t| {
        rows = t.rows.len;
        filtered = t.filtered;
        for (t.rows) |r| switch (r.kind) {
            .folder => folders += 1,
            .section => sections += 1,
            .file => files += 1,
        };
    }
    log.info("viewer tree rows={d} files={d} folders={d} sections={d} shut={d} selected={s} filtered={d} total={d}", .{
        rows,
        files,
        folders,
        sections,
        self.collapsed.items.len,
        self.file orelse "-",
        @intFromBool(filtered),
        probe.files.items.len,
    });
}

/// Put the tree's rows in the list box and the counts in the header.
fn fillList(self: *ViewerDiff) void {
    const ui = self.ui orelse return;
    self.filling = true;
    defer self.filling = false;
    wk.gtk_list_box_remove_all(ui.list);
    var header_buf: [128]u8 = undefined;
    const tree = if (self.tree) |*t| t else {
        wk.gtk_label_set_text(ui.header, "");
        return;
    };
    for (tree.rows) |row| {
        wk.gtk_list_box_append(ui.list, rowWidget(row));
    }
    // Sections are headings, not things to open.
    for (tree.rows, 0..) |row, i| {
        if (row.kind != .section) continue;
        const r = wk.gtk_list_box_get_row_at_index(ui.list, @intCast(i)) orelse continue;
        wk.gtk_list_box_row_set_activatable(r, 0);
        wk.gtk_list_box_row_set_selectable(r, 0);
    }
    wk.gtk_label_set_text(ui.header, panel_text.header(&header_buf, tree.fileRows(), tree.total_files, tree.filtered).ptr);
    self.syncSelection();
}

fn rowWidget(row: file_tree.Row) *wk.GtkWidget {
    var buf: [1024]u8 = undefined;
    const box = wk.gtk_box_new(wk.orientation_horizontal, 6);
    wk.gtk_widget_set_margin_start(box, 4 + @as(c_int, row.depth) * 12);
    switch (row.kind) {
        .section => {
            const l = label(&buf, "{s}", .{row.title});
            wk.gtk_widget_add_css_class(l, "heading");
            wk.gtk_box_append(box, l);
        },
        .folder => {
            wk.gtk_box_append(box, label(&buf, "{s}", .{if (row.collapsed) "\u{25b8}" else "\u{25be}"}));
            const t = label(&buf, "{s}", .{row.title});
            wk.gtk_widget_set_hexpand(t, 1);
            wk.gtk_box_append(box, t);
        },
        .file => {
            const s = label(&buf, "{s}", .{row.status.letter()});
            wk.gtk_widget_add_css_class(s, "monospace");
            wk.gtk_widget_add_css_class(s, panel_text.statusClass(row.status).ptr);
            wk.gtk_box_append(box, s);
            const names = wk.gtk_box_new(wk.orientation_vertical, 0);
            wk.gtk_widget_set_hexpand(names, 1);
            wk.gtk_box_append(names, label(&buf, "{s}", .{row.title}));
            // A filtered (flat) list names the folder, or two same-named
            // hits would be indistinguishable.
            if (row.detail.len > 0) {
                const d = label(&buf, "{s}", .{row.detail});
                wk.gtk_widget_add_css_class(d, "dim-label");
                wk.gtk_widget_add_css_class(d, "caption");
                wk.gtk_box_append(names, d);
            }
            wk.gtk_box_append(box, names);
            var counts_buf: [32]u8 = undefined;
            const counts = label(&buf, "{s}", .{panel_text.counts(&counts_buf, row.additions, row.deletions, row.binary)});
            wk.gtk_widget_add_css_class(counts, "dim-label");
            wk.gtk_widget_add_css_class(counts, "caption");
            wk.gtk_widget_set_margin_end(counts, 4);
            wk.gtk_box_append(box, counts);
        },
    }
    return box;
}

fn label(buf: []u8, comptime fmt: []const u8, args: anytype) *wk.GtkWidget {
    const z = std.fmt.bufPrintZ(buf, fmt, args) catch "";
    const l = wk.gtk_label_new(z.ptr);
    wk.gtk_label_set_xalign(l, 0);
    wk.gtk_label_set_ellipsize(l, wk.ellipsize_middle);
    return l;
}

/// Select the open file's row (the macOS selection pill), without it reading
/// as a click.
fn syncSelection(self: *ViewerDiff) void {
    const ui = self.ui orelse return;
    const tree = if (self.tree) |*t| t else return;
    const was = self.filling;
    self.filling = true;
    defer self.filling = was;
    const want = self.file orelse return wk.gtk_list_box_select_row(ui.list, null);
    for (tree.rows, 0..) |row, i| {
        if (row.kind != .file or !std.mem.eql(u8, row.id, want)) continue;
        wk.gtk_list_box_select_row(ui.list, wk.gtk_list_box_get_row_at_index(ui.list, @intCast(i)));
        return;
    }
    wk.gtk_list_box_select_row(ui.list, null);
}

fn onRowActivated(_: *wk.GtkWidget, row: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    if (v.diff.filling) return;
    const i = wk.gtk_list_box_row_get_index(row);
    if (i < 0) return;
    v.diff.activateRow(v, @intCast(i));
}

/// A row was clicked: a file opens, a folder folds or unfolds.
pub fn activateRow(self: *ViewerDiff, v: *Viewer, index: usize) void {
    const tree = if (self.tree) |*t| t else return;
    if (index >= tree.rows.len) return;
    const row = tree.rows[index];
    switch (row.kind) {
        .section => {},
        .file => self.openPath(v, row.id),
        .folder => {
            // Copied: the rebuild frees the row.
            var key_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (row.id.len > key_buf.len) return;
            @memcpy(key_buf[0..row.id.len], row.id);
            self.toggleFolder(key_buf[0..row.id.len]);
        },
    }
}

/// Activate the row whose id is `id` (the steps runner's `row`).
pub fn activateRowById(self: *ViewerDiff, v: *Viewer, id: []const u8) bool {
    const tree = if (self.tree) |*t| t else return false;
    for (tree.rows, 0..) |row, i| {
        if (std.mem.eql(u8, row.id, id)) {
            self.activateRow(v, i);
            return true;
        }
    }
    return false;
}

fn openPath(self: *ViewerDiff, v: *Viewer, path: []const u8) void {
    const probe = if (self.probe) |*p| p else return;
    for (probe.files.items, 0..) |f, i| {
        if (!std.mem.eql(u8, f.path, path)) continue;
        log.info("viewer tree open={s}", .{f.path});
        self.openFile(v, i, null);
        return;
    }
}

fn toggleFolder(self: *ViewerDiff, key: []const u8) void {
    const alloc = std.heap.c_allocator;
    for (self.collapsed.items, 0..) |k, i| {
        if (std.mem.eql(u8, k, key)) {
            alloc.free(self.collapsed.orderedRemove(i));
            log.info("viewer tree folder={s}", .{key});
            return self.rebuildTree();
        }
    }
    const owned = alloc.dupe(u8, key) catch return;
    self.collapsed.append(alloc, owned) catch return alloc.free(owned);
    log.info("viewer tree folder={s}", .{key});
    self.rebuildTree();
}

// --- the filter ------------------------------------------------------------

pub fn filterHasFocus(self: *const ViewerDiff, v: *const Viewer) bool {
    const ui = self.ui orelse return false;
    const f = v.focusWidget() orelse return false;
    return f == ui.filter or wk.gtk_widget_is_ancestor(f, ui.filter) != 0;
}

/// The field's text moved: narrow the tree.
pub fn setFilter(self: *ViewerDiff, text: []const u8) void {
    if (std.mem.eql(u8, self.filter.items, text)) return;
    const alloc = std.heap.c_allocator;
    self.filter.clearRetainingCapacity();
    self.filter.appendSlice(alloc, text) catch self.filter.clearRetainingCapacity();
    // Its own line, ahead of the tree line it causes: the text may hold
    // spaces, so it is LAST.
    log.info("viewer tree filter={s}", .{self.filter.items});
    if (self.probe == null) return;
    self.rebuildTree();
}

/// Return in the field: open the top hit ("type a few letters and go").
pub fn submitFilter(self: *ViewerDiff, v: *Viewer) void {
    const tree = if (self.tree) |*t| t else return;
    const index = file_tree.firstFile(tree.rows) orelse {
        log.info("viewer tree submit=-", .{});
        return;
    };
    const probe = if (self.probe) |*p| p else return;
    if (index >= probe.files.items.len) return;
    log.info("viewer tree submit={s}", .{probe.files.items[index].path});
    self.openFile(v, index, null);
}

/// Escape in the field: the whole list back, the caret to the diff.
pub fn clearFilter(self: *ViewerDiff, v: *Viewer) void {
    if (self.ui) |ui| wk.gtk_editable_set_text(ui.filter, "");
    self.setFilter("");
    v.focusContent();
}

fn onFilterChanged(entry: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    v.diff.setFilter(std.mem.span(wk.gtk_editable_get_text(entry)));
}

fn onFilterActivate(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    v.diff.submitFilter(v);
}

fn onFilterStop(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    v.diff.clearFilter(v);
}

// -------------------------------------------------------------------------
// The steps runner's view
// -------------------------------------------------------------------------

/// `diff files= file= style= filter= rows= selected= panel= listings=
/// patches= unchanged= git= width= busy=`.
pub fn describe(self: *const ViewerDiff, buf: []u8) []const u8 {
    const files = if (self.probe) |*p| p.files.items.len else 0;
    const unchanged = if (self.probe) |*p| p.unchanged_polls else 0;
    const git = if (self.probe) |*p| p.git_processes else 0;
    const busy = if (self.probe) |*p| p.busy() else false;
    const rows = if (self.tree) |*t| t.rows.len else 0;
    var selected: []const u8 = "-";
    var panel = false;
    var width: c_int = 0;
    var header: []const u8 = "";
    if (self.ui) |ui| {
        panel = wk.gtk_widget_get_visible(ui.panel) != 0;
        width = wk.gtk_paned_get_position(ui.paned);
        header = std.mem.span(wk.gtk_label_get_text(ui.header));
        if (wk.gtk_list_box_get_selected_row(ui.list)) |r| {
            const i = wk.gtk_list_box_row_get_index(r);
            if (self.tree) |*t| if (i >= 0 and @as(usize, @intCast(i)) < t.rows.len) {
                selected = t.rows[@intCast(i)].id;
            };
        }
    }
    return std.fmt.bufPrint(buf, "files={d} file={s} style={s} rows={d} selected={s} panel={} listings={d} patches={d} unchanged={d} git={d} width={d} busy={} header={s} filter={s}", .{
        files,
        self.file orelse "-",
        (self.style orelse diff.Style.unified).wire(),
        rows,
        selected,
        panel,
        self.listings,
        self.patches,
        unchanged,
        git,
        width,
        busy,
        header,
        self.filter.items,
    }) catch "";
}

/// `rows <kind>:<title>[*]|...`, `*` marking a shut folder.
pub fn describeRows(self: *const ViewerDiff, buf: []u8) []const u8 {
    const tree = if (self.tree) |*t| t else return "";
    var len: usize = 0;
    for (tree.rows) |row| {
        const s = std.fmt.bufPrint(buf[len..], "{s}{s}:{s}{s}", .{
            if (len == 0) "" else "|",
            @tagName(row.kind),
            row.title,
            if (row.kind == .folder and row.collapsed) "*" else "",
        }) catch break;
        len += s.len;
    }
    return buf[0..len];
}

pub fn filterWidget(self: *const ViewerDiff) ?*wk.GtkWidget {
    const ui = self.ui orelse return null;
    return ui.filter;
}
