//! The way OUT of full screen (T2011): what triggered each entry and exit,
//! when the "Exit full screen" button shows, and what it is painted with.
//!
//! The user report this exists for: "the chrome of the app completely
//! disappears (the part with the X and the max/min buttons). tab just
//! leaves. i can't figure out how to get it back." That is full screen
//! working as built. The window drops its caption, a one-tab window has no
//! strip (T234), and so nothing on screen says how to leave. The only way
//! out was the chord that got it there, Ctrl+Enter, which a terminal user
//! presses all day for other reasons.
//!
//! Three things answer it, and every decision behind them is here, with no
//! OS imports, so the none lane asserts all of it:
//!
//! - **A notice on entry.** "Press F11 to exit full screen", naming the
//!   window's LIVE binding (a rebind relabels it), for `NOTICE_MS`. Edge,
//!   Chrome and Windows Terminal all say this on entry. It is the one moment
//!   the user is guaranteed to be looking.
//! - **A reveal at the top edge.** Push the pointer against the top of the
//!   screen and an "Exit full screen" button appears. This is the browser
//!   convention, and the counterpart of Mac's full-screen title-bar reveal.
//!   It sits TOP-RIGHT, where the caption buttons the user is looking for
//!   used to be. It does not sit top-centre (Edge's spot) because that is
//!   where the Remote Desktop connection bar pins itself, and the report
//!   came over a remote connection.
//! - **A log line per transition**, naming the trigger (`Trigger`), so the
//!   next "it went full screen by itself" is answered from the log rather
//!   than inferred.
//!
//! The button is the read-only badge's chip (`readonly_badge`: the same
//! metrics, anchor and card renderer) in a neutral rim. It is a corner chip
//! of the same family, and reusing its asserted geometry is what keeps two
//! chips on one screen from disagreeing.

const std = @import("std");
const color_math = @import("color_math.zig");
const badge = @import("readonly_badge.zig");

const Rgb = color_math.Rgb;

/// What asked for a fullscreen transition. Logged on every entry and exit.
pub const Trigger = enum {
    /// A core binding action. A keybind is the usual source; ctrl+enter
    /// lands here.
    action,
    /// The menu or the command palette (`Surface.performCommand`).
    command,
    /// A chord matched inside a viewer pane (`Window.performViewerChord`).
    viewer_chord,
    /// The "Exit full screen" button this module places.
    exit_button,
};

/// How long the entry notice stays up, in ms. Edge holds its "Press F11 to
/// exit full screen" for about three seconds. A little longer here, because
/// this notice is the only teaching the feature does.
pub const NOTICE_MS: i64 = 4000;

/// How often the reveal polls the pointer while a window is full screen, in
/// ms. Polling, not WM_MOUSEMOVE: the pointer is over a child pane (or a
/// WebView2 viewer) that the top-level window never hears from, and a
/// pointer that leaves for another monitor sends nothing at all. One
/// GetCursorPos per tick, only while full screen.
pub const POLL_MS: u32 = 100;

/// The reveal band: the pointer within this many DIP of the screen's top
/// edge shows the button. At least one physical pixel, so the band never
/// rounds away.
pub const EDGE_DIP: f32 = 2.0;

/// Once shown, the button stays while the pointer is above its card's
/// bottom plus this margin. Without the margin it flickers off the moment
/// the pointer starts down toward it.
pub const HOLD_DIP: f32 = 24.0;

/// What the button is showing.
pub const Mode = enum {
    hidden,
    /// The entry notice: "Press F11 to exit full screen".
    notice,
    /// The top-edge reveal: "Exit full screen".
    reveal,
};

/// Everything the decision needs for one poll tick.
pub const Input = struct {
    fullscreen: bool,
    /// The window under the pointer belongs to this window (the window
    /// itself, a pane, a viewer, or the button). False when the pointer is on
    /// another monitor or another app's window, so a window that is not in
    /// front never sprouts a button.
    pointer_over: bool,
    /// Pointer y relative to the full-screen window's top, physical px.
    pointer_y: i32,
    now_ms: i64,
    /// When the entry notice expires (0 = no notice pending).
    notice_until_ms: i64,
    /// Bottom of the button's card, relative to the window's top, physical
    /// px. Only consulted while the button is up.
    card_bottom: i32,
    scale: f32,
};

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * @max(scale, 0.1)));
}

pub fn edgePx(scale: f32) i32 {
    return @max(px(EDGE_DIP, scale), 1);
}

pub fn holdPx(scale: f32) i32 {
    return px(HOLD_DIP, scale);
}

/// The next mode, given the current one. Pure, called on every poll tick.
pub fn decide(prev: Mode, in: Input) Mode {
    if (!in.fullscreen) return .hidden;
    // The notice holds for its whole time regardless of the pointer. It is
    // the guaranteed half of the answer.
    if (in.now_ms < in.notice_until_ms) return .notice;
    if (!in.pointer_over) return .hidden;
    if (in.pointer_y <= edgePx(in.scale)) return .reveal;
    // Already up (the reveal, or a notice that just expired with the
    // pointer resting on it): keep it while the pointer is near.
    if (prev != .hidden and in.pointer_y < in.card_bottom + holdPx(in.scale))
        return .reveal;
    return .hidden;
}

/// The button's chip, anchored top-right of a `win_w` x `win_h` window.
/// The badge's own layout: same inset, same card, same scale sweep.
pub fn layout(m: badge.Metrics, win_w: i32, win_h: i32, text_w: i32, text_h: i32) badge.Layout {
    return badge.layout(m, win_w, win_h, text_w, text_h);
}

/// The card fill over the window's background. The badge's glass wash,
/// so the two chips agree.
pub fn fillColor(bg: Rgb) Rgb {
    return badge.fillColor(bg);
}

/// Label and glyph color: black or white, whichever reads best (4.58:1 or
/// better on any fill).
pub fn labelColor(fill: Rgb) Rgb {
    return color_math.contrastForeground(fill);
}

/// The rim: a neutral luminance step off the fill, at the 3:1 boundary
/// floor (WCAG 1.4.11). Neutral on purpose; see `badge.renderCard`.
pub fn borderColor(fill: Rgb) Rgb {
    const c = color_math.contrastAdjustedTo(fill, fill, badge.BORDER_CONTRAST);
    if (badge.ratio(c, fill) >= badge.BORDER_CONTRAST) return c;
    return color_math.contrastForeground(fill);
}

/// Paint the chip. See `badge.render` for the straight-color + mask
/// contract the caller's GDI text pass relies on.
pub fn render(bgr: []u32, mask: []u8, m: badge.Metrics, l: badge.Layout, bg: Rgb) void {
    const fill = fillColor(bg);
    badge.renderCard(bgr, mask, m, l, fill, borderColor(fill));
}

pub const NOTICE_PREFIX = "Press ";
pub const NOTICE_SUFFIX = " to exit full screen";
pub const REVEAL_LABEL = "Exit full screen";

/// The label for `mode`, written into `buf`. `key` is the live trigger for
/// `toggle_fullscreen` as the menus print it ("F11"), or null when the user
/// unbound it, in which case the notice still says what the button does.
pub fn label(mode: Mode, key: ?[]const u8, buf: []u8) []const u8 {
    switch (mode) {
        .hidden, .reveal => return REVEAL_LABEL,
        .notice => {
            const k = key orelse return REVEAL_LABEL;
            if (k.len == 0) return REVEAL_LABEL;
            return std.fmt.bufPrint(buf, NOTICE_PREFIX ++ "{s}" ++ NOTICE_SUFFIX, .{k}) catch REVEAL_LABEL;
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

fn base(scale: f32) Input {
    return .{
        .fullscreen = true,
        .pointer_over = true,
        .pointer_y = 500,
        .now_ms = 10_000,
        .notice_until_ms = 0,
        .card_bottom = px(40, scale),
        .scale = scale,
    };
}

test "not full screen: never shown, whatever the pointer does" {
    var in = base(1.0);
    in.fullscreen = false;
    in.pointer_y = 0;
    in.notice_until_ms = in.now_ms + 1000;
    try testing.expectEqual(Mode.hidden, decide(.reveal, in));
    try testing.expectEqual(Mode.hidden, decide(.notice, in));
}

test "the entry notice holds for its whole time, pointer or not" {
    var in = base(1.0);
    in.notice_until_ms = in.now_ms + 1;
    in.pointer_over = false;
    try testing.expectEqual(Mode.notice, decide(.hidden, in));
    in.now_ms = in.notice_until_ms;
    try testing.expectEqual(Mode.hidden, decide(.notice, in));
}

test "the top edge reveals the button at every scale, one pixel at least" {
    for (scales) |s| {
        var in = base(s);
        in.pointer_y = 0;
        try testing.expectEqual(Mode.reveal, decide(.hidden, in));
        in.pointer_y = edgePx(s);
        try testing.expectEqual(Mode.reveal, decide(.hidden, in));
        // One pixel below the band, from hidden, is not a reveal.
        in.pointer_y = edgePx(s) + 1;
        try testing.expectEqual(Mode.hidden, decide(.hidden, in));
        try testing.expect(edgePx(s) >= 1);
    }
}

test "once up, the button holds while the pointer heads toward it" {
    for (scales) |s| {
        var in = base(s);
        in.pointer_y = in.card_bottom + holdPx(s) - 1;
        try testing.expectEqual(Mode.reveal, decide(.reveal, in));
        // An expired notice the pointer is resting on becomes the reveal
        // rather than vanishing under it.
        try testing.expectEqual(Mode.reveal, decide(.notice, in));
        in.pointer_y = in.card_bottom + holdPx(s);
        try testing.expectEqual(Mode.hidden, decide(.reveal, in));
    }
}

test "a pointer that is not over this window never reveals" {
    var in = base(1.0);
    in.pointer_y = 0;
    in.pointer_over = false;
    try testing.expectEqual(Mode.hidden, decide(.hidden, in));
    try testing.expectEqual(Mode.hidden, decide(.reveal, in));
}

test "the notice names the live key, and falls back when unbound" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("Press F11 to exit full screen", label(.notice, "F11", &buf));
    try testing.expectEqualStrings("Press Ctrl+Enter to exit full screen", label(.notice, "Ctrl+Enter", &buf));
    try testing.expectEqualStrings(REVEAL_LABEL, label(.notice, null, &buf));
    try testing.expectEqualStrings(REVEAL_LABEL, label(.notice, "", &buf));
    try testing.expectEqualStrings(REVEAL_LABEL, label(.reveal, "F11", &buf));
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings(REVEAL_LABEL, label(.notice, "F11", &tiny));
}

test "the button is anchored top-right at the badge inset, at every scale" {
    for (scales) |s| {
        const m = badge.Metrics.init(s);
        const l = layout(m, 1920, 1080, px(90, s), m.font_px + 3);
        try testing.expect(!l.hidden);
        const pad = m.shadowPad();
        // Card edges, in window coordinates.
        try testing.expectEqual(@as(i32, 1920) - m.inset, l.win.left + l.card.right);
        try testing.expectEqual(m.inset, l.win.top + l.card.top);
        try testing.expect(l.win.left >= 0 and l.win.right <= 1920);
        _ = pad;
    }
}

test "label clears 4.5:1 and the neutral rim 3:1 on any background" {
    var v: u16 = 0;
    while (v <= 255) : (v += 15) {
        const c: u8 = @intCast(v);
        for ([_]Rgb{
            .{ .r = c, .g = c, .b = c },
            .{ .r = c, .g = 0, .b = 255 - c },
            .{ .r = 255 - c, .g = c, .b = 40 },
        }) |bg| {
            const fill = fillColor(bg);
            try testing.expect(badge.ratio(labelColor(fill), fill) >= 4.5);
            try testing.expect(badge.ratio(borderColor(fill), fill) >= 3.0);
        }
    }
}

test "the rim is neutral: never the read-only badge's orange" {
    const bg = Rgb{ .r = 16, .g = 16, .b = 20 };
    const fill = fillColor(bg);
    const rim = borderColor(fill);
    try testing.expect(!rim.eql(badge.borderColor(fill)));
    // Neutral: no channel pulls far from the others more than the fill does.
    const spread_fill = @as(i32, @max(fill.r, @max(fill.g, fill.b))) - @min(fill.r, @min(fill.g, fill.b));
    const spread_rim = @as(i32, @max(rim.r, @max(rim.g, rim.b))) - @min(rim.r, @min(rim.g, rim.b));
    try testing.expect(spread_rim <= spread_fill + 24);
}

test "render paints an opaque card interior with the neutral rim" {
    const s: f32 = 1.0;
    const m = badge.Metrics.init(s);
    const l = layout(m, 800, 600, 90, m.font_px + 3);
    const w: usize = @intCast(l.win.width());
    const h: usize = @intCast(l.win.height());
    const bgr = try testing.allocator.alloc(u32, w * h);
    defer testing.allocator.free(bgr);
    const mask = try testing.allocator.alloc(u8, w * h);
    defer testing.allocator.free(mask);
    const bg = Rgb{ .r = 16, .g = 16, .b = 20 };
    render(bgr, mask, m, l, bg);
    const cx: usize = @intCast(@divTrunc(l.card.left + l.card.right, 2));
    const cy: usize = @intCast(@divTrunc(l.card.top + l.card.bottom, 2));
    try testing.expectEqual(@as(u8, 255), mask[cy * w + cx]);
    const fill = fillColor(bg);
    const p = bgr[cy * w + cx];
    try testing.expectEqual(@as(u32, fill.r), (p >> 16) & 0xFF);
    // A corner pixel outside the rounded card is not opaque.
    try testing.expect(mask[0] < 255);
}
