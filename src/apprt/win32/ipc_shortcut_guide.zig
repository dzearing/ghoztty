//! The `shortcut-guide` IPC action (T2591): open the keyboard shortcut guide,
//! drive its search, category, unbound toggle, selection and Run, and read
//! back the model it is showing - the seam `test/win32/shortcut-guide.ps1`
//! is built on.
//!
//! Debug builds only, like `whats-new`: the CLI verb list is a
//! cross-platform surface (T141) and this is instrumentation with one
//! consumer. What the guide is FOR is a model - which bindings are live,
//! which the user customized, what a key-combo search finds - and none of
//! that can be read off pixels, so the seam reports the same rows the
//! window paints.
//!
//! ```
//! {"action":"shortcut-guide","arguments":["--op=open"]}
//! {"action":"shortcut-guide","arguments":["--op=state","--query=ctrl shift p"]}
//! {"action":"shortcut-guide","arguments":["--op=state","--category=panes"]}
//! {"action":"shortcut-guide","arguments":["--op=state","--unbound=1"]}
//! {"action":"shortcut-guide","arguments":["--op=select","--down=2"]}
//! {"action":"shortcut-guide","arguments":["--op=run"]}
//! {"action":"shortcut-guide","arguments":["--op=escape"]}
//! {"action":"shortcut-guide","arguments":["--op=cheat-sheet"]}   (writes, never opens)
//! {"action":"shortcut-guide","arguments":["--op=close"]}
//!   -> {"success":true,"data":{"open":true,"query":"...","category":null,
//!        "include_unbound":false,"bound":61,"customized":0,"selected":"...",
//!        "rows":[{"id":"new_window","kind":"keybind","title":"New Window",
//!                 "category":"windows","keys":["Ctrl+N","Ctrl+Shift+N"],
//!                 "customized":false,"unbound_by_user":false,
//!                 "global":false,"table":null,"runnable":true}, ...],
//!        "counts":{"windows":12,...},"last_run":""}}
//! ```
const std = @import("std");
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const App = @import("App.zig");
const ipc_capture = @import("ipc_capture.zig");
const catalog_mod = @import("shortcut_catalog.zig");
const ShortcutGuideWindow = @import("ShortcutGuideWindow.zig");

const errorResponse = ipc_capture.errorResponse;

pub const enabled = build_config.is_debug;

pub const Op = enum { open, close, state, select, run, escape, @"cheat-sheet", shot };

pub const Request = struct {
    op: Op,
    query: ?[]const u8 = null,
    /// `all` clears the category.
    category: ?[]const u8 = null,
    unbound: ?bool = null,
    down: ?i32 = null,
    /// `shot`: where to write the PNG.
    path: ?[]const u8 = null,
};

pub const ParseError = error{ MissingOp, BadOp, BadCategory, BadNumber };

pub fn parse(arguments: ?[]const []const u8) ParseError!Request {
    var req: Request = .{ .op = .state };
    var have_op = false;
    if (arguments) |args| for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--op=")) {
            req.op = std.meta.stringToEnum(Op, arg["--op=".len..]) orelse return error.BadOp;
            have_op = true;
        } else if (std.mem.startsWith(u8, arg, "--query=")) {
            req.query = arg["--query=".len..];
        } else if (std.mem.startsWith(u8, arg, "--category=")) {
            const c = arg["--category=".len..];
            if (!std.mem.eql(u8, c, "all") and std.meta.stringToEnum(catalog_mod.Category, c) == null) return error.BadCategory;
            req.category = c;
        } else if (std.mem.startsWith(u8, arg, "--unbound=")) {
            req.unbound = std.mem.eql(u8, arg["--unbound=".len..], "1");
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            req.path = arg["--path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--down=")) {
            req.down = std.fmt.parseInt(i32, arg["--down=".len..], 10) catch return error.BadNumber;
        }
    };
    if (!have_op) return error.MissingOp;
    return req;
}

pub fn handle(app: *App, alloc: Allocator, arguments: ?[]const []const u8) Allocator.Error![]u8 {
    const req = parse(arguments) catch |err| return switch (err) {
        error.MissingOp => errorResponse(alloc, "--op=open|close|state|select|run|escape|cheat-sheet|shot is required", .{}),
        error.BadOp => errorResponse(alloc, "--op must be open, close, state, select, run, escape, cheat-sheet or shot", .{}),
        error.BadCategory => errorResponse(alloc, "--category must be all or a category name", .{}),
        error.BadNumber => errorResponse(alloc, "--down must be an integer", .{}),
    };

    if (req.op == .open) {
        const owner: ?*@import("Window.zig") = if (app.windows.items.len > 0) app.windows.items[0] else null;
        ShortcutGuideWindow.open(app, owner);
    }
    if (req.op == .close) {
        ShortcutGuideWindow.closeAll();
        return try stateResponse(alloc, null, null, null);
    }
    const w = ShortcutGuideWindow.current() orelse
        return errorResponse(alloc, "the keyboard shortcut guide is not open", .{});

    // Filters apply in a fixed order: the toggle, the category, the query
    // (a query clears the category, so it goes last - as typing does).
    if (req.unbound) |u| w.setIncludeUnbound(u);
    if (req.category) |c| w.setCategory(if (std.mem.eql(u8, c, "all")) null else std.meta.stringToEnum(catalog_mod.Category, c));
    if (req.query) |q| w.setQuery(q);

    var ran: ?bool = null;
    var sheet: ?[]u8 = null;
    defer if (sheet) |s| alloc.free(s);
    switch (req.op) {
        .select => w.moveSelection(req.down orelse 1),
        .run => ran = w.runSelection(),
        .escape => w.escape(),
        .@"cheat-sheet" => sheet = w.writeCheatSheet(alloc) catch null,
        .shot => {
            const path = req.path orelse return errorResponse(alloc, "--path=<file.png> is required for --op=shot", .{});
            w.snapshot(alloc, path) catch |err| return errorResponse(alloc, "shot failed ({s})", .{@errorName(err)});
        },
        else => {},
    }
    const still_open = ShortcutGuideWindow.current() != null;
    return try stateResponse(alloc, if (still_open) w else null, ran, sheet);
}

fn stateResponse(alloc: Allocator, w_opt: ?*ShortcutGuideWindow, ran: ?bool, sheet: ?[]const u8) Allocator.Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        jws.objectField("open") catch break :write;
        jws.write(w_opt != null) catch break :write;
        if (ran) |r| {
            jws.objectField("ran") catch break :write;
            jws.write(r) catch break :write;
        }
        if (sheet) |s| {
            jws.objectField("cheat_sheet") catch break :write;
            jws.write(s) catch break :write;
        }
        if (w_opt) |w| {
            jws.objectField("query") catch break :write;
            jws.write(w.query()) catch break :write;
            jws.objectField("category") catch break :write;
            jws.write(if (w.category) |c| @tagName(c) else null) catch break :write;
            jws.objectField("include_unbound") catch break :write;
            jws.write(w.include_unbound) catch break :write;
            jws.objectField("bound") catch break :write;
            jws.write(w.bound_total) catch break :write;
            jws.objectField("customized") catch break :write;
            jws.write(w.customized_total) catch break :write;
            jws.objectField("all_count") catch break :write;
            jws.write(w.all_count) catch break :write;
            jws.objectField("selected") catch break :write;
            jws.write(if (w.selectedRow()) |r| r.id else null) catch break :write;
            jws.objectField("last_run") catch break :write;
            jws.write(w.lastRun()) catch break :write;
            jws.objectField("counts") catch break :write;
            jws.beginObject() catch break :write;
            for (std.enums.values(catalog_mod.Category)) |c| {
                jws.objectField(@tagName(c)) catch break :write;
                jws.write(w.counts[@intFromEnum(c)]) catch break :write;
            }
            jws.endObject() catch break :write;
            jws.objectField("rows") catch break :write;
            jws.beginArray() catch break :write;
            for (w.rows) |r| {
                jws.beginObject() catch break :write;
                jws.objectField("id") catch break :write;
                jws.write(r.id) catch break :write;
                jws.objectField("kind") catch break :write;
                jws.write(@tagName(r.kind)) catch break :write;
                jws.objectField("title") catch break :write;
                jws.write(r.title) catch break :write;
                jws.objectField("category") catch break :write;
                jws.write(@tagName(r.category)) catch break :write;
                jws.objectField("keys") catch break :write;
                jws.beginArray() catch break :write;
                for (r.bindings) |b| {
                    jws.write(catalog_mod.bindingText(arena, b) catch "") catch break :write;
                }
                jws.endArray() catch break :write;
                jws.objectField("customized") catch break :write;
                jws.write(r.customized) catch break :write;
                jws.objectField("unbound_by_user") catch break :write;
                jws.write(r.unbound_by_user) catch break :write;
                jws.objectField("global") catch break :write;
                jws.write(r.isGlobal()) catch break :write;
                jws.objectField("table") catch break :write;
                jws.write(r.table()) catch break :write;
                jws.objectField("runnable") catch break :write;
                jws.write(r.runnable) catch break :write;
                jws.endObject() catch break :write;
            }
            jws.endArray() catch break :write;
        }
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
    }
    return try out.toOwnedSlice();
}

test "parse: ops, filters and refusals" {
    const t = std.testing;
    try t.expectError(error.MissingOp, parse(null));
    try t.expectError(error.BadOp, parse(&.{"--op=explode"}));
    try t.expectError(error.BadCategory, parse(&.{ "--op=state", "--category=nope" }));
    try t.expectError(error.BadNumber, parse(&.{ "--op=select", "--down=x" }));
    const r = try parse(&.{ "--op=state", "--query=ctrl d", "--category=panes", "--unbound=1" });
    try t.expectEqual(Op.state, r.op);
    try t.expectEqualStrings("ctrl d", r.query.?);
    try t.expectEqualStrings("panes", r.category.?);
    try t.expect(r.unbound.?);
    try t.expectEqual(Op.@"cheat-sheet", (try parse(&.{"--op=cheat-sheet"})).op);
}
