//! The GTK viewer's feedback button (T3419, Linux L9j; Mac
//! `ViewerSplitLeaf` + `ViewerView.refreshWorktree`, win32 T633/T638).
//!
//! A viewer pane whose content belongs to a git worktree gets an icon-only
//! button at the trailing end of its nav bar, tooltip `Send feedback to
//! <root>`. With nowhere to file a report the button would be a lie, so it is
//! hidden whenever there is no worktree - and that is re-decided on EVERY
//! navigation, because a pane walks between a repo file, a dev server and a
//! remote site, each a different worktree or none.
//!
//! Which worktree is `viewer_worktree.zig`'s strategy D (file directory, else
//! the loopback listener's cwd, else the pane's `--working-directory`), then
//! `git rev-parse --show-toplevel`. Everything past the string work runs on a
//! worker thread - a /proc walk and a git launch must not stall the terminal
//! beside the pane - and lands back on the UI loop through `g_idle_add` and a
//! ref-counted `Link` the pane cuts when it closes (ViewerDiff's shape). A
//! resolution is tagged with a generation, so a slow answer for a location the
//! pane has already left is dropped instead of flashing the wrong button.
//! Answers are cached per (location, origin) for 15 s - negative ones too -
//! so a back/forward walk never re-launches git, while a dev server started
//! later still makes the button appear.
//!
//! The button opens the composer (T3544, the second half of this file): a
//! pill under the nav bar hosting the shared `composer.js` in a second web
//! view, Enter for a newline, Ctrl+Enter to send, Escape to close, and the
//! report filed into `<worktree>/temp/feedback/new/<stem>/report.json` by
//! win32's pure `viewer_feedback_report.zig` (staging + one atomic rename).
const ViewerFeedback = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const Viewer = @import("Viewer.zig");
const wk = @import("webkit.zig");
const rules = @import("viewer_worktree.zig");
const host = @import("viewer_feedback_host.zig");
const content = @import("../win32/viewer_content.zig");
const page = @import("../win32/viewer_feedback_page.zig");
const report = @import("../win32/viewer_feedback_report.zig");
const git_run = @import("../win32/git_run.zig");

const log = std.log.scoped(.gtk_viewer);

const alloc = std.heap.c_allocator;

/// The button's icon: Adwaita's speech bubble (actions/), the nearest the
/// freedesktop set has to the Mac's `exclamationmark.bubble`.
pub const icon_name = "chat-message-new-symbolic";

button: ?*wk.GtkWidget = null,
/// The pane's `--working-directory`: leg 3's answer.
origin_dir: ?[]u8 = null,
/// The worktree root the button currently names; null = hidden.
root: ?[:0]u8 = null,
/// `Send feedback to <root>`, as set on the button.
tooltip: ?[:0]u8 = null,
cache: rules.Cache = .{ .alloc = std.heap.c_allocator },
link: ?*Link = null,
/// Bumped by every `refresh`; a completion for an older one is stale.
gen: u32 = 0,
/// The cache key hash of the resolution in flight.
inflight_hash: u64 = 0,
/// A resolution is in flight for the current generation.
pending: bool = false,
/// How many resolutions actually ran on a worker (cache misses); the tests
/// read it to prove a back/forward walk is served from the cache.
resolves: u32 = 0,
/// How many clicks the button has had.
clicks: u32 = 0,

// The composer (T3544). The band and its widgets are built once and hidden;
// the web view exists only while the composer is open.
band: ?*wk.GtkWidget = null,
slot: ?*wk.GtkWidget = null,
send_button: ?*wk.GtkWidget = null,
status: ?*wk.GtkWidget = null,
status_text: ?[:0]u8 = null,
view: ?*wk.GtkWidget = null,
ucm: ?*wk.UserContentManager = null,
message_handler: c_ulong = 0,
open: bool = false,
/// The page has loaded and said `ready`; before that nothing goes down.
ready: bool = false,
/// The report text. It lives on the pane, so closing and reopening the
/// composer keeps it.
text: std.ArrayListUnmanaged(u8) = .empty,
/// The caret, in the page's UTF-16 units; -1 = at the end.
caret: i64 = -1,
/// The last seed's generation; a snapshot from before it is dropped.
seed_gen: u32 = 0,
/// Wrapped lines, as the page last measured them.
lines: u32 = 1,
/// Bumped on every open and close, so a "Filed" auto-close timer from an
/// earlier composer never closes a new one.
close_gen: u32 = 0,
sending: bool = false,
/// Reports filed from this pane, and the folder of the last one.
sends: u32 = 0,
filed: ?[]u8 = null,

/// What a worker completion needs to find its pane: the viewer pointer, read
/// and cleared only on the UI thread, behind a count every job holds.
const Link = struct {
    refs: std.atomic.Value(u32) = .init(1),
    viewer: ?*Viewer,

    fn ref(self: *Link) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn unref(self: *Link) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) alloc.destroy(self);
    }
};

/// One resolution, owned by the worker until it posts, then by the idle.
const Job = struct {
    link: *Link,
    gen: u32,
    key: []u8,
    plan: union(enum) {
        directory: []u8,
        port: struct { port: u16, fallback: ?[]u8 },
    },
    /// The answer, filled on the worker.
    root: ?[]u8 = null,

    fn destroy(self: *Job) void {
        alloc.free(self.key);
        switch (self.plan) {
            .directory => |d| alloc.free(d),
            .port => |p| if (p.fallback) |f| alloc.free(f),
        }
        if (self.root) |r| alloc.free(r);
        self.link.unref();
        alloc.destroy(self);
    }
};

// -------------------------------------------------------------------------
// Widgets and lifetime
// -------------------------------------------------------------------------

/// Make the button and append it to the bar's row, after the address (the
/// Mac's trailing slot). Hidden until a worktree is found.
pub fn buildUi(self: *ViewerFeedback, v: *Viewer, bar_row: *wk.GtkWidget) void {
    const b = wk.gtk_button_new_from_icon_name(icon_name);
    wk.gtk_widget_add_css_class(b, "flat");
    wk.gtk_widget_set_focus_on_click(b, 0);
    wk.gtk_widget_set_margin_start(b, 4);
    wk.gtk_widget_set_visible(b, 0);
    _ = wk.g_signal_connect_data(b, "clicked", @ptrCast(&onClicked), v, null, 0);
    wk.gtk_box_append(bar_row, b);
    self.button = b;
}

pub fn buttonWidget(self: *const ViewerFeedback) ?*wk.GtkWidget {
    return self.button;
}

/// The pane's `--working-directory`. Set right after `create`, before the
/// first load commits, so the first resolution already has it.
pub fn setOriginDirectory(self: *ViewerFeedback, dir: ?[]const u8) void {
    if (self.origin_dir) |d| alloc.free(d);
    self.origin_dir = null;
    const d = dir orelse return;
    if (d.len == 0) return;
    self.origin_dir = alloc.dupe(u8, d) catch null;
}

pub fn deinit(self: *ViewerFeedback) void {
    // A worker still running holds its own ref; cutting the viewer here
    // makes its idle find nobody.
    if (self.link) |l| {
        l.viewer = null;
        l.unref();
    }
    self.link = null;
    // The composer's view is a child of the pane's box and goes with it;
    // only our own ref on its content manager is ours to drop.
    if (self.ucm) |m| {
        if (self.message_handler != 0) wk.g_signal_handler_disconnect(m, self.message_handler);
        wk.g_object_unref(m);
    }
    self.ucm = null;
    self.view = null;
    self.text.deinit(alloc);
    if (self.status_text) |t| alloc.free(t);
    self.status_text = null;
    if (self.filed) |f| alloc.free(f);
    self.filed = null;
    self.cache.deinit();
    if (self.origin_dir) |d| alloc.free(d);
    self.origin_dir = null;
    if (self.root) |r| alloc.free(r);
    self.root = null;
    if (self.tooltip) |t| alloc.free(t);
    self.tooltip = null;
}

// -------------------------------------------------------------------------
// Resolution
// -------------------------------------------------------------------------

/// Re-decide the button for where the pane is NOW. Called on every committed
/// navigation (and when the pane is first told its origin).
pub fn refresh(self: *ViewerFeedback, v: *Viewer) void {
    var kbuf: [2 * std.fs.max_path_bytes + 2]u8 = undefined;
    const key = rules.Cache.key(&kbuf, v.current, self.origin_dir);
    const key_hash: u64 = if (key) |k| std.hash.Wyhash.hash(0, k) else 0;
    // The same question is already being answered (the pane's origin was set
    // and then its first load committed): let that answer land.
    if (self.pending and key != null and key_hash == self.inflight_hash) return;

    self.gen +%= 1;
    self.pending = false;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = rules.plan(&buf, v.current, self.origin_dir, rules.realDirExists);
    if (p == .none) return self.setRoot(null);

    const k = key orelse return self.setRoot(null);
    if (self.cache.get(k, nowMs())) |hit| return self.setRoot(hit);

    const link = self.ensureLink(v) orelse return;
    const job = alloc.create(Job) catch return;
    const key_dup = alloc.dupe(u8, k) catch {
        alloc.destroy(job);
        return;
    };
    job.* = .{
        .link = link,
        .gen = self.gen,
        .key = key_dup,
        .plan = switch (p) {
            .none => unreachable,
            .directory => |d| .{ .directory = alloc.dupe(u8, d) catch {
                alloc.free(key_dup);
                alloc.destroy(job);
                return;
            } },
            .port => |pp| .{ .port = .{
                .port = pp.port,
                .fallback = if (pp.fallback) |f| (alloc.dupe(u8, f) catch null) else null,
            } },
        },
    };
    link.ref();
    const t = std.Thread.spawn(.{}, work, .{job}) catch |err| {
        log.warn("viewer feedback: cannot start the worktree probe err={}", .{err});
        job.destroy();
        return;
    };
    t.detach();
    self.pending = true;
    self.inflight_hash = key_hash;
    self.resolves += 1;
}

fn ensureLink(self: *ViewerFeedback, v: *Viewer) ?*Link {
    if (self.link) |l| return l;
    const l = alloc.create(Link) catch return null;
    l.* = .{ .viewer = v };
    self.link = l;
    return l;
}

fn nowMs() u64 {
    return @intCast(@max(0, std.time.milliTimestamp()));
}

/// ON THE WORKER: resolve the job's plan to a repo root, then post it.
fn work(job: *Job) void {
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir: ?[]const u8 = switch (job.plan) {
        .directory => |d| d,
        .port => |p| blk: {
            if (listenerCwd(p.port, &dbuf)) |cwd| {
                if (rules.realDirExists(cwd)) {
                    log.info("viewer feedback: port {d} is served from {s}", .{ p.port, cwd });
                    break :blk cwd;
                }
            }
            break :blk p.fallback;
        },
    };
    if (dir) |d| job.root = gitRoot(d);
    _ = wk.g_idle_add(&onIdle, job);
}

/// `git rev-parse --show-toplevel` in `dir`, trying each git binary until one
/// launches. Null for "not in a repo" and for "no git at all".
fn gitRoot(dir: []const u8) ?[]u8 {
    var out: [std.fs.max_path_bytes]u8 = undefined;
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    for (0..rules.git_paths.len) |i| {
        const argv = rules.rootArgv(i, dir);
        const stdout = git_run.capture(alloc, &argv, &out) orelse continue;
        const root = rules.parseRoot(&rbuf, stdout) orelse return null;
        return alloc.dupe(u8, root) catch null;
    }
    return null;
}

/// Linux's lsof: the working directory of the process LISTENING on `port`,
/// into `buf`. Null when nothing listens, or the owner's fd table or cwd
/// cannot be read (another user's process) - the origin fallback.
fn listenerCwd(port: u16, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const inode = listenInode(port) orelse return null;
    var proc = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return null;
    defer proc.close();
    var it = proc.iterate();
    while (it.next() catch null) |entry| {
        if (!rules.isPid(entry.name)) continue;
        if (!ownsSocket(entry.name, inode)) continue;
        var pbuf: [64]u8 = undefined;
        const cwd_link = std.fmt.bufPrint(&pbuf, "/proc/{s}/cwd", .{entry.name}) catch continue;
        return std.fs.readLinkAbsolute(cwd_link, buf) catch null;
    }
    return null;
}

fn listenInode(port: u16) ?u64 {
    for (rules.tcp_tables) |path| {
        const f = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer f.close();
        const text = f.readToEndAlloc(alloc, 4 << 20) catch continue;
        defer alloc.free(text);
        if (rules.listenInode(text, port)) |i| return i;
    }
    return null;
}

fn ownsSocket(pid: []const u8, inode: u64) bool {
    var pbuf: [64]u8 = undefined;
    const fd_path = std.fmt.bufPrint(&pbuf, "/proc/{s}/fd", .{pid}) catch return false;
    var fds = std.fs.openDirAbsolute(fd_path, .{ .iterate = true }) catch return false;
    defer fds.close();
    var it = fds.iterate();
    while (it.next() catch null) |fd| {
        var lbuf: [128]u8 = undefined;
        const target = fds.readLink(fd.name, &lbuf) catch continue;
        if (rules.socketInode(target) == inode) return true;
    }
    return false;
}

/// ON THE UI LOOP: take a worker's answer, if the pane is still there and
/// still where the job was asked about.
fn onIdle(data: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(data orelse return 0));
    defer job.destroy();
    const v = job.link.viewer orelse return 0;
    const self = &v.feedback;
    // Cache the answer whatever happens next: it is true for its key.
    self.cache.put(job.key, job.root, nowMs());
    if (job.gen != self.gen) return 0;
    self.pending = false;
    self.setRoot(job.root);
    return 0;
}

/// Show the button for `root`, or hide it.
fn setRoot(self: *ViewerFeedback, root: ?[]const u8) void {
    const same = if (self.root) |old|
        (if (root) |r| std.mem.eql(u8, old, r) else false)
    else
        root == null;
    if (same) return;

    if (self.root) |old| alloc.free(old);
    self.root = null;
    if (self.tooltip) |t| alloc.free(t);
    self.tooltip = null;

    const b = self.button orelse return;
    const r = root orelse {
        // Nowhere to file now: a composer left open would be a lie too. Its
        // text stays on the pane for when a worktree comes back.
        if (self.open) self.hideComposer();
        wk.gtk_widget_set_visible(b, 0);
        wk.gtk_widget_set_tooltip_text(b, null);
        log.info("viewer feedback: worktree=none", .{});
        return;
    };
    self.root = alloc.dupeZ(u8, r) catch return;
    var tbuf: [std.fs.max_path_bytes + 32]u8 = undefined;
    self.tooltip = alloc.dupeZ(u8, rules.tooltipText(&tbuf, r)) catch null;
    wk.gtk_widget_set_tooltip_text(b, if (self.tooltip) |t| t.ptr else null);
    wk.gtk_widget_set_visible(b, 1);
    log.info("viewer feedback: worktree={s} name={s}", .{ r, rules.worktreeName(r) });
}

/// The steps seam's `feedback` line.
pub fn describe(self: *const ViewerFeedback, buf: []u8) []const u8 {
    const visible = if (self.button) |b| wk.gtk_widget_get_visible(b) != 0 else false;
    return std.fmt.bufPrint(buf, "button={} worktree={s} tip={s} pending={} resolves={d} clicks={d}", .{
        visible,
        if (self.root) |r| r else "-",
        if (self.tooltip) |t| t else "-",
        self.pending,
        self.resolves,
        self.clicks,
    }) catch "feedback OVERFLOW";
}

// -------------------------------------------------------------------------
// The composer (T3544)
// -------------------------------------------------------------------------
//
// The button opens a band under the nav bar: a pill holding the shared
// `composer.js` page in a SECOND web view (win32's D43 shape) and a round
// send button, with a footer line under it. The view exists only while the
// composer is open - D43's mitigation: a closed composer costs the pane
// nothing - and everything a user would miss lives here on the pane instead,
// so every open re-seeds the page from `text`. The page pushes a snapshot up
// on every edit; nothing here ever asks it a question.

/// Line box and font, in CSS pixels: Adwaita's body text.
const line_px: f32 = 20;
const font_px: f32 = 14;
/// How long the "Filed" confirmation shows before the composer closes.
const filed_close_ms: c_uint = 1500;
/// Reads the page's selection at send time: what the user was pointing at.
const selection_js = "String(window.getSelection ? window.getSelection() : '')";

/// Build the (hidden) composer band; the caller packs it under the bar.
pub fn buildComposerUi(self: *ViewerFeedback, v: *Viewer) *wk.GtkWidget {
    const band = wk.gtk_box_new(wk.orientation_vertical, 2);
    wk.gtk_widget_set_margin_start(band, 8);
    wk.gtk_widget_set_margin_end(band, 8);
    wk.gtk_widget_set_margin_top(band, 4);
    wk.gtk_widget_set_margin_bottom(band, 4);
    wk.gtk_widget_set_visible(band, 0);

    const pill = wk.gtk_box_new(wk.orientation_horizontal, 6);
    wk.gtk_widget_add_css_class(pill, "card");
    const slot = wk.gtk_box_new(wk.orientation_horizontal, 0);
    wk.gtk_widget_set_hexpand(slot, 1);
    wk.gtk_widget_set_margin_start(slot, 10);
    wk.gtk_widget_set_margin_top(slot, 6);
    wk.gtk_widget_set_margin_bottom(slot, 6);
    wk.gtk_box_append(pill, slot);

    const send_b = wk.gtk_button_new_from_icon_name("go-up-symbolic");
    wk.gtk_widget_add_css_class(send_b, "circular");
    wk.gtk_widget_add_css_class(send_b, "suggested-action");
    wk.gtk_widget_set_valign(send_b, wk.align_end);
    wk.gtk_widget_set_margin_end(send_b, 6);
    wk.gtk_widget_set_margin_bottom(send_b, 4);
    wk.gtk_widget_set_tooltip_text(send_b, "Send (Ctrl+Enter)");
    wk.gtk_widget_set_focus_on_click(send_b, 0);
    _ = wk.g_signal_connect_data(send_b, "clicked", @ptrCast(&onSendClicked), v, null, 0);
    wk.gtk_box_append(pill, send_b);
    wk.gtk_box_append(band, pill);

    const status = wk.gtk_label_new("");
    wk.gtk_label_set_xalign(status, 0);
    wk.gtk_widget_add_css_class(status, "dim-label");
    wk.gtk_widget_add_css_class(status, "caption");
    wk.gtk_box_append(band, status);

    self.band = band;
    self.slot = slot;
    self.send_button = send_b;
    self.status = status;
    return band;
}

pub fn sendButtonWidget(self: *const ViewerFeedback) ?*wk.GtkWidget {
    return self.send_button;
}

/// The button: open the composer, or close it when it is open (the Mac's
/// toggle).
fn onClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    const self = &v.feedback;
    self.clicks += 1;
    if (self.open) self.closeComposer(v) else self.openComposer(v);
}

fn onSendClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    v.feedback.send(v);
}

pub fn openComposer(self: *ViewerFeedback, v: *Viewer) void {
    const root = self.root orelse return;
    const band = self.band orelse return;
    self.open = true;
    self.close_gen +%= 1;
    wk.gtk_widget_set_visible(band, 1);
    var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    self.setStatus(host.destinationText(&buf, rules.worktreeName(root)));
    if (self.view == null) self.createView(v) else self.focusComposer();
    log.info("viewer feedback: composer open worktree={s} chars={d}", .{ root, self.text.items.len });
}

pub fn closeComposer(self: *ViewerFeedback, v: *Viewer) void {
    if (!self.open) return;
    self.hideComposer();
    // The caret goes back to the page the report was about.
    _ = wk.gtk_widget_grab_focus(wk.asWidget(v.view));
    log.info("viewer feedback: composer closed chars={d}", .{self.text.items.len});
}

/// Close without touching focus: the pane walked somewhere with no worktree.
fn hideComposer(self: *ViewerFeedback) void {
    self.open = false;
    self.close_gen +%= 1;
    if (self.band) |b| wk.gtk_widget_set_visible(b, 0);
    self.destroyView();
}

fn createView(self: *ViewerFeedback, v: *Viewer) void {
    const slot = self.slot orelse return;
    const w = wk.webkit_web_view_new();
    const cv = wk.asWebView(w);
    const m = wk.webkit_web_view_get_user_content_manager(cv);
    const script = wk.webkit_user_script_new(host.shim_js, wk.inject_top_frame, wk.inject_at_document_start, null, null);
    wk.webkit_user_content_manager_add_script(m, script);
    wk.webkit_user_script_unref(script);
    if (wk.webkit_user_content_manager_register_script_message_handler(m, host.handler_name, null) == 0) {
        log.warn("viewer feedback: could not register the {s} handler; the composer cannot report", .{host.handler_name});
    }
    _ = wk.g_object_ref(m);
    self.ucm = m;
    self.message_handler = wk.g_signal_connect_data(
        m,
        "script-message-received::" ++ host.handler_name,
        @ptrCast(&onComposerMessage),
        v,
        null,
        0,
    );
    wk.gtk_widget_set_hexpand(w, 1);
    wk.gtk_widget_set_size_request(w, -1, host.boxHeight(self.lines, line_px, 0));
    wk.gtk_box_append(slot, w);
    self.view = w;
    self.ready = false;

    const html = page.documentAlloc(alloc) catch return;
    defer alloc.free(html);
    const z = alloc.dupeZ(u8, html) catch return;
    defer alloc.free(z);
    wk.webkit_web_view_load_html(cv, z.ptr, null);
    _ = wk.gtk_widget_grab_focus(w);
}

fn destroyView(self: *ViewerFeedback) void {
    if (self.ucm) |m| {
        if (self.message_handler != 0) wk.g_signal_handler_disconnect(m, self.message_handler);
        wk.webkit_user_content_manager_unregister_script_message_handler(m, host.handler_name, null);
        wk.g_object_unref(m);
    }
    self.ucm = null;
    self.message_handler = 0;
    if (self.view) |w| if (self.slot) |s| wk.gtk_box_remove(s, w);
    self.view = null;
    self.ready = false;
}

/// Deliver one JSON message down to the page.
fn post(self: *ViewerFeedback, json: []const u8) void {
    const w = self.view orelse return;
    const script = host.deliverScript(alloc, json) catch return;
    defer alloc.free(script);
    wk.webkit_web_view_evaluate_javascript(wk.asWebView(w), script.ptr, @intCast(script.len), null, null, null, null, null);
}

fn pushVars(self: *ViewerFeedback) void {
    const vars: page.Vars = .{
        .face = "Cantarell, \"Noto Sans\", \"DejaVu Sans\"",
        .font_px = font_px,
        .line_px = line_px,
        .fg = "#1e1e1e",
        .bg = "#ffffff",
        .placeholder = "#8a8a8a",
        .selection = "#a9c8f0",
        .placeholder_text = "Describe what you see. Ctrl+Enter sends.",
        .quote_bg = "#eef3fb",
        .quote_accent = "#3584e4",
        .quote_indent_px = 12,
        .quote_bar_px = 3,
        .quote_bar_x_px = 2,
        .image_pad_px = 2,
        .image_radius_px = 4,
        .image_ink = "#1c71d8",
        .image_edge = "#3584e4",
        .image_max_bytes = 0,
    };
    const json = vars.json(alloc) catch return;
    defer alloc.free(json);
    self.post(json);
}

/// Make the page equal the pane's buffer - the only native write there is.
fn pushSeed(self: *ViewerFeedback) void {
    self.seed_gen +%= 1;
    const json = page.seedJson(alloc, self.text.items, self.caret, self.seed_gen, &.{}, &.{}, false) catch return;
    defer alloc.free(json);
    self.post(json);
}

fn focusComposer(self: *ViewerFeedback) void {
    const w = self.view orelse return;
    _ = wk.gtk_widget_grab_focus(w);
    if (self.ready) self.post(page.focus_json);
}

/// A message from the composer's page: the shim's send/close chords, or the
/// shared page's own traffic.
fn onComposerMessage(_: *wk.UserContentManager, value: *wk.JSCValue, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    const self = &v.feedback;
    const json = wk.jsc_value_to_json(value, 0) orelse return;
    defer wk.g_free(json);
    const text = std.mem.span(json);
    if (host.hostVerb(alloc, text)) |verb| {
        switch (verb) {
            .send => self.send(v),
            .close => self.closeComposer(v),
        }
        return;
    }
    const parsed = page.parse(alloc, text) orelse return;
    defer parsed.deinit();
    switch (parsed.message) {
        .ready => {
            // A fresh page - or one that reloaded itself - heals from the
            // pane's buffer.
            self.ready = true;
            self.pushVars();
            self.pushSeed();
            if (self.open) self.focusComposer();
        },
        .state => |st| self.adoptState(st),
        .image => log.info("viewer feedback: a pasted picture is not filed on Linux yet (T3546)", .{}),
        .focus, .journal => {},
    }
}

/// Keep the page's snapshot - unless it was measured before the latest seed.
fn adoptState(self: *ViewerFeedback, st: page.State) void {
    if (st.gen != self.seed_gen) return;
    self.text.clearRetainingCapacity();
    self.text.appendSlice(alloc, st.text) catch {};
    self.caret = if (st.caret) |c| @intCast(c) else -1;
    if (st.lines != self.lines) {
        self.lines = st.lines;
        if (self.view) |w| wk.gtk_widget_set_size_request(w, -1, host.boxHeight(self.lines, line_px, 0));
    }
}

fn setStatus(self: *ViewerFeedback, text: []const u8) void {
    if (self.status_text) |t| alloc.free(t);
    self.status_text = alloc.dupeZ(u8, text) catch null;
    if (self.status) |l| wk.gtk_label_set_text(l, if (self.status_text) |t| t.ptr else "");
}

// ---- sending ---------------------------------------------------------------

/// Ctrl+Enter or the send button. Reads the page's selection first (what the
/// user was pointing at), then files off the UI thread.
pub fn send(self: *ViewerFeedback, v: *Viewer) void {
    if (self.sending) return;
    if (self.root == null) return;
    if (!host.hasContent(self.text.items)) {
        self.setStatus("Nothing to send yet");
        return;
    }
    const link = self.ensureLink(v) orelse return;
    link.ref();
    self.sending = true;
    wk.webkit_web_view_evaluate_javascript(v.view, selection_js, selection_js.len, null, null, null, &onSelection, link);
}

fn onSelection(source: ?*wk.GObject, result: *wk.GAsyncResult, ud: ?*anyopaque) callconv(.c) void {
    const link: *Link = @ptrCast(@alignCast(ud orelse return));
    defer link.unref();
    var err: ?*wk.GError = null;
    const value = if (source) |s| wk.webkit_web_view_evaluate_javascript_finish(@ptrCast(s), result, &err) else null;
    if (err) |e| wk.g_error_free(e);
    var raw: ?[*:0]u8 = null;
    if (value) |val| {
        raw = wk.jsc_value_to_string(val);
        wk.g_object_unref(val);
    }
    defer if (raw) |r| wk.g_free(r);
    var selection: ?[]const u8 = null;
    if (raw) |r| {
        const s = std.mem.span(r);
        if (std.mem.trim(u8, s, " \t\r\n").len != 0) selection = s;
    }
    const v = link.viewer orelse return;
    v.feedback.beginSend(v, selection);
}

/// One filing, owned by the worker until it posts, then by the idle.
const SendJob = struct {
    arena: std.heap.ArenaAllocator,
    link: *Link,
    ctx: report.Context = undefined,
    body: []const u8 = "",
    epoch: u64,
    suffix: u24,
    ok: bool = false,
    folder: []const u8 = "",
    stem: []const u8 = "",
    err_name: []const u8 = "",

    fn destroy(self: *SendJob) void {
        self.link.unref();
        self.arena.deinit();
        alloc.destroy(self);
    }
};

fn beginSend(self: *ViewerFeedback, v: *Viewer, selection: ?[]const u8) void {
    const root = self.root orelse {
        self.sending = false;
        return;
    };
    const link = self.link orelse {
        self.sending = false;
        return;
    };
    const job = alloc.create(SendJob) catch {
        self.sending = false;
        return;
    };
    link.ref();
    job.* = .{
        .arena = .init(alloc),
        .link = link,
        .epoch = @intCast(@max(0, std.time.timestamp())),
        .suffix = std.crypto.random.int(u24),
    };
    self.fillJob(v, job, root, selection) catch {
        job.destroy();
        self.sending = false;
        self.setStatus("Could not file: out of memory");
        return;
    };
    const t = std.Thread.spawn(.{}, sendWork, .{job}) catch |err| {
        log.warn("viewer feedback: cannot start the send err={}", .{err});
        job.destroy();
        self.sending = false;
        self.setStatus("Could not file: no thread");
        return;
    };
    t.detach();
    self.setStatus("Sending...");
}

fn fillJob(self: *ViewerFeedback, v: *Viewer, job: *SendJob, root: []const u8, selection: ?[]const u8) !void {
    const aa = job.arena.allocator();
    const loc: []const u8 = v.current;
    const kind = host.kindFor(loc, content.modeFor(loc) == .image);
    const file = host.filePath(loc);
    var vbuf: [32]u8 = undefined;
    const vw = wk.asWidget(v.view);
    const viewport = host.viewportText(&vbuf, wk.gtk_widget_get_width(vw), wk.gtk_widget_get_height(vw));
    // A web page's own title; for a file, its name - the bundled template's
    // title is ours, not the document's.
    const title: ?[]const u8 = if (file) |f|
        std.fs.path.basename(f)
    else if (wk.webkit_web_view_get_title(v.view)) |t| std.mem.span(t) else null;
    const root_d = try aa.dupe(u8, root);
    var ctx: report.Context = .{
        .location = try aa.dupe(u8, loc),
        .kind = kind.text(),
        .file_path = if (file) |f| try aa.dupe(u8, f) else null,
        .page_title = if (title) |t| (if (t.len != 0) try aa.dupe(u8, t) else null) else null,
        // An image report carries no selection - the kind promises that.
        .selection = if (kind != .image) (if (selection) |s| try aa.dupe(u8, s) else null) else null,
        .pane_id = if (v.pane_id) |p| try aa.dupe(u8, p) else null,
        .viewport = if (viewport) |s| try aa.dupe(u8, s) else null,
        .worktree_path = root_d,
        .worktree_name = rules.worktreeName(root_d),
        .app_version = build_config.version_string,
    };
    if (ctx.file_path) |p| {
        const buf = try aa.alloc(u8, p.len);
        ctx.relative_path = report.relativePath(buf, p, root_d);
    }
    job.ctx = ctx;
    job.body = try report.renderBody(aa, self.text.items, &.{});
}

/// ON THE WORKER: the revision as of NOW (a branch switched under an
/// all-day pane is the one the report must name), then the staged folder and
/// its one atomic rename into the queue.
fn sendWork(job: *SendJob) void {
    const aa = job.arena.allocator();
    job.ctx.branch = revision(aa, job.ctx.worktree_path, .branch);
    job.ctx.commit = revision(aa, job.ctx.worktree_path, .commit);
    if (report.write(aa, job.ctx, job.body, &.{}, &.{}, job.epoch, job.suffix, null)) |w| {
        job.ok = true;
        job.folder = w.folder;
        job.stem = w.stem;
    } else |err| {
        job.err_name = @errorName(err);
    }
    _ = wk.g_idle_add(&onSent, job);
}

const Which = enum { branch, commit };

/// One `git rev-parse` against the worktree root. Null for every state that
/// is not an answer (no git, a detached HEAD, an unborn repo). BLOCKING.
fn revision(aa: Allocator, root: []const u8, which: Which) ?[]const u8 {
    for (0..rules.git_paths.len) |i| {
        var buf: [512]u8 = undefined;
        const out = switch (which) {
            .branch => blk: {
                const argv = rules.branchArgv(i, root);
                break :blk git_run.capture(alloc, &argv, &buf);
            },
            .commit => blk: {
                const argv = rules.commitArgv(i, root);
                break :blk git_run.capture(alloc, &argv, &buf);
            },
        } orelse continue;
        const parsed = switch (which) {
            .branch => rules.parseBranch(out),
            .commit => rules.parseCommit(out),
        } orelse return null;
        return aa.dupe(u8, parsed) catch null;
    }
    return null;
}

/// ON THE UI LOOP: the filing landed, or did not.
fn onSent(data: ?*anyopaque) callconv(.c) c_int {
    const job: *SendJob = @ptrCast(@alignCast(data orelse return 0));
    defer job.destroy();
    const v = job.link.viewer orelse return 0;
    const self = &v.feedback;
    self.sending = false;
    if (!job.ok) {
        // The text stays: a failed send is one the next press retries.
        var buf: [160]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&buf, "Could not file: {s}", .{job.err_name}) catch "Could not file");
        log.warn("viewer feedback: send failed err={s}", .{job.err_name});
        return 0;
    }
    self.sends += 1;
    if (self.filed) |f| alloc.free(f);
    self.filed = alloc.dupe(u8, job.folder) catch null;
    log.info("viewer feedback: filed {s}", .{job.folder});
    // The composer clears behind a filed report...
    self.text.clearRetainingCapacity();
    self.caret = -1;
    if (self.ready) self.pushSeed();
    var buf: [256]u8 = undefined;
    self.setStatus(host.filedText(&buf, job.stem));
    // ...shows the confirmation, then closes - unless the user has since
    // closed and reopened it, which is a new composer.
    if (!self.open) return 0;
    const t = alloc.create(CloseTimer) catch return 0;
    job.link.ref();
    t.* = .{ .link = job.link, .gen = self.close_gen };
    _ = wk.g_timeout_add(filed_close_ms, &onFiledTimeout, t);
    return 0;
}

const CloseTimer = struct { link: *Link, gen: u32 };

fn onFiledTimeout(data: ?*anyopaque) callconv(.c) c_int {
    const t: *CloseTimer = @ptrCast(@alignCast(data orelse return 0));
    defer {
        t.link.unref();
        alloc.destroy(t);
    }
    const v = t.link.viewer orelse return 0;
    const self = &v.feedback;
    if (self.open and self.close_gen == t.gen and !self.sending) self.closeComposer(v);
    return 0;
}

/// The steps seam's `composer` line; the text is escaped onto one line.
pub fn describeComposer(self: *const ViewerFeedback, buf: []u8) []const u8 {
    var tbuf: [1024]u8 = undefined;
    var n: usize = 0;
    for (self.text.items) |c| {
        var one: [1]u8 = .{c};
        const esc: []const u8 = switch (c) {
            '\n' => "\\n",
            '\\' => "\\\\",
            else => &one,
        };
        if (n + esc.len > tbuf.len) break;
        @memcpy(tbuf[n..][0..esc.len], esc);
        n += esc.len;
    }
    return std.fmt.bufPrint(buf, "open={} view={} ready={} lines={d} sending={} sends={d} filed={s} status={s} text={s}", .{
        self.open,
        self.view != null,
        self.ready,
        self.lines,
        self.sending,
        self.sends,
        if (self.filed) |f| f else "-",
        if (self.status_text) |s| s else "-",
        tbuf[0..n],
    }) catch "composer OVERFLOW";
}
