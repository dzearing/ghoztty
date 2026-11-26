//! The "New Remote Window" machine chooser on GTK (T3674, Linux L11a-2):
//! Ctrl+Shift+N, the window menu and Settings > Remote Machines open it.
//! Mac `MachineChooserView`, win32 `MachineChooser.zig`, as a libadwaita
//! dialog: the account line across the top, the machines on the left, the
//! selected machine's detail on the right - its name and state, New Window,
//! Host Settings..., and the sessions still running on it, each with Resume
//! (or Show, when one of our panes already holds it) and End.
//!
//! What it is for, on Linux today: a Disconnect (T3563) leaves the remote
//! session running, and this is where it comes back - Resume opens a window
//! whose pane ATTACHes to it.
//!
//! **It never waits on the network to open** (win32's T711). Rows come from
//! the remembered directory (`machine_cache`, shared with Settings), drawn as
//! "Checking status"; one fetch on a worker confirms who is online, and it
//! re-runs every `chooser_refresh.poll_ms` while the chooser is open, keeping
//! the list that is true through a transient failure.
//!
//! **A machine's roster is fetched on a worker** when it is selected, and
//! again in place on every poll tick, so a session a Disconnect just left
//! appears and one that exited goes. Local rides the shared local-agent
//! connection; a relay machine is dialed per fetch. Not here yet, each a
//! card of its own: the warm per-machine connection pool and the pushed
//! roster (win32 T461/T710), per-session CPU meters (T462), Restore All
//! (T335), See Activity, rename and remove, the account row's Sign In
//! (T3575).
//!
//! One chooser at a time; GTK main thread only, except the job bodies, which
//! touch no GTK state and land back through `g_idle_add`, tagged with a
//! generation so a reply for a closed chooser or an older selection is
//! dropped.
const MachineChooser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const wk = @import("webkit.zig");

const rules = @import("machine_chooser_rules.zig");
const chooser_sessions = rules.chooser_sessions;
const chooser_session_sort = rules.chooser_session_sort;
const chooser_help = rules.chooser_help;
const chooser_refresh = @import("../win32/chooser_refresh.zig");
const machine_cache = @import("../win32/machine_cache.zig");
const live = @import("../win32/settings_live.zig");
const relay_directory = @import("../../remote/relay_directory.zig");
const relay_signin = @import("../../remote/relay_signin.zig");
const relay_account = @import("../../remote/relay_account.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const connection = @import("../../remote/connection.zig");
const ipc_remote_window = @import("ipc_remote_window.zig");
const RemoteLink = @import("RemoteLink.zig");
const HostSettingsDialog = @import("HostSettingsDialog.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Surface = @import("class/surface.zig").Surface;

const log = std.log.scoped(.gtk_chooser);

const c_alloc = std.heap.c_allocator;

/// The most machines the list shows (win32's and Settings' cap).
const max_machines = 64;
/// How long a roster or End RPC may take before the region says so.
const rpc_timeout_ns: u64 = 5 * std.time.ns_per_s;

pub const title = "New Remote Window";

app: *Application,
parent: *Window,
dialog: *wk.GtkWidget,
account_label: *wk.GtkWidget,
machine_list: *wk.GtkWidget,
detail_title: *wk.GtkWidget,
detail_subtitle: *wk.GtkWidget,
new_window_btn: *wk.GtkWidget,
host_btn: *wk.GtkWidget,
state_label: *wk.GtkWidget,
session_list: *wk.GtkWidget,

/// This chooser's identity in every job it starts.
id: u64,

// ---- machines -----------------------------------------------------------

/// Owns `email` and every machine's strings; reset by each rebuild.
arena: std.heap.ArenaAllocator,
machines: std.ArrayListUnmanaged(rules.Machine) = .empty,
email: ?[]const u8 = null,
account: live.Account = .signed_out,
/// The selected machine's id, kept across a rebuild (`rules.reselect`).
sel_buf: [128]u8 = undefined,
sel_len: usize = 0,
has_selection: bool = false,
/// The list is being rebuilt: ignore the row-selected it emits.
rebuilding: bool = false,
dir_inflight: bool = false,
dir_gen: u64 = 0,
misses: chooser_refresh.Misses = .{},
poll_source: c_uint = 0,

// ---- the roster -----------------------------------------------------------

/// Owns the roster's entries and labels; reset on each adopt.
roster_arena: std.heap.ArenaAllocator,
entries: []rules.Entry = &.{},
labels: [][]const u8 = &.{},
shown_buf: [rules.max_rows]usize = undefined,
shown: []usize = &.{},
roster_state: chooser_sessions.State = .loading,
roster_inflight: bool = false,
roster_gen: u64 = 0,
/// The machine the shown roster belongs to.
roster_for_buf: [128]u8 = undefined,
roster_for_len: usize = 0,
order: chooser_session_sort.Order = chooser_session_sort.initial,
session_rows: std.ArrayListUnmanaged(SessionRow) = .empty,

/// What the chooser last did, for the seam (`new-window`, `resume <id>`,
/// `show <id>`, `end <id>`, a failure sentence).
last_buf: [256]u8 = undefined,
last_len: usize = 0,

const SessionRow = struct { row: *wk.GtkWidget, action: *wk.GtkWidget, end: *wk.GtkWidget, entry: usize };

var open_chooser: ?*MachineChooser = null;
var next_gen: u64 = 1;
/// What the last chooser did, kept after it closed (Resume closes it).
var last_global_buf: [256]u8 = undefined;
var last_global_len: usize = 0;

fn mint() u64 {
    const g = next_gen;
    next_gen += 1;
    return g;
}

/// The open chooser, for the seam and the jobs.
pub fn current() ?*MachineChooser {
    return open_chooser;
}

pub fn lastAction() []const u8 {
    return last_global_buf[0..last_global_len];
}

// ---------------------------------------------------------------------
// Opening and closing
// ---------------------------------------------------------------------

/// Open the chooser over `parent` (Ctrl+Shift+N, the menu, Settings). One at
/// a time: a second open re-presents the first.
pub fn open(app: *Application, parent: *Window) void {
    if (open_chooser) |c| {
        wk.adw_dialog_present(c.dialog, @ptrCast(c.parent));
        return;
    }
    const self = c_alloc.create(MachineChooser) catch return;
    self.* = build(app, parent);
    open_chooser = self;
    _ = wk.g_signal_connect_data(self.dialog, "closed", @ptrCast(&onClosed), self, null, 0);
    self.reload();
    self.poll_source = wk.g_timeout_add(chooser_refresh.poll_ms, &onPoll, self);
    wk.adw_dialog_present(self.dialog, @ptrCast(parent));
    log.info("machine chooser: opened with {d} machine(s)", .{self.machines.items.len});
}

/// Close the chooser (the seam, Resume, New Window).
pub fn close(self: *MachineChooser) void {
    wk.adw_dialog_force_close(self.dialog);
}

fn onClosed(_: *wk.GtkWidget, self: *MachineChooser) callconv(.c) void {
    if (self.poll_source != 0) _ = wk.g_source_remove(self.poll_source);
    self.poll_source = 0;
    if (HostSettingsDialog.current()) |d| d.close();
    if (open_chooser == self) open_chooser = null;
    self.machines.deinit(c_alloc);
    self.session_rows.deinit(c_alloc);
    self.arena.deinit();
    self.roster_arena.deinit();
    log.info("machine chooser: closed", .{});
    c_alloc.destroy(self);
}

fn setText(lbl: *wk.GtkWidget, text: []const u8) void {
    var zb: [1024]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{text}) catch return;
    wk.gtk_label_set_text(lbl, z.ptr);
}

fn setTip(w: *wk.GtkWidget, text: []const u8) void {
    var zb: [chooser_help.max_len + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{text}) catch return;
    wk.gtk_widget_set_tooltip_text(w, z.ptr);
}

fn label(text: [*:0]const u8, xalign: f32) *wk.GtkWidget {
    const l = wk.gtk_label_new(text);
    wk.gtk_label_set_xalign(l, xalign);
    wk.gtk_label_set_ellipsize(l, wk.ellipsize_end);
    return l;
}

fn build(app: *Application, parent: *Window) MachineChooser {
    const dialog = wk.adw_dialog_new();
    wk.adw_dialog_set_title(dialog, title);
    // Mac's 840x540.
    wk.adw_dialog_set_content_width(dialog, 840);
    wk.adw_dialog_set_content_height(dialog, 540);

    const toolbar = wk.adw_toolbar_view_new();
    wk.adw_toolbar_view_add_top_bar(toolbar, wk.adw_header_bar_new());

    const outer = wk.gtk_box_new(wk.orientation_vertical, 0);
    // The account row (Mac `accountRow`).
    const account_label = label("Not signed in", 0);
    wk.gtk_widget_add_css_class(account_label, "dim-label");
    wk.gtk_widget_set_margin_start(account_label, 16);
    wk.gtk_widget_set_margin_end(account_label, 16);
    wk.gtk_widget_set_margin_top(account_label, 8);
    wk.gtk_widget_set_margin_bottom(account_label, 8);
    wk.gtk_box_append(outer, account_label);
    wk.gtk_box_append(outer, wk.gtk_separator_new(wk.orientation_horizontal));

    const paned = wk.gtk_paned_new(wk.orientation_horizontal);
    wk.gtk_widget_set_vexpand(paned, 1);
    wk.gtk_paned_set_shrink_start_child(paned, 0);
    wk.gtk_paned_set_shrink_end_child(paned, 0);
    wk.gtk_paned_set_position(paned, 260);

    // The machine column.
    const machine_list = wk.gtk_list_box_new();
    wk.gtk_widget_add_css_class(machine_list, "navigation-sidebar");
    const msw = wk.gtk_scrolled_window_new();
    wk.gtk_scrolled_window_set_policy(msw, wk.policy_never, wk.policy_automatic);
    wk.gtk_scrolled_window_set_child(msw, machine_list);
    wk.gtk_paned_set_start_child(paned, msw);

    // The detail pane.
    const detail = wk.gtk_box_new(wk.orientation_vertical, 8);
    wk.gtk_widget_set_margin_start(detail, 16);
    wk.gtk_widget_set_margin_end(detail, 16);
    wk.gtk_widget_set_margin_top(detail, 12);
    wk.gtk_widget_set_margin_bottom(detail, 12);
    const head = wk.gtk_box_new(wk.orientation_horizontal, 8);
    const titles = wk.gtk_box_new(wk.orientation_vertical, 2);
    wk.gtk_widget_set_hexpand(titles, 1);
    const detail_title = label("", 0);
    wk.gtk_widget_add_css_class(detail_title, "title-2");
    const detail_subtitle = label("", 0);
    wk.gtk_widget_add_css_class(detail_subtitle, "dim-label");
    wk.gtk_box_append(titles, detail_title);
    wk.gtk_box_append(titles, detail_subtitle);
    wk.gtk_box_append(head, titles);
    const host_btn = wk.gtk_button_new_with_label("Host Settings\u{2026}");
    wk.gtk_widget_set_valign(host_btn, 3);
    wk.gtk_box_append(head, host_btn);
    const new_window_btn = wk.gtk_button_new_with_label("New Window");
    wk.gtk_widget_add_css_class(new_window_btn, "suggested-action");
    wk.gtk_widget_set_valign(new_window_btn, 3);
    wk.gtk_box_append(head, new_window_btn);
    wk.gtk_box_append(detail, head);

    const state_label = label("", 0.5);
    wk.gtk_widget_add_css_class(state_label, "dim-label");
    wk.gtk_widget_set_margin_top(state_label, 24);
    wk.gtk_box_append(detail, state_label);
    const session_list = wk.gtk_list_box_new();
    wk.gtk_widget_add_css_class(session_list, "boxed-list");
    wk.gtk_list_box_set_selection_mode(session_list, 0); // GTK_SELECTION_NONE
    const ssw = wk.gtk_scrolled_window_new();
    wk.gtk_widget_set_vexpand(ssw, 1);
    wk.gtk_scrolled_window_set_policy(ssw, wk.policy_never, wk.policy_automatic);
    wk.gtk_scrolled_window_set_child(ssw, session_list);
    wk.gtk_box_append(detail, ssw);
    wk.gtk_paned_set_end_child(paned, detail);

    wk.gtk_box_append(outer, paned);
    wk.adw_toolbar_view_set_content(toolbar, outer);
    wk.adw_dialog_set_child(dialog, toolbar);

    return .{
        .app = app,
        .parent = parent,
        .dialog = dialog,
        .account_label = account_label,
        .machine_list = machine_list,
        .detail_title = detail_title,
        .detail_subtitle = detail_subtitle,
        .new_window_btn = new_window_btn,
        .host_btn = host_btn,
        .state_label = state_label,
        .session_list = session_list,
        .id = mint(),
        .arena = .init(c_alloc),
        .roster_arena = .init(c_alloc),
    };
}

fn connectOnce(self: *MachineChooser) void {
    _ = wk.g_signal_connect_data(self.machine_list, "row-selected", @ptrCast(&onMachineSelected), self, null, 0);
    _ = wk.g_signal_connect_data(self.new_window_btn, "clicked", @ptrCast(&onNewWindow), self, null, 0);
    _ = wk.g_signal_connect_data(self.host_btn, "clicked", @ptrCast(&onHostSettings), self, null, 0);
}

fn noteLast(self: *MachineChooser, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&self.last_buf, fmt, args) catch self.last_buf[0..0];
    self.last_len = s.len;
    @memcpy(last_global_buf[0..s.len], s);
    last_global_len = s.len;
    log.info("machine chooser: {s}", .{s});
}

pub fn last(self: *const MachineChooser) []const u8 {
    return self.last_buf[0..self.last_len];
}

// ---------------------------------------------------------------------
// The machine list
// ---------------------------------------------------------------------

/// Seed from local state (account, remembered directory), then ask the
/// relay on a worker. Called once at open.
fn reload(self: *MachineChooser) void {
    self.connectOnce();
    const a = self.arena.allocator();
    self.email = relay_signin.signedInEmail(a);
    const signed_in = signedIn(a);
    self.account = if (signed_in)
        .signed_in
    else if (relay_signin.isConfigured(a)) .signed_out else .unconfigured;
    self.drawAccount();

    var devices: std.ArrayList(DeviceRow) = .empty;
    if (signed_in) if (machine_cache.load(c_alloc, self.email orelse "")) |cached| {
        defer cached.deinit();
        for (cached.value.devices) |e| {
            devices.append(a, .{
                .id = a.dupe(u8, e.id) catch continue,
                .name = a.dupe(u8, e.name) catch continue,
                .hostname = if (e.hostname) |h| a.dupe(u8, h) catch null else null,
                .presence = .checking,
            }) catch break;
        }
    };
    self.setMachines(devices.items);
    if (signed_in) self.startDirectory();
}

fn signedIn(a: Allocator) bool {
    const path = relay_account.accountPath(a) catch return envToken();
    if (relay_account.isSignedIn(a, path)) return true;
    return envToken();
}

fn envToken() bool {
    const tok = std.posix.getenv("GHOSTTY_RELAY_TOKEN") orelse return false;
    return tok.len > 0;
}

fn drawAccount(self: *MachineChooser) void {
    var tb: [200]u8 = undefined;
    setText(self.account_label, live.accountTitle(&tb, self.account, self.email));
    if (self.account == .signed_in) if (self.email) |e| {
        var hb: [chooser_help.max_len]u8 = undefined;
        setTip(self.account_label, chooser_help.signedIn(&hb, e));
    };
}

const DeviceRow = struct {
    id: []const u8,
    name: []const u8,
    hostname: ?[]const u8 = null,
    presence: rules.chooser_rows.Presence,
};

/// Replace the list: Local first, then `devices` (borrowed from `arena`,
/// which outlives this call). Keeps the selection by id.
fn setMachines(self: *MachineChooser, devices: []const DeviceRow) void {
    self.machines.clearRetainingCapacity();
    self.machines.append(c_alloc, .{ .kind = .local, .id = rules.local_id, .name = "Local", .presence = .online }) catch return;
    for (devices) |d| {
        if (self.machines.items.len >= max_machines) break;
        self.machines.append(c_alloc, .{
            .kind = .relay,
            .id = d.id,
            .name = d.name,
            .hostname = d.hostname,
            .presence = d.presence,
        }) catch break;
    }
    self.drawMachines();
}

fn selectedId(self: *const MachineChooser) ?[]const u8 {
    if (!self.has_selection) return null;
    return self.sel_buf[0..self.sel_len];
}

pub fn selectedMachine(self: *const MachineChooser) ?rules.Machine {
    const id = self.selectedId() orelse return null;
    for (self.machines.items) |m| if (std.mem.eql(u8, m.id, id)) return m;
    return null;
}

fn drawMachines(self: *MachineChooser) void {
    self.rebuilding = true;
    defer self.rebuilding = false;
    wk.gtk_list_box_remove_all(self.machine_list);
    var ids: [max_machines + 1][]const u8 = undefined;
    for (self.machines.items, 0..) |m, i| {
        ids[i] = m.id;
        const rt = m.rowText();
        const row = wk.gtk_list_box_row_new();
        const box = wk.gtk_box_new(wk.orientation_horizontal, 8);
        wk.gtk_widget_set_margin_top(box, 6);
        wk.gtk_widget_set_margin_bottom(box, 6);
        const dot = wk.gtk_label_new("\u{25CF}");
        wk.gtk_widget_add_css_class(dot, switch (m.presence) {
            .online => "success",
            .offline => "dim-label",
            .checking => "warning",
        });
        if (m.kind == .relay) setTip(dot, chooser_help.machineStatus(m.presence)) else wk.gtk_widget_set_visible(dot, 0);
        wk.gtk_box_append(box, dot);
        const texts = wk.gtk_box_new(wk.orientation_vertical, 0);
        var zb: [256]u8 = undefined;
        const t = label((std.fmt.bufPrintZ(&zb, "{s}", .{rt.title}) catch "?").ptr, 0);
        var sb: [256]u8 = undefined;
        const s = label((std.fmt.bufPrintZ(&sb, "{s}", .{rt.subtitle}) catch "").ptr, 0);
        wk.gtk_widget_add_css_class(s, "dim-label");
        wk.gtk_widget_add_css_class(s, "caption");
        wk.gtk_box_append(texts, t);
        wk.gtk_box_append(texts, s);
        wk.gtk_box_append(box, texts);
        wk.gtk_list_box_row_set_child(row, box);
        wk.gtk_list_box_append(self.machine_list, row);
    }
    const pick = rules.reselect(ids[0..self.machines.items.len], self.selectedId()) orelse return;
    if (wk.gtk_list_box_get_row_at_index(self.machine_list, @intCast(pick))) |row|
        wk.gtk_list_box_select_row(self.machine_list, row);
    self.rebuilding = false;
    self.selectIndex(pick);
}

fn onMachineSelected(_: *wk.GtkWidget, row: ?*wk.GtkWidget, self: *MachineChooser) callconv(.c) void {
    if (self.rebuilding) return;
    const r = row orelse return;
    const i: usize = @intCast(@max(wk.gtk_list_box_row_get_index(r), 0));
    self.selectIndex(i);
}

/// Select the machine at `i`: draw its detail, then fetch or refresh its
/// roster (`chooser_sessions.transitionFor`).
pub fn selectIndex(self: *MachineChooser, i: usize) void {
    if (i >= self.machines.items.len) return;
    const m = self.machines.items[i];
    const prev = self.roster_for_buf[0..self.roster_for_len];
    const same = self.roster_for_len > 0 and std.mem.eql(u8, prev, m.id);
    const n = @min(m.id.len, self.sel_buf.len);
    @memcpy(self.sel_buf[0..n], m.id[0..n]);
    self.sel_len = n;
    self.has_selection = true;
    if (!same) {
        // A different machine: drop what is shown (machine A's sessions
        // under machine B's name is worse than nothing) and fetch.
        self.clearRoster();
        self.roster_state = .loading;
        self.roster_inflight = false;
        @memcpy(self.roster_for_buf[0..n], m.id[0..n]);
        self.roster_for_len = n;
        self.drawDetail();
        self.startRoster(null);
    } else {
        self.drawDetail();
        if (!self.roster_inflight) self.startRoster(null);
    }
}

pub fn selectId(self: *MachineChooser, id: []const u8) bool {
    for (self.machines.items, 0..) |m, i| if (std.mem.eql(u8, m.id, id)) {
        if (wk.gtk_list_box_get_row_at_index(self.machine_list, @intCast(i))) |row| {
            self.rebuilding = true;
            wk.gtk_list_box_select_row(self.machine_list, row);
            self.rebuilding = false;
        }
        self.selectIndex(i);
        return true;
    };
    return false;
}

fn drawDetail(self: *MachineChooser) void {
    const m = self.selectedMachine() orelse return;
    setText(self.detail_title, m.detailTitle());
    var sb: [384]u8 = undefined;
    const count: ?usize = if (self.roster_state == .loaded) self.shown.len else null;
    setText(self.detail_subtitle, m.detailSubtitle(&sb, count));
    var hb: [chooser_help.max_len]u8 = undefined;
    setTip(self.new_window_btn, chooser_help.newWindow(&hb, m.detailTitle()));
    // Host Settings... edits a relay machine's defaults (Mac's management
    // menu has none for Local).
    wk.gtk_widget_set_visible(self.host_btn, @intFromBool(m.kind == .relay));
    if (m.kind == .relay) setTip(self.host_btn, chooser_help.manage(&hb, m.name));
}

// ---------------------------------------------------------------------
// The directory fetch (a worker)
// ---------------------------------------------------------------------

const DirJob = struct {
    arena: std.heap.ArenaAllocator,
    owner: u64,
    gen: u64,
    account: []const u8,
    err: ?anyerror = null,
    unauthorized: bool = false,
    devices: []const relay_directory.Device = &.{},
};

fn startDirectory(self: *MachineChooser) void {
    if (self.dir_inflight) return;
    const job = c_alloc.create(DirJob) catch return;
    self.dir_gen = mint();
    job.* = .{ .arena = .init(c_alloc), .owner = self.id, .gen = self.dir_gen, .account = "" };
    job.account = job.arena.allocator().dupe(u8, self.email orelse "") catch "";
    const t = std.Thread.spawn(.{}, runDirectory, .{job}) catch {
        job.arena.deinit();
        c_alloc.destroy(job);
        return;
    };
    t.detach();
    self.dir_inflight = true;
}

fn runDirectory(job: *DirJob) void {
    defer _ = wk.g_idle_add(&onDirectory, job);
    const a = job.arena.allocator();
    const token = ipc_remote_window.resolveToken(a) orelse {
        job.err = error.NoToken;
        return;
    };
    const base = relay_directory.resolveBase(a) catch relay_directory.default_base;
    const parsed = relay_directory.listDevices(a, base, token) catch |err| {
        job.err = err;
        if (err == error.Unauthorized) {
            job.unauthorized = true;
            machine_cache.clear(a);
        }
        return;
    };
    job.devices = parsed.value.devices;
    var entries: std.ArrayList(machine_cache.Entry) = .empty;
    for (job.devices) |d| entries.append(a, .{ .id = d.id, .name = d.name, .hostname = d.hostname }) catch break;
    machine_cache.save(a, job.account, entries.items);
}

fn onDirectory(ud: ?*anyopaque) callconv(.c) c_int {
    const job: *DirJob = @ptrCast(@alignCast(ud orelse return 0));
    defer {
        job.arena.deinit();
        c_alloc.destroy(job);
    }
    const self = open_chooser orelse return 0;
    if (self.id != job.owner or self.dir_gen != job.gen) return 0;
    self.dir_inflight = false;
    if (job.unauthorized) {
        self.misses.succeeded();
        self.setMachines(&.{});
        log.info("machine chooser: the relay refused the credential; list cleared", .{});
        return 0;
    }
    if (job.err) |err| {
        // Keep the list that is true; say so only after a streak.
        if (self.misses.failed()) log.warn("machine chooser: directory fetch failed err={}", .{err});
        return 0;
    }
    self.misses.succeeded();
    const a = self.arena.allocator();
    var devices: std.ArrayList(DeviceRow) = .empty;
    for (job.devices) |d| {
        devices.append(a, .{
            .id = a.dupe(u8, d.id) catch continue,
            .name = a.dupe(u8, d.name) catch continue,
            .hostname = if (d.hostname) |h| a.dupe(u8, h) catch null else null,
            .presence = rules.chooser_rows.Presence.fromOnline(d.online),
        }) catch break;
    }
    self.setMachines(devices.items);
    log.info("machine chooser: directory has {d} machine(s)", .{devices.items.len});
    return 0;
}

fn onPoll(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *MachineChooser = @ptrCast(@alignCast(ud orelse return 0));
    if (open_chooser != self) return 0;
    switch (chooser_refresh.tick(self.account == .signed_in, self.dir_inflight)) {
        .fetch => self.startDirectory(),
        .skip_signed_out, .skip_inflight => {},
    }
    // The roster refreshes in place on the same beat (the pushed roster is
    // a card of its own).
    if (self.has_selection and !self.roster_inflight) self.startRoster(null);
    return 1;
}

// ---------------------------------------------------------------------
// The roster (a worker per fetch)
// ---------------------------------------------------------------------

const RosterTarget = union(enum) {
    local: *connection.Connection,
    relay: struct { device: []const u8 },
};

const RosterJob = struct {
    arena: std.heap.ArenaAllocator,
    owner: u64,
    gen: u64,
    machine: []const u8,
    target: RosterTarget,
    /// End this session first (the card's End button).
    end: ?[]const u8 = null,
    end_ok: ?bool = null,
    err: ?anyerror = null,
    sessions: []chooser_sessions.Session = &.{},
};

fn startRoster(self: *MachineChooser, end: ?[]const u8) void {
    const m = self.selectedMachine() orelse return;
    const job = c_alloc.create(RosterJob) catch return;
    self.roster_gen = mint();
    job.* = .{
        .arena = .init(c_alloc),
        .owner = self.id,
        .gen = self.roster_gen,
        .machine = "",
        .target = .{ .relay = .{ .device = "" } },
    };
    const a = job.arena.allocator();
    job.machine = a.dupe(u8, m.id) catch "";
    if (end) |e| job.end = a.dupe(u8, e) catch null;
    switch (m.kind) {
        .local => {
            // With session persistence off no local pane rides an agent,
            // and showing the chooser must not start one.
            if (!self.app.getConfig().get().@"session-persistence") {
                _ = wk.g_idle_add(&onRoster, job);
                self.roster_inflight = true;
                return;
            }
            const conn = self.app.rt().local_agent.sharedConnection() orelse {
                job.err = error.NoLocalAgent;
                _ = wk.g_idle_add(&onRoster, job);
                self.roster_inflight = true;
                return;
            };
            job.target = .{ .local = conn };
        },
        .relay => job.target = .{ .relay = .{ .device = a.dupe(u8, m.id) catch "" } },
    }
    const t = std.Thread.spawn(.{}, runRoster, .{job}) catch {
        job.arena.deinit();
        c_alloc.destroy(job);
        return;
    };
    t.detach();
    self.roster_inflight = true;
}

fn runRoster(job: *RosterJob) void {
    defer _ = wk.g_idle_add(&onRoster, job);
    switch (job.target) {
        .local => |conn| fetchOn(job, conn),
        .relay => |r| {
            const a = job.arena.allocator();
            const token = ipc_remote_window.resolveToken(a) orelse {
                job.err = error.Unauthorized;
                return;
            };
            const base = relay_directory.resolveBase(a) catch relay_directory.default_base;
            var d = relay_dial.dial(c_alloc, base, r.device, token, .raw) catch |err| {
                job.err = err;
                return;
            };
            defer d.deinit();
            fetchOn(job, d.conn);
        },
    }
}

/// End `job.end` if asked, then read the roster, copying it into the job's
/// arena so it outlives the connection.
fn fetchOn(job: *RosterJob, conn: *connection.Connection) void {
    if (job.end) |sid| {
        job.end_ok = conn.closeSession(sid, rpc_timeout_ns) catch |err| blk: {
            log.warn("machine chooser: End {s} failed err={}", .{ sid, err });
            break :blk false;
        };
    }
    var owned = conn.requestSessions(rpc_timeout_ns) catch |err| {
        job.err = err;
        return;
    };
    defer owned.deinit();
    const a = job.arena.allocator();
    const out = a.alloc(chooser_sessions.Session, owned.sessions.len) catch {
        job.err = error.OutOfMemory;
        return;
    };
    for (owned.sessions, 0..) |s, i| out[i] = .{
        .id = a.dupe(u8, s.id) catch "",
        .alive = s.alive,
        .relaunchable = s.relaunchable,
        .exit_code = s.exit_code,
        .attached = s.attached,
        .activity = a.dupe(u8, s.activity) catch "idle",
        .pid = s.pid,
        .title = if (s.title) |t| a.dupe(u8, t) catch null else null,
        .cwd = if (s.cwd) |c| a.dupe(u8, c) catch null else null,
        .argv = if (s.argv) |v| a.dupe(u8, v) catch null else null,
        .fg_cmd = if (s.fg_cmd) |f| a.dupe(u8, f) catch null else null,
    };
    job.sessions = out;
}

fn onRoster(ud: ?*anyopaque) callconv(.c) c_int {
    const job: *RosterJob = @ptrCast(@alignCast(ud orelse return 0));
    defer {
        job.arena.deinit();
        c_alloc.destroy(job);
    }
    const self = open_chooser orelse return 0;
    if (self.id != job.owner or self.roster_gen != job.gen) return 0;
    self.roster_inflight = false;
    if (!std.mem.eql(u8, job.machine, self.roster_for_buf[0..self.roster_for_len])) return 0;
    if (job.end) |sid| {
        if (job.end_ok orelse false) self.noteLast("end {s}", .{sid}) else self.noteLast("end {s} failed", .{sid});
    }
    if (job.err) |err| {
        log.info("machine chooser: roster for {s} failed err={}", .{ job.machine, err });
        // A refresh in place that fails keeps the rows it has.
        if (self.roster_state != .loaded) {
            self.roster_state = rules.failureState(err);
            self.drawRoster();
        }
        return 0;
    }
    self.adoptRoster(job.sessions);
    return 0;
}

fn clearRoster(self: *MachineChooser) void {
    _ = self.roster_arena.reset(.retain_capacity);
    self.entries = &.{};
    self.labels = &.{};
    self.shown = &.{};
}

fn adoptRoster(self: *MachineChooser, sessions: []const chooser_sessions.Session) void {
    const m = self.selectedMachine() orelse return;
    self.clearRoster();
    const a = self.roster_arena.allocator();
    const entries = a.alloc(rules.Entry, sessions.len) catch return;
    const labels = a.alloc([]const u8, sessions.len) catch return;
    const device: ?[]const u8 = if (m.kind == .relay) m.id else null;
    for (sessions, 0..) |s0, i| {
        var s = s0;
        s.id = a.dupe(u8, s0.id) catch "";
        s.activity = a.dupe(u8, s0.activity) catch "idle";
        s.title = if (s0.title) |t| a.dupe(u8, t) catch null else null;
        s.cwd = if (s0.cwd) |c| a.dupe(u8, c) catch null else null;
        s.argv = if (s0.argv) |v| a.dupe(u8, v) catch null else null;
        s.fg_cmd = if (s0.fg_cmd) |f| a.dupe(u8, f) catch null else null;
        const pane = IpcHandlers.paneHoldingSession(self.app, s.id, device);
        entries[i] = .{ .session = s, .open_locally = pane != null };
        var live_title: chooser_sessions.Live = .{};
        if (pane) |p| live_title = .{
            .open = true,
            .pane_title = if (p.surface.getTitle()) |t| a.dupe(u8, t) catch null else null,
            .window_title = if (p.surface.titleOverride()) |t| a.dupe(u8, t) catch null else null,
            .pane_count = 1,
        };
        var lb: [chooser_sessions.max_live_title]u8 = undefined;
        labels[i] = a.dupe(u8, chooser_sessions.label(&lb, s, live_title, null)) catch "";
    }
    self.entries = entries;
    self.labels = labels;
    self.shown = rules.displayed(&self.shown_buf, entries, labels, self.order);
    self.roster_state = .loaded;
    self.drawRoster();
    self.drawDetail();
}

fn drawRoster(self: *MachineChooser) void {
    wk.gtk_list_box_remove_all(self.session_list);
    self.session_rows.clearRetainingCapacity();
    const ph = rules.placeholder(self.roster_state, self.shown.len);
    setText(self.state_label, ph orelse "");
    wk.gtk_widget_set_visible(self.state_label, @intFromBool(ph != null));
    if (self.roster_state != .loaded) return;
    for (self.shown) |i| {
        const e = self.entries[i];
        const row = wk.adw_action_row_new();
        wk.adw_preferences_row_set_use_markup(row, 0);
        var zb: [512]u8 = undefined;
        wk.adw_preferences_row_set_title(row, (std.fmt.bufPrintZ(&zb, "{s}", .{self.labels[i]}) catch "session").ptr);
        var sb: [512]u8 = undefined;
        var szb: [513]u8 = undefined;
        const sub = rules.subline(&sb, e.session);
        wk.adw_action_row_set_subtitle(row, (std.fmt.bufPrintZ(&szb, "{s}", .{sub}) catch "").ptr);
        var ab: [16]u8 = undefined;
        const action = wk.gtk_button_new_with_label((std.fmt.bufPrintZ(&ab, "{s}", .{rules.actionLabel(e.open_locally)}) catch "Resume").ptr);
        wk.gtk_widget_set_valign(action, 3);
        setTip(action, rules.actionHelp(e.open_locally));
        const end = wk.gtk_button_new_from_icon_name("window-close-symbolic");
        wk.gtk_widget_set_valign(end, 3);
        wk.gtk_widget_add_css_class(end, "flat");
        setTip(end, chooser_help.end_session);
        wk.g_object_set_data(@ptrCast(action), "ghoztty-entry", @ptrFromInt(i + 1));
        wk.g_object_set_data(@ptrCast(end), "ghoztty-entry", @ptrFromInt(i + 1));
        _ = wk.g_signal_connect_data(action, "clicked", @ptrCast(&onSessionAction), self, null, 0);
        _ = wk.g_signal_connect_data(end, "clicked", @ptrCast(&onSessionEnd), self, null, 0);
        wk.adw_action_row_add_suffix(row, action);
        wk.adw_action_row_add_suffix(row, end);
        wk.gtk_list_box_append(self.session_list, row);
        self.session_rows.append(c_alloc, .{ .row = row, .action = action, .end = end, .entry = i }) catch break;
    }
}

fn entryOf(button: *wk.GtkWidget) ?usize {
    const t = @intFromPtr(wk.g_object_get_data(@ptrCast(button), "ghoztty-entry"));
    return if (t == 0) null else t - 1;
}

/// The displayed row for session `sid`, for the seam.
pub fn sessionRow(self: *const MachineChooser, sid: []const u8) ?SessionRow {
    for (self.session_rows.items) |r| if (std.mem.eql(u8, self.entries[r.entry].session.id, sid)) return r;
    return null;
}

pub fn click(button: *wk.GtkWidget) void {
    wk.g_signal_emit_by_name(@ptrCast(button), "clicked");
}

// ---------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------

fn onSessionEnd(button: *wk.GtkWidget, self: *MachineChooser) callconv(.c) void {
    const i = entryOf(button) orelse return;
    if (i >= self.entries.len) return;
    // End rides a roster job: the RPC, then the fresh roster.
    self.startRoster(self.entries[i].session.id);
}

fn onSessionAction(button: *wk.GtkWidget, self: *MachineChooser) callconv(.c) void {
    const i = entryOf(button) orelse return;
    if (i >= self.entries.len) return;
    const e = self.entries[i];
    const m = self.selectedMachine() orelse return;
    const device: ?[]const u8 = if (m.kind == .relay) m.id else null;
    // Show: one of our panes already holds it - never attach twice.
    if (IpcHandlers.paneHoldingSession(self.app, e.session.id, device)) |p| {
        IpcHandlers.focusPane(p);
        self.noteLast("show {s}", .{e.session.id});
        self.close();
        return;
    }
    switch (chooser_sessions.resumeTarget(if (m.kind == .relay) .{ .remote = m.id } else .local, e.session)) {
        .none => return,
        .local => |sid| {
            Surface.pending_restore = .{ .session_id = sid };
            _ = self.app.newWindowForIpc(null, null, &.{}, null, true);
            Surface.pending_restore = null;
            self.noteLast("resume {s}", .{sid});
            self.close();
        },
        .remote => |r| {
            if (self.openRelay(m, r.session)) {
                self.noteLast("resume {s}", .{r.session});
                self.close();
            }
        },
    }
}

fn onNewWindow(_: *wk.GtkWidget, self: *MachineChooser) callconv(.c) void {
    const m = self.selectedMachine() orelse return;
    switch (m.kind) {
        .local => {
            _ = self.app.newWindowForIpc(null, null, &.{}, null, true);
            self.noteLast("new-window local", .{});
            self.close();
        },
        .relay => if (self.openRelay(m, null)) {
            self.noteLast("new-window {s}", .{m.id});
            self.close();
        },
    }
}

/// Dial relay machine `m` and open a window on it: a fresh session, or an
/// ATTACH to `session`. The one remote open tail (`openWith`), so it gets
/// the per-host defaults and returns at relaunch like any relay window.
fn openRelay(self: *MachineChooser, m: rules.Machine, session: ?[]const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const token = ipc_remote_window.resolveToken(a) orelse {
        self.noteLast("{s}", .{chooser_sessions.unauthorized_text});
        return false;
    };
    const base = relay_directory.resolveBase(a) catch relay_directory.default_base;
    const machine: RemoteLink.Machine = .{ .relay = .{ .base = base, .device = m.id, .token = token, .name = m.name } };
    const dialed = RemoteLink.dial(machine) catch |err| {
        log.warn("machine chooser: dial to {s} failed err={}", .{ m.name, err });
        self.noteLast("{s}", .{chooser_sessions.stateText(rules.failureState(err)) orelse chooser_sessions.failed_text});
        return false;
    };
    const link = RemoteLink.adopt(dialed, machine) catch return false;
    _ = ipc_remote_window.openWith(self.app, .{ .link = link, .session_id = session }, true, .{});
    return true;
}

fn onHostSettings(_: *wk.GtkWidget, self: *MachineChooser) callconv(.c) void {
    const m = self.selectedMachine() orelse return;
    if (m.kind != .relay) return;
    _ = HostSettingsDialog.present(c_alloc, @ptrCast(self.parent), m.id, m.name, null, null);
}

/// Sort by `key` (a column header's click): flips the active column.
pub fn sortBy(self: *MachineChooser, key: chooser_session_sort.Key) void {
    self.order = chooser_session_sort.toggled(self.order, key);
    self.shown = rules.displayed(&self.shown_buf, self.entries, self.labels, self.order);
    self.drawRoster();
}

// ---------------------------------------------------------------------
// Reading it back (the seam)
// ---------------------------------------------------------------------

pub fn rosterState(self: *const MachineChooser) chooser_sessions.State {
    return self.roster_state;
}

pub fn rosterInflight(self: *const MachineChooser) bool {
    return self.roster_inflight;
}

pub fn machineList(self: *const MachineChooser) []const rules.Machine {
    return self.machines.items;
}

pub fn shownSessions(self: *const MachineChooser) []const usize {
    return self.shown;
}

pub fn entry(self: *const MachineChooser, i: usize) rules.Entry {
    return self.entries[i];
}

pub fn labelOf(self: *const MachineChooser, i: usize) []const u8 {
    return self.labels[i];
}

pub fn newWindowButton(self: *const MachineChooser) *wk.GtkWidget {
    return self.new_window_btn;
}

pub fn hostSettingsButton(self: *const MachineChooser) *wk.GtkWidget {
    return self.host_btn;
}

pub fn accountLabel(self: *const MachineChooser) *wk.GtkWidget {
    return self.account_label;
}

pub fn detailLabels(self: *const MachineChooser) [3]*wk.GtkWidget {
    return .{ self.detail_title, self.detail_subtitle, self.state_label };
}
