//! The drag's composition thread (T2770): the dragged pane visuals keep
//! following the cursor while the window's thread is busy.
//!
//! T2769 made a divider drag write the pane visuals before its layout pass,
//! but on the window thread: a stall there (a slow paint, a GC-like pause in
//! a handler, the debug seam below) froze the edge under the hand. While a
//! divider drag is live in the composition tree this thread waits on the
//! compositor clock (`DCompositionWaitForCompositorClock`; `DwmFlush` where
//! that is missing), reads the cursor, extrapolates the gutter from the model
//! the window thread published at its last move (`comp_drag.PaneModel`), and
//! writes the moving visuals' offsets and clips and commits.
//!
//! The window thread still owns capture, the child windows, their resizes and
//! the exact layout. Every move it handles republishes the model at its own
//! layout, so the thread only ever extrapolates from the newest truth, and a
//! fold or a give-way the model does not know is the window thread's to show.
//!
//! **The device lock.** DirectComposition objects are free-threaded, but a
//! commit publishes every pending change on the device, whichever thread
//! made it. So the thread writes and commits holding `lock`, and the window
//! thread holds the same lock across its own writes to the dragged visuals
//! and their commit (`Window.preplaceDragVisuals`, the coalesced pass), so
//! neither ever commits half of the other's frame. `lockedByMe` is the debug
//! assertion the window thread's pane placement checks.
//!
//! The thread lives for one drag: started at the first move that publishes a
//! model, stopped (joined) at button-up, capture loss and window close. It
//! holds its own references on the device and every visual it may write, so
//! a pane closed or a host rebuilt under the drag never frees what it is
//! writing; a failed write (a lost device) stops its writes for the drag.
//!
//! `GHOZTTY_COMP_DRAG_THREAD=0` keeps a drag on the window thread alone (the
//! control). Debug seams: `GHOZTTY_DEBUG_DRAG_STALL_MS=<n>` blocks the
//! window thread for n ms at a drag's 6th move (`stalled` marks it), and
//! `GHOZTTY_DEBUG_DRAG_CURSOR_FILE=<path>` reads the cursor as "x y" (screen
//! px) from a file the harness writes, because the test desktop has no
//! cursor of its own to follow.
const CompDragThread = @This();

const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const comp_tree = @import("../../renderer/comp_tree.zig");
const comp_drag = @import("comp_drag.zig");
const chrome_comp = @import("chrome_comp.zig");
const FrameClock = @import("FrameClock.zig");

const log = std.log.scoped(.comp_drag_thread);

pub const max_panes = 64;

/// Consecutive SURFACE_BEING_RENDERED refusals tolerated (about a second of
/// frames) before the thread gives the drag back to the window thread.
const max_commit_refusals = 60;

/// Set by the debug stall seam while the window thread is blocked in it.
pub var stalled: std.atomic.Value(bool) = .init(false);

/// One visual the thread may move, with its own references.
pub const Pane = struct {
    vis: chrome_comp.Obj,
    rounded: ?chrome_comp.Obj,
    shadow: ?chrome_comp.Obj,
    sdx: f32,
    sdy: f32,
    model: comp_drag.PaneModel,

    fn retain(self: Pane) void {
        chrome_comp.addRefObj(self.vis);
        if (self.rounded) |r| chrome_comp.addRefObj(r);
        if (self.shadow) |s| chrome_comp.addRefObj(s);
    }

    fn releaseAll(self: Pane) void {
        chrome_comp.releaseObj(self.vis);
        if (self.rounded) |r| chrome_comp.releaseObj(r);
        if (self.shadow) |s| chrome_comp.releaseObj(s);
    }
};

/// What the window thread publishes at each move it lays out.
pub const Publish = struct {
    axis: comp_drag.Axis,
    /// The pointer along the axis, in SCREEN px, that the poses describe.
    base: i32,
    min: f32,
};

alloc: std.mem.Allocator,
dcomp: chrome_comp.Obj,
thread: ?std.Thread = null,
stopping: std.atomic.Value(bool) = .init(false),
wake: ?w32.HANDLE = null,

/// The device lock, and who holds it (thread id, 0: nobody).
lock: std.Thread.Mutex = .{},
owner: std.atomic.Value(u32) = .init(0),

// Guarded by `lock`.
panes: [max_panes]Pane = undefined,
n: usize = 0,
axis: comp_drag.Axis = .x,
base: i32 = 0,
limits: comp_drag.Limits = .{ .lo = 0, .hi = 0 },
gen: u64 = 0,
written_gen: u64 = 0,
written_d: f32 = 0,
dead: bool = false,
/// Consecutive Commits refused because a surface was mid-draw.
commit_refusals: u32 = 0,
stats: comp_drag.ThreadStats = .{},

/// Thread only.
wait_clock: ?FrameClock.WaitForCompositorClockFn = null,
cursor_file: ?[]u8 = null,

/// `GHOZTTY_COMP_DRAG_THREAD=0`: no thread; the drag stays on the window
/// thread (the A/B and the negative control).
pub fn enabled() bool {
    const S = struct {
        var v: ?bool = null;
    };
    if (S.v) |v| return v;
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_COMP_DRAG_THREAD") catch {
        S.v = true;
        return true;
    };
    defer std.heap.page_allocator.free(raw);
    const v = !std.mem.eql(u8, raw, "0");
    S.v = v;
    return v;
}

/// Start a thread over `dcomp` (the window's device; the thread takes its
/// own reference). Null when it cannot start: the drag carries on without.
pub fn start(alloc: std.mem.Allocator, dcomp: chrome_comp.Obj) ?*CompDragThread {
    if (comptime builtin.os.tag != .windows) return null;
    const self = alloc.create(CompDragThread) catch return null;
    self.* = .{ .alloc = alloc, .dcomp = dcomp };
    chrome_comp.addRefObj(dcomp);
    self.wait_clock = FrameClock.loadCompositorClock();
    self.wake = w32.CreateEventW(null, 1, 0, null);
    if (builtin.mode == .Debug) {
        self.cursor_file = std.process.getEnvVarOwned(alloc, "GHOZTTY_DEBUG_DRAG_CURSOR_FILE") catch null;
    }
    self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
        self.destroy();
        return null;
    };
    return self;
}

/// Window thread: stop the thread, wait for it, and drop everything it held.
/// Returns its stats for the drag line.
pub fn stop(self: *CompDragThread) comp_drag.ThreadStats {
    self.stopping.store(true, .release);
    if (self.wake) |e| _ = w32.SetEvent(e);
    if (self.thread) |t| t.join();
    self.thread = null;
    const st = self.stats;
    self.destroy();
    return st;
}

fn destroy(self: *CompDragThread) void {
    for (self.panes[0..self.n]) |p| p.releaseAll();
    self.n = 0;
    chrome_comp.releaseObj(self.dcomp);
    if (self.wake) |e| _ = w32.CloseHandle(e);
    if (self.cursor_file) |f| self.alloc.free(f);
    self.alloc.destroy(self);
}

pub fn acquire(self: *CompDragThread) void {
    self.lock.lock();
    self.owner.store(w32.GetCurrentThreadId(), .release);
}

pub fn release(self: *CompDragThread) void {
    self.owner.store(0, .release);
    self.lock.unlock();
}

/// The debug assertion: the calling thread holds the device lock.
pub fn lockedByMe(self: *CompDragThread) bool {
    return self.owner.load(.acquire) == w32.GetCurrentThreadId();
}

/// Window thread, holding the lock: replace the model with `panes` at `p`.
/// The thread's references move with it: new ones are taken before the old
/// ones go, so a visual in both is never freed in between.
pub fn publish(self: *CompDragThread, p: Publish, panes: []const Pane) void {
    std.debug.assert(self.lockedByMe());
    const n = @min(panes.len, max_panes);
    for (panes[0..n]) |pn| pn.retain();
    for (self.panes[0..self.n]) |old| old.releaseAll();
    @memcpy(self.panes[0..n], panes[0..n]);
    self.n = n;
    self.axis = p.axis;
    self.base = p.base;
    var models: [max_panes]comp_drag.PaneModel = undefined;
    for (self.panes[0..n], 0..) |pn, i| models[i] = pn.model;
    self.limits = comp_drag.travelLimits(models[0..n], p.min);
    self.gen +%= 1;
    // The window thread just wrote these poses itself: travel 0 is on screen.
    self.written_gen = self.gen;
    self.written_d = 0;
}

/// Window thread, holding the lock: it just wrote a dragged visual outside a
/// publish (the layout pass placing it over its window), so what the thread
/// last wrote is no longer on screen and its next tick writes again.
pub fn invalidate(self: *CompDragThread) void {
    std.debug.assert(self.lockedByMe());
    self.written_gen = 0;
}

/// A `Pane` from the surface's view of it, classified against the gutter.
pub fn pane(vis: chrome_comp.Obj, rounded: ?chrome_comp.Obj, shadow: ?chrome_comp.Obj, sdx: f32, sdy: f32, model: comp_drag.PaneModel) Pane {
    return .{ .vis = vis, .rounded = rounded, .shadow = shadow, .sdx = sdx, .sdy = sdy, .model = model };
}

fn run(self: *CompDragThread) void {
    while (!self.stopping.load(.acquire)) {
        if (!self.waitTick()) continue;
        if (self.stopping.load(.acquire)) break;
        self.tick();
    }
}

/// Block until the next compositor frame. False when woken to stop.
fn waitTick(self: *CompDragThread) bool {
    const e = self.wake orelse {
        _ = w32.DwmFlush();
        return true;
    };
    const handles = [_]w32.HANDLE{e};
    if (self.wait_clock) |wait| {
        const r = wait(1, &handles, 50);
        if (r == w32.WAIT_OBJECT_0) return false;
        if (r == w32.WAIT_OBJECT_0 + 1 or r == w32.WAIT_TIMEOUT) return true;
        // The compositor clock failed (an occluded desktop): DwmFlush for
        // the rest of the drag.
        self.wait_clock = null;
    }
    // DwmFlush returns at once on a desktop with nothing to compose; a short
    // sleep keeps that from spinning.
    const t0 = std.time.Instant.now() catch null;
    _ = w32.DwmFlush();
    if (t0) |a| if (std.time.Instant.now()) |b| {
        if (b.since(a) < std.time.ns_per_ms) std.Thread.sleep(8 * std.time.ns_per_ms);
    } else |_| {};
    return true;
}

fn cursor(self: *CompDragThread) ?w32.POINT {
    if (self.cursor_file) |path| return readCursorFile(path);
    var pt: w32.POINT = undefined;
    if (w32.GetCursorPos_(&pt) == 0) return null;
    return pt;
}

fn readCursorFile(path: []const u8) ?w32.POINT {
    var buf: [64]u8 = undefined;
    const text = std.fs.cwd().readFile(path, &buf) catch return null;
    var it = std.mem.tokenizeAny(u8, text, " \r\n\t");
    const xs = it.next() orelse return null;
    const ys = it.next() orelse return null;
    const x = std.fmt.parseInt(i32, xs, 10) catch return null;
    const y = std.fmt.parseInt(i32, ys, 10) catch return null;
    return .{ .x = x, .y = y };
}

fn tick(self: *CompDragThread) void {
    const in_stall = stalled.load(.acquire);
    const t0 = std.time.Instant.now() catch return;
    const pt = self.cursor() orelse {
        if (in_stall) self.stats.stall_nocursor +|= 1;
        return;
    };
    self.acquire();
    defer self.release();
    self.stats.ticks +|= 1;
    if (in_stall) self.stats.ticks_in_stall +|= 1;
    if (self.dead or self.n == 0) {
        if (in_stall) {
            if (self.dead) self.stats.stall_dead +|= 1 else self.stats.stall_empty +|= 1;
        }
        return;
    }
    const along: i32 = switch (self.axis) {
        .x => pt.x,
        .y => pt.y,
    };
    const raw: f32 = @floatFromInt(along - self.base);
    const d = comp_drag.clampTravel(raw, self.limits);
    if (self.written_gen == self.gen and self.written_d == d) {
        if (in_stall) self.stats.stall_same +|= 1;
        return;
    }
    for (self.panes[0..self.n]) |p| {
        if (!p.model.moves()) continue;
        const pose = comp_drag.poseAt(p.model, self.axis, d);
        if (!chrome_comp.writePose(p.vis, p.rounded, pose, p.shadow, p.sdx, p.sdy)) {
            self.dead = true;
            log.warn("drag composition thread: a write failed; the window thread carries the drag", .{});
            return;
        }
    }
    const hr = chrome_comp.commitDevice(self.dcomp);
    if (hr < 0) {
        // The window thread draws its chrome surfaces (BeginDraw..EndDraw)
        // outside this lock, and a Commit landing inside one is refused with
        // SURFACE_BEING_RENDERED. The device is fine: the poses just set ride
        // the next Commit, and the next tick writes again. Anything else - or
        // a refusal that never clears - hands the drag back for good.
        if (hr == chrome_comp.dcomp_surface_being_rendered and self.commit_refusals < max_commit_refusals) {
            self.commit_refusals += 1;
            self.stats.commit_retries +|= 1;
            return;
        }
        self.dead = true;
        log.warn("drag composition thread: a commit failed hr=0x{x:0>8}; the window thread carries the drag", .{chrome_comp.hex(hr)});
        return;
    }
    self.commit_refusals = 0;
    self.written_gen = self.gen;
    self.written_d = d;
    const lag: u32 = if (std.time.Instant.now()) |t1| @intCast(@min(t1.since(t0) / std.time.ns_per_us, std.math.maxInt(u32))) else |_| 0;
    self.stats.recordWrite(lag, in_stall, d != raw);
}

/// `GHOZTTY_DEBUG_DRAG_STALL_MS=<n>` (debug builds): block the window thread
/// for n ms - with `stalled` up - the first time a drag reaches its 6th move.
pub fn debugStall(move_index: u32) void {
    if (comptime builtin.mode != .Debug) return;
    if (move_index != 6) return;
    const S = struct {
        var ms: ?u32 = null;
    };
    const ms = S.ms orelse blk: {
        const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "GHOZTTY_DEBUG_DRAG_STALL_MS") catch {
            S.ms = 0;
            break :blk 0;
        };
        defer std.heap.page_allocator.free(raw);
        const v = std.fmt.parseInt(u32, raw, 10) catch 0;
        S.ms = @min(v, 10_000);
        break :blk S.ms.?;
    };
    if (ms == 0) return;
    log.info("drag debug stall ms={d}", .{ms});
    stalled.store(true, .release);
    std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
    stalled.store(false, .release);
}
