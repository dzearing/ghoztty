//! The parked-thread pool for a viewer pane's short-lived workers (T2671).
//!
//! T2644 found that on the NVIDIA OpenGL driver every thread the process
//! creates while a GL context is alive costs about 64 KB that the driver never
//! gives back (`nvoglv64!DllMain` on DLL_THREAD_ATTACH). T2644 moved the three
//! threads every terminal pane spawns onto `reusable_thread` pools. A viewer
//! pane still created and exited three of its own per window: the file
//! watcher's `ReadDirectoryChangesW` loop (`viewer_watcher.zig`), the worktree
//! probe (`ViewerWorktreeProbe.zig`), and the `git` deadline watchdog that
//! probe starts (`git_run.zig`). A thread census of the window-close meter
//! named exactly those three, at the measured ~0.3 MB a closed window. The
//! diff probe (`ViewerDiffProbe.zig`) is the same shape, so it runs here too.
//!
//! So they run on parked threads instead. `join` waits for the job, not for
//! the OS thread, which parks for the next viewer. One pool serves all of them:
//! the jobs are short or end with their pane, and the pool grows to the most
//! that were ever running at once.
const std = @import("std");
const reusable_thread = @import("../../os/main.zig").reusable_thread;

/// The handle a worker field holds: `join` waits for the job to return.
pub const Thread = reusable_thread.PaneThread;

var pool: reusable_thread.Pool = .{ .name = "viewer-worker" };

/// Run `f(args...)` on a parked worker thread (a new one when none is idle).
pub fn spawn(comptime f: anytype, args: anytype) std.Thread.SpawnError!Thread {
    return reusable_thread.spawnPane(&pool, f, args);
}

/// OS threads the pool has ever created. Tests read it.
pub fn created() u32 {
    pool.mutex.lock();
    defer pool.mutex.unlock();
    return pool.created;
}

test "a second job reuses the first job's parked thread" {
    const S = struct {
        fn noop() void {}
    };
    // Warm: make sure at least one worker exists and is parked.
    (try spawn(S.noop, .{})).join();
    const before = created();
    for (0..8) |_| (try spawn(S.noop, .{})).join();
    try std.testing.expectEqual(before, created());
}
