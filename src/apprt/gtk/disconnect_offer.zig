//! What a close on Linux can offer as **Disconnect** (T3563, Linux L11a): walk
//! away from the remote panes being closed while their sessions keep running
//! on the machine that hosts them. The Mac's `SessionDisconnectPolicy` and
//! win32's `Window.disconnectOffer`, over the shared pure policy in
//! `apprt/win32/session_disconnect.zig` (which pane counts, the wording, the
//! detach pin).
//!
//! Stated over plain facts so the rules run in the `none` lane: the GTK
//! adapter (`SplitTree.addDisconnectOffer`) reads them off live panes and
//! feeds them here one pane at a time.

const std = @import("std");
const policy = @import("../win32/session_disconnect.zig");

pub const PaneFacts = policy.PaneFacts;

/// A buffer this size always holds `Offer.body` and its NUL.
pub const body_cap: usize = policy.text_cap + 1;

/// The panes a close would spare, and the one machine they run on when there
/// is exactly one.
pub const Offer = struct {
    /// How many panes a Disconnect would keep running. Zero: no Disconnect.
    count: usize = 0,
    /// The machine's name while every counted pane runs on the same one.
    /// Borrowed from the pane's link, which outlives the dialog.
    machine: ?[]const u8 = null,
    /// Counted panes on more than one machine: the wording names none
    /// ("naming one and lying about the rest", Mac).
    mixed: bool = false,

    /// Count one pane. `machine` is the name of the machine its shell runs
    /// on, or null for a local pane - including a local-agent pane, which is
    /// excluded on purpose (closing one ends its session; that is
    /// session-persistence's contract, and the way to keep it is to quit).
    pub fn add(self: *Offer, facts: PaneFacts, machine: ?[]const u8) void {
        const name = machine orelse return;
        if (!policy.isDisconnectable(facts)) return;
        if (self.count == 0) {
            self.machine = name;
        } else if (!self.mixed) {
            if (self.machine == null or !std.mem.eql(u8, self.machine.?, name)) {
                self.mixed = true;
                self.machine = null;
            }
        }
        self.count += 1;
    }

    pub fn offered(self: Offer) bool {
        return self.count > 0;
    }

    /// The dialog body: the shared, scope-neutral wording (one sentence
    /// serves a pane, a tab and a window), NUL-terminated for GTK.
    pub fn body(self: Offer, buf: *[body_cap]u8) [:0]const u8 {
        const text = policy.informativeText(buf[0..policy.text_cap], self.machine, self.count);
        buf[text.len] = 0;
        return buf[0..text.len :0];
    }
};

/// What an interactive close does before it closes: the local gate
/// (`needs_confirm`, a running process) widened for a remote pane even when
/// it is idle (Mac: ending a process on another machine is not the
/// recoverable thing an idle local shell is).
pub const Step = enum { close, ask_running, ask_disconnect };

pub fn step(needs_confirm: bool, offer: Offer) Step {
    return switch (policy.closeStep(needs_confirm, offer.count, false)) {
        .close => .close,
        .ask_running => .ask_running,
        .ask_disconnect, .disconnect => .ask_disconnect,
    };
}

pub const DetachPin = policy.DetachPin;

const testing = std.testing;

const live: PaneFacts = .{ .has_surface = true, .process_exited = false, .confirm_close_enabled = true };

test "a local pane is never offered Disconnect, even a running one" {
    var o: Offer = .{};
    o.add(live, null);
    try testing.expect(!o.offered());
    try testing.expectEqual(Step.ask_running, step(true, o));
    try testing.expectEqual(Step.close, step(false, o));
}

test "an IDLE remote pane still asks: the gate widens for remote" {
    var o: Offer = .{};
    o.add(live, "devbox");
    try testing.expectEqual(@as(usize, 1), o.count);
    try testing.expectEqual(Step.ask_disconnect, step(false, o));
    try testing.expectEqualStrings("devbox", o.machine.?);
}

test "an exited shell, a viewer, and confirm-close-surface=false spare nothing" {
    var o: Offer = .{};
    o.add(.{ .has_surface = true, .process_exited = true, .confirm_close_enabled = true }, "devbox");
    o.add(.{ .has_surface = false, .process_exited = false, .confirm_close_enabled = true }, "devbox");
    o.add(.{ .has_surface = true, .process_exited = false, .confirm_close_enabled = false }, "devbox");
    try testing.expect(!o.offered());
    try testing.expectEqual(Step.close, step(false, o));
}

test "two machines name neither; one machine is named and counted" {
    var o: Offer = .{};
    o.add(live, "a");
    o.add(live, "a");
    try testing.expectEqualStrings("a", o.machine.?);
    o.add(live, "b");
    try testing.expect(o.mixed);
    try testing.expect(o.machine == null);
    o.add(live, "a");
    try testing.expect(o.machine == null);
    try testing.expectEqual(@as(usize, 4), o.count);
}

test "body: the shared wording, NUL-terminated" {
    var buf: [body_cap]u8 = undefined;
    var one: Offer = .{};
    one.add(live, "devbox");
    const b1 = one.body(&buf);
    try testing.expect(std.mem.startsWith(u8, b1, "This session runs on devbox."));
    try testing.expectEqual(@as(u8, 0), b1.ptr[b1.len]);

    var two: Offer = .{};
    two.add(live, "a");
    two.add(live, "b");
    try testing.expect(std.mem.startsWith(u8, two.body(&buf), "2 sessions run on the remote machine."));
}

test "the pin refuses a later CLOSE marking and lets a DETACH through" {
    var pin: DetachPin = .{};
    try testing.expectEqual(@as(?bool, true), pin.resolve(true));
    pin.pin();
    try testing.expectEqual(@as(?bool, null), pin.resolve(true));
    try testing.expectEqual(@as(?bool, false), pin.resolve(false));
    pin.clear();
    try testing.expectEqual(@as(?bool, true), pin.resolve(true));
}
