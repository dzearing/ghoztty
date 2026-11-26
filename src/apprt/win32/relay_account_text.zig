//! The words of the relay-account row (T141), shared by every seat that
//! draws one: win32's machine chooser (`RelayAccountRow.zig` re-exports
//! these) and the GTK machine chooser (T3575). Pure, so it runs in the
//! `none` lane and the seats cannot drift. Mac's
//! `MachineChooserView.accountRow` is the source of the words.

const std = @import("std");
const relay_signin = @import("../../remote/relay_signin.zig");

/// The account button's label for a given state. Mac parity: the signed-in
/// state offers "Sign Out", the signed-out state offers Google sign-in.
pub fn buttonLabel(signed_in: bool, busy: bool) []const u8 {
    if (busy) return "Signing in…";
    return if (signed_in) "Sign Out" else "Sign in with Google…";
}

/// The account row's sentence when this build carries no Google OAuth client id
/// (T747). It replaces the button rather than sitting beside one: there is
/// nothing to press, and a build with no client id can only answer
/// `Error.NoClientId` to every attempt.
pub const unconfigured_status = "Google sign-in isn't set up in this build";

/// The footer-hint version of the same news, which is where the remedy goes —
/// the row's one line has no room for it, and the strip already wraps. Mac says
/// the same thing in its (larger) row: MachineChooserView.swift:1151.
pub const unconfigured_hint =
    "Google sign-in isn't set up in this build — it needs a Google OAuth client id " ++
    "(-Dgoogle-client-id, or GHOSTTY_GOOGLE_CLIENT_ID in the environment). " ++
    "See docs/design/relay-oidc-setup.md.";

/// The account status line shown next to the button, or "" when the state has
/// no sentence — the caller hides the STATIC on empty.
///
/// Three of the four states say something Mac says too: the email (2.4), the
/// browser-flow sentence beside Mac's "Waiting for browser sign-in…", and the
/// setup pointer an unconfigured build shows instead of a button it cannot
/// honour (T747). The **signed-out** state says nothing, because Mac says
/// nothing there — §2.4 records its signed-out row as the bordered button
/// alone — and on this surface the fact was already stated twice over: the
/// button's own caption is "Sign in with Google…", and the footer hint under
/// the empty list reads "Not signed in — use Sign in with Google above to list
/// your machines." A third copy in the band was the only text in the chooser
/// with no Mac counterpart at all (T316).
///
/// The one exception is Mac's too (T1426, f3b1e5fb5): a sign-out the user
/// forced past a failed revocation leaves this machine on the account until
/// the queued revocation lands, and the signed-out row says so — `pending` is
/// that sentence (`pendingRevocationText`), or "" when nothing is owed. Mac
/// shows it only under a live Sign In button, so an unconfigured build keeps
/// its setup pointer.
pub fn statusText(email: ?[]const u8, busy: bool, configured: bool, pending: []const u8) []const u8 {
    if (busy) return "Finish signing in in your browser…";
    const signed_out = if (!configured) unconfigured_status else pending;
    const e = email orelse return signed_out;
    return if (e.len == 0) signed_out else e;
}

/// The signed-out row's sentence while a revocation is still owed (T1426):
/// Mac's "This machine is still connected to <owner> — still removing it."
/// `owner` is the account the record was armed for; a record without one (or
/// an address too long for `buf`) names "your account" instead, which is still
/// the fact the user needs. The remedy is in the sentence itself — Ghoztty is
/// already doing the removing — so there is nothing for them to go and do.
pub fn pendingRevocationText(buf: []u8, owner: []const u8) []const u8 {
    const generic = "This machine is still connected to your account — still removing it.";
    if (owner.len == 0) return generic;
    return std.fmt.bufPrint(
        buf,
        "This machine is still connected to {s} — still removing it.",
        .{owner},
    ) catch generic;
}

/// The footer sentence for a finished sign-out (T1421). Pure, so every branch
/// is readable in one place and testable in the `none` lane.
///
/// The wording carries the outcome rather than a generic "Signed out.", because
/// the four outcomes are four different facts about the user's machine and only
/// one of them means what "Signed out" used to mean. `.not_revoked` in
/// particular must not read as success: the account is still signed in.
pub fn signOutMessage(res: relay_signin.SignOutResult) []const u8 {
    return switch (res.machine) {
        .revoked => "Signed out — this machine was removed from your account.",
        .not_revoked => "Couldn't remove this machine from your account, so you're still signed in.",
        .left_enrolled => "Signed out. This machine is still connected — Ghoztty will remove it when the relay answers.",
        .nothing_to_revoke => if (res.was_signed_in) "Signed out." else "Already signed out.",
    };
}

/// The confirmation body shown when a sign-out could not revoke this machine.
/// Pure for the same reason as `signOutMessage`, and separate because the
/// dialog states the consequence the footer has no room for.
pub const not_revoked_title = "Couldn't remove this machine from your account";
pub const not_revoked_body =
    "Signing out revokes this machine's registration so it stops being listed, " ++
    "reachable and streamable from your other computers. That couldn't be done " ++
    "just now — the relay didn't answer.\n\n" ++
    "You can sign out anyway: this machine stays connected to that account for " ++
    "now, and Ghoztty keeps trying to remove it until the relay answers — while " ++
    "this app runs, and again every time it starts. You can also remove it from " ++
    "the machine list on another computer.";

/// The monogram letter for the avatar circle (T311): the email's first LETTER,
/// uppercased, mirroring Mac's `initials` (MachineChooserView.swift:942-976).
///
/// Mac takes `first?.uppercased()` outright; this skips leading punctuation and
/// digits first, because an address like `+ghoztty@…` or `1@…` would otherwise
/// put a symbol in the identity mark. When there is no letter at all the mark
/// still draws — with `?`, which reads as "we do not know who this is" rather
/// than as an empty accent disc. Returns null only when there is nothing signed
/// in, which is the state that has no avatar at all.
pub fn monogram(email: ?[]const u8) ?u8 {
    const e = email orelse return null;
    if (e.len == 0) return null;
    for (e) |c| {
        if (std.ascii.isAlphabetic(c)) return std.ascii.toUpper(c);
    }
    return '?';
}

const testing = std.testing;

test "monogram: the first letter, uppercased, and never an empty disc" {
    try testing.expectEqual(@as(?u8, 'M'), monogram("me@example.com"));
    try testing.expectEqual(@as(?u8, 'D'), monogram("dzearing@gmail.com"));
    // Leading punctuation/digits are skipped — a "+" in the mark is not an
    // identity cue, and gmail's plus-addressing makes that a real address.
    try testing.expectEqual(@as(?u8, 'G'), monogram("+ghoztty@example.com"));
    try testing.expectEqual(@as(?u8, 'A'), monogram("1account@example.com"));
    // No letter anywhere: the disc still draws, with a legible placeholder.
    try testing.expectEqual(@as(?u8, '?'), monogram("12345@678.90"));
    // Signed out (or an empty email) has no avatar at all.
    try testing.expectEqual(@as(?u8, null), monogram(null));
    try testing.expectEqual(@as(?u8, null), monogram(""));
}

test "buttonLabel: signed-in offers sign out, busy overrides both" {
    try testing.expectEqualStrings("Sign Out", buttonLabel(true, false));
    try testing.expectEqualStrings("Sign in with Google…", buttonLabel(false, false));
    try testing.expectEqualStrings("Signing in…", buttonLabel(true, true));
    try testing.expectEqualStrings("Signing in…", buttonLabel(false, true));
}

test "statusText: email when signed in, and nothing at all when signed out (T316)" {
    try testing.expectEqualStrings("me@example.com", statusText("me@example.com", false, true, ""));
    // Signed out is Mac's composition: the bordered button alone. The state is
    // named by the button's caption and by the footer hint, not a third time
    // here.
    try testing.expectEqualStrings("", statusText(null, false, true, ""));
    try testing.expectEqualStrings("", statusText("", false, true, ""));
    // The browser-flow sentence stays — Mac shows one too (2.4).
    try testing.expect(statusText("me@example.com", true, true, "").len > 0);
    try testing.expect(statusText(null, true, true, "").len > 0);
}

test "statusText: an unconfigured build says so where signed-out says nothing (T747)" {
    // A drawn button IS the invitation, so the ordinary signed-out row needs no
    // words (T316); with no client id there is no button, and a row that said
    // nothing at all would be an empty band with no way out of it.
    try testing.expectEqualStrings(unconfigured_status, statusText(null, false, false, ""));
    try testing.expectEqualStrings(unconfigured_status, statusText("", false, false, ""));

    // A stored account still shows its email — Sign Out needs no client id.
    try testing.expectEqualStrings("me@example.com", statusText("me@example.com", false, false, ""));
    // And a sign-in in flight still describes itself.
    try testing.expectEqualStrings(statusText(null, true, true, ""), statusText(null, true, false, ""));

    // The hint carries the remedy the one-line row has no room for, and names
    // both ways to supply an id plus the doc.
    try testing.expect(std.mem.indexOf(u8, unconfigured_hint, "relay-oidc-setup.md") != null);
    try testing.expect(std.mem.indexOf(u8, unconfigured_hint, "GHOSTTY_GOOGLE_CLIENT_ID") != null);
    try testing.expect(unconfigured_hint.len > unconfigured_status.len);
}

test "statusText: a revocation still owed is the one signed-out sentence (T1426)" {
    var buf: [256]u8 = undefined;
    const pending = pendingRevocationText(&buf, "me@example.com");
    // Mac's sentence, word for word (f3b1e5fb5): who it is still connected
    // to, and that the removing is already happening.
    try testing.expectEqualStrings(
        "This machine is still connected to me@example.com — still removing it.",
        pending,
    );
    // Signed out with a revocation owed: the row says so.
    try testing.expectEqualStrings(pending, statusText(null, false, true, pending));
    try testing.expectEqualStrings(pending, statusText("", false, true, pending));
    // Nothing owed: back to T316's silent row.
    try testing.expectEqualStrings("", statusText(null, false, true, ""));
    // Signed in, the email wins — Mac shows the line only under Sign In.
    try testing.expectEqualStrings("me@example.com", statusText("me@example.com", false, true, pending));
    // A sign-in in flight describes itself instead.
    try testing.expectEqualStrings(statusText(null, true, true, ""), statusText(null, true, true, pending));
    // An unconfigured build keeps its setup pointer: there is no Sign In
    // button for the sentence to sit under.
    try testing.expectEqualStrings(unconfigured_status, statusText(null, false, false, pending));
}

test "pendingRevocationText: no owner, or one too long, still names the fact (T1426)" {
    var buf: [256]u8 = undefined;
    const generic = pendingRevocationText(&buf, "");
    try testing.expect(std.mem.indexOf(u8, generic, "your account") != null);
    try testing.expect(std.mem.indexOf(u8, generic, "still removing it") != null);
    var small: [16]u8 = undefined;
    try testing.expectEqualStrings(generic, pendingRevocationText(&small, "me@example.com"));
    // The footer's sign-out sentence and this one must not read alike: the
    // acceptance script tells them apart by "still removing it".
    const left = signOutMessage(.{ .was_signed_in = true, .machine = .left_enrolled });
    try testing.expect(std.mem.indexOf(u8, left, "still removing it") == null);
}

test "signOutMessage: the four outcomes say four different things (T1421)" {
    // `.not_revoked` is the one that must NOT read as success — the account is
    // still signed in, and a footer saying "Signed out." would be the same lie
    // the whole revocation path exists to stop telling.
    const not_revoked = signOutMessage(.{ .was_signed_in = true, .machine = .not_revoked });
    try testing.expect(std.mem.indexOf(u8, not_revoked, "still signed in") != null);
    try testing.expect(std.mem.indexOf(u8, not_revoked, "Signed out") == null);

    const revoked = signOutMessage(.{ .was_signed_in = true, .machine = .revoked });
    try testing.expect(std.mem.indexOf(u8, revoked, "removed from your account") != null);

    // Signing out anyway must still admit what is left behind — and, since
    // T1424, say that it is being finished rather than abandoned.
    const left = signOutMessage(.{ .was_signed_in = true, .machine = .left_enrolled });
    try testing.expect(std.mem.indexOf(u8, left, "still connected") != null);
    try testing.expect(std.mem.indexOf(u8, left, "will remove it") != null);

    // The unenrolled machine keeps the old wording, both ways round.
    try testing.expectEqualStrings(
        "Signed out.",
        signOutMessage(.{ .was_signed_in = true, .machine = .nothing_to_revoke }),
    );
    try testing.expectEqualStrings(
        "Already signed out.",
        signOutMessage(.{ .was_signed_in = false, .machine = .nothing_to_revoke }),
    );

    // All four are distinct: a footer that cannot tell two outcomes apart is a
    // footer the user cannot act on.
    const all = [_][]const u8{ not_revoked, revoked, left, signOutMessage(.{ .was_signed_in = true, .machine = .nothing_to_revoke }) };
    for (all, 0..) |a, i| {
        try testing.expect(a.len > 0);
        for (all[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    }
}

test "not_revoked_body: names the consequence and the remedy (T1421)" {
    // The dialog is the only place the user learns that signing out anyway
    // leaves the machine reachable, and where to go to finish the job.
    try testing.expect(std.mem.indexOf(u8, not_revoked_body, "stays connected") != null);
    try testing.expect(std.mem.indexOf(u8, not_revoked_body, "another computer") != null);
    // T1424: the dialog no longer asks the user to remember a chore. It says
    // the app finishes the job itself, because it now does.
    try testing.expect(std.mem.indexOf(u8, not_revoked_body, "keeps trying") != null);
    try testing.expect(not_revoked_title.len > 0);
}

test "SignOutResult.signedOut: only a failed revocation keeps the account" {
    const R = relay_signin.SignOutResult;
    try testing.expect((R{ .was_signed_in = true, .machine = .revoked }).signedOut());
    try testing.expect((R{ .was_signed_in = true, .machine = .left_enrolled }).signedOut());
    try testing.expect((R{ .was_signed_in = true, .machine = .nothing_to_revoke }).signedOut());
    try testing.expect(!(R{ .was_signed_in = true, .machine = .not_revoked }).signedOut());
}
