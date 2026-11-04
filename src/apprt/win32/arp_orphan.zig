//! Which `HKCU\...\Uninstall\{code}` keys are dead Ghoztty rows (T2679).
//! Pure logic: no OS imports, so every lane checks it.
//!
//! ## The rows
//!
//! Before T2327, every in-app update left the release it replaced listed in
//! Settings > Apps. The listed entry is the package's own `C_ArpEntry`
//! component (T2168), written to `HKCU\Software\Microsoft\Windows\
//! CurrentVersion\Uninstall\{ProductCode}`, and a late RemoveExistingProducts
//! removed the old PRODUCT while leaving that key behind. By 2026-11-03 one box
//! listed 44 of them, 1.43.4 to 1.52.8. T2327 stops new ones; this module
//! decides which of the existing ones may be removed on the user's behalf.
//!
//! ## What makes a key ours, and dead
//!
//! Every test below must hold, and the last one is the OS layer's
//! (`ArpOrphanSweep.zig`), because only Windows Installer can answer it:
//!
//! 1. The key name is a braced product code.
//! 2. `DisplayName` is exactly the product name and `Publisher` exactly the
//!    manufacturer the package writes. Another vendor's "Ghoztty" is not ours.
//! 3. `UninstallString` is exactly what `C_ArpEntry` writes,
//!    `MsiExec.exe /X{code}`, naming the SAME code as the key. A row someone
//!    or something else wrote does not have that shape.
//! 4. It is not Windows Installer's own registration entry
//!    (`WindowsInstaller` = 1). Ours never carries that value.
//! 5. Windows Installer does not know the product
//!    (`MsiQueryProductState` = INSTALLSTATE_UNKNOWN). A registered product -
//!    the live install, or one installed for another context - is never
//!    touched, whatever its key looks like.
//!
//! A row that fails any test is left exactly as it is.

const std = @import("std");

/// The product the package names: `PRODUCT_NAME` and `Manufacturer` in
/// `dist/windows-installer/build-msi.sh`.
pub const Identity = struct {
    display_name: []const u8,
    publisher: []const u8,
};

/// The release identity. A throwaway test identity (msi-test-identity.ps1)
/// shares the publisher and changes the name.
pub const release: Identity = .{ .display_name = "Ghoztty", .publisher = "dzearing" };

/// One listed key, as read from the registry. A value that is absent or not a
/// string is null.
pub const Entry = struct {
    key_name: []const u8,
    display_name: ?[]const u8 = null,
    publisher: ?[]const u8 = null,
    uninstall_string: ?[]const u8 = null,
    /// `WindowsInstaller` DWORD is 1: Windows' own entry, never ours.
    windows_installer: bool = false,
};

/// `{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}`, hex in either case.
pub fn isProductCode(s: []const u8) bool {
    if (s.len != 38 or s[0] != '{' or s[37] != '}') return false;
    for (s[1..37], 1..) |c, i| {
        switch (i) {
            9, 14, 19, 24 => if (c != '-') return false,
            else => if (!std.ascii.isHex(c)) return false,
        }
    }
    return true;
}

const uninstall_prefix = "MsiExec.exe /X";

/// Tests 1-4: the product code whose key this is, when the key has exactly
/// the shape the package writes for `id`; null otherwise. The caller still
/// owes test 5 before removing anything.
pub fn candidate(e: Entry, id: Identity) ?[]const u8 {
    if (!isProductCode(e.key_name)) return null;
    if (e.windows_installer) return null;
    const name = e.display_name orelse return null;
    if (!std.mem.eql(u8, name, id.display_name)) return null;
    const publisher = e.publisher orelse return null;
    if (!std.mem.eql(u8, publisher, id.publisher)) return null;
    const cmd = e.uninstall_string orelse return null;
    if (cmd.len != uninstall_prefix.len + e.key_name.len) return null;
    if (!std.ascii.eqlIgnoreCase(cmd[0..uninstall_prefix.len], uninstall_prefix)) return null;
    if (!std.ascii.eqlIgnoreCase(cmd[uninstall_prefix.len..], e.key_name)) return null;
    return e.key_name;
}

/// `GHOZTTY_ARP_SWEEP`, the only knob.
pub const Mode = enum {
    /// Do nothing.
    off,
    /// Sweep the release identity.
    on,
    /// Sweep even from a Debug build, for the identity named by
    /// `GHOZTTY_ARP_SWEEP_NAME` (the acceptance seam).
    forced,
};

/// A Debug build runs beside the user's real install and never sweeps unless
/// a test forces it, the same rule as the PATH self-heal.
pub fn mode(env: ?[]const u8, debug: bool) Mode {
    if (env) |v| {
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off")) return .off;
        if (std.ascii.eqlIgnoreCase(v, "force")) return .forced;
    }
    return if (debug) .off else .on;
}

/// The identity a sweep in `m` targets. Under `.forced` a name must be given,
/// so a forced run can never fall through to the user's release rows by
/// accident; null means "do nothing".
pub fn identityFor(m: Mode, name_override: ?[]const u8) ?Identity {
    return switch (m) {
        .off => null,
        .on => release,
        .forced => if (name_override) |n|
            (if (n.len == 0) null else .{ .display_name = n, .publisher = release.publisher })
        else
            null,
    };
}

const testing = std.testing;
const code = "{0D7919A6-1B2C-4D3E-8F90-A1B2C3D4E5F6}";

fn ours() Entry {
    return .{
        .key_name = code,
        .display_name = "Ghoztty",
        .publisher = "dzearing",
        .uninstall_string = "MsiExec.exe /X" ++ code,
    };
}

test "isProductCode" {
    try testing.expect(isProductCode(code));
    try testing.expect(isProductCode("{0d7919a6-1b2c-4d3e-8f90-a1b2c3d4e5f6}"));
    try testing.expect(!isProductCode("0D7919A6-1B2C-4D3E-8F90-A1B2C3D4E5F6"));
    try testing.expect(!isProductCode("{0D7919A6-1B2C-4D3E-8F90-A1B2C3D4E5FG}"));
    try testing.expect(!isProductCode("{0D7919A6-1B2C-4D3E-8F90A-1B2C3D4E5F6}"));
    try testing.expect(!isProductCode("Ghoztty"));
}

test "the key C_ArpEntry writes is a candidate" {
    try testing.expectEqualStrings(code, candidate(ours(), release).?);
    // msiexec spells it any way it likes, and so may a GUID's hex.
    var e = ours();
    e.uninstall_string = "MSIEXEC.EXE /x{0d7919a6-1b2c-4d3e-8f90-a1b2c3d4e5f6}";
    try testing.expectEqualStrings(code, candidate(e, release).?);
}

test "anything not exactly that shape is left alone" {
    var e = ours();
    e.display_name = "Ghoztty Preview";
    try testing.expect(candidate(e, release) == null);
    e = ours();
    e.display_name = null;
    try testing.expect(candidate(e, release) == null);
    e = ours();
    e.publisher = "Somebody else";
    try testing.expect(candidate(e, release) == null);
    e = ours();
    e.publisher = null;
    try testing.expect(candidate(e, release) == null);
    e = ours();
    e.uninstall_string = null;
    try testing.expect(candidate(e, release) == null);
    // Names a different product than the key it sits in.
    e = ours();
    e.uninstall_string = "MsiExec.exe /X{11111111-1B2C-4D3E-8F90-A1B2C3D4E5F6}";
    try testing.expect(candidate(e, release) == null);
    // Anything more than the bare command (a quiet switch, a script).
    e = ours();
    e.uninstall_string = "MsiExec.exe /X" ++ code ++ " /qn";
    try testing.expect(candidate(e, release) == null);
    e = ours();
    e.uninstall_string = "C:\\x\\uninstall.exe";
    try testing.expect(candidate(e, release) == null);
    // Windows' own registration entry.
    e = ours();
    e.windows_installer = true;
    try testing.expect(candidate(e, release) == null);
    // A key whose name is not a product code.
    e = ours();
    e.key_name = "Ghoztty";
    try testing.expect(candidate(e, release) == null);
}

test "a test identity only matches its own name" {
    const t: Identity = .{ .display_name = "GhozttyT2679", .publisher = "dzearing" };
    try testing.expect(candidate(ours(), t) == null);
    var e = ours();
    e.display_name = "GhozttyT2679";
    try testing.expectEqualStrings(code, candidate(e, t).?);
    try testing.expect(candidate(e, release) == null);
}

test "mode: release sweeps, Debug does not, the env can turn it off or force it" {
    try testing.expectEqual(Mode.on, mode(null, false));
    try testing.expectEqual(Mode.off, mode(null, true));
    try testing.expectEqual(Mode.off, mode("0", false));
    try testing.expectEqual(Mode.off, mode("OFF", false));
    try testing.expectEqual(Mode.forced, mode("force", true));
    try testing.expectEqual(Mode.on, mode("1", false));
    try testing.expectEqual(Mode.off, mode("1", true));
}

test "identityFor: a forced run needs a name and never defaults to the release" {
    try testing.expect(identityFor(.off, "x") == null);
    try testing.expectEqualStrings("Ghoztty", identityFor(.on, null).?.display_name);
    try testing.expect(identityFor(.forced, null) == null);
    try testing.expect(identityFor(.forced, "") == null);
    const t = identityFor(.forced, "GhozttyT2679").?;
    try testing.expectEqualStrings("GhozttyT2679", t.display_name);
    try testing.expectEqualStrings("dzearing", t.publisher);
}
