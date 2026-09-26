//! The machine chooser's ONE hover-help tooltip control (T812, generalized in
//! T1633): a native comctl32 tooltip carrying two kinds of tool:
//!
//! - **One TRACK tool** for everything the dialog PAINTS: the roster's CPU
//!   meters, End buttons and column headers, the account's email and monogram,
//!   and (through the list) a machine row's status dot.
//! - **One SUBCLASS tool per real child button**: New Window, Restore All,
//!   Activity and the "..." button.
//!
//! The control itself is `help_tooltip.zig`, shared with the Activity Monitor's
//! control bar since T1634; this file names the chooser's four buttons and its
//! text bound. Text derivation is pure and lives in `chooser_help.zig`; the hit
//! tests and the debug oracle stay in `MachineChooser.zig`, which owns the state
//! they read.

const chooser_help = @import("chooser_help.zig");
const help_tooltip = @import("help_tooltip.zig");

/// The real child controls that carry a subclass tool, in slot order.
pub const Control = enum(u2) { new_window, restore_all, activity, manage };

pub const HelpTip = help_tooltip.HelpTip(Control, chooser_help.max_len);
