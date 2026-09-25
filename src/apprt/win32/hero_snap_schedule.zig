//! When a hero-mode carousel thumbnail may be captured (T1423; Mac parity
//! with `HeroSnapshotScheduler.swift`, origin/main bc89bb8f3).
//!
//! Thumbnails are a glance affordance, not a live mirror, and capturing one is
//! not free. On this side the costs land in two places:
//!
//! - A terminal capture is a GL blit + `glReadPixels` on the pane's OWN
//!   renderer thread, between drawing a frame and presenting it. The readback
//!   is synchronous, so the frame it rides on waits for the GPU to drain — and
//!   the carousel asks EVERY leaf, the hero pane included, every 150ms. A hero
//!   terminal being typed into lost a frame's worth of latency to its own
//!   thumbnail seven times a second.
//! - A viewer capture is `ICoreWebView2::CapturePreview`: the browser process
//!   paints the whole page out of band and PNG-encodes it (there is no size
//!   knob), and GDI+ decodes it on our GUI thread. That paint competes with
//!   the very scroll the user is performing in the hero pane.
//!
//! So, like the Mac: capture nothing while the user is driving the window,
//! and pace what is captured by what it costs. The heartbeat keeps ticking
//! through a gesture and simply declines, so the first tick after
//! `quiet_period_ms` of stillness IS the trailing refresh — there is no
//! separate "settled" timer to miss or cancel.
//!
//! Pure and clock-injected (every entry point takes `now_ms`), with no OS
//! imports, so its unit tests run in every app-runtime lane (the hero_math
//! pattern). The message-loop tap and the foreign-input probe that feed it
//! live in App.zig and Window.zig.
const std = @import("std");

/// Panes differ in capture cost by more than an order of magnitude, so they
/// get different idle cadences.
pub const PaneKind = enum { terminal, viewer };

/// How long the window must go without user input before captures resume.
/// Mac's number (0.3s), measured there from the true end of a momentum
/// scroll; a wheel notch here arrives as discrete messages, so the same
/// window covers the gap between notches of one continuous scroll.
pub const quiet_period_ms: i64 = 300;

/// Timers fire with jitter both ways (a 150ms `SetTimer` on this box lands
/// anywhere in ~140-160ms). Without slack a tick landing a hair early pushes
/// a capture out by a whole extra heartbeat, which for a terminal tile is a
/// visibly stuttering thumbnail. Mac: 0.01s.
pub const jitter_tolerance_ms: i64 = 10;

/// How long an async capture may stay outstanding before it is presumed lost
/// and a fresh one is allowed. `CapturePreview` answers only when the page
/// paints, so a wedged page would otherwise latch the in-flight guard and
/// freeze that tile for the life of the pane. Long enough that a merely slow
/// capture is never superseded. Mac: 5s.
pub const stale_capture_timeout_ms: i64 = 5000;

/// Minimum time between two captures of the same tile while idle. Mac's
/// numbers. The viewer's used to be 2s here (T397), chosen when nothing else
/// kept captures away from interaction; now that a capture can only start
/// while the window is quiet, the page's cost no longer lands on a gesture
/// and the Mac cadence carries across.
pub fn minimumIntervalMs(kind: PaneKind) i64 {
    return switch (kind) {
        .terminal => 150, // cheap: keep terminal thumbnails live
        .viewer => 1000, // expensive: a page rarely changes on its own
    };
}

pub const Scheduler = struct {
    /// When the user last did something in this window, or null for never.
    last_interaction_ms: ?i64 = null,

    /// Record that the user just did something in the carousel's window.
    /// A timestamp older than one already recorded is ignored, so a late
    /// foreign-input sample cannot shorten a quiet period a newer message
    /// already opened.
    pub fn noteInteraction(self: *Scheduler, at_ms: i64) void {
        if (self.last_interaction_ms) |prev| if (at_ms <= prev) return;
        self.last_interaction_ms = at_ms;
    }

    /// True when the window has been free of user input for `quiet_period_ms`.
    pub fn isQuiet(self: Scheduler, now_ms: i64) bool {
        const last = self.last_interaction_ms orelse return true;
        return now_ms - last >= quiet_period_ms - jitter_tolerance_ms;
    }

    /// Whether a tile of `kind` should capture on this tick.
    ///
    /// `last_capture_ms`: when this tile last ASKED for a capture (null for
    /// never). `in_flight_since_ms`: when its outstanding async capture
    /// started, or null if none is outstanding. `resized`: the tile size moved
    /// since the last capture, which skips the idle cadence (a picture at the
    /// wrong size is wrong, not merely old) but never the quiet gate.
    pub fn shouldCapture(
        self: Scheduler,
        now_ms: i64,
        kind: PaneKind,
        last_capture_ms: ?i64,
        in_flight_since_ms: ?i64,
        resized: bool,
    ) bool {
        if (in_flight_since_ms) |since| {
            if (now_ms - since < stale_capture_timeout_ms) return false;
        }
        if (!self.isQuiet(now_ms)) return false;
        if (resized) return true;
        const last = last_capture_ms orelse return true;
        return now_ms - last >= minimumIntervalMs(kind) - jitter_tolerance_ms;
    }
};

// ---------------------------------------------------------------------------
// What counts as interaction
// ---------------------------------------------------------------------------

// Window-message numbers, spelled out so this module needs no OS import.
const WM_KEYDOWN: u32 = 0x0100;
const WM_SYSKEYDOWN: u32 = 0x0104;
const WM_MOUSEMOVE: u32 = 0x0200;
const WM_LBUTTONDOWN: u32 = 0x0201;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_LBUTTONDBLCLK: u32 = 0x0203;
const WM_RBUTTONDOWN: u32 = 0x0204;
const WM_RBUTTONUP: u32 = 0x0205;
const WM_RBUTTONDBLCLK: u32 = 0x0206;
const WM_MBUTTONDOWN: u32 = 0x0207;
const WM_MBUTTONUP: u32 = 0x0208;
const WM_MBUTTONDBLCLK: u32 = 0x0209;
const WM_MOUSEWHEEL: u32 = 0x020A;
const WM_XBUTTONDOWN: u32 = 0x020B;
const WM_XBUTTONUP: u32 = 0x020C;
const WM_XBUTTONDBLCLK: u32 = 0x020D;
const WM_MOUSEHWHEEL: u32 = 0x020E;

/// MK_LBUTTON | MK_RBUTTON | MK_MBUTTON | MK_XBUTTON1 | MK_XBUTTON2.
const any_button_mask: usize = 0x0001 | 0x0002 | 0x0010 | 0x0020 | 0x0040;

/// Whether a queued message means the user is driving something and the
/// thumbnails should hold still. Mac's `interactionEventTypes`, translated:
/// wheel, button down/up, key down, and a DRAG — which on Windows is a
/// `WM_MOUSEMOVE` with a button held, since there is no separate message.
///
/// Plain pointer movement is deliberately excluded (Mac excludes it too):
/// drifting the mouse across the carousel is not driving anything, and letting
/// it suppress captures would stall thumbnails for as long as the pointer
/// keeps twitching.
pub fn isInteractionMessage(msg: u32, wparam: usize) bool {
    return switch (msg) {
        WM_KEYDOWN,
        WM_SYSKEYDOWN,
        WM_MOUSEWHEEL,
        WM_MOUSEHWHEEL,
        WM_LBUTTONDOWN,
        WM_LBUTTONUP,
        WM_LBUTTONDBLCLK,
        WM_RBUTTONDOWN,
        WM_RBUTTONUP,
        WM_RBUTTONDBLCLK,
        WM_MBUTTONDOWN,
        WM_MBUTTONUP,
        WM_MBUTTONDBLCLK,
        WM_XBUTTONDOWN,
        WM_XBUTTONUP,
        WM_XBUTTONDBLCLK,
        => true,
        WM_MOUSEMOVE => wparam & any_button_mask != 0,
        else => false,
    };
}

/// Input our message loop never sees. A viewer pane's page is drawn by
/// WebView2 child windows that belong to the BROWSER process, so a wheel
/// scroll or a keystroke over the hero viewer — the one gesture whose frames
/// a viewer capture steals — is delivered to that process's thread, not
/// ours. This is the Windows shape of the Mac bug's crux ("interaction was
/// read off the carousel, which never saw the scroll").
///
/// What IS visible is the session's last-input tick. It counts as interaction
/// here when all three hold:
///   - it moved since the previous sample (someone did something),
///   - our window is foreground (it was this window, not another app), and
///   - the pointer did NOT move between the two samples — so the input was a
///     wheel, a key or a click, not the plain pointer drift that the message
///     path above deliberately excludes.
///
/// A drag or a scroll with the pointer moving at the same time reads as
/// drift and slips through; that costs at most one capture mid-gesture and
/// errs on the side of a thumbnail that stays live.
pub fn foreignInputIsInteraction(
    last_input_moved: bool,
    window_is_foreground: bool,
    pointer_moved: bool,
) bool {
    return last_input_moved and window_is_foreground and !pointer_moved;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a fresh scheduler is quiet and captures every kind at once" {
    const s: Scheduler = .{};
    try testing.expect(s.isQuiet(0));
    try testing.expect(s.shouldCapture(0, .terminal, null, null, false));
    try testing.expect(s.shouldCapture(0, .viewer, null, null, false));
}

test "interaction pauses every capture until the quiet period passes" {
    var s: Scheduler = .{};
    s.noteInteraction(1_000);
    // During the gesture and just short of the quiet period: nothing, even a
    // tile that has never captured and even a resized one.
    for ([_]i64{ 1_000, 1_100, 1_289 }) |now| {
        try testing.expect(!s.isQuiet(now));
        try testing.expect(!s.shouldCapture(now, .terminal, null, null, false));
        try testing.expect(!s.shouldCapture(now, .viewer, null, null, true));
    }
    // The first tick at (or a jitter's width before) 300ms is the trailing
    // refresh.
    try testing.expect(s.isQuiet(1_290));
    try testing.expect(s.shouldCapture(1_290, .terminal, 900, null, false));
    try testing.expect(s.shouldCapture(1_300, .viewer, 0, null, false));
}

test "a continuous gesture keeps captures paused for its whole length" {
    var s: Scheduler = .{};
    // A wheel notch every 100ms for two seconds, heartbeat every 150ms.
    var captured: usize = 0;
    var now: i64 = 0;
    var next_notch: i64 = 0;
    while (now <= 2_000) : (now += 150) {
        while (next_notch <= now) : (next_notch += 100) s.noteInteraction(next_notch);
        if (s.shouldCapture(now, .terminal, null, null, false)) captured += 1;
    }
    try testing.expectEqual(@as(usize, 0), captured);
    // And the heartbeat after it settles captures.
    try testing.expect(s.shouldCapture(2_000 + 300, .terminal, null, null, false));
}

test "an older interaction sample never shortens a newer quiet period" {
    var s: Scheduler = .{};
    s.noteInteraction(1_000);
    s.noteInteraction(800);
    try testing.expectEqual(@as(?i64, 1_000), s.last_interaction_ms);
    try testing.expect(!s.isQuiet(1_200));
}

test "idle cadence is per kind: terminals live, viewers settle to 1s" {
    const s: Scheduler = .{};
    try testing.expectEqual(@as(i64, 150), minimumIntervalMs(.terminal));
    try testing.expectEqual(@as(i64, 1000), minimumIntervalMs(.viewer));

    // Terminal: every heartbeat, including one landing 10ms early.
    try testing.expect(s.shouldCapture(1_150, .terminal, 1_000, null, false));
    try testing.expect(s.shouldCapture(1_140, .terminal, 1_000, null, false));
    try testing.expect(!s.shouldCapture(1_139, .terminal, 1_000, null, false));

    // Viewer: declines until a second has passed.
    try testing.expect(!s.shouldCapture(1_500, .viewer, 1_000, null, false));
    try testing.expect(s.shouldCapture(1_990, .viewer, 1_000, null, false));
}

test "a resize jumps the idle cadence but not the quiet gate or the in-flight guard" {
    var s: Scheduler = .{};
    try testing.expect(s.shouldCapture(1_100, .viewer, 1_000, null, true));
    try testing.expect(!s.shouldCapture(1_100, .viewer, 1_000, 1_050, true));
    s.noteInteraction(1_050);
    try testing.expect(!s.shouldCapture(1_100, .viewer, 1_000, null, true));
}

test "an outstanding capture blocks the tile until it goes stale" {
    const s: Scheduler = .{};
    try testing.expect(!s.shouldCapture(1_000, .viewer, 0, 0, false));
    try testing.expect(!s.shouldCapture(4_999, .viewer, 0, 0, false));
    // Presumed lost: a wedged page no longer freezes the tile for good.
    try testing.expect(s.shouldCapture(5_000, .viewer, 0, 0, false));
}

test "interaction messages: wheel, buttons, keys and drags count; drift does not" {
    try testing.expect(isInteractionMessage(WM_MOUSEWHEEL, 0));
    try testing.expect(isInteractionMessage(WM_MOUSEHWHEEL, 0));
    try testing.expect(isInteractionMessage(WM_KEYDOWN, 0));
    try testing.expect(isInteractionMessage(WM_SYSKEYDOWN, 0));
    try testing.expect(isInteractionMessage(WM_LBUTTONDOWN, 0));
    try testing.expect(isInteractionMessage(WM_LBUTTONUP, 0));
    try testing.expect(isInteractionMessage(WM_RBUTTONDOWN, 0));
    try testing.expect(isInteractionMessage(WM_XBUTTONUP, 0));
    // A drag is a move with a button held (the hero divider, a selection).
    try testing.expect(isInteractionMessage(WM_MOUSEMOVE, 0x0001));
    try testing.expect(isInteractionMessage(WM_MOUSEMOVE, 0x0010));
    // Plain drift, and a move with only a modifier key held (MK_SHIFT).
    try testing.expect(!isInteractionMessage(WM_MOUSEMOVE, 0));
    try testing.expect(!isInteractionMessage(WM_MOUSEMOVE, 0x0004));
    // Key-up and character messages follow a keydown that already counted.
    try testing.expect(!isInteractionMessage(0x0101, 0)); // WM_KEYUP
    try testing.expect(!isInteractionMessage(0x0102, 0)); // WM_CHAR
    try testing.expect(!isInteractionMessage(0x000F, 0)); // WM_PAINT
}

test "foreign input counts only when it was ours and was not pointer drift" {
    try testing.expect(foreignInputIsInteraction(true, true, false));
    try testing.expect(!foreignInputIsInteraction(false, true, false));
    try testing.expect(!foreignInputIsInteraction(true, false, false));
    try testing.expect(!foreignInputIsInteraction(true, true, true));
}
