//! A list transition running on one of the pane sidebar's surfaces (T1880):
//! what kind it is, when it started, and the pictures of the frame it leaves
//! from. The curve and the pixel math are `pane_sidebar_transition`; this is
//! the GDI side that holds the pictures.
//!
//! The open card is presented in up to three paints - plain, and over white
//! and over black for its glass (T1887) - so it is pictured in all three,
//! and each present composes against the picture painted the same way.

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

/// The card key each picture is painted under (`PaneSidebar.card_key`):
/// none, the white glass pass, the black glass pass.
pub const keys = [_]?u32{ null, 0x00FF_FFFF, 0 };

pub fn variantOf(key: ?u32) usize {
    const k = key orelse return 0;
    return if (k == keys[1].?) 1 else 2;
}

pub const Xfade = struct {
    kind: Kind,
    start_ms: u64 = 0,
    w: i32,
    h: i32,
    old: [keys.len]?Dib32 = .{ null, null, null },

    pub fn duration(self: *const Xfade) u64 {
        return switch (self.kind) {
            .scope => tr.scope_ms,
            .fold => tr.fold_ms,
        };
    }

    pub fn deinit(self: *Xfade) void {
        for (&self.old) |*o| {
            if (o.*) |d| d.destroy();
            o.* = null;
        }
    }
};

