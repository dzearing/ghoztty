//! `+stash` / `+restore` for the win32 apprt (T1782, split from
//! IpcHandlers.zig).
const std = @import("std");
const Allocator = std.mem.Allocator;

const IpcHandlers = @import("IpcHandlers.zig");
const Context = IpcHandlers.Context;
const apprt = @import("../../apprt.zig");
const ipc_server = apprt.ipc.server;
const Request = ipc_server.Request;
const errorResponse = ipc_server.errorResponse;
const nonEmpty = ipc_server.nonEmpty;
const verb_args = apprt.ipc.args;
const parseVerbArgs = verb_args.parseVerbArgs;

const missingResponse = IpcHandlers.missingResponse;
const focusTarget = IpcHandlers.focusTarget;

const log = std.log.scoped(.win32_ipc);

/// `+stash` / `+restore` (T1827, Mac `handleStash`): move a pane out of its
/// window's layout, or back. Both idempotent, like every IPC verb, and -
/// like every one - `+restore` leaves focus alone unless given `--focus`.
/// The refusal strings are Mac's, byte for byte.
pub fn stashOrRestore(ctx: Context, request: Request, restore: bool) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const verb = if (restore) "+restore" else "+stash";
    const args = try parseVerbArgs(arena, request.arguments);
    const target = args.target orelse
        return try errorResponse(ctx.alloc, "--target is required for {s}", .{verb});

    const entry = ctx.app.ipcLookup(target) orelse
        return try missingResponse(ctx, target, "target '{s}' not found in registry", .{target});
    const pane = switch (entry) {
        .pane => |p| p,
        .window => return try errorResponse(
            ctx.alloc,
            "target '{s}' is a window; {s} takes a pane (a name or pane id)",
            .{ target, verb },
        ),
    };
    // The window that holds the pane NOW, not the one it registered in: a
    // pane dragged between windows moved its back-pointer with it (T1538).
    const window = pane.parentWindow();
    if (window.is_quick_terminal) return try errorResponse(
        ctx.alloc,
        "target '{s}' is in the Quick Terminal, which has no pane sidebar",
        .{target},
    );

    if (restore) {
        window.restorePane(pane, false);
        if (args.focus) focusTarget(entry);
        log.info("IPC: restored '{s}'", .{target});
        return try ctx.alloc.dupe(u8, "{\"success\":true}");
    }

    window.stashPane(pane) catch |err| return switch (err) {
        error.LastVisiblePane => try errorResponse(
            ctx.alloc,
            "target '{s}' is the last pane on screen in its window; a window always shows at least one pane",
            .{target},
        ),
        error.NotInTree => try errorResponse(
            ctx.alloc,
            "target '{s}' is not in its window's layout",
            .{target},
        ),
        error.QuickTerminal => try errorResponse(
            ctx.alloc,
            "target '{s}' is in the Quick Terminal, which has no pane sidebar",
            .{target},
        ),
    };
    log.info("IPC: stashed '{s}'", .{target});
    return try ctx.alloc.dupe(u8, "{\"success\":true}");
}
