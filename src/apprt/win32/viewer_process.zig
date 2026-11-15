//! What a viewer pane does when a process its page runs in dies (T3107, port of
//! Mac 6c854957d `ViewerView.webViewWebContentProcessDidTerminate`). No OS
//! imports, so its unit tests run in every app-runtime lane.
//!
//! WebView2 reports it as `ProcessFailed`. Before this nothing subscribed, so a
//! pane whose renderer was killed (memory pressure, a page that ran itself into
//! the ground, a crash) stayed blank with `page_loaded` still true, and every
//! later render went to a dead page until the user reloaded by hand.
//!
//! - The page's own renderer exited or hung: reload it - at most
//!   `restart_limit` times in `restart_window_ms`, so a page that kills its
//!   renderer on every load does not respawn one forever. Past the cap the
//!   pane says so (its error card) rather than staying blank.
//! - The browser process exited: the controller is gone with it, and a reload
//!   has nothing to run in. The pane says so.
//! - Anything else (an iframe's renderer, the GPU or a utility process): the
//!   runtime recovers those itself and the page is still alive. Ignored.

const std = @import("std");

/// `COREWEBVIEW2_PROCESS_FAILED_KIND`, by ordinal.
pub const Kind = enum(u32) {
    browser_process_exited = 0,
    render_process_exited = 1,
    render_process_unresponsive = 2,
    frame_render_process_exited = 3,
    utility_process_exited = 4,
    sandbox_helper_process_exited = 5,
    gpu_process_exited = 6,
    ppapi_plugin_process_crashed = 7,
    ppapi_broker_process_crashed = 8,
    unknown_process_exited = 9,
    _,
};

/// Mac's `contentProcessRestartLimit` / `contentProcessRestartWindow`.
pub const restart_limit = 3;
pub const restart_window_ms: i64 = 60 * std.time.ms_per_s;

pub const Action = enum {
    /// Load the page again.
    reload,
    /// The renderer died again inside the window: stop, and say so.
    capped,
    /// The browser process is gone: no reload can run, say so.
    browser_gone,
    /// Not the page's process; the runtime handles it.
    ignore,
};

/// The restarts spent inside the window, oldest first.
pub const Budget = struct {
    stamps: [restart_limit]i64 = @splat(0),
    len: usize = 0,

    /// Decide what one `ProcessFailed` means at `now_ms`, spending a restart
    /// when the answer is `reload`. `kind` null (the runtime would not say) is
    /// treated as the renderer: reloading a live page is harmless, leaving a
    /// dead one blank is the defect.
    pub fn decide(self: *Budget, kind: ?Kind, now_ms: i64) Action {
        const k = kind orelse .render_process_exited;
        switch (k) {
            .browser_process_exited => return .browser_gone,
            .render_process_exited, .render_process_unresponsive => {},
            else => return .ignore,
        }
        self.expire(now_ms);
        if (self.len >= restart_limit) return .capped;
        self.stamps[self.len] = now_ms;
        self.len += 1;
        return .reload;
    }

    fn expire(self: *Budget, now_ms: i64) void {
        var keep: usize = 0;
        for (self.stamps[0..self.len]) |t| {
            if (now_ms - t > restart_window_ms) continue;
            self.stamps[keep] = t;
            keep += 1;
        }
        self.len = keep;
    }
};

pub fn kindFrom(raw: ?u32) ?Kind {
    return @enumFromInt(raw orelse return null);
}

const testing = std.testing;

test "viewer_process: a dead renderer reloads, up to the cap inside the window" {
    var b: Budget = .{};
    try testing.expectEqual(Action.reload, b.decide(.render_process_exited, 0));
    try testing.expectEqual(Action.reload, b.decide(.render_process_unresponsive, 1_000));
    try testing.expectEqual(Action.reload, b.decide(.render_process_exited, 2_000));
    try testing.expectEqual(Action.capped, b.decide(.render_process_exited, 3_000));
    // Capped stays capped while the restarts are still inside the window...
    try testing.expectEqual(Action.capped, b.decide(.render_process_exited, 59_000));
}

test "viewer_process: restarts older than the window are forgiven" {
    var b: Budget = .{};
    _ = b.decide(.render_process_exited, 0);
    _ = b.decide(.render_process_exited, 10_000);
    _ = b.decide(.render_process_exited, 20_000);
    try testing.expectEqual(Action.capped, b.decide(.render_process_exited, 30_000));
    // The first restart (t=0) is now more than a minute old: one slot back.
    try testing.expectEqual(Action.reload, b.decide(.render_process_exited, 60_001));
    try testing.expectEqual(Action.capped, b.decide(.render_process_exited, 60_002));
}

test "viewer_process: the browser process exiting is never a reload and spends nothing" {
    var b: Budget = .{};
    try testing.expectEqual(Action.browser_gone, b.decide(.browser_process_exited, 0));
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "viewer_process: processes the page does not run in are ignored" {
    var b: Budget = .{};
    for ([_]Kind{ .frame_render_process_exited, .gpu_process_exited, .utility_process_exited, .unknown_process_exited, @enumFromInt(42) }) |k| {
        try testing.expectEqual(Action.ignore, b.decide(k, 0));
    }
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "viewer_process: an unreadable kind is treated as the renderer" {
    var b: Budget = .{};
    try testing.expectEqual(Action.reload, b.decide(kindFrom(null), 0));
    try testing.expectEqual(Kind.render_process_exited, kindFrom(1).?);
    try testing.expectEqual(Kind.browser_process_exited, kindFrom(0).?);
}
