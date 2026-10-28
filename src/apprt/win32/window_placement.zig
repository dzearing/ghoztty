//! Pure rules for replaying a restored window's PLACEMENT — its normal rect and
//! its maximized state, which are one fact and have to travel together (T748).
//!
//! Three things live here, all of them the kind of detail that is invisible on
//! the box it was written on and wrong on somebody else's:
//!
//! 1. **The coordinate space.** `WINDOWPLACEMENT.rcNormalPosition` is NOT in
//!    screen coordinates. It is in *workspace* coordinates — screen coordinates
//!    shifted by the origin of the PRIMARY monitor's work area — which is
//!    identical to screen coordinates on the usual bottom-taskbar desktop and
//!    differs by the taskbar's thickness when it sits at the top or the left.
//!    Everything else in this codebase speaks screen coordinates: the manifest's
//!    `session_layout.Frame`, `restore_frame`'s monitor arithmetic (it asks
//!    `MonitorFromRect`, which only answers for screen coordinates), and
//!    `SetWindowPos`. So the conversion belongs at that one boundary and nowhere
//!    else, and both ends of the round trip — the capture that reads a maximized
//!    window's restore-down rect, and the restore that hands it back — go
//!    through the same pair of functions rather than each remembering the rule.
//!
//! 2. **Which show command a restore asks for.** Spelled out below.
//!
//! 3. **The scale a size was measured at** (T1971). Spelled out at
//!    `fitToMonitor`.
//!
//! Deliberately free of win32 (the caller supplies the work-area origin), so the
//! arithmetic runs in the none-runtime test lane.

const std = @import("std");

/// A rectangle in virtual-screen pixels — the manifest's own
/// `session_layout.Frame` shape. Shared with `restore_frame` so a frame can be
/// handed between the two without a third spelling of the same four fields.
pub const Rect = @import("restore_frame.zig").Rect;

/// The top-left of the primary monitor's WORK area (`SPI_GETWORKAREA`), which is
/// the offset between the two coordinate spaces. `(0, 0)` — a taskbar at the
/// bottom or the right, or an unreadable work area — makes both conversions the
/// identity, which is why this bug is invisible on almost every desktop.
pub const Origin = struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// Workspace → screen: what a `rcNormalPosition` read out of Windows means to
/// everything else here.
pub fn toScreen(r: Rect, work: Origin) Rect {
    return .{ .x = r.x +| work.x, .y = r.y +| work.y, .w = r.w, .h = r.h };
}

/// Screen → workspace: what a recorded frame has to become before it can be
/// handed back through `SetWindowPlacement`.
pub fn toWorkspace(r: Rect, work: Origin) Rect {
    return .{ .x = r.x -| work.x, .y = r.y -| work.y, .w = r.w, .h = r.h };
}

/// The show command a restore asks for, as a decision rather than a number.
///
/// The un-maximized case is deliberately the NO-ACTIVATE spelling
/// (`SW_SHOWNOACTIVATE`) rather than `SW_SHOWNORMAL`: a restore rebuilds every
/// window in turn, and each one grabbing the foreground on its way past is how
/// a multi-window restore ends up flipping activation between them. The
/// pre-T748 code applied its frame with `SWP_NOACTIVATE` for exactly that
/// reason, and this keeps that promise.
///
/// It also has to CLEAR a maximized state, and through `SetWindowPlacement` it
/// does — measured on the box: a window Windows had already maximized (from the
/// T85 placement memory) came back down onto `rcNormalPosition`, un-maximized,
/// when handed this show command. That is worth stating explicitly because
/// `ShowWindow(SW_SHOWNOACTIVATE)` is documented as "the most recent size and
/// position", which reads like it would leave a maximized window alone; the
/// placement call's `showCmd` is the state being ASKED FOR, not a hint.
///
/// The maximized case has no no-activate spelling — `SW_SHOWMAXIMIZED` is the
/// only way to maximize through a placement — which is no change: the pre-T748
/// code reached the same state through `ShowWindow(SW_MAXIMIZE)`, which
/// activates too.
pub const Show = enum {
    /// Un-maximize (or stay un-maximized) onto `rcNormalPosition`, without
    /// taking the foreground.
    show_noactivate,
    /// Maximize, with `rcNormalPosition` recorded as the restore-down rect.
    maximized,
};

pub fn show(maximized: bool) Show {
    return if (maximized) .maximized else .show_noactivate;
}

/// What a brand-new window (no session manifest behind it) opens as (T2342).
/// The `maximize` config wins over the placement memory - and defaults to true
/// since main's a0aaed0f2, so a new window fills the screen as Mac's does -
/// while the memory's size stays the restore-down size underneath. Two windows
/// never maximize: the quick terminal, which has its own geometry, and an
/// adopted popup that asked for a page size (T163), where a maximized sign-in
/// popup is exactly the "looks broken" case the request exists to avoid. A
/// restored window is not decided here: its manifest overrides this afterwards
/// (`applyRestoreFrame`).
pub const NewWindow = struct {
    config_maximize: bool,
    /// The placement memory's recorded state, null when nothing was loaded.
    remembered_maximized: ?bool = null,
    is_quick_terminal: bool = false,
    has_initial_size: bool = false,
};

pub fn startMaximized(w: NewWindow) bool {
    if (w.is_quick_terminal or w.has_initial_size) return false;
    return w.config_maximize or (w.remembered_maximized orelse false);
}

/// The outer rect Windows gives a maximized window on a monitor whose work area
/// is `work`: the sizing frame (`frame_x` / `frame_y`, per side) hangs off every
/// edge, so the client edge - not the border - meets the work area.
///
/// Needed by the background first show (T1966), which maximizes by style rather
/// than by show command: `SW_SHOWMAXIMIZED` is the only maximize spelling and it
/// activates, so a background window that must open maximized is given
/// `WS_MAXIMIZE`, moved here, and shown with `SW_SHOWNA` ("in its current
/// state", without activating). A zero-sized `work` (a failed query) answers
/// null and the caller opens the window at its restored size instead.
pub fn maximizedFrame(work: Rect, frame_x: i32, frame_y: i32) ?Rect {
    if (work.w <= 0 or work.h <= 0) return null;
    const fx = @max(frame_x, 0);
    const fy = @max(frame_y, 0);
    return .{
        .x = work.x -| fx,
        .y = work.y -| fy,
        .w = work.w +| 2 *| fx,
        .h = work.h +| 2 *| fy,
    };
}

/// The scale a size was measured at (T1971). Every number this module
/// and the manifest carry is a PHYSICAL pixel, and a physical pixel is only
/// half the story: 1200 pixels is a comfortable window at 100% and a small one
/// at 200%. Over Remote Desktop and Windows 365 the scale is a property of the
/// CONNECTION — the same Cloud PC is 100% from one client and 200% from
/// another — so a frame replayed as raw pixels comes back at whatever fraction
/// of its size the two scales differ by. A size therefore travels with the DPI
/// it was measured at, and is converted to the DPI it lands on. Mac never has
/// this problem because its frames are in points, which is exactly what a
/// pixel count over its DPI is.
pub const BASE_DPI: u32 = 96;

/// The built-in size of a window nobody has a record of, in device-independent
/// pixels: 800x600 at 100%, scaled to the monitor it opens on. Before T1971
/// these were physical pixels, so on a 200% desktop every such window opened
/// at a quarter of the intended area.
pub const DEFAULT_DIP_W: i32 = 800;
pub const DEFAULT_DIP_H: i32 = 600;

/// `v` measured at `from_dpi`, expressed at `to_dpi`, rounded to the nearest
/// pixel. A zero DPI on either side (unknown, or a query that failed) leaves
/// the value as recorded — replaying the number unchanged beats scaling by a
/// guess, the same rule `Origin` follows.
pub fn scaleDim(v: i32, from_dpi: u32, to_dpi: u32) i32 {
    if (from_dpi == 0 or to_dpi == 0 or from_dpi == to_dpi) return v;
    const num: i64 = @as(i64, v) * @as(i64, to_dpi);
    const den: i64 = @intCast(from_dpi);
    const half = @divTrunc(den, 2);
    const rounded = if (num >= 0) @divTrunc(num + half, den) else @divTrunc(num - half, den);
    return std.math.cast(i32, rounded) orelse (if (rounded < 0) std.math.minInt(i32) else std.math.maxInt(i32));
}

/// A recorded frame, sized for the monitor it is about to land on: the
/// top-left stays where it was (it is a position on the virtual screen, which
/// a scale change does not move), the size is converted from `saved_dpi` to
/// `target_dpi`, and the result is fitted inside `work` (the target monitor's
/// work area) — never larger than it, and shifted back on screen when the
/// rescaled size would hang off its right or bottom edge.
///
/// The fit only runs when the scale actually CHANGED. A frame measured at the
/// scale it lands on is replayed verbatim, the rule `restore_frame` keeps for
/// this machine's own manifest: a window the user stretched across two
/// monitors is a window they put there, not one to second-guess. A null
/// `saved_dpi` (a manifest written before T1971), an unknown `target_dpi`, and
/// a zero-sized `work` (a failed query) each leave their half of the rule out
/// rather than guessing.
pub fn fitToMonitor(r: Rect, saved_dpi: ?u32, target_dpi: u32, work: Rect) Rect {
    const sd = saved_dpi orelse return r;
    if (sd == 0 or target_dpi == 0 or sd == target_dpi) return r;
    var out = r;
    out.w = scaleDim(r.w, sd, target_dpi);
    out.h = scaleDim(r.h, sd, target_dpi);
    if (work.w <= 0 or work.h <= 0) return out;
    if (out.w > work.w) out.w = work.w;
    if (out.h > work.h) out.h = work.h;
    const right = work.x +| work.w;
    const bottom = work.y +| work.h;
    if (out.x +| out.w > right) out.x = right -| out.w;
    if (out.y +| out.h > bottom) out.y = bottom -| out.h;
    if (out.x < work.x) out.x = work.x;
    if (out.y < work.y) out.y = work.y;
    return out;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "a bottom-taskbar desktop makes both conversions the identity" {
    // The usual case, and the reason a workspace/screen mix-up can sit in the
    // code for months without anybody seeing it.
    const r: Rect = .{ .x = 200, .y = 120, .w = 1200, .h = 800 };
    try testing.expectEqual(r, toScreen(r, .{}));
    try testing.expectEqual(r, toWorkspace(r, .{}));
}

test "a taskbar at the top shifts the origin, never the size" {
    // 48px taskbar docked at the top of the primary monitor.
    const work: Origin = .{ .x = 0, .y = 48 };
    const screen: Rect = .{ .x = 100, .y = 148, .w = 900, .h = 600 };
    const workspace: Rect = .{ .x = 100, .y = 100, .w = 900, .h = 600 };

    try testing.expectEqual(workspace, toWorkspace(screen, work));
    try testing.expectEqual(screen, toScreen(workspace, work));
}

test "a taskbar on the left shifts x" {
    const work: Origin = .{ .x = 72, .y = 0 };
    const screen: Rect = .{ .x = 172, .y = 40, .w = 640, .h = 480 };
    try testing.expectEqual(
        Rect{ .x = 100, .y = 40, .w = 640, .h = 480 },
        toWorkspace(screen, work),
    );
}

test "the round trip is exact, including a window on a monitor left of primary" {
    const work: Origin = .{ .x = 0, .y = 48 };
    const cases = [_]Rect{
        .{ .x = 0, .y = 0, .w = 800, .h = 600 },
        .{ .x = -1920, .y = -200, .w = 1200, .h = 900 },
        .{ .x = 3000, .y = 1500, .w = 300, .h = 200 },
    };
    for (cases) |r| {
        try testing.expectEqual(r, toScreen(toWorkspace(r, work), work));
        try testing.expectEqual(r, toWorkspace(toScreen(r, work), work));
    }
}

test "a degenerate origin saturates instead of wrapping" {
    const r: Rect = .{ .x = std.math.maxInt(i32) - 1, .y = 0, .w = 10, .h = 10 };
    const out = toScreen(r, .{ .x = 1000, .y = 0 });
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), out.x);
    // The size is never touched by either conversion — only the origin moves.
    try testing.expectEqual(@as(i32, 10), out.w);
}

test "show: the recorded state decides, and only maximizing costs activation" {
    // Deliberately a function of the RECORDED state alone: what the window
    // happens to be right now (Windows may already have maximized it from the
    // placement memory) is not an input, because the placement call sets the
    // state being asked for either way.
    try testing.expectEqual(Show.maximized, show(true));
    try testing.expectEqual(Show.show_noactivate, show(false));
}

test "startMaximized: the default config opens a new window maximized (T2342)" {
    const Config = @import("../../config/Config.zig");
    const d: Config = .{};
    try testing.expect(d.maximize);
    try testing.expect(startMaximized(.{ .config_maximize = d.maximize }));
    // The memory's restored size does not undo the config.
    try testing.expect(startMaximized(.{ .config_maximize = true, .remembered_maximized = false }));
}

test "startMaximized: maximize = false falls back to the placement memory" {
    try testing.expect(!startMaximized(.{ .config_maximize = false }));
    try testing.expect(!startMaximized(.{ .config_maximize = false, .remembered_maximized = false }));
    try testing.expect(startMaximized(.{ .config_maximize = false, .remembered_maximized = true }));
}

test "startMaximized: the quick terminal and a sized popup never maximize" {
    try testing.expect(!startMaximized(.{ .config_maximize = true, .is_quick_terminal = true }));
    try testing.expect(!startMaximized(.{ .config_maximize = true, .remembered_maximized = true, .has_initial_size = true }));
}

test "maximizedFrame: the frame hangs off every edge of the work area" {
    // A 1920x1032 work area (bottom taskbar) with an 8px sizing frame.
    try testing.expectEqual(
        Rect{ .x = -8, .y = -8, .w = 1936, .h = 1048 },
        maximizedFrame(.{ .x = 0, .y = 0, .w = 1920, .h = 1032 }, 8, 8).?,
    );
    // A monitor left of primary with a top taskbar: only the origin moves.
    try testing.expectEqual(
        Rect{ .x = -1931, .y = 37, .w = 1942, .h = 1052 },
        maximizedFrame(.{ .x = -1920, .y = 48, .w = 1920, .h = 1030 }, 11, 11).?,
    );
}

test "maximizedFrame: an unreadable work area answers null, a negative frame is none" {
    try testing.expectEqual(@as(?Rect, null), maximizedFrame(.{ .x = 0, .y = 0, .w = 0, .h = 900 }, 8, 8));
    try testing.expectEqual(
        Rect{ .x = 0, .y = 0, .w = 1280, .h = 720 },
        maximizedFrame(.{ .x = 0, .y = 0, .w = 1280, .h = 720 }, -3, 0).?,
    );
}

test "scaleDim: a size measured at 100% doubles at 200% and rounds to the nearest pixel" {
    try testing.expectEqual(@as(i32, 2400), scaleDim(1200, 96, 192));
    try testing.expectEqual(@as(i32, 600), scaleDim(1200, 192, 96));
    // 150%: 801 * 144 / 96 = 1201.5 -> 1202 (half rounds away from zero).
    try testing.expectEqual(@as(i32, 1202), scaleDim(801, 96, 144));
    try testing.expectEqual(@as(i32, -1202), scaleDim(-801, 96, 144));
}

test "scaleDim: an unknown DPI on either side replays the number unchanged" {
    try testing.expectEqual(@as(i32, 1200), scaleDim(1200, 0, 192));
    try testing.expectEqual(@as(i32, 1200), scaleDim(1200, 96, 0));
    try testing.expectEqual(@as(i32, 1200), scaleDim(1200, 144, 144));
}

test "scaleDim saturates rather than wrapping" {
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), scaleDim(std.math.maxInt(i32), 96, 192));
}

test "the built-in default is 800x600 at 100% and twice that at 200%" {
    try testing.expectEqual(@as(i32, 1600), scaleDim(DEFAULT_DIP_W, BASE_DPI, 192));
    try testing.expectEqual(@as(i32, 1200), scaleDim(DEFAULT_DIP_H, BASE_DPI, 192));
    try testing.expectEqual(DEFAULT_DIP_W, scaleDim(DEFAULT_DIP_W, BASE_DPI, BASE_DPI));
}

test "fitToMonitor: the user's report - a 100% frame restored onto a 200% desktop keeps its DIP size" {
    // Saved at 96 DPI as 1000x700 at (100,80); the Cloud PC now answers 192.
    const work: Rect = .{ .x = 0, .y = 0, .w = 3840, .h = 2112 };
    const out = fitToMonitor(.{ .x = 100, .y = 80, .w = 1000, .h = 700 }, 96, 192, work);
    try testing.expectEqual(Rect{ .x = 100, .y = 80, .w = 2000, .h = 1400 }, out);
}

test "fitToMonitor: the reverse - a 200% frame on a 100% desktop halves instead of overflowing" {
    const work: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1032 };
    const out = fitToMonitor(.{ .x = 200, .y = 100, .w = 2400, .h = 1600 }, 192, 96, work);
    try testing.expectEqual(Rect{ .x = 200, .y = 100, .w = 1200, .h = 800 }, out);
}

test "fitToMonitor: same scale and on screen is the identity" {
    const work: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1032 };
    const r: Rect = .{ .x = 10, .y = 20, .w = 900, .h = 700 };
    try testing.expectEqual(r, fitToMonitor(r, 96, 96, work));
    // A pre-T1971 manifest (no recorded DPI) is not scaled at all.
    try testing.expectEqual(r, fitToMonitor(r, null, 192, work));
    // An unknown landing scale is not a change either.
    try testing.expectEqual(r, fitToMonitor(r, 96, 0, work));
}

test "fitToMonitor: a same-scale window the user stretched past the work area is left alone" {
    // Spanning two monitors is an arrangement, not an error to clamp.
    const work: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1032 };
    const r: Rect = .{ .x = 1000, .y = 0, .w = 2500, .h = 1000 };
    try testing.expectEqual(r, fitToMonitor(r, 144, 144, work));
}

test "fitToMonitor: a rescaled window that would hang off the edge is pulled back inside" {
    const work: Rect = .{ .x = 0, .y = 0, .w = 2560, .h = 1400 };
    const out = fitToMonitor(.{ .x = 1500, .y = 600, .w = 1000, .h = 500 }, 96, 192, work);
    // 2000x1000 at x=1500 would end at 3500: shifted so it ends at 2560.
    try testing.expectEqual(Rect{ .x = 560, .y = 400, .w = 2000, .h = 1000 }, out);
}

test "fitToMonitor: larger than the work area shrinks to it, on a monitor left of primary" {
    const work: Rect = .{ .x = -1920, .y = 0, .w = 1920, .h = 1040 };
    const out = fitToMonitor(.{ .x = -1900, .y = 10, .w = 1500, .h = 900 }, 96, 192, work);
    try testing.expectEqual(Rect{ .x = -1920, .y = 0, .w = 1920, .h = 1040 }, out);
}

test "fitToMonitor: an unreadable work area applies the scale and nothing else" {
    const out = fitToMonitor(.{ .x = 5000, .y = 5000, .w = 400, .h = 300 }, 96, 192, .{ .x = 0, .y = 0, .w = 0, .h = 0 });
    try testing.expectEqual(Rect{ .x = 5000, .y = 5000, .w = 800, .h = 600 }, out);
}
