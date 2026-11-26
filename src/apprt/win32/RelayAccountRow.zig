//! The relay-account row of the win32 machine chooser (T141).
//!
//! Sign-in used to be a CLI verb on Windows (`+relay-login` / `+relay-logout`,
//! T21a). The Mac client never had those — it signs in from the machine
//! chooser's account header — and a one-platform CLI verb is exactly the
//! divergence the user ruled out, so the verbs were deleted and this is where
//! signing in lives now: the chooser's own affordance, mirroring
//! `MachineChooserView.accountRow` on the Mac.
//!
//! This module owns the ASYNC half — the part that must not run on the GUI
//! thread. `relay_signin.signIn` blocks for as long as the user takes to
//! complete a browser consent screen (minutes), and `signOut` does a network
//! revoke; either on the GUI thread would freeze every window. So both run on a
//! detached thread and post `WM_APP_RELAY_ACCOUNT` to the app's message-only
//! window (`AgentIntegration`'s pattern), which routes the outcome to every
//! chooser that is open (T1552) — or to nobody, if the user closed it while
//! signing in. The
//! sign-in still took effect either way: the account store is the state, not
//! the dialog.
//!
//! `MachineChooser` owns the HWNDs and the redraw; everything here is either
//! pure (unit-tested label/status text) or off-thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const MachineChooser = @import("MachineChooser.zig");
const relay_signin = @import("../../remote/relay_signin.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Posted by the sign-in/sign-out thread to `App.msg_hwnd`. wparam = *Result
/// (ownership transfers to the GUI thread, which frees it in `onResult`).
/// WM_APP+1..+8 are taken (see App.zig / AgentIntegration.zig).
pub const WM_APP_RELAY_ACCOUNT: u32 = w32.WM_APP + 9;

pub const Kind = enum { sign_in, sign_out };

/// The outcome of an account operation, allocated on the app allocator by the
/// worker thread and freed by `onResult` on the GUI thread.
pub const Result = struct {
    kind: Kind,
    ok: bool,
    /// The signed-in email after a successful sign-in; empty otherwise.
    email: []const u8,
    /// A short user-facing sentence for the chooser's footer hint.
    message: []const u8,
    /// What became of THIS machine's device enrollment (T1421). Meaningful
    /// only on `.sign_out`. `.not_revoked` is the one the chooser must act on:
    /// the user is STILL SIGNED IN, and they have to be told and offered the
    /// way past it rather than left believing a sign-out that did not happen.
    machine: relay_signin.MachineOutcome = .nothing_to_revoke,
    /// The chooser window whose button started this operation (T1552), or
    /// null when nothing on screen did. Every open chooser hears the result;
    /// this only decides which one asks a FOLLOW-UP question (the
    /// `.not_revoked` "Sign Out Anyway" prompt), so one click never raises
    /// two modal dialogs. Compared, never dereferenced: the chooser may be
    /// gone by the time the result lands.
    origin: ?w32.HWND = null,
};

/// Only one account operation at a time. A second click while one is in flight
/// is ignored (the chooser also disables the button, but the guard has to live
/// with the work, not the widget: the chooser can be closed and reopened while
/// a sign-in is still running).
var running: std.atomic.Value(bool) = .init(false);

/// True while a sign-in/sign-out is in flight. The chooser consults this when
/// it opens so a re-opened chooser shows the pending state rather than an
/// enabled button that would start a second flow.
pub fn isRunning() bool {
    return running.load(.acquire);
}

/// Start a browser sign-in on a detached thread. Safe to call from the GUI
/// thread. Returns false when one is already in flight.
pub fn signInAsync(app: *App, origin: ?w32.HWND) bool {
    return startAsync(app, .sign_in, .revoke, origin);
}

/// Start a sign-out on a detached thread: revoke THIS machine's device
/// enrollment (T1421), revoke the session, delete the local store. Safe to call
/// from the GUI thread. Returns false when one is in flight.
///
/// `mode` is `.revoke` for the button, and `.force` for the "Sign Out Anyway"
/// the chooser offers after a `.not_revoked` outcome.
pub fn signOutAsync(app: *App, mode: relay_signin.SignOutMode, origin: ?w32.HWND) bool {
    return startAsync(app, .sign_out, mode, origin);
}

fn startAsync(app: *App, kind: Kind, mode: relay_signin.SignOutMode, origin: ?w32.HWND) bool {
    if (running.swap(true, .acq_rel)) {
        log.info("relay account: an operation is already running; ignoring", .{});
        return false;
    }
    const thread = std.Thread.spawn(.{}, worker, .{ app, kind, mode, origin }) catch |err| {
        running.store(false, .release);
        log.warn("relay account: thread spawn failed err={}", .{err});
        return false;
    };
    thread.detach();
    return true;
}

fn worker(app: *App, kind: Kind, mode: relay_signin.SignOutMode, origin: ?w32.HWND) void {
    defer running.store(false, .release);

    // The flow's own scratch memory: page-backed so it never touches the GUI
    // thread's allocator from off-thread.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const alloc = app.core_app.alloc;
    const res = alloc.create(Result) catch return;
    res.* = switch (kind) {
        .sign_in => blk: {
            if (relay_signin.signIn(arena, .{})) |outcome| {
                break :blk .{
                    .kind = .sign_in,
                    .ok = true,
                    .email = alloc.dupe(u8, outcome.email) catch "",
                    .message = "",
                };
            } else |err| {
                log.warn("relay account: sign-in failed err={}", .{err});
                break :blk .{
                    .kind = .sign_in,
                    .ok = false,
                    .email = "",
                    .message = relay_signin.errorMessage(err),
                };
            }
        },
        .sign_out => blk: {
            const out = relay_signin.signOut(arena, mode);
            break :blk .{
                .kind = .sign_out,
                // A sign-out that left the account signed in is NOT ok, and the
                // chooser must not re-read the account as though it had changed.
                .ok = out.signedOut(),
                .email = "",
                .message = signOutMessage(out),
                .machine = out.machine,
            };
        },
    };
    res.origin = origin;

    const hwnd = app.msg_hwnd orelse {
        free(app, res);
        return;
    };
    if (w32.PostMessageW(hwnd, WM_APP_RELAY_ACCOUNT, @intFromPtr(res), 0) == 0) {
        free(app, res);
    }
}

fn free(app: *App, res: *Result) void {
    const alloc = app.core_app.alloc;
    if (res.email.len > 0) alloc.free(res.email);
    alloc.destroy(res);
}

/// GUI thread (App's message-only WndProc): apply an account outcome. Owns
/// `res`. Routes to the open chooser when there is one; a closed chooser is not
/// an error — the store already changed, and the next chooser open reads it.
pub fn onResult(app: *App, res: *Result) void {
    defer free(app, res);
    log.info(
        "relay account: {s} {s}{s}",
        .{
            @tagName(res.kind),
            if (res.ok) "ok" else "failed",
            if (res.email.len > 0) " (signed in)" else "",
        },
    );
    // T1552: EVERY open chooser hears it — the account is one state shared by
    // all of them, so a window that did not ask must still relabel its row and
    // fetch its list. Only the follow-up question goes to one chooser (below).
    // No modal pump runs inside `onAccountResult`, so the window list cannot
    // change under this loop.
    var target: ?*MachineChooser = null;
    for (app.windows.items) |win| {
        const chooser = win.machine_chooser orelse continue;
        chooser.onAccountResult(res);
        if (takesPrompt(w32.HWND, if (target) |t| t.hwnd else null, chooser.hwnd, res.origin)) {
            target = chooser;
        }
    }

    // A sign-out that could not revoke this machine left the user SIGNED IN
    // (T1421): ask "Sign Out Anyway?" once, in the chooser whose button asked.
    // Last, because it is modal and the chooser set can change under its pump.
    if (res.kind == .sign_out and res.machine == .not_revoked) {
        if (target) |chooser| chooser.offerForcedSignOut();
    }

    // T713: the account's WINDOWS follow the account. This runs after the
    // chooser has been told, so the row has already relabelled itself and the
    // hint is already up — and it runs whether or not a chooser is open, because
    // the store is the state, not the dialog (the rule this file opens with).
    //
    // Only a sign-out that actually signed out (`ok`) closes anything: T1421's
    // `.not_revoked` outcome leaves the user SIGNED IN, and taking their windows
    // away over a sign-out that did not happen would be the worst of both.
    if (!res.ok) return;
    switch (res.kind) {
        .sign_out => _ = app.suspendRelayWindowsForSignOut(),
        .sign_in => _ = app.restoreRelayWindowsForSignIn(),
    }
}

/// Whether `candidate` should take over as the chooser that asks a result's
/// follow-up question from `current` (the pick so far, null for none), walking
/// the open choosers in window order (T1552). The chooser that started the
/// operation (`origin`) wins; when it has been closed — or nothing on screen
/// started it — the first open chooser does, which is what every result used
/// to get. Pure and generic over the handle type so it is unit-tested.
pub fn takesPrompt(comptime H: type, current: ?H, candidate: H, origin: ?H) bool {
    const cur = current orelse return true;
    const o = origin orelse return false;
    return cur != o and candidate == o;
}

// ---------------------------------------------------------------------
// Pure presentation: `relay_account_text.zig`, shared with the GTK chooser
// (T3575). Re-exported so every win32 caller keeps reading the same names.
// ---------------------------------------------------------------------

const text = @import("relay_account_text.zig");
pub const buttonLabel = text.buttonLabel;
pub const unconfigured_status = text.unconfigured_status;
pub const unconfigured_hint = text.unconfigured_hint;
pub const statusText = text.statusText;
pub const pendingRevocationText = text.pendingRevocationText;
pub const signOutMessage = text.signOutMessage;
pub const not_revoked_title = text.not_revoked_title;
pub const not_revoked_body = text.not_revoked_body;
pub const monogram = text.monogram;

const testing = std.testing;

test {
    _ = text;
}

test "takesPrompt: the chooser that asked gets the follow-up, wherever it sits (T1552)" {
    // Walk three open choosers in window order, the way `onResult` does, and
    // return which one ended up holding the prompt.
    const Walk = struct {
        fn pick(open: []const u32, origin: ?u32) ?u32 {
            var target: ?u32 = null;
            for (open) |c| {
                if (takesPrompt(u32, target, c, origin)) target = c;
            }
            return target;
        }
    };
    const open = [_]u32{ 10, 20, 30 };
    // The asker is the SECOND window: before T1552 the first one got it.
    try testing.expectEqual(@as(?u32, 20), Walk.pick(&open, 20));
    try testing.expectEqual(@as(?u32, 30), Walk.pick(&open, 30));
    try testing.expectEqual(@as(?u32, 10), Walk.pick(&open, 10));
    // The asker was closed while the flow ran, or nothing on screen asked:
    // the first open chooser, the pre-T1552 behaviour, rather than nobody.
    try testing.expectEqual(@as(?u32, 10), Walk.pick(&open, 99));
    try testing.expectEqual(@as(?u32, 10), Walk.pick(&open, null));
    // No chooser open: no prompt at all.
    try testing.expectEqual(@as(?u32, null), Walk.pick(&[_]u32{}, 20));
}
