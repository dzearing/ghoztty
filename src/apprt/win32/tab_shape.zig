//! Pure per-pixel math for the tab strip's tab SHAPE and surface (T206).
//! No OS imports, so these unit tests run in every app-runtime lane.
//!
//! `tab_strip_layout.zig` decides WHERE the tabs go; this decides what one
//! looks like. The split exists because the two change for different reasons
//! — geometry moves when the window resizes, appearance moves when the theme
//! or the design does.
//!
//! Why per-pixel instead of GDI. The user's report, 2026-07-30:
//!
//! > "don't you see how the edge of the banner has this gradient highlight
//! >  border? tabs should too, and inactive tabs should be visible somewhat
//! >  and tabs should have gaps in between. And the bottom corners of the
//! >  selected tab should curve into the edge. Why are you making the ux
//! >  unpolished on windows? Make this as good as mac."
//!
//! Every one of those needs something GDI does not have:
//!
//!   * A **gradient rim** — `FrameRgn`/`CreatePen` stroke ONE flat color.
//!     The banner card's rim is an elliptical gradient lit from above the
//!     card, and matching it means computing the alpha per pixel.
//!   * **Flared bottom corners** that curve OUT into the strip baseline (the
//!     Chrome/Safari/macOS tab silhouette). That is not a rounded rect at
//!     all, so `CreateRoundRectRgn` cannot express it.
//!   * **Antialiasing.** GDI regions and paths are hard-edged. An aliased
//!     curve sitting next to the banner's antialiased card is exactly the
//!     "unpolished" the report names — the flaw is visible precisely BECAUSE
//!     the banner next to it is smooth.
//!
//! So the strip's back buffer is a DIB section and the tabs are composited
//! into it here, the same way `banner_card.zig` composites the banner. The
//! rim constants are IMPORTED from that module rather than copied: the ask
//! was for the tabs to match the banner, and a copied 0.28 is a number that
//! silently stops matching the first time either side is tuned.

const std = @import("std");
const testing = std.testing;
const card = @import("banner_card.zig");
const color_math = @import("color_math.zig");

/// Re-exported so `Window.zig` can name the color type without importing
/// `color_math` just for one struct literal.
pub const Rgb = color_math.Rgb;

/// Negative control for `test/win32/tab-strip.ps1`. Flip to `true`, rebuild
/// `-Dapp-runtime=win32`, and re-run: tabs lose the rim, the flare, the
/// antialiasing and the inactive surface, restoring the flat pre-T206 look —
/// so the rim, bottom-flare, antialiasing and inactive-visibility assertions
/// must fail, and the geometry ones (T202's) must NOT.
///
/// T209 widened it. It used to zero only the rim and the inactive lift while
/// this comment already claimed the flare, and `sdTabRim` kept flaring and
/// `renderTab` kept antialiasing — so two of the assertions this control is
/// supposed to adjudicate could not fail no matter how it was set. A negative
/// control that does not cover a claim is worse than none: it is a green run
/// that reads as evidence.
pub const T206_NEUTERED = false;

/// Top-corner radius, unscaled px. The tab's own rounding, kept smaller than
/// the banner card's 14 because a tab is a third of the card's height and the
/// same radius on a short shape reads as a lozenge.
pub const CORNER_TOP: f32 = 7.0;

/// Bottom-corner FLARE radius, unscaled px — the outward curve that carries
/// the tab's side into the strip baseline instead of stopping dead at it.
/// This is the "curve into the edge" half of the report, and it is what makes
/// a selected tab read as continuous with the pane below rather than as a
/// rectangle parked on top of it.
pub const CORNER_BOTTOM: f32 = 7.0;

/// Hairline rim width, unscaled px. One device pixel at 100%, and it must
/// stay a hairline as DPI rises — a rim that scales becomes a border.
pub const RIM_W: f32 = 1.0;

/// Surface lift for a tab that is NOT selected, as an alpha of white over the
/// strip background. The report's "inactive tabs should be visible somewhat":
/// they used to be fully transparent, so an unselected tab was literally not
/// drawn and the strip read as one bar with text on it.
///
/// Deliberately the banner card's own `FILL_LIGHTEN` — an inactive tab and
/// the banner card are both "a surface floating on the background", so they
/// should be the same surface.
pub const INACTIVE_LIFT: f32 = card.FILL_LIGHTEN;

/// A hovered inactive tab lifts further, so hover is a change of surface
/// rather than a change of color.
pub const HOVER_LIFT: f32 = card.FILL_LIGHTEN * 2.0;

/// What a tab is doing, which decides its fill.
pub const Surface = enum {
    /// Selected. Filled with the CONTENT background so it merges into the
    /// pane below — the WinUI TabView selection cue.
    active,
    inactive,
    /// Unselected, pointer over it.
    hovered,
};

/// One tab to composite, in physical pixels relative to the strip buffer.
pub const Tab = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    surface: Surface,
};

/// The scaled constants for one DPI.
pub const Metrics = struct {
    corner_top: f32,
    corner_bottom: f32,
    rim_w: f32,

    pub fn init(scale: f32) Metrics {
        return .{
            .corner_top = CORNER_TOP * scale,
            .corner_bottom = CORNER_BOTTOM * scale,
            // A hairline stays a hairline: never thinner than a device pixel,
            // and never allowed to grow into a border at high DPI.
            .rim_w = @max(RIM_W, @min(RIM_W * scale, 2.0)),
        };
    }
};

fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Antialiased coverage from a signed distance: 1 well inside, 0 well
/// outside, a linear ramp across the boundary pixel. Same formulation as
/// `banner_card.zig` so the two shapes' edges resolve identically.
fn coverage(sd: f32) f32 {
    return std.math.clamp(0.5 - sd, 0.0, 1.0);
}

/// Signed distance to an axis-aligned box: negative inside.
fn sdBox(x: f32, y: f32, left: f32, top: f32, right: f32, bottom: f32) f32 {
    const dx = @max(left - x, x - right);
    const dy = @max(top - y, y - bottom);
    // Exact outside distance, and the usual max() approximation inside.
    const ax = @max(dx, 0.0);
    const ay = @max(dy, 0.0);
    return @sqrt(ax * ax + ay * ay) + @min(@max(dx, dy), 0.0);
}

/// Signed distance to ONE bottom flare — the little concave foot that carries
/// the tab's side out to the baseline.
///
/// It is the corner square beside the tab MINUS a disc tucked into that
/// square: the leftover sliver between the straight side and the disc is the
/// outward curve. Subtracting a disc (rather than adding a rounded corner) is
/// what makes the curve concave, which is the whole difference between a
/// Chrome-style tab and a rounded rectangle.
fn sdFlare(x: f32, y: f32, cx: f32, cy: f32, r: f32, box_l: f32, box_r: f32, box_t: f32, box_b: f32) f32 {
    const in_box = sdBox(x, y, box_l, box_t, box_r, box_b);
    const dx = x - cx;
    const dy = y - cy;
    // Negative when OUTSIDE the disc, which is the half we keep.
    const outside_disc = r - @sqrt(dx * dx + dy * dy);
    return @max(in_box, outside_disc);
}

/// Signed distance to the tab silhouette WITHOUT its baseline — the field the
/// RIM is drawn from (T242).
///
/// The baseline is not an edge of the tab. It is the seam where the tab meets
/// the pane below, and the whole selection idiom (T202) is that the selected
/// chiclet MERGES into that pane. `sdTab` clips the shape square there so the
/// fill cannot paint past `bar_h`, but a rim derived from that clipped field
/// faithfully traces the clip — a ~9-level-brighter line spanning the tab's
/// full width, sitting exactly on the seam, which is the user's report:
///
/// > "the active tab seems to have a horizontal line at the bottom, making it
/// >  feel disconnected from the pane below."
///
/// So COVERAGE is clipped and the RIM is not. Here the body extends below the
/// baseline and each flare's box does too, which leaves the rim ring with only
/// real edges to trace: the rounded top corners, the two sides, and the
/// outboard concave curve of each flare. Along the baseline the ring falls
/// below the drawn area and vanishes.
///
/// The alternative — setting `RIM_BOT` to 0 — was rejected: it dims the rim up
/// the tab's whole height to hide one row of it, and the artifact returns the
/// moment anyone tunes `RIM_BOT` back above zero.
pub fn sdTabRim(x: f32, y: f32, t: Tab, m: Metrics) f32 {
    const l: f32 = @floatFromInt(t.left);
    const tp: f32 = @floatFromInt(t.top);
    const r: f32 = @floatFromInt(t.right);
    const b: f32 = @floatFromInt(t.bottom);

    // Body: round the TOP corners only. Extending the rounded rect below the
    // baseline puts its bottom corners' rounding out of view; `sdTab`'s
    // half-plane then cuts it off square at the baseline — which is where the
    // flares take over.
    const rt = m.corner_top;
    const body_round = card.sdRoundRect(x, y, .{
        .left = l,
        .top = tp,
        .right = r,
        .bottom = b + rt,
    }, rt);

    // Flares, outboard of each bottom corner — on the SELECTED tab only.
    //
    // The report asks for them by name on that tab ("the bottom corners of
    // the selected tab should curve into the edge"), and restricting them
    // there is also what lets the tabs have real GAPS between them: a flare
    // reaches `corner_bottom` past its own side, so flaring every tab would
    // have neighbouring feet meeting in the middle of every gap and closing
    // it back up. The selected tab flares into the empty space beside it; the
    // others stay clear of each other.
    // Neutered: no flares at all, on any tab (T209 — the control's own
    // comment has always said so).
    if (T206_NEUTERED or t.surface != .active) return body_round;

    // The flare boxes run BELOW the baseline for the same reason the body
    // does: their bottom edge is the seam, so it must not be an edge here
    // either. `sdTab`'s clip brings them back to `b`.
    const rb = m.corner_bottom;
    const left_flare = sdFlare(x, y, l - rb, b - rb, rb, l - rb, l, b - rb, b + rb);
    const right_flare = sdFlare(x, y, r + rb, b - rb, rb, r, r + rb, b - rb, b + rb);

    return @min(body_round, @min(left_flare, right_flare));
}

/// Signed distance to the whole tab silhouette: a top-rounded body plus a
/// flare at each bottom corner, clipped square at the baseline.
///
/// Defined as `sdTabRim` plus the clip rather than as its own field, so the
/// two can never drift apart — the fill and the rim must always be the same
/// shape, differing only in whether the seam counts as an edge.
pub fn sdTab(x: f32, y: f32, t: Tab, m: Metrics) f32 {
    const b: f32 = @floatFromInt(t.bottom);
    return @max(sdTabRim(x, y, t, m), y - b);
}

/// The tab's own rect, as the banner card's geometry type — the rect the
/// specular ellipse is normalized to. The visible chiclet, `top`..`bottom`:
/// the rim's SDF deliberately runs below the baseline (see `sdTabRim`), but
/// the light is over the tab you can see, not over the part clipped away.
pub fn tabRect(t: Tab) card.Rect {
    return .{
        .left = @floatFromInt(t.left),
        .top = @floatFromInt(t.top),
        .right = @floatFromInt(t.right),
        .bottom = @floatFromInt(t.bottom),
    };
}

/// The rim's alpha at (`x`, `y`) within a tab: the banner card's rim,
/// evaluated against the TAB's rect (T679).
///
/// It used to be a straight vertical ramp between `card.RIM_TOP` and
/// `card.RIM_BOT`, on the premise that "a tab is short enough that a linear
/// ramp between the same two endpoints is indistinguishable". That premise
/// died when T124 made the card's rim a real elliptical gradient: those two
/// numbers became STOPS of that gradient, the bright one sitting at a light
/// half a card-height above the card and reached by no pixel of it, so the
/// tab's top edge was lit at 0.28 against the card's ~0.18 — two pieces of
/// chrome T206 deliberately gave the same rim, visibly different materials.
///
/// Sharing the ellipse rather than re-matching its endpoints is what keeps
/// that from happening again: the gradient is normalized to each surface's own
/// rect, so one overhead light lights a 29px tab and a 66px card identically
/// in relative terms, and neither can be retuned without the other following.
pub fn rimAlpha(x: f32, y: f32, t: Tab, active: bool) f32 {
    return rimFrom(card.rimEllipse(tabRect(t)).at(x, y), active);
}

/// The rim alpha for a point already reduced to the ellipse's parameter — so
/// `renderTab` can hoist the ellipse and its row term out of the pixel loop
/// without expressing the rim a second time.
fn rimFrom(e: f32, active: bool) f32 {
    const a = card.rimGradient(e);
    // An unselected tab's rim is softer — at full strength every tab would
    // shout as loudly as the selected one and the selection cue would be lost.
    return if (active) a else a * 0.6;
}

/// The fill a surface takes, already composited over the strip background.
/// Exposed so the acceptance script and the GDI text path can ask for the
/// exact color a tab is painted rather than re-deriving it.
pub fn fillColor(surface: Surface, strip_bg: Rgb, content_bg: Rgb) Rgb {
    if (T206_NEUTERED) {
        return switch (surface) {
            .active => content_bg,
            // The pre-T206 world: an unselected tab painted nothing at all.
            .inactive, .hovered => strip_bg,
        };
    }
    return switch (surface) {
        .active => content_bg,
        .inactive => lift(strip_bg, INACTIVE_LIFT),
        .hovered => lift(strip_bg, HOVER_LIFT),
    };
}

/// Composite white (dark background) or black (light background) at `a` over
/// `bg`. The same alpha composite `banner_card.fillColor` uses — NOT an HSB
/// brightness lift, which keeps saturation and lands on a different color.
/// The arithmetic itself now lives in `color_math.wash` (T304), where the
/// chrome palette and the banner card read it from too.
fn lift(bg: Rgb, a: f32) Rgb {
    return color_math.wash(bg, a);
}


/// Composite one tab into a top-down `w * h` buffer of `0x00RRGGBB`.
///
/// Only the pixels the tab can reach are touched — its rect grown by the
/// flare radius — so painting N tabs costs their own area, not N full strip
/// passes.
pub fn renderTab(
    pixels: []u32,
    w: i32,
    h: i32,
    t: Tab,
    m: Metrics,
    strip_bg: Rgb,
    content_bg: Rgb,
) void {
    if (w <= 0 or h <= 0) return;
    if (pixels.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return;
    if (t.right <= t.left or t.bottom <= t.top) return;

    const fill = fillColor(t.surface, strip_bg, content_bg);
    const fr: f32 = @floatFromInt(fill.r);
    const fg: f32 = @floatFromInt(fill.g);
    const fb: f32 = @floatFromInt(fill.b);
    const active = (t.surface == .active);

    // White rim on a dark background, black on a light one — a specular
    // highlight is the light source reflecting off the surface's edge, so it
    // has to go the other way when the surface is already bright.
    const rim_toward: f32 = if (color_math.isLight(strip_bg)) 0.0 else 255.0;

    const pad: i32 = @intFromFloat(@ceil(m.corner_bottom) + 2.0);
    const x0 = @max(t.left - pad, 0);
    const x1 = @min(t.right + pad, w);
    const y0 = @max(t.top - pad, 0);
    const y1 = @min(t.bottom + pad, h);

    // The overhead specular light, built once per tab: only its row and
    // column terms vary per pixel, and the column term is the only thing that
    // costs a `sqrt` — paid on rim pixels alone, below.
    const rim_e = card.rimEllipse(tabRect(t));

    var y = y0;
    while (y < y1) : (y += 1) {
        const fy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        const rim_row = rim_e.rowTerm(fy);
        const row = @as(usize, @intCast(y)) * @as(usize, @intCast(w));
        var x = x0;
        while (x < x1) : (x += 1) {
            const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
            const sd = sdTab(fx, fy, t, m);
            // Neutered: a hard edge, the way `CreateRoundRectRgn` fills — no
            // partial coverage anywhere, so no pixel on a corner arc can be
            // anything but strip or fill (T209's antialiasing assertion).
            const cov = if (T206_NEUTERED)
                @as(f32, if (sd < 0.0) 1.0 else 0.0)
            else
                coverage(sd);
            if (cov <= 0.0) continue;

            // The rim is the ring just INSIDE the silhouette: the shape minus
            // the shape shrunk by one hairline. Doing it as a difference of
            // coverages keeps it antialiased on both of its own edges, which
            // a stroked outline never is.
            //
            // Drawn from the UN-clipped field (T242): the baseline is a seam,
            // not an edge, so it gets no rim. Everywhere else the two fields
            // agree, so this is the same ring it always was.
            const sd_rim = if (T206_NEUTERED) sd else sdTabRim(fx, fy, t, m);
            const ring = if (T206_NEUTERED) 0.0 else @max(coverage(sd_rim) - coverage(sd_rim + m.rim_w), 0.0);
            const rim = if (ring > 0.0) ring * rimFrom(rim_e.atRow(fx, rim_row), active) else 0.0;

            const i = row + @as(usize, @intCast(x));
            const dst = pixels[i];
            var r: f32 = @floatFromInt((dst >> 16) & 0xFF);
            var g: f32 = @floatFromInt((dst >> 8) & 0xFF);
            var b: f32 = @floatFromInt(dst & 0xFF);

            r = mix(r, fr, cov);
            g = mix(g, fg, cov);
            b = mix(b, fb, cov);

            if (rim > 0.0) {
                r = mix(r, rim_toward, rim);
                g = mix(g, rim_toward, rim);
                b = mix(b, rim_toward, rim);
            }

            pixels[i] = (@as(u32, @intFromFloat(std.math.clamp(@round(r), 0.0, 255.0))) << 16) |
                (@as(u32, @intFromFloat(std.math.clamp(@round(g), 0.0, 255.0))) << 8) |
                @as(u32, @intFromFloat(std.math.clamp(@round(b), 0.0, 255.0)));
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const DARK = Rgb{ .r = 30, .g = 32, .b = 40 };
const STRIP = Rgb{ .r = 50, .g = 52, .b = 60 };

fn testTab(surface: Surface) Tab {
    return .{ .left = 20, .top = 3, .right = 120, .bottom = 32, .surface = surface };
}

fn px(pixels: []const u32, w: i32, x: i32, y: i32) u32 {
    return pixels[@as(usize, @intCast(y)) * @as(usize, @intCast(w)) + @as(usize, @intCast(x))];
}

fn lumOf(p: u32) u32 {
    return ((p >> 16) & 0xFF) + ((p >> 8) & 0xFF) + (p & 0xFF);
}

test "an inactive tab is VISIBLE against the strip" {
    // The report: "inactive tabs should be visible somewhat". Pre-T206 an
    // unselected tab painted nothing, so this difference was exactly zero.
    const c = fillColor(.inactive, STRIP, DARK);
    try testing.expect(!std.meta.eql(c, STRIP));
    try testing.expect(lumOf(@as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b) >
        lumOf(@as(u32, STRIP.r) << 16 | @as(u32, STRIP.g) << 8 | STRIP.b));
}

test "hover lifts further than inactive, and active is the content background" {
    const inact = fillColor(.inactive, STRIP, DARK);
    const hov = fillColor(.hovered, STRIP, DARK);
    try testing.expect(hov.r > inact.r);
    try testing.expectEqual(DARK, fillColor(.active, STRIP, DARK));
}

test "the inactive lift is the banner card's own, not a second opinion" {
    // "tabs should have similar borders to the banner. It should feel
    // cohesive" — cohesion by construction, not by two numbers that happen to
    // match today.
    try testing.expectEqual(card.FILL_LIGHTEN, INACTIVE_LIFT);
    try testing.expectEqual(card.fillColor(STRIP), fillColor(.inactive, STRIP, DARK));
}

test "the rim fades from top to bottom, like the card's" {
    const t = testTab(.active);
    const cx = @as(f32, @floatFromInt(t.left + t.right)) / 2.0;
    const top = rimAlpha(cx, @floatFromInt(t.top), t, true);
    const mid = rimAlpha(cx, @as(f32, @floatFromInt(t.top + t.bottom)) / 2.0, t, true);
    const bot = rimAlpha(cx, @floatFromInt(t.bottom), t, true);
    try testing.expect(top > mid);
    try testing.expect(mid > bot);
    // The gradient's stops bracket what any pixel takes: the bright one sits
    // at the light, which is above the tab, and the dim one is held past the
    // ellipse's boundary — which the baseline is already past.
    try testing.expect(top < card.RIM_TOP);
    try testing.expect(top > card.RIM_MID);
    try testing.expectApproxEqAbs(card.RIM_BOT, bot, 0.001);
}

test "the tab's rim and the card's agree at the same relative point (T679)" {
    // The defect: with the tab on a straight RIM_TOP -> RIM_BOT ramp, its top
    // edge was lit at the full 0.28 while the card's brightest pixel was
    // ~0.18 — two surfaces T206 gave the same rim reading as different
    // materials. One shared overhead light is what makes them agree, and it
    // has to hold across the aspect difference (a 29px tab vs a 66px card),
    // which is exactly what a hand-matched pair of endpoints cannot promise.
    const t = testTab(.active);
    const tab_cx = @as(f32, @floatFromInt(t.left + t.right)) / 2.0;
    const tab_top = rimAlpha(tab_cx, @as(f32, @floatFromInt(t.top)) + 0.5, t, true);

    const m = card.Metrics.init(400, 90, 1.0);
    const c = m.card();
    const card_top = card.rimAlpha(c.left + c.width() * 0.5, c.top + 0.5, c);

    // Within a level of 255 — the whole remaining difference is that half a
    // pixel is a different fraction of a tab's height than of a card's.
    try testing.expectApproxEqAbs(card_top, tab_top, 1.0 / 255.0);
    // And both are well under the stop the old ramp handed the tab.
    try testing.expect(tab_top < card.RIM_TOP - 0.05);
}

test "the rim dims toward a tab's ends, as the card's does" {
    // The horizontal half of the same light: the ellipse is normalized per
    // axis, so a tab's top corners fall off at the same relative rate a
    // card's do. A vertical-only ramp lit them exactly as brightly as the
    // middle, which is what made a tab read as a stripe-lit slab.
    const t = testTab(.active);
    const y = @as(f32, @floatFromInt(t.top)) + 0.5;
    const mid = rimAlpha(@as(f32, @floatFromInt(t.left + t.right)) / 2.0, y, t, true);
    const end = rimAlpha(@as(f32, @floatFromInt(t.left)) + 0.5, y, t, true);
    try testing.expect(mid > end);
}

test "an unselected tab's rim is softer than the selected one's" {
    const t = testTab(.inactive);
    try testing.expect(rimAlpha(70.0, 10.0, t, false) < rimAlpha(70.0, 10.0, t, true));
}

test "the silhouette contains its interior and excludes the strip above it" {
    const m = Metrics.init(1.0);
    const t = testTab(.active);
    // Well inside.
    try testing.expect(sdTab(70.0, 20.0, t, m) < 0);
    // Above the tab.
    try testing.expect(sdTab(70.0, 1.0, t, m) > 0);
    // Far to the left, clear of the flare.
    try testing.expect(sdTab(5.0, 20.0, t, m) > 0);
}

test "the bottom corners FLARE outward instead of stopping at the side" {
    // The report's "the bottom corners of the selected tab should curve into
    // the edge", as an assertion: just outside the tab's left edge and just
    // above the baseline is OUTSIDE the shape, but the same x at the baseline
    // is INSIDE it — that widening is the flare.
    const m = Metrics.init(1.0);
    const t = testTab(.active);
    const x_outside: f32 = @as(f32, @floatFromInt(t.left)) - 3.0;
    const y_baseline: f32 = @as(f32, @floatFromInt(t.bottom)) - 0.5;
    const y_middle: f32 = @as(f32, @floatFromInt(t.top + t.bottom)) / 2.0;

    try testing.expect(sdTab(x_outside, y_middle, t, m) > 0); // not yet
    try testing.expect(sdTab(x_outside, y_baseline, t, m) < 0); // flared out
    // Symmetric on the right.
    const x_right: f32 = @as(f32, @floatFromInt(t.right)) + 3.0;
    try testing.expect(sdTab(x_right, y_middle, t, m) > 0);
    try testing.expect(sdTab(x_right, y_baseline, t, m) < 0);
}

test "the flare is CONCAVE - it hugs the baseline, not a rounded corner" {
    // A rounded bottom corner would make the tab NARROWER as y approaches the
    // baseline. The flare makes it WIDER, monotonically. That is the whole
    // visual difference, so pin the direction.
    const m = Metrics.init(1.0);
    const t = testTab(.active);
    var last_width: f32 = -1;
    var y: f32 = @as(f32, @floatFromInt(t.bottom)) - m.corner_bottom + 0.5;
    while (y < @as(f32, @floatFromInt(t.bottom))) : (y += 1.0) {
        // Walk left from the tab edge until we leave the shape.
        var x: f32 = @floatFromInt(t.left);
        var width: f32 = 0;
        while (x > @as(f32, @floatFromInt(t.left)) - m.corner_bottom - 2.0) : (x -= 0.25) {
            if (sdTab(x, y, t, m) > 0) break;
            width += 0.25;
        }
        try testing.expect(width >= last_width);
        last_width = width;
    }
    try testing.expect(last_width > 0);
}

test "the top corners are rounded" {
    const m = Metrics.init(1.0);
    const t = testTab(.active);
    // The very corner pixel is outside a rounded shape and inside a square one.
    try testing.expect(sdTab(
        @as(f32, @floatFromInt(t.left)) + 0.5,
        @as(f32, @floatFromInt(t.top)) + 0.5,
        t,
        m,
    ) > 0);
    // ...while a pixel one radius in is inside.
    try testing.expect(sdTab(
        @as(f32, @floatFromInt(t.left)) + m.corner_top,
        @as(f32, @floatFromInt(t.top)) + m.corner_top,
        t,
        m,
    ) < 0);
}

test "renderTab paints a rim brighter than both the fill and the strip" {
    const w: i32 = 200;
    const h: i32 = 32;
    var pixels = [_]u32{0} ** (200 * 32);
    const strip_packed: u32 = (@as(u32, STRIP.r) << 16) | (@as(u32, STRIP.g) << 8) | STRIP.b;
    for (&pixels) |*p| p.* = strip_packed;

    const t = testTab(.active);
    renderTab(&pixels, w, h, t, Metrics.init(1.0), STRIP, DARK);

    // Interior is the content background.
    const inside = px(&pixels, w, 70, 20);
    try testing.expectEqual(@as(u32, (@as(u32, DARK.r) << 16) | (@as(u32, DARK.g) << 8) | DARK.b), inside);

    // Somewhere along the top edge there is a pixel brighter than BOTH the
    // strip and the fill — that is the specular rim, and its absence is what
    // "you haven't added the border outline to the tabs" meant.
    var brightest: u32 = 0;
    var x: i32 = t.left;
    while (x < t.right) : (x += 1) {
        var y: i32 = t.top;
        while (y < t.top + 3) : (y += 1) {
            brightest = @max(brightest, lumOf(px(&pixels, w, x, y)));
        }
    }
    try testing.expect(brightest > lumOf(strip_packed));
    try testing.expect(brightest > lumOf(inside));
}

test "the rim clears the margins test/win32/tab-strip.ps1 measures on screen" {
    // T679 retuned the rim DOWN (a tab's top edge no longer takes the full
    // 0.28), and the two numbers that decide whether that went too far live in
    // a screenshot script that cannot run on the test desktop. So the same two
    // measurements, on the same geometry, in a lane that always runs: max over
    // a short scan, so one antialiased pixel neither makes nor breaks it.
    const w: i32 = 260;
    const h: i32 = 34;
    var pixels = [_]u32{0} ** (260 * 34);
    const strip_packed: u32 = (@as(u32, STRIP.r) << 16) | (@as(u32, STRIP.g) << 8) | STRIP.b;
    for (&pixels) |*p| p.* = strip_packed;

    // A real chiclet: 5px top pad under a 34px bar, ~160px wide.
    const t = Tab{ .left = 20, .top = 5, .right = 180, .bottom = 34, .surface = .active };
    const m = Metrics.init(1.0);
    renderTab(&pixels, w, h, t, m, STRIP, DARK);

    const scan = struct {
        fn maxLum(p: []const u32, bw: i32, x0: i32, x1: i32, y: i32) u32 {
            var best: u32 = 0;
            var x = x0;
            while (x <= x1) : (x += 1) best = @max(best, lumOf(px(p, bw, x, y)));
            return best;
        }
    };

    const fill_lum = lumOf(px(&pixels, w, 100, 20));
    const strip_lum = lumOf(strip_packed);
    const arc: i32 = @as(i32, @intFromFloat(m.corner_top)) + 4;
    // The script's first assertion: the top edge is a rim brighter than both
    // its own fill and the strip, by 30 levels summed over RGB.
    const top_rim = scan.maxLum(&pixels, w, t.left + arc, t.right - arc, t.top);
    try testing.expect(top_rim > fill_lum + 30);
    try testing.expect(top_rim > strip_lum + 30);

    // The script's second: the SAME rim on the tab's side is a gradient, not a
    // border — mid-height at least 12 levels over just above the baseline.
    //
    // Scanned strictly INSIDE the tab's right edge. Past it is strip, and the
    // strip is brighter than the selected tab's own fill plus a rim this far
    // down the gradient, so a scan that reaches outboard measures the strip on
    // both rows and reports a flat rim no matter what the rim does.
    const side_hi = scan.maxLum(&pixels, w, t.right - 3, t.right - 1, @divTrunc(t.top + t.bottom, 2));
    const side_lo = scan.maxLum(&pixels, w, t.right - 3, t.right - 1, t.bottom - 3);
    try testing.expect(side_hi >= side_lo + 12);
}

test "the rim field keeps the tab's real edges and drops its baseline" {
    // T242, at the mechanism. Everywhere there IS an edge the two fields must
    // agree, because the rim has to keep tracing the silhouette; along the
    // baseline only the clipped field has one, and that is the difference.
    const m = Metrics.init(1.25);
    const t = testTab(.active);
    const l: f32 = @floatFromInt(t.left);
    const tp: f32 = @floatFromInt(t.top);
    const b: f32 = @floatFromInt(t.bottom);

    // Mid-width on the bottom row: the clipped field says "edge here" (which
    // is what drew the line), the rim field says "deep inside".
    try testing.expect(sdTab(70.0, b - 0.5, t, m) > -m.rim_w);
    try testing.expect(sdTabRim(70.0, b - 0.5, t, m) < -m.rim_w);

    // The same holds inside a flare — its box bottom is the seam too, so the
    // line used to run the full flared width, not just the tab's.
    try testing.expect(sdTab(l - 2.0, b - 0.5, t, m) > -m.rim_w);
    try testing.expect(sdTabRim(l - 2.0, b - 0.5, t, m) < -m.rim_w);

    // Real edges are identical in both: the top, the sides, the flare's
    // outboard concave curve.
    try testing.expectApproxEqAbs(sdTab(70.0, tp + 0.5, t, m), sdTabRim(70.0, tp + 0.5, t, m), 0.001);
    try testing.expectApproxEqAbs(sdTab(l + 0.5, 20.0, t, m), sdTabRim(l + 0.5, 20.0, t, m), 0.001);
    // ...and each of those is within a hairline of the boundary, i.e. IS rim.
    try testing.expect(@abs(sdTabRim(l + 0.5, 20.0, t, m)) < m.rim_w);
}

test "the selected tab's baseline carries NO rim - it merges into the pane" {
    // The user's report, 2026-07-31: "the active tab seems to have a
    // horizontal line at the bottom, making it feel disconnected from the
    // pane below." Before T242 the bottom row was lightened by RIM_BOT (0.04,
    // ~9 levels on a dark theme) across the tab's whole width — undoing
    // T202's selection idiom, where the merge into the pane IS the cue.
    const w: i32 = 200;
    const h: i32 = 32;
    const fill = fillColor(.active, STRIP, DARK);
    const fill_packed: u32 = (@as(u32, fill.r) << 16) | (@as(u32, fill.g) << 8) | fill.b;
    const strip_packed: u32 = (@as(u32, STRIP.r) << 16) | (@as(u32, STRIP.g) << 8) | STRIP.b;
    const t = testTab(.active);

    // Every DPI the box actually runs at — the user's is 125%, where most of
    // these defects are invisible at 1.0 and obvious in life.
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        var pixels = [_]u32{0} ** (200 * 32);
        for (&pixels) |*p| p.* = strip_packed;
        renderTab(&pixels, w, h, t, Metrics.init(scale), STRIP, DARK);

        // Clear of the side rims at either end, which trace REAL edges and
        // must survive: the seam row is exactly the pane's own color.
        var x: i32 = t.left + 4;
        while (x < t.right - 4) : (x += 1) {
            try testing.expectEqual(fill_packed, px(&pixels, w, x, t.bottom - 1));
        }
    }
}

test "an unselected tab's baseline carries no rim either" {
    // Inactive tabs meet the pane too, so the seam is a seam there as well.
    // What separates selected from unselected stays the FILL, as designed.
    const w: i32 = 200;
    const h: i32 = 32;
    var pixels = [_]u32{0} ** (200 * 32);
    const strip_packed: u32 = (@as(u32, STRIP.r) << 16) | (@as(u32, STRIP.g) << 8) | STRIP.b;
    for (&pixels) |*p| p.* = strip_packed;

    const t = testTab(.inactive);
    renderTab(&pixels, w, h, t, Metrics.init(1.25), STRIP, DARK);

    const fill = fillColor(.inactive, STRIP, DARK);
    const fill_packed: u32 = (@as(u32, fill.r) << 16) | (@as(u32, fill.g) << 8) | fill.b;
    var x: i32 = t.left + 4;
    while (x < t.right - 4) : (x += 1) {
        try testing.expectEqual(fill_packed, px(&pixels, w, x, t.bottom - 1));
    }
}

test "renderTab antialiases its curves instead of hard-stepping" {
    const w: i32 = 200;
    const h: i32 = 32;
    var pixels = [_]u32{0} ** (200 * 32);
    const strip_packed: u32 = (@as(u32, STRIP.r) << 16) | (@as(u32, STRIP.g) << 8) | STRIP.b;
    for (&pixels) |*p| p.* = strip_packed;

    const t = testTab(.active);
    renderTab(&pixels, w, h, t, Metrics.init(1.0), STRIP, DARK);

    // Across the top-left corner arc there must be at least one pixel that is
    // neither the strip nor the fill nor the rim's extreme — a partial
    // coverage value. A GDI region produces none.
    const fill_l = lumOf((@as(u32, DARK.r) << 16) | (@as(u32, DARK.g) << 8) | DARK.b);
    const strip_l = lumOf(strip_packed);
    var partials: usize = 0;
    var x: i32 = t.left;
    while (x < t.left + 8) : (x += 1) {
        var y: i32 = t.top;
        while (y < t.top + 8) : (y += 1) {
            const l = lumOf(px(&pixels, w, x, y));
            if (l != strip_l and l != fill_l) partials += 1;
        }
    }
    try testing.expect(partials > 0);
}

test "renderTab stays inside the buffer for tabs at its edges" {
    const w: i32 = 60;
    const h: i32 = 32;
    var pixels = [_]u32{0} ** (60 * 32);
    const m = Metrics.init(1.0);
    // Flush left, flush right, and taller than the buffer: none may trap.
    renderTab(&pixels, w, h, .{ .left = 0, .top = 3, .right = 30, .bottom = 32, .surface = .active }, m, STRIP, DARK);
    renderTab(&pixels, w, h, .{ .left = 30, .top = 3, .right = 60, .bottom = 40, .surface = .inactive }, m, STRIP, DARK);
    renderTab(&pixels, w, h, .{ .left = -10, .top = -5, .right = 20, .bottom = 32, .surface = .hovered }, m, STRIP, DARK);
    // Degenerate rects are ignored rather than wrapping.
    renderTab(&pixels, w, h, .{ .left = 10, .top = 3, .right = 10, .bottom = 32, .surface = .active }, m, STRIP, DARK);
}

test "the rim stays a hairline as DPI rises" {
    // A rim that scaled with DPI would be a 2-3px BORDER on a 200% display,
    // which is a different design, not the same one bigger.
    try testing.expectApproxEqAbs(@as(f32, 1.0), Metrics.init(1.0).rim_w, 0.001);
    try testing.expect(Metrics.init(3.0).rim_w <= 2.0);
    try testing.expect(Metrics.init(1.0).rim_w >= 1.0);
}

test "corners scale with DPI" {
    const m = Metrics.init(2.0);
    try testing.expectApproxEqAbs(CORNER_TOP * 2.0, m.corner_top, 0.001);
    try testing.expectApproxEqAbs(CORNER_BOTTOM * 2.0, m.corner_bottom, 0.001);
}

test "the shipped build is not neutered" {
    try testing.expect(!T206_NEUTERED);
}
