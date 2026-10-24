//! How much of a pane its window shows, for the pane's popups (T2227). The
//! rule and its geometry are `pane_clip_math.zig`; this is the window walk.

const w32 = @import("win32.zig");
const math = @import("pane_clip_math.zig");

pub const Clip = math.Clip;

fn fromRect(r: w32.RECT) math.Rect {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

/// The part of `hwnd` that is on show inside its ancestors, in screen
/// coordinates: its window rect intersected with the client area of every
/// window that clips it (each parent of a WS_CHILD, up to the top-level).
/// Null when none of it is.
pub fn visibleRect(hwnd: w32.HWND) ?math.Rect {
    var wr: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &wr) == 0) return null;
    var vis = fromRect(wr);
    var h = hwnd;
    while (w32.GetWindowLongW(h, w32.GWL_STYLE) & w32.WS_CHILD != 0) {
        const parent = w32.GetParent(h) orelse break;
        var cr: w32.RECT = undefined;
        if (w32.GetClientRect(parent, &cr) == 0) break;
        var tl: w32.POINT = .{ .x = cr.left, .y = cr.top };
        var br: w32.POINT = .{ .x = cr.right, .y = cr.bottom };
        _ = w32.ClientToScreen(parent, &tl);
        _ = w32.ClientToScreen(parent, &br);
        vis = math.intersect(vis, .{ .left = tl.x, .top = tl.y, .right = br.x, .bottom = br.y }) orelse return null;
        h = parent;
    }
    return vis;
}

/// How much of `owner` (a pane) is in view.
pub fn ownerClip(owner: w32.HWND) Clip {
    var wr: w32.RECT = undefined;
    if (w32.GetWindowRect(owner, &wr) == 0) return .none;
    return math.clip(fromRect(wr), visibleRect(owner));
}

/// Whether `owner` is on show with ALL of it in view - the condition for a
/// popup with content of its own (scrollbar, banner, badge, pill, bell frame)
/// to be shown over it. A hidden owner is not.
pub fn ownerWhollyInView(owner: w32.HWND) bool {
    if (w32.IsWindowVisible_(owner) == 0) return false;
    return ownerClip(owner) == .whole;
}
