//! Settings > Remote Machines (T2686; Mac `RemoteMachinesSection`,
//! SettingsStatusSections.swift): the account line with New Remote
//! Window..., then every enrolled machine with an online / offline /
//! checking dot, its folder and shell defaults, and Host Settings....
//!
//! Read without blocking, the machine chooser's way (`seedFromCache`): the
//! rows come from the remembered directory, so opening the page touches no
//! network, and one background `DirectoryProbe` fetch confirms who is
//! online (Mac's `.task { refreshFromRelay(quiet: true) }`). Host Settings...
//! is the chooser's own editor (`HostSettingsDialog.prompt` +
//! `host_defaults.update`, keyed on the device id).
//!
//! Split from `SettingsWindow.zig` so the window file does not keep growing;
//! the words are `settings_live.zig`'s. `paint` both measures and paints
//! (`draw` false only measures), like the window's rows.
const std = @import("std");
const Allocator = std.mem.Allocator;

const SettingsWindow = @import("SettingsWindow.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const MachineChooser = @import("MachineChooser.zig");
const HostSettingsDialog = @import("HostSettingsDialog.zig");
const DirectoryProbe = @import("DirectoryProbe.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const host_defaults = @import("host_defaults.zig");
const machine_cache = @import("machine_cache.zig");
const relay_directory = @import("../../remote/relay_directory.zig");
const relay_signin = @import("../../remote/relay_signin.zig");
const live = @import("settings_live.zig");
const layout = @import("settings_window_layout.zig");
const notes_render = @import("whats_new_notes.zig");
const panel_theme = @import("panel_theme.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.settings);

const Rect = layout.Rect;
const dip = layout.dip;
const cr = notes_render.cr;
const fillRect = notes_render.fillRect;
const Hit = SettingsWindow.Hit;

/// The most rows the page lists (the chooser's cap).
const max_machines = 64;

/// Posted to the Settings window's own hwnd by a Host Settings... click, so
/// the modal editor opens from the window's pump rather than inside the
/// click (or the IPC request that made it): `pending_id` names the machine.
pub const WM_APP_HOST_SETTINGS: u32 = w32.WM_APP + 1;

pub const State = struct {
    /// Owns `email` and every machine's strings; reset by `snap`.
    arena: ?std.heap.ArenaAllocator = null,
    account: live.Account = .signed_out,
    email: ?[]const u8 = null,
    machines: []live.Machine = &.{},
    /// The rows were seeded for this showing of the page.
    snapped: bool = false,
    /// A presence fetch is out.
    fetching: bool = false,
    /// The fetch has answered at least once since the seed.
    fetched: bool = false,
    pending_id: [host_defaults.MAX_KEY_LEN]u8 = undefined,
    pending_len: usize = 0,

    pub fn deinit(self: *State) void {
        if (self.arena) |*a| a.deinit();
        self.* = .{};
    }
};

/// Seed the page from the account and the remembered directory, then ask
/// the relay who is online. Never blocks on the network.
pub fn snap(w: *SettingsWindow) void {
    const gpa = w.gpa;
    const st = &w.remote;
    if (st.arena) |*a| _ = a.reset(.retain_capacity) else st.arena = .init(gpa);
    const a = st.arena.?.allocator();
    st.snapped = true;
    st.fetched = false;
    st.machines = &.{};

    const token = IpcHandlers.resolveToken(a);
    st.email = relay_signin.signedInEmail(a);
    st.account = if (token != null)
        .signed_in
    else if (relay_signin.isConfigured(a)) .signed_out else .unconfigured;
    if (token == null) return;

    if (machine_cache.load(gpa, accountKey(st))) |cached| {
        defer cached.deinit();
        var entries = cached.value.devices;
        if (entries.len > max_machines) entries = entries[0..max_machines];
        var list: std.ArrayList(live.Machine) = .empty;
        for (entries) |e| {
            const m = machine(a, e.id, e.name, .checking) orelse continue;
            list.append(a, m) catch break;
        }
        st.machines = list.items;
        log.info("settings remote machines: seeded {d} machine(s) from cache", .{st.machines.len});
    }

    if (st.fetching) return;
    const msg_hwnd = w.app.msg_hwnd orelse return;
    const base = relay_directory.resolveBase(a) catch relay_directory.default_base;
    if (DirectoryProbe.start(gpa, msg_hwnd, DirectoryProbe.settings_id, base, token, accountKey(st), true)) {
        st.fetching = true;
    }
}

fn accountKey(st: *const State) []const u8 {
    return st.email orelse "";
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

/// GUI thread: the presence fetch landed (routed here from
/// `MachineChooser.onDevices`, which has already refreshed the cache).
/// Returns true when the rows changed.
pub fn adopt(w: *SettingsWindow, res: *DirectoryProbe.Result) bool {
    const st = &w.remote;
    st.fetching = false;
    if (!st.snapped or st.arena == null) return false;
    if (!machine_cache.accountMatches(res.account, accountKey(st))) {
        log.info("settings remote machines: dropped a reply for another account", .{});
        return false;
    }
    if (res.unauthorized()) {
        // The credential is dead: the remembered rows are no longer the
        // user's to see (Mac's `clearRelayMachines`).
        st.machines = &.{};
        st.fetched = true;
        return true;
    }
    if (res.parsed == null) {
        log.info("settings remote machines: presence fetch failed err={?}", .{res.err});
        return false;
    }
    const a = st.arena.?.allocator();
    var devs = res.devices();
    if (devs.len > max_machines) devs = devs[0..max_machines];
    var list: std.ArrayList(live.Machine) = .empty;
    for (devs) |d| {
        const m = machine(a, d.id, d.name, if (d.online) .online else .offline) orelse continue;
        list.append(a, m) catch break;
    }
    st.machines = list.items;
    st.fetched = true;
    log.info("settings remote machines: presence for {d} machine(s)", .{st.machines.len});
    return true;
}

/// New Remote Window...: the machine chooser, on the focused terminal
/// window (the chooser is per-window), else the first one.
pub fn newRemoteWindow(w: *SettingsWindow) void {
    const app = w.app;
    const win: ?*Window = if (app.core_app.focusedSurface()) |s|
        s.rt_surface.parent_window
    else if (app.windows.items.len > 0)
        app.windows.items[0]
    else
        null;
    const target = win orelse {
        log.info("settings remote machines: New Remote Window with no terminal window open", .{});
        return;
    };
    if (target.hwnd) |h| _ = w32.SetForegroundWindow(h);
    MachineChooser.open(target);
}

/// Host Settings...'s click: remember which machine and open the editor
/// from the window's own pump.
pub fn requestHostSettings(w: *SettingsWindow, id: []const u8) void {
    const st = &w.remote;
    if (id.len == 0 or id.len > st.pending_id.len) return;
    @memcpy(st.pending_id[0..id.len], id);
    st.pending_len = id.len;
    _ = w32.PostMessageW(w.hwnd, WM_APP_HOST_SETTINGS, 0, 0);
}

/// The posted half: the chooser's editor over this machine's defaults.
pub fn runHostSettings(w: *SettingsWindow) void {
    const st = &w.remote;
    if (st.pending_len == 0) return;
    var id_buf: [host_defaults.MAX_KEY_LEN]u8 = undefined;
    const id = id_buf[0..st.pending_len];
    @memcpy(id, st.pending_id[0..st.pending_len]);
    st.pending_len = 0;

    // The dialog pumps messages - a fetch landing under it rebuilds the rows -
    // so the name is copied out first (`MachineChooser.promptHostSettings`).
    var name_buf: [128]u8 = undefined;
    const name: []const u8 = for (st.machines) |m| {
        if (!std.mem.eql(u8, m.id, id)) continue;
        const n = @min(m.name.len, name_buf.len);
        @memcpy(name_buf[0..n], m.name[0..n]);
        break name_buf[0..n];
    } else return;

    const app = w.app;
    var current: host_defaults.Resolved = .{};
    host_defaults.lookup(w.gpa, .{ .relay = id }, &current);
    var wd_buf: [host_defaults.MAX_VALUE_LEN]u8 = undefined;
    var shell_buf: [host_defaults.MAX_VALUE_LEN]u8 = undefined;
    const answer = HostSettingsDialog.prompt(app, w.hwnd, w.scale, w.hwnd, name, .{
        .working_directory = current.workingDirectory(),
        .shell = current.shell(),
    }, &wd_buf, &shell_buf) orelse return;
    // The dialog ran its own loop; the Settings window may have closed.
    const self = SettingsWindow.current() orelse return;
    if (self != w) return;
    host_defaults.update(w.gpa, .{ .relay = id }, .{
        .working_directory = answer.working_directory,
        .shell = answer.shell,
    });
    // Mac bumps `settingsRevision` to re-read the store.
    if (st.arena) |*ar| for (st.machines) |*m| {
        if (std.mem.eql(u8, m.id, id)) readDefaults(ar.allocator(), m);
    };
    log.info("settings remote machines: host settings saved for {s}", .{id});
}

/// A bordered button whose right edge is `right`, centred on `band`.
fn button(w: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, right: i32, top: i32, band: i32, label: []const u8, kind: Hit.Kind, key: []const u8, index: usize, draw: bool) i32 {
    const fh = layout.px(dip.field_h, w.scale);
    const pad = layout.px(dip.filter_pad_x, w.scale);
    const tw = w.text.measure(hdc, label, .{}, .caption).cx;
    const bw = tw + 2 * pad;
    const r: Rect = .{ .x = right - bw, .y = top + @divTrunc(band - fh, 2), .w = bw, .h = fh };
    if (draw) {
        SettingsWindow.roundRect(hdc, r, layout.px(dip.radius, w.scale), cr(p.field), cr(p.boundary), w.hair());
        const ch = w.text.lineHeight(.caption);
        _ = w.text.drawText(hdc, r.x + pad, r.y + @divTrunc(fh - ch, 2), label, .{}, .caption, cr(p.text), true);
        w.hit(.{ .rect = r, .kind = kind, .key = key, .index = index });
    }
    return bw;
}

/// The checking dot: amber (Mac's yellow), the panel's good green, or
/// secondary grey for offline.
fn dotColor(p: panel_theme.Panel, presence: live.Presence) u32 {
    return switch (presence) {
        .online => cr(p.good),
        .offline => cr(p.secondary),
        .checking => w32.RGB(0xE0, 0xA8, 0x00),
    };
}

/// The section. Returns its height.
pub fn paint(w: *SettingsWindow, hdc: w32.HDC, p: panel_theme.Panel, y: i32, draw: bool) i32 {
    const st = &w.remote;
    const f = w.frame();
    const g = layout.px(dip.gap, w.scale);
    const t = layout.px(dip.tight, w.scale);
    const pad_y = layout.px(dip.row_pad_y, w.scale);
    const lh = w.text.lineHeight(.body);
    const ch = w.text.lineHeight(.caption);
    const cols = layout.rowColumns(w.scale, f.list, f.scrollbar.w, y + pad_y, lh, dip.field_w);
    const width = cols.right - cols.left;
    const block = lh + t + ch;
    var cy = y + pad_y;

    // The account, with New Remote Window... trailing.
    {
        var tb: [160]u8 = undefined;
        const bw = button(w, hdc, p, cols.right, cy, block, "New Remote Window\u{2026}", .new_remote_window, "", 0, draw);
        if (draw) {
            const room = @max(0, width - bw - 2 * g);
            w.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy, .w = room, .h = lh }, live.accountTitle(&tb, st.account, st.email), .{}, .body, cr(p.text), false);
            w.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy + lh + t, .w = room, .h = ch }, live.accountCaption(st.account), .{}, .caption, cr(p.secondary), false);
        }
        cy += block;
    }

    if (st.machines.len > 0) {
        cy += g;
        if (draw) fillRect(hdc, .{ .x = cols.left, .y = cy, .w = width, .h = w.hair() }, cr(p.divider));
        cy += w.hair() + g;
        const d = layout.px(dip.dot, w.scale);
        for (st.machines, 0..) |m, i| {
            if (i > 0) cy += g;
            var capb: [2 * host_defaults.MAX_VALUE_LEN + 64]u8 = undefined;
            const bw = button(w, hdc, p, cols.right, cy, block, "Host Settings\u{2026}", .host_settings, m.id, i, draw);
            if (draw) {
                const room = @max(0, width - bw - 2 * g);
                SettingsWindow.roundRect(hdc, .{ .x = cols.left, .y = cy + @divTrunc(lh - d, 2), .w = d, .h = d }, @divTrunc(d, 2), dotColor(p, m.presence), null, 1);
                const nx = cols.left + d + g;
                w.text.drawEllipsized(hdc, .{ .x = nx, .y = cy, .w = @max(0, room - d - g), .h = lh }, m.name, .{}, .body, cr(p.text), false);
                w.text.drawEllipsized(hdc, .{ .x = cols.left, .y = cy + lh + t, .w = room, .h = ch }, live.machineCaption(&capb, m), .{}, .caption, cr(p.secondary), false);
            }
            cy += block;
        }
    }

    cy += pad_y + g;
    if (draw) fillRect(hdc, .{ .x = cols.left, .y = cy - w.hair(), .w = width, .h = w.hair() }, cr(p.divider));
    return cy - y;
}
