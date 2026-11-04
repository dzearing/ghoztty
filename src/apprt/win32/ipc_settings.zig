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
//! {"action":"settings","arguments":["--op=theme-mode","--value=true"]}   (Use: light & dark)
//! {"action":"settings","arguments":["--op=theme-pick","--key=dark","--value=Catppuccin Mocha"]}
//! {"action":"settings","arguments":["--op=close"]}
//! Advanced > Config file and the toast (T2676):
//! {"action":"settings","arguments":["--op=restore","--index=0"]}  (newest backup, confirmed)
//! {"action":"settings","arguments":["--op=undo"]}                 (the toast's Undo)
//! {"action":"settings","arguments":["--op=show_change"]}          (Show / Hide Change)
//! {"action":"settings","arguments":["--op=dismiss"]}              (the toast's x)
//! {"action":"settings","arguments":["--op=toast_ms","--value=600000"]}
//! The live sections (T2680):
//! {"action":"settings","arguments":["--op=check_updates"]}   (Updates' Check for Updates...)
//! {"action":"settings","arguments":["--op=click","--value=pane_style:flat"]}
//!   (clicks the PAINTED hit of that kind and key at its centre - run --op=shot
//!   first so the page has painted; ok=false when no such hit is on screen)
//!   -> adds "live":{"agent":{"running","pid","running_build","bundled_build","pipe"},
//!        "version","last_check_ms"} and "hits":[{"kind","key"}] (painted
//!        check_updates / pane_style hits)
//! {"action":"settings","arguments":["--op=open_editor"]}  / reveal_file / open_source --index / backups_folder / current_file
//!   -> adds "advanced":{"path","target","sources":[{"path","name","kind"}],"backups":[{"path","label"}],
//!        "backed_up","file_error","show_file","last_shell"} and
//!        "toast":{"message","detail","removed","added","expanded","refused"} (null when none)
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
const settings_pages = @import("settings_pages.zig");
const settings_advanced = @import("settings_advanced.zig");
const SettingsModel = @import("SettingsModel.zig");
const theme_catalog = @import("theme_catalog.zig");

const errorResponse = ipc_capture.errorResponse;

pub const enabled = build_config.is_debug;

pub const Op = enum {
    action,
    open,
    close,
    state,
    set,
    add,
    remove,
    reset,
    doc,
    escape,
    shot,
    toggle,
    choose,
    reveal,
    restore,
    undo,
    show_change,
    dismiss,
    toast_ms,
    open_editor,
    reveal_file,
    open_source,
    backups_folder,
    current_file,
    @"theme-mode",
    @"theme-pick",
    // The live sections (T2680).
    check_updates,
    click,
};

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

const op_list = blk: {
    var out: []const u8 = "";
    for (std.meta.fieldNames(Op), 0..) |n, i| out = out ++ (if (i == 0) "" else "|") ++ n;
    break :blk out;
};

pub fn handle(app: *App, alloc: Allocator, arguments: ?[]const []const u8) Allocator.Error![]u8 {
    const req = parse(arguments) catch |err| return switch (err) {
        error.MissingOp => errorResponse(alloc, "--op=<" ++ op_list ++ "> is required", .{}),
        error.BadOp => errorResponse(alloc, "--op must be one of " ++ op_list, .{}),
        error.BadFilter => errorResponse(alloc, "--filter must be all, changed or uncovered", .{}),
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
    var undo_result: ?SettingsModel.UndoResult = null;
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
        // A curated switch / popup pick / "<Page> >" link - the same
        // functions the clicks call (the popup's menu is the only part not
        // driven, since TrackPopupMenu is modal).
        .toggle => {
            const key = req.key orelse return errorResponse(alloc, "--key is required for --op=toggle", .{});
            ok = w.toggleKey(key);
        },
        .choose => {
            const key = req.key orelse return errorResponse(alloc, "--key is required for --op=choose", .{});
            ok = w.chooseValue(key, req.value orelse "");
        },
        .reveal => {
            const key = req.key orelse return errorResponse(alloc, "--key is required for --op=reveal", .{});
            ok = w.reveal(key);
        },
        // Appearance > Theme: the "Use" popup's pick, and a theme menu's pick.
        .@"theme-mode" => {
            const v = req.value orelse return errorResponse(alloc, "--value=true|false is required for --op=theme-mode", .{});
            ok = w.setThemeFollows(std.mem.eql(u8, v, "true"));
        },
        .@"theme-pick" => {
            const slot = std.meta.stringToEnum(theme_catalog.Slot, req.key orelse "light") orelse
                return errorResponse(alloc, "--key must be light or dark for --op=theme-pick", .{});
            const name = req.value orelse return errorResponse(alloc, "--value=<theme name> is required for --op=theme-pick", .{});
            ok = w.pickTheme(name, slot);
        },
        .escape => {
            // Esc, as the window handles it: field, then search, then close.
            if (w.editingKey() != null) w.cancelEdit() else if (w.search.len > 0) w.setQuery("") else {
                SettingsWindow.closeAll();
                return try stateResponse(alloc, null, null);
            }
        },
        .restore => ok = w.restoreBackupAt(req.index orelse 0),
        .undo => undo_result = w.undoLast(),
        .show_change => w.toggleToastChange(),
        .dismiss => w.dismissToast(),
        .toast_ms => {
            const v = req.value orelse return errorResponse(alloc, "--value=<ms> is required for --op=toast_ms", .{});
            w.toast_ms = std.fmt.parseInt(u32, v, 10) catch return errorResponse(alloc, "--value must be a number of milliseconds", .{});
        },
        .open_editor => w.openEditor(),
        .reveal_file => w.revealConfigFile(),
        .open_source => w.openSource(req.index orelse 0),
        .backups_folder => w.showBackupsFolder(),
        .current_file => w.toggleCurrentFile(),
        .check_updates => w.checkForUpdates(),
        .click => {
            const v = req.value orelse return errorResponse(alloc, "--value=<kind>:<key> is required for --op=click", .{});
            const colon = std.mem.indexOfScalar(u8, v, ':');
            const kind = std.meta.stringToEnum(SettingsWindow.Hit.Kind, if (colon) |c| v[0..c] else v) orelse
                return errorResponse(alloc, "--value must start with a hit kind", .{});
            ok = w.clickHit(kind, if (colon) |c| v[c + 1 ..] else "");
        },
        .shot => {
            const path = req.path orelse return errorResponse(alloc, "--path=<file.png> is required for --op=shot", .{});
            w.snapshot(alloc, path) catch |err| return errorResponse(alloc, "shot failed ({s})", .{@errorName(err)});
        },
        else => {},
    }
    return try stateResponseUndo(alloc, SettingsWindow.current(), ok, undo_result);
}

fn stateResponse(alloc: Allocator, w_opt: ?*SettingsWindow, ok: ?bool) Allocator.Error![]u8 {
    return stateResponseUndo(alloc, w_opt, ok, null);
}

fn stateResponseUndo(alloc: Allocator, w_opt: ?*SettingsWindow, ok: ?bool, undo: ?SettingsModel.UndoResult) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    writeState(&jws, alloc, w_opt, ok, undo) catch {};
    return out.toOwnedSlice();
}

/// Advanced > Config file and the toast, as the window paints them.
fn writeAdvanced(jws: *std.json.Stringify, w: *SettingsWindow) !void {
    try jws.objectField("advanced");
    try jws.beginObject();
    try jws.objectField("path");
    try jws.write(w.main_path);
    try jws.objectField("target");
    try jws.write(w.target_display);
    try jws.objectField("sources");
    try jws.beginArray();
    for (w.otherSources()) |src| {
        try jws.beginObject();
        try jws.objectField("path");
        try jws.write(src.path);
        try jws.objectField("name");
        try jws.write(src.name());
        try jws.objectField("kind");
        try jws.write(settings_advanced.sourceKind(src).tag());
        try jws.endObject();
    }
    try jws.endArray();
    try jws.objectField("backups");
    try jws.beginArray();
    var label_buf: [64]u8 = undefined;
    for (w.backups()) |b| {
        try jws.beginObject();
        try jws.objectField("path");
        try jws.write(b);
        try jws.objectField("label");
        try jws.write(settings_advanced.backupLabel(&label_buf, b));
        try jws.endObject();
    }
    try jws.endArray();
    try jws.objectField("backed_up");
    try jws.write(w.store.backup_path != null);
    try jws.objectField("file_error");
    try jws.write(w.model.file_error);
    try jws.objectField("show_file");
    try jws.write(w.show_file);
    try jws.objectField("last_shell");
    try jws.write(w.last_shell);
    try jws.endObject();

    try jws.objectField("toast");
    if (w.model.last_change) |c| {
        try jws.beginObject();
        try jws.objectField("message");
        try jws.write(c.message);
        try jws.objectField("detail");
        try jws.write(settings_advanced.toastDetail(c.backed_up_to != null));
        try jws.objectField("removed");
        try jws.write(c.removed);
        try jws.objectField("added");
        try jws.write(c.added);
        try jws.objectField("expanded");
        try jws.write(w.toast_expanded);
        try jws.objectField("refused");
        try jws.write(w.toast_refused);
        try jws.endObject();
    } else try jws.write(null);
}

/// The live sections' snapshot and their painted hits (T2680).
fn writeLive(jws: *std.json.Stringify, w: *SettingsWindow) !void {
    const a = w.live_agent;
    try jws.objectField("live");
    try jws.beginObject();
    try jws.objectField("agent");
    try jws.beginObject();
    try jws.objectField("running");
    try jws.write(a.running);
    try jws.objectField("pid");
    try jws.write(a.pid);
    try jws.objectField("running_build");
    try jws.write(a.running_build);
    try jws.objectField("bundled_build");
    try jws.write(a.bundled_build);
    try jws.objectField("pipe");
    try jws.write(a.pipe);
    try jws.endObject();
    try jws.objectField("version");
    try jws.write(build_config.version_string);
    try jws.objectField("last_check_ms");
    try jws.write(w.app.update_last_check_ms);
    try jws.endObject();
    try jws.objectField("hits");
    try jws.beginArray();
    for (w.hits.items) |h| switch (h.kind) {
        .check_updates, .pane_style => {
            try jws.beginObject();
            try jws.objectField("kind");
            try jws.write(@tagName(h.kind));
            try jws.objectField("key");
            try jws.write(h.key);
            try jws.endObject();
        },
        else => {},
    };
    try jws.endArray();
}

fn writeState(jws: *std.json.Stringify, alloc: Allocator, w_opt: ?*SettingsWindow, ok: ?bool, undo: ?SettingsModel.UndoResult) !void {
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
    if (undo) |u| {
        try jws.objectField("undo");
        try jws.write(@tagName(u));
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
        try jws.objectField("curated_hits");
        try jws.write(w.curated_hits);
        try jws.objectField("revealed");
        try jws.write(w.revealed_key);
        // Appearance > Theme, as the section reads it.
        try jws.objectField("theme");
        {
            const cat = w.themeCatalog();
            const sel = w.themeSelection();
            try jws.beginObject();
            try jws.objectField("follows");
            try jws.write(if (sel) |s| s.follows_system else false);
            try jws.objectField("light");
            try jws.write(if (sel) |s| s.light else null);
            try jws.objectField("dark");
            try jws.write(if (sel) |s| s.dark else null);
            try jws.objectField("mismatch");
            try jws.write(if (sel) |s| (if (theme_catalog.mismatch(cat, s)) |m| @tagName(m) else null) else null);
            try jws.objectField("light_count");
            try jws.write(cat.count(true));
            try jws.objectField("dark_count");
            try jws.write(cat.count(false));
            // The user's own themes, with their kind (a clash shows here as
            // the user's copy).
            try jws.objectField("user_themes");
            try jws.beginArray();
            for (cat.themes) |*t| if (t.is_user) {
                try jws.beginObject();
                try jws.objectField("name");
                try jws.write(t.name);
                try jws.objectField("light");
                try jws.write(t.isLight());
                try jws.endObject();
            };
            try jws.endArray();
            try jws.endObject();
        }
        // The sidebar: each page and its changed count.
        try jws.objectField("pages");
        try jws.beginArray();
        for (SettingsWindow.pages) |pg| {
            try jws.beginObject();
            try jws.objectField("id");
            try jws.write(@tagName(pg.id));
            try jws.objectField("title");
            try jws.write(pg.title);
            try jws.objectField("count");
            try jws.write(w.changedOn(pg.id));
            try jws.endObject();
        }
        try jws.endArray();
        try jws.objectField("file");
        try jws.write(w.main_path);
        try jws.objectField("editing");
        try jws.write(w.editingKey());
        try jws.objectField("doc");
        try jws.write(w.doc_key);
        // The custom sections the form lays out, in order.
        try jws.objectField("customs");
        try jws.beginArray();
        for (w.items) |it| if (it.kind == .custom) try jws.write(@tagName(it.custom));
        try jws.endArray();
        try writeAdvanced(jws, w);
        try writeLive(jws, w);
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
            // Curated: the page that owns the key (the reveal link), and on
            // a curated page the row's label, control, shown value, and
            // whether its condition leaves it live.
            try jws.objectField("curated_page");
            try jws.write(if (settings_pages.pageFor(key)) |id| @tagName(id) else null);
            if (!w.searching() and w.page == .advanced) {} else if (settings_pages.rowFor(key)) |row| {
                try jws.objectField("label");
                try jws.write(row.label);
                try jws.objectField("control");
                try jws.write(@tagName(row.control));
                try jws.objectField("shown");
                try jws.write(row.labelFor(r.value(key)));
                try jws.objectField("enabled");
                try jws.write(w.rowEnabled(row));
            }
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
    try testing.expectEqual(SettingsWindow.Filter.uncovered, (try parse(&.{ "--op=state", "--filter=uncovered" })).filter.?);
    try testing.expectEqual(Op.choose, (try parse(&.{ "--op=choose", "--key=scrollbar", "--value=never" })).op);
    try testing.expectEqual(SettingsWindow.PageId.terminal, (try parse(&.{ "--op=state", "--page=terminal" })).page.?);
    try testing.expectError(error.BadNumber, parse(&.{ "--op=remove", "--index=-1" }));
    try testing.expectEqual(Op.show_change, (try parse(&.{"--op=show_change"})).op);
    try testing.expectEqual(@as(usize, 2), (try parse(&.{ "--op=restore", "--index=2" })).index.?);
}
