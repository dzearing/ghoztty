//! The session roster's row plane (split out of `SessionRoster.zig` by
//! T1783): which sessions become visible rows and in what order, the alive
//! count and the listing log, and the window name / title / pane id a resumed
//! session gets back from the persisted layout.

const SessionRoster = @import("SessionRoster.zig");

const std = @import("std");
const builtin = @import("builtin");
const App = @import("App.zig");
const Window = @import("Window.zig");
const chooser_cpu = @import("chooser_cpu.zig");
const chooser_layout = @import("chooser_layout.zig");
const chooser_session_sort = @import("chooser_session_sort.zig");
const chooser_sessions = @import("chooser_sessions.zig");
const chrome_theme = @import("chrome_theme.zig");
const icon_button = @import("icon_button.zig");
const layout_blobs = @import("layout_blobs.zig");
const LocalAgent = @import("LocalAgent.zig");
const machine_pool = @import("machine_pool.zig");
const MachineConnectionPool = @import("MachineConnectionPool.zig");
const session_layout = @import("session_layout.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const remote_connection = @import("../../remote/connection.zig");
const w32 = @import("win32.zig");
const input_plane = @import("session_roster_input.zig");

const Allocator = SessionRoster.Allocator;
const Result = SessionRoster.Result;
const log = SessionRoster.log;
const testing = SessionRoster.testing;

// ---------------------------------------------------------------------
// The visible rows
// ---------------------------------------------------------------------

/// Cap on rendered roster rows. Bounds the fixed-size scratch every caller
/// keeps; a machine with more live sessions than this is not a case the
/// chooser's fixed 840x540 can show anyway.
pub const max_rows = 128;

pub const VisibleRow = struct {
    session: chooser_sessions.Session,
    /// This session's newest per-core CPU reading (T462), or null when the last
    /// pushed frame did not name it. Filled by the chooser from its
    /// `SessionCpuProbe` after `visible()` returns — the roster owns what a row
    /// SAYS, and the stream is a different subscription with a different
    /// lifetime.
    cpu: ?f32 = null,
    /// What one of OUR OPEN PANES calls this session (T710): the window's
    /// pinned title, the pane's own, and how many panes that pane's tab holds.
    /// All borrowed; the finished name is composed at the point of use, into the
    /// label buffer, because these row structs are copied and sorted and a
    /// composed slice into one of them could not survive the move.
    live: chooser_sessions.Live = .{},
    /// The saved layout title. Borrows the manifest.
    persisted_title: ?[]const u8 = null,
    open_locally: bool = false,
    /// Left over (T520): live on the LOCAL agent with no local pane holding it
    /// and no other viewer attached. Computed here, next to `open_locally`,
    /// because both answer against the live window set at build time.
    orphan: bool = false,
};

/// The rows worth rendering, in agent order: the sessions whose program is
/// still running (T1364 — a tombstone is not a row, relaunchable or not), minus
/// any held by a viewer that is not one of our panes (T1791,
/// `chooser_sessions.isActionable`), minus anything the user just killed. Fills
/// the caller's buffer and returns its filled prefix.
pub fn visible(self: *const SessionRoster, app: *App, out: []VisibleRow) []const VisibleRow {
    const roster = self.owned orelse return out[0..0];
    var n: usize = 0;
    for (roster.sessions) |s| {
        if (n >= out.len) break;
        const row: chooser_sessions.Session = .{
            .id = s.id,
            .alive = s.alive,
            .relaunchable = s.relaunchable,
            .exit_code = s.exit_code,
            .attached = s.attached,
            .activity = s.activity,
            .pid = s.pid,
            .title = s.title,
            .cwd = s.cwd,
            .argv = s.argv,
            .fg_cmd = s.fg_cmd,
        };
        if (!chooser_sessions.isConnectable(row)) continue;
        if (self.isKilled(s.id)) continue;

        // The live rung works for a remote machine too: a pane of ours attached
        // to one of ITS sessions carries that session's id. The layout rung used
        // to be local-only for a good reason — this box's saved layout says
        // nothing about another machine, and matching one would be a
        // coincidence — but since T1296 a remote roster carries the FAR
        // machine's own layout view, so the rung is answered from the right
        // record on both and a remote row is no longer nameless.
        const live = liveFor(app, s.id);
        // T1791: attached, and no pane of ours holds it — a pane just closed
        // (inside its undo window) or another viewer's. Not offered.
        if (!chooser_sessions.isActionable(row, live.open)) continue;
        out[n] = .{
            .session = row,
            .live = live,
            .persisted_title = self.persistedTitleFor(s.id),
            .open_locally = live.open,
            .orphan = chooser_sessions.orphaned(row, live.open, self.target == .local),
        };
        n += 1;
    }
    return out[0..n];
}

/// One sortable row: the row plus its resolved keys. The name slices may
/// point into the per-row label buffers; sorting moves these structs, never
/// the buffers, so the slices stay valid through the permutation.
pub const SortEntry = struct {
    row: VisibleRow,
    keys: chooser_session_sort.Keys,
};

pub fn entryLess(order: chooser_session_sort.Order, a: SortEntry, b: SortEntry) bool {
    return chooser_session_sort.less(order, a.keys, b.keys);
}

/// Sort `rows` in place for display (T602). The name key is the label the row
/// actually SHOWS — the user sorts by what they can read — and the CPU key the
/// whole percent its meter displays, both resolved ONCE per row here rather
/// than O(n log n) times in the comparator. Call after the CPU readings are
/// filled in: a CPU sort over unfilled rows would order every row as 0%.
pub fn sortRows(self: *const SessionRoster, rows: []VisibleRow) void {
    var bufs: [max_rows][chooser_sessions.max_live_title]u8 = undefined;
    var keyed: [max_rows]SortEntry = undefined;
    const n = @min(rows.len, max_rows);
    for (rows[0..n], 0..) |r, i| keyed[i] = .{
        .row = r,
        .keys = .{
            .name = chooser_sessions.label(&bufs[i], r.session, r.live, r.persisted_title),
            .cpu = chooser_session_sort.displayedCpu(r.cpu),
            .id = r.session.id,
        },
    };
    std.sort.pdq(SortEntry, keyed[0..n], self.sort, entryLess);
    for (keyed[0..n], 0..) |e, i| rows[i] = e.row;
}

/// How many of this machine's sessions are ALIVE — the datum "Restore All" is
/// gated on (`chooser_sessions.restoreAllAvailable`, T335). Counted off the same
/// set `visible` renders, so an optimistically-killed session is gone from both
/// and the button cannot outlive the rows that justify it. NOT capped at
/// `max_rows`: the gate is a property of the machine, not of what fits on
/// screen.
///
/// Since T1791 it counts what is OFFERED, as Mac's `highlightedAliveSessionCount`
/// counts its displayed (actionable) sessions: a session another viewer holds,
/// or one whose pane was just closed, is not a row, so it does not make two.
pub fn aliveCount(self: *const SessionRoster, app: *App) usize {
    const roster = self.owned orelse return 0;
    var n: usize = 0;
    for (roster.sessions) |s| {
        if (self.isKilled(s.id)) continue;
        // The same predicate `visible` keeps a row by, so this count and the
        // rendered list can no longer disagree.
        const row: chooser_sessions.Session = .{ .id = s.id, .alive = s.alive, .attached = s.attached };
        if (chooser_sessions.isActionable(row, liveFor(app, s.id).open)) n += 1;
    }
    return n;
}

/// Say the T520 mark out loud, once per adopted LOCAL roster: how many live
/// sessions no local pane holds. The rows are owner-drawn — there is no HWND to
/// read a badge back from — so this line is the acceptance oracle for the
/// "not in any window" mark, and it is said even at zero so a script can assert
/// the mark's absence as strongly as its presence.
pub fn logOrphans(self: *const SessionRoster, app: *App) void {
    if (self.target != .local) return;
    var rows: [max_rows]VisibleRow = undefined;
    var n: usize = 0;
    for (self.visible(app, &rows)) |r| {
        if (r.orphan) n += 1;
    }
    log.info("chooser roster: {d} session(s) not in any window", .{n});
}

/// Say what the roster is LISTING out loud, once per adopted roster: how many
/// rows it renders, and how many of the machine's sessions it left out because
/// their program has exited. Same reasoning as `logOrphans` — the rows are
/// owner-drawn, so there is no HWND to read the list back from — and NOT
/// local-only, because a relay machine's roster carries tombstones too.
///
/// This replaces T466's `can relaunch` oracle with the ABSENCE oracle T1364
/// needs: `hidden` is the count of finished sessions the agent reported and the
/// user is deliberately not offered, so a script can hold the agent's own
/// `+sessions --json` against it and prove the filter fired rather than that the
/// fixture happened to be empty.
pub fn logListed(self: *const SessionRoster, app: *App) void {
    var rows: [max_rows]VisibleRow = undefined;
    const shown = self.visible(app, &rows);
    const listed = shown.len;
    var hidden: usize = 0;
    // T1791: live sessions left out because a viewer that is not one of our
    // panes holds them (a pane just closed, or another machine's). Same absence
    // oracle as `hidden`, against the agent's own `attached`.
    var held: usize = 0;
    if (self.owned) |roster| {
        for (roster.sessions) |s| {
            if (self.isKilled(s.id)) continue;
            const row: chooser_sessions.Session = .{ .id = s.id, .alive = s.alive, .attached = s.attached };
            if (!chooser_sessions.isConnectable(row)) {
                hidden += 1;
            } else if (!chooser_sessions.isActionable(row, liveFor(app, s.id).open)) {
                held += 1;
            }
        }
    }
    log.info("chooser roster: listing {d} session(s), {d} exited hidden, {d} held elsewhere hidden", .{ listed, hidden, held });

    // Which chips each listed row wears (T1760), from the same `badges` call
    // the painter makes. Owner-drawn again: the only other way to see a chip is
    // a pixel scan, and the liveness dot shares the `open` chip's green.
    for (shown) |r| {
        var bbuf: [2]chooser_sessions.Badge = undefined;
        var ebuf: [32]u8 = undefined;
        var tbuf: [64]u8 = undefined;
        const run = chooser_sessions.badges(&bbuf, &ebuf, r.session, r.open_locally, r.orphan);
        log.info("chooser roster: row id={s} open={} badges={s}", .{
            r.session.id,
            r.open_locally,
            chooser_sessions.badgeList(&tbuf, run),
        });
    }

    // The rows one of OUR OWN PANES holds, by the NAME they show (T710). The
    // label ladder resolves at paint time out of borrowed titles, so there is
    // nothing to read back afterwards and no HWND to read it from — and the
    // rename this task exists for is invisible in every other line here: the
    // agent never learns a window was renamed, so a roster that is byte-identical
    // still renders a different name. Bounded to the rows we hold open, which is
    // the only set the question is about.
    for (shown) |r| {
        if (!r.live.open) continue;
        var lbuf: [chooser_sessions.max_live_title]u8 = undefined;
        log.info("chooser roster: open row id={s} name={s}", .{
            r.session.id,
            chooser_sessions.label(&lbuf, r.session, r.live, r.persisted_title),
        });
    }
}

/// What an OPEN pane bound to `id` calls it, with `open` false when no pane of
/// ours holds it. `open` is also the answer to "is this session open in one of
/// our windows", which is what turns the badge from `attached` (someone else
/// holds it) into `open` (you do).
///
/// The WINDOW's pinned title comes back alongside the pane's (T710) because a
/// rename is a statement about the window: reading the pane title alone left a
/// renamed window's row showing the old shell-derived name. `liveTitle` decides
/// which one a row actually says; this only finds them, plus the pane count its
/// tab holds, which is what makes the disambiguator rule answerable.
pub fn liveFor(app: *App, id: []const u8) chooser_sessions.Live {
    for (app.windows.items) |win| {
        for (0..win.tab_count) |t| {
            var it = win.tab_trees[t].iterator();
            while (it.next()) |entry| {
                // The LIVE id off the pane's remote backend, not the surface's
                // `remote_session_id` — that one is only set when a pane
                // ATTACHES to a restored session, so a freshly OPENed
                // persistent pane has none and every pane on screen would be
                // badged `attached` (someone else has it) instead of `open`
                // (you do). Same source `captureLeaf` writes the manifest from.
                const s2 = entry.view.surface() orelse continue;
                if (!s2.core_surface_ready) continue;
                const sid = s2.core_surface.remoteSessionId() orelse continue;
                if (!std.mem.eql(u8, sid, id)) continue;
                // An open pane with no title yet still means OPEN: `open` says
                // so on its own, and the ladder treats the empty name as an
                // absent rung and falls through to the next one.
                return .{
                    .window_title = win.title_override,
                    .pane_title = s2.title,
                    .pane_count = win.leafCount(t),
                    .open = true,
                };
            }
        }
    }
    return .{};
}

/// The layout views for the machine this roster is pointed at (T1296), most
/// trusted first: for the local one the on-disk manifest, then the blobs its
/// agent holds (T1318); for a remote one only the blobs pulled with the roster.
/// Either slot is empty when there is none — persistence off, a first run, an
/// agent too old to answer `GET_LAYOUTS`.
///
/// The manifest leads because this process wrote it, so where both know a
/// session it is the newer record. The agent's blobs are what is left of a
/// process that is gone, which is exactly the case an orphan comes from.
pub fn layoutViews(self: *const SessionRoster) [2][]const session_layout.Window {
    const blobs: []const session_layout.Window =
        if (self.layouts) |d| d.windows else &.{};
    if (self.target == .local) {
        const manifest: []const session_layout.Window =
            if (self.manifest) |p| p.value.windows else &.{};
        return .{ manifest, blobs };
    }
    return .{ blobs, &.{} };
}

pub const LeafRecord = struct {
    window: *const session_layout.Window,
    leaf: session_layout.Leaf,
};

/// The first layout record that names session `id`, searching the views in
/// `layoutViews` order. One lookup rather than a loop per question, because
/// every question asked of it ("what was this session's pane called", "what
/// did the user name the window it lived in") has the same answer shape on
/// both machines and only ever differed in where the record came from.
pub fn findLeaf(self: *const SessionRoster, id: []const u8) ?LeafRecord {
    for (self.layoutViews()) |view| {
        for (view) |*win| {
            for (win.tabs) |tab| {
                for (tab.nodes) |node| {
                    const leaf = node.leaf orelse continue;
                    const sid = leaf.session_id orelse continue;
                    if (std.mem.eql(u8, sid, id)) return .{ .window = win, .leaf = leaf };
                }
            }
        }
    }
    return null;
}

/// The name the user would recognise for the window `id` lived in, or null.
/// `pinned` distinguishes the two kinds, and the distinction is the whole point:
///
///   * **pinned** — the window's `title_override`: a name the USER typed, via
///     the rename dialog or `+rename`. It outranks anything the shell says, so a
///     resumed window takes it as a pin too.
///   * **not pinned** — the pane's last terminal-reported title. It is the best
///     label available, but it is the SHELL's to change: a resumed window shows
///     it and then lets the first title the live shell emits take over, exactly
///     as `App.restoreLeafPresentation` does for a full restore.
///
/// Collapsing the two would either freeze a shell title forever or let a shell
/// overwrite the name the user chose, and both have a user-visible symptom.
pub const WindowName = struct {
    text: []const u8,
    pinned: bool,
    /// A pinned name the user typed (T2404): it comes back as theirs, so a
    /// script's `+rename` still leaves it.
    by_user: bool = false,
};

pub fn persistedWindowNameFor(self: *const SessionRoster, id: []const u8) ?WindowName {
    const rec = self.findLeaf(id) orelse return null;
    if (rec.window.title_override) |t| {
        if (t.len > 0) return .{ .text = t, .pinned = true, .by_user = rec.window.title_set_by_user orelse false };
    }
    if (rec.leaf.title) |t| {
        if (t.len > 0) return .{ .text = t, .pinned = false };
    }
    return null;
}

pub fn persistedTitleFor(self: *const SessionRoster, id: []const u8) ?[]const u8 {
    const rec = self.findLeaf(id) orelse return null;
    return rec.leaf.title;
}

/// The pane id the saved layout recorded for `id`, or null. A resumed pane
/// re-adopts it (T113): the shell we are ATTACHing to is still running with
/// that value baked into `$GHOZTTY_PANE_ID`, so handing it a fresh one would
/// break the pane's ability to name itself.
///
/// Both machines (T1317): a REMOTE session's shell carries the id the FAR
/// machine's pane gave it, so the answer comes from that machine's layout view,
/// the same source `persistedWindowNameFor` reads. A LOCAL one falls back from
/// the manifest to the agent's blobs the same way that does (T1318).
pub fn persistedPaneIdFor(self: *const SessionRoster, id: []const u8) ?[]const u8 {
    const rec = self.findLeaf(id) orelse return null;
    return rec.leaf.pane_id;
}

test "sortRows: the displayed order follows the active column, ties by name then id" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();

    var rows = [_]VisibleRow{
        .{ .session = .{ .id = "3", .alive = true, .title = "zeta" }, .cpu = 2.4 },
        .{ .session = .{ .id = "1", .alive = true, .title = "alpha" }, .cpu = 90.0 },
        .{ .session = .{ .id = "2", .alive = true, .title = "Beta" }, .cpu = null },
    };

    // The initial order: Name, A→Z, case-insensitively — what the user READS.
    roster.sort = chooser_session_sort.initial;
    roster.sortRows(&rows);
    try testing.expectEqualStrings("1", rows[0].session.id);
    try testing.expectEqualStrings("2", rows[1].session.id);
    try testing.expectEqualStrings("3", rows[2].session.id);

    // CPU busiest-first; a blank meter sorts as 0.
    roster.sort = .{ .key = .cpu, .ascending = false };
    roster.sortRows(&rows);
    try testing.expectEqualStrings("1", rows[0].session.id);
    // 2.4 displays as 2%, beating the blank 0% — and the blank row is last.
    try testing.expectEqualStrings("3", rows[1].session.id);
    try testing.expectEqualStrings("2", rows[2].session.id);

    // Rows whose meters DISPLAY the same number tie, and the tie falls to the
    // name regardless of direction — sub-point jitter cannot reshuffle them.
    var jitter = [_]VisibleRow{
        .{ .session = .{ .id = "b", .alive = true, .title = "bravo" }, .cpu = 16.6 },
        .{ .session = .{ .id = "a", .alive = true, .title = "alpha" }, .cpu = 17.4 },
    };
    roster.sortRows(&jitter);
    try testing.expectEqualStrings("a", jitter[0].session.id);
    roster.sort = .{ .key = .cpu, .ascending = true };
    roster.sortRows(&jitter);
    try testing.expectEqualStrings("a", jitter[0].session.id);
}

// ---------------------------------------------------------------------
// T1296: the window name a resumed session gets back
// ---------------------------------------------------------------------

/// A decoded layout view standing in for what a remote fetch would have pulled:
/// one window with a user-set name over two panes, and one with none.
pub fn testLayoutsPayload(alloc: Allocator) ![]u8 {
    const win_named =
        \\{"id":"w0","ipc_name":"deploy","title_override":"Deploy watch",
        \\ "active_tab":0,"tabs":[{"nodes":[
        \\   {"leaf":{"session_id":"aaaa","title":"pwsh"}}],"active":true}]}
    ;
    const win_plain =
        \\{"id":"w1","active_tab":0,"tabs":[{"nodes":[
        \\   {"leaf":{"session_id":"bbbb","title":"build log"}},
        \\   {"leaf":{"session_id":"cccc"}}],"active":true}]}
    ;
    return std.fmt.allocPrint(
        alloc,
        "{{\"layouts\":[{{\"key\":\"k0\",\"blob\":{f}}},{{\"key\":\"k1\",\"blob\":{f}}}]}}",
        .{ std.json.fmt(win_named, .{}), std.json.fmt(win_plain, .{}) },
    );
}

test "a remote roster names a resumed window from the FAR machine's layout view (T1296)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.target = .{ .remote = "dev-remote" };

    const payload = try testLayoutsPayload(alloc);
    defer alloc.free(payload);
    roster.layouts = try layout_blobs.decodeLayouts(alloc, payload);

    // The user's own name for the window wins, and says so: a resume applies it
    // as a PIN, so the shell cannot overwrite it a second later.
    const named = roster.persistedWindowNameFor("aaaa").?;
    try testing.expectEqualStrings("Deploy watch", named.text);
    try testing.expect(named.pinned);

    // No name of the user's: the pane's own title is the best label there is,
    // and it is NOT pinned - the live shell's next title takes over.
    const shell = roster.persistedWindowNameFor("bbbb").?;
    try testing.expectEqualStrings("build log", shell.text);
    try testing.expect(!shell.pinned);

    // A leaf with neither, and a session no record mentions, are both "no name"
    // rather than an empty one - the resume then leaves the window alone.
    try testing.expect(roster.persistedWindowNameFor("cccc") == null);
    try testing.expect(roster.persistedWindowNameFor("zzzz") == null);
}

test "leaving a machine drops its layout view with its rows (T1296)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.target = .{ .remote = "dev-remote" };

    const payload = try testLayoutsPayload(alloc);
    defer alloc.free(payload);
    roster.layouts = try layout_blobs.decodeLayouts(alloc, payload);
    try testing.expect(roster.persistedWindowNameFor("aaaa") != null);

    // Otherwise the NEXT machine's session ids would match these records by
    // coincidence and a window would be named after somebody else's work.
    roster.clear();
    try testing.expect(roster.layouts == null);
    try testing.expect(roster.persistedWindowNameFor("aaaa") == null);
}

test "a failed layout pull keeps the names the last fetch landed (T1296)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.target = .{ .remote = "dev-remote" };
    roster.serial = 3;

    const payload = try testLayoutsPayload(alloc);
    defer alloc.free(payload);
    var first: Result = .{
        .alloc = alloc,
        .chooser_id = 1,
        .serial = 3,
        .roster = null,
        .layouts = try layout_blobs.decodeLayouts(alloc, payload),
    };
    defer if (first.layouts) |d| d.deinit();
    try testing.expect(roster.adopt(&first));
    try testing.expect(roster.persistedWindowNameFor("aaaa") != null);

    // A refetch whose GET_LAYOUTS did not answer: the rows must not all lose
    // their names because one RPC of one fetch missed.
    var second: Result = .{
        .alloc = alloc,
        .chooser_id = 1,
        .serial = 3,
        .roster = null,
        .layouts = null,
    };
    try testing.expect(roster.adopt(&second));
    try testing.expectEqualStrings("Deploy watch", roster.persistedWindowNameFor("aaaa").?.text);
}

test "the LOCAL arm answers the same question from this box's manifest (T1296)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.target = .local;

    const body =
        \\{"version":1,"windows":[{"id":"w0","title_override":"Deploy watch",
        \\ "active_tab":0,"tabs":[{"nodes":[
        \\   {"leaf":{"session_id":"aaaa","title":"pwsh"}}],"active":true}]},
        \\ {"id":"w1","active_tab":0,"tabs":[{"nodes":[
        \\   {"leaf":{"session_id":"bbbb","title":"build log"}}],"active":true}]}]}
    ;
    roster.manifest = try session_layout.parse(alloc, body);

    // Same two answers as the remote arm, from the record this box keeps on
    // disk: a resumed LOCAL session is named too, which is the half a user hits
    // after relaunching the app and resuming an orphan.
    const named = roster.persistedWindowNameFor("aaaa").?;
    try testing.expectEqualStrings("Deploy watch", named.text);
    try testing.expect(named.pinned);
    const shell = roster.persistedWindowNameFor("bbbb").?;
    try testing.expectEqualStrings("build log", shell.text);
    try testing.expect(!shell.pinned);
    try testing.expect(roster.persistedWindowNameFor("zzzz") == null);
}

test "a remote roster hands a resumed pane the FAR machine's pane id (T1317)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.target = .{ .remote = "dev-remote" };

    const blob =
        \\{"id":"w0","active_tab":0,"tabs":[{"nodes":[
        \\   {"leaf":{"session_id":"aaaa","pane_id":"1E5F0A2C-3D4B-4A6E-8F90-ABCDEF012345"}},
        \\   {"leaf":{"session_id":"bbbb"}}],"active":true}]}
    ;
    const payload = try std.fmt.allocPrint(
        alloc,
        "{{\"layouts\":[{{\"key\":\"k0\",\"blob\":{f}}}]}}",
        .{std.json.fmt(blob, .{})},
    );
    defer alloc.free(payload);
    roster.layouts = try layout_blobs.decodeLayouts(alloc, payload);

    // The far shell was baked with this id; the resumed pane answers to it.
    try testing.expectEqualStrings(
        "1E5F0A2C-3D4B-4A6E-8F90-ABCDEF012345",
        roster.persistedPaneIdFor("aaaa").?,
    );
    // A leaf that recorded none, and a session no record mentions, mint fresh.
    try testing.expect(roster.persistedPaneIdFor("bbbb") == null);
    try testing.expect(roster.persistedPaneIdFor("zzzz") == null);

    // And leaving the machine forgets them with its rows.
    roster.clear();
    try testing.expect(roster.persistedPaneIdFor("aaaa") == null);
}

test "a LOCAL orphan the rewritten manifest forgot is named from the agent's blobs (T1318)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.target = .local;

    // The relaunch that left the orphan rebuilt nothing, so its manifest holds
    // only the one window it opened - a different session, named differently
    // from the agent's record of it so the precedence below is observable.
    const body =
        \\{"version":1,"windows":[{"id":"w9","title_override":"Fresh window",
        \\ "active_tab":0,"tabs":[{"nodes":[
        \\   {"leaf":{"session_id":"bbbb","title":"pwsh","pane_id":"p-new"}}],"active":true}]}]}
    ;
    roster.manifest = try session_layout.parse(alloc, body);
    const payload = try testLayoutsPayload(alloc);
    defer alloc.free(payload);
    roster.layouts = try layout_blobs.decodeLayouts(alloc, payload);

    // The orphan lives only in the dead process's blob: the name it was given
    // there still reaches the window a resume builds, pinned.
    const named = roster.persistedWindowNameFor("aaaa").?;
    try testing.expectEqualStrings("Deploy watch", named.text);
    try testing.expect(named.pinned);

    // Where both records know a session, the manifest this process wrote wins.
    const fresh = roster.persistedWindowNameFor("bbbb").?;
    try testing.expectEqualStrings("Fresh window", fresh.text);
    try testing.expectEqualStrings("p-new", roster.persistedPaneIdFor("bbbb").?);
    try testing.expect(roster.persistedWindowNameFor("zzzz") == null);
}
