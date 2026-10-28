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

/// The column collapsing or expanding (T2291): the width it is leaving from
/// and the one it goes to, and the picture it left (`old_w` x `h`). The
/// column is drawn `tr.columnWidthAt` wide meanwhile, the two frames
/// crossfading in it (`tr.composeColumn`).
pub const Column = struct {
    start_ms: u64 = 0,
    from_w: i32,
    to_w: i32,
    h: i32,
    old: ?Dib32 = null,
    /// How long it runs: `tr.column_ms`, or the stretched one an acceptance
    /// script asks for (`GHOZTTY_SIDEBAR_COLUMN_MS`) to catch it mid-glide.
    ms: u64 = tr.column_ms,
    /// What it has put on screen so far (T2401), logged as it lands.
    frames: tr.Frames = .{},
    /// Whether its clock has been anchored at its first frame (T2401).
    anchored: bool = false,

    pub fn progress(self: *const Column, now_ms: u64) f64 {
        return tr.progress(now_ms -| self.start_ms, self.ms);
    }

    pub fn widthAt(self: *const Column, now_ms: u64) i32 {
        return tr.columnWidthAt(self.from_w, self.to_w, self.progress(now_ms));
    }

    pub fn done(self: *const Column, now_ms: u64) bool {
        return now_ms -| self.start_ms >= self.ms;
    }

    pub fn deinit(self: *Column) void {
        if (self.old) |d| d.destroy();
        self.old = null;
    }
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
