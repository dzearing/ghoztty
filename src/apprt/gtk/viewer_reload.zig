//! The GTK viewer's reload policy, the pure half (T3413, Linux L9d): which
//! file-monitor events are a save, how long a burst of them is collapsed,
//! what a dead WebKit web process means, and what the pane says when a page
//! keeps killing its own.
//!
//! Every DECISION here is already made, and tested, by the win32 port and
//! only mapped onto GTK's vocabulary:
//!
//! - what a reload does in each mode - re-render the template, reload a page
//!   in place, re-fetch from origin - is `viewer_content.reloadPlan`;
//! - whether a save may skip its render (unchanged stamp, hidden pane) is
//!   `reload_gate.Gate` (T3037);
//! - how many restarts a dead content process gets is `viewer_process.Budget`
//!   (T3107, Mac `contentProcessRestartLimit`/`Window`: 3 in 60 s).
//!
//! No GTK or WebKit imports, so the none lane runs these tests on every seat.
const std = @import("std");

const viewer_process = @import("../win32/viewer_process.zig");

/// How long a burst of change events is collapsed into one render: win32's
/// `reload_debounce_ms` (T391), the Mac's `scheduleReload` delay. An editor's
/// save is several events (truncate, write, close; or create, rename).
pub const debounce_ms: u32 = 100;

/// `GFileMonitorEvent`, by value.
pub const MonitorEvent = enum(c_int) {
    changed = 0,
    changes_done_hint = 1,
    deleted = 2,
    created = 3,
    attribute_changed = 4,
    pre_unmount = 5,
    unmounted = 6,
    moved = 7,
    renamed = 8,
    moved_in = 9,
    moved_out = 10,
    _,
};

/// Whether one event on the watched file can have changed what the pane
/// shows. The monitor watches the FILE by name (GIO's inotify backend watches
/// its directory and filters by name), so an atomic save - a temp file
/// renamed over the target - arrives as `created`/`moved_in`/`renamed` for
/// the same path and there is nothing to re-arm: the win32 translation's
/// point too (`viewer_watcher.zig`). `deleted` counts: the pane then shows
/// the file is gone rather than a stale copy, and a later `created` brings it
/// back. Attribute-only and mount events never change the bytes.
pub fn isSave(event: MonitorEvent) bool {
    return switch (event) {
        .changed, .changes_done_hint, .deleted, .created, .moved, .renamed, .moved_in, .moved_out => true,
        .attribute_changed, .pre_unmount, .unmounted => false,
        _ => false,
    };
}

/// `WebKitWebProcessTerminationReason`, by value.
pub const TerminationReason = enum(c_int) {
    crashed = 0,
    exceeded_memory_limit = 1,
    terminated_by_api = 2,
    _,
};

/// The win32 budget's kind for a WebKit termination. WebKitGTK only ever
/// reports the page's OWN web process here (an iframe's or the GPU process's
/// death is not this signal), so every reason is the renderer the Mac's
/// `webViewWebContentProcessDidTerminate` reloads - including a termination
/// by API, which the Mac's delegate is called for too.
pub fn kindFor(_: TerminationReason) viewer_process.Kind {
    return .render_process_exited;
}

pub const Budget = viewer_process.Budget;
pub const Action = viewer_process.Action;
pub const restart_limit = viewer_process.restart_limit;

/// What the pane shows once a page has used up its restarts: win32's
/// `webview2.Failure.page_keeps_crashing` card, word for word.
pub const keeps_crashing_title = "This page keeps crashing";
pub const keeps_crashing_detail = std.fmt.comptimePrint(
    "It was reloaded {d} times in a minute. Reopen this pane to try again.",
    .{restart_limit},
);

/// A self-contained page for that card. It is shown with
/// `webkit_web_view_load_alternate_html`, which replaces what is on screen
/// without adding a history entry, and it needs no template: the template is
/// itself a page, and the page is what keeps dying.
pub const keeps_crashing_html =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>" ++ keeps_crashing_title ++
    "</title><style>body{font:14px system-ui,sans-serif;margin:3em;color:#555}" ++
    "h1{font-size:1.2em;color:#222}@media (prefers-color-scheme:dark){body{background:#1e1e1e;color:#aaa}h1{color:#ddd}}" ++
    "</style></head><body><h1 id=\"ghoztty-crashed\">" ++ keeps_crashing_title ++ "</h1><p>" ++
    keeps_crashing_detail ++ "</p></body></html>";

const testing = std.testing;

test "viewer_reload: content events are saves, attribute and mount events are not" {
    for ([_]MonitorEvent{ .changed, .changes_done_hint, .deleted, .created, .renamed, .moved_in, .moved_out, .moved }) |e|
        try testing.expect(isSave(e));
    for ([_]MonitorEvent{ .attribute_changed, .pre_unmount, .unmounted, @enumFromInt(99) }) |e|
        try testing.expect(!isSave(e));
}

test "viewer_reload: every WebKit termination reason spends a restart, up to the Mac's cap" {
    var b: Budget = .{};
    const reasons = [_]TerminationReason{ .crashed, .exceeded_memory_limit, .terminated_by_api };
    for (reasons, 0..) |r, i| try testing.expectEqual(Action.reload, b.decide(kindFor(r), @intCast(i * 1000)));
    try testing.expectEqual(Action.capped, b.decide(kindFor(.crashed), 4_000));
    try testing.expectEqual(Action.reload, b.decide(kindFor(@enumFromInt(7)), 61_000));
}

test "viewer_reload: the crash card names the cap it hit" {
    try testing.expect(std.mem.indexOf(u8, keeps_crashing_detail, "3 times") != null);
    try testing.expect(std.mem.indexOf(u8, keeps_crashing_html, keeps_crashing_title) != null);
}
