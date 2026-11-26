//! The live sections of the GTK Settings window (T3635, Linux L11g6): what
//! Sessions & Agent says about the session agent, and Remote Machines - Mac
//! `AgentStatusSection` / `RemoteMachinesSection`
//! (SettingsStatusSections.swift), win32 `settings_live.zig` +
//! `settings_remote_view.zig`. The words are win32's pure `settings_live`,
//! shared, so the three seats say the same thing.
//!
//! **Sessions & Agent** reads the agent WITHOUT spawning it (Mac
//! `AgentStatusModel.refresh`): the info file's pid and a liveness check
//! (`LocalAgent.liveStatus`), then the build the SHARED connection already
//! shook hands with. Showing the page never dials, never starts an agent and
//! never runs `ghoztty-agent --version` - the bundled build is shown only once
//! something else (the launch's upgrade check) has probed it. Re-read every
//! time the page is shown, as Mac's `.onAppear`. Rows: Status (with the
//! green / grey dot), Running build (stale suffix when the bundled build is
//! newer), This app's agent, Socket (Mac's label; `~` for home).
//!
//! **Remote Machines** is the account line, then one row per enrolled machine
//! with its presence dot, its folder and shell defaults, and Host
//! Settings... (`HostSettingsDialog`, the chooser's editor). Read without
//! blocking, the chooser's way: rows come from the remembered directory
//! (`machine_cache`), so showing the page touches no network; one background
//! fetch (a worker thread: the account's token, then the relay's device list)
//! confirms who is online, and a 401 empties the list and the cache (Mac's
//! `clearRelayMachines`). Mac's "New Remote Window..." button sits on the
//! account row and opens the machine chooser (`MachineChooser.zig`, T3674).
const SettingsLive = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const wk = @import("webkit.zig");

const live = @import("../win32/settings_live.zig");
const host_defaults = @import("../win32/host_defaults.zig");
const machine_cache = @import("../win32/machine_cache.zig");
const relay_directory = @import("../../remote/relay_directory.zig");
const relay_signin = @import("../../remote/relay_signin.zig");
const relay_account = @import("../../remote/relay_account.zig");
const ipc_remote_window = @import("ipc_remote_window.zig");
const HostSettingsDialog = @import("HostSettingsDialog.zig");
const SettingsWindow = @import("SettingsWindow.zig");

const log = std.log.scoped(.gtk_settings);

/// The most rows the page lists (win32's cap).
const max_machines = 64;

pub const caption = "The agent keeps your shells alive when the app quits or restarts.";

// ---- Sessions & Agent ----------------------------------------------------

agent: live.Agent = .{},
socket: []const u8 = "",
socket_buf: [512]u8 = undefined,
socket_shown_buf: [512]u8 = undefined,
build_buf: [128]u8 = undefined,
agent_rows: ?AgentRows = null,

// ---- Remote Machines -----------------------------------------------------

/// Owns `email` and every machine's strings; reset by `snap`.
arena: ?std.heap.ArenaAllocator = null,
account: live.Account = .signed_out,
email: ?[]const u8 = null,
machines: []live.Machine = &.{},
/// The rows were seeded at least once.
snapped: bool = false,
/// A presence fetch is out.
fetching: bool = false,
/// The fetch has answered since the last seed.
fetched: bool = false,
/// Which snap a fetch belongs to: a reply for an older one (or another
/// window) is dropped.
gen: u64 = 0,
remote_group: ?*wk.GtkWidget = null,
account_row: ?*wk.GtkWidget = null,
/// "New Remote Window..." on the account row (T3674).
new_remote_button: ?*wk.GtkWidget = null,
machine_rows: std.ArrayListUnmanaged(MachineRow) = .empty,

const AgentRows = struct {
    status: *wk.GtkWidget,
    status_dot: *wk.GtkWidget,
    status_value: *wk.GtkWidget,
    running_build: *wk.GtkWidget,
    running_build_value: *wk.GtkWidget,
    bundled: *wk.GtkWidget,
    bundled_value: *wk.GtkWidget,
    socket: *wk.GtkWidget,
    socket_value: *wk.GtkWidget,
};

pub const MachineRow = struct { row: *wk.GtkWidget, dot: *wk.GtkWidget, button: *wk.GtkWidget };

var next_gen: u64 = 1;

pub fn deinit(self: *SettingsLive, gpa: Allocator) void {
    if (HostSettingsDialog.current()) |d| d.close();
    self.machine_rows.deinit(gpa);
    if (self.arena) |*a| a.deinit();
    self.* = .{};
}

// ---------------------------------------------------------------------
// Building (once, from SettingsWindow.addCustom)
// ---------------------------------------------------------------------

fn valueLabel(mono: bool) *wk.GtkWidget {
    const l = wk.gtk_label_new(null);
    wk.gtk_label_set_selectable(l, 1);
    wk.gtk_label_set_xalign(l, 1.0);
    wk.gtk_label_set_ellipsize(l, 1); // start: a long path keeps its tail
    if (mono) wk.gtk_widget_add_css_class(l, "monospace");
    return l;
}

fn labelledRow(group: *wk.GtkWidget, title: [:0]const u8, value: *wk.GtkWidget) *wk.GtkWidget {
    const row = wk.adw_action_row_new();
    wk.adw_preferences_row_set_use_markup(row, 0);
    wk.adw_preferences_row_set_title(row, title.ptr);
    wk.gtk_widget_set_valign(value, 3);
    wk.adw_action_row_add_suffix(row, value);
    wk.adw_preferences_group_add(group, row);
    return row;
}

fn dotLabel() *wk.GtkWidget {
    const d = wk.gtk_label_new("\u{25CF}");
    wk.gtk_widget_set_valign(d, 3);
    return d;
}

/// The Agent group's rows, under the curated Session persistence rows.
pub fn buildAgent(self: *SettingsLive, group: *wk.GtkWidget) void {
    wk.adw_preferences_group_set_description(group, caption);
    const status_box = wk.gtk_box_new(0, 6);
    const dot = dotLabel();
    const status_value = valueLabel(false);
    wk.gtk_label_set_selectable(status_value, 0);
    wk.gtk_box_append(status_box, dot);
    wk.gtk_box_append(status_box, status_value);
    const rb = valueLabel(true);
    const bb = valueLabel(true);
    const sv = valueLabel(true);
    self.agent_rows = .{
        .status = labelledRow(group, "Status", status_box),
        .status_dot = dot,
        .status_value = status_value,
        .running_build = labelledRow(group, "Running build", rb),
        .running_build_value = rb,
        .bundled = labelledRow(group, "This app\u{2019}s agent", bb),
        .bundled_value = bb,
        .socket = labelledRow(group, "Socket", sv),
        .socket_value = sv,
    };
}

/// The Remote Machines group: the account row now, machine rows per snap.
pub fn buildRemote(self: *SettingsLive, group: *wk.GtkWidget) void {
    self.remote_group = group;
    const row = wk.adw_action_row_new();
    wk.adw_preferences_row_set_use_markup(row, 0);
    wk.adw_preferences_row_set_title(row, "Not signed in");
    // Mac's "New Remote Window..." beside the account (T3674): the chooser,
    // over the front terminal window (win32 `settings_remote_view`).
    const button = wk.gtk_button_new_with_label("New Remote Window\u{2026}");
    wk.gtk_widget_set_valign(button, 3);
    _ = wk.g_signal_connect_data(button, "clicked", @ptrCast(&onNewRemoteWindow), null, null, 0);
    wk.adw_action_row_add_suffix(row, button);
    self.new_remote_button = button;
    wk.adw_preferences_group_add(group, row);
    self.account_row = row;
}

fn onNewRemoteWindow(_: *wk.GtkWidget, _: ?*anyopaque) callconv(.c) void {
    const w = SettingsWindow.current() orelse return;
    const front = @import("IpcHandlers.zig").frontWindowOf(w.app) orelse return;
    @import("MachineChooser.zig").open(w.app, front);
}

// ---------------------------------------------------------------------
// Showing a page
// ---------------------------------------------------------------------

/// A page was shown (Mac's `.onAppear` / `.task`).
pub fn shown(self: *SettingsLive, w: *SettingsWindow, id: SettingsWindow.PageId) void {
    switch (id) {
        .session => self.refreshAgent(w),
        .remote => self.snap(w),
        else => {},
    }
}

/// Take the agent snapshot and draw it (win32 `snapLive`).
pub fn refreshAgent(self: *SettingsLive, w: *SettingsWindow) void {
    const la = &w.app.rt().local_agent;
    var a: live.Agent = .{ .bundled_build = la.bundledVersionIfProbed() };
    self.socket = "";
    if (la.liveStatus(&self.socket_buf)) |st| {
        a.running = true;
        a.pid = st.pid;
        self.socket = st.socket;
        if (la.runningVersion()) |v| {
            const n = @min(v.len, self.build_buf.len);
            @memcpy(self.build_buf[0..n], v[0..n]);
            a.running_build = self.build_buf[0..n];
        }
    }
    // Mac names the socket even with no agent running: where it will be.
    if (self.socket.len == 0) self.socket = la.expectedSocket(&self.socket_buf);
    a.pipe = self.socket;
    self.agent = a;
    self.drawAgent();
    log.info("settings agent: running={} pid={d} build={?s} bundled={?s}", .{ a.running, a.pid, a.running_build, a.bundled_build });
}

fn setLabel(label: *wk.GtkWidget, text: []const u8) void {
    var zb: [1200]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{text}) catch return;
    wk.gtk_label_set_text(label, z.ptr);
}

fn setDot(dot: *wk.GtkWidget, class: [*:0]const u8) void {
    inline for (.{ "success", "warning", "dim-label" }) |c| wk.gtk_widget_remove_css_class(dot, c);
    wk.gtk_widget_add_css_class(dot, class);
}

fn drawAgent(self: *SettingsLive) void {
    const r = self.agent_rows orelse return;
    const a = self.agent;
    var b1: [96]u8 = undefined;
    var b2: [200]u8 = undefined;
    setLabel(r.status_value, live.statusLine(&b1, a));
    setDot(r.status_dot, if (a.running) "success" else "dim-label");
    if (live.runningBuildLine(&b2, a)) |rb| setLabel(r.running_build_value, rb);
    wk.gtk_widget_set_visible(r.running_build, @intFromBool(a.running_build != null));
    if (a.bundled_build) |bb| setLabel(r.bundled_value, bb);
    wk.gtk_widget_set_visible(r.bundled, @intFromBool(a.bundled_build != null));
    setLabel(r.socket_value, live.tildePath(&self.socket_shown_buf, self.socket, std.posix.getenv("HOME")));
}

/// Seed the rows from the account and the remembered directory, then ask
/// the relay who is online on a worker. Never blocks on the network.
pub fn snap(self: *SettingsLive, w: *SettingsWindow) void {
    const gpa = w.gpa;
    if (self.arena) |*a| _ = a.reset(.retain_capacity) else self.arena = .init(gpa);
    const a = self.arena.?.allocator();
    self.snapped = true;
    self.fetched = false;
    self.machines = &.{};
    self.gen = next_gen;
    next_gen += 1;

    // The account, from local state only: a stored sign-in or the
    // environment's token. The token itself (which may need a renewal round
    // trip) is resolved on the worker.
    self.email = relay_signin.signedInEmail(a);
    const signed_in = blk: {
        const path = relay_account.accountPath(a) catch break :blk false;
        if (relay_account.isSignedIn(a, path)) break :blk true;
        const tok = std.posix.getenv("GHOSTTY_RELAY_TOKEN") orelse break :blk false;
        break :blk tok.len > 0;
    };
    self.account = if (signed_in)
        .signed_in
    else if (relay_signin.isConfigured(a)) .signed_out else .unconfigured;

    if (signed_in) {
        if (machine_cache.load(gpa, self.accountKey())) |cached| {
            defer cached.deinit();
            var entries = cached.value.devices;
            if (entries.len > max_machines) entries = entries[0..max_machines];
            var list: std.ArrayList(live.Machine) = .empty;
            for (entries) |e| {
                const m = machine(a, e.id, e.name, .checking) orelse continue;
                list.append(a, m) catch break;
            }
            self.machines = list.items;
            log.info("settings remote machines: seeded {d} machine(s) from cache", .{self.machines.len});
        }
        self.startFetch(gpa);
    }
    self.drawRemote(w);
}

fn accountKey(self: *const SettingsLive) []const u8 {
    return self.email orelse "";
}

/// One row, its strings copied into `a`, its host defaults read.
fn machine(a: Allocator, id: []const u8, name: []const u8, presence: live.Presence) ?live.Machine {
    var m: live.Machine = .{
        .id = a.dupe(u8, id) catch return null,
        .name = a.dupe(u8, name) catch return null,
        .presence = presence,
    };
    readDefaults(a, &m);
    return m;
}

fn readDefaults(a: Allocator, m: *live.Machine) void {
    var r: host_defaults.Resolved = .{};
    host_defaults.lookup(a, .{ .relay = m.id }, &r);
    m.working_directory = if (r.workingDirectory()) |v| a.dupe(u8, v) catch null else null;
    m.shell = if (r.shell()) |v| a.dupe(u8, v) catch null else null;
}

fn drawRemote(self: *SettingsLive, w: *SettingsWindow) void {
    const group = self.remote_group orelse return;
    if (self.account_row) |row| {
        var tb: [200]u8 = undefined;
        var zb: [200]u8 = undefined;
        const t = live.accountTitle(&tb, self.account, self.email);
        const z = std.fmt.bufPrintZ(&zb, "{s}", .{t}) catch "Signed in";
        wk.adw_preferences_row_set_title(row, z.ptr);
        var sb: [200]u8 = undefined;
        const s = std.fmt.bufPrintZ(&sb, "{s}", .{live.accountCaption(self.account)}) catch "";
        wk.adw_action_row_set_subtitle(row, s.ptr);
    }
    // The machine rows are rebuilt: their count changes with the fetch.
    for (self.machine_rows.items) |mr| wk.adw_preferences_group_remove(group, mr.row);
    self.machine_rows.clearRetainingCapacity();
    for (self.machines, 0..) |m, i| {
        const row = wk.adw_action_row_new();
        wk.adw_preferences_row_set_use_markup(row, 0);
        var nb: [256]u8 = undefined;
        const nz = std.fmt.bufPrintZ(&nb, "{s}", .{m.name}) catch "?";
        wk.adw_preferences_row_set_title(row, nz.ptr);
        var cb: [2 * host_defaults.MAX_VALUE_LEN + 64]u8 = undefined;
        var cz: [2 * host_defaults.MAX_VALUE_LEN + 65]u8 = undefined;
        const c = std.fmt.bufPrintZ(&cz, "{s}", .{live.machineCaption(&cb, m)}) catch "";
        wk.adw_action_row_set_subtitle(row, c.ptr);
        const dot = dotLabel();
        setDot(dot, switch (m.presence) {
            .online => "success",
            .offline => "dim-label",
            .checking => "warning",
        });
        wk.adw_action_row_add_prefix(row, dot);
        const button = wk.gtk_button_new_with_label("Host Settings\u{2026}");
        wk.gtk_widget_set_valign(button, 3);
        wk.g_object_set_data(@ptrCast(button), "ghoztty-machine", @ptrFromInt(i + 1));
        _ = wk.g_signal_connect_data(button, "clicked", @ptrCast(&onHostSettingsClicked), w, null, 0);
        wk.adw_action_row_add_suffix(row, button);
        wk.adw_preferences_group_add(group, row);
        self.machine_rows.append(w.gpa, .{ .row = row, .dot = dot, .button = button }) catch break;
    }
}

// ---------------------------------------------------------------------
// The presence fetch (a worker thread)
// ---------------------------------------------------------------------

const Outcome = enum { ok, unauthorized, failed };

const Job = struct {
    arena: std.heap.ArenaAllocator,
    gen: u64,
    account: []const u8,
    outcome: Outcome = .failed,
    err: ?anyerror = null,
    devices: []const relay_directory.Device = &.{},
};

fn startFetch(self: *SettingsLive, gpa: Allocator) void {
    _ = gpa;
    if (self.fetching) return;
    // The worker's own allocator: c_allocator is thread-safe and outlives a
    // closed window.
    const job = std.heap.c_allocator.create(Job) catch return;
    job.* = .{ .arena = .init(std.heap.c_allocator), .gen = self.gen, .account = "" };
    job.account = job.arena.allocator().dupe(u8, self.accountKey()) catch "";
    const t = std.Thread.spawn(.{}, run, .{job}) catch |err| {
        log.warn("settings remote machines: no fetch worker err={}", .{err});
        job.arena.deinit();
        std.heap.c_allocator.destroy(job);
        return;
    };
    t.detach();
    self.fetching = true;
}

fn run(job: *Job) void {
    defer _ = wk.g_idle_add(&onFetched, job);
    const a = job.arena.allocator();
    const token = ipc_remote_window.resolveToken(a) orelse {
        job.err = error.NoToken;
        return;
    };
    const base = relay_directory.resolveBase(a) catch relay_directory.default_base;
    const parsed = relay_directory.listDevices(a, base, token) catch |err| {
        job.err = err;
        if (err == error.Unauthorized) {
            job.outcome = .unauthorized;
            // The credential is dead: so is the list it produced.
            machine_cache.clear(a);
        }
        return;
    };
    job.devices = parsed.value.devices;
    job.outcome = .ok;
    var entries: std.ArrayList(machine_cache.Entry) = .empty;
    for (job.devices) |d| entries.append(a, .{ .id = d.id, .name = d.name, .hostname = d.hostname }) catch break;
    machine_cache.save(a, job.account, entries.items);
}

/// GUI thread: the fetch landed.
fn onFetched(ud: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(ud orelse return 0));
    defer {
        job.arena.deinit();
        std.heap.c_allocator.destroy(job);
    }
    const w = SettingsWindow.current() orelse return 0;
    w.live.adopt(w, job);
    return 0;
}

fn adopt(self: *SettingsLive, w: *SettingsWindow, job: *Job) void {
    if (job.gen != self.gen) {
        log.info("settings remote machines: dropped a reply for an older showing", .{});
        return;
    }
    self.fetching = false;
    const a = (self.arena orelse return).allocator();
    switch (job.outcome) {
        .unauthorized => {
            self.machines = &.{};
            self.fetched = true;
            log.info("settings remote machines: the relay refused the credential; list cleared", .{});
        },
        .failed => {
            log.info("settings remote machines: presence fetch failed err={?}", .{job.err});
            return;
        },
        .ok => {
            var devs = job.devices;
            if (devs.len > max_machines) devs = devs[0..max_machines];
            var list: std.ArrayList(live.Machine) = .empty;
            for (devs) |d| {
                const m = machine(a, d.id, d.name, if (d.online) .online else .offline) orelse continue;
                list.append(a, m) catch break;
            }
            self.machines = list.items;
            self.fetched = true;
            log.info("settings remote machines: presence for {d} machine(s)", .{self.machines.len});
        },
    }
    self.drawRemote(w);
}

// ---------------------------------------------------------------------
// Host Settings...
// ---------------------------------------------------------------------

/// Host Settings...'s click on the i-th machine row.
pub fn openHostSettings(self: *SettingsLive, w: *SettingsWindow, index: usize) bool {
    if (index >= self.machines.len) return false;
    const m = self.machines[index];
    return HostSettingsDialog.present(w.gpa, w.window, m.id, m.name, &onHostSaved, w);
}

/// Index of the machine row whose id is `id`.
pub fn indexOf(self: *const SettingsLive, id: []const u8) ?usize {
    for (self.machines, 0..) |m, i| if (std.mem.eql(u8, m.id, id)) return i;
    return null;
}

/// The editor saved: re-read that machine's defaults (Mac bumps
/// `settingsRevision`).
fn onHostSaved(ctx: ?*anyopaque, id: []const u8) void {
    const w: *SettingsWindow = @ptrCast(@alignCast(ctx orelse return));
    if (SettingsWindow.current() != w) return;
    const self = &w.live;
    const ar = &(self.arena orelse return);
    for (self.machines) |*m| if (std.mem.eql(u8, m.id, id)) readDefaults(ar.allocator(), m);
    self.drawRemote(w);
}

fn onHostSettingsClicked(button: *wk.GtkWidget, w: *SettingsWindow) callconv(.c) void {
    const t = @intFromPtr(wk.g_object_get_data(@ptrCast(button), "ghoztty-machine"));
    if (t == 0) return;
    _ = w.live.openHostSettings(w, t - 1);
}

/// Click the account row's New Remote Window... (the seam, T3674).
pub fn clickNewRemoteWindow(self: *SettingsLive) bool {
    const b = self.new_remote_button orelse return false;
    wk.g_signal_emit_by_name(@ptrCast(b), "clicked");
    return true;
}

/// Click the i-th row's Host Settings... (the seam).
pub fn clickHostSettings(self: *SettingsLive, index: usize) bool {
    if (index >= self.machine_rows.items.len) return false;
    wk.g_signal_emit_by_name(@ptrCast(self.machine_rows.items[index].button), "clicked");
    return true;
}
