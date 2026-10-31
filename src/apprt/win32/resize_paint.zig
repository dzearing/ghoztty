//! Should a terminal surface's `WM_ERASEBKGND` paint the flat background, or
//! leave the pixels where they are for the GL frame that is already coming?
//!
//! T1031. The old answer was "always", with the comment that "the OpenGL
//! renderer will overwrite the entire client area on the next frame". The
//! *next* frame is the whole problem: the erase is synchronous and the GL
//! frame is not, so every erase puts one displayed frame of flat background
//! on screen before the content comes back. During a divider drag that is one
//! flash per motion tick, which is the strobing the user reported.
//!
//! The fill is not useless, though, and deleting it outright would trade a
//! flash for garbage:
//!
//!   * The search bar and the command palette are POPUPS registered under the
//!     same window class as the terminal surface, so they arrive at the same
//!     handler. They have no GL renderer behind them and paint their chrome in
//!     `WM_PAINT`; without the fill their background is whatever the desktop
//!     left there.
//!   * A surface that has never presented a frame has nothing behind it
//!     either. That is window creation, a restored session before its first
//!     draw, and a pane whose renderer has not started. Flat background is the
//!     right answer there — it is what the window is *about* to look like.
//!
//! So the rule is narrow: skip the fill only for the terminal surface window
//! itself, and only once the renderer has actually put a frame in it. Pure so
//! the rule is unit-testable in the `none` lane rather than only observable by
//! looking at a window.

const std = @import("std");

pub const Erase = struct {
    /// This HWND is the terminal surface window itself, rather than one of the
    /// popups that share its window class (search bar, command palette).
    is_surface_window: bool,

    /// The renderer thread has called `SwapBuffers` into this window at least
    /// once, so there are real pixels to preserve.
    has_presented_frame: bool,
};

/// True when the handler should `FillRect` the client area with the
/// background brush.
pub fn shouldFillBackground(e: Erase) bool {
    // Popups have no frame behind them, ever.
    if (!e.is_surface_window) return true;

    // Nothing to preserve yet: flat background beats undefined pixels.
    return !e.has_presented_frame;
}

/// The other half of "does the user see a blank frame": whether the pane
/// blocks for a frame at its new size before letting the resize land (T1393).
///
/// Declining the erase (above) only stops US from painting background. It does
/// nothing about the gap between the window changing size and the renderer
/// presenting at that size — during which the enlarged surface holds whatever
/// the GL front buffer had, i.e. the flat clear color. That gap is closed by
/// blocking the UI thread on the renderer's frame event, and until T1393 the
/// gate on it named the GESTURE rather than the situation: `in_live_resize`,
/// which is set at `WM_ENTERSIZEMOVE`.
///
/// Measured on 2026-09-06 with the `window resize cause=.. sync=..` oracle:
///
///   cause=restored  panes=2 sync=2   <- modal frame drag: guaranteed
///   cause=maximized panes=2 sync=0   <- maximize: no guarantee at all
///   cause=restored  panes=2 sync=0   <- restore: likewise
///
/// Maximize, restore, Aero-snap and a title-bar double-click resize the window
/// WITHOUT a modal size loop, so no `WM_ENTERSIZEMOVE` ever arrives and every
/// one of them relayouts panes the user is looking straight at with the
/// anti-flicker path switched off. Hence the rule below is about the pane's
/// state, not about which gesture got here: a pane with pixels in it waits;
/// a pane with nothing to preserve does not, because there the wait is a pure
/// stall (window creation, a restored session before its first draw) and the
/// flat background is the honest answer anyway — the same carve-out
/// `shouldFillBackground` makes, from the same fact.
pub const Present = struct {
    /// The pane is inside a modal size loop (`WM_ENTERSIZEMOVE` seen, no
    /// `WM_EXITSIZEMOVE` yet).
    in_live_resize: bool,

    /// The layout pass declared itself one the user is watching in real time —
    /// a divider drag, a banner expand/collapse, and since T1393 every
    /// whole-window `WM_SIZE` pass.
    in_live_layout: bool,

    /// The renderer thread has presented into this window at least once.
    has_presented_frame: bool,
};

/// A presented client size, packed into one word so it can cross the
/// renderer/UI thread boundary as a single atomic load and store (T1476).
///
/// Zero is "nothing presented yet", which is why the pack is width-major and
/// a zero-area frame can never be mistaken for a real one: the renderer
/// declines to draw at all when either dimension is 0.
pub fn packSize(width: u32, height: u32) u64 {
    return (@as(u64, width) << 32) | @as(u64, height);
}

/// Did the frame the wait came back on actually cover the size the pane was
/// resized to (T1476)?
///
/// `awaited` of 0 means the pane never went on the wait — a fresh pane, or a
/// pass that is not live — and there is nothing to be stale about.
pub fn presentIsStale(awaited: u64, presented: u64) bool {
    if (awaited == 0) return false;
    return presented != awaited;
}

/// Should the renderer throw away the frame it just drew instead of swapping
/// it (T2418)? `drawn` is the client size the frame was drawn for, measured
/// when it started; `client` is the window's client size now, just before the
/// swap. When they differ the layout moved the pane while the frame was being
/// drawn, and swapping it puts a frame for the old size at the pane's new
/// place: a column of text shown twice, and the swap's blit lands over the
/// gutter and card margin the window has just painted. The resize already
/// asked for a frame at the new size, so dropping this one loses nothing.
/// Either size unknown (0) keeps the swap - never drop a frame on a guess.
pub fn frameOutlivedItsWindow(drawn: u64, client: u64) bool {
    if (drawn == 0 or client == 0) return false;
    return drawn != client;
}

/// A client-space rectangle, `right`/`bottom` exclusive like a `RECT`.
pub const Strip = struct { left: u32, top: u32, right: u32, bottom: u32 };

/// The parts of a grown pane's client that its last presented frame does not
/// cover (T2485 D18). A pane with its own layer keeps the old frame's pixels
/// anchored top-left when it grows, and the strip beyond them is pure black
/// until the renderer presents at the new size. The compositor shows that
/// state for one frame on every tick of a drag that grows the pane: a black
/// column as wide as the tick's growth (40-47 px on a near-full-monitor
/// window). These strips, and only these, get the background fill - the
/// pixels the old frame did cover are never touched, which is the T1031 rule
/// above. Under a drag the grid is held (T2459), so what the new frame puts in
/// a grown strip is padding, which is the background anyway.
///
/// At most two strips: the column right of the old width (full new height)
/// and the row below the old height (old width only, so they never overlap).
/// Nothing presented (0) or nothing grown gives none.
pub const Uncovered = struct { len: u8, strips: [2]Strip };

pub fn uncoveredStrips(presented: u64, width: u32, height: u32) Uncovered {
    var out: Uncovered = .{ .len = 0, .strips = undefined };
    if (presented == 0) return out;
    const old_w: u32 = @intCast(presented >> 32);
    const old_h: u32 = @truncate(presented);
    if (width > old_w) {
        out.strips[out.len] = .{ .left = old_w, .top = 0, .right = width, .bottom = height };
        out.len += 1;
    }
    if (height > old_h) {
        out.strips[out.len] = .{ .left = 0, .top = old_h, .right = @min(old_w, width), .bottom = height };
        out.len += 1;
    }
    return out;
}

/// The panes a live layout batch resized, held so their resize WORK waits
/// until every one of them has had its uncovered-strip fill (T2485 D18b).
/// `EndDeferWindowPos` moves every pane at once and then sends each its
/// `WM_SIZE` in turn; a pane whose fill had to wait behind the earlier panes'
/// grid reflow and renderer wake was composed black for a frame (6 of a
/// near-full drag's ticks after D18). The batch fills them all first, then
/// drains this list. One entry per pane: a second `WM_SIZE` for the same pane
/// in one batch keeps its last size. `add` false = full, resize inline.
pub fn Pending(comptime T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { pane: T, width: u32, height: u32 };

        len: usize = 0,
        entries: [cap]Entry = undefined,

        pub fn add(self: *Self, pane: T, width: u32, height: u32) bool {
            for (self.entries[0..self.len]) |*e| if (e.pane == pane) {
                e.width = width;
                e.height = height;
                return true;
            };
            if (self.len >= cap) return false;
            self.entries[self.len] = .{ .pane = pane, .width = width, .height = height };
            self.len += 1;
            return true;
        }

        /// The held entries, emptying the list, so a resize the drain sets
        /// off can open a batch of its own without seeing these.
        pub fn take(self: *Self) Self {
            const out = self.*;
            self.len = 0;
            return out;
        }
    };
}

/// True when `handleResize` should block for a frame at the new size.
pub fn shouldPresentSynchronously(p: Present) bool {
    // Nothing on screen to go stale: waiting here buys no pixels and costs the
    // startup path a frame per pane.
    if (!p.has_presented_frame) return false;
    return p.in_live_resize or p.in_live_layout;
}

test "popups always get the flat fill" {
    // Both popup states, because "has presented a frame" is meaningless for a
    // window with no renderer and must not accidentally start gating them.
    try std.testing.expect(shouldFillBackground(.{
        .is_surface_window = false,
        .has_presented_frame = false,
    }));
    try std.testing.expect(shouldFillBackground(.{
        .is_surface_window = false,
        .has_presented_frame = true,
    }));
}

test "a surface with no frame yet gets the flat fill" {
    try std.testing.expect(shouldFillBackground(.{
        .is_surface_window = true,
        .has_presented_frame = false,
    }));
}

test "a surface that has presented is left alone" {
    // The one case that changed in T1031, and the whole point of the module.
    try std.testing.expect(!shouldFillBackground(.{
        .is_surface_window = true,
        .has_presented_frame = true,
    }));
}

test "a modal frame drag presents synchronously" {
    try std.testing.expect(shouldPresentSynchronously(.{
        .in_live_resize = true,
        .in_live_layout = false,
        .has_presented_frame = true,
    }));
}

test "a watched layout pass presents synchronously without a size loop" {
    // T1393: maximize, restore, Aero-snap and a title-bar double-click raise
    // no WM_ENTERSIZEMOVE, so `in_live_resize` is false through a resize the
    // user is watching. The pass says it is live instead, and that is enough.
    try std.testing.expect(shouldPresentSynchronously(.{
        .in_live_resize = false,
        .in_live_layout = true,
        .has_presented_frame = true,
    }));
}

test "a pane with nothing presented never stalls" {
    // Both live flags on, and still no wait: there are no pixels to preserve,
    // so the block would be a pure frame of latency at window creation.
    try std.testing.expect(!shouldPresentSynchronously(.{
        .in_live_resize = true,
        .in_live_layout = true,
        .has_presented_frame = false,
    }));
}

test "an unwatched relayout stays asynchronous" {
    try std.testing.expect(!shouldPresentSynchronously(.{
        .in_live_resize = false,
        .in_live_layout = false,
        .has_presented_frame = true,
    }));
}

test "packed sizes distinguish a transposed resize" {
    // 800x600 and 600x800 are the same two numbers, and a pack that could not
    // tell them apart would call a drag that swapped them "already presented".
    try std.testing.expect(packSize(800, 600) != packSize(600, 800));
    try std.testing.expectEqual(@as(u64, 0), packSize(0, 0));
}

test "a pane that never waited is never stale" {
    try std.testing.expect(!presentIsStale(0, packSize(800, 600)));
    try std.testing.expect(!presentIsStale(0, 0));
}

test "the frame the wait came back on has to be the size that was asked for" {
    const want = packSize(800, 600);
    // The defect: the renderer signals having presented the PREVIOUS size,
    // because that frame was already in flight when the resize landed.
    try std.testing.expect(presentIsStale(want, packSize(760, 600)));
    // Nothing presented at all is stale too — the wait timed out.
    try std.testing.expect(presentIsStale(want, 0));
    try std.testing.expect(!presentIsStale(want, want));
}

test "a frame drawn for a size the pane no longer has is dropped, not swapped" {
    // The T2418 shape: a divider drag shrank the pane from 900 to 870 wide
    // while its renderer was drawing at 900.
    try std.testing.expect(frameOutlivedItsWindow(packSize(900, 700), packSize(870, 700)));
    // Height counts as much as width (a banner toggle, a vertical split).
    try std.testing.expect(frameOutlivedItsWindow(packSize(900, 700), packSize(900, 640)));
    // The steady state: the window did not change under the frame.
    try std.testing.expect(!frameOutlivedItsWindow(packSize(900, 700), packSize(900, 700)));
}

test "a frame is never dropped on an unknown size" {
    // No measurement yet (the first frame), or the client rect could not be
    // read: swapping is the old behavior and the safe one.
    try std.testing.expect(!frameOutlivedItsWindow(0, packSize(900, 700)));
    try std.testing.expect(!frameOutlivedItsWindow(packSize(900, 700), 0));
}

test "a pane that grew wider gets exactly the column its last frame does not cover" {
    // run48 f130: pane 1 grew 961 -> 1005 in one tick, black at x961-1004.
    const r = uncoveredStrips(packSize(961, 1976), 1005, 1976);
    try std.testing.expectEqual(@as(u8, 1), r.len);
    try std.testing.expectEqual(Strip{ .left = 961, .top = 0, .right = 1005, .bottom = 1976 }, r.strips[0]);
}

test "a pane that grew both ways gets a column and a row that do not overlap" {
    const r = uncoveredStrips(packSize(800, 600), 840, 650);
    try std.testing.expectEqual(@as(u8, 2), r.len);
    try std.testing.expectEqual(Strip{ .left = 800, .top = 0, .right = 840, .bottom = 650 }, r.strips[0]);
    try std.testing.expectEqual(Strip{ .left = 0, .top = 600, .right = 800, .bottom = 650 }, r.strips[1]);
}

test "a pane that shrank, held still, or never presented gets no fill" {
    // Shrinking leaves no uncovered pixel: every pixel of the new client was
    // in the old frame. These are the pixels the T1031 rule protects.
    try std.testing.expectEqual(@as(u8, 0), uncoveredStrips(packSize(900, 700), 870, 700).len);
    try std.testing.expectEqual(@as(u8, 0), uncoveredStrips(packSize(900, 700), 900, 700).len);
    try std.testing.expectEqual(@as(u8, 0), uncoveredStrips(0, 900, 700).len);
    // Narrower but taller: only the row, and only as wide as the new client.
    const r = uncoveredStrips(packSize(900, 700), 870, 720);
    try std.testing.expectEqual(@as(u8, 1), r.len);
    try std.testing.expectEqual(Strip{ .left = 0, .top = 700, .right = 870, .bottom = 720 }, r.strips[0]);
}

test "a batch's held resizes keep one entry per pane, at its last size, in arrival order" {
    var p: Pending(u8, 4) = .{};
    try std.testing.expect(p.add(1, 961, 1976));
    try std.testing.expect(p.add(2, 300, 1976));
    try std.testing.expect(p.add(1, 1005, 1976));
    try std.testing.expectEqual(@as(usize, 2), p.len);
    try std.testing.expectEqual(@as(u8, 1), p.entries[0].pane);
    try std.testing.expectEqual(@as(u32, 1005), p.entries[0].width);
    try std.testing.expectEqual(@as(u8, 2), p.entries[1].pane);
}

test "a full batch says so, and taking it leaves it empty for the next" {
    var p: Pending(u8, 2) = .{};
    try std.testing.expect(p.add(1, 10, 10));
    try std.testing.expect(p.add(2, 10, 10));
    // A third pane resizes inline rather than being dropped.
    try std.testing.expect(!p.add(3, 10, 10));
    // A pane already held still updates in place when the list is full.
    try std.testing.expect(p.add(2, 20, 10));
    const held = p.take();
    try std.testing.expectEqual(@as(usize, 2), held.len);
    try std.testing.expectEqual(@as(u32, 20), held.entries[1].width);
    try std.testing.expectEqual(@as(usize, 0), p.len);
    try std.testing.expect(p.add(3, 10, 10));
}

/// T2418 experiment, off unless `GHOZTTY_PRESENT_RETIRE` is set: does the
/// divider drag's doubled first column come from a present the GPU retires
/// AFTER the layout moved the pane? `SwapBuffers` returns before the blit is
/// done, so a CPU-side gate around the swap (tried and refuted 2026-10-29)
/// orders the calls but not the pixels. With the switch on, a renderer holds
/// this gate shared from its size check through `SwapBuffers` and a
/// `glFinish`, and the layout pass holds it exclusive from the pane batch
/// through the band paint - so no present for the old place can land after
/// the bar was painted at the new one. Shared, not a mutex: panes present in
/// parallel with each other, and only the layout must wait them out.
pub var present_gate: std.Thread.RwLock = .{};

/// 0 = not read yet, 1 = off, 2 = on. Read once per process; both the UI and
/// the renderer threads ask, so it is an atomic rather than a lazy global.
var present_retire_state = std.atomic.Value(u8).init(0);

pub fn presentRetireOn() bool {
    const s = present_retire_state.load(.acquire);
    if (s != 0) return s == 2;
    const on = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PRESENT_RETIRE");
    present_retire_state.store(if (on) 2 else 1, .release);
    return on;
}
