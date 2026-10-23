//! Where is this exe running from? (T1217)
//!
//! Three copies of Ghoztty live on a developer's box and they are NOT
//! interchangeable:
//!
//!   * the **installed release**, `%LOCALAPPDATA%\Programs\Ghoztty` — what the
//!     MSI writes and what the user's everyday terminal is,
//!   * a **portable unpack** (a Desktop folder, a network share),
//!   * a **dev prefix** (`zig-out`, `zig-out-release`, a worktree).
//!
//! Several behaviors are already keyed on that distinction by hand —
//! `AgentIntegration.setupEnabled`, `PathInstaller` — and T1217 added another:
//! the automatic update check. Two things made that a bug rather than a
//! preference. The loop's morning refresh writes a script-built exe over the
//! installed release, so "was this exe produced by the MSI pipeline" (the
//! `-Dwindows-update-check` build flag) stopped being the same question as "is
//! this the user's installed terminal" — on 2026-08-31 a terminal installed
//! from the website at 07:08 could no longer find updates at 07:49, with
//! nothing on screen to say so. And the same staging bytes are ALSO delivered
//! to the portable locations, where phoning home is deliberately not wanted,
//! so the answer could not simply be moved into the build.
//!
//! It has to be about where the exe IS, so it lives here — pure and testable —
//! instead of being spelled out a fourth time at the call site.
const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../../build_config.zig");
const path_env = @import("../../os/path_env.zig");
const source_checkout = @import("source_checkout.zig");

/// The install directory's tail, under `%LOCALAPPDATA%`.
pub const install_subdir = "Programs\\Ghoztty";

/// Whether `exe_dir` IS the installed-release directory for a machine whose
/// `%LOCALAPPDATA%` is `local_app_data`.
///
/// Exact directory match, not a prefix match: a `zig-out` inside a checkout
/// that happens to sit under LOCALAPPDATA is not an install, and neither is a
/// subfolder of the install. Case-insensitive, trailing separators ignored,
/// and `/` reads as `\`, like Windows path resolution.
pub fn isInstallDir(exe_dir: []const u8, local_app_data: []const u8) bool {
    const local = path_env.normalize(local_app_data);
    if (local.len == 0) return false;
    const dir = path_env.normalize(exe_dir);
    if (dir.len <= local.len) return false;
    if (!eqlPathIgnoreSep(dir[0..local.len], local)) return false;

    var rest = dir[local.len..];
    // The separator between LOCALAPPDATA and the tail. `normalize` already
    // stripped a trailing one from `local` — except at a drive root ("C:\"),
    // which keeps its separator, so there is none left to consume there.
    if (rest.len > 0 and (rest[0] == '\\' or rest[0] == '/')) {
        rest = rest[1..];
    } else if (!(local.len == 3 and local[1] == ':')) {
        return false;
    }
    return eqlPathIgnoreSep(rest, install_subdir);
}

/// ASCII case-insensitive path compare that treats `/` and `\` as the same
/// separator, so a path that reached us through a POSIX-ish API still matches.
fn eqlPathIgnoreSep(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const na = if (ca == '/') '\\' else std.ascii.toLower(ca);
        const nb = if (cb == '/') '\\' else std.ascii.toLower(cb);
        if (na != nb) return false;
    }
    return true;
}

/// Runtime form: is the RUNNING executable the installed release?
///
/// Allocates from `arena` (nothing is freed individually). Answers false
/// rather than erroring when either the exe path or `%LOCALAPPDATA%` cannot be
/// read — an unknown location is treated as "not the install", which is the
/// safe side of every gate that asks.
pub fn isInstalledRelease(arena: std.mem.Allocator) bool {
    const exe_dir = std.fs.selfExeDirPathAlloc(arena) catch return false;
    const local = std.process.getEnvVarOwned(arena, "LOCALAPPDATA") catch return false;
    return isInstallDir(exe_dir, local);
}

/// Whether this exe may run the automatic win-v update check (T1217).
///
/// True for a build the MSI release pipeline stamped (`-Dwindows-update-check`,
/// T24), and for any non-Debug build RUNNING FROM the installed-release folder
/// — which is what a script-delivered refresh of the user's install is.
///
/// Debug is excluded even there: a debug build derives its own IPC endpoints
/// and state directory on purpose, and one that happened to be copied into the
/// install folder must not start behaving like the user's product.
///
/// This is the single answer behind the gate in `App.startUpdateCheck`, the
/// `update_check` field of `provenance.collect`, and the `update check:` line
/// of `ghoztty +version`, so those three cannot disagree — which is T1205's
/// lesson applied before it can be broken again.
pub fn autoUpdateCheckEnabled(arena: std.mem.Allocator) bool {
    if (build_config.windows_update_check) return true;
    if (builtin.mode == .Debug) return false;
    return isInstalledRelease(arena);
}

/// Which location a launch-time self-heal must be running from before it may
/// write something that outlives the process (T1213).
///
/// The deciding question is who OWNS the thing being written, and the full
/// rule — with the table of which site uses which — is "Which gate a self-heal
/// uses" in `docs/design/windows-registration-sites.md`. In short:
pub const SelfHealGate = enum {
    /// The written value names exactly ONE exe and replaces whatever was there
    /// — the `ghoztty://` handler command, the agent's `Run` value, the user
    /// PATH entry (an OWNED value the last launch re-points, T2169) — or is an
    /// offer whose answer every copy shares (the first-run integration). The
    /// last copy launched wins, and launching the copy you want puts it back,
    /// so any real copy may write it: the installed release AND a portable
    /// unpack. Refused: build output (`source_checkout`, T1124/T1146), and a
    /// copy an archive tool extracted into TEMP to run it
    /// (`isTemporaryExtraction`), which is gone as soon as the preview closes.
    /// This is the Mac behavior: its CLI link follows whichever non-temporary
    /// bundle launched.
    not_build_output,

    /// The write is about the installed release ITSELF, so only the canonical
    /// install folder may make it. No launch-time self-heal uses it since
    /// T2169 moved the PATH entry and the integration offer to
    /// `.not_build_output`; the gate stays for the next write that genuinely
    /// accumulates.
    installed_release,
};

/// Whether `exe_dir` is a copy an archive tool extracted into `temp_dir` just
/// to run it (T2169) — the Windows counterpart of the Mac refusal of a mounted
/// DMG or an App Translocation path. Double-clicking `ghoztty.exe` inside a zip
/// in Explorer runs it from `%TEMP%\Temp<n>_<name>.zip\...`; 7-Zip uses
/// `%TEMP%\7zO<hex>\` and WinRAR `%TEMP%\Rar$EX<...>\`. Each is deleted when
/// the preview closes, so anything registered against it dangles.
///
/// Only the FIRST component under `temp_dir` is examined: a portable unpacked
/// on purpose somewhere under TEMP is a real copy.
pub fn isTemporaryExtraction(exe_dir: []const u8, temp_dir: []const u8) bool {
    const temp = path_env.normalize(temp_dir);
    if (temp.len == 0) return false;
    const dir = path_env.normalize(exe_dir);
    if (dir.len <= temp.len + 1) return false;
    if (!eqlPathIgnoreSep(dir[0..temp.len], temp)) return false;
    const sep = dir[temp.len];
    if (sep != '\\' and sep != '/') return false;

    const rest = dir[temp.len + 1 ..];
    const end = std.mem.indexOfAny(u8, rest, "\\/") orelse rest.len;
    const first = rest[0..end];

    if (startsWithIgnoreCase(first, "7zO")) return true;
    if (startsWithIgnoreCase(first, "Rar$")) return true;
    // Explorer: `Temp<digits>_<archive name>.zip`.
    if (!startsWithIgnoreCase(first, "Temp")) return false;
    var i: usize = 4;
    while (i < first.len and std.ascii.isDigit(first[i])) i += 1;
    if (i == 4 or i >= first.len or first[i] != '_') return false;
    return std.ascii.endsWithIgnoreCase(first, ".zip");
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// Runtime form of `isTemporaryExtraction`: reads `%TEMP%` (then `%TMP%`).
/// Neither readable means no extraction can be recognised, and the answer is
/// false — the other half of the gate still refuses build output.
fn inTemporaryExtraction(arena: std.mem.Allocator, exe_dir: []const u8) bool {
    const temp = std.process.getEnvVarOwned(arena, "TEMP") catch
        std.process.getEnvVarOwned(arena, "TMP") catch return false;
    // Freed although the caller's is usually an arena: the unit tests pass a
    // leak-checking allocator through `selfHealAllowedIn`.
    defer arena.free(temp);
    return isTemporaryExtraction(exe_dir, temp);
}

/// Whether a self-heal under `gate` may write from an exe in `exe_dir`, on a
/// machine whose `%LOCALAPPDATA%` is `local_app_data`.
///
/// This is the ONE answer the launch-time self-heals ask (`url_scheme`,
/// `LocalAgent`, `PathInstaller`, `AgentIntegration`), so a new one picks a
/// gate by owner rather than by whichever neighbour its author read first.
/// `exe_dir` is the caller's: `url_scheme` asks about the PRODUCT exe it will
/// register, not the running one (T980). The agent's `adopt.zig` cannot
/// import the apprt and asks `source_checkout` directly — the same answer as
/// `.not_build_output`.
pub fn selfHealAllowedIn(
    arena: std.mem.Allocator,
    gate: SelfHealGate,
    exe_dir: []const u8,
    local_app_data: []const u8,
) bool {
    return switch (gate) {
        .not_build_output => !source_checkout.inSourceCheckout(arena, exe_dir) and
            !inTemporaryExtraction(arena, exe_dir),
        .installed_release => isInstallDir(exe_dir, local_app_data),
    };
}

/// Runtime form of `selfHealAllowedIn`: reads `%LOCALAPPDATA%` itself. An
/// unreadable one fails CLOSED for `.installed_release` — every one of these
/// writes outlives the process, so a location that cannot be checked is
/// treated as one that is not allowed.
pub fn selfHealAllowed(
    arena: std.mem.Allocator,
    gate: SelfHealGate,
    exe_dir: []const u8,
) bool {
    const local = std.process.getEnvVarOwned(arena, "LOCALAPPDATA") catch "";
    return selfHealAllowedIn(arena, gate, exe_dir, local);
}

const testing = std.testing;

test "selfHealAllowedIn: the installed release passes both gates" {
    // Under TEMP, not `testing.tmpDir` (inside this checkout, where every path
    // has our `build.zig` as an ancestor) — the same reason as
    // source_checkout's own test.
    const alloc = testing.allocator;
    const tmp = std.process.getEnvVarOwned(alloc, "TEMP") catch return error.SkipZigTest;
    defer alloc.free(tmp);
    const install = try std.fs.path.join(alloc, &.{ tmp, install_subdir });
    defer alloc.free(install);

    try testing.expect(selfHealAllowedIn(alloc, .installed_release, install, tmp));
    try testing.expect(selfHealAllowedIn(alloc, .not_build_output, install, tmp));
}

test "selfHealAllowedIn: a portable unpack passes the last-launch-wins gate only" {
    const alloc = testing.allocator;
    const tmp = std.process.getEnvVarOwned(alloc, "TEMP") catch return error.SkipZigTest;
    defer alloc.free(tmp);
    const portable = try std.fs.path.join(alloc, &.{ tmp, "Ghoztty-portable-x64", "Ghoztty" });
    defer alloc.free(portable);

    try testing.expect(selfHealAllowedIn(alloc, .not_build_output, portable, tmp));
    try testing.expect(!selfHealAllowedIn(alloc, .installed_release, portable, tmp));
}

test "selfHealAllowedIn: a copy run out of a zip preview registers nothing" {
    const alloc = testing.allocator;
    const tmp = std.process.getEnvVarOwned(alloc, "TEMP") catch return error.SkipZigTest;
    defer alloc.free(tmp);
    const preview = try std.fs.path.join(alloc, &.{ tmp, "Temp1_Ghoztty-portable-x64.zip", "Ghoztty" });
    defer alloc.free(preview);

    try testing.expect(!selfHealAllowedIn(alloc, .not_build_output, preview, tmp));
    try testing.expect(!selfHealAllowedIn(alloc, .installed_release, preview, tmp));
}

test "isTemporaryExtraction: Explorer, 7-Zip and WinRAR previews" {
    const temp = "C:\\Users\\D\\AppData\\Local\\Temp";
    try testing.expect(isTemporaryExtraction(temp ++ "\\Temp1_Ghoztty-portable-x64.zip\\Ghoztty", temp));
    try testing.expect(isTemporaryExtraction(temp ++ "\\Temp23_ghoztty.ZIP", temp));
    try testing.expect(isTemporaryExtraction(temp ++ "\\7zO8A1B2C3D\\Ghoztty", temp));
    try testing.expect(isTemporaryExtraction(temp ++ "\\Rar$EXa12345.6789\\Ghoztty", temp));
    // Case, trailing separators and slash direction do not matter.
    try testing.expect(isTemporaryExtraction("c:/users/d/appdata/local/temp/temp1_g.zip/Ghoztty/", temp ++ "\\"));
}

test "isTemporaryExtraction: a folder unpacked on purpose is a real copy" {
    const temp = "C:\\Users\\D\\AppData\\Local\\Temp";
    // Under TEMP, but not an archive tool's name.
    try testing.expect(!isTemporaryExtraction(temp ++ "\\Ghoztty-portable-x64\\Ghoztty", temp));
    try testing.expect(!isTemporaryExtraction(temp ++ "\\Temp_ghoztty.zip", temp));
    try testing.expect(!isTemporaryExtraction(temp ++ "\\Temp1_ghoztty", temp));
    try testing.expect(!isTemporaryExtraction(temp ++ "\\Templates\\Temp1_g.zip", temp));
    // TEMP itself, a sibling sharing its prefix, and elsewhere entirely.
    try testing.expect(!isTemporaryExtraction(temp, temp));
    try testing.expect(!isTemporaryExtraction(temp ++ "2\\Temp1_g.zip", temp));
    try testing.expect(!isTemporaryExtraction("D:\\Desktop\\Temp1_g.zip\\Ghoztty", temp));
    try testing.expect(!isTemporaryExtraction(temp ++ "\\Temp1_g.zip", ""));
}

test "selfHealAllowedIn: build output passes neither gate" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp = std.process.getEnvVarOwned(arena, "TEMP") catch return error.SkipZigTest;
    const name = try std.fmt.allocPrint(arena, "ghoztty-t1213-{d}", .{std.time.nanoTimestamp()});
    const repo = try std.fs.path.join(arena, &.{ tmp, name });
    const bin = try std.fs.path.join(arena, &.{ repo, "zig-out", "bin" });
    try std.fs.cwd().makePath(bin);
    defer std.fs.deleteTreeAbsolute(repo) catch {};
    const marker = try std.fs.path.join(arena, &.{ repo, "build.zig" });
    (try std.fs.createFileAbsolute(marker, .{})).close();

    try testing.expect(!selfHealAllowedIn(arena, .not_build_output, bin, tmp));
    try testing.expect(!selfHealAllowedIn(arena, .installed_release, bin, tmp));
}

test "selfHealAllowedIn: an unreadable LOCALAPPDATA fails closed for the install gate" {
    try testing.expect(!selfHealAllowedIn(
        testing.allocator,
        .installed_release,
        "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty",
        "",
    ));
}

test "isInstallDir: the installed release" {
    try testing.expect(isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty",
        "C:\\Users\\David\\AppData\\Local",
    ));
}

test "isInstallDir: case, trailing separators and slash direction do not matter" {
    try testing.expect(isInstallDir(
        "c:\\users\\david\\appdata\\local\\programs\\ghoztty\\",
        "C:\\Users\\David\\AppData\\Local\\",
    ));
    try testing.expect(isInstallDir(
        "C:/Users/David/AppData/Local/Programs/Ghoztty",
        "C:\\Users\\David\\AppData\\Local",
    ));
}

test "isInstallDir: a portable unpack is not the install" {
    try testing.expect(!isInstallDir(
        "D:\\Users\\David\\Desktop\\Ghoztty-portable-x64\\Ghoztty",
        "C:\\Users\\David\\AppData\\Local",
    ));
    try testing.expect(!isInstallDir(
        "\\\\homeassistant\\share\\ghoztty-windows\\Ghoztty",
        "C:\\Users\\David\\AppData\\Local",
    ));
}

test "isInstallDir: a dev prefix is not the install" {
    try testing.expect(!isInstallDir(
        "D:\\git\\ghoztty\\zig-out\\bin",
        "C:\\Users\\David\\AppData\\Local",
    ));
    // Even one that happens to live under LOCALAPPDATA.
    try testing.expect(!isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\src\\ghoztty\\zig-out\\bin",
        "C:\\Users\\David\\AppData\\Local",
    ));
}

test "isInstallDir: neither a parent nor a child of the install dir counts" {
    try testing.expect(!isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\Programs",
        "C:\\Users\\David\\AppData\\Local",
    ));
    try testing.expect(!isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty\\resources",
        "C:\\Users\\David\\AppData\\Local",
    ));
    // A sibling whose name merely starts the same way.
    try testing.expect(!isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty2",
        "C:\\Users\\David\\AppData\\Local",
    ));
}

test "isInstallDir: a drive-root LOCALAPPDATA still matches" {
    try testing.expect(isInstallDir("C:\\Programs\\Ghoztty", "C:\\"));
}

test "isInstallDir: an empty or unreadable LOCALAPPDATA is never the install" {
    try testing.expect(!isInstallDir(
        "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty",
        "",
    ));
    try testing.expect(!isInstallDir("", "C:\\Users\\David\\AppData\\Local"));
}
