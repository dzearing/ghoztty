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
//! The composer the button opens is T3544; until then a click logs that.
const ViewerFeedback = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Viewer = @import("Viewer.zig");
const wk = @import("webkit.zig");
const rules = @import("viewer_worktree.zig");
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
/// How many clicks the button has had (the composer is T3544's).
clicks: u32 = 0,

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

fn onClicked(_: *wk.GtkWidget, ud: ?*anyopaque) callconv(.c) void {
    const v: *Viewer = @ptrCast(@alignCast(ud orelse return));
    const self = &v.feedback;
    self.clicks += 1;
    log.info("viewer feedback: clicked worktree={s}; the composer is not built on Linux yet (T3544)", .{
        if (self.root) |r| r else "-",
    });
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
