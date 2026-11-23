/// This is the main entrypoint to the apprt for Ghostty. Ghostty will
/// initialize this in main to start the application..
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const internal_os = @import("../../os/main.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");

const Application = @import("class/application.zig").Application;
const Surface = @import("Surface.zig");
const ipcNewWindow = @import("ipc/new_window.zig").newWindow;
const IpcServer = @import("IpcServer.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const LocalAgent = @import("LocalAgent.zig");

const log = std.log.scoped(.gtk);

/// This is detected by the Renderer, in which case it sends a `redraw_surface`
/// message so that we can call `drawFrame` ourselves from the app thread,
/// because GTK's `GLArea` does not support drawing from a different thread.
pub const must_draw_from_app_thread = true;

/// GTK application ID
pub const application_id = @import("build/info.zig").application_id;

/// GTK object path
pub const object_path = @import("build/info.zig").object_path;

/// The GObject Application instance
app: *Application,

/// The CLI's Unix socket (T3335), while this instance serves it.
ipc_server: ?*IpcServer = null,

/// The local `ghoztty-agent` every persistent pane rides (T3337). Its
/// connection is deliberately never torn down at terminate: surfaces borrow
/// it and nothing refcounts it, and process exit closes the socket, which the
/// agent reads as a detach (the sessions survive for the next launch).
local_agent: LocalAgent = .init(std.heap.c_allocator),

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but we don't use it.
    opts: struct {},
) !void {
    _ = opts;

    const app: *Application = try .new(self, core_app);
    errdefer app.unref();
    self.* = .{ .app = app };
    return;
}

/// A `ghoztty://` link on the command line (the desktop file's `Exec ... %u`
/// line, T3343): forward a focus to the running instance, report a miss, and
/// exit with the code returned. Null for an ordinary launch. `main_ghostty`
/// asks this before any app setup, as it does win32's.
pub fn runUrlSchemeActivation(alloc: Allocator) ?u8 {
    return @import("url_scheme.zig").runActivation(alloc);
}

pub fn run(self: *App) !void {
    try self.app.run();
}

pub fn terminate(self: *App) void {
    // We force deinitialize the app. We don't unref because other things
    // tend to have a reference at this point, so this just forces the
    // disposal now.
    self.app.deinit();
}

/// Called by CoreApp to wake up the event loop.
pub fn wakeup(self: *App) void {
    self.app.wakeup();
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    return try self.app.performAction(target, action, value);
}

/// Send the given IPC to a running Ghostty. Returns `true` if the action was
/// able to be performed, `false` otherwise.
///
/// Note that this is a static function. Since this is called from a CLI app (or
/// some other process that is not Ghostty) there is no full-featured apprt App
/// to use.
pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    // Ghoztty (T3330): every verb goes over the same Unix socket the Mac
    // uses (`apprt.ipc.socketPath()`), so the CLI surface is identical on all
    // three platforms. The GTK app serves it (`startIpc`, T3335); verbs it
    // does not serve yet answer a plain error naming T3336. The
    // upstream D-Bus `new-window` path (`ipcNewWindow`) is kept below for
    // the auto-launch work (T3336): its arguments are upstream's `-e` CLI
    // args, not Ghoztty's wire args, so it cannot carry `+new-window` as is.
    _ = target;
    return internal_os.ipc_client.sendAction(
        alloc,
        comptime action.wireName(),
        value.arguments,
    );
}

/// Start serving the CLI's Unix socket (T3335). Called once, from
/// `Application.run`, after GApplication registration says this process is
/// the primary instance and before the first window spawns a shell, so every
/// pane can be baked with the endpoint.
///
/// Never fatal: an app that cannot serve still runs, and says why.
pub fn startIpc(self: *App) void {
    // An app launched from ANOTHER instance's pane inherits that instance's
    // `$GHOZTTY_IPC_SOCKET`. It names someone else's socket, so drop it
    // before anything we spawn inherits it (win32 does the same, T118);
    // our own panes are baked with OUR endpoint explicitly.
    _ = internal_os.unsetenv(apprt.ipc.socket_env);

    const alloc = std.heap.c_allocator;
    const path = internal_os.ipc_client.endpointPath(alloc) catch {
        log.warn("IPC: out of memory deriving the socket path; the CLI cannot reach this app", .{});
        return;
    };
    defer alloc.free(path);

    self.ipc_server = IpcServer.start(alloc, path, IpcHandlers.serve, self.app) catch |err| {
        switch (err) {
            error.AlreadyServed => log.warn(
                "IPC: another instance already serves {s}; ghoztty +<verb> reaches that one, not this app",
                .{path},
            ),
            error.PathOccupied => log.warn(
                "IPC: {s} exists and is not a stale socket of ours; leaving it alone, so the CLI cannot reach this app",
                .{path},
            ),
            else => log.warn("IPC: cannot serve {s} err={}", .{ path, err }),
        }
        return;
    };
}

/// Stop serving the socket and remove it (T3335).
pub fn stopIpc(self: *App) void {
    const s = self.ipc_server orelse return;
    self.ipc_server = null;
    s.stop();
}

/// The socket this instance serves, for baking into each pane's
/// `$GHOZTTY_IPC_SOCKET`; null while it serves none.
pub fn ipcEndpoint(self: *App) ?[]const u8 {
    const s = self.ipc_server orelse return null;
    return s.path;
}

/// Redraw the inspector for the given surface.
pub fn redrawInspector(_: *App, surface: *Surface) void {
    surface.redrawInspector();
}
