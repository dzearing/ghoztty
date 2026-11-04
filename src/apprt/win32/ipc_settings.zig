//! The `settings` IPC action (T2675): open the Settings window, drive its
//! search, page, filter, fields, Reset and value chips, and read back the
//! rows it paints - the seam `test/win32/settings-window.ps1` is built on.
//!
//! Debug builds only, like `shortcut-guide`: the CLI verb list is a
//! cross-platform surface (T141) and this is instrumentation with one
//! consumer. Every op calls the same function a click or a key calls
//! (`beginEdit` + `commitEdit` is exactly what clicking a field, typing and
//! pressing Enter does), so the seam exercises the window's own paths.
//!
//! ```
//! {"action":"settings","arguments":["--op=action"]}      (performs open_config)
//! {"action":"settings","arguments":["--op=open"]}
//! {"action":"settings","arguments":["--op=state","--query=font"]}
//! {"action":"settings","arguments":["--op=state","--filter=changed"]}
//! {"action":"settings","arguments":["--op=set","--key=font-size","--value=15"]}
//! {"action":"settings","arguments":["--op=add","--key=font-family","--value=Consolas"]}
//! {"action":"settings","arguments":["--op=remove","--key=font-family","--index=0"]}
//! {"action":"settings","arguments":["--op=reset","--key=font-size"]}
//! {"action":"settings","arguments":["--op=doc","--key=font-size"]}
//! {"action":"settings","arguments":["--op=shot","--path=C:\\t\\s.png"]}
//! {"action":"settings","arguments":["--op=close"]}
//!   -> {"success":true,"data":{"open":true,"page":"advanced","filter":"all",
//!        "query":"","searching":false,"total":190,"matched":190,
//!        "file":"...\\config-debug.ghostty","editing":null,"doc":null,
//!        "rows":[{"key":"font-size","value":"15","modified":true,
//!                 "set_in_file":true,"repeatable":false,"readonly":false,
//!                 "override":null,"problem":null,"values":["..."]}, ...]}}
//! ```
const std = @import("std");
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const App = @import("App.zig");
const ipc_capture = @import("ipc_capture.zig");
const SettingsWindow = @import("SettingsWindow.zig");

const errorResponse = ipc_capture.errorResponse;

pub const enabled = build_config.is_debug;

pub const Op = enum { action, open, close, state, set, add, remove, reset, doc, escape, shot };

pub const Request = struct {
    op: Op,
    query: ?[]const u8 = null,
    filter: ?SettingsWindow.Filter = null,
    page: ?SettingsWindow.PageId = null,
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    index: ?usize = null,
    path: ?[]const u8 = null,
};

pub const ParseError = error{ MissingOp, BadOp, BadFilter, BadPage, BadNumber };

pub fn parse(arguments: ?[]const []const u8) ParseError!Request {
    var req: Request = .{ .op = .state };
    var have_op = false;
    if (arguments) |args| for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--op=")) {
            req.op = std.meta.stringToEnum(Op, arg["--op=".len..]) orelse return error.BadOp;
            have_op = true;
        } else if (std.mem.startsWith(u8, arg, "--query=")) {
            req.query = arg["--query=".len..];
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            req.filter = std.meta.stringToEnum(SettingsWindow.Filter, arg["--filter=".len..]) orelse return error.BadFilter;
        } else if (std.mem.startsWith(u8, arg, "--page=")) {
            req.page = std.meta.stringToEnum(SettingsWindow.PageId, arg["--page=".len..]) orelse return error.BadPage;
        } else if (std.mem.startsWith(u8, arg, "--key=")) {
            req.key = arg["--key=".len..];
        } else if (std.mem.startsWith(u8, arg, "--value=")) {
            req.value = arg["--value=".len..];
        } else if (std.mem.startsWith(u8, arg, "--index=")) {
            req.index = std.fmt.parseInt(usize, arg["--index=".len..], 10) catch return error.BadNumber;
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            req.path = arg["--path=".len..];
        }
    };
    if (!have_op) return error.MissingOp;
    return req;
}

pub fn handle(app: *App, alloc: Allocator, arguments: ?[]const []const u8) Allocator.Error![]u8 {
    const req = parse(arguments) catch |err| return switch (err) {
        error.MissingOp => errorResponse(alloc, "--op=action|open|close|state|set|add|remove|reset|doc|escape|shot is required", .{}),
        error.BadOp => errorResponse(alloc, "--op must be action, open, close, state, set, add, remove, reset, doc, escape or shot", .{}),
        error.BadFilter => errorResponse(alloc, "--filter must be all or changed", .{}),
        error.BadPage => errorResponse(alloc, "--page must name a Settings page", .{}),
        error.BadNumber => errorResponse(alloc, "--index must be a non-negative integer", .{}),
    };

    switch (req.op) {
        // The real action, exactly as Ctrl+, / the menu item fire it.
        .action => _ = app.performAction(.app, .open_config, {}) catch |err|
            return errorResponse(alloc, "open_config failed ({s})", .{@errorName(err)}),
        .open => SettingsWindow.open(app, if (app.windows.items.len > 0) app.windows.items[0] else null),
        .close => {
            SettingsWindow.closeAll();
            return try stateResponse(alloc, null, null);
        },
        else => {},
    }
    const w = SettingsWindow.current() orelse
        return errorResponse(alloc, "the Settings window is not open", .{});

    if (req.page) |pg| w.setPage(pg);
    if (req.filter) |f| w.setFilter(f);
    if (req.query) |q| w.setQuery(q);

    var ok: ?bool = null;
    switch (req.op) {
        .set, .add => {
            const key = req.key orelse return errorResponse(alloc, "--key is required for --op={s}", .{@tagName(req.op)});
            const value = req.value orelse return errorResponse(alloc, "--value is required for --op={s}", .{@tagName(req.op)});
            if (!w.beginEdit(key)) {
                ok = false;
            } else {
                w.setFieldText(value);
                w.commitEdit();
                ok = w.editingKey() == null and w.model.problem(key) == null;
            }
        },
        .remove => {
            const key = req.key orelse return errorResponse(alloc, "--key is required for --op=remove", .{});
            ok = w.removeValue(key, req.index orelse 0);
        },
        .reset => {
            const key = req.key orelse return errorResponse(alloc, "--key is required for --op=reset", .{});
            ok = w.resetKey(key);
        },
        .doc => {
            const key = req.key orelse return errorResponse(alloc, "--key is required for --op=doc", .{});
            w.toggleDoc(key);
        },
        .escape => {
            // Esc, as the window handles it: field, then search, then close.
            if (w.editingKey() != null) w.cancelEdit() else if (w.search.len > 0) w.setQuery("") else {
                SettingsWindow.closeAll();
                return try stateResponse(alloc, null, null);
            }
        },
        .shot => {
            const path = req.path orelse return errorResponse(alloc, "--path=<file.png> is required for --op=shot", .{});
            w.snapshot(alloc, path) catch |err| return errorResponse(alloc, "shot failed ({s})", .{@errorName(err)});
        },
        else => {},
    }
    return try stateResponse(alloc, SettingsWindow.current(), ok);
}

fn stateResponse(alloc: Allocator, w_opt: ?*SettingsWindow, ok: ?bool) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    writeState(&jws, alloc, w_opt, ok) catch {};
    return out.toOwnedSlice();
}

fn writeState(jws: *std.json.Stringify, alloc: Allocator, w_opt: ?*SettingsWindow, ok: ?bool) !void {
    try jws.beginObject();
    try jws.objectField("success");
    try jws.write(true);
    try jws.objectField("data");
    try jws.beginObject();
    try jws.objectField("open");
    try jws.write(w_opt != null);
    if (ok) |o| {
        try jws.objectField("ok");
        try jws.write(o);
    }
    if (w_opt) |w| {
        try jws.objectField("page");
        try jws.write(@tagName(w.page));
        try jws.objectField("filter");
        try jws.write(@tagName(w.filter));
        try jws.objectField("query");
        try jws.write(w.query());
        try jws.objectField("searching");
        try jws.write(w.searching());
        try jws.objectField("total");
        try jws.write(w.catalog.entries.len);
        try jws.objectField("matched");
        try jws.write(w.matchedCount());
        try jws.objectField("changed_in_file");
        try jws.write(w.changedInFile());
        try jws.objectField("file");
        try jws.write(w.main_path);
        try jws.objectField("editing");
        try jws.write(w.editingKey());
        try jws.objectField("doc");
        try jws.write(w.doc_key);
        try jws.objectField("rows");
        try jws.beginArray();
        if (w.reader()) |r| for (w.listedKeys()) |key| {
            const entry = w.catalog.get(key);
            const repeatable = if (entry) |e| e.repeatable else false;
            try jws.beginObject();
            try jws.objectField("key");
            try jws.write(key);
            try jws.objectField("value");
            try jws.write(r.value(key));
            // The live config's value, not the file's line: it only moves
            // once the reload a write triggers has applied.
            try jws.objectField("effective");
            try jws.write(if (w.effective) |*e| (if (e.get(key)) |x| x.value() else null) else null);
            try jws.objectField("modified");
            try jws.write(r.isModified(key));
            try jws.objectField("set_in_file");
            try jws.write(r.isSetInFile(key));
            try jws.objectField("repeatable");
            try jws.write(repeatable);
            const src = w.overridingSource(key);
            try jws.objectField("readonly");
            try jws.write(src != null);
            try jws.objectField("override");
            try jws.write(if (src) |s| s.path else null);
            try jws.objectField("problem");
            try jws.write(w.model.problem(key));
            if (repeatable) {
                const file_vals = try w.file.values(alloc, key);
                defer alloc.free(file_vals);
                try jws.objectField("file_values");
                try jws.write(file_vals);
            }
            try jws.endObject();
        };
        try jws.endArray();
    }
    try jws.endObject();
    try jws.endObject();
}

const testing = std.testing;

test "ipc_settings: parse" {
    const r = try parse(&.{ "--op=set", "--key=font-size", "--value=15", "--filter=changed" });
    try testing.expectEqual(Op.set, r.op);
    try testing.expectEqualStrings("font-size", r.key.?);
    try testing.expectEqualStrings("15", r.value.?);
    try testing.expectEqual(SettingsWindow.Filter.changed, r.filter.?);
    try testing.expectError(error.MissingOp, parse(&.{"--key=x"}));
    try testing.expectError(error.BadOp, parse(&.{"--op=nope"}));
    try testing.expectError(error.BadFilter, parse(&.{ "--op=state", "--filter=some" }));
    try testing.expectError(error.BadNumber, parse(&.{ "--op=remove", "--index=-1" }));
}
