//! The panes an IPC verb just created whose agent session is still being bound
//! (T1612).
//!
//! `+new-window` and `+split` build their pane on the GUI thread and used to
//! answer the instant it existed — but an agent-backed pane learns its
//! `session_id` only when the IO thread's OPEN comes back, 250-774 ms later on
//! a cold start. A script that ran `+list --json` right after the verb got no
//! `session_id` 11 times in 15. The contract now is that the verb answers once
//! its new panes are bound (or their bring-up has failed, or a bounded budget
//! ran out), so the id is readable the moment the verb returns.
//!
//! The waiting happens on the IPC LISTENER thread, never the GUI thread: the
//! handler records the new panes here, `IpcServer` copies the list into the
//! request's `Pending`, and the listener polls readiness back through the GUI
//! thread (the only thread allowed to walk panes) until it holds or the budget
//! is spent. The GUI thread keeps pumping the whole time, which it must — the
//! OPEN being waited on may need it.
//!
//! Pure data and policy only, so the none lane can test it.

const std = @import("std");
const pane_id = @import("pane_id.zig");

const SessionAwait = @This();

/// A verb creates at most two terminal panes (`+new-window --split`); four is
/// headroom, and a pane past it is simply not waited for — never an error.
pub const capacity = 4;

/// How long a verb's reply may be held for its panes' sessions. Measured
/// arrival was under 0.8 s cold; the budget is several times that, and a pane
/// whose bring-up FAILS ends the wait early (`IpcHandlers.sessionsSettled`), so the
/// budget is only ever spent on an agent that is neither answering nor failing.
pub const budget_ms: u64 = 3000;

/// Gap between readiness polls. Each poll is one GUI-thread round trip.
pub const poll_ms: u64 = 15;

ids: [capacity]pane_id.Buf = undefined,
lens: [capacity]u8 = @splat(0),
n: usize = 0,

/// Record a pane to wait for. Ids that are not pane ids, duplicates, and
/// anything past `capacity` are ignored.
pub fn add(self: *SessionAwait, id: []const u8) void {
    if (id.len == 0 or id.len > pane_id.len) return;
    for (0..self.n) |i| if (std.mem.eql(u8, self.get(i).id(), id)) return;
    if (self.n >= capacity) return;
    @memcpy(self.ids[self.n][0..id.len], id);
    self.lens[self.n] = @intCast(id.len);
    self.n += 1;
}

pub fn clear(self: *SessionAwait) void {
    self.n = 0;
}

pub fn isEmpty(self: *const SessionAwait) bool {
    return self.n == 0;
}

pub const Entry = struct {
    buf: *const pane_id.Buf,
    len: u8,

    pub fn id(self: Entry) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn get(self: *const SessionAwait, i: usize) Entry {
    return .{ .buf = &self.ids[i], .len = self.lens[i] };
}

test "add dedups, ignores empties, and caps at capacity" {
    var a: SessionAwait = .{};
    try std.testing.expect(a.isEmpty());
    a.add("");
    try std.testing.expect(a.isEmpty());
    a.add("11111111-1111-4111-8111-111111111111");
    a.add("11111111-1111-4111-8111-111111111111");
    try std.testing.expectEqual(@as(usize, 1), a.n);
    a.add("22222222-2222-4222-8222-222222222222");
    a.add("33333333-3333-4333-8333-333333333333");
    a.add("44444444-4444-4444-8444-444444444444");
    a.add("55555555-5555-4555-8555-555555555555");
    try std.testing.expectEqual(@as(usize, capacity), a.n);
    try std.testing.expectEqualStrings("22222222-2222-4222-8222-222222222222", a.get(1).id());
    a.clear();
    try std.testing.expect(a.isEmpty());
}

test "add ignores an over-long id rather than truncating it" {
    var a: SessionAwait = .{};
    a.add("x" ** (pane_id.len + 1));
    try std.testing.expect(a.isEmpty());
}

test "a copy carries its ids independently of the original" {
    var a: SessionAwait = .{};
    a.add("11111111-1111-4111-8111-111111111111");
    var b = a;
    a.clear();
    a.add("99999999-9999-4999-8999-999999999999");
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", b.get(0).id());
    b.clear();
}
