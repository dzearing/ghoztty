//! The header a pane grows while rearrange mode is on (T1530). Pure geometry —
//! no OS imports — so every number here is asserted in the `none` lane, the
//! same arrangement `split_geometry.zig` and `pane_drop.zig` use.
//!
//! Mac parity: this is `macos/Sources/Features/Splits/PaneHeaderView.swift`
//! (b18ee2d77). A 24pt band at the very TOP of the pane, above the sticky
//! banner, holding a drag grip on the left, the pane's title, and a button on
//! the right that moves the pane out into its own window.
//!
//! The band takes REAL layout space rather than floating over the terminal,
//! which is why entering the mode resizes every pane in the window. That is
//! deliberate and it is Mac's choice too: a header that occludes nothing
//! cannot hide the row of output you were about to read.
//!
//! **One layout answers three questions.** The pane placement pass, the paint
//! pass and the hit test all call `layout`, so a header that is not drawn is
//! also not clickable and does not steal a pixel from the terminal. When they
//! were allowed to disagree — a band reserved by layout but suppressed by
//! paint — the result is a dead strip of window background that still swallows
//! clicks, which is the failure this shape makes unrepresentable.
//!
//! Distances are in PHYSICAL PIXELS: the constants Mac states in points are
//! scaled through `Metrics.forScale` rather than baked.

const std = @import("std");
const testing = std.testing;

/// A rectangle in win32 `RECT` terms: `right`/`bottom` exclusive.
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }
};

/// Point sizes, straight out of the Swift, scaled once per window.
pub const Metrics = struct {
    /// Band height. Mac's `PaneHeaderView.height`.
    height: i32,
    /// Inset from the pane's left/right edges to the first/last control.
    pad: i32,
    /// Gap between the grip, the title and the button.
    gap: i32,
    /// The grip glyph's box (three stacked rules, `line.3.horizontal`).
    grip: i32,
    /// The pop-out button's square hit box.
    button: i32,
    /// The separator rule along the band's bottom edge.
    rule: i32,

    pub fn forScale(scale: f32) Metrics {
        return .{
            .height = scaled(24, scale),
            .pad = scaled(8, scale),
            .gap = scaled(6, scale),
            .grip = scaled(12, scale),
            .button = scaled(20, scale),
            .rule = scaled(1, scale),
        };
    }

    /// The narrowest pane that can still hold the full header. Below this the
    /// pane gets no header at all rather than a squeezed one — see `layout`.
    pub fn minimumWidth(self: Metrics) i32 {
        return self.pad * 2 + self.grip + self.gap * 2 + self.button;
    }

    /// The shortest pane that can still hold a header. A header is only worth
    /// the space it takes if what is left is at least as tall as the header
    /// itself; below that the band would be most of the pane.
    pub fn minimumHeight(self: Metrics) i32 {
        return self.height * 2;
    }
};

fn scaled(points: i32, scale: f32) i32 {
    const v: f32 = @round(@as(f32, @floatFromInt(points)) * scale);
    return @max(@as(i32, @intFromFloat(v)), 1);
}

/// Where the header's controls sit, in the same coordinate space as the pane
/// slot that produced them.
pub const Layout = struct {
    /// The whole band, including the separator rule along its bottom.
    band: Rect,
    /// The drag grip glyph's box.
    grip: Rect,
    /// Where the pane title is drawn, clipped to this box.
    title: Rect,
    /// The pop-out button's hit box.
    button: Rect,
    /// The separator rule along the band's bottom edge.
    rule: Rect,
};

/// What is under a point inside the header.
pub const Hit = enum {
    /// Not on this header at all.
    none,
    /// The drag surface. The WHOLE band is draggable, not just the grip —
    /// Mac's `PaneDragSource` fills the header and the grip is a hint rather
    /// than the only target, so a user who grabs the title gets what they
    /// obviously meant.
    drag,
    /// The pop-out button.
    button,
};

/// The header for a pane occupying `slot`, or null when the pane is too small
/// to carry one.
///
/// Returning null rather than a squeezed band is the deliberate choice: a
/// 30px-tall pane with a 24px header is a header with a terminal accident
/// underneath it, and the user's grip on that pane is the window divider, not
/// a control they cannot read.
pub fn layout(slot: Rect, m: Metrics) ?Layout {
    if (slot.width() < m.minimumWidth()) return null;
    if (slot.height() < m.minimumHeight()) return null;

    const band: Rect = .{
        .left = slot.left,
        .top = slot.top,
        .right = slot.right,
        .bottom = slot.top + m.height,
    };
    const grip = centeredVertically(band, slot.left + m.pad, m.grip, m.grip);
    const button = centeredVertically(
        band,
        slot.right - m.pad - m.button,
        m.button,
        m.button,
    );
    return .{
        .band = band,
        .grip = grip,
        .title = .{
            .left = grip.right + m.gap,
            .top = band.top,
            .right = button.left - m.gap,
            .bottom = band.bottom,
        },
        .button = button,
        .rule = .{
            .left = band.left,
            .top = band.bottom - m.rule,
            .right = band.right,
            .bottom = band.bottom,
        },
    };
}

fn centeredVertically(band: Rect, left: i32, w: i32, h: i32) Rect {
    const top = band.top + @divFloor(band.height() - h, 2);
    return .{ .left = left, .top = top, .right = left + w, .bottom = top + h };
}

/// How much vertical space the header takes out of `slot`, which is what the
/// layout pass insets the pane by. Zero when the pane carries no header.
pub fn inset(slot: Rect, m: Metrics) i32 {
    const l = layout(slot, m) orelse return 0;
    return l.band.height();
}

/// What a point in the pane's own coordinate space means.
///
/// The button is tested BEFORE the drag surface, because it sits inside the
/// band: a press on it must be a press on the button and never the start of a
/// drag that happens to begin on a control.
pub fn hitTest(l: Layout, x: i32, y: i32) Hit {
    if (!l.band.contains(x, y)) return .none;
    if (l.button.contains(x, y)) return .button;
    return .drag;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const slot_1x: Rect = .{ .left = 100, .top = 50, .right = 900, .bottom = 650 };

test "T1530: the band sits at the very top of the pane and is 24pt tall" {
    const m = Metrics.forScale(1.0);
    const l = layout(slot_1x, m).?;
    try testing.expectEqual(@as(i32, 50), l.band.top);
    try testing.expectEqual(@as(i32, 74), l.band.bottom);
    try testing.expectEqual(@as(i32, 100), l.band.left);
    try testing.expectEqual(@as(i32, 900), l.band.right);
    // It spans the pane, so no pixel of the pane's top row belongs to the
    // terminal while the mode is on.
    try testing.expectEqual(slot_1x.width(), l.band.width());
}

test "T1530: the inset a pane is placed by is exactly the band height" {
    const m = Metrics.forScale(1.0);
    try testing.expectEqual(m.height, inset(slot_1x, m));
}

test "T1530: point sizes scale, and a 150% band is taller than a 100% one" {
    const one = Metrics.forScale(1.0);
    const one_five = Metrics.forScale(1.5);
    try testing.expectEqual(@as(i32, 24), one.height);
    try testing.expectEqual(@as(i32, 36), one_five.height);
    try testing.expect(one_five.button > one.button);
    try testing.expect(one_five.pad > one.pad);
    // The hairline rule never rounds away to nothing.
    try testing.expect(Metrics.forScale(0.1).rule >= 1);
}

test "T1530: grip left, button right, title between them" {
    const m = Metrics.forScale(1.0);
    const l = layout(slot_1x, m).?;
    try testing.expectEqual(slot_1x.left + m.pad, l.grip.left);
    try testing.expectEqual(slot_1x.right - m.pad, l.button.right);
    try testing.expect(l.title.left > l.grip.right);
    try testing.expect(l.title.right < l.button.left);
    try testing.expect(l.title.width() > 0);
}

test "T1530: the controls are centered in the band" {
    const m = Metrics.forScale(1.0);
    const l = layout(slot_1x, m).?;
    for ([_]Rect{ l.grip, l.button }) |r| {
        try testing.expectEqual(r.top - l.band.top, l.band.bottom - r.bottom);
        try testing.expect(r.top >= l.band.top);
        try testing.expect(r.bottom <= l.band.bottom);
    }
}

test "T1530: the separator rule is the bottom edge of the band, not below it" {
    const m = Metrics.forScale(1.0);
    const l = layout(slot_1x, m).?;
    try testing.expectEqual(l.band.bottom, l.rule.bottom);
    try testing.expectEqual(m.rule, l.rule.height());
    // Drawn INSIDE the reserved band, so it never overwrites a terminal row.
    try testing.expect(l.rule.top >= l.band.top);
}

test "T1530: a pane too short for a header gets none, and pays no inset" {
    const m = Metrics.forScale(1.0);
    const short: Rect = .{ .left = 0, .top = 0, .right = 800, .bottom = m.minimumHeight() - 1 };
    try testing.expect(layout(short, m) == null);
    try testing.expectEqual(@as(i32, 0), inset(short, m));
    // And the pane one pixel taller does get one, so the threshold is where
    // it claims to be rather than somewhere nearby.
    const ok: Rect = .{ .left = 0, .top = 0, .right = 800, .bottom = m.minimumHeight() };
    try testing.expect(layout(ok, m) != null);
}

test "T1530: a pane too narrow for the controls gets no header" {
    const m = Metrics.forScale(1.0);
    const narrow: Rect = .{ .left = 0, .top = 0, .right = m.minimumWidth() - 1, .bottom = 600 };
    try testing.expect(layout(narrow, m) == null);
    try testing.expectEqual(@as(i32, 0), inset(narrow, m));
    const ok: Rect = .{ .left = 0, .top = 0, .right = m.minimumWidth(), .bottom = 600 };
    const l = layout(ok, m).?;
    // At the exact minimum the title collapses to nothing but the grip and
    // the button still do not overlap, which is what the minimum means.
    try testing.expect(l.grip.right <= l.button.left);
}

test "T1530: the whole band drags, and the button is not part of it" {
    const m = Metrics.forScale(1.0);
    const l = layout(slot_1x, m).?;
    // The title area drags: the grip is a hint, not the only target.
    try testing.expectEqual(Hit.drag, hitTest(l, l.title.left + 4, l.band.top + 6));
    try testing.expectEqual(Hit.drag, hitTest(l, l.grip.left + 1, l.band.top + 6));
    // The button is itself, not the start of a drag.
    try testing.expectEqual(
        Hit.button,
        hitTest(l, l.button.left + @divFloor(m.button, 2), l.button.top + @divFloor(m.button, 2)),
    );
}

test "T1530: a point below the band is the terminal's, not the header's" {
    const m = Metrics.forScale(1.0);
    const l = layout(slot_1x, m).?;
    try testing.expectEqual(Hit.none, hitTest(l, 400, l.band.bottom));
    try testing.expectEqual(Hit.none, hitTest(l, 400, l.band.top - 1));
    try testing.expectEqual(Hit.none, hitTest(l, l.band.left - 1, l.band.top + 2));
    try testing.expectEqual(Hit.none, hitTest(l, l.band.right, l.band.top + 2));
}

test "T1530: two stacked panes each get their own band, at their own top" {
    const m = Metrics.forScale(1.0);
    const top: Rect = .{ .left = 0, .top = 0, .right = 800, .bottom = 300 };
    const bottom: Rect = .{ .left = 0, .top = 305, .right = 800, .bottom = 605 };
    const lt = layout(top, m).?;
    const lb = layout(bottom, m).?;
    try testing.expectEqual(@as(i32, 0), lt.band.top);
    try testing.expectEqual(@as(i32, 305), lb.band.top);
    // A point in the lower pane's band is not in the upper pane's.
    try testing.expectEqual(Hit.none, hitTest(lt, 400, 310));
    try testing.expectEqual(Hit.drag, hitTest(lb, 400, 310));
}
