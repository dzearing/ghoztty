//! Test-only: a box-wide turn-taking lock for every test whose ORACLE, or
//! whose side effect, is the system clipboard (T850, widened in T2353).
//!
//! A retried open (`clipboard_open`) makes one clipboard operation reliable; it
//! cannot make a SEQUENCE of them reliable, because the clipboard holds one set
//! of bytes for the whole window station and any other process may replace them
//! - or hold the clipboard open - between two of ours. The live copy test's
//! sequence is exactly that shape: write a sentinel, press Copy, then poll
//! until the needle appears. A second test binary writing its own sentinel,
//! putting the user's saved clipboard back, or simply holding the clipboard
//! open for its own round-trip test in the middle of that poll erases or blocks
//! the very bytes being waited for, and the poll then reports "the copy never
//! landed" over a copy that would have landed perfectly.
//!
//! Neither of the two things that isolate a loop lane covers this. Lanes have
//! their own build roots and their own repo mirrors, but they share one logon
//! session and therefore one clipboard: two lanes running
//! `zig build test -Dapp-runtime=win32` at the same moment are two test
//! binaries on one clipboard (T2353, 2026-10-27). So the lock lives in the
//! session's namespace, where every lane's binary meets it, and EVERY test that
//! opens the clipboard takes it - a lock only some of the contenders take is a
//! lock that protects nothing from the rest.
//!
//! It is a named mutex, which gives two properties nothing process-local
//! could: it is visible to every process in the session, and Windows releases
//! it automatically if its holder dies, so a crashed run cannot wedge the
//! lane. It guards only OUR sections. Another application copying at the same
//! instant still wins; nothing on Windows can prevent that, which is why the
//! oracles also re-check (`clipboard_open.holder`) rather than assuming.

const std = @import("std");
const w32 = @import("win32.zig");

const log = std.log.scoped(.clipboard_test_lock);

/// Session-local by design: the contenders are test binaries in one logon
/// session (one window station, one clipboard), and `Global\` would need
/// privileges a test should not want. Every clipboard test uses this name.
pub const default_name = std.unicode.utf8ToUtf16LeStringLiteral(
    "Local\\ghoztty-viewer-clipboard-test",
);

/// Waited in slices rather than one blocking call, so a caller with a message
/// loop keeps it running while it queues. WebView2 delivers everything through
/// that loop, and a test that stops pumping for minutes is a test that stalls
/// the browser side of whatever it is about to measure.
const slice_ms: u32 = 100;

/// How long a test waits for its turn before it gives up and FAILS. Five
/// minutes is two orders of magnitude past what a waiting turn costs (the
/// longest holder, the viewer copy section, holds it for seconds per case) and
/// still bounded - a lane that hangs teaches nobody anything.
pub const default_timeout_ms: u64 = 300 * std.time.ms_per_s;

pub const ClipboardTestLock = struct {
    handle: ?w32.HANDLE,
    owned: bool = false,

    pub fn init() ClipboardTestLock {
        return named(default_name);
    }

    /// A private name, for this module's own tests only: they must not queue
    /// behind - or block - a real clipboard test in another lane's binary.
    pub fn named(name: [*:0]const u16) ClipboardTestLock {
        return .{ .handle = w32.CreateMutexW(null, 0, name) };
    }

    pub fn deinit(self: *ClipboardTestLock) void {
        self.give();
        if (self.handle) |h| _ = w32.CloseHandle(h);
        self.handle = null;
    }

    pub const Outcome = enum { taken, timed_out, failed };

    /// Take the lock, pumping `msg` (when given) while waiting. False means it
    /// was not taken, with the reason logged - never a quiet proceed-anyway,
    /// since proceeding unlocked is precisely the flake this exists to remove.
    pub fn take(self: *ClipboardTestLock, msg: ?*w32.MSG, timeout_ms: u64) bool {
        return switch (self.acquire(msg, timeout_ms)) {
            .taken => true,
            .timed_out => blk: {
                log.err(
                    "clipboard test lock: not acquired within {d}ms; another " ++
                        "process is holding it far longer than a copy takes",
                    .{timeout_ms},
                );
                break :blk false;
            },
            .failed => blk: {
                log.err("clipboard test lock: unusable (err={d})", .{w32.GetLastError()});
                break :blk false;
            },
        };
    }

    /// `take` without the logging: the outcome, for a caller (this module's
    /// own exclusion test) to whom a timeout is the expected answer.
    pub fn acquire(self: *ClipboardTestLock, msg: ?*w32.MSG, timeout_ms: u64) Outcome {
        // Take/give are paired one-for-one. A Windows mutex is recursive, so a
        // nested take would succeed and the first give would then hand the
        // clipboard to the next process while this section is still using it -
        // the exact bug the lock exists to prevent, wearing the lock's name.
        std.debug.assert(!self.owned);
        const h = self.handle orelse return .failed;
        var timer = std.time.Timer.start() catch return .failed;
        while (true) {
            if (msg) |m| {
                while (w32.PeekMessageW(m, null, 0, 0, w32.PM_REMOVE) != 0) {
                    _ = w32.TranslateMessage(m);
                    _ = w32.DispatchMessageW(m);
                }
            }
            switch (w32.WaitForSingleObject(h, slice_ms)) {
                // ABANDONED is an acquisition: the previous holder died. The
                // clipboard state it left behind is irrelevant - every section
                // writes its own sentinel before it measures anything.
                w32.WAIT_OBJECT_0, w32.WAIT_ABANDONED => {
                    self.owned = true;
                    return .taken;
                },
                w32.WAIT_TIMEOUT => {},
                else => return .failed,
            }
            if (timer.read() >= timeout_ms * std.time.ns_per_ms) return .timed_out;
        }
    }

    /// Idempotent, so it is safe both as a `defer` and on the way out of
    /// `deinit` after an assertion has already unwound past the release.
    pub fn give(self: *ClipboardTestLock) void {
        if (!self.owned) return;
        if (self.handle) |h| _ = w32.ReleaseMutex(h);
        self.owned = false;
    }
};

/// The name the exclusion tests below share: distinct from `default_name` so
/// they never contend with a real clipboard test, and private to THIS process
/// so two concurrent test binaries running these same tests cannot slip into
/// each other's gap between a give and the next take (a soak of three
/// concurrent binaries did exactly that).
var probe_buf: [96]u16 = undefined;
var probe_name: [*:0]const u16 = undefined;

fn initProbeName() !void {
    var utf8: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&utf8, "Local\\ghoztty-clipboard-lock-selftest-{d}", .{w32.GetCurrentProcessId()});
    const n = try std.unicode.utf8ToUtf16Le(probe_buf[0 .. probe_buf.len - 1], s);
    probe_buf[n] = 0;
    probe_name = probe_buf[0..n :0].ptr;
}

fn probeTake(out: *ClipboardTestLock.Outcome) void {
    var lock = ClipboardTestLock.named(probe_name);
    defer lock.deinit();
    out.* = lock.acquire(null, 300);
}

test "a held lock excludes another holder, and giving it lets them in (T2353)" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    // A mutex is owned per THREAD, so a second thread stands in for the other
    // lane's test binary: what it cannot take, a second process cannot take
    // either - and this is the property every clipboard test now relies on.
    try initProbeName();
    var a = ClipboardTestLock.named(probe_name);
    defer a.deinit();
    try std.testing.expect(a.handle != null);
    try std.testing.expect(a.take(null, 1000));

    // Held: the other contender times out rather than slipping in. This is
    // the negative control - a lock that never excluded would make it true.
    var got_while_held: ClipboardTestLock.Outcome = .taken;
    {
        const t = try std.Thread.spawn(.{}, probeTake, .{&got_while_held});
        t.join();
    }
    try std.testing.expectEqual(ClipboardTestLock.Outcome.timed_out, got_while_held);

    // Given: the same contender now gets its turn.
    a.give();
    try std.testing.expect(!a.owned);
    var got_after_give: ClipboardTestLock.Outcome = .timed_out;
    {
        const t = try std.Thread.spawn(.{}, probeTake, .{&got_after_give});
        t.join();
    }
    try std.testing.expectEqual(ClipboardTestLock.Outcome.taken, got_after_give);

    // give() is idempotent: a defer after an explicit give is harmless.
    a.give();
}

test "a holder that dies hands the lock on instead of wedging it" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    // A thread that exits holding a mutex abandons it, which is what a crashed
    // test binary does to the other lane. The next take must SUCCEED (the
    // WAIT_ABANDONED arm), not time out - a dead run must never wedge the lane.
    try initProbeName();
    const Dier = struct {
        fn run() void {
            var lock = ClipboardTestLock.named(probe_name);
            _ = lock.take(null, 1000);
            // No give, no CloseHandle of an owned mutex's ownership: exiting
            // the thread is the abandonment. Closing our handle does not
            // release ownership, so the abandonment is what the next waiter
            // sees.
            if (lock.handle) |h| _ = w32.CloseHandle(h);
        }
    };
    const t = try std.Thread.spawn(.{}, Dier.run, .{});
    t.join();

    var next = ClipboardTestLock.named(probe_name);
    defer next.deinit();
    try std.testing.expect(next.take(null, 1000));
}
