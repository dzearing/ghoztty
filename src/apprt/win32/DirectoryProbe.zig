//! The relay DEVICE DIRECTORY fetch, off the GUI thread (T711).
//!
//! ## What it replaces
//! `MachineChooser.open` used to call `relay_directory.listDevices` inline,
//! before the dialog window existed: an authenticated HTTPS round trip — over
//! a link that may be slow, captive or gone — between ctrl+shift+n and
//! anything at all appearing on screen. Nothing could be shown early because
//! nothing was remembered, and nothing could be refreshed later because the
//! fetch was a one-shot on the way in.
//!
//! Now every directory read runs HERE, on a detached thread, and lands back on
//! the GUI thread as a message. That single change is what makes all three of
//! T711's halves possible: the chooser opens instantly on `machine_cache`'s
//! remembered rows, an OPEN chooser can re-ask every few seconds
//! (`chooser_refresh.poll_ms`), and the app can warm the cache at LAUNCH so the
//! first open of the session is already truthful.
//!
//! ## Routed by chooser id, never by pointer
//! Same contract as the session roster's reply (`SessionRoster.fetch`): the
//! result lands on the app's message-only window and is matched against the
//! chooser's id. A chooser that closed while the fetch was in flight simply
//! has no match — a reply aimed at a destroyed HWND would be discarded with
//! its queue (leaking the fetched list) or, worse, delivered to whatever
//! window recycled the handle.
//!
//! `chooser_id == warm_only` is the LAUNCH warm: nothing matches it, on
//! purpose. Its result exists only to refresh `machine_cache`, which the
//! handler does for every landing regardless of who was listening.

const DirectoryProbe = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const relay_directory = @import("../../remote/relay_directory.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Posted to the app's message-only window when a device-list fetch finished:
/// `wparam` = a heap `*Result` the handler owns and destroys.
pub const WM_APP_CHOOSER_DEVICES: u32 = w32.WM_APP + 37;

/// The `chooser_id` of a fetch nobody is waiting for — the launch warm, whose
/// only product is the refreshed cache. No chooser can ever carry it:
/// `MachineChooser.next_chooser_id` starts at 1.
pub const warm_only: u64 = 0;

/// What the GUI thread is handed. Owns everything it carries.
pub const Result = struct {
    alloc: Allocator,
    /// Who asked. `warm_only` for the launch refresh.
    chooser_id: u64,
    /// The account the fetch was made for (owned) — carried so the handler can
    /// write the cache under the right key even if the user signed into a
    /// different account while the fetch was in flight.
    account: []u8,
    /// A fetch this chooser asked for QUIETLY (a poll tick). A quiet failure
    /// keeps the last-known list and says nothing until it has missed
    /// `chooser_refresh.miss_threshold` times in a row.
    quiet: bool,
    /// The listed devices, or null when the fetch failed. Owned by `parsed`.
    parsed: ?relay_directory.Parsed,
    /// Why it failed, when it did.
    err: ?anyerror,

    pub fn devices(self: *const Result) []const relay_directory.Device {
        const p = self.parsed orelse return &.{};
        return p.value.devices;
    }

    /// True when the relay REJECTED the credential. The one failure that is
    /// never quiet: it means the cached list is no longer authorized, so it is
    /// purged rather than kept (Mac's sign-out contract).
    pub fn unauthorized(self: *const Result) bool {
        const e = self.err orelse return false;
        return e == error.Unauthorized;
    }

    pub fn destroy(self: *Result) void {
        if (self.parsed) |p| p.deinit();
        self.alloc.free(self.account);
        self.alloc.destroy(self);
    }
};

const Request = struct {
    alloc: Allocator,
    hwnd: w32.HWND,
    chooser_id: u64,
    quiet: bool,
    /// Owned copies: the caller's arena belongs to a dialog that may close
    /// while this thread is still inside a TLS handshake.
    base: []u8,
    token: []u8,
    account: []u8,

    fn destroy(self: *Request) void {
        self.alloc.free(self.base);
        self.alloc.free(self.token);
        self.alloc.free(self.account);
        self.alloc.destroy(self);
    }
};

/// Start a device-list fetch on a detached thread. Returns true when one is in
/// flight (so the caller can gate a second tick on it).
///
/// `token` null is signed out: there is no directory to ask for, and no thread
/// is spawned. Resolving the credential stays on the GUI thread, where the
/// state that owns it lives — the blocking part is all the worker does.
pub fn start(
    alloc: Allocator,
    msg_hwnd: w32.HWND,
    chooser_id: u64,
    base: []const u8,
    token: ?[]const u8,
    account: []const u8,
    quiet: bool,
) bool {
    if (comptime builtin.os.tag != .windows) return false;
    const tok = token orelse return false;

    const req = alloc.create(Request) catch return false;
    req.* = .{
        .alloc = alloc,
        .hwnd = msg_hwnd,
        .chooser_id = chooser_id,
        .quiet = quiet,
        .base = alloc.dupe(u8, base) catch {
            alloc.destroy(req);
            return false;
        },
        .token = undefined,
        .account = undefined,
    };
    req.token = alloc.dupe(u8, tok) catch {
        alloc.free(req.base);
        alloc.destroy(req);
        return false;
    };
    req.account = alloc.dupe(u8, account) catch {
        alloc.free(req.base);
        alloc.free(req.token);
        alloc.destroy(req);
        return false;
    };

    const thread = std.Thread.spawn(.{}, worker, .{req}) catch |err| {
        log.warn("chooser directory: fetch thread spawn failed err={}", .{err});
        req.destroy();
        return false;
    };
    thread.detach();
    // Said out loud at info: this line is how an acceptance run proves the
    // POLL is alive (one per tick) and that opening the chooser did not wait
    // for the network (the dialog is already up when the first one lands).
    log.info("chooser directory: fetch started chooser={d} quiet={}", .{ chooser_id, quiet });
    return true;
}

fn worker(req: *Request) void {
    defer req.destroy();
    const alloc = req.alloc;

    var parsed: ?relay_directory.Parsed = null;
    var err: ?anyerror = null;
    if (relay_directory.listDevices(alloc, req.base, req.token)) |p| {
        parsed = p;
    } else |e| {
        err = e;
        // A quiet tick's failure is expected weather: logged at debug so a
        // chooser left open on a flaky link does not fill the log with lines
        // nobody acts on. A visible fetch's failure is what the footer hint
        // will be built from, so it is worth a warning.
        if (req.quiet) {
            log.debug("chooser directory: quiet refresh failed err={}", .{e});
        } else {
            log.warn("chooser directory: device list failed err={}", .{e});
        }
    }

    const res = alloc.create(Result) catch {
        if (parsed) |p| p.deinit();
        return;
    };
    const account = alloc.dupe(u8, req.account) catch {
        if (parsed) |p| p.deinit();
        alloc.destroy(res);
        return;
    };
    res.* = .{
        .alloc = alloc,
        .chooser_id = req.chooser_id,
        .account = account,
        .quiet = req.quiet,
        .parsed = parsed,
        .err = err,
    };
    if (w32.PostMessageW(req.hwnd, WM_APP_CHOOSER_DEVICES, @intFromPtr(res), 0) == 0) {
        // The app is going away; nothing will ever collect this.
        res.destroy();
    }
}
