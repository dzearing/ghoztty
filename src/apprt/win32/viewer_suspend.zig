//! Pure logic for putting a hidden viewer's page to sleep (T3035, PA-V03).
//! No OS imports, so its unit tests run in every app-runtime lane.
//!
//! A viewer pane that is hidden - its tab is not showing, or its window is
//! minimized - already tells WebView2 `IsVisible = false`, which stops the page
//! producing frames (T2913). But the renderer behind it keeps its whole heap
//! and its timers keep firing: a background tab holding a live website costs
//! the same memory as the one being read. WebView2 has two answers and this
//! drives both:
//!
//! - **Trim** (`ICoreWebView2_19.MemoryUsageTargetLevel = Low`) the moment the
//!   pane hides. Cheap and instantly reversible, so a quick tab flick pays
//!   nothing visible for it.
//! - **Suspend** (`ICoreWebView2_3.TrySuspend`) once the pane has stayed
//!   hidden for `suspend_delay_ms`. That freezes script and timers and lets
//!   the renderer drop more, but waking costs a beat, so it waits until the
//!   pane is plainly in the background rather than mid-flick.
//!
//! Showing the pane undoes both: WebView2 resumes a suspended view on its own
//! when `IsVisible` goes true, and the level goes back to Normal.
//!
//! The one hazard is work aimed at a page that is asleep. WebView2 accepts
//! every API call on a suspended view, but a script queued into a frozen
//! renderer does not run until something wakes it - so `+read`, a reload, a
//! capture or a find against a background tab would hang until its timeout.
//! `work` is the gate every such call passes first: it says whether to
//! `Resume`, and re-arms the timer so the page goes back to sleep once the
//! work is done and nobody has looked.

const std = @import("std");

/// How long a pane stays hidden before its page is suspended. Long enough that
/// switching tabs to glance at something and back never pays a resume.
pub const suspend_delay_ms: u32 = 30_000;

pub const State = enum {
    /// Shown, or hidden with nothing done yet.
    awake,
    /// Hidden; memory target lowered, suspend timer armed.
    trimmed,
    /// `TrySuspend` issued and not yet answered.
    suspending,
    /// The runtime confirmed the page is suspended.
    suspended,
};

pub const HideAction = struct {
    /// Set `MemoryUsageTargetLevel = Low`.
    trim: bool = false,
    /// (Re)start the suspend timer.
    arm_timer: bool = false,
};

pub const ShowAction = struct {
    /// Set `MemoryUsageTargetLevel = Normal`.
    restore_level: bool = false,
    /// Call `Resume` explicitly. WebView2 resumes on `IsVisible = true` by
    /// itself; this is belt and braces for a runtime that does not.
    @"resume": bool = false,
    /// Kill the pending suspend timer.
    cancel_timer: bool = false,
};

pub const WorkAction = struct {
    /// Call `Resume` before the work, or it waits on a frozen renderer.
    @"resume": bool = false,
    /// The pane is still hidden: restart the suspend timer so the page goes
    /// back to sleep after the work, not never.
    arm_timer: bool = false,
};

pub const Gate = struct {
    state: State = .awake,

    /// The pane was hidden.
    pub fn hide(self: *Gate) HideAction {
        switch (self.state) {
            .awake => {
                self.state = .trimmed;
                return .{ .trim = true, .arm_timer = true };
            },
            // Already asleep or on the way: nothing new to ask for.
            .trimmed, .suspending, .suspended => return .{},
        }
    }

    /// The pane was shown.
    pub fn show(self: *Gate) ShowAction {
        const was = self.state;
        self.state = .awake;
        return switch (was) {
            .awake => .{},
            .trimmed => .{ .restore_level = true, .cancel_timer = true },
            .suspending, .suspended => .{ .restore_level = true, .@"resume" = true, .cancel_timer = true },
        };
    }

    /// The suspend timer fired. True means call `TrySuspend` now. A timer that
    /// outlived a show, or fires while one request is already in flight, is
    /// answered with false.
    pub fn timerFired(self: *Gate, shown: bool) bool {
        if (shown or self.state != .trimmed) return false;
        self.state = .suspending;
        return true;
    }

    /// `TrySuspend` answered. A success that lands after the pane was shown
    /// (or woken for work) is stale and changes nothing - the view is awake.
    /// A refusal leaves the pane trimmed, which is still most of the win.
    pub fn suspendCompleted(self: *Gate, ok: bool) void {
        if (self.state != .suspending) return;
        self.state = if (ok) .suspended else .trimmed;
    }

    /// Renderer-bound work is about to be issued against this pane.
    pub fn work(self: *Gate, shown: bool) WorkAction {
        if (shown) return .{};
        return switch (self.state) {
            .awake => .{},
            .trimmed => .{ .arm_timer = true },
            .suspending, .suspended => blk: {
                self.state = .trimmed;
                break :blk .{ .@"resume" = true, .arm_timer = true };
            },
        };
    }

    pub fn isAsleep(self: Gate) bool {
        return self.state == .suspending or self.state == .suspended;
    }
};

const testing = std.testing;

test "hide trims and arms once; repeated hides ask for nothing" {
    var g: Gate = .{};
    const a = g.hide();
    try testing.expect(a.trim and a.arm_timer);
    try testing.expectEqual(State.trimmed, g.state);
    const b = g.hide();
    try testing.expect(!b.trim and !b.arm_timer);
}

test "a quick flick never suspends: show before the timer cancels it" {
    var g: Gate = .{};
    _ = g.hide();
    const s = g.show();
    try testing.expect(s.restore_level and s.cancel_timer and !s.@"resume");
    // The timer was killed, but a WM_TIMER already in the queue still lands.
    try testing.expect(!g.timerFired(true));
    try testing.expect(!g.timerFired(false));
    try testing.expectEqual(State.awake, g.state);
}

test "hidden past the delay suspends; show wakes and restores" {
    var g: Gate = .{};
    _ = g.hide();
    try testing.expect(g.timerFired(false));
    try testing.expectEqual(State.suspending, g.state);
    // A second tick while the first request is in flight does not re-issue.
    try testing.expect(!g.timerFired(false));
    g.suspendCompleted(true);
    try testing.expect(g.isAsleep());
    const s = g.show();
    try testing.expect(s.restore_level and s.@"resume" and s.cancel_timer);
    try testing.expect(!g.isAsleep());
}

test "a suspend that completes after the pane was shown is ignored" {
    var g: Gate = .{};
    _ = g.hide();
    try testing.expect(g.timerFired(false));
    _ = g.show();
    g.suspendCompleted(true);
    try testing.expectEqual(State.awake, g.state);
}

test "a refused suspend leaves the pane trimmed and re-armable" {
    var g: Gate = .{};
    _ = g.hide();
    try testing.expect(g.timerFired(false));
    g.suspendCompleted(false);
    try testing.expectEqual(State.trimmed, g.state);
    try testing.expect(g.timerFired(false));
}

test "work against a sleeping hidden page resumes it and re-arms the timer" {
    var g: Gate = .{};
    _ = g.hide();
    try testing.expect(g.timerFired(false));
    g.suspendCompleted(true);
    const w = g.work(false);
    try testing.expect(w.@"resume" and w.arm_timer);
    try testing.expectEqual(State.trimmed, g.state);
    // ...and it goes back to sleep when the re-armed timer fires.
    try testing.expect(g.timerFired(false));
}

test "work against an in-flight suspend resumes and the late answer is stale" {
    var g: Gate = .{};
    _ = g.hide();
    try testing.expect(g.timerFired(false));
    const w = g.work(false);
    try testing.expect(w.@"resume");
    g.suspendCompleted(true);
    try testing.expectEqual(State.trimmed, g.state);
}

test "work on a trimmed page only pushes the suspend back" {
    var g: Gate = .{};
    _ = g.hide();
    const w = g.work(false);
    try testing.expect(!w.@"resume" and w.arm_timer);
}

test "work on a shown page asks for nothing" {
    var g: Gate = .{};
    const w = g.work(true);
    try testing.expect(!w.@"resume" and !w.arm_timer);
    _ = g.hide();
    // Shown wins even if the gate thinks it is hidden (a show is in flight).
    const w2 = g.work(true);
    try testing.expect(!w2.@"resume" and !w2.arm_timer);
}
