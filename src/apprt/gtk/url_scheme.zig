//! The GTK half of the `ghoztty://` URL scheme (T3343, Linux L14) - the Linux
//! counterpart of the Mac's `GhozttyURLScheme.swift` and win32's
//! `url_scheme.zig`. The grammar, the one-verb threat model (focus an
//! existing window or pane, NOTHING else) and the failure wording are shared:
//! `apprt/ipc/url_scheme.zig`. The pure decisions this half adds are in
//! `url_activation.zig`.
//!
//! ## Registration
//!
//! The installed `.desktop` file (`dist/linux/app.desktop.in`) carries
//! `MimeType=x-scheme-handler/ghoztty;` (a debug build: `ghoztty-debug`, so a
//! dev build never takes the user's links), and `scripts/linux/install.sh`
//! makes it the default handler (`xdg-mime default`). Nothing registers at
//! launch: on Linux a scheme belongs to an installed desktop entry, unlike
//! win32's HKCU self-registration.
//!
//! ## Two ways a link arrives, one answer
//!
//! 1. **D-Bus `Open`** (`openInApp`). The desktop file is `DBusActivatable`,
//!    so GIO-based launchers (`gio open`, a browser through the portal, GNOME)
//!    call `org.freedesktop.Application.Open` on the running app, which GLib
//!    hands to `GApplication::open` (`Application.open`). The focus runs in
//!    process through the same `verbs.focus` the IPC socket uses.
//! 2. **The `Exec` line** (`runActivation`). Launchers that do not speak D-Bus
//!    run `ghoztty ... <url>`. That process is not a terminal, exactly as on
//!    win32: it decodes the link, forwards a `focus` to the running instance
//!    over the IPC socket, shows anything that went wrong and exits with
//!    win32's codes. A cold click (no instance) is "nothing has that name":
//!    the one scheme that must never create anything does not launch a
//!    terminal to answer it.
//!
//! ## Failure
//!
//! A link that resolves to nothing says so in an `AdwAlertDialog` (the shared
//! `Failure` wording), coalesced: in process by a flag, across activation
//! processes by an `flock` in the runtime dir - each click through `Exec` is
//! its own process, the case win32's named mutex covers. Nothing is ever
//! created or focused as a consolation.
//!
//! `GHOZTTY_URL_SCHEME_QUIET=1` logs instead of showing (win32's switch). A
//! debug build with `GHOZTTY_TEST_URL_SCHEME_DIALOG=<file>` appends
//! `shown <title>|<body>` once the dialog is up and closes it after a moment,
//! so the headless harness can prove the dialog path without input.
const std = @import("std");
const builtin = @import("builtin");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../apprt.zig");
const build_config = @import("../../build_config.zig");
const internal_os = @import("../../os/main.zig");
const logic = @import("url_activation.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const Application = @import("class/application.zig").Application;

const grammar = apprt.ipc.url_scheme;
const verbs = apprt.ipc.verbs;

const log = std.log.scoped(.gtk_url_scheme);

// ---------------------------------------------------------------------------
// 1. In process: GApplication::open
// ---------------------------------------------------------------------------

/// Focus what a link handed to the running app names (D-Bus `Open`). A URI
/// that is not ours is ignored silently - nobody clicked a Ghoztty link.
pub fn openInApp(app: *Application, url: []const u8) void {
    if (!grammar.handles(url)) {
        log.info("open: not a ghoztty link, ignored: {s}", .{url});
        return;
    }
    var name_buf: [logic.max_target]u8 = undefined;
    const cmd = grammar.parse(url, &name_buf) orelse {
        log.info("open: unsupported link {s}", .{url});
        return present(.{ .unsupported_link = url }, app);
    };
    switch (cmd) {
        .focus => |name| {
            var arg_buf: [logic.max_target + 16]u8 = undefined;
            const arg = std.fmt.bufPrint(&arg_buf, "--target={s}", .{name}) catch
                return present(.{ .unsupported_link = url }, app);
            const argv = [_][]const u8{arg};
            const reply = verbs.focus(IpcHandlers, app, .{
                .action = "focus",
                .arguments = &argv,
            }) catch return;
            const r = reply orelse return;
            defer IpcHandlers.replyAllocator(app).free(r);
            const outcome = logic.replyOutcome(r);
            log.info("open: focus '{s}': {s}", .{ name, @tagName(outcome) });
            if (logic.failureFor(outcome, name)) |f| present(f, app);
        },
    }
}

var presenting = false;

/// Show a failure over the app's active window (or on its own when there is
/// none). One at a time: a burst of links is one dialog.
fn present(failure: grammar.Failure, app: *Application) void {
    if (quiet() or presenting) return logFailure(failure);
    const parent: ?*gtk.Widget = if (app.as(gtk.Application).getActiveWindow()) |w|
        w.as(gtk.Widget)
    else
        null;
    const dialog = makeDialog(failure) orelse return logFailure(failure);
    presenting = true;
    dialog.choose(parent, null, inAppDone, null);
    afterShown(failure, dialog);
}

fn inAppDone(_: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
    _ = ud;
    _ = result;
    presenting = false;
}

// ---------------------------------------------------------------------------
// 2. The activation process: `ghoztty <url>` from the Exec line
// ---------------------------------------------------------------------------

/// Handle a `ghoztty://` link on this process's command line, or null when
/// there is none (an ordinary launch). Called by `main_ghostty` before any
/// app or single-instance setup, through `App.runUrlSchemeActivation`.
pub fn runActivation(alloc: std.mem.Allocator) ?u8 {
    const args = std.process.argsAlloc(alloc) catch return null;
    defer std.process.argsFree(alloc, args);
    const url = logic.urlArg(args) orelse return null;
    return handleActivation(alloc, url);
}

fn handleActivation(alloc: std.mem.Allocator, url: []const u8) u8 {
    var target_buf: [logic.max_target]u8 = undefined;
    const cmd = grammar.parse(url, &target_buf) orelse {
        log.info("url scheme: unsupported link {s}", .{url});
        presentStandalone(.{ .unsupported_link = url });
        return logic.exit_unsupported;
    };
    switch (cmd) {
        .focus => |target| {
            const arg = std.fmt.allocPrintSentinel(alloc, "--target={s}", .{target}, 0) catch
                return logic.exit_not_found;
            defer alloc.free(arg);
            const ok = internal_os.ipc_client.sendAction(alloc, "focus", &.{arg}) catch |err| miss: {
                // No running instance is the cold-click case: nothing is
                // open by that name. Launching the app to answer would be
                // window creation from the scheme that must never create.
                log.info("url scheme: focus '{s}' failed: {}", .{ target, err });
                break :miss false;
            };
            if (!ok) {
                presentStandalone(.{ .target_not_found = target });
                return logic.exit_not_found;
            }
            log.info("url scheme: focused '{s}'", .{target});
            return logic.exit_focused;
        },
    }
}

/// The activation process's dialog: GTK is not up yet, so bring up just
/// enough of it for one `AdwAlertDialog` and run until it is dismissed.
fn presentStandalone(failure: grammar.Failure) void {
    if (quiet()) return logFailure(failure);
    const lock = burstLock() orelse return logFailure(failure);
    defer std.posix.close(lock);
    if (gtk.initCheck() == 0) return logFailure(failure);
    adw.init();
    const dialog = makeDialog(failure) orelse return logFailure(failure);
    var done = false;
    dialog.choose(null, null, standaloneDone, &done);
    afterShown(failure, dialog);
    const ctx = glib.MainContext.default();
    while (!done) _ = glib.MainContext.iteration(ctx, 1);
}

fn standaloneDone(_: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
    _ = result;
    const done: *bool = @ptrCast(@alignCast(ud));
    done.* = true;
}

/// An exclusive `flock` on `<runtime dir>/ghoztty[-debug]-url-warning.lock`,
/// or null when another activation process already holds it (it owns the
/// dialog; this click exits quietly with the same code).
fn burstLock() ?std.posix.fd_t {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse std.posix.getenv("TMPDIR") orelse "/tmp";
    const suffix = if (build_config.is_debug) "-debug" else "";
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/ghoztty{s}-url-warning.lock", .{ dir, suffix }) catch return null;
    const fd = std.posix.openZ(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600) catch return null;
    std.posix.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) catch {
        std.posix.close(fd);
        return null;
    };
    return fd;
}

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------

fn makeDialog(failure: grammar.Failure) ?*adw.AlertDialog {
    var title_buf: [logic.max_target + 64]u8 = undefined;
    var body_buf: [logic.max_target + 256]u8 = undefined;
    var title_z: [logic.max_target + 65]u8 = undefined;
    var body_z: [logic.max_target + 257]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_z, "{s}", .{failure.title(&title_buf)}) catch return null;
    const body = std.fmt.bufPrintZ(&body_z, "{s}", .{failure.body(&body_buf)}) catch return null;
    const dialog = adw.AlertDialog.new(title.ptr, body.ptr);
    dialog.addResponse("ok", "OK");
    dialog.setDefaultResponse("ok");
    dialog.setCloseResponse("ok");
    return dialog;
}

/// The debug-only test seam: record that the dialog is up and close it a
/// moment later, so a headless run proves the path without a keyboard.
fn afterShown(failure: grammar.Failure, dialog: *adw.AlertDialog) void {
    if (comptime builtin.mode != .Debug) return;
    const path = std.posix.getenv("GHOZTTY_TEST_URL_SCHEME_DIALOG") orelse return;
    var title_buf: [logic.max_target + 64]u8 = undefined;
    var body_buf: [logic.max_target + 256]u8 = undefined;
    if (std.fs.cwd().createFile(path, .{ .truncate = false })) |file| {
        defer file.close();
        file.seekFromEnd(0) catch {};
        var line_buf: [2048]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "shown {s}|{s}\n", .{
            failure.title(&title_buf),
            failure.body(&body_buf),
        }) catch return;
        file.writeAll(line) catch {};
    } else |_| {}
    _ = glib.timeoutAdd(500, closeDialog, dialog);
}

fn closeDialog(ud: ?*anyopaque) callconv(.c) c_int {
    const dialog: *adw.AlertDialog = @ptrCast(@alignCast(ud));
    _ = dialog.as(adw.Dialog).close();
    return 0;
}

fn quiet() bool {
    const v = std.posix.getenv("GHOZTTY_URL_SCHEME_QUIET") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

fn logFailure(failure: grammar.Failure) void {
    var title_buf: [logic.max_target + 64]u8 = undefined;
    var body_buf: [logic.max_target + 256]u8 = undefined;
    log.warn("url scheme: {s} - {s}", .{ failure.title(&title_buf), failure.body(&body_buf) });
}
