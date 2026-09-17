//! Geometry for the viewer nav bar (T159, design P3): where the buttons and
//! the address field sit at one DPI scale, and what the bar sheds as the pane
//! narrows. Pure — every number is arithmetic on the design-system scale, so
//! the whole module asserts in the none-runtime lane at 1.0/1.25/1.5/2.0 (the
//! defects this catches are invisible at 1.0 and obvious at 1.25).
//!
//! There is no show/hide policy here, and that absence is the point (T1185,
//! Mac fc7e36356): the bar is part of every viewer pane's frame, always on
//! screen, so the only question left is where its controls go.
const std = @import("std");
const icon_button = @import("icon_button.zig");
// The feedback button's tooltip is already worded (and tested) beside the
// provenance that decides whether the button exists at all, so `label` reads
// it from there rather than keeping a second copy of the same sentence.
const viewer_worktree = @import("viewer_worktree.zig");

pub const Rect = icon_button.Rect;

/// Bar height: a 28 DIP icon button with the design system's 4 DIP breathing
/// room above and below. The container is sized to the control, not the
/// reverse.
pub const bar_dip: f32 = 36.0;

/// The condensed address field's designed minimum width (DIP), and the whole
/// answer to "1 button and 1 tiny input?" (user, on D83's resolution). The
/// field is either wide enough to read an address in — about ten characters at
/// the body ramp — or it is not painted at all. There is deliberately no band
/// in between: a field that keeps shrinking past legibility is the "trimmed,
/// not designed" look this task exists to remove, and a two-pixel EDIT with a
/// caret in it is worse than an honest absence, because it looks like a
/// rendering fault rather than a compact mode.
pub const field_min_dip: f32 = 72.0;

/// The bar's buttons, in strip order. `contents` leads and exists only in a
/// narrow viewer pane whose document has a table of contents (T160): the
/// compact card's only opener lives in the chrome bar. Mac puts the same
/// button first in its chrome bar.
///
/// `feedback` TRAILS — it is the only button on the far side of the address
/// field — and exists only when the pane's content resolves to a git worktree
/// (T633). With nowhere to file a report the button would be a lie, so it is
/// absent rather than disabled; Mac's chrome bar places and gates it the same
/// way.
/// `overflow` is the "…" control (T1159): it closes the leading cluster and
/// exists only when this width could not pay for every command, carrying the
/// ones it dropped in a popup menu. It is a CONSEQUENCE of the layout rather
/// than an input to it — nothing asks for it, the arithmetic decides — which is
/// why it has no flag in `Shown`.
/// `prev_change` / `next_change` / `diff_style` exist only in a DIFF pane
/// (T817), and sit after Home exactly where Mac's chrome bar puts them
/// (`ViewerSplitLeaf.chrome`). They are three more buttons in the same strip
/// rather than a second row: a diff pane keeps this bar open anyway, so a
/// separate control strip would be a second permanent band of chrome buying
/// nothing.
pub const Button = enum {
    contents,
    back,
    forward,
    reload,
    home,
    prev_change,
    next_change,
    diff_style,
    overflow,
    feedback,
};
pub const button_count = std.enums.values(Button).len;

/// The leading cluster, in strip order, before the overflow control.
const leading_order = [_]Button{
    .contents,
    .back,
    .forward,
    .reload,
    .home,
    .prev_change,
    .next_change,
    .diff_style,
};

/// The order commands are given up to the overflow menu as the pane narrows:
/// what goes into the menu FIRST is what is reached for least.
///
/// Until T817 this was `leading_order` read backwards, which is the same list
/// while the strip ends at Home. It cannot stay implicit now that it does not:
/// in a diff pane the whole point of the bar is stepping changes, so the diff
/// controls outlive back/forward — the buttons a reader walking a diff touches
/// least — even though they are painted after them. The contents toggle still
/// sheds last, in a diff pane because it opens the file list and elsewhere
/// because it is the compact TOC's only opener.
const shed_order = [_]Button{
    .home,
    .reload,
    .forward,
    .back,
    .diff_style,
    .prev_change,
    .next_change,
    .contents,
};

/// Which of the two conditional buttons this bar is showing. A struct rather
/// than positional bools so a third condition cannot silently swap with a
/// second at a call site.
pub const Shown = struct {
    contents: bool = false,
    feedback: bool = false,
    /// Whether this pane is showing a diff, which is the whole condition on
    /// the three diff controls — Mac gates them on `isDiffMode` and nothing
    /// else, because a diff pane always has changes to step and a layout to
    /// choose, even when the diff turns out to be empty.
    diff: bool = false,
};

/// Whether this bar asks for `b` at all. The one place a button's PRESENCE
/// condition lives, so the strip order, the shed order and the reachability
/// assertion cannot disagree about which commands exist on a given bar.
pub fn asks(shown: Shown, b: Button) bool {
    return switch (b) {
        .contents => shown.contents,
        .feedback => shown.feedback,
        .prev_change, .next_change, .diff_style => shown.diff,
        // The "…" is a consequence of the layout, never something asked for.
        .overflow => false,
        .back, .forward, .reload, .home => true,
    };
}

/// Everything the bar paints, in physical pixels, for one scale and width.
pub const Layout = struct {
    /// Bar band height (the host window insets the content by exactly this,
    /// so top-of-page content is never covered).
    bar_h: i32,
    /// Painted squares of the buttons, indexed by `Button`. A button the bar
    /// is not showing (the contents toggle outside the compact TOC layout)
    /// has an EMPTY rect: it takes no room, paints nothing, and hits nothing.
    buttons: [button_count]Rect,
    /// The address field (a real EDIT control fills this rect). EMPTY when the
    /// pane is too narrow for a legible field (`field_min_dip`) — see there for
    /// why there is no shrinking middle ground.
    address: Rect,
    /// The commands this width folded into the overflow menu, indexed by
    /// `Button`. Every true here has an empty rect in `buttons`, and the
    /// `overflow` control is painted iff any of them is true — so "a dropped
    /// button is unreachable" cannot come back by accident: the two facts are
    /// the same array.
    overflowed: [button_count]bool,

    /// Whether the "…" control is showing (equivalently: whether anything was
    /// folded into its menu).
    pub fn hasOverflow(self: *const Layout) bool {
        return self.buttons[@intFromEnum(Button.overflow)].width() > 0;
    }

    /// The commands in the overflow menu, in strip order, written into `buf`.
    /// The order matters: the menu reads like the strip it stands in for.
    pub fn overflowItems(self: *const Layout, buf: *[button_count]Button) []const Button {
        var n: usize = 0;
        for (leading_order) |b| {
            if (self.overflowed[@intFromEnum(b)]) {
                buf[n] = b;
                n += 1;
            }
        }
        if (self.overflowed[@intFromEnum(Button.feedback)]) {
            buf[n] = .feedback;
            n += 1;
        }
        return buf[0..n];
    }

    pub fn init(scale: f32, width: i32, shown: Shown) Layout {
        const m = icon_button.Metrics.init(scale);
        const pad = px(4.0, scale); // band edge + inter-button gap
        const field_gap = px(8.0, scale); // buttons cluster <-> field
        const field_min = px(field_min_dip, scale);
        const bar_h = px(bar_dip, scale);
        const top = @divTrunc(bar_h - m.target, 2);
        const slot = m.target + pad; // one button plus the gap after it

        // The commands this bar wants to show, in strip order. Everything
        // after `wanted` in `leading_order` is not asked for at this width.
        var order: [leading_order.len]Button = undefined;
        var wanted: usize = 0;
        for (leading_order) |b| {
            if (!asks(shown, b)) continue;
            order[wanted] = b;
            wanted += 1;
        }

        // Pick the widest arrangement this pane can actually pay for: the most
        // leading buttons — then the trailing feedback button — that still
        // leaves a LEGIBLE address field. Shedding walks `shed_order` and only
        // ever forwards, so widening can never take a control away.
        //
        // Since T1159 what is shed does not vanish: the moment anything is,
        // the cluster ends in a "…" control carrying the dropped commands, so
        // a compact bar is a compact bar rather than a truncated one. That
        // control costs a slot, which is why it is inside the search instead of
        // bolted on after it.
        const Fit = struct {
            /// How many of `shed_order`'s entries have been given up. The
            /// SHAPE of the fit, not a count of what is painted: the strip
            /// order and the shed order are two different lists since T817, so
            /// "the first k of the strip" no longer describes a bar.
            shed: usize,
            feedback: bool,
            overflow: bool,
            field: bool,
        };
        var fit: Fit = .{ .shed = wanted, .feedback = false, .overflow = false, .field = false };
        var shed: usize = 0;
        var want_fb = shown.feedback;
        while (true) {
            const ovf = (shed > 0) or (shown.feedback and !want_fb);
            const slots: i32 = @intCast(wanted - shed + @intFromBool(ovf));
            const cluster: i32 = slots * slot;
            const fb_left = width - pad - m.target;
            const f_left = if (slots > 0) cluster + field_gap else pad;
            const f_right = if (want_fb) fb_left - field_gap else width - pad;
            const room = (slots == 0 or cluster <= width - pad) and
                (!want_fb or (fb_left >= cluster + pad and fb_left >= pad)) and
                (f_right - f_left >= field_min);
            if (room) {
                fit = .{ .shed = shed, .feedback = want_fb, .overflow = ovf, .field = true };
                break;
            }
            if (shed < wanted) {
                shed += 1;
                continue;
            }
            if (want_fb) {
                want_fb = false;
                continue;
            }
            // Nothing fits with a field: the minimum band. All that is left is
            // the "…" — one whole control the user can still reach every
            // command through — and even that goes if the band cannot hold it.
            const ovf_only = (wanted > 0 or shown.feedback) and pad + m.target <= width - pad;
            fit = .{ .shed = wanted, .feedback = false, .overflow = ovf_only, .field = false };
            break;
        }

        // Which commands this fit gave up, resolved from the shed order onto
        // the buttons the strip actually asked for.
        var is_shed = [_]bool{false} ** button_count;
        {
            var n: usize = 0;
            for (shed_order) |b| {
                if (n >= fit.shed) break;
                if (!asks(shown, b)) continue;
                is_shed[@intFromEnum(b)] = true;
                n += 1;
            }
        }

        var buttons: [button_count]Rect = undefined;
        var overflowed: [button_count]bool = undefined;
        for (&buttons, &overflowed) |*b, *o| {
            b.* = .{ .left = 0, .top = top, .right = 0, .bottom = top };
            o.* = false;
        }

        var x = pad;
        for (order[0..wanted]) |b| {
            if (!is_shed[@intFromEnum(b)]) {
                buttons[@intFromEnum(b)] = .{
                    .left = x,
                    .top = top,
                    .right = x + m.target,
                    .bottom = top + m.target,
                };
                x += slot;
            } else {
                overflowed[@intFromEnum(b)] = true;
            }
        }
        if (fit.overflow) {
            buttons[@intFromEnum(Button.overflow)] = .{
                .left = x,
                .top = top,
                .right = x + m.target,
                .bottom = top + m.target,
            };
            x += slot;
        }
        // No "…" control means no menu to be in. Below about 40 DIP the band
        // cannot hold even one whole button, so the commands really are gone
        // for that width — and `overflowed` must say so, or `hasOverflow` and
        // the array it indexes would disagree about the same fact.
        if (!fit.overflow) {
            for (&overflowed) |*o| o.* = false;
        }

        const painted_any = x > pad;
        // The leading cluster's right edge — where the field may start, and the
        // floor the trailing button may not cross.
        const cluster_right = if (painted_any) x - pad else 0;

        // Feedback trails: measured in from the band's own right edge, never
        // past the leading cluster. When the width cannot hold it there it is
        // not parked off the edge (where it painted nothing and answered no
        // click) and no longer merely dropped — it joins the overflow menu.
        if (shown.feedback) {
            if (fit.feedback) {
                const left = width - pad - m.target;
                buttons[@intFromEnum(Button.feedback)] = .{
                    .left = left,
                    .top = top,
                    .right = left + m.target,
                    .bottom = top + m.target,
                };
            } else if (fit.overflow) {
                overflowed[@intFromEnum(Button.feedback)] = true;
            }
        }

        // The field takes what is left between the cluster and the trailing
        // button — or nothing at all, in the minimum band. Both edges are
        // clamped into the band: a bar too narrow to hold even the leading gap
        // would otherwise put an empty field rect PAST the bar's right edge,
        // which is still a rect outside the pane.
        const field_left = @min(
            if (painted_any) cluster_right + field_gap else pad,
            @max(width, 0),
        );
        const field_limit = if (fit.feedback)
            buttons[@intFromEnum(Button.feedback)].left - field_gap
        else
            width - pad;
        const field_right = if (fit.field) @max(field_limit, field_left) else field_left;
        return .{
            .bar_h = bar_h,
            .buttons = buttons,
            .overflowed = overflowed,
            .address = .{
                .left = field_left,
                .top = top,
                .right = field_right,
                .bottom = top + m.target,
            },
        };
    }

    pub fn button(self: *const Layout, which: Button) Rect {
        return self.buttons[@intFromEnum(which)];
    }

    /// Hit test against the buttons' HIT boxes (grown past the paint, per the
    /// design system: forgiving to click, invisible to layout).
    pub fn hitButton(self: *const Layout, scale: f32, x: i32, y: i32) ?Button {
        const m = icon_button.Metrics.init(scale);
        for (self.buttons, 0..) |b, i| {
            // An absent button's empty rect must not answer hits — inflating
            // it by the hit pad would otherwise conjure a phantom target.
            if (b.width() <= 0) continue;
            if (icon_button.hitBox(m, b).containsPoint(x, y)) {
                return @enumFromInt(i);
            }
        }
        return null;
    }
};

/// Everything outside the geometry a tooltip needs to name its button. A
/// struct rather than positional flags so a second bool cannot silently swap
/// with a third at a call site (the same rule `Shown` follows).
pub const Labels = struct {
    /// Whether the compact contents card is currently OPEN. The toggle names
    /// the action it would perform, not the state it is in (Mac's
    /// `sidePanelOpen`).
    contents_open: bool = false,
    /// A diff pane's card lists changed FILES rather than headings, and the
    /// toggle is renamed to match (Mac's `isDiffMode`).
    diff: bool = false,
    /// Where Home would go. Empty => the pane has no recorded home, and the
    /// label drops the destination clause rather than naming nowhere.
    home: []const u8 = "",
    /// The working tree a report would file into. Empty => the feedback button
    /// is ABSENT rather than disabled, so it has no tooltip at all.
    worktree: []const u8 = "",
    /// Whether the diff pane is rendering side by side (T817). The layout
    /// toggle names the state it is IN and the one it would go to, which is
    /// Mac's wording exactly — a toggle that named only the destination reads
    /// as a claim about what is on screen.
    diff_split: bool = false,
};

/// The tooltip for one button, into `buf`. Mac's `.help(...)` on the chrome
/// bar (`ViewerSplitLeaf.swift`), string for string -- Home's destination
/// clause included, because "back to where?" is the question a Home button
/// raises in a pane that has browsed away from where it started.
///
/// A disabled back/forward still gets one, which is why this takes no enabled
/// flag: Mac's `.help` survives `.disabled`, and "why can I not press this" is
/// the moment a label is worth most.
///
/// An empty answer means "this button has no tooltip" -- today only the
/// feedback button with no working tree, which is absent rather than silent.
pub fn label(buf: []u8, which: Button, state: Labels) []const u8 {
    return switch (which) {
        .contents => if (state.diff)
            (if (state.contents_open) "Hide files" else "Show files")
        else
            (if (state.contents_open) "Hide contents" else "Show contents"),
        .back => "Back",
        .forward => "Forward",
        .reload => "Reload",
        // A home too long to name is still a Home button: the clause is
        // dropped rather than truncated to a path that points somewhere else.
        .home => if (state.home.len == 0)
            "Home"
        else
            std.fmt.bufPrint(buf, "Home \u{2014} back to {s}", .{state.home}) catch "Home",
        // Mac's `.help` / `.accessibilityLabel` on the same three controls,
        // word for word (T817).
        .prev_change => "Previous change",
        .next_change => "Next change",
        .diff_style => if (state.diff_split)
            "Side-by-side \u{2014} switch to unified"
        else
            "Unified \u{2014} switch to side-by-side",
        // Mac has no overflow control; this is the strip's own, and its menu
        // already words itself the same way (`ViewerNavBar.overflowTitle`).
        .overflow => "More",
        .feedback => if (state.worktree.len == 0)
            ""
        else
            viewer_worktree.tooltipText(buf, state.worktree),
    };
}

fn px(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}
// -----------------------------------------------------------------------------

const testing = std.testing;
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "bar geometry holds the design system at every scale" {
    for (scales) |scale| {
        // Every bar variant holds the same rules: the two conditional buttons
        // either take their slot or take no room at all.
        for ([_]Shown{
            .{},
            .{ .contents = true },
            .{ .feedback = true },
            .{ .contents = true, .feedback = true },
        }) |shown| {
            const m = icon_button.Metrics.init(scale);
            const l = Layout.init(scale, px(600.0, scale), shown);
            const gap = px(4.0, scale);

            // The band is the control plus 4 DIP above and below — sized to
            // the control, and tall enough that nothing touches its edges.
            try testing.expect(l.bar_h >= m.target + 2 * gap - 1);
            for (l.buttons) |b| {
                if (b.width() <= 0) continue; // absent contents toggle
                try testing.expect(b.top >= gap - 1);
                try testing.expect(l.bar_h - b.bottom >= gap - 1);
                // Painted square is the shared icon-button size.
                try testing.expectEqual(m.target, b.width());
                try testing.expectEqual(m.target, b.height());
            }

            // >= 4 DIP between any two painted squares, and buttons stay in
            // strip order with no overlap.
            var prev: ?Rect = null;
            for (l.buttons) |b| {
                if (b.width() <= 0) continue;
                if (prev) |p| try testing.expect(b.left - p.right >= gap);
                prev = b;
            }

            // The field clears the leading cluster by 8 DIP and the band edge
            // (or the trailing button) by 8, and shares the buttons' band.
            try testing.expect(l.address.left - l.button(.home).right >= px(8.0, scale));
            try testing.expectEqual(l.button(.home).top, l.address.top);
            try testing.expect(l.address.right < px(600.0, scale));
            if (shown.feedback) {
                const fb = l.button(.feedback);
                try testing.expect(fb.left - l.address.right >= px(8.0, scale));
                // And the trailing button keeps the band's own 4 DIP edge.
                try testing.expect(px(600.0, scale) - fb.right >= gap - 1);
            }
        }
    }
}

test "the feedback button trails the field, and is absent when not asked for" {
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        const width = px(600.0, scale);
        const without = Layout.init(scale, width, .{});
        const with = Layout.init(scale, width, .{ .feedback = true });

        // Absent: an empty rect that answers no hit, even dead on the spot the
        // present one occupies.
        try testing.expectEqual(@as(i32, 0), without.button(.feedback).width());
        const at = with.button(.feedback);
        try testing.expect(
            without.hitButton(scale, at.left + 1, at.top + 1) != Button.feedback,
        );

        // Present: standard square, hard against the band's trailing 4 DIP
        // edge, and the field gives up exactly that much width.
        try testing.expectEqual(m.target, at.width());
        try testing.expectEqual(m.target, at.height());
        try testing.expectEqual(width - px(4.0, scale), at.right);
        try testing.expect(with.address.right < without.address.right);
        try testing.expectEqual(
            Button.feedback,
            with.hitButton(scale, @divTrunc(at.left + at.right, 2), @divTrunc(at.top + at.bottom, 2)).?,
        );
    }
}

test "a narrow pane squeezes the field, never overlaps two painted buttons" {
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        const gap = px(4.0, scale);
        // Narrow enough that the trailing button would land inside the leading
        // cluster if it were measured from the right edge alone.
        for ([_]i32{ 10, m.target * 2, m.target * 5 }) |width| {
            const l = Layout.init(scale, width, .{ .contents = true, .feedback = true });
            try testing.expect(l.address.right >= l.address.left);
            const fb = l.button(.feedback);
            const home = l.button(.home);
            // Either the trailing button was dropped for want of room, or it
            // clears the last PAINTED leading button by a full gap.
            if (fb.width() > 0 and home.width() > 0) {
                try testing.expect(fb.left - home.right >= gap);
            }
        }
    }
}

test "T1130: every painted control stays inside the bar, at every width" {
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        // From "nothing fits" up past the widest strip, one pixel at a time
        // through the interesting band: this is the invariant, so it may not
        // hold only at the widths somebody thought to name.
        var width: i32 = 0;
        while (width <= m.target * 8) : (width += 1) {
            const l = Layout.init(scale, width, .{ .contents = true, .feedback = true });
            for (l.buttons) |b| {
                if (b.width() <= 0) continue; // dropped: costs no pixels
                try testing.expect(b.left >= 0);
                try testing.expect(b.right <= width);
            }
            // The field may collapse to nothing, but never inverts and never
            // sits outside the band.
            try testing.expect(l.address.right >= l.address.left);
            try testing.expect(l.address.left >= 0);
            try testing.expect(l.address.right <= @max(width, 0));
        }
    }
}

test "T1130: buttons drop from the trailing end, and come back as the pane widens" {
    const scale: f32 = 1.0;
    const m = icon_button.Metrics.init(scale);
    const pad = px(4.0, scale);

    // Wide enough for the whole strip: every leading button is painted.
    const wide = Layout.init(scale, px(600.0, scale), .{ .contents = true, .feedback = true });
    for ([_]Button{ .contents, .back, .forward, .reload, .home, .feedback }) |which| {
        try testing.expect(wide.button(which).width() > 0);
    }

    // Room for two slots and nothing else: too narrow for a legible field, so
    // this is the MINIMUM band — one whole control, the "…", and every command
    // inside it.
    const two = Layout.init(scale, pad + 2 * (m.target + pad), .{ .contents = true, .feedback = true });
    try testing.expect(two.hasOverflow());
    for ([_]Button{ .contents, .back, .forward, .reload, .home, .feedback }) |which| {
        try testing.expectEqual(@as(i32, 0), two.button(which).width());
        try testing.expect(two.overflowed[@intFromEnum(which)]);
    }
    try testing.expectEqual(@as(i32, 0), two.address.width());

    // A button that moved into the menu answers no hit on the strip, dead on
    // where it would have been.
    const home_was = wide.button(.home);
    try testing.expect(two.hitButton(
        scale,
        @divTrunc(home_was.left + home_was.right, 2),
        @divTrunc(home_was.top + home_was.bottom, 2),
    ) == null);

    // Monotone: widening never takes a button away. (The control for the drop
    // rule — a rule that dropped on the way UP would be worse than clipping.)
    var painted_prev: usize = 0;
    var width: i32 = 0;
    while (width <= m.target * 8) : (width += 1) {
        const l = Layout.init(scale, width, .{ .contents = true, .feedback = true });
        var painted: usize = 0;
        for (l.buttons) |b| {
            if (b.width() > 0) painted += 1;
        }
        try testing.expect(painted >= painted_prev);
        painted_prev = painted;
    }
}

test "T1159: nothing the bar drops becomes unreachable" {
    // The invariant the overflow menu exists for. At every width and every
    // variant: a command the bar asked for is EITHER painted on the strip OR
    // in the menu — never both, and never neither while the "…" is up. Walked
    // one pixel at a time, because a rule that holds only at the widths
    // somebody thought to name is not the rule.
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        for ([_]Shown{
            .{},
            .{ .contents = true },
            .{ .feedback = true },
            .{ .contents = true, .feedback = true },
        }) |shown| {
            var width: i32 = 0;
            while (width <= m.target * 12) : (width += 1) {
                const l = Layout.init(scale, width, shown);
                var folded: usize = 0;
                for (std.enums.values(Button)) |b| {
                    const asked = asks(shown, b);
                    const painted = l.button(b).width() > 0;
                    const in_menu = l.overflowed[@intFromEnum(b)];
                    try testing.expect(!(painted and in_menu));
                    if (!asked) try testing.expect(!in_menu);
                    if (asked and l.hasOverflow()) try testing.expect(painted or in_menu);
                    if (in_menu) folded += 1;
                }
                // And the control is up exactly when it has something in it.
                try testing.expectEqual(l.hasOverflow(), folded > 0);
                // The menu never lists itself.
                try testing.expect(!l.overflowed[@intFromEnum(Button.overflow)]);

                // The condensed field is legible or absent — never a stub.
                const fw = l.address.width();
                try testing.expect(fw == 0 or fw >= px(field_min_dip, scale));
            }
        }
    }
}

test "T1159: the overflow menu lists the dropped commands in strip order" {
    const scale: f32 = 1.0;
    const m = icon_button.Metrics.init(scale);
    const pad = px(4.0, scale);
    const slot = m.target + pad;

    // A width with room for the "…" plus a legible field and nothing else:
    // every command is in the menu, in the order the strip would have shown
    // them, with the trailing feedback button last.
    const min_field = px(field_min_dip, scale);
    const narrow = Layout.init(scale, pad + slot + px(8.0, scale) + min_field + pad, .{
        .contents = true,
        .feedback = true,
    });
    try testing.expect(narrow.hasOverflow());
    try testing.expect(narrow.address.width() >= min_field);
    var buf: [button_count]Button = undefined;
    try testing.expectEqualSlices(
        Button,
        &[_]Button{ .contents, .back, .forward, .reload, .home, .feedback },
        narrow.overflowItems(&buf),
    );

    // Wide: nothing is dropped, so there is no "…" and the menu is empty.
    const wide = Layout.init(scale, px(600.0, scale), .{ .contents = true, .feedback = true });
    try testing.expect(!wide.hasOverflow());
    try testing.expectEqual(@as(usize, 0), wide.overflowItems(&buf).len);

    // In between, the strip sheds along `shed_order`, so what lands in the
    // menu first is what is reached for least. Stated as a PREFIX of that
    // order rather than as a suffix of the strip (T817): the two lists were
    // the same one until the diff controls arrived, and only one of them is
    // the rule.
    const shown: Shown = .{ .contents = true, .feedback = true };
    var asked_leading: usize = 0;
    for (leading_order) |b| {
        if (asks(shown, b)) asked_leading += 1;
    }
    var seen_partial = false;
    var width: i32 = 0;
    while (width <= px(600.0, scale)) : (width += 1) {
        const l = Layout.init(scale, width, shown);
        const items = l.overflowItems(&buf);
        if (items.len == 0 or items.len == asked_leading + 1) continue;
        seen_partial = true;
        // The trailing feedback button only ever joins them once the whole
        // leading cluster has already gone.
        const fb_in = items[items.len - 1] == .feedback;
        const lead = if (fb_in) items[0 .. items.len - 1] else items;
        if (fb_in) try testing.expectEqual(asked_leading, lead.len);

        // What is folded is exactly the first `lead.len` commands of the shed
        // order...
        var want = [_]bool{false} ** button_count;
        var n: usize = 0;
        for (shed_order) |b| {
            if (n >= lead.len) break;
            if (!asks(shown, b)) continue;
            want[@intFromEnum(b)] = true;
            n += 1;
        }
        try testing.expectEqual(lead.len, n);
        for (lead) |b| try testing.expect(want[@intFromEnum(b)]);

        // ...listed in STRIP order, which is what makes the menu read like the
        // bar it stands in for.
        var prev: usize = 0;
        for (lead) |b| {
            const at = for (leading_order, 0..) |c, i| {
                if (c == b) break i;
            } else unreachable;
            try testing.expect(at >= prev);
            prev = at;
        }
    }
    try testing.expect(seen_partial);
}

test "T1159: the three bands, and no control ever lands outside the pane" {
    const scale: f32 = 1.0;
    const m = icon_button.Metrics.init(scale);

    // Minimum band: the "…" alone, no field.
    const tiny = Layout.init(scale, m.target * 2, .{ .contents = true, .feedback = true });
    try testing.expect(tiny.hasOverflow());
    try testing.expectEqual(@as(i32, 0), tiny.address.width());

    // Below even that, nothing is painted at all — and nothing claims to be in
    // a menu that is not there.
    const nothing = Layout.init(scale, 12, .{ .contents = true, .feedback = true });
    try testing.expect(!nothing.hasOverflow());
    for (nothing.buttons) |b| try testing.expectEqual(@as(i32, 0), b.width());
    for (nothing.overflowed) |o| try testing.expect(!o);

    // Containment, re-asserted with the overflow control in the mix: the
    // T1130 rule may not have been traded away for the new one.
    for (scales) |s| {
        const mm = icon_button.Metrics.init(s);
        var width: i32 = 0;
        while (width <= mm.target * 12) : (width += 1) {
            const l = Layout.init(s, width, .{ .contents = true, .feedback = true });
            for (l.buttons) |b| {
                if (b.width() <= 0) continue;
                try testing.expect(b.left >= 0);
                try testing.expect(b.right <= width);
            }
            try testing.expect(l.address.right >= l.address.left);
            try testing.expect(l.address.left >= 0);
            try testing.expect(l.address.right <= @max(width, 0));
        }
    }
}

test "the contents toggle leads the strip, and is absent when not asked for" {
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        const without = Layout.init(scale, px(600.0, scale), .{});
        const with = Layout.init(scale, px(600.0, scale), .{ .contents = true });

        // Absent: an empty rect, and the back button holds the lead slot.
        try testing.expectEqual(@as(i32, 0), without.button(.contents).width());
        try testing.expectEqual(px(4.0, scale), without.button(.back).left);
        // And an empty rect answers no hit, even dead on its position.
        const c = without.button(.contents);
        try testing.expect(without.hitButton(scale, c.left, c.top) != Button.contents);

        // Present: first in the strip, standard size, and everything after it
        // shifts right by one slot.
        try testing.expectEqual(px(4.0, scale), with.button(.contents).left);
        try testing.expectEqual(m.target, with.button(.contents).width());
        try testing.expectEqual(
            with.button(.contents).right + px(4.0, scale),
            with.button(.back).left,
        );
    }
}

test "a violently narrow pane never inverts the field rect" {
    for (scales) |scale| {
        const l = Layout.init(scale, 10, .{ .contents = true });
        try testing.expect(l.address.right >= l.address.left);
    }
}

test "hit testing answers on the hit box, not the paint" {
    const scale: f32 = 1.25;
    const m = icon_button.Metrics.init(scale);
    const l = Layout.init(scale, 800, .{});
    const back = l.button(.back);
    // Dead center of the painted square.
    try testing.expectEqual(
        Button.back,
        l.hitButton(scale, @divTrunc(back.left + back.right, 2), @divTrunc(back.top + back.bottom, 2)).?,
    );
    // Just past the paint but inside the hit pad still answers.
    try testing.expectEqual(
        Button.back,
        l.hitButton(scale, back.right + m.hit_pad - 1, back.top).?,
    );
    // The gap midpoint between two buttons belongs to whichever hit box
    // reaches it first or neither — never both; here just assert it does not
    // crash and resolves deterministically.
    _ = l.hitButton(scale, back.right + m.hit_pad + 1, -50);
    // Far outside is nobody's.
    try testing.expectEqual(@as(?Button, null), l.hitButton(scale, 0, l.bar_h * 3));
}

test "every button says what it does (T639)" {
    var buf: [512]u8 = undefined;

    // The five Mac labels, string for string.
    try testing.expectEqualStrings("Back", label(&buf, .back, .{}));
    try testing.expectEqualStrings("Forward", label(&buf, .forward, .{}));
    try testing.expectEqualStrings("Reload", label(&buf, .reload, .{}));
    try testing.expectEqualStrings("More", label(&buf, .overflow, .{}));

    // The toggle names the action, not the state, and a diff pane's card is a
    // list of FILES rather than a table of contents.
    try testing.expectEqualStrings("Show contents", label(&buf, .contents, .{}));
    try testing.expectEqualStrings(
        "Hide contents",
        label(&buf, .contents, .{ .contents_open = true }),
    );
    try testing.expectEqualStrings("Show files", label(&buf, .contents, .{ .diff = true }));
    try testing.expectEqualStrings(
        "Hide files",
        label(&buf, .contents, .{ .diff = true, .contents_open = true }),
    );
}

test "Home names its destination, and stays a label without one (T639)" {
    var buf: [512]u8 = undefined;

    try testing.expectEqualStrings(
        "Home \u{2014} back to D:\\git\\ghoztty\\README.md",
        label(&buf, .home, .{ .home = "D:\\git\\ghoztty\\README.md" }),
    );
    try testing.expectEqualStrings(
        "Home \u{2014} back to https://example.org/docs",
        label(&buf, .home, .{ .home = "https://example.org/docs" }),
    );

    // A pane with no recorded home drops the clause rather than naming
    // nowhere -- the button is still there and still goes somewhere.
    try testing.expectEqualStrings("Home", label(&buf, .home, .{}));

    // And a destination that cannot FIT is the same case: better an unadorned
    // label than a path truncated to one that points somewhere else.
    var small: [8]u8 = undefined;
    try testing.expectEqualStrings("Home", label(&small, .home, .{ .home = "D:\\git\\ghoztty" }));
}

test "the feedback button's tooltip names its worktree, or does not exist (T639)" {
    var buf: [512]u8 = undefined;

    try testing.expectEqualStrings(
        "Send feedback to D:\\git\\ghoztty",
        label(&buf, .feedback, .{ .worktree = "D:\\git\\ghoztty" }),
    );
    // Outside a working tree the button is ABSENT, so it is asked for no
    // label at all; an empty answer is how the bar hears that.
    try testing.expectEqualStrings("", label(&buf, .feedback, .{}));
}

test "T817: the diff controls follow Home, and exist only in a diff pane" {
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        const gap = px(4.0, scale);
        const width = px(600.0, scale);
        const plain = Layout.init(scale, width, .{});
        const diff = Layout.init(scale, width, .{ .diff = true });

        for ([_]Button{ .prev_change, .next_change, .diff_style }) |b| {
            // Absent outside a diff: no room taken, and no hit answered even
            // dead on the square the diff bar puts it in.
            try testing.expectEqual(@as(i32, 0), plain.button(b).width());
            const at = diff.button(b);
            try testing.expect(plain.hitButton(scale, at.left + 1, at.top + 1) != b);

            // Present in one: the shared square, on the buttons' own band.
            try testing.expectEqual(m.target, at.width());
            try testing.expectEqual(m.target, at.height());
            try testing.expectEqual(diff.button(.home).top, at.top);
        }

        // In Mac's order, after Home and before the field, each clearing the
        // last by the design system's 4 DIP.
        try testing.expectEqual(diff.button(.home).right + gap, diff.button(.prev_change).left);
        try testing.expectEqual(
            diff.button(.prev_change).right + gap,
            diff.button(.next_change).left,
        );
        try testing.expectEqual(
            diff.button(.next_change).right + gap,
            diff.button(.diff_style).left,
        );
        try testing.expect(diff.address.left - diff.button(.diff_style).right >= px(8.0, scale));

        // Three more buttons cost the field three slots and nothing else.
        try testing.expect(diff.address.right == plain.address.right);
        try testing.expect(diff.address.left > plain.address.left);
    }
}

test "T817: a narrowing diff pane gives up browsing before change-stepping" {
    // The shed order, as the property it exists for rather than as a list: in
    // a diff pane the controls this task added are what the bar is FOR, so
    // they outlive back/forward even though they are painted after them. Walked
    // one pixel at a time — the crossover width is not a number anybody should
    // have to name.
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        var width: i32 = 0;
        while (width <= m.target * 14) : (width += 1) {
            const l = Layout.init(scale, width, .{ .diff = true, .contents = true });
            const painted = struct {
                fn f(lay: Layout, b: Button) bool {
                    return lay.button(b).width() > 0;
                }
            }.f;
            // Back/forward/reload/home are painted only while every diff
            // control still is.
            for ([_]Button{ .back, .forward, .reload, .home }) |b| {
                if (!painted(l, b)) continue;
                for ([_]Button{ .prev_change, .next_change, .diff_style }) |d| {
                    try testing.expect(painted(l, d));
                }
            }
            // ...and the contents toggle outlives the lot, in a diff pane
            // because it is what opens the file list.
            for ([_]Button{ .prev_change, .next_change, .diff_style }) |d| {
                if (painted(l, d)) try testing.expect(painted(l, .contents));
            }
        }
    }
}

test "T817: nothing a diff bar drops becomes unreachable" {
    // The T1159 invariant, re-asserted over the bar's new shape: at every
    // width, a command a DIFF bar asked for is either painted or in the menu —
    // never both, never neither while the "…" is up.
    for (scales) |scale| {
        const m = icon_button.Metrics.init(scale);
        for ([_]Shown{
            .{ .diff = true },
            .{ .diff = true, .contents = true },
            .{ .diff = true, .feedback = true },
            .{ .diff = true, .contents = true, .feedback = true },
        }) |shown| {
            var width: i32 = 0;
            while (width <= m.target * 16) : (width += 1) {
                const l = Layout.init(scale, width, shown);
                var folded: usize = 0;
                for (std.enums.values(Button)) |b| {
                    const painted = l.button(b).width() > 0;
                    const in_menu = l.overflowed[@intFromEnum(b)];
                    try testing.expect(!(painted and in_menu));
                    if (!asks(shown, b)) try testing.expect(!in_menu);
                    if (asks(shown, b) and l.hasOverflow()) {
                        try testing.expect(painted or in_menu);
                    }
                    if (painted) try testing.expect(b == .overflow or asks(shown, b));
                    if (in_menu) folded += 1;
                }
                try testing.expectEqual(l.hasOverflow(), folded > 0);
                // Containment holds with eight leading buttons in the strip.
                for (l.buttons) |b| {
                    if (b.width() <= 0) continue;
                    try testing.expect(b.left >= 0);
                    try testing.expect(b.right <= width);
                }
                const fw = l.address.width();
                try testing.expect(fw == 0 or fw >= px(field_min_dip, scale));
            }
        }
    }
}

test "T817: widening a diff bar never takes a control away" {
    const scale: f32 = 1.25;
    const m = icon_button.Metrics.init(scale);
    var painted_prev: usize = 0;
    var width: i32 = 0;
    while (width <= m.target * 16) : (width += 1) {
        const l = Layout.init(scale, width, .{ .diff = true, .contents = true, .feedback = true });
        var painted: usize = 0;
        for (l.buttons) |b| {
            if (b.width() > 0) painted += 1;
        }
        try testing.expect(painted >= painted_prev);
        painted_prev = painted;
    }
}

test "T817: the layout toggle names the state it is in, and the one it offers" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("Previous change", label(&buf, .prev_change, .{}));
    try testing.expectEqualStrings("Next change", label(&buf, .next_change, .{}));
    try testing.expectEqualStrings(
        "Unified \u{2014} switch to side-by-side",
        label(&buf, .diff_style, .{}),
    );
    try testing.expectEqualStrings(
        "Side-by-side \u{2014} switch to unified",
        label(&buf, .diff_style, .{ .diff_split = true }),
    );
}

test "no button is left unlabelled (T639)" {
    var buf: [512]u8 = undefined;
    const state: Labels = .{ .home = "D:\\git\\ghoztty", .worktree = "D:\\git\\ghoztty" };
    // The defect this task exists for was one labelled button out of six, and
    // it was invisible because nothing asked the question of the whole enum.
    // A button added tomorrow fails here until it has words.
    for (std.enums.values(Button)) |b| {
        try testing.expect(label(&buf, b, state).len > 0);
    }
}
