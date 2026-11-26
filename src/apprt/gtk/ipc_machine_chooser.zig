//! `machine-chooser` (T3674): the DEBUG-ONLY seam the Linux acceptance test
//! drives the machine chooser through - the headless harness has no pointer
//! and no seat. Every op goes through the chooser's own code (a button op
//! emits that button's `clicked`), and every reply is the chooser as drawn.
//!
//!   --op=open                     open it over the front window (the menu)
//!   --op=chord --key=<chord>      the window's key classifier, as a real
//!                                 key would reach it (`ctrl+shift+n`,
//!                                 `ctrl+n`, `ctrl+alt+shift+n`)
//!   --op=state                    read it back (the default)
//!   --op=select --value=<id>      select a machine (`local` or a device id)
//!   --op=new-window               click New Window
//!   --op=resume --value=<session> click that session's Resume / Show
//!   --op=end --value=<session>    click that session's End
//!   --op=host-settings            click Host Settings...
//!   --op=sort --value=name|cpu    click a column
//!   --op=close                    close it
const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const server = apprt.ipc.server;
const Request = server.Request;
const wk = @import("webkit.zig");
const MachineChooser = @import("MachineChooser.zig");
const rules = @import("machine_chooser_rules.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;

const c_alloc = std.heap.c_allocator;

pub fn seam(app: *Application, request: Request) Allocator.Error![]u8 {
    var op: []const u8 = "state";
    var value: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    for (request.arguments orelse &.{}) |arg| {
        if (std.mem.startsWith(u8, arg, "--op=")) op = arg["--op=".len..];
        if (std.mem.startsWith(u8, arg, "--value=")) value = arg["--value=".len..];
        if (std.mem.startsWith(u8, arg, "--key=")) key = arg["--key=".len..];
    }
    var did: ?bool = null;
    if (std.mem.eql(u8, op, "open")) {
        const w = IpcHandlers.frontWindowOf(app) orelse
            return server.errorResponse(c_alloc, "machine-chooser: no window to open it over", .{});
        MachineChooser.open(app, w);
        did = true;
    } else if (std.mem.eql(u8, op, "chord")) {
        const w = IpcHandlers.frontWindowOf(app) orelse
            return server.errorResponse(c_alloc, "machine-chooser: no window", .{});
        const k = key orelse return server.errorResponse(c_alloc, "--key is required for --op=chord", .{});
        const n: c_uint = 'N';
        const shift: c_uint = 1 << 0;
        const ctrl: c_uint = 1 << 2;
        const alt: c_uint = 1 << 3;
        const state: c_uint = if (std.mem.eql(u8, k, "ctrl+shift+n"))
            ctrl | shift
        else if (std.mem.eql(u8, k, "ctrl+n"))
            ctrl
        else if (std.mem.eql(u8, k, "ctrl+alt+shift+n"))
            ctrl | alt | shift
        else
            return server.errorResponse(c_alloc, "--key '{s}' is not a chord this seam knows", .{k});
        did = w.chooserChord(if (state & shift != 0) n else 'n', state);
    } else if (!std.mem.eql(u8, op, "state")) {
        const c = MachineChooser.current() orelse
            return server.errorResponse(c_alloc, "machine-chooser: the chooser is not open", .{});
        if (std.mem.eql(u8, op, "select")) {
            const id = value orelse return server.errorResponse(c_alloc, "--value is required for --op=select", .{});
            did = c.selectId(id);
        } else if (std.mem.eql(u8, op, "new-window")) {
            MachineChooser.click(c.newWindowButton());
            did = true;
        } else if (std.mem.eql(u8, op, "host-settings")) {
            const b = c.hostSettingsButton();
            did = wk.gtk_widget_get_visible(b) != 0;
            if (did.?) MachineChooser.click(b);
        } else if (std.mem.eql(u8, op, "resume") or std.mem.eql(u8, op, "end")) {
            const sid = value orelse return server.errorResponse(c_alloc, "--value is required for --op={s}", .{op});
            const row = c.sessionRow(sid) orelse
                return server.errorResponse(c_alloc, "machine-chooser: no session row '{s}'", .{sid});
            MachineChooser.click(if (std.mem.eql(u8, op, "end")) row.end else row.action);
            did = true;
        } else if (std.mem.eql(u8, op, "sort")) {
            const v = value orelse "name";
            c.sortBy(if (std.mem.eql(u8, v, "cpu")) .cpu else .name);
            did = true;
        } else if (std.mem.eql(u8, op, "close")) {
            c.close();
            did = true;
        } else return server.errorResponse(c_alloc, "machine-chooser: unknown --op '{s}'", .{op});
    }
    return writeState(did);
}

fn tip(w: *wk.GtkWidget) ?[]const u8 {
    const t = wk.gtk_widget_get_tooltip_text(w) orelse return null;
    return std.mem.sliceTo(t, 0);
}

fn text(l: *wk.GtkWidget) []const u8 {
    return std.mem.sliceTo(wk.gtk_label_get_text(l), 0);
}

fn writeState(did: ?bool) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(c_alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write(&jws, did) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(j: *std.json.Stringify, did: ?bool) !void {
    try j.beginObject();
    try j.objectField("success");
    try j.write(true);
    try j.objectField("data");
    try j.beginObject();
    if (did) |d| {
        try j.objectField("did");
        try j.write(d);
    }
    const c_opt = MachineChooser.current();
    try j.objectField("open");
    try j.write(c_opt != null);
    try j.objectField("last");
    try j.write(if (c_opt) |c| c.last() else MachineChooser.lastAction());
    if (c_opt) |c| {
        try j.objectField("account");
        try j.write(text(c.accountLabel()));
        try j.objectField("account_tooltip");
        try j.write(tip(c.accountLabel()));
        try j.objectField("machines");
        try j.beginArray();
        for (c.machineList()) |m| {
            const rt = m.rowText();
            try j.beginObject();
            try j.objectField("id");
            try j.write(m.id);
            try j.objectField("kind");
            try j.write(@tagName(m.kind));
            try j.objectField("title");
            try j.write(rt.title);
            try j.objectField("subtitle");
            try j.write(rt.subtitle);
            try j.objectField("presence");
            try j.write(@tagName(m.presence));
            try j.endObject();
        }
        try j.endArray();
        try j.objectField("selected");
        try j.write(if (c.selectedMachine()) |m| m.id else null);
        const d = c.detailLabels();
        try j.objectField("detail_title");
        try j.write(text(d[0]));
        try j.objectField("detail_subtitle");
        try j.write(text(d[1]));
        try j.objectField("new_window_tooltip");
        try j.write(tip(c.newWindowButton()));
        try j.objectField("host_settings");
        try j.write(wk.gtk_widget_get_visible(c.hostSettingsButton()) != 0);
        try j.objectField("roster_state");
        try j.write(@tagName(c.rosterState()));
        try j.objectField("roster_inflight");
        try j.write(c.rosterInflight());
        try j.objectField("placeholder");
        try j.write(if (wk.gtk_widget_get_visible(d[2]) != 0) text(d[2]) else null);
        try j.objectField("sessions");
        try j.beginArray();
        for (c.shownSessions()) |i| {
            const e = c.entry(i);
            const row = c.sessionRow(e.session.id);
            try j.beginObject();
            try j.objectField("id");
            try j.write(e.session.id);
            try j.objectField("label");
            try j.write(c.labelOf(i));
            try j.objectField("pid");
            try j.write(e.session.pid);
            try j.objectField("attached");
            try j.write(e.session.attached);
            try j.objectField("open_locally");
            try j.write(e.open_locally);
            try j.objectField("action");
            try j.write(rules.actionLabel(e.open_locally));
            if (row) |r| {
                try j.objectField("action_tooltip");
                try j.write(tip(r.action));
                try j.objectField("end_tooltip");
                try j.write(tip(r.end));
            }
            try j.endObject();
        }
        try j.endArray();
    }
    try j.endObject();
    try j.endObject();
}
