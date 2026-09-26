//! The machine chooser's ONE hover-help tooltip control (T812, generalized in
//! T1633): a native comctl32 tooltip the system draws itself — the design
//! system leaves tooltips to the OS rather than owner-drawing them — carrying
//! two kinds of tool:
//!
//! - **One TRACK tool** (`TTF_TRACK | TTF_ABSOLUTE`) for everything the dialog
//!   PAINTS: the roster's CPU meters, End buttons and column headers, the
//!   account's email and monogram, and (through the list) a machine row's
//!   status dot. None of those is a window, so nothing but the dialog knows the
//!   pointer is on one; the dialog arms a show delay off its own hover tracking
//!   and places the tip here when it fires — the `Window.zig` tab-tip pattern.
//! - **One SUBCLASS tool per real child button** (`TTF_IDISHWND |
//!   TTF_SUBCLASS`): New Window, Restore All, Activity and the "..." button.
//!   comctl32 relays those buttons' own mouse messages, so the delay, the
//!   placement and — the part the dialog cannot do for a child — the dismissal
//!   when the pointer leaves the button straight out of the window are the
//!   system's. The dialog only keeps each tool's TEXT current.
//!
//! Text derivation is pure and lives in `chooser_help.zig`; the hit tests and
//! the debug oracle stay in `MachineChooser.zig`, which owns the state they
//! read. This file is only the control.

const std = @import("std");
const w32 = @import("win32.zig");
const chooser_help = @import("chooser_help.zig");

/// commctrl.h's values, from the one place that states them (T1744 corrected
/// `win32.zig`'s `TTF_SUBCLASS`, which this file used to work around).
const TTF_IDISHWND = w32.TTF_IDISHWND;
const TTF_SUBCLASS = w32.TTF_SUBCLASS;

/// The track tool's id in this control's tool space. Subclass tools are keyed
/// by their button's HWND (`TTF_IDISHWND`), which can never be 1.
const track_id: usize = 1;

/// The real child controls that carry a subclass tool, in slot order.
pub const Control = enum(u2) { new_window, restore_all, activity, manage };

const text_cap = chooser_help.max_len + 8;

pub const HelpTip = struct {
    /// Null until the first tip is needed — a chooser nobody hovers never
    /// makes one, and the control is destroyed with the dialog.
    hwnd: ?w32.HWND = null,
    /// Whether the TRACK tool is currently activated (visible).
    shown: bool = false,
    /// UTF-16 text handed to the track tool. The control is given the POINTER,
    /// so the buffer outlives every message that names it.
    track_text: [text_cap]u16 = undefined,
    /// Per-control tool text, same lifetime rule.
    control_text: [4][text_cap]u16 = undefined,
    /// Which buttons have their subclass tool registered.
    control_added: [4]bool = .{ false, false, false, false },
    /// The HWND each registered subclass tool is keyed on.
    control_hwnd: [4]?w32.HWND = .{ null, null, null, null },

    /// Create the control on first use, on the dialog's theme answer. The
    /// chooser is closed and rebuilt on a theme change, so it needs no mid-life
    /// reset.
    pub fn ensure(self: *HelpTip, owner: w32.HWND, hinstance: w32.HINSTANCE, dark: bool) ?w32.HWND {
        if (self.hwnd) |h| return h;

        var icc = w32.INITCOMMONCONTROLSEX{
            .dwSize = @sizeOf(w32.INITCOMMONCONTROLSEX),
            .dwICC = w32.ICC_TAB_CLASSES,
        };
        _ = w32.InitCommonControlsEx(&icc);

        const tip = w32.CreateWindowExW(
            w32.WS_EX_TOPMOST | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            w32.TOOLTIPS_CLASS,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP | w32.TTS_ALWAYSTIP | w32.TTS_NOPREFIX,
            w32.CW_USEDEFAULT,
            w32.CW_USEDEFAULT,
            w32.CW_USEDEFAULT,
            w32.CW_USEDEFAULT,
            owner,
            null,
            hinstance,
            null,
        ) orelse return null;

        if (dark) {
            _ = w32.SetWindowTheme(
                tip,
                std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
                null,
            );
        }

        self.track_text[0] = 0;
        var ti = self.trackToolInfo(owner);
        _ = w32.SendMessageW(tip, w32.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&ti)));
        // A max width is what makes a newline break lines - the CPU tip's
        // throttling line under its units line. Without one the control
        // renders both on one line.
        _ = w32.SendMessageW(tip, w32.TTM_SETMAXTIPWIDTH, 0, 0x7FFF);
        self.hwnd = tip;
        return tip;
    }

    fn trackToolInfo(self: *HelpTip, owner: w32.HWND) w32.TOOLINFOW {
        return .{
            .cbSize = @sizeOf(w32.TOOLINFOW),
            .uFlags = w32.TTF_TRACK | w32.TTF_ABSOLUTE,
            .hwnd = owner,
            .uId = track_id,
            .rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
            .hinst = null,
            .lpszText = @ptrCast(&self.track_text),
            .lParam = 0,
            .lpReserved = null,
        };
    }

    fn controlToolInfo(self: *HelpTip, owner: w32.HWND, slot: usize, ctl: w32.HWND) w32.TOOLINFOW {
        return .{
            .cbSize = @sizeOf(w32.TOOLINFOW),
            .uFlags = TTF_IDISHWND | TTF_SUBCLASS,
            .hwnd = owner,
            .uId = @intFromPtr(ctl),
            .rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
            .hinst = null,
            .lpszText = @ptrCast(&self.control_text[slot]),
            .lParam = 0,
            .lpReserved = null,
        };
    }

    /// Hide the TRACK tool. Safe from any state. Subclass tools hide
    /// themselves; this never touches them.
    pub fn hide(self: *HelpTip, owner: w32.HWND) void {
        if (!self.shown) return;
        self.shown = false;
        const tip = self.hwnd orelse return;
        var ti = self.trackToolInfo(owner);
        _ = w32.SendMessageW(tip, w32.TTM_TRACKACTIVATE, 0, @bitCast(@intFromPtr(&ti)));
    }

    /// Destroy the control. The next chooser makes its own on the theme it
    /// opens under.
    pub fn destroy(self: *HelpTip, owner: w32.HWND) void {
        self.hide(owner);
        const tip = self.hwnd orelse return;
        self.hwnd = null;
        self.control_added = .{ false, false, false, false };
        self.control_hwnd = .{ null, null, null, null };
        _ = w32.DestroyWindow(tip);
    }

    /// Show `text` on the track tool with its top-left at `screen` (screen
    /// coordinates). False when the text cannot be converted.
    pub fn showTrack(self: *HelpTip, owner: w32.HWND, tip: w32.HWND, text: []const u8, screen: w32.POINT) bool {
        const len16 = std.unicode.utf8ToUtf16Le(self.track_text[0 .. self.track_text.len - 1], text) catch return false;
        self.track_text[len16] = 0;
        var ti = self.trackToolInfo(owner);
        _ = w32.SendMessageW(tip, w32.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&ti)));
        const pos: isize = @bitCast(@as(usize, @as(u16, @bitCast(@as(i16, @truncate(screen.x))))) |
            (@as(usize, @as(u16, @bitCast(@as(i16, @truncate(screen.y))))) << 16));
        _ = w32.SendMessageW(tip, w32.TTM_TRACKPOSITION, 0, pos);
        _ = w32.SendMessageW(tip, w32.TTM_TRACKACTIVATE, 1, @bitCast(@intFromPtr(&ti)));
        self.shown = true;
        return true;
    }

    /// Register (first time) or re-word the subclass tool on control `c`.
    /// Called when the pointer ENTERS the control, before comctl32's show
    /// delay can elapse, so the words are always the selection's current ones.
    /// Empty `text` leaves a tool with no words, which comctl32 never shows.
    pub fn setControlText(
        self: *HelpTip,
        owner: w32.HWND,
        tip: w32.HWND,
        c: Control,
        ctl: w32.HWND,
        text: []const u8,
    ) void {
        const slot: usize = @intFromEnum(c);
        const buf = &self.control_text[slot];
        const len16 = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch 0;
        buf[len16] = 0;
        // A control re-created under the same slot (never today) would carry a
        // new HWND: drop the stale tool rather than re-wording a dead one.
        if (self.control_added[slot] and self.control_hwnd[slot] != ctl) {
            if (self.control_hwnd[slot]) |old| {
                var gone = self.controlToolInfo(owner, slot, old);
                _ = w32.SendMessageW(tip, w32.TTM_DELTOOLW, 0, @bitCast(@intFromPtr(&gone)));
            }
            self.control_added[slot] = false;
        }
        var ti = self.controlToolInfo(owner, slot, ctl);
        if (!self.control_added[slot]) {
            if (w32.SendMessageW(tip, w32.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&ti))) == 0) return;
            self.control_added[slot] = true;
            self.control_hwnd[slot] = ctl;
        } else {
            _ = w32.SendMessageW(tip, w32.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&ti)));
        }
    }
};
