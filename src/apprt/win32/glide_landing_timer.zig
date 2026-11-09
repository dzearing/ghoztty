//! Whether a stack glide's tick can skip the window's live layout pass
//! (T2828, the landing timer T2572 wanted).
//!
//! In the composition pane tree a glide is handed to the compositor whole:
//! each pane visual's path (T2572), the faces of the cards folding into and
//! opening out of their strips (T2778/T2779/T2822), the strips that move
//! (T2825), and the pane sidebar's column (T2827). Once all of it is up,
//! nothing the per-tick layout pass places or paints changes until something
//! lands, so a tick that only moves things along their declared paths has
//! nothing for that pass to do: it steps the glide's own model - which says
//! when a card catches up, and where everything is drawn for a retarget to
//! start from - and stops there.
//!
//! The pass still runs on every tick that is NOT that shape: a card or strip
//! landing this tick (it is placed at its slot, a fold's face retires), the
//! whole glide landing, a drag reshaping the row (the hand drives the layout
//! and the gutters follow it), a glide that resizes as it goes, a frame still
//! on its way from a renderer (the face is declared again when it lands), a
//! pane or face not declared, and whenever the stepped path is asked for
//! (`GHOZTTY_GLIDE_DECLARE=0`, forced slow frames, off the tree,
//! `GHOZTTY_GLIDE_LANDING_TIMER=0`).

const std = @import("std");

/// What a tick knows when it decides.
pub const Inputs = struct {
    /// The landing timer is on: the composition pane tree, declared glides,
    /// no forced slow frames, and not switched off for an A/B.
    enabled: bool,
    /// The glide caught up on this step: it lands now.
    done: bool,
    /// A divider or grip drag is reshaping the row.
    gesturing: bool,
    /// The glide resizes as it goes (a drag's glide).
    resizing: bool,
    /// A drag's layout is waiting on this tick.
    layout_pending: bool,
    /// Caught-up cards and strips before and after this step
    /// (`Slide.caughtUp`).
    caught_before: u32,
    caught_after: u32,
    /// Every card still on its way, every moving strip and a followed
    /// sidebar column are on the compositor, and no carried frame is still
    /// on its way from a renderer.
    all_declared: bool,
};

/// True: this tick steps the glide's model and nothing else.
pub fn quiet(in: Inputs) bool {
    if (!in.enabled or in.done) return false;
    if (in.gesturing or in.resizing or in.layout_pending) return false;
    if (in.caught_before != in.caught_after) return false;
    return in.all_declared;
}

const testing = std.testing;

fn base() Inputs {
    return .{
        .enabled = true,
        .done = false,
        .gesturing = false,
        .resizing = false,
        .layout_pending = false,
        .caught_before = 1,
        .caught_after = 1,
        .all_declared = true,
    };
}

test "quiet: a tick that only moves declared visuals along skips the layout" {
    try testing.expect(quiet(base()));
}

test "quiet: every other tick lays out" {
    var in = base();
    in.enabled = false;
    try testing.expect(!quiet(in));

    in = base();
    in.done = true;
    try testing.expect(!quiet(in));

    in = base();
    in.gesturing = true;
    try testing.expect(!quiet(in));

    in = base();
    in.resizing = true;
    try testing.expect(!quiet(in));

    in = base();
    in.layout_pending = true;
    try testing.expect(!quiet(in));

    // A card landing mid-glide: placed at its slot by the pass.
    in = base();
    in.caught_after = 2;
    try testing.expect(!quiet(in));

    // A retarget can put a caught-up card back on its way.
    in = base();
    in.caught_after = 0;
    try testing.expect(!quiet(in));

    in = base();
    in.all_declared = false;
    try testing.expect(!quiet(in));
}
