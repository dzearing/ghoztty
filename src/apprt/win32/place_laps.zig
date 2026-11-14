//! The stretches of a 4K fold-glide tick's placement pass (T2953), and
//! which one spent the most time off the CPU. A slow pass ran ~15 ms of
//! wall with 5-10 ms of it neither computing nor in a desk blit; timing each
//! stretch with the UI thread's own cycles names the call that waited.
//! `stall_probe.zig` takes the laps; this is the arithmetic, no OS imports.
const std = @import("std");

/// The stretches of a glide tick's placement pass (T2953), in the order the
/// pass runs them. `placeLap(p)` charges the time since the previous lap to
/// `p`, so a slow pass names the stretch its off-CPU time went into.
pub const Phase = enum(u8) {
    /// Snapshot, present gate, batch begin and the stack plan.
    plan,
    /// `placeGrid`: every pane's `DeferWindowPos`.
    defer_pos,
    /// `EndDeferWindowPos`, with each pane's `WM_SIZE` fill inside it.
    end_defer,
    /// The card regions cut inside a live batch.
    cut_in_batch,
    /// The held terminal resizes (`applyResize`).
    apply,
    /// The held viewers' bounds sync.
    viewers,
    /// The strip faces committed ahead of the desk fill.
    faces,
    /// The card regions cut after the batch.
    cut,
    /// Overlays ahead of the bands, and the vacated strips cleared.
    clear,
};
pub const phase_count = @typeInfo(Phase).@"enum".fields.len;

/// One phase's share of the tick: wall and the UI thread's CPU in it.
pub const PhaseCost = struct { wall_us: i64 = 0, cpu_us: i64 = 0 };

/// The phase that spent the most wall time off the CPU, and that time.
pub fn worstOffCpu(costs: []const PhaseCost) struct { phase: Phase, off_us: i64 } {
    var best: usize = 0;
    var best_off: i64 = std.math.minInt(i64);
    for (costs, 0..) |c, i| {
        const off = c.wall_us - c.cpu_us;
        if (off > best_off) {
            best_off = off;
            best = i;
        }
    }
    return .{ .phase = @enumFromInt(best), .off_us = @max(best_off, 0) };
}

test "worstOffCpu names the phase with the most wall over cpu" {
    var c: [phase_count]PhaseCost = @splat(.{});
    c[@intFromEnum(Phase.defer_pos)] = .{ .wall_us = 3000, .cpu_us = 2900 };
    c[@intFromEnum(Phase.end_defer)] = .{ .wall_us = 9000, .cpu_us = 2000 };
    c[@intFromEnum(Phase.apply)] = .{ .wall_us = 4000, .cpu_us = 500 };
    const w = worstOffCpu(&c);
    try std.testing.expectEqual(Phase.end_defer, w.phase);
    try std.testing.expectEqual(@as(i64, 7000), w.off_us);
}

test "worstOffCpu reports zero off-cpu when every phase ran" {
    var c: [phase_count]PhaseCost = @splat(.{});
    c[0] = .{ .wall_us = 100, .cpu_us = 120 };
    const w = worstOffCpu(&c);
    try std.testing.expectEqual(@as(i64, 0), w.off_us);
}
