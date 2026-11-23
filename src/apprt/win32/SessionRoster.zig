//! The machine chooser's session roster: the RPC, the state, and the painting
//! of the detail pane's per-session list (T318).
//!
//! `chooser_sessions.zig` holds everything pure about a roster row — the label
//! ladder, the connectable filter, the badges and the card geometry — and is
//! unit-tested in the none-runtime lane. This file is what that geometry is
//! drawn with, plus the part that cannot be pure: a blocking `LIST_SESSIONS`
//! against the local agent.
//!
//! ## Threading (inherited from T295, non-negotiable)
//!
//! The RPC blocks — dial, request, wait. It runs on a DETACHED THREAD and posts
//! its outcome back to the GUI thread as a `*Result`, which the handler owns
//! from that moment. A reply that lands after its chooser closed FREES what it
//! fetched instead of adopting it, which is why the message lands on the app's
//! message-only window and not on the chooser's HWND: `DestroyWindow` discards
//! a window's queued messages, and a discarded reply would leak a roster and,
//! on the probe path, a whole connection.
//!
//! A failed or slow fetch is a state OF THE REGION — never a modal, never a
//! blocked chooser.

const SessionRoster = @This();

const std = @import("std");
const builtin = @import("builtin");
pub const Allocator = std.mem.Allocator;

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

pub const log = std.log.scoped(.win32);

// -------------------------------------------------------------------------
// Split modules (T1775)
// -------------------------------------------------------------------------
//
// This file is the roster: its state, the fetch and its adoption, and the
// optimistic kill set. The planes below used to live inline here (T1783);
// each is imported back as method-call aliases so every `self.f(x)` and
// `SessionRoster.f` call site reads as it always did. The aliases are the
// planes' public surface: a function the chooser calls is a function a plane
// promised, listed here in one place.

const input_plane = @import("session_roster_input.zig");
pub const layoutRow = input_plane.layoutRow;
pub const actionAt = input_plane.actionAt;
pub const killAt = input_plane.killAt;
pub const rowAt = input_plane.rowAt;
pub const cpuAt = input_plane.cpuAt;
pub const hasCursor = input_plane.hasCursor;
pub const cursorId = input_plane.cursorId;
pub const setCursor = input_plane.setCursor;
pub const clearCursor = input_plane.clearCursor;
pub const cursorIndex = input_plane.cursorIndex;
pub const enterCursor = input_plane.enterCursor;
pub const moveCursor = input_plane.moveCursor;
pub const scrollToCursor = input_plane.scrollToCursor;
pub const clampScrollTo = input_plane.clampScrollTo;
pub const scrollBy = input_plane.scrollBy;

const rows_plane = @import("session_roster_rows.zig");
pub const max_rows = rows_plane.max_rows;
pub const VisibleRow = rows_plane.VisibleRow;
pub const visible = rows_plane.visible;
pub const SortEntry = rows_plane.SortEntry;
pub const entryLess = rows_plane.entryLess;
pub const sortRows = rows_plane.sortRows;
pub const aliveCount = rows_plane.aliveCount;
pub const logOrphans = rows_plane.logOrphans;
pub const logListed = rows_plane.logListed;
pub const liveFor = rows_plane.liveFor;
pub const layoutViews = rows_plane.layoutViews;
pub const LeafRecord = rows_plane.LeafRecord;
pub const findLeaf = rows_plane.findLeaf;
pub const WindowName = rows_plane.WindowName;
pub const persistedWindowNameFor = rows_plane.persistedWindowNameFor;
pub const persistedTitleFor = rows_plane.persistedTitleFor;
pub const persistedPaneIdFor = rows_plane.persistedPaneIdFor;
pub const testLayoutsPayload = rows_plane.testLayoutsPayload;

const paint_plane = @import("session_roster_paint.zig");
pub const PaintCtx = paint_plane.PaintCtx;
pub const rgb = paint_plane.rgb;
pub const rect = paint_plane.rect;
pub const contentHeight = paint_plane.contentHeight;
pub const paint = paint_plane.paint;
pub const HeaderZones = paint_plane.HeaderZones;
pub const headerZones = paint_plane.headerZones;
pub const headerKeyAt = paint_plane.headerKeyAt;
pub const paintHeader = paint_plane.paintHeader;
pub const drawChevron = paint_plane.drawChevron;
pub const paintRow = paint_plane.paintRow;
pub const drawAction = paint_plane.drawAction;
pub const drawCpuMeter = paint_plane.drawCpuMeter;
pub const cpuRect = paint_plane.cpuRect;
pub const drawKill = paint_plane.drawKill;
pub const fillRound = paint_plane.fillRound;
pub const drawDot = paint_plane.drawDot;
pub const measure = paint_plane.measure;
pub const drawText = paint_plane.drawText;
pub const drawTextPathEllipsis = paint_plane.drawTextPathEllipsis;
pub const drawTextCentered = paint_plane.drawTextCentered;
pub const drawWith = paint_plane.drawWith;

// (end of split modules)

/// A finished roster fetch, in flight to the GUI thread. Follows the
/// `ActivityMonitor.DialResult` shape: heap-allocated by the worker, owned by
/// the handler.
pub const WM_APP_CHOOSER_SESSIONS: u32 = w32.WM_APP + 16;

/// How long the RPC may take before it resolves to `failed`. Generous enough
/// for a busy agent, short enough that a wedged one does not leave the region
/// spinning for the length of the dialog.
const rpc_timeout_ns: u64 = 5 * std.time.ns_per_s;

/// Session ids are 32 hex chars on the wire; the buffer is the cap on what an
/// optimistic hide can remember, not a protocol constant.
pub const max_id_len = 64;
/// How many just-killed ids are hidden at once. A user killing more sessions
/// than this in one undo window is not a case worth growing state for — the
/// refetch drops them anyway.
const max_killed = 16;

// ---------------------------------------------------------------------
// State (GUI thread only)
// ---------------------------------------------------------------------

/// Everything needed to reach a REMOTE machine's agent. There is no new RPC on
/// this path — `Connection.requestSessions` is transport-agnostic
/// (`connection.zig:1598`), which is Mac's own claim about it
/// (`SessionBrowserProbe.swift:93-96`) — so the whole remote half of this file
/// is the connection and who owns it.
///
/// Since T461 that owner is `App.machine_pool`: this roster BORROWS the
/// machine's one warm connection for the length of an RPC instead of dialing its
/// own and freeing it per fetch. The credentials are still carried here because
/// the pool needs them to dial (a token can rotate; it is not part of the
/// endpoint's identity).
pub const Remote = struct {
    /// The relay HTTPS base (an `http://` base is a loopback test relay).
    base: []const u8,
    /// The enrolled device id.
    device: []const u8,
    /// The bearer the relay authenticates with.
    token: []const u8,
};

alloc: Allocator,
state: chooser_sessions.State = .loading,
/// Which machine these sessions belong to (T319). Every fetch, adopt and paint
/// is about THIS target; moving it resets the region, because machine A's
/// sessions under machine B's name is the one thing worse than an empty pane.
target: chooser_sessions.Target = .none,
/// Relay credentials for a `.remote` target, BORROWED from the chooser (its
/// arena and its device listing both outlive the roster). Null for `.local`.
remote: ?Remote = null,
/// The fetched roster. Owned; freed here and replaced whole by each adopt.
owned: ?remote_connection.OwnedSessions = null,
/// Bumped on every fetch. A reply carrying an older serial is stale — its
/// chooser has moved on — and is freed rather than adopted.
serial: u64 = 0,
inflight: bool = false,
/// Whether this roster has already condemned a pooled connection and asked for a
/// fresh dial since the last roster it managed to load (T859). The retry is
/// SINGLE-SHOT for exactly the reason it is allowed to skip the pool's redial
/// cooldown: one dial per proven-dead connection is a recovery, and an
/// unbounded chain of them — dial, RPC, die, dial — is a dial storm. Cleared by
/// a fetch that lands, so a machine that comes back is recoverable again.
redialed: bool = false,
scroll: i32 = 0,
/// Index (into the VISIBLE rows) whose Kill button is under the pointer, or -1.
hover_kill: i32 = -1,
/// Index (into the VISIBLE rows) whose Show / Resume button is under the
/// pointer, or -1 (T1746).
hover_action: i32 = -1,
/// The measured caption width of the widest action label ("Resume"), set by the
/// chooser from the font the button is painted in. 0 until measured, which
/// places no button — the layout module is text-free, so the width comes in
/// from the one place that owns the font (the T235 rule).
action_text_w: i32 = 0,
/// How the displayed rows are ordered (T602). Loaded from the persisted
/// preference when the chooser opens; saved when a column header is clicked.
sort: chooser_session_sort.Order = chooser_session_sort.initial,
/// The keyboard sub-cursor (T320): the SESSION ID it is anchored to, empty
/// when the machine row itself is highlighted and the roster is not being
/// navigated. An ID rather than an index since T602, because the list
/// re-sorts underneath it — a header click, or a live CPU tick while sorted
/// by CPU — and an index would silently re-point at whatever slid into that
/// slot. Resolved to an index against the DISPLAYED rows at every use.
cursor_id: [max_id_len]u8 = undefined,
cursor_id_len: usize = 0,

/// Sessions the user just killed, hidden optimistically so the row vanishes at
/// once instead of lingering — and degrading to a "pid" label — during the
/// close's undo window while the agent still lists it. Cleared when a refetch
/// confirms they are gone.
killed: [max_killed][max_id_len]u8 = undefined,
killed_len: [max_killed]usize = @splat(0),
killed_count: usize = 0,

/// The saved session-layout manifest, loaded once when the chooser opens, for
/// the `persisted_title` rung of the label ladder. Null when there is no
/// manifest (persistence off, or a first run).
manifest: ?session_layout.Parsed = null,

/// The machine's AGENT-side layout view (T1296): the blobs its agent holds,
/// pulled with the roster and decoded into the same `session_layout.Window`
/// shape the local manifest parses to. Null whenever the pull failed.
///
/// For a remote target it is the only layout view there is. For the local one
/// it backs up the manifest above (T1318): the shape that leaves an orphan to
/// resume is a launch that rebuilt nothing, and that launch rewrites the
/// manifest with the windows it DID open — so the dead process's record of the
/// orphan's window survives only in the blob it pushed to the agent.
///
/// Why the roster carries it at all: everything a row can SAY about a session
/// beyond its id — the window it belonged to, the name the user gave that
/// window, the pane's own title — lives in the layout record and NOWHERE on the
/// wire (`LIST_SESSIONS` has a `title` field but no agent ever fills it in). A
/// remote row was therefore anonymous, and so was the window a resume built
/// from it, which is exactly what the user reported.
layouts: ?layout_blobs.Decoded = null,

/// Whether the CPU meter's column is reserved in every row (T462). A statement
/// about the MACHINE — its agent advertised `session_cpu` and a subscription is
/// live on it — set by the chooser from its probe, and read by every geometry
/// call here so the paint and the hit tests cannot disagree about where a row's
/// title starts.
cpu_column: bool = false,

pub fn init(alloc: Allocator) SessionRoster {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *SessionRoster) void {
    if (self.owned) |*o| o.deinit();
    self.owned = null;
    if (self.manifest) |*m| m.deinit();
    self.manifest = null;
    self.dropLayouts();
}

fn dropLayouts(self: *SessionRoster) void {
    if (self.layouts) |d| d.deinit();
    self.layouts = null;
}

/// Load the session-layout manifest for the persisted-title rung. Best effort:
/// a missing or malformed manifest simply removes one rung from the ladder.
pub fn loadManifest(self: *SessionRoster) void {
    if (comptime builtin.os.tag != .windows) return;
    const path = session_layout.layoutPath(self.alloc) orelse return;
    defer self.alloc.free(path);
    self.manifest = session_layout.load(self.alloc, path) catch null;
}

// ---------------------------------------------------------------------
// The fetch (worker thread)
// ---------------------------------------------------------------------

const Request = struct {
    alloc: Allocator,
    hwnd: w32.HWND,
    chooser_id: u64,
    serial: u64,
    /// The agent connection this RPC rides, borrowed. Never freed here: for the
    /// LOCAL target it is owned by `LocalAgent` for the app's lifetime (and a
    /// retired one is kept alive precisely so a borrow like this can never
    /// dangle), and for a REMOTE target it belongs to `entry` below.
    warm: ?*remote_connection.Connection,
    /// A session to END before listing, for the Kill path. Owned.
    kill_id: ?[]u8,
    /// The pooled connection's refcount ticket for a REMOTE target (T461). Held
    /// for the whole blocking call and given back on the way out, which is what
    /// makes it safe for the last lease to drop mid-RPC: the pool's own
    /// reference can go while this one keeps the transport alive.
    entry: ?*MachineConnectionPool.Entry = null,
    /// Pull the machine's layout blobs alongside the roster (T1296; the local
    /// target too since T1318, as the fallback behind its on-disk manifest).
    want_layouts: bool = false,
    /// `entry`'s pool-wide id, carried by VALUE so the reply can name the
    /// connection this fetch actually used (T859) without dereferencing an entry
    /// the pool may have dropped in the meantime. Zero for a local fetch.
    entry_id: u64 = 0,

    fn destroy(self: *Request) void {
        if (self.kill_id) |k| self.alloc.free(k);
        if (self.entry) |e| e.release();
        self.alloc.destroy(self);
    }
};

pub const Result = struct {
    alloc: Allocator,
    chooser_id: u64,
    serial: u64,
    /// The fetched roster, or null when the RPC failed / no agent answered.
    roster: ?remote_connection.OwnedSessions,
    /// Whether a requested Kill was confirmed by the agent. Null when this
    /// fetch did not carry one.
    killed_ok: ?bool = null,
    /// The machine's decoded layout blobs (T1296), or null when the pull was
    /// not asked for or did not land. A failed pull is not a failed fetch: the
    /// rows are still worth showing, they just cannot name their windows.
    layouts: ?layout_blobs.Decoded = null,
    /// The POOLED connection this fetch proved unusable, by id (T859), or zero
    /// when the fetch either worked or failed for a reason that says nothing
    /// about the transport. `retryDeadPool` is what acts on it.
    dead_entry: u64 = 0,

    pub fn destroy(self: *Result) void {
        if (self.roster) |*r| r.deinit();
        if (self.layouts) |d| d.deinit();
        self.alloc.destroy(self);
    }
};

/// Point the roster at a machine (T319) and fetch if the move calls for it.
/// `remote` carries the relay credentials for a `.remote` target and is ignored
/// otherwise; it is BORROWED — the worker deep-copies what it needs.
///
/// Returns true when the region changed and the caller should repaint.
pub fn show(
    self: *SessionRoster,
    app: *App,
    chooser_id: u64,
    target: chooser_sessions.Target,
    remote: ?Remote,
) bool {
    switch (chooser_sessions.transitionFor(self.target, target, self.state, self.inflight)) {
        .nothing => return false,
        .reset => {
            self.clear();
            self.target = target;
            self.remote = null;
            return true;
        },
        .reset_and_fetch => {
            self.clear();
            self.target = target;
            self.remote = if (target == .remote) remote else null;
            self.fetch(app, chooser_id, null);
            return true;
        },
        .refresh_in_place => {
            // Same machine: keep the rows AND the credentials, and refetch
            // without touching `state` (`fetch` only moves to `loading` when
            // there is nothing to show).
            self.fetch(app, chooser_id, null);
            return false;
        },
    }
}

/// Drop everything that belongs to the machine we are leaving. Not optional:
/// the rows, the scroll offset and the optimistic kill hides are all statements
/// about a specific agent.
pub fn clear(self: *SessionRoster) void {
    if (self.owned) |*o| o.deinit();
    self.owned = null;
    // The layout view is a statement about the machine we are leaving, exactly
    // like the rows: keeping it would let the new machine's session ids match
    // the OLD one's records by coincidence and name a window after somebody
    // else's work.
    self.dropLayouts();
    self.state = .loading;
    self.scroll = 0;
    self.hover_kill = -1;
    self.hover_action = -1;
    // The cursor belongs to the roster it was pointing at: a new machine's
    // rows are not the rows the user was walking (Mac clears `browseCursor`
    // on every highlight move, `MachineChooserView.swift:1328`).
    self.cursor_id_len = 0;
    self.killed_count = 0;
    // A different machine's dead connection is not this one's (T859).
    self.redialed = false;
    // Bump the serial so a reply already in flight for the OLD machine is
    // dropped instead of adopted under the new machine's name.
    self.serial +%= 1;
    self.inflight = false;
}

/// Start a roster fetch (optionally ending `kill_id` first) on a detached
/// thread. `chooser_id` identifies the chooser the reply belongs to; the reply
/// is matched on it, never on a pointer, so a chooser that closed in the
/// meantime cannot be written through.
///
/// Resolving the connection happens HERE, on the GUI thread, because that is
/// where the state that owns it lives. The blocking part is all the worker does.
///
/// For the LOCAL target: the app's warm `LocalAgent` connection, or — when there
/// is none — a probe dial of the agent that is ALREADY running, freed afterwards.
/// Browsing must never SPAWN an agent.
///
/// For a REMOTE target: a BORROW of the machine's pooled warm connection (T461).
/// A machine with no warm connection is not dialed from here at all — the pool
/// owns dialing, and the lease's notification is what refetches once it lands.
/// That is the whole point of the pool: before it, every fetch dialed the relay
/// and freed it again, so N refetches cost N WebSocket upgrades and N relay
/// authentications, and nothing could subscribe to anything.
pub fn fetch(
    self: *SessionRoster,
    app: *App,
    chooser_id: u64,
    kill_id: ?[]const u8,
) void {
    if (comptime builtin.os.tag != .windows) return;
    if (self.target == .none) return;
    const msg_hwnd = app.msg_hwnd orelse {
        self.state = .failed;
        return;
    };

    self.serial +%= 1;
    if (self.owned == null) self.state = .loading;

    const req = self.alloc.create(Request) catch {
        self.state = .failed;
        return;
    };
    req.* = .{
        .alloc = self.alloc,
        .hwnd = msg_hwnd,
        .chooser_id = chooser_id,
        .serial = self.serial,
        // A remote target never borrows the local agent's connection — that
        // would silently list THIS box's sessions under another machine's name.
        // T1589: a WEDGED shared link is worse than no link here. `warm` null
        // sends the worker down the probe-dial path below, which talks to the
        // agent that is already running — and when it was the transport that
        // failed rather than the agent, that probe answers immediately where
        // the wedged link would have burned `rpc_timeout_ns` and reported
        // nothing.
        .warm = if (self.target == .local) app.local_agent.sharedConnectionIfLive() else null,
        .kill_id = null,
        // T1296: a remote machine's layout view has to be asked for. The local
        // one is on this box's disk, but asked for as well (T1318): an orphan's
        // window is usually missing from a manifest the relaunch rewrote.
        .want_layouts = true,
    };
    if (self.target == .remote) {
        // No credential at all is the signed-out case, and it gets the SAME
        // actionable sentence a rejected one does — "couldn't reach it" would
        // send the user looking at the network.
        const ep = self.endpoint() orelse {
            req.destroy();
            self.state = .unauthorized;
            return;
        };
        if (app.machine_pool.borrow(ep)) |entry| {
            req.entry = entry;
            req.entry_id = entry.id;
            req.warm = entry.conn();
        } else {
            // Not warm. The pool is already dialing (the chooser's lease started
            // one) unless the last attempt failed, in which case this asks for a
            // retry — bounded by the pool's own cooldown, so a refetch storm
            // cannot become a dial storm. Either way the answer arrives as a
            // lease notification, so leave the region as it is rather than
            // reporting a failure this fetch did not observe.
            app.machine_pool.ensureConnected(msg_hwnd, ep);
            if (kill_id != null) log.warn(
                "chooser roster: kill dropped — no warm connection to {s}",
                .{self.targetDevice()},
            );
            req.destroy();
            return;
        }
    }
    if (kill_id) |k| {
        req.kill_id = self.alloc.dupe(u8, k) catch {
            req.destroy();
            self.state = .failed;
            return;
        };
    }

    const thread = std.Thread.spawn(.{}, worker, .{req}) catch |err| {
        log.warn("chooser roster: fetch thread spawn failed err={}", .{err});
        req.destroy();
        self.state = .failed;
        return;
    };
    thread.detach();
    self.inflight = true;
}

fn worker(req: *Request) void {
    defer req.destroy();
    const alloc = req.alloc;

    var probe: ?tcp_dial.Dialed = null;
    const conn: ?*remote_connection.Connection = req.warm orelse blk: {
        // No warm connection: dial the agent that is ALREADY running. Never
        // spawn one — browsing a roster must not start a daemon. Only the LOCAL
        // target ever gets here; a remote fetch without a pooled connection is
        // refused before the thread is spawned.
        probe = LocalAgent.dialProbe(alloc);
        break :blk if (probe) |p| p.conn else null;
    };
    defer if (probe) |*p| p.deinit();

    var killed_ok: ?bool = null;
    var roster: ?remote_connection.OwnedSessions = null;
    var layouts: ?layout_blobs.Decoded = null;
    // The pooled connection this fetch disproved, reported back so the GUI
    // thread can condemn it and redial (T859).
    var dead_entry: u64 = 0;
    if (conn) |c| {
        if (req.kill_id) |id| {
            killed_ok = c.closeSession(id, rpc_timeout_ns) catch |err| ok: {
                // `error.Unsupported` is an OLDER AGENT, not a failure to
                // report: the capability was never advertised, so the button
                // should have been disabled. Logged, reported as not-killed.
                log.warn("chooser roster: close session failed err={}", .{err});
                break :ok false;
            };
        }
        roster = c.requestSessions(rpc_timeout_ns) catch |err| r: {
            log.warn("chooser roster: LIST_SESSIONS failed err={}", .{err});
            if (req.entry_id != 0 and connectionGone(c, err)) dead_entry = req.entry_id;
            break :r null;
        };
        // T1296: the machine's own layout view, on the same connection and the
        // same thread. Best effort in both directions — an agent too old to
        // answer, or a payload we cannot read, costs the rows their window names
        // and nothing else.
        if (req.want_layouts) {
            if (c.requestLayouts(rpc_timeout_ns)) |payload| {
                defer alloc.free(payload);
                layouts = layout_blobs.decodeLayouts(alloc, payload) catch |err| d: {
                    log.warn("chooser roster: layouts payload unreadable err={}", .{err});
                    break :d null;
                };
            } else |err| {
                log.warn("chooser roster: GET_LAYOUTS failed err={}", .{err});
            }
        }
    }
    // T859 (resolved, and the mechanism is above): a pooled connection that
    // died is now CONDEMNED by the fetch that discovered it — `dead_entry` names
    // it, `retryDeadPool` asks the pool to replace it, and the pool's own dial
    // (bounded end to end since T510) is the fresh one the retry rides. The
    // worker deliberately does not dial anything itself: the pool owns dialing,
    // so a connection made here would heal this one fetch and leave the dead
    // entry installed for the next one, re-paying a relay upgrade every time —
    // the exact cost T461 removed.
    //
    // T328 (resolved): a Kill on a REMOTE row used to lose its connection here
    // — both RPCs came back `error.ConnectionClosed`/`error.Timeout` — but the
    // defect was never in this worker: the agent's per-connection push pumps
    // could outlive their connection and write freed memory (fixed alongside
    // T420), and each roster dial/deinit cycle armed exactly that window. T461
    // removed the cycle itself: a remote fetch now borrows one pooled
    // connection, so there is no per-fetch dial left to arm anything. A
    // retry-on-fresh-dial was tried here once and WEDGED the worker —
    // `relay_dial.dial`'s upgrade read had no deadline at the time; T510 has
    // since bounded every phase of the dial (upgrade + HELLO), so a redial can
    // no longer park this thread, but the pooled design stands on its own
    // merits. `chooser-sessions-remote.ps1` asserts the refetch lands.

    const res = alloc.create(Result) catch {
        if (roster) |*r| r.deinit();
        if (layouts) |d| d.deinit();
        return;
    };
    res.* = .{
        .alloc = alloc,
        .chooser_id = req.chooser_id,
        .serial = req.serial,
        .roster = roster,
        .killed_ok = killed_ok,
        .layouts = layouts,
        .dead_entry = dead_entry,
    };
    if (w32.PostMessageW(req.hwnd, WM_APP_CHOOSER_SESSIONS, @intFromPtr(res), 0) == 0) {
        // The app is going away; nothing will ever collect this.
        res.destroy();
    }
}

/// Worker thread: does a failed RPC say the CONNECTION is gone, or only that the
/// agent did not answer this call (T859)?
///
/// Two ways to be sure, and nothing else counts:
///
///   * `error.ConnectionClosed` — the connection's own machinery failed the
///     caller because it is shutting down (`failPendingRpcs`). Proof.
///   * the link FSM has moved past `degraded` — `reconnecting` is 3 missed
///     heartbeats or a transport error (§5.1), `dead` is terminal. Both are the
///     TRANSPORT reporting itself broken, which is what distinguishes a dropped
///     socket from a busy agent.
///
/// `error.Timeout` on a `connected` or `degraded` link is deliberately NOT
/// enough: heartbeats are answered by the reader thread, not by session logic,
/// so an agent that is merely slow (or wedged — T1589) keeps its link healthy,
/// and condemning that connection would tear down the one warm link every
/// borrower on this machine shares over a call that was only slow.
fn connectionGone(c: *remote_connection.Connection, err: anyerror) bool {
    if (err == error.ConnectionClosed) return true;
    return switch (c.state()) {
        .connected, .degraded => false,
        .reconnecting, .reattaching, .dead => true,
    };
}

/// GUI thread: take ownership of a landed fetch. Returns true when it was
/// adopted — a stale serial is dropped, so the caller knows not to repaint.
pub fn adopt(self: *SessionRoster, res: *Result) bool {
    if (res.serial != self.serial) {
        log.debug("chooser roster: dropping a stale reply serial={d}", .{res.serial});
        return false;
    }
    self.inflight = false;

    // T1296: adopted independently of the roster — a landed layout view is
    // worth keeping even if the LIST_SESSIONS half failed, and a failed pull
    // must not blank the view a previous fetch left behind (a refetch that
    // could not read the layouts would otherwise make every row lose its name).
    if (res.layouts) |d| {
        self.dropLayouts();
        self.layouts = d;
        res.layouts = null; // adopted
    }

    if (res.roster) |r| {
        if (self.owned) |*old| old.deinit();
        self.owned = r;
        res.roster = null; // adopted
        self.state = .loaded;
        // A landed roster re-arms the T859 retry: whatever went wrong before is
        // over, so the NEXT dead connection gets its own single shot.
        self.redialed = false;
        self.pruneKilled();
        // The acceptance oracle: an owner-drawn roster has no HWNDs to read
        // back, so what it LOADED is said out loud (T318) — WITH the machine it
        // loaded from (T319), because "5 sessions" is the same sentence whether
        // they came from this box or the one the user clicked.
        // `live=` (T1554) separates running sessions from tombstones, which the
        // agent keeps listing until it reaps them: a session that was ENDED and
        // one that was only DETACHED are both still "loaded", and only this
        // number tells them apart. It sits before `target=` so a pattern that
        // anchors on what follows `device=` (the `pushed=1` lookahead in
        // chooser-conn-pool.ps1) reads the same line it always did.
        log.info("chooser roster: loaded {d} session(s) live={d} target={s} device={s}", .{
            self.owned.?.sessions.len,
            liveCount(self.owned.?.sessions),
            @tagName(self.target),
            self.targetDevice(),
        });
        if (res.killed_ok) |ok| {
            log.info("chooser roster: close session confirmed={}", .{ok});
        }
    } else {
        // A failed fetch does not erase a roster we already have: showing the
        // last known list beats blanking the region on one hiccup. Nor does it
        // overwrite `unauthorized`, which since T461 is the POOL's verdict about
        // the machine's credentials — a more specific and more actionable
        // sentence than anything this RPC's failure can say.
        if (self.owned == null and self.state != .unauthorized) self.state = .failed;
        log.info("chooser roster: fetch failed target={s} device={s} state={s}", .{
            @tagName(self.target),
            self.targetDevice(),
            @tagName(self.state),
        });
    }
    // The scroll offset is NOT reset here (T333). An adopt is a refetch of the
    // machine we are already looking at — `refresh_in_place` exists precisely so
    // a re-selection does not flash the region back to Loading — and sending the
    // region back to the top under a parked keyboard cursor (T320) leaves the
    // highlighted row off screen until the next keystroke drags it back. A REAL
    // machine change goes through `clear()`, which still owns the reset along
    // with the rows, the cursor and the optimistic kill hides.
    //
    // The rows can SHRINK under the offset, so the caller re-clamps against the
    // new content the moment it knows the region (`clampScrollTo`) — the same
    // clamp-at-the-point-of-use rule `cursorIndex` follows, and for the same
    // reason: this function has no geometry to clamp against.
    return true;
}

/// GUI thread: take ownership of a PUSHED roster (T710). Returns true when it
/// was adopted, so the caller knows whether to repaint.
///
/// The same bookkeeping `adopt` does for a fetched roster, deliberately — a
/// pushed roster and a polled one are the same frame decoded by the same path,
/// so they must land the same way. What differs is only what a push MEANS:
///
///   * It carries no serial, because nothing asked for it — and it deliberately
///     does NOT bump one. Invalidating the in-flight fetch was the obvious move
///     and it was wrong: a REMOTE fetch carries the machine's LAYOUT BLOBS
///     alongside the rows (T1296), and dropping that reply loses the only record
///     of what the user named those windows. `chooser-resume-remote.ps1` caught
///     it as a resumed window coming back called "Ghoztty" instead. The rows the
///     two carry are the same rows from the same agent, so letting a fetch reply
///     land a few hundred milliseconds behind a push costs nothing: any real
///     change since produces another push, which arrives after it.
///   * It is never a failure. There is no "the push failed" state to fall back
///     to, so the `failed` / `unauthorized` handling `adopt` carries has nothing
///     to say here.
///   * The scroll offset and the keyboard cursor stay put, for the T333 reason:
///     this is the machine the user is already looking at, and sending the
///     region back to the top under a parked cursor loses their place — now on
///     somebody ELSE's change, which they did not even ask for.
/// How many rows of a landed roster are running sessions rather than
/// tombstones (`alive == false`: ended, still listed until the agent reaps
/// them). The roster's acceptance lines report it as `live=` (T1554).
fn liveCount(sessions: []const remote_connection.OwnedSession) usize {
    var n: usize = 0;
    for (sessions) |s| {
        if (s.alive) n += 1;
    }
    return n;
}

pub fn adoptPushed(self: *SessionRoster, roster: remote_connection.OwnedSessions) bool {
    if (self.target == .none) {
        var tmp = roster;
        tmp.deinit();
        return false;
    }
    if (self.owned) |*old| old.deinit();
    self.owned = roster;
    self.state = .loaded;
    self.pruneKilled();
    // `serial` and `inflight` belong to the FETCH and are left exactly as they
    // were: the reply that is still coming is this machine's, it brings the
    // layout view with it, and it clears `inflight` itself when it lands.
    log.info("chooser roster: loaded {d} session(s) live={d} target={s} device={s} pushed=1", .{
        self.owned.?.sessions.len,
        liveCount(self.owned.?.sessions),
        @tagName(self.target),
        self.targetDevice(),
    });
    return true;
}

/// Whether a landed failure should condemn its pooled connection and redial
/// (T859). Pure, so the policy is readable and testable without an App or a
/// pool: the answer is yes exactly when this fetch DISPROVED the pooled
/// connection it used, over a remote machine we are still looking at, and we
/// have not already spent this roster's one shot.
///
/// A non-zero `dead_entry` already means the fetch failed — the worker sets it
/// only where `requestSessions` returned an error — so the region's own state is
/// deliberately not consulted. It could not be: a failed fetch over rows that
/// are already on screen stays `loaded` (`adopt` keeps the last known list
/// rather than blanking it), and that stale list is the symptom.
fn shouldRedial(self: *const SessionRoster, dead_entry: u64) bool {
    if (dead_entry == 0) return false;
    if (self.target != .remote) return false;
    if (self.redialed) return false;
    return true;
}

/// GUI thread: a fetch came back empty over a pooled connection it proved dead.
/// Condemn that connection and dial a fresh one NOW, so the region recovers by
/// itself instead of showing a list known to be wrong until the user clicks
/// somewhere else (T859).
///
/// Why the roster reports rather than waiting for the pool: a dropped socket
/// never reaches `dead` at all (only a DETACHED frame puts it there), and the
/// pool's own `sweep` only condemns it once it has stayed down through the
/// settle window and the next poll tick has looked (T1636). The fetch knows in
/// one RPC. So the borrower reports, the pool decides and dials,
/// and the roster refetches when the lease notification says the machine is warm
/// again — the ordinary `onPoolChange` path, with nothing new in it.
pub fn retryDeadPool(self: *SessionRoster, app: *App, dead_entry: u64) void {
    if (comptime builtin.os.tag != .windows) return;
    if (!self.shouldRedial(dead_entry)) return;
    const ep = self.endpoint() orelse return;
    const msg_hwnd = app.msg_hwnd orelse return;
    if (!app.machine_pool.redialNow(msg_hwnd, ep, dead_entry)) return;
    self.redialed = true;
    log.info(
        "chooser roster: the pooled connection was gone; redialing device={s}",
        .{self.targetDevice()},
    );
    // Not `failed`: the machine is being re-dialed, and `adopt` only reached for
    // that state because this fetch's RPC failed. Saying so would paint an error
    // card for the second it takes the dial to answer — and if it cannot, the
    // pool's own notification writes the failure with a better reason.
    if (self.owned == null) self.state = .loading;
}

/// This roster's pool endpoint, or null when there is nothing poolable to name:
/// the local agent (`LocalAgent` owns that connection), no selection, or a remote
/// machine with no credential — which is the signed-out case and gets the
/// `unauthorized` sentence rather than a dial.
pub fn endpoint(self: *const SessionRoster) ?machine_pool.Endpoint {
    if (self.target != .remote) return null;
    const r = self.remote orelse return null;
    return .{ .relay = .{ .base = r.base, .device = r.device } };
}

/// GUI thread: the pool says this machine's warm connection became usable, or
/// stopped being (T461). Returns true when the region changed and the caller
/// should repaint.
///
/// A connection arriving is not itself a roster — it is the thing a roster can
/// now be fetched over — so this kicks a fetch rather than painting anything, and
/// only when one is not already in flight (an `acquire` on an already-warm
/// machine replays through here in the same breath the selection's own fetch
/// borrowed it).
pub fn onPoolChange(
    self: *SessionRoster,
    app: *App,
    chooser_id: u64,
    conn: ?*remote_connection.Connection,
    failure: MachineConnectionPool.Failure,
) bool {
    if (self.target != .remote) return false;
    if (conn != null) {
        if (self.inflight) return false;
        const before = self.state;
        self.fetch(app, chooser_id, null);
        // The roster itself lands later, through `adopt`; the only thing worth
        // repainting for here is a fetch that failed before it started.
        return self.state != before;
    }
    // The connection is being REPLACED, not lost (T1636): the fresh one arrives
    // through this same callback and refetches. Nothing to say yet — an error
    // card now would flash for the second the dial takes.
    if (failure == .redialing) return false;
    // No connection: report WHY, and only over a region that has nothing better
    // to show — a roster already on screen is more useful than an error card
    // about the socket it was fetched over.
    if (self.owned != null) return false;
    const next: chooser_sessions.State = switch (failure) {
        .unauthorized => .unauthorized,
        .incompatible => .incompatible,
        .none, .offline, .redialing => .failed,
    };
    if (self.state == next) return false;
    self.state = next;
    self.inflight = false;
    // Deliberately the SAME sentence `adopt` prints for a failed fetch. Which
    // layer learned that a machine is unreachable is our business; "the roster
    // could not load from this machine, and here is the state it resolved to" is
    // one fact with one vocabulary, and the acceptance suite reads it as the
    // roster's answer (`chooser-sessions-remote.ps1` F and G).
    log.info("chooser roster: fetch failed target={s} device={s} state={s}", .{
        @tagName(self.target),
        self.targetDevice(),
        @tagName(next),
    });
    return true;
}

/// The target's device id for logging, or `-` when there is no device (the
/// local agent, or no selection at all).
fn targetDevice(self: *const SessionRoster) []const u8 {
    return switch (self.target) {
        .remote => |id| id,
        else => "-",
    };
}

/// Optimistically hide a session the user just killed.
pub fn markKilled(self: *SessionRoster, id: []const u8) void {
    if (self.killed_count >= max_killed) return;
    if (id.len > max_id_len) return;
    const i = self.killed_count;
    @memcpy(self.killed[i][0..id.len], id);
    self.killed_len[i] = id.len;
    self.killed_count = i + 1;
}

pub fn isKilled(self: *const SessionRoster, id: []const u8) bool {
    for (0..self.killed_count) |i| {
        if (std.mem.eql(u8, self.killed[i][0..self.killed_len[i]], id)) return true;
    }
    return false;
}

/// Drop hidden ids the agent no longer lists — the kill is confirmed, so the
/// hide has done its job and must not outlive it (a recycled id would
/// otherwise stay invisible).
fn pruneKilled(self: *SessionRoster) void {
    const roster = self.owned orelse return;
    var out: usize = 0;
    for (0..self.killed_count) |i| {
        const id = self.killed[i][0..self.killed_len[i]];
        var still_there = false;
        for (roster.sessions) |s| {
            if (std.mem.eql(u8, s.id, id)) still_there = true;
        }
        if (!still_there) continue;
        if (out != i) {
            @memcpy(self.killed[out][0..id.len], id);
            self.killed_len[out] = id.len;
        }
        out += 1;
    }
    self.killed_count = out;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

pub const testing = std.testing;

/// `n` alive sessions with agent-owned strings, shaped exactly like a landed
/// `LIST_SESSIONS` so `adopt` can take them and `deinit` can free them.
fn testSessions(alloc: Allocator, n: usize) !remote_connection.OwnedSessions {
    const sessions = try alloc.alloc(remote_connection.OwnedSession, n);
    for (sessions, 0..) |*s, i| {
        s.* = .{
            .id = try std.fmt.allocPrint(alloc, "session-{d}", .{i}),
            .alive = true,
            .exit_code = null,
            .attached = false,
            .activity = try alloc.dupe(u8, "idle"),
            .pid = @intCast(1000 + i),
            .title = null,
            .cwd = null,
            .argv = null,
            .created_at = 0,
            .last_activity = 0,
            .pinned = true,
        };
    }
    return .{ .sessions = sessions, .alloc = alloc };
}

pub fn testRows(buf: []VisibleRow) []const VisibleRow {
    for (buf) |*r| r.* = .{ .session = .{ .id = "s", .alive = true } };
    return buf;
}

test "liveCount leaves tombstones out (T1554)" {
    var roster = try testSessions(testing.allocator, 3);
    defer roster.deinit();
    try testing.expectEqual(@as(usize, 3), liveCount(roster.sessions));
    roster.sessions[1].alive = false;
    roster.sessions[1].exit_code = 0;
    try testing.expectEqual(@as(usize, 2), liveCount(roster.sessions));
    try testing.expectEqual(@as(usize, 0), liveCount(roster.sessions[0..0]));
}

test "adopt keeps the offset a refetch was parked at (T333)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.target = .local;
    roster.serial = 7;
    roster.scroll = 140;
    roster.setCursor("session-4");

    var res: Result = .{
        .alloc = alloc,
        .chooser_id = 1,
        .serial = 7,
        .roster = try testSessions(alloc, 6),
    };
    defer if (res.roster) |*r| r.deinit();

    try testing.expect(roster.adopt(&res));
    try testing.expectEqual(@as(usize, 6), roster.owned.?.sessions.len);
    // The whole point: the region does not jump back to the top under a parked
    // keyboard cursor just because the same machine was refetched.
    try testing.expectEqual(@as(i32, 140), roster.scroll);
    try testing.expectEqualStrings("session-4", roster.cursorId().?);
}

test "a stale reply changes nothing, offset included" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.target = .local;
    roster.serial = 7;
    roster.scroll = 140;

    var res: Result = .{
        .alloc = alloc,
        .chooser_id = 1,
        .serial = 6,
        .roster = try testSessions(alloc, 2),
    };
    defer if (res.roster) |*r| r.deinit();

    try testing.expect(!roster.adopt(&res));
    try testing.expectEqual(@as(i32, 140), roster.scroll);
    try testing.expect(roster.owned == null);
}

test "a machine change still resets the offset" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.scroll = 140;
    roster.setCursor("session-4");
    roster.hover_kill = 2;

    roster.clear();
    try testing.expectEqual(@as(i32, 0), roster.scroll);
    try testing.expect(!roster.hasCursor());
    try testing.expectEqual(@as(i32, -1), roster.hover_kill);
}

test "a fetch that disproved its pooled connection asks for one redial (T859)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();
    roster.target = .{ .remote = "dev-remote" };

    // The shape the worker reports: no roster, and the id of the pooled
    // connection whose RPC proved it gone.
    try testing.expect(roster.shouldRedial(42));

    // Single-shot until something lands. `retryDeadPool` sets the flag after the
    // pool agrees; the policy's job is to refuse the second ask.
    roster.redialed = true;
    try testing.expect(!roster.shouldRedial(42));

    // A landed roster re-arms it — a machine that came back is recoverable again.
    // Note what this state also is: rows on screen, `state == .loaded`. The next
    // failed fetch keeps both (a stale list beats a blank region) and must STILL
    // be able to condemn the connection it failed over, which is why the policy
    // reads `dead_entry` and never the region's state.
    var res: Result = .{
        .alloc = alloc,
        .chooser_id = 1,
        .serial = roster.serial,
        .roster = try testSessions(alloc, 2),
    };
    defer if (res.roster) |*r| r.deinit();
    try testing.expect(roster.adopt(&res));
    try testing.expect(!roster.redialed);
    try testing.expect(roster.shouldRedial(42));
}

test "nothing is condemned for a fetch that said nothing about its transport (T859)" {
    const alloc = testing.allocator;
    var roster: SessionRoster = .init(alloc);
    defer roster.deinit();

    // A failure the worker did not classify as connection-shaped (a slow agent's
    // `error.Timeout` over a healthy link) carries no entry id, so there is
    // nothing to condemn.
    roster.target = .{ .remote = "dev-remote" };
    try testing.expect(!roster.shouldRedial(0));

    // And the LOCAL target never has a pooled connection to replace: its
    // connection is `LocalAgent`'s, for the app's life.
    roster.target = .local;
    try testing.expect(!roster.shouldRedial(42));

    // A machine change drops the armed state with the rows it belonged to.
    roster.target = .{ .remote = "dev-remote" };
    roster.redialed = true;
    roster.clear();
    try testing.expect(!roster.redialed);
}

