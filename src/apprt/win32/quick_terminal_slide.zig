//! The quick terminal's slide, as numbers (T2766, composition step 5d-6): no
//! OS imports, so the `none` lane asserts all of it.
//!
//! The slide used to move the quick terminal's top-level window with a
//! `SetWindowPos` per frame-clock tick on the UI thread, so a busy UI thread
//! froze it halfway onto the screen. A top-level window cannot be moved by
//! DirectComposition, and offsetting the window's own root visual would leave
//! every terminal pane behind (each pane composes on its own child window's
//! target, `renderer/gl_comp_present.zig`). So the slide is DWM's instead:
//!
//!   - the quick terminal sits at its FINAL rect, cloaked (`DWMWA_CLOAK`: still
//!     composed by DWM, not drawn, not hit-tested), so input stays off until
//!     it lands;
//!   - a host window over the travel area, owned by a slider thread of its own
//!     (`QuickTerminalSlider.zig`), shows a live DWM thumbnail of it;
//!   - that thread moves the thumbnail's destination once per DWM frame
//!     (`DwmFlush`), from `hidden` to `target` on the same ease as before.
//!
//! What lives here: where the window is at a given progress (`slideRect`),
//! the host's rect (`hostRect`), the thumbnail's destination inside the host
//! (`destInHost`), the reversal arithmetic (`reversedElapsed`), and the packed
//! `DWM_THUMBNAIL_PROPERTIES` bytes (`thumbProps`).
const std = @import("std");

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(r: Rect) i32 {
        return r.right - r.left;
    }
    pub fn height(r: Rect) i32 {
        return r.bottom - r.top;
    }
    pub fn isEmpty(r: Rect) bool {
        return r.right <= r.left or r.bottom <= r.top;
    }
};

pub const Direction = enum { in, out };

/// Cubic ease-in-out: smooth acceleration and deceleration. The quick
/// terminal's ease since it was vendored; both paths use this one.
pub fn easeInOutCubic(t: f64) f64 {
    if (t < 0.5) return 4.0 * t * t * t;
    const f = -2.0 * t + 2.0;
    return 1.0 - (f * f * f) / 2.0;
}

/// Interpolate between two values using eased progress.
pub fn lerp(a: i32, b: i32, t: f64) i32 {
    return a + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(b - a)) * t)));
}

/// Eased position along hidden(0) -> target(1) for linear `progress` through
/// a slide in `dir`. An out slide walks the same curve backwards.
pub fn easedT(progress: f64, dir: Direction) f64 {
    const p = std.math.clamp(progress, 0.0, 1.0);
    return switch (dir) {
        .in => easeInOutCubic(p),
        .out => 1.0 - easeInOutCubic(p),
    };
}

/// The quick terminal's screen rect at eased `t` (0 = hidden, 1 = target).
/// Its size is the target's throughout, exactly as the stepped path moved it.
pub fn slideRect(hidden: Rect, target: Rect, t: f64) Rect {
    const x = lerp(hidden.left, target.left, t);
    const y = lerp(hidden.top, target.top, t);
    return .{ .left = x, .top = y, .right = x + target.width(), .bottom = y + target.height() };
}

/// The host window's screen rect: everything the slide passes over, clipped
/// to the monitor. Clipping is what keeps the off-screen half of the travel
/// from showing on a neighbouring monitor (the stepped path drew it there,
/// since a window at `hidden` simply overhangs the edge). Null when the slide
/// never touches the monitor at all.
pub fn hostRect(hidden: Rect, target: Rect, mon: Rect) ?Rect {
    const u: Rect = .{
        .left = @min(hidden.left, target.left),
        .top = @min(hidden.top, target.top),
        .right = @max(hidden.right, target.right),
        .bottom = @max(hidden.bottom, target.bottom),
    };
    const c: Rect = .{
        .left = @max(u.left, mon.left),
        .top = @max(u.top, mon.top),
        .right = @min(u.right, mon.right),
        .bottom = @min(u.bottom, mon.bottom),
    };
    if (c.isEmpty()) return null;
    return c;
}

/// The thumbnail's destination in the host's client coordinates. DWM clips it
/// to the host, which is the monitor edge.
pub fn destInHost(slide: Rect, host: Rect) Rect {
    return .{
        .left = slide.left - host.left,
        .top = slide.top - host.top,
        .right = slide.right - host.left,
        .bottom = slide.bottom - host.top,
    };
}

/// Linear progress after `elapsed_s` of a `duration_s` slide.
pub fn progressAt(elapsed_s: f64, duration_s: f64) f64 {
    if (duration_s <= 0) return 1.0;
    return std.math.clamp(elapsed_s / duration_s, 0.0, 1.0);
}

/// A toggle mid-slide reverses it from where the window has got to: the new
/// slide is credited with the time the old one had LEFT, so its progress
/// starts at the old one's remainder and the eased position is continuous
/// (ease(1-p) mirrors ease(p)). Returns the elapsed seconds to credit.
pub fn reversedElapsed(elapsed_s: f64, duration_s: f64) f64 {
    const p = progressAt(elapsed_s, duration_s);
    return (1.0 - p) * duration_s;
}

// -----------------------------------------------------------------------
// DWM_THUMBNAIL_PROPERTIES
// -----------------------------------------------------------------------

/// `sizeof(DWM_THUMBNAIL_PROPERTIES)`: dwmapi.h declares it under
/// `pshpack1` (checked against the 10.0.26100.0 header), so the BYTE
/// `opacity` is NOT padded and the two BOOLs after it are unaligned. An
/// `extern struct` would be 48 bytes with every field after `opacity` in the
/// wrong place; it goes to DWM as raw bytes instead (T2724's DWM_TIMING_INFO
/// is the same trap).
pub const THUMB_PROPS_SIZE: usize = 45;

pub const DWM_TNP_RECTDESTINATION: u32 = 0x01;
pub const DWM_TNP_RECTSOURCE: u32 = 0x02;
pub const DWM_TNP_OPACITY: u32 = 0x04;
pub const DWM_TNP_VISIBLE: u32 = 0x08;
pub const DWM_TNP_SOURCECLIENTAREAONLY: u32 = 0x10;

pub const ThumbProps = struct {
    dest: Rect,
    source: Rect,
    opacity: u8 = 255,
    visible: bool = true,
    client_only: bool = true,
};

/// Every field set: destination, source, opacity, visibility, client area.
pub const thumb_all_flags: u32 = DWM_TNP_RECTDESTINATION | DWM_TNP_RECTSOURCE |
    DWM_TNP_OPACITY | DWM_TNP_VISIBLE | DWM_TNP_SOURCECLIENTAREAONLY;

pub fn thumbProps(p: ThumbProps) [THUMB_PROPS_SIZE]u8 {
    var b = [_]u8{0} ** THUMB_PROPS_SIZE;
    std.mem.writeInt(u32, b[0..4], thumb_all_flags, .little);
    writeRect(b[4..20], p.dest);
    writeRect(b[20..36], p.source);
    b[36] = p.opacity;
    std.mem.writeInt(i32, b[37..41], @intFromBool(p.visible), .little);
    std.mem.writeInt(i32, b[41..45], @intFromBool(p.client_only), .little);
    return b;
}

fn writeRect(out: *[16]u8, r: Rect) void {
    std.mem.writeInt(i32, out[0..4], r.left, .little);
    std.mem.writeInt(i32, out[4..8], r.top, .little);
    std.mem.writeInt(i32, out[8..12], r.right, .little);
    std.mem.writeInt(i32, out[12..16], r.bottom, .little);
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

const work_top: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
const monitor: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
const target_top: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 400 };
const hidden_top: Rect = .{ .left = 0, .top = -400, .right = 1920, .bottom = 0 };

test "slideRect lands on hidden at 0 and target at 1, size held" {
    try testing.expectEqual(hidden_top, slideRect(hidden_top, target_top, 0));
    try testing.expectEqual(target_top, slideRect(hidden_top, target_top, 1));
    const mid = slideRect(hidden_top, target_top, 0.5);
    try testing.expectEqual(@as(i32, -200), mid.top);
    try testing.expectEqual(target_top.height(), mid.height());
    try testing.expectEqual(target_top.width(), mid.width());
}

test "slideRect matches the stepped path's lerp at every frame" {
    // The stepped path computed x/y with lerp(hidden, target, eased) and the
    // target's size; the DWM slide must put the picture in the same place.
    var i: usize = 0;
    while (i <= 60) : (i += 1) {
        const p = @as(f64, @floatFromInt(i)) / 60.0;
        for ([_]Direction{ .in, .out }) |dir| {
            const t = easedT(p, dir);
            const r = slideRect(hidden_top, target_top, t);
            try testing.expectEqual(lerp(hidden_top.top, target_top.top, t), r.top);
            try testing.expectEqual(lerp(hidden_top.left, target_top.left, t), r.left);
        }
    }
}

test "easedT: in starts hidden and ends on target, out the reverse, clamped" {
    try testing.expectEqual(@as(f64, 0), easedT(0, .in));
    try testing.expectEqual(@as(f64, 1), easedT(1, .in));
    try testing.expectEqual(@as(f64, 1), easedT(0, .out));
    try testing.expectEqual(@as(f64, 0), easedT(1, .out));
    try testing.expectEqual(@as(f64, 1), easedT(7, .in));
    try testing.expectEqual(@as(f64, 0), easedT(-1, .in));
}

test "hostRect: a top slide covers hidden+target clipped to the monitor" {
    const h = hostRect(hidden_top, target_top, monitor).?;
    try testing.expectEqual(target_top, h);
}

test "hostRect: a centred quick terminal's host spans from the top edge down to it" {
    const target: Rect = .{ .left = 560, .top = 340, .right = 1360, .bottom = 740 };
    const hidden: Rect = .{ .left = 560, .top = work_top.top - 400, .right = 1360, .bottom = work_top.top };
    const h = hostRect(hidden, target, monitor).?;
    try testing.expectEqual(Rect{ .left = 560, .top = 0, .right = 1360, .bottom = 740 }, h);
}

test "hostRect: a bottom slide does not spill onto a monitor below" {
    const target: Rect = .{ .left = 0, .top = 640, .right = 1920, .bottom = 1040 };
    const hidden: Rect = .{ .left = 0, .top = 1040, .right = 1920, .bottom = 1440 };
    const h = hostRect(hidden, target, monitor).?;
    try testing.expectEqual(@as(i32, 1080), h.bottom);
    try testing.expectEqual(@as(i32, 640), h.top);
}

test "hostRect: a secondary monitor at negative coordinates" {
    const mon: Rect = .{ .left = -1920, .top = 0, .right = 0, .bottom = 1080 };
    const target: Rect = .{ .left = -1920, .top = 0, .right = -1520, .bottom = 1040 };
    const hidden: Rect = .{ .left = -2320, .top = 0, .right = -1920, .bottom = 1040 };
    const h = hostRect(hidden, target, mon).?;
    try testing.expectEqual(Rect{ .left = -1920, .top = 0, .right = -1520, .bottom = 1040 }, h);
}

test "hostRect: null when the slide never reaches the monitor" {
    const far: Rect = .{ .left = 5000, .top = 0, .right = 5400, .bottom = 400 };
    try testing.expect(hostRect(far, far, monitor) == null);
}

test "destInHost: the window's place relative to the host; hidden overhangs" {
    const h = hostRect(hidden_top, target_top, monitor).?;
    try testing.expectEqual(Rect{ .left = 0, .top = -400, .right = 1920, .bottom = 0 }, destInHost(hidden_top, h));
    try testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 1920, .bottom = 400 }, destInHost(target_top, h));
}

test "progressAt clamps, and a zero duration is already there" {
    try testing.expectEqual(@as(f64, 0.5), progressAt(0.1, 0.2));
    try testing.expectEqual(@as(f64, 1), progressAt(1, 0.2));
    try testing.expectEqual(@as(f64, 0), progressAt(-1, 0.2));
    try testing.expectEqual(@as(f64, 1), progressAt(0, 0));
}

test "reversedElapsed keeps the eased position continuous across a toggle" {
    const d = 0.2;
    var i: usize = 0;
    while (i <= 20) : (i += 1) {
        const el = d * @as(f64, @floatFromInt(i)) / 20.0;
        const before = easedT(progressAt(el, d), .in);
        const after = easedT(progressAt(reversedElapsed(el, d), d), .out);
        try testing.expectApproxEqAbs(before, after, 1e-9);
        const before_out = easedT(progressAt(el, d), .out);
        const after_in = easedT(progressAt(reversedElapsed(el, d), d), .in);
        try testing.expectApproxEqAbs(before_out, after_in, 1e-9);
    }
}

test "thumbProps: packed layout, 45 bytes, fields where dwmapi.h puts them" {
    const b = thumbProps(.{
        .dest = .{ .left = 1, .top = -2, .right = 3, .bottom = 4 },
        .source = .{ .left = 5, .top = 6, .right = 7, .bottom = 8 },
        .opacity = 200,
        .visible = true,
        .client_only = false,
    });
    try testing.expectEqual(@as(usize, 45), b.len);
    try testing.expectEqual(thumb_all_flags, std.mem.readInt(u32, b[0..4], .little));
    try testing.expectEqual(@as(u32, 0x1f), thumb_all_flags);
    try testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, b[4..8], .little));
    try testing.expectEqual(@as(i32, -2), std.mem.readInt(i32, b[8..12], .little));
    try testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, b[16..20], .little));
    try testing.expectEqual(@as(i32, 5), std.mem.readInt(i32, b[20..24], .little));
    try testing.expectEqual(@as(i32, 8), std.mem.readInt(i32, b[32..36], .little));
    try testing.expectEqual(@as(u8, 200), b[36]);
    try testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, b[37..41], .little));
    try testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, b[41..45], .little));
}
