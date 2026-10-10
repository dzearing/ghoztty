//! Headless per-session terminal emulator for the **re-attach grid snapshot**
//! (session-persistence FIX 2).
//!
//! ## Why this exists
//!
//! The agent keeps only a bounded **raw byte ring** per session (`session.zig`),
//! and on re-attach it replays the ring tail (design §7.3). When deep scrollback
//! overran the ring, the exact resume point is evicted: the client showed a
//! `... bytes of scrollback lost ...` marker and — critically — often a **blank
//! pane**. The worst case is a full-screen (alt-screen) app such as Claude Code
//! or vim whose `\x1b[?1049h` (enter-alt) sequence scrolled out of the ring long
//! ago: replaying only the ring tail paints alt-screen writes onto the client's
//! *primary* screen (the mode switch is gone), leaving the real screen blank.
//!
//! Raw-ring replay can never reconstruct state written before the ring window.
//! The only thing that can is a component that watched the output **as it
//! happened**. So each session drives one of these tiny, side-effect-free
//! emulators continuously (fed the same bytes the ring records). On attach the
//! agent serializes the current visible screen as a self-contained VT repaint —
//! the "grid snapshot" the design always anticipated ("the forthcoming grid
//! snapshot makes the visible grid exact", `server.zig` handleAttach) — so the
//! pane repaints exactly and is **never blank**, even when the paint predates the
//! ring.
//!
//! ## The reboot history (`historyAlloc`)
//!
//! The same emulator is also what the **reboot floor** restores from. A reboot
//! kills every child, so the restored pane can only ever show what the session
//! LOOKED like — and the raw ring is a poor record of that. It is a byte window
//! into a live program's stream: it starts mid-sequence, it is a few minutes of a
//! TUI's in-place redraws (2 MB of Claude Code is ~700 frames of spinner), it
//! carries every query the program sent (`CSI c`, `CSI ? 2026 $ p`, `CSI ? u` …)
//! and every mode it set (mouse tracking, kitty keyboard, synchronized output),
//! and it is drawn with cursor motion that only lands at the original geometry.
//! Replayed into a fresh pane it answers dead queries into the NEW shell's stdin,
//! floods the viewer's IO mailbox, re-arms the dead program's input modes, and
//! smears — the reported "garbled, wrong width, unresponsive" restore.
//!
//! What a restore wants is the BUFFER: the scrollback and screen the user was
//! looking at. This emulator holds exactly that (it has scrollback, bounded by
//! `history_scrollback_bytes`), and `historyAlloc` serializes it as CONTENT ONLY —
//! text, colors, hyperlinks, soft wraps left unwrapped so the viewer reflows them
//! — with no modes, no cursor addressing, no queries. The agent writes it to disk
//! next to the ring (`ring_snapshot.writeHistoryAtomic`) and replays it instead of
//! the raw bytes after a restart. `historyFromRaw` builds the same thing from a
//! raw ring alone (a snapshot written by an older agent) by running it through a
//! scratch emulator, so even pre-upgrade files restore cleanly.
//!
//! ## Cost
//!
//! One `terminal.Terminal` per session with a bounded `max_scrollback`
//! (`max_scrollback_bytes`, below), plus VT parsing of each output chunk — the
//! same work the GUI already does per pane, done once in the daemon instead.
//! Idle sessions cost nothing; scrollback pages are allocated as they fill. The
//! emulator is `readonly` (the `stream_terminal` handler ignores
//! clipboard/DA/DSR/etc.), so it never writes back to the pty or has any side
//! effect beyond updating its own grid.
//!
//! ## Threading
//!
//! Not internally synchronized. The `Server` only ever touches a session's
//! emulator under `store.mutex` — `feed`/`resize` from `onChildOutput` and
//! `snapshotAlloc` from `handleAttach` both hold it — so access is single
//! threaded by the store lock, exactly like the ring.
//!
//! ## Skew safety
//!
//! Emitting the snapshot is gated on the negotiated `grid_snapshot` HELLO
//! capability (`protocol.zig`): a peer that doesn't advertise it (an older app,
//! or an older agent that never sends one) falls back to today's ring-only
//! replay. The snapshot itself is plain VT that any client's emulator renders, so
//! there is no new opcode and no unknown-frame hazard across the skew.

const std = @import("std");
const Allocator = std.mem.Allocator;
// Relative imports of src/terminal — the same way `src/pty.zig` (already in the
// agent's module graph via pty_child.zig) reaches it, so terminal stays a single
// module. The agent-core test aggregator roots at `src/` (via
// `src/agent_core_test.zig`) precisely so this `../../` stays inside its module
// path.
const terminal = @import("../../terminal/main.zig");
const Selection = @import("../../terminal/Selection.zig");
const stream_terminal = @import("../../terminal/stream_terminal.zig");
const formatter = @import("../../terminal/formatter.zig");

const log = std.log.scoped(.grid_snapshot);

/// A pty geometry can legitimately be 0 before the first resize; the emulator
/// needs at least a 1x1 grid, and we cap the upper bound so a bogus dimension
/// can't request a giant allocation.
fn clampDim(v: u16) u16 {
    return std.math.clamp(v, 1, 1000);
}

/// The emulator's per-session scrollback ceiling, in BYTES — the same unit
/// `terminal.Terminal.Options.max_scrollback` takes, so this IS the allocation
/// bound rather than a row count that implies one.
///
/// Deliberately chosen, not defaulted (the terminal's own default is 10 MB): the
/// agent already carries a 2 MB raw ring per session (`session.zig`), and this is
/// a SECOND per-session allocation living in the same daemon. It serves two
/// readers: a snapshot-less ATTACH (T621, below) and the reboot HISTORY
/// (`historyAlloc`, main 7e78aacf4), which wants ~2,000 rows at a 215-column
/// pane — 4 MiB. Pages are only allocated as scrollback actually fills, so an
/// idle or short-lived session costs a fraction of it; the per-session ceiling
/// is ~6 MB, which is the number to quote when the budget is questioned. (Raised
/// from 1 MiB at the T1796 merge so the history main relies on is not cut short.)
///
/// It is also what makes `T621`'s replay saving real: a snapshot-less ATTACH can
/// skip the whole raw ring precisely because this scrollback is reflowed to the
/// ATTACHING client's geometry, which the ring (a concatenation of segments drawn
/// at different sizes) can never be.
pub const max_scrollback_bytes: usize = 4 * 1024 * 1024;

/// What a snapshot should cover.
pub const SnapshotOptions = struct {
    /// Include the retained scrollback ABOVE the visible screen.
    ///
    /// Off by default, and that default is load-bearing: on a DELTA re-attach the
    /// client already holds this history (it was streamed to it before the
    /// disconnect, and the ring gap-fill covers the rest), so repainting it would
    /// duplicate it. Only a snapshot-less attach — a pane this viewer has never
    /// had open, or one rebuilt from a layout blob — wants it.
    scrollback: bool = false,
};

/// Main's name for the same budget (`historyAlloc`). One emulator, one bound.
pub const history_scrollback_bytes: usize = max_scrollback_bytes;

/// Width/height a `historyFromRaw` conversion uses when the raw ring did not
/// record the geometry it was drawn at (a legacy width-less GRS1 snapshot).
/// The history it produces is unwrapped, so the viewer re-wraps it at its own
/// width anyway; the scratch size only decides where absolute cursor moves land.
const unknown_cols: u16 = 80;
const unknown_rows: u16 = 24;

pub const GridEmulator = struct {
    alloc: Allocator,
    term: terminal.Terminal,
    stream: stream_terminal.Stream,

    /// Create a heap-pinned emulator. It MUST be heap-allocated (not moved)
    /// because the internal `stream` holds a `*Terminal` into `self.term`.
    pub fn create(alloc: Allocator, rows: u16, cols: u16) Allocator.Error!*GridEmulator {
        const self = try alloc.create(GridEmulator);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.term = try terminal.Terminal.init(alloc, .{
            .rows = clampDim(rows),
            .cols = clampDim(cols),
            // Bounded scrollback so a snapshot can carry history the attaching
            // client has never seen, reflowed to ITS geometry (T621), and so the
            // reboot history (`historyAlloc`) has the rows the user was looking
            // at. See `max_scrollback_bytes` for why this number.
            .max_scrollback = max_scrollback_bytes,
        });
        errdefer self.term.deinit(alloc);
        // initAlloc so OSC parsing (e.g. OSC 7 pwd, hyperlinks) can allocate; the
        // readonly handler still ignores side-effecting sequences.
        self.stream = stream_terminal.Stream.initAlloc(
            alloc,
            stream_terminal.Handler.init(&self.term),
        );
        return self;
    }

    pub fn destroy(self: *GridEmulator) void {
        self.stream.deinit();
        self.term.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Feed a chunk of child output. VT parse/apply errors are swallowed (logged
    /// by the handler) so this matches `Session.recordOutput`'s non-failing
    /// contract — a transient allocation failure degrades the snapshot's fidelity
    /// but never propagates.
    pub fn feed(self: *GridEmulator, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    /// Track the session's live geometry so the serialized screen matches the
    /// pty the child actually sees. No-op when already at the requested size
    /// (`Terminal.resize` short-circuits too, but we avoid the clamp/call). Best
    /// effort; a failure leaves the prior size.
    pub fn ensureSize(self: *GridEmulator, rows: u16, cols: u16) void {
        const c = clampDim(cols);
        const r = clampDim(rows);
        if (self.term.cols == c and self.term.rows == r) return;
        self.term.resize(self.alloc, c, r) catch |err| {
            log.warn("grid emulator resize failed: {}", .{err});
        };
    }

    /// True when the child is currently on the alternate screen (a full-screen
    /// app such as vim / Claude Code). The Server uses this to decide whether the
    /// raw ring tail is safe to replay: alt-screen paint written after an evicted
    /// `?1049h` must NOT be replayed onto the client's primary screen.
    pub fn onAlternateScreen(self: *const GridEmulator) bool {
        return self.term.screens.active_key == .alternate;
    }

    /// The pagelist range the snapshot covers.
    ///
    /// The formatter's own default (`.{ .selection = null }`) is the WHOLE
    /// pagelist, which with the emulator's bounded scrollback now means history
    /// too — so the no-scrollback case has to say "active area only" explicitly,
    /// and that is what keeps a delta re-attach byte-for-byte what it was before
    /// T621 gave the emulator any history to hold.
    fn contentSelection(
        self: *const GridEmulator,
        opts: SnapshotOptions,
    ) formatter.ScreenFormatter.Content {
        // Whole pagelist: history (if any) then the visible screen.
        if (opts.scrollback) return .{ .selection = null };

        const pages = &self.term.screens.active.pages;
        const tl = pages.getTopLeft(.active);
        const br = pages.getBottomRight(.screen) orelse return .{ .selection = null };
        // Everything ever written is ABOVE the active area (a screen scrolled
        // fully into history and left blank). There is no visible content to
        // emit, and emitting the reversed range would dump the history the
        // caller just said it did not want.
        if (br.before(tl)) return .none;
        return .{ .selection = Selection.init(tl, br, false) };
    }

    /// True when the emulator is holding scrollback above the visible screen —
    /// i.e. a `.{ .scrollback = true }` snapshot would carry more than the screen.
    /// False on the alternate screen, which has no history by construction.
    pub fn hasScrollback(self: *const GridEmulator) bool {
        if (self.term.screens.active_key == .alternate) return false;
        const pages = &self.term.screens.active.pages;
        return pages.getTopLeft(.screen).node != pages.getTopLeft(.active).node or
            pages.getTopLeft(.screen).y != pages.getTopLeft(.active).y;
    }

    /// Serialize the current screen as a self-contained VT repaint owned by `gpa`
    /// (caller frees). The client feeds these bytes straight into its terminal,
    /// repainting the exact on-screen grid — plus, when `opts.scrollback` is set,
    /// the retained history above it.
    ///
    /// The repaint re-establishes terminal state (modes incl. alt-screen, cursor,
    /// SGR, scrolling region, tabstops, pwd, hyperlinks) but NOT the palette:
    /// VT `emit` renders indexed colors as palette *indices*, which the client
    /// resolves against its OWN configured palette — emitting the emulator's
    /// (default) palette would clobber the user's theme on reconnect.
    pub fn snapshotAlloc(
        self: *GridEmulator,
        gpa: Allocator,
        opts: SnapshotOptions,
    ) Allocator.Error![]u8 {
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        const w = &buf.writer;

        // On the PRIMARY screen the repaint must start from a clean viewport, so
        // prefix home + erase-screen (ED2). ED2 erases the visible screen only —
        // scrollback history is preserved — then the screen is repainted over it.
        // On the ALTERNATE screen the `\x1b[?1049h` the formatter emits (via
        // `.modes`) itself switches to and clears the alt screen, so a manual
        // clear would be redundant (and would wrongly wipe the client's primary).
        if (self.term.screens.active_key != .alternate) {
            w.writeAll("\x1b[H\x1b[2J") catch return error.OutOfMemory;
        }

        // unwrap: a soft-wrapped row is emitted as the continuation it is, not
        // as a row ending in CRLF, so the viewer keeps it as ONE logical line it
        // can reflow when the pane is resized later. (The repaint is drawn at
        // the attaching viewer's own width, so the picture is identical either
        // way; only the wrap flag — and so every later resize — differs.)
        // semantic_prompts: the viewer must know which repainted rows are the
        // shell's prompt, or its next resize blanks output it mistakes for one.
        var tf = formatter.TerminalFormatter.init(&self.term, .{ .emit = .vt, .unwrap = true, .semantic_prompts = true });
        tf.content = self.contentSelection(opts);
        tf.extra = .{
            .palette = false,
            .modes = true,
            .scrolling_region = true,
            .tabstops = true,
            .pwd = true,
            .keyboard = true,
            .screen = .all,
        };
        tf.format(w) catch return error.OutOfMemory;

        return buf.toOwnedSlice();
    }

    /// Serialize the session's HISTORY — the scrollback and screen it was showing
    /// — as content-only VT for the reboot floor (see the module doc). Owned by
    /// `gpa`; empty when there is nothing on screen.
    pub fn historyAlloc(self: *GridEmulator, gpa: Allocator) Allocator.Error![]u8 {
        return historyOf(&self.term, gpa);
    }
};

/// Build the reboot history from a RAW ring snapshot (a byte window of the
/// session's output) by replaying it through a scratch emulator at the geometry
/// it was drawn at, then serializing that emulator like `historyAlloc`. This is
/// how a snapshot written by an agent that predates the history file still
/// restores as clean content instead of being replayed raw. `cols`/`rows` of 0
/// mean "unknown" (a legacy GRS1 file). Owned by `gpa`.
pub fn historyFromRaw(gpa: Allocator, bytes: []const u8, cols: u16, rows: u16) Allocator.Error![]u8 {
    const emu = try GridEmulator.create(
        gpa,
        if (rows == 0) unknown_rows else rows,
        if (cols == 0) unknown_cols else cols,
    );
    defer emu.destroy();
    emu.feed(bytes);
    return emu.historyAlloc(gpa);
}

/// The shared serializer behind `historyAlloc`/`historyFromRaw`.
///
/// What it emits, and why each piece is (or is not) there:
///   - The PRIMARY screen, all of it (scrollback + active rows): that is the
///     buffer a shell — or an inline TUI like Claude Code's default renderer —
///     was showing.
///   - The ALTERNATE screen's rows after it, when the program was on the alt
///     screen: the last frame of a full-screen TUI is what the user last saw, so
///     it becomes ordinary lines at the bottom of the restored history. The
///     restored pane itself stays on the PRIMARY screen — the program that owned
///     the alt screen is dead, and the fresh shell must not land inside its
///     frame.
///   - Shell-integration marks (OSC 133 `P`/`I` — `formatter.Options
///     .semantic_prompts`), so the restored prompt rows are known as prompts:
///     a resize with the new shell at its prompt otherwise blanks restored
///     output back to the last prompt the terminal DID see. The history ends
///     in output state (`I` + the final CRLF), so the divider, notice and new
///     shell below it are never mistaken for the dead shell's prompt.
///   - Text, SGR styles and hyperlinks only. No modes, no cursor position, no
///     scroll region, no tabstops, no keyboard state, no palette: every one of
///     those is an agreement with a process that no longer exists.
///   - Soft wraps UNWRAPPED, so a long line stays one logical line and the viewer
///     re-wraps it at whatever width the restored pane has (`unwrap = false` would
///     freeze every wrapped row at the capture width).
///   - A trailing SGR reset + hyperlink close + CRLF, so whatever follows (the
///     restart divider, the notice, the new shell's prompt) starts in a clean
///     style on its own line.
fn historyOf(term: *terminal.Terminal, gpa: Allocator) Allocator.Error![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;

    const opts: formatter.Options = .{ .emit = .vt, .unwrap = true, .trim = true, .semantic_prompts = true };

    if (term.screens.get(.primary)) |primary| {
        var sf = formatter.ScreenFormatter.init(primary, opts);
        sf.extra = .none;
        sf.format(w) catch return error.OutOfMemory;
    }

    if (term.screens.active_key == .alternate) alt: {
        const alt = term.screens.get(.alternate) orelse break :alt;
        var frame: std.Io.Writer.Allocating = .init(gpa);
        defer frame.deinit();
        var sf = formatter.ScreenFormatter.init(alt, opts);
        sf.extra = .none;
        sf.format(&frame.writer) catch return error.OutOfMemory;
        const bytes = frame.written();
        if (bytes.len > 0) {
            // Close whatever style the primary content ended in, and start the
            // frame on a fresh line below it.
            if (buf.written().len > 0) w.writeAll("\x1b[0m\r\n") catch return error.OutOfMemory;
            w.writeAll(bytes) catch return error.OutOfMemory;
        }
    }

    if (buf.written().len == 0) return buf.toOwnedSlice();
    w.writeAll("\x1b[0m\x1b]8;;\x1b\\\x1b]133;I\x1b\\\r\n") catch return error.OutOfMemory;
    return buf.toOwnedSlice();
}

const testing = std.testing;

test "GridEmulator: primary-screen snapshot clears then repaints the visible text" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 24, 80);
    defer emu.destroy();

    emu.feed("hello world");
    try testing.expect(!emu.onAlternateScreen());

    const snap = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(snap);

    // Primary screen: prefixed with home + erase-screen so the repaint lands
    // cleanly, then the visible text; no alt-screen enter.
    try testing.expect(std.mem.startsWith(u8, snap, "\x1b[H\x1b[2J"));
    try testing.expect(std.mem.indexOf(u8, snap, "hello world") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "?1049h") == null);
}

test "GridEmulator: alt-screen snapshot re-enters alt and repaints its content" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 24, 80);
    defer emu.destroy();

    // Enter the alternate screen, then paint — the shape of a full-screen app.
    emu.feed("\x1b[?1049h");
    emu.feed("ALTCONTENT");
    try testing.expect(emu.onAlternateScreen());

    const snap = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(snap);

    // The snapshot must re-enter the alt screen (so the client switches to it)
    // and repaint the content. It must NOT prefix the primary home+erase (that
    // would wrongly clear the client's primary screen); `?1049h` clears alt.
    try testing.expect(std.mem.indexOf(u8, snap, "?1049h") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "ALTCONTENT") != null);
    try testing.expect(!std.mem.startsWith(u8, snap, "\x1b[H\x1b[2J"));
}

test "GridEmulator: reproduces the CURRENT screen when an old alt-enter would be evicted" {
    // The real re-attach bug: a full-screen app entered the alt screen long ago
    // (that `?1049h` would have scrolled out of the 2 MB ring) then repainted
    // many times. A continuous emulator still knows it's on the alt screen and
    // reproduces the LAST paint exactly — which ring-tail replay alone cannot.
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 10, 40);
    defer emu.destroy();

    emu.feed("\x1b[?1049h\x1b[2J");
    var i: usize = 0;
    while (i < 200) : (i += 1) emu.feed("\x1b[H\x1b[2Jframe-old");
    emu.feed("\x1b[H\x1b[2JFRAME-FINAL");

    try testing.expect(emu.onAlternateScreen());
    const snap = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(snap);

    try testing.expect(std.mem.indexOf(u8, snap, "?1049h") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "FRAME-FINAL") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "frame-old") == null);
}

test "GridEmulator: ensureSize reflows to the attach geometry" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 24, 80);
    defer emu.destroy();
    emu.feed("resize me");
    emu.ensureSize(30, 100);
    try testing.expectEqual(@as(u16, 100), emu.term.cols);
    try testing.expectEqual(@as(u16, 30), emu.term.rows);
    const snap = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "resize me") != null);
}

test "GridEmulator: retains scrollback and serializes it only when asked" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 5, 40);
    defer emu.destroy();

    // Twenty lines through a five-row screen: the first fifteen are scrollback,
    // the last five are the visible screen.
    var i: usize = 1;
    while (i <= 20) : (i += 1) {
        var buf: [32]u8 = undefined;
        emu.feed(std.fmt.bufPrint(&buf, "line-{d}\r\n", .{i}) catch unreachable);
    }
    try testing.expect(emu.hasScrollback());

    // Default (a DELTA re-attach): the visible screen only. `line-1` scrolled
    // off long ago and must not come back — the client already has it.
    const screen_only = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(screen_only);
    try testing.expect(std.mem.indexOf(u8, screen_only, "line-1\r\n") == null);
    try testing.expect(std.mem.indexOf(u8, screen_only, "line-20") != null);

    // Scrollback (a snapshot-less ATTACH): the history rides along, in order,
    // ahead of the visible rows.
    const with_history = try emu.snapshotAlloc(alloc, .{ .scrollback = true });
    defer alloc.free(with_history);
    const first = std.mem.indexOf(u8, with_history, "line-1\r\n") orelse
        return error.MissingScrollback;
    const last = std.mem.indexOf(u8, with_history, "line-20") orelse
        return error.MissingScreen;
    try testing.expect(first < last);
    try testing.expect(with_history.len > screen_only.len);
}

test "GridEmulator: a scrollback snapshot reflows to the ATTACH geometry" {
    // The property a stored, app-side snapshot cannot have: the history is
    // serialized at the size the attaching client just asked for, not the size it
    // happened to be drawn at.
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 4, 20);
    defer emu.destroy();

    var i: usize = 1;
    while (i <= 12) : (i += 1) {
        var buf: [32]u8 = undefined;
        emu.feed(std.fmt.bufPrint(&buf, "row-{d}\r\n", .{i}) catch unreachable);
    }

    emu.ensureSize(10, 60);
    try testing.expectEqual(@as(u16, 60), emu.term.cols);

    const snap = try emu.snapshotAlloc(alloc, .{ .scrollback = true });
    defer alloc.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "row-1\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "row-12") != null);
}

test "GridEmulator: the alt screen has no scrollback to carry" {
    // Asking for scrollback on a full-screen app is not an error and does not
    // change the payload: the alternate screen keeps no history by construction.
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 6, 30);
    defer emu.destroy();

    emu.feed("\x1b[?1049h");
    emu.feed("ALTCONTENT");
    try testing.expect(emu.onAlternateScreen());
    try testing.expect(!emu.hasScrollback());

    const a = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(a);
    const b = try emu.snapshotAlloc(alloc, .{ .scrollback = true });
    defer alloc.free(b);
    try testing.expectEqualStrings(a, b);
}

test "GridEmulator: a screen scrolled entirely into history emits no content" {
    // The guard in `contentSelection`: everything ever written is ABOVE the active
    // area, so the no-scrollback range would be reversed. Emitting it backwards
    // would dump the very history the caller said it did not want.
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 3, 20);
    defer emu.destroy();

    emu.feed("alpha\r\nbravo\r\ncharlie\r\n\r\n\r\n\r\n");

    const screen_only = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(screen_only);
    try testing.expect(std.mem.indexOf(u8, screen_only, "alpha") == null);

    const with_history = try emu.snapshotAlloc(alloc, .{ .scrollback = true });
    defer alloc.free(with_history);
    try testing.expect(std.mem.indexOf(u8, with_history, "alpha") != null);
}

test "GridEmulator: the attach snapshot is the VISIBLE screen only, never the scrollback" {
    // The emulator keeps scrollback for the reboot history; the attach repaint
    // must not drag it along or every re-attach would duplicate history the
    // viewer already has.
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 3, 20);
    defer emu.destroy();
    emu.feed("old-1\r\nold-2\r\nold-3\r\nnew-1\r\nnew-2");

    const snap = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "new-2") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "old-1") == null);
    try testing.expect(std.mem.indexOf(u8, snap, "old-2") == null);
}

/// Every byte a history must never contain: a query the terminal would answer
/// into the NEW shell's stdin, or a mode/keyboard/cursor-addressing sequence
/// that belonged to the dead program.
fn expectContentOnly(hist: []const u8) !void {
    const forbidden = [_][]const u8{
        "\x1b[?", // any DEC private mode set/reset/query (mouse, 2026, 1049, 25 …)
        "\x1b[>", // kitty push / modifyOtherKeys / XTVERSION query
        "\x1b[<", // kitty pop
        "\x1b[=", // kitty set
        "\x1b[c", // DA1 query
        "$p", // DECRQM query
        "\x1b[6n", // CPR query
        "\x1b[r", // scroll region
    };
    for (forbidden) |f| {
        if (std.mem.indexOf(u8, hist, f) != null) {
            std.debug.print("history contains forbidden sequence {any}\n", .{f});
            return error.TestUnexpectedResult;
        }
    }
}

test "historyAlloc: scrollback + screen, content only, ends on a fresh line" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 3, 20);
    defer emu.destroy();
    // A TUI-ish stream: modes, queries, kitty keyboard, colors, scrolling text.
    emu.feed("\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[>1u\x1b[>4;2m\x1b[c\x1b[?2026$p");
    emu.feed("line-1\r\nline-2\r\n\x1b[31mred-3\x1b[0m\r\nline-4\r\nline-5");

    const hist = try emu.historyAlloc(alloc);
    defer alloc.free(hist);

    // Scrollback (rows that scrolled off a 3-row screen) AND the screen.
    for ([_][]const u8{ "line-1", "line-2", "red-3", "line-4", "line-5" }) |want| {
        try testing.expect(std.mem.indexOf(u8, hist, want) != null);
    }
    // In order.
    try testing.expect(std.mem.indexOf(u8, hist, "line-1").? < std.mem.indexOf(u8, hist, "line-5").?);
    // Styles survive.
    try testing.expect(std.mem.indexOf(u8, hist, "31m") != null or std.mem.indexOf(u8, hist, "38;5;1m") != null);
    try expectContentOnly(hist);
    // Ends reset and on a new line, so the divider/notice/prompt land below it.
    try testing.expect(std.mem.endsWith(u8, hist, "\r\n"));
}

test "historyAlloc: soft wraps stay unwrapped so the viewer can reflow them" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 5, 10);
    defer emu.destroy();
    // 25 characters on a 10-column screen: three rows, ONE logical line.
    emu.feed("abcdefghijklmnopqrstuvwxy\r\nnext");

    const hist = try emu.historyAlloc(alloc);
    defer alloc.free(hist);
    try testing.expect(std.mem.indexOf(u8, hist, "abcdefghijklmnopqrstuvwxy") != null);
}

test "historyAlloc: a session on the alt screen keeps the primary AND its last frame" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 5, 30);
    defer emu.destroy();
    emu.feed("$ claude\r\n");
    emu.feed("\x1b[?1049h\x1b[2J\x1b[H");
    var i: usize = 0;
    while (i < 50) : (i += 1) emu.feed("\x1b[H\x1b[2Jframe-old\x1b[5;1Hstatus-old");
    emu.feed("\x1b[H\x1b[2JFRAME-FINAL\x1b[5;1HSTATUS-FINAL");

    const hist = try emu.historyAlloc(alloc);
    defer alloc.free(hist);
    const prompt = std.mem.indexOf(u8, hist, "$ claude").?;
    const frame = std.mem.indexOf(u8, hist, "FRAME-FINAL").?;
    const status = std.mem.indexOf(u8, hist, "STATUS-FINAL").?;
    try testing.expect(prompt < frame and frame < status);
    try testing.expect(std.mem.indexOf(u8, hist, "frame-old") == null);
    try expectContentOnly(hist);
}

test "historyAlloc: nothing on screen yields nothing" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 5, 30);
    defer emu.destroy();
    emu.feed("\x1b[?1003h\x1b[c");
    const hist = try emu.historyAlloc(alloc);
    defer alloc.free(hist);
    try testing.expectEqual(@as(usize, 0), hist.len);
}

test "historyFromRaw: a raw Claude-Code-shaped ring converts to clean content" {
    // The shape of the user's real rings: the window starts MID-sequence, the
    // stream is synchronized-output frames redrawn in place with relative cursor
    // motion, interleaved with queries and kitty keyboard pushes — and its
    // `?1049h` (for the full-screen renderer) scrolled out of the window long ago.
    const alloc = testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    try raw.appendSlice(alloc, "8;2;109;181;110mtail of a cut sequence\r\n");
    try raw.appendSlice(alloc, "\x1b[<u\x1b[>1u\x1b[>4;2m\x1b[?1004h\x1b[?2004h");
    try raw.appendSlice(alloc, "conversation line A\r\nconversation line B\r\n");
    // The dynamic region the frames below redraw in place (two rows).
    try raw.appendSlice(alloc, "> prompt box\r\nstatus spinner\r\n");
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try raw.appendSlice(alloc, "\x1b[?2026h\x1b[?25l\r\x1b[2A\x1b[2K> prompt box\r\n\x1b[2Kstatus spinner\r\n\x1b[?25h\x1b[?2026l\x1b[c\x1b[?2026$p\x1b[>0q");
    }
    try raw.appendSlice(alloc, "\x1b[?2026h\r\x1b[2A\x1b[2K> FINAL prompt\r\n\x1b[2KFINAL status\r\n\x1b[?2026l");

    const hist = try historyFromRaw(alloc, raw.items, 40, 10);
    defer alloc.free(hist);
    try testing.expect(std.mem.indexOf(u8, hist, "conversation line A") != null);
    try testing.expect(std.mem.indexOf(u8, hist, "FINAL prompt") != null);
    try testing.expect(std.mem.indexOf(u8, hist, "FINAL status") != null);
    // In-place redraws collapse to their final frame — no stack of spinners.
    try testing.expect(std.mem.indexOf(u8, hist, "status spinner") == null);
    try expectContentOnly(hist);
}

test "historyFromRaw: unknown geometry (legacy GRS1) still converts" {
    const alloc = testing.allocator;
    const hist = try historyFromRaw(alloc, "hello\r\nworld", 0, 0);
    defer alloc.free(hist);
    try testing.expect(std.mem.indexOf(u8, hist, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, hist, "world") != null);
}

test "GridEmulator: the attach snapshot keeps soft wraps reflowable" {
    const alloc = testing.allocator;
    const emu = try GridEmulator.create(alloc, 5, 10);
    defer emu.destroy();
    emu.feed("abcdefghijklmnopqrstuvwxy");
    const snap = try emu.snapshotAlloc(alloc, .{});
    defer alloc.free(snap);

    // Paint it into a viewer at the same width, then widen the viewer: the line
    // must reflow back to one row, which it can only do if it arrived soft-wrapped.
    var t: terminal.Terminal = try .init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    var s: stream_terminal.Stream = .initAlloc(alloc, .init(&t));
    defer s.deinit();
    s.nextSlice(snap);
    try t.resize(alloc, 40, 5);
    const text = try t.plainString(alloc);
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "abcdefghijklmnopqrstuvwxy") != null);
}
