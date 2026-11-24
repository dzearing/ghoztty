//! `+stash` / `+restore` for the GTK apprt (T3596): win32's `ipc_stash.zig`
//! (T1827) over the GTK split tree. Mac `handleStash`'s refusal strings, byte
//! for byte, as win32 has them.
//!
//! A stashed pane leaves its window's LAYOUT and stays in its tab's TREE
//! (`SplitTree.stashSurface`): its shell keeps running, every verb still
//! reaches it, and `+list` reports it with `stashed: true`. `+restore` puts it
//! back in the slot it left; like every verb it leaves focus alone unless
//! given `--focus`. Both are idempotent.
const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const server = apprt.ipc.server;
const Request = server.Request;
const verb_args = apprt.ipc.args;

const IpcHandlers = @import("IpcHandlers.zig");
const Context = IpcHandlers.Context;

const log = std.log.scoped(.gtk_ipc);

const c_alloc = std.heap.c_allocator;

pub fn stashOrRestore(app: Context, request: Request, restore: bool) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(c_alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const verb = if (restore) "+restore" else "+stash";
    const args = try verb_args.parseVerbArgs(arena, request.arguments);
    const target = args.target orelse
        return try server.errorResponse(c_alloc, "--target is required for {s}", .{verb});

    const resolved = try IpcHandlers.resolve(arena, app, target);
    const found = switch (resolved) {
        .found => |t| t,
        else => return try IpcHandlers.missingResponse(arena, resolved, target, "target '{s}' not found in registry", .{target}),
    };
    const pane = switch (found) {
        .pane => |p| p,
        .window => return try server.errorResponse(
            c_alloc,
            "target '{s}' is a window; {s} takes a pane (a name or pane id)",
            .{ target, verb },
        ),
    };
    // The Quick Terminal has no pane sidebar, so a pane stashed in it would
    // have nowhere to be seen or brought back from (Mac refuses here too).
    if (pane.window.isQuickTerminal()) return try server.errorResponse(
        c_alloc,
        "target '{s}' is in the Quick Terminal, which has no pane sidebar",
        .{target},
    );
    const tab = IpcHandlers.tabOf(pane.window, pane.surface) orelse
        return try server.errorResponse(c_alloc, "target '{s}' is not in its window's layout", .{target});
    const tree = tab.getSplitTree();

    if (restore) {
        _ = tree.restoreSurface(pane.surface, false);
        if (args.focus) IpcHandlers.focusTarget(found);
        log.info("IPC: restored '{s}'", .{target});
        return try c_alloc.dupe(u8, "{\"success\":true}");
    }

    tree.stashSurface(pane.surface) catch |err| return switch (err) {
        error.LastVisiblePane => try server.errorResponse(
            c_alloc,
            "target '{s}' is the last pane on screen in its window; a window always shows at least one pane",
            .{target},
        ),
        error.NotInTree => try server.errorResponse(
            c_alloc,
            "target '{s}' is not in its window's layout",
            .{target},
        ),
    };
    log.info("IPC: stashed '{s}'", .{target});
    return try c_alloc.dupe(u8, "{\"success\":true}");
}
