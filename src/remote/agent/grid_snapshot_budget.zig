//! Magnitude checks for the scrollback-bearing ATTACH repaint (T1442).
//!
//! T621 let a snapshot-less ATTACH skip the raw ring replay because the grid
//! snapshot now carries the session's retained scrollback, reflowed to the
//! attaching client's geometry. Every test that proved it (`grid_snapshot.zig`,
//! `server.zig` "T621: …") used a dozen lines through a five-row screen: they
//! prove the history is there, ordered, reflowed and gated — and say nothing
//! about the one thing the change is FOR, which is the size of what goes on the
//! wire. This file weighs it at the sizes a real session reaches.
//!
//! ## What is measured, and the number defended
//!
//! Each workload is generated deterministically, fed through a `GridEmulator`
//! until its scrollback is pinned at the retention ceiling
//! (`grid_snapshot.max_scrollback_bytes`), and then:
//!
//!   - **snapshot bytes vs ring bytes.** The ring a pre-T621 attach would have
//!     replayed is the last `session.default_ring_bytes` of the raw stream. The
//!     repaint is serialized at an attach geometry DIFFERENT from the capture
//!     geometry (reflow is the reason the payload is worth sending at all), at
//!     a narrower and a wider one. **Asserted: the repaint is smaller than the
//!     ring replay it replaces.** If a later change (a bigger ceiling, heavier
//!     styling in the formatter) inverts that, this goes red instead of the
//!     trade quietly flipping.
//!   - **emulator memory per session.** The terminal's page memory is the bulk
//!     of it; `PageList.page_size` is the exact byte count of the pages it
//!     holds (both screens). **Asserted: it stays inside the ceiling plus one
//!     viewport's worth** (`PageList` never prunes the active area, so a screen
//!     taller than the ceiling would be allowed past it), so the per-session
//!     budget the `max_scrollback_bytes` doc quotes is a measurement, not an
//!     estimate.
//!   - **wall clock**, emulator feed, serialize and client-side parse (the
//!     parse only under `GHOZTTY_PERF`). Reported only: the test
//!     lanes build Debug, which says nothing about a release agent's timing,
//!     and a timing assert in a shared lane is a flake by construction.
//!
//! `GHOZTTY_PERF=1 zig build test-agent -Dtest-filter=T1442` prints one line
//! per workload with every number above. The figures recorded in T1442's task
//! file came from that line.

const std = @import("std");
const builtin = @import("builtin");
const grid_snapshot = @import("grid_snapshot.zig");
const session = @import("session.zig");

const GridEmulator = grid_snapshot.GridEmulator;
const testing = std.testing;

/// The capture geometry: a wide pane, the shape the ceiling's doc sizes for
/// ("~2,000 rows at a 215-column pane").
const capture_cols: u16 = 215;
const capture_rows: u16 = 50;

/// How much raw output each workload produces: enough that the ring a
/// pre-T621 attach would replay is full (2 MiB), with room to spare.
const stream_bytes: usize = 3 * 1024 * 1024;

const Workload = enum {
    /// A compiler / test-runner log: short-to-medium lines, an SGR colour on
    /// the status words, nothing redrawn in place. The worst case for the
    /// snapshot's side of the trade, because every raw byte is content.
    build_log,
    /// A Claude Code style transcript: long paragraphs that soft-wrap, a
    /// truecolor SGR every few words, box drawing, a spinner redrawn in place
    /// between turns, and an occasional full-screen (alt-screen) excursion.
    agent_transcript,
};

/// A tiny deterministic generator so the numbers are the same on every box.
const Gen = struct {
    rng: std.Random.DefaultPrng,
    out: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) Gen {
        return .{ .rng = .init(1442), .out = .empty, .alloc = alloc };
    }

    fn deinit(self: *Gen) void {
        self.out.deinit(self.alloc);
    }

    fn r(self: *Gen) std.Random {
        return self.rng.random();
    }

    fn put(self: *Gen, bytes: []const u8) !void {
        try self.out.appendSlice(self.alloc, bytes);
    }

    fn print(self: *Gen, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(self.alloc, fmt, args);
    }

    const words = [_][]const u8{
        "the",      "session",  "agent",   "repaint",  "scrollback", "geometry",
        "attach",   "ring",     "replay",  "emulator", "snapshot",   "pane",
        "terminal", "output",   "history", "reflow",   "client",     "budget",
        "measured", "ceiling",  "bytes",   "wrapped",  "style",      "colour",
        "function", "returns",  "error",   "value",    "allocator",  "buffer",
    };

    fn word(self: *Gen) []const u8 {
        return words[self.r().uintLessThan(usize, words.len)];
    }

    fn buildLogLine(self: *Gen, n: usize) !void {
        const pct = n % 101;
        switch (self.r().uintLessThan(u8, 10)) {
            0 => try self.print("\x1b[1;33mwarning:\x1b[0m src/{s}/{s}.zig:{d}:{d}: unused {s} '{s}'\r\n", .{
                self.word(), self.word(), self.r().uintLessThan(u32, 4000), self.r().uintLessThan(u32, 120), self.word(), self.word(),
            }),
            1 => try self.print("test {d}/{d} {s}.{s}...\x1b[32mOK\x1b[0m\r\n", .{
                n, n + 500, self.word(), self.word(),
            }),
            else => try self.print("[{d:>3}%] \x1b[32mBuilding Zig object\x1b[0m src/{s}/{s}_{s}.zig.o ({d} ms)\r\n", .{
                pct, self.word(), self.word(), self.word(), self.r().uintLessThan(u32, 9000),
            }),
        }
    }

    fn transcriptTurn(self: *Gen, n: usize) !void {
        // A boxed prompt.
        try self.put("\x1b[38;2;136;136;136m\xe2\x95\xad");
        for (0..60) |_| try self.put("\xe2\x94\x80");
        try self.put("\xe2\x95\xae\x1b[0m\r\n");
        try self.print("\x1b[38;2;136;136;136m\xe2\x94\x82\x1b[0m > {s} the {s} {s}\r\n", .{ self.word(), self.word(), self.word() });
        try self.put("\x1b[38;2;136;136;136m\xe2\x95\xb0");
        for (0..60) |_| try self.put("\xe2\x94\x80");
        try self.put("\xe2\x95\xaf\x1b[0m\r\n");

        // A spinner redrawn in place: raw bytes the ring carries and the
        // emulator collapses to nothing.
        for (0..40) |i| {
            try self.print("\r\x1b[2K\x1b[38;2;215;119;87m\xe2\x9c\xbb\x1b[0m Thinking\xe2\x80\xa6 ({d}s \xc2\xb7 \xe2\x86\x91 {d} tokens)", .{ i / 4, i * 37 });
        }
        try self.put("\r\x1b[2K");

        // Two or three long paragraphs, styled every few words, soft-wrapping.
        const paras = 2 + self.r().uintLessThan(usize, 2);
        for (0..paras) |_| {
            try self.put("\x1b[38;2;255;255;255m\xe2\x8f\xba\x1b[0m ");
            const len = 50 + self.r().uintLessThan(usize, 60);
            for (0..len) |w| {
                if (w % 7 == 3) {
                    try self.print("\x1b[38;2;{d};{d};{d}m{s}\x1b[0m ", .{
                        self.r().int(u8), self.r().int(u8), self.r().int(u8), self.word(),
                    });
                } else if (w % 11 == 5) {
                    try self.print("\x1b[1m`{s}`\x1b[22m ", .{self.word()});
                } else {
                    try self.print("{s} ", .{self.word()});
                }
            }
            try self.put("\r\n\r\n");
        }

        // Every 25 turns, a full-screen excursion (a pager, an editor) that
        // paints the alt screen with cursor addressing and leaves.
        if (n % 25 == 24) {
            try self.put("\x1b[?1049h\x1b[H\x1b[2J");
            for (1..capture_rows + 1) |row| {
                try self.print("\x1b[{d};1H\x1b[7m{d:>4}\x1b[27m {s} {s} {s}", .{ row, row, self.word(), self.word(), self.word() });
            }
            try self.put("\x1b[?1049l");
        }
    }

    /// How much of the stream's TAIL the emulator is fed. The emulator only
    /// keeps the newest rows that fit under its ceiling, so feeding it the
    /// whole stream would buy the same end state at several times the cost —
    /// and a Debug-built terminal parses at tens of KiB/s (its page integrity
    /// checks run on every operation), which made the full feed 85 s and 137 s.
    /// Each tail is sized to overrun the ceiling by a wide margin (asserted:
    /// the emulator must have PRUNED, i.e. be AT the ceiling, not short of it).
    fn emulatorTail(w: Workload) usize {
        return switch (w) {
            // ~70 content bytes a row; ~2,000 rows reach the ceiling.
            .build_log => 512 * 1024,
            // Most raw bytes are spinner redraws and SGR, collapsed to nothing.
            .agent_transcript => 1024 * 1024,
        };
    }

    fn fill(self: *Gen, w: Workload) !void {
        var n: usize = 0;
        while (self.out.items.len < stream_bytes) : (n += 1) switch (w) {
            .build_log => try self.buildLogLine(n),
            .agent_transcript => try self.transcriptTurn(n),
        };
    }
};

/// Bytes of terminal page memory the emulator holds, both screens.
fn pageBytes(emu: *GridEmulator) usize {
    var total: usize = 0;
    inline for (.{ .primary, .alternate }) |key| {
        if (emu.term.screens.get(key)) |screen| total += screen.pages.page_size;
    }
    return total;
}

const Measurement = struct {
    ring_bytes: usize,
    snap_narrow: usize,
    snap_wide: usize,
    page_bytes: usize,
    /// Rows the primary screen holds (scrollback + active) at capture.
    rows: usize,
    /// The primary screen has pruned history: it is AT its ceiling.
    saturated: bool,
    feed_ms: u64,
    serialize_ms: u64,
    parse_ms: u64,
};

fn measure(w: Workload) !Measurement {
    const alloc = testing.allocator;

    var gen = Gen.init(alloc);
    defer gen.deinit();
    try gen.fill(w);
    const stream = gen.out.items;

    const emu = try GridEmulator.create(alloc, capture_rows, capture_cols);
    defer emu.destroy();

    // Feed the tail in pty-sized chunks, the way `Session.recordOutput` does.
    // Start it on a line boundary so the first row is not a fragment.
    var off: usize = stream.len - Gen.emulatorTail(w);
    if (std.mem.indexOfScalarPos(u8, stream, off, '\n')) |nl| off = nl + 1;
    var timer = try std.time.Timer.start();
    while (off < stream.len) {
        const end = @min(stream.len, off + 16 * 1024);
        emu.feed(stream[off..end]);
        off = end;
    }
    const feed_ms = timer.lap() / std.time.ns_per_ms;

    try testing.expect(emu.hasScrollback());
    const primary = &emu.term.screens.get(.primary).?.pages;
    // At the ceiling: within one std page of it. (`page_serial_min` is not the
    // signal - a page grown past the standard size by a style-heavy row, which
    // truecolor transcripts produce constantly, is destroyed on prune rather
    // than recycled, and that path never advances it.)
    const saturated = primary.page_size * 10 >= primary.maxSize() * 9;
    const rows = primary.total_rows;
    const page_bytes = pageBytes(emu);

    // The ring a pre-T621 attach replays: the newest `default_ring_bytes`.
    const ring_bytes = @min(stream.len, session.default_ring_bytes);

    // Attach NARROWER than the capture geometry: reflow makes more rows.
    emu.ensureSize(40, 120);
    timer.reset();
    const narrow = try emu.snapshotAlloc(alloc, .{ .scrollback = true });
    defer alloc.free(narrow);
    const serialize_ms = timer.lap() / std.time.ns_per_ms;

    // What the client does with it: parse it into a fresh terminal at its
    // size. Timing only, so only when someone asked for the numbers - it is
    // seconds of Debug-lane time that assert nothing.
    var parse_ms: u64 = 0;
    if (perfOn()) {
        const client = try GridEmulator.create(alloc, 40, 120);
        defer client.destroy();
        timer.reset();
        client.feed(narrow);
        parse_ms = timer.lap() / std.time.ns_per_ms;
        try testing.expect(client.hasScrollback());
    }

    // And WIDER than it.
    emu.ensureSize(60, 300);
    const wide = try emu.snapshotAlloc(alloc, .{ .scrollback = true });
    defer alloc.free(wide);

    return .{
        .ring_bytes = ring_bytes,
        .snap_narrow = narrow.len,
        .snap_wide = wide.len,
        .page_bytes = page_bytes,
        .rows = rows,
        .saturated = saturated,
        .feed_ms = feed_ms,
        .serialize_ms = serialize_ms,
        .parse_ms = parse_ms,
    };
}

fn perfOn() bool {
    return std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PERF");
}

fn report(w: Workload, m: Measurement) void {
    if (!perfOn()) return;
    std.debug.print(
        "T1442 {s}: ring={d}KiB snap@120x40={d}KiB ({d}%) snap@300x60={d}KiB ({d}%) pages={d}KiB ceiling={d}KiB rows={d} saturated={} feed={d}ms serialize={d}ms parse={d}ms\n",
        .{
            @tagName(w),
            m.ring_bytes / 1024,
            m.snap_narrow / 1024,
            m.snap_narrow * 100 / m.ring_bytes,
            m.snap_wide / 1024,
            m.snap_wide * 100 / m.ring_bytes,
            m.page_bytes / 1024,
            grid_snapshot.max_scrollback_bytes / 1024,
            m.rows,
            m.saturated,
            m.feed_ms,
            m.serialize_ms,
            m.parse_ms,
        },
    );
}

fn check(w: Workload) !void {
    const m = try measure(w);
    report(w, m);

    // The emulator must actually be AT its ceiling, or every number above is
    // describing a session that has not filled yet.
    try testing.expect(m.saturated);

    // The trade T621 made: the repaint replaces the ring replay, so it must be
    // the smaller of the two at the sizes a session actually reaches.
    try testing.expect(m.snap_narrow < m.ring_bytes);
    try testing.expect(m.snap_wide < m.ring_bytes);

    // The per-session budget: page memory is bounded by the ceiling, plus the
    // active area `PageList` will never prune (one viewport at the largest
    // geometry measured, with headroom for the page rounding).
    const viewport_slack: usize = 1024 * 1024;
    try testing.expect(m.page_bytes <= grid_snapshot.max_scrollback_bytes + viewport_slack);
}

test "T1442: a build log at the scrollback ceiling repaints in fewer bytes than the ring it replaces" {
    try check(.build_log);
}

test "T1442: an agent transcript at the scrollback ceiling repaints in fewer bytes than the ring it replaces" {
    try check(.agent_transcript);
}
