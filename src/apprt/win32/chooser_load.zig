//! Pure model for the machine chooser's per-row LOAD reading (T1440): what a
//! row says about how busy its machine is, which rows get a probe, and the
//! retry memory that keeps a refused machine from being re-dialed every time
//! the user types into the filter.
//!
//! Ctrl+Shift+N lists the machines a window can open on, and until this every
//! row said only a name and (sometimes) a hostname - picking one was a guess.
//! The reading is Mac's `tcpSublineText` (MachineChooserView.swift:1668),
//! word for word: `CPU 12% · 3.2 GB / 16.0 GB`. Mac shows it only on direct-TCP
//! rows, which nothing ever creates (T1441 is that half); here it goes on every
//! relay row and on Local.
//!
//! Three rules shape it:
//!
//! - **The reading is APPENDED to the subline, never put in its place.** Mac's
//!   relay rows deliberately keep the hostname (`hostnameSubtext`), and the
//!   row has no third line. So a live row reads `winbox · CPU 12% · 3.2 GB /
//!   16.0 GB`, and the subline the row had before is always its prefix.
//! - **Only a live reading is drawn.** A row that is dialing, refused, or gone
//!   quiet shows its plain subline - no "Connecting…" on eight rows at once
//!   every time the picker opens, and no spinner on a machine that is off. A
//!   state we do not have is a state we do not paint (`activity_cards.State`'s
//!   rule, which the Activity Monitor's cards already follow).
//! - **Backoff is remembered by MACHINE, not by probe slot.** The filter
//!   rebuilds the candidate list on every keystroke, so a probe slot is retired
//!   the moment its row is filtered out. If the failure count lived in the slot,
//!   typing one letter and deleting it would reset a refused machine's 5-minute
//!   backoff to "dial now" - the tight loop `activity_probe` exists to refuse.
//!   `Backoff` outlives the slots for the chooser's whole life.
//!
//! `chooser_load_conn.zig` (T1440 follow-up) owns the sockets; this file is
//! all policy, so it runs in the `none` lane.

const std = @import("std");

const probe = @import("activity_probe.zig");

/// The same connection budget the Activity Monitor holds itself to. The chooser
/// can list up to 128 devices; it probes the first `max_probes` of what the
/// user can currently see.
pub const max_probes = probe.max_probes;

/// The cadence the chooser asks each agent for. The Activity Monitor's 1.5 s
/// cards are a panel you watch; a chooser is glanced at for a few seconds, and
/// a reading two seconds old answers "which box is pinned" just as well. Same
/// opening bid as the session CPU meter (`chooser_cpu.default_interval_ms`).
pub const interval_ms: u32 = 2000;

// ---------------------------------------------------------------------
// The reading
// ---------------------------------------------------------------------

/// One machine's load, as `protocol.HostMetrics` carries it: CPU busy % across
/// ALL cores (0..100 - unlike the session meter, this is a whole-machine number,
/// so it is never over 100), and physical memory in bytes.
pub const Load = struct {
    cpu_pct: f32 = 0,
    mem_used: u64 = 0,
    mem_total: u64 = 0,
};

/// What the chooser knows about one machine's load right now.
pub const Reading = union(enum) {
    /// Nobody has asked: no probe for this row (over budget, the Local row
    /// before its second sample, a row that just appeared).
    none,
    /// A dial is in flight or the link is up with no push yet.
    connecting,
    /// The newest pushed reading.
    live: Load,
    /// The dial was refused, or a live link went quiet. Backing off.
    failed,

    /// The load worth drawing, or null. Only `live` is ever drawn - see the
    /// file header's second rule.
    pub fn shown(self: Reading) ?Load {
        return switch (self) {
            .live => |l| l,
            else => null,
        };
    }
};

/// The longest `formatLoad` can produce: "CPU 100% · 99999.9 GB / 99999.9 GB"
/// with room to spare.
pub const max_load_len: usize = 64;

/// The longest `subline` can produce for a base the row can carry. Hostnames
/// are DNS-bounded; the cap here is what the chooser's scratch buffer is sized
/// to, and a longer base is truncated to fit rather than dropping the reading.
pub const max_subline_len: usize = 192;

const sep = " \u{00B7} ";

/// Whole percent, clamped to what a whole-machine reading can be. A malformed
/// frame's NaN or negative spells 0%, and nothing spells more than 100%.
fn pct(v: f32) f32 {
    if (!(v > 0)) return 0;
    return @round(@min(v, 100));
}

/// Mac's `memString`: gigabytes (2^30) with one decimal.
fn gb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1_073_741_824.0;
}

/// `CPU 12% · 3.2 GB / 16.0 GB` - Mac's `tcpSublineText` live case. An agent
/// that reported no memory total (a frame the wire allows but no shipped agent
/// sends) reads `CPU 12%` alone rather than `0.0 GB / 0.0 GB`, which would be
/// a confident statement about a machine with no RAM.
pub fn formatLoad(buf: []u8, load: Load) []const u8 {
    if (load.mem_total == 0) {
        return std.fmt.bufPrint(buf, "CPU {d:.0}%", .{pct(load.cpu_pct)}) catch "";
    }
    return std.fmt.bufPrint(buf, "CPU {d:.0}%" ++ sep ++ "{d:.1} GB / {d:.1} GB", .{
        pct(load.cpu_pct),
        gb(@min(load.mem_used, load.mem_total)),
        gb(load.mem_total),
    }) catch "";
}

/// The row's whole subline: its own `base` (the hostname, "Relay device",
/// "This machine"), with the reading appended when there is one to draw.
///
/// `base` is always the PREFIX of what this returns, so a row's own text never
/// changes when its machine gets busy - it only grows a suffix. When
/// `reading` has nothing to draw, `base` comes back untouched (the same slice,
/// not a copy).
pub fn subline(buf: []u8, base: []const u8, reading: Reading) []const u8 {
    const load = reading.shown() orelse return base;
    var lbuf: [max_load_len]u8 = undefined;
    const text = formatLoad(&lbuf, load);
    if (text.len == 0) return base;
    if (base.len == 0) {
        if (text.len > buf.len) return base;
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }
    const tail = sep.len + text.len;
    if (tail >= buf.len) return base;
    // A base too long for the buffer gives up its END, never the reading: the
    // reading is what the user opened the picker to find out, and the row's
    // painter ellipsizes whatever is left anyway.
    const keep = @min(base.len, buf.len - tail);
    @memcpy(buf[0..keep], base[0..keep]);
    @memcpy(buf[keep..][0..sep.len], sep);
    @memcpy(buf[keep + sep.len ..][0..text.len], text);
    return buf[0 .. keep + tail];
}

// ---------------------------------------------------------------------
// Which rows get a probe
// ---------------------------------------------------------------------

/// The machines that should hold a probe right now, written into `out`.
///
/// `visible` is the filtered list in display order (relay device ids; the Local
/// row is not in it - it is sampled in-process and needs no connection).
/// `selected` is the machine the chooser is browsing, or null when that is
/// Local: its reading rides the warm connection the chooser already holds for
/// it (`MachineConnectionPool`, T461), so it is never dialed a second time.
///
/// The budget goes to the TOP of the list, because the top is what the user
/// is looking at; a filter that narrows the list moves the budget onto what is
/// left, which is exactly the rows they are choosing between.
pub fn plan(visible: []const []const u8, selected: ?[]const u8, out: []probe.Target) usize {
    var cands: [max_plan_input]probe.Target = undefined;
    const n = @min(visible.len, cands.len);
    for (visible[0..n], 0..) |id, i| cands[i] = .{ .kind = .relay, .id = id };
    return probe.want(cands[0..n], selected == null, selected orelse "", out);
}

/// How many visible rows `plan` will look at. The chooser lists at most this
/// many devices (`MachineChooser.max_devices`); past it the budget is long
/// spent anyway.
pub const max_plan_input: usize = 128;

// ---------------------------------------------------------------------
// Backoff that survives the filter
// ---------------------------------------------------------------------

/// How many machines' failure history the chooser remembers. Sized to the
/// device list it can show, so a machine is only ever forgotten when the list
/// has more refused machines in it than the chooser can render.
pub const max_remembered: usize = 128;
pub const max_id: usize = 64;

/// Per-machine dial history for one chooser's life. GUI thread only.
///
/// Keyed by device id rather than by probe slot (file header, third rule). A
/// machine with no entry has never failed and is due now; `succeeded` deletes
/// the entry, so a machine that answered starts from a clean slate the next
/// time it refuses.
pub const Backoff = struct {
    ids: [max_remembered][max_id]u8 = undefined,
    id_len: [max_remembered]usize = @splat(0),
    attempts: [max_remembered]u32 = @splat(0),
    next_ms: [max_remembered]i64 = @splat(0),
    count: usize = 0,

    fn find(self: *const Backoff, id: []const u8) ?usize {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.ids[i][0..self.id_len[i]], id)) return i;
        }
        return null;
    }

    /// Whether `id` may be dialed at `now_ms`.
    pub fn due(self: *const Backoff, id: []const u8, now_ms: i64) bool {
        const i = self.find(id) orelse return true;
        return probe.dialDue(now_ms, self.next_ms[i]);
    }

    /// Consecutive failures on record for `id`.
    pub fn attemptsFor(self: *const Backoff, id: []const u8) u32 {
        const i = self.find(id) orelse return 0;
        return self.attempts[i];
    }

    /// The dial to `id` was refused (or its live link went quiet) at `now_ms`.
    /// Returns the deadline it may next be dialed at.
    pub fn failed(self: *Backoff, id: []const u8, now_ms: i64) i64 {
        if (id.len == 0 or id.len > max_id) {
            // An id we cannot key on is never remembered - and so would be
            // re-dialed at once. Hand back the floor so the caller can still
            // hold its own slot off for one period.
            return now_ms + @as(i64, @intCast(probe.retry_floor_ms));
        }
        const i = self.find(id) orelse self.insert(id);
        self.attempts[i] +|= 1;
        self.next_ms[i] = now_ms + @as(i64, @intCast(probe.retryDelayMs(self.attempts[i])));
        return self.next_ms[i];
    }

    /// The machine answered: forget its history.
    pub fn succeeded(self: *Backoff, id: []const u8) void {
        const i = self.find(id) orelse return;
        const last = self.count - 1;
        if (i != last) {
            self.ids[i] = self.ids[last];
            self.id_len[i] = self.id_len[last];
            self.attempts[i] = self.attempts[last];
            self.next_ms[i] = self.next_ms[last];
        }
        self.count = last;
    }

    /// A slot for a new id. When the table is full, the entry that is due
    /// SOONEST is given up: it is the one whose memory buys the least, since
    /// forgetting it only moves its next dial forward by what was left of a
    /// wait that was nearly over.
    fn insert(self: *Backoff, id: []const u8) usize {
        var i = self.count;
        if (i == max_remembered) {
            i = 0;
            for (1..self.count) |j| {
                if (self.next_ms[j] < self.next_ms[i]) i = j;
            }
        } else {
            self.count += 1;
        }
        @memcpy(self.ids[i][0..id.len], id);
        self.id_len[i] = id.len;
        self.attempts[i] = 0;
        self.next_ms[i] = 0;
        return i;
    }
};

/// Whether a live probe has gone quiet - `activity_probe.isStale` at the
/// chooser's cadence.
pub fn isStale(now_ms: i64, last_ms: i64) bool {
    return probe.isStale(now_ms, last_ms, interval_ms);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;
const GiB: u64 = 1024 * 1024 * 1024;

test "formatLoad is Mac's tcpSublineText, word for word" {
    var buf: [max_load_len]u8 = undefined;
    try testing.expectEqualStrings(
        "CPU 12% \u{00B7} 3.2 GB / 16.0 GB",
        formatLoad(&buf, .{ .cpu_pct = 12.4, .mem_used = GiB * 32 / 10, .mem_total = 16 * GiB }),
    );
    try testing.expectEqualStrings(
        "CPU 0% \u{00B7} 0.5 GB / 1.0 GB",
        formatLoad(&buf, .{ .cpu_pct = 0, .mem_used = GiB / 2, .mem_total = GiB }),
    );
}

test "formatLoad never spells a reading a machine cannot have" {
    var buf: [max_load_len]u8 = undefined;
    // Whole-machine CPU is 0..100; garbage clamps rather than printing a minus
    // sign or "NaN%".
    try testing.expectEqualStrings("CPU 0%", formatLoad(&buf, .{ .cpu_pct = -3 }));
    try testing.expectEqualStrings("CPU 0%", formatLoad(&buf, .{ .cpu_pct = std.math.nan(f32) }));
    try testing.expectEqualStrings("CPU 100%", formatLoad(&buf, .{ .cpu_pct = 140 }));
    // No total: no memory claim at all.
    try testing.expectEqualStrings("CPU 57%", formatLoad(&buf, .{ .cpu_pct = 57, .mem_used = GiB }));
    // Used past total is a race in the sampler, not more RAM than the box has.
    try testing.expectEqualStrings(
        "CPU 1% \u{00B7} 2.0 GB / 2.0 GB",
        formatLoad(&buf, .{ .cpu_pct = 1, .mem_used = 3 * GiB, .mem_total = 2 * GiB }),
    );
}

test "formatLoad fits max_load_len at the widest machine anyone owns" {
    var buf: [max_load_len]u8 = undefined;
    const t = formatLoad(&buf, .{ .cpu_pct = 100, .mem_used = 4096 * GiB, .mem_total = 4096 * GiB });
    try testing.expectEqualStrings("CPU 100% \u{00B7} 4096.0 GB / 4096.0 GB", t);
}

test "subline: only a live reading is drawn, and the base is always its prefix" {
    var buf: [max_subline_len]u8 = undefined;
    const live: Reading = .{ .live = .{ .cpu_pct = 12, .mem_used = 2 * GiB, .mem_total = 8 * GiB } };

    const s = subline(&buf, "winbox", live);
    try testing.expectEqualStrings("winbox \u{00B7} CPU 12% \u{00B7} 2.0 GB / 8.0 GB", s);
    try testing.expect(std.mem.startsWith(u8, s, "winbox"));

    // Dialing, refused, nobody asked: the row says exactly what it said before
    // T1440 - the same slice, not a copy and not a placeholder.
    const base: []const u8 = "Relay device";
    for ([_]Reading{ .none, .connecting, .failed }) |r| {
        const out = subline(&buf, base, r);
        try testing.expectEqual(base.ptr, out.ptr);
        try testing.expectEqualStrings(base, out);
    }
}

test "subline: an empty base is just the reading" {
    var buf: [max_subline_len]u8 = undefined;
    try testing.expectEqualStrings(
        "CPU 5%",
        subline(&buf, "", .{ .live = .{ .cpu_pct = 5 } }),
    );
}

test "subline: a base too long for the buffer gives up its end, never the reading" {
    var buf: [48]u8 = undefined;
    const long = "a-very-long-hostname.with.many.labels.example.internal";
    const s = subline(&buf, long, .{ .live = .{ .cpu_pct = 9 } });
    try testing.expect(s.len <= buf.len);
    try testing.expect(std.mem.endsWith(u8, s, " \u{00B7} CPU 9%"));
    try testing.expect(std.mem.startsWith(u8, s, "a-very-long"));

    // A buffer with no room for the reading at all keeps the base rather than
    // returning half a number.
    var tiny: [6]u8 = undefined;
    try testing.expectEqualStrings("host", subline(&tiny, "host", .{ .live = .{ .cpu_pct = 9 } }));
}

test "plan: the selected machine is never dialed twice" {
    const vis = [_][]const u8{ "dev-a", "dev-b", "dev-c" };
    var out: [max_probes]probe.Target = undefined;
    const n = plan(&vis, "dev-b", &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("dev-a", out[0].id);
    try testing.expectEqualStrings("dev-c", out[1].id);
    try testing.expectEqual(probe.Kind.relay, out[0].kind);
}

test "plan: Local selected probes every visible machine, up to the budget" {
    var ids: [20][8]u8 = undefined;
    var vis: [20][]const u8 = undefined;
    for (&ids, 0..) |*b, i| vis[i] = std.fmt.bufPrint(b, "dev-{d}", .{i}) catch unreachable;
    var out: [max_probes]probe.Target = undefined;
    const n = plan(&vis, null, &out);
    try testing.expectEqual(max_probes, n);
    // The budget goes to the top of the list.
    try testing.expectEqualStrings("dev-0", out[0].id);
    try testing.expectEqualStrings("dev-7", out[max_probes - 1].id);
}

test "plan: narrowing the filter moves the budget onto what is left" {
    var ids: [20][8]u8 = undefined;
    var vis: [20][]const u8 = undefined;
    for (&ids, 0..) |*b, i| vis[i] = std.fmt.bufPrint(b, "dev-{d}", .{i}) catch unreachable;
    var out: [max_probes]probe.Target = undefined;
    // "dev-1" matches dev-1 and dev-10..19: eleven rows, and the rows past the
    // old top eight now get probes.
    var narrowed: [20][]const u8 = undefined;
    var k: usize = 0;
    for (vis) |v| {
        if (std.mem.startsWith(u8, v, "dev-1")) {
            narrowed[k] = v;
            k += 1;
        }
    }
    const n = plan(narrowed[0..k], null, &out);
    try testing.expectEqual(max_probes, n);
    try testing.expectEqualStrings("dev-1", out[0].id);
    try testing.expectEqualStrings("dev-16", out[max_probes - 1].id);
}

test "Backoff: a machine that never failed is due now" {
    var b: Backoff = .{};
    try testing.expect(b.due("dev-a", 0));
    try testing.expectEqual(@as(u32, 0), b.attemptsFor("dev-a"));
}

test "Backoff: refusals double toward the ceiling, and success forgets them" {
    var b: Backoff = .{};
    const t0: i64 = 1_000_000;
    const next1 = b.failed("dev-a", t0);
    try testing.expectEqual(t0 + @as(i64, @intCast(probe.retry_floor_ms)), next1);
    try testing.expect(!b.due("dev-a", t0 + 1));
    try testing.expect(b.due("dev-a", next1));

    const next2 = b.failed("dev-a", next1);
    try testing.expectEqual(next1 + @as(i64, @intCast(probe.retry_floor_ms * 2)), next2);
    try testing.expectEqual(@as(u32, 2), b.attemptsFor("dev-a"));

    // Other machines are untouched by dev-a's history.
    try testing.expect(b.due("dev-b", t0));

    b.succeeded("dev-a");
    try testing.expect(b.due("dev-a", t0));
    try testing.expectEqual(@as(u32, 0), b.attemptsFor("dev-a"));
    // Forgetting something never recorded is a no-op, not a crash.
    b.succeeded("dev-z");
}

test "Backoff: filtering a refused row out and back in does not reset its wait" {
    // The T1440 churn rule. The slot is gone the moment the row is filtered out
    // (plan() no longer names it), but the history is keyed by machine - so the
    // keystroke that brings the row back finds it still waiting.
    var b: Backoff = .{};
    const t0: i64 = 5_000_000;
    for (0..5) |_| _ = b.failed("dev-off", t0);
    const vis_all = [_][]const u8{ "dev-off", "dev-on" };
    const vis_typed = [_][]const u8{"dev-on"};
    var out: [max_probes]probe.Target = undefined;
    _ = plan(&vis_typed, null, &out); // typed a letter: dev-off has no slot
    const n = plan(&vis_all, null, &out); // deleted it: dev-off is back
    try testing.expectEqual(@as(usize, 2), n);
    // ...and is still four minutes from its next dial, not due now.
    try testing.expect(!b.due("dev-off", t0 + 60_000));
    try testing.expectEqual(@as(u32, 5), b.attemptsFor("dev-off"));
}

test "Backoff: a full table gives up the entry closest to due" {
    var b: Backoff = .{};
    var ids: [max_remembered + 1][16]u8 = undefined;
    var names: [max_remembered + 1][]const u8 = undefined;
    for (&ids, 0..) |*buf, i| names[i] = std.fmt.bufPrint(buf, "dev-{d}", .{i}) catch unreachable;
    // dev-0 fails earliest, so its wait ends first.
    for (names[0..max_remembered], 0..) |n, i| _ = b.failed(n, @as(i64, @intCast(i)) * 1000);
    try testing.expectEqual(max_remembered, b.count);
    _ = b.failed(names[max_remembered], 999_999);
    try testing.expectEqual(max_remembered, b.count);
    try testing.expectEqual(@as(u32, 0), b.attemptsFor("dev-0"));
    try testing.expectEqual(@as(u32, 1), b.attemptsFor(names[max_remembered]));
    try testing.expectEqual(@as(u32, 1), b.attemptsFor("dev-1"));
}

test "Backoff: an id it cannot key on is still held off one period" {
    var b: Backoff = .{};
    const long = "x" ** (max_id + 1);
    const t0: i64 = 10_000;
    try testing.expectEqual(t0 + @as(i64, @intCast(probe.retry_floor_ms)), b.failed(long, t0));
    try testing.expectEqual(@as(usize, 0), b.count);
}

test "isStale: five missed pushes at the chooser's cadence" {
    try testing.expect(!isStale(10_000, 0)); // never answered: connecting
    try testing.expect(!isStale(10_000 + interval_ms * 5, 10_000));
    try testing.expect(isStale(10_000 + interval_ms * 5 + 1, 10_000));
}
