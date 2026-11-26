//! The GTK machine chooser's model (T3674, Linux L11a-2): which machines it
//! lists, what each row and the detail header say, and which of a machine's
//! sessions are shown in what order. Pure, so it runs in the `none` lane;
//! `MachineChooser.zig` keeps the widgets, the workers and the opens.
//!
//! Almost every rule is win32's, which is Mac's word for word, so the three
//! seats cannot drift: the row and detail wording (`chooser_rows`), the
//! roster's filter, labels and Resume target (`chooser_sessions`), the sort
//! (`chooser_session_sort`) and the hover sentences (`chooser_help`). What
//! lives here is only the glue the GTK dialog needs between them.
const std = @import("std");

pub const chooser_rows = @import("../win32/chooser_rows.zig");
pub const chooser_sessions = @import("../win32/chooser_sessions.zig");
pub const chooser_session_sort = @import("../win32/chooser_session_sort.zig");
pub const chooser_help = @import("../win32/chooser_help.zig");

/// The local machine's row id. Never a relay device id: those are UUIDs.
pub const local_id = "local";

/// The local machine's detail header. Mac reads "This Mac", Windows "This
/// PC" (what each shell calls it); a Linux desktop has no house name for it,
/// so the plain one.
pub const local_detail_title = "This Computer";

pub const Kind = enum { local, relay };

/// One row of the machine list. Strings borrow the chooser's arena.
pub const Machine = struct {
    kind: Kind,
    /// `local_id`, or the relay device id.
    id: []const u8,
    name: []const u8,
    hostname: ?[]const u8 = null,
    presence: chooser_rows.Presence = .checking,

    pub fn isLocal(self: Machine) bool {
        return self.kind == .local;
    }

    /// The row as the list draws it (win32's `localRow` / `deviceRow`).
    pub fn rowText(self: Machine) chooser_rows.RowText {
        return switch (self.kind) {
            .local => chooser_rows.localRow(),
            .relay => chooser_rows.deviceRow(self.name, self.hostname, self.presence),
        };
    }

    /// The detail pane's title: "This Computer" for Local, else the name.
    pub fn detailTitle(self: Machine) []const u8 {
        return switch (self.kind) {
            .local => local_detail_title,
            .relay => self.name,
        };
    }

    /// The detail pane's subtitle: Mac's "N sessions" once the roster has
    /// loaded, then the machine's reachability and hostname
    /// (`chooser_rows.deviceDetail`). Local is "This machine".
    pub fn detailSubtitle(self: Machine, buf: []u8, sessions: ?usize) []const u8 {
        var inner: [256]u8 = undefined;
        const tail: []const u8 = switch (self.kind) {
            .local => "This machine",
            .relay => chooser_rows.deviceDetail(&inner, self.name, self.hostname, self.presence).subtitle,
        };
        const n = sessions orelse return copy(buf, tail);
        var cb: [32]u8 = undefined;
        const count = chooser_sessions.countLabel(&cb, n);
        return std.fmt.bufPrint(buf, "{s} \u{00b7} {s}", .{ count, tail }) catch copy(buf, tail);
    }
};

fn copy(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// The index to select after the list was rebuilt: the row whose id was
/// selected before (a refresh keeps the user's place), else the first row.
/// Null only for an empty list.
pub fn reselect(ids: []const []const u8, previous: ?[]const u8) ?usize {
    if (ids.len == 0) return null;
    if (previous) |p| for (ids, 0..) |id, i| if (std.mem.eql(u8, id, p)) return i;
    return 0;
}

// ---------------------------------------------------------------------
// The roster
// ---------------------------------------------------------------------

/// One roster session as the chooser reads it: the shared row model, and
/// whether one of our panes holds it (Show rather than Resume).
pub const Entry = struct {
    session: chooser_sessions.Session,
    open_locally: bool = false,
};

/// The most sessions one machine's roster shows.
pub const max_rows = 256;

/// Which roster entries are shown, in what order: only actionable ones
/// (`chooser_sessions.isActionable` - a session still running, and not held
/// by a viewer that is not ours), sorted by `order` on the label each row
/// shows, ties by id (`chooser_session_sort.less`). `labels[i]` is entry
/// i's label. No CPU readings yet, so a CPU sort orders by name.
pub fn displayed(
    out: []usize,
    entries: []const Entry,
    labels: []const []const u8,
    order: chooser_session_sort.Order,
) []usize {
    std.debug.assert(labels.len == entries.len);
    var n: usize = 0;
    for (entries, 0..) |e, i| {
        if (n == out.len) break;
        if (!chooser_sessions.isActionable(e.session, e.open_locally)) continue;
        out[n] = i;
        n += 1;
    }
    const Ctx = struct {
        entries: []const Entry,
        labels: []const []const u8,
        order: chooser_session_sort.Order,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return chooser_session_sort.less(ctx.order, .{
                .name = ctx.labels[a],
                .cpu = 0,
                .id = ctx.entries[a].session.id,
            }, .{
                .name = ctx.labels[b],
                .cpu = 0,
                .id = ctx.entries[b].session.id,
            });
        }
    };
    std.sort.pdq(usize, out[0..n], Ctx{ .entries = entries, .labels = labels, .order = order }, Ctx.lessThan);
    return out[0..n];
}

/// A session card's second line: its working directory, then what it runs
/// (`chooser_sessions.command`), joined by a middle dot. Empty when neither
/// is known.
pub fn subline(buf: []u8, s: chooser_sessions.Session) []const u8 {
    const cwd = nonEmpty(s.cwd);
    const cmd = chooser_sessions.command(s);
    if (cwd != null and cmd != null)
        return std.fmt.bufPrint(buf, "{s} \u{00b7} {s}", .{ cwd.?, cmd.? }) catch copy(buf, cwd.?);
    return copy(buf, cwd orelse cmd orelse "");
}

/// The card's action button (Mac `sessionDetailRow`, T1746): a session open
/// in one of our windows is brought forward, any other is resumed.
pub fn actionLabel(open_locally: bool) []const u8 {
    return if (open_locally) "Show" else "Resume";
}

pub fn actionHelp(open_locally: bool) []const u8 {
    return if (open_locally) chooser_help.show_session else chooser_help.resume_session;
}

/// The roster region's placeholder when it has no rows to draw: the state's
/// own sentence, else "No active sessions" for a loaded but empty list.
pub fn placeholder(state: chooser_sessions.State, shown: usize) ?[]const u8 {
    if (chooser_sessions.stateText(state)) |t| return t;
    if (shown == 0) return chooser_sessions.empty_text;
    return null;
}

/// The roster state a failed fetch lands in: a refused credential and a
/// protocol skew are told apart from "couldn't reach", because each sends
/// the user somewhere different (T319, T628).
pub fn failureState(err: anyerror) chooser_sessions.State {
    if (err == error.Unauthorized) return .unauthorized;
    return switch (dial_failure.classify(err)) {
        .incompatible => .incompatible,
        .unauthorized => .unauthorized,
        .unreachable_machine => .failed,
    };
}

const dial_failure = @import("../win32/dial_failure.zig");

// ---------------------------------------------------------------------
// The account row (T3575): win32's words (`relay_account_text`), Mac's
// composition - the email over Sign Out, or the Sign in with Google button
// alone - plus one sentence only Linux needs: where the sign-in is kept.
// ---------------------------------------------------------------------

pub const relay_account_text = @import("../win32/relay_account_text.zig");

/// Which account operation is running, if any.
pub const Busy = enum { none, sign_in, sign_out };

pub const AccountInput = struct {
    /// The stored account's email; null when nothing is stored.
    email: ?[]const u8 = null,
    /// A `GHOSTTY_RELAY_TOKEN` stands in for an account (a developer's).
    env_token: bool = false,
    /// This build carries a Google OAuth client id.
    configured: bool = true,
    busy: Busy = .none,
};

pub const AccountView = struct {
    /// The row's line; "" draws no line (Mac's signed-out row is the button
    /// alone, win32 T316).
    status: []const u8,
    /// The button's caption; null hides it (an unconfigured build has
    /// nothing to press, win32 T747).
    button: ?[]const u8,
    sensitive: bool,
    /// Sign Out when an account is stored; else Sign In.
    signs_out: bool,
};

pub fn accountView(buf: []u8, in: AccountInput) AccountView {
    const email = nonEmpty(in.email);
    const stored = email != null;
    if (in.busy != .none) return .{
        .status = if (in.busy == .sign_in)
            relay_account_text.statusText(email, true, in.configured, "")
        else
            "Signing out\u{2026}",
        .button = if (in.busy == .sign_in)
            relay_account_text.buttonLabel(false, true)
        else
            relay_account_text.buttonLabel(true, false),
        .sensitive = false,
        .signs_out = in.busy == .sign_out,
    };
    const status: []const u8 = if (email) |e|
        (std.fmt.bufPrint(buf, "Signed in as {s}", .{e}) catch e)
    else if (in.env_token)
        "Signed in as your account"
    else
        relay_account_text.statusText(null, false, in.configured, "");
    // Sign Out needs no client id; Sign In does.
    const button: ?[]const u8 = if (stored)
        relay_account_text.buttonLabel(true, false)
    else if (in.configured)
        relay_account_text.buttonLabel(false, false)
    else
        null;
    return .{ .status = status, .button = button, .sensitive = true, .signs_out = stored };
}

/// The line under a stored account when it lives in the 0600 file rather
/// than a keyring (`relay_account.location() == .file`). WSL runs no keyring
/// daemon, so this is the WSL default; the Mac (Keychain) and Windows
/// (DPAPI) rows never need it. `path` is shown under `~` when it is in
/// `home`.
pub fn storeNote(buf: []u8, path: []const u8, home: ?[]const u8) []const u8 {
    var shown = path;
    var tilde = false;
    if (nonEmpty(home)) |h| {
        const hh = std.mem.trimRight(u8, h, "/");
        if (hh.len > 0 and path.len > hh.len + 1 and std.mem.startsWith(u8, path, hh) and path[hh.len] == '/') {
            shown = path[hh.len + 1 ..];
            tilde = true;
        }
    }
    return std.fmt.bufPrint(
        buf,
        "No keyring is running, so your sign-in is kept in a private file only you can read ({s}{s}).",
        .{ if (tilde) "~/" else "", shown },
    ) catch "No keyring is running, so your sign-in is kept in a private file only you can read.";
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "Local reads Local in the list and This Computer in the detail" {
    const m: Machine = .{ .kind = .local, .id = local_id, .name = "Local" };
    try testing.expectEqualStrings("Local", m.rowText().title);
    try testing.expectEqualStrings("This machine", m.rowText().subtitle);
    try testing.expectEqualStrings(local_detail_title, m.detailTitle());
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("This machine", m.detailSubtitle(&buf, null));
    try testing.expectEqualStrings("2 sessions \u{00b7} This machine", m.detailSubtitle(&buf, 2));
}

test "a relay row names its presence and a hostname that adds something" {
    const m: Machine = .{ .kind = .relay, .id = "d1", .name = "box", .hostname = "box.lan", .presence = .online };
    try testing.expectEqualStrings("box", m.rowText().title);
    try testing.expectEqualStrings("box.lan", m.rowText().subtitle);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Online \u{00b7} box.lan", m.detailSubtitle(&buf, null));
    try testing.expectEqualStrings("1 session \u{00b7} Online \u{00b7} box.lan", m.detailSubtitle(&buf, 1));
    const same: Machine = .{ .kind = .relay, .id = "d2", .name = "Box", .hostname = "box", .presence = .checking };
    try testing.expectEqualStrings("Relay device", same.rowText().subtitle);
    try testing.expectEqualStrings("Checking status", same.detailSubtitle(&buf, null));
}

test "reselect keeps the selected id, else the first row" {
    const ids = [_][]const u8{ "local", "a", "b" };
    try testing.expectEqual(@as(?usize, 2), reselect(&ids, "b"));
    try testing.expectEqual(@as(?usize, 0), reselect(&ids, "gone"));
    try testing.expectEqual(@as(?usize, 0), reselect(&ids, null));
    try testing.expectEqual(@as(?usize, null), reselect(&.{}, "a"));
}

test "displayed: only running sessions not held elsewhere, sorted by label then id" {
    const entries = [_]Entry{
        .{ .session = .{ .id = "s1", .alive = true } },
        .{ .session = .{ .id = "s2", .alive = false } }, // exited: never a row
        .{ .session = .{ .id = "s3", .alive = true, .attached = true } }, // another viewer's
        .{ .session = .{ .id = "s4", .alive = true, .attached = true }, .open_locally = true }, // ours: Show
        .{ .session = .{ .id = "s0", .alive = true } },
    };
    const labels = [_][]const u8{ "zsh", "x", "y", "Build", "zsh" };
    var out: [8]usize = undefined;
    const asc = displayed(&out, &entries, &labels, chooser_session_sort.initial);
    try testing.expectEqualSlices(usize, &.{ 3, 4, 0 }, asc);
    var out2: [8]usize = undefined;
    const desc = displayed(&out2, &entries, &labels, .{ .key = .name, .ascending = false });
    // Ties stay ascending by id whichever way the column points.
    try testing.expectEqualSlices(usize, &.{ 4, 0, 3 }, desc);
}

test "displayed never writes past its buffer" {
    const entries = [_]Entry{
        .{ .session = .{ .id = "a", .alive = true } },
        .{ .session = .{ .id = "b", .alive = true } },
        .{ .session = .{ .id = "c", .alive = true } },
    };
    const labels = [_][]const u8{ "a", "b", "c" };
    var out: [2]usize = undefined;
    try testing.expectEqual(@as(usize, 2), displayed(&out, &entries, &labels, chooser_session_sort.initial).len);
}

test "subline joins the folder and the command" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/src \u{00b7} make", subline(&buf, .{ .cwd = "/src", .fg_cmd = "make" }));
    try testing.expectEqualStrings("/src", subline(&buf, .{ .cwd = "/src" }));
    try testing.expectEqualStrings("vim x", subline(&buf, .{ .argv = "vim x" }));
    try testing.expectEqualStrings("", subline(&buf, .{ .cwd = "" }));
}

test "the action button and its help follow whether the session is open here" {
    try testing.expectEqualStrings("Show", actionLabel(true));
    try testing.expectEqualStrings("Resume", actionLabel(false));
    try testing.expectEqualStrings(chooser_help.show_session, actionHelp(true));
    try testing.expectEqualStrings(chooser_help.resume_session, actionHelp(false));
}

test "placeholder: a state's sentence, the empty sentence, or rows" {
    try testing.expectEqualStrings(chooser_sessions.loading_text, placeholder(.loading, 0).?);
    try testing.expectEqualStrings(chooser_sessions.empty_text, placeholder(.loaded, 0).?);
    try testing.expectEqual(@as(?[]const u8, null), placeholder(.loaded, 3));
    try testing.expectEqualStrings(chooser_sessions.unauthorized_text, placeholder(failureState(error.Unauthorized), 0).?);
    try testing.expectEqual(chooser_sessions.State.failed, failureState(error.ConnectionRefused));
}

test "accountView: Mac's composition - email over Sign Out, or the button alone" {
    var buf: [200]u8 = undefined;
    const in_ = accountView(&buf, .{ .email = "me@example.com" });
    try testing.expectEqualStrings("Signed in as me@example.com", in_.status);
    try testing.expectEqualStrings("Sign Out", in_.button.?);
    try testing.expect(in_.signs_out and in_.sensitive);

    const out = accountView(&buf, .{});
    try testing.expectEqualStrings("", out.status);
    try testing.expectEqualStrings("Sign in with Google\u{2026}", out.button.?);
    try testing.expect(!out.signs_out and out.sensitive);

    // An empty stored email reads as nothing stored.
    try testing.expect(!accountView(&buf, .{ .email = "" }).signs_out);
}

test "accountView: an env token is an account with nothing to sign out of" {
    var buf: [200]u8 = undefined;
    const v = accountView(&buf, .{ .env_token = true });
    try testing.expectEqualStrings("Signed in as your account", v.status);
    try testing.expectEqualStrings("Sign in with Google\u{2026}", v.button.?);
    try testing.expect(!v.signs_out);
}

test "accountView: an unconfigured build has no Sign In button, but keeps Sign Out" {
    var buf: [200]u8 = undefined;
    const v = accountView(&buf, .{ .configured = false });
    try testing.expectEqualStrings(relay_account_text.unconfigured_status, v.status);
    try testing.expect(v.button == null);
    const s = accountView(&buf, .{ .configured = false, .email = "me@example.com" });
    try testing.expectEqualStrings("Sign Out", s.button.?);
}

test "accountView: busy rows say what is happening and cannot be pressed again" {
    var buf: [200]u8 = undefined;
    const i = accountView(&buf, .{ .busy = .sign_in });
    try testing.expectEqualStrings(relay_account_text.statusText(null, true, true, ""), i.status);
    try testing.expectEqualStrings("Signing in\u{2026}", i.button.?);
    try testing.expect(!i.sensitive);
    const o = accountView(&buf, .{ .busy = .sign_out, .email = "me@example.com" });
    try testing.expectEqualStrings("Signing out\u{2026}", o.status);
    try testing.expect(!o.sensitive and o.signs_out);
}

test "storeNote: names the private file, under ~ when it is in home" {
    var buf: [300]u8 = undefined;
    try testing.expectEqualStrings(
        "No keyring is running, so your sign-in is kept in a private file only you can read (~/.local/share/ghoztty/account.dat).",
        storeNote(&buf, "/home/me/.local/share/ghoztty/account.dat", "/home/me/"),
    );
    // Outside home (a GHOSTTY_ACCOUNT_STORE override): the full path.
    try testing.expectEqualStrings(
        "No keyring is running, so your sign-in is kept in a private file only you can read (/tmp/x/a.dat).",
        storeNote(&buf, "/tmp/x/a.dat", "/home/me"),
    );
    // A sibling that merely shares the prefix is not under home.
    try testing.expect(std.mem.indexOf(u8, storeNote(&buf, "/home/meg/a.dat", "/home/me"), "(/home/meg/a.dat)") != null);
    // Too small a buffer still says the fact.
    var small: [8]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, storeNote(&small, "/a", null), "private file") != null);
}
