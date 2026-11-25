//! The shared verb BODIES (T3361, Linux L5b): argument handling, target
//! resolution wording and reply shape for the IPC verbs, written once over a
//! small model each frontend implements over its own types. `server.zig` owns
//! the request and the routing; this file owns what a verb DOES with it, so
//! win32 and GTK answer a verb with the same bytes and the same sentences
//! instead of two hand-kept copies drifting apart (T3336 had already copied
//! `+send-keys`/`+read` from win32 into GTK once).
//!
//! Moved so far: `+read` and `+send-keys` (T3361), then `+close`, the `focus`
//! action, `+set-state` and `+set-banner` (T3374), then `+new-window`,
//! `+split`, `+rename` and `+list`'s split-tree walk (T3375; their model is
//! documented on each body below), then `+reload` (T3413). Each is
//! `fn (comptime F, ctx: F.Context, request) Allocator.Error!?[]u8`, so a
//! frontend's handler is one line: `return verbs.read(@This(), ctx, request);`.
//! A frontend only needs the model decls of the verbs it routes here: Zig
//! analyzes a body only when it is called, so GTK can serve `+close` before it
//! has a banner to set.
//!
//! ## The model a frontend supplies (beyond server.zig's interface)
//!
//! For `+read` / `+send-keys`, which act on a terminal:
//!
//! - `pub const Terminal: type` - a handle to one terminal pane, with
//!   - `fn writeRaw(self, bytes) !void` - bytes to the pty, as typed;
//!   - `fn writeBracketed(self, bytes) !void` - bytes as a paste, framed when
//!     the program asked for bracketed paste;
//!   - `fn pasteIsBracketed(self) bool`;
//!   - `fn dumpScreen(self, arena, timing: ?*DumpTiming) ?[]const u8` - the
//!     whole screen (scrollback + active) as laid out, or null when it could
//!     not be serialized at all.
//!   `core_terminal.zig` is that handle over the shared core `Surface`, which
//!   both frontends use.
//! - `fn replyAllocator(ctx) Allocator` - what replies are allocated with.
//! - `fn lookupTerminal(ctx, name) Lookup(Terminal)` - what a `--target`/
//!   `--name` names, by the frontend's own registry.
//! - `pub const input_line_ends: LineEnds` - `.pty` for a POSIX pty, which
//!   takes a bare LF as a line end, or `.conpty` where an LF must become CR
//!   (win32's ConPTY; see `args.normalizeConptyInput`).
//! - optionally `fn notFoundResponse(ctx, name, fallback) Allocator.Error![]u8`
//!   - the reply for a name nothing answers to. win32 uses it to name an
//!   AMBIGUOUS name (several windows hold it, none is the caller's, T2250);
//!   without it the verb's own not-found sentence is the reply.
//!
//! For `+close` / `focus` / `+set-state` / `+set-banner`, which act on a
//! window or a pane:
//!
//! - `pub const Target: type` - what a name resolves to: a window or a pane.
//! - `fn lookupTarget(ctx, arena, name) Allocator.Error!TargetLookup(Target)`.
//! - `focus`: `fn focusTarget(target) void` - raise the window, focus the pane.
//! - `+close`: `fn closeConfirmationOpen(target) bool` - a close confirmation
//!   is up over the target's window; `fn dismissConfirmations(ctx, target,
//!   name) Dismissed` - answer it (Cancel) for `--force`; and
//!   `fn closeTarget(ctx, target, force: bool) bool` - close it now, false
//!   when that failed.
//! - `+set-state`: `fn setActivityState(target, ActivityState) bool` - a
//!   pane, or every terminal pane of a window; false for a viewer pane.
//! - `+set-banner`: `fn setPaneBanner(target, text: ?[]const u8) BannerSet` -
//!   the pane's, or a window's focused pane's; null clears it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const server = @import("server.zig");
const verb_args = @import("args.zig");
const verb_segments = @import("segments.zig");
const read_tail = @import("read_tail.zig");
const split_name_collision = @import("split_name_collision.zig");
const List = @import("list.zig").List;

const Request = server.Request;
const errorResponse = server.errorResponse;

/// What a target name resolves to. Each failure is a DIFFERENT state with its
/// own sentence (T181): a caller that cannot tell "it died" from "it never
/// started" cannot react to either.
pub fn Lookup(comptime Terminal: type) type {
    return union(enum) {
        /// A live terminal.
        ready: Terminal,
        /// Nothing answers to the name.
        not_found,
        /// It answered once and is being torn down (or a window with no tabs
        /// left).
        gone,
        /// A viewer pane (markdown, HTML, diff...), which has no pty.
        viewer,
        /// A terminal whose startup never completed.
        not_started,
    };
}

pub const LineEnds = enum { pty, conpty };

/// Where `+read`'s time went, for the GHOZTTY_PERF line (T111b): waiting for
/// the renderer lock vs serializing under it. The two halves have opposite
/// fixes, so they are reported apart.
pub const DumpTiming = struct {
    lock_wait_ns: u64 = 0,
    dump_ns: u64 = 0,
};

pub const default_read_lines: usize = 50;

const ok_reply = "{\"success\":true}";

/// Which verb is asking, for the per-state sentences: `+read` names a
/// `pane`, `+send-keys` a `target`, and the not-started sentence says which
/// thing it could not do. The wording is win32's since T181 and GTK's since
/// T3336, now one copy.
const Role = struct {
    noun: []const u8,
    ability: []const u8,
    not_found_fmt: []const u8,
};
const read_role: Role = .{
    .noun = "pane",
    .ability = "readable",
    .not_found_fmt = "pane '{s}' not found in registry",
};
const send_role: Role = .{
    .noun = "target",
    .ability = "writable",
    .not_found_fmt = "target '{s}' not found",
};

/// Resolve `name` to a live terminal, or the reply that says why not.
fn resolve(
    comptime F: type,
    ctx: F.Context,
    name: []const u8,
    comptime role: Role,
) Allocator.Error!union(enum) { terminal: F.Terminal, reply: []u8 } {
    const alloc = F.replyAllocator(ctx);
    return switch (F.lookupTerminal(ctx, name)) {
        .ready => |t| .{ .terminal = t },
        .not_found => .{ .reply = if (@hasDecl(F, "notFoundResponse")) nf: {
            const fallback = try std.fmt.allocPrint(alloc, role.not_found_fmt, .{name});
            defer alloc.free(fallback);
            break :nf try F.notFoundResponse(ctx, name, fallback);
        } else try errorResponse(alloc, role.not_found_fmt, .{name}) },
        .gone => .{ .reply = try errorResponse(alloc, role.noun ++ " '{s}' is no longer alive", .{name}) },
        .viewer => .{ .reply = try errorResponse(alloc, "{s} is a viewer pane, not a terminal", .{name}) },
        .not_started => .{ .reply = try errorResponse(
            alloc,
            role.noun ++ " '{s}' is not " ++ role.ability ++ ": its terminal never finished starting up",
            .{name},
        ) },
    };
}

// ---------------------------------------------------------------------------
// +read

/// `+read --name=<pane> [--lines=N]`: the last N lines (default 50) of the
/// pane's whole screen as laid out, by the shared rule (T181). A pane that has
/// printed nothing answers success with empty text - that is the truthful
/// answer for every pane's first fraction of a second, and reporting it as a
/// failure made a lost race read like a missing pane.
pub fn read(comptime F: type, ctx: F.Context, request: Request) Allocator.Error!?[]u8 {
    const alloc = F.replyAllocator(ctx);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);
    const name = args.name orelse
        return try errorResponse(alloc, "--name is required for +read", .{});
    const line_count: usize = if (args.lines) |l|
        (if (l > 0) @intCast(l) else default_read_lines)
    else
        default_read_lines;

    const term = switch (try resolve(F, ctx, name, read_role)) {
        .terminal => |t| t,
        .reply => |r| return r,
    };

    // GHOZTTY_PERF (T111b): `+read` of a flooded pane is the sharpest probe
    // of contention on that pane's renderer lock.
    var timing: DumpTiming = .{};
    const perf = perfEnabled();
    const full = term.dumpScreen(arena, if (perf) &timing else null) orelse
        return try errorResponse(alloc, "failed to read terminal content from '{s}'", .{name});
    if (perf) std.log.scoped(F.log_scope).info("ipcperf read pane={s} lockwait={d}ms dump={d}ms", .{
        name,
        timing.lock_wait_ns / std.time.ns_per_ms,
        timing.dump_ns / std.time.ns_per_ms,
    });

    return try readResponse(alloc, read_tail.tail(full, line_count));
}

fn perfEnabled() bool {
    if (comptime @import("builtin").is_test) return false;
    return std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PERF");
}

/// `{"success":true,"data":{"text":<text>}}`.
pub fn readResponse(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jws: std.json.Stringify = .{ .writer = &out.writer };
    write: {
        jws.beginObject() catch break :write;
        jws.objectField("success") catch break :write;
        jws.write(true) catch break :write;
        jws.objectField("data") catch break :write;
        jws.beginObject() catch break :write;
        jws.objectField("text") catch break :write;
        jws.write(text) catch break :write;
        jws.endObject() catch break :write;
        jws.endObject() catch break :write;
        return try out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// +send-keys

/// `+send-keys --target=<pane> --keys=<bytes> [--segments=...]
/// [--keys-resolved=1]`. The CLI resolves all key notation (C-x, Enter, `\n`
/// escapes) before sending, so this only writes bytes - the Mac's
/// `handleSendKeys`:
///
/// - With `--segments=` (T428) each TEXT run is written as a paste (framed
///   when the program asked for bracketed paste) and each KEY run bare, which
///   is what makes the trailing `Enter` of `"msg" Enter` submit instead of
///   landing in a composer as a pasted newline. A `--segments=` that does not
///   parse loses only the framing: the same bytes are in `--keys=`.
/// - Without it the flat `--keys=` payload is written as typed.
/// - Both go through `writeRaw`/`writeBracketed`, so a read-only pane refuses
///   them the same way (the Mac's `writePtyRaw`; win32's flat path wrote past
///   that check until T3361).
///
/// On a ConPTY (`input_line_ends = .conpty`) an LF must become CR or
/// `"echo A\necho B\n"` reaches cmd.exe as `echo Aecho B` (measured
/// 2026-08-10). `--keys-resolved=1` (T661) says every LF still in a text run
/// is CONTENT, so only a text run the program will not see as a paste is
/// mapped; an older CLI's payload is mapped whole, as it always was. A POSIX
/// pty takes LF as a line end, so `.pty` writes every byte untouched.
pub fn sendKeys(comptime F: type, ctx: F.Context, request: Request) Allocator.Error!?[]u8 {
    const alloc = F.replyAllocator(ctx);

    var target: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var segments_value: ?[]const u8 = null;
    var resolved = false;
    if (request.arguments) |arguments| for (arguments) |arg| {
        if (verb_args.dropPrefix(arg, "--target=")) |v| {
            target = v;
        } else if (verb_args.dropPrefix(arg, verb_segments.prefix)) |v| {
            segments_value = v;
        } else if (verb_args.dropPrefix(arg, verb_args.keys_resolved_prefix)) |v| {
            resolved = verb_args.keysResolvedValue(v);
        } else if (verb_args.dropPrefix(arg, "--keys=")) |v| {
            text = v;
        }
    };
    const target_name = target orelse
        return try errorResponse(alloc, "--target is required for +send-keys", .{});
    const bytes = text orelse
        return try errorResponse(alloc, "text is required for +send-keys", .{});
    if (bytes.len == 0)
        return try errorResponse(alloc, "text is required for +send-keys", .{});

    const term = switch (try resolve(F, ctx, target_name, send_role)) {
        .terminal => |t| t,
        .reply => |r| return r,
    };

    if (segments_value) |value| decode: {
        const runs = verb_segments.decode(alloc, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed => {
                std.log.scoped(F.log_scope).warn("+send-keys: ignoring malformed --segments=, sending flat", .{});
                break :decode;
            },
        };
        defer verb_segments.freeSegments(alloc, runs);
        if (runs.len == 0) break :decode;

        for (runs) |run| {
            if (run.bytes.len == 0) continue;
            const run_bytes = try prepareRun(F, alloc, term, run.bytes, run.kind, resolved);
            defer alloc.free(run_bytes);
            const written = switch (run.kind) {
                .text => term.writeBracketed(run_bytes),
                .key => term.writeRaw(run_bytes),
            };
            written catch return try errorResponse(alloc, "failed to queue input", .{});
        }
        return try alloc.dupe(u8, ok_reply);
    }

    // A flat payload is all text or all keys, and a key run from a resolved
    // CLI is already CR with no LF for the mapping to touch, so calling it
    // text is right for both of the things it can be.
    const flat = try prepareRun(F, alloc, term, bytes, .text, resolved);
    defer alloc.free(flat);
    term.writeRaw(flat) catch
        return try errorResponse(alloc, "failed to queue input", .{});
    return try alloc.dupe(u8, ok_reply);
}

/// The bytes one run is written as (caller frees). A POSIX pty gets them
/// verbatim. On a ConPTY (T661) there are three cases, and the shape of the
/// answer is the whole point:
///
///   * NOT resolved - a CLI old enough that a bare `\n` meant Enter. Rewrite
///     every newline to CR exactly as win32 always did, whatever the pane is
///     running. Nothing else can be inferred about those bytes.
///   * a `.key` run - a keypress the CLI already spelled as its terminal byte.
///     Verbatim; there is no newline in it to decide about.
///   * a `.text` run - pasted content, so it follows the terminal-wide paste
///     convention `input.paste.encode` implements: a program that asked for
///     bracketed paste understands a newline as a line break in the content
///     and gets it verbatim, while one that did not gets LF mapped to CR the
///     way xterm has always done it.
///
/// That last split is what makes this parity rather than a Windows quirk. On a
/// POSIX pty an unframed LF is a line terminator for a shell, so macOS and
/// Linux need no mapping to run `a` then `b`; conhost's VT input translation
/// SWALLOWS a bare LF. Mapping it restores the behavior a Mac user sees, while
/// a TUI's composer still receives the literal line break main's contract
/// promises it.
fn prepareRun(
    comptime F: type,
    alloc: Allocator,
    term: F.Terminal,
    bytes: []const u8,
    kind: verb_segments.Kind,
    resolved: bool,
) Allocator.Error![]u8 {
    switch (F.input_line_ends) {
        .pty => return try alloc.dupe(u8, bytes),
        .conpty => {
            if (!resolved) return try verb_args.normalizeConptyInput(alloc, bytes);
            if (kind == .text and !term.pasteIsBracketed())
                return try verb_args.normalizeConptyInput(alloc, bytes);
            return try alloc.dupe(u8, bytes);
        },
    }
}

// ---------------------------------------------------------------------------
// The window-or-pane verbs: +close, focus, +set-state, +set-banner (T3374).

/// What a window-or-pane name resolves to.
pub fn TargetLookup(comptime Target: type) type {
    return union(enum) {
        found: Target,
        /// Panes in several windows hold the name and none of them is the
        /// caller's (T2250): the sentence that names those windows, allocated
        /// in the arena the lookup was given.
        ambiguous: []const u8,
        not_found,
    };
}

/// The not-found sentence of every window-or-pane verb (win32's since T35).
const target_not_found_fmt = "target '{s}' not found in registry";

/// Resolve `name` to a target, or the reply that says why not.
fn resolveTarget(
    comptime F: type,
    ctx: F.Context,
    arena: Allocator,
    name: []const u8,
) Allocator.Error!union(enum) { target: F.Target, reply: []u8 } {
    const alloc = F.replyAllocator(ctx);
    return switch (try F.lookupTarget(ctx, arena, name)) {
        .found => |t| .{ .target = t },
        .ambiguous => |msg| .{ .reply = try errorResponse(alloc, "{s}", .{msg}) },
        .not_found => .{ .reply = try errorResponse(alloc, target_not_found_fmt, .{name}) },
    };
}

/// `focus --target=<name>`: raise the window holding the target and focus the
/// pane. There is no `+focus` CLI verb on any platform: this is the wire
/// action the `ghoztty://` launcher sends (T695, `url_scheme.zig`), and it
/// never creates, so a link that launched nothing answers "not found" instead
/// of opening a window as a side effect.
pub fn focus(comptime F: type, ctx: F.Context, request: Request) Allocator.Error!?[]u8 {
    const alloc = F.replyAllocator(ctx);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);
    const name = args.target orelse
        return try errorResponse(alloc, "--target is required for focus", .{});
    const target = switch (try resolveTarget(F, ctx, arena, name)) {
        .target => |t| t,
        .reply => |r| return r,
    };
    F.focusTarget(target);
    std.log.scoped(F.log_scope).info("IPC: focused '{s}'", .{name});
    return try alloc.dupe(u8, ok_reply);
}

/// What answering a close confirmation for `+close --force` left to do.
pub const Dismissed = enum {
    /// Dismissed; close the target now.
    close_now,
    /// The frontend closes it itself once the dialog has unwound (win32's
    /// dialogs are modal loops on the stack below this dispatch).
    closing,
    /// Dismissed, but nothing could be queued to close it.
    queue_full,
};

/// `+close --target=<name> [--force]`: close a pane (its window too, when it
/// was the last one) or a whole window, with no confirmation - the CLI drives
/// teardown, as on the Mac (`withConfirmation: false` /
/// `closeWindowImmediately`). `--force` (T2938) also skips the undo window.
///
/// Idempotent: a target nothing answers to is already closed. A name panes in
/// several other windows hold is NOT that: closing one at random would close
/// another agent's pane (T2250).
///
/// A dialog up over the window (T2938, Mac 4b558ab8f's `attachedSheet`) is a
/// question nothing on the IPC path can answer; closing under it would report
/// success over it, so a plain close closes nothing and says so, and
/// `--force` answers it (Cancel) and closes.
pub fn close(comptime F: type, ctx: F.Context, request: Request) Allocator.Error!?[]u8 {
    const alloc = F.replyAllocator(ctx);
    const log = std.log.scoped(F.log_scope);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);
    const name = args.target orelse
        return try errorResponse(alloc, "--target is required for +close", .{});

    const target = switch (try F.lookupTarget(ctx, arena, name)) {
        .found => |t| t,
        .ambiguous => |msg| return try errorResponse(alloc, "{s}", .{msg}),
        .not_found => return try alloc.dupe(u8, ok_reply),
    };

    if (F.closeConfirmationOpen(target)) {
        if (!args.force) {
            log.info("IPC: +close '{s}' is waiting on a confirmation in its window", .{name});
            return try errorResponse(
                alloc,
                "'{s}' is waiting on a close confirmation in its window, so nothing closed yet; answer it there, or run +close --force (no confirmation, no undo)",
                .{name},
            );
        }
        switch (F.dismissConfirmations(ctx, target, name)) {
            .close_now => {},
            .closing => return try alloc.dupe(u8, ok_reply),
            .queue_full => return try errorResponse(
                alloc,
                "'{s}': the confirmation was dismissed but too many forced closes are already waiting; run +close --force again",
                .{name},
            ),
        }
    }

    if (!F.closeTarget(ctx, target, args.force))
        return try errorResponse(alloc, "failed to close '{s}'", .{name});
    log.info("IPC: closed '{s}'", .{name});
    return try alloc.dupe(u8, ok_reply);
}

/// The states `+set-state --state=` takes (the tokens of the core's
/// `osc.Command.ActivityState`, whose names they are).
pub const ActivityState = enum { idle, busy, needs_input };

/// `+set-state --target=<name> --state=idle|busy|needs_input`: a pane target
/// sets that pane, a window target every terminal pane in the window (Mac
/// `handleSetState`).
pub fn setState(comptime F: type, ctx: F.Context, request: Request) Allocator.Error!?[]u8 {
    const alloc = F.replyAllocator(ctx);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);
    const name = args.target orelse
        return try errorResponse(alloc, "--target is required for +set-state", .{});
    const state_str = args.state orelse
        return try errorResponse(alloc, "--state is required for +set-state", .{});
    const state = std.meta.stringToEnum(ActivityState, state_str) orelse
        return try errorResponse(alloc, "invalid state '{s}': must be idle, busy, or needs_input", .{state_str});

    const target = switch (try resolveTarget(F, ctx, arena, name)) {
        .target => |t| t,
        .reply => |r| return r,
    };
    if (!F.setActivityState(target, state))
        return try errorResponse(alloc, "{s} is a viewer pane, not a terminal", .{name});
    return try alloc.dupe(u8, ok_reply);
}

/// What setting a banner found.
pub const BannerSet = enum {
    set,
    /// A window target with no tabs left.
    no_pane,
    /// The pane is a viewer pane, which has no banner.
    viewer,
};

/// `+set-banner --target=<name> <text>... | --clear` (T35): set or clear the
/// sticky banner of a pane. Banners are per-pane; a window target applies to
/// its focused pane (Mac `handleSetBanner`).
pub fn setBanner(comptime F: type, ctx: F.Context, request: Request) Allocator.Error!?[]u8 {
    const alloc = F.replyAllocator(ctx);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseSetBannerArgs(arena, request.arguments);
    const name = args.target orelse
        return try errorResponse(alloc, "--target is required for +set-banner", .{});
    const target = switch (try resolveTarget(F, ctx, arena, name)) {
        .target => |t| t,
        .reply => |r| return r,
    };
    return switch (F.setPaneBanner(target, if (args.clear) null else args.text)) {
        .set => try alloc.dupe(u8, ok_reply),
        .no_pane => try errorResponse(alloc, "target '{s}' has no focused pane", .{name}),
        .viewer => try errorResponse(alloc, "{s} is a viewer pane, not a terminal", .{name}),
    };
}

/// What reloading a target's viewer found (T3413).
pub const ReloadOutcome = enum {
    /// The viewer reloaded in place.
    reloaded,
    /// A pane target that is a terminal.
    terminal,
    /// A window target whose focused pane is a terminal.
    focused_terminal,
    /// A window target with no pane left.
    gone,
};

/// `+reload --target=<name>` reloads a viewer pane in place, bypassing caches
/// (a window target reloads its focused pane); `+reload --config` re-reads the
/// app's configuration, app-wide (T893). win32's handler since T893, shared in
/// T3413 so the Linux app answers with the same sentences. The model:
///
/// - `fn reloadConfig(ctx, arena) Allocator.Error!?[]const u8` - reload the
///   configuration; null on success, else the sentence that says why not.
/// - `fn reloadViewer(target) ReloadOutcome` - reload the target's viewer.
pub fn reload(comptime F: type, ctx: F.Context, request: Request) Allocator.Error!?[]u8 {
    const alloc = F.replyAllocator(ctx);
    const log = std.log.scoped(F.log_scope);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);

    // `--config` names no pane, so combining it with `--target` is a mistake
    // about which reload was meant rather than two requests to run.
    if (args.config) {
        if (args.target != null)
            return try errorResponse(alloc, "{s}", .{verb_args.reload_config_target_error});
        if (try F.reloadConfig(ctx, arena)) |why| return try errorResponse(alloc, "{s}", .{why});
        log.info("IPC: reloaded configuration", .{});
        return try alloc.dupe(u8, ok_reply);
    }

    const name = args.target orelse
        return try errorResponse(alloc, "--target is required for +reload", .{});
    const target = switch (try resolveTarget(F, ctx, arena, name)) {
        .target => |t| t,
        .reply => |r| return r,
    };
    switch (F.reloadViewer(target)) {
        .reloaded => {},
        .terminal => return try errorResponse(alloc, "target '{s}' is a terminal pane, nothing to reload", .{name}),
        .focused_terminal => return try errorResponse(alloc, "focused pane of '{s}' is a terminal pane, nothing to reload", .{name}),
        .gone => return try errorResponse(alloc, "target '{s}' is no longer alive", .{name}),
    }
    log.info("IPC: reloaded viewer '{s}'", .{name});
    return try alloc.dupe(u8, ok_reply);
}

// ---------------------------------------------------------------------------
// The create verbs: +new-window, +split, +rename (T3375). What is shared is
// the POLICY - argument checks and their order, the idempotent "focused"
// answers and their notes, name collisions (T2184/T2250), where a split lands,
// and the reply - while the window or pane itself is built by the frontend,
// which alone knows its shells, agents, viewers and tints.

/// The four ways a split opens: the CLI's `--direction`/`--split` words.
pub const SplitDirection = enum { right, down, left, up };

pub fn parseSplitDirection(s: []const u8) ?SplitDirection {
    return std.meta.stringToEnum(SplitDirection, s);
}

/// What `+new-window` asks the frontend to open, once the shared checks
/// passed. `args` still carries everything else (command, env, cwd, title,
/// colors, `--view`, `--focus`).
pub const WindowPlan = struct {
    /// The pane name the first pane registers under (`--name` without an
    /// inline split, T968), or null.
    first_pane_name: ?[]const u8,
    /// The `GHOZTTY_PANE_NAME` the first pane is started with: its own name,
    /// else the window's.
    first_pane_env_name: ?[]const u8,
    /// The inline split (`--split=`), already validated.
    split: ?SplitDirection,
};

/// What opening a window came to.
pub const Opened = union(enum) {
    /// Opened; the reply's optional `note`.
    created: ?[]const u8,
    /// Nothing opened; the reason, sent back as the error.
    failed: []const u8,
};

/// What `+split` asks the frontend to open at the anchor it resolved.
pub const SplitSpec = struct {
    direction: SplitDirection,
    /// The NEW pane's share, as the frontends' split trees keep it.
    ratio: f16,
    /// `--from-focused`: mirror the keyboard split - inherit the parent's
    /// command, cwd and machine, name nothing, tint nothing.
    inherit: bool,
};

/// What holds a name where a `+split --name=` would put it.
pub fn NameHolder(comptime Target: type) type {
    return struct {
        target: Target,
        existing: split_name_collision.Existing,
    };
}

/// What `+rename` found.
pub const Renamed = union(enum) {
    renamed,
    /// The user's own title is up (T2404); it is the payload.
    kept: []const u8,
};

/// The `+rename` refusal, word for word as Mac's (`IPCServer.swift`), so a
/// script reading the error sees one sentence on every platform.
pub const rename_refusal_fmt = "window '{s}' was renamed by the user ('{s}'); " ++
    "+rename leaves a user's title alone until they clear it";

/// `--view` before anything else: an ambiguous `--view` + command is refused
/// the same way everywhere, and a frontend that has no viewer yet says so
/// (`pub const view_not_served: []const u8`).
fn viewRefusal(comptime F: type, alloc: Allocator, args: verb_args.VerbArgs) Allocator.Error!?[]u8 {
    if (verb_args.viewConflictsWithCommand(args))
        return try errorResponse(alloc, "{s}", .{verb_args.view_command_conflict_error});
    if (@hasDecl(F, "view_not_served")) if (args.view != null)
        return try errorResponse(alloc, "{s}", .{F.view_not_served});
    // T3735: a `--shell` the platform can tell will not start (a WSL distro
    // that is not installed) is refused before anything opens.
    if (@hasDecl(F, "shellRefusal")) if (try F.shellRefusal(alloc, args)) |r| return r;
    return null;
}

/// The reply to a `+new-window` whose window or pane already exists (T135):
/// `outcome: focused`, with a note naming the flags only a create would have
/// honored - the CLI prints it, so the drop is loud. Exit stays 0:
/// idempotency is the contract, silence was the defect.
fn alreadyThere(
    alloc: Allocator,
    arena: Allocator,
    comptime what: []const u8,
    name: []const u8,
    args: verb_args.VerbArgs,
) Allocator.Error![]u8 {
    if (try verb_args.droppedOnExistingTarget(arena, args)) |dropped| {
        const note = try std.fmt.allocPrint(
            arena,
            what ++ " '{s}' already exists; {s} it. Ignored: {s}. +close it first to recreate.",
            .{ name, server.foundVerb(args.focus), dropped },
        );
        return try server.successResponse(alloc, "focused", note);
    }
    return try server.successResponse(alloc, "focused", null);
}

const pane_holds_window_name_fmt = "'{s}' is already the name of a pane, so no window can take it. Use another --target.";

/// `+new-window [--target=<window>] [--name=<pane>] [--split=<dir>] ...`.
///
/// Model: `lookupWindowName(ctx, arena, name) TargetLookup(Target)` - what a
/// GLOBAL name means, ignoring the caller's window (window names are global);
/// `isPane(target) bool`; `focusTarget`; `lookupTarget`; `openWindow(ctx,
/// arena, request, args, WindowPlan) Allocator.Error!Opened`. Optionally
/// `newWindowFromFocused(ctx, arena, args) Allocator.Error!?[]u8` - the reply
/// when `--from-focused` opened a window on the focused window's REMOTE
/// machine, null to open a local one - and `view_not_served`.
pub fn newWindow(comptime F: type, ctx: F.Context, request: Request) Allocator.Error!?[]u8 {
    const alloc = F.replyAllocator(ctx);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try verb_args.parseVerbArgs(arena, request.arguments);

    // Before anything is created or focused (Mac IPCServer.swift:386, ahead
    // of its idempotent target focus).
    if (try viewRefusal(F, alloc, args)) |r| return r;

    // `--from-focused` (T68) mirrors the keyboard "New Window": a REMOTE
    // parent's machine is inherited, and like the Mac that path ignores
    // `--target`/`--name` and the inline split. A local (or no) parent opens a
    // plain local window, dropping the same flags.
    if (args.from_focused) {
        if (@hasDecl(F, "newWindowFromFocused"))
            if (try F.newWindowFromFocused(ctx, arena, args)) |r| return r;
        args.target = null;
        args.name = null;
        args.split_direction = null;
        args.title = null;
    }

    // Idempotent: an existing window of that name is found, not recreated -
    // and raised only with `--focus` (T1797). A pane's name is never a
    // window's (T2250, Mac 71da9a680): a `--target` a pane holds fails rather
    // than "succeeding" without opening the window that was asked for.
    if (args.target) |target| switch (try F.lookupWindowName(ctx, arena, target)) {
        .ambiguous => return try errorResponse(alloc, pane_holds_window_name_fmt, .{target}),
        .found => |t| {
            if (F.isPane(t)) return try errorResponse(alloc, pane_holds_window_name_fmt, .{target});
            if (args.focus) F.focusTarget(t);
            return try alreadyThere(alloc, arena, "target", target, args);
        },
        .not_found => {},
    };

    // T968: `--name` names a PANE (the first one, or the inline split's) and
    // is idempotent the same way `+split --name` is. `--target` decided
    // first, so this only answers when the caller named no window.
    if (args.name) |name| if (args.target == null) switch (try F.lookupTarget(ctx, arena, name)) {
        .found => |t| {
            if (args.focus) F.focusTarget(t);
            var lost = args;
            lost.name = null;
            return try alreadyThere(alloc, arena, "pane", name, lost);
        },
        .ambiguous, .not_found => {},
    };

    // The inline split is checked before anything opens.
    const inline_split: ?SplitDirection = if (args.split_direction) |d|
        parseSplitDirection(d) orelse
            return try errorResponse(alloc, "invalid split direction: {s}", .{d})
    else
        null;

    const first_pane_name = verb_args.newWindowFirstPaneName(args);
    return switch (try F.openWindow(ctx, arena, request, args, .{
        .first_pane_name = first_pane_name,
        .first_pane_env_name = first_pane_name orelse args.target,
        .split = inline_split,
    })) {
        .created => |note| try server.successResponse(alloc, "created", note),
        .failed => |reason| try errorResponse(alloc, "{s}", .{reason}),
    };
}

/// `+split [--pane=<pane> | --target=<window-or-pane>] [--direction=<dir>]
/// [--percent=N] [--name=<pane>] [--from-focused] ...`.
///
/// Model, beyond the window-or-pane one: `WindowHandle` and `PaneHandle` types;
/// `windowOfTarget(Target) Window`; `paneOfTarget(Target) ?Pane` (null for a
/// window); `paneTarget(Pane) Target`; `paneWindow(Pane) Window`;
/// `activePane(Window) ?Pane`; `defaultWindow(ctx) ?Window` (the active window,
/// else the most recent); `callerPane(ctx,
/// args) ?Pane` (T1079); `nameHolderIn(ctx, name, Window) ?NameHolder(Target)`;
/// `createSplit(ctx, arena, args, Window, at: Pane, SplitSpec)
/// Allocator.Error!?Pane` - the new pane, already registered under `--name`
/// (not for `.inherit`), or null when none opened; `paneId(Pane)`;
/// `windowName(ctx, Window) ?[]const u8`. Optionally `paneOnShow(Window,
/// Pane) ?bool` (false: minimized to a strip) and `view_not_served`.
pub fn split(comptime F: type, ctx: F.Context, request: Request) Allocator.Error!?[]u8 {
    const alloc = F.replyAllocator(ctx);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);

    // First thing, as on the Mac (IPCServer.swift:572).
    if (try viewRefusal(F, alloc, args)) |r| return r;

    // Idempotent: a `--name` already held in THE WINDOW THIS SPLIT LANDS IN
    // is the answer when it already is what was asked for, and a failure
    // naming what holds it when not (T2184, Mac c2057a810). A pane of that
    // name in another window does not count: pane names belong to their
    // window (T2250), so this split creates this window's own. Focusing a
    // reused pane is the caller's choice (`--focus`, T1797). `--from-focused`
    // ignores `--name`, as on the Mac. An anchor that names nothing skips the
    // check; the split below fails with the reason.
    if (args.name) |name| check: {
        if (args.from_focused) break :check;
        const anchor = try splitAnchorWindow(F, ctx, arena, args) orelse break :check;
        const holder = F.nameHolderIn(ctx, name, anchor) orelse break :check;
        switch (try split_name_collision.decide(arena, name, holder.existing, server.nonEmpty(args.view))) {
            .conflict => |msg| {
                logSplit(F, ctx, request, args, anchor, null, msg, null);
                return try errorResponse(alloc, "{s}", .{msg});
            },
            .reuse => |msg| {
                logSplit(F, ctx, request, args, anchor, null, msg, null);
                if (args.focus) F.focusTarget(holder.target);
                return try server.messageResponse(alloc, msg);
            },
        }
    }

    const ratio: f16 = if (args.percent) |percent| ratio: {
        if (percent < 1 or percent > 99) return try errorResponse(
            alloc,
            "percent must be between 1 and 99, got {d}",
            .{percent},
        );
        const r = @as(f16, @floatFromInt(100 - percent)) / 100.0;
        break :ratio @min(0.9, @max(0.1, r));
    } else 0.5;

    const dir_str = args.split_direction orelse "right";
    const direction = parseSplitDirection(dir_str) orelse
        return try errorResponse(alloc, "invalid direction: {s}", .{dir_str});

    // Where it lands. `--from-focused` (T68) is the keyboard split on the
    // focused window's active pane. Otherwise `--pane` names the exact pane;
    // `--target` a window (or a pane, whose window is used) split at its
    // active pane; neither, the pane this command was run FROM (T1079), and
    // failing that the front window's active pane.
    var window: F.WindowHandle = undefined;
    var at: F.PaneHandle = undefined;
    if (args.from_focused) {
        window = F.defaultWindow(ctx) orelse
            return try errorResponse(alloc, "no window found for split", .{});
        at = F.activePane(window) orelse
            return try errorResponse(alloc, "no surface to split", .{});
    } else if (args.pane) |pane_name| {
        const t = switch (try F.lookupTarget(ctx, arena, pane_name)) {
            .found => |t| t,
            .ambiguous => |msg| return try errorResponse(alloc, "{s}", .{msg}),
            .not_found => return try errorResponse(alloc, "pane '{s}' not found", .{pane_name}),
        };
        at = F.paneOfTarget(t) orelse
            return try errorResponse(alloc, "pane '{s}' not found", .{pane_name});
        window = F.paneWindow(at);
    } else if (args.target) |target| {
        const t = switch (try resolveTarget(F, ctx, arena, target)) {
            .target => |t| t,
            .reply => |r| return r,
        };
        window = F.windowOfTarget(t);
        at = F.activePane(window) orelse
            return try errorResponse(alloc, "target '{s}' has no surface to split", .{target});
    } else if (F.callerPane(ctx, args)) |caller| {
        at = caller;
        window = F.paneWindow(caller);
    } else {
        window = F.defaultWindow(ctx) orelse
            return try errorResponse(alloc, "no window found for split", .{});
        at = F.activePane(window) orelse
            return try errorResponse(alloc, "no surface to split", .{});
    }

    const pane = try F.createSplit(ctx, arena, args, window, at, .{
        .direction = direction,
        .ratio = ratio,
        .inherit = args.from_focused,
    }) orelse {
        // A surface with no pane is not a pane anybody can see or target:
        // say so rather than reply "created" (T2250).
        const reason = "failed to create split";
        logSplit(F, ctx, request, args, window, null, reason, null);
        return try errorResponse(alloc, "{s}", .{reason});
    };

    // `--focus` (T1797): focus the new pane, raise its window - the one focus
    // a `--target` hit uses. Without it the pane that had the keyboard keeps it.
    if (args.focus) F.focusTarget(F.paneTarget(pane));

    // The reply names the pane, its window, and - when it did not come on
    // show - that it is a strip (T2250; Mac `createdMessage`).
    const on_show: ?bool = if (@hasDecl(F, "paneOnShow")) F.paneOnShow(window, pane) else null;
    const message = try verb_args.splitCreatedMessage(arena, .{
        .name = args.name,
        .pane_id = F.paneId(pane),
        .window_name = F.windowName(ctx, window) orelse "",
        .view = server.nonEmpty(args.view),
        .on_show = on_show,
    });
    logSplit(F, ctx, request, args, window, pane, "created", on_show);
    return try server.messageResponse(alloc, message);
}

/// The window a `+split` lands in, by `split`'s precedence, for the name
/// check that runs before it: null when that names nothing.
fn splitAnchorWindow(
    comptime F: type,
    ctx: F.Context,
    arena: Allocator,
    args: verb_args.VerbArgs,
) Allocator.Error!?F.WindowHandle {
    if (args.pane) |pane_name| return switch (try F.lookupTarget(ctx, arena, pane_name)) {
        .found => |t| F.paneWindow(F.paneOfTarget(t) orelse return null),
        .ambiguous, .not_found => null,
    };
    if (args.target) |target| return switch (try F.lookupTarget(ctx, arena, target)) {
        .found => |t| F.windowOfTarget(t),
        .ambiguous, .not_found => null,
    };
    if (F.callerPane(ctx, args)) |caller| return F.paneWindow(caller);
    return F.defaultWindow(ctx);
}

/// Every `+split`, in the log (T2250; the Mac logs it at `.notice`), so the
/// next unexplained "I opened it in a side pane" can be read back: who
/// asked, where it went, and what came of it.
fn logSplit(
    comptime F: type,
    ctx: F.Context,
    request: Request,
    args: verb_args.VerbArgs,
    window: ?F.WindowHandle,
    pane: ?F.PaneHandle,
    outcome: []const u8,
    on_show: ?bool,
) void {
    const shown: []const u8 = if (on_show) |s| (if (s) "yes" else "NO (strip)") else "unknown";
    std.log.scoped(F.log_scope).info(
        "IPC +split: caller={s} window={s} pane={s} name={s} view={s} outcome={s} onShow={s}",
        .{
            request.caller_pane orelse args.caller_pane orelse "-",
            if (window) |w| F.windowName(ctx, w) orelse "-" else "-",
            if (pane) |p| F.paneId(p) else "-",
            args.name orelse "-",
            server.nonEmpty(args.view) orelse "-",
            outcome,
            shown,
        },
    );
}

/// `+rename --target=<window-or-pane> --title=<title>`: pin the window's
/// title over the tabs' until cleared; `--title=""` clears the pin (T92, Mac
/// 9c7665354) instead of pinning an empty string. A pane target renames its
/// window. A title the user typed outranks any script's (T2404).
///
/// Model: `renameWindow(ctx, Target, title: ?[]const u8) Renamed` - set the
/// pin on the target's window, or report the user's title it left alone.
pub fn rename(comptime F: type, ctx: F.Context, request: Request) Allocator.Error!?[]u8 {
    const alloc = F.replyAllocator(ctx);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try verb_args.parseVerbArgs(arena, request.arguments);
    const name = args.target orelse
        return try errorResponse(alloc, "--target is required for +rename", .{});
    const title = args.title orelse
        return try errorResponse(alloc, "--title is required for +rename", .{});
    const target = switch (try resolveTarget(F, ctx, arena, name)) {
        .target => |t| t,
        .reply => |r| return r,
    };
    return switch (F.renameWindow(ctx, target, if (title.len == 0) null else title)) {
        .renamed => try alloc.dupe(u8, ok_reply),
        .kept => |kept| try errorResponse(alloc, rename_refusal_fmt, .{ name, kept }),
    };
}

// ---------------------------------------------------------------------------
// +list's split-tree walk (T3375): one recursion over either frontend's
// `datastruct.SplitTree`, with the leaf left to the frontend.

/// The `+list` node for `handle` in `tree`. `Tree` needs only what
/// `datastruct.SplitTree` has: `isEmpty()`, and `nodes[handle.idx()]` as
/// `.leaf` (a view) or `.split` (`layout` horizontal/vertical, `ratio`,
/// `left`, `right`). `leaves.terminal(arena, view) Allocator.Error!List.Terminal`
/// builds a leaf. An empty tree is the Mac server's placeholder leaf.
pub fn listSplitNode(
    comptime Tree: type,
    arena: Allocator,
    tree: *const Tree,
    handle: Tree.Node.Handle,
    leaves: anytype,
) Allocator.Error!*const List.Node {
    const node = try arena.create(List.Node);
    if (tree.isEmpty()) {
        node.* = .{ .leaf = List.empty_terminal };
        return node;
    }
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| node.* = .{ .leaf = try leaves.terminal(arena, view) },
        .split => |s| node.* = .{ .split = .{
            .direction = switch (s.layout) {
                .horizontal => "horizontal",
                .vertical => "vertical",
            },
            .ratio = @floatCast(s.ratio),
            .left = try listSplitNode(Tree, arena, tree, s.left, leaves),
            .right = try listSplitNode(Tree, arena, tree, s.right, leaves),
        } },
    }
    return node;
}

// ---------------------------------------------------------------------------
// Tests (none lane): a fake frontend whose terminals record their writes.

const testing = std.testing;

const FakeTerm = struct {
    state: *State,

    const State = struct {
        bracketed: bool = false,
        fail_writes: bool = false,
        screen: ?[]const u8 = "",
        /// One entry per write: 'R' raw or 'B' bracketed, then the bytes.
        writes: std.ArrayList([]u8) = .empty,

        fn deinit(self: *State) void {
            for (self.writes.items) |w| testing.allocator.free(w);
            self.writes.deinit(testing.allocator);
        }
        fn record(self: *State, tag: u8, bytes: []const u8) !void {
            if (self.fail_writes) return error.QueueFull;
            const w = try testing.allocator.alloc(u8, bytes.len + 1);
            w[0] = tag;
            @memcpy(w[1..], bytes);
            try self.writes.append(testing.allocator, w);
        }
    };

    pub fn writeRaw(self: FakeTerm, bytes: []const u8) !void {
        try self.state.record('R', bytes);
    }
    pub fn writeBracketed(self: FakeTerm, bytes: []const u8) !void {
        try self.state.record('B', bytes);
    }
    pub fn pasteIsBracketed(self: FakeTerm) bool {
        return self.state.bracketed;
    }
    pub fn dumpScreen(self: FakeTerm, arena: Allocator, timing: ?*DumpTiming) ?[]const u8 {
        _ = timing;
        const s = self.state.screen orelse return null;
        return arena.dupe(u8, s) catch null;
    }
};

fn FakeFrontend(comptime line_ends: LineEnds, comptime with_not_found: bool) type {
    return struct {
        const Self = @This();
        term: FakeTerm.State = .{},
        /// What every name other than "p1" resolves to.
        others: Lookup(FakeTerm) = .not_found,

        pub const Context = *Self;
        pub const Terminal = FakeTerm;
        pub const log_scope = .ipc_verbs_test;
        pub const input_line_ends = line_ends;

        pub fn replyAllocator(_: *Self) Allocator {
            return testing.allocator;
        }
        pub fn lookupTerminal(ctx: *Self, name: []const u8) Lookup(FakeTerm) {
            if (std.mem.eql(u8, name, "p1")) return .{ .ready = .{ .state = &ctx.term } };
            return ctx.others;
        }
        pub const notFoundResponse = if (with_not_found) struct {
            fn f(_: *Self, name: []const u8, fallback: []const u8) Allocator.Error![]u8 {
                return errorResponse(testing.allocator, "ambiguous '{s}' (else: {s})", .{ name, fallback });
            }
        }.f else {};
    };
}

/// A frontend without the optional `notFoundResponse`.
fn PlainFrontend(comptime line_ends: LineEnds) type {
    const Base = FakeFrontend(line_ends, false);
    return struct {
        pub const Context = Base.Context;
        pub const Terminal = Base.Terminal;
        pub const log_scope = Base.log_scope;
        pub const input_line_ends = Base.input_line_ends;
        pub const replyAllocator = Base.replyAllocator;
        pub const lookupTerminal = Base.lookupTerminal;
    };
}

fn expectReply(reply: ?[]u8, expected: []const u8) !void {
    const r = reply orelse return error.TestExpectedReply;
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(expected, r);
}

fn req(action: []const u8, args: []const []const u8) Request {
    return .{ .action = action, .arguments = args };
}

test "+read: the last N lines, default 50, empty is success" {
    const F = PlainFrontend(.pty);
    var fe: FakeFrontend(.pty, false) = .{};
    defer fe.term.deinit();

    fe.term.screen = "a\nb\nc\n";
    try expectReply(try read(F, &fe, req("read", &.{ "--name=p1", "--lines=2" })),
        "{\"success\":true,\"data\":{\"text\":\"b\\nc\"}}");
    try expectReply(try read(F, &fe, req("read", &.{"--name=p1"})),
        "{\"success\":true,\"data\":{\"text\":\"a\\nb\\nc\"}}");
    fe.term.screen = "";
    try expectReply(try read(F, &fe, req("read", &.{"--name=p1"})),
        "{\"success\":true,\"data\":{\"text\":\"\"}}");
    fe.term.screen = null;
    try expectReply(try read(F, &fe, req("read", &.{"--name=p1"})),
        "{\"success\":false,\"error\":\"failed to read terminal content from 'p1'\"}");
    try expectReply(try read(F, &fe, req("read", &.{})),
        "{\"success\":false,\"error\":\"--name is required for +read\"}");
}

test "+read and +send-keys name each lookup failure apart" {
    const F = PlainFrontend(.pty);
    var fe: FakeFrontend(.pty, false) = .{};
    defer fe.term.deinit();

    const cases = .{
        .{ Lookup(FakeTerm).not_found, "pane 'x' not found in registry", "target 'x' not found" },
        .{ Lookup(FakeTerm).gone, "pane 'x' is no longer alive", "target 'x' is no longer alive" },
        .{ Lookup(FakeTerm).viewer, "x is a viewer pane, not a terminal", "x is a viewer pane, not a terminal" },
        .{
            Lookup(FakeTerm).not_started,
            "pane 'x' is not readable: its terminal never finished starting up",
            "target 'x' is not writable: its terminal never finished starting up",
        },
    };
    inline for (cases) |c| {
        fe.others = c[0];
        const r = try std.fmt.allocPrint(testing.allocator, "{{\"success\":false,\"error\":\"{s}\"}}", .{c[1]});
        defer testing.allocator.free(r);
        try expectReply(try read(F, &fe, req("read", &.{"--name=x"})), r);
        const s = try std.fmt.allocPrint(testing.allocator, "{{\"success\":false,\"error\":\"{s}\"}}", .{c[2]});
        defer testing.allocator.free(s);
        try expectReply(try sendKeys(F, &fe, req("send-keys", &.{ "--target=x", "--keys=hi" })), s);
    }
    try testing.expectEqual(@as(usize, 0), fe.term.writes.items.len);
}

test "a frontend's notFoundResponse replaces the not-found sentence only" {
    const F = FakeFrontend(.pty, true);
    var fe: F = .{};
    defer fe.term.deinit();
    try expectReply(try read(F, &fe, req("read", &.{"--name=x"})),
        "{\"success\":false,\"error\":\"ambiguous 'x' (else: pane 'x' not found in registry)\"}");
    try expectReply(try sendKeys(F, &fe, req("send-keys", &.{ "--target=x", "--keys=a" })),
        "{\"success\":false,\"error\":\"ambiguous 'x' (else: target 'x' not found)\"}");
    fe.others = .gone;
    try expectReply(try read(F, &fe, req("read", &.{"--name=x"})),
        "{\"success\":false,\"error\":\"pane 'x' is no longer alive\"}");
}

test "+send-keys: required arguments" {
    const F = PlainFrontend(.pty);
    var fe: FakeFrontend(.pty, false) = .{};
    defer fe.term.deinit();
    try expectReply(try sendKeys(F, &fe, req("send-keys", &.{"--keys=a"})),
        "{\"success\":false,\"error\":\"--target is required for +send-keys\"}");
    try expectReply(try sendKeys(F, &fe, req("send-keys", &.{"--target=p1"})),
        "{\"success\":false,\"error\":\"text is required for +send-keys\"}");
    try expectReply(try sendKeys(F, &fe, req("send-keys", &.{ "--target=p1", "--keys=" })),
        "{\"success\":false,\"error\":\"text is required for +send-keys\"}");
}

fn segmentsArg(alloc: Allocator, runs: []const verb_segments.Segment) ![:0]const u8 {
    return verb_segments.encode(alloc, runs);
}

fn expectWrites(state: *const FakeTerm.State, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, state.writes.items.len);
    for (expected, state.writes.items) |e, w| try testing.expectEqualStrings(e, w);
}

test "+send-keys on a pty: text runs as pastes, key runs bare, bytes untouched" {
    const F = PlainFrontend(.pty);
    var fe: FakeFrontend(.pty, false) = .{};
    defer fe.term.deinit();

    const seg = try segmentsArg(testing.allocator, &.{
        .{ .kind = .text, .bytes = "a\nb" },
        .{ .kind = .key, .bytes = "" },
        .{ .kind = .key, .bytes = "\r" },
    });
    defer testing.allocator.free(seg);
    try expectReply(try sendKeys(F, &fe, req("send-keys", &.{ "--target=p1", "--keys=a\nb\r", seg })),
        "{\"success\":true}");
    try expectWrites(&fe.term, &.{ "Ba\nb", "R\r" });

    // Flat, old CLI: still untouched on a pty.
    try expectReply(try sendKeys(F, &fe, req("send-keys", &.{ "--target=p1", "--keys=x\n" })),
        "{\"success\":true}");
    try expectWrites(&fe.term, &.{ "Ba\nb", "R\r", "Rx\n" });

    // Malformed --segments= falls back to the flat bytes.
    try expectReply(try sendKeys(F, &fe, req("send-keys", &.{ "--target=p1", "--keys=z", "--segments=!!" })),
        "{\"success\":true}");
    try expectWrites(&fe.term, &.{ "Ba\nb", "R\r", "Rx\n", "Rz" });
}

test "+send-keys on a ConPTY: LF becomes CR unless the program sees a paste" {
    const F = PlainFrontend(.conpty);
    var fe: FakeFrontend(.conpty, false) = .{};
    defer fe.term.deinit();

    // Old CLI (no --keys-resolved): the whole payload is mapped.
    try expectReply(try sendKeys(F, &fe, req("send-keys", &.{ "--target=p1", "--keys=a\nb\n" })),
        "{\"success\":true}");
    const old_expected = try verb_args.normalizeConptyInput(testing.allocator, "a\nb\n");
    defer testing.allocator.free(old_expected);
    try testing.expectEqualStrings(old_expected, fe.term.writes.items[0][1..]);

    // Resolved, program not in bracketed paste: a text run is mapped.
    const seg = try segmentsArg(testing.allocator, &.{
        .{ .kind = .text, .bytes = "a\nb" },
        .{ .kind = .key, .bytes = "\r" },
    });
    defer testing.allocator.free(seg);
    try expectReply(try sendKeys(F, &fe, req("send-keys", &.{ "--target=p1", "--keys=a\nb\r", seg, "--keys-resolved=1" })),
        "{\"success\":true}");
    const mapped = try verb_args.normalizeConptyInput(testing.allocator, "a\nb");
    defer testing.allocator.free(mapped);
    try testing.expectEqualStrings(mapped, fe.term.writes.items[1][1..]);
    try testing.expectEqualStrings("R\r", fe.term.writes.items[2]);

    // Resolved, program in bracketed paste: the LF is content and stays.
    fe.term.bracketed = true;
    try expectReply(try sendKeys(F, &fe, req("send-keys", &.{ "--target=p1", "--keys=a\nb\r", seg, "--keys-resolved=1" })),
        "{\"success\":true}");
    try testing.expectEqualStrings("Ba\nb", fe.term.writes.items[3]);
}

test "+send-keys: a refused write is answered, not dropped" {
    const F = PlainFrontend(.pty);
    var fe: FakeFrontend(.pty, false) = .{};
    defer fe.term.deinit();
    fe.term.fail_writes = true;
    try expectReply(try sendKeys(F, &fe, req("send-keys", &.{ "--target=p1", "--keys=a" })),
        "{\"success\":false,\"error\":\"failed to queue input\"}");
}

// ---------------------------------------------------------------------------
// The window-or-pane verbs over a fake frontend (T3374).

/// The target-only model calls take no context, so the fake records them here.
const FakeRecord = struct {
    var focused: usize = 0;
    var dialog = false;
    var state: ?ActivityState = null;
    var banner_set = false;
    var banner_null = false;
    var reloaded: usize = 0;
    var config_error: ?[]const u8 = null;
    var config_reloads: usize = 0;
};

const FakeTargets = struct {
    const Self = @This();

    /// What a name resolves to: "w" a window, "p" a terminal pane, "v" a
    /// viewer pane, "e" a window with no tabs, "amb" ambiguous, else nothing.
    pub const Target = enum { w, p, v, e };

    dismissed: Dismissed = .close_now,
    close_ok: bool = true,
    /// 'D' dismiss, 'C' close, in call order.
    calls: std.ArrayList(u8) = .empty,
    last_force: bool = false,

    pub const Context = *Self;
    pub const log_scope = .ipc_verbs_test;

    fn deinit(self: *Self) void {
        self.calls.deinit(testing.allocator);
    }

    pub fn replyAllocator(_: *Self) Allocator {
        return testing.allocator;
    }
    pub fn lookupTarget(_: *Self, arena: Allocator, name: []const u8) Allocator.Error!TargetLookup(Target) {
        if (std.mem.eql(u8, name, "amb"))
            return .{ .ambiguous = try std.fmt.allocPrint(arena, "'{s}' is ambiguous", .{name}) };
        if (std.meta.stringToEnum(Target, name)) |t| return .{ .found = t };
        return .not_found;
    }
    pub fn focusTarget(_: Target) void {
        FakeRecord.focused += 1;
    }
    pub fn closeConfirmationOpen(_: Target) bool {
        return FakeRecord.dialog;
    }
    pub fn dismissConfirmations(ctx: *Self, _: Target, _: []const u8) Dismissed {
        ctx.calls.append(testing.allocator, 'D') catch @panic("OOM");
        return ctx.dismissed;
    }
    pub fn closeTarget(ctx: *Self, _: Target, force: bool) bool {
        ctx.calls.append(testing.allocator, 'C') catch @panic("OOM");
        ctx.last_force = force;
        return ctx.close_ok;
    }
    pub fn setActivityState(t: Target, state: ActivityState) bool {
        if (t == .v) return false;
        FakeRecord.state = state;
        return true;
    }
    pub fn setPaneBanner(t: Target, text: ?[]const u8) BannerSet {
        return switch (t) {
            .e => .no_pane,
            .v => .viewer,
            else => {
                FakeRecord.banner_set = true;
                FakeRecord.banner_null = text == null;
                return .set;
            },
        };
    }
    pub fn reloadConfig(_: *Self, _: Allocator) Allocator.Error!?[]const u8 {
        FakeRecord.config_reloads += 1;
        return FakeRecord.config_error;
    }
    /// "v" is the only viewer: a window "w" stands for one focused on a
    /// terminal.
    pub fn reloadViewer(t: Target) ReloadOutcome {
        return switch (t) {
            .v => {
                FakeRecord.reloaded += 1;
                return .reloaded;
            },
            .p => .terminal,
            .w => .focused_terminal,
            .e => .gone,
        };
    }
};

test "+reload: a viewer reloads; terminals, an empty window and a missing name each say why" {
    const F = FakeTargets;
    var fe: F = .{};
    defer fe.deinit();
    FakeRecord.reloaded = 0;
    try expectReply(try reload(F, &fe, req("reload", &.{})), errJson("--target is required for +reload"));
    try expectReply(try reload(F, &fe, req("reload", &.{"--target=v"})), ok_json);
    try testing.expectEqual(@as(usize, 1), FakeRecord.reloaded);
    try expectReply(try reload(F, &fe, req("reload", &.{"--target=p"})), errJson("target 'p' is a terminal pane, nothing to reload"));
    try expectReply(try reload(F, &fe, req("reload", &.{"--target=w"})), errJson("focused pane of 'w' is a terminal pane, nothing to reload"));
    try expectReply(try reload(F, &fe, req("reload", &.{"--target=e"})), errJson("target 'e' is no longer alive"));
    try expectReply(try reload(F, &fe, req("reload", &.{"--target=nope"})), errJson("target 'nope' not found in registry"));
    try expectReply(try reload(F, &fe, req("reload", &.{"--target=amb"})), errJson("'amb' is ambiguous"));
    try testing.expectEqual(@as(usize, 1), FakeRecord.reloaded);
}

test "+reload --config: app-wide, refuses --target, carries the frontend's failure sentence" {
    const F = FakeTargets;
    var fe: F = .{};
    defer fe.deinit();
    FakeRecord.config_reloads = 0;
    FakeRecord.config_error = null;
    try expectReply(try reload(F, &fe, req("reload", &.{"--config"})), ok_json);
    try expectReply(try reload(F, &fe, req("reload", &.{ "--config", "--target=v" })), errJson("--config cannot be combined with --target"));
    try testing.expectEqual(@as(usize, 1), FakeRecord.config_reloads);
    FakeRecord.config_error = "config reload failed: Boom";
    defer FakeRecord.config_error = null;
    try expectReply(try reload(F, &fe, req("reload", &.{"--config"})), errJson("config reload failed: Boom"));
}

const ok_json = "{\"success\":true}";

fn errJson(comptime msg: []const u8) []const u8 {
    return "{\"success\":false,\"error\":\"" ++ msg ++ "\"}";
}

test "focus: focuses what the name resolves to, names what it cannot" {
    const F = FakeTargets;
    var fe: F = .{};
    defer fe.deinit();
    FakeRecord.focused = 0;
    try expectReply(try focus(F, &fe, req("focus", &.{"--target=p"})), ok_json);
    try expectReply(try focus(F, &fe, req("focus", &.{"--target=w"})), ok_json);
    try testing.expectEqual(@as(usize, 2), FakeRecord.focused);
    try expectReply(try focus(F, &fe, req("focus", &.{"--target=nope"})), errJson("target 'nope' not found in registry"));
    try expectReply(try focus(F, &fe, req("focus", &.{"--target=amb"})), errJson("'amb' is ambiguous"));
    try expectReply(try focus(F, &fe, req("focus", &.{})), errJson("--target is required for focus"));
    try testing.expectEqual(@as(usize, 2), FakeRecord.focused);
}

test "+close: idempotent on nothing, refuses an ambiguous name, passes --force" {
    const F = FakeTargets;
    var fe: F = .{};
    defer fe.deinit();
    FakeRecord.dialog = false;
    try expectReply(try close(F, &fe, req("close", &.{})), errJson("--target is required for +close"));
    try expectReply(try close(F, &fe, req("close", &.{"--target=gone"})), ok_json);
    try expectReply(try close(F, &fe, req("close", &.{"--target=amb"})), errJson("'amb' is ambiguous"));
    try testing.expectEqualStrings("", fe.calls.items);

    try expectReply(try close(F, &fe, req("close", &.{"--target=p"})), ok_json);
    try testing.expect(!fe.last_force);
    try expectReply(try close(F, &fe, req("close", &.{ "--target=w", "--force" })), ok_json);
    try testing.expect(fe.last_force);
    try testing.expectEqualStrings("CC", fe.calls.items);

    fe.close_ok = false;
    try expectReply(try close(F, &fe, req("close", &.{"--target=p"})), errJson("failed to close 'p'"));
}

test "+close under a confirmation: refused without --force, each dismissal outcome with it" {
    const F = FakeTargets;
    var fe: F = .{};
    defer fe.deinit();
    FakeRecord.dialog = true;
    defer FakeRecord.dialog = false;

    try expectReply(try close(F, &fe, req("close", &.{"--target=p"})), errJson(
        "'p' is waiting on a close confirmation in its window, so nothing closed yet; answer it there, or run +close --force (no confirmation, no undo)",
    ));
    try testing.expectEqualStrings("", fe.calls.items);

    // GTK's shape: dismissed, close now.
    fe.dismissed = .close_now;
    try expectReply(try close(F, &fe, req("close", &.{ "--target=p", "--force" })), ok_json);
    try testing.expectEqualStrings("DC", fe.calls.items);

    // win32's: the frontend closes once the dialog's loop unwinds.
    fe.dismissed = .closing;
    try expectReply(try close(F, &fe, req("close", &.{ "--target=p", "--force" })), ok_json);
    try testing.expectEqualStrings("DCD", fe.calls.items);

    fe.dismissed = .queue_full;
    try expectReply(try close(F, &fe, req("close", &.{ "--target=w", "--force" })), errJson(
        "'w': the confirmation was dismissed but too many forced closes are already waiting; run +close --force again",
    ));
    try testing.expectEqualStrings("DCDD", fe.calls.items);
}

test "+set-state: arguments, the three states, a viewer pane refused" {
    const F = FakeTargets;
    var fe: F = .{};
    defer fe.deinit();
    try expectReply(try setState(F, &fe, req("set-state", &.{"--state=busy"})), errJson("--target is required for +set-state"));
    try expectReply(try setState(F, &fe, req("set-state", &.{"--target=p"})), errJson("--state is required for +set-state"));
    try expectReply(try setState(F, &fe, req("set-state", &.{ "--target=p", "--state=asleep" })), errJson("invalid state 'asleep': must be idle, busy, or needs_input"));
    try expectReply(try setState(F, &fe, req("set-state", &.{ "--target=nope", "--state=idle" })), errJson("target 'nope' not found in registry"));
    try expectReply(try setState(F, &fe, req("set-state", &.{ "--target=amb", "--state=idle" })), errJson("'amb' is ambiguous"));
    inline for (.{ "idle", "busy", "needs_input" }) |s| {
        FakeRecord.state = null;
        try expectReply(try setState(F, &fe, req("set-state", &.{ "--target=w", "--state=" ++ s })), ok_json);
        try testing.expectEqual(std.meta.stringToEnum(ActivityState, s).?, FakeRecord.state.?);
    }
    try expectReply(try setState(F, &fe, req("set-state", &.{ "--target=v", "--state=idle" })), errJson("v is a viewer pane, not a terminal"));
}

test "+set-banner: set, clear, and the no-pane / viewer / missing sentences" {
    const F = FakeTargets;
    var fe: F = .{};
    defer fe.deinit();
    try expectReply(try setBanner(F, &fe, req("set-banner", &.{"hello"})), errJson("--target is required for +set-banner"));

    FakeRecord.banner_set = false;
    try expectReply(try setBanner(F, &fe, req("set-banner", &.{ "--target=p", "hello" })), ok_json);
    try testing.expect(FakeRecord.banner_set and !FakeRecord.banner_null);
    try expectReply(try setBanner(F, &fe, req("set-banner", &.{ "--target=w", "--clear" })), ok_json);
    try testing.expect(FakeRecord.banner_null);

    try expectReply(try setBanner(F, &fe, req("set-banner", &.{ "--target=e", "x" })), errJson("target 'e' has no focused pane"));
    try expectReply(try setBanner(F, &fe, req("set-banner", &.{ "--target=v", "x" })), errJson("v is a viewer pane, not a terminal"));
    try expectReply(try setBanner(F, &fe, req("set-banner", &.{ "--target=nope", "x" })), errJson("target 'nope' not found in registry"));
}

test "the core's activity-state tokens are the ones +set-state takes" {
    const Core = @import("../../terminal/osc.zig").Command.ActivityState;
    inline for (@typeInfo(ActivityState).@"enum".fields) |f|
        try testing.expect(@hasField(Core, f.name));
    try testing.expectEqual(@typeInfo(Core).@"enum".fields.len, @typeInfo(ActivityState).@"enum".fields.len);
}

// ---------------------------------------------------------------------------
// The create verbs (T3375): a fake with three windows. Window 1 ("one") holds
// pane "11"; window 2 ("two") has no tabs; window 3 is unnamed and holds pane
// "31". A pane's window is its first digit.

const FakeCreate = struct {
    const Self = @This();

    pub const Target = union(enum) { window: u8, pane: []const u8 };
    pub const WindowHandle = u8;
    pub const PaneHandle = []const u8;
    pub const Context = *Self;
    pub const log_scope = .ipc_verbs_test;

    var on_show: ?bool = null;

    front: ?u8 = 1,
    caller: ?[]const u8 = null,
    holder: ?NameHolder(Target) = null,
    split_ok: bool = true,
    open_result: Opened = .{ .created = null },
    kept: ?[]const u8 = null,

    // What was asked of it.
    plan: ?WindowPlan = null,
    split_at: ?[]const u8 = null,
    spec: ?SplitSpec = null,
    renamed_to: ?(?[]const u8) = null,

    pub fn replyAllocator(_: *Self) Allocator {
        return testing.allocator;
    }
    pub fn lookupTarget(_: *Self, arena: Allocator, name: []const u8) Allocator.Error!TargetLookup(Target) {
        if (std.mem.eql(u8, name, "amb"))
            return .{ .ambiguous = try std.fmt.allocPrint(arena, "'{s}' is ambiguous", .{name}) };
        if (std.mem.eql(u8, name, "w1")) return .{ .found = .{ .window = 1 } };
        if (std.mem.eql(u8, name, "w2")) return .{ .found = .{ .window = 2 } };
        if (std.mem.eql(u8, name, "p11")) return .{ .found = .{ .pane = "11" } };
        if (std.mem.eql(u8, name, "p31")) return .{ .found = .{ .pane = "31" } };
        return .not_found;
    }
    pub fn lookupWindowName(ctx: *Self, arena: Allocator, name: []const u8) Allocator.Error!TargetLookup(Target) {
        return switch (try lookupTarget(ctx, arena, name)) {
            .ambiguous => .{ .ambiguous = "" },
            else => |l| l,
        };
    }
    pub fn isPane(t: Target) bool {
        return t == .pane;
    }
    pub fn focusTarget(_: Target) void {
        FakeRecord.focused += 1;
    }
    pub fn windowOfTarget(t: Target) u8 {
        return switch (t) {
            .window => |w| w,
            .pane => |p| paneWindow(p),
        };
    }
    pub fn paneOfTarget(t: Target) ?[]const u8 {
        return switch (t) {
            .pane => |p| p,
            .window => null,
        };
    }
    pub fn paneTarget(p: []const u8) Target {
        return .{ .pane = p };
    }
    pub fn paneWindow(p: []const u8) u8 {
        return p[0] - '0';
    }
    pub fn activePane(w: u8) ?[]const u8 {
        return switch (w) {
            1 => "11",
            3 => "31",
            else => null,
        };
    }
    pub fn defaultWindow(ctx: *Self) ?u8 {
        return ctx.front;
    }
    pub fn callerPane(ctx: *Self, _: verb_args.VerbArgs) ?[]const u8 {
        return ctx.caller;
    }
    pub fn nameHolderIn(ctx: *Self, _: []const u8, _: u8) ?NameHolder(Target) {
        return ctx.holder;
    }
    pub fn createSplit(
        ctx: *Self,
        _: Allocator,
        _: verb_args.VerbArgs,
        window: u8,
        at: []const u8,
        spec: SplitSpec,
    ) Allocator.Error!?[]const u8 {
        ctx.split_at = at;
        ctx.spec = spec;
        if (!ctx.split_ok) return null;
        return if (window == 1) "12" else "32";
    }
    pub fn paneId(p: []const u8) []const u8 {
        return p;
    }
    pub fn windowName(_: *Self, w: u8) ?[]const u8 {
        return switch (w) {
            1 => "one",
            2 => "two",
            else => null,
        };
    }
    pub fn paneOnShow(_: u8, _: []const u8) ?bool {
        return on_show;
    }
    pub fn openWindow(
        ctx: *Self,
        _: Allocator,
        _: Request,
        _: verb_args.VerbArgs,
        plan: WindowPlan,
    ) Allocator.Error!Opened {
        ctx.plan = plan;
        return ctx.open_result;
    }
    pub fn renameWindow(ctx: *Self, _: Target, title: ?[]const u8) Renamed {
        if (ctx.kept) |k| return .{ .kept = k };
        ctx.renamed_to = title;
        return .renamed;
    }
};

/// `{"success":true,"message":<msg>}`.
fn msgJson(comptime msg: []const u8) []const u8 {
    return "{\"success\":true,\"message\":\"" ++ msg ++ "\"}";
}

fn outcomeJson(comptime outcome: []const u8) []const u8 {
    return "{\"success\":true,\"outcome\":\"" ++ outcome ++ "\"}";
}

test "+new-window: an existing window or pane is the answer, and the note names what was dropped" {
    const F = FakeCreate;
    var fe: F = .{};
    FakeRecord.focused = 0;

    try expectReply(try newWindow(F, &fe, req("new-window", &.{"--target=w1"})), outcomeJson("focused"));
    try testing.expectEqual(@as(usize, 0), FakeRecord.focused);
    try expectReply(try newWindow(F, &fe, req("new-window", &.{ "--target=w1", "--focus" })), outcomeJson("focused"));
    try testing.expectEqual(@as(usize, 1), FakeRecord.focused);
    try expectReply(
        try newWindow(F, &fe, req("new-window", &.{ "--target=w1", "--command=ls" })),
        "{\"success\":true,\"outcome\":\"focused\",\"note\":\"target 'w1' already exists; kept it. Ignored: --command. +close it first to recreate.\"}",
    );
    // `--name` alone answers for its pane; `--name` itself is not "dropped".
    try expectReply(
        try newWindow(F, &fe, req("new-window", &.{ "--name=p11", "--command=ls", "--focus" })),
        "{\"success\":true,\"outcome\":\"focused\",\"note\":\"pane 'p11' already exists; focused it. Ignored: --command. +close it first to recreate.\"}",
    );
    try testing.expectEqual(@as(usize, 2), FakeRecord.focused);

    // A pane's name is never a window's (T2250), nor is one panes share.
    try expectReply(try newWindow(F, &fe, req("new-window", &.{"--target=p11"})), errJson("'p11' is already the name of a pane, so no window can take it. Use another --target."));
    try expectReply(try newWindow(F, &fe, req("new-window", &.{"--target=amb"})), errJson("'amb' is already the name of a pane, so no window can take it. Use another --target."));
    try testing.expect(fe.plan == null);
}

test "+new-window: checks before anything opens, then the plan the frontend opens" {
    const F = FakeCreate;
    var fe: F = .{};

    try expectReply(try newWindow(F, &fe, req("new-window", &.{ "--view=a.md", "--command=ls" })), errJson(verb_args.view_command_conflict_error));
    try expectReply(try newWindow(F, &fe, req("new-window", &.{ "--target=new", "--split=diagonal" })), errJson("invalid split direction: diagonal"));
    try testing.expect(fe.plan == null);

    // `--name` with no inline split names the first pane.
    try expectReply(try newWindow(F, &fe, req("new-window", &.{ "--target=new", "--name=doc" })), outcomeJson("created"));
    try testing.expectEqualStrings("doc", fe.plan.?.first_pane_name.?);
    try testing.expectEqualStrings("doc", fe.plan.?.first_pane_env_name.?);
    try testing.expect(fe.plan.?.split == null);

    // With one, `--name` is the split's and the first pane carries the window's.
    try expectReply(try newWindow(F, &fe, req("new-window", &.{ "--target=new", "--name=doc", "--split=down" })), outcomeJson("created"));
    try testing.expect(fe.plan.?.first_pane_name == null);
    try testing.expectEqualStrings("new", fe.plan.?.first_pane_env_name.?);
    try testing.expectEqual(SplitDirection.down, fe.plan.?.split.?);

    // `--from-focused` with no remote parent: a plain window, `--target` dropped.
    fe.plan = null;
    try expectReply(try newWindow(F, &fe, req("new-window", &.{ "--from-focused", "--target=w1", "--split=down" })), outcomeJson("created"));
    try testing.expect(fe.plan.?.first_pane_env_name == null and fe.plan.?.split == null);

    fe.open_result = .{ .created = "built elsewhere" };
    try expectReply(try newWindow(F, &fe, req("new-window", &.{})), "{\"success\":true,\"outcome\":\"created\",\"note\":\"built elsewhere\"}");
    fe.open_result = .{ .failed = "failed to create window" };
    try expectReply(try newWindow(F, &fe, req("new-window", &.{})), errJson("failed to create window"));
}

test "+split: argument checks and every anchor failure, in win32's order" {
    const F = FakeCreate;
    var fe: F = .{};

    try expectReply(try split(F, &fe, req("split", &.{"--percent=0"})), errJson("percent must be between 1 and 99, got 0"));
    try expectReply(try split(F, &fe, req("split", &.{"--direction=diagonal"})), errJson("invalid direction: diagonal"));
    try expectReply(try split(F, &fe, req("split", &.{ "--view=a.md", "--command=ls" })), errJson(verb_args.view_command_conflict_error));
    try expectReply(try split(F, &fe, req("split", &.{"--pane=nope"})), errJson("pane 'nope' not found"));
    try expectReply(try split(F, &fe, req("split", &.{"--pane=w1"})), errJson("pane 'w1' not found"));
    try expectReply(try split(F, &fe, req("split", &.{"--pane=amb"})), errJson("'amb' is ambiguous"));
    try expectReply(try split(F, &fe, req("split", &.{"--target=nope"})), errJson("target 'nope' not found in registry"));
    try expectReply(try split(F, &fe, req("split", &.{"--target=amb"})), errJson("'amb' is ambiguous"));
    try expectReply(try split(F, &fe, req("split", &.{"--target=w2"})), errJson("target 'w2' has no surface to split"));
    fe.front = null;
    try expectReply(try split(F, &fe, req("split", &.{})), errJson("no window found for split"));
    try expectReply(try split(F, &fe, req("split", &.{"--from-focused"})), errJson("no window found for split"));
    fe.front = 2;
    try expectReply(try split(F, &fe, req("split", &.{})), errJson("no surface to split"));
    try testing.expect(fe.split_at == null);

    fe.front = 1;
    fe.split_ok = false;
    try expectReply(try split(F, &fe, req("split", &.{})), errJson("failed to create split"));
}

test "+split: where it lands, the ratio, and the reply that names the pane" {
    const F = FakeCreate;
    var fe: F = .{};
    F.on_show = null;
    FakeRecord.focused = 0;

    // A window target splits its active pane, 50/50, to the right.
    try expectReply(try split(F, &fe, req("split", &.{"--target=w1"})), msgJson("created pane 12 in window 'one'"));
    try testing.expectEqualStrings("11", fe.split_at.?);
    try testing.expectEqual(SplitDirection.right, fe.spec.?.direction);
    try testing.expectEqual(@as(f16, 0.5), fe.spec.?.ratio);
    try testing.expect(!fe.spec.?.inherit);
    try testing.expectEqual(@as(usize, 0), FakeRecord.focused);

    // `--percent` is the NEW pane's share; the tree keeps the other side's.
    try expectReply(try split(F, &fe, req("split", &.{ "--pane=p11", "--name=doc", "--percent=30", "--direction=down", "--focus" })), msgJson("created pane 'doc' (12) in window 'one'"));
    try testing.expectEqual(@as(f16, 0.7), fe.spec.?.ratio);
    try testing.expectEqual(SplitDirection.down, fe.spec.?.direction);
    try testing.expectEqual(@as(usize, 1), FakeRecord.focused);

    // No anchor: the caller's own pane, before the front window.
    fe.caller = "31";
    try expectReply(try split(F, &fe, req("split", &.{})), msgJson("created pane 32 in window ''"));
    try testing.expectEqualStrings("31", fe.split_at.?);

    // `--from-focused` ignores every anchor and inherits.
    try expectReply(try split(F, &fe, req("split", &.{ "--from-focused", "--pane=nope" })), msgJson("created pane 12 in window 'one'"));
    try testing.expectEqualStrings("11", fe.split_at.?);
    try testing.expect(fe.spec.?.inherit);

    F.on_show = false;
    defer F.on_show = null;
    try expectReply(try split(F, &fe, req("split", &.{"--target=w1"})), msgJson("created pane 12 in window 'one'; it is minimized to a strip, since its row has no room for it on show"));
}

test "+split --name: a holder in the landing window is reused or refused, never split beside" {
    const F = FakeCreate;
    var fe: F = .{};
    FakeRecord.focused = 0;

    fe.holder = .{ .target = .{ .pane = "11" }, .existing = .{ .kind = .terminal, .window_name = "one" } };
    try expectReply(try split(F, &fe, req("split", &.{ "--target=w1", "--name=doc", "--focus" })), msgJson("pane 'doc' already exists in this window ('one'); reused it, no split created"));
    try testing.expectEqual(@as(usize, 1), FakeRecord.focused);

    fe.holder = .{ .target = .{ .window = 2 }, .existing = .{ .kind = .window, .window_name = "doc" } };
    try expectReply(try split(F, &fe, req("split", &.{ "--target=w1", "--name=doc" })), errJson("'doc' is already the name of a window, so no pane can take it. Use another --name."));
    try testing.expect(fe.split_at == null);

    // `--from-focused` ignores `--name`, so no holder stops it.
    try expectReply(try split(F, &fe, req("split", &.{ "--from-focused", "--name=doc" })), msgJson("created pane 'doc' (12) in window 'one'"));
}

test "+rename: arguments, a missing or shared name, a user's title kept, an empty title clears" {
    const F = FakeCreate;
    var fe: F = .{};
    try expectReply(try rename(F, &fe, req("rename", &.{"--title=x"})), errJson("--target is required for +rename"));
    try expectReply(try rename(F, &fe, req("rename", &.{"--target=w1"})), errJson("--title is required for +rename"));
    try expectReply(try rename(F, &fe, req("rename", &.{ "--target=nope", "--title=x" })), errJson("target 'nope' not found in registry"));
    try expectReply(try rename(F, &fe, req("rename", &.{ "--target=amb", "--title=x" })), errJson("'amb' is ambiguous"));

    try expectReply(try rename(F, &fe, req("rename", &.{ "--target=p11", "--title=Build" })), ok_json);
    try testing.expectEqualStrings("Build", fe.renamed_to.?.?);
    try expectReply(try rename(F, &fe, req("rename", &.{ "--target=w1", "--title=" })), ok_json);
    try testing.expect(fe.renamed_to.? == null);

    fe.kept = "My notes";
    try expectReply(try rename(F, &fe, req("rename", &.{ "--target=w1", "--title=x" })), errJson("window 'w1' was renamed by the user ('My notes'); +rename leaves a user's title alone until they clear it"));
}

test "parseSplitDirection takes exactly the four CLI words" {
    try testing.expectEqual(SplitDirection.right, parseSplitDirection("right").?);
    try testing.expectEqual(SplitDirection.up, parseSplitDirection("up").?);
    try testing.expect(parseSplitDirection("Right") == null);
    try testing.expect(parseSplitDirection("") == null);
}

test "listSplitNode: an empty tree is the placeholder, splits nest with their ratio" {
    const FakeTree = struct {
        nodes: []const Node,

        const Node = union(enum) {
            leaf: []const u8,
            split: Split,

            const Handle = enum(u8) {
                root = 0,
                _,
                fn idx(h: Handle) usize {
                    return @intFromEnum(h);
                }
            };
        };
        const Split = struct {
            layout: enum { horizontal, vertical },
            ratio: f16,
            left: Node.Handle,
            right: Node.Handle,
        };
        fn isEmpty(self: *const @This()) bool {
            return self.nodes.len == 0;
        }
    };
    const Leaves = struct {
        active: []const u8,
        pub fn terminal(self: @This(), arena: Allocator, view: []const u8) Allocator.Error!List.Terminal {
            var t = List.empty_terminal;
            t.id = try arena.dupe(u8, view);
            t.focused = std.mem.eql(u8, view, self.active);
            return t;
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const empty: FakeTree = .{ .nodes = &.{} };
    const placeholder = try listSplitNode(FakeTree, arena, &empty, .root, Leaves{ .active = "" });
    try testing.expectEqualStrings(List.empty_terminal.id, placeholder.leaf.id);

    // a | (b / c)
    const tree: FakeTree = .{ .nodes = &.{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.25, .left = @enumFromInt(1), .right = @enumFromInt(2) } },
        .{ .leaf = "a" },
        .{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = @enumFromInt(3), .right = @enumFromInt(4) } },
        .{ .leaf = "b" },
        .{ .leaf = "c" },
    } };
    const root = try listSplitNode(FakeTree, arena, &tree, .root, Leaves{ .active = "c" });
    try testing.expectEqualStrings("horizontal", root.split.direction);
    try testing.expectEqual(@as(f64, 0.25), root.split.ratio);
    try testing.expectEqualStrings("a", root.split.left.leaf.id);
    try testing.expect(!root.split.left.leaf.focused);
    const right = root.split.right.split;
    try testing.expectEqualStrings("vertical", right.direction);
    try testing.expectEqualStrings("b", right.left.leaf.id);
    try testing.expect(right.right.leaf.focused);
}
