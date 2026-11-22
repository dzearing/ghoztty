//! Activity Monitor hover help (T1634): Mac's `.help()` words on the control
//! bar, through ONE native comctl32 tooltip (`help_tooltip.zig`, the machine
//! chooser's control, shared).
//!
//! Two kinds of surface, the chooser's split exactly:
//!
//! - **Painted** — the status badge ("List truncated") and the process count.
//!   The panel sees the pointer on them through its own `WM_MOUSEMOVE`, arms a
//!   show delay, and places a track-mode tip under the words when it fires.
//!   Only the drawn WORDS answer, not the slack in their slot (`textHit`).
//! - **Painted table cells** (T1548) — a row's Name, Window / Pane and Path
//!   cells, with Mac's per-cell words (the full command, the pane's detail,
//!   the whole path). These answer anywhere in the cell, as Mac's `.help()`
//!   on a table cell does, and are one surface PER ROW: the target carries the
//!   row's PID, so moving down a column re-arms the delay for the new row. A
//!   wheel scroll drops the tip, and the show re-checks that the same row is
//!   still under the hover point, so a refresh that re-sorted the table during
//!   the delay cannot put one process's words under another's row.
//! - **Real controls** — "Show all", Kill and New Process. A child control
//!   forwards `WM_SETCURSOR` to the panel, which is where entering one is seen;
//!   the panel re-words that control's subclass tool and comctl32 shows it,
//!   including the dismissal when the pointer leaves the control straight out
//!   of the window.
//!
//! The words are derived at hover time AND again at show time, so a count that
//! changed during the delay is shown as it is now. Text derivation is pure
//! (`activity_help.zig`, none-lane tested); this file is the state machine,
//! the hit tests and the placement.
//!
//! The debug oracle, logged at HOVER time because the background test desktop
//! cannot hold a hover across the show delay (T233):
//!
//! - `activity help tooltip target=<kind> text=<text>` when the pointer reaches
//!   a surface (`<none>` when it has nothing to say right now). A table cell
//!   logs `target=<name|pane|path> pid=<n> text=<text>`, its newlines written
//!   as a literal `\n` so the multi-line pane detail stays one log line;
//! - `activity help tooltip dropped target=<kind>` when it leaves one for
//!   nothing;
//! - `activity help tooltip shown target=<kind>` when a painted tip appears.

const std = @import("std");

const ActivityMonitor = @import("ActivityMonitor.zig");
const actions = @import("activity_actions.zig");
const activity_help = @import("activity_help.zig");
const chrome_theme = @import("chrome_theme.zig");
const help_tooltip = @import("help_tooltip.zig");
const layout_mod = @import("activity_layout.zig");
const rows_mod = @import("activity_rows.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");

const log = ActivityMonitor.log;
const Target = activity_help.Target;

/// The real child controls that carry a subclass tool, in slot order.
pub const Control = enum(u2) { show_all, kill, new_process };

pub const Tip = help_tooltip.HelpTip(Control, activity_help.max_len);

/// The show delay's timer, on the panel's own timer id space (the sample poll
/// is 1) - so it is not a `msg_timer` id.
pub const TIMER_ID: usize = 2;

fn controlFor(t: Target) ?Control {
    return switch (t) {
        .show_all => .show_all,
        .kill => .kill,
        .new_process => .new_process,
        .badge, .count, .name_cell, .pane_cell, .path_cell => null,
    };
}

/// The help surface a process-table column carries (T1548), or null for the
/// columns Mac gives no `.help()` (PID, Memory) and the one whose words the
/// win32 panel cannot say yet (% CPU, T1549).
fn cellTargetFor(col: layout_mod.Column) ?Target {
    return switch (col) {
        .name => .name_cell,
        .pane => .pane_cell,
        .path => .path_cell,
        .pid, .mem, .cpu => null,
    };
}

/// A painted surface under the pointer: which, and for a table cell, whose row.
const Hit = struct { target: Target, pid: i64 = 0 };

fn showAllEnabled(self: *const ActivityMonitor) bool {
    return self.show_all_enabled orelse true;
}

/// Whether comctl32's subclass tool shows `t`'s tip. True for a real control,
/// EXCEPT a disabled "Show all" (T1748): a disabled window receives no mouse
/// messages, so its subclass tool never fires and the panel shows the tip as
/// a painted surface instead - which keeps Mac's "pre-dates" sentence, the one
/// that explains WHY it is disabled, reachable.
fn comctlShows(self: *const ActivityMonitor, t: Target) bool {
    if (!t.isControl()) return false;
    if (t == .show_all) return showAllEnabled(self);
    return true;
}

fn controlHwnd(self: *const ActivityMonitor, c: Control) w32.HWND {
    return switch (c) {
        .show_all => self.show_all_btn,
        .kill => self.kill_btn,
        .new_process => self.new_proc_btn,
    };
}

/// `WM_SETCURSOR` names the window under the pointer, and a child control
/// forwards it here - so entering a control, and moving off one onto anything
/// else in the panel, are both seen at this one place.
pub fn onSetCursor(self: *ActivityMonitor, over: ?w32.HWND) void {
    const h = over orelse return;
    const target: ?Target =
        if (h == self.show_all_btn) .show_all else if (h == self.kill_btn) .kill else if (h == self.new_proc_btn) .new_process else null;
    if (target) |t| {
        setTarget(self, .{ .target = t }, .{ .x = 0, .y = 0 });
        return;
    }
    // Over anything else: a control's tip is over. A painted surface's tip is
    // left to the `WM_MOUSEMOVE` that follows, which knows the point.
    if (self.help_target) |cur| {
        if (comctlShows(self, cur)) setTarget(self, null, .{ .x = 0, .y = 0 });
    }
}

/// The pointer moved on the panel itself (client coordinates).
pub fn onMouseMove(self: *ActivityMonitor, x: i32, y: i32) void {
    setTarget(self, paintedAt(self, x, y), .{ .x = x, .y = y });
}

/// The pointer left the panel. Only what the PANEL paints loses its tip here:
/// this leave also fires when the pointer enters a child, and a control's tip
/// belongs to comctl32's own tracking of that child.
pub fn onMouseLeave(self: *ActivityMonitor) void {
    if (self.help_target) |t| {
        if (!comctlShows(self, t)) setTarget(self, null, .{ .x = 0, .y = 0 });
    }
}

/// The table scrolled under the pointer: the row a cell tip describes is no
/// longer the row under it. Drop the tip; the next move finds the new row.
pub fn onTableScrolled(self: *ActivityMonitor) void {
    if (self.help_target) |t| {
        if (t.isCell()) setTarget(self, null, .{ .x = 0, .y = 0 });
    }
}

/// Hide the tip, cancel any pending show and destroy the control. Called when
/// the panel goes away.
pub fn destroy(self: *ActivityMonitor) void {
    _ = w32.KillTimer(self.hwnd, TIMER_ID);
    self.help_target = null;
    self.help_pid = 0;
    self.help_tip.destroy(self.hwnd);
}

/// The painted help surface at client point (x, y), if any.
fn paintedAt(self: *ActivityMonitor, x: i32, y: i32) ?Hit {
    const l = self.layout();
    // The table: a cell hit is arithmetic on the row band and column widths,
    // with no text measured.
    if (cellAt(self, l, x, y)) |hit| return hit;
    if (y < l.control.top or y >= l.control.bottom) return null;
    // A disabled "Show all" gets no mouse input of its own - Windows routes the
    // pointer over it to the panel - so its words are a painted surface while
    // it is disabled, answering anywhere in the control's rect.
    if (!showAllEnabled(self)) {
        const s = l.show_all;
        if (x >= s.left and x < s.right and y >= s.top and y < s.bottom) return .{ .target = .show_all };
    }
    if (badgeText(self)) |badge| {
        const b = l.badge;
        if (b.width() > 0 and activity_help.textHit(b.left, b.right, measure(self, badge), false, x, y >= b.top and y < b.bottom)) {
            return .{ .target = .badge };
        }
    }
    var buf: [64]u8 = undefined;
    const c = l.count;
    const label = countLabel(self, &buf);
    if (activity_help.textHit(c.left, c.right, measure(self, label), true, x, y >= c.top and y < c.bottom)) {
        return .{ .target = .count };
    }
    return null;
}

/// The process-table cell at (x, y) that carries help, with its row's PID.
/// Only rows that exist answer — the empty band under the last row is not a
/// cell.
fn cellAt(self: *const ActivityMonitor, l: layout_mod.Layout, x: i32, y: i32) ?Hit {
    if (x < l.table.left or x >= l.table.right) return null;
    const idx = layout_mod.rowIndexAt(l, y, self.scroll) orelse return null;
    const pid = self.pidAt(idx) orelse return null;
    const widths = layout_mod.columnWidths(self.scale, l.table.width());
    const col = ActivityMonitor.columnAt(l.table, widths, x) orelse return null;
    const t = cellTargetFor(col) orelse return null;
    return .{ .target = t, .pid = pid };
}

/// The row a cell target describes, while it is still in the snapshot.
fn rowFor(self: *const ActivityMonitor, pid: i64) ?*const rows_mod.Row {
    const snap = self.snap orelse return null;
    for (snap.rows) |*r| {
        if (r.pid == pid) return r;
    }
    return null;
}

/// The badge exactly as `paintControlBar` draws it.
fn badgeText(self: *const ActivityMonitor) ?[]const u8 {
    const total = if (self.snap) |s| s.rows.len else 0;
    const truncated = if (self.snap) |s| s.truncated else false;
    return actions.badgeText(self.refresh_failed, truncated, total);
}

/// The count exactly as `paintControlBar` draws it.
fn countLabel(self: *const ActivityMonitor, buf: []u8) []const u8 {
    const total = if (self.snap) |s| s.rows.len else 0;
    return rows_mod.formatCount(buf, self.filterSpec(), self.order_len, total);
}

/// The drawn width of `text` in the control bar's caption font, in pixels.
fn measure(self: *ActivityMonitor, text: []const u8) i32 {
    var wbuf: [128]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 0;
    if (n == 0) return 0;
    const hdc = w32.GetDC(self.hwnd) orelse return 0;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);
    const old = w32.SelectObject(hdc, self.caption_font);
    defer _ = w32.SelectObject(hdc, old);
    var sz: w32.SIZE = .{ .cx = 0, .cy = 0 };
    if (w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(n), &sz) == 0) return 0;
    return sz.cx;
}

/// The text for `t`, or null when there is nothing to explain right now (no
/// truncation, nothing selected). Derived at show time as well as hover time.
fn textFor(self: *ActivityMonitor, t: Target, pid: i64, out: []u8) ?[]const u8 {
    const total = if (self.snap) |s| s.rows.len else 0;
    return switch (t) {
        // A row that left the snapshot since the hover says nothing.
        .name_cell => if (rowFor(self, pid)) |r| activity_help.nameCell(out, r.name, r.cmd) else null,
        .path_cell => if (rowFor(self, pid)) |r| activity_help.pathCell(out, r.cmd) else null,
        .pane_cell => if (rowFor(self, pid)) |r| activity_help.paneCell(r.pane_label, r.pane_detail) else null,
        .badge => activity_help.badge(
            self.refresh_failed,
            if (self.snap) |s| s.truncated else false,
            total,
        ),
        .count => activity_help.count(out, self.filterSpec(), self.order_len, total),
        .show_all => activity_help.showAll(self.filterSpec()),
        .kill => blk: {
            if (self.sel_len == 0) break :blk null;
            const first = self.sel_pids[0];
            const name: []const u8 = if (rowFor(self, first)) |r| r.name else "";
            break :blk activity_help.kill(out, self.sel_len, first, name);
        },
        .new_process => activity_help.newProcess(out, self.source.label()),
    };
}

fn ensure(self: *ActivityMonitor) ?w32.HWND {
    const bg = self.app.config.background;
    const dark = chrome_theme.isDark(
        self.app.config.@"window-theme",
        .{ .r = bg.r, .g = bg.g, .b = bg.b },
        Window.systemUsesLightTheme(),
    );
    return self.help_tip.ensure(self.hwnd, self.app.hinstance, dark);
}

/// The pointer moved onto a different help surface (or off them all): hide
/// the tip, then arm a fresh delay for a painted surface, or re-word a
/// control's own tool.
fn setTarget(self: *ActivityMonitor, hit: ?Hit, pt: w32.POINT) void {
    const new: ?Target = if (hit) |h| h.target else null;
    const pid: i64 = if (hit) |h| h.pid else 0;
    const old = self.help_target;
    // Moving within one surface changes nothing - but a cell surface is one
    // per ROW, so the next row down the same column is a new surface.
    if (old == new and self.help_pid == pid) return;
    self.help_target = new;
    self.help_pid = pid;
    self.help_pt = pt;
    _ = w32.KillTimer(self.hwnd, TIMER_ID);
    self.help_tip.hide(self.hwnd);

    if (old) |o| {
        // Moving straight to another surface is announced by that surface's
        // own line; only "onto nothing" is a drop.
        if (new == null) log.debug("activity help tooltip dropped target={s}", .{o.kind()});
    }
    const t = new orelse return;

    var buf: [activity_help.max_len]u8 = undefined;
    const text = textFor(self, t, pid, &buf);
    if (t.isCell()) {
        // One line per hover, whatever the text: the pane detail is several.
        var lbuf: [2 * activity_help.max_len]u8 = undefined;
        log.debug("activity help tooltip target={s} pid={d} text={s}", .{
            t.kind(),
            pid,
            if (text) |s| activity_help.oneLine(&lbuf, s) else "<none>",
        });
    } else {
        log.debug("activity help tooltip target={s} text={s}", .{ t.kind(), text orelse "<none>" });
    }

    if (if (comctlShows(self, t)) controlFor(t) else null) |c| {
        // comctl32 shows this one: keep the tool's words current, nothing more.
        const tip = ensure(self) orelse return;
        self.help_tip.setControlText(self.hwnd, tip, c, controlHwnd(self, c), text orelse "");
        return;
    }
    _ = w32.SetTimer(self.hwnd, TIMER_ID, w32.GetDoubleClickTime(), null);
}

/// The show delay elapsed with the pointer still on a painted surface: place
/// the tip just under its words and activate it.
pub fn onTimer(self: *ActivityMonitor) void {
    _ = w32.KillTimer(self.hwnd, TIMER_ID);
    const t = self.help_target orelse return;
    if (comctlShows(self, t)) return;

    const l = self.layout();
    // A cell tip is shown only if the same row is still under the point it
    // was hovered at: a re-sort or a refresh in the delay moves rows under a
    // still pointer, and the words would then describe a neighbour.
    if (t.isCell()) {
        const now = cellAt(self, l, self.help_pt.x, self.help_pt.y) orelse return;
        if (now.target != t or now.pid != self.help_pid) return;
    }

    var buf: [activity_help.max_len]u8 = undefined;
    const text = textFor(self, t, self.help_pid, &buf) orelse return;
    if (text.len == 0) return;
    const tip = ensure(self) orelse return;

    const gap: i32 = @intFromFloat(@round(4.0 * self.scale));
    var pt: w32.POINT = switch (t) {
        .badge => .{ .x = l.badge.left, .y = l.badge.bottom + gap },
        // Only reached while the checkbox is disabled (`comctlShows`).
        .show_all => .{ .x = l.show_all.left, .y = l.show_all.bottom + gap },
        .count => blk: {
            var cbuf: [64]u8 = undefined;
            const w = @min(measure(self, countLabel(self, &cbuf)), l.count.width());
            break :blk .{ .x = l.count.right - w, .y = l.count.bottom + gap };
        },
        // Under the hovered row, at its cell's text edge.
        .name_cell, .pane_cell, .path_cell => blk: {
            const idx = layout_mod.rowIndexAt(l, self.help_pt.y, self.scroll) orelse return;
            const row = layout_mod.rowRect(l, idx - self.scroll);
            const widths = layout_mod.columnWidths(self.scale, l.table.width());
            const col = ActivityMonitor.columnAt(l.table, widths, self.help_pt.x) orelse return;
            const cell = layout_mod.cellRect(row, widths, col, self.scale);
            break :blk .{ .x = cell.left, .y = row.bottom + gap };
        },
        else => return,
    };
    _ = w32.ClientToScreen(self.hwnd, &pt);
    if (!self.help_tip.showTrack(self.hwnd, tip, text, pt)) return;
    log.debug("activity help tooltip shown target={s}", .{t.kind()});
}
