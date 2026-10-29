//! Who set a window's title, and what that lets a script do (T2404, Mac
//! 7e2d0a9da `BaseTerminalController.windowTitleIsUsers`).
//!
//! A window title pin records its setter. The USER sets one with the
//! Change Window Title prompt or the pane sidebar (its rename field, a group
//! rename, a drag into or out of a group); a SCRIPT sets one with `+rename`,
//! `+new-window --title`, or the sidebar's group + naming its new window. A
//! user's title outranks every script's: while it is up, `+rename` changes
//! nothing - not even a clear - and fails naming it. Once the user clears it,
//! scripts may rename again.
//!
//! Pure: no OS imports, so the rules run in every app-runtime lane (T59a).

const std = @import("std");

pub const Setter = enum { script, user };

/// The by-user bit to store beside a pin just set to `title` by `setter`.
/// Only a real title can be the user's: a null or empty one clears the pin
/// (T92), and a cleared pin belongs to nobody (Mac `byUser && newTitle != nil`).
pub fn byUserAfterSet(title: ?[]const u8, setter: Setter) bool {
    const t = title orelse return false;
    return t.len > 0 and setter == .user;
}

/// The title a script's `+rename` must leave alone, or null when the rename
/// may go ahead. Mac `IPCServer` answers the same question from
/// `windowTitleSetByUser` in the same main-thread turn as the set.
pub fn keptFromScript(pin: ?[]const u8, by_user: bool) ?[]const u8 {
    if (!by_user) return null;
    const t = pin orelse return null;
    return if (t.len > 0) t else null;
}

/// The `+rename` refusal, word for word as Mac's (`IPCServer.swift`), so a
/// script reading the error sees one sentence on both platforms.
pub const refusal_fmt = "window '{s}' was renamed by the user ('{s}'); " ++
    "+rename leaves a user's title alone until they clear it";

/// The session-layout spelling of the bit: `true`, or absent. A script's
/// title and a cleared pin both write nothing, so an older reader sees the
/// manifest it always did (Mac `windowTitleSetByUser`: true or absent).
pub fn persisted(pin: ?[]const u8, by_user: bool) ?bool {
    return if (keptFromScript(pin, by_user) != null) true else null;
}

/// The setter a restore replays a persisted pin with. Absent - an older
/// manifest, or a script's title - decodes as a script's.
pub fn restoredSetter(flag: ?bool) Setter {
    return if (flag orelse false) .user else .script;
}

const testing = std.testing;

test "only a real title set by the user is the user's" {
    try testing.expect(byUserAfterSet("Deploy", .user));
    try testing.expect(!byUserAfterSet("Deploy", .script));
    try testing.expect(!byUserAfterSet("", .user));
    try testing.expect(!byUserAfterSet(null, .user));
}

test "a script rename keeps the user's title and nothing else" {
    try testing.expectEqualStrings("Mine", keptFromScript("Mine", true).?);
    try testing.expect(keptFromScript("Theirs", false) == null);
    try testing.expect(keptFromScript(null, true) == null);
    try testing.expect(keptFromScript("", true) == null);
}

test "the refusal names the target and the user's title as Mac does" {
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, refusal_fmt, .{ "editor", "My notes" });
    try testing.expectEqualStrings(
        "window 'editor' was renamed by the user ('My notes'); " ++
            "+rename leaves a user's title alone until they clear it",
        msg,
    );
}

test "the persisted bit is true or absent, and absent restores as a script's" {
    try testing.expectEqual(@as(?bool, true), persisted("Mine", true));
    try testing.expectEqual(@as(?bool, null), persisted("Theirs", false));
    try testing.expectEqual(@as(?bool, null), persisted(null, true));
    try testing.expectEqual(Setter.user, restoredSetter(true));
    try testing.expectEqual(Setter.script, restoredSetter(false));
    try testing.expectEqual(Setter.script, restoredSetter(null));
}

test "user title lifecycle: kept from scripts until the user clears it" {
    // The Window's two fields, driven the way its setter drives them.
    var pin: ?[]const u8 = null;
    var by_user = false;
    const set = struct {
        fn f(p: *?[]const u8, b: *bool, t: ?[]const u8, s: Setter) void {
            p.* = if (t) |x| (if (x.len == 0) null else x) else null;
            b.* = byUserAfterSet(t, s);
        }
    }.f;

    set(&pin, &by_user, "from script", .script);
    try testing.expect(keptFromScript(pin, by_user) == null);
    set(&pin, &by_user, "typed", .user);
    try testing.expectEqualStrings("typed", keptFromScript(pin, by_user).?);
    // The user clears it; scripts may rename again.
    set(&pin, &by_user, null, .user);
    try testing.expect(keptFromScript(pin, by_user) == null);
    set(&pin, &by_user, "script again", .script);
    try testing.expect(keptFromScript(pin, by_user) == null);
}
