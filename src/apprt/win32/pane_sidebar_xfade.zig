//! A list transition running on the pane sidebar's panel (T1880): what kind
//! it is, when it started, and the picture of the frame it leaves from. The
//! curve and the pixel math are `pane_sidebar_transition`; this is the GDI
//! side that holds the picture.

const std = @import("std");
const Dib32 = @import("dib32.zig");
const tr = @import("pane_sidebar_transition.zig");

pub const Kind = union(enum) {
    /// The scope switch; true going to all windows.
    scope: bool,
    fold: Fold,
};

/// A fold, as the list stood before it: the folded head's index and bottom,
/// how far down the list's content reached, and how far it was scrolled. The
/// frame after is measured against these at paint time; when the head moved
/// (the list re-scrolled under the fold) the transition is dropped and the
/// fold simply lands.
pub const Fold = struct {
    head: usize,
    y0: i32,
    bottom: i32,
    scroll: i32,
};

pub const Xfade = struct {
    kind: Kind,
    start_ms: u64 = 0,
    w: i32,
    h: i32,
    old: ?Dib32 = null,

    pub fn duration(self: *const Xfade) u64 {
        return switch (self.kind) {
            .scope => tr.scope_ms,
            .fold => tr.fold_ms,
        };
    }

    pub fn deinit(self: *Xfade) void {
        if (self.old) |d| d.destroy();
        self.old = null;
    }
};
