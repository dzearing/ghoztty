//! Does a staged update package act on THIS copy of Ghoztty? (T3393)
//!
//! msiexec does not install "over the exe that launched it". It installs the
//! PRODUCT the package names, and Windows Installer keeps product state per
//! user, not per folder. So a package applied from any copy that is not the
//! registered install acts on the registered install anyway:
//!
//!   * a release build copied into a test sandbox's `Programs\Ghoztty` read
//!     that folder as the installed release, applied the real MSI and
//!     reconfigured the user's own install (2026-11-22, T3388);
//!   * a portable unpack applying the MSI installs a second copy under
//!     `%LOCALAPPDATA%\Programs\Ghoztty`, then relaunches the OLD portable.
//!
//! `GHOZTTY_AUTO_UPDATE=off` (T3388) closes the sandbox route by convention.
//! This closes it in the app: before the applier is armed, the package's own
//! UpgradeCode and its `ghoztty.exe` component are looked up in Windows
//! Installer, and the install goes ahead only when the registered product's
//! exe sits in this exe's own folder. The lookup is `update_target_msi.zig`;
//! the decision is here, with no OS imports, so every lane tests it.
//!
//! The product's `InstallLocation` is NOT the source: the package never sets
//! ARPINSTALLLOCATION, so Windows Installer reports it empty for the real
//! release (checked on the box, 2026-11-22). The component path is what msiexec
//! itself resolves, so it is the folder the install would actually write.
const std = @import("std");
const path_env = @import("../../os/path_env.zig");

/// What the lookup found, as the decision reads it.
pub const Verdict = union(enum) {
    /// The package's product is registered, and its exe is in this exe's
    /// folder. The only verdict that lets the install go ahead.
    same_install,
    /// No product carries the package's UpgradeCode: this copy is not an
    /// installed product (a portable unpack, a sandbox copy), and msiexec
    /// would make a fresh install somewhere else.
    not_installed,
    /// A registered product's exe lives in another folder - the one msiexec
    /// would act on. Carries that folder, for the log.
    elsewhere: []const u8,
    /// A product is registered but Windows Installer could not say where its
    /// exe is. Refused: a location that cannot be checked is not this one.
    location_unknown,
    /// The package could not be read as an installer database, or carries no
    /// UpgradeCode or no `ghoztty.exe` component. Refused for the same reason.
    package_unreadable,
    /// msi.dll could not be loaded or a lookup failed outright. Refused.
    lookup_failed,

    pub fn allows(self: Verdict) bool {
        return self == .same_install;
    }
};

/// Decide from the registered exe paths of every product carrying the
/// package's UpgradeCode (`null` = registered, location unresolved).
///
/// Every registration must be this folder: a major upgrade removes EVERY
/// related product, so one registration elsewhere is enough for the install
/// to reach a copy that is not this one.
pub fn decide(exe_dir: []const u8, registered: []const ?[]const u8) Verdict {
    if (registered.len == 0) return .not_installed;
    var unknown = false;
    for (registered) |maybe| {
        const exe_path = maybe orelse {
            unknown = true;
            continue;
        };
        const dir = std.fs.path.dirnameWindows(exe_path) orelse {
            unknown = true;
            continue;
        };
        if (!sameDir(dir, exe_dir)) return .{ .elsewhere = dir };
    }
    if (unknown) return .location_unknown;
    return .same_install;
}

/// Directory equality the way Windows resolves paths: ASCII case-insensitive,
/// trailing separators ignored, `/` read as `\`.
pub fn sameDir(a: []const u8, b: []const u8) bool {
    const na = path_env.normalize(a);
    const nb = path_env.normalize(b);
    if (na.len != nb.len) return false;
    for (na, nb) |ca, cb| {
        const xa = if (ca == '/') '\\' else std.ascii.toLower(ca);
        const xb = if (cb == '/') '\\' else std.ascii.toLower(cb);
        if (xa != xb) return false;
    }
    return true;
}

/// Whether an MSI `File.FileName` column names `want`. The column is either
/// the long name alone or `SHORT~1.EXE|long-name.exe`; the long name is the
/// one compared, case-insensitively.
pub fn msiFileNameIs(column: []const u8, want: []const u8) bool {
    const long = if (std.mem.indexOfScalar(u8, column, '|')) |bar| column[bar + 1 ..] else column;
    return std.ascii.eqlIgnoreCase(long, want);
}

/// Whether the guard's verdict is enforced, or only logged (Debug seams).
///
/// A release build always enforces. A Debug build with the
/// `GHOZTTY_UPDATE_MSI_CODE` seam set never runs msiexec at all (the applier
/// returns the forced code instead), so the acceptance scripts that arm a
/// canned, not-really-an-installer package keep working: the verdict is logged
/// as advisory. `GHOZTTY_UPDATE_TARGET_ENFORCE=1` puts the teeth back under
/// the seam, which is how `test\win32\update-target-guard.ps1` drives the
/// refusal with msiexec still unable to run if the guard ever let it through.
pub fn enforced(debug: bool, msi_code_seam: bool, enforce_seam: bool) bool {
    if (!debug) return true;
    if (msi_code_seam and !enforce_seam) return false;
    return true;
}

/// One log line naming the verdict. `buf` too small truncates to empty.
pub fn describe(buf: []u8, v: Verdict, exe_dir: []const u8) []const u8 {
    return switch (v) {
        .same_install => std.fmt.bufPrint(buf, "the installed product is this copy ({s})", .{exe_dir}),
        .not_installed => std.fmt.bufPrint(buf, "no installed product carries this package's UpgradeCode; this copy ({s}) is not an install", .{exe_dir}),
        .elsewhere => |dir| std.fmt.bufPrint(buf, "the package's product is registered at {s}, not at this copy ({s})", .{ dir, exe_dir }),
        .location_unknown => std.fmt.bufPrint(buf, "the package's product is registered but Windows Installer cannot say where; this copy is {s}", .{exe_dir}),
        .package_unreadable => std.fmt.bufPrint(buf, "the package could not be read as an installer (no UpgradeCode or no ghoztty.exe component)", .{}),
        .lookup_failed => std.fmt.bufPrint(buf, "Windows Installer could not be asked where the product is installed", .{}),
    } catch buf[0..0];
}

const testing = std.testing;

test "decide: the registered exe in this folder is the only go-ahead (T3393)" {
    const here = "C:\\Users\\D\\AppData\\Local\\Programs\\Ghoztty";
    const v = decide(here, &.{"C:\\Users\\D\\AppData\\Local\\Programs\\Ghoztty\\ghoztty.exe"});
    try testing.expect(v == .same_install);
    try testing.expect(v.allows());
    // Case, slash direction and a trailing separator do not matter.
    try testing.expect(decide(here ++ "\\", &.{"c:/users/d/appdata/local/programs/ghoztty/GHOZTTY.EXE"}) == .same_install);
}

test "decide: a sandbox copy is refused and names the real install (T3393)" {
    const v = decide(
        "C:\\Users\\D\\AppData\\Local\\Temp\\sandbox\\Programs\\Ghoztty",
        &.{"C:\\Users\\D\\AppData\\Local\\Programs\\Ghoztty\\ghoztty.exe"},
    );
    try testing.expect(!v.allows());
    try testing.expectEqualStrings("C:\\Users\\D\\AppData\\Local\\Programs\\Ghoztty", v.elsewhere);
}

test "decide: a portable unpack with nothing installed is refused (T3393)" {
    const v = decide("D:\\Desktop\\Ghoztty-portable-x64\\Ghoztty", &.{});
    try testing.expect(v == .not_installed);
    try testing.expect(!v.allows());
}

test "decide: one registration elsewhere is enough to refuse (T3393)" {
    const here = "C:\\P\\Ghoztty";
    const v = decide(here, &.{ "C:\\P\\Ghoztty\\ghoztty.exe", "D:\\Other\\ghoztty.exe" });
    try testing.expectEqualStrings("D:\\Other", v.elsewhere);
    // ...in either order.
    try testing.expect(decide(here, &.{ "D:\\Other\\ghoztty.exe", "C:\\P\\Ghoztty\\ghoztty.exe" }) == .elsewhere);
}

test "decide: an unresolved location fails closed (T3393)" {
    const here = "C:\\P\\Ghoztty";
    try testing.expect(decide(here, &.{null}) == .location_unknown);
    try testing.expect(decide(here, &.{ "C:\\P\\Ghoztty\\ghoztty.exe", null }) == .location_unknown);
    // A known-elsewhere beats an unknown: it is the more useful log line.
    try testing.expect(decide(here, &.{ null, "D:\\Other\\ghoztty.exe" }) == .elsewhere);
    // A bare file name has no folder to compare.
    try testing.expect(decide(here, &.{"ghoztty.exe"}) == .location_unknown);
}

test "decide: a sibling folder sharing the prefix is not this one (T3393)" {
    try testing.expect(decide("C:\\P\\Ghoztty", &.{"C:\\P\\Ghoztty2\\ghoztty.exe"}) == .elsewhere);
    try testing.expect(decide("C:\\P\\Ghoztty2", &.{"C:\\P\\Ghoztty\\ghoztty.exe"}) == .elsewhere);
}

test "every verdict but same_install refuses (T3393)" {
    try testing.expect(!(Verdict{ .elsewhere = "x" }).allows());
    try testing.expect(!(Verdict{ .not_installed = {} }).allows());
    try testing.expect(!(Verdict{ .location_unknown = {} }).allows());
    try testing.expect(!(Verdict{ .package_unreadable = {} }).allows());
    try testing.expect(!(Verdict{ .lookup_failed = {} }).allows());
}

test "msiFileNameIs: long names, short|long pairs, case (T3393)" {
    try testing.expect(msiFileNameIs("ghoztty.exe", "ghoztty.exe"));
    try testing.expect(msiFileNameIs("GHOZTT~1.EXE|ghoztty.exe", "ghoztty.exe"));
    try testing.expect(msiFileNameIs("GHOZTTY.EXE", "ghoztty.exe"));
    try testing.expect(!msiFileNameIs("ghoztty.com", "ghoztty.exe"));
    try testing.expect(!msiFileNameIs("GHOZTT~1.EXE|ghoztty-agent.exe", "ghoztty.exe"));
    // The short half alone never matches the long name it abbreviates.
    try testing.expect(!msiFileNameIs("GHOZTT~1.EXE", "ghoztty.exe"));
}

test "enforced: release always, Debug unless the msiexec seam is set without the enforce seam (T3393)" {
    try testing.expect(enforced(false, false, false));
    try testing.expect(enforced(false, true, false));
    try testing.expect(enforced(true, false, false));
    try testing.expect(!enforced(true, true, false));
    try testing.expect(enforced(true, true, true));
}

test "describe: the refusal names both folders (T3393)" {
    var buf: [512]u8 = undefined;
    const line = describe(&buf, .{ .elsewhere = "C:\\Real\\Ghoztty" }, "C:\\Sandbox\\Ghoztty");
    try testing.expect(std.mem.indexOf(u8, line, "C:\\Real\\Ghoztty") != null);
    try testing.expect(std.mem.indexOf(u8, line, "C:\\Sandbox\\Ghoztty") != null);
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("", describe(&tiny, .not_installed, "C:\\x"));
}
