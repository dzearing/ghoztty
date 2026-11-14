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

    /// The terminal's grid is held under a drag (T2459, T2623): the resize
    /// only moves the renderer's view over the grid it has, the uncovered
    /// strips are filled with background in the same batch, and the frame the
    /// wait would buy shows the same text. Waiting is a third of a drag step
    /// (T2609) for nothing.
    grid_held: bool = false,

    /// The pane is opening out of its strip (T2458) and is hidden while its
    /// card carries the frame it draws (T2940): no pixel of it is on screen
    /// for a stale frame to show in, and the card takes that frame by itself,
    /// only at the size it asked for. The wait here held a fold glide's UI
    /// thread 4-26 ms on every resize of the opening pane. The pane's reveal,
    /// when the card is out, is where its frame at the new size matters, and
    /// `Window.revealOpeningPane` waits there when the frame is still behind.
    carried_hidden: bool = false,
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

/// The grid's height in a client area `client_h` px tall with `band` px
/// carved off its top (T2566): a window on the composition path spans its
/// pane's banner band. Never 0: a resize can arrive with the old size before
/// the layout's new band, and a zero-row grid is not a size.
pub fn gridHeight(client_h: u32, band: u32) u32 {
    return if (client_h > band) client_h - band else 1;
}

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
    if (p.grid_held) return false;
    if (p.carried_hidden) return false;
    return p.in_live_resize or p.in_live_layout;
}

test "T2940: a pane hidden under the card that carries its frame never waits" {
    for ([_][2]bool{ .{ true, false }, .{ false, true }, .{ true, true } }) |live| {
        try std.testing.expect(!shouldPresentSynchronously(.{
            .in_live_resize = live[0],
            .in_live_layout = live[1],
            .has_presented_frame = true,
            .carried_hidden = true,
        }));
        // The same pane shown waits as before.
        try std.testing.expect(shouldPresentSynchronously(.{
            .in_live_resize = live[0],
            .in_live_layout = live[1],
            .has_presented_frame = true,
        }));
    }
}

test "T2623: a held grid never waits for a frame, in a size loop or a live pass" {
    for ([_][2]bool{ .{ true, false }, .{ false, true }, .{ true, true } }) |live| {
        try std.testing.expect(!shouldPresentSynchronously(.{
            .in_live_resize = live[0],
            .in_live_layout = live[1],
            .has_presented_frame = true,
            .grid_held = true,
        }));
    }
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

test "T2593: only a tree pane inside an edge drag's live pass keeps its old region" {
    try std.testing.expect(deferRegionCut(true, true, true, true));
    // A pane on its own child window's target is clipped by the region.
    try std.testing.expect(!deferRegionCut(true, true, true, false));
    // With a redirection surface, outside the size loop, or outside a live
    // layout pass (a settle, a divider drag), the cut is made as before.
    try std.testing.expect(!deferRegionCut(false, true, true, true));
    try std.testing.expect(!deferRegionCut(true, false, true, true));
    try std.testing.expect(!deferRegionCut(true, true, false, true));
}

/// The pane a divider-drag pass is placing, as `holdDragRegion` weighs it
/// (T2932).
pub const DragRegionPane = struct {
    /// The divider drag is still running (`Window.dragging_split`).
    dragging: bool,
    /// The pane draws into a visual in the window's composition tree, which
    /// takes the card's shape itself (T2570), so its child window is there
    /// for input alone.
    in_tree: bool,
    /// The desk is on the chrome host's visual, not painted through the
    /// window's DC - so no paint is clipped by the child's region either.
    desk_on_visual: bool,
    /// The desk is being printed through the DC this pass (`desk_printing`).
    desk_printing: bool,
    /// The pass wants the rounded card shape (no slide cut, a real region).
    card_shape: bool,
    /// The default path (T2933): the pane presents through a swap chain on
    /// its own child window, whose root visual can carry the card's shape
    /// (`comp_overlay.RootClip`), and the drag clip is switched on
    /// (`GHOZTTY_DRAG_CARD_CLIP=1`).
    own_visual_clip: bool = false,
};

/// How a divider-drag pass treats one pane's card region (T2932/T2933).
pub const DragRegionHold = enum {
    /// Cut the window region as the pass always has.
    cut,
    /// Leave it: the pane's tree visual already has the shape and the desk is
    /// a visual, so the region clips nothing on screen (T2932).
    tree,
    /// Give the window no region for the rest of the drag, and the card shape
    /// to the pane's own root visual instead, with the desk laid under its
    /// corners through the pane's own DC (T2933). A stale region would clip a
    /// growing pane's new edge, so this one is cleared, not held.
    own_visual,
};

pub fn dragRegionHold(p: DragRegionPane) DragRegionHold {
    if (!p.dragging or !p.card_shape or p.desk_printing) return .cut;
    if (p.in_tree) return if (p.desk_on_visual) .tree else .cut;
    // Only with the desk painted through the window's DC: the corner fill
    // copies the desk's cached picture, which a visual desk does not keep.
    if (p.own_visual_clip and !p.desk_on_visual) return .own_visual;
    return .cut;
}

/// Whether a layout pass is still inside the divider drag's region hold
/// (T2874): while the hand drags, and after it lets go for as long as the
/// glide the drag started is still easing the cards to their slots. Releasing
/// at the mouse-up re-cut every pane there and then again on every settling
/// tick, and those settle cuts held the stalls the hold exists to remove. A
/// glide the drag did not leave held (`held` false) cuts as it always has.
pub fn dragRegionGesture(dragging: bool, held: bool, gliding: bool) bool {
    return dragging or (held and gliding);
}

test "T2874: the drag's region hold lasts through the glide it leaves settling, and no further" {
    try std.testing.expect(dragRegionGesture(true, false, false));
    try std.testing.expect(dragRegionGesture(true, true, true));
    // Let go with the glide still easing: the hold carries on.
    try std.testing.expect(dragRegionGesture(false, true, true));
    // The glide landed: the hold is over and the end pass cuts.
    try std.testing.expect(!dragRegionGesture(false, true, false));
    // A glide no drag held (a split opening, a sidebar collapse) never holds.
    try std.testing.expect(!dragRegionGesture(false, false, true));
    try std.testing.expect(!dragRegionGesture(false, false, false));
}

test "T2933: a default-path pane clips its own visual during a drag only when asked, and never once it ends" {
    const own: DragRegionPane = .{ .dragging = true, .in_tree = false, .desk_on_visual = false, .desk_printing = false, .card_shape = true, .own_visual_clip = true };
    try std.testing.expectEqual(DragRegionHold.own_visual, dragRegionHold(own));
    var p = own;
    p.own_visual_clip = false;
    try std.testing.expectEqual(DragRegionHold.cut, dragRegionHold(p));
    p = own;
    p.dragging = false;
    try std.testing.expectEqual(DragRegionHold.cut, dragRegionHold(p));
    // A slide cut, a printed desk and a desk on a visual all still cut.
    p = own;
    p.card_shape = false;
    try std.testing.expectEqual(DragRegionHold.cut, dragRegionHold(p));
    p = own;
    p.desk_printing = true;
    try std.testing.expectEqual(DragRegionHold.cut, dragRegionHold(p));
    p = own;
    p.desk_on_visual = true;
    try std.testing.expectEqual(DragRegionHold.cut, dragRegionHold(p));
    // A tree pane keeps T2932's hold whatever the knob says.
    p = own;
    p.in_tree = true;
    p.desk_on_visual = true;
    try std.testing.expectEqual(DragRegionHold.tree, dragRegionHold(p));
}

/// The four corner squares of a `w` x `h` card with corner radius `r`, in its
/// own pixels (T2933): what the desk is laid under while the pane's visual,
/// not its window region, cuts the curve. `square_top` keeps only the bottom
/// two. Returns how many it wrote.
pub fn cardCornerSquares(w: i32, h: i32, r: i32, square_top: bool, out: *[4][4]i32) usize {
    if (r <= 0 or w <= 0 or h <= 0) return 0;
    const s = @min(r, @min(@divFloor(w, 2), @divFloor(h, 2)));
    if (s <= 0) return 0;
    var n: usize = 0;
    if (!square_top) {
        out[n] = .{ 0, 0, s, s };
        n += 1;
        out[n] = .{ w - s, 0, w, s };
        n += 1;
    }
    out[n] = .{ 0, h - s, s, h };
    n += 1;
    out[n] = .{ w - s, h - s, w, h };
    n += 1;
    return n;
}

test "T2933: the corner squares sit in the card's corners, bottom two only under a header" {
    var q: [4][4]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), cardCornerSquares(100, 50, 8, false, &q));
    try std.testing.expectEqual([4]i32{ 0, 0, 8, 8 }, q[0]);
    try std.testing.expectEqual([4]i32{ 92, 0, 100, 8 }, q[1]);
    try std.testing.expectEqual([4]i32{ 0, 42, 8, 50 }, q[2]);
    try std.testing.expectEqual([4]i32{ 92, 42, 100, 50 }, q[3]);
    try std.testing.expectEqual(@as(usize, 2), cardCornerSquares(100, 50, 8, true, &q));
    try std.testing.expectEqual([4]i32{ 0, 42, 8, 50 }, q[0]);
    // A sliver of a pane never gets squares bigger than half of it.
    try std.testing.expectEqual(@as(usize, 4), cardCornerSquares(6, 50, 8, false, &q));
    try std.testing.expectEqual([4]i32{ 3, 0, 6, 3 }, q[1]);
    try std.testing.expectEqual(@as(usize, 0), cardCornerSquares(100, 50, 0, false, &q));
}

/// Whether a divider-drag pass leaves a pane's card region as it was until
/// the drag ends (T2932). Each `SetWindowRgn` (and the GDI region build
/// before it) is a system call that now and then blocks the UI thread for
/// milliseconds on a session-wide lock (T2874); a drag made about two a
/// frame for a shape nothing on screen reads while the pointer is captured.
/// The same reasoning as a window-edge drag's `deferRegionCut` and a glide's
/// held region (T2826). A slide cut (`card_shape` false) still cuts: the
/// stack-fold oracle reads those.
pub fn holdDragRegion(p: DragRegionPane) bool {
    return dragRegionHold(p) == .tree;
}

test "T2932: a divider drag holds only a tree pane's card region, and only while the desk is a visual" {
    const held: DragRegionPane = .{ .dragging = true, .in_tree = true, .desk_on_visual = true, .desk_printing = false, .card_shape = true };
    try std.testing.expect(holdDragRegion(held));
    // The drag over: the end-of-drag pass cuts.
    var p = held;
    p.dragging = false;
    try std.testing.expect(!holdDragRegion(p));
    // A pane presenting into its own child (a viewer) is clipped by its region.
    p = held;
    p.in_tree = false;
    try std.testing.expect(!holdDragRegion(p));
    // A desk painted through the window's DC is clipped by every region.
    p = held;
    p.desk_on_visual = false;
    try std.testing.expect(!holdDragRegion(p));
    p = held;
    p.desk_printing = true;
    try std.testing.expect(!holdDragRegion(p));
    // A slide cut is made every frame, as before.
    p = held;
    p.card_shape = false;
    try std.testing.expect(!holdDragRegion(p));
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

var system_redraw_state: ?bool = null;

/// `GHOZTTY_RESIZE_REDRAW` (T2577): let the system invalidate and erase what
/// a live layout pass's pane moves expose, with no redirection surface, as it
/// did before. UI thread only; read once per process.
pub fn liveSystemRedraw() bool {
    if (system_redraw_state) |v| return v;
    const v = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_RESIZE_REDRAW");
    system_redraw_state = v;
    return v;
}

var tree_regions_state: ?bool = null;

/// `GHOZTTY_RESIZE_TREE_REGIONS` (T2593): cut a tree pane's card region on
/// every step of a window-edge drag, as before, rather than once at
/// `WM_EXITSIZEMOVE`. UI thread only; read once per process.
pub fn liveTreeRegions() bool {
    if (tree_regions_state) |v| return v;
    const v = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_RESIZE_TREE_REGIONS");
    tree_regions_state = v;
    return v;
}

/// Whether a live layout pass leaves a pane's card region as it was until the
/// drag ends (T2593). Only for a pane whose picture is a visual in the
/// window's composition tree: its child window is there for input alone, so
/// the region decides nothing on screen, and a `SetWindowRgn` per pane per
/// step is window-manager work the drag waits on. A pane presenting into its
/// own child window is clipped by that region, so it is cut every step.
pub fn deferRegionCut(noredir: bool, in_size_loop: bool, in_live_layout: bool, in_tree: bool) bool {
    return noredir and in_size_loop and in_live_layout and in_tree;
}

var nav_nodefer_state: ?bool = null;

/// `GHOZTTY_RESIZE_NAV_NODEFER` (T2767): keep the viewer nav bar a moving,
/// self-painting window through a window-edge drag, as before, rather than
/// hiding it and letting the host paint its band - so a film can score the
/// drag both ways on one build. UI thread only; read once per process.
pub fn navStaysLive() bool {
    if (nav_nodefer_state) |v| return v;
    const v = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_RESIZE_NAV_NODEFER");
    nav_nodefer_state = v;
    return v;
}

var viewer_moves_state: ?bool = null;

/// `GHOZTTY_RESIZE_VIEWER_MOVES` (T2577): refresh WebView2's parent position on
/// every viewer move inside a modal size loop, as before, rather than once at
/// `WM_EXITSIZEMOVE`. UI thread only; read once per process.
pub fn liveViewerMoves() bool {
    if (viewer_moves_state) |v| return v;
    const v = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_RESIZE_VIEWER_MOVES");
    viewer_moves_state = v;
    return v;
}
