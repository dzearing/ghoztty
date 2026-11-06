//! Latest-wins focus slot for the IO thread (T2495).
//!
//! FOCUS is control state where only the newest value matters, exactly like
//! RESIZE (see `Termio.pending_resize`). It used to travel through the bounded
//! termio mailbox as one message per change, and the GUI thread is the
//! producer: a burst of focus changes while the pane's IO thread was slow to
//! drain (a pane flooding output keeps the terminal lock hot, and every
//! `focusGained` takes that lock) filled the 64-deep queue, after which every
//! further change parked the GUI thread for the mailbox's full 50 ms give-up
//! before dropping it. 385 such drops in one focus-defer.ps1 run were ~19 s of
//! a GUI thread that answered no IPC request and painted nothing.
//!
//! So the value lives here and the queue carries at most ONE marker for it at
//! a time. The marker keeps the focus report ordered against the writes around
//! it in the normal case; it is pushed without waiting, and when the queue is
//! full and it cannot be, the IO thread's drain picks the value up from here
//! on its next wake instead. Either way the producer never blocks, the newest
//! value is never lost, and intermediate values that nobody could observe in
//! time are coalesced away.
const FocusSlot = @This();

const std = @import("std");

mutex: std.Thread.Mutex = .{},

/// The newest focus state not yet applied by the IO thread; null = nothing
/// pending.
pending: ?bool = null,

/// A `.focused` marker for `pending` is sitting in the mailbox queue. While it
/// is, the drain-start fallback leaves the value for the marker so the report
/// keeps its place in the queue's order.
marker_queued: bool = false,

/// Producer: record the newest state. Returns true when the caller must
/// enqueue a marker (none is queued yet); it must then call `markerDropped`
/// if that push fails.
pub fn set(self: *FocusSlot, focused: bool) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.pending = focused;
    if (self.marker_queued) return false;
    self.marker_queued = true;
    return true;
}

/// Producer: the marker could not be queued (the queue was full or closed).
/// Delivery falls to the drain-start fallback, `takeUnmarked`.
pub fn markerDropped(self: *FocusSlot) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.marker_queued = false;
}

/// Consumer: a marker was popped from the queue. Takes the newest value
/// (null if the fallback already applied it).
pub fn takeAtMarker(self: *FocusSlot) ?bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.marker_queued = false;
    const v = self.pending;
    self.pending = null;
    return v;
}

/// Consumer, at the start of every drain: takes a pending value whose marker
/// never made it into the queue. Leaves it alone while a marker is queued.
pub fn takeUnmarked(self: *FocusSlot) ?bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.marker_queued) return null;
    const v = self.pending;
    self.pending = null;
    return v;
}

const testing = std.testing;

test "FocusSlot: one marker for a burst, newest value wins" {
    var s: FocusSlot = .{};
    try testing.expect(s.set(true)); // first change queues a marker
    try testing.expect(!s.set(false)); // the burst rides the same marker
    try testing.expect(!s.set(true));
    try testing.expect(!s.set(false));
    try testing.expectEqual(@as(?bool, null), s.takeUnmarked()); // marker owns it
    try testing.expectEqual(@as(?bool, false), s.takeAtMarker());
    try testing.expectEqual(@as(?bool, null), s.takeUnmarked());
    // The next change needs a fresh marker.
    try testing.expect(s.set(true));
}

test "FocusSlot: a dropped marker is delivered by the drain fallback" {
    var s: FocusSlot = .{};
    try testing.expect(s.set(true));
    s.markerDropped(); // queue was full
    try testing.expectEqual(@as(?bool, true), s.takeUnmarked());
    try testing.expectEqual(@as(?bool, null), s.takeUnmarked());
    // And a later change queues a marker again.
    try testing.expect(s.set(false));
}

test "FocusSlot: a marker whose value the fallback took applies nothing" {
    var s: FocusSlot = .{};
    try testing.expect(s.set(true));
    s.markerDropped();
    try testing.expect(s.set(false)); // re-queued marker
    // Fallback must not race ahead of the queued marker.
    try testing.expectEqual(@as(?bool, null), s.takeUnmarked());
    try testing.expectEqual(@as(?bool, false), s.takeAtMarker());
    // A stale marker popped later finds nothing.
    try testing.expectEqual(@as(?bool, null), s.takeAtMarker());
}

test "FocusSlot: concurrent producer never loses the newest value" {
    var s: FocusSlot = .{};
    const N = 20000;
    const Producer = struct {
        fn run(slot: *FocusSlot) void {
            var i: usize = 0;
            while (i < N) : (i += 1) {
                // Odd index = true; the last write (i = N-1) is true.
                if (slot.set(i % 2 == 1)) {
                    // Simulate a full queue on every third marker.
                    if (i % 3 == 0) slot.markerDropped();
                }
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Producer.run, .{&s});
    // Consume concurrently, the way the IO thread's drain does.
    var last: ?bool = null;
    var spins: usize = 0;
    while (spins < N) : (spins += 1) {
        if (s.takeUnmarked()) |v| last = v;
        if (s.takeAtMarker()) |v| last = v;
    }
    t.join();
    if (s.takeUnmarked()) |v| last = v;
    if (s.takeAtMarker()) |v| last = v;
    try testing.expectEqual(@as(?bool, true), last);
}
