//! What a LAUNCH tells the instance that is already running when it hands its
//! window over (T1022, building D79's answer).
//!
//! Starting Ghoztty when Ghoztty is already running does not start a second
//! app: the launch loses the race for the IPC endpoint, forwards a `new-window`
//! to the winner and exits (`App.init`'s `AlreadyRunning` branch). The user
//! chose that in D79 — one app, one tray icon, one session list — over two
//! copies quietly sharing one agent and one saved layout.
//!
//! The endpoint is keyed on the build LINEAGE (debug vs release, plus any
//! explicit `GHOZTTY_PIPE_SUFFIX`), so a debug `zig-out` build and the
//! installed release never join each other and side-by-side development keeps
//! working. Two copies of the SAME lineage do join — and that is where D79's
//! remaining con lives, quoted from the option the user picked:
//!
//! > a shortcut pointing at the portable copy would open a window from
//! > whichever copy is already running, which can look like the wrong build
//! > started
//!
//! This module is that con's answer: the launch carries its own build identity
//! across the handoff, and when it differs from the running instance's the app
//! SAYS SO instead of opening a window that silently belongs to another build.
//! A launch of the same build says nothing — the two copies are byte-identical
//! there and the join is invisible by design, so a notice would be pure noise.
//!
//! Pure text/comparison logic, unit-tested in the `none` lane; the win32 apprt
//! supplies the identities and shows the result.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// How a Ghoztty process identifies its own build. Every field is optional on
/// the wire: an older launcher sends no `handoff` at all (the server then says
/// nothing, exactly as it did before this existed), and a field it does not
/// know arrives empty rather than absent.
pub const Identity = struct {
    /// `build_config.version_string` — e.g. `1.4.0-…-+87b99c4b6`.
    version: []const u8 = "",
    /// The commit the build was made from, or "unknown".
    commit: []const u8 = "",
    /// Absolute path of the executable.
    exe: []const u8 = "",
    /// Whether the LAUNCH already told the user about the difference and got
    /// their answer (T1023's prompt). Not part of the build's identity — it
    /// rides the same object because it is the same handoff — and deliberately
    /// ignored by `sameBuild`: it only decides whether the running instance
    /// repeats the fact as a desktop balloon, which after a dialog the user
    /// just dismissed is noise. The reply's `note` is unaffected, so a CLI or
    /// an acceptance script still reads the caveat either way.
    prompted: bool = false,
};

/// Whether two identities describe the SAME build.
///
/// The commit decides when both sides know one, because that is the field that
/// answers "are these the same bits?" — the same commit delivered to the
/// installed location and the Desktop portable copy is one build sitting in two
/// places, and a user cannot tell those windows apart. Version is the fallback
/// for a build whose commit is unknown (a source tarball with no git dir).
///
/// The exe PATH is deliberately not part of it: a different path holding the
/// same build is the everyday case here — `deliver-windows-build.ps1` ships one
/// staged build to three locations — and warning about it would fire on every
/// launch from the Desktop copy while nothing was actually wrong.
pub fn sameBuild(a: Identity, b: Identity) bool {
    if (known(a.commit) and known(b.commit)) return std.mem.eql(u8, a.commit, b.commit);
    return std.mem.eql(u8, a.version, b.version);
}

fn known(commit: []const u8) bool {
    return commit.len > 0 and !std.mem.eql(u8, commit, "unknown");
}

/// What the user is told when the build they started is not the build that
/// owns the window they got.
pub const Notice = struct {
    /// Balloon title. Bounded by construction (a literal).
    title: []const u8,
    /// Balloon body: short enough for `NOTIFYICONDATAW.szInfo` (256 wchars)
    /// with room to spare, so the sentence is never cut off mid-word by the
    /// shell.
    body: []const u8,
    /// The same fact with nothing elided, for the IPC reply's `note` — the CLI
    /// prints it to stderr, and an acceptance script reads it as the oracle.
    note: []const u8,
};

/// How much of an executable path the balloon keeps. Long enough that the
/// install location is recognizable ("…\Programs\Ghoztty\ghoztty.exe" vs
/// "…\Desktop\Ghoztty-portable-x64\ghoztty.exe"), short enough that the whole
/// body fits a balloon.
pub const exe_tail_max = 56;

/// Build the notice for a launch that handed off to a DIFFERENT build, or null
/// when the two builds match and the right thing to do is stay quiet.
///
/// Everything is allocated from `alloc`; the caller owns the strings (an arena
/// is the intended shape).
pub fn mismatchNotice(
    alloc: Allocator,
    launcher: Identity,
    running: Identity,
) Allocator.Error!?Notice {
    if (sameBuild(launcher, running)) return null;

    const running_tail = tail(running.exe, exe_tail_max);

    return .{
        .title = "A different Ghoztty is already running",
        .body = try std.fmt.allocPrint(
            alloc,
            "Your new window opened in the Ghoztty already running ({s}). " ++
                "The copy you started did not open — quit the running one first to switch builds.",
            .{if (running_tail.len > 0) running_tail else "already open"},
        ),
        .note = try std.fmt.allocPrint(
            alloc,
            "Ghoztty {s} is already running{s}{s}; the new window opened there. " ++
                "The copy you started ({s}{s}{s}) did not start — quit the running instance first to switch builds.",
            .{
                describe(running),
                if (running.exe.len > 0) " from " else "",
                running.exe,
                describe(launcher),
                if (launcher.exe.len > 0) " at " else "",
                launcher.exe,
            },
        ),
    };
}

/// How much of an executable path the PROMPT keeps. A dialog is wider than a
/// balloon, but `DT_WORDBREAK` only breaks between words, so a path longer than
/// the dialog's wrap width would be clipped rather than wrapped — bounding it
/// here is what keeps the last, identifying part of the path on screen.
pub const prompt_exe_tail_max = 64;

/// What the user is ASKED before a launch hands its window to a different
/// build (T1023, D79's mitigation: "two DIFFERENT versions still start
/// independently").
///
/// D79 chose one app per lineage, and the three things two same-lineage copies
/// share — the IPC endpoint, the local agent's pipe, and the saved layout —
/// cannot all be re-keyed per build: the agent and the layout have to survive
/// an upgrade, which is precisely the case where the build changes underneath
/// them. So a stale copy cannot become a second app without reintroducing the
/// cons the user rejected (two apps over one agent, one saved layout).
///
/// What CAN honour the mitigation is the choice: the launch never silently
/// becomes a window of another build. It says which build is running, which
/// build the user started, and lets them take the window or back out and quit
/// the running one first.
pub const Prompt = struct {
    /// Dialog caption.
    title: []const u8,
    /// Dialog body. Multi-line; wrapped by the dialog.
    text: []const u8,
    /// Affirmative: take the window from the build already running.
    ok_label: []const u8,
    /// Dismissive: open nothing, leave the running app alone.
    cancel_label: []const u8,
    /// The third answer (T1070): quit the running build and start the copy the
    /// user launched. Null when the running instance cannot be asked to quit,
    /// which is the two-answer dialog T1023 shipped.
    switch_label: ?[]const u8 = null,
};

/// Whether the instance already running can be switched for the user (T1070),
/// and what switching costs them. Read from its `version` reply, which is the
/// capability handshake: a build that predates the switch says nothing, and
/// that silence is `.unsupported` — a normal outcome, not an error, because
/// the whole point of this path is that the other instance is a DIFFERENT
/// build and may well be an older one.
pub const SwitchOffer = enum {
    /// The running build does not understand `handoff-quit`.
    unsupported,
    /// It does, and its terminals live in the background agent: they are
    /// attached again by the copy that takes over.
    keeps_terminals,
    /// It does, but session persistence is off there, so quitting it ends the
    /// shells it has open. The user is told before they choose it.
    closes_terminals,

    /// Decide from the two fields the `version` reply carries. An absent
    /// `handoff_quit` (an older build) is `false`.
    pub fn fromReply(handoff_quit: bool, session_persistence: bool) SwitchOffer {
        if (!handoff_quit) return .unsupported;
        return if (session_persistence) .keeps_terminals else .closes_terminals;
    }
};

/// The IPC action a launch sends to ask the running instance to quit so it can
/// take over (T1070). Not a CLI verb: it is one half of the launch handoff, and
/// the server refuses it from anything that is not a launch of a different
/// build (`refuseHandoffQuit`).
pub const quit_action = "handoff-quit";

/// Why a `handoff-quit` must be refused, or null when it may go ahead. Only a
/// LAUNCH carries a build identity, and only a launch of a DIFFERENT build has
/// a reason to ask: the same build joining is invisible by design, so a quit
/// requested for it would close the user's app for nothing.
pub fn refuseHandoffQuit(launcher: ?Identity, running: Identity) ?[]const u8 {
    const l = launcher orelse return "handoff-quit is only sent by a launch of another build";
    if (sameBuild(l, running)) return "handoff-quit refused: the launch is the build already running";
    return null;
}

/// Build the prompt for a launch whose build differs from the one already
/// running, or null when they match and the join is invisible by design.
///
/// Everything is allocated from `alloc`; the caller owns the strings.
pub fn mismatchPrompt(
    alloc: Allocator,
    launcher: Identity,
    running: Identity,
    offer: SwitchOffer,
) Allocator.Error!?Prompt {
    if (sameBuild(launcher, running)) return null;

    // A path goes on its own line under the sentence it belongs to; without one
    // the sentence simply ends. Formatting it inline would leave the period
    // hanging off the end of a path, where it reads as part of the filename.
    const running_where = try where(alloc, running);
    defer alloc.free(running_where);
    const launcher_where = try where(alloc, launcher);
    defer alloc.free(launcher_where);

    // The last paragraph is the only part that depends on what the running
    // instance can do: it names every button the dialog actually has, and says
    // what switching costs before the user picks it.
    const choice: []const u8 = switch (offer) {
        .unsupported => "Two versions cannot run at the same time, and the Ghoztty " ++
            "already running is too old to be switched for you. Open a window in it, " ++
            "or cancel and quit it first to run the copy you started.",
        .keeps_terminals => "Two versions cannot run at the same time. Switch to quit " ++
            "the Ghoztty already running and start the copy you started; your " ++
            "terminals will reopen in it. Or open a window in the one already running.",
        .closes_terminals => "Two versions cannot run at the same time. Switch to quit " ++
            "the Ghoztty already running and start the copy you started; the terminals " ++
            "open in it will close. Or open a window in the one already running.",
    };

    return .{
        .title = "A different Ghoztty is already running",
        .text = try std.fmt.allocPrint(
            alloc,
            "Ghoztty {s} is already running{s}\n\n" ++
                "The copy you started is {s}{s}\n\n{s}",
            .{ describe(running), running_where, describe(launcher), launcher_where, choice },
        ),
        .ok_label = "Open Window",
        .cancel_label = "Cancel",
        .switch_label = if (offer == .unsupported) null else "Switch",
    };
}

/// The ":\n<path>" tail of a prompt sentence, or "." when the path is unknown.
fn where(alloc: Allocator, id: Identity) Allocator.Error![]u8 {
    if (id.exe.len == 0) return alloc.dupe(u8, ".");
    return std.fmt.allocPrint(alloc, ":\n{s}", .{tail(id.exe, prompt_exe_tail_max)});
}

/// The most identifying thing we can say about a build in one phrase.
fn describe(id: Identity) []const u8 {
    if (id.version.len > 0) return id.version;
    if (known(id.commit)) return id.commit;
    return "an unknown build";
}

/// The last `max` bytes of `path`, prefixed with `…` when it was cut, and
/// never cut in the middle of a UTF-8 sequence (a half character would render
/// as a replacement box in the balloon).
pub fn tail(path: []const u8, max: usize) []const u8 {
    if (path.len <= max) return path;
    var start = path.len - max;
    // Advance to the next lead byte: continuation bytes are 0b10xxxxxx.
    while (start < path.len and (path[start] & 0xC0) == 0x80) start += 1;
    return path[start..];
}

test "sameBuild: the commit decides when both sides know one" {
    const testing = std.testing;
    // Same build delivered to two locations is ONE build: no notice.
    try testing.expect(sameBuild(
        .{ .version = "1.4.0+abc", .commit = "abc1234", .exe = "C:\\Programs\\Ghoztty\\ghoztty.exe" },
        .{ .version = "1.4.0+abc", .commit = "abc1234", .exe = "D:\\Desktop\\Ghoztty\\ghoztty.exe" },
    ));
    try testing.expect(!sameBuild(
        .{ .version = "1.4.0+abc", .commit = "abc1234" },
        .{ .version = "1.4.0+abc", .commit = "def5678" },
    ));
}

test "sameBuild: version is the fallback when a commit is unknown" {
    const testing = std.testing;
    try testing.expect(sameBuild(
        .{ .version = "1.4.0", .commit = "unknown" },
        .{ .version = "1.4.0", .commit = "abc1234" },
    ));
    try testing.expect(!sameBuild(
        .{ .version = "1.3.0", .commit = "unknown" },
        .{ .version = "1.4.0", .commit = "" },
    ));
    // Nothing known on either side reads as the same build, which keeps an
    // empty handoff silent rather than warning about a difference we cannot see.
    try testing.expect(sameBuild(.{}, .{}));
}

test "mismatchNotice: the same build says nothing" {
    const testing = std.testing;
    const id: Identity = .{ .version = "1.4.0", .commit = "abc1234", .exe = "C:\\a\\ghoztty.exe" };
    try testing.expect(try mismatchNotice(testing.allocator, id, id) == null);
}

test "mismatchNotice: names the running copy, and the balloon fits a balloon" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const notice = (try mismatchNotice(
        arena,
        .{ .version = "1.4.0-dev", .commit = "aaaaaaa", .exe = "D:\\git\\ghoztty\\zig-out\\bin\\ghoztty.exe" },
        .{ .version = "1.3.0", .commit = "bbbbbbb", .exe = "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty\\ghoztty.exe" },
    )).?;

    // The balloon names WHICH copy owns the window...
    try testing.expect(std.mem.indexOf(u8, notice.body, "Programs\\Ghoztty\\ghoztty.exe") != null);
    // ...and stays inside NOTIFYICONDATAW.szInfo (256 wchars) with room for the
    // shell's own ellipsis rather than relying on it.
    try testing.expect(notice.body.len < 240);
    try testing.expect(notice.title.len < 60);

    // The note elides nothing: both builds, both paths.
    try testing.expect(std.mem.indexOf(u8, notice.note, "1.3.0") != null);
    try testing.expect(std.mem.indexOf(u8, notice.note, "1.4.0-dev") != null);
    try testing.expect(std.mem.indexOf(u8, notice.note, "D:\\git\\ghoztty\\zig-out\\bin\\ghoztty.exe") != null);
}

test "mismatchNotice: an empty running exe still produces a sentence" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const notice = (try mismatchNotice(
        arena,
        .{ .version = "1.4.0", .commit = "aaaaaaa" },
        .{ .version = "1.3.0", .commit = "bbbbbbb" },
    )).?;
    try testing.expect(notice.body.len > 0);
    try testing.expect(std.mem.indexOf(u8, notice.body, "already open") != null);
    // No dangling "from " with nothing after it.
    try testing.expect(std.mem.indexOf(u8, notice.note, "running from ") == null);
}

test "mismatchPrompt: the same build is never asked about" {
    const testing = std.testing;
    const id: Identity = .{ .version = "1.4.0", .commit = "abc1234", .exe = "C:\\a\\ghoztty.exe" };
    try testing.expect(try mismatchPrompt(testing.allocator, id, id, .keeps_terminals) == null);
    // `prompted` is not part of the build's identity: a launch that has already
    // asked is still the SAME build and must stay silent.
    var asked = id;
    asked.prompted = true;
    try testing.expect(try mismatchPrompt(testing.allocator, asked, id, .unsupported) == null);
    try testing.expect(try mismatchNotice(testing.allocator, asked, id) == null);
}

test "mismatchPrompt: names both builds and offers both ways out" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prompt = (try mismatchPrompt(
        arena,
        .{ .version = "1.3.0", .commit = "aaaaaaa", .exe = "D:\\Users\\David\\Desktop\\Ghoztty-portable-x64\\ghoztty.exe" },
        .{ .version = "1.4.0", .commit = "bbbbbbb", .exe = "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty\\ghoztty.exe" },
        .unsupported,
    )).?;

    // Which build owns the app right now, and which one the user just started:
    // the whole point is that neither is left to be guessed from a window.
    try testing.expect(std.mem.indexOf(u8, prompt.text, "1.4.0") != null);
    try testing.expect(std.mem.indexOf(u8, prompt.text, "1.3.0") != null);
    try testing.expect(std.mem.indexOf(u8, prompt.text, "Programs\\Ghoztty\\ghoztty.exe") != null);
    try testing.expect(std.mem.indexOf(u8, prompt.text, "Ghoztty-portable-x64\\ghoztty.exe") != null);
    // ...with no period glued to the end of a path, where it reads as filename.
    try testing.expect(std.mem.indexOf(u8, prompt.text, ".exe.") == null);

    // Both ways out are named, and the dismissive one says what to do instead.
    try testing.expect(prompt.ok_label.len > 0 and prompt.cancel_label.len > 0);
    try testing.expect(std.mem.indexOf(u8, prompt.text, "quit it first") != null);
    // A running build that cannot be switched gets no third button, and the
    // text says why the user has to do it by hand (T1070).
    try testing.expect(prompt.switch_label == null);
    try testing.expect(std.mem.indexOf(u8, prompt.text, "too old to be switched") != null);

    // No line is long enough to be clipped by the dialog's word wrap: paths are
    // tailed, and every other line is prose that breaks between words.
    var lines = std.mem.splitScalar(u8, prompt.text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.splitScalar(u8, line, ' ');
        while (words.next()) |word| try testing.expect(word.len <= prompt_exe_tail_max + 1);
    }
}

test "mismatchPrompt: a build with no exe path still produces both sentences" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prompt = (try mismatchPrompt(
        arena,
        .{ .version = "1.3.0", .commit = "aaaaaaa" },
        .{ .version = "1.4.0", .commit = "bbbbbbb" },
        .unsupported,
    )).?;
    // No dangling colon-newline with nothing after it.
    try testing.expect(std.mem.indexOf(u8, prompt.text, ":\n") == null);
    try testing.expect(std.mem.indexOf(u8, prompt.text, "1.4.0 is already running.") != null);
}

test "mismatchPrompt: a switchable build gets the third answer, priced honestly (T1070)" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const launcher: Identity = .{ .version = "1.3.0", .commit = "aaaaaaa" };
    const running: Identity = .{ .version = "1.4.0", .commit = "bbbbbbb" };

    const keeps = (try mismatchPrompt(arena, launcher, running, .keeps_terminals)).?;
    try testing.expect(keeps.switch_label != null);
    // The text names the button it offers, and what it costs.
    try testing.expect(std.mem.indexOf(u8, keeps.text, "Switch") != null);
    try testing.expect(std.mem.indexOf(u8, keeps.text, "terminals will reopen") != null);
    // ...and no longer tells the user to do by hand what the button does.
    try testing.expect(std.mem.indexOf(u8, keeps.text, "quit it first") == null);

    // With persistence off over there, switching ends those shells, and the
    // user reads that before they choose it rather than after.
    const closes = (try mismatchPrompt(arena, launcher, running, .closes_terminals)).?;
    try testing.expect(closes.switch_label != null);
    try testing.expect(std.mem.indexOf(u8, closes.text, "will close") != null);
    try testing.expect(std.mem.indexOf(u8, closes.text, "will reopen") == null);
}

test "SwitchOffer.fromReply: silence from an older build is not an offer" {
    const testing = std.testing;
    try testing.expectEqual(SwitchOffer.unsupported, SwitchOffer.fromReply(false, true));
    try testing.expectEqual(SwitchOffer.unsupported, SwitchOffer.fromReply(false, false));
    try testing.expectEqual(SwitchOffer.keeps_terminals, SwitchOffer.fromReply(true, true));
    try testing.expectEqual(SwitchOffer.closes_terminals, SwitchOffer.fromReply(true, false));
}

test "refuseHandoffQuit: only a launch of a DIFFERENT build may ask" {
    const testing = std.testing;
    const running: Identity = .{ .version = "1.4.0", .commit = "bbbbbbb" };
    // No identity at all is a CLI caller or a hand-framed request, not a launch.
    try testing.expect(refuseHandoffQuit(null, running) != null);
    // The same build joining is invisible; quitting the app for it would close
    // the user's terminal for nothing.
    try testing.expect(refuseHandoffQuit(running, running) != null);
    try testing.expect(refuseHandoffQuit(.{ .version = "1.3.0", .commit = "aaaaaaa" }, running) == null);
}

test "tail: cuts on a character boundary" {
    const testing = std.testing;
    try testing.expectEqualStrings("abc", tail("abc", 8));
    try testing.expectEqualStrings("cde", tail("abcde", 3));
    // "é" is two bytes; a naive cut would land inside it.
    const p = "aaé";
    try testing.expectEqualStrings("é", tail(p, 2));
}
