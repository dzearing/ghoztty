//! The feedback composer's tooltip, keyboard-focus and screen-reader plane
//! (split out of `ViewerFeedbackBar.zig` by T1781): the action buttons'
//! tooltips, the Tab walk across the band's stops, and the actions a screen
//! reader can ask a painted part to perform.

const ViewerFeedbackBar = @import("ViewerFeedbackBar.zig");

const std = @import("std");
const w32 = @import("win32.zig");
const class_redraw = @import("class_redraw.zig");
const chrome_reposition = @import("chrome_reposition.zig");
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const banner_card = @import("banner_card.zig");
const banner_layout = @import("banner_layout.zig");
const pane_elevation = @import("pane_elevation.zig");
const Dib32 = @import("dib32.zig");
const type_ramp = @import("type_ramp.zig");
const icon_button = @import("icon_button.zig");
const icon_paint = @import("icon_button_paint.zig");
const layout_mod = @import("viewer_feedback_layout.zig");
const doc = @import("viewer_feedback_doc.zig");
const ViewerFeedbackWeb = @import("ViewerFeedbackWeb.zig");
const composer_page = @import("viewer_feedback_page.zig");
const feedback_images = @import("viewer_feedback_images.zig");
const utf16_offset = @import("utf16_offset.zig");
const gdiplus_decode = @import("gdiplus_decode.zig");
const RegionSelector = @import("RegionSelector.zig");
const system_colors = @import("system_colors.zig");
const viewer_accel = @import("viewer_accel.zig");
const Accessible = @import("viewer_feedback_acc.zig");
const a11y = @import("viewer_feedback_a11y.zig");
const ViewerPane = @import("ViewerPane.zig");
const viewer_worktree = @import("viewer_worktree.zig");
const input = @import("../../input.zig");
const build_config = @import("../../build_config.zig");
const paint_plane = @import("viewer_feedback_paint.zig");

const WM_APP_ACC_ACTION = ViewerFeedbackBar.WM_APP_ACC_ACTION;
const log = ViewerFeedbackBar.log;
const tip_log_cap = ViewerFeedbackBar.tip_log_cap;
const tip_text_cap = ViewerFeedbackBar.tip_text_cap;

// -------------------------------------------------------------------------
// Tooltips (T640)
// -------------------------------------------------------------------------

/// A tool id in this bar's own tool space. Keyed on the button so a tool never
/// has to be renumbered, exactly as `ViewerNavBar.tipId` does it.
pub fn tipId(b: layout_mod.Button) usize {
    return 0x200 + @as(usize, @intFromEnum(b));
}

/// One tooltip control for both actions, created on demand and kept for the
/// bar's life. A rect tool in `TTF_SUBCLASS` mode — the delay, the placement
/// and the dismissal are then comctl32's, which is the same trade the nav bar
/// makes and for the same reason: this band has no hover machinery of its own
/// worth driving a tip by hand from.
pub fn tipEnsure(self: *ViewerFeedbackBar) ?w32.HWND {
    if (self.tip) |h| return h;

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
        self.hwnd,
        null,
        null,
        null,
    ) orelse return null;

    // The composer's own theme decides the tip's: this band is already dark or
    // light for the page it sits over, and a light tip over a dark composer is
    // the seam the nav bar's tips do not have.
    system_colors.applyControlThemeDark(tip, self.dark);
    self.tip = tip;
    return tip;
}

pub fn tipToolInfo(
    self: *ViewerFeedbackBar,
    b: layout_mod.Button,
    rect: w32.RECT,
) w32.TOOLINFOW {
    return .{
        .cbSize = @sizeOf(w32.TOOLINFOW),
        .uFlags = w32.TTF_SUBCLASS,
        .hwnd = self.hwnd,
        .uId = tipId(b),
        .rect = rect,
        .hinst = null,
        .lpszText = @ptrCast(&self.tip_text[@intFromEnum(b)]),
        .lParam = 0,
        .lpReserved = null,
    };
}

/// Bring both tooltips in line with the composer's current rects. Idempotent,
/// and safe before the tip control exists.
///
/// A button the layout has squeezed to nothing has its tool DELETED rather
/// than left pointing at a rectangle nothing paints — a violently narrow pane
/// does exactly that to the actions.
pub fn syncTip(self: *ViewerFeedbackBar, l: layout_mod.Layout) void {
    const m = icon_button.Metrics.init(self.scale);
    var line: [tip_log_cap]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&line);
    const w = fbs.writer();
    for (std.enums.values(layout_mod.Button)) |b| {
        const i = @intFromEnum(b);
        const box = l.button(b);
        if (box.width() <= 0) {
            self.tipDelete(b);
            continue;
        }

        const text = layout_mod.label(b);
        const n = std.unicode.utf8ToUtf16Le(self.tip_text[i][0 .. tip_text_cap - 1], text) catch 0;
        self.tip_text[i][n] = 0;
        if (n == 0) {
            self.tipDelete(b);
            continue;
        }

        const tip = self.tipEnsure() orelse return;
        // The HIT box, not the paint: a tip should follow the same forgiving
        // target the click does (design system — a hit box may exceed its
        // paint), or the two disagree at the edges.
        const hit = icon_button.hitBox(m, box);
        var ti = self.tipToolInfo(b, .{
            .left = hit.left,
            .top = hit.top,
            .right = hit.right,
            .bottom = hit.bottom,
        });
        if (!self.tip_added[i]) {
            if (w32.SendMessageW(tip, w32.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&ti))) == 0) continue;
            self.tip_added[i] = true;
        } else {
            _ = w32.SendMessageW(tip, w32.TTM_NEWTOOLRECTW, 0, @bitCast(@intFromPtr(&ti)));
            _ = w32.SendMessageW(tip, w32.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&ti)));
        }
        w.print(" {s}:paint={d},{d},{d},{d}:tool={d},{d},{d},{d}:text=\"{s}\"", .{
            @tagName(b),
            box.left, box.top,  box.right,  box.bottom,
            hit.left, hit.top,  hit.right,  hit.bottom,
            text,
        }) catch {};
    }

    self.logTips(line[0..fbs.pos]);
}

/// State the composer's tooltips in the GUI's own stderr, once per CHANGE.
///
/// The band is owner-painted chrome on a desktop nothing can screenshot, so
/// this line is the acceptance script's only view of which tools exist and
/// where they sit — the same oracle, for the same reason, as the nav bar's
/// (T639). Once per change rather than per sync: `place` runs on every bounds
/// pass, and a line per pass would bury the one that changed.
pub fn logTips(self: *ViewerFeedbackBar, line: []const u8) void {
    if (line.len > self.tip_log.len) return;
    if (std.mem.eql(u8, self.tip_log[0..self.tip_log_len], line)) return;
    @memcpy(self.tip_log[0..line.len], line);
    self.tip_log_len = line.len;
    log.info("viewer feedback tips pane={s}{s}", .{ self.pane.paneId(), line });
}

pub fn tipDelete(self: *ViewerFeedbackBar, b: layout_mod.Button) void {
    const i = @intFromEnum(b);
    if (!self.tip_added[i]) return;
    var ti = self.tipToolInfo(b, .{ .left = 0, .top = 0, .right = 0, .bottom = 0 });
    if (self.tip) |t| _ = w32.SendMessageW(t, w32.TTM_DELTOOLW, 0, @bitCast(@intFromPtr(&ti)));
    self.tip_added[i] = false;
}

// -------------------------------------------------------------------------
// Keyboard focus (T640)
// -------------------------------------------------------------------------

/// Which actions a Tab may land on right now — the send button is dead while
/// there is nothing to send, and focus does not stop on a dead control.
pub fn enabledActions(self: *const ViewerFeedbackBar) [layout_mod.button_count]bool {
    var out: [layout_mod.button_count]bool = undefined;
    for (std.enums.values(layout_mod.Button)) |b| {
        out[@intFromEnum(b)] = self.buttonEnabled(b);
    }
    return out;
}

/// Move keyboard focus to `stop` and show it.
///
/// The band itself takes the Win32 focus for a BUTTON stop — there is no child
/// window to focus, the actions are painted by this window — and hands focus
/// straight on to the text surface for `.text`, which is what `WM_SETFOCUS`
/// has always done.
pub fn focusStop(self: *ViewerFeedbackBar, stop: layout_mod.Stop) void {
    const arriving = stop == .carousel and self.key_focus != .carousel;
    self.key_focus = stop;
    if (stop == .carousel) {
        // The ring arrives on the picture the caret is already in when there
        // is one — walking into the strip from a chip should not throw away
        // where the user was — and on the first tile otherwise.
        if (arriving) self.carousel_focus = self.carousel_selected orelse 0;
        if (self.carousel_focus) |i| {
            if (i >= self.images) self.carousel_focus = if (self.images > 0) 0 else null;
        }
        if (self.carousel_focus) |i| {
            self.carousel_scroll = self.currentLayout().scrollToShow(i, self.carousel_scroll);
        }
    } else self.carousel_focus = null;
    if (stop == .text) {
        self.takeFocus();
    } else if (w32.GetFocus() != self.hwnd) {
        _ = w32.SetFocus(self.hwnd);
    }
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    // The acceptance oracle for the tab order (T640): the ring is painted
    // chrome on a desktop nothing can screenshot, so where focus LANDED is
    // stated rather than looked at.
    log.info("viewer feedback focus pane={s} stop={s}", .{ self.pane.paneId(), @tagName(stop) });
    self.notifyAccFocus();
}

/// Tab / shift+Tab.
pub fn walkFocus(self: *ViewerFeedbackBar, back: bool) void {
    self.focusStop(layout_mod.nextStop(
        self.key_focus,
        back,
        self.currentLayout().reachable(self.enabledActions()),
        self.images > 0,
    ));
    // The strip reports its own focus, so the acceptance oracle can see the
    // ring land on a tile the same way it sees it land on a button.
    if (self.key_focus == .carousel) self.logCarousel("focus");
}

/// Space or Enter on a focused action — the same thing a click does.
///
/// Only ever reached while a BUTTON holds focus, which is the guard that keeps
/// a bare Enter in the text surface a newline (the one behavior this composer
/// must never lose) and a space a space.
pub fn activateFocused(self: *ViewerFeedbackBar) bool {
    const b = layout_mod.buttonOf(self.key_focus) orelse return false;
    if (!self.buttonEnabled(b)) return true;
    self.activate(b);
    return true;
}

// -------------------------------------------------------------------------
// Screen readers (T1468)
// -------------------------------------------------------------------------

/// The image number tile `index` shows - what its accessible name says, so a
/// reader names the picture the way the report's chip does.
pub fn accTileNumber(self: *ViewerFeedbackBar, index: usize) ?u32 {
    const spans = self.pane.feedbackImageSpans(self.alloc) orelse return null;
    defer self.alloc.free(spans);
    if (index >= spans.len) return null;
    return self.pane.feedbackImageEntry(spans[index]).number;
}

pub const AccAction = enum(u1) { press, focus };

/// Queue what a screen reader asked of a painted part; see `WM_APP_ACC_ACTION`.
pub fn postAccAction(self: *ViewerFeedbackBar, action: AccAction, child: i32) void {
    _ = w32.PostMessageW(
        self.hwnd,
        WM_APP_ACC_ACTION,
        @intFromEnum(action),
        @as(isize, child),
    );
}

/// Run a queued screen-reader request, resolving the child id against the
/// band as it is NOW - a part that went away in between is simply not there.
pub fn runAccAction(self: *ViewerFeedbackBar, action: AccAction, child: i32) void {
    const it = Accessible.itemFor(self, child) orelse return;
    log.info("viewer feedback acc pane={s} action={s} child={d}", .{
        self.pane.paneId(),
        @tagName(action),
        child,
    });
    switch (action) {
        .press => switch (it) {
            .button => |b| if (self.buttonEnabled(b)) self.activate(b),
            .tile => |i| self.activateThumb(i),
            else => {},
        },
        .focus => switch (it) {
            .button => |b| if (self.buttonEnabled(b)) self.focusStop(layout_mod.stopOf(b)),
            .tile => |i| {
                // Arrive on the strip, then put the ring on the asked-for tile.
                self.focusStop(.carousel);
                if (i < self.images and self.carousel_focus != i) {
                    self.carousel_focus = i;
                    self.carousel_scroll = self.currentLayout().scrollToShow(i, self.carousel_scroll);
                    _ = w32.InvalidateRect(self.hwnd, null, 1);
                    self.logCarousel("focus");
                    self.notifyAccFocus();
                }
            },
            else => {},
        },
    }
}

/// Tell a listening screen reader which painted part now has focus. Only when
/// the band itself holds the Win32 focus: on the text stop the web surface
/// has it, and Chromium announces its own.
pub fn notifyAccFocus(self: *ViewerFeedbackBar) void {
    if (w32.GetFocus() != self.hwnd) return;
    const it = a11y.focusedItem(true, self.key_focus, self.carousel_focus) orelse return;
    const id = Accessible.idFor(self, it);
    Accessible.notify(Accessible.EVENT_OBJECT_FOCUS, self.hwnd, id);
    log.info("viewer feedback acc focus pane={s} child={d}", .{ self.pane.paneId(), id });
}
