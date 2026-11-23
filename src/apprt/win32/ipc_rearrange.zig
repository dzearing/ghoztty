//! `+rearrange` for the win32 apprt (T1782, split from IpcHandlers.zig):
//! replace a window's active-tab split tree with a JSON layout, keeping
//! stashed panes and leaving an undo (T2234).
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

const PaneView = @import("PaneView.zig");
const Window = @import("Window.zig");
const LayoutUndo = @import("LayoutUndo.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree(PaneView);
const pane_stash = @import("pane_stash.zig");

const missingResponse = IpcHandlers.missingResponse;
const callerAnchorPaneView = IpcHandlers.callerAnchorPaneView;
const frontWindow = IpcHandlers.frontWindow;

pub fn handleRearrange(ctx: Context, request: Request) Allocator.Error!?[]u8 {
    const app = ctx.app;

    var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseVerbArgs(arena, request.arguments);
    const layout_json = args.layout orelse
        return try errorResponse(ctx.alloc, "--layout is required for +rearrange", .{});

    const layout = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        layout_json,
        .{},
    ) catch return try errorResponse(ctx.alloc, "invalid layout JSON", .{});

    // Validate shape + collect pane names (Mac collectPaneNames semantics).
    var names: std.ArrayList([]const u8) = .empty;
    if (try verb_args.validateLayout(arena, layout, &names)) |msg|
        return try errorResponse(ctx.alloc, "{s}", .{msg});
    if (names.items.len == 0)
        return try errorResponse(ctx.alloc, "layout must contain at least one pane", .{});
    if (verb_args.firstDuplicate(names.items)) |dupe|
        return try errorResponse(ctx.alloc, "duplicate pane name in layout: '{s}'", .{dupe});

    // Resolve the window, then every pane against its ACTIVE tab's tree.
    const window: *Window = if (args.target) |target| window: {
        const entry = app.ipcLookup(target) orelse
            return try missingResponse(ctx, target, "target window '{s}' not found", .{target});
        break :window switch (entry) {
            .window => |w| w,
            .pane => |pane| pane.parentWindow(),
        };
    } else if (callerAnchorPaneView(app, args)) |caller|
        // T1079: "rearrange this window" means the caller's window, not
        // whichever one the user has clicked into since. Same race as `+split`,
        // same fix; the layout names panes that live in a particular window, so
        // the focused-window guess made the command FAIL outright as often as
        // it moved the wrong one.
        caller.parentWindow()
    else
        frontWindow(app) orelse
            return try errorResponse(ctx.alloc, "no focused window found", .{});
    if (window.tab_count == 0)
        return try errorResponse(ctx.alloc, "no focused window found", .{});
    const tab = window.active_tab;
    const tree = &window.tab_trees[tab];

    var surfaces: std.StringHashMapUnmanaged(*PaneView) = .empty;
    for (names.items) |name| {
        const entry = app.ipcLookup(name) orelse
            return try missingResponse(ctx, name, "pane '{s}' not found in registry", .{name});
        const pane = switch (entry) {
            .pane => |p| p,
            .window => return try errorResponse(ctx.alloc, "pane '{s}' not found in registry", .{name}),
        };
        const in_tree = in_tree: {
            var it = tree.iterator();
            while (it.next()) |view_entry| {
                if (view_entry.view == pane) break :in_tree true;
            }
            break :in_tree false;
        };
        if (!in_tree)
            return try errorResponse(ctx.alloc, "pane '{s}' is not in the target window", .{name});
        try surfaces.put(arena, name, pane);
    }

    // The layout as it stands, for the undo (T2234): captured before any
    // stash mark below changes, so an undo stashes again what was stashed.
    var before = try LayoutUndo.capture(ctx.alloc, tree);
    var before_owned = true;
    defer if (before_owned) before.deinit(ctx.alloc);

    // Build the replacement tree in its own arena (SplitTree owns it). The
    // nodes borrow the kept panes; `clone` takes the new tree's references.
    const gpa = ctx.alloc;
    var tree_arena = std.heap.ArenaAllocator.init(gpa);
    defer tree_arena.deinit();
    var nodes: std.ArrayList(SplitTree.Node) = .empty;
    _ = try buildLayoutNode(tree_arena.allocator(), &nodes, layout, &surfaces);
    const borrowed: SplitTree = .{ .arena = tree_arena, .nodes = nodes.items, .zoomed = null };
    var new_tree = try borrowed.clone(gpa);
    var new_tree_owned = true;
    defer if (new_tree_owned) new_tree.deinit();

    // T1827 (Mac `handleRearrange`): a STASHED pane the layout leaves out
    // stays stashed - the layout describes the grid, and a stash is not part
    // of it. Without this it would be left out like any omitted pane: a close
    // the user never asked for, of a pane they could not even see. It is
    // carried into the new tree at the top level, right of the layout so the
    // layout's own first leaf stays first for the focus pick, where it is
    // hidden anyway; one the layout DOES place comes back on screen.
    {
        var it = tree.iterator();
        while (it.next()) |view_entry| {
            const view = view_entry.view;
            if (!pane_stash.isStashed(view)) continue;
            const placed = placed: {
                var kept = surfaces.valueIterator();
                while (kept.next()) |pane_ptr| {
                    if (pane_ptr.* == view) break :placed true;
                }
                break :placed false;
            };
            if (placed) continue;
            var leaf = try SplitTree.init(gpa, view);
            defer leaf.deinit();
            const next = try new_tree.insertAtTopLevel(gpa, .right, 0.5, &leaf);
            new_tree.deinit();
            new_tree = next;
        }
    }

    // Allocate the success response up front: `apply` takes the trees over.
    const response = try ctx.alloc.dupe(u8, "{\"success\":true}");
    errdefer ctx.alloc.free(response);

    // Bring the placed stashed panes back on screen. Only now, with nothing
    // left to fail before the swap but `apply`'s own allocations.
    {
        var kept = surfaces.valueIterator();
        while (kept.next()) |pane_ptr| pane_stash.unmark(pane_ptr.*);
    }

    // Swap, ending or parking (T2234) the panes the layout left out, and
    // re-persist (T110). T128's session rules live there too, shared with a
    // redo of this rearrange.
    new_tree_owned = false;
    before_owned = false;
    try LayoutUndo.apply(app, window, tab, new_tree, before);

    return response;
}

/// Append the nodes for `layout` (validated by verb_args.validateLayout)
/// preorder, so the root lands at index 0. Returns the node's handle.
fn buildLayoutNode(
    arena: Allocator,
    nodes: *std.ArrayList(SplitTree.Node),
    node: std.json.Value,
    surfaces: *const std.StringHashMapUnmanaged(*PaneView),
) Allocator.Error!SplitTree.Node.Handle {
    const handle: SplitTree.Node.Handle = @enumFromInt(nodes.items.len);
    try nodes.append(arena, undefined);
    const obj = node.object;

    if (obj.get("pane")) |pane| {
        nodes.items[handle.idx()] = .{ .leaf = surfaces.get(pane.string).? };
        return handle;
    }

    // Ratio arrives as a percent (default 50), clamped like the Mac.
    const ratio_percent: f64 = switch (obj.get("ratio") orelse std.json.Value{ .float = 50 }) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => 50,
    };
    const ratio: f16 = @floatCast(@min(0.9, @max(0.1, ratio_percent / 100.0)));
    const layout: SplitTree.Split.Layout = if (std.ascii.eqlIgnoreCase(
        obj.get("direction").?.string,
        "horizontal",
    )) .horizontal else .vertical;

    const left = try buildLayoutNode(arena, nodes, obj.get("left").?, surfaces);
    const right = try buildLayoutNode(arena, nodes, obj.get("right").?, surfaces);
    nodes.items[handle.idx()] = .{ .split = .{
        .layout = layout,
        .ratio = ratio,
        .left = left,
        .right = right,
    } };
    return handle;
}
