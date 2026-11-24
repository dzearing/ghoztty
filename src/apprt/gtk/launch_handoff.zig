//! A launch of one Ghoztty build while ANOTHER build already runs (T3598):
//! the launch half of win32's handoff (`App.handOffOrTakeOver`, T1022/T1023/
//! T1070), on GTK. The server half - `handoff-quit` and the `+version` fields
//! a launch reads - is T3595 (`IpcHandlers.handleHandoffQuit`).
//!
//! Before this, a second build's launch on Linux found the socket served and
//! either joined over D-Bus (single instance) or ran beside the first one
//! (`--gtk-single-instance=false`), and nothing told the user that the window
//! they got - or the CLI their panes reach - belonged to another build. Now,
//! before GApplication registration, the launch asks the instance serving the
//! socket which build it is. The same build is joined silently, as before.
//! A different build is a question, worded by the shared
//! `ipc_handoff.mismatchPrompt`:
//!
//!   [Switch]       the running build quits (layout saved, agent panes
//!                  detached, T3595) and this launch starts in its place,
//!                  re-attaching them through its own launch restore;
//!   [Open Window]  the window opens in the running build (`+new-window`
//!                  carrying this launch's identity, `-e` and cwd); Enter;
//!   [Cancel]       nothing opens; Escape.
//!
//! Every failure falls toward the old behavior: no answer from the running
//! instance, a refused quit, or an endpoint that never comes free all end in
//! a join, and a join nobody answers starts this launch as it always did.
//!
//! `GHOZTTY_HANDOFF_PROMPT=join|switch` answers without asking (win32's
//! automation hook), and a debug build takes `GHOZTTY_HANDOFF_VERSION` /
//! `GHOZTTY_HANDOFF_COMMIT` as the identity this launch reports, so a test can
//! be "another build" with the one binary it has. A debug build with
//! `GHOZTTY_TEST_HANDOFF_DIALOG=<file>` appends `shown <title>|<buttons>|<text>`
//! once the dialog is up and ends it a moment later (Cancel), so the headless
//! harness proves the dialog path without a keyboard.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const internal_os = @import("../../os/main.zig");
const build_identity = @import("../ipc/build_identity.zig");
const rules = @import("launch_handoff_rules.zig");

const ipc_client = internal_os.ipc_client;
const ipc_handoff = internal_os.ipc_handoff;

const log = std.log.scoped(.gtk_handoff);

/// What `Application.run` does next.
pub const Outcome = enum {
    /// Register and start as usual: nobody else serves the socket, it is the
    /// same build, or this launch has just taken the socket over.
    start,
    /// Exit 0 now: the window opened in the running build, or the user
    /// cancelled.
    exit_ok,
    /// Exit 1 now: the running build refused the window.
    exit_failed,
};

/// Decide, before registration, what this launch does about an instance that
/// already serves the socket. Runs on the main thread with the default main
/// context acquired (the dialog iterates it).
pub fn decide(config: *const configpkg.Config) Outcome {
    // An app started from another instance's pane inherits that instance's
    // `$GHOZTTY_IPC_SOCKET`; the question is about the socket THIS launch
    // would serve, so drop it first (`startIpc` drops it too, T118).
    _ = internal_os.unsetenv(apprt.ipc.socket_env);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const running = ipc_client.queryIdentity(alloc) orelse return .start;
    var id = launchIdentity(alloc);
    const prompt = (ipc_handoff.mismatchPrompt(alloc, id, running.id, running.offer) catch
        return .start) orelse return .start;
    const layout = rules.Layout.of(prompt.ok_label, prompt.cancel_label, prompt.switch_label);
    log.warn("launch of a different build: launcher={s} running={s} pid={d} switch={}; asking", .{
        id.version, running.id.version, running.pid, layout.hasSwitch(),
    });

    const env_mode: ?[]const u8 = std.posix.getenv(rules.prompt_env);
    const choice = rules.scripted(env_mode, layout.hasSwitch()) orelse ask(prompt, layout);
    switch (choice) {
        .cancel => {
            log.info("launch cancelled: a different build serves the socket", .{});
            return .exit_ok;
        },
        .switch_build => {
            id.prompted = true;
            if (takeOver(alloc, id, running.pid)) return .start;
        },
        .join => id.prompted = true,
    }
    return join(alloc, config, id);
}

/// This process's build identity (win32's `launchIdentity`).
fn launchIdentity(alloc: Allocator) ipc_handoff.Identity {
    return .{
        .version = envOverride("GHOZTTY_HANDOFF_VERSION") orelse build_identity.version,
        .commit = envOverride("GHOZTTY_HANDOFF_COMMIT") orelse build_identity.commit,
        .exe = std.fs.selfExePathAlloc(alloc) catch "",
    };
}

/// DEBUG-ONLY (win32's T1023 seam): the version/commit a launch reports, so a
/// test can be another build. A release build has no such lever.
fn envOverride(name: [:0]const u8) ?[]const u8 {
    if (comptime builtin.mode != .Debug) return null;
    const v = std.posix.getenv(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// Open the window in the running build, carrying this launch's identity so it
/// knows the window was asked for by another build (and, `prompted`, that the
/// user already heard so).
fn join(alloc: Allocator, config: *const configpkg.Config, id: ipc_handoff.Identity) Outcome {
    const args = rules.forwardArgs(alloc, config.@"initial-command", config.@"working-directory") catch
        return .start;
    const sent = ipc_client.sendActionWithHandoff(alloc, "new-window", args, id) catch |err| {
        // Nobody answered after all: start as the app, as before this existed.
        log.warn("handoff: the running build did not answer the window ({}); starting here", .{err});
        return .start;
    };
    if (!sent) {
        log.warn("handoff: the running build refused the window", .{});
        return .exit_failed;
    }
    log.info("handoff: the window opened in the running build", .{});
    return .exit_ok;
}

/// Switch (win32's `takeOverEndpoint`): ask the running build to quit, wait
/// for its process to end and its socket to stop answering. True when this
/// launch should now start as the app; false sends the caller to a join.
fn takeOver(alloc: Allocator, id: ipc_handoff.Identity, pid: u32) bool {
    if (!ipc_client.requestHandoffQuit(alloc, id)) {
        log.warn("handoff: the running build did not agree to quit; opening the window in it", .{});
        return false;
    }
    log.warn("handoff: the running build (pid={d}) is quitting; waiting to take over", .{pid});

    if (pid != 0) {
        const deadline = std.time.milliTimestamp() + rules.exit_wait_ms;
        while (alive(pid)) {
            if (std.time.milliTimestamp() >= deadline) {
                log.warn("handoff: pid={d} still running after {d}ms", .{ pid, rules.exit_wait_ms });
                break;
            }
            std.Thread.sleep(rules.poll_ms * std.time.ns_per_ms);
        }
    }

    const deadline = std.time.milliTimestamp() + rules.free_wait_ms;
    while (served(alloc)) {
        if (std.time.milliTimestamp() >= deadline) {
            log.warn("handoff: the socket never came free; opening the window in the build that holds it", .{});
            return false;
        }
        std.Thread.sleep(rules.poll_ms * std.time.ns_per_ms);
    }
    log.warn("handoff: this launch is now the app ({s})", .{id.version});
    return true;
}

fn alive(pid: u32) bool {
    std.posix.kill(@intCast(pid), 0) catch |err| return err != error.ProcessNotFound;
    return true;
}

/// Whether anything still accepts a connection on the socket.
fn served(alloc: Allocator) bool {
    const path = ipc_client.clientEndpointPath(alloc) catch return false;
    const stream = std.net.connectUnixSocket(path) catch return false;
    stream.close();
    return true;
}

// ---------------------------------------------------------------------------
// The dialog
// ---------------------------------------------------------------------------

const Answer = struct {
    up: bool = true,
    index: ?usize = null,
};

/// Show the question and run the main context until it is answered. There is
/// no window yet - the launch has not registered - so the dialog is a window
/// of its own, as win32's centered, ownerless one is.
fn ask(prompt: ipc_handoff.Prompt, layout: rules.Layout) rules.Choice {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const title = alloc.dupeZ(u8, prompt.title) catch return .join;
    const text = alloc.dupeZ(u8, prompt.text) catch return .join;
    var labels: [4]?[*:0]const u8 = .{ null, null, null, null };
    for (layout.labels[0..layout.len], 0..) |l, i|
        labels[i] = (alloc.dupeZ(u8, l) catch return .join).ptr;

    const dialog = gobject.ext.newInstance(gtk.AlertDialog, .{});
    defer dialog.unref(); // `choose`'s task keeps its own reference
    dialog.setMessage(title.ptr);
    dialog.setDetail(text.ptr);
    dialog.setModal(1);
    // A NULL-terminated array; the binding types it without the sentinel.
    dialog.setButtons(@ptrCast(&labels));
    dialog.setDefaultButton(@intCast(layout.default_index));
    dialog.setCancelButton(@intCast(layout.cancel_index));

    var answer: Answer = .{};
    const cancellable = gio.Cancellable.new();
    defer cancellable.unref();
    dialog.choose(null, cancellable, dialogDone, &answer);
    afterShown(prompt, layout, cancellable);

    const ctx = glib.MainContext.default();
    while (answer.up) _ = glib.MainContext.iteration(ctx, 1);
    const choice = layout.choiceFor(answer.index);
    log.info("handoff: the user answered {s}", .{@tagName(choice)});
    return choice;
}

fn dialogDone(source: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
    const answer: *Answer = @ptrCast(@alignCast(ud));
    defer answer.up = false;
    const dialog: *gtk.AlertDialog = @ptrCast(@alignCast(source orelse return));
    var err: ?*glib.Error = null;
    const index = dialog.chooseFinish(result, &err);
    if (err) |e| {
        e.free();
        return;
    }
    if (index >= 0) answer.index = @intCast(index);
}

/// The debug-only test seam: record that the dialog is up - its title, its
/// buttons in order, its text on one line - and end it a moment later through
/// its cancellable (Cancel), so a headless run proves the path.
fn afterShown(prompt: ipc_handoff.Prompt, layout: rules.Layout, cancellable: *gio.Cancellable) void {
    if (comptime builtin.mode != .Debug) return;
    const path = std.posix.getenv("GHOZTTY_TEST_HANDOFF_DIALOG") orelse return;
    if (std.fs.cwd().createFile(path, .{ .truncate = false })) |file| {
        defer file.close();
        file.seekFromEnd(0) catch {};
        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const out = &w.interface;
        out.print("shown {s}|", .{prompt.title}) catch {};
        for (layout.labels[0..layout.len], 0..) |l, i|
            out.print("{s}{s}", .{ if (i == 0) "" else ",", l }) catch {};
        out.writeAll("|") catch {};
        for (prompt.text) |c| out.writeByte(if (c == '\n') ' ' else c) catch {};
        out.writeAll("\n") catch {};
        out.flush() catch {};
    } else |_| {}
    _ = cancellable.ref();
    _ = glib.timeoutAdd(500, endDialog, cancellable);
}

fn endDialog(ud: ?*anyopaque) callconv(.c) c_int {
    const cancellable: *gio.Cancellable = @ptrCast(@alignCast(ud));
    log.info("test seam: ending the handoff dialog", .{});
    cancellable.cancel();
    cancellable.unref();
    return 0;
}
